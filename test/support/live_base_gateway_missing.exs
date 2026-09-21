import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, config: config} ->
  path = Path.join(base, "gateway.json")
  refute File.exists?(path)
  Gateway.children(%{config | port: 0})
  assert %{"cliToken" => "tbc_" <> token} = path |> File.read!() |> JSON.decode!()
  assert token != ""
end)

IO.puts("guarded-gateway-missing: ok")
