defmodule Tightbeam.RowReactions.Snapshot do
  @moduledoc false
  alias Tightbeam.DB.Txn

  def turn(txn, seq) do
    keys =
      ~w(seq sessionKey messageId wakeId origin assignmentId jobRef status createdAt startedAt endedAt error)

    case Txn.q(txn, "SELECT #{Enum.join(keys, ",")},jobRef FROM turns WHERE seq=?1", [seq]) do
      [row] -> Map.new(Enum.zip(keys ++ ["workItemId"], row))
      [] -> nil
    end
  end

  @attest_keys ~w(id assignmentId kind verdictKind bySession byUser ts)

  def attest_event(txn, id) do
    row =
      one(txn, "SELECT #{Enum.join(@attest_keys, ",")} FROM attests WHERE id=?1", @attest_keys, [
        id
      ])

    [[owner]] =
      Txn.q(
        txn,
        "SELECT s.ownerUserId FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey WHERE a.id=?1",
        [row["assignmentId"]]
      )

    principal =
      if row["bySession"],
        do: %{"kind" => "session", "id" => row["bySession"]},
        else: %{"kind" => "user", "id" => row["byUser"]}

    request_id =
      case Tightbeam.Assignments.late_ruling_receipt_request_id(row["verdictKind"]) do
        {:ok, id} -> id
        :ordinary -> nil
      end

    %{
      "id" => "attest:" <> id,
      "org" => owner,
      "kind" => "attest",
      "verb" => "attest",
      "at" => row["ts"],
      "before" => nil,
      "after" => row,
      "principal" => principal,
      "requestId" => request_id
    }
  end

  @request_fields [
    id: "id",
    kind: "kind",
    raiser_id: "raiserId",
    raiser_session_key: "raiserSessionKey",
    owner_user_id: "ownerUserId",
    assignment_id: "assignmentId",
    expecter_session_key: "expecterSessionKey",
    expecter_user_id: "expecterUserId",
    status: "status",
    raised_at: "raisedAt",
    ruled_at: "ruledAt",
    consumed_at: "consumedAt",
    answered_at: "answeredAt",
    returned_at: "returnedAt",
    context: "context",
    withdrawn_at: "withdrawnAt",
    withdrawn_by: "withdrawnBy",
    withdrawn_reason: "withdrawnReason"
  ]

  def request_row(nil), do: nil

  def request_row(row),
    do: Map.new(@request_fields, fn {key, name} -> {name, Map.fetch!(row, key)} end)

  @assignment_keys ~w(id holderKey workItemId openedBySession openedByUser state outcome closedAt closingAttestId closedBySession closedByUser closedByProcess)

  def assignment_row(txn, id),
    do:
      one(
        txn,
        "SELECT #{Enum.join(@assignment_keys, ",")} FROM assignments WHERE id=?1",
        @assignment_keys,
        [id]
      )

  @wake_keys ~w(wakeId sessionKey ownerUserId origin state createdAt dueAt firedAt deliveredTurnSeq creatorSessionKey assignmentId obligationRef)

  def wake(txn, id) do
    case one(txn, "SELECT #{Enum.join(@wake_keys, ",")} FROM wakes WHERE wakeId=?1", @wake_keys, [
           id
         ]) do
      nil ->
        nil

      row ->
        {namespace, target} = obligation_reference(row["obligationRef"])
        row |> Map.put("obligationNamespace", namespace) |> Map.put("obligationTarget", target)
    end
  end

  defp obligation_reference(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [namespace, target] when namespace != "" and target != "" -> {namespace, target}
      _ -> {nil, nil}
    end
  end

  defp obligation_reference(_), do: {nil, nil}

  # This is the existing receipt convention, not a determination that an action
  # was taken or that this receipt satisfies a particular reminder.
  def disposition(note) when is_binary(note) do
    case Regex.run(
           ~r/\Acompletion-handoff-action ([^\s]+) ([^\s]+) ([^\s]+) (kept|parked|retired): (.+)\z/u,
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
          },
          else: nil

      _ ->
        nil
    end
  end

  def disposition(_), do: nil

  def current(txn, %{"kind" => "assignment", "after" => row, "source" => source}, recorded) do
    item_keys = ~w(id ownerUserId deliveryOwnerSessionKey state)
    attest_keys = ~w(id assignmentId kind bySession byUser ts)

    revocation_keys =
      ~w(id assignmentId revokedAt revokedBySession revokedByUser revokedByProcess)

    item = one(txn, "SELECT #{Enum.join(item_keys, ",")} FROM work_items WHERE id=?1", item_keys, [row["workItemId"]])
    current_assignment = assignment_row(txn, row["id"])

    recorded
    |> addressed(txn, [row, current_assignment, item])
    |> Map.put("assignment", current_assignment)
    |> Map.put(
      "work_item",
      item
    )
    |> Map.put(
      "assignments",
      rows(
        txn,
        "SELECT #{Enum.join(@assignment_keys, ",")} FROM assignments WHERE workItemId=?1 AND holderKey=?2 AND state='open' ORDER BY openedAt,id",
        @assignment_keys,
        [row["workItemId"], row["openedBySession"]]
      )
    )
    |> Map.put(
      "attest",
      if(source["kind"] == "attest",
        do:
          one(
            txn,
            "SELECT #{Enum.join(attest_keys, ",")} FROM attests WHERE id=?1 AND assignmentId=?2",
            attest_keys,
            [source["id"], row["id"]]
          )
      )
    )
    |> Map.put(
      "revocation",
      if(source["kind"] == "assignment_revocation",
        do:
          one(
            txn,
            "SELECT #{Enum.join(revocation_keys, ",")} FROM assignment_revocations WHERE id=?1 AND assignmentId=?2",
            revocation_keys,
            [source["id"], row["id"]]
          )
      )
    )
  end

  def current(txn, %{"kind" => "wake_delivery", "after" => row, "delivery" => delivery}, recorded) do
    wakes = referenced_wakes(txn, [row["wakeId"]], MapSet.new(), [])
    sources = Enum.flat_map(wakes, &terminal_sources(txn, &1))

    recorded
    |> addressed(txn, [row, delivery, wakes, sources])
    |> Map.put("wakes", wakes)
    |> Map.put(
      "wake_retries",
      Enum.flat_map(wakes, fn wake ->
        rows(
          txn,
          "SELECT wakeId,rootWakeId FROM wake_retry_attempts WHERE wakeId=?1",
          ~w(wakeId rootWakeId),
          [wake["wakeId"]]
        )
      end)
    )
    |> Map.put(
      "assignments",
      rows(
        txn,
        "SELECT #{Enum.join(@assignment_keys, ",")} FROM assignments WHERE holderKey=?1 AND state='open' ORDER BY openedAt,id",
        @assignment_keys,
        [delivery["sessionKey"]]
      )
    )
    |> Map.put("attests", receipts(txn, delivery["sessionKey"], sources))
    |> Map.put("terminal_sources", sources)
  end

  def current(txn, %{"kind" => "decision_request", "after" => row} = event, recorded) do
    request = Tightbeam.Escalation.raw_by_id_in_txn(txn, row["id"]) |> request_row()
    assignment_id = request["assignmentId"]

    condition_keys =
      ~w(id assignmentId attestId decisionRequestId decisionWakeId openerRef disposerRef reason releaseFactKind releaseFactScope releaseFactPrincipalRef state createdAt settledAt settlementKind settlementFactId settledBy)

    condition =
      one(
        txn,
        "SELECT #{Enum.join(condition_keys, ",")} FROM assignment_cannot_proceed WHERE decisionRequestId=?1",
        condition_keys,
        [request["id"]]
      )

    fact_keys = ~w(id kind scope ts origin ownerUserId payload)

    fact =
      one(
        txn,
        "SELECT #{Enum.join(fact_keys, ",")} FROM condition_facts WHERE id=?1",
        fact_keys,
        [condition && condition["settlementFactId"]]
      )

    current_assignment = assignment(txn, assignment_id)

    recorded
    |> addressed(txn, [event, request, current_assignment])
    |> Map.put("decision_request", request)
    |> Map.put("assignment", current_assignment)
    |> Map.put("cannot_proceed", condition)
    |> Map.put(
      "settlement_fact",
      if(fact, do: Map.update!(fact, "payload", &decode/1), else: nil)
    )
    |> Map.put("explicit_notices", explicit_notices(txn, event, request["id"]))
    |> Map.put("related_actions", related_actions(txn, event["org"], request["id"]))
  end

  def current(txn, %{"kind" => "attest", "after" => row} = event, recorded) do
    request =
      case event["requestId"] do
        nil -> nil
        id -> Tightbeam.Escalation.raw_by_id_in_txn(txn, id) |> request_row()
      end

    current_assignment = assignment(txn, row["assignmentId"])

    recorded
    |> addressed(txn, [event, request, current_assignment])
    |> Map.put("decision_request", request)
    |> Map.put("assignment", current_assignment)
    |> Map.put("attests", Enum.uniq_by([row | first_receipt(txn, row["assignmentId"], request)], & &1["id"]))
    |> Map.put("explicit_notices", explicit_notices(txn, event, event["requestId"]))
    |> Map.put("related_actions", related_actions(txn, event["org"], event["requestId"]))
  end

  def current(txn, %{"kind" => "turn", "after" => row} = event, recorded) do
    {assignment, turns} = turn_relations(txn, row)

    recorded
    |> addressed(txn, [event, assignment])
    |> Map.put("assignment", assignment)
    |> Map.put("turns", turns)
  end

  def current(_txn, _event, recorded), do: recorded

  defp explicit_notices(_txn, _event, nil), do: []

  defp explicit_notices(txn, event, request_id) do
    prior =
      Txn.q(
        txn,
        "SELECT event FROM row_reaction_events WHERE org=?1 AND COALESCE(json_extract(event,'$.requestId'),CASE WHEN json_extract(event,'$.kind')='decision_request' THEN json_extract(event,'$.after.id') END)=?2 AND json_extract(event,'$.kind')='decision_request' ",
        [event["org"], request_id]
      )

    outputs =
      [event | Enum.map(prior, fn [json] -> JSON.decode!(json) end)]
      |> Enum.flat_map(&Map.get(&1, "outputs", []))
      |> Enum.uniq()

    captured =
      Enum.flat_map(outputs, fn output ->
        rows(
          txn,
          "SELECT wakeId,sessionKey,state FROM wakes WHERE wakeId=?1",
          ~w(wakeId sessionKey state),
          [output["wakeId"]]
        )
        |> Enum.map(
          &Map.merge(&1, %{"requestId" => request_id, "operation" => output["operation"]})
        )
      end)

    # Older operator rulings already carry a structured request reference and
    # canonical rendering. Initial ask outputs had no such stored relation.
    legacy =
      rows(
        txn,
        """
        SELECT w.wakeId,w.sessionKey,w.state FROM wakes w
        JOIN decision_requests r ON r.id=w.conditionScope
        WHERE r.id=?1 AND r.kind='operator' AND w.conditionKind='escalation-ruled'
          AND w.origin='process:tightbeam' AND w.consumer='prompt' AND w.prompt=?2
        """,
        ~w(wakeId sessionKey state),
        [request_id, Tightbeam.Escalation.terminal_notification(request_id)]
      )
      |> Enum.map(&Map.merge(&1, %{"requestId" => request_id, "operation" => "operator-rule"}))

    Enum.uniq(captured ++ legacy)
  end

  defp related_actions(_txn, _org, nil), do: []

  # Correlate only this request. Never embed another event's snapshot: it may
  # itself refer to earlier actions. The event key preserves durable provenance.
  defp related_actions(txn, org, request_id) do
    rows(
      txn,
      """
      SELECT a.id,a.family,a.slot,a.status,a.result,a.plan,e.eventId,
             json_extract(e.event,'$.kind')
      FROM row_reaction_events e JOIN row_reaction_actions a ON e.org=a.org AND e.eventId=a.eventId
      WHERE e.org=?1 AND COALESCE(json_extract(e.event,'$.requestId'),
        CASE WHEN json_extract(e.event,'$.kind')='decision_request' THEN json_extract(e.event,'$.after.id') END)=?2
      ORDER BY e.admittedAt,e.eventId,a.id
      """,
      ~w(id family slot status result plan eventId eventKind),
      [org, request_id]
    )
    |> Enum.map(fn row ->
      row
      |> Map.update!("result", &decode/1)
      |> Map.update!("plan", &decode/1)
      |> Map.put("event", %{"id" => row["eventId"], "kind" => row["eventKind"]})
      |> Map.put("facts", %{"decision_request" => %{"id" => request_id}})
      |> Map.put("source_ref", %{"org" => org, "event_id" => row["eventId"]})
    end)
  end

  defp first_receipt(_txn, _assignment, nil), do: []

  defp first_receipt(txn, assignment_id, request) do
    rows(txn,
      "SELECT #{Enum.join(@attest_keys, ",")} FROM attests WHERE assignmentId=?1 AND kind='verdict' AND verdictKind=?2 ORDER BY ts,id LIMIT 1",
      @attest_keys, [assignment_id, "ruling-consumed:" <> request["id"]])
  end

  defp receipts(txn, recipient, sources) do
    keys = ~w(id assignmentId kind bySession byUser ts note)

    sources
    |> Enum.map(&Map.take(&1, ~w(assignmentId sourceKind sourceToken)))
    |> Enum.uniq()
    |> Enum.flat_map(fn source ->
      prefix = "completion-handoff-action #{source["assignmentId"]} #{source["sourceKind"]} #{source["sourceToken"]}"
      # An indexed exact-prefix range avoids fetching unrelated attest notes.
      # Parsing still checks the complete existing convention, including detail.
      rows(txn, "SELECT #{Enum.join(keys, ",")} FROM attests WHERE bySession=?1 AND kind='progress' AND note>=?2 AND note<?3 ORDER BY ts,id",
        keys, [recipient, prefix <> " ", prefix <> "!"])
      |> Enum.map(&Map.put(&1, "disposition", disposition(&1["note"])))
    end)
  end

  defp referenced_wakes(_txn, [], _seen, acc), do: Enum.reverse(acc)

  defp referenced_wakes(txn, [id | rest], seen, acc) do
    if is_nil(id) or MapSet.member?(seen, id) do
      referenced_wakes(txn, rest, seen, acc)
    else
      seen = MapSet.put(seen, id)

      case wake(txn, id) do
        nil ->
          referenced_wakes(txn, rest, seen, acc)

        row ->
          roots =
            Txn.q(txn, "SELECT rootWakeId FROM wake_retry_attempts WHERE wakeId=?1", [id])
            |> List.flatten()

          referenced_wakes(txn, rest ++ [row["obligationTarget"] | roots], seen, [row | acc])
      end
    end
  end

  # New outputs carry their immutable source event in the action ledger. Read
  # that relation without re-rendering today's prompt or electing a recipient.
  defp terminal_sources(txn, wake) do
    events =
      Txn.q(
        txn,
        """
        SELECT DISTINCT e.event FROM row_reaction_actions a
        JOIN row_reaction_events e ON e.org=a.org AND e.eventId=a.eventId
        WHERE (json_extract(a.result,'$.wake_id')=?1
          OR json_extract(a.result,'$.wake_id') IN
            (SELECT rootWakeId FROM wake_retry_attempts WHERE wakeId=?1))
          AND json_extract(e.event,'$.kind')='assignment'
        """,
        [wake["wakeId"]]
      )
      |> Enum.map(fn [json] -> JSON.decode!(json) end)

    Enum.map(events, fn event ->
      row = event["after"]

      %{
        "wakeId" => wake["wakeId"],
        "sourceKind" => event["source"]["kind"],
        "sourceToken" => event["source"]["id"],
        "assignmentId" => row["id"],
        "workItemId" => row["workItemId"],
        "childSessionKey" => row["holderKey"],
        "ownerUserId" => wake["ownerUserId"],
        "outcome" => row["outcome"],
        "terminalAt" => event["at"]
      }
    end)
  end

  defp decode(nil), do: nil
  defp decode(value), do: JSON.decode!(value)

  defp assignment(txn, id) do
    keys = ~w(id holderKey openedBySession openedByUser state outcome workItemId)
    one(txn, "SELECT #{Enum.join(keys, ",")} FROM assignments WHERE id=?1", keys, [id])
  end

  # Read the addressed neighborhood, plus literal addresses in the elected
  # declarations (so changing a rail's recipient remains dynamic). This depends
  # on the current source and election size, never the session population.
  defp addressed(recorded, txn, relations) do
    addresses = strings([relations, Tightbeam.Rules.reactions()]) |> Enum.uniq()
    sessions = session_rows(txn, addresses)
    owner_ids = Enum.map(sessions, & &1["ownerUserId"])
    original_owners = Enum.map(Map.get(recorded, "sessions", []), & &1["ownerUserId"])
    users = rows(txn, "SELECT userId,isAdmin,createdAt FROM users WHERE userId IN (SELECT value FROM json_each(?1))",
      ~w(userId isAdmin createdAt), [JSON.encode!(Enum.uniq(addresses ++ owner_ids ++ original_owners))])
      |> Enum.map(&Map.put(&1, "personalSessionKey", Tightbeam.Org.personal_session_key(&1["userId"])))
    sessions = (sessions ++ session_rows(txn, Enum.map(users, & &1["personalSessionKey"]))) |> Enum.uniq_by(& &1["sessionKey"])
    recorded |> Map.put("sessions", sessions) |> Map.put("users", users)
  end

  defp session_rows(txn, addresses), do: rows(txn,
    "SELECT sessionKey,ownerUserId,state,identityRevision FROM sessions WHERE sessionKey IN (SELECT value FROM json_each(?1))",
    ~w(sessionKey ownerUserId state identityRevision), [JSON.encode!(addresses)])

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(_), do: []

  defp one(txn, sql, keys, params), do: List.first(rows(txn, sql, keys, params))

  defp turn_relations(txn, %{"status" => "running", "assignmentId" => id}) do
    keys = ~w(id holderKey openedBySession openedByUser state outcome workItemId)

    assignment =
      case rows(txn, "SELECT #{Enum.join(keys, ",")} FROM assignments WHERE id=?1", keys, [id]) do
        [row] -> row
        [] -> nil
      end

    turns =
      rows(
        txn,
        "SELECT seq,sessionKey,assignmentId,jobRef,status,startedAt FROM turns WHERE assignmentId=?1 AND sessionKey=?2 AND startedAt IS NOT NULL ORDER BY startedAt,seq LIMIT 1",
        ~w(seq sessionKey assignmentId workItemId status startedAt),
        [id, assignment && assignment["holderKey"]]
      )

    {assignment, turns}
  end

  defp turn_relations(_txn, _row), do: {nil, []}

  defp rows(txn, sql, keys, params \\ []),
    do: Enum.map(Txn.q(txn, sql, params), &Map.new(Enum.zip(keys, &1)))
end
