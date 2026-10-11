defmodule SettlementWriterDoorbell do
  use GenServer
  def init(state), do: {:ok, state}
  def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
end

defmodule SettlementGatewayWriter do
  import ExUnit.Assertions
  alias Tightbeam.{DB, Gateway, Ledger, Model, NoticeAuthority, NoticeBatcher, Org, SessionLane, Wakes}
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
        submission_restoration!(db, config, arena, home, coordinator, doorbell, adapter)
      after
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(doorbell)
      end
    end)

    IO.puts("settlement-gateway-writer: ok")
  end

  defp submission_restoration!(db, config, arena, _original_home, coordinator, doorbell, original_adapter) do
    # The queue is admitted on Claude, then the supported retune write changes
    # the receiver before claim. The REAL Adapter/Conn Codex scalar guard must
    # classify this obsolete large carrier before writing a session/prompt.
    arena = Path.join(arena, "submission-boundary")
    home = Path.join(arena, "home")
    File.mkdir_p!(home)
    File.write!(Path.join(arena, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
    File.write!(Path.join(home, "fixture.json"), "fixture-provider-credential")
    model = Model.new("gpt-fixture", effort: "medium")
    {:ok, adapter} = Adapter.start_link(
      harness: :codex,
      cmd: [System.find_executable("node"), Path.expand("test/support/recovery_acp_fixture.js")],
      home: home, cwd: home,
      env: [{"RECOVERY_FIXTURE_ARENA", arena}, {"FIXTURE_HOME", home},
            {"RECOVERY_FIXTURE_MODEL", "gpt-fixture"}]
    )
    {:ok, sid} = Adapter.new_session(adapter, model, home, [], "OUR-side size boundary proof")
    {:ok, registry} = Registry.start_link(keys: :unique, name: Tightbeam.LaneRegistry)
    {:ok, tasks} = Task.Supervisor.start_link()
    {Tightbeam.LaneManager, opts} = Gateway.children(config)
      |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))
    runner = Keyword.fetch!(opts, :runner)
    Process.put(:submission_proof_lanes, [])

    try do
      :sys.replace_state(coordinator, fn _ -> {adapter, nil} end)
      for {key, raw} <- [{"prewrite", String.duplicate("🙂", 1_048_577)},
                         {"unknown", "RECOVERY_HOLD_A unknown effect"}] do
        Org.create(db, %{session_key: key, display_name: key, owner_user_id: "flynn",
          origin: "user:flynn", archetype: "default", host: "testhost",
          harness: "claude", provider: "anthropic", model: Model.new("fable")})
        source = Wakes.schedule(db, %{session_key: key, origin: "process:tightbeam",
          prompt: raw, due_at: 0, class: "fyi"})
        [carrier] = NoticeBatcher.recover(db, source.due_at, lane_manager: doorbell)
        assert {:ok, [[seq, frozen]]} = DB.query(db,
          "SELECT seq,prompt FROM turns WHERE wakeId=?1", [carrier])
        assert Wakes.get(db, source.wake_id).prompt == raw
        Org.set_harness(db, key, "codex", "openai", model)
        Org.append_pointer(db, key, sid, "created")
        {:ok, lane} = SessionLane.start_link(session_key: key, db: db,
          task_sup: tasks, runner: runner)
        Process.put(:submission_proof_lanes, [lane | Process.get(:submission_proof_lanes)])

        if key == "prewrite" do
          await_terminal!(db, seq, 600)
          assert {:ok, [["failed", ^frozen]]} = DB.query(db,
            "SELECT status,prompt FROM turns WHERE seq=?1", [seq])
          assert NoticeAuthority.restored_turn?(db, seq)
          assert {:ok, [[retry]]} = DB.query(db,
            "SELECT retryWakeId FROM wake_retry_attempts WHERE rootWakeId=?1 AND retryWakeId IS NOT NULL",
            [source.wake_id])
          assert %{state: "pending", prompt: ^raw} = Wakes.get(db, retry)
          assert NoticeAuthority.current!(db, source.wake_id) == retry
          assert {:ok, [[0]]} = DB.query(db,
            "SELECT COUNT(*) FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='prompt_dispatched'", [seq])
          conn = Adapter.conn(adapter)
          refute Enum.any?(:sys.get_state(conn).pending, fn {_, entry} ->
            entry.method == "session/prompt" end)
          assert {:ok, [[detail]]} = DB.query(db,
            "SELECT detail FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='terminal_committed'", [seq])
          assert detail =~ "submission_text_limit_exceeded"
          requests =
            Path.join(arena, "recovery-acp.jsonl")
            |> File.read!()
            |> String.split("\n", trim: true)
            |> Enum.map(&JSON.decode!/1)
          refute Enum.any?(requests, fn record ->
            record["direction"] == "request" and record["frame"]["method"] == "session/prompt"
          end)
        else
          # Use the fixture's existing held-prompt barrier after a real port
          # write, then kill the exact owned task. No provider rejection or
          # guessed not-dispatched evidence may restore these roots.
          await_dispatch(db, seq, 600)
          %{current_seq: ^seq, task_pid: task} = :sys.get_state(lane)
          Process.exit(task, :kill)
          await_terminal!(db, seq, 600)
          refute NoticeAuthority.restored_turn?(db, seq)
          assert NoticeAuthority.current!(db, source.wake_id) == source.wake_id
          assert {:ok, [[0]]} = DB.query(db,
            "SELECT COUNT(*) FROM wake_retry_attempts WHERE rootWakeId=?1", [source.wake_id])
          assert {:ok, [[1]]} = DB.query(db,
            "SELECT COUNT(*) FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='prompt_dispatched'", [seq])
          assert Wakes.get(db, source.wake_id).state == "fired"
          assert NoticeBatcher.recover(db, source.due_at, lane_manager: doorbell) == []
          assert {:ok, [[1]]} = DB.query(db,
            "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [carrier])
        end

        assert Wakes.get(db, source.wake_id).prompt == raw
        assert {:ok, [[^frozen]]} = DB.query(db, "SELECT prompt FROM turns WHERE seq=?1", [seq])
        assert [%{delivery_wake_id: ^carrier, member_state: "included"}] =
                 NoticeBatcher.source_refs(db, source.wake_id)
      end
      assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
    after
      for lane <- Process.get(:submission_proof_lanes),
          do: if(Process.alive?(lane), do: GenServer.stop(lane))
      Supervisor.stop(tasks)
      Supervisor.stop(registry)
      GenServer.stop(adapter)
      :sys.replace_state(coordinator, fn _ -> {original_adapter, nil} end)
    end
  end

  defp await_terminal!(_db, _seq, 0), do: flunk("real SessionLane did not commit the terminal")
  defp await_terminal!(db, seq, attempts) do
    case DB.query(db, "SELECT status FROM turns WHERE seq=?1", [seq]) do
      {:ok, [[status]]} when status not in ["queued", "running"] -> :ok
      {:ok, [[_]]} ->
        Process.sleep(100)
        await_terminal!(db, seq, attempts - 1)
    end
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
