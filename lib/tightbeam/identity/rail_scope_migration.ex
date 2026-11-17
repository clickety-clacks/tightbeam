defmodule Tightbeam.Identity.RailScopeMigration do
  @moduledoc """
  Deterministic, receipt-based migration to qualified archetypes and scoped rails.

  Planning is read-only. Every known refusal is collected before identity files
  or organization rows are changed. A stop report is written outside the
  identity repository so it survives a refused boot without becoming served law.
  """

  alias Tightbeam.{DB, Identity}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Identity.{Provenance, TomlEdit}

  @report_name "rail-scope-migration-report.json"
  @migration_id "rail-scope-v1"
  @seed_reactions %{
    "assignment-terminal-handoff" => "rules/row-reaction-handoff.toml",
    "terminal-child-action-reminder" => "rules/row-reaction-terminal-action.toml"
  }
  @seed_rails %{
    "github-auth" => "rails/github-auth.toml",
    "tightbeam-probe" => "rails/tightbeam-probe.toml"
  }
  @legacy_reaction_hashes %{
    "6ec382195b47e1f28c1b41560a56be4c609f6b106b135e6d9b3b3f4b8d0ceadf" =>
      "assignment-inactivity-reminders",
    "49e221df8f6d8daee2a99c8874a32072c4870eac7f436ae74b379983a5d603de" =>
      "assignment-terminal-handoff",
    "b61637b67df034905bab78afd9b92b62e0054a6b0e48a8ecbf5fb392de5c4343" =>
      "assignment-terminal-handoff",
    "01eb80b0dc06793e21a9e1965680660602d68974ce0b05907811fe46110f44c0" =>
      "terminal-child-action-reminder"
  }
  @legacy_reaction_files ~w(
    row-reaction-assignment-inactivity.toml
    row-reaction-handoff.toml
    row-reaction-terminal-action.toml
  )
  @participant_facts ["spawn.archetype", "target.archetype", "assignment.holder_archetype"]
  @recurrence_tables ~w(
    recurrence_suppression_episodes
    recurrence_suppression_deliveries
    recurrence_suppression_fact_observations
    recurrence_suppression_receipts
    recurrence_suppression_events
  )

  @doc "Run the migration after the complete database schema has been ensured."
  @spec run!(String.t(), DB.server()) :: map()
  def run!(base_dir, db \\ DB) when is_binary(base_dir) do
    dir = Path.join(base_dir, "identity")
    report_path = Path.join(base_dir, @report_name)

    case completed_report_from_db!(db) do
      {:complete, report} ->
        report

      :not_complete ->
        if File.regular?(Path.join([dir, ".git", "MERGE_HEAD"])) do
          stop_pending_merge!(report_path)
        else
          run_clean_identity!(base_dir, db, dir, report_path)
        end
    end
  end

  defp completed_report_from_db!(db) do
    case DB.query(db, "SELECT reportJson FROM rail_scope_migrations WHERE migrationId=?1", [
           @migration_id
         ]) do
      {:ok, rows} ->
        decode_completed_report!(rows)

      {:error, error} ->
        raise ArgumentError,
              "cannot read rail scoping migration marker: #{Exception.message(error)}"
    end
  end

  defp completed_report_from_txn!(txn) do
    Txn.q(txn, "SELECT reportJson FROM rail_scope_migrations WHERE migrationId=?1", [
      @migration_id
    ])
    |> decode_completed_report!()
  end

  defp decode_completed_report!([]), do: :not_complete

  defp decode_completed_report!([[encoded]]) when is_binary(encoded) do
    report = JSON.decode!(encoded)

    if report["schema"] == "tightbeam-rail-scope-migration/v1" and
         report["status"] == "complete" and is_binary(report["source_revision"]) and
         is_binary(report["result_revision"]) do
      {:complete, report}
    else
      raise ArgumentError, "invalid rail scoping migration completion marker"
    end
  rescue
    error in [ArgumentError] ->
      reraise error, __STACKTRACE__

    error ->
      raise ArgumentError,
            "invalid rail scoping migration completion marker: #{Exception.message(error)}"
  end

  defp decode_completed_report!(rows),
    do: raise(ArgumentError, "invalid rail scoping migration marker rows: #{inspect(rows)}")

  defp store_completed_report!(txn, report) do
    Txn.q(
      txn,
      "INSERT INTO rail_scope_migrations(migrationId,reportJson,completedAt) VALUES(?1,?2,?3)",
      [@migration_id, JSON.encode!(report), System.system_time(:millisecond)]
    )
  end

  defp stop_pending_merge!(report_path) do
    reason = "an identity relearn merge is in progress"

    report = %{
      "schema" => "tightbeam-rail-scope-migration/v1",
      "status" => "stopped",
      "source_revision" => nil,
      "result_revision" => nil,
      "rewritten_names" => [],
      "removed_entries" => [],
      "flagged_conditions" => [],
      "stops" => [
        stop(
          "migration",
          "identity/.git/MERGE_HEAD",
          reason,
          "complete or abort the identity relearn merge, then restart Tightbeam"
        )
      ]
    }

    write_report!(report_path, report)
    raise ArgumentError, "rail scoping migration stopped; see #{report_path}: #{reason}"
  end

  defp run_clean_identity!(base_dir, db, dir, report_path) do
    revision =
      try do
        preflight_repository!(dir)
      rescue
        error ->
          write_failure_report!(report_path, nil, error)
          reraise error, __STACKTRACE__
      end

    plan =
      try do
        plan!(base_dir, dir, revision)
      rescue
        error ->
          write_failure_report!(report_path, revision, error)
          reraise error, __STACKTRACE__
      end

    if plan.stops != [] do
      report = report(plan, revision, "stopped")
      write_report!(report_path, report)

      raise ArgumentError,
            "rail scoping migration stopped; see #{report_path}: #{stop_summary(plan.stops)}"
    end

    old_main = revision

    case DB.transaction(db, fn txn ->
           case completed_report_from_txn!(txn) do
             {:complete, existing_report} ->
               {:already_complete, existing_report}

             :not_complete ->
               row_rewrites =
                 migrate_rows!(txn, plan.name_map, plan.rail_map, plan.reaction_names)

               result =
                 if plan.identity_changed? do
                   candidate_revision = apply_identity_plan!(dir, plan, revision)
                   :ok = publish_identity!(base_dir, revision, candidate_revision)
                   candidate_revision
                 else
                   revision
                 end

               final_plan = %{
                 plan
                 | result_revision: result,
                   rewritten_names: plan.rewritten_names ++ row_rewrites
               }

               final_report = report(final_plan, revision, "complete")
               store_completed_report!(txn, final_report)
               {:migrated, final_report}
           end
         end) do
      {:ok, {:already_complete, final_report}} ->
        final_report

      {:ok, {:migrated, final_report}} ->
        write_report!(report_path, final_report)
        final_report

      {:error, error} ->
        rollback_identity!(dir, old_main, plan)

        failed_plan = %{
          plan
          | stops:
              plan.stops ++
                [
                  stop(
                    "migration",
                    "database",
                    Exception.message(error),
                    "repair the recorded row shape or archetype reference, then rerun the migration"
                  )
                ]
        }

        write_report!(report_path, report(failed_plan, revision, "stopped"))
        raise error
    end
  rescue
    error in [ArgumentError] ->
      reraise error, __STACKTRACE__
  end

  @doc false
  def plan!(base_dir, identity_dir \\ nil, revision \\ nil) do
    identity_dir = identity_dir || Path.join(base_dir, "identity")
    revision = revision || preflight_repository!(identity_dir)
    entries = tree_entries!(identity_dir, revision)
    receipts = receipts_at!(identity_dir, revision)
    claims = receipt_claims(receipts)
    duplicate_stops = duplicate_claim_stops(claims)
    owner_by_path = owner_map(claims)
    archetypes = archetype_index(entries, owner_by_path)
    name_map = build_name_map(archetypes)
    seed_reactions = seed_reaction_entries()
    seed_rails = seed_rail_entries()
    reaction_scan = find_legacy_reactions(entries, receipts, owner_by_path)

    initial = %{
      identity_dir: identity_dir,
      source_revision: revision,
      entries: entries,
      receipts: receipts,
      owner_by_path: owner_by_path,
      archetypes: archetypes,
      name_map: name_map,
      rail_map: %{},
      reaction_names: Map.keys(@seed_reactions),
      writes: %{},
      removals: reaction_scan.removed_paths,
      skip_paths: reaction_scan.candidate_paths,
      rewritten_names: [],
      removed_entries: reaction_scan.removed_entries,
      flagged_conditions: [],
      stops: duplicate_stops ++ reaction_scan.stops
    }

    initial = plan_decision_briefing(initial)
    upstream = plan_upstream(initial)

    initial
    |> plan_archetypes()
    |> plan_scoped_files()
    |> plan_receipts(initial.removals)
    |> plan_manifests()
    |> plan_seed_reactions(seed_reactions, reaction_scan)
    |> plan_seed_rails(seed_rails)
    |> plan_rail_names()
    |> Map.put(:entries, entries)
    |> finalize_plan()
    |> Map.put(:upstream, upstream)
    |> then(fn plan ->
      %{
        plan
        | identity_changed?: plan.identity_changed? or upstream.identity_changed?,
          stops: plan.stops ++ upstream.stops,
          rewritten_names:
            plan.rewritten_names ++
              Enum.map(upstream.rewritten_names, &Map.put(&1, "ref", "tightbeam/upstream")),
          removed_entries:
            plan.removed_entries ++
              Enum.map(upstream.removed_entries, &Map.put(&1, "ref", "tightbeam/upstream")),
          flagged_conditions:
            plan.flagged_conditions ++
              Enum.map(upstream.flagged_conditions, &Map.put(&1, "ref", "tightbeam/upstream"))
      }
    end)
  end

  # 0.1.16 shipped this org-wide rule in an optional bundle. Preserve its
  # configured bytes as substrate law before applying kungfu scope isolation.
  defp plan_decision_briefing(plan) do
    source = "kungfu/harklight-decision-briefings/rules/briefings.toml"
    destination = "rules/harklight-decision-request-briefing.toml"

    if Map.has_key?(plan.entries, source) and not Map.has_key?(plan.entries, destination) do
      bytes = Map.fetch!(plan.entries, source)

      %{
        plan
        | entries: plan.entries |> Map.delete(source) |> Map.put(destination, bytes),
          removals: MapSet.put(plan.removals, source),
          removed_entries:
            plan.removed_entries ++ [%{"file" => source, "moved_to" => destination}]
      }
    else
      plan
    end
  end

  defp plan_upstream(main) do
    revision = git_output!(main.identity_dir, ["rev-parse", "tightbeam/upstream"])
    entries = tree_entries!(main.identity_dir, revision)

    seed_root =
      Application.get_env(
        :tightbeam,
        :identity_seed_dir,
        Application.app_dir(:tightbeam, "priv/seed")
      )

    # A flat item not claimed by the receipt belongs to the organization, even
    # if an older upstream snapshot once shipped a namesake. Remove it only
    # from the upstream baseline. The migrated main tree keeps the org bytes.
    removals =
      entries
      |> Enum.filter(fn {path, _} ->
        MapSet.member?(main.removals, path) or
          ((archetype_path?(path) or scoped_rail_path?(path)) and
             Map.get(main.owner_by_path, path, :substrate) == :substrate and
             not File.regular?(Path.join(seed_root, path)))
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    %{
      main
      | source_revision: revision,
        entries: Map.drop(entries, MapSet.to_list(removals)),
        writes: %{},
        removals: removals,
        rewritten_names: [],
        removed_entries: [],
        flagged_conditions: [],
        stops: []
    }
    |> plan_archetypes()
    |> plan_scoped_files()
    |> plan_manifests()
    |> Map.put(:entries, entries)
    |> finalize_plan()
  end

  defp preflight_repository!(dir) do
    unless File.dir?(Path.join(dir, ".git")),
      do:
        raise(ArgumentError, "identity repository is missing; rail scoping migration cannot run")

    branch = git_output!(dir, ["branch", "--show-current"])
    main = git_output!(dir, ["rev-parse", "main"])
    live = git_output!(dir, ["rev-parse", "tightbeam/live"])
    dirty = git_output!(dir, ["status", "--porcelain"])

    cond do
      branch != "main" ->
        raise ArgumentError, "identity migration requires main checked out (found #{branch})"

      dirty != "" ->
        raise ArgumentError, "identity migration requires a clean identity worktree"

      main != live ->
        raise ArgumentError, "identity migration requires main and tightbeam/live to match"

      true ->
        main
    end
  end

  defp tree_entries!(dir, revision) do
    git_output!(dir, ["ls-tree", "-r", "--name-only", revision])
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn path, entries ->
      if String.ends_with?(path, ".toml") or String.ends_with?(path, ".md") or
           String.ends_with?(path, ".json") do
        Map.put(entries, path, git_show_bytes!(dir, revision, path))
      else
        entries
      end
    end)
  end

  defp receipts_at!(dir, revision) do
    tree_entries!(dir, revision)
    |> Enum.filter(fn {path, _bytes} ->
      String.starts_with?(path, "kungfu/") and String.ends_with?(path, "/installed.toml")
    end)
    |> Enum.map(fn {path, bytes} ->
      receipt = Toml.decode!(bytes)
      name = Map.fetch!(receipt, "name")
      paths = Map.fetch!(receipt, "paths")

      unless is_binary(name) and is_list(paths) and Enum.all?(paths, &is_binary/1),
        do: raise(ArgumentError, "#{path}: invalid kungfu install receipt")

      %{name: name, path: path, data: receipt, paths: paths}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp receipt_claims(receipts) do
    Enum.reduce(receipts, %{}, fn receipt, claims ->
      Enum.reduce(receipt.paths, claims, fn path, claims ->
        normalized = normalize_path!(path)
        Map.update(claims, normalized, [receipt.name], &[receipt.name | &1])
      end)
    end)
    |> Map.new(fn {path, names} -> {path, Enum.uniq(names) |> Enum.sort()} end)
  end

  defp duplicate_claim_stops(claims) do
    for {path, owners} <- Enum.sort(claims), length(owners) > 1 do
      stop(
        "receipt",
        path,
        "receipt claims #{Enum.join(owners, " and ")}",
        "remove the duplicate path claim from one kungfu receipt"
      )
    end
  end

  defp owner_map(claims),
    do: Map.new(claims, fn {path, [owner | _]} -> {path, {:kungfu, owner}} end)

  defp archetype_index(entries, owners) do
    entries
    |> Enum.filter(fn {path, _} -> archetype_path?(path) end)
    |> Enum.group_by(fn {path, _bytes} -> Path.basename(path, ".toml") end)
    |> Map.new(fn {short, files} ->
      items =
        Enum.map(files, fn {path, bytes} ->
          %{path: path, owner: Map.get(owners, path, :substrate), bytes: bytes}
        end)

      {short, items}
    end)
  end

  defp build_name_map(archetypes) do
    Map.new(archetypes, fn {short, items} ->
      flat =
        Enum.find(items, fn item -> Path.split(item.path) == ["archetypes", short <> ".toml"] end)

      owners = items |> Enum.map(& &1.owner) |> Enum.uniq()

      qualified =
        cond do
          flat != nil -> Provenance.qualify(flat.owner, short)
          length(owners) == 1 -> Provenance.qualify(hd(owners), short)
          length(owners) > 1 -> :ambiguous
          true -> short
        end

      {short, qualified}
    end)
  end

  defp plan_archetypes(plan) do
    plan.entries
    |> Enum.filter(fn {path, _bytes} -> archetype_path?(path) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(plan, fn {source_path, bytes}, acc ->
      owner = Map.get(acc.owner_by_path, source_path, :substrate)

      owner_name =
        case owner do
          {:kungfu, name} -> name
          :substrate -> nil
        end

      destination = namespaced_path(source_path, owner_name)

      acc
      |> maybe_remove_moved_file(source_path, destination)
      |> put_file(destination, bytes)
      |> remember_owner(destination, owner)
    end)
  end

  defp plan_scoped_files(plan) do
    {plan, all_rail_names} =
      plan.entries
      |> Enum.filter(fn {path, _bytes} -> scoped_rail_path?(path) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({plan, []}, fn {source_path, bytes}, {acc, rail_names} ->
        owner = Map.get(acc.owner_by_path, source_path, :substrate)

        owner_name =
          case owner do
            {:kungfu, name} -> name
            :substrate -> nil
          end

        destination = namespaced_path(source_path, owner_name)
        short_names = archetype_names_for_owner(acc, owner_name)

        if MapSet.member?(acc.skip_paths, source_path) do
          {acc, rail_names}
        else
          case transform_rail_file(bytes, source_path, owner, short_names, acc.name_map) do
            {:ok, transformed, local} ->
              acc =
                acc
                |> maybe_remove_moved_file(source_path, destination)
                |> put_file(destination, transformed)
                |> remember_owner(destination, owner)
                |> add_changes(local)

              {acc, local.rail_names ++ rail_names}

            {:error, %{stops: _stops} = changes} ->
              acc = add_changes(acc, changes)
              {acc, rail_names}

            {:error, reason} ->
              stop = stop("rail", source_path, reason, owner_action(owner))
              {%{acc | stops: [stop | acc.stops]}, rail_names}
          end
        end
      end)

    %{plan | rail_map: build_rail_map(all_rail_names)}
  end

  defp transform_rail_file(bytes, path, owner, owned_archetypes, name_map) do
    data = Toml.decode!(bytes)
    rail_keys = Enum.filter(["rule", "policy", "reaction", "statute"], &Map.has_key?(data, &1))

    if rail_keys == [] do
      {:ok, bytes,
       %{rewritten_names: [], removed_entries: [], flagged_conditions: [], rail_names: []}}
    else
      {data, changes} =
        Enum.reduce(rail_keys, {data, empty_changes()}, fn key, {current, changes} ->
          rails = List.wrap(Map.get(current, key))

          {migrated, next_changes} =
            Enum.map_reduce(rails, empty_changes(), fn rail, local ->
              migrate_rail(rail, key, path, owner, owned_archetypes, name_map, local)
            end)

          migrated = Enum.reject(migrated, &is_nil/1)
          replacement = if is_list(Map.get(current, key)), do: migrated, else: hd(migrated)
          current = Map.put(current, key, replacement)
          {current, merge_changes(changes, next_changes)}
        end)

      if changes.stops == [] do
        {:ok, TomlEdit.update!(bytes, data), changes}
      else
        {:error, changes}
      end
    end
  rescue
    error -> {:error, "cannot preserve TOML: #{Exception.message(error)}"}
  end

  defp migrate_rail(rail, key, path, owner, owned_archetypes, name_map, changes)
       when is_map(rail) do
    name = Map.get(rail, "name", "<unnamed>")
    changes = %{changes | rail_names: [{name, owner} | changes.rail_names]}

    {rail, changes} =
      case owner do
        :substrate ->
          if agentless_rail?(key, rail) do
            {rail, changes}
          else
            {Map.put_new(rail, "archetypes", ["*"]), changes}
          end

        {:kungfu, _} ->
          {Map.put(
             rail,
             "archetypes",
             Enum.map(owned_archetypes, &Provenance.qualify(owner, &1))
           ), changes}
      end

    context = migration_context(key, rail)

    {rail, condition_changes} =
      transform_nested(rail, path, name, owner, owned_archetypes, name_map, context)

    changes = merge_changes(changes, condition_changes)
    {rail, changes}
  end

  defp migrate_rail(other, _key, _path, _owner, _owned, _name_map, changes), do: {other, changes}

  defp migration_context("rule", rail) do
    verbs = List.wrap(Map.get(rail, "verb")) ++ List.wrap(Map.get(rail, "verbs"))
    if "assign" in verbs, do: :assign_record_fact, else: :rule_participant_facts
  end

  defp migration_context(_key, _rail), do: :unsupported_expression

  defp transform_nested(value, path, rail_name, owner, owned, name_map, context)
       when is_map(value) do
    cond do
      condition_map?(value) ->
        transform_condition(value, path, rail_name, owner, owned, name_map, context)

      expression_comparison?(value) ->
        transform_expression(value, path, rail_name, owner, owned, name_map, context)

      true ->
        effective_context = context_for_nested_rule(value, context)

        Enum.reduce(value, {%{}, empty_changes()}, fn {key, child}, {result, changes} ->
          {child, local} =
            transform_nested(child, path, rail_name, owner, owned, name_map, effective_context)

          {Map.put(result, key, child), merge_changes(changes, local)}
        end)
        |> then(fn {result, changes} ->
          {result, validate_nonempty_condition_lists(result, changes, path, rail_name)}
        end)
    end
  end

  defp transform_expression(
         %{"op" => op, "args" => [left, right | rest]} = expression,
         path,
         rail_name,
         owner,
         owned,
         name_map,
         context
       )
       when op in ["eq", "ne", "in", "not_in"] do
    {fact, comparison_value, reversed?} =
      cond do
        is_binary(expression_ref(left)) ->
          {expression_ref(left), right, false}

        op in ["eq", "ne"] and is_binary(expression_ref(right)) ->
          {expression_ref(right), left, true}

        true ->
          {nil, nil, false}
      end

    if archetype_fact?(fact) do
      case transform_comparison(
             fact,
             op,
             comparison_value,
             owner,
             owned,
             name_map,
             :unsupported_expression
           ) do
        {:keep, new_value, description, rewrites} ->
          args = if reversed?, do: [new_value, right | rest], else: [left, new_value | rest]
          {Map.put(expression, "args", args), flag(path, rail_name, description, rewrites)}

        {:remove, description, rewrites} ->
          local = flag(path, rail_name, description, rewrites)

          stop =
            stop(
              rail_name,
              path,
              "#{rail_name}: unsupported expression cannot remove a foreign comparison",
              owner_action(owner)
            )

          {expression, %{local | stops: local.stops ++ [stop]}}

        {:stop, description} ->
          stop = stop(rail_name, path, "#{rail_name}: #{description}", owner_action(owner))
          {expression, %{empty_changes() | stops: [stop]}}
      end
    else
      transform_nested_map(expression, path, rail_name, owner, owned, name_map, context)
    end
  end

  defp transform_expression(expression, path, rail_name, owner, owned, name_map, context),
    do: transform_nested_map(expression, path, rail_name, owner, owned, name_map, context)

  defp transform_nested_map(value, path, rail_name, owner, owned, name_map, context) do
    Enum.reduce(value, {%{}, empty_changes()}, fn {key, child}, {result, changes} ->
      {child, local} = transform_nested(child, path, rail_name, owner, owned, name_map, context)
      {Map.put(result, key, child), merge_changes(changes, local)}
    end)
  end

  defp context_for_nested_rule(map, :rule_participant_facts) do
    verbs = List.wrap(Map.get(map, "verb")) ++ List.wrap(Map.get(map, "verbs"))
    if "assign" in verbs, do: :assign_record_fact, else: :rule_participant_facts
  end

  defp context_for_nested_rule(_map, context), do: context

  defp expression_comparison?(%{"op" => op, "args" => args})
       when op in ["eq", "ne", "in", "not_in"] and is_list(args),
       do: length(args) >= 2

  defp expression_comparison?(_), do: false
  defp expression_ref(%{"ref" => ref}) when is_binary(ref), do: ref
  defp expression_ref(_), do: nil

  defp archetype_fact?(fact) when is_binary(fact),
    do: fact in @participant_facts or String.ends_with?(fact, ".archetype")

  defp archetype_fact?(_fact), do: false

  defp transform_nested(value, path, rail_name, owner, owned, name_map, context)
       when is_list(value) do
    {values, changes} =
      Enum.map_reduce(value, empty_changes(), fn child, changes ->
        {child, local} = transform_nested(child, path, rail_name, owner, owned, name_map, context)
        {child, merge_changes(changes, local)}
      end)

    {Enum.reject(values, &(&1 == :remove_condition)), changes}
  end

  defp transform_nested(value, _path, _rail_name, _owner, _owned, _name_map, _context),
    do: {value, empty_changes()}

  defp transform_condition(condition, path, rail_name, owner, owned, name_map, context) do
    fact = Map.get(condition, "fact")
    op = Map.get(condition, "op")
    value = Map.get(condition, "value")

    case transform_comparison(fact, op, value, owner, owned, name_map, context) do
      {:keep, new_value, nil, []} ->
        {Map.put(condition, "value", new_value), empty_changes()}

      {:keep, new_value, description, rewrites} ->
        {Map.put(condition, "value", new_value), flag(path, rail_name, description, rewrites)}

      {:remove, description, rewrites} ->
        {:remove_condition,
         flag(path, rail_name, description, rewrites, [
           %{"rail" => rail_name, "file" => path, "condition" => condition}
         ])}

      {:stop, description} ->
        stop = stop(rail_name, path, "#{rail_name}: #{description}", owner_action(owner))
        {condition, %{empty_changes() | stops: [stop]}}
    end
  end

  defp transform_comparison(fact, op, value, owner, owned, name_map, context) do
    archetype_fact? = archetype_fact?(fact)

    if not archetype_fact? or op not in ["eq", "ne", "in", "not_in"] do
      {:keep, value, nil, []}
    else
      allowed = MapSet.new(Enum.map(owned, &Provenance.qualify(owner, &1)))
      values = if op in ["in", "not_in"] and is_list(value), do: value, else: [value]
      mapped = Enum.map(values, &Map.get(name_map, &1, &1))

      if :ambiguous in mapped do
        {:stop,
         "comparison #{fact} #{op} #{inspect(value)} refers to an ambiguous bare archetype name"}
      else
        foreign = Enum.reject(mapped, &MapSet.member?(allowed, &1))

        participant? =
          fact in @participant_facts and
            not (fact == "assignment.holder_archetype" and context == :assign_record_fact)

        rewrites =
          values
          |> Enum.zip(mapped)
          |> Enum.reject(fn {from, to} -> from == to end)
          |> Enum.map(fn {from, to} -> %{"fact" => fact, "from" => from, "to" => to} end)

        rewrite_text =
          if rewrites == [],
            do: nil,
            else: "#{fact} #{op} qualified #{inspect(values)} as #{inspect(mapped)}"

        case owner do
          :substrate ->
            next = if op in ["in", "not_in"] and is_list(value), do: mapped, else: hd(mapped)
            {:keep, next, rewrite_text, rewrites}

          {:kungfu, _} when foreign == [] ->
            next = if op in ["in", "not_in"] and is_list(value), do: mapped, else: hd(mapped)
            {:keep, next, rewrite_text, rewrites}

          {:kungfu, _} when context == :unsupported_expression ->
            {:stop,
             "comparison #{fact} #{op} #{inspect(value)} is a foreign archetype comparison in an unsupported policy or reaction expression"}

          {:kungfu, _} when not participant? ->
            {:stop,
             "comparison #{fact} #{op} #{inspect(value)} is a foreign archetype comparison on a record fact"}

          {:kungfu, _} ->
            preserve_participant_comparison(fact, op, value, mapped, foreign, allowed, rewrites)
        end
      end
    end
  end

  defp preserve_participant_comparison(fact, "in", value, mapped, _foreign, allowed, rewrites)
       when is_list(value) do
    retained = Enum.filter(mapped, &MapSet.member?(allowed, &1))

    if retained == [],
      do:
        {:stop,
         "comparison #{fact} in #{inspect(value)} is always false for the owning kungfu because the in-scope set is empty"},
      else:
        {:keep, retained, "#{fact} in #{inspect(value)} narrowed to #{inspect(retained)}",
         rewrites}
  end

  defp preserve_participant_comparison(fact, "not_in", value, mapped, _foreign, allowed, rewrites)
       when is_list(value) do
    retained = Enum.filter(mapped, &MapSet.member?(allowed, &1))

    if retained == [],
      do:
        {:remove,
         "#{fact} not_in #{inspect(value)} removed because the foreign-only comparison was always true",
         rewrites},
      else:
        {:keep, retained, "#{fact} not_in #{inspect(value)} narrowed to #{inspect(retained)}",
         rewrites}
  end

  defp preserve_participant_comparison(fact, "eq", value, _mapped, _foreign, _allowed, _name_map),
    do: {:stop, "comparison #{fact} eq #{inspect(value)} is always false for the owning kungfu"}

  defp preserve_participant_comparison(fact, "ne", value, _mapped, _foreign, _allowed, rewrites),
    do:
      {:remove,
       "#{fact} ne #{inspect(value)} removed because the foreign comparison was always true",
       rewrites}

  defp validate_nonempty_condition_lists(map, changes, path, rail_name) do
    Enum.reduce(map, changes, fn
      {key, []}, current when key in ["deny_when", "conditions", "when"] ->
        stop =
          stop(
            "rail",
            path,
            "#{rail_name}: removing foreign comparisons emptied required #{key}",
            "review the rail's required condition list and author its intended in-scope behavior"
          )

        %{current | stops: [stop | current.stops]}

      {_key, _value}, current ->
        current
    end)
  end

  defp plan_receipts(plan, removed_paths) do
    {writes, changed} =
      Enum.reduce(plan.receipts, {plan.writes, []}, fn receipt, {writes, changed} ->
        paths =
          receipt.paths
          |> Enum.map(&normalize_path!/1)
          |> Enum.reject(&MapSet.member?(removed_paths, &1))
          |> Enum.map(fn path ->
            case Map.get(plan.owner_by_path, path) do
              {:kungfu, owner} -> namespaced_path(path, owner)
              _ -> path
            end
          end)
          |> Enum.uniq()

        if paths == receipt.paths do
          {writes, changed}
        else
          data = Map.put(receipt.data, "paths", paths)

          {Map.put(
             writes,
             receipt.path,
             TomlEdit.update!(Map.fetch!(plan.entries, receipt.path), data)
           ), [receipt.name | changed]}
        end
      end)

    rewritten =
      Enum.map(changed, fn owner ->
        %{
          "kind" => "receipt",
          "from" => "flat paths",
          "to" => "namespaced paths",
          "owner" => owner
        }
      end)

    %{plan | writes: writes, rewritten_names: plan.rewritten_names ++ rewritten}
  end

  defp plan_manifests(plan) do
    plan.entries
    |> Enum.filter(fn {path, _} -> manifest_path?(path) end)
    |> Enum.reduce(plan, fn {path, bytes}, acc ->
      data = Toml.decode!(bytes)
      owner = Map.get(acc.owner_by_path, path, :substrate)
      {data, changes} = qualify_manifest_refs(data, path, owner, acc.name_map, acc.archetypes)
      add_changes(put_file(acc, path, TomlEdit.update!(bytes, data)), changes)
    end)
  end

  defp plan_seed_reactions(plan, seed_reactions, reaction_scan) do
    substrate_reactions = substrate_reaction_index(plan)

    Enum.reduce(@seed_reactions, plan, fn {name, relative}, acc ->
      existing = Map.get(substrate_reactions, name, [])

      cond do
        length(existing) > 1 ->
          stop =
            stop(
              "reaction",
              Enum.join(existing, ", "),
              name,
              "keep exactly one substrate definition of this reaction"
            )

          %{acc | stops: [stop | acc.stops]}

        existing == [] ->
          case Map.fetch(seed_reactions, relative) do
            {:ok, bytes} ->
              destination = "rules/#{Path.basename(relative)}"

              if Map.has_key?(merged_entries(acc), destination) do
                stop =
                  stop(
                    "reaction",
                    destination,
                    "a non-reaction file occupies the seed path for #{name}",
                    "move or rename the conflicting substrate file, then rerun the migration"
                  )

                %{acc | stops: [stop | acc.stops]}
              else
                put_file(acc, destination, add_wildcard_to_reaction(bytes))
              end

            :error ->
              stop =
                stop(
                  "reaction",
                  relative,
                  "required seed reaction is missing",
                  "restore the shipped substrate reaction file"
                )

              %{acc | stops: [stop | acc.stops]}
          end

        true ->
          existing_path = hd(existing)
          bytes = Map.get(acc.writes, existing_path, Map.fetch!(acc.entries, existing_path))
          put_file(acc, existing_path, add_wildcard_to_reaction(bytes))
      end
    end)
    |> Map.update!(:removals, &MapSet.union(&1, reaction_scan.removed_paths))
  end

  defp plan_seed_rails(plan, seed_rails) do
    substrate_statutes = substrate_statute_index(plan)

    Enum.reduce(@seed_rails, plan, fn {name, relative}, acc ->
      existing = Map.get(substrate_statutes, name, [])

      case Map.fetch(seed_rails, relative) do
        :error ->
          stop =
            stop(
              "statute",
              relative,
              "required seed statute is missing",
              "restore the shipped substrate statute file"
            )

          %{acc | stops: [stop | acc.stops]}

        {:ok, bytes} ->
          cond do
            not valid_seed_statute?(bytes, name) ->
              stop =
                stop(
                  "statute",
                  relative,
                  "required seed file does not define #{name} for all archetypes",
                  "restore the shipped substrate statute file"
                )

              %{acc | stops: [stop | acc.stops]}

            length(existing) > 1 ->
              stop =
                stop(
                  "statute",
                  Enum.join(existing, ", "),
                  name,
                  "keep exactly one substrate definition of this statute"
                )

              %{acc | stops: [stop | acc.stops]}

            existing == [] ->
              destination = "rails/#{Path.basename(relative)}"

              if Map.has_key?(merged_entries(acc), destination) do
                stop =
                  stop(
                    "statute",
                    destination,
                    "a different file occupies the seed path for #{name}",
                    "move or rename the conflicting substrate file, then rerun the migration"
                  )

                %{acc | stops: [stop | acc.stops]}
              else
                put_file(acc, destination, bytes)
              end

            true ->
              acc
          end
      end
    end)
  end

  defp substrate_statute_index(plan) do
    merged_entries(plan)
    |> Enum.filter(fn {path, _bytes} ->
      scoped_rail_path?(path) and owner_for_destination(plan, path) == :substrate
    end)
    |> Enum.reduce(%{}, fn {path, bytes}, index ->
      case Toml.decode(bytes) do
        {:ok, data} ->
          data
          |> Map.get("statute", [])
          |> List.wrap()
          |> Enum.reduce(index, fn
            %{"name" => name}, current when is_binary(name) ->
              Map.update(current, name, [path], &[path | &1])

            _statute, current ->
              current
          end)

        _ ->
          index
      end
    end)
  end

  defp valid_seed_statute?(bytes, name) do
    case Toml.decode(bytes) do
      {:ok, %{"statute" => [statute]}} when is_map(statute) ->
        Map.get(statute, "name") == name and Map.get(statute, "archetypes") == ["*"]

      _ ->
        false
    end
  end

  defp plan_rail_names(plan) do
    current = merged_entries(plan)

    names =
      current
      |> Enum.filter(fn {path, _} ->
        scoped_rail_path?(path) and not MapSet.member?(plan.removals, path)
      end)
      |> Enum.flat_map(fn {path, bytes} ->
        owner = Map.get(plan.owner_by_path, path, owner_for_destination(plan, path))

        case Toml.decode(bytes) do
          {:ok, data} ->
            Enum.flat_map(["rule", "policy", "reaction", "statute"], fn kind ->
              data
              |> Map.get(kind, [])
              |> List.wrap()
              |> Enum.map(fn rail -> {Map.get(rail, "name"), owner} end)
            end)

          _ ->
            []
        end
      end)
      |> Enum.reject(fn {name, _} -> not is_binary(name) end)

    map =
      names
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {short, owners} ->
        owners = Enum.uniq(owners)

        {short,
         if(length(owners) == 1, do: Provenance.qualify(hd(owners), short), else: :ambiguous)}
      end)

    # Short rail names may legitimately coexist across sources. Keep them
    # ambiguous in the lookup so only an active legacy bare reference stops;
    # duplicate declarations alone are valid under the qualified namespace.
    %{plan | rail_map: map}
  end

  defp finalize_plan(plan) do
    writes =
      Enum.reject(plan.writes, fn {path, bytes} -> Map.get(plan.entries, path) == bytes end)
      |> Map.new()

    removals = Enum.reject(plan.removals, &is_nil/1) |> MapSet.new()
    identity_changed? = writes != %{} or removals != MapSet.new()

    Map.merge(plan, %{
      writes: writes,
      removals: removals,
      identity_changed?: identity_changed?,
      result_revision: nil
    })
  end

  defp apply_identity_plan!(dir, plan, prior) do
    upstream = migrate_upstream!(dir, plan.upstream)
    write_identity_plan!(dir, plan)
    git!(dir, ["add", "-A"])
    tree = git_output!(dir, ["write-tree"])

    # Recording both parents is essential: subsequent relearn must compare the
    # org tree against the migrated upstream, never the old flat namespace.
    parents =
      if upstream == plan.upstream.source_revision,
        do: ["-p", prior],
        else: ["-p", prior, "-p", upstream]

    candidate =
      git_output!(
        dir,
        [
          "-c",
          "user.name=tightbeam",
          "-c",
          "user.email=tightbeam@localhost",
          "commit-tree",
          tree
        ] ++ parents ++ ["-m", "identity: scope kungfu rails"]
      )

    git!(dir, ["reset", "--hard", candidate])

    git!(dir, [
      "update-ref",
      "refs/heads/tightbeam/upstream",
      upstream,
      plan.upstream.source_revision
    ])

    candidate
  end

  defp write_identity_plan!(dir, plan) do
    Enum.each(plan.removals, fn path -> File.rm!(Path.join(dir, path)) end)

    Enum.each(plan.writes, fn {path, bytes} ->
      destination = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, bytes)
    end)
  end

  defp migrate_upstream!(_dir, %{identity_changed?: false, source_revision: revision}),
    do: revision

  defp migrate_upstream!(dir, plan) do
    scratch =
      Path.join(System.tmp_dir!(), "rail-scope-upstream-#{System.unique_integer([:positive])}")

    git!(dir, ["worktree", "add", "--detach", scratch, plan.source_revision])

    try do
      write_identity_plan!(scratch, plan)
      git!(scratch, ["add", "-A"])
      git!(scratch, ["commit", "-m", "identity: namespace upstream rail baseline"], "tightbeam")
      git_output!(scratch, ["rev-parse", "HEAD"])
    after
      git!(dir, ["worktree", "remove", "--force", scratch])
    end
  end

  defp publish_identity!(_base_dir, prior, candidate) when prior == candidate, do: :ok

  defp publish_identity!(base_dir, prior, candidate) do
    case Identity.publish_live!(base_dir, %{candidate_revision: candidate, expected_prior: prior}) do
      {:ok, _revision} -> :ok
      {:error, error} -> raise ArgumentError, "identity publication failed: #{inspect(error)}"
    end
  end

  defp rollback_identity!(dir, prior, plan) do
    git!(dir, ["reset", "--hard", prior])

    Enum.each(plan.writes, fn {path, _bytes} ->
      unless Map.has_key?(plan.entries, path) do
        case File.rm(Path.join(dir, path)) do
          :ok ->
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            raise "cannot remove rolled-back migration file #{path}: #{reason}"
        end
      end
    end)

    git!(dir, ["update-ref", "refs/heads/tightbeam/live", prior])
    git!(dir, ["update-ref", "refs/heads/tightbeam/upstream", plan.upstream.source_revision])
    :ok
  end

  defp migrate_rows!(txn, name_map, rail_map, reaction_names) do
    migrate_sessions!(txn, name_map) ++
      migrate_default_archetype!(txn, name_map) ++
      migrate_subtree_guidance!(txn, name_map) ++
      migrate_rail_state!(txn, rail_map, reaction_names)
  end

  defp migrate_sessions!(txn, name_map) do
    for [session_key, archetype] <-
          Txn.q(txn, "SELECT sessionKey,archetype FROM sessions ORDER BY sessionKey"),
        Map.has_key?(name_map, archetype),
        next = qualified_name!(name_map, archetype),
        is_binary(next) and next != archetype do
      Txn.q(txn, "UPDATE sessions SET archetype=?2 WHERE sessionKey=?1", [session_key, next])
      %{"kind" => "session", "from" => archetype, "to" => next}
    end
  end

  defp migrate_default_archetype!(txn, name_map) do
    case Txn.q(txn, "SELECT value FROM org_settings WHERE key='default-archetype'") do
      [[value]] ->
        next = qualified_name!(name_map, value)

        if is_binary(next) and next != value do
          Txn.q(txn, "UPDATE org_settings SET value=?1 WHERE key='default-archetype'", [next])

          [
            %{
              "kind" => "org-setting",
              "name" => "default-archetype",
              "from" => value,
              "to" => next
            }
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  defp migrate_subtree_guidance!(txn, name_map) do
    for [writer, name, archetypes] <-
          Txn.q(
            txn,
            "SELECT writerSessionKey,name,archetypes FROM subtree_guidance_entries WHERE archetypes IS NOT NULL ORDER BY writerSessionKey,name"
          ) do
      decoded = JSON.decode!(archetypes)

      unless is_list(decoded) and Enum.all?(decoded, &is_binary/1),
        do: raise(ArgumentError, "subtree guidance archetype scope is not a JSON string list")

      next = Enum.map(decoded, &qualified_name!(name_map, &1))

      if next != decoded do
        Txn.q(
          txn,
          "UPDATE subtree_guidance_entries SET archetypes=?3 WHERE writerSessionKey=?1 AND name=?2",
          [writer, name, JSON.encode!(next)]
        )

        %{"kind" => "subtree-guidance", "name" => name, "from" => decoded, "to" => next}
      else
        nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp migrate_rail_state!(txn, rail_map, reaction_names) do
    migrate_statute_column!(
      txn,
      "rail_remedy_episodes",
      "statute",
      "status IN ('claimed','dispatched','live')",
      rail_map,
      "remedy-episode"
    ) ++
      migrate_statute_column!(
        txn,
        "escalation_waivers",
        "statuteName",
        "revokedAt IS NULL",
        rail_map,
        "waiver"
      ) ++
      Enum.flat_map(@recurrence_tables, fn table ->
        migrate_statute_column!(txn, table, "statute", "1=1", rail_map, table)
      end) ++
      migrate_wakes!(txn, rail_map, reaction_names) ++
      migrate_open_decision_requests!(txn, rail_map)
  end

  defp migrate_open_decision_requests!(txn, rail_map) do
    for [id, name] <-
          Txn.q(
            txn,
            "SELECT id,statuteName FROM decision_requests WHERE kind='statute' AND status='open' AND statuteName IS NOT NULL"
          ) do
      case Map.get(rail_map, name) do
        next when is_binary(next) and next != name ->
          Txn.q(txn, "UPDATE decision_requests SET statuteName=?2 WHERE id=?1", [id, next])
          %{"kind" => "decision-request", "from" => name, "to" => next}

        :ambiguous ->
          raise ArgumentError, "open decision request names ambiguous rail #{name}"

        _ ->
          nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp migrate_statute_column!(txn, table, column, where, rail_map, kind) do
    for [rowid, name] <- Txn.q(txn, "SELECT rowid,#{column} FROM #{table} WHERE #{where}") do
      case Map.get(rail_map, name) do
        next when is_binary(next) and next != name ->
          Txn.q(txn, "UPDATE #{table} SET #{column}=?2 WHERE rowid=?1", [rowid, next])
          %{"kind" => kind, "from" => name, "to" => next}

        :ambiguous ->
          raise ArgumentError, "active rail state names ambiguous rail #{name}"

        _ ->
          nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp migrate_wakes!(txn, rail_map, reaction_names) do
    for [wake_id, delivery_rule, selected_policy, origin] <-
          Txn.q(
            txn,
            "SELECT wakeId,deliveryRule,selectedPolicyName,origin FROM wakes WHERE state='pending'"
          ) do
      next_delivery = migrate_rail_name(delivery_rule, rail_map, reaction_names)
      next_policy = migrate_rail_name(selected_policy, rail_map, reaction_names)
      next_origin = migrate_remedy_origin(origin, rail_map, reaction_names)

      if {delivery_rule, selected_policy, origin} != {next_delivery, next_policy, next_origin} do
        Txn.q(
          txn,
          "UPDATE wakes SET deliveryRule=?2,selectedPolicyName=?3,origin=?4 WHERE wakeId=?1",
          [wake_id, next_delivery, next_policy, next_origin]
        )

        %{
          "kind" => "wake",
          "from" => [delivery_rule, selected_policy, origin],
          "to" => [next_delivery, next_policy, next_origin]
        }
      else
        nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp migrate_rail_name(nil, _rail_map, _reactions), do: nil

  defp migrate_rail_name(name, rail_map, reaction_names) do
    short_name = name |> String.split(".") |> List.last()

    cond do
      name in reaction_names ->
        name

      short_name in reaction_names and short_name != name ->
        short_name

      String.contains?(name, ".") ->
        name

      true ->
        case Map.get(rail_map, name, name) do
          :ambiguous -> raise ArgumentError, "pending wake names ambiguous rail #{name}"
          next -> next
        end
    end
  end

  defp migrate_remedy_origin("remedy:" <> name, rail_map, reaction_names),
    do: "remedy:" <> migrate_rail_name(name, rail_map, reaction_names)

  defp migrate_remedy_origin(origin, _rail_map, _reaction_names), do: origin

  defp report(plan, revision, status) do
    %{
      "schema" => "tightbeam-rail-scope-migration/v1",
      "status" => status,
      "source_revision" => revision,
      "result_revision" => Map.get(plan, :result_revision),
      "rewritten_names" => Enum.sort_by(plan.rewritten_names, &JSON.encode!/1),
      "removed_entries" => Enum.sort_by(plan.removed_entries, &JSON.encode!/1),
      "flagged_conditions" => Enum.sort_by(plan.flagged_conditions, &JSON.encode!/1),
      "stops" => Enum.sort_by(plan.stops, &JSON.encode!/1)
    }
  end

  defp write_failure_report!(path, revision, error) do
    failure = %{
      "schema" => "tightbeam-rail-scope-migration/v1",
      "status" => "stopped",
      "source_revision" => revision,
      "result_revision" => nil,
      "rewritten_names" => [],
      "removed_entries" => [],
      "flagged_conditions" => [],
      "stops" => [
        stop(
          "migration",
          "identity",
          Exception.message(error),
          "repair the reported identity state, then rerun the migration"
        )
      ]
    }

    write_report!(path, failure)
  end

  defp write_report!(path, report) do
    File.mkdir_p!(Path.dirname(path))
    bytes = JSON.encode!(report) <> "\n"
    if File.read(path) != {:ok, bytes}, do: File.write!(path, bytes)
  end

  defp stop_summary(stops) do
    Enum.map_join(stops, "; ", fn
      %{"comparison" => comparison} when is_binary(comparison) -> comparison
      stop -> inspect(stop)
    end)
  end

  defp stop(kind, path, comparison, action),
    do: %{"rail" => kind, "file" => path, "comparison" => comparison, "owner_action" => action}

  defp owner_action({:kungfu, _}),
    do: "rewrite or remove the rule in the kungfu source, or re-author it as substrate TOML"

  defp owner_action(:substrate),
    do: "rewrite the substrate TOML without changing its intended archetype reference"

  defp namespaced_path(path, nil), do: path

  defp namespaced_path(path, owner) do
    case Path.split(path) do
      [kind | rest] when kind in ["archetypes", "rules", "rails"] ->
        Path.join(["kungfu", owner, kind | rest])

      ["kungfu", ^owner, kind | _] when kind in ["archetypes", "rules", "rails"] ->
        path

      ["kungfu", _current_owner, kind | rest] when kind in ["archetypes", "rules", "rails"] ->
        Path.join(["kungfu", owner, kind | rest])

      _ ->
        path
    end
  end

  defp maybe_remove_moved_file(plan, source, destination) when source == destination, do: plan

  defp maybe_remove_moved_file(plan, source, destination) do
    if Map.has_key?(plan.entries, destination) or Map.has_key?(plan.writes, destination) do
      stop =
        stop(
          "path",
          destination,
          "namespaced destination already exists while moving #{source}",
          "resolve the path collision while preserving both source files"
        )

      %{plan | stops: [stop | plan.stops]}
    else
      entry = %{"file" => source, "moved_to" => destination}

      %{
        plan
        | removals: MapSet.put(plan.removals, source),
          removed_entries: plan.removed_entries ++ [entry]
      }
    end
  end

  defp put_file(plan, path, bytes), do: %{plan | writes: Map.put(plan.writes, path, bytes)}

  defp remember_owner(plan, path, {:kungfu, _name} = owner),
    do: %{plan | owner_by_path: Map.put(plan.owner_by_path, path, owner)}

  defp remember_owner(plan, _path, :substrate), do: plan

  defp add_changes(plan, changes) do
    %{
      plan
      | rewritten_names: plan.rewritten_names ++ changes.rewritten_names,
        removed_entries: plan.removed_entries ++ changes.removed_entries,
        flagged_conditions: plan.flagged_conditions ++ changes.flagged_conditions,
        stops: plan.stops ++ changes.stops
    }
  end

  defp empty_changes,
    do: %{
      rewritten_names: [],
      removed_entries: [],
      flagged_conditions: [],
      stops: [],
      rail_names: []
    }

  defp merge_changes(left, right) do
    Enum.reduce(
      [:rewritten_names, :removed_entries, :flagged_conditions, :stops, :rail_names],
      left,
      fn key, acc ->
        Map.update!(acc, key, &(&1 ++ Map.get(right, key, [])))
      end
    )
  end

  defp flag(path, rail, description, rewrites, removed \\ []) do
    changes =
      if is_nil(description) do
        empty_changes()
      else
        %{
          empty_changes()
          | flagged_conditions: [%{"rail" => rail, "file" => path, "comparison" => description}]
        }
      end

    %{changes | rewritten_names: rewrites, removed_entries: removed}
  end

  defp agentless_rail?("reaction", %{"settings" => _}), do: true
  defp agentless_rail?(_kind, _rail), do: false

  defp condition_map?(map),
    do: Map.has_key?(map, "fact") and Map.has_key?(map, "op") and Map.has_key?(map, "value")

  defp archetype_path?(path) do
    path = normalize_path!(path)

    case Path.split(path) do
      ["archetypes", file] -> String.ends_with?(file, ".toml")
      ["kungfu", _name, "archetypes", file] -> String.ends_with?(file, ".toml")
      _ -> false
    end
  end

  defp scoped_rail_path?(path) do
    case Path.split(normalize_path!(path)) do
      [kind, file] when kind in ["rules", "rails"] ->
        String.ends_with?(file, ".toml")

      ["kungfu", _name, kind, file] when kind in ["rules", "rails"] ->
        String.ends_with?(file, ".toml")

      _ ->
        false
    end
  end

  defp manifest_path?(path) do
    case Path.split(path) do
      ["kungfu", _name, "manifest.toml"] -> true
      _ -> false
    end
  end

  defp normalize_path!(path) do
    parts = path |> String.replace("\\", "/") |> Path.split()

    parts =
      case parts do
        ["identity" | rest] -> rest
        _ -> parts
      end

    Path.join(parts)
  end

  defp qualified_name!(name_map, name) do
    case Map.get(name_map, name, name) do
      :ambiguous ->
        raise ArgumentError,
              "stored archetype #{name} has multiple kungfu candidates and no substrate file"

      value ->
        value
    end
  end

  defp archetype_names_for_owner(_plan, nil), do: []

  defp archetype_names_for_owner(plan, owner) do
    plan.archetypes
    |> Enum.flat_map(fn {short, items} ->
      if Enum.any?(items, &(&1.owner == {:kungfu, owner})), do: [short], else: []
    end)
    |> Enum.sort()
  end

  defp owner_for_destination(plan, path) do
    Map.get(plan.owner_by_path, path, :substrate)
  end

  defp merged_entries(plan) do
    plan.entries
    |> Map.drop(MapSet.to_list(plan.removals))
    |> Map.merge(plan.writes)
  end

  defp build_rail_map(names) do
    names
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {short, owners} ->
      owners = Enum.uniq(owners)

      {short,
       if(length(owners) == 1, do: Provenance.qualify(hd(owners), short), else: :ambiguous)}
    end)
  end

  defp qualify_manifest_refs(data, path, owner, name_map, archetypes) do
    Enum.reduce(data, {data, empty_changes()}, fn {key, value}, {current, changes} ->
      if key in ["root_archetype", "archetypes"] do
        values = if is_list(value), do: value, else: [value]

        mapped =
          Enum.map(values, fn
            name when is_binary(name) ->
              next = manifest_archetype_name(name, owner, name_map, archetypes)

              local =
                cond do
                  next == :ambiguous ->
                    stop =
                      stop(
                        "manifest",
                        path,
                        "reference #{name} has multiple kungfu candidates and no substrate file",
                        "add a substrate archetype or resolve the manifest reference explicitly"
                      )

                    %{empty_changes() | stops: [stop]}

                  next != name ->
                    %{
                      empty_changes()
                      | rewritten_names: [%{"file" => path, "from" => name, "to" => next}]
                    }

                  true ->
                    empty_changes()
                end

              next = if next == :ambiguous, do: name, else: next

              {next, local}

            other ->
              {other, empty_changes()}
          end)

        next_values = Enum.map(mapped, &elem(&1, 0))

        local =
          Enum.reduce(mapped, empty_changes(), fn {_name, next}, acc ->
            merge_changes(acc, next)
          end)

        next_value = if is_list(value), do: next_values, else: List.first(next_values)
        {Map.put(current, key, next_value), merge_changes(changes, local)}
      else
        {Map.put(current, key, value), changes}
      end
    end)
  end

  defp manifest_archetype_name(short, {:kungfu, owner}, name_map, archetypes) do
    if Enum.any?(Map.get(archetypes, short, []), &(&1.owner == {:kungfu, owner})),
      do: Provenance.qualify({:kungfu, owner}, short),
      else: Map.get(name_map, short, short)
  end

  defp manifest_archetype_name(name, _owner, name_map, _archetypes),
    do: Map.get(name_map, name, name)

  defp find_legacy_reactions(entries, receipts, owners) do
    receipts
    |> Enum.flat_map(fn receipt -> Enum.map(receipt.paths, &{receipt, normalize_path!(&1)}) end)
    |> Enum.filter(fn {_receipt, path} -> legacy_reaction_path?(path) end)
    |> Enum.reduce(
      %{
        removed_paths: MapSet.new(),
        candidate_paths: MapSet.new(),
        removed_entries: [],
        stops: []
      },
      fn {receipt, path}, acc ->
        bytes = Map.get(entries, path)
        hash = if is_binary(bytes), do: sha256(bytes), else: nil
        acc = %{acc | candidate_paths: MapSet.put(acc.candidate_paths, path)}

        cond do
          is_nil(bytes) ->
            item =
              stop(
                "reaction",
                path,
                "receipt-owned legacy reaction is missing",
                owner_action({:kungfu, receipt.name})
              )

            %{acc | stops: [item | acc.stops]}

          Map.get(owners, path) != {:kungfu, receipt.name} ->
            item =
              stop(
                "reaction",
                path,
                "legacy reaction provenance is ambiguous",
                owner_action({:kungfu, receipt.name})
              )

            %{acc | stops: [item | acc.stops]}

          Map.has_key?(@legacy_reaction_hashes, hash) ->
            name = Map.fetch!(@legacy_reaction_hashes, hash)
            entry = %{"file" => path, "name" => name, "owner" => receipt.name}

            %{
              acc
              | removed_paths: MapSet.put(acc.removed_paths, path),
                removed_entries: [entry | acc.removed_entries]
            }

          true ->
            item =
              stop(
                "reaction",
                path,
                "kungfu reaction was edited; carry the edit into substrate TOML or discard it",
                owner_action({:kungfu, receipt.name})
              )

            %{acc | stops: [item | acc.stops]}
        end
      end
    )
    |> Map.update!(:removed_entries, &Enum.sort_by(&1, fn entry -> entry["file"] end))
  end

  defp legacy_reaction_path?(path) do
    Path.basename(path) in @legacy_reaction_files
  end

  defp seed_reaction_entries do
    root =
      Application.get_env(
        :tightbeam,
        :identity_seed_dir,
        Application.app_dir(:tightbeam, "priv/seed")
      )

    Enum.reduce(@seed_reactions, %{}, fn {_name, path}, acc ->
      full = Path.join(root, path)
      if File.regular?(full), do: Map.put(acc, path, File.read!(full)), else: acc
    end)
  end

  defp seed_rail_entries do
    root =
      Application.get_env(
        :tightbeam,
        :identity_seed_dir,
        Application.app_dir(:tightbeam, "priv/seed")
      )

    Enum.reduce(@seed_rails, %{}, fn {_name, path}, acc ->
      full = Path.join(root, path)
      if File.regular?(full), do: Map.put(acc, path, File.read!(full)), else: acc
    end)
  end

  defp substrate_reaction_index(plan) do
    merged_entries(plan)
    |> Enum.filter(fn {path, _} ->
      scoped_rail_path?(path) and owner_for_destination(plan, path) == :substrate
    end)
    |> Enum.reduce(%{}, fn {path, bytes}, index ->
      case Toml.decode(bytes) do
        {:ok, data} ->
          data
          |> Map.get("reaction", [])
          |> List.wrap()
          |> Enum.reduce(index, fn reaction, index ->
            Map.update(index, Map.get(reaction, "name"), [path], &[path | &1])
          end)

        _ ->
          index
      end
    end)
  end

  defp add_wildcard_to_reaction(bytes) do
    data = Toml.decode!(bytes)

    reactions =
      Map.fetch!(data, "reaction") |> List.wrap() |> Enum.map(&Map.put(&1, "archetypes", ["*"]))

    replacement = if is_list(data["reaction"]), do: reactions, else: hd(reactions)
    TomlEdit.update!(bytes, Map.put(data, "reaction", replacement))
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp git_show_bytes!(dir, revision, path) do
    case System.cmd("git", ["show", "#{revision}:#{path}"], cd: dir, stderr_to_stdout: true) do
      {bytes, 0} ->
        bytes

      {output, status} ->
        raise ArgumentError,
              "cannot read identity path #{path} at #{revision} (#{status}): #{String.trim(output)}"
    end
  end

  defp git_output!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} ->
        String.trim_trailing(output, "\n")

      {output, status} ->
        raise ArgumentError,
              "git #{Enum.join(args, " ")} failed (#{status}): #{String.trim(output)}"
    end
  end

  defp git!(dir, args, author \\ nil) do
    env =
      if author,
        do: [
          {"GIT_AUTHOR_NAME", author},
          {"GIT_AUTHOR_EMAIL", "tightbeam@localhost"},
          {"GIT_COMMITTER_NAME", author},
          {"GIT_COMMITTER_EMAIL", "tightbeam@localhost"}
        ],
        else: []

    case System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise ArgumentError,
              "git #{Enum.join(args, " ")} failed (#{status}): #{String.trim(output)}"
    end
  end
end
