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
    adapterPublications TEXT,
    adapterPublishedAt INTEGER,
    resumeAt INTEGER,
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
    attemptState TEXT NOT NULL CHECK (attemptState IN (
      'reserved','materialized','claimed','terminal','not_admitted_cycle_closed'
    )),
    reconciliationGeneration INTEGER NOT NULL DEFAULT 0 CHECK (reconciliationGeneration >= 0),
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
    snapshotHost TEXT NOT NULL,
    snapshotHarness TEXT NOT NULL,
    adapterGeneration INTEGER CHECK (adapterGeneration > 0),
    adapterPublishedAt INTEGER,
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
    reconciliationCycle INTEGER NOT NULL CHECK (reconciliationCycle > 0),
    resolvedCycle INTEGER,
    resolvedTurnSeq INTEGER REFERENCES turns(seq),
    resolvedAt INTEGER,
    cause TEXT NOT NULL,
    principal TEXT NOT NULL,
    PRIMARY KEY (activationId, sessionKey)
  );
  CREATE INDEX IF NOT EXISTS credential_recovery_membership_target
    ON credential_recovery_memberships (targetId, generation, resolution);

  CREATE TABLE IF NOT EXISTS credential_recovery_transition_audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    kind TEXT NOT NULL,
    subject TEXT NOT NULL,
    causeKind TEXT NOT NULL,
    causeRowId TEXT NOT NULL,
    principal TEXT NOT NULL,
    detail TEXT
  );
  CREATE INDEX IF NOT EXISTS credential_recovery_transition_audit_subject
    ON credential_recovery_transition_audit (subject, id);
  """

  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc "Replay unfinished recovery from durable rows during gateway boot."
  def recover(db \\ Tightbeam.DB) do
    {:ok, interrupted} =
      DB.query(
        db,
        "SELECT activationId,state,adapterGenerations,adapterPublications,resumeAt FROM credential_recovery_activations WHERE state IN ('prepared','credential_installed','metadata_committed','adapter_started') ORDER BY host,provider,generation"
      )

    Enum.each(interrupted, fn
      [activation_id, "metadata_committed", encoded_generations, encoded_publications, resume_at] ->
        case decode_adapter_proof(encoded_generations, encoded_publications) do
          {:ok, generations, _publications}
          when map_size(generations) > 0 and is_integer(resume_at) ->
            with {:ok, :ok} <- edge(db, activation_id, :adapter_started),
                 {:ok, :ok} <- mark_ready(db, activation_id, generations) do
              :ok
            else
              {:error, reason} ->
                fail(db, activation_id, {:boot_metadata_committed_replay_failed, reason})
            end

          {:ok, _generations, _publications} ->
            fail(db, activation_id, :resume_not_proven_after_metadata_committed)

          {:error, reason} ->
            fail(db, activation_id, reason)
        end

      [activation_id, "adapter_started", encoded_generations, _encoded_publications, _resume_at] ->
        case JSON.decode(encoded_generations || "") do
          {:ok, generations} when is_map(generations) ->
            case mark_ready(db, activation_id, generations) do
              {:ok, :ok} -> :ok
              {:error, reason} -> fail(db, activation_id, {:boot_ready_replay_failed, reason})
            end

          _ ->
            fail(db, activation_id, :adapter_generations_missing_after_adapter_started)
        end

      [activation_id, state, _encoded_generations, _encoded_publications, _resume_at] ->
        fail(db, activation_id, %{code: "credential_activation_interrupted_#{state}"})
    end)

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

    {:ok, closed_attempts} =
      DB.query(
        db,
        "SELECT turnSeq FROM credential_recovery_targets WHERE state='pending' AND attemptState='not_admitted_cycle_closed' AND turnSeq IS NOT NULL ORDER BY targetId"
      )

    Enum.each(closed_attempts, fn [seq] ->
      turn_terminal(db, seq)
    end)

    {:ok, due_reconciliations} =
      DB.query(
        db,
        """
        SELECT t.targetId,w.wakeId
        FROM credential_recovery_targets t
        JOIN wakes w ON w.conditionScope=t.targetId
        WHERE t.state='retry_wait' AND t.dueAt<=?1
          AND t.failure LIKE 'reconciliation_failed:%'
          AND w.consumer='credential_recovery_retry' AND w.state='pending'
        ORDER BY t.targetId,w.wakeId
        """,
        [now()]
      )

    Enum.each(due_reconciliations, fn [target_id, wake_id] ->
      retry_reconciliation(db, %{wake_id: wake_id}, target_id)
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
    case edge do
      :credential_installed ->
        transition(db, activation_id, "prepared", "credential_installed", "installedAt")

      :metadata_committed ->
        transition(
          db,
          activation_id,
          "credential_installed",
          "metadata_committed",
          "metadataAt"
        )

      :adapter_started ->
        transition_adapter_started(db, activation_id)
    end
  end

  def edge(db, activation_id, {:adapter_generations, adapter_generations})
      when is_map(adapter_generations) do
    at = now()

    publications =
      Map.new(adapter_generations, fn {wire, generation} ->
        {wire, %{"generation" => generation, "publishedAt" => at}}
      end)

    edge(db, activation_id, {:adapter_publications, adapter_generations, publications})
  end

  def edge(
        db,
        activation_id,
        {:adapter_publications, adapter_generations, adapter_publications}
      )
      when is_map(adapter_generations) and is_map(adapter_publications) do
    publications = validate_adapter_publications!(adapter_generations, adapter_publications)
    encoded_generations = JSON.encode!(adapter_generations)
    encoded_publications = JSON.encode!(publications)

    published_at =
      publications |> Map.values() |> Enum.map(& &1["publishedAt"]) |> Enum.min(fn -> nil end)

    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        "UPDATE credential_recovery_activations SET adapterGenerations=?2,adapterPublications=?3,adapterPublishedAt=?4 WHERE activationId=?1 AND state IN ('credential_installed','metadata_committed')",
        [activation_id, encoded_generations, encoded_publications, published_at]
      )

      if Txn.changes(txn) != 1,
        do:
          raise(
            "credential_recovery_adapter_generations_transition_refused activation=#{activation_id}"
          )

      audit(txn, "credential_recovery_adapter_generations", activation_id, nil)
      :ok
    end)
  end

  def edge(db, activation_id, {:resume_succeeded, adapter_publications})
      when is_map(adapter_publications) do
    encoded_publications = JSON.encode!(adapter_publications)

    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        "UPDATE credential_recovery_activations SET resumeAt=?3 WHERE activationId=?1 AND state='metadata_committed' AND adapterPublications=?2",
        [activation_id, encoded_publications, now()]
      )

      if Txn.changes(txn) != 1,
        do: raise("credential_recovery_resume_transition_refused activation=#{activation_id}")

      audit(txn, "credential_recovery_resume_succeeded", activation_id, nil)
      :ok
    end)
  end

  @doc "Record that every successful activation edge, including resume, completed."
  def mark_ready(db, activation_id, adapter_generations) when is_map(adapter_generations) do
    affected_harnesses(adapter_generations)
    encoded = JSON.encode!(adapter_generations)
    at = now()

    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        "UPDATE credential_recovery_activations SET state='activation_ready',readyAt=?2,adapterGenerations=?3,adapterPublishedAt=COALESCE(adapterPublishedAt,?2) WHERE activationId=?1 AND state='adapter_started'",
        [activation_id, at, encoded]
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
           [[host, provider, generation, "activation_ready", encoded_publications]] =
             Txn.q(
               txn,
               "SELECT host,provider,generation,state,adapterPublications FROM credential_recovery_activations WHERE activationId=?1",
               [activation_id]
             )

           {:ok, _stored_generations, publications} =
             decode_adapter_proof(JSON.encode!(adapter_generations), encoded_publications)

           sessions = affected_sessions(txn, host, provider, harnesses)

           releases =
             Enum.flat_map(sessions, fn [session_key, harness] ->
               adapter_generation = Map.fetch!(adapter_generations, harness)
               target_id = target_id(host, provider, session_key)

               ensure_target(
                 txn,
                 activation_id,
                 target_id,
                 host,
                 provider,
                 session_key,
                 generation,
                 at
               )

               release =
                 ensure_membership(
                   txn,
                   activation_id,
                   target_id,
                   session_key,
                   host,
                   harness,
                   generation,
                   adapter_generation,
                   publications |> Map.fetch!(harness) |> Map.fetch!("publishedAt")
                 )

               materialize_if_needed(txn, activation_id, target_id)
               if release, do: [release], else: []
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

           %{
             activation_id: activation_id,
             state: state,
             aggregate:
               if(state == "complete",
                 do: "credential_recovery_complete",
                 else: "credential_recovery_in_progress"
               ),
             target_count: length(sessions),
             releases: releases
           }
         end) do
      {:ok, %{releases: releases} = result} ->
        Enum.each(releases, fn %{session_key: session_key, seq: seq} ->
          SessionLane.release_terminalized(session_key, seq)
        end)

        {:ok, Map.delete(result, :releases)}

      {:error, reason} ->
        {:error, {:recovery_publication_failed, reason}}
    end
  end

  @doc "Reconcile every pending current-cycle membership through its target's one owner."
  def reconcile_ready_activation(db, activation_id) do
    {:ok, target_rows} =
      DB.query(
        db,
        """
        SELECT DISTINCT targetId
        FROM credential_recovery_memberships
        WHERE activationId=?1 AND reconciliationState='pending'
        ORDER BY targetId
        """,
        [activation_id]
      )

    outcomes =
      Enum.map(target_rows, fn [target_id] ->
        {target_id, reconcile_target(db, target_id)}
      end)

    failures = Enum.filter(outcomes, fn {_target_id, result} -> match?({:error, _}, result) end)

    if failures == [] do
      retrying =
        Enum.flat_map(outcomes, fn
          {_target_id, {:ok, %{state: "retry_wait"} = status}} -> [status]
          _ -> []
        end)

      reconciled_count =
        Enum.reduce(outcomes, 0, fn
          {_target_id, {:ok, %{reconciled_count: count}}}, total -> total + count
          _, total -> total
        end)

      {:ok,
       %{
         reconciliation_state: if(retrying == [], do: "reconciled", else: "retrying"),
         reconciled_count: reconciled_count,
         attempt: retrying |> Enum.map(& &1.attempt) |> Enum.max(fn -> 0 end),
         due_at:
           retrying |> Enum.map(& &1.due_at) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end),
         reconciliation_counts: reconciliation_counts(db, activation_id)
       }}
    else
      {:error, {:reconciliation_failed, failures}}
    end
  end

  @doc "Persist one target-level bounded retry without creating or admitting its carrier."
  def defer_reconciliation(db, activation_id, reason) do
    DB.transaction(db, fn txn ->
      targets =
        Txn.q(
          txn,
          "SELECT DISTINCT targetId FROM credential_recovery_memberships WHERE activationId=?1 AND reconciliationState='pending' ORDER BY targetId",
          [activation_id]
        )

      statuses =
        Enum.map(targets, fn [target_id] -> defer_target_in_txn(txn, target_id, reason) end)

      %{
        attempt: statuses |> Enum.map(& &1.attempt) |> Enum.max(fn -> 0 end),
        due_at:
          statuses |> Enum.map(& &1.due_at) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
      }
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

        audit(
          txn,
          "credential_recovery_admitted",
          target_id,
          "wakeId=#{wake_id} turnSeq=#{seq}",
          "wake_admission",
          wake_id
        )

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
      [[target_id, session_key, _cycle]] ->
        disposition =
          case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [session_key]) do
            [["retired"]] -> "retired"
            _ -> "no_longer_affected"
          end

        dispose_target(txn, %{id: target_id}, disposition, "unavailable:#{wake_id}")
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

      Enum.each(targets, fn [target_id, _cycle] ->
        dispose_target(txn, %{id: target_id}, "retired", "session-retired:#{session_key}")
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
            "UPDATE credential_recovery_targets SET state='claimed',attemptState='claimed',turnSeq=?2,coveredGeneration=?3,updatedAt=?4 WHERE targetId=?1 AND state IN ('pending','admitted')",
            [target_id, seq, generation, now()]
          )

          audit(
            txn,
            "credential_recovery_claimed",
            target_id,
            "turnSeq=#{seq} coveredGeneration=#{generation}",
            "turn_claim",
            to_string(seq)
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
            "UPDATE credential_recovery_targets SET state='pending',attempt=?2,attemptState='reserved',dueAt=NULL,wakeId=NULL,turnSeq=NULL,coveredGeneration=NULL,updatedAt=?3 WHERE targetId=?1 AND state='retry_wait' AND attempt=?4",
            [target_id, next_attempt, now(), attempt]
          )

          materialize_if_needed(txn, nil, target_id)
          consume_internal_wake(txn, wake.wake_id)

          audit(
            txn,
            "credential_recovery_retry_reserved",
            target_id,
            "attempt=#{next_attempt}",
            "retry_wake",
            wake.wake_id
          )

          :ok

        _ ->
          consume_internal_wake(txn, wake.wake_id)

          :stale
      end
    end)
  end

  defp retry_reconciliation(db, wake, target_id) do
    current_time = now()

    reservation =
      DB.transaction(db, fn txn ->
        case Txn.q(
               txn,
               "SELECT state,attempt,dueAt,requiredGeneration FROM credential_recovery_targets WHERE targetId=?1",
               [target_id]
             ) do
          [["retry_wait", attempt, due_at, required_generation]]
          when due_at <= current_time and attempt < 3 ->
            next_attempt = attempt + 1

            Txn.q(
              txn,
              """
              UPDATE credential_recovery_targets
              SET state='pending',attempt=?2,attemptState='reserved',
                  reconciliationGeneration=?3,dueAt=NULL,failure=NULL,updatedAt=?4
              WHERE targetId=?1 AND state='retry_wait' AND attempt=?5 AND dueAt=?6
              """,
              [target_id, next_attempt, required_generation, now(), attempt, due_at]
            )

            if Txn.changes(txn) != 1, do: raise("credential_recovery_retry_reservation_race")
            consume_internal_wake(txn, wake.wake_id)

            audit(
              txn,
              "credential_recovery_retry_reserved",
              target_id,
              "attempt=#{next_attempt}",
              "retry_wake",
              wake.wake_id
            )

            {:reserved, next_attempt}

          _ ->
            consume_internal_wake(txn, wake.wake_id)
            :stale
        end
      end)

    case reservation do
      {:ok, {:reserved, _attempt}} ->
        case reconcile_target(db, target_id) do
          {:ok, _status} ->
            {:ok, :ok}

          {:error, reason} ->
            DB.transaction(db, fn txn ->
              defer_target_in_txn(txn, target_id, reason)
              :ok
            end)
        end

      {:ok, :stale} ->
        {:ok, :stale}

      {:error, reason} ->
        {:error, reason}
    end
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
            SELECT m.sessionKey,m.generation,m.snapshotHost,m.snapshotHarness,m.resolution,
                   m.reconciliationState,m.reconciliationResult,m.reconciliationCycle,
                   m.reconciliationTurnSeq,t.state,t.cycle,t.attempt,t.attemptState,
                   t.reconciliationGeneration,t.turnSeq,t.dueAt,t.failure
            FROM credential_recovery_memberships m
            JOIN credential_recovery_targets t ON t.targetId=m.targetId
            WHERE m.activationId=?1 ORDER BY m.sessionKey
            """,
            [activation_id]
          )

        membership_counts =
          rows
          |> Enum.map(&Enum.at(&1, 4))
          |> Enum.frequencies()

        aggregate =
          cond do
            Map.get(membership_counts, "undeliverable", 0) > 0 ->
              "credential_recovery_incomplete"

            state == "complete" ->
              "credential_recovery_complete"

            true ->
              "credential_recovery_in_progress"
          end

        %{
          activation_id: activation_id,
          host: host,
          provider: provider,
          credential_kind: kind,
          generation: generation,
          state: state,
          aggregate: aggregate,
          prepared_at: prepared,
          ready_at: ready,
          completed_at: completed,
          failure: failure,
          targets:
            Enum.map(rows, fn [
                                session,
                                member_gen,
                                snapshot_host,
                                snapshot_harness,
                                resolution,
                                reconciliation,
                                reconciliation_result,
                                reconciliation_cycle,
                                reconciliation_turn_seq,
                                target_state,
                                cycle,
                                attempt,
                                attempt_state,
                                reconciliation_generation,
                                turn_seq,
                                due_at,
                                target_failure
                              ] ->
              %{
                session_key: session,
                generation: member_gen,
                snapshot_host: snapshot_host,
                snapshot_harness: snapshot_harness,
                resolution: resolution,
                reconciliation: reconciliation,
                reconciliation_result: reconciliation_result,
                reconciliation_cycle: reconciliation_cycle,
                reconciliation_turn_seq: reconciliation_turn_seq,
                state: target_state,
                cycle: cycle,
                attempt: attempt,
                attempt_state: attempt_state,
                reconciliation_owner: %{
                  target_id: target_id(host, provider, session),
                  cycle: cycle,
                  attempt: attempt,
                  generation: reconciliation_generation
                },
                turn_seq: turn_seq,
                due_at: due_at,
                failure: target_failure
              }
            end),
          membership_counts: membership_counts
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

  defp transition_adapter_started(db, activation_id) do
    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        "UPDATE credential_recovery_activations SET state='adapter_started',adapterAt=?2 WHERE activationId=?1 AND state='metadata_committed' AND adapterPublications IS NOT NULL AND resumeAt IS NOT NULL",
        [activation_id, now()]
      )

      if Txn.changes(txn) != 1,
        do:
          raise(
            "credential_recovery_transition_refused activation=#{activation_id} expected=metadata_committed_with_adapter_and_resume_proof"
          )

      audit(txn, "credential_recovery_adapter_started", activation_id, nil)
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

  defp ensure_target(
         txn,
         activation_id,
         target_id,
         host,
         provider,
         session_key,
         generation,
         at
       ) do
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
            (targetId,host,provider,sessionKey,requiredGeneration,state,cycle,attempt,
             attemptState,updatedAt,cause,principal)
          VALUES (?1,?2,?3,?4,?5,'pending',1,0,'reserved',?6,'activation-ready',?7)
          """,
          [target_id, host, provider, session_key, generation, at, @process]
        )

        audit(
          txn,
          "credential_recovery_target_created",
          target_id,
          "cycle=1 generation=#{generation}",
          "activation",
          activation_id
        )

      [[state, _cycle, _old_generation]]
      when state in ["pending", "admitted", "claimed", "retry_wait"] ->
        Txn.q(
          txn,
          "UPDATE credential_recovery_targets SET requiredGeneration=?2,updatedAt=?3 WHERE targetId=?1",
          [target_id, generation, at]
        )

        audit(
          txn,
          "credential_recovery_target_generation_advanced",
          target_id,
          "generation=#{generation}",
          "activation",
          activation_id
        )

      [[state, cycle, _old_generation]]
      when state in ["handled", "undeliverable", "no_longer_affected"] ->
        Txn.q(
          txn,
          """
          UPDATE credential_recovery_targets
          SET requiredGeneration=?2,state='pending',cycle=?3,attempt=0,wakeId=NULL,
              attemptState='reserved',reconciliationGeneration=0,turnSeq=NULL,
              coveredGeneration=NULL,dueAt=NULL,failure=NULL,updatedAt=?4,
              cause='later-activation',principal=?5
          WHERE targetId=?1
          """,
          [target_id, generation, cycle + 1, at, @process]
        )

        audit(
          txn,
          "credential_recovery_target_cycle_opened",
          target_id,
          "cycle=#{cycle + 1} generation=#{generation}",
          "activation",
          activation_id
        )
    end
  end

  defp ensure_membership(
         txn,
         activation_id,
         target_id,
         session_key,
         snapshot_host,
         snapshot_harness,
         generation,
         adapter_generation,
         adapter_published_at
       ) do
    {reconciliation, turn_seq, release} =
      case prior_running(txn, session_key, adapter_generation, adapter_published_at) do
        {:pending, seq} -> {"pending", seq, nil}
        {:generation_missing, seq} -> {"not_required", nil, %{session_key: session_key, seq: seq}}
        :not_required -> {"not_required", nil, nil}
      end

    [[cycle]] =
      Txn.q(txn, "SELECT cycle FROM credential_recovery_targets WHERE targetId=?1", [target_id])

    Txn.q(
      txn,
      """
      INSERT INTO credential_recovery_memberships
        (activationId,sessionKey,targetId,generation,snapshotHost,snapshotHarness,
         adapterGeneration,adapterPublishedAt,resolution,reconciliationState,reconciliationTurnSeq,
         reconciliationCycle,cause,principal)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,'open',?9,?10,?11,'activation-membership',?12)
      """,
      [
        activation_id,
        session_key,
        target_id,
        generation,
        snapshot_host,
        snapshot_harness,
        adapter_generation,
        adapter_published_at,
        reconciliation,
        turn_seq,
        cycle,
        @process
      ]
    )

    audit(
      txn,
      "credential_recovery_membership_created",
      membership_subject(activation_id, session_key),
      "targetId=#{target_id} generation=#{generation} reconciliation=#{reconciliation}",
      "activation",
      activation_id
    )

    if release do
      [[owner_lease]] =
        Txn.q(
          txn,
          "SELECT ownerLease FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='claimed' ORDER BY ordinal DESC LIMIT 1",
          [release.seq]
        )

      true =
        Ledger.finish_in_txn(
          txn,
          release.seq,
          "failed",
          "generation_missing: adapter generation was not stamped before inference",
          cause: "credential-recovery-generation-missing",
          principal: @process,
          owner_lease: owner_lease
        )

      audit(
        txn,
        "credential_recovery_generation_missing",
        target_id,
        "turnSeq=#{release.seq}",
        "turn_claim",
        to_string(release.seq)
      )
    end

    release
  end

  defp prior_running(txn, session_key, adapter_generation, adapter_published_at) do
    case Txn.q(
           txn,
           """
           SELECT turns.seq,turns.adapterGen,
                  (SELECT at FROM turn_lifecycle_events
                   WHERE turnSeq=turns.seq AND kind='claimed'
                   ORDER BY ordinal DESC LIMIT 1)
           FROM turns WHERE sessionKey=?1 AND status='running' ORDER BY seq LIMIT 1
           """,
           [session_key]
         ) do
      [[seq, generation, _claimed_at]]
      when is_integer(generation) and generation < adapter_generation ->
        {:pending, seq}

      [[seq, nil, claimed_at]]
      when is_integer(claimed_at) and is_integer(adapter_published_at) and
             claimed_at < adapter_published_at ->
        {:pending, seq}

      [[seq, nil, claimed_at]]
      when is_integer(claimed_at) and is_integer(adapter_published_at) and
             claimed_at >= adapter_published_at ->
        {:generation_missing, seq}

      _ ->
        :not_required
    end
  end

  defp reconcile_target(db, target_id) do
    case DB.transaction(db, fn txn ->
           [[session_key, state, cycle, attempt, due_at, required_generation, carrier_turn_seq]] =
             Txn.q(
               txn,
               "SELECT sessionKey,state,cycle,attempt,dueAt,requiredGeneration,turnSeq FROM credential_recovery_targets WHERE targetId=?1",
               [target_id]
             )

           if state == "retry_wait" do
             %{state: state, attempt: attempt, due_at: due_at, reconciled_count: 0, releases: []}
           else
             rows =
               Txn.q(
                 txn,
                 """
                 SELECT activationId,sessionKey,reconciliationTurnSeq
                 FROM credential_recovery_memberships
                 WHERE targetId=?1 AND reconciliationCycle=?2 AND reconciliationState='pending'
                 ORDER BY reconciliationTurnSeq,activationId
                 """,
                 [target_id, cycle]
               )

             outcomes =
               rows
               |> Enum.group_by(&Enum.at(&1, 2))
               |> Enum.sort_by(fn {seq, _memberships} -> seq end)
               |> Enum.map(fn {seq, memberships} ->
                 reconcile_turn_group_with_savepoint(
                   txn,
                   target_id,
                   cycle,
                   session_key,
                   seq,
                   memberships
                 )
               end)

             releases =
               Enum.flat_map(outcomes, fn
                 {:ok, release} -> [release]
                 {:error, _seq, _reason} -> []
               end)

             failures =
               Enum.flat_map(outcomes, fn
                 {:error, seq, reason} -> [{seq, reason}]
                 {:ok, _release} -> []
               end)

             Txn.q(
               txn,
               "UPDATE credential_recovery_targets SET reconciliationGeneration=?2,failure=NULL,updatedAt=?3 WHERE targetId=?1",
               [target_id, required_generation, now()]
             )

             if failures == [] do
               terminalized_claim? =
                 is_integer(carrier_turn_seq) and
                   Enum.any?(releases, &(&1.terminalized? and &1.seq == carrier_turn_seq))

               if terminalized_claim? do
                 Txn.q(
                   txn,
                   "UPDATE credential_recovery_targets SET attemptState='not_admitted_cycle_closed',updatedAt=?3 WHERE targetId=?1 AND cycle=?2 AND state='pending' AND attemptState='reserved' AND wakeId IS NULL",
                   [target_id, cycle, now()]
                 )

                 cause_turn =
                   Enum.find_value(releases, fn release ->
                     if release.terminalized? and release.seq == carrier_turn_seq,
                       do: to_string(release.seq)
                   end)

                 audit(
                   txn,
                   "credential_recovery_attempt_not_admitted_cycle_closed",
                   target_id,
                   "cycle=#{cycle} attempt=#{attempt}",
                   "turn_terminal",
                   cause_turn
                 )
               else
                 materialize_if_needed(txn, nil, target_id)
               end

               %{
                 state: state,
                 attempt: attempt,
                 due_at: nil,
                 reconciled_count: length(rows),
                 releases: releases
               }
             else
               retry =
                 defer_target_in_txn(
                   txn,
                   target_id,
                   {:turn_groups_failed, Enum.map(failures, &elem(&1, 0))}
                 )

               [[next_state]] =
                 Txn.q(
                   txn,
                   "SELECT state FROM credential_recovery_targets WHERE targetId=?1",
                   [target_id]
                 )

               %{
                 state: next_state,
                 attempt: retry.attempt,
                 due_at: retry.due_at,
                 reconciled_count:
                   Enum.reduce(releases, 0, fn release, count ->
                     count + release.membership_count
                   end),
                 releases: releases
               }
             end
           end
         end) do
      {:ok, %{releases: releases} = status} ->
        Enum.each(releases, fn
          %{terminalized?: true, session_key: session_key, seq: seq} ->
            SessionLane.release_terminalized(session_key, seq)
            turn_terminal(db, seq)

          _ ->
            :ok
        end)

        {:ok, Map.delete(status, :releases)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_turn_group_with_savepoint(
         txn,
         target_id,
         cycle,
         session_key,
         seq,
         memberships
       ) do
    Txn.exec(txn, "SAVEPOINT credential_recovery_turn_group")

    try do
      release =
        reconcile_turn_group_in_txn(
          txn,
          target_id,
          cycle,
          session_key,
          seq,
          memberships
        )

      Txn.exec(txn, "RELEASE SAVEPOINT credential_recovery_turn_group")
      {:ok, Map.put(release, :membership_count, length(memberships))}
    rescue
      error ->
        Txn.exec(txn, "ROLLBACK TO SAVEPOINT credential_recovery_turn_group")
        Txn.exec(txn, "RELEASE SAVEPOINT credential_recovery_turn_group")
        {:error, seq, error}
    end
  end

  defp reconcile_turn_group_in_txn(
         txn,
         target_id,
         cycle,
         session_key,
         seq,
         memberships
       ) do
    {reconciliation_state, disposition, terminalized?} =
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

          {"done", disposition, true}

        [[status, _owner_lease]]
        when status in ["delivered", "canceled", "failed", "failed_unknown"] ->
          {"done", terminal_disposition(txn, seq, status), false}

        [] ->
          {"not_required", nil, false}
      end

    Txn.q(
      txn,
      "UPDATE credential_recovery_memberships SET reconciliationState=?4,reconciliationResult=?5 WHERE targetId=?1 AND reconciliationCycle=?2 AND reconciliationTurnSeq=?3 AND reconciliationState='pending'",
      [target_id, cycle, seq, reconciliation_state, disposition]
    )

    Enum.each(memberships, fn [activation_id, membership_session, _turn_seq] ->
      audit(
        txn,
        "credential_recovery_membership_reconciliation_#{reconciliation_state}",
        membership_subject(activation_id, membership_session),
        "targetId=#{target_id} cycle=#{cycle} disposition=#{disposition || "not_required"}",
        if(terminalized?, do: "turn_terminal", else: "turn_observed"),
        to_string(seq)
      )
    end)

    audit(
      txn,
      "credential_recovery_reconciled",
      target_id,
      "cycle=#{cycle} session=#{session_key} turnSeq=#{seq} memberships=#{length(memberships)} disposition=#{disposition || "not_required"}"
    )

    %{session_key: session_key, seq: seq, terminalized?: terminalized?}
  end

  defp defer_target_in_txn(txn, target_id, reason) do
    [[session_key, cycle, attempt, state, due_at, required_generation]] =
      Txn.q(
        txn,
        "SELECT sessionKey,cycle,attempt,state,dueAt,requiredGeneration FROM credential_recovery_targets WHERE targetId=?1",
        [target_id]
      )

    cond do
      state == "retry_wait" ->
        %{attempt: attempt, due_at: due_at}

      attempt < 3 ->
        next_attempt = attempt + 1
        retry_at = now() + Enum.at(@retry_delays, attempt)
        wake_id = reconciliation_wake_id(target_id, cycle, next_attempt)

        cancel_target_wake(txn, target_id, "consumer_unavailable")

        Wakes.schedule_in_txn(txn, %{
          wake_id: wake_id,
          session_key: session_key,
          origin: @process,
          consumer: "credential_recovery_retry",
          prompt: target_id,
          due_at: retry_at,
          condition_scope: target_id,
          target_gate: 1,
          sender_scheduled: true
        })

        Txn.q(
          txn,
          """
          UPDATE credential_recovery_targets
          SET state='retry_wait',attemptState='terminal',reconciliationGeneration=?2,
              wakeId=NULL,dueAt=?3,failure=?4,updatedAt=?5
          WHERE targetId=?1 AND state IN ('pending','admitted','claimed')
          """,
          [
            target_id,
            required_generation,
            retry_at,
            "reconciliation_failed:#{failure_code(reason)}",
            now()
          ]
        )

        audit(
          txn,
          "credential_recovery_reconciliation_retry_wait",
          target_id,
          "attempt=#{attempt} nextAttempt=#{next_attempt} dueAt=#{retry_at}",
          "recovery_attempt",
          "#{target_id}:#{cycle}:#{attempt}"
        )

        %{attempt: attempt, due_at: retry_at}

      true ->
        finalize_reconciliation_failure_in_txn(txn, target_id, cycle, required_generation, reason)
        %{attempt: attempt, due_at: nil}
    end
  end

  defp finalize_reconciliation_failure_in_txn(
         txn,
         target_id,
         cycle,
         reconciliation_generation,
         reason
       ) do
    at = now()

    pending_memberships =
      Txn.q(
        txn,
        "SELECT activationId,sessionKey,reconciliationTurnSeq FROM credential_recovery_memberships WHERE targetId=?1 AND reconciliationCycle=?2 AND reconciliationState='pending' ORDER BY reconciliationTurnSeq,activationId",
        [target_id, cycle]
      )

    Txn.q(
      txn,
      "UPDATE credential_recovery_memberships SET reconciliationState='failed',reconciliationResult='could_not_run' WHERE targetId=?1 AND reconciliationCycle=?2 AND reconciliationState='pending'",
      [target_id, cycle]
    )

    Enum.each(pending_memberships, fn [activation_id, session_key, turn_seq] ->
      audit(
        txn,
        "credential_recovery_membership_reconciliation_failed",
        membership_subject(activation_id, session_key),
        "targetId=#{target_id} cycle=#{cycle} result=could_not_run",
        "recovery_attempt",
        "#{target_id}:#{cycle}:#{turn_seq || "none"}"
      )
    end)

    cancel_target_wake(txn, target_id, "consumer_unavailable")
    cancel_internal_retry_wakes(txn, target_id, "consumer_unavailable")

    later? =
      finalize_undeliverable_generation(
        txn,
        target_id,
        cycle,
        reconciliation_generation,
        "reconciliation_failed:#{failure_code(reason)}",
        nil,
        at
      )

    complete_activations(txn, target_id)
    audit(txn, "credential_recovery_undeliverable", target_id, "reconciliation-attempt-3")

    if later?, do: materialize_if_needed(txn, nil, target_id)
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

    open_memberships =
      Txn.q(
        txn,
        "SELECT activationId,sessionKey FROM credential_recovery_memberships WHERE targetId=?1 AND resolution='open' ORDER BY activationId",
        [target.id]
      )

    pending_reconciliations =
      Txn.q(
        txn,
        "SELECT activationId,sessionKey,reconciliationTurnSeq FROM credential_recovery_memberships WHERE targetId=?1 AND reconciliationCycle=?2 AND reconciliationState='pending' ORDER BY activationId",
        [target.id, cycle]
      )

    cancel_target_wake(txn, target.id, "target_unresolvable")
    cancel_internal_retry_wakes(txn, target.id, "target_unresolvable")

    Txn.q(
      txn,
      "UPDATE credential_recovery_targets SET state=?2,attemptState='terminal',wakeId=NULL,dueAt=NULL,failure=?2,updatedAt=?3 WHERE targetId=?1",
      [target.id, disposition, at]
    )

    Txn.q(
      txn,
      "UPDATE credential_recovery_memberships SET reconciliationState='not_required',reconciliationResult=NULL WHERE targetId=?1 AND reconciliationCycle=?2 AND reconciliationState='pending'",
      [target.id, cycle]
    )

    Txn.q(
      txn,
      "UPDATE credential_recovery_memberships SET resolution=?2,resolvedCycle=?3,resolvedAt=?4 WHERE targetId=?1 AND resolution='open'",
      [target.id, disposition, cycle, at]
    )

    Enum.each(pending_reconciliations, fn [activation_id, session_key, turn_seq] ->
      audit(
        txn,
        "credential_recovery_membership_reconciliation_not_required",
        membership_subject(activation_id, session_key),
        "targetId=#{target.id} cycle=#{cycle} disposition=#{disposition}",
        "eligibility_disposition",
        turn_seq || target.id
      )
    end)

    Enum.each(open_memberships, fn [activation_id, session_key] ->
      audit(
        txn,
        "credential_recovery_membership_#{disposition}",
        membership_subject(activation_id, session_key),
        "targetId=#{target.id} cycle=#{cycle}",
        "eligibility_disposition",
        boundary
      )
    end)

    complete_activations(txn, target.id)

    audit(
      txn,
      "credential_recovery_#{disposition}",
      target.id,
      "boundary=#{boundary}",
      "eligibility_disposition",
      boundary
    )
  end

  defp materialize_if_needed(txn, activation_id, target_id) do
    case Txn.q(
           txn,
           "SELECT sessionKey,host,provider,requiredGeneration,state,cycle,attempt,attemptState,wakeId FROM credential_recovery_targets WHERE targetId=?1",
           [target_id]
         ) do
      [[session_key, host, provider, generation, "pending", cycle, attempt, "reserved", nil]] ->
        pending_reconciliation =
          Txn.q(
            txn,
            "SELECT 1 FROM credential_recovery_memberships WHERE targetId=?1 AND reconciliationState='pending' LIMIT 1",
            [target_id]
          ) != []

        if attempt == 0 or not pending_reconciliation do
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
            "UPDATE credential_recovery_targets SET wakeId=?2,attemptState='materialized',updatedAt=?3 WHERE targetId=?1 AND state='pending' AND wakeId IS NULL",
            [target_id, wake.wake_id, now()]
          )

          audit(
            txn,
            "credential_recovery_carrier_materialized",
            target_id,
            "cycle=#{cycle} attempt=#{attempt} wakeId=#{wake.wake_id}",
            "wake_materialized",
            wake.wake_id
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
    settle_cycle_reconciliations_in_txn(txn, target, seq, "delivered")

    resolved_memberships =
      Txn.q(
        txn,
        "SELECT activationId,sessionKey FROM credential_recovery_memberships WHERE targetId=?1 AND resolution='open' AND generation<=?2 ORDER BY activationId",
        [target.id, covered]
      )

    Txn.q(
      txn,
      "UPDATE credential_recovery_memberships SET resolution='handled',resolvedCycle=?2,resolvedTurnSeq=?3,resolvedAt=?4 WHERE targetId=?1 AND resolution='open' AND generation<=?5",
      [target.id, target.cycle, seq, at, covered]
    )

    Enum.each(resolved_memberships, fn [activation_id, session_key] ->
      audit(
        txn,
        "credential_recovery_membership_handled",
        membership_subject(activation_id, session_key),
        "targetId=#{target.id} cycle=#{target.cycle} generation=#{covered}",
        "turn_terminal",
        to_string(seq)
      )
    end)

    if target.required > covered do
      Txn.q(
        txn,
        "UPDATE credential_recovery_targets SET state='pending',handledGeneration=?2,cycle=?3,attempt=0,attemptState='reserved',reconciliationGeneration=0,wakeId=NULL,turnSeq=NULL,coveredGeneration=NULL,updatedAt=?4 WHERE targetId=?1 AND state='claimed'",
        [target.id, covered, target.cycle + 1, at]
      )

      audit(
        txn,
        "credential_recovery_target_cycle_opened",
        target.id,
        "cycle=#{target.cycle + 1} generation=#{target.required}",
        "turn_terminal",
        to_string(seq)
      )

      materialize_if_needed(txn, nil, target.id)
    else
      Txn.q(
        txn,
        "UPDATE credential_recovery_targets SET state='handled',handledGeneration=?2,attemptState='terminal',updatedAt=?3 WHERE targetId=?1 AND state='claimed'",
        [target.id, covered, at]
      )
    end

    complete_activations(txn, target.id)

    audit(
      txn,
      "credential_recovery_handled",
      target.id,
      "turnSeq=#{seq} generation=#{covered}",
      "turn_terminal",
      to_string(seq)
    )

    %{
      fire?: target.required > covered,
      state: if(target.required > covered, do: "pending", else: "handled")
    }
  end

  defp settle_terminal(txn, %{state: state} = target, seq)
       when state in ["pending", "admitted", "claimed"] do
    disposition = terminal_disposition(txn, seq, target.terminal)
    settle_cycle_reconciliations_in_txn(txn, target, seq, disposition)

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
          "UPDATE credential_recovery_targets SET state='retry_wait',attemptState='terminal',dueAt=?2,wakeId=NULL,turnSeq=NULL,coveredGeneration=NULL,failure=?3,updatedAt=?4 WHERE targetId=?1",
          [target.id, due_at, disposition, now()]
        )

        audit(
          txn,
          "credential_recovery_retry_wait",
          target.id,
          "attempt=#{attempt} nextAttempt=#{attempt + 1} dueAt=#{due_at}",
          "turn_terminal",
          to_string(seq)
        )

        %{fire?: false, state: "retry_wait"}

      _ ->
        covered = target.covered || target.required
        at = now()

        later? =
          finalize_undeliverable_generation(
            txn,
            target.id,
            target.cycle,
            covered,
            disposition,
            seq,
            at
          )

        complete_activations(txn, target.id)

        audit(
          txn,
          "credential_recovery_undeliverable",
          target.id,
          "turnSeq=#{seq} disposition=#{disposition}",
          "turn_terminal",
          to_string(seq)
        )

        if later?, do: materialize_if_needed(txn, nil, target.id)

        %{fire?: later?, state: if(later?, do: "pending", else: "undeliverable")}
    end
  end

  defp settle_terminal(_txn, _target, _seq), do: :stale

  defp finalize_undeliverable_generation(
         txn,
         target_id,
         cycle,
         resolution_generation,
         failure,
         turn_seq,
         at
       ) do
    [[required_generation]] =
      Txn.q(
        txn,
        "SELECT requiredGeneration FROM credential_recovery_targets WHERE targetId=?1",
        [target_id]
      )

    resolved_memberships =
      Txn.q(
        txn,
        "SELECT activationId,sessionKey FROM credential_recovery_memberships WHERE targetId=?1 AND resolution='open' AND generation<=?2 ORDER BY activationId",
        [target_id, resolution_generation]
      )

    Txn.q(
      txn,
      "UPDATE credential_recovery_memberships SET resolution='undeliverable',resolvedCycle=?2,resolvedTurnSeq=?3,resolvedAt=?4 WHERE targetId=?1 AND resolution='open' AND generation<=?5",
      [target_id, cycle, turn_seq, at, resolution_generation]
    )

    Enum.each(resolved_memberships, fn [activation_id, session_key] ->
      audit(
        txn,
        "credential_recovery_membership_undeliverable",
        membership_subject(activation_id, session_key),
        "targetId=#{target_id} cycle=#{cycle} generation=#{resolution_generation} failure=#{failure}",
        "turn_terminal",
        turn_seq || "#{target_id}:#{cycle}"
      )
    end)

    if required_generation > resolution_generation do
      Txn.q(
        txn,
        "UPDATE credential_recovery_targets SET state='pending',handledGeneration=?2,cycle=?3,attempt=0,attemptState='reserved',reconciliationGeneration=0,wakeId=NULL,turnSeq=NULL,coveredGeneration=NULL,dueAt=NULL,failure=NULL,updatedAt=?4 WHERE targetId=?1",
        [target_id, resolution_generation, cycle + 1, at]
      )

      audit(
        txn,
        "credential_recovery_target_cycle_opened",
        target_id,
        "cycle=#{cycle + 1} generation=#{required_generation}",
        if(turn_seq, do: "turn_terminal", else: "recovery_attempt"),
        turn_seq || "#{target_id}:#{cycle}"
      )

      true
    else
      Txn.q(
        txn,
        "UPDATE credential_recovery_targets SET state='undeliverable',handledGeneration=?2,attemptState='terminal',wakeId=NULL,dueAt=NULL,failure=?3,updatedAt=?4 WHERE targetId=?1",
        [target_id, resolution_generation, failure, at]
      )

      audit(
        txn,
        "credential_recovery_target_undeliverable",
        target_id,
        "cycle=#{cycle} generation=#{resolution_generation} failure=#{failure}",
        if(turn_seq, do: "turn_terminal", else: "recovery_attempt"),
        turn_seq || "#{target_id}:#{cycle}"
      )

      false
    end
  end

  defp settle_cycle_reconciliations_in_txn(txn, target, seq, disposition) do
    matching =
      Txn.q(
        txn,
        "SELECT activationId,sessionKey FROM credential_recovery_memberships WHERE targetId=?1 AND reconciliationCycle=?2 AND reconciliationTurnSeq=?3 AND reconciliationState='pending' ORDER BY activationId",
        [target.id, target.cycle, seq]
      )

    Txn.q(
      txn,
      """
      UPDATE credential_recovery_memberships
      SET reconciliationState='done',reconciliationResult=?4
      WHERE targetId=?1 AND reconciliationCycle=?2 AND reconciliationTurnSeq=?3
        AND reconciliationState='pending'
      """,
      [target.id, target.cycle, seq, disposition]
    )

    Enum.each(matching, fn [activation_id, session_key] ->
      audit(
        txn,
        "credential_recovery_membership_reconciliation_done",
        membership_subject(activation_id, session_key),
        "targetId=#{target.id} cycle=#{target.cycle} disposition=#{disposition}",
        "turn_terminal",
        to_string(seq)
      )
    end)

    remaining =
      Txn.q(
        txn,
        "SELECT activationId,sessionKey,reconciliationTurnSeq FROM credential_recovery_memberships WHERE targetId=?1 AND reconciliationCycle=?2 AND reconciliationState='pending' ORDER BY activationId",
        [target.id, target.cycle]
      )

    Txn.q(
      txn,
      """
      UPDATE credential_recovery_memberships
      SET reconciliationState='not_required',reconciliationResult=NULL
      WHERE targetId=?1 AND reconciliationCycle=?2 AND reconciliationState='pending'
      """,
      [target.id, target.cycle]
    )

    Enum.each(remaining, fn [activation_id, session_key, turn_seq] ->
      audit(
        txn,
        "credential_recovery_membership_reconciliation_not_required",
        membership_subject(activation_id, session_key),
        "targetId=#{target.id} cycle=#{target.cycle}",
        "turn_terminal",
        turn_seq || to_string(seq)
      )
    end)
  end

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
      incomplete? =
        Txn.q(
          txn,
          "SELECT 1 FROM credential_recovery_memberships WHERE activationId=?1 AND (resolution='open' OR reconciliationState='pending') LIMIT 1",
          [activation_id]
        ) != []

      unless incomplete? do
        Txn.q(
          txn,
          "UPDATE credential_recovery_activations SET state='complete',completedAt=?2 WHERE activationId=?1 AND state='recovering'",
          [activation_id, now()]
        )

        if Txn.changes(txn) == 1 do
          audit(
            txn,
            "credential_recovery_complete",
            activation_id,
            "targetId=#{target_id}",
            "membership_resolution",
            target_id
          )
        end
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

  defp cancel_internal_retry_wakes(txn, target_id, reason_kind) do
    txn
    |> Txn.q(
      "SELECT wakeId FROM wakes WHERE consumer='credential_recovery_retry' AND conditionScope=?1 AND state='pending' ORDER BY wakeId",
      [target_id]
    )
    |> Enum.each(fn [wake_id] ->
      Wakes.cancel_in_txn(txn, %{
        wake_id: wake_id,
        requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
        reason_kind: reason_kind,
        causal_source: %{kind: "scheduler_delivery", id: wake_id},
        outcome: %{kind: "no_replacement"}
      })
    end)
  end

  defp digest(value) do
    :crypto.hash(:sha256, value)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 24)
  end

  defp decode_adapter_proof(encoded_generations, encoded_publications) do
    with {:ok, generations} when is_map(generations) <-
           JSON.decode(encoded_generations || ""),
         {:ok, publications} when is_map(publications) <-
           JSON.decode(encoded_publications || "") do
      try do
        {:ok, generations, validate_adapter_publications!(generations, publications)}
      rescue
        ArgumentError -> {:error, :adapter_publications_invalid_after_metadata_committed}
      end
    else
      _ -> {:error, :adapter_publications_missing_after_metadata_committed}
    end
  end

  defp validate_adapter_publications!(adapter_generations, adapter_publications) do
    affected_harnesses(adapter_generations)

    publications =
      Map.new(adapter_generations, fn {wire, generation} ->
        publication = Map.fetch!(adapter_publications, wire)
        published_at = publication["publishedAt"] || publication[:published_at]
        published_generation = publication["generation"] || publication[:generation]

        unless published_generation == generation and is_integer(published_at) and
                 published_at >= 0 do
          raise ArgumentError, "invalid adapter publication proof for #{inspect(wire)}"
        end

        {wire, %{"generation" => generation, "publishedAt" => published_at}}
      end)

    if map_size(publications) != map_size(adapter_publications) do
      raise ArgumentError, "adapter publication proof scope mismatch"
    end

    publications
  end

  defp membership_subject(activation_id, session_key),
    do: "#{activation_id}:#{session_key}"

  defp audit(
         txn,
         kind,
         subject,
         detail,
         cause_kind \\ "recovery_transition",
         cause_row_id \\ nil,
         principal \\ @process
       ) do
    cause_row_id = cause_row_id || subject

    Txn.q(
      txn,
      "INSERT INTO credential_recovery_transition_audit (ts,kind,subject,causeKind,causeRowId,principal,detail) VALUES (?1,?2,?3,?4,?5,?6,?7)",
      [now(), kind, subject, cause_kind, to_string(cause_row_id), principal, detail]
    )

    EventLog.lifecycle_in_txn(txn, kind, subject, detail)
  end

  defp failure_code(value) when is_atom(value), do: Atom.to_string(value)
  defp failure_code({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_code(%{code: code}) when is_atom(code) or is_binary(code), do: to_string(code)
  defp failure_code(_value), do: "operation_failed"

  defp now, do: System.system_time(:millisecond)
end
