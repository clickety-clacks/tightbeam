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

    %{db: db, wake_ids: Enum.map(wakes, &elem(&1, 0))}
  end

  defp rows!(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    Enum.sort(rows)
  end

  defp plan!(db, sql, params) do
    {:ok, rows} = DB.query(db, "EXPLAIN QUERY PLAN " <> sql, params)
    Enum.map(rows, &List.last/1)
  end

  test "filtered source deliveries return exactly the rows of the filtered relation", ctx do
    all = NoticeBatcher.source_deliveries_sql()
    assert length(rows!(ctx.db, "SELECT * FROM (#{all})", [])) == 4

    cases = [
      {:source_wake, "d.sourceWakeId=?1", ctx.wake_ids},
      {:turn_seq, "d.turnSeq=?1", [1, 2, 3]},
      {:assignment, "d.assignmentId=?1", ["asg_a", "asg_b", "asg_none"]},
      {:turn_wake, "turn.wakeId=?1", ctx.wake_ids}
    ]

    for {key, predicate, values} <- cases do
      filtered = NoticeBatcher.source_deliveries_sql([{key, "?1"}])

      matched =
        Enum.map(values, fn value ->
          expected =
            rows!(
              ctx.db,
              "SELECT d.* FROM (#{all}) d JOIN turns turn ON turn.seq=d.turnSeq WHERE #{predicate}",
              [value]
            )

          assert rows!(
                   ctx.db,
                   "SELECT d.* FROM (#{filtered}) d JOIN turns turn ON turn.seq=d.turnSeq WHERE #{predicate}",
                   [value]
                 ) == expected,
                 "#{key}=#{inspect(value)}"

          assert rows!(ctx.db, "SELECT d.* FROM (#{filtered}) d", [value]) == expected,
                 "#{key}=#{inspect(value)} without the outer predicate"

          length(expected)
        end)

      assert Enum.sum(matched) > 0, "#{key} matched nothing"

      plan = plan!(ctx.db, "SELECT * FROM (#{filtered}) d", [hd(values)])
      refute Enum.any?(plan, &Regex.match?(~r/^SCAN t$/, &1)), "#{key}: #{inspect(plan)}"

      if key != :assignment do
        refute Enum.any?(plan, &Regex.match?(~r/^SCAN m$/, &1)), "#{key}: #{inspect(plan)}"
      end
    end
  end

  test "source_delivered_sql matches an EXISTS over the relation by indexed lookups", ctx do
    all = NoticeBatcher.source_deliveries_sql()

    expected =
      rows!(
        ctx.db,
        "SELECT w.wakeId FROM wakes w WHERE EXISTS (SELECT 1 FROM (#{all}) d WHERE d.sourceWakeId=w.wakeId)",
        []
      )

    assert expected == [["w_carrier"], ["w_direct"], ["w_src_a"], ["w_src_b"]]

    sql =
      "SELECT w.wakeId FROM wakes w WHERE #{NoticeBatcher.source_delivered_sql("w.wakeId")}"

    assert rows!(ctx.db, sql, []) == expected

    plan = plan!(ctx.db, sql, [])
    refute Enum.any?(plan, &Regex.match?(~r/^SCAN sd_(t|m)$/, &1)), inspect(plan)
    assert Enum.any?(plan, &(&1 =~ ~r/^SEARCH sd_m USING .*\(sourceWakeId=\?\)/)), inspect(plan)
  end
end
