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

  alias Tightbeam.{DB, Escalation, Roles, Wakes}

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

    # O7: neither class is governed by a ceiling at all (§7's "immediate"/
    # "bypass" rows name no ceiling), so the datum must say so honestly
    # rather than publish an inert `0` a future policy-extraction pass could
    # mistake for a real fact.
    assert Wakes.delivery_policy("blocker").ceiling_ms == nil
    assert Wakes.delivery_policy("algedonic").ceiling_ms == nil

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

    # O5 follow-up (Sol xhigh review, finding 2): `digest-members` needs a
    # wake id no other sanctioned surface hands an agent — the delivered
    # digest signs itself with its OWN id, right after the rule signature.
    assert Wakes.get(db, digest_id).prompt =~ "wake #{digest_id}"
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

  test "O2: role-addressed classed wakes digest into a role-carrier that carries targetRole forward",
       %{db: db} do
    seed_session(db, "s1", "flynn")
    Roles.create!(db, "role-x", "flynn", "s1")

    a =
      Wakes.schedule(db, %{
        session_key: "s1",
        target_role: "role-x",
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "first for role-x",
        due_at: 0,
        class: "fyi"
      })

    b =
      Wakes.schedule(db, %{
        session_key: "s1",
        target_role: "role-x",
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "second for role-x",
        due_at: 0,
        class: "fyi"
      })

    at = b.created_at + Wakes.delivery_policy("fyi").ceiling_ms

    assert [digest_id] = Wakes.materialize_digests(db, at)
    digest = Wakes.get(db, digest_id)

    assert digest.digest
    assert digest.target_role == "role-x"
    assert Enum.map(Wakes.digest_members(db, digest_id), & &1.wake_id) == [a.wake_id, b.wake_id]
  end

  test "O2: a role rebound inside the ceiling window reaches the new holder, not whoever held it when the members were filed",
       %{db: db} do
    seed_session(db, "s1", "flynn")
    seed_session(db, "s2", "flynn")
    Roles.create!(db, "role-x", "flynn", "s1")

    test_pid = self()
    scheduler = :"coordination_fabric_role_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!({
      Wakes,
      # A minimal stand-in for the composition root's real `deliver` fn
      # (org.ex): resolve `target_role` fresh, at delivery time, exactly the
      # contract the real one honors. This test's job is to prove the
      # CARRIER exposes `target_role` so that contract even applies to it —
      # not to re-prove the contract itself.
      db: db,
      name: scheduler,
      tick_ms: 60_000,
      deliver: fn wake ->
        case wake.target_role do
          role when is_binary(role) ->
            {:ok, session_key, _fallback} = Roles.resolve(db, role)
            send(test_pid, {:delivered, session_key, wake})

          nil ->
            send(test_pid, {:delivered, wake.session_key, wake})
        end
      end
    })

    held =
      Wakes.schedule(db, %{
        session_key: "s1",
        target_role: "role-x",
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "for whoever holds role-x",
        due_at: 0,
        class: "fyi"
      })

    # Backdate past its own ceiling so the scheduler's real-clock sweep finds
    # it due the instant it looks — the point under test is WHO receives it,
    # not when.
    {:ok, _} =
      DB.query(db, "UPDATE wakes SET createdAt=1, dueAt=1 WHERE wakeId=?1", [held.wake_id])

    # The role rebinds to a DIFFERENT session BEFORE materialization ever
    # runs (the scheduler materializes with its own real clock, inside
    # `fire_due` below, never on a timestamp this test hands it).
    :ok = Roles.bind(db, "role-x", "s2")

    assert :ok = Wakes.fire_due(scheduler)

    assert_receive {:delivered, "s2", %{target_role: "role-x", digest: true}}, 1_000
  end

  test "O2: mixed role- and session-addressed traffic for the same principal stays in separate groups",
       %{db: db} do
    seed_session(db, "s1", "flynn")
    Roles.create!(db, "role-y", "flynn", "s1")

    role_member =
      Wakes.schedule(db, %{
        session_key: "s1",
        target_role: "role-y",
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "role traffic",
        due_at: 0,
        class: "fyi"
      })

    session_member =
      Wakes.schedule(db, %{
        session_key: "s1",
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "session traffic",
        due_at: 0,
        class: "fyi"
      })

    at =
      max(role_member.created_at, session_member.created_at) +
        Wakes.delivery_policy("fyi").ceiling_ms

    # A role and the session it happens to be bound to right now are
    # DIFFERENT ADDRESSES — one re-resolves at delivery, the other does not
    # — so they never share a carrier even though both name "s1" today.
    assert digest_ids = Wakes.materialize_digests(db, at)
    assert length(digest_ids) == 2

    digests = Enum.map(digest_ids, &Wakes.get(db, &1))
    role_digest = Enum.find(digests, &(&1.target_role == "role-y"))
    session_digest = Enum.find(digests, &is_nil(&1.target_role))

    assert role_digest
    assert session_digest
    assert session_digest.session_key == "s1"

    assert Enum.map(Wakes.digest_members(db, role_digest.wake_id), & &1.wake_id) == [
             role_member.wake_id
           ]

    assert Enum.map(Wakes.digest_members(db, session_digest.wake_id), & &1.wake_id) == [
             session_member.wake_id
           ]
  end

  test "O4: the carrier inherits the group's linked work when every member agrees on one",
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
        VALUES ('wi_shared', 'shared work', 'owner', 'open', 'owner', ?1)
        """,
        [base]
      )

    a =
      Wakes.schedule(db, %{
        session_key: session,
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "first",
        due_at: base,
        class: "fyi",
        work_item_id: "wi_shared"
      })

    b =
      Wakes.schedule(db, %{
        session_key: session,
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "second",
        due_at: base,
        class: "fyi",
        work_item_id: "wi_shared"
      })

    at = b.created_at + Wakes.delivery_policy("fyi").ceiling_ms
    assert [digest_id] = Wakes.materialize_digests(db, at)

    digest = Wakes.get(db, digest_id)
    assert digest.work_item_id == "wi_shared"
    assert Enum.map(Wakes.digest_members(db, digest_id), & &1.wake_id) == [a.wake_id, b.wake_id]
  end

  test "O4: a genuinely mixed-work group's carrier takes the named digest-carrier exemption and claims no work item",
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
        VALUES ('wi_x', 'x', 'owner', 'open', 'owner', ?1),
               ('wi_y', 'y', 'owner', 'open', 'owner', ?1)
        """,
        [base]
      )

    a =
      Wakes.schedule(db, %{
        session_key: session,
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "first",
        due_at: base,
        class: "fyi",
        work_item_id: "wi_x"
      })

    b =
      Wakes.schedule(db, %{
        session_key: session,
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "second",
        due_at: base,
        class: "fyi",
        work_item_id: "wi_y"
      })

    at = b.created_at + Wakes.delivery_policy("fyi").ceiling_ms

    # No raise, despite neither member's own linked work matching the
    # other's — the named exemption is what lets an honest, genuinely mixed
    # group batch at all.
    assert [digest_id] = Wakes.materialize_digests(db, at)
    digest = Wakes.get(db, digest_id)
    refute digest.work_item_id
    assert Enum.map(Wakes.digest_members(db, digest_id), & &1.wake_id) == [a.wake_id, b.wake_id]
  end

  test "O4: the digest-carrier exemption is scoped to the batcher's own reserved requester id, nobody else's",
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
        VALUES ('wi_a', 'a', 'owner', 'open', 'owner', ?1),
               ('wi_b', 'b', 'owner', 'open', 'owner', ?1)
        """,
        [base]
      )

    member =
      Wakes.schedule(db, %{
        session_key: session,
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "m",
        due_at: base,
        class: "fyi",
        work_item_id: "wi_a"
      })

    carrier =
      Wakes.schedule(db, %{
        session_key: session,
        origin: "process:tightbeam",
        prompt: "digest carrier",
        due_at: base,
        class: "fyi",
        digest: true,
        work_item_id: "wi_b"
      })

    replacement_command = fn requester_id ->
      %{
        wake_id: member.wake_id,
        requester: %{kind: "process", id: requester_id},
        reason_kind: "superseded",
        causal_source: %{kind: "wake", id: carrier.wake_id},
        outcome: %{kind: "replacement", replacement_wake_id: carrier.wake_id}
      }
    end

    # A non-batcher requester otherwise authorized for superseded/wake/
    # replacement (effort-checkin) does NOT get the batcher's exemption — the
    # work mismatch is refused exactly as it would be for any ordinary
    # replacement.
    assert {:ok, false} =
             DB.transaction(db, fn txn ->
               Wakes.cancel_in_txn(txn, replacement_command.("tightbeam:effort-checkin"))
             end)

    assert Wakes.get(db, member.wake_id).state == "pending"

    # The SAME shape, from the batcher's own reserved id, IS exempt.
    assert {:ok, true} =
             DB.transaction(db, fn txn ->
               Wakes.cancel_in_txn(txn, replacement_command.("tightbeam:batcher"))
             end)

    assert Wakes.get(db, member.wake_id).state == "canceled"
  end

  test "O4: a forced member-cancellation failure rolls back its own group and does not crash the sweep",
       %{db: db} do
    session = "agent:po"
    healthy_session = "agent:po2"
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

    # A second, entirely healthy group — a DIFFERENT session, so a different
    # (session, class) group under the same materialization sweep.
    healthy_member = schedule(db, session: healthy_session, class: "fyi", prompt: "unrelated")

    # `broken_member`'s own linked work is not open, so the batcher's typed
    # cancellation for it will be refused by `validate_outcome/4` — the ONE
    # failure the all-or-nothing rule exists to catch.
    at = broken_member.created_at + Wakes.delivery_policy("fyi").ceiling_ms

    # PER-GROUP ISOLATION (O4): the poisoned group's raise is caught before
    # it reaches the caller — decimating one group must not decimate the
    # sweep. The healthy group still materializes in the SAME call.
    assert [digest_id] = Wakes.materialize_digests(db, at)
    assert Wakes.get(db, digest_id).session_key == healthy_session
    assert Enum.map(Wakes.digest_members(db, digest_id), & &1.wake_id) == [healthy_member.wake_id]

    # THE POISONED GROUP'S OWN TRANSACTION STILL ROLLS BACK IN FULL: neither
    # of its members was touched and no carrier exists for it.
    assert Wakes.get(db, ok_member.wake_id).state == "pending"
    assert Wakes.get(db, broken_member.wake_id).state == "pending"

    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM wake_cancellations")
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM wakes WHERE digest = 1")

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM lifecycle_events WHERE kind = 'wake_digest_materialized'"
             )

    # THE NAMED ROW IS THE AGENT-REACHABLE REPAIR SURFACE (philosophy gate
    # Q3): the poisoned group is visible and identifiable, not merely absent.
    assert {:ok, [[detail]]} =
             DB.query(
               db,
               "SELECT detail FROM lifecycle_events WHERE kind = 'wake_digest_materialization_failed'"
             )

    assert detail =~ "incompatible_delivery_policy_v1"
    assert detail =~ "#{session}/fyi"

    # SIGNED LIKE THE SUCCESS PATH (Sol xhigh review, finding 3; §8
    # legibility): the rule name and revision that was attempting this
    # materialization travels on the failure row too, not just on
    # `wake_digest_materialized`.
    assert detail =~ "rule=#{Wakes.digest_rule()}"

    # THE POISONED GROUP RETRIES NEXT TICK (still visible, still bounded) —
    # calling materialize_digests again reproduces the exact same failure
    # rather than silently giving up on it.
    assert Wakes.materialize_digests(db, at) == []

    assert {:ok, [[2]]} =
             DB.query(
               db,
               "SELECT count(*) FROM lifecycle_events WHERE kind = 'wake_digest_materialization_failed'"
             )

    # The healthy group's own carrier is untouched by the retry — still
    # exactly the one materialization from before.
    assert {:ok, [[1]]} =
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

  test "O5: the digest-members verb reads for the carrier's owner, refuses a non-carrier, and is not an oracle",
       %{db: db} do
    seed_session(db, "agent:po", "owner")
    seed_session(db, "agent:stranger", "outsider")

    member = schedule(db, session: "agent:po", class: "fyi", prompt: "the build finished")
    assert [materialized_id] = Wakes.materialize_digests(db, member.due_at)

    # THE SANCTIONED DISCOVERY PATH (Sol xhigh review, finding 2): an agent
    # reading the delivered digest never sees `materialize_digests/2`'s
    # return value — it reads the message the batcher signed, which now
    # names its own wake id in the signature line. Parse it out exactly as a
    # recipient would, and drive `digest-members` from THAT id, not the
    # internal one, to prove the whole discovery path an agent actually has.
    delivered_prompt = Wakes.get(db, materialized_id).prompt
    [digest_id] = Regex.run(~r/wake (w_[0-9a-f-]+)/, delivered_prompt, capture: :all_but_first)
    assert digest_id == materialized_id

    assert {:ok, %{digest_members: members}} =
             verb(db, {:user, "owner"}, "digest-members", %{wake_id: digest_id})

    assert Enum.map(members, & &1.wake_id) == [member.wake_id]

    # A caller who cannot see the carrier's session and a wake id naming
    # nothing at all give the SAME answer — otherwise the read is an
    # existence oracle over ordinary wakes.
    assert {:error, %{code: "not_found", message: unreadable}} =
             verb(db, {:user, "outsider"}, "digest-members", %{wake_id: digest_id})

    assert {:error, %{code: "not_found", message: absent}} =
             verb(db, {:user, "outsider"}, "digest-members", %{wake_id: "w_does_not_exist"})

    assert unreadable == absent

    # A wake id that resolves but is not itself a digest CARRIER (an
    # ordinary, non-batched wake) refuses identically — this is a status
    # question about the C4 audit, not a generic wake lookup.
    ordinary = schedule(db, session: "agent:po", prompt: "not a digest")

    assert {:error, %{code: "not_found"}} =
             verb(db, {:user, "owner"}, "digest-members", %{wake_id: ordinary.wake_id})

    assert {:error, %{code: "invalid"}} = verb(db, {:user, "owner"}, "digest-members", %{})
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

    # HALF TWO, structural (Sol xhigh review round 3). Round 2 centralized
    # every decision_requests reader into escalation.ex behind a hand-DECLARED
    # name-to-kind map. Sol found four bypasses a declared (not derived) map
    # cannot close: a new reader added INSIDE escalation.ex with no map entry;
    # a helper removed with its entry left stale; a helper's SQL widened past
    # its declared scope with no textual signal; and a new external caller of
    # an "any"-scoped helper, which has zero literal for any scan to catch.
    # This closes all four by making the map a CHECKED CLAIM:
    #
    #   (a) no `decision_requests` literal exists anywhere in `lib/` outside
    #       `escalation.ex` (unchanged from round 2: ZERO allowlist).
    #
    #   (a2) `escalation.ex`'s own inventory is DERIVED from its source — every
    #        function's true `end`-bounded body (comments stripped, so a
    #        neighbor's trailing `@doc` cannot bleed in and a mention inside a
    #        comment cannot fake one in) is checked for the literal, closed
    #        TRANSITIVELY over local calls so a delegate with no SQL of its
    #        own (`answer/2` calling `get_raw/2`) still counts — and asserted
    #        equal to the pinned map's keys.
    #
    #   (b) every entry scoped to one kind (or a named pair) must contain ITS
    #       OWN predicate in its own text — catches widening even when the
    #       reader itself never moved.
    #
    #   (c) every "any"-scoped, non-verb helper's external call sites are
    #       pinned by {file, enclosing function} — the one thing no literal
    #       scan can see, because a new caller adds no new SQL text anywhere.
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&(&1 == "lib/tightbeam/escalation.ex"))
      |> Enum.flat_map(fn file ->
        file
        |> sql_literals()
        |> Enum.filter(&(&1 =~ ~r/\bdecision_requests\b/i))
        |> Enum.map(&{file, &1})
      end)

    assert offenders == [],
           "a decision_requests literal outside escalation.ex: #{inspect(offenders)}"

    pinned_kinds = %{
      escalate: "statute",
      open_episodes: "statute",
      statute_park_candidate_in_txn: "statute",
      grant_waiver: "statute",
      current_request: "statute",
      file_agent_request: "agent",
      answer_open: "agent",
      effort_open_by_deadline_wake_in_txn: "effort",
      effort_insert_in_txn: "effort",
      effort_id_by_generation_in_txn: "effort",
      effort_supersede_open_in_txn: "effort",
      effort_update_generation_in_txn: "effort",
      open_counts_by_assignment: "statute,effort",
      consume: "any",
      withdraw_for_retired: "any",
      withdraw_episodes: "any",
      recover_retired: "any",
      list: "any",
      get: "any",
      effort_rule_in_txn: "any",
      claim_park_wake_in_txn: "any",
      decision_trace_rows: "any",
      wake_link_fragment: "any",
      raw_exists_in_txn?: "any",
      statute_name_for_ruling: "any",
      rule_open: "any",
      withdraw_open: "any",
      get_raw: "any",
      request_in_txn: "any",
      answer: "agent",
      ask: "agent",
      raw_by_id: "any",
      raw_by_id_in_txn!: "any",
      resolve: "statute",
      rule: "any",
      rule_statute: "any",
      summon: "statute",
      waive: "any",
      withdraw: "any"
    }

    assert Escalation.helper_kind_inventory() == pinned_kinds,
           "escalation.ex's decision_requests inventory changed; review the new/changed " <>
             "entry's kind scope and update this pin"

    escalation_slices = function_slices("lib/tightbeam/escalation.ex")

    pinned_arities = %{
      escalate: 4,
      open_episodes: 2,
      statute_park_candidate_in_txn: 2,
      grant_waiver: 6,
      current_request: 4,
      file_agent_request: 2,
      answer_open: 4,
      effort_open_by_deadline_wake_in_txn: 2,
      effort_insert_in_txn: 2,
      effort_id_by_generation_in_txn: 3,
      effort_supersede_open_in_txn: 2,
      effort_update_generation_in_txn: 4,
      open_counts_by_assignment: 1,
      consume: 2,
      withdraw_for_retired: 2,
      withdraw_episodes: 3,
      recover_retired: 1,
      list: 4,
      get: 4,
      effort_rule_in_txn: 5,
      claim_park_wake_in_txn: 3,
      decision_trace_rows: 2,
      wake_link_fragment: 1,
      raw_exists_in_txn?: 2,
      statute_name_for_ruling: 2,
      rule_open: 6,
      withdraw_open: 4,
      get_raw: 2,
      request_in_txn: 2,
      answer: 2,
      ask: 2,
      raw_by_id: 2,
      raw_by_id_in_txn!: 2,
      resolve: 3,
      rule: 3,
      rule_statute: 4,
      summon: 4,
      waive: 3,
      withdraw: 2
    }

    # (a2), hardened (Sol round 4, findings 2a/2b). A bare atom collapses
    # arity, so a NEW overload of an already-pinned name (`escalate/5` beside
    # the real `escalate/4`) is invisible to a name-only inventory — the new
    # arity silently rides in on the old name's already-accepted entry. The
    # closure is now computed AT THE AST LEVEL, keyed `{name, arity}`, and its
    # literal-touch test is stronger than a `Macro.to_string` substring scan
    # too: it resolves `<>` concatenation chains and this module's OWN
    # `@attr` references to their literal values (Sol round 4, finding 2b —
    # an assembled `"decision_" <> "requests"` or an attribute-derived
    # `@table "decision_requests"` used via `#{@table}` has no contiguous
    # "decision_requests" text for a `Macro.to_string` scan to find, but is
    # still a literal to the AST). `ensure_schema/1` is excluded by name: it
    # emits this table's own DDL (`DB.execute(db, @ddl)`) for ALL THREE kinds
    # at once, by construction — a schema definition, not a scoped reader, so
    # it is not part of "every reader lives in escalation.ex" in the sense
    # this inventory means.
    {direct_refs, derived_refs} = ast_reader_closure("lib/tightbeam/escalation.ex")

    direct_names = for {name, _arity} <- direct_refs, into: MapSet.new(), do: name
    derived_names = for {name, _arity} <- derived_refs, into: MapSet.new(), do: name

    assert derived_names == MapSet.new(Map.keys(pinned_kinds)),
           "derived escalation.ex functions touching decision_requests do not match the pin: " <>
             "new #{inspect(MapSet.difference(derived_names, MapSet.new(Map.keys(pinned_kinds))))}, " <>
             "missing #{inspect(MapSet.difference(MapSet.new(Map.keys(pinned_kinds)), derived_names))}"

    pinned_refs = for {name, arity} <- pinned_arities, into: MapSet.new(), do: {name, arity}

    assert derived_refs == pinned_refs,
           "escalation.ex's decision_requests-reading functions changed ARITY, not just name " <>
             "— a new overload of an already-pinned name is invisible to a name-only pin: new " <>
             "#{inspect(MapSet.difference(derived_refs, pinned_refs))}, missing " <>
             "#{inspect(MapSet.difference(pinned_refs, derived_refs))}"

    # (b): every DIRECT entry scoped to a real kind (not "any") must prove an
    # EXCLUSIVE predicate in its own SQL text, not merely CONTAIN the declared
    # kind as a substring (Sol round 4, finding 1): a "statute"-scoped helper
    # widened to `kind IN ('statute','agent')` still contains the literal
    # 'statute' and passed the old substring check. `kind_predicate_shape/3`
    # parses the helper's own SQL for its "kind" constraint and accepts only
    # two shapes — `kind = '<declared>'` for a single declared kind, or an
    # explicit `kind IN (...)` list EXACTLY equal to a declared pair — and
    # fails closed, by name, on anything else (an extra IN member, an OR, a
    # negation, or no recognizable constraint at all). A delegate (in
    # `derived` but not `direct`) has no text of its own to check — its
    # correctness rides on the direct entry it calls, which this loop already
    # covers.
    for {ref, kind} <- pinned_kinds, kind != "any", ref in direct_names do
      text = text_for_name(escalation_slices, ref)
      assert text != "", "#{ref} is pinned #{inspect(kind)} but no matching function was found"

      case kind_predicate_shape(ref, text, kind) do
        :ok -> :ok
        {:error, message} -> flunk(message)
      end
    end

    # (b2): a query built by interpolating a NON-LITERAL expression into the
    # query text cannot be proven, by this scan, to be free of an assembled
    # or hidden table reference — `#{@request_columns}` resolves (it is a
    # literal attribute), but `#{where}`/`#{status_clause}` in `list/4` and
    # `get/4`, and `#{clause}` in `decision_trace_rows/2`, do not. Rather than
    # silently trusting them, each is a REVIEWED, PINNED exception
    # (visibility-filter and IN-list placeholder text, never a table name);
    # any function joining this set is new dynamic SQL that has not been
    # reviewed and fails closed, by name, until it is.
    pinned_dynamic_queries = MapSet.new([{:list, 4}, {:get, 4}, {:decision_trace_rows, 2}])

    found_dynamic_queries = dynamic_query_refs("lib/tightbeam/escalation.ex")

    assert found_dynamic_queries == pinned_dynamic_queries,
           "a decision_requests query's text is no longer provably literal (it interpolates " <>
             "something this scan cannot resolve) in a function not already reviewed for it — a " <>
             "non-literal fragment could be hiding an assembled table name: new " <>
             "#{inspect(MapSet.difference(found_dynamic_queries, pinned_dynamic_queries))}, stale " <>
             "#{inspect(MapSet.difference(pinned_dynamic_queries, found_dynamic_queries))}"

    # (c): every "any"-scoped, non-verb helper's external callers are pinned.
    # The verb surface (`ask`/`answer`/`rule`/`waive`/`withdraw`/`resolve`/
    # `escalate`/`summon`/`revoke_waiver`) is reached exclusively through
    # Dispatch/Gateway's own routing tables, proved elsewhere (router
    # allowlist, dispatch conformance) — not a "helper" another module reaches
    # on its own initiative, so it is deliberately excluded here.
    pinned_callers = %{
      consume: [{"lib/tightbeam/dispatch.ex", "dispatch_through_rail/7"}],
      withdraw_for_retired: [{"lib/tightbeam/supervision.ex", "handle_cast/2"}],
      withdraw_episodes: [{"lib/tightbeam/rail_episodes.ex", "handle_call/3"}],
      recover_retired: [{"lib/tightbeam/boot.ex", "start_link/1"}],
      list: [{"lib/tightbeam/gateway.ex", "handlers/1"}],
      get: [{"lib/tightbeam/gateway.ex", "handlers/1"}],
      effort_rule_in_txn: [{"lib/tightbeam/effort_checkin.ex", "rule_in_txn/7"}],
      claim_park_wake_in_txn: [{"lib/tightbeam/supervision.ex", "park_escalation/3"}],
      decision_trace_rows: [{"lib/tightbeam/job_trace.ex", "decision_entries/2"}],
      wake_link_fragment: [{"lib/tightbeam/job_trace.ex", "wake_entries/3"}],
      raw_exists_in_txn?: [
        {"lib/tightbeam/wakes.ex", "validate_source/4"},
        {"lib/tightbeam/wakes.ex", "validate_disposition/3"}
      ],
      statute_name_for_ruling: [{"lib/tightbeam/dispatch.ex", "ruling_statute/2"}],
      raw_by_id: [{"lib/tightbeam/effort_checkin.ex", "request_row/2"}],
      raw_by_id_in_txn!: [{"lib/tightbeam/effort_checkin.ex", "request_for_id/2"}]
    }

    verb_surface =
      ~w(ask answer rule waive withdraw resolve escalate summon revoke_waiver)a

    any_kind_public =
      for {ref, "any"} <- pinned_kinds,
          ref not in verb_surface,
          public_escalation_function?(ref),
          into: MapSet.new(),
          do: ref

    assert any_kind_public == MapSet.new(Map.keys(pinned_callers)),
           "a public \"any\"-scoped, non-verb helper has no pinned-caller entry (or a pinned " <>
             "entry names a helper that no longer exists/is no longer \"any\"/public): " <>
             "new #{inspect(MapSet.difference(any_kind_public, MapSet.new(Map.keys(pinned_callers))))}, " <>
             "stale #{inspect(MapSet.difference(MapSet.new(Map.keys(pinned_callers)), any_kind_public))}"

    # AST-level caller resolution (Sol round 4, finding 3): a textual
    # `Escalation.<ref>(` scan is blind to a capture (`&Escalation.f/2`), an
    # `apply/3` target, or a caller that aliased the module under another
    # name — none of them add the literal substring the old scan looked for.
    # Computed once, for every lib/ file, rather than per-ref: cheaper, and
    # the same AST walk answers every ref's question at once.
    callers_by_ref =
      escalation_callers_by_file()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {ref, sites} -> {ref, Enum.uniq(sites)} end)

    for {ref, expected} <- pinned_callers do
      found = Map.get(callers_by_ref, ref, [])

      assert Enum.sort(found) == Enum.sort(expected),
             "#{ref}'s external callers changed: found #{inspect(found)}, pinned #{inspect(expected)}"
    end

    # Imports evade the same scan a different way: `import Escalation` turns
    # every bare `consume(...)` inside the importing file into a call this
    # walk never sees, because it never mentions `Escalation` at all. Cheapest
    # closure (Sol round 4, finding 3's `import` clause): assert the escape
    # hatch is not in use, so there is nothing to widen the caller walk for —
    # until the day this fails and it must.
    importers =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&(&1 == "lib/tightbeam/escalation.ex"))
      |> Enum.filter(&imports_escalation?/1)

    assert importers == [],
           "lib/ file(s) import Escalation — bare calls there are invisible to the caller walk " <>
             "above and must be handled explicitly: #{inspect(importers)}"

    # `apply/3` with a non-literal module argument is the one shape this scan
    # cannot resolve at all: the target could be anything at runtime,
    # Escalation included. `command_edge.ex`'s `perform_job/2` is a reviewed,
    # PINNED exception — a generic worker MFA from `validate_worker!/1`,
    # never Escalation — any other site joining this set is new and
    # unreviewed.
    pinned_dynamic_applies =
      MapSet.new([{"lib/tightbeam/command_edge.ex", "perform_job/2"}])

    found_dynamic_applies = dynamic_apply_sites() |> MapSet.new()

    assert found_dynamic_applies == pinned_dynamic_applies,
           "a lib/ function calls 3-arity apply/3 with a non-literal module argument outside " <>
             "the reviewed allowlist — this scan cannot prove it never targets Escalation: new " <>
             "#{inspect(MapSet.difference(found_dynamic_applies, pinned_dynamic_applies))}, stale " <>
             "#{inspect(MapSet.difference(pinned_dynamic_applies, found_dynamic_applies))}"

    # The MIRROR shape (Sol round 5, finding 2a): a LITERAL Escalation module
    # with a non-literal FUNCTION argument. `escalation_refs_called/2` above
    # requires a literal atom to attribute the call to a `ref`, and the
    # dynamic-apply check just above only flags a non-literal MODULE — so
    # this shape is invisible to both. It cannot be scoped to any specific
    # ref at all, so there is no reviewable pin for it: any occurrence fails
    # closed outright.
    escalation_apply_dynamic_function_hits = escalation_apply_dynamic_function_sites()

    assert escalation_apply_dynamic_function_hits == [],
           "a lib/ function calls apply/3 with a LITERAL Escalation module but a NON-literal " <>
             "function argument — this cannot be scoped to any specific ref and must be " <>
             "reviewed: #{inspect(escalation_apply_dynamic_function_hits)}"
  end

  # Every double-quoted or triple-quoted string literal in a file's raw
  # source, scanned as TEXT rather than parsed AST (Sol xhigh review, finding
  # 2) — a query built with `#{@request_columns}` interpolation is not a plain
  # `is_binary` AST node and an AST scan would silently skip it.
  defp sql_literals(file) do
    Regex.scan(~r/"""(?:(?!""").)*"""|"[^"\n]*"/s, File.read!(file))
    |> List.flatten()
  end

  # Every top-level `def`/`defp` in `file`, keyed `"name/arity"`, reconstructed
  # via `Macro.to_string/1` on its OWN AST node — never text sliced "from this
  # line to the next `def`", which bled a neighbor's `@doc`/comment in (Sol
  # xhigh review round 3 caught this exact bug in an earlier draft: a
  # multi-line function head with the body's `do:` on a later line defeated a
  # same-line one-liner check, and the resulting "search for the next `end`
  # at this indentation" fell through to end-of-file, silently swallowing
  # every function after it). The AST already excludes comments by
  # construction — nothing to strip, nothing left to bleed — and
  # `Macro.to_string/1` faithfully reconstructs `#{}` interpolation as text
  # (verified: a heredoc built with `#{@request_columns}` round-trips with
  # `decision_requests` still readable in the output), so this is accurate
  # for BOTH concerns the old text-slicing approach traded against each
  # other. Multiple clauses of the same name/arity are concatenated.
  defp function_slices(file) do
    source = File.read!(file)
    {:ok, ast} = Code.string_to_quoted(source, columns: true)
    {:defmodule, _, [_, [do: block]]} = ast

    top_level =
      case block do
        {:__block__, _, items} -> items
        single -> [single]
      end

    top_level
    |> Enum.filter(fn
      {kind, _, _} -> kind in [:def, :defp]
      _ -> false
    end)
    |> Enum.map(fn {_kind, _meta, args} = node ->
      head = hd(args)

      ref =
        case head do
          {:when, _, [inner | _]} -> inner
          other -> other
        end

      name_arity =
        case ref do
          {name, _, cargs} when is_list(cargs) -> "#{name}/#{length(cargs)}"
          {name, _, nil} -> "#{name}/0"
        end

      {name_arity, Macro.to_string(node)}
    end)
    |> Enum.reduce(%{}, fn {ref, text}, acc ->
      Map.update(acc, ref, text, &(&1 <> "\n" <> text))
    end)
  end

  # `slices` is keyed `"name/arity"`; the pinned map keys are bare atom names
  # (arity-agnostic, since no name in this inventory is overloaded across
  # arities). Concatenates every matching arity's text, so an overload would
  # fail safe (checked against the union) rather than silently picking one.
  defp text_for_name(slices, name) do
    slices
    |> Enum.filter(fn {ref, _text} -> String.starts_with?(ref, "#{name}/") end)
    |> Enum.map_join("\n", fn {_ref, text} -> text end)
  end

  defp public_escalation_function?(ref) do
    source = File.read!("lib/tightbeam/escalation.ex")
    source =~ ~r/^  def #{Regex.escape(Atom.to_string(ref))}[\(,]/m
  end

  ## AST-level audit infrastructure (Sol round 4)
  #
  # Everything below reads Elixir's own parse tree instead of `Macro.to_string`
  # text, closing three evasions a text/substring scan cannot see by
  # construction: a "kind" constraint widened past its declared scope but
  # still containing the declared literal (hole 1); a table name assembled
  # from concatenation parts or hidden behind this module's own `@attr`
  # (hole 2); and a caller reaching `Escalation` through a capture, an
  # `apply/3` target, or an aliased name rather than a literal `Mod.fun(`
  # call (hole 3).

  # The do-block's top-level forms for a single-`defmodule`-per-file source —
  # the same assumption `function_slices/1` above already makes.
  defp module_do_block(ast) do
    {:defmodule, _, [_, [do: block]]} = ast

    case block do
      {:__block__, _, items} -> items
      single -> [single]
    end
  end

  # Every top-level `def`/`defp`'s OWN raw AST node(s), keyed `{name, arity}`
  # — never collapsed to a bare atom, so a new overload of an already-known
  # name is its own distinct key rather than silently joining the existing
  # one's entry. Multiple clauses of the same `{name, arity}` are collected
  # into a list.
  defp function_defs_from_ast(ast) do
    ast
    |> module_do_block()
    |> Enum.filter(fn
      {kind, _, _} -> kind in [:def, :defp]
      _ -> false
    end)
    |> Enum.map(fn {_kind, _meta, args} = node ->
      head = hd(args)

      ref =
        case head do
          {:when, _, [inner | _]} -> inner
          other -> other
        end

      name_arity =
        case ref do
          {name, _, cargs} when is_list(cargs) -> {name, length(cargs)}
          {name, _, nil} -> {name, 0}
        end

      {name_arity, node}
    end)
    |> Enum.reduce(%{}, fn {ref, node}, acc -> Map.update(acc, ref, [node], &[node | &1]) end)
  end

  defp function_defs(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted(columns: true)
    function_defs_from_ast(ast)
  end

  # This module's own `@attr "literal"` definitions, resolved to their
  # literal string value (concatenation- and nested-attribute-aware via
  # `literal_value/2`) — the map `literal_fragments/2` consults so an
  # `@table "decision_requests"` used later as `#{@table}` is still found,
  # even though the reference itself carries no such text.
  defp module_attrs_from_ast(ast) do
    ast
    |> module_do_block()
    |> Enum.reduce(%{}, fn
      {:@, _, [{name, _, [value]}]}, acc when is_atom(name) ->
        case literal_value(value, acc) do
          {:ok, v} -> Map.put(acc, name, v)
          :unknown -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp module_attrs(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted(columns: true)
    module_attrs_from_ast(ast)
  end

  # Fully resolves an AST node to a literal string, or `:unknown` the moment
  # any part of it is not itself a literal (a variable, a function call, an
  # unresolved attribute). Handles plain literals, `<>` concatenation chains,
  # this module's own `@attr` reads, the compiler's `Kernel.to_string/1` wrap
  # around every `#{}` segment, and interpolated (`<<>>`) strings/sigils.
  defp literal_value(node, attrs) do
    case node do
      s when is_binary(s) ->
        {:ok, s}

      {:<>, _, [a, b]} ->
        with {:ok, sa} <- literal_value(a, attrs),
             {:ok, sb} <- literal_value(b, attrs) do
          {:ok, sa <> sb}
        else
          _ -> :unknown
        end

      {:@, _, [{name, _, nil}]} ->
        case Map.fetch(attrs, name) do
          {:ok, v} -> {:ok, v}
          :error -> :unknown
        end

      {{:., _, [Kernel, :to_string]}, _, [inner]} ->
        literal_value(inner, attrs)

      {:<<>>, _, _} = interp ->
        interpolated_value(interp, attrs)

      {:__block__, _, [single]} ->
        literal_value(single, attrs)

      _ ->
        :unknown
    end
  end

  defp interpolated_value({:<<>>, _, parts}, attrs) do
    Enum.reduce_while(parts, {:ok, ""}, fn
      part, {:ok, acc} when is_binary(part) ->
        {:cont, {:ok, acc <> part}}

      {:"::", _, [expr, _]}, {:ok, acc} ->
        case literal_value(expr, attrs) do
          {:ok, v} -> {:cont, {:ok, acc <> v}}
          :unknown -> {:halt, :unknown}
        end

      other, {:ok, acc} ->
        case literal_value(other, attrs) do
          {:ok, v} -> {:cont, {:ok, acc <> v}}
          :unknown -> {:halt, :unknown}
        end
    end)
  end

  # Every literal STRING FRAGMENT reachable anywhere in `node` — plain
  # literals, `<>` operands, an interpolated string's own static segments,
  # and resolved `@attr` reads — collected INDIVIDUALLY rather than requiring
  # the whole surrounding expression to resolve. That is what catches a table
  # name split across a static prefix/suffix around a dynamic middle, or
  # hidden entirely behind one resolvable attribute, without needing the rest
  # of the query (a WHERE fragment built at runtime, say) to be literal too.
  defp literal_fragments(node, attrs) do
    {_, frags} =
      Macro.prewalk(node, [], fn
        s, acc when is_binary(s) ->
          {s, [s | acc]}

        {:@, _, [{name, _, nil}]} = n, acc ->
          case Map.fetch(attrs, name) do
            {:ok, v} -> {n, [v | acc]}
            :error -> {n, acc}
          end

        {:<>, _, _} = n, acc ->
          case literal_value(n, attrs) do
            {:ok, v} -> {n, [v | acc]}
            :unknown -> {n, acc}
          end

        other, acc ->
          {other, acc}
      end)

    frags
  end

  # Bare (unqualified) local calls AND local captures whose `{name, arity}`
  # matches a function actually defined in this same set of slices — the
  # transitive-closure call graph's edge list, at the AST level instead of a
  # `(?<!\.)\bname\(` text regex.
  defp local_call_refs(node, known_refs) do
    {_, calls} =
      Macro.prewalk(node, [], fn
        {name, _, args} = n, acc when is_atom(name) and is_list(args) ->
          ref = {name, length(args)}
          if MapSet.member?(known_refs, ref), do: {n, [ref | acc]}, else: {n, acc}

        {:&, _, [{:/, _, [{name, _, ctx}, arity]}]} = n, acc
        when is_atom(name) and not is_list(ctx) ->
          ref = {name, arity}
          if MapSet.member?(known_refs, ref), do: {n, [ref | acc]}, else: {n, acc}

        other, acc ->
          {other, acc}
      end)

    calls
  end

  # (a2)'s DIRECT set — every `{name, arity}` whose OWN literal fragments
  # contain "decision_requests" (case-INSENSITIVE, Sol round 6, finding 1:
  # SQL identifiers are case-insensitive, so `DECISION_REQUESTS` names the
  # exact same table and must not evade a scan that only ever looked for the
  # lowercase spelling) — and its transitive closure over local calls, both
  # `{name, arity}`-keyed. `ensure_schema/1` is excluded: it issues this
  # table's own DDL for all three kinds by construction, which is not
  # "reading" in the sense this inventory means.
  defp ast_reader_closure(file) do
    attrs = module_attrs(file)
    defs = function_defs(file)
    known_refs = defs |> Map.keys() |> MapSet.new()

    direct =
      for {ref, nodes} <- defs,
          ref != {:ensure_schema, 1},
          frags = Enum.flat_map(nodes, &literal_fragments(&1, attrs)),
          Enum.any?(frags, &(&1 =~ ~r/\bdecision_requests\b/i)),
          into: MapSet.new(),
          do: ref

    call_graph =
      for {ref, nodes} <- defs, into: %{} do
        calls = nodes |> Enum.flat_map(&local_call_refs(&1, known_refs)) |> MapSet.new()
        {ref, calls}
      end

    closure =
      Enum.reduce_while(1..100, direct, fn _, acc ->
        next =
          Enum.reduce(call_graph, acc, fn {ref, calls}, acc2 ->
            if Enum.any?(calls, &MapSet.member?(acc2, &1)),
              do: MapSet.put(acc2, ref),
              else: acc2
          end)

        if MapSet.equal?(next, acc), do: {:halt, acc}, else: {:cont, next}
      end)

    {direct, closure}
  end

  # A `Txn.q`/`DB.query` call's own query-text argument, resolved the same
  # way `literal_fragments/2` resolves table-name literals — but here the
  # WHOLE expression must resolve, not just some fragment of it: a query is
  # either provably literal end to end, or it is dynamic SQL this scan cannot
  # vouch for at all.
  defp dynamic_query_refs(file) do
    attrs = module_attrs(file)
    defs = function_defs(file)

    for {ref, nodes} <- defs,
        Enum.any?(nodes, &has_dynamic_query?(&1, attrs)),
        into: MapSet.new(),
        do: ref
  end

  defp has_dynamic_query?(node, attrs) do
    {_, hit?} =
      Macro.prewalk(node, false, fn
        {{:., _, [_mod, fun]}, _, args} = n, acc
        when fun in [:q, :query] and length(args) >= 2 ->
          query_arg = Enum.at(args, 1)

          resolved =
            case query_arg do
              bin when is_binary(bin) -> {:ok, bin}
              other -> literal_value(other, attrs)
            end

          {n, acc or match?(:unknown, resolved)}

        n, acc ->
          {n, acc}
      end)

    hit?
  end

  # This file's own `alias` declarations (plain, `as:`, and the `Mod.{A, B}`
  # multi-alias form), mapping the SHORT name a call site can use back to the
  # module's full path — resolved once per file and threaded through every
  # call/capture/apply check below.
  defp module_alias_map(ast) do
    {_, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), parts)}

        {:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          case Keyword.get(opts, :as) do
            {:__aliases__, _, as_parts} -> {node, Map.put(acc, List.last(as_parts), parts)}
            _ -> {node, acc}
          end

        {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, entries}]} = node, acc ->
          acc2 =
            Enum.reduce(entries, acc, fn
              {:__aliases__, _, suffix}, a -> Map.put(a, List.last(suffix), prefix ++ suffix)
              _, a -> a
            end)

          {node, acc2}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  # `parts` is a dotted `__aliases__` path as the file's OWN source wrote it
  # (e.g. `[:Escalation]`, `[:TB, :Escalation]`, `[:Tightbeam, :Escalation]`)
  # — resolved by expanding only its FIRST segment through the alias map
  # (Sol round 5, finding 2c): a prior version handled a whole-module alias
  # (`alias Tightbeam.Escalation`, one segment) but not a PREFIX alias
  # (`alias Tightbeam, as: TB` then `TB.Escalation.consume(...)`, where the
  # alias covers only the leading segment and `:Escalation` rides along
  # unresolved as literal text of its own). A reference whose ORIGINAL
  # leading segment is `:Elixir` is an ABSOLUTE module path (Sol round 7):
  # `Elixir.Tightbeam.Escalation` names exactly Tightbeam.Escalation
  # regardless of any local alias, so it must NOT undergo alias expansion —
  # a local `alias Fake.Other, as: Tightbeam` would otherwise expand the
  # stripped prefix and hide the real call. Relative references still
  # expand, and an alias's own target may carry an explicit `Elixir.`
  # prefix, stripped after expansion — `Elixir.Foo` and `Foo` name the
  # exact same module; only the AST shape differs.
  defp resolves_to_escalation?([:"Elixir" | rest], _aliases) do
    drop_leading_elixir(rest) == [:Tightbeam, :Escalation]
  end

  defp resolves_to_escalation?(parts, aliases) do
    parts
    |> expand_alias_prefix(aliases)
    |> drop_leading_elixir() == [:Tightbeam, :Escalation]
  end

  defp drop_leading_elixir([:"Elixir" | rest]), do: rest
  defp drop_leading_elixir(parts), do: parts

  defp expand_alias_prefix([first | rest], aliases) do
    case Map.fetch(aliases, first) do
      {:ok, expansion} -> expansion ++ rest
      :error -> [first | rest]
    end
  end

  # A module reference at the AST level, in EITHER shape a caller can write
  # it: `Mod.fun` syntax (an `__aliases__` node, resolved through this
  # file's aliases) or the ATOM form — `apply(:"Elixir.Tightbeam.Escalation",
  # ...)` or the equivalent `:"Elixir...".fun()` — which is already fully
  # qualified and evades an `__aliases__`-only match outright (Sol round 5,
  # finding 2b).
  defp resolves_module_ref_to_escalation?({:__aliases__, _, parts}, aliases),
    do: resolves_to_escalation?(parts, aliases)

  defp resolves_module_ref_to_escalation?(atom, _aliases) when is_atom(atom),
    do: atom == Tightbeam.Escalation

  defp resolves_module_ref_to_escalation?(_other, _aliases), do: false

  # Every `Escalation.<fun>` reference reachable in `node` that resolves
  # (through `aliases`, both alias forms and the atom form) to
  # `Tightbeam.Escalation` — a remote call, a `&Mod.fun/arity` capture, or a
  # 3-arity `apply/3` naming the module and function as literals. None of the
  # latter two add the literal `Escalation.fun(` substring a text scan looked
  # for.
  defp escalation_refs_called(node, aliases) do
    {_, refs} =
      Macro.prewalk(node, [], fn
        {{:., _, [mod_ast, fun]}, _, _args} = n, acc when is_atom(fun) ->
          if resolves_module_ref_to_escalation?(mod_ast, aliases),
            do: {n, [fun | acc]},
            else: {n, acc}

        {:&, _, [{:/, _, [{{:., _, [mod_ast, fun]}, _, []}, _arity]}]} = n, acc ->
          if resolves_module_ref_to_escalation?(mod_ast, aliases),
            do: {n, [fun | acc]},
            else: {n, acc}

        {:apply, _, [mod_ast, fun_atom, _args]} = n, acc when is_atom(fun_atom) ->
          if resolves_module_ref_to_escalation?(mod_ast, aliases),
            do: {n, [fun_atom | acc]},
            else: {n, acc}

        node2, acc ->
          {node2, acc}
      end)

    refs
  end

  # `apply/3` naming a LITERAL Escalation module but a NON-literal function
  # (Sol round 5, finding 2a): `escalation_refs_called/2` above requires the
  # function argument to be a literal atom to attribute the call to a `ref`,
  # and `has_dynamic_apply?/1` below only flags a non-literal MODULE — so a
  # literal-module, dynamic-function `apply/3` fell through both, invisible
  # to either. It cannot be scoped to any specific ref, so it fails closed
  # outright rather than being silently skipped.
  defp escalation_apply_dynamic_function_sites do
    Path.wildcard("lib/**/*.ex")
    |> Enum.reject(&(&1 == "lib/tightbeam/escalation.ex"))
    |> Enum.flat_map(fn file ->
      source = File.read!(file)
      {:ok, ast} = Code.string_to_quoted(source, columns: true)
      aliases = module_alias_map(ast)
      defs = function_defs_from_ast(ast)

      for {{name, arity}, nodes} <- defs,
          Enum.any?(nodes, &has_escalation_apply_with_dynamic_function?(&1, aliases)),
          do: {file, "#{name}/#{arity}"}
    end)
  end

  defp has_escalation_apply_with_dynamic_function?(node, aliases) do
    {_, hit?} =
      Macro.prewalk(node, false, fn
        {:apply, _, [mod_ast, fun_arg, _args_arg]} = n, acc ->
          hit = not is_atom(fun_arg) and resolves_module_ref_to_escalation?(mod_ast, aliases)
          {n, acc or hit}

        n, acc ->
          {n, acc}
      end)

    hit?
  end

  # `{ref, {file, "name/arity"}}` for every lib/ file (escalation.ex
  # excluded) and every one of its own functions that reaches Escalation —
  # computed once for the whole tree rather than once per pinned ref, since
  # the same walk answers every ref's question at the same time.
  defp escalation_callers_by_file do
    Path.wildcard("lib/**/*.ex")
    |> Enum.reject(&(&1 == "lib/tightbeam/escalation.ex"))
    |> Enum.flat_map(fn file ->
      source = File.read!(file)
      {:ok, ast} = Code.string_to_quoted(source, columns: true)
      aliases = module_alias_map(ast)
      defs = function_defs_from_ast(ast)

      for {{name, arity}, nodes} <- defs,
          refs = nodes |> Enum.flat_map(&escalation_refs_called(&1, aliases)) |> Enum.uniq(),
          refs != [],
          ref <- refs,
          do: {ref, {file, "#{name}/#{arity}"}}
    end)
  end

  defp imports_escalation?(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted(columns: true)
    aliases = module_alias_map(ast)

    {_, hit?} =
      Macro.prewalk(ast, false, fn
        {:import, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, acc or resolves_to_escalation?(parts, aliases)}

        node, acc ->
          {node, acc}
      end)

    hit?
  end

  # 3-arity `apply/3` sites anywhere in lib/ whose MODULE argument is not
  # itself a literal (an atom or an `alias`-resolvable name) — the one shape
  # this scan cannot resolve at all, because the target is decided at
  # runtime and could be anything, Escalation included.
  defp dynamic_apply_sites do
    Path.wildcard("lib/**/*.ex")
    |> Enum.flat_map(fn file ->
      defs = function_defs(file)

      for {{name, arity}, nodes} <- defs,
          Enum.any?(nodes, &has_dynamic_apply?/1),
          do: {file, "#{name}/#{arity}"}
    end)
  end

  defp has_dynamic_apply?(node) do
    {_, hit?} =
      Macro.prewalk(node, false, fn
        {:apply, _, [mod_arg, _fun_arg, _args_arg]} = n, acc ->
          literal? = is_atom(mod_arg) or match?({:__aliases__, _, _}, mod_arg)
          {n, acc or not literal?}

        n, acc ->
          {n, acc}
      end)

    hit?
  end

  # A handful of ALREADY-REVIEWED `decision_requests` queries carry no kind
  # constraint of their own because their safety comes from elsewhere in the
  # SAME transaction, never from their own WHERE clause — and each exception
  # is bound to a SHA-256 of the reviewed function's own WHOLE text, not just
  # to its name (Sol round 6, finding 3): the exception is only as good as
  # the SAFETY WITNESS a reviewer actually read, and a later edit to the
  # function can silently invalidate that witness while the ref's NAME stays
  # the same. `pin_status/2` recomputes the hash at check time; a mismatch
  # fails closed with a named message pointing at re-review, rather than
  # quietly keeping on trusting a witness nobody re-read.
  #
  #   - `escalate/4`'s INSERT never names the `kind` column at all and relies
  #     on the column's own schema DEFAULT ('statute' — proved by the DDL,
  #     not by this function).
  #   - `grant_waiver/6`'s two UPDATEs are scoped by `id`, and that id only
  #     ever comes from the SAME function's own `kind = 'statute'` SELECT
  #     immediately above it, never from a caller.
  #
  # A NEW unscoped literal anywhere else is not in this list and fails closed
  # too — that is the gap this list exists to keep narrow (Sol round 5,
  # finding 1b).
  @pinned_unscoped_literal_exceptions %{
    escalate: %{
      hash: "da3f89f2fe07f759b66a38a8df664480c8dc1a67a1778fca96c95a024397a6d3",
      witness:
        "the kind column's own schema DEFAULT 'statute' makes this INSERT statute-scoped " <>
          "without the column being named",
      literals: [
        "INSERT INTO decision_requests (id, raiserId, raiserSessionKey, ownerUserId, " <>
          "assignmentId, raisedAt, deadlineAt, statuteName, actionKey, question, options, " <>
          "context, status) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 'open') " <>
          "ON CONFLICT DO NOTHING"
      ]
    },
    grant_waiver: %{
      hash: "279a32de196240f089a7025c38e8dc89f6221f283df7cfd62d8e17f22954c4d8",
      witness:
        "both UPDATEs' ids come from this function's own adjacent kind = 'statute' SELECT, " <>
          "in the same transaction, never from a caller",
      literals: [
        "UPDATE decision_requests SET status = 'ruled', decision = 'waived', rationale = ?2, " <>
          "ruledBy = ?3, ruledAt = ?4 WHERE id = ?1 AND status = 'open'",
        "UPDATE decision_requests SET rulingFactId = ?2 WHERE id = ?1"
      ]
    }
  }

  defp sha256_hex(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  # `:valid` only if `ref` has a pinned exception AND the current function's
  # WHOLE text still hashes to the value the reviewer actually read;
  # `:stale` names both hashes so the error message is actionable; `:no_pin`
  # for a ref with no exception at all.
  defp pin_status(ref, text) do
    case Map.fetch(@pinned_unscoped_literal_exceptions, ref) do
      :error ->
        :no_pin

      {:ok, %{hash: expected_hash, witness: witness, literals: literals}} ->
        actual_hash = sha256_hex(text)

        if actual_hash == expected_hash do
          {:valid, literals}
        else
          {:stale, expected_hash, actual_hash, witness}
        end
    end
  end

  # Every double-quoted or triple-quoted string literal inside a chunk of
  # already-reconstructed (`Macro.to_string/1`) source, each NORMALIZED (and
  # quote-stripped) INDIVIDUALLY rather than joined into one blob (Sol round
  # 5, finding 1b): a single aggregated blob let one properly-scoped query's
  # `kind = '<declared>'` literal satisfy the whole function's check even
  # when a SECOND query in the same function carried no kind constraint (or
  # a wrong one) of its own — the aggregate text still contained the
  # required substring, so the check never looked past it.
  defp own_sql_texts(text) do
    Regex.scan(~r/"""(?:(?!""").)*"""|"[^"\n]*"/s, text)
    |> List.flatten()
    |> Enum.map(&normalize_sql_literal/1)
  end

  defp normalize_sql_literal(lit) do
    lit
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.replace("\\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Every OWN query literal that references `decision_requests` (case-
  # INSENSITIVE, Sol round 6, finding 1: SQL identifiers are case-
  # insensitive, so an unscoped `UPDATE DECISION_REQUESTS ...` following a
  # scoped lowercase query must not slip past this selector uncounted) must
  # individually prove one of two EXCLUSIVE shapes: `kind = '<declared>'` for
  # a single declared kind, or an explicit `kind IN (...)` list equal to a
  # declared pair (order-insensitive, whitespace/case-normalized). An
  # INSERT's positional `(..., kind, ...) VALUES (..., '<literal>', ...)`
  # counts as an equality too (`file_agent_request/2` and
  # `effort_insert_in_txn/2` set `kind` this way rather than filtering on
  # it). A literal with NO kind mention at all must be a reviewed, HASH-BOUND
  # exception (see `@pinned_unscoped_literal_exceptions`) or it fails closed
  # — an unscoped query is exactly the vulnerability this check exists to
  # catch, not something a substring match anywhere else in the function can
  # excuse (Sol round 5, finding 1b). `OR` is rejected outright, everywhere,
  # before any of that: no reviewed helper's SQL uses it today, so ANY
  # occurrence in a `decision_requests` query is unreviewed disjunction, and
  # `kind = 'statute' OR 1 = 1` (or an exact IN-list with the same `OR 1 = 1`
  # tacked on) must not slip past an eq/IN check that never looked for it
  # (Sol round 5, finding 1a).
  defp kind_predicate_shape(ref, text, declared_csv) do
    declared =
      declared_csv
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    own_literals =
      text
      |> own_sql_texts()
      |> Enum.filter(&(&1 =~ ~r/\bdecision_requests\b/i))

    if own_literals == [] do
      {:error,
       "#{ref}: its own SQL text has no per-literal decision_requests query to check — it may " <>
         "be attribute-derived or assembled from parts, which this text-based scan cannot " <>
         "decompose; review by hand"}
    else
      pin = pin_status(ref, text)

      own_literals
      |> Enum.map(&single_literal_kind_shape(ref, &1, declared, pin))
      |> Enum.find(:ok, &match?({:error, _}, &1))
    end
  end

  defp single_literal_kind_shape(ref, literal, declared, pin) do
    cond do
      literal =~ ~r/\bOR\b/i ->
        {:error,
         "#{ref}: its own SQL contains OR in a decision_requests query — no reviewed helper " <>
           "uses OR today, so any occurrence is unreviewed disjunction and fails closed: " <>
           inspect(literal)}

      not (literal =~ ~r/\bkind\b/i) ->
        case pin do
          {:valid, literals} ->
            if literal in literals do
              :ok
            else
              {:error,
               "#{ref}: a decision_requests query names no kind constraint at all and is not " <>
                 "among #{ref}'s reviewed exceptions: #{inspect(literal)}"}
            end

          {:stale, expected_hash, actual_hash, witness} ->
            {:error,
             "#{ref}: an unscoped decision_requests query relies on a pinned exception whose " <>
               "SAFETY WITNESS (#{inspect(witness)}) was reviewed against a DIFFERENT version " <>
               "of this function — pinned hash #{expected_hash}, now #{actual_hash}. The " <>
               "witness may no longer hold; re-review #{ref} and update " <>
               "@pinned_unscoped_literal_exceptions: #{inspect(literal)}"}

          :no_pin ->
            {:error,
             "#{ref}: a decision_requests query names no kind constraint at all and is not a " <>
               "reviewed exception in @pinned_unscoped_literal_exceptions: #{inspect(literal)}"}
        end

      true ->
        negations =
          Regex.scan(
            ~r/\bkind\s*(?:!=|<>)\s*'[a-z_]+'|\bkind\s+not\s+in\b|\bkind\s+is\s+not\b/i,
            literal
          )

        eq_matches =
          Regex.scan(~r/\bkind\s*=\s*'([a-z_]+)'/i, literal)
          |> Enum.map(fn [_, v] -> String.downcase(v) end)

        in_matches =
          Regex.scan(~r/\bkind\s+in\s*\(\s*((?:'[a-z_]+'\s*,\s*)*'[a-z_]+')\s*\)/i, literal)
          |> Enum.map(fn [_, list] ->
            Regex.scan(~r/'([a-z_]+)'/i, list) |> Enum.map(fn [_, v] -> String.downcase(v) end)
          end)

        insert_matches = insert_kind_literals(literal)

        cond do
          negations != [] ->
            {:error, "#{ref}: unrecognized kind-constraint shape (negation): #{inspect(literal)}"}

          length(declared) == 1 ->
            [only] = declared
            eqish = Enum.uniq(eq_matches ++ insert_matches)

            if eqish == [only] and in_matches == [] do
              :ok
            else
              {:error,
               "#{ref}: pinned kind #{inspect(only)} but a query constrains kind to " <>
                 "eq=#{inspect(eqish)} in=#{inspect(in_matches)} — expected exactly " <>
                 "`kind = '#{only}'`: #{inspect(literal)}"}
            end

          length(declared) == 2 ->
            sorted_declared = Enum.sort(declared)
            normalized_in = in_matches |> Enum.map(&Enum.sort/1) |> Enum.uniq()

            if eq_matches ++ insert_matches == [] and normalized_in == [sorted_declared] do
              :ok
            else
              {:error,
               "#{ref}: pinned pair #{inspect(sorted_declared)} but a query's kind shape is " <>
                 "eq=#{inspect(eq_matches ++ insert_matches)} in=#{inspect(normalized_in)}: " <>
                 "#{inspect(literal)}"}
            end

          true ->
            {:error, "#{ref}: unsupported declared-kind arity #{inspect(declared)}"}
        end
    end
  end

  # `insert into decision_requests (..., kind, ...) values (..., 'x', ...)`:
  # the literal at `kind`'s own column position, if any. Assumes no comma
  # falls inside a quoted value in these queries (true of every INSERT this
  # module writes today) — a conservative reading that only ever produces
  # FEWER matches than are really there, never a false equality.
  defp insert_kind_literals(sql) do
    Regex.scan(~r/insert\s+into\s+decision_requests\s*\(([^)]*)\)\s*values\s*\(([^)]*)\)/i, sql)
    |> Enum.flat_map(fn [_, cols, vals] ->
      columns = cols |> String.split(",") |> Enum.map(&String.trim/1)
      values = vals |> String.split(",") |> Enum.map(&String.trim/1)

      case Enum.find_index(columns, &(&1 == "kind")) do
        nil ->
          []

        idx ->
          case Enum.at(values, idx) do
            "'" <> rest ->
              case String.split(rest, "'", parts: 2) do
                [v, _] -> [String.downcase(v)]
                _ -> []
              end

            _ ->
              []
          end
      end
    end)
  end

  ## Teeth checks (Sol round 4): each one proves the HARDENED tripwire above
  ## actually rejects the exact evasion it was built to close, on a small
  ## synthetic fixture — never on the real escalation.ex, so these prove the
  ## MECHANISM rather than today's snapshot of it.

  test "TEETH (hole 1): a kind predicate widened past its declared scope is rejected, " <>
         "not merely substring-matched" do
    widened =
      "\"SELECT id FROM decision_requests WHERE kind IN ('statute','agent') AND raiserId = ?1\""

    assert {:error, message} = kind_predicate_shape(:fake_widened, widened, "statute")
    assert message =~ "fake_widened"
    assert message =~ "statute"

    # Sanity: the exact declared shape (what the widened text used to pass
    # AS, under the old bare `text =~ "'statute'"` substring check) still
    # passes under the new one.
    exact = "\"SELECT id FROM decision_requests WHERE kind = 'statute' AND raiserId = ?1\""
    assert :ok = kind_predicate_shape(:fake_exact, exact, "statute")

    # A pinned PAIR is equally strict: an extra IN member is rejected too.
    widened_pair =
      "\"SELECT COUNT(*) FROM decision_requests WHERE kind IN ('statute','effort','agent')\""

    assert {:error, _} = kind_predicate_shape(:fake_pair, widened_pair, "statute,effort")

    exact_pair =
      "\"SELECT COUNT(*) FROM decision_requests WHERE kind IN ('statute','effort')\""

    assert :ok = kind_predicate_shape(:fake_pair_ok, exact_pair, "statute,effort")
  end

  test "TEETH (hole 1, round 5): OR in a decision_requests query is rejected outright, since " <>
         "no reviewed helper uses it" do
    # eq + OR: an exclusive `kind = '<declared>'` match with a disjunction
    # tacked on that a bare eq/IN check never looked for.
    eq_or = "\"SELECT id FROM decision_requests WHERE kind = 'statute' OR 1 = 1\""
    assert {:error, message} = kind_predicate_shape(:fake_or_eq, eq_or, "statute")
    assert message =~ "fake_or_eq"

    # IN + OR: same shape, on the pair form.
    in_or =
      "\"SELECT id FROM decision_requests WHERE kind IN ('statute','effort') OR 1 = 1\""

    assert {:error, message} = kind_predicate_shape(:fake_or_in, in_or, "statute,effort")
    assert message =~ "fake_or_in"

    # Sanity: the OR-free forms these are derived from still pass.
    assert :ok =
             kind_predicate_shape(
               :fake_or_eq_clean,
               "\"SELECT id FROM decision_requests WHERE kind = 'statute'\"",
               "statute"
             )
  end

  test "TEETH (hole 1, round 5): a second, unscoped query in the same helper is not masked " <>
         "by the first, properly-scoped one" do
    # THE MASKING BUG: two SEPARATE query literals in one function — the
    # first properly scoped to the declared kind, the second naming
    # `decision_requests` with no kind constraint at all. An aggregate,
    # joined-text check sees the declared literal ANYWHERE in the combined
    # blob and never notices the second query lacks its own.
    masked_text =
      "\"SELECT id FROM decision_requests WHERE kind = 'statute' AND id = ?1\"\n" <>
        "\"UPDATE decision_requests SET status = 'closed' WHERE id = ?1\""

    assert {:error, message} = kind_predicate_shape(:fake_masked, masked_text, "statute")
    assert message =~ "fake_masked"

    # THE OLD CHECK, for contrast: joining every literal into one blob before
    # looking for the declared kind's own predicate — the masking bug being
    # closed.
    aggregate = masked_text |> own_sql_texts() |> Enum.join(" ")

    assert aggregate =~ "kind = 'statute'",
           "the old aggregate check was expected to find the declared predicate ANYWHERE in " <>
             "the joined text (that is the masking bug being closed) but it did not"

    # A widened SECOND query is caught the same way: the first is exact, the
    # second smuggles in a foreign kind via a bare eq (not an IN — that is
    # hole 1's original finding, covered above).
    widened_second =
      "\"SELECT id FROM decision_requests WHERE kind = 'statute' AND id = ?1\"\n" <>
        "\"SELECT id FROM decision_requests WHERE kind = 'effort' AND id = ?1\""

    assert {:error, _} = kind_predicate_shape(:fake_widened_second, widened_second, "statute")
  end

  test "TEETH (hole 1, round 6): an UPPERCASE decision_requests table name is not invisible " <>
         "to the per-literal selector" do
    # SQL identifiers are case-insensitive: `DECISION_REQUESTS` names the
    # exact same table `decision_requests` does. A scoped first query
    # followed by an unscoped SECOND query spelled in a different case must
    # not slip past the selector uncounted — the same masking bug as above,
    # reached through a case mismatch instead of a second literal.
    mixed_case_text =
      "\"SELECT id FROM decision_requests WHERE kind = 'statute' AND id = ?1\"\n" <>
        "\"UPDATE DECISION_REQUESTS SET status = 'closed' WHERE id = ?1\""

    assert {:error, message} =
             kind_predicate_shape(:fake_mixed_case, mixed_case_text, "statute")

    assert message =~ "fake_mixed_case"

    # THE OLD CHECK, for contrast: a case-SENSITIVE selector was expected to
    # MISS the uppercase literal entirely (never even counting it as an "own
    # literal" to check) — that is the evasion being closed.
    old_selector_literals =
      mixed_case_text |> own_sql_texts() |> Enum.filter(&(&1 =~ "decision_requests"))

    assert length(old_selector_literals) == 1,
           "a case-sensitive selector was expected to see only the lowercase literal (that is " <>
             "the evasion being closed) but it saw #{length(old_selector_literals)}"
  end

  test "TEETH (hole 2): an assembled or attribute-derived table name is caught at the AST " <>
         "level, where a Macro.to_string substring scan is blind to it" do
    assembled_src = ~S'''
    defmodule Fake.Assembled do
      def evasive_reader(db, id) do
        DB.query(db, "SELECT id FROM " <> "decision_" <> "requests" <> " WHERE id = ?1", [id])
      end
    end
    '''

    attribute_src = ~S'''
    defmodule Fake.AttributeDerived do
      @table "decision_requests"

      def evasive_reader(db, id) do
        DB.query(db, "SELECT id FROM #{@table} WHERE id = ?1", [id])
      end
    end
    '''

    for src <- [assembled_src, attribute_src] do
      {:ok, ast} = Code.string_to_quoted(src, columns: true)
      attrs = module_attrs_from_ast(ast)
      defs = function_defs_from_ast(ast)
      [{{:evasive_reader, 2}, nodes}] = Map.to_list(defs)

      # THE HARDENED CHECK: fragment-level, attribute- and concatenation-aware.
      frags = Enum.flat_map(nodes, &literal_fragments(&1, attrs))

      assert Enum.any?(frags, &String.contains?(&1, "decision_requests")),
             "the AST-level scan must catch this evasion: #{src}"

      # THE OLD CHECK, for contrast: a plain substring scan over
      # `Macro.to_string/1`'s reconstructed text — proven blind to it.
      naive_text = Enum.map_join(nodes, "\n", &Macro.to_string/1)

      refute naive_text |> own_sql_texts() |> Enum.any?(&(&1 =~ "decision_requests")),
             "a Macro.to_string substring scan was expected to MISS this evasion (that is " <>
               "the bug being closed) but it caught it: #{src}"
    end
  end

  test "TEETH (hole 2, round 6): an UPPERCASE table name is caught by the AST fragment scan " <>
         "too, not just the per-literal selector" do
    uppercase_src = ~S'''
    defmodule Fake.UppercaseTable do
      def evasive_reader(db, id) do
        DB.query(db, "SELECT id FROM DECISION_REQUESTS WHERE id = ?1", [id])
      end
    end
    '''

    {:ok, ast} = Code.string_to_quoted(uppercase_src, columns: true)
    attrs = module_attrs_from_ast(ast)
    defs = function_defs_from_ast(ast)
    [{{:evasive_reader, 2}, nodes}] = Map.to_list(defs)
    frags = Enum.flat_map(nodes, &literal_fragments(&1, attrs))

    # THE HARDENED CHECK: case-insensitive.
    assert Enum.any?(frags, &(&1 =~ ~r/\bdecision_requests\b/i)),
           "the case-insensitive AST-level scan must catch this evasion"

    # THE OLD CHECK, for contrast: a case-SENSITIVE `String.contains?/2` scan
    # was expected to MISS it — that is the evasion being closed.
    refute Enum.any?(frags, &String.contains?(&1, "decision_requests")),
           "a case-sensitive substring scan was expected to MISS this evasion (that is the " <>
             "bug being closed) but it caught it"
  end

  test "TEETH (hole 2): a new arity overload of an already-pinned reader name is invisible " <>
         "to a name-only pin but caught by an arity-aware one" do
    overload_src = ~S'''
    defmodule Fake.Overload do
      def reader(db, id) do
        DB.query(db, "SELECT id FROM decision_requests WHERE id = ?1", [id])
      end

      def reader(db, id, _extra) do
        DB.query(db, "SELECT id FROM decision_requests WHERE id = ?1", [id])
      end
    end
    '''

    {:ok, ast} = Code.string_to_quoted(overload_src, columns: true)
    attrs = module_attrs_from_ast(ast)
    defs = function_defs_from_ast(ast)

    direct_refs =
      for {ref, nodes} <- defs,
          frags = Enum.flat_map(nodes, &literal_fragments(&1, attrs)),
          Enum.any?(frags, &String.contains?(&1, "decision_requests")),
          into: MapSet.new(),
          do: ref

    assert direct_refs == MapSet.new([{:reader, 2}, {:reader, 3}])

    # A NAME-ONLY pin (what round 2's hand-declared map, and round 3's
    # derived-but-arity-collapsed map, both used) only ever pinned `:reader`
    # once — it cannot distinguish "the one arity I reviewed" from "a second
    # one nobody has".
    name_only_pin = MapSet.new([:reader])
    derived_names = for {name, _arity} <- direct_refs, into: MapSet.new(), do: name
    assert derived_names == name_only_pin, "both arities collapse to the same pinned name"

    # An ARITY-AWARE pin that only reviewed `reader/2` catches the new
    # `reader/3` as a diff.
    arity_aware_pin = MapSet.new([{:reader, 2}])
    refute direct_refs == arity_aware_pin
    assert MapSet.difference(direct_refs, arity_aware_pin) == MapSet.new([{:reader, 3}])
  end

  test "TEETH (hole 3): a capture-based external caller reaches Escalation invisibly to a " <>
         "textual `Mod.fun(` scan" do
    src = ~S'''
    defmodule Fake.Caller do
      alias Tightbeam.Escalation

      def captured(db, ids) do
        fun = &Escalation.consume/2
        Enum.map(ids, fn id -> fun.(db, id) end)
      end
    end
    '''

    {:ok, ast} = Code.string_to_quoted(src, columns: true)
    aliases = module_alias_map(ast)
    defs = function_defs_from_ast(ast)
    [{{:captured, 2}, nodes}] = Map.to_list(defs)

    # THE HARDENED CHECK: AST-level, alias-resolved, capture-aware.
    refs = nodes |> Enum.flat_map(&escalation_refs_called(&1, aliases)) |> Enum.uniq()
    assert refs == [:consume], "the AST-level scan must catch a captured Escalation call"

    # THE OLD CHECK, for contrast: `&Escalation.consume/2` has no trailing
    # `(` — a literal `Escalation.consume(` scan was expected to MISS it.
    naive_text = Enum.map_join(nodes, "\n", &Macro.to_string/1)

    refute naive_text =~ "Escalation.consume(",
           "a textual `Escalation.consume(` scan was expected to MISS this evasion (that is " <>
             "the bug being closed) but it caught it"
  end

  test "TEETH (hole 3): apply/3 with a non-literal module argument is flagged, since it " <>
         "cannot be ruled out as reaching Escalation" do
    dynamic_src = ~S'''
    defmodule Fake.DynamicApply do
      def perform(worker, args) do
        {mod, fun} = worker
        apply(mod, fun, args)
      end
    end
    '''

    literal_src = ~S'''
    defmodule Fake.LiteralApply do
      def perform(args) do
        apply(Tightbeam.Escalation, :consume, args)
      end
    end
    '''

    {:ok, dynamic_ast} = Code.string_to_quoted(dynamic_src, columns: true)
    [{{:perform, 2}, dynamic_nodes}] = dynamic_ast |> function_defs_from_ast() |> Map.to_list()
    assert Enum.any?(dynamic_nodes, &has_dynamic_apply?/1)

    {:ok, literal_ast} = Code.string_to_quoted(literal_src, columns: true)
    [{{:perform, 1}, literal_nodes}] = literal_ast |> function_defs_from_ast() |> Map.to_list()
    refute Enum.any?(literal_nodes, &has_dynamic_apply?/1)
  end

  test "TEETH (hole 3, round 5): apply/3 naming a LITERAL Escalation module but a " <>
         "non-literal function is flagged, since it cannot be scoped to any ref" do
    dynamic_fun_src = ~S'''
    defmodule Fake.EscalationDynamicFun do
      def perform(fun, args) do
        apply(Tightbeam.Escalation, fun, args)
      end
    end
    '''

    literal_fun_src = ~S'''
    defmodule Fake.EscalationLiteralFun do
      def perform(args) do
        apply(Tightbeam.Escalation, :consume, args)
      end
    end
    '''

    {:ok, dynamic_ast} = Code.string_to_quoted(dynamic_fun_src, columns: true)
    aliases_a = module_alias_map(dynamic_ast)
    [{{:perform, 2}, dynamic_nodes}] = dynamic_ast |> function_defs_from_ast() |> Map.to_list()

    # THE HARDENED CHECK: a literal Escalation module, dynamic function.
    assert Enum.any?(dynamic_nodes, &has_escalation_apply_with_dynamic_function?(&1, aliases_a))

    # Neither of the OLD checks caught this shape on its own: the module is
    # literal, so the dynamic-MODULE apply scan does not flag it; the
    # function is not a literal atom, so `escalation_refs_called/2` cannot
    # attribute it to any ref either.
    refute has_dynamic_apply?(hd(dynamic_nodes))
    assert Enum.flat_map(dynamic_nodes, &escalation_refs_called(&1, aliases_a)) == []

    {:ok, literal_ast} = Code.string_to_quoted(literal_fun_src, columns: true)
    aliases_b = module_alias_map(literal_ast)
    [{{:perform, 1}, literal_nodes}] = literal_ast |> function_defs_from_ast() |> Map.to_list()

    refute Enum.any?(literal_nodes, &has_escalation_apply_with_dynamic_function?(&1, aliases_b))
  end

  test "TEETH (hole 3, round 5): apply/3's ATOM-form module reference is caught, where an " <>
         "`__aliases__`-only resolver would miss it" do
    src = ~S'''
    defmodule Fake.AtomFormApply do
      def perform(db, id) do
        apply(:"Elixir.Tightbeam.Escalation", :consume, [db, id])
      end
    end
    '''

    {:ok, ast} = Code.string_to_quoted(src, columns: true)
    aliases = module_alias_map(ast)
    [{{:perform, 2}, nodes}] = ast |> function_defs_from_ast() |> Map.to_list()

    # THE HARDENED CHECK: atom-form and `__aliases__`-form modules resolve
    # identically.
    refs = nodes |> Enum.flat_map(&escalation_refs_called(&1, aliases)) |> Enum.uniq()
    assert refs == [:consume]

    # THE OLD CHECK, for contrast: a resolver that only ever matched
    # `{:__aliases__, _, parts}` for the module position was expected to
    # MISS this — the atom form has no such node to match at all.
    naive_refs =
      elem(
        Macro.prewalk(hd(nodes), [], fn
          {:apply, _, [{:__aliases__, _, parts}, fun_atom, _args]} = n, acc
          when is_atom(fun_atom) ->
            if resolves_to_escalation?(parts, aliases), do: {n, [fun_atom | acc]}, else: {n, acc}

          n, acc ->
            {n, acc}
        end),
        1
      )

    assert naive_refs == [],
           "an `__aliases__`-only resolver was expected to MISS the atom-form module (that is " <>
             "the evasion being closed) but it caught it"
  end

  test "TEETH (hole 3, round 5): a PREFIX alias (`alias Tightbeam, as: TB` then " <>
         "`TB.Escalation.consume(...)`) is resolved, where a whole-module-only alias map " <>
         "would miss it" do
    src = ~S'''
    defmodule Fake.PrefixAliasCaller do
      alias Tightbeam, as: TB

      def sneaky(db, id) do
        TB.Escalation.consume(db, id)
      end
    end
    '''

    {:ok, ast} = Code.string_to_quoted(src, columns: true)
    aliases = module_alias_map(ast)
    [{{:sneaky, 2}, nodes}] = ast |> function_defs_from_ast() |> Map.to_list()

    # THE HARDENED CHECK: the alias map's `TB -> [Tightbeam]` prefix is
    # expanded before the trailing `.Escalation` segment is compared.
    refs = nodes |> Enum.flat_map(&escalation_refs_called(&1, aliases)) |> Enum.uniq()
    assert refs == [:consume]

    # THE OLD CHECK, for contrast: a resolver that only expanded a
    # WHOLE-MODULE alias (`[single] -> Map.get(aliases, single) == [...]`)
    # never looks at a two-segment `[:TB, :Escalation]` reference at all —
    # it falls straight to a catch-all `false`.
    naive_resolves? = fn parts ->
      case parts do
        [:Tightbeam, :Escalation] -> true
        [single] -> Map.get(aliases, single) == [:Tightbeam, :Escalation]
        _ -> false
      end
    end

    naive_refs =
      elem(
        Macro.prewalk(hd(nodes), [], fn
          {{:., _, [{:__aliases__, _, parts}, fun]}, _, _args} = n, acc when is_atom(fun) ->
            if naive_resolves?.(parts), do: {n, [fun | acc]}, else: {n, acc}

          n, acc ->
            {n, acc}
        end),
        1
      )

    assert naive_refs == [],
           "a whole-module-only alias resolver was expected to MISS a prefix alias (that is " <>
             "the evasion being closed) but it caught it"
  end

  test "TEETH (hole 3, round 6): an explicit `Elixir.` prefix on the module reference is " <>
         "resolved, for both the literal-function and dynamic-function apply/3 forms" do
    literal_fun_src = ~S'''
    defmodule Fake.ElixirPrefixLiteralApply do
      def perform(db, id) do
        apply(Elixir.Tightbeam.Escalation, :consume, [db, id])
      end
    end
    '''

    dynamic_fun_src = ~S'''
    defmodule Fake.ElixirPrefixDynamicApply do
      def perform(fun, args) do
        apply(Elixir.Tightbeam.Escalation, fun, args)
      end
    end
    '''

    {:ok, literal_ast} = Code.string_to_quoted(literal_fun_src, columns: true)
    aliases_a = module_alias_map(literal_ast)
    [{{:perform, 2}, literal_nodes}] = literal_ast |> function_defs_from_ast() |> Map.to_list()

    # THE HARDENED CHECK: `[:Elixir, :Tightbeam, :Escalation]` resolves the
    # same as `[:Tightbeam, :Escalation]`.
    refs = literal_nodes |> Enum.flat_map(&escalation_refs_called(&1, aliases_a)) |> Enum.uniq()
    assert refs == [:consume]

    # THE OLD CHECK, for contrast: a resolver that compared the raw parts
    # directly against `[:Tightbeam, :Escalation]`, with no `Elixir.`-prefix
    # normalization, was expected to MISS the three-segment form.
    naive_resolves? = fn parts -> parts == [:Tightbeam, :Escalation] end

    naive_refs =
      elem(
        Macro.prewalk(hd(literal_nodes), [], fn
          {:apply, _, [{:__aliases__, _, parts}, fun_atom, _args]} = n, acc
          when is_atom(fun_atom) ->
            if naive_resolves?.(parts), do: {n, [fun_atom | acc]}, else: {n, acc}

          n, acc ->
            {n, acc}
        end),
        1
      )

    assert naive_refs == [],
           "a resolver with no `Elixir.`-prefix normalization was expected to MISS this (that " <>
             "is the evasion being closed) but it caught it"

    # The DYNAMIC-function mirror: literal `Elixir.`-prefixed module, but a
    # non-literal function — must still be flagged as unscopable.
    {:ok, dynamic_ast} = Code.string_to_quoted(dynamic_fun_src, columns: true)
    aliases_b = module_alias_map(dynamic_ast)
    [{{:perform, 2}, dynamic_nodes}] = dynamic_ast |> function_defs_from_ast() |> Map.to_list()

    assert Enum.any?(dynamic_nodes, &has_escalation_apply_with_dynamic_function?(&1, aliases_b))
  end

  test "TEETH (round 7): an ABSOLUTE `Elixir.`-prefixed reference bypasses local alias " <>
         "expansion — a hostile `alias Fake.Other, as: Tightbeam` cannot hide the real call" do
    hostile_src = ~S'''
    defmodule Fake.HostileAliasShadow do
      alias Fake.Other, as: Tightbeam

      def perform(db, id) do
        apply(Elixir.Tightbeam.Escalation, :consume, [db, id])
      end

      def sanity(db, id) do
        # the shadowing alias DOES apply to relative references — this one
        # really is Fake.Other.Escalation, not ours
        Tightbeam.Escalation.consume(db, id)
      end
    end
    '''

    {:ok, ast} = Code.string_to_quoted(hostile_src, columns: true)
    aliases = module_alias_map(ast)
    defs = function_defs_from_ast(ast)

    # THE HARDENED CHECK: the absolute reference in perform/2 resolves to the
    # real Escalation despite the shadowing alias...
    [{{:perform, 2}, perform_nodes}] = defs |> Enum.filter(&match?({{:perform, 2}, _}, &1))
    refs = perform_nodes |> Enum.flat_map(&escalation_refs_called(&1, aliases)) |> Enum.uniq()
    assert refs == [:consume]

    # ...while the RELATIVE reference in sanity/2 expands through the alias to
    # Fake.Other.Escalation and is correctly NOT attributed to ours.
    [{{:sanity, 2}, sanity_nodes}] = defs |> Enum.filter(&match?({{:sanity, 2}, _}, &1))
    assert sanity_nodes |> Enum.flat_map(&escalation_refs_called(&1, aliases)) == []

    # THE OLD CHECK, for contrast (Sol round 7): strip-then-expand let the
    # shadowing alias capture the stripped prefix and MISS the real call.
    strip_then_expand = fn parts ->
      parts
      |> drop_leading_elixir()
      |> expand_alias_prefix(aliases)
      |> drop_leading_elixir() == [:Tightbeam, :Escalation]
    end

    naive_refs =
      elem(
        Macro.prewalk(hd(perform_nodes), [], fn
          {:apply, _, [{:__aliases__, _, parts}, fun_atom, _args]} = n, acc
          when is_atom(fun_atom) ->
            if strip_then_expand.(parts), do: {n, [fun_atom | acc]}, else: {n, acc}

          n, acc ->
            {n, acc}
        end),
        1
      )

    assert naive_refs == [],
           "the strip-then-expand resolver was expected to MISS the absolute reference under " <>
             "a shadowing alias (that is the evasion being closed) but it caught it"
  end

  test "TEETH (round 6, finding 3): an edited unscoped-literal function fails its pin's hash, " <>
         "rather than silently keeping a stale safety witness" do
    # `escalate/4`'s real pinned text, with one clause of whitespace changed
    # — a stand-in for ANY real edit. The hash is computed over the WHOLE
    # function, so even a change nowhere near the unscoped literal itself
    # invalidates the pin.
    real_escalate_text = text_for_name(function_slices("lib/tightbeam/escalation.ex"), :escalate)
    assert {:valid, _} = pin_status(:escalate, real_escalate_text)

    edited_text = real_escalate_text <> " "
    assert {:stale, expected, actual, witness} = pin_status(:escalate, edited_text)
    assert expected != actual
    assert witness =~ "schema DEFAULT"

    # The unscoped INSERT literal that a `:valid` pin would have excused is
    # now rejected, by name, rather than silently trusting a witness nobody
    # re-read against the edited function.
    insert_literal =
      real_escalate_text
      |> own_sql_texts()
      |> Enum.find(&(&1 =~ ~r/\binsert\b/i))

    assert {:error, message} =
             single_literal_kind_shape(
               :escalate,
               insert_literal,
               ["statute"],
               {:stale, expected, actual, witness}
             )

    assert message =~ "escalate"
    assert message =~ "SAFETY WITNESS"
    assert message =~ expected
    assert message =~ actual

    # A ref with no pin at all is unaffected by any of this (`:no_pin`, not
    # `:stale`) — the two failure reasons stay distinguishable.
    assert :no_pin = pin_status(:open_episodes, "unrelated text")
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
  #
  # Comment-insensitive (Sol xhigh review round 3): a comment MENTIONING the
  # predicate must never satisfy this on the real SQL's behalf. `function_slices/1`
  # reconstructs the body from its AST (`Macro.to_string/1`), which excludes
  # comments by construction — there is no `# kind = 'statute'` comment for
  # this to accidentally match, because comments are never part of the AST
  # this reads from at all.
  test "the statute gate read's kind predicate is evidenced in its own query text" do
    slices = function_slices("lib/tightbeam/escalation.ex")
    gate_read_body = text_for_name(slices, :current_request)

    assert gate_read_body != "",
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

    # An unknown id and an id this caller cannot see are ONE answer — the
    # cursor is resolved against the visible item map, so a stranger's id and
    # a nonexistent one land here identically. O3: `cursor_not_found`, unified
    # with `attests`/`transcript`'s cursor refusals, what keeps the cursor
    # from being an oracle.
    assert {:error, %{code: "cursor_not_found", message: unknown}} =
             toplines(db, %{after: "wi_ghost"})

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
