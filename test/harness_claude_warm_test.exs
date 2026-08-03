defmodule Tightbeam.HarnessClaudeWarmTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.Claude

  test "a failed warm is reported to the onboarding caller" do
    target = local_target(fn _command -> {"provider refused", 1} end)

    assert {:error, reason} = Claude.warm_home(target, "/tmp/claude-home")
    assert inspect(reason) =~ "provider refused"
  end

  test "a hung warm is bounded" do
    target =
      local_target(fn _command ->
        Process.sleep(:infinity)
      end)
      |> Map.put(:warm_timeout_ms, 10)

    started = System.monotonic_time(:millisecond)
    assert {:error, reason} = Claude.warm_home(target, "/tmp/claude-home")
    assert inspect(reason) =~ "timed out"
    assert System.monotonic_time(:millisecond) - started < 500
  end

  defp local_target(sh) do
    %{
      host_config: %{ssh: nil},
      sh: sh
    }
  end
end
