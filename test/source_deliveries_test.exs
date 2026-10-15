defmodule Tightbeam.SourceDeliveriesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, NoticeBatcher}

  # Direct turns, an included batch member with a delivery turn, a canceled
  # member, a member whose carrier has no turn yet, and an undelivered wake.
  setup do
    db = :"source_deliveries_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = DB.execute(db, "PRAGMA foreign_keys = OFF")

    wakes = [
      {"w_direct", "asg_a"},
      {"w_src_a", "asg_a"},
      {"w_src_b", "asg_b"},
      {"w_src_canceled", "asg_a"},
      {"w_src_unsent", "asg_b"},
      {"w_carrier", nil},
      {"w_carrier_unsent", nil},
      {"w_none", "asg_a"}
    ]

    for {wake_id, assignment_id} <- wakes do
      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO wakes (wakeId, sessionKey, origin, prompt, dueAt, createdAt, state, assignmentId)
          VALUES (?1, 'recipient', 'process:test', 'notice', 1, 1, 'fired', ?2)
          """,
          [wake_id, assignment_id]
        )
    end

    for {seq, wake_id, assignment_id} <- [{1, "w_direct", "asg_a"}, {2, "w_carrier", nil}] do
      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO turns (seq, sessionKey, messageId, wakeId, origin, prompt, assignmentId, status, createdAt)
          VALUES (?1, 'recipient', ?2, ?3, 'process:test', 'notice', ?4, 'delivered', 1)
          """,
          [seq, "msg-#{seq}", wake_id, assignment_id]
        )
    end

    for {batch_id, carrier, state} <- [
          {"b_delivered", "w_carrier", "delivered"},
          {"b_pending", "w_carrier_unsent", "delivery_pending"}
        ] do
      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO notice_batches
            (batchId, recipientAddress, sessionKey, visibilityScope, policyRevision, state,
             dueAt, openedAt, sealedAt, deliveryToken, envelope, deliveryWakeId)
          VALUES (?1, 'session:recipient', 'recipient', 'scope', 'r1', ?3, 1, 1, 1, ?1, 'e', ?2)
          """,
          [batch_id, carrier, state]
        )
    end

    members = [
      {"m1", "b_delivered", "w_src_a", 1, "included"},
      {"m2", "b_delivered", "w_src_b", 2, "included"},
      {"m3", "b_delivered", "w_src_canceled", 3, "canceled"},
      {"m4", "b_pending", "w_src_unsent", 4, "included"}
    ]

    for {member_id, batch_id, source, seq, state} <- members do
      {canceled_at, ref} = if state == "canceled", do: {1, "test"}, else: {nil, nil}

      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO notice_batch_members
            (memberId, batchId, sourceWakeId, policyRef, recipientAddress, visibilityScope,
             publicationSeq, policyRevision, senderPrincipal, cause, class, payload,
             renderedBytes, state, addedAt, canceledAt, cancellationRef)
          VALUES (?1, ?2, ?3, 'p', 'session:recipient', 'scope', ?4, 'r1', 'process:test',
                  'test', 'fyi', 'payload', 7, ?5, 1, ?6, ?7)
          """,
          [member_id, batch_id, source, seq, state, canceled_at, ref]
        )
    end

    :ok =
      DB.execute(
        db,
        "UPDATE wake_delivery_backfill SET afterRowid=0,throughRowid=(SELECT MAX(rowid) FROM wakes),completedAt=NULL"
      )

    %{db: db}
  end

  defp rows!(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    Enum.sort(rows)
  end

  test "backfill records direct and carried turns, excluding canceled and unsent members", ctx do
    assert :done = Tightbeam.Schema.backfill_wake_delivery(ctx.db)

    assert rows!(
             ctx.db,
             "SELECT wakeId,deliveredTurnSeq FROM wakes WHERE deliveredTurnSeq IS NOT NULL",
             []
           ) ==
             [["w_carrier", 2], ["w_direct", 1], ["w_src_a", 2], ["w_src_b", 2]]

    assert {:ok, [[2, "delivered", "asg_a"]]} =
             DB.transaction(ctx.db, &NoticeBatcher.source_delivery_turns_in_txn(&1, "w_src_a"))

    # Membership is metadata, not delivery authority after the stamp.
    :ok = DB.execute(ctx.db, "DELETE FROM notice_batch_members")

    assert {:ok, [[2, "delivered", "asg_a"]]} =
             DB.transaction(ctx.db, &NoticeBatcher.source_delivery_turns_in_txn(&1, "w_src_a"))

    assert {:ok, []} =
             DB.transaction(
               ctx.db,
               &NoticeBatcher.source_delivery_turns_in_txn(&1, "w_src_unsent")
             )

    assert {:ok, plan} =
             DB.query(
               ctx.db,
               "EXPLAIN QUERY PLAN SELECT wakeId FROM wakes WHERE deliveredTurnSeq=?1",
               [2]
             )

    assert Enum.any?(plan, &(List.last(&1) =~ "wakes_delivered_turn"))
  end

  test "a completed backfill skips historical rows on a second boot", ctx do
    assert :done = Tightbeam.Schema.backfill_wake_delivery(ctx.db)
    before = rows!(ctx.db, "SELECT * FROM wake_delivery_backfill", [])
    :ok = DB.execute(ctx.db, "UPDATE wakes SET deliveredTurnSeq=NULL WHERE wakeId='w_direct'")
    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
    assert :done = Tightbeam.Schema.backfill_wake_delivery(ctx.db)
    assert rows!(ctx.db, "SELECT * FROM wake_delivery_backfill", []) == before

    assert {:ok, []} =
             DB.transaction(ctx.db, &NoticeBatcher.source_delivery_turns_in_txn(&1, "w_direct"))
  end

  test "historical batches yield and resume from their recorded cursor", ctx do
    :ok = DB.execute(ctx.db, """
    WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<2100)
    INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt,state)
    SELECT 'old-' || x,'recipient','process:test','old',1,1,'fired' FROM n;
    UPDATE wake_delivery_backfill SET throughRowid=(SELECT MAX(rowid) FROM wakes);
    """)
    assert :more = Tightbeam.Schema.backfill_wake_delivery(ctx.db)
    assert {:ok, [[2000,nil]]} = DB.query(ctx.db, "SELECT afterRowid,completedAt FROM wake_delivery_backfill")
    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
    assert {:ok, [[2000,nil]]} = DB.query(ctx.db, "SELECT afterRowid,completedAt FROM wake_delivery_backfill")
    assert :done = Tightbeam.Schema.backfill_wake_delivery(ctx.db)
  end

  test "an existing database stamps pending and recent wakes before historical batches", ctx do
    # Reconstruct the additive predecessor. No application writes run during
    # this fixture-only downgrade.
    :ok =
      DB.execute(ctx.db, """
      DROP TRIGGER supervision_liveness_sidecar_insert_coherent;
      DROP INDEX wakes_delivered_turn;
      ALTER TABLE wakes DROP COLUMN deliveredTurnSeq;
      DROP TABLE wake_delivery_backfill;
      UPDATE wakes SET state='pending' WHERE wakeId='w_direct';
      """)

    at = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE wakes SET firedAt=?1 WHERE wakeId IN ('w_src_a','w_carrier')",
               [at]
             )

    assert :ok = Tightbeam.Schema.migrate_wake_delivery(ctx.db)

    assert rows!(
             ctx.db,
             "SELECT wakeId,deliveredTurnSeq FROM wakes WHERE deliveredTurnSeq IS NOT NULL",
             []
           ) ==
             [["w_carrier", 2], ["w_direct", 1], ["w_src_a", 2]]

    assert :done = Tightbeam.Schema.backfill_wake_delivery(ctx.db)
    assert rows!(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId='w_src_b'", []) == [[2]]
    assert :ok = Tightbeam.Schema.migrate_wake_delivery(ctx.db)
  end
end
