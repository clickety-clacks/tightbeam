defmodule Tightbeam.SpinupTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, EventLog, Spinup}

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-spinup-#{System.unique_integer([:positive])}")
    db = :"spinup_db_#{System.unique_integer([:positive])}"
    File.mkdir_p!(base_dir)
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = EventLog.ensure_schema(db)
    old_hosts = Application.get_env(:tightbeam, :hosts)

    on_exit(fn ->
      File.rm_rf!(base_dir)

      if old_hosts,
        do: Application.put_env(:tightbeam, :hosts, old_hosts),
        else: Application.delete_env(:tightbeam, :hosts)
    end)

    %{base_dir: base_dir, db: db}
  end

  test "local all-present allows without shell calls and records history", ctx do
    credential = Path.join([ctx.base_dir, "auth", "claude", "oauth-token"])
    File.mkdir_p!(Path.dirname(credential))
    File.write!(credential, "test-token")
    stage_claude!(ctx.base_dir)
    parent = self()

    sh = fn command ->
      send(parent, {:unexpected_shell, command})
      {"", 0}
    end

    assert :ok =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :claude, "testhost",
               db: ctx.db,
               sh: sh,
               patch_adapter: no_patch()
             )

    refute_received {:unexpected_shell, _}
    assert File.dir?(Path.join(ctx.base_dir, "work"))
    assert File.dir?(Path.join(ctx.base_dir, "homes"))

    assert [%{kind: "spinup", subject: "claude@testhost", detail: detail}] =
             EventLog.lifecycle_events(ctx.db)

    assert detail =~ "adapters present"
    assert detail =~ "credentials present"
  end

  test "local adapter missing denies with the base_dir path, not a sibling checkout", ctx do
    sandbox = Path.join(ctx.base_dir, "cwd")
    File.mkdir_p!(sandbox)

    result =
      File.cd!(sandbox, fn ->
        Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :codex, "testhost", db: ctx.db)
      end)

    expected = Path.join([ctx.base_dir, "adapters", "node_modules", ".bin", "codex-acp"])
    assert {:error, %{code: "host_unready", message: message}} = result
    assert message =~ "adapter missing"
    assert message =~ expected

    # The remedy names the host's own adapters directory. It used to send the
    # operator to a sibling checkout of the retired TypeScript project (#46).
    assert message =~ Path.join(ctx.base_dir, "adapters")
    refute message =~ "local Tightbeam checkout"
    refute message =~ "src/tightbeam/node_modules"
    assert [%{kind: "spinup", detail: "reached;" <> _}] = EventLog.lifecycle_events(ctx.db)
  end

  test "local directory setup failure names the permissions remedy", ctx do
    work_path = Path.join(ctx.base_dir, "work")
    File.write!(work_path, "not a directory")

    assert {:error, %{code: "host_unready", message: message}} =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :claude, "testhost", db: ctx.db)

    assert message =~ "directory setup failed at #{work_path}"
    assert message =~ "fix directory permissions on testhost"
  end

  test "missing credentials denies with path and setup ceremony", ctx do
    auth_dir = Path.join([ctx.base_dir, "auth", "claude"])
    stage_claude!(ctx.base_dir)

    assert {:error, %{code: "host_unready", message: message}} =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :claude, "testhost",
               db: ctx.db,
               patch_adapter: no_patch()
             )

    assert message =~ "no claude credentials in #{auth_dir}"
    assert message =~ "run the setup ceremony on testhost"
    assert [%{kind: "spinup", detail: detail}] = EventLog.lifecycle_events(ctx.db)
    assert detail =~ "DENIED"
  end

  test "remote readiness uses quoted commands and records allow", ctx do
    remote_base = "/srv/tight beam/o'hare"

    Application.put_env(:tightbeam, :hosts, %{
      "worker" => %{ssh: "worker.example", base_dir: remote_base, cli_bin: nil}
    })

    parent = self()

    sh = fn command ->
      send(parent, {:command, command})
      {"", 0}
    end

    assert :ok =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :claude, "worker",
               db: ctx.db,
               sh: sh
             )

    commands = receive_commands(4)

    assert ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "worker.example", "true"] =
             hd(commands)

    for command <- tl(commands) do
      assert Enum.take(command, -3) |> Enum.take(2) == ["sh", "-c"]
      assert String.starts_with?(List.last(command), "'")
      assert String.ends_with?(List.last(command), "'")
    end

    assert List.last(Enum.at(commands, 1)) =~ "mkdir -p"
    assert List.last(Enum.at(commands, 1)) =~ "tight beam"
    refute Enum.any?(commands, &(hd(&1) in ["scp", "rsync"]))
    assert [%{kind: "spinup", detail: detail}] = EventLog.lifecycle_events(ctx.db)
    assert detail =~ "credentials present"
  end

  test "remote missing adapter deploys both packages and rechecks", ctx do
    configure_remote(ctx.base_dir)
    {:ok, checks} = Agent.start_link(fn -> 0 end)
    parent = self()

    sh = fn command ->
      send(parent, {:command, command})
      script = List.last(command)

      if String.contains?(script, "test -x") do
        check = Agent.get_and_update(checks, &{&1, &1 + 1})
        if check == 0, do: {"", 1}, else: {"", 0}
      else
        {"", 0}
      end
    end

    assert :ok =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :codex, "worker",
               db: ctx.db,
               sh: sh
             )

    commands = receive_commands(6)
    install = Enum.find(commands, &String.contains?(List.last(&1), "npm install"))
    assert List.last(install) =~ "--prefix"

    # PINNED, not bare (#47): a bare name resolves to npm's latest, so every
    # provision installed whatever was published that day while @adapter_version
    # documented a pin nothing enforced. Measured on main: claude-agent-acp 0.62.0
    # and codex-acp 1.1.7 against pins of 0.59.0 and 1.1.4.
    for module <- Tightbeam.Harness.all() do
      assert List.last(install) =~ "#{module.install_package()}@#{module.adapter_version()}",
             "#{module.wire_name()} is not installed at its pinned version"
    end

    # ...and no bare name survives, which is what the pin is protecting against.
    for module <- Tightbeam.Harness.all() do
      refute List.last(install) =~ "#{module.install_package()} ",
             "#{module.wire_name()} still has an unpinned occurrence in the install line"

      refute String.ends_with?(List.last(install), module.install_package()),
             "#{module.wire_name()} trails the install line unpinned"
    end

    assert Enum.count(commands, &String.contains?(List.last(&1), "test -x")) == 2
    assert [%{detail: detail}] = EventLog.lifecycle_events(ctx.db)
    assert detail =~ "deployed adapters"
  end

  test "remote npm failure denies with command output", ctx do
    configure_remote(ctx.base_dir)

    sh = fn command ->
      script = List.last(command)

      cond do
        String.contains?(script, "test -x") -> {"", 1}
        String.contains?(script, "npm install") -> {"npm: command not found", 127}
        true -> {"", 0}
      end
    end

    assert {:error, %{code: "host_unready", message: message}} =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :claude, "worker",
               db: ctx.db,
               sh: sh
             )

    assert message =~ "npm: command not found"
    assert message =~ "install Node.js/npm and the ACP adapters on worker"
    assert [%{kind: "spinup", detail: detail}] = EventLog.lifecycle_events(ctx.db)
    assert detail =~ "DENIED"
  end

  test "remote adapter still missing after deployment names the verification remedy", ctx do
    configure_remote(ctx.base_dir)

    sh = fn command ->
      if String.contains?(List.last(command), "test -x"), do: {"not found", 1}, else: {"", 0}
    end

    assert {:error, %{code: "host_unready", message: message}} =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :codex, "worker",
               db: ctx.db,
               sh: sh
             )

    assert message =~ "adapter still missing"
    assert message =~ "verify the ACP adapter installation on worker"
  end

  test "remote directory setup failure names the permissions remedy", ctx do
    configure_remote(ctx.base_dir)

    sh = fn command ->
      if String.contains?(List.last(command), "mkdir -p"),
        do: {"permission denied", 1},
        else: {"", 0}
    end

    assert {:error, %{code: "host_unready", message: message}} =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :claude, "worker",
               db: ctx.db,
               sh: sh
             )

    assert message =~ "directory setup failed: permission denied"
    assert message =~ "fix directory permissions on worker"
  end

  test "unreachable host denies with ssh output and records history", ctx do
    configure_remote(ctx.base_dir)
    parent = self()

    sh = fn command ->
      send(parent, {:command, command})
      {"connection refused", 255}
    end

    assert {:error, %{code: "host_unready", message: message}} =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :claude, "worker",
               db: ctx.db,
               sh: sh
             )

    assert message =~ "host worker is unreachable: connection refused"
    assert message =~ "check SSH access to worker"
    assert [_reach] = receive_commands(1)
    assert [%{kind: "spinup", detail: detail}] = EventLog.lifecycle_events(ctx.db)
    assert detail =~ "DENIED"
  end

  defp configure_remote(local_base) do
    Application.put_env(:tightbeam, :hosts, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: nil}
    })

    local_base
  end

  defp receive_commands(count), do: receive_commands(count, [])
  defp receive_commands(0, commands), do: Enum.reverse(commands)

  defp receive_commands(count, commands) do
    receive do
      {:command, command} -> receive_commands(count - 1, [command | commands])
    after
      1_000 -> flunk("timed out collecting spinup commands")
    end
  end

  # The adapter lives under the host's OWN base_dir now (no sibling checkout), so
  # "already present" has to be staged there.
  # Adapter presence only — patching has its own tests, and is injected as a
  # no-op here so these stay about presence and credentials.
  defp stage_claude!(base_dir) do
    path = Path.join([base_dir, "adapters", "node_modules", ".bin", "claude-agent-acp"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  defp no_patch, do: fn _harness, _path -> :ok end
end
