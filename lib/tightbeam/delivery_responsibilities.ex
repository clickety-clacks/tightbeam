defmodule Tightbeam.DeliveryResponsibilities do
  @moduledoc """
  Read and check the explicit delivery owner stored on each work item.

  Historical scope and delegation rows remain untouched as evidence. They are
  not read to decide current ownership or staffing.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @legacy_operations ~w(
    work-item-delivery-scope-set
    delivery-scope-owner-set
    delivery-responsibility-get
  )

  @doc false
  def ensure_schema(_db), do: :ok

  @doc false
  def handle(_db, %{verb: verb}) when verb in @legacy_operations do
    refusal(
      "delivery_operation_retired",
      "#{verb} used the retired scope/delegation ledger; use work-item-get and the existing work-item-update --delivery-owner path"
    )
  end

  def handle(_db, _call),
    do: refusal("unknown_operation", "unsupported delivery responsibility operation")

  @doc "Return the explicit current owner link for an exact work item."
  def current_owner(db \\ DB, work_item_id) when is_binary(work_item_id) do
    case DB.query(db, owner_sql(), [work_item_id]) do
      {:ok, [row]} -> owner(row, work_item_id)
      {:ok, []} -> nil
    end
  end

  @doc false
  def current_owner_in_txn(%Txn{}, nil), do: nil

  @doc false
  def current_owner_in_txn(%Txn{} = txn, work_item_id) when is_binary(work_item_id) do
    case Txn.q(txn, owner_sql(), [work_item_id]) do
      [row] -> owner(row, work_item_id)
      [] -> nil
    end
  end

  @doc false
  def current_accountable_recipient_in_txn(
        %Txn{} = txn,
        work_item_id,
        owner_user_id
      )
      when is_binary(work_item_id) and is_binary(owner_user_id) do
    case current_owner_in_txn(txn, work_item_id) do
      %{
        "ownerUserId" => ^owner_user_id,
        "accountableSessionKey" => session_key,
        "deliveryState" => "current"
      } ->
        session_key

      _ ->
        nil
    end
  end

  def current_accountable_recipient_in_txn(%Txn{}, _work_item_id, _owner_user_id), do: nil

  @doc false
  def legacy_owner_link_backfill_in_txn(%Txn{} = txn) do
    case legacy_owner_history_table_count_in_txn(txn) do
      0 ->
        {:ok, []}

      2 ->
        backfill_legacy_owner_links_in_txn(txn)

      count ->
        {:error, {:incomplete_legacy_owner_history, count}}
    end
  end

  defp backfill_legacy_owner_links_in_txn(txn) do
    txn
    |> Txn.q("SELECT id FROM work_items ORDER BY id")
    |> Enum.reduce_while({:ok, []}, fn [work_item_id], {:ok, backfill} ->
      case legacy_current_owner_in_txn(txn, work_item_id) do
        nil ->
          {:cont, {:ok, backfill}}

        %{"accountableSessionKey" => session_key, "deliveryState" => state}
        when state in ["current", "unavailable"] ->
          {:cont, {:ok, [{work_item_id, session_key} | backfill]}}

        %{"accountableSessionKey" => session_key, "deliveryState" => state} ->
          {:halt, {:error, %{work_item_id: work_item_id, session_key: session_key, state: state}}}

        _ ->
          {:halt,
           {:error, %{work_item_id: work_item_id, session_key: nil, state: "contradictory"}}}
      end
    end)
    |> case do
      {:ok, backfill} -> {:ok, Enum.reverse(backfill)}
      error -> error
    end
  end

  @doc false
  def check_staffing_owner_in_txn(%Txn{} = txn, call, opts \\ []) do
    opts = Keyword.put(opts, :txn, txn)
    params = Map.get(call, :params, %{})

    with :ok <- retired_delegation(params) do
      cond do
        internal_spawn_remedy?(call, opts) ->
          validate_internal_spawn_references(txn, params)

        ownerless_work_item_intake_assignment?(txn, call, params) ->
          :ok

        production_staffing_operation?(call, opts) and
            not itemless_non_owner_link_control?(call) ->
          work_item_id = Map.get(params, :work_item_id)

          with :ok <- validate_supplied_owner_reference(params),
               :ok <- required_work_item(work_item_id),
               :ok <- known_work_item(txn, work_item_id),
               {:ok, owner} <- owner_for_staffing(txn, work_item_id, call, opts),
               :ok <- supplied_owner_matches(params, owner, work_item_id),
               :ok <- owner_available(owner, work_item_id, call, opts) do
            :ok
          else
            %{code: _} = error -> error
            {:error, code, message} -> refusal(code, message)
          end

        true ->
          :ok
      end
    end
  end

  defp internal_spawn_remedy?(
         %{verb: "spawn", principal: {:remedy, %{action: "spawn", owner: owner}}},
         opts
       )
       when is_binary(owner),
       do: owner == Keyword.get(opts, :owner_user_id)

  defp internal_spawn_remedy?(_call, _opts), do: false

  defp validate_internal_spawn_references(txn, params) do
    work_item_id = Map.get(params, :work_item_id)

    with :ok <- validate_supplied_owner_reference(params) do
      cond do
        is_nil(work_item_id) and supplied_owner_references(params) == [] ->
          :ok

        is_nil(work_item_id) ->
          supplied_owner_matches(params, nil, nil)

        is_binary(work_item_id) ->
          with :ok <- known_work_item(txn, work_item_id),
               {:ok, owner} <- owner_for_staffing(txn, work_item_id, %{}, []),
               :ok <- supplied_owner_matches(params, owner, work_item_id) do
            :ok
          end

        true ->
          required_work_item(work_item_id)
      end
    end
  end

  @doc false
  def responsibility(db \\ DB, session_key, work_item_id)

  def responsibility(%Txn{} = txn, session_key, work_item_id)
      when is_binary(session_key) and is_binary(work_item_id),
      do: responsibility_in_txn(txn, session_key, work_item_id)

  def responsibility(db, session_key, work_item_id)
      when is_binary(session_key) and is_binary(work_item_id) do
    case DB.transaction(db, &responsibility_in_txn(&1, session_key, work_item_id)) do
      {:ok, value} -> value
      {:error, _error} -> "none"
    end
  end

  @doc false
  def responsibility_in_txn(%Txn{} = txn, session_key, work_item_id) do
    case current_owner_in_txn(txn, work_item_id) do
      %{"accountableSessionKey" => ^session_key, "deliveryState" => "current"} ->
        "accountable"

      %{"accountableSessionKey" => ^session_key} ->
        "stale"

      _ ->
        if active_assignment_holder?(txn, session_key, work_item_id),
          do: "delegated",
          else: "none"
    end
  end

  defp owner_sql do
    """
    SELECT w.deliveryOwnerSessionKey,w.ownerUserId,s.state
    FROM work_items w
    LEFT JOIN sessions s ON s.sessionKey=w.deliveryOwnerSessionKey
    WHERE w.id=?1
    """
  end

  defp owner([nil, _human_owner, _state], _work_item_id), do: nil

  defp owner([session_key, human_owner, "active"], work_item_id) do
    %{
      "workItemId" => work_item_id,
      "ownerUserId" => human_owner,
      "accountableSessionKey" => session_key,
      "deliveryState" => "current"
    }
  end

  defp owner([session_key, human_owner, _state], work_item_id) do
    %{
      "workItemId" => work_item_id,
      "ownerUserId" => human_owner,
      "accountableSessionKey" => session_key,
      "deliveryState" => "unavailable"
    }
  end

  defp known_work_item(txn, work_item_id) do
    case Txn.q(txn, "SELECT 1 FROM work_items WHERE id=?1", [work_item_id]) do
      [[1]] ->
        :ok

      [] ->
        refusal(
          "unknown_work_item",
          "work item #{work_item_id} does not exist; correct the item reference or create/link the item before staffing"
        )
    end
  end

  defp required_work_item(work_item_id) when is_binary(work_item_id), do: :ok

  defp required_work_item(_work_item_id),
    do:
      refusal(
        "work_item_required",
        "production staffing requires an exact work item; create or link the item before staffing"
      )

  defp owner_for_staffing(txn, work_item_id, _call, _opts),
    do: {:ok, current_owner_in_txn(txn, work_item_id)}

  defp validate_supplied_owner_reference(params) do
    references = supplied_owner_references(params)

    if Enum.all?(references, &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else:
        refusal(
          "invalid_delivery_owner_reference",
          "delivery owner references must be non-blank session keys or session:<key> values"
        )
  end

  defp supplied_owner_matches(params, owner, work_item_id) do
    references =
      params
      |> supplied_owner_references()
      |> Enum.map(fn
        "session:" <> session_key -> session_key
        value -> value
      end)

    cond do
      references == [] ->
        :ok

      is_nil(work_item_id) ->
        refusal(
          "delivery_owner_reference_requires_work_item",
          "a delivery owner reference can only be supplied with its work item"
        )

      is_nil(owner) ->
        refusal(
          "delivery_owner_missing",
          "work item #{work_item_id} has no recorded delivery owner; its human owner/admin or active Main must set one with work-item-update --delivery-owner before production staffing"
        )

      Enum.any?(references, &(&1 != owner["accountableSessionKey"])) ->
        expected = owner["accountableSessionKey"]
        supplied = Enum.map_join(references, ", ", &"session:#{&1}")

        refusal(
          "delivery_owner_mismatch",
          "work item #{work_item_id} records delivery owner session:#{expected}, not #{supplied}; retry with the recorded owner or update the item through its authorized owner/admin"
        )

      true ->
        :ok
    end
  end

  defp supplied_owner_references(params) do
    for key <- [:delivery_owner_session_key, :delivery_owner_ref],
        Map.has_key?(params, key),
        do: Map.get(params, key)
  end

  defp owner_available(nil, work_item_id, _call, _opts) do
    refusal(
      "delivery_owner_missing",
      "work item #{work_item_id} has no recorded delivery owner; its human owner/admin or active Main must set one with work-item-update --delivery-owner before production staffing"
    )
  end

  defp owner_available(
         %{"accountableSessionKey" => owner, "deliveryState" => "current"},
         work_item_id,
         call,
         opts
       ) do
    if caller_is_responsible?(owner, work_item_id, call, opts) do
      :ok
    else
      refusal(
        "delivery_owner_required",
        "work item #{work_item_id} is owned by session:#{owner}; production staffing must come from that owner or an active holder of an open assignment on this exact item"
      )
    end
  end

  defp owner_available(%{"accountableSessionKey" => owner}, work_item_id, _call, _opts) do
    refusal(
      "delivery_owner_unavailable",
      "work item #{work_item_id} records delivery owner session:#{owner}, but that session is unavailable; its human owner/admin should replace the link with work-item-update --delivery-owner before production staffing"
    )
  end

  defp retired_delegation(%{delegates_delivery: true}),
    do:
      refusal(
        "delivery_delegation_retired",
        "delegatesDelivery no longer grants staffing authority; use the recorded work-item owner and existing assignment custody"
      )

  defp retired_delegation(%{delegates_delivery: value}) when not is_boolean(value),
    do: refusal("invalid_delegates_delivery", "delegatesDelivery must be a boolean when supplied")

  defp retired_delegation(_params), do: :ok

  defp production_staffing_operation?(call, opts) do
    case call.verb do
      "spawn" ->
        true

      verb when verb in ["assign", "dispatch"] ->
        not linked_review?(call, opts)

      _ ->
        false
    end
  end

  # Preserve authenticated intake and continued assignment custody for unlinked
  # items. A raw item or a canceled/mismatched routing wake is not that path.
  defp ownerless_work_item_intake_assignment?(txn, %{verb: verb} = call, params)
       when verb in ["assign", "dispatch"] and is_map(params) do
    work_item_id = Map.get(params, :work_item_id)
    owner_user_id = ownerless_intake_principal_user(txn, call)

    is_binary(work_item_id) and is_binary(owner_user_id) and
      supplied_owner_references(params) == [] and
      Txn.q(
        txn,
        """
        SELECT 1 FROM work_items wi
        WHERE wi.id=?1 AND wi.state='open' AND wi.ownerUserId=?2
          AND wi.deliveryOwnerSessionKey IS NULL
          AND (
            EXISTS (
              SELECT 1 FROM wakes w
              WHERE w.wakeId=wi.routingWakeId AND w.work_item_id=wi.id
                AND w.origin='process:tightbeam' AND w.consumer='prompt'
                AND w.sessionKey=?3 AND w.state IN ('pending','fired')
            ) OR EXISTS (
              SELECT 1 FROM assignments a WHERE a.workItemId=wi.id
            )
          )
        LIMIT 1
        """,
        [work_item_id, owner_user_id, Tightbeam.Org.personal_session_key(owner_user_id)]
      ) == [[1]]
  end

  defp ownerless_work_item_intake_assignment?(_txn, _call, _params), do: false

  defp ownerless_intake_principal_user(txn, call) do
    case Map.get(call, :principal) do
      {:user, user_id} when is_binary(user_id) ->
        user_id

      {:session, session_key} when is_binary(session_key) ->
        case Txn.q(
               txn,
               "SELECT ownerUserId FROM sessions WHERE sessionKey=?1 AND state='active' LIMIT 1",
               [session_key]
             ) do
          [[user_id]] when is_binary(user_id) -> user_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Existing itemless human assignment, dispatch, and spawn coordination stay
  # on their established paths. The typed internal spawn remedy is handled first
  # above and still validates its owner references.
  defp itemless_non_owner_link_control?(call) do
    itemless_human_assignment_control?(call) or
      itemless_public_dispatch_control?(call) or itemless_public_spawn_control?(call)
  end

  defp itemless_human_assignment_control?(%{
         verb: "assign",
         principal: {kind, _principal},
         params: params
       })
       when kind in [:user, :session] and is_map(params),
       do: is_nil(Map.get(params, :work_item_id))

  defp itemless_human_assignment_control?(_call), do: false

  defp itemless_public_dispatch_control?(%{
         verb: "dispatch",
         principal: {kind, _principal},
         params: params
       })
       when kind in [:user, :session] and is_map(params),
       do: is_nil(Map.get(params, :work_item_id))

  defp itemless_public_dispatch_control?(_call), do: false

  defp itemless_public_spawn_control?(%{verb: "spawn", origin: origin, params: params})
       when is_binary(origin) and is_map(params),
       do:
         is_nil(Map.get(params, :work_item_id)) and
           (String.starts_with?(origin, "user:") or String.starts_with?(origin, "agent:"))

  defp itemless_public_spawn_control?(_call), do: false

  defp linked_review?(call, opts) do
    work_item_id = call.params[:work_item_id]
    review_id = call.params[:reviews_assignment_id]
    txn = Keyword.get(opts, :txn)

    is_struct(txn, Txn) and is_binary(review_id) and
      (is_binary(work_item_id) or is_nil(work_item_id)) and
      Txn.q(
        txn,
        """
        SELECT 1 FROM assignments
        WHERE id=?1 AND (workItemId=?2 OR (workItemId IS NULL AND ?2 IS NULL))
          AND reviewsAssignmentId IS NULL
        """,
        [review_id, work_item_id]
      ) == [[1]]
  end

  defp active_assignment_holder?(txn, session_key, work_item_id) do
    Txn.q(
      txn,
      "SELECT 1 FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey WHERE a.workItemId=?1 AND a.holderKey=?2 AND a.state='open' AND s.state='active' LIMIT 1",
      [work_item_id, session_key]
    ) == [[1]]
  end

  defp caller_is_responsible?(owner, work_item_id, call, opts) do
    case Map.get(call, :principal) do
      {:user, _user_id} ->
        true

      {:remedy, %{action: "assign", owner: user_id}} when call.verb == "assign" ->
        txn = Keyword.fetch!(opts, :txn)

        Txn.q(txn, "SELECT 1 FROM work_items WHERE id=?1 AND ownerUserId=?2", [
          work_item_id,
          user_id
        ]) == [[1]]

      {:session, ^owner} ->
        true

      {:session, session_key} when is_binary(session_key) ->
        txn = Keyword.fetch!(opts, :txn)

        active_assignment_holder?(txn, session_key, work_item_id)

      _ ->
        false
    end
  end

  # Legacy scope events are consulted only for the exact stamped backfill.
  defp legacy_owner_history_table_count_in_txn(txn) do
    case Txn.q(
           txn,
           "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('work_item_delivery_scope_events','delivery_scope_owner_events')"
         ) do
      [[count]] -> count
      rows -> raise "invalid legacy owner-history table-count result: #{inspect(rows)}"
    end
  end

  defp legacy_current_owner_in_txn(txn, work_item_id) do
    case Txn.q(
           txn,
           """
           SELECT b.ownerUserId,b.poRole,o.accountableSessionKey,o.associationRevision
           FROM work_item_delivery_scope_events b
           JOIN (
             SELECT workItemId,MAX(eventSeq) AS eventSeq
             FROM work_item_delivery_scope_events GROUP BY workItemId
           ) latest_binding
             ON latest_binding.workItemId=b.workItemId
            AND latest_binding.eventSeq=b.eventSeq
           JOIN delivery_scope_owner_events o
             ON o.ownerUserId=b.ownerUserId AND o.poRole=b.poRole
           JOIN (
             SELECT ownerUserId,poRole,MAX(eventSeq) AS eventSeq
             FROM delivery_scope_owner_events GROUP BY ownerUserId,poRole
           ) latest_owner
             ON latest_owner.ownerUserId=o.ownerUserId
            AND latest_owner.poRole=o.poRole
            AND latest_owner.eventSeq=o.eventSeq
           WHERE b.workItemId=?1
           """,
           [work_item_id]
         ) do
      [[owner_user_id, po_role, session_key, association_revision]] ->
        %{
          "ownerUserId" => owner_user_id,
          "poRole" => po_role,
          "accountableSessionKey" => session_key,
          "deliveryState" =>
            legacy_owner_state(
              txn,
              owner_user_id,
              po_role,
              session_key,
              association_revision
            )
        }

      [] ->
        nil

      _ ->
        %{"deliveryState" => "contradictory"}
    end
  end

  defp legacy_owner_state(txn, owner, po_role, session, association_revision) do
    case Txn.q(
           txn,
           """
           SELECT s.state,a.ownerUserId,a.poRole,a.revision
           FROM sessions s
           LEFT JOIN session_po_associations a ON a.sessionKey=s.sessionKey
           WHERE s.sessionKey=?1
           """,
           [session]
         ) do
      [["retired", _association_owner, _association_role, _revision]] ->
        "unavailable"

      [["active", ^owner, ^po_role, ^association_revision]] ->
        if legacy_active_role_office?(txn, owner, po_role), do: "current", else: "stale"

      _ ->
        "stale"
    end
  end

  defp legacy_active_role_office?(txn, owner, po_role) do
    case Txn.q(txn, "SELECT ownerUserId,boundSessionKey FROM roles WHERE name=?1", [po_role]) do
      [[^owner, bound_session]] ->
        office = bound_session || Tightbeam.Org.personal_session_key(owner)

        Txn.q(
          txn,
          "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active'",
          [office, owner]
        ) == [[1]]

      _ ->
        false
    end
  end

  defp refusal(code, message), do: %{code: code, message: message}
end
