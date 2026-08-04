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

  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    ConnRegistry,
    DB,
    Gateway,
    Org,
    Rules
  }

  alias Tightbeam.ClientE2E
  alias Tightbeam.ClientE2E.{Journeys, Scorecard, SimClient}
  alias Tightbeam.ClientE2E.Scorecard.Leg
  alias Tightbeam.Wire.Router

  describe "scorecard algebra" do
    test "journey coverage makes a green subset INCOMPLETE while failure still wins" do
      full = green_leg(Journeys.ids())
      subset = green_leg(["J0"])

      failed_subset =
        Scorecard.add(
          subset,
          Scorecard.fail("2", "pair", "pairing failed", journey: "J0")
        )

      assert Scorecard.leg_verdict(full) == :pass
      assert Scorecard.run_verdict(%Scorecard{legs: [full]}, ["claude"]) == :pass

      assert {:incomplete, subset_blockers} = Scorecard.leg_verdict(subset)
      assert Enum.any?(subset_blockers, &(&1 =~ "journey coverage"))

      assert {:incomplete, run_blockers} =
               Scorecard.run_verdict(%Scorecard{legs: [subset]}, ["claude"])

      assert Enum.any?(run_blockers, &(&1 =~ "journey coverage"))
      assert Scorecard.leg_verdict(failed_subset) == :fail
      assert Scorecard.run_verdict(%Scorecard{legs: [failed_subset]}, ["claude"]) == :fail
    end

    test "a leg passes only when every automated row passed" do
      passing =
        Journeys.ids()
        |> green_leg()
        |> Scorecard.add(Scorecard.pass("P1", "auth claude"))

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
        Journeys.ids()
        |> green_leg()
        |> Scorecard.add(Scorecard.manual("16", "wakes", "J8 is not driven by this driver"))

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
        Journeys.ids()
        |> green_leg("codex")
        |> Scorecard.add(
          Scorecard.incomplete("13b", "model change", "catalog offered no second model",
            journey: "J6"
          )
        )

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
      row =
        Scorecard.pass("4", "tool use", divergence_ref: "harness-support.md#codex-tool-titles")

      leg = Journeys.ids() |> green_leg("codex") |> Scorecard.add(row)

      assert Scorecard.leg_verdict(leg) == :pass

      assert Scorecard.to_markdown(%Scorecard{legs: [leg]}, ["codex"]) =~
               "harness-support.md#codex-tool-titles"
    end

    test "the run verdict is the worst leg verdict" do
      good = Scorecard.add(%Leg{harness: "claude", host: "eezo"}, Scorecard.pass("3", "converse"))

      bad =
        Scorecard.add(
          %Leg{harness: "codex", host: "eezo"},
          Scorecard.fail("3", "converse", "no reply")
        )

      assert Scorecard.run_verdict(%Scorecard{legs: [good, bad]}, ["claude", "codex"]) == :fail
    end

    test "a single-harness run is INCOMPLETE however well its leg did (T-PARITY)" do
      leg = green_leg(Journeys.ids())

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

    defp reply(cmid),
      do: %{"type" => "message", "role" => "assistant", "replyToClientMessageId" => cmid}

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

  describe "the wake oracle (steps 16 and 16b)" do
    defp wake_observed(overrides \\ %{}) do
      Map.merge(
        %{
          wake_id: "w_1",
          turn: %{"wakeId" => "w_1", "status" => "delivered"},
          message_id: "m_1",
          stamped: %{"id" => "m_1", "sender" => "user:admin"},
          reply: %{"content" => "anything at all", "replyToMessageId" => "m_1"}
        },
        overrides
      )
    end

    test "the healthy chain passes" do
      assert Journeys.wake_oracle_error(wake_observed()) == nil
    end

    test "reply CONTENT is not asserted — effectiveness is evals' concern, not e2e's" do
      # The literal the removed assertion demanded, and two answers a competent
      # agent might give instead. All three pass: the substrate behaved
      # identically in every case.
      for content <- ["WAKE OK", "Sure — done.", "I ran it; the answer is 4."] do
        assert Journeys.wake_oracle_error(wake_observed(%{reply: %{"content" => content}})) == nil
      end

      # Even an empty reply body passes, because a reply ARRIVED and correlated.
      assert Journeys.wake_oracle_error(wake_observed(%{reply: %{"content" => ""}})) == nil
    end

    test "a dispatch that returned no wakeId fails" do
      assert Journeys.wake_oracle_error(wake_observed(%{wake_id: nil})) =~ "returned no wakeId"
    end

    test "no turn row for the dispatched wake fails, and names the wake" do
      error = Journeys.wake_oracle_error(wake_observed(%{turn: nil}))
      assert error =~ "no turn row was ever created"
      assert error =~ "w_1"
    end

    test "REGRESSION: another wake's turn row cannot vouch for this wake" do
      # The whole point of the wakeId chain: J8 has two wakes in flight, so a
      # turn row carrying the OTHER wakeId must not satisfy this one.
      error =
        Journeys.wake_oracle_error(
          wake_observed(%{turn: %{"wakeId" => "w_other", "status" => "delivered"}})
        )

      assert error =~ "not the dispatched"
      assert error =~ "w_other"
    end

    test "a turn row naming no delivered message fails" do
      assert Journeys.wake_oracle_error(wake_observed(%{message_id: nil})) =~
               "names no delivered message"
    end

    test "a prompt that never landed as a sender-tagged message fails" do
      assert Journeys.wake_oracle_error(wake_observed(%{stamped: nil})) =~ "sender-tagged message"
    end

    test "no correlated assistant reply fails" do
      assert Journeys.wake_oracle_error(wake_observed(%{reply: nil})) =~ "no assistant reply"
    end

    test "a non-delivered turn row fails even when every frame arrived" do
      assert Journeys.wake_oracle_error(
               wake_observed(%{turn: %{"wakeId" => "w_1", "status" => "queued"}})
             ) =~ "turn row is queued"
    end

    test "a failed turn row carries its error text into the row" do
      error =
        Journeys.wake_oracle_error(
          wake_observed(%{
            turn: %{"wakeId" => "w_1", "status" => "failed", "error" => "adapter died"}
          })
        )

      assert error =~ "turn row is failed"
      assert error =~ "adapter died"
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
      refute Substrate.turns_overlapped?(running, %{
               "startedAt" => now - 9_000,
               "endedAt" => now - 6_000
             })
    end
  end

  describe "J5's parallelism-opportunity gate (step 10)" do
    defp turn(created, started, ended),
      do: %{"createdAt" => created, "startedAt" => started, "endedAt" => ended}

    test "a run whose posts never overlapped had no opportunity — INCOMPLETE, not FAIL" do
      # slow 100..105, B 110..115, done 120..125: each posted after the previous
      # finished. Comparing B's enqueue against `done`'s close would say
      # otherwise for every sequential run, because B exists before `done` does.
      refute Journeys.lanes_had_opportunity?(
               turn(100, 100, 105),
               turn(108, 110, 115),
               turn(118, 120, 125)
             )
    end

    test "Smoke B enqueued while Main's slow turn ran had the opportunity" do
      assert Journeys.lanes_had_opportunity?(
               turn(100, 100, 500),
               turn(200, 510, 600),
               turn(610, 620, 700)
             )
    end

    test "Main's second post enqueued while Smoke B ran had the opportunity" do
      # slow finished long before B was posted, so the first pair says nothing —
      # but `done` was queued while B was still running and ran after it anyway.
      assert Journeys.lanes_had_opportunity?(
               turn(100, 100, 200),
               turn(210, 220, 500),
               turn(215, 500, 600)
             )
    end

    test "a turn row the substrate never wrote cannot witness an opportunity" do
      refute Journeys.lanes_had_opportunity?(nil, turn(200, 210, 300), nil)
      refute Journeys.lanes_had_opportunity?(turn(100, 100, nil), turn(200, 210, 300), nil)
    end
  end

  describe "J5's delivery oracle (step 10)" do
    @main "agent:main:clawline:user:main"
    @smoke_b "agent:main:clawline:user:main s_b"

    # The client-e2e-v1 posts: Main's slow prompt, Smoke B's trivial one beside
    # it, then a second Main post. `turns` gives each post's substrate interval
    # and `seqs` the store's commit order for its reply; frame arrival times are
    # the driver's own clock, on the same scale.
    # `seqs` is `[slow: {seq, committed_at}, ...]`; a bare seq means the store
    # stamped the reply the instant its turn ended, which is what happens when
    # nothing stalls between the write and the publish.
    defp j5_expected(seqs, turns) do
      for {id, key} <- [{"slow", @main}, {"b", @smoke_b}, {"done", @main}] do
        name = String.to_atom(id)
        {started, ended} = Keyword.fetch!(turns, name)

        {seq, committed_at} =
          case seqs[name] do
            {seq, committed_at} -> {seq, committed_at}
            seq -> {seq, ended}
          end

        %{
          id: id,
          session_key: key,
          committed_seq: seq,
          committed_at: committed_at,
          started_at: started,
          ended_at: ended
        }
      end
    end

    # B answers DURING Main's slow turn: Main 100..900, B 110..300, done 900..950.
    defp b_first_turns, do: [slow: {100, 900}, b: {110, 300}, done: {900, 950}]

    # The models the other way round: B's trivial prompt in a FRESH stream
    # outlives Main's deliberately slow one in a warm stream.
    defp b_last_turns, do: [slow: {100, 300}, b: {110, 900}, done: {300, 400}]

    defp j5_reply(session_key, cmid, at),
      do: %{
        "type" => "message",
        "role" => "assistant",
        "sessionKey" => session_key,
        "replyToClientMessageId" => cmid,
        "receivedAt" => at
      }

    defp j5_running(session_key, cmid, at),
      do: j5_turn_state(session_key, cmid, "running", false, at)

    defp j5_delivered(session_key, cmid, at),
      do: j5_turn_state(session_key, cmid, "delivered", true, at)

    defp j5_turn_state(session_key, cmid, state, terminal?, at) do
      %{
        "type" => "event",
        "event" => "prompt_turn_state",
        "receivedAt" => at,
        "payload" => %{
          "messageId" => cmid,
          "sessionKey" => session_key,
          "state" => state,
          "terminalState" => terminal?
        }
      }
    end

    defp b_answers_first do
      [
        j5_running(@main, "slow", 100),
        j5_running(@smoke_b, "b", 110),
        j5_reply(@smoke_b, "b", 300),
        j5_delivered(@smoke_b, "b", 300),
        j5_reply(@main, "slow", 900),
        j5_delivered(@main, "slow", 900),
        j5_running(@main, "done", 900),
        j5_reply(@main, "done", 950),
        j5_delivered(@main, "done", 950)
      ]
    end

    defp b_answers_last do
      [
        j5_running(@main, "slow", 100),
        j5_running(@smoke_b, "b", 110),
        j5_reply(@main, "slow", 300),
        j5_delivered(@main, "slow", 300),
        j5_running(@main, "done", 300),
        j5_reply(@main, "done", 400),
        j5_delivered(@main, "done", 400),
        j5_reply(@smoke_b, "b", 900),
        j5_delivered(@smoke_b, "b", 900)
      ]
    end

    # The oracle owns its own delivery budget (1s against a 0-1ms path); the
    # fixtures below sit far from it in both directions.
    defp j5_oracle(frames, seqs, turns),
      do: Journeys.concurrency_delivery_error(frames, j5_expected(seqs, turns))

    test "the client-e2e-v1 shape passes: B answers during Main's slow turn" do
      assert j5_oracle(b_answers_first(), [b: 1, slow: 2, done: 3], b_first_turns()) == nil
    end

    test "REGRESSION: a lane whose reply commits LAST is not a delivery failure" do
      # The field case (codex leg, 2026-08-04): B's trivial turn took 20.4s
      # against Main's 12.6s, so B's reply committed 8.2s after Main's turn had
      # already ended — publish->arrival measured 0ms on all three frames. The
      # old rule asked only whether B's bubble preceded Main's and reported "a
      # delayed client frame", blaming the wire for which prompt the model
      # finished first.
      assert j5_oracle(b_answers_last(), [slow: 1, done: 2, b: 3], b_last_turns()) == nil
    end

    test "a post the store holds no reply for fails BEFORE the client legs can compare" do
      # Absence must not be representable as success: with no committed seq, the
      # order lists would otherwise agree on what they both omit.
      assert j5_oracle(b_answers_first(), [b: 1, slow: 2, done: nil], b_first_turns()) =~
               "holds no reply row for [\"done\"]"
    end

    test "a reply the client never received fails, and names it" do
      frames = Enum.reject(b_answers_first(), &(&1["replyToClientMessageId"] == "b"))

      assert j5_oracle(frames, [b: 1, slow: 2, done: 3], b_first_turns()) =~
               "never received: [\"b\"]"
    end

    test "replies shown in an order their OWN stream never committed fail" do
      # Main delivered slow -> done against a store that committed done -> slow:
      # the shape a publication that does not ride commit order produces, and
      # the shape ConnRegistry's per-session cursor turns into a permanently
      # dropped frame. This asserts the ORACLE reports it; J5's own three posts
      # cannot produce it, and the moduledoc says so rather than letting the
      # row imply coverage it does not have.
      assert j5_oracle(b_answers_last(), [done: 1, slow: 2, b: 3], b_last_turns()) =~
               "an order the store never committed"
    end

    test "two streams interleaving differently from the global seq order is NOT a defect" do
      # B commits seq 1 but publishes after Main's seq 2: the streams' cursors
      # are independent, so the client seeing slow -> b -> done while the store
      # committed b -> slow -> done is ordinary concurrency. A global order
      # check would fail this healthy run.
      interleaved = [
        j5_running(@main, "slow", 100),
        j5_running(@smoke_b, "b", 110),
        j5_reply(@main, "slow", 290),
        j5_delivered(@main, "slow", 290),
        j5_reply(@smoke_b, "b", 295),
        j5_delivered(@smoke_b, "b", 295),
        j5_running(@main, "done", 300),
        j5_reply(@main, "done", 350),
        j5_delivered(@main, "done", 350)
      ]

      turns = [slow: {100, 290}, b: {110, 295}, done: {300, 350}]

      assert j5_oracle(interleaved, [b: 1, slow: 2, done: 3], turns) == nil
    end

    test "cross-talk is caught for EVERY post, not just Smoke B's" do
      # Main's slow reply delivered into Smoke B's stream. The journey checks
      # this for all three posts before the concurrency gate as well; the leg is
      # here so the oracle refuses it on its own evidence rather than relying on
      # a caller to have looked first.
      frames =
        Enum.map(b_answers_first(), fn frame ->
          if frame["replyToClientMessageId"] == "slow",
            do: %{frame | "sessionKey" => @smoke_b},
            else: frame
        end)

      assert j5_oracle(frames, [b: 1, slow: 2, done: 3], b_first_turns()) =~
               "cross-talk: [\"slow\"]"
    end

    test "a DUPLICATE bubble in the wrong stream is cross-talk too" do
      # The post is answered correctly first, then answered again in somebody
      # else's stream. A check that stopped at the first correctly-labelled
      # frame would call this healthy while a client renders the second bubble
      # in the wrong session.
      duplicate = j5_reply(@main, "b", 305)

      frames =
        Enum.flat_map(b_answers_first(), fn frame ->
          if frame["replyToClientMessageId"] == "b" and frame["type"] == "message",
            do: [frame, duplicate],
            else: [frame]
        end)

      assert j5_oracle(frames, [b: 1, slow: 2, done: 3], b_first_turns()) =~
               "cross-talk: [\"b\"]"
    end

    test "a turn state labelled with the wrong stream cannot stand in for one the client saw" do
      # slow's running/terminal frames relabelled to Smoke B. Correlating a turn
      # state by messageId alone would accept them as Main's.
      frames =
        Enum.map(b_answers_first(), fn frame ->
          if get_in(frame, ["payload", "messageId"]) == "slow",
            do: put_in(frame, ["payload", "sessionKey"], @smoke_b),
            else: frame
        end)

      assert j5_oracle(frames, [b: 1, slow: 2, done: 3], b_first_turns()) =~
               "before its own turn's terminal state"
    end

    test "a reply held behind its own turn's close fails, though its order is right" do
      # B's reply committed last and arrives last, so the order leg is happy —
      # but it arrives AFTER its own turn's terminal state, which the substrate
      # publishes immediately after the reply. Only this leg sees it.
      frames = [
        j5_running(@main, "slow", 100),
        j5_running(@smoke_b, "b", 110),
        j5_reply(@main, "slow", 300),
        j5_delivered(@main, "slow", 300),
        j5_running(@main, "done", 300),
        j5_reply(@main, "done", 400),
        j5_delivered(@main, "done", 400),
        j5_delivered(@smoke_b, "b", 900),
        j5_reply(@smoke_b, "b", 905)
      ]

      assert j5_oracle(frames, [slow: 1, done: 2, b: 3], b_last_turns()) =~
               "before its own turn's terminal state"
    end

    test "a turn whose terminal state never arrived fails — the indicator is left spinning" do
      frames = Enum.reject(b_answers_first(), &(get_in(&1, ["payload", "state"]) == "delivered"))

      assert j5_oracle(frames, [b: 1, slow: 2, done: 3], b_first_turns()) =~
               "before its own turn's terminal state"
    end

    test "frames flushed in perfect order once both lanes were done fail the liveness leg" do
      # Every earlier leg holds — nothing dropped, committed order preserved,
      # each reply before its own terminal frame, no cross-talk, and the flush
      # lands the instant the last turn closes, so it is inside the delivery
      # budget for every reply. Only the question "was any of it delivered WHILE
      # the other lane was running" can tell this from live delivery — 951 is
      # the first millisecond at which no turn of this journey is still open.
      flushed = Enum.map(b_answers_first(), fn frame -> %{frame | "receivedAt" => 951} end)

      assert j5_oracle(flushed, [b: 1, slow: 2, done: 3], b_first_turns()) =~
               "while another of these streams' turns was still open"
    end

    test "REGRESSION: one timely reply cannot launder another lane's delayed frame" do
      # The lanes genuinely overlapped (B runs 110..900 across both of Main's
      # turns), commit and arrival order agree, and each reply precedes its own
      # terminal frame — so every other leg holds. B's frames simply arrive five
      # seconds after B's turn closed. An existential liveness check passes this
      # on the strength of Main's timely replies; the per-reply budget is what
      # sees it.
      delayed = [
        j5_running(@main, "slow", 100),
        j5_running(@smoke_b, "b", 110),
        j5_reply(@main, "slow", 300),
        j5_delivered(@main, "slow", 300),
        j5_running(@main, "done", 300),
        j5_reply(@main, "done", 400),
        j5_delivered(@main, "done", 400),
        j5_reply(@smoke_b, "b", 5_900),
        j5_delivered(@smoke_b, "b", 5_901)
      ]

      turns = [slow: {100, 300}, b: {110, 900}, done: {300, 400}]

      assert j5_oracle(delayed, [slow: 1, done: 2, b: 3], turns) =~
               "[\"b\"] reached the client more than"
    end

    test "an arrival landing exactly on a turn's boundary is not a liveness witness" do
      # Both clocks are millisecond truncations of one source, so a tie cannot
      # say whether the frame arrived while the other turn was open or just as
      # it closed. An oracle must not accept ambiguity as proof: a flush timed
      # to the millisecond of the last close would otherwise read as live.
      frames = [
        j5_running(@main, "slow", 100),
        j5_running(@smoke_b, "b", 110),
        j5_reply(@smoke_b, "b", 300),
        j5_delivered(@smoke_b, "b", 300),
        j5_reply(@main, "slow", 300),
        j5_delivered(@main, "slow", 300),
        j5_running(@main, "done", 300),
        j5_reply(@main, "done", 350),
        j5_delivered(@main, "done", 350)
      ]

      turns = [slow: {100, 300}, b: {110, 300}, done: {300, 350}]

      assert j5_oracle(frames, [b: 1, slow: 2, done: 3], turns) =~
               "while another of these streams' turns was still open"
    end

    test "a reply the store never stamped fails the delivery bound rather than skipping it" do
      assert j5_oracle(
               b_answers_first(),
               [b: {1, nil}, slow: 2, done: 3],
               b_first_turns()
             ) =~ "[\"b\"] reached the client more than"
    end

    test "REGRESSION: a stall between the commit and the publish is caught" do
      # THE defect this lane was chartered for. B's reply is stamped at 150 and
      # its frame arrives at 5900 — but `turns.endedAt` is written after the
      # runner publishes, so B's turn row reads 110..5901 and the stall drags
      # the turn's own close along with it. Judged against `endedAt` the arrival
      # looks instant, and Main's 300ms reply even sits strictly inside B's
      # inflated window. Only the store's own stamp sees it.
      stalled = [
        j5_running(@main, "slow", 100),
        j5_running(@smoke_b, "b", 110),
        j5_reply(@main, "slow", 300),
        j5_delivered(@main, "slow", 301),
        j5_running(@main, "done", 301),
        j5_reply(@main, "done", 400),
        j5_delivered(@main, "done", 401),
        j5_reply(@smoke_b, "b", 5_900),
        j5_delivered(@smoke_b, "b", 5_902)
      ]

      turns = [slow: {100, 300}, b: {110, 5_901}, done: {301, 400}]
      seqs = [slow: {1, 300}, done: {2, 400}, b: {3, 150}]

      assert j5_oracle(stalled, seqs, turns) =~ "[\"b\"] reached the client more than"
    end

    test "a driver that recorded no arrival time refuses to judge liveness" do
      undated = Enum.map(b_answers_first(), &Map.delete(&1, "receivedAt"))

      assert j5_oracle(undated, [b: 1, slow: 2, done: 3], b_first_turns()) =~
               "recorded no arrival time"
    end
  end

  describe "leg provisioning carries the template's adapters (#102)" do
    alias Tightbeam.ClientE2E.LegGateway

    # A leg provisioned WITHOUT adapters/ boots with zero ACP adapters: its own
    # boot summary says NOT READY, every spawn faults while npm spends minutes
    # installing, and the run is poisoned before turn 1. The copy is same-host
    # by construction, so the template's node_modules (native deps included)
    # and its relative .bin symlinks are valid as-is.
    test "provision! copies adapters/ alongside auth/, homes/ and identity/ — never state.db" do
      template =
        Path.join(
          System.tmp_dir!(),
          "tightbeam-client-e2e-template-#{System.unique_integer([:positive])}"
        )

      base_dir = template <> "-leg-client-e2e"
      on_exit(fn -> File.rm_rf!(template) end)
      on_exit(fn -> File.rm_rf!(base_dir) end)

      adapter = Path.join(["adapters", "node_modules", ".bin", "claude-agent-acp"])

      for rel <- [adapter, "auth/claude/token", "homes/marker", "identity/marker"] do
        path = Path.join(template, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, rel)
      end

      # History must NOT ride along: a fresh leg with the template's state.db is
      # not a fresh leg.
      File.write!(Path.join(template, "state.db"), "history")

      LegGateway.provision!(template, base_dir)

      assert File.exists?(Path.join(base_dir, adapter)),
             "the template's installed adapters must ride into the leg"

      for rel <- ["auth/claude/token", "homes/marker", "identity/marker"] do
        assert File.exists?(Path.join(base_dir, rel))
      end

      refute File.exists?(Path.join(base_dir, "state.db"))
    end
  end

  describe "the driver's readiness gate (#102)" do
    alias Tightbeam.ClientE2E.LegGateway
    alias Tightbeam.Readiness

    # The defect this gate exists for: the leg gateway's own boot summary said
    # NOT READY, with the exact remedy, and the driver walked journeys anyway.
    # These tests fake only the READ — the log content is produced by the REAL
    # renderer (Tightbeam.Readiness.render/2), so the parser is pinned to the
    # renderer's actual shapes rather than to a hand-written imitation.

    test "a READY verdict naming the leg admits it" do
      dir = gate_dir!()

      lines =
        Readiness.render(
          %{runnable?: true, harnesses: [readiness_row("claude", %{})]},
          %{base_dir: dir}
        )

      gateway = gate_gateway!(dir, ["boot noise" | lines])

      assert LegGateway.await_runnable(gateway, "claude", "testhost",
               timeout_ms: 2_000,
               poll_ms: 50,
               progress: quiet()
             ) == :ok
    end

    test "a NOT READY verdict refuses the leg, quoting the gateway's own remedy" do
      dir = gate_dir!()
      missing = Path.join([dir, "adapters", "node_modules", ".bin", "claude-agent-acp"])

      lines =
        Readiness.render(
          %{
            runnable?: false,
            harnesses: [
              readiness_row("claude", %{adapter: {:missing, missing}, runnable?: false})
            ]
          },
          %{base_dir: dir}
        )

      gateway = gate_gateway!(dir, lines)

      assert {:error, {:not_ready, quoted}} =
               LegGateway.await_runnable(gateway, "claude", "testhost",
                 timeout_ms: 2_000,
                 poll_ms: 50,
                 progress: quiet()
               )

      # The refusal must carry the gateway's OWN words: the verdict, the leg's
      # gap, and the remedy the operator is told to run.
      assert quoted =~ "NOT READY"
      assert quoted =~ "claude on testhost:"
      assert quoted =~ "ACP adapter missing at #{missing}"

      assert quoted =~
               "install its pinned adapters automatically when the next session is spawned"

      refute quoted =~ "tightbeam assimilate"
      assert quoted =~ "Diagnose further with: mix tightbeam.doctor"
    end

    test "READY for another harness still refuses a leg the summary reports blocked" do
      dir = gate_dir!()
      missing = Path.join([dir, "adapters", "node_modules", ".bin", "claude-agent-acp"])

      lines =
        Readiness.render(
          %{
            runnable?: true,
            harnesses: [
              readiness_row("codex", %{provider: :openai}),
              readiness_row("claude", %{adapter: {:missing, missing}, runnable?: false})
            ]
          },
          %{base_dir: dir}
        )

      gateway = gate_gateway!(dir, lines)

      assert LegGateway.await_runnable(gateway, "codex", "testhost",
               timeout_ms: 2_000,
               poll_ms: 50,
               progress: quiet()
             ) == :ok

      assert {:error, {:not_ready, quoted}} =
               LegGateway.await_runnable(gateway, "claude", "testhost",
                 timeout_ms: 2_000,
                 poll_ms: 50,
                 progress: quiet()
               )

      assert quoted =~ "claude on testhost:"
      assert quoted =~ "ACP adapter missing at #{missing}"
    end

    test "no verdict waits, names what it is waiting on, then fails legibly" do
      dir = gate_dir!()

      # An open Spinup start line (no complete/failed closer) is the known slow
      # case, and the wait must NAME it — installing and broken are otherwise
      # indistinguishable silence.
      gateway =
        gate_gateway!(dir, [
          "Running Tightbeam.Wire.Router with Bandit 1.0 at 127.0.0.1:0 (http)",
          "installing ACP adapters into #{dir}/adapters on testhost — npm can take minutes on a cold cache"
        ])

      parent = self()

      assert {:error, {:no_verdict, detail}} =
               LegGateway.await_runnable(gateway, "claude", "testhost",
                 timeout_ms: 300,
                 poll_ms: 50,
                 progress: &send(parent, {:progress, &1})
               )

      assert detail =~ "never published its boot readiness verdict"
      assert detail =~ "ACP adapters installing"

      assert_received {:progress, progress_line}
      assert progress_line =~ "waiting on the gateway's boot readiness verdict"
      assert progress_line =~ "ACP adapters installing"
    end

    test "a closed install no longer reads as installing" do
      dir = gate_dir!()

      gateway =
        gate_gateway!(dir, [
          "installing ACP adapters into #{dir}/adapters on testhost — npm can take minutes on a cold cache",
          "ACP adapter install into #{dir}/adapters on testhost complete"
        ])

      assert {:error, {:no_verdict, detail}} =
               LegGateway.await_runnable(gateway, "claude", "testhost",
                 timeout_ms: 150,
                 poll_ms: 50,
                 progress: quiet()
               )

      refute detail =~ "ACP adapters installing"
    end
  end

  describe "leg teardown reports what actually happened" do
    alias Tightbeam.ClientE2E.LegGateway

    # This behaviour shipped INERT once: teardown computed :still_running or
    # :not_removed and then returned a bare :ok, so the runner's warnings could
    # never fire. A survivor that ignores SIGTERM is the cheapest way to hold
    # the real contract.
    test "a process that outlives SIGTERM returns :still_running and KEEPS the base_dir" do
      base_dir =
        Path.join(
          System.tmp_dir!(),
          "tightbeam-client-e2e-teardown-#{System.unique_integer([:positive])}"
        )

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
      base_dir =
        Path.join(
          System.tmp_dir!(),
          "tightbeam-client-e2e-reap-#{System.unique_integer([:positive])}"
        )

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

      assert await_process_gone(grand, 10_000) == :ok,
             "the SIGTERM-ignoring GRANDCHILD (#{grand}) outlived teardown"

      assert await_process_gone(mid, 10_000) == :ok,
             "the intermediate child (#{mid}) outlived teardown"
    end

    test "a recycled pid is NOT signalled — identity is checked, not just liveness" do
      # A pid is a reusable integer. If the process we booted has exited and the
      # number now belongs to somebody else, signalling it kills their work; that
      # is how a cleanup routine takes out another lane. Here the struct names a
      # LIVE pid whose command line does not match what was captured.
      base_dir =
        Path.join(
          System.tmp_dir!(),
          "tightbeam-client-e2e-recycled-#{System.unique_integer([:positive])}"
        )

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

      # Assert the RETURN, not just the side effect. A discarded return cannot
      # tell "refused on identity, took the clean path" from "signalled and the
      # kill happened to fail", and those are the two stories this test exists
      # to separate.
      assert LegGateway.teardown(gateway, exit_timeout_ms: 1_000, reap_timeout_ms: 1_000) == :ok

      assert {_, 0} =
               System.cmd("kill", ["-0", Integer.to_string(bystander)], stderr_to_stdout: true),
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

      assert LegGateway.reap_descendants(
               [{bystander, "/bin/nonexistent-captured-command"}],
               1_000
             ) ==
               :ok

      assert {_, 0} = System.cmd("kill", ["-0", bystander], stderr_to_stdout: true),
             "a pid whose identity no longer matches the capture must not be signalled"

      System.cmd("kill", ["-KILL", bystander], stderr_to_stdout: true)
    end

    test "a clean stop removes the run-local base_dir and returns :ok" do
      base_dir =
        Path.join(
          System.tmp_dir!(),
          "tightbeam-client-e2e-teardown-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(base_dir)

      gateway = %LegGateway{
        base_dir: base_dir,
        port: 0,
        os_pid: nil,
        os_command: nil,
        port_ref: nil,
        log_path: ""
      }

      assert LegGateway.teardown(gateway) == :ok
      refute File.exists?(base_dir)
    end

    test "a base_dir this driver did not provision is NEVER removed" do
      # The one unrecoverable mistake is deleting a real org.
      base_dir =
        Path.join(System.tmp_dir!(), "somebody-elses-org-#{System.unique_integer([:positive])}")

      File.mkdir_p!(base_dir)
      on_exit(fn -> File.rm_rf!(base_dir) end)

      gateway = %LegGateway{
        base_dir: base_dir,
        port: 0,
        os_pid: nil,
        os_command: nil,
        port_ref: nil,
        log_path: ""
      }

      assert LegGateway.teardown(gateway) == :ok
      assert File.dir?(base_dir)
    end
  end

  describe "a non-passing preflight blocks the leg (SMOKE P3)" do
    test "the runner gate blocks FAIL and INCOMPLETE but not PASS" do
      refute ClientE2E.preflight_blocked?(Scorecard.pass("P", "auth"))
      assert ClientE2E.preflight_blocked?(Scorecard.fail("P", "auth", "rejected"))
      assert ClientE2E.preflight_blocked?(Scorecard.incomplete("P", "auth", "timeout"))
    end

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

      # A store row is the credential file AND its metadata. The preflight reads
      # the KIND from here to choose which route to probe, so a file with no
      # metadata beside it is not a seeded credential — it is the half-assembled
      # store the "records no credential kind" row exists to catch.
      metadata = Path.join([store, ".tightbeam", "credential.json"])
      File.mkdir_p!(Path.dirname(metadata))

      File.write!(
        metadata,
        JSON.encode!(%{"provider" => "openai", "kind" => "subscription", "onboarded" => true})
      )

      on_exit(fn -> File.rm_rf!(base_dir) end)
      %{base_dir: base_dir}
    end

    test ":live passes", ctx do
      transport = fn _target, _request ->
        {:ok, %{status: 200, headers: %{}, body: "{}"}}
      end

      # A live grant is not the whole bar: the row only passes once the catalog
      # this host can actually derive is non-empty, which is now one HTTPS call
      # the host makes rather than a file someone seeded.
      catalog = fn _command ->
        catalog_reply(
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
      end

      assert %{status: :pass} =
               ClientE2E.preflight("codex", ctx.base_dir, transport: transport, sh: catalog)
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

      assert Provenance.to_header({:dirty, sha, fingerprint, listing}) =~
               "DIRTY (diff #{fingerprint})"
    end

    test "UNTRACKED content changes the fingerprint" do
      # `git diff HEAD` omits untracked files, so the previous fingerprint gave
      # two different untracked driver sources the same empty-diff hash.
      listing = "?? probe.exs\n"

      dir =
        Path.join(System.tmp_dir!(), "client-e2e-untracked-#{System.unique_integer([:positive])}")

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
    test "configured journeys resolve the environment against the registry" do
      variable = "TIGHTBEAM_CLIENT_E2E_JOURNEYS"
      previous = System.get_env(variable)

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(variable)
          value -> System.put_env(variable, value)
        end
      end)

      System.delete_env(variable)
      assert ClientE2E.configured_journeys() == Journeys.ids()

      System.put_env(variable, "J0, J7")
      assert ClientE2E.configured_journeys() == ["J0", "J7"]

      System.put_env(variable, "J0,J-unknown")

      assert_raise RuntimeError, ~r/unknown journey ids.*J-unknown/, fn ->
        ClientE2E.configured_journeys()
      end
    end

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

    test ":journeys restricts the walk, and a subset leg cannot look like a full one" do
      # What scripts/client_e2e.exs passes for TIGHTBEAM_CLIENT_E2E_JOURNEYS, so
      # "did I break restart?" costs one journey instead of the whole leg.
      {leg, _gateway} =
        ClientE2E.run_leg(
          host: "127.0.0.1",
          port: closed_port(),
          base_dir: System.tmp_dir!(),
          harness: registered_harness(),
          host_name: "testhost",
          journeys: ["J0"]
        )

      manual_only = for o <- Journeys.oracles(), match?({:none, _}, o.client), do: o.step

      j0_steps =
        for o <- Journeys.oracles(), o.journey == "J0", o.step not in manual_only, do: o.step

      assert Enum.sort(Enum.map(leg.rows, & &1.step)) == Enum.sort(j0_steps)

      # The steps it did not walk are ABSENT, not passing — a subset run has no
      # way to report the full automated set as green.
      refute Enum.sort(Enum.map(leg.rows, & &1.step)) == Enum.sort(Journeys.automated_steps())
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

  ## Readiness-gate helpers (#102)

  defp gate_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-client-e2e-gate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp gate_gateway!(dir, lines) do
    log_path = Path.join(dir, "gateway.log")

    # As Logger writes them: console prefix first, message (indentation
    # intact) after.
    File.write!(
      log_path,
      Enum.map_join(lines, "", &("12:00:00.000 [info] " <> &1 <> "\n"))
    )

    %Tightbeam.ClientE2E.LegGateway{base_dir: dir, port: 0, log_path: log_path}
  end

  defp readiness_row(harness, overrides) do
    Map.merge(
      %{
        host: "testhost",
        harness: harness,
        provider: :anthropic,
        adapter: :present,
        credential: :live,
        model: :selectable,
        runnable?: true
      },
      overrides
    )
  end

  defp quiet, do: fn _line -> :ok end

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

  # A signalled process is not instantly gone: it can sit as a zombie until its
  # parent — or launchd, once teardown has killed the parent and the survivors
  # are reparented — reaps it, and `kill -0` reports a zombie as alive. Sampling
  # once the instant teardown returns races the kernel rather than testing the
  # reaper, so poll for the disappearance instead.
  defp await_process_gone(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll ->
      cond do
        match?({_, 1}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true)) ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          :still_alive

        true ->
          Process.sleep(50)
          poll.(poll)
      end
    end

    poll.(poll)
  end

  defp registered_harness, do: Tightbeam.Harness.all() |> hd() |> then(& &1.wire_name())

  defp green_leg(ids, harness \\ "claude") do
    rows = Enum.map(ids, &Scorecard.pass(&1, "journey #{&1}", journey: &1))
    Scorecard.add(%Leg{harness: harness, host: "testhost"}, rows)
  end

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
          JSON.encode!(%{
            "type" => "message",
            "id" => "nope",
            "sessionKey" => key,
            "content" => "hi"
          })
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

    :ok = Tightbeam.Schema.ensure_all(db)

    start_supervised!(%{
      id: :client_e2e_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    handlers = Gateway.handlers(%{db: db, base_dir: base_dir, port: 0})
    Rules.load!(Path.join(base_dir, "no-rules"), Map.keys(handlers))
    on_exit(fn -> Rules.load!(Path.join(System.tmp_dir!(), "client-e2e-reset"), []) end)

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
          model: Model.new("fable")
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
