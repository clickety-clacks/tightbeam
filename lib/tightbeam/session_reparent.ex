defmodule Tightbeam.SessionReparent do
  @moduledoc "Owner correction of current topology; creation and runtime rows stay immutable."

  alias Tightbeam.{DB, Idempotency, Org}
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE session_reparent_events (
    eventSeq INTEGER PRIMARY KEY AUTOINCREMENT,
    eventId TEXT NOT NULL UNIQUE,
    ownerUserId TEXT NOT NULL,
    childSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    workItemId TEXT NOT NULL REFERENCES work_items(id),
    originParentSessionKey TEXT,
    previousCurrentParentSessionKey TEXT,
    newCurrentParentSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    originAssignmentOpenerKind TEXT NOT NULL CHECK (originAssignmentOpenerKind IN ('user','session')),
    originAssignmentOpenerRef TEXT NOT NULL,
    previousCurrentCoordinationParentSessionKey TEXT,
    newCurrentCoordinationParentSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    cause TEXT NOT NULL CHECK (cause='owner_topology_correction'),
    principalKind TEXT NOT NULL CHECK (principalKind='user'),
    principalRef TEXT NOT NULL,
    idempotencyKey TEXT NOT NULL,
    requestFingerprint TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    UNIQUE(ownerUserId,idempotencyKey),
    CHECK (newCurrentParentSessionKey=newCurrentCoordinationParentSessionKey),
    CHECK (principalRef='user:' || ownerUserId)
  );
  CREATE INDEX session_reparent_child ON session_reparent_events(childSessionKey,eventSeq);
  CREATE INDEX session_reparent_assignment ON session_reparent_events(assignmentId,eventSeq);
  CREATE TRIGGER session_reparent_no_update BEFORE UPDATE ON session_reparent_events
  BEGIN SELECT RAISE(ABORT,'session_reparent_events is append-only'); END;
  CREATE TRIGGER session_reparent_no_delete BEFORE DELETE ON session_reparent_events
  BEGIN SELECT RAISE(ABORT,'session_reparent_events is append-only'); END;
  """

  @doc false
  def migrate_in_txn(txn), do: Txn.exec(txn, @ddl)

  def handle(db, %{principal: {:user, owner}, params: params}) do
    case DB.transaction(db, &apply_in_txn(&1, owner, params)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  def handle(_db, _call), do: refusal("user_principal_required")

  @doc false
  def apply_in_txn(txn, owner, params) do
    child = params[:session_key]
    parent = params[:parent_session_key]
    assignment = params[:assignment_id]
    key = params[:idempotency_key]

    with true <- valid_key?(key),
         true <- Enum.all?([child, parent, assignment], &(is_binary(&1) and &1 != "")) do
      fingerprint =
        :crypto.hash(:sha256, JSON.encode!([child, parent, assignment]))
        |> Base.encode16(case: :lower)

      case Idempotency.reparent_result_in_txn(txn, owner, key) do
        %{fingerprint: ^fingerprint, response: response} -> response
        nil -> correct_in_txn(txn, owner, child, parent, assignment, key, fingerprint)
        _ -> refusal("idempotency_conflict")
      end
    else
      _ -> refusal("invalid_message")
    end
  end

  defp correct_in_txn(txn, owner, child, parent, assignment, key, fingerprint) do
    with {:ok, origin_parent} <- child_in_txn(txn, owner, child),
         :ok <- parent_in_txn(txn, owner, parent),
         {:ok, work_item, opener_kind, opener} <- assignment_in_txn(txn, owner, child, assignment),
         :ok <- acyclic(txn, parent, MapSet.new([child])) do
      previous_parent = Org.current_parent(txn, child)
      previous_coordination = current_coordination_parent(txn, assignment)

      if previous_parent == parent and previous_coordination == parent do
        refusal("no_change")
      else
        event = "trp_" <> Tightbeam.Id.uuid4()
        at = System.system_time(:millisecond)

        response = %{
          "eventId" => event,
          "session" => %{
            "sessionKey" => child,
            "originParent" => origin_parent,
            "previousCurrentParent" => previous_parent,
            "currentParent" => parent
          },
          "assignment" => %{
            "assignmentId" => assignment,
            "workItemId" => work_item,
            "originOpenerRef" => opener,
            "previousCurrentCoordinationParentRef" => session_ref(previous_coordination),
            "currentCoordinationParentRef" => session_ref(parent)
          },
          "appliedAt" => at
        }

        Txn.q(
          txn,
          """
          INSERT INTO session_reparent_events
            (eventId,ownerUserId,childSessionKey,assignmentId,workItemId,
             originParentSessionKey,previousCurrentParentSessionKey,newCurrentParentSessionKey,
             originAssignmentOpenerKind,originAssignmentOpenerRef,
             previousCurrentCoordinationParentSessionKey,newCurrentCoordinationParentSessionKey,
             cause,principalKind,principalRef,idempotencyKey,requestFingerprint,createdAt)
          VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?8,
            'owner_topology_correction','user',?12,?13,?14,?15)
          """,
          [
            event,
            owner,
            child,
            assignment,
            work_item,
            origin_parent,
            previous_parent,
            parent,
            opener_kind,
            opener,
            previous_coordination,
            "user:" <> owner,
            key,
            fingerprint,
            at
          ]
        )

        :ok = Idempotency.put_reparent_in_txn(txn, owner, key, fingerprint, event, response)
        response
      end
    else
      {:error, code} -> refusal(code)
    end
  end

  defp child_in_txn(txn, owner, child) do
    case Txn.q(
           txn,
           "SELECT ownerUserId,kind,isBuiltIn,state,spawnedBy FROM sessions WHERE sessionKey=?1",
           [child]
         ) do
      [[^owner, "custom", 0, "active", origin]] -> {:ok, origin}
      [[^owner, _, _, _, _]] -> {:error, "unsupported_session"}
      _ -> {:error, "not_authorized"}
    end
  end

  defp parent_in_txn(txn, owner, parent) do
    case Txn.q(txn, "SELECT ownerUserId,state FROM sessions WHERE sessionKey=?1", [parent]) do
      [[^owner, "active"]] -> :ok
      [[^owner, _]] -> {:error, "session_retired"}
      _ -> {:error, "not_authorized"}
    end
  end

  defp assignment_in_txn(txn, owner, child, assignment) do
    case Txn.q(
           txn,
           """
           SELECT a.holderKey,a.state,a.workItemId,w.ownerUserId,w.state,a.openedByUser,a.openedBySession
           FROM assignments a LEFT JOIN work_items w ON w.id=a.workItemId WHERE a.id=?1
           """,
           [assignment]
         ) do
      [[^child, "open", item, ^owner, "open", user, session]] ->
        case Txn.q(
               txn,
               "SELECT id FROM assignments WHERE holderKey=?1 AND state='open' ORDER BY id",
               [child]
             ) do
          [[^assignment]] ->
            {kind, ref} =
              if user, do: {"user", "user:" <> user}, else: {"session", "session:" <> session}

            {:ok, item, kind, ref}

          _ ->
            {:error, "multiple_open_assignments"}
        end

      _ ->
        {:error, "not_authorized"}
    end
  end

  defp acyclic(_txn, nil, _seen), do: :ok

  defp acyclic(txn, key, seen) do
    if MapSet.member?(seen, key),
      do: {:error, "cycle_detected"},
      else: acyclic(txn, Org.current_parent(txn, key), MapSet.put(seen, key))
  end

  def current_coordination_parent(db, assignment) do
    case DB.query(
           db,
           """
           SELECT newCurrentCoordinationParentSessionKey FROM session_reparent_events
           WHERE assignmentId=?1 ORDER BY eventSeq DESC LIMIT 1
           """,
           [assignment]
         ) do
      {:ok, [[parent]]} -> parent
      {:ok, []} -> nil
    end
  end

  def current_coordination_ref(db, assignment),
    do: session_ref(current_coordination_parent(db, assignment))

  def timeline(db, work_item) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT eventSeq,eventId,createdAt,principalRef,cause,childSessionKey,assignmentId,
          previousCurrentParentSessionKey,newCurrentParentSessionKey,
          previousCurrentCoordinationParentSessionKey,newCurrentCoordinationParentSessionKey
        FROM session_reparent_events WHERE workItemId=?1 ORDER BY eventSeq
        """,
        [work_item]
      )

    Enum.map(rows, fn [
                        seq,
                        id,
                        at,
                        principal,
                        cause,
                        child,
                        assignment,
                        previous,
                        parent,
                        previous_coord,
                        coord
                      ] ->
      %{
        type: "session_reparent",
        id: id,
        at: at,
        seqTiebreak: seq,
        principal: principal,
        cause: cause,
        sessionKey: child,
        assignmentId: assignment,
        previousCurrentParent: previous,
        currentParent: parent,
        previousCurrentCoordinationParentRef: session_ref(previous_coord),
        currentCoordinationParentRef: session_ref(coord)
      }
    end)
  end

  defp valid_key?(key),
    do: is_binary(key) and String.trim(key) != "" and String.length(key) <= 200

  defp session_ref(nil), do: nil
  defp session_ref(key), do: "session:" <> key
  defp refusal(code), do: %{ok: false, code: code, message: code}
end
