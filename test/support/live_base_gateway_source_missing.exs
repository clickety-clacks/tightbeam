import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, config: config} ->
  repo = Path.join(Path.dirname(base), "empty-source")
  File.mkdir_p!(repo)
  rust_cli = Path.join(repo, "cli/target/release/tightbeam")
  refute File.exists?(rust_cli)
  refute System.get_env("RELEASE_ROOT")

  File.cd!(repo, fn ->
    Gateway.children(%{config | port: 0})
    fallback = Path.join(base, "bin/tightbeam")
    body = File.read!(fallback)
    # No historical TypeScript fallback: only the actual refusal script runs.
    refute body =~ "exec node"
    refute body =~ "dist/cli/main.js"
    assert body =~ "tightbeam CLI is not installed"
    assert body =~ "cargo build --release --manifest-path cli/Cargo.toml"
    assert body =~ rust_cli
    assert File.stat!(fallback).mode |> Bitwise.band(0o777) == 0o755
    assert {refusal, 127} = System.cmd(fallback, ["list"], stderr_to_stdout: true)
    assert refusal =~ "tightbeam CLI is not installed"
    assert refusal =~ "cargo build --release"
  end)
end)

IO.puts("guarded-gateway-source-missing: ok")
