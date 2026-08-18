defmodule Tightbeam.SpecDispatchRequiresSpiritTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Archetypes,
    DB,
    Dispatch,
    EventLog,
    Gateway,
    Identity,
    Roles,
    Rules,
    Wakes,
    WorkItems
  }

  # The adjudication postmortem's wiring fix (spec production-machine-v1 era,
  # decisions ledger 2026-08-05): an 11-round spec pipeline ran
  # spec->review->implementation with no product-owner edge to cross. This
  # statute creates the edge; these tests prove it summons and releases, and
  # that unspecced work never crosses it.
  setup do
    db = :"spirit_gate_db_#{System.unique_integer([:positive])}"
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

    holder = session(db, "impl-holder", "coder", "claude", "anthropic")
    owner = session(db, "po-holder", "product-owner", "codex", "openai")
    Roles.create!(db, "product-owner", "flynn", owner.session_key)

    start_supervised!(
      {Wakes,
       db: db, deliver: fn _wake -> true end, tick_ms: 60_000, name: Tightbeam.WakeScheduler}
    )

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-spirit-gate-#{System.unique_integer([:positive])}")

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

    %{db: db, handlers: handlers, holder: holder, owner: owner, rules: rules, base_dir: base_dir}
  end

  defp session(db, key, archetype, harness, provider) do
    Tightbeam.Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: archetype,
      harness: harness,
      provider: provider,
      host: "eezo",
      model: Model.new("sonnet", effort: "medium"),
      spawned_by: nil,
      is_built_in: false
    })
  end

  defp work_item(ctx, spec_ref) do
    params = %{title: "Spirit subject #{System.unique_integer([:positive])}"}

    params =
      if spec_ref,
        do:
          Map.merge(params, %{
            spec_ref_name: spec_ref,
            spec_ref_sha256: String.duplicate("a", 64)
          }),
        else: params

    WorkItems.__handle__(ctx.db, "work-item-create", %{
      principal: {:user, "flynn"},
      params: params
    })
  end

  defp dispatch_call(holder_key, item_id, subject) do
    %{
      verb: "dispatch",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      params: %{
        subject: subject,
        brief: "Implement #{subject}.",
        work_item_id: item_id
      }
    }
  end

  defp verdict_call(session_key, assignment_id, kind, note \\ nil) do
    %{
      verb: "attest",
      origin: "session:#{session_key}",
      principal: {:session, session_key},
      session_key: session_key,
      params: %{
        assignment_id: assignment_id,
        kind: "verdict",
        verdict_kind: kind,
        note: note
      }
    }
  end

  test "unspecced work dispatches without a spirit verdict", ctx do
    item = work_item(ctx, nil)

    assert {:ok, assignment} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call(ctx.holder.session_key, item.id, "routine fix")
             )

    assert assignment.subject == "routine fix"
  end

  test "spec-backed dispatch summons the product owner and the verdict releases it", ctx do
    item = work_item(ctx, "some-spec-v1.md")

    call = dispatch_call(ctx.holder.session_key, item.id, "build the spec")

    assert {:error,
            %{code: "rule_denied", rule: "spec-dispatch-requires-spirit", message: message}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, call)

    assert message =~ "spirit review"

    # A MIND arranges the review the deny named (here, the test as the org's
    # inference): assign the product owner a spirit review of the item.
    {:ok, spirit} =
      Dispatch.dispatch(ctx.db, ctx.handlers, %{
        verb: "assign",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: ctx.owner.session_key,
        target_role: nil,
        role_fallback: false,
        params: %{
          subject: "spirit review of work item #{item.id}",
          work_item_id: item.id
        }
      })

    assert {:ok, %{attest: %{verdictKind: "spirit-approved"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.owner.session_key, spirit.id, "spirit-approved")
             )

    assert {:ok, assignment} = Dispatch.dispatch(ctx.db, ctx.handlers, call)
    assert assignment.subject == "build the spec"
  end

  # The round counter, proven through the ENGINE rather than by reading the
  # function: a synthetic org statute denies past 2 rounds; two verdicts pass,
  # the third is refused.
  test "assignment.review_verdict_count counts rounds through the rules engine", ctx do
    rules_dir = Path.join(ctx.base_dir, "identity/rules")
    File.mkdir_p!(rules_dir)

    File.write!(Path.join(rules_dir, "round-cap.toml"), """
    [[rule]]
    name = "round-cap-probe"
    verb = "attest"
    text = "synthetic: no more than two review rounds"
    edges = ["verb"]
    effect = "deny"
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "verdict" },
      { fact = "assignment.review_verdict_count", op = "gte", value = 2 },
    ]
    """)

    rules = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    assert "round-cap-probe" in Enum.map(rules, & &1.name)

    item = work_item(ctx, nil)

    {:ok, subject} =
      Dispatch.dispatch(
        ctx.db,
        ctx.handlers,
        dispatch_call(ctx.holder.session_key, item.id, "work under review")
      )

    review_call = fn n ->
      %{
        verb: "assign",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: ctx.owner.session_key,
        target_role: nil,
        role_fallback: false,
        params: %{
          subject: "round #{n}",
          reviews_assignment_id: subject.id
        }
      }
    end

    assert {:ok, _} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(
                 ctx.holder.session_key,
                 subject.id,
                 "tests-passed",
                 "testhost:/repo abc123; mix test test/spec_dispatch_requires_spirit_test.exs; passed"
               )
             )

    {:ok, r1} = Dispatch.dispatch(ctx.db, ctx.handlers, review_call.(1))

    assert {:ok, _} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.owner.session_key, r1.id, "changes-requested")
             )

    {:ok, r2} = Dispatch.dispatch(ctx.db, ctx.handlers, review_call.(2))

    assert {:ok, _} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.owner.session_key, r2.id, "changes-requested")
             )

    {:ok, r3} = Dispatch.dispatch(ctx.db, ctx.handlers, review_call.(3))

    r3_result =
      Dispatch.dispatch(
        ctx.db,
        ctx.handlers,
        verdict_call(ctx.owner.session_key, r3.id, "changes-requested")
      )

    assert {:error, %{rule: "round-cap-probe"}} = r3_result
  end

  test "review-rounds doorbell records and summons once without blocking attests", ctx do
    item = work_item(ctx, nil)

    {:ok, subject} =
      Dispatch.dispatch(
        ctx.db,
        ctx.handlers,
        dispatch_call(ctx.holder.session_key, item.id, "work under repeated review")
      )

    assert {:ok, %{attest: %{verdictKind: "tests-passed"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(
                 ctx.holder.session_key,
                 subject.id,
                 "tests-passed",
                 "fixture suite passed at the reviewed revision"
               )
             )

    review_call = fn n ->
      %{
        verb: "assign",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: ctx.owner.session_key,
        target_role: nil,
        role_fallback: false,
        params: %{
          subject: "doorbell round #{n}",
          reviews_assignment_id: subject.id
        }
      }
    end

    for n <- 1..4 do
      {:ok, review} = Dispatch.dispatch(ctx.db, ctx.handlers, review_call.(n))

      assert {:ok, %{attest: %{verdictKind: "changes-requested"}}} =
               Dispatch.dispatch(
                 ctx.db,
                 ctx.handlers,
                 verdict_call(ctx.owner.session_key, review.id, "changes-requested")
               )
    end

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE origin = 'remedy:review-rounds-doorbell'"
             )

    {:ok, crossing} = Dispatch.dispatch(ctx.db, ctx.handlers, review_call.(5))

    assert {:ok, %{attest: %{verdictKind: "changes-requested"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.owner.session_key, crossing.id, "changes-requested")
             )

    owner_session_key = ctx.owner.session_key

    assert {:ok, [[1, ^owner_session_key]]} =
             DB.query(
               ctx.db,
               """
               SELECT COUNT(*), sessionKey
               FROM wakes
               WHERE origin = 'remedy:review-rounds-doorbell'
               """
             )

    assert [%{kind: "rail_notice", subject: "review-rounds-doorbell", detail: detail}] =
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.filter(&(&1.kind == "rail_notice"))

    assert %{"ref" => ref, "outcome" => "claimed-dispatched"} = JSON.decode!(detail)
    assert ref == subject.id

    {:ok, repeated} = Dispatch.dispatch(ctx.db, ctx.handlers, review_call.(6))

    assert {:ok, %{attest: %{kind: "progress"}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, %{
               verb: "attest",
               origin: "session:#{ctx.owner.session_key}",
               principal: {:session, ctx.owner.session_key},
               session_key: ctx.owner.session_key,
               params: %{
                 assignment_id: repeated.id,
                 kind: "progress",
                 note: "sixth review is still in progress"
               }
             })

    assert {:ok, %{attest: %{verdictKind: "changes-requested"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               verdict_call(ctx.owner.session_key, repeated.id, "changes-requested")
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE origin = 'remedy:review-rounds-doorbell'"
             )

    assert 1 ==
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.count(&(&1.kind == "rail_notice"))
  end
end
