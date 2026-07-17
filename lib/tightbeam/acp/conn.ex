defmodule Tightbeam.Acp.Conn do
  @moduledoc """
  Owner of one ACP adapter Port: ndjson JSON-RPC over stdio (binary stream
  mode, hand-buffered line splitting — not Erlang {:line,N}, which fragments).

  The async protocol is binding:
  - This GenServer NEVER blocks its own loop. `request/4` stores the caller's
    `from` and replies when the Port answers ({:noreply, ...} + later
    GenServer.reply). Callers (TurnTasks) may block on the call — they are
    designed to wait and are monitored.
  - Per-request timeout via Process.send_after; on timeout the caller gets
    {:error, :timeout} and the pending entry is KEPT (awaiting the adapter's
    eventual answer) until resolution, for quiescence accounting.
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

  @type server :: GenServer.server()
  @type request_opts :: [timeout: non_neg_integer(), session_id: String.t()]
  @type response :: {:ok, term()} | {:error, term()}
  @type t :: %__MODULE__{
          port: port() | nil,
          buf: String.t(),
          next_id: pos_integer(),
          pending: map(),
          subscriber: pid() | nil,
          closed: boolean()
        }

  defstruct port: nil,
            buf: "",
            next_id: 1,
            # id => %{from, monitor, session_id, method, orphaned}
            pending: %{},
            subscriber: nil,
            closed: false

  ## Client

  @doc "Start one owner for an ACP adapter port and its unresolved requests."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc "JSON-RPC request. opts: :timeout (ms), :session_id (for cancel-on-death)."
  @spec request(server(), String.t(), map(), request_opts()) :: response()
  def request(conn, method, params, opts \\ []) do
    GenServer.call(conn, {:request, method, params, opts}, :infinity)
  end

  @doc "Send a JSON-RPC notification without creating pending request state."
  @spec notify(server(), String.t(), map()) :: :ok
  def notify(conn, method, params), do: GenServer.cast(conn, {:notify, method, params})

  @doc "Count of unresolved pending requests (quiescence probe)."
  @spec pending_count(server()) :: non_neg_integer()
  def pending_count(conn), do: GenServer.call(conn, :pending_count)

  @doc "Close the adapter port and fail every unresolved request exactly once."
  @spec close(server()) :: :ok
  def close(conn), do: GenServer.cast(conn, :close)

  ## Server

  @doc "Open the ACP subprocess and initialize its hand-buffered stream state."
  @spec init(keyword()) :: {:ok, t()}
  @impl true
  def init(opts) do
    cmd = Keyword.fetch!(opts, :cmd)
    stderr = Keyword.get(opts, :stderr_path, "/dev/null")
    env = Keyword.get(opts, :env, [])

    shell_cmd = Enum.map_join(cmd, " ", &shell_escape/1) <> " 2>>" <> shell_escape(stderr)

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        {:args, ["-c", "exec " <> shell_cmd]},
        {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
      ])

    {:ok, %__MODULE__{port: port, subscriber: Keyword.get(opts, :subscriber)}}
  end

  @doc "Handle asynchronous JSON-RPC requests and the quiescence count probe."
  @spec handle_call(term(), GenServer.from(), t()) ::
          {:reply, term(), t()} | {:noreply, t()}
  @impl true
  def handle_call({:request, method, params, opts}, {pid, _} = from, state) do
    if state.closed do
      {:reply, {:error, :closed}, state}
    else
      id = state.next_id
      send_json(state.port, %{jsonrpc: "2.0", id: id, method: method, params: params})
      timeout = Keyword.get(opts, :timeout, 60_000)
      Process.send_after(self(), {:req_timeout, id}, timeout)

      entry = %{
        from: from,
        monitor: Process.monitor(pid),
        session_id: Keyword.get(opts, :session_id),
        method: method,
        orphaned: false,
        replied: false
      }

      {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, entry)}}
    end
  end

  def handle_call(:pending_count, _from, state), do: {:reply, map_size(state.pending), state}

  @doc "Handle outbound notifications and explicit port closure."
  @spec handle_cast(term(), t()) :: {:noreply, t()}
  @impl true
  def handle_cast({:notify, method, params}, state) do
    unless state.closed,
      do: send_json(state.port, %{jsonrpc: "2.0", method: method, params: params})

    {:noreply, state}
  end

  def handle_cast(:close, state) do
    if state.port && !state.closed, do: Port.close(state.port)
    {:noreply, fail_all(%{state | closed: true}, {:error, :closed})}
  end

  @doc "Route port frames, exits, timeouts, and requester deaths without blocking the owner."
  @spec handle_info(term(), t()) :: {:noreply, t()}
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

  defp fail_all(state, reply) do
    for {_id, %{replied: false} = e} <- state.pending, do: GenServer.reply(e.from, reply)
    %{state | pending: %{}}
  end

  defp emit(%{subscriber: nil}, _msg), do: :ok
  defp emit(%{subscriber: pid}, msg), do: send(pid, msg)

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
