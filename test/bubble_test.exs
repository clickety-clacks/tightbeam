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

  # The spec's proofs 2–4 (production-machine-v1 §Proofs): the climb is
  # delivery-driven, the terminal alert is tokenless and stands as a fact,
  # and retraction is observed. Lineage under test:
  #
  #   main (flynn's personal session, parentless)
  #     └─ supervisor
  #          └─ holder
  setup do
    case ConnRegistry.start_link(name: Tightbeam.ConnRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # The bubble's notice enqueue rings the real LaneManager name; answer the
    # doorbell so delivery completes without a lane runtime in the test.
    start_supervised!({LaneDoorbell, Tightbeam.LaneManager})

    db = :"bubble_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    main = session(db, Org.personal_session_key("flynn"), nil, true)
    supervisor = session(db, "supervisor", main.session_key)
    holder = session(db, "holder", supervisor.session_key)

    %{db: db, main: main, supervisor: supervisor, holder: holder}
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

  defp cannot_proceed_assignment!(ctx, holder_session, opener_session, subject) do
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
        params: %{
          assignment_id: assignment.id,
          kind: "cannot-proceed",
          note: "the opener must decide"
        }
      })

    {assignment.id, blocked}
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
      assert {:ok, {:appended, ^recipient, _message, _opts}} =
               DB.transaction(ctx.db, fn txn ->
                 Tightbeam.Gateway.deliver_prompt_in_txn(
                   txn,
                   carrier.session_key,
                   carrier.origin,
                   carrier.prompt,
                   wake_id: carrier.wake_id,
                   sender: carrier.origin,
                   target_gate: carrier,
                   fire_wake_in_txn: true
                 )
               end)
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

    assert delivery in [:appended, :queued]
    if delivery == :queued, do: deliver_ready_carriers!(ctx, ctx.holder.session_key)

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

  test "a staged decision bubble transfers disposal to its busy recipient", ctx do
    {assignment_id, blocked} =
      cannot_proceed_assignment!(
        ctx,
        ctx.holder.session_key,
        ctx.supervisor.session_key,
        "decision bubble disposer"
      )

    decision_wake = blocked.decisionWake
    queue_decision_wake!(ctx, decision_wake)
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

    assert {:ok, {:appended, main_session, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.Gateway.deliver_prompt_in_txn(
                 txn,
                 carrier.session_key,
                 carrier.origin,
                 carrier.prompt,
                 wake_id: carrier.wake_id,
                 sender: carrier.origin,
                 target_gate: carrier,
                 fire_wake_in_txn: true
               )
             end)

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
