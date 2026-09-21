defmodule Tightbeam.FirehoseColdLoopbackTest do
  use Tightbeam.TestCase, async: false
  @tag :tmp_dir
  test "ordinary guarded Application delivers persistent work-item over real loopback", %{
    tmp_dir: tmp
  } do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "firehose_cold_loopback.exs",
      "guarded-firehose-loopback: ok"
    )
  end
end
