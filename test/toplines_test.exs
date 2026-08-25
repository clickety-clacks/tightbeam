defmodule Tightbeam.ToplinesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, ExecutionMap, Model, Org, Toplines}

  setup do
    db = :"durable_toplines_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('flynn', 0, 'admin_add', 1),('kay', 0, 'admin_add', 1),('root', 1, 'admin_add', 1)"
      )

    Enum.each(~w(flynn kay root), &ensure_main_session(db, &1))

    :ok = Toplines.ensure_schema(db)
    %{db: db}
  end

  test "self-contained schema creation is deterministic", %{db: db} do
    assert :ok = Toplines.ensure_schema(db)

    assert {:ok,
            [
              ["topline_events"],
              ["topline_idempotency"],
              ["topline_work_memberships"],
              ["toplines"]
            ]} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'topline%' ORDER BY name"
             )

    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
  end

  test "create canonicalizes the title, attributes the actor, and reads by owner visibility",
       ctx do
    session!(ctx.db, "s_flynn", "flynn")

    created =
      Toplines.create(
        ctx.db,
        call(
          {:user, "flynn"},
          %{title: "\u3000Cafe\u0301\u00A0", idempotency_key: "create-1"},
          10
        )
      )

    assert %{
             topline: %{
               id: "tl_" <> _,
               ownerUserId: "flynn",
               title: "Café",
               state: "open",
               createdActor: %{kind: "user", ref: "flynn"},
               createdAt: created_at,
               updatedAt: created_at,
               closedAt: nil,
               activeWorkCount: 0,
               openConcernCount: 0
             }
           } = created

    assert is_integer(created_at)

    id = created.topline.id
    assert %{toplines: [%{id: ^id}]} = Toplines.list(ctx.db, read_call({:user, "flynn"}))
    assert %{toplines: []} = Toplines.list(ctx.db, read_call({:user, "kay"}))
    assert %{toplines: [%{id: ^id}]} = Toplines.list(ctx.db, read_call({:user, "root"}))

    assert %{topline: %{id: ^id, workMemberships: [], concerns: []}} =
             Toplines.get(ctx.db, read_call({:session, "s_flynn"}, %{topline_id: id}))

    assert Toplines.get(ctx.db, read_call({:user, "kay"}, %{topline_id: id})) ==
             Toplines.get(ctx.db, read_call({:user, "kay"}, %{topline_id: "tl_missing"}))

    assert %{code: "process_denied"} =
             Toplines.list(ctx.db, read_call({:process, "tightbeam"}))

    session_created =
      Toplines.create(
        ctx.db,
        call({:session, "s_flynn"}, %{title: "Session intent", idempotency_key: "create-2"}, 11)
      )

    assert session_created.topline.createdActor == %{kind: "session", ref: "s_flynn"}
  end

  test "membership episodes retain reasons, attribution, history, and keyed replay", ctx do
    work_item!(ctx.db, "wi_release", "flynn")

    create_call = call({:user, "flynn"}, %{title: "Release", idempotency_key: "create"}, 100)
    first_create = Toplines.create(ctx.db, create_call)
    assert first_create == Toplines.create(ctx.db, create_call)
    topline_id = first_create.topline.id

    assert %{code: "idempotency_conflict"} =
             Toplines.create(
               ctx.db,
               call({:user, "flynn"}, %{title: "Other", idempotency_key: "create"}, 101)
             )

    link_call =
      call(
        {:user, "flynn"},
        %{
          topline_id: topline_id,
          work_item_id: "wi_release",
          reason: "  groups the Cafe\u0301 release  ",
          idempotency_key: "link"
        },
        110
      )

    linked = Toplines.link_work(ctx.db, link_call)
    assert linked == Toplines.link_work(ctx.db, link_call)

    assert linked ==
             Toplines.link_work(
               ctx.db,
               put_in(link_call, [:params, :reason], "  groups the Café release  ")
             )

    assert linked.resolvedPlacementId == nil
    assert linked.membership.linkReason == "  groups the Cafe\u0301 release  "
    assert linked.membership.linkedActor == %{kind: "user", ref: "flynn"}
    assert is_integer(linked.membership.linkedAt)
    membership_id = linked.membership.id

    assert %{code: "membership_exists"} =
             Toplines.link_work(
               ctx.db,
               put_in(link_call, [:params, :idempotency_key], "other-link")
             )

    unlink_call =
      call(
        {:user, "flynn"},
        %{membership_id: membership_id, reason: "work split", idempotency_key: "unlink"},
        120
      )

    ended = Toplines.unlink_work(ctx.db, unlink_call)
    assert ended == Toplines.unlink_work(ctx.db, unlink_call)
    assert ended.endedConcernReferenceIds == []
    assert ended.openedPlacement == nil
    assert ended.membership.unlinkReason == "work split"
    assert ended.membership.unlinkedActor == %{kind: "user", ref: "flynn"}
    assert is_integer(ended.membership.unlinkedAt)
    assert ended.membership.unlinkedAt >= linked.membership.linkedAt

    assert %{code: "membership_ended"} =
             Toplines.unlink_work(
               ctx.db,
               put_in(unlink_call, [:params, :idempotency_key], "other-unlink")
             )

    assert %{topline: %{workMemberships: [], history: history, updatedAt: updated_at}} =
             Toplines.get(
               ctx.db,
               read_call({:user, "flynn"}, %{topline_id: topline_id, history: true})
             )

    assert updated_at == ended.membership.unlinkedAt

    assert Enum.map(history, &{&1.seq, &1.kind}) == [
             {1, "topline_created"},
             {2, "work_linked"},
             {3, "work_unlinked"}
           ]

    assert Enum.at(history, 1).detail == %{
             linkReason: "  groups the Cafe\u0301 release  ",
             workItemId: "wi_release"
           }

    assert {:ok, [[canonical_response]]} =
             DB.query(
               ctx.db,
               "SELECT canonicalResponse FROM topline_idempotency WHERE operation = 'topline-link-work'"
             )

    assert canonical_response =~ "Cafe\u0301"

    relinked =
      Toplines.link_work(
        ctx.db,
        put_in(link_call, [:params, :idempotency_key], "relink") |> put_in([:now], 130)
      )

    assert relinked.membership.id != membership_id

    assert %{code: "membership_ended"} =
             Toplines.unlink_work(
               ctx.db,
               unlink_call
               |> put_in([:params, :idempotency_key], "stale-unlink")
               |> put_in([:now], 140)
             )

    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM topline_work_memberships")

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM topline_work_memberships WHERE unlinkedAt IS NULL"
             )
  end

  test "invalid, invisible, cross-owner, duplicate, and process operations refuse without writes",
       ctx do
    work_item!(ctx.db, "wi_mine", "flynn")
    work_item!(ctx.db, "wi_theirs", "kay")

    assert %{code: "invalid_message"} =
             Toplines.create(ctx.db, call({:user, "flynn"}, %{title: " ", idempotency_key: "k"}))

    assert %{code: "invalid_message"} =
             Toplines.create(
               ctx.db,
               call({:user, "flynn"}, %{title: "Valid", idempotency_key: " ", extra: true})
             )

    assert %{code: "process_denied"} =
             Toplines.create(
               ctx.db,
               call({:process, "tightbeam"}, %{title: "Valid", idempotency_key: "k"})
             )

    assert %{code: "process_denied"} =
             Toplines.create(ctx.db, call({:process, "tightbeam"}, %{unexpected: true}))

    topline =
      Toplines.create(
        ctx.db,
        call({:user, "flynn"}, %{title: "Mine", idempotency_key: "mine"})
      ).topline

    invisible = %{
      topline_id: topline.id,
      work_item_id: "wi_theirs",
      reason: "foreign",
      idempotency_key: "foreign"
    }

    assert %{code: "not_found"} =
             Toplines.link_work(ctx.db, call({:user, "flynn"}, invisible))

    assert %{code: "owner_mismatch"} =
             Toplines.link_work(ctx.db, call({:user, "root"}, invisible))

    assert %{code: "invalid_message"} =
             Toplines.link_work(
               ctx.db,
               call({:user, "flynn"}, %{invisible | work_item_id: "wi_mine", reason: ""})
             )

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM toplines")
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM topline_work_memberships")
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM topline_events")
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM topline_idempotency")
  end

  test "a late transaction failure rolls back state, event, and idempotency rows", ctx do
    :ok =
      DB.execute(
        ctx.db,
        """
        CREATE TRIGGER refuse_topline_receipt
        BEFORE INSERT ON topline_idempotency
        BEGIN
          SELECT RAISE(ABORT, 'receipt refused');
        END;
        """
      )

    assert_raise DB.Error, fn ->
      Toplines.create(
        ctx.db,
        call({:user, "flynn"}, %{title: "Rolled back", idempotency_key: "rollback"}, 50)
      )
    end

    for table <- ~w(toplines topline_work_memberships topline_events topline_idempotency) do
      assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM #{table}")
    end
  end

  test "compatibility delegates preserve Execution Map response bytes", ctx do
    work_item!(ctx.db, "wi_map", "flynn")

    roster_call = read_call({:user, "flynn"}) |> Map.put(:now, 9_000_000)
    detail_call = read_call({:user, "flynn"}, %{under: "wi_map"}) |> Map.put(:now, 9_000_000)

    assert JSON.encode!(Toplines.roster(ctx.db, roster_call)) ==
             JSON.encode!(ExecutionMap.roster(ctx.db, roster_call))

    assert JSON.encode!(Toplines.topline(ctx.db, detail_call)) ==
             JSON.encode!(ExecutionMap.topline(ctx.db, detail_call))
  end

  defp call(principal, params, now \\ 1) do
    %{
      verb: "test",
      principal: principal,
      origin: "test",
      session_key: nil,
      params: params,
      now: now
    }
  end

  defp read_call(principal, params \\ %{}), do: call(principal, params)

  defp work_item!(db, id, owner) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO work_items
          (id, title, ownerUserId, state, createdByUser, createdContextKnown, createdAt)
        VALUES (?1, ?2, ?3, 'open', ?3, 1, 1)
        """,
        [id, "Work #{id}", owner]
      )

    id
  end

  defp session!(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })

    key
  end
end
