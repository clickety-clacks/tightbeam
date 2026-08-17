defmodule Tightbeam.CustodyCeremonyF6Test do
  @moduledoc """
  F6: the custody handshake proved at the real boundary, not at an injected seam.

  Everything between the operator's keystroke and the final durable row runs for
  real here: the built CLI as a subprocess, its own argument parser, the HTTP
  route, the router's allowlist, `Gateway.handlers/1`, the durable `process-open`
  row, a real `fork`/`setsid` spawn, the pre-exec launch barrier, `process-bind`,
  the release revision, the broker identity artifact on disk, and a physical
  probe that execs the same built binary back again. The unit tests around
  `ManagedProcesses` prove the decisions; only this proves that the pieces are
  wired to each other.

  Two cases, because the handshake has exactly two outcomes and each is only
  interesting for what it FORBIDS:

    * a denied bind must leave the workload unexecuted — the child dies at the
      barrier having never become the vendor CLI;
    * a granted bind must exec only AFTER the release — the fixture records, at
      exec time, whether the release had already happened, so an exec that ran
      early would fail this test rather than pass it silently.

  Nothing here contacts a vendor, a network, or a credential. The harness CLI is
  a fixture script this test writes, named so it can only be ours, and the bytes
  it stages are synthetic and asserted to stay inside the fixture root.
  """

  use Tightbeam.TestCase, async: false

  @moduletag :cli_integration

  alias Tightbeam.{
    Archetypes,
    Credentials,
    DB,
    Gateway,
    ManagedProcesses,
    Model,
    Org,
    Placement,
    Roles,
    Rules
  }

  alias Tightbeam.Wire.Router

  # The ceremony's whole lifetime, and the lease the gateway hands the CLI. Short
  # enough that a wedged fixture fails the run instead of hanging it; far longer
  # than a script that writes two files needs.
  @lease_ms 60_000

  setup do
    binary = Path.expand("../cli/target/release/tightbeam", __DIR__)

    unless File.exists?(binary) do
      raise "CLI integration binary missing: #{binary}; run cargo build --release in cli/"
    end

    # ONE temp root holds every piece of state this test can touch: the gateway's
    # base dir, the credential store, the harness catalog, the staging CODEX_HOME,
    # the fixture harness binary, and the copy of the CLI the gateway execs to
    # probe. Isolation is what makes the assertion about synthetic bytes checkable
    # — there is exactly one directory they could have landed in.
    root =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-custody-f6-#{System.unique_integer([:positive])}"
      )

    workdir = Path.join(root, "work/session")
    harness_bin = Path.join(root, "harness-bin")
    custody_bin = Path.join(root, "bin")
    File.mkdir_p!(workdir)
    File.mkdir_p!(harness_bin)
    File.mkdir_p!(custody_bin)
    on_exit(fn -> File.rm_rf!(root) end)

    # `Placement.hosts/2` gives the local host `cli_bin: nil`, so the gateway's
    # physical probe looks for `<base_dir>/bin/tightbeam` — the path the real
    # boot installs. A symlink, not a rebuild: the binary under test is the one
    # the gate already built, and nothing in this suite may rewrite it.
    File.ln_s!(binary, Path.join(custody_bin, "tightbeam"))

    # The harness catalog the CLI reads, pinned to a binary name no vendor ships.
    # If the ceremony ever reached a real `codex`, this name is what would have
    # had to change for it to do so.
    File.write!(
      Path.join(root, "harnesses.json"),
      JSON.encode!([
        %{
          "id" => "codex",
          "wire_name" => "codex",
          "install_package" => "tb-f6-fixture",
          "cli_binary" => "tb-f6-codex",
          "process_markers" => ["tb-f6-codex"]
        }
      ])
    )

    fixture = Path.join(harness_bin, "tb-f6-codex")
    File.write!(fixture, fixture_script())
    File.chmod!(fixture, 0o755)

    db = :"custody_f6_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    # `local_host_name()` is "testhost" under the test config, and `Placement`
    # synthesizes the local entry with `ssh: nil` — which is exactly what makes
    # the gateway treat this row as locally probeable.
    machine = Placement.local_host_name()

    session =
      Org.create(db, %{
        session_key: "custody-f6",
        display_name: "Custody F6",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: machine,
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })

    Roles.create!(db, "custody-f6", "flynn", session.session_key)

    start_supervised!(
      {Credentials,
       name: Credentials, base_dir: root, machine: machine, onboarding_lease_ms: @lease_ms}
    )

    gateway_config = %{
      db: db,
      base_dir: root,
      cwd: root,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: @lease_ms
    }

    Archetypes.load!(root)
    real_handlers = Gateway.handlers(gateway_config)
    Rules.load!(root, Map.keys(real_handlers))

    test_pid = self()
    deny_flag = Path.join(root, "deny-bind")
    release_stamp = Path.join(root, "release.stamp")

    router_opts =
      Router.init(
        db: db,
        base_dir: root,
        handlers: instrument(real_handlers, db, test_pid, deny_flag, release_stamp),
        cli_token: "tbc_custody_f6",
        session_status: fn _ -> nil end
      )

    bandit =
      start_supervised!(
        {Bandit, plug: {Router, router_opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    File.write!(
      Path.join(workdir, ".tightbeam-session"),
      JSON.encode!(%{
        url: "http://127.0.0.1:#{port}",
        token: session.cli_token,
        sessionKey: session.session_key
      })
    )

    %{
      binary: binary,
      db: db,
      deny_flag: deny_flag,
      machine: machine,
      release_stamp: release_stamp,
      root: root,
      workdir: workdir
    }
  end

  test "a denied bind kills the child at the barrier and never execs the workload", ctx do
    exec_log = Path.join(ctx.root, "denied-exec.log")

    # The stop lands inside the `process-open` handler, so it is committed before
    # the CLI has the row id — no sleep, no window to lose. By the time the bind
    # arrives, the row carries a stop cause and the only lawful answer is "do not
    # release".
    File.write!(ctx.deny_flag, "stop the row the moment it is opened")

    {output, status} = onboard(ctx, exec_log)

    assert_receive {:custody, "process-open", process_id}, 30_000
    assert_receive {:custody, "process-bind", ^process_id}, 30_000

    # `flunk` rather than `refute ..., message`: ExUnit evaluates the message
    # eagerly, so reading the log to describe the failure would itself raise on the
    # passing path — where the file's ABSENCE is the whole proof.
    if File.exists?(exec_log) do
      flunk("the workload exec'd despite a denied bind: #{File.read!(exec_log)}")
    end

    assert status != 0, "the ceremony reported success after its bind was denied: #{output}"

    row = ManagedProcesses.get(ctx.db, process_id)
    assert row.osPid, "the denied row never recorded the identity it refused to release"
    assert row.brokerIdentity
    assert row.stopCause == "owner_stop"

    # The child is gone — it read EOF at the barrier — so the physical probe can
    # prove absence, and only a proof terminalizes the row.
    assert {_, 0} = process_reconcile(ctx, process_id)
    resolved = ManagedProcesses.get(ctx.db, process_id)
    assert resolved.state in ManagedProcesses.terminal_states()
    assert resolved.resolvedAt

    # Nothing was staged, because nothing ran.
    assert Credentials.kind_at(ctx.root, :openai) == :none
  end

  test "a granted bind execs the workload only after the release, and settles its row", ctx do
    exec_log = Path.join(ctx.root, "granted-exec.log")

    {output, status} = onboard(ctx, exec_log)

    assert_receive {:custody, "process-open", process_id}, 30_000
    assert_receive {:custody, "process-bind", ^process_id}, 30_000

    assert status == 0, "the ceremony failed: #{output}"

    # The stamp is written by the `process-bind` handler before its reply leaves
    # the gateway, so "the stamp was already there" is the same statement as "the
    # release had already been granted". An exec that beat the release would find
    # no stamp and fail this assertion rather than pass unnoticed.
    exec = File.read!(exec_log) |> String.trim()
    assert exec =~ "argv=login --device-auth", "the fixture ran with unexpected argv: #{exec}"
    assert exec =~ "stamp=present", "the workload exec'd before its release: #{exec}"

    [_, child_pid] = Regex.run(~r/pid=(\d+)/, exec)
    [_, child_pgid] = Regex.run(~r/pgid=(\d+)/, exec)

    row = ManagedProcesses.get(ctx.db, process_id)
    assert row.osPid, "the row bound no pid"
    assert row.processGroupId == row.osPid, "the broker did not lead its own process group"
    assert row.launchToken
    assert row.bootIdentity
    assert File.exists?(row.brokerIdentity), "the row names a broker identity that does not exist"

    # `exec` replaces the image without changing the pid, so the process that
    # became the workload is the very one the row bound — and it leads the group
    # a stop would signal. This is the link that makes the recorded identity
    # load-bearing rather than decorative.
    assert String.to_integer(child_pid) == row.osPid,
           "the workload ran as a different process than the row bound"

    assert String.to_integer(child_pgid) == row.processGroupId,
           "the workload ran outside the recorded process group"

    # The ceremony leaves the row live on purpose; `process-reconcile` is the verb
    # that resolves it, and it does so from a physical probe run by the same built
    # binary — not from a timeout.
    assert {_, 0} = process_reconcile(ctx, process_id)
    resolved = ManagedProcesses.get(ctx.db, process_id)
    assert resolved.state in ManagedProcesses.terminal_states()
    assert resolved.resolvedAt
    refute ManagedProcesses.blocks_retirement?(resolved)

    # The credential the fixture staged is synthetic and never left the fixture
    # root: the store banked it, and the bytes are the ones the fixture wrote.
    assert Credentials.kind_at(ctx.root, :openai) == :subscription

    staged = Path.wildcard(Path.join(ctx.root, "**/auth.json"))
    refute staged == [], "nothing was staged under the fixture root"

    for path <- staged do
      assert File.read!(path) =~ "tb-f6-synthetic-not-a-credential"
    end
  end

  # A ceremony run of the REAL built CLI. `TIGHTBEAM_MACHINE` is required rather
  # than convenient: without a `gateway.json` the CLI refuses to guess which
  # machine it is onboarding, which is the correct refusal and not one this test
  # should route around.
  defp onboard(ctx, exec_log) do
    System.cmd(ctx.binary, ["onboard", "openai"],
      cd: ctx.workdir,
      stderr_to_stdout: true,
      env: [
        {"TIGHTBEAM_BASE_DIR", ctx.root},
        {"TIGHTBEAM_MACHINE", ctx.machine},
        {"PATH", Path.join(ctx.root, "harness-bin") <> ":" <> System.get_env("PATH")},
        {"TB_F6_EXEC_LOG", exec_log},
        {"TB_F6_RELEASE_STAMP", ctx.release_stamp}
      ]
    )
  end

  defp process_reconcile(ctx, process_id) do
    System.cmd(ctx.binary, ["process-reconcile", process_id],
      cd: ctx.workdir,
      stderr_to_stdout: true,
      env: [{"TIGHTBEAM_BASE_DIR", ctx.root}]
    )
  end

  # The two custody verbs are wrapped, not replaced: the real handler decides,
  # and the wrapper only observes it and — for the denied case — commits a
  # legitimate stop through the ordinary verb at the one moment that makes the
  # denial deterministic.
  defp instrument(handlers, db, test_pid, deny_flag, release_stamp) do
    Map.new(handlers, fn
      {"process-open" = verb, handler} ->
        {verb,
         fn call ->
           result = handler.(call)
           id = process_id(result)
           if id && File.exists?(deny_flag), do: stop_row(db, id)
           send(test_pid, {:custody, verb, id})
           result
         end}

      {"process-bind" = verb, handler} ->
        {verb,
         fn call ->
           result = handler.(call)
           File.write!(release_stamp, "bind answered")
           send(test_pid, {:custody, verb, process_id(result)})
           result
         end}

      {verb, handler} ->
        {verb, handler}
    end)
  end

  defp process_id(%{process: %{"processId" => id}}), do: id
  defp process_id(_other), do: nil

  defp stop_row(db, process_id) do
    {:ok, _} =
      DB.transaction(db, fn txn ->
        ManagedProcesses.request_stop_in_txn(txn, process_id,
          now: System.system_time(:millisecond)
        )
      end)
  end

  # The fixture harness CLI. It contacts nothing, writes only where it is told,
  # and records the one fact the success case turns on: whether the release had
  # already been granted at the instant it became this program.
  defp fixture_script do
    """
    #!/bin/sh
    if [ -e "$TB_F6_RELEASE_STAMP" ]; then stamp=present; else stamp=absent; fi
    pgid=`ps -o pgid= -p $$ | tr -d ' '`
    printf 'argv=%s stamp=%s pid=%s pgid=%s\\n' "$*" "$stamp" "$$" "$pgid" >> "$TB_F6_EXEC_LOG"
    printf '%s' '{"tokens":{"access_token":"tb-f6-synthetic-not-a-credential"}}' > "$CODEX_HOME/auth.json"
    exit 0
    """
  end
end
