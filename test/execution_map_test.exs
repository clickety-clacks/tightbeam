defmodule Tightbeam.ExecutionMapTest do
  @moduledoc """
  Proofs for spec topline-map-v1.

  Everything asserted here is on OUR side of the ACP seam: SQL, the normative
  membership function, authorization by omission, the parent-status
  quadrichotomy, the progress clock and the reader's own read-only-ness.

  Rows are written DIRECTLY wherever the proof needs a shape production cannot
  be asked for on demand — a legacy review/item conflict (the C2 guard refuses
  new ones, and the boot audit contemplates exactly this legacy row), a
  multi-node parent cycle, a self-parent, a recorded null creating-turn seq, a
  `known = 0` pre-C1 row, and a pre-attribution-epoch item. Proofs 8 and 14
  additionally drive REAL production writers so the reader is shown against
  production-written rows and not only against staged ones.

  Evaluation time is FROZEN at `@now` on every read: `since_progress_ms` is
  now-relative, so twin-world byte identity is only a claim about
  authorization if the clock cannot move between the two responses.
  """
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model
  import Plug.Test
  import Plug.Conn

  alias Tightbeam.{
    Assignments,
    CausalEvents,
    DB,
    Dispatch,
    Org,
    ExecutionMap,
    WorkItems,
    WorkState
  }

  # A frozen evaluation clock and an attribution cutoff well below the
  # timestamps every fixture uses, so "pre-cutoff" is something a proof opts
  # into rather than an accident of when the suite ran.
  @now 9_000_000
  @cutoff 1_000_000
  @default_created 2_000_000

  @statuses ~w(linked from_turn no_turn_observed unrecorded)

  # The spec's normative node shape, sorted. A field added to or dropped from the
  # telemetry builder reddens proof 2 rather than sliding in unreviewed.
  @node_keys Enum.sort(
               ~w(active assignments attests bracket1_armed closing_attests creation_context
                  fail_reason fan_out finished_at id jobs minds open_decision_requests
                  origin parent review_revision_bindings since_progress_ms spec_ref_name spec_ref_sha256 started_at
                  state title turns)a
             )

  # Ordering fixtures need distinct, ASCENDING createdAt values that are still
  # at or after the attribution cutoff — a bare `created_at: 1` would silently
  # turn every proof into a coverage proof.
  defp at(offset), do: @default_created + offset

  setup do
    db = :"toplines_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    prepare!(db)
    %{db: db}
  end

  # The twin-world proof needs a SECOND database standing up identically, so
  # schema and org setup live in one place rather than only in `setup`.
  defp prepare!(db) do
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn',0,1),('kay',0,1),('root',1,1)"
      )

    # The epoch is stamped once at table creation, so a test that needs a known
    # cutoff moves the single row rather than pretending to control the clock.
    :ok = DB.execute(db, "UPDATE causal_events_epoch SET at = #{@cutoff} WHERE id = 0")
  end

  ## Proof 1 — origin is reported and annotated, never classified

  test "proof 1: origin annotation is filter-independent and --origin selects on it", ctx do
    session!(ctx.db, "s_creator", "flynn")
    item!(ctx.db, "wi_user", created_at: at(1), created_by_user: "flynn")
    item!(ctx.db, "wi_session", created_at: at(2), created_by_session: "s_creator")

    all = roster(ctx)
    assert ids(all) == ["wi_user", "wi_session"]

    assert node(all, "wi_user").origin == %{principal: "user", created_by: "flynn"}
    assert node(all, "wi_session").origin == %{principal: "session", created_by: "s_creator"}

    assert ids(roster(ctx, %{origin: "user"})) == ["wi_user"]
    assert ids(roster(ctx, %{origin: "session"})) == ["wi_session"]
    assert ids(roster(ctx, %{origin: "all"})) == ["wi_user", "wi_session"]

    # The annotation is present regardless of filter, so one response can be
    # re-sliced by a caller — every filter that INCLUDES an item annotates it
    # identically.
    for params <- [%{}, %{origin: "all"}, %{origin: "user"}, %{state: "open"}] do
      case Enum.find(roster(ctx, params).items, &(&1.id == "wi_user")) do
        nil -> flunk("wi_user must appear under #{inspect(params)}")
        found -> assert found.origin == %{principal: "user", created_by: "flynn"}
      end
    end
  end

  ## Proof 2 — the parent-status quadrichotomy, all four in ONE response

  test "proof 2: linked, from_turn, no_turn_observed and unrecorded are distinct and exhaustive",
       ctx do
    session!(ctx.db, "s_lane", "flynn")

    # The parent target itself: the substrate LOOKED and nothing was running.
    item!(ctx.db, "wi_root", created_at: at(1), context_known: 1, created_in_turn_seq: nil)
    # An item-attributed running turn names it.
    turn!(ctx.db, 10, "s_lane", job_ref: "wi_root", status: "running")
    item!(ctx.db, "wi_linked", created_at: at(2), context_known: 1, created_in_turn_seq: 10)
    # A conversational turn: neither jobRef nor a resolving assignment.
    turn!(ctx.db, 11, "s_lane", status: "delivered")
    item!(ctx.db, "wi_from_turn", created_at: at(3), context_known: 1, created_in_turn_seq: 11)
    # Pre-C1: the substrate never looked, so the parent is UNKNOWABLE.
    item!(ctx.db, "wi_unrecorded", created_at: at(4), context_known: 0, created_in_turn_seq: nil)

    response = roster(ctx)

    assert parent(response, "wi_linked") == %{status: "linked", item: "wi_root"}
    assert parent(response, "wi_from_turn") == %{status: "from_turn", item: nil}
    assert parent(response, "wi_root") == %{status: "no_turn_observed", item: nil}
    assert parent(response, "wi_unrecorded") == %{status: "unrecorded", item: nil}

    observed = Enum.map(response.items, & &1.parent.status)
    assert Enum.sort(Enum.uniq(observed)) == Enum.sort(@statuses), "all four in one response"
    assert length(Enum.uniq(observed)) == 4, "the four statuses are DISTINCT"
    assert Enum.all?(observed, &(&1 in @statuses)), "the four are EXHAUSTIVE"

    # The load-bearing distinction: "looked and saw nothing" is not "never
    # looked", even though both carry item: nil so no consumer reading `item`
    # alone can mistake silence for knowledge.
    assert parent(response, "wi_root") != parent(response, "wi_unrecorded")
    assert is_nil(parent(response, "wi_root").item)
    assert is_nil(parent(response, "wi_unrecorded").item)

    # The row's own columns are reported verbatim alongside the derivation, and
    # the derived block never carries the creating turn's jobRef or assignmentId.
    assert node(response, "wi_linked").creation_context == %{recorded: true, turn_seq: 10}
    assert node(response, "wi_root").creation_context == %{recorded: true, turn_seq: nil}
    assert node(response, "wi_unrecorded").creation_context == %{recorded: false, turn_seq: nil}
    assert response.edge_basis == "concurrent_turn"

    assert Enum.all?(response.items, &(Enum.sort(Map.keys(&1.parent)) == [:item, :status])),
           "the parent block carries the status and the item and nothing else"

    # The node's own key set is the spec's normative node shape. Pinning it is
    # what makes "explicitly not reported: any percentage, completion estimate,
    # confidence score, or confidence grade" enforceable rather than aspirational
    # — a field added or dropped anywhere in the builder lands here.
    assert Enum.all?(response.items, &(Enum.sort(Map.keys(&1)) == @node_keys))

    # `title` and the spec pin are the item's own row, verbatim.
    pinned =
      item!(ctx.db, "wi_pinned",
        created_at: at(5),
        spec_ref_name: "topline-map-v1",
        spec_ref_sha256: String.duplicate("c", 64)
      )

    node = node(roster(ctx), pinned)
    assert node.title == "Item wi_pinned"
    assert node.spec_ref_name == "topline-map-v1"
    assert node.spec_ref_sha256 == String.duplicate("c", 64)

    # An unpinned item says so rather than guessing.
    assert node(roster(ctx), "wi_root").spec_ref_name == nil
    assert node(roster(ctx), "wi_root").spec_ref_sha256 == nil
  end

  ## Proof 3 — edge derivation succeeds through BOTH carriers

  test "proof 3: a jobRef with no assignment and a transitive review chain both derive", ctx do
    session!(ctx.db, "s_lane", "flynn")
    session!(ctx.db, "s_holder", "flynn")
    item!(ctx.db, "wi_bracket_parent", created_at: at(1))
    item!(ctx.db, "wi_review_parent", created_at: at(2))

    # Carrier 1 — a bracket nag carries the work-item id with NO assignment.
    turn!(ctx.db, 20, "s_lane", job_ref: "wi_bracket_parent", assignment_id: nil)

    item!(ctx.db, "wi_child_job_ref",
      created_at: at(3),
      context_known: 1,
      created_in_turn_seq: 20
    )

    # Carrier 2 — an assignment-only turn whose assignment resolves TRANSITIVELY
    # through a NULL-workItemId review assignment.
    assignment!(ctx.db, "asg_pinned", work_item_id: "wi_review_parent")
    assignment!(ctx.db, "asg_review", work_item_id: nil, reviews: "asg_pinned")
    turn!(ctx.db, 21, "s_lane", assignment_id: "asg_review", job_ref: nil)
    item!(ctx.db, "wi_child_review", created_at: at(4), context_known: 1, created_in_turn_seq: 21)

    response = roster(ctx)

    assert parent(response, "wi_child_job_ref") ==
             %{status: "linked", item: "wi_bracket_parent"}

    assert parent(response, "wi_child_review") ==
             %{status: "linked", item: "wi_review_parent"}

    # The same resolution rule feeds the turn union: the review turn belongs to
    # the item its assignment RESOLVES to.
    assert node(response, "wi_review_parent").turns.total == 1
  end

  ## Proof 4 — twin-world authorization: byte identity, not a marker sweep

  test "proof 4: every surface is byte-identical against a database without the invisible rows",
       ctx do
    seed_twin_world(ctx.db, invisible: true)

    twin = :"toplines_twin_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({DB, path: ":memory:", name: twin}, id: :twin_db))
    prepare!(twin)
    twin_ctx = fresh(twin)
    seed_twin_world(twin, invisible: false)

    # Identical caller, identical request, FROZEN evaluation time — the only
    # difference between the two databases is the presence of rows this caller
    # may not see.
    surfaces = [
      {:roster, %{}},
      {:roster, %{tree: true}},
      {:topline, %{under: "wi_anchor"}},
      {:topline, %{assignments: ["asg_visible", "asg_none"]}}
    ]

    for {kind, params} <- surfaces do
      present = JSON.encode!(read(ctx, kind, params))
      absent = JSON.encode!(read(twin_ctx, kind, params))

      assert present == absent,
             "#{kind} #{inspect(params)} leaked invisible rows into the response bytes"
    end

    # And the leak bar is not vacuous: the same surfaces DO see the visible rows.
    roster = read(ctx, :roster, %{})
    assert "wi_anchor" in ids(roster)
    assert node(roster, "wi_anchor").assignments.open == 1

    # The focused sub-proof: a visible child of an INVISIBLE parent reports the
    # conversational-turn block, byte-for-byte.
    assert parent(roster, "wi_hidden_parent_child") == %{status: "from_turn", item: nil}

    assert JSON.encode!(parent(roster, "wi_hidden_parent_child")) ==
             JSON.encode!(parent(roster, "wi_conversational_child"))
  end

  ## Proof 5 — --under, and cycle termination in traversal AND parent blocks

  test "proof 5: --under returns visible linked descendants and terminates on inserted cycles",
       ctx do
    session!(ctx.db, "s_lane", "flynn")
    item!(ctx.db, "wi_a", created_at: at(1))
    turn!(ctx.db, 30, "s_lane", job_ref: "wi_a")
    item!(ctx.db, "wi_b", created_at: at(2), context_known: 1, created_in_turn_seq: 30)
    turn!(ctx.db, 31, "s_lane", job_ref: "wi_b")
    item!(ctx.db, "wi_c", created_at: at(3), context_known: 1, created_in_turn_seq: 31)
    # A sibling branch that is NOT under wi_a.
    item!(ctx.db, "wi_elsewhere", created_at: at(4))

    under = read(ctx, :topline, %{under: "wi_a"})
    assert root_ids(under) == ["wi_a"]
    assert nested_ids(under) == ["wi_a", "wi_b", "wi_c"]
    refute "wi_elsewhere" in nested_ids(under)

    # Unknown and invisible anchors are ONE answer, byte-identical.
    unknown = read(ctx, :topline, %{under: "wi_does_not_exist"})
    item!(ctx.db, "wi_kay", owner: "kay")
    invisible = read(ctx, :topline, %{under: "wi_kay"})

    assert unknown == %{code: "not_found", message: "work item not found"}
    assert JSON.encode!(unknown) == JSON.encode!(invisible)

    # A directly inserted MULTI-NODE cycle: x -> y -> z -> x.
    turn!(ctx.db, 40, "s_lane", job_ref: "wi_y")
    turn!(ctx.db, 41, "s_lane", job_ref: "wi_z")
    turn!(ctx.db, 42, "s_lane", job_ref: "wi_x")
    item!(ctx.db, "wi_x", created_at: at(10), context_known: 1, created_in_turn_seq: 40)
    item!(ctx.db, "wi_y", created_at: at(11), context_known: 1, created_in_turn_seq: 41)
    item!(ctx.db, "wi_z", created_at: at(12), context_known: 1, created_in_turn_seq: 42)

    cycle = read(ctx, :topline, %{under: "wi_z"})
    assert Enum.sort(nested_ids(cycle)) == ["wi_x", "wi_y", "wi_z"]
    assert nested_ids(cycle) == ["wi_z", "wi_y", "wi_x"], "the retained chain, not the cycle"
    # wi_x is the chain's LEAF: nothing hangs below it, and asking terminates.
    assert nested_ids(read(ctx, :topline, %{under: "wi_x"})) == ["wi_x"]

    roster = roster(ctx)

    # Canonical node order decides WHICH edge closes the cycle: the walk starts
    # at wi_x (earliest createdAt), climbs x -> y -> z, and z's edge back to x
    # is the cycle-closing one. It is dropped from traversal AND reported as the
    # same from_turn result in the source node's own parent block.
    assert parent(roster, "wi_x") == %{status: "linked", item: "wi_y"}
    assert parent(roster, "wi_y") == %{status: "linked", item: "wi_z"}
    assert parent(roster, "wi_z") == %{status: "from_turn", item: nil}

    tree = roster(ctx, %{tree: true})
    assert "wi_z" in root_ids(tree), "the cycle's retained forest must have a root"
    assert length(nested_ids(tree)) == length(Enum.uniq(nested_ids(tree))), "no node repeats"

    # A directly inserted SELF-parent yields neither a traversal edge nor a
    # linked-to-self block.
    turn!(ctx.db, 50, "s_lane", job_ref: "wi_self")
    item!(ctx.db, "wi_self", created_at: at(20), context_known: 1, created_in_turn_seq: 50)

    self_roster = roster(ctx)
    assert parent(self_roster, "wi_self") == %{status: "from_turn", item: nil}
    assert parent(self_roster, "wi_self") != %{status: "linked", item: "wi_self"}

    self_tree = roster(ctx, %{tree: true})
    assert "wi_self" in root_ids(self_tree)
    assert children(self_tree, "wi_self") == []
  end

  ## Proof 6 — singular resolved membership under a legacy conflict

  test "proof 6: a legacy conflicted review contributes to exactly ONE item's telemetry", ctx do
    session!(ctx.db, "s_holder_a", "flynn")
    session!(ctx.db, "s_holder_r", "flynn")
    item!(ctx.db, "wi_A", created_at: at(1))
    item!(ctx.db, "wi_B", created_at: at(2))

    assignment!(ctx.db, "asg_a", work_item_id: "wi_A", holder: "s_holder_a")

    # THE legacy conflict the boot audit contemplates: R's own pin is B while it
    # reviews A's chain. The C2 guard refuses new ones, so this row is inserted
    # directly — and own-pin-WINS, so R belongs to B and to B alone.
    assignment!(ctx.db, "asg_r",
      work_item_id: "wi_B",
      reviews: "asg_a",
      holder: "s_holder_r"
    )

    assert Assignments.resolved_work_item_id(ctx.db, "asg_r") == "wi_B"

    attest!(ctx.db, "att_r", "asg_r", by_session: "s_holder_r", ts: 3_000_000)

    turn!(ctx.db, 60, "s_holder_r",
      assignment_id: "asg_r",
      job_ref: nil,
      model: "m-r",
      effort: "high",
      context: "1m",
      harness: "claude"
    )

    # A child created during that assignment-only turn: derivation must resolve B.
    item!(ctx.db, "wi_child", created_at: at(5), context_known: 1, created_in_turn_seq: 60)

    response = roster(ctx)
    a = node(response, "wi_A")
    b = node(response, "wi_B")

    # Every consumer agrees, and none of them double-counts.
    assert b.assignments.open == 1
    assert b.attests.total == 1
    assert b.jobs == 1
    assert b.turns.total == 1
    assert b.minds == [%{model: "m-r", context: "1m", effort: "high", harness: "claude"}]

    assert a.assignments.open == 1, "A keeps its OWN assignment"
    assert a.attests.total == 0, "A receives none of R's attests"
    assert a.jobs == 1, "A's only ever-holder is its own"
    assert a.turns.total == 0, "the turn union places that turn under B only"
    assert a.minds == []

    assert parent(response, "wi_child") == %{status: "linked", item: "wi_B"},
           "edge derivation uses the same resolution rule the turn union does"

    # An ORDINARY null-pin review still follows its chain.
    assignment!(ctx.db, "asg_plain_review",
      work_item_id: nil,
      reviews: "asg_a",
      holder: "s_holder_r"
    )

    assert Assignments.resolved_work_item_id(ctx.db, "asg_plain_review") == "wi_A"
    assert node(roster(ctx), "wi_A").assignments.open == 2

    # A NONE assignment belongs to NO item's ordinary telemetry, and creates no
    # synthetic item.
    assignment!(ctx.db, "asg_none", work_item_id: nil, reviews: nil, holder: "s_holder_r")
    assert Assignments.resolved_work_item_id(ctx.db, "asg_none") == nil

    after_none = roster(ctx)
    assert ids(after_none) == ids(response), "a NONE assignment creates no synthetic item"
    assert node(after_none, "wi_A").assignments.open == 2
    assert node(after_none, "wi_B").assignments.open == 1

    # DIRECT consumers are NOT widened: story membership is not a lifecycle
    # action. feature_smoke's revoke loop and the client snapshots key on the
    # item's own pin, so R appears under B and never under A.
    assert Enum.map(Assignments.__for_work_item__(ctx.db, "wi_A"), & &1.id) == ["asg_a"]
    assert Enum.map(Assignments.__for_work_item__(ctx.db, "wi_B"), & &1.id) == ["asg_r"]

    direct = WorkState.item_detail(ctx.db, "wi_A")
    assert Enum.map(direct.assignments, & &1.id) == ["asg_a"]

    # And reading the topline changes neither DIRECT snapshot, byte for byte.
    _ = roster(ctx)
    assert JSON.encode!(WorkState.item_detail(ctx.db, "wi_A")) == JSON.encode!(direct)
  end

  ## Proof 7 — the turn union, from both arms, deduped by seq

  test "proof 7: a bracket nag, a review turn and a both-keys turn each count exactly once",
       ctx do
    session!(ctx.db, "s_holder", "flynn")
    item!(ctx.db, "wi_union")
    assignment!(ctx.db, "asg_union", work_item_id: "wi_union", holder: "s_holder")

    # A bracket nag carries jobRef and NO assignment; a review turn carries the
    # assignment and NO jobRef; either arm alone undercounts.
    turn!(ctx.db, 70, "s_holder", job_ref: "wi_union", assignment_id: nil, ended_at: 3_100_000)
    turn!(ctx.db, 71, "s_holder", job_ref: nil, assignment_id: "asg_union", ended_at: 3_200_000)

    turn!(ctx.db, 72, "s_holder",
      job_ref: "wi_union",
      assignment_id: "asg_union",
      ended_at: 3_300_000
    )

    telemetry = node(roster(ctx), "wi_union")

    assert telemetry.turns.total == 3, "both arms count, and the both-keys turn is not doubled"
    assert telemetry.turns.last_ended_at == 3_300_000
  end

  ## Proof 8 — terminal fields, against production writers

  test "proof 8: finished_at tracks the CURRENT terminal state and closing_attests exclude revoked",
       ctx do
    session!(ctx.db, "s_holder", "flynn")

    # Driven through the real disposition writer, so the causal event under test
    # is the one production appends.
    item!(ctx.db, "wi_cycle")
    assert %{workItem: %{state: "iceboxed"}} = dispose(ctx.db, "work-item-icebox", "wi_cycle")
    assert %{workItem: %{state: "open"}} = dispose(ctx.db, "work-item-reopen", "wi_cycle")

    assert node(roster(ctx), "wi_cycle").finished_at == nil,
           "an OPEN item is unfinished even with prior transitions"

    assert %{workItem: %{state: "closed"}} = dispose(ctx.db, "work-item-close", "wi_cycle")
    closed = node(roster(ctx), "wi_cycle")
    assert is_integer(closed.finished_at)
    assert closed.finished_at == disposition_at(ctx.db, "wi_cycle", "closed")

    # A terminal item whose transition predates the event table has no MATCHING
    # event, so finished_at is null rather than invented. The non-matching event
    # staged alongside it is what makes this bite: "no matching event" is not
    # "no events at all", and a reader that took the latest transition
    # regardless of toState would report this item as finished at that event.
    item!(ctx.db, "wi_pre_event", state: "failed", fail_reason: "no history")
    disposition!(ctx.db, "wi_pre_event", from: "open", to: "closed")

    pre_event = node(roster(ctx), "wi_pre_event")
    assert pre_event.finished_at == nil
    assert pre_event.state == "failed"
    assert pre_event.fail_reason == "no history"

    # And the match is on the CURRENT terminal state even when a later,
    # non-matching transition exists after the matching one.
    disposition!(ctx.db, "wi_cycle", from: "closed", to: "iceboxed")

    assert node(roster(ctx), "wi_cycle").finished_at ==
             disposition_at(ctx.db, "wi_cycle", "closed")

    # closing_attests: completed and surrendered REQUIRE a non-null closing
    # attest; revoked requires it to be null, so a revoked close is represented
    # only in by_outcome.revoked.
    item!(ctx.db, "wi_closes")
    assignment!(ctx.db, "asg_done", work_item_id: "wi_closes", holder: "s_holder")
    assignment!(ctx.db, "asg_review", reviews: "asg_done", holder: "s_holder")
    assignment!(ctx.db, "asg_gave_up", work_item_id: "wi_closes", holder: "s_holder")
    assignment!(ctx.db, "asg_revoked", work_item_id: "wi_closes", holder: "s_holder")

    attest!(ctx.db, "att_done", "asg_done", by_session: "s_holder", commit_refs: ["abc123"])
    attest!(ctx.db, "att_gave_up", "asg_gave_up", by_session: "s_holder", kind: "surrender")

    close!(ctx.db, "asg_done", "completed", "att_done")
    close!(ctx.db, "asg_gave_up", "surrendered", "att_gave_up")
    close!(ctx.db, "asg_revoked", "revoked", nil)

    :ok =
      DB.execute(
        ctx.db,
        """
        INSERT INTO assignment_review_revisions
          (reviewAssignmentId, repo, commitOid, bySession, cause, ts)
        VALUES ('asg_review', 'testhost:/repo', '#{String.duplicate("a", 40)}',
                's_holder', 'review-commission', #{@default_created})
        """
      )

    telemetry = node(roster(ctx), "wi_closes")

    assert telemetry.closing_attests == [
             %{assignmentId: "asg_done", attestId: "att_done", commitRefs: ["abc123"]},
             %{assignmentId: "asg_gave_up", attestId: "att_gave_up", commitRefs: nil}
           ]

    assert telemetry.review_revision_bindings == [
             %{
               reviewAssignmentId: "asg_review",
               commitRefs: [
                 %{repo: "testhost:/repo", commit: String.duplicate("a", 40)}
               ],
               principal: "session:s_holder",
               cause: "review-commission",
               ts: @default_created
             }
           ]

    assert telemetry.assignments == %{
             open: 1,
             closed: 3,
             by_outcome: %{completed: 1, surrendered: 1, revoked: 1}
           }

    refute Enum.any?(telemetry.closing_attests, &(&1.assignmentId == "asg_revoked"))
  end

  ## Proof 9 — the progress clock and quietness

  test "proof 9: the clock floors at the cutoff, attests reset it, and wakes never do", ctx do
    session!(ctx.db, "s_stale", "flynn")
    session!(ctx.db, "s_current", "flynn")

    # An item created before attribution was knowable: its clock can never claim
    # quiet time from before the cutoff.
    item!(ctx.db, "wi_ancient", created_at: 5_000)
    ancient = node(roster(ctx), "wi_ancient")

    assert ancient.since_progress_ms == @now - @cutoff
    assert ancient.since_progress_ms <= @now - @cutoff

    # A durable PRE-EPOCH attest participates as a progress event — it is not
    # discarded — but the same floor still bounds the answer.
    assignment!(ctx.db, "asg_ancient", work_item_id: "wi_ancient", holder: "s_current")
    attest!(ctx.db, "att_pre_epoch", "asg_ancient", by_session: "s_current", ts: 500_000)
    assert node(roster(ctx), "wi_ancient").since_progress_ms == @now - @cutoff

    # Filing one AFTER the cutoff resets the clock.
    attest!(ctx.db, "att_recent", "asg_ancient", by_session: "s_current", ts: 4_000_000)
    assert node(roster(ctx), "wi_ancient").since_progress_ms == @now - 4_000_000

    # A scheduled or fired wake is NOT progress.
    item!(ctx.db, "wi_quiet", created_at: 3_000_000)
    before_wake = node(roster(ctx), "wi_quiet").since_progress_ms
    wake!(ctx.db, "wk_sched", "s_current", state: "pending", work_item_id: "wi_quiet")
    wake!(ctx.db, "wk_fired", "s_current", state: "fired", work_item_id: "wi_quiet")
    assert node(roster(ctx), "wi_quiet").since_progress_ms == before_wake

    # --quiet-over: an item with a RUNNING turn on its resolved set is not quiet
    # however old its last progress event is.
    item!(ctx.db, "wi_running", created_at: 2_000_000)
    assignment!(ctx.db, "asg_running", work_item_id: "wi_running", holder: "s_current")
    turn!(ctx.db, 80, "s_current", assignment_id: "asg_running", status: "running")

    bound = 1_000
    quiet = ids(roster(ctx, %{quiet_over: bound}))
    assert "wi_quiet" in quiet
    refute "wi_running" in quiet, "a running turn defeats --quiet-over"
    assert node(roster(ctx), "wi_running").active.running_turn == true

    # A pending PROMPT wake on a current open holder also defeats it — the gate
    # is session-keyed across all pending prompt wakes, not item-attributed.
    item!(ctx.db, "wi_pending", created_at: 2_000_000)
    session!(ctx.db, "s_nudged", "flynn")
    assignment!(ctx.db, "asg_pending", work_item_id: "wi_pending", holder: "s_nudged")
    wake!(ctx.db, "wk_prompt", "s_nudged", state: "pending")

    assert node(roster(ctx), "wi_pending").active.pending_session_wake == true
    refute "wi_pending" in ids(roster(ctx, %{quiet_over: bound}))

    # A STALE ex-holder — only closed assignments — marks nothing active. It
    # remains represented only in the ever-held `jobs` history.
    item!(ctx.db, "wi_stale", created_at: 2_000_000)
    assignment!(ctx.db, "asg_stale", work_item_id: "wi_stale", holder: "s_stale")
    close!(ctx.db, "asg_stale", "revoked", nil)
    wake!(ctx.db, "wk_stale_prompt", "s_stale", state: "pending")

    stale = node(roster(ctx), "wi_stale")
    assert stale.active.pending_session_wake == false, "a stale ex-holder is not a current holder"
    assert stale.jobs == 1, "the ever-held history still counts it"
    assert "wi_stale" in ids(roster(ctx, %{quiet_over: bound}))
  end

  ## Proof 10 — coverage: absence before the cutoff is unknown, never zero

  test "proof 10: a pre-cutoff item nulls attribution-dependent counts and keeps durable facts",
       ctx do
    session!(ctx.db, "s_holder", "flynn")
    item!(ctx.db, "wi_old", created_at: @cutoff - 1)
    item!(ctx.db, "wi_new", created_at: @cutoff)

    assignment!(ctx.db, "asg_old", work_item_id: "wi_old", holder: "s_holder")
    attest!(ctx.db, "att_old", "asg_old", by_session: "s_holder", ts: 2_000_000)

    response = roster(ctx)
    old = node(response, "wi_old")
    new = node(response, "wi_new")

    assert response.coverage == %{attribution_cutoff: @cutoff, basis: "conservative_shared"}

    # Attribution carriers shipped as nullable ALTERs with no per-row stamp, so
    # a zero here would be a claim the rows cannot support.
    assert old.turns == %{total: nil, last_ended_at: nil}
    assert old.minds == nil
    assert old.fan_out == nil

    # An item at the cutoff is covered: its zeros are real zeros.
    assert new.turns == %{total: 0, last_ended_at: nil}
    assert new.minds == []
    assert new.fan_out == 0

    # Durable assignment and attest facts remain populated for the old item.
    assert old.assignments.open == 1
    assert old.jobs == 1
    assert old.attests.total == 1
    assert is_integer(old.started_at)

    # Parent derivation does NOT use the shared cutoff: C1 carries its own
    # per-row knowledge bit, and `unrecorded` is that edge's coverage statement.
    assert old.parent == %{status: "unrecorded", item: nil}
    assert old.creation_context == %{recorded: false, turn_seq: nil}

    turn!(ctx.db, 90, "s_holder", job_ref: "wi_old")

    item!(ctx.db, "wi_old_known",
      created_at: @cutoff - 2,
      context_known: 1,
      created_in_turn_seq: 90
    )

    old_known = node(roster(ctx), "wi_old_known")
    assert old_known.parent == %{status: "linked", item: "wi_old"}
    assert old_known.turns == %{total: nil, last_ended_at: nil}
  end

  ## Proof 11 — filtered forests keep the child and name the excluded parent

  test "proof 11: a filter-excluded visible parent leaves its child top-level and still named",
       ctx do
    session!(ctx.db, "s_lane", "flynn")
    item!(ctx.db, "wi_parent", created_at: at(1), state: "open")
    turn!(ctx.db, 100, "s_lane", job_ref: "wi_parent")

    item!(ctx.db, "wi_kid",
      created_at: at(2),
      state: "closed",
      context_known: 1,
      created_in_turn_seq: 100
    )

    # Two more closed siblings with an equal createdAt, to pin the tiebreak.
    item!(ctx.db, "wi_zz", created_at: at(3), state: "closed")
    item!(ctx.db, "wi_aa", created_at: at(3), state: "closed")

    for kind <- [:tree, :under] do
      response =
        case kind do
          :tree -> roster(ctx, %{tree: true, state: "closed"})
          :under -> read(ctx, :topline, %{under: "wi_parent", state: "closed"})
        end

      assert root_ids(response) == ["wi_kid"] or
               root_ids(response) == ["wi_kid", "wi_aa", "wi_zz"],
             "#{kind} roots were #{inspect(root_ids(response))}"

      kid = Enum.find(response.roots, &(&1.id == "wi_kid"))

      assert kid.parent == %{status: "linked", item: "wi_parent"},
             "#{kind}: an excluded parent stays NAMEABLE in the child's block"

      refute "wi_parent" in nested_ids(response), "#{kind}: the excluded parent is not pulled in"
      assert kid.children == [], "#{kind}: no placeholder node is emitted"
    end

    # Root/sibling order is createdAt ASC then id ASC, tiebreak included.
    assert root_ids(roster(ctx, %{tree: true, state: "closed"})) == ["wi_kid", "wi_aa", "wi_zz"]
  end

  ## Proof 12 — --assignments exercises all three classes at once

  test "proof 12: with-item, NONE and unknown-versus-invisible ids in one proof", ctx do
    session!(ctx.db, "s_mine", "flynn")
    session!(ctx.db, "s_theirs", "kay")
    item!(ctx.db, "wi_selected")
    item!(ctx.db, "wi_theirs", owner: "kay")

    assignment!(ctx.db, "asg_with_item", work_item_id: "wi_selected", holder: "s_mine")
    assignment!(ctx.db, "asg_none", work_item_id: nil, reviews: nil, holder: "s_mine")
    assignment!(ctx.db, "asg_theirs", work_item_id: "wi_theirs", holder: "s_theirs")

    response = read(ctx, :topline, %{assignments: ["asg_with_item", "asg_none"]})

    assert ids(response) == ["wi_selected"], "a visible with-item id contributes its item"
    assert response.no_item == ["asg_none"], "a visible NONE id contributes no item"

    # Duplicates COLLAPSE — the item appears once, the NONE id once.
    duplicated =
      read(ctx, :topline, %{
        assignments: ["asg_with_item", "asg_with_item", "asg_none", "asg_none"]
      })

    assert JSON.encode!(duplicated) == JSON.encode!(response)

    # Unknown and invisible are byte-identical, all-or-nothing not_found — even
    # when every OTHER id in the request is perfectly visible.
    unknown = read(ctx, :topline, %{assignments: ["asg_with_item", "asg_nonexistent"]})
    invisible = read(ctx, :topline, %{assignments: ["asg_with_item", "asg_theirs"]})

    assert unknown == %{code: "not_found", message: "assignment not found"}
    assert JSON.encode!(unknown) == JSON.encode!(invisible)

    # `no_item` is assignment id ASCENDING.
    assignment!(ctx.db, "asg_aaa", work_item_id: nil, reviews: nil, holder: "s_mine")

    assert read(ctx, :topline, %{assignments: ["asg_none", "asg_aaa"]}).no_item ==
             ["asg_aaa", "asg_none"]

    # Empty input is a USAGE error, not an empty result.
    assert read(ctx, :topline, %{assignments: []}) ==
             %{code: "invalid", message: "--assignments requires at least one assignment id"}

    # A NONE assignment held by someone else's session is invisible, so it
    # conflates with unknown rather than appearing in no_item.
    assignment!(ctx.db, "asg_none_theirs", work_item_id: nil, reviews: nil, holder: "s_theirs")

    assert JSON.encode!(read(ctx, :topline, %{assignments: ["asg_none_theirs"]})) ==
             JSON.encode!(read(ctx, :topline, %{assignments: ["asg_nonexistent"]}))

    # An admin sees the NONE assignment under the assignment-detail rule.
    admin = read(ctx, :topline, %{assignments: ["asg_none_theirs"]}, principal: {:user, "root"})
    assert admin.no_item == ["asg_none_theirs"]
  end

  ## Proof 13 — deterministic order under every filter combination

  test "proof 13: roster order is createdAt ASC then id ASC under every filter combination",
       ctx do
    session!(ctx.db, "s_creator", "flynn")

    # Equal createdAt across three ids forces the id tiebreak to do the work.
    for {id, created} <- [
          {"wi_ccc", 100},
          {"wi_aaa", 100},
          {"wi_bbb", 100},
          {"wi_early", 50},
          {"wi_late", 200}
        ] do
      item!(ctx.db, id,
        created_at: created,
        created_by_session: "s_creator",
        spec_ref_name: "topline-map-v1",
        spec_ref_sha256: String.duplicate("a", 64)
      )
    end

    combinations =
      for origin <- [nil, "all", "session"],
          owner <- [nil, "flynn"],
          state <- [nil, "open"],
          spec <- [nil, "topline-map-v1"],
          session <- [nil, "s_creator"] do
        %{origin: origin, owner: owner, state: state, spec: spec, session: session}
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
      end

    expected = ["wi_early", "wi_aaa", "wi_bbb", "wi_ccc", "wi_late"]

    for params <- combinations do
      assert ids(roster(ctx, params)) == expected,
             "roster order broke under #{inspect(params)}"

      assert root_ids(roster(ctx, Map.put(params, :tree, true))) == expected,
             "forest root order broke under #{inspect(params)}"
    end

    # The spec-sha narrowing is exact: a non-matching sha selects nothing.
    assert ids(roster(ctx, %{spec: "topline-map-v1", spec_sha: String.duplicate("b", 64)})) == []
  end

  ## Proof 14 — every surface is read-only in its own effects

  test "proof 14: a dispatched read writes only the ordinary audit row", ctx do
    session!(ctx.db, "s_holder", "flynn")
    item!(ctx.db, "wi_readonly")
    assignment!(ctx.db, "asg_readonly", work_item_id: "wi_readonly", holder: "s_holder")

    handlers = %{
      "toplines" => fn call -> ExecutionMap.roster(ctx.db, call) end,
      "topline" => fn call -> ExecutionMap.topline(ctx.db, call) end
    }

    before = snapshot(ctx.db)

    for {verb, params} <- [
          {"toplines", %{}},
          {"toplines", %{tree: true}},
          {"topline", %{under: "wi_readonly"}},
          {"topline", %{assignments: ["asg_readonly"]}}
        ] do
      assert {:ok, _result} =
               Dispatch.dispatch(ctx.db, handlers, %{
                 verb: verb,
                 origin: "user:flynn",
                 principal: {:user, "flynn"},
                 session_key: nil,
                 params: params
               })
    end

    # The audit row is expected and allowed; nothing ELSE may have moved.
    assert Map.delete(snapshot(ctx.db), "events") == Map.delete(before, "events")
    assert length(snapshot(ctx.db)["events"]) == length(before["events"]) + 4
  end

  ## Surface — the wiring these verbs need, at the router

  test "the router routes both verbs and refuses a volunteered typed target", ctx do
    session!(ctx.db, "s_real", "flynn")
    item!(ctx.db, "wi_routed")

    opts = [
      db: ctx.db,
      base_dir: System.tmp_dir!(),
      handlers: %{
        "toplines" => fn call -> ExecutionMap.roster(ctx.db, call) end,
        "topline" => fn call -> ExecutionMap.topline(ctx.db, call) end
      },
      cli_token: "tbc_toplines",
      session_status: fn _ -> nil end
    ]

    ok = post_dispatch(opts, %{verb: "toplines", asUser: "flynn", params: %{}})
    assert ok.status == 200
    assert [%{"id" => "wi_routed"}] = JSON.decode!(ok.resp_body)["result"]["items"]

    # `--session` is a COHORT FILTER over creator identity, so it travels as a
    # body param. A top-level typed target is refused BEFORE any lookup, which is
    # what stops the roster filter from becoming a session-existence oracle: an
    # unknown key, a real session and a foreign session are one answer.
    refusals =
      for verb <- ["toplines", "topline"],
          key <- ["s_real", "s_does_not_exist"] do
        response =
          post_dispatch(opts, %{verb: verb, asUser: "flynn", sessionKey: key, params: %{}})

        assert response.status == 400
        {verb, JSON.decode!(response.resp_body)}
      end

    for verb <- ["toplines", "topline"] do
      bodies = for {^verb, body} <- refusals, do: body
      assert length(bodies) == 2

      assert Enum.uniq(bodies) == [
               %{
                 "error" => %{
                   "code" => "invalid_message",
                   "message" => "#{verb} takes no typed target"
                 }
               }
             ]
    end
  end

  ## Helpers — reads

  defp post_dispatch(opts, body) do
    conn(:post, "/agent/dispatch", JSON.encode!(body))
    |> put_req_header("authorization", "Bearer tbc_toplines")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Tightbeam.Wire.Router.call(Tightbeam.Wire.Router.init(opts))
  end

  defp fresh(db), do: %{db: db}

  defp roster(ctx, params \\ %{}), do: read(ctx, :roster, params)

  defp read(ctx, kind, params, opts \\ []) do
    call = %{
      verb: if(kind == :roster, do: "toplines", else: "topline"),
      origin: "user:flynn",
      principal: Keyword.get(opts, :principal, {:user, "flynn"}),
      session_key: nil,
      params: params,
      now: Keyword.get(opts, :now, @now)
    }

    case kind do
      :roster -> ExecutionMap.roster(ctx.db, call)
      :topline -> ExecutionMap.topline(ctx.db, call)
    end
  end

  defp ids(%{items: items}), do: Enum.map(items, & &1.id)
  defp ids(%{roots: _} = response), do: nested_ids(response)

  defp root_ids(%{roots: roots}), do: Enum.map(roots, & &1.id)

  defp nested_ids(%{roots: roots}), do: Enum.flat_map(roots, &flatten/1)

  defp flatten(node), do: [node.id | Enum.flat_map(node.children, &flatten/1)]

  defp node(%{items: items}, id), do: Enum.find(items, &(&1.id == id))

  defp node(%{roots: _} = response, id) do
    response.roots |> Enum.flat_map(&flat_nodes/1) |> Enum.find(&(&1.id == id))
  end

  defp flat_nodes(node), do: [node | Enum.flat_map(node.children, &flat_nodes/1)]

  defp children(response, id), do: Enum.map(node(response, id).children, & &1.id)

  defp parent(response, id), do: node(response, id).parent

  ## Helpers — the twin-world fixture

  # ONE seeding function, called against both databases. With `invisible: false`
  # the rows this caller may not see — and their assignments, attests, wakes,
  # holds, markers and turn attributions — are never written at all, which is
  # what makes the comparison a twin-WORLD proof rather than an id sweep.
  defp seed_twin_world(db, invisible: invisible?) do
    session!(db, "s_mine", "flynn")
    session!(db, "s_lane", "flynn")
    if invisible?, do: session!(db, "s_theirs", "kay")

    item!(db, "wi_anchor", created_at: at(1))
    turn!(db, 200, "s_lane", job_ref: "wi_anchor")
    item!(db, "wi_descendant", created_at: at(2), context_known: 1, created_in_turn_seq: 200)
    assignment!(db, "asg_visible", work_item_id: "wi_anchor", holder: "s_mine")
    attest!(db, "att_visible", "asg_visible", by_session: "s_mine", ts: 3_000_000)
    assignment!(db, "asg_none", work_item_id: nil, reviews: nil, holder: "s_mine")

    # A conversational-turn child, the block the invisible-parent case must be
    # indistinguishable from.
    turn!(db, 201, "s_lane", job_ref: nil, assignment_id: nil)

    item!(db, "wi_conversational_child",
      created_at: at(3),
      context_known: 1,
      created_in_turn_seq: 201
    )

    if invisible? do
      item!(db, "wi_theirs", owner: "kay", created_at: at(4))
      assignment!(db, "asg_theirs", work_item_id: "wi_theirs", holder: "s_theirs")
      attest!(db, "att_theirs", "asg_theirs", by_session: "s_theirs", ts: 3_500_000)
      wake!(db, "wk_theirs", "s_theirs", state: "pending", work_item_id: "wi_theirs")
      marker!(db, "s_theirs", "sub_theirs", assignment_id: "asg_theirs")
      # A turn ATTRIBUTED to the invisible item and its assignment.
      turn!(db, 202, "s_theirs",
        job_ref: "wi_theirs",
        assignment_id: "asg_theirs",
        ended_at: 3_600_000,
        model: "m-theirs",
        harness: "codex"
      )

      # The invisible PARENT: turn 203 names it, so the visible child's edge
      # candidate is authorization-filtered away.
      turn!(db, 203, "s_lane", job_ref: "wi_theirs")
    else
      # The twin has the same lane turn WITHOUT the attribution the caller may
      # not see — "turn attributions physically absent".
      turn!(db, 203, "s_lane", job_ref: nil)
    end

    item!(db, "wi_hidden_parent_child",
      created_at: at(5),
      context_known: 1,
      created_in_turn_seq: 203
    )
  end

  ## Helpers — direct row fixtures

  defp item!(db, id, opts \\ []) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO work_items
          (id, title, specRefName, specRefSha256, isBug, ownerUserId, state, failReason,
           routingWakeId, createdByUser, createdBySession, createdInTurnSeq,
           createdContextKnown, createdAt)
        VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
        """,
        [
          id,
          "Item #{id}",
          Keyword.get(opts, :spec_ref_name),
          Keyword.get(opts, :spec_ref_sha256),
          Keyword.get(opts, :owner, "flynn"),
          Keyword.get(opts, :state, "open"),
          Keyword.get(opts, :fail_reason),
          Keyword.get(opts, :routing_wake_id),
          if(Keyword.has_key?(opts, :created_by_session),
            do: nil,
            else: Keyword.get(opts, :created_by_user, "flynn")
          ),
          Keyword.get(opts, :created_by_session),
          Keyword.get(opts, :created_in_turn_seq),
          Keyword.get(opts, :context_known, 0),
          Keyword.get(opts, :created_at, @default_created)
        ]
      )

    id
  end

  defp assignment!(db, id, opts) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO assignments
          (id, subject, holderKey, openedByUser, openedAt, state, workItemId, reviewsAssignmentId)
        VALUES (?1, ?2, ?3, 'flynn', ?4, 'open', ?5, ?6)
        """,
        [
          id,
          "subject #{id}",
          Keyword.get(opts, :holder, "s_holder"),
          Keyword.get(opts, :opened_at, @default_created),
          Keyword.get(opts, :work_item_id),
          Keyword.get(opts, :reviews)
        ]
      )

    id
  end

  defp close!(db, id, outcome, closing_attest_id) do
    {:ok, _} =
      DB.query(
        db,
        """
        UPDATE assignments
        SET state = 'closed', outcome = ?2, closedAt = ?3, closedByUser = 'flynn',
            closingAttestId = ?4
        WHERE id = ?1
        """,
        [id, outcome, @default_created + 1, closing_attest_id]
      )

    :ok
  end

  defp attest!(db, id, assignment_id, opts) do
    kind = Keyword.get(opts, :kind, "completion")

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO attests (id, assignmentId, kind, verdictKind, bySession, byUser, commitRefs, ts)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """,
        [
          id,
          assignment_id,
          kind,
          Keyword.get(opts, :verdict_kind),
          Keyword.get(opts, :by_session),
          Keyword.get(opts, :by_user),
          case Keyword.get(opts, :commit_refs) do
            nil -> nil
            refs -> JSON.encode!(refs)
          end,
          Keyword.get(opts, :ts, @default_created)
        ]
      )

    id
  end

  defp turn!(db, seq, session_key, opts) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO turns
          (seq, sessionKey, messageId, origin, prompt, assignmentId, jobRef, model,
           thinkingLevel, modelContext, harness, status, createdAt, endedAt)
        VALUES (?1, ?2, ?3, 'user:flynn', 'p', ?4, ?5, ?6, ?11, ?12, ?7, ?8, ?9, ?10)
        """,
        [
          seq,
          session_key,
          "msg_#{seq}",
          Keyword.get(opts, :assignment_id),
          Keyword.get(opts, :job_ref),
          Keyword.get(opts, :model),
          Keyword.get(opts, :harness),
          Keyword.get(opts, :status, "delivered"),
          Keyword.get(opts, :created_at, @default_created),
          Keyword.get(opts, :ended_at),
          Keyword.get(opts, :effort),
          Keyword.get(opts, :context)
        ]
      )

    seq
  end

  defp wake!(db, wake_id, session_key, opts) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO wakes
          (wakeId, sessionKey, origin, prompt, consumer, dueAt, state, createdAt, work_item_id)
        VALUES (?1, ?2, 'user:flynn', 'p', ?3, ?4, ?5, ?4, ?6)
        """,
        [
          wake_id,
          session_key,
          Keyword.get(opts, :consumer, "prompt"),
          @default_created,
          Keyword.get(opts, :state, "pending"),
          Keyword.get(opts, :work_item_id)
        ]
      )

    wake_id
  end

  defp marker!(db, principal, subagent_ref, opts) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO subagent_markers
          (kind, principal, subagentRef, sourceEventRef, harness, at, assignmentId)
        VALUES ('subagent_start', ?1, ?2, ?3, 'claude', ?4, ?5)
        """,
        [
          principal,
          subagent_ref,
          "evt_#{subagent_ref}",
          @default_created,
          Keyword.get(opts, :assignment_id)
        ]
      )

    :ok
  end

  defp session!(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })

    key
  end

  defp dispose(db, verb, id) do
    WorkItems.__handle__(db, verb, %{
      verb: verb,
      principal: {:user, "flynn"},
      origin: "user:flynn",
      session_key: nil,
      params: %{work_item_id: id}
    })
  end

  # A disposition event with no disposition: the reader must key on the event's
  # own toState, and only a directly staged row can put a non-matching
  # transition after the matching one.
  defp disposition!(db, item_id, from: from_state, to: to_state) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        CausalEvents.append_in_txn(txn, %{
          kind: "disposition_transition",
          job_ref: item_id,
          detail: %{workItemId: item_id, fromState: from_state, toState: to_state}
        })
      end)

    :ok
  end

  defp disposition_at(db, item_id, to_state) do
    db
    |> CausalEvents.for_job(item_id, [])
    |> Enum.filter(&(&1.kind == "disposition_transition" and &1.detail["toState"] == to_state))
    |> List.last()
    |> Map.fetch!(:at)
  end

  # Every table's full contents, so "read-only in its own effects" is asserted
  # over the whole database rather than over a hand-picked list.
  defp snapshot(db) do
    {:ok, tables} =
      DB.query(
        db,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
      )

    Map.new(tables, fn [table] ->
      {:ok, rows} = DB.query(db, "SELECT * FROM #{table}")
      {table, Enum.sort(rows)}
    end)
  end
end
