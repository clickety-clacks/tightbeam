defmodule Tightbeam.RowReactions do
  @moduledoc false
  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.{Cutover, Notice, Snapshot, Store}

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
    facts = Snapshot.current(txn, event, %{})
    actions = Store.admit(txn, event, facts)
    Enum.each(actions, &Notice.execute(txn, &1, event["at"]))
    Store.actions(txn, event["org"], event["id"])
  end

  def recover(db) do
    case DB.transaction(db, fn txn ->
           if ready?(txn) do
             Cutover.adopt(txn)
             for {event, _} <- Store.pending_events(txn), do: reconcile_safely(txn, event)
           end

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
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
            WHERE a.status='pending' AND w.state='pending' AND w.deliveredTurnSeq IS NULL AND w.sessionKey=?1
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
      Snapshot.current(txn, event, original)
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
    |> Enum.each(&Notice.execute(txn, &1, at))

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
        # Unknown database shapes and failed writes are defects, not uncertain
        # historical recipients. Do not hide them as a route hold.
        reraise error, __STACKTRACE__

      error ->
        :ok = Txn.exec(txn, "ROLLBACK TO terminal_reaction_reconcile")
        :ok = Txn.exec(txn, "RELEASE terminal_reaction_reconcile")
        :ok = Txn.restore_handoffs(txn, checkpoint)

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

  defp stringify(map),
    do:
      Map.new(map, fn {key, value} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), value}
      end)
end
