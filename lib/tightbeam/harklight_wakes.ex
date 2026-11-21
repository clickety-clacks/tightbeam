defmodule Tightbeam.HarklightWakes do
  @moduledoc """
  Routes filtered Harklight changes to durable Tightbeam wakes. Tightbeam
  checkpoints its own capture independently of the Agent CLI's journal.
  """

  use GenServer
  require Logger
  alias Tightbeam.{DB, ErrorDiagnostic, HarklightLifecycle, Org, Placement, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  @feed_state_retry_delays [250, 500, 1_000, 2_000, 5_000, 10_000, 30_000]
  @feed_read_retry_delay 250

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
  CREATE TABLE IF NOT EXISTS harklight_feed_checkpoints (
    handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
    rev INTEGER NOT NULL CHECK(rev >= 0)
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
         :ok <- Tightbeam.HarklightReceipts.ensure_schema(db),
         :ok <- Tightbeam.HarklightBriefings.ensure_schema(db) do
      backfill_pending_supersedes(db)
    end
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
        WHERE sessionKey=?1 OR currentReceiverSessionKey=?1
        UNION
        SELECT h.handle,h.sessionKey,h.host,h.state
        FROM harklight_wake_handles h
        JOIN harklight_wake_follows f ON f.handle=h.handle
        WHERE f.sessionKey=?1 AND f.state='open'
        """,
        [session_key]
      )

    # Ended handles never acquire receivers from a later retirement.
    rows =
      Enum.reject(rows, fn [handle, _, _, state] ->
        state == "complete" or
          Txn.q(
            txn,
            "SELECT 1 FROM harklight_wake_handles WHERE handle=?1 AND state='unavailable' AND lastError='origin_unavailable'",
            [handle]
          ) != []
      end)

    Enum.each(rows, fn [handle, origin, host, _] ->
      follows_conversation =
        Txn.q(
          txn,
          "SELECT 1 FROM harklight_wake_follows WHERE handle=?1 AND sessionKey=?2 AND kind='conversation' AND state='open'",
          [handle, session_key]
        ) != []

      [[receiver]] =
        Txn.q(
          txn,
          "SELECT COALESCE(currentReceiverSessionKey,sessionKey) FROM harklight_wake_handles WHERE handle=?1",
          [handle]
        )

      if receiver == session_key or
           (follows_conversation and
              match?(%{state: "retired"}, Org.get_in_txn(txn, receiver)) and
              not actual_receiver_eligible_in_txn?(txn, handle, origin, host)) do
        case successor_in_txn(txn, session_key) do
          %{session_key: successor, host: ^host} ->
            Txn.q(
              txn,
              "INSERT OR IGNORE INTO harklight_wake_follows(followId,sessionKey,kind,handle,senderId,messageId,state,createdAt) VALUES(?1,?2,'conversation',?3,NULL,'','open',?4)",
              [Tightbeam.Id.uuid4(), successor, handle, System.system_time(:millisecond)]
            )

            handoff_pending_in_txn(txn, handle, session_key, successor, origin)

          _ ->
            :ok
        end
      end
    end)

    handles = Enum.map(rows, fn [handle, _origin_session_key, _host, _state] -> handle end)

    gone_handles =
      for [handle, origin_session_key, host, _state] <- rows,
          not actual_receiver_eligible_in_txn?(txn, handle, origin_session_key, host),
          do: handle

    {:origin_retired, session_key, handles, gone_handles}
  end

  @doc false
  def successor_in_txn(txn, session_key),
    do: successor_in_txn(txn, session_key, MapSet.new())

  defp successor_in_txn(txn, session_key, visited) do
    if MapSet.member?(visited, session_key) do
      nil
    else
      office =
        Txn.q(
          txn,
          """
          SELECT r.boundSessionKey FROM retirement_blockers b
          JOIN unfinished_retirements u ON u.id=b.retirementId
          JOIN roles r ON r.name=b.reference
          WHERE b.kind='role' AND b.sessionKey=?1 AND r.createdAt<u.createdAt
            AND r.boundSessionKey IS NOT NULL AND r.boundSessionKey<>?1
          ORDER BY r.name LIMIT 1
          """,
          [session_key]
        )

      candidate =
        case office do
          [[key]] ->
            key

          [] ->
            case Txn.q(
                   txn,
                   "SELECT newOwnerSessionKey FROM retirement_owner_transfers WHERE formerOwnerSessionKey=?1 ORDER BY id LIMIT 1",
                   [session_key]
                 ) do
              [[key]] -> key
              [] -> Supervision.ladder_target(txn, session_key, 1)
            end
        end

      case candidate && Org.get_in_txn(txn, candidate) do
        %{state: "active"} = session ->
          session

        %{state: "retired"} ->
          successor_in_txn(txn, candidate, MapSet.put(visited, session_key))

        _ ->
          nil
      end
    end
  end

  defp handoff_pending_in_txn(txn, handle, retiring, successor, origin) do
    entries =
      Txn.q(
        txn,
        """
        SELECT e.eventId,e.rawLine,e.senderId,e.messageId,e.entryKind,e.entryAuthor,d.wakeId
        FROM harklight_wake_deliveries d
        JOIN harklight_wake_entries e ON e.handle=d.handle AND e.eventId=d.eventId
        JOIN wakes w ON w.wakeId=d.wakeId
        WHERE d.handle=?1 AND d.sessionKey=?2 AND w.state<>'canceled' AND
          (NOT EXISTS (
            SELECT 1 FROM turn_lifecycle_events dispatched
            WHERE dispatched.turnSeq=w.deliveredTurnSeq AND dispatched.kind='prompt_dispatched'
          ) OR (e.entryKind='discussion'
            AND NOT EXISTS (
              SELECT 1 FROM turns t WHERE t.seq=w.deliveredTurnSeq AND t.status='delivered'
            ) AND NOT EXISTS (
              SELECT 1 FROM wake_retry_attempts retry
              JOIN wakes receipt ON receipt.wakeId=retry.wakeId
              JOIN turns t ON t.seq=receipt.deliveredTurnSeq
              WHERE retry.rootWakeId=d.wakeId AND t.status='delivered'
            )))
        ORDER BY e.feedCursor
        """,
        [handle, retiring]
      )

    Enum.each(entries, fn [event, line, sender, message, kind, author, root] ->
      existing =
        Txn.q(
          txn,
          "SELECT wakeId FROM harklight_wake_deliveries WHERE handle=?1 AND eventId=?2 AND sessionKey=?3",
          [handle, event, successor]
        )

      # Retirement is a new handling context even when this recipient already
      # saw the event as a follower. Keep that authored payload in history and
      # make one contextual copy the delivery's new receipt/retry baseline.
      wake =
        Wakes.schedule_in_txn(txn, %{
          session_key: successor,
          origin: "process:tightbeam",
          prompt: entry_prompt(txn, origin, line, handle, event, sender, message, kind, author),
          due_at: System.system_time(:millisecond),
          creator_session_key: origin,
          class: "blocker"
        })

      replacement = wake.wake_id

      Txn.q(
        txn,
        """
        INSERT INTO harklight_wake_deliveries(handle,eventId,sessionKey,wakeId)
        VALUES(?1,?2,?3,?4)
        ON CONFLICT(handle,eventId,sessionKey) DO UPDATE SET wakeId=excluded.wakeId
        """,
        [handle, event, successor, replacement]
      )

      Wakes.publish_change_in_txn(txn, "wake.scheduled", replacement)

      # The retired target is the conversation's former responsible session;
      # its transition replaces even an active follower's old handling context.
      Enum.each(existing, fn [prior] ->
        cancel_handoff_attempts_in_txn(txn, prior, %{
          requester: %{kind: "process", id: "tightbeam:retirement"},
          reason_kind: "target_retired",
          causal_source: %{kind: "session_transition", id: retiring},
          outcome: %{kind: "replacement", replacement_wake_id: replacement}
        })
      end)

      cancel_handoff_attempts_in_txn(txn, root, %{
        requester: %{kind: "process", id: "tightbeam:retirement"},
        reason_kind: "target_retired",
        causal_source: %{kind: "session_transition", id: retiring},
        outcome: %{kind: "replacement", replacement_wake_id: replacement}
      })
    end)
  end

  defp cancel_handoff_attempts_in_txn(txn, root, command) do
    # Withdraw the old recipient's pending attempts, including a sealed source.
    Txn.q(
      txn,
      """
      SELECT wakeId FROM wakes WHERE wakeId=?1 AND state='pending'
      UNION
      SELECT w.wakeId FROM wake_retry_attempts retry
      JOIN wakes w ON w.wakeId=retry.wakeId
      WHERE retry.rootWakeId=?1 AND w.state='pending'
      """,
      [root]
    )
    |> Enum.each(fn [wake_id] ->
      result = Wakes.cancel_in_txn(txn, Map.put(command, :wake_id, wake_id))

      if result == false, do: raise("Harklight retirement cancellation refused for #{wake_id}")
    end)
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

  # Revise/retract operations use the existing operation journal. Their tagged
  # payload keeps the exact argv (including the original operation ID) apart
  # from the send payload shape consumed by send recovery and registration.
  def prepare_change(db, call, op_id, message_id, command, request, context \\ %{}) do
    session_key = call.session_key

    with true <- authenticated_origin?(call),
         true <- is_binary(op_id) and Regex.match?(@uuid4, op_id),
         true <- is_binary(message_id) and message_id != "",
         true <- command in ["revise", "retract"],
         true <- is_list(request) and request != [] and Enum.all?(request, &is_binary/1),
         %{state: "active", host: host} <- Org.get(db, session_key),
         true <- host == Placement.local_host_name() do
      now = System.system_time(:millisecond)

      payload =
        JSON.encode!(%{
          "operation_kind" => "change",
          "command" => command,
          "message_id" => message_id,
          "request" => request,
          "journal_id" => context[:journal_id],
          "item_id" => context[:item_id],
          "in_reply_to" => context[:in_reply_to],
          "handle" => context[:handle]
        })

      case DB.transaction(db, fn txn ->
             case Txn.q(
                    txn,
                    "SELECT sessionKey,host,payload,state FROM harklight_send_operations WHERE opId=?1",
                    [op_id]
                  ) do
               [] ->
                 unresolved =
                   Txn.q(
                     txn,
                     """
                     SELECT s.opId
                     FROM harklight_send_operations s
                     LEFT JOIN harklight_command_results r ON r.opId=s.opId
                     WHERE json_extract(s.payload,'$.operation_kind')='change'
                       AND json_extract(s.payload,'$.message_id')=?1
                       AND s.state='pending' AND r.opId IS NULL
                     LIMIT 1
                     """,
                     [message_id]
                   )

                 if unresolved == [] do
                   Txn.q(
                     txn,
                     "INSERT INTO harklight_send_operations(opId,sessionKey,host,payload,attemptedAt,state,createdAt,updatedAt) VALUES(?1,?2,?3,?4,?5,'pending',?5,?5)",
                     [op_id, session_key, host, payload, now]
                   )

                   {:ok, "pending"}
                 else
                   {:error, "harklight_operation_unresolved"}
                 end

               [[^session_key, ^host, ^payload, "pending"]] ->
                 case Txn.q(txn, "SELECT 1 FROM harklight_command_results WHERE opId=?1", [op_id]) do
                   [] -> {:ok, "pending"}
                   _ -> {:error, "harklight_change_already_settled"}
                 end

               _ ->
                 {:error, "harklight_change_mismatch"}
             end
           end) do
        {:ok, {:ok, state}} -> %{op_id: op_id, payload: payload, state: state}
        {:ok, {:error, reason}} -> %{code: reason}
        {:error, reason} -> %{code: "harklight_change_unavailable", message: inspect(reason)}
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
                 with :ok <-
                        Tightbeam.HarklightBriefings.validate_send_binding_in_txn(
                          txn,
                          op_id,
                          session_key,
                          payload,
                          handle,
                          sender_id,
                          message_id
                        ) do
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
                       with :ok <-
                              Tightbeam.HarklightBriefings.bind_send_in_txn(
                                txn,
                                op_id,
                                session_key,
                                payload,
                                handle,
                                sender_id,
                                message_id
                              ) do
                         effects =
                           HarklightLifecycle.send_committed_in_txn(
                             txn,
                             session_key,
                             op_id,
                             payload,
                             result
                           )

                         {:ok, Map.merge(registration, effects)}
                       end

                     error ->
                       error
                   end
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
                 with :ok <-
                        Tightbeam.HarklightBriefings.validate_send_binding_in_txn(
                          txn,
                          op_id,
                          session_key,
                          payload,
                          handle,
                          sender_id,
                          message_id
                        ) do
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
                       with :ok <-
                              Tightbeam.HarklightBriefings.bind_send_in_txn(
                                txn,
                                op_id,
                                session_key,
                                payload,
                                handle,
                                sender_id,
                                message_id
                              ) do
                         effects =
                           HarklightLifecycle.send_committed_in_txn(
                             txn,
                             session_key,
                             op_id,
                             payload,
                             result
                           )

                         {:ok, Map.merge(registration, effects)}
                       end

                     error ->
                       error
                   end
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
      "SELECT opId,sessionKey,payload FROM harklight_send_operations WHERE state='pending' AND attemptedAt IS NOT NULL AND COALESCE(json_extract(payload,'$.operation_kind'),'send')<>'change' AND opId NOT IN (SELECT opId FROM harklight_command_results) ORDER BY attemptedAt,opId"
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
        "SELECT COALESCE(currentReceiverSessionKey,sessionKey) FROM harklight_send_operations WHERE sessionKey=?1 AND host=?2 AND handle=?3 AND senderId=?4 AND messageId=?5 AND state='bound'",
        [session_key, host, handle, sender_id, message_id]
      )

    cond do
      provenance == [] ->
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
          [[receiver]] = provenance

          Txn.q(
            txn,
            "INSERT INTO harklight_wake_handles(handle,sessionKey,host,vendorSessionId,state,createdAt,updatedAt,currentReceiverSessionKey) VALUES(?1,?2,?3,?4,'active',?5,?5,?6)",
            [
              handle,
              session_key,
              host,
              vendor_id,
              now,
              if(receiver == session_key, do: nil, else: receiver)
            ]
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

  def restore_listener(db, call, handle) do
    with true <- authenticated_origin?(call),
         true <- is_binary(handle) and Regex.match?(@uuid4, handle),
         %{state: "active", host: host} <- Org.get(db, call.session_key),
         true <- host == Placement.local_host_name(),
         pid when is_pid(pid) <- Process.whereis(__MODULE__) do
      case GenServer.call(pid, {:restore_listener, call.session_key, handle}, :infinity) do
        {:ok, listener_state} ->
          %{
            command: "listener-restore",
            outcome: "requested",
            listener_state: listener_state,
            handle: handle,
            session_key: call.session_key
          }

        {:error, reason} ->
          %{command: "listener-restore", code: reason, outcome: "refused", handle: handle}
      end
    else
      _ ->
        %{
          command: "listener-restore",
          code: "harklight_origin_unavailable",
          outcome: "refused",
          reason: "listener restoration requires its active originating session on this host"
        }
    end
  end

  def retry_command(db, call) do
    params = Map.get(call, :params, %{})

    with {:ok, selector} <- retry_selector(params),
         {:ok, targets} <- retry_targets(db, selector),
         {:ok, targets} <- retry_target_messages(db, targets, selector) do
      results =
        Enum.map(targets, fn target ->
          outcome = retry_handle(target.handle)
          retry_result(target, outcome)
        end)

      counts =
        Enum.reduce(results, retry_empty_counts(), fn result, counts ->
          Map.update!(counts, String.to_existing_atom(result.outcome), &(&1 + 1))
        end)

      %{selector: selector_name(selector), results: results, counts: counts}
    else
      {:error, code, message} -> %{code: code, message: message}
    end
  rescue
    _ ->
      %{
        code: "harklight_retry_state_unavailable",
        message: "Tightbeam could not read retry state"
      }
  end

  defp retry_selector(params) do
    all = Map.get(params, :all) == true
    message = Map.get(params, :message_id)
    handle = Map.get(params, :handle)

    selected =
      [all, is_binary(message) and message != "", is_binary(handle) and handle != ""]
      |> Enum.count(& &1)

    if selected != 1 do
      {:error, "invalid_harklight_retry_selector",
       "choose exactly one of --all, --message <id>, or --session <handle>"}
    else
      cond do
        all -> {:ok, :all}
        is_binary(message) and message != "" -> {:ok, {:message, message}}
        true -> {:ok, {:session, handle}}
      end
    end
  end

  # Besides failed handles, select active ones that have no listener: a listener
  # that ended before its state was recorded leaves its row looking healthy.
  defp retry_targets(db, :all) do
    case DB.query(
           db,
           "SELECT handle,sessionKey,state,lastError FROM harklight_wake_handles h WHERE state IN ('active','unavailable') ORDER BY createdAt,handle"
         ) do
      {:ok, rows} ->
        active = for [handle, _, "active", _] <- rows, do: handle
        unlistened = unlistened_handles(active)

        {:ok,
         for [handle, session_key, state, last_error] <- rows,
             state == "unavailable" or MapSet.member?(unlistened, handle) do
           %{handle: handle, origin_session: session_key, state: state, last_error: last_error}
         end}

      _ ->
        {:error, "harklight_retry_state_unavailable", "could not select unavailable handles"}
    end
  end

  defp retry_targets(db, {:session, handle}) do
    case retry_target_by_handle(db, handle) do
      {:ok, target} ->
        {:ok, [target]}

      :not_found ->
        {:error, "harklight_handle_unknown",
         "no Tightbeam Harklight handle record exists for #{handle}"}

      :error ->
        {:error, "harklight_retry_state_unavailable", "could not read the selected handle"}
    end
  end

  defp retry_targets(db, {:message, message_id}) do
    case HarklightLifecycle.lookup(db, message_id) do
      nil ->
        {:error, "harklight_message_unknown",
         "no Tightbeam Harklight send record exists for message #{message_id}"}

      %{handle: handle} = message when is_binary(handle) and handle != "" ->
        case retry_target_by_handle(db, handle) do
          {:ok, target} ->
            {:ok,
             [
               Map.put(target, :selected_message, %{
                 sender_id: message.sender_id,
                 message_id: message.message_id || message_id
               })
             ]}

          :not_found ->
            {:error, "harklight_message_unresolved",
             "message #{message_id} has no recorded Harklight handle"}

          :error ->
            {:error, "harklight_retry_state_unavailable", "could not read the selected handle"}
        end

      _ ->
        {:error, "harklight_message_unresolved",
         "message #{message_id} has no recorded Harklight handle"}
    end
  rescue
    _ ->
      {:error, "harklight_retry_state_unavailable", "could not resolve the selected message"}
  end

  defp retry_target_by_handle(db, handle) do
    case DB.query(
           db,
           "SELECT handle,sessionKey,state,lastError FROM harklight_wake_handles WHERE handle=?1",
           [handle]
         ) do
      {:ok, [[handle, session_key, state, last_error]]} ->
        {:ok,
         %{handle: handle, origin_session: session_key, state: state, last_error: last_error}}

      {:ok, []} ->
        :not_found

      _ ->
        :error
    end
  end

  defp retry_target_messages(db, targets, _selector) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, gathered} ->
      case retry_messages(db, target.handle, target.origin_session) do
        {:ok, messages} ->
          messages =
            case Map.get(target, :selected_message) do
              %{sender_id: sender_id, message_id: message_id} ->
                ensure_selected_message(messages, sender_id, message_id)

              _ ->
                messages
            end

          selected_message =
            case Map.get(target, :selected_message) do
              nil ->
                nil

              %{sender_id: sender_id, message_id: message_id} ->
                %{
                  message_id: message_id,
                  state: message_state(messages, sender_id, message_id)
                }
            end

          target =
            target
            |> Map.put(:messages, messages)
            |> Map.put(:selected_message_state, selected_message)

          {:cont, {:ok, [target | gathered]}}

        {:error, stage, reason} ->
          {:halt,
           {:error, "harklight_retry_state_unavailable",
            "could not read #{stage} for handle #{target.handle}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, gathered} -> {:ok, Enum.reverse(gathered)}
      error -> error
    end
  end

  defp retry_messages(db, handle, origin_session) do
    with {:ok, requests} <-
           retry_message_rows(
             "saved requests",
             db,
             "SELECT senderId,messageId FROM harklight_wake_requests WHERE handle=?1 ORDER BY senderId,messageId",
             [handle]
           ),
         {:ok, bound_sends} <-
           retry_message_rows(
             "bound sends",
             db,
             "SELECT senderId,messageId FROM harklight_send_operations WHERE handle=?1 AND state='bound' ORDER BY senderId,messageId",
             [handle]
           ),
         {:ok, pending_sends} <-
           retry_message_rows(
             "pending sends",
             db,
             "SELECT payload FROM harklight_send_operations WHERE sessionKey=?1 AND state='pending' AND COALESCE(json_extract(payload,'$.operation_kind'),'send')<>'change' ORDER BY opId",
             [origin_session]
           ),
         {:ok, terminals} <-
           retry_message_rows(
             "terminal entries",
             db,
             "SELECT senderId,messageId,rawLine FROM harklight_wake_entries WHERE handle=?1 AND entryKind='terminal' ORDER BY feedCursor",
             [handle]
           ),
         {:ok, pending_messages} <- pending_retry_messages(pending_sends, handle) do
      known =
        (requests ++ bound_sends ++ pending_messages)
        |> Enum.uniq()
        |> Enum.sort()

      terminal_states =
        Enum.reduce(terminals, %{}, fn [sender_id, message_id, raw_line], states ->
          state = captured_terminal_state(raw_line)
          Map.put(states, {sender_id, message_id}, state)
        end)

      {:ok,
       Enum.map(known, fn [sender_id, message_id] ->
         %{
           sender_id: sender_id,
           message_id: message_id,
           state: Map.get(terminal_states, {sender_id, message_id}, "waiting")
         }
       end)}
    else
      {:error, stage, reason} -> {:error, stage, reason}
      :error -> {:error, "pending send payload", "invalid persisted send payload"}
    end
  rescue
    error -> {:error, "message-state conversion", Exception.message(error)}
  end

  defp retry_message_rows(stage, db, sql, params) do
    case DB.query(db, sql, params) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, stage, Exception.message(reason)}
    end
  rescue
    error -> {:error, stage, Exception.message(error)}
  end

  defp pending_retry_messages(rows, handle) do
    Enum.reduce_while(rows, {:ok, []}, fn [payload], {:ok, messages} ->
      case JSON.decode(payload) do
        {:ok, prepared} when is_map(prepared) ->
          request = prepared["request"] || prepared

          cond do
            not is_map(request) ->
              {:halt, :error}

            request["session_handle"] != handle ->
              {:cont, {:ok, messages}}

            is_map(request["message"]) and is_binary(request["message"]["sender_id"]) and
                is_binary(request["message"]["message_id"]) ->
              {:cont,
               {:ok,
                [
                  [request["message"]["sender_id"], request["message"]["message_id"]]
                  | messages
                ]}}

            true ->
              {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      _ -> :error
    end
  end

  defp captured_terminal_state(raw_line) do
    case JSON.decode(raw_line) do
      {:ok, event} when is_map(event) ->
        case get_in(event, ["entry", "terminal_state"]) do
          state when is_binary(state) and state != "" -> state
          _ -> "terminal_state_unavailable"
        end

      _ ->
        "terminal_state_unavailable"
    end
  end

  defp ensure_selected_message(messages, sender_id, message_id) do
    if Enum.any?(messages, &(&1.sender_id == sender_id and &1.message_id == message_id)) do
      messages
    else
      Enum.sort_by(
        messages ++ [%{sender_id: sender_id, message_id: message_id, state: "waiting"}],
        fn message ->
          {message.sender_id, message.message_id}
        end
      )
    end
  end

  defp message_state(messages, sender_id, message_id) do
    case Enum.find(messages, &(&1.sender_id == sender_id and &1.message_id == message_id)) do
      %{state: state} -> state
      _ -> "waiting"
    end
  end

  defp retry_result(target, outcome) do
    result = %{
      handle: target.handle,
      origin_session: target.origin_session,
      messages: target.messages
    }

    result =
      case Map.get(target, :selected_message_state) do
        nil -> result
        selected -> Map.put(result, :selected_message, selected)
      end

    result =
      case outcome do
        :in_progress ->
          Map.put(result, :outcome, "in_progress")

        {:not_failed, state} ->
          Map.merge(result, %{outcome: "not_failed", state: state})

        :skipped_closed ->
          Map.merge(result, %{
            outcome: "skipped_closed",
            reason: "nothing on this handle awaits the person and nothing is undelivered"
          })

        {:listening, started_for} ->
          Map.merge(result, %{
            outcome: "listening",
            started_for: retry_started_for(target.messages, started_for)
          })

        {:failed, reason, started_for} ->
          Map.merge(result, %{
            outcome: "failed",
            reason: reason,
            started_for: retry_started_for(target.messages, started_for)
          })
      end

    result
  end

  defp retry_started_for(messages, reasons) do
    waiting =
      messages
      |> Enum.filter(&(&1.state == "waiting"))
      |> Enum.map(& &1.message_id)

    Map.put(reasons, :waiting_messages, waiting)
  end

  defp selector_name(:all), do: "all"
  defp selector_name({:message, _}), do: "message"
  defp selector_name({:session, _}), do: "session"

  defp retry_empty_counts do
    %{
      in_progress: 0,
      not_failed: 0,
      skipped_closed: 0,
      listening: 0,
      failed: 0
    }
  end

  defp retry_handle(handle) do
    GenServer.call(__MODULE__, {:retry_handle, handle}, :infinity)
  catch
    :exit, _ -> {:failed, "listener manager unavailable", %{eligibility_undecidable: true}}
  end

  defp unlistened_handles([]), do: MapSet.new()

  defp unlistened_handles(handles) do
    GenServer.call(__MODULE__, {:unlistened_handles, handles}, :infinity)
  catch
    :exit, _ -> MapSet.new()
  end

  def origin_ready(session_key) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, {:origin_ready, session_key})
    :ok
  end

  @impl true
  def init(opts) do
    DB.owed_work()

    Process.flag(:trap_exit, true)
    send(self(), :restore)

    state_delays =
      Keyword.get(opts, :feed_state_retry_delays, @feed_state_retry_delays)

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
         Keyword.get(opts, :listener, fn manager, handle, _vendor_id ->
           run_listener(manager, handle, state_delays)
         end),
       send_runner: Keyword.get(opts, :send_runner),
       workers: %{},
       ports: %{},
       refs: %{},
       failures: %{},
       attempts: %{},
       retry_waiters: %{},
       starts_in_flight: MapSet.new(),
       manual_starts: MapSet.new(),
       retry_timers: %{},
       gone_tasks: %{},
       deferred: MapSet.new(),
       retry_delays: Keyword.get(opts, :retry_delays, [1_000, 2_000, 4_000, 8_000, 16_000]),
       restart: MapSet.new(),
       stopping: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:restore, state) do
    case DB.query(
           state.db,
           "SELECT handle FROM harklight_wake_handles WHERE state IN ('active','unavailable') ORDER BY createdAt,handle"
         ) do
      {:ok, rows} ->
        state =
          Enum.reduce(rows, state, fn [handle], acc -> start_worker(acc, handle, :startup) end)

        Task.start(fn ->
          Tightbeam.HarklightSend.recover_pending(state.db, runner: state.send_runner)
          HarklightLifecycle.process_terminals(state.db, runner: state.send_runner)
        end)

        {:noreply, state}

      {:error, _reason} ->
        Process.send_after(self(), :restore, @feed_read_retry_delay)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.gone_tasks, ref) do
      {handle, tasks} when is_binary(handle) ->
        state = %{state | gone_tasks: tasks}

        if MapSet.member?(state.deferred, handle) do
          mode =
            cond do
              MapSet.member?(state.deferred, {handle, :new_request}) -> :new_request
              MapSet.member?(state.deferred, {handle, :startup}) -> :startup
              MapSet.member?(state.deferred, {handle, :retry}) -> :retry
              true -> :existing
            end

          deferred =
            state.deferred
            |> MapSet.delete(handle)
            |> MapSet.delete({handle, :new_request})
            |> MapSet.delete({handle, :startup})
            |> MapSet.delete({handle, :retry})

          {:noreply, start_worker(%{state | deferred: deferred}, handle, mode)}
        else
          {:noreply, state}
        end

      {nil, _} ->
        worker_down(state, ref)
    end
  end

  def handle_info({:retry_listener, handle, token, action}, state) do
    case Map.get(state.retry_timers, handle) do
      {_, ^token} ->
        state = %{state | retry_timers: Map.delete(state.retry_timers, handle)}

        case action do
          :recover -> {:noreply, recover_worker(state, handle)}
          mode -> {:noreply, start_worker(state, handle, mode)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:reconcile_origin, session_key}, state),
    do: {:noreply, reconcile_origin(state, session_key)}

  def handle_info({:reconcile_retirement, handles, gone_handles}, state),
    do: {:noreply, reconcile_retirement(state, handles, MapSet.new(gone_handles))}

  # DOWN owns worker bookkeeping. Linked exits also shut down the worker
  # when its manager crashes.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp worker_down(state, ref) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {handle, refs} ->
        deferred_read = MapSet.member?(state.restart, {handle, :deferred_read})

        state = %{
          state
          | refs: refs,
            workers: Map.delete(state.workers, handle),
            starts_in_flight: MapSet.delete(state.starts_in_flight, handle),
            ports: Map.delete(state.ports, handle),
            restart:
              state.restart
              |> MapSet.delete({handle, :deciding})
              |> MapSet.delete({handle, :deferred_read})
        }

        cond do
          MapSet.member?(state.stopping, handle) ->
            state = %{
              state
              | stopping: MapSet.delete(state.stopping, handle),
                manual_starts: MapSet.delete(state.manual_starts, handle)
            }

            state =
              complete_retry_waiter(
                state,
                handle,
                {:failed, "listener start stopped before feed catch-up completed",
                 retry_waiter_started_for(state, handle)}
              )

            {:noreply, state}

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

          deferred_read ->
            mode = if MapSet.member?(state.manual_starts, handle), do: :retry, else: :existing
            {:noreply, schedule_listener_retry(state, handle, @feed_read_retry_delay, mode)}

          true ->
            if MapSet.member?(state.manual_starts, handle) do
              if Map.has_key?(state.failures, handle),
                do: mark_terminated(state.db, handle),
                else: mark_finished(state.db, handle, "listener_terminated")

              state =
                complete_retry_waiter(
                  state,
                  handle,
                  {:failed, retry_failure_reason(state.db, handle),
                   retry_waiter_started_for(state, handle)}
                )

              {:noreply, %{state | manual_starts: MapSet.delete(state.manual_starts, handle)}}
            else
              mark_terminated(state.db, handle)
              {:noreply, recover_worker(state, handle)}
            end
        end
    end
  end

  # Restart only after the preceding worker has exited.
  defp recover_worker(state, handle) do
    status = Map.get(state.failures, handle, "listener_terminated")

    case DB.query(
           state.db,
           "SELECT sessionKey,host,state FROM harklight_wake_handles WHERE handle=?1",
           [handle]
         ) do
      {:ok, [[_session_key, host, handle_state]]} when handle_state != "complete" ->
        attempt = Map.get(state.attempts, handle, 0)
        delay = Enum.at(state.retry_delays, attempt)

        case listener_eligibility(state.db, handle, host) do
          {:ok, eligible} ->
            if eligible and is_integer(delay) and retryable_failure?(status) do
              state = %{state | attempts: Map.put(state.attempts, handle, attempt + 1)}
              schedule_listener_retry(state, handle, delay, :existing)
            else
              notify_owner_after_recovery_exhaustion(state.db, handle, status)
              state
            end

          {:error, _reason} ->
            schedule_listener_retry(state, handle, @feed_read_retry_delay, :recover)
        end

      {:error, _reason} ->
        schedule_listener_retry(state, handle, @feed_read_retry_delay, :recover)

      _ ->
        state
    end
  end

  defp schedule_listener_retry(state, handle, delay, action) do
    state = cancel_retry(state, handle)
    token = make_ref()
    timer = Process.send_after(self(), {:retry_listener, handle, token, action}, delay)
    %{state | retry_timers: Map.put(state.retry_timers, handle, {timer, token})}
  end

  defp start_gone(state, handle) do
    if handle in Map.values(state.gone_tasks) do
      state
    else
      {:ok, pid} = Task.start_link(fn -> send_origin_gone(handle) end)
      %{state | gone_tasks: Map.put(state.gone_tasks, Process.monitor(pid), handle)}
    end
  end

  defp retryable_failure?({:harklight_failure, {_error, code}, _, _}) do
    code not in ~w(missing_journal configuration_error
      not_found forbidden operation_conflict invalid_field unsupported_version
      feed_gap feed_conflict invalid_notice invalid_response feed_refused)
  end

  defp retryable_failure?({:harklight_failure, error, _, _}), do: retryable_failure?(error)

  defp retryable_failure?(error),
    do: error not in ~w(origin_unavailable origin_host_mismatch
      event_identity_invalid event_identity_mismatch event_order_invalid invalid_listener_line
      unexpected_feed_record)

  defp transient_origin_failure?({:harklight_failure, {_error, code}, operation, _diagnostic})
       when operation == "listen" and code in ["transport_error", "timeout"],
       do: true

  defp transient_origin_failure?(_status), do: false

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.retry_timers, fn {_, {timer, _}} -> Process.cancel_timer(timer) end)
    Enum.each(state.ports, fn {_handle, port} -> close_listener_port(port) end)
    Enum.each(state.workers, fn {_handle, worker} -> Process.exit(worker, :shutdown) end)
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
    {:noreply, reconcile_origin(state, session_key)}
  end

  def handle_cast({:origin_retired, _session_key, handles, gone_handles}, state) do
    {:noreply, reconcile_retirement(state, handles, MapSet.new(gone_handles))}
  end

  @impl true
  def handle_cast({:activate, handle, true}, state) do
    {:noreply, force_worker(state, handle, :new_request)}
  end

  def handle_cast({:activate, handle, false}, state) do
    # Registration must interrupt an outstanding closure read, while an already
    # running listener continues normally.
    state =
      cond do
        MapSet.member?(state.restart, {handle, :deciding}) ->
          force_worker(state, handle, :new_request)

        true ->
          start_worker(state, handle, :new_request)
      end

    {:noreply, state}
  end

  def handle_cast({:origin_ready, session_key}, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle FROM harklight_wake_handles WHERE (sessionKey=?1 OR currentReceiverSessionKey=?1) AND state IN ('active','unavailable') ORDER BY createdAt,handle",
        [session_key]
      )

    {:noreply, Enum.reduce(rows, state, fn [handle], acc -> start_worker(acc, handle) end)}
  end

  defp reconcile_origin(state, session_key) do
    case DB.query(
           state.db,
           "SELECT handle,sessionKey,host,state FROM harklight_wake_handles WHERE sessionKey=?1 OR currentReceiverSessionKey=?1",
           [session_key]
         ) do
      {:ok, rows} ->
        reconcile_rows(state, rows, MapSet.new())

      {:error, _reason} ->
        Process.send_after(self(), {:reconcile_origin, session_key}, @feed_read_retry_delay)
        state
    end
  end

  defp reconcile_retirement(state, handles, gone_handles) do
    Enum.reduce(handles, state, fn handle, acc ->
      case DB.query(
             acc.db,
             "SELECT handle,sessionKey,host,state FROM harklight_wake_handles WHERE handle=?1",
             [handle]
           ) do
        {:ok, rows} -> reconcile_rows(acc, rows, gone_handles)
        {:error, _reason} -> defer_reconciliation(acc, handle, gone_handles)
      end
    end)
  end

  defp reconcile_rows(state, rows, gone_handles) do
    Enum.reduce(rows, state, fn [handle, origin_session_key, host, handle_state], acc ->
      case listener_eligibility(acc.db, handle, host) do
        {:ok, true} ->
          if handle_state == "complete", do: acc, else: start_worker(acc, handle)

        {:ok, false} ->
          # Persist invalidation before the worker's DOWN can reach observers.
          with {:ok, origin_active} <- session_active(acc.db, origin_session_key),
               :ok <- mark_finished(acc.db, handle, "origin_unavailable") do
            acc = stop_worker(acc, handle)
            notify_pending_origin_unavailable(acc.db, handle)

            cond do
              MapSet.member?(gone_handles, handle) ->
                mark_origin_gone_async(handle)
                acc

              host == Placement.local_host_name() and origin_active ->
                start_gone(acc, handle)

              true ->
                acc
            end
          else
            {:error, _reason} -> defer_reconciliation(acc, handle, gone_handles)
          end

        {:error, _reason} ->
          defer_reconciliation(acc, handle, gone_handles)
      end
    end)
  end

  defp defer_reconciliation(state, handle, gone_handles) do
    gone = if MapSet.member?(gone_handles, handle), do: [handle], else: []
    Process.send_after(self(), {:reconcile_retirement, [handle], gone}, @feed_read_retry_delay)
    state
  end

  defp session_active(db, session_key) do
    with {:ok, rows} <-
           DB.query(db, "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'", [
             session_key
           ]) do
      {:ok, rows != []}
    end
  end

  defp listener_eligibility(db, handle, host) do
    if host == Placement.local_host_name() do
      with {:ok, rows} <-
             DB.query(
               db,
               """
               SELECT 1
               FROM harklight_wake_handles h
               JOIN sessions s ON s.state='active' AND s.host=?2
               WHERE h.handle=?1 AND (
                 s.sessionKey=COALESCE(h.currentReceiverSessionKey,h.sessionKey) OR EXISTS (
                   SELECT 1 FROM harklight_wake_follows f
                   WHERE f.handle=h.handle AND f.sessionKey=s.sessionKey AND f.state='open'
                 )
               )
               LIMIT 1
               """,
               [handle, host]
             ) do
        {:ok, rows != []}
      end
    else
      {:ok, false}
    end
  end

  defp actual_receiver_eligible_in_txn?(txn, handle, _session_key, host) do
    [[receiver]] =
      Txn.q(
        txn,
        "SELECT COALESCE(currentReceiverSessionKey,sessionKey) FROM harklight_wake_handles WHERE handle=?1",
        [handle]
      )

    match?(%{state: "active", host: ^host}, Org.get_in_txn(txn, receiver)) or
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
                 ["session", "end", "--session", handle],
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

  defp valid_worker?(state, handle, {pid, _tag}) do
    Map.get(state.workers, handle) == pid and
      not MapSet.member?(state.stopping, handle) and
      not MapSet.member?(state.restart, handle)
  end

  defp retry_waiter_started_for(state, handle) do
    case Map.get(state.retry_waiters, handle) do
      %{started_for: started_for} -> started_for
      _ -> %{eligibility_undecidable: true}
    end
  end

  defp complete_retry_waiter(state, handle, result) do
    case Map.pop(state.retry_waiters, handle) do
      {nil, _waiters} ->
        state

      {%{from: from}, waiters} ->
        GenServer.reply(from, result)
        %{state | retry_waiters: waiters}
    end
  end

  defp retry_failure_reason(db, handle) do
    case DB.query(
           db,
           "SELECT lastError FROM harklight_wake_handles WHERE handle=?1",
           [handle]
         ) do
      {:ok, [[reason]]} when is_binary(reason) and reason != "" -> reason
      _ -> "listener start failed without a recorded reason"
    end
  end

  defp listener_start_in_flight?(state, handle) do
    MapSet.member?(state.starts_in_flight, handle) or
      Map.has_key?(state.retry_timers, handle) or
      Map.has_key?(state.retry_waiters, handle) or
      MapSet.member?(state.restart, handle)
  end

  # A running or winding-down worker, or a pending gone request, accounts for
  # the handle; anything else on an active row means no one is listening.
  defp listener_present?(state, handle) do
    Map.has_key?(state.workers, handle) or handle in Map.values(state.gone_tasks) or
      MapSet.member?(state.deferred, handle)
  end

  defp listener_eligible_in_txn?(txn, handle, session_key, host) do
    host == Placement.local_host_name() and
      actual_receiver_eligible_in_txn?(txn, handle, session_key, host)
  end

  @impl true
  def handle_call({:launch_child, handle, executable, args}, {pid, _} = from, state) do
    if valid_worker?(state, handle, from) do
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

  def handle_call({:unlistened_handles, handles}, _from, state) do
    {:reply,
     handles
     |> Enum.reject(&(listener_start_in_flight?(state, &1) or listener_present?(state, &1)))
     |> MapSet.new(), state}
  end

  def handle_call({:retry_handle, handle}, from, state) do
    cond do
      listener_start_in_flight?(state, handle) ->
        {:reply, :in_progress, state}

      true ->
        case DB.query(
               state.db,
               "SELECT state FROM harklight_wake_handles WHERE handle=?1",
               [handle]
             ) do
          {:ok, [[state_value]]} when state_value in ["active", "complete"] ->
            # A listener that ended before its state was recorded leaves an
            # active row with nothing listening; start it like a failed one.
            if state_value == "active" and not listener_present?(state, handle) do
              state = %{
                state
                | retry_waiters:
                    Map.put(state.retry_waiters, handle, %{from: from, started_for: %{}})
              }

              {:noreply, start_worker(state, handle, :retry)}
            else
              {:reply, {:not_failed, state_value}, state}
            end

          {:ok, [["unavailable"]]} ->
            state = %{
              state
              | retry_waiters:
                  Map.put(state.retry_waiters, handle, %{from: from, started_for: %{}})
            }

            {:noreply, start_worker(state, handle, :retry)}

          {:ok, []} ->
            {:reply, {:failed, "handle no longer exists", %{eligibility_undecidable: true}},
             state}

          _ ->
            {:reply, {:failed, "handle state unavailable", %{eligibility_undecidable: true}},
             state}
        end
    end
  end

  @impl true
  def handle_call({:restore_listener, session_key, handle}, _from, state) do
    # The conversation belongs to its current receiver: a custody transfer or
    # retirement handoff moves it off the session that first opened it.
    case DB.query(
           state.db,
           "SELECT COALESCE(currentReceiverSessionKey,sessionKey),host,state FROM harklight_wake_handles WHERE handle=?1",
           [handle]
         ) do
      {:ok, [[^session_key, host, handle_state]]}
      when handle_state in ["active", "unavailable"] ->
        case listener_eligibility(state.db, handle, host) do
          {:ok, true} ->
            already_running? =
              Map.has_key?(state.workers, handle) and not Map.has_key?(state.failures, handle)

            state =
              cond do
                already_running? -> state
                Map.has_key?(state.workers, handle) -> force_worker(state, handle, :existing)
                true -> start_worker(state, handle, :existing)
              end

            {:reply, {:ok, if(already_running?, do: "active", else: "restoring")}, state}

          {:ok, false} ->
            {:reply, {:error, "harklight_origin_unavailable"}, state}

          {:error, _reason} ->
            {:reply, {:error, "harklight_listener_unavailable"}, state}
        end

      {:ok, [[_other_session, _host, _state]]} ->
        {:reply, {:error, "harklight_origin_mismatch"}, state}

      {:ok, []} ->
        {:reply, {:error, "harklight_handle_unknown"}, state}

      {:error, _reason} ->
        {:reply, {:error, "harklight_listener_unavailable"}, state}
    end
  end

  @impl true
  def handle_call({:feed_start, handle}, from, state) do
    result =
      if valid_worker?(state, handle, from) do
        case DB.query(state.db, "SELECT rev FROM harklight_feed_checkpoints WHERE handle=?1", [
               handle
             ]) do
          {:ok, [[rev]]} -> {:ok, state.db, rev}
          {:ok, []} -> {:ok, state.db, nil}
          _ -> {:error, "capture_unavailable"}
        end
      else
        {:error, "listener_fenced"}
      end

    {:reply, result, state}
  end

  def handle_call({:feed_capture, handle, rev, frames, mode}, from, state) do
    result =
      if valid_worker?(state, handle, from),
        do: capture_feed(state.db, handle, rev, frames, mode),
        else: {:error, "listener_fenced"}

    {:reply, result, state}
  end

  def handle_call({:start_feed, handle}, from, state) do
    if valid_worker?(state, handle, from) do
      {reply, state} = prepare_listener(state, handle)

      state = %{state | restart: MapSet.delete(state.restart, {handle, :deciding})}

      state =
        case reply do
          :skip -> %{state | stopping: MapSet.put(state.stopping, handle)}
          :defer -> %{state | restart: MapSet.put(state.restart, {handle, :deferred_read})}
          {:listen, _} -> state
        end

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

  def handle_call({:feed_ready, handle}, from, state) do
    result =
      if valid_worker?(state, handle, from) do
        # The worker retries this local write without blocking the manager.
        case DB.refusable(fn ->
               DB.query(
                 state.db,
                 "UPDATE harklight_wake_handles SET state='active',lastError=NULL,updatedAt=?2 WHERE handle=?1",
                 [handle, System.system_time(:millisecond)]
               )
             end) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, "feed_state_unavailable"}
        end
      else
        {:error, "listener_fenced"}
      end

    # Quiet conversations may reconnect without capturing another event. Only
    # consecutive failed starts consume the recovery budget.
    state =
      if result == :ok do
        state = %{
          state
          | attempts: Map.delete(state.attempts, handle),
            manual_starts: MapSet.delete(state.manual_starts, handle),
            starts_in_flight: MapSet.delete(state.starts_in_flight, handle)
        }

        case Map.get(state.retry_waiters, handle) do
          nil ->
            state

          %{started_for: started_for} ->
            complete_retry_waiter(state, handle, {:listening, started_for})
        end
      else
        state
      end

    {:reply, result, state}
  end

  def handle_call({:finished, handle, "capture_unavailable"}, from, state),
    do: defer_feed_read(handle, from, state)

  def handle_call(
        {:finished, handle, {:harklight_failure, "capture_unavailable", _, _}},
        from,
        state
      ),
      do: defer_feed_read(handle, from, state)

  def handle_call({:finished, handle, status}, from, state) do
    valid? = valid_worker?(state, handle, from)

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
      if valid? do
        state = %{state | failures: Map.put(state.failures, handle, status)}

        if status == :complete do
          complete_retry_waiter(
            state,
            handle,
            {:failed, "listener completed before feed catch-up",
             retry_waiter_started_for(state, handle)}
          )
        else
          complete_retry_waiter(
            state,
            handle,
            {:failed, retry_failure_reason(state.db, handle),
             retry_waiter_started_for(state, handle)}
          )
        end
      else
        state
      end

    {:reply, result, state}
  end

  defp defer_feed_read(handle, from, state) do
    state =
      if valid_worker?(state, handle, from),
        do: %{state | restart: MapSet.put(state.restart, {handle, :deferred_read})},
        else: state

    {:reply, :ok, state}
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

        # Suppress only an explicitly identified origin transport failure
        # while its existing finite recovery budget runs. Other failures keep
        # their immediate owner notice.
        if not completed and not transient_origin_failure?(status),
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

  defp notify_owner_after_recovery_exhaustion(db, handle, status) do
    {error, operation, diagnostic} = failure_details(status)
    now = System.system_time(:millisecond)

    case DB.transaction(db, fn txn ->
           case Txn.q(
                  txn,
                  "SELECT sessionKey,state FROM harklight_wake_handles WHERE handle=?1",
                  [
                    handle
                  ]
                ) do
             [[session_key, state]] when state in ["active", "unavailable"] ->
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

             _ ->
               :ok
           end
         end) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Logger.error("Harklight recovery notice could not be recorded for handle=#{handle}")
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

    if Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [wake_id]) == [] do
      [[current_receiver]] =
        Txn.q(
          txn,
          "SELECT COALESCE(currentReceiverSessionKey,sessionKey) FROM harklight_wake_handles WHERE handle=?1",
          [handle]
        )

      recipient =
        case Org.get_in_txn(txn, current_receiver) do
          %{state: "active"} -> current_receiver
          _ -> Supervision.ladder_target(txn, current_receiver, 1)
        end

      if recipient do
        cli_output =
          case {error, operation, diagnostic} do
            {_, operation, diagnostic}
            when operation == "listen" and is_binary(diagnostic) ->
              " #{String.upcase(operation)} failure: #{diagnostic}."

            {"origin_unavailable", _, _} ->
              " The original session is inactive or no longer belongs to the recorded host."

            {"origin_host_mismatch", _, _} ->
              " The original session belongs to another host; this host cannot resume it."

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
              "Harklight listening for session #{session_key} and handle #{handle} stopped (#{error}).#{cli_output} Replies on this thread will not reach the current receiver while it is unavailable. Pending entries remain recorded for recovery.",
            due_at: now,
            class: "blocker"
          })

        Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)
      end
    end
  end

  defp start_worker(state, handle, mode \\ :existing) do
    state = cancel_retry(state, handle)

    state =
      if mode == :retry,
        do: %{state | manual_starts: MapSet.put(state.manual_starts, handle)},
        else: state

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
            case GenServer.call(manager, {:start_feed, handle}, :infinity) do
              {:listen, vendor_id} -> state.listener.(manager, handle, vendor_id)
              stop when stop in [:skip, :defer] -> :ok
            end
          end)

        ref = Process.monitor(pid)

        %{
          state
          | workers: Map.put(state.workers, handle, pid),
            starts_in_flight: MapSet.put(state.starts_in_flight, handle),
            refs: Map.put(state.refs, ref, handle),
            restart: MapSet.put(state.restart, {handle, :deciding})
        }
      end
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
           "SELECT sessionKey,host,vendorSessionId,state FROM harklight_wake_handles WHERE handle=?1",
           [handle]
         ) do
      {:ok, [[session_key, host, saved_vendor_id, state_value]]}
      when state_value in ["active", "unavailable"] ->
        case listener_eligibility(state.db, handle, host) do
          {:ok, true} ->
            prepare_eligible_listener(state, handle, session_key, host, saved_vendor_id)

          {:ok, false} ->
            prepare_ineligible_listener(state, handle, host)

          {:error, _reason} ->
            {:defer, state}
        end

      {:error, _reason} ->
        {:defer, state}

      _ ->
        {:skip, state}
    end
  end

  defp prepare_eligible_listener(state, handle, session_key, host, saved_vendor_id) do
    vendor_identity =
      DB.read_transaction(state.db, fn txn ->
        case Org.get_in_txn(txn, session_key) do
          %{state: "active", host: ^host} ->
            case Org.current_pointer_snapshot_in_txn(txn, session_key) do
              %{harness_session_id: id} -> id
              nil -> saved_vendor_id
            end

          _ ->
            saved_vendor_id
        end
      end)

    with {:ok, vendor_id} <- vendor_identity,
         :ok <- store_vendor_identity(state.db, handle, vendor_id, saved_vendor_id) do
      {{:listen, vendor_id}, %{state | failures: Map.delete(state.failures, handle)}}
    else
      {:error, _reason} -> {:defer, state}
    end
  end

  defp store_vendor_identity(_db, _handle, id, id), do: :ok

  defp store_vendor_identity(db, handle, vendor_id, _saved_vendor_id) do
    with {:ok, _} <-
           DB.query(
             db,
             "UPDATE harklight_wake_handles SET vendorSessionId=?2,updatedAt=?3 WHERE handle=?1",
             [handle, vendor_id, System.system_time(:millisecond)]
           ) do
      :ok
    end
  end

  defp prepare_ineligible_listener(state, handle, host) do
    local = host == Placement.local_host_name()
    reason = if local, do: "origin_unavailable", else: "origin_host_mismatch"

    case mark_finished(state.db, handle, reason) do
      :ok -> {:skip, if(local, do: start_gone(state, handle), else: state)}
      {:error, _reason} -> {:defer, state}
    end
  end

  defp run_listener(manager, handle, state_delays) do
    Process.flag(:trap_exit, true)

    with executable when is_binary(executable) <- System.find_executable("harklight-agent"),
         {:ok, db, cursor} <- GenServer.call(manager, {:feed_start, handle}, :infinity) do
      follow(manager, db, executable, handle, cursor, state_delays)
    else
      nil -> finish(manager, handle, "cli_missing")
      {:error, reason} -> finish(manager, handle, reason)
    end
  rescue
    _ -> finish(manager, handle, "listener_failed")
  end

  defp record_feed_ready(manager, handle, delays) do
    case GenServer.call(manager, {:feed_ready, handle}, :infinity) do
      {:error, "feed_state_unavailable"} ->
        [delay | rest] = delays

        Logger.warning(
          "Harklight listener state write failed handle=#{handle}; feed kept, retrying in #{delay}ms"
        )

        receive do
          {:EXIT, ^manager, exit_reason} -> exit(exit_reason)
          {:EXIT, _sender, :shutdown} -> exit(:shutdown)
        after
          delay -> record_feed_ready(manager, handle, if(rest == [], do: delays, else: rest))
        end

      result ->
        result
    end
  end

  # Keep feed diagnostics separate from captured content and include the observed
  # exit status whenever the wrapper reports one.
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

  defp follow(manager, db, executable, handle, cursor, state_delays) do
    resume = if is_nil(cursor), do: ["--snapshot"], else: ["--after", to_string(cursor)]
    args = ["listen", "--follow", "--session", handle | resume]

    case GenServer.call(manager, {:launch_child, handle, executable, args}, :infinity) do
      {:ok, port, initial} ->
        try do
          case GenServer.call(manager, {:listener_port, handle, port}, :infinity) do
            :ok ->
              true = Port.command(port, "continue
")

              feed = %{
                db: db,
                executable: executable,
                baseline: nil,
                ready: false,
                state_delays: state_delays
              }

              receive_lines(manager, port, handle, initial, [], feed)

            {:error, reason} ->
              finish(manager, handle, reason)
          end
        after
          close_listener_port(port)
        end

      {:error, reason} ->
        finish(manager, handle, failure_status("listener_failed", "listen", inspect(reason)))
    end
  end

  # The wrapper observes input EOF, terminates and reaps its CLI child. Closing
  # this port requests cleanup.
  defp close_listener_port(port) do
    Tightbeam.HarklightChild.request_stop(port)
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp receive_lines(manager, port, handle, pending, diagnostics, feed) do
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
          |> Enum.reduce_while({:ok, diagnostics, feed}, fn line,
                                                            {:ok, current_diagnostics, feed} ->
            case receive_listener_line(manager, handle, line, current_diagnostics, feed) do
              {:ok, next_diagnostics, next_feed} ->
                {:cont, {:ok, next_diagnostics, next_feed}}

              {:error, reason, next_diagnostics} ->
                {:halt, {:error, reason, next_diagnostics}}
            end
          end)

        case result do
          {:ok, next_diagnostics, feed} ->
            receive_lines(manager, port, handle, remainder, next_diagnostics, feed)

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
          if pending == "" and is_nil(feed.baseline),
            do:
              failure_status(
                "listener_stopped",
                "listen",
                listen_attempt_diagnostics("LISTEN attempt", 0, diagnostics)
              ),
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
            listener_exit_reason(exit_status, diagnostics),
            "listen",
            listen_attempt_diagnostics("LISTEN attempt", exit_status, diagnostics)
          )
        )
    end
  end

  # The Agent emits JSON events on stdout and reconnect/refusal messages on
  # stderr. The port merges them; keep plain-text diagnostics without treating
  # them as events, and leave every JSON line on the existing capture path.
  defp receive_listener_line(manager, handle, line, diagnostics, feed) do
    decoded =
      try do
        JSON.decode(line)
      rescue
        _ -> {:error, :invalid_listener_line}
      end

    case decoded do
      {:ok, event} ->
        case apply_listener_frame(manager, handle, event, feed) do
          {:ok, next_feed} -> {:ok, diagnostics, next_feed}
          {:error, reason} -> {:error, reason, diagnostics}
        end

      {:error, _} ->
        diagnostic_line = String.replace_invalid(line)

        if structured_output_line?(diagnostic_line) do
          {:error, "invalid_listener_line", diagnostics}
        else
          {:ok, append_diagnostic(diagnostics, diagnostic_line), feed}
        end
    end
  end

  defp apply_listener_frame(_manager, _handle, %{"kind" => "focus"}, feed), do: {:ok, feed}

  defp apply_listener_frame(
         _manager,
         _handle,
         %{"kind" => "baseline", "rev" => rev},
         %{baseline: nil} = feed
       )
       when is_integer(rev) and rev >= 0,
       do: {:ok, %{feed | baseline: {rev, []}}}

  defp apply_listener_frame(
         manager,
         handle,
         %{"kind" => "baseline_complete", "rev" => rev},
         %{baseline: {rev, frames}} = feed
       ) do
    with :ok <- submit_feed(manager, handle, rev, Enum.reverse(frames), :baseline, feed) do
      {:ok, %{feed | baseline: nil}}
    end
  end

  defp apply_listener_frame(
         manager,
         handle,
         %{"kind" => "caught_up", "rev" => rev},
         %{baseline: nil} = feed
       )
       when is_integer(rev) and rev >= 0 do
    with :ok <- submit_feed(manager, handle, rev, [], :live, feed) do
      mark_feed_ready(manager, handle, feed)
    end
  end

  defp apply_listener_frame(
         manager,
         handle,
         %{"kind" => kind, "rev" => rev, "data" => data} = frame,
         feed
       )
       when kind in ["message", "entry", "advisory"] and is_integer(rev) and rev > 0 and
              is_map(data) do
    case feed.baseline do
      {position, frames} ->
        {:ok, %{feed | baseline: {position, [frame | frames]}}}

      nil ->
        with :ok <- submit_feed(manager, handle, rev, [frame], :live, feed) do
          {:ok, feed}
        end
    end
  end

  defp apply_listener_frame(_manager, _handle, _frame, _feed),
    do: {:error, "unexpected_feed_record"}

  defp mark_feed_ready(_manager, _handle, %{ready: true} = feed), do: {:ok, feed}

  defp mark_feed_ready(manager, handle, feed) do
    with :ok <- record_feed_ready(manager, handle, feed.state_delays),
         do: {:ok, %{feed | ready: true}}
  end

  defp submit_feed(manager, handle, rev, frames, mode, feed) do
    with {:ok, frames} <- feed_entry_items(feed, handle, frames) do
      GenServer.call(manager, {:feed_capture, handle, rev, frames, mode}, :infinity)
    end
  end

  defp feed_entry_items(feed, handle, frames) do
    messages =
      Map.new(
        for %{"kind" => "message", "data" => %{"item_id" => id} = data} <- frames, do: {id, data}
      )

    Enum.reduce_while(frames, {:ok, []}, fn frame, {:ok, acc} ->
      case feed_entry_item(feed, handle, frame, messages) do
        {:ok, enriched} -> {:cont, {:ok, [enriched | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, frames} -> {:ok, Enum.reverse(frames)}
      error -> error
    end
  end

  defp feed_entry_item(
         feed,
         handle,
         %{
           "kind" => "entry",
           "data" => %{"kind" => "reply", "author" => "person", "item_id" => id}
         } = frame,
         messages
       )
       when is_binary(id) do
    case DB.query(
           feed.db,
           "SELECT 1 FROM harklight_wake_requests WHERE handle=?1 AND messageId=?2",
           [handle, id]
         ) do
      {:ok, [[1]]} ->
        {:ok, frame}

      {:ok, []} ->
        with {:ok, item} <- feed_message(feed.executable, messages, id) do
          {:ok, Map.put(frame, "item", item)}
        end

      _ ->
        {:error, "capture_unavailable"}
    end
  end

  defp feed_entry_item(_feed, _handle, frame, _messages), do: {:ok, frame}

  defp feed_message(executable, messages, id) do
    case Map.fetch(messages, id) do
      {:ok, item} ->
        {:ok, item}

      :error ->
        with {output, 0} <- System.cmd(executable, ["message-get", "--item-id", id]),
             {:ok, %{"message" => %{"item_id" => ^id} = item}} <- JSON.decode(output) do
          {:ok, item}
        else
          _ -> {:error, "harklight_message_lookup_failed"}
        end
    end
  rescue
    _ -> {:error, "harklight_message_lookup_failed"}
  end

  # The feed writes only stream records to stdout. The Agent's refusals are
  # reported via exit status and stderr, without a write-operation JSON frame.
  defp listener_exit_reason(2, _diagnostics), do: {"listener_stopped", "feed_refused"}
  defp listener_exit_reason(5, _diagnostics), do: {"listener_stopped", "unsupported_version"}

  defp listener_exit_reason(1, diagnostics) do
    diagnostic = Enum.join(diagnostics, "\n")

    cond do
      String.contains?(diagnostic, [
        "invalid agent change or cursor",
        "invalid agent snapshot",
        "server sent an unexpected response"
      ]) ->
        {"listener_stopped", "invalid_response"}

      Regex.match?(
        ~r/server request via configured address .* failed:|could not read HTTP [0-9]+ response/,
        diagnostic
      ) ->
        {"listener_stopped", "transport_error"}

      true ->
        "listener_stopped"
    end
  end

  defp listener_exit_reason(_status, _diagnostics), do: "listener_stopped"

  defp failure_status(error, operation, diagnostic),
    do: {:harklight_failure, error, operation, diagnostic}

  defp failure_details({:harklight_failure, {error, code}, operation, diagnostics}),
    do:
      {error, operation,
       format_failure_diagnostics(["reason_code=" <> code | List.wrap(diagnostics)])}

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

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp finish(manager, handle, status),
    do: GenServer.call(manager, {:finished, handle, status}, :infinity)

  @doc false
  @doc false
  def capture_feed(db, handle, rev, frames, mode)
      when is_integer(rev) and rev >= 0 and mode in [:baseline, :live] do
    case DB.transaction(db, fn txn ->
           [[session, host, handle_state]] =
             Txn.q(
               txn,
               "SELECT sessionKey,host,state FROM harklight_wake_handles WHERE handle=?1",
               [handle]
             )

           unless handle_state in ["active", "unavailable"] and
                    listener_eligible_in_txn?(txn, handle, session, host) do
             raise "harklight_origin_unavailable"
           end

           if handle_state == "unavailable" do
             Txn.q(
               txn,
               "UPDATE harklight_wake_handles SET state='active',lastError=NULL WHERE handle=?1",
               [handle]
             )
           end

           previous =
             case Txn.q(txn, "SELECT rev FROM harklight_feed_checkpoints WHERE handle=?1", [
                    handle
                  ]) do
               [[position]] -> position
               [] -> -1
             end

           if mode == :baseline or rev > previous do
             ordered = if mode == :baseline, do: Enum.sort_by(frames, & &1["rev"]), else: frames

             Enum.each(ordered, fn frame ->
               case capture_change_in_txn(txn, handle, frame) do
                 :ok -> :ok
                 {:error, reason} -> raise reason
               end
             end)

             Txn.q(
               txn,
               """
               INSERT INTO harklight_feed_checkpoints(handle,rev) VALUES(?1,?2)
               ON CONFLICT(handle) DO UPDATE SET rev=excluded.rev
               """,
               [handle, rev]
             )
           end

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, %RuntimeError{message: reason}} -> {:error, reason}
      {:error, _} -> {:error, "capture_unavailable"}
    end
  end

  defp capture_change_in_txn(
         txn,
         handle,
         %{
           "kind" => "entry",
           "data" =>
             %{
               "author" => "person",
               "kind" => "reply",
               "entry_id" => entry_id,
               "item_id" => item_id,
               "request_revision" => request_revision
             } = entry
         } = frame
       )
       when is_binary(item_id) and is_binary(entry_id) and is_integer(request_revision) and
              request_revision > 0 do
    capture_consumer_event(
      txn,
      handle,
      item_id,
      frame["item"],
      frame,
      ["entry", entry_id],
      request_revision,
      Map.put(entry, "kind", "discussion")
    )
  end

  defp capture_change_in_txn(
         txn,
         handle,
         %{
           "kind" => "message",
           "data" =>
             %{
               "session" => handle,
               "item_id" => item_id,
               "revision" => revision,
               "terminal" => %{"state" => state, "at_ms" => timestamp} = terminal
             } = item
         } = frame
       )
       when is_binary(item_id) and is_integer(revision) and revision > 0 and is_integer(timestamp) and
              state in ["answered", "cleared", "expired", "superseded"] do
    author = if state == "answered", do: "person", else: "server"

    entry =
      Map.merge(terminal, %{
        "kind" => "terminal",
        "terminal_state" => state,
        "author" => author
      })

    capture_consumer_event(
      txn,
      handle,
      item_id,
      item,
      frame,
      ["terminal", item_id, state, timestamp],
      revision,
      entry
    )
  end

  defp capture_change_in_txn(_txn, _handle, %{
         "kind" => "entry",
         "data" => %{"kind" => "reply", "author" => "person"}
       }),
       do: {:error, "event_identity_invalid"}

  defp capture_change_in_txn(_txn, _handle, %{"kind" => kind, "data" => data})
       when kind in ["entry", "message", "advisory"] and is_map(data), do: :ok

  defp capture_change_in_txn(_txn, _handle, _frame), do: {:error, "unexpected_feed_record"}

  defp capture_consumer_event(txn, handle, item_id, item, frame, identity, revision, entry) do
    case registered_item(txn, handle, item_id, item) do
      {:ok, sender, local_id} ->
        event_id =
          "v2_" <> (:crypto.hash(:sha256, JSON.encode!(identity)) |> Base.encode16(case: :lower))

        case Txn.q(
               txn,
               """
               SELECT 1 FROM harklight_wake_entries WHERE handle=?1 AND eventId=?2
               UNION ALL SELECT 1 FROM harklight_wake_suppressed_entries WHERE handle=?1 AND eventId=?2
               UNION ALL SELECT 1 FROM harklight_held_terminals WHERE handle=?1 AND eventId=?2
               """,
               [handle, event_id]
             ) do
          [] ->
            [[previous]] =
              Txn.q(txn, "SELECT lastCursor FROM harklight_wake_handles WHERE handle=?1", [handle])

            cursor = previous + 1

            line =
              JSON.encode!(%{
                "kind" => frame["kind"],
                "rev" => frame["rev"],
                "data" => frame["data"],
                "item_id" => item_id,
                "session_handle" => handle,
                "event_id" => event_id,
                "feed_cursor" => cursor,
                "request_revision" => revision,
                "request" => %{"sender_id" => sender, "message_id" => local_id},
                "entry" => entry
              })

            capture_event_in_txn(
              txn,
              handle,
              line,
              event_id,
              cursor,
              sender,
              local_id,
              revision,
              entry["kind"],
              entry["author"]
            )

          _ ->
            :ok
        end

      :unregistered ->
        case Txn.q(
               txn,
               """
               SELECT 1 FROM harklight_send_operations s
               LEFT JOIN harklight_command_results r ON r.opId=s.opId
               WHERE s.state='pending' AND s.attemptedAt IS NOT NULL AND r.opId IS NULL
                 AND json_extract(s.payload,'$.request.session_handle')=?1
                 AND json_extract(s.payload,'$.request.protocol')=2 LIMIT 1
               """,
               [handle]
             ) do
          [] -> :ok
          _ -> {:error, "harklight_send_pending"}
        end
    end
  end

  defp registered_item(txn, handle, item_id, item) do
    case Txn.q(
           txn,
           "SELECT senderId FROM harklight_wake_requests WHERE handle=?1 AND messageId=?2",
           [handle, item_id]
         ) do
      [[sender]] -> {:ok, sender, item_id}
      [] -> registered_migrated_item(txn, handle, item_id, item)
    end
  end

  defp registered_migrated_item(txn, handle, item_id, %{
         "item_id" => item_id,
         "legacy_message_id" => legacy,
         "sender" => sender,
         "session" => handle
       })
       when is_binary(legacy) and is_binary(sender) do
    case Txn.q(
           txn,
           "SELECT 1 FROM harklight_wake_requests WHERE handle=?1 AND senderId=?2 AND messageId=?3",
           [handle, sender, legacy]
         ) do
      [[1]] -> {:ok, sender, legacy}
      [] -> :unregistered
    end
  end

  defp registered_migrated_item(_txn, _handle, _item_id, _item), do: :unregistered

  # Replays a previously stored event without translating its durable identity.
  # Only capture_feed/5 accepts records from a running Agent.
  def capture_line(db, handle, line) do
    with {:ok, event} <- JSON.decode(line),
         true <- is_map(event) do
      case event do
        %{"kind" => "event"} ->
          capture_event(db, handle, line, event)

        %{"kind" => "message", "item_id" => item_id} when is_binary(item_id) ->
          capture_event(db, handle, line, event)

        _ ->
          {:error, "unexpected_feed_record"}
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
         not is_integer(cursor) or cursor < 1 or
         (event["kind"] == "event" and event_id != Integer.to_string(cursor)) or
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
    do: entry["terminal_state"] in ["cleared", "expired", "superseded"]

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

      prompt =
        entry_prompt(
          txn,
          session_key,
          line,
          handle,
          event_id,
          sender_id,
          message_id,
          kind,
          author
        )

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
        [[current_receiver]] =
          Txn.q(
            txn,
            "SELECT COALESCE(currentReceiverSessionKey,sessionKey) FROM harklight_wake_handles WHERE handle=?1",
            [handle]
          )

        primary = if current_receiver in recipients, do: current_receiver, else: hd(recipients)

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

  defp delivery_recipients_in_txn(txn, handle, _owner_session, sender_id, message_id, kind, line) do
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

    [[current_receiver]] =
      Txn.q(
        txn,
        "SELECT COALESCE(currentReceiverSessionKey,sessionKey) FROM harklight_wake_handles WHERE handle=?1",
        [handle]
      )

    own_recipients = if owner_open, do: [current_receiver], else: []

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
    |> Enum.filter(fn recipient ->
      case Org.get_in_txn(txn, recipient) do
        %{state: "active", host: host} ->
          Txn.q(txn, "SELECT 1 FROM harklight_wake_handles WHERE handle=?1 AND host=?2", [
            handle,
            host
          ]) != []

        _ ->
          false
      end
    end)
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

  defp entry_prompt(txn, origin, line, handle, _event, sender, message, _kind, _author) do
    instruction = handling_instruction(JSON.decode!(line))

    instruction =
      case Org.get_in_txn(txn, origin) do
        %{state: "retired", display_name: name} ->
          String.replace(
            instruction,
            "Handle this Harklight entry from your originating session.",
            "This Harklight entry was addressed to #{name} (#{origin}), who has retired. Handle it as the conversation's agent in their place.",
            global: false
          )

        _ ->
          instruction
      end

    line <>
      "\n\n" <>
      instruction <>
      Tightbeam.HarklightBriefings.chat_prompt_context_in_txn(txn, handle, sender, message)
  end

  defp handling_instruction(%{
         "kind" => "entry",
         "item_id" => item,
         "data" => %{"entry_id" => entry}
       }) do
    "Handle this Harklight entry from your originating session. " <>
      "For a chat reply, run harklight-agent reply --item-id #{item} --in-reply-to #{entry} --body <reply>. " <>
      "Report actual attachment transfer or use with harklight-agent file-use --item-id #{item} --entry-id #{entry} --file-id <file> and the applicable outcome."
  end

  defp handling_instruction(%{
         "kind" => "message",
         "item_id" => item,
         "data" => %{"terminal" => %{"state" => "answered"}}
       }) do
    "Handle this Harklight entry from your originating session. " <>
      "Reconcile any earlier effect before applying the answer once. " <>
      "Report its disposition with harklight-agent result --item-id #{item} --status applied|refused|received."
  end

  defp handling_instruction(_) do
    "Handle this Harklight entry from your originating session. " <>
      "Cleared, expired or superseded requests are closed. Check the recorded outcome before acting."
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
