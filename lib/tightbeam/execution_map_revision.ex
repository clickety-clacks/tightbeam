defmodule Tightbeam.ExecutionMapRevision do
  @moduledoc false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  def token(txn, principal, cutoff) do
    scope =
      if principal.kind == "session" or principal.is_admin,
        do: "admin",
        else: "user:" <> principal.id

    revision =
      case Txn.q(txn, "SELECT revision FROM execution_map_revisions WHERE scope = ?1", [scope]) do
        [[value]] -> value
        [] -> 0
      end

    JSON.encode!(["execution-map-revision-v1", scope, revision, cutoff])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def ensure_schema(db) do
    sql =
      """
      CREATE TABLE IF NOT EXISTS execution_map_revisions (
        scope TEXT PRIMARY KEY,
        revision INTEGER NOT NULL
      ) WITHOUT ROWID;
      """ <> Enum.map_join(sources(), "\n", &triggers/1)

    case DB.transaction(db, fn txn -> Txn.exec(txn, sql) end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  # Every branch selects a fixed number of owner keys. Indirect ownership is
  # through primary keys only, including OLD and NEW on ownership changes.
  defp sources do
    [
      {"work_items", fn row -> selects(["#{row}.ownerUserId"]) end, nil},
      {"work_item_versions", fn row -> selects([item_owner("#{row}.workItemId")]) end, nil},
      {"assignments",
       fn row -> selects(["#{row}.openedByUser", item_owner("#{row}.workItemId")]) end, nil},
      {"attests", &assignment_owners/1, nil},
      {"subagent_markers", &assignment_owners/1, nil},
      {"causal_events", fn row -> selects([item_owner("#{row}.jobRef")]) end,
       fn row -> "#{row}.kind = 'disposition_transition'" end},
      {"turns", &turn_owner/1,
       fn row -> "#{row}.jobRef IS NOT NULL OR #{row}.assignmentId IS NOT NULL" end},
      {"wakes",
       fn row ->
         selects([session_owner("#{row}.sessionKey"), session_owner("#{row}.creatorSessionKey")])
       end, fn row -> "#{row}.state = 'pending' AND #{row}.consumer = 'prompt'" end},
      {"decision_requests", &request_owners/1,
       fn row -> "#{row}.status = 'open' AND #{row}.kind IN ('statute', 'effort')" end},
      {"sessions", fn row -> selects(["#{row}.ownerUserId"]) end, nil},
      {"users", fn row -> selects(["#{row}.userId"]) end, nil},
      {"admin_projection_versions", fn row -> selects(["#{row}.primaryKey"]) end,
       fn row -> "#{row}.resource = 'users'" end}
    ]
  end

  defp triggers({table, owners, visible}) do
    Enum.map_join(
      [{"INSERT", ["NEW"]}, {"UPDATE", ["OLD", "NEW"]}, {"DELETE", ["OLD"]}],
      "\n",
      fn {event, rows} ->
        guards = if visible, do: Enum.map(rows, &("(" <> visible.(&1) <> ")")), else: []
        condition = if guards == [], do: "", else: "WHEN " <> Enum.join(guards, " OR ")

        user_rows =
          Enum.map_join(rows, " UNION ", fn row ->
            """
            SELECT 'user:' || owner FROM (#{owners.(row)}) AS affected
            WHERE owner IS NOT NULL #{if visible, do: "AND (#{visible.(row)})", else: ""}
            """
          end)

        """
        CREATE TRIGGER IF NOT EXISTS execution_map_revision_#{table}_#{String.downcase(event)}
        AFTER #{event} ON #{table}
        #{condition}
        BEGIN
          INSERT INTO execution_map_revisions(scope, revision)
          SELECT scope, 1 FROM (
            SELECT 'admin' AS scope UNION #{user_rows}
          ) WHERE 1
          ON CONFLICT(scope) DO UPDATE SET revision = revision + 1;
        END;
        """
      end
    )
  end

  defp selects(expressions),
    do: Enum.map_join(expressions, " UNION ", &"SELECT #{&1} AS owner")

  defp item_owner(expression),
    do: "(SELECT ownerUserId FROM work_items WHERE id = #{expression})"

  defp session_owner(expression),
    do: "(SELECT ownerUserId FROM sessions WHERE sessionKey = #{expression})"

  defp assignment_owners(row) do
    """
    SELECT a.openedByUser AS owner FROM assignments AS a WHERE a.id = #{row}.assignmentId
    UNION
    SELECT wi.ownerUserId FROM assignments AS a
    JOIN work_items AS wi ON wi.id = a.workItemId WHERE a.id = #{row}.assignmentId
    """
  end

  defp turn_owner(row) do
    """
    SELECT s.ownerUserId AS owner FROM sessions AS s WHERE s.sessionKey = #{row}.sessionKey
      AND (
        EXISTS (SELECT 1 FROM work_items AS wi
                WHERE wi.id = #{row}.jobRef AND wi.ownerUserId = s.ownerUserId)
        OR EXISTS (
          SELECT 1 FROM assignments AS a LEFT JOIN work_items AS wi ON wi.id = a.workItemId
          WHERE a.id = #{row}.assignmentId
            AND (a.openedByUser = s.ownerUserId OR wi.ownerUserId = s.ownerUserId)
        )
      )
    """
  end

  defp request_owners(row) do
    """
    SELECT #{row}.ownerUserId AS owner WHERE #{row}.kind = 'statute'
    UNION SELECT substr(#{row}.raiserId, 6)
      WHERE #{row}.kind = 'statute' AND #{row}.raiserId LIKE 'user:%'
    UNION SELECT #{row}.expecterUserId WHERE #{row}.kind = 'effort'
    UNION SELECT s.ownerUserId
      FROM assignments AS a JOIN sessions AS s ON s.sessionKey = a.holderKey
      WHERE #{row}.kind = 'effort' AND a.id = #{row}.assignmentId
    """
  end
end
