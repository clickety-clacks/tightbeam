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
  alias Tightbeam.{Harness}
  alias Tightbeam.Acp.Conn

  @gate_attestation_timeout 120_000
  @gate_marker "[gate: tightbeam-probe]"
  @gate_prompt "Run exactly this command with your shell tool (no other arguments): tightbeam-gate-probe . If the command is refused or blocked by anything, report the exact refusal message you received, verbatim, then stop; do not retry or work around it."
  @gate_raw_update_limit 20
  @gate_raw_log_limit 4_096
  @cancel_boundary_timeout 125_000

  defstruct [
    :conn,
    :preset,
    :harness,
    :cwd,
    :on_auth_event,
    :on_subagent_event,
    contained: false,
    chunks: %{},
    progress: %{},
    known: MapSet.new()
  ]

  ## Client

  @type adapter :: GenServer.server()

  @typedoc "Model reference — bare name or \"name[effort]\" (see parse_model_ref/1)."
  @type model_ref :: String.t()

  @doc """
  Start the adapter. Required: `:harness` (a registered harness id), `:cmd` (adapter
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
  @spec new_session(adapter(), model_ref(), String.t(), [map()], String.t()) ::
          {:ok, String.t()}
  def new_session(adapter, model, cwd, mcp_servers, guidance),
    do: GenServer.call(adapter, {:new_session, model, cwd, mcp_servers, guidance}, 30_000)

  @doc "Adopt an existing harness session at its workdir — re-applies the model; never trusts the advertised one."
  @spec load_session(adapter(), String.t(), model_ref(), String.t(), [map()], String.t()) ::
          :ok | {:error, term()}
  def load_session(adapter, session_id, model, cwd, mcp_servers, guidance),
    do:
      GenServer.call(
        adapter,
        {:load_session, session_id, model, cwd, mcp_servers, guidance},
        30_000
      )

  @doc "Best-effort ACP teardown for one harness session; adapter failures never escape the caller."
  @spec close_session(adapter(), String.t()) :: :ok | {:error, term()}
  def close_session(adapter, session_id) do
    GenServer.call(adapter, {:close_session, session_id}, 65_000)
  rescue
    reason -> {:error, {:adapter_unavailable, reason}}
  catch
    :exit, reason -> {:error, {:adapter_unavailable, reason}}
  end

  @doc "Strict adjudication-only model apply: base, effort, then response read-back."
  @spec apply_model_strict(adapter(), String.t(), model_ref(), model_ref()) ::
          :ok | {:error, :model_unavailable | :partial_apply}
  def apply_model_strict(adapter, session_id, model, prior_model),
    do: GenServer.call(adapter, {:apply_model_strict, session_id, model, prior_model}, 30_000)

  @doc """
  Run a turn: sends session/prompt, accumulates agent_message_chunk text while
  this GenServer keeps routing updates, replies when the harness finishes.
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
      do: GenServer.call(adapter, {:prompt, session_id, text, opts}, timeout + 5_000)

  @doc """
  Apply and read back the intended mind, persist it through `before_send`, then
  send the ACP prompt in one adapter-serialized boundary.
  """
  @spec prompt_configured(
          adapter(),
          String.t(),
          model_ref(),
          String.t(),
          (-> :ok | :already_terminal),
          timeout(),
          keyword()
        ) ::
          {:ok, %{stop_reason: String.t(), text: String.t()}} | {:error, term()}
  def prompt_configured(
        adapter,
        session_id,
        model,
        text,
        before_send,
        timeout \\ Application.get_env(:tightbeam, :turn_timeout_ms, 600_000),
        opts \\ []
      ),
      do:
        GenServer.call(
          adapter,
          {:prompt_configured, session_id, model, text, before_send, opts},
          timeout + 5_000
        )

  @doc "Serialize an ACP cancellation against tune and the configured prompt boundary."
  @spec cancel_session(adapter(), String.t(), (-> result)) :: result when result: term()
  def cancel_session(adapter, session_id, before_cancel \\ fn -> :ok end),
    do:
      GenServer.call(
        adapter,
        {:cancel_session, session_id, before_cancel},
        @cancel_boundary_timeout
      )

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
  def knows_session?(adapter, session_id),
    do: GenServer.call(adapter, {:knows_session?, session_id})

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
    module = Harness.module!(harness)
    preset = module.session_config(%{}, "")

    {:ok, conn} =
      Conn.start_link(
        cmd: Keyword.fetch!(opts, :cmd),
        env: Keyword.get(opts, :env, []),
        stderr_path: Keyword.get(opts, :stderr_path, "/dev/null"),
        subscriber: self()
      )

    {:ok, %{"protocolVersion" => 1}} =
      Conn.request(conn, "initialize", %{
        protocolVersion: 1,
        clientCapabilities: %{fs: %{readTextFile: false, writeTextFile: false}}
      })

    state = %__MODULE__{
      conn: conn,
      preset: preset,
      harness: harness,
      cwd: Keyword.fetch!(opts, :cwd),
      on_auth_event: Keyword.get(opts, :on_auth_event),
      on_subagent_event: Keyword.get(opts, :on_subagent_event),
      contained: Keyword.get(opts, :contained, false)
    }

    case Keyword.fetch(opts, :probe_cwd) do
      {:ok, probe_cwd} ->
        deadline =
          System.monotonic_time(:millisecond) +
            Keyword.get(opts, :gate_attestation_timeout, @gate_attestation_timeout)

        case gate_attestation(state, probe_cwd, Keyword.fetch!(opts, :probe_model), deadline) do
          {:ok, output} ->
            gate_log(
              Keyword.get(opts, :stderr_path, "/dev/null"),
              "gate wiring-check PASS #{@gate_marker} output=#{inspect(output)}"
            )

            adapter_ready(opts)
            {:noreply, state}

          {:error, detail, output, raw_updates} ->
            gate_log(
              Keyword.get(opts, :stderr_path, "/dev/null"),
              "[gate-drift] raw_updates=#{gate_raw_updates(raw_updates)}"
            )

            gate_log(
              Keyword.get(opts, :stderr_path, "/dev/null"),
              "gate wiring-check FAIL detail=#{detail} output=#{inspect(output)}"
            )

            {:stop, {:gate_attestation_failed, detail}, state}
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
         :ok <- apply_model(state, sid, model),
         :ok <- set_mode(state, sid) do
      state = %{state | known: MapSet.put(state.known, sid)}
      {:reply, {:ok, sid}, put_in(state.chunks[sid], [])}
    else
      # Refused config (e.g. an unavailable model) is a turn failure with a
      # reason — never a crash of the shared adapter's caller chain.
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:load_session, sid, model, cwd, mcp_servers, guidance}, _from, state) do
    case Conn.request(state.conn, "session/load", %{
           sessionId: sid,
           cwd: cwd,
           mcpServers: mcp_servers,
           _meta: Harness.module!(state.harness).session_config(%{}, guidance).meta
         }) do
      {:ok, _} ->
        # Best-effort: a loaded session already HAS a model. The option's
        # valid set is populated asynchronously in the harness and can lag
        # adapter boot, so a refused re-assert here must never cost the
        # session's memory — continuity outranks the config option.
        _ = apply_model(state, sid, model)

        case set_mode_after_load(state, sid) do
          :ok ->
            state = %{state | known: MapSet.put(state.known, sid)}
            {:reply, :ok, put_in(state.chunks[sid], [])}

          {:error, :contained_sandbox_disable_failed} = error ->
            state = %{state | known: MapSet.delete(state.known, sid)}
            {:reply, error, state}
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
            chunks: Map.delete(state.chunks, sid),
            progress: Map.delete(state.progress, sid)
        }

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_model_strict, sid, model, prior_model}, _from, state) do
    {:reply, strict_apply_with_retry(state, sid, model, prior_model, 3), state}
  end

  def handle_call({:knows_session?, sid}, _from, state),
    do: {:reply, MapSet.member?(state.known, sid), state}

  def handle_call({:prompt, sid, text, opts}, from, state) do
    start_prompt(state, sid, text, opts, from)
  end

  def handle_call({:prompt_configured, sid, model, text, before_send, opts}, from, state) do
    case strict_apply(state, sid, model, model) do
      :ok ->
        case before_send.() do
          :ok -> start_prompt(state, sid, text, opts, from)
          :already_terminal -> {:reply, {:error, :turn_terminal}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel_session, sid, before_cancel}, _from, state) do
    result = before_cancel.()
    if result == :ok, do: notify_cancel(state.conn, sid)
    {:reply, result, state}
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

  defp notify_cancel(conn, sid) do
    Conn.notify(conn, "session/cancel", %{sessionId: sid})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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
    maybe_emit_subagent_event(state, sid, update)
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
    with handler when is_function(handler, 2) <- state.on_subagent_event do
      handler.(sid, update)
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

  defp apply_model(state, sid, model_ref) do
    apply_model(state, sid, model_ref, fn method, params ->
      Conn.request(state.conn, method, params)
    end)
  end

  defp apply_model(state, sid, model_ref, request) do
    {model, effort} = parse_model_ref(model_ref)

    with {:ok, _} <-
           request.("session/set_config_option", %{
             sessionId: sid,
             configId: "model",
             value: model
           }),
         {:ok, _} <-
           (if effort do
              request.("session/set_config_option", %{
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

  defp set_mode(%{contained: false} = state, sid) do
    _ =
      Conn.request(state.conn, "session/set_mode", %{
        sessionId: sid,
        modeId: state.preset.permission_mode
      })

    :ok
  end

  defp set_mode(%{contained: true} = state, sid) do
    case Conn.request(state.conn, "session/set_mode", %{
           sessionId: sid,
           modeId: state.preset.permission_mode
         }) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :contained_sandbox_disable_failed}
    end
  end

  defp set_mode_after_load(%{contained: false}, _sid), do: :ok
  defp set_mode_after_load(state, sid), do: set_mode(state, sid)

  defp adapter_ready(opts) do
    # Boot completed — the only trustworthy health signal under lazy boot
    # (spawn success means nothing). The coordinator closes its circuit here.
    with ready when is_function(ready, 0) <- Keyword.get(opts, :on_ready), do: ready.()
  end

  defp gate_attestation(state, probe_cwd, probe_model, deadline) do
    request = fn method, params -> gate_request(state.conn, method, params, deadline) end

    with {:ok, result} <- request.("session/new", %{cwd: probe_cwd, mcpServers: []}),
         sid = result["sessionId"],
         :ok <- apply_model(state, sid, probe_model, request),
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

  defp gate_remaining(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp cancel_gate_timer(timer) do
    Process.cancel_timer(timer)

    receive do
      :gate_attestation_deadline -> :ok
    after
      0 -> :ok
    end
  end

  defp gate_log(path, line), do: File.write!(path, line <> "\n", [:append])

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
