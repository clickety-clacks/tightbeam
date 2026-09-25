defmodule Tightbeam.RefixRequiresDiagnosisTest do
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
    Org,
    RailRemedy,
    Roles,
    Rules,
    SessionPoAssociations,
    WorkItems
  }

  setup do
    db = :"proportionate_refix_db_#{System.unique_integer([:positive])}"
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

    holder = session(db, "fix-holder", "coder")
    recon = session(db, "recon-holder", "recon")
    po = session(db, "fix-po", "product-owner")
    pdo = session(db, "fix-pdo", "pdo")
    Roles.create!(db, "recon", "flynn", recon.session_key)
    Roles.create!(db, "product-owner:refix", "flynn", po.session_key)

    assert %{"changed" => true} =
             SessionPoAssociations.handle(db, %{
               principal: {:user, "flynn"},
               params: %{
                 session_key: pdo.session_key,
                 po_role: "product-owner:refix",
                 idempotency_key: "associate-refix-owner"
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
                 idempotency_key: "set-refix-owner"
               }
             })

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-proportionate-refix-#{System.unique_integer([:positive])}"
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

    %{db: db, handlers: handlers, holder: holder, pdo: pdo, rules: rules}
  end

  test "the shipped bundle omits count-triggered mandatory diagnosis", ctx do
    expected = [
      "completion-requires-review",
      "completion-requires-verification",
      "completion-requires-results-artifact",
      "wake-obligation-registration-authority"
    ]

    names =
      ctx.rules
      |> Enum.map(& &1.name)
      |> Enum.filter(&(&1 in expected))

    assert names == expected

    refute Enum.any?(ctx.rules, &(&1.name == "refix-requires-diagnosis"))
  end

  test "completed evidence work does not force recon before a repair", ctx do
    item = work_item(ctx, true)
    prior = completed_evidence(ctx, item.id)

    assert {:ok, next} =
             dispatch_after_rumination(
               ctx,
               dispatch_call(
                 ctx.pdo.session_key,
                 ctx.holder.session_key,
                 item.id,
                 "bounded repair"
               )
             )

    assert next.id != prior.id
    assert next.subject == "bounded repair"
    assert no_diagnosis_assignments(ctx.db, item.id)
    assert RailRemedy.episode(ctx.db, "refix-requires-diagnosis", item.id) == nil
  end

  test "disposed work still refuses a new assignment before any rail remedy", ctx do
    for verb <- ["work-item-close", "work-item-fail", "work-item-icebox"] do
      item = work_item(ctx, true)
      _prior = completed_evidence(ctx, item.id)

      assert %{ok: true} =
               ctx.handlers[verb].(%{
                 verb: verb,
                 origin: "user:flynn",
                 principal: {:user, "flynn"},
                 session_key: nil,
                 params: %{work_item_id: item.id}
               })

      assert {:error, %{code: "work_item_not_open"}} =
               Dispatch.dispatch(
                 ctx.db,
                 ctx.handlers,
                 dispatch_call(
                   ctx.pdo.session_key,
                   ctx.holder.session_key,
                   item.id,
                   "repeat fix"
                 )
               )

      assert no_diagnosis_assignments(ctx.db, item.id)
    end
  end

  defp work_item(ctx, is_bug) do
    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        principal: {:user, "flynn"},
        params: %{title: "Bug #{System.unique_integer([:positive])}", is_bug: is_bug}
      })

    establish_delivery(ctx, item)
    item
  end

  defp completed_evidence(ctx, work_item_id) do
    assignment =
      Assignments.__handle__(ctx.db, "assign", %{
        verb: "assign",
        origin: "agent:#{ctx.pdo.session_key}",
        principal: {:session, ctx.pdo.session_key},
        session_key: ctx.holder.session_key,
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{
          subject: "completed evidence",
          work_item_id: work_item_id,
          effect_kind: "evidence"
        }
      })

    assert assignment.effectKind == "evidence"

    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "session:#{ctx.holder.session_key}",
      principal: {:session, ctx.holder.session_key},
      session_key: nil,
      params: %{assignment_id: assignment.id, kind: "completion"}
    })

    assignment
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
                 idempotency_key: "bind-refix-#{item.id}"
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

  defp dispatch_call(caller_key, holder_key, work_item_id, subject) do
    %{
      verb: "dispatch",
      origin: "agent:#{caller_key}",
      principal: {:session, caller_key},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{subject: subject, brief: "Implement #{subject}.", work_item_id: work_item_id}
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

  defp no_diagnosis_assignments(db, work_item_id) do
    match?(
      {:ok, [[0]]},
      DB.query(
        db,
        "SELECT count(*) FROM assignments WHERE workItemId = ?1 AND holderRole = 'recon'",
        [work_item_id]
      )
    )
  end

  defp session(db, key, archetype) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: archetype,
      host: "eezo",
      harness: "codex",
      provider: "openai",
      model: Model.new("test")
    })
  end
end
