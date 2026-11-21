defmodule Tightbeam.HarklightWakesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    DB,
    Ephemeral,
    HarklightFollows,
    HarklightLifecycle,
    HarklightReceipts,
    HarklightSend,
    HarklightWakes,
    Ledger,
    Model,
    Org,
    Placement,
    SessionCustodyTransfer,
    TurnLifecycle,
    Wakes
  }

  # Refuses the listener's active-state write as an overloaded database would,
  # a given number of times, and forwards everything else to the real owner.
  defmodule FeedStateOverloadDB do
    use GenServer

    def start_link({db, parent, refusals}),
      do: GenServer.start_link(__MODULE__, %{db: db, parent: parent, refusals: refusals})

    def init(state), do: {:ok, state}

    def handle_call(
          {:query, "UPDATE harklight_wake_handles SET state='active'" <> _, _},
          _from,
          %{refusals: refusals} = state
        )
        when refusals > 0 do
      send(state.parent, :feed_state_refused)
      {:reply, {:error, %DB.Overloaded{}}, %{state | refusals: refusals - 1}}
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.db, request, :infinity), state}
  end

  defmodule RefusingHarklightDB do
    use GenServer

    def start_link({db, test}), do: GenServer.start_link(__MODULE__, {db, test, []})
    def init(state), do: {:ok, state}

    def handle_call({:refuse, sql}, from, state),
      do: handle_call({:refuse, sql, %DB.Overloaded{}}, from, state)

    def handle_call({:refuse, sql, error}, _from, {db, test, pending}),
      do: {:reply, :ok, {db, test, pending ++ [{sql, error}]}}

    def handle_call({:query, sql, _} = request, _from, {db, test, [{next, error} | rest]} = state) do
      if String.contains?(sql, next) do
        send(test, {:refused_sql, next})
        {:reply, {:error, error}, {db, test, rest}}
      else
        {:reply, GenServer.call(db, request, :infinity), state}
      end
    end

    def handle_call(request, _from, {db, _, _} = state),
      do: {:reply, GenServer.call(db, request, :infinity), state}
  end

  @handle "7d737f62-bbd7-4c51-978d-f6ff5b4d8146"
  @send_op "0bdb87a0-3a09-4f61-bff4-9a4a704324c8"
  @payload ~s({"type":"send","message":{"sender_id":"sender","message_id":"request"}})
  @result ~s({"kind":"sent","session":"7d737f62-bbd7-4c51-978d-f6ff5b4d8146","sender_id":"sender","request":"request"})

  setup do
    db = :"harklight_wakes_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)
    custody = Path.join(System.tmp_dir!(), "#{db}-feed-custody")
    old_recovery_opts = Application.get_env(:tightbeam, :harklight_recovery_options, [])

    Application.put_env(
      :tightbeam,
      :harklight_recovery_options,
      Keyword.put(old_recovery_opts, :feed_custody_dir, custody)
    )

    on_exit(fn ->
      Application.put_env(:tightbeam, :harklight_recovery_options, old_recovery_opts)
      File.rm_rf(custody)
    end)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users(userId,isAdmin,creationKind,createdAt) VALUES('owner',0,'admin_add',1)"
      )

    main =
      Org.create(db, %{
        session_key: Org.personal_session_key("owner"),
        display_name: "Main",
        kind: "main",
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })

    session =
      Org.create(db, %{
        session_key: "agent:origin:one",
        display_name: "Origin",
        owner_user_id: "owner",
        origin: "user:owner",
        spawned_by: main.session_key,
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
    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, @send_op, @payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               call,
               @send_op,
               @payload,
               @result,
               @handle,
               "sender",
               "request"
             )

    %{db: db, call: call, session: session, main: main}
  end

  test "a dispatched handoff resumes the same receipt after restart and refused DB writes", %{
    db: db,
    session: session
  } do
    assert :ok =
             HarklightWakes.capture_feed(db, @handle, 1, [feed_chat(1, "request", "chat")], :live)

    assert {:ok, [[wake]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    turn = deliver_discussion_turn!(db, wake, session.session_key)
    assert :ok = Ledger.stamp_adapter(db, turn.seq, 1)

    proxy = start_supervised!({RefusingHarklightDB, {db, self()}})
    test_pid = self()
    accepted = start_supervised!({Agent, fn -> nil end})

    runner = fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "receipt-journal"})

      ["retry", "--op-id", op, "--journal-id", "receipt-journal"] ->
        if Agent.get(accepted, & &1) == op do
          send(test_pid, {:receipt_replayed, op})
          receipt_result(op)
        else
          {JSON.encode!(%{kind: "operation_absent", op_id: op, journal_id: "receipt-journal"}), 1}
        end

      [
        "receipt",
        "--item-id",
        "request",
        "--entry-id",
        "chat",
        "--agent",
        "Origin",
        "--op-id",
        op
      ] ->
        Agent.update(accepted, fn _ -> op end)
        send(test_pid, {:receipt_attempted, op})
        frame(%{kind: "outcome_unknown", operation: "receipt", op_id: op, status: 503}, 7)
    end

    opts = [db: proxy, runner: runner, retry_delay: 200]
    start_supervised!({Tightbeam.HarklightReceipts, opts})
    refute_receive {:receipt_attempted, _}, 30
    assert {:ok, []} = DB.query(db, "SELECT opId FROM harklight_handoff_receipts")
    assert :ok = stop_supervised(Tightbeam.HarklightReceipts)

    # Dispatch proof can survive a crash before the notification is sent.
    record_prompt_dispatched!(db, turn)
    refused = "SELECT argv,opId,journalId FROM harklight_handoff_receipts"
    assert :ok = GenServer.call(proxy, {:refuse, refused})
    start_supervised!({Tightbeam.HarklightReceipts, opts})
    assert_receive {:refused_sql, ^refused}
    assert_receive {:receipt_attempted, op}, 1_000

    assert {:ok, [[^op, "receipt-journal", nil]]} =
             DB.query(db, "SELECT opId,journalId,completedAt FROM harklight_handoff_receipts")

    assert :ok = stop_supervised(Tightbeam.HarklightReceipts)

    refused = "UPDATE harklight_handoff_receipts SET completedAt"
    assert :ok = GenServer.call(proxy, {:refuse, refused})
    start_supervised!({Tightbeam.HarklightReceipts, opts})
    assert_receive {:receipt_replayed, ^op}, 1_000
    assert_receive {:refused_sql, ^refused}
    assert_receive {:receipt_replayed, ^op}, 1_000

    assert eventually(fn ->
             DB.query(
               db,
               "SELECT count(*) FROM harklight_handoff_receipts WHERE completedAt IS NOT NULL"
             ) ==
               {:ok, [[1]]}
           end)

    refute_receive {:receipt_attempted, _}, 30
  end

  for {failure, pause_recorded} <- [{"overload", true}, {"refused pause write", false}] do
    test "Round 26 holds a dispatched receipt through restart after #{failure}", context do
      assert_guarded_receipt(context, unquote(pause_recorded))
    end
  end

  defp assert_guarded_receipt(
         %{
           db: db,
           call: call,
           session: session,
           main: main
         },
         pause_recorded
       ) do
    :ok = HarklightWakes.capture_feed(db, @handle, 1, [feed_chat(1, "request", "chat")], :live)
    assert {:ok, [[wake]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    turn = deliver_discussion_turn!(db, wake, session.session_key)
    assert :ok = Ledger.stamp_adapter(db, turn.seq, 1)
    record_prompt_dispatched!(db, turn)

    parent = self()

    runner = fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "receipt-journal"})

      ["retry", "--op-id", op, "--journal-id", "receipt-journal"] ->
        send(parent, {:receipt_retry, op})
        frame(%{kind: "operation_absent", op_id: op, journal_id: "receipt-journal"}, 1)

      ["receipt" | _] = args ->
        op = List.last(args)
        send(parent, {:receipt_dispatched, op})
        projection_failure("receipt", op, "receipt-projection")
    end

    proxy = start_supervised!({RefusingHarklightDB, {db, self()}})
    refuse = "INSERT INTO harklight_operation_pauses"

    error =
      if pause_recorded,
        do: %DB.Overloaded{},
        else: %DB.Error{message: "database or disk is full"}

    assert :ok = GenServer.call(proxy, {:refuse, refuse, error})
    opts = [db: proxy, runner: runner, retry_delay: 10]
    start_supervised!({HarklightReceipts, opts})
    assert_receive {:receipt_dispatched, op}
    assert_received {:receipt_retry, ^op}
    assert_receive {:refused_sql, ^refuse}

    assert eventually(fn -> :sys.get_state(HarklightReceipts).task == nil end)
    assert {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM harklight_operation_pauses")
    assert count == if(pause_recorded, do: 1, else: 0)

    :ok = HarklightReceipts.dispatched(turn.seq)
    refute_receive {:receipt_retry, ^op}, 100
    assert {:ok, [[^op]]} = DB.query(db, "SELECT opId FROM harklight_operation_guards")
    previous = Process.whereis(HarklightReceipts)
    assert :ok = stop_supervised(HarklightReceipts)
    no_op = fn args -> flunk("automatic receipt recovery invoked #{inspect(args)}") end
    assert previous != start_supervised!({HarklightReceipts, Keyword.put(opts, :runner, no_op)})

    assert {:ok, false} = HarklightReceipts.drain(db, :all, runner: no_op)
    refute_receive {:receipt_dispatched, _}

    assert {:ok, [[^op, "receipt-journal", nil]]} =
             DB.query(db, "SELECT opId,journalId,completedAt FROM harklight_handoff_receipts")

    settle_call = %{call | params: %{op_id: op}}
    assert :unknown = HarklightReceipts.settle_paused(db, main.session_key, op, runner: no_op)

    assert %{outcome: "outcome_unknown", op_id: ^op} =
             HarklightSend.settle(db, settle_call,
               runner: fn ["retry", "--op-id", ^op, "--journal-id", "receipt-journal"] ->
                 frame(
                   %{kind: "outcome_unknown", operation: "receipt", op_id: op, status: 503},
                   7
                 )
               end
             )

    assert {:ok, false} = HarklightReceipts.drain(db, :all, runner: no_op)

    assert %{outcome: "committed", settled_command: "receipt", op_id: ^op} =
             HarklightSend.settle(db, settle_call,
               runner: fn ["retry", "--op-id", ^op, "--journal-id", "receipt-journal"] ->
                 receipt_result(op)
               end
             )

    assert {:ok, [[^op, "receipt-journal", completed]]} =
             DB.query(db, "SELECT opId,journalId,completedAt FROM harklight_handoff_receipts")

    assert is_integer(completed)
  end

  test "explicit receipt settlement starts the saved write after a pre-journal worker death", %{
    db: db,
    call: call,
    session: session
  } do
    :ok = HarklightWakes.capture_feed(db, @handle, 1, [feed_chat(1, "request", "chat")], :live)
    assert {:ok, [[wake]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    turn = deliver_discussion_turn!(db, wake, session.session_key)
    assert :ok = Ledger.stamp_adapter(db, turn.seq, 1)
    record_prompt_dispatched!(db, turn)

    parent = self()
    journal = "receipt-journal"

    interrupted_runner = fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: journal})

      ["retry", "--op-id", op, "--journal-id", ^journal] ->
        send(parent, {:before_agent_journal, self(), op})

        receive do
          :continue -> flunk("receipt worker should have died before journaling")
        end
    end

    manager = start_supervised!({HarklightReceipts, db: db, runner: interrupted_runner})
    assert_receive {:before_agent_journal, worker, op}
    assert {:ok, [[^op]]} = DB.query(db, "SELECT opId FROM harklight_operation_guards")

    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    assert eventually(fn ->
             case Process.whereis(HarklightReceipts) do
               pid when is_pid(pid) and pid != manager -> true
               _ -> false
             end
           end)

    :ok = HarklightReceipts.dispatched(turn.seq)
    refute_receive {:before_agent_journal, _, ^op}, 100

    assert {:ok, [[^op, ^journal, nil]]} =
             DB.query(db, "SELECT opId,journalId,completedAt FROM harklight_handoff_receipts")

    absent = %{kind: "operation_absent", op_id: op, journal_id: journal}
    settle = %{call | params: %{op_id: op}}

    for response <- [
          frame(%{absent | journal_id: "different-journal"}, 1),
          frame(%{absent | op_id: "different-operation"}, 1),
          frame(Map.delete(absent, :journal_id), 1),
          frame(%{absent | kind: "operation_unresolved"}, 7),
          frame(absent, 7)
        ] do
      runner = fn
        ["retry", "--op-id", ^op, "--journal-id", ^journal] ->
          response

        args ->
          send(parent, {:unexpected_recovery_call, args})
          response
      end

      assert %{code: "harklight_receipt_unresolved", outcome: "outcome_unknown", op_id: ^op} =
               HarklightSend.settle(db, settle, runner: runner)

      refute_received {:unexpected_recovery_call, _}
      assert {:ok, [[^op]]} = DB.query(db, "SELECT opId FROM harklight_operation_guards")
    end

    assert %{outcome: "outcome_unknown", op_id: ^op, reason: reason} =
             HarklightSend.settle(db, settle,
               runner: fn
                 ["retry", "--op-id", ^op, "--journal-id", ^journal] ->
                   frame(absent, 1)

                 [
                   "receipt",
                   "--item-id",
                   "request",
                   "--entry-id",
                   "chat",
                   "--agent",
                   "Origin",
                   "--op-id",
                   ^op
                 ] = args ->
                   send(parent, {:saved_receipt, args})
                   projection_failure("receipt", op, "explicit-receipt-projection")
               end
             )

    assert_received {:saved_receipt, _}
    assert reason =~ "explicit-receipt-projection"
    assert {:ok, [[^op]]} = DB.query(db, "SELECT opId FROM harklight_operation_pauses")

    :ok = HarklightReceipts.dispatched(turn.seq)
    refute_receive {:before_agent_journal, _, ^op}, 100

    assert %{outcome: "committed", settled_command: "receipt", op_id: ^op} =
             HarklightSend.settle(db, settle,
               runner: fn ["retry", "--op-id", ^op, "--journal-id", ^journal] ->
                 receipt_result(op)
               end
             )

    assert {:ok, [[^op, ^journal, completed]]} =
             DB.query(db, "SELECT opId,journalId,completedAt FROM harklight_handoff_receipts")

    assert is_integer(completed)
  end

  for lineage <- [:restoration, :cycle_release] do
    @receipt_lineage lineage

    test "health redelivery through #{@receipt_lineage} owes handoff only after dispatch",
         %{db: db, call: call, main: main} do
      receiver = follower_session(db, main, "agent:follower:health-receipt")

      assert %{outcome: "committed"} =
               follow_for_test(
                 db,
                 follow_call(call, receiver, %{handle: @handle}),
                 runner: lifecycle_runner(db)
               )

      {wake, original, replacement} =
        health_receipt_redelivery!(db, receiver, @receipt_lineage)

      assert {:ok, false} =
               HarklightReceipts.drain(db, MapSet.new([original.seq, replacement]),
                 runner: fn argv -> send(self(), {:early_receipt, argv}) end
               )

      refute_received {:early_receipt, _}
      assert {:ok, []} = DB.query(db, "SELECT opId FROM harklight_handoff_receipts")

      assert {:ok, %{seq: ^replacement, wake_id: nil} = turn} =
               Ledger.claim_next(db, receiver.session_key, "replacement-receipt")

      assert :ok = Ledger.stamp_adapter(db, replacement, 1)
      record_prompt_dispatched!(db, turn, "Replacement display")

      assert :ok =
               Ledger.finish(db, replacement, "delivered", nil, owner_lease: turn.owner_lease)

      test_pid = self()
      accepted = start_supervised!({Agent, fn -> nil end})

      runner = fn
        ["journal-id"] ->
          frame(%{kind: "journal", journal_id: "fixture-journal"})

        ["retry", "--op-id", op, "--journal-id", "fixture-journal"] ->
          if Agent.get(accepted, & &1) == op do
            send(test_pid, {:health_receipt_replayed, op})
            receipt_result(op)
          else
            {JSON.encode!(%{kind: "operation_absent", op_id: op, journal_id: "fixture-journal"}),
             1}
          end

        ["receipt" | _] = argv ->
          op = List.last(argv)
          Agent.update(accepted, fn _ -> op end)
          send(test_pid, {:health_receipt_attempt, argv})
          {JSON.encode!(%{kind: "outcome_unknown", op_id: op}), 7}
      end

      opts = [db: db, runner: runner, retry_delay: 30_000]

      if @receipt_lineage == :restoration do
        # Exercise discovery by the replacement's live dispatch notification.
        assert {:ok, true} =
                 HarklightReceipts.drain(db, MapSet.new([replacement]), runner: runner)
      else
        # Startup also recovers a successful replacement whose notification was lost.
        start_supervised!({HarklightReceipts, opts})
      end

      assert_receive {:health_receipt_attempt,
                      [
                        "receipt",
                        "--item-id",
                        "request",
                        "--entry-id",
                        "health-chat",
                        "--agent",
                        "Replacement display",
                        "--rerouted",
                        "--op-id",
                        op
                      ]},
                     1_000

      assert {:ok, [[^wake, ^replacement, ^op, "fixture-journal", nil]]} =
               DB.query(
                 db,
                 "SELECT wakeId,turnSeq,opId,journalId,completedAt FROM harklight_handoff_receipts"
               )

      if @receipt_lineage == :cycle_release, do: assert(:ok = stop_supervised(HarklightReceipts))
      start_supervised!({HarklightReceipts, opts})
      assert_receive {:health_receipt_replayed, ^op}, 1_000

      assert eventually(fn ->
               DB.query(
                 db,
                 "SELECT opId FROM harklight_handoff_receipts WHERE completedAt IS NOT NULL"
               ) == {:ok, [[op]]}
             end)

      refute_received {:health_receipt_attempt, _}
    end
  end

  test "original and replacement dispatch proofs create one health redelivery receipt",
       %{db: db, session: session} do
    {wake, original, replacement} = health_receipt_redelivery!(db, session, :restoration, true)

    assert {:ok, %{seq: ^replacement, wake_id: nil} = turn} =
             Ledger.claim_next(db, session.session_key, "duplicate-receipt")

    assert :ok = Ledger.stamp_adapter(db, replacement, 1)
    record_prompt_dispatched!(db, turn, "Replacement display")

    runner =
      receipt_fixture_runner(fn args ->
        send(self(), {:unique_receipt, args})
        receipt_success()
      end)

    assert {:ok, false} = HarklightReceipts.drain(db, :all, runner: runner)

    assert_received {:unique_receipt,
                     [
                       "receipt",
                       "--item-id",
                       "request",
                       "--entry-id",
                       "health-chat",
                       "--agent",
                       "Original display"
                     ]}

    assert {:ok, false} =
             HarklightReceipts.drain(db, MapSet.new([original.seq, replacement]), runner: runner)

    assert {:ok, [[^wake, seq]]} =
             DB.query(db, "SELECT wakeId,turnSeq FROM harklight_handoff_receipts")

    assert seq == original.seq
    refute_received {:unique_receipt, _}
  end

  test "a definite receipt refusal retains the target and permits a new attempt", %{
    db: db,
    session: session
  } do
    assert :ok =
             HarklightWakes.capture_feed(db, @handle, 1, [feed_chat(1, "request", "chat")], :live)

    assert {:ok, [[wake]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    turn = deliver_discussion_turn!(db, wake, session.session_key)
    assert :ok = Ledger.stamp_adapter(db, turn.seq, 1)
    record_prompt_dispatched!(db, turn)

    test_pid = self()
    attempts = :atomics.new(1, [])

    runner = fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "receipt-journal"})

      ["retry", "--op-id", op, "--journal-id", journal] ->
        {JSON.encode!(%{kind: "operation_absent", op_id: op, journal_id: journal}), 1}

      [
        "receipt",
        "--item-id",
        "request",
        "--entry-id",
        "chat",
        "--agent",
        "Origin",
        "--op-id",
        op
      ] ->
        send(test_pid, {:receipt_attempt, op})

        if :atomics.add_get(attempts, 1, 1) == 1 do
          {JSON.encode!(%{kind: "refused", operation: "receipt", op_id: op, error: "forbidden"}),
           2}
        else
          receipt_result(op)
        end
    end

    start_supervised!({Tightbeam.HarklightReceipts, db: db, runner: runner, retry_delay: 10})
    assert_receive {:receipt_attempt, first}, 1_000
    assert_receive {:receipt_attempt, second}, 1_000
    assert first != second

    assert eventually(fn ->
             DB.query(
               db,
               "SELECT opId FROM harklight_handoff_receipts WHERE completedAt IS NOT NULL"
             ) ==
               {:ok, [[second]]}
           end)
  end

  test "a refused follower eligibility read does not end an open feed", %{
    db: db,
    session: session,
    main: main
  } do
    follower = follower_session(db, main, "agent:feed:eligible")

    assert {:ok, _} =
             DB.query(
               db,
               """
               INSERT INTO harklight_wake_follows(followId,sessionKey,kind,handle,messageId,state,createdAt)
               VALUES('follower',?1,'conversation',?2,'','open',1)
               """,
               [follower.session_key, @handle]
             )

    assert {:ok, _} =
             DB.query(db, "UPDATE sessions SET host='other' WHERE sessionKey=?1", [
               session.session_key
             ])

    commands = fake_harklight_session_end_agent!()
    proxy = start_supervised!({RefusingHarklightDB, {db, self()}})
    prepare = "SELECT sessionKey,host,vendorSessionId,state"
    eligibility = "FROM harklight_wake_handles h"
    assert :ok = GenServer.call(proxy, {:refuse, prepare})
    assert :ok = GenServer.call(proxy, {:refuse, eligibility})
    test_pid = self()

    listener = fn manager, handle, _vendor ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, :follower_feed_started)
      receive do: (:stop -> :ok)
    end

    start_supervised!({HarklightWakes, db: proxy, listener: listener})
    assert_receive {:refused_sql, ^prepare}, 1_000
    assert_receive {:refused_sql, ^eligibility}, 1_000
    assert_receive :follower_feed_started, 1_000
    refute File.exists?(commands)

    assert {:ok, [["active", nil]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")
  end

  test "feed death keeps retry custody when the recovery read is refused", %{db: db} do
    proxy = start_supervised!({RefusingHarklightDB, {db, self()}})
    test_pid = self()

    listener = fn manager, handle, _vendor ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, {:feed_started, self()})
      receive do: (:exit_feed -> :ok)
    end

    start_supervised!({HarklightWakes, db: proxy, listener: listener, retry_delays: [10]})
    assert_receive {:feed_started, original}, 1_000
    refused = "SELECT sessionKey,host,state FROM harklight_wake_handles WHERE handle"
    assert :ok = GenServer.call(proxy, {:refuse, refused})
    send(original, :exit_feed)
    assert_receive {:refused_sql, ^refused}, 1_000
    assert_receive {:feed_started, restarted}, 1_000
    assert original != restarted
  end

  test "Agent 0.2 filtered subprocess reopens from Tightbeam's checkpoint", %{db: db} do
    item = %{
      "item_id" => "server-item",
      "legacy_message_id" => "request",
      "sender" => "sender",
      "session" => @handle,
      "revision" => 1
    }

    chat =
      JSON.encode!(%{
        "kind" => "entry",
        "rev" => 14,
        "data" => %{
          "kind" => "reply",
          "author" => "person",
          "item_id" => "server-item",
          "entry_id" => "chat-1",
          "request_revision" => 1,
          "text" => "Resume me"
        }
      })

    lookup = JSON.encode!(%{"rev" => 14, "message" => item})

    fake_harklight_agent!("""
    case "$*" in
      'listen --follow --session #{@handle} --snapshot')
        printf '%s\n' '{"kind":"baseline","rev":12,"reason":"first_contact"}'
        printf '%s\n' '{"kind":"baseline_complete","rev":12}' '{"kind":"caught_up","rev":12}'
        exit 0
        ;;
      'listen --follow --session #{@handle} --after 12')
        printf '%s\\n' 'server returned HTTP 503: Some("retry_later") (request ID Some("transient-feed"))' >&2
        printf '%s\n' '#{chat}' '#{chat}' '{"kind":"caught_up","rev":15}'
        exec sleep 30
        ;;
      'message-get --item-id server-item')
        printf '%s\n' '#{lookup}'
        ;;
      *) exit 2 ;;
    esac
    """)

    start_supervised!({HarklightWakes, db: db, retry_delays: [20, 40]})

    assert eventually(fn ->
             DB.query(db, "SELECT rev FROM harklight_feed_checkpoints WHERE handle=?1", [@handle]) ==
               {:ok, [[15]]}
           end)

    assert {:ok, [[line]]} = DB.query(db, "SELECT rawLine FROM harklight_wake_entries")
    assert {:ok, []} = DB.query(db, "SELECT handle FROM harklight_feed_pauses")

    assert %{"session_handle" => @handle, "rev" => 14, "data" => %{"entry_id" => "chat-1"}} =
             JSON.decode!(line)
  end

  for mode <- [:batch, :sse] do
    test "Round 26 #{mode} pauses the feed through restart and resumes the committed cursor", %{
      db: db,
      call: call
    } do
      mode = unquote(mode)
      chat = JSON.encode!(feed_chat(3, "request", "before-failure"))
      following = JSON.encode!(feed_chat(4, "request", "after-failure"))

      {first_frames, diagnostic, checkpoint, resume} = round26_feed_case(mode, chat)

      fake_harklight_agent!("""
      printf '%s\\n' "$*" >> "$0.calls"
      if [ ! -e "$0.resume" ]; then
        #{first_frames}
        printf '%s\\n' '#{diagnostic}' >&2
        exit 1
      fi
      [ "$*" = 'listen --follow --session #{@handle} #{resume}' ] || exit 2
      if [ '#{mode}' = batch ]; then
        printf '%s\\n' '{"kind":"baseline","rev":3}' '#{chat}' '{"kind":"baseline_complete","rev":3}'
      fi
      printf '%s\\n' '#{following}' '{"kind":"caught_up","rev":4}'
      exec sleep 30
      """)

      agent_path = System.find_executable("harklight-agent")
      opts = [db: db, retry_delays: [10, 20]]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!({HarklightWakes, opts})

          assert eventually(fn ->
                   :sys.get_state(HarklightWakes).workers == %{} and
                     match?(
                       {:ok, [[_]]},
                       DB.query(db, "SELECT diagnostic FROM harklight_feed_pauses")
                     )
                 end)
        end)

      assert log =~ "internal_error"
      assert log =~ "#{mode}-request"
      assert log =~ "operation=listen"

      assert {:ok, [[pause]]} = DB.query(db, "SELECT diagnostic FROM harklight_feed_pauses")
      assert pause =~ "internal_error"
      assert pause =~ "#{mode}-request"
      assert {:ok, ^checkpoint} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")

      assert :ok = stop_supervised(HarklightWakes)
      start_supervised!({HarklightWakes, opts})
      HarklightWakes.activate(@handle, true)

      assert %{code: "harklight_feed_paused", reason: reason} =
               HarklightWakes.restore_listener(db, call, @handle)

      assert reason =~ "harklight-retry --session"
      assert eventually(fn -> :sys.get_state(HarklightWakes).workers == %{} end)
      assert File.read!(agent_path <> ".calls") |> String.split("\n", trim: true) |> length() == 1

      File.touch!(agent_path <> ".resume")

      assert %{counts: %{listening: 1}} =
               HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

      assert {:ok, []} = DB.query(db, "SELECT diagnostic FROM harklight_feed_pauses")
      assert {:ok, [[4]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")
      assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
    end
  end

  defp round26_feed_case(:batch, _chat) do
    {
      ":",
      ~s|listen: live updates paused: server returned HTTP 500: Some("internal_error") (request ID Some("batch-request"))|,
      [],
      "--snapshot"
    }
  end

  defp round26_feed_case(:sse, chat) do
    {
      "printf '%s\\n' '{\"kind\":\"baseline\",\"rev\":2}' '{\"kind\":\"baseline_complete\",\"rev\":2}' '#{chat}'",
      ~s|listen: live updates paused: internal_error (Request-Id Some("sse-request"))|,
      [[3]],
      "--after 3"
    }
  end

  test "startup preserves historical wakes and starts a fresh Agent 0.2 baseline", %{db: db} do
    historical = event(41, "discussion", "Historical wake")
    assert :ok = HarklightWakes.capture_line(db, @handle, historical)

    migrated_item = %{
      "item_id" => "migrated-item",
      "legacy_message_id" => "request",
      "sender" => "sender",
      "session" => @handle,
      "revision" => 1
    }

    message = JSON.encode!(%{"kind" => "message", "rev" => 1, "data" => migrated_item})
    chat = JSON.encode!(feed_chat(2, "migrated-item", "migrated-entry"))

    fake_harklight_agent!("""
    case "$*" in
      'listen --follow --session #{@handle} --snapshot')
        printf '%s\n' '{"kind":"baseline","rev":2,"reason":"first_contact"}'
        printf '%s\n' '#{message}' '#{chat}' '{"kind":"baseline_complete","rev":2}'
        printf '%s\n' '{"kind":"caught_up","rev":2}'
        exec sleep 30
        ;;
      *) exit 2 ;;
    esac
    """)

    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             DB.query(db, "SELECT rev FROM harklight_feed_checkpoints") == {:ok, [[2]]}
           end)

    assert {:ok, [["41", 41, ^historical], [id, 42, line]]} =
             DB.query(
               db,
               "SELECT eventId,feedCursor,rawLine FROM harklight_wake_entries ORDER BY feedCursor"
             )

    assert String.starts_with?(id, "v2_")

    assert %{
             "item_id" => "migrated-item",
             "request" => %{"message_id" => "request", "sender_id" => "sender"},
             "data" => %{"entry_id" => "migrated-entry"}
           } = JSON.decode!(line)
  end

  test "Agent 0.2 feed commits its baseline atomically and replays each wake once", %{
    db: db,
    session: session
  } do
    item = %{
      "item_id" => "server-item",
      "legacy_message_id" => "request",
      "sender" => "sender",
      "session" => @handle,
      "revision" => 1
    }

    chat = %{
      "kind" => "entry",
      "rev" => 8,
      "item" => item,
      "data" => %{
        "kind" => "reply",
        "author" => "person",
        "item_id" => "server-item",
        "entry_id" => "chat-1",
        "request_revision" => 1,
        "text" => "Continue"
      }
    }

    terminal = %{
      "kind" => "message",
      "rev" => 11,
      "data" =>
        Map.put(item, "terminal", %{"state" => "answered", "at_ms" => 12, "answer" => nil})
    }

    assert {:error, "unexpected_feed_record"} =
             HarklightWakes.capture_feed(db, @handle, 11, [chat, %{"rev" => 10}], :baseline)

    assert {:ok, []} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")
    assert {:ok, []} = DB.query(db, "SELECT eventId FROM harklight_wake_entries")

    assert :ok = HarklightWakes.capture_feed(db, @handle, 11, [terminal, chat], :baseline)
    assert :ok = HarklightWakes.capture_feed(db, @handle, 15, [%{terminal | "rev" => 15}], :live)
    assert :ok = HarklightWakes.capture_feed(db, @handle, 18, [], :live)
    assert {:ok, [[18]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")

    assert {:ok, [[chat_line], [answer_line]]} =
             DB.query(db, "SELECT rawLine FROM harklight_wake_entries ORDER BY feedCursor")

    assert %{"data" => %{"entry_id" => "chat-1"}, "item_id" => "server-item"} =
             JSON.decode!(chat_line)

    assert %{"data" => %{"terminal" => %{"answer" => nil}}, "item_id" => "server-item"} =
             JSON.decode!(answer_line)

    turn = running_receipt_turn!(db, session.session_key)

    assert {:ok, _} =
             DB.query(
               db,
               """
               UPDATE wakes SET deliveredTurnSeq=?1
               WHERE wakeId IN (SELECT wakeId FROM harklight_wake_entries)
               """,
               [turn.seq]
             )

    parent = self()

    runner = fn argv ->
      send(parent, {:receipt, argv})

      {JSON.encode!(%{
         "kind" => "committed",
         "operation" => "receipt",
         "response" => %{"status" => "recorded"}
       }), 0}
    end

    assert :ok =
             receipt_for_test(
               db,
               turn.seq,
               session.session_key,
               "Origin",
               runner: runner
             )

    refute_received {:receipt, _}

    record_prompt_dispatched!(db, turn)

    assert :ok =
             receipt_for_test(
               db,
               turn.seq,
               session.session_key,
               "Origin",
               runner: runner
             )

    assert_received {:receipt,
                     [
                       "receipt",
                       "--item-id",
                       "server-item",
                       "--entry-id",
                       "chat-1",
                       "--agent",
                       "Origin"
                     ]}

    assert_received {:receipt, ["receipt", "--item-id", "server-item", "--agent", "Origin"]}
    refute_received {:receipt, _}
  end

  test "Agent 0.2 send settles by operation ID and binds the server item", %{db: db, call: call} do
    new_handle = "a04e215a-59f6-45e9-801c-f28fff255dbd"

    metadata = %{
      "sender" => "sender",
      "session" => new_handle,
      "message" => %{
        "message_type" => "fyi",
        "title" => "A new send",
        "progress" => %{"percent" => 4, "stage" => "Start"}
      },
      "files" => [],
      "supersedes" => nil,
      "supersedes_local" => []
    }

    runner = fn
      ["journal-id"] ->
        {JSON.encode!(%{"kind" => "journal", "journal_id" => "journal-1"}), 0}

      [
        "send",
        "--prepare",
        "--op-id",
        key,
        "--session",
        "new",
        "--sender-id",
        "sender",
        "--title",
        "A new send",
        "--type",
        "fyi",
        "--progress",
        "4",
        "--progress-stage",
        "Start"
      ] ->
        {JSON.encode!(%{
           "kind" => "prepared",
           "operation" => "send",
           "op_id" => key,
           "request_id" => key,
           "session_handle" => new_handle,
           "prepared" => metadata
         }), 0}

      ["send", "--execute", "--op-id", key] ->
        assert %{state: "pending", handle: ^new_handle, op_id: ^key} =
                 HarklightLifecycle.lookup(db, key)

        {JSON.encode!(%{"kind" => "outcome_unknown", "op_id" => key}), 7}

      ["retry", "--op-id", key, "--journal-id", "journal-1"] ->
        {JSON.encode!(%{
           "kind" => "committed",
           "operation" => "send",
           "op_id" => key,
           "request_id" => key,
           "item_id" => "server-item",
           "prepared" => metadata,
           "response" => %{
             "rev" => 2,
             "message" => %{
               "item_id" => "server-item",
               "revision" => 1,
               "session" => new_handle,
               "sender" => "sender"
             }
           }
         }), 0}
    end

    params = %{
      harklight_session: "new",
      sender_id: "sender",
      title: "A new send",
      progress: 4,
      progress_stage: "Start"
    }

    assert %{outcome: "outcome_unknown", op_id: key} =
             pending = HarklightSend.send_request(db, %{call | params: params}, runner: runner)

    refute Map.has_key?(pending, :message_id)

    assert %{outcome: "committed", message_id: "server-item", wake_effect: "subscribed"} =
             HarklightSend.settle(db, %{call | params: %{op_id: key}}, runner: runner)

    assert %{state: "committed", message_id: "server-item", op_id: ^key} =
             HarklightLifecycle.lookup(db, "server-item")
  end

  test "Agent 0.2 Progress settles its exact operation against a migrated item", %{
    db: db,
    call: call
  } do
    parent = self()
    call = %{call | params: %{message_id: "request", percent: 42, stage: "Review"}}

    runner = fn
      ["message-get", "--sender-id", "sender", "--message-id", "request"] ->
        {JSON.encode!(%{
           "message" => %{"sender" => "sender", "session" => @handle, "item_id" => "item-1"}
         }), 0}

      ["journal-id"] ->
        {JSON.encode!(%{"kind" => "journal", "journal_id" => "journal-1"}), 0}

      [
        "progress",
        "--session",
        @handle,
        "--request",
        "item-1",
        "--percent",
        "42",
        "--stage",
        "Review",
        "--op-id",
        key
      ] ->
        send(parent, {:progress_op, key})
        {JSON.encode!(%{"kind" => "outcome_unknown", "op_id" => key}), 7}

      ["retry", "--op-id", key, "--journal-id", "journal-1"] ->
        send(parent, {:retried_op, key})

        {JSON.encode!(%{
           "kind" => "committed",
           "operation" => "progress",
           "op_id" => key,
           "response" => %{"message" => %{"item_id" => "item-1", "revision" => 7}}
         }), 0}
    end

    assert %{outcome: "outcome_unknown", op_id: key} =
             HarklightSend.change_request(db, call, "progress", runner: runner)

    assert_received {:progress_op, ^key}

    assert %{state: "pending", item_id: "item-1", journal_id: "journal-1"} =
             HarklightLifecycle.lookup_change(db, "request")

    assert %{outcome: "committed", revision: 7, wake_effect: "kept"} =
             HarklightSend.settle(db, %{call | params: %{message_id: "request"}}, runner: runner)

    assert_received {:retried_op, ^key}
  end

  test "a missing migrated Progress item preserves the definite Agent refusal", %{
    db: db,
    call: call
  } do
    call = %{call | params: %{message_id: "request", percent: 42, stage: "Review"}}

    runner = fn ["message-get", "--sender-id", "sender", "--message-id", "request"] ->
      missing_legacy_item()
    end

    assert %{outcome: "refused", code: "not_found", wake_effect: "none"} =
             HarklightSend.change_request(db, call, "progress", runner: runner)

    assert HarklightLifecycle.lookup_change(db, "request") == nil
  end

  test "custody successor receives future replies on the original handle", %{
    db: db,
    session: session,
    main: main
  } do
    successor =
      Org.create(db, %{
        session_key: "agent:successor:one",
        display_name: "Successor",
        owner_user_id: "owner",
        origin: "user:owner",
        spawned_by: main.session_key,
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })

    origin_key = session.session_key
    successor_key = successor.session_key

    assert %{"eventId" => _} =
             SessionCustodyTransfer.handle(db, %{
               principal: {:user, "owner"},
               params: %{
                 from_session_key: origin_key,
                 to_session_key: successor_key,
                 idempotency_key: "receiver-succession"
               }
             })

    assert {:ok, [[^origin_key, ^successor_key]]} =
             DB.query(
               db,
               "SELECT sessionKey,currentReceiverSessionKey FROM harklight_wake_handles"
             )

    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "Later"))

    assert {:ok, [[^successor_key]]} =
             DB.query(db, "SELECT sessionKey FROM wakes WHERE origin='process:tightbeam'")

    assert {:ok, [[^successor_key]]} =
             DB.query(db, "SELECT sessionKey FROM harklight_wake_deliveries")

    assert {:ok, [[^origin_key, ^successor_key]]} =
             DB.query(
               db,
               "SELECT sessionKey,currentReceiverSessionKey FROM harklight_send_operations"
             )

    assert {:ok, {:origin_retired, ^successor_key, [@handle], []}} =
             DB.transaction(db, fn txn ->
               HarklightWakes.retirement_handoff_in_txn(txn, successor_key)
             end)
  end

  test "filtered feed replay delivers one wake to the custody successor", %{
    db: db,
    session: session,
    main: main
  } do
    successor = follower_session(db, main, "agent:feed:successor")

    assert %{"eventId" => _} =
             SessionCustodyTransfer.handle(db, %{
               principal: {:user, "owner"},
               params: %{
                 from_session_key: session.session_key,
                 to_session_key: successor.session_key,
                 idempotency_key: "feed-successor"
               }
             })

    Org.retire(db, session.session_key, "user:owner", 60_000)
    chat = feed_chat(12, "request", "entry-1")
    assert :ok = HarklightWakes.capture_feed(db, @handle, 12, [chat], :live)
    assert :ok = HarklightWakes.capture_feed(db, @handle, 15, [%{chat | "rev" => 15}], :live)

    receiver = successor.session_key
    assert {:ok, [[^receiver]]} = DB.query(db, "SELECT sessionKey FROM harklight_wake_deliveries")
    assert {:ok, [[^receiver]]} = DB.query(db, "SELECT sessionKey FROM wakes")
  end

  test "filtered feed ignores an item without a registered send", %{db: db} do
    assert :ok =
             HarklightWakes.capture_feed(
               db,
               @handle,
               12,
               [feed_chat(12, "foreign", "entry-1")],
               :live
             )

    assert {:ok, [[12]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")
    assert {:ok, []} = DB.query(db, "SELECT eventId FROM harklight_wake_entries")
    assert {:ok, []} = DB.query(db, "SELECT wakeId FROM wakes")
  end

  test "filtered feed does not advance after retirement with no active receiver", %{
    db: db,
    session: session,
    main: main
  } do
    Org.retire(db, main.session_key, "user:owner", 60_000)
    Org.retire(db, session.session_key, "user:owner", 60_000)

    assert {:error, _reason} =
             HarklightWakes.capture_feed(
               db,
               @handle,
               12,
               [feed_chat(12, "request", "entry-1")],
               :live
             )

    assert {:ok, []} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")
    assert {:ok, []} = DB.query(db, "SELECT wakeId FROM wakes")
  end

  defp feed_superseded(rev, item) do
    %{
      "kind" => "message",
      "rev" => rev,
      "data" => %{
        "item_id" => item,
        "session" => @handle,
        "revision" => 1,
        "sender" => "sender",
        "terminal" => %{"state" => "superseded", "at_ms" => rev}
      }
    }
  end

  defp v2_chat_line(rev, text) do
    feed_chat(rev, "request", "entry-#{rev}")
    |> put_in(["data", "text"], text)
    |> Map.put("session_handle", @handle)
    |> JSON.encode!()
  end

  defp feed_chat(rev, item, entry) do
    %{
      "kind" => "entry",
      "rev" => rev,
      "data" => %{
        "item_id" => item,
        "entry_id" => entry,
        "request_revision" => 1,
        "kind" => "reply",
        "author" => "person",
        "text" => "Reply"
      }
    }
  end

  test "retirement transfers pending and later chats through a conversation follow", %{
    db: db,
    session: session,
    main: main
  } do
    line = v2_chat_line(1, "pending successor")
    assert :ok = HarklightWakes.capture_feed(db, @handle, 1, [JSON.decode!(line)], :live)
    assert %{state: "retired"} = Org.retire(db, session.session_key, "user:owner", 60_000)

    assert {:ok, [["conversation", "open"]]} =
             DB.query(db, "SELECT kind,state FROM harklight_wake_follows WHERE sessionKey=?1", [
               main.session_key
             ])

    assert {:ok, [[wake_id, prompt]]} =
             DB.query(
               db,
               "SELECT w.wakeId,w.prompt FROM harklight_wake_deliveries d JOIN wakes w ON w.wakeId=d.wakeId WHERE d.sessionKey=?1",
               [main.session_key]
             )

    assert {:ok, [[stored]]} = DB.query(db, "SELECT rawLine FROM harklight_wake_entries")
    assert String.starts_with?(prompt, stored <> "\n\n")
    assert JSON.decode!(stored)["data"] == JSON.decode!(line)["data"]
    assert prompt =~ session.session_key
    assert prompt =~ "Origin"
    assert prompt =~ "has retired"
    refute prompt =~ "from your originating session"
    assert prompt =~ "harklight-agent reply --item-id request --in-reply-to entry-1"
    turn = deliver_discussion_turn!(db, wake_id, main.session_key)
    assert :ok = Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

    assert :ok =
             HarklightWakes.capture_feed(
               db,
               @handle,
               2,
               [JSON.decode!(v2_chat_line(2, "later successor"))],
               :live
             )

    assert {:ok, [[key]]} =
             DB.query(
               db,
               "SELECT d.sessionKey FROM harklight_wake_deliveries d JOIN harklight_wake_entries e ON e.handle=d.handle AND e.eventId=d.eventId WHERE json_extract(e.rawLine, '$.data.entry_id')='entry-2'"
             )

    assert key == main.session_key
    assert {:ok, [["active"]]} = DB.query(db, "SELECT state FROM harklight_wake_handles")
  end

  test "failed discussion retry remains with the successor after retirement", %{
    db: db,
    session: session,
    main: main
  } do
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "failed chat"))
    assert {:ok, [[root]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    turn = deliver_discussion_turn!(db, root, session.session_key)
    assert :ok = Ledger.finish(db, turn.seq, "failed_unknown", nil, owner_lease: turn.owner_lease)
    Org.retire(db, session.session_key, "user:owner", 60_000)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_deliveries WHERE sessionKey=?1", [
               main.session_key
             ])

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes w JOIN wake_retry_attempts r ON r.wakeId=w.wakeId WHERE r.rootWakeId=?1 AND w.state='pending'",
               [root]
             )
  end

  test "retiring an ordinary follower of a historical retiree passes custody along its own lineage",
       %{db: db, session: session, main: main, call: call} do
    parent = follower_session(db, main, "agent:next")
    follower = follower_session(db, parent, "agent:prior-follower")

    assert %{outcome: "committed"} =
             HarklightFollows.follow(
               db,
               follow_call(call, follower, %{handle: @handle}),
               runner: lifecycle_runner(db),
               activate: false
             )

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        session.session_key
      ])

    line = event(1, "discussion", "historical conversation")
    assert :ok = HarklightWakes.capture_line(db, @handle, line)
    Org.retire(db, follower.session_key, "user:owner", 60_000)

    assert {:ok, [[key, prompt]]} =
             DB.query(
               db,
               "SELECT d.sessionKey,w.prompt FROM harklight_wake_deliveries d JOIN wakes w ON w.wakeId=d.wakeId WHERE d.sessionKey<>?1",
               [follower.session_key]
             )

    assert key == parent.session_key
    assert String.starts_with?(prompt, line <> "\n\n")
    assert prompt =~ session.session_key
    assert :ok = HarklightWakes.capture_line(db, @handle, event(2, "discussion", "next"))

    assert {:ok, [[^key]]} =
             DB.query(db, "SELECT sessionKey FROM harklight_wake_deliveries WHERE eventId='2'")

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_follows WHERE sessionKey=?1", [
               main.session_key
             ])
  end

  test "successor deliveries retry with identical authored payload and rerouted receipt", %{
    db: db,
    session: session,
    main: main
  } do
    assert :ok =
             HarklightWakes.capture_feed(db, @handle, 1, [feed_chat(1, "request", "1")], :live)

    Org.retire(db, session.session_key, "user:owner", 60_000)

    assert {:ok, [[root, prompt]]} =
             DB.query(
               db,
               "SELECT w.wakeId,w.prompt FROM wakes w JOIN harklight_wake_deliveries d ON d.wakeId=w.wakeId WHERE d.sessionKey=?1",
               [main.session_key]
             )

    turn = deliver_discussion_turn!(db, root, main.session_key)
    Ledger.stamp_adapter(db, turn.seq, 1)
    record_prompt_dispatched!(db, turn)

    assert :ok =
             receipt_for_test(
               db,
               turn.seq,
               main.session_key,
               main.display_name,
               runner: fn args ->
                 send(self(), {:receipt, args})
                 receipt_success()
               end
             )

    assert_received {:receipt,
                     [
                       "receipt",
                       "--item-id",
                       "request",
                       "--entry-id",
                       "1",
                       "--agent",
                       "Main",
                       "--rerouted"
                     ]}

    assert :ok = Ledger.finish(db, turn.seq, "failed_unknown", nil, owner_lease: turn.owner_lease)

    assert {:ok, [[^prompt]]} =
             DB.query(
               db,
               "SELECT w.prompt FROM wakes w JOIN wake_retry_attempts r ON r.wakeId=w.wakeId WHERE r.rootWakeId=?1 AND w.state='pending'",
               [root]
             )
  end

  test "successor lookup orders office, duty transfers and reporting lineage with cycle termination",
       %{db: db, session: session, main: main} do
    other = follower_session(db, main, "agent:duty")
    office = follower_session(db, main, "agent:office")
    insert_retirement_fixture(db, "retirement", session.session_key, main.session_key)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO retirement_owner_transfers(id,retirementId,formerOwnerSessionKey,newOwnerSessionKey,successorId,createdAt) VALUES(1,'retirement',?1,?2,'retirement',2)",
        [session.session_key, other.session_key]
      )

    assert successor(db, session.session_key).session_key == other.session_key
    Tightbeam.Roles.create!(db, "m-office", "owner", office.session_key)
    {:ok, _} = DB.query(db, "UPDATE roles SET createdAt=1 WHERE name='m-office'")

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO retirement_blockers(retirementId,kind,reference,sessionKey) VALUES('retirement','role','m-office',?1)",
        [session.session_key]
      )

    assert successor(db, session.session_key).session_key == office.session_key
    # A retired office holder passes on before the original holder's duty source.
    {:ok, _} =
      DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [office.session_key])

    assert successor(db, session.session_key).session_key == main.session_key
    # A recreated office, including a same-millisecond creation, falls through.
    {:ok, _} = DB.query(db, "UPDATE roles SET createdAt=10 WHERE name='m-office'")
    assert successor(db, session.session_key).session_key == other.session_key
    {:ok, _} = DB.query(db, "UPDATE roles SET createdAt=11 WHERE name='m-office'")
    assert successor(db, session.session_key).session_key == other.session_key

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO retirement_owner_transfers(id,retirementId,formerOwnerSessionKey,newOwnerSessionKey,successorId,createdAt) VALUES(2,'retirement',?1,?2,'retirement',2)",
        [other.session_key, session.session_key]
      )

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey IN (?1,?2)", [
        other.session_key,
        session.session_key
      ])

    assert successor(db, session.session_key) == nil
  end

  test "a remote successor is selected without admitting it or falling back locally", %{
    db: db,
    session: session,
    main: main
  } do
    remote = follower_session(db, main, "agent:remote-successor")
    Org.set_host(db, remote.session_key, "other-host")
    insert_retirement_fixture(db, "remote-duty", session.session_key, main.session_key)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO retirement_owner_transfers(retirementId,formerOwnerSessionKey,newOwnerSessionKey,successorId,createdAt) VALUES('remote-duty',?1,?2,'remote-duty',2)",
        [session.session_key, remote.session_key]
      )

    assert successor(db, session.session_key).session_key == remote.session_key
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "remote"))
    Org.retire(db, session.session_key, "user:owner", 60_000)
    assert {:ok, []} = DB.query(db, "SELECT * FROM harklight_wake_follows")
    assert {:ok, [[key]]} = DB.query(db, "SELECT sessionKey FROM harklight_wake_deliveries")
    assert key == session.session_key
  end

  for {state, error} <- [{"complete", nil}, {"unavailable", "origin_unavailable"}] do
    test "ended #{state}/#{error} conversation is not revived by follower retirement", %{
      db: db,
      session: session,
      main: main,
      call: call
    } do
      follower = follower_session(db, main, "agent:ended-follower")

      assert %{outcome: "committed"} =
               HarklightFollows.follow(
                 db,
                 follow_call(call, follower, %{handle: @handle}),
                 runner: lifecycle_runner(db),
                 activate: false
               )

      {:ok, _} =
        DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
          session.session_key
        ])

      {:ok, _} =
        DB.query(db, "UPDATE harklight_wake_handles SET state=?1,lastError=?2", [
          unquote(state),
          unquote(error)
        ])

      assert {:error, "harklight_origin_unavailable"} =
               HarklightWakes.capture_line(db, @handle, event(1, "discussion", "ended"))

      Org.retire(db, follower.session_key, "user:owner", 60_000)
      assert {:ok, [[key]]} = DB.query(db, "SELECT sessionKey FROM harklight_wake_follows")
      assert key == follower.session_key
      assert {:ok, []} = DB.query(db, "SELECT * FROM harklight_wake_deliveries")

      assert {:ok, [[unquote(state), unquote(error)]]} =
               DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")
    end
  end

  test "recoverable listener failure permits successor follow and pending delivery", %{
    db: db,
    session: session,
    main: main
  } do
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "recoverable"))

    {:ok, _} =
      DB.query(
        db,
        "UPDATE harklight_wake_handles SET state='unavailable',lastError='listener_exit_1'"
      )

    Org.retire(db, session.session_key, "user:owner", 60_000)
    assert {:ok, [[key]]} = DB.query(db, "SELECT sessionKey FROM harklight_wake_follows")
    assert key == main.session_key

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_deliveries WHERE sessionKey=?1", [
               key
             ])

    test_pid = self()

    listener = fn manager, handle, _ ->
      GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, :successor_listener_restored)

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive :successor_listener_restored

    assert {:ok, [["active", nil]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")
  end

  test "a whole retiring set resolves directly to its first surviving receiver", %{
    db: db,
    session: session,
    main: main
  } do
    parent = follower_session(db, main, "agent:retiring-parent")

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
        session.session_key,
        parent.session_key
      ])

    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "subtree"))

    assert {:ok, _} =
             DB.transaction(db, fn txn ->
               for key <- [session.session_key, parent.session_key] do
                 Org.retire_in_txn(txn, key, "user:owner", defer_harklight: true)
               end

               for key <- [session.session_key, parent.session_key] do
                 HarklightWakes.retirement_handoff_in_txn(txn, key)
               end
             end)

    assert {:ok, [[key]]} = DB.query(db, "SELECT sessionKey FROM harklight_wake_follows")
    assert key == main.session_key

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_deliveries WHERE sessionKey=?1", [
               parent.session_key
             ])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_deliveries WHERE sessionKey=?1", [
               main.session_key
             ])
  end

  test "a terminal queued but not dispatched transfers, while a received discussion does not", %{
    db: db,
    session: session,
    main: main
  } do
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "received"))
    assert {:ok, [[discussion]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    received = deliver_discussion_turn!(db, discussion, session.session_key)
    Ledger.stamp_adapter(db, received.seq, 1)
    record_prompt_dispatched!(db, received)

    assert :ok =
             Ledger.finish(db, received.seq, "delivered", nil, owner_lease: received.owner_lease)

    assert :ok = HarklightWakes.capture_line(db, @handle, event(2, "terminal", "not dispatched"))

    assert {:ok, [[terminal]]} =
             DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries WHERE eventId='2'")

    # A carrying turn has been created, but no prompt-dispatched event exists.
    deliver_discussion_turn!(db, terminal, session.session_key)
    Org.retire(db, session.session_key, "user:owner", 60_000)

    assert {:ok, [["2"]]} =
             DB.query(db, "SELECT eventId FROM harklight_wake_deliveries WHERE sessionKey=?1", [
               main.session_key
             ])
  end

  for earlier_status <- ["pending", "running", "failed_unknown", "delivered"] do
    test "existing follower gets a contextual handoff after #{earlier_status} prior delivery", %{
      db: db,
      session: session,
      main: main,
      call: call
    } do
      assert %{outcome: "committed"} =
               HarklightFollows.follow(
                 db,
                 follow_call(call, main, %{handle: @handle}),
                 runner: lifecycle_runner(db),
                 activate: false
               )

      line = event(1, "discussion", "same event, new responsibility")
      assert :ok = HarklightWakes.capture_line(db, @handle, line)

      assert {:ok, [[old, old_prompt]]} =
               DB.query(
                 db,
                 "SELECT w.wakeId,w.prompt FROM harklight_wake_deliveries d JOIN wakes w ON w.wakeId=d.wakeId WHERE d.sessionKey=?1",
                 [main.session_key]
               )

      earlier =
        if unquote(earlier_status) != "pending" do
          earlier = deliver_discussion_turn!(db, old, main.session_key)
          Ledger.stamp_adapter(db, earlier.seq, 1)
          record_prompt_dispatched!(db, earlier)

          if unquote(earlier_status) != "running" do
            assert :ok =
                     Ledger.finish(db, earlier.seq, unquote(earlier_status), nil,
                       owner_lease: earlier.owner_lease
                     )
          end

          earlier
        end

      Org.retire(db, session.session_key, "user:owner", 60_000)

      if unquote(earlier_status) == "running" do
        assert :ok =
                 Ledger.finish(db, earlier.seq, "failed_unknown", nil,
                   owner_lease: earlier.owner_lease
                 )
      end

      assert {:ok, [[handoff, prompt]]} =
               DB.query(
                 db,
                 "SELECT w.wakeId,w.prompt FROM harklight_wake_deliveries d JOIN wakes w ON w.wakeId=d.wakeId WHERE d.sessionKey=?1",
                 [main.session_key]
               )

      refute handoff == old
      assert String.starts_with?(prompt, line <> "\n\n")
      assert prompt =~ "Origin (#{session.session_key}), who has retired"
      refute prompt =~ "from your originating session"

      assert {:ok, [[^old_prompt]]} =
               DB.query(db, "SELECT prompt FROM wakes WHERE wakeId=?1", [old])

      assert {:ok, [[0]]} =
               DB.query(
                 db,
                 "SELECT count(*) FROM wakes w LEFT JOIN wake_retry_attempts r ON r.wakeId=w.wakeId WHERE COALESCE(r.rootWakeId,w.wakeId)=?1 AND w.state='pending'",
                 [old]
               )

      carrying = deliver_discussion_turn!(db, handoff, main.session_key)
      Ledger.stamp_adapter(db, carrying.seq, 1)
      record_prompt_dispatched!(db, carrying)

      assert :ok =
               Ledger.finish(db, carrying.seq, "failed_unknown", nil,
                 owner_lease: carrying.owner_lease
               )

      assert {:ok, [[retry, ^prompt]]} =
               DB.query(
                 db,
                 "SELECT w.wakeId,w.prompt FROM wakes w JOIN wake_retry_attempts r ON r.wakeId=w.wakeId WHERE r.rootWakeId=?1 AND w.state='pending'",
                 [handoff]
               )

      received = deliver_discussion_turn!(db, retry, main.session_key)

      assert :ok =
               Ledger.finish(db, received.seq, "delivered", nil,
                 owner_lease: received.owner_lease
               )

      assert {:ok, [[0]]} =
               DB.query(
                 db,
                 "SELECT count(*) FROM wakes w JOIN wake_retry_attempts r ON r.wakeId=w.wakeId WHERE r.rootWakeId=?1 AND w.state='pending'",
                 [handoff]
               )

      assert {:ok, [[2]]} =
               DB.query(db, "SELECT count(*) FROM harklight_wake_deliveries WHERE eventId='1'")

      assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
      assert {:ok, [["active"]]} = DB.query(db, "SELECT state FROM harklight_wake_handles")
    end
  end

  defp successor(db, key) do
    {:ok, result} = DB.transaction(db, &HarklightWakes.successor_in_txn(&1, key))
    result
  end

  defp insert_retirement_fixture(db, id, target, owner) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO unfinished_retirements(id,targetSessionKey,ownerSessionKey,principalRef,keepOpenDescendants,blockerKind,wakeId,state,createdAt) VALUES(?1,?2,?3,'user:owner',0,'work','fixture','retired',10)",
        [id, target, owner]
      )
  end

  test "a prepared send cannot bind through a different payload or origin", %{db: db, call: call} do
    assert %{code: "harklight_send_mismatch"} =
             HarklightWakes.prepare_send(db, call, @send_op, @payload <> " ")

    assert %{code: "harklight_origin_unavailable"} =
             HarklightWakes.bind_send(
               db,
               %{call | transport_session_key: "other"},
               @send_op,
               @payload,
               @result,
               @handle,
               "sender",
               "request"
             )

    assert %{code: "harklight_send_pending"} =
             HarklightWakes.register(db, put_in(call.params.harklight_message_id, "unbound"))

    assert %{state: "registered", op_id: @send_op} =
             HarklightWakes.bind_send(
               db,
               call,
               @send_op,
               @payload,
               @result,
               @handle,
               "sender",
               "request"
             )

    assert %{code: "harklight_send_mismatch"} =
             HarklightWakes.bind_send(
               db,
               call,
               @send_op,
               @payload,
               @result <> " ",
               @handle,
               "sender",
               "request"
             )
  end

  test "authenticated send persists the prepared request before execute and binds its original result",
       %{
         db: db,
         call: call
       } do
    handle = "a1424ed8-763c-4b13-9a0d-55a70cd65b17"
    request_id = "request-new"
    hash = String.duplicate("a", 64)

    send_call = %{
      call
      | params: %{
          harklight_session: "new",
          message_type: "request",
          message_kind: "blocker",
          importance: "high",
          stake: "A one-week delay",
          by_when: "2026-11-02T17:00:00Z",
          reply: true,
          sender_id: "sender",
          title: "Question",
          choices: ["Approve", "Defer"],
          files: ["/tmp/request.txt"]
        }
    }

    file = %{name: "request.txt", size_bytes: 4, sha256: hash}

    prepared = %{
      sender: "sender",
      session: handle,
      message: %{title: "Question", message_type: "request"},
      files: [file],
      supersedes_local: []
    }

    runner = fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "send-journal"})

      ["send", "--prepare", "--op-id", op | args] ->
        refute "--controller" in args
        refute "--route" in args
        assert "--reply" in args

        for pair <- [
              ["--type", "request"],
              ["--kind", "blocker"],
              ["--importance", "high"],
              ["--stake", "A one-week delay"],
              ["--by-when", "2026-11-02T17:00:00Z"],
              ["--choice", "Approve"],
              ["--choice", "Defer"],
              ["--file", "/tmp/request.txt"]
            ] do
          assert pair in Enum.chunk_every(args, 2, 1, :discard)
        end

        assert {:ok, [[0]]} =
                 DB.query(db, "SELECT count(*) FROM harklight_send_operations WHERE opId=?1", [op])

        send_prepared_frame(op, handle, prepared)

      ["send", "--execute", "--op-id", op] ->
        assert {:ok, [[session, payload, attempted_at]]} =
                 DB.query(
                   db,
                   "SELECT sessionKey,payload,attemptedAt FROM harklight_send_operations WHERE opId=?1",
                   [op]
                 )

        assert session == call.session_key
        assert is_integer(attempted_at)
        saved = JSON.decode!(payload)
        assert saved["request"]["message"]["message_id"] == op
        assert saved["request"]["prepared"] == JSON.decode!(JSON.encode!(prepared))
        assert saved["files"] == [JSON.decode!(JSON.encode!(file))]
        send_committed_frame(op, handle, "sender", request_id, prepared)
    end

    assert %{
             state: "registered",
             session_key: session,
             op_id: op_id,
             message_type: "request",
             message_type_label: "Request"
           } =
             HarklightSend.send_request(db, send_call, runner: runner)

    assert session == call.session_key

    assert {:ok, [[^op_id, ^session, ^handle, "sender", ^request_id, "bound"]]} =
             DB.query(
               db,
               "SELECT opId,sessionKey,handle,senderId,messageId,state FROM harklight_send_operations WHERE opId=?1",
               [op_id]
             )
  end

  test "typed send refusals explain a fix before preparing an operation", %{db: db, call: call} do
    assert {:ok, [[existing_operations]]} =
             DB.query(db, "SELECT count(*) FROM harklight_send_operations")

    valid = %{
      harklight_session: "new",
      sender_id: "sender",
      title: "Question",
      message_type: "request",
      reply: true
    }

    cases = [
      {Map.delete(valid, :message_type), "harklight_type_required", "--type is required"},
      {Map.put(valid, :message_type, "notice"), "harklight_type_invalid", "fyi or request"},
      {
        Map.merge(valid, %{message_type: "fyi", reply: false, choices: ["Ship"]}),
        "harklight_fyi_has_answer_controls",
        "remove --choices-json and --reply"
      },
      {
        Map.merge(valid, %{message_type: "fyi", reply: true}),
        "harklight_fyi_has_answer_controls",
        "remove --choices-json and --reply"
      },
      {Map.put(valid, :reply, false), "harklight_request_needs_answer_controls", "--reply"},
      {
        Map.put(valid, :answer_ui, "/tmp/answer-ui.json"),
        "harklight_answer_ui_has_answer_controls",
        "remove --reply"
      },
      {
        Map.merge(valid, %{reply: false, choices: ["Cover A"], answer_ui: "/tmp/answer-ui.json"}),
        "harklight_answer_ui_has_answer_controls",
        "remove --choices-json"
      },
      {
        Map.merge(valid, %{message_type: "fyi", reply: false, answer_ui: "/tmp/answer-ui.json"}),
        "harklight_answer_ui_requires_request",
        "--type request"
      },
      {
        Map.put(valid, :answer_ui, ""),
        "harklight_answer_ui_invalid",
        "non-empty path"
      },
      {Map.put(valid, :message_kind, "update"), "harklight_kind_invalid", "blocker or success"},
      {
        Map.put(valid, :importance, "urgent"),
        "harklight_importance_invalid",
        "low, normal, high, now"
      },
      {Map.put(valid, :stake, "  "), "harklight_stake_invalid", "non-empty text"},
      {Map.put(valid, :by_when, "tomorrow"), "harklight_by_when_invalid", "RFC 3339"}
    ]

    for {params, code, fix} <- cases do
      result =
        HarklightSend.send_request(db, %{call | params: params},
          runner: fn _args -> flunk("invalid message reached the Agent CLI") end
        )

      assert %{outcome: "failed", code: ^code, reason: reason} = result
      assert reason =~ fix
    end

    assert {:ok, [[^existing_operations]]} =
             DB.query(db, "SELECT count(*) FROM harklight_send_operations")
  end

  test "FYI send forwards Seen-only type through the authenticated origin route", %{
    db: db,
    call: call
  } do
    handle = "b6a87513-b91d-4314-849a-cb8d80225864"
    message_id = "seen-notice"

    send_call = %{
      call
      | params: %{
          harklight_session: "new",
          message_type: "fyi",
          reply: false,
          sender_id: "sender",
          title: "Build finished",
          body: "The export is ready."
        }
    }

    prepared = %{
      sender: "sender",
      session: handle,
      message: %{title: "Build finished", body: "The export is ready.", message_type: "fyi"},
      files: [],
      supersedes_local: []
    }

    runner = fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "send-journal"})

      ["send", "--prepare", "--op-id", op | args] ->
        assert ["--type", "fyi"] in Enum.chunk_every(args, 2, 1, :discard)
        refute "--reply" in args
        refute "--choice" in args
        refute "--controller" in args
        send_prepared_frame(op, handle, prepared)

      ["send", "--execute", "--op-id", op] ->
        assert {:ok, [[session, payload]]} =
                 DB.query(
                   db,
                   "SELECT sessionKey,payload FROM harklight_send_operations WHERE opId=?1",
                   [op]
                 )

        assert session == call.session_key
        assert JSON.decode!(payload)["request"]["session_handle"] == handle
        send_committed_frame(op, handle, "sender", message_id, prepared)
    end

    assert %{
             state: "registered",
             session_key: session,
             handle: ^handle,
             message_id: ^message_id,
             message_type: "fyi",
             message_type_label: "FYI"
           } = HarklightSend.send_request(db, send_call, runner: runner)

    assert session == call.session_key
  end

  test "answer UI path and image files pass through unchanged and V2 refusal reason is preserved",
       %{db: db, call: call} do
    answer_ui = "/tmp/cover assets/answer-ui.json"
    files = ["/tmp/cover-a.jpg", "/tmp/cover-b.jpg"]
    refusal_reason = "answer_ui names cover-c.jpg, which is absent from --files-json"

    prepared = %{
      sender: "sender",
      session: @handle,
      message: %{title: "Choose a cover", message_type: "request"},
      files:
        for(
          path <- files,
          do: %{name: Path.basename(path), size_bytes: 4, sha256: String.duplicate("a", 64)}
        ),
      supersedes_local: []
    }

    runner = fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "send-journal"})

      ["send", "--prepare", "--op-id", op | args] ->
        pairs = Enum.chunk_every(args, 2, 1, :discard)
        assert ["--answer-ui", answer_ui] in pairs
        assert Enum.all?(files, &(["--file", &1] in pairs))
        refute "--reply" in args
        refute "--choice" in args
        send_prepared_frame(op, @handle, prepared)

      ["send", "--execute", "--op-id", op] ->
        {JSON.encode!(%{
           kind: "refused",
           operation: "send",
           op_id: op,
           error: "invalid_field",
           reason: refusal_reason
         }), 2}
    end

    result =
      HarklightSend.send_request(
        db,
        %{
          call
          | params: %{
              harklight_session: @handle,
              message_type: "request",
              answer_ui: answer_ui,
              sender_id: "sender",
              title: "Choose a cover",
              files: files
            }
        },
        runner: runner
      )

    assert %{outcome: "refused", reason: ^refusal_reason, wake_effect: "none"} = result
  end

  test "answer UI prepared content is retained when the send commits", %{db: db, call: call} do
    document = %{"schema" => "attention-client.ui/1", "opaque" => 18_446_744_073_709_551_617}

    prepared = %{
      sender: "sender",
      session: @handle,
      message: %{title: "Choose", message_type: "request", answer_ui: document},
      files: [],
      supersedes_local: []
    }

    runner = fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "send-journal"})

      ["send", "--prepare", "--op-id", op | args] ->
        assert ["--answer-ui", "/tmp/answer-ui.json"] in Enum.chunk_every(args, 2, 1, :discard)
        send_prepared_frame(op, @handle, prepared)

      ["send", "--execute", "--op-id", op] ->
        assert {:ok, [[payload]]} =
                 DB.query(db, "SELECT payload FROM harklight_send_operations WHERE opId=?1", [op])

        assert JSON.decode!(payload)["request"]["message"]["answer_ui"] == document
        send_committed_frame(op, @handle, "sender", "ui-committed", prepared)
    end

    result =
      HarklightSend.send_request(
        db,
        %{
          call
          | params: %{
              harklight_session: @handle,
              message_type: "request",
              answer_ui: "/tmp/answer-ui.json",
              sender_id: "sender",
              title: "Choose"
            }
        },
        runner: runner
      )

    assert %{outcome: "committed", state: "registered", message_id: "ui-committed"} = result
  end

  test "uncertain result stays unregistered and same-operation retry can bind it", %{
    db: db,
    call: call
  } do
    handle = "ca16c43c-e3b5-4ae8-b9cd-6a8829749697"

    send_call = %{
      call
      | params: %{
          harklight_session: "new",
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Question"
        }
    }

    parent = self()

    prepared = %{
      sender: "sender",
      session: handle,
      message: %{title: "Question", message_type: "request"},
      files: [],
      supersedes_local: []
    }

    runner = fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "send-journal"})

      ["send", "--prepare", "--op-id", op | _] ->
        send_prepared_frame(op, handle, prepared)

      ["send", "--execute", "--op-id", op] ->
        send(parent, {:attempted, op})
        {JSON.encode!(%{kind: "outcome_unknown", op_id: op, request_id: "server-request"}), 7}

      ["retry", "--op-id", op, "--journal-id", "send-journal"] ->
        send(parent, {:retried, op})
        send_committed_frame(op, handle, "sender", "new-request", prepared)
    end

    assert %{code: "harklight_outcome_unknown", op_id: op_id} =
             HarklightSend.send_request(db, send_call, runner: runner)

    assert_received {:attempted, ^op_id}

    assert {:ok, [["pending"]]} =
             DB.query(db, "SELECT state FROM harklight_send_operations WHERE opId=?1", [op_id])

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_requests WHERE messageId='new-request'"
             )

    assert :ok = HarklightSend.recover_pending(db, runner: runner)
    assert_received {:retried, ^op_id}

    assert {:ok, [["bound"]]} =
             DB.query(db, "SELECT state FROM harklight_send_operations WHERE opId=?1", [op_id])

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_requests WHERE messageId='new-request'"
             )

    refute_receive {:retried, _}
    assert :ok = HarklightSend.recover_pending(db, runner: runner)
    refute_receive {:retried, _}

    assert %{code: "harklight_origin_unavailable"} =
             HarklightSend.send_request(db, %{send_call | transport_session_key: nil},
               runner: fn _ -> flunk("sent") end
             )
  end

  test "recovery binds an operation committed before the local result was saved", %{
    db: db,
    call: call
  } do
    handle = "88d24275-358a-4c5d-b44f-a55dc8c03db9"
    request_id = "committed-request"

    send_call = %{
      call
      | params: %{
          harklight_session: "new",
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Question"
        }
    }

    parent = self()

    prepared = %{
      sender: "sender",
      session: handle,
      message: %{title: "Question", message_type: "request"},
      files: [],
      supersedes_local: []
    }

    runner = fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "send-journal"})

      ["send", "--prepare", "--op-id", op | _] ->
        send_prepared_frame(op, handle, prepared)

      ["send", "--execute", "--op-id", op] ->
        send(parent, {:executed, op})

        send_committed_frame(
          op,
          handle,
          "sender",
          request_id,
          put_in(prepared, [:message, :title], "Wrong")
        )

      ["retry", "--op-id", op, "--journal-id", "send-journal"] ->
        send(parent, {:retried, op})
        send_committed_frame(op, handle, "sender", request_id, prepared)
    end

    assert %{code: "harklight_result_unconfirmed", op_id: op_id} =
             HarklightSend.send_request(db, send_call, runner: runner)

    assert_received {:executed, ^op_id}

    assert {:ok, [["pending", session]]} =
             DB.query(
               db,
               "SELECT state,sessionKey FROM harklight_send_operations WHERE opId=?1",
               [op_id]
             )

    assert session == call.session_key

    assert :ok = HarklightSend.recover_pending(db, runner: runner)
    assert_received {:retried, ^op_id}

    assert {:ok, [["bound", ^handle, "sender", ^request_id]]} =
             DB.query(
               db,
               "SELECT state,handle,senderId,messageId FROM harklight_send_operations WHERE opId=?1",
               [op_id]
             )

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_requests WHERE messageId=?1", [
               request_id
             ])

    assert :ok = HarklightSend.recover_pending(db, runner: runner)
    refute_receive {:retried, _}
  end

  test "caller origin fields and an already registered minted handle cannot establish a send", %{
    db: db,
    call: call
  } do
    send_call = %{
      call
      | params: %{
          harklight_session: "new",
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Question"
        }
    }

    claimed_origin = %{
      send_call
      | params: Map.put(send_call.params, :session_key, "agent:origin:one")
    }

    assert %{code: "invalid_harklight_send"} =
             HarklightSend.send_request(db, claimed_origin, runner: fn _ -> flunk("prepared") end)

    runner = fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "send-journal"})

      ["send", "--prepare", "--op-id", op | _] ->
        send_prepared_frame(op, @handle, %{
          sender: "sender",
          session: @handle,
          message: %{title: "Question", message_type: "request"},
          files: [],
          supersedes_local: []
        })
    end

    assert %{code: "harklight_origin_mismatch"} =
             HarklightSend.send_request(db, send_call, runner: runner)
  end

  test "registration stays with the exact authenticated local origin", %{db: db, call: call} do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    assert %{state: "registered"} = HarklightWakes.register(db, call)

    assert %{code: "harklight_origin_unavailable"} =
             HarklightWakes.register(db, %{call | transport_session_key: "agent:other"})

    assert {:ok, [["agent:origin:one", host]]} =
             DB.query(db, "SELECT sessionKey,host FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    assert host == Placement.local_host_name()
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_requests")
  end

  test "feed order and request identity survive replay and terminal state", %{db: db, call: call} do
    first = put_in(feed_chat(41, "request", "chat-1"), ["data", "text"], "First words")
    second = put_in(feed_chat(42, "request", "chat-2"), ["data", "text"], "Second words")

    final = %{
      "kind" => "message",
      "rev" => 43,
      "data" => %{
        "item_id" => "request",
        "session" => @handle,
        "revision" => 1,
        "sender" => "sender",
        "terminal" => %{"state" => "answered", "at_ms" => 100, "answer" => "Seen"}
      }
    }

    for frame <- [first, second, final, %{first | "rev" => 44}] do
      assert :ok = HarklightWakes.capture_feed(db, @handle, frame["rev"], [frame], :live)
    end

    assert {:ok, [[first_prompt], [second_prompt], [answer_prompt]]} =
             DB.query(
               db,
               """
               SELECT w.prompt FROM harklight_wake_entries e JOIN wakes w ON w.wakeId=e.wakeId
               WHERE w.sessionKey=?1 AND e.messageId='request' ORDER BY e.feedCursor
               """,
               [call.session_key]
             )

    assert first_prompt =~ "First words"
    assert first_prompt =~ "reply --item-id request --in-reply-to chat-1"
    assert second_prompt =~ "Second words"
    assert answer_prompt =~ "Seen"
    assert answer_prompt =~ "result --item-id request --status applied|refused|received"
  end

  test "other requests on the same handle reach the same origin in feed order", %{
    db: db,
    call: call
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)

    assert {:error, "harklight_send_pending"} =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "other", "other"))

    other_op = "212f4c59-2ad2-4786-a18c-d4be86d53eb8"
    other_payload = ~s({"type":"send","message":{"sender_id":"sender","message_id":"other"}})

    other_result =
      ~s({"kind":"sent","session":"#{@handle}","sender_id":"sender","request":"other"})

    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, other_op, other_payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               call,
               other_op,
               other_payload,
               other_result,
               @handle,
               "sender",
               "other"
             )

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "other", "other"))

    assert :ok = HarklightWakes.capture_line(db, @handle, event(3, "discussion", "current"))

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_requests")
    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

    assert {:error, "event_order_invalid"} =
             HarklightWakes.capture_line(db, @handle, event(2, "discussion", "late"))

    changed = event(3, "discussion", "current", "wrong-request")
    assert {:error, "event_identity_mismatch"} = HarklightWakes.capture_line(db, @handle, changed)

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
  end

  for terminal <- ~w(failed failed_unknown canceled), dispatched <- [false, true] do
    @delivery_terminal terminal
    @delivery_dispatched dispatched
    test "discussion #{@delivery_terminal} dispatched=#{@delivery_dispatched} retries unchanged to the same session",
         %{db: db, session: session} do
      line = event(1, "discussion", "keep this exact discussion")
      assert :ok = HarklightWakes.capture_line(db, @handle, line)
      assert {:ok, [[root, prompt]]} = DB.query(db, "SELECT wakeId,prompt FROM wakes")
      assert {:ok, entries} = DB.query(db, "SELECT * FROM harklight_wake_entries")
      assert {:ok, command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
      turn = deliver_discussion_turn!(db, root, session.session_key)

      if @delivery_dispatched do
        {:ok, _} = DB.query(db, "UPDATE turns SET adapterGen=1 WHERE seq=?1", [turn.seq])

        assert :ok =
                 Tightbeam.TurnLifecycle.append(db, turn.seq, %{
                   event_key: "prompt:dispatched",
                   producer_event_id: "request:1",
                   kind: "prompt_dispatched",
                   stage: "prompt",
                   outcome: "dispatched",
                   cause: "acp:port-write",
                   principal: "process:tightbeam",
                   owner_lease: turn.owner_lease,
                   adapter_gen: 1,
                   acp_request_id: 1,
                   detail: %{v: 1}
                 })
      end

      assert :ok =
               Tightbeam.Ledger.finish(db, turn.seq, @delivery_terminal, nil,
                 owner_lease: turn.owner_lease
               )

      assert :already_terminal =
               Tightbeam.Ledger.finish(db, turn.seq, @delivery_terminal, nil,
                 owner_lease: turn.owner_lease
               )

      key = session.session_key

      assert {:ok, [[retry, ^key, ^prompt, "pending", due, ended]]} =
               DB.query(
                 db,
                 """
                 SELECT w.wakeId,w.sessionKey,w.prompt,w.state,w.dueAt,t.endedAt
                 FROM wake_retry_attempts r JOIN wakes w ON w.wakeId=r.retryWakeId
                 JOIN turns t ON t.seq=r.sourceTurnSeq WHERE r.wakeId=?1
                 """,
                 [root]
               )

      assert due >= ended + 30_000

      assert {:ok, source_scope} =
               DB.query(
                 db,
                 "SELECT ownerUserId,sourceVisibilityScope,sourceAddress FROM wakes WHERE wakeId=?1",
                 [root]
               )

      assert {:ok, ^source_scope} =
               DB.query(
                 db,
                 "SELECT ownerUserId,sourceVisibilityScope,sourceAddress FROM wakes WHERE wakeId=?1",
                 [retry]
               )

      refute retry == root
      assert {:ok, ^entries} = DB.query(db, "SELECT * FROM harklight_wake_entries")
      assert {:ok, ^command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
      assert {:ok, [["active"]]} = DB.query(db, "SELECT state FROM harklight_wake_handles")

      recovered = deliver_discussion_turn!(db, retry, key)
      assert recovered.prompt == turn.prompt

      assert :ok =
               Tightbeam.Ledger.finish(db, recovered.seq, "delivered", nil,
                 owner_lease: recovered.owner_lease
               )

      assert {:ok, [["acted", nil]]} =
               DB.query(
                 db,
                 "SELECT outcome,retryWakeId FROM wake_retry_attempts WHERE wakeId=?1",
                 [retry]
               )

      assert {:ok, [["delivered"]]} =
               DB.query(
                 db,
                 "SELECT t.status FROM wakes w JOIN turns t ON t.seq=w.deliveredTurnSeq WHERE w.wakeId=?1",
                 [retry]
               )

      # Normal turn completion is custody receipt, not an ACK on the agent's behalf.
      assert {:ok, ^command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
      assert {:ok, ^entries} = DB.query(db, "SELECT * FROM harklight_wake_entries")
    end
  end

  test "repeated discussion failure keeps backoff and never marks an active session gone", %{
    db: db,
    session: session
  } do
    assert {:ok, command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "pending"))
    assert {:ok, [[root]]} = DB.query(db, "SELECT wakeId FROM wakes")

    Enum.reduce(1..8, root, fn attempt, wake ->
      turn = deliver_discussion_turn!(db, wake, session.session_key)

      assert :ok =
               Tightbeam.Ledger.finish(db, turn.seq, "failed_unknown", nil,
                 owner_lease: turn.owner_lease
               )

      assert {:ok, [[next, ^attempt, "pending", due, ended]]} =
               DB.query(
                 db,
                 """
                 SELECT w.wakeId,r.attempt,w.state,w.dueAt,t.endedAt
                 FROM wake_retry_attempts p JOIN wake_retry_attempts r ON r.wakeId=p.retryWakeId
                 JOIN wakes w ON w.wakeId=r.wakeId JOIN turns t ON t.seq=p.sourceTurnSeq
                 WHERE p.wakeId=?1
                 """,
                 [wake]
               )

      assert due > ended

      assert {:ok, [["active", nil]]} =
               DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")

      next
    end)

    assert {:ok, ^command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
  end

  test "a failed mixed carrier retries only its discussion without losing other health custody",
       %{db: db, session: session} do
    alias Tightbeam.{Gateway, Ledger, NoticeBatcher, Wakes}
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(1, "discussion", "retained discussion")
             )

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(2, "discussion", "second retained discussion")
             )

    assert {:ok, original_sources} =
             DB.query(db, "SELECT wakeId,prompt FROM wakes ORDER BY wakeId")

    Wakes.schedule(db, %{
      session_key: session.session_key,
      origin: "agent:peer",
      prompt: "unrelated notice",
      due_at: 1,
      class: "fyi"
    })

    assert [carrier] = NoticeBatcher.recover(db, System.system_time(:millisecond) + 1)
    assert {:ok, turn} = Ledger.claim_next(db, session.session_key, "discussion-test")
    assert turn.wake_id == carrier
    assert turn.prompt =~ "unrelated notice"
    assert :ok = Ledger.finish(db, turn.seq, "failed", nil, owner_lease: turn.owner_lease)
    expected = Enum.map(original_sources, fn [root, prompt] -> [root, prompt, "pending"] end)

    assert {:ok, ^expected} =
             DB.query(db, """
             SELECT r.rootWakeId,w.prompt,w.state FROM wake_retry_attempts r
             JOIN wakes w ON w.wakeId=r.wakeId WHERE r.attempt=1 ORDER BY r.rootWakeId
             """)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Wakes.record_health_redelivery_source_in_txn(txn, turn.seq, "unclassified")
             end)

    # An unrelated successful turn remains the existing health recovery signal.
    assert {:ok, {:appended, _, _, _}} =
             DB.transaction(db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 session.session_key,
                 "user:owner",
                 "healthy turn"
               )
             end)

    assert {:ok, healthy} = Ledger.claim_next(db, session.session_key, "discussion-test")

    assert :ok =
             Ledger.finish(db, healthy.seq, "delivered", nil, owner_lease: healthy.owner_lease)

    assert {:ok, 1} =
             DB.transaction(db, fn txn ->
               Wakes.redeliver_pending_health_intents_in_txn(txn, session, healthy)
             end)

    assert {:ok, [[prompt]]} =
             DB.query(db, "SELECT prompt FROM turns WHERE sessionKey=?1 AND status='queued'", [
               session.session_key
             ])

    assert prompt == turn.prompt
  end

  test "discussion retry shares the existing prewrite successor and retains its authority", %{
    db: db,
    session: session
  } do
    alias Tightbeam.{Ledger, NoticeAuthority, NoticeSubmission}

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "prewrite retry"))

    assert {:ok, [[root]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    turn = deliver_discussion_turn!(db, root, session.session_key)

    evidence =
      NoticeSubmission.prewrite_evidence(
        :prompt,
        {:acp_request_not_dispatched, {:transport_capacity_exceeded, 101, 100}}
      )

    assert {:ok, [retry]} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", nil,
                        owner_lease: turn.owner_lease,
                        prewrite_evidence: evidence
                      )

               NoticeSubmission.restore_in_txn(txn, turn, evidence)
             end)

    seq = turn.seq
    assert %{root_wake_id: ^root, root_turn_seq: ^seq} = NoticeAuthority.resolve!(db, retry)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId=?1 AND state='pending'", [
               retry
             ])
  end

  test "retirement ends a discussion pending after turn failure through the existing gone path",
       %{db: db, session: session} do
    assert {:ok, command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
    calls = fake_harklight_session_end_agent!()

    listener = fn manager, handle, _ ->
      GenServer.call(manager, {:feed_ready, handle})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(1, "discussion", "pending retirement")
             )

    assert {:ok, [[root]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    turn = deliver_discussion_turn!(db, root, session.session_key)

    assert :ok =
             Tightbeam.Ledger.finish(db, turn.seq, "failed_unknown", nil,
               owner_lease: turn.owner_lease
             )

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        Org.personal_session_key("owner")
      ])

    assert %{state: "retired"} = Org.retire(db, session.session_key, "user:owner", 60_000)

    assert eventually(fn ->
             File.exists?(calls) and
               File.read!(calls) =~ "session end --session #{@handle}"
           end)

    assert {:ok, ^command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
  end

  defp deliver_discussion_turn!(db, wake_id, session_key) do
    assert {:ok, {:appended, ^session_key, _, _}} =
             DB.transaction(db, fn txn ->
               wake = Tightbeam.Wakes.get_in_txn(txn, wake_id)

               Tightbeam.Gateway.deliver_prompt_in_txn(txn, session_key, wake.origin, wake.prompt,
                 wake_id: wake_id,
                 sender: wake.origin,
                 fire_wake_in_txn: true
               )
             end)

    assert {:ok, turn} = Tightbeam.Ledger.claim_next(db, session_key, "discussion-test")
    turn
  end

  test "a completed request retry does not restart listening", %{db: db, call: call} do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      send(test_pid, :listener_started)
      :ok = GenServer.call(manager, {:feed_ready, handle})
      :ok = GenServer.call(manager, {:finished, handle, :complete})
      send(test_pid, :listener_completed)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive :listener_started
    assert_receive :listener_completed
    assert %{state: "complete"} = HarklightWakes.register(db, call)
    refute_receive :listener_started, 100
    :ok = stop_supervised(HarklightWakes)
    start_supervised!({HarklightWakes, db: db, listener: listener})
    refute_receive :listener_started, 100

    assert {:ok, [["complete"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
  end

  test "server expiry and supersession reach the origin once and allow idle completion", %{
    db: db,
    call: call
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)

    second_op = "0bdb87a0-3a09-4f61-bff4-9a4a704324c9"
    second_payload = String.replace(@payload, "request", "request2")
    second_result = String.replace(@result, "request", "request2")
    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, second_op, second_payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               call,
               second_op,
               second_payload,
               second_result,
               @handle,
               "sender",
               "request2"
             )

    for {id, state, request} <- [{51, "expired", "request"}, {52, "superseded", "request2"}] do
      line =
        event(id, "terminal", state, request)
        |> JSON.decode!()
        |> put_in(["entry", "author"], "server")
        |> put_in(["entry", "terminal_state"], state)
        |> JSON.encode!()

      assert :ok = HarklightWakes.capture_line(db, @handle, line)
      assert :ok = HarklightWakes.capture_line(db, @handle, line)
    end

    origin_line =
      event(53, "terminal", "not an inbound terminal")
      |> JSON.decode!()
      |> put_in(["entry", "author"], "origin")
      |> JSON.encode!()

    assert {:error, "event_identity_invalid"} =
             HarklightWakes.capture_line(db, @handle, origin_line)

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId LIKE 'w_harklight_%'")

    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      :ok = GenServer.call(manager, {:finished, handle, :complete})
      send(test_pid, :listener_completed)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive :listener_completed
    assert %{state: "complete"} = HarklightWakes.register(db, call)

    assert {:ok, [["complete"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
  end

  test "a stopped listener leaves the handle durable and notifies its owner", %{
    db: db,
    call: call,
    session: session
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      :ok = GenServer.call(manager, {:finished, handle, "listener_stopped"})
      send(test_pid, :listener_failed)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener, outage_notice_delay_ms: 0})
    assert_receive :listener_failed
    origin_key = session.session_key

    assert eventually(fn ->
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ]) == {:ok, [["unavailable", "listener_stopped"]]} and
               match?(
                 {:ok, [[@handle, _, _, id]]} when is_binary(id),
                 Tightbeam.HarklightListenerOutage.pending(db)
               )
           end)

    assert {:ok, [[^origin_key, prompt]]} =
             DB.query(
               db,
               "SELECT sessionKey,prompt FROM wakes WHERE prompt LIKE 'Harklight listening%'"
             )

    assert String.contains?(prompt, @handle)
  end

  test "Gateway listener restoration preserves the original session delivery route", %{
    db: db,
    call: call,
    session: session,
    main: main
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1",
               [@handle]
             )

    parent = self()

    listener = fn manager, handle, vendor_id ->
      send(parent, {:listener_started, handle, vendor_id})
      :ok = GenServer.call(manager, {:feed_ready, handle})

      :ok =
        GenServer.call(
          manager,
          {:feed_capture, handle, 1,
           [put_in(feed_chat(1, "request", "1"), ["data", "text"], "same-session reply")], :live}
        )

      send(parent, :reply_captured)

      receive do
        :stop -> :ok
      end
    end

    manager =
      start_supervised!(
        {HarklightWakes, db: db, listener: listener, send_runner: lifecycle_runner(db)}
      )

    assert :sys.get_state(manager).workers == %{}

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable',lastError='listener_stopped' WHERE handle=?1",
               [@handle]
             )

    other_call = %{
      call
      | session_key: main.session_key,
        principal: {:session, main.session_key},
        transport_session_key: main.session_key
    }

    assert %{code: "harklight_origin_mismatch", outcome: "refused"} =
             HarklightWakes.restore_listener(db, other_call, @handle)

    assert %{
             command: "listener-restore",
             outcome: "requested",
             listener_state: "restoring",
             handle: @handle,
             session_key: origin_key
           } = HarklightWakes.restore_listener(db, call, @handle)

    assert origin_key == session.session_key
    assert_receive {:listener_started, @handle, _vendor_id}
    assert_receive :reply_captured

    assert {:ok, [[^origin_key, prompt]]} =
             DB.query(
               db,
               """
               SELECT w.sessionKey,w.prompt
               FROM harklight_wake_entries e
               JOIN wakes w ON w.wakeId=e.wakeId
               WHERE e.handle=?1
               """,
               [@handle]
             )

    assert prompt =~ "same-session reply"
  end

  test "Gateway listener restoration follows the conversation's current receiver", %{
    db: db,
    call: call,
    session: session,
    main: main
  } do
    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1",
               [@handle]
             )

    parent = self()

    listener = fn manager, handle, vendor_id ->
      send(parent, {:listener_started, handle, vendor_id})
      :ok = GenServer.call(manager, {:feed_ready, handle})

      receive do
        :stop -> :ok
      end
    end

    manager =
      start_supervised!(
        {HarklightWakes, db: db, listener: listener, send_runner: lifecycle_runner(db)}
      )

    assert :sys.get_state(manager).workers == %{}

    # Custody moved the conversation from its origin session to Main.
    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable',lastError='listener_stopped',currentReceiverSessionKey=?2 WHERE handle=?1",
               [@handle, main.session_key]
             )

    receiver_call = %{
      call
      | session_key: main.session_key,
        principal: {:session, main.session_key},
        transport_session_key: main.session_key
    }

    assert %{code: "harklight_origin_mismatch", outcome: "refused"} =
             HarklightWakes.restore_listener(db, call, @handle)

    refute_receive {:listener_started, @handle, _vendor_id}

    # The origin session then retires; the receiver still owns the conversation.
    assert {:ok, _} =
             DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
               session.session_key
             ])

    assert %{outcome: "refused"} = HarklightWakes.restore_listener(db, call, @handle)

    assert %{
             command: "listener-restore",
             outcome: "requested",
             listener_state: "restoring",
             handle: @handle,
             session_key: receiver_key
           } = HarklightWakes.restore_listener(db, receiver_call, @handle)

    assert receiver_key == main.session_key
    assert_receive {:listener_started, @handle, _vendor_id}
  end

  for saved_error <- ["listener_stopped", "attachment_refused"] do
    @saved_error saved_error
    test "restart restores an existing #{@saved_error} handle without changing captured state", %{
      db: db,
      session: session
    } do
      lines =
        for {cursor, delivered, acted} <- [{1, false, false}, {2, true, false}, {3, true, true}] do
          feed_chat(cursor, "request", Integer.to_string(cursor))
          |> put_in(["data", "delivery"], %{"delivered" => delivered, "acted" => acted})
        end

      assert :ok = HarklightWakes.capture_feed(db, @handle, 3, lines, :baseline)
      {:ok, before_entries} = DB.query(db, "SELECT * FROM harklight_wake_entries")
      {:ok, before_requests} = DB.query(db, "SELECT * FROM harklight_wake_requests")
      {:ok, before_wakes} = DB.query(db, "SELECT * FROM wakes WHERE wakeId LIKE 'w_harklight_%'")
      {:ok, before_results} = DB.query(db, "SELECT * FROM harklight_command_results")
      {:ok, before_sends} = DB.query(db, "SELECT * FROM harklight_send_operations")

      {:ok, _} =
        DB.query(db, "UPDATE harklight_wake_handles SET state='unavailable',lastError=?1", [
          @saved_error
        ])

      parent = self()

      listener = fn manager, handle, vendor ->
        :ok = GenServer.call(manager, {:feed_ready, handle})
        :ok = GenServer.call(manager, {:feed_capture, handle, 3, lines, :baseline})
        send(parent, {:restored, self(), handle, vendor})

        receive do
          :never -> :ok
        end
      end

      start_supervised!({HarklightWakes, db: db, listener: listener})
      assert_receive {:restored, worker, @handle, nil}
      ref = Process.monitor(worker)
      :ok = stop_supervised(HarklightWakes)
      assert_receive {:DOWN, ^ref, :process, ^worker, :shutdown}
      start_supervised!({HarklightWakes, db: db, listener: listener})
      assert_receive {:restored, next, @handle, nil}
      refute next == worker
      assert {:ok, ^before_entries} = DB.query(db, "SELECT * FROM harklight_wake_entries")
      assert {:ok, ^before_requests} = DB.query(db, "SELECT * FROM harklight_wake_requests")

      assert {:ok, ^before_wakes} =
               DB.query(db, "SELECT * FROM wakes WHERE wakeId LIKE 'w_harklight_%'")

      assert {:ok, ^before_results} = DB.query(db, "SELECT * FROM harklight_command_results")
      assert {:ok, ^before_sends} = DB.query(db, "SELECT * FROM harklight_send_operations")
      origin = session.session_key

      assert {:ok, [[^origin, "active", nil, 3]]} =
               DB.query(
                 db,
                 "SELECT sessionKey,state,lastError,lastCursor FROM harklight_wake_handles"
               )

      assert {:ok, [[3]]} =
               DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId LIKE 'w_harklight_%'")
    end
  end

  test "failed restoration refreshes the actual reason and notifies the origin once", %{
    db: db,
    session: session
  } do
    {:ok, _} =
      DB.query(
        db,
        "UPDATE harklight_wake_handles SET state='unavailable',lastError='listener_stopped'"
      )

    parent = self()

    listener = fn manager, handle, _ ->
      :ok =
        GenServer.call(
          manager,
          {:finished, handle,
           {:harklight_failure, {"listener_stopped", "forbidden"}, "listen",
            ["The filtered feed refused access."]}}
        )

      send(parent, :refused)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive :refused
    :ok = stop_supervised(HarklightWakes)
    start_supervised!({HarklightWakes, db: db, listener: listener})
    refute_receive :refused, 100

    assert {:ok, [["unavailable", reason]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")

    assert reason =~ "forbidden"
    assert reason =~ "filtered feed refused access"
    origin = session.session_key

    assert {:ok, [[^origin, prompt]]} =
             DB.query(
               db,
               "SELECT sessionKey,prompt FROM wakes WHERE wakeId LIKE 'w_harklight_notice_%'"
             )

    assert prompt =~ "filtered feed refused access"
    assert prompt =~ "Replies on this thread will not reach"
  end

  test "startup restores each filtered feed with its own checkpoint", %{db: db, session: session} do
    resumed = Tightbeam.Id.uuid4()
    seed_completion_handle(db, session.session_key, resumed, "pending-sibling")

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable',lastError='listener_stopped'"
             )

    assert {:ok, _} =
             DB.query(db, "INSERT INTO harklight_feed_checkpoints(handle,rev) VALUES(?1,25)", [
               resumed
             ])

    log = Path.join(System.tmp_dir!(), "harklight-restore-#{Tightbeam.Id.uuid4()}")
    on_exit(fn -> Enum.each([log, log <> ".failed"], &File.rm/1) end)

    fake_harklight_agent!("""
    printf '%s\n' "$*" >> '#{log}'
    case "$*" in
      'listen --follow --session #{@handle} --snapshot')
        printf '%s\n' '{"kind":"baseline","rev":8,"reason":"first_contact"}'
        printf '%s\n' '{"kind":"baseline_complete","rev":8}' '{"kind":"caught_up","rev":8}'
        ;;
      'listen --follow --session #{resumed} --after 25')
        if [ ! -e '#{log}.failed' ]; then
          touch '#{log}.failed'
          printf '%s\n' 'server request via configured address localhost failed: connection lost' >&2
          exit 1
        fi
        printf '%s\n' '{"kind":"caught_up","rev":26}'
        ;;
      *) exit 2 ;;
    esac
    exec sleep 30
    """)

    start_supervised!({HarklightWakes, db: db, retry_delays: [100]})

    assert eventually(fn ->
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_handles WHERE state='active' AND lastError IS NULL"
             ) == {:ok, [[2]]} and
               DB.query(db, "SELECT rev FROM harklight_feed_checkpoints ORDER BY rev") ==
                 {:ok, [[8], [26]]}
           end)

    assert Enum.sort(File.read!(log) |> String.split("\n", trim: true)) ==
             Enum.sort([
               "listen --follow --session #{@handle} --snapshot",
               "listen --follow --session #{resumed} --after 25",
               "listen --follow --session #{resumed} --after 25"
             ])
  end

  test "startup records an ineligible origin without launching a listener", %{
    db: db,
    session: session
  } do
    Org.set_host(db, session.session_key, "other-host")
    parent = self()
    listener = fn _, _, _ -> send(parent, :unexpected_listener) end
    start_supervised!({HarklightWakes, db: db, listener: listener})
    :sys.get_state(HarklightWakes)

    assert eventually(fn ->
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles") ==
               {:ok, [["unavailable", "origin_unavailable"]]}
           end)

    refute_receive :unexpected_listener
  end

  test "feed manager shutdown releases its own idle subprocess before restoring", %{db: db} do
    root = Path.join(System.tmp_dir!(), "harklight-child-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    script = Path.join(root, "harklight-agent")

    File.write!(script, """
    #!/bin/sh
    printf '%s\n' "$*" >> "$0.calls"
    printf '%s\n' "$$" > "$0.pid"
    exec sleep 300
    """)

    File.chmod!(script, 0o700)
    old_path = System.fetch_env!("PATH")
    System.put_env("PATH", root <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(root)
    end)

    start_supervised!({HarklightWakes, db: db})
    listen_call = "listen --follow --session #{@handle} --snapshot"

    assert eventually(fn ->
             File.exists?(script <> ".pid") and File.read!(script <> ".pid") != "" and
               File.exists?(script <> ".calls") and File.read!(script <> ".calls") =~ listen_call
           end)

    port = await_listener_port()
    {:os_pid, pid} = Port.info(port, :os_pid)

    child_pid = File.read!(script <> ".pid") |> String.trim()

    calls = File.read!(script <> ".calls")
    assert calls =~ listen_call

    assert {_, 0} =
             System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    assert {_, 0} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)

    :ok = stop_supervised(HarklightWakes)

    # Port.close requests cleanup; the wrapper kills and reaps its child
    # asynchronously. Observe both exits before restoring the controller.
    assert eventually(fn ->
             Enum.all?([Integer.to_string(pid), child_pid], fn os_pid ->
               {_, status} = System.cmd("/bin/kill", ["-0", os_pid], stderr_to_stdout: true)
               status != 0
             end)
           end)

    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             File.read!(script <> ".calls")
             |> String.split("\n", trim: true)
             |> Enum.count(&(&1 == listen_call)) == 2
           end)

    new_port = await_listener_port()
    refute new_port == port
  end

  for {kind, exit_code, diagnostic, table, reason} <- [
        {:pause, 1,
         ~s|listen: live updates paused: internal_error (Request-Id Some("rotation-request"))|,
         "harklight_feed_pauses", "rotation-request"},
        {:refusal, 2, ~s|server returned HTTP 403: Some("forbidden") (request ID None)|,
         "harklight_feed_stops", "feed_refused"},
        {:unfinished_baseline, 0, ~s|{"kind":"baseline","rev":9}|, "harklight_feed_pauses",
         "feed_custody_uncertain"}
      ] do
    @drain_exit exit_code
    @drain_diagnostic diagnostic
    @drain_table table
    @drain_reason reason

    test "listener rotation accounts for an overlapping #{kind}", %{db: db} do
      :ok = HarklightWakes.capture_feed(db, @handle, 8, [], :live)

      fake_harklight_agent!("""
      printf '%s\n' "$*" >> "$0.calls"
      printf '%s\n' '{"kind":"caught_up","rev":8}'
      if [ -e "$0.resume" ]; then exec sleep 30; fi
      while [ ! -e "$0.fail" ]; do sleep 0.02; done
      printf '%s\n' '#{@drain_diagnostic}' >&2
      if [ '#{@drain_exit}' = '0' ]; then exec sleep 30; fi
      exit #{@drain_exit}
      """)

      agent = System.find_executable("harklight-agent")
      manager = start_supervised!({HarklightWakes, db: db, retry_delays: [1]})
      port = await_listener_port()
      assert eventually(fn -> MapSet.size(:sys.get_state(manager).starts_in_flight) == 0 end)
      worker = :sys.get_state(manager).workers[@handle]
      send(manager, {:feed_result, worker, "stale-launch", :clean})
      :sys.get_state(manager)
      assert {:ok, [[@handle]]} = DB.query(db, "SELECT handle FROM harklight_feed_launches")
      true = :erlang.suspend_process(worker)

      try do
        HarklightWakes.activate(@handle, true)

        assert eventually(fn ->
                 {:messages, messages} = Process.info(worker, :messages)
                 Enum.any?(messages, &match?({:close_feed, ^manager, _, _}, &1))
               end)

        File.touch!(agent <> ".fail")

        assert eventually(fn ->
                 {:messages, messages} = Process.info(worker, :messages)

                 if @drain_exit == 0 do
                   Enum.any?(messages, fn
                     {^port, {:data, bytes}} -> bytes =~ ~s("kind":"baseline")
                     _ -> false
                   end)
                 else
                   Enum.any?(messages, &match?({^port, {:exit_status, @drain_exit}}, &1))
                 end
               end)
      after
        :erlang.resume_process(worker)
      end

      assert eventually(fn ->
               DB.query(db, "SELECT handle FROM #{@drain_table}") == {:ok, [[@handle]]}
             end)

      assert {:ok, [[8]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")
      assert {:ok, [[diagnostic]]} = DB.query(db, "SELECT lastError FROM harklight_wake_handles")
      assert diagnostic =~ @drain_reason
      held = if @drain_exit == 0, do: [[@handle]], else: []
      assert {:ok, ^held} = DB.query(db, "SELECT handle FROM harklight_feed_launches")

      expected = "listen --follow --session #{@handle} --after 8"
      File.touch!(agent <> ".resume")
      HarklightWakes.activate(@handle, true)

      refute eventually(
               fn ->
                 File.read!(agent <> ".calls") |> String.split("\n", trim: true) != [expected]
               end,
               35
             )

      assert %{counts: %{listening: 1}} =
               HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

      assert File.read!(agent <> ".calls") |> String.split("\n", trim: true) == [
               expected,
               expected
             ]
    end
  end

  for {outcome, diagnostic, table, reason} <- [
        {:not_found,
         ~s|server returned HTTP 404: Some("not_found") (request ID Some("masked-request"))|,
         "harklight_feed_stops", "not_found"},
        {:closed, "agent feed closed: session_ended", "harklight_feed_stops", "session_ended"},
        {:ambiguous, "unclassified final diagnostic", "harklight_feed_pauses",
         "feed_custody_uncertain"}
      ] do
    @masked_outcome outcome
    @masked_diagnostic diagnostic
    @masked_table table
    @masked_reason reason

    test "rotation retains #{@masked_outcome} evidence read before the wrapper stops the child",
         %{db: db} do
      :ok = HarklightWakes.capture_feed(db, @handle, 8, [], :live)

      fake_harklight_agent!("""
      printf '%s\n' "$*" >> "$0.calls"
      printf '%s\n' '{"kind":"caught_up","rev":8}'
      if [ -e "$0.resume" ]; then exec sleep 30; fi
      while [ ! -e "$0.fail" ]; do sleep 0.02; done
      printf '%s\n' '#{@masked_diagnostic}' >&2
      exec sleep 30
      """)

      agent = System.find_executable("harklight-agent")
      manager = start_supervised!({HarklightWakes, db: db, retry_delays: [1]})
      port = await_listener_port()
      assert eventually(fn -> MapSet.size(:sys.get_state(manager).starts_in_flight) == 0 end)
      state = :sys.get_state(manager)
      worker = state.workers[@handle]
      token = state.launch_owners[@handle]
      1 = :erlang.trace(worker, true, [:receive])

      File.touch!(agent <> ".fail")
      assert_receive {:trace, ^worker, :receive, {^port, {:data, diagnostic}}}, 1_000
      assert diagnostic =~ @masked_diagnostic

      HarklightWakes.activate(@handle, true)
      assert_receive {:trace, ^worker, :receive, {^port, {:exit_status, 0}}}, 2_000

      assert eventually(fn ->
               DB.query(db, "SELECT handle FROM #{@masked_table}") == {:ok, [[@handle]]}
             end)

      assert {:ok, [[diagnostic]]} = DB.query(db, "SELECT lastError FROM harklight_wake_handles")
      assert diagnostic =~ @masked_reason
      held = if @masked_outcome == :ambiguous, do: [[token]], else: []
      assert {:ok, ^held} = DB.query(db, "SELECT owner FROM harklight_feed_launches")
      assert {:ok, [[8]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")

      expected = "listen --follow --session #{@handle} --after 8"
      File.touch!(agent <> ".resume")
      HarklightWakes.activate(@handle, true)

      refute eventually(
               fn ->
                 String.split(File.read!(agent <> ".calls"), "\n", trim: true) != [expected]
               end,
               35
             )

      assert %{counts: %{listening: 1}} =
               HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

      assert String.split(File.read!(agent <> ".calls"), "\n", trim: true) == [expected, expected]
    end
  end

  defp await_listener_port(attempts \\ 100)
  defp await_listener_port(0), do: flunk("listener port did not start")

  defp await_listener_port(attempts) do
    port = :sys.get_state(HarklightWakes).ports[@handle]

    if is_port(port) and Port.info(port) != nil do
      port
    else
      Process.sleep(10)
      await_listener_port(attempts - 1)
    end
  end

  if System.get_env("HARKLIGHT_ACCEPTANCE_BINARY") do
    test "published Agent reports missing configuration as a feed failure", %{db: db} do
      # The isolated gate supplies the hash-verified published binary. Ordinary
      # runs use the existing source-level controller tests.
      binary = System.fetch_env!("HARKLIGHT_ACCEPTANCE_BINARY")

      root =
        Path.join(System.tmp_dir!(), "harklight-restart-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      script = Path.join(root, "harklight-agent")

      File.write!(
        script,
        "#!/bin/sh\nexec '" <>
          binary <>
          "' --identity-dir '" <> root <> "/missing' --state-dir '" <> root <> "/state' \"$@\"\n"
      )

      File.chmod!(script, 0o700)
      old_path = System.fetch_env!("PATH")
      System.put_env("PATH", root <> ":" <> old_path)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(root)
      end)

      start_supervised!({HarklightWakes, db: db})
      await_handle_error(db, "exit status: 1")

      assert {:ok, [["unavailable", error]]} =
               DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")

      assert error =~ "listener_stopped"
      assert error =~ "exit status: 1"
    end
  end

  defp handle_failed_with?(db, label) do
    case DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
           @handle
         ]) do
      {:ok, [["unavailable", error]]} when is_binary(error) ->
        error == label or String.starts_with?(error, label <> ": ")

      _ ->
        false
    end
  end

  defp await_handle_error(db, text, attempts \\ 100)
  defp await_handle_error(_db, _text, 0), do: flunk("controller did not record the failure")

  defp await_handle_error(db, text, attempts) do
    case DB.query(db, "SELECT lastError FROM harklight_wake_handles") do
      {:ok, [[error]]} when is_binary(error) ->
        if String.contains?(error, text),
          do: :ok,
          else: await_handle_error(db, text, attempts - 1)

      _ ->
        Process.sleep(10)
        await_handle_error(db, text, attempts - 1)
    end
  end

  test "a refused feed startup retains the CLI reason without its secret", %{db: db, call: call} do
    fake_harklight_agent!("""
    if [ "$1" = "listen" ]; then
      printf '%s\n' 'feed refused: token=feed-secret-canary' >&2
      exit 2
    fi
    exit 1
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn -> handle_failed_with?(db, "listener_stopped") end)

    assert {:ok, [[prompt]]} =
             DB.query(db, "SELECT prompt FROM wakes WHERE wakeId=?1", [
               "w_harklight_notice_recovery_" <> @handle
             ])

    assert prompt =~ "LISTEN failure:"
    assert prompt =~ "feed refused"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "feed-secret-canary"
  end

  test "structured refusal output keeps only its safe reason field" do
    refusal =
      JSON.encode!(%{
        kind: "unsupported",
        reason: "route unavailable token=structured-secret-canary",
        payload: "structured-payload-canary"
      })

    assert "route unavailable token=[REDACTED:secret_field]" ==
             HarklightWakes.sanitize_refusal_output(refusal)

    assert is_nil(
             HarklightWakes.sanitize_refusal_output(
               JSON.encode!(%{kind: "event", entry: %{content: "event-payload-canary"}})
             )
           )
  end

  test "invalid bytes in refusal output do not change its failure classification", %{
    db: db,
    call: call
  } do
    fake_harklight_agent!("""
    if [ "$1" = "listen" ]; then
      printf 'origin refused \\377 token=invalid-byte-secret-canary\\n' >&2
      exit 17
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db, outage_notice_delay_ms: 0})

    assert eventually(fn ->
             handle_failed_with?(db, "listener_stopped")
           end)

    assert eventually(fn ->
             match?(
               {:ok, [[@handle, _, _, id]]} when is_binary(id),
               Tightbeam.HarklightListenerOutage.pending(db)
             )
           end)

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert String.valid?(prompt)
    assert prompt =~ "LISTEN attempt; exit status: 17"
    assert prompt =~ "origin refused"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "invalid-byte-secret-canary"
  end

  test "listen stderr is reported without exposing captured event payloads", %{db: db, call: call} do
    event_line = v2_chat_line(1, "listen-payload-canary")

    fake_harklight_agent!("""
    if [ "$1" = "listen" ]; then
      printf '%s\\n' 'origin stream refused: token=listen-secret-canary' >&2
      printf '%s\\n' '#{event_line}'
      exit 9
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db, outage_notice_delay_ms: 0})

    assert eventually(fn ->
             handle_failed_with?(db, "listener_stopped")
           end)

    assert eventually(fn ->
             match?(
               {:ok, [[@handle, _, _, id]]} when is_binary(id),
               Tightbeam.HarklightListenerOutage.pending(db)
             )
           end)

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_entries WHERE handle=?1", [
               @handle
             ])

    assert prompt =~ "failure:"
    assert prompt =~ "LISTEN failure:"
    assert prompt =~ "LISTEN attempt; exit status: 9"
    assert prompt =~ "origin stream refused"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "listen-secret-canary"
    refute prompt =~ "listen-payload-canary"
  end

  test "a follow listener remains active through reconnect diagnostics and captures the resumed reply",
       %{db: db, call: call} do
    nonce = Tightbeam.Id.uuid4()
    started = Path.join(System.tmp_dir!(), "harklight-reconnect-#{nonce}.started")
    resume = Path.join(System.tmp_dir!(), "harklight-reconnect-#{nonce}.resume")
    event_line = v2_chat_line(1, "reply after server restart")

    on_exit(fn ->
      File.rm(started)
      File.rm(resume)
    end)

    fake_harklight_agent!("""
    if [ "$1" = "listen" ]; then
      printf '%s\\n' 'Harklight origin stream unavailable; retrying after disconnect' >&2
      printf '%s\n' '{"kind":"caught_up","rev":0}'
      touch '#{started}'
      while [ ! -e '#{resume}' ]; do sleep 0.01; done
      printf '%s\\n' '#{event_line}'
      exec sleep 600
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn -> File.exists?(started) end)

    assert {:ok, [["active", nil]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId=?1", [
               "w_harklight_notice_recovery_" <> @handle
             ])

    File.write!(resume, "server returned")

    assert eventually(fn ->
             DB.query(db, "SELECT count(*) FROM harklight_wake_entries WHERE handle=?1", [
               @handle
             ]) == {:ok, [[1]]}
           end)

    assert {:ok, [["active", nil]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT w.prompt FROM harklight_wake_entries e JOIN wakes w ON w.wakeId=e.wakeId WHERE e.handle=?1 LIMIT 1",
               [@handle]
             )

    assert prompt =~ "reply after server restart"
  end

  test "a final unterminated listen refusal remains in the failure details", %{
    db: db,
    call: call
  } do
    fake_harklight_agent!("""
    if [ "$1" = "listen" ]; then
      printf '%s\\n' 'https://diagnostic.example/path Harklight origin stream unavailable; retrying after disconnect: prior cursor was accepted but no next event followed because the origin stream remained closed' >&2
      printf '%s\\n' 'Harklight origin stream unavailable; retrying after disconnect: message=the original event remains unavailable while the source continues trying to reconnect' >&2
      printf '%s' 'final refusal token=unterminated-secret-canary' >&2
      exit 19
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!({HarklightWakes, db: db, outage_notice_delay_ms: 0})

        assert eventually(fn ->
                 handle_failed_with?(db, "listener_stopped")
               end)
      end)

    assert eventually(fn ->
             match?(
               {:ok, [[@handle, _, _, id]]} when is_binary(id),
               Tightbeam.HarklightListenerOutage.pending(db)
             )
           end)

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert prompt =~ "LISTEN attempt; exit status: 19"
    assert prompt =~ "Harklight origin stream unavailable; retrying after disconnect"
    assert prompt =~ "[REDACTED:url]"
    assert prompt =~ "message=[REDACTED:content]"
    assert prompt =~ "final refusal"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "unterminated-secret-canary"
    assert log =~ "final refusal"
    assert log =~ "[REDACTED:url]"
    assert log =~ "message=[REDACTED:content]"
    refute log =~ "unterminated-secret-canary"
  end

  test "invalid bytes in a structured event preserve the listener parse failure", %{
    db: db,
    call: call
  } do
    event_line = event(1, "discussion", "invalid-byte-event-canary")

    event_line =
      :binary.replace(
        event_line,
        "invalid-byte-event-canary",
        "bad" <> <<255>> <> "event-payload"
      )

    printf_format =
      event_line
      |> :binary.bin_to_list()
      |> Enum.map_join(fn byte -> "\\" <> Integer.to_string(byte, 8) end)

    fake_harklight_agent!("""
    if [ "$1" = "listen" ]; then
      printf '#{printf_format}\\n'
      exit 0
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             handle_failed_with?(db, "invalid_listener_line")
           end)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_entries WHERE handle=?1", [
               @handle
             ])

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    refute prompt =~ "invalid-byte-event-canary"
    refute prompt =~ "event-payload"
  end

  test "a failed attempt on an unavailable handle is logged without another owner wake", %{
    db: db,
    call: call
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    test_pid = self()

    initial_listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      :ok = GenServer.call(manager, {:finished, handle, "listener_stopped"})
      send(test_pid, :initial_failure_recorded)
    end

    start_supervised!(
      {HarklightWakes, db: db, listener: initial_listener, outage_notice_delay_ms: 0}
    )

    assert_receive :initial_failure_recorded

    assert eventually(fn ->
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId=?1", [
               "w_harklight_notice_recovery_" <> @handle
             ]) == {:ok, [[1]]}
           end)

    stop_supervised!(HarklightWakes)

    retry_listener = fn manager, handle, _vendor_id ->
      :ok =
        GenServer.call(
          manager,
          {
            :finished,
            handle,
            {:harklight_failure, "listener_stopped", "listen",
             "LISTEN restore attempt; exit status: 23; sanitized output: retry refused token=repeat-secret-canary"}
          },
          :infinity
        )

      send(test_pid, :restored_failure_recorded)
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!({HarklightWakes, db: db, listener: retry_listener})
        assert_receive :restored_failure_recorded, 2_000
        Process.sleep(20)
      end)

    assert log =~ "Harklight listener failure"
    assert log =~ "LISTEN restore attempt; exit status: 23"
    assert log =~ "retry refused"
    assert log =~ "[REDACTED:secret_field]"
    refute log =~ "repeat-secret-canary"

    assert {:ok, [["unavailable", error]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    assert error =~ "listener_stopped: LISTEN restore attempt; exit status: 23"
    assert error =~ "retry refused"
    refute error =~ "repeat-secret-canary"

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )
  end

  test "an unavailable listen Port records a redacted launch failure", %{db: db, call: call} do
    fake_harklight_agent!("exit 2")

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    missing = Path.join(System.tmp_dir!(), Tightbeam.Id.uuid4())

    start_supervised!(
      {HarklightWakes, db: db, child_opts: [cli_path: missing], outage_notice_delay_ms: 0}
    )

    assert eventually(fn ->
             handle_failed_with?(db, "listener_failed") and
               match?(
                 {:ok, [[@handle, _, _, id]]} when is_binary(id),
                 Tightbeam.HarklightListenerOutage.pending(db)
               )
           end)

    assert {:ok, [[prompt]]} =
             DB.query(db, "SELECT prompt FROM wakes WHERE wakeId=?1", [
               "w_harklight_notice_recovery_" <> @handle
             ])

    assert prompt =~ "LISTEN failure:"
    assert prompt =~ "[REDACTED:structured output]"
  end

  test "retirement and host movement fence new captures without losing old wakes", %{
    db: db,
    call: call,
    session: session
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "first"))

    Org.set_host(db, session.session_key, "another-host")

    assert {:error, "harklight_origin_unavailable"} =
             HarklightWakes.capture_line(db, @handle, event(2, "discussion", "later"))

    Org.set_host(db, session.session_key, Placement.local_host_name())

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        Org.personal_session_key("owner")
      ])

    Org.retire(db, session.session_key, "user:owner", 60_000)
    session_key = session.session_key

    assert {:error, "harklight_origin_unavailable"} =
             HarklightWakes.capture_line(db, @handle, event(2, "discussion", "later"))

    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

    assert {:ok, [[^session_key, "pending"]]} =
             DB.query(db, "SELECT sessionKey,state FROM wakes WHERE wakeId LIKE ?1", [
               "w_harklight_" <> @handle <> "_%"
             ])
  end

  test "deliberate retirement marks a handle gone when no receiver remains", %{
    db: db,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, {:listener_running, self()})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listener_running, worker}

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        Org.personal_session_key("owner")
      ])

    retired = Org.retire(db, session.session_key, "user:owner", 60_000)
    assert retired.state == "retired"
    :sys.get_state(HarklightWakes)

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle}\n"}
           end)

    assert {:ok, [["unavailable", "origin_unavailable"]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    refute Process.alive?(worker)
  end

  test "an ephemeral last actual follow receiver retires after the origin", %{
    db: db,
    call: call,
    main: main,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
    follower = follower_session(db, main, "agent:follower:retirement")

    assert {:ok, _} =
             DB.transaction(
               db,
               &Ephemeral.stamp_in_txn(&1, follower.session_key, main.session_key)
             )

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, {:listener_running, self()})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listener_running, worker}

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        Org.personal_session_key("owner")
      ])

    retired = Org.retire(db, session.session_key, "user:owner", 60_000)
    assert retired.state == "retired"
    :sys.get_state(HarklightWakes)

    assert Process.alive?(worker)

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "After retirement"))

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [follower.session_key])

    refute File.exists?(calls)

    assert {:ok, :ok} =
             DB.transaction(db, &Ephemeral.retire_in_txn(&1, follower.session_key))

    assert Org.get(db, follower.session_key).state == "retired"

    assert {:ok, [["retired", "open"]]} =
             DB.query(
               db,
               """
               SELECT s.state,f.state
               FROM sessions s JOIN harklight_wake_follows f ON f.sessionKey=s.sessionKey
               WHERE f.handle=?1 AND f.sessionKey=?2
               """,
               [@handle, follower.session_key]
             )

    :sys.get_state(HarklightWakes)

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle}\n"}
           end)

    assert {:ok, [["unavailable", "origin_unavailable"]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    assert eventually(fn -> not Process.alive?(worker) end)
  end

  test "queued retirement handoffs mark gone once for the last actual receiver", %{
    db: db,
    call: call,
    main: main,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
    follower = follower_session(db, main, "agent:follower:queued-retirement")

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, {:listener_running, self()})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listener_running, worker}

    :sys.suspend(HarklightWakes)

    try do
      {:ok, _} =
        DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
          Org.personal_session_key("owner")
        ])

      assert %{state: "retired"} = Org.retire(db, session.session_key, "user:owner", 60_000)
      assert %{state: "retired"} = Org.retire(db, follower.session_key, "user:owner", 60_000)
    after
      :sys.resume(HarklightWakes)
    end

    :sys.get_state(HarklightWakes)

    assert {:ok, [["retired", "open"]]} =
             DB.query(
               db,
               """
               SELECT s.state,f.state
               FROM sessions s JOIN harklight_wake_follows f ON f.sessionKey=s.sessionKey
               WHERE f.handle=?1 AND f.sessionKey=?2
               """,
               [@handle, follower.session_key]
             )

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle}\n"}
           end)

    Process.sleep(50)
    assert File.read(calls) == {:ok, "session end --session #{@handle}\n"}
    assert eventually(fn -> not Process.alive?(worker) end)
  end

  test "a live origin remains eligible after its follower retires", %{
    db: db,
    call: call,
    main: main,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
    follower = follower_session(db, main, "agent:follower:origin-live")

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, {:listener_running, self()})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listener_running, worker}

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        Org.personal_session_key("owner")
      ])

    retired_follower = Org.retire(db, follower.session_key, "user:owner", 60_000)
    assert retired_follower.state == "retired"
    :sys.get_state(HarklightWakes)

    assert Process.alive?(worker)

    assert {:ok, [["active", "retired", "open"]]} =
             DB.query(
               db,
               """
               SELECT h.state,s.state,f.state
               FROM harklight_wake_handles h
               JOIN harklight_wake_follows f ON f.handle=h.handle
               JOIN sessions s ON s.sessionKey=f.sessionKey
               WHERE h.handle=?1 AND f.sessionKey=?2
               """,
               [@handle, follower.session_key]
             )

    refute File.exists?(calls)

    retired_origin = Org.retire(db, session.session_key, "user:owner", 60_000)
    assert retired_origin.state == "retired"
    :sys.get_state(HarklightWakes)

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle}\n"}
           end)

    assert eventually(fn -> not Process.alive?(worker) end)
  end

  # Listener start first reads Harklight status through the Agent CLI, which
  # HarklightLifecycle bounds with a 5s read deadline, and starts the listener
  # on whatever that read yields. The start can therefore legitimately take as
  # long as that deadline plus the read task's shutdown grace; ExUnit's default
  # 1s assert_receive window is below the product's own bound. Wait for the
  # event itself and bound only a hang, using twice the product deadline.
  @listener_start_bound_ms 10_000

  test "another active follow receiver keeps a retired origin not-gone", %{
    db: db,
    call: call,
    main: main,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
    first_follower = follower_session(db, main, "agent:follower:first")
    last_follower = follower_session(db, main, "agent:follower:last")

    for follower <- [first_follower, last_follower] do
      assert %{outcome: "committed"} =
               follow_for_test(
                 db,
                 follow_call(call, follower, %{message_id: "request"}),
                 runner: lifecycle_runner(db)
               )
    end

    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, {:listener_running, self()})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listener_running, worker}, @listener_start_bound_ms
    worker_down = Process.monitor(worker)

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        Org.personal_session_key("owner")
      ])

    retired_origin = Org.retire(db, session.session_key, "user:owner", 60_000)
    assert retired_origin.state == "retired"
    :sys.get_state(HarklightWakes)
    assert Process.alive?(worker)
    refute File.exists?(calls)

    retired_first = Org.retire(db, first_follower.session_key, "user:owner", 60_000)
    assert retired_first.state == "retired"
    :sys.get_state(HarklightWakes)
    assert Process.alive?(worker)

    assert {:ok, [["retired", "open"], ["active", "open"]]} =
             DB.query(
               db,
               """
               SELECT s.state,f.state
               FROM sessions s JOIN harklight_wake_follows f ON f.sessionKey=s.sessionKey
               WHERE f.handle=?1 ORDER BY f.sessionKey
               """,
               [@handle]
             )

    refute File.exists?(calls)

    retired_last = Org.retire(db, last_follower.session_key, "user:owner", 60_000)
    assert retired_last.state == "retired"
    :sys.get_state(HarklightWakes)

    # The gone call is a subprocess started outside the manager, so its output
    # file is the only observation of it; poll that against the same bound
    # rather than eventually/1's default 2s window.
    assert eventually(
             fn -> File.read(calls) == {:ok, "session end --session #{@handle}\n"} end,
             div(@listener_start_bound_ms, 10)
           )

    assert_receive {:DOWN, ^worker_down, :process, ^worker, _reason}, @listener_start_bound_ms
  end

  test "a first failed snapshot does not end the remote session", %{db: db} do
    calls = fake_harklight_session_end_agent!()
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             match?(
               {:ok, [["unavailable", _]]},
               DB.query(
                 db,
                 "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1",
                 [
                   @handle
                 ]
               )
             )
           end)

    output = File.read!(calls)
    assert output =~ "listen --follow --session #{@handle} --snapshot"
    refute output =~ "session end"
  end

  test "an interrupted filtered feed resumes within its budget without duplicate wakes", %{
    db: db,
    session: session
  } do
    calls = Path.join(System.tmp_dir!(), "running-outage-#{System.unique_integer([:positive])}")
    listen_count = calls <> ".listen"
    release = calls <> ".release"
    File.write!(calls, "")

    on_exit(fn ->
      Enum.each([calls, listen_count, release], &File.rm/1)
    end)

    handled = v2_chat_line(1, "captured before the outage")
    in_gap = v2_chat_line(2, "received during the outage")

    fake_harklight_agent!("""
    printf '%s\\n' "$*" >> '#{calls}'
    if [ "$1" = listen ]; then
      if [ -f '#{listen_count}' ]; then listen_attempt=$(cat '#{listen_count}'); else listen_attempt=0; fi
      listen_attempt=$((listen_attempt + 1))
      printf '%s\\n' "$listen_attempt" > '#{listen_count}'
      if [ "$listen_attempt" = 1 ]; then
        printf '%s\\n' '#{handled}'
        printf '%s\\n' 'server request via configured address localhost failed: connection lost' >&2
        exit 1
      fi
      printf '%s\\n' '#{handled}'
      printf '%s\\n' '#{in_gap}'
      printf '%s\\n' '#{in_gap}'
      printf '%s\\n' '{"kind":"caught_up","rev":2}'
      while [ ! -e '#{release}' ]; do sleep 0.01; done
      exit 0
    fi
    exit 2
    """)

    start_supervised!({HarklightWakes, db: db, retry_delays: [10, 20]})

    assert eventually(fn ->
             match?(
               {:ok, [[_wake_id]]},
               DB.query(
                 db,
                 "SELECT wakeId FROM harklight_wake_entries WHERE json_extract(rawLine, '$.data.entry_id')='entry-1'"
               )
             )
           end)

    assert {:ok, [[handled_wake]]} =
             DB.query(
               db,
               "SELECT wakeId FROM harklight_wake_entries WHERE json_extract(rawLine, '$.data.entry_id')='entry-1'"
             )

    turn = deliver_discussion_turn!(db, handled_wake, session.session_key)
    assert turn.prompt =~ "captured before the outage"

    assert eventually(fn ->
             match?(
               {:ok, [[_wake_id]]},
               DB.query(
                 db,
                 "SELECT wakeId FROM harklight_wake_entries WHERE json_extract(rawLine, '$.data.entry_id')='entry-2'"
               )
             ) and
               match?(
                 {:ok, [["active", nil]]},
                 DB.query(
                   db,
                   "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1",
                   [@handle]
                 )
               )
           end)

    assert {:ok, [["entry-1", 1], ["entry-2", 1]]} =
             DB.query(
               db,
               "SELECT json_extract(rawLine, '$.data.entry_id'),count(*) FROM harklight_wake_entries GROUP BY 1 ORDER BY 1"
             )

    assert {:ok, [[2]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId LIKE ?1",
               ["w_harklight_" <> @handle <> "_%"]
             )

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId=?1", [
               "w_harklight_notice_recovery_" <> @handle
             ])

    commands = File.read!(calls) |> String.split("\n", trim: true)

    assert commands == [
             "listen --follow --session #{@handle} --snapshot",
             "listen --follow --session #{@handle} --after 1"
           ]
  end

  test "a retryable running-gateway failure notifies only after bounded recovery is exhausted",
       %{db: db} do
    gone_calls = fake_harklight_session_end_agent!()
    File.write!(gone_calls, "")
    parent = self()
    failures = :atomics.new(1, [])

    failure =
      {:harklight_failure, {"listener_stopped", "transport_error"}, "listen",
       ["origin request failed: simulated outage"]}

    listener = fn manager, handle, _vendor_id ->
      attempt = :atomics.add_get(failures, 1, 1)
      :ok = GenServer.call(manager, {:finished, handle, failure})
      send(parent, {:retryable_failure, attempt, self()})
      receive do: (:exit_worker -> :ok)
    end

    start_supervised!(
      {HarklightWakes, db: db, listener: listener, retry_delays: [20], sustain_retries: false}
    )

    assert_receive {:retryable_failure, 1, first_worker}, 1_000

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId=?1", [
               "w_harklight_notice_recovery_" <> @handle
             ])

    send(first_worker, :exit_worker)
    assert_receive {:retryable_failure, 2, final_worker}, 1_000

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId=?1", [
               "w_harklight_notice_recovery_" <> @handle
             ])

    send(final_worker, :exit_worker)

    assert eventually(fn ->
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId=?1", [
               "w_harklight_notice_recovery_" <> @handle
             ]) == {:ok, [[1]]}
           end)

    refute String.contains?(File.read(gone_calls) |> elem(1), "session end")

    assert {:ok, [["unavailable", error]]} =
             DB.query(
               db,
               "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1",
               [@handle]
             )

    assert error =~ "listener_stopped"
    refute_receive {:retryable_failure, 3, _worker}, 50
  end

  test "quiet restarts, baseline and duplicate frames keep a notified outage open", %{db: db} do
    parent = self()
    failure = {:harklight_failure, {"listener_stopped", "transport_error"}, "listen", nil}
    first = feed_chat(10, "request", "existing")
    :ok = HarklightWakes.capture_feed(db, @handle, 10, [first], :live)

    listener = fn manager, handle, _vendor ->
      send(parent, {:outage_worker, self()})

      receive do
        :fail ->
          :ok = GenServer.call(manager, {:finished, handle, failure})

        :catch_up ->
          :ok = GenServer.call(manager, {:feed_capture, handle, 10, [], :live})
          :ok = GenServer.call(manager, {:feed_ready, handle})
          send(parent, :caught_up)

          receive do
            :sse_failed ->
              :ok = GenServer.call(manager, {:finished, handle, failure})

            :fresh ->
              :ok = GenServer.call(manager, {:feed_capture, handle, 9, [first], :live})
              provisional = feed_chat(11, "request", "in-baseline")
              :ok = GenServer.call(manager, {:feed_capture, handle, 11, [provisional], :baseline})
              duplicate = %{first | "rev" => 12}
              :ok = GenServer.call(manager, {:feed_capture, handle, 12, [duplicate], :live})
              send(parent, :replayed)
              receive do: (:new_change -> :ok)
              fresh = feed_chat(13, "request", "fresh")
              :ok = GenServer.call(manager, {:feed_capture, handle, 13, [fresh], :live})
              send(parent, :captured)
              receive do: (:hold -> :ok)
          end
      end
    end

    opts = [db: db, listener: listener, retry_delays: [1], outage_notice_delay_ms: 0]
    start_supervised!({HarklightWakes, opts})
    assert_receive {:outage_worker, original}
    send(original, :fail)
    assert_receive {:outage_worker, second}, 1_000
    send(second, :catch_up)
    assert_receive :caught_up

    assert eventually(fn ->
             match?(
               {:ok, [[@handle, _, _, notice]]} when is_binary(notice),
               Tightbeam.HarklightListenerOutage.pending(db)
             )
           end)

    assert {:ok, [[@handle, episode, started, notice]]} =
             Tightbeam.HarklightListenerOutage.pending(db)

    send(second, :sse_failed)
    assert_receive {:outage_worker, _}, 1_000
    assert :ok = stop_supervised(HarklightWakes)
    start_supervised!({HarklightWakes, opts})
    assert_receive {:outage_worker, resumed}

    send(resumed, :catch_up)
    assert_receive :caught_up
    send(resumed, :fresh)
    assert_receive :replayed

    assert {:ok, [[@handle, ^episode, ^started, ^notice]]} =
             Tightbeam.HarklightListenerOutage.pending(db)

    assert {:ok, [[10]]} = DB.query(db, "SELECT checkpoint FROM harklight_listener_outages")

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId LIKE 'w_harklight_notice_recovery_%'"
             )

    assert {:ok, []} =
             DB.query(db, "SELECT wakeId FROM wakes WHERE wakeId=?1", [
               "w_harklight_listening_" <> episode
             ])

    send(resumed, :new_change)
    assert_receive :captured
    assert {:ok, []} = Tightbeam.HarklightListenerOutage.pending(db)

    assert {:ok, [[prompt]]} =
             DB.query(db, "SELECT prompt FROM wakes WHERE wakeId=?1", [
               "w_harklight_listening_" <> episode
             ])

    assert prompt =~ "Tightbeam is receiving Harklight updates again"
  end

  test "refused outage persistence keeps the original cause, time and checkpoint", %{db: db} do
    :ok = HarklightWakes.capture_feed(db, @handle, 8, [], :live)

    :ok =
      DB.execute(db, """
      CREATE TRIGGER reject_outage BEFORE INSERT ON harklight_listener_outages
      BEGIN SELECT RAISE(ABORT, 'refuse outage intent'); END;
      """)

    parent = self()
    clock = :atomics.new(1, [])
    issued = System.system_time(:millisecond)
    :atomics.put(clock, 1, issued)

    listener = fn manager, handle, _vendor ->
      send(parent, {:feed, self()})

      receive do
        :drop -> :ok
        :fail -> :ok = GenServer.call(manager, {:finished, handle, "listener_stopped"})
      end
    end

    opts = [
      db: db,
      listener: listener,
      retry_delays: [1],
      outage_notice_delay_ms: 600_000,
      wall_now: fn -> :atomics.get(clock, 1) end
    ]

    manager = start_supervised!({HarklightWakes, opts})
    assert_receive {:feed, original}
    send(original, :drop)

    assert eventually(fn ->
             :sys.get_state(manager).pending_failures[@handle] ==
               {"listener_terminated", issued, true}
           end)

    assert {:ok, [["active", nil]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")

    assert {:ok, []} = Tightbeam.HarklightListenerOutage.pending(db)

    assert {:ok, {"listener_terminated", ^issued, true}} =
             Tightbeam.HarklightFeedCustody.pending(:sys.get_state(manager).custody_dir, @handle)

    replacing = replace_feed_manager(manager)

    assert eventually(fn ->
             :sys.get_state(replacing).pending_failures[@handle] ==
               {"listener_terminated", issued, true}
           end)

    HarklightWakes.activate(@handle, true)
    refute_receive {:feed, _}, 350
    assert {:ok, [[8]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")

    :atomics.put(clock, 1, issued + 600_000)
    :ok = DB.execute(db, "DROP TRIGGER reject_outage")
    assert_receive {:feed, retry}, 1_000
    send(retry, :fail)

    assert eventually(fn ->
             match?(
               {:ok, [[@handle, _, ^issued, id]]} when is_binary(id),
               Tightbeam.HarklightListenerOutage.pending(db)
             )
           end)

    assert {:ok, [["listener_terminated", 8]]} =
             DB.query(db, "SELECT error,checkpoint FROM harklight_listener_outages")

    assert {:ok, [[@handle, episode, ^issued, notice]]} =
             Tightbeam.HarklightListenerOutage.pending(db)

    :ok = stop_supervised(HarklightWakes)
    start_supervised!({HarklightWakes, opts})
    assert_receive {:feed, replacement}, 1_000
    send(replacement, :fail)
    assert_receive {:feed, _}, 1_000

    assert {:ok, [[@handle, ^episode, ^issued, ^notice]]} =
             Tightbeam.HarklightListenerOutage.pending(db)

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId LIKE 'w_harklight_notice_recovery_%'"
             )
  end

  for {name, table, exit_code, diagnostic, reason} <- [
        {"pause", "harklight_feed_pauses", 1,
         ~s|listen: live updates paused: internal_error (Request-Id Some("original-request"))|,
         "original-request"},
        {"stop", "harklight_feed_stops", 2,
         ~s|server returned HTTP 403: Some("forbidden") (request ID None)|, "feed_refused"}
      ],
      local_store <- [:available, :refused] do
    @failure_table table
    @failure_exit exit_code
    @failure_diagnostic diagnostic
    @failure_reason reason
    @local_store local_store

    test "refused feed #{name} survives manager replacement with local store #{local_store}", %{
      db: db
    } do
      :ok = HarklightWakes.capture_feed(db, @handle, 8, [], :live)

      :ok =
        DB.execute(db, """
        CREATE TRIGGER reject_feed_failure BEFORE INSERT ON #{@failure_table}
        BEGIN SELECT RAISE(ABORT, 'refuse feed failure projection'); END;
        """)

      clock = :atomics.new(1, [])
      issued = System.system_time(:millisecond)
      :atomics.put(clock, 1, issued)
      custody = Path.join(System.tmp_dir!(), "#{db}-recovery-intent")
      on_exit(fn -> File.rm_rf(custody) end)

      if @local_store == :refused do
        # Let the first child start, then make the journal directory refuse
        # both writing and reading before the failure is observed.
        File.mkdir_p!(custody)
      end

      fake_harklight_agent!("""
      printf '%s\n' "$*" >> "$0.calls"
      if [ ! -e "$0.resume" ]; then
        while [ ! -e "$0.fail" ]; do sleep 0.05; done
        printf '%s\n' '#{@failure_diagnostic}' >&2
        exit #{@failure_exit}
      fi
      [ "$*" = 'listen --follow --session #{@handle} --after 8' ] || exit 2
      printf '%s\n' '{"kind":"caught_up","rev":8}'
      exec sleep 30
      """)

      agent_path = System.find_executable("harklight-agent")
      calls = fn -> File.read!(agent_path <> ".calls") |> String.split("\n", trim: true) end

      opts = [
        db: db,
        feed_custody_dir: custody,
        retry_delays: [1],
        wall_now: fn -> :atomics.get(clock, 1) end
      ]

      manager = start_supervised!({HarklightWakes, opts})
      assert eventually(fn -> File.exists?(agent_path <> ".calls") end)

      if @local_store == :refused do
        File.rmdir!(custody)
        File.write!(custody, "fixture refusing custody directory")
      end

      File.touch!(agent_path <> ".fail")

      assert eventually(fn ->
               match?({_status, ^issued, true}, :sys.get_state(manager).pending_failures[@handle])
             end)

      expected = "listen --follow --session #{@handle} --after 8"
      assert calls.() == [expected]
      assert {:ok, []} = DB.query(db, "SELECT handle FROM #{@failure_table}")

      :atomics.put(clock, 1, issued + 600_000)

      refute eventually(
               fn ->
                 match?(
                   {_status, time, true} when time != issued,
                   :sys.get_state(manager).pending_failures[@handle]
                 )
               end,
               35
             )

      replacement = replace_feed_manager(manager)

      assert eventually(fn ->
               match?(
                 {_status, ^issued, true},
                 :sys.get_state(replacement).pending_failures[@handle]
               )
             end)

      HarklightWakes.activate(@handle, true)
      assert {:ok, [[8]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")
      refute eventually(fn -> length(calls.()) > 1 end, 35)
      assert {:ok, []} = DB.query(db, "SELECT handle FROM #{@failure_table}")

      if @local_store == :refused, do: File.rm!(custody)
      :ok = DB.execute(db, "DROP TRIGGER reject_feed_failure")

      assert eventually(fn ->
               match?({:ok, [[@handle]]}, DB.query(db, "SELECT handle FROM #{@failure_table}"))
             end)

      assert {:ok, [["unavailable", error, ^issued]]} =
               DB.query(db, "SELECT state,lastError,updatedAt FROM harklight_wake_handles")

      assert error =~ @failure_reason
      assert {:ok, [[8]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")

      HarklightWakes.activate(@handle, true)
      refute eventually(fn -> length(calls.()) > 1 end, 35)

      File.touch!(agent_path <> ".resume")

      assert %{counts: %{listening: 1}} =
               HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

      assert calls.() == [expected, expected]
      assert {:ok, []} = DB.query(db, "SELECT handle FROM #{@failure_table}")
    end
  end

  for {code, status, diagnostic, attempts} <- [
        {"feed_refused", 2, ~s|server returned HTTP 403: Some("forbidden") (request ID None)|, 1},
        {"unsupported_version", 5,
         ~s|server returned HTTP 404: Some("unsupported") (request ID None)|, 1},
        {"invalid_response", 1, "invalid agent snapshot", 1},
        {"transport_error", 1,
         "server request via configured address localhost failed: connection lost", 2}
      ] do
    @feed_code code
    @feed_status status
    @feed_diagnostic diagnostic
    @feed_attempts attempts
    test "filtered feed refusal #{@feed_code} uses #{@feed_attempts} bounded attempts", %{db: db} do
      path = Path.join(System.tmp_dir!(), "feed-calls-#{System.unique_integer([:positive])}")
      File.write!(path, "")
      on_exit(fn -> File.rm(path) end)

      fake_harklight_agent!("""
      printf '%s\n' "$*" >> '#{path}'
      printf '%s\n' '#{@feed_diagnostic}' >&2
      exit #{@feed_status}
      """)

      manager =
        start_supervised!({HarklightWakes, db: db, retry_delays: [1], sustain_retries: false})

      assert eventually(fn ->
               state = :sys.get_state(manager)
               calls = File.read!(path) |> String.split("\n", trim: true)

               state.workers == %{} and state.retry_timers == %{} and
                 length(calls) == @feed_attempts
             end)

      expected = "listen --follow --session #{@handle} --snapshot"

      assert File.read!(path) |> String.split("\n", trim: true) ==
               List.duplicate(expected, @feed_attempts)

      assert {:ok, [[error]]} = DB.query(db, "SELECT lastError FROM harklight_wake_handles")
      assert error =~ "reason_code=#{@feed_code}"

      if @feed_code != "transport_error" do
        :ok = stop_supervised(HarklightWakes)
        restarted = start_supervised!({HarklightWakes, db: db, retry_delays: [1]})
        assert eventually(fn -> :sys.get_state(restarted).workers == %{} end)
        assert {:ok, [[@handle]]} = DB.query(db, "SELECT handle FROM harklight_feed_stops")
        assert File.read!(path) |> String.split("\n", trim: true) == [expected]
      end
    end
  end

  test "refused capture leaves the checkpoint and replays through the next real child", %{db: db} do
    :ok = HarklightWakes.capture_feed(db, @handle, 10, [], :live)

    :ok =
      DB.execute(db, """
      CREATE TRIGGER reject_feed_advance BEFORE UPDATE ON harklight_feed_checkpoints
      BEGIN SELECT RAISE(ABORT, 'refuse feed capture'); END;
      """)

    calls =
      Path.join(System.tmp_dir!(), "refused-feed-capture-#{System.unique_integer([:positive])}")

    File.write!(calls, "")
    on_exit(fn -> File.rm(calls) end)
    chat = JSON.encode!(feed_chat(11, "request", "replayed-after-refusal"))

    fake_harklight_agent!("""
    printf '%s\n' "$*" >> '#{calls}'
    printf '%s\n' '#{chat}' '{"kind":"caught_up","rev":11}'
    exec sleep 30
    """)

    start_supervised!({HarklightWakes, db: db, retry_delays: [750], retry_jitter: false})

    assert eventually(fn ->
             DB.query(db, "SELECT error,checkpoint FROM harklight_listener_outages") ==
               {:ok, [["capture_unavailable", 10]]}
           end)

    assert {:ok, [[10]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
    :ok = DB.execute(db, "DROP TRIGGER reject_feed_advance")

    assert eventually(fn ->
             DB.query(db, "SELECT rev FROM harklight_feed_checkpoints") == {:ok, [[11]]}
           end)

    assert {:ok, []} = Tightbeam.HarklightListenerOutage.pending(db)
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

    assert File.read!(calls) |> String.split("\n", trim: true) ==
             List.duplicate("listen --follow --session #{@handle} --after 10", 2)
  end

  test "a refused capture with an independently partial tail holds the launch fence", %{db: db} do
    :ok = HarklightWakes.capture_feed(db, @handle, 10, [], :live)

    :ok =
      DB.execute(db, """
      CREATE TRIGGER reject_feed_advance BEFORE UPDATE ON harklight_feed_checkpoints
      BEGIN SELECT RAISE(ABORT, 'refuse feed capture'); END;
      """)

    chat = JSON.encode!(feed_chat(11, "request", "refused-before-tail"))

    fake_harklight_agent!("""
    printf '%s\n' "$*" >> "$0.calls"
    if [ -e "$0.resume" ]; then
      printf '%s\n' '#{chat}' '{"kind":"caught_up","rev":11}'
    else
      printf '%s\n' '{"kind":"caught_up","rev":10}'
      while [ ! -e "$0.fail" ]; do sleep 0.02; done
      printf '%s\n%s' '#{chat}' '{"kind":"message","data":'
    fi
    exec sleep 30
    """)

    # The initial caught-up marker writes no checkpoint because the rev is equal.
    agent = System.find_executable("harklight-agent")
    manager = start_supervised!({HarklightWakes, db: db, retry_delays: [20]})

    assert eventually(fn ->
             state = :sys.get_state(manager)
             Map.has_key?(state.ports, @handle) and MapSet.size(state.starts_in_flight) == 0
           end)

    token = :sys.get_state(manager).launch_owners[@handle]
    File.touch!(agent <> ".fail")

    assert eventually(fn ->
             case DB.query(db, "SELECT diagnostic FROM harklight_feed_pauses") do
               {:ok, [[diagnostic]]} -> diagnostic =~ "feed_custody_uncertain"
               _ -> false
             end
           end)

    assert {:ok, [[^token]]} = DB.query(db, "SELECT owner FROM harklight_feed_launches")
    assert {:ok, [[10]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
    assert :ok = DB.execute(db, "DROP TRIGGER reject_feed_advance")

    expected = "listen --follow --session #{@handle} --after 10"
    File.touch!(agent <> ".resume")
    HarklightWakes.activate(@handle, true)

    refute eventually(
             fn ->
               String.split(File.read!(agent <> ".calls"), "\n", trim: true) != [expected]
             end,
             35
           )

    assert %{counts: %{listening: 1}} =
             HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

    assert {:ok, [[11]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
    assert String.split(File.read!(agent <> ".calls"), "\n", trim: true) == [expected, expected]
  end

  test "shared cooldown paces real filtered children and prioritizes an explicit retry", %{
    db: db,
    session: session
  } do
    second = "7d737f62-bbd7-4c51-978d-f6ff5b4d8147"
    third = "7d737f62-bbd7-4c51-978d-f6ff5b4d8148"
    seed_completion_handle(db, session.session_key, second, "other")
    seed_completion_handle(db, session.session_key, third, "third")

    calls = Path.join(System.tmp_dir!(), "paced-children-#{System.unique_integer([:positive])}")
    File.write!(calls, "")
    on_exit(fn -> File.rm(calls) end)

    fake_harklight_agent!("""
    handle="$4"
    printf '%s\n' "$handle" >> '#{calls}'
    count=$(grep -c "$handle" '#{calls}')
    if [ "$handle" != '#{third}' ] && [ "$count" -eq 1 ]; then
      printf '%s\n' 'server request via configured address localhost failed: connection lost' >&2
      exit 1
    fi
    printf '%s\n' '{"kind":"caught_up","rev":0}'
    while :; do sleep 1; done
    """)

    opts = [
      db: db,
      retry_delays: [5_000],
      retry_jitter: false,
      feed_start_spacing_ms: 250,
      feed_cooldown_threshold: 2,
      feed_cooldown_base_ms: 1_200
    ]

    manager = start_supervised!({HarklightWakes, opts})

    assert eventually(fn -> File.read!(calls) == @handle <> "\n" end)
    assert eventually(fn -> :sys.get_state(manager).cooldown_level == 1 end)
    assert File.read!(calls) |> String.split("\n", trim: true) == [@handle, second]

    retry = Task.async(fn -> GenServer.call(manager, {:retry_handle, @handle}, :infinity) end)

    assert eventually(fn ->
             match?([{@handle, :retry}, {^third, _}], :sys.get_state(manager).admission_queue)
           end)

    assert :in_progress = GenServer.call(manager, {:retry_handle, @handle})
    assert File.read!(calls) |> String.split("\n", trim: true) == [@handle, second]

    assert {:listening, %{}} = Task.await(retry, 3_000)

    assert eventually(fn ->
             File.read!(calls) |> String.split("\n", trim: true) == [
               @handle,
               second,
               @handle,
               third
             ]
           end)

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_listener_outages")

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId LIKE 'w_harklight_notice_recovery_%'"
             )
  end

  test "explicit retry keeps its waiter while a preparation read is deferred", %{db: db} do
    :ok = DB.execute(db, "UPDATE harklight_wake_handles SET state='unavailable'")

    :ok =
      DB.execute(
        db,
        "INSERT INTO harklight_feed_stops(handle) SELECT handle FROM harklight_wake_handles"
      )

    proxy = start_supervised!({RefusingHarklightDB, {db, self()}})
    parent = self()

    listener = fn manager, handle, _vendor ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(parent, :ready_after_deferral)
      receive do: (:hold -> :ok)
    end

    manager = start_supervised!({HarklightWakes, db: proxy, listener: listener})
    prepare = "SELECT sessionKey,host,vendorSessionId,state"
    assert :ok = GenServer.call(proxy, {:refuse, prepare})
    first = Task.async(fn -> GenServer.call(manager, {:retry_handle, @handle}, :infinity) end)
    assert_receive {:refused_sql, ^prepare}

    assert eventually(fn ->
             state = :sys.get_state(manager)

             Map.has_key?(state.retry_waiters, @handle) and
               Map.has_key?(state.retry_timers, @handle)
           end)

    assert :in_progress = GenServer.call(manager, {:retry_handle, @handle})
    assert {:listening, %{}} = Task.await(first, 2_000)
    assert_receive :ready_after_deferral
    assert {:ok, []} = DB.query(db, "SELECT handle FROM harklight_feed_stops")
  end

  for disposition <- [:paused, :stopped] do
    @disposition disposition
    test "canceling a queued explicit retry revokes authorization for a #{@disposition} feed", %{
      db: db,
      session: session
    } do
      :ok = DB.execute(db, "UPDATE harklight_wake_handles SET state='unavailable'")

      table =
        if @disposition == :paused do
          :ok =
            DB.execute(db, """
            INSERT INTO harklight_feed_pauses(handle,diagnostic)
            SELECT handle,'original pause' FROM harklight_wake_handles
            """)

          "harklight_feed_pauses"
        else
          :ok =
            DB.execute(db, """
            INSERT INTO harklight_feed_stops(handle) SELECT handle FROM harklight_wake_handles
            """)

          "harklight_feed_stops"
        end

      fake_harklight_session_end_agent!()
      parent = self()

      listener = fn manager, handle, _ ->
        :ok = GenServer.call(manager, {:feed_ready, handle})
        send(parent, :feed_open)
        receive do: (:hold -> :ok)
      end

      manager = start_supervised!({HarklightWakes, db: db, listener: listener})

      :sys.replace_state(
        manager,
        &%{&1 | cooldown_until: System.monotonic_time(:millisecond) + 60_000}
      )

      retry = Task.async(fn -> GenServer.call(manager, {:retry_handle, @handle}, :infinity) end)

      assert eventually(fn ->
               state = :sys.get_state(manager)
               state.admission_queue == [{@handle, :retry}] and state.workers == %{}
             end)

      Org.set_host(db, session.session_key, "other-host")
      assert {:failed, "listener receiver is no longer eligible", _} = Task.await(retry, 2_000)

      state = :sys.get_state(manager)
      assert state.admission_queue == []
      refute Map.has_key?(state.retry_waiters, @handle)
      refute MapSet.member?(state.manual_starts, @handle)

      :sys.replace_state(manager, fn state ->
        {timer, _token} = state.admission_timer
        Process.cancel_timer(timer)
        %{state | cooldown_until: nil, admission_timer: nil}
      end)

      Org.set_host(db, session.session_key, Placement.local_host_name())
      HarklightWakes.activate(@handle, true)
      refute_receive :feed_open, 350
      assert {:ok, [[@handle]]} = DB.query(db, "SELECT handle FROM #{table}")

      assert {:listening, %{}} = GenServer.call(manager, {:retry_handle, @handle}, :infinity)
      assert_receive :feed_open
      assert {:ok, []} = DB.query(db, "SELECT handle FROM #{table}")
    end
  end

  defp replace_feed_manager(manager) do
    monitor = Process.monitor(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^manager, :killed}, 1_000

    assert eventually(fn ->
             current = Process.whereis(HarklightWakes)
             is_pid(current) and current != manager
           end)

    Process.whereis(HarklightWakes)
  end

  test "a live focus frame proves recovery after an empty catch-up", %{db: db} do
    :ok = HarklightWakes.capture_feed(db, @handle, 5, [], :live)
    now = System.system_time(:millisecond)

    assert {:ok, [@handle, episode, ^now, nil]} =
             DB.transaction(db, fn txn ->
               Tightbeam.HarklightListenerOutage.start_in_txn(
                 txn,
                 @handle,
                 {"listener_terminated", nil, nil},
                 now
               )
             end)

    assert {:ok, :notified} =
             Tightbeam.HarklightListenerOutage.notify(db, @handle, episode, now, 0)

    gate = Path.join(System.tmp_dir!(), "live-focus-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(gate) end)

    fake_harklight_agent!("""
    printf '%s\n' '{"kind":"caught_up","rev":5}' '{"kind":"focus","data":{}}'
    while [ ! -f '#{gate}' ]; do sleep 0.05; done
    printf '%s\n' '{"kind":"focus","data":{"focus":{}}}'
    while :; do sleep 1; done
    """)

    manager = start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             state = :sys.get_state(manager)
             map_size(state.workers) == 1 and MapSet.size(state.starts_in_flight) == 0
           end)

    assert {:ok, [[@handle, ^episode, ^now, _]]} = Tightbeam.HarklightListenerOutage.pending(db)
    File.write!(gate, "")
    assert eventually(fn -> Tightbeam.HarklightListenerOutage.pending(db) == {:ok, []} end)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId=?1", [
               "w_harklight_listening_" <> episode
             ])

    assert {:ok, [[5]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")
  end

  test "empty catch-up keeps counting consecutive failures", %{db: db} do
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, {:listener_started, self()})
      receive do: (:drop -> :ok)
    end

    manager =
      start_supervised!(
        {HarklightWakes, db: db, listener: listener, retry_delays: [1, 1], sustain_retries: false}
      )

    for _ <- 1..3 do
      assert_receive {:listener_started, worker}, 1_000
      send(worker, :drop)
    end

    assert eventually(fn ->
             state = :sys.get_state(manager)
             state.workers == %{} and state.retry_timers == %{}
           end)

    refute_receive {:listener_started, _}, 50
  end

  test "an ineligible local origin is gone and later eligibility can attach again", %{
    db: db,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
    Org.set_host(db, session.session_key, "other-host")
    parent = self()

    listener = fn manager, handle, _ ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(parent, :reattached)

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})

    assert eventually(fn ->
             File.exists?(calls) and
               File.read!(calls) =~ "session end --session #{@handle}"
           end)

    refute_receive :reattached, 30
    Org.set_host(db, session.session_key, Placement.local_host_name())
    assert_receive :reattached

    assert {:ok, [["active", nil]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")
  end

  test "manual retry resolves an answered message to its mixed unanswered handle", %{db: db} do
    parent = self()

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_wake_requests(senderId,messageId,handle) VALUES('sender','sibling',?1)",
               [@handle]
             )

    answer = completion_event(@handle, 1, "request", "terminal", "person")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1",
               [@handle]
             )

    listener = fn manager, handle, _vendor ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(parent, {:retry_listener_started, self()})

      receive do
        :hold -> :ok
      end
    end

    manager =
      start_supervised!({HarklightWakes, db: db, listener: listener, retry_delays: [1]})

    assert eventually(fn ->
             Process.info(manager, :message_queue_len) == {:message_queue_len, 0}
           end)

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable',lastError='previous failure' WHERE handle=?1",
               [@handle]
             )

    result = HarklightWakes.retry_command(db, %{params: %{message_id: "request"}})
    assert_receive {:retry_listener_started, listener_pid}

    assert %{selector: "message", counts: %{listening: 1}, results: [handle_result]} = result
    assert handle_result.outcome == "listening"
    assert handle_result.selected_message == %{message_id: "request", state: "answered"}
    assert Enum.find(handle_result.messages, &(&1.message_id == "request")).state == "answered"
    assert Enum.find(handle_result.messages, &(&1.message_id == "sibling")).state == "waiting"
    assert handle_result.started_for.waiting_messages == ["sibling"]

    repeated = HarklightWakes.retry_command(db, %{params: %{message_id: "request"}})

    assert %{
             counts: %{not_failed: 1},
             results: [
               %{
                 outcome: "not_failed",
                 state: "active",
                 selected_message: %{message_id: "request", state: "answered"}
               }
             ]
           } = repeated

    assert Process.alive?(listener_pid)
  end

  test "manual retry reads saved sends after a listener restart with a pending change", %{
    db: db,
    call: call,
    session: session
  } do
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    # A saved change operation from an earlier release has a list-shaped request.
    # Main no longer creates one, but retry must still read its persisted state.
    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_send_operations(opId,sessionKey,host,payload,state,createdAt,updatedAt) VALUES(?1,?2,?3,?4,?5,1,1)",
               [
                 Tightbeam.Id.uuid4(),
                 call.session_key,
                 Placement.local_host_name(),
                 JSON.encode!(%{
                   "operation_kind" => "change",
                   "request" => ["--message", "request"]
                 }),
                 "pending"
               ]
             )

    listener = fn manager, handle, _vendor ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)

      case attempt do
        2 ->
          :ok = GenServer.call(manager, {:finished, handle, "scripted_feed_failure"})
          send(parent, :restart_feed_failed)

        _ ->
          :ok = GenServer.call(manager, {:feed_ready, handle})
          send(parent, {:listener_started, attempt, self()})
          receive do: (:hold -> :ok)
      end
    end

    opts = [
      db: db,
      listener: listener,
      retry_delays: []
    ]

    start_supervised!({HarklightWakes, opts})
    assert_receive {:listener_started, 1, first_listener}
    first_ref = Process.monitor(first_listener)
    :ok = stop_supervised(HarklightWakes)
    assert_receive {:DOWN, ^first_ref, :process, ^first_listener, :shutdown}

    start_supervised!({HarklightWakes, opts})
    assert_receive :restart_feed_failed

    assert {:ok, [["unavailable"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])

    assert %{counts: %{listening: 1}, results: [%{outcome: "listening"}]} =
             HarklightWakes.retry_command(db, %{params: %{message_id: "request"}})

    assert_receive {:listener_started, 3, _retry_listener}
    reply = event(1, "discussion", "same-origin reply after retry")
    assert :ok = HarklightWakes.capture_line(db, @handle, reply)
    assert :ok = HarklightWakes.capture_line(db, @handle, reply)
    origin = session.session_key

    assert {:ok, [[^origin, prompt]]} =
             DB.query(
               db,
               "SELECT d.sessionKey,w.prompt FROM harklight_wake_deliveries d JOIN wakes w ON w.wakeId=d.wakeId WHERE d.handle=?1 AND d.eventId='1'",
               [@handle]
             )

    assert prompt =~ "same-origin reply after retry"
  end

  test "retry state-read failure names the handle, read, and database reason", %{
    db: db,
    session: session
  } do
    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_send_operations(opId,sessionKey,host,payload,state,createdAt,updatedAt) VALUES(?1,?2,?3,'not-json','pending',1,1)",
               [Tightbeam.Id.uuid4(), session.session_key, Placement.local_host_name()]
             )

    assert %{code: "harklight_retry_state_unavailable", message: message} =
             HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

    assert message =~ @handle
    assert message =~ "pending sends"
    assert message =~ "malformed JSON"
  end

  test "manual retry advances a scheduled automatic recovery", %{db: db} do
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    listener = fn manager, handle, _vendor ->
      attempt = Agent.get_and_update(attempts, fn current -> {current, current + 1} end)
      send(parent, {:recovery_listener_started, attempt})

      if attempt == 0 do
        :ok = GenServer.call(manager, {:finished, handle, "listener_stopped"})
      else
        :ok = GenServer.call(manager, {:feed_ready, handle})
        send(parent, :recovery_feed_ready)
        receive do: (:hold -> :ok)
      end
    end

    manager =
      start_supervised!({HarklightWakes, db: db, listener: listener, retry_delays: [5_000]})

    assert_receive {:recovery_listener_started, 0}
    assert eventually(fn -> Map.has_key?(:sys.get_state(manager).retry_timers, @handle) end)

    assert %{counts: %{listening: 1}, results: [%{outcome: "listening"}]} =
             HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

    assert :sys.get_state(manager).retry_timers == %{}
    assert_receive {:recovery_listener_started, 1}
    assert_receive :recovery_feed_ready, 1_000

    assert %{counts: %{not_failed: 1}, results: [%{outcome: "not_failed", state: "active"}]} =
             HarklightWakes.retry_command(db, %{params: %{handle: @handle}})
  end

  test "retry rejects invalid targets without reading Harklight", %{db: db} do
    parent = self()

    runner = fn _args ->
      send(parent, :unexpected_harklight_contact)
      {"{}", 0}
    end

    assert %{code: "invalid_harklight_retry_selector"} =
             HarklightWakes.retry_command(db, %{params: %{}})

    assert %{code: "invalid_harklight_retry_selector"} =
             HarklightWakes.retry_command(db, %{params: %{all: true, handle: @handle}})

    assert %{code: "harklight_message_unknown"} =
             HarklightWakes.retry_command(db, %{params: %{message_id: "unknown-message"}})

    assert %{code: "harklight_handle_unknown"} =
             HarklightWakes.retry_command(db, %{params: %{handle: "unknown-handle"}})

    assert {:ok, _} =
             DB.query(db, "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1", [
               @handle
             ])

    start_supervised!({HarklightWakes, db: db, send_runner: runner})

    assert eventually(fn ->
             Process.info(Process.whereis(HarklightWakes), :message_queue_len) ==
               {:message_queue_len, 0}
           end)

    assert %{
             results: [],
             counts: %{failed: 0, in_progress: 0, listening: 0, not_failed: 0, skipped_closed: 0}
           } =
             HarklightWakes.retry_command(db, %{params: %{all: true}})

    refute_receive :unexpected_harklight_contact, 0
  end

  test "retry reports a listening or complete handle as not failed without another start", %{
    db: db
  } do
    parent = self()

    listener = fn manager, handle, _vendor ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(parent, {:listening, self()})
      receive do: (:hold -> :ok)
    end

    manager = start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listening, listener_pid}

    assert eventually(fn ->
             Process.info(manager, :message_queue_len) == {:message_queue_len, 0}
           end)

    assert %{counts: %{not_failed: 1}, results: [%{outcome: "not_failed", state: "active"}]} =
             HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

    assert %{selector: "all", results: []} =
             HarklightWakes.retry_command(db, %{params: %{all: true}})

    assert {:ok, _} =
             DB.query(db, "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1", [
               @handle
             ])

    assert %{counts: %{not_failed: 1}, results: [%{outcome: "not_failed", state: "complete"}]} =
             HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

    refute_receive {:listening, _}, 0
    assert :sys.get_state(manager).workers == %{@handle => listener_pid}
  end

  test "retry restarts an active handle that has no listener", %{db: db} do
    parent = self()

    listener = fn manager, handle, _vendor ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(parent, {:listening, self()})
      receive do: (:hold -> :ok)
    end

    assert {:ok, _} =
             DB.query(db, "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1", [
               @handle
             ])

    manager =
      start_supervised!({HarklightWakes, db: db, listener: listener, retry_delays: []})

    assert eventually(fn ->
             Process.info(manager, :message_queue_len) == {:message_queue_len, 0}
           end)

    # The row looks healthy, but its listener ended before recording a failure.
    assert {:ok, _} =
             DB.query(db, "UPDATE harklight_wake_handles SET state='active' WHERE handle=?1", [
               @handle
             ])

    assert :sys.get_state(manager).workers == %{}

    assert %{selector: "all", counts: %{listening: 1}, results: [%{outcome: "listening"}]} =
             HarklightWakes.retry_command(db, %{params: %{all: true}})

    assert_receive {:listening, listener_pid}
    assert :sys.get_state(manager).workers == %{@handle => listener_pid}

    assert %{counts: %{not_failed: 1}, results: [%{outcome: "not_failed", state: "active"}]} =
             HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

    refute_receive {:listening, _}, 50
  end

  test "repeated same-ID loads and lane starts keep one filtered feed", %{
    db: db,
    session: session
  } do
    path = Path.join(System.tmp_dir!(), "same-pointer-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    fake_harklight_agent!("""
    printf '%s\\n' "$*" >> '#{path}'
    if [ "$1" = listen ]; then
      printf '%s\\n' '{"kind":"caught_up","rev":9}'
      exec sleep 300
    fi
    """)

    calls = fn -> File.read!(path) |> String.split("\n", trim: true) end
    listen_count = fn -> Enum.count(calls.(), &String.starts_with?(&1, "listen ")) end

    Org.append_pointer(db, session.session_key, "vendor-original", "created")
    manager = start_supervised!({HarklightWakes, db: db})

    assert eventually(fn -> File.exists?(path) and listen_count.() == 1 end)
    assert is_port(:sys.get_state(manager).ports[@handle])
    worker = :sys.get_state(manager).workers[@handle]

    for _ <- 1..5 do
      Org.append_pointer(db, session.session_key, "vendor-original", "loaded")
      GenServer.cast(manager, {:origin_ready, session.session_key})
      # The synchronous round trip drains the preceding pointer handoff and
      # origin_ready cast before checking that neither replaced the worker.
      assert :sys.get_state(manager).workers[@handle] == worker
    end

    assert listen_count.() == 1
    assert length(Org.pointer_chain(db, session.session_key)) == 6

    Org.append_pointer(db, session.session_key, "vendor-replacement", "fallback")

    assert eventually(fn ->
             state = :sys.get_state(manager)
             is_port(state.ports[@handle]) and state.workers[@handle] != worker
           end)

    assert eventually(fn -> listen_count.() == 2 end)

    assert calls.() == [
             "listen --follow --session #{@handle} --snapshot",
             "listen --follow --session #{@handle} --after 9"
           ]
  end

  test "an overloaded listener-state write keeps the feed and delivers the waiting entry once",
       %{db: db, session: session} do
    path = Path.join(System.tmp_dir!(), "state-write-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    waiting = JSON.encode!(feed_chat(1, "request", "entry-1"))

    fake_harklight_agent!("""
    printf '%s\n' "$*" >> '#{path}'
    if [ "$1" = listen ]; then
      printf '%s\n' '#{waiting}' '{"kind":"caught_up","rev":1}'
      exec sleep 300
    fi
    exit 2
    """)

    proxy = start_supervised!({FeedStateOverloadDB, {db, self(), 3}})

    manager =
      start_supervised!({HarklightWakes, db: proxy, feed_state_retry_delays: [10, 20]})

    for _ <- 1..3, do: assert_receive(:feed_state_refused, 2_000)

    assert eventually(fn ->
             DB.query(db, "SELECT COUNT(*) FROM harklight_wake_deliveries") == {:ok, [[1]]}
           end)

    assert {:ok, [[@handle, event_id, session_key]]} =
             DB.query(db, "SELECT handle,eventId,sessionKey FROM harklight_wake_deliveries")

    assert String.starts_with?(event_id, "v2_")
    assert session_key == session.session_key
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")

    assert eventually(fn ->
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ]) == {:ok, [["active", nil]]}
           end)

    assert {:ok, []} =
             DB.query(db, "SELECT wakeId FROM wakes WHERE wakeId=?1", [
               "w_harklight_notice_recovery_" <> @handle
             ])

    calls = File.read!(path) |> String.split("\n", trim: true)
    assert calls == ["listen --follow --session #{@handle} --snapshot"]

    state = :sys.get_state(manager)
    assert Map.has_key?(state.workers, @handle)
    refute Map.has_key?(state.failures, @handle)
    assert is_port(state.ports[@handle])
  end

  test "manual retry reports an in-flight startup without starting a second listener", %{db: db} do
    parent = self()

    listener = fn _manager, _handle, _vendor ->
      send(parent, {:startup_listener_started, self()})
      receive do: (:hold -> :ok)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:startup_listener_started, listener_pid}

    assert %{counts: %{in_progress: 1}, results: [%{outcome: "in_progress"}]} =
             HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

    refute_receive {:startup_listener_started, _}, 0
    assert Process.alive?(listener_pid)
  end

  test "manual retry resumes a failed filtered feed from its saved checkpoint", %{db: db} do
    path = Path.join(System.tmp_dir!(), "retry-feed-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    fake_harklight_agent!("""
    printf '%s\n' "$*" >> '#{path}'
    if [ "$*" = "listen --follow --session #{@handle} --after 7" ]; then
      printf '%s\n' '{"kind":"caught_up","rev":9}'
      exec sleep 300
    fi
    exit 2
    """)

    assert :ok = HarklightWakes.capture_feed(db, @handle, 7, [], :live)

    assert {:ok, _} =
             DB.query(db, "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1", [
               @handle
             ])

    manager = start_supervised!({HarklightWakes, db: db, retry_delays: []})
    assert :sys.get_state(manager).workers == %{}

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable' WHERE handle=?1",
               [@handle]
             )

    assert %{counts: %{listening: 1}, results: [%{outcome: "listening"}]} =
             HarklightWakes.retry_command(db, %{params: %{handle: @handle}})

    assert {:ok, [[9]]} = DB.query(db, "SELECT rev FROM harklight_feed_checkpoints")
    assert File.read!(path) == "listen --follow --session #{@handle} --after 7\n"
  end

  test "manual retry reports its recorded failure without scheduling another start", %{db: db} do
    parent = self()

    assert {:ok, _} =
             DB.query(db, "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1", [
               @handle
             ])

    listener = fn manager, handle, _vendor ->
      send(parent, :retry_listener_attempted)
      GenServer.call(manager, {:finished, handle, "scripted_feed_failure"})
    end

    manager =
      start_supervised!({HarklightWakes, db: db, listener: listener, retry_delays: []})

    assert eventually(fn ->
             Process.info(manager, :message_queue_len) == {:message_queue_len, 0}
           end)

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable',lastError='previous failure' WHERE handle=?1",
               [@handle]
             )

    result = HarklightWakes.retry_command(db, %{params: %{handle: @handle}})
    assert_receive :retry_listener_attempted
    assert %{selector: "session", counts: %{failed: 1}, results: [handle_result]} = result
    assert handle_result.outcome == "failed"
    assert handle_result.reason == "scripted_feed_failure"

    assert eventually(fn ->
             state = :sys.get_state(manager)
             state.workers == %{} and state.retry_timers == %{} and state.gone_tasks == %{}
           end)

    assert :sys.get_state(manager).manual_starts == MapSet.new()

    assert {:ok, [["unavailable", "scripted_feed_failure"]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])
  end

  test "ordinary worker death restores the same handle after DOWN", %{db: db} do
    test_pid = self()

    listener = fn manager, handle, vendor ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, {:started, self(), handle, vendor})

      receive do
        :fail -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener, retry_delays: [1]})
    assert_receive {:started, old, @handle, vendor}
    ref = Process.monitor(old)
    send(old, :fail)
    assert_receive {:DOWN, ^ref, :process, ^old, :normal}
    assert_receive {:started, new, @handle, ^vendor}
    refute new == old

    assert {:ok, [["active", nil]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])
  end

  test "retry exhaustion leaves availability to the feed and allows later activation", %{db: db} do
    calls = fake_harklight_session_end_agent!()
    parent = self()

    listener = fn manager, handle, _vendor ->
      send(parent, :attempt)
      GenServer.call(manager, {:finished, handle, "listener_stopped"})
    end

    start_supervised!(
      {HarklightWakes, db: db, listener: listener, retry_delays: [1], sustain_retries: false}
    )

    assert_receive :attempt
    assert_receive :attempt
    refute_receive :attempt, 30
    refute File.exists?(calls)

    HarklightWakes.activate(@handle)
    assert_receive :attempt
  end

  test "an irrecoverable feed refusal is recorded without ending the session", %{db: db} do
    calls = fake_harklight_session_end_agent!()
    parent = self()

    listener = fn manager, handle, _vendor ->
      send(parent, :attempt)

      GenServer.call(
        manager,
        {:finished, handle,
         {:harklight_failure, {"listener_stopped", "forbidden"}, "listen", nil}}
      )
    end

    start_supervised!({HarklightWakes, db: db, listener: listener, retry_delays: [1]})
    assert_receive :attempt

    assert eventually(fn ->
             case DB.query(db, "SELECT lastError FROM harklight_wake_handles WHERE handle=?1", [
                    @handle
                  ]) do
               {:ok, [[error]]} when is_binary(error) -> error =~ "reason_code=forbidden"
               _ -> false
             end
           end)

    refute_receive :attempt, 30
    refute File.exists?(calls)
  end

  test "a failed gone command leaves retirement nonblocking", %{db: db, session: session} do
    calls = fake_harklight_session_end_agent!(17, wait_for_session_end: true)
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, {:listener_running, self()})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listener_running, _worker}

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        Org.personal_session_key("owner")
      ])

    retired = Org.retire(db, session.session_key, "user:owner", 60_000)
    assert retired.state == "retired"
    :sys.get_state(HarklightWakes)

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle}\n"}
           end)

    assert {:ok, [["unavailable"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])

    File.write!(calls <> ".release", "continue")

    assert eventually(fn -> File.read(calls <> ".exit-status") == {:ok, "17\n"} end)
  end

  test "moving the origin stops its running controller", %{db: db, call: call, session: session} do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, {:listener_running, self()})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listener_running, worker}
    ref = Process.monitor(worker)

    Org.set_host(db, session.session_key, "another-host")
    assert_receive {:DOWN, ^ref, :process, ^worker, :shutdown}

    assert {:ok, [["unavailable", "origin_unavailable"]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])
  end

  test "a new harness pointer restarts one filtered feed under the current owner", %{
    db: db,
    call: call,
    session: session
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    test_pid = self()

    listener = fn manager, handle, vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      send(test_pid, {:listener_running, self(), vendor_id})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listener_running, old_worker, nil}
    ref = Process.monitor(old_worker)

    Org.append_pointer(db, session.session_key, "vendor-next", "loaded")
    assert_receive {:DOWN, ^ref, :process, ^old_worker, :shutdown}
    assert_receive {:listener_running, new_worker, "vendor-next"}
    refute old_worker == new_worker
  end

  test "completed conversations acquire no successor or recovery wake at retirement", %{
    db: db,
    call: call,
    session: session
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "terminal", "final"))
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:feed_ready, handle})
      :ok = GenServer.call(manager, {:finished, handle, :complete})
      send(test_pid, :listener_completed)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive :listener_completed
    Org.retire(db, session.session_key, "user:owner", 60_000)
    :sys.get_state(HarklightWakes)
    session_key = session.session_key

    assert {:ok, [[^session_key, "pending"]]} =
             DB.query(db, "SELECT sessionKey,state FROM wakes WHERE wakeId LIKE ?1", [
               "w_harklight_" <> @handle <> "_%"
             ])

    assert {:ok, []} = DB.query(db, "SELECT * FROM harklight_wake_follows")

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT sessionKey FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )
  end

  test "retract preserves a queued reply with context and cancels only later captures", %{
    db: db,
    call: call
  } do
    alias Tightbeam.{Ledger, HarklightLifecycle}

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "keep this reply"))

    {:ok, [[wake, prompt]]} =
      DB.query(db, "SELECT wakeId,prompt FROM wakes WHERE wakeId LIKE 'w_harklight_%'")

    Ledger.enqueue(db, %{
      session_key: call.session_key,
      message_id: "queued-reply",
      wake_id: wake,
      origin: "process:tightbeam",
      prompt: prompt
    })

    runner = fn
      ["retract", "--item-id", "server-item", "--op-id", op] ->
        change_committed("retract", op, "server-item", 1)

      args ->
        change_setup_reply(args)
    end

    assert %{outcome: "committed", wake_effect: "ended", pending_delivery: [%{event_id: "1"}]} =
             HarklightSend.change_request(
               db,
               %{call | params: %{message_id: "request"}},
               "retract",
               runner: runner
             )

    assert :ok = HarklightWakes.capture_line(db, @handle, event(2, "discussion", "too late"))

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "keep this reply"))

    assert {:ok, turn} = Ledger.claim_next(db, call.session_key, "test")
    assert turn.prompt =~ "keep this reply"
    assert turn.prompt =~ "received before message request was retracted"
    refute turn.prompt =~ "too late"
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
    assert HarklightLifecycle.lookup(db, "request").state == "committed"

    assert {:ok, [["ended", "not_needed"]]} =
             DB.query(db, "SELECT state,acknowledgment FROM harklight_subscription_ends")
  end

  test "plural supersede holds early own terminals, suppresses them and preserves replies", %{
    db: db,
    call: call
  } do
    bind_extra(db, call, "second")
    bind_extra(db, call, "closed")

    assert :ok =
             HarklightWakes.capture_feed(
               db,
               @handle,
               1,
               [put_in(feed_chat(1, "request", "chat-1"), ["data", "text"], "earlier reply")],
               :live
             )

    runner =
      lifecycle_runner(db,
        before_commit: fn ->
          assert :ok =
                   HarklightWakes.capture_feed(
                     db,
                     @handle,
                     2,
                     [feed_superseded(2, "request")],
                     :live
                   )

          assert :ok =
                   HarklightWakes.capture_feed(
                     db,
                     @handle,
                     3,
                     [feed_superseded(3, "second")],
                     :live
                   )

          assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
        end,
        warnings: [%{message_id: "closed", reason: "closed"}]
      )

    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement",
          supersedes: ["request", "second", "request", "closed", "unknown"]
        }
    }

    result = HarklightSend.send_request(db, send_call, runner: runner)

    assert %{
             outcome: "committed",
             message_id: "replacement",
             wake_effect: "subscribed",
             pending_delivery: [%{event_id: event_id}]
           } = result

    assert String.starts_with?(event_id, "v2_")

    assert Enum.map(result.supersedes, &{&1.message_id, &1.effect}) == [
             {"request", "ended"},
             {"second", "ended"},
             {"closed", "unchanged"},
             {"unknown", "no_subscription"}
           ]

    assert Enum.take(result.supersedes, 2) |> Enum.all?(&(&1.acknowledgment == "not_needed"))
    Tightbeam.HarklightLifecycle.process_terminals(db, runner: runner)

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_entries WHERE entryKind='terminal'"
             )

    assert :ok =
             HarklightWakes.capture_feed(
               db,
               @handle,
               4,
               [put_in(feed_chat(4, "replacement", "chat-4"), ["data", "text"], "new reply")],
               :live
             )

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
    assert {:ok, [[statement]]} = DB.query(db, "SELECT statement FROM harklight_entry_context")
    assert statement =~ "superseded by replacement"
  end

  test "committed sends pass contradiction matches through with camelCase member names", %{
    db: db,
    call: call
  } do
    warning =
      "these possibly contradictory messages are still active, please talk to its poster to reconcile them"

    contradictions = %{
      "status" => "checked",
      "warning" => warning,
      "messages" => [
        %{
          "sender_id" => "sender-a",
          "sender_name" => "Agent A",
          "message_id" => "open-a",
          "title" => "First open request"
        },
        %{
          "sender_id" => "sender-b",
          "sender_name" => "Agent B",
          "message_id" => "open-b",
          "title" => "Second open request"
        }
      ]
    }

    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement"
        }
    }

    result =
      HarklightSend.send_request(db, send_call,
        runner: lifecycle_runner(db, possible_contradictions: contradictions)
      )

    assert result.outcome == "committed"
    assert result.wake_effect == "subscribed"

    assert result.possible_contradictions == %{
             "status" => "checked",
             "warning" => warning,
             "messages" => [
               %{
                 "senderId" => "sender-a",
                 "senderName" => "Agent A",
                 "messageId" => "open-a",
                 "title" => "First open request"
               },
               %{
                 "senderId" => "sender-b",
                 "senderName" => "Agent B",
                 "messageId" => "open-b",
                 "title" => "Second open request"
               }
             ]
           }
  end

  test "committed incomplete result is carried without warning or messages", %{db: db, call: call} do
    contradictions = %{
      "status" => "incomplete",
      "reason" => "unavailable",
      "unchecked" => 3
    }

    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement"
        }
    }

    result =
      HarklightSend.send_request(db, send_call,
        runner: lifecycle_runner(db, possible_contradictions: contradictions)
      )

    assert result.outcome == "committed"
    assert result.wake_effect == "subscribed"
    assert result.possible_contradictions == contradictions
  end

  test "send without the server field retains the ordinary committed result", %{
    db: db,
    call: call
  } do
    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement"
        }
    }

    result = HarklightSend.send_request(db, send_call, runner: lifecycle_runner(db))

    assert result.outcome == "committed"
    assert result.wake_effect == "subscribed"
    refute Map.has_key?(result, :possible_contradictions)
  end

  test "superseding sends carry the contradiction field without changing supersede results", %{
    db: db,
    call: call
  } do
    contradictions = %{
      "status" => "incomplete",
      "reason" => "unavailable",
      "unchecked" => 1
    }

    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement",
          supersedes: ["request"]
        }
    }

    result =
      HarklightSend.send_request(db, send_call,
        runner: lifecycle_runner(db, possible_contradictions: contradictions)
      )

    assert result.outcome == "committed"
    assert result.wake_effect == "subscribed"
    assert result.possible_contradictions == contradictions
    assert [%{message_id: "request", effect: "ended"}] = result.supersedes
  end

  test "an uncertain supersede can be settled once with the same operation and inputs", %{
    db: db,
    call: call
  } do
    runner = lifecycle_runner(db, unknown: true)

    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement",
          supersedes: ["request"]
        }
    }

    assert %{
             outcome: "outcome_unknown",
             op_id: op,
             wake_effect: "none"
           } = HarklightSend.send_request(db, send_call, runner: runner)

    record = Tightbeam.HarklightLifecycle.lookup(db, op)
    no_op = fn _ -> flunk("unresolved lifecycle command ran Harklight") end

    assert %{outcome: "refused", reason: reason} =
             HarklightSend.change_request(
               db,
               %{call | params: %{message_id: op}},
               "retract",
               runner: no_op
             )

    assert reason =~ "harklight-settle"

    assert %{outcome: "refused"} =
             HarklightSend.send_request(
               db,
               %{send_call | params: %{send_call.params | supersedes: [op]}},
               runner: no_op
             )

    settled =
      HarklightSend.settle(db, %{call | params: %{op_id: op}}, runner: lifecycle_runner(db))

    assert %{command: "settle", outcome: "committed", op_id: ^op, wake_effect: "subscribed"} =
             settled

    assert record.payload == Tightbeam.HarklightLifecycle.lookup(db, "replacement").payload

    assert %{outcome: "refused", reason: reason} =
             HarklightSend.settle(db, %{call | params: %{op_id: op}}, runner: no_op)

    assert reason =~ "already settled as committed"
    assert :ok = HarklightSend.recover_pending(db, runner: no_op)
  end

  for {status, description} <- [
        {500, "projection failure after commit"},
        {503, "transient failure"}
      ] do
    test "Round 26 send handles #{description} with the original operation", %{
      db: db,
      call: call
    } do
      status = unquote(status)
      parent = self()
      normal_runner = lifecycle_runner(db)

      first_attempt = fn
        ["send", "--execute", "--op-id", op] = args ->
          if status == 500 do
            send(parent, {:committed_response, op, normal_runner.(args)})
            projection_failure("send", op, "send-projection")
          else
            frame(%{kind: "outcome_unknown", operation: "send", op_id: op, status: 503}, 7)
          end

        args ->
          normal_runner.(args)
      end

      send_call = %{
        call
        | params: %{
            harklight_session: @handle,
            message_type: "fyi",
            title: "Update",
            sender_id: "sender"
          }
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            parent,
            {:send_result, HarklightSend.send_request(db, send_call, runner: first_attempt)}
          )
        end)

      assert_received {:send_result, %{outcome: "outcome_unknown", op_id: op, reason: reason}}
      assert %{state: "pending"} = HarklightLifecycle.lookup(db, op)

      if status == 500 do
        assert_received {:committed_response, ^op, committed}
        assert reason =~ "internal_error"
        assert reason =~ "send-projection"
        assert log =~ "Operation send"
        assert log =~ op

        assert :ok =
                 HarklightSend.recover_pending(db,
                   runner: fn args -> flunk("automatic recovery invoked #{inspect(args)}") end
                 )

        assert %{state: "pending"} = HarklightLifecycle.lookup(db, op)

        assert %{outcome: "committed", op_id: ^op, message_id: "replacement"} =
                 HarklightSend.settle(db, %{call | params: %{op_id: op}},
                   runner: fn ["retry", "--op-id", ^op, "--journal-id", "lifecycle-journal"] ->
                     committed
                   end
                 )
      else
        refute log =~ "internal_error"

        assert :ok =
                 HarklightSend.recover_pending(db,
                   runner: fn ["retry", "--op-id", ^op, "--journal-id", "lifecycle-journal"] =
                                args ->
                     normal_runner.(args)
                   end
                 )
      end

      assert %{state: "committed", message_id: "replacement"} = HarklightLifecycle.lookup(db, op)
      refute_received {:committed_response, _, _}
    end
  end

  test "Round 26 guards a send when its pause write fails and the caller exits", %{
    db: db,
    call: call
  } do
    parent = self()
    proxy = start_supervised!({RefusingHarklightDB, {db, parent}})
    refuse = "INSERT INTO harklight_operation_pauses"

    assert :ok =
             GenServer.call(
               proxy,
               {:refuse, refuse, %DB.Error{message: "database or disk is full"}}
             )

    normal_runner = lifecycle_runner(db)

    runner = fn
      ["send", "--execute", "--op-id", op] = args ->
        send(parent, {:committed_response, op, normal_runner.(args)})
        projection_failure("send", op, "refused-pause-request")

      args ->
        normal_runner.(args)
    end

    params = %{
      harklight_session: @handle,
      message_type: "fyi",
      title: "Update",
      sender_id: "sender"
    }

    caller =
      Task.async(fn ->
        HarklightSend.send_request(proxy, %{call | params: params}, runner: runner)
      end)

    assert %{code: "internal_error", outcome: "outcome_unknown", op_id: op, reason: reason} =
             Task.await(caller)

    assert eventually(fn -> not Process.alive?(caller.pid) end)
    assert_received {:refused_sql, ^refuse}
    assert_received {:committed_response, ^op, committed}
    assert reason =~ "could not record the recovery pause"
    assert reason =~ "refused-pause-request"
    assert {:ok, []} = DB.query(db, "SELECT opId FROM harklight_operation_pauses")

    no_automatic_retry = fn args -> send(parent, {:unexpected_automatic_retry, args}) end
    assert :ok = HarklightSend.recover_pending(db, runner: no_automatic_retry)
    refute_received {:unexpected_automatic_retry, _}
    assert {:ok, [[^op]]} = DB.query(db, "SELECT opId FROM harklight_operation_guards")

    settle = %{call | params: %{op_id: op}}

    assert %{outcome: "outcome_unknown", op_id: ^op} =
             HarklightSend.settle(db, settle,
               runner: fn ["retry", "--op-id", ^op, "--journal-id", "lifecycle-journal"] ->
                 frame(%{kind: "outcome_unknown", operation: "send", op_id: op, status: 503}, 7)
               end
             )

    assert :ok = HarklightSend.recover_pending(db, runner: no_automatic_retry)
    refute_received {:unexpected_automatic_retry, _}

    assert %{outcome: "committed", message_id: "replacement", op_id: ^op} =
             HarklightSend.settle(db, settle,
               runner: fn ["retry", "--op-id", ^op, "--journal-id", "lifecycle-journal"] ->
                 committed
               end
             )
  end

  test "a supersede naming an outcome_unknown send applies the valid targets and warns for it", %{
    db: db,
    call: call
  } do
    params = fn supersedes ->
      %{
        harklight_session: @handle,
        message_type: "request",
        reply: true,
        sender_id: "sender",
        title: "Replacement",
        supersedes: supersedes
      }
    end

    assert %{outcome: "outcome_unknown", op_id: pending} =
             HarklightSend.send_request(db, %{call | params: params.([])},
               runner: lifecycle_runner(db, unknown: true)
             )

    # A supersede whose only target is the unresolved send is still refused.
    no_op = fn _ -> flunk("a supersede of only an unresolved send ran Harklight") end

    assert %{outcome: "refused", code: "harklight_send_unresolved"} =
             HarklightSend.send_request(db, %{call | params: params.([pending])}, runner: no_op)

    parent = self()
    base = lifecycle_runner(db, message_id: "second-replacement")

    runner = fn args ->
      send(parent, {:harklight_args, args})
      base.(args)
    end

    result =
      HarklightSend.send_request(
        db,
        %{call | params: params.(["request", pending, pending])},
        runner: runner
      )

    assert %{
             outcome: "committed",
             message_id: "second-replacement",
             wake_effect: "subscribed"
           } = result

    assert_received {:harklight_args, ["send", "--prepare" | prepare_args]}

    assert Enum.chunk_every(prepare_args, 2, 1, :discard)
           |> Enum.member?(["--supersedes", "request"])

    refute pending in prepare_args

    assert [
             %{message_id: "request", effect: "ended"},
             %{message_id: ^pending, effect: "unchanged", reason: reason}
           ] = result.supersedes

    assert reason =~ "harklight-settle --op-id #{pending}"

    # The unresolved send is untouched and can still be settled.
    assert %{state: "pending"} = HarklightLifecycle.lookup(db, pending)
    assert %{state: "committed"} = HarklightLifecycle.lookup(db, "second-replacement")
  end

  test "refused send keeps its operation ID and is not recovered again", %{db: db, call: call} do
    runner = lifecycle_runner(db, refused: true)

    result =
      HarklightSend.send_request(
        db,
        %{
          call
          | params: %{
              harklight_session: @handle,
              message_type: "request",
              reply: true,
              sender_id: "sender",
              title: "Replacement"
            }
        },
        runner: runner
      )

    assert %{outcome: "refused", op_id: op, code: "invalid_field", wake_effect: "none"} =
             result

    refute Map.has_key?(result, :message_id)

    assert :ok =
             HarklightSend.recover_pending(db, runner: fn _ -> flunk("refused send retried") end)

    assert %{outcome: "refused", reason: reason} =
             HarklightSend.settle(db, %{call | params: %{op_id: op}})

    assert reason =~ "already settled as refused"
  end

  test "cross-session retract settles the original uncertain operation", %{
    db: db,
    call: call,
    main: main
  } do
    caller = %{
      call
      | session_key: main.session_key,
        principal: {:session, main.session_key},
        transport_session_key: main.session_key,
        params: %{message_id: "request"}
    }

    parent = self()

    uncertain = fn
      ["retract", "--item-id", "server-item", "--op-id", op] = args ->
        send(parent, {:operation, op, args})
        {JSON.encode!(%{kind: "outcome_unknown", op_id: op}), 7}

      args ->
        change_setup_reply(args)
    end

    assert %{outcome: "outcome_unknown", wake_effect: "none", op_id: first} =
             HarklightSend.change_request(db, caller, "retract", runner: uncertain)

    assert_receive {:operation, ^first, saved_request}

    assert %{op_id: ^first, request: ^saved_request, state: "pending"} =
             HarklightLifecycle.lookup_change(db, "request")

    no_op = fn _ -> flunk("unresolved retract ran a new operation") end

    assert %{outcome: "refused", code: "harklight_operation_unresolved"} =
             HarklightSend.change_request(db, caller, "retract", runner: no_op)

    settled =
      HarklightSend.settle(db, caller,
        runner: fn args ->
          assert args == ["retry", "--op-id", first, "--journal-id", "journal-test"]
          change_committed("retract", first, "server-item", 1)
        end
      )

    assert %{
             command: "settle",
             settled_command: "retract",
             outcome: "committed",
             op_id: ^first,
             wake_effect: "ended"
           } = settled

    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_subscription_ends")
  end

  test "revise passes its base revision and keeps the reply subscription", %{db: db, call: call} do
    runner = fn
      [
        "revise",
        "--item-id",
        "server-item",
        "--base-revision",
        "1",
        "--title",
        "Updated",
        "--clear-choices",
        "--op-id",
        key
      ] ->
        change_committed("revise", key, "server-item", 2)

      args ->
        change_setup_reply(args)
    end

    revised = %{
      call
      | params: %{message_id: "request", base_revision: 1, title: "Updated", clear_choices: true}
    }

    assert %{outcome: "committed", message_id: "request", revision: 2, wake_effect: "kept"} =
             HarklightSend.change_request(db, revised, "revise", runner: runner)

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "after revision"))

    assert %{outcome: "refused", reason: "request is at revision 2"} =
             HarklightSend.change_request(db, revised, "revise",
               runner: fn
                 ["revise" | _] -> {"request is at revision 2", 2}
                 args -> change_setup_reply(args)
               end
             )
  end

  describe "a message Tightbeam has no send record for" do
    @other_handle "9b2c1f64-0d58-4e0b-8a8e-6a1f3f3a9c11"
    @loose_op "5f0c7a52-3e0b-4b8d-9d5a-2f6c1d3b7e90"

    defp committed_runner(parent, operation) do
      fn
        ["message-get", "--item-id", "raw-message"] ->
          raw_message_lookup()

        ["message-get", "--sender-id", "sender", "--message-id", "request"] = args ->
          change_setup_reply(args)

        ["journal-id"] ->
          frame(%{kind: "journal", journal_id: "raw-journal"})

        ["retry", "--op-id", key | _] = args ->
          send(parent, {:harklight_args, args})
          change_committed(operation, key, "raw-message", 3)

        [^operation | _] = args ->
          send(parent, {:harklight_args, args})
          item_id = Enum.at(args, 2)
          change_committed(operation, List.last(args), item_id, 3)
      end
    end

    defp raw_message_lookup,
      do: frame(%{message: %{item_id: "raw-message", session: @other_handle, revision: 2}})

    defp assert_no_local_effects(db) do
      for table <- ~w(harklight_subscription_ends harklight_wake_follows) do
        assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM #{table}")
      end
    end

    test "revise reaches Harklight and reports no subscription effect", %{db: db, call: call} do
      revised = %{
        call
        | params: %{
            message_id: "raw-message",
            base_revision: 2,
            title: "Updated",
            handle: @other_handle
          }
      }

      result =
        HarklightSend.change_request(db, revised, "revise",
          runner: committed_runner(self(), "revise")
        )

      assert %{
               outcome: "committed",
               message_id: "raw-message",
               revision: 3,
               wake_effect: "none",
               subscription_effect: "none",
               note: "no subscription effect" <> _
             } = result

      assert_received {:harklight_args, ["revise", "--item-id", "raw-message" | _]}

      assert_no_local_effects(db)
    end

    test "retract reaches Harklight and reports no subscription effect", %{db: db, call: call} do
      retracted = %{call | params: %{message_id: "raw-message", handle: @other_handle}}

      result =
        HarklightSend.change_request(db, retracted, "retract",
          runner: committed_runner(self(), "retract")
        )

      assert %{
               outcome: "committed",
               message_id: "raw-message",
               wake_effect: "none",
               subscription_effect: "none",
               note: "no subscription effect" <> _
             } = result

      assert_received {:harklight_args,
                       [
                         "retract",
                         "--item-id",
                         "raw-message",
                         "--op-id",
                         _
                       ]}

      assert_no_local_effects(db)
    end

    test "settle retries the named operation and reports no subscription effect", %{
      db: db,
      call: call
    } do
      settled = %{call | params: %{message_id: "raw-message", op_id: @loose_op}}

      result = HarklightSend.settle(db, settled, runner: committed_runner(self(), "revise"))

      assert %{
               command: "settle",
               outcome: "committed",
               op_id: @loose_op,
               wake_effect: "none",
               subscription_effect: "none",
               note: "no subscription effect" <> _
             } = result

      assert_received {:harklight_args, ["retry", "--op-id", @loose_op]}
      assert_no_local_effects(db)
    end

    test "an unrecorded uncertain retract can be settled from its saved request", %{
      db: db,
      call: call
    } do
      retracted = %{call | params: %{message_id: "raw-message", handle: @other_handle}}

      assert %{outcome: "outcome_unknown"} =
               HarklightSend.change_request(db, retracted, "retract",
                 runner: fn
                   ["message-get", "--item-id", "raw-message"] ->
                     raw_message_lookup()

                   ["journal-id"] ->
                     frame(%{kind: "journal", journal_id: "raw-journal"})

                   ["retract" | _] = args ->
                     {JSON.encode!(%{kind: "outcome_unknown", op_id: List.last(args)}), 7}
                 end
               )

      assert %{outcome: "committed", wake_effect: "none", subscription_effect: "none"} =
               HarklightSend.settle(db, %{call | params: %{message_id: "raw-message"}},
                 runner: committed_runner(self(), "retract")
               )

      assert_received {:harklight_args, ["retry", "--op-id", _, "--journal-id", "raw-journal"]}
      assert_no_local_effects(db)
    end

    test "Harklight's refusal is passed back, not replaced by a local check", %{
      db: db,
      call: call
    } do
      retracted = %{call | params: %{message_id: "raw-message", handle: @other_handle}}

      assert %{outcome: "refused", code: "harklight_refused", reason: "not your message"} =
               HarklightSend.change_request(db, retracted, "retract",
                 runner: fn
                   ["message-get", "--item-id", "raw-message"] -> raw_message_lookup()
                   ["journal-id"] -> frame(%{kind: "journal", journal_id: "raw-journal"})
                   ["retract" | _] -> {"not your message", 2}
                 end
               )
    end

    test "a missing or malformed flag is refused by name without running Harklight", %{
      db: db,
      call: call
    } do
      no_op = fn _ -> flunk("Harklight ran without the identifier it needs") end

      for command <- ["retract", "revise"] do
        params = %{message_id: "raw-message", base_revision: 1, title: "T"}
        params = if command == "retract", do: Map.take(params, [:message_id]), else: params

        assert %{outcome: "refused", code: "harklight_session_required", reason: reason} =
                 HarklightSend.change_request(db, %{call | params: params}, command,
                   runner: no_op
                 )

        assert reason =~ "--session"

        assert %{outcome: "refused", code: "harklight_session_invalid"} =
                 HarklightSend.change_request(
                   db,
                   %{call | params: Map.put(params, :handle, "--not-a-handle")},
                   command,
                   runner: no_op
                 )
      end

      assert %{outcome: "refused", code: "harklight_op_id_required", reason: reason} =
               HarklightSend.settle(db, %{call | params: %{message_id: "raw-message"}},
                 runner: no_op
               )

      assert reason =~ "--op-id"

      assert %{outcome: "refused", code: "harklight_op_id_invalid"} =
               HarklightSend.settle(
                 db,
                 %{call | params: %{message_id: "raw-message", op_id: "nope"}},
                 runner: no_op
               )
    end

    test "a flag that contradicts the local record is refused", %{db: db, call: call} do
      no_op = fn _ -> flunk("Harklight ran despite a contradicting flag") end

      assert %{outcome: "refused", code: "harklight_session_mismatch"} =
               HarklightSend.change_request(
                 db,
                 %{call | params: %{message_id: "request", handle: @other_handle}},
                 "retract",
                 runner: no_op
               )

      assert %{outcome: "refused", code: "harklight_op_id_mismatch"} =
               HarklightSend.settle(
                 db,
                 %{call | params: %{message_id: "request", op_id: @loose_op}},
                 runner: no_op
               )
    end

    test "the recorded session handle may be repeated without effect on a recorded message", %{
      db: db,
      call: call
    } do
      assert %{outcome: "committed", wake_effect: "ended"} =
               HarklightSend.change_request(
                 db,
                 %{call | params: %{message_id: "request", handle: @handle}},
                 "retract",
                 runner: committed_runner(self(), "retract")
               )
    end
  end

  test "uncertain revise is settled with its original operation ID and saved request", %{
    db: db,
    call: call
  } do
    assert_change_recovery(db, call, "revise", %{
      message_id: "request",
      base_revision: 1,
      title: "Updated",
      body: "Saved text",
      in_reply_to: "chat-entry"
    })
  end

  test "uncertain retract is settled with its original operation ID and saved request", %{
    db: db,
    call: call
  } do
    assert_change_recovery(db, call, "retract", %{
      message_id: "request",
      in_reply_to: "chat-entry"
    })
  end

  for command <- ["revise", "retract"] do
    test "Round 26 preserves correlated #{command} custody after a projection failure", %{
      db: db,
      call: call
    } do
      command = unquote(command)
      params = %{message_id: "request", in_reply_to: "chat-entry"}

      params =
        if command == "revise",
          do: Map.merge(params, %{title: "Updated", base_revision: 1}),
          else: params

      runner = fn
        [^command | _] = args ->
          projection_failure(command, List.last(args), "change-projection")

        args ->
          change_setup_reply(args)
      end

      assert %{outcome: "outcome_unknown", code: "internal_error", reason: reason, op_id: op} =
               HarklightSend.change_request(db, %{call | params: params}, command, runner: runner)

      assert reason =~ "Request-Id change-projection"

      assert %{state: "pending", op_id: ^op, in_reply_to: "chat-entry"} =
               HarklightLifecycle.lookup_change(db, "request")

      assert %{outcome: "committed", settled_command: ^command, op_id: ^op} =
               HarklightSend.settle(db, %{call | params: %{message_id: "request"}},
                 runner: fn ["retry", "--op-id", ^op, "--journal-id", "journal-test"] ->
                   correlated_change_frame(command, op, "chat-entry")
                 end
               )
    end
  end

  test "settlement distinguishes an absent operation from an unavailable journal", %{
    db: db,
    call: call
  } do
    params = %{message_id: "request", base_revision: 1, title: "Updated"}

    assert %{outcome: "outcome_unknown", op_id: key} =
             HarklightSend.change_request(db, %{call | params: params}, "revise",
               runner: fn
                 ["revise" | _] = args ->
                   {JSON.encode!(%{kind: "outcome_unknown", op_id: List.last(args)}), 7}

                 args ->
                   change_setup_reply(args)
               end
             )

    settle = %{call | params: %{message_id: "request"}}

    assert %{outcome: "outcome_unknown"} =
             HarklightSend.settle(db, settle,
               runner: fn ["retry", "--op-id", ^key, "--journal-id", "journal-test"] ->
                 {JSON.encode!(%{kind: "operation_unresolved", op_id: key}), 7}
               end
             )

    assert %{state: "pending"} = HarklightLifecycle.lookup_change(db, "request")

    assert %{outcome: "failed", code: "harklight_operation_absent"} =
             HarklightSend.settle(db, settle,
               runner: fn ["retry", "--op-id", ^key, "--journal-id", "journal-test"] ->
                 {JSON.encode!(%{
                    kind: "operation_absent",
                    op_id: key,
                    journal_id: "journal-test"
                  }), 1}
               end
             )

    assert %{state: "failed"} = HarklightLifecycle.lookup_change(db, "request")
  end

  test "a thrown revise command preserves its saved operation for settlement", %{
    db: db,
    call: call
  } do
    change_call = %{
      call
      | params: %{
          message_id: "request",
          base_revision: 1,
          title: "Updated",
          body: "Saved text"
        }
    }

    assert %{
             outcome: "outcome_unknown",
             code: "harklight_cli_failed",
             op_id: op_id
           } =
             HarklightSend.change_request(db, change_call, "revise",
               runner: fn
                 ["revise" | _] -> raise "connection lost"
                 args -> lifecycle_runner(db).(args)
               end
             )

    assert %{
             op_id: ^op_id,
             request: saved_request,
             state: "pending"
           } = HarklightLifecycle.lookup_change(db, "request")

    assert saved_request == [
             "revise",
             "--item-id",
             "request",
             "--base-revision",
             "1",
             "--title",
             "Updated",
             "--body",
             "Saved text",
             "--op-id",
             op_id
           ]

    assert %{
             command: "settle",
             settled_command: "revise",
             outcome: "committed",
             op_id: ^op_id
           } =
             HarklightSend.settle(db, %{call | params: %{message_id: "request"}},
               runner: fn args ->
                 assert args == ["retry", "--op-id", op_id, "--journal-id", "lifecycle-journal"]

                 frame(%{
                   kind: "committed",
                   operation: "revise",
                   op_id: op_id,
                   response: %{rev: 12, message: %{item_id: "request", revision: 2}}
                 })
               end
             )
  end

  test "a sealed batch gets the pre-retract statement at claim without another wake", %{
    db: db,
    call: call
  } do
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "sealed reply"))
    [carrier] = Tightbeam.NoticeBatcher.recover(db, System.system_time(:millisecond) + 1000)

    assert {:ok, [["queued"]]} =
             DB.query(db, "SELECT status FROM turns WHERE wakeId=?1", [carrier])

    runner = fn
      ["retract", "--item-id", "server-item", "--op-id", op] ->
        change_committed("retract", op, "server-item", 1)

      args ->
        change_setup_reply(args)
    end

    assert %{pending_delivery: [%{event_id: "1"}]} =
             HarklightSend.change_request(
               db,
               %{call | params: %{message_id: "request"}},
               "retract",
               runner: runner
             )

    assert {:ok, turn} = Tightbeam.Ledger.claim_next(db, call.session_key, "sealed-test")
    assert turn.prompt =~ "sealed reply"
    assert turn.prompt =~ "received before message request was retracted"
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "sealed reply"))
    assert [] = Tightbeam.NoticeBatcher.recover(db, System.system_time(:millisecond) + 1000)
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM turns")
  end

  test "an unresolved terminal cannot be overtaken and refusal releases it in feed order", %{
    db: db,
    call: call
  } do
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})
    bind_extra(db, call, "second")

    runner =
      lifecycle_runner(db,
        unknown: true,
        before_commit: fn ->
          assert :ok =
                   HarklightWakes.capture_feed(
                     db,
                     @handle,
                     1,
                     [feed_superseded(1, "request")],
                     :live
                   )

          assert :ok =
                   HarklightWakes.capture_feed(
                     db,
                     @handle,
                     2,
                     [put_in(feed_chat(2, "second", "chat-2"), ["data", "text"], "second entry")],
                     :live
                   )
        end
      )

    assert %{outcome: "outcome_unknown", op_id: pending} =
             HarklightSend.send_request(
               db,
               %{
                 call
                 | params: %{
                     harklight_session: @handle,
                     message_type: "request",
                     reply: true,
                     sender_id: "sender",
                     title: "Replacement",
                     supersedes: ["request"]
                   }
               },
               runner: runner
             )

    assert [] = Tightbeam.NoticeBatcher.recover(db, System.system_time(:millisecond) + 1000)

    assert %{outcome: "refused"} =
             HarklightSend.settle(db, %{call | params: %{op_id: pending}},
               runner: lifecycle_runner(db, refused: true)
             )

    [_carrier] = Tightbeam.NoticeBatcher.recover(db, System.system_time(:millisecond) + 1000)
    assert {:ok, turn} = Tightbeam.Ledger.claim_next(db, call.session_key, "ordered-test")
    assert [before, _after] = String.split(turn.prompt, "second entry", parts: 2)
    assert before =~ "superseded"
    refute_receive {:acked, _}
  end

  test "due scan preserves legacy owner and follower eligibility", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:due")

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

    for cursor <- 1..2 do
      assert :ok =
               HarklightWakes.capture_line(db, @handle, event(cursor, "discussion", "captured"))
    end

    # Include both a historical owner wake without a delivery row and the
    # current owner/follower form in the same production due query.
    assert {:ok, _} =
             DB.query(
               db,
               "DELETE FROM harklight_wake_deliveries WHERE handle=?1 AND eventId='1' AND sessionKey=?2",
               [@handle, call.session_key]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE wakes SET dueAt=0,deliveryRule='turn-boundary-digest r1'"
             )

    assert {:ok, captured} = DB.query(db, "SELECT wakeId,sessionKey FROM wakes")
    assert length(captured) == 4
    host = Placement.local_host_name()

    for {owner_state, owner_host, follower_state, follower_host, owner_ok, follower_ok} <- [
          {"active", host, "active", host, true, true},
          {"active", "another-host", "active", host, false, true},
          {"retired", host, "active", host, false, true},
          {"active", host, "retired", host, true, false},
          {"retired", host, "retired", host, false, false},
          {"active", host, "active", "another-host", true, true}
        ] do
      assert {:ok, _} =
               DB.query(db, "UPDATE sessions SET state=?2,host=?3 WHERE sessionKey=?1", [
                 call.session_key,
                 owner_state,
                 owner_host
               ])

      assert {:ok, _} =
               DB.query(db, "UPDATE sessions SET state=?2,host=?3 WHERE sessionKey=?1", [
                 follower.session_key,
                 follower_state,
                 follower_host
               ])

      expected =
        for [id, session] <- captured,
            (session == call.session_key and owner_ok) or
              (session == follower.session_key and follower_ok),
            into: MapSet.new(),
            do: id

      assert {:ok, rows} = DB.query(db, Tightbeam.Wakes.due_scan_sql(), [1])
      assert MapSet.new(rows, &hd/1) == expected
    end
  end

  test "production due scan searches indexed candidates as captured history grows", %{
    db: db,
    call: call
  } do
    assert {:ok, _} =
             DB.query(
               db,
               """
               WITH RECURSIVE due(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM due WHERE n<3000)
               INSERT INTO wakes(wakeId,sessionKey,origin,consumer,dueAt,state,createdAt,ownerUserId)
               SELECT 'ordinary-due-'||n,?1,'test','test',0,'pending',1,'owner' FROM due
               """,
               [call.session_key]
             )

    for {first, last} <- [{1, 100}, {101, 3000}] do
      assert {:ok, _} =
               DB.query(
                 db,
                 """
                 WITH RECURSIVE history(n) AS (SELECT ?2 UNION ALL SELECT n+1 FROM history WHERE n<?3)
                 INSERT INTO wakes(wakeId,sessionKey,origin,consumer,dueAt,state,createdAt,ownerUserId)
                 SELECT 'captured-history-'||n,?1,'test','test',0,'fired',1,'owner' FROM history
                 """,
                 [call.session_key, first, last]
               )

      assert {:ok, _} =
               DB.query(
                 db,
                 """
                 WITH RECURSIVE history(n) AS (SELECT ?2 UNION ALL SELECT n+1 FROM history WHERE n<?3)
                 INSERT INTO harklight_wake_entries
                   (handle,eventId,feedCursor,senderId,messageId,entryKind,entryAuthor,rawLine,wakeId,capturedAt)
                 SELECT ?1,'history-'||n,n,'sender','request','discussion','person','{}',
                   'captured-history-'||n,1 FROM history
                 """,
                 [@handle, first, last]
               )

      assert {:ok, _} =
               DB.query(
                 db,
                 """
                 INSERT INTO harklight_wake_deliveries(handle,eventId,sessionKey,wakeId)
                 SELECT handle,eventId,?2,wakeId FROM harklight_wake_entries
                 WHERE handle=?1 AND feedCursor BETWEEN ?3 AND ?4
                 """,
                 [@handle, call.session_key, first, last]
               )

      assert {:ok, [[^last]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

      for analyzed <- [false, true] do
        if analyzed, do: assert({:ok, _} = DB.query(db, "ANALYZE"))
        sql = Tightbeam.Wakes.due_scan_sql()
        assert {:ok, [[3000]]} = DB.query(db, "SELECT count(*) FROM (" <> sql <> ")", [1])
        assert {:ok, plan} = DB.query(db, "EXPLAIN QUERY PLAN " <> sql, [1])
        details = Enum.map(plan, &List.last/1)
        refute Enum.any?(details, &Regex.match?(~r/SCAN (e|d)\b/, &1)), inspect(details)

        for table <- ["e", "d"] do
          assert Enum.any?(
                   details,
                   &(String.contains?(&1, "SEARCH " <> table <> " USING") and
                       String.contains?(&1, "wakeId=?"))
                 ),
                 inspect(details)
        end
      end
    end
  end

  test "superseded-terminal lookup uses the sender and target index", %{db: db} do
    assert {:ok, rows} =
             DB.query(
               db,
               "EXPLAIN QUERY PLAN SELECT 1 FROM harklight_pending_supersedes WHERE senderId=?1 AND messageId=?2 LIMIT 1",
               ["sender", "request"]
             )

    assert Enum.any?(rows, fn row ->
             List.last(row) =~
               "SEARCH harklight_pending_supersedes USING COVERING INDEX harklight_pending_supersedes_target"
           end)
  end

  test "schema backfills preexisting pending supersede targets and deduplicates them", %{
    db: db,
    call: call
  } do
    op = Tightbeam.Id.uuid4()

    payload =
      JSON.encode!(%{
        request: %{
          message: %{
            sender_id: "sender",
            message_id: "replacement",
            supersedes: ["request", "request"]
          }
        }
      })

    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, op, payload)

    assert :ok = DB.execute(db, "DROP INDEX harklight_pending_supersedes_target")

    assert :ok = DB.execute(db, "DROP TABLE harklight_pending_supersedes")
    assert :ok = DB.execute(db, "DROP TABLE harklight_pending_supersedes_migration")
    assert :ok = HarklightWakes.ensure_schema(db)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes WHERE opId=?1", [op])

    assert {:ok, _} = DB.query(db, "DELETE FROM harklight_pending_supersedes WHERE opId=?1", [op])

    assert {:ok, _} = DB.query(db, "DELETE FROM harklight_pending_supersedes_migration")

    assert :ok =
             DB.execute(db, """
             CREATE TRIGGER fail_harklight_pending_supersedes_marker
             BEFORE INSERT ON harklight_pending_supersedes_migration
             BEGIN
               SELECT RAISE(ABORT, 'simulated interrupted migration');
             END;
             """)

    assert {:error, _} = HarklightWakes.ensure_schema(db)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes WHERE opId=?1", [op])

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes_migration")

    assert :ok = DB.execute(db, "DROP TRIGGER fail_harklight_pending_supersedes_marker")

    assert :ok = HarklightWakes.ensure_schema(db)
    assert :ok = HarklightWakes.ensure_schema(db)

    assert {:ok, [[^op, "sender", "request"]]} =
             DB.query(
               db,
               "SELECT opId,senderId,messageId FROM harklight_pending_supersedes WHERE opId=?1",
               [op]
             )

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes WHERE opId=?1", [op])

    assert :ok = HarklightWakes.capture_line(db, @handle, terminal(1, "request"))

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_held_terminals WHERE eventId='1'")
  end

  test "preparing a settled pending send does not restore supersede targets", %{
    db: db,
    call: call
  } do
    op = Tightbeam.Id.uuid4()

    payload =
      JSON.encode!(%{
        request: %{
          message: %{sender_id: "sender", message_id: "replacement", supersedes: ["request"]}
        }
      })

    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, op, payload)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes WHERE opId=?1", [op])

    assert {:ok, %{wake_effect: "none"}} = HarklightLifecycle.record_refused(db, op)
    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, op, payload)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes WHERE opId=?1", [op])
  end

  test "superseding another session leaves its terminal wake and never acknowledges it", %{
    db: db,
    call: call,
    main: main
  } do
    other_handle = "e0205d95-f840-460f-951e-2a0f995be13d"

    other_call = %{
      call
      | session_key: main.session_key,
        principal: {:session, main.session_key},
        transport_session_key: main.session_key
    }

    op = Tightbeam.Id.uuid4()

    payload =
      JSON.encode!(%{
        request: %{
          session_handle: other_handle,
          message: %{sender_id: "sender", message_id: "foreign"}
        }
      })

    HarklightWakes.prepare_send(db, other_call, op, payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               other_call,
               op,
               payload,
               "{}",
               other_handle,
               "sender",
               "foreign"
             )

    terminal =
      terminal(1, "foreign")
      |> JSON.decode!()
      |> Map.put("session_handle", other_handle)
      |> JSON.encode!()

    send_fixture =
      lifecycle_runner(db,
        before_commit: fn ->
          assert :ok = HarklightWakes.capture_line(db, other_handle, terminal)
        end
      )

    runner = fn
      ["message-get", "--sender-id", "sender", "--message-id", "foreign"] ->
        frame(%{
          message: %{item_id: "foreign", sender: "sender", session: other_handle, revision: 1}
        })

      args ->
        send_fixture.(args)
    end

    assert %{supersedes: [%{effect: "other_session"}]} =
             HarklightSend.send_request(
               db,
               %{
                 call
                 | params: %{
                     harklight_session: @handle,
                     message_type: "request",
                     reply: true,
                     sender_id: "sender",
                     title: "Replacement",
                     supersedes: ["foreign"]
                   }
               },
               runner: runner
             )

    refute_receive {:acked, _}

    assert {:ok, [[recipient, prompt]]} =
             DB.query(db, "SELECT sessionKey,prompt FROM wakes WHERE wakeId LIKE 'w_harklight_%'")

    assert recipient == main.session_key
    assert prompt =~ "superseded"
  end

  test "a missing migrated supersede target warns while the remaining targets proceed", %{
    db: db,
    call: call
  } do
    assert %{state: "registered"} = bind_extra(db, call, "missing")
    send_fixture = lifecycle_runner(db, warnings: [%{message_id: "external", reason: "closed"}])

    runner = fn
      ["message-get", "--sender-id", "sender", "--message-id", "missing"] ->
        missing_legacy_item()

      ["send", "--prepare" | fields] = args ->
        assert Enum.take(fields, -4) == [
                 "--supersedes",
                 "server-item",
                 "--supersedes",
                 "external"
               ]

        send_fixture.(args)

      ["message-get" | _] = args ->
        change_setup_reply(args)

      args ->
        send_fixture.(args)
    end

    call = %{
      call
      | params: %{
          harklight_session: @handle,
          sender_id: "sender",
          title: "Replacement",
          message_type: "fyi",
          supersedes: ["missing", "request", "external", "missing"]
        }
    }

    assert %{
             outcome: "committed",
             supersedes: [
               %{message_id: "missing", effect: "unchanged", reason: "unknown"},
               %{message_id: "request", effect: "ended"},
               %{message_id: "external", effect: "unchanged", reason: "closed"}
             ]
           } = HarklightSend.send_request(db, call, runner: runner)
  end

  test "a prepare failure has no invented message ID and shows unchanged supersede effects", %{
    db: db,
    call: call
  } do
    result =
      HarklightSend.send_request(
        db,
        %{
          call
          | params: %{
              harklight_session: @handle,
              message_type: "request",
              reply: true,
              sender_id: "sender",
              title: "Replacement",
              supersedes: ["request", "request"]
            }
        },
        runner: fn
          ["send", "--prepare" | _] -> raise "executable unavailable"
          args -> lifecycle_runner(db).(args)
        end
      )

    assert %{
             outcome: "failed",
             wake_effect: "none",
             supersedes: [%{message_id: "request", effect: "unchanged"}],
             reason: reason
           } = result

    refute Map.has_key?(result, :message_id)
    assert reason =~ "could not complete"
    assert reason =~ "not sent"
    assert result.sender_id == "sender"
  end

  test "message and conversation follows overlap once per session and entry", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:one")
    second_follower = follower_session(db, main, "agent:follower:two")
    message_call = follow_call(call, follower, %{message_id: "request"})
    conversation_call = follow_call(call, follower, %{handle: @handle})
    runner = lifecycle_runner(db)

    assert %{
             command: "follow",
             following: "message",
             outcome: "committed",
             wake_effect: "subscribed",
             message_id: "request",
             handle: @handle,
             sender_id: "sender"
           } = follow_for_test(db, message_call, runner: runner)

    assert %{outcome: "committed", following: "conversation", wake_effect: "subscribed"} =
             follow_for_test(db, conversation_call, runner: runner)

    assert %{outcome: "committed", wake_effect: "kept"} =
             follow_for_test(db, message_call, runner: runner)

    assert %{outcome: "committed", wake_effect: "subscribed"} =
             follow_for_test(
               db,
               follow_call(call, second_follower, %{message_id: "request"}),
               runner: runner
             )

    assert %{outcome: "committed", wake_effect: "kept"} =
             follow_for_test(db, follow_call(call, call, %{message_id: "request"}),
               runner: runner
             )

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_follows WHERE sessionKey=?1 AND kind='message'",
               [call.session_key]
             )

    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "Reply"))

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_deliveries WHERE handle=?1 AND eventId='1' AND sessionKey=?2",
               [@handle, follower.session_key]
             )

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_deliveries WHERE handle=?1 AND eventId='1' AND sessionKey=?2",
               [@handle, second_follower.session_key]
             )

    assert {:ok, [[owner_prompt]]} =
             DB.query(db, "SELECT prompt FROM wakes WHERE sessionKey=?1", [call.session_key])

    assert {:ok, [[follower_prompt]]} =
             DB.query(db, "SELECT prompt FROM wakes WHERE sessionKey=?1", [follower.session_key])

    assert follower_prompt == owner_prompt

    assert Enum.count(
             follow_for_test(db, conversation_call, runner: runner).subscriptions,
             &(&1.follower == follower.session_key and &1.kind == "conversation" and
                 &1.state == "open")
           ) == 1
  end

  test "a follow starts at its transaction and does not gain earlier captured entries", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:coverage")
    runner = lifecycle_runner(db)
    entry = event(1, "discussion", "Already captured")

    assert :ok = HarklightWakes.capture_line(db, @handle, entry)

    assert %{outcome: "committed"} =
             follow_for_test(db, follow_call(call, follower, %{message_id: "request"}),
               runner: runner
             )

    assert :ok = HarklightWakes.capture_line(db, @handle, entry)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [follower.session_key])

    assert :ok = HarklightWakes.capture_line(db, @handle, event(2, "discussion", "New reply"))

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [follower.session_key])
  end

  test "unknown and unresolved messages refuse without recording a follow", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:unknown")
    runner = lifecycle_runner(db)

    assert %{outcome: "refused", wake_effect: "none", reason: message_reason} =
             follow_for_test(db, follow_call(call, follower, %{message_id: "raw-message"}),
               runner: runner
             )

    assert message_reason =~
             "only messages and conversations sent through tightbeam harklight-send"

    assert %{outcome: "refused", wake_effect: "none", reason: handle_reason} =
             follow_for_test(db, follow_call(call, follower, %{handle: "raw-handle"}),
               runner: runner
             )

    assert handle_reason =~
             "only messages and conversations sent through tightbeam harklight-send"

    pending_op = Tightbeam.Id.uuid4()

    pending_payload =
      JSON.encode!(%{
        request: %{
          session_handle: @handle,
          message: %{sender_id: "sender", message_id: "pending-message"}
        }
      })

    assert %{state: "pending"} =
             HarklightWakes.prepare_send(db, call, pending_op, pending_payload)

    assert %{
             outcome: "refused",
             wake_effect: "none",
             message_id: "pending-message",
             reason: unresolved_reason
           } =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "pending-message"}),
               runner: runner
             )

    assert unresolved_reason =~ "is unresolved"
    assert unresolved_reason =~ "tightbeam harklight-settle --message pending-message"

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_follows WHERE sessionKey=?1", [
               follower.session_key
             ])
  end

  test "an answered item remains followable and accepts a later chat", %{
    db: db,
    call: call,
    main: main,
    session: session
  } do
    follower = follower_session(db, main, "agent:follower:answered")

    answer = %{
      "kind" => "message",
      "rev" => 12,
      "data" => %{
        "item_id" => "request",
        "session" => @handle,
        "revision" => 1,
        "sender" => "sender",
        "terminal" => %{"state" => "answered", "at_ms" => 172, "answer" => nil}
      }
    }

    assert :ok = HarklightWakes.capture_feed(db, @handle, 12, [answer], :live)
    follow_call = follow_call(call, follower, %{handle: @handle})

    assert %{outcome: "committed", wake_effect: "subscribed"} =
             follow_for_test(db, follow_call,
               runner: fn argv -> flunk("unexpected read: #{inspect(argv)}") end
             )

    assert :ok =
             HarklightWakes.capture_feed(
               db,
               @handle,
               15,
               [feed_chat(15, "request", "chat")],
               :live
             )

    assert {:ok, [["active"]]} = DB.query(db, "SELECT state FROM harklight_wake_handles")

    assert {:ok, receivers} =
             DB.query(db, """
             SELECT d.sessionKey FROM harklight_wake_deliveries d
             JOIN harklight_wake_entries e ON e.handle=d.handle AND e.eventId=d.eventId
             WHERE e.entryKind='discussion' ORDER BY d.sessionKey
             """)

    assert Enum.sort(receivers) == Enum.sort([[follower.session_key], [session.session_key]])
  end

  test "following requires the existing conversation origin host rule", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:remote-origin")

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET host='other-host' WHERE handle=?1",
               [@handle]
             )

    result =
      follow_for_test(
        db,
        follow_call(call, follower, %{message_id: "request"}),
        runner: fn _ -> flunk("status must not run outside the conversation origin host") end
      )

    assert %{
             command: "follow",
             following: "message",
             outcome: "failed",
             wake_effect: "none",
             message_id: "request",
             handle: @handle,
             sender_id: "sender",
             code: "harklight_origin_unavailable"
           } = result

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_follows WHERE sessionKey=?1", [
               follower.session_key
             ])
  end

  test "self supersede delivers follower terminals and keeps conversation follows open",
       %{db: db, call: call, main: main} do
    message_follower = follower_session(db, main, "agent:follower:message")
    conversation_follower = follower_session(db, main, "agent:follower:conversation")
    runner = lifecycle_runner(db)

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, message_follower, %{message_id: "request"}),
               runner: runner
             )

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, conversation_follower, %{handle: @handle}),
               runner: runner
             )

    supersede_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement",
          supersedes: ["request"]
        }
    }

    assert %{outcome: "committed", supersedes: [%{effect: "ended"}]} =
             HarklightSend.send_request(db, supersede_call, runner: runner)

    assert :ok =
             HarklightWakes.capture_feed(db, @handle, 1, [feed_superseded(1, "request")], :live)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               message_follower.session_key
             ])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               conversation_follower.session_key
             ])

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [call.session_key])

    assert {:ok, [["ended"]]} =
             DB.query(
               db,
               "SELECT state FROM harklight_wake_follows WHERE sessionKey=?1 AND kind='message'",
               [message_follower.session_key]
             )

    assert {:ok, [["open"]]} =
             DB.query(
               db,
               "SELECT state FROM harklight_wake_follows WHERE sessionKey=?1 AND kind='conversation'",
               [conversation_follower.session_key]
             )

    HarklightLifecycle.process_terminals(db, runner: runner)
    refute_receive {:acked, _}

    assert :ok =
             HarklightWakes.capture_feed(
               db,
               @handle,
               2,
               [
                 put_in(
                   feed_chat(2, "request", "chat-2"),
                   ["data", "text"],
                   "Old conversation entry"
                 )
               ],
               :live
             )

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [call.session_key])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               message_follower.session_key
             ])

    assert {:ok, [[2]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE sessionKey=?1",
               [conversation_follower.session_key]
             )

    assert :ok =
             HarklightWakes.capture_feed(
               db,
               @handle,
               3,
               [
                 put_in(
                   feed_chat(3, "replacement", "chat-3"),
                   ["data", "text"],
                   "Replacement reply"
                 )
               ],
               :live
             )

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               message_follower.session_key
             ])

    assert {:ok, [[3]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               conversation_follower.session_key
             ])
  end

  test "another-session supersede wakes the sender and message followers but excludes the caller",
       %{db: db, call: call, main: main} do
    message_follower = follower_session(db, main, "agent:follower:other-message")
    caller = follower_session(db, main, "agent:follower:other-caller")
    runner = lifecycle_runner(db)

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, message_follower, %{message_id: "request"}),
               runner: runner
             )

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, caller, %{handle: @handle}),
               runner: runner
             )

    payload =
      JSON.encode!(%{
        request: %{
          message: %{
            sender_id: "sender",
            message_id: "replacement-other",
            supersedes: ["request"]
          }
        }
      })

    assert {:ok, effects} =
             DB.transaction(db, fn txn ->
               HarklightLifecycle.send_committed_in_txn(
                 txn,
                 caller.session_key,
                 "cross-session-operation",
                 payload,
                 JSON.encode!(%{supersedes_warnings: []})
               )
             end)

    assert [%{effect: "other_session"}] = effects.supersedes
    assert :ok = HarklightWakes.capture_line(db, @handle, terminal(1, "request"))

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [call.session_key])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               message_follower.session_key
             ])

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [caller.session_key])

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_subscription_ends WHERE senderId='sender' AND messageId='request'"
             )

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(2, "discussion", "Still open to sender")
             )

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [call.session_key])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               message_follower.session_key
             ])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [caller.session_key])
  end

  test "retract ends message follows and preserves pending deliveries for each recipient", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:retract")
    conversation_follower = follower_session(db, main, "agent:follower:retract-conversation")

    assert %{outcome: "committed"} =
             follow_for_test(db, follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, conversation_follower, %{handle: @handle}),
               runner: lifecycle_runner(db)
             )

    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "Pending reply"))
    record = HarklightLifecycle.lookup(db, "request")
    effects = HarklightLifecycle.retract_committed(db, record, "retract-operation")

    assert effects.wake_effect == "ended"

    assert Enum.map(effects.pending_delivery, & &1.session_key) |> Enum.sort() ==
             Enum.sort([
               call.session_key,
               follower.session_key,
               conversation_follower.session_key
             ])

    assert {:ok, [["ended"]]} =
             DB.query(
               db,
               "SELECT state FROM harklight_wake_follows WHERE sessionKey=?1 AND kind='message'",
               [follower.session_key]
             )

    assert {:ok, [["open"]]} =
             DB.query(
               db,
               "SELECT state FROM harklight_wake_follows WHERE sessionKey=?1 AND kind='conversation'",
               [conversation_follower.session_key]
             )

    assert %{state: "registered"} = bind_extra(db, call, "next-request")

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(2, "discussion", "After retract", "next-request")
             )

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [follower.session_key])

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               conversation_follower.session_key
             ])
  end

  test "an open follow restores listening after restart when its sender session is retired", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:restart")

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET vendorSessionId='saved-vendor' WHERE handle=?1",
               [@handle]
             )

    assert {:ok, _} =
             DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
               call.session_key
             ])

    test_pid = self()

    listener = fn manager, handle, vendor_id ->
      send(test_pid, {:listener_started, handle, vendor_id})
      :ok = GenServer.call(manager, {:feed_ready, handle})

      receive do
        :stop -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})

    assert_receive {:listener_started, @handle, "saved-vendor"}
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "After restart"))

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [follower.session_key])
  end

  test "Handoff receipt follows prompt dispatch for each person entry on the delivered turn", %{
    db: db,
    main: main,
    session: session
  } do
    follower = follower_session(db, main, "agent:follower:receipt")
    owner_turn = running_receipt_turn!(db, session.session_key)
    follower_turn = running_receipt_turn!(db, follower.session_key)

    receipt_fixture_entry!(
      db,
      @handle,
      "101",
      session.session_key,
      owner_turn.seq,
      "discussion",
      "person"
    )

    receipt_fixture_entry!(
      db,
      @handle,
      "102",
      session.session_key,
      owner_turn.seq,
      "terminal",
      "person"
    )

    receipt_fixture_entry!(
      db,
      @handle,
      "103",
      session.session_key,
      owner_turn.seq,
      "terminal",
      "server"
    )

    receipt_fixture_entry!(db, @handle, "104", session.session_key, nil, "discussion", "person")

    receipt_fixture_entry!(
      db,
      @handle,
      "105",
      follower.session_key,
      follower_turn.seq,
      "discussion",
      "person"
    )

    receipt_fixture_entry!(
      db,
      @handle,
      "106",
      session.session_key,
      owner_turn.seq,
      "discussion",
      "agent"
    )

    test_pid = self()

    runner = fn args ->
      send(test_pid, {:receipt, args})
      receipt_success()
    end

    assert :ok =
             receipt_for_test(
               db,
               owner_turn.seq,
               session.session_key,
               session.display_name,
               runner: runner
             )

    refute_receive {:receipt, _args}

    record_prompt_dispatched!(db, owner_turn)

    assert :ok =
             receipt_for_test(
               db,
               owner_turn.seq,
               session.session_key,
               session.display_name,
               runner: runner
             )

    assert_receive {:receipt,
                    ["receipt", "--item-id", "request", "--entry-id", "101", "--agent", "Origin"]}

    assert_receive {:receipt, ["receipt", "--item-id", "request", "--agent", "Origin"]}

    refute_receive {:receipt, _args}

    record_prompt_dispatched!(db, follower_turn)

    assert :ok =
             receipt_for_test(
               db,
               follower_turn.seq,
               follower.session_key,
               follower.display_name,
               runner: runner
             )

    assert_receive {:receipt,
                    [
                      "receipt",
                      "--item-id",
                      "request",
                      "--entry-id",
                      "105",
                      "--agent",
                      agent_name,
                      "--rerouted"
                    ]}

    assert agent_name == follower.display_name

    refute_receive {:receipt, _args}
  end

  test "Handoff receipt follows discussion retry lineage without treating dispatch as custody receipt",
       %{
         db: db,
         session: session
       } do
    assert :ok =
             HarklightWakes.capture_feed(db, @handle, 1, [feed_chat(1, "request", "1")], :live)

    assert {:ok, [[root]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    first = deliver_discussion_turn!(db, root, session.session_key)
    assert :ok = Ledger.finish(db, first.seq, "failed", nil, owner_lease: first.owner_lease)
    test_pid = self()

    runner = fn args ->
      send(test_pid, {:retry_receipt, args})
      receipt_success()
    end

    Enum.reduce(1..2, root, fn attempt, source ->
      assert {:ok, [[retry]]} =
               DB.query(db, "SELECT retryWakeId FROM wake_retry_attempts WHERE wakeId=?1", [
                 source
               ])

      turn = deliver_discussion_turn!(db, retry, session.session_key)
      assert :ok = Ledger.stamp_adapter(db, turn.seq, 1)

      assert :ok =
               receipt_for_test(
                 db,
                 turn.seq,
                 session.session_key,
                 session.display_name,
                 runner: runner
               )

      refute_receive {:retry_receipt, _}
      record_prompt_dispatched!(db, turn)

      assert :ok =
               receipt_for_test(
                 db,
                 turn.seq,
                 "agent:unrelated",
                 "Other",
                 runner: runner
               )

      refute_receive {:retry_receipt, _}

      assert :ok =
               receipt_for_test(
                 db,
                 turn.seq,
                 session.session_key,
                 session.display_name,
                 runner: runner
               )

      if attempt == 1 do
        assert_receive {:retry_receipt,
                        [
                          "receipt",
                          "--item-id",
                          "request",
                          "--entry-id",
                          "1",
                          "--agent",
                          "Origin"
                        ]}
      end

      refute_receive {:retry_receipt, _}

      terminal = if attempt == 1, do: "failed_unknown", else: "delivered"
      assert :ok = Ledger.finish(db, turn.seq, terminal, nil, owner_lease: turn.owner_lease)

      if attempt == 1 do
        assert {:ok, [[next]]} =
                 DB.query(db, "SELECT retryWakeId FROM wake_retry_attempts WHERE wakeId=?1", [
                   retry
                 ])

        assert is_binary(next)
      else
        assert {:ok, [["acted", nil]]} =
                 DB.query(
                   db,
                   "SELECT outcome,retryWakeId FROM wake_retry_attempts WHERE wakeId=?1",
                   [retry]
                 )
      end

      retry
    end)
  end

  test "Harklight wake instructions leave Handoff receipt to the receiving system", %{db: db} do
    assert :ok =
             HarklightWakes.capture_feed(db, @handle, 1, [feed_chat(1, "request", "1")], :live)

    assert {:ok, [[prompt]]} = DB.query(db, "SELECT prompt FROM wakes")
    assert prompt =~ "harklight-agent reply --item-id request --in-reply-to 1"
    refute prompt =~ "harklight-agent receipt"
  end

  defp follow_for_test(db, call, opts),
    do: HarklightFollows.follow(db, call, Keyword.put(opts, :activate, false))

  defp running_receipt_turn!(db, session_key) do
    message_id = "receipt-test-#{System.unique_integer([:positive])}"

    assert {:ok, seq} =
             Ledger.enqueue(db, %{
               session_key: session_key,
               message_id: message_id,
               origin: "process:tightbeam",
               prompt: "Handoff receipt fixture turn"
             })

    assert {:ok, %{seq: ^seq, owner_lease: _lease} = turn} =
             Ledger.claim_next(db, session_key, "receipt-test")

    assert :ok = Ledger.stamp_adapter(db, seq, 1)
    turn
  end

  defp health_receipt_redelivery!(db, receiver, lineage, original_dispatched \\ false) do
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})

    assert :ok =
             HarklightWakes.capture_feed(
               db,
               @handle,
               1,
               [feed_chat(1, "request", "health-chat")],
               :live
             )

    assert {:ok, [[wake]]} =
             DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries WHERE sessionKey=?1", [
               receiver.session_key
             ])

    Wakes.schedule(db, %{
      session_key: receiver.session_key,
      origin: "agent:peer",
      prompt: "Mixed carrier fixture",
      due_at: 1,
      class: "fyi"
    })

    Tightbeam.NoticeBatcher.recover(db, System.system_time(:millisecond) + 1_000)
    assert {:ok, original} = Ledger.claim_next(db, receiver.session_key, "original-receipt")
    assert original.wake_id != wake
    assert original.prompt =~ "Mixed carrier fixture"

    if original_dispatched do
      assert :ok = Ledger.stamp_adapter(db, original.seq, 1)
      record_prompt_dispatched!(db, original, "Original display")
    end

    assert :ok = Ledger.finish(db, original.seq, "failed", nil, owner_lease: original.owner_lease)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Wakes.record_health_redelivery_source_in_txn(txn, original.seq, "unclassified")
             end)

    if lineage == :cycle_release, do: mark_receipt_cycle_release!(db, receiver, original.seq)

    assert {:ok, healthy} =
             Ledger.enqueue(db, %{
               session_key: receiver.session_key,
               message_id: "normal-restoration-turn",
               origin: "agent:peer",
               prompt: "Normal restoration"
             })

    assert {:ok, %{seq: ^healthy} = restoration} =
             Ledger.claim_next(db, receiver.session_key, "restoration-test")

    assert :ok =
             Ledger.finish(db, healthy, "delivered", nil, owner_lease: restoration.owner_lease)

    assert {:ok, 1} =
             DB.transaction(db, fn txn ->
               Wakes.redeliver_pending_health_intents_in_txn(txn, receiver, restoration)
             end)

    assert {:ok, [[normal, cycle]]} =
             DB.query(
               db,
               "SELECT redeliveryTurnSeq,cycleReleaseTurnSeq FROM health_redelivery_attempts WHERE sourceTurnSeq=?1",
               [original.seq]
             )

    replacement =
      case {lineage, normal, cycle} do
        {:restoration, seq, nil} when is_integer(seq) -> seq
        {:cycle_release, nil, seq} when is_integer(seq) -> seq
      end

    assert {:ok, [["queued", nil]]} =
             DB.query(db, "SELECT status,wakeId FROM turns WHERE seq=?1", [replacement])

    {wake, original, replacement}
  end

  defp mark_receipt_cycle_release!(db, receiver, original) do
    observation = %{
      correlation_id: "fixture-health-open",
      harness: to_string(receiver.harness),
      host: receiver.host,
      failure_class: "auth-dead",
      evidence_kind: "authoritative-provider",
      session_key: receiver.session_key,
      observed_at: System.system_time(:millisecond),
      cause: "Test provider refusal",
      principal: "process:tightbeam"
    }

    assert {:opened, _} = Tightbeam.HarnessHealth.observe(db, observation)
    correlation = "fixture-health-resolution"

    assert {:resolved, _} =
             Tightbeam.HarnessHealth.resolve(db, %{
               observation
               | correlation_id: correlation,
                 cause: "Test provider recovery"
             })

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE health_redelivery_attempts SET cycleReleaseCorrelation=?2 WHERE sourceTurnSeq=?1",
               [original, correlation]
             )
  end

  defp record_prompt_dispatched!(db, turn, name \\ nil) do
    detail = if name, do: %{v: 1, harklight_receipt_agent: name}, else: %{v: 1}

    assert :ok =
             TurnLifecycle.append(db, turn.seq, %{
               event_key: "prompt:dispatched",
               producer_event_id: "fixture:receipt:#{turn.seq}",
               kind: "prompt_dispatched",
               stage: "prompt",
               outcome: "dispatched",
               cause: "acp:port-write",
               principal: "process:tightbeam",
               owner_lease: turn.owner_lease,
               adapter_gen: 1,
               acp_request_id: turn.seq,
               detail: detail
             })
  end

  defp receipt_fixture_entry!(db, handle, event_id, session_key, turn_seq, kind, author) do
    wake_id = "receipt_fixture_#{event_id}_#{System.unique_integer([:positive])}"

    assert %{wake_id: ^wake_id} =
             Wakes.schedule(db, %{
               wake_id: wake_id,
               session_key: session_key,
               origin: "process:tightbeam",
               prompt: "Handoff receipt fixture entry",
               due_at: System.system_time(:millisecond)
             })

    if is_integer(turn_seq) do
      assert {:ok, _} =
               DB.query(db, "UPDATE wakes SET deliveredTurnSeq=?2 WHERE wakeId=?1", [
                 wake_id,
                 turn_seq
               ])
    end

    cursor = String.to_integer(event_id)

    raw_line =
      if kind == "terminal" do
        JSON.encode!(%{
          "kind" => "message",
          "item_id" => "request",
          "data" => %{"terminal" => %{"state" => "answered"}}
        })
      else
        JSON.encode!(%{
          "kind" => "entry",
          "item_id" => "request",
          "data" => %{"entry_id" => event_id}
        })
      end

    assert {:ok, _} =
             DB.query(
               db,
               """
               INSERT INTO harklight_wake_entries
                 (handle,eventId,feedCursor,senderId,messageId,requestRevision,entryKind,entryAuthor,rawLine,wakeId,capturedAt)
               VALUES(?1,?2,?3,'sender','request',1,?4,?5,?6,?7,?8)
               """,
               [
                 handle,
                 event_id,
                 cursor,
                 kind,
                 author,
                 raw_line,
                 wake_id,
                 System.system_time(:millisecond)
               ]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_wake_deliveries(handle,eventId,sessionKey,wakeId) VALUES(?1,?2,?3,?4)",
               [handle, event_id, session_key, wake_id]
             )

    :ok
  end

  defp receipt_for_test(db, seq, session_key, _name, opts) do
    case DB.query(db, "SELECT 1 FROM turns WHERE seq=?1 AND sessionKey=?2", [seq, session_key]) do
      {:ok, [[1]]} ->
        runner = opts |> Keyword.fetch!(:runner) |> receipt_fixture_runner()
        assert {:ok, false} = HarklightReceipts.drain(db, MapSet.new([seq]), runner: runner)

      {:ok, []} ->
        :ok
    end

    :ok
  end

  defp receipt_fixture_runner(caller_runner) do
    fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "fixture-journal"})

      ["retry", "--op-id", op, "--journal-id", journal] ->
        {JSON.encode!(%{kind: "operation_absent", op_id: op, journal_id: journal}), 1}

      ["receipt" | _] = args ->
        {argv, ["--op-id", op]} = Enum.split(args, -2)
        {reply, 0} = caller_runner.(argv)
        frame(Map.put(JSON.decode!(reply), "op_id", op))
    end
  end

  defp receipt_result(op) do
    frame(%{kind: "committed", operation: "receipt", op_id: op, response: %{status: "recorded"}})
  end

  defp receipt_success do
    {JSON.encode!(%{
       "kind" => "committed",
       "operation" => "receipt",
       "response" => %{"status" => "recorded"}
     }), 0}
  end

  defp assert_change_recovery(db, call, command, params) do
    request_call = %{call | params: params}
    settle_call = %{call | params: %{message_id: "request"}}
    parent = self()

    uncertain_runner = fn
      [^command | _] = args ->
        op_id = List.last(args)

        assert {:ok, [[payload, nil, "pending"]]} =
                 DB.query(
                   db,
                   "SELECT payload,result,state FROM harklight_send_operations WHERE opId=?1",
                   [op_id]
                 )

        decoded = JSON.decode!(payload)
        assert decoded["operation_kind"] == "change"
        assert decoded["command"] == command
        assert decoded["message_id"] == "request"
        assert decoded["request"] == args

        if entry = params[:in_reply_to] do
          assert ["--in-reply-to", entry] in Enum.chunk_every(args, 2, 1, :discard)
          assert decoded["in_reply_to"] == entry
        end

        send(parent, {:external_change_request, command, args})

        if params[:in_reply_to] do
          change_committed(command, op_id, "server-item", 2)
        else
          {JSON.encode!(%{kind: "outcome_unknown", op_id: op_id}), 7}
        end

      args ->
        change_setup_reply(args)
    end

    assert %{
             command: ^command,
             outcome: "outcome_unknown",
             op_id: op_id,
             reason: reason
           } = HarklightSend.change_request(db, request_call, command, runner: uncertain_runner)

    assert reason =~ "harklight-settle"
    assert_receive {:external_change_request, ^command, saved_request}

    assert %{op_id: ^op_id, request: ^saved_request, state: "pending"} =
             HarklightLifecycle.lookup_change(db, "request")

    no_op = fn _ -> flunk("unresolved change operation ran a new request") end

    assert %{outcome: "refused", code: "harklight_operation_unresolved"} =
             HarklightSend.change_request(db, request_call, command, runner: no_op)

    if params[:in_reply_to] do
      assert %{outcome: "outcome_unknown", code: "harklight_result_mismatch", op_id: ^op_id} =
               HarklightSend.settle(db, settle_call,
                 runner: fn ["retry", "--op-id", ^op_id, "--journal-id", "journal-test"] ->
                   correlated_change_frame(command, op_id, "different-entry")
                 end
               )

      assert %{op_id: ^op_id, state: "pending"} = HarklightLifecycle.lookup_change(db, "request")

      assert {:ok, []} =
               DB.query(
                 db,
                 "SELECT state FROM harklight_subscription_ends WHERE messageId='request'"
               )
    end

    settled =
      HarklightSend.settle(db, settle_call,
        runner: fn args ->
          assert args == ["retry", "--op-id", op_id, "--journal-id", "journal-test"]

          assert %{op_id: ^op_id, request: ^saved_request, state: "pending"} =
                   HarklightLifecycle.lookup_change(db, "request")

          case params[:in_reply_to] do
            nil -> change_committed(command, op_id, "server-item", 2)
            entry -> correlated_change_frame(command, op_id, entry)
          end
        end
      )

    assert %{
             command: "settle",
             settled_command: ^command,
             outcome: "committed",
             op_id: ^op_id
           } = settled

    assert %{op_id: ^op_id, request: ^saved_request, state: "committed"} =
             HarklightLifecycle.lookup_change(db, "request")

    assert :ok = HarklightSend.recover_pending(db, runner: no_op)

    assert %{outcome: "refused", reason: reason} =
             HarklightSend.settle(db, settle_call, runner: no_op)

    assert reason =~ "already settled as committed"

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_send_operations WHERE json_extract(payload,'$.operation_kind')='change' AND json_extract(payload,'$.message_id')=?1",
               ["request"]
             )
  end

  defp correlated_change_frame(command, op, entry) do
    frame(%{
      kind: "committed",
      operation: command,
      op_id: op,
      response: %{
        rev: 12,
        message: %{item_id: "server-item", revision: 2},
        entry: %{
          item_id: "server-item",
          entry_id: entry,
          author: "person",
          kind: "reply",
          delivery: %{acted: true}
        }
      }
    })
  end

  defp change_committed(operation, key, item, revision) do
    frame(%{
      kind: "committed",
      operation: operation,
      op_id: key,
      response: %{rev: 12, message: %{item_id: item, revision: revision}}
    })
  end

  defp change_setup_reply(["journal-id"]),
    do: frame(%{kind: "journal", journal_id: "journal-test"})

  defp change_setup_reply(["message-get", "--sender-id", "sender", "--message-id", "request"]),
    do: frame(%{message: %{item_id: "server-item", sender: "sender", session: @handle}})

  defp send_prepared_frame(op, handle, prepared) do
    frame(%{
      kind: "prepared",
      operation: "send",
      op_id: op,
      request_id: op,
      session_handle: handle,
      prepared: prepared
    })
  end

  defp send_committed_frame(op, handle, sender, item, prepared) do
    frame(%{
      kind: "committed",
      operation: "send",
      op_id: op,
      request_id: op,
      item_id: item,
      prepared: prepared,
      response: %{rev: 1, message: %{item_id: item, sender: sender, session: handle, revision: 1}}
    })
  end

  defp frame(value, status \\ 0), do: {JSON.encode!(value) <> "\n", status}

  defp projection_failure(operation, op_id, request_id) do
    frame(
      %{
        kind: "outcome_unknown",
        operation: operation,
        op_id: op_id,
        status: 500,
        error: "internal_error",
        retryable: false,
        request_id: request_id
      },
      7
    )
  end

  defp missing_legacy_item do
    {reply, 0} =
      frame(%{kind: "refused", operation: "message-get", status: 404, error: "not_found"})

    {reply <> ~s|server returned HTTP 404: Some("not_found") (request ID None)\n|, 2}
  end

  defp bind_extra(db, call, message) do
    op = Tightbeam.Id.uuid4()

    payload =
      JSON.encode!(%{
        request: %{session_handle: @handle, message: %{sender_id: "sender", message_id: message}}
      })

    HarklightWakes.prepare_send(db, call, op, payload)
    HarklightWakes.bind_send(db, call, op, payload, "{}", @handle, "sender", message)
  end

  defp terminal(cursor, message) do
    event(cursor, "terminal", "", message)
    |> JSON.decode!()
    |> Map.put("entry", %{
      "kind" => "terminal",
      "author" => "server",
      "terminal_state" => "superseded"
    })
    |> JSON.encode!()
  end

  # These frames exercise local custody and operation handling, not claims
  # about a deployed Harklight service. Their shape follows the CLI interface.
  defp lifecycle_runner(db, opts \\ []) do
    fn args ->
      case args do
        ["journal-id"] ->
          frame(%{kind: "journal", journal_id: "lifecycle-journal"})

        ["message-get", "--sender-id", sender, "--message-id", id] ->
          frame(%{message: %{item_id: id, sender: sender, session: @handle, revision: 1}})

        ["send", "--prepare" | fields] ->
          {op, metadata} = lifecycle_prepared(fields)

          frame(%{
            kind: "prepared",
            operation: "send",
            op_id: op,
            request_id: op,
            session_handle: @handle,
            prepared: metadata
          })

        ["send", "--execute", "--op-id", op] ->
          lifecycle_execution(db, op, opts)

        ["retry", "--op-id", op, "--journal-id", "lifecycle-journal"] ->
          lifecycle_execution(db, op, opts)

        _ ->
          flunk("unexpected Agent 0.2 fixture command: #{inspect(args)}")
      end
    end
  end

  defp lifecycle_prepared(fields) do
    value = fn flag ->
      fields |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)
    end

    supersedes =
      Enum.chunk_every(fields, 2, 1, :discard)
      |> Enum.flat_map(fn
        ["--supersedes", id] -> [id]
        _ -> []
      end)

    message = %{title: value.("--title"), message_type: value.("--type"), body: value.("--body")}

    {value.("--op-id"),
     %{
       sender: value.("--sender-id"),
       session: @handle,
       message: message,
       files: [],
       supersedes: supersedes,
       supersedes_local: []
     }}
  end

  defp lifecycle_execution(db, op, opts) do
    assert {:ok, [[payload]]} =
             DB.query(db, "SELECT payload FROM harklight_send_operations WHERE opId=?1", [op])

    if callback = opts[:before_commit], do: callback.()

    cond do
      opts[:unknown] ->
        {JSON.encode!(%{kind: "outcome_unknown", op_id: op}), 7}

      opts[:refused] ->
        {JSON.encode!(%{kind: "refused", operation: "send", op_id: op, error: "invalid_field"}),
         2}

      true ->
        prepared = JSON.decode!(payload)["request"]["prepared"]
        item = opts[:message_id] || "replacement"

        advisories =
          if contradictions = opts[:possible_contradictions],
            do: [Map.put(contradictions, :advisory_type, "possible_contradictions")],
            else: []

        warnings =
          Enum.map(opts[:warnings] || [], fn warning ->
            %{
              item_id: warning[:message_id] || warning["message_id"],
              reason: warning[:reason] || warning["reason"]
            }
          end)

        frame(%{
          kind: "committed",
          operation: "send",
          op_id: op,
          request_id: op,
          item_id: item,
          prepared: prepared,
          response: %{
            rev: 12,
            message: %{
              item_id: item,
              sender: prepared["sender"],
              session: @handle,
              revision: 1,
              advisories: advisories
            },
            supersedes_warnings: warnings
          }
        })
    end
  end

  defp event(id, kind, content, message_id \\ "request") do
    JSON.encode!(%{
      "kind" => "event",
      "session_handle" => @handle,
      "event_id" => Integer.to_string(id),
      "feed_cursor" => id,
      "request" => %{"sender_id" => "sender", "message_id" => message_id},
      "request_revision" => 1,
      "delivered" => false,
      "acted" => false,
      "entry" => %{"kind" => kind, "author" => "person", "content" => content}
    })
  end

  defp follower_session(db, main, key) do
    Org.create(db, %{
      session_key: key,
      display_name: "Follower #{key}",
      owner_user_id: "owner",
      origin: "user:owner",
      spawned_by: main.session_key,
      archetype: "default",
      host: Placement.local_host_name(),
      harness: "codex",
      provider: "openai",
      model: Model.new("fable")
    })
  end

  defp follow_call(call, session, params) do
    %{
      call
      | session_key: session.session_key,
        principal: {:session, session.session_key},
        transport_session_key: session.session_key,
        params: params
    }
  end

  defp fake_harklight_agent!(body) do
    directory =
      Path.join(System.tmp_dir!(), "harklight-agent-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    executable = Path.join(directory, "harklight-agent")
    File.write!(executable, "#!/bin/sh\n" <> body)
    File.chmod!(executable, 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", Enum.join([directory, previous_path] |> Enum.reject(&is_nil/1), ":"))

    on_exit(fn ->
      if is_nil(previous_path),
        do: System.delete_env("PATH"),
        else: System.put_env("PATH", previous_path)

      File.rm_rf!(directory)
    end)
  end

  defp fake_harklight_session_end_agent!(exit_status \\ 0, opts \\ []) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "harklight-session-end-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    executable = Path.join(directory, "harklight-agent")
    calls = Path.join(directory, "calls.log")

    wait_for_session_end =
      if Keyword.get(opts, :wait_for_session_end, false) do
        "if [ \"$1\" = \"session\" ]; then\n" <>
          "  while [ ! -e \"#{calls}.release\" ]; do sleep 0.01; done\n" <>
          "fi\n"
      else
        ""
      end

    File.write!(
      executable,
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"#{calls}\"\n" <>
        wait_for_session_end <>
        "if [ \"$1\" = \"session\" ]; then printf '%s\\n' '#{exit_status}' > \"#{calls}.exit-status\"; fi\n" <>
        "exit #{exit_status}\n"
    )

    File.chmod!(executable, 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", Enum.join([directory, previous_path] |> Enum.reject(&is_nil/1), ":"))

    on_exit(fn ->
      File.write!(calls <> ".release", "continue")

      if is_nil(previous_path),
        do: System.delete_env("PATH"),
        else: System.put_env("PATH", previous_path)

      File.rm_rf!(directory)
    end)

    calls
  end

  defp completion_event(handle, cursor, message_id, kind, author, channel \\ nil) do
    entry = %{"kind" => kind, "author" => author}

    entry =
      if kind == "terminal",
        do: Map.merge(entry, %{"terminal_state" => "answered", "terminal_kind" => "answer"}),
        else: Map.put(entry, "content", "message")

    event = %{
      "kind" => "event",
      "session_handle" => handle,
      "event_id" => Integer.to_string(cursor),
      "feed_cursor" => cursor,
      "request" => %{"sender_id" => "sender", "message_id" => message_id},
      "request_revision" => 1,
      "delivered" => false,
      "acted" => false,
      "entry" => entry
    }

    if channel, do: Map.put(event, "channel", channel), else: event
  end

  defp seed_completion_handle(db, session_key, handle, message_id) do
    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_wake_handles(handle,sessionKey,host,state,createdAt,updatedAt) VALUES(?1,?2,?3,'active',?4,?4)",
               [handle, session_key, Placement.local_host_name(), now]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_wake_requests(senderId,messageId,handle) VALUES('sender',?1,?2)",
               [message_id, handle]
             )
  end

  defp mark_completion_wakes_delivered(db, handle, excluded_sessions \\ []) do
    assert {:ok, rows} =
             DB.query(
               db,
               "SELECT wakeId,sessionKey FROM harklight_wake_deliveries WHERE handle=?1 ORDER BY eventId,sessionKey",
               [handle]
             )

    for [wake_id, session_key] <- Enum.uniq_by(rows, &hd/1),
        session_key not in excluded_sessions do
      assert {:ok, _} =
               DB.query(
                 db,
                 "INSERT INTO turns(sessionKey,messageId,wakeId,origin,prompt,status,createdAt) VALUES(?1,?2,?3,'process:test','delivered source wake','delivered',?4) ON CONFLICT(wakeId) DO UPDATE SET status='delivered'",
                 [session_key, Tightbeam.Id.uuid4(), wake_id, System.system_time(:millisecond)]
               )

      assert {:ok, [[turn_seq]]} =
               DB.query(db, "SELECT seq FROM turns WHERE wakeId=?1", [wake_id])

      assert {:ok, _} =
               DB.query(
                 db,
                 "UPDATE wakes SET state='fired',firedAt=?3,deliveredTurnSeq=?2 WHERE wakeId=?1",
                 [wake_id, turn_seq, System.system_time(:millisecond)]
               )
    end
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
