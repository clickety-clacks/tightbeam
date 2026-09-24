defmodule Tightbeam.DeliveryResponsibilities do
  @moduledoc """
  Explicit delivery scopes, accountable-owner succession, and assignment grants.

  A scope is the canonical registered PO office `(ownerUserId, poRole)`. Work
  items enter a scope only through an explicit binding event. The latest owner
  event for that scope is the single accountable delivery owner for every bound
  item. Assignment grants are exact-item capabilities tied to both the binding
  and owner revisions that admitted them; succession therefore withdraws old
  grants from future commissioning without rewriting assignment custody or
  historical authorship.

  No relation is inferred from role spelling, archetype, display name, session
  ancestry, shared user ownership, or the mere presence of a PO association.
  """

  alias Tightbeam.{DB, Id, Org}
  alias Tightbeam.DB.Txn

  @scope_operation "work-item-delivery-scope-set"
  @owner_operation "delivery-scope-owner-set"

  @ddl """
  CREATE TABLE IF NOT EXISTS delivery_responsibility_requests (
    requestSeq INTEGER PRIMARY KEY AUTOINCREMENT,
    ownerUserId TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('work-item-delivery-scope-set','delivery-scope-owner-set')),
    idempotencyKey TEXT NOT NULL,
    subjectRef TEXT NOT NULL,
    requestFingerprint TEXT NOT NULL,
    canonicalResponse TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    UNIQUE(ownerUserId,operation,idempotencyKey),
    CHECK (length(trim(subjectRef)) > 0)
  );
  CREATE TRIGGER IF NOT EXISTS delivery_responsibility_requests_no_update
  BEFORE UPDATE ON delivery_responsibility_requests
  BEGIN SELECT RAISE(ABORT,'delivery_responsibility_requests is immutable'); END;
  CREATE TRIGGER IF NOT EXISTS delivery_responsibility_requests_no_delete
  BEFORE DELETE ON delivery_responsibility_requests
  BEGIN SELECT RAISE(ABORT,'delivery_responsibility_requests is immutable'); END;

  CREATE TABLE IF NOT EXISTS work_item_delivery_scope_events (
    eventSeq INTEGER PRIMARY KEY AUTOINCREMENT,
    eventId TEXT NOT NULL UNIQUE,
    workItemId TEXT NOT NULL REFERENCES work_items(id),
    bindingRevision INTEGER NOT NULL CHECK (bindingRevision >= 1),
    ownerUserId TEXT NOT NULL,
    poRole TEXT NOT NULL,
    associationSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    associationRevision INTEGER NOT NULL CHECK (associationRevision >= 1),
    previousOwnerUserId TEXT,
    previousPoRole TEXT,
    setByKind TEXT NOT NULL CHECK (setByKind IN ('user','session')),
    setByRef TEXT NOT NULL,
    cause TEXT NOT NULL CHECK (cause IN ('initial','reassigned')),
    createdAt INTEGER NOT NULL,
    UNIQUE(workItemId,bindingRevision),
    CHECK (length(trim(poRole)) > 0),
    CHECK (length(trim(setByRef)) > 0),
    CHECK ((bindingRevision=1 AND previousOwnerUserId IS NULL AND previousPoRole IS NULL) OR
           (bindingRevision>1 AND previousOwnerUserId IS NOT NULL AND previousPoRole IS NOT NULL))
  );
  CREATE INDEX IF NOT EXISTS work_item_delivery_scope_current
    ON work_item_delivery_scope_events(workItemId,eventSeq DESC);
  CREATE INDEX IF NOT EXISTS work_item_delivery_scope_office
    ON work_item_delivery_scope_events(ownerUserId,poRole,eventSeq DESC);
  CREATE TRIGGER IF NOT EXISTS work_item_delivery_scope_events_no_update
  BEFORE UPDATE ON work_item_delivery_scope_events
  BEGIN SELECT RAISE(ABORT,'work_item_delivery_scope_events is append-only'); END;
  CREATE TRIGGER IF NOT EXISTS work_item_delivery_scope_events_no_delete
  BEFORE DELETE ON work_item_delivery_scope_events
  BEGIN SELECT RAISE(ABORT,'work_item_delivery_scope_events is append-only'); END;

  CREATE TABLE IF NOT EXISTS delivery_scope_owner_events (
    eventSeq INTEGER PRIMARY KEY AUTOINCREMENT,
    eventId TEXT NOT NULL UNIQUE,
    ownerUserId TEXT NOT NULL,
    poRole TEXT NOT NULL,
    ownerRevision INTEGER NOT NULL CHECK (ownerRevision >= 1),
    previousSessionKey TEXT REFERENCES sessions(sessionKey),
    accountableSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    associationRevision INTEGER NOT NULL CHECK (associationRevision >= 1),
    expectedOwnerRevision INTEGER NOT NULL CHECK (expectedOwnerRevision >= 0),
    expectedSessionKey TEXT REFERENCES sessions(sessionKey),
    setByKind TEXT NOT NULL CHECK (setByKind IN ('user','session')),
    setByRef TEXT NOT NULL,
    cause TEXT NOT NULL CHECK (cause IN ('initial','transfer','recovery')),
    createdAt INTEGER NOT NULL,
    UNIQUE(ownerUserId,poRole,ownerRevision),
    CHECK (length(trim(poRole)) > 0),
    CHECK (length(trim(setByRef)) > 0),
    CHECK ((ownerRevision=1 AND previousSessionKey IS NULL AND expectedSessionKey IS NULL AND expectedOwnerRevision=0) OR
           (ownerRevision>1 AND previousSessionKey IS NOT NULL AND expectedSessionKey=previousSessionKey AND expectedOwnerRevision=ownerRevision-1))
  );
  CREATE INDEX IF NOT EXISTS delivery_scope_owner_current
    ON delivery_scope_owner_events(ownerUserId,poRole,eventSeq DESC);
  CREATE TRIGGER IF NOT EXISTS delivery_scope_owner_events_no_update
  BEFORE UPDATE ON delivery_scope_owner_events
  BEGIN SELECT RAISE(ABORT,'delivery_scope_owner_events is append-only'); END;
  CREATE TRIGGER IF NOT EXISTS delivery_scope_owner_events_no_delete
  BEFORE DELETE ON delivery_scope_owner_events
  BEGIN SELECT RAISE(ABORT,'delivery_scope_owner_events is append-only'); END;

  CREATE TABLE IF NOT EXISTS assignment_delivery_delegations (
    assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
    workItemId TEXT NOT NULL REFERENCES work_items(id),
    holderSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    ownerUserId TEXT NOT NULL,
    poRole TEXT NOT NULL,
    scopeBindingEventId TEXT NOT NULL REFERENCES work_item_delivery_scope_events(eventId),
    scopeBindingRevision INTEGER NOT NULL CHECK (scopeBindingRevision >= 1),
    ownerEventId TEXT NOT NULL REFERENCES delivery_scope_owner_events(eventId),
    ownerRevision INTEGER NOT NULL CHECK (ownerRevision >= 1),
    holderAssociationRevision INTEGER NOT NULL CHECK (holderAssociationRevision >= 1),
    delegatedByKind TEXT NOT NULL CHECK (delegatedByKind = 'session'),
    delegatedByRef TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    CHECK (length(trim(poRole)) > 0),
    CHECK (substr(delegatedByRef,1,8)='session:')
  );
  CREATE INDEX IF NOT EXISTS assignment_delivery_delegations_item
    ON assignment_delivery_delegations(workItemId,assignmentId);
  CREATE INDEX IF NOT EXISTS assignment_delivery_delegations_holder
    ON assignment_delivery_delegations(holderSessionKey,workItemId);
  CREATE TRIGGER IF NOT EXISTS assignment_delivery_delegations_no_update
  BEFORE UPDATE ON assignment_delivery_delegations
  BEGIN SELECT RAISE(ABORT,'assignment_delivery_delegations is immutable'); END;
  CREATE TRIGGER IF NOT EXISTS assignment_delivery_delegations_no_delete
  BEFORE DELETE ON assignment_delivery_delegations
  BEGIN SELECT RAISE(ABORT,'assignment_delivery_delegations is immutable'); END;
  """

  @doc false
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Bind an item to an explicit addressed-PO scope."
  def handle(db, %{verb: @scope_operation, params: params} = call) do
    transact(db, &set_scope_in_txn(&1, call.principal, params))
  end

  # Set or succeed the one accountable owner for an addressed-PO scope.
  def handle(db, %{verb: @owner_operation, params: params} = call) do
    transact(db, &set_scope_owner_in_txn(&1, call.principal, params))
  end

  def handle(db, %{verb: "delivery-responsibility-get", params: params} = call) do
    transact(db, &get_in_txn(&1, call.principal, params[:work_item_id]))
  end

  def handle(_db, _call),
    do: refusal("unknown_operation", "unsupported delivery responsibility operation")

  @doc "Return the current scope binding for an exact work item."
  def current_scope(db \\ DB, work_item_id) when is_binary(work_item_id) do
    transact(db, &current_scope_in_txn(&1, work_item_id))
  end

  @doc false
  def current_scope_in_txn(%Txn{} = txn, work_item_id) do
    case Txn.q(txn, current_scope_sql() <> " WHERE e.workItemId=?1", [work_item_id]) do
      [row] -> scope_event(row)
      [] -> nil
    end
  end

  @doc "Return the current accountable event for an item's explicit scope."
  def current_owner(db \\ DB, work_item_id) when is_binary(work_item_id) do
    transact(db, &current_owner_in_txn(&1, work_item_id))
  end

  @doc false
  def current_owner_in_txn(%Txn{} = txn, work_item_id) do
    case current_scope_in_txn(txn, work_item_id) do
      nil ->
        nil

      scope ->
        case current_scope_owner_in_txn(txn, scope["ownerUserId"], scope["poRole"]) do
          nil ->
            nil

          owner ->
            owner
            |> Map.put("workItemId", work_item_id)
            |> Map.put("scopeBindingEventId", scope["eventId"])
            |> Map.put("scopeBindingRevision", scope["bindingRevision"])
            |> Map.put("scopeAssociationSessionKey", scope["associationSessionKey"])
            |> Map.put("scopeAssociationRevision", scope["associationRevision"])
        end
    end
  end

  @doc "Return accountable, delegated, stale, or none for a session and item."
  def responsibility(db \\ DB, session_key, work_item_id)

  def responsibility(%Txn{} = txn, session_key, work_item_id)
      when is_binary(session_key) and is_binary(work_item_id),
      do: responsibility_in_txn(txn, session_key, work_item_id)

  def responsibility(db, session_key, work_item_id)
      when is_binary(session_key) and is_binary(work_item_id) do
    transact(db, &responsibility_in_txn(&1, session_key, work_item_id))
  end

  @doc false
  def responsibility_in_txn(%Txn{} = txn, session_key, work_item_id) do
    owner = current_owner_in_txn(txn, work_item_id)

    cond do
      owner && owner["accountableSessionKey"] == session_key &&
          owner["deliveryState"] == "current" ->
        "accountable"

      owner && owner["accountableSessionKey"] == session_key ->
        "stale"

      active_delegation_in_txn?(txn, session_key, work_item_id) ->
        "delegated"

      open_delegation_in_txn?(txn, session_key, work_item_id) ->
        "stale"

      true ->
        "none"
    end
  end

  @doc false
  def validate_assignment_delegation_in_txn(%Txn{}, %{params: params}, _target)
      when not is_map_key(params, :delegates_delivery),
      do: :ok

  def validate_assignment_delegation_in_txn(
        %Txn{},
        %{params: %{delegates_delivery: false}},
        _target
      ),
      do: :ok

  def validate_assignment_delegation_in_txn(
        %Txn{} = txn,
        %{principal: principal, params: %{delegates_delivery: true} = params},
        target
      ) do
    work_item_id = params[:work_item_id]

    with :ok <- required_delegation_work_item(work_item_id),
         {:ok, _owner} <- open_work_item_owner(txn, work_item_id),
         {:ok, binding} <- bound_scope(txn, work_item_id),
         {:ok, owner} <- current_usable_owner(txn, binding),
         {:ok, _target_association} <-
           association_for_scope(txn, target, binding["ownerUserId"], binding["poRole"]),
         {:ok, _attribution} <-
           authorize_delegation(txn, principal, work_item_id, binding, owner) do
      :ok
    else
      {:error, code, message} -> refusal(code, message)
    end
  end

  def validate_assignment_delegation_in_txn(%Txn{}, %{params: params}, _target)
      when is_map_key(params, :delegates_delivery),
      do:
        refusal("invalid_delegates_delivery", "delegatesDelivery must be a boolean when supplied")

  @doc false
  def record_assignment_delegation_in_txn(
        %Txn{},
        %{params: %{delegates_delivery: value}},
        _assignment
      )
      when value != true,
      do: :ok

  def record_assignment_delegation_in_txn(%Txn{}, %{params: params}, _assignment)
      when not is_map_key(params, :delegates_delivery),
      do: :ok

  def record_assignment_delegation_in_txn(%Txn{} = txn, call, assignment) do
    {:ok, binding} = bound_scope(txn, assignment.workItemId)
    {:ok, owner} = current_usable_owner(txn, binding)

    {:ok, target_association} =
      association_for_scope(
        txn,
        assignment.holderKey,
        binding["ownerUserId"],
        binding["poRole"]
      )

    {:ok, {kind, by}} =
      authorize_delegation(txn, call.principal, assignment.workItemId, binding, owner)

    Txn.q(
      txn,
      """
      INSERT INTO assignment_delivery_delegations
        (assignmentId,workItemId,holderSessionKey,ownerUserId,poRole,
         scopeBindingEventId,scopeBindingRevision,ownerEventId,ownerRevision,
         holderAssociationRevision,delegatedByKind,delegatedByRef,createdAt)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
      """,
      [
        assignment.id,
        assignment.workItemId,
        assignment.holderKey,
        binding["ownerUserId"],
        binding["poRole"],
        binding["eventId"],
        binding["bindingRevision"],
        owner["eventId"],
        owner["ownerRevision"],
        target_association.revision,
        kind,
        by,
        System.system_time(:millisecond)
      ]
    )

    :ok
  end

  defp set_scope_in_txn(txn, principal, params) do
    work_item_id = params[:work_item_id]
    association_session = params[:association_session_key]
    association_revision = params[:association_revision]
    expected_revision = params[:expected_binding_revision]
    key = params[:idempotency_key]

    with :ok <- nonblank([work_item_id, association_session, key]),
         :ok <- nonnegative_integer(expected_revision, "expected binding revision"),
         :ok <- positive_integer(association_revision, "association revision"),
         {:ok, owner, item_state} <- work_item_owner_and_state(txn, work_item_id),
         fingerprint <-
           fingerprint([
             work_item_id,
             association_session,
             association_revision,
             expected_revision
           ]),
         replay <- replay_in_txn(txn, owner, @scope_operation, key),
         {:continue, replay} <- replay_or_continue(replay, fingerprint) do
      if replay do
        replay
      else
        with :ok <- open_item(item_state),
             {:ok, association} <-
               current_association(txn, association_session, association_revision),
             :ok <-
               same_owner(association.owner, owner, "association and work item owners differ"),
             current <- current_scope_in_txn(txn, work_item_id),
             :ok <- expected_binding(current, expected_revision),
             :ok <- authorize_scope_binding(txn, principal, owner, association, current),
             :ok <- reassignable_item(txn, work_item_id, current, association) do
          {response, replay_session} =
            if current && current["ownerUserId"] == association.owner &&
                 current["poRole"] == association.po_role do
              {%{"changed" => false, "scope" => current}, current["associationSessionKey"]}
            else
              event = append_scope_event(txn, work_item_id, association, principal, current)
              {%{"changed" => true, "scope" => event}, event["associationSessionKey"]}
            end

          persist_replay(
            txn,
            owner,
            @scope_operation,
            key,
            replay_session,
            fingerprint,
            response
          )

          response
        else
          {:error, code, message} -> refusal(code, message)
        end
      end
    else
      {:error, code, message} -> refusal(code, message)
      %{code: _} = error -> error
    end
  end

  defp set_scope_owner_in_txn(txn, principal, params) do
    target = params[:session_key]
    association_revision = params[:association_revision]
    expected_session = params[:expected_owner_session_key]
    expected_revision = params[:expected_owner_revision]
    key = params[:idempotency_key]

    with :ok <- nonblank([target, key]),
         :ok <- optional_text(expected_session, "expected owner session"),
         :ok <- positive_integer(association_revision, "association revision"),
         :ok <- nonnegative_integer(expected_revision, "expected owner revision"),
         {:ok, owner} <- session_owner(txn, target),
         fingerprint <-
           fingerprint([target, association_revision, expected_session, expected_revision]),
         replay <- replay_in_txn(txn, owner, @owner_operation, key),
         {:continue, replay} <- replay_or_continue(replay, fingerprint) do
      if replay do
        replay
      else
        with {:ok, association} <- current_association(txn, target, association_revision),
             :ok <- same_owner(association.owner, owner, "association and target owners differ"),
             current <- current_scope_owner_in_txn(txn, owner, association.po_role),
             :ok <- expected_owner(current, expected_session, expected_revision),
             :ok <- authorize_scope_owner_set(txn, principal, owner, current) do
          {response, replay_session} =
            if current && current["accountableSessionKey"] == target &&
                 current["associationRevision"] == association_revision &&
                 current["deliveryState"] == "current" do
              {%{"changed" => false, "accountable" => current}, target}
            else
              event = append_owner_event(txn, association, principal, current)
              {%{"changed" => true, "accountable" => event}, target}
            end

          persist_replay(
            txn,
            owner,
            @owner_operation,
            key,
            replay_session,
            fingerprint,
            response
          )

          response
        else
          {:error, code, message} -> refusal(code, message)
        end
      end
    else
      {:error, code, message} -> refusal(code, message)
      %{code: _} = error -> error
    end
  end

  defp get_in_txn(txn, principal, work_item_id) do
    with :ok <- required_text(work_item_id, "work item must be a non-empty string"),
         {:ok, owner, _state} <- work_item_owner_and_state(txn, work_item_id),
         :ok <- authorize_read(txn, principal, owner) do
      scope = current_scope_in_txn(txn, work_item_id)

      %{
        "workItemId" => work_item_id,
        "scope" => scope,
        "accountable" => current_owner_in_txn(txn, work_item_id),
        "delegations" => delegations_in_txn(txn, work_item_id),
        "scopeHistory" => scope_history_in_txn(txn, work_item_id),
        "ownerHistory" => owner_history_for_scope_in_txn(txn, scope)
      }
    else
      {:error, code, message} -> refusal(code, message)
    end
  end

  defp append_scope_event(txn, work_item_id, association, principal, current) do
    event_id = "dsb_" <> Id.uuid4()
    revision = if current, do: current["bindingRevision"] + 1, else: 1
    {kind, by} = attribution(principal)

    Txn.q(
      txn,
      """
      INSERT INTO work_item_delivery_scope_events
        (eventId,workItemId,bindingRevision,ownerUserId,poRole,
         associationSessionKey,associationRevision,previousOwnerUserId,
         previousPoRole,setByKind,setByRef,cause,createdAt)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
      """,
      [
        event_id,
        work_item_id,
        revision,
        association.owner,
        association.po_role,
        association.session,
        association.revision,
        current && current["ownerUserId"],
        current && current["poRole"],
        kind,
        by,
        if(current, do: "reassigned", else: "initial"),
        System.system_time(:millisecond)
      ]
    )

    current_scope_in_txn(txn, work_item_id)
  end

  defp append_owner_event(txn, association, principal, current) do
    event_id = "dso_" <> Id.uuid4()
    revision = if current, do: current["ownerRevision"] + 1, else: 1
    {kind, by} = attribution(principal)

    cause =
      cond do
        is_nil(current) -> "initial"
        current["deliveryState"] == "current" -> "transfer"
        true -> "recovery"
      end

    Txn.q(
      txn,
      """
      INSERT INTO delivery_scope_owner_events
        (eventId,ownerUserId,poRole,ownerRevision,previousSessionKey,
         accountableSessionKey,associationRevision,expectedOwnerRevision,
         expectedSessionKey,setByKind,setByRef,cause,createdAt)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
      """,
      [
        event_id,
        association.owner,
        association.po_role,
        revision,
        current && current["accountableSessionKey"],
        association.session,
        association.revision,
        if(current, do: current["ownerRevision"], else: 0),
        current && current["accountableSessionKey"],
        kind,
        by,
        cause,
        System.system_time(:millisecond)
      ]
    )

    current_scope_owner_in_txn(txn, association.owner, association.po_role)
  end

  defp current_scope_owner_in_txn(txn, owner, po_role) do
    case Txn.q(txn, current_owner_sql() <> " WHERE e.ownerUserId=?1 AND e.poRole=?2", [
           owner,
           po_role
         ]) do
      [row] -> owner_event(row) |> Map.put("deliveryState", owner_state(txn, row))
      [] -> nil
    end
  end

  defp owner_state(txn, row) do
    [_event, owner, po_role, _revision, _previous, session, association_revision | _] = row

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
        if active_role_office?(txn, owner, po_role), do: "current", else: "stale"

      _ ->
        "stale"
    end
  end

  defp authorize_scope_binding(txn, principal, owner, association, current) do
    cond do
      authorized_user?(txn, principal, owner) ->
        :ok

      actual_main?(txn, principal, owner) ->
        :ok

      session_principal?(principal) &&
        (is_nil(current) ||
           (current["ownerUserId"] == association.owner &&
              current["poRole"] == association.po_role)) &&
          current_owner_session?(txn, principal, association.owner, association.po_role) ->
        :ok

      true ->
        {:error, "not_authorized",
         "binding this item requires its human owner/admin, the owner's actual Main, or the current accountable owner of the selected scope"}
    end
  end

  defp authorize_scope_owner_set(txn, principal, owner, current) do
    cond do
      authorized_user?(txn, principal, owner) ->
        :ok

      actual_main?(txn, principal, owner) ->
        :ok

      session_principal?(principal) && current && current["deliveryState"] == "current" &&
          elem(principal, 1) == current["accountableSessionKey"] ->
        :ok

      true ->
        {:error, "not_authorized",
         "owner succession requires the human owner/admin, the owner's actual Main, or the current active accountable owner"}
    end
  end

  defp authorize_delegation(txn, {:session, caller}, work_item_id, binding, owner) do
    cond do
      owner["deliveryState"] != "current" ->
        {:error, "delivery_owner_reconciliation_required",
         "the accountable owner association is stale or unavailable; the owner or Main must complete explicit recovery"}

      caller == owner["accountableSessionKey"] ->
        {:ok, {"session", "session:" <> caller}}

      active_delegation_in_txn?(txn, caller, work_item_id) ->
        {:ok, {"session", "session:" <> caller}}

      true ->
        {:error, "not_authorized",
         "delivery delegation requires the current accountable owner or an active exact-item delegate for scope #{binding["poRole"]}; current accountable owner: session:#{owner["accountableSessionKey"]}"}
    end
  end

  defp authorize_delegation(_txn, _principal, _work_item_id, _binding, owner) do
    {:error, "not_authorized",
     "production delegation must be issued by the current accountable session; current accountable owner: session:#{owner["accountableSessionKey"]}"}
  end

  defp authorize_read(txn, {:user, user}, owner) do
    if user == owner || admin_user?(txn, user),
      do: :ok,
      else: {:error, "not_authorized", "delivery responsibility belongs to another owner"}
  end

  defp authorize_read(txn, {:session, session}, owner) do
    case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [session]) do
      [[^owner]] -> :ok
      _ -> {:error, "not_authorized", "delivery responsibility belongs to another owner"}
    end
  end

  defp authorize_read(_txn, _principal, _owner),
    do: {:error, "not_authorized", "delivery responsibility requires an attributable owner"}

  defp current_association(txn, session, revision) do
    case Txn.q(
           txn,
           """
           SELECT s.ownerUserId,s.state,a.ownerUserId,a.poRole,a.revision
           FROM sessions s
           LEFT JOIN session_po_associations a ON a.sessionKey=s.sessionKey
           WHERE s.sessionKey=?1
           """,
           [session]
         ) do
      [] ->
        {:error, "unknown_session", "association session does not exist"}

      [[_session_owner, "retired", _association_owner, _po_role, _actual_revision]] ->
        {:error, "session_retired", "association session is retired"}

      [[session_owner, "active", session_owner, po_role, ^revision]]
      when is_binary(po_role) ->
        if active_role_office?(txn, session_owner, po_role) do
          {:ok, %{owner: session_owner, po_role: po_role, session: session, revision: revision}}
        else
          {:error, "po_role_unresolved",
           "the associated PO role no longer resolves to an active same-owner office"}
        end

      [[_session_owner, "active", nil, nil, nil]] ->
        {:error, "missing_po_association", "the session has no explicit addressed-PO association"}

      [[_session_owner, "active", _association_owner, _po_role, _actual_revision]] ->
        {:error, "stale_po_association",
         "the supplied session and association revision are not the current addressed-PO association"}
    end
  end

  defp association_for_scope(txn, session, owner, po_role) do
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
      [["active", ^owner, ^po_role, revision]] when is_integer(revision) ->
        if active_role_office?(txn, owner, po_role) do
          {:ok, %{owner: owner, po_role: po_role, session: session, revision: revision}}
        else
          {:error, "po_role_unresolved",
           "the scope PO role no longer resolves to an active same-owner office"}
        end

      [["retired", _association_owner, _association_role, _revision]] ->
        {:error, "session_retired", "delegation target is retired"}

      [["active", nil, nil, nil]] ->
        {:error, "missing_po_association",
         "delegation target has no explicit addressed-PO association"}

      [["active", _association_owner, _association_role, _revision]] ->
        {:error, "cross_scope_session",
         "delegation target's current addressed-PO association does not match the work item's scope"}

      [] ->
        {:error, "unknown_session", "delegation target does not exist"}
    end
  end

  defp active_role_office?(txn, owner, po_role) do
    case Txn.q(txn, "SELECT ownerUserId,boundSessionKey FROM roles WHERE name=?1", [po_role]) do
      [[^owner, bound]] ->
        office = bound || Org.personal_session_key(owner)

        Txn.q(
          txn,
          "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active'",
          [office, owner]
        ) == [[1]]

      _ ->
        false
    end
  end

  defp expected_binding(nil, 0), do: :ok

  defp expected_binding(nil, _revision),
    do:
      {:error, "stale_binding_revision",
       "the item is unbound; expected binding revision must be 0"}

  defp expected_binding(current, revision) do
    if current["bindingRevision"] == revision do
      :ok
    else
      {:error, "stale_binding_revision",
       "expected binding revision #{revision} is stale; current revision is #{current["bindingRevision"]}"}
    end
  end

  defp expected_owner(nil, nil, 0), do: :ok

  defp expected_owner(nil, _session, _revision),
    do:
      {:error, "stale_owner_revision", "the scope is unowned; expected owner revision must be 0"}

  defp expected_owner(current, session, revision) do
    if current["accountableSessionKey"] == session && current["ownerRevision"] == revision do
      :ok
    else
      {:error, "stale_owner_revision",
       "expected owner session/revision is stale; current accountable owner is session:#{current["accountableSessionKey"]} at revision #{current["ownerRevision"]}"}
    end
  end

  defp reassignable_item(_txn, _work_item_id, nil, _association), do: :ok

  defp reassignable_item(txn, work_item_id, current, association) do
    if current["ownerUserId"] == association.owner && current["poRole"] == association.po_role do
      :ok
    else
      case Txn.q(
             txn,
             "SELECT id FROM assignments WHERE workItemId=?1 AND state='open' ORDER BY id LIMIT 1",
             [work_item_id]
           ) do
        [] ->
          :ok

        [[assignment_id]] ->
          {:error, "scope_reassignment_has_open_obligations",
           "work item has open assignment #{assignment_id}; reconcile it before changing delivery scope"}
      end
    end
  end

  defp current_usable_owner(txn, binding) do
    case current_scope_owner_in_txn(txn, binding["ownerUserId"], binding["poRole"]) do
      nil ->
        {:error, "delivery_scope_unowned",
         "the delivery scope has no accountable owner; the human owner/admin or owner's actual Main must set one before production delegation"}

      %{"deliveryState" => "current"} = owner ->
        {:ok, owner}

      _owner ->
        {:error, "delivery_owner_reconciliation_required",
         "the accountable owner association is stale or unavailable; the human owner/admin or owner's actual Main must complete explicit recovery"}
    end
  end

  defp bound_scope(txn, work_item_id) do
    case current_scope_in_txn(txn, work_item_id) do
      nil ->
        {:error, "delivery_scope_unbound",
         "the work item has no explicit delivery scope; its owner/Main or the current owner of the selected scope must bind it before production delegation"}

      scope ->
        {:ok, scope}
    end
  end

  defp active_delegation_in_txn?(txn, session_key, work_item_id) do
    delegation_candidates(txn, session_key, work_item_id)
    |> Enum.any?(&current_delegation?(txn, &1))
  end

  defp open_delegation_in_txn?(txn, session_key, work_item_id) do
    delegation_candidates(txn, session_key, work_item_id) != []
  end

  defp delegation_candidates(txn, session_key, work_item_id) do
    Txn.q(
      txn,
      """
      SELECT d.assignmentId,d.ownerUserId,d.poRole,d.scopeBindingEventId,
             d.scopeBindingRevision,d.ownerEventId,d.ownerRevision,
             d.holderAssociationRevision,d.holderSessionKey,d.workItemId
      FROM assignment_delivery_delegations d
      JOIN assignments a ON a.id=d.assignmentId
      JOIN sessions s ON s.sessionKey=d.holderSessionKey
      WHERE d.holderSessionKey=?1 AND d.workItemId=?2
        AND a.state='open' AND s.state='active'
      ORDER BY d.createdAt,d.assignmentId
      """,
      [session_key, work_item_id]
    )
  end

  defp current_delegation?(txn, [
         _assignment_id,
         owner,
         po_role,
         binding_event_id,
         binding_revision,
         owner_event_id,
         owner_revision,
         holder_association_revision,
         session_key,
         work_item_id
       ]) do
    with %{
           "eventId" => ^binding_event_id,
           "bindingRevision" => ^binding_revision,
           "ownerUserId" => ^owner,
           "poRole" => ^po_role
         } <- current_scope_in_txn(txn, work_item_id),
         %{
           "eventId" => ^owner_event_id,
           "ownerRevision" => ^owner_revision,
           "deliveryState" => "current"
         } <- current_scope_owner_in_txn(txn, owner, po_role),
         {:ok, %{revision: ^holder_association_revision}} <-
           association_for_scope(txn, session_key, owner, po_role) do
      true
    else
      _ -> false
    end
  end

  defp delegations_in_txn(txn, work_item_id) do
    Txn.q(
      txn,
      """
      SELECT d.assignmentId,d.holderSessionKey,d.ownerUserId,d.poRole,
             d.scopeBindingEventId,d.scopeBindingRevision,d.ownerEventId,
             d.ownerRevision,d.holderAssociationRevision,d.delegatedByRef,
             d.createdAt,a.state,s.state
      FROM assignment_delivery_delegations d
      JOIN assignments a ON a.id=d.assignmentId
      JOIN sessions s ON s.sessionKey=d.holderSessionKey
      WHERE d.workItemId=?1 ORDER BY d.createdAt,d.assignmentId
      """,
      [work_item_id]
    )
    |> Enum.map(fn [
                     assignment,
                     holder,
                     owner,
                     po_role,
                     binding_event,
                     binding_revision,
                     owner_event,
                     owner_revision,
                     association_revision,
                     by,
                     at,
                     assignment_state,
                     session_state
                   ] ->
      active =
        assignment_state == "open" && session_state == "active" &&
          current_delegation?(txn, [
            assignment,
            owner,
            po_role,
            binding_event,
            binding_revision,
            owner_event,
            owner_revision,
            association_revision,
            holder,
            work_item_id
          ])

      %{
        "assignmentId" => assignment,
        "holderSessionKey" => holder,
        "ownerUserId" => owner,
        "poRole" => po_role,
        "scopeBindingEventId" => binding_event,
        "scopeBindingRevision" => binding_revision,
        "ownerEventId" => owner_event,
        "ownerRevision" => owner_revision,
        "holderAssociationRevision" => association_revision,
        "delegatedByRef" => by,
        "createdAt" => at,
        "assignmentState" => assignment_state,
        "sessionState" => session_state,
        "active" => active
      }
    end)
  end

  defp scope_history_in_txn(txn, work_item_id) do
    Txn.q(
      txn,
      """
      SELECT eventId,workItemId,bindingRevision,ownerUserId,poRole,
             associationSessionKey,associationRevision,previousOwnerUserId,
             previousPoRole,setByKind,setByRef,cause,createdAt
      FROM work_item_delivery_scope_events
      WHERE workItemId=?1 ORDER BY eventSeq
      """,
      [work_item_id]
    )
    |> Enum.map(&scope_event/1)
  end

  defp owner_history_for_scope_in_txn(_txn, nil), do: []

  defp owner_history_for_scope_in_txn(txn, scope) do
    Txn.q(
      txn,
      """
      SELECT eventId,ownerUserId,poRole,ownerRevision,previousSessionKey,
             accountableSessionKey,associationRevision,expectedOwnerRevision,
             expectedSessionKey,setByKind,setByRef,cause,createdAt
      FROM delivery_scope_owner_events
      WHERE ownerUserId=?1 AND poRole=?2 ORDER BY eventSeq
      """,
      [scope["ownerUserId"], scope["poRole"]]
    )
    |> Enum.map(&owner_event/1)
  end

  defp current_scope_sql do
    """
    SELECT e.eventId,e.workItemId,e.bindingRevision,e.ownerUserId,e.poRole,
           e.associationSessionKey,e.associationRevision,e.previousOwnerUserId,
           e.previousPoRole,e.setByKind,e.setByRef,e.cause,e.createdAt
    FROM work_item_delivery_scope_events e
    JOIN (
      SELECT workItemId,MAX(eventSeq) AS eventSeq
      FROM work_item_delivery_scope_events GROUP BY workItemId
    ) current ON current.workItemId=e.workItemId AND current.eventSeq=e.eventSeq
    """
  end

  defp current_owner_sql do
    """
    SELECT e.eventId,e.ownerUserId,e.poRole,e.ownerRevision,e.previousSessionKey,
           e.accountableSessionKey,e.associationRevision,e.expectedOwnerRevision,
           e.expectedSessionKey,e.setByKind,e.setByRef,e.cause,e.createdAt
    FROM delivery_scope_owner_events e
    JOIN (
      SELECT ownerUserId,poRole,MAX(eventSeq) AS eventSeq
      FROM delivery_scope_owner_events GROUP BY ownerUserId,poRole
    ) current ON current.ownerUserId=e.ownerUserId AND current.poRole=e.poRole
             AND current.eventSeq=e.eventSeq
    """
  end

  defp scope_event([
         event,
         item,
         revision,
         owner,
         po_role,
         association_session,
         association_revision,
         previous_owner,
         previous_po_role,
         kind,
         by,
         cause,
         at
       ]) do
    %{
      "eventId" => event,
      "workItemId" => item,
      "bindingRevision" => revision,
      "ownerUserId" => owner,
      "poRole" => po_role,
      "associationSessionKey" => association_session,
      "associationRevision" => association_revision,
      "previousOwnerUserId" => previous_owner,
      "previousPoRole" => previous_po_role,
      "setByKind" => kind,
      "setByRef" => by,
      "cause" => cause,
      "createdAt" => at
    }
  end

  defp owner_event([
         event,
         owner,
         po_role,
         revision,
         previous,
         session,
         association_revision,
         expected_revision,
         expected_session,
         kind,
         by,
         cause,
         at
       ]) do
    %{
      "eventId" => event,
      "ownerUserId" => owner,
      "poRole" => po_role,
      "ownerRevision" => revision,
      "previousSessionKey" => previous,
      "accountableSessionKey" => session,
      "associationSessionKey" => session,
      "associationRevision" => association_revision,
      "expectedOwnerRevision" => expected_revision,
      "expectedSessionKey" => expected_session,
      "setByKind" => kind,
      "setByRef" => by,
      "cause" => cause,
      "createdAt" => at
    }
  end

  defp replay_in_txn(txn, owner, operation, key) do
    case Txn.q(
           txn,
           """
           SELECT requestFingerprint,canonicalResponse FROM delivery_responsibility_requests
           WHERE ownerUserId=?1 AND operation=?2 AND idempotencyKey=?3
           """,
           [owner, operation, key]
         ) do
      [[fingerprint, response]] -> %{fingerprint: fingerprint, response: JSON.decode!(response)}
      [] -> nil
    end
  end

  defp replay_or_continue(nil, _fingerprint), do: {:continue, nil}

  defp replay_or_continue(%{fingerprint: fingerprint, response: response}, fingerprint),
    do: {:continue, response}

  defp replay_or_continue(_replay, _fingerprint),
    do:
      {:error, "idempotency_conflict",
       "the request key was already used with different parameters"}

  defp persist_replay(txn, owner, operation, key, session, fingerprint, response) do
    Txn.q(
      txn,
      """
      INSERT INTO delivery_responsibility_requests
        (ownerUserId,operation,idempotencyKey,subjectRef,requestFingerprint,
         canonicalResponse,createdAt)
      VALUES (?1,?2,?3,?4,?5,?6,?7)
      """,
      [
        owner,
        operation,
        key,
        session,
        fingerprint,
        JSON.encode!(response),
        System.system_time(:millisecond)
      ]
    )

    :ok
  end

  defp authorized_user?(txn, {:user, caller}, owner),
    do: caller == owner || admin_user?(txn, caller)

  defp authorized_user?(_txn, _principal, _owner), do: false

  defp admin_user?(txn, user) do
    Txn.q(txn, "SELECT isAdmin FROM users WHERE userId=?1", [user]) == [[1]]
  end

  defp actual_main?(txn, {:session, session}, owner) do
    Txn.q(
      txn,
      "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND kind='main' AND state='active'",
      [session, owner]
    ) == [[1]]
  end

  defp actual_main?(_txn, _principal, _owner), do: false

  defp current_owner_session?(txn, {:session, session}, owner, po_role) do
    case current_scope_owner_in_txn(txn, owner, po_role) do
      %{"accountableSessionKey" => ^session, "deliveryState" => "current"} -> true
      _ -> false
    end
  end

  defp current_owner_session?(_txn, _principal, _owner, _po_role), do: false

  defp session_principal?({:session, session}) when is_binary(session), do: true
  defp session_principal?(_principal), do: false

  defp attribution({:user, user}), do: {"user", "user:" <> user}
  defp attribution({:session, session}), do: {"session", "session:" <> session}

  defp open_work_item_owner(txn, work_item_id) do
    case work_item_owner_and_state(txn, work_item_id) do
      {:ok, owner, "open"} -> {:ok, owner}
      {:ok, _owner, _state} -> {:error, "work_item_not_open", "work item is not open"}
      error -> error
    end
  end

  defp work_item_owner_and_state(txn, work_item_id) do
    case Txn.q(txn, "SELECT ownerUserId,state FROM work_items WHERE id=?1", [work_item_id]) do
      [[owner, state]] -> {:ok, owner, state}
      [] -> {:error, "unknown_work_item", "work item does not exist"}
    end
  end

  defp session_owner(txn, session) do
    case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [session]) do
      [[owner]] -> {:ok, owner}
      [] -> {:error, "unknown_session", "target session does not exist"}
    end
  end

  defp open_item("open"), do: :ok
  defp open_item(_state), do: {:error, "work_item_not_open", "work item is not open"}

  defp same_owner(owner, owner, _message), do: :ok
  defp same_owner(_left, _right, message), do: {:error, "cross_owner_scope", message}

  defp required_text(value, message) when is_binary(value) do
    if String.trim(value) == "",
      do: {:error, "invalid_message", message},
      else: :ok
  end

  defp required_text(_value, message), do: {:error, "invalid_message", message}

  defp required_delegation_work_item(value) when is_binary(value) do
    if String.trim(value) == "",
      do:
        {:error, "delivery_delegation_requires_work_item",
         "delegated delivery responsibility requires a work item"},
      else: :ok
  end

  defp required_delegation_work_item(_value),
    do:
      {:error, "delivery_delegation_requires_work_item",
       "delegated delivery responsibility requires a work item"}

  defp optional_text(nil, _label), do: :ok

  defp optional_text(value, label) when is_binary(value) do
    if String.trim(value) == "",
      do: {:error, "invalid_message", "#{label} must be omitted or a non-empty string"},
      else: :ok
  end

  defp optional_text(_value, label),
    do: {:error, "invalid_message", "#{label} must be omitted or a non-empty string"}

  defp positive_integer(value, _label) when is_integer(value) and value >= 1, do: :ok

  defp positive_integer(_value, label),
    do: {:error, "invalid_message", "#{label} must be a positive integer"}

  defp nonnegative_integer(value, _label) when is_integer(value) and value >= 0, do: :ok

  defp nonnegative_integer(_value, label),
    do: {:error, "invalid_message", "#{label} must be a non-negative integer"}

  defp nonblank(values) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else:
        {:error, "invalid_message",
         "required identifiers and request key must be non-empty strings"}
  end

  defp fingerprint(values) do
    :crypto.hash(:sha256, JSON.encode!(values))
    |> Base.encode16(case: :lower)
  end

  defp transact(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp refusal(code, message), do: %{code: code, message: message}
end
