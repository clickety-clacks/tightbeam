defmodule Tightbeam.RowReactions.Store do
  @moduledoc false
  alias Tightbeam.{DB, Rules}
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE row_reaction_events (
    org TEXT NOT NULL, eventId TEXT NOT NULL, version INTEGER NOT NULL CHECK(version=1),
    event TEXT NOT NULL, facts TEXT NOT NULL, admittedAt INTEGER NOT NULL,
    PRIMARY KEY(org,eventId)
  );
  CREATE TABLE row_reaction_actions (
    id TEXT PRIMARY KEY, org TEXT NOT NULL, eventId TEXT NOT NULL,
    family TEXT NOT NULL, slot TEXT NOT NULL, plan TEXT NOT NULL,
    payloadDigest TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('pending','accepted','canceled','held')),
    result TEXT, attempts INTEGER NOT NULL DEFAULT 0, lastError TEXT, updatedAt INTEGER NOT NULL,
    UNIQUE(org,family,eventId,slot),
    FOREIGN KEY(org,eventId) REFERENCES row_reaction_events(org,eventId)
  );
  CREATE INDEX row_reaction_pending ON row_reaction_actions(status,org,eventId);
  CREATE INDEX row_reaction_output ON row_reaction_actions(json_extract(result,'$.wake_id'));
  CREATE TABLE row_reaction_cutovers (
    source TEXT PRIMARY KEY, watermark TEXT NOT NULL, adoptedAt INTEGER NOT NULL,
    heldCount INTEGER NOT NULL
  );
  """

  def ensure_schema(db) do
    case DB.transaction(db, fn txn ->
           migration = "terminal-row-reactions/v1"

           case Txn.q(txn, "SELECT 1 FROM supervision_liveness_migrations WHERE migrationId=?1", [
                  migration
                ]) do
             [[1]] ->
               :ok

             [] ->
               :ok = Txn.exec(txn, @ddl)

               Txn.q(
                 txn,
                 "INSERT INTO supervision_liveness_migrations(migrationId,appliedAt,affectedRows,cause,principal) VALUES(?1,?2,0,'release_upgrade','process:tightbeam')",
                 [migration, System.system_time(:millisecond)]
               )

               :ok
           end

           Process.put({Tightbeam.RowReactions, txn.conn}, true)
           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  # Includes an empty election: later publication cannot resurrect an event
  # that created no action. Caller supplies its actual source-write transaction.
  def admit(txn, event, facts) do
    case event(txn, event["org"], event["id"]) do
      nil ->
        put_event(txn, event, facts)

        for plan <- Rules.reaction_plans(event, Map.put(facts, "original", facts)),
            plan.selected,
            do: insert(txn, plan, "pending", nil, event["at"])

      {stored, _facts} ->
        unless stored == event, do: raise(ArgumentError, "reaction source identity conflict")
    end

    actions(txn, event["org"], event["id"])
  end

  def adopt(txn, event, facts, plan, status, result, at) do
    if is_nil(event(txn, event["org"], event["id"])), do: put_event(txn, event, facts)
    insert(txn, plan, status, result, at)
  end

  def remember(txn, event, facts), do: put_event(txn, event, facts)

  def reconcile(txn, event, original, current, at) do
    plans =
      Rules.reaction_plans(event, Map.put(current, "original", original))
      |> Map.new(&{id(&1.identity), &1})

    for action <- actions(txn, event["org"], event["id"]), action["status"] == "pending" do
      case Map.get(plans, action["id"]) do
        %{selected: true} = plan ->
          Txn.q(
            txn,
            "UPDATE row_reaction_actions SET plan=?2,payloadDigest=?3,updatedAt=?4 WHERE id=?1 AND status='pending'",
            [action["id"], JSON.encode!(plan), digest(plan.value), at]
          )

        plan ->
          withdrawn = Map.put(action["plan"], "withdraw", plan && plan.withdraw)

          Txn.q(
            txn,
            "UPDATE row_reaction_actions SET plan=?2,status='canceled',updatedAt=?3 WHERE id=?1 AND status='pending'",
            [action["id"], JSON.encode!(withdrawn), at]
          )
      end
    end

    actions(txn, event["org"], event["id"])
  end

  def event(txn, org, id) do
    case Txn.q(txn, "SELECT event,facts FROM row_reaction_events WHERE org=?1 AND eventId=?2", [
           org,
           id
         ]) do
      [] -> nil
      [[event, facts]] -> {JSON.decode!(event), JSON.decode!(facts)}
    end
  end

  def actions(txn, org, event_id) do
    Txn.q(
      txn,
      "SELECT id,plan,status,result,lastError FROM row_reaction_actions INDEXED BY row_reaction_pending WHERE status IN ('pending','accepted','canceled','held') AND org=?1 AND eventId=?2 ORDER BY id",
      [org, event_id]
    )
    |> Enum.map(fn [id, plan, status, result, error] ->
      %{
        "id" => id,
        "plan" => JSON.decode!(plan),
        "status" => status,
        "result" => if(result, do: JSON.decode!(result)),
        "error" => error
      }
    end)
  end

  def pending_events(txn) do
    Txn.q(txn, """
    SELECT DISTINCT e.event,e.facts FROM row_reaction_actions a INDEXED BY row_reaction_pending
    JOIN row_reaction_events e ON e.org=a.org AND e.eventId=a.eventId
    WHERE a.status='pending' ORDER BY e.admittedAt,e.eventId
    """)
    |> Enum.map(fn [event, facts] -> {JSON.decode!(event), JSON.decode!(facts)} end)
  end

  def output_event(txn, wake_id) do
    case Txn.q(
           txn,
           """
           SELECT e.event,e.facts FROM row_reaction_actions a
           JOIN row_reaction_events e ON e.org=a.org AND e.eventId=a.eventId
           WHERE json_extract(a.result,'$.wake_id')=?1
           """,
           [wake_id]
         ) do
      [] -> nil
      [[event, facts]] -> {JSON.decode!(event), JSON.decode!(facts)}
      _ -> raise ArgumentError, "reaction output has multiple owners"
    end
  end

  def record(txn, action, status, result, at, error \\ nil) do
    Txn.q(
      txn,
      "UPDATE row_reaction_actions SET status=?2,result=?3,lastError=?4,attempts=attempts+1,updatedAt=?5 WHERE id=?1",
      [action["id"], status, JSON.encode!(result), error, at]
    )

    :ok
  end

  def id(identity), do: "reaction_" <> digest(identity)

  defp digest(value),
    do: :crypto.hash(:sha256, JSON.encode!(value)) |> Base.encode16(case: :lower)

  defp put_event(txn, event, facts) do
    Txn.q(
      txn,
      "INSERT INTO row_reaction_events(org,eventId,version,event,facts,admittedAt) VALUES(?1,?2,1,?3,?4,?5)",
      [event["org"], event["id"], JSON.encode!(event), JSON.encode!(facts), event["at"]]
    )
  end

  defp insert(txn, plan, status, result, at) do
    [org, family, event_id, slot] = plan.identity

    Txn.q(
      txn,
      """
      INSERT INTO row_reaction_actions(id,org,eventId,family,slot,plan,payloadDigest,status,result,updatedAt)
      VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
      """,
      [
        id(plan.identity),
        org,
        event_id,
        family,
        slot,
        JSON.encode!(plan),
        digest(plan.value),
        status,
        if(result, do: JSON.encode!(result)),
        at
      ]
    )
  end
end
