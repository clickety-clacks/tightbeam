defmodule Tightbeam.CliIntegrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  @moduletag :cli_integration

  alias Tightbeam.{
    Archetypes,
    CliCompatibility,
    DB,
    Gateway,
    Ledger,
    Org,
    Projection,
    RailRemedy,
    Rails,
    Roles,
    Rules,
    Wakes
  }

  alias Tightbeam.Wire.Router

  setup_all do
    cli_dir = Path.expand("../cli", __DIR__)
    binary = Path.join(cli_dir, "target/release/tightbeam")

    if cargo = System.find_executable("cargo") do
      {output, status} =
        System.cmd(cargo, ["build", "--release"], cd: cli_dir, stderr_to_stdout: true)

      if status != 0, do: raise("release CLI build failed:\n#{output}")
    end

    unless File.exists?(binary) do
      raise "CLI integration binary missing: #{binary}; run cargo build --release in cli/"
    end

    :ok
  end

  setup do
    binary = Path.expand("../cli/target/release/tightbeam", __DIR__)

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

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('flynn', 1, 'admin_add', 1)"
      )

    main_key = Org.personal_session_key("flynn")

    Org.create(db, %{
      session_key: main_key,
      display_name: "Main",
      kind: "main",
      is_built_in: true,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

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
      Map.new(real_handlers, fn {verb, handler} ->
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

  test "A22 real completion smoke delivers both notices and retains from the exact parent", ctx do
    main_key = Org.personal_session_key("flynn")

    parent =
      completion_session!(ctx.db, "a22-parent", main_key)

    child =
      completion_session!(ctx.db, "a22-child", parent.session_key)

    report =
      completion_session!(ctx.db, "a22-report", main_key)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('a22-admin',1,'admin_add',1)"
      )

    child_dir = session_workdir!(ctx, child)
    parent_dir = session_workdir!(ctx, parent)
    report_dir = session_workdir!(ctx, report)

    {work_json, 0} =
      System.cmd(ctx.binary, ["work-item-create", "--title", "A22 real completion smoke"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    work_item_id = JSON.decode!(work_json)["id"]

    dispatch_args = [
      "dispatch",
      "--holder",
      child.session_key,
      "--subject",
      "Complete the A22 smoke",
      "--brief",
      "File completion so the exact parent can retain.",
      "--work-item",
      work_item_id,
      "--key",
      "a22-real-completion",
      "--report-to",
      report.session_key
    ]

    {rumination_json, 0} =
      System.cmd(ctx.binary, dispatch_args, cd: ctx.workdir, stderr_to_stdout: true)

    assert JSON.decode!(rumination_json)["ruminationRequired"]

    assert {:ok, [[rumination_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId FROM wakes WHERE rumination=1 AND work_item_id=?1 AND creatorSessionKey=?2",
               [work_item_id, ctx.session.session_key]
             )

    deliver_completion_wake!(ctx, rumination_wake_id)

    {assignment_json, 0} =
      System.cmd(ctx.binary, dispatch_args, cd: ctx.workdir, stderr_to_stdout: true)

    assignment_response = JSON.decode!(assignment_json)
    assignment_id = assignment_response["id"] || assignment_response["assignment"]["id"]
    assert is_binary(assignment_id), inspect(assignment_response)

    {completion_json, 0} =
      System.cmd(ctx.binary, ["attest", assignment_id, "--kind", "completion"],
        cd: child_dir,
        stderr_to_stdout: true
      )

    closing_attest_id = JSON.decode!(completion_json)["attest"]["id"]
    parent_key = parent.session_key
    report_key = report.session_key

    assert {:ok,
            [
              [
                completion_id,
                ^closing_attest_id,
                "open",
                ^parent_key,
                ^report_key
              ]
            ]} =
             DB.query(
               ctx.db,
               "SELECT id,closingAttestId,status,parentSessionKey,reportToSessionKey FROM completion_escalations WHERE assignmentId=?1",
               [assignment_id]
             )

    assert {:ok, wake_rows} =
             DB.query(
               ctx.db,
               "SELECT kind,wakeId FROM completion_escalation_wakes WHERE completionId=?1",
               [completion_id]
             )

    wake_ids = Map.new(wake_rows, fn [kind, wake_id] -> {kind, wake_id} end)
    deadline_wake_id = wake_ids["deadline"]
    deliver_completion_wake!(ctx, wake_ids["parent-notice"])
    deliver_completion_wake!(ctx, wake_ids["report-to-notice"])

    {parent_read, 0} =
      System.cmd(ctx.binary, ["completion-notices", "--status", "open"],
        cd: parent_dir,
        stderr_to_stdout: true
      )

    {report_read, 0} =
      System.cmd(ctx.binary, ["completion-notices", "--status", "open"],
        cd: report_dir,
        stderr_to_stdout: true
      )

    {child_read, 0} =
      System.cmd(ctx.binary, ["completion-notices", "--status", "open"],
        cd: child_dir,
        stderr_to_stdout: true
      )

    {owner_read, 0} = completion_notices_as_user(ctx, "flynn")
    {admin_read, 0} = completion_notices_as_user(ctx, "a22-admin")

    for body <- [parent_read, report_read, child_read, owner_read, admin_read] do
      assert body =~ completion_id
    end

    {opener_read, 0} =
      System.cmd(ctx.binary, ["completion-notices", "--status", "open"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    refute opener_read =~ completion_id

    {report_denial, 1} =
      System.cmd(
        ctx.binary,
        ["completion-disposition", completion_id, "--decision", "retain"],
        cd: report_dir,
        stderr_to_stdout: true
      )

    assert report_denial =~ "not_authorized"

    {retained_json, 0} =
      System.cmd(
        ctx.binary,
        ["completion-disposition", completion_id, "--decision", "retain"],
        cd: parent_dir,
        stderr_to_stdout: true
      )

    retained = JSON.decode!(retained_json)
    assert retained["request"]["status"] == "acknowledged"
    assert retained["request"]["decision"] == "retain"

    {assignment_projection, 0} =
      System.cmd(ctx.binary, ["assignments", "--session", child.session_key, "--state", "all"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert assignment_projection =~ assignment_id
    assert assignment_projection =~ closing_attest_id

    {trace_json, 0} =
      System.cmd(ctx.binary, ["work-item-trace", work_item_id],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    timeline = JSON.decode!(trace_json)["timeline"]
    completion_wake_ids = Map.values(wake_ids)

    assert Enum.map(
             Enum.filter(timeline, &(&1["type"] == "completion_escalation")),
             & &1["phase"]
           ) == ["opened", "acknowledged"]

    assert Enum.map(
             Enum.filter(timeline, &(&1["type"] == "completion_escalation_event")),
             & &1["kind"]
           ) == ["completion_escalation_opened", "completion_escalation_acknowledged"]

    assert timeline
           |> Enum.filter(&(&1["type"] == "wake_fired" and &1["id"] in completion_wake_ids))
           |> Enum.map(& &1["id"])
           |> Enum.sort() ==
             Enum.sort([wake_ids["parent-notice"], wake_ids["report-to-notice"]])

    assert timeline
           |> Enum.filter(&(&1["type"] == "wake_canceled" and &1["id"] in completion_wake_ids))
           |> Enum.map(& &1["id"]) == [wake_ids["deadline"]]

    assert {:ok, message_rows} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,content FROM messages WHERE content LIKE ?1 ORDER BY sessionKey",
               ["%completionId=#{completion_id}%"]
             )

    assert Enum.map(message_rows, &hd/1) == Enum.sort([parent.session_key, report.session_key])
    refute Enum.any?(message_rows, &(hd(&1) == ctx.session.session_key))

    assert {:ok, turn_rows} =
             DB.query(
               ctx.db,
               "SELECT wakeId,sessionKey FROM turns WHERE wakeId IN (?1,?2) ORDER BY wakeId",
               [wake_ids["parent-notice"], wake_ids["report-to-notice"]]
             )

    assert Enum.sort(Enum.map(turn_rows, &List.last/1)) ==
             Enum.sort([parent.session_key, report.session_key])

    assert {:ok, wake_states} =
             DB.query(
               ctx.db,
               "SELECT wakeId,state FROM wakes WHERE wakeId IN (?1,?2,?3) ORDER BY wakeId",
               [wake_ids["parent-notice"], wake_ids["report-to-notice"], wake_ids["deadline"]]
             )

    assert Map.new(wake_states, fn [wake_id, state] -> {wake_id, state} end) == %{
             wake_ids["parent-notice"] => "fired",
             wake_ids["report-to-notice"] => "fired",
             wake_ids["deadline"] => "canceled"
           }

    assert {:ok, [[^deadline_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId FROM wake_cancellations WHERE wakeId IN (?1,?2,?3)",
               [wake_ids["parent-notice"], wake_ids["report-to-notice"], wake_ids["deadline"]]
             )

    assert {:ok, lifecycle_rows} =
             DB.query(
               ctx.db,
               "SELECT kind,subject FROM lifecycle_events WHERE subject=?1 ORDER BY rowid",
               [completion_id]
             )

    assert lifecycle_rows == [
             ["completion_escalation_opened", completion_id],
             ["completion_escalation_acknowledged", completion_id]
           ]

    IO.puts(
      "A22_CAPTURE " <>
        JSON.encode!(%{
          assignmentId: assignment_id,
          assignmentProjection: JSON.decode!(assignment_projection),
          closingAttestId: closing_attest_id,
          completionId: completion_id,
          lifecycle: lifecycle_rows,
          messages: message_rows,
          retain: retained,
          trace: timeline,
          turns: turn_rows,
          visibility: %{
            admin: JSON.decode!(admin_read),
            child: JSON.decode!(child_read),
            opener: JSON.decode!(opener_read),
            owner: JSON.decode!(owner_read),
            parent: JSON.decode!(parent_read),
            reportTo: JSON.decode!(report_read),
            reportToDisposition: report_denial
          },
          wakes: wake_states,
          workItemId: work_item_id
        })
    )
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
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('other', 0, 'admin_add', 1)"
      )

    other_main_key = Org.personal_session_key("other")

    Org.create(ctx.db, %{
      session_key: other_main_key,
      display_name: "Other Main",
      kind: "main",
      is_built_in: true,
      owner_user_id: "other",
      origin: "user:other",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

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
        [
          "revoke-assignment",
          assignment_id,
          "--reason",
          "operator cleanup",
          "--as-user",
          "flynn"
        ],
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
      System.cmd(ctx.binary, ["revoke-assignment", dispatch_id, "--reason", "worker cleanup"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert revoked =~ "revoked"

    assert_receive {:cli_call,
                    %{
                      verb: "revoke-assignment",
                      params: %{assignment_id: ^dispatch_id, reason: "worker cleanup"}
                    }}

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

    # The posture gate refuses a coder card on an unpostured work item, so the
    # org's orchestrator rules the slice first, through the same real CLI.
    orchestrator =
      Org.create(ctx.db, %{
        session_key: "cli-orchestrator",
        display_name: "CLI Orchestrator",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "orchestrator",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: Model.new("test")
      })

    Roles.create!(ctx.db, "cli-orchestrator", "flynn", orchestrator.session_key)

    {slice, 0} =
      System.cmd(
        ctx.binary,
        [
          "assign",
          "--subject",
          "orchestrate the slice",
          "--session",
          "cli-orchestrator",
          "--work-item",
          item_id,
          "--as-user",
          "flynn"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    slice_id = JSON.decode!(slice)["id"]

    {_postured, 0} =
      System.cmd(
        ctx.binary,
        [
          "attest",
          slice_id,
          "--kind",
          "verdict",
          "--verdict",
          "posture-light",
          "--note",
          "e2e: the input is the spec",
          "--as-user",
          "flynn"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

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

  defp completion_session!(db, session_key, parent_session_key) do
    session =
      Org.create(db, %{
        session_key: session_key,
        display_name: session_key,
        owner_user_id: "flynn",
        origin: "user:flynn",
        spawned_by: parent_session_key,
        operational_parent: parent_session_key,
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    Roles.create!(db, session_key, "flynn", session.session_key)
    session
  end

  defp completion_notices_as_user(ctx, user_id) do
    System.cmd(
      ctx.binary,
      ["completion-notices", "--status", "open", "--as-user", user_id],
      cd: ctx.outside,
      stderr_to_stdout: true,
      env: [
        {"TIGHTBEAM_URL", "ws://127.0.0.1:#{ctx.port}"},
        {"TIGHTBEAM_TOKEN", "tbc_cli_integration"},
        {"TIGHTBEAM_BASE_DIR", nil},
        {"TIGHTBEAM_HOME", nil}
      ]
    )
  end

  defp deliver_completion_wake!(ctx, wake_id) do
    wake = Wakes.get(ctx.db, wake_id)

    assert {:ok, {:appended, _owner, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(txn, wake.session_key, wake.origin, wake.prompt,
                 db: ctx.db,
                 wake_id: wake.wake_id,
                 sender: wake.origin,
                 principal: {:process, "tightbeam"},
                 target_gate: wake,
                 fire_wake_in_txn: true
               )
             end)
  end

  defp raw_agent_dispatch(ctx, token, body) do
    {:ok, {{_version, status, _reason}, _headers, raw_body}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{ctx.port}/agent/dispatch",
         [
           {~c"authorization", ~c"Bearer #{token}"},
           {~c"x-tightbeam-cli-version", String.to_charlist(CliCompatibility.required_version())}
         ], ~c"application/json", JSON.encode!(body)},
        [],
        []
      )

    {status, raw_body |> to_string() |> JSON.decode!()}
  end

  defp seed_terminal_response_fixtures!(ctx) do
    now = 1_780_000_000_000
    deadline = now + 86_400_000

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE decision_request_terminal_epoch SET legacyRulingFactMaxId=90000 WHERE id=0"
             )

    for {id, scope} <- [
          {90_000, "dr_00000000-0000-4000-8000-000000000005"},
          {90_001, "dr_00000000-0000-4000-8000-000000000002"},
          {90_002, "dr_00000000-0000-4000-8000-000000000007"}
        ] do
      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 "INSERT INTO condition_facts (id,ts,kind,scope,origin) VALUES (?1,?2,'escalation-ruled',?3,'process:tightbeam')",
                 [id, now + id, scope]
               )
    end

    common = fn id, owner, raiser_session, status ->
      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 "INSERT INTO decision_requests (id,kind,raiserId,raiserSessionKey,ownerUserId,raisedAt,deadlineAt,actionKey,question,options,context,status) VALUES (?1,'operator','agent:capture',?2,?3,?4,?5,?6,?7,'[{\"label\":\"accept\"},{\"label\":\"dismiss\"}]','{\"capture\":true}',?8)",
                 [
                   id,
                   raiser_session,
                   owner,
                   now,
                   deadline,
                   "capture:#{id}",
                   "Capture #{id}?",
                   status
                 ]
               )
    end

    common.("dr_00000000-0000-4000-8000-000000000001", "flynn", ctx.session.session_key, "open")

    common.(
      "dr_00000000-0000-4000-8000-000000000003",
      "flynn",
      ctx.session.session_key,
      "withdrawn"
    )

    common.(
      "dr_00000000-0000-4000-8000-000000000004",
      "flynn",
      ctx.session.session_key,
      "superseded"
    )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE decision_requests SET withdrawnBy='user:flynn',withdrawnReason='capture complete',withdrawnAt=?2 WHERE id=?1",
               ["dr_00000000-0000-4000-8000-000000000003", now + 20]
             )

    common.("dr_00000000-0000-4000-8000-000000000005", "flynn", ctx.session.session_key, "open")
    common.("dr_00000000-0000-4000-8000-000000000002", "flynn", ctx.session.session_key, "open")
    common.("dr_00000000-0000-4000-8000-000000000007", "flynn", ctx.session.session_key, "open")

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE decision_requests SET status='ruled',decision='accept',rationale=NULL,ruledBy='user:flynn',ruledViaPrincipal='user:flynn',ruledViaSessionState='none',ruledAt=?2,rulingFactId=90000 WHERE id=?1",
               ["dr_00000000-0000-4000-8000-000000000005", now + 100]
             )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE decision_requests SET ruledViaPrincipal=NULL,ruledViaSessionState=NULL WHERE id='dr_00000000-0000-4000-8000-000000000005'"
             )

    for {id, fact_id, ruled_at, status, consumed_at} <- [
          {"dr_00000000-0000-4000-8000-000000000002", 90_001, now + 200, "ruled", nil},
          {"dr_00000000-0000-4000-8000-000000000007", 90_002, now + 300, "consumed", now + 400}
        ] do
      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 "UPDATE decision_requests SET status=?2,decision='accept',rationale='captured',ruledBy='user:flynn',ruledViaPrincipal='user:flynn',ruledViaSessionState='none',ruledAt=?3,rulingFactId=?4,consumedAt=?5 WHERE id=?1",
                 [id, status, ruled_at, fact_id, consumed_at]
               )
    end

    for id <- [
          "dr_00000000-0000-4000-8000-000000000005",
          "dr_00000000-0000-4000-8000-000000000002",
          "dr_00000000-0000-4000-8000-000000000007"
        ] do
      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 "INSERT INTO lifecycle_events (ts,kind,subject,detail) VALUES (?1,'decision_request_ruled',?2,NULL)",
                 [now + 500, id]
               )
    end

    for {id, cursor, ruled_at} <- [
          {"dr_00000000-0000-4000-8000-000000000002", 90_000, now + 200},
          {"dr_00000000-0000-4000-8000-000000000007", 90_001, now + 300}
        ] do
      prompt =
        "Decision request #{id} was ruled. Read it with tightbeam decision-request --request #{id}."

      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 "INSERT INTO wakes (wakeId,sessionKey,origin,prompt,consumer,dueAt,state,createdAt,conditionKind,conditionScope,conditionAfterId,creatorSessionKey,targetGate) VALUES (?1,?2,'process:tightbeam',?3,'prompt',?4,'pending',?5,'escalation-ruled',?6,?7,NULL,0)",
                 [
                   "w_capture_#{id}",
                   ctx.session.session_key,
                   prompt,
                   ruled_at + 86_400_000,
                   now,
                   id,
                   cursor
                 ]
               )
    end

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('capture-other',0,'admin_add',1)"
             )

    ensure_main_session(ctx.db, "capture-other")

    hidden =
      Org.create(ctx.db, %{
        session_key: "cli-capture-hidden",
        display_name: "Hidden capture",
        owner_user_id: "capture-other",
        origin: "user:capture-other",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    common.(
      "dr_00000000-0000-4000-8000-000000000006",
      "capture-other",
      hidden.session_key,
      "open"
    )

    [
      {"open", "dr_00000000-0000-4000-8000-000000000001"},
      {"ruled", "dr_00000000-0000-4000-8000-000000000002"},
      {"withdrawn", "dr_00000000-0000-4000-8000-000000000003"},
      {"superseded", "dr_00000000-0000-4000-8000-000000000004"},
      {"legacy", "dr_00000000-0000-4000-8000-000000000005"},
      {"hidden", "dr_00000000-0000-4000-8000-000000000006"},
      {"impossibleConsumed", "dr_00000000-0000-4000-8000-000000000007"}
    ]
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

  test "real CLI exact-reads and rules an effort request from a non-expecter session", ctx do
    continue_request = open_effort_request(ctx, "continue")
    worker_dir = session_workdir!(ctx, ctx.worker)

    {requests, 0} =
      System.cmd(ctx.binary, ["decision-requests", "--status", "open"],
        cd: worker_dir,
        stderr_to_stdout: true
      )

    refute requests =~ continue_request

    assert_receive {:cli_call,
                    %{
                      verb: "decision-requests",
                      principal: {:session, "cli-worker"},
                      params: %{status: "open"}
                    }}

    {exact, 0} =
      System.cmd(
        ctx.binary,
        ["decision-request", "--request", continue_request],
        cd: worker_dir,
        stderr_to_stdout: true
      )

    exact = JSON.decode!(exact)["decisionRequest"]
    assert exact["id"] == continue_request
    assert exact["kind"] == "effort"
    assert exact["question"] == "Continue or dismiss?"

    assert_receive {:cli_call,
                    %{
                      verb: "decision-request",
                      principal: {:session, "cli-worker"},
                      params: %{request: ^continue_request}
                    }}

    {:ok, [[generations_before]]} =
      DB.query(
        ctx.db,
        "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId = (SELECT assignmentId FROM decision_requests WHERE id = ?1)",
        [continue_request]
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

    {:ok, [["session:cli-worker"]]} =
      DB.query(ctx.db, "SELECT ruledBy FROM decision_requests WHERE id = ?1", [continue_request])

    {:ok, [[generations_after]]} =
      DB.query(
        ctx.db,
        "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId = (SELECT assignmentId FROM decision_requests WHERE id = ?1)",
        [continue_request]
      )

    assert generations_after == generations_before + 1

    {retried, 0} =
      System.cmd(
        ctx.binary,
        ["effort-rule", "--request", continue_request, "--action", "continue"],
        cd: worker_dir,
        stderr_to_stdout: true
      )

    assert retried =~ "session:cli-worker"

    {:ok, [[^generations_after]]} =
      DB.query(
        ctx.db,
        "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId = (SELECT assignmentId FROM decision_requests WHERE id = ?1)",
        [continue_request]
      )

    {lost, status} =
      System.cmd(
        ctx.binary,
        ["effort-rule", "--request", continue_request, "--action", "continue"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert status != 0
    assert lost =~ "not_open"

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

  test "real CLI rejects duplicate exact-request flags before dispatch", ctx do
    first_request = "dr_11111111-1111-4111-8111-111111111111"
    second_request = "dr_22222222-2222-4222-8222-222222222222"

    {output, status} =
      System.cmd(
        ctx.binary,
        ["decision-request", "--request", first_request, "--request", second_request],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "usage: tightbeam decision-request --request <decisionRequestId>"
    refute_receive {:cli_call, _call}
  end

  test "A-27 checked fixture is captured from release CLI and real HTTP responses", ctx do
    baseline =
      __DIR__
      |> then(&Path.expand("fixtures/terminal_operator_real_gateway_baseline.json", &1))
      |> File.read!()
      |> JSON.decode!()

    assert baseline["sourceRevision"] == "d38cd7823511a4b6ee5bb3d8180a1628fcb2ac3b"

    assert Enum.sort(Map.keys(baseline["capture"])) ==
             ~w(hidden impossibleConsumed legacy open ruled superseded withdrawn)

    assert Enum.all?(baseline["capture"], fn {_name, captured} ->
             captured["http"] == %{
               "status" => 404,
               "body" => %{
                 "error" => %{
                   "code" => "not_found",
                   "message" => "decision request not found"
                 }
               }
             } and captured["releaseCli"]["status"] == 1
           end)

    fixture_ids = seed_terminal_response_fixtures!(ctx)

    actual =
      Map.new(fixture_ids, fn {name, request_id} ->
        {http_status, http_body} =
          raw_agent_dispatch(ctx, ctx.session.cli_token, %{
            "verb" => "decision-request",
            "params" => %{"request" => request_id}
          })

        {cli_output, cli_status} =
          System.cmd(ctx.binary, ["decision-request", "--request", request_id],
            cd: ctx.workdir,
            stderr_to_stdout: true
          )

        {name,
         %{
           "requestId" => request_id,
           "http" => %{"status" => http_status, "body" => http_body},
           "releaseCli" => %{"status" => cli_status, "output" => cli_output}
         }}
      end)

    fixture_path =
      Path.expand("fixtures/terminal_operator_real_gateway_candidate.json", __DIR__)

    if File.exists?(fixture_path) do
      assert actual == fixture_path |> File.read!() |> JSON.decode!()
    else
      flunk("capture fixture missing; real response was:\n#{JSON.encode!(actual)}")
    end
  end

  test "A-14 raw HTTP pins exact-read and response refusal envelopes", ctx do
    effort_id = open_effort_request(ctx, "wire-refusal")
    agent_id = "dr_wire_agent_#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO decision_requests
                 (id,kind,raiserId,raiserSessionKey,ownerUserId,expecterSessionKey,
                  expecterUserId,raisedAt,question,context,status)
               VALUES (?1,'agent','session:cli-holder','cli-holder','flynn','cli-holder',
                       'flynn',?2,'Which path?','{}','open')
               """,
               [agent_id, now]
             )

    assert {200,
            %{
              "result" => %{
                "decisionRequest" => %{"id" => ^effort_id, "kind" => "effort"}
              }
            }} =
             raw_agent_dispatch(ctx, ctx.worker.cli_token, %{
               "verb" => "decision-request",
               "params" => %{"request" => effort_id}
             })

    not_found = %{
      "error" => %{"code" => "not_found", "message" => "decision request not found"}
    }

    assert {404, ^not_found} =
             raw_agent_dispatch(ctx, ctx.worker.cli_token, %{
               "verb" => "decision-request",
               "params" => %{"request" => "dr_absent"}
             })

    for verb <- ["answer", "return"] do
      params =
        if verb == "answer",
          do: %{"request" => effort_id, "answer" => "not an agent question"},
          else: %{"request" => effort_id, "reason" => "not an agent question"}

      assert {404, ^not_found} =
               raw_agent_dispatch(ctx, ctx.worker.cli_token, %{
                 "verb" => verb,
                 "params" => params
               })
    end

    assert {400,
            %{
              "error" => %{
                "code" => "invalid",
                "message" => "effort-rule requires an effort request"
              }
            }} =
             raw_agent_dispatch(ctx, ctx.worker.cli_token, %{
               "verb" => "effort-rule",
               "params" => %{"request" => agent_id, "action" => "continue"}
             })

    assert {403,
            %{
              "error" => %{
                "code" => "not_authorized",
                "message" => "current expecter required"
              }
            }} =
             raw_agent_dispatch(ctx, ctx.worker.cli_token, %{
               "asUser" => "flynn",
               "verb" => "effort-rule",
               "params" => %{"request" => effort_id, "action" => "continue"}
             })

    for {verb, params} <- [
          {"decision-request", %{"request" => effort_id}},
          {"answer", %{"request" => agent_id, "answer" => "yes"}},
          {"return", %{"request" => agent_id, "reason" => "unclear"}},
          {"effort-rule", %{"request" => effort_id, "action" => "continue"}}
        ] do
      assert {401, %{"error" => %{"code" => "auth_failed"}}} =
               raw_agent_dispatch(ctx, "not-a-token", %{"verb" => verb, "params" => params})
    end
  end

  test "A-15 exact-id security matrix preserves every principal boundary", ctx do
    for user_id <- ["nobody", "other"] do
      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES (?1,0,'admin_add',1)",
                 [user_id]
               )
    end

    session_identity = %{}
    user_identity = %{"asUser" => "nobody"}
    process_identity = %{"asProcess" => "ci"}
    role_identity = %{"as" => "cli-holder"}

    invoke = fn token, identity, verb, params ->
      raw_agent_dispatch(
        ctx,
        token,
        identity |> Map.merge(%{"verb" => verb, "params" => params})
      )
    end

    # One authenticated bystander session gains exact-id access and the three
    # kind-matching response paths. The statute arm remains hidden.
    agent_read = open_agent_request(ctx)
    effort_read = open_effort_request(ctx, "matrix-session-read")
    statute_read = open_statute_request(ctx, "other")

    assert {200, %{"result" => %{"decisionRequest" => %{"id" => ^agent_read}}}} =
             invoke.(ctx.worker.cli_token, session_identity, "decision-request", %{
               "request" => agent_read
             })

    assert {200, %{"result" => %{"decisionRequest" => %{"id" => ^effort_read}}}} =
             invoke.(ctx.worker.cli_token, session_identity, "decision-request", %{
               "request" => effort_read
             })

    assert {404, %{"error" => %{"code" => "not_found", "message" => _}}} =
             invoke.(ctx.worker.cli_token, session_identity, "decision-request", %{
               "request" => statute_read
             })

    assert {404, absent_read_envelope} =
             invoke.(ctx.worker.cli_token, session_identity, "decision-request", %{
               "request" => "dr_matrix_session_absent"
             })

    assert {404, ^absent_read_envelope} =
             invoke.(ctx.worker.cli_token, session_identity, "decision-request", %{
               "request" => statute_read
             })

    answer_id = open_agent_request(ctx)

    assert {200, %{"result" => %{"decisionRequest" => %{"answeredBy" => "session:cli-worker"}}}} =
             invoke.(ctx.worker.cli_token, session_identity, "answer", %{
               "request" => answer_id,
               "answer" => "session answer"
             })

    return_id = open_agent_request(ctx)

    assert {200, %{"result" => %{"decisionRequest" => %{"returnedBy" => "session:cli-worker"}}}} =
             invoke.(ctx.worker.cli_token, session_identity, "return", %{
               "request" => return_id,
               "reason" => "session needs context"
             })

    effort_rule_id = open_effort_request(ctx, "matrix-session-rule")

    assert {200, %{"result" => %{"ruledBy" => "session:cli-worker"}}} =
             invoke.(ctx.worker.cli_token, session_identity, "effort-rule", %{
               "request" => effort_rule_id,
               "action" => "continue"
             })

    # The bystander session's direct standing remains kind-scoped. Every
    # wrong-kind hidden row is indistinguishable from an absent id.
    before_session_refusals = security_counts(ctx.db)

    for {verb, params_for} <- [
          {"answer", fn request -> %{"request" => request, "answer" => "wrong kind"} end},
          {"return", fn request -> %{"request" => request, "reason" => "wrong kind"} end}
        ] do
      assert {404, absent_envelope} =
               invoke.(
                 ctx.worker.cli_token,
                 session_identity,
                 verb,
                 params_for.("dr_matrix_session_absent")
               )

      for hidden_id <- [effort_read, statute_read] do
        assert {404, ^absent_envelope} =
                 invoke.(
                   ctx.worker.cli_token,
                   session_identity,
                   verb,
                   params_for.(hidden_id)
                 )
      end
    end

    assert {400,
            %{
              "error" => %{
                "code" => "invalid",
                "message" => "effort-rule requires an effort request"
              }
            }} =
             invoke.(ctx.worker.cli_token, session_identity, "effort-rule", %{
               "request" => agent_read,
               "action" => "continue"
             })

    assert {404, absent_effort_envelope} =
             invoke.(ctx.worker.cli_token, session_identity, "effort-rule", %{
               "request" => "dr_matrix_session_absent",
               "action" => "continue"
             })

    assert {404, ^absent_effort_envelope} =
             invoke.(ctx.worker.cli_token, session_identity, "effort-rule", %{
               "request" => statute_read,
               "action" => "continue"
             })

    assert security_counts(ctx.db) == before_session_refusals

    # User, process, role-without-session, and unauthenticated callers acquire
    # no standing. Every refused group leaves requests, events, wakes, and
    # monitor generations byte-for-byte at the same counts.
    for {token, identity, authenticated?} <- [
          {"tbc_cli_integration", user_identity, true},
          {"tbc_cli_integration", process_identity, true},
          {"tbc_cli_integration", role_identity, true},
          {"not-a-token", %{}, false}
        ] do
      agent_id = open_agent_request(ctx)
      effort_id = open_effort_request(ctx, "matrix-refused")
      statute_id = open_statute_request(ctx, "other")
      absent_id = "dr_matrix_absent_#{System.unique_integer([:positive])}"
      before = security_counts(ctx.db)

      targets = %{agent: agent_id, effort: effort_id, statute: statute_id, absent: absent_id}

      for {verb, params_for} <- [
            {"decision-request", fn request -> %{"request" => request} end},
            {"answer", fn request -> %{"request" => request, "answer" => "must refuse"} end},
            {"return", fn request -> %{"request" => request, "reason" => "must refuse"} end},
            {"effort-rule", fn request -> %{"request" => request, "action" => "continue"} end}
          ] do
        absent_result = invoke.(token, identity, verb, params_for.(targets.absent))
        expected_absent_status = if authenticated?, do: 404, else: 401
        assert {^expected_absent_status, %{"error" => %{"code" => _}}} = absent_result

        for kind <- [:agent, :effort, :statute] do
          result = invoke.(token, identity, verb, params_for.(Map.fetch!(targets, kind)))

          if authenticated? and verb == "effort-rule" and kind == :effort do
            assert {403,
                    %{
                      "error" => %{
                        "code" => "not_authorized",
                        "message" => "current expecter required"
                      }
                    }} = result
          else
            assert result == absent_result
          end
        end
      end

      assert security_counts(ctx.db) == before

      assert request_statuses(ctx.db, [agent_id, effort_id, statute_id]) == [
               "open",
               "open",
               "open"
             ]
    end

    # Existing stamped human expecters retain their old standing and no more.
    expecter_identity = %{"asUser" => "other"}
    user_agent_read = open_agent_request(ctx, expecter_user_id: "other")

    assert {200, %{"result" => %{"decisionRequest" => %{"id" => ^user_agent_read}}}} =
             invoke.("tbc_cli_integration", expecter_identity, "decision-request", %{
               "request" => user_agent_read
             })

    user_answer = open_agent_request(ctx, expecter_user_id: "other")

    assert {200, %{"result" => %{"decisionRequest" => %{"answeredBy" => "user:other"}}}} =
             invoke.("tbc_cli_integration", expecter_identity, "answer", %{
               "request" => user_answer,
               "answer" => "human answer"
             })

    user_return = open_agent_request(ctx, expecter_user_id: "other")

    assert {200, %{"result" => %{"decisionRequest" => %{"returnedBy" => "user:other"}}}} =
             invoke.("tbc_cli_integration", expecter_identity, "return", %{
               "request" => user_return,
               "reason" => "human needs context"
             })

    user_effort =
      open_effort_request(ctx, "matrix-user-rule",
        expecter_session_key: nil,
        expecter_user_id: "other"
      )

    assert {200, %{"result" => %{"ruledBy" => "user:other"}}} =
             invoke.("tbc_cli_integration", expecter_identity, "effort-rule", %{
               "request" => user_effort,
               "action" => "continue"
             })

    user_statute = open_statute_request(ctx, "other")

    assert {200, %{"result" => %{"decisionRequest" => %{"id" => ^user_statute}}}} =
             invoke.("tbc_cli_integration", expecter_identity, "decision-request", %{
               "request" => user_statute
             })

    before_statute_refusals = security_counts(ctx.db)

    for {verb, params, status} <- [
          {"answer", %{"request" => user_statute, "answer" => "wrong kind"}, 404},
          {"return", %{"request" => user_statute, "reason" => "wrong kind"}, 404},
          {"effort-rule", %{"request" => user_statute, "action" => "continue"}, 400}
        ] do
      assert {^status, _envelope} =
               invoke.("tbc_cli_integration", expecter_identity, verb, params)
    end

    assert security_counts(ctx.db) == before_statute_refusals
    assert request_statuses(ctx.db, [user_statute]) == ["open"]
  end

  test "real CLI returns an insufficient question and removes it from the open queue", ctx do
    {asked, 0} =
      System.cmd(
        ctx.binary,
        [
          "ask",
          "--session",
          ctx.worker.session_key,
          "--question",
          "which migration should ship?"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert_receive {:cli_call,
                    %{
                      verb: "ask",
                      principal: {:session, "cli-holder"},
                      session_key: "cli-worker"
                    }}

    assert {:ok, [[request_id]]} =
             DB.query(
               ctx.db,
               "SELECT id FROM decision_requests WHERE kind='agent' ORDER BY rowid DESC LIMIT 1"
             )

    assert asked =~ request_id
    worker_dir = session_workdir!(ctx, ctx.worker)

    {returned, 0} =
      System.cmd(
        ctx.binary,
        [
          "return",
          "--request",
          request_id,
          "--reason",
          "name the migration and rollback boundary"
        ],
        cd: worker_dir,
        stderr_to_stdout: true
      )

    assert returned =~ request_id
    assert returned =~ "returned"
    assert returned =~ "name the migration and rollback boundary"

    assert_receive {:cli_call,
                    %{
                      verb: "return",
                      principal: {:session, "cli-worker"},
                      params: %{
                        request: ^request_id,
                        reason: "name the migration and rollback boundary"
                      }
                    }}

    assert {:ok, [["returned", "session:cli-worker", reason, returned_at]]} =
             DB.query(
               ctx.db,
               "SELECT status, returnedBy, returnReason, returnedAt FROM decision_requests WHERE id=?1",
               [request_id]
             )

    assert reason == "name the migration and rollback boundary"
    assert is_integer(returned_at)

    {open, 0} =
      System.cmd(ctx.binary, ["decision-requests", "--status", "open"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    refute open =~ request_id

    {history, 0} =
      System.cmd(ctx.binary, ["decision-requests", "--status", "returned"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert history =~ request_id
    assert history =~ reason
  end

  test "real CLI retrieves open decisions through the configured client gateway path", ctx do
    request_id = "dr_configured-client_#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO decision_requests
          (id, raiserId, ownerUserId, raisedAt, deadlineAt, statuteName, actionKey,
           question, context, status)
        VALUES (?1, 'process:tightbeam', 'flynn', ?2, ?3,
                'configured-client-retrieval', ?4, 'Continue?', '{}', 'open')
        """,
        [request_id, now, now + 60_000, request_id]
      )

    {requests, 0} =
      System.cmd(
        ctx.binary,
        ["decision-requests", "--status", "open", "--as-user", "flynn"],
        cd: ctx.outside,
        stderr_to_stdout: true,
        env: [
          {"TIGHTBEAM_URL", "ws://127.0.0.1:#{ctx.port}"},
          {"TIGHTBEAM_TOKEN", ctx.session.cli_token},
          {"TIGHTBEAM_BASE_DIR", nil},
          {"TIGHTBEAM_HOME", nil}
        ]
      )

    assert requests =~ request_id

    assert_receive {:cli_call,
                    %{
                      verb: "decision-requests",
                      principal: {:user, "flynn"},
                      params: %{status: "open"}
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

  test "real CLI exposes the complete work-item PATCH contract", ctx do
    sha = String.duplicate("a", 64)
    sha2 = String.duplicate("b", 64)

    {created, 0} =
      System.cmd(
        ctx.binary,
        [
          "work-item-create",
          "--title",
          "Before",
          "--spec-ref",
          "governing.md",
          "--spec-sha256",
          sha
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    work_item_id = JSON.decode!(created)["id"]

    assert_receive {:cli_call, %{verb: "work-item-create"}}

    {retitled, 0} =
      System.cmd(ctx.binary, ["work-item-update", work_item_id, "--title", "After"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert %{
             "title" => "After",
             "specRefName" => "governing.md",
             "specRefSha256" => ^sha
           } = JSON.decode!(retitled)

    assert_receive {:cli_call,
                    %{
                      verb: "work-item-update",
                      params: %{work_item_id: ^work_item_id, title: "After"}
                    }}

    {repinned, 0} =
      System.cmd(ctx.binary, ["work-item-update", work_item_id, "--spec-sha256", sha2],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert %{"specRefName" => "governing.md", "specRefSha256" => ^sha2} =
             JSON.decode!(repinned)

    assert_receive {:cli_call,
                    %{
                      verb: "work-item-update",
                      params: %{work_item_id: ^work_item_id, spec_ref_sha256: ^sha2}
                    }}

    {noop, 0} =
      System.cmd(ctx.binary, ["work-item-update", work_item_id],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert JSON.decode!(noop) == JSON.decode!(repinned)

    assert_receive {:cli_call,
                    %{verb: "work-item-update", params: %{work_item_id: ^work_item_id}}}

    {cleared, 0} =
      System.cmd(ctx.binary, ["work-item-update", work_item_id, "--clear-spec-ref"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert %{"specRefName" => nil, "specRefSha256" => nil} = JSON.decode!(cleared)

    assert_receive {:cli_call,
                    %{
                      verb: "work-item-update",
                      params: %{
                        work_item_id: ^work_item_id,
                        spec_ref_name: nil,
                        spec_ref_sha256: nil
                      }
                    }}

    {incomplete, 1} =
      System.cmd(ctx.binary, ["work-item-update", work_item_id, "--spec-ref", "next.md"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert incomplete =~ "invalid_spec_ref"

    assert_receive {:cli_call,
                    %{
                      verb: "work-item-update",
                      params: %{work_item_id: ^work_item_id, spec_ref_name: "next.md"}
                    }}

    {set, 0} =
      System.cmd(
        ctx.binary,
        [
          "work-item-update",
          work_item_id,
          "--spec-ref",
          "next.md",
          "--spec-sha256",
          sha
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert %{"specRefName" => "next.md", "specRefSha256" => ^sha} = JSON.decode!(set)

    assert_receive {:cli_call,
                    %{
                      verb: "work-item-update",
                      params: %{
                        work_item_id: ^work_item_id,
                        spec_ref_name: "next.md",
                        spec_ref_sha256: ^sha
                      }
                    }}

    {replayed, 0} =
      System.cmd(
        ctx.binary,
        [
          "work-item-update",
          work_item_id,
          "--spec-ref",
          "next.md",
          "--spec-sha256",
          sha
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert JSON.decode!(replayed) == JSON.decode!(set)
    assert_receive {:cli_call, %{verb: "work-item-update"}}

    {conflict, 1} =
      System.cmd(
        ctx.binary,
        ["work-item-update", work_item_id, "--clear-spec-ref", "--spec-ref", "next.md"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert conflict =~ "conflicts"
    refute_receive {:cli_call, %{verb: "work-item-update"}}, 50

    {got, 0} =
      System.cmd(ctx.binary, ["work-item-get", work_item_id],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert got =~ "next.md"
    assert got =~ sha
    assert_receive {:cli_call, %{verb: "work-item-get"}}

    {combined, 0} =
      System.cmd(
        ctx.binary,
        [
          "work-item-update",
          work_item_id,
          "--title",
          "Together",
          "--spec-ref",
          "combined.md",
          "--spec-sha256",
          sha2,
          "--priority",
          "7"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert %{
             "title" => "Together",
             "specRefName" => "combined.md",
             "specRefSha256" => ^sha2,
             "priority" => 7
           } = JSON.decode!(combined)

    assert_receive {:cli_call,
                    %{
                      verb: "work-item-update",
                      params: %{
                        work_item_id: ^work_item_id,
                        title: "Together",
                        spec_ref_name: "combined.md",
                        spec_ref_sha256: ^sha2,
                        priority: 7
                      }
                    }}
  end

  defp open_agent_request(ctx, opts \\ []) do
    request_id = "dr_agent_#{System.unique_integer([:positive])}"
    expecter_session_key = Keyword.get(opts, :expecter_session_key, "cli-holder")
    expecter_user_id = Keyword.get(opts, :expecter_user_id, "other")
    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO decision_requests
                 (id,kind,raiserId,raiserSessionKey,ownerUserId,expecterSessionKey,
                  expecterUserId,raisedAt,question,context,status)
               VALUES (?1,'agent','session:cli-holder','cli-holder','flynn',?2,?3,?4,
                       'Which path?','{}','open')
               """,
               [request_id, expecter_session_key, expecter_user_id, now]
             )

    request_id
  end

  defp open_statute_request(ctx, owner_user_id) do
    request_id = "dr_statute_#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO decision_requests
                 (id,kind,raiserId,ownerUserId,raisedAt,deadlineAt,statuteName,actionKey,
                  question,context,status)
               VALUES (?1,'statute','session:cli-holder',?2,?3,?4,'deploy-gate',?5,
                       'May this ship?','{}','open')
               """,
               [request_id, owner_user_id, now, now + 60_000, "action-#{request_id}"]
             )

    request_id
  end

  defp security_counts(db) do
    assert {:ok, [counts]} =
             DB.query(
               db,
               """
               SELECT
                 (SELECT COUNT(*) FROM decision_requests),
                 (SELECT COUNT(*) FROM lifecycle_events),
                 (SELECT COUNT(*) FROM wakes),
                 (SELECT COUNT(*) FROM effort_checkin_generations)
               """
             )

    counts
  end

  defp request_statuses(db, request_ids) do
    Enum.map(request_ids, fn request_id ->
      assert {:ok, [[status]]} =
               DB.query(db, "SELECT status FROM decision_requests WHERE id=?1", [request_id])

      status
    end)
  end

  defp open_effort_request(ctx, action, opts \\ []) do
    expecter_session_key = Keyword.get(opts, :expecter_session_key, "cli-holder")
    expecter_user_id = Keyword.get(opts, :expecter_user_id)
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

    request_id = "dr_" <> Tightbeam.Id.uuid4()
    now = System.system_time(:millisecond)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO decision_requests
          (id, kind, raiserId, ownerUserId, assignmentId, expecterSessionKey,
           expecterUserId, lineageRung, effortGeneration, deadlineWakeId, raisedAt, deadlineAt,
           question, options, context, status)
        VALUES (?1, 'effort', 'process:tightbeam', 'flynn', ?2, ?3, ?4,
                1, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'open')
        """,
        [
          request_id,
          assignment_id,
          expecter_session_key,
          expecter_user_id,
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
