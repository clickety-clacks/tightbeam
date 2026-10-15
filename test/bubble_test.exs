defmodule Tightbeam.Productions.BubbleTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    ConditionFacts,
    ConnRegistry,
    DB,
    HarnessHealth,
    Ledger,
    Model,
    NoticeBatcher,
    Org
  }

  alias Tightbeam.Productions.Bubble

  defmodule LaneDoorbell do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(state), do: {:ok, state}
    def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
  end

  defmodule RecognitionRefusal do
    use GenServer
    def start_link(db), do: GenServer.start_link(__MODULE__, db)
    def init(db), do: {:ok, %{db: db, refuse: true}}
    def handle_call(:allow, _from, state), do: {:reply, :ok, %{state | refuse: false}}

    def handle_call({:query, sql, _params} = request, _from, state) do
      sweep_query? =
        String.contains?(sql, "production_cursors") or
          String.contains?(sql, "SELECT seq, endedAt")

      if state.refuse and not sweep_query? do
        {:reply, {:error, %DB.Error{message: "recognition temporarily refused"}}, state}
      else
        {:reply, GenServer.call(state.db, request), state}
      end
    end

    def handle_call(request, _from, state), do: {:reply, GenServer.call(state.db, request), state}
  end

  # Exercise the real registry implementation until the first terminal-alert
  # transaction has committed, then disconnect that local publication handoff.
  defmodule OwnerAlertDisconnect do
    use GenServer
    def start_link(args), do: GenServer.start_link(__MODULE__, args, name: Tightbeam.ConnRegistry)

    def init({db, observer}) do
      {:ok, registry} = Tightbeam.ConnRegistry.init(:ok)
      {:ok, %{db: db, observer: observer, registry: registry}}
    end

    def handle_call({:publish_message, _, _, _, _, _} = request, from, state) do
      {:ok, [[completed]]} =
        Tightbeam.DB.query(
          state.db,
          "SELECT COUNT(*) FROM lifecycle_events WHERE kind='lineage_exhausted'"
        )

      if completed > 0 do
        send(state.observer, {:owner_alert_committed, completed})
        {:stop, :owner_alert_publication_interrupted, state}
      else
        forward(request, from, state)
      end
    end

    def handle_call(request, from, state), do: forward(request, from, state)

    defp forward(request, from, state) do
      {:reply, reply, registry} =
        Tightbeam.ConnRegistry.handle_call(request, from, state.registry)

      {:reply, reply, %{state | registry: registry}}
    end
  end

  # Select a real active ancestor, then temporarily remove its row only
  # during the real delivery transaction. Gateway must observe no_session_row;
  # the exact row is restored before commit and FK enforcement is restored.
  defmodule MissingTargetDB do
    use GenServer
    import ExUnit.Assertions
    def start_link(args), do: GenServer.start_link(__MODULE__, args)

    def init({db, target, observer}),
      do: {:ok, %{db: db, target: target, observer: observer, armed: false, used: false}}

    def handle_call(
          {:query, "SELECT state FROM sessions WHERE sessionKey = ?1", [target]} = request,
          _from,
          %{target: target, used: false} = state
        ) do
      response = GenServer.call(state.db, request)
      assert {:ok, [["active"]]} = response
      {:reply, response, %{state | armed: true}}
    end

    def handle_call({:transaction, fun}, _from, %{armed: true} = state) do
      response =
        Tightbeam.DB.migration_transaction(
          state.db,
          :bubble_missing_target,
          ["PRAGMA foreign_keys=OFF"],
          ["PRAGMA foreign_keys=ON"],
          fn txn ->
            [row] =
              Tightbeam.DB.Txn.q(txn, "SELECT rowid,* FROM sessions WHERE sessionKey=?1", [
                state.target
              ])

            Tightbeam.DB.Txn.q(txn, "DELETE FROM sessions WHERE sessionKey=?1", [state.target])

            assert [] ==
                     Tightbeam.DB.Txn.q(txn, "SELECT 1 FROM sessions WHERE sessionKey=?1", [
                       state.target
                     ])

            result = fun.(txn)

            columns = [
              "rowid"
              | Enum.map(Tightbeam.DB.Txn.q(txn, "PRAGMA table_info(sessions)"), &Enum.at(&1, 1))
            ]

            names = Enum.map_join(columns, ",", &"\"#{&1}\"")
            placeholders = 1..length(row) |> Enum.map_join(",", &"?#{&1}")
            Tightbeam.DB.Txn.q(txn, "INSERT INTO sessions(#{names}) VALUES(#{placeholders})", row)

            assert [row] ==
                     Tightbeam.DB.Txn.q(txn, "SELECT rowid,* FROM sessions WHERE sessionKey=?1", [
                       state.target
                     ])

            result
          end
        )

      send(state.observer, {:real_missing_target_delivery, state.target})
      {:reply, response, %{state | armed: false, used: true}}
    end

    def handle_call(request, _from, state), do: {:reply, GenServer.call(state.db, request), state}
  end

  # The spec's proofs 2–4 (production-machine-v1 §Proofs): the climb is
  # delivery-driven, the terminal alert is tokenless and stands as a fact,
  # and retraction is observed. Lineage under test:
  #
  #   main (flynn's personal session, parentless)
  #     └─ supervisor
  #          └─ holder
  setup tags do
    case ConnRegistry.start_link(name: Tightbeam.ConnRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # The bubble's notice enqueue rings the real LaneManager name; answer the
    # doorbell so delivery completes without a lane runtime in the test.
    start_supervised!({LaneDoorbell, Tightbeam.LaneManager})

    db = :"bubble_db_#{System.unique_integer([:positive])}"

    db_opts =
      if tags[:persistent] do
        base =
          Path.join(System.tmp_dir!(), "bubble-persistent-#{System.unique_integer([:positive])}")

        prepared = Tightbeam.GuardRuntimeFixture.prepare!(base, "schema_shape_runtime.exs")
        on_exit(fn -> File.rm_rf!(base) end)

        [
          path: Path.join(prepared.base, "state.db"),
          name: db,
          guard_inputs: [],
          payload_root: prepared.payload
        ]
      else
        [path: ":memory:", name: db]
      end

    start_supervised!({DB, db_opts})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    main = session(db, Org.personal_session_key("flynn"), nil, true)
    supervisor = session(db, "supervisor", main.session_key)
    holder = session(db, "holder", supervisor.session_key)

    %{db: db, db_opts: db_opts, main: main, supervisor: supervisor, holder: holder}
  end

  defp session(db, key, spawned_by, built_in? \\ false) do
    session =
      Org.create(db, %{
        session_key: key,
        display_name: key,
        kind: if(built_in?, do: "main", else: "custom"),
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        harness: "claude",
        provider: "anthropic",
        host: "testhost",
        model: Model.new("fable"),
        spawned_by: spawned_by,
        is_built_in: built_in?
      })

    session
  end

  # An ordinary failing turn, made honestly: delivered into the session's
  # queue through the one turn sink, claimed, and finished into `terminal`.
  defp fail_turn!(db, session_key, terminal \\ "failed", error \\ "quota exhausted") do
    :appended =
      Tightbeam.Gateway.deliver_prompt(session_key, "user:flynn", "do the thing",
        db: db,
        device_id: "test",
        client_message_id: "cause-#{System.unique_integer([:positive])}"
      )

    {:ok, turn} = Ledger.claim_next(db, session_key, "test-lane")
    :ok = Ledger.finish(db, turn.seq, terminal, error, owner_lease: turn.owner_lease)
    turn.seq
  end

  defp fail_assigned_turn!(db, session_key, assignment_id) do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "assigned-cause-#{System.unique_integer([:positive])}",
        origin: "user:flynn",
        prompt: "assigned work",
        assignment_id: assignment_id
      })

    assert {:ok, %{seq: ^seq} = turn} = Ledger.claim_next(db, session_key, "assigned-cause")

    assert :ok =
             Ledger.finish(db, seq, "failed", "assigned failure", owner_lease: turn.owner_lease)

    seq
  end

  defp cannot_proceed_assignment!(
         ctx,
         holder_session,
         opener_session,
         subject,
         extra_params \\ %{}
       ) do
    assignment =
      Assignments.__handle__(ctx.db, "assign", %{
        verb: "assign",
        origin: "agent:#{opener_session}",
        principal: {:session, opener_session},
        session_key: holder_session,
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{subject: subject, idempotency_key: nil, work_item_id: nil}
      })

    blocked =
      Assignments.__handle__(ctx.db, "attest", %{
        verb: "attest",
        origin: "agent:#{holder_session}",
        principal: {:session, holder_session},
        session_key: nil,
        params:
          Map.merge(
            %{
              assignment_id: assignment.id,
              kind: "cannot-proceed",
              note: "the opener must decide"
            },
            extra_params
          )
      })

    {assignment.id, blocked}
  end

  defp prewrite_restore!(db, turn, expected_finish \\ true) do
    evidence =
      Tightbeam.NoticeSubmission.prewrite_evidence(
        :prompt,
        {:acp_request_not_dispatched, {:transport_capacity_exceeded, 201, 200}}
      )

    assert {:ok, successors} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", "local prewrite refusal",
                        owner_lease: turn.owner_lease,
                        prewrite_evidence: evidence
                      ) == expected_finish

               Tightbeam.NoticeSubmission.restore_in_txn(txn, turn, evidence)
             end)

    successors
  end

  defp hold_recipient!(db, session_key) do
    assert {:ok, seq} =
             Ledger.enqueue(db, %{
               session_key: session_key,
               message_id: "busy-recipient-#{System.unique_integer([:positive])}",
               origin: "user:flynn",
               prompt: "hold recipient before carrier delivery"
             })

    assert {:ok, turn} = Ledger.claim_next(db, session_key, "bubble-busy-recipient")
    assert turn.seq == seq
    turn
  end

  defp finish_busy_recipient!(db, turn) do
    assert :ok = Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)
  end

  defp queue_decision_wake!(ctx, decision_wake) do
    assert :queued =
             Tightbeam.Gateway.deliver_prompt(
               decision_wake.session_key,
               decision_wake.origin,
               decision_wake.prompt,
               db: ctx.db,
               wake_id: decision_wake.wake_id,
               sender: decision_wake.origin,
               device_id: "test",
               client_message_id: decision_wake.wake_id,
               target_gate: decision_wake,
               fire_wake_in_txn: true
             )
  end

  defp deliver_decision_carrier!(ctx, recipient) do
    [carrier_id] = deliver_ready_carriers!(ctx, recipient)
    Tightbeam.Wakes.get(ctx.db, carrier_id)
  end

  defp deliver_ready_carriers!(ctx, recipient, delivered \\ [], rounds \\ 0)

  defp deliver_ready_carriers!(_ctx, _recipient, delivered, rounds) when rounds >= 8,
    do: Enum.reverse(delivered)

  defp deliver_ready_carriers!(ctx, recipient, delivered, rounds) do
    carrier_ids = NoticeBatcher.recover(ctx.db, System.system_time(:millisecond) + 1_000)

    matching_carriers =
      carrier_ids
      |> Enum.map(&Tightbeam.Wakes.get(ctx.db, &1))
      |> Enum.filter(&(&1.session_key == recipient))

    Enum.each(matching_carriers, fn carrier ->
      assert {:ok, [[^recipient, "queued"]]} =
               DB.query(ctx.db, "SELECT sessionKey,status FROM turns WHERE wakeId=?1", [
                 carrier.wake_id
               ])

      # The readiness transaction already appended the actual turn. Re-appending
      # here would test an artificial duplicate, not the carrier's admission.
    end)

    case matching_carriers do
      [] ->
        Enum.reverse(delivered)

      carriers ->
        deliver_ready_carriers!(
          ctx,
          recipient,
          Enum.map(carriers, & &1.wake_id) ++ delivered,
          rounds + 1
        )
    end
  end

  defp notice_turn(db, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT seq, requestRef, wakeId, origin, prompt FROM turns WHERE sessionKey = ?1 AND requestRef LIKE 'bubble:%' ORDER BY seq",
        [session_key]
      )

    rows
  end

  defp fail_wake!(ctx, status, error \\ "private provider detail") do
    sender = session(ctx.db, "wake-sender", ctx.main.session_key)
    busy = hold_recipient!(ctx.db, ctx.holder.session_key)

    wake =
      Tightbeam.Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        creator_session_key: sender.session_key,
        origin: "user:flynn",
        prompt: "private carried intent",
        due_at: 0
      })

    delivery =
      Tightbeam.Gateway.deliver_prompt(ctx.holder.session_key, wake.origin, wake.prompt,
        db: ctx.db,
        wake_id: wake.wake_id,
        fire_wake_in_txn: true
      )

    assert delivery == :queued
    finish_busy_recipient!(ctx.db, busy)
    deliver_ready_carriers!(ctx, ctx.holder.session_key)

    assert {:ok, turn} = Ledger.claim_next(ctx.db, ctx.holder.session_key, "wake-fixture")
    assert :ok = Ledger.finish(ctx.db, turn.seq, status, error, owner_lease: turn.owner_lease)
    {wake, turn, sender}
  end

  for status <- ["failed", "failed_unknown"] do
    @delivery_status status
    test "#{status} names the carried wake and records one sender result without retry", ctx do
      {wake, turn, sender} = fail_wake!(ctx, @delivery_status)
      assert :ok = Bubble.recognize_terminal(ctx.db, turn.seq)
      assert :ok = Bubble.recognize_terminal(ctx.db, turn.seq)

      assert [[_, _, _, _, prompt]] = notice_turn(ctx.db, ctx.supervisor.session_key)
      assert prompt =~ "carrying delivery wake #{turn.wake_id}"
      assert prompt =~ "source wake(s) #{wake.wake_id}"

      assert {:ok, [[content, "substrate", "process:tightbeam", 1]]} =
               DB.query(
                 ctx.db,
                 "SELECT content,messageType,sender,attentionTier FROM messages WHERE sessionKey=?1 AND clientMessageId=?2",
                 [sender.session_key, "wake-undelivered:#{turn.seq}"]
               )

      assert content =~ wake.wake_id
      assert content =~ @delivery_status
      refute content =~ "private provider detail"
      refute content =~ wake.prompt

      if @delivery_status == "failed_unknown",
        do: assert(content =~ "prior effects must be reconciled")

      assert Ledger.pending_count(ctx.db, sender.session_key) == 0
      assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM wake_retry_attempts")
      assert Tightbeam.Wakes.get(ctx.db, wake.wake_id).state == "fired"

      # Exhaust the actual ancestor climb. Each rung names both the failed
      # delivery carrier and the durable source wake it carried.
      assert {:ok, parent_notice} =
               Ledger.claim_next(ctx.db, ctx.supervisor.session_key, "fixture")

      assert :ok =
               Ledger.finish(ctx.db, parent_notice.seq, "failed", "notice failed",
                 owner_lease: parent_notice.owner_lease
               )

      assert :ok = Bubble.recognize_terminal(ctx.db, parent_notice.seq)
      assert {:ok, main_notice} = Ledger.claim_next(ctx.db, ctx.main.session_key, "fixture")

      assert :ok =
               Ledger.finish(ctx.db, main_notice.seq, "failed", "notice failed",
                 owner_lease: main_notice.owner_lease
               )

      assert :ok = Bubble.recognize_terminal(ctx.db, main_notice.seq)

      assert {:ok, [[alert]]} =
               DB.query(
                 ctx.db,
                 "SELECT content FROM messages WHERE sessionKey=?1 AND content LIKE '[no agent can act]%'",
                 [ctx.main.session_key]
               )

      assert alert =~ "carrying delivery wake #{turn.wake_id}"
      assert alert =~ "source wake(s) #{wake.wake_id}"
    end
  end

  test "a failed mixed carrier reports each source only to its own sender", ctx do
    sender_a = session(ctx.db, "mixed-sender-a", ctx.main.session_key)
    sender_b = session(ctx.db, "mixed-sender-b", ctx.main.session_key)

    wake_a =
      Tightbeam.Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        creator_session_key: sender_a.session_key,
        origin: "user:flynn",
        prompt: "private intent alpha",
        due_at: 0
      })

    wake_b =
      Tightbeam.Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        creator_session_key: sender_b.session_key,
        origin: "user:flynn",
        prompt: "private intent beta",
        due_at: 0
      })

    for wake <- [wake_a, wake_b] do
      assert :queued =
               Tightbeam.Gateway.deliver_prompt(
                 ctx.holder.session_key,
                 wake.origin,
                 wake.prompt,
                 db: ctx.db,
                 wake_id: wake.wake_id,
                 fire_wake_in_txn: true
               )
    end

    [carrier_id] = deliver_ready_carriers!(ctx, ctx.holder.session_key)

    assert [%{delivery_wake_id: ^carrier_id}] =
             Tightbeam.NoticeBatcher.source_refs(ctx.db, wake_a.wake_id)

    assert [%{delivery_wake_id: ^carrier_id}] =
             Tightbeam.NoticeBatcher.source_refs(ctx.db, wake_b.wake_id)

    assert {:ok, turn} = Ledger.claim_next(ctx.db, ctx.holder.session_key, "mixed-failure")
    assert turn.wake_id == carrier_id

    assert :ok =
             Ledger.finish(ctx.db, turn.seq, "failed", "carrier failed",
               owner_lease: turn.owner_lease
             )

    assert :ok = Bubble.recognize_terminal(ctx.db, turn.seq)

    for {sender, own_wake, other_wake, own_prompt, other_prompt} <- [
          {sender_a, wake_a, wake_b, "private intent alpha", "private intent beta"},
          {sender_b, wake_b, wake_a, "private intent beta", "private intent alpha"}
        ] do
      assert {:ok, [[content]]} =
               DB.query(
                 ctx.db,
                 "SELECT content FROM messages WHERE sessionKey=?1 AND clientMessageId=?2",
                 [sender.session_key, "wake-undelivered:#{turn.seq}"]
               )

      assert content =~ own_wake.wake_id
      refute content =~ other_wake.wake_id
      refute content =~ own_prompt
      refute content =~ other_prompt
    end
  end

  test "typed rate-limit retry ownership is not mistaken for a non-retryable sender result",
       ctx do
    error = JSON.encode!(%{data: %{errorKind: "rate_limit"}})
    {_wake, turn, sender} = fail_wake!(ctx, "failed", error)
    assert :ok = Bubble.recognize_terminal(ctx.db, turn.seq)

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT id FROM messages WHERE sessionKey=?1 AND clientMessageId=?2",
               [sender.session_key, "wake-undelivered:#{turn.seq}"]
             )
  end

  test "delivered carriers do not produce an undelivered sender result", ctx do
    {_wake, turn, sender} = fail_wake!(ctx, "delivered")
    assert :ok = Bubble.recognize_terminal(ctx.db, turn.seq)
    assert notice_turn(ctx.db, ctx.supervisor.session_key) == []

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT id FROM messages WHERE sessionKey=?1 AND clientMessageId=?2",
               [sender.session_key, "wake-undelivered:#{turn.seq}"]
             )
  end

  test "a spawned session's failed turn stages one deduped notice behind its busy parent", ctx do
    {:appended, current_message} =
      Tightbeam.Projection.append(ctx.db, %{
        session_key: ctx.supervisor.session_key,
        role: "user",
        content: "current parent work",
        sender: "session:#{ctx.supervisor.session_key}"
      })

    {:ok, current_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.supervisor.session_key,
        message_id: current_message.id,
        origin: "session:#{ctx.supervisor.session_key}",
        prompt: "current parent work"
      })

    assert {:ok, %{seq: ^current_seq, owner_lease: lease}} =
             Ledger.claim_next(ctx.db, ctx.supervisor.session_key, "bubble-batching-test")

    seq = fail_turn!(ctx.db, "holder")

    :ok = Bubble.recognize_terminal(ctx.db, seq)

    source_id = "bubble:#{seq}:supervisor"
    assert notice_turn(ctx.db, "supervisor") == []

    assert [%{wake_id: ^source_id, state: "pending", origin: "process:tightbeam"} = source] =
             Enum.filter(Tightbeam.Wakes.list_for_session(ctx.db, "supervisor"), fn wake ->
               wake.wake_id == source_id
             end)

    assert source.prompt =~ "holder"
    assert source.prompt =~ "quota exhausted"
    assert NoticeBatcher.source_refs(ctx.db, source_id) == []

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [source_id])

    # Recognizing the same terminal again is a rung of the SAME climb: the
    # deterministic wakeId absorbs it. One notice, not two.
    :ok = Bubble.recognize_terminal(ctx.db, seq)

    assert 1 ==
             Enum.count(Tightbeam.Wakes.list_for_session(ctx.db, "supervisor"), fn wake ->
               wake.wake_id == source_id
             end)

    assert :ok =
             Ledger.finish(ctx.db, current_seq, "delivered", nil, owner_lease: lease)

    [carrier_id] = deliver_ready_carriers!(ctx, "supervisor")
    carrier = Tightbeam.Wakes.get(ctx.db, carrier_id)
    assert carrier.prompt =~ "holder"
    assert carrier.prompt =~ "quota exhausted"

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [carrier_id])
  end

  test "an open incident suppresses only its affected harness", ctx do
    assert {:opened, _incident} =
             HarnessHealth.observe(ctx.db, %{
               correlation_id: "bubble-rate-limit",
               harness: "claude",
               host: "testhost",
               failure_class: "rate-limit-dead",
               evidence_kind: "authoritative-provider",
               session_key: ctx.holder.session_key,
               assignment_id: nil,
               observed_at: 1,
               cause: "provider rate limit",
               principal: "process:tightbeam"
             })

    affected_seq = fail_turn!(ctx.db, ctx.holder.session_key)
    :ok = Bubble.recognize_terminal(ctx.db, affected_seq)
    assert notice_turn(ctx.db, ctx.supervisor.session_key) == []

    healthy =
      Org.create(ctx.db, %{
        session_key: "healthy-holder",
        display_name: "Healthy holder",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        harness: "claude",
        provider: "anthropic",
        host: "healthy-host",
        model: Model.new("fable"),
        spawned_by: ctx.supervisor.session_key
      })

    healthy_seq = fail_turn!(ctx.db, healthy.session_key)
    :ok = Bubble.recognize_terminal(ctx.db, healthy_seq)
    healthy_ref = "bubble:#{healthy_seq}"

    assert [[_, ^healthy_ref, _, _, _]] =
             notice_turn(ctx.db, ctx.supervisor.session_key)
  end

  test "a canceled cause turn never bubbles — cancellation is a decision", ctx do
    :appended =
      Tightbeam.Gateway.deliver_prompt("holder", "user:flynn", "doomed",
        db: ctx.db,
        device_id: "test",
        client_message_id: "c-cancel"
      )

    {:ok, [[seq]]} =
      DB.query(ctx.db, "SELECT seq FROM turns WHERE sessionKey = 'holder' ORDER BY seq DESC")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE turns SET status = 'canceled', endedAt = 1 WHERE seq = ?1",
        [seq]
      )

    :ok = Bubble.recognize_terminal(ctx.db, seq)
    assert notice_turn(ctx.db, "supervisor") == []
  end

  test "a failed notice climbs one rung; a failed notice at the top alerts and stands", ctx do
    cause_seq = fail_turn!(ctx.db, "holder")
    :ok = Bubble.recognize_terminal(ctx.db, cause_seq)

    # The supervisor cannot run either: its notice fails. Same wall.
    {:ok, notice} = Ledger.claim_next(ctx.db, "supervisor", "test-lane")

    :ok =
      Ledger.finish(ctx.db, notice.seq, "failed", "quota exhausted",
        owner_lease: notice.owner_lease
      )

    :ok = Bubble.recognize_terminal(ctx.db, notice.seq)

    # The SAME cause climbed — not a notice about the notice.
    assert [[_, request_ref, wake_id, _, prompt]] = notice_turn(ctx.db, ctx.main.session_key)
    assert request_ref == "bubble:#{cause_seq}"
    assert wake_id == "bubble:#{cause_seq}:#{ctx.main.session_key}"
    assert prompt =~ "holder"

    # The main session is against the wall too. Its notice failing exhausts
    # the lineage: the alert is a substrate message in the owner's stream (no
    # turn, no tokens) and the fact stands for the OWNER, not a session.
    {:ok, top} = Ledger.claim_next(ctx.db, ctx.main.session_key, "test-lane")

    :ok =
      Ledger.finish(ctx.db, top.seq, "failed", "quota exhausted", owner_lease: top.owner_lease)

    :ok = Bubble.recognize_terminal(ctx.db, top.seq)

    assert ConditionFacts.standing?(ctx.db, "user-alerted", "flynn")

    {:ok, [[alert_content]]} =
      DB.query(
        ctx.db,
        "SELECT content FROM messages WHERE sessionKey = ?1 AND content LIKE '[no agent can act]%'",
        [ctx.main.session_key]
      )

    assert alert_content =~ "holder"
    assert alert_content =~ "quota exhausted"

    # Suppression: a fresh failure under the alerted owner does not climb.
    seq2 = fail_turn!(ctx.db, "holder", "failed", "still walled")
    :ok = Bubble.recognize_terminal(ctx.db, seq2)

    assert [[_, ref, _, _, _]] = notice_turn(ctx.db, "supervisor")
    assert ref == "bubble:#{cause_seq}", "no second notice while the alert stands"
  end

  test "a canceled notice climbs — the underlying fault remains untold", ctx do
    cause_seq = fail_turn!(ctx.db, "holder")
    :ok = Bubble.recognize_terminal(ctx.db, cause_seq)

    {:ok, [[notice_seq]]} =
      DB.query(
        ctx.db,
        "SELECT seq FROM turns WHERE sessionKey = 'supervisor' AND requestRef = ?1",
        ["bubble:#{cause_seq}"]
      )

    {:ok, _} =
      DB.query(ctx.db, "UPDATE turns SET status = 'canceled', endedAt = 1 WHERE seq = ?1", [
        notice_seq
      ])

    :ok = Bubble.recognize_terminal(ctx.db, notice_seq)
    assert [[_, ref, _, _, _]] = notice_turn(ctx.db, ctx.main.session_key)
    assert ref == "bubble:#{cause_seq}"
  end

  test "a parentless session's failure marks its own stream and climbs nowhere", ctx do
    seq = fail_turn!(ctx.db, ctx.main.session_key)
    :ok = Bubble.recognize_terminal(ctx.db, seq)

    assert notice_turn(ctx.db, "supervisor") == []
    refute ConditionFacts.standing?(ctx.db, "user-alerted", "flynn")
  end

  test "the first delivered turn for an alerted owner clears the alert", ctx do
    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{
          kind: "user-alerted",
          scope: "flynn",
          origin: "process:tightbeam"
        })
      end)

    assert ConditionFacts.standing?(ctx.db, "user-alerted", "flynn")

    :appended =
      Tightbeam.Gateway.deliver_prompt("holder", "user:flynn", "the wall fell",
        db: ctx.db,
        device_id: "test",
        client_message_id: "c-heal"
      )

    {:ok, turn} = Ledger.claim_next(ctx.db, "holder", "test-lane")
    :ok = Ledger.finish(ctx.db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)
    :ok = Bubble.recognize_terminal(ctx.db, turn.seq)

    refute ConditionFacts.standing?(ctx.db, "user-alerted", "flynn")

    # And the next exhausted climb alerts AGAIN — the machine acts on current
    # state, and the current state says the user has not been told about the
    # new wall. The climb is run honestly: fail in holder, fail the notice at
    # every rung above it.
    cause_seq = fail_turn!(ctx.db, "holder", "failed", "new wall")
    :ok = Bubble.recognize_terminal(ctx.db, cause_seq)

    for rung <- ["supervisor", ctx.main.session_key] do
      {:ok, notice} = Ledger.claim_next(ctx.db, rung, "test-lane")

      :ok =
        Ledger.finish(ctx.db, notice.seq, "failed", "new wall", owner_lease: notice.owner_lease)

      :ok = Bubble.recognize_terminal(ctx.db, notice.seq)
    end

    assert ConditionFacts.standing?(ctx.db, "user-alerted", "flynn")
  end

  # Review B2: a cause turn whose lineage EXISTS but holds no active rung is
  # the climb exhausting, and the climb exhausting is the alert — the silent
  # arm is reserved for sessions with no lineage at all.
  test "a cause turn under an all-retired lineage alerts instead of dying silently", ctx do
    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey IN (?1, ?2)", [
        "supervisor",
        ctx.main.session_key
      ])

    seq = fail_turn!(ctx.db, "holder")
    :ok = Bubble.recognize_terminal(ctx.db, seq)

    assert ConditionFacts.standing?(ctx.db, "user-alerted", "flynn")
    assert notice_turn(ctx.db, "supervisor") == []
  end

  # Review M5: a notice with a corrupt marker must not become the start of a
  # new bubble; recognition declines and reports.
  test "a malformed bubble marker declines recognition instead of climbing", ctx do
    seq = fail_turn!(ctx.db, "holder")
    {:ok, _} = DB.query(ctx.db, "UPDATE turns SET requestRef='bubble:12x' WHERE seq=?1", [seq])

    :ok = Bubble.recognize_terminal(ctx.db, seq)

    assert notice_turn(ctx.db, "supervisor") == []

    assert Enum.any?(
             Tightbeam.EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "bubble_marker_malformed" and &1.subject == "holder")
           )
  end

  # Review M4: a bubble naming a cause turn that does not exist reports dirt
  # rather than fabricating an "unknown" cause for a parent or a user.
  test "a missing cause row declines recognition and reports", ctx do
    seq = fail_turn!(ctx.db, "holder")
    {:ok, _} = DB.query(ctx.db, "UPDATE turns SET requestRef='bubble:99999' WHERE seq=?1", [seq])

    :ok = Bubble.recognize_terminal(ctx.db, seq)

    assert notice_turn(ctx.db, "supervisor") == []
    assert notice_turn(ctx.db, ctx.main.session_key) == []

    assert Enum.any?(
             Tightbeam.EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "bubble_cause_missing" and &1.subject == "holder")
           )
  end

  # Spec proof 6's bubble counterpart: the LHS asserted against its surface.
  test "the bubble LHS: terminal admission by notice-ness, suppression by owner", ctx do
    cause = %{
      notice?: false,
      owner: "flynn",
      session_key: "holder",
      cause_seq: 1,
      status: "failed"
    }

    notice = %{cause | notice?: true}

    assert Bubble.bubble_production_matches?(ctx.db, "failed", cause)
    assert Bubble.bubble_production_matches?(ctx.db, "failed_unknown", cause)
    refute Bubble.bubble_production_matches?(ctx.db, "canceled", cause)
    assert Bubble.bubble_production_matches?(ctx.db, "canceled", notice)

    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{
          kind: "user-alerted",
          scope: "flynn",
          origin: "process:tightbeam"
        })
      end)

    refute Bubble.bubble_production_matches?(ctx.db, "failed", cause)
  end

  test "turn signals recognize once and missed signals are repaired and counted", ctx do
    sweeper =
      start_supervised!(
        {Tightbeam.Productions.BubbleSweeper, db: ctx.db, name: :event_bubble_sweeper}
      )

    :sys.get_state(sweeper)
    assert :sys.get_state(sweeper).interval >= 180_000
    before = Tightbeam.SchedulerMisses.count()
    seq = fail_turn!(ctx.db, "holder")
    Tightbeam.Productions.BubbleSweeper.recognize(sweeper, seq)
    :sys.get_state(sweeper)
    assert [[_, ref, _, _, _]] = notice_turn(ctx.db, "supervisor")
    assert ref == "bubble:#{seq}"
    Tightbeam.Productions.BubbleSweeper.sweep_now(sweeper)
    assert Tightbeam.SchedulerMisses.count() == before

    missed = fail_turn!(ctx.db, "holder")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(sweeper, :tick)
        :sys.get_state(sweeper)
      end)

    assert log =~ "loop=bubble record=#{missed}"
    assert Tightbeam.SchedulerMisses.count() > before

    assert {:ok, [[cursor]]} =
             DB.query(ctx.db, "SELECT seq FROM production_cursors WHERE name='bubble'")

    assert cursor >= missed or
             match?(
               {:ok, [[^missed]]},
               DB.query(ctx.db, "SELECT seq FROM production_cursors WHERE name=?1", [
                 "bubble:#{missed}"
               ])
             )

    before_restart = Tightbeam.SchedulerMisses.count()
    stop_supervised!(Tightbeam.Productions.BubbleSweeper)

    replacement =
      start_supervised!(
        {Tightbeam.Productions.BubbleSweeper, db: ctx.db, name: :event_bubble_sweeper}
      )

    :sys.get_state(replacement)
    assert Tightbeam.SchedulerMisses.count() == before_restart
  end

  # Review B1/B3b: the sweeper's cursor makes recognition sweep-reachable —
  # a terminal whose cast was lost is picked up from the cursor, and the
  # cursor never advances past a still-pending row (out-of-order terminals).
  test "the sweeper recognizes from the cursor and halts at the terminal prefix", ctx do
    sweeper =
      start_supervised!(
        {Tightbeam.Productions.BubbleSweeper,
         db: ctx.db, interval: 3_600_000, name: :"bubble_sweeper_#{ctx.db}"}
      )

    # A failed cause whose cast was "lost" (never delivered by hand), and a
    # still-queued younger sibling that must block the cursor behind it.
    seq = fail_turn!(ctx.db, "holder")

    :appended =
      Tightbeam.Gateway.deliver_prompt("holder", "user:flynn", "still queued",
        db: ctx.db,
        device_id: "test",
        client_message_id: "c-pending"
      )

    assert Tightbeam.Productions.BubbleSweeper.sweep_now(sweeper) >= 1
    assert [[_, ref, _, _, _]] = notice_turn(ctx.db, "supervisor")
    assert ref == "bubble:#{seq}"

    {:ok, [[cursor]]} =
      DB.query(ctx.db, "SELECT seq FROM production_cursors WHERE name='bubble'")

    assert cursor < seq + 2, "cursor must not pass the still-queued row"
    assert Tightbeam.Productions.BubbleSweeper.sweep_now(sweeper) == 0
  end

  test "a permanently failed turn cannot hold the sweep cursor forever", ctx do
    seq = fail_turn!(ctx.db, "holder")
    proxy = start_supervised!({RecognitionRefusal, ctx.db})

    sweeper =
      start_supervised!(
        {Tightbeam.Productions.BubbleSweeper,
         db: proxy, interval: 3_600_000, name: :"bounded_bubble_sweeper_#{ctx.db}"}
      )

    :sys.get_state(sweeper)
    for _ <- 1..5, do: Tightbeam.Productions.BubbleSweeper.sweep_now(sweeper)

    assert {:ok, [[cursor]]} =
             DB.query(ctx.db, "SELECT seq FROM production_cursors WHERE name='bubble'")

    assert cursor >= seq
    assert Process.alive?(sweeper)
  end

  test "a failed recognition holds the cursor and succeeds on a later sweep", ctx do
    seq = fail_turn!(ctx.db, "holder")
    proxy = start_supervised!({RecognitionRefusal, ctx.db})

    sweeper =
      start_supervised!(
        {Tightbeam.Productions.BubbleSweeper,
         db: proxy, interval: 3_600_000, name: :"refused_bubble_sweeper_#{ctx.db}"}
      )

    assert Tightbeam.Productions.BubbleSweeper.sweep_now(sweeper) == 0
    assert {:ok, []} = DB.query(ctx.db, "SELECT seq FROM production_cursors WHERE name='bubble'")
    assert :ok = GenServer.call(proxy, :allow)
    assert Tightbeam.Productions.BubbleSweeper.sweep_now(sweeper) >= 1

    assert {:ok, [[cursor]]} =
             DB.query(ctx.db, "SELECT seq FROM production_cursors WHERE name='bubble'")

    assert cursor >= seq
    assert [[_, _, _, _, _]] = notice_turn(ctx.db, "supervisor")
  end

  test "the substrate may not assert work-blocked; agents may not file the alert kinds", ctx do
    {:ok, refused} =
      DB.transaction(ctx.db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{
          kind: "work-blocked",
          scope: "holder",
          origin: "process:tightbeam"
        })
      end)

    assert {:error, %{code: "agent_only_kind"}} = refused

    {:ok, refused} =
      DB.transaction(ctx.db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{
          kind: "user-alerted",
          scope: "flynn",
          origin: "session:holder"
        })
      end)

    assert {:error, %{code: "reserved_kind"}} = refused
  end

  test "a restored decision retains root authority and release cancels its current leaf", ctx do
    busy = hold_recipient!(ctx.db, ctx.supervisor.session_key)

    {assignment, blocked} =
      cannot_proceed_assignment!(
        ctx,
        ctx.holder.session_key,
        ctx.supervisor.session_key,
        "retry-root decision",
        %{
          release_fact_kind: "reviewed",
          release_fact_scope: "retry-decision-release",
          release_fact_principal_ref: "process:tightbeam"
        }
      )

    queue_decision_wake!(ctx, blocked.decisionWake)
    finish_busy_recipient!(ctx.db, busy)
    carrier = deliver_decision_carrier!(ctx, ctx.supervisor.session_key)

    assert {:ok, turn} =
             Ledger.claim_next(ctx.db, ctx.supervisor.session_key, "prewrite-decision")

    assert turn.wake_id == carrier.wake_id
    root = blocked.decisionWake.wake_id

    {:ok, cp_before} =
      DB.query(ctx.db, "SELECT * FROM assignment_cannot_proceed WHERE id=?1", [
        blocked.cannotProceed.id
      ])

    successors = prewrite_restore!(ctx.db, turn)
    leaf = Tightbeam.NoticeAuthority.current!(ctx.db, root)
    assert leaf in successors
    assert leaf != root

    assert Tightbeam.NoticeAuthority.resolve!(ctx.db, leaf) == %{
             root_wake_id: root,
             root_turn_seq: turn.seq
           }

    assert {:ok, ^cp_before} =
             DB.query(ctx.db, "SELECT * FROM assignment_cannot_proceed WHERE id=?1", [
               blocked.cannotProceed.id
             ])

    assert :ok = Bubble.recognize_terminal(ctx.db, turn.seq)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE wakeId LIKE ?1", [
               "bubble:#{turn.seq}:%"
             ])

    # A later, legitimate disposer change cannot be overridden by stale retry
    # admission. Release still acts on the immutable decision root's live leaf.
    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Assignments.transfer_cannot_proceed_disposer_to_session_in_txn(
                 txn,
                 assignment,
                 ctx.holder.session_key,
                 turn.seq,
                 root
               )
             end)

    assert {:error, error} =
             DB.transaction(
               ctx.db,
               &Assignments.assert_retry_decision_in_txn!(&1, leaf, ctx.supervisor.session_key)
             )

    assert Exception.message(error) =~ "decision disposer changed"
    assert Tightbeam.Wakes.get(ctx.db, leaf).state == "pending"

    assert {:ok, %{fact_id: _}} =
             DB.transaction(ctx.db, fn txn ->
               ConditionFacts.file_in_txn(txn, %{
                 kind: "reviewed",
                 scope: "retry-decision-release",
                 origin: "process:tightbeam",
                 owner_user_id: "flynn"
               })
             end)

    assert Tightbeam.Wakes.get(ctx.db, root).state == "fired"
    assert Tightbeam.Wakes.get(ctx.db, leaf).state == "canceled"

    assert {:ok, [[^root, "settled"]]} =
             DB.query(
               ctx.db,
               "SELECT decisionWakeId,state FROM assignment_cannot_proceed WHERE id=?1",
               [blocked.cannotProceed.id]
             )

    assert prewrite_restore!(ctx.db, turn, false) == successors
    assert Tightbeam.Wakes.get(ctx.db, leaf).state == "canceled"

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wake_cancellations WHERE wakeId=?1 AND reasonKind='cannot_proceed_released'",
               [leaf]
             )
  end

  test "a prewrite bubble retry preserves transferred disposal and original cause once", ctx do
    busy = hold_recipient!(ctx.db, ctx.supervisor.session_key)

    {_assignment, blocked} =
      cannot_proceed_assignment!(
        ctx,
        ctx.holder.session_key,
        ctx.supervisor.session_key,
        "transferred decision retry"
      )

    queue_decision_wake!(ctx, blocked.decisionWake)
    finish_busy_recipient!(ctx.db, busy)
    _ = deliver_decision_carrier!(ctx, ctx.supervisor.session_key)

    assert {:ok, decision} =
             Ledger.claim_next(ctx.db, ctx.supervisor.session_key, "failed-decision")

    assert :ok =
             Ledger.finish(ctx.db, decision.seq, "failed", "ordinary failure",
               owner_lease: decision.owner_lease
             )

    # Hold the actual next recipient so the bubble has an editable source
    # before readiness admission, rather than taking the lone idle direct path.
    main_busy = hold_recipient!(ctx.db, ctx.main.session_key)
    assert :ok = Bubble.recognize_terminal(ctx.db, decision.seq)
    root = "bubble:#{decision.seq}:#{ctx.main.session_key}"
    assert Tightbeam.Wakes.get(ctx.db, root).state == "pending"
    assert Tightbeam.NoticeAuthority.current!(ctx.db, root) == root
    finish_busy_recipient!(ctx.db, main_busy)
    [bubble_carrier] = deliver_ready_carriers!(ctx, ctx.main.session_key)
    assert Tightbeam.Wakes.get(ctx.db, root).state == "fired"
    assert {:ok, turn} = Ledger.claim_next(ctx.db, ctx.main.session_key, "prewrite-bubble")
    assert turn.wake_id == bubble_carrier
    refute turn.wake_id == root

    {:ok, cp_before} =
      DB.query(ctx.db, "SELECT * FROM assignment_cannot_proceed WHERE id=?1", [
        blocked.cannotProceed.id
      ])

    expected = "session:" <> ctx.main.session_key

    assert {:ok, [[^expected]]} =
             DB.query(ctx.db, "SELECT disposerRef FROM assignment_cannot_proceed WHERE id=?1", [
               blocked.cannotProceed.id
             ])

    successors = prewrite_restore!(ctx.db, turn)
    retry = Tightbeam.NoticeAuthority.current!(ctx.db, root)
    assert retry in successors
    refute retry == root

    assert Tightbeam.NoticeAuthority.resolve!(ctx.db, retry) == %{
             root_wake_id: root,
             root_turn_seq: turn.seq
           }

    assert :ok = Bubble.recognize_terminal(ctx.db, turn.seq)

    assert {:ok, ^cp_before} =
             DB.query(ctx.db, "SELECT * FROM assignment_cannot_proceed WHERE id=?1", [
               blocked.cannotProceed.id
             ])

    assert prewrite_restore!(ctx.db, turn, false) == successors
    _ = NoticeBatcher.recover(ctx.db, Tightbeam.Wakes.get(ctx.db, retry).due_at)
    assert Tightbeam.Wakes.get(ctx.db, retry).state == "fired"

    assert {:ok, ^cp_before} =
             DB.query(ctx.db, "SELECT * FROM assignment_cannot_proceed WHERE id=?1", [
               blocked.cannotProceed.id
             ])

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM (SELECT wakeId AS sourceWakeId,deliveredTurnSeq AS turnSeq,assignmentId FROM wakes WHERE deliveredTurnSeq IS NOT NULL) d WHERE d.sourceWakeId=?1",
               [retry]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM condition_facts WHERE kind='user-alerted'"
             )
  end

  test "an ordinary assignment failure does not displace the cannot-proceed opener", ctx do
    {assignment_id, blocked} =
      cannot_proceed_assignment!(
        ctx,
        ctx.holder.session_key,
        ctx.main.session_key,
        "running bubble disposer"
      )

    {:appended, busy_message} =
      Tightbeam.Projection.append(ctx.db, %{
        session_key: ctx.supervisor.session_key,
        role: "user",
        content: "busy supervisor turn",
        sender: "session:#{ctx.supervisor.session_key}"
      })

    {:ok, busy_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.supervisor.session_key,
        message_id: busy_message.id,
        origin: "session:#{ctx.supervisor.session_key}",
        prompt: "busy supervisor turn"
      })

    assert {:ok, %{seq: ^busy_seq, owner_lease: busy_lease}} =
             Ledger.claim_next(ctx.db, ctx.supervisor.session_key, "busy-supervisor")

    cause_seq = fail_assigned_turn!(ctx.db, ctx.holder.session_key, assignment_id)
    assert :ok = Bubble.recognize_terminal(ctx.db, cause_seq)

    bubble_wake_id = "bubble:#{cause_seq}:#{ctx.supervisor.session_key}"

    assert {:ok, [["pending", ^assignment_id]]} =
             DB.query(ctx.db, "SELECT state,assignmentId FROM wakes WHERE wakeId=?1", [
               bubble_wake_id
             ])

    expected_disposer = "session:" <> ctx.main.session_key

    assert {:ok, [[^expected_disposer]]} =
             DB.query(
               ctx.db,
               "SELECT disposerRef FROM assignment_cannot_proceed WHERE id=?1",
               [blocked.cannotProceed.id]
             )

    assert :ok = Ledger.finish(ctx.db, busy_seq, "delivered", nil, owner_lease: busy_lease)
    _carriers = deliver_ready_carriers!(ctx, ctx.supervisor.session_key)

    assert [%{batch_state: "delivered", delivery_wake_id: _}] =
             NoticeBatcher.source_refs(ctx.db, bubble_wake_id)

    assert {:ok, [[^expected_disposer]]} =
             DB.query(
               ctx.db,
               "SELECT disposerRef FROM assignment_cannot_proceed WHERE id=?1",
               [blocked.cannotProceed.id]
             )

    assert %{outcome: "revoked"} =
             Assignments.__handle__(ctx.db, "revoke-assignment", %{
               verb: "revoke-assignment",
               origin: "agent:#{ctx.main.session_key}",
               principal: {:session, ctx.main.session_key},
               session_key: nil,
               params: %{
                 assignment_id: assignment_id,
                 reason: "ordinary failure does not transfer authority"
               }
             })
  end

  test "an idle ancestor receives a mixed decision carrier and inherits each matched disposer",
       ctx do
    holder_two = session(ctx.db, "holder-two", ctx.supervisor.session_key)

    {assignment_a, blocked_a} =
      cannot_proceed_assignment!(
        ctx,
        ctx.holder.session_key,
        ctx.supervisor.session_key,
        "first decision in mixed carrier"
      )

    {assignment_b, blocked_b} =
      cannot_proceed_assignment!(
        ctx,
        holder_two.session_key,
        ctx.supervisor.session_key,
        "second decision in mixed carrier"
      )

    queue_decision_wake!(ctx, blocked_a.decisionWake)
    queue_decision_wake!(ctx, blocked_b.decisionWake)

    decision_carrier_ids = deliver_ready_carriers!(ctx, ctx.supervisor.session_key)
    assert length(decision_carrier_ids) == 1
    decision_carrier = Tightbeam.Wakes.get(ctx.db, hd(decision_carrier_ids))
    assert is_nil(decision_carrier.assignment_id)

    assert [%{delivery_wake_id: carrier_id}] =
             NoticeBatcher.source_refs(ctx.db, blocked_a.decisionWake.wake_id)

    assert carrier_id == decision_carrier.wake_id

    assert [%{delivery_wake_id: ^carrier_id}] =
             NoticeBatcher.source_refs(ctx.db, blocked_b.decisionWake.wake_id)

    assert {:ok, decision_turn} =
             Ledger.claim_next(ctx.db, ctx.supervisor.session_key, "mixed-decision-wake")

    assert :ok =
             Ledger.finish(ctx.db, decision_turn.seq, "failed", "decision carrier failed",
               owner_lease: decision_turn.owner_lease
             )

    assert :ok = Bubble.recognize_terminal(ctx.db, decision_turn.seq)
    _ = deliver_ready_carriers!(ctx, ctx.main.session_key)
    assert length(notice_turn(ctx.db, ctx.main.session_key)) == 1

    expected_disposer = "session:" <> ctx.main.session_key

    for blocked <- [blocked_a, blocked_b] do
      assert {:ok, [[^expected_disposer]]} =
               DB.query(
                 ctx.db,
                 "SELECT disposerRef FROM assignment_cannot_proceed WHERE id=?1",
                 [blocked.cannotProceed.id]
               )
    end

    assert assignment_a != assignment_b
  end

  for {terminal, boundary} <- [
        {"failed", :complete},
        {"canceled", :complete},
        {"failed", :publication_interrupted},
        {"failed", :transaction_refused},
        {"failed", :target_skipped},
        {"failed", :target_skipped_publication_interrupted}
      ] do
    description =
      "separate failed decisions share a #{terminal} bubble carrier without losing either cause"

    description =
      if boundary == :complete, do: description, else: description <> " at #{boundary}"

    @tag persistent: true
    test description,
         ctx do
      busy = hold_recipient!(ctx.db, ctx.supervisor.session_key)

      causes =
        for suffix <- ~w(a b) do
          opener = session(ctx.db, "decision-#{suffix}", ctx.supervisor.session_key)
          holder = session(ctx.db, "decision-holder-#{suffix}", opener.session_key)
          opener_busy = hold_recipient!(ctx.db, opener.session_key)

          {_assignment, blocked} =
            cannot_proceed_assignment!(
              ctx,
              holder.session_key,
              opener.session_key,
              "independent decision #{suffix}"
            )

          queue_decision_wake!(ctx, blocked.decisionWake)
          finish_busy_recipient!(ctx.db, opener_busy)
          _ = deliver_ready_carriers!(ctx, opener.session_key)

          assert {:ok, decision} =
                   Ledger.claim_next(ctx.db, opener.session_key, "original-decision-#{suffix}")

          assert :ok =
                   Ledger.finish(
                     ctx.db,
                     decision.seq,
                     "failed",
                     "original decision #{suffix} failed",
                     owner_lease: decision.owner_lease
                   )

          assert :ok = Bubble.recognize_terminal(ctx.db, decision.seq)
          {decision.seq, blocked, opener.session_key}
        end

      finish_busy_recipient!(ctx.db, busy)
      [carrier] = deliver_ready_carriers!(ctx, ctx.supervisor.session_key)

      expected =
        Enum.map(causes, fn {seq, _, _} -> "bubble:#{seq}:#{ctx.supervisor.session_key}" end)

      assert Enum.map(Tightbeam.Wakes.digest_members(ctx.db, carrier), & &1.wake_id) == expected

      assert {:ok, intermediate} =
               Ledger.claim_next(ctx.db, ctx.supervisor.session_key, "combined-bubble")

      assert intermediate.wake_id == carrier

      assert {:ok, [[nil]]} =
               DB.query(ctx.db, "SELECT requestRef FROM turns WHERE seq=?1", [intermediate.seq])

      assert :ok =
               Ledger.finish(
                 ctx.db,
                 intermediate.seq,
                 unquote(terminal),
                 "combined notice could not run",
                 owner_lease: intermediate.owner_lease
               )

      assert :ok = stop_supervised(DB)
      start_supervised!({DB, ctx.db_opts})
      assert :ok = Tightbeam.Schema.ensure_all(ctx.db)

      terminal_seqs =
        if unquote(boundary) in [:target_skipped, :target_skipped_publication_interrupted] do
          assert :ok = Tightbeam.Productions.BubbleSweeper.ensure_schema(ctx.db)

          assert {:ok, _} =
                   DB.query(
                     ctx.db,
                     "INSERT INTO production_cursors(name,seq) VALUES('bubble',?1) ON CONFLICT(name) DO UPDATE SET seq=excluded.seq",
                     [intermediate.seq - 1]
                   )

          proxy = start_supervised!({MissingTargetDB, {ctx.db, ctx.main.session_key, self()}})
          interrupted? = unquote(boundary) == :target_skipped_publication_interrupted
          if interrupted?, do: disconnect_owner_alert!(ctx.db)

          sweeper =
            start_supervised!(
              {Tightbeam.Productions.BubbleSweeper,
               db: proxy, interval: 3_600_000, name: :"skipped_bubble_sweeper_#{ctx.db}"}
            )

          # The boot tick precedes this call: containment must not advance the
          # cursor past a group whose original causes have not been completed.
          if interrupted? do
            assert {:ok, [[cursor_before_retry]]} =
                     DB.query(
                       ctx.db,
                       "SELECT seq FROM production_cursors WHERE name='bubble'"
                     )

            assert cursor_before_retry == intermediate.seq - 1
          end

          expected_recognized = if interrupted?, do: 1, else: 0
          assert Tightbeam.Productions.BubbleSweeper.sweep_now(sweeper) == expected_recognized
          assert_receive {:real_missing_target_delivery, selected_target}
          assert selected_target == ctx.main.session_key

          assert {:ok, [[cursor]]} =
                   DB.query(
                     ctx.db,
                     "SELECT seq FROM production_cursors WHERE name='bubble'"
                   )

          assert cursor == intermediate.seq
          assert notice_turn(ctx.db, ctx.main.session_key) == []

          for {seq, _, _} <- causes do
            assert {:ok, [[detail]]} =
                     DB.query(
                       ctx.db,
                       "SELECT detail FROM lifecycle_events WHERE kind='turn_undeliverable' AND subject=?1",
                       ["bubble:#{seq}:#{ctx.main.session_key}"]
                     )

            assert detail =~ "reason=no_session_row target=#{ctx.main.session_key}"
          end

          if interrupted? do
            assert_receive {:owner_alert_committed, 2}
            restore_owner_registry!()
          end

          assert :ok = stop_supervised(Tightbeam.Productions.BubbleSweeper)
          assert :ok = stop_supervised(MissingTargetDB)
          assert :ok = stop_supervised(DB)
          start_supervised!({DB, ctx.db_opts})
          assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
          assert :ok = Bubble.recognize_terminal(ctx.db, intermediate.seq)
          [intermediate.seq]
        else
          main_busy = hold_recipient!(ctx.db, ctx.main.session_key)
          assert :ok = Bubble.recognize_terminal(ctx.db, intermediate.seq)
          assert :ok = Bubble.recognize_terminal(ctx.db, intermediate.seq)
          finish_busy_recipient!(ctx.db, main_busy)
          [main_carrier] = deliver_ready_carriers!(ctx, ctx.main.session_key)

          expected_main =
            Enum.map(causes, fn {seq, _, _} -> "bubble:#{seq}:#{ctx.main.session_key}" end)

          assert Enum.map(Tightbeam.Wakes.digest_members(ctx.db, main_carrier), & &1.wake_id) ==
                   expected_main

          assert {:ok, main_notice} =
                   Ledger.claim_next(ctx.db, ctx.main.session_key, "combined-main-bubble")

          assert main_notice.wake_id == main_carrier

          for {seq, blocked, _original_recipient} <- causes do
            assert main_notice.prompt =~ "Turn #{seq}"

            assert {:ok, [[disposer]]} =
                     DB.query(
                       ctx.db,
                       "SELECT disposerRef FROM assignment_cannot_proceed WHERE id=?1",
                       [blocked.cannotProceed.id]
                     )

            assert disposer == "session:" <> ctx.main.session_key
          end

          assert :ok =
                   Ledger.finish(ctx.db, main_notice.seq, "failed", "final recipient failed",
                     owner_lease: main_notice.owner_lease
                   )

          case unquote(boundary) do
            :publication_interrupted ->
              disconnect_owner_alert!(ctx.db)

              assert {:owner_alert_publication_interrupted, _call} =
                       catch_exit(Bubble.recognize_terminal(ctx.db, main_notice.seq))

              assert_receive {:owner_alert_committed, 2}
              restore_owner_registry!()
              assert :ok = stop_supervised(DB)
              start_supervised!({DB, ctx.db_opts})
              assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
              assert :ok = Bubble.recognize_terminal(ctx.db, main_notice.seq)

            :transaction_refused ->
              {last_cause, _blocked, original_recipient} = List.last(causes)
              detail = "cause_seq=#{last_cause} session=#{original_recipient}"
              assert :ok = Tightbeam.Wakes.report_failed_delivery(ctx.db, main_notice.seq)
              before = bubble_history(ctx.db)

              assert :ok =
                       DB.execute(ctx.db, """
                       CREATE TRIGGER refuse_second_owner_alert BEFORE INSERT ON lifecycle_events
                       WHEN NEW.kind='lineage_exhausted' AND NEW.detail='#{detail}'
                       BEGIN SELECT RAISE(ABORT,'second owner alert refused'); END
                       """)

              assert_raise MatchError, fn ->
                Bubble.recognize_terminal(ctx.db, main_notice.seq)
              end

              assert bubble_history(ctx.db) == before
              refute ConditionFacts.standing?(ctx.db, "user-alerted", "flynn")
              assert :ok = DB.execute(ctx.db, "DROP TRIGGER refuse_second_owner_alert")
              assert :ok = stop_supervised(DB)
              start_supervised!({DB, ctx.db_opts})
              assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
              assert :ok = Bubble.recognize_terminal(ctx.db, main_notice.seq)

            :complete ->
              assert :ok = Bubble.recognize_terminal(ctx.db, main_notice.seq)
          end

          [intermediate.seq, main_notice.seq]
        end

      assert ConditionFacts.standing?(ctx.db, "user-alerted", "flynn")

      for {seq, blocked, original_recipient} <- causes do
        assert {:ok, [["user:flynn"]]} =
                 DB.query(
                   ctx.db,
                   "SELECT disposerRef FROM assignment_cannot_proceed WHERE id=?1",
                   [blocked.cannotProceed.id]
                 )

        assert {:ok, [[1]]} =
                 DB.query(
                   ctx.db,
                   "SELECT COUNT(*) FROM lifecycle_events WHERE kind='lineage_exhausted' AND detail=?1",
                   ["cause_seq=#{seq} session=#{original_recipient}"]
                 )

        assert {:ok, [[1]]} =
                 DB.query(
                   ctx.db,
                   "SELECT COUNT(*) FROM messages WHERE sessionKey=?1 AND content LIKE ?2",
                   [ctx.main.session_key, "[no agent can act]%Original failure — turn #{seq} %"]
                 )
      end

      snapshot = bubble_history(ctx.db)
      assert :ok = stop_supervised(DB)
      start_supervised!({DB, ctx.db_opts})
      assert :ok = Tightbeam.Schema.ensure_all(ctx.db)

      for terminal_seq <- terminal_seqs,
          do: assert(:ok = Bubble.recognize_terminal(ctx.db, terminal_seq))

      assert bubble_history(ctx.db) == snapshot
      assert {:ok, []} = DB.query(ctx.db, "PRAGMA foreign_key_check")
    end
  end

  defp disconnect_owner_alert!(db) do
    assert :ok = GenServer.stop(Process.whereis(Tightbeam.ConnRegistry))
    start_supervised!({OwnerAlertDisconnect, {db, self()}}, restart: :temporary)

    on_exit(fn ->
      if is_nil(Process.whereis(Tightbeam.ConnRegistry)),
        do: ConnRegistry.start_link(name: Tightbeam.ConnRegistry)
    end)
  end

  defp restore_owner_registry!() do
    _ = stop_supervised(OwnerAlertDisconnect)
    {:ok, _registry} = ConnRegistry.start_link(name: Tightbeam.ConnRegistry)
    :ok
  end

  defp bubble_history(db) do
    Map.new(
      [
        "turns",
        "wakes",
        "notice_batch_members",
        "assignment_cannot_proceed",
        "condition_facts",
        "lifecycle_events",
        "messages",
        "sessions"
      ],
      fn table ->
        {:ok, rows} = DB.query(db, "SELECT rowid,* FROM #{table} ORDER BY rowid")
        {table, rows}
      end
    )
  end

  test "a staged decision bubble transfers disposal to its busy recipient", ctx do
    {assignment_id, blocked} =
      cannot_proceed_assignment!(
        ctx,
        ctx.holder.session_key,
        ctx.supervisor.session_key,
        "decision bubble disposer"
      )

    decision_wake = blocked.decisionWake
    busy = hold_recipient!(ctx.db, decision_wake.session_key)
    queue_decision_wake!(ctx, decision_wake)
    finish_busy_recipient!(ctx.db, busy)
    decision_carrier = deliver_decision_carrier!(ctx, ctx.supervisor.session_key)
    supervisor_session = ctx.supervisor.session_key
    assert decision_carrier.session_key == supervisor_session

    assert {:ok, decision_turn} =
             Ledger.claim_next(ctx.db, ctx.supervisor.session_key, "decision-wake")

    assert :ok =
             Ledger.finish(ctx.db, decision_turn.seq, "failed", "decision wake failed",
               owner_lease: decision_turn.owner_lease
             )

    {:appended, busy_message} =
      Tightbeam.Projection.append(ctx.db, %{
        session_key: ctx.main.session_key,
        role: "user",
        content: "current main turn",
        sender: "session:#{ctx.main.session_key}"
      })

    {:ok, busy_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.main.session_key,
        message_id: busy_message.id,
        origin: "session:#{ctx.main.session_key}",
        prompt: "current main turn"
      })

    assert {:ok, %{seq: ^busy_seq, owner_lease: busy_lease}} =
             Ledger.claim_next(ctx.db, ctx.main.session_key, "bubble-busy-ancestor")

    assert :ok = Bubble.recognize_terminal(ctx.db, decision_turn.seq)

    bubble_wake_id = "bubble:#{decision_turn.seq}:#{ctx.main.session_key}"

    assert {:ok, [["pending", "process:tightbeam", ^assignment_id]]} =
             DB.query(
               ctx.db,
               "SELECT state,origin,assignmentId FROM wakes WHERE wakeId=?1",
               [bubble_wake_id]
             )

    expected_disposer = "session:" <> ctx.main.session_key

    assert {:ok, [[^expected_disposer]]} =
             DB.query(
               ctx.db,
               "SELECT disposerRef FROM assignment_cannot_proceed WHERE id=?1",
               [blocked.cannotProceed.id]
             )

    assert :ok = Ledger.finish(ctx.db, busy_seq, "delivered", nil, owner_lease: busy_lease)
    [carrier_id] = NoticeBatcher.recover(ctx.db, System.system_time(:millisecond) + 1_000)
    carrier = Tightbeam.Wakes.get(ctx.db, carrier_id)

    assert {:ok, [[main_session, "queued"]]} =
             DB.query(ctx.db, "SELECT sessionKey,status FROM turns WHERE wakeId=?1", [
               carrier.wake_id
             ])

    assert main_session == ctx.main.session_key
    assert {:ok, notice} = Ledger.claim_next(ctx.db, ctx.main.session_key, "assigned-cause")

    expected_disposer = "session:" <> ctx.main.session_key

    assert {:ok, [[^expected_disposer]]} =
             DB.query(
               ctx.db,
               "SELECT disposerRef FROM assignment_cannot_proceed WHERE id=?1",
               [blocked.cannotProceed.id]
             )

    assert {:ok, [["running"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [notice.seq])

    assert %{outcome: "revoked"} =
             Assignments.__handle__(ctx.db, "revoke-assignment", %{
               verb: "revoke-assignment",
               origin: "agent:#{ctx.main.session_key}",
               principal: {:session, ctx.main.session_key},
               session_key: nil,
               params: %{assignment_id: assignment_id, reason: "decision recipient disposition"}
             })
  end

  test "terminal lineage exhaustion transfers cannot-proceed disposition to the alerted user",
       ctx do
    assignment =
      Assignments.__handle__(ctx.db, "assign", %{
        verb: "assign",
        origin: "agent:#{ctx.main.session_key}",
        principal: {:session, ctx.main.session_key},
        session_key: "holder",
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{subject: "terminal disposer transfer", idempotency_key: nil, work_item_id: nil}
      })

    blocked =
      Assignments.__handle__(ctx.db, "attest", %{
        verb: "attest",
        origin: "agent:holder",
        principal: {:session, "holder"},
        session_key: nil,
        params: %{
          assignment_id: assignment.id,
          kind: "cannot-proceed",
          note: "the opener lineage is exhausted"
        }
      })

    # The initial decision is already queued for Main. Consume that genuine
    # earlier turn before testing failure of the later bubble, rather than
    # accidentally failing the decision notice and treating it as a bubble.
    _ = deliver_ready_carriers!(ctx, ctx.main.session_key)

    assert {:ok, decision_turn} =
             Ledger.claim_next(ctx.db, ctx.main.session_key, "initial-decision")

    assert {:ok, [[decision_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT decisionWakeId FROM assignment_cannot_proceed WHERE id=?1",
               [blocked.cannotProceed.id]
             )

    assert {:ok, [[decision_seq, "running", source_assignment]]} =
             DB.transaction(
               ctx.db,
               &NoticeBatcher.source_delivery_turns_in_txn(&1, decision_wake_id)
             )

    assert decision_seq == decision_turn.seq
    assert source_assignment == assignment.id

    assert :ok =
             Ledger.finish(ctx.db, decision_turn.seq, "delivered", nil,
               owner_lease: decision_turn.owner_lease
             )

    cause_seq = fail_assigned_turn!(ctx.db, ctx.holder.session_key, assignment.id)
    assert :ok = Bubble.recognize_terminal(ctx.db, cause_seq)
    _ = deliver_ready_carriers!(ctx, ctx.supervisor.session_key)

    assert {:ok, supervisor_notice} =
             Ledger.claim_next(ctx.db, ctx.supervisor.session_key, "assigned-cause")

    assert :ok =
             Ledger.finish(ctx.db, supervisor_notice.seq, "failed", "assigned failure",
               owner_lease: supervisor_notice.owner_lease
             )

    assert :ok = Bubble.recognize_terminal(ctx.db, supervisor_notice.seq)
    _ = deliver_ready_carriers!(ctx, ctx.main.session_key)

    assert {:ok, main_notice} = Ledger.claim_next(ctx.db, ctx.main.session_key, "assigned-cause")

    assert :ok =
             Ledger.finish(ctx.db, main_notice.seq, "failed", "assigned failure",
               owner_lease: main_notice.owner_lease
             )

    assert :ok = Bubble.recognize_terminal(ctx.db, main_notice.seq)

    assert {:ok, [["user:flynn"]]} =
             DB.query(
               ctx.db,
               "SELECT disposerRef FROM assignment_cannot_proceed WHERE id=?1",
               [blocked.cannotProceed.id]
             )

    assert %{outcome: "revoked"} =
             Assignments.__handle__(ctx.db, "revoke-assignment", %{
               verb: "revoke-assignment",
               origin: "user:flynn",
               principal: {:user, "flynn"},
               session_key: nil,
               params: %{assignment_id: assignment.id, reason: "terminal disposition"}
             })
  end
end
