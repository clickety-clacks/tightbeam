defmodule Tightbeam.RowReactionTerminalCutoverTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Gateway, Identity, Model, Org, RowReactions, Schema, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.{Snapshot, Store, TerminalNoticeCutover}

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    # Populate the pre-upgrade database before enabling the migration observer.
    DB.transaction(db, fn txn -> Process.delete({RowReactions, txn.conn}) end)
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

    DB.query(db, """
    INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state)
    VALUES('assignment','fixture','holder','opener',1,'open')
    """)

    %{db: db, base: base}
  end

  defp elect(ctx, edit \\ &Function.identity/1) do
    path = Path.join(ctx.base, "identity/rules/row-reaction-handoff.toml")
    bytes = File.read!("priv/kungfu/agentic-engineering/rules/row-reaction-handoff.toml")
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

  defp legacy_close(ctx) do
    {:ok, wake} =
      DB.transaction(ctx.db, fn txn ->
        Txn.q(
          txn,
          "INSERT INTO attests(id,assignmentId,kind,bySession,ts) VALUES('closing','assignment','completion','holder',100)"
        )

        Txn.q(
          txn,
          "UPDATE assignments SET state='closed',outcome='completed',closedAt=100,closingAttestId='closing',closedBySession='holder' WHERE id='assignment'"
        )

        wake = Tightbeam.RowReactionFixtures.legacy_notice_in_txn(txn, "assignment", "opener")

        if Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey='opener'") == [["retired"]] do
          Wakes.notice_undeliverable_in_txn(
            txn,
            wake,
            "terminal-child-owner-notification",
            "terminal_notification_recipient_unavailable"
          )
        end

        Wakes.get_in_txn(txn, wake.wake_id)
      end)

    wake
  end

  defp adopt(ctx) do
    :ok = RowReactions.activate(ctx.db)
    assert {:ok, :ok} = DB.transaction(ctx.db, &TerminalNoticeCutover.adopt_in_txn(&1, 200))
  end

  defp action(ctx, wake) do
    {:ok, [action]} =
      DB.transaction(ctx.db, &Store.actions_in_txn(&1, "owner", "legacy_notice:" <> wake.wake_id))

    action
  end

  test "pending canonical root retains identity and truthful historical evidence", ctx do
    elect(ctx)
    root = legacy_close(ctx)
    before = Wakes.get(ctx.db, root.wake_id)
    adopt(ctx)
    assert action(ctx, root)["status"] == "pending"
    assert Wakes.get(ctx.db, root.wake_id) == before

    assert {:ok, [[bytes]]} =
             DB.query(ctx.db, "SELECT event FROM row_reaction_events WHERE eventId=?1", [
               "legacy_notice:" <> root.wake_id
             ])

    event = JSON.decode!(bytes)
    assert event["historical"]
    assert event["before"] == nil
    assert event["after"]["state"] == "closed"
    assert event["source"] == %{"kind" => "attest", "id" => "closing"}
    assert event["principal"] == %{"kind" => "session", "id" => "holder"}
    adopt(ctx)
    assert :ok = RowReactions.recover(ctx.db)
    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.wake_id == root.wake_id
    DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='opener'")
    assert :ok = RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, root.wake_id).session_key == Org.personal_session_key("owner")
    assert action(ctx, root)["status"] == "pending"

    assert {:ok, [[^bytes]]} =
             DB.query(ctx.db, "SELECT event FROM row_reaction_events WHERE eventId=?1", [
               event["id"]
             ])
  end

  defp recovered_legacy_close(ctx) do
    DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey != 'holder'")
    root = legacy_close(ctx)
    assert root.state == "canceled"
    DB.query(ctx.db, "UPDATE sessions SET state='active' WHERE sessionKey='opener'")

    assert {:ok, {:ok, %{wake: successor, replay: false}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.recover_terminal_notification_in_txn(txn, root.wake_id, "session:opener")
             end)

    {root, successor}
  end

  test "explicit recovery successor retains its transport identity through adoption", ctx do
    elect(ctx)
    {root, successor} = recovered_legacy_close(ctx)
    original_root = Wakes.get(ctx.db, root.wake_id)
    adopt(ctx)
    assert action(ctx, root)["status"] == "canceled"
    assert action(ctx, successor)["status"] == "pending"
    assert :ok = RowReactions.recover(ctx.db)
    assert [pending] = Wakes.list_pending(ctx.db)
    assert pending.wake_id == successor.wake_id
    assert Wakes.get(ctx.db, root.wake_id) == original_root
    assert action(ctx, successor)["result"]["wake_id"] == successor.wake_id

    DB.query(ctx.db, "UPDATE sessions SET state='active' WHERE sessionKey=?1", [
      Org.personal_session_key("owner")
    ])

    DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='opener'")
    assert :ok = RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, successor.wake_id).session_key == Org.personal_session_key("owner")
    assert Wakes.get(ctx.db, root.wake_id) == original_root

    assert {:ok, {:ok, %{wake: replay, replay: true}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.recover_terminal_notification_in_txn(txn, root.wake_id, "user:owner")
             end)

    assert replay.wake_id == successor.wake_id
  end

  test "absent rail cancels adopted recovery successor without resurrecting its root", ctx do
    {root, successor} = recovered_legacy_close(ctx)
    original_root = Wakes.get(ctx.db, root.wake_id)
    adopt(ctx)
    assert :ok = RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, successor.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, root.wake_id) == original_root
    elect(ctx)
    assert Wakes.list_pending(ctx.db) == []
    assert action(ctx, successor)["status"] == "canceled"
  end

  test "absent election cancels only existing pending output and never replays close", ctx do
    root = legacy_close(ctx)
    adopt(ctx)
    assert :ok = RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, root.wake_id).state == "canceled"
    assert action(ctx, root)["status"] == "canceled"
    elect(ctx)
    assert Wakes.list_pending(ctx.db) == []

    assert {:ok, [["closed", "completed"]]} =
             DB.query(ctx.db, "SELECT state,outcome FROM assignments WHERE id='assignment'")
  end

  test "cutover does not manufacture missing historical outputs", ctx do
    DB.query(
      ctx.db,
      "UPDATE assignments SET state='closed',outcome='completed',closedAt=100 WHERE id='assignment'"
    )

    adopt(ctx)
    elect(ctx)
    assert Wakes.list_pending(ctx.db) == []

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM row_reaction_actions WHERE family='terminal-handoff'"
             )
  end

  for state <- ["fired", "canceled"] do
    test "#{state} output remains immutable through absent and changed election", ctx do
      root = legacy_close(ctx)

      if unquote(state) == "canceled" do
        assert {:ok, true} =
                 DB.transaction(ctx.db, fn txn ->
                   Wakes.cancel_in_txn(txn, %{
                     wake_id: root.wake_id,
                     requester: %{kind: "process", id: "tightbeam:row-reactions"},
                     reason_kind: "superseded",
                     causal_source: %{kind: "wake", id: root.wake_id},
                     outcome: %{kind: "no_replacement"}
                   })
                 end)
      else
        assert {:ok, []} =
                 DB.query(ctx.db, "UPDATE wakes SET state='fired' WHERE wakeId=?1", [root.wake_id])
      end

      original = Wakes.get(ctx.db, root.wake_id)
      adopt(ctx)
      expected = if unquote(state) == "fired", do: "accepted", else: "canceled"
      assert action(ctx, root)["status"] == expected
      assert :ok = RowReactions.recover(ctx.db)
      elect(ctx, &String.replace(&1, "terminal-child-owner-notification", "changed-notification"))
      assert Wakes.get(ctx.db, root.wake_id) == original
      assert action(ctx, root)["status"] == expected
    end
  end

  test "canonical-looking output with mismatched source is held without guessing", ctx do
    elect(ctx)
    root = legacy_close(ctx)

    DB.query(ctx.db, "UPDATE wakes SET prompt=prompt || ' changed' WHERE wakeId=?1", [
      root.wake_id
    ])

    original = Wakes.get(ctx.db, root.wake_id)
    adopt(ctx)
    assert action(ctx, root)["status"] == "held"

    assert {:ok, false} =
             DB.transaction(ctx.db, &RowReactions.delivery_ready_in_txn?(&1, root.wake_id))

    assert :ok = RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, root.wake_id) == original

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT heldCount FROM row_reaction_cutovers WHERE source='terminal-notice/v1'"
             )
  end

  test "earlier revocation is adopted from its exact generation after reopening", ctx do
    {:ok, root} =
      DB.transaction(ctx.db, fn txn ->
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

        root =
          Tightbeam.RowReactionFixtures.legacy_notice_in_txn(
            txn,
            "assignment",
            "opener",
            "revocation"
          )

        Txn.q(
          txn,
          "INSERT INTO assignment_reopenings(assignmentId,ts,reopenedByUser,reason,priorOutcome,priorClosedAt,priorClosedByUser) VALUES('assignment',110,'owner','new work','revoked',101,'owner')"
        )

        Txn.q(
          txn,
          "UPDATE assignments SET state='open',outcome=NULL,closedAt=NULL,closedByUser=NULL WHERE id='assignment'"
        )

        root
      end)

    adopt(ctx)
    assert action(ctx, root)["status"] == "pending"

    assert {:ok, [[bytes]]} =
             DB.query(ctx.db, "SELECT event FROM row_reaction_events WHERE eventId=?1", [
               "legacy_notice:" <> root.wake_id
             ])

    event = JSON.decode!(bytes)
    assert event["before"] == nil
    assert event["after"]["state"] == "closed"
    assert event["after"]["closedAt"] == 101
    assert event["source"] == %{"kind" => "assignment_revocation", "id" => "revocation"}
    assert event["principal"] == %{"kind" => "user", "id" => "owner"}

    assert {:ok, [["open", nil]]} =
             DB.query(ctx.db, "SELECT state,outcome FROM assignments WHERE id='assignment'")
  end

  defp elect_reminders(ctx) do
    elect(ctx)
    path = Path.join(ctx.base, "identity/rules/row-reaction-terminal-action.toml")

    File.write!(
      path,
      File.read!("priv/kungfu/agentic-engineering/rules/row-reaction-terminal-action.toml")
    )

    receipt = Path.join(ctx.base, "identity/kungfu/agentic-engineering/installed.toml")

    File.write!(
      receipt,
      "name='agentic-engineering'\npaths=['rules/row-reaction-handoff.toml','rules/row-reaction-terminal-action.toml']\n"
    )

    Gateway.load_law!(%{base_dir: ctx.base, db: ctx.db}, [])
  end

  defp deliver_legacy(ctx, wake, at) do
    {:ok, seq} =
      DB.transaction(ctx.db, fn txn ->
        [[seq]] =
          Txn.q(
            txn,
            "INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,wakeId) VALUES('opener',?1,'process:tightbeam',?2,'queued',?3,?4) RETURNING seq",
            ["delivery:" <> wake.wake_id, wake.prompt, at, wake.wake_id]
          )

        Txn.q(txn, "UPDATE wakes SET deliveredTurnSeq=?2 WHERE wakeId=?1", [wake.wake_id, seq])
        :ok = Wakes.batch_source_delivered_in_txn(txn, wake.wake_id, "opener")
        # The old producer's persisted output is fixture data. Do not ask the
        # new delivery runtime to recreate a historical automatic reaction.
        if Txn.q(txn, "SELECT 1 FROM assignments WHERE id='parent-work' AND state='open'") != [] do
          prefix = "terminal-child-owner-action-reminder:"

          {root_id, predecessor} =
            if String.starts_with?(wake.obligation_ref, prefix),
              do: {String.replace_prefix(wake.obligation_ref, prefix, ""), wake.wake_id},
              else: {wake.wake_id, "initial"}

          digest =
            :crypto.hash(
              :sha256,
              JSON.encode!(["terminal-child-owner-action-reminder", root_id, predecessor])
            )
            |> Base.encode16(case: :lower)

          condition = :crypto.hash(:sha256, root_id) |> Base.encode16(case: :lower)

          prompt =
            "A parent action is still due for child assignment assignment " <>
              "(finish occurrence attest/closing). Choose keep, park, or retire " <>
              "based on current purpose and obligations, act within your existing authority, then record " <>
              "what you did on an open assignment with a progress attest naming this child and occurrence. " <>
              "Use note: completion-handoff-action assignment attest " <>
              "closing kept|parked|retired: <what you did>. " <>
              "A refusal or failed action must be reported truthfully. Notice #{root_id}."

          Wakes.schedule_in_txn(txn, %{
            wake_id: "w_terminal_action_" <> digest,
            session_key: "opener",
            owner_user_id: "owner",
            origin: "process:tightbeam",
            prompt: prompt,
            due_at: at + 7_200_000,
            creator_session_key: "holder",
            condition_kind: "terminal-child-owner-action-" <> condition,
            condition_scope: root_id,
            obligation_ref: prefix <> root_id
          })
        end

        seq
      end)

    seq
  end

  defp parent_work(ctx) do
    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state) VALUES('parent-work','fixture','opener','owner',1,'open')"
             )
  end

  test "legacy reminder adoption uses actual delivery time and retains its output", ctx do
    elect_reminders(ctx)
    parent_work(ctx)
    root = legacy_close(ctx)
    seq = deliver_legacy(ctx, root, 200)
    [reminder] = Wakes.list_pending(ctx.db)
    original = reminder
    adopt(ctx)
    assert action(ctx, root)["status"] == "accepted"
    assert action(ctx, reminder)["status"] == "pending"
    assert Wakes.get(ctx.db, reminder.wake_id) == original

    assert {:ok, [[bytes]]} =
             DB.query(ctx.db, "SELECT event FROM row_reaction_events WHERE eventId=?1", [
               "legacy_notice:" <> reminder.wake_id
             ])

    event = JSON.decode!(bytes)
    assert event["historical"] and event["before"] == nil
    assert event["kind"] == "wake_delivery" and event["at"] == 200
    assert event["delivery"]["turnSeq"] == seq
    assert event["after"]["wakeId"] == root.wake_id
    assert :ok = RowReactions.recover(ctx.db)
    [current] = Wakes.list_pending(ctx.db)
    assert current.wake_id == reminder.wake_id
    assert current.due_at == 7_200_200
    adopt(ctx)
    assert :ok = RowReactions.recover(ctx.db)
    assert [^current] = Wakes.list_pending(ctx.db)
  end

  test "successor joins its canonical predecessor and receipt cancels only pending reminder",
       ctx do
    elect_reminders(ctx)
    parent_work(ctx)
    root = legacy_close(ctx)
    deliver_legacy(ctx, root, 200)
    [first] = Wakes.list_pending(ctx.db)
    seq = deliver_legacy(ctx, first, 300)
    [second] = Wakes.list_pending(ctx.db)
    adopt(ctx)
    assert action(ctx, first)["status"] == "accepted"
    assert action(ctx, second)["status"] == "pending"

    assert {:ok, [[bytes]]} =
             DB.query(ctx.db, "SELECT event FROM row_reaction_events WHERE eventId=?1", [
               "legacy_notice:" <> second.wake_id
             ])

    event = JSON.decode!(bytes)
    assert event["after"]["wakeId"] == first.wake_id
    assert event["delivery"]["turnSeq"] == seq
    assert event["at"] == 300
    assert :ok = RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, second.wake_id).due_at == 7_200_300

    DB.query(
      ctx.db,
      "INSERT INTO attests(id,assignmentId,kind,bySession,ts,note) VALUES('receipt','parent-work','progress','opener',400,'completion-handoff-action assignment attest closing kept: needed')"
    )

    assert :ok = RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, second.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, first.wake_id).state == "fired"
    assert action(ctx, first)["status"] == "accepted"
  end

  test "changed parent eligibility is evaluated by the rail after historical adoption", ctx do
    elect_reminders(ctx)
    parent_work(ctx)
    root = legacy_close(ctx)
    deliver_legacy(ctx, root, 200)
    [reminder] = Wakes.list_pending(ctx.db)
    DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='opener'")
    adopt(ctx)
    assert action(ctx, reminder)["status"] == "pending"
    assert :ok = RowReactions.recover(ctx.db)
    assert action(ctx, reminder)["status"] == "canceled"
    assert Wakes.get(ctx.db, reminder.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, root.wake_id).state == "fired"
  end

  test "absent reminder election cancels its pending output without recreating a handoff", ctx do
    parent_work(ctx)
    root = legacy_close(ctx)
    deliver_legacy(ctx, root, 200)
    [reminder] = Wakes.list_pending(ctx.db)
    adopt(ctx)
    assert :ok = RowReactions.recover(ctx.db)
    assert action(ctx, reminder)["status"] == "canceled"
    assert Wakes.get(ctx.db, reminder.wake_id).state == "canceled"
    elect_reminders(ctx)
    assert Wakes.list_pending(ctx.db) == []
    assert action(ctx, reminder)["status"] == "canceled"
  end

  test "missing delivery evidence holds existing reminder and never invents a past event", ctx do
    elect_reminders(ctx)
    parent_work(ctx)
    root = legacy_close(ctx)
    deliver_legacy(ctx, root, 200)
    [reminder] = Wakes.list_pending(ctx.db)
    DB.query(ctx.db, "UPDATE wakes SET deliveredTurnSeq=NULL WHERE wakeId=?1", [root.wake_id])
    adopt(ctx)
    assert action(ctx, reminder)["status"] == "held"
    assert :ok = RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, reminder.wake_id).state == "pending"

    assert {:ok, false} =
             DB.transaction(ctx.db, &RowReactions.delivery_ready_in_txn?(&1, reminder.wake_id))
  end

  test "historical delivered root without reminder does not arm one at adoption", ctx do
    elect_reminders(ctx)
    root = legacy_close(ctx)
    deliver_legacy(ctx, root, 200)
    assert Wakes.list_pending(ctx.db) == []
    parent_work(ctx)
    adopt(ctx)
    assert :ok = RowReactions.recover(ctx.db)
    assert Wakes.list_pending(ctx.db) == []

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM row_reaction_actions WHERE family='terminal-action'"
             )
  end

  test "adopted root supplies raw terminal provenance for later delivery", ctx do
    root = legacy_close(ctx)
    adopt(ctx)

    assert {:ok, facts} =
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

    assert [%{"sourceToken" => "closing", "outcome" => "completed", "wakeId" => id}] =
             facts["terminal_sources"]

    assert id == root.wake_id
  end
end
