defmodule EphemeralDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule EphemeralRuntime do
  import ExUnit.Assertions

  alias Tightbeam.{
    DB,
    Ephemeral,
    Gateway,
    Ledger,
    Model,
    NoticeBatcher,
    Org,
    Placement,
    Projection,
    Wakes
  }

  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
      for key <- ["caller", "helper"] do
        Org.create(db, %{
          session_key: key,
          display_name: key,
          owner_user_id: "flynn",
          origin: "user:flynn",
          archetype: "default",
          host: "testhost",
          harness: "claude",
          provider: "anthropic",
          model: Model.new("fable")
        })
      end

      {:ok, _} = DB.transaction(db, &Ephemeral.stamp_in_txn(&1, "helper", "caller"))
      {:ok, lane} = GenServer.start_link(EphemeralDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})

      try do
        {Tightbeam.LaneManager, opts} =
          Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(opts, :runner)

        {:appended, message} =
          Projection.append(db, %{
            session_key: "helper",
            role: "user",
            content: "split assistant messages"
          })

        {:ok, _} =
          Ledger.enqueue(db, %{
            session_key: "helper",
            message_id: message.id,
            origin: "user:flynn",
            prompt: "split assistant messages"
          })

        {:ok, turn} = Ledger.claim_next(db, "helper", "test")
        task = Task.async(fn -> runner.(Map.put(turn, :session_key, "helper")) end)
        assert_receive {:prompt_started, ^adapter}, 60_000
        send(adapter, :continue_prompt)
        assert {:ok, %{record_in_txn: record}} = Task.await(task)
        assert :ok = Tightbeam.GatewayTurnFixture.commit_success!(db, turn, record)

        assert Org.get(db, "helper").state == "retired"
        refute File.exists?(Placement.workdir_path(config, Org.get(db, "helper")))
        result = Wakes.get(db, "ephemeral-result:helper")
        assert result.session_key == "caller"
        assert result.prompt == "Ephemeral spawn result from helper:\n\nSECOND"

        assert {:ok, [[0]]} =
                 DB.query(db, "SELECT COUNT(*) FROM assignments WHERE holderKey='helper'")

        assert {:ok, [[0]]} =
                 DB.query(
                   db,
                   "SELECT COUNT(*) FROM work_items WHERE deliveryOwnerSessionKey='helper'"
                 )

        NoticeBatcher.recover(db, System.system_time(:millisecond) + 1000,
          conn_registry: Tightbeam.ConnRegistry,
          lane_manager: lane
        )

        assert {:ok, returned} = Ledger.claim_next(db, "caller", "test")
        assert returned.prompt =~ "SECOND"
        assert returned.prompt =~ "ephemeral-result:helper"
      after
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(lane)
      end
    end)
  end
end

EphemeralRuntime.run()
IO.puts("ephemeral-runtime: ok")
