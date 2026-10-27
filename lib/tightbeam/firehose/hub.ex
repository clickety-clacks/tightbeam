defmodule Tightbeam.Firehose.Hub do
  @moduledoc "Live-only Firehose fanout; startup is owned by Gateway."
  use GenServer
  require Logger
  alias Tightbeam.Firehose.Publisher

  # An approximately 2 GB held-backlog budget across 30 stalled apps gives each app about 64 MB.
  @max_app_backlog_bytes 64 * 1_024 * 1_024

  defmodule Socket do
    @moduledoc false
    defstruct monitor: nil,
              mode: :pending,
              user_id: nil,
              device_id: nil,
              principal_kind: nil,
              principal_id: nil,
              subscriptions: %{},
              pending_subscriptions: %{},
              pending_notices: :queue.new(),
              pending_notice_bytes: 0,
              backlog_counter: nil,
              seq: 0,
              overflowed: false
  end

  defstruct sockets: %{}, shutting_down: false, shutdown_waiter: nil

  # Committed outboxes use the same admission path as direct publications.
  def destination(server), do: server

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def register(server \\ __MODULE__, pid \\ self()), do: register(server, pid, %{mode: :all})
  def register(server, pid, opts), do: GenServer.call(server, {:register, pid, opts})

  def subscribe(server, pid, id, filters),
    do: GenServer.call(server, {:subscribe, pid, id, filters})

  def begin_subscribe(server, pid, id, filters),
    do: GenServer.call(server, {:begin_subscribe, pid, id, filters})

  def finish_subscribe(server, pid, id, notices),
    do: GenServer.call(server, {:finish_subscribe, pid, id, notices})

  def unsubscribe(server, pid, id), do: GenServer.call(server, {:unsubscribe, pid, id})
  def sequence(server, pid), do: GenServer.call(server, {:sequence, pid})
  def connection_stats(server, pid), do: GenServer.call(server, {:connection_stats, pid})
  # Kept as a no-op for older internal callers; delivery no longer waits for
  # a per-frame acknowledgement from the socket process.
  def delivered(_server, _pid), do: :ok

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

  def publish(server \\ __MODULE__, notice), do: GenServer.cast(server, {:publish, notice})

  def committed(server \\ __MODULE__, class, payload, refs),
    do: publish(server, Publisher.committed_notice(class, payload, refs))

  def accepted(server \\ __MODULE__, db, call, result),
    do: publish_many(server, Publisher.accepted_notices(db, call, result))

  def denied(server \\ __MODULE__, call, error),
    do: publish_many(server, Publisher.denied_notices(call, error))

  defp publish_many(server, notices) do
    Enum.each(notices, &publish(server, &1))
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

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
            :user_id,
            :device_id,
            :principal_kind,
            :principal_id,
            :backlog_counter
          ])
        )

      {:reply, :ok, put_in(state.sockets[pid], socket)}
    end
  end

  def handle_call({:subscribe, pid, id, filters}, _, state),
    do: {:reply, :ok, update(state, pid, &put_in(&1.subscriptions[id], filters))}

  def handle_call({:begin_subscribe, pid, id, filters}, _, state),
    do: {:reply, :ok, update(state, pid, &put_in(&1.pending_subscriptions[id], filters))}

  def handle_call({:finish_subscribe, pid, id, notices}, _, state) do
    case state.sockets[pid] do
      nil ->
        {:reply, :ok, state}

      socket ->
        case socket.pending_subscriptions[id] do
          nil ->
            {:reply, :ok, state}

          filters ->
            {pending_notices, remaining_notices, pending_notice_bytes} =
              socket.pending_notices
              |> :queue.to_list()
              |> Enum.reduce({[], [], socket.pending_notice_bytes}, fn
                {^id, _notice} = entry, {pending, remaining, bytes} ->
                  {[entry | pending], remaining, bytes - :erlang.external_size(entry)}

                entry, {pending, remaining, bytes} ->
                  {pending, [entry | remaining], bytes}
              end)

            pending_notices = Enum.reverse(pending_notices)
            remaining_notices = Enum.reverse(remaining_notices)

            {snapshot_frames, seq} = matching_notice_frames(notices, id, filters, socket.seq)

            {pending_frames, seq} =
              matching_notice_frames(
                Enum.map(pending_notices, fn {_subscription_id, notice} -> notice end),
                id,
                filters,
                seq
              )

            ready = %{"type" => "subscription_ready", "subscriptionId" => id}

            socket = %{
              socket
              | subscriptions: Map.put(socket.subscriptions, id, filters),
                pending_subscriptions: Map.delete(socket.pending_subscriptions, id),
                pending_notices: :queue.from_list(remaining_notices),
                pending_notice_bytes: pending_notice_bytes,
                seq: seq
            }

            socket =
              enqueue(socket, pid, [ready | snapshot_frames ++ pending_frames])

            {:reply, :ok, put_in(state.sockets[pid], socket)}
        end
    end
  end

  def handle_call({:unsubscribe, pid, id}, _, state),
    do:
      {:reply, :ok, update(state, pid, &%{&1 | subscriptions: Map.delete(&1.subscriptions, id)})}

  def handle_call({:sequence, pid}, _, state),
    do: {:reply, (state.sockets[pid] && state.sockets[pid].seq) || 0, state}

  def handle_call({:connection_stats, pid}, _, state) do
    socket = state.sockets[pid]

    stats =
      if socket do
        %{
          queued: socket_queue_length(pid) + :queue.len(socket.pending_notices),
          in_flight: false,
          overflowed: socket.overflowed,
          seq: socket.seq
        }
      end

    {:reply, stats, state}
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

  def handle_cast({:publish, notice}, state),
    do: {:noreply, fanout(state, notice)}

  def handle_cast(_, state), do: {:noreply, state}

  defp fanout(%{shutting_down: true} = state, _), do: state

  defp fanout(state, notice) do
    sockets =
      Map.new(state.sockets, fn {pid, socket} ->
        {pid, deliver_notice(socket, pid, notice)}
      end)

    %{state | sockets: sockets}
  end

  defp deliver_notice(%{mode: :pending} = socket, _, _), do: socket
  defp deliver_notice(%{overflowed: true} = socket, _, _), do: socket

  defp deliver_notice(socket, pid, notice) do
    if revoked?(notice, socket) do
      send(pid, :firehose_revoked)
      socket
    else
      deliver_matching_notice(socket, pid, notice)
    end
  end

  defp deliver_matching_notice(socket, pid, notice) do
    pending_subscriptions =
      socket.pending_subscriptions
      |> Enum.filter(fn {_id, filters} -> matches?(notice, filters) end)

    frames =
      if socket.mode == :all,
        do: [notice],
        else: matching_frames(notice, socket.subscriptions, socket.seq)

    if (frames == [] and pending_subscriptions == []) or secret_payload?(notice["payload"]) do
      socket
    else
      socket =
        Enum.reduce(pending_subscriptions, socket, fn {id, _filters}, socket ->
          enqueue_pending_notice(socket, pid, {id, notice})
        end)

      if socket.overflowed do
        socket
      else
        seq =
          if frames == [] or socket.mode == :all,
            do: socket.seq,
            else: List.last(frames)["seq"]

        enqueue(%{socket | seq: seq}, pid, frames)
      end
    end
  end

  defp enqueue_pending_notice(socket, _, _) when socket.overflowed, do: socket

  defp enqueue_pending_notice(socket, pid, notice) do
    pending_bytes = :erlang.external_size(notice)
    backlog_bytes = socket_backlog_bytes(socket) + pending_bytes

    if backlog_bytes > @max_app_backlog_bytes do
      overflow(socket, pid, backlog_bytes)
    else
      %{
        socket
        | pending_notices: :queue.in(notice, socket.pending_notices),
          pending_notice_bytes: socket.pending_notice_bytes + pending_bytes
      }
    end
  end

  defp enqueue(socket, _pid, []), do: socket
  defp enqueue(%{overflowed: true} = socket, _pid, _frames), do: socket

  defp enqueue(socket, pid, frames) do
    messages = Enum.map(frames, &outbound_message/1)
    outbound_bytes = Enum.reduce(messages, 0, &(&2 + :erlang.external_size(&1)))
    queued_bytes = reserve_backlog_bytes(socket.backlog_counter, outbound_bytes)
    backlog_bytes = queued_bytes + socket.pending_notice_bytes

    if backlog_bytes > @max_app_backlog_bytes do
      release_backlog_bytes(socket.backlog_counter, outbound_bytes)
      overflow(socket, pid, backlog_bytes)
    else
      Enum.each(messages, &send(pid, &1))
      socket
    end
  end

  defp socket_backlog_bytes(socket),
    do: current_backlog_bytes(socket.backlog_counter) + socket.pending_notice_bytes

  # The socket updates this shared count as it consumes frames, so fanout never scans its mailbox.
  defp current_backlog_bytes(nil), do: 0
  defp current_backlog_bytes(counter), do: :atomics.get(counter, 1)

  defp reserve_backlog_bytes(nil, bytes), do: bytes
  defp reserve_backlog_bytes(counter, bytes), do: :atomics.add_get(counter, 1, bytes)

  defp release_backlog_bytes(nil, _bytes), do: :ok
  defp release_backlog_bytes(counter, bytes), do: :atomics.sub(counter, 1, bytes)

  defp socket_queue_length(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} -> length
      nil -> 0
    end
  end

  defp overflow(socket, pid, backlog_bytes) do
    if not socket.overflowed do
      Logger.warning(
        "firehose app dropped #{inspect(app_identity(socket))} reason=outbound_queue_overflow " <>
          "backlog_bytes=#{backlog_bytes} limit_bytes=#{@max_app_backlog_bytes} " <>
          "close_code=4008 connection=#{inspect(pid)}"
      )

      send(pid, :firehose_overflow)
    end

    %{socket | pending_notices: :queue.new(), pending_notice_bytes: 0, overflowed: true}
  end

  defp app_identity(socket) do
    %{
      principal_kind: socket.principal_kind,
      principal_id: socket.principal_id,
      user_id: socket.user_id,
      device_id: socket.device_id
    }
  end

  defp outbound_message(%{"type" => "subscription_ready"} = frame),
    do: {:firehose_control, frame}

  defp outbound_message(frame), do: {:firehose_notice, Publisher.wire_notice(frame)}

  defp matching_notice_frames(notices, id, filters, seq) do
    {frames, seq} =
      Enum.reduce(notices, {[], seq}, fn notice, {frames, seq} ->
        case matching_frames(notice, %{id => filters}, seq) do
          [] ->
            {frames, seq}

          [frame] ->
            {[frame | frames], frame["seq"]}
        end
      end)

    {Enum.reverse(frames), seq}
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

  defp revoked?(_notice, %{principal_kind: :observer}), do: false

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
