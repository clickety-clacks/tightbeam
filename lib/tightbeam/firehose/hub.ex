defmodule Tightbeam.Firehose.Hub do
  @moduledoc "Live-only Firehose queue with per-delivery authorization; startup is owned by Gateway."
  use GenServer
  require Logger
  alias Tightbeam.Firehose.Publisher
  alias Tightbeam.StateVisibility

  defmodule Socket do
    @moduledoc false
    defstruct monitor: nil,
              mode: :pending,
              db: nil,
              user_id: nil,
              device_id: nil,
              principal_kind: nil,
              principal_id: nil,
              is_admin: false,
              subscriptions: %{},
              seq: 0,
              queue: :queue.new(),
              queued: 0,
              in_flight: false,
              overflowed: false
  end

  defstruct sockets: %{},
            ingress: nil,
            queue_limit: 1_000,
            shutting_down: false,
            shutdown_waiter: nil

  @ingress_count 1_000
  @ingress_bytes 8 * 1024 * 1024

  defmodule Transport do
    @moduledoc false

    def send(server, {:"$gen_cast", message}),
      do: Tightbeam.Firehose.Hub.ingress(server, message)
  end

  # Committed outboxes use the same admission path as direct publications.
  def destination(server), do: {:via, Transport, server}

  @doc false
  def ingress(server, message) do
    pid = GenServer.whereis(server)

    case :persistent_term.get({__MODULE__, pid}, nil) do
      nil ->
        :ok

      table ->
        bytes = :erlang.external_size(message)
        [count, total] = :ets.update_counter(table, :ingress, [{2, 1}, {3, bytes}])

        if count <= @ingress_count and total <= @ingress_bytes do
          GenServer.cast(pid, {:ingress, bytes, message})
        else
          :ets.update_counter(table, :ingress, [{2, -1}, {3, -bytes}])

          if :ets.insert_new(table, {:overflow, true}),
            do: GenServer.cast(pid, :ingress_overflow)
        end
    end

    :ok
  end

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

  def shutdown(server \\ __MODULE__, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    remaining = deadline - System.monotonic_time(:millisecond)

    result =
      if remaining <= 0 do
        {:error, :deadline_exceeded}
      else
        try do
          GenServer.call(server, {:shutdown, deadline}, remaining)
        catch
          :exit, reason -> {:error, reason}
        end
      end

    if result != :ok, do: Logger.warning("firehose shutdown incomplete: #{inspect(result)}")
    result
  end

  def publish(server \\ __MODULE__, notice), do: ingress(server, {:publish, notice})

  def committed(server \\ __MODULE__, class, payload, refs),
    do: ingress(server, {:committed, class, payload, refs})

  def accepted(server \\ __MODULE__, db, call, result),
    do: ingress(server, {:accepted, db, call, result})

  def denied(server \\ __MODULE__, call, error),
    do: ingress(server, {:denied, call, error})

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:public, :set, write_concurrency: true])
    :ets.insert(table, {:ingress, 0, 0})
    :persistent_term.put({__MODULE__, self()}, table)
    {:ok, %__MODULE__{ingress: table, queue_limit: Keyword.get(opts, :queue_limit, 1_000)}}
  end

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase({__MODULE__, self()})
    :ok
  end

  @impl true
  def handle_call({:register, pid, opts}, _from, state) do
    if state.shutting_down do
      send(pid, :firehose_shutdown)
      {:reply, :ok, state}
    else
      existing = state.sockets[pid]
      socket = existing || %Socket{monitor: Process.monitor(pid)}

      socket =
        struct(
          socket,
          Map.take(opts, [
            :mode,
            :db,
            :user_id,
            :device_id,
            :principal_kind,
            :principal_id,
            :is_admin
          ])
        )

      # Frames were admitted for the identity that queued them. A socket that
      # comes back as someone else keeps only what that identity may see.
      socket =
        if existing && authorization(existing) != authorization(socket),
          do: requeue_visible(socket),
          else: socket

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

  def handle_call({:shutdown, deadline}, from, state) do
    Process.send_after(
      self(),
      {:shutdown_timeout, from},
      max(deadline - System.monotonic_time(:millisecond), 0)
    )

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

  def handle_cast({:ingress, bytes, message}, state) do
    try do
      handle_cast(message, state)
    after
      :ets.update_counter(state.ingress, :ingress, [{2, -1}, {3, -bytes}])
    end
  end

  def handle_cast(:ingress_overflow, state) do
    :ets.delete(state.ingress, :overflow)

    sockets =
      Map.new(state.sockets, fn {pid, socket} ->
        if not socket.overflowed, do: send(pid, :firehose_overflow)
        {pid, %{socket | queue: :queue.new(), queued: 0, overflowed: true}}
      end)

    {:noreply, %{state | sockets: sockets}}
  end

  def handle_cast({:committed, _, _, _}, %{shutting_down: true} = state),
    do: {:noreply, state}

  def handle_cast({:committed, class, payload, refs}, state)
      when class in ~w(session.spawned session.updated session.harness_changed session.retired) do
    session_key = refs["sessionKey"] || payload[:session_key] || payload["sessionKey"]
    owner = refs["ownerUserId"] || payload[:owner_user_id] || payload["ownerUserId"]

    probe = %{
      "class" => class,
      "refs" => Map.merge(refs, %{"sessionKey" => session_key, "ownerUserId" => owner}),
      "payload" => %{"sessionKey" => session_key, "ownerUserId" => owner}
    }

    eligible =
      Enum.filter(state.sockets, fn {pid, socket} ->
        cond do
          socket.mode == :pending or socket.overflowed ->
            false

          revoked?(probe, socket) ->
            send(pid, :firehose_revoked)
            false

          true ->
            interested?(socket, probe) and visible?(socket, probe)
        end
      end)

    # Deriving session capabilities can query the database. Only do it after
    # subscriptions and visibility admit a recipient, then reuse that decision.
    sockets =
      if eligible == [] do
        state.sockets
      else
        notice = Publisher.committed_notice(class, payload, refs)

        Enum.reduce(eligible, state.sockets, fn {pid, socket}, sockets ->
          Map.put(
            sockets,
            pid,
            deliver_visible_notice(socket, pid, notice, state.queue_limit, true)
          )
        end)
      end

    {:noreply, %{state | sockets: sockets}}
  end

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

  defp interested?(%{mode: :all}, _notice), do: true

  defp interested?(socket, notice),
    do: Enum.any?(socket.subscriptions, fn {_id, filters} -> matches?(notice, filters) end)

  defp deliver_visible_notice(socket, pid, notice, limit, authorized? \\ false) do
    frames =
      if socket.mode == :all,
        do: [notice],
        else: matching_frames(notice, socket.subscriptions, socket.seq)

    if frames != [] and not secret_payload?(notice["payload"]) and
         (authorized? or visible?(socket, notice)) do
      seq = if socket.mode == :all, do: socket.seq, else: List.last(frames)["seq"]
      enqueue(%{socket | seq: seq}, pid, Enum.map(frames, &Publisher.wire_notice/1), limit)
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

        send(pid, {:firehose_notice, frame})
        %{socket | in_flight: true}

      {:empty, _} ->
        socket
    end
  end

  defp matching_frames(notice, subscriptions, seq) do
    {frames, _seq} =
      Enum.sort(subscriptions)
      |> Enum.reduce({[], seq}, fn {id, filters}, {frames, n} ->
        if matches?(notice, filters),
          do:
            {[
               Map.merge(notice, %{
                 "type" => "change",
                 "schemaVersion" => 2,
                 "subscriptionId" => id,
                 "seq" => n + 1
               })
               | frames
             ], n + 1},
          else: {frames, n}
      end)

    Enum.reverse(frames)
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

    if socket.principal_kind == :session do
      refs["sessionKey"] == socket.principal_id or payload["sessionKey"] == socket.principal_id
    else
      payload["ownerUserId"] == socket.user_id or refs["ownerUserId"] == socket.user_id
    end
  end

  defp revoked?(_notice, _socket), do: false

  defp visible?(%{principal_kind: :session, principal_id: session_key, db: db}, notice),
    do: StateVisibility.visible?(db, notice, %{kind: "session", id: session_key})

  defp visible?(
         %{principal_kind: :user, principal_id: user_id, db: db, is_admin: is_admin},
         notice
       ),
       do: StateVisibility.visible?(db, notice, user_id, is_admin)

  defp visible?(socket, notice),
    do: StateVisibility.visible?(socket.db, notice, socket.user_id, socket.is_admin)

  defp secret_payload?(payload) when is_map(payload) do
    Enum.any?(payload, fn {key, value} ->
      key in ["cliToken", "token", "identityToken"] or secret_payload?(value)
    end)
  end

  defp secret_payload?(payload) when is_list(payload), do: Enum.any?(payload, &secret_payload?/1)
  defp secret_payload?(_payload), do: false

  defp authorization(socket),
    do: Map.take(socket, [:mode, :user_id, :principal_kind, :principal_id, :is_admin])

  defp requeue_visible(socket) do
    frames =
      socket.queue
      |> :queue.to_list()
      |> Enum.filter(&(socket.mode != :pending and visible?(socket, &1)))

    %{socket | queue: :queue.from_list(frames), queued: length(frames)}
  end

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
  def handle_info({:shutdown_timeout, from}, %{shutdown_waiter: from} = state) do
    GenServer.reply(from, {:error, :deadline_exceeded})
    {:noreply, %{state | shutdown_waiter: nil}}
  end

  def handle_info({:shutdown_timeout, _from}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, pid, _}, state) do
    case state.sockets[pid] do
      %{monitor: ^monitor} -> {:noreply, drop(state, pid)}
      _ -> {:noreply, state}
    end
  end
end
