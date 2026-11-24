defmodule Tightbeam.WaitLinks do
  @moduledoc "Bounded, direct wait links derived from existing records. Never expands a chain."
  alias Tightbeam.{DB, Escalation, StateResources, StateVisibility, Wakes}
  alias Tightbeam.DB.Txn

  @doc "The same recorded target references used by wake reads and events."
  def wake_targets(wake) do
    bindings = (wake[:predicate] || %{})["bindings"] || %{}

    targets =
      cond do
        wake[:wait_mode] == "after-turn" ->
          [ref("turn", wake[:originating_turn_seq])]

        wake[:wait_mode] == "dependency" ->
          [
            ref("assignment", bindings["assignmentId"]),
            ref("decision", bindings["decisionRequestId"]),
            ref("work-item", bindings["workItemId"]),
            event(bindings["conditionKind"], bindings["conditionScope"])
          ]

        is_binary(wake[:condition_kind]) ->
          [event(wake.condition_kind, wake[:condition_scope])]

        is_binary(wake[:cron]) or wake[:due_at] > wake[:created_at] ->
          [time(wake[:due_at], "due", wake[:cron])]

        true ->
          []
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(fn target ->
        if target["factKind"],
          do:
            Map.put(
              target,
              "afterFact",
              bindings["conditionAfterId"] || wake[:condition_after_id]
            ),
          else: target
      end)

    if targets != [] and not Enum.any?(targets, &(&1["kind"] == "time")) and
         wake[:wait_mode] != "after-turn" and is_integer(wake[:due_at]) and
         wake.due_at != Wakes.no_deadline() do
      targets ++ [time(wake.due_at, "fallback", nil)]
    else
      targets
    end
  end

  defp ref(_kind, nil), do: nil
  defp ref(kind, id), do: %{"kind" => kind, "id" => id}
  defp event(nil, _scope), do: nil

  defp event(kind, scope)
       when kind in ["assignment-landed", "assignment-reviewed", "assignment-blocked"] and
              is_binary(scope),
       do: %{"kind" => "assignment", "id" => scope, "factKind" => kind, "scope" => scope}

  defp event(kind, scope),
    do: %{"kind" => "event", "id" => nil, "factKind" => kind, "scope" => scope}

  defp time(at, role, cron),
    do: %{"kind" => "time", "id" => nil, "dueAt" => at, "role" => role, "cron" => cron}

  @doc "Small work-item indicators; reads only records explicitly linked to each item."
  def summaries(db, ids) do
    sql = """
    SELECT wi.id,
      EXISTS(SELECT 1 FROM wakes w WHERE
        (w.work_item_id=wi.id OR w.assignmentId IN (SELECT id FROM assignments WHERE workItemId=wi.id))
        AND w.state='pending' AND w.recognitionAt IS NULL
        AND (w.resolverKind='assignment' OR w.waitMode='after-turn')),
      EXISTS(SELECT 1 FROM wakes w WHERE
        (w.work_item_id=wi.id OR w.assignmentId IN (SELECT id FROM assignments WHERE workItemId=wi.id))
        AND w.state='pending' AND w.recognitionAt IS NULL AND w.waitMode IS NULL
        AND w.conditionKind IS NULL AND (EXISTS(SELECT 1 FROM cron_wake_schedules c WHERE c.wakeId=w.wakeId) OR w.dueAt>w.createdAt)),
      COALESCE((SELECT json_group_array(json_object('kind',r.kind,'session',r.session,'user',r.user)) FROM (
        SELECT d.kind,d.expecterSessionKey session,COALESCE(d.expecterUserId,d.ownerUserId) user
        FROM decision_requests d WHERE d.status='open'
          AND NOT EXISTS(SELECT 1 FROM assignment_cannot_proceed cp WHERE cp.decisionRequestId=d.id AND cp.state='standing' AND cp.releaseFactKind IS NULL) AND
          (d.assignmentId IN (SELECT id FROM assignments WHERE workItemId=wi.id)
          OR d.id IN (SELECT w.resolverId FROM wakes w WHERE
            (w.work_item_id=wi.id OR w.assignmentId IN (SELECT id FROM assignments WHERE workItemId=wi.id))
            AND w.resolverKind='decision_request' AND w.state='pending' AND w.recognitionAt IS NULL))
        UNION ALL
        SELECT 'cannot-proceed',
          CASE WHEN cp.disposerRef LIKE 'session:%' THEN substr(cp.disposerRef,9) END,
          CASE WHEN cp.disposerRef LIKE 'user:%' THEN substr(cp.disposerRef,6) END
        FROM assignment_cannot_proceed cp WHERE cp.state='standing' AND cp.releaseFactKind IS NULL
          AND cp.assignmentId IN (SELECT id FROM assignments WHERE workItemId=wi.id)
      ) r), '[]'),
      EXISTS(SELECT 1 FROM turns t WHERE t.status='running' AND
        (t.jobRef=wi.id OR t.assignmentId IN (SELECT id FROM assignments WHERE workItemId=wi.id)))
    FROM work_items wi WHERE wi.id IN (SELECT value FROM json_each(?1))
    """

    rows =
      case db do
        %Txn{} ->
          Txn.q(db, sql, [JSON.encode!(ids)])

        _ ->
          {:ok, rows} = DB.query(db, sql, [JSON.encode!(ids)])
          rows
      end

    Map.new(rows, fn [id, agent, time, decisions, running] ->
      decisions = JSON.decode!(decisions)

      users =
        decisions
        |> Enum.reject(&is_binary(&1["session"]))
        |> Enum.map(& &1["user"])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.sort()

      {id,
       %{
         waiting: %{
           agent: agent == 1 or Enum.any?(decisions, &is_binary(&1["session"])),
           time: time == 1,
           userIds: users
         },
         running: running == 1
       }}
    end)
  end

  @doc false
  def publish_wake_change_in_txn(txn, wake) do
    if wake_targets(wake) != [],
      do: publish_source_change_in_txn(txn, wake.work_item_id, wake.assignment_id),
      else: :ok
  end

  @doc false
  def publish_source_change_in_txn(txn, work_item_id, assignment_id) do
    ids =
      if is_binary(assignment_id) do
        Enum.map(
          Txn.q(txn, "SELECT workItemId FROM assignments WHERE id=?1", [assignment_id]),
          &hd/1
        )
      else
        []
      end

    [work_item_id | ids]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.each(
      &Tightbeam.WorkItemSummary.publish_change_in_txn(txn, &1, %{
        principal: {:process, "tightbeam"},
        firehose_work_item_summary: true
      })
    )

    :ok
  end

  @doc false
  def with_schedule(txn, wake) do
    cron =
      case Txn.q(txn, "SELECT schedule FROM cron_wake_schedules WHERE wakeId=?1", [wake.wake_id]) do
        [[schedule]] -> schedule
        [] -> nil
      end

    Map.put(wake, :cron, cron)
  end

  def request(query, kind, id) do
    query =
      Map.new(query, fn
        {key, [value]} -> {key, value}
        {key, value} -> {key, value}
      end)

    with true <- Map.keys(query) -- ~w(asUser limit cursor includeEnded) == [],
         limit_text when is_binary(limit_text) <- query["limit"] || "20",
         {limit, ""} when limit > 0 <- Integer.parse(limit_text),
         true <- query["includeEnded"] in [nil, "true", "false"],
         ended = query["includeEnded"] == "true",
         {:ok, boundary} <- decode_cursor(query["cursor"], kind, id, ended) do
      {:ok, %{limit: min(limit, 50), ended: ended, boundary: boundary}}
    else
      _ ->
        {:error, 400, "invalid_wait_links_query",
         "Use limit, cursor and includeEnded=true or false."}
    end
  end

  def page(db, kind, id, principal, request) do
    DB.read_transaction!(db, fn txn ->
      case target(txn, ref(kind, id), principal) do
        %{"visible" => false} -> {:error, :not_found}
        source -> {:ok, page_in_txn(txn, kind, id, source, principal, request)}
      end
    end)
  end

  defp page_in_txn(txn, kind, id, source, principal, request) do
    {sql, params} = candidates(kind, id, request.ended)
    [at, key] = request.boundary || [-1, ""]

    rows =
      Txn.q(
        txn,
        "SELECT at,key,type,id FROM (#{sql}) WHERE (at,key)>(?,?) ORDER BY at,key LIMIT ?",
        params ++ [at, key, request.limit + 1]
      )

    more = length(rows) > request.limit
    selected = Enum.take(rows, request.limit)
    items = Enum.map(selected, &edge(txn, kind, id, &1, principal))

    next =
      if more, do: cursor(kind, id, request.ended, Enum.take(List.last(selected), 2)), else: nil

    %{
      items: items,
      nextCursor: next,
      truncated: more,
      asOf: System.system_time(:millisecond),
      rowVersion: source["rowVersion"],
      source: source
    }
  end

  defp candidates(kind, id, ended) do
    active_wake = if ended, do: "1=1", else: "w.state='pending' AND w.recognitionAt IS NULL"
    active_assignment = if ended, do: "1=1", else: "a.state='open'"
    active_decision = if ended, do: "1=1", else: "d.status='open'"
    active_block = if ended, do: "1=1", else: "cp.state='standing'"

    waiting =
      "(w.waitMode IS NOT NULL OR w.conditionKind IS NOT NULL OR EXISTS(SELECT 1 FROM cron_wake_schedules c WHERE c.wakeId=w.wakeId) OR w.dueAt>w.createdAt)"

    wake = fn scope ->
      "SELECT w.createdAt at,'wake:'||w.wakeId key,'wake' type,w.wakeId id FROM wakes w WHERE (#{scope}) AND #{active_wake} AND #{waiting}"
    end

    decision = fn scope ->
      "SELECT d.raisedAt at,'decision:'||d.id key,'decision' type,d.id FROM decision_requests d WHERE (#{scope}) AND #{active_decision}"
    end

    case kind do
      "work-item" ->
        {wake.(
           "w.work_item_id=? OR w.assignmentId IN (SELECT id FROM assignments WHERE workItemId=?)"
         ) <>
           " UNION ALL SELECT a.openedAt,'assignment:'||a.id,'assignment',a.id FROM assignments a WHERE a.workItemId=? AND #{active_assignment}",
         [id, id, id]}

      "assignment" ->
        {wake.("w.assignmentId=?") <>
           " UNION ALL " <>
           decision.("d.assignmentId=?") <>
           " UNION ALL SELECT cp.createdAt,'cannot-proceed:'||cp.id,'cannot-proceed',cp.id FROM assignment_cannot_proceed cp WHERE cp.assignmentId=? AND #{active_block}",
         [id, id, id]}

      "session" ->
        {wake.("w.sessionKey=?") <> " UNION ALL " <> decision.("d.raiserSessionKey=?"), [id, id]}

      "decision" ->
        {decision.("d.id=?"), [id]}
    end
  end

  defp edge(txn, kind, source_id, [at, key, "wake", id], principal) do
    wake = with_schedule(txn, Wakes.get_in_txn(txn, id))
    targets = Enum.map(wake_targets(wake), &target(txn, &1, principal))

    %{
      id: key,
      wakeId: id,
      kind: wake_kind(wake),
      waitReason: wake.wait_reason,
      createdAt: at,
      state: wake.state,
      from: ref(kind, source_id),
      to: List.first(targets),
      waitOn: targets,
      rowVersion: max(wake.created_at, wake.recognition_at || 0),
      recognition: %{
        path: wake.recognition_path,
        at: wake.recognition_at,
        disposition: wake.recognition_disposition
      }
    }
  end

  defp edge(txn, kind, source_id, [at, key, "cannot-proceed", id], principal) do
    [[state, fact_kind, scope, opener, decision_id]] =
      Txn.q(
        txn,
        "SELECT state,releaseFactKind,releaseFactScope,disposerRef,decisionRequestId FROM assignment_cannot_proceed WHERE id=?",
        [id]
      )

    destination =
      if is_binary(fact_kind) do
        target(txn, event(fact_kind, scope), principal)
      else
        case String.split(opener, ":", parts: 2) do
          [kind, recipient] when kind in ["session", "user"] ->
            target(txn, ref(kind, recipient), principal)

          _ ->
            target(txn, ref("decision", decision_id), principal)
        end
      end

    %{
      id: key,
      wakeId: nil,
      kind: "cannot-proceed",
      waitReason: nil,
      createdAt: at,
      state: state,
      from: ref(kind, source_id),
      to: destination,
      waitOn: [destination],
      recognition: nil
    }
  end

  defp edge(txn, kind, source_id, [at, key, type, id], principal) do
    destination = target(txn, ref(type, id), principal)

    {edge_kind, destination} =
      if type == "decision" do
        if kind == "decision" do
          {"addressee",
           destination["addressee"] || %{"kind" => "user", "id" => nil, "visible" => false}}
        else
          {if(destination["decisionKind"] == "agent",
             do: "agent-question",
             else: "operator-question"
           ), destination}
        end
      else
        {"assignment", destination}
      end

    %{
      id: key,
      wakeId: nil,
      kind: edge_kind,
      waitReason: nil,
      createdAt: at,
      state: destination["state"],
      from: ref(kind, source_id),
      to: destination,
      waitOn: [destination],
      recognition: nil
    }
  end

  @doc false
  def wake_kind(%{wait_mode: "after-turn"}), do: "after-turn"
  def wake_kind(%{wait_mode: "dependency"}), do: "dependency"
  def wake_kind(%{condition_kind: kind}) when is_binary(kind), do: "fact"
  def wake_kind(%{cron: cron}) when is_binary(cron), do: "recurring"
  def wake_kind(_), do: "timed"

  defp target(_txn, %{"kind" => kind} = ref, _principal) when kind in ["time", "event", "user"],
    do: Map.put(ref, "visible", true)

  defp target(txn, %{"kind" => "assignment", "id" => id} = ref, principal) do
    case StateResources.query_assignment(txn, id, %{rest_principal: principal}) do
      nil ->
        hidden(ref)

      row ->
        Map.merge(ref, %{
          "visible" => true,
          "state" => row.state,
          "holder" => target(txn, ref("session", row.holder_key), principal),
          "workItemId" => row.work_item_id,
          "rowVersion" => version(row)
        })
    end
  end

  defp target(txn, %{"kind" => "work-item", "id" => id} = ref, principal) do
    case StateResources.query_work_item(txn, id, %{
           rest_principal: principal,
           include_work_item_summary: false
         }) do
      nil ->
        hidden(ref)

      row ->
        Map.merge(ref, %{"visible" => true, "state" => row.state, "rowVersion" => version(row)})
    end
  end

  defp target(txn, %{"kind" => "session", "id" => id} = ref, principal) do
    case StateResources.query_session(txn, %{key: id, principal: principal}) do
      nil ->
        hidden(ref)

      row ->
        running =
          Txn.q(
            txn,
            "SELECT seq,startedAt FROM turns WHERE sessionKey=? AND status='running' ORDER BY seq DESC LIMIT 1",
            [id]
          )

        Map.merge(ref, %{
          "visible" => true,
          "state" => row.state,
          "rowVersion" => version(row),
          "running" => running != [],
          "runningSince" =>
            case running do
              [[_, at]] -> at
              [] -> nil
            end
        })
    end
  end

  defp target(txn, %{"kind" => "decision", "id" => id} = ref, principal) do
    row = Escalation.raw_by_id_in_txn(txn, id)

    if row && StateVisibility.core_detail_visible?(txn, "decision requests", row, principal) do
      addressee =
        if row[:expecter_session_key],
          do: target(txn, ref("session", row.expecter_session_key), principal),
          else: target(txn, ref("user", row[:expecter_user_id] || row.owner_user_id), principal)

      Map.merge(ref, %{
        "visible" => true,
        "state" => row.status,
        "decisionKind" => row.kind,
        "addressee" => addressee,
        "rowVersion" => version(row)
      })
    else
      hidden(ref)
    end
  end

  defp target(txn, %{"kind" => "turn", "id" => id} = ref, principal) do
    row = if is_integer(id), do: StateResources.query_turn_in_txn(txn, id)

    if row && StateVisibility.core_detail_visible?(txn, "turns", row, principal),
      do:
        Map.merge(ref, %{
          "visible" => true,
          "state" => row.status,
          "session" => target(txn, ref("session", row.session_key), principal)
        }),
      else: hidden(ref)
  end

  defp version(row) do
    [:row_version, :updated_at, :closed_at, :opened_at, :created_at, :raised_at]
    |> Enum.map(&row[&1])
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 1 end)
  end

  defp hidden(ref), do: %{"kind" => ref["kind"], "id" => nil, "visible" => false}

  defp cursor(kind, id, ended, boundary),
    do: JSON.encode!([kind, id, ended, boundary]) |> Base.url_encode64(padding: false)

  defp decode_cursor(nil, _kind, _id, _ended), do: {:ok, nil}

  defp decode_cursor(value, kind, id, ended) when is_binary(value) do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, [^kind, ^id, ^ended, [at, key]]} <- JSON.decode(json),
         true <- is_integer(at) and is_binary(key),
         do: {:ok, [at, key]},
         else: (_ -> :error)
  end

  defp decode_cursor(_value, _kind, _id, _ended), do: :error
end
