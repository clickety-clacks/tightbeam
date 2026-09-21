import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, db: db, config: config} ->
  Tightbeam.TestCase.register_hosts(db, %{
    "already-assimilated" => %{
      ssh: "clu@already-assimilated",
      base_dir: "/remote/tb",
      cli_bin: nil
    }
  })

  Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:11373")
  parent = self()

  sh = fn command ->
    assert hd(command) in ["rsync", "ssh"]
    if hd(command) == "rsync", do: send(parent, {:staged, File.read!(Enum.at(command, -2))})
    {"", 0}
  end

  Gateway.children(%{config | port: 11_373} |> Map.put(:sh, sh))

  token =
    base |> Path.join("gateway.json") |> File.read!() |> JSON.decode!() |> Map.fetch!("cliToken")

  assert_receive {:staged, content}, 1_000

  assert JSON.decode!(content) == %{
           "url" => "http://gateway.example:11373",
           "cliToken" => token,
           "machine" => "already-assimilated"
         }
end)

IO.puts("guarded-gateway-endpoint: ok")
