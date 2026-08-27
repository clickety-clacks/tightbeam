defmodule Tightbeam.CliIntegrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  @moduletag :cli_integration

  alias Tightbeam.{
    Assets,
    Archetypes,
    Assignments,
    CliCompatibility,
    ConditionFacts,
    DB,
    Devices,
    Escalation,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Projection,
    RailRemedy,
    Rails,
    Roles,
    Rules,
    Wakes,
    WorkItems,
    WorkState
  }

  alias Tightbeam.Wire.Router

  setup do
    binary = Path.expand("../cli/target/release/tightbeam", __DIR__)

    unless File.exists?(binary) do
      raise "CLI integration binary missing: #{binary}; run cargo build --release in cli/"
    end

    db = :"cli_integration_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-cli-integration-#{System.unique_integer([:positive])}"
      )

    workdir = Path.join(base_dir, "work/session/nested")
    outside = Path.join(base_dir, "outside")
    File.mkdir_p!(workdir)
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    # Delegate to the ONE canonical schema list. A hand-kept copy here is how
    # this test ran without one of the schema modules: three lists had to agree and
    # did not.
    :ok = Tightbeam.Schema.ensure_all(db)

    register_hosts(db, %{"testhost" => %{ssh: nil, base_dir: base_dir, cli_bin: nil}})

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)"
      )

    session =
      Org.create(db, %{
        session_key: "cli-holder",
        display_name: "CLI Holder",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    Roles.create!(db, "cli-holder", "flynn", session.session_key)

    worker =
      Org.create(db, %{
        session_key: "cli-worker",
        display_name: "CLI Worker",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    Roles.create!(db, "cli-worker", "flynn", worker.session_key)

    gateway_config = %{
      db: db,
      base_dir: base_dir,
      cwd: base_dir,
      wake_tick_ms: 1_000
    }

    Archetypes.load!(base_dir)
    real_handlers = Gateway.handlers(gateway_config)
    Rules.load!(base_dir, Map.keys(real_handlers))
    test_pid = self()

    handlers =
      Map.new(real_handlers, fn
        {"tune", _handler} ->
          {"tune",
           fn call ->
             send(test_pid, {:cli_call, call})
             %{ok: false, code: "same_harness", message: "omit --harness"}
           end}

        {verb, handler} ->
          {verb,
           fn call ->
             send(test_pid, {:cli_call, call})
             handler.(call)
           end}
      end)

    router_opts =
      Router.init(
        db: db,
        base_dir: base_dir,
        handlers: handlers,
        cli_token: "tbc_cli_integration",
        session_status: fn _ -> nil end
      )

    bandit =
      start_supervised!(
        {Bandit, plug: {Router, router_opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    File.write!(
      Path.join(base_dir, "work/session/.tightbeam-session"),
      JSON.encode!(%{
        url: "http://127.0.0.1:#{port}",
        token: session.cli_token,
        sessionKey: session.session_key
      })
    )

    %{
      base_dir: base_dir,
      binary: binary,
      db: db,
      handlers: handlers,
      port: port,
      session: session,
      worker: worker,
      workdir: workdir,
      outside: outside
    }
  end

  test "real CLI states its built version when it connects", ctx do
    {version, 0} = System.cmd(ctx.binary, ["version"])
    version = String.trim(version)

    {listed, 0} = System.cmd(ctx.binary, ["list"], cd: ctx.workdir, stderr_to_stdout: true)

    assert version != ""
    assert listed =~ "cli-holder"
    assert_receive {:cli_call, %{verb: "inspect"}}
  end

  test "real CLI build is the exact gateway-required version", ctx do
    {version, 0} = System.cmd(ctx.binary, ["version"])
    version = String.trim(version)

    assert version == CliCompatibility.required_version()
  end

  test "real tune CLI uses session identity, typed fields, and structured refusals", ctx do
    {output, 1} =
      System.cmd(
        ctx.binary,
        [
          "tune",
          "--session",
          ctx.worker.session_key,
          "--harness",
          "claude",
          "--model",
          "fable"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert String.starts_with?(output, "{"), output
    assert %{"code" => "same_harness", "ok" => false} = JSON.decode!(output)

    assert_receive {:cli_call,
                    %{
                      verb: "tune",
                      origin: "agent:cli-holder",
                      session_key: "cli-worker",
                      params: %{setting: "set_harness", harness: "claude", model: "fable"}
                    }}

    {_effort, 1} =
      System.cmd(
        ctx.binary,
        ["tune", "--session", ctx.worker.session_key, "--effort", "high"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert_receive {:cli_call,
                    %{
                      verb: "tune",
                      session_key: "cli-worker",
                      params: %{setting: "set_reasoning", reasoningLevel: "high"}
                    }}

    {_fast, 1} =
      System.cmd(
        ctx.binary,
        ["tune", "--session", ctx.worker.session_key, "--fast", "on"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert_receive {:cli_call,
                    %{
                      verb: "tune",
                      session_key: "cli-worker",
                      params: %{setting: "set_fast_mode", fastMode: "on"}
                    }}

    {usage, 1} =
      System.cmd(
        ctx.binary,
        ["tune", "--session", ctx.worker.session_key, "--fast", "on", "--effort", "high"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert usage =~ "--fast is mutually exclusive"
    refute_receive {:cli_call, %{verb: "tune"}}
  end

  test "version refusal is distinguishable from auth and network failures", ctx do
    session_file = Path.join(ctx.base_dir, "work/session/.tightbeam-session")

    File.write!(
      session_file,
      JSON.encode!(%{
        url: "http://127.0.0.1:#{ctx.port}",
        token: "wrong-token",
        sessionKey: ctx.session.session_key
      })
    )

    {auth, 1} = System.cmd(ctx.binary, ["list"], cd: ctx.workdir, stderr_to_stdout: true)
    assert auth =~ "auth_failed"
    refute auth =~ "incompatible_cli"

    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_address, unused_port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    File.write!(
      session_file,
      JSON.encode!(%{
        url: "http://127.0.0.1:#{unused_port}",
        token: ctx.session.cli_token,
        sessionKey: ctx.session.session_key
      })
    )

    {network, 1} = System.cmd(ctx.binary, ["list"], cd: ctx.workdir, stderr_to_stdout: true)
    refute network =~ "auth_failed"
    refute network =~ "incompatible_cli"
    assert network =~ "Connection refused" or network =~ "connection refused"
  end

  test "real CLI discovers a session token, dispatches, and loses access at retire", ctx do
    {listed, 0} = System.cmd(ctx.binary, ["list"], cd: ctx.workdir, stderr_to_stdout: true)
    assert listed =~ "cli-holder"
    assert_receive {:cli_call, %{origin: "agent:cli-holder", principal: {:session, "cli-holder"}}}

    {outside, 1} =
      System.cmd(ctx.binary, ["list"], cd: ctx.outside, stderr_to_stdout: true)

    assert outside =~ "identity required"
    assert outside =~ ".tightbeam-session"
    assert outside =~ ctx.outside

    {woken, 0} =
      System.cmd(
        ctx.binary,
        ["wake", "--session", "cli-holder", "--prompt", "hello", "--after", "1h"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert woken =~ "\"wakeId\": \"w_"

    assert_receive {:cli_call,
                    %{
                      verb: "wake",
                      origin: "agent:cli-holder",
                      principal: {:session, "cli-holder"},
                      params: %{after_ms: 3_600_000}
                    }}

    {_listed_as_owner, 0} =
      System.cmd(ctx.binary, ["list", "--as-user", "flynn"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert_receive {:cli_call, %{origin: "user:flynn", principal: {:user, "flynn"}}}

    Org.retire(ctx.db, ctx.session.session_key, "user:flynn", 1_000)
    {refused, 1} = System.cmd(ctx.binary, ["list"], cd: ctx.workdir, stderr_to_stdout: true)
    assert refused =~ "auth_failed"
  end

  test "session-auth --as-user attributes verdicts to the user and grants admin revocation",
       ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('other', 0, 1)"
      )

    other =
      Org.create(ctx.db, %{
        session_key: "cli-other",
        display_name: "CLI Other",
        owner_user_id: "other",
        origin: "user:other",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    Roles.create!(ctx.db, "cli-other", "other", other.session_key)
    other_dir = session_workdir!(ctx, other)

    {assigned, 0} =
      System.cmd(
        ctx.binary,
        ["assign", "--subject", "admin revocation", "--session", "cli-worker"],
        cd: other_dir,
        stderr_to_stdout: true
      )

    assignment_id = JSON.decode!(assigned)["id"]

    assert_receive {:cli_call,
                    %{
                      verb: "assign",
                      principal: {:session, "cli-other"},
                      session_key: "cli-worker"
                    }}

    {verdicted, 0} =
      System.cmd(
        ctx.binary,
        [
          "attest",
          assignment_id,
          "--kind",
          "verdict",
          "--verdict",
          "tests-passed",
          "--as-user",
          "flynn"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert verdicted =~ "tests-passed"

    assert_receive {:cli_call,
                    %{
                      verb: "attest",
                      origin: "user:flynn",
                      principal: {:user, "flynn"}
                    }}

    assert {:ok, [["flynn", nil]]} =
             DB.query(
               ctx.db,
               "SELECT byUser, bySession FROM attests WHERE assignmentId = ?1 AND verdictKind = 'tests-passed'",
               [assignment_id]
             )

    {revoked, 0} =
      System.cmd(
        ctx.binary,
        ["revoke-assignment", assignment_id, "--as-user", "flynn"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert revoked =~ "revoked"

    assert_receive {:cli_call,
                    %{
                      verb: "revoke-assignment",
                      origin: "user:flynn",
                      principal: {:user, "flynn"}
                    }}

    assert {:ok, [["closed", "revoked"]]} =
             DB.query(ctx.db, "SELECT state, outcome FROM assignments WHERE id = ?1", [
               assignment_id
             ])
  end

  test "real CLI round-trips assign, dispatch, and attest through gateway handlers", ctx do
    {assigned, 0} =
      System.cmd(
        ctx.binary,
        [
          "assign",
          "--subject",
          "ship",
          "--session",
          "cli-holder",
          "--key",
          "assign-cli"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assignment_id = JSON.decode!(assigned)["id"]
    assert "asg_" <> _ = assignment_id

    assert_receive {:cli_call,
                    %{
                      verb: "assign",
                      session_key: "cli-holder",
                      params: %{
                        subject: "ship",
                        idempotency_key: "assign-cli"
                      }
                    }}

    {dispatched, 0} =
      System.cmd(
        ctx.binary,
        [
          "dispatch",
          "--holder",
          "cli-worker",
          "--subject",
          "investigate",
          "--brief",
          "Investigate the restored CLI path.",
          "--key",
          "dispatch-cli"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    dispatch_id = JSON.decode!(dispatched)["id"]
    assert "asg_" <> _ = dispatch_id

    assert_receive {:cli_call,
                    %{
                      verb: "dispatch",
                      session_key: "cli-worker",
                      principal: {:session, "cli-holder"},
                      params: %{
                        subject: "investigate",
                        brief: "Investigate the restored CLI path.",
                        idempotency_key: "dispatch-cli"
                      }
                    }}

    {attested, 0} =
      System.cmd(ctx.binary, ["attest", assignment_id, "--kind", "completion", "--note", "ready"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert attested =~ "completion"

    assert_receive {:cli_call,
                    %{
                      verb: "attest",
                      params: %{
                        assignment_id: ^assignment_id,
                        kind: "completion",
                        note: "ready"
                      }
                    }}

    {attests, 0} =
      System.cmd(ctx.binary, ["attests", assignment_id],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert attests =~ assignment_id
    assert_receive {:cli_call, %{verb: "attests", params: %{assignment_id: ^assignment_id}}}

    {verdicted, 0} =
      System.cmd(
        ctx.binary,
        ["attest", dispatch_id, "--kind", "verdict", "--verdict", "tests-passed"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert verdicted =~ "tests-passed"

    assert_receive {:cli_call,
                    %{
                      verb: "attest",
                      params: %{
                        assignment_id: ^dispatch_id,
                        kind: "verdict",
                        verdict_kind: "tests-passed"
                      }
                    }}

    {revoked, 0} =
      System.cmd(ctx.binary, ["revoke-assignment", dispatch_id],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert revoked =~ "revoked"

    assert_receive {:cli_call,
                    %{verb: "revoke-assignment", params: %{assignment_id: ^dispatch_id}}}

    {listed, 0} =
      System.cmd(ctx.binary, ["assignments", "--session", "cli-worker", "--state", "all"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert listed =~ dispatch_id

    assert_receive {:cli_call,
                    %{
                      verb: "assignments",
                      session_key: "cli-worker",
                      params: %{state: "all"}
                    }}
  end

  # verification-papertrail-v1 A7 (macOS half): A1/A2 walked end to end through
  # the real Bandit/Router stack and the real release CLI, against the shipped
  # statutes exactly as relearn delivers them.
  #
  # EVERY hop is the CLI now — work item, coder assignment, the review link, the
  # review verdict, both denials, both wakes, the verification verdict, the
  # report artifact, and the final completion. The two that used to be carved out
  # are both closed: the artifact, because artifact-record refused over the wire
  # for want of a firing messages.id until the carrier ruling made it fail open;
  # and the review link, because `--reviews` reached the handler under a name no
  # handler read until the router learned to alias it (#112).
  test "real CLI walks the verification papertrail end to end (A1/A2)", ctx do
    # A real bundle import, not a fixture copy: under neutral-seed-v1 the org
    # is born empty and the bundle arrives ONLY by an explicit learn — so this
    # walk now exercises that real arrival path, and fails if learn stops
    # delivering rules/.
    assert :initialized = Archetypes.init_identity!(ctx.base_dir)

    assert {:ok, _revision} =
             Tightbeam.Identity.learn!(ctx.base_dir, "agentic-engineering", "operator")

    Archetypes.load!(ctx.base_dir)

    for file <- ["engineering.toml", "verification.toml"] do
      assert File.exists?(Path.join([ctx.base_dir, "identity", "rules", file])),
             "learn did not deliver rules/#{file} into the org's identity tree"
    end

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    test_pid = self()

    start_supervised!(
      {Wakes,
       db: ctx.db,
       deliver: fn wake ->
         send(test_pid, {:wake_delivered, wake})
         true
       end,
       tick_ms: 60_000,
       name: Tightbeam.WakeScheduler}
    )

    coder =
      Org.create(ctx.db, %{
        session_key: "cli-coder",
        display_name: "CLI Coder",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    reviewer =
      Org.create(ctx.db, %{
        session_key: "cli-reviewer",
        display_name: "CLI Reviewer",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "reviewer",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: Model.new("test")
      })

    Roles.create!(ctx.db, "cli-coder", "flynn", coder.session_key)
    Roles.create!(ctx.db, "cli-reviewer", "flynn", reviewer.session_key)
    coder_dir = session_workdir!(ctx, coder)
    reviewer_dir = session_workdir!(ctx, reviewer)

    {created, 0} =
      System.cmd(
        ctx.binary,
        ["work-item-create", "--title", "papertrail e2e", "--as-user", "flynn"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    item_id = JSON.decode!(created)["id"]

    {assigned, 0} =
      System.cmd(
        ctx.binary,
        [
          "assign",
          "--subject",
          "implement the feature",
          "--session",
          "cli-coder",
          "--work-item",
          item_id,
          "--as-user",
          "flynn"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    work_id = JSON.decode!(assigned)["id"]

    repo = Path.expand("..", __DIR__)
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)

    {_receipt, 0} =
      System.cmd(
        ctx.binary,
        [
          "attest",
          work_id,
          "--kind",
          "verdict",
          "--verdict",
          "tests-passed",
          "--note",
          "#{Tightbeam.Placement.local_host_name()}:#{repo} #{String.trim(commit)}; " <>
            "mise exec -- mix test test/cli_integration_test.exs; passed"
        ],
        cd: coder_dir,
        stderr_to_stdout: true
      )

    # The review link, through the real CLI. This was the last hop that was not:
    # `--reviews` reached the handler as the wire word `reviews`, which no
    # handler reads, so a CLI-created review link was silently dropped (#112).
    # The router aliases it to `:reviews_assignment_id` now, so the bypass that
    # stood in for it is gone.
    {reviewed, 0} =
      System.cmd(
        ctx.binary,
        [
          "assign",
          "--subject",
          "review of the feature",
          "--session",
          "cli-reviewer",
          "--work-item",
          item_id,
          "--reviews",
          work_id,
          "--as-user",
          "flynn"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    # The link is what the CLI is on trial for here: an assignment that came back
    # without it would still parse, and would still be a silently dropped edge.
    assert_receive {:cli_call, %{verb: "assign", params: %{reviews_assignment_id: ^work_id}}}

    review_id = JSON.decode!(reviewed)["id"]

    {_verdict, 0} =
      System.cmd(
        ctx.binary,
        ["attest", review_id, "--kind", "verdict", "--verdict", "reviewed-clean"],
        cd: reviewer_dir,
        stderr_to_stdout: true
      )

    # A1 first denial: the completion is refused and the wake names the
    # missing verification verdict.
    {denied, denied_status} =
      System.cmd(ctx.binary, ["attest", work_id, "--kind", "completion"],
        cd: coder_dir,
        stderr_to_stdout: true
      )

    assert denied_status != 0
    assert denied =~ "completion-requires-verification"

    assert %{status: "live"} =
             RailRemedy.episode(ctx.db, "completion-requires-verification", work_id)

    assert_receive {:wake_delivered, verification_wake}, 5_000
    assert verification_wake.session_key == "cli-coder"
    assert verification_wake.prompt =~ "no verification verdict is filed"
    assert verification_wake.prompt =~ work_id

    {_verified, 0} =
      System.cmd(
        ctx.binary,
        ["attest", work_id, "--kind", "verdict", "--verdict", "verified"],
        cd: coder_dir,
        stderr_to_stdout: true
      )

    # A1 second denial: the artifact statute prods next, naming its own record.
    {denied_again, denied_again_status} =
      System.cmd(ctx.binary, ["attest", work_id, "--kind", "completion"],
        cd: coder_dir,
        stderr_to_stdout: true
      )

    assert denied_again_status != 0
    assert denied_again =~ "completion-requires-results-artifact"
    assert_receive {:wake_delivered, artifact_wake}, 5_000
    assert artifact_wake.prompt =~ "no artifact is recorded on its work item"

    # The report artifact, through the REAL CLI. This hop used to call the
    # handler directly with a `recorded_message_id` no wire client can send,
    # because over the wire the verb refused unconditionally — so the suite drove
    # a path that did not exist and the live defect stayed invisible to it.
    #
    # The whole chain runs here: the substrate-reserved PreToolUse hook fires
    # against a real tool-call payload, execs the real CLI, which posts to the
    # real gateway, which captures the turn that is running right now.
    {:appended, message} =
      Projection.append(ctx.db, %{
        session_key: "cli-coder",
        role: "user",
        content: "write up the verification results"
      })

    {:ok, _seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: "cli-coder",
        message_id: message.id,
        origin: "user:flynn",
        prompt: "write up the verification results"
      })

    {:ok, _turn} = Ledger.claim_next(ctx.db, "cli-coder", "cli-integration")

    assert fire_observation_hook(
             ctx,
             coder_dir,
             "tightbeam artifact-record --kind report --title 'verification results'"
           ) == 0

    {recorded, 0} =
      System.cmd(
        ctx.binary,
        [
          "artifact-record",
          "--kind",
          "report",
          "--title",
          "verification results",
          "--path",
          "results.txt",
          "--work-item",
          item_id
        ],
        cd: coder_dir,
        stderr_to_stdout: true
      )

    recorded = JSON.decode!(recorded)
    assert recorded["recordedMessageId"] == message.id
    assert recorded["recordedTurnEvidence"] == "tool-call-observed"

    # A2: the papertrail stands — the completion passes and the episodes close.
    {completed, 0} =
      System.cmd(ctx.binary, ["attest", work_id, "--kind", "completion"],
        cd: coder_dir,
        stderr_to_stdout: true
      )

    assert completed =~ "closed"

    assert {:ok, [["closed", "completed"]]} =
             DB.query(ctx.db, "SELECT state, outcome FROM assignments WHERE id = ?1", [work_id])

    assert %{status: "closed"} =
             RailRemedy.episode(ctx.db, "completion-requires-verification", work_id)

    assert %{status: "closed"} =
             RailRemedy.episode(ctx.db, "completion-requires-results-artifact", work_id)
  end

  # verification-papertrail-v1 A7 x A5 (macOS half): an org with no learned
  # statutes completes bare through the real CLI — no denial, no episode, no
  # remedy wake.
  test "real CLI bare completion passes on a rule-free org (A5)", ctx do
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    coder =
      Org.create(ctx.db, %{
        session_key: "cli-neutral-coder",
        display_name: "Neutral Coder",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    Roles.create!(ctx.db, coder.session_key, "flynn", coder.session_key)
    coder_dir = session_workdir!(ctx, coder)

    {created, 0} =
      System.cmd(
        ctx.binary,
        ["work-item-create", "--title", "neutral e2e", "--as-user", "flynn"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    item_id = JSON.decode!(created)["id"]

    {assigned, 0} =
      System.cmd(
        ctx.binary,
        [
          "assign",
          "--subject",
          "neutral bare completion",
          "--session",
          coder.session_key,
          "--work-item",
          item_id,
          "--as-user",
          "flynn"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    work_id = JSON.decode!(assigned)["id"]

    {completed, 0} =
      System.cmd(ctx.binary, ["attest", work_id, "--kind", "completion"],
        cd: coder_dir,
        stderr_to_stdout: true
      )

    assert completed =~ "closed"
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM rail_remedy_episodes", [])

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wakes WHERE origin LIKE 'remedy:%'",
               []
             )
  end

  # The other half of the hook contract, and the reason the papertrail test's
  # `tool-call-observed` means anything: without the hook the same record lands
  # `session-concurrent`, so the grep really is what separates the two classes.
  # It also pins the cost claim — a Bash call that is not an artifact-record must
  # exit before it ever reaches the gateway.
  test "the observation hook exits on every command that is not an artifact-record", ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES ('wi_hookgate', 'hook gate', 'flynn', 'flynn', 1)"
      )

    coder_dir = session_workdir!(ctx, ctx.session)

    {:appended, message} =
      Projection.append(ctx.db, %{
        session_key: ctx.session.session_key,
        role: "user",
        content: "build it"
      })

    {:ok, _seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.session.session_key,
        message_id: message.id,
        origin: "user:flynn",
        prompt: "build it"
      })

    {:ok, _turn} = Ledger.claim_next(ctx.db, ctx.session.session_key, "cli-integration")

    assert fire_observation_hook(ctx, coder_dir, "ls -la && make build") == 0

    {recorded, 0} =
      System.cmd(
        ctx.binary,
        [
          "artifact-record",
          "--kind",
          "report",
          "--title",
          "wrapped in a script",
          "--path",
          "out.txt",
          "--work-item",
          "wi_hookgate"
        ],
        cd: coder_dir,
        stderr_to_stdout: true
      )

    recorded = JSON.decode!(recorded)
    assert recorded["recordedMessageId"] == message.id
    assert recorded["recordedTurnEvidence"] == "session-concurrent"
  end

  # Runs the compiled hook EXACTLY as a harness runs it: the command string
  # `Rails.observation_entry/0` projects into settings.json / hooks.json, with a
  # real PreToolUse payload on stdin and the CLI reachable on PATH the way
  # placement puts it there. Nothing about the hook's shape is restated here — a
  # change to the grep or to the verb it execs has to survive this.
  defp fire_observation_hook(ctx, cwd, command_text) do
    %{"hooks" => [%{"command" => hook_command}]} = Rails.observation_entry()

    payload =
      JSON.encode!(%{
        "tool_name" => "Bash",
        "tool_input" => %{"command" => command_text}
      })

    payload_path = Path.join(cwd, "pre-tool-use.json")
    File.write!(payload_path, payload)

    {_output, status} =
      System.cmd("sh", ["-c", "cat #{payload_path} | #{hook_command}"],
        cd: cwd,
        stderr_to_stdout: true,
        env: [{"PATH", Path.dirname(ctx.binary) <> ":" <> System.get_env("PATH")}]
      )

    status
  end

  defp open_request?(db, id) do
    {:ok, rows} =
      DB.query(db, "SELECT 1 FROM decision_requests WHERE id = ?1 AND status = 'open'", [id])

    rows == [[1]]
  end

  defp session_workdir!(ctx, session) do
    dir = Path.join([ctx.base_dir, "work", session.session_key])
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, ".tightbeam-session"),
      JSON.encode!(%{
        url: "http://127.0.0.1:#{ctx.port}",
        token: session.cli_token,
        sessionKey: session.session_key
      })
    )

    dir
  end

  # Regression, found by smoke group 12. `Dispatch.dispatch/3` declares three
  # returns and the router's dispatch_response served two, so an escalating verb
  # reached `case` with no clause: CaseClauseError, an empty body from Bandit,
  # and the CLI dying on EOF. The EFFECT had already applied — the
  # decision-request opens and the handler does not run — so a test asserting on
  # the DB stayed green while every real caller of an escalating verb hard-failed.
  # That is why this one runs the REAL binary and asserts on what it PRINTS.
  test "real CLI renders an escalated verb as decision_pending instead of dying on EOF", ctx do
    {cli_version, 0} = System.cmd(ctx.binary, ["version"])
    cli_version = String.trim(cli_version)

    File.mkdir_p!(Path.join([ctx.base_dir, "identity", "rules"]))

    File.write!(
      Path.join([ctx.base_dir, "identity", "rules", "escalate.toml"]),
      """
      [[rule]]
      name = "assignments-need-a-ruling"
      verb = "assignments"
      text = "listing assignments is an owner decision in this fixture org"
      effect = "escalate"
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]
      """
    )

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    # THE WIRE CONTRACT ITSELF, off the real Bandit socket. Asserting only on what
    # the CLI printed would leave the router free to drift to a 200, or to a
    # 400 error envelope carrying the same three fields, with every test still
    # green — the rendered text is identical either way, and both drifts change
    # what a non-CLI client sees. So the status and the WHOLE envelope are pinned
    # here, exactly, rather than by substring.
    {:ok, {{_version, http_status, _reason}, _headers, raw_body}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{ctx.port}/agent/dispatch",
         [
           {~c"authorization", ~c"Bearer #{ctx.session.cli_token}"},
           {~c"x-tightbeam-cli-version", String.to_charlist(cli_version)}
         ], ~c"application/json",
         JSON.encode!(%{
           "verb" => "assignments",
           "params" => %{"sessionKey" => "cli-holder"}
         })},
        [],
        []
      )

    assert http_status == 202
    envelope = raw_body |> to_string() |> JSON.decode!()

    # Exactly one top-level key: not a result, not an error, no companions.
    assert Map.keys(envelope) == ["decisionPending"]
    pending = envelope["decisionPending"]
    assert Enum.sort(Map.keys(pending)) == ["code", "decisionRequestId", "message"]
    assert pending["code"] == "decision_pending"

    {output, status} =
      System.cmd(ctx.binary, ["assignments", "--session", "cli-holder"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    # It does NOT crash, and it says what happened in words the agent can act on.
    assert status != 0
    assert output =~ "decision_pending"
    assert output =~ "needs an owner decision"
    refute output =~ "EOF"
    refute output =~ "CaseClauseError"

    # The id each caller was told is a row that is actually open — without that,
    # the message is unactionable prose. Checked per caller rather than against a
    # single row: dedup keys on (raiserId, statuteName, actionKey), and these two
    # callers send different params, so two open requests here is correct and
    # asserting one would be asserting a coincidence.
    assert [request_id] = Regex.run(~r/dr_[0-9a-f-]+/, output)
    assert open_request?(ctx.db, request_id)
    assert open_request?(ctx.db, pending["decisionRequestId"])

    # THE EFFECT-APPLIES PROPERTY, which the fix must leave exactly alone: the
    # request opened and the handler never ran. Only the response changed.
    refute_receive {:cli_call, %{verb: "assignments"}}
  end

  test "real CLI retired producer verbs are unknown commands", ctx do
    for verb <- ["run-tests", "run-smoke", "cancel-producer-job"] do
      {output, status} =
        System.cmd(ctx.binary, [verb, "asg_1"],
          cd: ctx.workdir,
          stderr_to_stdout: true
        )

      assert status != 0
      assert output =~ "unknown command"
    end
  end

  test "real CLI prefers the expecter but permits an exact-id delegate with canonical replay",
       ctx do
    continue_request = open_effort_request(ctx, "continue")
    worker_dir = session_workdir!(ctx, ctx.worker)

    {requests, 0} =
      System.cmd(ctx.binary, ["decision-requests", "--status", "open"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert requests =~ continue_request

    assert_receive {:cli_call,
                    %{
                      verb: "decision-requests",
                      principal: {:session, "cli-holder"},
                      params: %{status: "open"}
                    }}

    {worker_requests, 0} =
      System.cmd(ctx.binary, ["decision-requests", "--status", "open"],
        cd: worker_dir,
        stderr_to_stdout: true
      )

    refute worker_requests =~ continue_request

    {exact, 0} =
      System.cmd(ctx.binary, ["decision-request", "--request", continue_request],
        cd: worker_dir,
        stderr_to_stdout: true
      )

    assert %{
             "decisionRequest" => %{
               "id" => ^continue_request,
               "kind" => "effort",
               "expecterSessionKey" => "cli-holder",
               "assignmentId" => assignment_id
             }
           } = JSON.decode!(exact)

    assert_receive {:cli_call,
                    %{
                      verb: "decision-request",
                      principal: {:session, "cli-worker"},
                      params: %{request: ^continue_request}
                    }}

    {:ok, [[generation_count]]} =
      DB.query(
        ctx.db,
        "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId = ?1",
        [assignment_id]
      )

    {continued, 0} =
      System.cmd(
        ctx.binary,
        ["effort-rule", "--request", continue_request, "--action", "continue"],
        cd: worker_dir,
        stderr_to_stdout: true
      )

    assert continued =~ "continue"

    assert_receive {:cli_call,
                    %{
                      verb: "effort-rule",
                      principal: {:session, "cli-worker"},
                      params: %{request: ^continue_request, action: "continue"}
                    }}

    assert {:ok, [["session:cli-worker"]]} =
             DB.query(ctx.db, "SELECT ruledBy FROM decision_requests WHERE id = ?1", [
               continue_request
             ])

    {replayed, 0} =
      System.cmd(
        ctx.binary,
        ["effort-rule", "--request", continue_request, "--action", "continue"],
        cd: worker_dir,
        stderr_to_stdout: true
      )

    assert replayed =~ "continue"

    assert {:ok, [[count_after_replay]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId = ?1",
               [assignment_id]
             )

    assert count_after_replay == generation_count + 1

    {refused_replay, refused_status} =
      System.cmd(
        ctx.binary,
        ["effort-rule", "--request", continue_request, "--action", "continue"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert refused_status != 0
    assert refused_replay =~ "not_open"

    dismiss_request = open_effort_request(ctx, "dismiss")

    {dismissed, 0} =
      System.cmd(
        ctx.binary,
        ["effort-rule", "--request", dismiss_request, "--action", "dismiss"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert dismissed =~ "dismiss"

    assert_receive {:cli_call,
                    %{
                      verb: "effort-rule",
                      principal: {:session, "cli-holder"},
                      params: %{request: ^dismiss_request, action: "dismiss"}
                    }}
  end

  test "real CLI creates and gets work items and enforces spec-ref pairing", ctx do
    sha = String.duplicate("a", 64)

    {created, 0} =
      System.cmd(
        ctx.binary,
        [
          "work-item-create",
          "--title",
          "Ship",
          "--spec-ref",
          "spec.md",
          "--spec-sha256",
          sha
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    work_item_id = JSON.decode!(created)["id"]
    assert "wi_" <> _ = work_item_id

    assert_receive {:cli_call,
                    %{
                      verb: "work-item-create",
                      params: %{title: "Ship", spec_ref_name: "spec.md", spec_ref_sha256: ^sha}
                    }}

    {got, 0} =
      System.cmd(ctx.binary, ["work-item-get", work_item_id],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert got =~ work_item_id

    assert_receive {:cli_call, %{verb: "work-item-get", params: %{work_item_id: ^work_item_id}}}

    {pairing, 1} =
      System.cmd(ctx.binary, ["work-item-create", "--title", "x", "--spec-ref", "spec.md"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert pairing =~ "supplied together"
  end

  defp open_effort_request(ctx, action) do
    key = "effort-#{action}-#{System.unique_integer([:positive])}"

    {dispatched, 0} =
      System.cmd(
        ctx.binary,
        [
          "dispatch",
          "--holder",
          "cli-worker",
          "--subject",
          "effort #{action}",
          "--brief",
          "Exercise the #{action} ruling path.",
          "--key",
          key
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assignment_id = JSON.decode!(dispatched)["id"]

    assert_receive {:cli_call, %{verb: "dispatch", params: %{idempotency_key: ^key}}}

    {:ok, [[generation, wake_id]]} =
      DB.query(
        ctx.db,
        "SELECT generation, wakeId FROM effort_checkin_generations WHERE assignmentId = ?1",
        [assignment_id]
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE effort_checkin_generations SET state = 'probed' WHERE assignmentId = ?1",
        [assignment_id]
      )

    request_id = "dr_#{action}_#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO decision_requests
          (id, kind, raiserId, ownerUserId, assignmentId, expecterSessionKey,
           lineageRung, effortGeneration, deadlineWakeId, raisedAt, deadlineAt,
           question, options, context, status)
        VALUES (?1, 'effort', 'process:tightbeam', 'flynn', ?2, 'cli-holder',
                1, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'open')
        """,
        [
          request_id,
          assignment_id,
          generation,
          wake_id,
          now,
          now + 60_000,
          "Continue or dismiss?",
          JSON.encode!(["continue", "dismiss"]),
          JSON.encode!(%{"actions" => ["continue", "dismiss"]})
        ]
      )

    request_id
  end
end
