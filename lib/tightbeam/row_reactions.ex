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

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
