defmodule Tightbeam.ReminderDeliveryProof do
  @moduledoc false
  # End-to-end reminder delivery through a real SessionLane and the real
  # Gateway runner. Each case runs in its own guarded VM against a fresh base.
  import ExUnit.Assertions

  alias Tightbeam.{
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    HarnessHealth,
    Ledger,
    Model,
    NoticeBatcher,
    Org,
    ReminderDelivery,
    Rules,
    SessionLane,
    StateResources,
    Wakes
  }

  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

  defmodule Doorbell do
    @moduledoc false
    use GenServer
    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, key}, _from, parent) do
      send(parent, {:lane_nudged, key})
      {:reply, :ok, parent}
    end
  end

  @holder "holder"
  @assignment "asg_reminder"

  # A reminder carried by a notice carrier turn is consumed by the lane's
  # ordinary terminal transaction, together with the assistant reply.
  def delivered(ctx) do
    with_consumer(ctx, fn ctx ->
      {reminder, initial} = schedule_reminder!(ctx)
      seq = carry!(ctx, reminder)
      run_lane!(ctx, seq)

      assert_consumed!(ctx, seq, initial, %{"wake" => reminder.wake_id})
      assert assistant_replies(ctx.db, seq) != []
      assert lifecycle_count(ctx.db, "turn_finalize_transaction_failed", seq) == 0
    end)
  end

  # When the terminal transaction cannot record the reply, the fallback
  # terminal transaction still consumes the reminder exactly once.
  def fallback(ctx) do
    with_consumer(ctx, fn ctx ->
      {reminder, initial} = schedule_reminder!(ctx)
      seq = carry!(ctx, reminder)

      assert :ok =
               DB.execute(
                 ctx.db,
                 """
                 CREATE TRIGGER reminder_proof_refuse_reply BEFORE INSERT ON messages
                 WHEN NEW.role='assistant' AND NEW.sender='tightbeam'
                 BEGIN SELECT RAISE(ABORT,'reminder proof refuses assistant replies'); END
                 """
               )

      run_lane!(ctx, seq)

      assert_consumed!(ctx, seq, initial, %{"wake" => reminder.wake_id})
      assert assistant_replies(ctx.db, seq) == []
      assert lifecycle_count(ctx.db, "turn_finalize_transaction_failed", seq) == 1
      assert lifecycle_count(ctx.db, "turn_finalize_fallback_failed", seq) == 0
    end)
  end

  # A rerun of an interrupted reminder turn takes over its claim; the rerun's
  # reply belongs to the original source turn in the transcript.
  def repaired(ctx) do
    with_consumer(ctx, fn ctx ->
      {reminder, initial} = schedule_reminder!(ctx)

      assert :appended =
               Gateway.deliver_prompt(@holder, reminder.origin, reminder.prompt,
                 db: ctx.db,
                 wake_id: reminder.wake_id,
                 sender: reminder.origin,
                 target_gate: reminder,
                 fire_wake_in_txn: true,
                 conn_registry: ConnRegistry,
                 lane_manager: ctx.doorbell
               )

      assert {:ok, [[source_seq, @assignment]]} =
               DB.query(ctx.db, "SELECT seq,assignmentId FROM turns WHERE wakeId=?1", [
                 reminder.wake_id
               ])

      assert {:ok, source} = Ledger.claim_next(ctx.db, @holder, "interrupted-reminder")
      assert source.seq == source_seq

      assert :ok =
               Ledger.finish(ctx.db, source.seq, "failed_unknown", "interrupted: outcome unknown",
                 owner_lease: source.owner_lease
               )

      assert state(ctx.db) == initial
      session = Org.get(ctx.db, @holder)

      assert {:opened, _incident} =
               HarnessHealth.observe(ctx.db, %{
                 correlation_id: "reminder-proof-interrupted",
                 harness: session.harness,
                 host: session.host,
                 failure_class: "interrupted-outcome-unknown",
                 evidence_kind: "authoritative-provider",
                 session_key: @holder,
                 assignment_id: @assignment,
                 observed_at: System.system_time(:millisecond),
                 cause: "interrupted reminder turn",
                 principal: "process:tightbeam"
               })

      handlers = Gateway.handlers(ctx.config)
      Rules.load!(ctx.base, Map.keys(handlers))

      call = %{
        verb: "repair-assignment",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        lane_manager: ctx.doorbell,
        params: %{
          assignment_id: @assignment,
          action: "rerun",
          turn_seq: source.seq,
          idempotency_key: "reminder-proof-rerun",
          outcome: "not-completed"
        }
      }

      assert {:ok, repaired} = Tightbeam.Dispatch.dispatch(ctx.db, handlers, call)
      assert repaired.ok
      assert repaired.sourceTurnSeq == source.seq
      attempt = repaired.attemptTurnSeq

      rebound = state(ctx.db)
      assert rebound["pending"]["consumer"] == %{"turn" => attempt}
      assert rebound["pending"]["intent"] == initial["pending"]["intent"]
      assert rebound["pending"]["snapshot"] == initial["pending"]["snapshot"]
      assert rebound["claimEpoch"] == initial["claimEpoch"] + 1

      assert {:ok, :no_claim} =
               DB.transaction(ctx.db, &ReminderDelivery.delivered_in_txn(&1, source.seq))

      assert state(ctx.db) == rebound

      run_lane!(ctx, attempt)
      assert_consumed!(ctx, attempt, initial, %{"turn" => attempt})

      assert {:ok, [[attempt_message_id]]} =
               DB.query(ctx.db, "SELECT messageId FROM turns WHERE seq=?1", [attempt])

      assert attempt_message_id == source.message_id
      assert [{reply_id, reply_content}] = assistant_replies(ctx.db, attempt)
      assert is_binary(reply_content) and String.trim(reply_content) != ""
      source_seq = source.seq
      source_message_id = source.message_id

      assert %{
               turn_seq: ^source_seq,
               assignment_id: @assignment,
               reply_to_message_id: ^source_message_id,
               content: ^reply_content
             } = StateResources.query_message(ctx.db, reply_id)

      assert {:ok, [["failed_unknown"]]} =
               DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [source.seq])

      assert {:ok, [[0]]} =
               DB.query(
                 ctx.db,
                 "SELECT count(*) FROM turns WHERE sessionKey=?1 AND status IN ('queued','running')",
                 [@holder]
               )
    end)
  end

  defp with_consumer(%{db: db} = ctx, proof) do
    {:ok, _} =
      DB.query(db, "INSERT OR IGNORE INTO users(userId,isAdmin,createdAt) VALUES ('flynn',0,1)")

    main = session!(db, Org.personal_session_key("flynn"), nil, true)
    session!(db, @holder, main.session_key, false)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt) VALUES (?1,'reminder proof',?2,'flynn',1)",
        [@assignment, @holder]
      )

    {:ok, lane_registry} = Registry.start_link(keys: :unique, name: Tightbeam.LaneRegistry)
    {:ok, task_sup} = Task.Supervisor.start_link()
    {:ok, doorbell} = GenServer.start_link(Doorbell, self())

    {:ok, responder} =
      Task.Supervisor.start_child(task_sup, fn ->
        loop = fn loop ->
          receive do
            {:prompt_started, adapter} -> send(adapter, :continue_prompt)
            _ -> :ok
          end

          loop.(loop)
        end

        loop.(loop)
      end)

    {:ok, adapter} = AdapterStub.start_link({:unique_sessions, responder})
    {:ok, coordinator} = CoordinatorStub.start_link(adapter)

    {Tightbeam.LaneManager, lane_opts} =
      Gateway.children(ctx.config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

    try do
      proof.(
        Map.merge(ctx, %{
          doorbell: doorbell,
          task_sup: task_sup,
          runner: Keyword.fetch!(lane_opts, :runner)
        })
      )
    after
      GenServer.stop(coordinator)
      if Process.alive?(adapter), do: GenServer.stop(adapter)
      GenServer.stop(doorbell)
      Supervisor.stop(task_sup)
      Supervisor.stop(lane_registry)
    end
  end

  defp session!(db, key, spawned_by, built_in) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: spawned_by,
      kind: if(built_in, do: "main", else: "custom"),
      is_built_in: built_in,
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp schedule_reminder!(ctx) do
    assert {:ok, %{wake_id: _} = reminder} =
             DB.transaction(ctx.db, fn txn ->
               ReminderDelivery.schedule_in_txn(txn, @assignment, "prod", @holder, fn ->
                 Wakes.schedule_in_txn(txn, %{
                   session_key: @holder,
                   origin: "process:tightbeam",
                   prompt: "reminder: report progress on the reminder proof",
                   assignment_id: @assignment,
                   due_at: 0
                 })
               end)
             end)

    initial = state(ctx.db)
    assert initial["pending"]["consumer"] == %{"wake" => reminder.wake_id}
    {reminder, initial}
  end

  # Deliver the reminder through the notice batcher alongside an unrelated
  # notice, so it travels on a carrier turn that names no assignment.
  defp carry!(ctx, reminder) do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt) VALUES ('asg_sibling','sibling',?1,'flynn',1)",
        [@holder]
      )

    sibling =
      Wakes.schedule(ctx.db, %{
        session_key: @holder,
        origin: "agent:sibling",
        prompt: "unrelated information",
        assignment_id: "asg_sibling",
        class: "information",
        due_at: 0
      })

    assert [carrier] =
             NoticeBatcher.recover(ctx.db, System.system_time(:millisecond) + 1_000,
               conn_registry: ConnRegistry,
               lane_manager: ctx.doorbell
             )

    assert {:ok, source_ids} =
             DB.transaction(ctx.db, &NoticeBatcher.carrier_source_ids_in_txn(&1, carrier))

    assert Enum.sort(source_ids) == Enum.sort([reminder.wake_id, sibling.wake_id])

    assert {:ok, [[seq, "queued", @assignment]]} =
             DB.transaction(
               ctx.db,
               &NoticeBatcher.source_delivery_turns_in_txn(&1, reminder.wake_id)
             )

    assert {:ok, [[^carrier, nil]]} =
             DB.query(ctx.db, "SELECT wakeId,assignmentId FROM turns WHERE seq=?1", [seq])

    seq
  end

  defp run_lane!(ctx, seq) do
    parent = self()

    {:ok, lane} =
      SessionLane.start_link(
        session_key: @holder,
        db: ctx.db,
        task_sup: ctx.task_sup,
        runner: ctx.runner,
        on_terminal: fn _key, terminal_seq -> send(parent, {:reminder_terminal, terminal_seq}) end
      )

    try do
      assert_receive {:reminder_terminal, ^seq}, 60_000
    after
      if Process.alive?(lane), do: GenServer.stop(lane)
    end
  end

  defp assert_consumed!(ctx, seq, initial, consumer) do
    assert {:ok, [["delivered", ended_at]]} =
             DB.query(ctx.db, "SELECT status,endedAt FROM turns WHERE seq=?1", [seq])

    delivered = state(ctx.db)
    assert delivered["pending"] == nil
    assert delivered["lastConsumer"] == consumer
    assert delivered["lastIntent"] == initial["pending"]["intent"]
    assert delivered["lastSnapshot"] == initial["pending"]["snapshot"]
    assert delivered["lastDeliveredAt"] == ended_at
    assert delivered["nextEligibleAt"] - delivered["lastDeliveredAt"] == 300_000

    # A replayed terminal transition finds no claim and changes nothing.
    assert {:ok, :no_claim} = DB.transaction(ctx.db, &ReminderDelivery.delivered_in_txn(&1, seq))
    assert state(ctx.db) == delivered
  end

  defp assistant_replies(db, seq) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT m.id,m.content FROM messages m JOIN turns t ON t.messageId=m.replyToMessageId
        WHERE t.seq=?1 AND m.role='assistant' AND m.sender='tightbeam' ORDER BY m.seq
        """,
        [seq]
      )

    Enum.map(rows, fn [id, content] -> {id, content} end)
  end

  defp lifecycle_count(db, kind, seq) do
    subject = "#{@holder}:#{seq}"
    db |> EventLog.lifecycle_events() |> Enum.count(&(&1.kind == kind and &1.subject == subject))
  end

  defp state(db) do
    {:ok, [[encoded]]} =
      DB.query(db, "SELECT reminderState FROM assignments WHERE id=?1", [@assignment])

    JSON.decode!(encoded)
  end
end
