defmodule Tightbeam.OpencodeLaunchInvariantsTest.ReuseProbeShimHarness do
  @moduledoc false
  # A SECOND, synthetic binary-native harness — distinct from OpenCode — that reuses the generic
  # shim seam by supplying its OWN cli_binary + subcommand, with NO edit to the shared helper
  # (harness.ex/spinup.ex/support.ex). This is the Cursor reuse contract in miniature: if anything
  # opencode-specific had leaked into `Spinup.ensure_shim_adapter/4`, this harness could not use it.
  # A plain module (not `@behaviour`) on purpose — it exercises only the shim surface, not the whole
  # behaviour, so it stays lightweight and warning-free.
  def adapter_provisioning, do: :shim
  def cli_binary, do: "probe-agent"
  def install_package, do: "probe-agent"

  def ensure_adapter(target) do
    shim =
      Path.join([target.host_config.base_dir, "adapters", "node_modules", ".bin", "probe-agent"])

    Tightbeam.Spinup.ensure_shim_adapter(target, shim, cli_binary(), ["bridge"])
  end
end

defmodule Tightbeam.OpencodeLaunchInvariantsTest do
  # The rails-critical launch invariants for the OpenCode harness, tested structurally where the
  # conformance suite cannot: the shim can carry no plugin-disabling/listener-opening flag, the
  # launch argv is exactly the shim, the gate env is wired and OPENCODE_PURE never is, and the
  # 0-LISTEN assertion is opt-in per harness.
  use Tightbeam.TestCase, async: false

  import Bitwise, only: [band: 2]

  alias Tightbeam.{Harness, Spinup}
  alias Tightbeam.Harness.Opencode

  @forbidden ["--pure", "serve", "--port", "--hostname", "--mdns", "--cors"]

  describe "shim mechanism (invariants 1 & 2, structural)" do
    test "the shim bakes the fixed subcommand and carries no plugin-disabling/listener-opening flag" do
      base = Path.join(System.tmp_dir!(), "oc-shim-#{System.unique_integer([:positive])}")
      cli = Path.join(base, "opencode-bin")
      shim = Path.join([base, "adapters", "node_modules", ".bin", "opencode"])
      File.mkdir_p!(base)
      File.write!(cli, "#!/bin/sh\n")
      File.chmod!(cli, 0o755)

      target = %{
        host_name: "t",
        host_config: %{ssh: nil, base_dir: base},
        find_executable: fn "opencode" -> cli end
      }

      assert {:ok, "shim adapter present"} =
               Spinup.ensure_shim_adapter(target, shim, "opencode", ["acp"])

      content = File.read!(shim)
      assert content == "#!/bin/sh\nexec \"#{cli}\" acp \"$@\"\n"
      for flag <- @forbidden, do: refute(content =~ flag, "shim must never carry #{flag}")
      assert band(File.stat!(shim).mode, 0o777) == 0o755

      File.rm_rf!(base)
    end

    test "a missing operator CLI is a loud refusal, never a silent stub" do
      base = Path.join(System.tmp_dir!(), "oc-shim-miss-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      shim = Path.join(base, "opencode")

      target = %{
        host_name: "t",
        host_config: %{ssh: nil, base_dir: base},
        find_executable: fn "opencode" -> nil end
      }

      assert {:error, %{code: "host_unready", message: message}} =
               Spinup.ensure_shim_adapter(target, shim, "opencode", ["acp"])

      assert message =~ "opencode"
      refute File.exists?(shim)
      File.rm_rf!(base)
    end
  end

  describe "prepare_launch (invariants 1 & 2 at the launch seam)" do
    test "cmd is exactly the shim with no extra argv; the gate is wired and OPENCODE_PURE never is" do
      base = "/base"
      home = "/base/homes/h/opencode"
      adapter = "/base/adapters/node_modules/.bin/opencode"

      target = %{
        host_config: %{ssh: nil, base_dir: base},
        adapter_binary: adapter
      }

      plan =
        Opencode.prepare_launch(target, home,
          common_env: [{"COMMON", "1"}],
          remote_env: [],
          lineage: "l"
        )

      # The whole argv is the shim — nothing appends a flag, so `--pure`/`serve`/`--port` cannot
      # reach the CLI (the shim itself bakes in `acp`).
      assert plan[:cmd] == [adapter]
      for token <- plan[:cmd], flag <- @forbidden, do: refute(token =~ flag)

      env = Map.new(plan[:env])
      assert env["OPENCODE_CONFIG"] == "/base/opencode-gate/opencode.json"
      assert env["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1"
      assert env["XDG_DATA_HOME"] == "/base/homes/h"
      assert env["XDG_CONFIG_HOME"] == "/base/homes/h"
      refute Map.has_key?(env, "OPENCODE_PURE")
    end
  end

  describe "0-LISTEN assertion (invariant 3, automatic for the :shim class)" do
    test "requires_zero_listeners?/1 is safe-by-default: enforced for :shim, not for :npm" do
      # OpenCode gets it automatically by being :shim — it declares no per-harness property.
      assert Harness.requires_zero_listeners?(Tightbeam.Harness.Opencode)
      refute function_exported?(Tightbeam.Harness.Opencode, :requires_zero_listeners?, 0)

      # The :npm path is not enforced in this goal.
      refute Harness.requires_zero_listeners?(Tightbeam.Harness.Claude)
      refute Harness.requires_zero_listeners?(Tightbeam.Harness.Codex)
      refute Harness.requires_zero_listeners?(Tightbeam.Harness.Fixture)
    end
  end

  describe "provisioning strategy (shared shim seam)" do
    test "opencode is :shim and is excluded from the npm-provisioned set; the others are :npm" do
      assert Opencode.adapter_provisioning() == :shim
      refute Opencode in Harness.npm_provisioned()
      assert Tightbeam.Harness.Claude in Harness.npm_provisioned()
      assert Tightbeam.Harness.Codex in Harness.npm_provisioned()
    end
  end

  describe "reuse contract (the shared shim seam is generic, nothing opencode-specific leaked)" do
    alias Tightbeam.OpencodeLaunchInvariantsTest.ReuseProbeShimHarness, as: ReuseShim

    test "a second synthetic shim harness reuses Spinup.ensure_shim_adapter with its own binary + subcommand" do
      base = Path.join(System.tmp_dir!(), "reuse-shim-#{System.unique_integer([:positive])}")
      cli = Path.join(base, "probe-agent-bin")
      File.mkdir_p!(base)
      File.write!(cli, "#!/bin/sh\n")
      File.chmod!(cli, 0o755)

      target = %{
        host_name: "t",
        host_config: %{ssh: nil, base_dir: base},
        find_executable: fn "probe-agent" -> cli end
      }

      assert {:ok, "shim adapter present"} = ReuseShim.ensure_adapter(target)

      shim = Path.join([base, "adapters", "node_modules", ".bin", "probe-agent"])
      content = File.read!(shim)

      # Keyed ENTIRELY on this harness's own values — a different binary and a different
      # subcommand than opencode's — proving cli_binary + exec_args are fully parameterized and
      # no opencode literal ("acp"/"opencode") is baked into the shared helper.
      assert content == "#!/bin/sh\nexec \"#{cli}\" bridge \"$@\"\n"
      refute content =~ "opencode"
      refute content =~ "acp"

      # adapter_provisioning drives the generic exclusion AND the safe-by-default 0-LISTEN assert:
      # a second :shim harness gets invariant-3 protection AUTOMATICALLY, without opting in and with
      # nothing hardcoded to opencode — exactly the safe-by-default the ruling requires.
      assert ReuseShim.adapter_provisioning() == :shim
      assert Harness.requires_zero_listeners?(ReuseShim)

      File.rm_rf!(base)
    end
  end
end
