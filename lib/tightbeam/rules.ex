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
  for a caller holding no roles.

  Rule denials and fact errors are written as `kind = "denied"` events by
  dispatch. That audit write is best-effort: an unavailable event sink never
  turns a denial into an allowed call.
  """

  alias Tightbeam.{Devices, EventLog, Org, Roles}

  @persist_key __MODULE__
  @rule_keys MapSet.new(["name", "verb", "deny_when", "text"])
  @condition_keys MapSet.new(["fact", "op", "value"])
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
    "caller.verb_count_24h" => :int
  }
  @operators ~w(eq ne gt gte lt lte in not_in)

  @type condition :: %{fact: String.t(), op: String.t(), value: term()}
  @type rule :: %{name: String.t(), verb: String.t(), text: String.t(), conditions: [condition()]}

  @doc "Load and validate all rule files, replacing the currently active set."
  @spec load!(String.t(), Enumerable.t()) :: [rule()]
  def load!(base_dir, valid_verbs) do
    verbs = MapSet.new(valid_verbs)

    rules =
      base_dir
      |> Path.join("identity/rules/*.toml")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(&load_file!(&1, verbs))

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
    rules = :persistent_term.get(@persist_key, [])
    verb = Map.fetch!(call, :verb)

    rules
    |> Enum.filter(&(&1.verb == verb))
    |> evaluate_rules(db, call, %{})
  end

  defp load_file!(path, valid_verbs) do
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
        |> Enum.map(fn {rule, ordinal} -> validate_rule!(path, ordinal, rule, valid_verbs) end)

      _ ->
        raise ArgumentError, "#{path}: must contain one or more [[rule]] tables"
    end
  end

  defp validate_rule!(path, ordinal, rule, valid_verbs) when is_map(rule) do
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

    conditions = Map.get(rule, "deny_when")

    unless is_list(conditions) and conditions != [] and Enum.all?(conditions, &is_map/1) do
      fail.("deny_when must be a non-empty list of condition tables")
    end

    validated =
      conditions
      |> Enum.with_index(1)
      |> Enum.map(fn {condition, index} -> validate_condition!(condition, index, fail) end)

    %{
      name: raw_name,
      verb: verb,
      text: String.trim(text),
      conditions: validated,
      source: path
    }
  end

  defp validate_rule!(path, ordinal, _rule, _valid_verbs) do
    raise ArgumentError, "#{path}: rule ##{ordinal}: rule must be a table"
  end

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

  defp evaluate_rules([], _db, _call, _cache), do: :ok

  defp evaluate_rules([rule | rest], db, call, cache) do
    case evaluate_conditions(rule.conditions, rule, db, call, cache) do
      {:match, _cache} ->
        {:deny, %{code: "rule_denied", rule: rule.name, message: "#{rule.name}: #{rule.text}"}}

      {:no_match, cache} ->
        evaluate_rules(rest, db, call, cache)

      {:error, fact} ->
        {:deny,
         %{
           code: "rule_error",
           rule: rule.name,
           fact: fact,
           message: "#{rule.name}: failed to compute #{fact}"
         }}
    end
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

  defp compute_fact("$target", db, call, cache) do
    target =
      case Map.get(call, :session_key) do
        nil -> nil
        key -> Org.get(db, key)
      end

    {target, cache}
  end

  defp with_dependency(fact, db, call, cache, fun) do
    case fetch_fact(fact, db, call, cache) do
      {:ok, value, cache} -> fun.(value, cache)
      :error -> throw({:dependency_error, fact})
    end
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
end
