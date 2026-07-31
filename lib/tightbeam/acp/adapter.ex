defmodule Tightbeam.Acp.Adapter do
  @moduledoc """
  Harness session layer over Acp.Conn. One Adapter per (harness, archetype);
  it owns a Conn and routes session/update chunks by sessionId to the turn
  currently prompting each session.

  Adapter rules (spec §Adapter selection; the SOURCE OF TRUTH mirrored from the
  TS reference harness.ts):
  1. Apply the selected model immediately after session/new. After session/load,
     read the harness's current model and return it to the caller; a stored record
     is a projection and must never be pushed over the loaded owner's value.
  2. Model via session/set_config_option {configId:"model"} with a BARE name;
     effort rides as "model[effort]" split and applied via the harness's effort
     config id.
  3. Permission requests auto-allowed by Conn (YOLO); sessions run in the
     harness's bypass mode set at session/new time.
  """

  use GenServer
  require Logger
  alias Tightbeam.{Harness}
  alias Tightbeam.Acp.Conn

  @gate_attestation_timeout 120_000
  # Boot may spend 60s initializing ACP before the separate 120s gate
  # deadline starts. Residency calls queue behind handle_continue, so their
  # caller budget must clear the full boot boundary.
  @boot_boundary_timeout 185_000
  @gate_marker "[gate: tightbeam-probe]"
  @gate_prompt "Run exactly this command with your shell tool (no other arguments): tightbeam-gate-probe . If the command is refused or blocked by anything, report the exact refusal message you received, verbatim, then stop; do not retry or work around it."
  @gate_raw_update_limit 20
  @gate_raw_log_limit 4_096

  defstruct [
    :conn,
    :preset,
    :harness,
    :cwd,
    :stderr_path,
    :on_auth_event,
    :on_subagent_event,
    stderr_offset: 0,
    chunks: %{},
    progress: %{},
    subagent_tasks: %{},
    known: MapSet.new(),
    models: %{}
  ]

  ## Client

  @type adapter :: GenServer.server()

  @typedoc "Model reference — bare name or \"name[effort]\" (see parse_model_ref/1)."
  @type model_ref :: String.t()

  @doc """
  Start the adapter. Required: `:harness` (a registered harness id), `:cmd` (adapter
  argv), `:home` (agent-home dir, exported via the harness's home env var),
  `:cwd`. Optional: `:env`, `:stderr_path`, `:gate_log_path`, `:name`.

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
  @spec new_session(adapter(), model_ref(), String.t(), [map()], String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def new_session(adapter, model, cwd, mcp_servers, guidance),
    do: call(adapter, {:new_session, model, cwd, mcp_servers, guidance}, 30_000)

  @doc "Adopt an existing harness session and return the model the harness reports as current."
  @spec load_session(adapter(), String.t(), model_ref(), String.t(), [map()], String.t()) ::
          {:ok, model_ref()} | {:error, term()}
  def load_session(adapter, session_id, model, cwd, mcp_servers, guidance),
    do: call(adapter, {:load_session, session_id, model, cwd, mcp_servers, guidance}, 30_000)

  @doc "Best-effort ACP teardown for one harness session; adapter failures never escape the caller."
  @spec close_session(adapter(), String.t()) :: :ok | {:error, term()}
  def close_session(adapter, session_id) do
    GenServer.call(adapter, {:close_session, session_id}, 65_000)
  rescue
    reason -> {:error, {:adapter_unavailable, reason}}
  catch
    :exit, reason -> {:error, {:adapter_unavailable, reason}}
  end

  # An adapter that cannot BOOT dies in handle_continue, so the turn's first
  # call exits carrying only the death reason — that is how an actionable spawn
  # error ("Permission denied") used to reach the lane as a bare :task_crash
  # (S4 defect 1). Translating the exit into the DESIGNED
  # {:adapter_unavailable, one-line reason} here — the same shape close_session
  # has always produced — is what puts the reason on the turn row. Every
  # adapter-boundary call the turn path makes goes through this.
  defp call(adapter, message, timeout) do
    GenServer.call(adapter, message, timeout)
  catch
    :exit, reason -> {:error, {:adapter_unavailable, unavailable_reason(reason)}}
  end

  # `:noproc` stays an ATOM: it means the adapter was ALREADY dead when the call
  # went out, so this call carries no reason of its own and the caller should
  # prefer the coordinator's record of the death. Every other exit yields text.
  defp unavailable_reason({:noproc, {GenServer, :call, _args}}), do: :noproc
  defp unavailable_reason({reason, {GenServer, :call, _args}}), do: failure_text(reason)
  defp unavailable_reason(reason), do: failure_text(reason)

  @doc """
  Render an adapter DEATH reason as the one-line turn-facing text. The stderr
  line is the spawn error; the wrapper names what failed while producing it.
  """
  @spec failure_text(term()) :: String.t()
  def failure_text({:adapter_fault, %{reason: reason, stderr: line}}),
    do: one_line("#{inspect(reason)}: #{line}")

  def failure_text(reason), do: one_line(inspect(reason))

  defp one_line(text), do: text |> String.replace(~r/\s*\n\s*/, " ") |> String.trim()

  @doc "Strict adjudication-only model CAS: compare the confirmed owner, then set and read back."
  @spec apply_model_strict(adapter(), String.t(), model_ref(), model_ref()) ::
          {:ok, model_ref()}
          | {:error,
             :model_unavailable
             | :partial_apply
             | :model_readback_unavailable
             | {:stale_model, model_ref()}}
  def apply_model_strict(adapter, session_id, model, prior_model),
    do: GenServer.call(adapter, {:apply_model_strict, session_id, model, prior_model}, 30_000)

  @doc "The last model value confirmed by this serialized harness adapter."
  @spec current_model(adapter(), String.t()) ::
          {:ok, model_ref()}
          | {:error, :model_readback_unavailable | {:adapter_unavailable, term()}}
  def current_model(adapter, session_id),
    do: call(adapter, {:current_model, session_id}, @boot_boundary_timeout)

  @doc "Apply a model selection and surface any explicit harness refusal."
  @spec apply_model(adapter(), String.t(), model_ref()) :: :ok | {:error, term()}
  def apply_model(adapter, session_id, model),
    do: GenServer.call(adapter, {:apply_model, session_id, model}, 30_000)

  @doc """
  Run a turn: sends session/prompt, accumulates agent_message_chunk text while
  this GenServer keeps routing updates, replies when the harness finishes.

  A harness that dies MID-PROMPT kills this adapter before it can reply, so the
  call must be caught like every other adapter-boundary call: otherwise the turn
  task exits and the lane records a bare `:task_crash`, skipping the
  adjudication closure entirely — no hold, no cause, nothing to heal
  (cross-review F1; the spec names runtime failures an adapter-fault form).
  """
  @spec prompt(adapter(), String.t(), String.t(), timeout(), keyword()) ::
          {:ok, %{stop_reason: String.t(), text: String.t()}} | {:error, term()}
  def prompt(
        adapter,
        session_id,
        text,
        timeout \\ Application.get_env(:tightbeam, :turn_timeout_ms, 600_000),
        opts \\ []
      ),
      do: call(adapter, {:prompt, session_id, text, opts}, timeout + 5_000)

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
  @spec knows_session?(adapter(), String.t()) ::
          boolean() | {:error, {:adapter_unavailable, term()}}
  def knows_session?(adapter, session_id) do
    # The BOOT-BOUNDARY budget (task #20): a residency call legally queues
    # behind a slow codex boot, and the old 5s caller budget undercut that queue.
    # A DEAD adapter still fails promptly via :noproc — only a BOOTING one waits.
    GenServer.call(adapter, {:knows_session?, session_id}, @boot_boundary_timeout)
  rescue
    reason -> {:error, {:adapter_unavailable, unavailable_reason(reason)}}
  catch
    :exit, reason -> {:error, {:adapter_unavailable, unavailable_reason(reason)}}
  end

  @doc "The underlying Acp.Conn."
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
    stderr_path = Keyword.get(opts, :stderr_path, "/dev/null")
    # ATTEMPT-SCOPED stderr: the per-key log is opened `2>>` and accumulates
    # across every spawn, so the file's last line can belong to a PREVIOUS
    # attempt. One adapter process is exactly one spawn attempt; recording the
    # size before the port opens makes "the last stderr line of that boot
    # attempt" mean it (S4 defect 1).
    offset = stderr_size(stderr_path)

    try do
      boot(opts, stderr_path, offset)
    rescue
      error ->
        {:stop,
         adapter_failure_reason({:boot_failed, Exception.message(error)}, stderr_path, offset),
         nil}
    end
  end

  defp boot(opts, stderr_path, offset) do
    harness = Keyword.fetch!(opts, :harness)
    module = Harness.module!(harness)
    preset = module.session_config(%{}, "")

    {:ok, conn} =
      Conn.start_link(
        cmd: Keyword.fetch!(opts, :cmd),
        env: Keyword.get(opts, :env, []),
        stderr_path: stderr_path,
        subscriber: self()
      )

    state = %__MODULE__{
      conn: conn,
      preset: preset,
      harness: harness,
      cwd: Keyword.fetch!(opts, :cwd),
      stderr_path: stderr_path,
      stderr_offset: offset,
      on_auth_event: Keyword.get(opts, :on_auth_event),
      on_subagent_event: Keyword.get(opts, :on_subagent_event)
    }

    # A binary that cannot execute still opens the port (the spawn is `sh -c`),
    # so the failure surfaces HERE as {:error, :closed} — no exception to
    # translate. Naming it explicitly is what carries the spawn error out.
    case Conn.request(conn, "initialize", %{
           protocolVersion: 1,
           clientCapabilities: %{fs: %{readTextFile: false, writeTextFile: false}}
         }) do
      {:ok, %{"protocolVersion" => 1}} ->
        gate(opts, state)

      other ->
        {:stop, adapter_failure_reason({:initialize_failed, other}, stderr_path, offset), state}
    end
  end

  defp gate(opts, state) do
    case Keyword.fetch(opts, :probe_cwd) do
      {:ok, probe_cwd} ->
        deadline =
          System.monotonic_time(:millisecond) +
            Keyword.get(opts, :gate_attestation_timeout, @gate_attestation_timeout)

        case gate_attestation(state, probe_cwd, Keyword.fetch!(opts, :probe_model), deadline) do
          {:ok, output} ->
            gate_log(
              opts,
              "gate wiring-check PASS #{@gate_marker} output=#{inspect(output)}"
            )

            adapter_ready(opts)
            {:noreply, state}

          {:error, detail, output, raw_updates} ->
            reason =
              adapter_failure_reason(
                {:gate_attestation_failed, detail},
                state.stderr_path,
                state.stderr_offset
              )

            gate_log(
              opts,
              "[gate-drift] raw_updates=#{gate_raw_updates(raw_updates)}"
            )

            gate_log(
              opts,
              "gate wiring-check FAIL detail=#{detail} output=#{inspect(output)}"
            )

            {:stop, reason, state}
        end

      :error ->
        adapter_ready(opts)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:new_session, model, cwd, mcp_servers, guidance}, _from, state) do
    with {:ok, result} <-
           Conn.request(state.conn, "session/new", %{
             cwd: cwd,
             mcpServers: mcp_servers,
             _meta: Harness.module!(state.harness).session_config(%{}, guidance).meta
           }),
         sid = result["sessionId"],
         {:ok, applied_model} <- apply_model_to_session(state, sid, model),
         :ok <- set_mode(state, sid) do
      state =
        state
        |> put_in([Access.key(:known)], MapSet.put(state.known, sid))
        |> put_in([Access.key(:models), sid], applied_model)

      {:reply, {:ok, sid}, put_in(state.chunks[sid], [])}
    else
      # Refused config (e.g. an unavailable model) is a turn failure with a
      # reason — never a crash of the shared adapter's caller chain.
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:load_session, sid, _model, cwd, mcp_servers, guidance}, _from, state) do
    case Conn.request(state.conn, "session/load", %{
           sessionId: sid,
           cwd: cwd,
           mcpServers: mcp_servers,
           _meta: Harness.module!(state.harness).session_config(%{}, guidance).meta
         }) do
      {:ok, result} ->
        case model_ref_from_config(result, state.preset.effort_config) do
          {:ok, owner_model} ->
            state =
              state
              |> put_in([Access.key(:known)], MapSet.put(state.known, sid))
              |> put_in([Access.key(:models), sid], owner_model)

            {:reply, {:ok, owner_model}, put_in(state.chunks[sid], [])}

          :error ->
            state = %{
              state
              | known: MapSet.delete(state.known, sid),
                models: Map.delete(state.models, sid)
            }

            {:reply, {:error, :model_readback_unavailable}, state}
        end

      {:error, error} ->
        # The harness no longer has this session (lost files, other host…).
        # The caller falls back to a fresh session (pointer reason
        # "fallback") — never a crash, never a silent retry.
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:close_session, sid}, _from, state) do
    case Conn.request(state.conn, "session/close", %{sessionId: sid}) do
      {:ok, _result} ->
        state = %{
          state
          | known: MapSet.delete(state.known, sid),
            models: Map.delete(state.models, sid),
            chunks: Map.delete(state.chunks, sid),
            progress: Map.delete(state.progress, sid)
        }

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_model_strict, sid, model, prior_model}, _from, state) do
    case Map.fetch(state.models, sid) do
      {:ok, ^prior_model} ->
        case strict_apply_with_retry(state, sid, model, prior_model, 3) do
          :ok -> {:reply, {:ok, model}, put_in(state.models[sid], model)}
          error -> {:reply, error, state}
        end

      {:ok, current_model} ->
        {:reply, {:error, {:stale_model, current_model}}, state}

      :error ->
        {:reply, {:error, :model_readback_unavailable}, state}
    end
  end

  def handle_call({:apply_model, sid, model}, _from, state) do
    case apply_model_to_session(state, sid, model) do
      {:ok, applied_model} -> {:reply, :ok, put_in(state.models[sid], applied_model)}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:knows_session?, sid}, _from, state),
    do: {:reply, MapSet.member?(state.known, sid), state}

  def handle_call({:current_model, sid}, _from, state) do
    case Map.fetch(state.models, sid) do
      {:ok, model} -> {:reply, {:ok, model}, state}
      :error -> {:reply, {:error, :model_readback_unavailable}, state}
    end
  end

  def handle_call({:prompt, sid, text, opts}, from, state) do
    start_prompt(state, sid, text, opts, from)
  end

  def handle_call(:conn, _from, state), do: {:reply, state.conn, state}

  defp start_prompt(state, sid, text, opts, from) do
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
    dispatched = make_ref()
    conn_monitor = Process.monitor(state.conn)

    prompt_worker =
      spawn(fn ->
        result =
          Conn.request(
            state.conn,
            "session/prompt",
            %{sessionId: sid, prompt: [%{type: "text", text: text}]},
            timeout: Application.get_env(:tightbeam, :turn_timeout_ms, 600_000),
            notify_dispatched: {parent, {:prompt_dispatched, dispatched}}
          )

        send(parent, {:prompt_done, sid, from, result})
      end)

    receive do
      {:prompt_dispatched, ^dispatched} ->
        Process.demonitor(conn_monitor, [:flush])

      {:DOWN, ^conn_monitor, :process, _pid, _reason} ->
        send(parent, {:prompt_done, sid, from, {:error, :prompt_dispatch_failed}})
    after
      Application.get_env(:tightbeam, :prompt_dispatch_timeout_ms, 60_000) ->
        Process.demonitor(conn_monitor, [:flush])
        Process.exit(prompt_worker, :kill)
        send(parent, {:prompt_done, sid, from, {:error, :prompt_dispatch_failed}})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:acp_notification, "account/updated", params}, state) do
    emit_auth_classification(state, params)
    {:noreply, state}
  end

  def handle_info({:acp_notification, "session/update", params}, state) do
    sid = params["sessionId"]
    update = params["update"] || %{}
    maybe_emit_account_update(state, update)
    state = maybe_emit_subagent_event(state, sid, update)
    state = emit_progress(state, sid, update)
    state = remember_config_model(state, sid, update)

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

  def handle_info({:subagent_event_ingested, event_ref, {:ok, _result}}, state) do
    {:noreply, clear_subagent_task(state, event_ref)}
  end

  def handle_info({:subagent_event_ingested, event_ref, {:error, reason}}, state) do
    {context, state} = pop_subagent_task(state, event_ref)

    Logger.error(
      "subagent event ingestion failed retry=false context=#{inspect(context)} reason=#{inspect(reason)}"
    )

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.subagent_tasks, fn {_event_ref, task} -> task.monitor == monitor end) do
      {event_ref, task} ->
        Logger.error(
          "subagent event ingestion failed retry=false context=#{inspect(task.context)} " <>
            "reason=#{inspect({:task_exit, reason})}"
        )

        {:noreply, %{state | subagent_tasks: Map.delete(state.subagent_tasks, event_ref)}}

      nil ->
        {:noreply, state}
    end
  end

  # The harness OS process died. The Conn survives that (closed, failing
  # pendings) but survival here would WEDGE the org: the coordinator
  # monitors THIS process, so staying alive means no adapter_down row, no
  # generation bump, no fresh adapter — every future turn fails against a
  # dead conn until a deploy. Dying is the contract: :DOWN fires, the
  # death is recorded, the next turn boots a replacement and re-adopts
  # sessions. (Found by the soak driver's A3 audit: an adapter SIGKILL
  # left zero substrate records.)
  def handle_info({:acp_exit, status}, state) do
    reason = adapter_failure_reason({:acp_exit, status}, state.stderr_path, state.stderr_offset)

    # A draining gateway takes its harnesses down with it — that death is
    # lifecycle, not fault (#98). {:shutdown, reason} keeps the detail for the
    # coordinator's adapter_down row while OTP skips the [error] crash report.
    if Tightbeam.Application.draining?() do
      Logger.info("adapter exited with the draining gateway: #{inspect(reason)}")
      {:stop, {:shutdown, reason}, state}
    else
      {:stop, reason, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
  end

  defp maybe_emit_account_update(state, update) do
    emit_auth_classification(state, update)
  end

  defp emit_auth_classification(state, event) do
    with classification when classification != :unknown <-
           Harness.module!(state.harness).classify_auth_event(event),
         handler when is_function(handler, 2) <- state.on_auth_event do
      handler.(classification, event)
    end
  end

  defp maybe_emit_subagent_event(state, sid, update) do
    case state.on_subagent_event do
      handler when is_function(handler, 2) ->
        case handler.(sid, update) do
          {:async, event_ref, pid, context} ->
            monitor = Process.monitor(pid)

            state =
              put_in(state.subagent_tasks[event_ref], %{
                monitor: monitor,
                context: context
              })

            send(pid, {:consume_subagent_event, event_ref, self()})
            state

          {:error, context, reason} ->
            Logger.error(
              "subagent event ingestion failed retry=false context=#{inspect(context)} " <>
                "reason=#{inspect(reason)}"
            )

            state

          _other ->
            state
        end

      _other ->
        state
    end
  end

  defp clear_subagent_task(state, event_ref) do
    {_context, state} = pop_subagent_task(state, event_ref)
    state
  end

  defp pop_subagent_task(state, event_ref) do
    case Map.pop(state.subagent_tasks, event_ref) do
      {nil, tasks} ->
        {%{event_ref: event_ref}, %{state | subagent_tasks: tasks}}

      {%{monitor: monitor, context: context}, tasks} ->
        Process.demonitor(monitor, [:flush])
        {context, %{state | subagent_tasks: tasks}}
    end
  end

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

  defp apply_model_to_session(state, sid, model_ref) do
    apply_model_to_session(state, sid, model_ref, fn method, params ->
      Conn.request(state.conn, method, params)
    end)
  end

  defp apply_model_to_session(state, sid, model_ref, request) do
    {model, effort} = parse_model_ref(model_ref)

    with {:ok, base_result} <-
           map_model_refusal(
             request.("session/set_config_option", %{
               sessionId: sid,
               configId: "model",
               value: model
             })
           ),
         {:ok, effort_result} <-
           (if effort do
              request.("session/set_config_option", %{
                sessionId: sid,
                configId: state.preset.effort_config,
                value: effort
              })
            else
              {:ok, base_result}
            end) do
      case model_ref_from_config(effort_result, state.preset.effort_config) do
        {:ok, applied_model} -> {:ok, applied_model}
        :error -> {:ok, model_ref}
      end
    end
  end

  # The adapter's own refusal of a model value — JSON-RPC -32602 Invalid params,
  # recorded live 2026-07-28: the harness ACP adapter refused the platform id
  # `gpt-5.1-codex` at `session/set_config_option {configId: "model"}` — is a
  # model decision, not an adapter fault, and it must say so in the house
  # vocabulary (`:model_unavailable`, the word `strict_apply/4` already uses)
  # instead of passing the raw envelope through to be recorded as an
  # unclassifiable harness error. Every other shape keeps the fail-loud raw
  # passthrough.
  defp map_model_refusal({:error, %{"code" => -32602}}), do: {:error, :model_unavailable}
  defp map_model_refusal(result), do: result

  defp strict_apply_with_retry(state, sid, model_ref, prior_model, attempts) do
    case strict_apply(state, sid, model_ref, prior_model) do
      {:error, :model_unavailable} when attempts > 1 ->
        strict_apply_with_retry(state, sid, model_ref, prior_model, attempts - 1)

      result ->
        result
    end
  end

  defp strict_apply(state, sid, model_ref, prior_model) do
    {model, effort} = parse_model_ref(model_ref)

    case Conn.request(state.conn, "session/set_config_option", %{
           sessionId: sid,
           configId: "model",
           value: model
         }) do
      {:ok, base_result} ->
        effort_result =
          if effort do
            Conn.request(state.conn, "session/set_config_option", %{
              sessionId: sid,
              configId: state.preset.effort_config,
              value: effort
            })
          else
            {:ok, base_result}
          end

        if read_back?(base_result, "model", model) and
             match?({:ok, _}, effort_result) and
             (is_nil(effort) or
                read_back?(elem(effort_result, 1), state.preset.effort_config, effort)) do
          :ok
        else
          {prior_base, _prior_effort} = parse_model_ref(prior_model)

          _ =
            Conn.request(state.conn, "session/set_config_option", %{
              sessionId: sid,
              configId: "model",
              value: prior_base
            })

          {:error, :partial_apply}
        end

      {:error, _} ->
        {:error, :model_unavailable}
    end
  end

  defp read_back?(%{"configOptions" => options}, id, expected) when is_list(options) do
    Enum.any?(options, fn option ->
      (option["id"] || option["configId"]) == id and
        (option["currentValue"] || option["value"]) == expected
    end)
  end

  defp read_back?(_, _id, _expected), do: false

  defp remember_config_model(
         state,
         sid,
         %{"sessionUpdate" => "config_option_update", "configOptions" => options}
       ) do
    case model_ref_from_config(%{"configOptions" => options}, state.preset.effort_config) do
      {:ok, model} -> put_in(state.models[sid], model)
      :error -> state
    end
  end

  defp remember_config_model(state, _sid, _update), do: state

  defp model_ref_from_config(%{"configOptions" => options}, effort_id)
       when is_list(options) do
    model = config_value(options, "model")
    effort = config_value(options, effort_id)

    cond do
      not is_binary(model) ->
        :error

      effort in [nil, "", "default"] ->
        {:ok, model}

      true ->
        {:ok, "#{model}[#{effort}]"}
    end
  end

  defp model_ref_from_config(_, _effort_id), do: :error

  defp config_value(options, id) do
    case Enum.find(options, &((&1["id"] || &1["configId"]) == id)) do
      nil -> nil
      option -> option["currentValue"] || option["value"]
    end
  end

  defp set_mode(state, sid) do
    _ =
      Conn.request(state.conn, "session/set_mode", %{
        sessionId: sid,
        modeId: state.preset.permission_mode
      })

    :ok
  end

  defp adapter_ready(opts) do
    # Boot completed — the only trustworthy health signal under lazy boot
    # (spawn success means nothing). The coordinator closes its circuit here.
    with ready when is_function(ready, 0) <- Keyword.get(opts, :on_ready), do: ready.()
  end

  defp gate_attestation(state, probe_cwd, probe_model, deadline) do
    request = fn method, params -> gate_request(state.conn, method, params, deadline) end

    with {:ok, result} <- request.("session/new", %{cwd: probe_cwd, mcpServers: []}),
         sid = result["sessionId"],
         {:ok, _applied_model} <- apply_model_to_session(state, sid, probe_model, request),
         {:ok, _} <-
           request.("session/set_mode", %{
             sessionId: sid,
             modeId: state.preset.permission_mode
           }) do
      gate_prompt(state.conn, sid, deadline)
    else
      {:error, :deadline} -> {:error, :deadline, "", []}
      {:error, _error} -> {:error, :turn_error, "", []}
    end
  end

  defp gate_request(conn, method, params, deadline) do
    case gate_remaining(deadline) do
      remaining when remaining <= 0 ->
        {:error, :deadline}

      remaining ->
        case Conn.request(conn, method, params, timeout: remaining) do
          {:error, :timeout} -> {:error, :deadline}
          result -> result
        end
    end
  end

  defp gate_prompt(conn, sid, deadline) do
    case gate_remaining(deadline) do
      remaining when remaining <= 0 ->
        {:error, :deadline, "", []}

      remaining ->
        parent = self()

        Task.start(fn ->
          result =
            gate_request(
              conn,
              "session/prompt",
              %{sessionId: sid, prompt: [%{type: "text", text: @gate_prompt}]},
              deadline
            )

          send(parent, {:gate_attestation_prompt_done, sid, result})
        end)

        timer = Process.send_after(self(), :gate_attestation_deadline, remaining)
        gate_prompt_wait(sid, timer, {[], []})
    end
  end

  defp gate_prompt_wait(sid, timer, {output, raw_updates}) do
    receive do
      {:acp_notification, "session/update", %{"sessionId" => ^sid, "update" => update}} ->
        gate_prompt_wait(
          sid,
          timer,
          {
            gate_update_output(update) ++ output,
            [update | raw_updates] |> Enum.take(@gate_raw_update_limit)
          }
        )

      {:acp_notification, _method, _params} ->
        gate_prompt_wait(sid, timer, {output, raw_updates})

      {:gate_attestation_prompt_done, ^sid, result} ->
        cancel_gate_timer(timer)
        collected = output |> Enum.reverse() |> Enum.join()

        case result do
          {:ok, _} ->
            if String.contains?(collected, @gate_marker),
              do: {:ok, collected},
              else: {:error, :no_marker, collected, raw_updates}

          {:error, :deadline} ->
            {:error, :deadline, collected, raw_updates}

          {:error, _error} ->
            {:error, :turn_error, collected, raw_updates}
        end

      :gate_attestation_deadline ->
        {:error, :deadline, output |> Enum.reverse() |> Enum.join(), raw_updates}

      {:acp_exit, _status} ->
        cancel_gate_timer(timer)
        {:error, :turn_error, output |> Enum.reverse() |> Enum.join(), raw_updates}
    end
  end

  defp gate_update_output(%{
         "sessionUpdate" => "agent_message_chunk",
         "content" => %{"text" => text}
       })
       when is_binary(text),
       do: [text]

  defp gate_update_output(%{"sessionUpdate" => kind, "content" => content})
       when kind in ["tool_call", "tool_call_update"],
       do: [JSON.encode!(content)]

  defp gate_update_output(_update), do: []

  defp gate_raw_updates(raw_updates) do
    raw_updates
    |> Enum.reverse()
    |> JSON.encode!()
    |> String.slice(0, @gate_raw_log_limit)
  end

  defp adapter_failure_reason(reason, stderr_path, offset) do
    case last_stderr_line(stderr_path, offset) do
      nil -> reason
      line -> {:adapter_fault, %{reason: reason, stderr: line}}
    end
  end

  defp stderr_size(stderr_path) do
    case File.stat(stderr_path) do
      {:ok, %{size: size}} -> size
      {:error, _reason} -> 0
    end
  end

  # The 8KiB tail is a cap on how much of THIS attempt's stderr we read; the
  # attempt's start offset is the floor, so nothing from a prior spawn can be
  # reported as this failure's reason.
  defp last_stderr_line(stderr_path, offset) do
    with {:ok, file} <- :file.open(String.to_charlist(stderr_path), [:read, :binary]) do
      try do
        with {:ok, size} <- :file.position(file, :eof),
             true <- size > offset,
             {:ok, _position} <- :file.position(file, max(offset, size - 8_192)),
             {:ok, bytes} <- :file.read(file, 8_192) do
          bytes
          |> String.split("\n", trim: true)
          |> List.last()
        else
          _ -> nil
        end
      after
        :file.close(file)
      end
    else
      _ -> nil
    end
  end

  defp gate_remaining(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp cancel_gate_timer(timer) do
    Process.cancel_timer(timer)

    receive do
      :gate_attestation_deadline -> :ok
    after
      0 -> :ok
    end
  end

  defp gate_log(opts, line) do
    path =
      case Keyword.fetch(opts, :gate_log_path) do
        {:ok, path} ->
          path

        :error ->
          case Keyword.fetch(opts, :stderr_path) do
            {:ok, path} when path != "/dev/null" -> path <> ".gate.log"
            _ -> nil
          end
      end

    if path, do: File.write!(path, line <> "\n", [:append])
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
