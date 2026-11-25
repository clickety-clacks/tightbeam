defmodule Tightbeam.Harness.ClaudeCliReadinessTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.{Claude, ClaudeCli, Support}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    modules = Path.join(root, "node_modules")
    package = Path.join(modules, "@agentclientprotocol/claude-agent-acp")
    entry = Path.join(package, "dist/adapter.js")
    adapter = Path.join(modules, ".bin/claude-agent-acp")
    manifest = Path.join(package, "package.json")
    File.mkdir_p!(Path.dirname(adapter))
    File.mkdir_p!(Path.dirname(entry))
    write_executable(entry, "exit 1")
    File.ln_s!(entry, adapter)
    write_package(manifest, Claude.adapter_version())
    bundled = Path.join(package, "fixtures/claude")

    File.write!(Path.join(package, "dist/acp-agent.js"), """
    export async function claudeCliPath() {
      return #{JSON.encode!(bundled)};
    }
    """)

    path_cli = Path.join(root, "bin/claude")
    write_cli(path_cli, "2.1.322")
    path = Path.dirname(path_cli) <> ":" <> System.fetch_env!("PATH")
    %{root: root, adapter: adapter, manifest: manifest, bundled: bundled, path: path}
  end

  test "a stale satellite refuses before launch even with a newer CLI on PATH", ctx do
    write_package(ctx.manifest, "0.59.0")
    write_cli(ctx.bundled, "2.1.207")

    opts = satellite_opts(ctx)

    assert {:error, %{code: "claude_cli_unready", message: message}} =
             ClaudeCli.check_launch(opts, "satellite", &satellite/1)

    assert message =~ "satellite"
    assert message =~ "bundled Claude Code executable reports 2.1.207"
    assert message =~ "2.1.280 or newer"
    assert message =~ "ACP package must be reconciled"
  end

  test "a stale ACP package needs reconciliation before a cold launch", ctx do
    write_package(ctx.manifest, "0.59.0")
    write_cli(ctx.bundled, "2.1.322")

    assert {:error, %{message: message}} =
             ClaudeCli.check_launch(satellite_opts(ctx), "satellite", &satellite/1)

    assert message =~ "ACP package must be reconciled to #{Claude.adapter_version()}"
  end

  test "a fresh install runs the bundled CLI at the supported floor", ctx do
    write_cli(ctx.bundled, "2.1.280")
    assert :ok = ClaudeCli.check_launch(local_opts(ctx), "local", &run/1)
    assert :ok = ClaudeCli.check_launch(satellite_opts(ctx), "satellite", &satellite/1)
  end

  test "a valid override takes precedence over an old bundle", ctx do
    write_cli(ctx.bundled, "2.1.207")
    override = Path.join(ctx.root, "custom cli")
    write_cli(override, "2.1.322")

    opts = local_opts(ctx, [{"CLAUDE_CODE_EXECUTABLE", override}])
    assert :ok = ClaudeCli.check_launch(opts, "local", &run/1)

    opts = satellite_opts(ctx, ["CLAUDE_CODE_EXECUTABLE=" <> Support.shell_quote(override)])
    assert :ok = ClaudeCli.check_launch(opts, "satellite", &satellite/1)
  end

  test "an old explicit override is refused even when the bundle is supported", ctx do
    write_cli(ctx.bundled, "2.1.280")
    override = Path.join(ctx.root, "old")
    write_cli(override, "2.1.207")

    opts = local_opts(ctx, [{"CLAUDE_CODE_EXECUTABLE", override}])
    assert {:error, %{message: message}} = ClaudeCli.check_launch(opts, "local", &run/1)
    assert message =~ "CLAUDE_CODE_EXECUTABLE override reports 2.1.207"
  end

  test "a JavaScript override is checked using Node like the SDK launches it", ctx do
    override = Path.join(ctx.root, "claude.mjs")
    File.write!(override, "console.log('2.1.322 (Claude Code)');\n")

    opts = local_opts(ctx, [{"CLAUDE_CODE_EXECUTABLE", override}])
    assert :ok = ClaudeCli.check_launch(opts, "local", &run/1)
  end

  defp local_opts(ctx, extra_env \\ []) do
    [cmd: [ctx.adapter], cwd: ctx.root, env: [{"PATH", ctx.path} | extra_env]]
  end

  defp satellite_opts(ctx, extra_env \\ []) do
    [
      process_ssh: "satellite",
      cmd:
        ["ssh", "satellite", "exec", "env", "PATH=" <> Support.shell_quote(ctx.path)] ++
          extra_env ++ ["ANTHROPIC_API_KEY=$(exit 99)", ctx.adapter]
    ]
  end

  defp satellite(["ssh", "satellite" | command]) do
    refute Enum.any?(command, &String.contains?(&1, "ANTHROPIC_API_KEY"))
    run(["/bin/sh", "-c", Enum.join(command, " ")])
  end

  defp run([executable | args]) do
    System.cmd(executable, args, stderr_to_stdout: true, env: [{"CLAUDE_CODE_EXECUTABLE", nil}])
  end

  defp write_package(manifest, version) do
    File.write!(
      manifest,
      JSON.encode!(%{name: Claude.install_package(), version: version, type: "module"})
    )
  end

  defp write_cli(path, version), do: write_executable(path, "echo '#{version} (Claude Code)'")

  defp write_executable(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
  end
end
