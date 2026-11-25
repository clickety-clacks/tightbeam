defmodule Tightbeam.Harness.ClaudeCliReadinessTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.{Claude, ClaudeCli, Support}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    modules = Path.join(root, "node_modules")
    package = Path.join(modules, "@agentclientprotocol/claude-agent-acp")
    entry = Path.join(package, "dist/adapter.js")
    adapter = Claude.installed_adapter(root)
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
    node_dir = Path.dirname(System.find_executable("node"))
    path = Path.dirname(path_cli) <> ":" <> node_dir <> ":/usr/bin:/bin"

    %{
      root: root,
      adapter: adapter,
      manifest: manifest,
      bundled: bundled,
      path: path,
      path_cli: path_cli
    }
  end

  test "a stale satellite reports the bundled CLI version and the required ACP pin", ctx do
    write_package(ctx.manifest, "0.59.0")
    write_cli(ctx.bundled, "2.1.207")

    opts = satellite_opts(ctx)

    assert {:error, %{code: "claude_cli_unready", message: message}} =
             ClaudeCli.prepare_launch(opts, "satellite", &satellite/1)

    assert message =~ "satellite"
    assert message =~ "bundled Claude Code executable reports 2.1.207"
    assert message =~ "2.1.280 or newer"
    assert message =~ "ACP package must be reconciled"
  end

  test "a stale ACP package needs reconciliation before a cold launch", ctx do
    write_package(ctx.manifest, "0.59.0")
    write_cli(ctx.bundled, "2.1.207")
    write_cli(ctx.path_cli, "2.1.322")

    assert {:error, %{message: message}} =
             ClaudeCli.prepare_launch(satellite_opts(ctx), "satellite", &satellite/1)

    assert message =~ "ACP package must be reconciled to #{Claude.adapter_version()}"
  end

  test "a supported bundle is used when PATH has no supported CLI", ctx do
    write_cli(ctx.bundled, "2.1.280")
    write_cli(ctx.path_cli, "2.1.280-dev")
    assert {:ok, opts} = ClaudeCli.prepare_launch(local_opts(ctx), "local", &run/1)
    assert launch_pin(opts) == ctx.bundled

    assert {:ok, opts} = ClaudeCli.prepare_launch(satellite_opts(ctx), "satellite", &satellite/1)
    assert launch_pin(opts) == ctx.bundled
  end

  test "a supported PATH CLI is passed to ACP for local and satellite launches", ctx do
    write_cli(ctx.path_cli, "2.1.322")
    write_cli(ctx.bundled, "2.1.207")

    assert {:ok, opts} = ClaudeCli.prepare_launch(local_opts(ctx), "local", &run/1)
    assert launch_pin(opts) == ctx.path_cli

    assert {:ok, opts} = ClaudeCli.prepare_launch(satellite_opts(ctx), "satellite", &satellite/1)
    assert launch_pin(opts) == ctx.path_cli
  end

  test "a valid override takes precedence over a supported PATH CLI", ctx do
    write_cli(ctx.bundled, "2.1.207")
    write_cli(ctx.path_cli, "2.1.322")
    override = Path.join(ctx.root, "custom cli")
    write_cli(override, "2.1.322")

    opts = local_opts(ctx, [{"CLAUDE_CODE_EXECUTABLE", override}])
    assert {:ok, opts} = ClaudeCli.prepare_launch(opts, "local", &run/1)
    assert launch_pin(opts) == override

    opts = satellite_opts(ctx, ["CLAUDE_CODE_EXECUTABLE=" <> Support.shell_quote(override)])
    assert {:ok, opts} = ClaudeCli.prepare_launch(opts, "satellite", &satellite/1)
    assert launch_pin(opts) == override
  end

  test "an old explicit override is refused even when the bundle is supported", ctx do
    write_cli(ctx.bundled, "2.1.280")
    override = Path.join(ctx.root, "old")
    write_cli(override, "2.1.207")

    opts = local_opts(ctx, [{"CLAUDE_CODE_EXECUTABLE", override}])
    assert {:error, %{message: message}} = ClaudeCli.prepare_launch(opts, "local", &run/1)
    assert message =~ "CLAUDE_CODE_EXECUTABLE override reports 2.1.207"
  end

  test "a JavaScript override is checked using Node like the SDK launches it", ctx do
    override = Path.join(ctx.root, "claude.mjs")
    File.write!(override, "console.log('2.1.322 (Claude Code)');\n")

    opts = local_opts(ctx, [{"CLAUDE_CODE_EXECUTABLE", override}])
    assert {:ok, opts} = ClaudeCli.prepare_launch(opts, "local", &run/1)
    assert launch_pin(opts) == override
  end

  defp launch_pin(opts) do
    if opts[:process_ssh], do: remote_launch_pin(opts), else: local_launch_pin(opts)
  end

  defp local_launch_pin(opts) do
    {_, path} = List.keyfind(opts[:env], "CLAUDE_CODE_EXECUTABLE", 0)
    path
  end

  defp remote_launch_pin(opts) do
    assert List.last(opts[:cmd]) =~ "/.bin/claude-agent-acp"
    "CLAUDE_CODE_EXECUTABLE=" <> quoted = Enum.at(opts[:cmd], -2)
    {path, 0} = run(["/bin/sh", "-c", "printf %s " <> quoted])
    path
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
