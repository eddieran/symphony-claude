defmodule SymphonyElixir.ClaudeServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.Server, as: ClaudeServer

  test "claude server rejects workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude"
      )

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               ClaudeServer.start_session(workspace_root)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               ClaudeServer.start_session(outside_workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "claude server start_session returns session with session_id and workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-server-session-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude"
      )

      assert {:ok, session} = ClaudeServer.start_session(workspace)
      assert is_binary(session.session_id)
      assert String.match?(session.session_id, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
      # workspace is canonicalized (macOS /tmp -> /private/var/...)
      assert String.ends_with?(session.workspace, "workspaces/MT-100")
      assert session.turn_count == 0
    after
      File.rm_rf(test_root)
    end
  end

  test "claude server stop_session is a no-op" do
    assert :ok = ClaudeServer.stop_session(%{session_id: "test", workspace: "/tmp", turn_count: 0})
  end

  test "claude server completes a turn with stream-json result event" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-server-turn-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-101")
      fake_claude = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      # Fake Claude Code emitting stream-json events
      printf '%s\\n' '{"type":"assistant","message":"thinking..."}'
      printf '%s\\n' '{"type":"tool_use","tool":"Read","input":{"file":"foo.ex"}}'
      printf '%s\\n' '{"type":"tool_result","result":"contents of foo.ex"}'
      printf '%s\\n' '{"type":"result","result":"All done!","session_id":"test-session","usage":{"input_tokens":1500,"output_tokens":500}}'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude",
        claude_command: fake_claude
      )

      {:ok, session} = ClaudeServer.start_session(workspace)

      issue = %Issue{
        id: "issue-claude-turn",
        identifier: "MT-101",
        title: "Claude turn test",
        description: "Test basic Claude turn completion",
        state: "In Progress",
        url: "https://example.org/issues/MT-101",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:claude_message, message}) end

      assert {:ok, result} =
               ClaudeServer.run_turn(session, "Do the thing", issue, on_message: on_message)

      assert result.result == :turn_completed
      assert result.thread_id == session.session_id
      assert result.turn_id == "turn-1"
      assert result.session.turn_count == 1

      # Should have received notification events for assistant/tool_use/tool_result
      assert_received {:claude_message, %{event: :session_started}}
      assert_received {:claude_message, %{event: :notification, payload: %{"type" => "assistant"}}}
      assert_received {:claude_message, %{event: :notification, payload: %{"type" => "tool_use"}}}
      assert_received {:claude_message, %{event: :notification, payload: %{"type" => "tool_result"}}}

      assert_received {:claude_message,
                       %{
                         event: :turn_completed,
                         payload: %{"type" => "result"},
                         usage: %{
                           "input_tokens" => 1500,
                           "output_tokens" => 500,
                           "total_tokens" => 2000
                         },
                         codex_app_server_pid: pid,
                         session_id: _
                       }}

      assert is_binary(pid)
    after
      File.rm_rf(test_root)
    end
  end

  test "claude server handles non-zero exit as error" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-server-exit-error-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-102")
      fake_claude = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      printf '%s\\n' '{"type":"assistant","message":"starting..."}'
      exit 1
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude",
        claude_command: fake_claude
      )

      {:ok, session} = ClaudeServer.start_session(workspace)

      issue = %Issue{
        id: "issue-claude-exit-error",
        identifier: "MT-102",
        title: "Claude exit error test",
        description: "Test non-zero exit handling",
        state: "In Progress",
        url: "https://example.org/issues/MT-102",
        labels: ["backend"]
      }

      assert {:error, {:port_exit, 1}} =
               ClaudeServer.run_turn(session, "Fail please", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "claude server handles error event in stream" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-server-error-event-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-103")
      fake_claude = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      printf '%s\\n' '{"type":"error","error":{"message":"rate limited","type":"rate_limit"}}'
      sleep 1
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude",
        claude_command: fake_claude
      )

      {:ok, session} = ClaudeServer.start_session(workspace)

      issue = %Issue{
        id: "issue-claude-error-event",
        identifier: "MT-103",
        title: "Claude error event test",
        description: "Test error event in stream",
        state: "In Progress",
        url: "https://example.org/issues/MT-103",
        labels: ["backend"]
      }

      assert {:error, {:claude_error, %{"message" => "rate limited", "type" => "rate_limit"}}} =
               ClaudeServer.run_turn(session, "Error me", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "claude server increments turn count across turns" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-server-multi-turn-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-104")
      fake_claude = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      printf '%s\\n' '{"type":"result","result":"done"}'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude",
        claude_command: fake_claude
      )

      {:ok, session} = ClaudeServer.start_session(workspace)

      issue = %Issue{
        id: "issue-claude-multi-turn",
        identifier: "MT-104",
        title: "Claude multi-turn test",
        description: "Test turn count increments",
        state: "In Progress",
        url: "https://example.org/issues/MT-104",
        labels: ["backend"]
      }

      assert {:ok, result1} = ClaudeServer.run_turn(session, "Turn 1", issue)
      assert result1.turn_id == "turn-1"
      assert result1.session.turn_count == 1

      assert {:ok, result2} = ClaudeServer.run_turn(result1.session, "Turn 2", issue)
      assert result2.turn_id == "turn-2"
      assert result2.session.turn_count == 2
    after
      File.rm_rf(test_root)
    end
  end

  test "claude server captures non-JSON output without crashing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-server-nonjson-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-105")
      fake_claude = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      printf '%s\\n' 'warning: some stderr noise'
      printf '%s\\n' '{"type":"result","result":"done despite noise"}'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude",
        claude_command: fake_claude
      )

      {:ok, session} = ClaudeServer.start_session(workspace)

      issue = %Issue{
        id: "issue-claude-nonjson",
        identifier: "MT-105",
        title: "Claude non-JSON output test",
        description: "Test non-JSON line handling",
        state: "In Progress",
        url: "https://example.org/issues/MT-105",
        labels: ["backend"]
      }

      log =
        capture_log(fn ->
          assert {:ok, _result} = ClaudeServer.run_turn(session, "Handle noise", issue)
        end)

      assert log =~ "Claude stream output: warning: some stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "config dispatches to claude server module when backend is claude" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "claude")
    assert Config.agent_server_module() == SymphonyElixir.Claude.Server
  end

  test "config dispatches to codex app server module when backend is codex" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "codex")
    assert Config.agent_server_module() == SymphonyElixir.Codex.AppServer
  end

  test "config defaults to codex backend" do
    assert Config.agent_server_module() == SymphonyElixir.Codex.AppServer
  end
end
