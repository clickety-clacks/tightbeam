defmodule Tightbeam.ClientE2ETest do
  @moduledoc """
  The driver's own tests.

  Three things are proved here, and one deliberately is not:

  1. The SCORECARD ALGEBRA — a verdict that is computed differently by each
     run is not a verdict, so the algebra is pinned rather than described.
  2. The ORACLE TABLE's completeness — the duality contract says every step
     carries BOTH columns and that silence is illegal, which is a property a
     test can hold and a code review cannot.
  3. The SIM CLIENT against a REAL gateway — a real Bandit/Router/Socket stack
     over real `Tightbeam.Gateway` handlers and a real on-disk state.db,
     walking J0 end to end. Nothing here is a fake gateway; the journeys that
     need a live model are the runner script's job, against a real org.

  What is NOT proved here: the model-dependent journeys (J1, J3-J6). Those
  need a real harness session, and a green run against a stubbed model would
  be exactly the false confidence the standing directive forbids.
  """

  use ExUnit.Case, async: false

  alias Tightbeam.{ConnRegistry, DB, Devices, EventLog, Gateway, Idempotency, Ledger, Org, Projection, Rules}
  alias Tightbeam.ClientE2E
  alias Tightbeam.ClientE2E.{Journeys, Scorecard, SimClient}
  alias Tightbeam.ClientE2E.Scorecard.Leg
  alias Tightbeam.Wire.Router

  describe "scorecard algebra" do
    test "a leg passes only when every automated row passed" do
      leg = %Leg{harness: "claude", host: "eezo"}

      passing =
        Scorecard.add(leg, [
          Scorecard.pass("P1", "auth claude"),
          Scorecard.pass("3", "converse", journey: "J1")
        ])

      assert Scorecard.leg_verdict(passing) == :pass
    end

    test "a preflight row is an automated row: its failure fails the leg" do
      leg =
        Scorecard.add(%Leg{harness: "claude", host: "eezo"}, [
          Scorecard.fail("P1", "auth claude", "OAuth session expired"),
          Scorecard.pass("3", "converse", journey: "J1")
        ])

      assert Scorecard.leg_verdict(leg) == :fail
    end

    test "manual rows are verdict-neutral" do
      leg =
        Scorecard.add(%Leg{harness: "claude", host: "eezo"}, [
          Scorecard.pass("3", "converse", journey: "J1"),
          Scorecard.manual("16", "wakes", "J8 is not driven by this driver")
        ])

      assert Scorecard.leg_verdict(leg) == :pass
    end

    test "a leg of only manual rows is INCOMPLETE, never a pass" do
      leg =
        Scorecard.add(%Leg{harness: "claude", host: "eezo"}, [
          Scorecard.manual("16", "wakes", "not driven")
        ])

      assert {:incomplete, ["no automated rows ran on this leg"]} = Scorecard.leg_verdict(leg)
    end

    test "incomplete rows carry their blockers into the verdict" do
      leg =
        Scorecard.add(%Leg{harness: "codex", host: "eezo"}, [
          Scorecard.pass("3", "converse", journey: "J1"),
          Scorecard.incomplete("13b", "model change", "catalog offered no second model", journey: "J6")
        ])

      assert {:incomplete, ["13b: catalog offered no second model"]} = Scorecard.leg_verdict(leg)
    end

    test "a fail outranks an incomplete" do
      leg =
        Scorecard.add(%Leg{harness: "codex", host: "eezo"}, [
          Scorecard.incomplete("13b", "model change", "no second model", journey: "J6"),
          Scorecard.fail("3", "converse", "no assistant reply", journey: "J1")
        ])

      assert Scorecard.leg_verdict(leg) == :fail
    end

    test "a negative-proved divergence passes its row and cites the matrix row" do
      row = Scorecard.pass("4", "tool use", divergence_ref: "harness-support.md#codex-tool-titles")
      leg = Scorecard.add(%Leg{harness: "codex", host: "eezo"}, row)

      assert Scorecard.leg_verdict(leg) == :pass
      assert Scorecard.to_markdown(%Scorecard{legs: [leg]}, ["codex"]) =~ "harness-support.md#codex-tool-titles"
    end

    test "the run verdict is the worst leg verdict" do
      good = Scorecard.add(%Leg{harness: "claude", host: "eezo"}, Scorecard.pass("3", "converse"))
      bad = Scorecard.add(%Leg{harness: "codex", host: "eezo"}, Scorecard.fail("3", "converse", "no reply"))

      assert Scorecard.run_verdict(%Scorecard{legs: [good, bad]}, ["claude", "codex"]) == :fail
    end

    test "a single-harness run is INCOMPLETE however well its leg did (T-PARITY)" do
      leg = Scorecard.add(%Leg{harness: "claude", host: "eezo"}, Scorecard.pass("3", "converse"))

      assert {:incomplete, blockers} =
               Scorecard.run_verdict(%Scorecard{legs: [leg]}, ["claude", "codex"])

      assert Enum.any?(blockers, &(&1 =~ "harness parity"))
      assert Scorecard.run_verdict(%Scorecard{legs: [leg]}, ["claude"]) == :pass
    end

    test "a run with no legs is INCOMPLETE, not a vacuous pass" do
      assert {:incomplete, ["no legs ran"]} = Scorecard.run_verdict(%Scorecard{legs: []}, [])
    end
  end

  describe "the oracle table" do
    test "every step names BOTH a client and a substrate oracle (silence is illegal)" do
      for oracle <- Journeys.oracles() do
        for column <- [:client, :substrate] do
          case Map.fetch!(oracle, column) do
            text when is_binary(text) ->
              assert text != "", "#{oracle.step} has an empty #{column} oracle"

            {:none, reason} ->
              assert is_binary(reason) and reason != "",
                     "#{oracle.step} declares no #{column} counterpart without saying why"

            other ->
              flunk("#{oracle.step} #{column} oracle is #{inspect(other)}")
          end
        end
      end
    end

    test "every journey the driver runs has oracle rows, and every oracle belongs to one" do
      declared = Journeys.oracles() |> Enum.map(& &1.journey) |> Enum.uniq()

      assert Enum.sort(declared) == Enum.sort(Journeys.ids())
    end

    test "steps are unique — two rows for one step would make the scorecard ambiguous" do
      steps = Journeys.automated_steps()
      assert steps == Enum.uniq(steps)
    end

    test "the driver claims every v1 journey step: J0-J8, SMOKE steps 1-16" do
      # J7 (restart) and J8 (wakes) are v1 SPEC scope. They were once recorded
      # as verdict-neutral MANUAL rows, which meant a gateway with broken
      # restart recovery or dead wakes could still earn RUN VERDICT PASS. Only
      # 13c stays manual, and only because it is a RENDERED surface no
      # wire-level driver can witness.
      assert Journeys.automated_steps() ==
               ~w(1 2 3 4 5 6 7 8 9 10 11 12 13a 13b 13c 14 15 16 16b)

      manual_only = for o <- Journeys.oracles(), match?({:none, _}, o.client), do: o.step
      assert manual_only == ["13c"]
    end
  end

  describe "J1's turn-completion oracle" do
    # SMOKE step 3 as amended: the typing indicator is the invariant, its label
    # is harness-reported. These are FRAME-ORDER tests on purpose — the first
    # version of this oracle asked "does a clear exist after the post?", which
    # a stale clear from the previous turn answers, and the pure-map tests it
    # shipped with could not see order at all.
    @session "agent:main:clawline:user:main"

    defp echo(cmid), do: %{"type" => "message", "role" => "user", "clientMessageId" => cmid}
    defp reply(cmid), do: %{"type" => "message", "role" => "assistant", "replyToClientMessageId" => cmid}
    defp typing(active), do: %{"type" => "typing", "active" => active, "sessionKey" => @session}

    defp oracle(frames, opts \\ []) do
      Journeys.turn_oracle_error(%{
        frames: frames,
        session_key: @session,
        client_message_id: "c_1",
        turn: Keyword.get(opts, :turn, %{"status" => "delivered"}),
        timeout_ms: 1_000
      })
    end

    defp healthy_sequence do
      [echo("c_1"), typing(true), reply("c_1"), typing(false)]
    end

    test "the healthy frame order passes" do
      assert oracle(healthy_sequence()) == nil
    end

    test "a plain turn with NO progress label passes — the substrate fabricates no label" do
      # No agent_progress frame anywhere in the sequence.
      refute Enum.any?(healthy_sequence(), &(&1["type"] == "agent_progress"))
      assert oracle(healthy_sequence()) == nil
    end

    test "REGRESSION: a stale clear cannot vouch for an indicator left ON" do
      # false → true → reply. The old oracle matched the leading `false` as
      # "cleared" and started its lingering check after the final `true`, so it
      # passed with the indicator active. This is the bug the cross-review found.
      frames = [echo("c_1"), typing(false), typing(true), reply("c_1")]

      assert oracle(frames) =~ "left ON"
    end

    test "REGRESSION: an indicator that comes back after the reply fails" do
      frames = [echo("c_1"), typing(true), reply("c_1"), typing(false), typing(true)]

      assert oracle(frames) =~ "left ON"
    end

    test "a clear that predates the reply does not count as clearing the turn" do
      frames = [echo("c_1"), typing(true), typing(false), reply("c_1")]

      assert oracle(frames) =~ "never cleared after the turn ended"
    end

    test "an indicator that never turns on fails" do
      frames = [echo("c_1"), reply("c_1"), typing(false)]

      assert oracle(frames) =~ "never turned on"
    end

    test "a typing frame for ANOTHER session cannot satisfy this session's indicator" do
      other = %{"type" => "typing", "active" => true, "sessionKey" => "agent:main:other"}
      frames = [echo("c_1"), other, reply("c_1"), typing(false)]

      assert oracle(frames) =~ "never turned on"
    end

    test "no typing frame at all fails, and says so" do
      assert oracle([echo("c_1"), reply("c_1")]) =~ "never turned on"
    end

    test "a failed turn row is reported ahead of the client symptom it caused" do
      error =
        oracle([echo("c_1")],
          turn: %{"status" => "failed", "error" => "Invalid value for config option model"}
        )

      assert error =~ "turn row is failed"
      assert error =~ "Invalid value for config option model"
      refute error =~ "never turned on"
    end

    test "a missing echo is the first thing reported — nothing else is meaningful without it" do
      assert oracle([typing(true), reply("c_1")], turn: nil) =~ "no echo bubble"
    end

    test "a missing reply is reported once the indicator legs hold" do
      assert oracle([echo("c_1"), typing(true)]) =~ "no assistant reply"
    end

    test "a non-terminal turn row fails even when every frame arrived" do
      assert oracle(healthy_sequence(), turn: %{"status" => "queued"}) =~ "turn row is queued"
    end

    test "indicator_settled_error/3 is reusable by cancel and the queued batch" do
      # J3 and J4 assert the same invariant against their own anchor frame.
      frames = [typing(true), %{"type" => "event"}, typing(false), %{"type" => "event"}]
      # Anchored before the clear: settled. Anchored after it: the clear is stale.
      assert Journeys.indicator_settled_error(frames, @session, 1) == nil
      assert Journeys.indicator_settled_error(frames, @session, 3) =~ "never cleared"
      assert Journeys.indicator_settled_error([typing(true)], @session, 0) =~ "left ON"
      assert Journeys.indicator_settled_error([], @session, 0) =~ "no typing frame at all"
    end
  end

  describe "the concurrency witness (step 10)" do
    alias Tightbeam.ClientE2E.Substrate

    test "simultaneity requires ONE sample holding both sessions" do
      sequential = [%{"a" => 1}, %{}, %{"b" => 1}]
      together = [%{"a" => 1}, %{"a" => 1, "b" => 1}, %{"b" => 1}]

      # This is the laundering the cross-review found: per-session maxima are
      # 1 and 1 in BOTH lists, so a maxima-based witness calls sequential
      # execution concurrent.
      refute Substrate.simultaneous?(sequential, ["a", "b"])
      assert Substrate.simultaneous?(together, ["a", "b"])
      assert Substrate.widest_sample(sequential) == 1
      assert Substrate.widest_sample(together) == 2
    end

    test "an empty sample list witnesses nothing" do
      refute Substrate.simultaneous?([], ["a", "b"])
      assert Substrate.widest_sample([]) == 0
      assert Substrate.busiest_lane([], "a") == 0
    end

    test "the lane witness counts turns within ONE session (J4's strict order)" do
      # Two turns running at once in one lane is the queueing violation; the
      # same samples must not read as concurrency across lanes.
      doubled = [%{"a" => 1}, %{"a" => 2}, %{"a" => 1}]

      assert Substrate.busiest_lane(doubled, "a") == 2
      assert Substrate.busiest_lane([%{"a" => 1}, %{"a" => 1}], "a") == 1
      refute Substrate.simultaneous?(doubled, ["a", "b"])
    end

    test "turn intervals witness overlap without needing a lucky sample" do
      main = %{"startedAt" => 100, "endedAt" => 900}

      assert Substrate.turns_overlapped?(main, %{"startedAt" => 200, "endedAt" => 400})
      assert Substrate.turns_overlapped?(main, %{"startedAt" => 800, "endedAt" => 1_500})
      refute Substrate.turns_overlapped?(main, %{"startedAt" => 950, "endedAt" => 1_200})
    end

    test "touching boundaries are a HAND-OFF, not an overlap" do
      # One turn ending on the same millisecond another begins is exactly the
      # sequential case; an inclusive comparison called it concurrency.
      main = %{"startedAt" => 100, "endedAt" => 900}

      refute Substrate.turns_overlapped?(main, %{"startedAt" => 900, "endedAt" => 1_400})
      refute Substrate.turns_overlapped?(%{"startedAt" => 900, "endedAt" => 1_400}, main)
      refute Substrate.turns_overlapped?(main, %{"startedAt" => 50, "endedAt" => 100})
    end

    test "a turn that never started cannot witness overlap" do
      refute Substrate.turns_overlapped?(%{"startedAt" => nil}, %{"startedAt" => 100})
      refute Substrate.turns_overlapped?(nil, %{"startedAt" => 100})
      refute Substrate.turns_overlapped?(%{"startedAt" => 100}, nil)
    end

    test "a STILL-RUNNING turn extends to now, not to its own start" do
      # endedAt nil means "still going". Collapsing it to a point meant an
      # in-flight turn could never be seen overlapping anything — including the
      # turn queued right beside it.
      now = System.system_time(:millisecond)
      running = %{"startedAt" => now - 5_000, "endedAt" => nil}

      assert Substrate.turns_overlapped?(running, %{"startedAt" => now - 1_000, "endedAt" => now})
      assert Substrate.turns_overlapped?(%{"startedAt" => now - 1_000, "endedAt" => nil}, running)
      # Still bounded by its start: something that ended before it began cannot overlap.
      refute Substrate.turns_overlapped?(running, %{"startedAt" => now - 9_000, "endedAt" => now - 6_000})
    end
  end

  describe "leg teardown reports what actually happened" do
    alias Tightbeam.ClientE2E.LegGateway

    # This behaviour shipped INERT once: teardown computed :still_running or
    # :not_removed and then returned a bare :ok, so the runner's warnings could
    # never fire. A survivor that ignores SIGTERM is the cheapest way to hold
    # the real contract.
    test "a process that outlives SIGTERM returns :still_running and KEEPS the base_dir" do
      base_dir = Path.join(System.tmp_dir!(), "tightbeam-client-e2e-teardown-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(base_dir, "homes"))
      on_exit(fn -> File.rm_rf!(base_dir) end)

      # `trap "" TERM` makes SIGTERM a no-op for this shell. Two details this
      # test needed before it could hold the contract: the LOOP (given a single
      # simple command, sh execs it and the trap dies with the shell it
      # replaced), and the READY file (signalling before the trap is installed
      # kills the survivor on the default disposition and proves nothing).
      ready = Path.join(base_dir, "ready")

      port =
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: ["-c", "trap '' TERM; touch #{ready}; while true; do sleep 1; done"]
        ])

      os_pid = port |> Port.info(:os_pid) |> elem(1)
      wait_for_file(ready, 5_000)

      gateway = %LegGateway{
        base_dir: base_dir,
        port: 0,
        os_pid: os_pid,
        os_command: LegGateway.process_command(os_pid),
        port_ref: nil,
        log_path: Path.join(base_dir, "gateway.log")
      }

      assert {:error, :still_running, ^os_pid} =
               LegGateway.teardown(gateway, exit_timeout_ms: 1_000)

      assert File.dir?(base_dir), "the base_dir must survive a gateway that is still running"

      System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    test "teardown reaps a GRANDCHILD that ignores SIGTERM" do
      # Harness adapters outlive the gateway's SIGTERM and hold the leg's homes
      # open — eight orphans accumulated across one afternoon before teardown
      # reaped anything.
      #
      # The pids asserted here are recorded by the processes THEMSELVES (each
      # echoes its own $$), never derived from descendant_pids/1, or the test
      # would be checking that a function agrees with itself. And the
      # SIGTERM-ignorer is the GRANDCHILD: with a direct child, dropping the
      # recursive descent from descendant_pids/1 would still pass.
      base_dir = Path.join(System.tmp_dir!(), "tightbeam-client-e2e-reap-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base_dir)
      on_exit(fn -> File.rm_rf!(base_dir) end)

      mid_pid_file = Path.join(base_dir, "mid.pid")
      grand_pid_file = Path.join(base_dir, "grand.pid")
      ready = Path.join(base_dir, "ready")
      grand_sh = Path.join(base_dir, "grand.sh")
      mid_sh = Path.join(base_dir, "mid.sh")
      top_sh = Path.join(base_dir, "top.sh")

      # Level 3: ignores SIGTERM, so only a KILL from the reaper ends it.
      File.write!(grand_sh, """
      #!/bin/sh
      trap '' TERM
      echo $$ > #{grand_pid_file}
      touch #{ready}
      while true; do sleep 1; done
      """)

      # Level 2: a real intermediate process, so the grandchild is two hops down.
      File.write!(mid_sh, """
      #!/bin/sh
      echo $$ > #{mid_pid_file}
      #{grand_sh} &
      wait
      """)

      # Level 1: stands in for the gateway BEAM.
      File.write!(top_sh, """
      #!/bin/sh
      #{mid_sh} &
      wait
      """)

      for f <- [grand_sh, mid_sh, top_sh], do: File.chmod!(f, 0o755)

      port = Port.open({:spawn_executable, top_sh}, [:binary, :exit_status])
      top = port |> Port.info(:os_pid) |> elem(1)
      wait_for_file(ready, 10_000)
      wait_for_file(mid_pid_file, 10_000)
      wait_for_file(grand_pid_file, 10_000)

      mid = File.read!(mid_pid_file) |> String.trim()
      grand = File.read!(grand_pid_file) |> String.trim()

      # Independently recorded, and genuinely three distinct processes.
      assert mid != "" and grand != ""
      assert Enum.uniq([to_string(top), mid, grand]) |> length() == 3

      # The recursive descent, pinned directly: the GRANDCHILD's own recorded pid
      # must appear in the tree. Drop the recursion and this fails here, without
      # needing a mutation run to prove it.
      tree = LegGateway.descendant_pids(top)
      assert grand in tree, "descendant_pids/1 must descend past direct children"
      assert mid in tree

      gateway = %LegGateway{
        base_dir: base_dir,
        port: 0,
        os_pid: top,
        # Identity, verified before anything is signalled — even in a test. A
        # raw pid on a busy box can be somebody else's process by the time you
        # signal it.
        os_command: LegGateway.process_command(top),
        port_ref: nil,
        log_path: ""
      }

      assert gateway.os_command =~ "top.sh", "the fixture's identity must be established first"
      assert LegGateway.ours?(gateway)

      assert LegGateway.teardown(gateway, exit_timeout_ms: 3_000, reap_timeout_ms: 3_000) == :ok

      assert {_, 1} = System.cmd("kill", ["-0", grand], stderr_to_stdout: true),
             "the SIGTERM-ignoring GRANDCHILD (#{grand}) outlived teardown"

      assert {_, 1} = System.cmd("kill", ["-0", mid], stderr_to_stdout: true),
             "the intermediate child (#{mid}) outlived teardown"
    end

    test "a recycled pid is NOT signalled — identity is checked, not just liveness" do
      # A pid is a reusable integer. If the process we booted has exited and the
      # number now belongs to somebody else, signalling it kills their work; that
      # is how a cleanup routine takes out another lane. Here the struct names a
      # LIVE pid whose command line does not match what was captured.
      base_dir = Path.join(System.tmp_dir!(), "tightbeam-client-e2e-recycled-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base_dir)
      on_exit(fn -> File.rm_rf!(base_dir) end)
      ready = Path.join(base_dir, "ready")

      port =
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: ["-c", "touch #{ready}; while true; do sleep 1; done"]
        ])

      bystander = port |> Port.info(:os_pid) |> elem(1)
      wait_for_file(ready, 5_000)

      # Same pid, a command line from a process that is gone.
      gateway = %LegGateway{
        base_dir: base_dir,
        port: 0,
        os_pid: bystander,
        os_command: "/usr/bin/some-other-process --that --exited",
        port_ref: nil,
        log_path: ""
      }

      refute LegGateway.ours?(gateway), "a mismatched command line must not read as ours"

      LegGateway.teardown(gateway, exit_timeout_ms: 1_000, reap_timeout_ms: 1_000)

      assert {_, 0} = System.cmd("kill", ["-0", Integer.to_string(bystander)], stderr_to_stdout: true),
             "the bystander holding a recycled pid must be left alone"

      System.cmd("kill", ["-KILL", Integer.to_string(bystander)], stderr_to_stdout: true)
    end

    test "reap_descendants leaves a pid alone once its command line has changed" do
      # The capture named a command that is not what this pid runs now.
      port =
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: ["-c", "while true; do sleep 1; done"]
        ])

      bystander = port |> Port.info(:os_pid) |> elem(1) |> Integer.to_string()

      LegGateway.reap_descendants([{bystander, "/bin/nonexistent-captured-command"}], 1_000)

      assert {_, 0} = System.cmd("kill", ["-0", bystander], stderr_to_stdout: true),
             "a pid whose identity no longer matches the capture must not be signalled"

      System.cmd("kill", ["-KILL", bystander], stderr_to_stdout: true)
    end

    test "a clean stop removes the run-local base_dir and returns :ok" do
      base_dir = Path.join(System.tmp_dir!(), "tightbeam-client-e2e-teardown-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base_dir)

      gateway = %LegGateway{base_dir: base_dir, port: 0, os_pid: nil, os_command: nil, port_ref: nil, log_path: ""}

      assert LegGateway.teardown(gateway) == :ok
      refute File.exists?(base_dir)
    end

    test "a base_dir this driver did not provision is NEVER removed" do
      # The one unrecoverable mistake is deleting a real org.
      base_dir = Path.join(System.tmp_dir!(), "somebody-elses-org-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base_dir)
      on_exit(fn -> File.rm_rf!(base_dir) end)

      gateway = %LegGateway{base_dir: base_dir, port: 0, os_pid: nil, os_command: nil, port_ref: nil, log_path: ""}

      assert LegGateway.teardown(gateway) == :ok
      assert File.dir?(base_dir)
    end
  end

  describe "a non-passing preflight blocks the leg (SMOKE P3)" do
    test "every step is recorded as blocked, and the leg FAILS" do
      row = Scorecard.fail("P-x", "auth x", "OAuth session expired")
      leg = ClientE2E.blocked_leg("x", "testhost", row)

      # The preflight FAIL is what fails the leg; the blocked steps are
      # incomplete, and none of them is silently missing.
      assert Scorecard.leg_verdict(leg) == :fail

      steps = Enum.map(leg.rows, & &1.step)
      assert "P-x" in steps
      assert Enum.sort(steps -- ["P-x"]) == Enum.sort(Journeys.automated_steps())

      blocked = Enum.reject(leg.rows, &(&1.step == "P-x"))
      assert Enum.all?(blocked, &(&1.status == :incomplete))
      assert Enum.all?(blocked, &(&1.note =~ "preflight-blocked"))
    end

    test "an incomplete credential preflight blocks every journey" do
      preflight =
        Scorecard.incomplete("P-codex", "auth codex", "credential liveness unknown: :timeout")

      leg = ClientE2E.blocked_leg("codex", "eezo", preflight)

      assert match?({:incomplete, [_preflight | _blocked]}, Scorecard.leg_verdict(leg))

      blocked = Enum.reject(leg.rows, &(&1.step == "P-codex"))
      assert length(blocked) == length(Journeys.oracles())
      assert Enum.all?(blocked, &(&1.status == :incomplete))
      assert Enum.all?(blocked, &(&1.note =~ "preflight-blocked"))
    end
  end

  describe "credential liveness preflight mapping" do
    setup do
      base_dir =
        Path.join(
          System.tmp_dir!(),
          "tightbeam-client-e2e-credential-live-#{System.unique_integer([:positive])}"
        )

      store = Tightbeam.Credentials.store_dir(base_dir, :openai)
      home = Tightbeam.Homes.home_path(base_dir, "testhost", :codex)
      File.mkdir_p!(store)
      File.mkdir_p!(home)
      File.write!(Path.join(store, "auth.json"), "{}")

      File.write!(
        Path.join(home, "models_cache.json"),
        JSON.encode!(%{
          "models" => [
            %{
              "slug" => "recorded-model",
              "display_name" => "Recorded Model",
              "supported_reasoning_levels" => [],
              "max_input_tokens" => 1_000
            }
          ]
        })
      )

      on_exit(fn -> File.rm_rf!(base_dir) end)
      %{base_dir: base_dir}
    end

    test ":live passes", ctx do
      transport = fn _target, _request ->
        {:ok, %{status: 200, headers: %{}, body: "{}"}}
      end

      assert %{status: :pass} =
               ClientE2E.preflight("codex", ctx.base_dir, transport: transport)
    end

    test ":dead fails", ctx do
      transport = fn _target, _request ->
        {:ok, %{status: 401, headers: %{}, body: ~s({"detail":"rejected"})}}
      end

      assert %{status: :fail, note: note} =
               ClientE2E.preflight("codex", ctx.base_dir, transport: transport)

      assert note =~ "credential rejected"
    end

    test ":unknown is INCOMPLETE and never passes", ctx do
      transport = fn _target, _request -> {:error, :econnrefused} end

      assert %{status: :incomplete, note: note} =
               ClientE2E.preflight("codex", ctx.base_dir, transport: transport)

      assert note =~ "credential liveness unknown"
    end
  end

  describe "scorecard provenance" do
    alias Tightbeam.ClientE2E.Provenance

    setup do
      repo = Path.join(System.tmp_dir!(), "client-e2e-prov-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf!(repo) end)

      git = fn args -> System.cmd("git", args, cd: repo, stderr_to_stdout: true) end
      git.(["init", "-q", "-b", "main"])
      git.(["config", "user.email", "driver@example.test"])
      git.(["config", "user.name", "driver"])
      File.write!(Path.join(repo, "tracked.txt"), "one\n")
      git.(["add", "-A"])
      git.(["commit", "-q", "-m", "seed"])

      %{repo: repo, git: git}
    end

    test "a clean worktree stamps just the sha", ctx do
      assert {:clean, sha} = Provenance.stamp(ctx.repo)
      assert sha =~ ~r/^[0-9a-f]{7,}$/
      assert Provenance.to_header({:clean, sha}) == sha
    end

    test "a tracked edit makes it dirty and shows in the header", ctx do
      File.write!(Path.join(ctx.repo, "tracked.txt"), "two\n")

      assert {:dirty, sha, fingerprint, listing} = Provenance.stamp(ctx.repo)
      assert listing =~ "tracked.txt"
      assert Provenance.to_header({:dirty, sha, fingerprint, listing}) =~ "DIRTY (diff #{fingerprint})"
    end

    test "UNTRACKED content changes the fingerprint" do
      # `git diff HEAD` omits untracked files, so the previous fingerprint gave
      # two different untracked driver sources the same empty-diff hash.
      listing = "?? probe.exs\n"
      dir = Path.join(System.tmp_dir!(), "client-e2e-untracked-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, "probe.exs")

      File.write!(path, "IO.puts(:alpha)")
      alpha = Provenance.fingerprint(dir, listing)

      File.write!(path, "IO.puts(:beta)")
      beta = Provenance.fingerprint(dir, listing)

      refute alpha == beta, "same filename, different bytes must not share a fingerprint"
    end

    test "a content change INSIDE an untracked directory changes the fingerprint", ctx do
      # Plain `git status --porcelain` reports a wholly-untracked subtree as one
      # `?? dir/` entry. A directory has no bytes to hash, so every edit inside
      # it used to fingerprint identically — an untracked driver tree could
      # change completely and claim the same provenance.
      nested = Path.join([ctx.repo, "e2e", "sim"])
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "driver.exs"), "IO.puts(:alpha)")

      assert {:dirty, _sha, alpha, listing} = Provenance.stamp(ctx.repo)
      assert listing =~ "e2e/sim/driver.exs", "the nested file must be listed in its own right"

      File.write!(Path.join(nested, "driver.exs"), "IO.puts(:beta)")
      assert {:dirty, _sha, beta, _listing} = Provenance.stamp(ctx.repo)

      refute alpha == beta, "a change inside an untracked directory must change the fingerprint"
    end

    test "adding a file inside an untracked directory changes the fingerprint", ctx do
      nested = Path.join(ctx.repo, "e2e")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "one.exs"), "one")

      assert {:dirty, _, before, _} = Provenance.stamp(ctx.repo)

      File.write!(Path.join(nested, "two.exs"), "two")
      assert {:dirty, _, later, _} = Provenance.stamp(ctx.repo)

      refute before == later
    end

    test "untracked paths are read off the porcelain listing" do
      listing = "?? b.exs\n M tracked.txt\n?? a.exs\n"
      assert Provenance.untracked_paths(listing) == ["a.exs", "b.exs"]
    end
  end

  describe "the client's session-status decode contract" do
    test "a full payload has no gaps" do
      assert Journeys.decode_contract_gaps(%{
               "sessionKey" => "agent:main:user:flynn",
               "display" => %{"model" => "fable"},
               "run" => %{"state" => "idle"},
               "capabilities" => %{}
             }) == []
    end

    test "each field the Swift decoder requires is reported by name when missing" do
      full = %{
        "sessionKey" => "agent:main:user:flynn",
        "display" => %{"model" => "fable"},
        "run" => %{"state" => "idle"},
        "capabilities" => %{}
      }

      for key <- ~w(sessionKey display run capabilities) do
        assert Journeys.decode_contract_gaps(Map.delete(full, key)) == [key]
      end

      assert Journeys.decode_contract_gaps(put_in(full, ["run"], %{})) == ["run.state"]
    end
  end

  describe "the driver cannot pass vacuously" do
    test "against a closed port the leg FAILS with the client's own transport error" do
      {leg, _gateway} =
        ClientE2E.run_leg(
          host: "127.0.0.1",
          port: closed_port(),
          base_dir: System.tmp_dir!(),
          # From the registry, not a literal: the driver has no default harness.
          harness: registered_harness(),
          host_name: "testhost"
        )

      assert Scorecard.leg_verdict(leg) == :fail

      boot = Enum.find(leg.rows, &(&1.step == "1"))
      assert boot.status == :fail
      assert boot.note =~ "econnrefused"

      # Every step the driver claims to automate is accounted for; a step that
      # simply vanished from the report is how a broken run looks green.
      assert Enum.sort(Enum.map(leg.rows, & &1.step)) == Enum.sort(Journeys.automated_steps())
    end

    test "run_leg REFUSES to guess a harness" do
      # A default harness silently pins one leg and survives a registry change.
      assert_raise KeyError, fn ->
        ClientE2E.run_leg(host: "127.0.0.1", port: closed_port(), base_dir: System.tmp_dir!())
      end
    end

    test "J7 reports itself incomplete without a gateway handle rather than passing" do
      ctx = %{
        base_dir: System.tmp_dir!(),
        host: "127.0.0.1",
        port: 0,
        client: nil,
        main_key: "agent:main:x",
        gateway: nil,
        leg: %{},
        turn_timeout_ms: 1_000,
        settle_ms: 1
      }

      {_ctx, rows} = Journeys.run(ctx, "J7")

      assert Enum.map(rows, & &1.step) == ["14", "15"]
      assert Enum.all?(rows, &(&1.status == :incomplete))
      assert Enum.all?(rows, &(&1.note =~ "gateway"))
    end
  end

  defp wait_for_file(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if File.exists?(path) or System.monotonic_time(:millisecond) >= deadline do
        :done
      else
        Process.sleep(50)
        :wait
      end
    end)
    |> Enum.find(&(&1 == :done))

    assert File.exists?(path), "the survivor process never signalled readiness"
  end

  defp registered_harness, do: Tightbeam.Harness.all() |> hd() |> then(& &1.wire_name())

  describe "the sim client against a real gateway" do
    setup :real_gateway

    test "J0 passes: the wire pairs, authenticates, seeds Main and syncs", ctx do
      {:ok, %{token: token}} =
        SimClient.pair("127.0.0.1", ctx.port, device_id: "sim-j0", claimed_name: "Flynn")

      {:ok, client} = SimClient.connect("127.0.0.1", ctx.port, token, device_id: "sim-j0")

      {journey_ctx, rows} = Journeys.run(journey_ctx(ctx, client), "J0")
      SimClient.disconnect(journey_ctx.client)

      assert Enum.map(rows, & &1.status) == [:pass, :pass],
             "J0 rows: #{inspect(Enum.map(rows, &{&1.step, &1.status, &1.note}))}"

      assert journey_ctx.main_key =~ "main"
    end

    test "an unpaired token is refused and the driver reports the gateway's reason", ctx do
      assert {:error, "auth_failed"} =
               SimClient.connect("127.0.0.1", ctx.port, "not-a-token", device_id: "sim-bad")
    end

    test "posting with a malformed id is refused on the wire, not silently dropped", ctx do
      {:ok, %{token: token}} =
        SimClient.pair("127.0.0.1", ctx.port, device_id: "sim-bad-id", claimed_name: "Flynn")

      {:ok, client} = SimClient.connect("127.0.0.1", ctx.port, token, device_id: "sim-bad-id")
      watermark = SimClient.mark(client)
      key = Org.personal_session_key(client.user_id)

      :ok =
        Tightbeam.ClientE2E.WS.send_text(
          client.ws,
          JSON.encode!(%{"type" => "message", "id" => "nope", "sessionKey" => key, "content" => "hi"})
        )

      assert {:ok, frame, client} =
               SimClient.await(client, watermark, &(&1["type"] == "error"), 5_000)

      assert frame["code"] == "invalid_message"
      SimClient.disconnect(client)
    end
  end

  defp journey_ctx(ctx, client) do
    %{
      base_dir: ctx.base_dir,
      host: "127.0.0.1",
      port: ctx.port,
      client: client,
      main_key: nil,
      gateway: nil,
      leg: %{harness: "claude", host: "testhost", model: "fable"},
      turn_timeout_ms: 10_000,
      settle_ms: 250
    }
  end

  defp real_gateway(_ctx) do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-client-e2e-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    db = :"client_e2e_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: Path.join(base_dir, "state.db"), name: db})

    for module <- [Devices, EventLog, Idempotency, Ledger, Org, Projection],
        do: :ok = module.ensure_schema(db)

    start_supervised!(%{
      id: :client_e2e_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    handlers = Gateway.handlers(%{db: db, base_dir: base_dir, port: 0})
    Rules.load!(Path.join(base_dir, "no-rules"), Map.keys(handlers), %{})
    on_exit(fn -> Rules.load!(Path.join(System.tmp_dir!(), "client-e2e-reset"), [], %{}) end)

    router_opts =
      Router.init(
        db: db,
        base_dir: base_dir,
        handlers: handlers,
        conn_registry: Tightbeam.ConnRegistry,
        cli_token: "tbc_client_e2e",
        session_status: fn _key -> nil end,
        defaults: %{
          archetype: "default",
          host: "testhost",
          harness: :claude,
          provider: fn -> :anthropic end,
          model: "fable"
        }
      )

    bandit =
      start_supervised!(
        {Bandit, plug: {Router, router_opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    %{db: db, base_dir: base_dir, port: port}
  end

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
