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
    A live session/prompt explicitly uses :infinity and gets no timer.
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
  - A stdout line that is not JSON cannot be routed; it is counted, logged
    without its content, and reported on later transport failures.

  A caller that passes `diagnostic: true` receives a transport failure as
  `{:error, {:diagnosed, :closed | :timeout, node}}` (see
  `Tightbeam.ErrorDiagnostic`): the method, the adapter's exit status or the
  client close, the timeout, and any undecodable output. Every other caller
  receives the bare classification it always did.
  """

  use GenServer
  require Logger
  alias Tightbeam.ErrorDiagnostic

  defstruct port: nil,
            buf: "",
            next_id: 1,
            # id => %{from, monitor, session_id, method, orphaned}
            pending: %{},
            subscriber: nil,
            closed: false,
            # why the transport closed: {:exit, status} | :closed_by_client | :send_failed
            closed_by: nil,
            malformed_lines: 0,
            last_malformed: nil

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
    reply = GenServer.call(conn, {:request, method, params, opts}, :infinity)

    if Keyword.get(opts, :diagnostic, false),
      do: reply,
      else: ErrorDiagnostic.classified(reply)
  end

  @doc "Fire-and-forget JSON-RPC notification (no id, no reply)."
  @spec notify(conn(), String.t(), map()) :: :ok
  def notify(conn, method, params), do: GenServer.cast(conn, {:notify, method, params})

  @doc "Close the Port; all still-waiting callers get `{:error, :closed}`."
  @spec close(conn()) :: :ok
  def close(conn), do: GenServer.cast(conn, :close)

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

    {:ok, %__MODULE__{port: port, subscriber: Keyword.get(opts, :subscriber)}}
  end

  @impl true
  def handle_call({:request, method, params, opts}, {pid, _} = from, state) do
    if state.closed do
      notify_not_dispatched(opts, :closed)
      {:reply, {:error, transport_failure(state, :closed, method, nil)}, state}
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

        if timeout != :infinity do
          Process.send_after(self(), {:req_timeout, id}, timeout)
        end

        entry = %{
          from: from,
          monitor: Process.monitor(pid),
          session_id: Keyword.get(opts, :session_id),
          method: method,
          timeout: timeout,
          orphaned: false,
          replied: false
        }

        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, entry)}}
      else
        notify_not_dispatched(opts, :closed)
        state = %{state | closed: true, closed_by: :send_failed}
        {:reply, {:error, transport_failure(state, :closed, method, nil)}, state}
      end
    end
  end

  @impl true
  def handle_cast({:notify, method, params}, state) do
    unless state.closed,
      do: send_json(state.port, %{jsonrpc: "2.0", method: method, params: params})

    {:noreply, state}
  end

  def handle_cast(:close, state) do
    state =
      if state.port && !state.closed do
        Port.close(state.port)
        %{state | closed_by: :closed_by_client}
      else
        state
      end

    {:noreply, fail_all(%{state | closed: true})}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {lines, buf} = split_lines(state.buf <> chunk)
    {:noreply, Enum.reduce(lines, %{state | buf: buf}, &handle_line/2)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    emit(state, {:acp_exit, status})
    {:noreply, fail_all(%{state | closed: true, closed_by: {:exit, status}})}
  end

  def handle_info({:req_timeout, id}, state) do
    case state.pending[id] do
      %{replied: false} = entry ->
        GenServer.reply(
          entry.from,
          {:error, transport_failure(state, :timeout, entry.method, entry.timeout)}
        )

        # KEEP the entry (unresolved at the adapter) for quiescence accounting.
        {:noreply, put_in(state.pending[id], %{entry | replied: true})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.pending, fn {_id, e} -> e.monitor == ref end) do
      {id, entry} ->
        if entry.session_id do
          send_json(state.port, %{
            jsonrpc: "2.0",
            method: "session/cancel",
            params: %{sessionId: entry.session_id}
          })
        end

        {:noreply, put_in(state.pending[id], %{entry | orphaned: true, replied: true})}

      nil ->
        {:noreply, state}
    end
  end

  ## Incoming frames

  defp handle_line(line, state) do
    case safe_decode(line) do
      {:ok, msg} ->
        route(msg, state)

      {:error, reason} ->
        malformed = malformed_fact(reason, line)

        Logger.warning(
          "acp undecodable stdout line dropped: #{malformed["error"]} " <>
            "at byte #{malformed["byteOffset"] || "?"} of #{malformed["lineBytes"]}"
        )

        %{state | malformed_lines: state.malformed_lines + 1, last_malformed: malformed}
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
    Process.demonitor(entry.monitor, [:flush])

    reply =
      case msg do
        %{"error" => err} -> {:error, err}
        _ -> {:ok, msg["result"]}
      end

    cond do
      entry.orphaned -> emit(state, {:acp_orphan_resolved, entry.session_id})
      entry.replied -> emit(state, {:acp_late_reply, entry.method})
      true -> GenServer.reply(entry.from, reply)
    end

    %{state | pending: pending}
  end

  defp route(%{"method" => method} = msg, state) when is_binary(method) do
    emit(state, {:acp_notification, method, msg["params"]})
    state
  end

  defp route(_msg, state), do: state

  ## Helpers

  defp fail_all(state) do
    for {_id, %{replied: false} = e} <- state.pending,
        do: GenServer.reply(e.from, {:error, transport_failure(state, :closed, e.method, nil)})

    %{state | pending: %{}}
  end

  defp transport_failure(state, reason, method, timeout) do
    {exit_status, closed_by} =
      case state.closed_by do
        {:exit, status} -> {status, "adapter_exit"}
        nil -> {nil, nil}
        other -> {nil, Atom.to_string(other)}
      end

    node =
      ErrorDiagnostic.new(Atom.to_string(reason),
        operation: method,
        origin: "acp_transport",
        closed_by: if(reason == :closed, do: closed_by),
        exit_status: if(reason == :closed, do: exit_status),
        timeout_ms: timeout,
        malformed_lines: if(state.malformed_lines > 0, do: state.malformed_lines),
        last_malformed: state.last_malformed && {:node, state.last_malformed}
      )

    ErrorDiagnostic.diagnosed(reason, node)
  end

  # Only the parser's own verdict and position: the line itself may carry
  # conversation or credential text and is never retained.
  defp malformed_fact(reason, line) do
    base = %{"lineBytes" => byte_size(line)}

    case reason do
      {:invalid_byte, offset, _byte} ->
        Map.merge(base, %{"error" => "invalid_byte", "byteOffset" => offset})

      {:unexpected_end, offset} ->
        Map.merge(base, %{"error" => "unexpected_end", "byteOffset" => offset})

      {:unexpected_sequence, offset, _bytes} ->
        Map.merge(base, %{"error" => "unexpected_sequence", "byteOffset" => offset})

      _ ->
        Map.put(base, "error", "undecodable")
    end
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
    JSON.decode(line)
  rescue
    _ -> {:error, :undecodable}
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
