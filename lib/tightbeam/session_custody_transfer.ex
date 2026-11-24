defmodule Tightbeam.SessionCustodyTransfer do
  @moduledoc "Operator transfer of current session custody without changing origin records."

  alias Tightbeam.{DB, EventLog, Idempotency, Org, SessionReparent, Wakes, WorkItemSummary}
  alias Tightbeam.DB.Txn

  defmodule Refusal do
    defexception [:code]
  end

  def handle(db, %{principal: {:user, owner}, params: params} = call) do
    source = params[:from_session_key]
    target = params[:to_session_key]
    parent = params[:parent_session_key]
    key = params[:idempotency_key]

    if valid_key?(key) and valid_session?(source) and valid_session?(target) and
         (is_nil(parent) or valid_session?(parent)) do
      case DB.transaction(db, &transfer_in_txn(&1, owner, source, target, parent, key, call)) do
        {:ok, result} -> result
        {:error, %Refusal{code: code}} -> refusal(code)
        {:error, error} -> raise error
      end
    else
      refusal("invalid_message")
    end
  end

  def handle(_db, _call), do: refusal("user_principal_required")

  defp transfer_in_txn(txn, owner, source, target, parent, key, call) do
    fingerprint =
      :crypto.hash(:sha256, JSON.encode!([owner, source, target, parent]))
      |> Base.encode16(case: :lower)

    case Idempotency.custody_result_in_txn(txn, owner, key) do
      %{fingerprint: ^fingerprint, response: response} ->
        response

      nil ->
        transfer_new_in_txn(txn, owner, source, target, parent, key, fingerprint, call)

      _ ->
        refusal("idempotency_conflict")
    end
  end

  defp transfer_new_in_txn(txn, owner, source, target, parent, key, fingerprint, call) do
    if source == target, do: raise(Refusal, code: "no_change")

    active_owner_host!(txn, source, owner)
    target_host = active_owner_host!(txn, target, owner)

    selected = %{
      work_items:
        ids(
          txn,
          "SELECT id FROM work_items WHERE deliveryOwnerSessionKey=?1 AND state='open' ORDER BY createdAt,id",
          [source]
        ),
      holders:
        ids(
          txn,
          "SELECT id FROM assignments WHERE holderKey=?1 AND state='open' ORDER BY openedAt,id",
          [source]
        ),
      openers:
        ids(
          txn,
          "SELECT id FROM assignments WHERE state='open' AND COALESCE(currentOpenerSessionKey,openedBySession)=?1 ORDER BY openedAt,id",
          [source]
        ),
      raisers:
        ids(
          txn,
          "SELECT id FROM decision_requests WHERE COALESCE(currentRaiserSessionKey,raiserSessionKey)=?1 AND status IN ('open','ruled','answered','returned') ORDER BY raisedAt,id",
          [source]
        ),
      expecters:
        ids(
          txn,
          "SELECT id FROM decision_requests WHERE COALESCE(currentExpecterSessionKey,expecterSessionKey)=?1 AND status='open' ORDER BY raisedAt,id",
          [source]
        ),
      disposers:
        ids(
          txn,
          "SELECT id FROM assignment_cannot_proceed WHERE disposerRef=?1 AND state='standing' ORDER BY createdAt,id",
          ["session:" <> source]
        ),
      wakes:
        ids(
          txn,
          "SELECT wakeId FROM wakes WHERE sessionKey=?1 AND targetRole IS NULL AND consumer='prompt' AND reresolve IS NULL AND state='pending' AND deliveredTurnSeq IS NULL ORDER BY createdAt,wakeId",
          [source]
        ),
      handles:
        ids(
          txn,
          "SELECT handle FROM harklight_wake_handles WHERE COALESCE(currentReceiverSessionKey,sessionKey)=?1 ORDER BY createdAt,handle",
          [source]
        ),
      sends:
        ids(
          txn,
          "SELECT opId FROM harklight_send_operations WHERE COALESCE(currentReceiverSessionKey,sessionKey)=?1 ORDER BY createdAt,opId",
          [source]
        )
    }

    if Enum.any?(selected.handles, fn handle ->
         Txn.q(txn, "SELECT host FROM harklight_wake_handles WHERE handle=?1", [handle]) !=
           [[target_host]]
       end) or
         Enum.any?(selected.sends, fn op_id ->
           Txn.q(txn, "SELECT host FROM harklight_send_operations WHERE opId=?1", [op_id]) !=
             [[target_host]]
         end),
       do: raise(Refusal, code: "harklight_receiver_host_mismatch")

    captured =
      ids(
        txn,
        """
        SELECT d.wakeId FROM harklight_wake_deliveries d
        JOIN wakes w ON w.wakeId=d.wakeId
        WHERE w.sessionKey=?1 AND w.state='pending'
        ORDER BY d.handle,d.eventId
        """,
        [source]
      )

    unless Enum.all?(captured, &(&1 in selected.wakes)),
      do: raise(Refusal, code: "captured_wake_not_readdressable")

    # A captured origin delivery cannot be dispatched on a host different from
    # its Harklight handle. Ordinary follower wakes have no such locality.
    if Txn.q(
         txn,
         """
         SELECT 1 FROM harklight_wake_deliveries d
         JOIN harklight_wake_handles h ON h.handle=d.handle AND h.sessionKey=d.sessionKey
         WHERE d.wakeId IN (SELECT wakeId FROM wakes WHERE sessionKey=?1 AND state='pending')
           AND h.host<>?2
         LIMIT 1
         """,
         [source, target_host]
       ) != [],
       do: raise(Refusal, code: "captured_origin_host_mismatch")

    if Txn.q(
         txn,
         """
         SELECT 1 FROM harklight_wake_deliveries source
         JOIN harklight_wake_deliveries target
           ON target.handle=source.handle AND target.eventId=source.eventId
         WHERE source.wakeId IN (SELECT wakeId FROM wakes WHERE sessionKey=?1 AND state='pending')
           AND COALESCE(target.currentRecipientSessionKey,target.sessionKey)=?2
           AND target.wakeId<>source.wakeId
         LIMIT 1
         """,
         [source, target]
       ) != [],
       do: raise(Refusal, code: "captured_delivery_already_addressed")

    before = snapshot(txn, source, selected, captured)
    event = "sct_" <> Tightbeam.Id.uuid4()
    at = System.system_time(:millisecond)

    # A parent correction sees the source's held assignments before custody
    # moves. Both operations share this transaction and its replay key.
    if parent do
      case SessionReparent.apply_in_txn(txn, owner, %{
             session_key: source,
             parent_session_key: parent,
             idempotency_key: "custody:" <> fingerprint
           }) do
        %{ok: false, code: "no_change"} -> :ok
        %{ok: false, code: code} -> raise Refusal, code: code
        _ -> :ok
      end
    end

    update_ids!(
      txn,
      selected.holders,
      "UPDATE assignments SET holderKey=?2 WHERE id=?1 AND holderKey=?3 AND state='open'",
      [target, source]
    )

    Tightbeam.HolderProd.custody_changed_in_txn(txn, selected.holders, at)

    update_ids!(
      txn,
      selected.work_items,
      "UPDATE work_items SET deliveryOwnerSessionKey=?2 WHERE id=?1 AND deliveryOwnerSessionKey=?3 AND state='open'",
      [target, source]
    )

    update_ids!(
      txn,
      selected.openers,
      "UPDATE assignments SET currentOpenerSessionKey=?2 WHERE id=?1 AND COALESCE(currentOpenerSessionKey,openedBySession)=?3 AND state='open'",
      [target, source]
    )

    update_ids!(
      txn,
      selected.raisers,
      "UPDATE decision_requests SET currentRaiserSessionKey=?2,rowVersion=rowVersion+1 WHERE id=?1 AND COALESCE(currentRaiserSessionKey,raiserSessionKey)=?3",
      [target, source]
    )

    update_ids!(
      txn,
      selected.expecters,
      "UPDATE decision_requests SET currentExpecterSessionKey=?2,rowVersion=rowVersion+1 WHERE id=?1 AND COALESCE(currentExpecterSessionKey,expecterSessionKey)=?3",
      [target, source]
    )

    update_ids!(
      txn,
      selected.disposers,
      "UPDATE assignment_cannot_proceed SET disposerRef=?2 WHERE id=?1 AND disposerRef=?3 AND state='standing'",
      ["session:" <> target, "session:" <> source]
    )

    Enum.each(selected.wakes, fn wake_id ->
      wake = Wakes.get_in_txn(txn, wake_id)

      unless wake.state == "canceled" and Tightbeam.HolderProd.own_notice?(wake) do
        case Wakes.readdress_pending_in_txn(txn, wake_id, target) do
          {:ok, _wake} -> :ok
          {:error, reason} -> raise Refusal, code: "wake_readdress_failed:#{inspect(reason)}"
        end
      end
    end)

    update_ids!(
      txn,
      captured,
      "UPDATE harklight_wake_deliveries SET currentRecipientSessionKey=?2 WHERE wakeId=?1 AND COALESCE(currentRecipientSessionKey,sessionKey)=?3",
      [target, source]
    )

    update_ids!(
      txn,
      selected.handles,
      "UPDATE harklight_wake_handles SET currentReceiverSessionKey=?2,updatedAt=?4 WHERE handle=?1 AND COALESCE(currentReceiverSessionKey,sessionKey)=?3",
      [target, source, at]
    )

    update_ids!(
      txn,
      selected.sends,
      "UPDATE harklight_send_operations SET currentReceiverSessionKey=?2,updatedAt=?4 WHERE opId=?1 AND COALESCE(currentReceiverSessionKey,sessionKey)=?3",
      [target, source, at]
    )

    Enum.each(selected.raisers ++ selected.expecters, fn id ->
      Tightbeam.Escalation.publish_wait_source_in_txn(
        txn,
        Tightbeam.Escalation.raw_by_id_in_txn(txn, id)
      )
    end)

    Enum.each(selected.disposers, fn id ->
      [[assignment_id]] =
        Txn.q(txn, "SELECT assignmentId FROM assignment_cannot_proceed WHERE id=?1", [id])

      Tightbeam.WaitLinks.publish_source_change_in_txn(txn, nil, assignment_id)
    end)

    Enum.each(selected.work_items, fn item_id ->
      Wakes.readdress_accountability_notices_in_txn(txn, item_id)
      WorkItemSummary.publish_change_in_txn(txn, item_id, call)
    end)

    after_state = snapshot(txn, source, selected, captured)

    if before == after_state, do: raise(Refusal, code: "no_change")

    response = %{
      "eventId" => event,
      "principal" => "user:" <> owner,
      "fromSessionKey" => source,
      "toSessionKey" => target,
      "parentSessionKey" => parent,
      "before" => before,
      "after" => after_state,
      "appliedAt" => at
    }

    :ok =
      EventLog.lifecycle_in_txn(
        txn,
        "session_custody_transferred",
        event,
        JSON.encode!(%{
          "principal" => response["principal"],
          "fromSessionKey" => source,
          "toSessionKey" => target,
          "parentSessionKey" => parent,
          "key" => key,
          "before" => before,
          "after" => after_state
        })
      )

    :ok = Idempotency.put_custody_in_txn(txn, owner, key, fingerprint, event, response)

    selected.holders
    |> Kernel.++(selected.openers)
    |> Enum.uniq()
    |> Enum.each(fn assignment_id ->
      case Txn.q(txn, "SELECT workItemId FROM assignments WHERE id=?1", [assignment_id]) do
        [[item]] when is_binary(item) -> Wakes.readdress_accountability_notices_in_txn(txn, item)
        _ -> :ok
      end
    end)

    response
  end

  defp snapshot(txn, source, selected, captured) do
    %{
      "currentParent" => Org.current_parent(txn, source),
      "workItems" =>
        rows_for(
          txn,
          "work_items",
          "id,deliveryOwnerSessionKey,createdByUser,createdBySession,state",
          "id",
          selected.work_items
        )
        |> Enum.map(fn row ->
          [[version]] =
            Txn.q(
              txn,
              "SELECT COALESCE((SELECT rowVersion FROM work_item_versions WHERE workItemId=work_items.id),createdAt) FROM work_items WHERE id=?1",
              [row["id"]]
            )

          Map.put(row, "rowVersion", version)
        end),
      "coordinationParents" =>
        Map.new(selected.holders, fn id ->
          {id, SessionReparent.current_coordination_parent(txn, id)}
        end),
      "assignments" =>
        rows_for(
          txn,
          "assignments",
          "id,holderKey,openedBySession,currentOpenerSessionKey,state",
          "id",
          Enum.uniq(selected.holders ++ selected.openers)
        ),
      "decisions" =>
        rows_for(
          txn,
          "decision_requests",
          "id,raiserSessionKey,currentRaiserSessionKey,expecterSessionKey,currentExpecterSessionKey,status,rowVersion",
          "id",
          Enum.uniq(selected.raisers ++ selected.expecters)
        ),
      "cannotProceed" =>
        rows_for(
          txn,
          "assignment_cannot_proceed",
          "id,openerRef,disposerRef,state",
          "id",
          selected.disposers
        ),
      "wakes" =>
        rows_for(
          txn,
          "wakes",
          "wakeId,sessionKey,targetRole,consumer,state,origin,creatorSessionKey",
          "wakeId",
          selected.wakes
        ),
      "capturedDeliveries" =>
        rows_for(
          txn,
          "harklight_wake_deliveries",
          "wakeId,sessionKey,currentRecipientSessionKey,handle,eventId",
          "wakeId",
          captured
        ),
      "harklightHandles" =>
        rows_for(
          txn,
          "harklight_wake_handles",
          "handle,sessionKey,currentReceiverSessionKey,state,host",
          "handle",
          selected.handles
        ),
      "harklightSends" =>
        rows_for(
          txn,
          "harklight_send_operations",
          "opId,sessionKey,currentReceiverSessionKey,state,handle",
          "opId",
          selected.sends
        )
    }
  end

  defp rows_for(txn, table, columns, key, ids) do
    names = columns |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    Enum.map(ids, fn id ->
      case Txn.q(txn, "SELECT #{columns} FROM #{table} WHERE #{key}=?1", [id]) do
        [row] -> Map.new(Enum.zip(names, row))
        _ -> raise Refusal, code: "readback_changed"
      end
    end)
  end

  defp update_ids!(txn, ids, sql, suffix) do
    Enum.each(ids, fn id ->
      Txn.q(txn, sql, [id | suffix])
      if Txn.changes(txn) != 1, do: raise(Refusal, code: "custody_row_changed")
    end)
  end

  defp ids(txn, sql, params), do: Txn.q(txn, sql, params) |> List.flatten()

  defp active_owner_host!(txn, session, owner) do
    case Txn.q(
           txn,
           "SELECT ownerUserId,state,host FROM sessions WHERE sessionKey=?1",
           [session]
         ) do
      [[^owner, "active", host]] -> host
      [[^owner, _state, _host]] -> raise Refusal, code: "session_retired"
      _ -> raise Refusal, code: "not_authorized"
    end
  end

  defp valid_key?(key),
    do: is_binary(key) and String.trim(key) != "" and String.length(key) <= 200

  defp valid_session?(key), do: is_binary(key) and String.trim(key) != ""

  defp refusal(code), do: %{ok: false, code: code, message: code}
end
