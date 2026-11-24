defmodule Tightbeam.CoordinatorHoldDecisions do
  @moduledoc false
  use GenServer

  alias Tightbeam.{
    Archetypes,
    DB,
    ErrorDiagnostic,
    Escalation,
    Id,
    Org,
    Placement,
    RateLimitReset,
    Wakes
  }

  alias Tightbeam.DB.Txn
  alias Tightbeam.HarnessHealth.{RecoverySchedule, RecoveryScheduler}

  @interval :timer.minutes(5)
  @wait "Wait"
  @retry "Capacity is restored, retry now"
  @retry_command "tightbeam harness-health-retry <incidentId>"
  @title_id ~r/\b(?:(?:wi|asg|s|att|art|dr)_[a-z0-9_-]+|[a-f0-9]{16,}|[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}|agent:main:clawline:[^\r\n]+?:main)\b/i
  @title_secret ~r/\b(?:[\w-]*(?:key|token|secret|password)["']?\s*[:=]\s*\S+|[a-z0-9_+\/-]{32,}|(?=[a-z0-9_+\/-]*\d)[a-z0-9_+\/-]{24,})/i

  @ddl """
  CREATE TABLE IF NOT EXISTS coordinator_outage_decisions (
    id TEXT PRIMARY KEY,
    ownerUserId TEXT NOT NULL,
    openedAt INTEGER NOT NULL,
    closedAt INTEGER,
    requestId TEXT UNIQUE REFERENCES decision_requests(id),
    filedAt INTEGER,
    CHECK((requestId IS NULL) = (filedAt IS NULL))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS coordinator_outage_decision_open
    ON coordinator_outage_decisions(ownerUserId) WHERE closedAt IS NULL;

  CREATE TABLE IF NOT EXISTS coordinator_outage_retries (
    requestId TEXT NOT NULL REFERENCES decision_requests(id),
    holdId TEXT NOT NULL,
    cycleId TEXT NOT NULL,
    PRIMARY KEY(requestId,holdId)
  );
  """

  def ensure_schema(db), do: DB.execute(db, @ddl)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def changed_in_txn(txn), do: Txn.handoff(txn, __MODULE__, :reconcile)
  def changed, do: GenServer.cast(__MODULE__, :reconcile)

  @impl true
  def init(opts) do
    state = %{db: Keyword.fetch!(opts, :db), clock: Keyword.get(opts, :clock, &now/0), timer: nil}
    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state), do: {:noreply, reconcile_and_schedule(state)}

  @impl true
  def handle_cast(:reconcile, state), do: {:noreply, reconcile_and_schedule(state)}

  @impl true
  def handle_info({:timeout, ref, :reconcile}, %{timer: ref} = state),
    do: {:noreply, reconcile_and_schedule(%{state | timer: nil})}

  def handle_info({:timeout, _ref, :reconcile}, state), do: {:noreply, state}

  defp reconcile_and_schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    timer =
      case DB.owed_work(fn -> reconcile(state.db, state.clock) end) do
        nil -> nil
        due_at -> :erlang.start_timer(max(0, due_at - state.clock.()), self(), :reconcile)
      end

    %{state | timer: timer}
  end

  @doc false
  def reconcile(db, clock) do
    case DB.transaction_then(
           db,
           fn txn ->
             Txn.q(txn, "SELECT userId FROM users WHERE isAdmin=1 ORDER BY createdAt,userId")
             |> Enum.map(fn [owner] -> reconcile_owner(txn, owner, clock) end)
             |> Enum.reject(&is_nil/1)
             |> Enum.min(fn -> nil end)
           end,
           fn txn, due_at ->
             # Filing is committed before any elected rule evaluates its consequence.
             Wakes.row_commit_in_txn(txn, [])
             due_at
           end
         ) do
      {:ok, due_at} -> due_at
      {:error, error} -> raise error
    end
  end

  defp reconcile_owner(txn, owner, clock) do
    episode =
      case Txn.q(
             txn,
             "SELECT id,requestId FROM coordinator_outage_decisions WHERE ownerUserId=?1 AND closedAt IS NULL",
             [owner]
           ) do
        [[id, request_id]] -> {id, request_id}
        [] -> nil
      end

    sessions = active_sessions(txn, owner)
    coordinators = Enum.filter(sessions, & &1.coordinator)

    case coordinators do
      [] ->
        nil

      coordinators ->
        at = clock.()

        if Enum.all?(coordinators, &held?/1) do
          reserve_and_file(txn, owner, episode, sessions, coordinators, at)
        else
          if episode do
            {id, request_id} = episode
            Escalation.withdraw_coordinator_hold_in_txn(txn, request_id)

            Txn.q(txn, "UPDATE coordinator_outage_decisions SET closedAt=?2 WHERE id=?1", [id, at])
          end

          nil
        end
    end
  end

  defp reserve_and_file(txn, owner, nil, sessions, coordinators, at) do
    episode = Id.ulid()

    Txn.q(
      txn,
      "INSERT INTO coordinator_outage_decisions(id,ownerUserId,openedAt) VALUES(?1,?2,?3)",
      [
        episode,
        owner,
        at
      ]
    )

    reserve_and_file(txn, owner, {episode, nil}, sessions, coordinators, at)
  end

  defp reserve_and_file(txn, owner, {episode, nil}, sessions, coordinators, at) do
    [[due_at]] =
      Txn.q(txn, "SELECT MAX(filedAt)+?1 FROM coordinator_outage_decisions", [@interval])

    if due_at && due_at > at do
      due_at
    else
      held = Enum.filter(sessions, &held?/1)
      retryable = retryable_incidents(txn, held)
      choices = if retryable == [], do: [@wait], else: [@wait, @retry]
      question = question(txn, owner, coordinators, held, retryable)

      request =
        Escalation.file_coordinator_hold_in_txn(txn, owner, episode, question, choices, at)

      Txn.q(txn, "UPDATE coordinator_outage_decisions SET requestId=?2,filedAt=?3 WHERE id=?1", [
        episode,
        request.id,
        at
      ])

      nil
    end
  end

  defp reserve_and_file(_txn, _owner, {_episode, _request}, _sessions, _coordinators, _at),
    do: nil

  @doc false
  def ruling_in_txn(txn, request, @retry, at) do
    sessions = active_sessions(txn, request.owner_user_id)
    coordinators = Enum.filter(sessions, & &1.coordinator)

    results =
      if coordinators != [] and Enum.all?(coordinators, &held?/1) do
        for incident <- retryable_incidents(txn, Enum.filter(sessions, &held?/1)) do
          case RecoverySchedule.retry_now_in_txn(txn, incident, at, :coordinator) do
            {status, cycle} when status in [:ok, :already_running] ->
              Txn.q(
                txn,
                "INSERT INTO coordinator_outage_retries(requestId,holdId,cycleId) VALUES(?1,?2,?3)",
                [request.id, incident, cycle]
              )

              if status == :ok, do: Txn.handoff(txn, RecoveryScheduler, :refresh)

              "Tightbeam will show the provider check here. To try again later, run #{@retry_command}."

            {:error, reason} ->
              reason
          end
        end
      else
        []
      end

    summary =
      case Enum.uniq(results) do
        [] -> "No supported usage-limit hold remains available to retry."
        messages -> Enum.join(messages, " ")
      end

    Txn.q(
      txn,
      "UPDATE decision_requests SET context=json_set(context,'$.retryStatus',?2) WHERE id=?1",
      [
        request.id,
        summary
      ]
    )
  end

  def ruling_in_txn(_txn, _request, @wait, _at), do: :ok

  @doc false
  def retry_results_in_txn(txn, id) do
    Txn.q(
      txn,
      """
      SELECT c.harness,CASE WHEN c.host=?2 THEN c.host ELSE h.name END,c.outcome,c.errorExcerpt
        FROM coordinator_outage_retries r
        JOIN harness_health_recovery_checks c ON c.holdId=r.holdId AND c.cycleId=r.cycleId
        LEFT JOIN hosts h ON h.name=c.host
        WHERE r.requestId=?1
        ORDER BY c.harness,h.name,c.routeKey,c.holdId
      """,
      [id, Placement.local_host_name()]
    )
    |> Enum.map(fn [harness, host, outcome, excerpt] ->
      %{"harness" => harness, "host" => host, "outcome" => outcome, "providerResponse" => excerpt}
    end)
  end

  defp retryable_incidents(txn, sessions) do
    sessions
    |> Enum.map(& &1.incident_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(&RecoverySchedule.retryable_hold_in_txn?(txn, &1))
  end

  defp held?(session), do: session.sources != []

  defp active_sessions(txn, owner) do
    catalog = Archetypes.all()

    Txn.q(
      txn,
      """
      SELECT s.sessionKey,s.archetype,s.harness,s.host,CASE WHEN s.host=?2 THEN s.host ELSE h.name END,
             p.requestedAt,p.generation,
             (SELECT i.id FROM harness_health_incidents i
               WHERE p.adapterKey IS NOT NULL AND i.harness=s.harness AND i.host=s.host
                 AND i.state='open'
               ORDER BY (i.failureClass='rate-limit-dead') DESC,i.openedAt DESC,i.id DESC LIMIT 1),
             m.id,m.observedAt,m.cause
        FROM sessions s
        LEFT JOIN hosts h ON h.name=s.host
        LEFT JOIN harness_park_fences p ON p.adapterKey=s.harness || ':shared@' || s.host
        LEFT JOIN harness_model_rate_limits m ON m.id=(
          SELECT held.id FROM harness_model_rate_limits held
          WHERE held.harness=s.harness AND held.host=s.host AND held.model=s.model
            AND held.releasedAt IS NULL
          ORDER BY held.observedAt DESC,held.id DESC LIMIT 1
        )
        WHERE s.ownerUserId=?1 AND s.state='active'
      ORDER BY (s.kind='main') DESC,s.sessionKey
      """,
      [owner, Placement.local_host_name()]
    )
    |> Enum.map(fn [
                     key,
                     archetype,
                     harness,
                     host,
                     host_name,
                     parked_at,
                     park_generation,
                     incident_id,
                     model_hold,
                     observed_at,
                     cause
                   ] ->
      sources =
        Enum.reject(
          [
            incident_id,
            parked_at && (park_generation || [harness, host, parked_at]),
            model_hold
          ],
          &is_nil/1
        )

      %{
        key: key,
        harness: harness,
        host_name: host_name,
        model_hold: model_hold,
        sources: sources,
        incident_id: incident_id,
        model_reset: model_reset(cause, observed_at),
        coordinator: coordinator_label(owner, key, Map.get(catalog, archetype))
      }
    end)
  end

  defp coordinator_label(owner, key, archetype) do
    if key == Org.personal_session_key(owner) do
      "Main"
    else
      case archetype do
        %{manifest_name: "exec"} -> "Exec"
        %{manifest_name: "deliverator"} -> "Deliverator"
        _ -> nil
      end
    end
  end

  defp model_reset(cause, observed_at) when is_binary(cause) do
    evidence = cause |> String.split(" reason=", parts: 2) |> List.last()

    case JSON.decode(evidence) do
      {:ok, evidence} -> RateLimitReset.from_error(evidence, observed_at)
      _ -> nil
    end
  end

  defp model_reset(_cause, _at), do: nil

  defp question(txn, owner, coordinators, held, retryable) do
    roles = coordinators |> Enum.map(& &1.coordinator) |> Enum.uniq() |> Enum.join(", ")

    routes =
      held
      |> Enum.group_by(&{&1.harness, &1.host_name})
      |> Enum.sort()
      |> Enum.map(fn {{harness, host}, sessions} ->
        label = if host, do: "#{harness} on #{host}", else: harness

        resets =
          sessions
          |> Enum.flat_map(&[park_reset(txn, &1.incident_id), &1.model_reset])
          |> Enum.filter(&is_integer/1)
          |> Enum.uniq()
          |> Enum.sort()

        reset =
          case resets do
            [] -> "The reset time is unknown."
            times -> "Known provider resets: #{Enum.map_join(times, ", ", &time/1)}."
          end

        coverage =
          cond do
            Enum.all?(sessions, &(&1.incident_id in retryable and is_nil(&1.model_hold))) ->
              " Retry now can check these holds."

            Enum.any?(sessions, &(&1.incident_id in retryable)) ->
              " Retry now can check the harness usage limit here. Any separate model limits still need to reset."

            true ->
              " These holds cannot be retried here."
          end

        "#{label} has #{length(sessions)} held. #{reset}#{coverage}"
      end)

    choices =
      [
        "Wait. Tightbeam will resume held work automatically as capacity returns. An unanswered request has no deadline and stays open until a coordinator can act. You can retry a supported usage-limit incident later with #{@retry_command}."
      ] ++
        if retryable != [] do
          [
            "Capacity is restored, retry now. Tightbeam will check the supported usage-limit routes and release each hold if its checks pass. Failed checks will appear on this request."
          ]
        else
          []
        end

    unsupported =
      if Enum.any?(held, &(&1.model_hold || &1.incident_id not in retryable)) do
        [
          "For holds that cannot be retried here, wait for the limit to reset or move the affected sessions to available capacity."
        ]
      else
        []
      end

    summary =
      case length(coordinators) do
        1 ->
          "Tightbeam cannot coordinate work because its only active coordinator is held (#{roles})."

        count ->
          "Tightbeam cannot coordinate work because all #{count} active coordinators are held (#{roles})."
      end

    ([summary] ++
       routes ++
       urgent_work(txn, owner, held) ++
       choices ++
       unsupported ++
       ["What would you like Tightbeam to do?"])
    |> Enum.join("\n")
  end

  defp park_reset(_txn, nil), do: nil

  defp park_reset(txn, incident) do
    [[reset]] =
      Txn.q(
        txn,
        """
        SELECT MAX(w.dueAt) FROM wakes w
        JOIN harness_health_observations o ON o.id=w.prompt
        WHERE w.consumer='rate_limit_reset' AND w.state='pending' AND o.incidentId=?1
        """,
        [incident]
      )

    reset
  end

  defp urgent_work(txn, owner, held) do
    keys = JSON.encode!(Enum.map(held, & &1.key))

    work =
      Txn.q(
        txn,
        """
        WITH held_sessions AS (SELECT value AS sessionKey FROM json_each(?1)),
        sources AS (
          SELECT w.wakeId,w.assignmentId,w.work_item_id,w.dueAt,w.createdAt,w.ownerUserId,NULL AS requestRef
          FROM wakes w JOIN held_sessions h ON h.sessionKey=w.sessionKey
          WHERE w.state='pending' AND w.consumer='prompt'
          UNION
          SELECT w.wakeId,COALESCE(w.assignmentId,t.assignmentId),w.work_item_id,w.dueAt,w.createdAt,w.ownerUserId,t.requestRef
          FROM held_sessions h JOIN turns t ON t.sessionKey=h.sessionKey AND t.status='queued'
          JOIN wakes w ON w.deliveredTurnSeq=t.seq OR w.wakeId=t.wakeId
        )
        SELECT item.title, MIN(COALESCE(d.deadlineAt,CASE WHEN s.dueAt>s.createdAt THEN s.dueAt END))
        FROM sources s
        LEFT JOIN assignments a ON a.id=s.assignmentId AND EXISTS (
          SELECT 1 FROM sessions holder WHERE holder.sessionKey=a.holderKey AND holder.ownerUserId=?2
        )
        LEFT JOIN work_items item ON item.id=COALESCE(s.work_item_id,a.workItemId)
          AND item.ownerUserId=?2
        LEFT JOIN decision_requests d ON d.status='open' AND d.ownerUserId=?2
          AND (d.id=s.requestRef OR d.deadlineWakeId=s.wakeId)
        WHERE (s.ownerUserId IS NULL OR s.ownerUserId=?2)
          AND (s.assignmentId IS NULL OR a.id IS NOT NULL)
          AND (COALESCE(s.work_item_id,a.workItemId) IS NULL OR item.id IS NOT NULL)
          AND (s.requestRef IS NULL OR d.id IS NOT NULL)
          AND (d.deadlineAt IS NOT NULL OR s.dueAt>s.createdAt)
        GROUP BY item.id IS NULL,COALESCE(item.id,s.wakeId),item.title
        ORDER BY 2,1
        """,
        [keys, owner]
      )

    {labelled, hidden} =
      work
      |> Enum.map(fn [title, at] -> {safe_title(title), at} end)
      |> Enum.split_with(fn {title, _at} -> is_binary(title) end)

    {shown, remaining} = Enum.split(labelled, 3)
    lines = Enum.map(shown, fn {title, at} -> "#{title} due #{time(at)}." end)

    case hidden ++ remaining do
      [] ->
        lines

      work ->
        earliest = work |> Enum.map(&elem(&1, 1)) |> Enum.min()
        lines ++ ["#{length(work)} held items with deadlines. Earliest due #{time(earliest)}."]
    end
  end

  defp safe_title(title) when is_binary(title) do
    if ErrorDiagnostic.redact_text(title) == title and not Regex.match?(@title_id, title) and
         not Regex.match?(@title_secret, title) do
      case String.split(title) do
        [] -> nil
        words -> words |> Enum.join(" ") |> String.slice(0, 120)
      end
    end
  end

  defp safe_title(_title), do: nil

  defp time(at) do
    case DateTime.from_unix(at, :millisecond) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%b %d %H:%M UTC")
      _ -> "at an unknown time"
    end
  end

  defp now, do: System.system_time(:millisecond)
end
