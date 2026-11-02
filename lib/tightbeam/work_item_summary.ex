defmodule Tightbeam.WorkItemSummary do
  @moduledoc false

  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.{Hub, Publisher}
  alias Tightbeam.{ConditionFacts, DB, StateResources, WorkItems}

  @doc false
  def attach(db, row), do: db |> attach_many([row]) |> hd()

  @doc false
  def attach_many(_db, []), do: []

  def attach_many(db, rows) when is_list(rows) do
    summaries = fields_many(db, Enum.map(rows, & &1.id))

    Enum.map(rows, fn row ->
      attach_fields(row, Map.fetch!(summaries, row.id))
    end)
  end

  @doc false
  def attach_fields(row, fields), do: Map.merge(row, fields)

  @doc false
  def attach_handler_row(db, row), do: db |> attach_handler_rows([row]) |> hd()

  @doc false
  def attach_handler_rows(_db, []), do: []

  def attach_handler_rows(db, rows) when is_list(rows) do
    summaries = fields_many(db, Enum.map(rows, & &1.id))

    Enum.map(rows, fn row ->
      summary = Map.fetch!(summaries, row.id)

      Map.merge(row, %{
        holders: summary.holders,
        started: summary.started,
        attestCounts: summary.attest_counts,
        verdictCounts: summary.verdict_counts,
        effectiveCommitRefs: summary.effective_commit_refs,
        landings: summary.landings
      })
    end)
  end

  @doc false
  def fields(db, work_item_id), do: Map.fetch!(fields_many(db, [work_item_id]), work_item_id)

  @doc false
  def fields_many(_db, []), do: %{}

  def fields_many(db, work_item_ids) when is_list(work_item_ids) do
    work_item_ids = Enum.uniq(work_item_ids)
    work_item_ids_json = JSON.encode!(work_item_ids)
    empty = empty_fields()
    summaries = Map.new(work_item_ids, &{&1, empty})

    holders =
      query(
        db,
        """
        SELECT workItemId, holderKey
        FROM assignments
        WHERE workItemId IN (SELECT value FROM json_each(?1)) AND state='open'
        GROUP BY workItemId, holderKey
        ORDER BY workItemId, holderKey
        """,
        [work_item_ids_json]
      )
      |> Enum.reduce(%{}, fn [work_item_id, holder], acc ->
        Map.update(acc, work_item_id, [holder], &[holder | &1])
      end)
      |> Map.new(fn {work_item_id, reversed_holders} ->
        {work_item_id, Enum.reverse(reversed_holders)}
      end)

    started =
      query(
        db,
        "SELECT DISTINCT workItemId FROM assignments WHERE workItemId IN (SELECT value FROM json_each(?1))",
        [work_item_ids_json]
      )
      |> Map.new(fn [work_item_id] -> {work_item_id, true} end)

    attest_counts =
      query(
        db,
        """
        SELECT a.workItemId, att.kind, COUNT(*)
        FROM attests att
        JOIN assignments a ON a.id=att.assignmentId
        WHERE a.workItemId IN (SELECT value FROM json_each(?1))
        GROUP BY a.workItemId, att.kind
        ORDER BY a.workItemId, att.kind
        """,
        [work_item_ids_json]
      )
      |> grouped_counts()

    verdict_counts =
      query(
        db,
        """
        SELECT a.workItemId, att.verdictKind, COUNT(*)
        FROM attests att
        JOIN assignments a ON a.id=att.assignmentId
        WHERE a.workItemId IN (SELECT value FROM json_each(?1))
          AND att.kind='verdict' AND att.verdictKind IS NOT NULL
        GROUP BY a.workItemId, att.verdictKind
        ORDER BY a.workItemId, att.verdictKind
        """,
        [work_item_ids_json]
      )
      |> grouped_counts()

    effective_refs_by_item = effective_commit_refs_many(db, work_item_ids_json)

    commits =
      effective_refs_by_item
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1["commit"])
      |> Enum.uniq()

    landings_by_item =
      commits
      |> then(&observed_landings(db, &1))
      |> associate_landings(effective_refs_by_item)

    summaries
    |> put_fields(:holders, holders)
    |> put_fields(:started, started)
    |> put_fields(:attest_counts, attest_counts)
    |> put_fields(:verdict_counts, verdict_counts)
    |> put_fields(:effective_commit_refs, effective_refs_by_item)
    |> put_fields(:landings, landings_by_item)
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
    |> publish_observed_merge_changes(txn, call)
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

  defp publish_observed_merge_changes(work_item_ids, txn, call) do
    summary_fields_by_item =
      if publish_notice?(call), do: fields_many(txn, work_item_ids), else: nil

    Enum.each(work_item_ids, fn work_item_id ->
      call =
        if is_map(summary_fields_by_item) do
          Map.put(call, :work_item_summary_fields_by_id, summary_fields_by_item)
        else
          call
        end

      publish_change_in_txn(txn, work_item_id, call)
    end)
  end

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
    commits = Enum.uniq(commits)

    if commits == [] do
      []
    else
      commit_set = MapSet.new(commits)

      candidates =
        Txn.q(
          txn,
          """
          SELECT workItemId FROM (
            SELECT a.workItemId
            FROM assignments a
            JOIN assignment_commit_ref_corrections correction
              ON correction.assignmentId = a.id
            JOIN json_each(correction.commitRefs) refs
            WHERE a.workItemId IS NOT NULL
              AND json_extract(refs.value, '$.commit') IN
                (SELECT value FROM json_each(?1))
            UNION
            SELECT a.workItemId
            FROM assignments a
            JOIN attests att ON att.assignmentId = a.id
            JOIN json_each(att.commitRefs) refs
            WHERE a.workItemId IS NOT NULL
              AND att.commitRefs IS NOT NULL
              AND NOT EXISTS (
                SELECT 1 FROM assignment_commit_ref_corrections correction
                WHERE correction.assignmentId = a.id
              )
              AND json_extract(refs.value, '$.commit') IN
                (SELECT value FROM json_each(?1))
          ) candidates
          ORDER BY workItemId
          """,
          [JSON.encode!(commits)]
        )
        |> Enum.map(&hd/1)

      Enum.filter(candidates, fn work_item_id ->
        effective_commit_refs(txn, work_item_id)
        |> Enum.any?(&MapSet.member?(commit_set, &1["commit"]))
      end)
    end
  end

  defp effective_commit_refs_many(db, work_item_ids_json) do
    query(
      db,
      """
      SELECT a.workItemId, a.id, correction.commitRefs, NULL
      FROM assignments a
      JOIN assignment_commit_ref_corrections correction
        ON correction.assignmentId = a.id
      WHERE a.workItemId IN (SELECT value FROM json_each(?1))
      UNION ALL
      SELECT a.workItemId, a.id, NULL, att.commitRefs
      FROM assignments a
      JOIN attests att ON att.assignmentId = a.id
      WHERE a.workItemId IN (SELECT value FROM json_each(?1))
        AND att.commitRefs IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM assignment_commit_ref_corrections correction
          WHERE correction.assignmentId = a.id
        )
      """,
      [work_item_ids_json]
    )
    |> Enum.group_by(fn [work_item_id, assignment_id, _correction_refs, _attest_refs] ->
      {work_item_id, assignment_id}
    end)
    |> Enum.map(fn {{work_item_id, _assignment_id}, rows} ->
      refs =
        case Enum.find_value(rows, fn [_item_id, _id, correction_refs, _attest_refs] ->
               correction_refs
             end) do
          correction_refs when is_binary(correction_refs) ->
            correction_refs
            |> decode_refs()
            |> Enum.map(&Map.take(&1, ["repo", "commit"]))

          nil ->
            Enum.flat_map(rows, fn [_item_id, _id, _correction_refs, attest_refs] ->
              decode_refs(attest_refs)
            end)
        end

      {work_item_id, refs}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {work_item_id, refs_by_assignment} ->
      refs =
        refs_by_assignment
        |> List.flatten()
        |> Enum.uniq_by(&{&1["repo"], &1["commit"]})
        |> Enum.sort_by(&{&1["repo"], &1["commit"]})

      {work_item_id, refs}
    end)
  end

  defp associate_landings(landings, effective_refs_by_item) do
    items_by_commit =
      Enum.reduce(effective_refs_by_item, %{}, fn {work_item_id, refs}, acc ->
        Enum.reduce(refs, acc, fn ref, by_commit ->
          Map.update(by_commit, ref["commit"], [work_item_id], &[work_item_id | &1])
        end)
      end)

    landings
    |> Enum.reduce(%{}, fn landing, acc ->
      item_ids =
        [landing["commit"], landing["headCommit"]]
        |> Enum.flat_map(&Map.get(items_by_commit, &1, []))
        |> Enum.uniq()

      Enum.reduce(item_ids, acc, fn work_item_id, by_item ->
        Map.update(by_item, work_item_id, [landing], &[landing | &1])
      end)
    end)
    |> Map.new(fn {work_item_id, reversed_landings} ->
      {work_item_id, Enum.sort_by(reversed_landings, &{&1["observedAt"], &1["pullRequest"]})}
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

  defp empty_fields do
    %{
      holders: [],
      started: false,
      attest_counts: %{},
      verdict_counts: %{},
      effective_commit_refs: [],
      landings: []
    }
  end

  defp grouped_counts(rows) do
    rows
    |> Enum.group_by(fn [work_item_id, _kind, _count] -> work_item_id end)
    |> Map.new(fn {work_item_id, item_rows} ->
      {work_item_id, counts_map(item_rows)}
    end)
  end

  defp counts_map(rows), do: Map.new(rows, fn [_work_item_id, kind, count] -> {kind, count} end)

  defp put_fields(summaries, field, values) do
    Enum.reduce(values, summaries, fn {work_item_id, value}, acc ->
      Map.update!(acc, work_item_id, &Map.put(&1, field, value))
    end)
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end
end
