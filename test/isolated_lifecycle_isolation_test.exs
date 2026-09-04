defmodule Tightbeam.IsolatedLifecycleIsolationTest do
  # Phase-1 regression suite for teardown-isolation v4-final-r2. Reuses the
  # shape of merge_gate_isolation_test.exs (shim/env-poison harness) and the
  # shared production-identity scrub definition (scripts/production-identity-env,
  # via Tightbeam.ProductionIdentityEnv).
  #
  # The incident: a test teardown ran `stop` in an environment where the
  # production systemd unit had exported RELEASE_NODE/TIGHTBEAM_PORT to it; the
  # mix release resolved `stop` by node name, the inherited RELEASE_NODE won, and
  # the shared cookie let the test's `stop` halt PRODUCTION :11373.
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Placement

  @shim Path.expand("../packaging/tightbeam-gateway", __DIR__)

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tb-iso-lifecycle-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    db = :"iso_lifecycle_db_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{base_dir: base_dir, db: db}
  end

  # ── Case 1 — shim/pid-stop, the exact incident repro (Phase 1) ─────────────

  test "stop SIGTERMs only the descriptor's owned pid — production survives the poisoned env" do
    {prod_port, prod_pid, _prod_cmd} = spawn_standin()
    {iso_port, iso_pid, iso_cmd} = spawn_standin()

    iso_dir = Path.join(System.tmp_dir!(), "tb-iso-#{System.unique_integer([:positive])}")

    write_descriptor(iso_dir, %{
      port: 11_484,
      cliToken: "tbc_iso",
      ownedPid: to_string(iso_pid),
      ownedCommand: iso_cmd
    })

    on_exit(fn ->
      File.rm_rf!(iso_dir)
      kill(prod_pid)
      kill(iso_pid)
      safe_close(prod_port)
      safe_close(iso_port)
    end)

    # The EXACT incident env: an inherited production node/port/name.
    {out, status} =
      System.cmd(@shim, ["stop"],
        env: [
          {"TIGHTBEAM_BASE_DIR", iso_dir},
          {"RELEASE_NODE", "tightbeam_gateway_11373"},
          {"TIGHTBEAM_PORT", "11484"},
          {"TIGHTBEAM_NODE", "tightbeam_gateway_11484"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "stop should succeed by pid-signal, got: #{out}"

    # It signalled by pid: the iso stand-in dies, the production stand-in lives.
    assert wait_until(fn -> process_command(iso_pid) == "" end),
           "the iso owned pid should have been SIGTERMed"

    assert process_command(prod_pid) != "",
           "the production stand-in must NOT be reached by a test stop"

    # It consulted no node/cookie: the stop path never runs erl/rpc/epmd, so its
    # output can name none of them.
    refute out =~ ~r/cookie|nodedown|epmd|RELEASE_COOKIE/i
  end

  test "stop refuses on a recycled pid rather than signalling somebody else's process" do
    {port, pid, _cmd} = spawn_standin()
    iso_dir = Path.join(System.tmp_dir!(), "tb-iso-#{System.unique_integer([:positive])}")

    # The pid is live but its command no longer matches the descriptor: the OS
    # recycled it. Signalling would kill an unrelated process.
    write_descriptor(iso_dir, %{
      port: 11_484,
      cliToken: "tbc_iso",
      ownedPid: to_string(pid),
      ownedCommand: "some-other-process --that-we-never-booted"
    })

    on_exit(fn ->
      File.rm_rf!(iso_dir)
      kill(pid)
      safe_close(port)
    end)

    {out, status} =
      System.cmd(@shim, ["stop"], env: [{"TIGHTBEAM_BASE_DIR", iso_dir}], stderr_to_stdout: true)

    assert status != 0, "stop must refuse a recycled pid"
    assert out =~ "recycled"
    assert process_command(pid) != "", "the recycled pid's process must survive"
  end

  # ── R1 — resolve from $TIGHTBEAM_BASE_DIR ONLY, refuse on absent (Phase 1) ──

  test "R1: a poisoned TIGHTBEAM_HOME with TIGHTBEAM_BASE_DIR unset is refused, not followed" do
    {out, status} =
      System.cmd(@shim, ["stop"],
        env: [{"TIGHTBEAM_BASE_DIR", nil}, {"TIGHTBEAM_HOME", "/production/org"}],
        stderr_to_stdout: true
      )

    assert status != 0, "no TIGHTBEAM_HOME fallback: stop must refuse"
    assert out =~ "TIGHTBEAM_BASE_DIR"
  end

  test "R1: an empty environment is refused — no ~/.tightbeam default" do
    {out, status} =
      System.cmd(@shim, ["stop"],
        env: [{"TIGHTBEAM_BASE_DIR", nil}, {"TIGHTBEAM_HOME", nil}],
        stderr_to_stdout: true
      )

    assert status != 0, "no default base dir: stop must refuse"
    assert out =~ "TIGHTBEAM_BASE_DIR"
  end

  # ── F1 — the restart verb is dropped (Phase 1) ─────────────────────────────

  test "F1: restart is removed and names its two replacements" do
    {out, status} =
      System.cmd(@shim, ["restart"], env: [{"TIGHTBEAM_BASE_DIR", nil}], stderr_to_stdout: true)

    assert status != 0
    assert out =~ "`restart` verb was removed"
    assert out =~ "stop"
    assert out =~ "start"
    assert out =~ "systemctl restart tightbeam"
  end

  # ── R3 — scrub inherited production identity at the real spawn seam ─────────

  test "R3: a spawned child keeps session identity but not production identity" do
    poison = %{
      "RELEASE_NODE" => "tightbeam_gateway_11373",
      "RELEASE_COOKIE" => "prod-shared-cookie",
      "TIGHTBEAM_BASE_DIR" => "/production/org",
      "TIGHTBEAM_PORT" => "11373"
    }

    for {k, v} <- poison, do: System.put_env(k, v)
    on_exit(fn -> for {k, _} <- poison, do: System.delete_env(k) end)

    out = Path.join(System.tmp_dir!(), "tb-r3-child-env-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(out) end)

    {:ok, conn} =
      Tightbeam.Acp.Conn.start_link(
        cmd: ["sh", "-c", "env > #{out}"],
        env: [{"TIGHTBEAM_HOME", "/session/home"}, {"PATH", System.fetch_env!("PATH")}],
        subscriber: self()
      )

    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    assert_receive {:acp_exit, _status}, 5_000

    child_env = File.read!(out)

    refute child_env =~ ~r/^RELEASE_NODE=/m
    refute child_env =~ ~r/^RELEASE_COOKIE=/m
    refute child_env =~ ~r/^TIGHTBEAM_BASE_DIR=/m
    refute child_env =~ ~r/^TIGHTBEAM_PORT=/m

    # Presence, not merely scrub-set absence: the session identity is re-provided.
    assert child_env =~ ~r{^TIGHTBEAM_HOME=/session/home$}m
  end

  # ── R9 — production-identity vars cannot be re-injected as a DB overlay ─────

  test "R9: production-identity env vars are rejected as reserved_env_name", %{db: db} do
    for name <- ~w(RELEASE_NODE RELEASE_COOKIE RELEASE_FUTURE_INPUT ROOTDIR BINDIR
                   TIGHTBEAM_BASE_DIR TIGHTBEAM_PORT TIGHTBEAM_NODE) do
      assert {:error, %{code: "reserved_env_name"}} =
               Placement.set_env_overlay(db, "testhost", "claude", name, "poison", "agent:test"),
             "#{name} must be reserved"
    end
  end

  test "R9: a non-identity var still passes the reservation guard", %{base_dir: base_dir, db: db} do
    register_hosts(db, %{"testhost" => %{ssh: "x", base_dir: base_dir, cli_bin: "/bin"}})

    assert {:ok, _row} =
             Placement.set_env_overlay(
               db,
               "testhost",
               "claude",
               "EXAMPLE_OK_VAR",
               "ok",
               "agent:test"
             )
  end

  # ── Case 2 — direct mix-script cookie backstop [N5: Phase-2-gated] ──────────

  @tag skip:
         "Phase-2-gated (N5): exercises the per-instance cookie (fix C), which ships in Phase 2"
  test "Case 2: direct release rpc at production is refused by the per-instance cookie" do
    flunk("Phase-2-gated placeholder — not implemented in Phase 1")
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp spawn_standin do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        {:args, ["-c", "exec sleep 300"]}
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    assert wait_until(fn -> process_command(pid) != "" end), "stand-in process failed to start"
    {port, pid, process_command(pid)}
  end

  defp process_command(pid) do
    case System.cmd("ps", ["-ww", "-o", "command=", "-p", to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> ""
    end
  end

  defp write_descriptor(dir, fields) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "gateway.json")
    File.write!(path, JSON.encode!(fields))
    File.chmod!(path, 0o600)
    path
  end

  defp kill(pid), do: System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

  # A signalled stand-in exits, which auto-closes its port; closing an
  # already-closed port raises, so guard it.
  defp safe_close(port) do
    if Port.info(port) != nil, do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp wait_until(fun, timeout \\ 5_000, interval \\ 25) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline, interval)
  end

  defp do_wait(fun, deadline, interval) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(interval)
        do_wait(fun, deadline, interval)
    end
  end
end
