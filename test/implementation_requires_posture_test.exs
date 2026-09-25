defmodule Tightbeam.ImplementationRequiresPostureTest do
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
    db = :"proportionate_dispatch_db_#{System.unique_integer([:positive])}"
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

    coder = session(db, "proportionate-coder", "coder")
    orchestrator = session(db, "proportionate-orchestrator", "orchestrator")
    reviewer = session(db, "proportionate-reviewer", "reviewer-spec")
    po = session(db, "proportionate-po", "product-owner")

    Roles.create!(db, "product-owner:posture", "flynn", po.session_key)

    assert %{"changed" => true} =
             SessionPoAssociations.handle(db, %{
               principal: {:user, "flynn"},
               params: %{
                 session_key: orchestrator.session_key,
                 po_role: "product-owner:posture",
                 idempotency_key: "associate-posture-owner"
               }
             })

    assert %{"changed" => true} =
             DeliveryResponsibilities.handle(db, %{
               verb: "delivery-scope-owner-set",
               origin: "user:flynn",
               principal: {:user, "flynn"},
               params: %{
                 session_key: orchestrator.session_key,
                 association_revision: 1,
                 expected_owner_session_key: nil,
                 expected_owner_revision: 0,
                 idempotency_key: "set-posture-owner"
               }
             })

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-proportionate-dispatch-#{System.unique_integer([:positive])}"
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
      coder: coder,
      orchestrator: orchestrator,
      reviewer: reviewer,
      rules: rules
    }
  end

  test "the shipped bundle omits posture-token admission rails", ctx do
    names = Enum.map(ctx.rules, & &1.name)
    refute "implementation-requires-posture" in names
    refute "implementation-dispatch-requires-posture" in names
  end

  test "coder assignment and dispatch proceed without a posture receipt", ctx do
    item = work_item(ctx)

    assert {:ok, assigned} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               session_assign_call(
                 ctx.orchestrator.session_key,
                 ctx.coder.session_key,
                 item.id,
                 "implement the bounded repair"
               )
             )

    assert assigned.subject == "implement the bounded repair"

    assert {:ok, dispatched} =
             dispatch_after_rumination(
               ctx,
               dispatch_call(
                 ctx.orchestrator.session_key,
                 ctx.coder.session_key,
                 item.id,
                 "implement the follow-up"
               )
             )

    assert dispatched.subject == "implement the follow-up"
  end

  test "a legacy posture-light verdict remains ordinary evidence, not an admission token", ctx do
    item = work_item(ctx)

    assert {:ok, slice} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               user_assign_call(ctx.orchestrator.session_key, item.id, "coordinate the repair",
                 effect_kind: "coordination"
               )
             )

    assert {:ok, %{attest: %{verdictKind: "posture-light"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.orchestrator.session_key, slice.id, "posture-light")
             )

    assert {:ok, implementation} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               session_assign_call(
                 ctx.orchestrator.session_key,
                 ctx.coder.session_key,
                 item.id,
                 "implement after judgment"
               )
             )

    assert implementation.subject == "implement after judgment"
  end

  test "a legacy posture-heavy verdict does not select a mechanical workflow", ctx do
    item = work_item(ctx)

    assert {:ok, slice} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               user_assign_call(
                 ctx.orchestrator.session_key,
                 item.id,
                 "coordinate consequential work",
                 effect_kind: "coordination"
               )
             )

    assert {:ok, %{attest: %{verdictKind: "posture-heavy"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.orchestrator.session_key, slice.id, "posture-heavy")
             )

    assert {:ok, implementation} =
             dispatch_after_rumination(
               ctx,
               dispatch_call(
                 ctx.orchestrator.session_key,
                 ctx.coder.session_key,
                 item.id,
                 "implement the authorized slice"
               )
             )

    assert implementation.subject == "implement the authorized slice"
  end

  test "a non-coder assignment remains admitted without a posture receipt", ctx do
    item = work_item(ctx)

    assert {:ok, producer} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               session_assign_call(
                 ctx.orchestrator.session_key,
                 ctx.coder.session_key,
                 item.id,
                 "produce the specification"
               )
             )

    assert {:ok, review} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               user_assign_call(ctx.reviewer.session_key, item.id, "review the specification",
                 reviews_assignment_id: producer.id
               )
             )

    assert review.subject == "review the specification"
  end

  test "posture evidence on another item has no admission effect", ctx do
    item = work_item(ctx)
    other = work_item(ctx)

    assert {:ok, slice} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               user_assign_call(ctx.orchestrator.session_key, other.id, "coordinate another item",
                 effect_kind: "coordination"
               )
             )

    assert {:ok, _} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.orchestrator.session_key, slice.id, "posture-light")
             )

    assert {:ok, implementation} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               session_assign_call(
                 ctx.orchestrator.session_key,
                 ctx.coder.session_key,
                 item.id,
                 "implement independently"
               )
             )

    assert implementation.subject == "implement independently"
  end

  defp work_item(ctx) do
    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        principal: {:user, "flynn"},
        params: %{title: "Proportionate work #{System.unique_integer([:positive])}"}
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
                 association_session_key: ctx.orchestrator.session_key,
                 association_revision: 1,
                 expected_binding_revision: 0,
                 idempotency_key: "bind-posture-#{item.id}"
               }
             })

    topology =
      Assignments.__handle__(ctx.db, "assign", %{
        verb: "assign",
        origin: "agent:#{ctx.orchestrator.session_key}",
        principal: {:session, ctx.orchestrator.session_key},
        session_key: ctx.orchestrator.session_key,
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
               origin: "agent:#{ctx.orchestrator.session_key}",
               principal: {:session, ctx.orchestrator.session_key},
               params: %{
                 assignment_id: topology.id,
                 kind: "verdict",
                 verdict_kind: "topology-decided"
               }
             })

    assert %{assignment: %{state: "closed"}} =
             Assignments.__handle__(ctx.db, "attest", %{
               verb: "attest",
               origin: "agent:#{ctx.orchestrator.session_key}",
               principal: {:session, ctx.orchestrator.session_key},
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

  defp session_assign_call(caller_key, holder_key, item_id, subject) do
    %{
      verb: "assign",
      origin: "agent:#{caller_key}",
      principal: {:session, caller_key},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{subject: subject, work_item_id: item_id}
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
