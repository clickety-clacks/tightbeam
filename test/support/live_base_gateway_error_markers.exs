defmodule GuardErrorDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardErrorMarkers do
  import ExUnit.Assertions
  alias Tightbeam.{ConnRegistry, DB, ErrorDiagnostic, EventLog, Gateway, Ledger, Model, Org}
  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{base: base, db: db, config: config} ->
      input = Path.join(Path.dirname(base), "error-case.json") |> File.read!() |> JSON.decode!()

      Org.create(db, %{
        session_key: "k1",
        display_name: "Main",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

      {:ok, lane} = GenServer.start_link(GuardErrorDoorbell, self())
      setup_diagnosed? = input["mode"] == "setup_diagnosed"

      # What the real adapter returns when the harness refuses the model while
      # creating the session: the legacy classification carrying the refusal.
      setup_refusal = %{
        "code" => -32602,
        "message" => "Invalid params",
        "data" => %{"model" => "fable", "detail" => "not offered"}
      }

      stub_arg =
        if setup_diagnosed?,
          do:
            {:new_session_reply,
             {:error,
              ErrorDiagnostic.diagnosed(
                :model_unavailable,
                ErrorDiagnostic.with_facts(setup_refusal,
                  operation: "session/set_config_option",
                  phase: "model",
                  origin: "acp_adapter"
                )
              )}, self()},
          else: self()

      {:ok, adapter} = AdapterStub.start_link(stub_arg)
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})
      exact_registry = Tightbeam.ConnRegistry

      {:ok, _ref, nil} =
        ConnRegistry.register(exact_registry, %{
          pid: self(),
          user_id: "flynn",
          device_id: "failed",
          is_admin: false,
          subscriptions: MapSet.new(["chat"])
        })

      try do
        {Tightbeam.LaneManager, lane_opts} =
          Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        pre_dispatch? = input["mode"] == "pre_dispatch"

        prompt =
          cond do
            pre_dispatch? -> "fail before dispatch"
            setup_diagnosed? -> "never reaches the prompt"
            true -> "fail with " <> JSON.encode!(input["reason"])
          end

        assert :appended =
                 Gateway.deliver_prompt(
                   "k1",
                   "user:flynn",
                   prompt,
                   db: db,
                   conn_registry: exact_registry,
                   lane_manager: lane,
                   device_id: "failed",
                   client_message_id: "c_fail"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")

        assert {:error,
                %{reason: runner_reason, terminal_publish: publish, record_in_txn: record}} =
                 runner.(Map.put(turn, :session_key, "k1"))

        if pre_dispatch? do
          assert runner_reason == {:acp_request_not_dispatched, :closed}
        end

        # The turn's reason is the classification it always was; the carrier
        # never reaches turns.error, the marker or the health decision.
        if setup_diagnosed? do
          assert runner_reason == :model_unavailable
        end

        assert {:ok, true} =
                 DB.transaction(db, fn txn ->
                   assert Ledger.finish_in_txn(txn, turn.seq, "failed", "boom",
                            owner_lease: turn.owner_lease
                          )

                   record.(txn)
                   true
                 end)

        publish.("failed")

        # EVERY failed turn speaks now. Adjudication used to route a failure into a
        # brief instead of the marker, so deleting the brief (2026-08-05) would have
        # left this class of failure with no channel at all — the "agent progress
        # interrupted, no reason given" that Flynn hit on gibson twice.
        frames = collect_pushes(9, [])

        expected =
          cond do
            pre_dispatch? -> "{:acp_request_not_dispatched, :closed}"
            setup_diagnosed? -> ":model_unavailable"
            true -> input["expected"]
          end

        assert Enum.any?(frames, fn frame ->
                 frame["type"] == "message" and
                   frame["content"] ==
                     "[turn failed]\n\nThe agent could not answer the message above: " <> expected
               end)

        lifecycle =
          Enum.find(EventLog.lifecycle_events(db), fn event ->
            event.kind == "harness_turn_error" and event.subject == "k1"
          end)

        assert lifecycle

        assert Enum.any?(
                 frames,
                 &match?(
                   %{"event" => "prompt_turn_state", "payload" => %{"state" => "failed"}},
                   &1
                 )
               )

        if setup_diagnosed? do
          assert %{
                   "stage" => "session",
                   "reason" => "model_unavailable",
                   "diagnostic" => %{
                     "kind" => "jsonrpc_error",
                     "operation" => "session/set_config_option",
                     "phase" => "model",
                     "origin" => "acp_adapter",
                     "reason" => ^setup_refusal
                   }
                 } = JSON.decode!(lifecycle.detail)

          # The live turn-state stream carries the same original refusal.
          assert Enum.any?(frames, fn frame ->
                   match?(
                     %{
                       "event" => "prompt_turn_state",
                       "payload" => %{
                         "state" => "failed",
                         "diagnostic" => %{
                           "kind" => "jsonrpc_error",
                           "operation" => "session/set_config_option",
                           "reason" => ^setup_refusal
                         }
                       }
                     },
                     frame
                   )
                 end)
        end

        if pre_dispatch? do
          assert lifecycle.detail =~ "prompt"
          assert lifecycle.detail =~ "acp_request_not_dispatched"
          assert lifecycle.detail =~ "closed"

          refute Enum.any?(frames, fn frame ->
                   frame["type"] == "message" and frame["role"] == "assistant" and
                     not String.starts_with?(frame["content"] || "", "[turn failed]")
                 end)

          refute Enum.any?(frames, fn frame ->
                   match?(
                     %{"event" => "prompt_turn_state", "payload" => %{"state" => "delivered"}},
                     frame
                   )
                 end)

          assert Enum.count(frames, fn frame ->
                   match?(
                     %{"event" => "prompt_turn_state", "payload" => %{"state" => "failed"}},
                     frame
                   )
                 end) == 1
        end
      after
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(lane)
      end
    end)
  end

  defp collect_pushes(0, acc), do: Enum.reverse(acc)

  defp collect_pushes(n, acc) do
    receive do
      {:push, payload} -> collect_pushes(n - 1, [payload | acc])
      {:push_message, _key, _seq, payload} -> collect_pushes(n - 1, [payload | acc])
      {:ensure_lane, _key} -> collect_pushes(n, acc)
    after
      1_000 -> flunk("timed out collecting golden frames")
    end
  end

  defp frame_name(%{"type" => "message", "role" => role}), do: "message:#{role}"

  defp frame_name(%{
         "type" => "event",
         "event" => "prompt_turn_state",
         "payload" => %{"state" => state}
       }),
       do: "turn:#{state}"

  defp frame_name(%{"type" => "typing", "active" => active}), do: "typing:#{active}"

  defp frame_name(%{
         "type" => "event",
         "event" => "activity",
         "payload" => %{"isActive" => active}
       }),
       do: "activity:#{active}"

  defp frame_name(%{"type" => "ack"}), do: "ack"
end

GuardErrorMarkers.run()
IO.puts("guarded-gateway-error-markers: ok")
