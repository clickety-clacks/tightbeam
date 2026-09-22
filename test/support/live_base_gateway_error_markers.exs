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
  alias Tightbeam.{ConnRegistry, DB, EventLog, Gateway, Ledger, Model, Org}
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
      {:ok, adapter} = AdapterStub.start_link(self())
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
          if pre_dispatch?,
            do: "fail before dispatch",
            else: "fail with " <> JSON.encode!(input["reason"])

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

        assert {:ok, true} =
                 DB.transaction(db, fn txn ->
                   assert Ledger.finish_in_txn(txn, turn.seq, "failed", "boom")
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
          if pre_dispatch?,
            do: "{:acp_request_not_dispatched, :closed}",
            else: input["expected"]

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
