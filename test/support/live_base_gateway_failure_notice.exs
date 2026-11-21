defmodule GuardFailureNoticeDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

# A reviewer's first assignment turn fails with a model's request-rate 429
# through the real Gateway runner. Its opener must get one notice carrying the
# exact sentence the reviewer's own [turn failed] marker shows, and the limit
# must be recorded against the reviewer's model without fencing the harness.
defmodule GuardFailureNotice do
  import ExUnit.Assertions

  alias Tightbeam.{ConnRegistry, DB, Gateway, HarnessProcess, Ledger, Model, Org, Wakes}
  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}
  alias Tightbeam.HarnessHealth.ModelRateLimit

  @reason %{
    "code" => -32_603,
    "data" => %{"errorKind" => "rate_limit"},
    "message" =>
      "API error: 429 This request would exceed your account's rate limit. " <>
        "Please try again later · model not changed"
  }

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
      for {key, model} <- [
            {"agent:lane", "claude-opus-5-5"},
            {"agent:reviewer", "claude-fable-5-2"}
          ] do
        Org.create(db, %{
          session_key: key,
          display_name: key,
          owner_user_id: "flynn",
          origin: "user:flynn",
          archetype: "default",
          host: "testhost",
          harness: "claude",
          provider: "anthropic",
          model: Model.new(model),
          spawned_by: if(key == "agent:reviewer", do: "agent:lane"),
          operational_parent: if(key == "agent:reviewer", do: "agent:lane")
        })
      end

      {:ok, []} =
        DB.query(
          db,
          """
          INSERT INTO assignments
            (id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
          VALUES ('asg_first_turn','review the change','agent:reviewer','agent:lane',1,'open',
                  'claude','anthropic')
          """
        )

      {:ok, lane} = GenServer.start_link(GuardFailureNoticeDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})

      try do
        {Tightbeam.LaneManager, lane_opts} =
          Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        assert :appended =
                 Gateway.deliver_prompt(
                   "agent:reviewer",
                   "user:flynn",
                   "fail with " <> JSON.encode!(@reason),
                   db: db,
                   conn_registry: ConnRegistry,
                   lane_manager: lane,
                   client_message_id: "c_first_turn"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "agent:reviewer", "test")

        # The brief's first turn belongs to the reviewer's own assignment.
        {:ok, []} =
          DB.query(db, "UPDATE turns SET assignmentId='asg_first_turn' WHERE seq=?1", [turn.seq])

        assert {:error, %{terminal_publish: publish, record_in_txn: record}} =
                 runner.(Map.put(turn, :session_key, "agent:reviewer"))

        commit = fn ->
          DB.transaction(db, fn txn ->
            if Ledger.finish_in_txn(txn, turn.seq, "failed", "rate limited",
                 owner_lease: turn.owner_lease
               ) do
              record.(txn)
              true
            else
              false
            end
          end)
        end

        assert {:ok, true} = commit.()
        publish.("failed")
        # A second commit of the same terminal loses and records nothing.
        assert {:ok, false} = commit.()

        {:ok, [[marker]]} =
          DB.query(
            db,
            "SELECT content FROM messages WHERE sessionKey='agent:reviewer' AND content LIKE '[turn failed]%'"
          )

        [_, sentence] = String.split(marker, "could not answer the message above: ", parts: 2)
        sentence = sentence |> String.split("\n") |> hd()
        assert sentence =~ "429 This request would exceed your account's rate limit"

        {:ok, notices} =
          DB.query(db, "SELECT wakeId,sessionKey FROM wakes WHERE wakeId LIKE 'w_turn_failure_%'")

        assert [[wake_id, "agent:lane"]] = notices
        notice = Wakes.get(db, wake_id)
        assert notice.class == "blocker"
        assert notice.prompt =~ "Reason: " <> sentence <> "\n"
        assert notice.prompt =~ "assignment asg_first_turn"
        assert notice.prompt =~ "model claude-fable-5-2"

        assert [%{model: "claude-fable-5-2", session_key: "agent:reviewer"}] =
                 ModelRateLimit.held(db, "claude", "testhost")

        refute HarnessProcess.parked?(db, {:claude, "shared", "testhost"})
      after
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(lane)
      end
    end)
  end
end

GuardFailureNotice.run()
IO.puts("guarded-gateway-failure-notice: ok")
