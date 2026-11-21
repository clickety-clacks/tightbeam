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

  alias Tightbeam.{ConnRegistry, DB, Gateway, HarnessProcess, Ledger, Model, Org}
  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}
  alias Tightbeam.HarnessHealth.ModelRateLimit
  alias Tightbeam.Productions.Bubble

  @reason %{
    "code" => -32_603,
    "data" => %{"errorKind" => "rate_limit"},
    "message" =>
      "API error: 429 This request would exceed your account's rate limit. " <>
        "Please try again later · model not changed"
  }

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
      for {key, model, parent} <- [
            {"agent:lane", "claude-opus-5-5", nil},
            {"agent:opener", "claude-opus-5-5", nil},
            {"agent:reviewer", "claude-fable-5-2", "agent:lane"}
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
          spawned_by: parent,
          operational_parent: parent
        })
      end

      {:ok, lane} = GenServer.start_link(GuardFailureNoticeDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})

      try do
        {Tightbeam.LaneManager, lane_opts} =
          Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        for {opener, index} <- Enum.with_index(["agent:lane", "agent:opener"], 1) do
          assignment = "asg_first_turn_#{index}"

          {:ok, []} =
            DB.query(
              db,
              """
              INSERT INTO assignments
                (id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
              VALUES (?1,'review the change','agent:reviewer',?2,1,'open','claude','anthropic')
              """,
              [assignment, opener]
            )

          assert :appended =
                   Gateway.deliver_prompt(
                     "agent:reviewer",
                     "user:flynn",
                     "fail with " <> JSON.encode!(@reason),
                     db: db,
                     conn_registry: ConnRegistry,
                     lane_manager: lane,
                     client_message_id: "c_first_turn_#{index}"
                   )

          assert {:ok, turn} = Ledger.claim_next(db, "agent:reviewer", "test")

          {:ok, []} =
            DB.query(db, "UPDATE turns SET assignmentId=?2 WHERE seq=?1", [turn.seq, assignment])

          assert {:error, %{reason: reason, terminal_publish: publish, record_in_txn: record}} =
                   runner.(Map.put(turn, :session_key, "agent:reviewer"))

          recorded_reason = Tightbeam.SessionLane.error_text(reason)

          commit = fn ->
            DB.transaction(db, fn txn ->
              if Ledger.finish_in_txn(txn, turn.seq, "failed", recorded_reason,
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
          assert {:ok, false} = commit.()
          assert :ok = Bubble.recognize_terminal(db, turn.seq)
          assert :ok = Bubble.recognize_terminal(db, turn.seq)

          {:ok, [[marker]]} =
            DB.query(
              db,
              "SELECT content FROM messages WHERE sessionKey='agent:reviewer' " <>
                "AND content LIKE '[turn failed]%' ORDER BY timestamp DESC LIMIT 1"
            )

          [_, sentence] = String.split(marker, "could not answer the message above: ", parts: 2)
          sentence = sentence |> String.split("\n") |> hd()
          assert sentence =~ "429 This request would exceed your account's rate limit"

          assert {:ok, notices} =
                   DB.query(
                     db,
                     """
                     SELECT sessionKey,prompt FROM turns
                     WHERE wakeId LIKE ?1 OR (wakeId LIKE 'w_turn_failure_%' AND instr(prompt,?2)>0)
                     UNION ALL
                     SELECT sessionKey,prompt FROM wakes
                     WHERE (wakeId LIKE ?1 OR (wakeId LIKE 'w_turn_failure_%' AND instr(prompt,?2)>0))
                       AND NOT EXISTS (SELECT 1 FROM turns WHERE turns.wakeId=wakes.wakeId)
                     """,
                     ["bubble:#{turn.seq}:%", "turn #{turn.seq} on assignment"]
                   )

          recipients = if opener == "agent:lane", do: [opener], else: ["agent:lane", opener]
          assert Enum.sort(Enum.map(notices, &hd/1)) == recipients
          assert Enum.all?(notices, fn [_recipient, prompt] -> prompt =~ sentence end)

          assert %{model: "claude-fable-5-2", session_key: "agent:reviewer"} =
                   ModelRateLimit.for_turn(db, turn.seq)
        end

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
