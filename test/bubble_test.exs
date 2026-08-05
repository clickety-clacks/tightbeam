defmodule Tightbeam.Productions.BubbleTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConditionFacts, ConnRegistry, DB, Ledger, Model, Org}
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
    :ok = Ledger.finish(db, turn.seq, terminal, error)
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
    assert prompt =~ "holder"
    assert prompt =~ "quota exhausted"

    # Recognizing the same terminal again is a rung of the SAME climb: the
    # deterministic wakeId absorbs it. One notice, not two.
    :ok = Bubble.recognize_terminal(ctx.db, seq)
    assert [_] = notice_turn(ctx.db, "supervisor")
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
    :ok = Ledger.finish(ctx.db, notice.seq, "failed", "quota exhausted")
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
    :ok = Ledger.finish(ctx.db, top.seq, "failed", "quota exhausted")
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
    :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
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
      :ok = Ledger.finish(ctx.db, notice.seq, "failed", "new wall")
      :ok = Bubble.recognize_terminal(ctx.db, notice.seq)
    end

    assert ConditionFacts.standing?(ctx.db, "user-alerted", "flynn")
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
