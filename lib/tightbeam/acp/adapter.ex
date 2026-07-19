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

  defstruct [:conn, :preset, :cwd, chunks: %{}, progress: %{}, known: MapSet.new()]

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

  @doc """
  Create a fresh harness session, model applied (fable-trap rule), rooted at
  `cwd` — the SESSION's isolated workdir, never a shared/operator directory
  (harnesses load project-level instruction files walking up from cwd; an
  un-isolated cwd leaks the operator's own guidance and files into the
  agent). Returns {:ok, session_id}.
  """
  @spec new_session(adapter(), model_ref(), String.t(), [map()]) :: {:ok, String.t()}
  def new_session(adapter, model, cwd, mcp_servers),
    do: GenServer.call(adapter, {:new_session, model, cwd, mcp_servers}, 30_000)

  @doc "Adopt an existing harness session at its workdir — re-applies the model; never trusts the advertised one."
  @spec load_session(adapter(), String.t(), model_ref(), String.t(), [map()]) ::
          :ok | {:error, term()}
  def load_session(adapter, session_id, model, cwd, mcp_servers),
    do: GenServer.call(adapter, {:load_session, session_id, model, cwd, mcp_servers}, 30_000)

  @doc """
  Run a turn: sends session/prompt, accumulates agent_message_chunk text while
  this GenServer keeps routing updates, replies when the harness finishes.
  """
  @spec prompt(adapter(), String.t(), String.t(), timeout(), keyword()) ::
          {:ok, %{stop_reason: String.t(), text: String.t()}} | {:error, term()}
  def prompt(adapter, session_id, text, timeout \\ 600_000, opts \\ []),
    do: GenServer.call(adapter, {:prompt, session_id, text, opts}, timeout + 5_000)

  @doc """
  Map one ACP session/update to a typing-indicator status line, or :skip.
  Pure — the substrate relays what the harness reports; it never interprets.

      iex> Tightbeam.Acp.Adapter.progress_status(%{"sessionUpdate" => "agent_thought_chunk"})
      {:ok, "Thinking…"}

      iex> Tightbeam.Acp.Adapter.progress_status(%{"sessionUpdate" => "tool_call", "title" => "Read config/runtime.exs"})
      {:ok, "Read config/runtime.exs"}

      iex> Tightbeam.Acp.Adapter.progress_status(%{"sessionUpdate" => "agent_message_chunk"})
      :skip
  """
  @spec progress_status(map()) :: {:ok, String.t()} | :skip
  def progress_status(%{"sessionUpdate" => "agent_thought_chunk"}), do: {:ok, "Thinking…"}

  def progress_status(%{"sessionUpdate" => kind} = update)
      when kind in ["tool_call", "tool_call_update"] do
    case update["title"] || update["kind"] do
      title when is_binary(title) and title != "" -> {:ok, title}
      _ -> if kind == "tool_call", do: {:ok, "Using a tool"}, else: :skip
    end
  end

  def progress_status(_update), do: :skip

  @doc """
  Whether THIS adapter process has created or loaded the harness session —
  the authority for lazy re-adoption. Generation numbers reset across boots
  (a fresh coordinator counts from 1 again), so comparing stamped
  generations can spuriously match across a restart; asking the process
  itself cannot.
  """
  @spec knows_session?(adapter(), String.t()) :: boolean()
  def knows_session?(adapter, session_id), do: GenServer.call(adapter, {:knows_session?, session_id})

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
  def handle_call({:new_session, model, cwd, mcp_servers}, _from, state) do
    with {:ok, result} <-
           Conn.request(state.conn, "session/new", %{cwd: cwd, mcpServers: mcp_servers}),
         sid = result["sessionId"],
         :ok <- apply_model(state, sid, model) do
      _ = Conn.request(state.conn, "session/set_mode", %{sessionId: sid, modeId: state.preset.yolo_mode})
      state = %{state | known: MapSet.put(state.known, sid)}
      {:reply, {:ok, sid}, put_in(state.chunks[sid], [])}
    else
      # Refused config (e.g. an unavailable model) is a turn failure with a
      # reason — never a crash of the shared adapter's caller chain.
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:load_session, sid, model, cwd, mcp_servers}, _from, state) do
    case Conn.request(state.conn, "session/load", %{
           sessionId: sid,
           cwd: cwd,
           mcpServers: mcp_servers
         }) do
      {:ok, _} ->
        # Best-effort: a loaded session already HAS a model. The option's
        # valid set is populated asynchronously in the harness and can lag
        # adapter boot, so a refused re-assert here must never cost the
        # session's memory — continuity outranks the config option.
        _ = apply_model(state, sid, model)
        state = %{state | known: MapSet.put(state.known, sid)}
        {:reply, :ok, put_in(state.chunks[sid], [])}

      {:error, error} ->
        # The harness no longer has this session (lost files, other host…).
        # The caller falls back to a fresh session (pointer reason
        # "fallback") — never a crash, never a silent retry.
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:knows_session?, sid}, _from, state),
    do: {:reply, MapSet.member?(state.known, sid), state}

  def handle_call({:prompt, sid, text, opts}, from, state) do
    state = put_in(state.chunks[sid], [])
    # Per-turn progress channel: {fun, last_status, seq}. Deduped on text so
    # per-token thought chunks emit ONE "Thinking…" until something changes.
    state =
      case Keyword.get(opts, :progress) do
        fun when is_function(fun, 2) -> put_in(state.progress[sid], {fun, nil, 0})
        _ -> state
      end
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
    state = emit_progress(state, sid, update)

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
    state = %{state | progress: Map.delete(state.progress, sid)}
    {:noreply, put_in(state.chunks[sid], [])}
  end

  # The harness OS process died. The Conn survives that (closed, failing
  # pendings) but survival here would WEDGE the org: the coordinator
  # monitors THIS process, so staying alive means no adapter_down row, no
  # generation bump, no fresh adapter — every future turn fails against a
  # dead conn until a deploy. Dying is the contract: :DOWN fires, the
  # death is recorded, the next turn boots a replacement and re-adopts
  # sessions. (Found by the soak driver's A3 audit: an adapter SIGKILL
  # left zero substrate records.)
  def handle_info({:acp_exit, status}, state),
    do: {:stop, {:acp_exit, status}, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # Invoke the per-turn progress fun on status CHANGE only. The fun is fast
  # by contract (an in-memory registry broadcast) — see PATTERNS on shared
  # serializers; anything slower belongs to the turn, not here.
  defp emit_progress(state, sid, update) do
    with {fun, last, seq} <- Map.get(state.progress, sid),
         {:ok, text} when text != last <- progress_status(update) do
      fun.(text, seq + 1)
      put_in(state.progress[sid], {fun, text, seq + 1})
    else
      _ -> state
    end
  end

  ## Model application (the fable-trap rule)

  defp apply_model(state, sid, model_ref) do
    {model, effort} = parse_model_ref(model_ref)

    with {:ok, _} <-
           Conn.request(state.conn, "session/set_config_option", %{
             sessionId: sid,
             configId: "model",
             value: model
           }),
         {:ok, _} <-
           (if effort do
              Conn.request(state.conn, "session/set_config_option", %{
                sessionId: sid,
                configId: state.preset.effort_config,
                value: effort
              })
            else
              {:ok, nil}
            end) do
      :ok
    end
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
