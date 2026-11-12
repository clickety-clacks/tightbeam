defmodule Tightbeam.RowReactions.Snapshot do
  @moduledoc false
  alias Tightbeam.{
    DeliveryResponsibilities,
    Harness,
    HarnessProcess,
    Org,
    SessionReparent,
    Wakes
  }

  alias Tightbeam.DB.Txn

  @assignment ~w(id holderKey workItemId openedBySession openedByUser openedAt state outcome closedAt closingAttestId closedBySession closedByUser closedByProcess)
  def assignment(txn, id), do: one(txn, "assignments", @assignment, "id=?1", [id])

  def harness_health_hold(txn, incident_id) do
    case Txn.q(
           txn,
           """
           SELECT i.id,i.harness,i.host,i.failureClass,i.state,i.openedAt,i.resolvedAt,
                  o.correlationId,
                  (SELECT s.ownerUserId FROM harness_health_members m
                   JOIN sessions s ON s.sessionKey=m.sessionKey
                   WHERE m.incidentId=i.id ORDER BY s.ownerUserId LIMIT 1)
           FROM harness_health_incidents i
           LEFT JOIN harness_health_observations o ON o.id=i.resolutionObservationId
           WHERE i.id=?1
           """,
           [incident_id]
         ) do
      [[id, harness, host, failure_class, state, opened_at, resolved_at, correlation, owner]] ->
        route_rows =
          Txn.q(
            txn,
            """
            WITH terminal_observations AS (
              SELECT o.correlationId,o.harness,o.host,o.failureClass,o.observedAt,o.id,
                     CASE
                       WHEN substr(o.correlationId,1,13)='harness-turn:'
                         AND instr(substr(o.correlationId,14),':') > 1
                         AND substr(
                               o.correlationId,
                               14,
                               instr(substr(o.correlationId,14),':') - 1
                             ) NOT GLOB '*[^0-9]*'
                       THEN CAST(
                              substr(
                                o.correlationId,
                                14,
                                instr(substr(o.correlationId,14),':') - 1
                              ) AS INTEGER
                            )
                       ELSE NULL
                     END AS turnSeq
              FROM harness_health_observations o
              WHERE o.incidentId=?1 AND o.evidenceKind='terminal-failure'
            )
            SELECT o.correlationId,o.harness,o.host,t.model
            FROM terminal_observations o
            LEFT JOIN turns t
              ON t.seq=o.turnSeq
             AND o.correlationId='harness-turn:' || t.seq || ':' || o.failureClass
            ORDER BY o.observedAt,o.id
            """,
            [incident_id]
          )

        routes =
          route_rows
          |> Enum.map(fn [_correlation, route_harness, route_host, model] ->
            %{
              "harness" => route_harness,
              "host" => route_host,
              "sharedAccount" => "shared",
              "model" => model
            }
          end)
          |> Enum.uniq()
          |> Enum.sort_by(&{&1["harness"], &1["host"], &1["sharedAccount"], &1["model"] || ""})

        key = {Harness.parse!(harness).id(), "shared", host}

        %{
          "id" => id,
          "harness" => harness,
          "host" => host,
          "failureClass" => failure_class,
          "state" => state,
          "openedAt" => opened_at,
          "resolvedAt" => resolved_at,
          "resolutionCorrelation" => correlation,
          "ownerUserId" => owner,
          "routes" => routes,
          "routesComplete" =>
            route_rows != [] and
              Enum.all?(routes, fn route ->
                is_binary(route["model"]) and route["model"] != ""
              end),
          "fencePresent" => HarnessProcess.parked_in_txn?(txn, key)
        }

      [] ->
        nil
    end
  end

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

  def current(
        txn,
        %{"kind" => "harness_health_hold", "source" => %{"id" => incident_id}},
        _recorded
      ) do
    %{"hold" => harness_health_hold(txn, incident_id)}
  end

  def current(txn, %{"kind" => "harness_health_recovery_check"} = event, _recorded) do
    %{
      "hold" => harness_health_hold(txn, event["holdId"]),
      "recovery_check" =>
        Map.take(event, ~w(holdId cycleId route startedAt finishedAt outcome errorExcerpt))
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

    attests =
      Enum.flat_map(sources, fn source ->
        parents =
          [delivery["sessionKey"], opener_session(source)]
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        receipt_candidates_in_txn(txn, parents, source)
      end)

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

  # A binary prefix range per candidate session uses the receipt index, so
  # unrelated lifetime progress is neither scanned nor materialized for each
  # pending handoff. The reminded session is always a candidate; the child's
  # recorded opener is one too, so its stopping note is found even though the
  # reminder was addressed to someone else (the work item's delivery owner).
  def receipt_candidates_in_txn(txn, parents, source) when is_list(parents) do
    prefix =
      "completion-handoff-action #{source["assignmentId"]} #{source["sourceKind"]} #{source["sourceToken"]} "

    upper = String.trim_trailing(prefix, " ") <> "!"

    Enum.flat_map(parents, fn parent ->
      rows(
        txn,
        "attests INDEXED BY row_reaction_receipt_candidates",
        ~w(id assignmentId kind bySession byUser ts note),
        """
        bySession=?1 AND kind='progress' AND note>=?2 AND note<?3
          AND EXISTS (SELECT 1 FROM assignments a
            WHERE a.id=attests.assignmentId AND a.workItemId IS ?4)
        """,
        [parent, prefix, upper, source["workItemId"]]
      )
    end)
    |> Enum.map(&Map.put(&1, "disposition", disposition(&1["note"])))
  end

  defp opener_session(%{"openedByKind" => "session", "openedById" => id}) when is_binary(id),
    do: id

  defp opener_session(_source), do: nil

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
            "terminalAt" => source.terminal_at,
            "openedByKind" => source.opened_by_kind,
            "openedById" => source.opened_by_id
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
