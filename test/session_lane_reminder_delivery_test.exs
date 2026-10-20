defmodule Tightbeam.SessionLaneReminderDeliveryTest do
  use Tightbeam.TestCase, async: false

  # Each case drives a real SessionLane and Gateway runner in a guarded VM.

  @tag timeout: 180_000, cold_gateway: true, tmp_dir: true
  test "a lane's terminal delivery consumes a carried reminder claim once", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "live_base_reminder_delivery_delivered.exs",
      "guarded-reminder-delivery-delivered: ok"
    )
  end

  @tag timeout: 180_000, cold_gateway: true, tmp_dir: true
  test "the fallback terminal transaction consumes a reminder claim when the reply cannot be recorded",
       %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "live_base_reminder_delivery_fallback.exs",
      "guarded-reminder-delivery-fallback: ok"
    )
  end

  @tag timeout: 180_000, cold_gateway: true, tmp_dir: true
  test "a repaired reminder turn consumes the rebound claim and its reply belongs to the source turn",
       %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "live_base_reminder_delivery_repaired.exs",
      "guarded-reminder-delivery-repaired: ok"
    )
  end
end
