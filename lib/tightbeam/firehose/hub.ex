defmodule Tightbeam.Firehose.Hub do
  @moduledoc "Live-only Firehose queue with per-delivery authorization; startup is owned by Gateway."
  use GenServer
  alias Tightbeam.Firehose.Publisher
  alias Tightbeam.StateVisibility

  defmodule Socket do
    @moduledoc false
    defstruct monitor: nil,
              mode: :pending,
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

  defstruct sockets: %{}, queue_limit: 1_000, shutting_down: false, shutdown_waiter: nil

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def register(server \\ __MODULE__, pid \\ self()), do: register(server, pid, %{mode: :all})
  def register(server, pid, opts), do: GenServer.call(server, {:register, pid, opts})

  def subscribe(server, pid, id, filters),
    do: GenServer.call(server, {:subscribe, pid, id, filters})

  def unsubscribe(server, pid, id), do: GenServer.call(server, {:unsubscribe, pid, id})
  def sequence(server, pid), do: GenServer.call(server, {:sequence, pid})
  def connection_stats(server, pid), do: GenServer.call(server, {:connection_stats, pid})
  def delivered(server, pid), do: GenServer.cast(server, {:delivered, pid})

  def unregister(server \\ __MODULE__, pid \\ self()),
    do: GenServer.cast(server, {:unregister, pid})

  def shutdown_delivered(server, pid), do: GenServer.call(server, {:shutdown_delivered, pid})
  def shutdown(server \\ __MODULE__), do: GenServer.call(server, :shutdown, :infinity)
  def publish(server \\ __MODULE__, notice), do: GenServer.cast(server, {:publish, notice})

  def committed(server \\ __MODULE__, class, payload, refs),
    do: GenServer.cast(server, {:committed, class, payload, refs})

  def accepted(server \\ __MODULE__, db, call, result),
    do: GenServer.cast(server, {:accepted, db, call, result})

  def denied(server \\ __MODULE__, call, error),
    do: GenServer.cast(server, {:denied, call, error})

  @impl true
  def init(opts), do: {:ok, %__MODULE__{queue_limit: Keyword.get(opts, :queue_limit, 1_000)}}
  @impl true
  def handle_call({:register, pid, opts}, _from, state) do
    if state.shutting_down do
      send(pid, :firehose_shutdown)
      {:reply, :ok, state}
    else
      socket = state.sockets[pid] || %Socket{monitor: Process.monitor(pid)}
      socket = struct(socket, Map.take(opts, [:mode, :db, :user_id, :device_id, :is_admin]))
      {:reply, :ok, put_in(state.sockets[pid], socket)}
    end
  end

  def handle_call({:subscribe, pid, id, filters}, _, state),
    do: {:reply, :ok, update(state, pid, &put_in(&1.subscriptions[id], filters))}

  def handle_call({:unsubscribe, pid, id}, _, state),
    do:
      {:reply, :ok, update(state, pid, &%{&1 | subscriptions: Map.delete(&1.subscriptions, id)})}

  def handle_call({:sequence, pid}, _, state),
    do: {:reply, (state.sockets[pid] && state.sockets[pid].seq) || 0, state}

  def handle_call({:connection_stats, pid}, _, state) do
    socket = state.sockets[pid]
    {:reply, socket && Map.take(socket, [:queued, :in_flight, :overflowed, :seq]), state}
  end

  def handle_call(:shutdown, from, state) do
    Enum.each(Map.keys(state.sockets), &send(&1, :firehose_shutdown))

    if map_size(state.sockets) == 0,
      do: {:reply, :ok, %{state | shutting_down: true}},
      else: {:noreply, %{state | shutting_down: true, shutdown_waiter: from}}
  end

  def handle_call({:shutdown_delivered, pid}, _, state), do: {:reply, :ok, drop(state, pid)}

  @impl true
  def handle_cast({:unregister, pid}, state), do: {:noreply, drop(state, pid)}

  def handle_cast({:delivered, pid}, state),
    do: {:noreply, update(state, pid, &dispatch_next(%{&1 | in_flight: false}, pid))}

  def handle_cast({:committed, class, payload, refs}, state),
    do: {:noreply, fanout(state, Publisher.committed_notice(class, payload, refs))}

  def handle_cast({:publish, notice}, state),
    do: {:noreply, fanout(state, notice)}

  def handle_cast({:accepted, db, call, result}, state),
    do:
      {:noreply,
       Enum.reduce(Publisher.accepted_notices(db, call, result), state, &fanout(&2, &1))}

  def handle_cast({:denied, call, error}, state),
    do: {:noreply, Enum.reduce(Publisher.denied_notices(call, error), state, &fanout(&2, &1))}

  def handle_cast(_, state), do: {:noreply, state}

  defp fanout(%{shutting_down: true} = state, _), do: state

  defp fanout(state, notice) do
    sockets =
      Map.new(state.sockets, fn {pid, socket} ->
        {pid, deliver_notice(socket, pid, notice, state.queue_limit)}
      end)

    %{state | sockets: sockets}
  end

  defp deliver_notice(%{mode: :pending} = socket, _, _, _), do: socket
  defp deliver_notice(%{overflowed: true} = socket, _, _, _), do: socket

  defp deliver_notice(socket, pid, notice, limit) do
    if revoked?(notice, socket) do
      send(pid, :firehose_revoked)
      socket
    else
      deliver_visible_notice(socket, pid, notice, limit)
    end
  end

  defp deliver_visible_notice(socket, pid, notice, limit) do
    if not secret_payload?(notice["payload"]) and
         StateVisibility.visible?(socket.db, notice, socket.user_id, socket.is_admin) do
      {frames, seq} =
        if socket.mode == :all,
          do: {[notice], socket.seq},
          else: matching_frames(notice, socket.subscriptions, socket.seq)

      frames = Enum.map(frames, &Publisher.wire_notice/1)
      enqueue(%{socket | seq: seq}, pid, frames, limit)
    else
      socket
    end
  end

  defp enqueue(socket, _, [], _), do: socket

  defp enqueue(socket, pid, frames, limit) do
    occupied = socket.queued + if(socket.in_flight, do: 1, else: 0)

    if occupied + length(frames) > limit do
      send(pid, :firehose_overflow)
      %{socket | queue: :queue.new(), queued: 0, overflowed: true}
    else
      queue = Enum.reduce(frames, socket.queue, &:queue.in(&1, &2))
      dispatch_next(%{socket | queue: queue, queued: socket.queued + length(frames)}, pid)
    end
  end

  defp dispatch_next(%{in_flight: true} = socket, _), do: socket
  defp dispatch_next(%{overflowed: true} = socket, _), do: socket

  defp dispatch_next(socket, pid) do
    case :queue.out(socket.queue) do
      {{:value, frame}, queue} ->
        socket = %{socket | queue: queue, queued: socket.queued - 1}

        cond do
          socket.mode == :pending or
              not StateVisibility.visible?(
                socket.db,
                frame,
                socket.user_id,
                socket.is_admin
              ) ->
            dispatch_next(socket, pid)

          true ->
            send(pid, {:firehose_notice, Publisher.wire_notice(frame)})
            %{socket | in_flight: true}
        end

      {:empty, _} ->
        socket
    end
  end

  defp matching_frames(notice, subscriptions, seq) do
    Enum.sort(subscriptions)
    |> Enum.reduce({[], seq}, fn {id, filters}, {frames, n} ->
      if matches?(notice, filters),
        do:
          {frames ++
             [
               Map.merge(
                 notice,
                 %{
                   "type" => "change",
                   "schemaVersion" => 1,
                   "subscriptionId" => id,
                   "seq" => n + 1
                 }
               )
             ], n + 1},
        else: {frames, n}
    end)
  end

  def matches?(notice, filters) do
    refs = notice["refs"] || %{}
    classes = filters["classes"]

    (is_nil(classes) or
       (is_list(classes) and
          Enum.any?(
            classes,
            &(is_binary(&1) and String.starts_with?(notice["class"] || "", &1))
          ))) and
      Enum.all?(
        ~w(sessionKey workItemId origin principal),
        &(is_nil(filters[&1]) or filters[&1] == refs[&1])
      )
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

  defp update(state, pid, fun) do
    case state.sockets[pid] do
      nil -> state
      socket -> put_in(state.sockets[pid], fun.(socket))
    end
  end

  defp drop(state, pid) do
    {socket, sockets} = Map.pop(state.sockets, pid)
    if socket, do: Process.demonitor(socket.monitor, [:flush])
    state = %{state | sockets: sockets}

    if state.shutdown_waiter && map_size(sockets) == 0 do
      GenServer.reply(state.shutdown_waiter, :ok)
      %{state | shutdown_waiter: nil}
    else
      state
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _}, state) do
    case state.sockets[pid] do
      %{monitor: ^monitor} -> {:noreply, drop(state, pid)}
      _ -> {:noreply, state}
    end
  end
end
