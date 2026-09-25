defmodule Tightbeam.SpecDispatchRequiresSpiritTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Archetypes,
    Assignments,
    DB,
    DeliveryResponsibilities,
    Dispatch,
    Gateway,
    Identity,
    Roles,
    Rules,
    SessionPoAssociations,
    WorkItems
  }

  setup do
    db = :"spirit_opportunity_db_#{System.unique_integer([:positive])}"
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
    pdo = session(db, "delivery-owner", "pdo")

    Roles.create!(db, "product-owner:spirit", "flynn", owner.session_key)

    assert %{"changed" => true} =
             SessionPoAssociations.handle(db, %{
               principal: {:user, "flynn"},
               params: %{
                 session_key: pdo.session_key,
                 po_role: "product-owner:spirit",
                 idempotency_key: "associate-spirit-owner"
               }
             })

    assert %{"changed" => true} =
             DeliveryResponsibilities.handle(db, %{
               verb: "delivery-scope-owner-set",
               origin: "user:flynn",
               principal: {:user, "flynn"},
               params: %{
                 session_key: pdo.session_key,
                 association_revision: 1,
                 expected_owner_session_key: nil,
                 expected_owner_revision: 0,
                 idempotency_key: "set-spirit-owner"
               }
             })

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-spirit-opportunity-#{System.unique_integer([:positive])}"
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
      rules: rules,
      base_dir: base_dir
    }
  end

  test "spec-backed preparation proceeds without a historical spirit token", ctx do
    refute "spec-dispatch-requires-spirit" in Enum.map(ctx.rules, & &1.name)
    item = work_item(ctx)

    assert {:ok, assignment} =
             dispatch_after_rumination(
               ctx,
               dispatch_call(
                 ctx.pdo.session_key,
                 ctx.holder.session_key,
                 item.id,
                 "prepare the bounded implementation"
               )
             )

    assert assignment.subject == "prepare the bounded implementation"
  end

  test "the product owner can still record current intent judgment on the same item", ctx do
    item = work_item(ctx)

    assert {:ok, review} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               user_assign_call(ctx.owner.session_key, item.id, "judge the current spec intent",
                 effect_kind: "coordination"
               )
             )

    assert {:ok, %{attest: %{verdictKind: "spirit-approved"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.owner.session_key, review.id, "spirit-approved")
             )
  end

  # This synthetic rule exercises the still-supported engine fact. It is test
  # policy only, not a shipped round limit or a required review workflow.
  test "assignment.review_verdict_count counts conclusions through the rules engine", ctx do
    rules_dir = Path.join(ctx.base_dir, "identity/rules")
    File.mkdir_p!(rules_dir)

    File.write!(Path.join(rules_dir, "round-count-probe.toml"), """
    [[rule]]
    name = "round-count-probe"
    verb = "attest"
    text = "synthetic fact probe: refuse after two recorded conclusions"
    edges = ["verb"]
    effect = "deny"
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "verdict" },
      { fact = "assignment.review_verdict_count", op = "gte", value = 2 },
    ]
    """)

    assert "round-count-probe" in Enum.map(
             Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)),
             & &1.name
           )

    item = work_item(ctx)

    call =
      dispatch_call(
        ctx.pdo.session_key,
        ctx.holder.session_key,
        item.id,
        "evidence under review"
      )

    call = put_in(call, [:params, :effect_kind], "evidence")
    assert {:ok, subject} = dispatch_after_rumination(ctx, call)

    for round <- 1..3 do
      call =
        user_assign_call(
          ctx.owner.session_key,
          item.id,
          "independent conclusion #{round}",
          reviews_assignment_id: subject.id
        )

      assert {:ok, review} = Dispatch.dispatch(ctx.db, ctx.handlers, call)

      result =
        Dispatch.dispatch(
          ctx.db,
          ctx.handlers,
          verdict_call(ctx.owner.session_key, review.id, "changes-requested")
        )

      if round < 3,
        do: assert({:ok, _} = result),
        else: assert({:error, %{rule: "round-count-probe"}} = result)
    end
  end

  defp work_item(ctx) do
    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        principal: {:user, "flynn"},
        params: %{
          title: "Spirit opportunity #{System.unique_integer([:positive])}",
          spec_ref_name: "some-spec-v1.md",
          spec_ref_sha256: String.duplicate("a", 64)
        }
      })

    establish_delivery(ctx, item)
    item
  end

  defp establish_delivery(ctx, item) do
    assert %{"changed" => true} =
             DeliveryResponsibilities.handle(ctx.db, %{
               verb: "work-item-delivery-scope-set",
               origin: "user:flynn",
               principal: {:user, "flynn"},
               params: %{
                 work_item_id: item.id,
                 association_session_key: ctx.pdo.session_key,
                 association_revision: 1,
                 expected_binding_revision: 0,
                 idempotency_key: "bind-spirit-#{item.id}"
               }
             })

    topology =
      Assignments.__handle__(ctx.db, "assign", %{
        verb: "assign",
        origin: "agent:#{ctx.pdo.session_key}",
        principal: {:session, ctx.pdo.session_key},
        session_key: ctx.pdo.session_key,
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{
          subject: "return topology",
          work_item_id: item.id,
          effect_kind: "coordination"
        }
      })

    assert %{attest: %{verdictKind: "topology-decided"}} =
             Assignments.__handle__(ctx.db, "attest", %{
               verb: "attest",
               origin: "agent:#{ctx.pdo.session_key}",
               principal: {:session, ctx.pdo.session_key},
               params: %{
                 assignment_id: topology.id,
                 kind: "verdict",
                 verdict_kind: "topology-decided"
               }
             })

    assert %{assignment: %{state: "closed"}} =
             Assignments.__handle__(ctx.db, "attest", %{
               verb: "attest",
               origin: "agent:#{ctx.pdo.session_key}",
               principal: {:session, ctx.pdo.session_key},
               params: %{assignment_id: topology.id, kind: "completion"}
             })
  end

  defp user_assign_call(holder_key, item_id, subject, options) do
    %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{
        subject: subject,
        work_item_id: item_id,
        effect_kind: options[:effect_kind],
        reviews_assignment_id: options[:reviews_assignment_id]
      }
    }
  end

  defp dispatch_call(caller_key, holder_key, item_id, subject) do
    %{
      verb: "dispatch",
      origin: "agent:#{caller_key}",
      principal: {:session, caller_key},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{subject: subject, brief: "Implement #{subject}.", work_item_id: item_id}
    }
  end

  defp dispatch_after_rumination(ctx, call) do
    assert {:ok, %{rumination_required: true}} = Dispatch.dispatch(ctx.db, ctx.handlers, call)

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               UPDATE wakes SET state = 'fired'
               WHERE rumination = 1 AND work_item_id = ?1 AND creatorSessionKey = ?2
               """,
               [call.params.work_item_id, elem(call.principal, 1)]
             )

    Dispatch.dispatch(ctx.db, ctx.handlers, call)
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
