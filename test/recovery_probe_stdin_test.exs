defmodule Tightbeam.RecoveryProbeStdinTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Placement}
  alias Tightbeam.Harness.RecoveryProbe

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
  defp fake_cli!(dir, name, help, features) do
    path = Path.join(dir, name)

    File.write!(path, """
    #!/bin/sh
    input=$(cat)
    [ -z "$input" ] || { echo "unexpected stdin" >&2; exit 9; }
    case "$1 $2" in
      "exec --help"|"--help ") echo "#{Enum.join(help, " ")}" ;;
      "features list") echo "#{Enum.join(features, " ")}" ;;
      *) : ;;
    esac
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp fake_ssh!(dir) do
    # Like ssh: skip the options and host, give the rest to a shell, keep stdin open.
    path = Path.join(dir, "ssh")

    File.write!(path, """
    #!/bin/sh
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
    assert {:ok, _} = Placement.set_env_overlay(ctx.db, host, harness, pin_name, binary, "test")

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
    binary = fake_cli!(ctx.tmp_dir, "claude", @claude_help, [])
    assert {{:succeeded, nil}, _} = run(ctx, "claude", binary, nil, 20_000)
  end

  @tag :tmp_dir
  test "a remote Codex check gets no stdin through ssh", ctx do
    fake_ssh!(ctx.tmp_dir)
    binary = fake_cli!(ctx.tmp_dir, "codex", @codex_help, @codex_features)
    path = System.get_env("PATH")
    System.put_env("PATH", ctx.tmp_dir <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    assert {{:succeeded, nil}, elapsed} = run(ctx, "codex", binary, "fixture@remote", 20_000)
    assert elapsed < 15_000
  end
end
