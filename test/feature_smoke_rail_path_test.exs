defmodule Tightbeam.FeatureSmokeRailPathTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Archetypes,
    DB,
    Gateway,
    Ledger,
    Model,
    ModelCatalog,
    NoticeBatcher,
    Org,
    Roles,
    Rules,
    Schema
  }

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
      user_id: Org.get(db, Org.personal_session_key("mike")).owner_user_id,
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
             DB.query(
               ctx.db,
               "SELECT id,holderKey FROM assignments WHERE subject LIKE 'smoke fanout %'"
             )

    owner_id = ctx.state.user_id
    assert Org.get(ctx.db, dispatch_holder).owner_user_id == owner_id

    assert {:ok, [[revocation_id, terminal_at, dispatch_work_item, ^owner_id]]} =
             DB.query(
               ctx.db,
               """
               SELECT revocation.id,revocation.revokedAt,assignment.workItemId,assignment.openedByUser
               FROM assignments assignment
               JOIN assignment_revocation_generations generation ON generation.assignmentId=assignment.id
                 AND generation.reopeningId IS (
                   SELECT MAX(id) FROM assignment_reopenings WHERE assignmentId=assignment.id)
               JOIN assignment_revocations revocation ON revocation.id=generation.revocationId
                 AND revocation.assignmentId=assignment.id AND revocation.revokedAt=assignment.closedAt
                 AND revocation.revokedByUser IS assignment.closedByUser
                 AND revocation.revokedBySession IS assignment.closedBySession
                 AND revocation.revokedByProcess IS assignment.closedByProcess
               WHERE assignment.id=?1 AND assignment.holderKey=?2
                 AND assignment.state='closed' AND assignment.outcome='revoked'
                 AND assignment.openedBySession IS NULL AND revocation.reason='holder session retired'
               """,
               [dispatch_id, dispatch_holder]
             )

    assert {:ok, [[owner_session, ^owner_id, "retired"]]} =
             DB.query(
               ctx.db,
               """
               SELECT work_item.deliveryOwnerSessionKey,recipient.ownerUserId,recipient.state
               FROM work_items work_item
               JOIN sessions recipient ON recipient.sessionKey=work_item.deliveryOwnerSessionKey
               WHERE work_item.id=?1
               """,
               [dispatch_work_item]
             )

    assert {:ok, %{wake_id: terminal_source, prompt: terminal_raw}} =
             Tightbeam.Wakes.terminal_notification(%{
               source_kind: "assignment_revocation",
               source_token: revocation_id,
               assignment_id: dispatch_id,
               work_item_id: dispatch_work_item,
               child_session_key: dispatch_holder,
               owner_user_id: owner_id,
               opened_by_kind: "user",
               opened_by_id: owner_id,
               outcome: "revoked",
               terminal_at: terminal_at
             })

    # The script retires both the holder and its accountable owner. Admission
    # before owner retirement leaves immutable delivery; retirement first must
    # leave a typed cancellation, never invented fired history.
    NoticeBatcher.recover(ctx.db)

    assert {:ok, [[dispatch_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT prompt FROM turns WHERE assignmentId=?1 AND sessionKey=?2",
               [dispatch_id, dispatch_holder]
             )

    assert dispatch_prompt ==
             "[from user:#{owner_id}]\n\n[assignment: #{dispatch_id}]\n\nship the smoke feature"

    terminal = Tightbeam.Wakes.get(ctx.db, terminal_source)

    assert %{
             session_key: ^owner_session,
             prompt: ^terminal_raw,
             origin: "process:tightbeam",
             consumer: "prompt",
             assignment_id: ^dispatch_id,
             work_item_id: ^dispatch_work_item,
             creator_session_key: ^dispatch_holder,
             owner_user_id: ^owner_id
           } = terminal

    assert terminal.obligation_ref ==
             "terminal-child-owner-notification:" <> dispatch_id

    case terminal.state do
      "fired" ->
        assert {:ok,
                [
                  [
                    terminal_carrier,
                    ^owner_session,
                    terminal_prompt,
                    terminal_envelope,
                    terminal_hash
                  ]
                ]} =
                 DB.query(
                   ctx.db,
                   """
                   SELECT turn.wakeId,turn.sessionKey,turn.prompt,
                     batch.envelope,batch.envelopeSha256
                   FROM (#{NoticeBatcher.source_deliveries_sql()}) delivery
                   JOIN turns turn ON turn.seq=delivery.turnSeq AND turn.origin='process:tightbeam'
                   JOIN messages message ON message.id=turn.messageId
                     AND message.sender=turn.origin AND message.content=turn.prompt
                   JOIN notice_batches batch ON batch.deliveryWakeId=turn.wakeId AND batch.state='delivered'
                   WHERE delivery.sourceWakeId=?1 AND delivery.assignmentId=?2 AND delivery.carrier=1
                   """,
                   [terminal_source, dispatch_id]
                 )

        assert %{state: "fired", digest: true, prompt: ^terminal_envelope} =
                 Tightbeam.Wakes.get(ctx.db, terminal_carrier)

        assert terminal_carrier != terminal_source

        assert terminal_prompt ==
                 Gateway.decorate_delivery_prompt(terminal_envelope, "process:tightbeam")

        assert terminal_envelope =~ terminal_raw

        assert terminal_hash ==
                 Base.encode16(:crypto.hash(:sha256, terminal_envelope), case: :lower)

        assert {:ok, [[0]]} =
                 DB.query(ctx.db, "SELECT count(*) FROM wake_cancellations WHERE wakeId=?1", [
                   terminal_source
                 ])

      "canceled" ->
        assert terminal.fired_at == nil
        assert terminal.fired_by == nil
        canceled_at = terminal.canceled_at
        assert is_integer(canceled_at)

        assert {:ok,
                [
                  [
                    ^canceled_at,
                    "process",
                    "tightbeam:retirement",
                    "target_retired",
                    "session_transition",
                    ^owner_session,
                    "no_replacement",
                    nil,
                    nil,
                    nil,
                    "work_item",
                    ^dispatch_work_item,
                    "linked_work_open",
                    "routing_bracket",
                    ^dispatch_work_item,
                    1
                  ]
                ]} =
                 DB.query(
                   ctx.db,
                   """
                   SELECT canceledAt,requesterKind,requesterId,reasonKind,
                     causalSourceKind,causalSourceId,outcomeKind,replacementWakeId,
                     dispositionKind,dispositionId,primaryWorkKind,primaryWorkId,
                     workImpactKind,livenessTriggerKind,livenessTriggerId,actionNeeded
                   FROM wake_cancellations WHERE wakeId=?1 AND wakeState='canceled'
                   """,
                   [terminal_source]
                 )

        assert {:ok, [[0]]} =
                 DB.query(
                   ctx.db,
                   "SELECT count(*) FROM (#{NoticeBatcher.source_deliveries_sql()}) WHERE sourceWakeId=?1",
                   [terminal_source]
                 )

        assert {:ok, [[0]]} =
                 DB.query(ctx.db, "SELECT count(*) FROM turns WHERE wakeId=?1", [terminal_source])
    end

    # Detailed member corruption/replay/privacy checks belong to the focused
    # notice fixtures; this script proves one brief and its required owner notice.
    assert {:ok, coordination_rows} =
             DB.query(ctx.db, """
             SELECT a.id,a.subject,a.openedByUser,a.openedBySession
             FROM assignments a JOIN assignment_effects effect ON effect.assignmentId=a.id
             WHERE effect.effectKind='coordination'
             """)

    expected_subjects =
      Enum.map(
        [
          "One default-archetype selection probe",
          "One holder for assignment-get round-trip and not-found checks",
          "One holder for atomic dispatch and work-item linkage checks"
        ],
        &("Coordinate disposable smoke fixture: " <> &1)
      )

    assert Enum.sort(Enum.map(coordination_rows, fn [_, subject, _, _] -> subject end)) ==
             Enum.sort(expected_subjects)

    for [_, _, opener, opened_by_session] <- coordination_rows do
      assert opener == ctx.state.user_id
      assert opened_by_session == nil
    end
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

    # Drain only the preparatory rumination through the real claim/terminal
    # seams, explicitly canceled as fixture setup. No provider reply or model
    # execution is fabricated. The subsequent holder dispatch stays queued.
    rumination =
      Task.async(fn ->
        drain_effort_rumination!(ctx.db, System.monotonic_time(:millisecond) + 10_000)
      end)

    ExUnit.CaptureIO.capture_io(fn ->
      assert_raise Tightbeam.FeatureSmokeDriverFixture.Failure, ~r/effort smoke timed out/, fn ->
        Driver.check_effort_without_effect(ctx.state)
      end
    end)

    {source, carrier, seq} = Task.await(rumination, 1_000)
    refute source == carrier
    assert Tightbeam.Wakes.get(ctx.db, source).state == "fired"

    assert {:ok, [["canceled"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [seq])

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               """
               SELECT count(*) FROM turn_lifecycle_events
               WHERE turnSeq=?1 AND kind='terminal_committed' AND outcome='canceled'
               """,
               [seq]
             )

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

  defp drain_effort_rumination!(db, deadline) do
    assert {:ok, rows} =
             DB.query(db, """
             SELECT source.wakeId,source.sessionKey,t.seq,t.wakeId
             FROM wakes source JOIN sessions s ON s.sessionKey=source.sessionKey
             JOIN (#{NoticeBatcher.source_deliveries_sql()}) d ON d.sourceWakeId=source.wakeId
             JOIN turns t ON t.seq=d.turnSeq
             WHERE source.rumination=1 AND source.state='fired' AND d.carrier=1
               AND s.displayName LIKE 'smoke-effort-parent-%' AND t.status='queued'
             """)

    case rows do
      [[source, recipient, seq, carrier]] ->
        assert {:ok, turn} = Ledger.claim_next(db, recipient, "fixture-rumination-drain")
        assert turn.seq == seq
        assert turn.wake_id == carrier
        refute carrier == source

        assert :ok =
                 Ledger.finish(db, seq, "canceled", "provider-free fixture preparation only",
                   owner_lease: turn.owner_lease
                 )

        {source, carrier, seq}

      [] ->
        assert System.monotonic_time(:millisecond) < deadline,
               "actual effort rumination carrier was not admitted"

        Process.sleep(10)
        drain_effort_rumination!(db, deadline)
    end
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

        # The fixture's rest already carries the posture gate the shipped file
        # ends with; take only the shipped completion rule.
        [shipped_completion | _] =
          String.split(
            File.read!("priv/kungfu/agentic-engineering/rules/engineering.toml"),
            "\n# Posture gate",
            parts: 2
          )

        File.write!(
          Path.join(ctx.base, "identity/rules/engineering.toml"),
          shipped_completion <> "\n# Re-entry twin" <> rest
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
