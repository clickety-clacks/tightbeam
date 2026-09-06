defmodule Tightbeam.ToplinesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, ExecutionMap, Model, Org, Toplines, WorkItems}

  setup do
    db = :"durable_toplines_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn',0,1),('kay',0,1),('root',1,1)"
      )

    :ok = Toplines.ensure_schema(db)
    %{db: db}
  end

  test "self-contained schema creation is deterministic", %{db: db} do
    assert :ok = Toplines.ensure_schema(db)

    assert {:ok,
            [
              ["topline_concern_refs"],
              ["topline_concerns"],
              ["topline_events"],
              ["topline_idempotency"],
              ["topline_placement_obligations"],
              ["topline_schema_stamp"],
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
    assert ended.untaggedConcernIds == []
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

  test "AC10 concurrent active-pair links commit once and append one event", ctx do
    work_item!(ctx.db, "wi_race", "flynn")

    topline =
      Toplines.create(
        ctx.db,
        call({:user, "flynn"}, %{title: "Race", idempotency_key: "race-create"}, 10)
      ).topline

    calls =
      for key <- ["race-link-a", "race-link-b"] do
        call(
          {:user, "flynn"},
          %{
            topline_id: topline.id,
            work_item_id: "wi_race",
            reason: "same pair",
            idempotency_key: key
          },
          11
        )
      end

    results = race(calls, &Toplines.link_work(ctx.db, &1))

    assert 1 == Enum.count(results, &match?(%{membership: %{}}, &1))
    assert 1 == Enum.count(results, &match?(%{code: "membership_exists"}, &1))

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM topline_work_memberships WHERE unlinkedAt IS NULL"
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM topline_events WHERE toplineId=?1 AND kind='work_linked'",
               [topline.id]
             )
  end

  test "AC59 concurrent Concern tags commit once and append one event", ctx do
    work_item!(ctx.db, "wi_reference_race", "flynn")

    topline =
      Toplines.create(
        ctx.db,
        call({:user, "flynn"}, %{title: "Reference race", idempotency_key: "race-create"}, 20)
      ).topline

    Toplines.link_work(
      ctx.db,
      call(
        {:user, "flynn"},
        %{
          topline_id: topline.id,
          work_item_id: "wi_reference_race",
          reason: "member",
          idempotency_key: "race-member"
        },
        21
      )
    )

    concern =
      Toplines.create_concern(
        ctx.db,
        call(
          {:user, "flynn"},
          %{topline_id: topline.id, title: "Risk", idempotency_key: "race-concern"},
          22
        )
      ).concern

    calls =
      for key <- ["race-reference-a", "race-reference-b"] do
        call(
          {:user, "flynn"},
          %{
            concern_id: concern.id,
            work_item_id: "wi_reference_race",
            reason: "same reference",
            idempotency_key: key
          },
          23
        )
      end

    results = race(calls, &Toplines.link_concern_work(ctx.db, &1))

    assert 1 == Enum.count(results, &match?(%{concernTag: %{}}, &1))
    assert 1 == Enum.count(results, &match?(%{code: "concern_tag_exists"}, &1))

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM topline_concern_refs"
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM topline_events WHERE toplineId=?1 AND kind='concern_work_tagged'",
               [topline.id]
             )
  end

  test "lifecycle mutations preserve canonical titles, exact transitions, and event order", ctx do
    created =
      Toplines.create(
        ctx.db,
        call({:user, "flynn"}, %{title: " Cafe\u0301 ", idempotency_key: "create"}, 10)
      )

    id = created.topline.id

    assert %{code: "no_change", message: "no change"} =
             Toplines.update(
               ctx.db,
               call(
                 {:user, "flynn"},
                 %{
                   topline_id: id,
                   title: "\u00a0Café\u3000",
                   reason: "same",
                   idempotency_key: "same"
                 },
                 11
               )
             )

    updated =
      Toplines.update(
        ctx.db,
        call(
          {:user, "flynn"},
          %{topline_id: id, title: "Ship", reason: "rename", idempotency_key: "rename"},
          12
        )
      )

    assert updated.topline.title == "Ship"
    assert updated.topline.updatedAt == 12

    closed =
      Toplines.close(
        ctx.db,
        call({:user, "flynn"}, %{topline_id: id, reason: "done", idempotency_key: "close"}, 13)
      )

    assert closed.topline.state == "closed"
    assert closed.topline.closedAt == 13

    assert %{code: "no_change"} =
             Toplines.update(
               ctx.db,
               call(
                 {:user, "flynn"},
                 %{topline_id: id, title: "Ship", reason: "same", idempotency_key: "closed-same"},
                 14
               )
             )

    assert %{code: "topline_closed"} =
             Toplines.update(
               ctx.db,
               call(
                 {:user, "flynn"},
                 %{
                   topline_id: id,
                   title: "Other",
                   reason: "different",
                   idempotency_key: "closed-different"
                 },
                 15
               )
             )

    reopened =
      Toplines.reopen(
        ctx.db,
        call({:user, "flynn"}, %{topline_id: id, reason: "again", idempotency_key: "reopen"}, 16)
      )

    assert reopened.topline.state == "open"
    assert reopened.topline.closedAt == nil

    assert %{code: "invalid_transition", message: "invalid state transition"} =
             Toplines.reopen(
               ctx.db,
               call(
                 {:user, "flynn"},
                 %{topline_id: id, reason: "again", idempotency_key: "reopen-twice"},
                 17
               )
             )

    assert %{topline: %{history: history}} =
             Toplines.get(ctx.db, read_call({:user, "flynn"}, %{topline_id: id, history: true}))

    assert Enum.map(history, &{&1.seq, &1.kind}) == [
             {1, "topline_created"},
             {2, "topline_renamed"},
             {3, "topline_closed"},
             {4, "topline_reopened"}
           ]

    assert Enum.at(history, 1).detail == %{fromTitle: "Café", toTitle: "Ship"}
  end

  test "Concern definitions are immutable tags and membership unlink cleans current tags", ctx do
    work_item!(ctx.db, "wi_concern", "flynn")
    session!(ctx.db, "s_flynn", "flynn")

    topline =
      Toplines.create(
        ctx.db,
        call({:user, "flynn"}, %{title: "Intent", idempotency_key: "create"}, 20)
      ).topline

    membership =
      Toplines.link_work(
        ctx.db,
        call(
          {:user, "flynn"},
          %{
            topline_id: topline.id,
            work_item_id: "wi_concern",
            reason: "member",
            idempotency_key: "link"
          },
          21
        )
      ).membership

    concerns =
      for {title, key} <- [{" Risk ", "risk"}, {"Privacy", "privacy"}] do
        Toplines.create_concern(
          ctx.db,
          call(
            {:session, "s_flynn"},
            %{topline_id: topline.id, title: title, idempotency_key: key},
            22
          )
        ).concern
      end

    for {concern, key} <- Enum.zip(concerns, ["tag-risk", "tag-privacy"]) do
      request =
        call(
          {:user, "flynn"},
          %{
            concern_id: concern.id,
            work_item_id: "wi_concern",
            reason: "addresses",
            idempotency_key: key
          },
          23
        )

      response = Toplines.link_concern_work(ctx.db, request)
      assert response == Toplines.link_concern_work(ctx.db, %{request | now: 99})
      assert response.concernTag.workItemId == "wi_concern"
    end

    assert %{topline: %{concerns: projected, history: history}} =
             Toplines.get(
               ctx.db,
               read_call({:user, "flynn"}, %{topline_id: topline.id, history: true})
             )

    assert Map.new(projected, &{&1.title, &1.workItemIds}) == %{
             "Privacy" => ["wi_concern"],
             "Risk" => ["wi_concern"]
           }

    assert Enum.take(Enum.map(history, & &1.kind), -2) ==
             ["concern_work_tagged", "concern_work_tagged"]

    work_item!(ctx.db, "wi_unlinked", "flynn")

    assert %{code: "topline_mismatch"} =
             Toplines.link_concern_work(
               ctx.db,
               call(
                 {:user, "flynn"},
                 %{
                   concern_id: hd(concerns).id,
                   work_item_id: "wi_unlinked",
                   reason: "not a member",
                   idempotency_key: "mismatch"
                 },
                 24
               )
             )

    assert %{code: "not_found"} =
             Toplines.create_concern(
               ctx.db,
               call(
                 {:user, "kay"},
                 %{topline_id: topline.id, title: "Invisible", idempotency_key: "foreign"},
                 24
               )
             )

    Toplines.close(
      ctx.db,
      call(
        {:user, "flynn"},
        %{topline_id: topline.id, reason: "pause", idempotency_key: "close"},
        25
      )
    )

    untag_request =
      call(
        {:user, "flynn"},
        %{
          concern_id: hd(concerns).id,
          work_item_id: "wi_concern",
          reason: "narrow focus",
          idempotency_key: "untag"
        },
        26
      )

    assert %{concernId: concern_id, workItemId: "wi_concern"} =
             Toplines.unlink_concern_work(ctx.db, untag_request)

    assert concern_id == hd(concerns).id

    assert Toplines.unlink_concern_work(ctx.db, untag_request) ==
             %{concernId: concern_id, workItemId: "wi_concern"}

    assert %{code: "topline_closed"} =
             Toplines.link_concern_work(
               ctx.db,
               call(
                 {:user, "flynn"},
                 %{
                   concern_id: hd(concerns).id,
                   work_item_id: "wi_concern",
                   reason: "reapply",
                   idempotency_key: "closed-tag"
                 },
                 26
               )
             )

    ended =
      Toplines.unlink_work(
        ctx.db,
        call(
          {:user, "flynn"},
          %{membership_id: membership.id, reason: "split", idempotency_key: "unlink"},
          27
        )
      )

    assert ended.untaggedConcernIds == [List.last(concerns).id]
    assert ended.openedPlacement == nil

    assert %{topline: %{concerns: cleaned, history: cleaned_history}} =
             Toplines.get(
               ctx.db,
               read_call({:user, "flynn"}, %{topline_id: topline.id, history: true})
             )

    assert Enum.all?(cleaned, &(&1.workItemIds == []))
    assert List.last(cleaned_history).kind == "work_unlinked"
  end

  test "public query applies visibility and state before the closed projection", ctx do
    open =
      Toplines.create(
        ctx.db,
        call({:user, "flynn"}, %{title: "Open", idempotency_key: "open"}, 30)
      ).topline

    closed =
      Toplines.create(
        ctx.db,
        call({:user, "flynn"}, %{title: "Closed", idempotency_key: "closed"}, 31)
      ).topline

    Toplines.close(
      ctx.db,
      call(
        {:user, "flynn"},
        %{topline_id: closed.id, reason: "done", idempotency_key: "close"},
        32
      )
    )

    assert [] = Toplines.query_public(ctx.db, %{principal: {:user, "kay"}, state: nil})

    assert [%{topline: %{id: id}} = queried] =
             Toplines.query_public(ctx.db, %{principal: {:user, "flynn"}, state: ["open"]})

    assert id == open.id
    item = Toplines.public_item(queried)

    assert Map.keys(item) |> MapSet.new() ==
             MapSet.new(~w(
               id ownerUserId title state createdActor createdAt updatedAt closedAt
               activeWorkCount openConcernCount workMemberships concerns dependencyVersion
             )a)

    assert item.workMemberships == []
    assert item.concerns == []
    assert item.dependencyVersion =~ ~r/^[0-9a-f]{64}$/

    assert Enum.map(
             Toplines.query_public(ctx.db, %{
               principal: {:user, "root"},
               state: ["closed", "open"]
             }),
             & &1.topline.id
           ) == [open.id, closed.id]
  end

  test "public dependency digest uses the exact ordered integer Work Item rowVersion vector",
       ctx do
    work_item!(ctx.db, "wi_dependency", "flynn")

    topline =
      Toplines.create(
        ctx.db,
        call({:user, "flynn"}, %{title: "Dependency", idempotency_key: "dependency-create"}, 40)
      ).topline

    membership =
      Toplines.link_work(
        ctx.db,
        call(
          {:user, "flynn"},
          %{
            topline_id: topline.id,
            work_item_id: "wi_dependency",
            reason: "dependency",
            idempotency_key: "dependency-link"
          },
          41
        )
      ).membership

    expected_vector =
      [
        ["toplines", topline.id, 2],
        ["topline work memberships", membership.id, 2],
        ["work items", "wi_dependency", 1]
      ]
      |> Enum.sort()

    expected_digest =
      expected_vector
      |> JSON.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert [%{topline: queried} = composed] =
             Toplines.query_public(ctx.db, %{principal: {:user, "flynn"}, state: ["open"]})

    assert queried.id == topline.id
    assert Toplines.public_item(composed).dependencyVersion == expected_digest
  end

  test "Work Item mutation advances its rowVersion and the composed dependency digest", ctx do
    work_item!(ctx.db, "wi_mutation", "flynn")

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE work_item_versions SET rowVersion = 9000000000000000 WHERE workItemId = 'wi_mutation'"
      )

    topline =
      Toplines.create(
        ctx.db,
        call({:user, "flynn"}, %{title: "Mutation", idempotency_key: "mutation-create"}, 42)
      ).topline

    Toplines.link_work(
      ctx.db,
      call(
        {:user, "flynn"},
        %{
          topline_id: topline.id,
          work_item_id: "wi_mutation",
          reason: "mutation",
          idempotency_key: "mutation-link"
        },
        43
      )
    )

    [before] = Toplines.query_public(ctx.db, %{principal: {:user, "flynn"}, state: ["open"]})
    before_item = Toplines.public_item(before)
    assert [%{workItemTitle: "Work wi_mutation"}] = before_item.workMemberships

    updated =
      WorkItems.__handle__(
        ctx.db,
        "work-item-update",
        call({:user, "flynn"}, %{work_item_id: "wi_mutation", title: "After"}, 44)
      )

    assert updated.rowVersion == 9_000_000_000_000_001

    [after_update] =
      Toplines.query_public(ctx.db, %{principal: {:user, "flynn"}, state: ["open"]})

    after_item = Toplines.public_item(after_update)
    assert [%{workItemTitle: "After"}] = after_item.workMemberships
    refute after_item.dependencyVersion == before_item.dependencyVersion

    unchanged =
      WorkItems.__handle__(
        ctx.db,
        "work-item-update",
        call({:user, "flynn"}, %{work_item_id: "wi_mutation", title: "After"}, 45)
      )

    assert unchanged.rowVersion == updated.rowVersion

    [after_noop] =
      Toplines.query_public(ctx.db, %{principal: {:user, "flynn"}, state: ["open"]})

    assert Toplines.public_item(after_noop).dependencyVersion == after_item.dependencyVersion
  end

  test "the frozen in-transaction placement seam stores one pending episode and resolution",
       ctx do
    work_item!(ctx.db, "wi_place", "flynn")

    :ok =
      DB.execute(
        ctx.db,
        """
        INSERT INTO wakes
          (wakeId, sessionKey, origin, prompt, consumer, dueAt, state, createdAt)
        VALUES ('w_place', 'agent:main:clawline:flynn:main', 'process:tightbeam',
                'Choose placement', 'prompt', 40, 'pending', 40)
        """
      )

    {:ok, opened} =
      DB.transaction(ctx.db, fn txn ->
        Toplines.open_placement_in_txn(txn, %{
          id: "tlp_one",
          work_item_id: "wi_place",
          owner_user_id: "flynn",
          cause: "created",
          cause_ref: "wi_place",
          source_causal_event_seq: nil,
          actor_kind: "user",
          actor_ref: "flynn",
          at: 40,
          prompt_wake_id: "w_place"
        })
      end)

    assert opened == %{
             cause: "created",
             causeRef: "wi_place",
             dueAt: 40,
             id: "tlp_one",
             openedActor: %{kind: "user", ref: "flynn"},
             openedAt: 40,
             ownerUserId: "flynn",
             promptWake: %{id: "w_place", state: "pending"},
             resolutionActor: nil,
             resolutionReason: nil,
             resolvedAt: nil,
             state: "pending",
             workItemId: "wi_place",
             workItemTitle: "Work wi_place"
           }

    {:ok, resolved} =
      DB.transaction(ctx.db, fn txn ->
        Toplines.resolve_placement_in_txn(txn, %{
          work_item_id: "wi_place",
          state: "left_unlinked",
          actor_kind: "user",
          actor_ref: "flynn",
          reason: "deliberate",
          at: 41,
          resolution_causal_event_seq: nil
        })
      end)

    assert resolved.state == "left_unlinked"
    assert resolved.resolutionActor == %{kind: "user", ref: "flynn"}
    assert resolved.resolutionReason == "deliberate"
    assert resolved.resolvedAt == 41

    assert {:ok, nil} =
             DB.transaction(ctx.db, fn txn ->
               Toplines.resolve_placement_in_txn(txn, %{
                 work_item_id: "wi_place",
                 state: "left_unlinked",
                 actor_kind: "user",
                 actor_ref: "flynn",
                 reason: "again",
                 at: 42,
                 resolution_causal_event_seq: nil
               })
             end)
  end

  test "leave-unlinked resolves the caller's pending placement idempotently and lists resolved placements",
       ctx do
    work_item!(ctx.db, "wi_leave", "flynn")

    :ok =
      DB.execute(
        ctx.db,
        """
        INSERT INTO wakes
          (wakeId, sessionKey, origin, prompt, consumer, dueAt, state, createdAt)
        VALUES ('w_leave', 'agent:main:clawline:flynn:main', 'process:tightbeam',
                'Choose placement', 'prompt', 40, 'pending', 40)
        """
      )

    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        Toplines.open_placement_in_txn(txn, %{
          id: "tlp_leave",
          work_item_id: "wi_leave",
          owner_user_id: "flynn",
          cause: "created",
          cause_ref: "wi_leave",
          source_causal_event_seq: nil,
          actor_kind: "user",
          actor_ref: "flynn",
          at: 40,
          prompt_wake_id: "w_leave"
        })
      end)

    request = %{work_item_id: "wi_leave", reason: "not now", idempotency_key: "leave-1"}

    assert %{placement: %{id: "tlp_leave", state: "left_unlinked", resolutionReason: "not now"}} =
             Toplines.leave_unlinked(ctx.db, call({:user, "flynn"}, request, 41))

    assert %{placement: %{id: "tlp_leave", state: "left_unlinked"}} =
             Toplines.leave_unlinked(ctx.db, call({:user, "flynn"}, request, 42))

    assert %{code: "placement_not_pending"} =
             Toplines.leave_unlinked(
               ctx.db,
               call({:user, "flynn"}, %{request | idempotency_key: "leave-2"}, 43)
             )

    assert %{placements: []} = Toplines.list_placements(ctx.db, read_call({:user, "flynn"}))

    assert %{placements: [%{id: "tlp_leave", state: "left_unlinked"}]} =
             Toplines.list_placements(
               ctx.db,
               read_call({:user, "flynn"}, %{state: "resolved"})
             )

    assert %{placements: []} =
             Toplines.list_placements(ctx.db, read_call({:user, "kay"}, %{state: "all"}))

    assert %{code: "process_denied"} =
             Toplines.leave_unlinked(
               ctx.db,
               call({:process, "tightbeam"}, %{work_item_id: "wi_leave"}, 44)
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

  defp race(inputs, operation) do
    parent = self()

    tasks =
      Enum.map(inputs, fn input ->
        Task.async(fn ->
          send(parent, {:race_ready, self()})
          receive do: (:race_go -> operation.(input))
        end)
      end)

    Enum.each(tasks, fn task ->
      pid = task.pid
      assert_receive {:race_ready, ^pid}, 1_000
    end)

    Enum.each(tasks, &send(&1.pid, :race_go))
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

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

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_item_versions (workItemId, rowVersion) VALUES (?1, 1)",
        [id]
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
