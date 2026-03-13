defmodule SymphonyElixir.Claude.Server do
  @moduledoc """
  AgentServer implementation for Claude Code.

  Uses `claude -p <prompt> --output-format stream-json` as an Erlang Port.
  Multi-turn continuity is achieved via `--session-id` and `--resume`.
  """

  @behaviour SymphonyElixir.AgentServer

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          session_id: String.t(),
          workspace: Path.t(),
          turn_count: non_neg_integer(),
          last_turn_session_id: String.t() | nil
        }

  @impl true
  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    with {:ok, expanded_workspace} <- validate_workspace(workspace) do
      session_id = generate_session_id()
      Logger.info("Claude session created session_id=#{session_id} workspace=#{expanded_workspace}")

      {:ok,
       %{
         session_id: session_id,
         workspace: expanded_workspace,
         turn_count: 0,
         last_turn_session_id: nil
       }}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{session_id: session_id, workspace: workspace, turn_count: turn_count} = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    claude_settings = Config.settings!().claude
    prev_turn_session_id = Map.get(session, :last_turn_session_id)

    turn_id = "turn-#{turn_count + 1}"
    turn_session_id = generate_session_id()
    combined_session_id = "#{session_id}-#{turn_id}"

    Logger.info(
      "Claude turn starting for #{issue_context(issue)} session_id=#{combined_session_id} turn_session=#{turn_session_id} resume_from=#{prev_turn_session_id || "none"}"
    )

    emit_message(on_message, :session_started, %{
      session_id: combined_session_id,
      thread_id: session_id,
      turn_id: turn_id
    })

    args = build_cli_args(turn_session_id, claude_settings, prev_turn_session_id)

    case launch_port(workspace, claude_settings.command, args, prompt) do
      {:ok, port} ->
        metadata = port_metadata(port, combined_session_id)

        result =
          receive_loop(
            port,
            on_message,
            metadata,
            claude_settings.turn_timeout_ms,
            ""
          )

        case result do
          {:ok, output} ->
            Logger.info(
              "Claude turn completed for #{issue_context(issue)} session_id=#{combined_session_id}"
            )

            {:ok,
             %{
               result: output,
               session_id: combined_session_id,
               thread_id: session_id,
               turn_id: turn_id,
               session: %{session | turn_count: turn_count + 1, last_turn_session_id: turn_session_id}
             }}

          {:error, reason} ->
            Logger.warning(
              "Claude turn ended with error for #{issue_context(issue)} session_id=#{combined_session_id}: #{inspect(reason)}"
            )

            emit_message(on_message, :turn_ended_with_error, %{
              session_id: combined_session_id,
              reason: reason
            })

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Claude port launch failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason})
        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(_session) do
    :ok
  end

  # --- Private helpers ---

  defp validate_workspace(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error,
           {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp generate_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
    |> String.downcase()
  end

  defp build_cli_args(session_id, claude_settings, resume_from) do
    args = [
      "-p",
      "-",
      "--output-format",
      "stream-json",
      "--verbose",
      "--session-id",
      session_id,
      "--model",
      claude_settings.model,
      "--permission-mode",
      claude_settings.permission_mode
    ]

    # Resume from previous turn's session with fork (new session ID, old context)
    args =
      if is_binary(resume_from) do
        args ++ ["--resume", resume_from, "--fork-session"]
      else
        args
      end

    Enum.reduce(claude_settings.allowed_tools, args, fn tool, acc ->
      acc ++ ["--allowedTools", tool]
    end)
  end

  defp launch_port(workspace, command, args, prompt) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      prompt_file = write_prompt_file(prompt)

      cli_command =
        [command | args]
        |> Enum.map(&shell_escape/1)
        |> Enum.join(" ")

      escaped_prompt_file = shell_escape(prompt_file)
      full_command = "cat #{escaped_prompt_file} | #{cli_command}; __exit=$?; rm -f #{escaped_prompt_file}; exit $__exit"

      env =
        [
          {~c"CLAUDECODE", false}
        ]

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:env, env},
            args: [~c"-lc", String.to_charlist(full_command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp write_prompt_file(prompt) do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-claude-prompt-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, prompt)
    path
  end

  defp shell_escape(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp port_metadata(port, session_id) when is_port(port) do
    base = %{session_id: session_id}

    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> Map.put(base, :codex_app_server_pid, to_string(os_pid))
      _ -> base
    end
  end

  defp receive_loop(port, on_message, metadata, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_line(port, on_message, metadata, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          metadata,
          timeout_ms,
          pending_line <> to_string(chunk)
        )

      {^port, {:exit_status, 0}} ->
        {:ok, :turn_completed}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        stop_port(port)
        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, on_message, metadata, data, timeout_ms) do
    case Jason.decode(data) do
      {:ok, %{"type" => "result"} = payload} ->
        usage = extract_usage(payload)

        emit_message(
          on_message,
          :turn_completed,
          Map.merge(
            %{payload: payload, raw: data, details: payload, method: :turn_completed},
            usage
          ),
          metadata
        )

        drain_port(port)
        {:ok, :turn_completed}

      {:ok, %{"type" => type} = payload} when type in ["assistant", "tool_use", "tool_result"] ->
        emit_message(
          on_message,
          :notification,
          %{payload: payload, raw: data},
          metadata
        )

        receive_loop(port, on_message, metadata, timeout_ms, "")

      {:ok, %{"type" => "error"} = payload} ->
        emit_message(
          on_message,
          :turn_ended_with_error,
          %{payload: payload, raw: data, reason: Map.get(payload, "error")},
          metadata
        )

        {:error, {:claude_error, Map.get(payload, "error")}}

      {:ok, payload} ->
        emit_message(
          on_message,
          :notification,
          %{payload: payload, raw: data},
          metadata
        )

        receive_loop(port, on_message, metadata, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_line(data)
        receive_loop(port, on_message, metadata, timeout_ms, "")
    end
  end

  defp drain_port(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, {:data, _}} -> drain_port(port)
    after
      5_000 ->
        stop_port(port)
        :ok
    end
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp log_non_json_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude stream output: #{text}")
      else
        Logger.debug("Claude stream output: #{text}")
      end
    end
  end

  defp extract_usage(payload) when is_map(payload) do
    case Map.get(payload, "usage") do
      %{} = usage ->
        %{
          usage: %{
            "input_tokens" => Map.get(usage, "input_tokens", 0),
            "output_tokens" => Map.get(usage, "output_tokens", 0),
            "total_tokens" =>
              Map.get(
                usage,
                "total_tokens",
                Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
              )
          }
        }

      _ ->
        %{}
    end
  end

  defp emit_message(on_message, event, details, metadata \\ %{})
       when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp default_on_message(_message), do: :ok
end
