defmodule Tightbeam.NoticeBatcherTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true

  test "acceptance 1: routine envelope preserves two sources and commits one recipient turn", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 0)
  end

  test "acceptance 2: user-authored fyi bypasses membership and keeps the ordinary path", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 1)
  end

  test "acceptance 3: urgent classes bypass while agent-authored fyi joins the selected lane", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 2)
  end

  test "acceptance 4: blocker publication leaves the fyi batch unchanged", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 3)
  end

  test "acceptance 5: rows-only status query creates no batch state", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 4)
  end

  test "acceptance 6: ceiling seals then arms without a decision or desk dependency", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 5)
  end

  test "acceptance 7: a terminal turn boundary releases before the ceiling", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 6)
  end

  test "acceptance 8: boundary and insertion race assigns the later source exactly once", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 7)
  end

  test "acceptance 9: equal source timestamps retain publication sequence order", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 8)
  end

  test "acceptance 10: the 51st member starts the next ordered batch", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 9)
  end

  test "acceptance 11: the payload limit seals a prefix and never truncates the candidate", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 10)
  end

  test "an overflow-sealed prefix arms at the recipient boundary before its ceiling", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 11)
  end

  test "acceptance 12: replay returns one member and one batch", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 12)
  end

  test "acceptance 14: transient failure retries while unresolved delivery terminates", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 13)
  end

  test "acceptance 15: post-commit recovery marks terminal without a second edge", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 14)
  end

  test "acceptance 16: a late arrival cannot change a sealed envelope", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 15)
  end

  test "acceptance 17: cancellation before seal excludes; cancellation after seal preserves", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 16)
  end

  test "acceptance 18: visibility scopes split one role lane and gate batch reads", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 17)
  end

  test "acceptance 19: an exec-desk role receives the ordinary carrier without desk state", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 18)
  end

  test "acceptance 20: recurrence and prod state remain outside batching", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 19)
  end

  test "acceptance 21: default-off selection and rollback preserve the ordinary path", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 20)
  end

  test "default-off digest preserves the legacy rule through suppression and provenance", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 21)
  end

  test "acceptance 22: a later earlier deadline atomically shortens the lane", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 22)
  end

  test "a selected 65,536-byte source stays durable on the ordinary fallback lane", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 23)
  end

  test "the rendered V1 member boundary admits 65,536 bytes and bypasses the next byte", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 24)
  end

  test "the delivery envelope preserves trailing source payload bytes", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 25)
  end

  @tag notice_guarded_restart: true
  test "acceptance 13: a reopened file arms one wake from an already sealed batch", %{
    tmp_dir: tmp
  } do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "firehose_notice_restart.exs",
      "guarded-notice-batch-reopen: ok"
    )
  end
end
