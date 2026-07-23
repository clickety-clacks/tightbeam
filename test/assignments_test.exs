defmodule Tightbeam.AssignmentsTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{
    Assignments,
    ConditionFacts,
    DB,
    Devices,
    Dispatch,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Projection,
    Roles,
    Rules,
    Wakes,
    WorkItems,
    WorkState
  }

  setup do
    db = :"assignments_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [
          Devices,
          ConditionFacts,
          Idempotency,
          Ledger,
          Org,
          Projection,
          Roles,
          Wakes,
          WorkItems,
          Assignments,
          WorkState,
          EventLog
        ] do
      :ok = module.ensure_schema(db)
    end

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('admin', 1, 1), ('flynn', 0, 1), ('other', 0, 1)"
      )

    holder = session(db, "holder", "flynn")
    other = session(db, "other-session", "other")
    Rules.load!(System.tmp_dir!(), Map.keys(Gateway.handlers(%{db: db})), %{})
    %{db: db, holder: holder, other: other, handlers: Gateway.handlers(%{db: db})}
  end

  test "schema pins every assignment consistency CHECK", %{db: db} do
    base =
      "INSERT INTO assignments (id, subject, holderKey, holderRole, holderFallback, openedByUser, openedBySession, openedAt, state, outcome, closedAt, closedByUser, closedBySession, closingAttestId) VALUES "

    invalid = [
      "('a1','x','holder',NULL,1,'flynn',NULL,1,'open',NULL,NULL,NULL,NULL,NULL)",
      "('a2','x','holder',NULL,0,NULL,NULL,1,'open',NULL,NULL,NULL,NULL,NULL)",
      "('a3','x','holder',NULL,0,'flynn','holder',1,'open',NULL,NULL,NULL,NULL,NULL)",
      "('a4','x','holder',NULL,0,'flynn',NULL,1,'open','revoked',NULL,NULL,NULL,NULL)",
      "('a5','x','holder',NULL,0,'flynn',NULL,1,'closed',NULL,2,'flynn',NULL,NULL)",
      "('a6','x','holder',NULL,0,'flynn',NULL,1,'closed','revoked',NULL,'flynn',NULL,NULL)",
      "('a7','x','holder',NULL,0,'flynn',NULL,1,'closed','revoked',2,NULL,NULL,NULL)",
      "('a8','x','holder',NULL,0,'flynn',NULL,1,'closed','revoked',2,'flynn','holder',NULL)",
      "('a9','x','holder',NULL,0,'flynn',NULL,1,'closed','completed',2,'flynn',NULL,NULL)"
    ]

    Enum.each(invalid, fn values ->
      assert {:error, %DB.Error{message: message}} = DB.query(db, base <> values)
      assert message =~ "CHECK constraint"
    end)

    assert {:error, %DB.Error{}} =
             DB.query(
               db,
               "INSERT INTO attests (id, assignmentId, kind, note, bySession, ts) VALUES ('bad','missing','verdict',NULL,'holder',1)"
             )
  end

  test "assignment text limits are fixed by the specs, not application config", ctx do
    old_values =
      for key <- [:max_subject_len, :max_note_len, :max_verdict_kind_len, :max_idem_key_len],
          into: %{} do
        {key, Application.get_env(:tightbeam, key)}
      end

    on_exit(fn ->
      Enum.each(old_values, fn
        {key, nil} -> Application.delete_env(:tightbeam, key)
        {key, value} -> Application.put_env(:tightbeam, key, value)
      end)
    end)

    Application.put_env(:tightbeam, :max_subject_len, 3)
    Application.put_env(:tightbeam, :max_note_len, 3)
    Application.put_env(:tightbeam, :max_verdict_kind_len, 3)
    Application.put_env(:tightbeam, :max_idem_key_len, 3)

    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "four", "four"))
    assert assignment.subject == "four"

    progress =
      attest_call({:session, "holder"}, assignment.id, "progress")
      |> put_in([:params, :note], "four")
      |> then(&handle(ctx, "attest", &1))

    assert progress.attest.note == "four"

    verdict =
      attest_call({:user, "flynn"}, assignment.id, "verdict")
      |> put_in([:params, :verdict_kind], "four")
      |> then(&handle(ctx, "attest", &1))

    assert verdict.attest.verdictKind == "four"

    assert %{code: "invalid_subject"} =
             handle(
               ctx,
               "assign",
               assign_call({:user, "flynn"}, String.duplicate(" ", 2000) <> "x")
             )

    assert %{code: "invalid_note"} =
             attest_call({:session, "holder"}, assignment.id, "progress")
             |> put_in([:params, :note], String.duplicate("x", 2001))
             |> then(&handle(ctx, "attest", &1))

    assert %{code: "invalid_verdict_kind"} =
             attest_call({:user, "flynn"}, assignment.id, "verdict")
             |> put_in([:params, :verdict_kind], String.duplicate("x", 65))
             |> then(&handle(ctx, "attest", &1))
  end

  test "assign validates principals, input, liveness, opener typing, and idempotent races", ctx do
    assert %{code: "process_denied"} = handle(ctx, "assign", assign_call({:process, "cron"}))
    assert %{code: "principal_required"} = handle(ctx, "assign", assign_call(nil))
    assert %{code: "invalid_subject"} = handle(ctx, "assign", assign_call({:user, "flynn"}, " "))

    assert %{code: "invalid_subject"} =
             handle(ctx, "assign", assign_call({:user, "flynn"}, String.duplicate("x", 2001)))

    assert %{code: "invalid_idempotency_key"} =
             handle(ctx, "assign", assign_call({:user, "flynn"}, "x", " "))

    assert %{code: "invalid_idempotency_key"} =
             handle(
               ctx,
               "assign",
               assign_call({:user, "flynn"}, "x", String.duplicate("k", 201))
             )

    user_opened = handle(ctx, "assign", assign_call({:user, "flynn"}, "user work"))
    assert user_opened.openedByUser == "flynn"
    assert user_opened.openedBySession == nil
    assert user_opened.workItemId == nil

    session_opened = handle(ctx, "assign", assign_call({:session, "holder"}, "session work"))
    assert session_opened.openedBySession == "holder"
    assert session_opened.openedByUser == nil

    role_call =
      assign_call({:user, "flynn"}, "role work")
      |> Map.merge(%{target_role: "builder", role_fallback: true})

    role_opened = handle(ctx, "assign", role_call)
    assert role_opened.holderRole == "builder"
    assert role_opened.holderFallback

    Org.retire(ctx.db, "other-session")

    assert %{code: "session_retired"} =
             handle(ctx, "assign", %{assign_call({:user, "flynn"}) | session_key: "other-session"})

    call = assign_call({:user, "flynn"}, "once", "same-key")
    tasks = for _ <- 1..2, do: Task.async(fn -> handle(ctx, "assign", call) end)
    [one, two] = Task.await_many(tasks)
    assert one.id == two.id

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'once'")
  end

  test "dispatch atomically opens an assignment and enqueues its brief with the card id", ctx do
    assignment =
      handle(ctx, "dispatch", dispatch_call({:user, "flynn"}, "ship it", "Please ship it."))

    assert assignment.subject == "ship it"
    assert assignment.holderKey == "holder"

    assert {:ok, [[prompt]]} =
             DB.query(ctx.db, "SELECT prompt FROM turns WHERE sessionKey = 'holder'")

    assert prompt =~ assignment.id
    assert prompt =~ "Please ship it."

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE id = ?1", [assignment.id])
  end

  test "linked dispatch remains one atomic assign-and-wake action", ctx do
    work_item =
      handle(
        ctx,
        "work-item-create",
        work_item_call("work-item-create", {:user, "flynn"}, %{title: "Rumination rail"})
      )

    call =
      dispatch_call(
        {:session, "other-session"},
        "ship the rail",
        "Implement the ratified behavior",
        nil,
        work_item.id
      )

    assignment = handle(ctx, "dispatch", call)
    assert assignment.workItemId == work_item.id
    assert assignment.openedBySession == "other-session"

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE workItemId = ?1", [
               work_item.id
             ])

    user_dispatch =
      handle(
        ctx,
        "dispatch",
        dispatch_call(
          {:user, "flynn"},
          "user dispatch",
          "Dispatch immediately.",
          nil,
          work_item.id
        )
      )

    assert user_dispatch.workItemId == work_item.id

    unlinked =
      handle(
        ctx,
        "dispatch",
        dispatch_call({:session, "other-session"}, "unlinked", "Dispatch immediately.")
      )

    assert unlinked.subject == "unlinked"

    assigned =
      handle(
        ctx,
        "assign",
        assign_call({:session, "other-session"}, "bookkeeping", nil, work_item.id)
      )

    assert assigned.workItemId == work_item.id
  end

  test "review and file declarations are assign-only inputs", ctx do
    reviewed = handle(ctx, "assign", assign_call({:user, "flynn"}, "reviewed"))

    call =
      dispatch_call({:user, "flynn"}, "dispatch", "Do the work.")
      |> put_in([:params, :reviews_assignment_id], reviewed.id)
      |> put_in([:params, :files], ["lib/ignored.ex"])
      |> Map.put(:on_work_item_change, fn _, _ -> send(self(), :work_item_change) end)

    dispatched = handle(ctx, "dispatch", call)
    assert dispatched.reviewsAssignmentId == nil
    assert Assignments.declared_files(ctx.db, dispatched.id) == []
    refute_received :work_item_change
  end

  test "dispatch rolls back the assignment when prompt enqueue fails", ctx do
    assert {:ok, _} = DB.query(ctx.db, "DROP TABLE turns")

    assert {:error, %{code: "server_error", message: message}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call({:user, "flynn"}, "rollback", "Wake now.")
             )

    assert message =~ "no such table: turns"

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'rollback'")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM messages WHERE content LIKE '%Wake now.%'")
  end

  test "dispatch rejects disallowed principals exactly as assign does", ctx do
    for principal <- [{:process, "cron"}, nil] do
      assign_error = handle(ctx, "assign", assign_call(principal, "work"))
      dispatch_error = handle(ctx, "dispatch", dispatch_call(principal, "work", "Do work."))
      assert dispatch_error == assign_error
    end
  end

  test "assignment-get returns the full assignment row or not_found", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "fetch me"))

    assert handle(
             ctx,
             "assignment-get",
             assignment_get_call({:session, "other-session"}, assignment.id)
           ) ==
             assignment

    assert handle(
             ctx,
             "assignment-get",
             assignment_get_call({:session, "other-session"}, "asg_missing")
           ) == %{code: "not_found", message: "unknown assignment: asg_missing"}
  end

  test "work-item links validate on create but idempotent replay returns the original link",
       ctx do
    first =
      handle(
        ctx,
        "work-item-create",
        work_item_call("work-item-create", {:user, "flynn"}, %{title: "First"})
      )

    second =
      handle(
        ctx,
        "work-item-create",
        work_item_call("work-item-create", {:user, "flynn"}, %{title: "Second"})
      )

    linked =
      handle(ctx, "assign", assign_call({:user, "flynn"}, "linked", "work-key", first.id))

    assert linked.workItemId == first.id

    for work_item_id <- [second.id, nil, "wi_missing"] do
      replay =
        handle(ctx, "assign", assign_call({:user, "flynn"}, "ignored", "work-key", work_item_id))

      assert replay.id == linked.id
      assert replay.workItemId == first.id
    end

    assert %{code: "unknown_work_item"} =
             handle(
               ctx,
               "assign",
               assign_call({:user, "flynn"}, "not inserted", nil, "wi_missing")
             )

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'not inserted'")
  end

  test "attest-era database gains nullable workItemId additively and idempotently" do
    db = :"assignment_migration_db_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: db,
      start: {DB, :start_link, [[path: ":memory:", name: db]]}
    })

    :ok = WorkItems.ensure_schema(db)

    :ok =
      DB.execute(db, """
      CREATE TABLE assignments (
        id TEXT PRIMARY KEY, subject TEXT NOT NULL, holderKey TEXT NOT NULL,
        holderRole TEXT NULL, holderFallback INTEGER NOT NULL DEFAULT 0,
        openedByUser TEXT NULL, openedBySession TEXT NULL, openedAt INTEGER NOT NULL,
        state TEXT NOT NULL DEFAULT 'open', outcome TEXT NULL, closedAt INTEGER NULL,
        closedByUser TEXT NULL, closedBySession TEXT NULL, closingAttestId TEXT NULL
      )
      """)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) VALUES ('asg_old', 'old', 'holder', 'flynn', 1)"
      )

    :ok = Assignments.ensure_schema(db)
    :ok = Assignments.ensure_schema(db)
    assert [%{id: "asg_old", workItemId: nil}] = Assignments.list(db, %{state: "all"})
  end

  test "assign captures review links and immutable holder family stamps", ctx do
    reviewed = handle(ctx, "assign", assign_call({:user, "flynn"}, "producer"))

    assert reviewed.reviewsAssignmentId == nil
    assert reviewed.holderHarness == "claude"
    assert reviewed.holderProvider == "anthropic"

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET harness = 'codex', provider = 'openai' WHERE sessionKey = 'holder'"
      )

    assert %{holderHarness: "claude", holderProvider: "anthropic"} =
             Assignments.list(ctx.db, %{state: "all"})
             |> Enum.find(&(&1.id == reviewed.id))

    review_call =
      assign_call({:user, "flynn"}, "review")
      |> put_in([:params, :reviews_assignment_id], reviewed.id)
      |> Map.put(:session_key, "other-session")

    review = handle(ctx, "assign", review_call)
    assert review.reviewsAssignmentId == reviewed.id
    assert review.holderHarness == "claude"
    assert review.holderProvider == "anthropic"

    unknown =
      assign_call({:user, "flynn"}, "unknown review")
      |> put_in([:params, :reviews_assignment_id], "asg_missing")

    assert %{code: "unknown_review_target"} = handle(ctx, "assign", unknown)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'unknown review'")
  end

  test "attests rebuild reaches the full checked shape from every prior version" do
    for starting_shape <- [:bare, :check_tier, :partial_p3] do
      db = :"attests_#{starting_shape}_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: db,
        start: {DB, :start_link, [[path: ":memory:", name: db]]}
      })

      :ok = DB.execute(db, migration_base_ddl())
      :ok = DB.execute(db, prior_attests_ddl(starting_shape))

      {:ok, _} =
        DB.query(
          db,
          prior_attest_insert(starting_shape)
        )

      :ok = WorkItems.ensure_schema(db)
      :ok = Assignments.ensure_schema(db)
      :ok = Assignments.ensure_schema(db)

      assert [%{id: "att_old"} = old] = Assignments.list_attests(db, "asg_old")
      assert old.byHarness == nil
      assert old.byProvider == nil
      assert old.producer == nil
      assert old.producerCommand == nil
      assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")

      {:ok, [[sql]]} =
        DB.query(db, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'attests'")

      for fragment <- [
            "producer TEXT NULL",
            "producerCommand TEXT NULL",
            "byHarness TEXT NULL",
            "byProvider TEXT NULL",
            "CHECK(producer IS NULL OR kind = 'verdict')",
            "CHECK(producerCommand IS NULL OR producer IS NOT NULL)",
            "CHECK(byHarness IS NULL OR kind = 'verdict')",
            "CHECK(byProvider IS NULL OR kind = 'verdict')",
            "CHECK(note IS NULL OR length(trim(note)) BETWEEN 1 AND 2000)"
          ] do
        assert sql =~ fragment
      end

      for {id, columns, values} <- [
            {"bad_producer", "producer", "'build'"},
            {"bad_harness", "byHarness", "'claude'"},
            {"bad_provider", "byProvider", "'anthropic'"}
          ] do
        assert {:error, %DB.Error{message: message}} =
                 DB.query(
                   db,
                   "INSERT INTO attests (id, assignmentId, kind, note, bySession, #{columns}, ts) VALUES ('#{id}', 'asg_old', 'progress', NULL, 'holder', #{values}, 2)"
                 )

        assert message =~ "CHECK constraint"
      end

      assert {:error, %DB.Error{message: message}} =
               DB.query(
                 db,
                 "INSERT INTO attests (id, assignmentId, kind, verdictKind, bySession, producerCommand, ts) VALUES ('bad_command', 'asg_old', 'verdict', 'tests-passed', 'holder', 'mix test', 2)"
               )

      assert message =~ "CHECK constraint"
    end
  end

  test "declared files dedupe silently and overlap is transactionally serialized", ctx do
    paths = ["lib/a.ex", "lib/b.ex", "lib/a.ex", "../kept", "/absolute/kept"]

    first =
      assign_call({:user, "flynn"}, "files")
      |> put_in([:params, :files], paths)
      |> then(&handle(ctx, "assign", &1))

    assert Assignments.declared_files(ctx.db, first.id) ==
             Enum.sort(["lib/a.ex", "lib/b.ex", "../kept", "/absolute/kept"])

    assert Assignments.open_assignments_touching(ctx.db, ["lib/a.ex"]) == [first.id]
    assert Assignments.open_assignments_touching(ctx.db, ["lib/a.ex"], first.id) == []
    assert Assignments.open_assignments_touching(ctx.db, ["not-declared"]) == []
    assert Assignments.open_assignments_touching(ctx.db, []) == []

    overlapping =
      assign_call({:user, "flynn"}, "overlap")
      |> put_in([:params, :files], ["lib/a.ex"])

    assert %{code: "files_overlap", message: message} = handle(ctx, "assign", overlapping)
    assert message =~ first.id

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'overlap'")

    malformed =
      assign_call({:user, "flynn"}, "malformed")
      |> put_in([:params, :files], ["ok", " "])

    assert %{code: "invalid_files"} = handle(ctx, "assign", malformed)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'malformed'")

    no_files = handle(ctx, "assign", assign_call({:user, "flynn"}, "no files"))
    assert Assignments.declared_files(ctx.db, no_files.id) == []

    disjoint =
      for {subject, path} <- [{"disjoint one", "one"}, {"disjoint two", "two"}] do
        assign_call({:user, "flynn"}, subject)
        |> put_in([:params, :files], [path])
        |> then(&handle(ctx, "assign", &1))
      end

    assert Enum.all?(disjoint, &is_binary(&1.id))

    concurrent =
      for subject <- ["race one", "race two"] do
        Task.async(fn ->
          assign_call({:user, "flynn"}, subject)
          |> put_in([:params, :files], ["same-race-path"])
          |> then(&handle(ctx, "assign", &1))
        end)
      end
      |> Task.await_many()

    assert Enum.count(concurrent, &(&1[:code] == "files_overlap")) == 1
    assert Enum.count(concurrent, &is_binary(&1[:id])) == 1

    _closed = handle(ctx, "attest", attest_call({:session, "holder"}, first.id, "completion"))

    after_close =
      assign_call({:user, "flynn"}, "after close")
      |> put_in([:params, :files], ["lib/a.ex"])
      |> then(&handle(ctx, "assign", &1))

    assert is_binary(after_close.id)
  end

  test "ordinary and producer verdicts freeze provenance and expose produced reads", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "verdict stamps"))

    ordinary =
      handle(ctx, "attest", %{
        attest_call({:session, "holder"}, assignment.id, "verdict")
        | params: %{assignment_id: assignment.id, kind: "verdict", verdict_kind: "reviewed-clean"}
      })

    assert ordinary.attest.byHarness == "claude"
    assert ordinary.attest.byProvider == "anthropic"
    assert ordinary.attest.producer == nil
    assert ordinary.attest.producerCommand == nil

    user_verdict =
      handle(ctx, "attest", %{
        attest_call({:user, "flynn"}, assignment.id, "verdict")
        | params: %{assignment_id: assignment.id, kind: "verdict", verdict_kind: "user-ruling"}
      })

    assert user_verdict.attest.byHarness == nil
    assert user_verdict.attest.byProvider == nil

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET harness = 'codex', provider = 'openai' WHERE sessionKey = 'holder'"
      )

    assert {:ok, {:ok, produced}} =
             DB.transaction(ctx.db, fn txn ->
               Assignments.insert_producer_verdict_in_txn(txn, %{
                 assignment_id: assignment.id,
                 verdict_kind: "tests-passed",
                 producer: "build",
                 producer_command: "mix test --seed 0",
                 by_session: "holder",
                 by_user: nil,
                 by_harness: "claude",
                 by_provider: "anthropic"
               })
             end)

    assert produced.producer == "build"
    assert produced.producerCommand == "mix test --seed 0"
    assert produced.byHarness == "claude"
    assert produced.byProvider == "anthropic"
    assert Assignments.produced_verdict_kinds(ctx.db, assignment.id) == ["tests-passed"]

    rows = Assignments.list_attests(ctx.db, assignment.id)
    assert Enum.find(rows, &(&1.id == ordinary.attest.id)).byHarness == "claude"
    assert Enum.find(rows, &(&1.id == produced.id)).producerCommand == "mix test --seed 0"

    closed = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "completion"))
    assert closed.assignment.state == "closed"

    assert {:ok, {:error, %{code: "assignment_closed"}}} =
             DB.transaction(ctx.db, fn txn ->
               Assignments.insert_producer_verdict_in_txn(txn, producer_input(assignment.id))
             end)

    assert {:ok, {:error, %{code: "unknown_assignment"}}} =
             DB.transaction(ctx.db, fn txn ->
               Assignments.insert_producer_verdict_in_txn(txn, producer_input("missing"))
             end)
  end

  test "commissioned review authors enforce the full review-link predicate", ctx do
    third = session(ctx.db, "third-session", "other", %{harness: "codex", provider: "openai"})
    producer = handle(ctx, "assign", assign_call({:user, "flynn"}, "producer assignment"))

    valid_review =
      assign_call({:user, "flynn"}, "valid review")
      |> Map.put(:session_key, third.session_key)
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    valid =
      attest_call({:session, third.session_key}, valid_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    wrong_producer = handle(ctx, "assign", assign_call({:user, "flynn"}, "other producer"))

    wrong_review =
      assign_call({:user, "flynn"}, "wrong-link review")
      |> Map.put(:session_key, third.session_key)
      |> put_in([:params, :reviews_assignment_id], wrong_producer.id)
      |> then(&handle(ctx, "assign", &1))

    _wrong_link_verdict =
      attest_call({:session, third.session_key}, wrong_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "wrong-link")
      |> then(&handle(ctx, "attest", &1))

    direct =
      attest_call({:session, third.session_key}, producer.id, "verdict")
      |> put_in([:params, :verdict_kind], "direct-does-not-count")

    _ = handle(ctx, "attest", direct)

    third_party =
      attest_call({:session, "other-session"}, valid_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "third-party")

    _ = handle(ctx, "attest", third_party)

    user =
      attest_call({:user, "flynn"}, valid_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "user-verdict")

    _ = handle(ctx, "attest", user)

    self_commissioned =
      assign_call({:session, "holder"}, "self commissioned")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    self_verdict =
      attest_call({:session, "other-session"}, self_commissioned.id, "verdict")
      |> put_in([:params, :verdict_kind], "self-commissioned")

    _ = handle(ctx, "attest", self_verdict)

    assert Assignments.commissioned_review_authors(ctx.db, producer.id, "holder") == [
             %{
               verdict_kind: valid.attest.verdictKind,
               by_harness: "codex",
               by_provider: "openai"
             }
           ]
  end

  test "prefixed idempotency scopes disjoint equal user and session strings", ctx do
    user = handle(ctx, "assign", assign_call({:user, "holder"}, "user", "collision"))
    session = handle(ctx, "assign", assign_call({:session, "holder"}, "session", "collision"))
    refute user.id == session.id

    assert {:ok, [["session:holder"], ["user:holder"]]} =
             DB.query(
               ctx.db,
               "SELECT ownerUserId FROM wire_idempotency WHERE operation = 'assign' ORDER BY ownerUserId"
             )
  end

  test "attest lifecycle, authorization precedence, and terminal race are atomic", ctx do
    assignment = handle(ctx, "assign", assign_call({:session, "holder"}, "work"))

    assert %{code: "process_denied"} =
             handle(ctx, "attest", attest_call({:process, "cron"}, assignment.id, "progress"))

    assert %{code: "principal_required"} =
             handle(ctx, "attest", attest_call(nil, assignment.id, "progress"))

    assert %{code: "not_holder"} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "other-session"}, assignment.id, "progress")
             )

    assert %{code: "not_holder"} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "other-session"}, assignment.id, "bogus")
             )

    assert %{code: "missing_verdict_kind"} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "other-session"}, assignment.id, "verdict")
             )

    assert %{code: "not_holder"} =
             handle(ctx, "attest", attest_call({:user, "flynn"}, assignment.id, "progress"))

    assert %{code: "invalid_kind"} =
             handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "bogus"))

    assert %{code: "missing_verdict_kind"} =
             handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "verdict"))

    assert %{code: "invalid_note"} =
             handle(ctx, "attest", %{
               attest_call({:session, "holder"}, assignment.id, "progress")
               | params: %{assignment_id: assignment.id, kind: "progress", note: " "}
             })

    assert %{code: "unknown_assignment"} =
             handle(ctx, "attest", attest_call({:session, "holder"}, "missing", "progress"))

    progress = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "progress"))
    assert progress.assignment.state == "open"
    assert progress.attest.kind == "progress"

    completed =
      handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "completion"))

    assert completed.assignment.state == "closed"
    assert completed.assignment.outcome == "completed"
    assert completed.assignment.closingAttestId == completed.attest.id

    race = handle(ctx, "assign", assign_call({:session, "holder"}, "race"))

    complete =
      Task.async(fn ->
        handle(ctx, "attest", attest_call({:session, "holder"}, race.id, "completion"))
      end)

    revoke =
      Task.async(fn ->
        handle(ctx, "revoke-assignment", revoke_call({:session, "holder"}, race.id))
      end)

    results = Task.await_many([complete, revoke])
    assert Enum.count(results, &(&1[:code] == "assignment_closed")) == 1
    winner = Enum.find(results, &(&1[:code] != "assignment_closed"))
    assert winner

    assert {:ok, [[count]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM attests WHERE assignmentId = ?1 AND kind = 'completion'",
               [race.id]
             )

    assert count in [0, 1]
    assert (winner[:attest] && count == 1) || (!winner[:attest] && count == 0)

    terminal = handle(ctx, "assign", assign_call({:session, "holder"}, "terminal"))
    closed = handle(ctx, "attest", attest_call({:session, "holder"}, terminal.id, "surrender"))
    assert closed.assignment.outcome == "surrendered"
    assert closed.assignment.closingAttestId == closed.attest.id

    assert %{code: "assignment_closed"} =
             handle(ctx, "attest", attest_call({:session, "holder"}, terminal.id, "progress"))

    assert %{code: "assignment_closed"} =
             handle(ctx, "attest", attest_call({:session, "holder"}, terminal.id, "verdict"))
  end

  test "work lifecycle markers land in the actor transcript with exact event text", ctx do
    completed = handle(ctx, "assign", assign_call({:user, "flynn"}, "completed markers"))

    progress =
      handle(ctx, "attest", attest_call({:session, "holder"}, completed.id, "progress"))

    verdict_call =
      attest_call({:session, "holder"}, completed.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")

    verdict = handle(ctx, "attest", verdict_call)

    marker_count_before_user_verdict = length(marker_contents(ctx.db, "holder"))

    user_verdict_call =
      attest_call({:user, "flynn"}, completed.id, "verdict")
      |> put_in([:params, :verdict_kind], "user-ruling")

    user_verdict = handle(ctx, "attest", user_verdict_call)

    assert length(marker_contents(ctx.db, "holder")) == marker_count_before_user_verdict

    completion =
      handle(ctx, "attest", attest_call({:session, "holder"}, completed.id, "completion"))

    surrendered = handle(ctx, "assign", assign_call({:user, "flynn"}, "surrender markers"))

    surrender =
      handle(ctx, "attest", attest_call({:session, "holder"}, surrendered.id, "surrender"))

    revoked = handle(ctx, "assign", assign_call({:user, "flynn"}, "revoke markers"))
    revocation = handle(ctx, "revoke-assignment", revoke_call({:user, "flynn"}, revoked.id))

    assert marker_contents(ctx.db, "holder") == [
             "[assignment opened: #{completed.id}]",
             "[progress filed on #{completed.id}]",
             "[verdict filed: reviewed-clean on #{completed.id}]",
             "[completion filed on #{completed.id}]",
             "[assignment closed: #{completed.id} — completed]",
             "[assignment opened: #{surrendered.id}]",
             "[surrendered #{surrendered.id} — needs user input]",
             "[assignment closed: #{surrendered.id} — surrendered]",
             "[assignment opened: #{revoked.id}]",
             "[assignment revoked: #{revoked.id}]"
           ]

    assert progress.attest.kind == "progress"
    assert verdict.attest.verdictKind == "reviewed-clean"
    assert user_verdict.attest.byUser == "flynn"
    assert completion.assignment.outcome == "completed"
    assert completion.assignment.closingAttestId == completion.attest.id
    assert surrender.assignment.outcome == "surrendered"
    assert surrender.assignment.closingAttestId == surrender.attest.id
    assert revocation.outcome == "revoked"
    assert revocation.closingAttestId == nil

    assert Enum.all?(Projection.list_after(ctx.db, "holder", nil, 100), fn marker ->
             marker.role == "assistant" and marker.sender == "process:tightbeam"
           end)
  end

  test "a marker insert failure does not fail the underlying attest", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "marker failure"))
    :ok = DB.execute(ctx.db, "DROP TABLE messages")

    result =
      handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "progress"))

    assert result.assignment.id == assignment.id
    assert result.attest.kind == "progress"
    assert Assignments.attest_count(ctx.db, assignment.id) == 1
  end

  test "revoke permits admin and typed openers, denies others, and creates no attest", ctx do
    for {principal, opener} <- [
          {{:user, "admin"}, {:user, "flynn"}},
          {{:user, "flynn"}, {:user, "flynn"}},
          {{:session, "holder"}, {:session, "holder"}}
        ] do
      assignment = handle(ctx, "assign", assign_call(opener, inspect(principal)))
      revoked = handle(ctx, "revoke-assignment", revoke_call(principal, assignment.id))
      assert revoked.outcome == "revoked"
      assert revoked.closingAttestId == nil
    end

    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "deny"))

    assert %{code: "not_authorized"} =
             handle(ctx, "revoke-assignment", revoke_call({:user, "other"}, assignment.id))

    assert %{code: "process_denied"} =
             handle(ctx, "revoke-assignment", revoke_call({:process, "x"}, assignment.id))

    assert %{code: "principal_required"} =
             handle(ctx, "revoke-assignment", revoke_call(nil, assignment.id))

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM attests")
  end

  test "query filters, deterministic ordering, role-resolved holder input, and open_count", ctx do
    a = handle(ctx, "assign", assign_call({:user, "flynn"}, "a"))
    b = handle(ctx, "assign", assign_call({:user, "flynn"}, "b"))
    _ = handle(ctx, "attest", attest_call({:session, "holder"}, a.id, "completion"))
    {:ok, _} = DB.query(ctx.db, "UPDATE assignments SET openedAt = 99")

    assert Assignments.open_count(ctx.db, "holder") == 1

    assert Enum.map(Assignments.list(ctx.db, %{state: "all"}), & &1.id) ==
             Enum.sort([a.id, b.id], :desc)

    assert Enum.map(Assignments.list(ctx.db, %{state: "open", holder_key: "holder"}), & &1.id) ==
             [b.id]

    assert %{assignments: [_]} =
             handle(ctx, "assignments", query_call({:user, "flynn"}, "open", "holder"))

    assert %{code: "invalid_state_filter"} =
             handle(ctx, "assignments", query_call({:user, "flynn"}, "bad", nil))

    assert %{code: "process_denied"} =
             handle(ctx, "assignments", query_call({:process, "x"}, "bad", nil))

    assert %{code: "principal_required"} =
             handle(ctx, "assignments", query_call(nil, "open", nil))
  end

  test "each accepted verb emits one event and a real statute denies assign", ctx do
    assignment = dispatch!(ctx, assign_call({:session, "holder"}, "events"))
    dispatch!(ctx, attest_call({:session, "holder"}, assignment.id, "progress"))
    dispatch!(ctx, query_call({:session, "holder"}, "open", nil))
    dispatch!(ctx, revoke_call({:session, "holder"}, assignment.id))

    assert {:ok, [[4]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM events WHERE kind = 'verb' AND verb IN ('assign','attest','assignments','revoke-assignment')"
             )

    base = Path.join(System.tmp_dir!(), "assignment-rules-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "identity/rules"))

    File.write!(Path.join(base, "identity/rules/deny.toml"), """
    [[rule]]
    name = "deny-assign"
    verb = "assign"
    text = "assign denied"
    [[rule.deny_when]]
    fact = "caller.origin_class"
    op = "eq"
    value = "agent"
    """)

    on_exit(fn -> File.rm_rf!(base) end)
    Rules.load!(base, Map.keys(ctx.handlers), %{})

    assert {:error, %{code: "rule_denied"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, assign_call({:session, "holder"}, "denied"))
  end

  test "zero rules allow completion without verdicts and verdict emits one verb event", ctx do
    completion_assignment = dispatch!(ctx, assign_call({:session, "holder"}, "completion"))

    assert {:ok, %{assignment: closed, attest: completion}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               attest_call({:session, "holder"}, completion_assignment.id, "completion")
             )

    assert closed.state == "closed"
    assert completion.verdictKind == nil
    assert completion.byUser == nil

    assert {:ok, [[before_verdict]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM events WHERE kind = 'verb' AND verb = 'attest'"
             )

    verdict_assignment = dispatch!(ctx, assign_call({:session, "holder"}, "verdict event"))

    verdict_call =
      attest_call({:user, "flynn"}, verdict_assignment.id, "verdict")
      |> put_in([:params, :verdict_kind], "tests-passed")

    assert {:ok, %{attest: verdict}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, verdict_call)

    assert verdict.verdictKind == "tests-passed"

    assert {:ok, [[after_verdict]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM events WHERE kind = 'verb' AND verb = 'attest'"
             )

    assert after_verdict == before_verdict + 1
  end

  test "attests returns every kind in timestamp and id order", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "all attests"))

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO attests
          (id, assignmentId, kind, verdictKind, note, bySession, byUser, ts)
        VALUES
          ('att_progress', ?1, 'progress', NULL, NULL, 'holder', NULL, 30),
          ('att_completion', ?1, 'completion', NULL, NULL, 'holder', NULL, 20),
          ('att_surrender', ?1, 'surrender', NULL, NULL, 'holder', NULL, 20),
          ('att_verdict', ?1, 'verdict', 'reviewed-clean', NULL, NULL, 'flynn', 10)
        """,
        [assignment.id]
      )

    assert %{attests: attests} =
             handle(
               ctx,
               "attests",
               call("attests", {:user, "flynn"}, nil, %{assignment_id: assignment.id})
             )

    assert Enum.map(attests, &{&1.kind, &1.ts, &1.id}) == [
             {"verdict", 10, "att_verdict"},
             {"completion", 20, "att_completion"},
             {"surrender", 20, "att_surrender"},
             {"progress", 30, "att_progress"}
           ]
  end

  test "accepted handler commit survives event append failure", ctx do
    {:ok, _} = DB.query(ctx.db, "DROP TABLE events")

    assert_raise MatchError, fn ->
      Dispatch.dispatch(ctx.db, ctx.handlers, assign_call({:session, "holder"}, "committed"))
    end

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'committed'")
  end

  defp handle(ctx, verb, call)
       when verb in [
              "assign",
              "dispatch",
              "assignment-get",
              "attest",
              "attests",
              "revoke-assignment",
              "assignments"
            ],
       do: Assignments.__handle__(ctx.db, verb, %{call | verb: verb})

  defp handle(ctx, verb, call), do: WorkItems.__handle__(ctx.db, verb, %{call | verb: verb})

  defp dispatch!(ctx, call) do
    assert {:ok, result} = Dispatch.dispatch(ctx.db, ctx.handlers, call)
    result
  end

  defp marker_contents(db, session_key) do
    db
    |> Projection.list_after(session_key, nil, 100)
    |> Enum.map(& &1.content)
  end

  defp assign_call(principal, subject \\ "work", key \\ nil, work_item_id \\ nil) do
    call("assign", principal, "holder", %{
      subject: subject,
      idempotency_key: key,
      work_item_id: work_item_id
    })
    |> Map.merge(%{target_role: nil, role_fallback: false})
  end

  defp dispatch_call(principal, subject, brief, key \\ nil, work_item_id \\ nil) do
    call("dispatch", principal, "holder", %{
      subject: subject,
      brief: brief,
      idempotency_key: key,
      work_item_id: work_item_id
    })
    |> Map.merge(%{target_role: nil, role_fallback: false})
  end

  defp work_item_call(verb, principal, params), do: call(verb, principal, nil, params)

  defp attest_call(principal, id, kind),
    do: call("attest", principal, nil, %{assignment_id: id, kind: kind})

  defp assignment_get_call(principal, id),
    do: call("assignment-get", principal, nil, %{assignment_id: id})

  defp revoke_call(principal, id),
    do: call("revoke-assignment", principal, nil, %{assignment_id: id})

  defp query_call(principal, state, holder),
    do: call("assignments", principal, holder, %{state: state})

  defp call(verb, principal, target, params) do
    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: target,
      params: params
    }
  end

  defp origin({:session, key}), do: "agent:#{key}"
  defp origin({:user, user}), do: "user:#{user}"
  defp origin({:process, process}), do: "process:#{process}"
  defp origin(nil), do: "agent:declared"

  defp producer_input(assignment_id) do
    %{
      assignment_id: assignment_id,
      verdict_kind: "tests-passed",
      producer: "build",
      producer_command: "mix test",
      by_session: "holder",
      by_user: nil,
      by_harness: "claude",
      by_provider: "anthropic"
    }
  end

  defp migration_base_ddl do
    """
    CREATE TABLE users (userId TEXT PRIMARY KEY);
    CREATE TABLE sessions (
      sessionKey TEXT PRIMARY KEY, harness TEXT NOT NULL, provider TEXT NOT NULL,
      state TEXT NOT NULL
    );
    INSERT INTO users (userId) VALUES ('flynn');
    INSERT INTO sessions (sessionKey, harness, provider, state)
      VALUES ('holder', 'claude', 'anthropic', 'active');
    CREATE TABLE assignments (
      id TEXT PRIMARY KEY, subject TEXT NOT NULL, holderKey TEXT NOT NULL,
      holderRole TEXT NULL, holderFallback INTEGER NOT NULL DEFAULT 0,
      openedByUser TEXT NULL, openedBySession TEXT NULL, openedAt INTEGER NOT NULL,
      state TEXT NOT NULL DEFAULT 'open', outcome TEXT NULL, closedAt INTEGER NULL,
      closedByUser TEXT NULL, closedBySession TEXT NULL, closingAttestId TEXT NULL
    );
    INSERT INTO assignments
      (id, subject, holderKey, openedByUser, openedAt, state)
      VALUES ('asg_old', 'old', 'holder', 'flynn', 1, 'open')
    """
  end

  defp prior_attests_ddl(:bare) do
    """
    CREATE TABLE attests (
      id TEXT PRIMARY KEY, assignmentId TEXT NOT NULL REFERENCES assignments(id),
      kind TEXT NOT NULL, note TEXT NULL,
      bySession TEXT NULL REFERENCES sessions(sessionKey), ts INTEGER NOT NULL
    )
    """
  end

  defp prior_attests_ddl(:check_tier) do
    """
    CREATE TABLE attests (
      id TEXT PRIMARY KEY, assignmentId TEXT NOT NULL REFERENCES assignments(id),
      kind TEXT NOT NULL CHECK(kind IN ('progress', 'completion', 'surrender', 'verdict')),
      verdictKind TEXT NULL, note TEXT NULL,
      bySession TEXT NULL REFERENCES sessions(sessionKey),
      byUser TEXT NULL REFERENCES users(userId), ts INTEGER NOT NULL
    )
    """
  end

  defp prior_attests_ddl(:partial_p3) do
    """
    CREATE TABLE attests (
      id TEXT PRIMARY KEY, assignmentId TEXT NOT NULL REFERENCES assignments(id),
      kind TEXT NOT NULL CHECK(kind IN ('progress', 'completion', 'surrender', 'verdict')),
      verdictKind TEXT NULL, note TEXT NULL,
      bySession TEXT NULL REFERENCES sessions(sessionKey),
      byUser TEXT NULL REFERENCES users(userId), producer TEXT NULL,
      producerCommand TEXT NULL, ts INTEGER NOT NULL,
      CHECK(producer IS NULL OR kind = 'verdict'),
      CHECK(producerCommand IS NULL OR producer IS NOT NULL)
    )
    """
  end

  defp prior_attest_insert(:bare) do
    "INSERT INTO attests (id, assignmentId, kind, note, bySession, ts) VALUES ('att_old', 'asg_old', 'progress', 'old', 'holder', 1)"
  end

  defp prior_attest_insert(:check_tier) do
    "INSERT INTO attests (id, assignmentId, kind, verdictKind, note, bySession, byUser, ts) VALUES ('att_old', 'asg_old', 'progress', NULL, 'old', 'holder', NULL, 1)"
  end

  defp prior_attest_insert(:partial_p3) do
    "INSERT INTO attests (id, assignmentId, kind, verdictKind, note, bySession, byUser, producer, producerCommand, ts) VALUES ('att_old', 'asg_old', 'progress', NULL, 'old', 'holder', NULL, NULL, NULL, 1)"
  end

  defp session(db, key, owner, overrides \\ %{}) do
    input = %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: "fable",
      host: "eezo"
    }

    Org.create(db, Map.merge(input, overrides))
  end
end
