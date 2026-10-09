defmodule Tightbeam.FeatureSmokeRailPathTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Archetypes, DB, Gateway, Model, ModelCatalog, Org, Roles, Rules, Schema}
  alias Tightbeam.Wire.Router
  alias Tightbeam.FeatureSmokeDriverFixture, as: Driver

  setup_all do
    # Compile the real script's module without its top-level online entrypoint.
    # Only visibility and module name change; HTTP, SQL, assertions, setup and
    # receipt bodies run unchanged. No provider response is synthesized.
    {:__block__, _, forms} =
      "scripts/feature_smoke.exs" |> File.read!() |> Code.string_to_quoted!()

    module = Enum.find(forms, &match?({:defmodule, _, _}, &1))

    module =
      Macro.prewalk(module, fn
        {:defmodule, meta, [{:__aliases__, am, [:FeatureSmoke]}, body]} ->
          {:defmodule, meta, [{:__aliases__, am, [:Tightbeam, :FeatureSmokeDriverFixture]}, body]}

        {:defp, meta, args} ->
          {:def, meta, args}

        node ->
          node
      end)

    Code.compile_quoted(module, "scripts/feature_smoke.exs")
    :ok
  end

  setup do
    base = Path.join(System.tmp_dir!(), "smoke-rail-path-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{payload: payload} = Tightbeam.GuardRuntimeFixture.prepare!(base, "unused")

    db =
      start_supervised!(
        {DB,
         path: Path.join(base, "state.db"), name: nil, guard_inputs: [], payload_root: payload}
      )

    :ok = Schema.ensure_all(db)
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    # Real readiness admission publishes and rings a lane after committing;
    # this fixture has no provider lane, but must own that local doorbell.
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})
    register_hosts(db, %{"testhost" => %{ssh: nil, base_dir: base, cli_bin: nil}})
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('mike',1,1)")

    Org.create(db, %{
      session_key: Org.personal_session_key("mike"),
      display_name: "main",
      kind: "main",
      owner_user_id: "mike",
      origin: "user:mike",
      host: "testhost",
      archetype: "default",
      harness: "fixture",
      provider: "fixture_provider",
      model: Model.new("fixture-model")
    })

    File.mkdir_p!(Path.join(base, "identity/archetypes"))

    for name <- ~w(default coder reviewer-code product-owner orchestrator) do
      File.write!(Path.join(base, "identity/archetypes/#{name}.toml"), """
      name = "#{name}"
      where = ["testhost"]
      [guidance]
      text = "Disposable rule-path fixture; no provider invocation."
      """)
    end

    Archetypes.load!(base)
    File.write!(Path.join(base, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
    Tightbeam.RecoveryFixture.place_adapter!(base, seed_credential: false)
    fixture_home = Tightbeam.Homes.home_path(base, "testhost", :fixture)
    File.mkdir_p!(fixture_home)
    File.write!(Path.join(fixture_home, "fixture.json"), "synthetic-nonsecret-fixture-only")

    start_supervised!(
      {ModelCatalog,
       base_dir: base,
       db: db,
       credential_status: fn provider ->
         if provider == :fixture_provider, do: :onboarded, else: :missing
       end,
       credential_kind: fn _ -> :subscription end}
    )

    handlers =
      Gateway.handlers(%{
        db: db,
        base_dir: base,
        cwd: base,
        wake_tick_ms: 1_000,
        default_harness: :fixture,
        default_model: Model.new("fixture-model"),
        credential_status: fn provider ->
          if provider == :fixture_provider, do: :onboarded, else: :missing
        end,
        credential_kind: fn _ -> :subscription end
      })

    File.mkdir_p!(Path.join(base, "identity/rules"))

    for name <- ~w(topology engineering verification) do
      File.cp!(
        "test/support/fixtures/feature_smoke_#{name}.toml",
        Path.join(base, "identity/rules/#{name}.toml")
      )
    end

    File.cp!(
      "priv/kungfu/agentic-engineering/rules/delivery.toml",
      Path.join(base, "identity/rules/delivery.toml")
    )

    Rules.load!(base, Map.keys(handlers))
    # Real wake scheduling and atomic carrier admission; the local doorbell
    # does not execute a provider or synthesize an assistant turn.
    # Nothing calls an adapter or manufactures an inference/tool-call result.
    start_supervised!(
      {Tightbeam.Wakes,
       db: db, name: Tightbeam.WakeScheduler, tick_ms: 25, deliver: fn _ -> :ok end}
    )

    opts = Router.init(db: db, base_dir: base, handlers: handlers, cli_token: "tbc_fixture")

    server =
      start_supervised!(
        {Bandit, plug: {Router, opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    leg = %{
      harness: Tightbeam.Harness.Fixture,
      wire_name: "fixture",
      model: "fixture-model",
      effort: nil,
      context: nil
    }

    state = %{
      port: port,
      token: "tbc_fixture",
      base_dir: base,
      leg: leg,
      pass: 0,
      smoke_scope: "synthetic"
    }

    %{db: db, base: base, handlers: handlers, state: state}
  end

  test "real script staffing, default-archetype and query paths with loaded rules", ctx do
    ExUnit.CaptureIO.capture_io(fn ->
      Driver.check_facts_read(ctx.state)
      Driver.check_config_default_archetype(ctx.state)
      Driver.check_work_item_and_assignment_get(ctx.state)
      Driver.check_dispatch_opens_assignment(ctx.state)
      Driver.check_breathing_query(ctx.state)
      Driver.check_execution_map(ctx.state)
      Driver.check_toplines_list(ctx.state)
    end)

    assert {:ok, [[count]]} = DB.query(ctx.db, "SELECT count(*) FROM assignments")
    assert count >= 4

    assert {:ok, [[dispatch_id, dispatch_holder]]} =
             DB.query(ctx.db,
               "SELECT id,holderKey FROM assignments WHERE subject LIKE 'smoke fanout %'")
    assert {:ok, [[^dispatch_holder, dispatch_prompt]]} =
             DB.query(ctx.db,
               "SELECT sessionKey,prompt FROM turns WHERE assignmentId=?1",
               [dispatch_id])
    assert dispatch_prompt =~ "ship the smoke feature"

    # The topology verdict also notifies its opener through ordinary delivery.
    # Account for that actual turn by exact authored attest provenance instead
    # of relaxing a global count or treating it as another dispatch.
    assert {:ok, [[notice_carrier, notice_assignment]]} =
             DB.query(ctx.db,
               "SELECT wakeId,assignmentId FROM turns WHERE assignmentId IS NOT NULL AND assignmentId<>?1",
               [dispatch_id])
    assert %{state: "fired", digest: true} = Tightbeam.Wakes.get(ctx.db, notice_carrier)
    assert {:ok, notices} =
             DB.query(ctx.db, """
             SELECT source.wakeId,source.prompt
             FROM notice_batches batch
             JOIN notice_batch_members member ON member.batchId=batch.batchId AND member.state='included'
             JOIN wakes source ON source.wakeId=member.sourceWakeId
             JOIN attests attest ON attest.assignmentId=source.assignmentId
               AND source.origin='agent:'||attest.bySession
               AND source.prompt='Attest '||attest.id||' ('||attest.kind||') was filed on assignment '||attest.assignmentId||'.'
             WHERE batch.deliveryWakeId=?1 AND source.assignmentId=?2 AND batch.state='delivered'
             """, [notice_carrier, notice_assignment])
    refute notices == []
    for [source_id, raw_notice] <- notices do
      assert Tightbeam.Wakes.get(ctx.db, source_id).prompt == raw_notice
      assert Tightbeam.Wakes.get(ctx.db, source_id).state == "fired"
      assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [source_id])
    end
    notice_count = length(notices)
    assert {:ok, [[^notice_count]]} =
             DB.query(ctx.db,
               "SELECT COUNT(*) FROM notice_batch_members member JOIN notice_batches batch ON batch.batchId=member.batchId WHERE batch.deliveryWakeId=?1 AND member.state='included'",
               [notice_carrier])
  end

  test "scripted review refuses changed source, wrong commit bytes, and false output", ctx do
    check = Driver.seed_verifiable_work!(ctx.state, "review-negative", "review-negative")
    assert Tightbeam.FeatureSmokeTopology.review_check!(check) =~ "no provider review"
    File.write!(check.path, "#!/bin/sh\nexit 1\n")

    assert_raise RuntimeError, ~r/source changed/, fn ->
      Tightbeam.FeatureSmokeTopology.review_check!(check)
    end

    assert_raise RuntimeError, ~r/source differs from the named commit/, fn ->
      Tightbeam.FeatureSmokeTopology.review_check!(%{check | source: File.read!(check.path)})
    end

    File.write!(check.path, check.source)

    assert_raise RuntimeError, ~r/execution disagrees/, fn ->
      Tightbeam.FeatureSmokeTopology.review_check!(%{check | output: "invented output"})
    end
  end

  test "effort fixture reaches queued dispatch but cannot claim provider-free execution", ctx do
    previous = Application.get_env(:tightbeam, :effort_checkin_horizon_ms)
    Application.put_env(:tightbeam, :effort_checkin_horizon_ms, 2_500)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tightbeam, :effort_checkin_horizon_ms, previous),
        else: Application.delete_env(:tightbeam, :effort_checkin_horizon_ms)
    end)

    start_supervised!(
      {Tightbeam.Supervision,
       db: ctx.db,
       handlers: ctx.handlers,
       sweep_ms: 25,
       prod_limit: 3,
       name: Tightbeam.Supervision}
    )

    # The real dispatch leaves a turn queued. Without a lane/provider it cannot
    # become idle execution evidence. Keep the driver's refusal and name that
    # boundary instead of fabricating a reply or terminalizing the turn by SQL.
    ExUnit.CaptureIO.capture_io(fn ->
      assert_raise Tightbeam.FeatureSmokeDriverFixture.Failure, ~r/effort smoke timed out/, fn ->
        Driver.check_effort_without_effect(ctx.state)
      end
    end)

    assert {:ok, [["open", nil, "queued"]]} =
             DB.query(ctx.db, """
             SELECT a.state,a.outcome,t.status FROM assignments a JOIN turns t ON t.assignmentId=a.id
             WHERE a.subject LIKE 'effort smoke%'
             """)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM decision_requests WHERE kind='effort'"
             )
  end

  for profile <- [:installed, :published] do
    @tag profile: profile
    test "real gate chain reaches completed with #{profile} review remedy and immutable receipts",
         ctx do
      if ctx.profile == :published do
        # Current packaged completion is an accountable wake, not automatic staffing.
        # Keep all additional installed posture/test-receipt rules loaded as well.
        installed = File.read!(Path.join(ctx.base, "identity/rules/engineering.toml"))
        [_completion, rest] = String.split(installed, "# Re-entry twin", parts: 2)

        File.write!(
          Path.join(ctx.base, "identity/rules/engineering.toml"),
          File.read!("priv/kungfu/agentic-engineering/rules/engineering.toml") <>
            "\n# Re-entry twin" <> rest
        )

        Rules.load!(ctx.base, Map.keys(ctx.handlers))
      end

      wi = Driver.ok!(ctx.state, "work-item-create", %{"title" => "gate-chain dry check"})["id"]

      holder =
        Driver.open_grounded_assignment!(
          ctx.state,
          "dry-#{ctx.profile}",
          wi,
          "gate dry check",
          "g"
        )

      reviewer =
        Driver.ok!(ctx.state, "spawn", %{
          "archetype" => "reviewer-code",
          "workItemId" => wi,
          "displayName" => "dry reviewer",
          "idempotencyKey" => "reviewer-#{wi}"
        })

      key = get_in(reviewer, ["stream", "sessionKey"]) || reviewer["sessionKey"]
      Roles.create!(ctx.db, "reviewer-code", "mike", key)

      ExUnit.CaptureIO.capture_io(fn ->
        Driver.gate_chain_enforced(
          ctx.state,
          "dry-#{ctx.profile}",
          ctx.state.leg,
          reviewer,
          key,
          wi,
          holder
        )
      end)

      assert {:ok, [["completed", commit_refs]]} =
               DB.query(
                 ctx.db,
                 """
                 SELECT s.outcome,a.commitRefs FROM assignments s JOIN attests a ON a.assignmentId=s.id
                 WHERE s.workItemId=?1 AND a.kind='completion'
                 """,
                 [wi]
               )

      assert [%{"commit" => commit, "repo" => "testhost:" <> repo}] = JSON.decode!(commit_refs)
      assert byte_size(commit) == 40
      # Retirement may release the workspace, so the durable receipts are the final proof.
      assert is_binary(repo)

      assert {:ok, [[3]]} =
               DB.query(
                 ctx.db,
                 "SELECT count(*) FROM attests a JOIN assignments s ON s.id=a.assignmentId WHERE s.workItemId=?1 AND a.commitRefs=?2",
                 [wi, commit_refs]
               )
    end
  end
end
