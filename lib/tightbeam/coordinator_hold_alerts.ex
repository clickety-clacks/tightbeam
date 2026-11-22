defmodule Tightbeam.CoordinatorHoldAlerts do
  @moduledoc false
  use GenServer
  require Logger

  alias Tightbeam.{Archetypes, DB, ErrorDiagnostic, HarklightSend, Id, Org, RateLimitReset}
  alias Tightbeam.DB.Txn

  @alert_interval_ms :timer.minutes(5)
  @title_id ~r/\b(?:(?:wi|asg|s|att|art|dr)_[a-z0-9_-]+|[a-f0-9]{16,}|[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}|agent:main:clawline:\S+:main)\b/i
  @title_secret ~r/\b(?:[\w-]*(?:key|token|secret|password)["']?\s*[:=]\s*\S+|[a-z0-9_+\/-]{32,}|(?=[a-z0-9_+\/-]*\d)[a-z0-9_+\/-]{24,})/i

  @ddl """
  CREATE TABLE IF NOT EXISTS coordinator_hold_episodes (
    id TEXT PRIMARY KEY,
    ownerUserId TEXT NOT NULL,
    openedAt INTEGER NOT NULL,
    closedAt INTEGER,
    holdSources TEXT NOT NULL
  );
  CREATE UNIQUE INDEX IF NOT EXISTS coordinator_hold_episode_open
    ON coordinator_hold_episodes(ownerUserId) WHERE closedAt IS NULL;

  CREATE TABLE IF NOT EXISTS coordinator_hold_sends (
    episodeId TEXT NOT NULL REFERENCES coordinator_hold_episodes(id),
    phase TEXT NOT NULL CHECK(phase IN ('outage','recovery')),
    operationId TEXT NOT NULL UNIQUE,
    body TEXT NOT NULL,
    attemptedAt INTEGER,
    outcome TEXT CHECK(outcome IN ('committed','failed','outcome_unknown')),
    CHECK((attemptedAt IS NULL) = (outcome IS NULL)),
    PRIMARY KEY(episodeId,phase)
  );
  """

  def ensure_schema(db), do: DB.execute(db, @ddl)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def changed_in_txn(txn), do: Txn.handoff(txn, __MODULE__, :reconcile)
  def changed, do: GenServer.cast(__MODULE__, :reconcile)

  @impl true
  def init(opts) do
    state = %{
      db: Keyword.fetch!(opts, :db),
      runner: opts[:runner],
      clock: Keyword.get(opts, :clock, &now/0),
      timer: nil
    }

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
      case DB.owed_work(fn -> reconcile(state.db, state.clock, state.runner) end) do
        nil -> nil
        due_at -> :erlang.start_timer(max(0, due_at - state.clock.()), self(), :reconcile)
      end

    %{state | timer: timer}
  end

  @doc false
  def reconcile(db, clock, runner) do
    {:ok, {due_at, pending}} =
      DB.transaction(db, fn txn ->
        case operator_owner(txn) do
          owner when is_binary(owner) ->
            {due_at, allow_outage} =
              reconcile_owner(txn, owner, active_sessions(txn, owner), clock.())

            {due_at, pending_sends(txn, owner, allow_outage)}

          nil ->
            {nil, []}
        end
      end)

    Enum.reduce(pending, due_at, fn [operation], next_due ->
      case claim_and_deliver(db, operation, clock, runner) do
        {:defer, at} -> if next_due, do: min(next_due, at), else: at
        :ok -> next_due
      end
    end)
  end

  # Harklight's configured destination belongs to the gateway operator.
  # Match the gateway's first-admin convention for owner notices.
  defp operator_owner(txn) do
    case Txn.q(txn, "SELECT userId FROM users WHERE isAdmin=1 ORDER BY createdAt,userId LIMIT 1") do
      [[owner]] -> owner
      [] -> nil
    end
  end

  defp active_sessions(txn, owner) do
    catalog = Archetypes.all()

    Txn.q(
      txn,
      """
      SELECT s.sessionKey,s.archetype,s.harness,s.host,
             p.requestedAt,p.generation,
             (SELECT i.id FROM harness_health_incidents i
               WHERE p.adapterKey IS NOT NULL AND i.harness=s.harness AND i.host=s.host
                 AND i.state='open'
               ORDER BY (i.failureClass='rate-limit-dead') DESC,i.openedAt DESC,i.id DESC LIMIT 1),
             m.id,m.observedAt,m.cause
        FROM sessions s
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
      [owner]
    )
    |> Enum.map(fn [
                     key,
                     archetype,
                     harness,
                     host,
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
        host: host,
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

  defp reconcile_owner(txn, owner, sessions, at) do
    case coordinator_state(sessions) do
      :empty ->
        {nil, false}

      {:held, coordinators} ->
        {outage(txn, owner, open_episode(txn, owner), coordinators, at), true}

      {:ready, ready} ->
        if episode = open_episode(txn, owner), do: recover(txn, episode, ready, sessions, at)
        {nil, false}
    end
  end

  defp coordinator_state(sessions) do
    case Enum.filter(sessions, & &1.coordinator) do
      [] ->
        :empty

      coordinators ->
        case Enum.find(coordinators, &(&1.sources == [])) do
          nil -> {:held, coordinators}
          ready -> {:ready, ready}
        end
    end
  end

  defp open_episode(txn, owner) do
    case Txn.q(
           txn,
           "SELECT id FROM coordinator_hold_episodes WHERE ownerUserId=?1 AND closedAt IS NULL",
           [
             owner
           ]
         ) do
      [[id]] -> id
      [] -> nil
    end
  end

  defp outage(txn, owner, episode, coordinators, at) do
    episode =
      episode ||
        open_episode_in_txn(txn, owner, Enum.flat_map(coordinators, & &1.sources), at)

    [[already_reserved]] =
      Txn.q(
        txn,
        "SELECT EXISTS(SELECT 1 FROM coordinator_hold_sends WHERE episodeId=?1 AND phase='outage')",
        [episode]
      )

    if already_reserved == 0 do
      case outage_due(txn, owner, at) do
        nil ->
          reserve(txn, episode, "outage", "")
          nil

        due_at ->
          due_at
      end
    end
  end

  defp outage_due(txn, owner, at) do
    [[due_at]] =
      Txn.q(
        txn,
        """
        SELECT MAX(s.attemptedAt)+?2
        FROM coordinator_hold_sends s JOIN coordinator_hold_episodes e ON e.id=s.episodeId
        WHERE e.ownerUserId=?1 AND s.phase='outage'
        """,
        [owner, @alert_interval_ms]
      )

    if is_integer(due_at) and at < due_at, do: due_at
  end

  defp open_episode_in_txn(txn, owner, sources, at) do
    id = Id.uuid4()

    Txn.q(
      txn,
      """
      INSERT INTO coordinator_hold_episodes(id,ownerUserId,openedAt,holdSources)
      VALUES (?1,?2,?3,?4)
      """,
      [id, owner, at, JSON.encode!(Enum.uniq(sources))]
    )

    id
  end

  defp recover(txn, episode, ready, sessions, at) do
    Txn.q(txn, "UPDATE coordinator_hold_episodes SET closedAt=?2 WHERE id=?1", [episode, at])

    case Txn.q(
           txn,
           "SELECT outcome FROM coordinator_hold_sends WHERE episodeId=?1 AND phase='outage'",
           [
             episode
           ]
         ) do
      [[outcome]] when outcome in ["committed", "outcome_unknown"] ->
        count = Enum.count(sessions, &(&1.sources != []))

        line = "#{ready.coordinator} can take turns again on #{ready.harness} at #{ready.host}."

        remaining =
          case count do
            0 -> nil
            1 -> "One other session is still held."
            count -> "#{count} other sessions are still held."
          end

        body = Enum.join(Enum.reject([line, remaining], &is_nil/1), "\n")
        reserve(txn, episode, "recovery", body)

      _ ->
        :ok
    end
  end

  defp reserve(txn, episode, phase, body) do
    Txn.q(
      txn,
      """
      INSERT INTO coordinator_hold_sends(episodeId,phase,operationId,body)
      VALUES (?1,?2,?3,?4)
      """,
      [episode, phase, Id.uuid4(), body]
    )
  end

  defp pending_sends(txn, owner, allow_outage) do
    Txn.q(
      txn,
      """
      SELECT s.operationId FROM coordinator_hold_sends s
      JOIN coordinator_hold_episodes e ON e.id=s.episodeId
      WHERE e.ownerUserId=?1 AND s.attemptedAt IS NULL
        AND (s.phase='recovery' OR (?2=1 AND e.closedAt IS NULL))
      ORDER BY e.openedAt,s.phase
      """,
      [owner, if(allow_outage, do: 1, else: 0)]
    )
  end

  defp claim_and_deliver(db, operation, clock, runner) do
    {:ok, claim} = DB.transaction(db, &claim_in_txn(&1, operation, clock))

    case claim do
      {:send, episode, phase, body} ->
        deliver(db, episode, phase, operation, body, runner)
        :ok

      result ->
        result
    end
  end

  defp claim_in_txn(txn, operation, clock) do
    owner = operator_owner(txn)

    case Txn.q(
           txn,
           """
           SELECT e.id,e.closedAt,s.phase,s.body FROM coordinator_hold_sends s
           JOIN coordinator_hold_episodes e ON e.id=s.episodeId
           WHERE s.operationId=?1 AND s.attemptedAt IS NULL AND e.ownerUserId=?2
           """,
           [operation, owner]
         ) do
      [[episode, nil, "outage", _body]] ->
        claim_outage(txn, owner, episode, operation, clock)

      [[episode, _closed_at, "recovery", body]] ->
        mark_attempt(txn, operation, episode, "recovery", body, clock.())

      _ ->
        :ok
    end
  end

  defp claim_outage(txn, owner, episode, operation, clock) do
    sessions = active_sessions(txn, owner)

    case coordinator_state(sessions) do
      {:held, coordinators} ->
        body = outage_body(txn, owner, coordinators, sessions)
        at = clock.()

        case outage_due(txn, owner, at) do
          nil -> mark_attempt(txn, operation, episode, "outage", body, at)
          due_at -> {:defer, due_at}
        end

      {:ready, ready} ->
        recover(txn, episode, ready, sessions, clock.())
        :ok

      :empty ->
        :ok
    end
  end

  defp mark_attempt(txn, operation, episode, phase, body, at) do
    Txn.q(
      txn,
      """
      UPDATE coordinator_hold_sends SET attemptedAt=?2,outcome='outcome_unknown',body=?3
      WHERE operationId=?1
      """,
      [operation, at, body]
    )

    {:send, episode, phase, body}
  end

  defp deliver(db, episode, phase, operation, body, runner) do
    phase = if phase == "outage", do: :outage, else: :recovery

    {outcome, code} =
      HarklightSend.send_coordinator_hold(phase, operation, body, runner: runner)

    {:ok, _} =
      DB.query(db, "UPDATE coordinator_hold_sends SET outcome=?2 WHERE operationId=?1", [
        operation,
        outcome
      ])

    if outcome != "committed" do
      Logger.warning(
        "Coordinator hold notice #{outcome} episode=#{episode} operation=#{operation} reason=#{code}"
      )
    end
  end

  defp outage_body(txn, owner, coordinators, sessions) do
    held = Enum.reject(sessions, &(&1.sources == []))

    routes =
      held
      |> Enum.group_by(&{&1.harness, &1.host})
      |> Enum.sort()
      |> Enum.map(fn {{harness, host}, group} ->
        resets =
          group
          |> Enum.flat_map(&[park_reset(txn, &1.incident_id), &1.model_reset])
          |> Enum.filter(&is_integer/1)

        reset =
          case Enum.max(resets, fn -> nil end) do
            nil -> "Reset time unknown."
            at -> "Provider reset #{time(at)}."
          end

        count = length(group)
        unit = if count == 1, do: "session", else: "sessions"
        "#{harness} at #{host} has #{count} held #{unit}. #{reset}"
      end)

    urgent = urgent_work(txn, owner, held)
    next = "Tightbeam will resume work as routes recover and tell you when a coordinator can act."
    next = if urgent == [], do: next, else: next <> " Check any deadline above that is at risk."

    summary =
      case length(coordinators) do
        1 -> "The only active coordinator is held."
        count -> "All #{count} coordinators are held."
      end

    ([summary] ++ routes ++ urgent ++ [next])
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
