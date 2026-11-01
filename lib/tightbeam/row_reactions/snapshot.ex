defmodule Tightbeam.RowReactions.Snapshot do
  @moduledoc false
  alias Tightbeam.{Assignments, DeliveryResponsibilities, Org, SessionReparent, Wakes}
  alias Tightbeam.DB.Txn

  @assignment ~w(id holderKey workItemId reviewsAssignmentId openedBySession openedByUser openedAt state outcome closedAt closingAttestId closedBySession closedByUser closedByProcess)
  def assignment(txn, id), do: one(txn, "assignments", @assignment, "id=?1", [id])

  def attest(txn, id) do
    one(
      txn,
      "attests",
      ~w(id assignmentId kind verdictKind note bySession byUser ts waitId),
      "id=?1",
      [id]
    )
  end

  def work_item(txn, id),
    do: one(txn, "work_items", ~w(id ownerUserId state), "id=?1", [id])

  def current(txn, %{"kind" => "assignment"} = event, _recorded) do
    terminal = event["terminal"]

    item =
      one(txn, "work_items", ~w(id ownerUserId deliveryOwnerSessionKey), "id=?1", [
        terminal["work_item_id"]
      ])

    delivery_owner = DeliveryResponsibilities.current_owner_in_txn(txn, terminal["work_item_id"])

    coordination_parent =
      SessionReparent.current_coordination_parent(txn, terminal["assignment_id"])

    personal = Org.personal_session_key(terminal["owner_user_id"])

    keys = [
      terminal["opened_by_id"],
      terminal["child_session_key"],
      personal,
      delivery_owner && delivery_owner["accountableSessionKey"],
      coordination_parent
    ]

    %{
      "work_item" => item,
      "delivery_owner" => delivery_owner,
      "coordination_parent" => coordination_parent,
      "personal_session_key" => personal,
      "opener_responsibility" =>
        DeliveryResponsibilities.responsibility_in_txn(
          txn,
          terminal["opened_by_id"],
          terminal["work_item_id"]
        ),
      "sessions" => sessions(txn, keys),
      "assignments" =>
        rows(txn, "assignments", @assignment, "workItemId=?1", [terminal["work_item_id"]])
    }
  end

  def current(txn, %{"kind" => "assignment_attest", "after" => after_event}, _recorded) do
    assignment_id = after_event["assignment"]["id"]
    context = assignment_context(txn, assignment_id)
    request_id = after_event["lateRequestId"]

    %{
      "assignment" => context.assignment,
      "work_item" => context.work_item,
      "assignment_owner_user_id" => context.owner_user_id,
      "personal_session_key" => context.personal_session_key,
      "process_notification_recipient" => context.process_notification_recipient,
      "sessions" => context.sessions,
      "request" => request(txn, request_id),
      "ruling_result_recipients" => ruling_result_recipients(txn, request_id)
    }
  end

  def current(txn, %{"kind" => "assignment_start", "after" => after_event}, _recorded) do
    context = assignment_context(txn, after_event["assignment"]["id"])

    %{
      "assignment" => context.assignment,
      "work_item" => context.work_item,
      "assignment_owner_user_id" => context.owner_user_id,
      "personal_session_key" => context.personal_session_key,
      "process_notification_recipient" => context.process_notification_recipient,
      "sessions" => context.sessions
    }
  end

  def current(txn, %{"kind" => "wake_delivery", "delivery" => delivery} = event, _recorded) do
    delivered = event["after"]

    root_id =
      if delivered["obligationNamespace"] == "terminal-child-owner-notification",
        do: delivered["wakeId"],
        else: delivered["obligationTarget"]

    root = wake(txn, root_id)
    roots = if root, do: [root], else: []
    sources = Enum.flat_map(roots, &terminal_sources(txn, &1))
    child = List.first(sources)

    child =
      if child,
        do:
          one(txn, "sessions", ~w(sessionKey state), "sessionKey=?1", [child["childSessionKey"]])

    attests = Enum.flat_map(sources, &receipt_candidates_in_txn(txn, delivery["sessionKey"], &1))

    %{
      "sessions" => sessions(txn, [delivery["sessionKey"]]),
      "assignments" =>
        rows(txn, "assignments", @assignment, "holderKey=?1", [delivery["sessionKey"]]),
      "attests" => attests,
      "wakes" => Enum.uniq_by([delivered | roots], & &1["wakeId"]),
      "terminal_sources" => sources,
      "child" => child,
      "parent_activity_at" =>
        Tightbeam.Supervision.holder_activity_in_txn(txn, delivery["sessionKey"])
    }
  end

  # A binary prefix range uses the receipt index, so unrelated lifetime
  # progress is neither scanned nor materialized for each pending handoff.
  def receipt_candidates_in_txn(txn, parent, source) do
    prefix =
      "completion-handoff-action #{source["assignmentId"]} #{source["sourceKind"]} #{source["sourceToken"]} "

    upper = String.trim_trailing(prefix, " ") <> "!"

    rows(
      txn,
      "attests INDEXED BY row_reaction_receipt_candidates",
      ~w(id assignmentId kind bySession byUser ts note),
      "bySession=?1 AND kind='progress' AND note>=?2 AND note<?3",
      [parent, prefix, upper]
    )
    |> Enum.map(&Map.put(&1, "disposition", disposition(&1["note"])))
  end

  def wake(txn, id) do
    row =
      one(
        txn,
        "wakes",
        ~w(wakeId sessionKey ownerUserId creatorSessionKey assignmentId origin obligationRef conditionKind conditionScope dueAt firedAt deliveredTurnSeq state prompt),
        "wakeId=?1",
        [id]
      )

    if row do
      {namespace, target} =
        case String.split(row["obligationRef"] || "", ":", parts: 2) do
          [namespace, target] -> {namespace, target}
          _ -> {nil, nil}
        end

      row |> Map.put("obligationNamespace", namespace) |> Map.put("obligationTarget", target)
    end
  end

  def assignment_context(txn, id) do
    assignment = assignment(txn, id)
    work_item = assignment && work_item(txn, assignment["workItemId"])

    {notification_session, notification_owner} =
      if assignment,
        do: Assignments.process_notification_recipient_in_txn(txn, id),
        else: {nil, nil}

    owner_user_id =
      (work_item && work_item["ownerUserId"]) || notification_owner ||
        assignment_owner_from_sessions(txn, assignment)

    process_recipient =
      if assignment && is_nil(assignment["openedBySession"]) &&
           is_nil(assignment["openedByUser"]) do
        %{
          "sessionKey" => notification_session || Org.personal_session_key(owner_user_id),
          "ownerUserId" => owner_user_id
        }
      end

    personal = if is_binary(owner_user_id), do: Org.personal_session_key(owner_user_id)

    keys =
      [
        assignment && assignment["holderKey"],
        assignment && assignment["openedBySession"],
        personal,
        process_recipient && process_recipient["sessionKey"]
      ]
      |> Enum.filter(&is_binary/1)

    %{
      assignment: assignment,
      work_item: work_item,
      owner_user_id: owner_user_id,
      personal_session_key: personal,
      process_notification_recipient: process_recipient,
      sessions: sessions(txn, keys)
    }
  end

  defp assignment_owner_from_sessions(_txn, nil), do: nil

  defp assignment_owner_from_sessions(txn, assignment) do
    session_owner(txn, assignment["holderKey"]) || assignment["openedByUser"] ||
      session_owner(txn, assignment["openedBySession"])
  end

  defp session_owner(_txn, nil), do: nil

  defp session_owner(txn, key) do
    case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [key]) do
      [[owner]] -> owner
      [] -> nil
    end
  end

  defp request(_txn, nil), do: nil

  defp request(txn, id) do
    one(
      txn,
      "decision_requests",
      ~w(id kind assignmentId raiserId raiserSessionKey ownerUserId status),
      "id=?1",
      [id]
    )
  end

  defp ruling_result_recipients(_txn, nil), do: []

  defp ruling_result_recipients(txn, id) do
    Txn.q(
      txn,
      """
      SELECT sessionKey,ownerUserId FROM wakes
      WHERE conditionKind='escalation-ruled' AND conditionScope=?1
        AND origin='process:tightbeam' AND sessionKey IS NOT NULL
      ORDER BY rowid
      """,
      [id]
    )
    |> Enum.map(fn [session_key, owner] ->
      %{"sessionKey" => session_key, "ownerUserId" => owner}
    end)
  end

  # A receipt records the accountable actor's statement. Parsing does not
  # assert that a child was physically retired or select a cancellation policy.
  def disposition(note) when is_binary(note) do
    case Regex.run(
           ~r/\Acompletion-handoff-action ([^\s]+) ([^\s]+) ([^\s]+) (kept|parked|retired): (.+)\z/us,
           note,
           capture: :all_but_first
         ) do
      [assignment, source, token, action, detail] ->
        if String.trim(detail) != "",
          do: %{
            "assignmentId" => assignment,
            "sourceKind" => source,
            "sourceToken" => token,
            "action" => action,
            "detail" => detail
          }

      _ ->
        nil
    end
  end

  def disposition(_), do: nil

  defp terminal_sources(txn, row) do
    case Wakes.terminal_source_in_txn(txn, row["wakeId"]) do
      {:ok, source} ->
        [
          %{
            "wakeId" => row["wakeId"],
            "sourceKind" => source.source_kind,
            "sourceToken" => source.source_token,
            "assignmentId" => source.assignment_id,
            "workItemId" => source.work_item_id,
            "childSessionKey" => source.child_session_key,
            "ownerUserId" => source.owner_user_id,
            "outcome" => source.outcome,
            "terminalAt" => source.terminal_at
          }
        ]

      _ ->
        []
    end
  end

  defp sessions(txn, keys),
    do:
      keys
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.flat_map(
        &rows(txn, "sessions", ~w(sessionKey ownerUserId state), "sessionKey=?1", [&1])
      )

  defp one(txn, table, fields, where, params),
    do: List.first(rows(txn, table, fields, where, params))

  defp rows(txn, table, fields, where, params),
    do:
      Txn.q(txn, "SELECT #{Enum.join(fields, ",")} FROM #{table} WHERE #{where}", params)
      |> Enum.map(&Map.new(Enum.zip(fields, &1)))
end
