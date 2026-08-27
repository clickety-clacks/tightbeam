defmodule Tightbeam.Productions.BubbleTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConditionFacts, ConnRegistry, DB, HarnessHealth, Ledger, Model, Org}
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
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('flynn', 1, 'admin_add', 1)"
      )

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

  defp notice_turn(db, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT seq, requestRef, wakeId, origin, prompt FROM turns WHERE sessionKey = ?1 AND requestRef LIKE 'bubble:%' ORDER BY seq",
        [session_key]
      )

    rows
  end

  test "a spawned session's failed turn produces one deduped notice to its parent", ctx do
    seq = fail_turn!(ctx.db, "holder")

    :ok = Bubble.recognize_terminal(ctx.db, seq)

    assert [[_, request_ref, wake_id, origin, prompt]] = notice_turn(ctx.db, "supervisor")
    assert request_ref == "bubble:#{seq}"
    assert wake_id == "bubble:#{seq}:supervisor"
    assert origin == "process:tightbeam"
    assert String.starts_with?(prompt, "[from process:tightbeam]\n\nTurn #{seq}")
    assert prompt =~ "holder"
    assert prompt =~ "quota exhausted"

    # Recognizing the same terminal again is a rung of the SAME climb: the
    # deterministic wakeId absorbs it. One notice, not two.
    :ok = Bubble.recognize_terminal(ctx.db, seq)
    assert [_] = notice_turn(ctx.db, "supervisor")
  end

  test "a failed turn bubbles to the operational parent, not the spawning session", ctx do
    operational_supervisor = session(ctx.db, "operational-supervisor", ctx.main.session_key)

    holder =
      Org.set_operational_parent(
        ctx.db,
        ctx.holder.session_key,
        operational_supervisor.session_key
      )

    seq = fail_turn!(ctx.db, holder.session_key)
    :ok = Bubble.recognize_terminal(ctx.db, seq)

    assert holder.spawned_by == ctx.supervisor.session_key

    assert [[_, "bubble:" <> _, _, _, _]] =
             notice_turn(ctx.db, operational_supervisor.session_key)

    assert notice_turn(ctx.db, ctx.supervisor.session_key) == []
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

  test "Main is the operational-parent terminus for its own failure", ctx do
    seq = fail_turn!(ctx.db, ctx.main.session_key)
    :ok = Bubble.recognize_terminal(ctx.db, seq)

    assert notice_turn(ctx.db, "supervisor") == []
    assert ConditionFacts.standing?(ctx.db, "user-alerted", "flynn")
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

    :ok =
      Ledger.finish(ctx.db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

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
end
