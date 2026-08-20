defmodule Tightbeam.PatrolResponse do
  @moduledoc false

  alias Tightbeam.{Escalation, EventLog, Schema, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  @source_kinds ~w(supervision_episode effort_generation_probe effort_generation_prod effort_decision_notification effort_decision_deadline)
  @reference_schema "patrol_schema_reference"

  @output_source_objects [
    %{
      type: "table",
      name: "patrol_output_sources",
      sql: """
      CREATE TABLE patrol_output_sources (
        wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
        assignmentId TEXT NOT NULL REFERENCES assignments(id),
        holderKey TEXT NOT NULL REFERENCES sessions(sessionKey),
        sourceKind TEXT NOT NULL CHECK (sourceKind IN (
          'supervision_episode',
          'effort_generation_probe',
          'effort_generation_prod',
          'effort_decision_notification',
          'effort_decision_deadline'
        )),
        sourceRef TEXT NOT NULL,
        sourceVersion INTEGER NOT NULL CHECK (sourceVersion >= 0),
        rootWakeId TEXT NOT NULL REFERENCES wakes(wakeId),
        predecessorWakeId TEXT REFERENCES wakes(wakeId),
        retryOrdinal INTEGER NOT NULL CHECK (retryOrdinal >= 0),
        createdAt INTEGER NOT NULL CHECK (createdAt >= 0),
        sourceCause TEXT NOT NULL CHECK (sourceCause = 'patrol_output_scheduled'),
        sourcePrincipal TEXT NOT NULL CHECK (sourcePrincipal = 'process:tightbeam'),
        UNIQUE (rootWakeId, retryOrdinal),
        UNIQUE (sourceKind, sourceRef, sourceVersion, retryOrdinal),
        CHECK (
          (retryOrdinal = 0 AND rootWakeId = wakeId AND predecessorWakeId IS NULL)
          OR
          (retryOrdinal > 0 AND rootWakeId != wakeId AND predecessorWakeId IS NOT NULL)
        )
      )
      """
    },
    %{
      type: "trigger",
      name: "patrol_output_source_immutable",
      sql: """
      CREATE TRIGGER patrol_output_source_immutable
      BEFORE UPDATE ON patrol_output_sources
      BEGIN
        SELECT RAISE(ABORT, 'patrol output source is immutable');
      END
      """
    },
    %{
      type: "trigger",
      name: "patrol_output_source_immutable_delete",
      sql: """
      CREATE TRIGGER patrol_output_source_immutable_delete
      BEFORE DELETE ON patrol_output_sources
      BEGIN
        SELECT RAISE(ABORT, 'patrol output source is durable');
      END
      """
    }
  ]

  @episode_objects [
    %{
      type: "table",
      name: "supervision_patrol_response_episodes",
      sql: """
      CREATE TABLE supervision_patrol_response_episodes (
        assignmentId TEXT NOT NULL REFERENCES assignments(id),
        originatingWakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
        recoveryBranch TEXT NOT NULL CHECK (recoveryBranch IN ('prod','escalation')),
        recoveryRung INTEGER NOT NULL CHECK (recoveryRung > 0),
        sourceTerminalId INTEGER NOT NULL REFERENCES turns(seq),
        answerTerminalId INTEGER UNIQUE REFERENCES turns(seq),
        scheduledAt INTEGER NOT NULL CHECK (scheduledAt >= 0),
        acknowledgedAt INTEGER CHECK (acknowledgedAt >= scheduledAt),
        scheduledCause TEXT NOT NULL CHECK (scheduledCause = 'patrol_wake_scheduled'),
        scheduledPrincipal TEXT NOT NULL CHECK (scheduledPrincipal = 'process:tightbeam'),
        acknowledgmentCause TEXT CHECK (acknowledgmentCause = 'patrol_answer_terminal'),
        acknowledgmentPrincipal TEXT CHECK (acknowledgmentPrincipal = 'process:tightbeam'),
        PRIMARY KEY (
          assignmentId,
          originatingWakeId,
          recoveryBranch,
          recoveryRung,
          sourceTerminalId
        ),
        CHECK (
          (answerTerminalId IS NULL AND acknowledgedAt IS NULL
            AND acknowledgmentCause IS NULL AND acknowledgmentPrincipal IS NULL)
          OR
          (answerTerminalId IS NOT NULL AND acknowledgedAt IS NOT NULL
            AND acknowledgmentCause IS NOT NULL AND acknowledgmentPrincipal IS NOT NULL)
        )
      )
      """
    },
    %{
      type: "trigger",
      name: "supervision_patrol_episode_insert_coherent",
      sql: """
      CREATE TRIGGER supervision_patrol_episode_insert_coherent
      BEFORE INSERT ON supervision_patrol_response_episodes
      WHEN NEW.answerTerminalId IS NOT NULL
        OR NEW.acknowledgedAt IS NOT NULL
        OR NEW.acknowledgmentCause IS NOT NULL
        OR NEW.acknowledgmentPrincipal IS NOT NULL
        OR NOT EXISTS (
        SELECT 1
        FROM wakes w
        JOIN supervision_liveness_sidecar s
          ON s.wakeId=w.wakeId AND s.assignmentId=w.assignmentId
        JOIN assignments a ON a.id=w.assignmentId
        JOIN turns source ON source.seq=NEW.sourceTerminalId
        WHERE w.wakeId=NEW.originatingWakeId
          AND w.assignmentId=NEW.assignmentId
          AND w.origin='process:tightbeam' AND w.consumer='prompt'
          AND w.state='pending'
          AND w.createdAt=NEW.scheduledAt
          AND a.state='open' AND source.sessionKey=a.holderKey
          AND source.status IN ('delivered','canceled','failed','failed_unknown')
          AND s.controllerOrigin='scheduled' AND s.controllerState='pending'
          AND s.wakeKind=NEW.recoveryBranch
          AND (
            (NEW.recoveryBranch='prod' AND w.reresolve IS NULL
              AND w.reresolveSeed IS NULL AND w.reresolveRung IS NULL)
            OR
            (NEW.recoveryBranch='escalation' AND w.reresolve='lineage'
              AND w.reresolveSeed=a.holderKey
              AND w.reresolveRung=NEW.recoveryRung)
          )
      )
      BEGIN
        SELECT RAISE(ABORT, 'patrol response episode requires a coherent scheduled wake');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_patrol_episode_source_immutable",
      sql: """
      CREATE TRIGGER supervision_patrol_episode_source_immutable
      BEFORE UPDATE OF assignmentId, originatingWakeId, recoveryBranch, recoveryRung,
        sourceTerminalId, scheduledAt, scheduledCause, scheduledPrincipal
      ON supervision_patrol_response_episodes
      WHEN NEW.assignmentId IS NOT OLD.assignmentId
        OR NEW.originatingWakeId IS NOT OLD.originatingWakeId
        OR NEW.recoveryBranch IS NOT OLD.recoveryBranch
        OR NEW.recoveryRung IS NOT OLD.recoveryRung
        OR NEW.sourceTerminalId IS NOT OLD.sourceTerminalId
        OR NEW.scheduledAt IS NOT OLD.scheduledAt
        OR NEW.scheduledCause IS NOT OLD.scheduledCause
        OR NEW.scheduledPrincipal IS NOT OLD.scheduledPrincipal
      BEGIN
        SELECT RAISE(ABORT, 'patrol response episode source is immutable');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_patrol_acknowledgment_one_way",
      sql: """
      CREATE TRIGGER supervision_patrol_acknowledgment_one_way
      BEFORE UPDATE OF answerTerminalId, acknowledgedAt, acknowledgmentCause,
        acknowledgmentPrincipal
      ON supervision_patrol_response_episodes
      WHEN NOT (
        (NEW.answerTerminalId IS OLD.answerTerminalId
          AND NEW.acknowledgedAt IS OLD.acknowledgedAt
          AND NEW.acknowledgmentCause IS OLD.acknowledgmentCause
          AND NEW.acknowledgmentPrincipal IS OLD.acknowledgmentPrincipal)
        OR
        (OLD.answerTerminalId IS NULL AND OLD.acknowledgedAt IS NULL
          AND OLD.acknowledgmentCause IS NULL AND OLD.acknowledgmentPrincipal IS NULL
          AND NEW.answerTerminalId IS NOT NULL AND NEW.acknowledgedAt IS NOT NULL
          AND NEW.acknowledgmentCause='patrol_answer_terminal'
          AND NEW.acknowledgmentPrincipal='process:tightbeam'
          AND EXISTS (
            SELECT 1
            FROM turns answer
            JOIN wakes w ON w.wakeId=answer.wakeId
            JOIN patrol_output_sources p ON p.wakeId=answer.wakeId
            JOIN assignments a ON a.id=answer.assignmentId
            JOIN supervision_liveness_sidecar s
              ON s.wakeId=w.wakeId AND s.assignmentId=w.assignmentId
            WHERE answer.seq=NEW.answerTerminalId
              AND answer.assignmentId=OLD.assignmentId
              AND answer.status='delivered' AND answer.endedAt=NEW.acknowledgedAt
              AND w.state='fired' AND w.origin='process:tightbeam'
              AND w.consumer='prompt' AND w.assignmentId=OLD.assignmentId
              AND p.assignmentId=OLD.assignmentId AND p.holderKey=a.holderKey
              AND p.sourceKind='supervision_episode'
              AND p.sourceRef=OLD.originatingWakeId AND p.sourceVersion=0
              AND p.rootWakeId=OLD.originatingWakeId
              AND a.state='open'
              AND s.controllerOrigin='scheduled' AND s.controllerState='settled'
              AND s.wakeKind=OLD.recoveryBranch
              AND (
                (OLD.recoveryBranch='prod' AND w.reresolve IS NULL
                  AND w.reresolveSeed IS NULL AND w.reresolveRung IS NULL)
                OR
                (OLD.recoveryBranch='escalation' AND w.reresolve='lineage'
                  AND w.reresolveSeed=a.holderKey
                  AND w.reresolveRung=OLD.recoveryRung)
              )
          ))
      )
      BEGIN
        SELECT RAISE(ABORT, 'patrol response acknowledgment is one-way and coherent');
      END
      """
    },
    %{
      type: "trigger",
      name: "supervision_patrol_episode_immutable_delete",
      sql: """
      CREATE TRIGGER supervision_patrol_episode_immutable_delete
      BEFORE DELETE ON supervision_patrol_response_episodes
      BEGIN
        SELECT RAISE(ABORT, 'patrol response episode is durable');
      END
      """
    }
  ]

  @doc false
  def ensure_schema_in_txn(%Txn{} = txn) do
    ensure_reference_schema!(txn)
    ensure_closed_set!(txn, @output_source_objects, "incompatible_patrol_output_sources_v1")

    ensure_closed_set!(
      txn,
      @episode_objects,
      "incompatible_patrol_response_acknowledgment_v1"
    )

    :ok
  end

  @doc false
  def create_supervision_episode_in_txn(%Txn{} = txn, wake_id) when is_binary(wake_id) do
    case supervision_episode_input(txn, wake_id) do
      {:ok, episode} ->
        with {:ok, stored} <- insert_or_equal_episode(txn, episode),
             {:ok, _source} <-
               insert_or_equal_source(txn, %{
                 wake_id: episode.originating_wake_id,
                 assignment_id: episode.assignment_id,
                 holder_key: episode.holder_key,
                 source_kind: "supervision_episode",
                 source_ref: episode.originating_wake_id,
                 source_version: 0,
                 root_wake_id: episode.originating_wake_id,
                 predecessor_wake_id: nil,
                 retry_ordinal: 0,
                 created_at: episode.scheduled_at
               }) do
          {:ok, stored}
        end

      :error ->
        {:error, :invalid_patrol_response_episode}
    end
  end

  def create_supervision_episode_in_txn(%Txn{}, _wake_id),
    do: {:error, :invalid_patrol_response_episode}

  @doc false
  def create_effort_source_in_txn(%Txn{} = txn, wake_id, source_kind, source_ref, source_version)
      when is_binary(wake_id) and source_kind in @source_kinds and is_binary(source_ref) and
             is_integer(source_version) and source_version >= 0 do
    case effort_source_input(txn, wake_id, source_kind, source_ref, source_version) do
      {:ok, source} -> insert_or_equal_source(txn, source)
      :error -> {:error, :invalid_patrol_output_source}
    end
  end

  def create_effort_source_in_txn(%Txn{}, _wake, _kind, _ref, _version),
    do: {:error, :invalid_patrol_output_source}

  @doc false
  def create_effort_delivery_retry_in_txn(
        %Txn{} = txn,
        wake_id,
        source_kind,
        source_ref,
        source_version,
        delivery_wake_id
      )
      when is_binary(wake_id) and source_kind in @source_kinds and is_binary(source_ref) and
             is_integer(source_version) and source_version >= 0 and
             is_binary(delivery_wake_id) do
    with {:ok, source} <-
           effort_source_input(txn, wake_id, source_kind, source_ref, source_version),
         %{state: "pending"} = predecessor <-
           existing_effort_source_in_txn(txn, source_kind, source_ref, source_version),
         true <- retry_identity_equal?(predecessor, source),
         true <- coherent_retry_chain?(txn, predecessor.wake_id),
         true <- last_chain_member?(txn, predecessor.wake_id),
         [[1]] <-
           Txn.q(
             txn,
             """
             SELECT 1 FROM patrol_output_sources delivery
             JOIN wakes w ON w.wakeId=delivery.wakeId
             WHERE delivery.wakeId=?1 AND delivery.assignmentId=?2 AND w.state='pending'
             """,
             [delivery_wake_id, source.assignment_id]
           ) do
      retry = %{
        source
        | root_wake_id: predecessor.root_wake_id,
          predecessor_wake_id: predecessor.wake_id,
          retry_ordinal: predecessor.retry_ordinal + 1
      }

      with {:ok, stored} <- insert_or_equal_source(txn, retry),
           true <-
             Wakes.cancel_in_txn(txn, %{
               wake_id: predecessor.wake_id,
               requester: %{kind: "process", id: "tightbeam:effort-checkin"},
               reason_kind: "superseded",
               causal_source: %{kind: "wake", id: delivery_wake_id},
               outcome: %{kind: "replacement", replacement_wake_id: wake_id}
             }) do
        {:ok, stored}
      else
        _ -> {:error, :patrol_output_source_conflict}
      end
    else
      _ -> {:error, :patrol_output_source_conflict}
    end
  end

  def create_effort_delivery_retry_in_txn(
        %Txn{},
        _wake,
        _kind,
        _ref,
        _version,
        _delivery_wake
      ),
      do: {:error, :patrol_output_source_conflict}

  @doc false
  def existing_effort_source_in_txn(%Txn{} = txn, source_kind, source_ref, source_version) do
    case Txn.q(
           txn,
           """
           SELECT p.wakeId,p.assignmentId,p.holderKey,p.sourceKind,p.sourceRef,
                  p.sourceVersion,p.rootWakeId,p.predecessorWakeId,p.retryOrdinal,
                  p.createdAt,w.sessionKey,w.state
           FROM patrol_output_sources p JOIN wakes w ON w.wakeId=p.wakeId
           WHERE p.sourceKind=?1 AND p.sourceRef=?2 AND p.sourceVersion=?3
           ORDER BY p.retryOrdinal DESC LIMIT 1
           """,
           [source_kind, source_ref, source_version]
         ) do
      [
        [
          wake,
          assignment,
          holder,
          kind,
          ref,
          version,
          root,
          predecessor,
          ordinal,
          created_at,
          destination,
          state
        ]
      ] ->
        source_from_row([
          wake,
          assignment,
          holder,
          kind,
          ref,
          version,
          root,
          predecessor,
          ordinal,
          created_at,
          destination
        ])
        |> Map.put(:state, state)

      [] ->
        nil
    end
  end

  @doc false
  def attach_destination_retry_in_txn(%Txn{} = txn, predecessor_wake_id, replacement_wake_id)
      when is_binary(predecessor_wake_id) and is_binary(replacement_wake_id) do
    case source_for_wake(txn, predecessor_wake_id) do
      nil ->
        :ordinary

      predecessor ->
        with true <- coherent_retry_chain?(txn, predecessor_wake_id),
             true <- last_chain_member?(txn, predecessor_wake_id),
             [[assignment_id, created_at, destination]] <-
               Txn.q(
                 txn,
                 "SELECT assignmentId,createdAt,sessionKey FROM wakes WHERE wakeId=?1 AND state='pending'",
                 [replacement_wake_id]
               ),
             true <- assignment_id == predecessor.assignment_id do
          retry = %{
            predecessor
            | wake_id: replacement_wake_id,
              predecessor_wake_id: predecessor_wake_id,
              retry_ordinal: predecessor.retry_ordinal + 1,
              created_at: created_at,
              destination: destination
          }

          case insert_or_equal_source(txn, retry) do
            {:ok, stored} ->
              if retry_source_current?(txn, stored),
                do: {:ok, stored},
                else: {:error, :patrol_output_source_conflict}

            error ->
              error
          end
        else
          _ -> {:error, :patrol_output_source_conflict}
        end
    end
  end

  def attach_destination_retry_in_txn(%Txn{}, _predecessor, _replacement),
    do: {:error, :patrol_output_source_conflict}

  @doc false
  def acknowledge_in_txn(%Txn{} = txn, answer_terminal_id)
      when is_integer(answer_terminal_id) and answer_terminal_id > 0 do
    candidate =
      case Txn.q(txn, "SELECT wakeId FROM turns WHERE seq=?1", [answer_terminal_id]) do
        [[wake_id]] when is_binary(wake_id) -> acknowledgment_candidate(txn, answer_terminal_id)
        _ -> nil
      end

    case candidate do
      nil ->
        :not_acknowledged

      candidate ->
        case candidate.answer_terminal_id do
          ^answer_terminal_id ->
            {:acknowledged, candidate}

          nil ->
            if coherent_retry_chain?(txn, candidate.answer_wake_id) do
              Txn.q(
                txn,
                """
                UPDATE supervision_patrol_response_episodes
                SET answerTerminalId=?2, acknowledgedAt=?3,
                    acknowledgmentCause='patrol_answer_terminal',
                    acknowledgmentPrincipal='process:tightbeam'
                WHERE originatingWakeId=?1 AND answerTerminalId IS NULL
                """,
                [candidate.originating_wake_id, answer_terminal_id, candidate.ended_at]
              )

              if Txn.changes(txn) == 1 do
                {:acknowledged, %{candidate | answer_terminal_id: answer_terminal_id}}
              else
                acknowledgment_after_lost_update(
                  txn,
                  candidate.originating_wake_id,
                  answer_terminal_id
                )
              end
            else
              :not_acknowledged
            end

          _other ->
            {:error, :patrol_response_acknowledgment_conflict}
        end
    end
  rescue
    _error in Tightbeam.DB.Error -> :not_acknowledged
  end

  def acknowledge_in_txn(%Txn{}, _answer_terminal_id), do: :not_acknowledged

  @doc false
  def acknowledged_terminal_in_txn?(%Txn{} = txn, assignment_id, terminal_id) do
    case acknowledgment_candidate(txn, terminal_id) do
      %{
        assignment_id: ^assignment_id,
        answer_terminal_id: ^terminal_id,
        answer_wake_id: answer_wake_id
      } ->
        coherent_retry_chain?(txn, answer_wake_id)

      _ ->
        false
    end
  end

  @doc false
  def admit_delivery_in_txn(%Txn{} = txn, wake_id, destination)
      when is_binary(wake_id) and is_binary(destination) do
    case source_for_wake(txn, wake_id) do
      nil ->
        :ordinary

      source ->
        case wake_state(txn, wake_id) do
          "pending" ->
            case admission_stop(txn, source, destination, "pending", now()) do
              nil -> :admit
              stop -> cancel_stopped_wake_in_txn(txn, source, stop)
            end

          state when state in ["fired", "canceled"] ->
            :replay

          _ ->
            raise "patrol output wake #{wake_id} is missing"
        end
    end
  end

  def admit_delivery_in_txn(%Txn{}, _wake_id, _destination), do: :ordinary

  @doc false
  def admit_internal_in_txn(%Txn{} = txn, wake_id, expected_kind) do
    case source_for_wake(txn, wake_id) do
      %{source_kind: ^expected_kind} = source ->
        case wake_state(txn, wake_id) do
          "pending" ->
            case admission_stop(txn, source, source.destination, "pending", now()) do
              nil ->
                :admit

              %{kind: :block} = stop when expected_kind == "effort_generation_probe" ->
                {:blocked, stop}

              stop ->
                cancel_stopped_wake_in_txn(txn, source, stop)
            end

          state when state in ["fired", "canceled"] ->
            :replay

          _ ->
            raise "patrol output wake #{wake_id} is missing"
        end

      nil ->
        :ordinary

      source ->
        cancel_stopped_wake_in_txn(txn, source, %{
          kind: :mismatch,
          at: now(),
          detail: "sourceKind"
        })
    end
  end

  @doc false
  def admit_turn_in_txn(%Txn{} = txn, seq, clock)
      when is_integer(seq) and is_integer(clock) and clock >= 0 do
    case Txn.q(
           txn,
           "SELECT wakeId,assignmentId,sessionKey,status FROM turns WHERE seq=?1",
           [seq]
         ) do
      [[wake_id, assignment_id, destination, "queued"]] when is_binary(wake_id) ->
        case source_for_wake(txn, wake_id) do
          nil ->
            :ordinary

          source ->
            stop =
              if source.assignment_id == assignment_id do
                admission_stop(txn, source, destination, "fired", clock)
              else
                %{kind: :mismatch, at: clock, detail: "turn.assignmentId"}
              end

            if is_nil(stop), do: :admit, else: cancel_stopped_turn_in_txn(txn, seq, source, stop)
        end

      _ ->
        :ordinary
    end
  end

  @doc false
  def tombstone_assignment_in_txn(%Txn{} = txn, assignment_id, requester_id, at)
      when is_binary(assignment_id) and is_binary(requester_id) and is_integer(at) do
    sources_for_assignment(txn, assignment_id, "pending")
    |> Enum.each(fn source ->
      cancel_stopped_wake_in_txn(txn, source, %{
        kind: :lifecycle,
        at: at,
        detail: "assignment_transition",
        requester_id: requester_id
      })
    end)

    Txn.q(
      txn,
      """
      SELECT t.seq,p.wakeId,p.assignmentId,p.holderKey,p.sourceKind,p.sourceRef,
             p.sourceVersion,p.rootWakeId,p.predecessorWakeId,p.retryOrdinal,
             p.createdAt,w.sessionKey
      FROM turns t
      JOIN patrol_output_sources p ON p.wakeId=t.wakeId
      JOIN wakes w ON w.wakeId=p.wakeId
      WHERE p.assignmentId=?1 AND t.status='queued'
      ORDER BY t.seq
      """,
      [assignment_id]
    )
    |> Enum.each(fn [seq | row] ->
      source = source_from_row(row)

      cancel_stopped_turn_in_txn(txn, seq, source, %{
        kind: :lifecycle,
        at: at,
        detail: "assignment_transition"
      })
    end)

    :ok
  end

  @doc false
  def recognize_block_in_txn(%Txn{} = txn, %{kind: "work-blocked", scope: holder} = fact)
      when is_binary(holder) do
    Txn.q(
      txn,
      "SELECT id FROM assignments WHERE holderKey=?1 AND state='open' ORDER BY openedAt,id",
      [holder]
    )
    |> List.flatten()
    |> Enum.each(fn assignment_id ->
      Escalation.effort_supersede_open_in_txn(txn, assignment_id)

      sources_for_assignment(txn, assignment_id, "pending")
      |> Enum.filter(fn source ->
        String.starts_with?(source.source_kind, "effort_") and
          source.source_kind != "effort_generation_probe"
      end)
      |> Enum.each(fn source ->
        cancel_stopped_wake_in_txn(txn, source, %{
          kind: :block,
          at: fact.ts,
          fact_id: fact.fact_id,
          detail: "work-blocked"
        })
      end)
    end)

    :ok
  end

  def recognize_block_in_txn(%Txn{}, _fact), do: :ok

  defp supervision_episode_input(txn, wake_id) do
    case Txn.q(
           txn,
           """
           SELECT w.assignmentId,a.holderKey,w.createdAt,w.reresolve,w.reresolveSeed,
                  w.reresolveRung,s.wakeKind,m.pendingBranch,m.pendingAssignment,
                  m.pendingK,m.lastEvaluatedTerminal,source.sessionKey,source.status,
                  a.state,s.controllerOrigin,s.controllerState
           FROM wakes w
           JOIN assignments a ON a.id=w.assignmentId
           JOIN supervision_liveness_sidecar s ON s.wakeId=w.wakeId
           JOIN supervision_watermarks m ON m.sessionKey=a.holderKey
           JOIN turns source ON source.seq=m.lastEvaluatedTerminal
           WHERE w.wakeId=?1 AND w.origin='process:tightbeam'
             AND w.consumer='prompt' AND w.state='pending'
           """,
           [wake_id]
         ) do
      [
        [
          assignment_id,
          holder,
          scheduled_at,
          reresolve,
          seed,
          wake_rung,
          branch,
          branch,
          assignment_id,
          rung,
          terminal_id,
          holder,
          terminal_status,
          "open",
          "scheduled",
          "pending"
        ]
      ]
      when branch in ["prod", "escalation"] and is_integer(rung) and rung > 0 and
             is_integer(terminal_id) and terminal_id > 0 and
             terminal_status in ["delivered", "canceled", "failed", "failed_unknown"] ->
        lineage_ok =
          (branch == "prod" and is_nil(reresolve) and is_nil(seed) and is_nil(wake_rung)) or
            (branch == "escalation" and reresolve == "lineage" and seed == holder and
               wake_rung == rung)

        if lineage_ok do
          {:ok,
           %{
             assignment_id: assignment_id,
             originating_wake_id: wake_id,
             recovery_branch: branch,
             recovery_rung: rung,
             source_terminal_id: terminal_id,
             scheduled_at: scheduled_at,
             holder_key: holder
           }}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp insert_or_equal_episode(txn, episode) do
    Txn.q(
      txn,
      """
      INSERT INTO supervision_patrol_response_episodes
        (assignmentId,originatingWakeId,recoveryBranch,recoveryRung,sourceTerminalId,
         answerTerminalId,scheduledAt,acknowledgedAt,scheduledCause,scheduledPrincipal,
         acknowledgmentCause,acknowledgmentPrincipal)
      VALUES (?1,?2,?3,?4,?5,NULL,?6,NULL,'patrol_wake_scheduled','process:tightbeam',NULL,NULL)
      ON CONFLICT DO NOTHING
      """,
      [
        episode.assignment_id,
        episode.originating_wake_id,
        episode.recovery_branch,
        episode.recovery_rung,
        episode.source_terminal_id,
        episode.scheduled_at
      ]
    )

    stored = episode_by_wake(txn, episode.originating_wake_id)

    if episode_equal?(stored, episode),
      do: {:ok, stored},
      else: {:error, :patrol_response_episode_conflict}
  end

  defp episode_by_wake(txn, wake_id) do
    case Txn.q(
           txn,
           """
           SELECT assignmentId,originatingWakeId,recoveryBranch,recoveryRung,
                  sourceTerminalId,answerTerminalId,scheduledAt
           FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1
           """,
           [wake_id]
         ) do
      [[assignment, wake, branch, rung, source_terminal, answer_terminal, scheduled_at]] ->
        %{
          assignment_id: assignment,
          originating_wake_id: wake,
          recovery_branch: branch,
          recovery_rung: rung,
          source_terminal_id: source_terminal,
          answer_terminal_id: answer_terminal,
          scheduled_at: scheduled_at
        }

      [] ->
        nil
    end
  end

  defp episode_equal?(stored, expected) when is_map(stored) do
    Enum.all?(
      ~w(assignment_id originating_wake_id recovery_branch recovery_rung source_terminal_id scheduled_at)a,
      &(Map.fetch!(stored, &1) == Map.fetch!(expected, &1))
    )
  end

  defp episode_equal?(_, _), do: false

  defp effort_source_input(
         txn,
         wake_id,
         source_kind,
         expected_ref,
         expected_version
       )
       when source_kind in ["effort_decision_notification", "effort_decision_deadline"] do
    request = Escalation.effort_open_by_id_in_txn(txn, expected_ref)

    expected_destination =
      case request do
        %{expecter_session_key: destination} when is_binary(destination) ->
          destination

        %{expecter_user_id: user_id} when is_binary(user_id) ->
          "agent:main:clawline:" <> user_id <> ":main"

        _ ->
          nil
      end

    wake_rows =
      case request do
        %{assignment_id: assignment_id} ->
          Txn.q(
            txn,
            """
            SELECT a.holderKey,w.createdAt,w.sessionKey,w.consumer
            FROM assignments a
            JOIN sessions h ON h.sessionKey=a.holderKey
            JOIN wakes w ON w.assignmentId=a.id
            WHERE a.id=?1 AND w.wakeId=?2 AND a.state='open' AND h.state='active'
            """,
            [assignment_id, wake_id]
          )

        _ ->
          []
      end

    valid_kind =
      case {source_kind, request, wake_rows} do
        {"effort_decision_notification", %{lineage_rung: ^expected_version},
         [
           [_holder, _created_at, ^expected_destination, "prompt"]
         ]} ->
          true

        {"effort_decision_deadline",
         %{lineage_rung: ^expected_version, deadline_wake_id: ^wake_id},
         [
           [_holder, _created_at, ^expected_destination, "effort_deadline"]
         ]} ->
          true

        _ ->
          false
      end

    case {valid_kind, request, wake_rows} do
      {true, %{assignment_id: assignment}, [[holder, created_at, destination, _consumer]]} ->
        {:ok,
         %{
           wake_id: wake_id,
           assignment_id: assignment,
           holder_key: holder,
           source_kind: source_kind,
           source_ref: expected_ref,
           source_version: expected_version,
           root_wake_id: wake_id,
           predecessor_wake_id: nil,
           retry_ordinal: 0,
           created_at: created_at,
           destination: destination
         }}

      _ ->
        :error
    end
  end

  defp effort_source_input(txn, wake_id, source_kind, expected_ref, expected_version) do
    query =
      case source_kind do
        "effort_generation_probe" ->
          """
          SELECT g.assignmentId,a.holderKey,g.assignmentId,g.generation,w.createdAt,w.sessionKey
          FROM effort_checkin_generations g JOIN assignments a ON a.id=g.assignmentId
          JOIN sessions h ON h.sessionKey=a.holderKey JOIN wakes w ON w.wakeId=g.wakeId
          WHERE g.wakeId=?1 AND g.assignmentId=?2 AND g.generation=?3
            AND a.state='open' AND h.state='active'
            AND g.holderKey=a.holderKey AND w.sessionKey=a.holderKey
          """

        "effort_generation_prod" ->
          """
          SELECT g.assignmentId,a.holderKey,g.assignmentId,g.generation,w.createdAt,w.sessionKey
          FROM effort_checkin_generations g JOIN assignments a ON a.id=g.assignmentId
          JOIN sessions h ON h.sessionKey=a.holderKey JOIN wakes w ON w.assignmentId=g.assignmentId
          WHERE w.wakeId=?1 AND g.assignmentId=?2 AND g.generation=?3
            AND a.state='open' AND h.state='active'
            AND g.holderKey=a.holderKey AND w.sessionKey=a.holderKey
            AND g.generation=(SELECT MAX(g2.generation) FROM effort_checkin_generations g2 WHERE g2.assignmentId=g.assignmentId)
          """

        _ ->
          nil
      end

    params =
      if is_binary(expected_ref) and is_integer(expected_version),
        do: [wake_id, expected_ref, expected_version],
        else: [wake_id, expected_ref, expected_version]

    case query && Txn.q(txn, query, params) do
      [[assignment, holder, ref, version, created_at, destination]] ->
        {:ok,
         %{
           wake_id: wake_id,
           assignment_id: assignment,
           holder_key: holder,
           source_kind: source_kind,
           source_ref: to_string(ref),
           source_version: version,
           root_wake_id: wake_id,
           predecessor_wake_id: nil,
           retry_ordinal: 0,
           created_at: created_at,
           destination: destination
         }}

      _ ->
        :error
    end
  end

  defp insert_or_equal_source(txn, source) do
    Txn.q(
      txn,
      """
      INSERT INTO patrol_output_sources
        (wakeId,assignmentId,holderKey,sourceKind,sourceRef,sourceVersion,
         rootWakeId,predecessorWakeId,retryOrdinal,createdAt,sourceCause,sourcePrincipal)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,
              'patrol_output_scheduled','process:tightbeam')
      ON CONFLICT DO NOTHING
      """,
      [
        source.wake_id,
        source.assignment_id,
        source.holder_key,
        source.source_kind,
        source.source_ref,
        source.source_version,
        source.root_wake_id,
        source.predecessor_wake_id,
        source.retry_ordinal,
        source.created_at
      ]
    )

    stored = source_for_wake(txn, source.wake_id)

    if source_equal?(stored, source),
      do: {:ok, stored},
      else: {:error, :patrol_output_source_conflict}
  end

  defp source_equal?(stored, expected) when is_map(stored) do
    Enum.all?(
      ~w(wake_id assignment_id holder_key source_kind source_ref source_version root_wake_id predecessor_wake_id retry_ordinal created_at)a,
      &(Map.fetch!(stored, &1) == Map.fetch!(expected, &1))
    )
  end

  defp source_equal?(_, _), do: false

  defp retry_identity_equal?(predecessor, source) do
    Enum.all?(
      ~w(assignment_id holder_key source_kind source_ref source_version)a,
      &(Map.fetch!(predecessor, &1) == Map.fetch!(source, &1))
    )
  end

  defp acknowledgment_candidate(txn, terminal_id) do
    case Txn.q(
           txn,
           """
           SELECT e.assignmentId,e.originatingWakeId,e.recoveryBranch,e.recoveryRung,
                  e.sourceTerminalId,e.answerTerminalId,answer.wakeId,answer.endedAt
           FROM turns answer
           JOIN wakes w ON w.wakeId=answer.wakeId
           JOIN patrol_output_sources p ON p.wakeId=answer.wakeId
           JOIN supervision_patrol_response_episodes e
             ON e.originatingWakeId=p.rootWakeId AND e.assignmentId=p.assignmentId
           JOIN assignments a ON a.id=e.assignmentId
           JOIN turns source ON source.seq=e.sourceTerminalId
           JOIN supervision_liveness_sidecar s
             ON s.wakeId=w.wakeId AND s.assignmentId=w.assignmentId
           WHERE answer.seq=?1 AND answer.status='delivered'
             AND answer.assignmentId=e.assignmentId AND w.state='fired'
             AND w.origin='process:tightbeam' AND w.consumer='prompt'
             AND w.assignmentId=e.assignmentId AND p.holderKey=a.holderKey
             AND p.sourceKind='supervision_episode'
             AND p.sourceRef=e.originatingWakeId AND p.sourceVersion=0
             AND p.rootWakeId=e.originatingWakeId AND a.state='open'
             AND source.sessionKey=a.holderKey
             AND source.status IN ('delivered','canceled','failed','failed_unknown')
             AND s.controllerOrigin='scheduled' AND s.controllerState='settled'
             AND s.wakeKind=e.recoveryBranch
             AND ((e.recoveryBranch='prod' AND w.reresolve IS NULL
                    AND w.reresolveSeed IS NULL AND w.reresolveRung IS NULL)
                  OR
                  (e.recoveryBranch='escalation' AND w.reresolve='lineage'
                    AND w.reresolveSeed=a.holderKey AND w.reresolveRung=e.recoveryRung))
           """,
           [terminal_id]
         ) do
      [[assignment, root, branch, rung, source_terminal, answer_terminal, answer_wake, ended_at]] ->
        %{
          assignment_id: assignment,
          originating_wake_id: root,
          recovery_branch: branch,
          recovery_rung: rung,
          source_terminal_id: source_terminal,
          answer_terminal_id: answer_terminal,
          answer_wake_id: answer_wake,
          ended_at: ended_at
        }

      _ ->
        nil
    end
  end

  defp acknowledgment_after_lost_update(txn, wake_id, terminal_id) do
    case episode_by_wake(txn, wake_id) do
      %{answer_terminal_id: ^terminal_id} = episode -> {:acknowledged, episode}
      %{answer_terminal_id: nil} -> :not_acknowledged
      _ -> {:error, :patrol_response_acknowledgment_conflict}
    end
  end

  defp coherent_retry_chain?(txn, wake_id) do
    case source_for_wake(txn, wake_id) do
      %{retry_ordinal: 0, predecessor_wake_id: nil, root_wake_id: ^wake_id} ->
        true

      %{retry_ordinal: ordinal, root_wake_id: root} when ordinal > 0 ->
        [[count, min_ordinal, max_ordinal]] =
          Txn.q(
            txn,
            """
            WITH RECURSIVE chain(wakeId,predecessorWakeId,retryOrdinal) AS (
              SELECT wakeId,predecessorWakeId,retryOrdinal FROM patrol_output_sources WHERE wakeId=?1
              UNION ALL
              SELECT p.wakeId,p.predecessorWakeId,p.retryOrdinal
              FROM patrol_output_sources p JOIN chain c ON p.wakeId=c.predecessorWakeId
            )
            SELECT COUNT(*),MIN(retryOrdinal),MAX(retryOrdinal) FROM chain
            """,
            [wake_id]
          )

        count == ordinal + 1 and min_ordinal == 0 and max_ordinal == ordinal and
          Txn.q(
            txn,
            "SELECT 1 FROM patrol_output_sources WHERE wakeId=?1 AND rootWakeId=?1 AND retryOrdinal=0",
            [root]
          ) == [[1]] and retry_cancellations_coherent?(txn, wake_id)

      _ ->
        false
    end
  end

  defp retry_cancellations_coherent?(txn, wake_id) do
    Txn.q(
      txn,
      """
      WITH RECURSIVE chain(wakeId,predecessorWakeId,retryOrdinal) AS (
        SELECT wakeId,predecessorWakeId,retryOrdinal FROM patrol_output_sources WHERE wakeId=?1
        UNION ALL
        SELECT p.wakeId,p.predecessorWakeId,p.retryOrdinal
        FROM patrol_output_sources p JOIN chain c ON p.wakeId=c.predecessorWakeId
      )
      SELECT COUNT(*)
      FROM chain child
      JOIN wake_cancellations c ON c.wakeId=child.predecessorWakeId
        AND c.outcomeKind='replacement' AND c.replacementWakeId=child.wakeId
      WHERE child.retryOrdinal>0
      """,
      [wake_id]
    ) == [[source_for_wake(txn, wake_id).retry_ordinal]]
  end

  defp admission_stop(txn, source, destination, expected_wake_state, admission_clock) do
    cond do
      source.destination != destination ->
        %{kind: :mismatch, at: admission_clock, detail: "destination"}

      not coherent_retry_chain?(txn, source.wake_id) ->
        %{kind: :mismatch, at: admission_clock, detail: "retryChain"}

      not last_chain_member?(txn, source.wake_id) ->
        %{kind: :mismatch, at: admission_clock, detail: "retryTail"}

      not source_current?(txn, source) ->
        %{kind: :mismatch, at: admission_clock, detail: "typedSource"}

      true ->
        admission_state_stop(
          txn,
          source,
          destination,
          expected_wake_state,
          admission_clock
        )
    end
  end

  defp last_chain_member?(txn, wake_id) do
    Txn.q(txn, "SELECT 1 FROM patrol_output_sources WHERE predecessorWakeId=?1 LIMIT 1", [wake_id]) ==
      []
  end

  defp source_current?(txn, %{source_kind: "supervision_episode"} = source) do
    Txn.q(
      txn,
      """
      SELECT 1 FROM supervision_patrol_response_episodes e
      JOIN assignments a ON a.id=e.assignmentId
      JOIN wakes w ON w.wakeId=?2 AND w.assignmentId=e.assignmentId
      JOIN supervision_liveness_sidecar s ON s.wakeId=w.wakeId AND s.assignmentId=e.assignmentId
      WHERE e.originatingWakeId=?1 AND e.assignmentId=?3
        AND s.controllerOrigin='scheduled' AND s.wakeKind=e.recoveryBranch
        AND w.origin='process:tightbeam' AND w.consumer='prompt'
        AND ((e.recoveryBranch='prod' AND w.sessionKey=a.holderKey
              AND w.reresolve IS NULL AND w.reresolveSeed IS NULL AND w.reresolveRung IS NULL)
          OR (e.recoveryBranch='escalation' AND w.reresolve='lineage'
              AND w.reresolveSeed=a.holderKey AND w.reresolveRung=e.recoveryRung))
      """,
      [source.source_ref, source.wake_id, source.assignment_id]
    ) == [[1]]
  end

  defp source_current?(txn, %{source_kind: "effort_generation_probe"} = source) do
    Txn.q(
      txn,
      """
      SELECT 1 FROM effort_checkin_generations g
      JOIN wakes w ON w.wakeId=?5 AND w.assignmentId=g.assignmentId
      WHERE g.assignmentId=?1 AND g.generation=?2 AND g.wakeId=?3
        AND g.holderKey=?4 AND g.state='armed' AND w.sessionKey=?4
      """,
      [
        source.source_ref,
        source.source_version,
        source.root_wake_id,
        source.holder_key,
        source.wake_id
      ]
    ) == [[1]]
  end

  defp source_current?(txn, %{source_kind: "effort_generation_prod"} = source) do
    Txn.q(
      txn,
      """
      SELECT 1 FROM effort_checkin_generations g
      JOIN wakes w ON w.wakeId=?4 AND w.assignmentId=g.assignmentId
      WHERE g.assignmentId=?1 AND g.generation=?2 AND g.holderKey=?3
        AND g.state='probed' AND w.sessionKey=?3
      """,
      [source.source_ref, source.source_version, source.holder_key, source.wake_id]
    ) == [[1]]
  end

  defp source_current?(txn, %{source_kind: "effort_decision_notification"} = source) do
    case Escalation.effort_open_by_id_in_txn(txn, source.source_ref) do
      %{
        assignment_id: assignment_id,
        lineage_rung: version,
        expecter_session_key: session_key,
        expecter_user_id: user_id
      } ->
        destination = session_key || "agent:main:clawline:" <> user_id <> ":main"

        assignment_id == source.assignment_id and version == source.source_version and
          destination == source.destination

      _ ->
        false
    end
  end

  defp source_current?(txn, %{source_kind: "effort_decision_deadline"} = source) do
    case Escalation.effort_open_by_id_in_txn(txn, source.source_ref) do
      %{
        assignment_id: assignment_id,
        lineage_rung: version,
        deadline_wake_id: deadline_wake_id,
        expecter_session_key: session_key,
        expecter_user_id: user_id
      } ->
        destination = session_key || "agent:main:clawline:" <> user_id <> ":main"

        assignment_id == source.assignment_id and version == source.source_version and
          deadline_wake_id == source.wake_id and destination == source.destination

      _ ->
        false
    end
  end

  defp source_current?(_txn, _source), do: false

  defp retry_source_current?(txn, source) do
    source_current?(txn, source) and
      is_nil(
        admission_state_stop(
          txn,
          source,
          source.destination,
          "pending",
          source.created_at
        )
      )
  end

  defp admission_state_stop(txn, source, destination, expected_wake_state, admission_clock) do
    block = standing_block(txn, source.holder_key)

    case Txn.q(
           txn,
           """
           SELECT w.state,a.state,a.holderKey,a.closedAt,h.state,h.updatedAt,d.state,d.updatedAt
           FROM wakes w JOIN assignments a ON a.id=?2
           LEFT JOIN sessions h ON h.sessionKey=?3
           LEFT JOIN sessions d ON d.sessionKey=?4
           WHERE w.wakeId=?1
           """,
           [source.wake_id, source.assignment_id, source.holder_key, destination]
         ) do
      [[wake_state, "open", holder, _closed_at, "active", _holder_at, "active", _dest_at]]
      when wake_state == expected_wake_state and holder == source.holder_key ->
        if block, do: %{kind: :block, at: block.ts, fact_id: block.id, detail: "work-blocked"}

      [
        [
          _wake_state,
          assignment_state,
          holder,
          closed_at,
          holder_state,
          _holder_at,
          dest_state,
          _dest_at
        ]
      ] ->
        cond do
          assignment_state != "open" ->
            %{kind: :lifecycle, at: closed_at || now(), detail: "assignment.state"}

          holder != source.holder_key ->
            %{kind: :mismatch, at: admission_clock, detail: "assignment.holderKey"}

          holder_state != "active" ->
            %{kind: :mismatch, at: admission_clock, detail: "holder.state"}

          dest_state != "active" ->
            %{kind: :mismatch, at: admission_clock, detail: "destination.state"}

          true ->
            %{kind: :mismatch, at: admission_clock, detail: "wake.state"}
        end

      _ ->
        %{kind: :mismatch, at: admission_clock, detail: "durableJoin"}
    end
  end

  defp standing_block(txn, holder) do
    case Txn.q(
           txn,
           """
           SELECT id,ts FROM condition_facts
           WHERE kind IN ('work-blocked','work-unblocked') AND scope=?1
           ORDER BY id DESC LIMIT 1
           """,
           [holder]
         ) do
      [[id, ts]] ->
        case Txn.q(txn, "SELECT kind FROM condition_facts WHERE id=?1", [id]) do
          [["work-blocked"]] -> %{id: id, ts: ts}
          _ -> nil
        end

      [] ->
        nil
    end
  end

  defp cancel_stopped_wake_in_txn(txn, source, stop) do
    {reason, causal_source, requester} =
      case stop.kind do
        :block ->
          {"production_unmatched", %{kind: "condition_fact", id: to_string(stop.fact_id)},
           "tightbeam:wake-scheduler"}

        :lifecycle ->
          {"obligation_disposed", %{kind: "assignment_transition", id: source.assignment_id},
           Map.get(stop, :requester_id, "tightbeam:assignments")}

        :mismatch ->
          {"patrol_source_mismatch", %{kind: "scheduler_delivery", id: source.wake_id},
           "tightbeam:wake-scheduler"}
      end

    outcome =
      if stop.kind == :lifecycle do
        %{
          kind: "disposition",
          disposition_kind: "assignment_transition",
          disposition_id: source.assignment_id
        }
      else
        %{kind: "no_replacement"}
      end

    command = %{
      wake_id: source.wake_id,
      requester: %{kind: "process", id: requester},
      reason_kind: reason,
      causal_source: causal_source,
      outcome: put_liveness_trigger(txn, source.assignment_id, outcome)
    }

    cond do
      Wakes.cancel_in_txn(txn, command) ->
        {:stopped, stop.kind}

      stopped_wake_already_recorded?(txn, source, reason, causal_source, outcome) ->
        {:stopped, stop.kind}

      true ->
        raise "patrol stop cancellation refused for #{source.wake_id}"
    end
  end

  defp stopped_wake_already_recorded?(txn, source, reason, causal_source, outcome) do
    expected_outcome = if outcome.kind == "disposition", do: "disposition", else: "no_replacement"

    Txn.q(
      txn,
      """
      SELECT 1 FROM wake_cancellations
      WHERE wakeId=?1 AND reasonKind=?2 AND causalSourceKind=?3 AND causalSourceId=?4
        AND outcomeKind=?5 AND replacementWakeId IS NULL
      """,
      [source.wake_id, reason, causal_source.kind, causal_source.id, expected_outcome]
    ) == [[1]]
  end

  defp put_liveness_trigger(txn, assignment_id, outcome) do
    primary =
      case Txn.q(txn, "SELECT state,workItemId FROM assignments WHERE id=?1", [assignment_id]) do
        [["open", _]] -> {:assignment, assignment_id}
        [[_, work_item]] when is_binary(work_item) -> {:work_item, work_item}
        _ -> nil
      end

    case primary && Supervision.liveness_trigger_in_txn(txn, primary) do
      {:ok, trigger} -> Map.put(outcome, :liveness_trigger, trigger)
      _ -> outcome
    end
  end

  defp cancel_stopped_turn_in_txn(txn, seq, source, stop) do
    Txn.q(
      txn,
      "UPDATE turns SET status='canceled',endedAt=?2,error=?3 WHERE seq=?1 AND status='queued'",
      [seq, stop.at, "patrol stop: #{stop.detail}"]
    )

    if Txn.changes(txn) == 1 do
      EventLog.lifecycle_in_txn(
        txn,
        "patrol_turn_stopped",
        to_string(seq),
        "wakeId=#{source.wake_id} assignmentId=#{source.assignment_id} sourceKind=#{source.source_kind} sourceRef=#{source.source_ref} sourceVersion=#{source.source_version} cause=#{stop.detail} principal=process:tightbeam outcome=no_replacement"
      )
    end

    :canceled
  end

  defp source_for_wake(txn, wake_id) do
    case Txn.q(
           txn,
           """
           SELECT p.wakeId,p.assignmentId,p.holderKey,p.sourceKind,p.sourceRef,
                  p.sourceVersion,p.rootWakeId,p.predecessorWakeId,p.retryOrdinal,
                  p.createdAt,w.sessionKey
           FROM patrol_output_sources p JOIN wakes w ON w.wakeId=p.wakeId
           WHERE p.wakeId=?1
           """,
           [wake_id]
         ) do
      [row] -> source_from_row(row)
      _ -> nil
    end
  end

  defp wake_state(txn, wake_id) do
    case Txn.q(txn, "SELECT state FROM wakes WHERE wakeId=?1", [wake_id]) do
      [[state]] -> state
      [] -> nil
    end
  end

  defp sources_for_assignment(txn, assignment_id, state) do
    Txn.q(
      txn,
      """
      SELECT p.wakeId,p.assignmentId,p.holderKey,p.sourceKind,p.sourceRef,
             p.sourceVersion,p.rootWakeId,p.predecessorWakeId,p.retryOrdinal,
             p.createdAt,w.sessionKey
      FROM patrol_output_sources p JOIN wakes w ON w.wakeId=p.wakeId
      WHERE p.assignmentId=?1 AND w.state=?2 ORDER BY p.createdAt,p.wakeId
      """,
      [assignment_id, state]
    )
    |> Enum.map(&source_from_row/1)
  end

  defp source_from_row([
         wake,
         assignment,
         holder,
         kind,
         ref,
         version,
         root,
         predecessor,
         ordinal,
         created_at,
         destination
       ]) do
    %{
      wake_id: wake,
      assignment_id: assignment,
      holder_key: holder,
      source_kind: kind,
      source_ref: ref,
      source_version: version,
      root_wake_id: root,
      predecessor_wake_id: predecessor,
      retry_ordinal: ordinal,
      created_at: created_at,
      destination: destination
    }
  end

  defp now, do: System.system_time(:millisecond)

  defp ensure_closed_set!(txn, objects, refusal) do
    present = Enum.filter(objects, &object_present?(txn, &1, refusal))

    case length(present) do
      0 ->
        Enum.each(objects, fn object ->
          :ok = Txn.exec(txn, object.sql)
          validate_object!(txn, object, refusal)
        end)

      count when count == length(objects) ->
        Enum.each(objects, &validate_object!(txn, &1, refusal))

      _ ->
        missing = objects -- present

        refuse!(
          refusal,
          "incomplete additive shape; missing #{Enum.map_join(missing, ", ", & &1.name)}"
        )
    end
  end

  defp object_present?(txn, %{type: type, name: name}, refusal) do
    case Txn.q(txn, "SELECT 1 FROM sqlite_schema WHERE type=?1 AND name=?2", [type, name]) do
      [] -> false
      [[1]] -> true
      _ -> refuse!(refusal, "duplicate owned object #{name}")
    end
  end

  defp validate_object!(txn, %{type: type, name: name} = object, refusal) do
    case Txn.q(txn, "SELECT sql FROM sqlite_schema WHERE type=?1 AND name=?2", [type, name]) do
      [[actual]] when is_binary(actual) ->
        [[reference]] =
          Txn.q(
            txn,
            "SELECT sql FROM #{@reference_schema}.sqlite_schema WHERE type=?1 AND name=?2",
            [type, name]
          )

        if sql_tokens(actual) == sql_tokens(reference) and
             table_images_equal?(txn, object) do
          :ok
        else
          refuse!(refusal, "unequal schema image for #{name}")
        end

      [] ->
        refuse!(refusal, "missing owned object #{name}")

      _ ->
        refuse!(refusal, "duplicate owned object #{name}")
    end
  end

  defp ensure_reference_schema!(txn) do
    unless Enum.any?(Txn.q(txn, "PRAGMA database_list"), fn [_seq, name, _path] ->
             name == @reference_schema
           end) do
      [] = Txn.q(txn, "ATTACH DATABASE ?1 AS #{@reference_schema}", [":memory:"])
    end

    reference_objects = @output_source_objects ++ @episode_objects

    case Txn.q(
           txn,
           "SELECT COUNT(*) FROM #{@reference_schema}.sqlite_schema WHERE sql IS NOT NULL"
         ) do
      [[0]] ->
        Enum.each(reference_objects, fn object ->
          :ok = Txn.exec(txn, reference_sql(object))
        end)

      [[count]] when count == length(reference_objects) ->
        :ok

      _ ->
        raise "patrol schema reference is incomplete"
    end
  end

  defp reference_sql(%{type: "table", name: name, sql: sql}) do
    String.replace(
      sql,
      "CREATE TABLE #{name}",
      "CREATE TABLE #{@reference_schema}.#{name}",
      global: false
    )
  end

  defp reference_sql(%{type: "trigger", name: name, sql: sql}) do
    String.replace(
      sql,
      "CREATE TRIGGER #{name}",
      "CREATE TRIGGER #{@reference_schema}.#{name}",
      global: false
    )
  end

  defp table_images_equal?(_txn, %{type: "trigger"}), do: true

  defp table_images_equal?(txn, %{type: "table", name: name}) do
    table_image(txn, "main", name) == table_image(txn, @reference_schema, name)
  end

  defp table_image(txn, schema, table) do
    %{
      columns: Txn.q(txn, "SELECT * FROM pragma_table_xinfo(?1, ?2)", [table, schema]),
      foreign_keys: Txn.q(txn, "SELECT * FROM pragma_foreign_key_list(?1, ?2)", [table, schema]),
      unique_indexes: unique_index_images(txn, schema, table)
    }
  end

  defp unique_index_images(txn, schema, table) do
    Txn.q(
      txn,
      "SELECT name,\"unique\" FROM pragma_index_list(?1, ?2) WHERE \"unique\"=1",
      [table, schema]
    )
    |> Enum.map(fn [name, unique] ->
      {unique, Txn.q(txn, "SELECT * FROM pragma_index_xinfo(?1, ?2)", [name, schema])}
    end)
    |> Enum.sort()
  end

  # Both inputs are SQLite-persisted SQL: the owned object and the exact object
  # executed in the connection's empty reference schema. This scanner retains
  # the SQLite token classes that the comparison image names: comments and
  # whitespace do not participate, unquoted words use SQLite's
  # case-insensitive identity, and quoted tokens remain byte-exact.
  defp sql_tokens(sql), do: tokenize(sql, [])

  defp tokenize(<<>>, acc), do: Enum.reverse(acc)

  defp tokenize(<<c, rest::binary>>, acc) when c in [9, 10, 11, 12, 13, 32],
    do: tokenize(rest, acc)

  defp tokenize(<<"--", rest::binary>>, acc), do: tokenize(drop_line_comment(rest), acc)
  defp tokenize(<<"/*", rest::binary>>, acc), do: tokenize(drop_block_comment(rest), acc)

  defp tokenize(<<quote, rest::binary>>, acc) when quote in [?\', ?\", ?`] do
    {token, tail} = take_quoted(rest, quote, <<quote>>)
    tokenize(tail, [token | acc])
  end

  defp tokenize(<<?[, rest::binary>>, acc) do
    {token, tail} = take_bracket(rest, "[")
    tokenize(tail, [token | acc])
  end

  defp tokenize(<<c, _::binary>> = sql, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {word, tail} = take_while(sql, &word_char?/1)
    tokenize(tail, [String.downcase(word) | acc])
  end

  defp tokenize(<<c, _::binary>> = sql, acc) when c in ?0..?9 do
    {number, tail} = take_while(sql, &number_char?/1)
    tokenize(tail, [number | acc])
  end

  defp tokenize(<<c, rest::binary>>, acc), do: tokenize(rest, [<<c>> | acc])

  defp drop_line_comment(<<>>), do: <<>>
  defp drop_line_comment(<<?\n, rest::binary>>), do: rest
  defp drop_line_comment(<<_, rest::binary>>), do: drop_line_comment(rest)

  defp drop_block_comment(<<"*/", rest::binary>>), do: rest
  defp drop_block_comment(<<_, rest::binary>>), do: drop_block_comment(rest)
  defp drop_block_comment(<<>>), do: <<>>

  defp take_quoted(<<quote, quote, rest::binary>>, quote, acc),
    do: take_quoted(rest, quote, <<acc::binary, quote, quote>>)

  defp take_quoted(<<quote, rest::binary>>, quote, acc),
    do: {<<acc::binary, quote>>, rest}

  defp take_quoted(<<c, rest::binary>>, quote, acc),
    do: take_quoted(rest, quote, <<acc::binary, c>>)

  defp take_quoted(<<>>, _quote, acc), do: {acc, <<>>}

  defp take_bracket(<<?], rest::binary>>, acc), do: {acc <> "]", rest}
  defp take_bracket(<<c, rest::binary>>, acc), do: take_bracket(rest, <<acc::binary, c>>)
  defp take_bracket(<<>>, acc), do: {acc, <<>>}

  defp take_while(binary, predicate), do: take_while(binary, predicate, <<>>)

  defp take_while(<<c, rest::binary>>, predicate, acc) do
    if predicate.(c),
      do: take_while(rest, predicate, <<acc::binary, c>>),
      else: {acc, <<c, rest::binary>>}
  end

  defp take_while(<<>>, _predicate, acc), do: {acc, <<>>}

  defp word_char?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?$]
  defp number_char?(c), do: c in ?0..?9 or c in [?., ?e, ?E]

  defp refuse!(prefix, detail), do: raise(Schema.ShapeError, message: "#{prefix}: #{detail}")
end
