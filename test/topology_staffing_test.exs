defmodule Tightbeam.TopologyStaffingTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model
  alias Tightbeam.{Archetypes, DB, Dispatch, Gateway, Identity, Rules, WorkItems}

  setup do
    db = :"topology_db_#{System.unique_integer([:positive])}"
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

    holder = session(db, "impl-holder", "coder")
    owner = session(db, "po-holder", "product-owner")

    pdo = session(db, "delivery-owner", "orchestrator")
    lane = session(db, "lane-owner", "orchestrator")

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-topology-#{System.unique_integer([:positive])}"
      )

    assert :initialized = Archetypes.init_identity!(base_dir)
    assert {:ok, _revision} = Identity.learn!(base_dir, "agentic-engineering", "flynn")
    _archetypes = Archetypes.load!(base_dir)

    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
    rules = Rules.load!(base_dir, Map.keys(handlers))

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Rules)
      :persistent_term.erase(Archetypes)
    end)

    %{
      db: db,
      handlers: handlers,
      holder: holder,
      owner: owner,
      pdo: pdo,
      lane: lane,
      rules: rules,
      base_dir: base_dir
    }
  end

  test "every new item requires topology before either staffing verb", ctx do
    for verb <- ["assign", "dispatch"] do
      item = work_item(ctx)
      call = staffing_call(verb, ctx.holder.session_key, item.id, "code")

      {:ok, wakes_before} =
        DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE work_item_id=?1", [item.id])

      assert {:error, %{code: "rule_denied", message: message}} = run(ctx, call)
      assert message =~ "topology"

      assert {:ok, [[0]]} =
               DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE workItemId=?1", [item.id])

      assert {:ok, ^wakes_before} =
               DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE work_item_id=?1", [item.id])

      record_topology(ctx, item)
      assert {:ok, %{holderKey: holder}} = run(ctx, call)
      assert holder == ctx.holder.session_key
      other_item = work_item(ctx)

      assert {:error, %{code: "rule_denied"}} =
               run(ctx, put_in(call.params.work_item_id, other_item.id))
    end
  end

  test "PDO intake and PO consultation can produce the decision without a deadlock", ctx do
    for verb <- ["assign", "dispatch"] do
      item = work_item(ctx)
      intake = staffing_call(verb, ctx.pdo.session_key, item.id, "coordination")
      assert {:ok, %{id: _}} = run(ctx, intake)
      lane = staffing_call(verb, ctx.lane.session_key, item.id, "coordination")
      assert {:error, %{code: "rule_denied"}} = run(ctx, lane)
      consultation = staffing_call(verb, ctx.owner.session_key, item.id, "coordination")
      assert {:ok, %{id: id}} = run(ctx, consultation)
      assert {:ok, _} = run(ctx, verdict_call(ctx.owner.session_key, id, "topology-decided"))
      assert {:ok, %{id: _}} = run(ctx, lane)
    end
  end

  test "spirit approval, progress and consultation completion cannot replace topology", ctx do
    item = work_item(ctx)

    assert {:ok, consultation} =
             run(ctx, assign_call(ctx.owner.session_key, item.id, "understand intent"))

    assert {:ok, _} =
             run(ctx, verdict_call(ctx.owner.session_key, consultation.id, "spirit-approved"))

    for kind <- ["progress", "completion"] do
      call = verdict_call(ctx.owner.session_key, consultation.id, "unused")

      call =
        put_in(call.params, %{
          assignment_id: consultation.id,
          kind: kind,
          note: "Intent understood"
        })

      assert {:ok, _} = run(ctx, call)
    end

    assert {:error, %{code: "rule_denied"}} =
             run(ctx, staffing_call("dispatch", ctx.holder.session_key, item.id, "code"))
  end

  test "a delivery owner may record returned advice without a designated-PO identity check",
       ctx do
    item = work_item(ctx)

    assert {:ok, intake} =
             run(ctx, staffing_call("assign", ctx.pdo.session_key, item.id, "coordination"))

    call = verdict_call(ctx.pdo.session_key, intake.id, "topology-decided")

    call =
      put_in(
        call.params[:note],
        "PO recommends one coder and an independent reviewer, no child orchestrators; one coupled lane."
      )

    assert {:ok, _} = run(ctx, call)
    assert {:ok, _} = run(ctx, staffing_call("assign", ctx.holder.session_key, item.id, "code"))
  end

  test "worker coordination, planner code and omitted effects do not bypass the rule", ctx do
    for verb <- ["assign", "dispatch"],
        {holder, effect} <- [
          {ctx.holder, "coordination"},
          {ctx.pdo, "code"},
          {ctx.owner, "code"},
          {ctx.pdo, nil}
        ] do
      item = work_item(ctx)

      assert {:error, %{code: "rule_denied"}} =
               run(ctx, staffing_call(verb, holder.session_key, item.id, effect))
    end
  end

  test "dropping the work-item reference does not bypass topology", ctx do
    for verb <- ["assign", "dispatch"], holder <- [ctx.holder, ctx.pdo, ctx.owner] do
      assert {:error, %{code: "rule_denied", message: message}} =
               run(ctx, staffing_call(verb, holder.session_key, nil, "coordination"))

      assert message =~ "work item"
    end
  end

  test "session callers face the same staffing boundary as user callers", ctx do
    item = work_item(ctx)

    for verb <- ["assign", "dispatch"] do
      call = staffing_call(verb, ctx.holder.session_key, item.id, "code")

      call = %{
        call
        | origin: "session:#{ctx.pdo.session_key}",
          principal: {:session, ctx.pdo.session_key}
      }

      assert {:error, %{code: "rule_denied"}} = run(ctx, call)
    end
  end

  test "unrelated assignment parameters cannot lend topology to unlinked staffing", ctx do
    other = work_item(ctx)
    consultation = record_topology(ctx, other)

    for verb <- ["assign", "dispatch"] do
      call = staffing_call(verb, ctx.holder.session_key, nil, "code")
      call = put_in(call.params[:assignment_id], consultation.id)
      assert {:error, %{rule: rule}} = run(ctx, call)
      assert rule == "#{verb}-staffing-needs-work-item"

      own_item = work_item(ctx)
      call = put_in(call.params[:work_item_id], own_item.id)
      assert {:error, %{code: "rule_denied"}} = run(ctx, call)
    end

    call = staffing_call("dispatch", ctx.holder.session_key, nil, "code")
    call = put_in(call.params[:reviews_assignment_id], consultation.id)
    assert {:error, %{rule: "dispatch-staffing-needs-work-item"}} = run(ctx, call)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE workItemId IS NULL")
  end

  test "intake retries return the existing assignment rather than staffing twice", ctx do
    item = work_item(ctx)
    call = staffing_call("dispatch", ctx.pdo.session_key, item.id, "coordination")
    call = put_in(call.params[:idempotency_key], "topology-intake")
    assert {:ok, first} = run(ctx, call)
    assert {:ok, again} = run(ctx, call)
    assert first.id == again.id
  end

  test "the insertion transaction rechecks first intake after preflight", ctx do
    item = work_item(ctx)
    first = staffing_call("assign", ctx.pdo.session_key, item.id, "coordination")
    second = staffing_call("assign", ctx.lane.session_key, item.id, "coordination")
    assert :ok = Rules.evaluate(ctx.db, first)
    assert :ok = Rules.evaluate(ctx.db, second)
    assert {:ok, _} = run(ctx, first)
    # Invoke the actual handler after its earlier preflight admitted the call.
    # This is the interleaving of two concurrent dispatch callers.
    assert %{code: "rule_denied"} = Map.fetch!(ctx.handlers, "assign").(second)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE workItemId=?1", [item.id])
  end

  test "linked reviews inherit the item's topology without a duplicate explicit reference", ctx do
    item = work_item(ctx)
    record_topology(ctx, item)

    assert {:ok, producer} =
             run(ctx, staffing_call("assign", ctx.holder.session_key, item.id, "evidence"))

    review = staffing_call("assign", ctx.owner.session_key, nil, "coordination")
    review = put_in(review.params[:reviews_assignment_id], producer.id)
    assert {:ok, %{effectKind: "review"}} = run(ctx, review)
  end

  defp record_topology(ctx, item) do
    assert {:ok, consultation} =
             run(ctx, assign_call(ctx.owner.session_key, item.id, "recommend topology"))

    call = verdict_call(ctx.owner.session_key, consultation.id, "topology-decided")

    call =
      put_in(
        call.params[:note],
        "One coder and an independent reviewer; no additional orchestrators needed."
      )

    assert {:ok, _} = run(ctx, call)
    consultation
  end

  defp staffing_call(verb, holder, item, effect) do
    call =
      if verb == "assign",
        do: assign_call(holder, item, "staff work"),
        else: dispatch_call(holder, item, "staff work")

    put_in(call.params[:effect_kind], effect)
  end

  defp run(ctx, call), do: Dispatch.dispatch(ctx.db, ctx.handlers, call)

  defp work_item(ctx) do
    WorkItems.__handle__(ctx.db, "work-item-create", %{
      principal: {:user, "flynn"},
      params: %{
        title: "Spirit opportunity #{System.unique_integer([:positive])}",
        is_bug: true
      }
    })
  end

  defp assign_call(holder_key, item_id, subject) do
    %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{subject: subject, work_item_id: item_id, effect_kind: "coordination"}
    }
  end

  defp dispatch_call(holder_key, item_id, subject) do
    %{
      verb: "dispatch",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{subject: subject, brief: "Implement #{subject}.", work_item_id: item_id}
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

  defp session(db, key, archetype) do
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
      spawned_by: nil,
      is_built_in: false
    })
  end
end
