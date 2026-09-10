import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, config: config} ->
  self_codex = Path.join(base, "bin/codex")
  File.mkdir_p!(Path.dirname(self_codex))
  File.write!(self_codex, "self-sentinel")
  File.chmod!(self_codex, 0o755)
  Application.put_env(:tightbeam, :fixture_harness, false)
  System.put_env("PATH", Path.dirname(self_codex))
  assert_raise RuntimeError, ~r/no usable harness CLI/, fn -> Gateway.children(config) end
  assert File.read!(self_codex) == "self-sentinel"
end)

IO.puts("guarded-gateway-shim-self: ok")
