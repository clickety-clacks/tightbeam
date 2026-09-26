defmodule SettlementWriterDoorbell do
  use GenServer
  def init(state), do: {:ok, state}
  def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
end

defmodule SettlementGatewayWriter do
  import ExUnit.Assertions
  alias Tightbeam.{DB, Gateway, Ledger, Model, Org}
  alias Tightbeam.Acp.{Adapter, Conn}
  alias Tightbeam.GatewayTurnFixture.CoordinatorStub

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config, base: base} ->
      # Reuse the existing synthetic ACP fixture. This proves our durable writer,
      # not provider behavior or the separately required live-harness matrix.
      arena = Path.join(base, "writer-arena")
      home = Path.join(arena, "home")
      File.mkdir_p!(home)
      File.write!(Path.join(arena, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
      File.write!(Path.join(home, "fixture.json"), "fixture-provider-credential")

      {:ok, adapter} =
        Adapter.start_link(
          harness: :fixture,
          cmd: [
            System.find_executable("node"),
            Path.expand("test/support/recovery_acp_fixture.js")
          ],
          home: home,
          cwd: home,
          env: [{"RECOVERY_FIXTURE_ARENA", arena}, {"FIXTURE_HOME", home}]
        )

      {:ok, coordinator} = CoordinatorStub.start_link(adapter)
      {:ok, doorbell} = GenServer.start_link(SettlementWriterDoorbell, nil)

      try do
        model = Model.new("fixture-model", effort: "medium")

        Org.create(db, %{
          session_key: "writer",
          display_name: "Writer",
          owner_user_id: "flynn",
          origin: "user:flynn",
          archetype: "default",
          host: "testhost",
          harness: "fixture",
          provider: "fixture_provider",
          model: model
        })

        {:ok, sid} = Adapter.new_session(adapter, model, home, [], "synthetic writer proof")
        Org.append_pointer(db, "writer", sid, "created")

        {Tightbeam.LaneManager, opts} =
          Gateway.children(config)
          |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(opts, :runner)

        assert :appended =
                 Gateway.deliver_prompt("writer", "user:flynn", "RECOVERY_HOLD_A",
                   db: db,
                   conn_registry: Tightbeam.ConnRegistry,
                   lane_manager: doorbell
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "writer", "writer-proof")
        task = Task.async(fn -> runner.(Map.put(turn, :session_key, "writer")) end)

        try do
          {request_id, generation} = await_dispatch(db, turn.seq, 600)
          conn = Adapter.conn(adapter)

          assert %{method: "session/prompt", prompt_session_id: ^sid} =
                   :sys.get_state(conn).pending[request_id]

          assert {:ok, [[^generation]]} =
                   DB.query(db, "SELECT adapterGen FROM turns WHERE seq=?1", [turn.seq])

          assert {:ok, [[lease]]} =
                   DB.query(
                     db,
                     "SELECT ownerLease FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='prompt_dispatched'",
                     [turn.seq]
                   )

          assert lease == turn.owner_lease
          Conn.notify(conn, "session/cancel", %{sessionId: sid})
          Task.await(task, 10_000)
          assert :ok = Ledger.finish(db, turn.seq, "canceled", nil, owner_lease: turn.owner_lease)

          assert {:ok, [["claimed"], ["prompt_dispatched"], ["terminal_committed"]]} =
                   DB.query(
                     db,
                     "SELECT kind FROM turn_lifecycle_events WHERE turnSeq=?1 ORDER BY rowid",
                     [turn.seq]
                   )
        after
          Task.shutdown(task, :brutal_kill)
        end
      after
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(doorbell)
      end
    end)

    IO.puts("settlement-gateway-writer: ok")
  end

  defp await_dispatch(_db, _seq, 0), do: flunk("real Gateway dispatch was not persisted")

  defp await_dispatch(db, seq, attempts) do
    case DB.query(
           db,
           "SELECT acpRequestId,adapterGen FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='prompt_dispatched'",
           [seq]
         ) do
      {:ok, [[id, generation]]} ->
        {id, generation}

      {:ok, []} ->
        Process.sleep(100)
        await_dispatch(db, seq, attempts - 1)
    end
  end
end

SettlementGatewayWriter.run()
