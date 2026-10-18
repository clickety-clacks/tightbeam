defmodule Tightbeam.RowReactions.Store do
  @moduledoc false
  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.Plan

  @ddl """
  CREATE TABLE row_reaction_events (
    org TEXT NOT NULL,
    eventId TEXT NOT NULL,
    version INTEGER NOT NULL CHECK(version=1),
    event TEXT NOT NULL,
    facts TEXT NOT NULL,
    admittedAt INTEGER NOT NULL,
    PRIMARY KEY(org,eventId)
  );
  CREATE TABLE row_reaction_actions (
    id TEXT PRIMARY KEY,
    org TEXT NOT NULL,
    eventId TEXT NOT NULL,
    family TEXT NOT NULL,
    slot TEXT NOT NULL,
    plan TEXT NOT NULL,
    payloadDigest TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('pending','accepted','canceled','held')),
    attempts INTEGER NOT NULL DEFAULT 0,
    lastAttemptAt INTEGER,
    lastError TEXT,
    result TEXT,
    updatedAt INTEGER NOT NULL,
    UNIQUE(org,family,eventId,slot),
    FOREIGN KEY(org,eventId) REFERENCES row_reaction_events(org,eventId)
  );
  CREATE INDEX row_reaction_pending ON row_reaction_actions(status,org,eventId);
  """

  def ensure_schema(db) do
    case DB.transaction(db, fn txn ->
           migration = "row-reactions/v1"

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

           case Txn.q(
                  txn,
                  "SELECT 1 FROM supervision_liveness_migrations WHERE migrationId='row-reactions/cutovers-v1'"
                ) do
             [[1]] ->
               :ok

             [] ->
               :ok =
                 Txn.exec(
                   txn,
                   "CREATE TABLE row_reaction_cutovers(source TEXT PRIMARY KEY,watermark TEXT NOT NULL,adoptedAt INTEGER NOT NULL,heldCount INTEGER NOT NULL)"
                 )

               Txn.q(
                 txn,
                 "INSERT INTO supervision_liveness_migrations(migrationId,appliedAt,affectedRows,cause,principal) VALUES('row-reactions/cutovers-v1',?1,0,'release_upgrade','process:tightbeam')",
                 [System.system_time(:millisecond)]
               )

               :ok
           end

           case Txn.q(
                  txn,
                  "SELECT 1 FROM supervision_liveness_migrations WHERE migrationId='row-reactions/addressed-snapshots-v1'"
                ) do
             [[1]] ->
               :ok

             [] ->
               :ok =
                 Txn.exec(txn, """
                 CREATE INDEX row_reaction_request ON row_reaction_events(org,
                   COALESCE(json_extract(event,'$.requestId'),CASE WHEN json_extract(event,'$.kind')='decision_request' THEN json_extract(event,'$.after.id') END));
                 CREATE INDEX row_reaction_output ON row_reaction_actions(json_extract(result,'$.wake_id'));
                 CREATE INDEX row_reaction_source ON row_reaction_actions(org,eventId);
                 CREATE INDEX reaction_first_receipt ON attests(assignmentId,kind,verdictKind,ts,id);
                 CREATE INDEX reaction_disposition ON attests(bySession,kind,note);
                 CREATE INDEX reaction_first_start ON turns(assignmentId,sessionKey,startedAt,seq) WHERE startedAt IS NOT NULL;
                 CREATE INDEX reaction_open_assignments ON assignments(holderKey,state,workItemId,openedAt,id);
                 """)

               Txn.q(
                 txn,
                 "INSERT INTO supervision_liveness_migrations(migrationId,appliedAt,affectedRows,cause,principal) VALUES('row-reactions/addressed-snapshots-v1',?1,0,'release_upgrade','process:tightbeam')",
                 [System.system_time(:millisecond)]
               )
           end

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  # The caller owns the source-write transaction. Admission, including an empty
  # election, is recorded once, so replay cannot turn historical rows into work.
  def admit_in_txn(%Txn{} = txn, event, facts, rails, at) do
    org = Map.fetch!(event, "org")
    event_id = Map.fetch!(event, "id")

    case Txn.q(txn, "SELECT event FROM row_reaction_events WHERE org=?1 AND eventId=?2", [
           org,
           event_id
         ]) do
      [[stored]] ->
        unless JSON.decode!(stored) == event,
          do: raise(ArgumentError, "source event identity reused for different transition")

        actions_in_txn(txn, org, event_id)

      [] ->
        plans = Plan.evaluate(rails, event, Map.put(facts, "original", facts))

        Txn.q(
          txn,
          "INSERT INTO row_reaction_events(org,eventId,version,event,facts,admittedAt) VALUES(?1,?2,1,?3,?4,?5)",
          [org, event_id, JSON.encode!(event), JSON.encode!(facts), at]
        )

        Enum.each(plans, &insert_in_txn(txn, &1, at))
        actions_in_txn(txn, org, event_id)
    end
  end

  # Adoption links a historical effect; it never evaluates or schedules it.
  def adopt_in_txn(txn, event, facts, plan, result, status, at)
      when status in ~w(pending accepted canceled held) do
    org = event["org"]
    event_id = event["id"]

    case Txn.q(txn, "SELECT 1 FROM row_reaction_events WHERE org=?1 AND eventId=?2", [
           org,
           event_id
         ]) do
      [] ->
        Txn.q(
          txn,
          "INSERT INTO row_reaction_events(org,eventId,version,event,facts,admittedAt) VALUES(?1,?2,1,?3,?4,?5)",
          [org, event_id, JSON.encode!(event), JSON.encode!(facts), at]
        )

        insert_in_txn(txn, plan, at)

        Txn.q(txn, "UPDATE row_reaction_actions SET result=?2,status=?3 WHERE id=?1", [
          action_id(plan),
          JSON.encode!(result),
          status
        ])

        :ok

      _ ->
        raise ArgumentError, "legacy reaction event already exists without its cutover watermark"
    end
  end

  # Revisions change only already pending work. New slots, accepted work, and
  # canceled work cannot be resurrected by replay or rollback to an older rail.
  def reconcile_in_txn(%Txn{} = txn, org, event_id, rails, at, current_facts \\ :recorded) do
    [[event, facts]] =
      Txn.q(txn, "SELECT event,facts FROM row_reaction_events WHERE org=?1 AND eventId=?2", [
        org,
        event_id
      ])

    recorded = JSON.decode!(facts)
    original = recorded
    facts = if current_facts == :recorded, do: recorded, else: current_facts
    facts = Map.put(facts, "original", original)
    plans = Plan.evaluate(rails, JSON.decode!(event), facts) |> Map.new(&{action_id(&1), &1})
    withdrawals = Plan.withdrawals(rails, JSON.decode!(event), facts)

    for action <- actions_in_txn(txn, org, event_id), action["status"] == "pending" do
      case Map.get(plans, action["id"]) do
        nil ->
          Txn.q(
            txn,
            "UPDATE row_reaction_actions SET status='canceled',updatedAt=?2,plan=?3 WHERE id=?1 AND status='pending'",
            [
              action["id"],
              at,
              JSON.encode!(
                Map.put(
                  action["plan"],
                  "withdraw",
                  Map.get(withdrawals, List.to_tuple(action["plan"]["identity"]))
                )
              )
            ]
          )

        plan ->
          Txn.q(
            txn,
            "UPDATE row_reaction_actions SET plan=?2,payloadDigest=?3,updatedAt=?4 WHERE id=?1 AND status='pending'",
            [action["id"], encode_plan(plan), digest(plan.value), at]
          )
      end
    end

    actions_in_txn(txn, org, event_id)
  end

  def actions_in_txn(%Txn{} = txn, org, event_id) do
    Txn.q(
      txn,
      "SELECT id,plan,status,attempts,lastError,result FROM row_reaction_actions WHERE org=?1 AND eventId=?2 ORDER BY id",
      [org, event_id]
    )
    |> Enum.map(fn [id, plan, status, attempts, error, result] ->
      %{
        "id" => id,
        "plan" => JSON.decode!(plan),
        "status" => status,
        "attempts" => attempts,
        "last_error" => error,
        "result" => if(result, do: JSON.decode!(result))
      }
    end)
  end

  # Call only in the same transaction as the actual accepted effect. A failed
  # transaction rolls both back; persistence never relies on a process callback.
  def accept_in_txn(%Txn{} = txn, id, result, at) do
    Txn.q(
      txn,
      "UPDATE row_reaction_actions SET status='accepted',result=?2,attempts=attempts+1,lastAttemptAt=?3,lastError=NULL,updatedAt=?3 WHERE id=?1 AND status='pending'",
      [id, JSON.encode!(result), at]
    )

    Txn.changes(txn) == 1
  end

  # An explicit recovery command has already admitted a new linked transport.
  # Preserve the semantic action identity and old output history. Reconciliation
  # alone never enters this path, and command replay must not call it again.
  def link_recovery_in_txn(txn, previous_id, successor_id, principal, at) do
    for [id, encoded_plan, encoded_result] <-
          Txn.q(
            txn,
            "SELECT id,plan,result FROM row_reaction_actions WHERE json_extract(result,'$.wake_id')=?1 AND status IN ('pending','accepted','canceled')",
            [previous_id]
          ) do
      plan = JSON.decode!(encoded_plan)
      result = JSON.decode!(encoded_result)

      result =
        result
        |> Map.put("wake_id", successor_id)
        |> Map.put("elected_wake_id", plan["value"]["wake_id"])
        |> Map.put("recovery", %{
          "principal" => principal,
          "at" => at,
          "previous_wake_id" => previous_id
        })
        |> Map.update("previous_wake_ids", [previous_id], &Enum.uniq(&1 ++ [previous_id]))

      Txn.q(
        txn,
        "UPDATE row_reaction_actions SET status='pending',result=?2,updatedAt=?3 WHERE id=?1",
        [id, JSON.encode!(result), at]
      )
    end

    :ok
  end

  def failure_in_txn(%Txn{} = txn, id, error, at) do
    Txn.q(
      txn,
      "UPDATE row_reaction_actions SET attempts=attempts+1,lastAttemptAt=?3,lastError=?2,updatedAt=?3 WHERE id=?1 AND status='pending'",
      [id, error, at]
    )

    :ok
  end

  def pending_result_in_txn(%Txn{} = txn, id, result, at) do
    Txn.q(
      txn,
      "UPDATE row_reaction_actions SET result=?2,lastError=NULL,updatedAt=?3 WHERE id=?1 AND status='pending'",
      [id, JSON.encode!(result), at]
    )

    :ok
  end

  def cancel_pending_in_txn(%Txn{} = txn, id, at) do
    Txn.q(
      txn,
      "UPDATE row_reaction_actions SET status='canceled',updatedAt=?2 WHERE id=?1 AND status='pending'",
      [id, at]
    )

    :ok
  end

  def skip_in_txn(%Txn{} = txn, id) do
    Txn.q(
      txn,
      "DELETE FROM row_reaction_actions WHERE id=?1 AND status='pending' AND result IS NULL",
      [id]
    )

    :ok
  end

  def action_id(plan), do: "reaction_" <> digest(Tuple.to_list(plan.identity))

  defp insert_in_txn(txn, plan, at) do
    {org, family, event_id, slot} = plan.identity

    Txn.q(
      txn,
      "INSERT INTO row_reaction_actions(id,org,eventId,family,slot,plan,payloadDigest,status,updatedAt) VALUES(?1,?2,?3,?4,?5,?6,?7,'pending',?8)",
      [action_id(plan), org, event_id, family, slot, encode_plan(plan), digest(plan.value), at]
    )
  end

  defp encode_plan(plan), do: JSON.encode!(Map.update!(plan, :identity, &Tuple.to_list/1))

  defp digest(value),
    do: :crypto.hash(:sha256, JSON.encode!(value)) |> Base.encode16(case: :lower)
end
