defmodule Tightbeam.RuleRuntime do
  @moduledoc """
  Dependency-inversion seam between rule evaluation and rule-effect consumers.

  `Tightbeam.Rules` installs the one evaluator after loading the active rule set.
  Consumers call this module so wake delivery does not acquire dependencies on
  the domain readers used by the evaluator.
  """

  alias Tightbeam.DB

  @persist_key __MODULE__

  @predicate_transition_contracts %{
    "work_item.state" => %{kind: :row, domains: ["work_item"], binding: "workItemId"},
    "assignment.state" => %{kind: :row, domains: ["assignment"], binding: "assignmentId"},
    "assignment.outcome" => %{kind: :row, domains: ["assignment"], binding: "assignmentId"},
    "decision_request.status" => %{
      kind: :row,
      domains: ["decision_request"],
      binding: "decisionRequestId"
    },
    "artifact.present" => %{kind: :artifact, domains: ["artifact"], binding: "artifact"},
    "artifact.content_sha256" => %{
      kind: :artifact,
      domains: ["artifact"],
      binding: "artifact"
    },
    "review.qualifying_verdict_kinds" => %{
      kind: :artifact,
      domains: ["artifact", "attest"],
      binding: "artifact"
    },
    "condition_fact.matches" => %{kind: :condition_fact, domains: ["condition_fact"]}
  }

  @type callbacks :: %{
          row_commit_effects: (DB.Txn.t(), [map()] | map() -> [tuple()]),
          resolve_notice: (DB.Txn.t(), map(), map() -> {:ok, map()} | {:error, term()}),
          evaluate_predicate: (DB.Txn.t(), map() -> {:ok, map()} | {:error, map()}),
          select_policy: (DB.Txn.t(), String.t(), map() -> {:ok, map()} | :none)
        }

  @doc false
  @spec install(callbacks()) :: :ok
  def install(%{
        row_commit_effects: row_commit_effects,
        resolve_notice: resolve_notice,
        evaluate_predicate: evaluate_predicate,
        select_policy: select_policy
      })
      when is_function(row_commit_effects, 2) and is_function(resolve_notice, 3) and
             is_function(evaluate_predicate, 2) and is_function(select_policy, 3) do
    :persistent_term.put(@persist_key, %{
      row_commit_effects: row_commit_effects,
      resolve_notice: resolve_notice,
      evaluate_predicate: evaluate_predicate,
      select_policy: select_policy
    })

    :ok
  end

  @doc false
  @spec loaded?() :: boolean()
  def loaded?, do: not is_nil(callbacks())

  @doc false
  @spec predicate_transition_contract(String.t()) :: map() | nil
  def predicate_transition_contract(fact), do: Map.get(@predicate_transition_contracts, fact)

  @doc false
  @spec predicate_row_domains(String.t()) :: [String.t()]
  def predicate_row_domains(fact) do
    case predicate_transition_contract(fact) do
      %{domains: domains} -> domains
      nil -> []
    end
  end

  @doc false
  @spec row_commit_effects_in_txn(DB.Txn.t(), [map()] | map()) :: [tuple()]
  def row_commit_effects_in_txn(%DB.Txn{} = txn, transitions) do
    case callbacks() do
      %{row_commit_effects: evaluate} -> evaluate.(txn, transitions)
      nil -> raise "row rule recognition is not loaded"
    end
  end

  @doc false
  @spec resolve_notice_in_txn(DB.Txn.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_notice_in_txn(%DB.Txn{} = txn, rule, call) do
    case callbacks() do
      %{resolve_notice: resolve} -> resolve.(txn, rule, call)
      nil -> {:error, :rules_not_loaded}
    end
  end

  @doc false
  @spec evaluate_predicate_in_txn(DB.Txn.t(), map()) :: {:ok, map()} | {:error, map()}
  def evaluate_predicate_in_txn(%DB.Txn{} = txn, predicate) do
    case callbacks() do
      %{evaluate_predicate: evaluate} -> evaluate.(txn, predicate)
      nil -> {:error, %{code: "rules_not_loaded", message: "rules are not loaded"}}
    end
  end

  @doc false
  @spec select_policy_in_txn(DB.Txn.t(), String.t(), map()) :: {:ok, map()} | :none
  def select_policy_in_txn(%DB.Txn{} = txn, purpose, context) do
    case callbacks() do
      %{select_policy: select} -> select.(txn, purpose, context)
      nil -> raise "row rule recognition is not loaded"
    end
  end

  defp callbacks, do: :persistent_term.get(@persist_key, nil)
end
