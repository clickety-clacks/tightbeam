defmodule Tightbeam.CliIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :cli_integration

  alias Tightbeam.{
    Assets,
    Archetypes,
    Assignments,
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
    Producers,
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

    for module <- [
          Tightbeam.CausalEvents,
          Assets,
          Devices,
          ConditionFacts,
          Idempotency,
          Ledger,
          Org,
          Projection,
          Roles,
          Wakes,
          WorkItems,
          Assignments,
          WorkState,
          EventLog,
          Escalation,
          Producers
        ],
        do: :ok = module.ensure_schema(db)

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
        model: "fable"
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
        model: "fable"
      })

    Roles.create!(db, "cli-worker", "flynn", worker.session_key)

    gateway_config = %{
      db: db,
      base_dir: base_dir,
      cwd: base_dir,
      producer_config: %{tests: "true", smoke: "true", timeout_ms: 60_000},
      producer_runner: nil
    }

    Archetypes.load!(base_dir)
    real_handlers = Gateway.handlers(gateway_config)
    Rules.load!(base_dir, Map.keys(real_handlers), %{})
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
      binary: binary,
      db: db,
      session: session,
      worker: worker,
      workdir: workdir,
      outside: outside
    }
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

    assert_receive {:cli_call, %{origin: "user:flynn", principal: {:session, "cli-holder"}}}

    Org.retire(ctx.db, ctx.session.session_key)
    {refused, 1} = System.cmd(ctx.binary, ["list"], cd: ctx.workdir, stderr_to_stdout: true)
    assert refused =~ "auth_failed"
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

  test "real CLI runs producers, lists decisions, and rules effort continue and dismiss", ctx do
    {assigned, 0} =
      System.cmd(
        ctx.binary,
        [
          "assign",
          "--subject",
          "mechanical checks",
          "--session",
          "cli-holder",
          "--key",
          "producer-cli"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assignment_id = JSON.decode!(assigned)["id"]
    assert_receive {:cli_call, %{verb: "assign", params: %{idempotency_key: "producer-cli"}}}

    {tests, 0} =
      System.cmd(ctx.binary, ["run-tests", assignment_id],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert tests =~ "pj_"

    assert_receive {:cli_call, %{verb: "run-tests", params: %{assignment_id: ^assignment_id}}}

    {smoke, 0} =
      System.cmd(ctx.binary, ["run-smoke", assignment_id],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert smoke =~ "pj_"

    assert_receive {:cli_call, %{verb: "run-smoke", params: %{assignment_id: ^assignment_id}}}

    continue_request = open_effort_request(ctx, "continue")

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

    {continued, 0} =
      System.cmd(
        ctx.binary,
        ["effort-rule", "--request", continue_request, "--action", "continue"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert continued =~ "continue"

    assert_receive {:cli_call,
                    %{
                      verb: "effort-rule",
                      principal: {:session, "cli-holder"},
                      params: %{request: ^continue_request, action: "continue"}
                    }}

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
