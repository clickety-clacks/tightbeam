defmodule Tightbeam.RowReactions do
  @moduledoc false
  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.HarnessHealth.RecoverySchedule
  alias Tightbeam.HarnessHealth.RecoveryScheduler
  alias Tightbeam.RowReactions.{Cutover, Notice, Snapshot, Store}
  require Logger

  def observe_work_item_in_txn(txn, id, operation, source, before, transition \\ nil) do
    Cutover.adopt(txn)

    after_row =
      Snapshot.current(txn, %{"kind" => "work_item_observation", "workItemId" => id}, %{})[
        "work_item"
      ]

    if after_row do
      event = %{
        "id" => "work-item:#{id}:#{operation}:#{source.kind}:#{source[:generation] || source.id}",
        "org" => after_row["ownerUserId"],
        "kind" => "work_item_observation",
        "workItemId" => id,
        "operation" => operation,
        "at" => source[:at] || after_row["createdAt"],
        "generation" => source[:generation] || source.id,
        "source" => stringify(Map.take(source, [:kind, :id])),
        "principal" => observation_principal(source[:principal]),
        "before" =>
          Map.merge(before || %{}, %{
            "workItem" => source[:work_item_before],
            "sourceRow" => source[:before]
          }),
        "after" => after_row,
        "sourceAfter" => source[:after],
        "transition" => if(transition, do: JSON.decode!(JSON.encode!(transition)))
      }

      # Expressions and durable replay must see the same nested key types.
      event = event |> JSON.encode!() |> JSON.decode!()

      # A repeated observation reads its captured event, rather than inventing
      # another occurrence or changing the occurrence timestamp.
      event =
        case Store.event(txn, event["org"], event["id"]) do
          {stored, _} -> stored
          nil -> event
        end

      admit(txn, event)
    else
      []
    end
  end

  defp observation_principal({kind, id}) when kind in [:user, :session, :process],
    do: %{"kind" => Atom.to_string(kind), "id" => id}

  defp observation_principal({:remedy, %{statute: statute, action: action, owner: owner}}),
    do: %{"kind" => "remedy", "id" => statute, "action" => action, "ownerUserId" => owner}

  defp observation_principal(nil), do: nil

  def harness_health_hold_in_txn(
        txn,
        incident_id,
        transition,
        at,
        before \\ nil,
        cycle_release \\ false
      )
      when transition in ["opened", "resolved"] do
    Cutover.adopt(txn)
    after_snapshot = Snapshot.harness_health_hold(txn, incident_id)

    event = %{
      "id" => "harness-health-hold:#{incident_id}:#{transition}",
      # Harness-health incidents may have no session owner. They are still
      # global product events; the system namespace keeps them distinct from
      # any user's assignment and wake reactions.
      "org" => after_snapshot["ownerUserId"] || "system",
      "kind" => "harness_health_hold",
      "at" => at,
      "generation" => incident_id <> ":" <> transition,
      "source" => %{"kind" => "harness_health_incident", "id" => incident_id},
      "transition" => transition,
      "resolutionCorrelation" => after_snapshot["resolutionCorrelation"],
      "cycleRelease" => transition == "resolved" and cycle_release == true,
      "principal" => %{"kind" => "process", "id" => "tightbeam"},
      "before" => before,
      "after" => after_snapshot
    }

    admit(txn, event)
    RecoverySchedule.reconcile_hold_in_txn(txn, after_snapshot, event["id"], at)
    :ok
  end

  @doc false
  def remember_harness_health_recovery_check_in_txn(txn, check) do
    Cutover.adopt(txn)

    event = %{
      "id" => check.event_id,
      "org" => check.org,
      "kind" => "harness_health_recovery_check",
      "at" => check.finished_at,
      "generation" => check.cycle_id,
      "source" => %{"kind" => "harness_health_recovery_check", "id" => check.event_id},
      "holdId" => check.hold_id,
      "cycleId" => check.cycle_id,
      "route" => check.route,
      "startedAt" => check.started_at,
      "finishedAt" => check.finished_at,
      "outcome" => check.outcome,
      "errorExcerpt" => check.error_excerpt,
      "principal" => %{"kind" => "process", "id" => "tightbeam"},
      "before" => nil,
      "after" => nil
    }

    facts = Snapshot.current(txn, event, %{})
    Store.remember(txn, event, facts)
    :ok
  end

  def terminal_in_txn(txn, terminal, before) do
    Cutover.adopt(txn)
    id = "assignment:" <> terminal.source_kind <> ":" <> terminal.source_token

    event = %{
      "id" => id,
      "org" => terminal.owner_user_id,
      "kind" => "assignment",
      "at" => terminal.terminal_at,
      "generation" => terminal.source_token,
      "source" => %{"kind" => terminal.source_kind, "id" => terminal.source_token},
      "terminal" => stringify(terminal),
      "before" => before,
      "after" => Snapshot.assignment(txn, terminal.assignment_id)
    }

    event = Map.put(event, "principal", principal(event["after"]))

    actions =
      cond do
        is_map(before) and before["state"] == "open" ->
          admit(txn, event)

        true ->
          # Read-only replay may refer to an adopted occurrence whose ledger
          # key predates this event adapter. It must never admit a new action.
          Txn.q(
            txn,
            """
            SELECT eventId FROM row_reaction_events
            WHERE org=?1 AND json_extract(event,'$.kind')='assignment'
              AND json_extract(event,'$.source.kind')=?2 AND json_extract(event,'$.source.id')=?3
            """,
            [event["org"], terminal.source_kind, terminal.source_token]
          )
          |> Enum.flat_map(fn [id] -> Store.actions(txn, event["org"], id) end)
      end

    case Enum.find(actions, &get_in(&1, ["result", "wake_id"])) do
      nil ->
        {:ok, nil}

      action ->
        {recorded, _} = Store.event(txn, event["org"], action["plan"]["source_event_id"])

        if recorded["terminal"] == event["terminal"] do
          Notice.replay_in_txn(txn, action)
        else
          {:error,
           %{
             code: "terminal_notification_conflict",
             message: "terminal source differs from its captured occurrence"
           }}
        end
    end
  end

  # Delivery is the committed source-to-turn relation, including members of a
  # batch. A fired timestamp, queued batch, or failed delivery is not a receipt.
  def delivered_in_txn(txn, wake_id) do
    Cutover.adopt(txn)

    case delivery_event(txn, wake_id) do
      nil -> :ok
      event -> admit(txn, event)
    end

    :ok
  end

  def attest_in_txn(txn, attest, principal) do
    Cutover.adopt(txn)
    event = attest_event(txn, attest, principal)
    admit(txn, event)
    :ok
  end

  @doc false
  def attest_event(txn, attest, principal, owner_user_id_override \\ nil) do
    attest = stringify(attest)
    assignment_id = attest["assignmentId"]
    context = Snapshot.assignment_context(txn, assignment_id)
    assignment = context.assignment
    owner_user_id = owner_user_id_override || context.owner_user_id

    unless is_binary(owner_user_id),
      do: raise(ArgumentError, "attest source has no owning user")

    late_request_id = receipt_request_id(attest)

    event = %{
      "id" => "attest:" <> attest["id"],
      "org" => owner_user_id,
      "kind" => "assignment_attest",
      "at" => attest["ts"],
      "generation" => attest["id"],
      "principal" => attest_principal(attest, principal),
      "source" => %{"kind" => "attest", "id" => attest["id"]},
      "before" => %{"attest" => nil, "assignment" => assignment},
      "after" => %{
        "attest" => attest,
        "assignment" => assignment,
        "inserted" => true,
        "lateRequestId" => late_request_id
      }
    }

    event
  end

  def turn_started_in_txn(txn, seq) do
    Cutover.adopt(txn)

    # An idle-holder dispatch records assignmentId directly on its turn without
    # a wake. Wake-carried turns must match the wake that delivered that turn.
    case Txn.q(
           txn,
           """
           SELECT t.seq,t.sessionKey,t.createdAt,t.startedAt,t.assignmentId,t.wakeId,
                  w.assignmentId,w.sessionKey,w.deliveredTurnSeq,a.holderKey,a.workItemId
           FROM turns t
           LEFT JOIN wakes w ON w.wakeId=t.wakeId
           JOIN assignments a ON a.id=t.assignmentId
           WHERE t.seq=?1 AND t.status='running' AND t.startedAt IS NOT NULL
             AND t.sessionKey=a.holderKey
             AND (t.wakeId IS NULL OR
                  (w.assignmentId=t.assignmentId AND w.sessionKey=t.sessionKey
                   AND w.deliveredTurnSeq=t.seq))
           """,
           [seq]
         ) do
      [
        [
          ^seq,
          session,
          created_at,
          started_at,
          assignment_id,
          wake_id,
          wake_assignment_id,
          wake_session,
          wake_seq,
          holder,
          _work_item_id
        ]
      ]
      when holder == session and
             (is_nil(wake_id) or
                (wake_assignment_id == assignment_id and wake_session == session and
                   wake_seq == seq)) ->
        [[started_count]] =
          Txn.q(
            txn,
            """
            -- Keep this assignment-scoped probe on the assignment index. Without
            -- the pin SQLite may choose turns_session and scan the holder's full
            -- turn history for every assignment-bound start.
            SELECT COUNT(*) FROM turns t INDEXED BY turns_assignment_id
            LEFT JOIN wakes w ON w.wakeId=t.wakeId
            JOIN assignments a ON a.id=t.assignmentId
            WHERE t.assignmentId=?1 AND t.startedAt IS NOT NULL
              AND (t.startedAt<?2 OR (t.startedAt=?2 AND t.seq<=?3))
              AND t.sessionKey=a.holderKey
              AND (t.wakeId IS NULL OR
                   (w.assignmentId=t.assignmentId AND w.sessionKey=t.sessionKey
                    AND w.deliveredTurnSeq=t.seq))
            """,
            [assignment_id, started_at, seq]
          )

        if started_count == 1 do
          assignment = Snapshot.assignment(txn, assignment_id)

          turn = %{
            "seq" => seq,
            "sessionKey" => session,
            "createdAt" => created_at,
            "startedAt" => started_at,
            "assignmentId" => assignment_id,
            "wakeId" => wake_id
          }

          queued_turn = turn |> Map.delete("startedAt") |> Map.put("status", "queued")
          running_turn = Map.put(turn, "status", "running")

          delivery = %{
            "wakeId" => wake_id,
            "assignmentId" => assignment_id,
            "sessionKey" => session,
            "deliveredTurnSeq" => seq
          }

          event = %{
            "id" => "assignment-start:" <> assignment_id,
            "org" => assignment_owner!(txn, assignment),
            "kind" => "assignment_start",
            "at" => started_at,
            "generation" => seq,
            "principal" => %{"kind" => "process", "id" => "tightbeam"},
            "source" => %{"kind" => "turn", "id" => seq},
            "before" => %{"status" => "queued", "turn" => queued_turn, "delivery" => delivery},
            "after" => %{
              "status" => "running",
              "turn" => running_turn,
              "delivery" => delivery,
              "assignment" => assignment
            }
          }

          admit(txn, event)
        end

      _ ->
        :ok
    end

    :ok
  end

  def delivery_event(txn, wake_id) do
    case Txn.q(
           txn,
           """
           SELECT t.seq,t.sessionKey,t.createdAt FROM wakes w JOIN turns t ON t.seq=w.deliveredTurnSeq
           WHERE w.wakeId=?1 AND t.sessionKey=w.sessionKey
           """,
           [wake_id]
         ) do
      [[seq, session, at]] ->
        wake = Snapshot.wake(txn, wake_id)

        %{
          "id" => "wake-delivery:#{wake_id}:#{seq}",
          "org" => wake["ownerUserId"],
          "kind" => "wake_delivery",
          "at" => at,
          "generation" => seq,
          "principal" => %{"kind" => "process", "id" => "tightbeam"},
          "source" => %{"kind" => "turn", "id" => seq},
          "delivery" => %{"turnSeq" => seq, "sessionKey" => session},
          "before" => nil,
          "after" => wake
        }

      [] ->
        nil
    end
  end

  def admit(txn, event) do
    facts =
      event_scope_facts(
        txn,
        event,
        Snapshot.subtree_facts(txn, event, Snapshot.current(txn, event, %{}))
      )
    actions = Store.admit(txn, event, facts)
    Enum.each(actions, &execute_action(txn, event, &1, event["at"]))
    Store.actions(txn, event["org"], event["id"])
  end

  def recover(db) do
    case DB.transaction(db, fn txn ->
           if ready?(txn) do
             Cutover.adopt(txn)
             superseded = Store.resume_unloaded_rail_holds(txn)
             for event <- superseded, do: reconcile_safely(txn, event)
             for {event, _} <- Store.pending_events(txn), do: reconcile_safely(txn, event)
             RecoverySchedule.reconcile_open_holds_in_txn(txn, System.system_time(:millisecond))
           end

           :ok
         end) do
      {:ok, :ok} ->
        RecoveryScheduler.refresh()
        :ok

      {:error, error} ->
        raise error
    end
  end

  def reconcile_recipient_in_txn(txn, recipient, transition \\ nil) do
    for [org, event_id] <-
          Txn.q(
            txn,
            """
            SELECT DISTINCT a.org,a.eventId FROM row_reaction_actions a
            JOIN wakes w ON w.wakeId=json_extract(a.result,'$.wake_id')
            WHERE a.status='pending' AND w.sessionKey=?1
            """,
            [recipient]
          ) do
      {event, _facts} = Store.event(txn, org, event_id)
      reconcile(txn, event, transition)
    end

    :ok
  end

  def reconcile_receipt_in_txn(txn, recipient, receipt) do
    for [org, event_id] <-
          Txn.q(
            txn,
            """
            SELECT DISTINCT a.org,a.eventId FROM row_reaction_actions a
            JOIN row_reaction_events e ON e.org=a.org AND e.eventId=a.eventId
            JOIN wakes w ON w.wakeId=json_extract(a.result,'$.wake_id')
            WHERE a.status='pending' AND w.state='pending' AND w.deliveredTurnSeq IS NULL
              AND (w.sessionKey=?1 OR json_extract(e.facts,'$.terminal_sources[0].openedById')=?1)
              AND json_extract(e.facts,'$.terminal_sources[0].assignmentId')=?2
              AND json_extract(e.facts,'$.terminal_sources[0].sourceKind')=?3
              AND json_extract(e.facts,'$.terminal_sources[0].sourceToken')=?4
            """,
            [recipient, receipt["assignmentId"], receipt["sourceKind"], receipt["sourceToken"]]
          ) do
      {event, _facts} = Store.event(txn, org, event_id)
      reconcile(txn, event)
    end

    :ok
  end

  def reconcile_work_item_in_txn(txn, item_id) do
    for [org, event_id] <-
          Txn.q(
            txn,
            """
            SELECT DISTINCT a.org,a.eventId FROM row_reaction_actions a
            JOIN row_reaction_events e ON e.org=a.org AND e.eventId=a.eventId
            WHERE a.status='pending' AND (json_extract(e.event,'$.terminal.work_item_id')=?1
              OR json_extract(e.event,'$.workItemId')=?1
              OR EXISTS (SELECT 1 FROM json_each(e.facts,'$.terminal_sources') s
                WHERE json_extract(s.value,'$.workItemId')=?1))
            """,
            [item_id]
          ) do
      {event, _facts} = Store.event(txn, org, event_id)
      reconcile(txn, event)
    end

    :ok
  end

  # Shared by direct and batch preparation. An unresolved historical source is
  # held individually. It must not reach either transport or prevent boot.
  def prepare_in_txn(txn, wake_id) do
    if ready?(txn), do: prepare_owned_in_txn(txn, wake_id), else: :ready
  end

  defp ready?(txn), do: Process.get({__MODULE__, txn.conn}, false)

  defp prepare_owned_in_txn(txn, wake_id) do
    case Store.output_event(txn, wake_id) do
      nil ->
        :ready

      {event, _facts} ->
        reconcile_safely(txn, event)

        case Txn.q(
               txn,
               "SELECT status FROM row_reaction_actions WHERE json_extract(result,'$.wake_id')=?1",
               [wake_id]
             ) do
          [[state]] when state in ["held", "canceled"] -> :held
          _ -> :ready
        end
    end
  end

  def reconcile(txn, event, transition \\ nil) do
    at = System.system_time(:millisecond)
    Enum.each(Store.actions(txn, event["org"], event["id"]), &Notice.synchronize(txn, &1, at))
    {_event, original} = Store.event(txn, event["org"], event["id"])

    facts =
      event_scope_facts(
        txn,
        event,
        Snapshot.subtree_facts(txn, event, Snapshot.current(txn, event, original))
      )
      |> Map.put("transition", transition)
      |> Map.put(
        "reaction_actions",
        Enum.map(Store.actions(txn, event["org"], event["id"]), fn action ->
          %{
            "family" => action["plan"]["family"],
            "slot" => action["plan"]["slot"],
            "result" => action["result"]
          }
        end)
      )

    Store.reconcile(txn, event, original, facts, at)
    |> Enum.each(&execute_action(txn, event, &1, at))

    :ok
  end

  defp reconcile_safely(txn, event) do
    checkpoint = Txn.handoff_checkpoint(txn)
    :ok = Txn.exec(txn, "SAVEPOINT terminal_reaction_reconcile")

    try do
      reconcile(txn, event)
      :ok = Txn.exec(txn, "RELEASE terminal_reaction_reconcile")
    rescue
      error in DB.Error ->
        if retryable_recovery_event?(event) do
          rollback_reconciliation!(txn, checkpoint)
          record_recovery_failures(txn, event, Exception.message(error))
          :ok
        else
          # Unknown database shapes and failed writes are defects, not uncertain
          # historical recipients. Do not hide them as a route hold.
          reraise error, __STACKTRACE__
        end

      error ->
        rollback_reconciliation!(txn, checkpoint)

        if retryable_recovery_event?(event) do
          record_recovery_failures(txn, event, Exception.message(error))
        else
          for action <- Store.actions(txn, event["org"], event["id"]),
              action["status"] == "pending",
              do:
                Store.record(
                  txn,
                  action,
                  "held",
                  action["result"],
                  System.system_time(:millisecond),
                  Exception.message(error)
                )
        end
    end
  end

  defp execute_action(txn, event, action, at) do
    if recovery_notice_action?(event, action) do
      execute_recovery_notice_safely(txn, event, action, at)
    else
      Notice.execute(txn, action, at)
    end
  end

  defp execute_recovery_notice_safely(txn, event, action, at) do
    case recovery_notice_checkpoint(txn) do
      {:ok, checkpoint} ->
        execute_recovery_notice_effect(txn, action, at, checkpoint)

      {:error, message} ->
        # No notice effect ran. Action admission predates this attempt, so its
        # pending row remains the durable retry record.
        record_recovery_failure(txn, action, at, message)
        :ok
    end
  end

  defp recovery_notice_checkpoint(txn) do
    try do
      checkpoint = Txn.handoff_checkpoint(txn)
      :ok = Txn.exec(txn, "SAVEPOINT harness_recovery_notice_effect")
      {:ok, checkpoint}
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, inspect({kind, reason})}
    end
  end

  defp execute_recovery_notice_effect(txn, action, at, checkpoint) do
    try do
      Notice.execute(txn, action, at)
      :ok = Txn.exec(txn, "RELEASE harness_recovery_notice_effect")
    rescue
      error ->
        rollback_recovery_notice_effect!(txn, checkpoint)
        record_recovery_failure(txn, action, at, Exception.message(error))

        :ok
    catch
      kind, reason ->
        rollback_recovery_notice_effect!(txn, checkpoint)
        record_recovery_failure(txn, action, at, inspect({kind, reason}))

        :ok
    end
  end

  defp recovery_notice_action?(
         %{"kind" => "harness_health_hold", "transition" => "resolved"} = event,
         %{"plan" => %{"family" => "harness-recovery"}}
       ),
       do: event["cycleRelease"] != true

  defp recovery_notice_action?(_event, _action), do: false

  defp retryable_recovery_event?(
         %{"kind" => "harness_health_hold", "transition" => "resolved"} = event
       ),
       do: event["cycleRelease"] != true

  defp retryable_recovery_event?(_event), do: false

  defp rollback_reconciliation!(txn, checkpoint) do
    :ok = Txn.exec(txn, "ROLLBACK TO terminal_reaction_reconcile")
    :ok = Txn.exec(txn, "RELEASE terminal_reaction_reconcile")
    :ok = Txn.restore_handoffs(txn, checkpoint)
  end

  defp rollback_recovery_notice_effect!(txn, checkpoint) do
    :ok = Txn.exec(txn, "ROLLBACK TO harness_recovery_notice_effect")
    :ok = Txn.exec(txn, "RELEASE harness_recovery_notice_effect")
    :ok = Txn.restore_handoffs(txn, checkpoint)
  end

  defp record_recovery_failures(txn, event, message) do
    at = System.system_time(:millisecond)

    try do
      for action <- Store.actions(txn, event["org"], event["id"]),
          action["status"] == "pending",
          action["plan"]["family"] == "harness-recovery",
          do: record_recovery_failure(txn, action, at, message)
    rescue
      error ->
        Logger.error(
          "harness recovery notice remains pending; failure details could not be queried: #{Exception.message(error)}"
        )
    catch
      kind, reason ->
        Logger.error(
          "harness recovery notice remains pending; failure details could not be queried: #{inspect({kind, reason})}"
        )
    end

    :ok
  end

  defp record_recovery_failure(txn, action, at, message) do
    try do
      Store.record(txn, action, "pending", action["result"], at, message)
    rescue
      error ->
        Logger.error(
          "harness recovery notice remains pending; failure detail could not be recorded: #{Exception.message(error)}"
        )
    catch
      kind, reason ->
        Logger.error(
          "harness recovery notice remains pending; failure detail could not be recorded: #{inspect({kind, reason})}"
        )
    end

    :ok
  end

  defp principal(row) do
    cond do
      row["closedBySession"] -> %{"kind" => "session", "id" => row["closedBySession"]}
      row["closedByUser"] -> %{"kind" => "user", "id" => row["closedByUser"]}
      true -> %{"kind" => "process", "id" => row["closedByProcess"]}
    end
  end

  defp assignment_owner!(txn, assignment) do
    case Snapshot.assignment_context(txn, assignment["id"]).owner_user_id do
      owner when is_binary(owner) -> owner
      _ -> raise ArgumentError, "assignment start source has no owning user"
    end
  end

  defp receipt_request_id(%{"kind" => "verdict", "verdictKind" => verdict})
       when is_binary(verdict) do
    case Regex.run(
           ~r/\Aruling-consumed:(dr_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\z/u,
           verdict,
           capture: :all_but_first
         ) do
      [request_id] -> request_id
      _ -> nil
    end
  end

  defp receipt_request_id(_attest), do: nil

  defp attest_principal(%{"bySession" => session}, _principal) when is_binary(session),
    do: %{"kind" => "session", "id" => session}

  defp attest_principal(%{"byUser" => user}, _principal) when is_binary(user),
    do: %{"kind" => "user", "id" => user}

  defp attest_principal(_attest, {:process, process}),
    do: %{"kind" => "process", "id" => process}

  defp attest_principal(_attest, principal),
    do: raise(ArgumentError, "attest source has unsupported principal: #{inspect(principal)}")

  defp event_scope_facts(txn, event, facts) do
    record_keys =
      case event["kind"] do
        "assignment" ->
          after_row = event["after"] || %{}
          Enum.filter([after_row["openedBySession"], after_row["holderKey"]], &is_binary/1)

        "wake_delivery" ->
          after_row = event["after"] || %{}
          Enum.filter([after_row["creatorSessionKey"]], &is_binary/1)

        _ ->
          []
      end

    record_groups = if record_keys == [], do: [[]], else: [record_keys]

    caller_key =
      if get_in(event, ["principal", "kind"]) == "session",
        do: get_in(event, ["principal", "id"])

    delivery_key = get_in(event, ["delivery", "sessionKey"])

    participant_keys = [caller_key, delivery_key] |> Enum.filter(&is_binary/1) |> Enum.uniq()

    participant_archetypes =
      Enum.map(participant_keys, fn key ->
        case Enum.find(facts["sessions"] || [], &(&1["sessionKey"] == key)) do
          %{"archetype" => archetype} -> archetype
          _ -> nil
        end
      end)

    facts
    |> Map.put("scope_participant_archetypes", participant_archetypes)
    |> Map.put("scope_record_session_groups", record_groups)
    |> put_subtree_facts(txn, event, participant_keys)
  end

  # Subtree rules read who holds which role now and where the work's owner
  # sits in the session tree. They are recomputed at every evaluation,
  # including the re-check before a delayed notice is delivered, and are never
  # stored with the event.
  defp put_subtree_facts(facts, txn, event, participant_keys) do
    if Tightbeam.FeatureFlags.subtree_rules?() do
      main = Tightbeam.Org.personal_session_key(event["org"])
      anchors = active_anchors(txn, main)

      Map.put(facts, Tightbeam.RowReactions.Plan.subtree_facts_key(), %{
        "participants" => participant_keys,
        "role_bindings" => Tightbeam.SubtreeScope.role_bindings(txn),
        "anchors" => anchors,
        "holder_archetypes" =>
          Map.new(anchors, fn {_, anchor} ->
            {anchor["session_key"], anchor["archetype"]}
          end),
        "owner_lineage" =>
          case Tightbeam.SubtreeScope.work_owner(txn, subtree_refs(event)) do
            key when is_binary(key) -> Tightbeam.SubtreeScope.lineage(txn, key)
            _ -> []
          end
      })
    else
      facts
    end
  end

  defp active_anchors(txn, main) do
    Txn.q(
      txn,
      """
      SELECT r.name, s.sessionKey, s.displayName, s.archetype FROM roles r
      JOIN sessions s ON s.sessionKey = r.boundSessionKey
      WHERE s.state = 'active'
      UNION ALL
      SELECT NULL, sessionKey, displayName, archetype FROM sessions
      WHERE sessionKey = ?1 AND state = 'active'
      """,
      [main]
    )
    |> Map.new(fn [role, key, name, archetype] ->
      {role, %{"session_key" => key, "name" => name, "archetype" => archetype}}
    end)
  end

  defp subtree_refs(event) do
    caller =
      if get_in(event, ["principal", "kind"]) == "session",
        do: get_in(event, ["principal", "id"])

    assignment_id =
      case event["kind"] do
        "assignment" ->
          get_in(event, ["terminal", "assignment_id"])

        kind when kind in ["assignment_attest", "assignment_start"] ->
          get_in(event, ["after", "assignment", "id"])

        "wake_delivery" ->
          get_in(event, ["after", "assignmentId"])

        _ ->
          nil
      end

    work_item_id =
      case event["kind"] do
        "work_item_observation" -> event["workItemId"]
        "assignment" -> get_in(event, ["terminal", "work_item_id"])
        _ -> nil
      end

    %{
      assignment_id: assignment_id,
      work_item_id: work_item_id,
      caller: caller || get_in(event, ["delivery", "sessionKey"])
    }
  end

  defp stringify(map),
    do:
      Map.new(map, fn {key, value} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), value}
      end)
end
