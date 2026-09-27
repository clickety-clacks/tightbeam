defmodule Tightbeam.TerminalCredentialFailureTest do
  use Tightbeam.TestCase, async: false

  @tag tmp_dir: true, guard_runtime: true
  test "one open incident owns the canonical statement and current admin delivery", %{
    tmp_dir: tmp
  } do
    run_core_proof!(tmp, "statement-delivery")
  end

  @tag tmp_dir: true, guard_runtime: true
  test "rollback documentation names the old-code probe-loop consequence", %{tmp_dir: tmp} do
    run_core_proof!(tmp, "rollback-documentation")
  end

  @tag tmp_dir: true, guard_runtime: true
  test "demotion pauses statement updates and re-promotion reuses its identity", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "terminal_credential_admin_lifecycle_runtime.exs",
      "terminal-credential-admin-lifecycle: ok",
      []
    )
  end

  @tag tmp_dir: true, guard_runtime: true
  test "resolution before a personal session prevents stale pending delivery", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "terminal_credential_resolved_pending_runtime.exs",
      "terminal-credential-resolved-pending: ok",
      []
    )
  end

  @tag tmp_dir: true, guard_runtime: true
  test "concurrent final results find one open incident and one assertion", %{tmp_dir: tmp} do
    run_core_proof!(tmp, "concurrent-open")
  end

  @tag tmp_dir: true, guard_runtime: true
  test "only newer facts claim recovery and restart resumes a claim once", %{tmp_dir: tmp} do
    run_core_proof!(tmp, "newer-fact-recovery")
  end

  @tag tmp_dir: true, guard_runtime: true
  test "startup claims an eligible fact committed before its recognition cast", %{tmp_dir: tmp} do
    run_core_proof!(tmp, "startup-recovery")
  end

  @tag tmp_dir: true, guard_runtime: true
  test "a newer fact racing a failed recovery coalesces to the greatest successor", %{
    tmp_dir: tmp
  } do
    run_core_proof!(tmp, "racing-recovery")
  end

  @tag tmp_dir: true, guard_runtime: true
  test "normal harness success cannot resolve the separate terminal catalog incident", %{
    tmp_dir: tmp
  } do
    run_core_proof!(tmp, "normal-turn-exclusion")
  end

  @tag tmp_dir: true, guard_runtime: true
  test "provider task and recovery injector call sites stay fully accounted", %{tmp_dir: tmp} do
    run_core_proof!(tmp, "call-site-accounting")
  end

  defp run_core_proof!(tmp, proof) do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "terminal_credential_core_runtime.exs",
      "terminal-credential-core: #{proof}: ok",
      args: [proof]
    )
  end
end
