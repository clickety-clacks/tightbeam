defmodule Tightbeam.CoordinationFabricTest do
  @moduledoc """
  Seams ① and ② of coordination-fabric-v1 §13 Phase 1.

  The proofs are named for the law each one holds down, because every one of
  them is a law this mechanism could plausibly break: batching that lost a row
  (Law 2), a wait whose exit was someone's decision (Invariant 3), a substrate
  that overwrote what a sender said (§5 classifier), or a reflex nobody could
  attribute (§8 legibility).
  """
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Wakes}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = ensure_all_schemas(name)
    %{db: name}
  end

  ## Seam ① — the class vocabulary

  test "the classifier stamps only unclassified traffic and never overwrites an election" do
    for class <- Wakes.seed_classes() do
      assert Wakes.classify(class) == {class, "sender"}
    end

    # An extended class this build never heard of is still the SENDER's word.
    assert Wakes.classify("kungfu:deploy-window") == {"kungfu:deploy-window", "sender"}

    # Only the absent election takes the stamp.
    assert Wakes.classify(nil) == {"fyi", "classifier"}
    assert Wakes.classify("") == {"fyi", "classifier"}
    assert Wakes.classifier_default() == "fyi"
  end

  test "the seed policy is §7's table verbatim and every rule names itself" do
    assert %{immediacy: :digest, ceiling_ms: 14_400_000} = Wakes.delivery_policy("fyi")
    assert %{immediacy: :digest, ceiling_ms: 1_800_000} = Wakes.delivery_policy("status-query")
    assert %{immediacy: :digest, ceiling_ms: 1_800_000} = Wakes.delivery_policy("input-needed")
    assert %{immediacy: :immediate} = Wakes.delivery_policy("blocker")
    assert %{immediacy: :bypass} = Wakes.delivery_policy("algedonic")

    for class <- Wakes.seed_classes() do
      policy = Wakes.delivery_policy(class)
      refute policy.skew
      # §8: an unattributable reflex is a bug. Rule AND revision, always.
      assert policy.rule =~ ~r/ r\d+$/
    end

    assert Wakes.delivery_policy("algedonic").rule =~ "bypass"
  end

  test "an unknown class is delivered as fyi with a named skew row, never dropped or promoted",
       %{db: db} do
    skewed = Wakes.delivery_policy("kungfu:nobody-mapped-this")

    assert skewed.skew
    assert skewed.immediacy == :digest
    assert skewed.ceiling_ms == Wakes.delivery_policy("fyi").ceiling_ms

    wake = schedule(db, session: "agent:po", class: "kungfu:nobody-mapped-this")

    # LAW 2: the row keeps what the sender said. The policy skewed, the record
    # did not.
    assert wake.class == "kungfu:nobody-mapped-this"
    assert wake.class_election == "sender"

    assert {:ok, [[detail]]} =
             DB.query(
               db,
               "SELECT detail FROM lifecycle_events WHERE kind = 'wake_class_policy_skew' AND subject = ?1",
               [wake.wake_id]
             )

    assert detail =~ "class=kungfu:nobody-mapped-this"
    assert detail =~ "deliveredAs=fyi"
  end

  test "algedonic is never batched and blocker delivers immediately", %{db: db} do
    at = System.system_time(:millisecond)

    alarm = schedule(db, session: "agent:po", class: "algedonic", due_at: at)
    blocker = schedule(db, session: "agent:po", class: "blocker", due_at: at)

    assert alarm.due_at == at
    assert blocker.due_at == at
    assert alarm.delivery_rule =~ "algedonic-bypass"
    assert blocker.delivery_rule =~ "immediate-delivery"

    # Neither is a digest member: the batcher has nothing to carry.
    assert Wakes.materialize_digests(db, at) == []
    assert Wakes.get(db, alarm.wake_id).state == "pending"
    assert Wakes.get(db, blocker.wake_id).state == "pending"
  end

  test "an unclassed wake is untouched by the policy", %{db: db} do
    at = System.system_time(:millisecond)
    wake = schedule(db, session: "agent:po", due_at: at)

    assert wake.class == nil
    assert wake.class_election == nil
    assert wake.delivery_rule == nil
    assert wake.due_at == at
    assert Wakes.materialize_digests(db, at) == []
  end

  test "the batcher's inhibition seam is nameable: a sender's own schedule wins", %{db: db} do
    at = System.system_time(:millisecond) + 90_000
    wake = schedule(db, session: "agent:po", class: "fyi", due_at: at, sender_scheduled: true)

    assert wake.due_at == at, "an elected delivery time is not the batcher's to move"
    assert wake.delivery_rule == Wakes.inhibited_rule()
    assert Wakes.materialize_digests(db, at) == []
  end

  ## Seam ② — the batcher

  test "the ceiling is the exit for an idle session: the digest materializes its own turn",
       %{db: db} do
    a = schedule(db, session: "agent:po", class: "fyi", prompt: "the build finished")
    b = schedule(db, session: "agent:po", class: "fyi", prompt: "docs merged")

    # The clock the batcher reads is the ROW's, not the test's: a wall clock
    # sampled a millisecond earlier makes this proof pass by luck.
    ceiling = Wakes.delivery_policy("fyi").ceiling_ms
    due = b.created_at + ceiling
    assert a.due_at - a.created_at == ceiling
    assert a.delivery_rule == Wakes.digest_rule()

    # No turn ever runs for this session. Before the ceiling: nothing fires —
    # and nothing is lost either.
    assert Wakes.materialize_digests(db, a.created_at + ceiling - 1) == []
    assert Wakes.get(db, a.wake_id).state == "pending"

    # At the ceiling the digest exists WITHOUT anyone deciding anything.
    assert [digest_id] = Wakes.materialize_digests(db, due)
    digest = Wakes.get(db, digest_id)

    assert digest.digest
    assert digest.class == "fyi"
    assert digest.state == "pending"
    assert digest.prompt =~ "the build finished"
    assert digest.prompt =~ "docs merged"
    assert digest.prompt =~ Wakes.digest_signature(2)

    assert Enum.map(Wakes.digest_members(db, digest_id), & &1.wake_id) == [a.wake_id, b.wake_id]
  end

  test "a turn boundary materializes the digest early, and only when the session is free",
       %{db: db} do
    session = "agent:po"
    held = schedule(db, session: session, class: "fyi", prompt: "one")

    # A turn that is still RUNNING is not a boundary.
    seq = turn(db, session, status: "running", created_at: held.created_at + 10)
    assert Wakes.materialize_digests(db, held.created_at + 20) == []

    # Ending it is.
    end_turn(db, seq, held.created_at + 30)
    assert [digest_id] = Wakes.materialize_digests(db, held.created_at + 40)
    assert Wakes.get(db, digest_id).due_at == held.created_at + 40

    # Far short of the four-hour ceiling: the boundary, not the clock, released it.
    assert held.created_at + 40 < held.due_at
  end

  test "a turn that ended BEFORE the message arrived is not that message's boundary",
       %{db: db} do
    session = "agent:po"
    base = System.system_time(:millisecond)

    seq = turn(db, session, status: "running", created_at: base - 1_000)
    end_turn(db, seq, base - 500)

    held = schedule(db, session: session, class: "fyi", prompt: "arrived after the turn ended")

    assert Wakes.materialize_digests(db, held.created_at + 1) == [],
           "a boundary in the past never protected attention that was not yet spent"
  end

  test "classes are digested apart, so a 30-minute ceiling is not stretched to four hours",
       %{db: db} do
    schedule(db, session: "agent:po", class: "fyi", prompt: "fyi one")
    decision = schedule(db, session: "agent:po", class: "input-needed", prompt: "pick a or b")

    assert decision.due_at - decision.created_at == 1_800_000

    assert [digest_id] = Wakes.materialize_digests(db, decision.due_at)
    digest = Wakes.get(db, digest_id)

    assert digest.class == "input-needed"
    assert digest.prompt =~ "pick a or b"
    refute digest.prompt =~ "fyi one"
  end

  test "LAW 2: a carried member keeps its row and points at the digest that carries it",
       %{db: db} do
    member =
      schedule(db, session: "agent:po", class: "fyi", prompt: "the whole payload, verbatim")

    assert [digest_id] = Wakes.materialize_digests(db, member.due_at)

    carried = Wakes.get(db, member.wake_id)

    # Consumed, but NOT as delivered — `fired` is this substrate's word for
    # delivered and the member was never individually delivered.
    assert carried.state == "canceled"
    assert carried.prompt == "the whole payload, verbatim"
    assert carried.class == "fyi"
    assert carried.class_election == "sender"

    assert {:ok, [[reason, outcome, replacement, requester]]} =
             DB.query(
               db,
               """
               SELECT reasonKind, outcomeKind, replacementWakeId, requesterId
               FROM wake_cancellations WHERE wakeId = ?1
               """,
               [member.wake_id]
             )

    assert reason == "superseded"
    assert outcome == "replacement"
    assert replacement == digest_id
    assert requester == "tightbeam:batcher"

    assert [%{prompt: "the whole payload, verbatim"}] = Wakes.digest_members(db, digest_id)
  end

  test "the digest names the rule that produced it and the trigger that released it",
       %{db: db} do
    held = schedule(db, session: "agent:po", class: "fyi", prompt: "one")

    assert [digest_id] = Wakes.materialize_digests(db, held.due_at)

    assert {:ok, [[detail]]} =
             DB.query(
               db,
               "SELECT detail FROM lifecycle_events WHERE kind = 'wake_digest_materialized' AND subject = ?1",
               [digest_id]
             )

    assert detail =~ "rule=#{Wakes.digest_rule()}"
    assert detail =~ "members=1"
    assert detail =~ "trigger=ceiling"
    assert Wakes.get(db, digest_id).prompt =~ "coalesced by #{Wakes.digest_rule()}"
  end

  test "a digest carrier is not itself held, and materializing twice carries nothing twice",
       %{db: db} do
    held = schedule(db, session: "agent:po", class: "fyi", prompt: "one")
    at = held.due_at

    assert [digest_id] = Wakes.materialize_digests(db, at)

    carrier = Wakes.get(db, digest_id)
    assert carrier.digest, "a carrier not flagged as one would join its own next group"
    assert carrier.delivery_rule == Wakes.digest_rule()
    assert carrier.due_at == at, "the carrier fires at the moment the rule chose, not a ceiling"

    assert Wakes.materialize_digests(db, at) == []
    assert length(Wakes.digest_members(db, digest_id)) == 1
  end

  ## Seam ① — the acceptance-№1 read (§12 Q5)

  test "coordination share counts classed non-summon non-algedonic turns against all turns",
       %{db: db} do
    session = "agent:po"
    base = System.system_time(:millisecond)

    ordinary = schedule(db, session: session, due_at: base)
    fyi = schedule(db, session: session, class: "fyi", sender_scheduled: true, due_at: base)
    alarm = schedule(db, session: session, class: "algedonic", due_at: base)

    turn(db, session, created_at: base, wake_id: ordinary.wake_id)
    turn(db, session, created_at: base + 1, wake_id: fyi.wake_id)
    turn(db, session, created_at: base + 2, wake_id: alarm.wake_id)
    turn(db, session, created_at: base + 3)

    share = Wakes.coordination_share(db, session, base, base + 10)

    assert share.turns == 4
    assert share.wake_turns == 3
    assert share.classed_turns == 2
    assert share.coordination_turns == 1
    assert share.algedonic_turns == 1
    assert share.summon_turns == 0
    assert share.share == 0.25
    assert share.by_class == %{"fyi" => 1, "algedonic" => 1}
  end

  test "a summon is a deliberate spend, subtracted from the share", %{db: db} do
    session = "agent:po"
    base = System.system_time(:millisecond)

    summon =
      schedule(db,
        session: session,
        class: "input-needed",
        sender_scheduled: true,
        due_at: base,
        summon: true
      )

    turn(db, session, created_at: base, wake_id: summon.wake_id)

    share = Wakes.coordination_share(db, session, base, base + 10)

    assert share.classed_turns == 1
    assert share.summon_turns == 1
    assert share.coordination_turns == 0
    assert share.share == 0.0
  end

  test "an empty window reports a null share, never zero", %{db: db} do
    base = System.system_time(:millisecond)
    share = Wakes.coordination_share(db, "agent:po", base, base + 10)

    assert share.turns == 0
    assert share.share == nil
    assert share.by_class == %{}
  end

  ## The verb seam

  test "the coordination-share verb reads for the owner, refuses a bad window, and is not a session oracle",
       %{db: db} do
    base = System.system_time(:millisecond)
    seed_session(db, "agent:po", "owner")
    seed_session(db, "agent:stranger", "outsider")
    turn(db, "agent:po", created_at: base)

    assert {:ok, share} =
             share_call(db, {:user, "owner"}, %{session: "agent:po", from: base, to: base + 10})

    assert share.turns == 1
    assert share.share == 0.0

    assert {:error, %{code: "invalid"}} =
             share_call(db, {:user, "owner"}, %{session: "agent:po", from: base + 10, to: base})

    assert {:error, %{code: "invalid"}} =
             share_call(db, {:user, "owner"}, %{session: "agent:po", from: base})

    # A session this caller may not read and a session that does not exist give
    # the SAME answer — otherwise the read is an existence oracle.
    assert {:error, %{code: "not_found", message: unreadable}} =
             share_call(db, {:user, "outsider"}, %{session: "agent:po", from: base, to: base + 10})

    assert {:error, %{code: "not_found", message: absent}} =
             share_call(db, {:user, "outsider"}, %{
               session: "agent:ghost",
               from: base,
               to: base + 10
             })

    assert unreadable == absent
  end

  ## Helpers

  defp share_call(db, principal, params) do
    handlers = Tightbeam.Gateway.handlers(%{db: db, wake_tick_ms: 1_000})

    Tightbeam.Dispatch.dispatch(db, handlers, %{
      verb: "coordination-share",
      origin: principal_origin(principal),
      principal: principal,
      session_key: nil,
      params: Map.put_new(params, :session_key, params[:session])
    })
  end

  defp principal_origin({:user, id}), do: "user:#{id}"
  defp principal_origin({:session, key}), do: "agent:#{key}"

  defp seed_session(db, session_key, owner) do
    {:ok, _} =
      DB.query(db, "INSERT OR IGNORE INTO users (userId, isAdmin, createdAt) VALUES (?1, 0, 1)", [
        owner
      ])

    Tightbeam.Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "coder",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable"),
      host: Tightbeam.Placement.local_host_name()
    })

    :ok
  end

  defp schedule(db, opts) do
    Wakes.schedule(db, %{
      session_key: Keyword.fetch!(opts, :session),
      origin: Keyword.get(opts, :origin, "agent:sender"),
      creator_session_key: Keyword.get(opts, :creator, "agent:sender"),
      prompt: Keyword.get(opts, :prompt, "go"),
      due_at: Keyword.get_lazy(opts, :due_at, fn -> System.system_time(:millisecond) end),
      class: Keyword.get(opts, :class),
      sender_scheduled: Keyword.get(opts, :sender_scheduled, false),
      summon: Keyword.get(opts, :summon, false)
    })
  end

  defp turn(db, session_key, opts) do
    created_at = Keyword.fetch!(opts, :created_at)
    seq = System.unique_integer([:positive, :monotonic])

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO turns (seq, sessionKey, messageId, wakeId, origin, prompt, status, createdAt)
        VALUES (?1, ?2, ?3, ?4, 'agent:sender', 'go', ?5, ?6)
        """,
        [
          seq,
          session_key,
          "m_#{seq}",
          Keyword.get(opts, :wake_id),
          Keyword.get(opts, :status, "delivered"),
          created_at
        ]
      )

    seq
  end

  defp end_turn(db, seq, ended_at) do
    {:ok, _} =
      DB.query(db, "UPDATE turns SET status = 'delivered', endedAt = ?2 WHERE seq = ?1", [
        seq,
        ended_at
      ])

    :ok
  end
end
