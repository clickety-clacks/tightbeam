defmodule Tightbeam.RecoveryProbeStdinTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Placement}
  alias Tightbeam.Harness.{Claude, ClaudeCli, RecoveryProbe, Support}

  @codex_help ~w(--ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check -C -m -s -c
                 --disable --output-schema --json)
  @codex_features ~w(shell_tool unified_exec code_mode_host multi_agent apps plugins hooks
                     browser_use browser_use_external computer_use in_app_browser image_generation
                     view_image sleep_tool goals tool_suggest skill_search memories
                     workspace_dependencies skill_mcp_dependency_install)
  @claude_help ~w(-p --tools --model --safe-mode --strict-mcp-config --no-session-persistence
                  --output-format)

  setup do
    db = :"recovery_probe_stdin_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, db: db}
  end

  # Every CLI call reads standard input to end of file before answering, as
  # `codex exec` does. The check call also fails unless that input is empty.
  defp fake_cli!(dir, name, help, features, version \\ "2.1.322") do
    path = Path.join(dir, name)

    File.write!(path, """
    #!/bin/sh
    input=$(cat)
    [ -z "$input" ] || { echo "unexpected stdin" >&2; exit 9; }
    case "$1 $2" in
      "--version ") echo "#{version} (Claude Code)" ;;
      "exec --help"|"--help ") echo "#{Enum.join(help, " ")}" ;;
      "features list") echo "#{Enum.join(features, " ")}" ;;
      *) touch "$0.called" ;;
    esac
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp fake_ssh!(dir, warning \\ "") do
    # Like ssh: skip the options and host, give the rest to a shell, keep stdin open.
    path = Path.join(dir, "ssh")
    warning = if warning == "", do: "", else: warning <> "\n"

    File.write!(path, """
    #!/bin/sh
    printf %s #{Support.shell_quote(warning)} >&2
    while [ "$1" = "-o" ]; do shift 2; done
    shift
    exec sh -c "$*"
    """)

    File.chmod!(path, 0o755)
  end

  defp run(ctx, harness, binary, ssh, timeout_ms) do
    dir = ctx.tmp_dir
    host = "stdinhost"
    assert {:ok, _} = Placement.register_host(ctx.db, host, %{ssh: ssh, base_dir: dir})

    pin_name = if harness == "codex", do: "CODEX_PATH", else: "CLAUDE_CODE_EXECUTABLE"

    if binary do
      assert {:ok, _} = Placement.set_env_overlay(ctx.db, host, harness, pin_name, binary, "test")
    end

    route = %{
      "harness" => harness,
      "host" => host,
      "model" => "fixture-model",
      "sharedAccount" => "shared"
    }

    started = System.monotonic_time(:millisecond)
    result = RecoveryProbe.run_route(dir, ctx.db, route, timeout_ms)
    {result, System.monotonic_time(:millisecond) - started}
  end

  @tag :tmp_dir
  test "a Codex check finishes although the CLI waits for end of input", ctx do
    binary = fake_cli!(ctx.tmp_dir, "codex", @codex_help, @codex_features)
    assert {{:succeeded, nil}, elapsed} = run(ctx, "codex", binary, nil, 20_000)
    assert elapsed < 15_000
  end

  @tag :tmp_dir
  test "a Claude check still succeeds with no stdin", ctx do
    fake_claude_adapter!(ctx.tmp_dir)
    binary = fake_cli!(ctx.tmp_dir, "claude", @claude_help, [])
    assert {{:succeeded, nil}, _} = run(ctx, "claude", binary, nil, 20_000)
  end

  @tag :tmp_dir
  test "Claude launch and recovery select the same PATH CLI when the bundle is obsolete", ctx do
    bundle = fake_claude_adapter!(ctx.tmp_dir, "2.1.207")
    path_cli = fake_cli!(ctx.tmp_dir, "claude", @claude_help, [])
    configure_claude_toolchain!(ctx)

    selected = launch_executable!(ctx)
    assert selected == path_cli
    assert {{:succeeded, nil}, _} = run(ctx, "claude", nil, nil, 20_000)
    assert File.exists?(selected <> ".called")
    refute File.exists?(bundle <> ".called")
  end

  @tag :tmp_dir
  test "Claude launch and recovery select the same bundle when the PATH CLI is obsolete", ctx do
    bundle = fake_claude_adapter!(ctx.tmp_dir)
    path_cli = fake_cli!(ctx.tmp_dir, "claude", @claude_help, [], "2.1.207")
    configure_claude_toolchain!(ctx)

    selected = launch_executable!(ctx)
    assert selected == bundle
    assert {{:succeeded, nil}, _} = run(ctx, "claude", nil, nil, 20_000)
    assert File.exists?(selected <> ".called")
    refute File.exists?(path_cli <> ".called")
  end

  @tag :tmp_dir
  test "Claude recovery honors an inherited override containing spaces", ctx do
    fake_claude_adapter!(ctx.tmp_dir)
    binary = fake_cli!(ctx.tmp_dir, "custom claude", @claude_help, [])
    with_claude_override(binary)
    assert {{:succeeded, nil}, _} = run(ctx, "claude", nil, nil, 20_000)
  end

  @tag :tmp_dir
  test "Claude recovery reads JSON separately from SSH warnings", ctx do
    fake_ssh!(ctx.tmp_dir, "fixture SSH warning")
    with_fixture_path(ctx.tmp_dir)
    fake_claude_adapter!(ctx.tmp_dir)
    binary = fake_cli!(ctx.tmp_dir, "custom claude", @claude_help, [])
    assert {{:succeeded, nil}, _} = run(ctx, "claude", binary, "fixture@remote", 20_000)
    assert File.exists?(binary <> ".called")
  end

  @tag :tmp_dir
  test "a remote Codex check gets no stdin through ssh", ctx do
    fake_ssh!(ctx.tmp_dir)
    binary = fake_cli!(ctx.tmp_dir, "codex", @codex_help, @codex_features)
    with_fixture_path(ctx.tmp_dir)

    assert {{:succeeded, nil}, elapsed} = run(ctx, "codex", binary, "fixture@remote", 20_000)
    assert elapsed < 15_000
  end

  defp fake_claude_adapter!(dir, version \\ "2.1.280") do
    root = Path.join(dir, "adapters")
    package = Path.join(root, "node_modules/@agentclientprotocol/claude-agent-acp")
    adapter = Claude.installed_adapter(root)
    File.mkdir_p!(Path.join(package, "dist"))
    File.mkdir_p!(Path.dirname(adapter))
    entry = fake_cli!(package, "cli", [], [])
    File.ln_s!(entry, adapter)

    File.write!(
      Path.join(package, "package.json"),
      JSON.encode!(%{
        name: Claude.install_package(),
        version: Claude.adapter_version(),
        type: "module"
      })
    )

    bundle = fake_cli!(package, "bundled-claude", @claude_help, [], version)

    File.write!(Path.join(package, "dist/acp-agent.js"), """
    export function claudeCliPath() {
      return #{JSON.encode!(bundle)};
    }
    """)

    bundle
  end

  defp configure_claude_toolchain!(ctx) do
    assert {:ok, _} =
             Placement.register_host(ctx.db, "stdinhost", %{ssh: nil, base_dir: ctx.tmp_dir})

    {node, 0} = System.cmd("node", ["-p", "process.execPath"])
    node_dir = node |> String.trim() |> Path.dirname()

    assert {:ok, _} =
             Placement.set_toolchain_dirs(ctx.db, "stdinhost", [ctx.tmp_dir, node_dir], "test")

    with_claude_override(nil)
  end

  defp launch_executable!(ctx) do
    path = Placement.toolchain_path_preview(%{base_dir: ctx.tmp_dir, db: ctx.db}, "stdinhost")
    adapter = Claude.installed_adapter(Path.join(ctx.tmp_dir, "adapters"))
    opts = [cmd: [adapter], cwd: ctx.tmp_dir, env: [{"PATH", path}]]

    assert {:ok, launch_opts} =
             ClaudeCli.prepare_launch(opts, "stdinhost", &Support.system_cmd_out/1)

    {"CLAUDE_CODE_EXECUTABLE", executable} =
      List.keyfind(launch_opts[:env], "CLAUDE_CODE_EXECUTABLE", 0)

    executable
  end

  defp with_fixture_path(dir) do
    path = System.fetch_env!("PATH")
    System.put_env("PATH", dir <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)
  end

  defp with_claude_override(value) do
    env = "CLAUDE_CODE_EXECUTABLE"
    previous = System.get_env(env)
    set_override(env, value)
    on_exit(fn -> set_override(env, previous) end)
  end

  defp set_override(name, nil), do: System.delete_env(name)
  defp set_override(name, value), do: System.put_env(name, value)
end
