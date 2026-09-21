import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, config: config} ->
  path = Path.join(base, "gateway.json")
  refute File.exists?(path)
  File.write!(path, "not json")
  assert File.read!(path) == "not json"
  Gateway.children(%{config | port: 0})
  assert %{"cliToken" => "tbc_" <> token} = path |> File.read!() |> JSON.decode!()
  assert token != ""
end)

IO.puts("guarded-gateway-corrupt: ok")
