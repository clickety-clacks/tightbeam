defmodule Tightbeam.RowReactionHandoffSnapshotTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Gateway, Identity, Model, Org, RowReactions, Schema, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.Snapshot

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    base = Path.join(System.tmp_dir!(), "request-reaction-#{System.unique_integer([:positive])}")
    assert :initialized = Identity.init!(base)
    Gateway.load_law!(%{base_dir: base, db: db}, [])
    on_exit(fn -> File.rm_rf!(base) end)
    DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1)")

    for key <- ["holder", "opener", "alternate", Org.personal_session_key("owner")] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "owner",
        origin: "user:owner",
        kind: if(key == Org.personal_session_key("owner"), do: "main", else: "custom"),
        archetype: "default",
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture"),
        host: "synthetic-host"
      })
    end

    DB.execute(db, """
    INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state)
    VALUES('assignment','fixture','holder','opener',1,'open')
    """)

    %{db: db, base: base}
  end

  defp elect(ctx, edit \\ &Function.identity/1) do
    path = Path.join(ctx.base, "identity/rules/row-reaction-handoff.toml")
    bytes = File.read!("priv/kungfu/agentic-engineering/rules/row-reaction-handoff.toml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, edit.(bytes))
    receipt = Path.join(ctx.base, "identity/kungfu/agentic-engineering/installed.toml")
    File.mkdir_p!(Path.dirname(receipt))

    File.write!(
      receipt,
      "name='agentic-engineering'\npaths=['rules/row-reaction-handoff.toml']\n"
    )

    Gateway.load_law!(%{base_dir: ctx.base, db: ctx.db}, [])
    path
  end

  # Exercise the neutral observer in its owning transaction. Production close
  # and delivery call sites are composed separately with legacy cutover.
  defp close_in_txn(ctx) do
    DB.transaction(ctx.db, fn txn ->
      before = Snapshot.assignment_row(txn, "assignment")

      Txn.q(
        txn,
        "INSERT INTO attests(id,assignmentId,kind,bySession,ts) VALUES('closing','assignment','completion','holder',100)"
      )

      Txn.q(
        txn,
        "UPDATE assignments SET state='closed',outcome='completed',closedAt=100,closingAttestId='closing',closedBySession='holder' WHERE id='assignment'"
      )

      RowReactions.observe_assignment_in_txn(
        txn,
        before,
        %{"kind" => "attest", "id" => "closing"},
        "session:holder",
        100
      )
    end)
  end

  defp event(ctx, kind) do
    {:ok, [[bytes, facts]]} =
      DB.query(
        ctx.db,
        "SELECT event,facts FROM row_reaction_events WHERE json_extract(event,'$.kind')=?1",
        [kind]
      )

    {JSON.decode!(bytes), JSON.decode!(facts)}
  end

  test "assignment observation captures raw before and source rows with an elected handoff",
       ctx do
    elect(ctx)
    assert {:ok, :ok} = close_in_txn(ctx)
    {event, facts} = event(ctx, "assignment")
    assert event["before"]["state"] == "open"
    assert event["before"]["closedAt"] == nil
    assert event["after"]["closedAt"] == 100
    assert event["after"]["closingAttestId"] == "closing"
    assert event["source"] == %{"kind" => "attest", "id" => "closing"}
    assert facts["attest"]["id"] == "closing"
    assert facts["revocation"] == nil
    assert facts["work_item"] == nil
    assert facts["assignments"] == []
    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.session_key == "opener"
    assert wake.obligation_ref == "terminal-child-owner-notification:assignment"

    assert {:ok, legacy} =
             Wakes.terminal_notification(%{
               source_kind: "attest",
               source_token: "closing",
               assignment_id: "assignment",
               work_item_id: nil,
               child_session_key: "holder",
               owner_user_id: "owner",
               opened_by_kind: "session",
               opened_by_id: "opener",
               outcome: "completed",
               terminal_at: 100
             })

    assert wake.wake_id == legacy.wake_id
    assert wake.prompt == legacy.prompt
  end

  test "absent handoff election leaves source rows without replay when enabled",
       ctx do
    assert {:ok, :ok} = close_in_txn(ctx)
    assert Wakes.list_pending(ctx.db) == []
    assert {_, %{"attest" => %{"id" => "closing"}}} = event(ctx, "assignment")
    elect(ctx)
    assert Wakes.list_pending(ctx.db) == []
  end

  test "default unavailable recipient preserves close with one undelivered intent", ctx do
    elect(ctx)
    DB.execute(ctx.db, "UPDATE sessions SET state='retired'")
    assert {:ok, :ok} = close_in_txn(ctx)

    assert {:ok, [["closed", "completed", 100]]} =
             DB.query(
               ctx.db,
               "SELECT state,outcome,closedAt FROM assignments WHERE id='assignment'"
             )

    assert {:ok, [[id, "canceled", nil]]} =
             DB.query(ctx.db, "SELECT wakeId,state,deliveredTurnSeq FROM wakes")

    assert {:ok, [[detail]]} =
             DB.query(
               ctx.db,
               "SELECT detail FROM lifecycle_events WHERE kind='wake_undeliverable' AND subject=?1",
               [id]
             )

    assert JSON.decode!(detail)["reason"] == "terminal_notification_recipient_unavailable"
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM attests")
    assert :ok = RowReactions.recover(ctx.db)
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")
  end

  test "failure to persist undelivered evidence rolls back actual source write", ctx do
    elect(ctx)
    DB.execute(ctx.db, "UPDATE sessions SET state='retired'")

    DB.execute(
      ctx.db,
      "CREATE TRIGGER refuse_evidence BEFORE INSERT ON lifecycle_events WHEN NEW.kind='wake_undeliverable' BEGIN SELECT RAISE(ABORT,'fixture evidence failure'); END;"
    )

    assert {:error, _} = close_in_txn(ctx)

    assert {:ok, [["open", nil]]} =
             DB.query(ctx.db, "SELECT state,closedAt FROM assignments WHERE id='assignment'")

    for table <- ~w(attests wakes wake_cancellations row_reaction_actions row_reaction_events) do
      assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM " <> table)
    end
  end

  test "pending handoff reevaluates raw recipient facts while source evidence is immutable",
       ctx do
    elect(ctx)
    assert {:ok, :ok} = close_in_txn(ctx)
    [wake] = Wakes.list_pending(ctx.db)
    original = event(ctx, "assignment")
    DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='opener'")
    assert :ok = RowReactions.recover(ctx.db)
    assert %{session_key: key, wake_id: id} = Wakes.get(ctx.db, wake.wake_id)
    assert key == Org.personal_session_key("owner")
    assert id == wake.wake_id
    assert event(ctx, "assignment") == original
  end

  test "delivery snapshots expose only related wakes and raw authored disposition facts", ctx do
    elect(ctx)
    assert {:ok, :ok} = close_in_txn(ctx)
    [root] = Wakes.list_pending(ctx.db)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               reminder =
                 Wakes.schedule_in_txn(txn, %{
                   session_key: "opener",
                   owner_user_id: "owner",
                   origin: "process:tightbeam",
                   prompt: "reminder",
                   due_at: 200,
                   obligation_ref: "terminal-child-owner-action-reminder:" <> root.wake_id
                 })

               Wakes.schedule_in_txn(txn, %{
                 session_key: "opener",
                 owner_user_id: "owner",
                 origin: "example",
                 prompt: "unrelated",
                 due_at: 200
               })

               Txn.q(
                 txn,
                 "INSERT INTO attests(id,assignmentId,kind,bySession,ts,note) VALUES('receipt','assignment','progress','opener',110,?1)",
                 ["completion-handoff-action assignment attest closing kept: still needed"]
               )

               before = Snapshot.wake(txn, reminder.wake_id)

               [[seq]] =
                 Txn.q(
                   txn,
                   "INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,wakeId) VALUES('opener','delivered','process:tightbeam','reminder','queued',200,?1) RETURNING seq",
                   [reminder.wake_id]
                 )

               Txn.q(
                 txn,
                 "UPDATE wakes SET state='fired',firedAt=200,deliveredTurnSeq=?2 WHERE wakeId=?1",
                 [reminder.wake_id, seq]
               )

               RowReactions.observe_wake_delivery_in_txn(
                 txn,
                 before,
                 %{"sessionKey" => "opener", "turnSeq" => seq, "carrierWakeId" => nil},
                 "process:tightbeam",
                 200
               )
             end)

    {event, facts} = event(ctx, "wake_delivery")
    assert event["before"]["deliveredTurnSeq"] == nil
    assert event["before"]["state"] == "pending"
    assert event["after"]["deliveredTurnSeq"] == event["delivery"]["turnSeq"]
    assert length(facts["wakes"]) == 2
    assert Enum.any?(facts["wakes"], &(&1["wakeId"] == root.wake_id))

    assert [
             %{
               "wakeId" => id,
               "sourceKind" => "attest",
               "sourceToken" => "closing",
               "outcome" => "completed"
             }
           ] = facts["terminal_sources"]

    assert id == root.wake_id
    assert [%{"id" => "receipt", "disposition" => receipt}] = facts["attests"]

    assert receipt == %{
             "assignmentId" => "assignment",
             "sourceKind" => "attest",
             "sourceToken" => "closing",
             "action" => "kept",
             "detail" => "still needed"
           }

    # No open destination is synthesized and no eligibility Boolean is supplied.
    assert facts["assignments"] == []
  end

  test "receipt syntax preserves exact existing convention without source policy" do
    assert %{"sourceKind" => "other", "action" => "parked"} =
             Snapshot.disposition("completion-handoff-action a other token parked: explanation")

    for note <- [
          nil,
          "completion-handoff-action a attest token kept:",
          "completion-handoff-action a attest token kept:   ",
          "completion-handoff-action a attest token keep: explanation",
          "prefix completion-handoff-action a attest token retired: explanation"
        ] do
      assert Snapshot.disposition(note) == nil
    end
  end

  test "retry projection uses its stored root and immutable event despite changed prompt", ctx do
    elect(ctx)
    assert {:ok, :ok} = close_in_txn(ctx)
    [root] = Wakes.list_pending(ctx.db)

    assert {:ok, {retry, facts}} =
             DB.transaction(ctx.db, fn txn ->
               retry =
                 Wakes.schedule_in_txn(txn, %{
                   session_key: "opener",
                   owner_user_id: "owner",
                   origin: "process:tightbeam",
                   prompt: "changed elected prompt",
                   due_at: 200,
                   obligation_ref: root.obligation_ref,
                   assignment_id: "assignment"
                 })

               Txn.q(
                 txn,
                 "INSERT INTO wake_retry_attempts(wakeId,rootWakeId,predecessorWakeId,attempt,outcome,observedAt) VALUES(?1,?2,?2,1,'pending',200)",
                 [retry.wake_id, root.wake_id]
               )

               facts =
                 Snapshot.current(
                   txn,
                   %{
                     "kind" => "wake_delivery",
                     "after" => Snapshot.wake(txn, retry.wake_id),
                     "delivery" => %{"sessionKey" => "opener"}
                   },
                   %{}
                 )

               {retry, facts}
             end)

    assert length(facts["wakes"]) == 2
    assert [%{"wakeId" => retry_id, "rootWakeId" => root_id}] = facts["wake_retries"]
    assert retry_id == retry.wake_id
    assert root_id == root.wake_id

    assert Enum.sort(Enum.map(facts["terminal_sources"], & &1["wakeId"])) ==
             Enum.sort([retry_id, root_id])

    assert Enum.all?(facts["terminal_sources"], &(&1["sourceToken"] == "closing"))
  end

  test "revocation source stays raw and is not removed by reminder outcome policy", ctx do
    elect(ctx)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               before = Snapshot.assignment_row(txn, "assignment")

               Txn.q(
                 txn,
                 "INSERT INTO assignment_revocations(id,assignmentId,revokedAt,revokedByUser,reason) VALUES('revocation','assignment',101,'owner','work ended')"
               )

               Txn.q(
                 txn,
                 "INSERT INTO assignment_revocation_generations(revocationId,assignmentId,reopeningId) VALUES('revocation','assignment',NULL)"
               )

               Txn.q(
                 txn,
                 "UPDATE assignments SET state='closed',outcome='revoked',closedAt=101,closedByUser='owner' WHERE id='assignment'"
               )

               RowReactions.observe_assignment_in_txn(
                 txn,
                 before,
                 %{"kind" => "assignment_revocation", "id" => "revocation"},
                 "user:owner",
                 101
               )
             end)

    {event, facts} = event(ctx, "assignment")
    assert event["principal"] == %{"kind" => "user", "id" => "owner"}
    assert facts["attest"] == nil
    assert facts["revocation"]["id"] == "revocation"
    assert facts["revocation"]["revokedByUser"] == "owner"
    [root] = Wakes.list_pending(ctx.db)

    assert {:ok, delivery_facts} =
             DB.transaction(ctx.db, fn txn ->
               Snapshot.current(
                 txn,
                 %{
                   "kind" => "wake_delivery",
                   "after" => Snapshot.wake(txn, root.wake_id),
                   "delivery" => %{"sessionKey" => "opener"}
                 },
                 %{}
               )
             end)

    assert [%{"outcome" => "revoked", "sourceKind" => "assignment_revocation"}] =
             delivery_facts["terminal_sources"]
  end

  test "addressed delivery and pending recovery ignore growing settled history", ctx do
    elect(ctx)
    assert {:ok, :ok} = close_in_txn(ctx)
    [root] = Wakes.list_pending(ctx.db)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO attests(id,assignmentId,kind,bySession,ts,note) VALUES('exact-receipt','assignment','progress','opener',110,'completion-handoff-action assignment attest closing kept: still needed')"
             )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state) VALUES('current-work','current','opener','owner',1,'open')"
             )

    snapshots =
      for count <- [0, 64, 256] do
        assert {:ok, :ok} =
                 DB.transaction(ctx.db, fn txn ->
                   if count > 0 do
                     for n <- 1..count do
                       id = "history-#{count}-#{n}"

                       Txn.q(
                         txn,
                         "INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt) SELECT ?1,?1,ownerUserId,origin,archetype,harness,provider,model,1,1 FROM sessions WHERE sessionKey='holder'",
                         [id]
                       )

                       Txn.q(
                         txn,
                         "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state,outcome,closedAt) VALUES(?1,'settled','opener','owner',1,'closed','completed',2)",
                         [id]
                       )

                       Txn.q(
                         txn,
                         "INSERT INTO attests(id,assignmentId,kind,bySession,ts,note) VALUES(?1,?1,'progress','opener',1,?2)",
                         [id, String.duplicate("historical note ", 100)]
                       )

                       Txn.q(
                         txn,
                         "INSERT INTO row_reaction_events(org,eventId,version,event,facts,admittedAt) VALUES('owner',?1,1,'{}','{}',1)",
                         [id]
                       )

                       Txn.q(
                         txn,
                         "INSERT INTO row_reaction_actions(id,org,eventId,family,slot,plan,payloadDigest,status,updatedAt) VALUES(?1,'owner',?1,'settled','notice','{}','historical','accepted',1)",
                         [id]
                       )
                     end
                   end

                   :ok
                 end)

        assert {:ok, {facts, plans}} =
                 DB.transaction(ctx.db, fn txn ->
                   Process.put(:snapshot_queries, [])

                   observed =
                     Txn.observe_queries(txn, fn {:sql_query, sql, params} ->
                       Process.put(:snapshot_queries, [
                         {sql, params} | Process.get(:snapshot_queries)
                       ])
                     end)

                   facts =
                     Snapshot.current(
                       observed,
                       %{
                         "kind" => "wake_delivery",
                         "after" => Snapshot.wake(txn, root.wake_id),
                         "delivery" => %{"sessionKey" => "opener"}
                       },
                       %{}
                     )

                   :ok = RowReactions.recover_in_txn(observed)

                   plans =
                     for {sql, params} <- Process.delete(:snapshot_queries),
                         String.starts_with?(String.trim(sql), "SELECT") do
                       {sql, Txn.q(txn, "EXPLAIN QUERY PLAN " <> sql, params)}
                     end

                   {facts, plans}
                 end)

        assert [%{"id" => "exact-receipt"}] = facts["attests"]
        assert [%{"id" => "current-work"}] = facts["assignments"]
        assert length(facts["sessions"]) <= 3

        for {_sql, plan} <- plans do
          details = Enum.map_join(plan, "\n", &List.last/1)
          refute Regex.match?(~r/SCAN (?:attests|assignments|sessions|e|a)(?:$|\s)/m, details)
        end

        assert Enum.any?(plans, fn {_, plan} ->
                 Enum.any?(plan, &(List.last(&1) =~ "reaction_disposition"))
               end)

        assert Enum.any?(plans, fn {_, plan} ->
                 Enum.any?(plan, &(List.last(&1) =~ "row_reaction_pending"))
               end)

        IO.puts(
          "settled_history=#{count} delivery_snapshot_bytes=#{byte_size(JSON.encode!(facts))} plans=#{inspect(plans)}"
        )

        facts
      end

    assert Enum.uniq(snapshots) |> length() == 1
  end
end
