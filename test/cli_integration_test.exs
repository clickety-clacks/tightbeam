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
end
