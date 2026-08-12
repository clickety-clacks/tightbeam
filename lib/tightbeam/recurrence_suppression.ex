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
    openedEvidenceSequence INTEGER NOT NULL,
    openedOccurrenceSequence INTEGER NOT NULL,
    recoveredSequence INTEGER,
    recoveredOccurrenceSequence INTEGER,
    recurrenceBaselineSequence INTEGER,
    escalated INTEGER NOT NULL DEFAULT 0 CHECK (escalated IN (0, 1)),
    PRIMARY KEY (statute, targetSession, subject, fingerprintDigest)
  );
  CREATE TABLE IF NOT EXISTS recurrence_suppression_deliveries (
    statute TEXT NOT NULL,
    subject TEXT NOT NULL,
    receiptId TEXT NOT NULL,
    dispatchKey TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending','delivered')),
    targetSession TEXT,
    fingerprintDigest TEXT,
    PRIMARY KEY (statute, subject, receiptId),
    UNIQUE (dispatchKey)
  );
  CREATE TABLE IF NOT EXISTS recurrence_suppression_fact_observations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    statute TEXT NOT NULL,
    targetSession TEXT NOT NULL,
    subject TEXT NOT NULL,
    fingerprintDigest TEXT NOT NULL,
    generation INTEGER NOT NULL,
    phase TEXT NOT NULL CHECK (phase IN ('recovered','recurred')),
    signature TEXT NOT NULL,
    matched INTEGER NOT NULL CHECK (matched IN (0,1))
  );
  CREATE TABLE IF NOT EXISTS recurrence_suppression_receipts (
    statute TEXT NOT NULL,
    targetSession TEXT NOT NULL,
    subject TEXT NOT NULL,
    fingerprintDigest TEXT NOT NULL,
    generation INTEGER NOT NULL,
    receiptId TEXT NOT NULL,
    outcome TEXT NOT NULL,
    PRIMARY KEY (statute, targetSession, subject, fingerprintDigest, receiptId)
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

  @doc "Persist the dispatch identity before the first producer can be delivered."
  def prepare_first(db, occurrence, dispatch_key) do
    with {:ok, pending} <- normalize_pending(occurrence), true <- valid_string?(dispatch_key) do
      transaction!(db, fn txn ->
        Txn.q(
          txn,
          """
          INSERT INTO recurrence_suppression_deliveries
            (statute,subject,receiptId,dispatchKey,state)
          VALUES (?1,?2,?3,?4,'pending') ON CONFLICT DO NOTHING
          """,
          [pending.statute, pending.subject, pending.receipt_id, dispatch_key]
        )

        case Txn.q(
               txn,
               "SELECT dispatchKey,state FROM recurrence_suppression_deliveries WHERE statute=?1 AND subject=?2 AND receiptId=?3",
               [pending.statute, pending.subject, pending.receipt_id]
             ) do
          [[^dispatch_key, "pending"]] -> :dispatch
          [[^dispatch_key, "delivered"]] -> :delivered
          _ -> :conflict
        end
      end)
    else
      _ -> :unavailable
    end
  end

  @doc "Commit the delivered target and open its suppression generation."
  def record_first(db, config, occurrence, dispatch_key, recovered_evidence) do
    with {:ok, normalized} <- normalize(occurrence) do
      transaction!(db, fn txn ->
        record_first_in_txn(txn, config, normalized, dispatch_key, recovered_evidence)
      end)
    else
      :error -> unavailable(db, occurrence)
    end
  end

  @doc "Classify a later matching occurrence before any wake or turn is created."
  def repeat(db, config, occurrence, recovered_evidence, recurred_evidence) do
    with {:ok, normalized} <- normalize(occurrence) do
      transaction!(db, fn txn ->
        repeat_in_txn(txn, config, normalized, recovered_evidence, recurred_evidence)
      end)
    else
      :error -> unavailable(db, occurrence)
    end
  end

  defp record_first_in_txn(txn, _config, occurrence, dispatch_key, recovered_evidence) do
    key = key(occurrence)
    opened_sequence = observe(txn, key, 1, "recovered", recovered_evidence)

    Txn.q(
      txn,
      """
      INSERT INTO recurrence_suppression_episodes
        (statute,targetSession,subject,fingerprintDigest,generation,suppressedCount,
         openedEvidenceSequence,openedOccurrenceSequence,recoveredSequence,recoveredOccurrenceSequence,
         recurrenceBaselineSequence,escalated)
      VALUES (?1,?2,?3,?4,1,0,?5,?6,NULL,NULL,NULL,0) ON CONFLICT DO NOTHING
      """,
      key ++ [opened_sequence, occurrence.sequence]
    )

    generation = episode(txn, key).generation

    if insert_receipt(txn, key, generation, occurrence.receipt_id, "delivered") do
      audit(txn, "recurrence_first_delivered", occurrence, generation, 0, nil, nil)
    end

    Txn.q(
      txn,
      """
      UPDATE recurrence_suppression_deliveries
      SET state='delivered',targetSession=?5,fingerprintDigest=?6
      WHERE statute=?1 AND subject=?2 AND receiptId=?3 AND dispatchKey=?4
        AND state IN ('pending','delivered')
      """,
      [
        occurrence.statute,
        occurrence.subject,
        occurrence.receipt_id,
        dispatch_key,
        occurrence.target_session,
        occurrence.digest
      ]
    )

    :deliver
  end

  defp repeat_in_txn(txn, config, occurrence, recovered_evidence, recurred_evidence) do
    key = key(occurrence)

    case episode(txn, key) do
      nil ->
        audit(txn, "recurrence_suppression_unavailable", occurrence, 0, 0, nil, nil)
        :unavailable

      episode ->
        case receipt_result(txn, key, occurrence.receipt_id) do
          nil ->
            if episode.generation > 1 and
                 occurrence.sequence == episode.opened_occurrence_sequence and
                 evidence_matches?(recurred_evidence) do
              replay_rearm(txn, key, episode.generation, occurrence.receipt_id)
            else
              recovery_observation =
                observe(txn, key, episode.generation, "recovered", recovered_evidence)

              recurrence_observation =
                observe(txn, key, episode.generation, "recurred", recurred_evidence)

              episode =
                maybe_recover(
                  txn,
                  key,
                  episode,
                  occurrence,
                  recovered_evidence,
                  recovery_observation,
                  recurrence_observation
                )

              if evidence_matches?(recurred_evidence) and
                   is_integer(episode.recovered_sequence) and
                   occurrence.sequence > episode.recovered_occurrence_sequence do
                rearm(
                  txn,
                  key,
                  episode,
                  occurrence,
                  recovered_evidence,
                  recurrence_observation
                )
              else
                suppress(txn, config, key, episode, occurrence)
              end
            end

          result ->
            result
        end
    end
  end

  defp maybe_recover(
         txn,
         key,
         %{recovered_sequence: nil} = episode,
         occurrence,
         evidence,
         recovery_observation,
         recurrence_observation
       ) do
    eligible =
      evidence_matches?(evidence) and recovery_observation > episode.opened_evidence_sequence

    Txn.q(
      txn,
      """
      UPDATE recurrence_suppression_episodes
      SET recoveredSequence=?5,recoveredOccurrenceSequence=?6,recurrenceBaselineSequence=?7
      WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
        AND generation=?8 AND recoveredSequence IS NULL AND ?9=1
      """,
      key ++
        [
          recovery_observation,
          occurrence.sequence,
          recurrence_observation,
          episode.generation,
          if(eligible, do: 1, else: 0)
        ]
    )

    if Txn.changes(txn) == 1 do
      audit(
        txn,
        "recurrence_recovered",
        occurrence,
        episode.generation,
        episode.suppressed_count,
        recovery_observation,
        nil
      )

      %{
        episode
        | recovered_sequence: recovery_observation,
          recovered_occurrence_sequence: occurrence.sequence,
          recurrence_baseline_sequence: recurrence_observation
      }
    else
      episode(txn, key)
    end
  end

  defp maybe_recover(_txn, _key, episode, _occurrence, _evidence, _recovery, _recurrence),
    do: episode

  defp rearm(txn, key, episode, occurrence, recovered_evidence, recurrence_observation) do
    next = episode.generation + 1

    Txn.q(
      txn,
      """
      UPDATE recurrence_suppression_episodes
      SET generation=?7,suppressedCount=0,openedEvidenceSequence=?8,
          openedOccurrenceSequence=?9,recoveredSequence=NULL,
          recoveredOccurrenceSequence=NULL,recurrenceBaselineSequence=NULL,escalated=0
      WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
        AND generation=?5 AND recoveredSequence=?6
      """,
      key ++
        [
          episode.generation,
          episode.recovered_sequence,
          next,
          recurrence_observation,
          occurrence.sequence
        ]
    )

    if Txn.changes(txn) == 1 do
      opened_evidence_sequence = observe(txn, key, next, "recovered", recovered_evidence)

      Txn.q(
        txn,
        """
        UPDATE recurrence_suppression_episodes SET openedEvidenceSequence=?6
        WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
          AND generation=?5
        """,
        key ++ [next, opened_evidence_sequence]
      )

      insert_receipt(txn, key, next, occurrence.receipt_id, "rearmed")

      audit(
        txn,
        "recurrence_rearmed",
        occurrence,
        next,
        0,
        episode.recovered_sequence,
        recurrence_observation
      )

      {:rearmed, next}
    else
      case episode(txn, key) do
        %{generation: ^next, opened_occurrence_sequence: sequence}
        when sequence == occurrence.sequence ->
          replay_rearm(txn, key, next, occurrence.receipt_id)

        _ ->
          :suppressed
      end
    end
  end

  defp replay_rearm(txn, key, generation, receipt_id) do
    insert_receipt(txn, key, generation, receipt_id, "rearmed")
    {:rearmed, generation}
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
      case main_fallback_target(txn, occurrence.target_session) do
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
            %{occurrence | cause: "operational-parent-unavailable"},
            generation,
            count,
            nil,
            occurrence.sequence
          )
      end
    end
  end

  # This base has no durable operational-parent resolver. Creation provenance
  # (`spawnedBy`) is deliberately not authority; the declared fallback is Main.
  defp main_fallback_target(txn, target) do
    case Txn.q(
           txn,
           "SELECT ownerUserId FROM sessions WHERE sessionKey=?1",
           [target]
         ) do
      [[owner]] ->
        main = Org.personal_session_key(owner)
        if active_distinct?(txn, main, target), do: main

      _ ->
        nil
    end
  end

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

  defp normalize_pending(occurrence) do
    with statute when is_binary(statute) and statute != "" <- string(occurrence, :statute),
         subject when is_binary(subject) and subject != "" <- string(occurrence, :subject),
         receipt when is_binary(receipt) and receipt != "" <- string(occurrence, :receipt_id) do
      {:ok, %{statute: statute, subject: subject, receipt_id: receipt}}
    else
      _ -> :error
    end
  end

  defp valid_string?(value), do: is_binary(value) and value != ""

  defp digest(values) do
    bytes = Enum.map_join(values, fn value -> <<byte_size(value)::unsigned-big-64>> <> value end)
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp key(o), do: [o.statute, o.target_session, o.subject, o.digest]

  defp episode(txn, key) do
    case Txn.q(
           txn,
           """
           SELECT generation,suppressedCount,openedEvidenceSequence,openedOccurrenceSequence,
                  recoveredSequence,recoveredOccurrenceSequence,recurrenceBaselineSequence,escalated
           FROM recurrence_suppression_episodes
           WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
           """,
           key
         ) do
      [
        [
          generation,
          count,
          opened,
          opened_occurrence,
          recovered,
          recovered_occurrence,
          recurrence_baseline,
          escalated
        ]
      ] ->
        %{
          generation: generation,
          suppressed_count: count,
          opened_evidence_sequence: opened,
          opened_occurrence_sequence: opened_occurrence,
          recovered_sequence: recovered,
          recovered_occurrence_sequence: recovered_occurrence,
          recurrence_baseline_sequence: recurrence_baseline,
          escalated: escalated == 1
        }

      [] ->
        nil
    end
  end

  defp receipt_result(txn, key, receipt_id) do
    case Txn.q(
           txn,
           """
           SELECT generation,outcome FROM recurrence_suppression_receipts
           WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
             AND receiptId=?5
           """,
           key ++ [receipt_id]
         ) do
      [[_generation, "delivered"]] -> :deliver
      [[_generation, "suppressed"]] -> :suppressed
      [[generation, "rearmed"]] -> {:rearmed, generation}
      [] -> nil
    end
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

  defp observe(txn, key, generation, phase, evidence) do
    signature = evidence_signature(evidence)
    matched = if evidence_matches?(evidence), do: 1, else: 0

    case Txn.q(
           txn,
           """
           SELECT id,signature,matched FROM recurrence_suppression_fact_observations
           WHERE statute=?1 AND targetSession=?2 AND subject=?3 AND fingerprintDigest=?4
             AND generation=?5 AND phase=?6 ORDER BY id DESC LIMIT 1
           """,
           key ++ [generation, phase]
         ) do
      [[id, ^signature, ^matched]] ->
        id

      _ ->
        Txn.q(
          txn,
          """
          INSERT INTO recurrence_suppression_fact_observations
            (statute,targetSession,subject,fingerprintDigest,generation,phase,signature,matched)
          VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
          """,
          key ++ [generation, phase, signature, matched]
        )

        [[id]] = Txn.q(txn, "SELECT last_insert_rowid()")
        id
    end
  end

  defp evidence_signature(evidence) do
    :crypto.hash(:sha256, :erlang.term_to_binary(evidence, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp evidence_matches?(%{matched: true}), do: true
  defp evidence_matches?(_), do: false

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
