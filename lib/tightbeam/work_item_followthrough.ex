defmodule Tightbeam.WorkItemFollowthrough do
  @moduledoc false
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.Store
  alias Tightbeam.{RowReactions, WorkItems}

  def enabled?,
    do:
      Application.get_env(:tightbeam, :work_item_followthrough_enabled, false) and
        Tightbeam.WorkItemWaits.enabled?()

  # Carry the episode through the existing delivery replacement. This is not a
  # second reminder: the only actionable notice remains work_items.slateWakeId.
  def delivery_context(txn, wake_id, item_id) do
    [[session_key]] =
      Txn.q(txn, "SELECT deliveryOwnerSessionKey FROM work_items WHERE id=?1", [item_id])

    prior =
      case Store.output_event(txn, wake_id) do
        {event, _} -> get_in(event, ["sourceAfter", "followThrough"])
        nil -> nil
      end

    case prior do
      %{"ownerSessionKey" => ^session_key} -> prior
      _ -> %{"episodeId" => wake_id, "ownerSessionKey" => session_key, "misses" => 0}
    end
  end

  # An explicit policy can supply exact current session relations. Spawn
  # ancestry and addressed-PO associations are deliberately not consulted.
  def route(txn, item) do
    policy = Tightbeam.Rules.reaction_policy("work-item-followthrough-supervision")
    relations = if policy, do: Map.get(policy.settings, "relations", []), else: []
    owner = item && item["deliveryOwnerSessionKey"]

    candidates =
      relations
      |> Enum.filter(&(is_map(&1) and &1["owner_session_key"] == owner))
      |> Enum.map(& &1["supervisor_session_key"])
      |> Enum.uniq()

    case candidates do
      [key] when is_binary(key) and key != owner ->
        if Txn.q(
             txn,
             "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active'",
             [key, item["ownerUserId"]]
           ) == [[1]],
           do: %{"recipient" => key, "status" => "available", "policy" => policy.name},
           else: %{"recipient" => nil, "status" => "unavailable"}

      [] ->
        %{"recipient" => nil, "status" => "unavailable"}

      _ ->
        %{"recipient" => nil, "status" => "ambiguous"}
    end
  end

  def terminal_in_txn(txn, seq, terminal, work_outcome) do
    if enabled?() and terminal == "delivered" and work_outcome != :did_not_perform do
      # Includes source members of a delivered batch, not merely its carrier.
      for [wake_id, item_id, session_key] <-
            Txn.q(
              txn,
              """
              SELECT w.wakeId,w.work_item_id,t.sessionKey
              FROM wakes w INDEXED BY wakes_delivered_turn
              JOIN turns t ON t.seq=w.deliveredTurnSeq
              WHERE w.deliveredTurnSeq=?1 AND t.status='delivered'
                AND w.sessionKey=t.sessionKey AND w.work_item_id IS NOT NULL
              """,
              [seq]
            ) do
        observe_success(txn, seq, wake_id, item_id, session_key)
      end
    end

    :ok
  end

  defp observe_success(txn, seq, wake_id, item_id, session_key) do
    # Delivery reconciliation can arrive after the terminal callback. Admit its
    # existing replacement first; pointer matching makes this replay-safe.
    if Txn.q(txn, "SELECT 1 FROM work_items WHERE id=?1 AND slateWakeId=?2", [item_id, wake_id]) ==
         [[1]] do
      WorkItems.rearm_on_fire_in_txn(txn, wake_id, %{work_item_id: item_id})
    end

    with [["open", ^session_key, current, 0]] <-
           Txn.q(
             txn,
             """
             SELECT state,deliveryOwnerSessionKey,slateWakeId,
               (SELECT COUNT(*) FROM assignments WHERE workItemId=wi.id AND state='open')
             FROM work_items wi WHERE id=?1
             """,
             [item_id]
           ),
         true <- is_binary(current),
         false <- Tightbeam.WorkItemWaits.active_in_txn?(txn, item_id),
         [[1]] <-
           Txn.q(
             txn,
             "SELECT 1 FROM wakes WHERE wakeId=?1 AND state='pending' AND deliveredTurnSeq IS NULL",
             [current]
           ),
         {event, _} <- Store.output_event(txn, current),
         "delivered" <- event["operation"],
         ^wake_id <- get_in(event, ["before", "deliveredWakeId"]),
         %{"ownerSessionKey" => ^session_key} = context <-
           get_in(event, ["sourceAfter", "followThrough"]) do
      [[ended_at]] = Txn.q(txn, "SELECT endedAt FROM turns WHERE seq=?1", [seq])
      context = Map.update!(context, "misses", &(&1 + 1))

      RowReactions.observe_work_item_in_txn(
        txn,
        item_id,
        "owner_turn_completed",
        %{
          kind: "turn",
          id: seq,
          generation: "#{seq}:#{wake_id}",
          principal: {:process, "tightbeam"},
          at: ended_at,
          after: %{"followThrough" => context}
        },
        %{"deliveredWakeId" => wake_id, "replacementWakeId" => current}
      )
    else
      _ -> :ok
    end
  end
end
