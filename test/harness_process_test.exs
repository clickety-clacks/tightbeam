defmodule Tightbeam.HarnessProcessTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true
  @moduletag timeout: 120_000

  alias Tightbeam.{DB, HarnessProcess}
  @helper Path.expand("../cli/target/release/tightbeam", __DIR__)

  test "a bare executable name is resolved to a path rather than handed over unresolved", %{
    tmp_dir: tmp
  } do
    Tightbeam.HarnessProcessFixture.run!(tmp, 0)
  end

  test "an absolute path is taken as given, not looked up on PATH", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 1)
  end

  test "an unresolvable name is refused rather than raised on", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 2)
  end

  test "an old harness process schema is refused without partial DDL", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 3)
  end

  test "the ruled-out shared listener seam stays absent" do
    refute function_exported?(HarnessProcess, :assert_zero_listeners, 2)
    refute function_exported?(HarnessProcess, :assert_zero_listeners, 3)
    refute function_exported?(Tightbeam.Acp.Adapter, :listener_guard_for_test, 6)
  end

  test "the coordinator records group identity during real adapter boot", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 4)
  end

  test "boot reconciliation kills a recorded orphan without a live monitor", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 5)
  end

  test "remote launch wraps the harness with the same session helper", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 6)
  end

  test "identity capture cannot mutate an already-resolved launch", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 7)
  end

  test "local Cursor launch switches identity before the session helper records it", %{
    tmp_dir: tmp
  } do
    db = String.to_atom("cursor_harness_process_#{System.unique_integer([:positive])}")
    start_supervised!(Supervisor.child_spec({DB, path: ":memory:", name: db}, id: db))

    opts =
      HarnessProcess.prepare_launch(
        [
          cmd: [Path.join(tmp, "adapters/cursor-agent"), "acp"],
          cursor_execution_identity: true,
          cursor_rails_sha256: String.duplicate("a", 64),
          process_helper: @helper,
          process_identity_dir: tmp
        ],
        db,
        {:cursor, "shared", "testhost"}
      )

    assert [
             "/usr/bin/sudo",
             "-n",
             "-H",
             "-u",
             "tightbeam-cursor",
             "--",
             "/usr/local/libexec/tightbeam-cursor-launcher",
             "cursor-exec",
             "launch",
             base,
             org_base,
             operator_uid,
             operator_home,
             rails_sha256,
             "--",
             identity_path,
             launch_id,
             "--",
             adapter,
             "acp"
           ] = Keyword.fetch!(opts, :cmd)

    assert base == Tightbeam.Harness.Cursor.execution_base(nil)
    assert org_base == @helper |> Path.dirname() |> Path.dirname()
    assert operator_uid == System.cmd("/usr/bin/id", ["-u"]) |> elem(0) |> String.trim()
    assert operator_home == System.user_home!()
    assert rails_sha256 == String.duplicate("a", 64)
    assert identity_path =~ "/harness-processes/"
    assert is_binary(launch_id)
    assert adapter == Path.join(tmp, "adapters/cursor-agent")
    assert Bitwise.band(File.stat!(Path.dirname(identity_path)).mode, 0o7777) == 0o2770
  end

  test "Cursor execution identity refuses an SSH launch before wrapping it" do
    db = String.to_atom("remote_cursor_harness_process_#{System.unique_integer([:positive])}")
    start_supervised!(Supervisor.child_spec({DB, path: ":memory:", name: db}, id: db))

    assert_raise ArgumentError, ~r/local-only; SSH hosts are unsupported/, fn ->
      HarnessProcess.prepare_launch(
        [
          cmd: ["ssh", "worker", "cursor-agent", "acp"],
          process_ssh: "worker",
          cursor_execution_identity: true,
          cursor_rails_sha256: String.duplicate("a", 64),
          process_helper: @helper,
          process_identity_dir: "/remote/cursor"
        ],
        db,
        {:cursor, "shared", "worker"}
      )
    end
  end

  test "identity capture accepts an unbounded wait", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 8)
  end

  test "kill delivery failure remains fenced and the reconcile sweep retries it", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 9)
  end

  test "a kill command that never returns is bounded and remains kill_failed", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 10)
  end

  test "continuous helper output cannot starve the absolute command deadline", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 11)
  end

  test "every unresolved launch fences a replacement before DOWN reconciliation", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 12)
  end

  test "park selection follows durable launch sequence, not clock or ULID order", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 13)
  end

  test "boot reconciliation waits for a launcher identity that appears after row insertion", %{
    tmp_dir: tmp
  } do
    Tightbeam.HarnessProcessFixture.run!(tmp, 14)
  end

  test "boot reconciliation clears a fence with no unresolved launch", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 15)
  end

  test "DOWN reconciliation authorizes and signals the recorded group", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 16)
  end

  test "proven-dead settlement resolves the captured missing-identity rows and is inert when repeated",
       %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 17)
  end

  test "a helper refusal cannot resolve a launch without attempting the group kill", %{
    tmp_dir: tmp
  } do
    Tightbeam.HarnessProcessFixture.run!(tmp, 18)
  end

  test "a second reconciler losing the terminal race cannot corrupt the resolved row", %{
    tmp_dir: tmp
  } do
    Tightbeam.HarnessProcessFixture.run!(tmp, 19)
  end

  test "planned close returns reconciliation failure and keeps the launch fenced", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 20)
  end

  test "a proven-dead cleanup refusal records the failure and starts one successor", %{
    tmp_dir: tmp
  } do
    Tightbeam.HarnessProcessFixture.run!(tmp, 21)
  end

  test "identity removal failure is cleanup and does not suppress the scheduled restart", %{
    tmp_dir: tmp
  } do
    Tightbeam.HarnessProcessFixture.run!(tmp, 22)
  end

  test "a park with no launch fences and cancels a pending checkout", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 23)
  end

  test "a kill_failed durable park fences checkout after coordinator recreation", %{tmp_dir: tmp} do
    Tightbeam.HarnessProcessFixture.run!(tmp, 24)
  end

  test "a launch that never minted a process is resolved by reconciliation, not fenced", %{
    tmp_dir: tmp
  } do
    Tightbeam.HarnessProcessFixture.run!(tmp, 25)
  end

  test "a launch from a previous OS boot is resolved as a reboot orphan, not fenced", %{
    tmp_dir: tmp
  } do
    Tightbeam.HarnessProcessFixture.run!(tmp, 26)
  end

  test "a key whose launch never minted a process is launchable again after reboot", %{
    tmp_dir: tmp
  } do
    Tightbeam.HarnessProcessFixture.run!(tmp, 27)
  end
end
