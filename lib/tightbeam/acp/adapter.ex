defmodule Tightbeam.Acp.Adapter do
  @moduledoc """
  Harness session layer over Acp.Conn. One Adapter per (harness, archetype);
  it owns a Conn and routes session/update chunks by sessionId to the turn
  currently prompting each session.

  Adapter rules (spec §Adapter selection; the SOURCE OF TRUTH mirrored from the
  TS reference harness.ts):
  1. Apply the model immediately after session/new AND session/load — never
     trust the advertised current model (the fable trap).
  2. Model via session/set_config_option {configId:"model"} with a BARE name;
     effort rides as "model[effort]" split and applied via the harness's effort
     config id.
  3. Permission requests auto-allowed by Conn (YOLO); sessions run in the
     harness's bypass mode set at session/new time.
  """

  use GenServer
  alias Tightbeam.Acp.Conn

  @presets %{
    claude: %{
      home_env: "CLAUDE_CONFIG_DIR",
      yolo_mode: "bypassPermissions",
      effort_config: "effort"
    },
    codex: %{
      home_env: "CODEX_HOME",
      yolo_mode: "agent-full-access",
      effort_config: "reasoning_effort"
    }
  }

  defstruct [:conn, :preset, :cwd, chunks: %{}]

  ## Client

  @type adapter :: GenServer.server()

  @typedoc "Model reference — bare name or \"name[effort]\" (see parse_model_ref/1)."
  @type model_ref :: String.t()

  @doc """
  Start the adapter. Required: `:harness` (:claude | :codex), `:cmd` (adapter
  argv), `:home` (agent-home dir, exported via the harness's home env var),
  `:cwd`. Optional: `:env`, `:stderr_path`, `:name`.

  Accepts either the opts keyword directly, or a ZERO-ARITY FUN producing it.
  The fun form is the coordinator's: opts-building may be expensive or hang
  (remote home delivery over ssh), so it and the ACP initialize handshake run
  AFTER init via handle_continue — inside this process, never blocking the
  caller. A boot failure is then an ordinary adapter crash, taking the
  coordinator's uniform :DOWN → backoff → circuit path. Calls made while
  booting queue behind the continue and are answered when it completes.
  """
  @spec start_link(keyword() | (-> keyword())) :: GenServer.on_start()
  def start_link(fun) when is_function(fun, 0), do: GenServer.start_link(__MODULE__, fun)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc "Create a fresh harness session, model applied (fable-trap rule). Returns {:ok, session_id}."
  @spec new_session(adapter(), model_ref()) :: {:ok, String.t()}
  def new_session(adapter, model), do: GenServer.call(adapter, {:new_session, model}, 30_000)

  @doc "Adopt an existing harness session — re-applies the model; never trusts the advertised one."
  @spec load_session(adapter(), String.t(), model_ref()) :: :ok
  def load_session(adapter, session_id, model), do: GenServer.call(adapter, {:load_session, session_id, model}, 30_000)

  @doc """
  Run a turn: sends session/prompt, accumulates agent_message_chunk text while
  this GenServer keeps routing updates, replies when the harness finishes.
  """
  @spec prompt(adapter(), String.t(), String.t(), timeout()) ::
          {:ok, %{stop_reason: String.t(), text: String.t()}} | {:error, term()}
  def prompt(adapter, session_id, text, timeout \\ 600_000),
    do: GenServer.call(adapter, {:prompt, session_id, text}, timeout + 5_000)

  @doc "The underlying Acp.Conn (for pending_count / quiescence probes)."
  @spec conn(adapter()) :: pid()
  def conn(adapter), do: GenServer.call(adapter, :conn)

  ## Server

  @impl true
  def init(opts_or_fun) do
    {:ok, nil, {:continue, {:boot, opts_or_fun}}}
  end

  @impl true
  def handle_continue({:boot, fun}, nil) when is_function(fun, 0),
    do: handle_continue({:boot, fun.()}, nil)

  def handle_continue({:boot, opts}, nil) do
    harness = Keyword.fetch!(opts, :harness)
    preset = Map.fetch!(@presets, harness)

    {:ok, conn} =
      Conn.start_link(
        cmd: Keyword.fetch!(opts, :cmd),
        env: [{preset.home_env, Keyword.fetch!(opts, :home)}] ++ Keyword.get(opts, :env, []),
        stderr_path: Keyword.get(opts, :stderr_path, "/dev/null"),
        subscriber: self()
      )

    {:ok, %{"protocolVersion" => 1}} =
      Conn.request(conn, "initialize", %{
        protocolVersion: 1,
        clientCapabilities: %{fs: %{readTextFile: false, writeTextFile: false}}
      })

    # Boot completed — the only trustworthy health signal under lazy boot
    # (spawn success means nothing). The coordinator closes its circuit here.
    with ready when is_function(ready, 0) <- Keyword.get(opts, :on_ready), do: ready.()

    {:noreply, %__MODULE__{conn: conn, preset: preset, cwd: Keyword.fetch!(opts, :cwd)}}
  end

  @impl true
  def handle_call({:new_session, model}, _from, state) do
    {:ok, result} = Conn.request(state.conn, "session/new", %{cwd: state.cwd, mcpServers: []})
    sid = result["sessionId"]
    :ok = apply_model(state, sid, model)
    _ = Conn.request(state.conn, "session/set_mode", %{sessionId: sid, modeId: state.preset.yolo_mode})
    {:reply, {:ok, sid}, put_in(state.chunks[sid], [])}
  end

  def handle_call({:load_session, sid, model}, _from, state) do
    {:ok, _} = Conn.request(state.conn, "session/load", %{sessionId: sid, cwd: state.cwd})
    :ok = apply_model(state, sid, model)
    {:reply, :ok, put_in(state.chunks[sid], [])}
  end

  def handle_call({:prompt, sid, text}, from, state) do
    state = put_in(state.chunks[sid], [])
    # Fire the ACP prompt asynchronously so this GenServer keeps routing
    # session/update chunks while the turn runs.
    parent = self()

    Task.start(fn ->
      result = Conn.request(state.conn, "session/prompt", %{sessionId: sid, prompt: [%{type: "text", text: text}]}, timeout: 600_000)
      send(parent, {:prompt_done, sid, from, result})
    end)

    {:noreply, state}
  end

  def handle_call(:conn, _from, state), do: {:reply, state.conn, state}

  @impl true
  def handle_info({:acp_notification, "session/update", params}, state) do
    sid = params["sessionId"]
    update = params["update"] || %{}

    if update["sessionUpdate"] == "agent_message_chunk" do
      text = get_in(update, ["content", "text"])

      if is_binary(text) and Map.has_key?(state.chunks, sid) do
        {:noreply, update_in(state.chunks[sid], &[text | &1])}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:prompt_done, sid, from, result}, state) do
    text = state.chunks |> Map.get(sid, []) |> Enum.reverse() |> Enum.join()

    reply =
      case result do
        {:ok, r} -> {:ok, %{stop_reason: r["stopReason"] || "unknown", text: text}}
        {:error, e} -> {:error, e}
      end

    GenServer.reply(from, reply)
    {:noreply, put_in(state.chunks[sid], [])}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Model application (the fable-trap rule)

  defp apply_model(state, sid, model_ref) do
    {model, effort} = parse_model_ref(model_ref)
    {:ok, _} = Conn.request(state.conn, "session/set_config_option", %{sessionId: sid, configId: "model", value: model})

    if effort do
      {:ok, _} =
        Conn.request(state.conn, "session/set_config_option", %{
          sessionId: sid,
          configId: state.preset.effort_config,
          value: effort
        })
    end

    :ok
  end

  @doc """
  Split a model ref into `{model, effort}`; effort is nil when absent.

      iex> Tightbeam.Acp.Adapter.parse_model_ref("gpt-5.6-sol[medium]")
      {"gpt-5.6-sol", "medium"}

      iex> Tightbeam.Acp.Adapter.parse_model_ref("claude-fable-5")
      {"claude-fable-5", nil}
  """
  @spec parse_model_ref(model_ref()) :: {String.t(), String.t() | nil}
  def parse_model_ref(ref) do
    case Regex.run(~r/^(.*?)\[(.*?)\]$/, ref) do
      [_, model, effort] -> {model, effort}
      _ -> {ref, nil}
    end
  end
end
