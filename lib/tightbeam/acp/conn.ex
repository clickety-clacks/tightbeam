defmodule Tightbeam.Acp.Conn do
  @moduledoc """
  Owner of one ACP adapter Port: ndjson JSON-RPC over stdio (binary stream
  mode, hand-buffered line splitting — not Erlang {:line,N}, which fragments).

  The async protocol (binding invariants — do not weaken):
  - This GenServer NEVER blocks its own loop. `request/4` stores the caller's
    `from` and replies when the Port answers ({:noreply, ...} + later
    GenServer.reply). Callers (TurnTasks) may block on the call — they are
    designed to wait and are monitored.
  - Finite per-request timeout via Process.send_after; on timeout the caller gets
    {:error, :timeout} and the pending entry is KEPT (awaiting the adapter's
    eventual answer) until resolution, for quiescence accounting.
    Owned prompts instead carry an absolute deadline: expiry sends cancel,
    waits for the original response, then closes this exact connection if the
    bounded cancellation grace expires. A timeout is never proof of quiescence.
  - Requester death: each pending request monitors its caller; on :DOWN a
    session/cancel notification is sent for that request's session. The
    pending entry is retained until the adapter's terminal response arrives —
    that arrival is the QUIESCENCE signal (emitted to the subscriber as
    {:acp_orphan_resolved, session_id}). Dropping the entry early would
    discard the only proof the old prompt stopped.
  - Server→client requests (session/request_permission) are answered here:
    auto-allow, preferring an allow-kind option (YOLO).
  - Port exit fails all pending with {:error, :closed} and emits
    {:acp_exit, status} to the subscriber. Stderr goes to a file via sh
    redirection — never merged into the ndjson stream.
  """

  use GenServer

  defstruct port: nil,
            buf: "",
            next_id: 1,
            # id => %{from, monitor, session_id, method, orphaned}
            pending: %{},
            subscriber: nil,
            connection_generation: nil,
            closed: false

  ## Client

  @type conn :: GenServer.server()

  @doc """
  Start the Conn. Required: `:cmd` (argv list for the adapter). Optional:
  `:env` (list of {name, value}), `:stderr_path`, `:subscriber` (pid receiving
  `{:acp_notification, ...}` / `{:acp_exit, ...}` / quiescence signals),
  `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc """
  JSON-RPC request; blocks the CALLER (never this GenServer) until the adapter
  answers, the per-request timeout fires, or the Port closes. opts: `:timeout`
  (ms or `:infinity`, default 60_000), `:session_id` (enables
  cancel-on-caller-death).
  """
  @spec request(conn(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(conn, method, params, opts \\ []) do
    GenServer.call(conn, {:request, method, params, opts}, :infinity)
  end

  @doc "Fire-and-forget JSON-RPC notification (no id, no reply)."
  @spec notify(conn(), String.t(), map()) :: :ok
  def notify(conn, method, params), do: GenServer.cast(conn, {:notify, method, params})

  @doc "Close the Port; all still-waiting callers get `{:error, :closed}`."
  @spec close(conn()) :: :ok
  def close(conn), do: GenServer.cast(conn, :close)

  @doc "Read one exact unresolved request from this connection without provider I/O."
  @spec probe_request(conn(), pos_integer(), String.t(), pos_integer(), pos_integer()) ::
          {:live, pos_integer()} | :absent | {:unknown, term()}
  def probe_request(conn, request_id, session_id, generation, timeout_ms)
      when is_integer(request_id) and request_id > 0 and is_binary(session_id) and
             is_integer(generation) and generation > 0 and is_integer(timeout_ms) and
             timeout_ms > 0 do
    GenServer.call(
      conn,
      {:probe_request, request_id, session_id, generation},
      timeout_ms
    )
  catch
    :exit, {:timeout, _} -> {:unknown, :timeout}
    :exit, {:noproc, _} -> {:unknown, :closed}
    :exit, reason -> {:unknown, {:connection_unavailable, reason}}
  end

  def probe_request(_conn, _request_id, _session_id, _generation, _timeout_ms),
    do: {:unknown, :uncorrelatable}

  ## Server

  @impl true
  def init(opts) do
    cmd = Keyword.fetch!(opts, :cmd)
    stderr = Keyword.get(opts, :stderr_path, "/dev/null")
    env = Keyword.get(opts, :env, [])

    shell_cmd = Enum.map_join(cmd, " ", &shell_escape/1) <> " 2>>" <> shell_escape(stderr)

    # R3: Erlang's `:env` OVERLAYS the emulator's full environment, so without
    # this the child would INHERIT this gateway's production identity —
    # RELEASE_*, TIGHTBEAM_BASE_DIR/PORT/NODE, ROOTDIR/BINDIR. Remove every such
    # inherited var with `{name, false}` FIRST, then let the explicit session
    # env (which carries TIGHTBEAM_HOME/MACHINE/LINEAGE) win by coming last. A
    # spawned session must resolve its OWN instance, never the ambient one — the
    # RELEASE_NODE-wins vector that let a test teardown reach production.
    scrub =
      for {name, _value} <- System.get_env(),
          Tightbeam.ProductionIdentityEnv.production_identity?(name),
          do: {String.to_charlist(name), false}

    provided = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        {:args, ["-c", "exec " <> shell_cmd]},
        {:env, scrub ++ provided}
      ])

    {:ok,
     %__MODULE__{
       port: port,
       subscriber: Keyword.get(opts, :subscriber),
       connection_generation: Keyword.get(opts, :connection_generation)
     }}
  end

  @impl true
  def handle_call({:request, method, params, opts}, {pid, _} = from, state) do
    expired? =
      is_integer(opts[:prompt_deadline]) and
        opts[:prompt_deadline] <= System.monotonic_time(:millisecond)

    if state.closed or expired? do
      reason = if state.closed, do: :closed, else: :prompt_timeout
      notify_not_dispatched(opts, reason)
      {:reply, {:error, reason}, state}
    else
      id = state.next_id

      if send_request_json(state.port, %{
           jsonrpc: "2.0",
           id: id,
           method: method,
           params: params
         }) do
        notify_dispatched(opts, id)
        timeout = Keyword.get(opts, :timeout, 60_000)

        deadline = Keyword.get(opts, :prompt_deadline)
        token = make_ref()

        timer =
          if is_integer(deadline) do
            Process.send_after(
              self(),
              {:prompt_deadline, id, token},
              max(deadline - System.monotonic_time(:millisecond), 0)
            )
          else
            if timeout != :infinity, do: Process.send_after(self(), {:req_timeout, id}, timeout)
          end

        entry = %{
          from: from,
          monitor: Process.monitor(pid),
          owner_monitor: if(is_pid(opts[:owner]), do: Process.monitor(opts[:owner])),
          deadline: deadline,
          timer: timer,
          cancel_timer: nil,
          token: token,
          cancel_reason: nil,
          cancel_grace: Keyword.get(opts, :cancel_grace, 5_000),
          session_id: Keyword.get(opts, :session_id),
          prompt_session_id:
            if(method == "session/prompt", do: params[:sessionId] || params["sessionId"]),
          method: method,
          orphaned: false,
          replied: false
        }

        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, entry)}}
      else
        notify_not_dispatched(opts, :closed)
        {:reply, {:error, :closed}, %{state | closed: true}}
      end
    end
  end

  def handle_call(
        {:probe_request, request_id, session_id, generation},
        _from,
        %{connection_generation: generation, closed: false} = state
      ) do
    result =
      case state.pending[request_id] do
        %{method: "session/prompt", prompt_session_id: ^session_id} -> {:live, request_id}
        nil -> :absent
        _mismatch -> {:unknown, :uncorrelatable}
      end

    {:reply, result, state}
  end

  def handle_call({:probe_request, _request_id, _session_id, _generation}, _from, state),
    do: {:reply, {:unknown, :uncorrelatable}, state}

  @impl true
  def handle_cast({:notify, method, params}, state) do
    unless state.closed,
      do: send_json(state.port, %{jsonrpc: "2.0", method: method, params: params})

    {:noreply, state}
  end

  def handle_cast(:close, state) do
    if state.port && !state.closed do
      try do
        Port.close(state.port)
      rescue
        # The Port may have exited before its exit_status was handled.
        ArgumentError -> :ok
      end
    end

    {:noreply, fail_all(%{state | closed: true}, {:error, :closed})}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {lines, buf} = split_lines(state.buf <> chunk)
    {:noreply, Enum.reduce(lines, %{state | buf: buf}, &handle_line/2)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    emit(state, {:acp_exit, status})
    {:noreply, fail_all(%{state | closed: true}, {:error, :closed})}
  end

  def handle_info({:req_timeout, id}, state) do
    case state.pending[id] do
      %{replied: false} = entry ->
        GenServer.reply(entry.from, {:error, :timeout})
        # KEEP the entry (unresolved at the adapter) for quiescence accounting.
        {:noreply, put_in(state.pending[id], %{entry | replied: true})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:prompt_deadline, id, token}, state) do
    case state.pending[id] do
      %{token: ^token, deadline: deadline} when is_integer(deadline) ->
        {:noreply, cancel_prompt(state, id, :prompt_timeout)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:prompt_cancel_expired, id, token}, state) do
    case state.pending[id] do
      %{token: ^token, cancel_reason: reason, prompt_session_id: sid}
      when not is_nil(reason) ->
        # The original response is the acknowledgment. Without it, release the
        # local transport, never pretend the cancel notification stopped it.
        if state.port && !state.closed do
          try do
            Port.close(state.port)
          rescue
            # The Port may have exited before its exit_status was handled.
            ArgumentError -> :ok
          end
        end

        emit(state, {:acp_prompt_teardown, self(), id, sid, reason})

        {:noreply,
         fail_all(
           %{state | closed: true},
           {:error, {:prompt_interrupted, {:cancel_unacknowledged, sid}}},
           true
         )}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.pending, fn {_id, e} -> e.monitor == ref or e.owner_monitor == ref end) do
      {id, %{deadline: deadline} = entry} when is_integer(deadline) ->
        state =
          if entry.monitor == ref do
            put_in(state.pending[id], %{entry | orphaned: true, replied: true})
          else
            state
          end

        cause = if entry.monitor == ref, do: {:prompt_worker_exit, reason}, else: :prompt_canceled
        {:noreply, cancel_prompt(state, id, cause)}

      {id, entry} ->
        if entry.session_id, do: send_cancel(state, entry.session_id)
        {:noreply, put_in(state.pending[id], %{entry | orphaned: true, replied: true})}

      nil ->
        {:noreply, state}
    end
  end

  defp cancel_prompt(state, id, reason) do
    case state.pending[id] do
      %{cancel_reason: nil} = entry ->
        send_cancel(state, entry.prompt_session_id)

        timer =
          Process.send_after(
            self(),
            {:prompt_cancel_expired, id, entry.token},
            entry.cancel_grace
          )

        emit(state, {:acp_prompt_cancelling, id, entry.prompt_session_id, reason})
        put_in(state.pending[id], %{entry | cancel_reason: reason, cancel_timer: timer})

      _ ->
        state
    end
  end

  defp send_cancel(state, sid) do
    unless state.closed do
      send_request_json(state.port, %{
        jsonrpc: "2.0",
        method: "session/cancel",
        params: %{sessionId: sid}
      })
    end
  end

  ## Incoming frames

  defp handle_line(line, state) do
    case safe_decode(line) do
      {:ok, msg} -> route(msg, state)
      :error -> state
    end
  end

  defp route(%{"id" => id, "method" => method} = msg, state) when is_binary(method) do
    # Server→client request: answer permission requests permissively (YOLO).
    result =
      if method == "session/request_permission" do
        %{outcome: %{outcome: "selected", optionId: pick_allow(msg["params"])}}
      else
        %{}
      end

    send_json(state.port, %{jsonrpc: "2.0", id: id, result: result})
    state
  end

  defp route(%{"id" => id} = msg, state) when is_map_key(state.pending, id) do
    {entry, pending} = Map.pop(state.pending, id)
    release_request(entry)

    reason =
      entry.cancel_reason ||
        if(is_integer(entry.deadline) and entry.deadline <= System.monotonic_time(:millisecond),
          do: :prompt_timeout
        )

    reply =
      case {reason, msg} do
        {reason, _} when not is_nil(reason) -> {:error, reason}
        {nil, %{"error" => err}} -> {:error, err}
        {nil, _} -> {:ok, msg["result"]}
      end

    cond do
      entry.orphaned and is_integer(entry.deadline) ->
        emit(state, {:acp_prompt_orphan_resolved, self(), id, entry.session_id})

      entry.orphaned ->
        emit(state, {:acp_orphan_resolved, entry.session_id})

      entry.replied ->
        emit(state, {:acp_late_reply, entry.method})

      true ->
        GenServer.reply(entry.from, reply)
    end

    %{state | pending: pending}
  end

  defp route(%{"method" => method} = msg, state) when is_binary(method) do
    emit(state, {:acp_notification, method, msg["params"]})
    state
  end

  defp route(_msg, state), do: state

  ## Helpers

  defp fail_all(state, reply, owned_teardown? \\ false) do
    for {_id, entry} <- state.pending do
      release_request(entry)
      # On exceptional teardown the adapter alone settles owned prompt calls.
      # A worker reply racing that signal could otherwise start a successor
      # before the generation's workers have been released.
      unless entry.replied or (owned_teardown? and is_integer(entry.deadline)),
        do: GenServer.reply(entry.from, reply)
    end

    %{state | pending: %{}}
  end

  defp release_request(entry) do
    Process.demonitor(entry.monitor, [:flush])
    if entry.owner_monitor, do: Process.demonitor(entry.owner_monitor, [:flush])
    if entry.timer, do: Process.cancel_timer(entry.timer)
    if entry.cancel_timer, do: Process.cancel_timer(entry.cancel_timer)
  end

  defp emit(%{subscriber: nil}, _msg), do: :ok
  defp emit(%{subscriber: pid}, msg), do: send(pid, msg)

  defp notify_dispatched(opts, request_id) do
    case Keyword.get(opts, :notify_dispatched) do
      {pid, ref} -> send(pid, {:acp_request_dispatched, ref, request_id})
      nil -> :ok
    end
  end

  defp notify_not_dispatched(opts, reason) do
    case Keyword.get(opts, :notify_dispatched) do
      {pid, ref} -> send(pid, {:acp_request_not_dispatched, ref, reason})
      nil -> :ok
    end
  end

  # A request is dispatched only after its bytes reach the Port. The OS process
  # can exit after `closed` was read above but before this write; only that
  # observable closed-port ArgumentError becomes `false`. Encoding happens
  # outside the rescue, and a write ArgumentError while the Port is still open
  # remains a programming error rather than being mislabeled as lifecycle loss.
  defp send_request_json(port, map) do
    payload = JSON.encode!(map) <> "\n"

    try do
      Port.command(port, payload)
    rescue
      error in ArgumentError ->
        if Port.info(port) == nil,
          do: false,
          else: reraise(error, __STACKTRACE__)
    end
  end

  defp send_json(port, map), do: Port.command(port, JSON.encode!(map) <> "\n")

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    {Enum.reject(lines, &(&1 == "")), rest}
  end

  defp safe_decode(line) do
    {:ok, JSON.decode!(line)}
  rescue
    _ -> :error
  end

  defp pick_allow(params) do
    options = (params || %{})["options"] || []

    allow =
      Enum.find(options, fn o -> o["kind"] in ["allow_always", "allow_once"] end) ||
        Enum.find(options, fn o -> is_binary(o["optionId"]) and o["optionId"] =~ ~r/allow/i end) ||
        List.first(options)

    allow && allow["optionId"]
  end

  defp shell_escape(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
