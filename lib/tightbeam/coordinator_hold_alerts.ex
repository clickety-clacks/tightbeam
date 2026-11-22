defmodule Tightbeam.CoordinatorHoldAlerts do
  @moduledoc false
  use GenServer
  require Logger

  alias Tightbeam.{DB, HarklightSend, Id, Org, RateLimitReset}
  alias Tightbeam.DB.Txn

  @alert_interval_ms :timer.minutes(5)

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
    state = %{db: Keyword.fetch!(opts, :db), runner: opts[:runner], timer: nil}
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
      case DB.owed_work(fn -> reconcile(state.db, now(), state.runner) end) do
        nil -> nil
        due_at -> :erlang.start_timer(max(0, due_at - now()), self(), :reconcile)
      end

    %{state | timer: timer}
  end

  @doc false
  def reconcile(db, at, runner) do
    {:ok, {due_at, pending}} =
      DB.transaction(db, fn txn ->
        # Harklight's configured destination belongs to the gateway operator.
        # Match the gateway's first-admin convention for owner notices.
        case Txn.q(
               txn,
               "SELECT userId FROM users WHERE isAdmin=1 ORDER BY createdAt,userId LIMIT 1"
             ) do
          [[owner]] ->
            {due_at, allow_outage} = reconcile_owner(txn, owner, active_sessions(txn, owner), at)
            {due_at, pending_sends(txn, owner, allow_outage)}

          [] ->
            {nil, []}
        end
      end)

    Enum.each(pending, &claim_and_deliver(db, &1, at, runner))
    due_at
  end

  defp active_sessions(txn, owner) do
    Txn.q(
      txn,
      """
      SELECT s.ownerUserId,s.sessionKey,s.archetype,s.displayName,s.harness,s.host,s.model,
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
                     owner,
                     key,
                     archetype,
                     name,
                     harness,
                     host,
                     model,
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
        owner: owner,
        key: key,
        name: name,
        harness: harness,
        host: host,
        model: model,
        parked: not is_nil(parked_at),
        sources: sources,
        incident_id: incident_id,
        model_reset: model_reset(cause, observed_at),
        coordinator: key == Org.personal_session_key(owner) or coordinator_archetype?(archetype)
      }
    end)
  end

  defp coordinator_archetype?(archetype) do
    List.last(String.split(archetype, ".")) in ["exec", "deliverator"]
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
    coordinators = Enum.filter(sessions, & &1.coordinator)
    available = Enum.find(coordinators, &(&1.sources == []))

    case {coordinators, available, open_episode(txn, owner)} do
      {[], _, _} ->
        {nil, false}

      {_, nil, episode} ->
        {outage(txn, owner, episode, coordinators, sessions, at), true}

      {_, ready, episode} ->
        if episode, do: recover(txn, episode, ready, sessions, at)
        {nil, false}
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

  defp outage(txn, owner, episode, coordinators, sessions, at) do
    episode =
      episode ||
        open_episode_in_txn(txn, owner, Enum.flat_map(coordinators, & &1.sources), at)

    [[already_reserved, last_attempt]] =
      Txn.q(
        txn,
        """
        SELECT EXISTS(SELECT 1 FROM coordinator_hold_sends WHERE episodeId=?1 AND phase='outage'),
               MAX(s.attemptedAt)
        FROM coordinator_hold_sends s JOIN coordinator_hold_episodes e ON e.id=s.episodeId
        WHERE e.ownerUserId=?2 AND s.phase='outage'
        """,
        [episode, owner]
      )

    cond do
      already_reserved == 1 ->
        nil

      last_attempt && at < last_attempt + @alert_interval_ms ->
        last_attempt + @alert_interval_ms

      true ->
        reserve(txn, episode, "outage", outage_body(txn, coordinators, sessions))
        nil
    end
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

        name =
          if ready.key == Org.personal_session_key(ready.owner),
            do: "Main",
            else: short(ready.name)

        line = "#{name} can take turns again on #{ready.harness} at #{ready.host}."

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

  defp claim_and_deliver(db, [operation], at, runner) do
    case DB.query(
           db,
           """
           UPDATE coordinator_hold_sends SET attemptedAt=?2,outcome='outcome_unknown'
           WHERE operationId=?1 AND attemptedAt IS NULL
           AND (phase='recovery' OR EXISTS(
             SELECT 1 FROM coordinator_hold_episodes e WHERE e.id=episodeId AND e.closedAt IS NULL
           ))
           RETURNING episodeId,phase,body
           """,
           [operation, at]
         ) do
      {:ok, [[episode, phase, body]]} ->
        deliver(db, episode, phase, operation, body, runner)

      {:ok, []} ->
        :ok
    end
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

  defp outage_body(txn, coordinators, sessions) do
    held = Enum.reject(sessions, &(&1.sources == []))

    routes =
      held
      |> Enum.group_by(&{&1.harness, &1.host, if(&1.parked, do: nil, else: &1.model)})
      |> Enum.sort()
      |> Enum.map(fn {{harness, host, model}, group} ->
        route = if model, do: "#{harness} (#{model})", else: harness

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
        "#{route} at #{host} has #{count} held #{unit}. #{reset}"
      end)

    urgent = urgent_work(txn, held)
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

  defp urgent_work(txn, held) do
    keys = JSON.encode!(Enum.map(held, & &1.key))

    Txn.q(
      txn,
      """
      WITH held_sessions AS (SELECT value AS sessionKey FROM json_each(?1)),
      sources AS (
        SELECT w.wakeId,w.assignmentId,w.work_item_id,w.dueAt,w.createdAt,NULL AS requestRef
        FROM wakes w JOIN held_sessions h ON h.sessionKey=w.sessionKey
        WHERE w.state='pending' AND w.consumer='prompt'
        UNION
        SELECT w.wakeId,COALESCE(w.assignmentId,t.assignmentId),w.work_item_id,w.dueAt,w.createdAt,t.requestRef
        FROM held_sessions h JOIN turns t ON t.sessionKey=h.sessionKey AND t.status='queued'
        JOIN wakes w ON w.deliveredTurnSeq=t.seq OR w.wakeId=t.wakeId
      )
      SELECT DISTINCT
        COALESCE(item.title,a.subject,'Scheduled work'),
        COALESCE(d.deadlineAt,CASE WHEN s.dueAt>s.createdAt THEN s.dueAt END)
      FROM sources s
      LEFT JOIN assignments a ON a.id=s.assignmentId
      LEFT JOIN work_items item ON item.id=COALESCE(s.work_item_id,a.workItemId)
      LEFT JOIN decision_requests d ON d.status='open'
        AND (d.id=s.requestRef OR d.deadlineWakeId=s.wakeId)
      WHERE d.deadlineAt IS NOT NULL OR s.dueAt>s.createdAt
      ORDER BY 2,1 LIMIT 3
      """,
      [keys]
    )
    |> Enum.map(fn [title, at] -> "#{short(title)} due #{time(at)}." end)
  end

  defp short(text), do: text |> String.replace(~r/\s+/, " ") |> String.slice(0, 120)

  defp time(at) do
    case DateTime.from_unix(at, :millisecond) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%b %d %H:%M UTC")
      _ -> "at an unknown time"
    end
  end

  defp now, do: System.system_time(:millisecond)
end
