defmodule Tightbeam.Firehose.Hub do
  @moduledoc """
  Live-only fan-out for state-change notices.

  The hub keeps no history. It owns each connection's subscriptions, delivery
  sequence, and bounded queue so registration and publication have one
  deterministic ordering seam. Publishers only cast post-commit notices; a
  slow socket never receives more than one in-flight delivery at a time.
  """

  use GenServer

  alias Tightbeam.StateVisibility

  @default_queue_limit 1_000

  defmodule Socket do
    @moduledoc false
    defstruct monitor: nil,
              mode: :all,
              db: nil,
              user_id: nil,
              device_id: nil,
              is_admin: false,
              subscriptions: %{},
              seq: 0,
              queue: :queue.new(),
              queued: 0,
              in_flight: false,
              overflowed: false
  end

  defstruct sockets: %{},
            queue_limit: @default_queue_limit,
            shutting_down: false,
            shutdown_waiter: nil

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Register a raw all-notice sink. Production change sockets use register/3."
  @spec register(server(), pid()) :: :ok
  def register(server \\ __MODULE__, pid \\ self()),
    do: register(server, pid, %{mode: :all})

  @spec register(server(), pid(), map()) :: :ok
  def register(server, pid, opts) when is_pid(pid) and is_map(opts),
    do: GenServer.call(server, {:register, pid, opts})

  @spec subscribe(server(), pid(), String.t(), map()) :: :ok
  def subscribe(server, pid, id, filters) when is_binary(id) and is_map(filters),
    do: GenServer.call(server, {:subscribe, pid, id, filters})

  @spec unsubscribe(server(), pid(), String.t()) :: :ok
  def unsubscribe(server, pid, id) when is_binary(id),
    do: GenServer.call(server, {:unsubscribe, pid, id})

  @spec sequence(server(), pid()) :: non_neg_integer()
  def sequence(server, pid),
    do: GenServer.call(server, {:sequence, pid})

  @doc false
  @spec connection_stats(server(), pid()) :: map() | nil
  def connection_stats(server, pid),
    do: GenServer.call(server, {:connection_stats, pid})

  @spec delivered(server(), pid()) :: :ok
  def delivered(server, pid) do
    GenServer.cast(server, {:delivered, pid})
  end

  @spec unregister(server(), pid()) :: :ok
  def unregister(server \\ __MODULE__, pid \\ self()),
    do: GenServer.cast(server, {:unregister, pid})

  @doc false
  @spec shutdown_delivered(server(), pid()) :: :ok
  def shutdown_delivered(server, pid),
    do: GenServer.call(server, {:shutdown_delivered, pid})

  @spec shutdown(server()) :: :ok
  def shutdown(server \\ __MODULE__), do: GenServer.call(server, :shutdown, :infinity)

  @spec publish(server(), map()) :: :ok
  def publish(server \\ __MODULE__, notice) when is_map(notice) do
    GenServer.cast(server, {:publish, notice})
  end

  @spec accepted(server(), GenServer.server() | nil, map(), term()) :: :ok
  def accepted(server \\ __MODULE__, db, call, result),
    do: GenServer.cast(server, {:accepted, db, call, result})

  @spec denied(server(), map(), map()) :: :ok
  def denied(server \\ __MODULE__, call, error),
    do: GenServer.cast(server, {:denied, call, error})

  @spec committed(server(), String.t(), map(), map()) :: :ok
  def committed(server \\ __MODULE__, class, payload, refs),
    do: GenServer.cast(server, {:committed, class, payload, refs})

  @impl true
  def init(opts),
    do: {:ok, %__MODULE__{queue_limit: Keyword.get(opts, :queue_limit, @default_queue_limit)}}

  @impl true
  def handle_call({:register, pid, opts}, _from, state) do
    case state.sockets[pid] do
      nil when state.shutting_down ->
        send(pid, :firehose_shutdown)
        {:reply, :ok, state}

      nil ->
        monitor = Process.monitor(pid)

        socket = configure_socket(%Socket{monitor: monitor}, opts)

        {:reply, :ok, put_socket(state, pid, socket)}

      socket ->
        {:reply, :ok, put_socket(state, pid, configure_socket(socket, opts))}
    end
  end

  def handle_call({:subscribe, pid, id, filters}, _from, state) do
    {:reply, :ok, update_socket(state, pid, &put_in(&1.subscriptions[id], filters))}
  end

  def handle_call({:unsubscribe, pid, id}, _from, state) do
    {:reply, :ok,
     update_socket(state, pid, &%{&1 | subscriptions: Map.delete(&1.subscriptions, id)})}
  end

  def handle_call({:sequence, pid}, _from, state) do
    {:reply, (state.sockets[pid] && state.sockets[pid].seq) || 0, state}
  end

  def handle_call({:connection_stats, pid}, _from, state) do
    stats =
      case state.sockets[pid] do
        nil ->
          nil

        socket ->
          %{
            queued: socket.queued,
            in_flight: socket.in_flight,
            overflowed: socket.overflowed,
            seq: socket.seq
          }
      end

    {:reply, stats, state}
  end

  def handle_call(:shutdown, from, state) do
    Enum.each(Map.keys(state.sockets), &send(&1, :firehose_shutdown))

    state = %{state | shutting_down: true}

    if map_size(state.sockets) == 0 do
      {:reply, :ok, state}
    else
      {:noreply, %{state | shutdown_waiter: from}}
    end
  end

  def handle_call({:shutdown_delivered, pid}, _from, state) do
    state = state |> drop_socket(pid) |> maybe_finish_shutdown()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:unregister, pid}, state),
    do: {:noreply, state |> drop_socket(pid) |> maybe_finish_shutdown()}

  def handle_cast({:delivered, pid}, state) do
    state =
      update_socket(state, pid, fn socket ->
        socket
        |> Map.put(:in_flight, false)
        |> dispatch_next(pid)
      end)

    {:noreply, state}
  end

  def handle_cast({:publish, notice}, state), do: {:noreply, fanout(state, notice)}

  def handle_cast({:accepted, db, call, result}, state) do
    state =
      Enum.reduce(
        Tightbeam.Firehose.Publisher.accepted_notices(db, call, result),
        state,
        &fanout(&2, &1)
      )

    {:noreply, state}
  end

  def handle_cast({:denied, call, error}, state) do
    state =
      Enum.reduce(
        Tightbeam.Firehose.Publisher.denied_notices(call, error),
        state,
        &fanout(&2, &1)
      )

    {:noreply, state}
  end

  def handle_cast({:committed, class, payload, refs}, state) do
    notice = Tightbeam.Firehose.Publisher.committed_notice(class, payload, refs)
    {:noreply, fanout(state, notice)}
  end

  defp fanout(%{shutting_down: true} = state, _notice), do: state

  defp fanout(state, notice) do
    sockets =
      Map.new(state.sockets, fn {pid, socket} ->
        {pid, deliver_notice(pid, socket, notice, state.queue_limit)}
      end)

    %{state | sockets: sockets}
  end

  defp deliver_notice(_pid, %{overflowed: true} = socket, _notice, _queue_limit),
    do: socket

  defp deliver_notice(pid, socket, notice, queue_limit) do
    cond do
      socket.mode == :pending ->
        socket

      revoked?(notice, socket) ->
        send(pid, :firehose_revoked)
        socket

      socket.mode == :all ->
        enqueue_frames(pid, socket, [notice], queue_limit)

      visible?(notice, socket) ->
        {frames, seq} = matching_frames(notice, socket.subscriptions, socket.seq)
        enqueue_frames(pid, %{socket | seq: seq}, frames, queue_limit)

      true ->
        socket
    end
  end

  defp enqueue_frames(_pid, socket, [], _queue_limit), do: socket

  defp enqueue_frames(pid, socket, frames, queue_limit) do
    occupied = socket.queued + if(socket.in_flight, do: 1, else: 0)

    if occupied + length(frames) > queue_limit do
      send(pid, :firehose_overflow)

      %{
        socket
        | queue: :queue.new(),
          queued: 0,
          overflowed: true
      }
    else
      queue = Enum.reduce(frames, socket.queue, &:queue.in(&1, &2))

      socket
      |> Map.put(:queue, queue)
      |> Map.put(:queued, socket.queued + length(frames))
      |> dispatch_next(pid)
    end
  end

  defp dispatch_next(%{in_flight: true} = socket, _pid), do: socket
  defp dispatch_next(%{overflowed: true} = socket, _pid), do: socket

  defp dispatch_next(socket, pid) do
    case :queue.out(socket.queue) do
      {{:value, frame}, queue} ->
        send(pid, {:firehose_notice, frame})
        %{socket | queue: queue, queued: socket.queued - 1, in_flight: true}

      {:empty, _queue} ->
        socket
    end
  end

  defp matching_frames(notice, subscriptions, initial_seq) do
    subscriptions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], initial_seq}, fn {id, filters}, {frames, seq} ->
      if matches?(notice, filters) do
        next = seq + 1

        frame =
          notice
          |> Map.put("type", "change")
          |> Map.put("schemaVersion", 1)
          |> Map.put("subscriptionId", id)
          |> Map.put("seq", next)

        {[frame | frames], next}
      else
        {frames, seq}
      end
    end)
    |> then(fn {frames, seq} -> {Enum.reverse(frames), seq} end)
  end

  @doc false
  @spec matches?(map(), map()) :: boolean()
  def matches?(notice, filters) do
    refs = notice["refs"] || %{}

    class_match? =
      case filters["classes"] do
        nil -> true
        prefixes -> Enum.any?(prefixes, &String.starts_with?(notice["class"] || "", &1))
      end

    class_match? and
      Enum.all?(~w(sessionKey workItemId origin principal), fn key ->
        is_nil(filters[key]) or filters[key] == refs[key]
      end)
  end

  defp visible?(notice, socket) do
    payload = notice["payload"] || %{}

    not secret_payload?(payload) and
      StateVisibility.visible?(socket.db, notice, socket.user_id, socket.is_admin)
  end

  defp revoked?(%{"class" => "device.revoked", "refs" => refs}, socket),
    do: refs["deviceId"] == socket.device_id

  defp revoked?(%{"class" => "session.retired"} = notice, socket) do
    payload = notice["payload"] || %{}
    refs = notice["refs"] || %{}
    payload["ownerUserId"] == socket.user_id or refs["ownerUserId"] == socket.user_id
  end

  defp revoked?(_notice, _socket), do: false

  defp secret_payload?(payload) when is_map(payload) do
    Enum.any?(payload, fn {key, value} ->
      key in ["cliToken", "token", "identityToken"] or secret_payload?(value)
    end)
  end

  defp secret_payload?(payload) when is_list(payload), do: Enum.any?(payload, &secret_payload?/1)
  defp secret_payload?(_payload), do: false

  defp update_socket(state, pid, fun) do
    case state.sockets[pid] do
      nil -> state
      socket -> put_socket(state, pid, fun.(socket))
    end
  end

  defp configure_socket(socket, opts) do
    %{
      socket
      | mode: Map.get(opts, :mode, socket.mode),
        db: Map.get(opts, :db, socket.db),
        user_id: Map.get(opts, :user_id, socket.user_id),
        device_id: Map.get(opts, :device_id, socket.device_id),
        is_admin: Map.get(opts, :is_admin, socket.is_admin)
    }
  end

  defp put_socket(state, pid, socket), do: %{state | sockets: Map.put(state.sockets, pid, socket)}

  defp drop_socket(state, pid) do
    {socket, sockets} = Map.pop(state.sockets, pid)
    if socket, do: Process.demonitor(socket.monitor, [:flush])
    %{state | sockets: sockets}
  end

  defp maybe_finish_shutdown(%{shutdown_waiter: nil} = state), do: state

  defp maybe_finish_shutdown(%{sockets: sockets} = state) when map_size(sockets) > 0,
    do: state

  defp maybe_finish_shutdown(state) do
    GenServer.reply(state.shutdown_waiter, :ok)
    %{state | shutdown_waiter: nil}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    state =
      case state.sockets[pid] do
        %{monitor: ^monitor} -> state |> drop_socket(pid) |> maybe_finish_shutdown()
        _other -> state
      end

    {:noreply, state}
  end
end
