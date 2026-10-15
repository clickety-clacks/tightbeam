defmodule Tightbeam.NoticeRecipientRoutingTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Archetypes, DB, Gateway, Ledger, Model, NoticeBatcher, Org, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  defmodule SelectionRace do
    use GenServer
    def start_link({db, change}), do: GenServer.start_link(__MODULE__, {db, change})
    def init(state), do: {:ok, state}

    def handle_call({:transaction_then, _, _} = request, _from, {db, change}) do
      result = GenServer.call(db, request, :infinity)
      if change, do: change.()
      {:reply, result, {db, nil}}
    end

    def handle_call(request, _from, {db, change}) do
      {:reply, GenServer.call(db, request, :infinity), {db, change}}
    end
  end

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = ensure_all_schemas(db)
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1)")
    main = ensure_main_session(db, "owner")
    create_session(db, "previous-recipient", main.session_key)
    create_session(db, "later-recipient", main.session_key)
    create_session(db, "quiet-child", main.session_key)

    directory =
      Path.join(System.tmp_dir!(), "notice-routing-#{System.unique_integer([:positive])}")

    Archetypes.load!(directory)
    registry = :"notice_routing_registry_#{System.unique_integer([:positive])}"
    lane = :"notice_routing_lane_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.ConnRegistry, name: registry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, lane})
    previous = Application.get_env(:tightbeam, :effort_checkin_horizon_ms)
    Application.put_env(:tightbeam, :effort_checkin_horizon_ms, 60_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tightbeam, :effort_checkin_horizon_ms, previous),
        else: Application.delete_env(:tightbeam, :effort_checkin_horizon_ms)
    end)

    %{db: db, current: main.session_key, opts: [conn_registry: registry, lane_manager: lane]}
  end

  for kind <- [:terminal, :idle_cleanup],
      stored_busy <- [false, true],
      current_busy <- [false, true] do
    test "#{kind} uses the current recipient with stored busy=#{stored_busy}, current busy=#{current_busy}",
         ctx do
      kind = unquote(kind)
      stored_busy = unquote(stored_busy)
      current_busy = unquote(current_busy)
      wake = source!(ctx, kind)
      if stored_busy, do: busy!(ctx.db, "previous-recipient")
      current_turn = if current_busy, do: busy!(ctx.db, ctx.current)
      before = Wakes.get(ctx.db, wake.wake_id)
      assert before.session_key == "previous-recipient"
      at = System.system_time(:millisecond)

      {carriers, prepared} = recover_traced(ctx, ctx.db, at)

      if current_busy do
        assert carriers == []
        assert prepared == []
        assert Wakes.get(ctx.db, wake.wake_id) == before
        assert NoticeBatcher.source_refs(ctx.db, wake.wake_id) == []
        finish!(ctx.db, current_turn)
        {carriers, prepared} = recover_traced(ctx, ctx.db, System.system_time(:millisecond))
        assert prepared == [wake.wake_id]
        assert_delivered_once!(ctx, wake, carriers)
      else
        assert prepared == [wake.wake_id]
        assert_delivered_once!(ctx, wake, carriers)
      end

      assert NoticeBatcher.recover(ctx.db, System.system_time(:millisecond), ctx.opts) == []

      assert {:ok, [[0]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM notice_batches WHERE sessionKey='previous-recipient'"
               )
    end
  end

  for kind <- [:terminal, :idle_cleanup] do
    @tag new_read_only_api: true
    test "resolving the current #{kind} recipient writes no rows", ctx do
      kind = unquote(kind)
      before = source!(ctx, kind)
      at = System.system_time(:millisecond)
      # Resolving a recipient cannot update the source, expire an incident or
      # publish even a diagnostic event, including when routing is stale.
      assert {:ok, :ok} =
               DB.transaction(ctx.db, fn txn ->
                 [[changes]] = Txn.q(txn, "SELECT total_changes()")

                 case kind do
                   :terminal ->
                     assert {:ok, target} = Wakes.terminal_notice_target_in_txn(txn, before)
                     assert target == ctx.current

                   :idle_cleanup ->
                     assert {:idle_cleanup, target} =
                              Supervision.idle_cleanup_target_in_txn(txn, before, at)

                     assert target == ctx.current
                 end

                 assert [[changes]] == Txn.q(txn, "SELECT total_changes()")
                 :ok
               end)
    end
  end

  test "a terminal recipient becoming busy after selection is not prepared or delivered to the old owner",
       ctx do
    wake = source!(ctx, :terminal)
    busy = busy!(ctx.db, "later-recipient")

    proxy =
      start_supervised!(
        {SelectionRace,
         {ctx.db,
          fn ->
            {:ok, _} =
              DB.query(
                ctx.db,
                "UPDATE work_items SET deliveryOwnerSessionKey='later-recipient' WHERE id='work'"
              )
          end}}
      )

    assert {[], []} = recover_traced(ctx, proxy, System.system_time(:millisecond))
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"
    assert NoticeBatcher.source_refs(ctx.db, wake.wake_id) == []
    finish!(ctx.db, busy)
    ctx = %{ctx | current: "later-recipient"}
    {carriers, prepared} = recover_traced(ctx, ctx.db, System.system_time(:millisecond))
    assert prepared == [wake.wake_id]
    assert_delivered_once!(ctx, wake, carriers)
  end

  test "cleanup membership changing after selection cannot deliver the stale prompt", ctx do
    wake = source!(ctx, :idle_cleanup)

    proxy =
      start_supervised!(
        {SelectionRace,
         {ctx.db,
          fn ->
            Wakes.schedule(ctx.db, %{
              session_key: "quiet-child",
              origin: "user:owner",
              prompt: "new work",
              due_at: System.system_time(:millisecond) + 60_000
            })
          end}}
      )

    assert {[], []} = recover_traced(ctx, proxy, System.system_time(:millisecond))
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"
    assert NoticeBatcher.source_refs(ctx.db, wake.wake_id) == []
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM notice_batches")
  end

  test "95 notices for 54 recipients prepare only each free recipient's own notices once", ctx do
    recipients = for n <- 1..54, do: "recipient-#{n}"
    for key <- recipients, do: create_session(ctx.db, key, ctx.current)
    busy = recipients |> Enum.take(27) |> MapSet.new()
    for key <- busy, do: busy!(ctx.db, key)
    at = System.system_time(:millisecond)

    sources =
      for n <- 0..94 do
        target = Enum.at(recipients, rem(n, 54))

        wake =
          Wakes.schedule(ctx.db, %{
            session_key: target,
            origin: "user:owner",
            prompt: "notice #{n}",
            due_at: at,
            sender_scheduled: true
          })

        {wake, target}
      end

    {carriers, prepared} = recover_traced(ctx, ctx.db, at + 1)
    counts = Enum.frequencies(prepared)
    assert length(carriers) == 27

    assert length(prepared) ==
             Enum.count(sources, fn {_, target} -> not MapSet.member?(busy, target) end)

    for {wake, target} <- sources do
      if MapSet.member?(busy, target) do
        assert Map.get(counts, wake.wake_id, 0) == 0
        assert Wakes.get(ctx.db, wake.wake_id).state == "pending"
        assert NoticeBatcher.source_refs(ctx.db, wake.wake_id) == []
      else
        assert counts[wake.wake_id] == 1

        assert [%{member_state: "included", delivery_wake_id: carrier}] =
                 NoticeBatcher.source_refs(ctx.db, wake.wake_id)

        assert carrier in carriers
      end
    end
  end

  defp source!(ctx, :terminal) do
    now = System.system_time(:millisecond)

    :ok =
      DB.execute(ctx.db, """
      INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdAt,deliveryOwnerSessionKey)
        VALUES('work','work','owner','open','owner',1,'previous-recipient');
      INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,workItemId)
        VALUES('assignment','work','quiet-child','owner',1,'work');
      INSERT INTO attests(id,assignmentId,kind,bySession,ts)
        VALUES('completion','assignment','completion','quiet-child',#{now});
      UPDATE assignments SET state='closed',outcome='completed',closedAt=#{now},closedBySession='quiet-child',closingAttestId='completion' WHERE id='assignment';
      """)

    assert {:ok, {:ok, wake}} =
             DB.transaction(ctx.db, &Wakes.admit_terminal_notification_in_txn(&1, "assignment"))

    assert wake.session_key == "previous-recipient"

    {:ok, _} =
      DB.query(ctx.db, "UPDATE work_items SET deliveryOwnerSessionKey=?1 WHERE id='work'", [
        ctx.current
      ])

    wake
  end

  defp source!(ctx, :idle_cleanup) do
    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET createdAt=1,updatedAt=1 WHERE sessionKey='quiet-child'"
      )

    process =
      start_supervised!(
        {Supervision,
         db: ctx.db, handlers: Gateway.handlers(%{db: ctx.db}), sweep_ms: 60_000, name: nil}
      )

    :sys.get_state(process)
    stop_supervised!(Supervision)

    assert [wake] =
             Enum.filter(
               Wakes.list_pending(ctx.db),
               &String.starts_with?(&1.obligation_ref || "", "idle-cleanup-v1:")
             )

    assert wake.session_key == ctx.current
    # The cached address can lag the authoritative group/member evidence.
    # Keep that evidence and prompt intact while exercising an older address.
    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET sessionKey='previous-recipient' WHERE wakeId=?1", [
        wake.wake_id
      ])

    Wakes.get(ctx.db, wake.wake_id)
  end

  defp create_session(db, key, parent) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "owner",
      origin: "user:owner",
      spawned_by: parent,
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "testhost"
    })
  end

  defp busy!(db, key) do
    assert {:ok, _} =
             Ledger.enqueue(db, %{
               session_key: key,
               message_id: "message-#{System.unique_integer([:positive])}",
               origin: "user:owner",
               prompt: "work in progress"
             })

    assert {:ok, turn} = Ledger.claim_next(db, key, "fixture")
    turn
  end

  defp finish!(db, turn),
    do: Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

  defp recover_traced(ctx, db, at) do
    mfa = {NoticeBatcher, :prepared_source_in_txn, 2}
    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(ctx.db, true, [:call, {:tracer, self()}])

    try do
      result = NoticeBatcher.recover(db, at, ctx.opts)
      barrier = :erlang.trace_delivered(ctx.db)
      assert_receive {:trace_delivered, _, ^barrier}
      {result, preparations(ctx.db, [])}
    after
      :erlang.trace(ctx.db, false, [:call])
      :erlang.trace_pattern(mfa, false, [:local])
    end
  end

  defp preparations(db, acc) do
    receive do
      {:trace, ^db, :call, {NoticeBatcher, :prepared_source_in_txn, [_txn, id]}} ->
        preparations(db, [id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_delivered_once!(ctx, wake, carriers) do
    assert [carrier] = carriers

    assert [%{member_state: "included", delivery_wake_id: ^carrier}] =
             NoticeBatcher.source_refs(ctx.db, wake.wake_id)

    assert {:ok, [[target, prompt]]} =
             DB.query(ctx.db, "SELECT sessionKey,prompt FROM turns WHERE wakeId=?1", [carrier])

    assert target == ctx.current
    assert String.contains?(prompt, wake.prompt)
    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"
  end
end
