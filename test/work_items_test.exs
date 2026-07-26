defmodule Tightbeam.WorkItemsTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{
    Assignments,
    DB,
    Devices,
    Dispatch,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Roles,
    Rules,
    Wakes,
    WorkItems,
    WorkState
  }

  @sha String.duplicate("a", 64)
  @sha2 String.duplicate("b", 64)

  setup do
    db = :work_items_db
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [
          Tightbeam.CausalEvents,
          Devices,
          Idempotency,
          Ledger,
          Org,
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
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1), ('other', 0, 1)"
      )

    holder = session(db, "holder", "flynn")
    other = session(db, "other-holder", "other")
    handlers = Gateway.handlers(%{db: db})
    Rules.load!(System.tmp_dir!(), Map.keys(handlers), %{})
    %{db: db, holder: holder, other: other, handlers: handlers}
  end

  test "schema pins typed creator, paired spec ref, owner, and the four disposition states",
       %{db: db} do
    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")

    base =
      "INSERT INTO work_items (id, title, specRefName, specRefSha256, ownerUserId, state, createdByUser, createdBySession, createdAt) VALUES "

    for values <- [
          "('wi_none','x',NULL,NULL,'flynn','open',NULL,NULL,1)",
          "('wi_both','x',NULL,NULL,'flynn','open','flynn','holder',1)",
          "('wi_name','x','spec',NULL,'flynn','open','flynn',NULL,1)",
          "('wi_sha','x',NULL,'#{@sha}','flynn','open','flynn',NULL,1)",
          "('wi_blank','   ',NULL,NULL,'flynn','open','flynn',NULL,1)",
          "('wi_upper','x','spec','#{String.upcase(@sha)}','flynn','open','flynn',NULL,1)",
          "('wi_state','x',NULL,NULL,'flynn','bogus','flynn',NULL,1)"
        ] do
      assert {:error, %DB.Error{message: message}} = DB.query(db, base <> values)
      assert message =~ "CHECK constraint"
    end

    # ownerUserId is NOT NULL — the owner is always a user (constitution §3).
    assert {:error, %DB.Error{message: null_message}} =
             DB.query(
               db,
               "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES ('wi_noowner','x',NULL,'flynn',1)"
             )

    assert null_message =~ "NOT NULL constraint failed: work_items.ownerUserId"

    assert {:ok, columns} = DB.query(db, "PRAGMA table_info(work_items)")

    assert Enum.map(columns, fn [_cid, name | _] -> name end) == [
             "id",
             "title",
             "specRefName",
             "specRefSha256",
             "isBug",
             "ownerUserId",
             "state",
             "failReason",
             "routingWakeId",
             "slateWakeId",
             "createdByUser",
             "createdBySession",
             "createdInTurnSeq",
             "createdContextKnown",
             "createdAt"
           ]

    assert {:ok, assignment_columns} = DB.query(db, "PRAGMA table_info(assignments)")
    assert Enum.any?(assignment_columns, fn [_cid, name | _] -> name == "workItemId" end)

    assert {:ok, assignment_fks} = DB.query(db, "PRAGMA foreign_key_list(assignments)")

    assert Enum.any?(assignment_fks, fn [_id, _seq, table, from, to | _] ->
             table == "work_items" and from == "workItemId" and to == "id"
           end)
  end

  test "create validates every field and records session or user creator", ctx do
    assert %{code: "process_denied"} = create(ctx, {:process, "cron"}, %{title: "x"})
    assert %{code: "principal_required"} = create(ctx, nil, %{title: "x"})

    for title <- [nil, " ", String.duplicate("x", 2001)] do
      assert %{code: "invalid_title"} = create(ctx, {:user, "flynn"}, %{title: title})
    end

    for params <- [
          %{title: "x", spec_ref_name: "spec"},
          %{title: "x", spec_ref_sha256: @sha},
          %{title: "x", spec_ref_name: " ", spec_ref_sha256: @sha},
          %{title: "x", spec_ref_name: String.duplicate("x", 2001), spec_ref_sha256: @sha},
          %{title: "x", spec_ref_name: "spec", spec_ref_sha256: String.upcase(@sha)},
          %{title: "x", spec_ref_name: "spec", spec_ref_sha256: "abc"},
          %{title: "x", spec_ref_name: "spec", spec_ref_sha256: String.duplicate("g", 64)}
        ] do
      assert %{code: "invalid_spec_ref"} = create(ctx, {:user, "flynn"}, params)
    end

    user = create(ctx, {:user, "flynn"}, %{title: "User item"})
    assert String.starts_with?(user.id, "wi_")
    assert user.createdByUser == "flynn"
    assert user.createdBySession == nil
    assert user.specRefName == nil
    assert user.specRefSha256 == nil
    refute user.isBug

    assert %{code: "invalid_is_bug"} =
             create(ctx, {:user, "flynn"}, %{title: "Invalid bug", is_bug: "yes"})

    session =
      create(ctx, {:session, "holder"}, %{
        title: "Session item",
        spec_ref_name: "spec.md",
        spec_ref_sha256: @sha,
        is_bug: true
      })

    assert session.createdBySession == "holder"
    assert session.createdByUser == nil
    assert session.specRefName == "spec.md"
    assert session.specRefSha256 == @sha
    assert session.isBug
  end

  test "Proof 1: an item created during a running turn carries that seq with known = 1; created with no running turn carries NULL with known = 1",
       ctx do
    running_seq = running_turn!(ctx.db, "holder")
    during = create(ctx, {:session, "holder"}, %{title: "During turn"})

    assert {:ok, [[^running_seq, 1]]} =
             creation_context(ctx.db, during.id)

    :ok = Ledger.finish(ctx.db, running_seq, "delivered")
    idle = create(ctx, {:session, "holder"}, %{title: "No running turn"})

    assert {:ok, [[nil, 1]]} = creation_context(ctx.db, idle.id)
  end

  test "Proof 3: a bracket-turn create (jobRef, no assignment) stamps the turn", ctx do
    running_seq = running_turn!(ctx.db, "holder", job_ref: "wi_bracket")
    item = create(ctx, {:session, "holder"}, %{title: "Bracket create"})

    assert {:ok, [[^running_seq, nil, "wi_bracket"]]} =
             DB.query(
               ctx.db,
               """
               SELECT w.createdInTurnSeq, t.assignmentId, t.jobRef
               FROM work_items AS w
               JOIN turns AS t ON t.seq = w.createdInTurnSeq
               WHERE w.id = ?1
               """,
               [item.id]
             )
  end

  test "Proof 4: migration uses two additive columns, existing rows land known = 0, and createdInTurnSeq is indexed" do
    db = :"c1_migration_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: db,
      start: {DB, :start_link, [[path: ":memory:", name: db]]}
    })

    :ok =
      DB.execute(
        db,
        """
        CREATE TABLE work_items (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 2000),
          specRefName TEXT NULL,
          specRefSha256 TEXT NULL,
          isBug INTEGER NOT NULL DEFAULT 0,
          ownerUserId TEXT NOT NULL,
          state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','iceboxed','closed','failed')),
          failReason TEXT NULL,
          routingWakeId TEXT NULL,
          slateWakeId TEXT NULL,
          createdByUser TEXT NULL,
          createdBySession TEXT NULL,
          createdAt INTEGER NOT NULL
        );
        INSERT INTO work_items
          (id, title, ownerUserId, createdByUser, createdAt)
        VALUES ('wi_legacy', 'legacy', 'flynn', 'flynn', 1);
        """
      )

    :ok = WorkItems.ensure_schema(db)

    assert {:ok, [[nil, 0]]} = creation_context(db, "wi_legacy")

    assert {:ok, indexes} = DB.query(db, "PRAGMA index_list(work_items)")

    assert Enum.any?(indexes, fn [_seq, name | _] ->
             name == "work_items_created_in_turn"
           end)
  end

  test "Proof 5: a cancel-then-arriving create lands known = 1, seq = NULL", ctx do
    running_seq = running_turn!(ctx.db, "holder")
    :ok = Ledger.finish(ctx.db, running_seq, "canceled")

    item = create(ctx, {:session, "holder"}, %{title: "Arrived after cancel"})

    assert {:ok, [[nil, 1]]} = creation_context(ctx.db, item.id)
  end

  test "update implements the complete PATCH matrix", ctx do
    assert %{code: "process_denied"} = update(ctx, {:process, "cron"}, "missing", %{})
    assert %{code: "principal_required"} = update(ctx, nil, "missing", %{})
    assert %{code: "unknown_work_item"} = update(ctx, {:user, "flynn"}, "missing", %{})

    unpinned = create(ctx, {:user, "flynn"}, %{title: "Original"})
    assert %{code: "invalid_title"} = update(ctx, {:user, "flynn"}, unpinned.id, %{title: " "})

    assert %{code: "invalid_spec_ref"} =
             update(ctx, {:user, "flynn"}, unpinned.id, %{spec_ref_name: "spec.md"})

    assert %{code: "invalid_spec_ref"} =
             update(ctx, {:user, "flynn"}, unpinned.id, %{spec_ref_sha256: @sha})

    noop = update(ctx, {:user, "flynn"}, unpinned.id, %{})
    assert noop == unpinned
    assert update(ctx, {:user, "flynn"}, unpinned.id, %{}) == noop

    assert %{code: "invalid_is_bug"} =
             update(ctx, {:user, "flynn"}, unpinned.id, %{is_bug: nil})

    bug = update(ctx, {:user, "flynn"}, unpinned.id, %{is_bug: true})
    assert bug.isBug
    refute update(ctx, {:user, "flynn"}, unpinned.id, %{is_bug: false}).isBug

    pinned =
      update(ctx, {:user, "flynn"}, unpinned.id, %{
        spec_ref_name: "spec.md",
        spec_ref_sha256: @sha
      })

    assert pinned.title == "Original"
    assert pinned.specRefName == "spec.md"
    assert pinned.specRefSha256 == @sha

    repinned = update(ctx, {:user, "flynn"}, pinned.id, %{spec_ref_sha256: @sha2})
    assert repinned.specRefName == "spec.md"
    assert repinned.specRefSha256 == @sha2

    titled = update(ctx, {:user, "flynn"}, pinned.id, %{title: "Retitled"})
    assert titled.title == "Retitled"
    assert titled.specRefName == "spec.md"
    assert titled.specRefSha256 == @sha2
    assert update(ctx, {:user, "flynn"}, pinned.id, %{title: "Retitled"}) == titled

    assert %{code: "invalid_spec_ref"} =
             update(ctx, {:user, "flynn"}, pinned.id, %{
               spec_ref_name: nil,
               spec_ref_sha256: @sha
             })

    cleared = update(ctx, {:user, "flynn"}, pinned.id, %{spec_ref_name: nil})
    assert cleared.specRefName == nil
    assert cleared.specRefSha256 == nil

    # The metadata doorbell (observability-v1 §work_item_events, kind="metadata")
    # fires on a real metadata change and is silent on a no-op. observability-v1
    # OWNS this doorbell; work-item-v1 §Mutability flags the card-refresh need.
    change_call =
      update_call({:user, "flynn"}, pinned.id, %{title: "Retitled again"})
      |> Map.put(:on_work_item_change, fn _, _ -> send(self(), :work_item_change) end)

    assert WorkItems.__handle__(ctx.db, "work-item-update", change_call).title ==
             "Retitled again"

    assert_received :work_item_change

    noop_call =
      update_call({:user, "flynn"}, pinned.id, %{title: "Retitled again"})
      |> Map.put(:on_work_item_change, fn _, _ -> send(self(), :work_item_change) end)

    assert WorkItems.__handle__(ctx.db, "work-item-update", noop_call).title ==
             "Retitled again"

    refute_received :work_item_change
  end

  test "schema migration adds the org-set bug attribute with a false default" do
    legacy = :"legacy_work_items_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: legacy,
      start: {DB, :start_link, [[path: ":memory:", name: legacy]]}
    })

    :ok =
      DB.execute(
        legacy,
        """
        CREATE TABLE work_items (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          specRefName TEXT,
          specRefSha256 TEXT,
          createdByUser TEXT,
          createdBySession TEXT,
          createdAt INTEGER NOT NULL
        );
        INSERT INTO work_items
          (id, title, createdByUser, createdAt)
        VALUES ('wi_legacy', 'Legacy', 'flynn', 1)
        """
      )

    assert :ok = WorkItems.ensure_schema(legacy)
    assert :ok = WorkItems.ensure_schema(legacy)
    assert {:ok, [[0]]} = DB.query(legacy, "SELECT isBug FROM work_items WHERE id = 'wi_legacy'")

    assert %{workItems: [%{id: "wi_legacy", isBug: false}]} =
             WorkItems.__handle__(legacy, "work-item-list", %{
               principal: {:user, "flynn"},
               params: %{}
             })
  end

  test "get and list return deterministic eras, aspects, and ordering", ctx do
    assert %{workItems: []} = list(ctx, {:user, "flynn"})
    assert %{code: "unknown_work_item"} = get(ctx, {:user, "flynn"}, "missing")

    first = create(ctx, {:user, "flynn"}, %{title: "First"})
    assert %{workItem: ^first, assignments: []} = get(ctx, {:session, "holder"}, first.id)
    second = create(ctx, {:user, "flynn"}, %{title: "Second"})
    {:ok, _} = DB.query(ctx.db, "UPDATE work_items SET createdAt = 99")

    assert %{workItems: work_items} = list(ctx, {:user, "flynn"})
    assert Enum.map(work_items, & &1.id) == Enum.sort([first.id, second.id], :desc)

    era = assign(ctx, "holder", "era", first.id)
    revoked = Assignments.__handle__(ctx.db, "revoke-assignment", revoke_call(era.id))
    assert revoked.state == "closed"
    restaffed = assign(ctx, "other-holder", "restaffed", first.id)
    aspect = assign(ctx, "holder", "aspect", first.id)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE assignments SET openedAt = 123 WHERE workItemId = ?1", [first.id])

    detail = get(ctx, {:user, "flynn"}, first.id)

    assert Enum.map(detail.assignments, & &1.id) ==
             Enum.sort([era.id, restaffed.id, aspect.id], :desc)

    assert Enum.count(detail.assignments, &(&1.state == "open")) == 2
    assert Enum.count(detail.assignments, &(&1.state == "closed")) == 1
  end

  test "work-item and assignment lifecycles are independent", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Independent"})
    assignment = assign(ctx, "holder", "work", item.id)

    # The OBSERVABLE item (title/spec/owner/state — never the internal bracket
    # wake-id columns, which a last-close does write) is untouched by closure.
    before_item = get(ctx, {:user, "flynn"}, item.id).workItem
    _ = Assignments.__handle__(ctx.db, "revoke-assignment", revoke_call(assignment.id))
    assert get(ctx, {:user, "flynn"}, item.id).workItem == before_item

    before_assignment = row(ctx.db, "SELECT * FROM assignments WHERE id = ?1", assignment.id)
    _ = update(ctx, {:user, "flynn"}, item.id, %{title: "Changed"})

    assert row(ctx.db, "SELECT * FROM assignments WHERE id = ?1", assignment.id) ==
             before_assignment
  end

  test "all four verbs emit one event and statutes can deny create", ctx do
    item = dispatch!(ctx, create_call({:user, "flynn"}, %{title: "Events"}))
    dispatch!(ctx, update_call({:user, "flynn"}, item.id, %{title: "Updated"}))
    dispatch!(ctx, get_call({:user, "flynn"}, item.id))
    dispatch!(ctx, list_call({:user, "flynn"}))

    assert {:ok, [[4]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM events WHERE kind = 'verb' AND verb LIKE 'work-item-%'"
             )

    base = Path.join(System.tmp_dir!(), "work-item-rules-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "identity/rules"))
    on_exit(fn -> File.rm_rf!(base) end)

    File.write!(Path.join(base, "identity/rules/deny.toml"), """
    [[rule]]
    name = "deny-work-item-create"
    verb = "work-item-create"
    text = "create denied"
    [[rule.deny_when]]
    fact = "caller.origin_class"
    op = "eq"
    value = "agent"
    """)

    Rules.load!(base, Map.keys(ctx.handlers), %{})

    assert {:error, %{code: "rule_denied"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               create_call({:session, "holder"}, %{title: "Denied"})
             )

    assert Map.has_key?(ctx.handlers, "work-item-update")
  end

  defp create(ctx, principal, params),
    do: WorkItems.__handle__(ctx.db, "work-item-create", create_call(principal, params))

  defp creation_context(db, work_item_id) do
    DB.query(
      db,
      "SELECT createdInTurnSeq, createdContextKnown FROM work_items WHERE id = ?1",
      [work_item_id]
    )
  end

  defp running_turn!(db, session_key, opts \\ []) do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "m_#{System.unique_integer([:positive])}",
        origin: "user:test",
        prompt: "create work",
        assignment_id: Keyword.get(opts, :assignment_id),
        job_ref: Keyword.get(opts, :job_ref)
      })

    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(db, session_key, "test-owner")
    seq
  end

  defp update(ctx, principal, id, patch),
    do: WorkItems.__handle__(ctx.db, "work-item-update", update_call(principal, id, patch))

  defp get(ctx, principal, id),
    do: WorkItems.__handle__(ctx.db, "work-item-get", get_call(principal, id))

  defp list(ctx, principal),
    do: WorkItems.__handle__(ctx.db, "work-item-list", list_call(principal))

  defp create_call(principal, params), do: call("work-item-create", principal, params)
  defp get_call(principal, id), do: call("work-item-get", principal, %{work_item_id: id})
  defp list_call(principal), do: call("work-item-list", principal, %{})

  defp update_call(principal, id, patch),
    do: call("work-item-update", principal, Map.put(patch, :work_item_id, id))

  defp call(verb, principal, params) do
    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: params
    }
  end

  defp assign(ctx, holder, subject, work_item_id) do
    assignment_call =
      call("assign", {:user, "flynn"}, %{subject: subject, work_item_id: work_item_id})
      |> Map.merge(%{session_key: holder, target_role: nil, role_fallback: false})

    Assignments.__handle__(ctx.db, "assign", assignment_call)
  end

  defp revoke_call(id), do: call("revoke-assignment", {:user, "flynn"}, %{assignment_id: id})

  defp dispatch!(ctx, call) do
    assert {:ok, result} = Dispatch.dispatch(ctx.db, ctx.handlers, call)
    result
  end

  defp row(db, sql, id) do
    assert {:ok, [row]} = DB.query(db, sql, [id])
    row
  end

  defp origin({:session, session}), do: "agent:#{session}"
  defp origin({:user, user}), do: "user:#{user}"
  defp origin({:process, process}), do: "process:#{process}"
  defp origin(nil), do: "agent:declared"

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: "fable",
      host: "eezo"
    })
  end
end
