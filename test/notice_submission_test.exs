defmodule Tightbeam.NoticeSubmissionTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true

  test "Claude readiness submits every eligible ordered source in one durable carrier without a guessed text cap",
       %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 41)
  end

  test "one real readiness admission coalesces all small Codex sources above the old caps", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 39)
  end

  test "real Unicode size split preserves cancellation and immutable turns across restart", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 40)
  end

  test "claimed prewrite refusal restores raw roots once across a persistent reopen", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 31)
  end

  test "a stale lease or actual port-write evidence cannot restore a claimed carrier", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 32)
  end

  test "forged claimed-turn, envelope, sender or member provenance refuses with zero writes", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 42)
  end

  test "a changed controller entitlement rolls back terminal and sibling restoration atomically",
       %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 33)
  end

  test "a restored prod reuses its charged generation and settles once across reopen", %{
    tmp_dir: tmp
  } do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 34)
  end

  test "a missing bubble cause cannot partially restore siblings", %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 35)
  end

  test "a scheduled escalation delegates original transfer through repeated prewrite successors",
       %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 36)
  end

  test "a retirement successor retains the original predecessor outcome across retry and reopen",
       %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 37)
  end

  test "a deterministic retry name without prewrite evidence cannot delegate or suppress failure",
       %{tmp_dir: tmp} do
    Tightbeam.NoticeBatcherFixture.run!(tmp, 38)
  end

  test "only the explicit capacity prewrite result qualifies, never inferred failure text" do
    alias Tightbeam.NoticeSubmission

    evidence =
      NoticeSubmission.prewrite_evidence(
        :prompt,
        {:acp_request_not_dispatched, {:transport_capacity_exceeded, 201, 200}}
      )

    assert NoticeSubmission.valid_evidence?(evidence)

    for stage <- [:checkout, :session],
        do:
          assert(
            NoticeSubmission.prewrite_evidence(
              stage,
              {:acp_request_not_dispatched, {:transport_capacity_exceeded, 201, 200}}
            ) == nil
          )

    for reason <- [
          :prompt_timeout,
          :closed,
          :prompt_dispatch_failed,
          :invalid_transport_capacity,
          {:transport_capacity_exceeded, 200, 200},
          {:transport_capacity_exceeded, 201, 0},
          {:transport_capacity_exceeded, "201", 200}
        ] do
      assert NoticeSubmission.prewrite_evidence(
               :prompt,
               {:acp_request_not_dispatched, reason}
             ) == nil
    end

    for reason <- [
          :interrupted,
          {:provider_error, "capacity exceeded"},
          {:provider_error, 413},
          %{"api_error_status" => 413},
          {:lifecycle_trace_failed_after_prompt, :dispatch, :timeout},
          "acp_request_not_dispatched transport_capacity_exceeded"
        ] do
      assert NoticeSubmission.prewrite_evidence(:prompt, reason) == nil
    end

    refute NoticeSubmission.valid_evidence?(Map.put(evidence, "invented", true))
  end
end
