defmodule Tightbeam.ClaudeAdapterVerificationTest do
  use ExUnit.Case, async: true
  alias Tightbeam.Harness.Claude

  setup do
    root = Path.join(System.tmp_dir!(), "tb-claude-verify-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    package = Path.join([root, "node_modules", "@agentclientprotocol", "claude-agent-acp"])
    binary = Path.join([root, "node_modules", ".bin", "claude-agent-acp"])
    bundle = Path.join(package, "dist/acp-agent.js")
    File.mkdir_p!(Path.dirname(bundle))
    File.mkdir_p!(Path.dirname(binary))
    File.write!(binary, "")
    File.write!(bundle, "// No legacy anchors: native runtime owns lifecycle.\n")
    File.chmod!(bundle, 0o755)
    manifest = Path.join(package, "package.json")
    File.write!(manifest, JSON.encode!(%{version: Claude.adapter_version()}))
    %{binary: binary, bundle: bundle, manifest: manifest}
  end

  test "local verification preserves bytes and mode and rejects package drift", ctx do
    target = %{adapter_binary: ctx.binary, host_config: %{ssh: nil}}
    source = File.read!(ctx.bundle)
    mode = File.stat!(ctx.bundle).mode
    assert {:ok, _} = Claude.ensure_adapter(target)
    assert File.read!(ctx.bundle) == source
    assert File.stat!(ctx.bundle).mode == mode
    File.write!(ctx.manifest, JSON.encode!(%{version: "0.74.0"}))
    assert_raise MatchError, fn -> Claude.ensure_adapter(target) end
    assert File.read!(ctx.bundle) == source
  end

  test "remote verification executes the same pin check before touching source", ctx do
    # Execute the generated remote shell payload locally: transport is ours;
    # this checks the actual generated JavaScript rather than mocking its result.
    sh = fn args ->
      ["sh", "-c", quoted] = Enum.take(args, -3)
      System.cmd("sh", ["-c", "sh -c " <> quoted], stderr_to_stdout: true)
    end

    File.chmod!(ctx.binary, 0o755)
    target = %{adapter_binary: ctx.binary, host_config: %{ssh: "test-host"}, sh: sh}
    source = File.read!(ctx.bundle)
    mode = File.stat!(ctx.bundle).mode
    assert {:ok, _} = Claude.ensure_adapter(target)
    assert File.read!(ctx.bundle) == source
    assert File.stat!(ctx.bundle).mode == mode
    File.write!(ctx.manifest, JSON.encode!(%{version: "0.74.0"}))
    assert {:error, %{message: message}} = Claude.ensure_adapter(target)
    assert message =~ "unsupported claude adapter version 0.74.0"
    assert File.read!(ctx.bundle) == source
  end
end
