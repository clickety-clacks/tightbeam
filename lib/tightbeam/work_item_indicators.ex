defmodule Tightbeam.WorkItemIndicators do
  @moduledoc "One bounded read of the small facts a page of work items shows. Computed on read."
  alias Tightbeam.{DB, StateResources, StateVisibility, WaitLinks}
  alias Tightbeam.DB.Txn

  # Per id list, so a page can name its items and its cards in one read.
  @max_ids 50
  @max_links 20

  def request(query) do
    with true <- Map.keys(query) -- ~w(asUser workItemIds assignmentIds) == [],
         {:ok, items} <- ids(query["workItemIds"]),
         {:ok, assignments} <- ids(query["assignmentIds"]),
         false <- items == [] and assignments == [] do
      if length(items) > @max_ids or length(assignments) > @max_ids,
        do:
          {:error, 400, "too_many_ids",
           "Name at most #{@max_ids} workItemIds and #{@max_ids} assignmentIds per read."},
        else: {:ok, %{items: items, assignments: assignments}}
    else
      _ ->
        {:error, 400, "invalid_indicators_query",
         "Use workItemIds and/or assignmentIds, each one comma-separated list of ids."}
    end
  end

  defp ids(nil), do: {:ok, []}

  defp ids([text]) do
    ids = String.split(text, ",")
    if "" in ids, do: :error, else: {:ok, Enum.uniq(ids)}
  end

  defp ids(_), do: :error

  def read(db, request, principal) do
    DB.read_transaction!(db, fn txn ->
      txn = Txn.observe_queries(txn, Map.get(principal, :core_detail_trace))
      read_in_txn(txn, request, principal)
    end)
  end

  defp read_in_txn(txn, request, principal) do
    assignments = StateResources.query_assignment_items(txn, request.assignments, principal)

    named =
      (request.items ++
         Enum.map(request.assignments, &get_in(assignments, [&1, Access.key(:workItemId)])))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    states = StateResources.query_work_item_states(txn, named, principal)
    visible = Enum.filter(named, &is_map_key(states, &1))
    # Waits, questions and running come from wait links and follow their flag.
    linked = if WaitLinks.enabled?(), do: WaitLinks.linked(txn, visible), else: %{}
    running = running_cards(txn, visible, principal)

    %{
      schemaVersion: 1,
      resource: "work item indicators",
      asOf: System.system_time(:millisecond),
      items:
        Enum.map(visible, fn id ->
          item(
            txn,
            states[id],
            linked[id],
            Map.get(running, id, []),
            principal
          )
        end),
      assignments:
        request.assignments
        |> Enum.filter(&is_map_key(assignments, &1))
        |> Enum.map(&assignments[&1]),
      notFound: %{
        workItemIds: named -- visible,
        assignmentIds: Enum.reject(request.assignments, &is_map_key(assignments, &1))
      }
    }
  end

  defp item(_txn, row, nil, running, _principal), do: Map.put(row, :runningCards, running)

  defp item(txn, row, linked, running, principal) do
    Map.merge(row, %{
      waiting: linked.waiting,
      running: linked.running,
      waits: Enum.map(Enum.take(linked.waits, @max_links), &WaitLinks.wait(txn, &1, principal)),
      waitsTruncated: length(linked.waits) > @max_links,
      questions: %{
        count: length(linked.questions),
        items:
          Enum.map(
            Enum.take(linked.questions, @max_links),
            &WaitLinks.question(txn, &1, principal)
          ),
        truncated: length(linked.questions) > @max_links
      },
      runningCards: running
    })
  end

  # Open cards whose holder is in a turn, with whatever work that turn recorded.
  # The status list is the running-turn index's own predicate.
  defp running_cards(_txn, [], _principal), do: %{}

  defp running_cards(txn, ids, principal) do
    Txn.q(
      txn,
      """
      SELECT a.workItemId,a.id,a.holderKey,t.seq,t.startedAt,t.assignmentId,t.jobRef
      FROM json_each(?1) i CROSS JOIN assignments a ON a.workItemId=i.value AND a.state='open'
      CROSS JOIN turns t INDEXED BY turns_pending ON t.sessionKey=a.holderKey
        AND t.status IN ('queued','running') AND t.status='running'
      ORDER BY a.openedAt,a.id
      """,
      [JSON.encode!(ids)]
    )
    |> Enum.filter(fn [_item, _card, holder | _turn] ->
      StateVisibility.core_detail_visible?(txn, "turns", %{session_key: holder}, principal)
    end)
    |> Enum.group_by(&hd/1, fn [_item, card, holder, seq, started, assignment, work_item] ->
      %{
        assignmentId: card,
        holderKey: holder,
        turn: %{seq: seq, startedAt: started, assignmentId: assignment, workItemId: work_item}
      }
    end)
  end
end
