import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, config: config} ->
  empty = Path.join(base, "missing-bin")
  File.mkdir_p!(empty)
  Application.put_env(:tightbeam, :fixture_harness, false)
  System.put_env("PATH", empty)

  assert_raise RuntimeError, ~r/no registered harness CLI is installed/, fn ->
    Gateway.children(config)
  end

  refute File.exists?(Path.join(base, "bin/codex"))
end)

IO.puts("guarded-gateway-shim-missing: ok")
