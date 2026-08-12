defmodule Tightbeam.RecurrenceSuppression do
  @moduledoc "Durable, receipt-idempotent suppression for recurring rail remedy deliveries."

  alias Tightbeam.{DB, Org, Wakes}
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS recurrence_suppression_episodes (
    statute TEXT NOT NULL,
    targetSession TEXT NOT NULL,
    subject TEXT NOT NULL,
    fingerprintDigest TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK (generation > 0),
    suppressedCount INTEGER NOT NULL DEFAULT 0 CHECK (suppressedCount >= 0),
    recoveredSequence INTEGER,
    escalated INTEGER NOT NULL DEFAULT 0 CHECK (escalated IN (0, 1)),
    PRIMARY KEY (statute, targetSession, subject, fingerprintDigest)
  );
  CREATE TABLE IF NOT EXISTS recurrence_suppression_receipts (
    statute TEXT NOT NULL,
    targetSession TEXT NOT NULL,
    subject TEXT NOT NULL,
    fingerprintDigest TEXT NOT NULL,
    generation INTEGER NOT NULL,
    receiptId TEXT NOT NULL,
    outcome TEXT NOT NULL,
    PRIMARY KEY (statute, targetSession, subject, fingerprintDigest, generation, receiptId)
  );
  CREATE TABLE IF NOT EXISTS recurrence_suppression_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    outcome TEXT NOT NULL,
    statute TEXT NOT NULL,
    targetSession TEXT,
    subject TEXT NOT NULL,
    fingerprintDigest TEXT,
    generation INTEGER NOT NULL,
    receiptId TEXT,
    suppressedCount INTEGER NOT NULL,
    cause TEXT NOT NULL,
    principal TEXT NOT NULL,
    recoverySequence INTEGER,
    recurrenceSequence INTEGER
  );
  """

  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Record the one delivery which opens a suppression generation."
  def record_first(db, config, occurrence) do
    with {:ok, normalized} <- normalize(occurrence) do
      transaction!(db, fn txn -> record_first_in_txn(txn, config, normalized) end)
    else
      :error -> unavailable(db, occurrence)
    end
  end

  @doc "Classify a later matching occurrence before any wake or turn is created."
  def repeat(db, config, occurrence, recovered?, recurred?) do
    with {:ok, normalized} <- normalize(occurrence) do
      transaction!(db, fn txn ->
        repeat_in_txn(txn, config, normalized, recovered?, recurred?)
      end)
    else
      :error -> unavailable(db, occurrence)
    end
  end

  defp record_first_in_txn(txn, _config, occurrence) do
    key = key(occurrence)

    Txn.q(
      txn,
      """
      INSERT INTO recurrence_suppression_episodes
        (statute,targetSession,subject,fingerprintDigest,generation,suppressedCount,recoveredSequence,escalated)
      VALUES (?1,?2,?3,?4,1,0,NULL,0) ON CONFLICT DO NOTHING
      """,
      key
    )

    generation = episode(txn, key).generation

    if insert_receipt(txn, key, generation, occurrence.receipt_id, "delivered") do
      audit(txn, "recurrence_first_delivered", occurrence, generation, 0, nil, nil)
    end

    :deliver
  end

  defp repeat_in_txn(txn, config, occurrence, recovered?, recurred?) do
    key = key(occurrence)

    case episode(txn, key) do
      nil ->
        audit(txn, "recurrence_suppression_unavailable", occurrence, 0, 0, nil, nil)
        :unavailable

      episode ->
        if receipt?(txn, key, episode.generation, occurrence.receipt_id) do
          :suppressed
        else
          episode = maybe_recover(txn, key, episode, occurrence, recovered?)

          if recurred? and is_integer(episode.recovered_sequence) and
               occurrence.sequence > episode.recovered_sequence do
            rearm(txn, key, episode, occurrence)
          else
            suppress(txn, config, key, episode, occurrence)
          end
        end
    end
  end

  defp maybe_recover(txn, key, %{recovered_sequence: nil} = episode, occurrence, true) do
    Txn.q(
      txn,
      """
      UPDATE recurrence_suppression_episodes SET recoveredSequence=?5
      WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
        AND generation=?6 AND recoveredSequence IS NULL
      """,
      key ++ [occurrence.sequence, episode.generation]
    )

    if Txn.changes(txn) == 1 do
      audit(
        txn,
        "recurrence_recovered",
        occurrence,
        episode.generation,
        episode.suppressed_count,
        occurrence.sequence,
        nil
      )

      %{episode | recovered_sequence: occurrence.sequence}
    else
      episode(txn, key)
    end
  end

  defp maybe_recover(_txn, _key, episode, _occurrence, _recovered?), do: episode

  defp rearm(txn, key, episode, occurrence) do
    next = episode.generation + 1

    Txn.q(
      txn,
      """
      UPDATE recurrence_suppression_episodes
      SET generation=?7,suppressedCount=0,recoveredSequence=NULL,escalated=0
      WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
        AND generation=?5 AND recoveredSequence=?6
      """,
      key ++ [episode.generation, episode.recovered_sequence, next]
    )

    if Txn.changes(txn) == 1 do
      insert_receipt(txn, key, next, occurrence.receipt_id, "delivered")

      audit(
        txn,
        "recurrence_rearmed",
        occurrence,
        next,
        0,
        episode.recovered_sequence,
        occurrence.sequence
      )

      {:rearmed, next}
    else
      :suppressed
    end
  end

  defp suppress(txn, config, key, episode, occurrence) do
    if insert_receipt(txn, key, episode.generation, occurrence.receipt_id, "suppressed") do
      count = episode.suppressed_count + 1

      Txn.q(
        txn,
        """
        UPDATE recurrence_suppression_episodes SET suppressedCount=?7
        WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
          AND generation=?5 AND suppressedCount=?6
        """,
        key ++ [episode.generation, episode.suppressed_count, count]
      )

      audit(
        txn,
        "recurrence_repeat_suppressed",
        occurrence,
        episode.generation,
        count,
        episode.recovered_sequence,
        occurrence.sequence
      )

      if count >= config.escalation_threshold and not episode.escalated do
        escalate(txn, key, episode.generation, count, occurrence)
      end
    end

    :suppressed
  end

  defp escalate(txn, key, generation, count, occurrence) do
    Txn.q(
      txn,
      """
      UPDATE recurrence_suppression_episodes SET escalated=1
      WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
        AND generation=?5 AND escalated=0
      """,
      key ++ [generation]
    )

    if Txn.changes(txn) == 1 do
      case escalation_target(txn, occurrence.target_session) do
        nil ->
          audit(
            txn,
            "recurrence_fallback_audit_only",
            occurrence,
            generation,
            count,
            nil,
            occurrence.sequence
          )

        target ->
          Wakes.schedule_in_txn(txn, %{
            wake_id: escalation_wake_id(occurrence.digest, generation),
            session_key: target,
            target_role: nil,
            origin: "process:tightbeam",
            prompt:
              "Recurring failure #{occurrence.statute} remains suppressed for #{occurrence.subject}; inspect the durable recurrence audit.",
            due_at: now(),
            creator_session_key: nil,
            target_gate: 1
          })

          audit(
            txn,
            "recurrence_escalated",
            occurrence,
            generation,
            count,
            nil,
            occurrence.sequence
          )
      end
    end
  end

  defp escalation_target(txn, target) do
    case Txn.q(
           txn,
           "SELECT spawnedBy,ownerUserId FROM sessions WHERE sessionKey=?1",
           [target]
         ) do
      [[parent, owner]] ->
        main = Org.personal_session_key(owner)

        cond do
          active_distinct?(txn, parent, target) -> parent
          active_distinct?(txn, main, target) -> main
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp active_distinct?(_txn, nil, _target), do: false
  defp active_distinct?(_txn, candidate, target) when candidate == target, do: false

  defp active_distinct?(txn, candidate, _target) do
    Txn.q(txn, "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'", [candidate]) ==
      [[1]]
  end

  defp unavailable(db, occurrence) do
    transaction!(db, fn txn ->
      safe = %{
        statute: string(occurrence, :statute) || "unknown",
        target_session: string(occurrence, :target_session),
        subject: string(occurrence, :subject) || "unknown",
        digest: nil,
        receipt_id: string(occurrence, :receipt_id),
        sequence: integer(occurrence, :sequence),
        cause: string(occurrence, :cause) || "missing-fingerprint-input",
        principal: string(occurrence, :principal) || "unknown"
      }

      audit(txn, "recurrence_suppression_unavailable", safe, 0, 0, nil, safe.sequence)
      :unavailable
    end)
  end

  defp normalize(occurrence) do
    fields =
      ~w(statute target_session subject failure_class failure_code receipt_id cause principal)a

    values = Map.new(fields, &{&1, string(occurrence, &1)})
    sequence = integer(occurrence, :sequence)

    if Enum.all?(values, fn {_key, value} -> is_binary(value) and value != "" end) and
         is_integer(sequence) and sequence >= 0 do
      digest =
        digest(
          Enum.map(~w(statute target_session subject failure_class failure_code)a, &values[&1])
        )

      {:ok, values |> Map.put(:sequence, sequence) |> Map.put(:digest, digest)}
    else
      :error
    end
  end

  defp digest(values) do
    bytes = Enum.map_join(values, fn value -> <<byte_size(value)::unsigned-big-64>> <> value end)
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp key(o), do: [o.statute, o.target_session, o.subject, o.digest]

  defp episode(txn, key) do
    case Txn.q(
           txn,
           """
           SELECT generation,suppressedCount,recoveredSequence,escalated
           FROM recurrence_suppression_episodes
           WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
           """,
           key
         ) do
      [[generation, count, recovered, escalated]] ->
        %{
          generation: generation,
          suppressed_count: count,
          recovered_sequence: recovered,
          escalated: escalated == 1
        }

      [] ->
        nil
    end
  end

  defp receipt?(txn, key, generation, receipt_id) do
    Txn.q(
      txn,
      """
      SELECT 1 FROM recurrence_suppression_receipts
      WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
        AND generation=?5 AND receiptId=?6
      """,
      key ++ [generation, receipt_id]
    ) == [[1]]
  end

  defp insert_receipt(txn, key, generation, receipt_id, outcome) do
    Txn.q(
      txn,
      """
      INSERT INTO recurrence_suppression_receipts
        (statute,targetSession,subject,fingerprintDigest,generation,receiptId,outcome)
      VALUES (?1,?2,?3,?4,?5,?6,?7) ON CONFLICT DO NOTHING
      """,
      key ++ [generation, receipt_id, outcome]
    )

    Txn.changes(txn) == 1
  end

  defp audit(txn, outcome, occurrence, generation, count, recovery_sequence, recurrence_sequence) do
    Txn.q(
      txn,
      """
      INSERT INTO recurrence_suppression_events
        (ts,outcome,statute,targetSession,subject,fingerprintDigest,generation,receiptId,
         suppressedCount,cause,principal,recoverySequence,recurrenceSequence)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
      """,
      [
        now(),
        outcome,
        occurrence.statute,
        occurrence.target_session,
        occurrence.subject,
        occurrence.digest,
        generation,
        occurrence.receipt_id,
        count,
        occurrence.cause,
        occurrence.principal,
        recovery_sequence,
        recurrence_sequence
      ]
    )
  end

  defp string(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp integer(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp escalation_wake_id(digest, generation),
    do: "w_rs_#{String.slice(digest, 0, 24)}_#{generation}"

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)
end
