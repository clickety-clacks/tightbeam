defmodule Tightbeam.SettlementGatewayWriterTest do
  use Tightbeam.TestCase, async: false

  @tag timeout: 180_000, tmp_dir: true
  test "real Gateway, Adapter and Conn persist the actual dispatch correlation", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "settlement_gateway_writer.exs",
      "settlement-gateway-writer: ok"
    )
  end
end
