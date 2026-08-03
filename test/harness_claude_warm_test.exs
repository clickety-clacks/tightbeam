defmodule Tightbeam.HarnessClaudeWarmTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.Claude

  # THE WARM MUST SPEAK A LANGUAGE THE HARNESS UNDERSTANDS. This passed
  # `--config-dir <home>`, an option Claude Code does not have, so every warm exited
  # "unknown option" and was swallowed by the best-effort contract — the mechanism
  # built to break the cold-catalog deadlock had never once run. The old assertions
  # could not catch it: they checked that the home PATH appeared in the command, which
  # a wrong flag satisfies just as well as a right one. What must be pinned is the
  # DELIVERY MECHANISM, and that it is the same one `prepare_launch/2` uses.
  test "the home is delivered by CLAUDE_CONFIG_DIR, never by a flag the CLI lacks" do
    parent = self()
    target = local_target(fn command -> send(parent, {:ran, command}) && {"", 0} end)

    assert :ok = Claude.warm_home(target, "/tmp/claude-home")

    assert_receive {:ran, command}

    # THE EXACT ARGV, IN ORDER -- not a substring of it. A joined-and-searched assertion
    # passes for `["CLAUDE_CONFIG_DIR=...", "claude", ...]`, which carries the right text
    # and is still broken: `System.cmd/2` would try to EXECUTE the assignment as a program.
    # What has to be pinned is that `env` applies it.
    assert command == [
             "env",
             "CLAUDE_CONFIG_DIR=/tmp/claude-home",
             "claude",
             "-p",
             "ok",
             "--model",
             "sonnet"
           ]
  end

  # Same contract on the satellite path, which had the identical bug: a remote home that
  # never warms leaves the host holding a good credential whose harness has never asked
  # what it may run, and the catalog narrows to the static floor.
  test "a remote warm delivers the home by env too" do
    parent = self()

    target = %{
      host_config: %{ssh: "worker@sat.example"},
      sh: fn command -> send(parent, {:ran, command}) && {"", 0} end
    }

    assert :ok = Claude.warm_home(target, "/srv/tb/homes/sat/claude")

    assert_receive {:ran, command}

    assert hd(command) == "ssh"
    assert "worker@sat.example" in command

    # The remote leg is one shell word per argv element, quoted. Assert the whole
    # command line, so an assignment that lost its `env` -- and would be read as a
    # command NAME by the remote shell -- cannot pass.
    remote = List.last(command)

    assert remote ==
             "'env' 'CLAUDE_CONFIG_DIR=/srv/tb/homes/sat/claude' 'claude' '-p' 'ok' " <>
               "'--model' 'sonnet'"
  end

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
