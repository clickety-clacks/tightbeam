defmodule Tightbeam.FeatureSmokeHomeTest do
  use ExUnit.Case, async: true
  alias Tightbeam.FeatureSmokeHome

  @rollout "sessions/2026/09/06/rollout-2026-09-06T19-42-18-01a079be-bb45-7971-95f2-6818514c2791.jsonl"

  @snapshot "shell_snapshots/01a079ca-4202-7032-9a64-c52a9f46c158.1788749693443945392.sh"

  test "new native Codex history is accepted while new deployment strays still fail" do
    before_entries = MapSet.new(["history.jsonl"])
    owned = MapSet.new(["hooks.json", "auth.json"])

    strays = [
      "unexpected.txt",
      "sessions/stray.txt",
      ".tightbeam/unowned",
      "shell_snapshots/unexpected.sh",
      @rollout <> ".bak"
    ]

    after_entries =
      MapSet.new(["history.jsonl", "hooks.json", "auth.json", @rollout, @snapshot | strays])

    assert Enum.sort(FeatureSmokeHome.new_strays(before_entries, after_entries, owned, :codex)) ==
             Enum.sort(strays)
  end

  test "the Codex history exception does not apply to other harnesses" do
    assert FeatureSmokeHome.new_strays(
             MapSet.new(),
             MapSet.new([@rollout]),
             MapSet.new(),
             :claude
           ) ==
             [@rollout]
  end

  test "native lock and key shapes are harness-specific and arbitrary files still fail" do
    codex_lock = "thread-writer-locks/01a079d2-1306-7031-938e-66bec2ea11a6.lock"

    claude_key =
      "sessions/2159598.b1226807dd39786332307f7b370d0d000a05d4106ec7f1724ba71d59e1e9b225.key"

    assert Tightbeam.Harness.Codex.native_home_entry?(codex_lock)

    assert Tightbeam.Harness.Codex.native_home_entry?(
             ".tmp/plugins/plugins/zoom/skills/virtual-agent/ios/examples/js-bridge-patterns.md"
           )

    refute Tightbeam.Harness.Codex.native_home_entry?(".tmp/unexpected.txt")
    assert Tightbeam.Harness.Codex.native_home_entry?("tmp/arg0/codex-arg0kNZker/.lock")
    refute Tightbeam.Harness.Codex.native_home_entry?("tmp/arg0/unexpected/.lock")
    refute Tightbeam.Harness.Claude.native_home_entry?(codex_lock)
    assert Tightbeam.Harness.Claude.native_home_entry?(claude_key)
    assert Tightbeam.Harness.Claude.native_home_entry?("sessions/2192740.json")
    refute Tightbeam.Harness.Claude.native_home_entry?("sessions/unexpected.json")
    refute Tightbeam.Harness.Codex.native_home_entry?(claude_key)
    refute Tightbeam.Harness.Claude.native_home_entry?("sessions/unexpected.key")
    refute Tightbeam.Harness.Codex.native_home_entry?("thread-writer-locks/unexpected.lock")
  end

  @tag :tmp_dir
  test "census tolerates a file removed after readdir and retains other entries", %{tmp_dir: root} do
    File.write!(Path.join(root, "vanishing.lock"), "lock")
    File.write!(Path.join(root, "keep"), "keep")

    lstat = fn path ->
      if Path.basename(path) == "vanishing.lock", do: File.rm!(path)
      File.lstat(path)
    end

    assert FeatureSmokeHome.leaf_entries(root, lstat: lstat) == ["keep"]
  end

  @tag :tmp_dir
  test "census reports permission errors rather than treating them as disappearing entries", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "denied"), "entry")

    assert_raise File.Error, fn ->
      FeatureSmokeHome.leaf_entries(root, lstat: fn _ -> {:error, :eacces} end)
    end
  end
end
