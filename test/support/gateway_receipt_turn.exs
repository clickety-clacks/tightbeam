defmodule GuardReceiptTurnDoorbell do
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardReceiptTurn do
  import ExUnit.Assertions

  alias Tightbeam.{ConnRegistry, DB, Gateway, HarklightWakes, Ledger, Model, Org, Placement}
  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

  @handle "7d737f62-bbd7-4c51-978d-f6ff5b4d8146"
  @session_key "agent:main:clawline:fixture-owner:main"
  @event_id "707"
  @send_op "0bdb87a0-3a09-4f61-bff4-9a4a704324c8"
  @send_payload ~s({"type":"send","message":{"sender_id":"sender","message_id":"request"}})
  @send_result ~s({"kind":"sent","session":"7d737f62-bbd7-4c51-978d-f6ff5b4d8146","sender_id":"sender","request":"request"})

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{base: base, db: db, config: config} ->
      now = System.system_time(:millisecond)

      assert {:ok, _} =
               DB.query(
                 db,
                 "INSERT INTO users(userId,isAdmin,createdAt) VALUES(?1,0,?2)",
                 ["fixture-owner", now]
               )

      session =
        Org.create(db, %{
          session_key: @session_key,
          display_name: "handoff receipt fixture agent",
          kind: "main",
          owner_user_id: "fixture-owner",
          origin: "user:fixture-owner",
          archetype: "default",
          host: Placement.local_host_name(),
          harness: "codex",
          provider: "openai",
          model: Model.new("fable")
        })

      call = %{
        session_key: session.session_key,
        principal: {:session, session.session_key},
        transport_session_key: session.session_key,
        params: %{
          harklight_handle: @handle,
          harklight_sender_id: "sender",
          harklight_message_id: "request"
        }
      }

      assert %{code: "harklight_send_pending"} = HarklightWakes.register(db, call)
      assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, @send_op, @send_payload)

      assert %{state: "registered"} =
               HarklightWakes.bind_send(
                 db,
                 call,
                 @send_op,
                 @send_payload,
                 @send_result,
                 @handle,
                 "sender",
                 "request"
               )

      assert :ok =
               HarklightWakes.capture_feed(
                 db,
                 @handle,
                 707,
                 [
                   %{
                     "kind" => "entry",
                     "rev" => 707,
                     "data" => %{
                       "item_id" => "request",
                       "entry_id" => @event_id,
                       "request_revision" => 1,
                       "kind" => "reply",
                       "author" => "person",
                       "text" => "HARKLIGHT_RECEIPT_GATEWAY_FIXTURE"
                     }
                   }
                 ],
                 :live
               )

      assert {:ok, [[wake_id, prompt]]} =
               DB.query(
                 db,
                 "SELECT wakeId,prompt FROM wakes WHERE sessionKey=?1 AND consumer='prompt' ORDER BY createdAt DESC LIMIT 1",
                 [@session_key]
               )

      bin = Path.join(base, "receipt-test-bin")
      File.mkdir_p!(bin)
      executable = Path.join(bin, "harklight-agent")
      calls = executable <> ".calls"
      started = executable <> ".started"
      release = executable <> ".release"
      finished = executable <> ".finished"

      File.write!(
        executable,
        """
        #!/bin/sh
        case "$1" in
          journal-id) printf '%s\n' '{"kind":"journal","journal_id":"receipt-journal"}'; exit 0 ;;
          retry)
            printf '{"kind":"operation_absent","op_id":"%s","journal_id":"receipt-journal"}\n' "$3"
            exit 1
            ;;
        esac
        printf '%s\n' "$*" >> "$0.calls"
        for arg in "$@"; do operation="$arg"; done
        : > "$0.started"
        while [ ! -f "$0.release" ]; do sleep 0.01; done
        printf '{"kind":"committed","operation":"receipt","op_id":"%s","response":{"status":"recorded"}}\n' "$operation"
        : > "$0.finished"
        exit 0
        """
      )

      File.chmod!(executable, 0o755)
      {:ok, lane} = GenServer.start_link(GuardReceiptTurnDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})

      {:ok, _ref, nil} =
        ConnRegistry.register(ConnRegistry, %{
          pid: self(),
          user_id: session.owner_user_id,
          device_id: "receipt-gateway",
          is_admin: false,
          subscriptions: MapSet.new(["chat"])
        })

      Process.put(:receipt_gateway_runner_task, nil)

      try do
        # GuardRuntimeFixture runs this scenario in a short-lived isolated VM.
        # Keep the stand-in first on PATH until that process exits.
        System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
        {:ok, _receipt_worker} = Tightbeam.HarklightReceipts.start_link(db: db)

        {Tightbeam.LaneManager, lane_opts} =
          Gateway.children(config)
          |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)

        assert :appended =
                 Gateway.deliver_prompt(@session_key, "process:tightbeam", prompt,
                   db: db,
                   conn_registry: ConnRegistry,
                   lane_manager: lane,
                   wake_id: wake_id,
                   fire_wake_in_txn: true,
                   client_message_id: "receipt-gateway-turn"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, @session_key, "receipt-gateway-turn")
        turn = Map.put(turn, :session_key, session.session_key)
        turn_seq = turn.seq

        assert {:ok, [[^turn_seq]]} =
                 DB.query(db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [wake_id])

        task = Task.async(fn -> runner.(turn) end)
        Process.put(:receipt_gateway_runner_task, task)

        assert_receive {:prompt_started, ^adapter}, 60_000
        await_file!(started)

        assert File.read!(calls) =~
                 "receipt --item-id request --entry-id #{@event_id} --agent #{session.display_name} --op-id "

        refute File.exists?(release)

        send(adapter, :continue_prompt)

        assert {:ok, %{terminal_publish: publish, record_in_txn: record}} =
                 Task.await(task, 60_000)

        assert :ok = Tightbeam.GatewayTurnFixture.commit_success!(db, turn, record)
        publish.("delivered")

        assert {:ok, [["delivered"]]} =
                 DB.query(db, "SELECT status FROM turns WHERE seq=?1", [turn.seq])

        refute File.exists?(finished)
      after
        File.write!(release, "")

        if Process.alive?(adapter), do: send(adapter, :continue_prompt)
        if File.exists?(started), do: await_file!(finished)

        case Process.get(:receipt_gateway_runner_task) do
          %Task{pid: pid} = task when is_pid(pid) ->
            if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)

          _ ->
            :ok
        end

        Process.delete(:receipt_gateway_runner_task)

        if Process.alive?(coordinator), do: GenServer.stop(coordinator)
        if Process.alive?(adapter), do: GenServer.stop(adapter)
        if Process.alive?(lane), do: GenServer.stop(lane)
      end
    end)
  end

  defp await_file!(path, attempts \\ 500)
  defp await_file!(_path, 0), do: raise("timed out waiting for handoff receipt command fixture")

  defp await_file!(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(10)
      await_file!(path, attempts - 1)
    end
  end
end

GuardReceiptTurn.run()
IO.puts("guarded-gateway-receipt-turn: ok")
