defmodule Tightbeam.CommandExecutionsTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true

  test "prepares exact single-use intent and refuses idempotency drift", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 0)
  end

  test "a pre-start caller death settles only through explicit not_started evidence", %{
    tmp_dir: tmp
  } do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 1)
  end

  test "success records start and distinct exact output evidence", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 2)
  end

  test "quiet and loud command failures are finished executions", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 3)
  end

  test "a command signal is terminal evidence distinct from an exit code", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 4)
  end

  test "the exec child restores SIGPIPE before recording command evidence", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 5)
  end

  test "the detached command reads EOF rather than the invoker stdin", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 6)
  end

  test "terminal output evidence refuses captured-byte drift", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 7)
  end

  test "boot reconciliation records malformed receipt evidence and continues", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 8)
  end

  test "boot reconciliation isolates malformed terminal status evidence per row", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 9)
  end

  test "boot reconciliation isolates all nine reviewed poison classes", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 10)
  end

  test "boot reconciliation bounds decoding to unresolved rows", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 11)
  end

  test "exec failure is durably not_started and duplicate consumption is refused", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 12)
  end

  test "a receipt pinned to another host is refused before consumption", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 13)
  end

  test "a terminal bound turn settles prepared intent without inferring a start", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 14)
  end

  test "detached supervisor finishes after the invoking adapter is killed post-start", %{
    tmp_dir: tmp
  } do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 15)
  end

  test "receipt races reconcile deterministically and idempotently", %{tmp_dir: tmp} do
    Tightbeam.CommandExecutionsFixture.run!(tmp, 16)
  end
end
