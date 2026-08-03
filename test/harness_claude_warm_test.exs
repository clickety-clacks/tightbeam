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

  # A satellite onboarded BY THE GATEWAY must warm too. Skipping it left a host holding a
  # good credential whose harness had never asked what it may run -- the catalog then
  # narrows to the static floor, which reads as a weak account rather than a missing step.
  test "a remote home warms over ssh rather than being silently skipped" do
    parent = self()

    target = %{
      host_config: %{ssh: "worker@sat.example"},
      sh: fn command ->
        send(parent, {:ran, command})
        {"", 0}
      end
    }

    assert :ok = Claude.warm_home(target, "/srv/tb/homes/sat/claude")

    assert_receive {:ran, command}
    line = Enum.join(command, " ")
    assert hd(command) == "ssh"
    assert line =~ "worker@sat.example"
    assert line =~ "claude"
    assert line =~ "/srv/tb/homes/sat/claude"
  end

  # The same failure contract as a local warm: the caller decides what a cold home costs,
  # so a remote refusal must be reported rather than swallowed by the transport.
  test "a remote warm that fails is reported, not swallowed" do
    target = %{
      host_config: %{ssh: "worker@sat.example"},
      sh: fn _command -> {"ssh: connect failed", 255} end
    }

    assert {:error, reason} = Claude.warm_home(target, "/srv/tb/homes/sat/claude")
    assert inspect(reason) =~ "connect failed"
  end

  defp local_target(sh) do
    %{
      host_config: %{ssh: nil},
      sh: sh
    }
  end
end
