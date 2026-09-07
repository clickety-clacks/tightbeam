defmodule Tightbeam.Rules do
  @moduledoc """
  Operator-authored conditional statutes loaded from `identity/rules/*.toml`.
  Verb and turn-end rules evaluate at their existing chokepoints; row-commit
  notice rules evaluate after the owning business mutation commits.

  Facts are demand-driven, cached once per dispatch call, and are
  best-effort point-in-time snapshots. Their reads are intentionally not
  synchronized with concurrent organization changes. A stale snapshot can
  miss or spuriously fire a statute, but any call statutes allow still runs
  the live constitutional checks in its handler.

  A nil fact never satisfies any operator, including `ne` and `not_in`.
  An empty list is present, however: `caller.roles not_in ["admin"]` fires
  for a caller holding no roles, and `assignment.verdicts not_in
  ["reviewed-clean"]` fires for an assignment with no verdicts. List facts are
  `caller.roles`, `assignment.verdicts`,
  `assignment.independent_verdict_kinds`,
  `assignment.qualifying_review_verdict_kinds`, and
  `assignment.artifact_kinds` (the distinct artifact kinds the assignment's
  holder recorded on its work item, in every artifact state). Assignment
  caller identity comes from the optional dispatch principal rather than the
  origin string.

  Check-tier facts are `attest.kind` (raw string on attest calls),
  `assignment.verdicts` (distinct filed verdict kinds),
  `assignment.is_producing_card`, `assignment.effect_kind`, `assignment.state`,
  `assignment.holder_noted_verdict_kinds`, `assignment.holder_archetype`, and
  `assignment.caller_is_holder`. The assignment facts resolve from the call's
  assignmentId, or from the reviewed assignment on an assign call, and are nil
  when that assignment cannot be resolved.

  Work-item facts are `work_item.is_bug` (the org-set work-item attribute) and
  `assignment.prior_completed_fix_count` (completed, non-review assignments on
  the same work item, excluding the current assignment). On an implementation
  `dispatch`, the assignment facts project the latest completed fix for the
  supplied work item so a re-fix gate can inspect its commissioned verdicts
  before the next assignment exists.

  Rule denials and fact errors are written as `kind = "denied"` events by
  dispatch. That audit write is best-effort: an unavailable event sink never
  turns a denial into an allowed call.
  """

  alias Tightbeam.{
    Artifacts,
    Assignments,
    DB,
    Devices,
    Escalation,
    EventLog,
    ObligationFacts,
    Org,
    RailEpisodes,
    RailRemedy,
    RailScript,
    RuleRuntime,
    Roles
  }

  import Bitwise

  @persist_key __MODULE__
  @policy_key {__MODULE__, :policies}
  @rule_keys MapSet.new([
               "name",
               "verb",
               "deny_when",
               "text",
               "edges",
               "check",
               "effect",
               "notice",
               "remedy",
               "external_producer",
               "recurrence_suppression"
             ])
  @condition_keys MapSet.new(["fact", "op", "value"])
  @policy_keys MapSet.new(["name", "purpose", "when", "verification"])
  @verification_keys MapSet.new(["trigger", "terminal", "fallback"])
  @policy_purposes ~w(wait-prod-coverage wait-effort-relief wait-verification-admission)
  @recurrence_keys MapSet.new([
                     "scope",
                     "fingerprint",
                     "escalation_threshold",
                     "fallback",
                     "rearm"
                   ])
  @rearm_keys MapSet.new(["recovered_when", "recurred_when"])
  @recurrence_fingerprint ~w(statute target_session subject failure_class failure_code)
  @check_keys MapSet.new(["script", "returns", "timeout_ms", "effects"])
  @notice_keys MapSet.new(["target_role", "target_session", "prompt"])
  @remedy_keys MapSet.new([
                 "action",
                 "produces",
                 "target_role",
                 "target_session",
                 "name",
                 "harness",
                 "model",
                 "effort",
                 "context",
                 "archetype",
                 "host",
                 "on_rule_denied",
                 "params"
               ])
  @binding_tokens ~w(assignment_id work_item_id holder_key holder_role holder_archetype caller_origin)
  @embedded_fields ~w(subject prompt display)
  @whole_fields ~w(target_role target_session reviews work_item name harness model effort context archetype host after at)
  @verdict_facts ~w(
    assignment.verdicts
    assignment.independent_verdict_kinds
    assignment.qualifying_review_verdict_kinds
    work_item.verdict_kinds
  )
  @linked_review_facts ~w(
    assignment.independent_verdict_kinds
    assignment.qualifying_review_verdict_kinds
  )
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
    "assignment.is_producing_card" => :bool,
    "assignment.effect_kind" => :string,
    "assignment.state" => :string,
    "assignment.outcome" => :string,
    "assignment.holder_noted_verdict_kinds" => {:list, :string},
    "assignment.independent_verdict_kinds" => {:list, :string},
    "assignment.qualifying_review_verdict_kinds" => {:list, :string},
    "assignment.artifact_kinds" => {:list, :string},
    "assignment.holder_archetype" => :string,
    "assignment.caller_is_holder" => :bool,
    "work_item.is_bug" => :bool,
    "work_item.state" => :string,
    "work_item.has_topline" => :bool,
    "work_item.has_spec_ref" => :bool,
    "work_item.verdict_kinds" => {:list, :string},
    "assignment.review_verdict_count" => :int,
    "assignment.prior_completed_fix_count" => :int,
    "assign.declared_files_overlap_open" => :bool,
    "decision_request.status" => :string,
    "artifact.present" => :bool,
    "artifact.content_sha256" => :string,
    "review.qualifying_verdict_kinds" => {:list, :string},
    "condition_fact.matches" => :bool,
    "wait.obligation_matches" => :bool,
    "wait.admitted" => :bool,
    "wait.after_turn_eligible" => :bool,
    "wait.coverage_valid" => :bool,
    "wait.continuation_state" => :string,
    "wait.recognized" => :bool,
    "wait.declaration_complete" => :bool,
    "wait.verification_accountable" => :bool,
    "wait.verification_state" => :string,
    "resolver.open" => :bool,
    "resolver.owed_by_other" => :bool,
    "wake.has_obligation" => :bool,
    "wake.registrant_is_holder" => :bool,
    "wake.registrant_is_ancestor" => :bool,
    "verifier.open" => :bool,
    "verifier.holder_is_other" => :bool
  }
  @operators ~w(eq ne gt gte lt lte in not_in)
  @predicate_binding_keys ~w(
    workItemId assignmentId decisionRequestId artifact
    conditionKind conditionScope conditionAfterId conditionFactId
  )
  @artifact_facts ~w(artifact.present artifact.content_sha256 review.qualifying_verdict_kinds)
  @type condition :: %{fact: String.t(), op: String.t(), value: term()}
  @type rule :: %{
          name: String.t(),
          verb: String.t(),
          text: String.t(),
          conditions: [condition()],
          edges: [String.t()],
          effect: String.t(),
          check: map() | nil,
          notice: map() | nil,
          remedy: map() | nil,
          external_producer: boolean()
        }

  @doc "Load and validate all rule files, replacing the currently active set."
  @spec load!(String.t(), Enumerable.t()) :: [rule()]
  def load!(base_dir, valid_verbs) do
    verbs = MapSet.new(valid_verbs)

    identity_manifest_sha = identity_manifest_sha(base_dir)

    entries =
      base_dir
      |> Path.join("identity/rules/*.toml")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(&load_file!(&1, verbs, base_dir, identity_manifest_sha))

    rules = for {:rule, rule} <- entries, do: rule
    policies = for {:policy, policy} <- entries, do: policy

    named = rules ++ policies

    case Enum.find(named, fn entry -> Enum.count(named, &(&1.name == entry.name)) > 1 end) do
      %{name: name, source: source} ->
        raise ArgumentError, "#{source}: rule #{inspect(name)}: duplicate name"

      nil ->
        :ok
    end

    validate_satisfiability!(rules, verbs)
    :persistent_term.put(@persist_key, rules)
    :persistent_term.put(@policy_key, policies)

    RuleRuntime.install_admission(&evaluate/2)

    RuleRuntime.install(%{
      row_commit_effects: &row_commit_effects_in_txn/2,
      resolve_notice: &resolve_notice_in_txn/3,
      evaluate_predicate: &evaluate_predicate_in_txn/2,
      select_policy: &select_policy_in_txn/3
    })

    rules
  end

  @doc "Select the bytewise-smallest matching predicate-only policy for one snapshot."
  @spec select_policy_in_txn(DB.Txn.t(), String.t(), map()) :: {:ok, map()} | :none
  def select_policy_in_txn(%DB.Txn{} = txn, purpose, context) do
    @policy_key
    |> :persistent_term.get([])
    |> Enum.filter(&(&1.purpose == purpose))
    |> Enum.sort_by(& &1.name)
    |> Enum.find_value(:none, fn policy ->
      call = %{origin: "process:tightbeam", params: %{}, policy_context: context}

      case evaluate_conditions(policy.conditions, policy, txn, call, %{}) do
        {:match, cache} ->
          {:ok, %{name: policy.name, facts: evidence_facts(policy.conditions, cache)}}

        {:no_match, _cache} ->
          false

        {:error, fact} ->
          raise ArgumentError, "failed to compute #{fact} for policy #{policy.name}"
      end
    end)
  end

  @doc "Evaluate the active statutes for a raw dispatch call."
  @spec evaluate(GenServer.server(), map()) :: :ok | {:deny, map()}
  def evaluate(db, call) do
    case decide(db, call) do
      {:allow, _to_close, _to_consume} -> :ok
      {{:deny, error}, _to_close, _to_consume} -> {:deny, error}
      {{:remedy, _statute, _ref, error}, _to_close, _to_consume} -> {:deny, error}
      {{:escalate, _statute, ctx, _dr_id}, _to_close, _to_consume} -> {:deny, ctx.error}
      {{:deny_escalate, _statute, ctx}, _to_close, _to_consume} -> {:deny, ctx.error}
    end
  end

  @doc "Return the dry statute decision and the actor-owned close/consume work."
  @spec decide(GenServer.server(), map()) :: {term(), [term()], [String.t()]}
  def decide(db, call) do
    rules = :persistent_term.get(@persist_key, [])
    verb = Map.fetch!(call, :verb)
    edge = edge(call)

    rules
    |> Enum.filter(&(&1.verb == verb and edge in &1.edges))
    |> decide_rules(db, call, %{}, [], [])
  end

  @doc false
  @spec active_identity_manifest_sha() :: String.t() | nil
  def active_identity_manifest_sha do
    @persist_key
    |> :persistent_term.get([])
    |> Enum.find_value(& &1.identity_manifest_sha)
  end

  @doc "Validate and evaluate an ad hoc predicate against one transaction snapshot."
  @spec evaluate_predicate(DB.server() | DB.Txn.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def evaluate_predicate(%DB.Txn{} = txn, predicate),
    do: evaluate_predicate_in_txn(txn, predicate)

  def evaluate_predicate(db, predicate) do
    case DB.transaction(db, &evaluate_predicate_in_txn(&1, predicate)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc "Evaluate one validated predicate through the common condition and fact engine."
  @spec evaluate_predicate_in_txn(DB.Txn.t(), map()) :: {:ok, map()} | {:error, map()}
  def evaluate_predicate_in_txn(%DB.Txn{} = txn, predicate) when is_map(predicate) do
    owner_user_id = field(predicate, :owner_user_id)
    raw_conditions = field(predicate, :conditions)
    raw_bindings = field(predicate, :bindings) || %{}

    try do
      unless is_binary(owner_user_id) and String.trim(owner_user_id) != "",
        do: raise(ArgumentError, "predicate ownerUserId must be nonblank")

      conditions = normalize_predicate_conditions(raw_conditions)
      fail = fn message -> raise ArgumentError, message end
      validate_predicate_conditions!(conditions, fail)
      conditions = validate_conditions!(conditions, fail)
      bindings = validate_bindings_in_txn!(txn, conditions, raw_bindings, owner_user_id)

      candidates = artifact_candidates_in_txn(txn, conditions, bindings, owner_user_id)

      result =
        Enum.reduce_while(candidates, nil, fn candidate, _acc ->
          call = predicate_call(owner_user_id, bindings, candidate, field(predicate, :transition))

          case evaluate_conditions(conditions, %{name: "ad-hoc-predicate"}, txn, call, %{}) do
            {:match, cache} ->
              {:halt,
               %{
                 matched: true,
                 facts: evidence_facts(conditions, cache),
                 condition_match: Map.get(cache, "$condition_match"),
                 artifact_revision: candidate,
                 canonical: %{conditions: conditions, bindings: bindings}
               }}

            {:no_match, cache} ->
              {:cont,
               %{
                 matched: false,
                 facts: evidence_facts(conditions, cache),
                 condition_match: Map.get(cache, "$condition_match"),
                 artifact_revision: candidate,
                 canonical: %{conditions: conditions, bindings: bindings}
               }}

            {:error, fact} ->
              raise ArgumentError, "failed to compute #{fact}"
          end
        end)

      {:ok,
       result ||
         %{
           matched: false,
           facts: [],
           condition_match: nil,
           artifact_revision: nil,
           canonical: %{conditions: conditions, bindings: bindings}
         }}
    rescue
      error in ArgumentError -> {:error, %{code: "invalid_predicate", message: error.message}}
    end
  end

  def evaluate_predicate_in_txn(%DB.Txn{}, _predicate),
    do: {:error, %{code: "invalid_predicate", message: "predicate must be an object"}}

  @doc "Evaluate loaded row-commit notice rules into effects for Wakes to record."
  @spec row_commit_effects_in_txn(DB.Txn.t(), [map()] | map()) :: [tuple()]
  def row_commit_effects_in_txn(%DB.Txn{} = txn, transitions) do
    List.wrap(transitions)
    |> Enum.flat_map(&evaluate_row_transition_in_txn(txn, &1))
  end

  @doc "Resolve a validated notice against the same transaction snapshot as its rule."
  @spec resolve_notice_in_txn(DB.Txn.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_notice_in_txn(%DB.Txn{} = txn, rule, call) do
    RailRemedy.resolve_notice(txn, rule.notice, notice_bindings(txn, call))
  end

  defp normalize_predicate_conditions(conditions) when is_list(conditions) do
    Enum.map(conditions, fn
      condition when is_map(condition) ->
        Map.new(condition, fn {key, value} -> {predicate_key(key), value} end)

      other ->
        other
    end)
  end

  defp normalize_predicate_conditions(other), do: other

  defp predicate_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> Macro.camelize() |> lower_first()

  defp predicate_key(key), do: key

  defp lower_first(value) do
    String.downcase(String.first(value)) <> String.slice(value, 1..-1//1)
  end

  defp validate_bindings_in_txn!(txn, conditions, raw_bindings, owner_user_id)
       when is_map(raw_bindings) do
    bindings = normalize_bindings(raw_bindings)
    unknown = Map.keys(bindings) -- @predicate_binding_keys

    if unknown != [],
      do:
        raise(ArgumentError, "bindings have unknown keys: #{Enum.join(Enum.sort(unknown), ", ")}")

    facts = MapSet.new(conditions, & &1.fact)

    if MapSet.member?(facts, "work_item.state") do
      id = required_binding!(bindings, "workItemId")
      ensure_owned_row!(txn, "work item", id, owner_user_id, "work_items", "id", "ownerUserId")
    end

    if Enum.any?(facts, &(&1 in ~w(assignment.state assignment.outcome))) do
      id = required_binding!(bindings, "assignmentId")

      unless owned_assignment?(txn, id, owner_user_id),
        do: raise(ArgumentError, "unknown or inaccessible assignment binding")
    end

    if MapSet.member?(facts, "decision_request.status") do
      id = required_binding!(bindings, "decisionRequestId")

      ensure_owned_row!(
        txn,
        "decision request",
        id,
        owner_user_id,
        "decision_requests",
        "id",
        "ownerUserId"
      )
    end

    bindings =
      if Enum.any?(facts, &(&1 in @artifact_facts)) do
        Map.put(
          bindings,
          "artifact",
          validate_artifact_binding_in_txn!(txn, Map.get(bindings, "artifact"), owner_user_id)
        )
      else
        bindings
      end

    if MapSet.member?(facts, "condition_fact.matches") do
      kind = required_binding!(bindings, "conditionKind")
      after_id = required_binding!(bindings, "conditionAfterId")

      unless is_binary(kind) and String.trim(kind) != "",
        do: raise(ArgumentError, "conditionKind binding must be nonblank")

      unless is_integer(after_id) and after_id >= 0,
        do: raise(ArgumentError, "conditionAfterId binding must be a nonnegative integer")

      scope = Map.get(bindings, "conditionScope")

      unless is_nil(scope) or is_binary(scope),
        do: raise(ArgumentError, "conditionScope binding must be text or null")
    end

    bindings
  end

  defp validate_bindings_in_txn!(_txn, _conditions, _raw_bindings, _owner_user_id),
    do: raise(ArgumentError, "predicate bindings must be an object")

  defp predicate_binding_key(key) when is_atom(key) do
    case key do
      :work_item_id -> "workItemId"
      :assignment_id -> "assignmentId"
      :decision_request_id -> "decisionRequestId"
      :artifact_id -> "artifactId"
      :content_sha256 -> "contentSha256"
      :produced_by_assignment_id -> "producedByAssignmentId"
      :condition_kind -> "conditionKind"
      :condition_scope -> "conditionScope"
      :condition_after_id -> "conditionAfterId"
      :condition_fact_id -> "conditionFactId"
      _ -> Atom.to_string(key)
    end
  end

  defp predicate_binding_key(key), do: key

  defp required_binding!(bindings, key) do
    case Map.get(bindings, key) do
      value when is_binary(value) and value != "" -> value
      value when key == "conditionAfterId" and is_integer(value) -> value
      _ -> raise ArgumentError, "bindings are missing #{key}"
    end
  end

  defp ensure_owned_row!(txn, label, id, owner, table, id_column, owner_column) do
    sql = "SELECT 1 FROM #{table} WHERE #{id_column}=?1 AND #{owner_column}=?2"

    if DB.Txn.q(txn, sql, [id, owner]) != [[1]],
      do: raise(ArgumentError, "unknown or inaccessible #{label} binding")
  end

  defp owned_assignment?(txn, id, owner) do
    DB.Txn.q(
      txn,
      """
      SELECT 1
      FROM assignments a
      JOIN sessions s ON s.sessionKey=a.holderKey
      LEFT JOIN work_items wi ON wi.id=a.workItemId
      WHERE a.id=?1 AND s.ownerUserId=?2
        AND (a.workItemId IS NULL OR wi.ownerUserId=?2)
      """,
      [id, owner]
    ) == [[1]]
  end

  defp validate_artifact_binding_in_txn!(txn, binding, owner) when is_map(binding) do
    binding = Map.new(binding, fn {key, value} -> {predicate_binding_key(key), value} end)
    keys = Map.keys(binding) |> Enum.sort()

    cond do
      keys == ["artifactId", "contentSha256"] ->
        artifact_id = Map.get(binding, "artifactId")
        hash = Map.get(binding, "contentSha256")

        unless is_binary(artifact_id) and artifact_id != "" and is_binary(hash) and hash != "",
          do:
            raise(
              ArgumentError,
              "artifact identity binding requires nonblank artifactId and contentSha256"
            )

        ensure_owned_artifact!(txn, artifact_id, owner)

      keys in [["producedByAssignmentId"], ["contentSha256", "producedByAssignmentId"]] ->
        producer = Map.get(binding, "producedByAssignmentId")
        hash = Map.get(binding, "contentSha256")

        unless is_binary(producer) and producer != "" and
                 (is_nil(hash) or (is_binary(hash) and hash != "")),
               do: raise(ArgumentError, "artifact producer binding is malformed")

        unless owned_assignment?(txn, producer, owner),
          do: raise(ArgumentError, "unknown or inaccessible artifact producer binding")

      true ->
        raise ArgumentError,
              "artifact binding must name artifactId/contentSha256 or producedByAssignmentId with optional contentSha256"
    end

    binding
  end

  defp validate_artifact_binding_in_txn!(_txn, _binding, _owner),
    do: raise(ArgumentError, "bindings are missing artifact")

  defp ensure_owned_artifact!(txn, artifact_id, owner) do
    rows =
      DB.Txn.q(
        txn,
        """
        SELECT 1 FROM artifacts art
        JOIN work_items wi ON wi.id=art.workItemId
        WHERE art.artifactId=?1 AND wi.ownerUserId=?2
        """,
        [artifact_id, owner]
      )

    if rows != [[1]], do: raise(ArgumentError, "unknown or inaccessible artifact binding")
  end

  defp artifact_candidates_in_txn(txn, conditions, bindings, owner) do
    if Enum.any?(conditions, &(&1.fact in @artifact_facts)) do
      binding = Map.get(bindings, "artifact")

      rows =
        case binding do
          %{"artifactId" => artifact_id} ->
            DB.Txn.q(
              txn,
              """
              SELECT art.artifactId, art.contentSha256, art.producedByAssignmentId
              FROM artifacts art JOIN work_items wi ON wi.id=art.workItemId
              WHERE art.artifactId=?1 AND wi.ownerUserId=?2
              """,
              [artifact_id, owner]
            )

          %{"producedByAssignmentId" => producer} = artifact_binding ->
            expected_hash = Map.get(artifact_binding, "contentSha256")
            hash_clause = if is_binary(expected_hash), do: " AND art.contentSha256=?3", else: ""

            params =
              if is_binary(expected_hash),
                do: [producer, owner, expected_hash],
                else: [producer, owner]

            DB.Txn.q(
              txn,
              """
              SELECT art.artifactId, art.contentSha256, art.producedByAssignmentId
              FROM artifacts art JOIN work_items wi ON wi.id=art.workItemId
              WHERE art.producedByAssignmentId=?1 AND wi.ownerUserId=?2#{hash_clause}
              ORDER BY art.createdAt, art.artifactId
              """,
              params
            )

          _ ->
            []
        end

      case rows do
        [] ->
          [nil]

        rows ->
          Enum.map(rows, fn [id, hash, producer] -> %{id: id, hash: hash, producer: producer} end)
      end
    else
      [nil]
    end
  end

  defp predicate_call(owner, bindings, artifact_candidate, transition) do
    params = %{
      work_item_id: Map.get(bindings, "workItemId"),
      assignment_id: Map.get(bindings, "assignmentId"),
      decision_request_id: Map.get(bindings, "decisionRequestId")
    }

    %{
      verb: "wake",
      edge: :row_commit,
      origin: "process:tightbeam",
      principal: {:user, owner},
      params: params,
      predicate_owner_user_id: owner,
      predicate_bindings: bindings,
      artifact_candidate: artifact_candidate,
      transition: transition
    }
  end

  defp evaluate_row_transition_in_txn(txn, transition) when is_map(transition) do
    verb = field(transition, :verb)
    owner = field(transition, :owner_user_id)
    bindings = field(transition, :bindings) || %{}
    {origin, principal} = row_commit_principal(field(transition, :principal), owner)

    call =
      predicate_call(owner, normalize_bindings(bindings), nil, transition)
      |> Map.merge(%{verb: verb, origin: origin, principal: principal, edge: :row_commit})

    domain = field(transition, :domain)

    :persistent_term.get(@persist_key, [])
    |> Enum.filter(fn rule ->
      rule.verb == verb and "row-commit" in rule.edges and rule.effect == "notice" and
        row_domain_candidate?(rule, domain)
    end)
    |> Enum.flat_map(fn rule ->
      try do
        candidates =
          artifact_candidates_in_txn(txn, rule.conditions, call.predicate_bindings, owner)

        Enum.reduce_while(candidates, [], fn candidate, [] ->
          candidate_call = Map.put(call, :artifact_candidate, candidate)

          case evaluate_conditions(rule.conditions, rule, txn, candidate_call, %{}) do
            {:match, cache} ->
              {:halt, [{:notice, rule, candidate_call, evidence_facts(rule.conditions, cache)}]}

            {:no_match, _cache} ->
              {:cont, []}

            {:error, fact} ->
              raise "row-commit rule #{rule.name} failed to compute #{fact}"
          end
        end)
      rescue
        error ->
          [{:error, rule, Exception.message(error)}]
      end
    end)
  end

  defp evaluate_row_transition_in_txn(_txn, _transition), do: []

  defp row_domain_candidate?(rule, domain) do
    Enum.any?(rule.conditions, fn condition ->
      domain in RuleRuntime.predicate_row_domains(condition.fact)
    end)
  end

  defp notice_bindings(db, call) do
    assignment =
      case fetch_fact("$assignment", db, call, %{}) do
        {:ok, value, _cache} -> value
        _ -> nil
      end

    %{
      assignment_id: assignment && assignment.id,
      work_item_id:
        (assignment && assignment.work_item_id) || Map.get(call.params, :work_item_id),
      holder_key: assignment && assignment.holder_key,
      holder_role: assignment && assignment[:holder_role],
      holder_archetype: assignment && assignment.holder_archetype,
      caller_origin: call.origin
    }
  end

  defp row_commit_principal("session:" <> session_key, _owner) do
    origin =
      case Tightbeam.Origin.parse(session_key) do
        {:agent, _} -> session_key
        _ -> "agent:#{session_key}"
      end

    {origin, {:session, session_key}}
  end

  defp row_commit_principal("user:" <> user_id, _owner),
    do: {"user:#{user_id}", {:user, user_id}}

  defp row_commit_principal("process:" <> process, _owner),
    do: {"process:#{process}", {:process, process}}

  defp row_commit_principal("remedy:" <> statute, owner),
    do: {"remedy:#{statute}", {:remedy, %{statute: statute, owner: owner}}}

  defp row_commit_principal(origin, owner) when is_binary(origin), do: {origin, {:user, owner}}
  defp row_commit_principal(_origin, owner), do: {"process:tightbeam", {:user, owner}}

  defp normalize_bindings(bindings) do
    bindings = Map.new(bindings, fn {key, value} -> {predicate_binding_key(key), value} end)

    case Map.get(bindings, "artifact") do
      artifact when is_map(artifact) ->
        Map.put(
          bindings,
          "artifact",
          Map.new(artifact, fn {key, value} -> {predicate_binding_key(key), value} end)
        )

      _ ->
        bindings
    end
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

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

    unknown = unknown_keys(manifest, MapSet.new(["rule", "policy"]))

    if unknown != [],
      do: raise(ArgumentError, "#{path}: unknown root keys: #{Enum.join(unknown, ", ")}")

    rules =
      case Map.fetch(manifest, "rule") do
        {:ok, rules} when is_list(rules) and rules != [] ->
          rules
          |> Enum.with_index(1)
          |> Enum.map(fn {rule, ordinal} ->
            {:rule,
             validate_rule!(path, ordinal, rule, valid_verbs, base_dir, identity_manifest_sha)}
          end)

        :error ->
          []

        _ ->
          raise ArgumentError, "#{path}: [[rule]] must be a non-empty array of tables"
      end

    policies =
      case Map.fetch(manifest, "policy") do
        {:ok, policies} when is_list(policies) and policies != [] ->
          policies
          |> Enum.with_index(1)
          |> Enum.map(fn {policy, ordinal} ->
            {:policy, validate_policy!(path, ordinal, policy, identity_manifest_sha)}
          end)

        :error ->
          []

        _ ->
          raise ArgumentError, "#{path}: [[policy]] must be a non-empty array of tables"
      end

    if rules == [] and policies == [],
      do: raise(ArgumentError, "#{path}: must contain one or more [[rule]] or [[policy]] tables")

    rules ++ policies
  end

  defp validate_policy!(path, ordinal, policy, identity_manifest_sha) when is_map(policy) do
    raw_name = Map.get(policy, "name")

    label =
      if valid_name?(raw_name), do: "policy #{inspect(raw_name)}", else: "policy ##{ordinal}"

    fail = fn message -> raise ArgumentError, "#{path}: #{label}: #{message}" end

    unknown = unknown_keys(policy, @policy_keys)
    if unknown != [], do: fail.("unknown keys: #{Enum.join(unknown, ", ")}")
    unless valid_name?(raw_name), do: fail.("invalid or missing name: #{inspect(raw_name)}")

    purpose = Map.get(policy, "purpose")
    unless purpose in @policy_purposes, do: fail.("unsupported purpose: #{inspect(purpose)}")

    conditions = validate_policy_conditions!(Map.get(policy, "when"), fail)
    verification = validate_policy_verification!(purpose, Map.get(policy, "verification"), fail)

    %{
      name: raw_name,
      purpose: purpose,
      conditions: conditions,
      verification: verification,
      source: path,
      identity_manifest_sha: identity_manifest_sha
    }
  end

  defp validate_policy!(path, ordinal, _policy, _identity_manifest_sha),
    do: raise(ArgumentError, "#{path}: policy ##{ordinal}: policy must be a table")

  defp validate_policy_conditions!(conditions, fail) do
    unless is_list(conditions) and conditions != [] and Enum.all?(conditions, &is_map/1),
      do: fail.("when must be a non-empty list of condition tables")

    conditions
    |> Enum.with_index(1)
    |> Enum.map(fn {condition, index} -> validate_condition!(condition, index, fail) end)
  end

  defp validate_policy_verification!("wait-verification-admission", verification, fail)
       when is_map(verification) do
    unknown = unknown_keys(verification, @verification_keys)
    if unknown != [], do: fail.("verification has unknown keys: #{Enum.join(unknown, ", ")}")

    expected = %{
      "trigger" => "registration",
      "terminal" => "bound-verdict-or-obligation-terminal",
      "fallback" => "wake-due-at"
    }

    unless verification == expected,
      do:
        fail.(
          "verification must declare registration, bound-verdict-or-obligation-terminal, and wake-due-at"
        )

    expected
  end

  defp validate_policy_verification!("wait-verification-admission", _verification, fail),
    do: fail.("verification admission requires a verification table")

  defp validate_policy_verification!(_purpose, nil, _fail), do: nil

  defp validate_policy_verification!(_purpose, _verification, fail),
    do: fail.("verification is valid only for wait-verification-admission")

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

    if "row-commit" in edges and effect != "notice",
      do: fail.(~s(edge "row-commit" requires effect = "notice"))

    effects = if check, do: Map.values(check.effects), else: [effect]
    notice = validate_notice!(Map.get(rule, "notice"), effect, fail)
    remedy = validate_remedy!(Map.get(rule, "remedy"), conditions, check, effects, fail)

    recurrence_suppression =
      validate_recurrence_suppression!(Map.get(rule, "recurrence_suppression"), fail)

    if "remedy" in effects and is_nil(remedy),
      do: fail.("effect remedy requires [rule.remedy]")

    if remedy && "remedy" not in effects,
      do: fail.("[rule.remedy] requires a remedy effect")

    if recurrence_suppression && is_nil(remedy),
      do: fail.("[rule.recurrence_suppression] requires a remedy effect and [rule.remedy]")

    external_producer = Map.get(rule, "external_producer", false)
    unless is_boolean(external_producer), do: fail.("external_producer must be a boolean")

    if external_producer and verdict_requirements(conditions) == [],
      do: fail.("external_producer is valid only on a verdict-fact gate")

    %{
      name: raw_name,
      verb: verb,
      text: String.trim(text),
      conditions: conditions,
      edges: edges,
      effect: effect,
      check: check,
      notice: notice,
      remedy: remedy,
      recurrence_suppression: recurrence_suppression,
      external_producer: external_producer,
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

  defp validate_predicate_conditions!(conditions, fail) do
    unless is_list(conditions) and conditions != [] do
      fail.("predicate conditions must be a non-empty list of condition objects")
    end
  end

  defp validate_recurrence_suppression!(nil, _fail), do: nil

  defp validate_recurrence_suppression!(declaration, fail) when is_map(declaration) do
    unknown = unknown_keys(declaration, @recurrence_keys)

    if unknown != [],
      do: fail.("recurrence_suppression has unknown keys: #{Enum.join(unknown, ", ")}")

    scope = Map.get(declaration, "scope")

    unless scope == "target_session_subject",
      do: fail.("recurrence_suppression scope must be target_session_subject")

    fingerprint = Map.get(declaration, "fingerprint")

    unless is_list(fingerprint) and fingerprint != [] and
             Enum.all?(fingerprint, &is_binary/1) and Enum.uniq(fingerprint) == fingerprint,
           do:
             fail.(
               "recurrence_suppression fingerprint must be a non-empty unique list of strings"
             )

    unless fingerprint == @recurrence_fingerprint,
      do:
        fail.(
          "recurrence_suppression fingerprint must be exactly #{inspect(@recurrence_fingerprint)}"
        )

    threshold = Map.get(declaration, "escalation_threshold")

    unless is_integer(threshold) and threshold >= 1,
      do: fail.("recurrence_suppression escalation_threshold must be an integer of at least 1")

    fallback = Map.get(declaration, "fallback")

    unless fallback == "operational_parent_then_main",
      do: fail.("recurrence_suppression fallback must be operational_parent_then_main")

    rearm = Map.get(declaration, "rearm")
    unless is_map(rearm), do: fail.("recurrence_suppression rearm must be a table")
    rearm_unknown = unknown_keys(rearm, @rearm_keys)

    if rearm_unknown != [],
      do:
        fail.("recurrence_suppression rearm has unknown keys: #{Enum.join(rearm_unknown, ", ")}")

    recovered_when =
      validate_rearm_conditions!(Map.get(rearm, "recovered_when"), "recovered_when", fail)

    recurred_when =
      validate_rearm_conditions!(Map.get(rearm, "recurred_when"), "recurred_when", fail)

    %{
      scope: scope,
      fingerprint: fingerprint,
      escalation_threshold: threshold,
      fallback: fallback,
      rearm: %{recovered_when: recovered_when, recurred_when: recurred_when}
    }
  end

  defp validate_recurrence_suppression!(_declaration, fail),
    do: fail.("recurrence_suppression must be a table")

  defp validate_rearm_conditions!(conditions, name, fail) do
    unless is_list(conditions) and conditions != [] and Enum.all?(conditions, &is_map/1),
      do:
        fail.("recurrence_suppression rearm #{name} must be a non-empty list of condition tables")

    conditions
    |> Enum.with_index(1)
    |> Enum.map(fn {condition, index} -> validate_condition!(condition, index, fail) end)
  end

  @doc false
  def condition_evidence(db, call, conditions) when is_list(conditions) do
    case evaluate_conditions(conditions, %{name: "recurrence-suppression"}, db, call, %{}) do
      {:match, cache} -> %{matched: true, facts: evidence_facts(conditions, cache)}
      {:no_match, cache} -> %{matched: false, facts: evidence_facts(conditions, cache)}
      {:error, fact} -> %{matched: false, facts: [{fact, :error}]}
    end
  end

  defp evidence_facts(conditions, cache) do
    Enum.map(conditions, fn condition ->
      {condition.fact, Map.get(cache, condition.fact, :not_evaluated)}
    end)
  end

  defp validate_edges!(edges, verb, fail) do
    unless is_list(edges) and edges != [] and
             Enum.all?(edges, &(&1 in ~w(verb turn-end row-commit))) and
             Enum.uniq(edges) == edges do
      fail.(~s(edges must be a non-empty subset of ["verb", "turn-end", "row-commit"]))
    end

    if "turn-end" in edges and verb != "attest",
      do: fail.(~s(edge "turn-end" is legal only for verb "attest"))

    edges
  end

  defp validate_effect!(effect, check, explicit?, fail) do
    unless effect in ~w(deny remedy escalate notice),
      do: fail.("effect must be one of deny, remedy, escalate, notice")

    if check && explicit?,
      do: fail.("effect is valid only on predicate-only statutes")

    effect
  end

  defp validate_notice!(nil, "notice", fail),
    do: fail.(~s(effect notice requires [rule.notice]))

  defp validate_notice!(nil, _effect, _fail), do: nil

  defp validate_notice!(notice, "notice", fail) when is_map(notice) do
    unknown = unknown_keys(notice, @notice_keys)
    if unknown != [], do: fail.("notice has unknown keys: #{Enum.join(unknown, ", ")}")

    targets = Enum.filter(~w(target_role target_session), &Map.has_key?(notice, &1))

    if length(targets) != 1,
      do: fail.("notice requires exactly one of target_role or target_session")

    prompt = Map.get(notice, "prompt")

    unless is_binary(prompt) and String.trim(prompt) != "",
      do: fail.("notice prompt must be nonblank")

    Enum.each(notice, fn {field, value} -> validate_interpolation!(field, value, fail) end)

    notice
    |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp validate_notice!(_notice, "notice", fail), do: fail.("notice must be a table")

  defp validate_notice!(_notice, _effect, fail),
    do: fail.(~s([rule.notice] requires effect = "notice"))

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

  defp validate_remedy!(nil, _conditions, _check, _effects, _fail), do: nil

  defp validate_remedy!(remedy, conditions, check, effects, fail) when is_map(remedy) do
    unknown = unknown_keys(remedy, @remedy_keys)
    if unknown != [], do: fail.("remedy has unknown keys: #{Enum.join(unknown, ", ")}")

    action = Map.get(remedy, "action")

    unless action in ~w(assign wake spawn),
      do: fail.("remedy action must be assign, wake, or spawn")

    params = Map.get(remedy, "params", %{})
    unless is_map(params), do: fail.("remedy params must be a table")

    on_rule_denied = Map.get(remedy, "on_rule_denied", "block")

    unless on_rule_denied in ~w(block surface),
      do: fail.("remedy on_rule_denied must be block or surface")

    {required_top, allowed_top, required_params, allowed_params} =
      case action do
        "assign" ->
          {~w(target_role), ~w(target_role), ~w(subject), ~w(subject reviews files work_item)}

        "wake" ->
          {[], ~w(target_role target_session), ~w(prompt), ~w(prompt after at)}

        "spawn" ->
          {~w(name harness model), ~w(name harness model effort context archetype host), [],
           ~w(display)}
      end

    present_top =
      remedy
      |> Map.keys()
      |> Enum.filter(&(&1 not in ~w(action produces on_rule_denied params)))

    missing_top = required_top -- present_top
    if missing_top != [], do: fail.("remedy #{action} is missing #{Enum.join(missing_top, ", ")}")

    extra_top = present_top -- allowed_top

    if extra_top != [],
      do: fail.("remedy #{action} has invalid targets: #{Enum.join(extra_top, ", ")}")

    if action == "wake" and Enum.count(present_top, &(&1 in ~w(target_role target_session))) != 1,
      do: fail.("remedy wake requires exactly one of target_role or target_session")

    missing_params = required_params -- Map.keys(params)

    if missing_params != [],
      do: fail.("remedy #{action} params are missing #{Enum.join(missing_params, ", ")}")

    extra_params = Map.keys(params) -- allowed_params

    if extra_params != [],
      do: fail.("remedy #{action} has invalid params: #{Enum.join(extra_params, ", ")}")

    Enum.each(Map.take(remedy, present_top), fn {field, value} ->
      validate_interpolation!(field, value, fail)
    end)

    Enum.each(params, fn
      {"files", files} when is_list(files) ->
        Enum.each(files, &validate_interpolation!("files", &1, fail))

      {"files", _} ->
        fail.("remedy files must be a non-empty list")

      {field, value} ->
        validate_interpolation!(field, value, fail)
    end)

    requirements = verdict_requirements(conditions)
    produces = Map.get(remedy, "produces")

    cond do
      check && not is_nil(produces) ->
        fail.("script-effect remedy must omit produces")

      is_nil(check) and requirements == [] and artifact_requirements(conditions) == [] ->
        fail.("predicate remedy requires a verdict-fact or artifact-fact gate")

      is_nil(check) and requirements == [] and not is_nil(produces) ->
        fail.("remedy produces is valid only on a verdict-fact gate")

      is_nil(check) and requirements != [] and not valid_verdict_kind?(produces) ->
        fail.("remedy produces must be a verdictKind required by the gate")

      is_nil(check) and requirements != [] and
          not Enum.any?(requirements, fn {_fact, kinds} -> produces in kinds end) ->
        fail.("remedy produces #{inspect(produces)} but the gate does not require it")

      true ->
        :ok
    end

    if is_nil(check) and
         Enum.any?(requirements, fn {fact, kinds} ->
           fact in @linked_review_facts and produces in kinds
         end) and params["reviews"] != "{assignment_id}" do
      fail.("linked-review-fact remedy requires reviews = \"{assignment_id}\"")
    end

    if "remedy" not in effects, do: fail.("[rule.remedy] requires a remedy effect")

    %{
      action: action,
      produces: produces,
      on_rule_denied: on_rule_denied,
      target:
        remedy
        |> Map.take(allowed_top)
        |> Map.new(fn {key, value} -> {String.to_atom(key), value} end),
      params: Map.new(params, fn {key, value} -> {String.to_atom(key), value} end)
    }
  end

  defp validate_remedy!(_remedy, _conditions, _check, _effects, fail),
    do: fail.("remedy must be a table")

  defp validate_interpolation!(field, value, fail) when field in @embedded_fields do
    unless is_binary(value), do: fail.("remedy #{field} must be a string")
    validate_tokens!(value, fail)
  end

  defp validate_interpolation!("files", value, fail) do
    unless is_binary(value), do: fail.("remedy files entries must be strings")
    validate_whole_interpolation("files", value, fail)
  end

  defp validate_interpolation!(field, value, fail) when field in @whole_fields do
    validate_whole_interpolation(field, value, fail)
  end

  defp validate_whole_interpolation(field, value, fail) when is_binary(value) do
    validate_tokens!(value, fail)

    if Regex.match?(~r/\{[^{}]+\}/, value) and
         not Regex.match?(~r/^\{[a-z_]+\}$/, value) do
      fail.("remedy #{field} must be a whole token or literal")
    end
  end

  defp validate_whole_interpolation(field, value, _fail)
       when field in ~w(after at) and is_integer(value),
       do: :ok

  defp validate_whole_interpolation(field, _value, fail),
    do: fail.("remedy #{field} must be a whole token or literal")

  defp validate_tokens!(value, fail) do
    tokens =
      Regex.scan(~r/\{([^{}]+)\}/, value, capture: :all_but_first)
      |> List.flatten()

    case Enum.find(tokens, &(&1 not in @binding_tokens)) do
      nil -> :ok
      token -> fail.("remedy uses unknown binding token {#{token}}")
    end
  end

  defp valid_verdict_kind?(kind) when is_binary(kind) do
    max = Application.get_env(:tightbeam, :max_verdict_kind_len, 64)
    String.length(kind) in 1..max and Regex.match?(@name_re, kind)
  end

  defp valid_verdict_kind?(_kind), do: false

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

    if is_binary(fact) do
      try do
        ObligationFacts.register!(fact)
      rescue
        error in ArgumentError -> fail.(error.message)
      end
    end

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

  defp validate_satisfiability!(rules, valid_verbs) do
    Enum.each(rules, &validate_producer_existence!/1)
    Enum.each(rules, &validate_remedy_reachability!(&1, rules, valid_verbs))
    validate_producer_cycles!(rules)
  end

  defp validate_producer_existence!(%{check: check}) when not is_nil(check), do: :ok

  defp validate_producer_existence!(rule) do
    Enum.each(verdict_requirements(rule.conditions), fn {fact, kinds} ->
      covered? = rule.external_producer or remedy_covers?(rule.remedy, fact, kinds)

      unless covered? do
        raise ArgumentError,
              "#{rule.source}: rule #{inspect(rule.name)}: F1 unsatisfied verdict gate #{fact}; no producer for #{Enum.join(kinds, ", ")}"
      end
    end)
  end

  defp remedy_covers?(nil, _fact, _kinds), do: false

  defp remedy_covers?(remedy, fact, kinds) do
    remedy.produces in kinds and
      (fact not in @linked_review_facts or remedy.params[:reviews] == "{assignment_id}")
  end

  defp validate_remedy_reachability!(%{remedy: nil}, _rules, _valid_verbs), do: :ok

  defp validate_remedy_reachability!(rule, rules, valid_verbs) do
    action = rule.remedy.action

    unless MapSet.member?(valid_verbs, action) do
      raise ArgumentError,
            "#{rule.source}: rule #{inspect(rule.name)}: F2 handler #{inspect(action)} cannot admit remedy statute #{inspect(rule.name)}"
    end

    case Enum.find(rules, &provable_blocker?(&1, rule)) do
      nil ->
        :ok

      blocker ->
        raise ArgumentError,
              "#{rule.source}: rule #{inspect(rule.name)}: F2 remedy statute #{inspect(rule.name)} is blocked by statute #{inspect(blocker.name)}"
    end
  end

  defp provable_blocker?(candidate, remedy_rule) do
    candidate.verb == remedy_rule.remedy.action and
      is_nil(candidate.remedy) and
      is_nil(candidate.check) and
      candidate.effect == "deny" and
      candidate.conditions != [] and
      Enum.all?(candidate.conditions, &fixed_condition_true?(&1, remedy_rule.remedy))
  end

  defp fixed_condition_true?(
         %{fact: "caller.origin_class", op: op, value: value},
         _remedy
       ) do
    compare("remedy", op, value)
  end

  defp fixed_condition_true?(_condition, _remedy), do: false

  defp validate_producer_cycles!(rules) do
    remedy_rules =
      Enum.filter(
        rules,
        &(not is_nil(&1.remedy) and not escaping_static_producer?(&1))
      )

    Enum.each(remedy_rules, fn rule ->
      walk_producer_chain!(rule, rule, remedy_rules, [rule.name])
    end)
  end

  defp escaping_static_producer?(%{external_producer: true}), do: true

  # A statute whose gate requirements are all artifact requirements escapes the
  # chain walk: `artifact-record` is a constitutional verb available to every
  # session, so the requirement is statically satisfiable without any producer.
  defp escaping_static_producer?(rule) do
    verdict_requirements(rule.conditions) == [] and
      artifact_requirements(rule.conditions) != []
  end

  defp walk_producer_chain!(root, current, rules, path) do
    next_rules = Enum.filter(rules, &(&1.verb == current.remedy.action))

    Enum.each(next_rules, fn next ->
      if next.name in path do
        raise ArgumentError,
              "#{root.source}: rule #{inspect(root.name)}: F2 producer cycle between statutes #{inspect(current.name)} and #{inspect(next.name)}"
      else
        walk_producer_chain!(root, next, rules, [next.name | path])
      end
    end)
  end

  defp verdict_requirements(conditions) do
    Enum.flat_map(conditions, fn
      %{fact: fact, op: "not_in", value: kinds} when fact in @verdict_facts ->
        [{fact, kinds}]

      _ ->
        []
    end)
  end

  defp artifact_requirements(conditions) do
    Enum.flat_map(conditions, fn
      %{fact: "assignment.artifact_kinds", op: "not_in", value: kinds} ->
        [{"assignment.artifact_kinds", kinds}]

      _ ->
        []
    end)
  end

  defp decide_rules([], _db, _call, _cache, to_close, to_consume),
    do: {:allow, Enum.reverse(to_close), Enum.reverse(to_consume)}

  defp decide_rules([rule | rest], db, call, cache, to_close, to_consume) do
    case evaluate_conditions(rule.conditions, rule, db, call, cache) do
      {:no_match, cache} ->
        decide_rules(rest, db, call, cache, maybe_close(rule, db, call, to_close), to_consume)

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
            # Minted BEFORE the sensor looks. That ordering is the whole fix: a verdict may
            # only authorize closing episodes that already existed when its check started,
            # so a malfunction landing during or after this run — fresh or attach — cannot
            # be swept by it, however long the actor takes to enact. A cutoff taken after
            # the verdict could always grow to cover events the verdict never saw, which is
            # what two rounds of review kept finding. `nil` means nothing is open to
            # recover. Minting touches no episode state, so `decide` stays effect-free.
            position = RailEpisodes.evaluating(db, rule.name)

            case RailScript.run(db, rule.base_dir, rule, call, assignment) do
              # The sensor answered. Whatever the token maps to — allow or a genuine deny —
              # this statute's check is rendering verdicts again, which IS the repair for
              # any malfunction episode it left open (§A3). The close rides `to_close`
              # because it is an EFFECT and `decide` is effect-free on enforcement (§B):
              # the actors own it, at both edges, whatever the fold decides afterwards. The
              # read is what keeps `to_close` a list of work rather than a no-op on every
              # healthy check — the same shape `maybe_close/4` uses for remedy episodes.
              {:ok, token, exit_class} ->
                fold_effect(
                  rule.check.effects[token],
                  rule,
                  rest,
                  db,
                  call,
                  cache,
                  recovery(rule, position, to_close),
                  to_consume,
                  exit_class
                )

              # Everything else is a MALFUNCTION, not a verdict (§A3, Flynn 2026-07-29,
              # generalized under dark-factory doctrine): a clock, a crash, a containment
              # refusal, a token outside the declared set, or one of the four paths that
              # reached a deny with nothing observed at all. A clock or a crash decided,
              # not a mind. The deny is byte-identical to what it always was — same reason,
              # same exit class, same legibility payload — and the event ALSO goes to the
              # escalation engine so a mind adjudicates the sensor instead of the deny
              # recurring silently on every retry. Only a declared token mapped to `deny`
              # above stays a bare deny; that one is the sensor answering.
              {:error, reason, exit_class} ->
                malfunction(rule, call, reason, exit_class, to_close, to_consume)
            end

          # The invocation context could not be resolved, so NO script was spawned — the
          # third `unreported` row of §A3's table, and a malfunction like the rest of it.
          # It recorded `error:1` until now: a child exit asserted for a child that never
          # existed, byte-identical to a script that really did exit 1. That is the task
          # #43 fabrication, surviving here because it sits a level above `rail_script.ex`
          # where the rest of it was cleaned out. The class no observation carried is
          # exactly what `unreported` exists to say.
          :error ->
            malfunction(rule, call, "script_error", "unreported", to_close, to_consume)
        end
    end
  end

  defp fold_effect("allow", rule, rest, db, call, cache, to_close, to_consume, _exit_class),
    do:
      decide_rules(
        rest,
        db,
        call,
        cache,
        maybe_close(rule, db, call, to_close),
        to_consume
      )

  defp fold_effect("notice", rule, rest, db, call, cache, to_close, to_consume, _exit_class) do
    evidence = evidence_facts(rule.conditions, cache)

    decide_rules(
      rest,
      db,
      call,
      cache,
      [{:notice, rule, call, evidence} | maybe_close(rule, db, call, to_close)],
      to_consume
    )
  end

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

  # The one shape every malfunction takes, so the two sites that reach one cannot drift:
  # the deny is byte-identical to what it always was, and the summons rides beside it.
  defp malfunction(rule, call, reason, exit_class, to_close, to_consume) do
    ctx = %{
      question: malfunction_question(rule, reason, exit_class),
      error: denial_error(rule, call, reason, exit_class),
      episode_key: exit_class
    }

    {{:deny_escalate, rule, ctx}, Enum.reverse(to_close), Enum.reverse(to_consume)}
  end

  # What the summoned mind is asked. It names the statute, the reason code, and the exit
  # class, because those are what separate the available repairs: raise the ceiling, fix
  # the script, repair the host, or reclassify the check as work.
  defp malfunction_question(rule, reason, exit_class) do
    "#{rule.name}: #{rule.text}\n" <>
      "The check rendered no verdict — denied #{reason}, script_exit_class " <>
      "#{exit_class}. A malfunction may bound a call; it may never be the last word on work."
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

  defp edge(call) do
    case Map.get(call, :edge, :verb) do
      :turn_end -> "turn-end"
      :row_commit -> "row-commit"
      _ -> "verb"
    end
  end

  defp gated_ref(call) do
    params = Map.fetch!(call, :params)

    params[:assignment_id] || params["assignment_id"] || params[:reviews_assignment_id] ||
      params["reviews_assignment_id"] || params[:work_item_id] || params["work_item_id"]
  end

  # The position rides the entry so the ACTOR can hand recovery to the writer; the writer,
  # not this list and not SQL, decides which episodes the position covers. `nil` means the
  # statute had nothing open when the check started, so there is no recovery to schedule
  # and `to_close` stays empty.
  defp recovery(_rule, nil, to_close), do: to_close
  defp recovery(rule, position, to_close), do: [{:episodes, rule.name, position} | to_close]

  defp maybe_close(rule, db, call, to_close) do
    subject = gated_ref(call)

    if not is_nil(rule.remedy) and is_binary(subject) do
      case RailRemedy.live?(db, rule.name, subject) do
        nil -> to_close
        occurrence -> [{rule.name, subject, occurrence} | to_close]
      end
    else
      to_close
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

      {:remedy, _} ->
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

  defp compute_fact("assignment.is_producing_card", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache -> {nil, cache}
      assignment, cache -> {is_nil(assignment.reviews_assignment_id), cache}
    end)
  end

  defp compute_fact("assignment.effect_kind", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache -> {nil, cache}
      assignment, cache -> {assignment.effect_kind, cache}
    end)
  end

  defp compute_fact("assignment.state", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache -> {nil, cache}
      assignment, cache -> {assignment.state, cache}
    end)
  end

  defp compute_fact("assignment.outcome", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache -> {nil, cache}
      assignment, cache -> {assignment.outcome, cache}
    end)
  end

  defp compute_fact("assignment.holder_noted_verdict_kinds", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      assignment, cache ->
        {:ok, rows} =
          DB.query(
            db,
            """
            SELECT DISTINCT verdictKind FROM attests
            WHERE assignmentId = ?1
              AND kind = 'verdict'
              AND bySession = ?2
              AND note IS NOT NULL
              AND length(trim(note)) > 0
            ORDER BY verdictKind
            """,
            [assignment.id, assignment.holder_key]
          )

        {Enum.map(rows, fn [kind] -> kind end), cache}
    end)
  end

  defp compute_fact("assignment.independent_verdict_kinds", db, call, cache) do
    with_dependency("$verdict_authors", db, call, cache, fn
      nil, cache -> {nil, cache}
      authors, cache -> {distinct_verdict_kinds(authors), cache}
    end)
  end

  defp compute_fact("assignment.qualifying_review_verdict_kinds", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      assignment, cache ->
        {Assignments.qualifying_review_verdict_kinds(
           db,
           assignment.id,
           assignment.holder_key
         ), cache}
    end)
  end

  defp compute_fact("assignment.artifact_kinds", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      assignment, cache ->
        {Artifacts.recorded_kinds(db, assignment.work_item_id, assignment.holder_key), cache}
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

  defp compute_fact("work_item.is_bug", db, call, cache) do
    with_dependency("$work_item_id", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      work_item_id, cache ->
        value =
          case DB.query(db, "SELECT isBug FROM work_items WHERE id = ?1", [work_item_id]) do
            {:ok, [[is_bug]]} -> is_bug == 1
            {:ok, []} -> nil
          end

        {value, cache}
    end)
  end

  defp compute_fact("work_item.state", db, call, cache) do
    with_dependency("$work_item_id", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      work_item_id, cache ->
        owner = Map.get(call, :predicate_owner_user_id)

        {sql, params} =
          if is_binary(owner) do
            {"SELECT state FROM work_items WHERE id=?1 AND ownerUserId=?2", [work_item_id, owner]}
          else
            {"SELECT state FROM work_items WHERE id=?1", [work_item_id]}
          end

        value =
          case DB.query(db, sql, params) do
            {:ok, [[state]]} -> state
            {:ok, []} -> nil
          end

        {value, cache}
    end)
  end

  defp compute_fact("decision_request.status", db, call, cache) do
    decision_id = Map.get(call.params, :decision_request_id)
    owner = Map.get(call, :predicate_owner_user_id)

    value =
      case DB.query(
             db,
             "SELECT status FROM decision_requests WHERE id=?1 AND ownerUserId=?2",
             [decision_id, owner]
           ) do
        {:ok, [[status]]} -> status
        {:ok, []} -> nil
      end

    {value, cache}
  end

  defp compute_fact("artifact.present", _db, call, cache) do
    candidate = Map.get(call, :artifact_candidate)
    binding = get_in(call, [:predicate_bindings, "artifact"]) || %{}
    expected_hash = Map.get(binding, "contentSha256")

    present =
      is_map(candidate) and is_binary(candidate.hash) and
        (is_nil(expected_hash) or candidate.hash == expected_hash)

    {present, cache}
  end

  defp compute_fact("artifact.content_sha256", _db, call, cache) do
    value =
      case Map.get(call, :artifact_candidate) do
        %{hash: hash} -> hash
        _ -> nil
      end

    {value, cache}
  end

  defp compute_fact("review.qualifying_verdict_kinds", db, call, cache) do
    value =
      case Map.get(call, :artifact_candidate) do
        %{id: artifact_id, hash: hash, producer: producer}
        when is_binary(hash) and is_binary(producer) ->
          qualifying_revision_verdicts(db, artifact_id, hash, producer)

        _ ->
          []
      end

    {value, cache}
  end

  defp compute_fact("condition_fact.matches", db, call, cache) do
    bindings = Map.get(call, :predicate_bindings, %{})
    kind = Map.get(bindings, "conditionKind")
    scope = Map.get(bindings, "conditionScope")
    after_id = Map.get(bindings, "conditionAfterId")
    fact_id = Map.get(bindings, "conditionFactId")
    owner_user_id = Map.get(call, :predicate_owner_user_id)

    {owner_clause, params} =
      if owner_user_id == "legacy-unscoped" do
        {"ownerUserId IS NULL", [after_id, kind]}
      else
        {"ownerUserId=?3", [after_id, kind, owner_user_id]}
      end

    {scope_clause, params} =
      if is_nil(scope) do
        {"", params}
      else
        {" AND scope=?#{length(params) + 1}", params ++ [scope]}
      end

    {id_clause, params} =
      if is_integer(fact_id) do
        {" AND id=?#{length(params) + 1}", params ++ [fact_id]}
      else
        {"", params}
      end

    rows =
      case DB.query(
             db,
             "SELECT id, scope FROM condition_facts WHERE id>?1 AND kind=?2 AND #{owner_clause}#{scope_clause}#{id_clause} ORDER BY id LIMIT 1",
             params
           ) do
        {:ok, rows} -> rows
      end

    case rows do
      [[id, matched_scope]] ->
        {true, Map.put(cache, "$condition_match", %{id: id, scope: matched_scope})}

      [] ->
        {false, cache}
    end
  end

  defp compute_fact("wake.has_obligation", _db, call, cache) do
    {is_binary(call.params[:assignment_id]), cache}
  end

  defp compute_fact(fact, db, call, cache)
       when fact in ~w(wake.registrant_is_holder wake.registrant_is_ancestor) do
    registrant =
      case call[:principal] do
        {:session, key} -> key
        _ -> nil
      end

    {:ok, rows} =
      DB.query(
        db,
        """
        WITH RECURSIVE lineage(sessionKey,spawnedBy,holderKey,ownerUserId) AS (
          SELECT s.sessionKey,s.spawnedBy,s.sessionKey,s.ownerUserId
          FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey
          JOIN sessions caller ON caller.sessionKey=?2 AND caller.ownerUserId=s.ownerUserId
          WHERE a.id=?1 AND a.state='open'
          UNION
          SELECT s.sessionKey,s.spawnedBy,l.holderKey,l.ownerUserId
          FROM sessions s JOIN lineage l ON s.sessionKey=l.spawnedBy AND s.ownerUserId=l.ownerUserId
        )
        SELECT sessionKey=holderKey FROM lineage WHERE sessionKey=?2
        """,
        [call.params[:assignment_id], registrant]
      )

    value =
      case {fact, rows} do
        {"wake.registrant_is_holder", [[1]]} -> true
        {"wake.registrant_is_ancestor", [[0]]} -> true
        _ -> false
      end

    {value, cache}
  end

  defp compute_fact("verifier.open", _db, call, cache) do
    {get_in(call, [:policy_context, :verifier_state]) == "open", cache}
  end

  defp compute_fact(fact, _db, call, cache)
       when fact in ~w(wait.obligation_matches wait.admitted wait.after_turn_eligible
                      wait.coverage_valid wait.continuation_state wait.recognized
                      wait.declaration_complete wait.verification_accountable
                      wait.verification_state resolver.open resolver.owed_by_other) do
    # Only the bound, checked wake snapshot supplies these facts. Missing context
    # remains nil (including for ne), never an invented negative observation.
    {get_in(call, [:policy_context, :wait_facts, fact]), cache}
  end

  defp compute_fact("verifier.holder_is_other", _db, call, cache) do
    context = Map.get(call, :policy_context, %{})
    {context[:verifier_holder_key] != context[:obligation_holder_key], cache}
  end

  # Explicit active membership is the sole Topline truth. Visibility is checked
  # before the count so an unknown item and another user's item are one nil
  # answer; ended episodes and Concern references cannot make this fact true.
  defp compute_fact("work_item.has_topline", db, call, cache) do
    with_dependency("$work_item_id", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      work_item_id, cache ->
        with_dependency("caller.user", db, call, cache, fn
          nil, cache ->
            {nil, cache}

          caller_user, cache ->
            with_dependency("caller.is_admin", db, call, cache, fn
              nil, cache ->
                {nil, cache}

              is_admin, cache ->
                {:ok, rows} =
                  DB.query(
                    db,
                    """
                    SELECT EXISTS(
                      SELECT 1 FROM topline_work_memberships m
                      WHERE m.workItemId = wi.id AND m.unlinkedAt IS NULL
                    )
                    FROM work_items wi
                    WHERE wi.id = ?1 AND (?2 = 1 OR wi.ownerUserId = ?3)
                    """,
                    [work_item_id, if(is_admin, do: 1, else: 0), caller_user]
                  )

                case rows do
                  [[flag]] -> {flag == 1, cache}
                  [] -> {nil, cache}
                end
            end)
        end)
    end)
  end

  # Whether the call's work item pins a spec (specRefName). Neutral truth for
  # the spirit-gate statute: spec-backed work is a slice of product, and the
  # law can require a product-owner spirit verdict before its implementation
  # dispatches. The substrate answers has-a-spec; the PO judges the spec.
  defp compute_fact("work_item.has_spec_ref", db, call, cache) do
    with_dependency("$work_item_id", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      work_item_id, cache ->
        {:ok, rows} =
          DB.query(db, "SELECT specRefName IS NOT NULL FROM work_items WHERE id = ?1", [
            work_item_id
          ])

        case rows do
          [[flag]] -> {flag == 1, cache}
          [] -> {nil, cache}
        end
    end)
  end

  # Verdict kinds across EVERY assignment of the call's work item — the
  # item-scoped sibling of assignment.verdict_kinds, because on a FIRST
  # dispatch no assignment exists to project and an assignment-scoped fact is
  # nil, which can never satisfy a conjunct: a gate meant to fire before the
  # first implementation must read the item. Empty list (never nil) once the
  # item is known: "no verdicts yet" is an answer, not an absence.
  defp compute_fact("work_item.verdict_kinds", db, call, cache) do
    with_dependency("$work_item_id", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      work_item_id, cache ->
        {:ok, rows} =
          DB.query(
            db,
            """
            SELECT DISTINCT a.verdictKind
              FROM attests AS a
              JOIN assignments AS s ON s.id = a.assignmentId
             WHERE s.workItemId = ?1 AND a.kind = 'verdict'
             ORDER BY a.verdictKind
            """,
            [work_item_id]
          )

        {Enum.map(rows, &hd/1), cache}
    end)
  end

  # How many review-verdict attests have landed on this assignment's REVIEW
  # SUBJECT — the round counter. Anchored on COALESCE(reviewsAssignmentId, id)
  # so the answer is the same whether the call's assignment IS a review (an
  # attest landing on round N sees rounds 1..N-1 as its siblings) or is the
  # reviewed subject itself. Total attests, NOT distinct kinds: five
  # changes-requested verdicts are five rounds, and collapsing them would hide
  # exactly the spin the round-count doorbell exists to light up.
  defp compute_fact("assignment.review_verdict_count", db, call, cache) do
    with_dependency("$assignment", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      assignment, cache ->
        {:ok, [[count]]} =
          DB.query(
            db,
            """
            SELECT COUNT(*) FROM attests
             WHERE kind = 'verdict'
               AND assignmentId IN
                   (SELECT id FROM assignments
                     WHERE reviewsAssignmentId =
                           (SELECT COALESCE(reviewsAssignmentId, id)
                              FROM assignments WHERE id = ?1))
            """,
            [assignment.id]
          )

        {count, cache}
    end)
  end

  defp compute_fact("assignment.prior_completed_fix_count", db, call, cache) do
    with_dependency("$work_item_id", db, call, cache, fn
      nil, cache ->
        {nil, cache}

      work_item_id, cache ->
        current_assignment_id =
          case Map.get(call.params, :assignment_id) do
            id when is_binary(id) -> id
            _ -> nil
          end

        {:ok, [[count]]} =
          DB.query(
            db,
            """
            SELECT count(*)
            FROM assignments
            WHERE workItemId = ?1
              AND reviewsAssignmentId IS NULL
              AND state = 'closed'
              AND outcome = 'completed'
              AND (?2 IS NULL OR id != ?2)
            """,
            [work_item_id, current_assignment_id]
          )

        {count, cache}
    end)
  end

  defp compute_fact("assign.declared_files_overlap_open", db, call, cache) do
    value =
      case {call.verb, Map.get(call.params, :files)} do
        {"assign", files} when is_list(files) and files != [] ->
          if Enum.all?(files, fn path ->
               is_binary(path) and String.length(String.trim(path)) in 1..2_000
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

  defp compute_fact("$work_item_id", db, call, cache) do
    case Map.get(call.params, :work_item_id) do
      work_item_id when is_binary(work_item_id) ->
        {work_item_id, cache}

      _ ->
        with_dependency("$assignment", db, call, cache, fn
          nil, cache -> {nil, cache}
          assignment, cache -> {assignment.work_item_id, cache}
        end)
    end
  end

  defp compute_fact("$assignment", db, call, cache) do
    assignment =
      case Map.get(call.params, :assignment_id) || Map.get(call.params, "assignment_id") do
        id when is_binary(id) ->
          case Map.get(call, :predicate_owner_user_id) do
            owner when is_binary(owner) ->
              assignment_context(
                db,
                "WHERE a.id = ?1 AND s.ownerUserId = ?2 AND (a.workItemId IS NULL OR wi.ownerUserId = ?2)",
                [id, owner]
              )

            _ ->
              assignment_context(db, "WHERE a.id = ?1", [id])
          end

        _ ->
          case Map.get(call.params, :reviews_assignment_id) ||
                 Map.get(call.params, "reviews_assignment_id") do
            id when call.verb == "assign" and is_binary(id) ->
              assignment_context(db, "WHERE a.id = ?1", [id])

            _ ->
              resolve_dispatch_assignment(db, call)
          end
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

  defp resolve_dispatch_assignment(db, call) do
    case {call.verb, Map.get(call.params, :work_item_id)} do
      {"dispatch", work_item_id} when is_binary(work_item_id) ->
        assignment_context(
          db,
          """
          WHERE a.workItemId = ?1
            AND a.reviewsAssignmentId IS NULL
            AND a.state = 'closed'
            AND a.outcome = 'completed'
          ORDER BY a.closedAt DESC, a.id DESC
          LIMIT 1
          """,
          [work_item_id]
        )

      _ ->
        nil
    end
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

  defp qualifying_revision_verdicts(db, artifact_id, hash, producer_assignment_id) do
    case DB.query(
           db,
           """
           WITH winner AS (
             SELECT v.verdictKind, r.holderKey AS reviewHolder, p.holderKey AS producerHolder
             FROM attests v
             JOIN assignments r ON r.id=v.assignmentId
             JOIN assignments p ON p.id=r.reviewsAssignmentId
             WHERE r.reviewsAssignmentId=?1
               AND v.kind='verdict'
               AND v.bySession=r.holderKey
               AND v.verdictKind IN ('reviewed-clean','changes-requested')
               AND v.artifactId=?2
               AND v.contentSha256=?3
             ORDER BY v.ts DESC, v.rowid DESC
             LIMIT 1
           )
           SELECT verdictKind FROM winner
           WHERE verdictKind='reviewed-clean' AND reviewHolder != producerHolder
           """,
           [producer_assignment_id, artifact_id, hash]
         ) do
      {:ok, [["reviewed-clean"]]} -> ["reviewed-clean"]
      {:ok, _} -> []
    end
  end

  defp assignment_context(db, where, params) do
    case DB.query(
           db,
           """
           SELECT a.id, a.workItemId, a.reviewsAssignmentId, a.holderKey, a.holderRole,
                  a.state, a.outcome, s.archetype,
                  a.holderHarness, a.holderProvider,
                  COALESCE(e.effectKind,
                    CASE WHEN a.reviewsAssignmentId IS NULL THEN 'code' ELSE 'review' END)
           FROM assignments a
           JOIN sessions s ON s.sessionKey = a.holderKey
           LEFT JOIN work_items wi ON wi.id = a.workItemId
           LEFT JOIN assignment_effects e ON e.assignmentId = a.id
           #{where}
           """,
           params
         ) do
      {:ok,
       [
         [
           assignment_id,
           work_item_id,
           reviews_assignment_id,
           holder_key,
           holder_role,
           state,
           outcome,
           holder_archetype,
           holder_harness,
           holder_provider,
           effect_kind
         ]
       ]} ->
        %{
          id: assignment_id,
          work_item_id: work_item_id,
          reviews_assignment_id: reviews_assignment_id,
          holder_key: holder_key,
          holder_role: holder_role,
          state: state,
          outcome: outcome,
          holder_archetype: holder_archetype,
          holder_harness: holder_harness,
          holder_provider: holder_provider,
          effect_kind: effect_kind
        }

      {:ok, []} ->
        nil
    end
  end

  defp caller_user(db, call, cache) do
    case {Map.get(call, :edge), Map.get(call, :principal)} do
      {:row_commit, {:session, session_key}} ->
        value =
          case Org.get(db, session_key) do
            nil -> nil
            session -> session.owner_user_id
          end

        {value, cache}

      _ ->
        caller_user_from_origin(db, call, cache)
    end
  end

  defp caller_user_from_origin(db, call, cache) do
    case parse_origin(call.origin) do
      :malformed ->
        {nil, cache}

      {:user, user} ->
        {user, cache}

      {:process, _} ->
        {nil, cache}

      {:remedy, _} ->
        case Map.get(call, :principal) do
          {:remedy, %{owner: owner}} -> {owner, cache}
          _ -> {nil, cache}
        end

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

  defp parse_origin(origin), do: Tightbeam.Origin.parse(origin)

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
