defmodule Tightbeam.JobTrace do
  @moduledoc "Pinned, read-only work-item trace artifact."

  alias Tightbeam.DB

  @type_rank %{
    "turn_start" => 0,
    "wake_scheduled" => 1,
    "wake_fired" => 2,
    "decision_request" => 3,
    "effort_generation" => 4,
    "attest" => 5,
    "turn_end" => 6
  }

  @spec build(DB.server(), map()) :: map()
  def build(db, item) do
    assignments = assignments(db, item.id)
    assignment_ids = Enum.map(assignments, & &1.id)

    %{
      workItem: %{
        id: item.id,
        ownerUserId: item.ownerUserId,
        state: item.state,
        failReason: item.failReason,
        title: item.title
      },
      assignments: assignments,
      timeline:
        (turn_entries(db, item.id) ++
           attest_entries(db, assignment_ids) ++
           wake_entries(db, item.id, assignment_ids) ++
           decision_entries(db, assignment_ids) ++ effort_entries(db, assignment_ids))
        |> Enum.sort_by(fn entry ->
          {entry.at, Map.fetch!(@type_rank, entry.type), entry.id}
        end)
    }
  end

  defp assignments(db, work_item_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        WITH RECURSIVE members(id) AS (
          SELECT id FROM assignments WHERE workItemId = ?1
          UNION
          SELECT review.id
          FROM assignments AS review
          JOIN members AS target ON review.reviewsAssignmentId = target.id
        )
        SELECT a.id, a.holderKey, a.openedByUser, a.openedBySession, a.state,
               a.reviewsAssignmentId
        FROM assignments AS a
        JOIN members AS m ON m.id = a.id
        ORDER BY a.id ASC
        """,
        [work_item_id]
      )

    Enum.map(rows, fn [id, holder, opened_user, opened_session, state, reviews] ->
      %{
        id: id,
        holderKey: holder,
        openerRef: opener_ref(opened_user, opened_session),
        state: state,
        files: assignment_files(db, id),
        reviewsAssignmentId: reviews
      }
    end)
  end

  defp assignment_files(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT path FROM assignment_files WHERE assignmentId = ?1 ORDER BY path ASC",
        [assignment_id]
      )

    Enum.map(rows, &hd/1)
  end

  defp opener_ref(user, nil), do: "user:" <> user
  defp opener_ref(nil, session), do: "session:" <> session

  defp turn_entries(db, work_item_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT seq, assignmentId, jobRef, status, model, harness, createdAt, endedAt
        FROM turns
        WHERE jobRef = ?1
        ORDER BY seq ASC
        """,
        [work_item_id]
      )

    Enum.flat_map(rows, fn [seq, assignment_id, job_ref, status, model, harness, created, ended] ->
      base = %{
        id: seq,
        assignmentId: assignment_id,
        jobRef: job_ref,
        status: status,
        model: model,
        harness: harness
      }

      [Map.merge(base, %{type: "turn_start", at: created})] ++
        if ended, do: [Map.merge(base, %{type: "turn_end", at: ended})], else: []
    end)
  end

  defp attest_entries(_db, []), do: []

  defp attest_entries(db, assignment_ids) do
    {clause, params} = in_clause(assignment_ids)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT id, assignmentId, kind, verdictKind, commitRefs, ts
        FROM attests
        WHERE assignmentId IN (#{clause})
        """,
        params
      )

    Enum.map(rows, fn [id, assignment_id, kind, verdict, commit_refs, at] ->
      %{
        at: at,
        type: "attest",
        id: id,
        assignmentId: assignment_id,
        kind: kind,
        verdict: verdict,
        commitRefs: decode(commit_refs)
      }
    end)
  end

  defp wake_entries(db, work_item_id, assignment_ids) do
    item_wakes =
      wake_rows(
        db,
        """
        SELECT w.wakeId, NULL, w.createdAt, w.dueAt, w.firedAt, w.firedBy,
               matched_fact_at
        FROM (
          SELECT w.*,
                 CASE WHEN w.firedBy = 'condition' THEN (
                   SELECT f.ts FROM condition_facts AS f
                   WHERE f.id > w.conditionAfterId
                     AND f.kind = w.conditionKind
                     AND (w.conditionScope IS NULL OR f.scope = w.conditionScope)
                   ORDER BY f.id ASC LIMIT 1
                 ) END AS matched_fact_at
          FROM wakes AS w
        ) AS w
        WHERE w.work_item_id = ?1
        """,
        [work_item_id]
      )

    assignment_wakes =
      case assignment_ids do
        [] ->
          []

        ids ->
          {clause, params} = in_clause(ids)

          wake_rows(
            db,
            """
            WITH links(wakeId, assignmentId) AS (
              SELECT wakeId, assignmentId FROM effort_checkin_generations
              WHERE assignmentId IN (#{clause})
              UNION
              SELECT deadlineWakeId, assignmentId FROM decision_requests
              WHERE assignmentId IN (#{clause})
            )
            SELECT w.wakeId, links.assignmentId, w.createdAt, w.dueAt, w.firedAt, w.firedBy,
                   CASE WHEN w.firedBy = 'condition' THEN (
                     SELECT f.ts FROM condition_facts AS f
                     WHERE f.id > w.conditionAfterId
                       AND f.kind = w.conditionKind
                       AND (w.conditionScope IS NULL OR f.scope = w.conditionScope)
                     ORDER BY f.id ASC LIMIT 1
                   ) END
            FROM wakes AS w
            JOIN links ON links.wakeId = w.wakeId
            """,
            params
          )
      end

    (item_wakes ++ assignment_wakes)
    |> Map.new(fn {wake_id, entries} -> {wake_id, entries} end)
    |> Map.values()
    |> List.flatten()
  end

  defp wake_rows(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)

    Enum.map(rows, fn [id, assignment_id, created, due, fired, fired_by, matched_fact_at] ->
      scheduled = %{
        at: created,
        type: "wake_scheduled",
        id: id,
        assignmentId: assignment_id,
        dueAt: due
      }

      entries =
        if fired do
          [
            scheduled,
            %{
              at: fired,
              type: "wake_fired",
              id: id,
              assignmentId: assignment_id,
              firedBy: fired_by,
              matchedFactAt: matched_fact_at
            }
          ]
        else
          [scheduled]
        end

      {id, entries}
    end)
  end

  defp decision_entries(_db, []), do: []

  defp decision_entries(db, assignment_ids) do
    {clause, params} = in_clause(assignment_ids)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT id, assignmentId, status, decision, raisedAt
        FROM decision_requests
        WHERE assignmentId IN (#{clause})
        """,
        params
      )

    Enum.map(rows, fn [id, assignment_id, state, ruling, at] ->
      %{
        at: at,
        type: "decision_request",
        id: id,
        assignmentId: assignment_id,
        state: state,
        ruling: ruling
      }
    end)
  end

  defp effort_entries(_db, []), do: []

  defp effort_entries(db, assignment_ids) do
    {clause, params} = in_clause(assignment_ids)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT assignmentId, generation, state, evidence, armedAt
        FROM effort_checkin_generations
        WHERE assignmentId IN (#{clause})
        """,
        params
      )

    Enum.map(rows, fn [assignment_id, generation, state, evidence, at] ->
      %{
        at: at,
        type: "effort_generation",
        id: "gen:#{assignment_id}:#{generation}",
        assignmentId: assignment_id,
        state: state,
        evidence: decode(evidence)
      }
    end)
  end

  defp decode(nil), do: nil
  defp decode(encoded), do: JSON.decode!(encoded)

  defp in_clause(values) do
    placeholders =
      values
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_value, index} -> "?#{index}" end)

    {placeholders, values}
  end
end
