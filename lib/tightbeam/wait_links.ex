defmodule Tightbeam.WaitLinks do
  @moduledoc "Bounded, direct wait links derived from existing records. Never expands a chain."
  alias Tightbeam.{DB, Escalation, StateResources, StateVisibility, Wakes}
  alias Tightbeam.DB.Txn

  def enabled?, do: Application.get_env(:tightbeam, :wait_links_enabled, false) == true

  @doc "The same recorded target references used by wake reads and events."
  def wake_targets(%{wait_link_excluded: true}), do: []
  # Retry wake IDs name transport attempts, not new wait declarations.
  def wake_targets(%{wake_id: "wr_" <> _}), do: []

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

  @doc false
  def project_wake(_txn, nil, _principal), do: nil

  def project_wake(txn, row, principal) do
    if enabled?(), do: project_wake_enabled(txn, row, principal), else: row
  end

  defp project_wake_enabled(txn, row, principal) do
    Map.put(row, "waitOn", Enum.map(wake_targets(row), &visible_ref(txn, &1, principal)))
  end

  @doc false
  def project_notice(
        db,
        %{"class" => "wake." <> _, "payload" => %{"waitOn" => targets} = payload} = notice,
        principal
      ) do
    DB.read_transaction!(db, fn txn ->
      Map.put(
        notice,
        "payload",
        Map.put(payload, "waitOn", Enum.map(targets, &visible_ref(txn, &1, principal)))
      )
    end)
  end

  def project_notice(_db, notice, _principal), do: notice

  defp visible_ref(_txn, %{"visible" => false} = ref, _principal), do: ref

  defp visible_ref(txn, ref, principal) do
    if target(txn, ref, principal)["visible"], do: ref, else: hidden(ref)
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

  @doc false
  def work_item_reminder_reference?(%{"resource" => "work_item", "field" => field})
      when field in ["routingWakeId", "slateWakeId"], do: true

  def work_item_reminder_reference?(_), do: false

  # The unary plus drops wakeId's text affinity, which the expression index lacks;
  # with it SQLite walks the whole index for every wake.
  defp declared_wait_sql do
    """
    w.wakeId NOT GLOB 'wr_*'
    AND NOT EXISTS(SELECT 1 FROM work_items wi WHERE wi.id=w.work_item_id
      AND (wi.routingWakeId=w.wakeId OR wi.slateWakeId=w.wakeId))
    AND NOT EXISTS(SELECT 1 FROM row_reaction_actions r INDEXED BY row_reaction_output
      WHERE json_extract(r.result,'$.wake_id')=+w.wakeId
      AND json_extract(r.plan,'$.value.reference.resource')='work_item'
      AND json_extract(r.plan,'$.value.reference.field') IN ('routingWakeId','slateWakeId'))
    """
  end

  @doc false
  def excluded_sql(alias_name),
    do: "NOT (" <> String.replace(declared_wait_sql(), "w.", alias_name <> ".") <> ")"

  defp declared_wait?(txn, wake) do
    Txn.q(txn, "SELECT 1 FROM wakes w WHERE w.wakeId=?1 AND " <> declared_wait_sql(), [
      wake.wake_id
    ]) != []
  end

  defp active_wake_sql do
    "w.state='pending' AND (w.recognitionAt IS NULL OR w.waitMode='after-turn') AND (w.firedAt IS NULL OR w.consumer='cron') AND " <>
      declared_wait_sql()
  end

  # A trigger that defers the wake; an undelivered immediate message is not a wait.
  defp waiting_wake_sql,
    do:
      "(w.waitMode IS NOT NULL OR w.conditionKind IS NOT NULL OR w.consumer='cron' OR w.dueAt>w.createdAt)"

  @reserved_facts "('assignment-landed','assignment-reviewed','assignment-blocked')"

  @doc "Small work-item indicators; reads only records explicitly linked to each item."
  def summaries(db, ids) do
    if enabled?(),
      do: Map.new(linked(db, ids), fn {id, row} -> {id, Map.take(row, [:waiting, :running])} end),
      else: Map.new(ids, &{&1, %{}})
  end

  # Every record that makes an item waiting or running, for the items named in ?1
  # (a JSON id array). Each named item or card drives its own indexed seeks:
  # CROSS JOIN fixes that order, because INDEXED BY alone still lets SQLite walk a
  # whole index and there are no statistics to tell it otherwise.
  defp linked_sql do
    """
    WITH items AS MATERIALIZED (SELECT value id FROM json_each(?1)),
    item_assignments AS MATERIALIZED (
      SELECT a.id,a.workItemId FROM items i CROSS JOIN assignments a ON a.workItemId=i.id
    ),
    item_wakes AS MATERIALIZED (
      SELECT i.id itemId,COALESCE(w.conditionKind,json_extract(w.predicate,'$.bindings.conditionKind')) waitFactKind,w.* FROM items i CROSS JOIN wakes w INDEXED BY wakes_wait_links_item ON w.work_item_id=i.id
      WHERE #{active_wake_sql()}
      UNION ALL
      SELECT a.workItemId itemId,COALESCE(w.conditionKind,json_extract(w.predicate,'$.bindings.conditionKind')) waitFactKind,w.* FROM item_assignments a CROSS JOIN wakes w INDEXED BY wakes_assignment ON w.assignmentId=a.id
      WHERE w.work_item_id IS NOT a.workItemId AND #{active_wake_sql()}
    ),
    item_decisions AS MATERIALIZED (
      SELECT a.workItemId itemId,d.* FROM item_assignments a
        CROSS JOIN decision_requests d INDEXED BY decision_requests_rest_assignment_order ON d.assignmentId=a.id WHERE d.status='open'
      UNION
      SELECT w.itemId,d.* FROM item_wakes w CROSS JOIN decision_requests d ON d.id=w.resolverId
        WHERE w.resolverKind='decision_request' AND d.status='open'
      UNION
      SELECT i.id itemId,d.* FROM items i CROSS JOIN decision_requests d INDEXED BY decision_requests_wait_item
        ON (CASE WHEN json_valid(d.context) THEN json_extract(d.context,'$.workItemId') END)=i.id WHERE d.status='open'
    ),
    item_blocks AS MATERIALIZED (
      SELECT a.workItemId itemId,cp.* FROM item_assignments a
        CROSS JOIN assignment_cannot_proceed cp INDEXED BY cannot_proceed_wait_assignment ON cp.assignmentId=a.id
        WHERE cp.state='standing'
    ),
    item_asks AS MATERIALIZED (
      SELECT d.itemId,'decision' type,d.id,d.id decisionId,d.assignmentId,d.raisedAt at,
        COALESCE(d.currentExpecterSessionKey,d.expecterSessionKey) session,COALESCE(d.expecterUserId,d.ownerUserId) user
      FROM item_decisions d WHERE NOT EXISTS(
        SELECT 1 FROM item_blocks cp WHERE cp.decisionRequestId=d.id)
      UNION ALL
      SELECT cp.itemId,'cannot-proceed',cp.id,cp.decisionRequestId,cp.assignmentId,cp.createdAt,
        CASE WHEN cp.disposerRef LIKE 'session:%' THEN substr(cp.disposerRef,9) END,
        CASE WHEN cp.disposerRef LIKE 'user:%' THEN substr(cp.disposerRef,6) END
      FROM item_blocks cp WHERE cp.releaseFactKind IS NULL
    ),
    item_running AS MATERIALIZED (
      SELECT i.id itemId FROM items i CROSS JOIN turns t INDEXED BY turns_wait_item ON t.jobRef=i.id WHERE t.status='running'
      UNION
      SELECT a.workItemId itemId FROM item_assignments a CROSS JOIN turns t INDEXED BY turns_wait_assignment ON t.assignmentId=a.id WHERE t.status='running'
    )
    SELECT w.itemId,'wake' type,w.wakeId id,NULL decisionId,w.assignmentId,w.createdAt at,
      (w.resolverKind='assignment' OR w.waitMode='after-turn' OR w.waitFactKind IN #{@reserved_facts}) IS TRUE agent,
      (w.consumer='cron' OR (w.waitMode IS NULL AND w.conditionKind IS NULL AND w.dueAt>w.createdAt)) IS TRUE time,
      (w.waitFactKind NOT IN #{@reserved_facts}) IS TRUE event,
      NULL user
    FROM item_wakes w WHERE #{waiting_wake_sql()}
    UNION ALL
    SELECT cp.itemId,'cannot-proceed',cp.id,cp.decisionRequestId,cp.assignmentId,cp.createdAt,
      cp.releaseFactKind IN #{@reserved_facts},0,cp.releaseFactKind NOT IN #{@reserved_facts},NULL
    FROM item_blocks cp WHERE cp.releaseFactKind IS NOT NULL
    UNION ALL
    SELECT r.itemId,r.type,r.id,r.decisionId,r.assignmentId,r.at,
      r.session IS NOT NULL,0,0,CASE WHEN r.session IS NULL THEN r.user END
    FROM item_asks r WHERE r.session IS NOT NULL OR r.user IS NOT NULL
    UNION ALL
    SELECT itemId,'running',NULL,NULL,NULL,0,0,0,0,NULL FROM item_running
    ORDER BY at,2,3
    """
  end

  @doc """
  What each named item waits on, oldest first. `waits` and `questions` (open to a
  user) are rows; readers turn the ones they return into links with `wait/3` and
  `question/3`. `waiting` and `running` are the indicators those rows add up to.
  """
  def linked(db, ids) do
    rows =
      case db do
        %Txn{} ->
          Txn.q(db, linked_sql(), [JSON.encode!(ids)])

        _ ->
          {:ok, rows} = DB.query(db, linked_sql(), [JSON.encode!(ids)])
          rows
      end
      |> Enum.map(fn [item, type, id, decision_id, assignment, at, agent, time, event, user] ->
        %{
          item: item,
          type: type,
          id: id,
          decision_id: decision_id,
          assignment_id: assignment,
          at: at,
          agent: agent == 1,
          time: time == 1,
          event: event == 1,
          user: user
        }
      end)
      |> Enum.group_by(& &1.item)

    Map.new(ids, fn id ->
      {running, rows} = rows |> Map.get(id, []) |> Enum.split_with(&(&1.type == "running"))
      {questions, waits} = Enum.split_with(rows, &(&1.user && &1.decision_id))

      {id,
       %{
         waiting: %{
           agent: Enum.any?(rows, & &1.agent),
           time: Enum.any?(rows, & &1.time),
           event: Enum.any?(rows, & &1.event),
           userIds: rows |> Enum.map(& &1.user) |> Enum.filter(& &1) |> Enum.uniq() |> Enum.sort()
         },
         running: running != [],
         waits: waits,
         questions: Enum.uniq_by(questions, & &1.decision_id)
       }}
    end)
  end

  @doc "One small wait from a `linked/2` row, with the same link rules as a wait-links page."
  def wait(%Txn{} = txn, row, principal) do
    link = edge(txn, "work-item", row.item, [row.at, nil, row.type, row.id], principal)
    due = fn role -> Enum.find_value(link.waitOn, &(&1["role"] == role && &1["dueAt"])) end

    %{
      id: link.id,
      wakeId: link.wakeId,
      kind: link.kind,
      by: if(link.id, do: wait_by(row, link.waitOn)),
      assignmentId: if(link.id, do: row.assignment_id),
      waitReason: link.waitReason,
      createdAt: link[:createdAt],
      dueAt: due.("due"),
      fallbackAt: due.("fallback"),
      waitOn: link.waitOn
    }
  end

  @doc "One open question's reference from a `linked/2` row; never its text."
  def question(%Txn{} = txn, row, principal) do
    case target(txn, ref("decision", row.decision_id), principal) do
      %{"visible" => true} = decision ->
        %{
          id: row.decision_id,
          kind: decision["decisionKind"],
          userId: row.user,
          assignmentId: row.assignment_id,
          raisedAt: row.at
        }

      _ ->
        %{id: nil, visible: false}
    end
  end

  defp wait_by(%{agent: true}, _targets), do: "agent"
  defp wait_by(%{time: true}, _targets), do: "time"
  defp wait_by(%{event: true}, _targets), do: "event"
  defp wait_by(%{user: user}, _targets) when is_binary(user), do: "user"

  # A wait on a recorded decision is on whoever that decision is addressed to.
  defp wait_by(_row, targets) do
    case Enum.find(targets, &(&1["kind"] == "decision"))["addressee"]["kind"] do
      "session" -> "agent"
      kind -> kind
    end
  end

  @doc false
  def publish_wake_change_in_txn(txn, wake) do
    if enabled?() and wake_targets(wake) != [] and declared_wait?(txn, wake),
      do: publish_source_change_in_txn(txn, wake.work_item_id, wake.assignment_id),
      else: :ok
  end

  @doc false
  def publish_source_change_in_txn(txn, work_item_id, assignment_id) do
    if enabled?(),
      do: publish_source_change_in_txn_enabled(txn, work_item_id, assignment_id),
      else: :ok
  end

  defp publish_source_change_in_txn_enabled(txn, work_item_id, assignment_id) do
    ids =
      if is_binary(assignment_id) do
        Enum.map(
          Txn.q(txn, "SELECT workItemId FROM assignments WHERE id=?1", [assignment_id]),
          &hd/1
        )
      else
        []
      end

    ids = [work_item_id | ids] |> Enum.filter(&is_binary/1) |> Enum.uniq()

    # A turn's jobRef is an attribution key and may not name a work item.
    Txn.q(txn, "SELECT id FROM work_items WHERE id IN (SELECT value FROM json_each(?1))", [
      JSON.encode!(ids)
    ])
    |> Enum.each(fn [id] ->
      Tightbeam.WorkItemSummary.publish_change_in_txn(txn, id, %{
        principal: {:process, "tightbeam"},
        firehose_work_item_summary: true
      })
    end)

    :ok
  end

  @doc false
  def with_wait_metadata(wake, txn) do
    if enabled?(), do: with_wait_metadata_enabled(wake, txn), else: wake
  end

  defp with_wait_metadata_enabled(wake, txn) do
    wake = with_schedule(wake, txn)

    if Map.has_key?(wake, :wait_link_excluded) or wake_targets(wake) == [] or
         declared_wait?(txn, wake),
       do: wake,
       else: Map.put(wake, :wait_link_excluded, true)
  end

  defp with_schedule(%{consumer: "cron"} = wake, txn) do
    case Txn.q(txn, "SELECT schedule FROM cron_wake_schedules WHERE wakeId=?1", [wake.wake_id]) do
      [[schedule]] -> Map.put(wake, :cron, schedule)
      [] -> wake
    end
  end

  defp with_schedule(wake, _txn), do: wake

  def request(query, kind, id) do
    if enabled?(),
      do: request_enabled(query, kind, id),
      else:
        {:error, 409, "feature_disabled",
         "Wait-link reads are disabled; enable wait_links_enabled to use this endpoint."}
  end

  defp request_enabled(query, kind, id) do
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
    if enabled?(),
      do: page_enabled(db, kind, id, principal, request),
      else: {:error, :feature_disabled}
  end

  defp page_enabled(db, kind, id, principal, request) do
    DB.read_transaction!(db, fn txn ->
      txn = Txn.observe_queries(txn, Map.get(principal, :core_detail_trace))

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
    active_wake = if ended, do: "1=1", else: active_wake_sql()
    active_assignment = if ended, do: "1=1", else: "a.state='open'"
    active_decision = if ended, do: "1=1", else: "d.status='open'"
    active_block = if ended, do: "1=1", else: "cp.state='standing'"

    wake = fn scope, index ->
      index =
        if ended do
          index
        else
          %{
            "wakes_wait_links_item" => "wakes_wait_pending_item",
            "wakes_assignment" => "wakes_wait_pending_assignment",
            "wakes_rest_session_created_order" => "wakes_wait_pending_session"
          }
          |> Map.fetch!(index)
        end

      "SELECT w.createdAt at,'wake:'||printf('%020d',w.rowid) key,'wake' type,w.wakeId id FROM wakes w INDEXED BY #{index} WHERE (#{scope}) AND #{active_wake} AND #{waiting_wake_sql()} AND #{declared_wait_sql()}"
    end

    decision = fn scope ->
      "SELECT d.raisedAt at,'decision:'||printf('%020d',d.rowid) key,'decision' type,d.id FROM decision_requests d WHERE (#{scope}) AND +#{active_decision}"
    end

    case kind do
      "work-item" ->
        {wake.("w.work_item_id=?", "wakes_wait_links_item") <>
           " UNION ALL " <>
           wake.(
             "w.assignmentId IN (SELECT id FROM assignments WHERE workItemId=?) AND w.work_item_id IS NOT ?",
             "wakes_assignment"
           ) <>
           " UNION ALL SELECT a.openedAt,'assignment:'||printf('%020d',a.rowid),'assignment',a.id FROM assignments a WHERE a.workItemId=? AND #{active_assignment}" <>
           " UNION ALL " <>
           decision.(
             "(CASE WHEN json_valid(d.context) THEN json_extract(d.context,'$.workItemId') END)=? AND +d.assignmentId IS NULL"
           ), [id, id, id, id, id]}

      "assignment" ->
        {wake.("w.assignmentId=?", "wakes_assignment") <>
           " UNION ALL " <>
           decision.("d.assignmentId=?") <>
           " UNION ALL SELECT cp.createdAt,'cannot-proceed:'||printf('%020d',cp.rowid),'cannot-proceed',cp.id FROM assignment_cannot_proceed cp INDEXED BY cannot_proceed_wait_assignment WHERE cp.assignmentId=? AND #{active_block}",
         [id, id, id]}

      "session" ->
        {wake.("w.sessionKey=?", "wakes_rest_session_created_order") <>
           " UNION ALL " <> decision.("COALESCE(d.currentRaiserSessionKey,d.raiserSessionKey)=?"),
         [id, id]}

      "decision" ->
        {decision.("d.id=?"), [id]}
    end
  end

  defp edge(txn, kind, source_id, [at, _key, "wake", id], principal) do
    wake = with_wait_metadata(Wakes.get_in_txn(txn, id), txn)
    notice = %{"class" => "wake.scheduled", "payload" => StateResources.wake(wake), "refs" => %{}}

    visible =
      StateVisibility.core_detail_visible?(txn, "wakes", wake, principal) or
        StateVisibility.visible?(txn, notice, principal)

    if visible do
      wake_edge(txn, kind, source_id, at, id, wake, principal)
    else
      %{
        id: nil,
        wakeId: nil,
        kind: "wake",
        visible: false,
        waitReason: nil,
        from: ref(kind, source_id),
        to: hidden(%{"kind" => "wake"}),
        waitOn: [hidden(%{"kind" => "wake"})]
      }
    end
  end

  defp wake_edge(txn, kind, source_id, at, id, wake, principal) do
    targets = Enum.map(wake_targets(wake), &target(txn, &1, principal))

    %{
      id: "wake:" <> id,
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

  defp edge(txn, kind, source_id, [at, _key, "cannot-proceed", id], principal) do
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
      id: "cannot-proceed:" <> id,
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

  defp edge(txn, kind, source_id, [at, _key, type, id], principal) do
    destination = target(txn, ref(type, id), principal)

    {edge_kind, destination} =
      if type == "decision" do
        if kind == "decision" do
          {"addressee",
           destination["addressee"] || %{"kind" => "user", "id" => nil, "visible" => false}}
        else
          {cond do
             destination["visible"] == false -> "question"
             destination["addressee"]["kind"] == "session" -> "agent-question"
             true -> "operator-question"
           end, destination}
        end
      else
        {"assignment", destination}
      end

    %{
      id: if(destination["visible"] == false, do: nil, else: type <> ":" <> id),
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
        # The status list is the pending-turn index's own predicate; without it an
        # idle session's whole turn history is walked.
        running =
          Txn.q(
            txn,
            "SELECT seq,startedAt FROM turns INDEXED BY turns_pending WHERE sessionKey=? AND status IN ('queued','running') AND status='running' ORDER BY seq DESC LIMIT 1",
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

    if row &&
         StateVisibility.visible?(
           txn,
           %{
             "class" => "decision_request.updated",
             "payload" => StateResources.decision_request(row),
             "refs" => %{}
           },
           principal
         ) do
      addressee =
        if row[:current_expecter_session_key] || row[:expecter_session_key],
          do:
            target(
              txn,
              ref("session", row[:current_expecter_session_key] || row.expecter_session_key),
              principal
            ),
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
