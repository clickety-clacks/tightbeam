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
    prebind_mode = Path.join(root, "prebind-mode")
    release_stamp = Path.join(root, "release.stamp")

    router_opts =
      Router.init(
        db: db,
        base_dir: root,
        handlers: instrument(real_handlers, db, test_pid, deny_flag, prebind_mode, release_stamp),
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

    # A HOME and a TMPDIR of its own, so closing the environment leaves the CLI
    # somewhere to be rather than pointing it at the real user's dotfiles.
    home = Path.join(root, "home")
    tmpdir = Path.join(root, "tmp")
    hold_flag = Path.join(root, "hold-workload")
    File.mkdir_p!(home)
    File.mkdir_p!(tmpdir)
    on_exit(fn -> File.rm(hold_flag) end)

    %{
      binary: binary,
      db: db,
      deny_flag: deny_flag,
      env_log: Path.join(root, "workload-env.log"),
      gateway_config: gateway_config,
      home: home,
      hold_flag: hold_flag,
      machine: machine,
      prebind_mode: prebind_mode,
      release_stamp: release_stamp,
      root: root,
      tmpdir: tmpdir,
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

    # Checked HERE and not in the denied case because only a workload that
    # actually exec'd can report what it was handed; the denied case proves the
    # opposite thing, that nothing exec'd at all.
    assert_environment_closed(ctx, [
      "TIGHTBEAM_BASE_DIR",
      "TIGHTBEAM_MACHINE",
      "PATH",
      "HOME",
      "TMPDIR",
      "TB_F6_EXEC_LOG",
      "TB_F6_ENV_LOG",
      "TB_F6_RELEASE_STAMP"
    ])

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

  test "the sweeper physically stops an expired live lease and is idempotent", ctx do
    exec_log = Path.join(ctx.root, "expired-live-exec.log")
    File.write!(ctx.hold_flag, "keep the fixture alive until custody stops it")

    ceremony = Task.async(fn -> onboard(ctx, exec_log) end)

    assert_receive {:custody, "process-open", process_id}, 30_000
    assert_receive {:custody, "process-bind", ^process_id}, 30_000
    assert eventually(fn -> File.exists?(exec_log) end)

    running = ManagedProcesses.get(ctx.db, process_id)
    assert running.state == "running"
    assert running.brokerIdentity

    expired_at = System.system_time(:millisecond) - 1

    {:ok, {:ok, expired}} =
      DB.transaction(ctx.db, fn txn ->
        ManagedProcesses.transition(
          txn,
          process_id,
          [state: "running", revision: running.revision],
          %{state: "running", lease_expires_at: expired_at, now: expired_at}
        )
      end)

    assert expired.leaseExpiresAt == expired_at

    first = Gateway.sweep_process_custody(ctx.gateway_config)
    assert first.reconciled == 1

    {_, status} = Task.await(ceremony, 30_000)
    assert status != 0, "the live workload reported success after its lease-expiry stop"

    settled = ManagedProcesses.get(ctx.db, process_id)
    assert settled.state in ["killed", "exited"]
    assert settled.stopCause == "lease_expired"
    assert settled.resolvedAt

    second = Gateway.sweep_process_custody(ctx.gateway_config)
    repeated = ManagedProcesses.get(ctx.db, process_id)

    assert second.reconciled == 0
    assert repeated.revision == settled.revision
    assert repeated.state == settled.state
  end

  test "restart before and after the deadline keeps an artifact-free broker exit honest", ctx do
    exec_log = Path.join(ctx.root, "prebind-no-artifact-exec.log")
    File.write!(ctx.prebind_mode, "before-artifact")

    {output, status} = onboard(ctx, exec_log)
    assert status != 0, "the broker unexpectedly survived the pre-artifact refusal: #{output}"

    assert_receive {:custody, "process-open", process_id}, 30_000
    refute File.exists?(exec_log), "the workload ran before identity binding"
    refute File.exists?(identity_path(ctx, process_id))

    force_launch_deadline(ctx.db, process_id, System.system_time(:millisecond) + 60_000)
    before = ManagedProcesses.get(ctx.db, process_id)

    Gateway.recover_process_custody(ctx.gateway_config)
    waiting = ManagedProcesses.get(ctx.db, process_id)
    assert waiting.state == "preparing"
    assert waiting.revision == before.revision

    force_launch_deadline(ctx.db, process_id, System.system_time(:millisecond) - 1)
    Gateway.recover_process_custody(ctx.gateway_config)

    unknown = ManagedProcesses.get(ctx.db, process_id)
    assert unknown.state == "identity_unknown"
    assert unknown.uncertaintyCause == "launch_handoff_unknown"
    assert unknown.stopCause == nil

    Gateway.recover_process_custody(ctx.gateway_config)
    assert ManagedProcesses.get(ctx.db, process_id).revision == unknown.revision
  end

  test "restart binds a real live pre-exec identity and the broker releases that revision", ctx do
    exec_log = Path.join(ctx.root, "prebind-recovered-live-exec.log")
    File.write!(ctx.prebind_mode, "pause-before-commit")

    ceremony = Task.async(fn -> onboard(ctx, exec_log) end)

    assert_receive {:custody, "process-open", process_id}, 30_000
    assert_receive {:custody_bind_waiting, ^process_id, bind_handler}, 30_000
    assert File.exists?(identity_path(ctx, process_id))
    refute File.exists?(exec_log), "the workload crossed the pre-exec barrier before recovery"

    assert %{reconciled: 1} = Gateway.recover_process_custody(ctx.gateway_config)
    recovered = ManagedProcesses.get(ctx.db, process_id)
    assert recovered.state == "running"
    assert recovered.releaseGrantedAt
    assert recovered.brokerIdentity == identity_path(ctx, process_id)

    send(bind_handler, :continue_bind)
    assert_receive {:custody, "process-bind", ^process_id}, 30_000

    {output, status} = Task.await(ceremony, 30_000)
    assert status == 0, "the recovered broker did not release the proven revision: #{output}"
    assert File.read!(exec_log) =~ "stamp=present"

    assert {_, 0} = process_reconcile(ctx, process_id)
    assert ManagedProcesses.get(ctx.db, process_id).state in ManagedProcesses.terminal_states()
  end

  test "restart proves absence after the real broker exits between artifact and identity commit",
       ctx do
    exec_log = Path.join(ctx.root, "prebind-artifact-exit-exec.log")
    File.write!(ctx.prebind_mode, "after-artifact")

    {output, status} = onboard(ctx, exec_log)
    assert status != 0, "the broker unexpectedly committed identity: #{output}"

    assert_receive {:custody, "process-open", process_id}, 30_000
    assert_receive {:custody, "process-bind", ^process_id}, 30_000
    refute File.exists?(exec_log), "the workload ran after the bind request failed"
    assert File.exists?(identity_path(ctx, process_id))
    assert ManagedProcesses.get(ctx.db, process_id).state == "preparing"

    assert %{reconciled: 1} = Gateway.recover_process_custody(ctx.gateway_config)
    settled = ManagedProcesses.get(ctx.db, process_id)
    assert settled.state == "launch_failed"
    assert settled.lastError == "launch_timeout"
    assert settled.resolvedAt

    assert %{reconciled: 0} = Gateway.recover_process_custody(ctx.gateway_config)
    assert ManagedProcesses.get(ctx.db, process_id).revision == settled.revision
  end

  # A ceremony run of the REAL built CLI. `TIGHTBEAM_MACHINE` is required rather
  # than convenient: without a `gateway.json` the CLI refuses to guess which
  # machine it is onboarding, which is the correct refusal and not one this test
  # should route around.
  defp onboard(ctx, exec_log) do
    System.cmd(ctx.binary, ["onboard", "openai"],
      cd: ctx.workdir,
      stderr_to_stdout: true,
      env:
        closed_env([
          {"TIGHTBEAM_BASE_DIR", ctx.root},
          {"TIGHTBEAM_MACHINE", ctx.machine},
          {"PATH", Path.join(ctx.root, "harness-bin") <> ":/usr/bin:/bin"},
          {"HOME", ctx.home},
          {"TMPDIR", ctx.tmpdir},
          {"TB_F6_EXEC_LOG", exec_log},
          {"TB_F6_HOLD_FILE", ctx.hold_flag},
          {"TB_F6_ENV_LOG", ctx.env_log},
          {"TB_F6_RELEASE_STAMP", ctx.release_stamp}
        ])
    )
  end

  defp process_reconcile(ctx, process_id) do
    System.cmd(ctx.binary, ["process-reconcile", process_id],
      cd: ctx.workdir,
      stderr_to_stdout: true,
      env:
        closed_env([
          {"TIGHTBEAM_BASE_DIR", ctx.root},
          {"PATH", "/usr/bin:/bin"},
          {"HOME", ctx.home},
          {"TMPDIR", ctx.tmpdir}
        ])
    )
  end

  # `System.cmd/3` MERGES `env:` into the parent environment — it does not
  # replace it. An allowlist alone therefore proves NOTHING about isolation:
  # every variable the test runner happened to hold, credentials included,
  # still reached the workload, which is exactly what made this test's
  # "no credential in reach" claim unearned (review att_c36308f5 F6).
  #
  # Passing `{name, nil}` is how `System.cmd/3` REMOVES a variable, so closing
  # the environment means naming every inherited variable outside the allowlist
  # and removing it. Built from `System.get_env/0` at call time rather than from
  # a fixed deny list, because the leak to worry about is the variable nobody
  # thought to name.
  defp closed_env(allowed) do
    kept = MapSet.new(allowed, fn {name, _value} -> name end)

    allowed ++
      for {name, _value} <- System.get_env(), not MapSet.member?(kept, name), do: {name, nil}
  end

  # The claim, OBSERVED rather than argued: the fixture dumps the environment it
  # was actually handed, and nothing the test runner holds outside the allowlist
  # may have REACHED it. Anything the CLI itself adds on the way down is ours and
  # is not inheritance, so it is not what this checks; the second assertion
  # covers those by shape instead.
  #
  # A leak is judged by VALUE, not by name: a variable leaked only if the
  # RUNNER'S value for it arrived downstream. The fixture is a shell, and a shell
  # defines a few names of its own no matter what it is handed — `PWD` from
  # `getcwd`, `SHLVL` and `_` at startup. Those collide with names the runner
  # also holds while carrying none of the runner's data, so they are named here
  # rather than left to a value comparison that `SHLVL=1` could pass by
  # coincidence. None of them can carry a credential.
  @shell_defined ~w(PWD OLDPWD SHLVL _)

  defp assert_environment_closed(ctx, allowed_names) do
    received =
      ctx.env_log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, "=", parts: 2) do
          [name, value] -> [{name, value}]
          _ -> []
        end
      end)
      |> Map.new()

    inherited =
      System.get_env()
      |> Enum.filter(fn {name, value} ->
        name not in allowed_names and name not in @shell_defined and
          Map.get(received, name) == value
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert inherited == [],
           "the workload inherited #{inspect(inherited)} from the test runner; " <>
             "the isolation this proof claims does not hold"

    secretish =
      received
      |> Map.keys()
      |> Enum.filter(&Regex.match?(~r/KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL/i, &1))
      |> Enum.reject(&String.starts_with?(&1, "TB_F6_"))
      |> Enum.sort()

    assert secretish == [],
           "the workload was handed credential-shaped variables #{inspect(secretish)}"
  end

  # The two custody verbs are wrapped, not replaced: the real handler decides,
  # and the wrapper only observes it and — for the denied case — commits a
  # legitimate stop through the ordinary verb at the one moment that makes the
  # denial deterministic.
  defp instrument(handlers, db, test_pid, deny_flag, prebind_mode, release_stamp) do
    Map.new(handlers, fn
      {"process-open" = verb, handler} ->
        {verb,
         fn call ->
           result = handler.(call)
           id = process_id(result)
           if id && File.exists?(deny_flag), do: stop_row(db, id)
           send(test_pid, {:custody, verb, id})

           if prebind_mode(prebind_mode) == "before-artifact" do
             %{code: "server_error", message: "fixture stopped the broker before spawn"}
           else
             result
           end
         end}

      {"process-bind" = verb, handler} ->
        {verb,
         fn call ->
           id = call.params[:process_id]

           case prebind_mode(prebind_mode) do
             "after-artifact" ->
               send(test_pid, {:custody, verb, id})

               %{
                 code: "server_error",
                 message: "fixture stopped the broker before identity commit"
               }

             "pause-before-commit" ->
               send(test_pid, {:custody_bind_waiting, id, self()})

               receive do
                 :continue_bind -> :ok
               after
                 30_000 -> raise "fixture timed out waiting to continue process-bind"
               end

               result = handler.(call)
               File.write!(release_stamp, "bind answered")
               send(test_pid, {:custody, verb, process_id(result)})
               result

             _ ->
               result = handler.(call)
               File.write!(release_stamp, "bind answered")
               send(test_pid, {:custody, verb, process_id(result)})
               result
           end
         end}

      {verb, handler} ->
        {verb, handler}
    end)
  end

  defp process_id(%{process: %{"processId" => id}}), do: id
  defp process_id(_other), do: nil

  defp prebind_mode(path) do
    case File.read(path) do
      {:ok, mode} -> String.trim(mode)
      {:error, :enoent} -> nil
    end
  end

  defp identity_path(ctx, process_id) do
    Path.join([ctx.root, "process-custody", "#{process_id}.identity"])
  end

  defp force_launch_deadline(db, process_id, deadline) do
    {:ok, _} =
      DB.query(
        db,
        "UPDATE managed_processes SET launchDeadline = ?1 WHERE processId = ?2",
        [deadline, process_id]
      )
  end

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
  # already been granted at the instant it became this program. It also dumps
  # the environment it was handed, which is the only place the isolation claim
  # can be checked from — the test cannot see what the CLI passed down.
  defp fixture_script do
    """
    #!/bin/sh
    env > "$TB_F6_ENV_LOG"
    if [ -e "$TB_F6_RELEASE_STAMP" ]; then stamp=present; else stamp=absent; fi
    pgid=`ps -o pgid= -p $$ | tr -d ' '`
    printf 'argv=%s stamp=%s pid=%s pgid=%s\\n' "$*" "$stamp" "$$" "$pgid" >> "$TB_F6_EXEC_LOG"
    while [ -n "${TB_F6_HOLD_FILE:-}" ] && [ -e "$TB_F6_HOLD_FILE" ]; do sleep 0.05; done
    printf '%s' '{"tokens":{"access_token":"tb-f6-synthetic-not-a-credential"}}' > "$CODEX_HOME/auth.json"
    exit 0
    """
  end

  defp eventually(check, attempts \\ 200)

  defp eventually(check, attempts) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end
end
