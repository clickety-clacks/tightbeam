defmodule Tightbeam.Rules do
  @moduledoc """
  Operator-authored, deny-only verb statutes loaded from
  `identity/rules/*.toml` and evaluated at the dispatch chokepoint.

  Facts are demand-driven, cached once per dispatch call, and are
  best-effort point-in-time snapshots. Their reads are intentionally not
  synchronized with concurrent organization changes. A stale snapshot can
  miss or spuriously fire a statute, but any call statutes allow still runs
  the live constitutional checks in its handler.

  A nil fact never satisfies any operator, including `ne` and `not_in`.
  An empty list is present, however: `caller.roles not_in ["admin"]` fires
  for a caller holding no roles, and `assignment.verdicts not_in
  ["tests-passed"]` fires for an assignment with no verdicts. List facts are
  `caller.roles`, `assignment.verdicts`,
  `assignment.independent_verdict_kinds`,
  `assignment.cross_harness_verdict_kinds`,
  `assignment.cross_provider_verdict_kinds`, and
  `assignment.produced_verdict_kinds`. Assignment caller identity comes from
  the optional dispatch principal rather than the origin string.

  Check-tier facts are `attest.kind` (raw string on attest calls),
  `assignment.verdicts` (distinct filed verdict kinds),
  `assignment.holder_archetype`, and `assignment.caller_is_holder`. The three
  assignment facts resolve from the call's assignmentId and are nil when that
  assignment cannot be resolved.

  Rule denials and fact errors are written as `kind = "denied"` events by
  dispatch. That audit write is best-effort: an unavailable event sink never
  turns a denial into an allowed call.
  """

  alias Tightbeam.{Assignments, DB, Devices, Escalation, EventLog, Org, RailScript, Roles}
  import Bitwise

  @persist_key __MODULE__
  @rule_keys MapSet.new(["name", "verb", "deny_when", "text", "edges", "check", "effect"])
  @condition_keys MapSet.new(["fact", "op", "value"])
  @check_keys MapSet.new(["script", "returns", "timeout_ms", "effects"])
  @name_re ~r/^[a-z0-9][a-z0-9-]*$/
  @facts %{
    "caller.origin_class" => :string,
    "caller.user" => :string,
    "caller.is_admin" => :bool,
    "caller.roles" => {:list, :string},
    "target.owner" => :string,
    "target.archetype" => :string,
    "target.host" => :string,
    "target.kind" => :string,
    "target.state" => :string,
    "org.live_sessions_owned_by_caller" => :int,
    "caller.verb_count_24h" => :int,
    "attest.kind" => :string,
    "assignment.verdicts" => {:list, :string},
    "assignment.independent_verdict_kinds" => {:list, :string},
    "assignment.cross_harness_verdict_kinds" => {:list, :string},
    "assignment.cross_provider_verdict_kinds" => {:list, :string},
    "assignment.produced_verdict_kinds" => {:list, :string},
    "assignment.holder_archetype" => :string,
    "assignment.caller_is_holder" => :bool,
    "assign.declared_files_overlap_open" => :bool
  }
  @operators ~w(eq ne gt gte lt lte in not_in)

  @type condition :: %{fact: String.t(), op: String.t(), value: term()}
  @type rule :: %{
          name: String.t(),
          verb: String.t(),
          text: String.t(),
          conditions: [condition()],
          edges: [String.t()],
          effect: String.t(),
          check: map() | nil
        }

  @doc "Load and validate all rule files, replacing the currently active set."
  @spec load!(String.t(), Enumerable.t()) :: [rule()]
  def load!(base_dir, valid_verbs) do
    verbs = MapSet.new(valid_verbs)

    identity_manifest_sha = identity_manifest_sha(base_dir)

    rules =
      base_dir
      |> Path.join("identity/rules/*.toml")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(&load_file!(&1, verbs, base_dir, identity_manifest_sha))

    case Enum.find(rules, fn rule -> Enum.count(rules, &(&1.name == rule.name)) > 1 end) do
      %{name: name, source: source} ->
        raise ArgumentError, "#{source}: rule #{inspect(name)}: duplicate name"

      nil ->
        :ok
    end

    :persistent_term.put(@persist_key, rules)
    rules
  end

  @doc "Evaluate the active statutes for a raw dispatch call."
  @spec evaluate(GenServer.server(), map()) :: :ok | {:deny, map()}
  def evaluate(db, call) do
    case decide(db, call) do
      {:allow, _to_close, _to_consume} -> :ok
      {{:deny, error}, _to_close, _to_consume} -> {:deny, error}
      {{:remedy, _statute, _ref, error}, _to_close, _to_consume} -> {:deny, error}
      {{:escalate, _statute, ctx, _dr_id}, _to_close, _to_consume} -> {:deny, ctx.error}
    end
  end

  @doc "Return the dry statute decision and the actor-owned close/consume work."
  @spec decide(GenServer.server(), map()) :: {term(), [term()], [String.t()]}
  def decide(db, call) do
    rules = :persistent_term.get(@persist_key, [])
    verb = Map.fetch!(call, :verb)
    edge = if Map.get(call, :edge, :verb) == :turn_end, do: "turn-end", else: "verb"

    rules
    |> Enum.filter(&(&1.verb == verb and edge in &1.edges))
    |> decide_rules(db, call, %{}, [], [])
  end

  defp load_file!(path, valid_verbs, base_dir, identity_manifest_sha) do
    contents = File.read!(path)

    if String.trim(contents) == "" do
      raise ArgumentError, "#{path}: empty TOML"
    end

    manifest =
      case Toml.decode(contents) do
        {:ok, decoded} -> decoded
        {:error, error} -> raise ArgumentError, "#{path}: invalid TOML: #{inspect(error)}"
      end

    unknown = unknown_keys(manifest, MapSet.new(["rule"]))

    if unknown != [],
      do: raise(ArgumentError, "#{path}: unknown root keys: #{Enum.join(unknown, ", ")}")

    case Map.get(manifest, "rule") do
      rules when is_list(rules) and rules != [] ->
        rules
        |> Enum.with_index(1)
        |> Enum.map(fn {rule, ordinal} ->
          validate_rule!(path, ordinal, rule, valid_verbs, base_dir, identity_manifest_sha)
        end)

      _ ->
        raise ArgumentError, "#{path}: must contain one or more [[rule]] tables"
    end
  end

  defp validate_rule!(path, ordinal, rule, valid_verbs, base_dir, identity_manifest_sha)
       when is_map(rule) do
    raw_name = Map.get(rule, "name")
    label = if valid_name?(raw_name), do: "rule #{inspect(raw_name)}", else: "rule ##{ordinal}"
    fail = fn message -> raise ArgumentError, "#{path}: #{label}: #{message}" end

    unknown = unknown_keys(rule, @rule_keys)
    if unknown != [], do: fail.("unknown keys: #{Enum.join(unknown, ", ")}")
    unless valid_name?(raw_name), do: fail.("invalid or missing name: #{inspect(raw_name)}")

    verb = Map.get(rule, "verb")
    unless is_binary(verb) and String.trim(verb) != "", do: fail.("missing or blank verb")
    unless MapSet.member?(valid_verbs, verb), do: fail.("unknown verb: #{inspect(verb)}")

    text = Map.get(rule, "text")
    unless is_binary(text) and String.trim(text) != "", do: fail.("missing or blank text")

    conditions = validate_conditions!(Map.get(rule, "deny_when"), fail)
    check = validate_check!(Map.get(rule, "check"), base_dir, fail)

    if conditions == [] and is_nil(check),
      do: fail.("must carry at least one of deny_when or [rule.check]")

    edges = validate_edges!(Map.get(rule, "edges", ["verb"]), verb, fail)

    effect =
      validate_effect!(Map.get(rule, "effect", "deny"), check, Map.has_key?(rule, "effect"), fail)

    effects = if check, do: Map.values(check.effects), else: [effect]

    if "remedy" in effects,
      do: fail.("effect remedy requires [rule.remedy] (roadmap phase P5)")

    %{
      name: raw_name,
      verb: verb,
      text: String.trim(text),
      conditions: conditions,
      edges: edges,
      effect: effect,
      check: check,
      source: path,
      base_dir: base_dir,
      identity_manifest_sha: identity_manifest_sha
    }
  end

  defp validate_rule!(path, ordinal, _rule, _valid_verbs, _base_dir, _identity_manifest_sha) do
    raise ArgumentError, "#{path}: rule ##{ordinal}: rule must be a table"
  end

  defp validate_conditions!(nil, _fail), do: []

  defp validate_conditions!(conditions, fail) do
    unless is_list(conditions) and conditions != [] and Enum.all?(conditions, &is_map/1) do
      fail.("deny_when must be a non-empty list of condition tables")
    end

    conditions
    |> Enum.with_index(1)
    |> Enum.map(fn {condition, index} -> validate_condition!(condition, index, fail) end)
  end

  defp validate_edges!(edges, verb, fail) do
    unless is_list(edges) and edges != [] and Enum.all?(edges, &(&1 in ~w(verb turn-end))) and
             Enum.uniq(edges) == edges do
      fail.(~s(edges must be a non-empty subset of ["verb", "turn-end"]))
    end

    if "turn-end" in edges and verb != "attest",
      do: fail.(~s(edge "turn-end" is legal only for verb "attest"))

    edges
  end

  defp validate_effect!(effect, check, explicit?, fail) do
    unless effect in ~w(deny remedy escalate),
      do: fail.("effect must be one of deny, remedy, escalate")

    if check && explicit?,
      do: fail.("effect is valid only on predicate-only statutes")

    effect
  end

  defp validate_check!(nil, _base_dir, _fail), do: nil

  defp validate_check!(check, base_dir, fail) when is_map(check) do
    unknown = unknown_keys(check, @check_keys)
    if unknown != [], do: fail.("check has unknown keys: #{Enum.join(unknown, ", ")}")

    script = Map.get(check, "script")
    unless valid_name?(script), do: fail.("check script has an invalid or missing name")

    path = Path.join([base_dir, "identity", "rails", "scripts", script])

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o111) != 0 -> :ok
      _ -> fail.("check script must be an existing executable regular file: #{path}")
    end

    returns = Map.get(check, "returns")

    unless is_list(returns) and returns != [] and Enum.all?(returns, &valid_name?/1) and
             Enum.uniq(returns) == returns do
      fail.("check returns must be a non-empty unique list of tokens")
    end

    timeout_ms = Map.get(check, "timeout_ms", 5_000)

    unless is_integer(timeout_ms) and timeout_ms in 1..60_000,
      do: fail.("check timeout_ms must be an integer in 1..60000")

    effects = Map.get(check, "effects")
    unless is_map(effects), do: fail.("check effects must be a table")

    unless Map.keys(effects) |> Enum.sort() == Enum.sort(returns),
      do: fail.("check effects must map every declared return and no others")

    unless Enum.all?(effects, fn {_token, effect} -> effect in ~w(allow deny remedy escalate) end),
           do: fail.("check effects must be one of allow, deny, remedy, escalate")

    %{script: script, returns: returns, timeout_ms: timeout_ms, effects: effects}
  end

  defp validate_check!(_check, _base_dir, fail), do: fail.("check must be a table")

  defp validate_condition!(condition, index, fail) do
    unknown = unknown_keys(condition, @condition_keys)

    if unknown != [],
      do: fail.("condition ##{index} has unknown keys: #{Enum.join(unknown, ", ")}")

    for key <- ["fact", "op", "value"] do
      unless Map.has_key?(condition, key), do: fail.("condition ##{index} is missing #{key}")
    end

    fact = Map.get(condition, "fact")
    op = Map.get(condition, "op")
    value = Map.get(condition, "value")
    type = Map.get(@facts, fact)

    if is_nil(type), do: fail.("condition ##{index} has unknown fact: #{inspect(fact)}")
    unless op in @operators, do: fail.("condition ##{index} has unknown op: #{inspect(op)}")
    validate_value!(type, op, value, index, fail)
    %{fact: fact, op: op, value: value}
  end

  defp validate_value!({:list, :string}, op, value, index, fail) do
    unless op in ~w(in not_in),
      do: fail.("condition ##{index} operator #{op} is invalid for a list fact")

    validate_nonempty_flat_list!(value, :string, index, fail)
  end

  defp validate_value!(type, op, value, index, fail) when op in ~w(eq ne) do
    unless typed?(value, type), do: fail.("condition ##{index} value does not match #{type}")
  end

  defp validate_value!(:int, op, value, index, fail) when op in ~w(gt gte lt lte) do
    unless is_integer(value), do: fail.("condition ##{index} value must be an integer")
  end

  defp validate_value!(type, op, value, index, fail) when op in ~w(gt gte lt lte) do
    fail.("condition ##{index} operator #{op} is invalid for #{type}")
    value
  end

  defp validate_value!(type, op, value, index, fail) when op in ~w(in not_in) do
    validate_nonempty_flat_list!(value, type, index, fail)
  end

  defp validate_nonempty_flat_list!(value, type, index, fail) do
    unless is_list(value) and value != [] and Enum.all?(value, &typed?(&1, type)) do
      fail.("condition ##{index} value must be a non-empty flat list of #{type} values")
    end
  end

  defp typed?(value, :string), do: is_binary(value)
  defp typed?(value, :bool), do: is_boolean(value)
  defp typed?(value, :int), do: is_integer(value)

  defp valid_name?(name), do: is_binary(name) and Regex.match?(@name_re, name)

  defp unknown_keys(map, allowed) do
    map
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.difference(allowed)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp decide_rules([], _db, _call, _cache, to_close, to_consume),
    do: {:allow, Enum.reverse(to_close), Enum.reverse(to_consume)}

  defp decide_rules([rule | rest], db, call, cache, to_close, to_consume) do
    case evaluate_conditions(rule.conditions, rule, db, call, cache) do
      {:no_match, cache} ->
        decide_rules(rest, db, call, cache, to_close, to_consume)

      {:error, fact} ->
        error =
          denial_error(rule, call, "rule_denied", nil)
          |> Map.merge(%{
            code: "rule_error",
            fact: fact,
            message: "#{rule.name}: failed to compute #{fact}"
          })

        {{:deny, error}, Enum.reverse(to_close), Enum.reverse(to_consume)}

      {:match, cache} ->
        evaluate_reached_rule(rule, rest, db, call, cache, to_close, to_consume)
    end
  end

  defp evaluate_reached_rule(rule, rest, db, call, cache, to_close, to_consume) do
    case rule.check do
      nil ->
        fold_effect(rule.effect, rule, rest, db, call, cache, to_close, to_consume, nil)

      _check ->
        case fetch_fact("$assignment", db, call, cache) do
          {:ok, assignment, cache} ->
            case RailScript.run(db, rule.base_dir, rule, call, assignment) do
              {:ok, token, exit_class} ->
                fold_effect(
                  rule.check.effects[token],
                  rule,
                  rest,
                  db,
                  call,
                  cache,
                  to_close,
                  to_consume,
                  exit_class
                )

              {:error, reason, exit_class} ->
                error = denial_error(rule, call, reason, exit_class)
                {{:deny, error}, Enum.reverse(to_close), Enum.reverse(to_consume)}
            end

          :error ->
            error = denial_error(rule, call, "script_error", "error:1")
            {{:deny, error}, Enum.reverse(to_close), Enum.reverse(to_consume)}
        end
    end
  end

  defp fold_effect("allow", _rule, rest, db, call, cache, to_close, to_consume, _exit_class),
    do: decide_rules(rest, db, call, cache, to_close, to_consume)

  defp fold_effect("deny", rule, _rest, _db, call, _cache, to_close, to_consume, exit_class) do
    error = denial_error(rule, call, "rule_denied", exit_class)
    {{:deny, error}, Enum.reverse(to_close), Enum.reverse(to_consume)}
  end

  defp fold_effect("remedy", rule, _rest, _db, call, _cache, to_close, to_consume, exit_class) do
    error = denial_error(rule, call, "remedy_fired", exit_class)

    {{:remedy, rule, gated_ref(call), error}, Enum.reverse(to_close), Enum.reverse(to_consume)}
  end

  defp fold_effect("escalate", rule, rest, db, call, cache, to_close, to_consume, exit_class) do
    ctx = %{
      question: rule.text,
      error: denial_error(rule, call, "escalated", exit_class)
    }

    case Escalation.resolve(db, call, rule) do
      :allow ->
        decide_rules(rest, db, call, cache, to_close, to_consume)

      {:allow, ruling_id} ->
        decide_rules(rest, db, call, cache, to_close, [ruling_id | to_consume])

      {:deny, error} ->
        error = enrich_denial(error, rule, call, "rule_denied", exit_class)
        {{:deny, error}, Enum.reverse(to_close), Enum.reverse(to_consume)}

      {:needs_request, dr_id} ->
        {{:escalate, rule, ctx, dr_id}, Enum.reverse(to_close), Enum.reverse(to_consume)}
    end
  end

  defp denial_error(rule, call, reason, script_exit_class) do
    %{
      code: "rule_denied",
      rule: rule.name,
      edge: edge(call),
      reason: reason,
      script_exit_class: script_exit_class,
      ref: gated_ref(call),
      producer: nil,
      identity_manifest_sha: rule.identity_manifest_sha,
      message: "#{rule.name}: #{rule.text}"
    }
  end

  defp enrich_denial(error, rule, call, reason, script_exit_class) do
    denial_error(rule, call, reason, script_exit_class) |> Map.merge(error)
  end

  defp edge(call), do: if(Map.get(call, :edge, :verb) == :turn_end, do: "turn-end", else: "verb")

  defp gated_ref(call) do
    params = Map.fetch!(call, :params)

    params[:assignment_id] || params[:work_item_id] || params["assignment_id"] ||
      params["work_item_id"]
  end

  defp evaluate_conditions([], _rule, _db, _call, cache), do: {:match, cache}

  defp evaluate_conditions([condition | rest], rule, db, call, cache) do
    case fetch_fact(condition.fact, db, call, cache) do
      {:ok, nil, cache} ->
        {:no_match, cache}

      {:ok, value, cache} ->
        if compare(value, condition.op, condition.value) do
          evaluate_conditions(rest, rule, db, call, cache)
        else
          {:no_match, cache}
        end

      :error ->
        {:error, condition.fact}
    end
  end

  defp fetch_fact(fact, db, call, cache) do
    case Map.fetch(cache, fact) do
      {:ok, value} -> {:ok, value, cache}
      :error -> compute_fact_safely(fact, db, call, cache)
    end
  end

  defp compute_fact_safely(fact, db, call, cache) do
    try do
      {value, cache} = compute_fact(fact, db, call, cache)
      {:ok, value, Map.put(cache, fact, value)}
    catch
      _kind, _reason -> :error
    end
  end

  defp compute_fact("caller.origin_class", _db, call, cache),
    do: {origin_part(call.origin, :class), cache}

  defp compute_fact("caller.user", db, call, cache), do: caller_user(db, call, cache)

  defp compute_fact("caller.is_admin", db, call, cache) do
    with_dependency("caller.user", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      user, cache ->
        value =
          case Devices.user(db, user) do
            nil -> nil
            row -> row.is_admin
          end

        {value, cache}
    end)
  end

  defp compute_fact("caller.roles", db, call, cache) do
    case parse_origin(call.origin) do
      :malformed ->
        {nil, cache}

      {:user, _} ->
        {[], cache}

      {:process, _} ->
        {[], cache}

      {:agent, role_name} ->
        case Roles.get(db, role_name) do
          %{bound_session_key: key} when is_binary(key) ->
            case Org.get(db, key) do
              %{state: "active"} ->
                roles =
                  Roles.list(db)
                  |> Enum.filter(&(&1.bound_session_key == key))
                  |> Enum.map(& &1.name)

                {roles, cache}

              _ ->
                {[], cache}
            end

          _ ->
            {[], cache}
        end
    end
  end

  defp compute_fact("target." <> field, db, call, cache) do
    with_dependency("$target", db, call, cache, fn target, cache ->
      key = if field == "owner", do: :owner_user_id, else: String.to_existing_atom(field)
      value = if target, do: Map.fetch!(target, key), else: nil
      {value, cache}
    end)
  end

  defp compute_fact("org.live_sessions_owned_by_caller", db, call, cache) do
    with_dependency("caller.user", db, call, cache, fn
      nil, cache -> {nil, cache}
      user, cache -> {length(Org.list_for_user(db, user, false)), cache}
    end)
  end

  defp compute_fact("caller.verb_count_24h", db, call, cache) do
    case parse_origin(call.origin) do
      :malformed ->
        {nil, cache}

      _ ->
        {EventLog.verb_count(
           db,
           call.origin,
           call.verb,
           System.system_time(:millisecond) - 86_400_000
         ), cache}
    end
  end

  defp compute_fact("attest.kind", _db, call, cache) do
    value =
      case {call.verb, Map.get(call.params, :kind)} do
        {"attest", kind} when is_binary(kind) -> kind
        _ -> nil
      end

    {value, cache}
  end

  defp compute_fact("assignment.verdicts", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache -> {nil, cache}
      assignment, cache -> {Assignments.verdict_kinds(db, assignment.id), cache}
    end)
  end

  defp compute_fact("assignment.independent_verdict_kinds", db, call, cache) do
    with_dependency("$verdict_authors", db, call, cache, fn
      nil, cache -> {nil, cache}
      authors, cache -> {distinct_verdict_kinds(authors), cache}
    end)
  end

  defp compute_fact("assignment.cross_harness_verdict_kinds", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      %{holder_harness: nil}, cache ->
        {nil, cache}

      assignment, cache ->
        with_dependency("$verdict_authors", db, call, cache, fn authors, cache ->
          kinds =
            authors
            |> Enum.filter(
              &(not is_nil(&1.by_harness) and &1.by_harness != assignment.holder_harness)
            )
            |> distinct_verdict_kinds()

          {kinds, cache}
        end)
    end)
  end

  defp compute_fact("assignment.cross_provider_verdict_kinds", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      %{holder_provider: nil}, cache ->
        {nil, cache}

      assignment, cache ->
        with_dependency("$verdict_authors", db, call, cache, fn authors, cache ->
          kinds =
            authors
            |> Enum.filter(
              &(not is_nil(&1.by_provider) and &1.by_provider != assignment.holder_provider)
            )
            |> distinct_verdict_kinds()

          {kinds, cache}
        end)
    end)
  end

  defp compute_fact("assignment.produced_verdict_kinds", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache -> {nil, cache}
      assignment, cache -> {Assignments.produced_verdict_kinds(db, assignment.id), cache}
    end)
  end

  defp compute_fact("assignment.holder_archetype", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache -> {nil, cache}
      assignment, cache -> {assignment.holder_archetype, cache}
    end)
  end

  defp compute_fact("assignment.caller_is_holder", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache -> {nil, cache}
      _assignment, cache when not is_map_key(call, :principal) -> {nil, cache}
      _assignment, cache when is_nil(call.principal) -> {nil, cache}
      assignment, cache -> {call.principal == {:session, assignment.holder_key}, cache}
    end)
  end

  defp compute_fact("assign.declared_files_overlap_open", db, call, cache) do
    value =
      case {call.verb, Map.get(call.params, :files)} do
        {"assign", files} when is_list(files) and files != [] ->
          if Enum.all?(files, fn path ->
               is_binary(path) and String.trim(path) != "" and byte_size(path) <= 2_000
             end) do
            Assignments.open_assignments_touching(db, Enum.uniq(files)) != []
          else
            nil
          end

        _ ->
          nil
      end

    {value, cache}
  end

  defp compute_fact("$target", db, call, cache) do
    target =
      case Map.get(call, :session_key) do
        nil -> nil
        key -> Org.get(db, key)
      end

    {target, cache}
  end

  defp compute_fact("$assignment", db, call, cache) do
    assignment =
      case Map.get(call.params, :assignment_id) do
        id when is_binary(id) ->
          case DB.query(
                 db,
                 "SELECT a.id, a.holderKey, s.archetype, a.holderHarness, a.holderProvider FROM assignments a JOIN sessions s ON s.sessionKey = a.holderKey WHERE a.id = ?1",
                 [id]
               ) do
            {:ok,
             [[assignment_id, holder_key, holder_archetype, holder_harness, holder_provider]]} ->
              %{
                id: assignment_id,
                holder_key: holder_key,
                holder_archetype: holder_archetype,
                holder_harness: holder_harness,
                holder_provider: holder_provider
              }

            {:ok, []} ->
              nil
          end

        _ ->
          nil
      end

    {assignment, cache}
  end

  defp compute_fact("$verdict_authors", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      assignment, cache ->
        {Assignments.commissioned_review_authors(db, assignment.id, assignment.holder_key), cache}
    end)
  end

  defp with_dependency(fact, db, call, cache, fun) do
    case fetch_fact(fact, db, call, cache) do
      {:ok, value, cache} -> fun.(value, cache)
      :error -> throw({:dependency_error, fact})
    end
  end

  defp distinct_verdict_kinds(authors) do
    authors
    |> Enum.map(& &1.verdict_kind)
    |> Enum.uniq()
  end

  defp caller_user(db, call, cache) do
    case parse_origin(call.origin) do
      :malformed ->
        {nil, cache}

      {:user, user} ->
        {user, cache}

      {:process, _} ->
        {nil, cache}

      {:agent, role_name} ->
        value =
          case Roles.get(db, role_name) do
            %{bound_session_key: key} when is_binary(key) ->
              case Org.get(db, key) do
                nil -> nil
                session -> session.owner_user_id
              end

            _ ->
              nil
          end

        {value, cache}
    end
  end

  defp origin_part(origin, :class) do
    case parse_origin(origin) do
      {class, _} -> Atom.to_string(class)
      :malformed -> nil
    end
  end

  defp parse_origin(origin) when is_binary(origin) do
    case String.split(origin, ":", parts: 2) do
      [prefix, rest] when prefix in ~w(user agent process) and rest != "" ->
        {String.to_existing_atom(prefix), rest}

      _ ->
        :malformed
    end
  end

  defp parse_origin(_), do: :malformed

  defp compare(left, "eq", right), do: left == right
  defp compare(left, "ne", right), do: left != right
  defp compare(left, "gt", right), do: left > right
  defp compare(left, "gte", right), do: left >= right
  defp compare(left, "lt", right), do: left < right
  defp compare(left, "lte", right), do: left <= right

  defp compare(left, "in", right) when is_list(left),
    do: not MapSet.disjoint?(MapSet.new(left), MapSet.new(right))

  defp compare(left, "not_in", right) when is_list(left),
    do: MapSet.disjoint?(MapSet.new(left), MapSet.new(right))

  defp compare(left, "in", right), do: left in right
  defp compare(left, "not_in", right), do: left not in right

  defp identity_manifest_sha(base_dir) do
    identity_dir = Path.join(base_dir, "identity")

    case System.cmd("git", ["-C", identity_dir, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
