defmodule Tightbeam.CliIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :cli_integration

  alias Tightbeam.{Assets, DB, Devices, EventLog, Org, Roles}
  alias Tightbeam.Wire.Router

  setup do
    binary = Path.expand("../cli/target/release/tightbeam", __DIR__)

    unless File.exists?(binary) do
      raise "CLI integration binary missing: #{binary}; run cargo build --release in cli/"
    end

    db = :"cli_integration_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    for module <- [Assets, Devices, EventLog, Org, Roles], do: :ok = module.ensure_schema(db)

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-cli-integration-#{System.unique_integer([:positive])}"
      )

    workdir = Path.join(base_dir, "work/session/nested")
    File.mkdir_p!(workdir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

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
    test_pid = self()

    handlers = %{
      "inspect" => fn call ->
        send(test_pid, {:cli_call, call})
        %{sessions: [%{session_key: session.session_key}], wakes: []}
      end,
      "wake" => fn call ->
        send(test_pid, {:cli_call, call})
        %{wake_id: "w_cli"}
      end,
      "assign" => fn call ->
        send(test_pid, {:cli_call, call})
        %{id: "asg_cli", subject: call.params.subject}
      end,
      "attest" => fn call ->
        send(test_pid, {:cli_call, call})
        %{assignment: %{id: call.params.assignment_id}, attest: %{kind: call.params.kind}}
      end,
      "attests" => fn call ->
        send(test_pid, {:cli_call, call})
        %{attests: [%{id: "att_cli", assignmentId: call.params.assignment_id}]}
      end,
      "revoke-assignment" => fn call ->
        send(test_pid, {:cli_call, call})
        %{id: call.params.assignment_id, outcome: "revoked"}
      end,
      "assignments" => fn call ->
        send(test_pid, {:cli_call, call})
        %{assignments: [%{id: "asg_cli"}]}
      end,
      "work-item-create" => fn call ->
        send(test_pid, {:cli_call, call})
        %{id: "wi_cli", title: call.params.title}
      end,
      "work-item-update" => fn call ->
        send(test_pid, {:cli_call, call})
        %{id: call.params.work_item_id, title: call.params[:title]}
      end,
      "work-item-get" => fn call ->
        send(test_pid, {:cli_call, call})
        %{workItem: %{id: call.params.work_item_id}, assignments: []}
      end,
      "work-item-list" => fn call ->
        send(test_pid, {:cli_call, call})
        %{workItems: [%{id: "wi_cli"}]}
      end
    }

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

    %{binary: binary, db: db, session: session, workdir: workdir}
  end

  test "real CLI discovers a session token, dispatches, and loses access at retire", ctx do
    {listed, 0} = System.cmd(ctx.binary, ["list"], cd: ctx.workdir, stderr_to_stdout: true)
    assert listed =~ "cli-holder"
    assert_receive {:cli_call, %{origin: "agent:cli-holder", principal: {:session, "cli-holder"}}}

    {woken, 0} =
      System.cmd(
        ctx.binary,
        ["wake", "--session", "cli-holder", "--prompt", "hello"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert woken =~ "w_cli"
    assert_receive {:cli_call, %{verb: "wake", origin: "agent:cli-holder"}}

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

  test "real CLI dispatches every assignment subcommand with pinned wire shapes", ctx do
    {assigned, 0} =
      System.cmd(
        ctx.binary,
        [
          "assign",
          "--subject",
          "ship",
          "--session",
          "cli-holder",
          "--idempotency-key",
          "idem",
          "--work-item",
          "wi_cli"
        ],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert assigned =~ "asg_cli"

    assert_receive {:cli_call,
                    %{
                      verb: "assign",
                      session_key: "cli-holder",
                      params: %{subject: "ship", idempotency_key: "idem", work_item_id: "wi_cli"}
                    }}

    {attested, 0} =
      System.cmd(ctx.binary, ["attest", "asg_cli", "--kind", "completion", "--note", "ready"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert attested =~ "completion"

    assert_receive {:cli_call,
                    %{
                      verb: "attest",
                      params: %{assignment_id: "asg_cli", kind: "completion", note: "ready"}
                    }}

    {verdicted, 0} =
      System.cmd(
        ctx.binary,
        ["attest", "asg_cli", "--kind", "verdict", "--verdict", "tests-passed"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert verdicted =~ "verdict"

    assert_receive {:cli_call,
                    %{
                      verb: "attest",
                      params: %{
                        assignment_id: "asg_cli",
                        kind: "verdict",
                        verdict_kind: "tests-passed"
                      }
                    }}

    {attests, 0} =
      System.cmd(ctx.binary, ["attests", "asg_cli"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert attests =~ "att_cli"
    assert_receive {:cli_call, %{verb: "attests", params: %{assignment_id: "asg_cli"}}}

    {revoked, 0} =
      System.cmd(ctx.binary, ["revoke-assignment", "asg_cli"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert revoked =~ "revoked"
    assert_receive {:cli_call, %{verb: "revoke-assignment", params: %{assignment_id: "asg_cli"}}}

    {listed, 0} =
      System.cmd(ctx.binary, ["assignments", "--role", "cli-holder", "--state", "all"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert listed =~ "asg_cli"

    assert_receive {:cli_call,
                    %{
                      verb: "assignments",
                      session_key: "cli-holder",
                      target_role: "cli-holder",
                      params: %{state: "all"}
                    }}
  end

  test "real CLI dispatches every work-item subcommand and enforces usage pairing", ctx do
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

    assert created =~ "wi_cli"

    assert_receive {:cli_call,
                    %{
                      verb: "work-item-create",
                      params: %{title: "Ship", spec_ref_name: "spec.md", spec_ref_sha256: ^sha}
                    }}

    {updated, 0} =
      System.cmd(ctx.binary, ["work-item-update", "wi_cli", "--clear-spec-ref"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert updated =~ "wi_cli"

    assert_receive {:cli_call,
                    %{
                      verb: "work-item-update",
                      params: %{
                        work_item_id: "wi_cli",
                        spec_ref_name: nil,
                        spec_ref_sha256: nil
                      }
                    }}

    {got, 0} =
      System.cmd(ctx.binary, ["work-item-get", "wi_cli"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert got =~ "wi_cli"
    assert_receive {:cli_call, %{verb: "work-item-get", params: %{work_item_id: "wi_cli"}}}

    {listed, 0} =
      System.cmd(ctx.binary, ["work-item-list"], cd: ctx.workdir, stderr_to_stdout: true)

    assert listed =~ "wi_cli"
    assert_receive {:cli_call, %{verb: "work-item-list", params: %{}}}

    {pairing, 1} =
      System.cmd(ctx.binary, ["work-item-create", "--title", "x", "--spec-ref", "spec.md"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert pairing =~ "supplied together"

    {conflict, 1} =
      System.cmd(
        ctx.binary,
        ["work-item-update", "wi_cli", "--clear-spec-ref", "--spec-ref", "spec.md"],
        cd: ctx.workdir,
        stderr_to_stdout: true
      )

    assert conflict =~ "conflicts"
  end
end
