defmodule SymphonyElixir.AgentServer do
  @moduledoc """
  Behaviour for coding-agent backends (Codex, Claude Code, etc.).
  """

  @type session :: map()

  @callback start_session(workspace :: Path.t(), opts :: keyword()) :: {:ok, session()} | {:error, term()}

  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback stop_session(session()) :: :ok
end
