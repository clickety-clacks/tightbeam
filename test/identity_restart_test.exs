defmodule Tightbeam.IdentityRestartTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true

  @tag timeout: 180_000
  test "customized relearn conflict survives a real gateway restart and supported abort/resolve",
       %{
         tmp_dir: tmp
       } do
    binary = Path.expand("cli/target/release/tightbeam")

    fixture = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "identity_restart.exs")

    for phase <- ["conflict", "abort", "resolve", "normal"] do
      {output, status} =
        System.cmd(fixture.executable, fixture.args ++ [phase, binary],
          env: fixture.env,
          stderr_to_stdout: true
        )

      File.write!(Path.join(tmp, "#{phase}.log"), output)
      assert status == 0, output
      assert output =~ "identity-restart: #{phase} passed"
    end
  end
end
