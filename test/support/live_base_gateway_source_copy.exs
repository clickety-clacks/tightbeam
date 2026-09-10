import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, config: config} ->
  repo = Path.join(Path.dirname(base), "synthetic-source")
  rust_cli = Path.join(repo, "cli/target/release/tightbeam")
  File.mkdir_p!(Path.dirname(rust_cli))
  File.write!(rust_cli, "rust-cli-binary")
  refute System.get_env("RELEASE_ROOT")

  File.cd!(repo, fn ->
    Gateway.children(%{config | port: 0})
    installed = Path.join(base, "bin/tightbeam")
    assert File.read!(installed) == "rust-cli-binary"
    assert File.stat!(installed).mode |> Bitwise.band(0o777) == 0o755
  end)
end)

IO.puts("guarded-gateway-source-copy: ok")
