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
         :ok <- HarklightLifecycle.ensure_schema(db) do
      backfill_pending_supersedes(db)
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

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

  def origin_ready(session_key) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, {:origin_ready, session_key})
    :ok
  end

  @impl true
  def init(opts) do
    send(self(), :restore)

    {:ok,
     %{
       db: Keyword.get(opts, :db, DB),
       listener: Keyword.get(opts, :listener, &run_listener/3),
       send_runner: Keyword.get(opts, :send_runner),
       workers: %{},
       refs: %{},
       restart: MapSet.new(),
       stopping: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:restore, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle FROM harklight_wake_handles WHERE state IN ('active','unavailable') ORDER BY createdAt,handle"
      )

    Task.start(fn ->
      Tightbeam.HarklightSend.recover_pending(state.db, runner: state.send_runner)
      HarklightLifecycle.process_terminals(state.db, runner: state.send_runner)
    end)

    {:noreply, Enum.reduce(rows, state, fn [handle], acc -> start_worker(acc, handle) end)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {handle, refs} ->
        state = %{state | refs: refs, workers: Map.delete(state.workers, handle)}

        cond do
          MapSet.member?(state.stopping, handle) ->
            {:noreply, %{state | stopping: MapSet.delete(state.stopping, handle)}}

          MapSet.member?(state.restart, handle) ->
            state = %{state | restart: MapSet.delete(state.restart, handle)}
            {:noreply, start_worker(state, handle)}

          true ->
            mark_finished(state.db, handle, "listener_terminated")
            {:noreply, state}
        end
    end
  end

  def handle_cast({:pointer_changed, session_key}, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle FROM harklight_wake_handles WHERE sessionKey=?1 AND state IN ('active','unavailable')",
        [session_key]
      )

    {:noreply, Enum.reduce(rows, state, fn [handle], acc -> force_worker(acc, handle) end)}
  end

  def handle_cast({:origin_changed, session_key}, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle,host,state FROM harklight_wake_handles WHERE sessionKey=?1",
        [session_key]
      )

    state =
      Enum.reduce(rows, state, fn [handle, host, handle_state], acc ->
        if listener_eligible?(acc.db, handle, session_key, host) do
          if handle_state == "complete", do: acc, else: start_worker(acc, handle)
        else
          # Persist invalidation before the worker's DOWN can reach observers.
          mark_finished(acc.db, handle, "origin_unavailable")
          acc = stop_worker(acc, handle)
          notify_pending_origin_unavailable(acc.db, handle)
          acc
        end
      end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:activate, handle, true}, state) do
    {:noreply, force_worker(state, handle)}
  end

  def handle_cast({:activate, handle, false}, state), do: {:noreply, start_worker(state, handle)}

  def handle_cast({:origin_ready, session_key}, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle FROM harklight_wake_handles WHERE sessionKey=?1 AND state IN ('active','unavailable') ORDER BY createdAt,handle",
        [session_key]
      )

    {:noreply, Enum.reduce(rows, state, fn [handle], acc -> start_worker(acc, handle) end)}
  end

  defp force_worker(state, handle) do
    case Map.fetch(state.workers, handle) do
      {:ok, worker} ->
        Process.exit(worker, :shutdown)
        %{state | restart: MapSet.put(state.restart, handle)}

      :error ->
        start_worker(state, handle)
    end
  end

  defp stop_worker(state, handle) do
    case Map.fetch(state.workers, handle) do
      {:ok, worker} ->
        Process.exit(worker, :shutdown)

        %{
          state
          | stopping: MapSet.put(state.stopping, handle),
            restart: MapSet.delete(state.restart, handle)
        }

      :error ->
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
      (match?(%{state: "active", host: ^host}, Org.get(db, session_key)) or
         match?(
           {:ok, [[1]]},
           DB.query(
             db,
             "SELECT 1 FROM harklight_wake_follows WHERE handle=?1 AND state='open' LIMIT 1",
             [handle]
           )
         ))
  end

  defp listener_eligible_in_txn?(txn, handle, session_key, host) do
    host == Placement.local_host_name() and
      (match?(%{state: "active", host: ^host}, Org.get_in_txn(txn, session_key)) or
         Txn.q(
           txn,
           "SELECT 1 FROM harklight_wake_follows WHERE handle=?1 AND state='open' LIMIT 1",
           [handle]
         ) != [])
  end

  @impl true
  def handle_call({:capture, handle, line}, from, state) do
    result =
      if valid_worker?(state, handle, from),
        do: capture_line(state.db, handle, line),
        else: {:error, "listener_fenced"}

    if result == :ok,
      do: HarklightLifecycle.acknowledge_pending(state.db, runner: state.send_runner)

    {:reply, result, state}
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

    {:reply, result, state}
  end

  def handle_call({:finished, handle, status}, from, state) do
    result =
      if valid_worker?(state, handle, from) do
        # Later restoration failures still matter when the durable handle is
        # already unavailable; owner wake/state gating remains in the writer.
        if status != :complete, do: log_listener_failure(handle, status)
        mark_finished(state.db, handle, status)
      else
        :ok
      end

    {:reply, result, state}
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
      [[session_key, "active"]] ->
        now = System.system_time(:millisecond)
        completed = status == :complete
        next_state = if completed, do: "complete", else: "unavailable"

        {error, operation, diagnostic} =
          if completed, do: {nil, nil, nil}, else: failure_details(status)

        Txn.q(
          txn,
          "UPDATE harklight_wake_handles SET state=?2,lastError=?3,updatedAt=?4 WHERE handle=?1",
          [handle, next_state, error, now]
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
         notice_kind,
         error,
         operation,
         diagnostic,
         now
       ) do
    wake_id = "w_harklight_notice_" <> notice_kind <> "_" <> handle

    if Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [wake_id]) == [] do
      if recipient = Supervision.ladder_target(txn, session_key, 1) do
        cli_output =
          case {operation, diagnostic} do
            {operation, diagnostic}
            when operation in ["attach", "listen"] and is_binary(diagnostic) ->
              " Failure cause is unknown. Sanitized #{String.upcase(operation)} CLI failure details: #{diagnostic}."

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
              "Harklight listening for session #{session_key} and handle #{handle} stopped (#{error}).#{cli_output} Pending entries remain at the origin. Restore only that session on its original host; do not transfer the conversation.",
            due_at: now,
            class: "blocker"
          })

        Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)
      end
    end
  end

  defp start_worker(state, handle) do
    if Map.has_key?(state.workers, handle) do
      state
    else
      case DB.query(
             state.db,
             "SELECT sessionKey,host,vendorSessionId,state FROM harklight_wake_handles WHERE handle=?1",
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

            manager = self()
            {:ok, pid} = Task.start(fn -> state.listener.(manager, handle, vendor_id) end)
            ref = Process.monitor(pid)

            %{
              state
              | workers: Map.put(state.workers, handle, pid),
                refs: Map.put(state.refs, ref, handle)
            }
          else
            state
          end

        _ ->
          state
      end
    end
  end

  defp run_listener(manager, handle, vendor_id) do
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
        args = [
          "attach",
          "--session",
          handle,
          "--vendor-session-id",
          vendor_id || "none",
          "--route",
          "other",
          "--controller"
        ]

        case attach(executable, args) do
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

  defp attach(executable, args) do
    case attach_once(executable, args, "ATTACH initial attempt") do
      {:unknown, op_id, initial_diagnostic} ->
        case retry_existing_operation(executable, op_id) do
          {:ok, retry_diagnostic} ->
            case attach_once(executable, args, "ATTACH after same-operation retry") do
              :ok ->
                :ok

              {:unknown, _op_id, diagnostic} ->
                {:error, "attachment_outcome_unknown",
                 [initial_diagnostic, retry_diagnostic, diagnostic]}

              {:error, reason, diagnostic} ->
                {:error, reason, [initial_diagnostic, retry_diagnostic, diagnostic]}
            end

          {:error, retry_diagnostic} ->
            {:error, "attachment_outcome_unknown", [initial_diagnostic, retry_diagnostic]}
        end

      result ->
        attach_result(result)
    end
  rescue
    _ ->
      {:error, "attachment_cli_failed", attempt_diagnostic("ATTACH initial attempt", nil, nil)}
  end

  defp retry_existing_operation(executable, op_id) do
    case System.cmd(executable, ["retry", "--op-id", op_id], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, attempt_diagnostic("ATTACH existing same-operation retry", 0, output)}

      {output, exit_status} ->
        {:error, attempt_diagnostic("ATTACH existing same-operation retry", exit_status, output)}
    end
  rescue
    _ ->
      {:error, attempt_diagnostic("ATTACH existing same-operation retry", nil, nil)}
  end

  defp attach_once(executable, args, attempt) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
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
          do: {:unknown, unknown, diagnostic},
          else: {:error, "attachment_refused", diagnostic}
    end
  rescue
    _ -> {:error, "attachment_cli_failed", attempt_diagnostic(attempt, nil, nil)}
  end

  defp attach_result({:unknown, _op_id, diagnostic}),
    do: {:error, "attachment_outcome_unknown", diagnostic}

  defp attach_result({:unknown, _}), do: {:error, "attachment_outcome_unknown", nil}
  defp attach_result({:error, reason}), do: {:error, reason, nil}
  defp attach_result(result), do: result

  defp attempt_diagnostic(attempt, exit_status, output) do
    status =
      case exit_status do
        status when is_integer(status) -> "exit status: #{status}"
        _ -> "exit status: unknown (not observed)"
      end

    output = sanitize_refusal_output(output)
    output_detail = if output, do: "sanitized output: #{output}", else: "no safe output captured"

    "#{attempt}; #{status}; #{output_detail}"
    |> sanitize_diagnostic_text()
  end

  defp follow(manager, executable, handle) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["listen", "--follow", "--controller", "--session", handle]
      ])

    receive_lines(manager, port, handle, "", [])
  rescue
    _ ->
      finish(
        manager,
        handle,
        failure_status(
          "listener_failed",
          "listen",
          attempt_diagnostic("LISTEN attempt (Port exit status)", nil, nil)
        )
      )
  end

  defp receive_lines(manager, port, handle, pending, diagnostics) do
    receive do
      {^port, {:data, bytes}} ->
        data = pending <> bytes
        lines = String.split(data, "\n")
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
            Port.close(port)

            finish(
              manager,
              handle,
              failure_status(
                reason,
                "listen",
                attempt_diagnostic("LISTEN attempt", nil, joined_diagnostics(next_diagnostics))
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
                attempt_diagnostic(
                  "LISTEN attempt",
                  0,
                  joined_diagnostics(append_diagnostic(diagnostics, pending))
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
            attempt_diagnostic("LISTEN attempt", exit_status, joined_diagnostics(diagnostics))
          )
        )
    end
  end

  # The Agent emits JSON events on stdout and reconnect/refusal messages on
  # stderr. The port merges them; keep plain-text diagnostics without treating
  # them as events, and leave every JSON line on the existing capture path.
  defp receive_listener_line(manager, handle, line, diagnostics) do
    line = String.replace_invalid(line)

    case JSON.decode(line) do
      {:ok, _event} ->
        case GenServer.call(manager, {:capture, handle, line}, :infinity) do
          :ok -> {:ok, diagnostics}
          {:error, reason} -> {:error, reason, append_diagnostic(diagnostics, line)}
        end

      {:error, _} ->
        if structured_output_line?(line) do
          {:error, "invalid_listener_line", diagnostics}
        else
          {:ok, append_diagnostic(diagnostics, line)}
        end
    end
  end

  defp failure_status(error, operation, diagnostic),
    do: {:harklight_failure, error, operation, diagnostic}

  defp failure_details({:harklight_failure, error, operation, diagnostics}),
    do: {to_string(error), operation, format_failure_diagnostics(diagnostics)}

  defp failure_details(error), do: {to_string(error), nil, nil}

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
      when kind in ["error", "unsupported"] and is_binary(reason) ->
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

  defp joined_diagnostics([]), do: nil

  defp joined_diagnostics(diagnostics),
    do: diagnostics |> Enum.join(" | ") |> String.slice(0, @max_diagnostic_chars)

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

  defp capture_event(db, handle, line, event) do
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
               author
             )
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
         author
       ) do
    handle_state =
      Txn.q(
        txn,
        "SELECT sessionKey,host,lastCursor,state FROM harklight_wake_handles WHERE handle=?1",
        [handle]
      )

    case handle_state do
      [[session_key, host, prior_cursor, "active"]] ->
        if listener_eligible_in_txn?(txn, handle, session_key, host) do
          capture_for_active_origin(
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
