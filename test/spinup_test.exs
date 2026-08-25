defmodule Tightbeam.SpinupTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, EventLog, Spinup}

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-spinup-#{System.unique_integer([:positive])}")
    db = :"spinup_db_#{System.unique_integer([:positive])}"
    File.mkdir_p!(base_dir)
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = EventLog.ensure_schema(db)
    :ok = Tightbeam.Placement.ensure_schema(db)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{base_dir: base_dir, db: db}
  end

  test "local all-present allows without shell calls and records history", ctx do
    credential = Path.join([ctx.base_dir, "auth", "claude", ".credentials.json"])
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

  test "Pi spinup accepts its selected named provider without OpenCode credentials", ctx do
    provider =
      Tightbeam.LocalOpenAi.Providers.provider_path(ctx.base_dir, "spark")

    File.mkdir_p!(Path.dirname(provider))

    File.write!(
      provider,
      JSON.encode!(%{
        "name" => "spark",
        "type" => "local-openai",
        "endpoint" => "https://spark.example/v1"
      })
    )

    stage_pi!(ctx.base_dir)

    assert :ok =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :pi, "testhost",
               db: ctx.db,
               patch_adapter: no_patch(),
               credential_provider: :local_openai,
               credential_names: ["spark.json"]
             )

    refute File.exists?(Path.join([ctx.base_dir, "auth", "pi", "auth.json"]))
  end

  # The gateway host used to be the only machine that could not supply its own adapters:
  # it refused and told the operator to go install them by hand, on the host tightbeam
  # was standing on. It provisions now, through the same mechanism the remote path uses
  # and at the same pinned versions (#46).
  test "local adapter missing provisions the pinned adapters into the host's base_dir", ctx do
    adapter = Path.join([ctx.base_dir, "adapters", "node_modules", ".bin", "codex-acp"])
    credential = Path.join([ctx.base_dir, "auth", "codex", "auth.json"])
    File.mkdir_p!(Path.dirname(credential))
    File.write!(credential, "test-token")
    parent = self()

    sh = fn command ->
      send(parent, {:command, command})
      # Stand in for npm by leaving the executable npm would leave — the local branch
      # confirms the install with File.exists?, so a mock that reports success without
      # producing the binary would prove the wrong thing.
      File.mkdir_p!(Path.dirname(adapter))
      File.write!(adapter, "#!/bin/sh\n")
      File.chmod!(adapter, 0o755)
      {"", 0}
    end

    assert :ok =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :codex, "testhost",
               db: ctx.db,
               sh: sh,
               patch_adapter: no_patch()
             )

    assert [["sh", "-c", script]] = receive_commands(1)

    # Local means local: no ssh hop to reach the machine tightbeam is running on.
    refute script =~ "ssh"
    assert script =~ "npm install --prefix"
    assert script =~ Path.join(ctx.base_dir, "adapters")

    # Every harness at its pin, asserted per harness rather than by naming packages —
    # a partial pin has to fail for the harness that lost it (#47).
    for module <- Tightbeam.Harness.all() do
      assert script =~ "#{module.install_package()}@#{module.adapter_version()}",
             "#{module.wire_name()} is not installed at its pinned version"
    end

    assert [%{kind: "spinup", detail: detail}] = EventLog.lifecycle_events(ctx.db)
    assert detail =~ "deployed adapters"
  end

  # An install is minutes of npm silence on a cold cache, indistinguishable from
  # a broken gateway unless it says so (#102). Every start line gets a closer —
  # complete or failed — and the client-e2e driver's readiness wait names an
  # open install by these exact phrases (LegGateway.await_runnable's hint), so
  # a rewording here must carry that hint with it.
  test "adapter provisioning logs a start line and a complete line", ctx do
    adapter = Path.join([ctx.base_dir, "adapters", "node_modules", ".bin", "codex-acp"])
    credential = Path.join([ctx.base_dir, "auth", "codex", "auth.json"])
    File.mkdir_p!(Path.dirname(credential))
    File.write!(credential, "test-token")

    sh = fn _command ->
      File.mkdir_p!(Path.dirname(adapter))
      File.write!(adapter, "#!/bin/sh\n")
      File.chmod!(adapter, 0o755)
      {"", 0}
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :codex, "testhost",
                   db: ctx.db,
                   sh: sh,
                   patch_adapter: no_patch()
                 )
      end)

    install_dir = Path.join(ctx.base_dir, "adapters")
    assert log =~ "installing ACP adapters into #{install_dir} on testhost"
    assert log =~ "ACP adapter install into #{install_dir} on testhost complete"
  end

  test "a failed install closes its start line with a failed line", ctx do
    sh = fn _command -> {"npm error code E404\nnot found", 1} end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %{code: "host_unready"}} =
                 Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :codex, "testhost",
                   db: ctx.db,
                   sh: sh
                 )
      end)

    install_dir = Path.join(ctx.base_dir, "adapters")
    assert log =~ "installing ACP adapters into #{install_dir} on testhost"
    assert log =~ "ACP adapter install into #{install_dir} on testhost failed"
  end

  test "local adapter install failure names the npm remedy for this host", ctx do
    sh = fn _command -> {"npm error code E404\nnot found", 1} end

    assert {:error, %{code: "host_unready", message: message}} =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :codex, "testhost",
               db: ctx.db,
               sh: sh
             )

    assert message =~ "adapter deployment failed"
    assert message =~ "E404"
    assert message =~ Path.join(ctx.base_dir, "adapters")
    assert message =~ "on testhost"
    assert [%{kind: "spinup", detail: detail}] = EventLog.lifecycle_events(ctx.db)
    assert detail =~ "DENIED:"
  end

  test "local install that leaves no binary says so instead of proceeding", ctx do
    adapter = Path.join([ctx.base_dir, "adapters", "node_modules", ".bin", "codex-acp"])
    sh = fn _command -> {"", 0} end

    assert {:error, %{code: "host_unready", message: message}} =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :codex, "testhost",
               db: ctx.db,
               sh: sh
             )

    assert message =~ "adapter still missing at #{adapter} after deployment"
    assert message =~ "reinstall the ACP adapters on testhost"
  end

  test "local directory setup failure names the permissions remedy", ctx do
    work_path = Path.join(ctx.base_dir, "work")
    File.write!(work_path, "not a directory")

    assert {:error, %{code: "host_unready", message: message}} =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :claude, "testhost", db: ctx.db)

    assert message =~ "directory setup failed at #{work_path}"
    assert message =~ "fix directory permissions on testhost"
  end

  test "missing credentials deny with separate login fact and exact remedy", ctx do
    auth_dir = Path.join(ctx.base_dir, "auth")
    stage_claude!(ctx.base_dir)

    assert {:error, %{code: "host_unready", message: message}} =
             Spinup.ensure_ready(%{base_dir: ctx.base_dir}, :claude, "testhost",
               db: ctx.db,
               patch_adapter: no_patch()
             )

    assert message =~ "Tightbeam has no credential for anthropic on testhost"
    assert message =~ "normal claude CLI login"
    assert message =~ "keeps its own credential under #{auth_dir}"
    assert message =~ "Run on testhost: tightbeam onboard anthropic --as-user <userId>"
    assert [%{kind: "spinup", detail: detail}] = EventLog.lifecycle_events(ctx.db)
    assert detail =~ "DENIED"
  end

  test "remote readiness uses quoted commands and records allow", ctx do
    remote_base = "/srv/tight beam/o'hare"

    register_hosts(ctx.db, %{
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
    configure_remote(ctx)
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
    configure_remote(ctx)

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
    configure_remote(ctx)

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
    configure_remote(ctx)

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
    configure_remote(ctx)
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

  defp configure_remote(ctx) do
    register_hosts(ctx.db, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: nil}
    })
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

  defp stage_pi!(base_dir) do
    path = Path.join([base_dir, "adapters", "node_modules", ".bin", "pi-acp"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  defp no_patch, do: fn _harness, _path -> :ok end
end
