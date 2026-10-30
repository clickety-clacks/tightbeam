defmodule Tightbeam.HarklightLifecycle do
  @moduledoc false
  alias Tightbeam.{DB, HarklightWakes, NoticeBatcher}
  alias Tightbeam.DB.Txn

  # Additive storage: the original send provenance and captured wake identities
  # remain authoritative. A missing subscription-end row means the original,
  # open subscription; no historical rows need to be inferred or rewritten.
  def ensure_schema(db) do
    DB.execute(db, """
    CREATE TABLE IF NOT EXISTS harklight_command_results (
      opId TEXT PRIMARY KEY,
      outcome TEXT NOT NULL,
      effects TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS harklight_subscription_ends (
      senderId TEXT NOT NULL,
      messageId TEXT NOT NULL,
      handle TEXT NOT NULL,
      opId TEXT NOT NULL,
      replacementId TEXT,
      state TEXT NOT NULL CHECK(state IN ('ended','open')),
      acknowledgment TEXT NOT NULL CHECK(acknowledgment IN ('not_needed','pending','acknowledged','failed')),
      ackEventId TEXT,
      reason TEXT,
      PRIMARY KEY(senderId,messageId)
    );
    CREATE TABLE IF NOT EXISTS harklight_follow_message_ends (
      senderId TEXT NOT NULL,
      messageId TEXT NOT NULL,
      handle TEXT NOT NULL,
      opId TEXT NOT NULL,
      replacementId TEXT,
      endedBySessionKey TEXT,
      endKind TEXT NOT NULL CHECK(endKind IN ('retracted','superseded','terminal')),
      PRIMARY KEY(senderId,messageId)
    );
    CREATE TABLE IF NOT EXISTS harklight_held_terminals (
      handle TEXT NOT NULL,
      eventId TEXT NOT NULL,
      senderId TEXT NOT NULL,
      messageId TEXT NOT NULL,
      rawLine TEXT NOT NULL,
      PRIMARY KEY(handle,eventId)
    );
    CREATE TABLE IF NOT EXISTS harklight_entry_context (
      wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
      statement TEXT NOT NULL
    );
    """)
  end

  def lookup(db, message_id) do
    {:ok, result} = DB.transaction(db, &lookup_in_txn(&1, message_id))
    result
  end

  def lookup_in_txn(txn, message_id) do
    case Txn.q(
           txn,
           """
           SELECT s.opId,s.sessionKey,s.payload,s.state,s.handle,s.senderId,s.messageId,r.outcome
           FROM harklight_send_operations s LEFT JOIN harklight_command_results r ON r.opId=s.opId
           WHERE s.messageId=?1 OR json_extract(s.payload,'$.request.message.message_id')=?1
           ORDER BY s.createdAt LIMIT 1
           """,
           [message_id]
         ) do
      [[op, session, payload, state, handle, sender, message, outcome]] ->
        prepared = JSON.decode!(payload)
        request = prepared["request"] || prepared

        %{
          op_id: op,
          session_key: session,
          payload: payload,
          request: request,
          handle: handle || request["session_handle"],
          sender_id: sender || get_in(request, ["message", "sender_id"]),
          message_id: message || get_in(request, ["message", "message_id"]),
          state: outcome || if(state == "bound", do: "committed", else: "pending")
        }

      [] ->
        nil
    end
  end

  def unresolved(db, ids) do
    Enum.find(ids, fn id -> match?(%{state: "pending"}, lookup(db, id)) end)
  end

  def effects_in_txn(txn, op_id) do
    case Txn.q(txn, "SELECT effects FROM harklight_command_results WHERE opId=?1", [op_id]) do
      [[json]] -> decode_effects(JSON.decode!(json))
      [] -> nil
    end
  end

  defp decode_effects(value) when is_list(value), do: Enum.map(value, &decode_effects/1)

  defp decode_effects(value) when is_map(value) do
    keys =
      ~w(wake_effect supersedes pending_delivery message_id effect reason acknowledgment subscription_state handle event_id session_key follower kind state replacement_id follows)a

    Map.new(value, fn {k, v} ->
      {Enum.find(keys, k, &(Atom.to_string(&1) == k)), decode_effects(v)}
    end)
  end

  defp decode_effects(value), do: value

  def record_result_in_txn(txn, op_id, outcome, effects) do
    Txn.q(txn, "INSERT INTO harklight_command_results(opId,outcome,effects) VALUES(?1,?2,?3)", [
      op_id,
      outcome,
      JSON.encode!(effects)
    ])

    Txn.q(txn, "DELETE FROM harklight_pending_supersedes WHERE opId=?1", [op_id])

    Tightbeam.Wakes.schedule_changed_in_txn(txn, :wake_ready)
    effects
  end

  def record_refused(db, op_id) do
    DB.transaction(db, fn txn ->
      effects_in_txn(txn, op_id) ||
        record_result_in_txn(txn, op_id, "refused", %{wake_effect: "none"})
    end)
  end

  def send_committed_in_txn(txn, session, op_id, payload, result) do
    effects_in_txn(txn, op_id) || begin_send_effects(txn, session, op_id, payload, result)
  end

  defp begin_send_effects(txn, session, op_id, payload, result) do
    prepared = JSON.decode!(payload)
    request = prepared["request"] || prepared
    message = request["message"] || %{}
    warnings = JSON.decode!(result)["supersedes_warnings"] || []
    ids = Enum.uniq(message["supersedes"] || [])

    {effects, pending} =
      Enum.map_reduce(ids, [], fn id, pending ->
        warning = Enum.find(warnings, &(&1["message_id"] == id))
        old = lookup_in_txn(txn, id)

        cond do
          warning ->
            {%{message_id: id, effect: "unchanged", reason: warning["reason"]}, pending}

          is_nil(old) or old.sender_id != message["sender_id"] ->
            {%{message_id: id, effect: "no_subscription"}, pending}

          old.session_key != session ->
            entries =
              end_follows_in_txn(
                txn,
                old,
                op_id,
                message["message_id"],
                session,
                "superseded"
              )

            {%{message_id: id, effect: "other_session"}, pending ++ entries}

          true ->
            entries = end_in_txn(txn, old, op_id, message["message_id"], "pending")

            {%{
               message_id: id,
               effect: "ended",
               acknowledgment: "pending",
               subscription_state: "open"
             }, pending ++ entries}
        end
      end)

    record_result_in_txn(txn, op_id, "committed", %{
      wake_effect: "subscribed",
      supersedes: effects,
      pending_delivery: pending
    })
  end

  def retract_committed(db, record, op_id) do
    {:ok, effects} =
      DB.transaction(db, fn txn ->
        effects_in_txn(txn, op_id) ||
          record_result_in_txn(txn, op_id, "committed", %{
            wake_effect: "ended",
            pending_delivery: end_in_txn(txn, record, op_id, nil, "not_needed")
          })
      end)

    effects
  end

  defp end_in_txn(txn, record, op_id, replacement, acknowledgment) do
    existing =
      Txn.q(txn, "SELECT 1 FROM harklight_subscription_ends WHERE senderId=?1 AND messageId=?2", [
        record.sender_id,
        record.message_id
      ])

    if existing == [] do
      Txn.q(
        txn,
        """
        INSERT INTO harklight_subscription_ends(senderId,messageId,handle,opId,replacementId,state,acknowledgment)
        VALUES(?1,?2,?3,?4,?5,?6,?7)
        """,
        [
          record.sender_id,
          record.message_id,
          record.handle,
          op_id,
          replacement,
          if(acknowledgment == "pending", do: "open", else: "ended"),
          acknowledgment
        ]
      )
    end

    end_follows_in_txn(
      txn,
      record,
      op_id,
      replacement,
      record.session_key,
      if(replacement, do: "superseded", else: "retracted")
    )
  end

  defp end_follows_in_txn(txn, record, op_id, replacement, ended_by, end_kind) do
    now = System.system_time(:millisecond)

    Txn.q(
      txn,
      """
      UPDATE harklight_wake_follows SET state='ended',endedAt=?3
      WHERE senderId=?1 AND messageId=?2 AND kind='message' AND state='open'
        AND (?4<>'superseded' OR sessionKey=?5)
      """,
      [record.sender_id, record.message_id, now, end_kind, ended_by]
    )

    Txn.q(
      txn,
      """
      INSERT INTO harklight_follow_message_ends(senderId,messageId,handle,opId,replacementId,endedBySessionKey,endKind)
      VALUES(?1,?2,?3,?4,?5,?6,?7)
      ON CONFLICT(senderId,messageId) DO UPDATE SET
        handle=excluded.handle,opId=excluded.opId,replacementId=excluded.replacementId,
        endedBySessionKey=excluded.endedBySessionKey,endKind=excluded.endKind
      """,
      [record.sender_id, record.message_id, record.handle, op_id, replacement, ended_by, end_kind]
    )

    pending_deliveries_in_txn(txn, record, replacement)
  end

  def end_message_follows_in_txn(txn, sender_id, message_id, handle, event_id) do
    Txn.q(
      txn,
      "UPDATE harklight_wake_follows SET state='ended',endedAt=?3 WHERE senderId=?1 AND messageId=?2 AND kind='message' AND state='open'",
      [sender_id, message_id, System.system_time(:millisecond)]
    )

    Txn.q(
      txn,
      """
      INSERT INTO harklight_follow_message_ends(senderId,messageId,handle,opId,replacementId,endedBySessionKey,endKind)
      VALUES(?1,?2,?3,?4,NULL,NULL,'terminal')
      ON CONFLICT(senderId,messageId) DO NOTHING
      """,
      [sender_id, message_id, handle, "terminal:" <> event_id]
    )

    :ok
  end

  def supersede_caller_in_txn(txn, sender_id, message_id) do
    case Txn.q(
           txn,
           "SELECT endedBySessionKey FROM harklight_follow_message_ends WHERE senderId=?1 AND messageId=?2 AND endKind='superseded'",
           [sender_id, message_id]
         ) do
      [[session_key]] -> session_key
      _ -> nil
    end
  end

  def message_follow_end_kind_in_txn(txn, sender_id, message_id) do
    case Txn.q(
           txn,
           "SELECT endKind FROM harklight_follow_message_ends WHERE senderId=?1 AND messageId=?2",
           [sender_id, message_id]
         ) do
      [[end_kind]] -> end_kind
      _ -> nil
    end
  end

  defp pending_deliveries_in_txn(txn, record, replacement) do
    statement =
      if replacement,
        do:
          "This entry was received before message #{record.message_id} was superseded by #{replacement}.",
        else: "This entry was received before message #{record.message_id} was retracted."

    Txn.q(
      txn,
      """
      SELECT COALESCE(d.wakeId,e.wakeId),e.handle,e.eventId,COALESCE(d.sessionKey,h.sessionKey)
      FROM harklight_wake_entries e
      JOIN harklight_wake_handles h ON h.handle=e.handle
      LEFT JOIN harklight_wake_deliveries d ON d.handle=e.handle AND d.eventId=e.eventId
      WHERE e.senderId=?1 AND e.messageId=?2
      ORDER BY e.feedCursor,COALESCE(d.sessionKey,h.sessionKey)
      """,
      [record.sender_id, record.message_id]
    )
    |> Enum.flat_map(fn [wake, handle, event, session_key] ->
      delivered =
        NoticeBatcher.source_delivery_turns_in_txn(txn, wake)
        |> Enum.any?(fn [_, status, _] -> status != "queued" end)

      if delivered do
        []
      else
        Txn.q(
          txn,
          "INSERT INTO harklight_entry_context(wakeId,statement) VALUES(?1,?2) ON CONFLICT(wakeId) DO NOTHING",
          [wake, statement]
        )

        [
          %{
            message_id: record.message_id,
            handle: handle,
            event_id: event,
            session_key: session_key
          }
        ]
      end
    end)
    |> Enum.uniq_by(&{&1.event_id, &1.session_key})
  end

  # The claim transaction is the final presentation boundary, shared with
  # command commits. Even an already sealed envelope gets its context before
  # the recipient receives it; no correction wake or second entry is created.
  def decorate_turn_in_txn(txn, "w_harklight_" <> _ = wake_id, prompt),
    do: decorate_sources_in_txn(txn, [wake_id], prompt)

  def decorate_turn_in_txn(txn, "w_nb_" <> _ = wake_id, prompt) do
    ids =
      NoticeBatcher.carrier_source_ids_in_txn(txn, wake_id)
      |> Enum.filter(&String.starts_with?(&1, "w_harklight_"))

    decorate_sources_in_txn(txn, ids, prompt)
  end

  def decorate_turn_in_txn(_txn, _wake_id, prompt), do: prompt

  defp decorate_sources_in_txn(txn, ids, prompt) do
    statements =
      Enum.flat_map(ids, fn id ->
        Txn.q(txn, "SELECT statement FROM harklight_entry_context WHERE wakeId=?1", [id])
        |> List.flatten()
      end)

    if statements == [], do: prompt, else: prompt <> "\n\n" <> Enum.join(statements, "\n")
  end

  # A terminal can precede its send response. Hold only a possible own closing
  # terminal until the stored outcome distinguishes it from another sender's
  # operation. A refused/closed target releases the real terminal unchanged.
  def hold_terminal_in_txn?(txn, handle, sender, message, event_id, line) do
    entry = JSON.decode!(line)["entry"]

    if entry["kind"] == "terminal" and entry["terminal_state"] == "superseded" do
      ended =
        Txn.q(
          txn,
          "SELECT acknowledgment FROM harklight_subscription_ends WHERE senderId=?1 AND messageId=?2 AND replacementId IS NOT NULL",
          [sender, message]
        )

      pending =
        Txn.q(
          txn,
          "SELECT 1 FROM harklight_pending_supersedes WHERE senderId=?1 AND messageId=?2 LIMIT 1",
          [sender, message]
        ) != []

      if pending do
        Txn.q(
          txn,
          "INSERT INTO harklight_held_terminals(handle,eventId,senderId,messageId,rawLine) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(handle,eventId) DO NOTHING",
          [handle, event_id, sender, message, line]
        )

        true
      else
        if ended == [["pending"]] do
          Txn.q(
            txn,
            "UPDATE harklight_subscription_ends SET ackEventId=?3 WHERE senderId=?1 AND messageId=?2 AND ackEventId IS NULL",
            [sender, message, event_id]
          )

          Txn.q(
            txn,
            "INSERT INTO harklight_held_terminals(handle,eventId,senderId,messageId,rawLine) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(handle,eventId) DO NOTHING",
            [handle, event_id, sender, message, line]
          )
        end

        false
      end
    else
      false
    end
  end

  # A held terminal must not be overtaken by later entries on its handle.
  # Releasing it can create its wake later than those entries, so retain feed
  # order within that handle without changing the order of unrelated notices.
  def ready_sources_in_txn(txn, ids) do
    tagged =
      Enum.map(ids, fn id ->
        if String.starts_with?(id, "w_harklight_") do
          case Txn.q(
                 txn,
                 """
                 SELECT e.handle,e.feedCursor
                 FROM harklight_wake_entries e
                 LEFT JOIN harklight_wake_deliveries d ON d.handle=e.handle AND d.eventId=e.eventId
                 WHERE e.wakeId=?1 OR d.wakeId=?1
                 LIMIT 1
                 """,
                 [id]
               ) do
            [[handle, cursor]] -> {id, handle, cursor}
            [] -> {id, nil, nil}
          end
        else
          {id, nil, nil}
        end
      end)

    ready =
      Enum.reject(tagged, fn {_id, handle, cursor} ->
        is_binary(handle) and
          Txn.q(
            txn,
            """
            SELECT 1 FROM harklight_held_terminals t
            WHERE t.handle=?1 AND CAST(t.eventId AS INTEGER)<?2
              AND NOT EXISTS (SELECT 1 FROM harklight_subscription_ends e WHERE e.senderId=t.senderId AND e.messageId=t.messageId)
              AND NOT EXISTS (SELECT 1 FROM harklight_wake_entries e WHERE e.handle=t.handle AND e.eventId=t.eventId)
              AND NOT EXISTS (SELECT 1 FROM harklight_wake_suppressed_entries e WHERE e.handle=t.handle AND e.eventId=t.eventId)
            LIMIT 1
            """,
            [handle, cursor]
          ) != []
      end)

    groups =
      ready
      |> Enum.reject(fn {_, h, _} -> is_nil(h) end)
      |> Enum.group_by(&elem(&1, 1))
      |> Map.new(fn {h, entries} -> {h, Enum.sort_by(entries, &elem(&1, 2))} end)

    {ordered, _} =
      Enum.map_reduce(ready, groups, fn
        {id, nil, _}, groups ->
          {id, groups}

        {_, handle, _}, groups ->
          [{id, _, _} | rest] = Map.fetch!(groups, handle)
          {id, Map.put(groups, handle, rest)}
      end)

    ordered
  end

  def held_in_txn?(txn, handle, event) do
    Txn.q(txn, "SELECT 1 FROM harklight_held_terminals WHERE handle=?1 AND eventId=?2", [
      handle,
      event
    ]) != []
  end

  def process_terminals(db, opts \\ []) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT t.handle,t.eventId,t.rawLine FROM harklight_held_terminals t
        LEFT JOIN harklight_subscription_ends e ON e.senderId=t.senderId AND e.messageId=t.messageId
        WHERE (e.messageId IS NULL OR (e.acknowledgment='pending' AND e.ackEventId IS NULL))
          AND NOT EXISTS (SELECT 1 FROM harklight_wake_entries w WHERE w.handle=t.handle AND w.eventId=t.eventId)
          AND NOT EXISTS (SELECT 1 FROM harklight_wake_suppressed_entries w WHERE w.handle=t.handle AND w.eventId=t.eventId)
        ORDER BY CAST(t.eventId AS INTEGER)
        """
      )

    Enum.each(rows, fn [handle, _event, line] -> HarklightWakes.capture_line(db, handle, line) end)

    acknowledge_pending(db, opts)
  end

  def acknowledge_pending(db, opts \\ []) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT senderId,messageId,handle,ackEventId FROM harklight_subscription_ends WHERE acknowledgment='pending' AND ackEventId IS NOT NULL"
      )

    Enum.each(rows, fn [sender, message, handle, event] ->
      # Serialize the check and ack with other ack attempts. The external ack
      # itself is idempotent; a crash before recording it resumes at startup.
      :global.trans({{__MODULE__, db, handle, event}, self()}, fn ->
        case DB.query(
               db,
               "SELECT acknowledgment FROM harklight_subscription_ends WHERE senderId=?1 AND messageId=?2",
               [sender, message]
             ) do
          {:ok, [["pending"]]} ->
            result = Tightbeam.HarklightSend.ack(handle, event, opts)

            {state, status, reason} =
              case result do
                :ok -> {"ended", "acknowledged", nil}
                {:error, reason} -> {"open", "failed", reason}
              end

            DB.query(
              db,
              "UPDATE harklight_subscription_ends SET state=?3,acknowledgment=?4,reason=?5 WHERE senderId=?1 AND messageId=?2",
              [sender, message, state, status, reason]
            )

          _ ->
            :ok
        end
      end)
    end)

    :ok
  end

  def refresh_acknowledgments_result(effects, db), do: refresh_acknowledgments(db, effects)

  def refresh_acknowledgments(db, effects) do
    Map.update(effects, :supersedes, [], fn targets ->
      Enum.map(targets, fn target ->
        if target.effect == "ended" do
          case DB.query(
                 db,
                 "SELECT acknowledgment,state,reason FROM harklight_subscription_ends WHERE messageId=?1",
                 [target.message_id]
               ) do
            {:ok, [[ack, state, reason]]} ->
              Map.merge(target, %{
                acknowledgment: ack,
                subscription_state: state,
                reason: reason,
                follows: follows_for_message(db, target.message_id)
              })

            _ ->
              target
          end
        else
          target
        end
      end)
    end)
  end

  defp follows_for_message(db, message_id) do
    case DB.query(
           db,
           "SELECT handle FROM harklight_wake_requests WHERE messageId=?1 LIMIT 1",
           [message_id]
         ) do
      {:ok, [[handle]]} ->
        case DB.query(
               db,
               "SELECT sessionKey,kind,messageId,state FROM harklight_wake_follows WHERE handle=?1 AND (kind='conversation' OR messageId=?2) ORDER BY createdAt,followId",
               [handle, message_id]
             ) do
          {:ok, rows} ->
            Enum.map(rows, fn [follower, kind, followed_message, state] ->
              %{
                follower: follower,
                kind: kind,
                message_id: if(followed_message == "", do: nil, else: followed_message),
                state: state
              }
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  def complete_in_txn(txn, handle) do
    Txn.q(
      txn,
      "UPDATE harklight_subscription_ends SET state='ended',acknowledgment=CASE WHEN acknowledgment='pending' AND ackEventId IS NULL THEN 'not_needed' ELSE acknowledgment END WHERE handle=?1",
      [handle]
    )

    Txn.q(
      txn,
      "UPDATE harklight_wake_follows SET state='ended',endedAt=?2 WHERE handle=?1 AND state='open'",
      [handle, System.system_time(:millisecond)]
    )
  end
end
