defmodule Tightbeam.FirehoseColdSlowTest do
  use Tightbeam.TestCase, async: false
  @tag :tmp_dir
  test "cold persistent slow consumer closes 4008 and refetches after reconnect", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "firehose_cold_slow.exs",
      "guarded-firehose-slow-consumer: ok"
    )
  end
end
