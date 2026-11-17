defmodule Tightbeam.ClaudeAdapterPinTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.Claude

  setup do
    base = Path.join(System.tmp_dir!(), "claude-pin-#{System.unique_integer([:positive])}")
    binary = Path.join([base, "adapters", "node_modules", ".bin", "claude-agent-acp"])
    manifest = Path.join([base, "adapters", "node_modules", Claude.install_package(), "package.json"])
    File.mkdir_p!(Path.dirname(binary))
    File.mkdir_p!(Path.dirname(manifest))
    File.write!(binary, "#!/bin/sh\nexit 0\n")
    File.chmod!(binary, 0o755)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, binary: binary, manifest: manifest}
  end

  test "local mismatched packages reinstall the current pin before patching, including prereleases", ctx do
    for version <- ["0.66.0", "0.99.0", "0.81.0-beta.1"] do
      write_version(ctx.manifest, version)
      parent = self()
      target = local_target(ctx, fn command ->
        send(parent, {:install, command})
        write_version(ctx.manifest, Claude.adapter_version())
        {"", 0}
      end, fn path ->
        assert path == ctx.binary
        assert File.read!(ctx.manifest) =~ Claude.adapter_version()
        send(parent, :patched)
        :ok
      end)
      assert {:ok, "deployed adapters"} = Claude.ensure_adapter(target)
      assert_received {:install, command}
      assert List.last(command) =~ "#{Claude.install_package()}@#{Claude.adapter_version()}"
      assert_received :patched
    end
  end

  test "matching local package is patched without installation", ctx do
    write_version(ctx.manifest, Claude.adapter_version())
    parent = self()
    target = local_target(ctx, fn _ -> flunk("matching pin must not install") end,
      fn _ -> send(parent, :patched); :ok end)
    assert {:ok, "adapters present"} = Claude.ensure_adapter(target)
    assert_received :patched
  end

  test "failed replacement never patches the mismatched package", ctx do
    write_version(ctx.manifest, "0.66.0")
    target = local_target(ctx, fn _ -> {"install failed", 1} end,
      fn _ -> flunk("failed install must not patch the stale package") end)
    assert {:error, %{code: "host_unready", message: message}} = Claude.ensure_adapter(target)
    assert message =~ "install failed"
    assert File.read!(ctx.manifest) =~ "0.66.0"
  end

  test "remote prerelease mismatch is rechecked at the pin before patching", ctx do
    {:ok, version} = Agent.start_link(fn -> "0.81.0-beta.1" end)
    on_exit(fn -> if Process.alive?(version), do: Agent.stop(version) end)
    parent = self()
    target = %{
      base_dir: ctx.base,
      host_name: "fixture-host",
      host_config: %{base_dir: "/fixture/base", ssh: "fixture-host"},
      sh: fn command ->
        script = List.last(command)
        cond do
          String.contains?(script, "cat ") -> {JSON.encode!(%{"version" => Agent.get(version, & &1)}), 0}
          String.contains?(script, "npm install") ->
            assert script =~ "#{Claude.install_package()}@#{Claude.adapter_version()}"
            Agent.update(version, fn _ -> Claude.adapter_version() end)
            send(parent, :installed)
            {"", 0}
          true -> {"", 0}
        end
      end,
      remote_patch: fn _, detail ->
        assert Agent.get(version, & &1) == Claude.adapter_version()
        send(parent, :patched)
        {:ok, detail}
      end
    }
    assert {:ok, "deployed adapters"} = Claude.ensure_adapter(target)
    assert_received :installed
    assert_received :patched
  end

  defp local_target(ctx, sh, patch) do
    %{
      base_dir: ctx.base,
      host_name: "fixture-host",
      host_config: %{base_dir: ctx.base, ssh: nil},
      sh: sh,
      patch_adapter: patch
    }
  end

  defp write_version(path, version), do: File.write!(path, JSON.encode!(%{"version" => version}))
end
