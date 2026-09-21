import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, config: config} ->
  real_codex = System.find_executable("codex")
  assert real_codex == Path.join(base, "fixture-bin/codex")
  Gateway.children(config)
  shim = Path.join(base, "bin/codex")

  assert File.read!(shim) ==
           "#!/bin/sh\nexec \"#{real_codex}\" --dangerously-bypass-hook-trust \"$@\"\n"

  assert File.stat!(shim).mode |> Bitwise.band(0o777) == 0o755
end)

IO.puts("guarded-gateway-shim-copy: ok")
