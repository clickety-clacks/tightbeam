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

  alias Tightbeam.{DB, Escalation, Wakes}

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

  test "a scheduled or conditional algedonic wake is never batcher-inhibited", %{db: db} do
    # Sol xhigh review, finding 1: the class check precedes the inhibition
    # branch. §7: algedonic "bypasses every bone... never batched, never
    # digested, never triaged." A sender's own --after on an algedonic wake is
    # the sender's OWN election, not the batcher holding anything — the row
    # must carry the bypass rule, never `batcher-inhibited`, and the sender's
    # chosen time, never a ceiling.
    at = System.system_time(:millisecond) + 4 * 60 * 60 * 1000
    # Sol xhigh review round 2, finding 4: exact equality, not `=~` — a
    # prefixed or revised rule string must not slip past this assertion.
    bypass_rule = Wakes.delivery_policy("algedonic").rule

    scheduled =
      schedule(db, session: "agent:po", class: "algedonic", due_at: at, sender_scheduled: true)

    assert scheduled.due_at == at, "the sender's own election, unmoved"
    assert scheduled.delivery_rule == bypass_rule
    refute scheduled.delivery_rule == Wakes.inhibited_rule()
    assert Wakes.materialize_digests(db, at) == []

    # A condition-scoped algedonic wake is likewise never inhibited: its own
    # firing mechanics govern it, and the delivery-policy row must not claim
    # the batcher held it either.
    conditioned =
      Wakes.schedule(db, %{
        session_key: "agent:po",
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "pain, gated on a fact",
        due_at: at,
        class: "algedonic",
        condition_kind: "work-blocked",
        condition_scope: "agent:po"
      })

    assert conditioned.delivery_rule == bypass_rule
    refute conditioned.delivery_rule == Wakes.inhibited_rule()
    assert conditioned.due_at == at, "the sender's elected time, unchanged"
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

  test "a turn boundary materializes the digest early", %{db: db} do
    session = "agent:po"
    held = schedule(db, session: session, class: "fyi", prompt: "one")

    # A turn that has not yet ENDED is not a boundary — an in-flight turn's
    # end is the trigger, not its start.
    seq = turn(db, session, status: "running", created_at: held.created_at + 10)
    assert Wakes.materialize_digests(db, held.created_at + 20) == []

    # Ending it is.
    end_turn(db, seq, held.created_at + 30)
    assert [digest_id] = Wakes.materialize_digests(db, held.created_at + 40)
    assert Wakes.get(db, digest_id).due_at == held.created_at + 40

    # Far short of the four-hour ceiling: the boundary, not the clock, released it.
    assert held.created_at + 40 < held.due_at
  end

  test "a turn boundary releases the digest even with more work queued behind it",
       %{db: db} do
    # Sol xhigh review, finding 3: `turn_boundary_passed?` must not require
    # `busy == 0`. A turn boundary is a turn ENDING — the digest joins the
    # queue at that boundary rather than waiting for the session to go idle,
    # which with continuous queued work would mean never.
    session = "agent:po"
    held = schedule(db, session: session, class: "fyi", prompt: "one")

    ended = turn(db, session, status: "running", created_at: held.created_at + 10)
    end_turn(db, ended, held.created_at + 20)

    # Another turn is QUEUED behind the boundary that just released `held`.
    _queued = turn(db, session, status: "queued", created_at: held.created_at + 25)

    assert [digest_id] = Wakes.materialize_digests(db, held.created_at + 30),
           "queued work behind an already-passed boundary must not hold the digest"

    assert Wakes.get(db, digest_id).due_at == held.created_at + 30
  end

  test "the ceiling fires even during an in-flight turn", %{db: db} do
    # The ceiling is TIME, not a session-state judgment: a turn still running
    # when the ceiling arrives is not a reason to withhold delivery.
    session = "agent:po"
    held = schedule(db, session: session, class: "fyi", prompt: "one")
    _running = turn(db, session, status: "running", created_at: held.created_at + 10)

    assert [digest_id] = Wakes.materialize_digests(db, held.due_at)
    assert Wakes.get(db, digest_id).class == "fyi"
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

  test "a member filed after the trigger waits for its own boundary, not somebody else's",
       %{db: db} do
    # Sol xhigh review, finding 2: eligibility and membership must be one
    # transactionally coherent snapshot. A member the outer group query never
    # saw at all — filed after a boundary already released an earlier member
    # of the SAME session/class group — must not be swept into that earlier
    # member's digest by an unqualified "grab everything pending" query.
    session = "agent:po"

    early =
      schedule(db, session: session, class: "fyi", prompt: "early, released by the boundary")

    seq = turn(db, session, status: "running", created_at: early.created_at)
    ended_at = early.created_at + 10
    end_turn(db, seq, ended_at)

    late = schedule(db, session: session, class: "fyi", prompt: "late, arrived after the trigger")

    # Deterministically AFTER the boundary that released `early` — pinned by
    # direct injection, never raced against the real clock (Sol xhigh review
    # round 2, finding 1): `Wakes.schedule` always stamps `createdAt` from its
    # own clock, so there is no public way to make this ordering exact except
    # to set it directly, the same way `turn`/`end_turn` already inject their
    # own timestamps below.
    stamp_created_at!(db, late, ended_at + 10)

    assert [digest_id] = Wakes.materialize_digests(db, ended_at + 20)

    assert Enum.map(Wakes.digest_members(db, digest_id), & &1.wake_id) == [early.wake_id]

    assert Wakes.get(db, late.wake_id).state == "pending",
           "a late arrival is not carried by a boundary that passed before it was filed"

    # `late` still has its own ceiling ahead of it: nothing lost, only delayed —
    # it gets its OWN digest once its own trigger arrives.
    assert [late_digest_id] = Wakes.materialize_digests(db, late.due_at)
    assert late_digest_id != digest_id
    assert Enum.map(Wakes.digest_members(db, late_digest_id), & &1.wake_id) == [late.wake_id]
  end

  test "a member filed in the same millisecond as a turn's end waits for the next boundary",
       %{db: db} do
    # Sol xhigh review round 2, finding 1: `boundary >= created_at` treated a
    # wake filed in the SAME millisecond a turn ended as already past that
    # boundary. Same-millisecond is ambiguous ordering — not proof the turn
    # ended AFTER the wake was filed — so it must NOT release the digest.
    # Pinned with exact injected timestamps, never raced against the clock.
    session = "agent:po"

    edge =
      schedule(db, session: session, class: "fyi", prompt: "same millisecond as the boundary")

    seq = turn(db, session, status: "running", created_at: edge.created_at)
    end_turn(db, seq, edge.created_at)

    assert Wakes.materialize_digests(db, edge.created_at + 1) == [],
           "an equal createdAt/endedAt is not proof the boundary happened after filing"

    # A turn ending STRICTLY after the member's filing time resolves it.
    next_seq = turn(db, session, status: "running", created_at: edge.created_at + 1)
    end_turn(db, next_seq, edge.created_at + 1)

    assert [digest_id] = Wakes.materialize_digests(db, edge.created_at + 2)
    assert Enum.map(Wakes.digest_members(db, digest_id), & &1.wake_id) == [edge.wake_id]
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

  test "the carrier is honestly attributed to the batcher; members keep their true elections",
       %{db: db} do
    # Sol xhigh review, finding 7: a digest carrier passing `class: class` to
    # `elected_class/1` used to be read as a sender election. The carrier was
    # built by the batcher, not elected by anyone — and a group can mix a
    # sender's own election with the classifier's default stamp, both of
    # which must survive on their SOURCE rows untouched.
    session = "agent:po"

    sender_elected = schedule(db, session: session, class: "fyi", prompt: "sender said fyi")

    classifier_elected =
      Wakes.schedule(db, %{
        session_key: session,
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "unclassed, the classifier stamped it",
        due_at: sender_elected.due_at,
        classify: true
      })

    assert classifier_elected.class == "fyi"
    assert classifier_elected.class_election == "classifier"

    # Both members' OWN ceilings, not the first one's — `classifier_elected`
    # was filed after `sender_elected`, so its own ceiling lands later.
    at = classifier_elected.created_at + Wakes.delivery_policy("fyi").ceiling_ms
    assert [digest_id] = Wakes.materialize_digests(db, at)
    carrier = Wakes.get(db, digest_id)

    assert carrier.class_election == "batcher",
           "the batcher built this row; claiming 'sender' would be an untrue audit fact"

    members = Wakes.digest_members(db, digest_id)
    elections = Map.new(members, &{&1.wake_id, &1.class_election})

    assert elections[sender_elected.wake_id] == "sender"
    assert elections[classifier_elected.wake_id] == "classifier"
  end

  test "digest_members is provenance-total: an adversarial supersession pointing at the carrier is not a member",
       %{db: db} do
    # Sol xhigh review, finding 6: matching only replacementWakeId/reasonKind/
    # outcomeKind proves a row was superseded BY SOMETHING naming this carrier
    # as its replacement — not that the BATCHER carried it. A legitimate,
    # differently-caused cancellation that happens to name the same
    # replacement must not be reported as a digest member.
    session = "agent:po"
    member = schedule(db, session: session, class: "fyi", prompt: "the true member")

    assert [digest_id] = Wakes.materialize_digests(db, member.due_at)
    assert Enum.map(Wakes.digest_members(db, digest_id), & &1.wake_id) == [member.wake_id]

    unrelated =
      Wakes.schedule(db, %{
        session_key: session,
        origin: "agent:other",
        prompt: "unrelated traffic, not carried by anything",
        due_at: member.due_at
      })

    forged_command = %{
      wake_id: unrelated.wake_id,
      requester: %{kind: "process", id: "tightbeam:effort-checkin"},
      reason_kind: "superseded",
      causal_source: %{kind: "wake", id: digest_id},
      outcome: %{kind: "replacement", replacement_wake_id: digest_id}
    }

    assert {:ok, true} =
             DB.transaction(db, fn txn -> Wakes.cancel_in_txn(txn, forged_command) end)

    # The forged row matches replacementWakeId/reasonKind/outcomeKind exactly,
    # and even names the carrier as its causal source — but it is not the
    # batcher's requesterId, so it must not appear as a member.
    assert Enum.map(Wakes.digest_members(db, digest_id), & &1.wake_id) == [member.wake_id]
  end

  test "a forced member-cancellation failure rolls back the whole materialization",
       %{db: db} do
    session = "agent:po"
    base = System.system_time(:millisecond)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('owner', 0, ?1)", [
        base
      ])

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO work_items (id, title, ownerUserId, state, createdByUser, createdAt)
        VALUES ('wi_broken', 'already closed', 'owner', 'closed', 'owner', ?1)
        """,
        [base]
      )

    ok_member = schedule(db, session: session, class: "fyi", prompt: "fine")

    broken_member =
      Wakes.schedule(db, %{
        session_key: session,
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "linked to closed work",
        due_at: base,
        class: "fyi",
        work_item_id: "wi_broken"
      })

    # `broken_member`'s own linked work is not open, so the batcher's typed
    # cancellation for it will be refused by `validate_outcome/4` — the ONE
    # failure the all-or-nothing rule exists to catch.
    at = broken_member.created_at + Wakes.delivery_policy("fyi").ceiling_ms

    assert_raise RuntimeError, ~r/incompatible_delivery_policy_v1/, fn ->
      Wakes.materialize_digests(db, at)
    end

    # FULL ROLLBACK: neither member was touched, no carrier exists, and
    # nothing was logged — the transaction layout's guarantee, demonstrated.
    assert Wakes.get(db, ok_member.wake_id).state == "pending"
    assert Wakes.get(db, broken_member.wake_id).state == "pending"
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM wake_cancellations")
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM wakes WHERE digest = 1")

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM lifecycle_events WHERE kind = 'wake_digest_materialized'"
             )
  end

  test "the scheduler materializes AND delivers its own turn for an idle session", %{db: db} do
    # Sol xhigh review, finding 9: prior coverage only ever called
    # `materialize_digests/2` directly and asserted a pending carrier — it
    # never ran the actual scheduler path. This runs `fire_due/1` — the real
    # tick — and asserts the carrier is DELIVERED, proving Invariant 3's "an
    # idle session's digest materializes its own turn" end to end.
    test_pid = self()
    scheduler = :"coordination_fabric_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake -> send(test_pid, {:delivered, wake}) end}
    )

    session = "agent:po"
    held = schedule(db, session: session, class: "fyi", prompt: "the build finished")

    ended = turn(db, session, status: "running", created_at: held.created_at + 10)
    end_turn(db, ended, held.created_at + 20)

    assert :ok = Wakes.fire_due(scheduler)

    assert_receive {:delivered, %{digest: true, class: "fyi"} = delivered}, 1_000
    assert delivered.prompt =~ "the build finished"
    assert Wakes.get(db, delivered.wake_id).state == "fired"
    assert Wakes.get(db, held.wake_id).state == "canceled"
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
    # §11.1's numerator is ALL non-summon, non-algedonic wake-materialized
    # turns, classed or not (Sol xhigh review, finding 5): `ordinary` carries
    # no class at all yet is still wake-materialized traffic, so it counts
    # alongside `fyi`. The prior pin of `1` here was the bug itself, not a
    # spec — it silently dropped every legacy unclassed wake turn from the
    # acceptance-№1 measure.
    assert share.coordination_turns == 2
    assert share.algedonic_turns == 1
    assert share.summon_turns == 0
    assert share.share == 0.5
    assert share.by_class == %{"fyi" => 1, "algedonic" => 1}
  end

  test "a dangling wakeId with no matching wake row is not counted as coordination traffic",
       %{db: db} do
    # Sol xhigh review round 2, finding 3: the numerator's COALESCE guards
    # passed even when the LEFT JOIN found NO wake row at all — a turn whose
    # `wakeId` names a wake that does not exist got `w.class` and `w.summon`
    # both read as NULL, which `COALESCE(w.class, '') <> 'algedonic'` and
    # `COALESCE(w.summon, 0) = 0` both waved through as "an unclassed,
    # non-summon wake." It is not a wake at all. Requiring the JOIN actually
    # match (`w.wakeId IS NOT NULL`) excludes it.
    session = "agent:po"
    base = System.system_time(:millisecond)

    turn(db, session, created_at: base, wake_id: "w_never_existed")
    turn(db, session, created_at: base + 1)

    share = Wakes.coordination_share(db, session, base, base + 10)

    assert share.turns == 2
    assert share.wake_turns == 1, "the turn still names a wakeId, dangling or not"
    assert share.classed_turns == 0

    assert share.coordination_turns == 0,
           "a dangling wakeId is not a wake-materialized turn — nothing was ever carried"

    assert share.share == 0.0
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

  ## Seam ③ — the `input-needed` carrier (GitHub #11)

  test "an agent's question and the notification that carries it are one commit", %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    seed_session(db, "agent:po", "flynn")

    assert {:ok, %{decision_request: request}} =
             ask(db, "agent:coder", "agent:po", "ship behind a flag or block?")

    assert request.kind == "agent"
    assert request.status == "open"
    assert request.raiser_id == "session:agent:coder"
    assert request.raiser_session_key == "agent:coder"
    assert request.expecter_session_key == "agent:po"
    assert request.expecter_user_id == "flynn"
    assert request.question == "ship behind a flag or block?"
    assert request.answer == nil

    # NONE of the adjudication vocabulary, and this is the assertion the seam
    # exists to keep true: an answer is not a verdict, so there is nowhere on
    # this row for one to be written.
    assert request.statute_name == nil
    assert request.action_key == nil
    assert request.decision == nil
    assert request.ruled_by == nil
    assert request.ruling_fact_id == nil
    assert request.park_wake_id == nil
    assert request.consumed_at == nil

    # No deadline either (Sol xhigh review, finding 1): a question is not
    # swept, so it must not be indistinguishable from a statute/effort row to
    # a generic `status = 'open' AND deadlineAt <= ?` consumer.
    assert request.deadline_at == nil

    # The transactional outbox: one wake, at the asked session, elected
    # `input-needed` by the asker — so seam ②'s policy batches it to the target's
    # next turn boundary or the 30-minute floor, whichever comes first.
    assert [notice] = wakes_for(db, "agent:po")
    assert notice.class == "input-needed"
    assert notice.class_election == "sender"
    assert notice.delivery_rule == Wakes.digest_rule()
    assert notice.target_gate == 0
    assert notice.prompt =~ request.id
    assert notice.prompt =~ "ship behind a flag or block?"
    assert notice.due_at - notice.created_at == Wakes.delivery_policy("input-needed").ceiling_ms
  end

  test "THE TRIPWIRE: an open question gates nothing (fabric §10)", %{db: db} do
    # Two halves, and the second is the one a substrate reaches for by reflex.
    #
    # HALF ONE, behavioural: an open question naming an assignment does not stop
    # its holder completing and closing that assignment. If it ever does,
    # adjudication has been rebuilt with a friendlier face.
    seed_session(db, "agent:coder", "flynn")
    seed_session(db, "agent:po", "flynn")
    assignment = open_assignment(db, "agent:coder")

    assert {:ok, %{decision_request: request}} =
             ask(db, "agent:coder", "agent:po", "which way?", assignment_id: assignment.id)

    assert request.assignment_id == assignment.id
    assert request.status == "open"

    assert %{attest: %{kind: "completion"}} =
             Tightbeam.Assignments.__handle__(db, "attest", %{
               verb: "attest",
               origin: "agent:agent:coder",
               principal: {:session, "agent:coder"},
               session_key: nil,
               params: %{assignment_id: assignment.id, kind: "completion"}
             })

    # The question is STILL OPEN and the card closed anyway — the asker held its
    # obligation throughout and disposed of it by its own choice.
    assert get_request(db, request.id).status == "open"

    # HALF TWO, structural (Sol xhigh review round 2, finding 1). The
    # enumeration this test used to run — every `status = 'open'` literal
    # across a fixed file list, checked for a `kind` predicate — had false
    # negatives no scan can close on its own: a NEW file could gain a reader
    # invisibly, `status = 'open'` matched only that exact spelling (a
    # parameterized or assembled predicate evades it), a concatenated literal
    # is never reconstructed, and the `id = ?`/retirement-sweep exemptions
    # were bound to string shapes, not to the table. `escalation.ex` now
    # centralizes EVERY production read and write of `decision_requests`
    # behind named, kind-classified functions (`@external_reader_kinds`,
    # documented above `raw_by_id/2`) — so the structural half shrinks to two
    # checks that are reliable BECAUSE there is nowhere else for a query to
    # hide, not because this scan is clever:
    #
    #   (a) no `decision_requests` literal exists anywhere in `lib/` outside
    #       `escalation.ex` — proved with the same text scan as before, now
    #       with ZERO allowlist besides that one file.
    #
    #   (b) `escalation.ex`'s own helper inventory, name-to-kind-scope, equals
    #       a pinned copy — so a new helper, or a scope that silently widens
    #       from (say) `"statute"` to `"any"`, fails here until it is
    #       reviewed and this pin is updated by hand.
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&(&1 == "lib/tightbeam/escalation.ex"))
      |> Enum.flat_map(fn file ->
        file
        |> sql_literals()
        |> Enum.filter(&(&1 =~ "decision_requests"))
        |> Enum.map(&{file, &1})
      end)

    assert offenders == [],
           "a decision_requests literal outside escalation.ex: #{inspect(offenders)}"

    assert Tightbeam.Escalation.external_reader_kinds() == %{
             raw_by_id: "any",
             raw_by_id_in_txn: "any",
             raw_by_id_in_txn!: "any",
             raw_exists_in_txn?: "any",
             statute_name_for_ruling: "any",
             effort_open_by_deadline_wake_in_txn: "effort",
             effort_insert_in_txn: "effort",
             effort_id_by_generation_in_txn: "effort",
             effort_supersede_open_in_txn: "effort",
             effort_update_generation_in_txn: "effort",
             effort_rule_in_txn: "effort",
             statute_park_candidate_in_txn: "statute",
             claim_park_wake_in_txn: "any",
             open_counts_by_assignment: "statute,effort",
             decision_trace_rows: "any",
             wake_link_fragment: "any"
           },
           "escalation.ex's external-reader inventory changed; review the new/changed " <>
             "entry's kind scope and update this pin"
  end

  # Every double-quoted or triple-quoted string literal in a file's raw
  # source, scanned as TEXT rather than parsed AST (Sol xhigh review, finding
  # 2) — a query built with `#{@request_columns}` interpolation is not a plain
  # `is_binary` AST node and an AST scan would silently skip it.
  defp sql_literals(file) do
    Regex.scan(~r/"""(?:(?!""").)*"""|"[^"\n]*"/s, File.read!(file))
    |> List.flatten()
  end

  test "the statute gate read cannot be reached by an agent row sharing its raiser",
       %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    seed_session(db, "agent:po", "flynn")

    # An open AGENT question from `agent:coder`, filed alongside an open
    # STATUTE escalation from the very same raiser — the closest two rows can
    # get to colliding on `current_request/4`'s key. If its `kind = 'statute'`
    # predicate were ever dropped, `statuteName`/`actionKey` being NULL on the
    # agent row already makes a collision structurally impossible; this proves
    # the gate read still lands on the statute row, not merely that it could.
    assert {:ok, %{decision_request: question}} = ask(db, "agent:coder", "agent:po", "which way?")

    call = %{
      verb: "attest",
      origin: "agent:agent:coder",
      principal: {:session, "agent:coder"},
      session_key: nil,
      params: %{assignment_id: "a-fake", kind: "completion"}
    }

    statute = %{name: "review", text: "owner denied review"}

    assert {:needs_request, nil} = Escalation.resolve(db, call, statute)

    {:decision_pending, statute_id} =
      Escalation.escalate(db, call, statute, %{question: "allow?", options: nil})

    refute statute_id == question.id
    assert {:needs_request, ^statute_id} = Escalation.resolve(db, call, statute)

    assert Escalation.rule(
             db,
             %{
               origin: "user:flynn",
               principal: {:user, "flynn"},
               params: %{
                 request_id: statute_id,
                 decision: "allow"
               }
             },
             authorized: true
           ).decision == "allow"

    assert {:allow, ^statute_id} = Escalation.resolve(db, call, statute)

    # The agent question is untouched by any of that: still open, still
    # answerless.
    assert get_request(db, question.id).status == "open"
  end

  # Sol xhigh review round 2: the test above proves current_request/4 lands on
  # the statute row when an agent row shares its raiser, but it cannot prove
  # the `kind = 'statute'` predicate is WHY — an agent row's `statuteName` and
  # `actionKey` are pinned NULL by the schema's own CHECK arm, so no row
  # sharing those keys can ever be constructed through the ordinary write
  # path to begin with. That makes the predicate's absence unfalsifiable by
  # any row this test (or any test) could file. The honest proof is the query
  # text itself: THE GATE READ still names `kind = 'statute'`, independent of
  # whatever the schema separately guarantees about NULLs.
  test "the statute gate read's kind predicate is evidenced in its own query text" do
    source = File.read!("lib/tightbeam/escalation.ex")

    assert [_, gate_read_body] =
             Regex.run(~r/defp current_request\(.*?\) do(.*?)\n  end\n/s, source),
           "current_request/4 (THE GATE READ) was not found where this test expects it"

    assert gate_read_body =~ "kind = 'statute'"
  end

  test "--about refuses an assignment the asker cannot legitimately reference, identically to a fake id",
       %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    seed_session(db, "agent:po", "flynn")
    seed_session(db, "agent:outsider", "someone-else")

    # `agent:outsider` neither holds it, opened it, nor is the party a review
    # of it would target.
    private = open_assignment(db, "agent:coder")

    assert {:error, %{code: "not_found", message: invisible}} =
             ask(db, "agent:outsider", "agent:po", "what is this about?",
               assignment_id: private.id
             )

    assert {:error, %{code: "not_found", message: fake}} =
             ask(db, "agent:outsider", "agent:po", "what is this about?",
               assignment_id: "as_nonexistent"
             )

    # An outsider probing ids cannot tell a private assignment from one that
    # does not exist (Sol xhigh review, finding 5) — same code, same message
    # SHAPE (each just echoes back the id the caller itself supplied, never
    # anything the probe didn't already know).
    assert invisible =~ "unknown assignment: #{private.id}"
    assert fake =~ "unknown assignment: as_nonexistent"

    # The holder, naturally, can reference its own assignment.
    assert {:ok, %{decision_request: request}} =
             ask(db, "agent:coder", "agent:po", "what is this about?", assignment_id: private.id)

    assert request.assignment_id == private.id
  end

  test "the asker's exits are its own, and only the asked principal answers", %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    seed_session(db, "agent:po", "flynn")
    seed_session(db, "agent:stranger", "outsider")

    assert {:ok, %{decision_request: request}} = ask(db, "agent:coder", "agent:po", "which way?")

    # Not the asker, not a bystander, not an admin: the principal that was
    # asked. Refused as `not_found` rather than a kind-revealing `not_asked`
    # (Sol xhigh review, finding 4) — an unauthorized caller learns nothing an
    # unauthorized caller probing a fake id would not also learn.
    assert {:error, %{code: "not_found"}} =
             answer(db, {:session, "agent:coder"}, request.id, "myself")

    assert {:error, %{code: "not_found"}} =
             answer(db, {:session, "agent:stranger"}, request.id, "not mine to answer")

    # `rule` and `waive` refuse BY NAME rather than quietly doing something.
    assert {:error, %{code: "invalid", message: ruled}} =
             admin_call(db, "rule", %{request: request.id, decision: "allow"})

    assert ruled =~ "answered, not ruled"

    assert {:error, %{code: "invalid", message: waived}} =
             admin_call(db, "waive", %{request: request.id})

    assert waived =~ "answered, not waived"

    # The answer lands, names its author, and wakes the asker — information, not
    # a verdict: nothing is consumed and no condition fact is filed.
    before_facts = fact_count(db)

    assert {:ok, %{decision_request: answered}} =
             answer(db, {:session, "agent:po"}, request.id, "behind a flag")

    assert answered.status == "answered"
    assert answered.answer == "behind a flag"
    assert answered.answered_by == "session:agent:po"
    assert answered.decision == nil
    assert answered.consumed_at == nil
    assert fact_count(db) == before_facts

    assert [reply] = wakes_for(db, "agent:coder")
    assert reply.prompt =~ "behind a flag"
    assert reply.class == nil, "the substrate does not elect a class on a mind's behalf"

    # Answered once is answered: a second answer is refused, not overwritten.
    assert {:error, %{code: "not_open"}} =
             answer(db, {:session, "agent:po"}, request.id, "changed my mind")
  end

  test "answer and rule refuse a fake id, an agent question, and a non-agent request identically to an unauthorized caller",
       %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    seed_session(db, "agent:po", "flynn")
    seed_session(db, "agent:outsider", "someone-else")

    assert {:ok, %{decision_request: agent_request}} =
             ask(db, "agent:coder", "agent:po", "which way?")

    statute_id = "dr_statute_probe"

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO decision_requests (id, kind, raiserId, raiserSessionKey, ownerUserId, " <>
          "raisedAt, deadlineAt, statuteName, actionKey, question, context, status) VALUES " <>
          "(?1,'statute','session:agent:coder','agent:coder','flynn',1,999999999999," <>
          "'deploy-gate','k1','q','{}','open')",
        [statute_id]
      )

    # `answer`: a caller that was never asked cannot tell a fake id, someone
    # else's question, and a non-agent request apart — ONE refusal for all
    # three (Sol xhigh review, finding 4). Authority is checked before
    # existence or kind is revealed.
    assert {:error, %{code: "not_found"}} =
             answer(db, {:session, "agent:outsider"}, "dr_nonexistent", "guess")

    assert {:error, %{code: "not_found"}} =
             answer(db, {:session, "agent:outsider"}, agent_request.id, "not mine")

    assert {:error, %{code: "not_found"}} =
             answer(db, {:session, "agent:outsider"}, statute_id, "not agent-kind")

    # `rule`: an unauthorized (non-admin) caller gets the SAME refusal whether
    # the id is fake, names an agent question, or names a real, rulable
    # statute request — the agent-kind special case no longer fires ahead of
    # the authority check.
    assert {:error, %{code: "not_owner", message: fake}} =
             verb(db, {:session, "agent:outsider"}, "rule", %{
               request_id: "dr_nonexistent",
               decision: "allow"
             })

    assert {:error, %{code: "not_owner", message: agent_kind}} =
             verb(db, {:session, "agent:outsider"}, "rule", %{
               request_id: agent_request.id,
               decision: "allow"
             })

    assert {:error, %{code: "not_owner", message: statute_kind}} =
             verb(db, {:session, "agent:outsider"}, "rule", %{
               request_id: statute_id,
               decision: "allow"
             })

    assert fake == agent_kind
    assert agent_kind == statute_kind

    # An AUTHORIZED admin still gets the specific, kind-naming refusal for the
    # agent row — that message is only a leak when the caller has no standing
    # to be told anything at all.
    assert {:error, %{code: "invalid", message: authorized_agent}} =
             admin_call(db, "rule", %{request: agent_request.id, decision: "allow"})

    assert authorized_agent =~ "answered, not ruled"
  end

  test "withdraw is the asker's own lawful exit, and nobody else's", %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    seed_session(db, "agent:po", "flynn")

    assert {:ok, %{decision_request: request}} = ask(db, "agent:coder", "agent:po", "which way?")

    # The principal that was ASKED cannot take the question away from the asker.
    assert {:error, %{code: "not_raiser"}} =
             withdraw(db, {:session, "agent:po"}, request.id, "not mine")

    assert {:ok, withdrawn} =
             withdraw(db, {:session, "agent:coder"}, request.id, "worked it out myself")

    assert withdrawn.status == "withdrawn"
    assert withdrawn.withdrawn_reason == "worked it out myself"

    # A withdrawn question can no longer be answered: the exit is real.
    assert {:error, %{code: "not_open"}} =
             answer(db, {:session, "agent:po"}, request.id, "too late")
  end

  test "the schema refuses every shape the agent arm forbids", %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    seed_session(db, "agent:po", "flynn")

    # `deadlineAt` is left out of the column list entirely (and so lands NULL,
    # exactly as the agent arm requires — Sol xhigh review, finding 1) so every
    # row below is forbidden for exactly the one reason its comment names, not
    # also for carrying a deadline the arm refuses.
    base =
      "INSERT INTO decision_requests (id, kind, raiserId, raiserSessionKey, ownerUserId, " <>
        "expecterSessionKey, expecterUserId, raisedAt, question, context, status"

    forbidden = [
      # Adjudication vocabulary, one column at a time.
      {", statuteName) VALUES ('d1','agent','session:agent:coder','agent:coder','flynn'," <>
         "'agent:po','flynn',1,'q','{}','open','deploy-gate')"},
      {", decision) VALUES ('d2','agent','session:agent:coder','agent:coder','flynn'," <>
         "'agent:po','flynn',1,'q','{}','open','allow')"},
      {", parkWakeId) VALUES ('d3','agent','session:agent:coder','agent:coder','flynn'," <>
         "'agent:po','flynn',1,'q','{}','open','w_1')"},
      {", rulingFactId) VALUES ('d4','agent','session:agent:coder','agent:coder','flynn'," <>
         "'agent:po','flynn',1,'q','{}','open',7)"},
      # `ruled` is not one of this arm's three words.
      {") VALUES ('d5','agent','session:agent:coder','agent:coder','flynn'," <>
         "'agent:po','flynn',1,'q','{}','ruled')"},
      # `answered` without an answer, and an answer without an author.
      {") VALUES ('d6','agent','session:agent:coder','agent:coder','flynn'," <>
         "'agent:po','flynn',1,'q','{}','answered')"},
      {", answer) VALUES ('d7','agent','session:agent:coder','agent:coder','flynn'," <>
         "'agent:po','flynn',1,'q','{}','answered','yes')"},
      # `raiserId` must name the asking session, not some other principal.
      {") VALUES ('d8','agent','user:flynn','agent:coder','flynn'," <>
         "'agent:po','flynn',1,'q','{}','open')"}
    ]

    for {tail} <- forbidden do
      assert {:error, %DB.Error{message: message}} = DB.query(db, base <> tail)
      assert message =~ "CHECK constraint"
    end

    # `deadlineAt` is the statute/effort arms' vocabulary (sweep/deadline
    # semantics a question does not carry); the agent arm refuses a stamped
    # one exactly as it refuses a stamped `decision` (Sol xhigh review,
    # finding 1).
    assert {:error, %DB.Error{message: deadlined}} =
             DB.query(
               db,
               "INSERT INTO decision_requests (id, kind, raiserId, raiserSessionKey, " <>
                 "ownerUserId, expecterSessionKey, expecterUserId, raisedAt, deadlineAt, " <>
                 "question, context, status) VALUES ('d10','agent','session:agent:coder'," <>
                 "'agent:coder','flynn','agent:po','flynn',1,999,'q','{}','open')"
             )

    assert deadlined =~ "CHECK constraint"

    # And the fence in the other direction: a STATUTE row cannot borrow the
    # agent arm's columns or its terminal word.
    assert {:error, %DB.Error{message: fenced}} =
             DB.query(
               db,
               "INSERT INTO decision_requests (id, kind, raiserId, ownerUserId, raisedAt, " <>
                 "deadlineAt, statuteName, actionKey, question, context, status, answer, " <>
                 "answeredBy, answeredAt) VALUES ('d9','statute','session:agent:coder','flynn'," <>
                 "1,2,'deploy-gate','k','q','{}','open','yes','session:agent:po',3)"
             )

    assert fenced =~ "CHECK constraint"
  end

  test "a question is visible to its asker, the principal asked, and nobody else", %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    seed_session(db, "agent:po", "flynn")
    seed_session(db, "agent:stranger", "outsider")

    assert {:ok, %{decision_request: request}} = ask(db, "agent:coder", "agent:po", "which way?")

    assert [%{id: id}] = list_requests(db, {:session, "agent:coder"})
    assert id == request.id
    assert [%{id: ^id}] = list_requests(db, {:session, "agent:po"})
    assert [%{id: ^id}] = list_requests(db, {:user, "flynn"})
    assert list_requests(db, {:session, "agent:stranger"}) == []
    assert list_requests(db, {:user, "outsider"}) == []
  end

  test "a sibling session sharing the asker's owner is not one of the three visible principals",
       %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    seed_session(db, "agent:po", "flynn")
    # Owned by flynn too, same as coder — but neither asker, asked, nor the
    # owner acting AS itself.
    seed_session(db, "agent:reviewer", "flynn")
    seed_session(db, "agent:bob-app", "bob")

    assert {:ok, %{decision_request: request}} =
             ask(db, "agent:coder", "agent:bob-app", "which way?")

    # `owner_user_id: "flynn"` is exactly what the gateway resolves for ANY of
    # flynn's sessions (`decision-requests`'s `caller.owner_user_id`) — so this
    # reproduces, at the call site `Escalation.list/get` actually see, what an
    # unrelated sibling session's call looks like (Sol xhigh review, finding
    # 3). Before the fix, the `ownerUserId` branch fired for this session
    # exactly as it does for the owner acting as a user principal.
    reviewer_call = %{
      origin: "agent:reviewer",
      principal: {:session, "agent:reviewer"},
      params: %{}
    }

    assert Escalation.list(db, reviewer_call, "open", owner_user_id: "flynn") == []
    assert Escalation.get(db, reviewer_call, request.id, owner_user_id: "flynn") == nil

    # The owner acting AS itself — a user principal, not merely a session
    # resolving to the same owner — is the one the `ownerUserId` branch exists
    # for, and still sees it.
    owner_call = %{origin: "user:flynn", principal: {:user, "flynn"}, params: %{}}

    assert [%{id: id}] = Escalation.list(db, owner_call, "open", owner_user_id: "flynn")
    assert id == request.id
  end

  ## Seam ④ — `--after` cursors (GitHub #13)

  test "the attests cursor is a (ts, id) keyset that survives a ts collision", %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    assignment = open_assignment(db, "agent:coder")

    # THREE attests sharing ONE millisecond. A `ts`-only cursor either repeats
    # them or drops them; the keyset does neither.
    ids = for n <- 1..3, do: attest_row(db, assignment.id, "at_#{n}", 5_000)
    late = attest_row(db, assignment.id, "at_9", 5_001)

    # A bare unpaged read carries no cursor vocabulary at all (seam ④'s
    # byte-identical promise, Sol xhigh review finding 8) — the collision-
    # spanning order is proved on `page.attests` alone.
    assert {:ok, page} = attests(db, assignment.id, %{})
    assert Enum.map(page.attests, & &1.id) == ids ++ [late]
    assert page == %{attests: page.attests}

    assert {:ok, first} = attests(db, assignment.id, %{limit: 2})
    assert Enum.map(first.attests, & &1.id) == Enum.take(ids, 2)
    assert first.has_more_after
    assert first.next_after == Enum.at(ids, 1)

    assert {:ok, second} = attests(db, assignment.id, %{limit: 2, after: first.next_after})
    assert Enum.map(second.attests, & &1.id) == [Enum.at(ids, 2), late]
    assert second.has_more_after == false

    # Walking to the end returns an empty page, never a repeat.
    assert {:ok, past} = attests(db, assignment.id, %{after: late})
    assert past.attests == []
    assert past.next_after == nil
    assert past.has_more_after == false
  end

  test "an unpaged attests read is byte-identical to what it always returned", %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    assignment = open_assignment(db, "agent:coder")
    for n <- 1..3, do: attest_row(db, assignment.id, "at_#{n}", 5_000 + n)

    assert {:ok, page} = attests(db, assignment.id, %{})

    # NO DEFAULT LIMIT: an audit list that shortens itself silently is the bug
    # this seam must not ship (Law 2).
    assert page.attests == Tightbeam.Assignments.list_attests(db, assignment.id)
    assert length(page.attests) == 3

    # BYTE-IDENTICAL means the whole map, not just the list inside it (Sol
    # xhigh review, finding 8): a pre-existing caller that never passed
    # `--after`/`--limit` must see the exact response it always did, with no
    # `next_after`/`has_more_after` keys added.
    assert page == %{attests: page.attests}
  end

  test "an attests cursor from another assignment is not found, exactly like a fake one",
       %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    mine = open_assignment(db, "agent:coder")
    theirs = open_assignment(db, "agent:coder")
    attest_row(db, theirs.id, "at_elsewhere", 5_000)

    assert {:error, %{code: "cursor_not_found", message: foreign}} =
             attests(db, mine.id, %{after: "at_elsewhere"})

    assert {:error, %{code: "cursor_not_found", message: absent}} =
             attests(db, mine.id, %{after: "at_nonexistent"})

    # Different ids, same SHAPE of answer: the cursor is not a probe for attests
    # on assignments the caller did not name.
    assert foreign =~ "unknown attest cursor"
    assert absent =~ "unknown attest cursor"

    assert {:error, %{code: "invalid"}} = attests(db, mine.id, %{limit: 0})
  end

  test "the toplines cursor pages the flat roster on a stable order key", %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    ids = for n <- 1..4, do: work_item_row(db, "wi_#{n}", 1_000 + n)

    assert {:ok, all} = toplines(db, %{})
    assert Enum.map(all.items, & &1.id) == ids
    refute Map.has_key?(all, :next_after), "an unpaged roster answers exactly as it did"

    assert {:ok, first} = toplines(db, %{limit: 2})
    assert Enum.map(first.items, & &1.id) == Enum.take(ids, 2)
    assert first.next_after == Enum.at(ids, 1)
    assert first.has_more_after

    assert {:ok, second} = toplines(db, %{limit: 2, after: first.next_after})
    assert Enum.map(second.items, & &1.id) == Enum.drop(ids, 2)
    assert second.has_more_after == false

    # The cursor is compared against the ORDER KEY, not against membership: an
    # item filtered out of the page still positions the one after it. The
    # cursor item itself is CLOSED here (Sol xhigh review, finding 7) — every
    # helper-created item defaults to `open`, so the earlier `state: "open"`
    # filter never actually excluded anything and this test would have passed
    # even if cursor resolution regressed from `world.items_by_id` (the full
    # item map) to the filtered/appearing roster, where a closed cursor item
    # cannot be found at all.
    close_work_item_row(db, Enum.at(ids, 0))

    assert {:ok, filtered} = toplines(db, %{after: Enum.at(ids, 0), state: "open"})
    assert Enum.map(filtered.items, & &1.id) == Enum.drop(ids, 1)
  end

  test "an exhausted toplines page hands back a null cursor, never a boolean", %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    ids = for n <- 1..2, do: work_item_row(db, "wi_#{n}", 1_000 + n)

    # Paging exactly to the end: the last item is the cursor, and the next
    # page is empty (Sol xhigh review, finding 6). `selected != [] && ...`
    # evaluates to `false` for an empty page — not the `nil` an ID-or-null
    # cursor contract promises, and not something a client could round-trip
    # back in as `--after`.
    assert {:ok, exhausted} = toplines(db, %{after: List.last(ids)})
    assert exhausted.items == []
    assert exhausted.next_after == nil
    assert exhausted.has_more_after == false
  end

  test "toplines refuses a forest page and an unresolvable cursor by name", %{db: db} do
    seed_session(db, "agent:coder", "flynn")
    work_item_row(db, "wi_1", 1_000)

    assert {:error, %{code: "invalid", message: forest}} = toplines(db, %{tree: true, limit: 2})
    assert forest =~ "--tree returns a forest"

    # An unknown id and an id this caller cannot see are ONE answer — the same
    # rule `--under` follows, and what keeps the cursor from being an oracle.
    assert {:error, %{code: "not_found", message: unknown}} = toplines(db, %{after: "wi_ghost"})
    assert unknown =~ "work item not found"

    assert {:error, %{code: "invalid"}} = toplines(db, %{limit: -1})
    assert {:error, %{code: "invalid"}} = toplines(db, %{after: ""})

    # `topline` bounds its own selection, so a cursor there is refused rather
    # than accepted and ignored.
    assert {:error, %{code: "invalid", message: bounded}} =
             topline(db, %{under: "wi_1", limit: 2})

    assert bounded =~ "selection the caller bounded"
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

  # Every seam ③/④ call goes through `Dispatch.dispatch/3` — the chokepoint the
  # wire router uses — so `Rules.decide` sees these verbs exactly as it sees
  # every other one, and nothing here is proved against a private function the
  # product never reaches.
  defp verb(db, principal, verb, params, target \\ nil) do
    handlers = Tightbeam.Gateway.handlers(%{db: db, wake_tick_ms: 1_000})

    Tightbeam.Dispatch.dispatch(db, handlers, %{
      verb: verb,
      origin: principal_origin(principal),
      principal: principal,
      session_key: target,
      params: params
    })
  end

  defp ask(db, asker, asked, question, opts \\ []) do
    params =
      %{question: question}
      |> then(fn p ->
        case Keyword.get(opts, :assignment_id) do
          nil -> p
          id -> Map.put(p, :assignment_id, id)
        end
      end)

    verb(db, {:session, asker}, "ask", params, asked)
  end

  defp answer(db, principal, request_id, text),
    do: verb(db, principal, "answer", %{request: request_id, answer: text})

  defp withdraw(db, principal, request_id, reason),
    do: verb(db, principal, "withdraw", %{request: request_id, reason: reason})

  defp attests(db, assignment_id, params),
    do: verb(db, {:user, "flynn"}, "attests", Map.put(params, :assignment_id, assignment_id))

  defp toplines(db, params), do: verb(db, {:user, "flynn"}, "toplines", params)
  defp topline(db, params), do: verb(db, {:user, "flynn"}, "topline", params)

  defp list_requests(db, principal) do
    case verb(db, principal, "decision-requests", %{status: "open"}) do
      {:ok, %{decision_requests: requests}} -> requests
      other -> flunk("decision-requests refused: #{inspect(other)}")
    end
  end

  defp admin_call(db, name, params) do
    {:ok, _} =
      DB.query(db, "INSERT OR IGNORE INTO users (userId, isAdmin, createdAt) VALUES ('root',1,1)")

    verb(db, {:user, "root"}, name, params)
  end

  defp get_request(db, id) do
    {:ok, [[status]]} = DB.query(db, "SELECT status FROM decision_requests WHERE id = ?1", [id])
    %{status: status}
  end

  defp fact_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM condition_facts")
    count
  end

  defp wakes_for(db, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT wakeId FROM wakes WHERE sessionKey = ?1 AND state = 'pending' ORDER BY createdAt, wakeId",
        [session_key]
      )

    Enum.map(rows, fn [id] -> Wakes.get(db, id) end)
  end

  defp open_assignment(db, holder_key) do
    Tightbeam.Assignments.__handle__(db, "assign", %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{subject: "work"}
    })
  end

  defp attest_row(db, assignment_id, id, ts) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES (?1, ?2, 'progress', 'agent:coder', ?3)",
        [id, assignment_id, ts]
      )

    id
  end

  defp work_item_row(db, id, created_at) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO work_items (id, title, ownerUserId, state, createdByUser, createdAt,
                                createdContextKnown)
        VALUES (?1, ?1, 'flynn', 'open', 'flynn', ?2, 0)
        """,
        [id, created_at]
      )

    id
  end

  defp close_work_item_row(db, id) do
    {:ok, _} = DB.query(db, "UPDATE work_items SET state = 'closed' WHERE id = ?1", [id])
    id
  end

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

  # Injects an exact `createdAt`, deterministically — `Wakes.schedule` always
  # stamps it from its own clock, so this is the only way to pin a wake's
  # filing time relative to another event without racing the real clock
  # (Sol xhigh review round 2, finding 1).
  defp stamp_created_at!(db, wake, created_at) do
    {:ok, _} =
      DB.query(db, "UPDATE wakes SET createdAt = ?1 WHERE wakeId = ?2", [
        created_at,
        wake.wake_id
      ])

    :ok
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
