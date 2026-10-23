defmodule Tightbeam.MementoCutover do
  @moduledoc false
  alias Tightbeam.{Assignments, MementoJudgments, Mementos, RuleRuntime, Rules}
  alias Tightbeam.DB.Txn

  # This is immutable candidate policy, never a request-supplied inventory.
  # Absence remains valid for legacy identities; an assessment must require it.
  def prepare!([], _snapshot), do: nil

  def prepare!([entry], snapshot) do
    raw = entry.declaration
    keys!(raw, ~w(version effects judgments legacy_evidence_requirements inventory), "declaration")
    unless raw["version"] === 1, do: refuse!("unsupported memento_cutover version")
    revision = snapshot.revision

    unless is_binary(revision) and revision != "" and snapshot.declarations.revision == revision,
      do: refuse!("memento_cutover requires one candidate identity revision")

    effects = raw["effects"]
    keys!(effects, ~w(selector mapping), "effects")
    selector = rule!(effects["selector"], snapshot)
    mappings = list!(effects["mapping"], "effect mapping")

    mappings =
      Enum.map(mappings, fn mapping ->
        keys!(mapping, ~w(legacy_value name value), "effect mapping")
        legacy = string!(mapping["legacy_value"], "legacy value")
        name = string!(mapping["name"], "qualified memento name")
        value = string!(mapping["value"], "mapped value")

        case snapshot.declarations.names[name] do
          %{records: records} ->
            unless "assignment" in records,
              do: refuse!("mapped memento #{name} is not declared for assignments")

          _ ->
            refuse!("mapped memento #{name} is not declared in the candidate")
        end

        # Reuse the opaque value limits, without appending or resolving legacy data.
        Mementos.values!([value])
        %{legacy_value: legacy, name: name, value: value}
      end)

    unique!(mappings, & &1.legacy_value, "legacy effect mapping")
    judgments = list!(raw["judgments"], "judgment selectors")
    if judgments == [], do: refuse!("memento_cutover requires judgment selector rules")

    judgments =
      Enum.map(judgments, fn judgment ->
        keys!(judgment, ~w(selector route successor_rule), "judgment selector")
        selector = rule!(judgment["selector"], snapshot)
        route = judgment["route"]

        unless route in ~w(none linked_review holder_verification),
          do: refuse!("invalid successor route #{inspect(route)}")

        successor =
          if route == "none" do
            if Map.has_key?(judgment, "successor_rule"),
              do: refuse!("a no-successor route cannot name a successor rule")

            nil
          else
            rule!(judgment["successor_rule"], snapshot)
          end

        %{selector: selector, route: route, successor_rule: successor}
      end)

    unique!(judgments, & &1.selector, "judgment selector")
    requirements = requirements!(raw["legacy_evidence_requirements"], snapshot)

    %{
      version: 1,
      identity_revision: revision,
      effects: %{selector: selector, mapping: mappings},
      judgments: judgments,
      legacy_evidence_requirements: requirements,
      inventory: raw["inventory"]
    }
  end

  def prepare!(_entries, _snapshot), do: refuse!("duplicate memento_cutover declarations")

  defp requirements!(nil, _snapshot), do: %{version: 1, entries: []}

  defp requirements!(raw, snapshot) do
    keys!(raw, ~w(version entries), "legacy evidence requirements")
    unless raw["version"] === 1, do: refuse!("unsupported legacy evidence requirements version")

    entries =
      Enum.map(list!(raw["entries"], "legacy evidence requirements"), fn entry ->
        keys!(entry, ~w(assignment_id attest_id route name values), "legacy evidence requirement")
        assignment = string!(entry["assignment_id"], "requirement source assignment")
        attest = string!(entry["attest_id"], "requirement source attest")
        name = string!(entry["name"], "requirement memento name")

        route =
          case entry["route"] do
            "independent-review" -> "linked_review"
            "open-producer-holder-verification" -> "holder_verification"
            other -> refuse!("invalid requirement route #{inspect(other)}")
          end

        case snapshot.declarations.names[name] do
          %{records: records} ->
            unless "attest" in records,
              do: refuse!("requirement memento #{name} is not declared for attests")

          _ ->
            refuse!("requirement memento #{name} is not declared in the candidate")
        end

        values = Mementos.values!(entry["values"])

        unless snapshot.declarations.names[name].many or length(values) <= 1,
          do: refuse!("requirement #{attest} exceeds the declared cardinality for #{name}")

        unless values != [] and values === entry["values"],
          do: refuse!("requirement #{attest} needs nonempty distinct expected values")

        %{assignment_id: assignment, attest_id: attest, route: route, name: name, values: values}
      end)

    unique!(entries, &{&1.assignment_id, &1.attest_id}, "legacy evidence requirement")
    %{version: 1, entries: entries}
  end

  defp requirement!(requirements, assignment, attest, route) do
    case {route, Map.get(requirements, {assignment, attest})} do
      {"none", nil} ->
        nil

      {"none", _} ->
        refuse!("judgment #{attest}: no-successor route has an extra evidence requirement")

      {_, %{route: ^route} = requirement} ->
        requirement

      {_, nil} ->
        refuse!("judgment #{attest}: missing evidence requirement")

      _ ->
        refuse!("judgment #{attest}: ambiguous or wrong-route evidence requirement")
    end
  end

  # The replacement must load without any retired admission facts, including
  # predicates in positive requirements and policy tables. This reads the
  # loaded candidate, not a caller's list of supposedly affected rules.
  @doc false
  def policy_inventory!(snapshot) do
    unless is_binary(snapshot.revision) and snapshot.revision != "" and
             snapshot.declarations.revision == snapshot.revision and
             snapshot.unavailable_verbs == %{} do
      refuse!("cutover candidate is not a complete loaded policy revision")
    end

    replacement_verbs =
      snapshot.requested_admission_contract
      |> Enum.filter(fn {_verb, contract} -> contract.classification == "replacement" end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    rules = Rules.policy_rule_inventory(snapshot)

    policies =
      Enum.map(snapshot.policies, fn policy ->
        %{
          name: policy.name,
          identity_revision: policy.identity_manifest_sha,
          facts: policy.conditions |> Enum.map(& &1.fact) |> Enum.uniq() |> Enum.sort()
        }
      end)

    retired = ~w(assign.effect_kind assignment.effect_kind
      assignment.qualifying_review_verdict_kinds assignment.qualifying_verification_verdict_kinds)

    Enum.each(rules ++ policies, fn entry ->
      unless entry.identity_revision == snapshot.revision,
        do: refuse!("rule or policy #{entry.name} belongs to a different identity revision")

      if not Map.has_key?(entry, :verb) or MapSet.member?(replacement_verbs, entry.verb) do
        case Enum.find(entry.facts, &(&1 in retired)) do
          nil -> :ok
          fact -> refuse!("rule or policy #{entry.name} still references retired fact #{fact}")
        end
      end
    end)

    %{rules: rules, policies: Enum.sort_by(policies, & &1.name)}
  end

  # This is a census component, not an activation/readiness result. It has no
  # request-supplied population and is never called by normal record operations.
  # The final cutover assessment must also check callers and the published/core
  # pair while retaining the same fence through activation.
  @doc false
  def census_in_txn!(%Txn{} = txn, snapshot) do
    declaration = Map.get(snapshot, :memento_cutover)

    unless is_map(declaration) and declaration.identity_revision == snapshot.revision and
             snapshot.declarations.revision == snapshot.revision,
           do: refuse!("cutover census requires the candidate memento_cutover declaration")

    RuleRuntime.with_policy_snapshot(snapshot, fn ->
      # Keep the exact legacy source row in the census; this table has no
      # independent version column.
      assignment_sources =
        Txn.q(
          txn,
          "SELECT a.*, e.effectKind FROM assignments a LEFT JOIN assignment_effects e ON e.assignmentId=a.id ORDER BY a.id"
        )

      assignments = Assignments.list(txn, %{state: "all"}) |> Enum.sort_by(& &1.id)

      sources =
        Map.new(assignment_sources, fn row ->
          {hd(row), %{revision: Enum.drop(row, -1), legacy_value: List.last(row)}}
        end)

      effects =
        Enum.map(assignments, fn assignment ->
          id = assignment.id
          selected = selector!(txn, declaration.effects.selector, source_call(id), id)

          stored = Map.fetch!(sources, id)

          source = %{
            id: id,
            source_revision: stored.revision,
            legacy_value: stored.legacy_value,
            selected: selected
          }

          if selected do
            mapping =
              case Enum.filter(
                     declaration.effects.mapping,
                     &(&1.legacy_value == stored.legacy_value)
                   ) do
                [mapping] ->
                  mapping

                _ ->
                  refuse!(
                    "assignment #{id}: missing or ambiguous effect mapping for #{inspect(stored.legacy_value)}"
                  )
              end

            head = effect_head!(txn, id, mapping)
            Map.merge(source, %{mapping: mapping, head: head})
          else
            source
          end
        end)

      # Enumerate every verdict, including those with no legacy references. A
      # policy must explicitly resolve each judgment to one route (possibly
      # none); a null/empty legacy value must not silently hide an obligation.
      judgment_sources =
        Txn.q(txn, "SELECT rowid, * FROM attests WHERE kind='verdict' ORDER BY id")

      requirements =
        Map.new(
          declaration.legacy_evidence_requirements.entries,
          &{{&1.assignment_id, &1.attest_id}, &1}
        )

      judgments =
        Enum.map(judgment_sources, fn [
                                        rowid,
                                        id,
                                        assignment_id,
                                        kind,
                                        verdict_kind,
                                        _note,
                                        by_session,
                                        by_user | _
                                      ] = row ->
          call =
            source_call(
              assignment_id,
              %{kind: kind, verdict_kind: verdict_kind, attest_id: id},
              by_session,
              by_user
            )

          # Stored inline values are the row's own fact context. This lets
          # policy distinguish legacy-only judgments from prepared successors
          # without teaching core the meaning of any qualified name.
          call = Map.put(call, :memento_writes, Map.to_list(Mementos.current(txn, "attest", id)))
          routes = Enum.filter(declaration.judgments, &selector!(txn, &1.selector, call, id))

          route =
            case routes do
              [route] -> route
              [] -> refuse!("judgment #{id}: no cutover selector matched")
              _ -> refuse!("judgment #{id}: ambiguous cutover selector outcomes")
            end

          requirement = requirement!(requirements, assignment_id, id, route.route)

          %{
            id: id,
            assignment_id: assignment_id,
            rowid: rowid,
            source_revision: rowid,
            route: route.route,
            successor_rule: route.successor_rule,
            requirement: requirement,
            successor: successor!(txn, route, call, rowid, id, requirement)
          }
        end)

      source_keys = MapSet.new(judgments, &{&1.assignment_id, &1.id})

      Enum.each(declaration.legacy_evidence_requirements.entries, fn requirement ->
        unless MapSet.member?(source_keys, {requirement.assignment_id, requirement.attest_id}),
          do:
            refuse!(
              "judgment #{requirement.attest_id}: extra or wrong-source evidence requirement"
            )
      end)

      [[current_head_count]] = Txn.q(txn, "SELECT COUNT(*) FROM memento_current")

      census = %{
        phase: :census,
        identity_revision: snapshot.revision,
        current_head_count: current_head_count,
        assignment_count: length(effects),
        selected_effect_count: Enum.count(effects, & &1.selected),
        judgment_count: length(judgments),
        effects: effects,
        judgments: judgments,
        successors_checked: true
      }

      inventory = declaration.inventory
      reconcile_inventory!(inventory, census)
      Map.put(census, :inventory_reconciled, not is_nil(inventory))
    end)
  end

  # An inventory is an optional comparison document, never an input to the
  # selectors or store queries above. Each supplied population claims a complete
  # source or selected set and must contain the exact runtime-checked rows.
  defp reconcile_inventory!(nil, _census), do: :ok

  defp reconcile_inventory!(inventory, census) do
    keys!(
      inventory,
      ~w(version identity_revision assignments judgments),
      "inventory"
    )

    unless inventory["version"] === 1 and
             inventory["identity_revision"] === census.identity_revision,
           do: refuse!("cutover inventory has a stale or mismatched policy revision")

    reconcile_population!(inventory["assignments"], census.effects, & &1.selected, "assignment")

    reconcile_population!(
      inventory["judgments"],
      census.judgments,
      &(&1.route != "none"),
      "judgment"
    )

    :ok
  end

  defp reconcile_population!(population, actual, selected?, kind) do
    keys!(population, ~w(scope count rows), "#{kind} inventory population")
    scope = population["scope"]
    unless scope in ~w(all selected), do: refuse!("invalid #{kind} inventory scope")
    rows = list!(population["rows"], "#{kind} inventory rows")

    unless is_integer(population["count"]) and population["count"] >= 0 and
             population["count"] == length(rows),
           do: refuse!("#{kind} inventory count does not match its rows")

    expected = if scope == "all", do: actual, else: Enum.filter(actual, selected?)

    ids =
      Enum.map(rows, fn row ->
        unless is_map(row) and is_binary(row["id"]) and row["id"] != "",
          do: refuse!("invalid #{kind} inventory row id")

        row["id"]
      end)

    case Enum.find(Enum.frequencies(ids), fn {_, count} -> count > 1 end) do
      {id, _} -> refuse!("#{kind} #{id}: duplicate inventory row")
      nil -> :ok
    end

    expected_ids = Enum.map(expected, & &1.id)
    expected_set = MapSet.new(expected_ids)
    supplied_set = MapSet.new(ids)

    case Enum.find(expected_ids, &(not MapSet.member?(supplied_set, &1))) do
      nil -> :ok
      id -> refuse!("#{kind} #{id}: omitted from #{scope} inventory")
    end

    case Enum.find(ids, &(not MapSet.member?(expected_set, &1))) do
      nil -> :ok
      id -> refuse!("#{kind} #{id}: extra row in #{scope} inventory")
    end

    supplied = Map.new(rows, &{&1["id"], &1})

    Enum.each(expected, fn row ->
      # Normalize only key representation, not values or row membership.
      checked = row |> JSON.encode!() |> JSON.decode!()

      unless supplied[row.id] === checked,
        do: refuse!("#{kind} #{row.id}: stale or mismatched inventory state")
    end)
  end

  defp successor!(_txn, %{route: "none"}, _call, _rowid, _id, nil), do: nil

  defp successor!(txn, route, call, source_rowid, source_id, requirement) do
    source_assignment = call.params.assignment_id

    [[parent, state]] =
      Txn.q(txn, "SELECT reviewsAssignmentId,state FROM assignments WHERE id=?1", [
        source_assignment
      ])

    {producer, selector, fact_selector} =
      case route.route do
        "linked_review" ->
          {parent || source_assignment, "linked_review", "latest_linked_review"}

        "holder_verification" ->
          unless is_nil(parent) and state == "open",
            do:
              refuse!(
                "judgment #{source_id}: holder verification requires the same open producer"
              )

          {source_assignment, "holder", "latest_holder_verdict"}
      end

    selected = MementoJudgments.latest(txn, producer, selector)
    unless selected, do: refuse!("judgment #{source_id}: missing #{selector} successor")

    [[rowid, assignment_id, kind, author, user, ts, holder, reviews, producer_holder]] =
      Txn.q(
        txn,
        """
        SELECT v.rowid,v.assignmentId,v.verdictKind,v.bySession,v.byUser,v.ts,
               a.holderKey,a.reviewsAssignmentId,p.holderKey
        FROM attests v JOIN assignments a ON a.id=v.assignmentId
        JOIN assignments p ON p.id=?2 WHERE v.id=?1 AND v.kind='verdict'
        """,
        [selected.id, producer]
      )

    [[source_ts]] = Txn.q(txn, "SELECT ts FROM attests WHERE id=?1", [source_id])

    unless {ts, rowid} > {source_ts, source_rowid} and selected.id != source_id and
             author == holder and is_nil(user) and is_binary(kind) and kind != "" and
             kind == selected.judgment_kind,
           do:
             refuse!(
               "judgment #{source_id}: successor #{selected.id} is not a fresh holder judgment"
             )

    case route.route do
      "linked_review" ->
        unless reviews == producer and author != producer_holder and selected.independent,
          do:
            refuse!(
              "judgment #{source_id}: successor #{selected.id} is not an independent linked review"
            )

      "holder_verification" ->
        unless assignment_id == producer and kind == "verified",
          do:
            refuse!(
              "judgment #{source_id}: successor #{selected.id} is not holder verification on the same producer"
            )
    end

    candidate_call = %{call | params: Map.put(call.params, :assignment_id, producer)}

    checked =
      Rules.cutover_successor_in_txn!(txn, route.successor_rule, candidate_call, requirement)

    prefix = "assignment.#{fact_selector}."

    unless checked.cache[{:memento_judgment, fact_selector}] == selected and
             Map.has_key?(checked.facts, prefix <> "judgment_kind"),
           do:
             refuse!(
               "judgment #{source_id}: successor policy must check the selected #{selector} kind"
             )

    matcher = prefix <> "memento_matches_cutover_requirement." <> requirement.name

    unless checked.facts[matcher] == true,
      do:
        refuse!("judgment #{source_id}: successor policy has no evidence matcher for #{selector}")

    names = [requirement.name]

    evidence =
      Map.new(names, fn name ->
        values = Map.get(checked.cache, {:memento_value, "attest", selected.id, name}, [])

        if values == [],
          do: refuse!("judgment #{source_id}: successor #{selected.id} has empty #{name}")

        {name, current_head!(txn, "attest", selected.id, name, values)}
      end)

    %{
      id: selected.id,
      assignment_id: assignment_id,
      producer_id: producer,
      selector: selector,
      judgment_kind: kind,
      independent: selected.independent,
      rowid: rowid,
      ts: ts,
      facts: checked.facts,
      evidence: evidence
    }
  rescue
    error in ArgumentError -> refuse!("judgment #{source_id}: #{Exception.message(error)}")
  end

  defp selector!(txn, selector, call, id) do
    Rules.cutover_selector_in_txn!(txn, selector, call)
  rescue
    error in ArgumentError -> refuse!("record #{id}: #{Exception.message(error)}")
  end

  defp source_call(assignment_id, params \\ %{}, session \\ nil, user \\ nil) do
    principal =
      cond do
        is_binary(session) -> {:session, session}
        is_binary(user) -> {:user, user}
        true -> nil
      end

    %{
      verb: "attest",
      params: Map.put(params, :assignment_id, assignment_id),
      principal: principal,
      origin:
        if(principal,
          do:
            "#{if(elem(principal, 0) == :session, do: "agent", else: "user")}:#{elem(principal, 1)}",
          else: nil
        ),
      session_key: nil,
      target_role: nil,
      role_fallback: false
    }
  end

  defp effect_head!(txn, id, mapping),
    do: current_head!(txn, "assignment", id, mapping.name, [mapping.value])

  defp current_head!(txn, kind, id, name, expected) do
    case Txn.q(
           txn,
           """
           SELECT c.historyId,c.valueJson,h.recordKind,h.recordId,h.name,h.valueJson,
             (SELECT MAX(latest.id) FROM memento_history latest
              WHERE latest.recordKind=?1 AND latest.recordId=?2 AND latest.name=?3)
           FROM memento_current c LEFT JOIN memento_history h ON h.id=c.historyId
           WHERE c.recordKind=?1 AND c.recordId=?2 AND c.name=?3
           """,
           [kind, id, name]
         ) do
      [[head, values, ^kind, ^id, ^name, values, head]] ->
        unless JSON.decode(values) == {:ok, expected},
          do: refuse!("#{kind} #{id}: mapped current memento #{name} value mismatch")

        %{history_id: head, values: expected, name: name}

      _ ->
        refuse!("#{kind} #{id}: missing or stale current memento head #{name}")
    end
  end

  defp rule!(name, snapshot) do
    name = string!(name, "selector rule reference")

    case Enum.filter(snapshot.rules, &(&1.name == name)) do
      [rule] ->
        unless rule.identity_manifest_sha == snapshot.revision and
                 not Map.has_key?(snapshot.unavailable_verbs, rule.verb) and is_nil(rule.check),
               do:
                 refuse!(
                   "selector rule #{name} is unavailable or is not a candidate predicate rule"
                 )

        name

      _ ->
        refuse!("selector rule #{name} is missing or ambiguous")
    end
  end

  defp keys!(value, keys, label) do
    unless is_map(value) and Map.keys(value) -- keys == [],
      do: refuse!("invalid #{label} keys in memento_cutover")
  end

  defp list!(value, _label) when is_list(value), do: value
  defp list!(_value, label), do: refuse!("#{label} must be an array")

  defp string!(value, _label) when is_binary(value) and byte_size(value) > 0, do: value
  defp string!(_value, label), do: refuse!("#{label} must be a nonempty string")

  defp unique!(values, key, label) do
    if Enum.any?(Enum.frequencies_by(values, key), fn {_, count} -> count > 1 end),
      do: refuse!("duplicate #{label}")
  end

  defp refuse!(message),
    do: raise(Mementos.Refusal, code: "policy_revision_unavailable", message: message)
end
