defmodule Tightbeam.ExecutionMap do
  @moduledoc """
  The work telemetry the substrate already knows (spec topline-map-v1). A pure
  READ over durable work, assignment, turn, attest, wake and
  creation-context rows. REST reads include the transactional scope revision.

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
     why the traversal order is over visible nodes only, and why pending
     wakes are selected by the current holder's SESSION KEY rather than
     through any item-attributed carrier.
  """

  alias Tightbeam.{CausalEvents, DB, StateResources, StateVisibility}
  alias Tightbeam.DB.Txn
  alias Tightbeam.{Assignments, Wakes}

  @edge_basis "concurrent_turn"
  @coverage_basis "conservative_shared"
  @empty_turn_summary %{total: 0, last_ended_at: nil, running: false, minds: []}
  @rest_work_item_batch_size 256
  @rest_assignment_batch_size 900
  @rest_attest_page_size 2_000
  @terminal_states ~w(closed failed iceboxed)
  @execution_map_node_fields ~w(
    id title specRefName specRefSha256 state failReason bracket1Armed origin
    creationContext parent finishedAt assignments jobs attests startedAt
    closingAttests openDecisionRequests turns minds fanOut active sinceProgressMs
  )
  @doc "The canonical D2 flat ExecutionMap collection query."
  def list_execution_map(db, call) do
    with_rest_snapshot(db, call, fn txn ->
      context = rest_context(txn, call)
      page = rest_flat_page(context, call)
      world = rest_page_world(context, page.items)
      world = load_turn_summaries(world, page.items)

      %{
        items: Enum.map(page.items, &rest_node(world, &1)),
        flags: %{has_more_before: page.has_more_before, has_more_after: page.has_more_after},
        dependency_version:
          Tightbeam.ExecutionMapRevision.token(txn, context.principal, context.cutoff),
        attribution_cutoff: world.cutoff
      }
    end)
  end

  defp rest_flat_page(context, call) do
    if is_nil(call.filters["quietOverMs"]) do
      rest_work_item_page(context.txn, call)
    else
      rest_quiet_page(context, call)
    end
  end

  defp rest_work_item_page(txn, call) do
    filters =
      [
        {"state", "state"},
        {"ownerUserId", "ownerUserId"},
        {"sessionKey", "createdBySession"},
        {"specRefName", "specRefName"},
        {"specRefSha256", "specRefSha256"}
      ]
      |> Enum.reduce(%{}, fn {source, target}, filters ->
        case call.filters[source] do
          nil -> filters
          value -> Map.put(filters, target, [value])
        end
      end)
      |> Map.put("executionMapOrigin", call.filters["origin"])
      |> Map.put("createdBefore", call[:created_before])

    page =
      StateResources.query_work_item_page(
        txn,
        filters,
        %{rest_principal: call.principal, include_work_item_summary: false},
        call.boundary,
        call.limit
      )

    %{
      items: Enum.map(page.rows, &rest_work_item/1),
      has_more_before: page.has_more_before,
      has_more_after: page.has_more_after
    }
  end

  defp rest_quiet_page(context, call) do
    boundary = call.boundary
    limit = call.limit
    bound = call.filters["quietOverMs"]

    if context.now - context.cutoff <= bound do
      %{items: [], has_more_before: false, has_more_after: false}
    else
      backward? = boundary == :latest or match?({:before, _}, boundary)
      matches = context |> rest_quiet_matches(call, boundary, backward?) |> Enum.take(limit + 1)
      extra? = length(matches) > limit
      selected = Enum.take(matches, limit)

      {before?, after?} =
        case boundary do
          :earliest ->
            {false, extra?}

          :latest ->
            {extra?, false}

          {:before, cursor} ->
            {extra?, rest_quiet_exists?(context, call, :after, selected, cursor)}

          {:after, cursor} ->
            {rest_quiet_exists?(context, call, :before, selected, cursor), extra?}
        end

      %{
        items: if(backward?, do: Enum.reverse(selected), else: selected),
        has_more_before: before?,
        has_more_after: after?
      }
    end
  end

  defp rest_quiet_exists?(context, call, direction, selected, fallback) do
    cursor =
      case selected do
        [%{created_at: ts, id: id} | _] -> [ts, id]
        [] -> fallback
      end

    context
    |> rest_quiet_matches(call, {direction, cursor}, direction == :before)
    |> Enum.take(1)
    |> Kernel.!=([])
  end

  defp rest_quiet_matches(context, call, boundary, backward?) do
    bound = call.filters["quietOverMs"]

    Stream.unfold(boundary, fn
      nil ->
        nil

      cursor ->
        page =
          rest_work_item_page(
            context.txn,
            %{
              call
              | boundary: cursor,
                limit: @rest_work_item_batch_size
            }
            |> Map.put(:created_before, context.now - bound)
          )

        items = if backward?, do: Enum.reverse(page.items), else: page.items
        more? = if backward?, do: page.has_more_before, else: page.has_more_after

        next =
          if more? do
            item = List.last(items)
            direction = if backward?, do: :before, else: :after
            {direction, [item.created_at, item.id]}
          end

        {items, next}
    end)
    |> Stream.flat_map(fn items ->
      world = rest_scope(context, items)
      details = rest_details(world, rest_member_ids(world.by_item))
      world = world |> Map.merge(rest_telemetry(details)) |> load_turn_summaries(items)
      Enum.filter(items, &rest_quiet_item?(world, &1, bound))
    end)
  end

  defp rest_quiet_item?(world, item, bound) do
    set = Map.get(world.by_item, item.id, [])
    turns = Map.get(world.turn_summaries, item.id, @empty_turn_summary)

    not turns.running and
      world.now - anchor(world, item, set, turns.last_ended_at) > bound and
      not pending_session_wake?(world, current_holders(world, set))
  end

  @doc "The canonical D2 ExecutionMap forest query."
  def query_execution_map_tree(db, call) do
    with_rest_world(db, call, fn world ->
      {world, items} = execution_map_appearing(world, call.filters)

      execution_map_forest(world, items)
      |> Map.put(:dependency_version, world.dependency_version)
      |> Map.put(:attribution_cutoff, world.cutoff)
    end)
  end

  @doc "The canonical D2 visible ExecutionMap subtree query."
  def query_execution_map_subtree(db, call) do
    with_rest_world(db, call, fn world ->
      case resolve_typed_prefix(call.work_item_id, "wi_", world.items) do
        {:ok, item} ->
          descendants = descendants(world, item.id)
          scoped = Enum.filter(world.items, &MapSet.member?(descendants, &1.id))

          {world, items} = execution_map_appearing(%{world | items: scoped}, call.filters)

          execution_map_forest(world, items)
          |> Map.put(:dependency_version, world.dependency_version)
          |> Map.put(:attribution_cutoff, world.cutoff)

        {:error, :not_found} ->
          {:error, 404, "not_found", nil}

        {:error, :ambiguous, ids} ->
          {:error, 400, "ambiguous_id", ids}
      end
    end)
  end

  @doc "The canonical D2 assignment-set ExecutionMap query."
  def query_execution_map_assignments(db, call) do
    with_rest_world(db, call, fn world ->
      case resolve_assignment_selectors(world, call.assignment_ids, call.principal) do
        {:error, :not_found} ->
          {:error, 404, "not_found", nil}

        {:error, :ambiguous, ids} ->
          {:error, 400, "ambiguous_id", ids}

        {:ok, selected_items, no_item} ->
          selected_items =
            world.items
            |> Enum.filter(&MapSet.member?(MapSet.new(selected_items), &1.id))
            |> Enum.filter(
              &StateVisibility.execution_map_node_visible?(world.txn, &1.id, call.principal)
            )

          world = load_turn_summaries(world, selected_items)

          %{
            items: Enum.map(selected_items, &rest_node(world, &1)),
            no_item: Enum.sort(no_item),
            dependency_version: world.dependency_version,
            attribution_cutoff: world.cutoff
          }
      end
    end)
  end

  @doc "The one closed-world public ExecutionMap node serializer."
  def execution_map_node(node) when is_map(node) do
    encoded =
      Enum.map_join(@execution_map_node_fields, ",", fn field ->
        value = execution_map_wire_value!(node, field)
        JSON.encode!(field) <> ":" <> encode_execution_map_field!(field, value)
      end)

    children = Map.get(node, :children)

    case children do
      nil ->
        "{" <> encoded <> "}"

      values when is_list(values) ->
        "{" <>
          encoded <>
          ",\"children\":[" <>
          Enum.map_join(values, ",", &execution_map_node/1) <> "]}"

      _ ->
        raise ArgumentError, "execution-map children must be an array"
    end
  end

  def execution_map_node(_node), do: raise(ArgumentError, "execution-map node must be an object")

  @doc """
  The `toplines` verb: the roster with full telemetry, or the caller-visible
  causal forest when `--tree` is set.
  """
  @spec roster(DB.server(), map()) :: map()
  def roster(db, call) do
    with :ok <- validate_roster_filters(call.params),
         {:ok, page} <- roster_page_params(call.params) do
      roster_validated(db, call, page)
    end
  end

  defp roster_validated(db, call, page_params) do
    world = world(db, call)
    {world, appearing} = appearing(world, call.params)

    if truthy?(call.params[:tree]) do
      world |> load_turn_summaries(appearing) |> forest(appearing)
    else
      {items, page} = roster_page(appearing, page_params)
      world = load_turn_summaries(world, items)
      response = Map.put(envelope(world), :items, Enum.map(items, &node(world, &1)))
      if page, do: Map.put(response, :page, page), else: response
    end
  end

  defp roster_page_params(%{limit: limit} = params)
       when is_integer(limit) and limit in 1..500 do
    if truthy?(params[:tree]) do
      invalid("--limit is supported only for the flat execution map")
    else
      case params[:after] do
        nil ->
          {:ok, {:earliest, limit}}

        cursor when is_binary(cursor) ->
          with [timestamp, "wi_" <> suffix = id] when suffix != "" <-
                 String.split(cursor, ":", parts: 2),
               {created_at, ""} <- Integer.parse(timestamp) do
            {:ok, {{:after, [created_at, id]}, limit}}
          else
            _ -> invalid("--after must be an execution-map page cursor")
          end

        _ ->
          invalid("--after must be an execution-map page cursor")
      end
    end
  end

  defp roster_page_params(params) do
    cond do
      Map.has_key?(params, :limit) -> invalid("--limit must be an integer from 1 to 500")
      Map.has_key?(params, :after) -> invalid("--after requires --limit")
      true -> {:ok, nil}
    end
  end

  defp roster_page(items, nil), do: {items, nil}

  defp roster_page(items, {boundary, limit}) do
    page = execution_map_page(items, boundary, limit)

    next_cursor =
      if page.has_more_after do
        item = List.last(page.items)
        "#{item.created_at}:#{item.id}"
      end

    {page.items, %{next_cursor: next_cursor}}
  end

  @doc """
  The `topline` verb: `--under <id>` (a causal subtree) or `--assignments
  <id,...>` (explicit assignment-set selection). Exactly one is required.
  """
  @spec topline(DB.server(), map()) :: map()
  def topline(db, call) do
    case validate_roster_filters(call.params) do
      :ok -> topline_validated(db, call)
      error -> error
    end
  end

  defp topline_validated(db, call) do
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

  defp forest_of(world, params) do
    {world, items} = appearing(world, params)
    world |> load_turn_summaries(items) |> forest(items)
  end

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

            world = load_turn_summaries(world, selected)

            envelope(world)
            |> Map.put(:items, Enum.map(selected, &node(world, &1)))
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

  defp validate_roster_filters(params) do
    cond do
      not is_nil(params[:state]) and params[:state] not in ~w(open iceboxed closed failed) ->
        invalid(
          "bad --state value: #{inspect(params[:state])} (use open, iceboxed, closed, or failed)"
        )

      not is_nil(params[:origin]) and params[:origin] not in ~w(user session all) ->
        invalid("bad --origin value: #{inspect(params[:origin])} (use user, session, or all)")

      not is_nil(params[:quiet_over]) and
          not (is_integer(params[:quiet_over]) and params[:quiet_over] >= 0) ->
        invalid("--quiet-over must be a nonnegative duration in milliseconds")

      not is_nil(params[:spec_sha]) and is_nil(params[:spec]) ->
        invalid("--spec-sha requires --spec <name>")

      true ->
        :ok
    end
  end

  ## Roster filters — they select which authorized nodes APPEAR, nothing else

  defp appearing(world, params) do
    candidates =
      Enum.filter(world.items, fn item ->
        origin_match?(item, params[:origin]) and
          owner_match?(item, params[:owner]) and
          state_match?(item, params[:state]) and
          spec_match?(item, params[:spec], params[:spec_sha]) and
          session_match?(item, params[:session])
      end)

    case params[:quiet_over] do
      nil ->
        {world, candidates}

      bound ->
        world = load_turn_summaries(world, candidates)
        {world, Enum.filter(candidates, &quiet_match?(world, &1, bound))}
    end
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
    turns = turn_summary(world, item.id)
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
      current_coordination:
        set
        |> Enum.map(&Map.fetch!(world.assignments_by_id, &1))
        |> Enum.filter(&(&1.state == "open"))
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn a ->
          %{
            assignment_id: a.id,
            holder_key: a.holder_key,
            current_coordination_parent_ref: a.current_coordination_parent_ref
          }
        end),
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
          else: Map.take(turns, [:total, :last_ended_at])
        ),
      minds: unless(pre_cutoff?, do: turns.minds),
      fan_out: unless(pre_cutoff?, do: fan_out(world, set)),
      # THE ONE RESIDUAL OVERCLAIM in this response, and a considered limit
      # rather than an oversight: `running_turn` stays BOOLEAN for a pre-cutoff
      # item, so an old item whose turns were never attributed reports `false` on
      # absent evidence. The coverage null rule is scoped to COUNTS, and
      # `--quiet-over` is defined against `running_turn = false` — nulling it here
      # would silently drop every pre-cutoff item out of `--quiet-over`, which is
      # the worse failure. `pending_session_wake` carries no such caveat: it is
      # session-keyed through durable assignment columns.
      active: %{
        running_turn: turns.running,
        pending_session_wake: pending_session_wake?(world, holders)
      },
      since_progress_ms: world.now - anchor(world, item, set, turns.last_ended_at)
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

  defp turn_summary(%{turn_summaries: summaries}, id) do
    summary = Map.get(summaries, id, @empty_turn_summary)
    %{summary | minds: sort_minds(Enum.reverse(summary.minds))}
  end

  defp sort_minds(minds) do
    Enum.sort_by(minds, &{&1.model || "", &1.context || "", &1.effort || "", &1.harness || ""})
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

  ## The progress clock

  # A scheduled wake or a fired prod is NOT progress. The anchor is the maximum
  # of every known progress timestamp and the coverage baseline, so an older
  # item's clock can never claim quiet time from before attribution was
  # knowable. Pre-epoch attests are not discarded — filing one resets the clock,
  # subject to the same floor.
  defp anchor(world, item, set, last_ended_at) do
    attested =
      Enum.flat_map(set, fn id ->
        Enum.map(Map.get(world.attests_by_assignment, id, []), & &1.ts)
      end)

    disposed = world.dispositions |> Map.get(item.id, []) |> Enum.map(& &1.at)

    Enum.max([
      max(item.created_at, world.cutoff),
      last_ended_at || item.created_at | attested ++ disposed
    ])
  end

  @doc false
  def work_item_trace_parent_data(items, assignments, turns)
      when is_list(items) and is_list(assignments) and is_list(turns) do
    work_item_trace_parent_data(
      items,
      assignments,
      turns,
      work_item_trace_resolution(items, assignments)
    )
  end

  @doc false
  def work_item_trace_parent_data(items, assignments, turns, resolution)
      when is_list(items) and is_list(assignments) and is_list(turns) and is_map(resolution) do
    turns_by_seq = Map.new(turns, &{&1.seq, &1})
    candidates = candidate_edges(items, resolution.items_by_id, turns_by_seq, resolution.resolved)
    {linked, cycles} = retain_acyclic_with_cycles(items, candidates)

    %{
      resolved: resolution.resolved,
      linked: linked,
      parents: parents(items, linked),
      cycles: cycles
    }
  end

  @doc false
  def work_item_trace_resolution(items, assignments)
      when is_list(items) and is_list(assignments) do
    assignments_by_id = Map.new(assignments, &{&1.id, &1})
    items_by_id = Map.new(items, &{&1.id, &1})

    %{
      items_by_id: items_by_id,
      resolved: resolve_all(assignments, assignments_by_id)
    }
  end

  @doc false
  def work_item_trace_turn_has_visible_link?(turn, resolution) when is_map(resolution),
    do: turn_has_visible_link?(turn, resolution.resolved, resolution.items_by_id)

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

  defp retain_acyclic_with_cycles(items, candidates) do
    linked = retain_acyclic(items, candidates)

    cycles =
      candidates
      |> Enum.reject(fn {child, _parent} -> Map.has_key?(linked, child) end)
      |> Map.new(fn {child, parent} -> {child, cycle_members(child, parent, candidates)} end)

    {linked, cycles}
  end

  defp cycle_members(child, parent, candidates),
    do: cycle_members(child, parent, candidates, MapSet.new([child]))

  defp cycle_members(child, current, _candidates, members) when child == current, do: members

  defp cycle_members(child, current, candidates, members) do
    if MapSet.member?(members, current) do
      members
    else
      cycle_members(
        child,
        Map.fetch!(candidates, current),
        candidates,
        MapSet.put(members, current)
      )
    end
  end

  ## REST D2 query path. Source admission happens before every derived map.

  defp with_rest_world(db, call, fun) do
    with_rest_snapshot(db, call, fn txn -> fun.(rest_world(txn, call)) end)
  end

  defp with_rest_snapshot(db, call, fun) do
    principal = Map.fetch!(call, :principal)

    case DB.read_transaction(db, fn txn ->
           txn = Txn.observe_queries(txn, Map.get(principal, :core_detail_trace))
           fun.(txn)
         end) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp rest_world(txn, call) do
    world = rest_structure(txn, call)
    assignment_ids = rest_member_ids(world.by_item)
    details = rest_details(world, assignment_ids)

    world
    |> Map.merge(rest_telemetry(details))
    |> Map.put(
      :dependency_version,
      Tightbeam.ExecutionMapRevision.token(txn, world.principal, world.cutoff)
    )
  end

  defp rest_context(txn, call) do
    %{
      txn: txn,
      principal: call.principal,
      cutoff: CausalEvents.epoch(txn),
      now: Map.get(call, :now) || System.system_time(:millisecond),
      turn_summaries: %{}
    }
  end

  defp rest_page_world(context, items) do
    world = rest_scope(context, items)
    details = rest_details(world, rest_member_ids(world.by_item))

    world
    |> Map.merge(rest_telemetry(details))
    |> Map.put(:parents, rest_scoped_parents(context, items))
  end

  defp rest_scoped_parents(context, items) do
    result =
      Enum.reduce_while(items, {%{}, %{}}, fn item, {linked, cache} ->
        case rest_cached_candidate(context, item, cache) do
          {nil, cache} ->
            {:cont, {linked, cache}}

          {parent, cache} ->
            case rest_cycle_member?(context, parent, item.id, MapSet.new(), cache) do
              {true, _cache} -> {:halt, :cyclic}
              {false, cache} -> {:cont, {Map.put(linked, item.id, parent.id), cache}}
            end
        end
      end)

    case result do
      :cyclic ->
        # The legacy edge removed from a cycle depends on the earliest
        # visible item that reaches it, including items outside the page.
        context.txn
        |> rest_structure(context)
        |> Map.fetch!(:parents)
        |> Map.take(Enum.map(items, & &1.id))

      {linked, _cache} ->
        parents(items, linked)
    end
  end

  defp rest_cached_candidate(context, item, cache) do
    case Map.fetch(cache, item.id) do
      {:ok, parent} ->
        {parent, cache}

      :error ->
        parent = rest_candidate_parent(context, item)
        {parent, Map.put(cache, item.id, parent)}
    end
  end

  defp rest_cycle_member?(_context, %{id: id}, id, _visited, cache), do: {true, cache}
  defp rest_cycle_member?(_context, nil, _root, _visited, cache), do: {false, cache}

  defp rest_cycle_member?(context, item, root, visited, cache) do
    if MapSet.member?(visited, item.id) do
      {false, cache}
    else
      {parent, cache} = rest_cached_candidate(context, item, cache)
      rest_cycle_member?(context, parent, root, MapSet.put(visited, item.id), cache)
    end
  end

  defp rest_candidate_parent(context, %{context_known: true, created_in_turn_seq: seq} = item)
       when is_integer(seq) do
    turn = Map.get(rest_creation_turns(context.txn, context.principal, [item]), seq)

    id =
      case turn do
        %{job_ref: ref} when is_binary(ref) -> ref
        %{assignment_id: id} when is_binary(id) -> rest_assignment_target(context, id)
        _ -> nil
      end

    if is_binary(id) do
      case StateResources.query_work_item(context.txn, id, %{
             rest_principal: context.principal,
             include_work_item_summary: false
           }) do
        nil -> nil
        row -> rest_work_item(row)
      end
    end
  end

  defp rest_candidate_parent(_context, _item), do: nil

  defp rest_scope(context, items) do
    members =
      rest_scoped_assignments(context.txn, context.principal, Enum.map(items, & &1.id), nil, -1)

    rest_scope(context, items, members)
  end

  defp rest_scope(context, items, members) do
    Map.merge(context, %{
      items: items,
      items_by_id: Map.new(items, &{&1.id, &1}),
      assignments_by_id: Map.new(members, fn {_item_id, row} -> {row.id, row} end),
      by_item: Enum.group_by(members, &elem(&1, 0), fn {_item_id, row} -> row.id end)
    })
  end

  defp rest_structure(txn, call) do
    principal = call.principal

    items =
      StateResources.query_work_item(txn, %{}, %{rest_principal: principal})
      |> Enum.map(&rest_work_item/1)
      |> Enum.sort_by(&{&1.created_at, &1.id})

    items_by_id = Map.new(items, &{&1.id, &1})
    assignments = rest_visible_assignments(txn, principal)
    assignments_by_id = Map.new(assignments, &{&1.id, &1})
    resolved = resolve_all(assignments, assignments_by_id)
    by_item = membership(resolved, items_by_id)
    turns_by_seq = rest_creation_turns(txn, principal, items)
    linked = retain_acyclic(items, candidate_edges(items, items_by_id, turns_by_seq, resolved))

    %{
      txn: txn,
      now: Map.get(call, :now) || System.system_time(:millisecond),
      principal: principal,
      cutoff: CausalEvents.epoch(txn),
      items: items,
      items_by_id: items_by_id,
      assignments_by_id: assignments_by_id,
      resolved: resolved,
      by_item: by_item,
      turn_summaries: %{},
      linked: linked,
      parents: parents(items, linked)
    }
  end

  defp rest_member_ids(by_item) do
    by_item |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.sort()
  end

  defp rest_details(world, assignment_ids) do
    %{txn: txn, principal: principal} = world
    attests = rest_allowed_attests(txn, principal, assignment_ids)

    {pending_wake_sessions, pending_wake_classes_by_session} =
      rest_allowed_pending_wakes(txn, principal, world.assignments_by_id, world.by_item)

    open_requests = rest_allowed_open_requests(txn, principal, assignment_ids)

    markers_by_assignment = rest_allowed_markers(txn, assignment_ids)
    dispositions = rest_allowed_dispositions(txn, world.items_by_id)

    %{
      attests: attests,
      dispositions: dispositions,
      open_requests: open_requests,
      markers_by_assignment: markers_by_assignment,
      pending_wake_sessions: pending_wake_sessions,
      pending_wake_classes_by_session: pending_wake_classes_by_session
    }
  end

  defp rest_telemetry(details) do
    details
    |> Map.take([
      :dispositions,
      :open_requests,
      :markers_by_assignment,
      :pending_wake_sessions,
      :pending_wake_classes_by_session
    ])
    |> Map.put(:attests_by_assignment, Enum.group_by(details.attests, & &1.assignment_id))
    |> Map.put(:commit_refs, Map.new(details.attests, &{&1.id, &1.commit_refs}))
  end

  defp rest_work_item(row) do
    %{
      id: row.id,
      title: row.title,
      owner_user_id: row.owner_user_id,
      state: row.state,
      fail_reason: row.fail_reason,
      spec_ref_name: row.spec_ref_name,
      spec_ref_sha256: row.spec_ref_sha256,
      routing_wake_id: row.routing_wake_id,
      created_by_user: row.created_by_user,
      created_by_session: row.created_by_session,
      created_in_turn_seq: row.created_in_turn_seq,
      context_known: row.created_context_known,
      created_at: row.created_at
    }
  end

  @rest_assignment_visibility """
  (?1 = 1 OR
    (?2 = 'session' AND (a.holderKey = ?3 OR COALESCE(a.currentOpenerSessionKey,a.openedBySession) = ?3)) OR
    (?2 = 'user' AND (wi.ownerUserId = ?3 OR a.openedByUser = ?3)))
  """

  defp rest_assignment_target(context, id) do
    case Txn.q(
           context.txn,
           """
           WITH RECURSIVE chain(id, job, reviews) AS (
             SELECT a.id, a.workItemId, a.reviewsAssignmentId
             FROM assignments AS a
             LEFT JOIN work_items AS wi ON wi.id = a.workItemId
             WHERE a.id = ?4 AND #{@rest_assignment_visibility}
             UNION
             SELECT a.id, a.workItemId, a.reviewsAssignmentId
             FROM chain AS c
             JOIN assignments AS a ON a.id = c.reviews
             LEFT JOIN work_items AS wi ON wi.id = a.workItemId
             WHERE c.job IS NULL AND #{@rest_assignment_visibility}
           )
           SELECT job FROM chain WHERE job IS NOT NULL
           """,
           turn_principal_params(context.principal) ++ [id]
         ) do
      [[job]] -> job
      [] -> nil
    end
  end

  defp rest_scoped_assignments(_txn, _principal, [], _after_id, _limit), do: []

  defp rest_scoped_assignments(txn, principal, item_ids, after_id, limit) do
    Txn.q(
      txn,
      """
      WITH RECURSIVE members(item_id, assignment_id) AS (
        SELECT a.workItemId, a.id
        FROM json_each(?4) AS requested
        CROSS JOIN assignments AS a ON a.workItemId = requested.value
        LEFT JOIN work_items AS wi ON wi.id = a.workItemId
        WHERE #{@rest_assignment_visibility}
        UNION ALL
        SELECT m.item_id, a.id
        FROM members AS m
        JOIN assignments AS a ON a.reviewsAssignmentId = m.assignment_id
        LEFT JOIN work_items AS wi ON wi.id = a.workItemId
        WHERE a.workItemId IS NULL AND #{@rest_assignment_visibility}
      )
      SELECT m.item_id, a.id, a.workItemId, a.reviewsAssignmentId, a.holderKey,
             a.state, a.outcome, a.openedAt, a.closingAttestId, a.closedAt
      FROM members AS m
      JOIN assignments AS a ON a.id = m.assignment_id
      WHERE (?5 IS NULL OR a.id > ?5)
      ORDER BY a.id
      LIMIT ?6
      """,
      turn_principal_params(principal) ++ [JSON.encode!(item_ids), after_id, limit]
    )
    |> Enum.map(fn [item_id | row] ->
      {item_id, row |> rest_assignment_query_row() |> rest_assignment()}
    end)
  end

  defp rest_visible_assignments(txn, principal) do
    {kind, id, is_admin} = detail_principal(principal)

    Txn.q(
      txn,
      """
      SELECT a.id, a.workItemId, a.reviewsAssignmentId, a.holderKey,
             a.state, a.outcome, a.openedAt, a.closingAttestId, a.closedAt
      FROM assignments AS a
      LEFT JOIN work_items AS wi ON wi.id = a.workItemId
      WHERE #{@rest_assignment_visibility}
      ORDER BY a.id
      """,
      [if(is_admin, do: 1, else: 0), kind, id]
    )
    |> Enum.map(&rest_assignment_query_row/1)
    |> Enum.map(&rest_assignment/1)
  end

  defp detail_principal(%{kind: "session", id: id}), do: {"session", id, true}

  defp detail_principal(%{kind: kind, id: id, is_admin: is_admin}),
    do: {kind, id, is_admin}

  defp rest_assignment_query_row([
         id,
         work_item_id,
         reviews_assignment_id,
         holder_key,
         state,
         outcome,
         opened_at,
         closing_attest_id,
         closed_at
       ]) do
    %{
      id: id,
      work_item_id: work_item_id,
      reviews_assignment_id: reviews_assignment_id,
      holder_key: holder_key,
      state: state,
      outcome: outcome,
      opened_at: opened_at,
      closing_attest_id: closing_attest_id,
      closed_at: closed_at
    }
  end

  defp rest_assignment(row) do
    %{
      id: row.id,
      work_item_id: row.work_item_id,
      reviews_assignment_id: row.reviews_assignment_id,
      holder_key: row.holder_key,
      state: row.state,
      outcome: row.outcome,
      opened_at: row.opened_at,
      closing_attest_id: row.closing_attest_id,
      current_coordination_parent_ref: Map.get(row, :current_coordination_parent_ref)
    }
  end

  @rest_turn_visibility """
  (?3 = 1 OR
       ?4 = 'session' OR
       (?4 = 'user' AND s.ownerUserId = ?5))
  AND (
    EXISTS (
      SELECT 1 FROM work_items AS wi
      WHERE wi.id = t.jobRef AND (
        ?3 = 1 OR
        (?4 = 'user' AND wi.ownerUserId = ?5) OR
        ?4 = 'session'
      )
    )
    OR EXISTS (
      SELECT 1
      FROM assignments AS a
      LEFT JOIN work_items AS wi ON wi.id = a.workItemId
      WHERE a.id = t.assignmentId AND (
        ?3 = 1 OR
        ?4 = 'session' OR
        (?4 = 'user' AND (wi.ownerUserId = ?5 OR a.openedByUser = ?5))
      )
    )
  )
  """

  defp rest_creation_turns(txn, principal, items) do
    rows =
      Txn.q(
        txn,
        """
        SELECT t.seq, t.assignmentId, t.jobRef
        FROM turns AS t
        JOIN sessions AS s ON s.sessionKey = t.sessionKey
        WHERE t.seq IN (SELECT value FROM json_each(?1)) AND (#{@rest_turn_visibility})
        """,
        [JSON.encode!(creation_sequences(items)), nil | turn_principal_params(principal)]
      )

    creation_turn_index(rows)
  end

  defp turn_principal_params(principal) do
    {kind, id, is_admin} = detail_principal(principal)
    [if(is_admin, do: 1, else: 0), kind, id]
  end

  defp turn_has_visible_link?(turn, resolved, items_by_id) do
    (is_binary(turn.job_ref) and Map.has_key?(items_by_id, turn.job_ref)) or
      (is_binary(turn.assignment_id) and
         Map.has_key?(items_by_id, Map.get(resolved, turn.assignment_id)))
  end

  defp rest_allowed_attests(_txn, _principal, []), do: []

  defp rest_allowed_attests(txn, principal, assignment_ids) do
    assignment_ids
    |> Enum.sort()
    |> Enum.chunk_every(@rest_assignment_batch_size)
    |> Enum.flat_map(&rest_all_attests_for_assignments(txn, principal, &1, :earliest, []))
    |> Enum.sort_by(&{&1.ts, &1.id})
  end

  defp rest_all_attests_for_assignments(txn, principal, assignment_ids, boundary, acc) do
    page =
      Assignments.list_attests(txn, %{
        filters: %{"assignmentId" => assignment_ids},
        principal: principal,
        boundary: boundary,
        limit: @rest_attest_page_size
      })

    acc = Enum.reduce(page.rows, acc, fn row, rows -> [rest_attest(row) | rows] end)

    if page.has_more_after do
      last = List.last(page.rows)

      rest_all_attests_for_assignments(
        txn,
        principal,
        assignment_ids,
        {:after, [last.ts, last.id]},
        acc
      )
    else
      Enum.reverse(acc)
    end
  end

  defp rest_attest(row) do
    %{
      id: row.id,
      assignment_id: row.assignment_id,
      kind: row.kind,
      verdict_kind: row.verdict_kind,
      ts: row.ts,
      commit_refs: row.commit_refs
    }
  end

  defp rest_allowed_pending_wakes(txn, principal, assignments_by_id, by_item) do
    holders =
      assignments_by_id
      |> rows_for(by_item |> Map.values() |> List.flatten() |> Enum.uniq())
      |> Enum.filter(&(&1.state == "open"))
      |> Enum.map(& &1.holder_key)
      |> Enum.uniq()

    if holders == [] do
      {MapSet.new(), %{}}
    else
      holders
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.chunk_every(@rest_assignment_batch_size)
      |> Enum.flat_map(fn batch ->
        marks = Enum.map_join(batch, ",", fn _ -> "?" end)

        Txn.q(
          txn,
          "SELECT wakeId FROM wakes WHERE state = 'pending' AND consumer = 'prompt' AND sessionKey IN (" <>
            marks <> ") ORDER BY wakeId",
          batch
        )
        |> Enum.map(&hd/1)
      end)
      |> Enum.map(&Wakes.delivery_projection_in_txn(txn, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn wake ->
        wake.state == "pending" and wake.consumer == "prompt" and
          wake.session_key in holders and
          StateVisibility.core_detail_visible?(txn, "wakes", wake, principal)
      end)
      |> then(fn wakes ->
        sessions = MapSet.new(wakes, & &1.session_key)

        classes =
          Enum.reduce(wakes, %{}, fn wake, acc ->
            if is_binary(wake.class) and wake.class != "" do
              update_in(
                acc,
                [Access.key(wake.session_key, %{}), Access.key(wake.class, 0)],
                &(&1 + 1)
              )
            else
              acc
            end
          end)

        {sessions, classes}
      end)
    end
  end

  defp rest_allowed_open_requests(_txn, _principal, []), do: %{}

  defp rest_allowed_open_requests(txn, principal, assignment_ids) do
    rows =
      assignment_ids
      |> Enum.sort()
      |> Enum.chunk_every(@rest_assignment_batch_size)
      |> Enum.flat_map(fn batch ->
        marks = Enum.map_join(batch, ",", fn _ -> "?" end)

        Txn.q(
          txn,
          "SELECT id FROM decision_requests WHERE status = 'open' AND kind IN ('statute','effort') AND assignmentId IN (" <>
            marks <> ") ORDER BY id",
          batch
        )
        |> Enum.map(&hd/1)
      end)
      |> Enum.map(&StateResources.query_decision_request_in_txn(txn, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn wrapper ->
        row = wrapper["item"] || wrapper[:item]

        Map.get(row, :status) == "open" and Map.get(row, :kind) in ["statute", "effort"] and
          StateVisibility.core_detail_visible?(txn, "decision requests", row, principal)
      end)

    Enum.frequencies_by(rows, fn wrapper ->
      row = wrapper["item"] || wrapper[:item]
      Map.get(row, :assignment_id)
    end)
  end

  defp rest_allowed_markers(_txn, []), do: %{}

  defp rest_allowed_markers(txn, assignment_ids) do
    rows =
      assignment_ids
      |> Enum.sort()
      |> Enum.chunk_every(@rest_assignment_batch_size)
      |> Enum.flat_map(fn batch ->
        marks = Enum.map_join(batch, ",", fn _ -> "?" end)

        Txn.q(
          txn,
          "SELECT id, assignmentId, subagentRef FROM subagent_markers WHERE assignmentId IN (" <>
            marks <> ") ORDER BY id",
          batch
        )
        |> Enum.map(fn [id, assignment_id, ref] ->
          %{id: id, assignment_id: assignment_id, subagent_ref: ref}
        end)
      end)

    rows
    |> Enum.group_by(& &1.assignment_id, & &1.subagent_ref)
    |> Map.new(fn {assignment_id, refs} -> {assignment_id, Enum.uniq(refs)} end)
  end

  defp rest_allowed_dispositions(_txn, items_by_id) when map_size(items_by_id) == 0,
    do: %{}

  defp rest_allowed_dispositions(txn, items_by_id) do
    rows =
      items_by_id
      |> Map.keys()
      |> Enum.sort()
      |> Enum.chunk_every(@rest_assignment_batch_size)
      |> Enum.flat_map(fn ids ->
        marks = Enum.map_join(ids, ",", fn _ -> "?" end)

        Txn.q(
          txn,
          "SELECT jobRef, seq, at, json_extract(detail, '$.toState') FROM causal_events " <>
            "WHERE kind = 'disposition_transition' AND jobRef IN (" <> marks <> ") ORDER BY seq",
          ids
        )
        |> Enum.map(fn [job_ref, seq, at, to_state] ->
          %{job_ref: job_ref, seq: seq, at: at, to_state: to_state}
        end)
      end)

    Enum.group_by(rows, & &1.job_ref)
  end

  defp execution_map_appearing(world, filters) do
    items =
      Enum.filter(world.items, fn item ->
        execution_map_origin_match?(item, Map.get(filters, "origin")) and
          execution_map_exact_match?(item.owner_user_id, Map.get(filters, "ownerUserId")) and
          execution_map_exact_match?(item.state, Map.get(filters, "state")) and
          execution_map_spec_match?(item, filters) and
          execution_map_exact_match?(item.created_by_session, Map.get(filters, "sessionKey"))
      end)

    case Map.get(filters, "quietOverMs") do
      nil ->
        {world, items}

      bound ->
        world = load_turn_summaries(world, items)
        {world, Enum.filter(items, &execution_map_quiet_match?(world, &1, bound))}
    end
  end

  defp execution_map_origin_match?(_item, nil), do: true
  defp execution_map_origin_match?(_item, "all"), do: true
  defp execution_map_origin_match?(item, "user"), do: principal(item) == "user"
  defp execution_map_origin_match?(item, "session"), do: principal(item) == "session"

  defp execution_map_exact_match?(_value, nil), do: true
  defp execution_map_exact_match?(value, expected), do: value == expected

  defp execution_map_spec_match?(item, filters) do
    name = Map.get(filters, "specRefName")
    sha = Map.get(filters, "specRefSha256")

    (is_nil(name) or item.spec_ref_name == name) and
      (is_nil(sha) or item.spec_ref_sha256 == sha)
  end

  defp execution_map_quiet_match?(_world, _item, nil), do: true

  defp execution_map_quiet_match?(world, item, bound) when is_integer(bound) do
    telemetry = rest_node(world, item)

    telemetry.since_progress_ms > bound and telemetry.active.running_turn == false and
      telemetry.active.pending_session_wake == false
  end

  defp execution_map_quiet_match?(_world, _item, _bound), do: false

  defp execution_map_page(items, boundary, limit) do
    tuples = Enum.map(items, &{&1.created_at, &1.id})

    {selected, has_more_before, has_more_after} =
      case boundary do
        :latest ->
          selected = Enum.take(items, -limit)
          {selected, length(items) > limit, false}

        :earliest ->
          selected = Enum.take(items, limit)
          {selected, false, length(items) > limit}

        {:before, [created_at, id]} ->
          cursor = {created_at, id}
          prior = Enum.filter(items, &({&1.created_at, &1.id} < cursor))
          selected = Enum.take(prior, -limit)

          newest =
            if selected == [],
              do: cursor,
              else: {List.last(selected).created_at, List.last(selected).id}

          {selected, length(prior) > limit, Enum.any?(tuples, &(&1 > newest))}

        {:after, [created_at, id]} ->
          cursor = {created_at, id}
          later = Enum.filter(items, &({&1.created_at, &1.id} > cursor))
          selected = Enum.take(later, limit)
          oldest = if selected == [], do: cursor, else: {hd(selected).created_at, hd(selected).id}
          {selected, Enum.any?(tuples, &(&1 < oldest)), length(later) > limit}
      end

    %{
      items: selected,
      has_more_before: has_more_before,
      has_more_after: has_more_after
    }
  end

  defp execution_map_forest(world, appearing) do
    world = load_turn_summaries(world, appearing)
    appearing_ids = MapSet.new(appearing, & &1.id)
    nodes = Map.new(appearing, &{&1.id, rest_node(world, &1)})

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

    %{roots: Enum.map(roots, &execution_map_nest(&1, nodes, children))}
  end

  defp execution_map_nest(item, nodes, children) do
    kids = children |> Map.get(item.id, []) |> Enum.map(&execution_map_nest(&1, nodes, children))
    Map.put(Map.fetch!(nodes, item.id), :children, kids)
  end

  defp rest_node(world, item) do
    item
    |> then(&node(world, &1))
    |> Map.drop([:current_coordination])
    |> Map.update!(:active, fn active ->
      holder_classes =
        current_holders(world, Map.get(world.by_item, item.id, []))
        |> Enum.reduce(%{}, fn holder, acc ->
          Enum.reduce(Map.get(world.pending_wake_classes_by_session, holder, %{}), acc, fn {class,
                                                                                            count},
                                                                                           classes ->
            Map.update(classes, class, count, &(&1 + count))
          end)
        end)

      Map.put(active, :pending_wake_classes, holder_classes)
    end)
    |> Map.put(:created_at, item.created_at)
  end

  defp resolve_assignment_selectors(world, selectors, principal) do
    ids = Enum.uniq(selectors)

    Enum.reduce_while(ids, {:ok, [], []}, fn selector, {:ok, item_ids, no_item} ->
      case resolve_typed_prefix(selector, "asg_", Map.values(world.assignments_by_id)) do
        {:error, :not_found} ->
          {:halt, {:error, :not_found}}

        {:error, :ambiguous, candidate_ids} ->
          {:halt, {:error, :ambiguous, candidate_ids}}

        {:ok, assignment} ->
          if StateVisibility.execution_map_assignment_visible?(
               world.txn,
               assignment.id,
               principal
             ) do
            case Map.get(world.resolved, assignment.id) do
              nil ->
                {:cont, {:ok, item_ids, [assignment.id | no_item]}}

              item_id ->
                if Map.has_key?(world.items_by_id, item_id) and
                     StateVisibility.execution_map_node_visible?(world.txn, item_id, principal) do
                  {:cont, {:ok, [item_id | item_ids], no_item}}
                else
                  {:halt, {:error, :not_found}}
                end
            end
          else
            {:halt, {:error, :not_found}}
          end
      end
    end)
    |> case do
      {:ok, item_ids, no_item} -> {:ok, Enum.uniq(item_ids), Enum.uniq(no_item)}
      error -> error
    end
  end

  defp resolve_typed_prefix(value, prefix, candidates)
       when is_binary(value) and is_binary(prefix) and is_list(candidates) do
    if String.starts_with?(value, prefix) do
      matches =
        candidates
        |> Enum.filter(&String.starts_with?(&1.id, value))
        |> Enum.sort_by(& &1.id)

      case matches do
        [] -> {:error, :not_found}
        [match] -> {:ok, match}
        many -> {:error, :ambiguous, Enum.map(many, & &1.id)}
      end
    else
      {:error, :not_found}
    end
  end

  defp execution_map_wire_value!(node, "id"), do: execution_map_string!(node.id, "id")
  defp execution_map_wire_value!(node, "title"), do: execution_map_string!(node.title, "title")

  defp execution_map_wire_value!(node, "specRefName"),
    do: execution_map_nullable_string!(node.spec_ref_name, "specRefName")

  defp execution_map_wire_value!(node, "specRefSha256"),
    do: execution_map_nullable_string!(node.spec_ref_sha256, "specRefSha256")

  defp execution_map_wire_value!(node, "state") do
    value = execution_map_string!(node.state, "state")

    unless value in ~w(open iceboxed closed failed),
      do: raise(ArgumentError, "invalid execution-map state")

    value
  end

  defp execution_map_wire_value!(node, "failReason"),
    do: execution_map_nullable_string!(node.fail_reason, "failReason")

  defp execution_map_wire_value!(node, "bracket1Armed"),
    do: execution_map_boolean!(node.bracket1_armed, "bracket1Armed")

  defp execution_map_wire_value!(node, "origin") do
    execution_map_object!(
      node.origin,
      [principal: "principal", created_by: "createdBy"],
      "origin"
    )
  end

  defp execution_map_wire_value!(node, "creationContext") do
    execution_map_object!(
      node.creation_context,
      [recorded: "recorded", turn_seq: "turnSeq"],
      "creationContext"
    )
  end

  defp execution_map_wire_value!(node, "parent") do
    execution_map_object!(node.parent, [status: "status", item: "item"], "parent")
  end

  defp execution_map_wire_value!(node, "finishedAt"),
    do: execution_map_nullable_integer!(node.finished_at, "finishedAt")

  defp execution_map_wire_value!(node, "assignments") do
    value = node.assignments
    exact_execution_map_keys!(value, [:open, :closed, :by_outcome], "assignments")
    outcomes = value.by_outcome

    "{" <>
      execution_map_pair!("open", execution_map_encoded_count!(value.open, "assignments.open")) <>
      "," <>
      execution_map_pair!(
        "closed",
        execution_map_encoded_count!(value.closed, "assignments.closed")
      ) <>
      "," <>
      execution_map_pair!(
        "byOutcome",
        execution_map_object!(
          outcomes,
          [completed: "completed", surrendered: "surrendered", revoked: "revoked"],
          "assignments.byOutcome",
          &execution_map_encoded_count!(&1, "assignments.byOutcome")
        )
      ) <> "}"
  end

  defp execution_map_wire_value!(node, "jobs"), do: execution_map_count!(node.jobs, "jobs")

  defp execution_map_wire_value!(node, "attests") do
    value = node.attests
    exact_execution_map_keys!(value, [:total, :by_kind, :by_verdict_kind], "attests")

    "{" <>
      execution_map_pair!("total", execution_map_encoded_count!(value.total, "attests.total")) <>
      "," <>
      execution_map_pair!("byKind", execution_map_count_map!(value.by_kind, "attests.byKind")) <>
      "," <>
      execution_map_pair!(
        "byVerdictKind",
        execution_map_count_map!(value.by_verdict_kind, "attests.byVerdictKind")
      ) <> "}"
  end

  defp execution_map_wire_value!(node, "startedAt"),
    do: execution_map_nullable_integer!(node.started_at, "startedAt")

  defp execution_map_wire_value!(node, "closingAttests") when is_list(node.closing_attests) do
    "[" <>
      (node.closing_attests
       |> Enum.sort_by(&Map.get(&1, :assignmentId))
       |> Enum.map_join(",", fn attest ->
         exact_execution_map_keys!(
           attest,
           [:assignmentId, :attestId, :commitRefs],
           "closingAttests"
         )

         refs =
           case attest.commitRefs do
             nil ->
               "null"

             rows when is_list(rows) ->
               "[" <>
                 Enum.map_join(rows, ",", fn row ->
                   encode_execution_map_string_object!(
                     row,
                     ~w(repo commit),
                     "closingAttests.commitRefs"
                   )
                 end) <> "]"

             _ ->
               raise ArgumentError, "closingAttests.commitRefs must be an array or null"
           end

         "{" <>
           execution_map_pair!(
             "assignmentId",
             JSON.encode!(
               execution_map_string!(attest.assignmentId, "closingAttests.assignmentId")
             )
           ) <>
           "," <>
           execution_map_pair!(
             "attestId",
             JSON.encode!(execution_map_string!(attest.attestId, "closingAttests.attestId"))
           ) <>
           "," <>
           execution_map_pair!("commitRefs", refs) <> "}"
       end)) <> "]"
  end

  defp execution_map_wire_value!(_node, "closingAttests"),
    do: raise(ArgumentError, "closingAttests must be an array")

  defp execution_map_wire_value!(node, "openDecisionRequests"),
    do: execution_map_count!(node.open_decision_requests, "openDecisionRequests")

  defp execution_map_wire_value!(node, "turns") do
    execution_map_object!(node.turns, [total: "total", last_ended_at: "lastEndedAt"], "turns")
  end

  defp execution_map_wire_value!(node, "minds") when is_list(node.minds) do
    "[" <>
      (node.minds
       |> Enum.sort_by(fn mind ->
         {Map.get(mind, :model) || "", Map.get(mind, :context) || "",
          Map.get(mind, :effort) || "", Map.get(mind, :harness) || ""}
       end)
       |> Enum.map_join(",", fn mind ->
         execution_map_object!(
           mind,
           [model: "model", context: "context", effort: "effort", harness: "harness"],
           "minds"
         )
       end)) <> "]"
  end

  defp execution_map_wire_value!(_node, "minds"),
    do: raise(ArgumentError, "minds must be an array")

  defp execution_map_wire_value!(node, "fanOut"),
    do: execution_map_nullable_integer!(node.fan_out, "fanOut")

  defp execution_map_wire_value!(node, "active") do
    value = node.active

    exact_execution_map_keys!(
      value,
      [:running_turn, :pending_session_wake, :pending_wake_classes],
      "active"
    )

    "{" <>
      execution_map_pair!(
        "runningTurn",
        JSON.encode!(execution_map_boolean!(value.running_turn, "active.runningTurn"))
      ) <>
      "," <>
      execution_map_pair!(
        "pendingSessionWake",
        JSON.encode!(
          execution_map_boolean!(value.pending_session_wake, "active.pendingSessionWake")
        )
      ) <>
      "," <>
      execution_map_pair!(
        "pendingWakeClasses",
        execution_map_count_map!(value.pending_wake_classes, "active.pendingWakeClasses")
      ) <> "}"
  end

  defp execution_map_wire_value!(node, "sinceProgressMs"),
    do: execution_map_integer!(node.since_progress_ms, "sinceProgressMs")

  defp execution_map_wire_value!(_node, field),
    do: raise(ArgumentError, "unknown execution-map node field #{field}")

  defp encode_execution_map_field!("id", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("title", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("specRefName", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("specRefSha256", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("state", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("failReason", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("bracket1Armed", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("origin", value), do: value
  defp encode_execution_map_field!("creationContext", value), do: value
  defp encode_execution_map_field!("parent", value), do: value
  defp encode_execution_map_field!("finishedAt", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("assignments", value), do: value
  defp encode_execution_map_field!("jobs", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("attests", value), do: value
  defp encode_execution_map_field!("startedAt", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("closingAttests", value), do: value
  defp encode_execution_map_field!("openDecisionRequests", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("turns", value), do: value
  defp encode_execution_map_field!("minds", value), do: value
  defp encode_execution_map_field!("fanOut", value), do: JSON.encode!(value)
  defp encode_execution_map_field!("active", value), do: value
  defp encode_execution_map_field!("sinceProgressMs", value), do: JSON.encode!(value)

  defp execution_map_object!(value, fields, label, encode_value \\ &JSON.encode!/1) do
    exact_execution_map_keys!(value, Keyword.keys(fields), label)

    "{" <>
      Enum.map_join(fields, ",", fn {key, wire} ->
        execution_map_pair!(wire, encode_value.(Map.fetch!(value, key)))
      end) <> "}"
  end

  defp encode_execution_map_string_object!(value, fields, label) when is_map(value) do
    unless Enum.sort(Map.keys(value)) == Enum.sort(fields) do
      raise ArgumentError, "#{label} has an extra or missing field"
    end

    "{" <>
      Enum.map_join(fields, ",", fn field ->
        execution_map_pair!(field, JSON.encode!(Map.fetch!(value, field)))
      end) <> "}"
  end

  defp encode_execution_map_string_object!(_value, _fields, label),
    do: raise(ArgumentError, "#{label} must be an object")

  defp exact_execution_map_keys!(value, expected, label) when is_map(value) do
    unless Enum.sort(Map.keys(value)) == Enum.sort(expected) do
      raise ArgumentError, "#{label} has an extra or missing field"
    end
  end

  defp exact_execution_map_keys!(_value, _expected, label),
    do: raise(ArgumentError, "#{label} must be an object")

  defp execution_map_count_map!(value, label) when is_map(value) do
    unless Enum.all?(Map.keys(value), &(is_binary(&1) and &1 != "")) do
      raise ArgumentError, "#{label} contains an invalid key"
    end

    "{" <>
      (value
       |> Enum.sort_by(&elem(&1, 0))
       |> Enum.map_join(",", fn {key, count} ->
         execution_map_pair!(key, execution_map_encoded_count!(count, label))
       end)) <> "}"
  end

  defp execution_map_count_map!(_value, label),
    do: raise(ArgumentError, "#{label} must be an object")

  defp execution_map_pair!(key, encoded_value),
    do: JSON.encode!(key) <> ":" <> encoded_value

  defp execution_map_string!(value, _field) when is_binary(value) and value != "", do: value

  defp execution_map_string!(_value, field),
    do: raise(ArgumentError, "#{field} must be a nonempty string")

  defp execution_map_nullable_string!(nil, _field), do: nil
  defp execution_map_nullable_string!(value, field), do: execution_map_string!(value, field)

  defp execution_map_boolean!(value, _field) when is_boolean(value), do: value

  defp execution_map_boolean!(_value, field),
    do: raise(ArgumentError, "#{field} must be a boolean")

  defp execution_map_integer!(value, _field) when is_integer(value), do: value

  defp execution_map_integer!(_value, field),
    do: raise(ArgumentError, "#{field} must be an integer")

  defp execution_map_nullable_integer!(nil, _field), do: nil
  defp execution_map_nullable_integer!(value, field), do: execution_map_integer!(value, field)

  defp execution_map_count!(value, _field) when is_integer(value) and value >= 0, do: value

  defp execution_map_count!(_value, field),
    do: raise(ArgumentError, "#{field} must be a nonnegative integer")

  defp execution_map_encoded_count!(value, field),
    do: JSON.encode!(execution_map_count!(value, field))

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

    turns_by_seq = creation_turns(db, items)

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
      db: db,
      turn_summaries: %{},
      linked: linked,
      parents: parents(items, linked),
      attests_by_assignment: attests_by_assignment(db),
      commit_refs: commit_refs(db),
      markers_by_assignment: markers_by_assignment(db),
      open_requests: open_requests(db),
      pending_wake_sessions: pending_wake_sessions(db),
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
        closing_attest_id: closing,
        current_coordination_parent_ref:
          Tightbeam.SessionReparent.current_coordination_ref(db, id)
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

  defp creation_turns(db, items) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT seq, assignmentId, jobRef
        FROM turns
        WHERE seq IN (SELECT value FROM json_each(?1))
        """,
        [JSON.encode!(creation_sequences(items))]
      )

    creation_turn_index(rows)
  end

  defp creation_sequences(items) do
    for item <- items,
        item.context_known,
        is_integer(item.created_in_turn_seq),
        uniq: true,
        do: item.created_in_turn_seq
  end

  defp creation_turn_index(rows) do
    Map.new(rows, fn [seq, assignment_id, job_ref] ->
      {seq, %{assignment_id: assignment_id, job_ref: job_ref}}
    end)
  end

  defp load_turn_summaries(world, items) do
    {join, predicate, principal_params} = turn_summary_scope(world)

    summaries =
      items
      |> Enum.reject(&Map.has_key?(world.turn_summaries, &1.id))
      |> Enum.chunk_every(256)
      |> Enum.reduce(world.turn_summaries, fn batch, acc ->
        ids = Enum.map(batch, & &1.id)

        assignments =
          for id <- ids, assignment_id <- Map.get(world.by_item, id, []), do: [id, assignment_id]

        rows =
          query_turn_summaries(
            world,
            """
            WITH attributed AS (
              SELECT item.value AS item_id, t.status, t.endedAt,
                     t.model, t.modelContext, t.thinkingLevel, t.harness,
                     printf('0:%020d', t.seq) AS attribution_order
              FROM json_each(?1) AS item
              CROSS JOIN turns AS t ON t.jobRef = item.value
              #{join}
              WHERE #{predicate}
              UNION ALL
              SELECT json_extract(member.value, '$[0]'), t.status, t.endedAt,
                     t.model, t.modelContext, t.thinkingLevel, t.harness,
                     printf('1:%s:%020d', t.assignmentId, t.seq)
              FROM json_each(?2) AS member
              CROSS JOIN turns AS t ON t.assignmentId = json_extract(member.value, '$[1]')
              #{join}
              WHERE t.jobRef IS NOT json_extract(member.value, '$[0]')
                AND (#{predicate})
            )
            SELECT item_id, COUNT(*), MAX(endedAt), MAX(status IS 'running'),
                   model, modelContext, thinkingLevel, harness
            FROM attributed
            GROUP BY item_id, model, modelContext, thinkingLevel, harness
            ORDER BY MIN(attribution_order)
            """,
            [JSON.encode!(ids), JSON.encode!(assignments) | principal_params]
          )

        acc = Enum.reduce(ids, acc, &Map.put(&2, &1, @empty_turn_summary))
        Enum.reduce(rows, acc, &merge_turn_summary/2)
      end)

    %{world | turn_summaries: summaries}
  end

  defp turn_summary_scope(%{principal: principal}) do
    {"JOIN sessions AS s ON s.sessionKey = t.sessionKey", @rest_turn_visibility,
     turn_principal_params(principal)}
  end

  defp turn_summary_scope(_world), do: {"", "1", []}

  defp query_turn_summaries(%{txn: txn}, sql, params), do: Txn.q(txn, sql, params)

  defp query_turn_summaries(%{db: db}, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  # A turn with both links to the same item contributes once. If the two links
  # resolve to different items, it contributes once to each of those items.
  defp merge_turn_summary(
         [id, count, ended_at, running, model, context, effort, harness],
         summaries
       ) do
    summary = Map.get(summaries, id, @empty_turn_summary)

    minds =
      if is_nil(model) and is_nil(harness) do
        summary.minds
      else
        [%{model: model, context: context, effort: effort, harness: harness} | summary.minds]
      end

    Map.put(summaries, id, %{
      total: summary.total + count,
      last_ended_at: latest_turn_end(summary.last_ended_at, ended_at),
      running: summary.running or running == 1,
      minds: minds
    })
  end

  defp latest_turn_end(nil, right), do: right
  defp latest_turn_end(left, nil), do: left
  defp latest_turn_end(left, right), do: max(left, right)

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

  defp caller(_db, {:process, _name}), do: %{owner: nil, admin: true}

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
