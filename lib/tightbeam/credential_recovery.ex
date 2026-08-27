defmodule Tightbeam.CredentialRecovery do
  @moduledoc """
  Durable per-session recovery after a provider credential activation.

  An activation snapshots every active session on the activated host whose
  recorded harness uses that provider. Each target owns at most one ordinary
  prompt carrier at a time. A later activation joins that carrier instead of
  creating another turn; a terminal carrier either covers the joined
  generation or opens the next cycle.
  """

  alias Tightbeam.{DB, EventLog, Harness, Ledger, SessionLane, Wakes}
  alias Tightbeam.DB.Txn

  defmodule ReconciliationPending do
    defexception [:message]
  end

  @process "process:tightbeam"
  @retry_delays [5_000, 30_000, 120_000]

  @ddl """
  CREATE TABLE IF NOT EXISTS credential_recovery_activations (
    activationId TEXT PRIMARY KEY,
    host TEXT NOT NULL,
    provider TEXT NOT NULL,
    credentialKind TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK (generation > 0),
    state TEXT NOT NULL CHECK (state IN (
      'prepared','credential_installed','metadata_committed','adapter_started',
      'activation_ready','recovering','complete','failed'
    )),
    preparedAt INTEGER NOT NULL,
    installedAt INTEGER,
    metadataAt INTEGER,
    adapterAt INTEGER,
    readyAt INTEGER,
    completedAt INTEGER,
    failure TEXT,
    adapterGenerations TEXT,
    cause TEXT NOT NULL,
    principal TEXT NOT NULL,
    UNIQUE (host, provider, generation)
  );
  CREATE INDEX IF NOT EXISTS credential_recovery_activation_scope
    ON credential_recovery_activations (host, provider, generation);

  CREATE TABLE IF NOT EXISTS credential_recovery_targets (
    targetId TEXT PRIMARY KEY,
    host TEXT NOT NULL,
    provider TEXT NOT NULL,
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    requiredGeneration INTEGER NOT NULL CHECK (requiredGeneration > 0),
    handledGeneration INTEGER NOT NULL DEFAULT 0 CHECK (handledGeneration >= 0),
    state TEXT NOT NULL CHECK (state IN (
      'pending','admitted','claimed','retry_wait','handled','retired',
      'no_longer_affected','undeliverable'
    )),
    cycle INTEGER NOT NULL CHECK (cycle > 0),
    attempt INTEGER NOT NULL CHECK (attempt BETWEEN 0 AND 3),
    reconciliationAttempt INTEGER NOT NULL DEFAULT 0 CHECK (reconciliationAttempt BETWEEN 0 AND 3),
    wakeId TEXT REFERENCES wakes(wakeId),
    turnSeq INTEGER REFERENCES turns(seq),
    coveredGeneration INTEGER CHECK (coveredGeneration > 0),
    dueAt INTEGER,
    failure TEXT,
    updatedAt INTEGER NOT NULL,
    cause TEXT NOT NULL,
    principal TEXT NOT NULL,
    UNIQUE (host, provider, sessionKey)
  );
  CREATE INDEX IF NOT EXISTS credential_recovery_target_state
    ON credential_recovery_targets (state, dueAt);

  CREATE TABLE IF NOT EXISTS credential_recovery_memberships (
    activationId TEXT NOT NULL REFERENCES credential_recovery_activations(activationId),
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    targetId TEXT NOT NULL REFERENCES credential_recovery_targets(targetId),
    generation INTEGER NOT NULL CHECK (generation > 0),
    adapterGeneration INTEGER CHECK (adapterGeneration > 0),
    resolution TEXT NOT NULL CHECK (resolution IN (
      'open','handled','retired','no_longer_affected','undeliverable'
    )),
    reconciliationState TEXT NOT NULL CHECK (reconciliationState IN (
      'not_required','pending','done','failed'
    )),
    reconciliationResult TEXT CHECK (reconciliationResult IS NULL OR reconciliationResult IN (
      'delivered','could_not_run','run_failed','run_canceled','outcome_unknown'
    )),
    reconciliationTurnSeq INTEGER REFERENCES turns(seq),
    resolvedCycle INTEGER,
    resolvedTurnSeq INTEGER REFERENCES turns(seq),
    resolvedAt INTEGER,
    cause TEXT NOT NULL,
    principal TEXT NOT NULL,
    PRIMARY KEY (activationId, sessionKey)
  );
  CREATE INDEX IF NOT EXISTS credential_recovery_membership_target
    ON credential_recovery_memberships (targetId, generation, resolution);
  """

  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc "Replay unfinished recovery from durable rows during gateway boot."
  def recover(db \\ Tightbeam.DB) do
    {:ok, activations} =
      DB.query(
        db,
        "SELECT activationId,state,adapterGenerations FROM credential_recovery_activations WHERE state IN ('activation_ready','recovering') ORDER BY host,provider,generation"
      )

    Enum.each(activations, fn [activation_id, state, encoded_generations] ->
      plan =
        if state == "activation_ready" do
          with {:ok, generations} <- JSON.decode(encoded_generations || "{}"),
               {:ok, _result} <- activation_ready(db, activation_id, generations) do
            :ok
          end
        else
          :ok
        end

      with :ok <- plan,
           {:ok, _result} <- reconcile_ready_activation(db, activation_id) do
        :ok
      else
        {:error, reason} ->
          EventLog.lifecycle(
            db,
            "credential_recovery_replay_failed",
            activation_id,
            inspect(reason)
          )
      end
    end)

    {:ok, claimed} =
      DB.query(
        db,
        "SELECT targetId,turnSeq FROM credential_recovery_targets WHERE state='claimed' AND turnSeq IS NOT NULL ORDER BY targetId"
      )

    Enum.each(claimed, fn [_target_id, seq] ->
      terminalize_claimed_after_crash(db, seq)
      turn_terminal(db, seq)
    end)

    {:ok, pending} =
      DB.query(
        db,
        "SELECT targetId FROM credential_recovery_targets WHERE state='pending' AND wakeId IS NULL ORDER BY targetId"
      )

    Enum.each(pending, fn [target_id] ->
      {:ok, :ok} =
        DB.transaction(db, fn txn ->
          materialize_if_needed(txn, nil, target_id)
          :ok
        end)
    end)

    :ok
  end

  @doc "Create the activation record before credential mutation starts."
  def prepare(db, host, provider, credential_kind, opts \\ []) do
    provider = to_string(provider)
    credential_kind = to_string(credential_kind)
    activation_id = "cra_" <> Tightbeam.Id.uuid4()
    at = now()
    cause = Keyword.get(opts, :cause, "provider-onboard-finish")
    principal = Keyword.get(opts, :principal, @process)

    DB.transaction(db, fn txn ->
      [[generation]] =
        Txn.q(
          txn,
          "SELECT COALESCE(MAX(generation), 0) + 1 FROM credential_recovery_activations WHERE host=?1 AND provider=?2",
          [host, provider]
        )

      Txn.q(
        txn,
        """
        INSERT INTO credential_recovery_activations
          (activationId,host,provider,credentialKind,generation,state,preparedAt,cause,principal)
        VALUES (?1,?2,?3,?4,?5,'prepared',?6,?7,?8)
        """,
        [activation_id, host, provider, credential_kind, generation, at, cause, principal]
      )

      audit(
        txn,
        "credential_recovery_prepared",
        activation_id,
        "host=#{host} provider=#{provider} generation=#{generation}"
      )

      %{activation_id: activation_id, generation: generation}
    end)
  end

  @doc "Advance one observed credential-activation edge."
  def edge(db, activation_id, edge)
      when edge in [:credential_installed, :metadata_committed, :adapter_started] do
    {from, state, column} =
      case edge do
        :credential_installed -> {"prepared", "credential_installed", "installedAt"}
        :metadata_committed -> {"credential_installed", "metadata_committed", "metadataAt"}
        :adapter_started -> {"metadata_committed", "adapter_started", "adapterAt"}
      end

    transition(db, activation_id, from, state, column)
  end

  @doc "Record that every successful activation edge, including resume, completed."
  def mark_ready(db, activation_id, adapter_generations) when is_map(adapter_generations) do
    affected_harnesses(adapter_generations)
    encoded = JSON.encode!(adapter_generations)

    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        "UPDATE credential_recovery_activations SET state='activation_ready',readyAt=?2,adapterGenerations=?3 WHERE activationId=?1 AND state='adapter_started'",
        [activation_id, now(), encoded]
      )

      if Txn.changes(txn) != 1,
        do: raise("credential_recovery_ready_transition_refused activation=#{activation_id}")

      audit(txn, "credential_recovery_activation_ready", activation_id, nil)
      :ok
    end)
  end

  @doc "Fail a prepared activation without scheduling recovery work."
  def fail(db, activation_id, reason) do
    detail = failure_code(reason)

    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        "UPDATE credential_recovery_activations SET state='failed',failure=?2,completedAt=?3 WHERE activationId=?1 AND state NOT IN ('complete','failed')",
        [activation_id, detail, now()]
      )

      audit(txn, "credential_recovery_failed", activation_id, detail)
      :ok
    end)
  end

  @doc "Publish immutable memberships and materialize one carrier per target."
  def activation_ready(db, activation_id, adapter_generations) when is_map(adapter_generations) do
    harnesses = affected_harnesses(adapter_generations)
    at = now()

    case DB.transaction(db, fn txn ->
           [[host, provider, generation, "activation_ready"]] =
             Txn.q(
               txn,
               "SELECT host,provider,generation,state FROM credential_recovery_activations WHERE activationId=?1",
               [activation_id]
             )

           sessions = affected_sessions(txn, host, provider, harnesses)

           Enum.each(sessions, fn [session_key, harness] ->
             adapter_generation = Map.fetch!(adapter_generations, harness)
             target_id = target_id(host, provider, session_key)

             ensure_target(txn, target_id, host, provider, session_key, generation, at)

             ensure_membership(
               txn,
               activation_id,
               target_id,
               session_key,
               generation,
               adapter_generation
             )

             materialize_if_needed(txn, activation_id, target_id)
           end)

           state = if sessions == [], do: "complete", else: "recovering"
           completed_at = if state == "complete", do: at, else: nil

           Txn.q(
             txn,
             "UPDATE credential_recovery_activations SET state=?2,completedAt=?3 WHERE activationId=?1 AND state='activation_ready'",
             [activation_id, state, completed_at]
           )

           audit(
             txn,
             "credential_recovery_ready",
             activation_id,
             "targets=#{length(sessions)} state=#{state}"
           )

           %{activation_id: activation_id, state: state, target_count: length(sessions)}
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:recovery_publication_failed, reason}}
    end
  end

  @doc "Terminalize every pre-activation running turn without waiting for its old adapter callback."
  def reconcile_ready_activation(db, activation_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT targetId,sessionKey,reconciliationTurnSeq
        FROM credential_recovery_memberships
        WHERE activationId=?1 AND reconciliationState='pending'
        ORDER BY targetId,sessionKey
        """,
        [activation_id]
      )

    reconciled =
      Enum.map(rows, fn [target_id, session_key, seq] ->
        result =
          DB.transaction(db, fn txn ->
            reconcile_running_in_txn(txn, activation_id, session_key, seq)
          end)

        case result do
          {:ok, disposition} ->
            SessionLane.release_terminalized(session_key, seq)
            {:ok, target_id, disposition}

          {:error, reason} ->
            {:error, target_id, reason}
        end
      end)

    failures = Enum.filter(reconciled, &match?({:error, _, _}, &1))

    if failures == [] do
      target_ids = rows |> Enum.map(&hd/1) |> Enum.uniq()

      Enum.each(target_ids, fn target_id ->
        {:ok, :ok} =
          DB.transaction(db, fn txn ->
            materialize_if_needed(txn, activation_id, target_id)
            :ok
          end)
      end)

      {:ok,
       %{
         reconciliation_state: "reconciled",
         reconciled_count: length(rows),
         reconciliation_counts: reconciliation_counts(db, activation_id)
       }}
    else
      {:error, {:reconciliation_failed, failures}}
    end
  end

  @doc "Persist the first bounded reconciliation retry without creating a carrier."
  def defer_reconciliation(db, activation_id, reason) do
    DB.transaction(db, fn txn ->
      targets =
        Txn.q(
          txn,
          "SELECT DISTINCT targetId FROM credential_recovery_memberships WHERE activationId=?1 AND reconciliationState='pending' ORDER BY targetId",
          [activation_id]
        )

      Enum.each(targets, fn [target_id] ->
        [[session_key, cycle]] =
          Txn.q(
            txn,
            "SELECT sessionKey,cycle FROM credential_recovery_targets WHERE targetId=?1",
            [target_id]
          )

        due_at = now() + hd(@retry_delays)
        wake_id = reconciliation_wake_id(target_id, cycle, 1)

        Wakes.schedule_in_txn(txn, %{
          wake_id: wake_id,
          session_key: session_key,
          origin: @process,
          consumer: "credential_recovery_retry",
          prompt: target_id,
          due_at: due_at,
          condition_scope: target_id,
          target_gate: 1,
          sender_scheduled: true
        })

        Txn.q(
          txn,
          "UPDATE credential_recovery_targets SET state='retry_wait',reconciliationAttempt=1,dueAt=?2,failure=?3,updatedAt=?4 WHERE targetId=?1 AND state IN ('pending','admitted')",
          [target_id, due_at, "reconciliation_failed:#{failure_code(reason)}", now()]
        )

        Txn.q(
          txn,
          "UPDATE wakes SET dueAt=?2 WHERE wakeId=(SELECT wakeId FROM credential_recovery_targets WHERE targetId=?1) AND state='pending'",
          [target_id, due_at + 1]
        )

        audit(
          txn,
          "credential_recovery_reconciliation_retry_wait",
          target_id,
          "attempt=1 dueAt=#{due_at}"
        )
      end)

      :ok
    end)
  end

  @doc "Bind a delivered recovery carrier to its ordinary queued turn."
  def admit_in_txn(%Txn{} = txn, wake_id, seq) when is_binary(wake_id) do
    case Txn.q(
           txn,
           "SELECT targetId,state FROM credential_recovery_targets WHERE wakeId=?1",
           [wake_id]
         ) do
      [[target_id, "pending"]] ->
        Txn.q(
          txn,
          "UPDATE credential_recovery_targets SET state='admitted',turnSeq=?2,updatedAt=?3 WHERE targetId=?1 AND state='pending'",
          [target_id, seq, now()]
        )

        audit(txn, "credential_recovery_admitted", target_id, "wakeId=#{wake_id} turnSeq=#{seq}")
        :ok

      [] ->
        :ordinary

      [[_target_id, _state]] ->
        :ok
    end
  end

  def admit_in_txn(%Txn{}, _wake_id, _seq), do: :ordinary

  @doc "Revalidate a recovery carrier against its exact durable scope before admission."
  def admissible_in_txn(%Txn{} = txn, wake_id) when is_binary(wake_id) do
    case scoped_target(txn, wake_id) do
      :ordinary ->
        true

      {:ok, target} ->
        case Txn.q(
               txn,
               "SELECT 1 FROM credential_recovery_memberships WHERE targetId=?1 AND reconciliationState='pending' LIMIT 1",
               [target.id]
             ) do
          [] -> true
          _ -> raise ReconciliationPending, message: "credential recovery reconciliation pending"
        end

      {:dispose, target, disposition} ->
        dispose_target(txn, target, disposition, "admission")
        false
    end
  end

  def admissible_in_txn(%Txn{}, _wake_id), do: true

  @doc "Dispose a carrier whose target failed the ordinary active-session gate."
  def unavailable_in_txn(%Txn{} = txn, wake_id) when is_binary(wake_id) do
    case Txn.q(
           txn,
           "SELECT targetId,sessionKey,cycle FROM credential_recovery_targets WHERE wakeId=?1 AND state IN ('pending','admitted')",
           [wake_id]
         ) do
      [[target_id, session_key, cycle]] ->
        disposition =
          case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [session_key]) do
            [["retired"]] -> "retired"
            _ -> "no_longer_affected"
          end

        at = now()

        Txn.q(
          txn,
          "UPDATE credential_recovery_targets SET state=?2,failure=?2,updatedAt=?3 WHERE targetId=?1",
          [target_id, disposition, at]
        )

        Txn.q(
          txn,
          "UPDATE credential_recovery_memberships SET resolution=?2,resolvedCycle=?3,resolvedAt=?4 WHERE targetId=?1 AND resolution='open'",
          [target_id, disposition, cycle, at]
        )

        cancel_target_wake(txn, target_id, "target_unresolvable")
        complete_activations(txn, target_id)
        audit(txn, "credential_recovery_#{disposition}", target_id, "wakeId=#{wake_id}")
        disposition

      [] ->
        :ordinary
    end
  end

  def unavailable_in_txn(%Txn{}, _wake_id), do: :ordinary

  @doc "Close every open recovery membership when its target session retires."
  def session_retired(db, session_key) do
    DB.transaction(db, fn txn ->
      targets =
        Txn.q(
          txn,
          "SELECT targetId,cycle FROM credential_recovery_targets WHERE sessionKey=?1 AND state IN ('pending','admitted','claimed','retry_wait') ORDER BY targetId",
          [session_key]
        )

      Enum.each(targets, fn [target_id, cycle] ->
        at = now()

        Txn.q(
          txn,
          "UPDATE credential_recovery_targets SET state='retired',failure='retired',updatedAt=?2 WHERE targetId=?1",
          [target_id, at]
        )

        Txn.q(
          txn,
          "UPDATE credential_recovery_memberships SET resolution='retired',resolvedCycle=?2,resolvedAt=?3 WHERE targetId=?1 AND resolution='open'",
          [target_id, cycle, at]
        )

        cancel_target_wake(txn, target_id, "target_unresolvable")
        complete_activations(txn, target_id)
        audit(txn, "credential_recovery_retired", target_id, "session=#{session_key}")
      end)

      :ok
    end)
  end

  @doc "Stamp the activation generation covered when a carrier is claimed."
  def claim_in_txn(%Txn{} = txn, wake_id, seq) when is_binary(wake_id) do
    case scoped_target(txn, wake_id) do
      {:ok, %{id: target_id, state: state, generation: generation}}
      when state in ["pending", "admitted"] ->
        pending? =
          Txn.q(
            txn,
            "SELECT 1 FROM credential_recovery_memberships WHERE targetId=?1 AND reconciliationState='pending' LIMIT 1",
            [target_id]
          ) != []

        if pending? do
          {:retry, "reconciliation_pending"}
        else
          Txn.q(
            txn,
            "UPDATE credential_recovery_targets SET state='claimed',turnSeq=?2,coveredGeneration=?3,updatedAt=?4 WHERE targetId=?1 AND state IN ('pending','admitted')",
            [target_id, seq, generation, now()]
          )

          audit(
            txn,
            "credential_recovery_claimed",
            target_id,
            "turnSeq=#{seq} coveredGeneration=#{generation}"
          )

          :ok
        end

      :ordinary ->
        :ordinary

      {:dispose, target, disposition} ->
        dispose_target(txn, target, disposition, "claim")
        {:dispose, disposition}

      _ ->
        :ok
    end
  end

  def claim_in_txn(%Txn{}, _wake_id, _seq), do: :ordinary

  @doc "Consume an ordinary carrier terminal and advance or retry its target."
  def turn_terminal(db, seq) do
    result =
      DB.transaction(db, fn txn ->
        case target_for_turn(txn, seq) do
          nil ->
            :ordinary

          target ->
            settle_terminal(txn, target, seq)
        end
      end)

    case result do
      {:ok, %{fire?: true} = reply} -> {:ok, reply}
      {:ok, reply} -> {:ok, reply}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Durable retry timer consumer. Reserves the next attempt before its carrier exists."
  def retry_due(db, wake) do
    target_id = wake.condition_scope || wake.prompt

    case DB.query(
           db,
           "SELECT failure FROM credential_recovery_targets WHERE targetId=?1",
           [target_id]
         ) do
      {:ok, [[failure]]} when is_binary(failure) ->
        if String.starts_with?(failure, "reconciliation_failed:"),
          do: retry_reconciliation(db, wake, target_id),
          else: retry_carrier(db, wake, target_id)

      _ ->
        retry_carrier(db, wake, target_id)
    end
  end

  defp retry_carrier(db, wake, target_id) do
    current_time = now()

    DB.transaction(db, fn txn ->
      case Txn.q(
             txn,
             "SELECT state,attempt,dueAt FROM credential_recovery_targets WHERE targetId=?1",
             [target_id]
           ) do
        [["retry_wait", attempt, due_at]] when due_at <= current_time and attempt < 3 ->
          next_attempt = attempt + 1

          Txn.q(
            txn,
            "UPDATE credential_recovery_targets SET state='pending',attempt=?2,dueAt=NULL,wakeId=NULL,turnSeq=NULL,coveredGeneration=NULL,updatedAt=?3 WHERE targetId=?1 AND state='retry_wait' AND attempt=?4",
            [target_id, next_attempt, now(), attempt]
          )

          materialize_if_needed(txn, nil, target_id)
          consume_internal_wake(txn, wake.wake_id)

          audit(txn, "credential_recovery_retry_reserved", target_id, "attempt=#{next_attempt}")
          :ok

        _ ->
          consume_internal_wake(txn, wake.wake_id)

          :stale
      end
    end)
  end

  defp retry_reconciliation(db, wake, target_id) do
    {:ok, activation_rows} =
      DB.query(
        db,
        "SELECT activationId FROM credential_recovery_memberships WHERE targetId=?1 AND reconciliationState='pending' ORDER BY generation",
        [target_id]
      )

    failures =
      activation_rows
      |> Enum.map(fn [activation_id] -> reconcile_ready_activation(db, activation_id) end)
      |> Enum.filter(&match?({:error, _}, &1))

    DB.transaction(db, fn txn ->
      if failures == [] do
        Txn.q(
          txn,
          "UPDATE credential_recovery_targets SET state='pending',dueAt=NULL,failure=NULL,updatedAt=?2 WHERE targetId=?1 AND state='retry_wait'",
          [target_id, now()]
        )

        materialize_if_needed(txn, nil, target_id)
        consume_internal_wake(txn, wake.wake_id)
        audit(txn, "credential_recovery_reconciliation_recovered", target_id, nil)
      else
        [[attempt]] =
          Txn.q(
            txn,
            "SELECT reconciliationAttempt FROM credential_recovery_targets WHERE targetId=?1",
            [target_id]
          )

        if attempt < 3 do
          next_attempt = attempt + 1
          due_at = now() + Enum.at(@retry_delays, attempt)

          Txn.q(
            txn,
            "UPDATE credential_recovery_targets SET reconciliationAttempt=?2,dueAt=?3,failure=?4,updatedAt=?5 WHERE targetId=?1 AND state='retry_wait'",
            [
              target_id,
              next_attempt,
              due_at,
              "reconciliation_failed:#{failure_code(failures)}",
              now()
            ]
          )

          Txn.q(txn, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1 AND state='pending'", [
            wake.wake_id,
            due_at
          ])

          Txn.q(
            txn,
            "UPDATE wakes SET dueAt=?2 WHERE wakeId=(SELECT wakeId FROM credential_recovery_targets WHERE targetId=?1) AND state='pending'",
            [target_id, due_at + 1]
          )

          audit(
            txn,
            "credential_recovery_reconciliation_retry_wait",
            target_id,
            "attempt=#{next_attempt} dueAt=#{due_at}"
          )
        else
          Txn.q(
            txn,
            "UPDATE credential_recovery_memberships SET reconciliationState='failed',reconciliationResult='could_not_run' WHERE targetId=?1 AND reconciliationState='pending'",
            [target_id]
          )

          dispose_target(txn, %{id: target_id}, "undeliverable", "reconciliation-attempt-3")
          consume_internal_wake(txn, wake.wake_id)
        end
      end

      :ok
    end)
  end

  @doc "Persistent, privacy-bounded recovery readback."
  def readback(db, activation_id) do
    case DB.query(
           db,
           "SELECT host,provider,credentialKind,generation,state,preparedAt,readyAt,completedAt,failure FROM credential_recovery_activations WHERE activationId=?1",
           [activation_id]
         ) do
      {:ok, [[host, provider, kind, generation, state, prepared, ready, completed, failure]]} ->
        {:ok, rows} =
          DB.query(
            db,
            """
            SELECT m.sessionKey,m.generation,m.resolution,m.reconciliationState,
                   m.reconciliationResult,
                   t.state,t.cycle,t.attempt,t.reconciliationAttempt,t.turnSeq,t.dueAt,t.failure
            FROM credential_recovery_memberships m
            JOIN credential_recovery_targets t ON t.targetId=m.targetId
            WHERE m.activationId=?1 ORDER BY m.sessionKey
            """,
            [activation_id]
          )

        %{
          activation_id: activation_id,
          host: host,
          provider: provider,
          credential_kind: kind,
          generation: generation,
          state: state,
          prepared_at: prepared,
          ready_at: ready,
          completed_at: completed,
          failure: failure,
          targets:
            Enum.map(rows, fn [
                                session,
                                member_gen,
                                resolution,
                                reconciliation,
                                reconciliation_result,
                                target_state,
                                cycle,
                                attempt,
                                reconciliation_attempt,
                                turn_seq,
                                due_at,
                                target_failure
                              ] ->
              %{
                session_key: session,
                generation: member_gen,
                resolution: resolution,
                reconciliation: reconciliation,
                reconciliation_result: reconciliation_result,
                state: target_state,
                cycle: cycle,
                attempt: attempt,
                reconciliation_attempt: reconciliation_attempt,
                turn_seq: turn_seq,
                due_at: due_at,
                failure: target_failure
              }
            end)
        }

      {:ok, []} ->
        nil
    end
  end

  @doc "Count persistent reconciliation states for one activation."
  def reconciliation_counts(db, activation_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT reconciliationState,COUNT(*) FROM credential_recovery_memberships WHERE activationId=?1 GROUP BY reconciliationState ORDER BY reconciliationState",
        [activation_id]
      )

    Map.new(rows, fn [state, count] -> {state, count} end)
  end

  defp transition(db, activation_id, from, state, column) do
    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        "UPDATE credential_recovery_activations SET state=?2,#{column}=?3 WHERE activationId=?1 AND state=?4",
        [activation_id, state, now(), from]
      )

      if Txn.changes(txn) != 1,
        do:
          raise(
            "credential_recovery_transition_refused activation=#{activation_id} expected=#{from}"
          )

      audit(txn, "credential_recovery_#{state}", activation_id, nil)
      :ok
    end)
  end

  defp affected_harnesses(adapter_generations) do
    configured =
      Harness.all()
      |> Map.new(fn harness ->
        {harness.wire_name(), to_string(harness.credential_provider())}
      end)

    Enum.each(adapter_generations, fn {wire, generation} ->
      unless Map.has_key?(configured, wire) and is_integer(generation) and generation > 0 do
        raise ArgumentError, "invalid activated adapter generation for #{inspect(wire)}"
      end
    end)

    Map.keys(adapter_generations)
  end

  defp affected_sessions(_txn, _host, _provider, []), do: []

  defp affected_sessions(txn, host, provider, harnesses) do
    placeholders = Enum.map_join(1..length(harnesses), ",", &"?#{&1 + 2}")

    rows =
      Txn.q(
        txn,
        "SELECT sessionKey,harness FROM sessions WHERE host=?1 AND provider=?2 AND state='active' AND harness IN (#{placeholders}) ORDER BY sessionKey",
        [host, provider | harnesses]
      )

    Enum.filter(rows, fn [_session, wire] ->
      harness = Harness.parse!(wire)
      to_string(harness.credential_provider()) == provider
    end)
  end

  defp ensure_target(txn, target_id, host, provider, session_key, generation, at) do
    case Txn.q(
           txn,
           "SELECT state,cycle,requiredGeneration FROM credential_recovery_targets WHERE targetId=?1",
           [target_id]
         ) do
      [] ->
        Txn.q(
          txn,
          """
          INSERT INTO credential_recovery_targets
            (targetId,host,provider,sessionKey,requiredGeneration,state,cycle,attempt,updatedAt,cause,principal)
          VALUES (?1,?2,?3,?4,?5,'pending',1,0,?6,'activation-ready',?7)
          """,
          [target_id, host, provider, session_key, generation, at, @process]
        )

      [[state, _cycle, _old_generation]]
      when state in ["pending", "admitted", "claimed", "retry_wait"] ->
        Txn.q(
          txn,
          "UPDATE credential_recovery_targets SET requiredGeneration=?2,updatedAt=?3 WHERE targetId=?1",
          [target_id, generation, at]
        )

      [[state, cycle, _old_generation]]
      when state in ["handled", "undeliverable", "no_longer_affected"] ->
        Txn.q(
          txn,
          """
          UPDATE credential_recovery_targets
          SET requiredGeneration=?2,state='pending',cycle=?3,attempt=0,wakeId=NULL,
              turnSeq=NULL,coveredGeneration=NULL,dueAt=NULL,failure=NULL,updatedAt=?4,
              cause='later-activation',principal=?5
          WHERE targetId=?1
          """,
          [target_id, generation, cycle + 1, at, @process]
        )
    end
  end

  defp ensure_membership(
         txn,
         activation_id,
         target_id,
         session_key,
         generation,
         adapter_generation
       ) do
    {reconciliation, turn_seq} = prior_running(txn, session_key, adapter_generation)

    Txn.q(
      txn,
      """
      INSERT INTO credential_recovery_memberships
        (activationId,sessionKey,targetId,generation,adapterGeneration,resolution,
         reconciliationState,reconciliationTurnSeq,cause,principal)
      VALUES (?1,?2,?3,?4,?5,'open',?6,?7,'activation-membership',?8)
      """,
      [
        activation_id,
        session_key,
        target_id,
        generation,
        adapter_generation,
        reconciliation,
        turn_seq,
        @process
      ]
    )
  end

  defp prior_running(txn, session_key, adapter_generation) do
    case Txn.q(
           txn,
           """
           SELECT turns.seq,turns.adapterGen,
                  EXISTS (SELECT 1 FROM credential_recovery_targets t
                          WHERE t.turnSeq=turns.seq AND t.state='claimed')
           FROM turns WHERE sessionKey=?1 AND status='running' ORDER BY seq LIMIT 1
           """,
           [session_key]
         ) do
      [[_seq, _generation, 1]] ->
        {"not_required", nil}

      [[seq, generation, 0]] when is_integer(generation) and generation < adapter_generation ->
        {"pending", seq}

      [[seq, nil, 0]] ->
        {"pending", seq}

      _ ->
        {"not_required", nil}
    end
  end

  defp reconcile_running_in_txn(txn, activation_id, session_key, seq) do
    disposition =
      case Txn.q(
             txn,
             """
             SELECT turns.status,
                    (SELECT ownerLease FROM turn_lifecycle_events
                     WHERE turnSeq=turns.seq AND kind='claimed' ORDER BY ordinal DESC LIMIT 1)
             FROM turns WHERE turns.seq=?1 AND turns.sessionKey=?2
             """,
             [seq, session_key]
           ) do
        [["running", owner_lease]] when is_binary(owner_lease) ->
          lifecycle_started? =
            Txn.q(
              txn,
              "SELECT 1 FROM turn_lifecycle_events WHERE turnSeq=?1 AND ((kind='stage_started' AND stage='prompt') OR kind='prompt_dispatched') LIMIT 1",
              [seq]
            ) != []

          disposition = if lifecycle_started?, do: "outcome_unknown", else: "could_not_run"
          terminal = if lifecycle_started?, do: "failed_unknown", else: "failed"

          true =
            Ledger.finish_in_txn(
              txn,
              seq,
              terminal,
              "credential activation reconciled prior adapter generation",
              cause: "credential-recovery-reconciliation",
              principal: @process,
              owner_lease: owner_lease
            )

          disposition

        [[status, _owner_lease]]
        when status in ["delivered", "canceled", "failed", "failed_unknown"] ->
          terminal_disposition(txn, seq, status)

        [] ->
          raise "credential_recovery_reconciliation_turn_missing activation=#{activation_id} turn=#{seq}"
      end

    Txn.q(
      txn,
      "UPDATE credential_recovery_memberships SET reconciliationState='done',reconciliationResult=?4 WHERE activationId=?1 AND sessionKey=?2 AND reconciliationTurnSeq=?3 AND reconciliationState='pending'",
      [activation_id, session_key, seq, disposition]
    )

    audit(
      txn,
      "credential_recovery_reconciled",
      activation_id,
      "session=#{session_key} turnSeq=#{seq} disposition=#{disposition}"
    )

    disposition
  end

  defp terminalize_claimed_after_crash(db, seq) do
    DB.transaction(db, fn txn ->
      case Txn.q(
             txn,
             """
             SELECT turns.status,
                    (SELECT ownerLease FROM turn_lifecycle_events
                     WHERE turnSeq=turns.seq AND kind='claimed' ORDER BY ordinal DESC LIMIT 1)
             FROM turns WHERE turns.seq=?1
             """,
             [seq]
           ) do
        [["running", owner_lease]] when is_binary(owner_lease) ->
          Ledger.finish_in_txn(
            txn,
            seq,
            "failed_unknown",
            "gateway restart interrupted credential recovery carrier",
            cause: "credential-recovery-boot-replay",
            principal: @process,
            owner_lease: owner_lease
          )

        _ ->
          false
      end
    end)
  end

  defp scoped_target(txn, wake_id) do
    case Txn.q(
           txn,
           """
           SELECT t.targetId,t.sessionKey,t.host,t.provider,t.state,t.requiredGeneration,
                  s.state,s.host,s.provider,s.harness
           FROM credential_recovery_targets t
           LEFT JOIN sessions s ON s.sessionKey=t.sessionKey
           WHERE t.wakeId=?1
           """,
           [wake_id]
         ) do
      [] ->
        :ordinary

      [
        [
          target_id,
          session_key,
          host,
          provider,
          state,
          generation,
          session_state,
          session_host,
          session_provider,
          harness
        ]
      ] ->
        target = %{
          id: target_id,
          session: session_key,
          state: state,
          generation: generation
        }

        cond do
          session_state == "retired" or is_nil(session_state) ->
            {:dispose, target, "retired"}

          session_state != "active" or session_host != host or session_provider != provider or
              not harness_uses_provider?(harness, provider) ->
            {:dispose, target, "no_longer_affected"}

          true ->
            {:ok, target}
        end
    end
  end

  defp harness_uses_provider?(harness, provider) when is_binary(harness) do
    to_string(Harness.parse!(harness).credential_provider()) == provider
  end

  defp harness_uses_provider?(_harness, _provider), do: false

  defp dispose_target(txn, target, disposition, boundary) do
    [[cycle]] =
      Txn.q(txn, "SELECT cycle FROM credential_recovery_targets WHERE targetId=?1", [target.id])

    at = now()

    Txn.q(
      txn,
      "UPDATE credential_recovery_targets SET state=?2,failure=?2,updatedAt=?3 WHERE targetId=?1",
      [target.id, disposition, at]
    )

    Txn.q(
      txn,
      "UPDATE credential_recovery_memberships SET resolution=?2,resolvedCycle=?3,resolvedAt=?4 WHERE targetId=?1 AND resolution='open'",
      [target.id, disposition, cycle, at]
    )

    cancel_target_wake(txn, target.id, "target_unresolvable")

    complete_activations(txn, target.id)
    audit(txn, "credential_recovery_#{disposition}", target.id, "boundary=#{boundary}")
  end

  defp materialize_if_needed(txn, activation_id, target_id) do
    case Txn.q(
           txn,
           "SELECT sessionKey,host,provider,requiredGeneration,state,cycle,attempt,wakeId FROM credential_recovery_targets WHERE targetId=?1",
           [target_id]
         ) do
      [[session_key, host, provider, generation, "pending", cycle, attempt, nil]] ->
        pending_reconciliation =
          Txn.q(
            txn,
            "SELECT 1 FROM credential_recovery_memberships WHERE targetId=?1 AND reconciliationState='pending' LIMIT 1",
            [target_id]
          ) != []

        if not pending_reconciliation do
          wake_id = carrier_wake_id(target_id, cycle, attempt)
          activation_id = activation_id || newest_open_activation(txn, target_id)

          wake =
            Wakes.schedule_in_txn(txn, %{
              wake_id: wake_id,
              session_key: session_key,
              origin: @process,
              prompt: carrier_prompt(provider, host, activation_id, generation),
              consumer: "prompt",
              due_at: now(),
              target_gate: 1,
              sender_scheduled: true
            })

          Txn.q(
            txn,
            "UPDATE credential_recovery_targets SET wakeId=?2,updatedAt=?3 WHERE targetId=?1 AND state='pending' AND wakeId IS NULL",
            [target_id, wake.wake_id, now()]
          )

          audit(
            txn,
            "credential_recovery_carrier_materialized",
            target_id,
            "cycle=#{cycle} attempt=#{attempt} wakeId=#{wake.wake_id}"
          )
        end

      _ ->
        :ok
    end
  end

  defp newest_open_activation(txn, target_id) do
    [[activation_id]] =
      Txn.q(
        txn,
        "SELECT activationId FROM credential_recovery_memberships WHERE targetId=?1 AND resolution='open' ORDER BY generation DESC LIMIT 1",
        [target_id]
      )

    activation_id
  end

  defp target_for_turn(txn, seq) do
    case Txn.q(
           txn,
           """
           SELECT t.targetId,t.sessionKey,t.provider,t.requiredGeneration,t.coveredGeneration,
                  t.state,t.cycle,t.attempt,turns.status
           FROM credential_recovery_targets t
           JOIN turns ON turns.seq=t.turnSeq
           WHERE t.turnSeq=?1
           """,
           [seq]
         ) do
      [[target_id, session, provider, required, covered, state, cycle, attempt, terminal]] ->
        %{
          id: target_id,
          session: session,
          provider: provider,
          required: required,
          covered: covered,
          state: state,
          cycle: cycle,
          attempt: attempt,
          terminal: terminal
        }

      [] ->
        nil
    end
  end

  defp settle_terminal(txn, %{state: "claimed", terminal: "delivered"} = target, seq) do
    covered = target.covered || target.required
    at = now()

    Txn.q(
      txn,
      "UPDATE credential_recovery_memberships SET resolution='handled',resolvedCycle=?2,resolvedTurnSeq=?3,resolvedAt=?4 WHERE targetId=?1 AND resolution='open' AND generation<=?5",
      [target.id, target.cycle, seq, at, covered]
    )

    if target.required > covered do
      Txn.q(
        txn,
        "UPDATE credential_recovery_targets SET state='pending',handledGeneration=?2,cycle=?3,attempt=0,wakeId=NULL,turnSeq=NULL,coveredGeneration=NULL,updatedAt=?4 WHERE targetId=?1 AND state='claimed'",
        [target.id, covered, target.cycle + 1, at]
      )

      materialize_if_needed(txn, nil, target.id)
    else
      Txn.q(
        txn,
        "UPDATE credential_recovery_targets SET state='handled',handledGeneration=?2,updatedAt=?3 WHERE targetId=?1 AND state='claimed'",
        [target.id, covered, at]
      )
    end

    complete_activations(txn, target.id)
    audit(txn, "credential_recovery_handled", target.id, "turnSeq=#{seq} generation=#{covered}")

    %{
      fire?: target.required > covered,
      state: if(target.required > covered, do: "pending", else: "handled")
    }
  end

  defp settle_terminal(txn, %{state: state} = target, seq)
       when state in ["pending", "admitted", "claimed"] do
    disposition = terminal_disposition(txn, seq, target.terminal)

    case {disposition, target.attempt} do
      {"could_not_run", attempt} when attempt < 3 ->
        due_at = now() + Enum.at(@retry_delays, attempt)
        timer_wake_id = retry_wake_id(target.id, target.cycle, attempt + 1)

        Wakes.schedule_in_txn(txn, %{
          wake_id: timer_wake_id,
          session_key: target.session,
          origin: @process,
          consumer: "credential_recovery_retry",
          prompt: target.id,
          due_at: due_at,
          condition_scope: target.id,
          target_gate: 1,
          sender_scheduled: true
        })

        Txn.q(
          txn,
          "UPDATE credential_recovery_targets SET state='retry_wait',dueAt=?2,wakeId=NULL,turnSeq=NULL,coveredGeneration=NULL,failure=?3,updatedAt=?4 WHERE targetId=?1",
          [target.id, due_at, disposition, now()]
        )

        audit(
          txn,
          "credential_recovery_retry_wait",
          target.id,
          "attempt=#{attempt} nextAttempt=#{attempt + 1} dueAt=#{due_at}"
        )

        %{fire?: false, state: "retry_wait"}

      _ ->
        Txn.q(
          txn,
          "UPDATE credential_recovery_targets SET state='undeliverable',failure=?2,updatedAt=?3 WHERE targetId=?1",
          [target.id, disposition, now()]
        )

        Txn.q(
          txn,
          "UPDATE credential_recovery_memberships SET resolution='undeliverable',resolvedCycle=?2,resolvedTurnSeq=?3,resolvedAt=?4 WHERE targetId=?1 AND resolution='open'",
          [target.id, target.cycle, seq, now()]
        )

        complete_activations(txn, target.id)

        audit(
          txn,
          "credential_recovery_undeliverable",
          target.id,
          "turnSeq=#{seq} disposition=#{disposition}"
        )

        %{fire?: false, state: "undeliverable"}
    end
  end

  defp settle_terminal(_txn, _target, _seq), do: :stale

  defp terminal_disposition(txn, seq, "failed") do
    prompt_started? =
      Txn.q(
        txn,
        "SELECT 1 FROM turn_lifecycle_events WHERE turnSeq=?1 AND ((kind='stage_started' AND stage='prompt') OR kind='prompt_dispatched') LIMIT 1",
        [seq]
      ) != []

    if prompt_started?, do: "run_failed", else: "could_not_run"
  end

  defp terminal_disposition(_txn, _seq, "failed_unknown"), do: "outcome_unknown"
  defp terminal_disposition(_txn, _seq, "canceled"), do: "run_canceled"
  defp terminal_disposition(_txn, _seq, terminal), do: terminal

  defp complete_activations(txn, target_id) do
    activation_ids =
      Txn.q(
        txn,
        "SELECT DISTINCT activationId FROM credential_recovery_memberships WHERE targetId=?1",
        [target_id]
      )

    Enum.each(activation_ids, fn [activation_id] ->
      open? =
        Txn.q(
          txn,
          "SELECT 1 FROM credential_recovery_memberships WHERE activationId=?1 AND resolution='open' LIMIT 1",
          [activation_id]
        ) != []

      unless open? do
        Txn.q(
          txn,
          "UPDATE credential_recovery_activations SET state='complete',completedAt=?2 WHERE activationId=?1 AND state='recovering'",
          [activation_id, now()]
        )
      end
    end)
  end

  defp carrier_prompt(provider, host, activation_id, generation) do
    "Provider #{provider} credential activation #{activation_id} generation #{generation} completed on host #{host}. " <>
      "A later activation can coalesce into this recovery obligation. Read the current credential-recovery target readback for this provider and host, then read your own open assignments and durable continuation facts. " <>
      "Inspect the work you judge was blocked by the credential outage. Resume that work or file its lawful disposition, and preserve unrelated work."
  end

  defp target_id(host, provider, session_key),
    do: "crt_" <> digest("#{host}\0#{provider}\0#{session_key}")

  defp carrier_wake_id(target_id, cycle, attempt),
    do: "w_cr_" <> digest("#{target_id}\0#{cycle}\0#{attempt}")

  defp retry_wake_id(target_id, cycle, attempt),
    do: "w_crt_" <> digest("#{target_id}\0#{cycle}\0#{attempt}")

  defp reconciliation_wake_id(target_id, cycle, attempt),
    do: "w_crr_" <> digest("#{target_id}\0#{cycle}\0#{attempt}")

  defp consume_internal_wake(txn, wake_id) when is_binary(wake_id) do
    Txn.q(
      txn,
      "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending'",
      [wake_id, now()]
    )
  end

  defp consume_internal_wake(_txn, _wake_id), do: :ok

  defp cancel_target_wake(txn, target_id, reason_kind) do
    case Txn.q(
           txn,
           "SELECT wakeId FROM credential_recovery_targets WHERE targetId=?1 AND wakeId IS NOT NULL",
           [target_id]
         ) do
      [[wake_id]] ->
        Wakes.cancel_in_txn(txn, %{
          wake_id: wake_id,
          requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
          reason_kind: reason_kind,
          causal_source: %{kind: "scheduler_delivery", id: wake_id},
          outcome: %{kind: "no_replacement"}
        })

      [] ->
        false
    end
  end

  defp digest(value) do
    :crypto.hash(:sha256, value)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 24)
  end

  defp audit(txn, kind, subject, detail),
    do: EventLog.lifecycle_in_txn(txn, kind, subject, detail)

  defp failure_code(value) when is_atom(value), do: Atom.to_string(value)
  defp failure_code({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_code(%{code: code}) when is_atom(code) or is_binary(code), do: to_string(code)
  defp failure_code(_value), do: "operation_failed"

  defp now, do: System.system_time(:millisecond)
end
