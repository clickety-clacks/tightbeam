defmodule Tightbeam.SessionPoAssociations do
  @moduledoc "Explicit current addressed-PO associations for exact session incarnations."

  alias Tightbeam.{DB, Org, Wakes}
  alias Tightbeam.DB.Txn

  @operation "session-po-set"
  @cause "explicit_set"

  @ddl """
  CREATE TABLE session_po_associations (
    sessionKey    TEXT PRIMARY KEY REFERENCES sessions(sessionKey),
    ownerUserId   TEXT NOT NULL,
    poRole        TEXT NOT NULL,
    revision      INTEGER NOT NULL CHECK (revision >= 1),
    noticeWakeId  TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
    setBy         TEXT NOT NULL,
    cause         TEXT NOT NULL CHECK (cause = 'explicit_set'),
    createdAt     INTEGER NOT NULL,
    updatedAt     INTEGER NOT NULL,
    CHECK (length(trim(poRole)) > 0),
    CHECK (length(trim(setBy)) > 0),
    CHECK (updatedAt >= createdAt)
  );
  CREATE INDEX session_po_associations_owner
    ON session_po_associations(ownerUserId, sessionKey);
  """

  @doc false
  def migrate_in_txn(%Txn{} = txn), do: Txn.exec(txn, @ddl)

  @doc "Set or replace one exact session's addressed PO role."
  def handle(db, %{principal: principal, params: params} = call) do
    case DB.transaction(db, &set_in_txn(&1, principal, params, call)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  def handle(_db, _call),
    do: refusal("unknown_caller", "an authenticated user or session is required")

  @doc "Read the current association for an exact session, or nil."
  def get(db \\ Tightbeam.DB, session_key) when is_binary(session_key) do
    case DB.query(db, select_sql() <> " WHERE a.sessionKey=?1", [session_key]) do
      {:ok, [row]} -> association(row)
      {:ok, []} -> nil
    end
  end

  @doc false
  def get_in_txn(%Txn{} = txn, session_key) do
    case Txn.q(txn, select_sql() <> " WHERE a.sessionKey=?1", [session_key]) do
      [row] -> association(row)
      [] -> nil
    end
  end

  defp set_in_txn(txn, principal, params, call) do
    session_key = params[:session_key]
    po_role = params[:po_role]
    key = params[:idempotency_key]

    with :ok <- valid_input(session_key, po_role, key),
         {:ok, owner} <- active_target(txn, session_key),
         {:ok, set_by} <- authorize(txn, principal, session_key, owner) do
      fingerprint = fingerprint(session_key, po_role)

      case replay_in_txn(txn, owner, key) do
        %{fingerprint: ^fingerprint, response: response} ->
          response

        nil ->
          with :ok <- resolvable_po_role(txn, po_role, owner) do
            apply_in_txn(txn, owner, session_key, po_role, key, fingerprint, set_by, call)
          else
            {:error, code, message} -> refusal(code, message)
          end

        _different_request ->
          refusal(
            "idempotency_conflict",
            "the request key was already used with different parameters"
          )
      end
    else
      {:error, code, message} -> refusal(code, message)
    end
  end

  defp apply_in_txn(txn, owner, session_key, po_role, key, fingerprint, set_by, call) do
    case get_in_txn(txn, session_key) do
      %{"poRole" => ^po_role} = current ->
        response = %{"association" => current, "changed" => false}
        persist_replay(txn, owner, key, session_key, fingerprint, response)
        response

      current ->
        now = System.system_time(:millisecond)
        revision = if current, do: current["revision"] + 1, else: 1
        wake_id = "w_" <> Tightbeam.Id.uuid4()

        Wakes.schedule_in_txn(txn, %{
          wake_id: wake_id,
          session_key: session_key,
          origin: "topology:addressed-po-association",
          prompt: notice_prompt(po_role, revision),
          due_at: now,
          owner_user_id: owner,
          creator_session_key: principal_session(call[:principal]),
          sender_scheduled: true
        })

        if current do
          Txn.q(
            txn,
            """
            UPDATE session_po_associations
            SET poRole=?2, revision=?3, noticeWakeId=?4, setBy=?5, cause=?6, updatedAt=?7
            WHERE sessionKey=?1
            """,
            [session_key, po_role, revision, wake_id, set_by, @cause, now]
          )
        else
          Txn.q(
            txn,
            """
            INSERT INTO session_po_associations
              (sessionKey,ownerUserId,poRole,revision,noticeWakeId,setBy,cause,createdAt,updatedAt)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?8)
            """,
            [session_key, owner, po_role, revision, wake_id, set_by, @cause, now]
          )
        end

        association = get_in_txn(txn, session_key)
        response = %{"association" => association, "changed" => true}
        persist_replay(txn, owner, key, session_key, fingerprint, response)
        response
    end
  end

  defp active_target(txn, session_key) do
    case Txn.q(txn, "SELECT ownerUserId,state FROM sessions WHERE sessionKey=?1", [session_key]) do
      [[owner, "active"]] -> {:ok, owner}
      [[_owner, "retired"]] -> {:error, "session_retired", "target session is retired"}
      [] -> {:error, "unknown_session", "target session does not exist"}
    end
  end

  defp authorize(_txn, {:user, owner}, _target, owner), do: {:ok, "user:" <> owner}

  defp authorize(txn, {:session, caller}, target, owner) do
    with [[^owner, "active"]] <-
           Txn.q(txn, "SELECT ownerUserId,state FROM sessions WHERE sessionKey=?1", [caller]),
         true <- caller == target or Org.current_parent(txn, target) == caller do
      {:ok, "session:" <> caller}
    else
      _ ->
        {:error, "not_authorized",
         "only the owner, target session, or current parent may set the addressed PO"}
    end
  end

  defp authorize(_txn, _principal, _target, _owner),
    do:
      {:error, "not_authorized",
       "only the owner, target session, or current parent may set the addressed PO"}

  defp resolvable_po_role(txn, po_role, owner) do
    case Txn.q(txn, "SELECT ownerUserId,boundSessionKey FROM roles WHERE name=?1", [po_role]) do
      [[^owner, bound]] ->
        resolved = bound || Org.personal_session_key(owner)

        case Txn.q(txn, "SELECT ownerUserId,state FROM sessions WHERE sessionKey=?1", [resolved]) do
          [[^owner, "active"]] ->
            :ok

          _ ->
            {:error, "po_role_unresolved",
             "PO role does not resolve to an active same-owner session"}
        end

      [[_other_owner, _bound]] ->
        {:error, "cross_owner_po_role", "PO role belongs to a different owner"}

      [] ->
        {:error, "po_role_unresolved", "PO role is not registered"}
    end
  end

  defp replay_in_txn(txn, owner, key) do
    case Txn.q(
           txn,
           """
           SELECT requestFingerprint,canonicalResponse FROM wire_idempotency
           WHERE ownerUserId=?1 AND operation=?2 AND idempotencyKey=?3
           """,
           [owner, @operation, key]
         ) do
      [[fingerprint, response]] -> %{fingerprint: fingerprint, response: JSON.decode!(response)}
      [] -> nil
    end
  end

  defp persist_replay(txn, owner, key, session_key, fingerprint, response) do
    Txn.q(
      txn,
      """
      INSERT INTO wire_idempotency
        (ownerUserId,operation,idempotencyKey,sessionKey,requestFingerprint,canonicalResponse)
      VALUES (?1,?2,?3,?4,?5,?6)
      """,
      [owner, @operation, key, session_key, fingerprint, JSON.encode!(response)]
    )

    :ok
  end

  defp fingerprint(session_key, po_role) do
    :crypto.hash(:sha256, JSON.encode!([session_key, po_role]))
    |> Base.encode16(case: :lower)
  end

  defp valid_input(session_key, po_role, key) do
    if Enum.all?([session_key, po_role, key], &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else:
        {:error, "invalid_message", "session, PO role, and request key must be non-empty strings"}
  end

  defp notice_prompt(po_role, revision) do
    "Your addressed PO is `#{po_role}` (association revision `#{revision}`). " <>
      "Read the current association and consult that PO about team shape. " <>
      "The PO recommends; you adopt or amend the recommendation, staff, and retain delivery custody. " <>
      "This notice does not block otherwise authorized staffing."
  end

  defp principal_session({:session, session_key}), do: session_key
  defp principal_session(_), do: nil

  defp select_sql do
    """
    SELECT a.sessionKey,a.ownerUserId,a.poRole,a.revision,a.noticeWakeId,
           a.setBy,a.cause,a.createdAt,a.updatedAt
    FROM session_po_associations a
    """
  end

  defp association([
         session_key,
         owner,
         po_role,
         revision,
         wake_id,
         set_by,
         cause,
         created_at,
         updated_at
       ]) do
    %{
      "sessionKey" => session_key,
      "ownerUserId" => owner,
      "poRole" => po_role,
      "revision" => revision,
      "noticeWakeId" => wake_id,
      "setBy" => set_by,
      "cause" => cause,
      "createdAt" => created_at,
      "updatedAt" => updated_at
    }
  end

  defp refusal(code, message), do: %{code: code, message: message}
end
