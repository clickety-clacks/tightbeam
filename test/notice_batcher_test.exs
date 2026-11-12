defmodule Tightbeam.NoticeBatcherTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{NoticeBatcher, Rules}

  @moduletag tmp_dir: true

  test "batching and class order follow the declared settings family" do
    assert NoticeBatcher.batching_enabled?()
    assert NoticeBatcher.class_order_sql("w") =~ "WHEN 'fyi' THEN 4"

    configured =
      Path.join(System.tmp_dir!(), "batch-settings-#{System.unique_integer([:positive])}")

    rules_dir = Path.join(configured, "identity/rules")
    File.mkdir_p!(rules_dir)
    on_exit(fn -> File.rm_rf!(configured) end)

    seed = File.read!(Path.expand("../priv/seed/rules/substrate.toml", __DIR__))

    seed =
      String.replace(
        seed,
        "class_order = [\"algedonic\", \"blocker\", \"input-needed\", \"status-query\", \"fyi\"]",
        "class_order = [\"fyi\", \"status-query\", \"input-needed\", \"blocker\", \"algedonic\"]"
      )

    File.write!(Path.join(rules_dir, "substrate.toml"), seed)
    Rules.load!(configured, [])

    assert NoticeBatcher.batching_enabled?()
    assert NoticeBatcher.class_order_sql("w") =~ "WHEN 'fyi' THEN 0"

    empty =
      Path.join(
        System.tmp_dir!(),
        "batch-settings-empty-#{System.unique_integer([:positive])}"
      )
    File.mkdir_p!(Path.join(empty, "identity/rules"))
    on_exit(fn -> File.rm_rf!(empty) end)
    Rules.load!(empty, [])

    refute NoticeBatcher.batching_enabled?()
    assert NoticeBatcher.class_order_sql("w") == "CASE WHEN 1 = 1 THEN 0 END"
  end

  test "without the settings family, classed notices are not enrolled in batching", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 48)
  end

  test "batch members use the configured class order", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 49)
  end

  test "a queued ordinary prompt is delivered when batching settings are absent", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 50)
  end

  test "a queued ordinary prompt is delivered when batching is disabled", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 51)
  end

  test "a queued ordinary prompt is delivered when batching settings are invalid", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 52)
  end

  test "an explicit non-lease due time survives an invalid notice-delivery family", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 53)
  end

  test "an explicit non-lease due time survives disabled notice batching", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 54)
  end

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

  test "acceptance 8: before/after admission boundaries assign every source exactly once", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 7)
  end

  test "acceptance 9: equal source timestamps retain publication sequence order", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 8)
  end

  test "separate eligibility boundaries exclude later sources even when capped splitting is allowed",
       %{
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

  test "acceptance 17: cancellation before admission excludes; cancellation after commit preserves history",
       %{
         tmp_dir: tmp
       } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 16)
  end

  test "acceptance 18: source visibility survives session coalescing and gates the entire batch read",
       %{
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

  test "acceptance 22: an earlier due source delivers without prematurely including a later deadline",
       %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 22)
  end

  test "an oversized Codex source is disposed and does not block a later sibling", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 23)
  end

  test "the complete Codex submission admits 1048576 scalars and disposes the next scalar", %{
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
  test "acceptance 13: a reopened file regroups unclaimed sealed history and commits one carrier",
       %{
         tmp_dir: tmp
       } do
    # Historical seal/arm is replaced by one readiness transaction; retain the file-reopen proof.
    Tightbeam.NoticeBatcherFixture.run!(tmp, 29)
  end

  test "failure of the second Codex size-bounded turn rolls back every chunk before exact retry",
       %{
         tmp_dir: tmp
       } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 30)
  end

  test "prewrite retry restores every admitted source without changing its stored bytes", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 31)
  end

  test "uncertain or dispatched turns refuse prewrite restoration atomically", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 32)
  end

  test "unavailable retry provenance rolls back the whole sibling restoration", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 35)
  end

  test "a provider rejection cannot be mistaken for prewrite restoration evidence", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 38)
  end

  test "forged retry identity or carrier metadata cannot be restored", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 42)
  end

  test "ordinary sources retain retry authority across repeated prewrite failures", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 47)
  end

  test "one malformed attachment source does not block its sibling notice", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 43)
  end

  test "an oversized source is ended with a sender notice without blocking its sibling", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 44)
  end

  test "an unresolvable linked target is ended without blocking or reading its missing source", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 46)
  end
end
