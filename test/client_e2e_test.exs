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

    test "the SMOKE steps this driver claims are exactly J0-J6's steps 1-13" do
      assert Journeys.automated_steps() ==
               ~w(1 2 3 4 5 6 7 8 9 10 11 12 13a 13b 13c)
    end
  end

  describe "J1's turn-completion oracle" do
    # SMOKE step 3 as amended: the typing indicator is the invariant, its label
    # is harness-reported. These pin the amended contract in both directions —
    # the label must not be required, and the indicator must still fail hard.
    defp delivered_turn, do: %{"status" => "delivered"}

    defp observed(overrides) do
      Map.merge(
        %{
          echo: %{"type" => "message"},
          typing_on: %{"active" => true},
          typing_off: %{"active" => false},
          lingering: nil,
          reply: %{"content" => "hi"},
          turn: delivered_turn(),
          timeout_ms: 1_000
        },
        overrides
      )
    end

    test "a plain turn with NO progress label passes — the substrate fabricates no label" do
      assert Journeys.turn_oracle_error(observed(%{})) == nil
    end

    test "the indicator turning on is an invariant" do
      assert Journeys.turn_oracle_error(observed(%{typing_on: nil})) =~ "never turned on"
    end

    test "the indicator clearing is an invariant, and so is not coming back" do
      assert Journeys.turn_oracle_error(observed(%{typing_off: nil})) =~ "never cleared"

      assert Journeys.turn_oracle_error(observed(%{lingering: %{"active" => true}})) =~
               "came back after the turn ended"
    end

    test "a failed turn row is reported ahead of the client symptom it caused" do
      error =
        Journeys.turn_oracle_error(
          observed(%{
            reply: nil,
            typing_on: nil,
            turn: %{"status" => "failed", "error" => "Invalid value for config option model"}
          })
        )

      assert error =~ "turn row is failed"
      assert error =~ "Invalid value for config option model"
      refute error =~ "never turned on"
    end

    test "a missing echo is the first thing reported — nothing else is meaningful without it" do
      assert Journeys.turn_oracle_error(observed(%{echo: nil, turn: nil})) =~ "no echo bubble"
    end

    test "a non-terminal turn row fails even when every frame arrived" do
      assert Journeys.turn_oracle_error(observed(%{turn: %{"status" => "queued"}})) =~
               "turn row is queued"
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
      leg =
        ClientE2E.run_leg(
          host: "127.0.0.1",
          port: closed_port(),
          base_dir: System.tmp_dir!(),
          harness: "claude",
          host_name: "testhost",
          preflight: false
        )

      assert Scorecard.leg_verdict(leg) == :fail

      boot = Enum.find(leg.rows, &(&1.step == "1"))
      assert boot.status == :fail
      assert boot.note =~ "econnrefused"

      # Every step the driver claims to automate is accounted for; a step that
      # simply vanished from the report is how a broken run looks green.
      assert Enum.sort(Enum.map(leg.rows, & &1.step)) == Enum.sort(Journeys.automated_steps())
    end
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
