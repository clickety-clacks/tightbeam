defmodule Tightbeam.HarklightWakes do
  @moduledoc """
  Durable, origin-bound handoff from a Harklight controller stream to ordinary
  prompt wakes. The external CLI owns the feed journal and cursor; this table
  owns each handle's sender and follower subscriptions and remembers every line
  captured for one or more sessions.
  """

  use GenServer
  require Logger
  alias Tightbeam.{DB, ErrorDiagnostic, HarklightLifecycle, Org, Placement, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  @attach_retry_delays [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000]
  @attach_retry_window_ms 180_000
  # Released Server serializes every origin attach through one Relay process.
  # Restore starts all listeners at once, so cap concurrent attach attempts to
  # keep that queue inside the Relay call timeout (WI2979 fifth fleet run).
  @attach_concurrency 4

  @max_diagnostic_lines 3
  @max_diagnostic_line_chars 240
  @max_diagnostic_chars 768

  @ddl """
  CREATE TABLE IF NOT EXISTS harklight_send_operations (
    opId TEXT PRIMARY KEY,
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    host TEXT NOT NULL,
    payload TEXT NOT NULL,
    result TEXT,
    handle TEXT,
    senderId TEXT,
    messageId TEXT,
    attemptedAt INTEGER,
    state TEXT NOT NULL CHECK(state IN ('pending','bound')),
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL,
    CHECK ((state='pending' AND result IS NULL AND handle IS NULL AND senderId IS NULL AND messageId IS NULL)
       OR (state='bound' AND result IS NOT NULL AND handle IS NOT NULL AND senderId IS NOT NULL AND messageId IS NOT NULL))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS harklight_send_bound_request
    ON harklight_send_operations(senderId,messageId);
  CREATE TABLE IF NOT EXISTS harklight_pending_supersedes (
    opId TEXT NOT NULL REFERENCES harklight_send_operations(opId),
    senderId TEXT NOT NULL,
    messageId TEXT NOT NULL,
    PRIMARY KEY(opId,senderId,messageId)
  );
  CREATE INDEX IF NOT EXISTS harklight_pending_supersedes_target
    ON harklight_pending_supersedes(senderId,messageId,opId);
  CREATE TABLE IF NOT EXISTS harklight_wake_handles (
    handle TEXT PRIMARY KEY,
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    host TEXT NOT NULL,
    vendorSessionId TEXT,
    state TEXT NOT NULL CHECK(state IN ('active','complete','unavailable')),
    lastCursor INTEGER NOT NULL DEFAULT 0,
    lastError TEXT,
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS harklight_wake_requests (
    senderId TEXT NOT NULL,
    messageId TEXT NOT NULL,
    handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
    PRIMARY KEY(senderId,messageId)
  );
  CREATE TABLE IF NOT EXISTS harklight_wake_follows (
    followId TEXT PRIMARY KEY,
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    kind TEXT NOT NULL CHECK(kind IN ('message','conversation')),
    handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
    senderId TEXT,
    messageId TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('open','ended')),
    createdAt INTEGER NOT NULL,
    endedAt INTEGER,
    CHECK ((kind='conversation' AND senderId IS NULL AND messageId='') OR
           (kind='message' AND senderId IS NOT NULL AND messageId<>''))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS harklight_wake_follows_open
    ON harklight_wake_follows(sessionKey,kind,handle,messageId) WHERE state='open';
  CREATE TABLE IF NOT EXISTS harklight_wake_entries (
    handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
    eventId TEXT NOT NULL,
    feedCursor INTEGER NOT NULL,
    senderId TEXT NOT NULL,
    messageId TEXT NOT NULL,
    requestRevision INTEGER,
    entryKind TEXT NOT NULL,
    entryAuthor TEXT NOT NULL,
    rawLine TEXT NOT NULL,
    wakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
    capturedAt INTEGER NOT NULL,
    PRIMARY KEY(handle,eventId),
    UNIQUE(handle,feedCursor)
  );
  CREATE TABLE IF NOT EXISTS harklight_wake_deliveries (
    handle TEXT NOT NULL,
    eventId TEXT NOT NULL,
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    wakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
    PRIMARY KEY(handle,eventId,sessionKey),
    FOREIGN KEY(handle,eventId) REFERENCES harklight_wake_entries(handle,eventId)
  );
  CREATE TABLE IF NOT EXISTS harklight_wake_suppressed_entries (
    handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
    eventId TEXT NOT NULL,
    feedCursor INTEGER NOT NULL,
    senderId TEXT NOT NULL,
    messageId TEXT NOT NULL,
    requestRevision INTEGER,
    entryKind TEXT NOT NULL,
    entryAuthor TEXT NOT NULL,
    rawLine TEXT NOT NULL,
    capturedAt INTEGER NOT NULL,
    PRIMARY KEY(handle,eventId),
    UNIQUE(handle,feedCursor)
  );
  CREATE INDEX IF NOT EXISTS harklight_wake_requests_handle
    ON harklight_wake_requests(handle);
  CREATE INDEX IF NOT EXISTS harklight_wake_follows_handle
    ON harklight_wake_follows(handle,state,kind,messageId);
  CREATE INDEX IF NOT EXISTS harklight_wake_deliveries_session
    ON harklight_wake_deliveries(sessionKey,handle,eventId);
  """

  @uuid4 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def ensure_schema(db \\ DB) do
    with :ok <- DB.execute(db, @ddl),
         :ok <- HarklightLifecycle.ensure_schema(db),
         :ok <- Tightbeam.HarklightOrigin.ensure_schema(db) do
      backfill_pending_supersedes(db)
    end
  end

  @doc false
  def ack2_for_dispatched_turn(db, turn_seq, session_key, agent_name, opts \\ []) do
    query = """
    SELECT DISTINCT e.handle,e.eventId,h.sessionKey
    FROM wakes w
    LEFT JOIN wake_retry_attempts retry ON retry.wakeId=w.wakeId
    JOIN harklight_wake_deliveries d
      ON d.wakeId=COALESCE(retry.rootWakeId,w.wakeId) AND d.sessionKey=w.sessionKey
    JOIN harklight_wake_entries e ON e.handle=d.handle AND e.eventId=d.eventId
    JOIN harklight_wake_handles h ON h.handle=e.handle
    WHERE w.deliveredTurnSeq=?1 AND d.sessionKey=?2
      AND e.entryKind IN ('discussion','terminal') AND e.entryAuthor='person'
      AND EXISTS (
        SELECT 1 FROM turn_lifecycle_events event
        WHERE event.turnSeq=w.deliveredTurnSeq AND event.kind='prompt_dispatched'
      )
    ORDER BY e.feedCursor,e.handle,e.eventId
    """

    case DB.query(db, query, [turn_seq, session_key]) do
      {:ok, []} ->
        :ok

      {:ok, entries} ->
        case ack2_runner(opts) do
          {:ok, runner} ->
            Enum.each(entries, fn [handle, event_id, owner_session_key] ->
              args =
                ["ack2", "--session", handle, "--event", event_id, "--agent", agent_name]

              args = if owner_session_key == session_key, do: args, else: args ++ ["--rerouted"]

              case safe_ack2_call(runner, args) do
                {:ok, {_output, 0}} ->
                  :ok

                {:ok, {_output, status}} ->
                  Logger.error(
                    "Harklight ACK2 failed for dispatched turn #{turn_seq} (exit status #{inspect(status)})"
                  )

                :error ->
                  Logger.error("Harklight ACK2 could not run for dispatched turn #{turn_seq}")
              end
            end)

            :ok

          {:error, reason} ->
            Logger.error(
              "Harklight ACK2 could not run for dispatched turn #{turn_seq}: #{reason}"
            )

            :ok
        end

      {:error, reason} ->
        Logger.error(
          "Harklight ACK2 lookup failed for dispatched turn #{turn_seq}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp ack2_runner(opts) do
    case Keyword.get(opts, :runner) do
      runner when is_function(runner, 1) ->
        {:ok, runner}

      nil ->
        case System.find_executable("harklight-agent") do
          nil ->
            {:error, "harklight_cli_missing"}

          executable ->
            {:ok, fn args -> System.cmd(executable, args, stderr_to_stdout: true) end}
        end
    end
  end

  defp safe_ack2_call(runner, args) do
    case runner.(args) do
      result when is_tuple(result) and tuple_size(result) == 2 -> {:ok, result}
      _other -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def retirement_handoff_in_txn(%Txn{} = txn, session_key) do
    rows =
      Txn.q(
        txn,
        """
        SELECT handle,sessionKey,host,state
        FROM harklight_wake_handles
        WHERE sessionKey=?1
        UNION
        SELECT h.handle,h.sessionKey,h.host,h.state
        FROM harklight_wake_handles h
        JOIN harklight_wake_follows f ON f.handle=h.handle
        WHERE f.sessionKey=?1 AND f.state='open'
        """,
        [session_key]
      )

    handles = Enum.map(rows, fn [handle, _origin_session_key, _host, _state] -> handle end)

    gone_handles =
      for [handle, origin_session_key, host, _state] <- rows,
          not actual_receiver_eligible_in_txn?(txn, handle, origin_session_key, host),
          do: handle

    {:origin_retired, session_key, handles, gone_handles}
  end

  # The caller of these functions is the runtime-owned send boundary. Its
  # external adapter must execute or recover only this persisted operation and
  # must pass the original confirmed result to bind_send/8. No wire command may
  # assert a result or binding on the adapter's behalf.
  def prepare_send(db, call, op_id, payload) do
    session_key = call.session_key

    with true <- authenticated_origin?(call),
         true <- is_binary(op_id) and Regex.match?(@uuid4, op_id),
         true <- is_binary(payload) and payload != "",
         %{state: "active", host: host} <- Org.get(db, session_key),
         true <- host == Placement.local_host_name() do
      now = System.system_time(:millisecond)
      supersedes = pending_supersede_targets(payload)

      case DB.transaction(db, fn txn ->
             case Txn.q(
                    txn,
                    "SELECT sessionKey,host,payload,state FROM harklight_send_operations WHERE opId=?1",
                    [op_id]
                  ) do
               [] ->
                 Txn.q(
                   txn,
                   "INSERT INTO harklight_send_operations(opId,sessionKey,host,payload,state,createdAt,updatedAt) VALUES(?1,?2,?3,?4,'pending',?5,?5)",
                   [op_id, session_key, host, payload, now]
                 )

                 insert_pending_supersedes(txn, op_id, supersedes)

                 {:ok, "pending"}

               [[^session_key, ^host, ^payload, state]] ->
                 if state == "pending" and
                      Txn.q(
                        txn,
                        "SELECT 1 FROM harklight_command_results WHERE opId=?1",
                        [op_id]
                      ) == [] do
                   insert_pending_supersedes(txn, op_id, supersedes)
                 end

                 {:ok, state}

               _ ->
                 {:error, "harklight_send_mismatch"}
             end
           end) do
        {:ok, {:ok, state}} -> %{op_id: op_id, state: state}
        {:ok, {:error, reason}} -> %{code: reason}
        {:error, reason} -> %{code: "harklight_send_unavailable", message: inspect(reason)}
      end
    else
      _ -> %{code: "harklight_origin_unavailable"}
    end
  end

  def bind_send(db, call, op_id, payload, result, handle, sender_id, message_id) do
    session_key = call.session_key

    with true <- authenticated_origin?(call),
         true <- is_binary(op_id) and Regex.match?(@uuid4, op_id),
         true <- is_binary(payload) and payload != "" and is_binary(result) and result != "",
         true <- is_binary(handle) and Regex.match?(@uuid4, handle),
         true <-
           is_binary(sender_id) and sender_id != "" and is_binary(message_id) and message_id != "",
         %{state: "active", host: host} <- Org.get(db, session_key),
         true <- host == Placement.local_host_name() do
      now = System.system_time(:millisecond)
      pointer = Org.current_pointer(db, session_key)
      vendor_id = if pointer, do: pointer.harness_session_id, else: nil

      case DB.transaction(db, fn txn ->
             case Txn.q(
                    txn,
                    "SELECT sessionKey,host,payload,result,handle,senderId,messageId,state FROM harklight_send_operations WHERE opId=?1",
                    [op_id]
                  ) do
               [[^session_key, ^host, ^payload, nil, nil, nil, nil, "pending"]] ->
                 Txn.q(
                   txn,
                   "UPDATE harklight_send_operations SET result=?2,handle=?3,senderId=?4,messageId=?5,state='bound',updatedAt=?6 WHERE opId=?1",
                   [op_id, result, handle, sender_id, message_id, now]
                 )

                 case register_in_txn(
                        txn,
                        handle,
                        session_key,
                        host,
                        sender_id,
                        message_id,
                        vendor_id,
                        now
                      ) do
                   {:ok, registration} ->
                     effects =
                       HarklightLifecycle.send_committed_in_txn(
                         txn,
                         session_key,
                         op_id,
                         payload,
                         result
                       )

                     {:ok, Map.merge(registration, effects)}

                   error ->
                     error
                 end

               [
                 [
                   ^session_key,
                   ^host,
                   ^payload,
                   ^result,
                   ^handle,
                   ^sender_id,
                   ^message_id,
                   "bound"
                 ]
               ] ->
                 case register_in_txn(
                        txn,
                        handle,
                        session_key,
                        host,
                        sender_id,
                        message_id,
                        vendor_id,
                        now
                      ) do
                   {:ok, registration} ->
                     effects =
                       HarklightLifecycle.send_committed_in_txn(
                         txn,
                         session_key,
                         op_id,
                         payload,
                         result
                       )

                     {:ok, Map.merge(registration, effects)}

                   error ->
                     error
                 end

               _ ->
                 {:error, "harklight_send_mismatch"}
             end
           end) do
        {:ok, {:ok, registration}} ->
          activate(handle, registration.rearm)
          registration |> Map.delete(:rearm) |> Map.put(:op_id, op_id)

        {:ok, {:error, reason}} ->
          %{code: reason}

        {:error, reason} ->
          %{code: "harklight_send_unavailable", message: inspect(reason)}
      end
    else
      _ -> %{code: "harklight_origin_unavailable"}
    end
  end

  defp authenticated_origin?(call) do
    is_binary(call.session_key) and call.principal == {:session, call.session_key} and
      call.transport_session_key == call.session_key
  end

  def mark_send_attempt(db, call, op_id, payload) do
    with true <- authenticated_origin?(call),
         %{state: "active", host: host} <- Org.get(db, call.session_key),
         true <- host == Placement.local_host_name() do
      case DB.transaction(db, fn txn ->
             case Txn.q(
                    txn,
                    "SELECT sessionKey,host,payload,state FROM harklight_send_operations WHERE opId=?1",
                    [op_id]
                  ) do
               [[session, ^host, ^payload, "pending"]] when session == call.session_key ->
                 Txn.q(
                   txn,
                   "UPDATE harklight_send_operations SET attemptedAt=COALESCE(attemptedAt,?2),updatedAt=?2 WHERE opId=?1",
                   [op_id, System.system_time(:millisecond)]
                 )

                 :ok

               _ ->
                 {:error, "harklight_send_mismatch"}
             end
           end) do
        {:ok, :ok} -> :ok
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, _} -> {:error, "harklight_send_unavailable"}
      end
    else
      _ -> {:error, "harklight_origin_unavailable"}
    end
  end

  def pending_send_attempts(db) do
    DB.query(
      db,
      "SELECT opId,sessionKey,payload FROM harklight_send_operations WHERE state='pending' AND attemptedAt IS NOT NULL AND opId NOT IN (SELECT opId FROM harklight_command_results) ORDER BY attemptedAt,opId"
    )
  end

  def register(db, call) do
    p = call.params
    session_key = call.session_key
    handle = p[:harklight_handle]
    sender_id = p[:harklight_sender_id]
    message_id = p[:harklight_message_id]
    supplied_vendor_id = p[:harklight_vendor_session_id]
    pointer = if is_binary(session_key), do: Org.current_pointer(db, session_key)
    vendor_id = if pointer, do: pointer.harness_session_id, else: supplied_vendor_id

    with true <- authenticated_origin?(call),
         true <- is_binary(handle) and Regex.match?(@uuid4, handle),
         true <-
           is_binary(sender_id) and sender_id != "" and is_binary(message_id) and
             message_id != "" and (is_nil(supplied_vendor_id) or is_binary(supplied_vendor_id)),
         true <- is_nil(supplied_vendor_id) or is_nil(pointer) or supplied_vendor_id == vendor_id,
         %{state: "active", host: host} <- Org.get(db, session_key),
         true <- host == Placement.local_host_name() do
      now = System.system_time(:millisecond)

      case DB.transaction(db, fn txn ->
             register_in_txn(
               txn,
               handle,
               session_key,
               host,
               sender_id,
               message_id,
               vendor_id,
               now
             )
           end) do
        {:ok, {:ok, result}} ->
          activate(handle, result.rearm)
          Map.delete(result, :rearm)

        {:ok, {:error, reason}} ->
          %{code: reason}

        {:error, reason} ->
          %{code: "harklight_registration_unavailable", message: inspect(reason)}
      end
    else
      _ ->
        %{
          code: "harklight_origin_unavailable",
          message: "registration requires the active originating session on this host"
        }
    end
  end

  defp register_in_txn(txn, handle, session_key, host, sender_id, message_id, vendor_id, now) do
    existing =
      Txn.q(
        txn,
        "SELECT sessionKey,host,state,vendorSessionId FROM harklight_wake_handles WHERE handle=?1",
        [handle]
      )

    request =
      Txn.q(
        txn,
        "SELECT handle FROM harklight_wake_requests WHERE senderId=?1 AND messageId=?2",
        [sender_id, message_id]
      )

    provenance =
      Txn.q(
        txn,
        "SELECT 1 FROM harklight_send_operations WHERE sessionKey=?1 AND host=?2 AND handle=?3 AND senderId=?4 AND messageId=?5 AND state='bound'",
        [session_key, host, handle, sender_id, message_id]
      )

    cond do
      provenance != [[1]] ->
        {:error, "harklight_send_pending"}

      existing != [] and Enum.take(hd(existing), 2) != [session_key, host] ->
        {:error, "harklight_origin_mismatch"}

      request != [] and request != [[handle]] ->
        {:error, "harklight_request_mismatch"}

      true ->
        new_request = request == []
        completed = existing != [] and Enum.at(hd(existing), 2) == "complete"

        rearm =
          existing != [] and
            ((completed and new_request) or
               (not completed and Enum.at(hd(existing), 3) != vendor_id))

        if existing == [] do
          Txn.q(
            txn,
            "INSERT INTO harklight_wake_handles(handle,sessionKey,host,vendorSessionId,state,createdAt,updatedAt) VALUES(?1,?2,?3,?4,'active',?5,?5)",
            [handle, session_key, host, vendor_id, now]
          )
        else
          [[_, _, state, previous_vendor]] = existing

          if (state == "complete" and new_request) or
               (state != "complete" and previous_vendor != vendor_id) do
            Txn.q(
              txn,
              "UPDATE harklight_wake_handles SET state='active',vendorSessionId=?2,lastError=NULL,updatedAt=?3 WHERE handle=?1",
              [handle, vendor_id, now]
            )
          end
        end

        if request == [] do
          Txn.q(
            txn,
            "INSERT INTO harklight_wake_requests(senderId,messageId,handle) VALUES(?1,?2,?3)",
            [sender_id, message_id, handle]
          )
        end

        status = if completed and not new_request, do: "complete", else: "registered"
        {:ok, %{handle: handle, session_key: session_key, state: status, rearm: rearm}}
    end
  end

  def activate(handle, force \\ false) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, {:activate, handle, force})
    :ok
  end

  @doc false
  def reconnect_handle(handle, caller_session_key, server \\ __MODULE__) do
    GenServer.call(server, {:reconnect_handle, handle, caller_session_key}, :infinity)
  end

  def origin_ready(session_key) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, {:origin_ready, session_key})
    :ok
  end

  def origin_turn_ended(session_key) do
    if pid = Process.whereis(__MODULE__),
      do: GenServer.cast(pid, {:origin_turn_ended, session_key})

    :ok
  end

  def h8a_acknowledged(handle) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, {:h8a_acknowledged, handle})
    :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :restore)
    delays = Keyword.get(opts, :attach_retry_delays, @attach_retry_delays)
    window = Keyword.get(opts, :attach_retry_window_ms, @attach_retry_window_ms)

    {:ok,
     %{
       db: Keyword.get(opts, :db, DB),
       child_opts:
         Keyword.get(
           opts,
           :child_opts,
           Application.get_env(:tightbeam, :harklight_child_opts, [])
         ),
       listener:
         Keyword.get(opts, :listener, fn manager, handle, vendor_id ->
           run_listener(manager, handle, vendor_id, delays, window)
         end),
       send_runner: Keyword.get(opts, :send_runner),
       workers: %{},
       ports: %{},
       refs: %{},
       failures: %{},
       attempts: %{},
       retry_timers: %{},
       reconnect_waiters: %{},
       gone_tasks: %{},
       deferred: MapSet.new(),
       retry_delays: Keyword.get(opts, :retry_delays, [1_000, 2_000, 4_000, 8_000, 16_000]),
       restart: MapSet.new(),
       stopping: MapSet.new(),
       attach_limit: Keyword.get(opts, :attach_concurrency, @attach_concurrency),
       attach_slots: MapSet.new(),
       attach_waiting: :queue.new()
     }}
  end

  @impl true
  def handle_info(:restore, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle FROM harklight_wake_handles WHERE state IN ('active','unavailable') AND NOT EXISTS (SELECT 1 FROM harklight_origin_moves m WHERE m.handle=harklight_wake_handles.handle) ORDER BY createdAt,handle"
      )

    state = Enum.reduce(rows, state, fn [handle], acc -> start_worker(acc, handle, :startup) end)

    Task.start(fn ->
      Tightbeam.HarklightSend.recover_pending(state.db, runner: state.send_runner)
      HarklightLifecycle.process_terminals(state.db, runner: state.send_runner)
    end)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state = release_attach_slot(state, pid)

    case Map.pop(state.gone_tasks, ref) do
      {handle, tasks} when is_binary(handle) ->
        state = %{state | gone_tasks: tasks}

        if MapSet.member?(state.deferred, handle) do
          mode =
            cond do
              MapSet.member?(state.deferred, {handle, :new_request}) -> :new_request
              MapSet.member?(state.deferred, {handle, :startup}) -> :startup
              true -> :existing
            end

          deferred =
            state.deferred
            |> MapSet.delete(handle)
            |> MapSet.delete({handle, :new_request})
            |> MapSet.delete({handle, :startup})

          {:noreply, start_worker(%{state | deferred: deferred}, handle, mode)}
        else
          {:noreply, state}
        end

      {nil, _} ->
        worker_down(state, ref)
    end
  end

  def handle_info({:retry_listener, handle, token}, state) do
    case Map.get(state.retry_timers, handle) do
      {_, ^token} ->
        {:noreply,
         start_worker(%{state | retry_timers: Map.delete(state.retry_timers, handle)}, handle)}

      _ ->
        {:noreply, state}
    end
  end

  # DOWN owns worker bookkeeping. Linked exits ensure a controller crash cannot
  # leave a worker holding the original handle's listener lock.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp worker_down(state, ref) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {handle, refs} ->
        state = reply_reconnect_waiter(state, ref, reconnect_worker_down_result())

        state = %{
          state
          | refs: refs,
            workers: Map.delete(state.workers, handle),
            ports: Map.delete(state.ports, handle),
            restart: MapSet.delete(state.restart, {handle, :deciding})
        }

        cond do
          Tightbeam.HarklightOrigin.managed?(state.db, handle) ->
            {:noreply,
             %{
               state
               | stopping: MapSet.delete(state.stopping, handle),
                 restart: MapSet.delete(state.restart, handle)
             }}

          MapSet.member?(state.stopping, handle) ->
            {:noreply, %{state | stopping: MapSet.delete(state.stopping, handle)}}

          MapSet.member?(state.restart, handle) ->
            mode =
              if MapSet.member?(state.restart, {handle, :new_request}),
                do: :new_request,
                else: :existing

            state = %{
              state
              | restart:
                  state.restart |> MapSet.delete(handle) |> MapSet.delete({handle, :new_request})
            }

            {:noreply, start_worker(state, handle, mode)}

          true ->
            mark_terminated(state.db, handle)
            {:noreply, recover_worker(state, handle)}
        end
    end
  end

  # A retry starts only after the old worker has terminated. A gone request is
  # also serialized with later attachment so a late response cannot mark a
  # newly attached conversation gone.
  defp recover_worker(state, handle) do
    status = Map.get(state.failures, handle, "listener_terminated")

    case DB.query(
           state.db,
           "SELECT sessionKey,host,state FROM harklight_wake_handles WHERE handle=?1",
           [handle]
         ) do
      {:ok, [[session_key, host, handle_state]]} when handle_state != "complete" ->
        attempt = Map.get(state.attempts, handle, 0)
        delay = Enum.at(state.retry_delays, attempt)

        if listener_eligible?(state.db, handle, session_key, host) and
             retryable_failure?(status) and is_integer(delay) do
          token = make_ref()
          timer = Process.send_after(self(), {:retry_listener, handle, token}, delay)

          %{
            state
            | attempts: Map.put(state.attempts, handle, attempt + 1),
              retry_timers: Map.put(state.retry_timers, handle, {timer, token})
          }
        else
          start_gone(state, handle)
        end

      _ ->
        state
    end
  end

  defp start_gone(state, handle) do
    if handle in Map.values(state.gone_tasks) do
      state
    else
      {:ok, pid} = Task.start_link(fn -> send_origin_gone(handle) end)
      %{state | gone_tasks: Map.put(state.gone_tasks, Process.monitor(pid), handle)}
    end
  end

  # A lock refusal does not identify its owner. It can be our previous child
  # still releasing the lock; bounded attempts let that clear. The Agent takes
  # the exclusive lock before attaching, so a held lock never starts a second
  # stream. Persistent contention ends in gone with its observed reason intact.
  defp retryable_failure?({:harklight_failure, {_error, code}, _, _}) do
    code not in ~w(missing_journal unproven_handle invalid_handle invalid_attachment
      invalid_attachment_receipt support_mismatch configuration_error
      not_found forbidden operation_conflict invalid_field unsupported_version
      feed_gap feed_conflict invalid_notice invalid_response)
  end

  defp retryable_failure?({:harklight_failure, error, _, _}), do: retryable_failure?(error)

  defp retryable_failure?(error),
    do: error not in ~w(origin_unavailable origin_host_mismatch listener_unsupported
      event_identity_invalid event_identity_mismatch event_order_invalid invalid_listener_line
      unexpected_listener_line)

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.retry_timers, fn {_, {timer, _}} -> Process.cancel_timer(timer) end)
    Enum.each(state.ports, fn {_handle, port} -> close_listener_port(port) end)
    Enum.each(state.workers, fn {_handle, worker} -> Process.exit(worker, :shutdown) end)
  end

  def handle_cast({:pointer_changed, session_key}, state) do
    Tightbeam.HarklightOriginListener.resume_session(session_key)

    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle FROM harklight_wake_handles WHERE sessionKey=?1 AND state IN ('active','unavailable') AND NOT EXISTS (SELECT 1 FROM harklight_origin_moves m WHERE m.handle=harklight_wake_handles.handle)",
        [session_key]
      )

    {:noreply, Enum.reduce(rows, state, fn [handle], acc -> force_worker(acc, handle) end)}
  end

  def handle_cast({:origin_changed, session_key}, state) do
    {:noreply, reconcile_origin(state, session_key)}
  end

  def handle_cast({:origin_retired, _session_key, handles, gone_handles}, state) do
    {:noreply, reconcile_retirement(state, handles, MapSet.new(gone_handles))}
  end

  def handle_cast({:decision_slot, pid, ref}, state),
    do: handle_cast({:attach_slot, pid, {:decision, ref}}, state)

  def handle_cast({:attach_slot, pid, ref}, state) do
    if MapSet.size(state.attach_slots) < state.attach_limit do
      send(pid, {:attach_slot, ref})
      {:noreply, %{state | attach_slots: MapSet.put(state.attach_slots, pid)}}
    else
      # Share the existing bounded slot pool. Actual attachments retain FIFO
      # order ahead of queued decisions, so startup reads cannot monopolize it.
      waiting =
        if is_tuple(ref) do
          :queue.in({pid, ref}, state.attach_waiting)
        else
          {attaches, decisions} =
            state.attach_waiting
            |> :queue.to_list()
            |> Enum.split_while(fn {_, queued_ref} -> not is_tuple(queued_ref) end)

          :queue.from_list(attaches ++ [{pid, ref}] ++ decisions)
        end

      {:noreply, %{state | attach_waiting: waiting}}
    end
  end

  def handle_cast({:attach_slot_released, pid}, state),
    do: {:noreply, release_attach_slot(state, pid)}

  @impl true
  def handle_cast({:activate, handle, true}, state) do
    Tightbeam.HarklightOriginListener.resume_handle(handle)

    if Tightbeam.HarklightOrigin.managed?(state.db, handle),
      do: {:noreply, state},
      else: {:noreply, force_worker(state, handle, :new_request)}
  end

  def handle_cast({:activate, handle, false}, state) do
    Tightbeam.HarklightOriginListener.resume_handle(handle)
    # Registration must interrupt an outstanding closure read, while an already
    # running listener continues normally.
    state =
      cond do
        Tightbeam.HarklightOrigin.managed?(state.db, handle) ->
          state

        MapSet.member?(state.restart, {handle, :deciding}) ->
          force_worker(state, handle, :new_request)

        true ->
          start_worker(state, handle, :new_request)
      end

    {:noreply, state}
  end

  def handle_cast({:origin_ready, session_key}, state) do
    Tightbeam.HarklightOriginListener.resume_session(session_key)

    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle FROM harklight_wake_handles WHERE sessionKey=?1 AND state IN ('active','unavailable') AND NOT EXISTS (SELECT 1 FROM harklight_origin_moves m WHERE m.handle=harklight_wake_handles.handle) ORDER BY createdAt,handle",
        [session_key]
      )

    {:noreply, Enum.reduce(rows, state, fn [handle], acc -> start_worker(acc, handle) end)}
  end

  def handle_cast({:origin_turn_ended, session_key}, state) do
    case answer_completion_candidates(state.db, session_key) do
      {:ok, candidates} ->
        schedule_answered_checks(self(), state.db, state.send_runner, candidates)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:h8a_acknowledged, handle}, state) do
    schedule_answered_checks(self(), state.db, state.send_runner, [[handle]])
    {:noreply, state}
  end

  def handle_cast({:answer_completion_evidence, handle, evidence}, state) do
    result =
      DB.transaction(state.db, fn txn ->
        HarklightLifecycle.complete_answered_in_txn(txn, handle, evidence)
      end)

    state = if result == {:ok, true}, do: stop_worker(state, handle), else: state
    {:noreply, state}
  end

  defp answer_completion_candidates(db, session_key) do
    DB.query(
      db,
      """
      SELECT DISTINCT h.handle
      FROM harklight_wake_handles h
      JOIN harklight_wake_entries e ON e.handle=h.handle
      WHERE h.state IN ('active','unavailable') AND e.entryKind='terminal' AND e.entryAuthor='person'
        AND (?1 IS NULL OR h.sessionKey=?1)
      ORDER BY h.handle
      """,
      [session_key]
    )
  end

  defp schedule_answered_checks(manager, db, runner, candidates) do
    Task.start(fn -> schedule_answered_checks_now(manager, db, runner, candidates) end)
  end

  defp schedule_answered_checks_now(manager, db, runner, candidates) do
    Enum.each(candidates, fn [handle] ->
      case HarklightLifecycle.completion_evidence(db, handle, runner: runner) do
        {:ok, evidence} ->
          GenServer.cast(manager, {:answer_completion_evidence, handle, evidence})

        _ ->
          :ok
      end
    end)
  end

  defp reconcile_origin(state, session_key) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle,sessionKey,host,state FROM harklight_wake_handles WHERE sessionKey=?1",
        [session_key]
      )

    reconcile_rows(state, rows, MapSet.new())
  end

  defp reconcile_retirement(state, handles, gone_handles) do
    Enum.reduce(handles, state, fn handle, acc ->
      {:ok, rows} =
        DB.query(
          acc.db,
          "SELECT handle,sessionKey,host,state FROM harklight_wake_handles WHERE handle=?1",
          [handle]
        )

      reconcile_rows(acc, rows, gone_handles)
    end)
  end

  defp reconcile_rows(state, rows, gone_handles) do
    Enum.reduce(rows, state, fn [handle, origin_session_key, host, handle_state], acc ->
      if listener_eligible?(acc.db, handle, origin_session_key, host) do
        if handle_state == "complete", do: acc, else: start_worker(acc, handle)
      else
        # Persist invalidation before the worker's DOWN can reach observers.
        mark_finished(acc.db, handle, "origin_unavailable")
        acc = stop_worker(acc, handle)
        notify_pending_origin_unavailable(acc.db, handle)

        cond do
          MapSet.member?(gone_handles, handle) ->
            mark_origin_gone_async(handle)
            acc

          host == Placement.local_host_name() and
              match?(%{state: "active"}, Org.get(acc.db, origin_session_key)) ->
            start_gone(acc, handle)

          true ->
            acc
        end
      end
    end)
  end

  defp actual_receiver_eligible?(db, handle, session_key, host) do
    match?(%{state: "active", host: ^host}, Org.get(db, session_key)) or
      match?(
        {:ok, [[1]]},
        DB.query(
          db,
          """
          SELECT 1
          FROM harklight_wake_follows f
          JOIN sessions s ON s.sessionKey=f.sessionKey
          WHERE f.handle=?1 AND f.state='open' AND s.state='active' AND s.host=?2
          LIMIT 1
          """,
          [handle, host]
        )
      )
  end

  defp actual_receiver_eligible_in_txn?(txn, handle, session_key, host) do
    match?(%{state: "active", host: ^host}, Org.get_in_txn(txn, session_key)) or
      Txn.q(
        txn,
        """
        SELECT 1
        FROM harklight_wake_follows f
        JOIN sessions s ON s.sessionKey=f.sessionKey
        WHERE f.handle=?1 AND f.state='open' AND s.state='active' AND s.host=?2
        LIMIT 1
        """,
        [handle, host]
      ) != []
  end

  defp mark_origin_gone_async(handle) do
    case Task.start(fn -> send_origin_gone(handle) end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Harklight origin #{handle} could not be marked gone: session-end task did not start (#{inspect(reason)})"
        )
    end
  end

  defp send_origin_gone(handle) do
    case System.find_executable("harklight-agent") do
      nil ->
        Logger.warning(
          "Harklight origin #{handle} could not be marked gone: harklight-agent is unavailable"
        )

      executable ->
        try do
          case System.cmd(
                 executable,
                 ["session", "end", "--session", handle, "--gone"],
                 stderr_to_stdout: true
               ) do
            {_output, 0} ->
              :ok

            {_output, status} ->
              Logger.warning(
                "Harklight origin #{handle} session-end gone command failed with exit status #{status}"
              )
          end
        rescue
          error ->
            Logger.warning(
              "Harklight origin #{handle} session-end gone command could not run (#{inspect(error.__struct__)})"
            )
        end
    end
  end

  defp force_worker(state, handle, mode \\ :existing) do
    case Map.fetch(state.workers, handle) do
      {:ok, worker} ->
        if port = Map.get(state.ports, handle), do: close_listener_port(port)
        Process.exit(worker, :shutdown)
        restart = MapSet.put(state.restart, handle)

        restart =
          if mode == :new_request, do: MapSet.put(restart, {handle, :new_request}), else: restart

        %{state | restart: restart, stopping: MapSet.delete(state.stopping, handle)}

      :error ->
        start_worker(state, handle, mode)
    end
  end

  defp stop_worker(state, handle) do
    state = cancel_retry(state, handle)

    case Map.fetch(state.workers, handle) do
      {:ok, worker} ->
        if port = Map.get(state.ports, handle), do: close_listener_port(port)
        Process.exit(worker, :shutdown)

        %{
          state
          | stopping: MapSet.put(state.stopping, handle),
            restart:
              state.restart |> MapSet.delete(handle) |> MapSet.delete({handle, :new_request})
        }

      :error ->
        state
    end
  end

  # A worker that exits while holding or awaiting a slot is released by DOWN.
  defp release_attach_slot(state, pid) do
    waiting = :queue.filter(fn {waiter, _ref} -> waiter != pid end, state.attach_waiting)

    if MapSet.member?(state.attach_slots, pid) do
      grant_attach_slot(%{
        state
        | attach_slots: MapSet.delete(state.attach_slots, pid),
          attach_waiting: waiting
      })
    else
      %{state | attach_waiting: waiting}
    end
  end

  defp grant_attach_slot(state) do
    case :queue.out(state.attach_waiting) do
      {{:value, {pid, ref}}, waiting} ->
        send(pid, {:attach_slot, ref})
        %{state | attach_slots: MapSet.put(state.attach_slots, pid), attach_waiting: waiting}

      {:empty, _} ->
        state
    end
  end

  defp valid_worker?(state, handle, {pid, _tag}) do
    Map.get(state.workers, handle) == pid and
      not MapSet.member?(state.stopping, handle) and
      not MapSet.member?(state.restart, handle)
  end

  defp listener_eligible?(db, handle, session_key, host) do
    host == Placement.local_host_name() and
      actual_receiver_eligible?(db, handle, session_key, host)
  end

  defp listener_eligible_in_txn?(txn, handle, session_key, host) do
    host == Placement.local_host_name() and
      actual_receiver_eligible_in_txn?(txn, handle, session_key, host)
  end

  @doc false
  def stop_for_origin(handle, server \\ __MODULE__) do
    with {:ok, opts} <- GenServer.call(server, {:stop_origin_reader, handle}, :infinity),
         do: Tightbeam.HarklightChild.await_stopped({:handle, handle}, opts)
  end

  @doc false
  def begin_origin_move(handle, session_key, server \\ __MODULE__),
    do: GenServer.call(server, {:begin_origin_move, handle, session_key}, :infinity)

  @impl true
  def handle_call({:reconnect_handle, handle, caller_session_key}, from, state) do
    case reconnect_admission(state, handle, caller_session_key) do
      :ok ->
        state = cancel_retry(state, handle)
        {:noreply, start_reconnect_worker(state, handle, caller_session_key, from)}

      {:error, {:busy, reason}} ->
        {:reply, {:error, {:busy, reason}}, state}

      {:error, {:refused, code, reason}} ->
        {:reply, {:error, {:refused, code, reason}}, state}
    end
  end

  def handle_call({:reconnect_result, ref, result}, {pid, _tag}, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, handle} ->
        cond do
          Map.get(state.workers, handle) != pid ->
            {:reply, {:error, :listener_fenced}, state}

          origin_managed?(state.db, handle) ->
            case Map.pop(state.reconnect_waiters, ref) do
              {nil, _waiters} ->
                {:reply, :origin_moving, state}

              {waiter, waiters} ->
                GenServer.reply(
                  waiter,
                  {:error,
                   {:busy, "The original Harklight handle began moving during reconnect."}}
                )

                {:reply, :origin_moving, %{state | reconnect_waiters: waiters}}
            end

          not valid_worker?(state, handle, {pid, nil}) ->
            {:reply, {:error, :listener_fenced}, state}

          true ->
            case Map.pop(state.reconnect_waiters, ref) do
              {nil, _waiters} ->
                {:reply, :ok, state}

              {waiter, waiters} ->
                case result do
                  {:ok, %{feed_cursor: cursor}} when is_integer(cursor) and cursor >= 0 ->
                    case activate_reconnect_handle(state.db, handle) do
                      :active ->
                        GenServer.reply(waiter, result)

                        {:reply, :ok,
                         %{
                           state
                           | reconnect_waiters: waiters,
                             attempts: Map.delete(state.attempts, handle),
                             failures: Map.delete(state.failures, handle)
                         }}

                      :closed ->
                        GenServer.reply(
                          waiter,
                          {:error,
                           {:refused, "harklight_chat_closed",
                            "The Harklight chat closed while reconnect was starting."}}
                        )

                        {:reply, :closed, %{state | reconnect_waiters: waiters}}

                      {:error, reason} ->
                        GenServer.reply(
                          waiter,
                          {:error,
                           {:connection_error, "harklight_reconnect_state_unavailable",
                            "The Harklight reconnect could not be recorded: #{inspect(reason)}"}}
                        )

                        {:reply, {:error, reason}, %{state | reconnect_waiters: waiters}}
                    end

                  _ ->
                    GenServer.reply(waiter, result)
                    {:reply, :ok, %{state | reconnect_waiters: waiters}}
                end
            end
        end

      _ ->
        {:reply, {:error, :listener_fenced}, state}
    end
  end

  def handle_call({:capture_reconnect, handle, event_line}, {pid, _tag}, state)
      when is_binary(event_line) do
    cond do
      not valid_worker?(state, handle, {pid, nil}) ->
        {:reply, {:error, "listener_fenced"}, state}

      not reconnect_events_for_handle?(handle, [event_line]) ->
        {:reply, {:error, "event_identity_invalid"}, state}

      origin_managed?(state.db, handle) ->
        result = capture_reconnect_origin_lines(state.db, [event_line])

        case result do
          :ok ->
            HarklightLifecycle.acknowledge_pending(state.db, runner: state.send_runner)
            {:reply, :ok, state}

          :captured ->
            {:reply, :captured, state}

          :ignored ->
            {:reply, capture_reconnect_unmanaged(state, handle, [event_line]), state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      true ->
        {:reply, capture_reconnect_unmanaged(state, handle, [event_line]), state}
    end
  rescue
    _ -> {:reply, {:error, "reconnect_capture_unavailable"}, state}
  end

  def handle_call({:begin_origin_move, handle, session_key}, _from, state) do
    result = Tightbeam.HarklightOrigin.begin_move(state.db, handle, session_key)
    # Preserve the current reader until the first settling cover. Only future
    # starts and restart requests are suppressed by this durable marker.
    state =
      case result do
        {:ok, result} when result in [:started, :moving, :covered] -> cancel_retry(state, handle)
        _ -> state
      end

    {:reply, result, state}
  end

  def handle_call({:launch_child, handle, executable, args}, {pid, _} = from, state) do
    if valid_worker?(state, handle, from) and
         not Tightbeam.HarklightOrigin.managed?(state.db, handle) do
      case Tightbeam.HarklightChild.open({:handle, handle}, executable, args, state.child_opts) do
        {:ok, port, initial} ->
          true = Port.connect(port, pid)
          {:reply, {:ok, port, initial}, %{state | ports: Map.put(state.ports, handle, port)}}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :listener_fenced}, state}
    end
  end

  def handle_call({:stop_origin_reader, handle}, _from, state) do
    if Tightbeam.HarklightOrigin.managed?(state.db, handle) do
      {:reply, {:ok, state.child_opts}, stop_worker(state, handle)}
    else
      {:reply, {:error, :handle_not_moving}, state}
    end
  end

  def handle_call({:capture, handle, line}, from, state) do
    result =
      if valid_worker?(state, handle, from),
        do: capture_line(state.db, handle, line),
        else: {:error, "listener_fenced"}

    if result == :ok,
      do: HarklightLifecycle.acknowledge_pending(state.db, runner: state.send_runner)

    state =
      if result == :ok, do: %{state | attempts: Map.delete(state.attempts, handle)}, else: state

    {:reply, result, state}
  end

  def handle_call({:start_decided, handle, skip?}, from, state) do
    if valid_worker?(state, handle, from) do
      {reply, state} = if skip?, do: {:skip, state}, else: prepare_listener(state, handle)

      state =
        if reply == :skip,
          do: %{state | stopping: MapSet.put(state.stopping, handle)},
          else: %{state | restart: MapSet.delete(state.restart, {handle, :deciding})}

      {:reply, reply, state}
    else
      {:reply, :skip, state}
    end
  end

  def handle_call({:listener_port, handle, port}, from, state) do
    if valid_worker?(state, handle, from) do
      {:reply, :ok, %{state | ports: Map.put(state.ports, handle, port)}}
    else
      {:reply, {:error, "listener_fenced"}, state}
    end
  end

  def handle_call({:attached, handle}, from, state) do
    result =
      if valid_worker?(state, handle, from) do
        case DB.query(
               state.db,
               "UPDATE harklight_wake_handles SET state='active',lastError=NULL,updatedAt=?2 WHERE handle=?1",
               [handle, System.system_time(:millisecond)]
             ) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, "attachment_state_unavailable"}
        end
      else
        {:error, "listener_fenced"}
      end

    # Quiet conversations may reconnect without capturing another event. Only
    # consecutive failed attachments consume the recovery budget.
    state =
      if result == :ok, do: %{state | attempts: Map.delete(state.attempts, handle)}, else: state

    {:reply, result, state}
  end

  def handle_call({:finished, handle, status}, from, state) do
    valid? =
      valid_worker?(state, handle, from) and
        not Tightbeam.HarklightOrigin.managed?(state.db, handle)

    result =
      if valid? do
        # Later restoration failures still matter when the durable handle is
        # already unavailable; owner wake/state gating remains in the writer.
        if status != :complete, do: log_listener_failure(handle, status)
        mark_finished(state.db, handle, status)
      else
        :ok
      end

    state =
      if valid?, do: %{state | failures: Map.put(state.failures, handle, status)}, else: state

    {:reply, result, state}
  end

  defp mark_terminated(db, handle) do
    DB.transaction(db, fn txn ->
      case Txn.q(txn, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [handle]) do
        [["active"]] -> mark_finished_in_txn(txn, handle, "listener_terminated")
        _ -> :ok
      end
    end)
  end

  defp mark_finished(db, handle, status) do
    case DB.transaction(db, fn txn -> mark_finished_in_txn(txn, handle, status) end) do
      {:ok, result} -> result
      {:error, _} -> {:error, "listener_state_unavailable"}
    end
  end

  defp mark_finished_in_txn(txn, handle, status) do
    case Txn.q(txn, "SELECT sessionKey,state FROM harklight_wake_handles WHERE handle=?1", [
           handle
         ]) do
      [[session_key, current_state]] when current_state in ["active", "unavailable"] ->
        now = System.system_time(:millisecond)
        completed = status == :complete
        next_state = if completed, do: "complete", else: "unavailable"

        {error, operation, diagnostic} =
          if completed, do: {nil, nil, nil}, else: failure_details(status)

        Txn.q(
          txn,
          "UPDATE harklight_wake_handles SET state=?2,lastError=?3,updatedAt=?4 WHERE handle=?1",
          [handle, next_state, if(diagnostic, do: error <> ": " <> diagnostic, else: error), now]
        )

        if completed, do: HarklightLifecycle.complete_in_txn(txn, handle)

        if not completed,
          do:
            notify_owner_in_txn(
              txn,
              session_key,
              handle,
              if(error == "origin_unavailable",
                do: "origin_unavailable",
                else: "listener_failure"
              ),
              error,
              operation,
              diagnostic,
              now
            )

        :ok

      _ ->
        :ok
    end
  end

  defp notify_pending_origin_unavailable(db, handle) do
    DB.transaction(db, fn txn ->
      case Txn.q(
             txn,
             "SELECT h.sessionKey FROM harklight_wake_handles h JOIN harklight_wake_entries e ON e.handle=h.handle JOIN wakes w ON w.wakeId=e.wakeId WHERE h.handle=?1 AND w.state='pending' LIMIT 1",
             [handle]
           ) do
        [[session_key]] ->
          notify_owner_in_txn(
            txn,
            session_key,
            handle,
            "origin_unavailable",
            "origin_unavailable",
            nil,
            nil,
            System.system_time(:millisecond)
          )

        _ ->
          :ok
      end
    end)
  end

  defp notify_owner_in_txn(
         txn,
         session_key,
         handle,
         _notice_kind,
         error,
         operation,
         diagnostic,
         now
       ) do
    wake_id = "w_harklight_notice_recovery_" <> handle

    message_id =
      case Txn.q(
             txn,
             "SELECT messageId FROM harklight_send_operations WHERE handle=?1 AND state='bound' ORDER BY createdAt,opId LIMIT 1",
             [handle]
           ) do
        [[message_id]] when is_binary(message_id) and message_id != "" -> message_id
        _ -> "unknown"
      end

    safe_error =
      if(is_binary(error), do: error, else: inspect(error))
      |> sanitize_diagnostic_text()
      |> case do
        nil -> "unknown"
        value -> value
      end

    if Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [wake_id]) == [] do
      recipient =
        case Org.get_in_txn(txn, session_key) do
          %{state: "active"} -> session_key
          _ -> Supervision.ladder_target(txn, session_key, 1)
        end

      if recipient do
        cli_output =
          case {error, operation, diagnostic} do
            {_, operation, diagnostic}
            when operation in ["attach", "listen", "reconnect"] and is_binary(diagnostic) ->
              " #{String.upcase(operation)} failure: #{diagnostic}."

            {"origin_unavailable", _, _} ->
              " The original session is inactive or no longer belongs to the recorded host."

            {"origin_host_mismatch", _, _} ->
              " The original session belongs to another host; this controller cannot attach it."

            _ ->
              " Failure cause is unknown. No safe Agent CLI diagnostic was captured."
          end

        wake =
          Wakes.schedule_in_txn(txn, %{
            wake_id: wake_id,
            session_key: recipient,
            origin: "process:tightbeam",
            creator_session_key: session_key,
            prompt:
              "DISCONNECT: Harklight message #{message_id} in thread #{handle} for origin session #{session_key} stopped (#{safe_error}).#{cli_output} Replies on this thread will not reach the originating session while it is unavailable. Pending entries remain at the origin. The origin may re-ask; do not transfer the conversation.",
            due_at: now,
            class: "blocker"
          })

        Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)
      end
    end
  end

  defp start_worker(state, handle, mode \\ :existing) do
    state = cancel_retry(state, handle)

    if handle in Map.values(state.gone_tasks) do
      deferred = MapSet.put(state.deferred, handle)
      deferred = if mode != :existing, do: MapSet.put(deferred, {handle, mode}), else: deferred
      %{state | deferred: deferred}
    else
      if Map.has_key?(state.workers, handle) do
        state
      else
        manager = self()

        {:ok, pid} =
          Task.start_link(fn ->
            skip? = decide_start(state, manager, handle, mode)

            case GenServer.call(manager, {:start_decided, handle, skip?}, :infinity) do
              {:listen, vendor_id} -> state.listener.(manager, handle, vendor_id)
              :skip -> :ok
            end
          end)

        ref = Process.monitor(pid)

        %{
          state
          | workers: Map.put(state.workers, handle, pid),
            refs: Map.put(state.refs, ref, handle),
            restart: MapSet.put(state.restart, {handle, :deciding})
        }
      end
    end
  end

  defp reconnect_admission(state, handle, caller_session_key) do
    case DB.query(
           state.db,
           "SELECT sessionKey,host,state FROM harklight_wake_handles WHERE handle=?1",
           [handle]
         ) do
      {:ok, [[session_key, host, handle_state]]} ->
        cond do
          not reconnect_authorized?(state.db, caller_session_key, handle, session_key) ->
            {:error,
             {:refused, "harklight_reconnect_unauthorized",
              "Reconnect requires the message owner or an open follow on this thread."}}

          host != Placement.local_host_name() ->
            {:error,
             {:refused, "harklight_origin_unavailable",
              "The original Harklight host is not available here."}}

          handle_state == "complete" ->
            {:error,
             {:refused, "harklight_chat_closed", "The Harklight chat is already complete."}}

          handle_state != "unavailable" ->
            {:error, {:busy, "The Harklight handle is not idle and disconnected."}}

          origin_managed?(state.db, handle) ->
            {:error, {:busy, "The original Harklight handle is moving or already covered."}}

          Map.has_key?(state.workers, handle) or Map.has_key?(state.ports, handle) or
            MapSet.member?(state.stopping, handle) or MapSet.member?(state.restart, handle) or
            MapSet.member?(state.restart, {handle, :deciding}) or
              handle in Map.values(state.gone_tasks) ->
            {:error, {:busy, "Another Harklight operation already owns this handle."}}

          true ->
            :ok
        end

      {:ok, []} ->
        {:error,
         {:refused, "harklight_origin_unavailable",
          "The original Harklight handle is unavailable."}}

      {:error, _reason} ->
        {:error,
         {:refused, "harklight_origin_unavailable",
          "The original Harklight handle could not be checked."}}
    end
  rescue
    _ ->
      {:error,
       {:refused, "harklight_origin_unavailable",
        "The original Harklight handle could not be checked."}}
  end

  defp reconnect_authorized?(db, caller_session_key, handle, owner_session_key) do
    caller_session_key == owner_session_key or
      match?(
        {:ok, [[1]]},
        DB.query(
          db,
          "SELECT 1 FROM harklight_wake_follows WHERE sessionKey=?1 AND handle=?2 AND state='open' LIMIT 1",
          [caller_session_key, handle]
        )
      )
  end

  defp origin_managed?(db, handle) do
    if Code.ensure_loaded?(Tightbeam.HarklightOrigin) do
      apply(Tightbeam.HarklightOrigin, :managed?, [db, handle])
    else
      false
    end
  end

  defp start_reconnect_worker(state, handle, caller_session_key, waiter) do
    manager = self()
    captured_state = state

    {:ok, pid} =
      Task.start_link(fn ->
        receive do
          {:reconnect_registered, ref} ->
            result =
              try do
                reconnect_worker(captured_state, manager, handle, ref)
              rescue
                error ->
                  {:result,
                   reconnect_failure(
                     manager,
                     handle,
                     "harklight_reconnect_failed",
                     Exception.message(error)
                   )}
              catch
                :exit, :shutdown ->
                  exit(:shutdown)

                kind, reason ->
                  {:result,
                   reconnect_failure(
                     manager,
                     handle,
                     "harklight_reconnect_failed",
                     "#{kind}: #{inspect(reason)}"
                   )}
              end

            case result do
              {:result, response} ->
                GenServer.call(manager, {:reconnect_result, ref, response}, :infinity)

              :reported ->
                :ok
            end
        after
          30_000 -> exit(:reconnect_worker_registration_timeout)
        end
      end)

    ref = Process.monitor(pid)
    send(pid, {:reconnect_registered, ref})

    %{
      state
      | workers: Map.put(state.workers, handle, pid),
        refs: Map.put(state.refs, ref, handle),
        reconnect_waiters: Map.put(state.reconnect_waiters, ref, waiter),
        restart: MapSet.put(state.restart, {handle, :deciding})
    }
  end

  defp reconnect_worker(state, manager, handle, ref) do
    skip? = HarklightLifecycle.closed_for_start?(state.db, handle, runner: state.send_runner)

    case GenServer.call(manager, {:start_decided, handle, skip?}, :infinity) do
      {:listen, _vendor_id} when not skip? ->
        case System.find_executable("harklight-agent") do
          nil ->
            {:result,
             reconnect_failure(
               manager,
               handle,
               "harklight_cli_missing",
               "Harklight Agent could not be run."
             )}

          executable ->
            run_reconnect_stream(manager, handle, executable, ref)
        end

      :skip when skip? ->
        {:result,
         {:error,
          {:refused, "harklight_chat_closed",
           "The original Harklight handle no longer has an unanswered chat."}}}

      :skip ->
        {:result,
         {:error,
          {:connection_error, "harklight_origin_unavailable",
           "The original Harklight host is no longer available for reconnect."}}}
    end
  end

  defp run_reconnect_stream(manager, handle, executable, ref) do
    try do
      case GenServer.call(
             manager,
             {:launch_child, handle, executable, ["reconnect", "--session", handle]},
             :infinity
           ) do
        {:ok, port, initial} ->
          try do
            true = Port.command(port, "continue\n")

            receive_reconnect_output(
              manager,
              handle,
              executable,
              ref,
              port,
              initial,
              %{connected?: false, feed_cursor: nil, diagnostics: []}
            )
          after
            close_listener_port(port)
          end

        {:error, reason} ->
          case reason do
            :listener_fenced ->
              {:result,
               {:error, {:busy, "The original Harklight handle began moving during reconnect."}}}

            _ ->
              {:result,
               reconnect_failure(manager, handle, "harklight_reconnect_failed", inspect(reason))}
          end
      end
    rescue
      error ->
        reason = Tightbeam.HarklightWakes.sanitize_refusal_output(Exception.message(error))
        {:result, reconnect_failure(manager, handle, "harklight_reconnect_failed", reason)}
    catch
      :exit, :shutdown ->
        exit(:shutdown)

      kind, reason ->
        {:result,
         reconnect_failure(
           manager,
           handle,
           "harklight_reconnect_failed",
           "#{kind}: #{inspect(reason)}"
         )}
    end
  end

  defp receive_reconnect_output(
         manager,
         handle,
         executable,
         ref,
         port,
         pending,
         stream_state
       ) do
    receive do
      {:EXIT, ^manager, reason} ->
        exit(reason)

      {:EXIT, _sender, :shutdown} ->
        exit(:shutdown)

      {^port, {:data, bytes}} ->
        case process_reconnect_chunk(
               manager,
               handle,
               ref,
               pending,
               bytes,
               stream_state
             ) do
          {:continue, next_pending, next_state} ->
            receive_reconnect_output(
              manager,
              handle,
              executable,
              ref,
              port,
              next_pending,
              next_state
            )

          {:stop, result} ->
            result
        end

      {^port, {:exit_status, status}} ->
        case process_reconnect_final_line(
               manager,
               handle,
               ref,
               pending,
               stream_state
             ) do
          {:continue, final_state} ->
            reconnect_stream_exit(manager, handle, status, final_state)

          {:stop, result} ->
            result
        end
    end
  end

  defp process_reconnect_chunk(manager, handle, ref, pending, bytes, stream_state) do
    parts = :binary.split(pending <> bytes, "\n", [:global])
    remainder = List.last(parts)
    lines = Enum.drop(parts, -1)

    Enum.reduce_while(lines, {:continue, remainder, stream_state}, fn line,
                                                                      {:continue, _remainder,
                                                                       current_state} ->
      case process_reconnect_line(manager, handle, ref, line, current_state) do
        {:continue, next_state} -> {:cont, {:continue, remainder, next_state}}
        {:stop, result} -> {:halt, {:stop, result}}
      end
    end)
  end

  defp process_reconnect_final_line(_manager, _handle, _ref, "", stream_state),
    do: {:continue, stream_state}

  defp process_reconnect_final_line(manager, handle, ref, line, stream_state) do
    case process_reconnect_line(manager, handle, ref, line, stream_state) do
      {:continue, next_state} -> {:continue, next_state}
      {:stop, result} -> {:stop, result}
    end
  end

  defp process_reconnect_line(manager, handle, ref, line, stream_state) do
    case Tightbeam.HarklightReconnect.parse_agent_line(line, handle) do
      {:connected, cursor} ->
        if stream_state.connected? do
          if stream_state.feed_cursor == cursor do
            {:continue, stream_state}
          else
            reconnect_stream_failure(
              manager,
              handle,
              "harklight_reconnect_unconfirmed",
              "Agent changed the feed cursor during one reconnect stream.",
              stream_state
            )
          end
        else
          case GenServer.call(
                 manager,
                 {:reconnect_result, ref, {:ok, %{feed_cursor: cursor}}},
                 :infinity
               ) do
            :ok ->
              {:continue, %{stream_state | connected?: true, feed_cursor: cursor}}

            :origin_moving ->
              {:stop, :reported}

            :closed ->
              {:stop, :reported}

            {:error, reason} ->
              reconnect_stream_failure(
                manager,
                handle,
                "harklight_reconnect_state_unavailable",
                reason,
                stream_state
              )
          end
        end

      {:event, event_line} ->
        case GenServer.call(manager, {:capture_reconnect, handle, event_line}, :infinity) do
          :ok ->
            {:continue, stream_state}

          :captured ->
            {:continue, stream_state}

          {:error, :origin_moving} ->
            {:stop,
             if(stream_state.connected?,
               do: :reported,
               else:
                 {:result,
                  {:error,
                   {:busy, "The original Harklight handle began moving during reconnect."}}}
             )}

          {:error, :closed} ->
            finish(manager, handle, :complete)
            {:stop, if(stream_state.connected?, do: :reported, else: closed_reconnect_result())}

          {:error, reason} ->
            reconnect_stream_failure(
              manager,
              handle,
              "harklight_reconnect_capture_failed",
              reason,
              stream_state
            )
        end

      :idle ->
        # Reconnect is a standing Agent stream; idle marks a drained cursor,
        # while later entries can still arrive on this same handle.
        {:continue, stream_state}

      {:error, outcome, code, reason, op_id} ->
        reason = reason || "The Agent declined or could not confirm the reconnect."

        finish(
          manager,
          handle,
          failure_status({"harklight_reconnect_failed", code}, "reconnect", reason)
        )

        result =
          case outcome do
            :outcome_unknown -> {:error, {:outcome_unknown, code, reason, op_id}}
            :refused -> {:error, {:refused, code, reason}}
            _ -> {:error, {:connection_error, code, reason}}
          end

        {:stop, if(stream_state.connected?, do: :reported, else: {:result, result})}

      {:diagnostic, diagnostic} ->
        diagnostics =
          [String.slice(diagnostic, 0, @max_diagnostic_line_chars) | stream_state.diagnostics]
          |> Enum.take(@max_diagnostic_lines)

        {:continue, %{stream_state | diagnostics: diagnostics}}

      :ignore ->
        {:continue, stream_state}
    end
  end

  defp reconnect_stream_exit(manager, handle, status, %{connected?: true} = stream_state) do
    {code, reason} = stream_exit_diagnostic(status, stream_state.diagnostics)

    finish(
      manager,
      handle,
      failure_status({"harklight_reconnect_failed", code}, "reconnect", reason)
    )

    :reported
  end

  defp reconnect_stream_exit(manager, handle, status, stream_state) do
    {code, reason, outcome} = unconfirmed_stream_diagnostic(status, stream_state.diagnostics)
    _failure = reconnect_failure(manager, handle, code, reason)

    diagnostic =
      Tightbeam.HarklightWakes.sanitize_refusal_output(reason) ||
        "The Agent reconnect ended without confirming the connection."

    case outcome do
      :outcome_unknown ->
        {:result, {:error, {:outcome_unknown, code, diagnostic, nil}}}

      _ ->
        {:result, {:error, {:connection_error, code, diagnostic}}}
    end
  end

  defp reconnect_stream_failure(manager, handle, code, reason, stream_state) do
    diagnostic = reason || "The Agent reconnect did not complete."
    result = reconnect_failure(manager, handle, code, diagnostic)
    {:stop, if(stream_state.connected?, do: :reported, else: {:result, result})}
  end

  defp closed_reconnect_result do
    {:result,
     {:error,
      {:refused, "harklight_chat_closed",
       "The Harklight chat closed while reconnect was in progress."}}}
  end

  defp stream_exit_diagnostic(status, diagnostics) do
    detail = diagnostic_summary(diagnostics)

    if status == 0 do
      {"harklight_reconnect_stream_ended",
       detail || "The Agent reconnect stream ended unexpectedly."}
    else
      {"harklight_reconnect_stream_failed",
       detail || "The Agent reconnect stream ended with exit status #{status}."}
    end
  end

  defp unconfirmed_stream_diagnostic(status, diagnostics) do
    detail = diagnostic_summary(diagnostics)
    outcome = if status == 7, do: :outcome_unknown, else: :connection_error

    {"harklight_reconnect_unconfirmed",
     detail ||
       "The Agent reconnect ended without confirming the connection (exit status #{status}).",
     outcome}
  end

  defp diagnostic_summary([]), do: nil

  defp diagnostic_summary(lines) do
    lines
    |> Enum.reverse()
    |> Enum.join("; ")
    |> Tightbeam.HarklightWakes.sanitize_refusal_output()
  end

  defp activate_reconnect_handle(db, handle) do
    case DB.transaction(db, fn txn ->
           case Txn.q(txn, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [handle]) do
             [["complete"]] ->
               :closed

             [[state]] when state in ["active", "unavailable"] ->
               Txn.q(
                 txn,
                 "UPDATE harklight_wake_handles SET state='active',lastError=NULL,updatedAt=?2 WHERE handle=?1 AND state IN ('active','unavailable')",
                 [handle, System.system_time(:millisecond)]
               )

               :active

             _ ->
               {:error, :handle_unavailable}
           end
         end) do
      {:ok, :active} -> :active
      {:ok, :closed} -> :closed
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp capture_reconnect_legacy_lines(db, handle, lines) do
    Enum.reduce_while(lines, :ok, fn line, :ok ->
      case capture_line(db, handle, line) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp capture_reconnect_unmanaged(state, handle, lines) do
    case activate_reconnect_handle(state.db, handle) do
      :active ->
        result = capture_reconnect_legacy_lines(state.db, handle, lines)

        if result == :ok,
          do: HarklightLifecycle.acknowledge_pending(state.db, runner: state.send_runner)

        result

      :closed ->
        {:error, :closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture_reconnect_origin_lines(db, lines) do
    Enum.reduce_while(lines, {:ok, false}, fn line, {:ok, staged?} ->
      case capture_origin_line(db, line) do
        :ok -> {:cont, {:ok, staged?}}
        :captured -> {:cont, {:ok, true}}
        :ignored -> {:cont, {:ignored, staged?}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, false} -> :ok
      {:ok, true} -> :captured
      {:ignored, false} -> :ignored
      {:ignored, true} -> :captured
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconnect_events_for_handle?(handle, lines) do
    Enum.all?(lines, fn line ->
      case JSON.decode(line) do
        {:ok, %{"kind" => "event", "session_handle" => ^handle}} -> true
        _ -> false
      end
    end)
  end

  defp reconnect_failure(manager, handle, code, reason) do
    reason = if is_binary(reason), do: reason, else: inspect(reason)
    reason = Tightbeam.HarklightWakes.sanitize_refusal_output(reason)
    diagnostic = reason || "The Agent reconnect did not complete."

    finish(
      manager,
      handle,
      failure_status({"harklight_reconnect_failed", code}, "reconnect", diagnostic)
    )

    {:error, {:connection_error, code, diagnostic}}
  end

  defp reconnect_worker_down_result do
    {:error,
     {:connection_error, "harklight_reconnect_worker_failed",
      "The reconnect worker exited before confirming the connection."}}
  end

  defp reply_reconnect_waiter(state, ref, result) do
    case Map.pop(state.reconnect_waiters, ref) do
      {nil, _waiters} ->
        state

      {waiter, waiters} ->
        GenServer.reply(waiter, result)
        %{state | reconnect_waiters: waiters}
    end
  end

  defp decide_start(_state, _manager, _handle, :new_request), do: false

  defp decide_start(state, manager, handle, mode) do
    ref = make_ref()
    GenServer.cast(manager, {:decision_slot, self(), ref})

    receive do
      {:attach_slot, {:decision, ^ref}} -> :ok
    end

    try do
      skip? = HarklightLifecycle.closed_for_start?(state.db, handle, runner: state.send_runner)

      if skip? and mode == :startup,
        do: HarklightLifecycle.complete_answered(state.db, handle, runner: state.send_runner)

      skip?
    after
      GenServer.cast(manager, {:attach_slot_released, self()})
    end
  end

  defp cancel_retry(state, handle) do
    case Map.pop(state.retry_timers, handle) do
      {nil, _} ->
        state

      {{timer, _}, timers} ->
        Process.cancel_timer(timer)
        %{state | retry_timers: timers}
    end
  end

  defp prepare_listener(state, handle) do
    case DB.query(
           state.db,
           "SELECT sessionKey,host,vendorSessionId,state FROM harklight_wake_handles WHERE handle=?1 AND NOT EXISTS (SELECT 1 FROM harklight_origin_moves m WHERE m.handle=harklight_wake_handles.handle)",
           [handle]
         ) do
      {:ok, [[session_key, host, saved_vendor_id, state_value]]}
      when state_value in ["active", "unavailable"] ->
        if listener_eligible?(state.db, handle, session_key, host) do
          vendor_id =
            case Org.get(state.db, session_key) do
              %{state: "active", host: ^host} ->
                case Org.current_pointer(state.db, session_key) do
                  nil -> saved_vendor_id
                  pointer -> pointer.harness_session_id
                end

              _ ->
                saved_vendor_id
            end

          if vendor_id != saved_vendor_id do
            DB.query(
              state.db,
              "UPDATE harklight_wake_handles SET vendorSessionId=?2,updatedAt=?3 WHERE handle=?1",
              [handle, vendor_id, System.system_time(:millisecond)]
            )
          end

          {{:listen, vendor_id}, %{state | failures: Map.delete(state.failures, handle)}}
        else
          reason =
            if host == Placement.local_host_name(),
              do: "origin_unavailable",
              else: "origin_host_mismatch"

          mark_finished(state.db, handle, reason)

          state =
            if host == Placement.local_host_name(), do: start_gone(state, handle), else: state

          {:skip, state}
        end

      _ ->
        {:skip, state}
    end
  end

  defp run_listener(manager, handle, vendor_id, delays, window) do
    Process.flag(:trap_exit, true)

    case System.find_executable("harklight-agent") do
      nil ->
        finish(
          manager,
          handle,
          failure_status(
            "cli_missing",
            "attach",
            attempt_diagnostic(
              "ATTACH startup (CLI unavailable; subprocess not launched)",
              nil,
              nil
            )
          )
        )

      executable ->
        executable = {manager, handle, executable}

        args = [
          "attach",
          "--session",
          handle,
          "--vendor-session-id",
          vendor_id || "none",
          "--route",
          "other",
          "--controller",
          "--ack2"
        ]

        deadline = System.monotonic_time(:millisecond) + window

        case attach_with_transport_recovery(
               executable,
               args,
               delays,
               deadline,
               manager,
               handle,
               nil
             ) do
          :ok ->
            case GenServer.call(manager, {:attached, handle}, :infinity) do
              :ok -> follow(manager, executable, handle)
              {:error, reason} -> finish(manager, handle, reason)
            end

          {:error, reason, diagnostic} ->
            finish(manager, handle, failure_status(reason, "attach", diagnostic))

          {:error, reason} ->
            finish(manager, handle, reason)
        end
    end
  rescue
    _ -> finish(manager, handle, "listener_failed")
  end

  # Keep the original same-operation recovery inside each attempt. Only an
  # observed transport failure can schedule another attempt; a handle refusal
  # or an unclassified unknown result retains the existing disposition.
  defp attach_with_transport_recovery(executable, args, delays, deadline, manager, handle, last) do
    case paced_attach(executable, args, deadline, manager, last) do
      {:transport, reason, diagnostic} = failure ->
        case delays do
          [delay | rest] ->
            if System.monotonic_time(:millisecond) + delay <= deadline do
              log_listener_failure(handle, failure_status(reason, "attach", diagnostic))

              receive do
                {:EXIT, ^manager, exit_reason} -> exit(exit_reason)
              after
                delay ->
                  if System.monotonic_time(:millisecond) <= deadline do
                    attach_with_transport_recovery(
                      executable,
                      args,
                      rest,
                      deadline,
                      manager,
                      handle,
                      failure
                    )
                  else
                    {:error, reason, diagnostic}
                  end
              end
            else
              {:error, reason, diagnostic}
            end

          [] ->
            {:error, reason, diagnostic}
        end

      result ->
        result
    end
  end

  # Waiting for a slot spends the same retry window; a retry granted after the
  # deadline reports the previous transport failure instead of attaching.
  defp paced_attach(executable, args, deadline, manager, last) do
    ref = make_ref()
    GenServer.cast(manager, {:attach_slot, self(), ref})

    receive do
      {:attach_slot, ^ref} -> :ok
      {:EXIT, ^manager, exit_reason} -> exit(exit_reason)
    end

    try do
      if last && System.monotonic_time(:millisecond) > deadline,
        do: last,
        else: attach(executable, args)
    after
      GenServer.cast(manager, {:attach_slot_released, self()})
    end
  end

  defp attach(executable, args) do
    case attach_once(executable, args, "ATTACH initial attempt") do
      {:unknown, op_id, initial_diagnostic, _transport} ->
        case retry_existing_operation(executable, op_id) do
          {:ok, retry_diagnostic} ->
            case attach_once(executable, args, "ATTACH after same-operation retry") do
              :ok ->
                :ok

              {:unknown, _op_id, diagnostic, transport} ->
                {if(transport, do: :transport, else: :error), "attachment_outcome_unknown",
                 [initial_diagnostic, retry_diagnostic, diagnostic]}

              {kind, reason, diagnostic} when kind in [:error, :transport] ->
                {kind, reason, [initial_diagnostic, retry_diagnostic, diagnostic]}
            end

          {:transport, retry_diagnostic} ->
            {:transport, "attachment_outcome_unknown", [initial_diagnostic, retry_diagnostic]}

          {:error, retry_diagnostic} ->
            {:error, "attachment_outcome_unknown", [initial_diagnostic, retry_diagnostic]}

          {:error, reason, retry_diagnostic} ->
            {:error, reason, [initial_diagnostic, retry_diagnostic]}
        end

      result ->
        attach_result(result)
    end
  rescue
    _ ->
      {:error, "attachment_cli_failed", attempt_diagnostic("ATTACH initial attempt", nil, nil)}
  end

  defp retry_existing_operation(executable, op_id) do
    case Tightbeam.HarklightChild.command(executable, ["retry", "--op-id", op_id]) do
      {output, 0} ->
        {:ok, attempt_diagnostic("ATTACH existing same-operation retry", 0, output)}

      {output, exit_status} ->
        diagnostic =
          attempt_diagnostic("ATTACH existing same-operation retry", exit_status, output)

        kind = if retry_transport_failure?(output, op_id), do: :transport, else: :error
        {kind, diagnostic}
    end
  rescue
    _ ->
      {:error, "attachment_cli_failed",
       attempt_diagnostic("ATTACH existing same-operation retry", nil, nil)}
  end

  defp attach_once(executable, args, attempt) do
    case Tightbeam.HarklightChild.command(executable, args) do
      {output, 0} ->
        if Enum.any?(String.split(output, "\n", trim: true), fn line ->
             match?({:ok, %{"kind" => "attached", "ready_for_listen" => true}}, JSON.decode(line))
           end),
           do: :ok,
           else: {:error, "attachment_unconfirmed", attempt_diagnostic(attempt, 0, output)}

      {output, exit_status} ->
        unknown =
          output
          |> String.split("\n", trim: true)
          |> Enum.find_value(fn line ->
            case JSON.decode(line) do
              {:ok, %{"kind" => "outcome_unknown", "op_id" => id}} when is_binary(id) -> id
              _ -> nil
            end
          end)

        diagnostic = attempt_diagnostic(attempt, exit_status, output)

        if unknown,
          do: {:unknown, unknown, diagnostic, attach_transport_failure?(output)},
          else:
            {if(attach_transport_failure?(output), do: :transport, else: :error),
             classified_reason("attachment_refused", output), diagnostic}
    end
  rescue
    _ -> {:error, "attachment_cli_failed", attempt_diagnostic(attempt, nil, nil)}
  end

  defp attach_transport_failure?(output) do
    Enum.any?(String.split(output, "\n", trim: true), fn line ->
      case JSON.decode(line) do
        {:ok, %{"kind" => kind, "reason_source" => "agent", "reason_code" => code}}
        when kind in ["refused", "connection_error", "outcome_unknown"] and
               code in ["transport_error", "timeout"] ->
          true

        _ ->
          false
      end
    end)
  end

  # Agent 0.1.6's generic retry omits reason_code. Its ApiError::Transport
  # Display prefix is emitted on stderr beside the same operation's unknown
  # record. Inspect that source-defined prefix, but never retain the raw URL.
  defp retry_transport_failure?(output, op_id) do
    lines = String.split(output, "\n", trim: true)

    Enum.any?(lines, &String.starts_with?(&1, "origin request failed: ")) and
      Enum.any?(lines, fn line ->
        case JSON.decode(line) do
          {:ok, %{"kind" => "outcome_unknown", "op_id" => ^op_id}} -> true
          _ -> false
        end
      end)
  end

  defp attach_result({:unknown, _op_id, diagnostic}),
    do: {:error, "attachment_outcome_unknown", diagnostic}

  defp attach_result({:unknown, _}), do: {:error, "attachment_outcome_unknown", nil}
  defp attach_result({:error, reason}), do: {:error, reason, nil}
  defp attach_result(result), do: result

  defp attempt_diagnostic(attempt, exit_status, output) do
    status = exit_status_detail(exit_status)

    output = sanitize_refusal_output(output)
    output_detail = if output, do: "sanitized output: #{output}", else: "no safe output captured"

    "#{attempt}; #{status}; #{output_detail}"
    |> String.slice(0, @max_diagnostic_line_chars)
  end

  defp listen_attempt_diagnostics(attempt, exit_status, diagnostics) do
    status = exit_status_detail(exit_status)

    case diagnostics do
      [] ->
        ["#{attempt}; #{status}; no safe output captured"]

      [first | rest] ->
        [
          "#{attempt}; #{status}; sanitized output: #{first}"
          | Enum.map(rest, &"sanitized output: #{&1}")
        ]
    end
    |> Enum.take(@max_diagnostic_lines)
    |> Enum.map(&String.slice(&1, 0, @max_diagnostic_line_chars))
  end

  defp exit_status_detail(status) when is_integer(status), do: "exit status: #{status}"
  defp exit_status_detail(_), do: "exit status: unknown (not observed)"

  defp follow(manager, {_manager, _handle, executable}, handle) do
    {:ok, port, initial} =
      GenServer.call(
        manager,
        {:launch_child, handle, executable,
         ["listen", "--follow", "--controller", "--session", handle, "--ack2"]},
        :infinity
      )

    try do
      case GenServer.call(manager, {:listener_port, handle, port}, :infinity) do
        :ok ->
          true = Port.command(port, "continue\n")
          receive_lines(manager, port, handle, initial, [])

        {:error, reason} ->
          finish(manager, handle, reason)
      end
    after
      close_listener_port(port)
    end
  rescue
    _ ->
      finish(
        manager,
        handle,
        failure_status(
          "listener_failed",
          "listen",
          attempt_diagnostic("LISTEN attempt (Port unavailable or receive failed)", nil, nil)
        )
      )
  end

  # The wrapper observes input EOF, terminates and reaps its CLI child. Closing
  # this port requests cleanup; M2 separately waits on its lifetime-lock barrier.
  defp close_listener_port(port) do
    Tightbeam.HarklightChild.request_stop(port)
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp receive_lines(manager, port, handle, pending, diagnostics) do
    receive do
      {:EXIT, ^manager, reason} ->
        exit(reason)

      {:EXIT, _sender, :shutdown} ->
        exit(:shutdown)

      {^port, {:data, bytes}} ->
        data = pending <> bytes
        lines = :binary.split(data, "\n", [:global])
        remainder = List.last(lines)

        result =
          lines
          |> Enum.drop(-1)
          |> Enum.reduce_while({:ok, diagnostics}, fn line, {:ok, current_diagnostics} ->
            case receive_listener_line(manager, handle, line, current_diagnostics) do
              {:ok, next_diagnostics} ->
                {:cont, {:ok, next_diagnostics}}

              {:error, reason, next_diagnostics} ->
                {:halt, {:error, reason, next_diagnostics}}
            end
          end)

        case result do
          {:ok, next_diagnostics} ->
            receive_lines(manager, port, handle, remainder, next_diagnostics)

          {:error, reason, next_diagnostics} ->
            close_listener_port(port)

            finish(
              manager,
              handle,
              failure_status(
                reason,
                "listen",
                listen_attempt_diagnostics("LISTEN attempt", nil, next_diagnostics)
              )
            )
        end

      {^port, {:exit_status, 0}} ->
        status =
          if pending == "",
            do: :complete,
            else:
              failure_status(
                "incomplete_line",
                "listen",
                listen_attempt_diagnostics(
                  "LISTEN attempt",
                  0,
                  append_diagnostic(diagnostics, pending)
                )
              )

        finish(manager, handle, status)

      {^port, {:exit_status, exit_status}} ->
        diagnostics = append_diagnostic(diagnostics, pending)

        finish(
          manager,
          handle,
          failure_status(
            "listener_stopped",
            "listen",
            listen_attempt_diagnostics("LISTEN attempt", exit_status, diagnostics)
          )
        )
    end
  end

  # The Agent emits JSON events on stdout and reconnect/refusal messages on
  # stderr. The port merges them; keep plain-text diagnostics without treating
  # them as events, and leave every JSON line on the existing capture path.
  defp receive_listener_line(manager, handle, line, diagnostics) do
    decoded =
      try do
        JSON.decode(line)
      rescue
        _ -> {:error, :invalid_listener_line}
      end

    case decoded do
      {:ok, %{"kind" => kind}}
      when kind in ["refused", "connection_error", "outcome_unknown", "error"] ->
        {:error, classified_reason("listener_stopped", line),
         append_diagnostic(diagnostics, line)}

      {:ok, _event} ->
        case GenServer.call(manager, {:capture, handle, line}, :infinity) do
          :ok -> {:ok, diagnostics}
          {:error, reason} -> {:error, reason, append_diagnostic(diagnostics, line)}
        end

      {:error, _} ->
        diagnostic_line = String.replace_invalid(line)

        if structured_output_line?(diagnostic_line) do
          {:error, "invalid_listener_line", diagnostics}
        else
          {:ok, append_diagnostic(diagnostics, diagnostic_line)}
        end
    end
  end

  defp failure_status(error, operation, diagnostic),
    do: {:harklight_failure, error, operation, diagnostic}

  defp failure_details({:harklight_failure, {error, code}, "reconnect", diagnostics}),
    do:
      {error, "reconnect",
       format_failure_diagnostics(List.wrap(diagnostics) ++ ["reason_code=" <> code])}

  defp failure_details({:harklight_failure, {error, code}, operation, diagnostics}),
    do:
      {error, operation,
       format_failure_diagnostics(["reason_code=" <> code | List.wrap(diagnostics)])}

  defp failure_details({:harklight_failure, error, operation, diagnostics}),
    do: {to_string(error), operation, format_failure_diagnostics(diagnostics)}

  defp failure_details(error), do: {to_string(error), nil, nil}

  # Agent v0.1.6 controller_attach uses this closed vocabulary. Unknown output
  # retains bounded retry and the existing sanitized diagnostics, never an
  # inference from arbitrary stderr text.
  defp classified_reason(error, output) do
    codes = ~w(missing_journal unproven_handle invalid_handle invalid_attachment
      invalid_attachment_receipt support_mismatch configuration_error listener_active
      already_listening not_found forbidden operation_conflict invalid_field unsupported_version
      feed_gap feed_conflict invalid_notice invalid_response journal_error local_io timeout
      transport_error stream_ended stream_io storage_unavailable unknown)

    code =
      output
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case JSON.decode(line) do
          {:ok, %{"reason_code" => code}} -> if code in codes, do: code
          _ -> nil
        end
      end)

    if code, do: {error, code}, else: error
  end

  defp log_listener_failure(handle, status) do
    {error, operation, diagnostic} = failure_details(status)
    handle = sanitize_diagnostic_text(handle) || "unknown"
    error = sanitize_diagnostic_text(error) || "unknown"

    operation =
      if is_binary(operation),
        do: sanitize_diagnostic_text(operation) || "unknown",
        else: "unknown"

    diagnostic =
      diagnostic ||
        "stage/attempt: unknown; exit status: unknown (not observed); no safe output captured"

    Logger.warning(
      "Harklight listener failure handle=#{handle} error=#{error} operation=#{operation}; #{diagnostic}"
    )
  end

  defp format_failure_diagnostics(nil), do: nil

  defp format_failure_diagnostics(diagnostics) when is_binary(diagnostics),
    do: format_failure_diagnostics([diagnostics])

  defp format_failure_diagnostics(diagnostics) when is_list(diagnostics) do
    diagnostics
    |> Enum.map(&sanitize_diagnostic_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(not is_binary(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_diagnostic_lines)
    |> Enum.join(" | ")
    |> String.slice(0, @max_diagnostic_chars)
    |> blank_to_nil()
  end

  @doc false
  def sanitize_refusal_output(output) when is_binary(output) do
    output
    |> String.replace_invalid()
    |> String.split(~r/[\r\n]+/, trim: true)
    |> Enum.flat_map(&refusal_detail_lines/1)
    |> Enum.map(&sanitize_diagnostic_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_diagnostic_lines)
    |> Enum.join(" | ")
    |> String.slice(0, @max_diagnostic_chars)
    |> blank_to_nil()
  end

  def sanitize_refusal_output(_), do: nil

  defp refusal_detail_lines(line) do
    case JSON.decode(String.trim(line)) do
      {:ok, %{"kind" => kind, "reason" => reason}}
      when kind in ["error", "unsupported", "refused", "outcome_unknown", "connection_error"] and
             is_binary(reason) ->
        [reason]

      {:ok, %{"type" => "error", "reason" => reason}} when is_binary(reason) ->
        [reason]

      {:ok,
       %{
         "kind" => "attached",
         "ready_for_listen" => false,
         "listening_support" => %{"unsupported_reason" => reason}
       }}
      when is_binary(reason) ->
        [reason]

      {:ok, _structured_output} ->
        []

      {:error, _} ->
        if structured_output_line?(line), do: [], else: [line]
    end
  end

  defp sanitize_diagnostic_text(text) do
    text =
      text
      |> String.replace_invalid()
      |> String.trim()
      |> String.replace(~r/\{.*\}|\[(?!REDACTED:)[^\]]*\]/u, "[REDACTED:structured output]")
      |> String.replace(~r/https?:\/\/[^\s]+/i, "[REDACTED:url]")
      |> String.replace(
        ~r/\b(payload|body|content|title|message)\s*[:=].*$/i,
        "\\1=[REDACTED:content]"
      )
      |> ErrorDiagnostic.redact_text()
      |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if text == "" do
      nil
    else
      String.slice(text, 0, @max_diagnostic_line_chars)
    end
  end

  defp structured_output_line?(line) do
    String.starts_with?(String.trim_leading(line), ["{", "["])
  end

  defp append_diagnostic(diagnostics, output) do
    case sanitize_refusal_output(output) do
      nil -> diagnostics
      diagnostic -> Enum.take(diagnostics ++ [diagnostic], -@max_diagnostic_lines)
    end
  end

  defp combine_diagnostics(left, right) do
    [left, right]
    |> Enum.reject(&(not is_binary(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.join(" | ")
    |> String.slice(0, @max_diagnostic_chars)
    |> blank_to_nil()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp finish(manager, handle, status),
    do: GenServer.call(manager, {:finished, handle, status}, :infinity)

  @doc false
  def capture_line(db, handle, line) do
    with {:ok, event} <- JSON.decode(line),
         true <- is_map(event) do
      case event do
        %{"kind" => "event"} -> capture_event(db, handle, line, event)
        %{"kind" => "idle", "open_requests" => 0} -> :ok
        %{"kind" => "unsupported"} -> {:error, "listener_unsupported"}
        _ -> {:error, "unexpected_listener_line"}
      end
    else
      _ -> {:error, "invalid_listener_line"}
    end
  end

  @doc false
  def capture_origin_line(db, line) do
    with {:ok, %{"kind" => "event", "session_handle" => handle} = event} <- JSON.decode(line),
         true <- is_binary(handle) do
      # Ignore foreign and non-opted-in handles before interpreting their payload.
      # Admission is checked again inside the write transaction.
      if Tightbeam.HarklightOrigin.managed?(db, handle),
        do: capture_event(db, handle, line, event, :origin),
        else: :ignored
    else
      {:ok, %{"kind" => "event"}} -> :ignored
      _ -> {:error, "unexpected_origin_line"}
    end
  end

  defp capture_event(db, handle, line, event, source \\ :legacy) do
    request = event["request"] || %{}
    entry = event["entry"] || %{}
    event_id = event["event_id"]
    cursor = event["feed_cursor"]
    sender_id = request["sender_id"]
    message_id = request["message_id"]
    revision = event["request_revision"]
    kind = entry["kind"]
    author = entry["author"]

    if event["session_handle"] != handle or not is_binary(event_id) or
         not is_integer(cursor) or cursor < 1 or event_id != Integer.to_string(cursor) or
         not is_binary(sender_id) or not is_binary(message_id) or
         not (is_nil(revision) or is_integer(revision)) or
         kind not in ["discussion", "terminal"] or
         not valid_entry_author?(kind, author, entry) do
      {:error, "event_identity_invalid"}
    else
      case DB.transaction(db, fn txn ->
             admission =
               if source == :origin,
                 do: Tightbeam.HarklightOrigin.admission(txn, handle),
                 else: :legacy

             case admission do
               :ignored ->
                 :ignored

               :moving ->
                 Tightbeam.HarklightOrigin.stage(txn, handle, event_id, cursor, line)

               mode ->
                 if mode == :confirmed,
                   do: Tightbeam.HarklightOrigin.stage(txn, handle, event_id, cursor, line)

                 result =
                   capture_event_in_txn(
                     txn,
                     handle,
                     line,
                     event_id,
                     cursor,
                     sender_id,
                     message_id,
                     revision,
                     kind,
                     author,
                     mode == :confirmed
                   )

                 cond do
                   result == :ok and mode == :confirmed ->
                     Tightbeam.HarklightOrigin.captured(txn, handle, event_id)

                   mode == :confirmed and
                       result in [
                         {:error, "harklight_origin_unavailable"},
                         {:error, "harklight_send_pending"}
                       ] ->
                     # One temporarily unavailable recipient must not stop the
                     # enrollment's stream or lose an already-offered entry.
                     :captured

                   true ->
                     result
                 end
             end
           end) do
        {:ok, result} -> result
        {:error, _} -> {:error, "capture_unavailable"}
      end
    end
  end

  defp valid_entry_author?("discussion", author, _entry), do: author in ["person", "agent"]

  defp valid_entry_author?("terminal", "server", entry),
    do: entry["terminal_state"] in ["expired", "superseded"]

  defp valid_entry_author?("terminal", author, _entry), do: author in ["person", "agent"]

  defp capture_event_in_txn(
         txn,
         handle,
         line,
         event_id,
         cursor,
         sender_id,
         message_id,
         revision,
         kind,
         author,
         replay?
       ) do
    handle_state =
      Txn.q(
        txn,
        "SELECT sessionKey,host,lastCursor,state FROM harklight_wake_handles WHERE handle=?1",
        [handle]
      )

    case handle_state do
      [[session_key, host, prior_cursor, state]]
      when state == "active" or (replay? and state == "unavailable") ->
        if listener_eligible_in_txn?(txn, handle, session_key, host) do
          if state == "unavailable",
            do:
              Txn.q(
                txn,
                "UPDATE harklight_wake_handles SET state='active',lastError=NULL WHERE handle=?1",
                [handle]
              )

          capture_for_active_origin(
            txn,
            handle,
            session_key,
            if(replay?, do: min(prior_cursor, cursor - 1), else: prior_cursor),
            line,
            event_id,
            cursor,
            sender_id,
            message_id,
            revision,
            kind,
            author
          )
        else
          {:error, "harklight_origin_unavailable"}
        end

      _ ->
        {:error, "harklight_origin_unavailable"}
    end
  end

  defp capture_for_active_origin(
         txn,
         handle,
         session_key,
         prior_cursor,
         line,
         event_id,
         cursor,
         sender_id,
         message_id,
         revision,
         kind,
         author
       ) do
    existing =
      Txn.q(
        txn,
        "SELECT feedCursor,senderId,messageId,requestRevision,entryKind,entryAuthor FROM harklight_wake_entries WHERE handle=?1 AND eventId=?2",
        [
          handle,
          event_id
        ]
      )

    suppressed =
      Txn.q(
        txn,
        "SELECT feedCursor,senderId,messageId,requestRevision,entryKind,entryAuthor FROM harklight_wake_suppressed_entries WHERE handle=?1 AND eventId=?2",
        [handle, event_id]
      )

    cond do
      existing != [] ->
        if existing == [[cursor, sender_id, message_id, revision, kind, author]],
          do: :ok,
          else: {:error, "event_identity_mismatch"}

      suppressed != [] ->
        if suppressed == [[cursor, sender_id, message_id, revision, kind, author]],
          do: :ok,
          else: {:error, "event_identity_mismatch"}

      HarklightLifecycle.hold_terminal_in_txn?(txn, handle, sender_id, message_id, event_id, line) ->
        Txn.q(
          txn,
          "UPDATE harklight_wake_handles SET lastCursor=MAX(lastCursor,?2) WHERE handle=?1",
          [handle, cursor]
        )

        :ok

      true ->
        held = HarklightLifecycle.held_in_txn?(txn, handle, event_id)
        prior_cursor = if held, do: cursor - 1, else: prior_cursor

        request =
          Txn.q(
            txn,
            "SELECT handle FROM harklight_wake_requests WHERE senderId=?1 AND messageId=?2",
            [sender_id, message_id]
          )

        if request == [[handle]] do
          capture_new_entry(
            txn,
            handle,
            session_key,
            prior_cursor,
            line,
            event_id,
            cursor,
            sender_id,
            message_id,
            revision,
            kind,
            author
          )
        else
          {:error, "harklight_send_pending"}
        end
    end
  end

  defp capture_new_entry(
         txn,
         handle,
         session_key,
         prior_cursor,
         line,
         event_id,
         cursor,
         sender_id,
         message_id,
         revision,
         kind,
         author
       ) do
    if cursor <= prior_cursor do
      {:error, "event_order_invalid"}
    else
      wake_id = "w_harklight_" <> handle <> "_" <> String.pad_leading(event_id, 20, "0")
      prompt = line <> "\n\n" <> handling_instruction(handle, event_id, message_id, kind, author)
      now = System.system_time(:millisecond)

      recipients =
        delivery_recipients_in_txn(txn, handle, session_key, sender_id, message_id, kind, line)

      if recipients == [] do
        Txn.q(
          txn,
          "INSERT INTO harklight_wake_suppressed_entries(handle,eventId,feedCursor,senderId,messageId,requestRevision,entryKind,entryAuthor,rawLine,capturedAt) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
          [handle, event_id, cursor, sender_id, message_id, revision, kind, author, line, now]
        )

        if superseded_terminal?(kind, line),
          do:
            HarklightLifecycle.end_message_follows_in_txn(
              txn,
              sender_id,
              message_id,
              handle,
              event_id
            )

        Txn.q(
          txn,
          "UPDATE harklight_wake_handles SET lastCursor=MAX(lastCursor,?2),updatedAt=?3 WHERE handle=?1",
          [handle, cursor, now]
        )

        :ok
      else
        primary = if session_key in recipients, do: session_key, else: hd(recipients)

        wakes =
          Enum.map(recipients, fn recipient ->
            recipient_wake_id =
              if recipient == primary do
                wake_id
              else
                wake_id <> "_" <> recipient_suffix(recipient)
              end

            wake =
              Wakes.schedule_in_txn(txn, %{
                wake_id: recipient_wake_id,
                session_key: recipient,
                origin: "process:tightbeam",
                prompt: prompt,
                due_at: now,
                creator_session_key: session_key,
                class: "blocker"
              })

            {recipient, wake.wake_id}
          end)

        {^primary, primary_wake_id} =
          Enum.find(wakes, fn {recipient, _} -> recipient == primary end)

        Txn.q(
          txn,
          "INSERT INTO harklight_wake_entries(handle,eventId,feedCursor,senderId,messageId,requestRevision,entryKind,entryAuthor,rawLine,wakeId,capturedAt) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
          [
            handle,
            event_id,
            cursor,
            sender_id,
            message_id,
            revision,
            kind,
            author,
            line,
            primary_wake_id,
            now
          ]
        )

        Enum.each(wakes, fn {recipient, recipient_wake_id} ->
          Txn.q(
            txn,
            "INSERT INTO harklight_wake_deliveries(handle,eventId,sessionKey,wakeId) VALUES(?1,?2,?3,?4)",
            [handle, event_id, recipient, recipient_wake_id]
          )

          Wakes.publish_change_in_txn(txn, "wake.scheduled", recipient_wake_id)
        end)

        if superseded_terminal?(kind, line),
          do:
            HarklightLifecycle.end_message_follows_in_txn(
              txn,
              sender_id,
              message_id,
              handle,
              event_id
            )

        Txn.q(
          txn,
          "UPDATE harklight_wake_handles SET lastCursor=MAX(lastCursor,?2),updatedAt=?3 WHERE handle=?1",
          [handle, cursor, now]
        )

        :ok
      end
    end
  end

  defp delivery_recipients_in_txn(txn, handle, owner_session, sender_id, message_id, kind, line) do
    terminal = superseded_terminal?(kind, line)

    superseding_session =
      if terminal,
        do: HarklightLifecycle.supersede_caller_in_txn(txn, sender_id, message_id),
        else: nil

    follow_end = HarklightLifecycle.message_follow_end_kind_in_txn(txn, sender_id, message_id)

    owner_open =
      Txn.q(
        txn,
        "SELECT 1 FROM harklight_subscription_ends WHERE senderId=?1 AND messageId=?2",
        [sender_id, message_id]
      ) == []

    own_recipients = if owner_open, do: [owner_session], else: []

    conversation_recipients =
      Txn.q(
        txn,
        "SELECT sessionKey FROM harklight_wake_follows WHERE handle=?1 AND kind='conversation' AND state='open'",
        [handle]
      )
      |> List.flatten()

    message_recipients =
      if follow_end == "superseded" and not terminal do
        []
      else
        Txn.q(
          txn,
          "SELECT sessionKey FROM harklight_wake_follows WHERE senderId=?1 AND messageId=?2 AND kind='message' AND state='open'",
          [sender_id, message_id]
        )
        |> List.flatten()
      end

    (own_recipients ++ conversation_recipients ++ message_recipients)
    |> Enum.reject(&(terminal and &1 == superseding_session))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp superseded_terminal?("terminal", line) do
    entry = JSON.decode!(line)["entry"]
    entry["terminal_state"] == "superseded"
  end

  defp superseded_terminal?(_, _), do: false

  defp recipient_suffix(session_key) do
    :crypto.hash(:sha256, session_key)
    |> Base.encode16(case: :lower)
  end

  defp handling_instruction(handle, event_id, message_id, _kind, _author) do
    "Handle this Harklight entry from your originating session. First run `harklight-agent ack --session #{handle} --event #{event_id}`. " <>
      "For a person discussion, reply with `harklight-agent reply --session #{handle} --request #{message_id} --in-reply-to #{event_id} --body <reply>`. " <>
      "For an answered terminal by a person, reconcile any earlier effect before applying once, then report with `harklight-agent result --session #{handle} --request #{message_id} --in-reply-to #{event_id} --status applied|refused`. An agent-authored terminal is not the person's choice. " <>
      "For cleared, expired or superseded, stop work on that request; do not treat it as approval. " <>
      "If delivered is true, check prior effects before acting again. Do not run listen; the controller listens."
  end

  defp pending_supersede_targets(payload) do
    prepared = JSON.decode!(payload)
    request = prepared["request"] || %{}
    message = request["message"] || %{}
    sender = message["sender_id"]
    targets = message["supersedes"] || []

    if is_binary(sender) and is_list(targets) do
      targets
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.map(&{sender, &1})
    else
      []
    end
  end

  defp insert_pending_supersedes(txn, op_id, targets) do
    Enum.each(targets, fn {sender, message} ->
      Txn.q(
        txn,
        "INSERT OR IGNORE INTO harklight_pending_supersedes(opId,senderId,messageId) VALUES(?1,?2,?3)",
        [op_id, sender, message]
      )
    end)
  end

  # Keep this one-time pending-payload walk in schema migration, never in
  # terminal capture. The marker commits with the backfill so interruption retries it.
  defp backfill_pending_supersedes(db) do
    case DB.migration_transaction(db, :harklight_pending_supersedes_backfill, [], [], fn txn ->
           :ok =
             Txn.exec(txn, """
             CREATE TABLE IF NOT EXISTS harklight_pending_supersedes_migration (
               id INTEGER PRIMARY KEY CHECK(id=0),
               appliedAt INTEGER NOT NULL CHECK(appliedAt >= 0)
             )
             """)

           case Txn.q(txn, "SELECT id,appliedAt FROM harklight_pending_supersedes_migration") do
             [] ->
               Txn.q(
                 txn,
                 """
                 INSERT OR IGNORE INTO harklight_pending_supersedes(opId,senderId,messageId)
                 SELECT s.opId,json_extract(s.payload,'$.request.message.sender_id'),target.value
                 FROM harklight_send_operations s
                 JOIN json_each(s.payload,'$.request.message.supersedes') target
                 LEFT JOIN harklight_command_results r ON r.opId=s.opId
                 WHERE s.state='pending' AND r.opId IS NULL
                   AND json_type(s.payload,'$.request.message.sender_id')='text'
                   AND target.type='text' AND target.value<>''
                 """
               )

               Txn.q(
                 txn,
                 "INSERT INTO harklight_pending_supersedes_migration(id,appliedAt) VALUES(0,?1)",
                 [System.system_time(:millisecond)]
               )

               :ok

             [[0, applied_at]] when is_integer(applied_at) and applied_at >= 0 ->
               :ok

             rows ->
               raise Tightbeam.Schema.ShapeError,
                 message: "incompatible_harklight_pending_supersedes_migration: #{inspect(rows)}"
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
