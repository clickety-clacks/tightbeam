defmodule Tightbeam.EscalationDeliveryTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true
  test "proof 1: a statute request and its owner notification commit or roll back together", %{
    tmp_dir: tmp
  } do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 0)
  end

  test "proof 1b: an operator row and its Main opportunity commit or roll back together", %{
    tmp_dir: tmp
  } do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 1)
  end

  test "proof 2: an effort request, its deadline wake, and its notification are one commit", %{
    tmp_dir: tmp
  } do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 2)
  end

  test "proof 3: a deadline advance and its new-rung notification are one commit", %{tmp_dir: tmp} do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 3)
  end

  test "proof 4: a committed notification is delivered by the boot tick alone", %{tmp_dir: tmp} do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 4)
  end

  test "proof 5: a raising or exiting delivery leaves the notification pending", %{tmp_dir: tmp} do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 5)
  end

  test "proof 6: one delivery commits message, turn and fired-mark; the backstop dedupes", %{
    tmp_dir: tmp
  } do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 6)
  end

  test "proof 7: decision-pending replay and open-request conflict arm nothing", %{tmp_dir: tmp} do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 7)
  end

  test "proof 8: every rung expiry re-arms one deadline wake and one prompt wake", %{tmp_dir: tmp} do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 8)
  end

  test "proof 9: delivery reaches only the injected registry and lane manager", %{tmp_dir: tmp} do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 9)
  end

  test "proof 10: every request site arms in-transaction and every turn sink is enumerated", %{
    tmp_dir: tmp
  } do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 10)
  end

  test "proof 11: targetGate 0 delivers to a retired target; the default gate still gates", %{
    tmp_dir: tmp
  } do
    Tightbeam.EscalationDeliveryFixture.run!(tmp, 11)
  end
end
