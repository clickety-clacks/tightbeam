defmodule Tightbeam.CredentialWarmFixture do
  @moduledoc false
  import ExUnit.Assertions

  # Only the existing local warm argv is accepted. There is deliberately no
  # System.cmd, shell, SSH, provider invocation, or fallback runner here.
  def runner(base, machine) do
    home = Path.join([base, "homes", machine, "claude"])
    expected = ["env", "CLAUDE_CONFIG_DIR=#{home}", "claude", "-p", "ok", "--model", "sonnet"]
    owner = self()

    fn command ->
      assert command == expected
      send(owner, {:fixture_warm, home})
      {"fixture warm refused", 1}
    end
  end
end
