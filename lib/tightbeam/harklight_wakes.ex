defmodule Tightbeam.HarklightWakes do
  @moduledoc """
  Routes filtered Harklight changes to durable Tightbeam wakes. Tightbeam
  checkpoints its own capture independently of the Agent CLI's journal.
  """

  use GenServer
  require Logger

  alias Tightbeam.{
    DB,
    ErrorDiagnostic,
    HarklightFailures,
    HarklightLifecycle,
    Org,
    Placement,
    Supervision,
    Wakes
  }

  alias Tightbeam.DB.Txn
  alias Tightbeam.HarklightFeedCustody, as: FeedCustody
  alias Tightbeam.HarklightListenerOutage, as: Outage

  @feed_state_retry_delays [250, 500, 1_000, 2_000, 5_000, 10_000, 30_000]
  @feed_read_retry_delay 250
  @retry_delays [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 64_000, 128_000, 300_000]

  # A feed that stays up this long after catching up has recovered. Focus
  # records need a separate grant, so a quiet feed may never confirm itself.
  @feed_steady_delay 60_000

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
  CREATE TABLE IF NOT EXISTS harklight_pending_opens (
    handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
    rev INTEGER,
    token TEXT,
    resumed INTEGER NOT NULL DEFAULT 0,
    stopped INTEGER NOT NULL DEFAULT 0,
    expired INTEGER,
    CHECK ((rev IS NULL) = (token IS NULL))
  );
  CREATE TABLE IF NOT EXISTS harklight_feed_launches (
    handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
    owner TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS harklight_feed_stops (
    handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle)
  );
  CREATE TABLE IF NOT EXISTS harklight_feed_pauses (
    handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
    diagnostic TEXT NOT NULL
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

  # A conversation with messages from before protocol 2 that has never been
  # opened under it. Its first read is never a snapshot.
  @earlier_unopened_sql """
  (NOT EXISTS(SELECT 1 FROM harklight_feed_checkpoints c WHERE c.handle=h.handle)
   AND (h.lastCursor>0
     OR NOT EXISTS(SELECT 1 FROM harklight_wake_requests r WHERE r.handle=h.handle)
     OR EXISTS(
       SELECT 1 FROM harklight_wake_requests r
       LEFT JOIN harklight_send_operations o
         ON o.senderId=r.senderId AND o.messageId=r.messageId AND o.state='bound'
       WHERE r.handle=h.handle AND COALESCE(
         CASE WHEN json_valid(o.payload) THEN json_extract(o.payload,'$.request.protocol') END,0)<>2)))
  """

  # A migration rule, not a stop: such a conversation opens only by explicit
  # retry. Once chosen, its open continues by itself. Set this to "0" to drop
  # the rule.
  @first_open_held_sql """
  (#{@earlier_unopened_sql}
   AND NOT EXISTS(SELECT 1 FROM harklight_pending_opens o WHERE o.handle=h.handle))
  """

  @first_open_pending "harklight_first_open_pending"
  @pending_stopped "harklight_pending_open_stopped"

  # Why a conversation is not opened by itself. Other recorded stops and pauses
  # recover.
  @choice_sql """
  CASE
    WHEN EXISTS(SELECT 1 FROM harklight_pending_opens o WHERE o.handle=h.handle AND o.stopped=1)
      THEN '#{@pending_stopped}'
    WHEN #{@first_open_held_sql} THEN '#{@first_open_pending}'
  END
  """

  @hold_sql """
  COALESCE(#{@choice_sql}, CASE
    WHEN (s.handle IS NOT NULL OR p.handle IS NOT NULL) AND (
      h.lastError LIKE '%reason_code=identity_revoked%'
      OR h.lastError LIKE '%agent feed closed: revoked%') THEN 'harklight_feed_stopped'
  END)
  """

  @uuid4 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def ensure_schema(db \\ DB) do
    with :ok <- DB.execute(db, @ddl),
         :ok <- Outage.ensure_schema(db),
         :ok <- HarklightFailures.ensure_schema(db),
         :ok <- HarklightLifecycle.ensure_schema(db),
         :ok <- Tightbeam.HarklightReceipts.ensure_schema(db),
         :ok <- Tightbeam.HarklightBriefings.ensure_schema(db),
         :ok <- Tightbeam.HarklightBounces.ensure_schema(db) do
      backfill_pending_supersedes(db)
    end
  end

  def start_link(opts) do
    opts = Keyword.merge(Application.get_env(:tightbeam, :harklight_recovery_options, []), opts)
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

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
      """
      SELECT s.opId,s.sessionKey,s.payload FROM harklight_send_operations s
      WHERE s.state='pending' AND s.attemptedAt IS NOT NULL
        AND COALESCE(json_extract(s.payload,'$.operation_kind'),'send') NOT IN ('change','action')
        AND NOT EXISTS (SELECT 1 FROM harklight_command_results r WHERE r.opId=s.opId)
        AND NOT EXISTS (SELECT 1 FROM harklight_operation_pauses p WHERE p.opId=s.opId)
        AND NOT EXISTS (SELECT 1 FROM harklight_operation_guards g WHERE g.opId=s.opId)
      ORDER BY s.attemptedAt,s.opId
      """
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

        {:error, code} when code in [@first_open_pending, @pending_stopped] ->
          %{
            command: "listener-restore",
            code: code,
            outcome: "refused",
            handle: handle,
            reason: choice_reason(code, "active")
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
  # Conversations that wait for a choice are left out; that choice is made with a
  # handle or message.
  defp retry_targets(db, :all) do
    case DB.query(
           db,
           """
           SELECT h.handle,h.sessionKey,h.state,COALESCE(p.diagnostic,h.lastError)
           FROM harklight_wake_handles h LEFT JOIN harklight_feed_pauses p ON p.handle=h.handle
           WHERE h.state IN ('active','unavailable') AND (#{@choice_sql}) IS NULL
           ORDER BY h.createdAt,h.handle
           """
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
           """
           SELECT h.handle,h.sessionKey,h.state,COALESCE(p.diagnostic,h.lastError)
           FROM harklight_wake_handles h LEFT JOIN harklight_feed_pauses p ON p.handle=h.handle
           WHERE h.handle=?1
           """,
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
             "SELECT payload FROM harklight_send_operations WHERE sessionKey=?1 AND state='pending' AND COALESCE(json_extract(payload,'$.operation_kind'),'send') NOT IN ('change','action') ORDER BY opId",
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

    child_opts =
      Keyword.get(opts, :child_opts, Application.get_env(:tightbeam, :harklight_child_opts, []))

    custody_dir =
      Keyword.get_lazy(opts, :feed_custody_dir, fn ->
        child_opts
        |> Keyword.get_lazy(:base_dir, &Tightbeam.BaseDir.resolve/0)
        |> Path.join("harklight-feed-custody")
      end)

    {:ok,
     %{
       db: Keyword.get(opts, :db, DB),
       child_opts: child_opts,
       custody_dir: custody_dir,
       launch_owners: %{},
       listener:
         Keyword.get(opts, :listener, fn manager, handle, _vendor_id ->
           run_listener(manager, handle, state_delays)
         end),
       send_runner: Keyword.get(opts, :send_runner),
       workers: %{},
       ports: %{},
       refs: %{},
       failures: %{},
       pending_failures: %{},
       attempts: %{},
       retry_waiters: %{},
       starts_in_flight: MapSet.new(),
       manual_starts: MapSet.new(),
       retry_timers: %{},
       outage_timers: %{},
       outage_notice_delay: Keyword.get(opts, :outage_notice_delay_ms, 600_000),
       wall_now: Keyword.get(opts, :wall_now, fn -> System.system_time(:millisecond) end),
       gone_tasks: %{},
       deferred: MapSet.new(),
       retry_delays: Keyword.get(opts, :retry_delays, @retry_delays),
       sustain_retries: Keyword.get(opts, :sustain_retries, true),
       retry_jitter: Keyword.get(opts, :retry_jitter, true),
       admission_queue: [],
       admission_timer: nil,
       admission_next: nil,
       admission_spacing: Keyword.get(opts, :feed_start_spacing_ms, 250),
       launching: MapSet.new(),
       feed_steady_delay: Keyword.get(opts, :feed_steady_delay_ms, @feed_steady_delay),
       transport_failures: %{},
       cooldown_until: nil,
       cooldown_level: 0,
       cooldown_threshold: Keyword.get(opts, :feed_cooldown_threshold, 4),
       cooldown_window: Keyword.get(opts, :feed_cooldown_window_ms, 600_000),
       cooldown_base: Keyword.get(opts, :feed_cooldown_base_ms, 30_000),
       cooldown_max: Keyword.get(opts, :feed_cooldown_max_ms, 300_000),
       restart: MapSet.new(),
       stopping: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:restore, state) do
    with {:ok, rows} <-
           DB.query(
             state.db,
             """
             SELECT h.handle,#{@hold_sql} AS hold,
               s.handle IS NOT NULL OR p.handle IS NOT NULL
             FROM harklight_wake_handles h
             LEFT JOIN harklight_feed_stops s ON s.handle=h.handle
             LEFT JOIN harklight_feed_pauses p ON p.handle=h.handle
             WHERE h.state IN ('active','unavailable')
             ORDER BY hold IS NOT NULL,h.createdAt,h.handle
             """
           ),
         {:ok, outages} <- Outage.pending(state.db) do
      # Nothing recovers a held conversation, so its outage is not announced.
      held = for [handle, hold, _] when is_binary(hold) <- rows, into: MapSet.new(), do: handle

      state =
        outages
        |> Enum.reject(&MapSet.member?(held, hd(&1)))
        |> Enum.reduce(state, &arm_outage(&2, &1))

      state =
        Enum.reduce(rows, state, fn [handle, hold, recorded], acc ->
          mode = if hold && recorded == 1, do: :fenced, else: :startup
          start_worker(acc, handle, mode)
        end)

      Task.start(fn ->
        Tightbeam.HarklightSend.recover_pending(state.db, runner: state.send_runner)
        HarklightLifecycle.process_terminals(state.db, runner: state.send_runner)
      end)

      {:noreply, state}
    else
      {:error, _} ->
        Process.send_after(self(), :restore, @feed_read_retry_delay)
        {:noreply, state}
    end
  end

  def handle_info({:outage_notice, handle, episode, token}, state) do
    case Map.get(state.outage_timers, handle) do
      {_, ^token} ->
        state = cancel_outage_timer(state, handle)
        now = state.wall_now.()
        delay = state.outage_notice_delay

        case Outage.notify(state.db, handle, episode, now, delay) do
          {:ok, {:early, row}} ->
            {:noreply, arm_outage(state, row)}

          {:ok, _} ->
            {:noreply, state}

          {:error, _} ->
            {:noreply, arm_outage(state, [handle, episode, now - delay + 1_000, nil])}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:admit_feed, token}, %{admission_timer: {_, token}} = state),
    do: {:noreply, admit_feed(%{state | admission_timer: nil})}

  def handle_info({:admit_feed, _stale}, state), do: {:noreply, state}

  def handle_info({:feed_steady, handle, pid}, state) do
    if state.workers[handle] == pid and not Map.has_key?(state.failures, handle) and
         not MapSet.member?(state.stopping, handle) and not MapSet.member?(state.restart, handle) do
      case DB.refusable(fn -> Outage.finish(state.db, handle, true, state.wall_now.()) end) do
        {:ok, _} ->
          {:noreply, confirm_feed_recovery(state, handle)}

        {:error, _} ->
          arm_feed_steady(state, handle, pid)
          {:noreply, state}
      end
    else
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
        {:noreply, state} = worker_down(state, ref)
        {:noreply, admit_feed(state)}
    end
  end

  def handle_info({:retry_listener, handle, token, action}, state) do
    case Map.get(state.retry_timers, handle) do
      {_, ^token} ->
        state = %{state | retry_timers: Map.delete(state.retry_timers, handle)}

        case action do
          :recover ->
            {:noreply, recover_worker(state, handle)}

          mode ->
            state = persist_feed_failure(state, handle)

            if Map.has_key?(state.pending_failures, handle),
              do:
                {:noreply, schedule_listener_retry(state, handle, @feed_read_retry_delay, mode)},
              else: {:noreply, start_worker(state, handle, mode)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:reconcile_origin, session_key}, state),
    do: {:noreply, reconcile_origin(state, session_key)}

  def handle_info({:reconcile_retirement, handles, gone_handles}, state),
    do: {:noreply, reconcile_retirement(state, handles, MapSet.new(gone_handles))}

  def handle_info({:feed_drain_timeout, handle, token}, state) do
    if state.launch_owners[handle] == token do
      if port = state.ports[handle], do: close_listener_port(port)
      Process.exit(state.workers[handle], :kill)
    end

    {:noreply, state}
  end

  def handle_info({:feed_result, pid, token, result}, state) do
    case Enum.find(state.workers, fn {_handle, worker} -> worker == pid end) do
      {handle, ^pid} when is_map_key(state.launch_owners, handle) ->
        if state.launch_owners[handle] == token,
          do: {:noreply, apply_feed_result(state, handle, token, result)},
          else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # DOWN owns worker bookkeeping. Linked exits also shut down the worker
  # when its manager crashes.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp worker_down(state, ref) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {handle, refs} ->
        deferred_read = MapSet.member?(state.restart, {handle, :deferred_read})
        launched? = Map.has_key?(state.launch_owners, handle)

        state = %{
          state
          | refs: refs,
            workers: Map.delete(state.workers, handle),
            launching: MapSet.delete(state.launching, handle),
            starts_in_flight: MapSet.delete(state.starts_in_flight, handle),
            ports: Map.delete(state.ports, handle),
            launch_owners: Map.delete(state.launch_owners, handle),
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

            if Map.has_key?(state.pending_failures, handle),
              do:
                {:noreply,
                 schedule_listener_retry(state, handle, @feed_read_retry_delay, :recover)},
              else: {:noreply, state}

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
            state =
              if Map.has_key?(state.failures, handle),
                do: state,
                else: observe_feed_failure(state, handle, "listener_terminated", not launched?)

            if MapSet.member?(state.manual_starts, handle) do
              state =
                complete_retry_waiter(
                  state,
                  handle,
                  {:failed, retry_failure_reason(state.db, handle),
                   retry_waiter_started_for(state, handle)}
                )

              state = %{state | manual_starts: MapSet.delete(state.manual_starts, handle)}
              {:noreply, recover_worker(state, handle)}
            else
              {:noreply, recover_worker(state, handle)}
            end
        end
    end
  end

  # Restart only after the preceding worker has exited.
  defp recover_worker(state, handle) do
    status = Map.get(state.failures, handle, "listener_terminated")

    state = persist_feed_failure(state, handle)

    cond do
      Map.has_key?(state.pending_failures, handle) ->
        schedule_listener_retry(state, handle, @feed_read_retry_delay, :recover)

      retryable_failure?(status) ->
        recover_worker(state, handle, status)

      true ->
        state
    end
  end

  defp recover_worker(state, handle, status) do
    case DB.query(
           state.db,
           "SELECT sessionKey,host,state FROM harklight_wake_handles WHERE handle=?1",
           [handle]
         ) do
      {:ok, [[_session_key, host, handle_state]]} when handle_state != "complete" ->
        attempt = Map.get(state.attempts, handle, 0)
        fallback = if state.sustain_retries, do: List.last(state.retry_delays)

        delay =
          if refused_identity?(status) or no_pending_route?(status),
            do: List.last(state.retry_delays),
            else: Enum.at(state.retry_delays, attempt, fallback)

        case listener_eligibility(state.db, handle, host) do
          {:ok, eligible} ->
            if eligible and is_integer(delay) and retryable_failure?(status) do
              next_attempt = min(attempt + 1, length(state.retry_delays))
              state = %{state | attempts: Map.put(state.attempts, handle, next_attempt)}
              schedule_listener_retry(state, handle, jitter(delay, state.retry_jitter), :existing)
            else
              case finish_recovery(state.db, handle, status) do
                {:ok, _} ->
                  cancel_outage_timer(state, handle)

                {:error, _} ->
                  schedule_listener_retry(state, handle, @feed_read_retry_delay, :recover)
              end
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

  defp observe_feed_failure(state, handle, status, ended? \\ false) do
    state = observe_transport_failure(state, handle, status)
    previous = Map.get(state.pending_failures, handle)

    evidence =
      case previous do
        {^status, at, ended_before?} ->
          {status, at, ended_before? or ended?}

        {earlier, at, ended_before?} ->
          if retryable_failure?(status) and not reported_failure?(status),
            do: {earlier, at, ended_before? or ended?},
            else: {status, state.wall_now.(), ended?}

        nil ->
          {status, state.wall_now.(), ended?}
      end

    if evidence != previous, do: FeedCustody.remember(state.custody_dir, handle, evidence)

    state = %{
      state
      | failures: Map.put(state.failures, handle, status),
        pending_failures: Map.put(state.pending_failures, handle, evidence)
    }

    persist_feed_failure(state, handle)
  end

  defp observe_transport_failure(state, handle, {:harklight_failure, {_error, code}, "listen", _})
       when code in ["transport_error", "timeout"] do
    now = System.monotonic_time(:millisecond)

    failures =
      state.transport_failures
      |> Map.filter(fn {_handle, at} -> now - at < state.cooldown_window end)
      |> Map.put(handle, now)

    state = %{state | transport_failures: failures}

    if state.cooldown_level > 0 or map_size(failures) >= state.cooldown_threshold do
      level = min(state.cooldown_level + 1, 10)
      ceiling = min(state.cooldown_base * Integer.pow(2, level - 1), state.cooldown_max)
      delay = jitter(ceiling, state.retry_jitter)

      %{
        state
        | cooldown_until: max(state.cooldown_until || now, now + delay),
          cooldown_level: level
      }
    else
      state
    end
  end

  defp observe_transport_failure(state, _handle, _status), do: state

  defp persist_feed_failure(state, handle) do
    case Map.fetch(state.pending_failures, handle) do
      {:ok, {status, at, ended?}} ->
        FeedCustody.retry_write(state.custody_dir, handle)

        # Keep the journal and pending evidence when SQLite refuses admission.
        # Waiting here would block the worker and manager retry paths.
        result =
          DB.refusable(fn ->
            DB.transaction(state.db, fn txn ->
              projected =
                cond do
                  not retryable_failure?(status) ->
                    mark_finished_in_txn(txn, handle, status, at)

                  first_open_held_in_txn?(txn, handle) ->
                    unopened_in_txn(txn, handle, status, at)

                  true ->
                    if cursor_expired?(status), do: want_pending_open_in_txn(txn, handle)
                    Outage.start_in_txn(txn, handle, failure_details(status), at)
                end

              if ended?, do: FeedCustody.release_launch_in_txn(txn, handle)
              projected
            end)
          end)

        case result do
          {:ok, [_, _, _, _] = row} -> state |> clear_pending_failure(handle) |> arm_outage(row)
          {:ok, nil} -> clear_pending_failure(state, handle)
          {:ok, :ok} -> state |> clear_pending_failure(handle) |> cancel_outage_timer(handle)
          {:error, _} -> state
        end

      :error ->
        state
    end
  end

  defp clear_pending_failure(state, handle) do
    case FeedCustody.forget(state.custody_dir, handle) do
      :ok -> %{state | pending_failures: Map.delete(state.pending_failures, handle)}
      {:error, _} -> state
    end
  end

  defp arm_feed_steady(state, handle, pid),
    do: Process.send_after(self(), {:feed_steady, handle, pid}, state.feed_steady_delay)

  defp arm_outage(state, [_handle, _episode, _started, notice]) when is_binary(notice), do: state

  defp arm_outage(state, [handle, episode, started, nil]) do
    if Map.has_key?(state.outage_timers, handle) do
      state
    else
      delay = max(0, started + state.outage_notice_delay - state.wall_now.())
      token = make_ref()
      timer = Process.send_after(self(), {:outage_notice, handle, episode, token}, delay)
      %{state | outage_timers: Map.put(state.outage_timers, handle, {timer, token})}
    end
  end

  defp cancel_outage_timer(state, handle) do
    case Map.pop(state.outage_timers, handle) do
      {nil, _} ->
        state

      {{timer, _}, timers} ->
        Process.cancel_timer(timer)
        %{state | outage_timers: timers}
    end
  end

  defp jitter(delay, _) when delay <= 1, do: delay
  defp jitter(delay, false), do: delay
  defp jitter(delay, true), do: div(delay, 2) + :rand.uniform(delay - div(delay, 2))

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

  # Only a definite permanent refusal, or a conversation with no receiver here,
  # ends listening. Every other failure retries from the saved checkpoint.
  defp retryable_failure?(:complete), do: false

  defp retryable_failure?(status),
    do:
      status not in ["origin_unavailable", "origin_host_mismatch"] and
        not identity_revoked?(status)

  # These need an operator and are no proof the conversation is gone: keep the
  # position and ask again at the slowest pace.
  defp refused_identity?({:harklight_failure, {_, "feed_refused"}, _, diagnostic}) do
    diagnostic
    |> List.wrap()
    |> Enum.any?(&(&1 =~ ~r/server returned HTTP (401: .*unauthorized|403: .*forbidden)/))
  end

  defp refused_identity?(_), do: false

  defp no_pending_route?({:harklight_failure, {_, "no_pending_route"}, _, _}), do: true
  defp no_pending_route?(_), do: false

  defp cursor_expired?({:harklight_failure, "cursor_expired", _, _}), do: true
  defp cursor_expired?(_), do: false

  # An expired position is recorded with the wish, so that a position which has
  # moved since is followed instead.
  defp want_pending_open_in_txn(txn, handle),
    do:
      Txn.q(
        txn,
        """
        INSERT OR IGNORE INTO harklight_pending_opens(handle,expired)
        VALUES(?1,(SELECT rev FROM harklight_feed_checkpoints WHERE handle=?1))
        """,
        [handle]
      )

  # A failure the Agent or the capture path identified, as opposed to a lost
  # connection or an unexplained exit. These outrank a closing child's silence.
  defp reported_failure?({:harklight_failure, {_error, code}, _, _}) do
    code in ~w(identity_revoked missing_journal configuration_error
      not_found forbidden operation_conflict invalid_field unsupported_version
      feed_gap feed_conflict invalid_notice invalid_response feed_refused internal_error
      feed_custody_uncertain)
  end

  defp reported_failure?({:harklight_failure, error, _, _}), do: reported_failure?(error)

  defp reported_failure?(error),
    do: error in ~w(cli_missing event_identity_invalid event_identity_mismatch
      event_order_invalid invalid_listener_line unexpected_feed_record cursor_expired)

  defp identity_revoked?({:harklight_failure, {_, "identity_revoked"}, _, _}), do: true
  defp identity_revoked?(_), do: false

  # A finished conversation cannot be opened, so retry is not offered for it.
  defp choice_reason(@first_open_pending, state) do
    open =
      if state == "complete",
        do: "",
        else: "It opens only with harklight-retry --session. "

    "This conversation has messages from before Harklight 0.2 and has not been opened since. " <>
      "Its first read can deliver earlier replies again. " <>
      open <> "To send, start a new conversation."
  end

  defp choice_reason(@pending_stopped, _state), do: pending_stopped_reason()

  defp pending_stopped_reason do
    "Harklight no longer accepts the saved position of this conversation's interrupted first read. " <>
      "Replies it had already served may be missing here; the conversation history has them. " <>
      "harklight-retry --session reads what is still waiting. To send, start a new conversation."
  end

  # A new send into a conversation that waits for a choice would not be heard.
  def first_open_pending(db, handle) do
    case DB.query(
           db,
           "SELECT h.state,#{@choice_sql} FROM harklight_wake_handles h WHERE h.handle=?1",
           [handle]
         ) do
      {:ok, [[state, code]]} when is_binary(code) -> {:error, code, choice_reason(code, state)}
      {:ok, _} -> :ok
      {:error, _} -> {:error, "harklight_send_unavailable"}
    end
  end

  defp first_open_held_in_txn?(txn, handle),
    do:
      Txn.q(
        txn,
        "SELECT 1 FROM harklight_wake_handles h WHERE h.handle=?1 AND #{@first_open_held_sql}",
        [handle]
      ) != []

  @impl true
  def terminate(reason, state) do
    if state.admission_timer, do: Process.cancel_timer(elem(state.admission_timer, 0))
    Enum.each(state.retry_timers, fn {_, {timer, _}} -> Process.cancel_timer(timer) end)
    Enum.each(state.outage_timers, fn {_, {timer, _}} -> Process.cancel_timer(timer) end)

    Enum.each(state.pending_failures, fn {handle, _} ->
      FeedCustody.retry_write(state.custody_dir, handle)
    end)

    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
      deadline = Tightbeam.Application.shutdown_deadline(drain_deadline())

      workers =
        for {handle, _port} <- state.ports,
            pid = state.workers[handle],
            token = state.launch_owners[handle],
            into: %{} do
          send(pid, {:close_feed, self(), token, deadline})
          {pid, {handle, token}}
        end

      settle_draining_feeds(state, workers, deadline)
    end

    Enum.each(state.ports, fn {_handle, port} -> close_listener_port(port) end)
    Enum.each(state.workers, fn {_handle, worker} -> Process.exit(worker, :shutdown) end)
  end

  defp settle_draining_feeds(_state, workers, _deadline) when map_size(workers) == 0, do: :ok

  defp settle_draining_feeds(state, workers, deadline) do
    receive do
      {:feed_result, pid, token, result} when is_map_key(workers, pid) ->
        case workers[pid] do
          {handle, ^token} ->
            state = apply_feed_result(state, handle, token, result)
            settle_draining_feeds(state, Map.delete(workers, pid), deadline)

          _ ->
            settle_draining_feeds(state, workers, deadline)
        end
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> :ok
    end
  end

  defp drain_deadline, do: System.monotonic_time(:millisecond) + 1_000

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
        request_worker_close(state, handle, worker)
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

    state =
      complete_retry_waiter(
        state,
        handle,
        {:failed, "listener receiver is no longer eligible",
         retry_waiter_started_for(state, handle)}
      )

    deferred =
      Enum.reduce(
        [handle, {handle, :retry}, {handle, :startup}, {handle, :new_request}],
        state.deferred,
        &MapSet.delete(&2, &1)
      )

    state = %{
      state
      | admission_queue: List.keydelete(state.admission_queue, handle, 0),
        manual_starts: MapSet.delete(state.manual_starts, handle),
        deferred: deferred
    }

    state =
      if Map.has_key?(state.pending_failures, handle),
        do: schedule_listener_retry(state, handle, @feed_read_retry_delay, :recover),
        else: state

    case Map.fetch(state.workers, handle) do
      {:ok, worker} ->
        request_worker_close(state, handle, worker)

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

  defp request_worker_close(state, handle, worker) do
    case Map.fetch(state.launch_owners, handle) do
      {:ok, token} ->
        send(worker, {:close_feed, self(), token, drain_deadline()})
        Process.send_after(self(), {:feed_drain_timeout, handle, token}, 1_000)

      :error ->
        Process.exit(worker, :shutdown)
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
           """
           SELECT COALESCE(p.diagnostic,h.lastError)
           FROM harklight_wake_handles h LEFT JOIN harklight_feed_pauses p ON p.handle=h.handle
           WHERE h.handle=?1
           """,
           [handle]
         ) do
      {:ok, [[reason]]} when is_binary(reason) and reason != "" -> reason
      _ -> "listener start failed without a recorded reason"
    end
  end

  defp listener_start_in_flight?(state, handle) do
    List.keymember?(state.admission_queue, handle, 0) or
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
      token = Tightbeam.Id.uuid4()

      case FeedCustody.arm_launch(state.db, handle, token) do
        :ok ->
          state = %{state | launch_owners: Map.put(state.launch_owners, handle, token)}
          open_feed_child(state, handle, pid, token, executable, args)

        {:error, :feed_launch_unavailable} = error ->
          {:reply, error, %{state | restart: MapSet.put(state.restart, {handle, :deferred_read})}}
      end
    else
      {:reply, {:error, :listener_fenced}, state}
    end
  end

  defp open_feed_child(state, handle, pid, token, executable, args) do
    case Tightbeam.HarklightChild.open({:handle, handle}, executable, args, state.child_opts) do
      {:ok, port, initial} ->
        true = Port.connect(port, pid)
        next = System.monotonic_time(:millisecond) + state.admission_spacing

        state = %{
          state
          | launching: MapSet.delete(state.launching, handle),
            admission_next: next,
            ports: Map.put(state.ports, handle, port)
        }

        {:reply, {:ok, port, initial, token}, admit_feed(state)}

      {:error, reason} ->
        status = failure_status("listener_failed", "listen", inspect(reason))

        ended? =
          case reason do
            {:child_start_failed, exit_status} ->
              Tightbeam.HarklightChild.verified_exit?(exit_status)

            other ->
              other not in [:child_readiness_unknown, :child_readiness_invalid]
          end

        state = apply_feed_result(state, handle, token, {:failed, status, ended?})
        {:reply, {:error, :feed_open_accounted}, state}
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
      Map.has_key?(state.retry_waiters, handle) or
          (listener_start_in_flight?(state, handle) and
             not Map.has_key?(state.retry_timers, handle) and
             not List.keymember?(state.admission_queue, handle, 0)) ->
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
           """
           SELECT COALESCE(h.currentReceiverSessionKey,h.sessionKey),h.host,h.state,
             #{@hold_sql}
           FROM harklight_wake_handles h
           LEFT JOIN harklight_feed_pauses p ON p.handle=h.handle
           LEFT JOIN harklight_feed_stops s ON s.handle=h.handle
           WHERE h.handle=?1
           """,
           [handle]
         ) do
      {:ok, [[^session_key, _host, handle_state, hold]]}
      when is_binary(hold) and handle_state in ["active", "unavailable"] ->
        {:reply, {:error, hold}, state}

      {:ok, [[^session_key, host, handle_state, nil]]}
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

      {:ok, [[_other_session, _host, _state, _hold]]} ->
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
        case DB.transaction(state.db, &feed_start_in_txn(&1, handle)) do
          {:ok, start} -> {:ok, state.db, start}
          _ -> {:error, "capture_unavailable"}
        end
      else
        {:error, "listener_fenced"}
      end

    {:reply, result, state}
  end

  def handle_call({:pending_open, handle, step}, from, state) do
    if valid_worker?(state, handle, from) do
      case DB.transaction(state.db, &pending_open_in_txn(&1, handle, step)) do
        {:ok, :stopped} ->
          state = cancel_outage_timer(state, handle)
          {:reply, :stopped, %{state | stopping: MapSet.put(state.stopping, handle)}}

        {:ok, result} ->
          {:reply, result, state}

        {:error, _} ->
          {:reply, {:error, "capture_unavailable"}, state}
      end
    else
      {:reply, {:error, "listener_fenced"}, state}
    end
  end

  def handle_call({:feed_capture, handle, rev, frames, mode}, from, state) do
    if valid_worker?(state, handle, from) do
      result = capture_feed_result(state.db, handle, rev, frames, mode)
      if match?({:ok, _}, result), do: Tightbeam.HarklightBounces.captured(frames)

      case result do
        {:ok, true} -> {:reply, :ok, confirm_feed_recovery(state, handle)}
        {:ok, false} -> {:reply, :ok, state}
        error -> {:reply, error, state}
      end
    else
      {:reply, {:error, "listener_fenced"}, state}
    end
  end

  def handle_call({:feed_live, handle}, from, state) do
    if valid_worker?(state, handle, from) do
      case Outage.finish(state.db, handle, true, state.wall_now.()) do
        {:ok, :ok} -> {:reply, :ok, confirm_feed_recovery(state, handle)}
        {:error, _} -> {:reply, {:error, "capture_unavailable"}, state}
      end
    else
      {:reply, {:error, "listener_fenced"}, state}
    end
  end

  def handle_call({:start_feed, handle}, from, state) do
    if valid_worker?(state, handle, from) do
      {reply, state} = prepare_listener(state, handle)

      state = %{state | restart: MapSet.delete(state.restart, {handle, :deciding})}

      state =
        case reply do
          :skip ->
            %{state | stopping: MapSet.put(state.stopping, handle)}

          :defer ->
            state = observe_feed_failure(state, handle, "feed_preparation_unavailable")
            %{state | restart: MapSet.put(state.restart, {handle, :deferred_read})}

          {:listen, _} ->
            state
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
    valid? = valid_worker?(state, handle, from)
    state = if valid?, do: persist_feed_failure(state, handle), else: state

    result =
      if valid? and not Map.has_key?(state.pending_failures, handle) do
        # The worker retries this local write without blocking the manager.
        case DB.refusable(fn ->
               with {:ok, _} <-
                      DB.query(
                        state.db,
                        "UPDATE harklight_wake_handles SET state='active',lastError=NULL,updatedAt=?2 WHERE handle=?1",
                        [handle, System.system_time(:millisecond)]
                      ) do
                 if MapSet.member?(state.manual_starts, handle) do
                   with {:ok, _} <-
                          DB.query(
                            state.db,
                            "DELETE FROM harklight_feed_pauses WHERE handle=?1",
                            [handle]
                          ) do
                     DB.query(state.db, "DELETE FROM harklight_feed_stops WHERE handle=?1", [
                       handle
                     ])
                   end
                 else
                   {:ok, []}
                 end
               end
             end) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, "feed_state_unavailable"}
        end
      else
        if valid?, do: {:error, "feed_state_unavailable"}, else: {:error, "listener_fenced"}
      end

    # Catch-up releases the manual wait but does not prove live recovery.
    state =
      if result == :ok do
        state = %{
          state
          | manual_starts: MapSet.delete(state.manual_starts, handle),
            failures: Map.delete(state.failures, handle),
            launching: MapSet.delete(state.launching, handle),
            starts_in_flight: MapSet.delete(state.starts_in_flight, handle)
        }

        arm_feed_steady(state, handle, elem(from, 0))

        case Map.get(state.retry_waiters, handle) do
          nil ->
            state

          %{started_for: started_for} ->
            complete_retry_waiter(state, handle, {:listening, started_for})
        end
      else
        if result == {:error, "feed_state_unavailable"},
          do: observe_feed_failure(state, handle, "feed_state_unavailable"),
          else: state
      end

    {:reply, result, admit_feed(state)}
  end

  def handle_call({:finished, handle, status}, from, state) do
    if valid_worker?(state, handle, from) do
      state = observe_feed_failure(state, handle, status, true)
      if status != :complete, do: log_listener_failure(handle, status)

      state =
        complete_retry_waiter(
          state,
          handle,
          {:failed, retry_failure_reason(state.db, handle),
           retry_waiter_started_for(state, handle)}
        )

      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  # How a feed starts is decided here only.
  defp feed_start_in_txn(txn, handle) do
    # An explicit retry of a stopped open prepares afresh.
    Txn.q(
      txn,
      "UPDATE harklight_pending_opens SET rev=NULL,token=NULL,resumed=0,stopped=0 WHERE handle=?1 AND stopped=1",
      [handle]
    )

    [[rev, earlier_unopened]] =
      Txn.q(
        txn,
        """
        SELECT c.rev,#{@earlier_unopened_sql} FROM harklight_wake_handles h
        LEFT JOIN harklight_feed_checkpoints c ON c.handle=h.handle WHERE h.handle=?1
        """,
        [handle]
      )

    # The position that expired is no longer the position, as after a rollback to
    # a version whose Agent recovered by itself.
    Txn.q(
      txn,
      "DELETE FROM harklight_pending_opens WHERE handle=?1 AND token IS NULL AND expired IS NOT NULL AND expired IS NOT ?2",
      [handle, rev]
    )

    if earlier_unopened == 1, do: want_pending_open_in_txn(txn, handle)

    # What an Agent and Server without the pending read do instead, as long as
    # nothing was prepared: an expired position keeps the Agent's own recovery, a
    # new conversation starts from a snapshot, and an old one stays unopened.
    older =
      cond do
        is_integer(rev) -> {:after, rev, :agent_recovers}
        earlier_unopened == 1 -> nil
        true -> :snapshot
      end

    case Txn.q(txn, "SELECT rev,token FROM harklight_pending_opens WHERE handle=?1", [handle]) do
      [[open_rev, token]] when is_binary(token) -> {:pending, {open_rev, token}, nil}
      [] when is_integer(rev) -> {:after, rev}
      _ -> {:pending, {nil, nil}, older}
    end
  end

  # The token is stored before anything is served under it, and once only.
  defp pending_open_in_txn(txn, handle, {:prepared, rev, token}) do
    Txn.q(
      txn,
      """
      INSERT INTO harklight_pending_opens(handle,rev,token) VALUES(?1,?2,?3)
      ON CONFLICT(handle) DO UPDATE SET rev=excluded.rev,token=excluded.token,resumed=0
      WHERE token IS NULL
      """,
      [handle, rev, token]
    )

    [[rev, token]] =
      Txn.q(txn, "SELECT rev,token FROM harklight_pending_opens WHERE handle=?1", [handle])

    {:ok, rev, token}
  end

  defp pending_open_in_txn(txn, handle, {:resuming, token}) do
    [[resumed]] =
      Txn.q(txn, "SELECT resumed FROM harklight_pending_opens WHERE handle=?1 AND token=?2", [
        handle,
        token
      ])

    Txn.q(txn, "UPDATE harklight_pending_opens SET resumed=1 WHERE handle=?1", [handle])
    {:ok, resumed == 1}
  end

  # A rejected token may be replaced only if it never served anything.
  defp pending_open_in_txn(txn, handle, {:rejected, token, false}) do
    Txn.q(
      txn,
      "UPDATE harklight_pending_opens SET rev=NULL,token=NULL,resumed=0 WHERE handle=?1 AND token=?2",
      [handle, token]
    )

    :unserved
  end

  defp pending_open_in_txn(txn, handle, {:rejected, token, true}) do
    now = System.system_time(:millisecond)

    Txn.q(txn, "UPDATE harklight_pending_opens SET stopped=1 WHERE handle=?1 AND token=?2", [
      handle,
      token
    ])

    Txn.q(
      txn,
      "UPDATE harklight_wake_handles SET state='unavailable',lastError='pending_token_invalid',updatedAt=?2 WHERE handle=?1 AND state<>'complete'",
      [handle, now]
    )

    Outage.finish_in_txn(txn, handle, false, now)

    [[session]] =
      Txn.q(txn, "SELECT sessionKey FROM harklight_wake_handles WHERE handle=?1", [handle])

    notify_owner_in_txn(
      txn,
      session,
      handle,
      "pending_open",
      "pending_token_invalid",
      "read",
      token,
      now
    )

    :stopped
  end

  defp apply_feed_result(state, handle, token, :clean) do
    unless Map.has_key?(state.pending_failures, handle) do
      FeedCustody.release_launch(state.db, handle, token)
    end

    state
  end

  defp apply_feed_result(state, handle, _token, :uncertain) do
    # The next admission discovers the still-owned fence.
    %{state | failures: Map.put(state.failures, handle, "listener_terminated")}
  end

  defp apply_feed_result(state, handle, _token, {:failed, status, ended?}) do
    log_listener_failure(handle, status)
    observe_feed_failure(state, handle, status, ended?)
  end

  defp confirm_feed_recovery(state, handle) do
    state = cancel_outage_timer(state, handle)
    if state.admission_timer, do: Process.cancel_timer(elem(state.admission_timer, 0))

    admit_feed(%{
      state
      | attempts: Map.delete(state.attempts, handle),
        transport_failures: Map.delete(state.transport_failures, handle),
        admission_timer: nil,
        cooldown_until: nil,
        cooldown_level: 0
    })
  end

  defp mark_finished(db, handle, status, now \\ System.system_time(:millisecond)) do
    case DB.transaction(db, fn txn -> mark_finished_in_txn(txn, handle, status, now) end) do
      {:ok, result} -> result
      {:error, _} -> {:error, "listener_state_unavailable"}
    end
  end

  defp mark_finished_in_txn(txn, handle, status, now) do
    case Txn.q(txn, "SELECT sessionKey,state FROM harklight_wake_handles WHERE handle=?1", [
           handle
         ]) do
      [[session_key, current_state]] when current_state in ["active", "unavailable"] ->
        completed = status == :complete
        next_state = if completed, do: "complete", else: "unavailable"

        {error, operation, diagnostic} =
          if completed, do: {nil, nil, nil}, else: failure_details(status)

        last_error = if diagnostic, do: error <> ": " <> diagnostic, else: error

        Txn.q(
          txn,
          "UPDATE harklight_wake_handles SET state=?2,lastError=?3,updatedAt=?4 WHERE handle=?1",
          [handle, next_state, last_error, now]
        )

        if completed, do: HarklightLifecycle.complete_in_txn(txn, handle)

        Outage.finish_in_txn(txn, handle, false, now)

        if identity_revoked?(status) do
          Txn.q(txn, "INSERT OR IGNORE INTO harklight_feed_stops(handle) VALUES(?1)", [handle])
        end

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

  # An explicit first opening failed. It stays unopened, with no recovery to
  # report.
  defp unopened_in_txn(txn, handle, status, now) do
    {error, _operation, diagnostic} = failure_details(status)

    Txn.q(
      txn,
      "UPDATE harklight_wake_handles SET state='unavailable',lastError=?2,updatedAt=?3 WHERE handle=?1 AND state<>'complete'",
      [handle, if(diagnostic, do: error <> ": " <> diagnostic, else: error), now]
    )

    nil
  end

  defp finish_recovery(db, handle, status) do
    {error, operation, diagnostic} = failure_details(status)
    now = System.system_time(:millisecond)

    DB.transaction(db, fn txn ->
      case Txn.q(
             txn,
             """
             SELECT h.sessionKey,h.state,o.noticeWakeId
             FROM harklight_wake_handles h
             LEFT JOIN harklight_listener_outages o ON o.handle=h.handle
             WHERE h.handle=?1
             """,
             [handle]
           ) do
        [[session_key, state, nil]] when state in ["active", "unavailable"] ->
          notify_owner_in_txn(
            txn,
            session_key,
            handle,
            "listener_failure",
            error,
            operation,
            diagnostic,
            now
          )

        _ ->
          :ok
      end

      Outage.finish_in_txn(txn, handle, false, now)
    end)
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
    wake_id =
      if error == "pending_token_invalid" do
        digest = :crypto.hash(:sha256, diagnostic) |> Base.url_encode64(padding: false)
        "w_harklight_notice_pending_" <> handle <> "_" <> digest
      else
        "w_harklight_notice_recovery_" <> handle
      end

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
            {"pending_token_invalid", _, _} ->
              " " <> pending_stopped_reason()

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

    cond do
      Map.has_key?(state.pending_failures, handle) ->
        schedule_listener_retry(state, handle, @feed_read_retry_delay, mode)

      handle in Map.values(state.gone_tasks) ->
        deferred = MapSet.put(state.deferred, handle)
        deferred = if mode != :existing, do: MapSet.put(deferred, {handle, mode}), else: deferred
        %{state | deferred: deferred}

      Map.has_key?(state.workers, handle) ->
        state

      mode != :retry and List.keymember?(state.admission_queue, handle, 0) ->
        state

      true ->
        restore_feed_custody(state, handle, mode)
    end
  end

  defp restore_feed_custody(state, handle, mode) do
    case FeedCustody.pending(state.custody_dir, handle) do
      :clear when mode == :fenced ->
        state

      :clear ->
        check_launch_custody(state, handle, mode)

      {:ok, {status, _at, _ended?} = evidence} ->
        state = %{
          state
          | failures: Map.put(state.failures, handle, status),
            pending_failures: Map.put(state.pending_failures, handle, evidence)
        }

        if mode in [:retry, :fenced],
          do: schedule_listener_retry(state, handle, 0, mode),
          else: recover_worker(state, handle)

      {:error, _} ->
        schedule_listener_retry(state, handle, @feed_read_retry_delay, mode)
    end
  end

  defp check_launch_custody(state, handle, mode) do
    case FeedCustody.launch_owner(state.db, handle) do
      {:ok, nil} ->
        enqueue_feed(state, handle, mode)

      # An earlier feed's outcome was never recorded. Resuming cannot lose or
      # repeat anything: its captures committed with the checkpoint or not at
      # all, events keep their identity when read again, and the child's
      # lifetime lock keeps a new child from running beside an old one.
      {:ok, _previous_owner} ->
        enqueue_feed(state, handle, mode)

      {:error, _} ->
        schedule_listener_retry(state, handle, @feed_read_retry_delay, mode)
    end
  end

  defp enqueue_feed(state, handle, mode) do
    queue = List.keydelete(state.admission_queue, handle, 0)
    request = {handle, mode}
    queue = if mode == :retry, do: [request | queue], else: queue ++ [request]
    admit_feed(%{state | admission_queue: queue})
  end

  defp admit_feed(%{admission_queue: []} = state), do: state
  defp admit_feed(%{admission_timer: {_, _}} = state), do: state

  defp admit_feed(state) do
    now = System.monotonic_time(:millisecond)
    due = max(state.admission_next || now, state.cooldown_until || now)

    cond do
      MapSet.size(state.launching) > 0 ->
        state

      due > now ->
        token = make_ref()
        timer = Process.send_after(self(), {:admit_feed, token}, due - now)
        %{state | admission_timer: {timer, token}}

      true ->
        [{handle, _mode} | queue] = state.admission_queue
        state = %{state | admission_queue: queue, admission_next: now + state.admission_spacing}
        state |> spawn_feed_worker(handle) |> admit_feed()
    end
  end

  defp spawn_feed_worker(state, handle) do
    manager = self()

    {:ok, pid} =
      Task.start_link(fn ->
        case GenServer.call(manager, {:start_feed, handle}, :infinity) do
          {:listen, vendor_id} -> state.listener.(manager, handle, vendor_id)
          stop when stop in [:skip, :defer] -> :ok
        end
      end)

    %{
      state
      | workers: Map.put(state.workers, handle, pid),
        launching: MapSet.put(state.launching, handle),
        starts_in_flight: MapSet.put(state.starts_in_flight, handle),
        refs: Map.put(state.refs, Process.monitor(pid), handle),
        restart: MapSet.put(state.restart, {handle, :deciding})
    }
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
    manual? = MapSet.member?(state.manual_starts, handle)

    case DB.query(
           state.db,
           """
           SELECT sessionKey,host,vendorSessionId,state,#{@hold_sql},
             s.handle IS NOT NULL OR p.handle IS NOT NULL
           FROM harklight_wake_handles h LEFT JOIN harklight_feed_pauses p ON p.handle=h.handle
           LEFT JOIN harklight_feed_stops s ON s.handle=h.handle
           WHERE h.handle=?1
           """,
           [handle]
         ) do
      {:ok, [[session_key, host, saved_vendor_id, state_value, hold, recorded]]}
      when state_value in ["active", "unavailable"] and
             (manual? or is_nil(hold) or recorded == 0) ->
        case listener_eligibility(state.db, handle, host) do
          {:ok, true} when hold != nil and not manual? ->
            {:skip, state}

          {:ok, true} ->
            # A held handle keeps its record until an explicit retry catches up.
            if is_nil(hold) and recorded == 1 and
                 match?({:error, _}, clear_recorded_stop(state.db, handle)) do
              {:defer, state}
            else
              prepare_eligible_listener(state, handle, session_key, host, saved_vendor_id)
            end

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

  defp clear_recorded_stop(db, handle) do
    DB.transaction(db, fn txn ->
      Txn.q(txn, "DELETE FROM harklight_feed_pauses WHERE handle=?1", [handle])
      Txn.q(txn, "DELETE FROM harklight_feed_stops WHERE handle=?1", [handle])
    end)
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
         {:ok, db, start} <- GenServer.call(manager, {:feed_start, handle}, :infinity) do
      case start do
        {:pending, open, older} ->
          # An old conversation asks anyway: only the refusal tells its receiver.
          case older && pending_agent?(manager, handle, executable) do
            {:ok, false} ->
              follow(manager, db, executable, handle, older, state_delays)

            supported when supported in [nil, {:ok, true}] ->
              open_pending(manager, db, executable, handle, open, older, state_delays)

            other ->
              finish_pending(other, manager, handle)
          end

        start ->
          follow(manager, db, executable, handle, start, state_delays)
      end
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

  # Every first open, and an expired position, is a caller-owned open: nothing
  # listens until everything waiting at its fixed position is applied and that
  # position is committed with it. Killed anywhere, the same token serves the
  # same rows again and events keep their identity. One reader per conversation:
  # another reader of this identity can take rows that this open would then not
  # be served.
  defp open_pending(manager, db, executable, handle, {_, nil}, older, state_delays) do
    with {:ok, output, status} <-
           run_agent(manager, handle, executable, pending_args(handle, ["--prepare"])) do
      case {status, pending_records(output)} do
        {0,
         [%{"kind" => "baseline_prepared", "session" => ^handle, "rev" => rev, "token" => token}]}
        when is_integer(rev) and rev >= 0 and is_binary(token) and token != "" ->
          with {:ok, rev, token} <- pending_step(manager, handle, {:prepared, rev, token}),
               do: open_pending(manager, db, executable, handle, {rev, token}, nil, state_delays)

        {_, records} ->
          failure = pending_failure(records, output, status)

          if older && no_pending_route?(failure),
            do: follow(manager, db, executable, handle, older, state_delays),
            else: {:error, failure}
      end
    end
    |> finish_pending(manager, handle)
  end

  defp open_pending(manager, db, executable, handle, {rev, token}, _older, state_delays) do
    with {:ok, resumed?} <- pending_step(manager, handle, {:resuming, token}),
         args = pending_args(handle, ["--resume", token]),
         {:ok, output, status} <- run_agent(manager, handle, executable, args) do
      records = pending_records(output)

      case {status, pending_rows(records, rev)} do
        {0, {:ok, frames}} ->
          feed = %{db: db, executable: executable}

          with :ok <- submit_feed(manager, handle, rev, frames, {:pending, token}, feed),
               do: follow(manager, db, executable, handle, {:after, rev}, state_delays)

        _ ->
          if Enum.any?(records, &match?(%{"kind" => "token_invalid"}, &1)) do
            served? = resumed? or Enum.any?(records, &match?(%{"kind" => "baseline"}, &1))

            with :unserved <- pending_step(manager, handle, {:rejected, token, served?}),
                 do: {:error, listener_failure("pending_token_invalid", status, [])}
          else
            {:error, pending_failure(records, output, status)}
          end
      end
    end
    |> finish_pending(manager, handle)
  end

  defp finish_pending({:error, "listener_fenced"}, _manager, _handle), do: :ok

  defp finish_pending({:error, {:internal_error, _, _} = error}, manager, handle),
    do: finish(manager, handle, internal_error_status(error))

  defp finish_pending({:error, status}, manager, handle), do: finish(manager, handle, status)
  defp finish_pending(result, _manager, _handle), do: result

  defp pending_step(manager, handle, step),
    do: GenServer.call(manager, {:pending_open, handle, step}, :infinity)

  # Both steps name exactly one conversation.
  defp pending_args(handle, step), do: ["read", "--session", handle, "--pending" | step]

  # Runs to its end as that feed's only child.
  defp run_agent(manager, handle, executable, args) do
    case GenServer.call(manager, {:launch_child, handle, executable, args}, :infinity) do
      {:ok, port, initial, _token} ->
        {output, status} = Tightbeam.HarklightChild.collect(port, initial)
        {:ok, output, status}

      {:error, reason} when reason in [:feed_launch_unavailable, :feed_open_accounted] ->
        :accounted

      {:error, :listener_fenced} ->
        {:error, "listener_fenced"}

      {:error, reason} ->
        {:error, failure_status("listener_failed", "listen", inspect(reason))}
    end
  end

  # Diagnostics share the output. A line with a brace that is not a whole record
  # may be a damaged row, so it stands as one and nothing is committed.
  defp pending_records(output) do
    for line <- String.split(output, "\n"),
        line =~ ~r/[{}]/ do
      case JSON.decode(line) do
        {:ok, %{"kind" => _} = record} -> record
        _ -> :damaged
      end
    end
  end

  # The markers must both name the stored position. A row is applied whatever
  # its pending marker says: that only describes receipts and updates.
  defp pending_rows([%{"kind" => "baseline", "rev" => rev} | rest], rev) do
    case List.pop_at(rest, -1) do
      {%{"kind" => "baseline_complete", "rev" => ^rev}, rows} ->
        if :damaged in rows, do: :error, else: {:ok, rows}

      _ ->
        :error
    end
  end

  defp pending_rows(_records, _rev), do: :error

  # An Agent without the flags refuses its command line; a Server without the
  # route is reported as unsupported.
  defp pending_failure(records, output, status) do
    lines =
      output
      |> String.split("\n")
      |> Enum.reject(&structured_output_line?/1)
      |> Enum.reduce([], &append_diagnostic(&2, &1))

    cond do
      Enum.any?(records, &match?(%{"kind" => "unsupported"}, &1)) or
          (status == 2 and output =~ ~r/unexpected argument '--(?:pending|prepare|resume)'/) ->
        failure_status(
          {"pending_unavailable", "no_pending_route"},
          "listen",
          "Opening this conversation needs Harklight Agent 0.2.4 and Server 0.2.7 or newer"
        )

      true ->
        case HarklightFailures.read_error(Enum.join(lines, "\n"), status, "read") do
          nil -> listener_failure(listener_exit_reason(status, lines), status, lines)
          internal -> internal_error_status(internal)
        end
    end
  end

  # Asked once per installed Agent, as that feed's child, so one that does not
  # answer holds back nothing else. Only an answer makes it an older Agent.
  defp pending_agent?(manager, handle, executable) do
    key = {__MODULE__, :pending_agent, executable}
    identity = with {:ok, stat} <- File.stat(executable), do: {stat.inode, stat.mtime, stat.size}

    case :persistent_term.get(key, nil) do
      {^identity, answer} ->
        {:ok, answer}

      _ ->
        case run_agent(manager, handle, executable, ["--version"]) do
          {:ok, output, 0} ->
            answer =
              case Regex.run(~r/(\d+\.\d+\.\d+)/, output) do
                [_, version] -> Version.compare(version, "0.2.4") != :lt
                nil -> false
              end

            :persistent_term.put(key, {identity, answer})
            {:ok, answer}

          {:ok, output, status} ->
            {:error, pending_failure([], output, status)}

          other ->
            other
        end
    end
  end

  defp feed_args({:after, rev}, true),
    do: ["--after", to_string(rev), "--on-expired", "exit"]

  defp feed_args({:after, rev}, false), do: ["--after", to_string(rev)]
  defp feed_args({:after, rev, :agent_recovers}, _), do: ["--after", to_string(rev)]
  defp feed_args(:snapshot, _), do: ["--snapshot"]

  defp follow(manager, db, executable, handle, {:after, _} = start, state_delays) do
    case pending_agent?(manager, handle, executable) do
      {:ok, stops?} -> follow(manager, db, executable, handle, start, stops?, state_delays)
      other -> finish_pending(other, manager, handle)
    end
  end

  defp follow(manager, db, executable, handle, start, state_delays),
    do: follow(manager, db, executable, handle, start, false, state_delays)

  defp follow(manager, db, executable, handle, start, stops_on_expiry?, state_delays) do
    args = ["listen", "--follow", "--session", handle | feed_args(start, stops_on_expiry?)]

    case GenServer.call(manager, {:launch_child, handle, executable, args}, :infinity) do
      {:ok, port, initial, token} ->
        try do
          feed = %{
            db: db,
            executable: executable,
            token: token,
            baseline: nil,
            stops_on_expiry: stops_on_expiry?,
            diagnostic_evidence: :quiet,
            ready: false,
            state_delays: state_delays
          }

          # The wrapper buffers forwarding until we say continue. If this
          # worker has already been fenced, forward only to the drain.
          case GenServer.call(manager, {:listener_port, handle, port}, :infinity) do
            :ok ->
              true = Port.command(port, "continue\n")
              receive_lines(manager, port, handle, initial, [], feed)

            {:error, "listener_fenced"} ->
              true = Port.command(port, "continue\n")
              stop_and_drain(manager, port, feed, initial, [], :closing, drain_deadline())
          end
        after
          close_listener_port(port)
        end

      {:error, reason} when reason in [:feed_launch_unavailable, :feed_open_accounted] ->
        :ok

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
      {:close_feed, ^manager, token, deadline} when token == feed.token ->
        stop_and_drain(manager, port, feed, pending, diagnostics, :closing, deadline)

      {:EXIT, ^manager, reason} ->
        exit(reason)

      {:EXIT, _sender, :shutdown} ->
        exit(:shutdown)

      {^port, {:data, bytes}} ->
        case consume_feed_lines(manager, handle, pending <> bytes, diagnostics, feed) do
          {:ok, remainder, diagnostics, feed} ->
            receive_lines(manager, port, handle, remainder, diagnostics, feed)

          {:error, reason, unread, diagnostics, feed} ->
            mode =
              if reason == "listener_fenced",
                do: :closing,
                else: {:failed, listener_failure(reason, nil, diagnostics)}

            stop_and_drain(manager, port, feed, unread, diagnostics, mode, drain_deadline())
        end

      {^port, {:exit_status, status}} ->
        drain = %{drain_state(feed, diagnostics, :running) | pending: pending}
        send_feed_result(manager, feed.token, drained_result(status, drain))
    end
  end

  defp consume_feed_lines(manager, handle, data, diagnostics, feed) do
    case :binary.split(data, "\n") do
      [line, rest] ->
        case receive_listener_line(manager, handle, line, diagnostics, feed) do
          {:ok, diagnostics, feed} ->
            consume_feed_lines(manager, handle, rest, diagnostics, feed)

          {:error, reason, diagnostics} ->
            {:error, reason, data, diagnostics, feed}
        end

      [remainder] ->
        {:ok, remainder, diagnostics, feed}
    end
  end

  defp stop_and_drain(manager, port, feed, pending, diagnostics, mode, deadline) do
    Tightbeam.HarklightChild.request_stop(port)
    drain = drain_output(drain_state(feed, diagnostics, mode), pending)
    drain_port(manager, port, feed.token, drain, deadline)
  end

  defp drain_state(feed, diagnostics, mode) do
    %{
      pending: "",
      diagnostics: diagnostics,
      evidence: feed.diagnostic_evidence,
      baseline: if(feed.baseline, do: elem(feed.baseline, 0)),
      discarded: false,
      fallback: if(match?({:failed, _}, mode), do: elem(mode, 1)),
      mode: mode
    }
  end

  defp drain_port(manager, port, token, drain, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0,
      do: send_feed_result(manager, token, drained_result(nil, drain)),
      else: receive_drain(manager, port, token, drain, deadline, remaining)
  end

  defp receive_drain(manager, port, token, drain, deadline, remaining) do
    receive do
      {^port, {:data, bytes}} ->
        drain_port(manager, port, token, drain_output(drain, bytes), deadline)

      {^port, {:exit_status, status}} ->
        send_feed_result(manager, token, drained_result(status, drain))

      {:close_feed, ^manager, ^token, final_deadline} ->
        drain = %{drain | mode: :closing}
        drain_port(manager, port, token, drain, min(deadline, final_deadline))

      {:EXIT, ^manager, reason} ->
        exit(reason)
    after
      remaining -> send_feed_result(manager, token, drained_result(nil, drain))
    end
  end

  defp drain_output(drain, bytes) do
    parts = :binary.split(drain.pending <> bytes, "\n", [:global])
    {pending, lines} = List.pop_at(parts, -1)
    Enum.reduce(lines, %{drain | pending: pending}, &drain_line/2)
  end

  defp drain_line(line, drain) do
    if structured_output_line?(line) do
      %{drain | discarded: true, baseline: drained_baseline(JSON.decode(line), drain.baseline)}
    else
      line = String.replace_invalid(line)

      %{
        drain
        | evidence: observe_feed_diagnostic(drain.evidence, line),
          diagnostics: append_diagnostic(drain.diagnostics, line)
      }
    end
  end

  defp drained_baseline({:ok, %{"kind" => "baseline", "rev" => rev}}, nil)
       when is_integer(rev) and rev >= 0,
       do: rev

  defp drained_baseline({:ok, %{"kind" => "baseline_complete", "rev" => rev}}, rev)
       when is_integer(rev),
       do: nil

  defp drained_baseline({:ok, %{"kind" => kind}}, baseline)
       when kind in ["caught_up", "focus", "message", "entry", "advisory"],
       do: baseline

  defp drained_baseline(_, _), do: :unverified

  # Keep outcome evidence independently of the bounded, redacted log buffer.
  # The wrapper can mask a natural exit, but cannot turn stderr into silence.
  defp observe_feed_diagnostic({:terminal, _} = evidence, _line), do: evidence

  defp observe_feed_diagnostic(evidence, line) do
    case HarklightFailures.listen_pause(line) || HarklightFailures.listen_refusal(line) do
      nil ->
        if String.trim(line) == "" or HarklightFailures.listen_progress?(line),
          do: evidence,
          else: :ambiguous

      terminal ->
        {:terminal, terminal}
    end
  end

  defp drained_result(status, drain) do
    evidence = observe_feed_diagnostic(drain.evidence, String.replace_invalid(drain.pending))
    diagnostics = append_diagnostic(drain.diagnostics, drain.pending)
    ended? = Tightbeam.HarklightChild.verified_exit?(status)
    reason = listener_exit_reason(status, diagnostics)
    failure = listener_failure(reason, status, diagnostics)

    cond do
      cursor_expired?(drain.fallback) ->
        {:failed, drain.fallback, ended?}

      match?({:terminal, _}, evidence) ->
        {:failed, terminal_feed_failure(elem(evidence, 1), status, diagnostics), ended?}

      reported_failure?(failure) ->
        {:failed, failure, ended?}

      drain.fallback && reported_failure?(drain.fallback) ->
        {:failed, drain.fallback, ended?}

      drain.mode == :closing ->
        if status == 0 and quiet_drain?(drain, evidence), do: :clean, else: :uncertain

      drain.fallback ->
        complete? = is_nil(drain.baseline) and drain.pending == ""
        known_exit? = status != 0 or evidence == :quiet
        {:failed, drain.fallback, ended? and complete? and known_exit?}

      not ended? ->
        {:failed, failure, false}

      not is_nil(drain.baseline) or structured_output_line?(drain.pending) ->
        {:failed, listener_failure("incomplete_line", status, diagnostics), false}

      true ->
        {:failed, failure, true}
    end
  end

  defp quiet_drain?(drain, evidence),
    do:
      evidence == :quiet and not drain.discarded and is_nil(drain.baseline) and
        drain.pending == ""

  defp terminal_feed_failure({:internal_error, _, _} = pause, _status, _diagnostics),
    do: internal_error_status(pause)

  defp terminal_feed_failure(code, status, diagnostics),
    do: listener_failure({"listener_stopped", Atom.to_string(code)}, status, diagnostics)

  defp send_feed_result(manager, token, result) do
    send(manager, {:feed_result, self(), token, result})
    :ok
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
          evidence = observe_feed_diagnostic(feed.diagnostic_evidence, diagnostic_line)

          {:ok, append_diagnostic(diagnostics, diagnostic_line),
           %{feed | diagnostic_evidence: evidence}}
        end
    end
  end

  defp apply_listener_frame(
         manager,
         handle,
         %{"kind" => "focus", "data" => %{"focus" => focus}},
         %{baseline: nil} = feed
       )
       when is_map(focus) do
    with :ok <- GenServer.call(manager, {:feed_live, handle}, :infinity), do: {:ok, feed}
  end

  defp apply_listener_frame(_manager, _handle, %{"kind" => "focus"}, feed), do: {:ok, feed}

  # The position expired. A feed told to exit then must not print a snapshot,
  # which skips chat on closed items, so one is not applied.
  defp apply_listener_frame(_manager, _handle, %{"kind" => "cursor_expired"}, _feed),
    do: {:error, "cursor_expired"}

  defp apply_listener_frame(_manager, _handle, %{"kind" => "baseline"}, %{
         stops_on_expiry: true
       }),
       do: {:error, "cursor_expired"}

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
        with {output, 0} <-
               System.cmd(executable, ["message-get", "--item-id", id], stderr_to_stdout: true),
             {:ok, %{"message" => %{"item_id" => ^id} = item}} <- JSON.decode(output) do
          {:ok, item}
        else
          {output, status} when is_integer(status) ->
            {:error,
             HarklightFailures.read_error(output, status, "message-get") ||
               "harklight_message_lookup_failed"}

          _ ->
            {:error, "harklight_message_lookup_failed"}
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

  defp listener_failure({:internal_error, _, _} = error, _exit_status, _diagnostics),
    do: internal_error_status(error)

  defp listener_failure(reason, exit_status, diagnostics) do
    failure_status(
      reason,
      "listen",
      listen_attempt_diagnostics("LISTEN attempt", exit_status, diagnostics)
    )
  end

  defp internal_error_status({:internal_error, operation, request_id}) do
    failure_status(
      {"listener_stopped", "internal_error"},
      operation,
      HarklightFailures.details(operation, request_id)
    )
  end

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

    level =
      if match?({:harklight_failure, {_, "internal_error"}, _, _}, status),
        do: :error,
        else: :warning

    Logger.log(
      level,
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
    case not HarklightFailures.listen_progress?(output) && sanitize_refusal_output(output) do
      false -> diagnostics
      nil -> diagnostics
      diagnostic -> Enum.take(diagnostics ++ [diagnostic], -@max_diagnostic_lines)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp finish(manager, handle, status) do
    GenServer.call(manager, {:finished, handle, status}, :infinity)
  end

  @doc false
  def capture_feed(db, handle, rev, frames, mode) do
    case capture_feed_result(db, handle, rev, frames, mode) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp capture_feed_result(db, handle, rev, frames, mode)
       when is_integer(rev) and rev >= 0 and
              (mode in [:baseline, :live] or (is_tuple(mode) and elem(mode, 0) == :pending)) do
    case DB.transaction(db, fn txn ->
           [[session, host, handle_state, event_position]] =
             Txn.q(
               txn,
               "SELECT sessionKey,host,state,lastCursor FROM harklight_wake_handles WHERE handle=?1",
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

           # A feed that answers ends an open that was only wanted: its position
           # is good, or the Agent recovered it.
           if mode in [:baseline, :live],
             do:
               Txn.q(
                 txn,
                 "DELETE FROM harklight_pending_opens WHERE handle=?1 AND token IS NULL",
                 [handle]
               )

           if mode != :live or rev > previous do
             # A pending open keeps the Server's order: chat before its answer.
             ordered = if mode == :baseline, do: Enum.sort_by(frames, & &1["rev"]), else: frames

             :ok = Tightbeam.HarklightBounces.capture_frames_in_txn(txn, handle, ordered)

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

             with {:pending, token} <- mode,
                  [] <-
                    Txn.q(
                      txn,
                      "DELETE FROM harklight_pending_opens WHERE handle=?1 AND token=?2 RETURNING handle",
                      [handle, token]
                    ) do
               raise "pending_open_changed"
             end

             if mode == :live and frames != [] do
               case Txn.q(txn, "SELECT lastCursor FROM harklight_wake_handles WHERE handle=?1", [
                      handle
                    ]) do
                 [[position]] when position > event_position ->
                   Outage.captured_in_txn(txn, handle, rev, System.system_time(:millisecond))

                 _ ->
                   false
               end
             else
               false
             end
           else
             false
           end
         end) do
      {:ok, recovered} -> {:ok, recovered}
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

  defp entry_prompt(txn, origin, line, handle, event, sender, message, _kind, _author) do
    instruction = handling_instruction(JSON.decode!(line), handle, event, message)

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

  defp handling_instruction(
         %{"kind" => "entry", "item_id" => item, "data" => %{"entry_id" => entry}},
         handle,
         event,
         message
       ) do
    action_instruction(handle, event) <>
      "Reply with `tightbeam harklight-reply --handle #{handle} --request #{message} --in-reply-to #{event} --body <reply> [--op-id <uuid>]`. If the outcome is uncertain, retry the same command with unchanged inputs and the operation ID returned in the response. " <>
      "Report actual attachment transfer or use with harklight-agent file-use --item-id #{item} --entry-id #{entry} --file-id <file> and the applicable outcome."
  end

  defp handling_instruction(
         %{"kind" => "message", "data" => %{"terminal" => %{"state" => "answered"}}},
         handle,
         event,
         message
       ) do
    action_instruction(handle, event) <>
      "Reconcile any earlier effect before applying the answer once. " <>
      "Report its disposition with `tightbeam harklight-result --handle #{handle} --request #{message} --in-reply-to #{event} --status applied|refused|received [--op-id <uuid>]`. If the outcome is uncertain, retry the same command with unchanged inputs and the operation ID returned in the response."
  end

  defp handling_instruction(_, _handle, _event, _message) do
    "Handle this Harklight entry from your originating session. " <>
      "Cleared, expired or superseded requests are closed. Check the recorded outcome before acting."
  end

  defp action_instruction(handle, event) do
    "Handle this Harklight entry from your originating session. " <>
      "Read it with `tightbeam harklight-read --handle #{handle}`. For this delivered chat or answer, confirm handoff with `tightbeam harklight-ack --handle #{handle} --event #{event}` before acting. "
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
