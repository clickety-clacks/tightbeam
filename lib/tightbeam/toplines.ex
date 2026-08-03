defmodule Tightbeam.Toplines do
  @moduledoc """
  The work telemetry the substrate already knows (spec topline-map-v1). A pure
  READ over durable work, assignment, turn, attest, wake, adjudication and
  creation-context rows: no table, no column, no migration, no emission.

  Four surfaces, one telemetry builder: the roster, the caller-visible causal
  forest (`--tree`), a subtree anchored on one item (`--under`), and explicit
  assignment-set selection (`--assignments`).

  Three things here are deliberately precise, and a plausible-looking
  implementation gets each one wrong:

  1. MEMBERSHIP HAS EXACTLY ONE DEFINITION —
     `{a : resolved_work_item_id(a) == item}`. `resolve_all/1` computes that
     function in bulk (own non-null pin wins, else follow `reviewsAssignmentId`,
     else NONE), so every consumer — assignment counts, jobs, attests,
     closing attests, decision requests, the turn union, marker fan-out and
     parent-edge derivation — reads the SAME map. The recursive
     `work-item-trace` CTE is NOT reused: it seeds on `workItemId` and unions
     the reviewed chain, which attributes a legacy conflicted review to two
     items at once.

  2. THE PARENT BLOCK IS FOUR-VALUED AND NONE OF THE VALUES MAY OVERCLAIM. The
     creation stamp records CONCURRENCY, not proven causality (core-causality
     C1), so the response carries a constant `edge_basis` and one of
     `linked | from_turn | no_turn_observed | unrecorded`. `no_turn_observed`
     is the substrate saying it LOOKED and nothing was running — a signal, not
     a `root: true` classification — and `unrecorded` is a pre-C1 row whose
     parent is unknowable. Both carry `item: nil` so a consumer reading only
     `item` cannot mistake silence for knowledge. No confidence scores.

  3. AUTHORIZATION IS BY OMISSION, and the bar is twin-world byte identity:
     the complete response with invisible rows present must be byte-identical
     to the response against a database where those rows are absent. That is
     why candidate parent edges are authorization-filtered BEFORE traversal
     (an invisible parent is indistinguishable from a conversational turn),
     why the traversal order is over visible nodes only, and why holds and
     pending wakes are selected by the current holder's SESSION KEY rather
     than through any item-attributed carrier.
  """

  alias Tightbeam.{CausalEvents, DB}

  @edge_basis "concurrent_turn"
  @coverage_basis "conservative_shared"
  @terminal_states ~w(closed failed iceboxed)
  @open_hold_states ~w(claimed notified)

  @doc """
  The `toplines` verb: the roster with full telemetry, or the caller-visible
  causal forest when `--tree` is set.
  """
  @spec roster(DB.server(), map()) :: map()
  def roster(db, call) do
    world = world(db, call)
    appearing = appearing(world, call.params)

    if truthy?(call.params[:tree]) do
      forest(world, appearing)
    else
      Map.put(envelope(world), :items, Enum.map(appearing, &node(world, &1)))
    end
  end

  @doc """
  The `topline` verb: `--under <id>` (a causal subtree) or `--assignments
  <id,...>` (explicit assignment-set selection). Exactly one is required.
  """
  @spec topline(DB.server(), map()) :: map()
  def topline(db, call) do
    params = call.params

    cond do
      is_binary(params[:under]) and params[:under] != "" and
          not is_nil(params[:assignments]) ->
        invalid("--under and --assignments are mutually exclusive")

      is_binary(params[:under]) and params[:under] != "" ->
        under(world(db, call), params, params[:under])

      not is_nil(params[:assignments]) ->
        assignment_selection(world(db, call), params[:assignments])

      true ->
        invalid("topline requires --under <workItemId> or --assignments <id,...>")
    end
  end

  ## --under — the anchor plus its transitive visible linked descendants

  defp under(world, params, anchor) do
    # Unknown and invisible anchors are the same answer: the candidate set is
    # built from the VISIBLE nodes only, so an anchor absent from it never
    # reaches a lookup that could distinguish the two.
    if Map.has_key?(world.items_by_id, anchor) do
      candidates = descendants(world, anchor)

      world
      |> Map.put(:items, Enum.filter(world.items, &MapSet.member?(candidates, &1.id)))
      |> forest_of(params)
    else
      not_found("work item not found")
    end
  end

  defp forest_of(world, params), do: forest(world, appearing(world, params))

  # Children-of relation over the retained (post-cycle-drop) linked edges. A
  # cycle among the descendants terminates because the dropped edge is already
  # absent from `world.linked`.
  defp descendants(world, anchor) do
    children = children_index(world)
    collect([anchor], children, MapSet.new([anchor]))
  end

  defp collect([], _children, seen), do: seen

  defp collect([id | rest], children, seen) do
    next = children |> Map.get(id, []) |> Enum.reject(&MapSet.member?(seen, &1))
    collect(rest ++ next, children, Enum.reduce(next, seen, &MapSet.put(&2, &1)))
  end

  defp children_index(world) do
    Enum.group_by(world.linked, fn {_child, parent} -> parent end, fn {child, _parent} ->
      child
    end)
  end

  ## --assignments — explicit selection, all-or-nothing on unknown/invisible

  defp assignment_selection(world, raw) do
    case selected_ids(raw) do
      [] ->
        invalid("--assignments requires at least one assignment id")

      ids ->
        case classify(world, ids, [], []) do
          :not_found ->
            # An unknown id and an id this caller may not see are ONE answer;
            # a visible NONE id is substrate truth and uses `no_item`.
            not_found("assignment not found")

          {items, no_item} ->
            selected =
              world.items
              |> Enum.filter(&MapSet.member?(MapSet.new(items), &1.id))
              |> Enum.map(&node(world, &1))

            envelope(world)
            |> Map.put(:items, selected)
            |> Map.put(:no_item, Enum.sort(no_item))
        end
    end
  end

  defp classify(_world, [], items, no_item), do: {Enum.uniq(items), Enum.uniq(no_item)}

  defp classify(world, [id | rest], items, no_item) do
    case Map.fetch(world.assignments_by_id, id) do
      :error ->
        :not_found

      {:ok, assignment} ->
        case Map.get(world.resolved, id) do
          nil ->
            if assignment_detail_visible?(world, assignment),
              do: classify(world, rest, items, [id | no_item]),
              else: :not_found

          item_id ->
            if Map.has_key?(world.items_by_id, item_id),
              do: classify(world, rest, [item_id | items], no_item),
              else: :not_found
        end
    end
  end

  # The assignment-detail rule for a NONE assignment: admin, or a caller who
  # owns the assignment's holder session.
  defp assignment_detail_visible?(%{caller: nil}, _assignment), do: false
  defp assignment_detail_visible?(%{caller: %{admin: true}}, _assignment), do: true

  defp assignment_detail_visible?(world, assignment) do
    Map.get(world.session_owners, assignment.holder_key) == world.caller.owner
  end

  # Duplicate ids collapse; blank entries are not ids. `--assignments` arrives
  # from the CLI as a list of strings.
  defp selected_ids(raw) when is_list(raw) do
    raw |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()
  end

  defp selected_ids(raw) when is_binary(raw) do
    raw |> String.split(",") |> Enum.map(&String.trim/1) |> selected_ids()
  end

  defp selected_ids(_raw), do: []

  ## Forest assembly — nesting exists only among APPEARING nodes

  defp forest(world, appearing) do
    appearing_ids = MapSet.new(appearing, & &1.id)

    nodes = Map.new(appearing, &{&1.id, node(world, &1)})

    # A child whose linked parent is caller-visible but filter-excluded appears
    # top-level and KEEPS `parent: {status: "linked", item: <parent-id>}`. No
    # placeholder is emitted and the excluded parent is never pulled in.
    children =
      appearing
      |> Enum.filter(fn item ->
        parent = Map.get(world.linked, item.id)
        not is_nil(parent) and MapSet.member?(appearing_ids, parent)
      end)
      |> Enum.group_by(&Map.get(world.linked, &1.id))

    roots =
      Enum.reject(appearing, fn item ->
        parent = Map.get(world.linked, item.id)
        not is_nil(parent) and MapSet.member?(appearing_ids, parent)
      end)

    Map.put(envelope(world), :roots, Enum.map(roots, &nest(&1, nodes, children)))
  end

  defp nest(item, nodes, children) do
    kids = children |> Map.get(item.id, []) |> Enum.map(&nest(&1, nodes, children))
    Map.put(Map.fetch!(nodes, item.id), :children, kids)
  end

  defp envelope(world) do
    %{
      edge_basis: @edge_basis,
      coverage: %{attribution_cutoff: world.cutoff, basis: @coverage_basis}
    }
  end

  ## Roster filters — they select which authorized nodes APPEAR, nothing else

  defp appearing(world, params) do
    Enum.filter(world.items, fn item ->
      origin_match?(item, params[:origin]) and
        owner_match?(item, params[:owner]) and
        state_match?(item, params[:state]) and
        spec_match?(item, params[:spec], params[:spec_sha]) and
        session_match?(item, params[:session]) and
        quiet_match?(world, item, params[:quiet_over])
    end)
  end

  defp origin_match?(item, "user"), do: principal(item) == "user"
  defp origin_match?(item, "session"), do: principal(item) == "session"
  defp origin_match?(_item, _all), do: true

  defp owner_match?(_item, nil), do: true
  defp owner_match?(item, owner) when is_binary(owner), do: item.owner_user_id == owner
  defp owner_match?(_item, _owner), do: true

  defp state_match?(_item, nil), do: true
  defp state_match?(item, state) when is_binary(state), do: item.state == state
  defp state_match?(_item, _state), do: true

  defp spec_match?(_item, nil, _sha), do: true

  defp spec_match?(item, name, sha) when is_binary(name) do
    item.spec_ref_name == name and (is_nil(sha) or item.spec_ref_sha256 == sha)
  end

  defp spec_match?(_item, _name, _sha), do: true

  defp session_match?(_item, nil), do: true

  defp session_match?(item, session) when is_binary(session),
    do: item.created_by_session == session

  defp session_match?(_item, _session), do: true

  # `--quiet-over` is a compound predicate, not a clock comparison: an item with
  # a running turn or a pending prompt wake on a current holder is NOT quiet
  # however old its last progress event is.
  defp quiet_match?(_world, _item, nil), do: true

  defp quiet_match?(world, item, bound) when is_number(bound) do
    telemetry = node(world, item)

    telemetry.since_progress_ms > bound and telemetry.active.running_turn == false and
      telemetry.active.pending_session_wake == false
  end

  defp quiet_match?(_world, _item, _bound), do: true

  ## Per-node telemetry

  defp node(world, item) do
    set = Map.get(world.by_item, item.id, [])
    union = turn_union(world, item.id, set)
    holders = current_holders(world, set)
    pre_cutoff? = item.created_at < world.cutoff

    %{
      id: item.id,
      title: item.title,
      spec_ref_name: item.spec_ref_name,
      spec_ref_sha256: item.spec_ref_sha256,
      state: item.state,
      fail_reason: item.fail_reason,
      bracket1_armed: not is_nil(item.routing_wake_id),
      origin: %{principal: principal(item), created_by: created_by(item)},
      creation_context: %{recorded: item.context_known, turn_seq: item.created_in_turn_seq},
      parent: Map.fetch!(world.parents, item.id),
      finished_at: finished_at(world, item),
      assignments: assignment_counts(world, set),
      jobs: jobs(world, set),
      attests: attests(world, set),
      started_at: started_at(world, set),
      closing_attests: closing_attests(world, set),
      open_decision_requests: open_decision_requests(world, set),
      # COVERAGE: turn attribution, mind stamps and marker attribution shipped
      # as nullable ALTERs with no per-row stamp, so for an item older than the
      # one conservative shared epoch a zero here would be a claim the rows
      # cannot support. Absence is UNKNOWN, so it reports null, never 0.
      turns:
        if(pre_cutoff?,
          do: %{total: nil, last_ended_at: nil},
          else: %{total: length(union), last_ended_at: last_ended_at(union)}
        ),
      minds: unless(pre_cutoff?, do: minds(union)),
      fan_out: unless(pre_cutoff?, do: fan_out(world, set)),
      # THE ONE RESIDUAL OVERCLAIM in this response, and a considered limit
      # rather than an oversight: `running_turn` stays BOOLEAN for a pre-cutoff
      # item, so an old item whose turns were never attributed reports `false` on
      # absent evidence. The coverage null rule is scoped to COUNTS, and
      # `--quiet-over` is defined against `running_turn = false` — nulling it here
      # would silently drop every pre-cutoff item out of `--quiet-over`, which is
      # the worse failure. `pending_session_wake` and `holds` carry no such caveat:
      # both are session-keyed through durable assignment columns.
      active: %{
        running_turn: Enum.any?(union, &(&1.status == "running")),
        pending_session_wake: pending_session_wake?(world, holders)
      },
      holds: holds(world, holders),
      since_progress_ms: world.now - anchor(world, item, set, union)
    }
  end

  defp principal(%{created_by_user: user}) when is_binary(user), do: "user"
  defp principal(_item), do: "session"

  defp created_by(%{created_by_user: user}) when is_binary(user), do: user
  defp created_by(%{created_by_session: session}), do: session

  # The timestamp of the LATEST disposition_transition whose `toState` equals the
  # item's CURRENT terminal state. Null for an open item even with prior
  # transitions, and null for a terminal item with no matching event.
  defp finished_at(_world, %{state: state}) when state not in @terminal_states, do: nil

  defp finished_at(world, item) do
    world.dispositions
    |> Map.get(item.id, [])
    |> Enum.filter(&(&1.to_state == item.state))
    |> Enum.max_by(& &1.seq, fn -> nil end)
    |> then(fn
      nil -> nil
      event -> event.at
    end)
  end

  defp assignment_counts(world, set) do
    rows = rows_for(world.assignments_by_id, set)
    closed = Enum.filter(rows, &(&1.state == "closed"))

    %{
      open: Enum.count(rows, &(&1.state == "open")),
      closed: length(closed),
      by_outcome: %{
        completed: Enum.count(closed, &(&1.outcome == "completed")),
        surrendered: Enum.count(closed, &(&1.outcome == "surrendered")),
        revoked: Enum.count(closed, &(&1.outcome == "revoked"))
      }
    }
  end

  # EVER held, closed assignments included — a history count, not a
  # current-holder count.
  defp jobs(world, set) do
    world.assignments_by_id
    |> rows_for(set)
    |> Enum.map(& &1.holder_key)
    |> Enum.uniq()
    |> length()
  end

  # Verdict slugs are shape-validated only; there is no durable
  # approved/rejected taxonomy, so they are reported as stored. Collapsing them
  # would invent a classification the rows do not carry.
  defp attests(world, set) do
    rows = Enum.flat_map(set, &Map.get(world.attests_by_assignment, &1, []))

    %{
      total: length(rows),
      by_kind: tally(rows, & &1.kind),
      by_verdict_kind: rows |> Enum.reject(&is_nil(&1.verdict_kind)) |> tally(& &1.verdict_kind)
    }
  end

  defp started_at(world, set) do
    world.assignments_by_id
    |> rows_for(set)
    |> Enum.map(& &1.opened_at)
    |> Enum.min(fn -> nil end)
  end

  # Completed and surrendered closes REQUIRE a non-null closingAttestId; revoked
  # requires it to be null. A revoked close is therefore represented only in
  # `assignments.by_outcome.revoked`.
  defp closing_attests(world, set) do
    world.assignments_by_id
    |> rows_for(set)
    |> Enum.filter(&(&1.outcome in ["completed", "surrendered"] and &1.closing_attest_id))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn assignment ->
      %{
        assignmentId: assignment.id,
        attestId: assignment.closing_attest_id,
        commitRefs: Map.get(world.commit_refs, assignment.closing_attest_id)
      }
    end)
  end

  defp open_decision_requests(world, set) do
    Enum.reduce(set, 0, &(&2 + Map.get(world.open_requests, &1, 0)))
  end

  ## The turn union — either attribution arm alone undercounts

  # A bracket nag may carry only `jobRef`; a review turn may carry only
  # `assignmentId`. `seq` is the primary key, so uniq_by/2 deduping a turn that
  # carries BOTH keys is exact.
  defp turn_union(world, item_id, set) do
    (Map.get(world.turns_by_job_ref, item_id, []) ++
       Enum.flat_map(set, &Map.get(world.turns_by_assignment, &1, [])))
    |> Enum.uniq_by(& &1.seq)
  end

  defp last_ended_at(union) do
    union |> Enum.map(& &1.ended_at) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
  end

  # The mind is stamped when a queued turn is CLAIMED, so an unclaimed turn has
  # no mind: a fully-null pair is the absence of a stamp, not a mind.
  defp minds(union) do
    union
    |> Enum.map(&%{model: &1.model, context: &1.context, effort: &1.effort, harness: &1.harness})
    |> Enum.reject(&(is_nil(&1.model) and is_nil(&1.harness)))
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.model || "", &1.context || "", &1.effort || "", &1.harness || ""})
  end

  defp fan_out(world, set) do
    set
    |> Enum.flat_map(&Map.get(world.markers_by_assignment, &1, []))
    |> Enum.uniq()
    |> length()
  end

  ## Current-holder state — a stale ex-holder marks nothing active

  # A holder is CURRENT only while it owns an OPEN resolved assignment.
  defp current_holders(world, set) do
    world.assignments_by_id
    |> rows_for(set)
    |> Enum.filter(&(&1.state == "open"))
    |> Enum.map(& &1.holder_key)
    |> Enum.uniq()
  end

  # Supervision gates the CURRENT open holder at turn end, and wake suppression
  # is session-keyed across all pending prompt wakes — so this is not the set of
  # item-attributed wakes.
  defp pending_session_wake?(world, holders) do
    Enum.any?(holders, &MapSet.member?(world.pending_wake_sessions, &1))
  end

  defp holds(world, holders) do
    holders
    |> Enum.flat_map(&Map.get(world.holds_by_session, &1, []))
    |> Enum.sort_by(&{&1.sessionKey, &1.condition})
    |> Enum.map(&Map.take(&1, [:episodeId, :cause, :sessionKey]))
  end

  ## The progress clock

  # A scheduled wake or a fired prod is NOT progress. The anchor is the maximum
  # of every known progress timestamp and the coverage baseline, so an older
  # item's clock can never claim quiet time from before attribution was
  # knowable. Pre-epoch attests are not discarded — filing one resets the clock,
  # subject to the same floor.
  defp anchor(world, item, set, union) do
    ended = union |> Enum.map(& &1.ended_at) |> Enum.reject(&is_nil/1)

    attested =
      Enum.flat_map(set, fn id ->
        Enum.map(Map.get(world.attests_by_assignment, id, []), & &1.ts)
      end)

    disposed = world.dispositions |> Map.get(item.id, []) |> Enum.map(& &1.at)

    Enum.max([max(item.created_at, world.cutoff) | ended ++ attested ++ disposed])
  end

  ## Parent derivation — total over missing, legacy and corrupt rows

  # The four statuses are exhaustive and mutually exclusive, and `linked` is the
  # only one that names an item.
  defp parents(items, linked) do
    Map.new(items, fn item ->
      status =
        cond do
          not item.context_known -> %{status: "unrecorded", item: nil}
          is_nil(item.created_in_turn_seq) -> %{status: "no_turn_observed", item: nil}
          parent = Map.get(linked, item.id) -> %{status: "linked", item: parent}
          # `from_turn` absorbs a conversational turn, an assignment resolving to
          # NONE, a missing turn row, an authorization-hidden parent, and a
          # cycle-closing edge that had to be dropped. The status is the
          # load-bearing field; the caller cannot tell these apart, by design.
          true -> %{status: "from_turn", item: nil}
        end

      {item.id, status}
    end)
  end

  # Candidate edges are AUTHORIZATION-FILTERED before traversal: a visible child
  # of an invisible parent is indistinguishable from the conversational-turn
  # case. Appearance filters do not participate — a filter-excluded but visible
  # parent stays nameable in the child's block.
  defp candidate_edges(items, items_by_id, turns_by_seq, resolved) do
    for item <- items,
        item.context_known,
        seq = item.created_in_turn_seq,
        not is_nil(seq),
        turn = Map.get(turns_by_seq, seq),
        candidate = candidate_parent(turn, resolved),
        not is_nil(candidate),
        Map.has_key?(items_by_id, candidate),
        into: %{} do
      {item.id, candidate}
    end
  end

  # 1. the turn's `jobRef` when set — bracket nags and item-attributed turns
  #    carry the work-item id without an assignment;
  # 2. otherwise the turn assignment's RESOLVED item;
  # 3. otherwise no edge.
  defp candidate_parent(nil, _resolved), do: nil
  defp candidate_parent(%{job_ref: job_ref}, _resolved) when is_binary(job_ref), do: job_ref

  defp candidate_parent(%{assignment_id: assignment_id}, resolved) when is_binary(assignment_id),
    do: Map.get(resolved, assignment_id)

  defp candidate_parent(_turn, _resolved), do: nil

  # Traversal in canonical node order with a CURRENT-ANCESTRY visited set. An
  # edge whose target is already on that ancestry is the cycle-closing edge and
  # is dropped — from the traversal AND from the source node's parent block, so
  # a corrupt self-parent yields neither an edge nor a `linked`-to-self.
  #
  # Each node has at most one candidate parent, so the candidate graph is
  # functional: every cycle is simple and disjoint, and dropping the one edge
  # that closes it leaves a forest.
  defp retain_acyclic(items, candidates) do
    {dropped, _settled} =
      Enum.reduce(items, {MapSet.new(), MapSet.new()}, fn item, {dropped, settled} ->
        if MapSet.member?(settled, item.id) do
          {dropped, settled}
        else
          walk(item.id, candidates, dropped, settled, MapSet.new())
        end
      end)

    Map.reject(candidates, fn {child, _parent} -> MapSet.member?(dropped, child) end)
  end

  defp walk(id, candidates, dropped, settled, ancestry) do
    settled = MapSet.put(settled, id)
    ancestry = MapSet.put(ancestry, id)

    case Map.get(candidates, id) do
      nil ->
        {dropped, settled}

      parent ->
        cond do
          MapSet.member?(ancestry, parent) -> {MapSet.put(dropped, id), settled}
          # A chain merging into already-explored territory can close no new
          # cycle: that node's whole upward chain was resolved by an earlier walk.
          MapSet.member?(settled, parent) -> {dropped, settled}
          true -> walk(parent, candidates, dropped, settled, ancestry)
        end
    end
  end

  ## The world — every row this read needs, loaded once

  defp world(db, call) do
    caller = caller(db, Map.get(call, :principal))
    cutoff = CausalEvents.epoch(db)
    items = visible_items(db, caller)
    items_by_id = Map.new(items, &{&1.id, &1})

    assignments = all_assignments(db)
    assignments_by_id = Map.new(assignments, &{&1.id, &1})
    resolved = resolve_all(assignments, assignments_by_id)
    by_item = membership(resolved, items_by_id)

    turns = all_turns(db)
    turns_by_seq = Map.new(turns, &{&1.seq, &1})

    linked = retain_acyclic(items, candidate_edges(items, items_by_id, turns_by_seq, resolved))

    %{
      now: Map.get(call, :now) || System.system_time(:millisecond),
      caller: caller,
      cutoff: cutoff,
      items: items,
      items_by_id: items_by_id,
      assignments_by_id: assignments_by_id,
      resolved: resolved,
      by_item: by_item,
      turns_by_job_ref: index_turns(turns, & &1.job_ref),
      turns_by_assignment: index_turns(turns, & &1.assignment_id),
      linked: linked,
      parents: parents(items, linked),
      attests_by_assignment: attests_by_assignment(db),
      commit_refs: commit_refs(db),
      markers_by_assignment: markers_by_assignment(db),
      open_requests: open_requests(db),
      pending_wake_sessions: pending_wake_sessions(db),
      holds_by_session: holds_by_session(db),
      dispositions: dispositions(db),
      session_owners: session_owners(db)
    }
  end

  # An item node is visible under the existing `work-item-trace` owner-or-admin
  # rule. Invisible nodes are omitted ENTIRELY: no value, total, count, order,
  # marker, id, flag or nesting choice may depend on their existence.
  defp visible_items(_db, nil), do: []

  defp visible_items(db, caller) do
    {sql, params} =
      if caller.admin,
        do: {"", []},
        else: {" WHERE ownerUserId = ?1", [caller.owner]}

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT id, title, ownerUserId, state, failReason, specRefName, specRefSha256,
               routingWakeId, createdByUser, createdBySession, createdInTurnSeq,
               createdContextKnown, createdAt
        FROM work_items#{sql}
        ORDER BY createdAt ASC, id ASC
        """,
        params
      )

    Enum.map(rows, fn [
                        id,
                        title,
                        owner,
                        state,
                        fail_reason,
                        spec_name,
                        spec_sha,
                        routing_wake_id,
                        created_by_user,
                        created_by_session,
                        created_in_turn_seq,
                        context_known,
                        created_at
                      ] ->
      %{
        id: id,
        title: title,
        owner_user_id: owner,
        state: state,
        fail_reason: fail_reason,
        spec_ref_name: spec_name,
        spec_ref_sha256: spec_sha,
        routing_wake_id: routing_wake_id,
        created_by_user: created_by_user,
        created_by_session: created_by_session,
        created_in_turn_seq: created_in_turn_seq,
        context_known: context_known == 1,
        created_at: created_at
      }
    end)
  end

  defp all_assignments(db) do
    {:ok, rows} =
      DB.query(db, """
      SELECT id, workItemId, reviewsAssignmentId, holderKey, state, outcome,
             openedAt, closingAttestId
      FROM assignments
      """)

    Enum.map(rows, fn [id, item_id, reviews, holder, state, outcome, opened, closing] ->
      %{
        id: id,
        work_item_id: item_id,
        reviews_assignment_id: reviews,
        holder_key: holder,
        state: state,
        outcome: outcome,
        opened_at: opened,
        closing_attest_id: closing
      }
    end)
  end

  # THE normative membership function, computed in bulk:
  #
  #   resolved_assignments(item) = {a : resolved_work_item_id(a) == item}
  #
  # An assignment's own non-null `workItemId` WINS; otherwise resolution follows
  # `reviewsAssignmentId`; otherwise NONE. Total and cycle-safe — a memoized nil
  # is correct because entering a cycle at any point traverses it and returns
  # nil.
  defp resolve_all(assignments, by_id) do
    Enum.reduce(assignments, %{}, fn assignment, memo ->
      {value, memo} = resolve(by_id, assignment.id, MapSet.new(), memo)
      Map.put(memo, assignment.id, value)
    end)
  end

  defp resolve(by_id, id, visited, memo) do
    cond do
      Map.has_key?(memo, id) ->
        {Map.fetch!(memo, id), memo}

      MapSet.member?(visited, id) ->
        {nil, memo}

      true ->
        case Map.get(by_id, id) do
          nil ->
            {nil, memo}

          %{work_item_id: item_id} when not is_nil(item_id) ->
            {item_id, Map.put(memo, id, item_id)}

          %{reviews_assignment_id: nil} ->
            {nil, Map.put(memo, id, nil)}

          %{reviews_assignment_id: reviews} ->
            {value, memo} = resolve(by_id, reviews, MapSet.put(visited, id), memo)
            {value, Map.put(memo, id, value)}
        end
    end
  end

  # An assignment resolving to NONE belongs to no item's ordinary telemetry: it
  # is not an item orphan and creates no synthetic item.
  defp membership(resolved, items_by_id) do
    resolved
    |> Enum.filter(fn {_id, item_id} -> Map.has_key?(items_by_id, item_id) end)
    |> Enum.group_by(fn {_id, item_id} -> item_id end, fn {id, _item_id} -> id end)
    |> Map.new(fn {item_id, ids} -> {item_id, Enum.sort(ids)} end)
  end

  defp all_turns(db) do
    {:ok, rows} =
      DB.query(db, """
      SELECT seq, assignmentId, jobRef, status, model, thinkingLevel, modelContext,
             harness, endedAt
      FROM turns
      """)

    Enum.map(rows, fn [
                        seq,
                        assignment_id,
                        job_ref,
                        status,
                        model,
                        effort,
                        model_context,
                        harness,
                        ended_at
                      ] ->
      %{
        seq: seq,
        assignment_id: assignment_id,
        job_ref: job_ref,
        status: status,
        model: model,
        context: model_context,
        effort: effort,
        harness: harness,
        ended_at: ended_at
      }
    end)
  end

  defp attests_by_assignment(db) do
    {:ok, rows} =
      DB.query(db, "SELECT assignmentId, kind, verdictKind, ts FROM attests")

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn {assignment_id, grouped} ->
      {assignment_id,
       Enum.map(grouped, fn [_id, kind, verdict, ts] ->
         %{kind: kind, verdict_kind: verdict, ts: ts}
       end)}
    end)
  end

  defp commit_refs(db) do
    {:ok, rows} = DB.query(db, "SELECT id, commitRefs FROM attests WHERE commitRefs IS NOT NULL")
    Map.new(rows, fn [id, encoded] -> {id, JSON.decode!(encoded)} end)
  end

  # `assignmentId` is the durable marker carrier, stamped from the running parent
  # turn at emission. `subagentRef` is the subagent identity — start and stop are
  # two markers for one fan-out.
  defp markers_by_assignment(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT assignmentId, subagentRef FROM subagent_markers WHERE assignmentId IS NOT NULL"
      )

    rows
    |> Enum.group_by(&hd/1, &List.last/1)
    |> Map.new(fn {assignment_id, refs} -> {assignment_id, Enum.uniq(refs)} end)
  end

  defp open_requests(db) do
    {:ok, rows} =
      DB.query(db, """
      SELECT assignmentId, COUNT(*) FROM decision_requests
      WHERE status = 'open' AND assignmentId IS NOT NULL
      GROUP BY assignmentId
      """)

    Map.new(rows, fn [assignment_id, count] -> {assignment_id, count} end)
  end

  defp pending_wake_sessions(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT DISTINCT sessionKey FROM wakes WHERE state = 'pending' AND consumer = 'prompt'"
      )

    MapSet.new(rows, &hd/1)
  end

  defp holds_by_session(db) do
    states = Enum.map_join(@open_hold_states, ", ", &"'#{&1}'")

    {:ok, rows} =
      DB.query(db, """
      SELECT sessionKey, condition, episodeId, cause
      FROM adjudication_episodes
      WHERE status IN (#{states})
      """)

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn {session_key, grouped} ->
      {session_key,
       Enum.map(grouped, fn [_key, condition, episode_id, cause] ->
         %{sessionKey: session_key, condition: condition, episodeId: episode_id, cause: cause}
       end)}
    end)
  end

  # Dispositions append a `disposition_transition` causal event with
  # `jobRef = item` and exact from/to state. `seq` is commit order, so it — not
  # `at`, which can tie — decides which transition is the latest.
  defp dispositions(db) do
    {:ok, rows} =
      DB.query(db, """
      SELECT jobRef, seq, at, json_extract(detail, '$.toState')
      FROM causal_events
      WHERE kind = 'disposition_transition' AND jobRef IS NOT NULL
      """)

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn {job_ref, grouped} ->
      {job_ref,
       Enum.map(grouped, fn [_ref, seq, at, to_state] ->
         %{seq: seq, at: at, to_state: to_state}
       end)}
    end)
  end

  defp index_turns(turns, key) do
    turns
    |> Enum.reject(&is_nil(key.(&1)))
    |> Enum.group_by(key)
  end

  defp session_owners(db) do
    {:ok, rows} = DB.query(db, "SELECT sessionKey, ownerUserId FROM sessions")
    Map.new(rows, fn [key, owner] -> {key, owner} end)
  end

  ## Caller resolution — the same owner-or-admin shape work-item-trace uses

  defp caller(db, {:user, user}) do
    case DB.query(db, "SELECT isAdmin FROM users WHERE userId = ?1", [user]) do
      {:ok, [[admin]]} -> %{owner: user, admin: admin == 1}
      _ -> nil
    end
  end

  defp caller(db, {:session, session_key}) do
    case DB.query(
           db,
           """
           SELECT u.userId, u.isAdmin
           FROM sessions AS s
           JOIN users AS u ON u.userId = s.ownerUserId
           WHERE s.sessionKey = ?1
           """,
           [session_key]
         ) do
      {:ok, [[owner, admin]]} -> %{owner: owner, admin: admin == 1}
      _ -> nil
    end
  end

  defp caller(_db, _principal), do: nil

  ## Small shared helpers

  defp rows_for(by_id, ids), do: Enum.flat_map(ids, &List.wrap(Map.get(by_id, &1)))

  defp tally(rows, fun) do
    rows |> Enum.group_by(fun) |> Map.new(fn {key, grouped} -> {key, length(grouped)} end)
  end

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp invalid(message), do: %{code: "invalid", message: message}
  defp not_found(message), do: %{code: "not_found", message: message}
end
