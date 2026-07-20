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
    Org,
    Roles,
    Rules,
    WorkItems
  }

  @sha String.duplicate("a", 64)
  @sha2 String.duplicate("b", 64)

  setup do
    db = :work_items_db
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [Devices, Idempotency, Org, Roles, WorkItems, Assignments, EventLog] do
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
    Rules.load!(System.tmp_dir!(), Map.keys(handlers))
    %{db: db, holder: holder, other: other, handlers: handlers}
  end

  test "schema pins typed creator, paired spec ref, and has no state column", %{db: db} do
    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")

    base =
      "INSERT INTO work_items (id, title, specRefName, specRefSha256, createdByUser, createdBySession, createdAt) VALUES "

    for values <- [
          "('wi_none','x',NULL,NULL,NULL,NULL,1)",
          "('wi_both','x',NULL,NULL,'flynn','holder',1)",
          "('wi_name','x','spec',NULL,'flynn',NULL,1)",
          "('wi_sha','x',NULL,'#{@sha}','flynn',NULL,1)",
          "('wi_blank','   ',NULL,NULL,'flynn',NULL,1)",
          "('wi_upper','x','spec','#{String.upcase(@sha)}','flynn',NULL,1)"
        ] do
      assert {:error, %DB.Error{message: message}} = DB.query(db, base <> values)
      assert message =~ "CHECK constraint"
    end

    assert {:ok, columns} = DB.query(db, "PRAGMA table_info(work_items)")

    assert Enum.map(columns, fn [_cid, name | _] -> name end) == [
             "id",
             "title",
             "specRefName",
             "specRefSha256",
             "createdByUser",
             "createdBySession",
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

    session =
      create(ctx, {:session, "holder"}, %{
        title: "Session item",
        spec_ref_name: "spec.md",
        spec_ref_sha256: @sha
      })

    assert session.createdBySession == "holder"
    assert session.createdByUser == nil
    assert session.specRefName == "spec.md"
    assert session.specRefSha256 == @sha
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

    before_item = row(ctx.db, "SELECT * FROM work_items WHERE id = ?1", item.id)
    _ = Assignments.__handle__(ctx.db, "revoke-assignment", revoke_call(assignment.id))
    assert row(ctx.db, "SELECT * FROM work_items WHERE id = ?1", item.id) == before_item

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

    Rules.load!(base, Map.keys(ctx.handlers))

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
