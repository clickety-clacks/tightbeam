defmodule Tightbeam.WorkItemSummary do
  @moduledoc false

  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.{Hub, Publisher}
  alias Tightbeam.{ConditionFacts, DB, StateResources, WorkItems}

  @doc false
  def attach(db, %{id: work_item_id} = row) do
    Map.merge(row, fields(db, work_item_id))
  end

  @doc false
  def attach_handler_row(db, %{id: work_item_id} = row) do
    summary = fields(db, work_item_id)

    Map.merge(row, %{
      holders: summary.holders,
      started: summary.started,
      attestCounts: summary.attest_counts,
      verdictCounts: summary.verdict_counts,
      effectiveCommitRefs: summary.effective_commit_refs,
      landings: summary.landings
    })
  end

  @doc false
  def fields(db, work_item_id) do
    holders =
      query(
        db,
        "SELECT DISTINCT holderKey FROM assignments WHERE workItemId=?1 AND state='open' ORDER BY holderKey",
        [work_item_id]
      )
      |> Enum.map(&hd/1)

    started =
      query(db, "SELECT EXISTS(SELECT 1 FROM assignments WHERE workItemId=?1)", [work_item_id]) ==
        [[1]]

    attest_counts =
      query(
        db,
        "SELECT att.kind, COUNT(*) FROM attests att JOIN assignments a ON a.id=att.assignmentId WHERE a.workItemId=?1 GROUP BY att.kind ORDER BY att.kind",
        [work_item_id]
      )
      |> counts_map()

    verdict_counts =
      query(
        db,
        "SELECT att.verdictKind, COUNT(*) FROM attests att JOIN assignments a ON a.id=att.assignmentId WHERE a.workItemId=?1 AND att.kind='verdict' AND att.verdictKind IS NOT NULL GROUP BY att.verdictKind ORDER BY att.verdictKind",
        [work_item_id]
      )
      |> counts_map()

    effective_commit_refs = effective_commit_refs(db, work_item_id)
    landings = observed_landings(db, Enum.map(effective_commit_refs, & &1["commit"]))

    %{
      holders: holders,
      started: started,
      attest_counts: attest_counts,
      verdict_counts: verdict_counts,
      effective_commit_refs: effective_commit_refs,
      landings: landings
    }
  end

  @doc false
  def publish_observed_merge_in_txn(
        %Txn{} = txn,
        %{kind: "landing.observed-merge", payload: payload},
        call
      )
      when is_map(payload) do
    commits = Enum.map(["commit", "headCommit"], &Map.fetch!(payload, &1))

    matching_work_item_ids(txn, commits)
    |> Enum.each(&publish_change_in_txn(txn, &1, call))
  end

  def publish_observed_merge_in_txn(%Txn{}, _fact, _call), do: :ok

  @doc false
  def publish_assignment_change_in_txn(%Txn{} = txn, assignment_id, call) do
    case Txn.q(txn, "SELECT workItemId FROM assignments WHERE id=?1", [assignment_id]) do
      [[work_item_id]] when is_binary(work_item_id) ->
        publish_change_in_txn(txn, work_item_id, call)

      _ ->
        :ok
    end
  end

  @doc false
  def publish_change_in_txn(%Txn{} = txn, work_item_id, call)
      when is_binary(work_item_id) do
    WorkItems.touch_version_in_txn(txn, work_item_id)

    if publish_notice?(call) do
      case StateResources.query_work_item(txn, work_item_id, call) do
        nil ->
          :ok

        row ->
          Publisher.committed_in_txn(
            txn,
            "work_item.updated",
            StateResources.work_item(row),
            %{"workItemId" => work_item_id},
            Map.get(call, :firehose_hub, Hub)
          )
      end
    else
      :ok
    end
  end

  def publish_change_in_txn(%Txn{}, nil, _call), do: :ok

  defp publish_notice?(call),
    do:
      Map.get(call, :firehose_in_txn, false) or
        Map.get(call, :firehose_work_item_summary, false)

  defp effective_commit_refs(db, work_item_id) do
    query(
      db,
      """
      SELECT a.id, correction.commitRefs, att.commitRefs
      FROM assignments a
      LEFT JOIN assignment_commit_ref_corrections correction
        ON correction.assignmentId = a.id
      LEFT JOIN attests att ON att.assignmentId = a.id
      WHERE a.workItemId = ?1
      ORDER BY a.id, att.ts, att.id
      """,
      [work_item_id]
    )
    |> Enum.group_by(&hd/1)
    |> Enum.flat_map(fn {_assignment_id, rows} ->
      case Enum.find_value(rows, fn [_id, correction_refs, _attest_refs] -> correction_refs end) do
        correction_refs when is_binary(correction_refs) ->
          correction_refs
          |> JSON.decode!()
          |> Enum.map(&Map.take(&1, ["repo", "commit"]))

        nil ->
          Enum.flat_map(rows, fn [_id, _correction_refs, attest_refs] ->
            decode_refs(attest_refs)
          end)
      end
    end)
    |> Enum.uniq_by(&{&1["repo"], &1["commit"]})
    |> Enum.sort_by(&{&1["repo"], &1["commit"]})
  end

  defp matching_work_item_ids(txn, commits) do
    commit_set = MapSet.new(commits)

    Txn.q(
      txn,
      "SELECT DISTINCT workItemId FROM assignments WHERE workItemId IS NOT NULL ORDER BY workItemId",
      []
    )
    |> Enum.map(&hd/1)
    |> Enum.filter(fn work_item_id ->
      effective_commit_refs(txn, work_item_id)
      |> Enum.any?(&MapSet.member?(commit_set, &1["commit"]))
    end)
  end

  defp decode_refs(refs) when is_binary(refs), do: JSON.decode!(refs)
  defp decode_refs(_refs), do: []

  defp observed_landings(db, commits) do
    if Code.ensure_loaded?(ConditionFacts) and
         function_exported?(ConditionFacts, :landings_for_commits, 2) do
      apply(ConditionFacts, :landings_for_commits, [db, commits])
    else
      []
    end
  end

  defp counts_map(rows), do: Map.new(rows, fn [kind, count] -> {kind, count} end)

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end
end
