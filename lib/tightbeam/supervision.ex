defmodule Tightbeam.Supervision do
  @moduledoc """
  The serialized, durable reaction executor for stalled assignments.

  This module hosts productions of a Newell PRODUCTION MACHINE (spec
  production-machine-v1): recognize-act cycles over durable working memory —
  assignments, the ledger, wakes, condition facts, and the productions' own
  bookkeeping rows (`assignment_prods`, `supervision_watermarks`). Recognition
  is declared: a production's complete left-hand side lives in one named
  function (`prod_production_matches?/3`) reading durable state only. The
  right-hand side stays procedural Elixir — half a production system done
  honestly. The turn-end schedule (`@turn_end_schedule`) is the machine's
  CONFLICT-RESOLUTION STRATEGY: several productions could fire when a turn
  ends, so they hold a fixed priority order and the first act wins the cycle.
  """

  use GenServer

  alias Tightbeam.{
    Assignments,
    CausalEvents,
    ConditionFacts,
    DB,
    Dispatch,
    Escalation,
    EventLog,
    Gateway,
    HarnessHealth,
    Ledger,
    Org,
    RailEpisodes,
    RailRemedy,
    Rules,
    Wakes
  }

  alias Tightbeam.DB.Txn

  require Logger

  @prods_ddl """
  CREATE TABLE IF NOT EXISTS assignment_prods (
    assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
    attemptCount INTEGER NOT NULL DEFAULT 0,
    prodCount INTEGER NOT NULL DEFAULT 0,
    deniedStreak INTEGER NOT NULL DEFAULT 0,
    attestCount INTEGER NOT NULL DEFAULT 0,
    lastProdAt INTEGER,
    stalledAt INTEGER,
    strandedAt INTEGER NULL
  )
  """

  @watermarks_ddl """
  CREATE TABLE IF NOT EXISTS supervision_watermarks (
    sessionKey TEXT PRIMARY KEY,
    lastEvaluatedTerminal INTEGER NOT NULL,
    pendingBranch TEXT CHECK (pendingBranch IN ('prod','escalation','terminus')),
    pendingAssignment TEXT,
    pendingK INTEGER NULL,
    pendingN INTEGER NULL
  )
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec notify_terminal(GenServer.server(), String.t(), integer()) :: :ok
  def notify_terminal(server \\ __MODULE__, session_key, terminal_seq) do
    GenServer.cast(server, {:terminal, session_key, terminal_seq})
  end

  @spec notify_retired(GenServer.server(), String.t()) :: :ok
  def notify_retired(server \\ __MODULE__, session_key) do
    GenServer.cast(server, {:retired, session_key})
  end

  @spec request_sweep(GenServer.server()) :: :ok
  def request_sweep(server \\ __MODULE__), do: GenServer.cast(server, :sweep)

  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ DB) do
    :ok = DB.execute(db, @prods_ddl)
    :ok = DB.execute(db, @watermarks_ddl)
  end

  @doc false
  @spec recover_liveness!(DB.server(), pos_integer()) :: :ok
  def recover_liveness!(db, interval) when is_integer(interval) and interval > 0 do
    recover_liveness(%{db: db, sweep_ms: interval})
  end

  @spec prod_state(DB.server(), String.t()) :: map() | nil
  def prod_state(db, assignment_id) do
    {:ok, prod_rows} =
      DB.query(
        db,
        "SELECT assignmentId, attemptCount, prodCount, deniedStreak, attestCount, lastProdAt, stalledAt, strandedAt FROM assignment_prods WHERE assignmentId = ?1",
        [assignment_id]
      )

    counters =
      case prod_rows do
        [[id, attempts, prods, denied, attests, last_prod, stalled, stranded]] ->
          %{
            assignmentId: id,
            attemptCount: attempts,
            prodCount: prods,
            deniedStreak: denied,
            attestCount: attests,
            lastProdAt: last_prod,
            stalledAt: stalled,
            strandedAt: stranded
          }

        [] ->
          nil
      end

    {:ok, entitlement_rows} =
      DB.query(
        db,
        """
        SELECT generation, dueAt, state, basisKind, basisId, terminusAt, cause,
               principal, supervisionIntervalMs
        FROM supervision_entitlements
        WHERE assignmentId=?1
        """,
        [assignment_id]
      )

    supervision =
      case entitlement_rows do
        [
          [
            generation,
            due_at,
            state,
            basis_kind,
            basis_id,
            terminus_at,
            cause,
            principal,
            interval
          ]
        ] ->
          %{
            supervisionState: state,
            supervisionGeneration: generation,
            supervisionDueAt: due_at,
            supervisionIntervalMs: interval,
            supervisionBasisKind: logical_basis_kind(basis_kind, basis_id),
            supervisionBasisId: logical_basis_id(basis_kind, basis_id),
            supervisionCause: logical_basis_kind(cause, basis_id),
            supervisionPrincipal: principal,
            supervisionTerminusAt: terminus_at,
            supervisionTransferWakeId: nil,
            supervisionTransferSessionKey: nil,
            supervisionRetirementEpoch: nil,
            supervisionRetirementOutcomeKind: nil,
            supervisionRetirementOutcomeId: nil,
            supervisionActionNeeded: nil
          }

        [] ->
          transfer_projection(db, assignment_id)
      end

    case {counters, supervision} do
      {nil, nil} -> nil
      {nil, projection} -> Map.merge(zero_state(assignment_id), projection)
      {state, nil} -> state
      {state, projection} -> Map.merge(state, projection)
    end
  end

  defp logical_basis_kind("progress", "receipt:" <> _receipt_id), do: "liveness_receipt"
  defp logical_basis_kind(kind, _basis_id), do: kind

  defp logical_basis_id("progress", "receipt:" <> receipt_id), do: receipt_id
  defp logical_basis_id(_kind, basis_id), do: basis_id

  @doc """
  Validate an existing accepted parent-transfer reference without creating
  ownership state. The cancellation seam uses this read-only predicate.
  """
  @spec accepted_transfer?(DB.server() | Txn.t(), String.t(), map()) :: :ok | :error
  def accepted_transfer?(db_or_txn, transfer_id, primary) do
    with {:ok, assignment_id, turn_seq} <- split_transfer_id(transfer_id),
         true <-
           {primary.kind, primary.id} == {"assignment", assignment_id} or
             assignment_belongs_to_work?(db_or_txn, assignment_id, primary),
         {:ok, _projection} <- accepted_transfer(db_or_txn, assignment_id, turn_seq) do
      :ok
    else
      _ -> :error
    end
  end

  @doc """
  The one in-transaction mutation seam used by assignment and Gateway callers.
  Every observation includes a positive `:supervision_interval_ms` when it
  creates a generation.
  """
  @spec transition_in_txn(Txn.t(), map()) ::
          :armed
          | :parent_elevated
          | :terminal_disposition
          | :duplicate
          | :canceled
          | {:armed, pos_integer()}
          | {:admit, String.t()}
          | {:error, term()}
  def transition_in_txn(%Txn{} = txn, %{
        kind: "assignment_open",
        assignment_id: assignment_id,
        opened_at: opened_at,
        principal: principal,
        supervision_interval_ms: interval
      })
      when is_integer(opened_at) and opened_at >= 0 and is_integer(interval) and interval > 0 do
    Txn.q(
      txn,
      """
      INSERT INTO supervision_entitlements
        (assignmentId, generation, dueAt, state, lastAttemptGeneration, claimClock,
         basisKind, basisId, terminusAt, cause, principal, supervisionIntervalMs)
      VALUES (?1, 1, ?2, 'armed', NULL, NULL, 'assignment_open', ?1, NULL,
              'assignment_open', ?3, ?4)
      ON CONFLICT(assignmentId) DO NOTHING
      """,
      [assignment_id, opened_at + interval, principal, interval]
    )

    result = if Txn.changes(txn) == 1, do: :armed, else: :duplicate
    ensure_liveness_receipt_state_in_txn(txn, assignment_id, "assignment_open", principal)
    result
  end

  def transition_in_txn(%Txn{} = txn, %{
        kind: "terminal_disposition",
        assignment_id: assignment_id,
        cause: cause,
        principal: principal,
        requester_id: requester_id
      }) do
    cancel_assignment_controllers_in_txn(txn, assignment_id, requester_id)
    clear_entitlement_in_txn(txn, assignment_id, cause, principal)
    :terminal_disposition
  end

  def transition_in_txn(%Txn{} = txn, %{
        kind: "checkpoint_scheduled",
        wake_id: wake_id,
        creator_session_key: creator_session_key
      }) do
    case Txn.q(
           txn,
           """
           SELECT a.id, t.seq
           FROM wakes w
           JOIN turns t ON t.sessionKey=w.sessionKey
           JOIN assignments a ON a.id=t.assignmentId
           JOIN supervision_entitlements e ON e.assignmentId=a.id
           WHERE w.wakeId=?1
             AND w.sessionKey=?2 AND w.creatorSessionKey=?2
             AND w.consumer='prompt' AND w.state='pending'
             AND w.dueAt > w.createdAt
             AND t.status='running'
             AND a.holderKey=?2 AND a.state='open'
             AND e.state IN ('armed','claimed')
           ORDER BY t.seq DESC
           LIMIT 1
           """,
           [wake_id, creator_session_key]
         ) do
      [[assignment_id, turn_seq]] ->
        Txn.q(
          txn,
          """
          INSERT INTO supervision_liveness_checkpoint_bindings
            (wakeId, assignmentId, holderSessionKey, sourceTurnSeq, boundAt, principal)
          VALUES (?1, ?2, ?3, ?4, ?5, 'process:tightbeam')
          """,
          [wake_id, assignment_id, creator_session_key, turn_seq, now()]
        )

        :armed

      [] ->
        :duplicate
    end
  end

  @doc """
  Derive exact supervision coverage for one assignment terminal.

  Only the immutable `(assignmentId, rootTurnSeq)` controller link can cover
  the source. Historical null links and links for another terminal fail safe.
  """
  @spec controller_coverage_in_txn(Txn.t(), String.t(), pos_integer()) ::
          :resolved_existing
          | :pending
          | :historical_unknown
          | :different_root
          | :none
          | {:prior_recipients, [String.t()]}
  def controller_coverage_in_txn(%Txn{} = txn, assignment_id, turn_seq)
      when is_binary(assignment_id) and is_integer(turn_seq) and turn_seq > 0 do
    rows =
      Txn.q(
        txn,
        """
        SELECT s.rootTurnSeq, w.sessionKey, w.state, t.status
        FROM supervision_liveness_sidecar s
        JOIN wakes w ON w.wakeId=s.wakeId AND w.assignmentId=s.assignmentId
        LEFT JOIN turns t ON t.wakeId=w.wakeId AND t.assignmentId=w.assignmentId
                         AND t.sessionKey=w.sessionKey
        WHERE s.assignmentId=?1 AND s.controllerOrigin IS NOT NULL
        ORDER BY w.createdAt, w.wakeId
        """,
        [assignment_id]
      )

    exact = Enum.filter(rows, fn [root_turn_seq | _] -> root_turn_seq == turn_seq end)

    prior_recipients =
      exact
      |> Enum.filter(fn [_root, _recipient, _wake_state, status] ->
        status in ["failed", "failed_unknown", "canceled"]
      end)
      |> Enum.map(fn [_root, recipient, _wake_state, _status] -> recipient end)
      |> Enum.uniq()

    cond do
      Enum.any?(exact, fn [_root, _recipient, _wake_state, status] ->
        status == "delivered"
      end) ->
        :resolved_existing

      Enum.any?(exact, fn [_root, _recipient, wake_state, status] ->
        wake_state == "pending" or status in ["queued", "running"]
      end) ->
        :pending

      prior_recipients != [] ->
        {:prior_recipients, prior_recipients}

      Enum.any?(rows, fn [root_turn_seq | _] -> is_nil(root_turn_seq) end) ->
        :historical_unknown

      Enum.any?(rows, fn [root_turn_seq | _] -> root_turn_seq != turn_seq end) ->
        :different_root

      true ->
        :none
    end
  end

  def transition_in_txn(%Txn{} = txn, %{
        kind: "parent_target_retired",
        session_key: session_key,
        retirement_epoch: retirement_epoch,
        supervision_interval_ms: supervision_interval_ms,
        principal: principal
      })
      when is_integer(retirement_epoch) and retirement_epoch >= 0 and
             is_integer(supervision_interval_ms) and supervision_interval_ms > 0 and
             is_binary(principal) do
    outcomes =
      transferred_assignments_in_txn(txn, session_key)
      |> Enum.map(fn {assignment_id, transfer} ->
        recover_retired_target_in_txn(
          txn,
          assignment_id,
          transfer,
          retirement_epoch,
          supervision_interval_ms,
          principal
        )
      end)

    cond do
      :armed in outcomes -> :armed
      :parent_elevated in outcomes -> :parent_elevated
      true -> :duplicate
    end
  end

  def transition_in_txn(%Txn{} = txn, %{
        kind: "parent_elevated",
        assignment_id: assignment_id,
        wake_id: wake_id,
        turn_seq: turn_seq,
        target_session_key: target
      }) do
    Txn.q(
      txn,
      """
      UPDATE supervision_liveness_sidecar
      SET controllerState='settled'
      WHERE wakeId=?1 AND assignmentId=?2 AND controllerOrigin='scheduled'
        AND wakeKind='escalation' AND controllerState='pending'
      """,
      [wake_id, assignment_id]
    )

    clear_entitlement_in_txn(txn, assignment_id, "parent_elevated")

    EventLog.lifecycle_in_txn(
      txn,
      "supervision_entitlement_transferred",
      assignment_id,
      "wakeId=#{wake_id} transfer=#{assignment_id}##{turn_seq} target=#{target}"
    )

    :parent_elevated
  end

  def transition_in_txn(%Txn{} = txn, %{
        kind: "controller_scheduled",
        wake_id: wake_id,
        assignment_id: assignment_id,
        wake_kind: wake_kind,
        root_turn_seq: root_turn_seq
      })
      when wake_kind in ["prod", "escalation"] and is_integer(root_turn_seq) and
             root_turn_seq > 0 do
    case Txn.q(
           txn,
           """
           SELECT generation, claimClock, supervisionIntervalMs
           FROM supervision_entitlements
           WHERE assignmentId=?1 AND state='claimed'
           """,
           [assignment_id]
         ) do
      [[generation, evaluation_clock, interval]] ->
        next_generation = generation + 1
        basis_kind = "#{wake_kind}_scheduled"

        case Txn.q(
               txn,
               """
               SELECT state, origin, assignmentId
               FROM wakes
               WHERE wakeId=?1
               """,
               [wake_id]
             ) do
          [["pending", "process:tightbeam", ^assignment_id]] -> :ok
          _ -> raise "incompatible_supervision_liveness_v1: invalid scheduled controller"
        end

        Txn.q(
          txn,
          """
          INSERT INTO supervision_liveness_sidecar
            (wakeId, assignmentId, controllerOrigin, wakeKind, controllerState,
             chargedGeneration, rootTurnSeq)
          VALUES (?1, ?2, 'scheduled', ?3, 'pending', ?4, ?5)
          """,
          [wake_id, assignment_id, wake_kind, next_generation, root_turn_seq]
        )

        Txn.q(
          txn,
          """
          UPDATE supervision_entitlements
          SET generation=?2, dueAt=?3, state='armed', lastAttemptGeneration=NULL,
              claimClock=NULL, basisKind=?4, basisId=?5, cause=?4,
              principal='process:tightbeam'
          WHERE assignmentId=?1 AND generation=?6 AND state='claimed'
          """,
          [
            assignment_id,
            next_generation,
            evaluation_clock + interval,
            basis_kind,
            wake_id,
            generation
          ]
        )

        if Txn.changes(txn) != 1 do
          raise "incompatible_supervision_liveness_v1: stale controller schedule"
        end

        EventLog.lifecycle_in_txn(
          txn,
          "supervision_entitlement_rearmed",
          assignment_id,
          "generation=#{next_generation} basis=#{basis_kind}:#{wake_id} cause=#{basis_kind} principal=process:tightbeam"
        )

        {:armed, next_generation}

      [] ->
        :duplicate
    end
  end

  def transition_in_txn(%Txn{} = txn, %{
        kind: "policy_denied",
        assignment_id: assignment_id,
        event_id: event_id,
        evaluation_clock: evaluation_clock
      })
      when is_integer(event_id) and event_id > 0 and is_integer(evaluation_clock) and
             evaluation_clock >= 0 do
    case Txn.q(
           txn,
           """
           SELECT e.generation, e.claimClock, e.supervisionIntervalMs, a.holderKey
           FROM supervision_entitlements e
           JOIN assignments a ON a.id=e.assignmentId
           WHERE e.assignmentId=?1 AND e.state='claimed'
           """,
           [assignment_id]
         ) do
      [[generation, ^evaluation_clock, interval, holder]]
      when is_integer(interval) and interval > 0 ->
        principal =
          case Txn.q(
                 txn,
                 "SELECT principal FROM events WHERE id=?1 AND kind='denied'",
                 [event_id]
               ) do
            [[principal]] when is_binary(principal) and principal != "" -> principal
            _ -> raise "incompatible_supervision_liveness_v1: invalid policy denial event"
          end

        Txn.q(
          txn,
          """
          UPDATE supervision_watermarks
          SET pendingBranch=NULL, pendingAssignment=NULL, pendingK=NULL, pendingN=NULL
          WHERE sessionKey=?1 AND pendingAssignment=?2 AND pendingBranch IS NOT NULL
          """,
          [holder, assignment_id]
        )

        if Txn.changes(txn) != 1 do
          raise "incompatible_supervision_liveness_v1: missing policy denial branch"
        end

        Txn.q(
          txn,
          "UPDATE assignment_prods SET deniedStreak=deniedStreak + 1 WHERE assignmentId=?1",
          [assignment_id]
        )

        if Txn.changes(txn) != 1 do
          raise "incompatible_supervision_liveness_v1: missing policy denial counters"
        end

        next_generation = generation + 1

        Txn.q(
          txn,
          """
          UPDATE supervision_entitlements
          SET generation=?2, dueAt=?3, state='armed', lastAttemptGeneration=NULL,
              claimClock=NULL, basisKind='policy_denied', basisId=?4,
              cause='policy_denied', principal=?5
          WHERE assignmentId=?1 AND generation=?6 AND state='claimed' AND claimClock=?7
          """,
          [
            assignment_id,
            next_generation,
            evaluation_clock + interval,
            to_string(event_id),
            principal,
            generation,
            evaluation_clock
          ]
        )

        if Txn.changes(txn) != 1 do
          raise "incompatible_supervision_liveness_v1: stale policy denial"
        end

        EventLog.lifecycle_in_txn(
          txn,
          "supervision_entitlement_rearmed",
          assignment_id,
          "generation=#{next_generation} basis=policy_denied:#{event_id} cause=policy_denied principal=#{principal}"
        )

        {:armed, next_generation}

      [] ->
        :duplicate

      _ ->
        raise "incompatible_supervision_liveness_v1: invalid policy denial claim"
    end
  end

  def transition_in_txn(
        %Txn{} = txn,
        %{
          kind: "controller_fire",
          wake_id: wake_id,
          assignment_id: assignment_id,
          target_session_key: target
        } = observation
      ) do
    turn_seq = Map.get(observation, :turn_seq)

    case Txn.q(
           txn,
           """
           SELECT s.wakeKind, s.chargedGeneration, e.generation, e.basisKind,
                  e.basisId, e.supervisionIntervalMs
           FROM supervision_liveness_sidecar s
           LEFT JOIN supervision_entitlements e ON e.assignmentId=s.assignmentId
           WHERE s.wakeId=?1 AND s.assignmentId=?2 AND s.controllerOrigin='scheduled'
             AND s.controllerState='pending'
           """,
           [wake_id, assignment_id]
         ) do
      [[wake_kind, charged_generation, generation, _basis_kind, _basis_id, interval]]
      when generation == charged_generation ->
        case absorb_liveness_receipts_in_txn(txn, assignment_id, interval) do
          :rebased ->
            :canceled

          :duplicate ->
            if is_integer(turn_seq) and turn_seq > 0 do
              Txn.q(
                txn,
                "UPDATE supervision_liveness_sidecar SET controllerState='settled' WHERE wakeId=?1 AND controllerState='pending'",
                [wake_id]
              )

              if wake_kind == "escalation" do
                transition_in_txn(txn, %{
                  kind: "parent_elevated",
                  assignment_id: assignment_id,
                  wake_id: wake_id,
                  turn_seq: turn_seq,
                  target_session_key: target
                })
              end
            end

            {:admit, wake_kind}
        end

      [[_wake_kind, _charged_generation, generation, "progress", basis_id, _interval]]
      when is_integer(generation) ->
        if Wakes.cancel_in_txn(txn, %{
             wake_id: wake_id,
             requester: %{kind: "process", id: "tightbeam:supervision"},
             reason_kind: "superseded",
             causal_source: %{kind: "progress_attest", id: basis_id},
             outcome: %{
               kind: "no_replacement",
               liveness_trigger: %{
                 kind: "supervision_entitlement",
                 id: "#{assignment_id}##{generation}"
               }
             }
           }) do
          Txn.q(
            txn,
            "UPDATE supervision_liveness_sidecar SET controllerState='settled' WHERE wakeId=?1",
            [wake_id]
          )
        end

        :canceled

      [[_wake_kind, _charged_generation, _generation, _basis_kind, _basis_id, _interval]] ->
        raise "incompatible_supervision_liveness_v1: stale controller generation"

      [] ->
        raise "incompatible_supervision_liveness_v1: missing scheduled controller"
    end
  end

  def transition_in_txn(%Txn{}, _observation), do: :duplicate

  @doc false
  def revalidate_delivery_in_txn(
        %Txn{} = txn,
        %{
          sessionKey: session_key,
          lastEvaluatedTerminal: terminal_seq,
          pendingBranch: branch,
          pendingAssignment: assignment_id,
          pendingK: k,
          pendingN: n
        } = pending
      ) do
    case Txn.q(
           txn,
           """
           SELECT e.supervisionIntervalMs
           FROM supervision_watermarks w
           LEFT JOIN supervision_entitlements e ON e.assignmentId=w.pendingAssignment
           WHERE w.sessionKey=?1 AND w.lastEvaluatedTerminal IS ?2
             AND w.pendingBranch=?3 AND w.pendingAssignment=?4
             AND w.pendingK IS ?5 AND w.pendingN IS ?6
           """,
           [session_key, terminal_seq, branch, assignment_id, k, n]
         ) do
      [] ->
        :stale

      [[nil]] ->
        :ready

      [[interval]] ->
        case absorb_liveness_receipts_in_txn(txn, assignment_id, interval) do
          :rebased ->
            if clear_pending_in_txn(txn, pending) do
              EventLog.lifecycle_in_txn(
                txn,
                "supervision_delivery_suppressed",
                assignment_id,
                "branch=#{branch} terminal=#{terminal_seq} cause=liveness_receipt principal=process:tightbeam"
              )

              :suppressed
            else
              :stale
            end

          :duplicate ->
            :ready
        end
    end
  end

  @spec liveness_trigger_in_txn(Txn.t(), {:assignment | :work_item, String.t()}) ::
          {:ok, %{kind: String.t(), id: String.t()}} | :none | {:error, atom()}
  def liveness_trigger_in_txn(txn, {:assignment, assignment_id}) do
    assignment_trigger_in_txn(txn, assignment_id)
  end

  def liveness_trigger_in_txn(txn, {:work_item, work_item_id}) do
    case work_item_bracket_trigger_in_txn(txn, work_item_id) do
      :none ->
        txn
        |> query(
          "SELECT id FROM assignments WHERE workItemId=?1 AND state='open' ORDER BY openedAt, id",
          [work_item_id]
        )
        |> Enum.reduce_while(:none, fn [assignment_id], _acc ->
          case assignment_trigger_in_txn(txn, assignment_id) do
            :none -> {:cont, :none}
            result -> {:halt, result}
          end
        end)

      result ->
        result
    end
  end

  defp work_item_bracket_trigger_in_txn(txn, work_item_id) do
    case query(
           txn,
           """
           SELECT 1
           FROM work_items wi
           JOIN wakes w ON w.wakeId=wi.routingWakeId OR w.wakeId=wi.slateWakeId
           WHERE wi.id=?1 AND wi.state='open' AND w.state='pending'
           LIMIT 1
           """,
           [work_item_id]
         ) do
      [[1]] -> {:ok, %{kind: "routing_bracket", id: work_item_id}}
      [] -> :none
    end
  end

  defp cancel_assignment_controllers_in_txn(txn, assignment_id, requester_id) do
    trigger =
      case query(txn, "SELECT workItemId FROM assignments WHERE id=?1", [assignment_id]) do
        [[work_item_id]] when is_binary(work_item_id) ->
          case liveness_trigger_in_txn(txn, {:work_item, work_item_id}) do
            {:ok, value} -> value
            :none -> nil
            {:error, reason} -> raise "invalid liveness trigger: #{inspect(reason)}"
          end

        _ ->
          nil
      end

    outcome = %{
      kind: "disposition",
      disposition_kind: "assignment_transition",
      disposition_id: assignment_id
    }

    outcome = if trigger, do: Map.put(outcome, :liveness_trigger, trigger), else: outcome

    Txn.q(
      txn,
      """
      SELECT s.wakeId
      FROM supervision_liveness_sidecar s
      JOIN wakes w ON w.wakeId=s.wakeId
      WHERE s.assignmentId=?1 AND s.controllerOrigin='scheduled'
        AND s.controllerState='pending' AND w.state='pending'
      ORDER BY w.createdAt, w.wakeId
      """,
      [assignment_id]
    )
    |> Enum.each(fn [wake_id] ->
      unless Wakes.cancel_in_txn(txn, %{
               wake_id: wake_id,
               requester: %{kind: "process", id: requester_id},
               reason_kind: "obligation_disposed",
               causal_source: %{kind: "assignment_transition", id: assignment_id},
               outcome: outcome
             }) do
        raise "typed supervision cancellation refused for #{wake_id}"
      end
    end)
  end

  defp assignment_trigger_in_txn(txn, assignment_id) do
    case query(
           txn,
           "SELECT generation, state FROM supervision_entitlements WHERE assignmentId=?1",
           [assignment_id]
         ) do
      [[generation, state]] when state in ["armed", "claimed"] ->
        {:ok, %{kind: "supervision_entitlement", id: "#{assignment_id}##{generation}"}}

      [[_generation, "terminus"]] ->
        :none

      [] ->
        case accepted_transfer(txn, assignment_id, nil) do
          {:ok, %{turn_seq: turn_seq}} ->
            {:ok, %{kind: "supervision_transfer", id: "#{assignment_id}##{turn_seq}"}}

          :none ->
            :none

          {:error, _reason} ->
            {:error, :incompatible_supervision_liveness_v1}
        end
    end
  end

  defp clear_entitlement_in_txn(txn, assignment_id, cause, principal \\ "process:tightbeam") do
    Txn.q(txn, "DELETE FROM supervision_entitlements WHERE assignmentId=?1", [assignment_id])
    changed? = Txn.changes(txn) == 1

    Txn.q(
      txn,
      """
      UPDATE supervision_watermarks
      SET pendingBranch=NULL, pendingAssignment=NULL, pendingK=NULL, pendingN=NULL
      WHERE pendingAssignment=?1
      """,
      [assignment_id]
    )

    if changed? and cause != "parent_elevated" do
      EventLog.lifecycle_in_txn(
        txn,
        "supervision_entitlement_cleared",
        assignment_id,
        "cause=#{cause} principal=#{principal}"
      )
    end

    changed?
  end

  @spec watermark(DB.server(), String.t()) :: map() | nil
  def watermark(db, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment, pendingK, pendingN FROM supervision_watermarks WHERE sessionKey = ?1",
        [session_key]
      )

    case rows do
      [[key, terminal, branch, assignment, k, n]] ->
        %{
          sessionKey: key,
          lastEvaluatedTerminal: terminal,
          pendingBranch: branch,
          pendingAssignment: assignment,
          pendingK: k,
          pendingN: n
        }

      [] ->
        nil
    end
  end

  @doc """
  Who owns this holder at `rung` of its lineage ladder — or NOBODY.

  `nil` is a real answer and the reason this returns it: the last rung falls
  back to the owner's main session, and `Org.personal_session_key/1` COMPOSES
  that key from a user id rather than reading a row. An owner with no main
  session got a well-formed address to a session that does not exist, and every
  notice sent there queued forever. Verified the way `Gateway`'s sibling
  `active_personal_target/3` verifies it; callers name what they could not
  deliver.
  """
  @spec ladder_target(DB.server() | Txn.t(), String.t(), pos_integer()) :: String.t() | nil
  def ladder_target(%Txn{} = txn, holder_key, rung) do
    %{owner_user_id: owner, session_key: effective_parent} =
      Org.effective_parent_in_txn(txn, holder_key)

    chain = lineage(txn, effective_parent, MapSet.new([holder_key]), [])

    case Enum.at(chain, rung - 1) do
      nil -> active_personal_key(txn, owner)
      rung_key -> rung_key
    end
  end

  def ladder_target(db, holder_key, rung) do
    case DB.transaction(db, fn txn -> ladder_target(txn, holder_key, rung) end) do
      {:ok, target} -> target
      {:error, error} -> raise error
    end
  end

  defp active_personal_key(db_or_txn, owner) do
    key = Org.personal_session_key(owner)

    case query(db_or_txn, "SELECT 1 FROM sessions WHERE sessionKey = ?1 AND state = 'active'", [
           key
         ]) do
      [] -> nil
      [_ | _] -> key
    end
  end

  @spec evaluate(DB.server(), Dispatch.handlers(), non_neg_integer(), String.t(), integer() | nil) ::
          :busy
          | :continuation
          | :idle
          | :blocked
          | :harness_unavailable
          | :duplicate
          | :coalesced
          | :rebased
          | :not_due
          | {:prodded, pos_integer()}
          | {:escalated, pos_integer(), String.t()}
          | :terminus
          | :stranded
          | {:acted, :rail_remedy}
          | {:acted, :rail_escalate}
          | {:retry, :rail_escalate}
          | {:refused, String.t()}
  def evaluate(db, handlers, n, session_key, terminal_seq) do
    evaluate_with_interval(db, handlers, n, session_key, terminal_seq, nil)
  end

  defp evaluate_with_interval(db, handlers, n, session_key, terminal_seq, interval) do
    case drain(db, handlers, session_key) do
      {:pending, result} ->
        result

      {:cleared, :deferred} ->
        if harness_unavailable?(db, session_key),
          do: :harness_unavailable,
          else: evaluate_terminal(db, handlers, n, session_key, terminal_seq, interval)

      {:cleared, _prior_result} ->
        evaluate_terminal(db, handlers, n, session_key, terminal_seq, interval)
    end
  end

  @doc """
  The prod production's COMPLETE left-hand side (spec production-machine-v1
  §The prod production), declared in this one site and read from durable
  state only — rows, never process state. Conjuncts, in evaluation order:

    1. an open assignment obligation exists for the holder;
    2. this terminal seq was not already evaluated — the
       `supervision_watermarks` dedupe (`:terminal_already_evaluated`) — and
       is not older than the one that was (`:terminal_coalesced`);
    3. no running or queued turn for the holder: a pending turn means the
       strand is moving;
    4. the holder session is active, not retired;
    5. no standing harness-health incident for the holder's shared
       `(harness, host)` process: the substrate suppresses this harness while
       healthy harnesses continue;
    6. a terminal exists at all — the sweep also asks about strands that
       have never ended a turn;
    7. no standing `work-blocked` fact for the holder: an agent with
       authority decided this session is not to be treated as stalled, and
       the production simply does not match — the same absence-of-match as
       a session with no open assignment.

  Liveness receipts are deliberately NOT match conditions. The act consumes
  only typed durable sources: an assignment artifact, work-item update,
  verdict fact, or one unexpired assignment-bound checkpoint. Progress prose
  is never parsed and never resets the ladder by itself.

  A no-match verdict names the failing conjunct. Verdicts the turn-end
  schedule must still see — the rail production outranks the prod ladder
  and runs regardless — carry the obligation with them.
  """
  @spec prod_production_matches?(DB.server(), String.t(), integer() | nil) ::
          {:match, map()} | {:no_match, atom()} | {:no_match, atom(), map()}
  def prod_production_matches?(db, session_key, terminal_seq) do
    case oldest_supervised_assignment(db, session_key) ||
           Assignments.oldest_prod_eligible(db, session_key) do
      nil ->
        {:no_match, :no_open_obligation}

      assignment ->
        with :new <- dedupe(watermark(db, session_key), terminal_seq),
             :quiet <- turn_gate(db, session_key),
             :live <- holder_state(db, session_key),
             :available <- harness_gate(db, session_key),
             :evaluable <- terminal_gate(terminal_seq),
             :unblocked <- block_gate(db, session_key) do
          {:match, assignment}
        else
          :duplicate -> {:no_match, :terminal_already_evaluated}
          :coalesced -> {:no_match, :terminal_coalesced}
          :moving -> {:no_match, :strand_moving}
          :retired -> {:no_match, :holder_retired}
          :no_terminal -> {:no_match, :no_terminal, assignment}
          :unavailable -> {:no_match, :harness_unavailable, assignment}
          :blocked -> {:no_match, :work_blocked, assignment}
        end
    end
  end

  defp oldest_supervised_assignment(db, session_key) do
    case query(
           db,
           """
           SELECT a.id, a.subject, a.holderKey
           FROM assignments a
           JOIN supervision_entitlements e ON e.assignmentId=a.id
           WHERE a.holderKey=?1 AND a.state='open' AND e.state IN ('armed','claimed')
             AND NOT EXISTS (
               SELECT 1 FROM assignment_cannot_proceed cp
               WHERE cp.assignmentId=a.id AND cp.state='standing'
             )
           ORDER BY a.openedAt, a.id
           LIMIT 1
           """,
           [session_key]
         ) do
      [[id, subject, holder]] -> %{id: id, subject: subject, holderKey: holder}
      [] -> nil
    end
  end

  defp turn_gate(db, session_key),
    do: if(Ledger.pending_count(db, session_key) == 0, do: :quiet, else: :moving)

  defp terminal_gate(nil), do: :no_terminal
  defp terminal_gate(_terminal_seq), do: :evaluable

  defp harness_gate(db, session_key) do
    if harness_unavailable?(db, session_key), do: :unavailable, else: :available
  end

  defp harness_unavailable?(db, session_key) do
    case query(db, "SELECT harness, host FROM sessions WHERE sessionKey=?1", [session_key]) do
      [[harness, host]] -> HarnessHealth.unavailable?(db, harness, host)
      [] -> false
    end
  end

  @doc false
  def harness_unavailable_in_txn?(txn, session_key) do
    case Txn.q(txn, "SELECT harness, host FROM sessions WHERE sessionKey=?1", [session_key]) do
      [[harness, host]] ->
        ConditionFacts.harness_unavailable_in_txn?(txn, harness, host)

      [] ->
        false
    end
  end

  defp block_gate(db, session_key) do
    if ConditionFacts.standing?(db, "work-blocked", session_key),
      do: :blocked,
      else: :unblocked
  end

  @impl true
  def init(opts) do
    state = %{
      db: Keyword.fetch!(opts, :db),
      handlers: Keyword.fetch!(opts, :handlers),
      n: Keyword.fetch!(opts, :prod_limit),
      sweep_ms: Keyword.get(opts, :sweep_ms),
      delivery_opts: Keyword.take(opts, [:conn_registry, :lane_manager])
    }

    if Keyword.get(opts, :recover, true), do: recover_liveness(state)
    schedule_sweep(state.sweep_ms)
    {:ok, state, {:continue, :initial_sweep}}
  end

  @impl true
  def handle_continue(:initial_sweep, state) do
    sweep(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:terminal, session_key, terminal_seq}, state) do
    safe_evaluate(state, session_key, fn ->
      evaluate_with_interval(
        state.db,
        state.handlers,
        state.n,
        session_key,
        terminal_seq,
        state.sweep_ms
      )
    end)

    {:noreply, state}
  end

  def handle_cast({:retired, session_key}, state) do
    safe_evaluate(state, session_key, fn ->
      :ok = Escalation.withdraw_for_retired(state.db, session_key)
      doorbells_for_holder(state.db, session_key)
      notify_stranded_ancestor(state, session_key)
    end)

    {:noreply, state}
  end

  def handle_cast(:sweep, state) do
    sweep(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:scheduled_sweep, state) do
    sweep(state)
    schedule_sweep(state.sweep_ms)
    {:noreply, state}
  end

  # Recognize, then act: the production's complete LHS is evaluated once, at
  # cycle start, and everything downstream — including the schedule's gates —
  # consults that verdict rather than re-reading working memory mid-cycle.
  defp evaluate_terminal(db, handlers, n, session_key, terminal_seq, interval) do
    case prod_production_matches?(db, session_key, terminal_seq) do
      {:no_match, :no_open_obligation} ->
        :idle

      {:no_match, :terminal_already_evaluated} ->
        :duplicate

      {:no_match, :terminal_coalesced} ->
        :coalesced

      {:no_match, :strand_moving} ->
        :busy

      {:no_match, :harness_unavailable, _assignment} ->
        :harness_unavailable

      {:no_match, :holder_retired} ->
        # Act-then-watermark (matches the remedy branch): doorbells are an
        # idempotent CAS, so a crash before the watermark re-rings them on
        # redelivery. Watermark-first would lose them permanently (a retired
        # session never re-terminals).
        doorbells_for_holder(db, session_key)
        write_watermark(db, session_key, terminal_seq)
        :stranded

      verdict ->
        evaluate_live(db, handlers, n, session_key, terminal_seq, verdict, interval)
    end
  end

  # ── THE TURN-END SCHEDULE (supervision-impl r21) ──────────────────────────
  #
  # This list IS the end-of-turn shift — and, named for what it is, the
  # production machine's CONFLICT-RESOLUTION STRATEGY (spec
  # production-machine-v1): the standard production-system answer to "several
  # rules could fire" — a fixed priority order, first act wins the cycle.
  # Every governance that acts when a turn ends holds exactly one named slot
  # here, and the shift runs them in this order, first halt wins. The order
  # is SEMANTIC, not incidental:
  #
  #   :rail_enforcement  — the org's statutes get the turn before the
  #                        substrate's own ladder does (Rules.decide → remedy /
  #                        escalate / legibility rows; rails-mechanism-v1 owns
  #                        the semantics of this step, this module only hosts
  #                        its slot);
  #   :prod_ladder       — the sweep proper (prods, escalation ladder,
  #                        watermark). Always halts; the schedule never runs
  #                        off the end.
  #
  # ADDING A STEP (the lease — all four lines, or the shift rejects you):
  #   1. Add the atom HERE, in its semantically correct position.
  #   2. Add a `turn_end_step/2` clause returning `:cont` or `{:halt, result}`.
  #      Read state freely; any write must be idempotent (the terminal cast
  #      can be redelivered) and must NOT move the watermark — the watermark
  #      has ONE writer, the acting step that ends the shift.
  #   3. Extend the termination argument (spec §r21): your step must be
  #      bounded per shift and must not unconditionally re-trigger a turn —
  #      the enforcement loop is bounded ONLY because remedies are
  #      once-per-occurrence; say why yours is bounded too.
  #   4. Extend the order-pinning test in supervision_test.exs — it fails on
  #      any unannounced change to this list, by design.
  #
  # PRINCIPLES every step inherits (r20's invariants, kept verbatim): the
  # substrate never judges ("gave up" is not a state), never punishes (no
  # retire/cancel/re-staff — substrate acts are wakes, stamps, and
  # org-authored statute effects), never reads content (rows or nothing).
  #
  # This list is deliberately NOT a runtime registration seam: steps share
  # the turn context, the order carries meaning, and the termination proof is
  # over the closed composition. Orgs extend turn-end behavior through
  # STATUTES (data, hosted by :rail_enforcement) — never by code injection.
  @turn_end_schedule [:rail_enforcement, :prod_ladder]

  @doc "The end-of-turn shift, in execution order. Pinned by test; amend both."
  def turn_end_schedule, do: @turn_end_schedule

  defp evaluate_live(db, handlers, n, session_key, terminal_seq, verdict, interval) do
    # Every verdict that reaches the schedule still carries the obligation:
    # the rail production outranks the prod ladder and needs it even when the
    # prod production did not match.
    assignment =
      case verdict do
        {:match, assignment} -> assignment
        {:no_match, _conjunct, assignment} -> assignment
      end

    ctx = %{
      db: db,
      handlers: handlers,
      n: n,
      session_key: session_key,
      terminal_seq: terminal_seq,
      assignment: assignment,
      verdict: verdict,
      supervision_interval_ms: interval
    }

    run_schedule(@turn_end_schedule, ctx)
  end

  # First halt wins; :prod_ladder always halts, so the list never runs dry.
  defp run_schedule([step | rest], ctx) do
    case turn_end_step(step, ctx) do
      :cont -> run_schedule(rest, ctx)
      {:halt, result} -> result
    end
  end

  defp turn_end_step(:rail_enforcement, ctx) do
    case rail_step(ctx.db, ctx.handlers, ctx.session_key, ctx.assignment, ctx.terminal_seq) do
      {:acted, _tag} = acted -> {:halt, acted}
      {:retry, _tag} = retry -> {:halt, retry}
      :fallthrough -> :cont
    end
  end

  defp turn_end_step(:prod_ladder, ctx) do
    case ctx.verdict do
      {:no_match, :no_terminal, _assignment} ->
        {:halt, :idle}

      {:no_match, :work_blocked, _assignment} ->
        # Not suppression bolted onto the prodder: the production does not
        # match, so nothing is claimed and nothing is watermarked — the
        # obligation stands, and retraction re-matches this same terminal
        # (spec production-machine-v1).
        {:halt, :blocked}

      {:match, assignment} ->
        result =
          terminal_prod_ladder(
            ctx.db,
            ctx.handlers,
            ctx.n,
            ctx.session_key,
            ctx.terminal_seq,
            assignment,
            ctx.supervision_interval_ms
          )

        {:halt, result}
    end
  end

  defp rail_step(_db, _handlers, _session_key, _assignment, nil), do: :fallthrough

  defp rail_step(db, handlers, session_key, assignment, terminal_seq) do
    if Wakes.self_pending_count(db, session_key) > 0 do
      :fallthrough
    else
      call = %{
        verb: "attest",
        origin: "remedy:sweep",
        principal: {:session, assignment.holderKey},
        session_key: nil,
        edge: :turn_end,
        recurrence_receipt_id: "turn-end:#{session_key}:#{terminal_seq}",
        recurrence_sequence: terminal_seq,
        recurrence_failure_class: "rail-remedy",
        recurrence_failure_code: "obligation-unsatisfied",
        params: %{assignment_id: assignment.id, kind: "completion"}
      }

      {decision, to_close, _to_consume} = Rules.decide(db, call)
      Enum.each(to_close, &close_episode(db, handlers, &1))

      case decision do
        {:remedy, statute, ref, _error} ->
          RailRemedy.fire(db, handlers, statute, ref, call)
          rail_sweep_lifecycle(db, session_key, ref, statute.name, "run-remedy")
          write_watermark(db, session_key, terminal_seq)
          {:acted, :rail_remedy}

        {:escalate, statute, ctx, dr_id} ->
          decision_request_id =
            case dr_id do
              nil ->
                {:decision_pending, id} =
                  Escalation.escalate(db, call, statute, Map.put(ctx, :dr_id, nil))

                id

              id ->
                id
            end

          case park_escalation(db, session_key, decision_request_id) do
            :parked ->
              rail_sweep_lifecycle(
                db,
                session_key,
                assignment.id,
                statute.name,
                "escalate-park"
              )

              write_watermark(db, session_key, terminal_seq)
              {:acted, :rail_escalate}

            :skipped ->
              {:retry, :rail_escalate}
          end

        # A sensor malfunction summons a mind, but its deny is the sweep's ordinary
        # re-obligate (§A3): the session is NOT parked, because parking is the escalate
        # effect's consequence and the ruling changed what a malfunction ALSO does, not
        # what it decides.
        {:deny_escalate, statute, ctx} ->
          rail_sweep_lifecycle(db, session_key, assignment.id, ctx.error.rule, "re-obligate")
          :ok = RailEpisodes.summon(db, call, statute, Map.put(ctx, :dr_id, nil))
          :fallthrough

        {:deny, error} ->
          rail_sweep_lifecycle(db, session_key, assignment.id, error.rule, "re-obligate")
          :fallthrough

        :allow ->
          rail_sweep_lifecycle(db, session_key, assignment.id, nil, "none")
          :fallthrough
      end
    end
  end

  # The sweep closes both kinds of episode the verb edge does (§C3.5, §A3).
  defp close_episode(db, _handlers, {:episodes, statute, position}),
    do: RailEpisodes.recovered(db, statute, position)

  defp close_episode(db, _handlers, {statute, subject, occurrence}),
    do: RailRemedy.close(db, statute, subject, occurrence)

  defp close_episode(db, handlers, {:notice, statute, subject, call}),
    do: RailRemedy.notice(db, handlers, statute, subject, call)

  # `decision_request_id` here only ever names a statute row: it is the `dr_id`
  # `Escalation.resolve/3` handed back, which comes from `current_request/4`'s
  # own `kind = 'statute'`-scoped read. `Escalation.statute_park_candidate_in_txn/2`
  # (Sol xhigh review, finding 2 / round 2 finding 1) restates that scope at
  # its own read rather than leaning on the upstream invariant alone — a park
  # sweep is exactly the kind of reader that must not be able to reach an
  # agent row even by construction accident — and is now the ONLY place this
  # module's decision_requests SQL lives (`Escalation` owns the rest).
  defp park_escalation(db, session_key, decision_request_id) do
    transaction!(db, fn txn ->
      case Escalation.statute_park_candidate_in_txn(txn, decision_request_id) do
        {:ok, deadline_at, nil, assignment_id} ->
          wake =
            Wakes.schedule_in_txn(txn, %{
              session_key: session_key,
              target_role: nil,
              origin: "process:tightbeam",
              prompt:
                "Decision request #{decision_request_id} was ruled; re-adjudicate the obligation.",
              due_at: deadline_at,
              condition_kind: "escalation-ruled",
              condition_scope: decision_request_id,
              creator_session_key: nil,
              # A decision-DEADLINE wake resolves its assignment from the REQUEST
              # row, where it is durable (spec job-forensics-v2 §1).
              assignment_id: assignment_id
            })

          :ok = Escalation.claim_park_wake_in_txn(txn, decision_request_id, wake.wake_id)

          :parked

        {:ok, _deadline_at, park_wake_id, _assignment_id} when is_binary(park_wake_id) ->
          :parked

        :not_found ->
          :skipped
      end
    end)
  end

  defp rail_sweep_lifecycle(db, session_key, ref, statute, decision) do
    detail = JSON.encode!(%{ref: ref, statute: statute, decision: decision})
    best_effort_lifecycle(db, "rail_sweep", session_key, detail)
  end

  defp write_watermark(_db, _session_key, nil), do: :ok

  defp write_watermark(db, session_key, terminal_seq) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO supervision_watermarks
          (sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment, pendingK, pendingN)
        VALUES (?1, ?2, NULL, NULL, NULL, NULL)
        ON CONFLICT(sessionKey) DO UPDATE SET
          lastEvaluatedTerminal = excluded.lastEvaluatedTerminal,
          pendingBranch = NULL,
          pendingAssignment = NULL,
          pendingK = NULL,
          pendingN = NULL
        """,
        [session_key, terminal_seq]
      )

    :ok
  end

  defp dedupe(_watermark, nil), do: :new
  defp dedupe(nil, _terminal), do: :new
  defp dedupe(%{lastEvaluatedTerminal: terminal}, terminal), do: :duplicate
  defp dedupe(%{lastEvaluatedTerminal: prior}, terminal) when terminal < prior, do: :coalesced
  defp dedupe(_watermark, _terminal), do: :new

  defp holder_state(db, session_key) do
    case DB.query(db, "SELECT state FROM sessions WHERE sessionKey = ?1", [session_key]) do
      {:ok, [["retired"]]} -> :retired
      {:ok, [["active"]]} -> :live
    end
  end

  defp terminal_prod_ladder(
         db,
         handlers,
         n,
         session_key,
         terminal_seq,
         assignment,
         replacement_interval
       ) do
    evaluation_clock = now()

    outcome =
      transaction!(db, fn txn ->
        case Txn.q(
               txn,
               """
               SELECT generation, dueAt, state, lastAttemptGeneration,
                      supervisionIntervalMs, basisKind, basisId
               FROM supervision_entitlements
               WHERE assignmentId=?1
               """,
               [assignment.id]
             ) do
          [] ->
            :unarmed

          [[generation, due_at, state, last_attempt, stored_interval, basis_kind, basis_id]] ->
            interval =
              if is_integer(replacement_interval) and replacement_interval > 0,
                do: replacement_interval,
                else: stored_interval

            case absorb_liveness_receipts_in_txn(txn, assignment.id, interval) do
              :rebased ->
                write_terminal_watermark_in_txn(txn, session_key, terminal_seq)
                :rebased

              :duplicate when state == "claimed" ->
                write_terminal_watermark_in_txn(txn, session_key, terminal_seq)
                :claimed

              :duplicate when state == "armed" and due_at > evaluation_clock ->
                write_terminal_watermark_in_txn(txn, session_key, terminal_seq)
                :not_due

              :duplicate when state == "armed" ->
                if due_gate?(txn, assignment.id, session_key) do
                  :controlled
                else
                  case claim_entitlement_in_txn(
                         txn,
                         assignment,
                         generation,
                         due_at,
                         last_attempt,
                         basis_kind,
                         basis_id,
                         evaluation_clock,
                         n,
                         terminal_seq,
                         "new_terminal"
                       ) do
                    :ok -> :claimed
                    :stale -> :duplicate
                  end
                end

              :duplicate ->
                write_terminal_watermark_in_txn(txn, session_key, terminal_seq)
                :duplicate
            end
        end
      end)

    case outcome do
      :unarmed ->
        :idle

      :claimed ->
        case drain(db, handlers, session_key) do
          {:pending, result} -> result
          {:cleared, result} -> result
        end

      :rebased ->
        :rebased

      :not_due ->
        :not_due

      :controlled ->
        :continuation

      :duplicate ->
        :duplicate
    end
  end

  defp write_terminal_watermark_in_txn(_txn, _session_key, nil), do: :ok

  defp write_terminal_watermark_in_txn(txn, session_key, terminal_seq) do
    Txn.q(
      txn,
      """
      INSERT INTO supervision_watermarks
        (sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment, pendingK, pendingN)
      VALUES (?1, ?2, NULL, NULL, NULL, NULL)
      ON CONFLICT(sessionKey) DO UPDATE SET
        lastEvaluatedTerminal=excluded.lastEvaluatedTerminal
      """,
      [session_key, terminal_seq]
    )

    :ok
  end

  defp claim_entitlement_in_txn(
         txn,
         assignment,
         generation,
         due_at,
         last_attempt_generation,
         basis_kind,
         basis_id,
         evaluation_clock,
         n,
         terminal_seq,
         cause
       ) do
    ensure_liveness_receipt_state_in_txn(
      txn,
      assignment.id,
      "first_prod",
      "process:tightbeam"
    )

    current = counter_state_in_txn(txn, assignment.id)

    attempt_count =
      if last_attempt_generation == generation,
        do: current.attemptCount,
        else: current.attemptCount + 1

    # THE LADDER ADVANCES ON HEARD PRODS, NOT SENT ONES (Mike's design,
    # 2026-08-15, after the correlated-outage postmortem). `current.prodCount`
    # counts every prod CLAIMED — including prods whose wake-turn failed
    # because the harness was down. During the 2026-08-10 outage that meant
    # ladders exhausted into a dead tree: every rung's wake became a failed
    # turn, the count climbed anyway, 127 strands stalled in one day, and
    # nothing re-armed them when the harness recovered.
    #
    # A failed prod turn is evidence about the TRANSPORT, not the holder. The
    # ladder measures unaccountability, so only prods that were actually
    # DELIVERED — heard, and then ignored — may advance it. The stored
    # counters keep counting every attempt (they pace the backoff and are
    # facts worth reporting); the RUNG decision reads delivery. An outage now
    # freezes the ladder instead of burning it: the sweep keeps retrying at
    # backoff pace, and the first delivered prod after recovery resumes the
    # climb exactly where the evidence left it.
    {branch, k} =
      branch_for_claim(
        txn,
        assignment.holderKey,
        heard_prod_count(txn, assignment.id),
        n
      )

    stalled_at =
      if branch in ["escalation", "terminus"],
        do: current.stalledAt || evaluation_clock,
        else: current.stalledAt

    Txn.q(
      txn,
      """
      UPDATE supervision_entitlements
      SET state='claimed', claimClock=?3, lastAttemptGeneration=?2,
          cause=?5, principal='process:tightbeam'
      WHERE assignmentId=?1 AND generation=?2 AND dueAt=?4 AND state='armed'
      """,
      [assignment.id, generation, evaluation_clock, due_at, cause]
    )

    if Txn.changes(txn) == 1 do
      Txn.q(
        txn,
        """
        INSERT INTO supervision_watermarks
          (sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment, pendingK, pendingN)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(sessionKey) DO UPDATE SET
          lastEvaluatedTerminal=excluded.lastEvaluatedTerminal,
          pendingBranch=excluded.pendingBranch,
          pendingAssignment=excluded.pendingAssignment,
          pendingK=excluded.pendingK,
          pendingN=excluded.pendingN
        """,
        [assignment.holderKey, terminal_seq, branch, assignment.id, k, n]
      )

      [[attest_count]] =
        Txn.q(txn, "SELECT count(*) FROM attests WHERE assignmentId=?1", [assignment.id])

      Txn.q(
        txn,
        """
        INSERT INTO assignment_prods
          (assignmentId, attemptCount, prodCount, deniedStreak, attestCount,
           lastProdAt, stalledAt, strandedAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ON CONFLICT(assignmentId) DO UPDATE SET
          attemptCount=excluded.attemptCount,
          prodCount=excluded.prodCount,
          deniedStreak=excluded.deniedStreak,
          attestCount=excluded.attestCount,
          lastProdAt=excluded.lastProdAt,
          stalledAt=excluded.stalledAt,
          strandedAt=excluded.strandedAt
        """,
        [
          assignment.id,
          attempt_count,
          current.prodCount,
          current.deniedStreak,
          attest_count,
          current.lastProdAt,
          stalled_at,
          current.strandedAt
        ]
      )

      EventLog.lifecycle_in_txn(
        txn,
        "supervision_entitlement_claimed",
        assignment.id,
        "generation=#{generation} basis=#{basis_kind}:#{basis_id} cause=#{cause} principal=process:tightbeam"
      )

      :ok
    else
      :stale
    end
  end

  defp counter_state_in_txn(txn, assignment_id) do
    case Txn.q(
           txn,
           """
           SELECT attemptCount, prodCount, deniedStreak, attestCount, lastProdAt,
                  stalledAt, strandedAt
           FROM assignment_prods
           WHERE assignmentId=?1
           """,
           [assignment_id]
         ) do
      [[attempts, prods, denied, attests, last_prod, stalled, stranded]] ->
        %{
          attemptCount: attempts,
          prodCount: prods,
          deniedStreak: denied,
          attestCount: attests,
          lastProdAt: last_prod,
          stalledAt: stalled,
          strandedAt: stranded
        }

      [] ->
        zero_state(assignment_id)
    end
  end

  # Prods and escalations this assignment's holder actually RECEIVED — within
  # the CURRENT ladder epoch. Two boundaries compose here:
  #
  # TRANSPORT: a wake was heard unless its turn failed or was canceled — a
  # failed turn is evidence about the harness, not the holder. A delivered
  # prod was heard and ignored; an admitted escalation's turn (queued to the
  # parent) is the durable transfer itself, parked rather than lost; the
  # legacy retirement path marks its evidence on the sidecar directly. A wake
  # with NO turn at all was never attempted and proves nothing.
  #
  # EPOCH: a typed liveness receipt is the holder's NAMED REPAIR VERB — it
  # resets the ladder, and evidence from before it must never resurrect a
  # rung (Sol review, blocking: a lifetime count re-escalated an accountable
  # holder immediately after their receipt, overriding the repair seam the
  # philosophy gates require). The receipt records the generation it re-armed;
  # prods charged at or after it are this epoch's, everything earlier is
  # history. Before any receipt exists, ALL evidence counts — including legacy
  # retirement rows whose chargedGeneration is NULL (a NULL would silently
  # fail a >= comparison, un-hearing a durable parent transfer; Sol
  # confirmation round). Once a receipt boundary exists, NULL-generation rows
  # fall out of the epoch — conservative, and honest: a repaired ladder
  # restarts at prod 1.
  defp heard_prod_count(txn, assignment_id) do
    [[count]] =
      Txn.q(
        txn,
        """
        SELECT COUNT(*)
        FROM supervision_liveness_sidecar s
        LEFT JOIN turns t ON t.wakeId = s.wakeId
        WHERE s.assignmentId = ?1
          AND s.wakeKind IN ('prod', 'escalation')
          AND (s.chargedGeneration >=
                 (SELECT MAX(generation)
                  FROM supervision_liveness_receipts
                  WHERE assignmentId = ?1)
                 OR NOT EXISTS (SELECT 1
                                FROM supervision_liveness_receipts
                                WHERE assignmentId = ?1))
          AND ((t.wakeId IS NOT NULL AND
                t.status NOT IN ('failed', 'failed_unknown', 'canceled'))
               OR s.transferEvidenceId IS NOT NULL)
        """,
        [assignment_id]
      )

    count
  end

  defp branch_for_claim(txn, holder, prod_count, n) do
    if prod_count < n do
      {"prod", prod_count + 1}
    else
      rung = prod_count - n + 1

      case ladder_target(txn, holder, rung) do
        nil -> {"terminus", rung}
        ^holder -> {"terminus", rung}
        _target -> {"escalation", rung}
      end
    end
  end

  defp drain(db, handlers, session_key) do
    case watermark(db, session_key) do
      %{pendingBranch: branch} = pending when is_binary(branch) ->
        drain_pending(db, handlers, pending)

      _ ->
        {:cleared, nil}
    end
  end

  defp drain_pending(db, handlers, pending) do
    case open_assignment(db, pending.pendingAssignment) do
      nil ->
        clear_pending(db, pending)
        {:cleared, nil}

      assignment ->
        case prepare_drain(db, pending) do
          :ready -> drain_open(db, handlers, pending, assignment)
          :legacy -> drain_open(db, handlers, pending, assignment)
          :deferred -> {:cleared, :deferred}
          :stale -> {:cleared, nil}
        end
    end
  end

  defp prepare_drain(db, pending) do
    transaction!(db, fn txn ->
      case Txn.q(
             txn,
             """
             SELECT generation, state, lastAttemptGeneration, basisKind, basisId
             FROM supervision_entitlements
             WHERE assignmentId=?1
             """,
             [pending.pendingAssignment]
           ) do
        [] ->
          :legacy

        [[generation, "claimed", generation, basis_kind, basis_id]] ->
          case gate_reason_in_txn(txn, pending.pendingAssignment, pending.sessionKey) do
            nil ->
              :ready

            cause ->
              Txn.q(
                txn,
                """
                UPDATE supervision_entitlements
                SET state='armed', claimClock=NULL,
                    cause=CASE WHEN ?3='harness_unavailable' THEN cause ELSE ?3 END,
                    principal='process:tightbeam'
                WHERE assignmentId=?1 AND generation=?2 AND state='claimed'
                  AND lastAttemptGeneration=?2
                """,
                [pending.pendingAssignment, generation, cause]
              )

              if Txn.changes(txn) == 1 do
                clear_pending_in_txn(txn, pending)

                EventLog.lifecycle_in_txn(
                  txn,
                  "supervision_entitlement_deferred",
                  pending.pendingAssignment,
                  "generation=#{generation} basis=#{basis_kind}:#{basis_id} cause=#{cause} principal=process:tightbeam"
                )
              end

              :deferred
          end

        [_stale] ->
          clear_pending_in_txn(txn, pending)
          :stale
      end
    end)
  end

  defp drain_open(db, handlers, %{pendingBranch: "prod"} = pending, assignment) do
    case holder_state(db, pending.sessionKey) do
      :retired ->
        clear_pending(db, pending)
        doorbell(db, assignment.id)
        {:cleared, nil}

      :live ->
        dispatch_wake(db, handlers, pending, assignment, pending.sessionKey)
    end
  end

  defp drain_open(db, handlers, %{pendingBranch: "escalation"} = pending, assignment) do
    case ladder_target(db, pending.sessionKey, pending.pendingK) do
      nil ->
        # The ladder emptied between the evaluation that recorded this branch and
        # this drain. It has nowhere to go, which is what terminus MEANS — but the
        # watermark row still says "escalation" and `clear_pending_in_txn/2` CASes
        # on that value. Retiring it as terminus WITHOUT rewriting the branch is
        # what closes the clear; carrying a rewritten struct in would lose the CAS
        # every sweep and re-log this forever.
        Logger.error(
          "supervision escalation for assignment #{assignment.id} is undeliverable: " <>
            "the lineage ladder from #{pending.sessionKey} rung #{pending.pendingK} is " <>
            "exhausted and its owner has no active main session"
        )

        terminus(db, pending)

      target ->
        dispatch_wake(db, handlers, pending, assignment, target)
    end
  end

  defp drain_open(db, _handlers, %{pendingBranch: "terminus"} = pending, _assignment) do
    terminus(db, pending)
  end

  defp terminus(db, pending) do
    attempt_count =
      (prod_state(db, pending.pendingAssignment) || zero_state(pending.pendingAssignment)).attemptCount

    transaction!(db, fn txn ->
      if clear_pending_in_txn(txn, pending) do
        terminus_at = now()

        Txn.q(
          txn,
          """
          UPDATE supervision_entitlements
          SET dueAt=NULL, state='terminus', lastAttemptGeneration=NULL, claimClock=NULL,
              terminusAt=?2, cause='terminus', principal='process:tightbeam',
              supervisionIntervalMs=NULL
          WHERE assignmentId=?1 AND state='claimed'
          """,
          [pending.pendingAssignment, terminus_at]
        )

        terminated? = Txn.changes(txn) == 1

        EventLog.lifecycle_in_txn(
          txn,
          "supervision_terminus",
          pending.pendingAssignment,
          "holder=#{pending.sessionKey} attemptCount=#{attempt_count}"
        )

        if terminated? do
          EventLog.lifecycle_in_txn(
            txn,
            "supervision_entitlement_terminated",
            pending.pendingAssignment,
            "cause=terminus principal=process:tightbeam terminusAt=#{terminus_at}"
          )
        end
      end
    end)

    {:cleared, :terminus}
  end

  # "Recognition happens at act time or it is not recognition." (spec
  # production-machine-v1 §The prod production) The prodder is two-phase —
  # the claim records a durable pending branch, and this drain dispatches it,
  # possibly sweeps or a restart later — so the branch re-reads the standing
  # work-blocked and harness-health facts it was matched without. It DISCARDS
  # itself if either now stands. Nothing is lost: the obligation still stands
  # in working memory, and the production re-matches from current state after
  # retraction or normal-turn recovery.
  defp dispatch_wake(db, handlers, pending, assignment, target) do
    suppressed? =
      ConditionFacts.standing?(db, "work-blocked", pending.sessionKey) or
        harness_unavailable?(db, pending.sessionKey)

    if suppressed? do
      clear_pending(db, pending)
      {:cleared, nil}
    else
      deliver_wake(db, handlers, pending, assignment, target)
    end
  end

  defp deliver_wake(db, handlers, pending, assignment, target) do
    prompt =
      case pending.pendingBranch do
        "prod" ->
          prod_prompt(assignment.id, assignment.subject, pending.pendingK, pending.pendingN)

        "escalation" ->
          escalation_prompt(
            assignment.id,
            assignment.subject,
            pending.sessionKey,
            pending.pendingN,
            pending.pendingK
          )
      end

    # Supervision prods and escalations already hold their assignment when they
    # schedule; they stop dropping it. THIS is what unlocks prod-turn attribution.
    params = %{
      prompt: prompt,
      after_ms: 0,
      nudge: false,
      assignment_id: pending.pendingAssignment,
      supervision_wake_kind: pending.pendingBranch,
      supervision_session_key: pending.sessionKey,
      supervision_terminal_seq: pending.lastEvaluatedTerminal,
      supervision_k: pending.pendingK,
      supervision_n: pending.pendingN
    }

    params =
      if pending.pendingBranch == "escalation" do
        Map.merge(params, %{
          reresolve: "lineage",
          reresolve_seed: pending.sessionKey,
          reresolve_rung: pending.pendingK
        })
      else
        params
      end

    call = %{
      verb: "wake",
      origin: "process:tightbeam",
      principal: {:process, "tightbeam"},
      session_key: target,
      params: params
    }

    case Dispatch.dispatch(db, handlers, call) do
      {:ok, %{suppressed: true}} ->
        {:cleared, nil}

      {:ok, _} ->
        success_clear(db, pending)

        result =
          case pending.pendingBranch do
            "prod" -> {:prodded, pending.pendingK}
            "escalation" -> {:escalated, pending.pendingK, target}
          end

        {:cleared, result}

      {:error, %{code: code}} when code in ["rule_denied", "rule_error"] ->
        denied_streak = denied_clear(db, pending)
        detail = "code=#{code} deniedStreak=#{denied_streak}"
        best_effort_lifecycle(db, "supervision_prod_denied", assignment.id, detail)

        if denied_streak == max(pending.pendingN, 1) do
          best_effort_lifecycle(db, "supervision_blocked", assignment.id, detail)
        end

        {:cleared, {:refused, code}}

      {:error, %{code: code}} ->
        best_effort_lifecycle(db, "supervision_dispatch_failed", assignment.id, "code=#{code}")
        {:pending, {:refused, code}}
    end
  end

  defp clear_pending(db, pending) do
    transaction!(db, fn txn -> clear_pending_in_txn(txn, pending) end)
  end

  defp success_clear(db, pending) do
    _event_seq =
      transaction!(db, fn txn ->
        if clear_pending_in_txn(txn, pending) do
          Txn.q(
            txn,
            "UPDATE assignment_prods SET prodCount = prodCount + 1, lastProdAt = ?2, deniedStreak = 0 WHERE assignmentId = ?1",
            [pending.pendingAssignment, now()]
          )

          # prodCount is a mutable aggregate that RESETS on attest, and pendingK is
          # overwritten every evaluation: the tier that fired has no other home.
          if pending.pendingBranch == "prod" do
            at = now()
            job_ref = job_ref_in_txn(txn, pending.pendingAssignment)

            CausalEvents.append_in_txn(txn, %{
              kind: "prod_fired",
              assignment_id: pending.pendingAssignment,
              job_ref: job_ref,
              session_key: pending.sessionKey,
              at: at,
              detail: %{tier: pending.pendingK}
            })

            [[seq]] = Txn.q(txn, "SELECT last_insert_rowid()")

            event = %{
              seq: seq,
              at: at,
              job_ref: job_ref,
              assignment_id: pending.pendingAssignment,
              session_key: pending.sessionKey,
              kind: "prod_fired",
              detail: %{tier: pending.pendingK}
            }

            Tightbeam.Firehose.Publisher.observation_in_txn(
              txn,
              "prod.fired",
              event,
              %{
                "eventId" => seq,
                "assignmentId" => pending.pendingAssignment,
                "workItemId" => job_ref,
                "sessionKey" => pending.sessionKey
              },
              at
            )

            seq
          end
        end
      end)

    :ok
  end

  defp denied_clear(db, pending) do
    transaction!(db, fn txn ->
      if clear_pending_in_txn(txn, pending) do
        Txn.q(
          txn,
          "UPDATE assignment_prods SET deniedStreak = deniedStreak + 1 WHERE assignmentId = ?1",
          [pending.pendingAssignment]
        )
      end

      [[streak]] =
        Txn.q(txn, "SELECT deniedStreak FROM assignment_prods WHERE assignmentId = ?1", [
          pending.pendingAssignment
        ])

      streak
    end)
  end

  defp job_ref_in_txn(txn, assignment_id) do
    case Txn.q(txn, "SELECT workItemId FROM assignments WHERE id = ?1", [assignment_id]) do
      [[job_ref]] -> job_ref
      [] -> nil
    end
  end

  defp clear_pending_in_txn(txn, pending) do
    Txn.q(
      txn,
      """
      UPDATE supervision_watermarks
      SET pendingBranch = NULL, pendingAssignment = NULL, pendingK = NULL, pendingN = NULL
      WHERE sessionKey = ?1 AND pendingBranch = ?2 AND pendingAssignment = ?3
        AND lastEvaluatedTerminal IS ?4 AND pendingK IS ?5 AND pendingN IS ?6
      """,
      [
        pending.sessionKey,
        pending.pendingBranch,
        pending.pendingAssignment,
        pending.lastEvaluatedTerminal,
        pending.pendingK,
        pending.pendingN
      ]
    )

    Txn.changes(txn) == 1
  end

  defp open_assignment(db, assignment_id) do
    {:ok, rows} =
      DB.query(db, "SELECT id, subject FROM assignments WHERE id = ?1 AND state = 'open'", [
        assignment_id
      ])

    case rows do
      [[id, subject]] -> %{id: id, subject: subject}
      [] -> nil
    end
  end

  defp doorbells_for_holder(db, session_key) do
    db
    |> Assignments.list(%{holder_key: session_key, state: "open"})
    |> Enum.each(&doorbell(db, &1.id))
  end

  defp doorbell(db, assignment_id) do
    stamped =
      transaction!(db, fn txn ->
        Txn.q(
          txn,
          """
          INSERT INTO assignment_prods (assignmentId, strandedAt)
          VALUES (?1, ?2)
          ON CONFLICT(assignmentId) DO UPDATE SET strandedAt = excluded.strandedAt
          WHERE assignment_prods.strandedAt IS NULL
          """,
          [assignment_id, now()]
        )

        Txn.changes(txn) == 1
      end)

    if stamped, do: best_effort_lifecycle(db, "supervision_stranded", assignment_id, nil)
    :ok
  end

  defp notify_stranded_ancestor(state, session_key) do
    case Assignments.open_count(state.db, session_key) do
      0 ->
        :ok

      count ->
        row_label = if count == 1, do: "row", else: "rows"

        prompt =
          "Session #{session_key} retired with #{count} open assignment #{row_label}. " <>
            "The work is stranded and requires your attention."

        case ladder_target(state.db, session_key, 1) do
          nil ->
            Logger.error(
              "stranded-work notice for retired session #{session_key} " <>
                "(#{count} open assignment #{row_label}) is undeliverable: its owner has no " <>
                "active main session"
            )

          target ->
            Gateway.deliver_prompt(
              target,
              "process:tightbeam",
              prompt,
              [
                db: state.db,
                sender: "process:tightbeam",
                device_id: "process:tightbeam",
                client_message_id: "retired-strand:#{session_key}"
              ] ++ state.delivery_opts
            )
        end
    end
  end

  defp recover_liveness(%{sweep_ms: interval} = state)
       when is_integer(interval) and interval > 0 do
    recovery_clock = now()

    transaction!(state.db, fn txn ->
      retired_holders =
        Txn.q(
          txn,
          """
          SELECT DISTINCT s.sessionKey, s.ownerUserId
          FROM sessions s
          JOIN assignments a ON a.holderKey=s.sessionKey
          WHERE s.state='retired' AND a.state='open'
          ORDER BY s.sessionKey
          """
        )

      Enum.each(retired_holders, fn [session_key, owner_user_id] ->
        recover_retired_holder_in_txn(txn, session_key, owner_user_id)
      end)

      Txn.q(
        txn,
        """
        DELETE FROM supervision_entitlements
        WHERE assignmentId IN (SELECT id FROM assignments WHERE state='closed')
        """
      )

      normalize_legacy_lineage_markers_in_txn(txn)
      migrate_legacy_parent_retirements_in_txn(txn)

      existing =
        Txn.q(
          txn,
          """
          SELECT e.assignmentId
          FROM supervision_entitlements e
          JOIN assignments a ON a.id=e.assignmentId
          JOIN sessions s ON s.sessionKey=a.holderKey
          WHERE e.state IN ('armed','claimed') AND a.state='open' AND s.state='active'
          ORDER BY a.openedAt, a.id
          """
        )

      Enum.each(existing, fn [assignment_id] ->
        ensure_liveness_receipt_state_in_txn(
          txn,
          assignment_id,
          "recovery_backfill",
          "process:tightbeam"
        )

        absorb_liveness_receipts_in_txn(txn, assignment_id, interval)
      end)

      missing =
        Txn.q(
          txn,
          """
          SELECT a.id
          FROM assignments a
          JOIN sessions s ON s.sessionKey=a.holderKey
          LEFT JOIN supervision_entitlements e ON e.assignmentId=a.id
          WHERE a.state='open' AND s.state='active' AND e.assignmentId IS NULL
          ORDER BY a.openedAt, a.id
          """
        )

      Enum.each(missing, fn [assignment_id] ->
        case accepted_transfer(txn, assignment_id, nil) do
          {:ok, _projection} ->
            :ok

          :none ->
            baseline_progress_in_txn(txn, assignment_id)

            ensure_liveness_receipt_state_in_txn(
              txn,
              assignment_id,
              "recovery_backfill",
              "process:tightbeam"
            )

            Txn.q(
              txn,
              """
              INSERT INTO supervision_entitlements
                (assignmentId, generation, dueAt, state, lastAttemptGeneration, claimClock,
                 basisKind, basisId, terminusAt, cause, principal, supervisionIntervalMs)
              VALUES (?1, 1, ?2, 'armed', NULL, NULL, 'recovery_backfill', ?1, NULL,
                      'recovery_backfill', 'process:tightbeam', ?3)
              """,
              [assignment_id, recovery_clock + interval, interval]
            )

            EventLog.lifecycle_in_txn(
              txn,
              "supervision_entitlement_armed",
              assignment_id,
              "generation=1 basis=recovery_backfill:#{assignment_id} cause=recovery_backfill principal=process:tightbeam"
            )

          {:error, reason} ->
            raise "incompatible_supervision_liveness_v1: #{reason}"
        end
      end)
    end)
  end

  defp recover_liveness(_state), do: :ok

  # Recovery is not an authorized user or session principal. The revocation
  # provenance contract admits only a real user or session, so retain the
  # stranded assignment and report the refusal rather than inventing its
  # holder's owner as the revoker.
  defp recover_retired_holder_in_txn(txn, session_key, owner_user_id) do
    Assignments.interrupt_for_retire_in_txn(
      txn,
      session_key,
      owner_user_id,
      "process:tightbeam"
    )
  rescue
    error in ArgumentError ->
      if String.starts_with?(error.message, "retirement interruption requires a representable") do
        Logger.error(
          "retired-holder recovery refused for #{session_key}: #{Exception.message(error)}"
        )
      else
        reraise error, __STACKTRACE__
      end
  end

  defp baseline_progress_in_txn(txn, assignment_id) do
    rows =
      Txn.q(
        txn,
        """
        SELECT id, ts
        FROM attests
        WHERE assignmentId=?1 AND kind='progress'
        ORDER BY ts, id
        """,
        [assignment_id]
      )

    Enum.each(rows, fn [attest_id, attest_ts] ->
      Txn.q(
        txn,
        """
        INSERT OR IGNORE INTO supervision_progress_absorptions
          (attestId, assignmentId, attestTs, generation, recoveryBaseline, cause, principal)
        VALUES (?1, ?2, ?3, 1, 1, 'recovery_backfill', 'process:tightbeam')
        """,
        [attest_id, assignment_id, attest_ts]
      )
    end)
  end

  # The interrupted additive rollout could install the liveness schema and
  # then return to the old writer. Those old wakes carry the generic lineage
  # delivery marker but cannot be supervision transfers: the assignment never
  # had an entitlement, and therefore no controller generation ever existed.
  # Normalize only that self-identifying legacy shape. Clearing the routing
  # discriminator preserves the wake, turn, and message history. The durable
  # migration receipt makes this an upgrade step, not a startup repair loop:
  # after 0.1.6 has considered the existing ledger once, later malformed data
  # is not silently cleaned by normal writer or recovery paths.
  defp normalize_legacy_lineage_markers_in_txn(txn) do
    migration_id = "0.1.6/normalize-sidecarless-lineage-v1"

    case Txn.q(
           txn,
           "SELECT 1 FROM supervision_liveness_migrations WHERE migrationId=?1",
           [migration_id]
         ) do
      [[1]] ->
        :ok

      [] ->
        Txn.q(
          txn,
          """
          UPDATE wakes AS w
          SET reresolve=NULL, reresolveSeed=NULL, reresolveRung=NULL
          WHERE w.state='fired' AND w.origin='process:tightbeam'
            AND w.reresolve='lineage' AND w.assignmentId IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM supervision_liveness_sidecar s WHERE s.wakeId=w.wakeId
            )
            AND NOT EXISTS (
              SELECT 1 FROM supervision_entitlements e WHERE e.assignmentId=w.assignmentId
            )
            AND EXISTS (
              SELECT 1 FROM turns t
              WHERE t.wakeId=w.wakeId AND t.assignmentId=w.assignmentId
            )
          """
        )

        affected_rows = Txn.changes(txn)

        Txn.q(
          txn,
          """
          INSERT INTO supervision_liveness_migrations
            (migrationId, appliedAt, affectedRows, cause, principal)
          VALUES (?1, ?2, ?3, 'release_upgrade', 'process:tightbeam')
          """,
          [migration_id, now(), affected_rows]
        )

        :ok
    end
  end

  defp liveness_cycle(%{sweep_ms: interval} = state, terminal_rebases)
       when is_integer(interval) and interval > 0 do
    evaluation_clock = now()

    outcome =
      transaction!(state.db, fn txn ->
        assignments =
          Txn.q(
            txn,
            """
            SELECT e.assignmentId
            FROM supervision_entitlements e
            JOIN assignments a ON a.id=e.assignmentId
            JOIN sessions s ON s.sessionKey=a.holderKey
            WHERE e.state IN ('armed','claimed') AND a.state='open' AND s.state='active'
            ORDER BY a.openedAt, a.id
            """
          )

        rebased =
          Enum.reduce(assignments, terminal_rebases, fn [assignment_id], acc ->
            if MapSet.member?(acc, assignment_id) do
              acc
            else
              case absorb_liveness_receipts_in_txn(txn, assignment_id, interval) do
                :rebased -> MapSet.put(acc, assignment_id)
                :duplicate -> acc
              end
            end
          end)

        claim_due_in_txn(txn, evaluation_clock, rebased, state.n)
      end)

    case outcome do
      {:claimed, holder} ->
        case drain(state.db, state.handlers, holder) do
          {:pending, result} -> result
          {:cleared, result} -> result
        end

      _ ->
        :ok
    end
  end

  defp liveness_cycle(_state, _terminal_rebases), do: :ok

  defp absorb_liveness_receipts_in_txn(txn, assignment_id, interval) do
    ensure_liveness_receipt_state_in_txn(
      txn,
      assignment_id,
      "first_prod",
      "process:tightbeam"
    )

    [[generation, state]] =
      Txn.q(
        txn,
        "SELECT generation, state FROM supervision_entitlements WHERE assignmentId=?1",
        [assignment_id]
      )

    pending_controller? =
      Txn.q(
        txn,
        """
        SELECT 1 FROM supervision_liveness_sidecar
        WHERE assignmentId=?1 AND controllerOrigin='scheduled' AND controllerState='pending'
        LIMIT 1
        """,
        [assignment_id]
      ) != []

    if state in ["armed", "claimed"] and not pending_controller? do
      absorb_receipt_candidates_in_txn(txn, assignment_id, generation, interval)
    else
      :duplicate
    end
  end

  defp absorb_receipt_candidates_in_txn(txn, assignment_id, generation, interval) do
    evaluation_clock = now()

    [[holder, work_item_id]] =
      Txn.q(
        txn,
        "SELECT holderKey, workItemId FROM assignments WHERE id=?1 AND state='open'",
        [assignment_id]
      )

    [[artifact_cursor, attest_cursor, event_cursor, wake_cursor]] =
      Txn.q(
        txn,
        """
        SELECT artifactCursor, attestCursor, workItemEventCursor, wakeCursor
        FROM supervision_liveness_receipt_state WHERE assignmentId=?1
        """,
        [assignment_id]
      )

    [artifact_max, attest_max, event_max, wake_max] = receipt_source_maxima_in_txn(txn)

    effects =
      artifact_receipts_in_txn(
        txn,
        work_item_id,
        holder,
        artifact_cursor,
        artifact_max
      ) ++
        attest_receipts_in_txn(txn, assignment_id, generation, attest_cursor, attest_max) ++
        work_item_receipts_in_txn(txn, work_item_id, event_cursor, event_max)

    checkpoint =
      checkpoint_receipt_in_txn(
        txn,
        assignment_id,
        holder,
        wake_cursor,
        wake_max,
        effects,
        evaluation_clock
      )

    Txn.q(
      txn,
      """
      UPDATE supervision_liveness_receipt_state
      SET artifactCursor=?2, attestCursor=?3, workItemEventCursor=?4, wakeCursor=?5
      WHERE assignmentId=?1
      """,
      [assignment_id, artifact_max, attest_max, event_max, wake_max]
    )

    receipts = if effects == [], do: List.wrap(checkpoint), else: effects

    case receipts do
      [] ->
        :duplicate

      rows ->
        next_generation = generation + 1
        accepted_at = evaluation_clock

        Enum.each(rows, fn %{kind: kind, id: id, at: source_at, expires_at: expires_at} ->
          if kind == "progress" do
            Txn.q(
              txn,
              """
              INSERT INTO supervision_liveness_progress_receipts
                (assignmentId, sourceKind, sourceId, sourceAt, acceptedAt, generation)
              VALUES (?1, 'progress', ?2, ?3, ?4, ?5)
              """,
              [assignment_id, id, source_at, accepted_at, next_generation]
            )
          else
            Txn.q(
              txn,
              """
              INSERT INTO supervision_liveness_receipts
                (assignmentId, sourceKind, sourceId, sourceAt, acceptedAt, generation, expiresAt)
              VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
              """,
              [assignment_id, kind, id, source_at, accepted_at, next_generation, expires_at]
            )
          end
        end)

        basis_id =
          case Enum.find(rows, &(&1.kind == "progress")) do
            %{id: id} ->
              "progress:#{id}"

            nil ->
              [[receipt_id]] =
                Txn.q(
                  txn,
                  "SELECT MAX(receiptId) FROM supervision_liveness_receipts WHERE assignmentId=?1",
                  [assignment_id]
                )

              to_string(receipt_id)
          end

        [[attest_count]] =
          Txn.q(txn, "SELECT count(*) FROM attests WHERE assignmentId=?1", [assignment_id])

        Txn.q(
          txn,
          """
          INSERT INTO assignment_prods
            (assignmentId, attemptCount, prodCount, deniedStreak, attestCount, stalledAt)
          VALUES (?1, 0, 0, 0, ?2, NULL)
          ON CONFLICT(assignmentId) DO UPDATE SET
            attemptCount=0, prodCount=0, deniedStreak=0,
            attestCount=excluded.attestCount, stalledAt=NULL
          """,
          [assignment_id, attest_count]
        )

        due_at = receipt_due_at(rows, accepted_at, interval)

        # `supervision_entitlements` is a shape-validated legacy table. Keep its
        # accepted enum byte-compatible and reserve the existing progress slot;
        # the additive receipt ledger above is the authoritative provenance.
        Txn.q(
          txn,
          """
          UPDATE supervision_entitlements
          SET generation=?2, dueAt=?3, state='armed', lastAttemptGeneration=NULL,
              claimClock=NULL, basisKind='progress', basisId=?4, terminusAt=NULL,
              cause='progress', principal='process:tightbeam',
              supervisionIntervalMs=?5
          WHERE assignmentId=?1 AND generation=?6 AND state IN ('armed','claimed')
          """,
          [
            assignment_id,
            next_generation,
            due_at,
            "receipt:#{basis_id}",
            interval,
            generation
          ]
        )

        source_refs = Enum.map_join(rows, ",", &"#{&1.kind}:#{&1.id}")

        EventLog.lifecycle_in_txn(
          txn,
          "supervision_entitlement_rebased",
          assignment_id,
          "generation=#{next_generation} basis=liveness_receipt:#{basis_id} sources=#{source_refs} cause=liveness_receipt principal=process:tightbeam"
        )

        :rebased
    end
  end

  defp ensure_liveness_receipt_state_in_txn(
         txn,
         assignment_id,
         baseline_cause,
         principal
       ) do
    [artifact_cursor, attest_cursor, event_cursor, wake_cursor] =
      receipt_source_maxima_in_txn(txn)

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO supervision_liveness_receipt_state
        (assignmentId, artifactCursor, attestCursor, workItemEventCursor, wakeCursor,
         baselineCause, baselinePrincipal)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      """,
      [
        assignment_id,
        artifact_cursor,
        attest_cursor,
        event_cursor,
        wake_cursor,
        baseline_cause,
        principal
      ]
    )

    :ok
  end

  defp receipt_source_maxima_in_txn(txn) do
    [[artifact_cursor]] = Txn.q(txn, "SELECT COALESCE(MAX(rowid), 0) FROM artifacts")
    [[attest_cursor]] = Txn.q(txn, "SELECT COALESCE(MAX(rowid), 0) FROM attests")
    [[event_cursor]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM work_item_events")
    [[wake_cursor]] = Txn.q(txn, "SELECT COALESCE(MAX(rowid), 0) FROM wakes")
    [artifact_cursor, attest_cursor, event_cursor, wake_cursor]
  end

  defp artifact_receipts_in_txn(txn, work_item_id, holder, cursor, maximum) do
    Txn.q(
      txn,
      """
      SELECT artifactId, createdAt
      FROM artifacts
      WHERE rowid > ?1 AND rowid <= ?2 AND workItemId=?3 AND createdBySession=?4
      ORDER BY rowid
      """,
      [cursor, maximum, work_item_id, holder]
    )
    |> Enum.map(fn [id, at] -> %{kind: "artifact", id: id, at: at, expires_at: nil} end)
  end

  defp attest_receipts_in_txn(txn, assignment_id, generation, cursor, maximum) do
    Txn.q(
      txn,
      """
      SELECT id, kind, ts
      FROM attests
      WHERE rowid > ?1 AND rowid <= ?2 AND assignmentId=?3
        AND (
          kind='verdict'
          OR (
            kind='progress'
            AND NOT EXISTS (
              SELECT 1
              FROM wake_cancellations
              WHERE livenessTriggerKind='supervision_entitlement'
                AND livenessTriggerId=?4
                AND reasonKind='requester_withdrew'
                AND causalSourceKind='verb_call'
                AND NOT EXISTS (
                  SELECT 1
                  FROM supervision_liveness_sidecar
                  WHERE wakeId=wake_cancellations.wakeId
                )
            )
          )
        )
      ORDER BY rowid
      """,
      [cursor, maximum, assignment_id, "#{assignment_id}##{generation}"]
    )
    |> Enum.map(fn [id, kind, at] -> %{kind: kind, id: id, at: at, expires_at: nil} end)
  end

  defp work_item_receipts_in_txn(txn, work_item_id, cursor, maximum) do
    Txn.q(
      txn,
      """
      SELECT id, ts
      FROM work_item_events
      WHERE id > ?1 AND id <= ?2 AND workItemId=?3 AND kind='metadata'
      ORDER BY id
      """,
      [cursor, maximum, work_item_id]
    )
    |> Enum.map(fn [id, at] ->
      %{kind: "work_item_update", id: to_string(id), at: at, expires_at: nil}
    end)
  end

  defp checkpoint_receipt_in_txn(
         _txn,
         _assignment_id,
         _holder,
         _cursor,
         _maximum,
         effects,
         _evaluation_clock
       )
       when effects != [],
       do: nil

  defp checkpoint_receipt_in_txn(
         txn,
         assignment_id,
         holder,
         cursor,
         maximum,
         [],
         evaluation_clock
       ) do
    latest_kind =
      case Txn.q(
             txn,
             """
             SELECT sourceKind FROM supervision_liveness_receipts
             WHERE assignmentId=?1 ORDER BY receiptId DESC LIMIT 1
             """,
             [assignment_id]
           ) do
        [[kind]] -> kind
        [] -> nil
      end

    if latest_kind == "checkpoint" do
      nil
    else
      case Txn.q(
             txn,
             """
             SELECT w.wakeId, w.createdAt, w.dueAt
             FROM wakes w
             JOIN supervision_liveness_checkpoint_bindings b ON b.wakeId=w.wakeId
             WHERE w.rowid > ?1 AND w.rowid <= ?2
               AND b.assignmentId=?3 AND b.holderSessionKey=?4
               AND w.sessionKey=?4 AND w.creatorSessionKey=?4
               AND w.consumer='prompt' AND w.state='pending'
               AND w.dueAt > ?5 AND w.dueAt > w.createdAt
             ORDER BY w.dueAt, w.rowid
             LIMIT 1
             """,
             [cursor, maximum, assignment_id, holder, evaluation_clock]
           ) do
        [[id, at, due_at]] ->
          %{kind: "checkpoint", id: id, at: at, expires_at: due_at}

        [] ->
          nil
      end
    end
  end

  defp receipt_due_at([%{kind: "checkpoint", expires_at: due_at}], _accepted_at, _interval),
    do: due_at

  defp receipt_due_at(rows, accepted_at, interval) do
    latest_source = rows |> Enum.map(& &1.at) |> Enum.max()
    max(accepted_at, latest_source) + interval
  end

  defp claim_due_in_txn(txn, evaluation_clock, rebased, n) do
    candidates =
      Txn.q(
        txn,
        """
        SELECT e.assignmentId, e.generation, e.dueAt, e.lastAttemptGeneration,
               e.supervisionIntervalMs, e.basisKind, e.basisId,
               a.subject, a.holderKey
        FROM supervision_entitlements e
        JOIN assignments a ON a.id=e.assignmentId
        JOIN sessions s ON s.sessionKey=a.holderKey
        WHERE e.state='armed' AND e.dueAt <= ?1
          AND a.state='open' AND s.state='active'
        ORDER BY e.dueAt, a.openedAt, a.id
        """,
        [evaluation_clock]
      )

    Enum.reduce_while(candidates, :not_due, fn
      [
        assignment_id,
        generation,
        due_at,
        last_attempt_generation,
        interval,
        basis_kind,
        basis_id,
        subject,
        holder
      ],
      _acc ->
        cond do
          MapSet.member?(rebased, assignment_id) ->
            {:cont, :not_due}

          due_gate?(txn, assignment_id, holder) ->
            {:cont, :deferred}

          true ->
            case last_terminal_in_txn(txn, holder) do
              nil ->
                next_generation = generation + 1

                Txn.q(
                  txn,
                  """
                  UPDATE supervision_entitlements
                  SET generation=?2, dueAt=?3, state='armed', lastAttemptGeneration=NULL,
                      claimClock=NULL, basisKind='no_terminal', basisId=?4,
                      cause='no_terminal', principal='process:tightbeam'
                  WHERE assignmentId=?1 AND generation=?5 AND state='armed'
                  """,
                  [
                    assignment_id,
                    next_generation,
                    evaluation_clock + interval,
                    "#{assignment_id}##{generation}",
                    generation
                  ]
                )

                EventLog.lifecycle_in_txn(
                  txn,
                  "supervision_entitlement_rearmed",
                  assignment_id,
                  "generation=#{next_generation} basis=no_terminal:#{assignment_id}##{generation} cause=no_terminal principal=process:tightbeam"
                )

                {:halt, :deferred}

              terminal_seq ->
                assignment = %{id: assignment_id, subject: subject, holderKey: holder}

                case claim_entitlement_in_txn(
                       txn,
                       assignment,
                       generation,
                       due_at,
                       last_attempt_generation,
                       basis_kind,
                       basis_id,
                       evaluation_clock,
                       n,
                       terminal_seq,
                       "deadline"
                     ) do
                  :ok -> {:halt, {:claimed, holder}}
                  :stale -> {:cont, :not_due}
                end
            end
        end
    end)
  end

  defp due_gate?(txn, assignment_id, holder) do
    not is_nil(gate_reason_in_txn(txn, assignment_id, holder))
  end

  defp gate_reason_in_txn(txn, assignment_id, holder) do
    cond do
      Assignments.cannot_proceed_standing_in_txn?(txn, assignment_id) ->
        "cannot_proceed"

      harness_unavailable_in_txn?(txn, holder) ->
        "harness_unavailable"

      Txn.q(
        txn,
        "SELECT 1 FROM turns WHERE sessionKey=?1 AND status IN ('queued','running') LIMIT 1",
        [holder]
      ) != [] ->
        "pending_turn"

      Txn.q(
        txn,
        """
        SELECT 1
        FROM supervision_liveness_sidecar
        WHERE assignmentId=?1 AND controllerOrigin='scheduled' AND controllerState='pending'
        LIMIT 1
        """,
        [assignment_id]
      ) != [] ->
        "pending_wake"

      Txn.q(
        txn,
        """
        SELECT 1
        FROM condition_facts blocked
        WHERE blocked.kind='work-blocked' AND blocked.scope=?1
          AND blocked.id > COALESCE((
            SELECT MAX(cleared.id)
            FROM condition_facts cleared
            WHERE cleared.kind='work-unblocked' AND cleared.scope=?1
          ), 0)
        LIMIT 1
        """,
        [holder]
      ) != [] ->
        "work_blocked"

      true ->
        nil
    end
  end

  defp last_terminal_in_txn(txn, holder) do
    case Txn.q(
           txn,
           """
           SELECT seq
           FROM turns
           WHERE sessionKey=?1 AND endedAt IS NOT NULL
           ORDER BY seq DESC
           LIMIT 1
           """,
           [holder]
         ) do
      [[seq]] -> seq
      [] -> nil
    end
  end

  defp sweep(%{sweep_ms: interval} = state) when is_integer(interval) and interval > 0 do
    terminal_rebases = sweep_new_terminals(state)
    liveness_cycle(state, terminal_rebases)

    {:ok, pending_rows} =
      DB.query(
        state.db,
        "SELECT sessionKey FROM supervision_watermarks WHERE pendingBranch IS NOT NULL"
      )

    Enum.each(pending_rows, fn [session_key] ->
      safe_evaluate(state, session_key, fn -> drain(state.db, state.handlers, session_key) end)
    end)
  rescue
    error ->
      best_effort_lifecycle(
        state.db,
        "supervision_evaluate_failed",
        "sweep",
        Exception.message(error)
      )
  catch
    kind, reason ->
      best_effort_lifecycle(
        state.db,
        "supervision_evaluate_failed",
        "sweep",
        inspect({kind, reason})
      )
  end

  defp sweep(state), do: legacy_sweep(state)

  defp sweep_new_terminals(state) do
    open_holders =
      state.db
      |> Assignments.list(%{state: "open"})
      |> Enum.map(& &1.holderKey)
      |> Enum.reject(&ConditionFacts.standing?(state.db, "work-blocked", &1))
      |> Enum.reject(&harness_unavailable?(state.db, &1))

    {:ok, pending_rows} =
      DB.query(
        state.db,
        "SELECT sessionKey FROM supervision_watermarks WHERE pendingBranch IS NOT NULL"
      )

    pending_sessions = Enum.map(pending_rows, fn [session_key] -> session_key end)

    open_holders
    |> Kernel.++(pending_sessions)
    |> Enum.uniq()
    |> Enum.reduce(MapSet.new(), fn session_key, rebased ->
      terminal_seq = Ledger.last_terminal_seq(state.db, session_key)

      if new_terminal?(watermark(state.db, session_key), terminal_seq) do
        result =
          safe_evaluate(state, session_key, fn ->
            evaluate_with_interval(
              state.db,
              state.handlers,
              state.n,
              session_key,
              terminal_seq,
              state.sweep_ms
            )
          end)

        if result == :rebased do
          case oldest_supervised_assignment(state.db, session_key) do
            %{id: assignment_id} -> MapSet.put(rebased, assignment_id)
            nil -> rebased
          end
        else
          rebased
        end
      else
        rebased
      end
    end)
  end

  defp new_terminal?(_watermark, nil), do: false
  defp new_terminal?(nil, _terminal_seq), do: true

  defp new_terminal?(%{lastEvaluatedTerminal: prior}, terminal_seq),
    do: terminal_seq > prior

  defp legacy_sweep(state) do
    # Blocked holders are pre-filtered at sweep granularity (review N11): the
    # per-terminal evaluation would decline them anyway, but re-declining
    # every tick writes a rail_sweep lifecycle row per tick, and work-blocked
    # is designed to be long-lived. The turn-end path is untouched — a
    # terminal still runs the full shift once. Retraction needs no wiring:
    # the next tick reads the current fact and the holder is simply back.
    open_holders =
      state.db
      |> Assignments.list(%{state: "open"})
      |> Enum.map(& &1.holderKey)
      |> Enum.reject(&ConditionFacts.standing?(state.db, "work-blocked", &1))
      |> Enum.reject(&harness_unavailable?(state.db, &1))

    {:ok, pending_rows} =
      DB.query(
        state.db,
        "SELECT sessionKey FROM supervision_watermarks WHERE pendingBranch IS NOT NULL"
      )

    pending_sessions = Enum.map(pending_rows, fn [session_key] -> session_key end)

    open_holders
    |> Kernel.++(pending_sessions)
    |> Enum.uniq()
    |> Enum.each(fn session_key ->
      safe_evaluate(state, session_key, fn ->
        evaluate(
          state.db,
          state.handlers,
          state.n,
          session_key,
          Ledger.last_terminal_seq(state.db, session_key)
        )
      end)
    end)
  rescue
    error ->
      best_effort_lifecycle(
        state.db,
        "supervision_evaluate_failed",
        "sweep",
        Exception.message(error)
      )
  catch
    kind, reason ->
      best_effort_lifecycle(
        state.db,
        "supervision_evaluate_failed",
        "sweep",
        inspect({kind, reason})
      )
  end

  defp schedule_sweep(sweep_ms) when is_integer(sweep_ms) and sweep_ms > 0,
    do: Process.send_after(self(), :scheduled_sweep, sweep_ms)

  defp schedule_sweep(_sweep_ms), do: :ok

  defp safe_evaluate(state, session_key, fun) do
    fun.()
  rescue
    error ->
      best_effort_lifecycle(
        state.db,
        "supervision_evaluate_failed",
        session_key,
        Exception.message(error)
      )
  catch
    kind, reason ->
      best_effort_lifecycle(
        state.db,
        "supervision_evaluate_failed",
        session_key,
        inspect({kind, reason})
      )
  end

  defp best_effort_lifecycle(db, kind, subject, detail) do
    EventLog.lifecycle(db, kind, subject, detail)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp lineage(_db, nil, _visited, acc), do: Enum.reverse(acc)

  defp lineage(db, session_key, visited, acc) do
    if MapSet.member?(visited, session_key) do
      Enum.reverse(acc)
    else
      case query(db, "SELECT state FROM sessions WHERE sessionKey = ?1", [session_key]) do
        [[state]] ->
          next_acc = if state == "active", do: [session_key | acc], else: acc
          effective_parent = Org.effective_parent_in_txn(db, session_key).session_key
          lineage(db, effective_parent, MapSet.put(visited, session_key), next_acc)

        [] ->
          Enum.reverse(acc)
      end
    end
  end

  defp split_transfer_id(transfer_id) when is_binary(transfer_id) do
    case String.split(transfer_id, "#", parts: 2) do
      [assignment_id, encoded_seq] when assignment_id != "" ->
        case Integer.parse(encoded_seq) do
          {turn_seq, ""} when turn_seq > 0 -> {:ok, assignment_id, turn_seq}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp split_transfer_id(_transfer_id), do: :error

  defp assignment_belongs_to_work?(db_or_txn, assignment_id, %{kind: "work_item", id: id}) do
    query(
      db_or_txn,
      "SELECT 1 FROM assignments WHERE id=?1 AND workItemId=?2 AND state='open'",
      [assignment_id, id]
    ) != []
  end

  defp assignment_belongs_to_work?(_db_or_txn, _assignment_id, _primary), do: false

  defp transfer_projection(db_or_txn, assignment_id) do
    case accepted_transfer(db_or_txn, assignment_id, nil) do
      {:ok, transfer} ->
        %{
          supervisionState: "parent_elevated",
          supervisionGeneration: transfer.generation,
          supervisionDueAt: nil,
          supervisionIntervalMs: nil,
          supervisionBasisKind: nil,
          supervisionBasisId: nil,
          supervisionCause: transfer.cause,
          supervisionPrincipal: transfer.principal,
          supervisionTerminusAt: nil,
          supervisionTransferWakeId: transfer.wake_id,
          supervisionTransferSessionKey: transfer.session_key,
          supervisionRetirementEpoch: transfer.retirement_epoch,
          supervisionRetirementOutcomeKind: transfer.retirement_outcome_kind,
          supervisionRetirementOutcomeId: transfer.retirement_outcome_id,
          supervisionActionNeeded: transfer.action_needed
        }

      :none ->
        nil

      {:error, reason} ->
        raise "incompatible_supervision_liveness_v1: #{reason}"
    end
  end

  defp accepted_transfer(db_or_txn, assignment_id, requested_turn_seq) do
    candidates =
      query(
        db_or_txn,
        """
        SELECT t.seq, t.sessionKey, t.assignmentId,
               w.wakeId, w.state, w.assignmentId, w.origin, w.createdAt, w.firedAt,
               w.reresolve, w.reresolveSeed, w.reresolveRung,
               s.assignmentId, s.controllerOrigin, s.wakeKind, s.controllerState,
               s.chargedGeneration, s.transferEvidenceId
        FROM turns t
        JOIN wakes w ON w.wakeId=t.wakeId
        LEFT JOIN supervision_liveness_sidecar s ON s.wakeId=w.wakeId
        WHERE t.assignmentId=?1 AND w.assignmentId=?1
          AND (?2 IS NULL OR t.seq=?2)
          AND (w.reresolve='lineage' OR s.wakeKind='escalation')
        ORDER BY t.seq
        """,
        [assignment_id, requested_turn_seq]
      )
      |> Enum.map(&decode_transfer_row/1)
      |> Enum.reject(fn candidate ->
        candidate.transfer_evidence_id == "#{assignment_id}##{candidate.turn_seq}"
      end)

    case candidates do
      [] ->
        :none

      _ ->
        candidates
        |> Enum.reverse()
        |> Enum.reduce_while({:error, :invalid_parent_transfer}, fn candidate, _result ->
          case validate_transfer(db_or_txn, assignment_id, candidate) do
            {:ok, transfer} -> {:halt, {:ok, transfer}}
            {:error, :invalid_parent_transfer} -> {:cont, {:error, :invalid_parent_transfer}}
          end
        end)
    end
  end

  defp decode_transfer_row([
         turn_seq,
         session_key,
         turn_assignment_id,
         wake_id,
         wake_state,
         wake_assignment_id,
         origin,
         created_at,
         fired_at,
         reresolve,
         reresolve_seed,
         reresolve_rung,
         sidecar_assignment_id,
         controller_origin,
         wake_kind,
         controller_state,
         charged_generation,
         transfer_evidence_id
       ]) do
    %{
      turn_seq: turn_seq,
      session_key: session_key,
      turn_assignment_id: turn_assignment_id,
      wake_id: wake_id,
      wake_state: wake_state,
      wake_assignment_id: wake_assignment_id,
      origin: origin,
      created_at: created_at,
      fired_at: fired_at,
      reresolve: reresolve,
      reresolve_seed: reresolve_seed,
      reresolve_rung: reresolve_rung,
      sidecar_assignment_id: sidecar_assignment_id,
      controller_origin: controller_origin,
      wake_kind: wake_kind,
      controller_state: controller_state,
      charged_generation: charged_generation,
      transfer_evidence_id: transfer_evidence_id
    }
  end

  defp validate_transfer(db_or_txn, assignment_id, candidate) do
    evidence_id = "#{assignment_id}##{candidate.turn_seq}"

    common? =
      candidate.turn_assignment_id == assignment_id and
        candidate.wake_assignment_id == assignment_id and
        candidate.wake_state == "fired" and candidate.origin == "process:tightbeam" and
        candidate.reresolve == "lineage" and is_integer(candidate.reresolve_rung) and
        candidate.reresolve_rung > 0 and is_binary(candidate.reresolve_seed) and
        session_exists?(db_or_txn, candidate.session_key) and
        candidate.transfer_evidence_id != evidence_id

    branch =
      cond do
        not common? ->
          :error

        candidate.controller_origin == "scheduled" ->
          validate_scheduled_transfer(db_or_txn, candidate)

        candidate.controller_origin == "retirement_elevation" ->
          validate_retirement_transfer(db_or_txn, assignment_id, evidence_id, candidate)

        true ->
          :error
      end

    case branch do
      {:ok, predecessor} ->
        {:ok,
         Map.merge(
           %{
             assignment_id: assignment_id,
             turn_seq: candidate.turn_seq,
             session_key: candidate.session_key,
             wake_id: candidate.wake_id,
             generation: candidate.charged_generation,
             reresolve_seed: candidate.reresolve_seed,
             reresolve_rung: candidate.reresolve_rung,
             evidence_id: evidence_id,
             cause: "parent_elevated",
             principal: "process:tightbeam",
             retirement_epoch: nil,
             retirement_outcome_kind: nil,
             retirement_outcome_id: nil,
             action_needed: nil
           },
           predecessor
         )}

      :error ->
        {:error, :invalid_parent_transfer}
    end
  end

  defp validate_scheduled_transfer(db_or_txn, candidate) do
    if candidate.sidecar_assignment_id == candidate.turn_assignment_id and
         candidate.controller_state == "settled" and candidate.wake_kind == "escalation" and
         is_integer(candidate.charged_generation) and candidate.charged_generation > 0 and
         ladder_target(
           db_or_txn,
           candidate.reresolve_seed,
           candidate.reresolve_rung
         ) == candidate.session_key do
      {:ok, %{}}
    else
      :error
    end
  end

  defp migrate_legacy_parent_retirements_in_txn(txn) do
    activation_epoch = liveness_epoch!(txn)

    assignments =
      Txn.q(
        txn,
        """
        SELECT a.id
        FROM assignments a
        LEFT JOIN supervision_entitlements e ON e.assignmentId=a.id
        WHERE a.state='open' AND e.assignmentId IS NULL
        ORDER BY a.openedAt, a.id
        """
      )

    Enum.each(assignments, fn [assignment_id] ->
      case legacy_outcomes_in_txn(txn, assignment_id) do
        [] ->
          migrate_legacy_candidate_in_txn(txn, assignment_id, activation_epoch)

        [_outcome] ->
          case accepted_transfer(txn, assignment_id, nil) do
            {:ok, %{cause: "legacy_parent_target_retired"}} -> :ok
            _ -> legacy_refusal!(assignment_id, "legacy_parent_successor_conflict")
          end

        _many ->
          legacy_refusal!(assignment_id, "legacy_parent_successor_conflict")
      end
    end)
  end

  defp legacy_outcomes_in_txn(txn, assignment_id) do
    Txn.q(
      txn,
      """
      SELECT wakeId
      FROM supervision_liveness_sidecar
      WHERE assignmentId=?1 AND retirementCause='legacy_parent_target_retired'
      ORDER BY wakeId
      """,
      [assignment_id]
    )
  end

  defp migrate_legacy_candidate_in_txn(txn, assignment_id, activation_epoch) do
    candidates =
      transfer_candidates(txn, assignment_id)
      |> Enum.filter(
        &potential_legacy_candidate?(
          txn,
          assignment_id,
          activation_epoch,
          &1
        )
      )

    case candidates do
      [] ->
        :ok

      [candidate] ->
        migrate_one_legacy_transfer_in_txn(
          txn,
          assignment_id,
          candidate,
          activation_epoch
        )

      _many ->
        legacy_refusal!(assignment_id, "legacy_parent_transfer_ambiguous")
    end
  end

  defp transfer_candidates(txn, assignment_id) do
    Txn.q(
      txn,
      """
      SELECT t.seq, t.sessionKey, t.assignmentId,
             w.wakeId, w.state, w.assignmentId, w.origin, w.createdAt, w.firedAt,
             w.reresolve, w.reresolveSeed, w.reresolveRung,
             s.assignmentId, s.controllerOrigin, s.wakeKind, s.controllerState,
             s.chargedGeneration, s.transferEvidenceId
      FROM turns t
      JOIN wakes w ON w.wakeId=t.wakeId
      LEFT JOIN supervision_liveness_sidecar s ON s.wakeId=w.wakeId
      WHERE t.assignmentId=?1 AND w.assignmentId=?1
        AND (w.reresolve='lineage' OR s.wakeKind='escalation')
      ORDER BY t.seq
      """,
      [assignment_id]
    )
    |> Enum.map(&decode_transfer_row/1)
  end

  defp potential_legacy_candidate?(
         txn,
         assignment_id,
         activation_epoch,
         candidate
       ) do
    structural? =
      candidate.turn_assignment_id == assignment_id and
        candidate.wake_assignment_id == assignment_id and
        candidate.wake_state == "fired" and candidate.origin == "process:tightbeam" and
        candidate.reresolve == "lineage" and is_integer(candidate.reresolve_rung) and
        candidate.reresolve_rung > 0 and is_binary(candidate.reresolve_seed) and
        is_nil(candidate.transfer_evidence_id) and
        legacy_source_shape?(assignment_id, activation_epoch, candidate)

    structural? and
      ladder_target(
        txn,
        candidate.reresolve_seed,
        candidate.reresolve_rung
      ) != candidate.session_key
  rescue
    _ -> false
  end

  defp legacy_source_shape?(assignment_id, _activation_epoch, candidate)
       when candidate.controller_origin == "scheduled" do
    candidate.sidecar_assignment_id == assignment_id and
      candidate.controller_state == "settled" and candidate.wake_kind == "escalation" and
      is_integer(candidate.charged_generation) and candidate.charged_generation > 0
  end

  defp legacy_source_shape?(_assignment_id, _activation_epoch, _candidate), do: false

  defp migrate_one_legacy_transfer_in_txn(txn, assignment_id, candidate, activation_epoch) do
    case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [
           candidate.session_key
         ]) do
      [] ->
        legacy_refusal!(
          assignment_id,
          "legacy_parent_target_missing",
          candidate
        )

      [["retired"]] ->
        :ok

      [[_state]] ->
        legacy_refusal!(
          assignment_id,
          "legacy_parent_target_not_retired",
          candidate
        )
    end

    [[subject]] =
      Txn.q(txn, "SELECT subject FROM assignments WHERE id=?1 AND state='open'", [
        assignment_id
      ])

    target = legacy_owner_main_in_txn(txn, assignment_id, candidate)

    transfer =
      candidate
      |> Map.put(:assignment_id, assignment_id)
      |> Map.put(:evidence_id, "#{assignment_id}##{candidate.turn_seq}")

    invalidate_transfer_turn_in_txn(txn, transfer, activation_epoch)

    wake =
      Wakes.schedule_in_txn(txn, %{
        session_key: target,
        origin: "process:tightbeam",
        prompt:
          escalation_prompt(
            assignment_id,
            subject,
            candidate.reresolve_seed,
            0,
            candidate.reresolve_rung
          ),
        due_at: activation_epoch,
        assignment_id: assignment_id,
        reresolve: "lineage",
        reresolve_seed: candidate.reresolve_seed,
        reresolve_rung: candidate.reresolve_rung
      })

    insert_retirement_controller_in_txn(txn, wake.wake_id, assignment_id, transfer.wake_id)

    case Gateway.deliver_prompt_in_txn(
           txn,
           target,
           wake.origin,
           wake.prompt,
           wake_id: wake.wake_id,
           sender: wake.origin,
           fire_wake_in_txn: true,
           assignment_id: assignment_id
         ) do
      {:appended, ^target, _message, _opts} ->
        :ok

      other ->
        legacy_refusal!(
          assignment_id,
          "legacy_parent_successor_conflict delivery=#{inspect(other)}",
          candidate
        )
    end

    [[turn_seq]] = Txn.q(txn, "SELECT seq FROM turns WHERE wakeId=?1", [wake.wake_id])
    outcome_id = "#{assignment_id}##{turn_seq}"

    store_legacy_retirement_outcome_in_txn(
      txn,
      transfer,
      activation_epoch,
      outcome_id,
      target
    )
  end

  defp legacy_owner_main_in_txn(txn, assignment_id, candidate) do
    rows =
      Txn.q(
        txn,
        """
        SELECT s.sessionKey
        FROM assignments a
        JOIN work_items wi ON wi.id=a.workItemId
        JOIN sessions s ON s.ownerUserId=wi.ownerUserId
        WHERE a.id=?1 AND s.kind='main' AND s.isBuiltIn=1 AND s.state='active'
        ORDER BY s.sessionKey
        """,
        [assignment_id]
      )

    case rows do
      [[target]] -> target
      _ -> legacy_refusal!(assignment_id, "legacy_parent_successor_conflict", candidate)
    end
  end

  defp store_legacy_retirement_outcome_in_txn(
         txn,
         transfer,
         activation_epoch,
         outcome_id,
         target
       ) do
    Txn.q(
      txn,
      """
      INSERT INTO supervision_liveness_sidecar
        (wakeId, assignmentId, transferEvidenceId, retirementEpoch,
         retiringSessionKey, retirementOutcomeKind, retirementOutcomeId,
         retirementTargetSessionKey, retirementCause, retirementPrincipal,
         retirementActionNeeded)
      VALUES (?1, ?2, ?3, ?4, ?5, 'main_elevation', ?6, ?7,
              'legacy_parent_target_retired', 'process:tightbeam', 1)
      ON CONFLICT(wakeId) DO UPDATE SET
        transferEvidenceId=excluded.transferEvidenceId,
        retirementEpoch=excluded.retirementEpoch,
        retiringSessionKey=excluded.retiringSessionKey,
        retirementOutcomeKind=excluded.retirementOutcomeKind,
        retirementOutcomeId=excluded.retirementOutcomeId,
        retirementTargetSessionKey=excluded.retirementTargetSessionKey,
        retirementCause=excluded.retirementCause,
        retirementPrincipal=excluded.retirementPrincipal,
        retirementActionNeeded=excluded.retirementActionNeeded
      WHERE supervision_liveness_sidecar.transferEvidenceId IS NULL
      """,
      [
        transfer.wake_id,
        transfer.assignment_id,
        transfer.evidence_id,
        activation_epoch,
        transfer.session_key,
        outcome_id,
        target
      ]
    )

    if Txn.changes(txn) != 1 do
      legacy_refusal!(
        transfer.assignment_id,
        "legacy_parent_successor_conflict",
        transfer
      )
    end
  end

  defp legacy_refusal!(assignment_id, detail, candidate \\ nil) do
    suffix =
      if is_map(candidate) do
        " assignment=#{assignment_id} evidence=#{assignment_id}##{candidate.turn_seq} target=#{candidate.session_key}"
      else
        " assignment=#{assignment_id}"
      end

    raise "incompatible_supervision_liveness_v1: #{detail}#{suffix}"
  end

  defp validate_retirement_transfer(db_or_txn, assignment_id, evidence_id, candidate) do
    if candidate.sidecar_assignment_id == assignment_id and
         candidate.controller_state == "settled" and candidate.wake_kind == "escalation" and
         is_nil(candidate.charged_generation) do
      predecessors =
        query(
          db_or_txn,
          """
          SELECT wakeId, transferEvidenceId, retirementEpoch, retiringSessionKey,
                 retirementOutcomeKind, retirementOutcomeId, retirementTargetSessionKey,
                 retirementCause, retirementPrincipal, retirementActionNeeded
          FROM supervision_liveness_sidecar
          WHERE retirementOutcomeId=?1 AND wakeId<>?2
          """,
          [evidence_id, candidate.wake_id]
        )

      case predecessors do
        [predecessor] ->
          validate_retirement_predecessor(
            db_or_txn,
            assignment_id,
            evidence_id,
            candidate,
            predecessor
          )

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp validate_retirement_predecessor(
         db_or_txn,
         assignment_id,
         evidence_id,
         candidate,
         [
           _source_wake_id,
           invalidated_evidence_id,
           epoch,
           _retiring_session_key,
           outcome_kind,
           predecessor_outcome_id,
           target,
           cause,
           principal,
           action_needed
         ]
       ) do
    owner_main = assignment_owner_main(db_or_txn, assignment_id)

    shared? =
      predecessor_outcome_id == evidence_id and invalidated_evidence_id != evidence_id and
        is_integer(epoch) and epoch >= 0 and target == candidate.session_key

    runtime? =
      cause == "parent_target_retired" and
        ((outcome_kind == "parent_elevation" and action_needed == 0 and target != owner_main) or
           (outcome_kind == "main_elevation" and action_needed == 1 and target == owner_main))

    legacy? =
      cause == "legacy_parent_target_retired" and principal == "process:tightbeam" and
        outcome_kind == "main_elevation" and action_needed == 1 and target == owner_main and
        liveness_epoch_matches?(db_or_txn, epoch)

    if shared? and (runtime? or legacy?) do
      {:ok,
       %{
         cause: cause,
         principal: principal,
         retirement_epoch: epoch,
         retirement_outcome_kind: outcome_kind,
         retirement_outcome_id: evidence_id,
         action_needed: action_needed == 1
       }}
    else
      :error
    end
  end

  defp liveness_epoch(db_or_txn) do
    case query(
           db_or_txn,
           """
           SELECT id, activatedAt, cause, principal
           FROM supervision_liveness_epoch
           ORDER BY id
           """,
           []
         ) do
      [[0, activated_at, "schema_activation", "process:tightbeam"]]
      when is_integer(activated_at) and activated_at >= 0 ->
        {:ok, activated_at}

      _ ->
        :error
    end
  end

  defp liveness_epoch!(db_or_txn) do
    case liveness_epoch(db_or_txn) do
      {:ok, activated_at} ->
        activated_at

      :error ->
        raise "invalid supervision_liveness_epoch: expected exactly row 0 with a nonnegative activatedAt, schema_activation cause, and process:tightbeam principal"
    end
  end

  defp liveness_epoch_matches?(db_or_txn, activated_at) do
    liveness_epoch(db_or_txn) == {:ok, activated_at}
  end

  defp session_exists?(db_or_txn, session_key) do
    query(db_or_txn, "SELECT 1 FROM sessions WHERE sessionKey=?1", [session_key]) != []
  end

  defp assignment_owner_main(db_or_txn, assignment_id) do
    case query(
           db_or_txn,
           """
           SELECT wi.ownerUserId
           FROM assignments a
           JOIN work_items wi ON wi.id=a.workItemId
           WHERE a.id=?1
           """,
           [assignment_id]
         ) do
      [[owner_user_id]] -> Org.personal_session_key(owner_user_id)
      [] -> nil
    end
  end

  defp transferred_assignments_in_txn(txn, target_session_key) do
    query(
      txn,
      """
      SELECT a.id
      FROM assignments a
      LEFT JOIN supervision_entitlements e ON e.assignmentId=a.id
      WHERE a.state='open' AND e.assignmentId IS NULL
      ORDER BY a.openedAt, a.id
      """,
      []
    )
    |> Enum.reduce([], fn [assignment_id], acc ->
      case accepted_transfer(txn, assignment_id, nil) do
        {:ok, %{session_key: ^target_session_key} = transfer} ->
          [{assignment_id, transfer} | acc]

        {:ok, _other_target} ->
          acc

        :none ->
          acc

        {:error, reason} ->
          raise "incompatible_supervision_liveness_v1: #{reason}"
      end
    end)
    |> Enum.reverse()
  end

  defp recover_retired_target_in_txn(
         txn,
         assignment_id,
         transfer,
         retirement_epoch,
         supervision_interval_ms,
         principal
       ) do
    [[holder, subject]] =
      query(txn, "SELECT holderKey, subject FROM assignments WHERE id=?1 AND state='open'", [
        assignment_id
      ])

    if active_session?(txn, holder) do
      generation = (transfer.generation || 0) + 1
      outcome_id = "#{assignment_id}##{generation}"

      invalidate_transfer_turn_in_txn(txn, transfer, retirement_epoch, sync_session: false)

      Txn.q(
        txn,
        """
        INSERT INTO supervision_entitlements
          (assignmentId, generation, dueAt, state, lastAttemptGeneration, claimClock,
           basisKind, basisId, terminusAt, cause, principal, supervisionIntervalMs)
        VALUES (?1, ?2, ?3, 'armed', NULL, NULL, 'parent_retirement', ?4, NULL,
                'parent_target_retired', ?5, ?6)
        """,
        [
          assignment_id,
          generation,
          retirement_epoch + supervision_interval_ms,
          "#{transfer.evidence_id}##{retirement_epoch}",
          principal,
          supervision_interval_ms
        ]
      )

      store_retirement_outcome_in_txn(
        txn,
        transfer,
        retirement_epoch,
        "child_rearm",
        outcome_id,
        nil,
        principal,
        false
      )

      EventLog.lifecycle_in_txn(
        txn,
        "supervision_entitlement_rearmed",
        assignment_id,
        "generation=#{generation} basis=parent_retirement:#{transfer.evidence_id}##{retirement_epoch} cause=parent_target_retired principal=#{principal}"
      )

      :armed
    else
      target = retirement_successor(txn, transfer, assignment_id)
      main = assignment_owner_main(txn, assignment_id)
      outcome_kind = if target == main, do: "main_elevation", else: "parent_elevation"
      action_needed = outcome_kind == "main_elevation"

      invalidate_transfer_turn_in_txn(txn, transfer, retirement_epoch, sync_session: false)

      wake =
        Wakes.schedule_in_txn(txn, %{
          session_key: target,
          origin: "process:tightbeam",
          prompt:
            escalation_prompt(
              assignment_id,
              subject,
              transfer.reresolve_seed,
              0,
              transfer.reresolve_rung
            ),
          due_at: retirement_epoch,
          assignment_id: assignment_id,
          reresolve: "lineage",
          reresolve_seed: transfer.reresolve_seed,
          reresolve_rung: transfer.reresolve_rung
        })

      insert_retirement_controller_in_txn(txn, wake.wake_id, assignment_id, transfer.wake_id)

      case Gateway.deliver_prompt_in_txn(
             txn,
             target,
             wake.origin,
             wake.prompt,
             wake_id: wake.wake_id,
             sender: wake.origin,
             fire_wake_in_txn: true,
             assignment_id: assignment_id
           ) do
        {:appended, ^target, _message, _opts} ->
          :ok

        other ->
          raise "incompatible_supervision_liveness_v1: retirement delivery #{inspect(other)}"
      end

      [[turn_seq]] = Txn.q(txn, "SELECT seq FROM turns WHERE wakeId=?1", [wake.wake_id])
      outcome_id = "#{assignment_id}##{turn_seq}"

      store_retirement_outcome_in_txn(
        txn,
        transfer,
        retirement_epoch,
        outcome_kind,
        outcome_id,
        target,
        principal,
        action_needed
      )

      EventLog.lifecycle_in_txn(
        txn,
        "supervision_entitlement_transferred",
        assignment_id,
        "wakeId=#{wake.wake_id} transfer=#{outcome_id} target=#{target} cause=parent_target_retired principal=#{principal}"
      )

      :parent_elevated
    end
  end

  defp invalidate_transfer_turn_in_txn(txn, transfer, retirement_epoch, opts \\ []) do
    Txn.q(
      txn,
      "UPDATE turns SET status='canceled', endedAt=?2 WHERE seq=?1 AND status='queued'",
      [transfer.turn_seq, retirement_epoch]
    )

    if Txn.changes(txn) == 1 and Keyword.get(opts, :sync_session, true),
      do: Tightbeam.Org.sync_mechanical_status_in_txn(txn, transfer.session_key)
  end

  defp insert_retirement_controller_in_txn(
         txn,
         wake_id,
         assignment_id,
         source_wake_id
       ) do
    Txn.q(
      txn,
      """
      INSERT INTO supervision_liveness_sidecar
        (wakeId, assignmentId, controllerOrigin, wakeKind, controllerState,
         chargedGeneration, rootTurnSeq)
      SELECT ?1, ?2, 'retirement_elevation', 'escalation', 'settled', NULL,
             source.rootTurnSeq
      FROM supervision_liveness_sidecar source
      WHERE source.wakeId=?3 AND source.assignmentId=?2
        AND source.controllerOrigin IS NOT NULL
      """,
      [wake_id, assignment_id, source_wake_id]
    )

    if Txn.changes(txn) != 1 do
      raise "incompatible_supervision_liveness_v1: retirement controller root link missing"
    end

    :ok
  end

  defp store_retirement_outcome_in_txn(
         txn,
         transfer,
         retirement_epoch,
         outcome_kind,
         outcome_id,
         target,
         principal,
         action_needed
       ) do
    Txn.q(
      txn,
      """
      INSERT INTO supervision_liveness_sidecar
        (wakeId, assignmentId, transferEvidenceId, retirementEpoch,
         retiringSessionKey, retirementOutcomeKind, retirementOutcomeId,
         retirementTargetSessionKey, retirementCause, retirementPrincipal,
         retirementActionNeeded)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8,
              'parent_target_retired', ?9, ?10)
      ON CONFLICT(wakeId) DO UPDATE SET
        transferEvidenceId=excluded.transferEvidenceId,
        retirementEpoch=excluded.retirementEpoch,
        retiringSessionKey=excluded.retiringSessionKey,
        retirementOutcomeKind=excluded.retirementOutcomeKind,
        retirementOutcomeId=excluded.retirementOutcomeId,
        retirementTargetSessionKey=excluded.retirementTargetSessionKey,
        retirementCause=excluded.retirementCause,
        retirementPrincipal=excluded.retirementPrincipal,
        retirementActionNeeded=excluded.retirementActionNeeded
      WHERE supervision_liveness_sidecar.transferEvidenceId IS NULL
      """,
      [
        transfer.wake_id,
        transfer.assignment_id,
        transfer.evidence_id,
        retirement_epoch,
        transfer.session_key,
        outcome_kind,
        outcome_id,
        target,
        principal,
        if(action_needed, do: 1, else: 0)
      ]
    )

    if Txn.changes(txn) != 1 do
      raise "incompatible_supervision_liveness_v1: parent retirement outcome conflict"
    end
  end

  defp retirement_successor(txn, transfer, assignment_id) do
    owner_main = assignment_owner_main(txn, assignment_id)

    candidate =
      ladder_target_excluding(
        txn,
        transfer.reresolve_seed,
        transfer.reresolve_rung,
        transfer.session_key
      )

    cond do
      is_binary(candidate) and candidate != owner_main -> candidate
      is_binary(owner_main) and active_session?(txn, owner_main) -> owner_main
      true -> raise "incompatible_supervision_liveness_v1: parent retirement target missing"
    end
  end

  defp ladder_target_excluding(db_or_txn, holder_key, rung, excluded) do
    %{owner_user_id: owner, session_key: effective_parent} =
      Org.effective_parent_in_txn(db_or_txn, holder_key)

    chain =
      lineage_excluding(
        db_or_txn,
        effective_parent,
        excluded,
        MapSet.new([holder_key]),
        []
      )

    case Enum.at(chain, rung - 1) do
      nil ->
        main = Org.personal_session_key(owner)
        if main != excluded and active_session?(db_or_txn, main), do: main

      target ->
        target
    end
  end

  defp lineage_excluding(_db_or_txn, nil, _excluded, _visited, acc), do: Enum.reverse(acc)

  defp lineage_excluding(db_or_txn, session_key, excluded, visited, acc) do
    if MapSet.member?(visited, session_key) do
      Enum.reverse(acc)
    else
      case query(db_or_txn, "SELECT state FROM sessions WHERE sessionKey=?1", [session_key]) do
        [[state]] ->
          next_acc =
            if state == "active" and session_key != excluded,
              do: [session_key | acc],
              else: acc

          effective_parent = Org.effective_parent_in_txn(db_or_txn, session_key).session_key

          lineage_excluding(
            db_or_txn,
            effective_parent,
            excluded,
            MapSet.put(visited, session_key),
            next_acc
          )

        [] ->
          Enum.reverse(acc)
      end
    end
  end

  defp active_session?(db_or_txn, session_key) do
    query(db_or_txn, "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'", [
      session_key
    ]) != []
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  defp zero_state(assignment_id) do
    %{
      assignmentId: assignment_id,
      attemptCount: 0,
      prodCount: 0,
      deniedStreak: 0,
      attestCount: 0,
      lastProdAt: nil,
      stalledAt: nil,
      strandedAt: nil
    }
  end

  defp prod_prompt(id, subject, k, n) do
    "Your turn ended with no filing and no continuation scheduled for assignment #{id} — \"#{subject}\". " <>
      "File completion, schedule your continuation, or file cannot-proceed with a reason. This is prod #{k} of #{n}; " <>
      "a reply without a row escalates to your spawner."
  end

  defp escalation_prompt(id, subject, holder, n, rung) do
    "Assignment #{id} — \"#{subject}\" — held by #{holder} is stalled: #{n} prods produced no filing " <>
      "and no continuation. This is escalation #{rung} for this assignment. Why, and what happens next, " <>
      "is your judgment — the substrate only reports the rows."
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)
end
