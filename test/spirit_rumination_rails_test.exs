defmodule Tightbeam.SpiritRuminationRailsTest do
  @moduledoc """
  Spirit rumination as a prod, never a gate (2026-09-17).

  A work item gaining or changing its spec summons the product's PO to judge it
  against the product's intent; a PO changes-requested on spec-backed work reaches
  the session that owns the work. Nothing is refused anywhere on this path.
  """
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Archetypes,
    DB,
    Dispatch,
    EventLog,
    Gateway,
    Identity,
    ProductOwner,
    Roles,
    Rules,
    Wakes,
    WorkItems
  }

  @spec_a String.duplicate("a", 64)
  @spec_b String.duplicate("b", 64)

  setup do
    db = :"spirit_rumination_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    register_hosts(db, %{
      "eezo" => %{
        ssh: nil,
        base_dir: Application.fetch_env!(:tightbeam, :base_dir),
        cli_bin: nil
      }
    })

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    # The shape the layered-delivery guidance produces: an executive root, a
    # product delivery orchestrator with one PO alongside it, a lane owner under
    # the PDO, and a coder under the lane owner.
    root = session(db, "main-root", "orchestrator", nil)
    pdo = session(db, "pdo", "orchestrator", root.session_key)
    po = session(db, "po", "product-owner", pdo.session_key)
    lane = session(db, "lane-owner", "orchestrator", pdo.session_key)
    coder = session(db, "impl-coder", "coder", lane.session_key)
    orphan = session(db, "orphan-coder", "coder", nil)

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-spirit-rumination-#{System.unique_integer([:positive])}"
      )

    assert :initialized = Archetypes.init_identity!(base_dir)
    assert {:ok, _revision} = Identity.learn!(base_dir, "agentic-engineering", "flynn")
    _archetypes = Archetypes.load!(base_dir)

    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
    rules = Rules.load!(base_dir, Map.keys(handlers))
    :ok = Wakes.activate_wait_recognition(db)

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Rules)
      :persistent_term.erase(Archetypes)
    end)

    %{
      db: db,
      handlers: handlers,
      rules: rules,
      base_dir: base_dir,
      root: root,
      pdo: pdo,
      po: po,
      lane: lane,
      coder: coder,
      orphan: orphan
    }
  end

  test "the shipped bundle carries the prod rules and not the old gate", ctx do
    names = Enum.map(ctx.rules, & &1.name)
    assert "spec-pinned-summons-spirit" in names
    assert "spec-repinned-summons-spirit" in names
    assert "spirit-objection-reaches-owner" in names
    refute "spec-dispatch-requires-spirit" in names

    for rule <- ctx.rules, rule.name =~ "spirit" do
      assert rule.effect == "notice", "#{rule.name} must never gate"
    end
  end

  describe "the product owner lookup" do
    test "walks lineage to the PO alongside the product delivery orchestrator", ctx do
      assert ProductOwner.resolve(ctx.db, ctx.coder.session_key) == ctx.po.session_key
      assert ProductOwner.resolve(ctx.db, ctx.lane.session_key) == ctx.po.session_key
      assert ProductOwner.resolve(ctx.db, ctx.pdo.session_key) == ctx.po.session_key
      assert ProductOwner.resolve(ctx.db, ctx.po.session_key) == ctx.po.session_key
    end

    test "answers nil rather than guess when nothing or several resolve", ctx do
      assert ProductOwner.resolve(ctx.db, ctx.orphan.session_key) == nil
      assert ProductOwner.resolve(ctx.db, nil) == nil

      other_pdo = session(ctx.db, "other-pdo", "orchestrator", ctx.root.session_key)
      first = session(ctx.db, "po-one", "product-owner", other_pdo.session_key)
      _second = session(ctx.db, "po-two", "product-owner", other_pdo.session_key)
      worker = session(ctx.db, "other-coder", "coder", other_pdo.session_key)

      assert ProductOwner.resolve(ctx.db, worker.session_key) == nil

      Roles.create!(ctx.db, "product-owner:other", "flynn", first.session_key)
      assert ProductOwner.resolve(ctx.db, worker.session_key) == first.session_key
    end
  end

  describe "a spec summons the product owner" do
    test "creating a spec-backed item wakes the PO and blocks nothing", ctx do
      item = create_item(ctx, {:session, ctx.lane.session_key}, @spec_a)

      assert [wake] = po_wakes(ctx, "remedy:spec-pinned-summons-spirit")
      assert wake.session_key == ctx.po.session_key
      assert wake.prompt =~ item.id
      assert wake.prompt =~ ctx.lane.session_key
      assert wake.prompt =~ "Nothing is waiting on you"

      assert %{detail: detail} =
               ctx.db
               |> EventLog.lifecycle_events()
               |> Enum.find(&(&1.kind == "rule_notice" and &1.subject == wake.wake_id))

      assert detail =~ ~s("rule":"spec-pinned-summons-spirit")
    end

    test "an item without a spec is silent until a spec is pinned, then again on change",
         ctx do
      item = create_item(ctx, {:session, ctx.lane.session_key}, nil)
      assert po_wakes(ctx, "remedy:spec-pinned-summons-spirit") == []
      assert po_wakes(ctx, "remedy:spec-repinned-summons-spirit") == []

      assert %{} = update_item(ctx, {:session, ctx.lane.session_key}, item.id, @spec_a)
      assert [first] = po_wakes(ctx, "remedy:spec-repinned-summons-spirit")
      assert first.prompt =~ item.id

      # Same pin again: no change, no summons.
      assert %{} = update_item(ctx, {:session, ctx.lane.session_key}, item.id, @spec_a)
      assert [_] = po_wakes(ctx, "remedy:spec-repinned-summons-spirit")

      # A new spec is a new question, whatever was judged before.
      approve(ctx, item.id)
      assert %{} = update_item(ctx, {:session, ctx.lane.session_key}, item.id, @spec_b)
      assert [_, second] = po_wakes(ctx, "remedy:spec-repinned-summons-spirit")
      assert second.prompt =~ "Any earlier judgment was of the old spec"
    end

    test "a newer pin coalesces into an unhandled request so the PO holds one", ctx do
      item = create_item(ctx, {:session, ctx.lane.session_key}, @spec_a)
      assert [first] = po_wakes(ctx, "remedy:spec-pinned-summons-spirit")

      assert %{} = update_item(ctx, {:session, ctx.lane.session_key}, item.id, @spec_b)
      assert [second] = po_wakes(ctx, "remedy:spec-repinned-summons-spirit")

      # The create rule's request is another rule's and stays. A second update
      # while the first update's request is unread adds nothing to the queue.
      assert %{} =
               update_item(
                 ctx,
                 {:session, ctx.lane.session_key},
                 item.id,
                 String.duplicate("c", 64)
               )

      assert [still] = po_wakes(ctx, "remedy:spec-repinned-summons-spirit")
      assert still.wake_id == second.wake_id
      assert [^first] = po_wakes(ctx, "remedy:spec-pinned-summons-spirit")

      assert %{detail: detail} =
               ctx.db
               |> EventLog.lifecycle_events()
               |> Enum.find(&(&1.kind == "rule_notice_coalesced" and &1.subject == second.wake_id))

      assert detail =~ item.id
      assert detail =~ String.duplicate("c", 64)
    end

    test "closing a spec-backed item does not summon anyone", ctx do
      item = create_item(ctx, {:session, ctx.lane.session_key}, @spec_a)
      assert [_] = po_wakes(ctx, "remedy:spec-pinned-summons-spirit")

      assert %{ok: true} =
               WorkItems.__handle__(ctx.db, "work-item-close", %{
                 verb: "work-item-close",
                 origin: "agent:#{ctx.lane.session_key}",
                 principal: {:session, ctx.lane.session_key},
                 params: %{work_item_id: item.id}
               })

      assert [_] = po_wakes(ctx, "remedy:spec-pinned-summons-spirit")
      assert po_wakes(ctx, "remedy:spec-repinned-summons-spirit") == []
    end

    test "when no product owner resolves the item is still created and the miss is recorded",
         ctx do
      item = create_item(ctx, {:session, ctx.orphan.session_key}, @spec_a)
      assert is_binary(item.id)
      assert po_wakes(ctx, "remedy:spec-pinned-summons-spirit") == []

      assert Enum.any?(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "rule_notice_failed" and &1.subject == "spec-pinned-summons-spirit")
             )
    end
  end

  describe "a spirit objection reaches the owner" do
    test "changes-requested by the PO wakes the opener of the open coder card", ctx do
      item = create_item(ctx, {:session, ctx.lane.session_key}, @spec_a)

      # The lane owner staffs the coder. Nothing refuses it.
      assert {:ok, impl} =
               Dispatch.dispatch(
                 ctx.db,
                 ctx.handlers,
                 assign_call(
                   {:session, ctx.lane.session_key},
                   ctx.coder.session_key,
                   item.id,
                   "implement the slice"
                 )
               )

      assert impl.holderKey == ctx.coder.session_key

      review = po_card(ctx, item.id)

      assert {:ok, %{attest: %{verdictKind: "changes-requested"}}} =
               Dispatch.dispatch(
                 ctx.db,
                 ctx.handlers,
                 verdict_call(ctx.po.session_key, review.id, "changes-requested")
               )

      assert [wake] =
               wakes_for(ctx, ctx.lane.session_key, "remedy:spirit-objection-reaches-owner")

      assert wake.prompt =~ ctx.po.session_key
      assert wake.prompt =~ review.id
      assert wake.prompt =~ item.id
    end

    test "with no implementation yet the objection goes to the item's creator", ctx do
      item = create_item(ctx, {:session, ctx.pdo.session_key}, @spec_a)
      review = po_card(ctx, item.id)

      assert {:ok, _} =
               Dispatch.dispatch(
                 ctx.db,
                 ctx.handlers,
                 verdict_call(ctx.po.session_key, review.id, "changes-requested")
               )

      assert [_] = wakes_for(ctx, ctx.pdo.session_key, "remedy:spirit-objection-reaches-owner")
    end

    test "approval and non-PO objections travel nowhere", ctx do
      item = create_item(ctx, {:session, ctx.lane.session_key}, @spec_a)

      assert {:ok, impl} =
               Dispatch.dispatch(
                 ctx.db,
                 ctx.handlers,
                 assign_call(
                   {:session, ctx.lane.session_key},
                   ctx.coder.session_key,
                   item.id,
                   "implement the slice"
                 )
               )

      approve(ctx, item.id)

      assert {:ok, _} =
               Dispatch.dispatch(
                 ctx.db,
                 ctx.handlers,
                 verdict_call(ctx.coder.session_key, impl.id, "changes-requested")
               )

      assert wakes_for(ctx, ctx.lane.session_key, "remedy:spirit-objection-reaches-owner") == []
    end
  end

  ## helpers

  defp create_item(ctx, principal, spec_sha) do
    params = %{title: "Spirit rumination #{System.unique_integer([:positive])}"}

    params =
      if spec_sha,
        do: Map.merge(params, %{spec_ref_name: "some-spec-v1.md", spec_ref_sha256: spec_sha}),
        else: params

    WorkItems.__handle__(ctx.db, "work-item-create", %{
      verb: "work-item-create",
      origin: origin(principal),
      principal: principal,
      params: params
    })
  end

  defp update_item(ctx, principal, item_id, spec_sha) do
    WorkItems.__handle__(ctx.db, "work-item-update", %{
      verb: "work-item-update",
      origin: origin(principal),
      principal: principal,
      params: %{
        work_item_id: item_id,
        spec_ref_name: "some-spec-v1.md",
        spec_ref_sha256: spec_sha
      }
    })
  end

  defp po_card(ctx, item_id) do
    assert {:ok, review} =
             Dispatch.dispatch(ctx.db, ctx.handlers, %{
               verb: "assign",
               origin: "user:flynn",
               principal: {:user, "flynn"},
               session_key: ctx.po.session_key,
               target_role: nil,
               role_fallback: false,
               params: %{subject: "spirit judgment", work_item_id: item_id}
             })

    review
  end

  defp approve(ctx, item_id) do
    review = po_card(ctx, item_id)

    assert {:ok, %{attest: %{verdictKind: "spirit-approved"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.po.session_key, review.id, "spirit-approved")
             )
  end

  defp assign_call(principal, holder_key, item_id, subject) do
    %{
      verb: "assign",
      origin: origin(principal),
      principal: principal,
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{subject: subject, work_item_id: item_id, effect_kind: "code"}
    }
  end

  defp verdict_call(session_key, assignment_id, kind) do
    %{
      verb: "attest",
      origin: "session:#{session_key}",
      principal: {:session, session_key},
      session_key: session_key,
      params: %{assignment_id: assignment_id, kind: "verdict", verdict_kind: kind}
    }
  end

  defp po_wakes(ctx, origin), do: wakes_for(ctx, ctx.po.session_key, origin)

  defp wakes_for(ctx, session_key, origin) do
    ctx.db
    |> Wakes.list_pending()
    |> Enum.filter(&(&1.session_key == session_key and &1.origin == origin))
  end

  defp origin({:session, key}), do: "agent:#{key}"
  defp origin({:user, user}), do: "user:#{user}"

  defp session(db, key, archetype, spawned_by) do
    Tightbeam.Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: archetype,
      harness: "codex",
      provider: "openai",
      host: "eezo",
      model: Model.new("sonnet", effort: "medium"),
      spawned_by: spawned_by,
      is_built_in: false
    })
  end
end
