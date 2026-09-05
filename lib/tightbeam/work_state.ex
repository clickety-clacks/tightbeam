defmodule Tightbeam.WorkState do
  @moduledoc "Grain-agnostic, query-time work observability."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS work_state_events (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           INTEGER NOT NULL,
    assignmentId TEXT    NOT NULL REFERENCES assignments(id),
    fromState    TEXT,
    toState      TEXT    NOT NULL,
    CHECK (fromState IS NULL OR fromState IN
      ('open','active','stranded','claims-done','verified','abandoned')),
    CHECK (toState IN
      ('open','active','stranded','claims-done','verified','abandoned'))
  );
  CREATE INDEX IF NOT EXISTS work_state_events_assignment
    ON work_state_events (assignmentId, id);

  CREATE TABLE IF NOT EXISTS work_item_events (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           INTEGER NOT NULL,
    workItemId   TEXT    NOT NULL REFERENCES work_items(id),
    kind         TEXT    NOT NULL,
    CHECK (kind IN ('metadata','composition'))
  );
  CREATE INDEX IF NOT EXISTS work_item_events_item
    ON work_item_events (workItemId, id);
  """

  @assignment_columns """
  a.id, a.subject, a.holderKey, a.holderRole, a.holderFallback,
  a.openedByUser, a.openedBySession, a.openedAt, a.state, a.outcome,
  a.closedAt, a.closedByUser, a.closedBySession, a.closingAttestId,
  (SELECT r.reason FROM assignment_revocation_generations g
    JOIN assignment_revocations r ON r.id = g.revocationId
    WHERE g.assignmentId = a.id AND g.reopeningId IS (
      SELECT reopening.id FROM assignment_reopenings reopening
      WHERE reopening.assignmentId = a.id
      ORDER BY reopening.id DESC LIMIT 1
    )),
  a.workItemId, s.state,
  CASE
    WHEN a.state = 'closed' AND a.outcome IN ('surrendered', 'revoked') THEN 'abandoned'
    WHEN a.state = 'closed' AND a.outcome = 'completed' AND EXISTS (
      SELECT 1 FROM attests v
      WHERE v.assignmentId = a.id AND v.kind = 'verdict' AND v.verdictKind = 'verified'
    ) THEN 'verified'
    WHEN a.state = 'closed' AND a.outcome = 'completed' THEN 'claims-done'
    WHEN a.state = 'open' AND s.state = 'retired' THEN 'stranded'
    WHEN a.state = 'open' AND NOT EXISTS (
      SELECT 1 FROM attests f WHERE f.assignmentId = a.id
    ) THEN 'open'
    ELSE 'active'
  END,
  COALESCE(
    (SELECT priority FROM assignment_priorities WHERE assignmentId=a.id),
    (SELECT priority FROM work_item_priorities WHERE workItemId=a.workItemId),
    CAST(COALESCE((SELECT value FROM org_settings WHERE key='default-priority'),'4') AS INTEGER)
  )
  """

  @doc "Create both observability doorbell tables."
  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Derive one assignment's current work state, or nil when unknown."
  @spec status(DB.server(), String.t()) :: String.t() | nil
  def status(db, assignment_id) do
    case DB.query(db, assignment_query("a.id = ?1"), [assignment_id]) do
      {:ok, [row]} -> row |> assignment() |> Map.fetch!(:status)
      {:ok, []} -> nil
    end
  end

  @doc "Return an atomic assignment-grain snapshot."
  @spec list(DB.server(), map()) :: %{work: [map()], cursor: non_neg_integer()}
  def list(db, filters) do
    transaction(db, fn txn ->
      work =
        txn
        |> assignment_rows(filters)
        |> Enum.map(fn row -> row |> assignment() |> project_assignment(txn) end)

      %{work: work, cursor: cursor(txn, "work_state_events")}
    end)
  end

  @doc "Return an atomic assignment detail snapshot, or nil."
  @spec detail(DB.server(), String.t()) :: map() | nil
  def detail(db, assignment_id) do
    transaction(db, fn txn ->
      case Txn.q(txn, assignment_query("a.id = ?1"), [assignment_id]) do
        [] ->
          nil

        [row] ->
          assignment = row |> assignment() |> project_assignment(txn)

          %{
            assignment: assignment,
            attests: attests(txn, assignment_id),
            supervision: supervision(txn, assignment_id),
            holder: holder(txn, assignment.holderKey),
            cursor: cursor(txn, "work_state_events")
          }
      end
    end)
  end

  @doc "Return an atomic work-item-grain snapshot with both cursors."
  @spec list_items(DB.server(), map()) :: %{items: [map()], cursor: map()}
  def list_items(db, filters) do
    transaction(db, fn txn ->
      items =
        txn
        |> item_rows(filters)
        |> Enum.map(fn row ->
          item = row |> work_item() |> project_work_item(txn)
          %{workItem: item, assignments: assignments_for_item(txn, item.id)}
        end)

      %{items: items, cursor: cursors(txn)}
    end)
  end

  @doc "Return an atomic work-item detail snapshot, or nil."
  @spec item_detail(DB.server(), String.t()) :: map() | nil
  def item_detail(db, work_item_id) do
    transaction(db, fn txn ->
      case Txn.q(txn, "SELECT #{item_columns()} FROM work_items WHERE id = ?1", [work_item_id]) do
        [] ->
          nil

        [row] ->
          %{
            workItem: row |> work_item() |> project_work_item(txn),
            assignments: assignments_for_item(txn, work_item_id),
            cursor: cursors(txn)
          }
      end
    end)
  end

  @doc "Insert an assignment doorbell iff the derived state changed."
  @spec emit(DB.server(), String.t(), String.t() | nil) :: map() | nil
  def emit(db, assignment_id, from) do
    transaction(db, fn txn ->
      to = status_in_txn(txn, assignment_id)

      if is_nil(to) or (not is_nil(from) and from == to) do
        nil
      else
        ts = System.system_time(:millisecond)

        Txn.q(
          txn,
          "INSERT INTO work_state_events (ts, assignmentId, fromState, toState) VALUES (?1, ?2, ?3, ?4)",
          [ts, assignment_id, from, to]
        )

        [[id]] = Txn.q(txn, "SELECT last_insert_rowid()")

        [[session_key]] =
          Txn.q(
            txn,
            "SELECT holderKey FROM assignments WHERE id = ?1",
            [assignment_id]
          )

        %{
          assignmentId: assignment_id,
          sessionKey: session_key,
          fromState: from,
          toState: to,
          cursor: id,
          ts: ts
        }
      end
    end)
  end

  @doc "Insert and return one work-item doorbell."
  @spec emit_item(DB.server(), String.t(), String.t()) :: map()
  def emit_item(db, work_item_id, kind) do
    ts = System.system_time(:millisecond)

    id =
      transaction(db, fn txn ->
        Txn.q(
          txn,
          "INSERT INTO work_item_events (ts, workItemId, kind) VALUES (?1, ?2, ?3)",
          [ts, work_item_id, kind]
        )

        [[id]] = Txn.q(txn, "SELECT last_insert_rowid()")
        id
      end)

    %{workItemId: work_item_id, kind: kind, cursor: id, ts: ts}
  end

  defp assignment_rows(txn, filters) do
    rows = Txn.q(txn, assignment_query("1 = 1"))
    state = Map.get(filters, :state, "all")
    statuses = Map.get(filters, :status)
    holder = Map.get(filters, :session_key)
    owner = Map.get(filters, :owner_user_id)

    Enum.filter(rows, fn row ->
      assignment = assignment(row)

      (state == "all" or assignment.state == state) and
        (is_nil(statuses) or assignment.status in statuses) and
        (is_nil(holder) or assignment.holderKey == holder) and
        (is_nil(owner) or assignment_owner(txn, assignment.id) == owner)
    end)
  end

  defp item_rows(txn, filters) do
    session_key = Map.get(filters, :session_key)
    owner = Map.get(filters, :owner_user_id)

    Txn.q(txn, "SELECT #{item_columns()} FROM work_items ORDER BY createdAt DESC, id DESC")
    |> Enum.filter(fn row ->
      item = work_item(row)

      # Owner visibility (observability-v1 amendment): an item is visible to its
      # ownerUserId regardless of assignments — an unassigned item still reaches
      # its owner. The assignment-holder path stays for non-owner visibility.
      (is_nil(session_key) or item_has_holder?(txn, item.id, session_key)) and
        (is_nil(owner) or item.ownerUserId == owner or item_has_owner?(txn, item.id, owner))
    end)
  end

  defp assignments_for_item(txn, work_item_id) do
    Txn.q(txn, assignment_query("a.workItemId = ?1"), [work_item_id])
    |> Enum.map(fn row -> row |> assignment() |> project_assignment(txn) end)
  end

  defp assignment_owner(txn, assignment_id) do
    [[owner]] =
      Txn.q(
        txn,
        "SELECT s.ownerUserId FROM assignments a JOIN sessions s ON s.sessionKey = a.holderKey WHERE a.id = ?1",
        [assignment_id]
      )

    owner
  end

  defp item_has_holder?(txn, item_id, session_key) do
    Txn.q(txn, "SELECT 1 FROM assignments WHERE workItemId = ?1 AND holderKey = ?2 LIMIT 1", [
      item_id,
      session_key
    ]) != []
  end

  defp item_has_owner?(txn, item_id, owner) do
    Txn.q(
      txn,
      "SELECT 1 FROM assignments a JOIN sessions s ON s.sessionKey = a.holderKey WHERE a.workItemId = ?1 AND s.ownerUserId = ?2 LIMIT 1",
      [item_id, owner]
    ) != []
  end

  defp attests(txn, assignment_id) do
    Txn.q(
      txn,
      "SELECT id, assignmentId, kind, verdictKind, note, bySession, byUser, ts FROM attests WHERE assignmentId = ?1 ORDER BY ts ASC, id ASC",
      [assignment_id]
    )
    |> Enum.map(fn [id, assignment_id, kind, verdict_kind, note, by_session, by_user, ts] ->
      %{
        id: id,
        assignmentId: assignment_id,
        kind: kind,
        verdictKind: verdict_kind,
        note: note,
        bySession: by_session,
        byUser: by_user,
        ts: ts,
        deliverableClaim: Tightbeam.DeliverableContract.attest_claim_projection_in_txn(txn, id)
      }
    end)
  end

  defp supervision(txn, assignment_id) do
    case Txn.q(
           txn,
           "SELECT assignmentId, attemptCount, prodCount, deniedStreak, attestCount, lastProdAt, stalledAt, strandedAt FROM assignment_prods WHERE assignmentId = ?1",
           [assignment_id]
         ) do
      [] ->
        nil

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
    end
  end

  defp holder(txn, session_key) do
    [[key, state, display_name]] =
      Txn.q(txn, "SELECT sessionKey, state, displayName FROM sessions WHERE sessionKey = ?1", [
        session_key
      ])

    %{sessionKey: key, state: state, displayName: display_name}
  end

  defp status_in_txn(txn, assignment_id) do
    case Txn.q(txn, assignment_query("a.id = ?1"), [assignment_id]) do
      [row] -> row |> assignment() |> Map.fetch!(:status)
      [] -> nil
    end
  end

  defp cursors(txn) do
    %{assignment: cursor(txn, "work_state_events"), workItem: cursor(txn, "work_item_events")}
  end

  defp cursor(txn, table) do
    [[value]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM #{table}")
    value
  end

  defp assignment_query(where) do
    "SELECT #{@assignment_columns} FROM assignments a JOIN sessions s ON s.sessionKey = a.holderKey " <>
      "WHERE #{where} ORDER BY a.openedAt DESC, a.id DESC"
  end

  defp item_columns,
    do:
      "id, title, specRefName, specRefSha256, isBug, ownerUserId, state, failReason, " <>
        "createdByUser, createdBySession, createdAt, " <>
        "COALESCE((SELECT priority FROM work_item_priorities p WHERE p.workItemId=work_items.id), " <>
        "CAST(COALESCE((SELECT value FROM org_settings WHERE key='default-priority'),'4') AS INTEGER)), " <>
        "COALESCE((SELECT rowVersion FROM work_item_versions WHERE workItemId=work_items.id), createdAt)"

  defp assignment([
         id,
         subject,
         holder_key,
         holder_role,
         holder_fallback,
         opened_by_user,
         opened_by_session,
         opened_at,
         state,
         outcome,
         closed_at,
         closed_by_user,
         closed_by_session,
         closing_attest_id,
         revocation_reason,
         work_item_id,
         holder_state,
         status,
         priority
       ]) do
    %{
      id: id,
      subject: subject,
      holderKey: holder_key,
      holderRole: holder_role,
      holderFallback: holder_fallback == 1,
      openedByUser: opened_by_user,
      openedBySession: opened_by_session,
      openedAt: opened_at,
      state: state,
      outcome: outcome,
      closedAt: closed_at,
      closedByUser: closed_by_user,
      closedBySession: closed_by_session,
      closingAttestId: closing_attest_id,
      revocationReason: revocation_reason,
      workItemId: work_item_id,
      holderState: holder_state,
      status: status,
      priority: priority
    }
  end

  defp work_item([
         id,
         title,
         spec_ref_name,
         spec_ref_sha256,
         is_bug,
         owner_user_id,
         state,
         fail_reason,
         user,
         session,
         created_at,
         priority,
         row_version
       ]) do
    %{
      id: id,
      title: title,
      specRefName: spec_ref_name,
      specRefSha256: spec_ref_sha256,
      isBug: is_bug == 1,
      ownerUserId: owner_user_id,
      state: state,
      failReason: fail_reason,
      createdByUser: user,
      createdBySession: session,
      createdAt: created_at,
      priority: priority,
      rowVersion: row_version
    }
  end

  defp project_assignment(assignment, txn) do
    Map.merge(
      assignment,
      Tightbeam.DeliverableContract.assignment_projection_in_txn(txn, assignment.id)
    )
  end

  defp project_work_item(item, txn) do
    Map.merge(
      item,
      Tightbeam.DeliverableContract.work_item_projection_in_txn(txn, item.id)
    )
  end

  defp transaction(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
