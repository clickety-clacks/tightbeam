defmodule Tightbeam.NoticeBatcherTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true

  test "acceptance 1: routine envelope preserves two sources and commits one recipient turn", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 0)
  end

  test "acceptance 2: user-authored fyi joins the default recipient batch", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 1)
  end

  test "acceptance 3: every prompt class and origin joins the default batch", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 2)
  end

  test "acceptance 4: blocker joins the ordinary recipient batch", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 3)
  end

  test "acceptance 5: internal status query remains outside prompt batching", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 4)
  end

  test "acceptance 6: an idle recipient forms its batch at the due time", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 5)
  end

  test "acceptance 7: a busy recipient forms its batch after the turn boundary", %{tmp_dir: tmp} do
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

  test "bounded queue chunks become carriers in the recipient-ready pass", %{
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

  test "acceptance 21: legacy lane settings cannot disable automatic batching", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 20)
  end

  test "unclassed prompt traffic gets the default class and batches immediately when idle", %{
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

  test "authenticated user, session and role targets batch by default with source privacy", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 26)
  end

  test "class priority marks every source and unclassed prompts use the classifier default", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 27)
  end

  test "a busy recipient keeps sources editable until the next turn boundary", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 28)
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
