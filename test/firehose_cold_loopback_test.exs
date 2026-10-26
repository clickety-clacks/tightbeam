defmodule Tightbeam.FirehoseColdLoopbackTest do
  use Tightbeam.TestCase, async: false
  @tag :tmp_dir
  test "guarded gateway serves credentialless Firehose and reads beside authenticated clients", %{
    tmp_dir: tmp
  } do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "firehose_cold_loopback.exs",
      "guarded-firehose-loopback: ok"
    )
  end
end
