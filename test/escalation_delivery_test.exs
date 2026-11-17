defmodule Tightbeam.EscalationDeliveryTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true
  test "proof 1: a statute request and filing fact commit or roll back together", %{
    tmp_dir: tmp
  } do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 0)
  end

  test "proof 1b: an operator request and filing fact commit or roll back together", %{
    tmp_dir: tmp
  } do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 1)
  end

  test "proof 4: an addressed ask is delivered by the boot tick alone", %{tmp_dir: tmp} do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 4)
  end

  test "proof 5: a raising or exiting delivery leaves the addressed ask pending", %{tmp_dir: tmp} do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 5)
  end

  test "proof 6: one delivery commits message, turn and fired-mark; the backstop dedupes", %{
    tmp_dir: tmp
  } do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 6)
  end

  test "proof 7: statute replay keeps one fact and no retired relay", %{tmp_dir: tmp} do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 7)
  end

  test "proof 9: delivery reaches only the injected registry and lane manager", %{tmp_dir: tmp} do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 9)
  end

  test "proof 11: retirement readdresses the addressed ask before delivery", %{
    tmp_dir: tmp
  } do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 11)
  end
end
