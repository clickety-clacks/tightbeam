defmodule Tightbeam.AttentionTierTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true
  test "an elected turn's reply carries high; an unelected turn's reply carries normal", %{
    tmp_dir: tmp
  } do
    Tightbeam.AttentionTierFixture.run!(tmp, 0)
  end

  test "an election cannot leak into a later reply", %{tmp_dir: tmp} do
    Tightbeam.AttentionTierFixture.run!(tmp, 1)
  end

  test "a newer turn on another session cannot supply this reply's tier", %{tmp_dir: tmp} do
    Tightbeam.AttentionTierFixture.run!(tmp, 2)
  end

  test "attend's substrate-owned params are stripped at the wire boundary", %{tmp_dir: tmp} do
    Tightbeam.AttentionTierFixture.run!(tmp, 3)
  end

  test "a volunteered attentionTier does not reach a posted message", %{tmp_dir: tmp} do
    Tightbeam.AttentionTierFixture.run!(tmp, 4)
  end

  test "the message payload emits the tier", %{tmp_dir: tmp} do
    Tightbeam.AttentionTierFixture.run!(tmp, 5)
  end

  test "attend elects on the caller's running turn only", %{tmp_dir: tmp} do
    Tightbeam.AttentionTierFixture.run!(tmp, 6)
  end
end
