defmodule Tightbeam.Acp.Adapter do
  @moduledoc """
  Harness session layer over Acp.Conn. One Adapter per (harness, archetype);
  it owns a Conn and routes session/update chunks by sessionId to the turn
  currently prompting each session.

  Adapter rules (spec §Adapter selection and the superseding model ruling):
  1. The user's known canonical selection is pushed after session/new,
     session/load, and immediately before each turn. An unknown selection is
     never pushed: a fresh session keeps the harness default and captures it
     when reported, while a loaded session is left unchanged.
  2. Callers pass a `Tightbeam.Model` structure. This module is the seam that
     renders it for the harness: the vendor identifier (family, plus the
     vendor's context variant when there is one) via
     session/set_config_option {configId:"model"}, and the effort — Tightbeam's
     own field — via the harness's effort config id. Nothing outside this
     module builds or reads a packed model string.
  3. Permission requests auto-allowed by Conn (YOLO); sessions run in the
     harness's bypass mode set at session/new time.
  """

  use GenServer
  require Logger
  alias Tightbeam.{Harness, Model}
  alias Tightbeam.Acp.Conn

  # Boot may spend 60s initializing ACP before the separate 120s gate
  # deadline starts. Residency calls queue behind handle_continue, so their
  # caller budget must clear the full boot boundary.
  @boot_boundary_timeout 185_000
  @gate_marker "[gate: tightbeam-probe]"
  @gate_prompt "Run exactly this command with your shell tool (no other arguments): tightbeam-gate-probe . If the command is refused or blocked by anything, report the exact refusal message you received, verbatim, then stop; do not retry or work around it."
  @gate_raw_update_limit 20
  @gate_raw_log_limit 4_096
  # The operation budget matches what this path always offered: a harness reply
  # that arrives inside 30s succeeds, exactly as it did before the deadline was
  # derived. The margin lives OUTSIDE that window -- the caller waits 2s past
  # the operation deadline -- so delivering the structured error costs no
  # success case. Once Conn receives a response, only two local BEAM replies
  # remain (Conn -> Adapter -> caller); they take microseconds idle, but the
  # margin must hold on a loaded scheduler where mailbox residence is real
  # time: with a thin margin an operation timing out at its deadline loses the
  # race and the caller exits instead of receiving the structured error -- the
  # defect this deadline exists to prevent.
  @strict_model_operation_timeout 30_000
  @strict_model_reply_margin 2_000
  @strict_model_call_timeout @strict_model_operation_timeout + @strict_model_reply_margin

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
    models: %{},
    unprompted: MapSet.new(),
    switchable_models: %{},
    config_options: %{}
  ]

  ## Client

  @type adapter :: GenServer.server()

  @typedoc "A model identity. Structured everywhere; rendered only at this seam."
  @type model_ref :: Tightbeam.Model.t()

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
  @spec new_session(adapter(), model_ref() | nil, String.t(), [map()], String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def new_session(adapter, model, cwd, mcp_servers, guidance),
    do: call(adapter, {:new_session, model, cwd, mcp_servers, guidance}, 30_000)

  @doc "Prepare a candidate and report the close outcome when post-create verification fails."
  @spec new_candidate_session(adapter(), model_ref(), String.t(), [map()], String.t()) ::
          {:ok, String.t()}
          | {:error,
             {:session_prepare_failed, term(), String.t(),
              %{status: String.t(), reason: term() | nil}}}
          | {:error, term()}
  def new_candidate_session(adapter, model, cwd, mcp_servers, guidance),
    do: call(adapter, {:new_candidate_session, model, cwd, mcp_servers, guidance}, 30_000)

  def new_session_for_turn(adapter, model, cwd, mcp_servers, guidance),
    do: call(adapter, {:new_session, model, cwd, mcp_servers, guidance, :infinity}, :infinity)

  @doc "Adopt an existing harness session and push the canonical model when it is known."
  @spec load_session(adapter(), String.t(), model_ref() | nil, String.t(), [map()], String.t()) ::
          {:ok, model_ref() | :unknown} | {:error, term()}
  def load_session(adapter, session_id, model, cwd, mcp_servers, guidance),
    do: call(adapter, {:load_session, session_id, model, cwd, mcp_servers, guidance}, 30_000)

  def load_session_for_turn(adapter, session_id, model, cwd, mcp_servers, guidance),
    do:
      call(
        adapter,
        {:load_session, session_id, model, cwd, mcp_servers, guidance, :infinity},
        :infinity
      )

  @doc """
  Move a resident session to a new model without losing its conversation.

  Claude binds its offered-model set when a session starts, so changing the
  projected home cannot make a newly pinned model selectable in that resident
  process. Claude therefore forks the conversation into a fresh session after
  the home is pinned. Harnesses whose model set remains live update the resident
  session in place. Returns the harness session id that owns the next turn.
  """
  @spec switch_model_session(
          adapter(),
          String.t(),
          model_ref(),
          String.t(),
          [map()],
          String.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def switch_model_session(adapter, session_id, model, cwd, mcp_servers, guidance),
    do:
      call(
        adapter,
        {:switch_model_session, session_id, model, cwd, mcp_servers, guidance},
        @boot_boundary_timeout
      )

  @doc "Canonical models the harness currently offers for a history-preserving session switch."
  @spec switchable_models(adapter(), String.t()) ::
          {:ok, [model_ref()]}
          | {:error, :model_capability_unavailable | {:adapter_unavailable, term()}}
  def switchable_models(adapter, session_id),
    do: call(adapter, {:switchable_models, session_id}, @boot_boundary_timeout)

  @doc "Canonical Fast state from the resident harness's latest live config response."
  @spec fast_status(adapter(), String.t()) ::
          {:ok, %{fast: String.t(), option_id: String.t()}}
          | {:error, :fast_unsupported | :runtime_config_unknown | {:adapter_unavailable, term()}}
  def fast_status(adapter, session_id),
    do: call(adapter, {:fast_status, session_id}, @boot_boundary_timeout)

  @doc "Apply canonical Fast on/off through the live option advertised by this adapter."
  @spec apply_fast(adapter(), String.t(), String.t()) ::
          {:ok, %{fast: String.t(), option_id: String.t()}}
          | {:error,
             :fast_unsupported
             | :runtime_config_unknown
             | {:runtime_config_mismatch, String.t()}
             | term()}
  def apply_fast(adapter, session_id, value) when value in ["on", "off"],
    do: call(adapter, {:apply_fast, session_id, value}, @boot_boundary_timeout)

  @doc "Best-effort ACP teardown for one harness session; adapter failures never escape the caller."
  @spec close_session(adapter(), String.t()) :: :ok | {:error, term()}
  def close_session(adapter, session_id) do
    GenServer.call(adapter, {:close_session, session_id}, 65_000)
  rescue
    reason -> {:error, {:adapter_unavailable, reason}}
  catch
    :exit, reason -> {:error, {:adapter_unavailable, reason}}
  end

  @doc "Queue a close request without blocking the caller behind an in-progress boot."
  @spec request_close(adapter()) :: :ok
  def request_close(adapter), do: GenServer.cast(adapter, :close)

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
             | :model_transport_failure
             | :partial_apply
             | :model_readback_unavailable}
  def apply_model_strict(adapter, session_id, model, prior_model) do
    deadline = System.monotonic_time(:millisecond) + @strict_model_operation_timeout

    GenServer.call(
      adapter,
      {:apply_model_strict, session_id, model, prior_model, deadline},
      @strict_model_call_timeout
    )
  end

  @doc "The adapter's cached model value. This does not query the harness owner."
  @spec current_model(adapter(), String.t(), timeout()) ::
          {:ok, model_ref()}
          | {:error, :model_readback_unavailable | {:adapter_unavailable, term()}}
  def current_model(adapter, session_id, timeout \\ @boot_boundary_timeout),
    do: call(adapter, {:current_model, session_id}, timeout)

  @doc "Forget cached residency so the next session use must reload from the harness owner."
  @spec forget_model_residency(adapter(), String.t()) ::
          :ok | {:error, {:adapter_unavailable, term()}}
  def forget_model_residency(adapter, session_id),
    do: call(adapter, {:forget_model_residency, session_id}, @boot_boundary_timeout)

  @doc "Apply a model selection and surface any explicit harness refusal."
  @spec apply_model(adapter(), String.t(), model_ref()) :: :ok | {:error, term()}
  def apply_model(adapter, session_id, model),
    do: GenServer.call(adapter, {:apply_model, session_id, model}, 30_000)

  def apply_model_for_turn(adapter, session_id, model),
    do: call(adapter, {:apply_model, session_id, model, :infinity}, :infinity)

  @doc """
  Run a turn: sends session/prompt, accumulates agent_message_chunk text while
  this GenServer keeps routing updates, and preserves the public ACP messageId
  boundary between distinct assistant messages before the harness finishes.

  A harness that dies MID-PROMPT kills this adapter before it can reply, so the
  call must be caught like every other adapter-boundary call: otherwise the turn
  task exits and the lane records a bare `:task_crash`, skipping the
  adjudication closure entirely — no hold, no cause, nothing to heal
  (cross-review F1; the spec names runtime failures an adapter-fault form).
  """
  @spec prompt(adapter(), String.t(), String.t(), keyword()) ::
          {:ok,
           %{
             stop_reason: String.t(),
             text: String.t(),
             messages: [%{message_id: String.t() | nil, text: String.t()}]
           }}
          | {:error, term()}
  def prompt(adapter, session_id, text, opts \\ []),
    do: call(adapter, {:prompt, session_id, text, opts}, :infinity)

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

  def knows_session_for_turn?(adapter, session_id),
    do: call(adapter, {:knows_session?, session_id}, :infinity)

  def current_model_for_turn(adapter, session_id),
    do: call(adapter, {:current_model, session_id}, :infinity)

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

    # A LAUNCH waits out adapter provisioning in flight for this host (a
    # no-op call in the permanent steady state): npm churn in the shared
    # adapters dir can momentarily unlink an installed binary, and exec'ing
    # into that window dies with an ENOENT whose cause is two seconds of
    # internal housekeeping. Bounded by the provision's own completion; a
    # launch that then still finds nothing fails with the ENOENT it earned.
    :ok = Tightbeam.Spinup.Flight.await(Tightbeam.Placement.local_host_name())

    {:ok, conn} =
      Conn.start_link(
        cmd: Keyword.fetch!(opts, :cmd),
        env: Keyword.get(opts, :env, []),
        stderr_path: stderr_path,
        subscriber: self()
      )

    case Keyword.fetch(opts, :harness_process_launch_id) do
      {:ok, launch_id} ->
        db = Keyword.get(opts, :db, Tightbeam.DB)

        case Tightbeam.HarnessProcess.capture_identity(db, launch_id, :infinity) do
          :ok -> :ok
          {:error, reason} -> raise "harness process identity unavailable: #{inspect(reason)}"
        end

      :error ->
        :ok
    end

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
    case Conn.request(
           conn,
           "initialize",
           %{
             protocolVersion: 1,
             clientCapabilities: %{fs: %{readTextFile: false, writeTextFile: false}}
           },
           timeout: :infinity
         ) do
      {:ok, %{"protocolVersion" => 1}} ->
        case listener_guard(opts, module, harness, state, stderr_path, offset) do
          :ok -> gate(opts, state)
          stop -> stop
        end

      other ->
        {:stop, adapter_failure_reason({:initialize_failed, other}, stderr_path, offset), state}
    end
  end

  # Rails-critical launch invariant 3 (ZERO LISTEN sockets in the launched process group), asserted
  # AFTER `initialize` returns — the harness is fully booted by the time it answers, so a listener
  # it binds DURING boot is now observable. A pre-initialize probe raced the bind: OpenCode's
  # :4096 HTTP server comes up ~0.3–1.1s after spawn, AFTER `capture_identity`. Fail-closed: a
  # listener (or an inconclusive probe) refuses the launch. Applies automatically to the :shim
  # harness class (`Harness.requires_zero_listeners?/1`); a launch with no recorded process group
  # cannot be probed and is skipped here.
  #
  # RESIDUAL (honest, unclosable by this mechanism): even a settle-window probe cannot catch a
  # listener bound strictly AFTER the last sample. That gap is input for the go-live threat-model
  # adjudication, not something the assert can eliminate.
  defp listener_guard(opts, module, harness, state, stderr_path, offset) do
    with true <- Harness.requires_zero_listeners?(module),
         {:ok, launch_id} <- Keyword.fetch(opts, :harness_process_launch_id) do
      db = Keyword.get(opts, :db, Tightbeam.DB)

      case Tightbeam.HarnessProcess.assert_zero_listeners(db, launch_id) do
        :ok ->
          :ok

        {:error, reason} ->
          {:stop,
           adapter_failure_reason({:listener_present, harness, reason}, stderr_path, offset),
           state}
      end
    else
      _ -> :ok
    end
  end

  defp gate(opts, state) do
    case Keyword.fetch(opts, :probe_cwd) do
      {:ok, probe_cwd} ->
        case gate_attestation(state, probe_cwd, Keyword.fetch!(opts, :probe_model)) do
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
    new_session_reply(state, model, cwd, mcp_servers, guidance, 60_000, false)
  end

  def handle_call({:new_candidate_session, model, cwd, mcp_servers, guidance}, _from, state) do
    new_session_reply(state, model, cwd, mcp_servers, guidance, 60_000, true)
  end

  def handle_call(
        {:new_session, model, cwd, mcp_servers, guidance, request_timeout},
        _from,
        state
      ) do
    new_session_reply(state, model, cwd, mcp_servers, guidance, request_timeout, false)
  end

  def handle_call({:load_session, sid, model, cwd, mcp_servers, guidance}, _from, state) do
    load_session_reply(state, sid, model, cwd, mcp_servers, guidance, 60_000)
  end

  def handle_call(
        {:load_session, sid, model, cwd, mcp_servers, guidance, request_timeout},
        _from,
        state
      ) do
    load_session_reply(state, sid, model, cwd, mcp_servers, guidance, request_timeout)
  end

  def handle_call(
        {:switch_model_session, sid, model, cwd, mcp_servers, guidance},
        _from,
        state
      ) do
    case state.preset.resident_model_switch do
      :fork ->
        if MapSet.member?(state.unprompted, sid) do
          {:reply, {:error, :fork_requires_prompted_session}, state}
        else
          fork_model_session_reply(state, sid, model, cwd, mcp_servers, guidance, 30_000)
        end

      :in_place ->
        switch_model_in_place_reply(state, sid, model, 30_000)
    end
  end

  def handle_call({:close_session, sid}, _from, state) do
    case Conn.request(state.conn, "session/close", %{sessionId: sid}) do
      {:ok, _result} ->
        state = %{
          state
          | known: MapSet.delete(state.known, sid),
            models: Map.delete(state.models, sid),
            unprompted: MapSet.delete(state.unprompted, sid),
            switchable_models: Map.delete(state.switchable_models, sid),
            config_options: Map.delete(state.config_options, sid),
            chunks: Map.delete(state.chunks, sid),
            progress: Map.delete(state.progress, sid)
        }

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_model_strict, sid, model, prior_model, caller_deadline}, _from, state) do
    case Map.fetch(state.models, sid) do
      {:ok, ^prior_model} ->
        case strict_apply(state, sid, model, caller_deadline) do
          :ok -> {:reply, {:ok, model}, put_in(state.models[sid], model)}
          error -> {:reply, error, drop_model_residency(state, sid)}
        end

      {:ok, _cached_model} ->
        # Cache disagreement proves only that the cache cannot justify this
        # mutation. It does not reveal the harness owner's current value.
        {:reply, {:error, :model_readback_unavailable}, drop_model_residency(state, sid)}

      :error ->
        {:reply, {:error, :model_readback_unavailable}, state}
    end
  end

  def handle_call({:apply_model, sid, model}, _from, state) do
    case apply_model_to_session(state, sid, model) do
      {:ok, applied_model} -> {:reply, :ok, put_in(state.models[sid], applied_model)}
      error -> {:reply, error, drop_model_residency(state, sid)}
    end
  end

  def handle_call({:apply_model, sid, model, request_timeout}, _from, state) do
    case apply_model_to_session(state, sid, model, request_timeout) do
      {:ok, applied_model} -> {:reply, :ok, put_in(state.models[sid], applied_model)}
      error -> {:reply, error, drop_model_residency(state, sid)}
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

  def handle_call({:switchable_models, sid}, _from, state) do
    case Map.fetch(state.switchable_models, sid) do
      {:ok, models} -> {:reply, {:ok, models}, state}
      :error -> {:reply, {:error, :model_capability_unavailable}, state}
    end
  end

  def handle_call({:fast_status, sid}, _from, state) do
    {:reply, canonical_fast_status(state, sid), state}
  end

  def handle_call({:apply_fast, sid, requested}, _from, state) do
    with {:ok, option} <- advertised_fast_option(state, sid),
         {:ok, wire_value} <- fast_wire_value(option, requested) do
      case Conn.request(
             state.conn,
             "session/set_config_option",
             %{sessionId: sid, configId: option_id(option), value: wire_value},
             timeout: 30_000
           ) do
        {:ok, result} ->
          state = remember_config_options(state, sid, result)

          reply =
            case canonical_fast_status(state, sid) do
              {:ok, %{fast: ^requested} = actual} -> {:ok, actual}
              {:ok, %{fast: actual}} -> {:error, {:runtime_config_mismatch, actual}}
              {:error, _reason} -> {:error, :runtime_config_unknown}
            end

          {:reply, reply, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:forget_model_residency, sid}, _from, state),
    do: {:reply, :ok, drop_model_residency(state, sid)}

  def handle_call({:prompt, sid, text, opts}, from, state) do
    start_prompt(state, sid, text, opts, from)
  end

  def handle_call(:conn, _from, state), do: {:reply, state.conn, state}

  defp switch_model_in_place_reply(state, sid, model, request_timeout) do
    case apply_verified_in_place_model(state, sid, model, request_timeout) do
      {:ok, applied_model} ->
        {:reply, {:ok, sid}, put_in(state.models[sid], applied_model)}

      {:error, {:runtime_config_mismatch, %Model{} = actual}} = error ->
        {:reply, error, put_in(state.models[sid], actual)}

      {:error, :model_unavailable} = error ->
        {:reply, error, state}

      {:error, reason} ->
        {:reply, {:error, {:runtime_config_unknown, reason}}, drop_model_residency(state, sid)}
    end
  end

  defp apply_verified_in_place_model(state, sid, %Model{} = model, request_timeout) do
    value = Model.to_ref(model)

    case map_switch_model_refusal(
           Conn.request(
             state.conn,
             "session/set_config_option",
             %{sessionId: sid, configId: "model", value: value},
             timeout: request_timeout
           )
         ) do
      {:ok, model_result} ->
        cond do
          not read_back?(model_result, "model", value) ->
            verified_model_mismatch(model_result, state.preset)

          true ->
            case apply_verified_effort(
                   state,
                   sid,
                   model.effort,
                   model_result,
                   request_timeout
                 ) do
              {:ok, _verified_result} -> {:ok, model}
              {:error, {:runtime_config_mismatch, %Model{}}} = mismatch -> mismatch
              {:error, _reason} = error -> error
            end
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp new_session_reply(
         state,
         model,
         cwd,
         mcp_servers,
         guidance,
         request_timeout,
         report_cleanup?
       ) do
    case Conn.request(
           state.conn,
           "session/new",
           %{
             cwd: cwd,
             mcpServers: mcp_servers,
             _meta: Harness.module!(state.harness).session_config(%{}, guidance).meta
           },
           timeout: request_timeout
         ) do
      {:ok, %{"sessionId" => sid} = result} when is_binary(sid) ->
        with {:ok, applied_model} <-
               establish_new_session_model(state, sid, model, result, request_timeout),
             :ok <- set_mode(state, sid, request_timeout) do
          state =
            state
            |> put_in([Access.key(:known)], MapSet.put(state.known, sid))
            |> remember_model(sid, applied_model)
            |> remember_switchable_models(sid, result)
            |> remember_config_options(sid, result)
            |> put_in([Access.key(:unprompted)], MapSet.put(state.unprompted, sid))

          {:reply, {:ok, sid}, put_in(state.chunks[sid], [])}
        else
          {:error, error} ->
            if report_cleanup? do
              cleanup = close_failed_new_session(state, sid)
              {:reply, {:error, {:session_prepare_failed, error, sid, cleanup}}, state}
            else
              {:reply, {:error, error}, state}
            end
        end

      {:ok, result} ->
        {:reply, {:error, {:invalid_new_session_response, result}}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  defp close_failed_new_session(state, sid) do
    case Conn.request(state.conn, "session/close", %{sessionId: sid}) do
      {:ok, _result} -> %{status: "verified", reason: nil}
      {:error, reason} -> %{status: "unverified", reason: reason}
    end
  end

  defp load_session_reply(state, sid, model, cwd, mcp_servers, guidance, request_timeout) do
    case Conn.request(
           state.conn,
           "session/load",
           %{
             sessionId: sid,
             cwd: cwd,
             mcpServers: mcp_servers,
             _meta: Harness.module!(state.harness).session_config(%{}, guidance).meta
           },
           timeout: request_timeout
         ) do
      {:ok, result} ->
        state =
          state
          |> put_in([Access.key(:known)], MapSet.put(state.known, sid))
          |> put_in([Access.key(:models)], Map.delete(state.models, sid))
          |> put_in([Access.key(:unprompted)], MapSet.delete(state.unprompted, sid))
          |> remember_switchable_models(sid, result)
          |> remember_config_options(sid, result)
          |> put_in([Access.key(:chunks), sid], [])

        case model do
          %Model{} = model ->
            case apply_model_to_session(state, sid, model, request_timeout) do
              {:ok, applied_model} ->
                {:reply, {:ok, applied_model}, put_in(state.models[sid], applied_model)}

              {:error, reason} ->
                {:reply, {:error, {:model_apply_failed, reason}},
                 drop_model_residency(state, sid)}
            end

          _unknown ->
            {:reply, {:ok, :unknown}, state}
        end

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  defp fork_model_session_reply(
         state,
         sid,
         model,
         cwd,
         mcp_servers,
         guidance,
         request_timeout
       ) do
    case Conn.request(
           state.conn,
           "session/fork",
           %{
             sessionId: sid,
             cwd: cwd,
             mcpServers: mcp_servers,
             _meta: Harness.module!(state.harness).session_config(%{}, guidance).meta
           },
           timeout: request_timeout
         ) do
      {:ok, %{"sessionId" => new_sid} = result} when new_sid != sid ->
        with {:ok, applied_model} <-
               apply_fork_model(state, new_sid, model, result, request_timeout),
             :ok <- set_mode(state, new_sid, request_timeout) do
          state =
            state
            |> put_in([Access.key(:known)], MapSet.put(state.known, new_sid))
            |> remember_model(new_sid, applied_model)
            |> remember_switchable_models(new_sid, result)
            |> remember_config_options(new_sid, result)
            |> put_in([Access.key(:chunks), new_sid], [])

          {:reply, {:ok, new_sid}, state}
        else
          {:error, reason} ->
            close_failed_fork(state, new_sid)
            {:reply, {:error, {:model_apply_failed, reason}}, state}
        end

      {:ok, %{"sessionId" => ^sid}} ->
        {:reply, {:error, :fork_did_not_create_new_session}, state}

      {:ok, result} ->
        {:reply, {:error, {:invalid_fork_response, result}}, state}

      {:error, error} ->
        {:reply, {:error, map_fork_error(error)}, state}
    end
  end

  # Claude's alias vocabulary changes meaning across adapter releases. The
  # canonical model is therefore always the first candidate; offered aliases
  # are fallback candidates only. Neither a successful RPC nor the static alias
  # table proves what ran. Only the public config readback -- currentValue plus
  # the selected option's init-derived name/description -- may confirm the
  # requested canonical identity before the caller projects it into the DB.
  defp apply_fork_model(state, sid, %Model{} = model, offered, request_timeout) do
    with {:ok, model_result} <-
           apply_fork_model_candidates(state, sid, model, offered, request_timeout),
         {:ok, _verified_result} <-
           apply_verified_effort(state, sid, model.effort, model_result, request_timeout) do
      {:ok, model}
    end
  end

  defp apply_fork_model_candidates(state, sid, model, offered, request_timeout) do
    state.preset
    |> model_value_candidates(offered, model)
    |> try_fork_model_candidates(state, sid, model, request_timeout)
  end

  defp try_fork_model_candidates([], _state, _sid, _model, _request_timeout),
    do: {:error, :model_unavailable}

  defp try_fork_model_candidates(
         [value | remaining],
         state,
         sid,
         model,
         request_timeout
       ) do
    result =
      map_switch_model_refusal(
        Conn.request(
          state.conn,
          "session/set_config_option",
          %{sessionId: sid, configId: "model", value: value},
          timeout: request_timeout
        )
      )

    case result do
      {:ok, model_result} ->
        if readback_confirms_model?(model_result, state.preset, model) do
          {:ok, model_result}
        else
          try_fork_model_candidates(remaining, state, sid, model, request_timeout)
        end

      {:error, :model_unavailable} ->
        try_fork_model_candidates(remaining, state, sid, model, request_timeout)

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_verified_effort(_state, _sid, nil, model_result, _request_timeout),
    do: {:ok, model_result}

  defp apply_verified_effort(state, sid, effort, _model_result, request_timeout) do
    case Conn.request(
           state.conn,
           "session/set_config_option",
           %{sessionId: sid, configId: state.preset.effort_config, value: effort},
           timeout: request_timeout
         ) do
      {:ok, effort_result} ->
        if read_back?(effort_result, state.preset.effort_config, effort),
          do: {:ok, effort_result},
          else: verified_model_mismatch(effort_result, state.preset)

      {:error, _reason} = error ->
        error
    end
  end

  defp verified_model_mismatch(result, preset) do
    case model_ref_from_config(result, preset.effort_config) do
      {:ok, actual} -> {:error, {:runtime_config_mismatch, actual}}
      :error -> {:error, :model_readback_unavailable}
    end
  end

  defp map_fork_error(%{"code" => -32_002}), do: :fork_requires_prompted_session
  defp map_fork_error(error), do: error

  defp map_switch_model_refusal({:error, %{"code" => -32_602}}),
    do: {:error, :model_unavailable}

  defp map_switch_model_refusal({:error, %{"message" => message}} = error)
       when is_binary(message) do
    if String.contains?(String.downcase(message), "invalid value for config option model"),
      do: {:error, :model_unavailable},
      else: error
  end

  defp map_switch_model_refusal(result), do: result

  defp close_failed_fork(state, sid) do
    case Conn.request(state.conn, "session/close", %{sessionId: sid}) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to close rejected fork #{sid}: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_cast(:close, state) do
    if state.conn, do: Conn.close(state.conn)
    {:stop, :normal, state}
  end

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
            timeout: :infinity,
            notify_dispatched: {parent, {:prompt_dispatched, dispatched}}
          )

        send(parent, {:prompt_done, sid, from, result})
      end)

    receive do
      {:prompt_dispatched, ^dispatched} ->
        Process.demonitor(conn_monitor, [:flush])

      {:DOWN, ^conn_monitor, :process, _pid, _reason} ->
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
      message_id = assistant_message_id(update)

      if is_binary(text) and Map.has_key?(state.chunks, sid) do
        {:noreply,
         update_in(state.chunks[sid], &accumulate_assistant_chunk(&1, message_id, text))}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:prompt_done, sid, from, result}, state) do
    messages = state.chunks |> Map.get(sid, []) |> assistant_messages()
    text = Enum.map_join(messages, & &1.text)

    reply =
      case result do
        {:ok, response} ->
          {:ok,
           %{stop_reason: response["stopReason"] || "unknown", text: text, messages: messages}}

        {:error, reason} ->
          {:error, reason}
      end

    GenServer.reply(from, reply)
    state = %{state | progress: Map.delete(state.progress, sid)}

    state =
      if match?({:ok, _response}, result),
        do: %{state | unprompted: MapSet.delete(state.unprompted, sid)},
        else: state

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
  # ACP's public `messageId` is the only boundary authority. Claude and Codex
  # stamp every chunk from one assistant message with the same stable id. A
  # changed id starts a new message record; an absent id preserves the legacy
  # one-message accumulator instead of guessing from content or tool traffic.
  defp assistant_message_id(%{"messageId" => id}) when is_binary(id) and id != "", do: id
  defp assistant_message_id(_update), do: nil

  defp accumulate_assistant_chunk(
         [%{message_id: message_id, chunks: chunks} | rest],
         message_id,
         text
       ),
       do: [%{message_id: message_id, chunks: [text | chunks]} | rest]

  defp accumulate_assistant_chunk(groups, message_id, text),
    do: [%{message_id: message_id, chunks: [text]} | groups]

  defp assistant_messages([]), do: [%{message_id: nil, text: ""}]

  defp assistant_messages(groups) do
    groups
    |> Enum.reverse()
    |> Enum.map(fn %{message_id: message_id, chunks: chunks} ->
      %{message_id: message_id, text: chunks |> Enum.reverse() |> Enum.join()}
    end)
  end

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

  defp establish_new_session_model(state, sid, %Model{} = model, _result, request_timeout),
    do: apply_model_to_session(state, sid, model, request_timeout)

  defp establish_new_session_model(state, _sid, _unknown, result, _request_timeout) do
    case model_ref_from_config(result, state.preset.effort_config) do
      {:ok, reported_model} -> {:ok, reported_model}
      :error -> {:ok, :unknown}
    end
  end

  defp remember_model(state, sid, %Model{} = model),
    do: put_in(state.models[sid], model)

  defp remember_model(state, sid, _unknown),
    do: put_in(state.models, Map.delete(state.models, sid))

  defp apply_model_to_session(state, sid, model_ref) do
    apply_model_to_session(state, sid, model_ref, 60_000)
  end

  defp apply_model_to_session(state, sid, model_ref, request_timeout)
       when is_integer(request_timeout) or request_timeout == :infinity do
    apply_model_to_session(state, sid, model_ref, fn method, params ->
      Conn.request(state.conn, method, params, timeout: request_timeout)
    end)
  end

  defp apply_model_to_session(state, sid, %Model{} = model_ref, request) do
    effort = model_ref.effort

    with {:ok, base_result} <-
           map_model_refusal(
             request.("session/set_config_option", %{
               sessionId: sid,
               configId: "model",
               value: Model.to_ref(model_ref)
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
        :error -> {:error, :model_readback_unavailable}
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

  defp strict_apply(state, sid, %Model{} = model_ref, deadline) do
    model = Model.to_ref(model_ref)
    effort = model_ref.effort

    case map_model_refusal(strict_model_request(state, sid, "model", model, deadline)) do
      {:ok, base_result} ->
        effort_result =
          if effort do
            strict_model_request(
              state,
              sid,
              state.preset.effort_config,
              effort,
              deadline
            )
          else
            {:ok, base_result}
          end

        if read_back?(base_result, "model", model) and
             match?({:ok, _}, effort_result) and
             (is_nil(effort) or
                read_back?(elem(effort_result, 1), state.preset.effort_config, effort)) do
          :ok
        else
          {:error, :partial_apply}
        end

      {:error, reason} when reason in [:closed, :timeout] ->
        {:error, :model_transport_failure}

      {:error, _reason} ->
        {:error, :model_unavailable}
    end
  end

  defp strict_model_request(state, sid, config_id, value, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 ->
        Conn.request(
          state.conn,
          "session/set_config_option",
          %{sessionId: sid, configId: config_id, value: value},
          timeout: remaining
        )

      _expired ->
        {:error, :timeout}
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
    state =
      state
      |> remember_switchable_models(sid, %{"configOptions" => options})
      |> remember_config_options(sid, %{"configOptions" => options})

    case Map.fetch(state.models, sid) do
      {:ok, %Model{} = cached} ->
        if readback_confirms_model?(%{"configOptions" => options}, state.preset, cached) do
          remember_confirmed_config_model(state, sid, cached, options)
        else
          remember_reported_config_model(state, sid, options)
        end

      _ ->
        remember_reported_config_model(state, sid, options)
    end
  end

  defp remember_config_model(state, _sid, _update), do: state

  defp drop_model_residency(state, sid) do
    # A failed set/read-back leaves the harness value unknown. Keeping
    # either cache entry would let the next residency pass project memory over
    # the owner; forgetting residency forces that pass through session/load.
    %{
      state
      | known: MapSet.delete(state.known, sid),
        models: Map.delete(state.models, sid),
        unprompted: MapSet.delete(state.unprompted, sid),
        switchable_models: Map.delete(state.switchable_models, sid),
        config_options: Map.delete(state.config_options, sid)
    }
  end

  defp remember_switchable_models(state, sid, result) do
    models = canonical_offered_models(state.preset, result)

    if models == [] do
      state
    else
      put_in(state.switchable_models[sid], models)
    end
  end

  defp remember_config_options(state, sid, %{"configOptions" => options})
       when is_list(options),
       do: put_in(state.config_options[sid], options)

  defp remember_config_options(state, sid, _result),
    do: put_in(state.config_options, Map.delete(state.config_options, sid))

  defp advertised_fast_option(state, sid) do
    with {:ok, options} <- Map.fetch(state.config_options, sid),
         %{} = option <-
           Enum.find(options, &(option_id(&1) in ["fast", "fast-mode"])) do
      {:ok, option}
    else
      nil -> {:error, :fast_unsupported}
      :error -> {:error, :runtime_config_unknown}
      _ -> {:error, :fast_unsupported}
    end
  end

  defp canonical_fast_status(state, sid) do
    with {:ok, option} <- advertised_fast_option(state, sid),
         {:ok, fast} <- canonical_fast_value(option_current_value(option)) do
      {:ok, %{fast: fast, option_id: option_id(option)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp fast_wire_value(option, requested) do
    offered = option["options"] || []

    case Enum.find_value(offered, fn candidate ->
           value = candidate["value"]

           case canonical_fast_value(value) do
             {:ok, ^requested} -> {:found, value}
             _ -> nil
           end
         end) do
      {:found, value} ->
        {:ok, value}

      nil ->
        if option["type"] in ["boolean", "bool"] or is_boolean(option["currentValue"]),
          do: {:ok, requested == "on"},
          else: {:ok, requested}
    end
  end

  defp canonical_fast_value(value) when value in [true, "on", "enabled"], do: {:ok, "on"}
  defp canonical_fast_value(value) when value in [false, "off", "disabled"], do: {:ok, "off"}
  defp canonical_fast_value(_value), do: {:error, :runtime_config_unknown}

  defp option_id(option), do: option["id"] || option["configId"]

  defp option_current_value(option) do
    if Map.has_key?(option, "currentValue"), do: option["currentValue"], else: option["value"]
  end

  defp model_value_candidates(preset, result, %Model{} = model) do
    canonical_ref = Model.to_ref(model)

    aliases =
      result
      |> model_option_values()
      |> Enum.filter(&(Map.get(preset.model_option_aliases, &1) == canonical_ref))

    Enum.uniq([canonical_ref | aliases])
  end

  defp canonical_offered_models(preset, result) do
    result
    |> model_option_entries()
    |> Enum.flat_map(&confirmed_option_models(preset, &1))
    |> Enum.uniq()
  end

  defp confirmed_option_models(preset, option) do
    public_model = public_option_model(preset, option)

    mapped_candidates =
      case Map.get(preset.model_option_aliases, option["value"]) do
        value when is_binary(value) -> [Model.parse_ref(value)]
        _ -> []
      end

    confirmed_candidates =
      Enum.filter(mapped_candidates, &public_option_confirms_model?(option, public_model, &1))

    case {confirmed_candidates, public_model} do
      {[], %Model{} = model} -> [model]
      {models, _} -> models
    end
  end

  defp model_option_entries(%{"configOptions" => options}) when is_list(options) do
    case Enum.find(options, &((&1["id"] || &1["configId"]) == "model")) do
      %{"options" => values} when is_list(values) ->
        Enum.flat_map(values, fn
          %{"value" => value} = option when is_binary(value) -> [option]
          value when is_binary(value) -> [%{"value" => value, "name" => value}]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp model_option_entries(_result), do: []

  defp model_option_values(%{"configOptions" => options}) when is_list(options) do
    case Enum.find(options, &((&1["id"] || &1["configId"]) == "model")) do
      %{"options" => values} when is_list(values) ->
        Enum.flat_map(values, fn
          %{"value" => value} when is_binary(value) -> [value]
          value when is_binary(value) -> [value]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp model_option_values(_result), do: []

  defp readback_confirms_model?(result, preset, %Model{} = model) do
    with %{} = config <- model_config_option(result),
         value when is_binary(value) <- config["currentValue"] || config["value"],
         %{} = option <- selected_model_option(config, value),
         %Model{} = public_model <- public_option_model(preset, option) do
      public_option_confirms_model?(option, public_model, model)
    else
      _ -> false
    end
  end

  defp model_config_option(%{"configOptions" => options}) when is_list(options),
    do: Enum.find(options, &((&1["id"] || &1["configId"]) == "model"))

  defp model_config_option(_result), do: nil

  defp selected_model_option(config, value) do
    config
    |> Map.get("options", [])
    |> Enum.flat_map(fn
      %{"options" => nested} when is_list(nested) -> nested
      option -> [option]
    end)
    |> Enum.find_value(fn
      %{"value" => ^value} = option -> option
      ^value -> %{"value" => value, "name" => value}
      _ -> nil
    end)
    |> case do
      nil -> %{"value" => value, "name" => value}
      option -> option
    end
  end

  defp public_option_model(preset, %{"value" => value} = option) when is_binary(value) do
    if Enum.any?(preset.canonical_model_prefixes, &String.starts_with?(value, &1)) do
      Model.parse_ref(value)
    else
      public_model_from_label(option)
    end
  end

  defp public_option_model(_preset, _option), do: nil

  defp public_model_from_label(option) do
    label = Enum.join([option["name"], option["description"]], " ")

    case Regex.run(~r/\b(opus|sonnet|haiku|fable)\s+(\d+)(?:[. -](\d+))?/i, label) do
      [_, family, major, minor] when minor not in [nil, ""] ->
        Model.new("claude-#{String.downcase(family)}-#{major}-#{minor}")

      [_, family, major | _] ->
        Model.new("claude-#{String.downcase(family)}-#{major}")

      _ ->
        nil
    end
  end

  defp public_option_confirms_model?(_option, nil, _requested), do: false

  defp public_option_confirms_model?(option, %Model{} = public, %Model{} = requested) do
    public.family == requested.family and
      context_confirmed?(option, public.context, requested.context)
  end

  defp context_confirmed?(_option, context, context), do: true
  defp context_confirmed?(_option, _public_context, nil), do: true

  defp context_confirmed?(option, _public_context, requested_context) do
    option
    |> then(&Enum.join([&1["value"], &1["name"], &1["description"]], " "))
    |> String.downcase()
    |> String.contains?(String.downcase(requested_context))
  end

  defp remember_reported_config_model(state, sid, options) do
    case model_ref_from_config(%{"configOptions" => options}, state.preset.effort_config) do
      {:ok, model} -> put_in(state.models[sid], model)
      :error -> state
    end
  end

  defp remember_confirmed_config_model(state, sid, cached, options) do
    model =
      case config_value(options, state.preset.effort_config) do
        nil -> cached
        effort when effort in ["", "default"] -> %{cached | effort: nil}
        effort -> %{cached | effort: effort}
      end

    put_in(state.models[sid], model)
  end

  defp model_ref_from_config(%{"configOptions" => options}, effort_id)
       when is_list(options) do
    model = config_value(options, "model")
    effort = config_value(options, effort_id)

    cond do
      not is_binary(model) ->
        :error

      effort in [nil, "", "default"] ->
        {:ok, Model.parse_ref(model)}

      true ->
        {:ok, %{Model.parse_ref(model) | effort: effort}}
    end
  end

  defp model_ref_from_config(_, _effort_id), do: :error

  defp config_value(options, id) do
    case Enum.find(options, &((&1["id"] || &1["configId"]) == id)) do
      nil -> nil
      option -> option["currentValue"] || option["value"]
    end
  end

  defp set_mode(state, sid, request_timeout) do
    _ =
      Conn.request(
        state.conn,
        "session/set_mode",
        %{
          sessionId: sid,
          modeId: state.preset.permission_mode
        },
        timeout: request_timeout
      )

    :ok
  end

  defp adapter_ready(opts) do
    # Boot completed — the only trustworthy health signal under lazy boot
    # (spawn success means nothing). The coordinator closes its circuit here.
    with ready when is_function(ready, 0) <- Keyword.get(opts, :on_ready), do: ready.()
  end

  defp gate_attestation(state, probe_cwd, probe_model) do
    request = fn method, params ->
      Conn.request(state.conn, method, params, timeout: :infinity)
    end

    with {:ok, result} <- request.("session/new", %{cwd: probe_cwd, mcpServers: []}),
         sid = result["sessionId"],
         {:ok, _applied_model} <- apply_model_to_session(state, sid, probe_model, request),
         {:ok, _} <-
           request.("session/set_mode", %{
             sessionId: sid,
             modeId: state.preset.permission_mode
           }) do
      gate_prompt(state.conn, sid)
    else
      {:error, _error} -> {:error, :turn_error, "", []}
    end
  end

  defp gate_prompt(conn, sid) do
    parent = self()

    Task.start(fn ->
      result =
        Conn.request(
          conn,
          "session/prompt",
          %{sessionId: sid, prompt: [%{type: "text", text: @gate_prompt}]},
          timeout: :infinity
        )

      send(parent, {:gate_attestation_prompt_done, sid, result})
    end)

    gate_prompt_wait(sid, {[], []})
  end

  defp gate_prompt_wait(sid, {output, raw_updates}) do
    receive do
      {:acp_notification, "session/update", %{"sessionId" => ^sid, "update" => update}} ->
        gate_prompt_wait(
          sid,
          {
            gate_update_output(update) ++ output,
            [update | raw_updates] |> Enum.take(@gate_raw_update_limit)
          }
        )

      {:acp_notification, _method, _params} ->
        gate_prompt_wait(sid, {output, raw_updates})

      {:gate_attestation_prompt_done, ^sid, result} ->
        collected = output |> Enum.reverse() |> Enum.join()

        case result do
          {:ok, _} ->
            if String.contains?(collected, @gate_marker),
              do: {:ok, collected},
              else: {:error, :no_marker, collected, raw_updates}

          {:error, _error} ->
            {:error, :turn_error, collected, raw_updates}
        end

      {:acp_exit, _status} ->
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
end
