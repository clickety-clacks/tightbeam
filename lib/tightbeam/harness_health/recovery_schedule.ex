defmodule Tightbeam.HarnessHealth.RecoverySchedule do
  @moduledoc false
  require Logger

  alias Tightbeam.{DB, Id, Rules}
  alias Tightbeam.DB.Txn
  alias Tightbeam.HarnessHealth.RecoveryScheduler
  alias Tightbeam.RowReactions.Snapshot

  @family "harness-health-recovery"
  @slot "cycle"
  @settings ~w(eligible_failure_classes interval_ms timeout_ms start withdraw reschedule release)
  @reactions %{
    "start" => "schedule_one_cycle_for_eligible_open_hold",
    "withdraw" => "withdraw_resolved_or_ineligible_cycle_at_delivery",
    "reschedule" => "move_the_single_pending_cycle_in_place",
    "release" => "resolve_only_after_all_constituent_routes_succeed"
  }
  @classes ~w(auth-dead rate-limit-dead adapter_unavailable model_unavailable task_crash interrupted-outcome-unknown)
  @migration "harness-health-recovery-schedules/v1"

  @ddl """
  CREATE TABLE harness_health_recovery_schedules (
    holdId TEXT PRIMARY KEY REFERENCES harness_health_incidents(id),
    org TEXT NOT NULL,
    family TEXT NOT NULL,
    slot TEXT NOT NULL,
    sourceEventId TEXT NOT NULL,
    cycleId TEXT NOT NULL UNIQUE,
    failureClass TEXT NOT NULL,
    eligibleClasses TEXT NOT NULL,
    intervalMs INTEGER NOT NULL CHECK(intervalMs > 0),
    timeoutMs INTEGER NOT NULL CHECK(timeoutMs > 0),
    policyDigest TEXT NOT NULL,
    dueAt INTEGER NOT NULL CHECK(dueAt >= 0),
    startedAt INTEGER,
    previousStartedAt INTEGER,
    status TEXT NOT NULL CHECK(status IN ('pending','due','withdrawn','completed')),
    createdAt INTEGER NOT NULL CHECK(createdAt >= 0),
    updatedAt INTEGER NOT NULL CHECK(updatedAt >= 0),
    UNIQUE(org,family,sourceEventId,slot)
  );
  CREATE INDEX harness_health_recovery_schedule_due
    ON harness_health_recovery_schedules(status,dueAt,holdId);
  """

  def ensure_schema(db) do
    case DB.transaction(db, fn txn ->
           case Txn.q(txn, "SELECT 1 FROM supervision_liveness_migrations WHERE migrationId=?1", [
                  @migration
                ]) do
             [[1]] ->
               validate_schema!(txn)

             [] ->
               :ok = Txn.exec(txn, @ddl)

               Txn.q(
                 txn,
                 "INSERT INTO supervision_liveness_migrations(migrationId,appliedAt,affectedRows,cause,principal) VALUES(?1,?2,0,'release_upgrade','process:tightbeam')",
                 [@migration, System.system_time(:millisecond)]
               )

               :ok
           end

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  def reconcile_hold_in_txn(txn, hold, source_event_id, now, opts \\ []) do
    policy = policy()

    case policy do
      {:ok, settings, digest} ->
        if eligible?(hold, settings) do
          upsert(txn, hold, source_event_id, settings, digest, now, opts)
        else
          withdraw(txn, hold["id"], now)
        end

      :unavailable ->
        withdraw(txn, hold["id"], now)
    end

    :ok
  end

  def reconcile_open_holds_in_txn(txn, now) do
    policy = policy()

    open_holds =
      Txn.q(
        txn,
        "SELECT id FROM harness_health_incidents WHERE state='open' ORDER BY openedAt,id"
      )
      |> Enum.map(fn [id] -> Snapshot.harness_health_hold(txn, id) end)

    open_ids = MapSet.new(Enum.map(open_holds, & &1["id"]))

    case policy do
      {:ok, settings, digest} ->
        Enum.each(open_holds, fn hold ->
          source_event_id = "harness-health-hold:#{hold["id"]}:opened"

          reconcile_with_policy(
            txn,
            hold,
            source_event_id,
            settings,
            digest,
            now,
            cutover: true
          )
        end)

      :unavailable ->
        Txn.q(
          txn,
          "UPDATE harness_health_recovery_schedules SET status='withdrawn',updatedAt=?1 WHERE status IN ('pending','due')",
          [now]
        )
    end

    Txn.q(
      txn,
      "SELECT holdId FROM harness_health_recovery_schedules WHERE status IN ('pending','due')"
    )
    |> Enum.each(fn [hold_id] ->
      unless MapSet.member?(open_ids, hold_id) do
        withdraw(txn, hold_id, now)
      end
    end)

    :ok
  end

  def reconcile_open_holds(db, now \\ System.system_time(:millisecond)) do
    case DB.transaction(db, &reconcile_open_holds_in_txn(&1, now)) do
      {:ok, :ok} ->
        RecoveryScheduler.refresh()
        :ok

      {:error, error} ->
        raise error
    end
  end

  def fire_due(db, now \\ System.system_time(:millisecond)) do
    case DB.transaction(db, &fire_due_in_txn(&1, now)) do
      {:ok, cycles} -> cycles
      {:error, error} -> raise error
    end
  end

  def fire_due_in_txn(txn, now) do
    due =
      Txn.q(
        txn,
        "SELECT holdId,cycleId FROM harness_health_recovery_schedules WHERE status='pending' AND dueAt<=?1 ORDER BY dueAt,holdId",
        [now]
      )

    Enum.flat_map(due, fn [hold_id, cycle_id] ->
      hold = Snapshot.harness_health_hold(txn, hold_id)

      case policy() do
        {:ok, settings, _digest} when not is_nil(hold) ->
          if eligible?(hold, settings) do
            Txn.q(
              txn,
              "UPDATE harness_health_recovery_schedules SET status='due',startedAt=?3,previousStartedAt=?3,updatedAt=?3 WHERE holdId=?1 AND cycleId=?2 AND status='pending'",
              [hold_id, cycle_id, now]
            )

            if Txn.changes(txn) == 1 do
              [%{"hold_id" => hold_id, "cycle_id" => cycle_id, "routes" => hold["routes"]}]
            else
              []
            end
          else
            withdraw(txn, hold_id, now)
            []
          end

        _ ->
          withdraw(txn, hold_id, now)
          []
      end
    end)
  end

  def next_due_at(db) do
    case DB.query(
           db,
           "SELECT MIN(dueAt) FROM harness_health_recovery_schedules WHERE status='pending'"
         ) do
      {:ok, [[nil]]} -> nil
      {:ok, [[due_at]]} when is_integer(due_at) -> due_at
      {:ok, rows} -> raise ArgumentError, "invalid recovery schedule deadline rows: #{inspect(rows)}"
      {:error, error} -> raise error
    end
  end

  def due_cycles(db) do
    case DB.query(
           db,
           "SELECT holdId,cycleId,sourceEventId,failureClass,eligibleClasses,intervalMs,timeoutMs,dueAt,startedAt FROM harness_health_recovery_schedules WHERE status='due' ORDER BY startedAt,holdId"
         ) do
      {:ok, rows} ->
        Enum.map(rows, fn [hold_id, cycle_id, event_id, failure_class, classes, interval, timeout, due, started] ->
          %{
            "hold_id" => hold_id,
            "cycle_id" => cycle_id,
            "source_event_id" => event_id,
            "failure_class" => failure_class,
            "eligible_classes" => JSON.decode!(classes),
            "interval_ms" => interval,
            "timeout_ms" => timeout,
            "due_at" => due,
            "started_at" => started
          }
        end)

      {:error, error} ->
        raise error
    end
  end

  @doc false
  def finish_cycle_in_txn(txn, hold_id, cycle_id, now) do
    case Txn.q(
           txn,
           "SELECT sourceEventId,status FROM harness_health_recovery_schedules WHERE holdId=?1 AND cycleId=?2",
           [hold_id, cycle_id]
         ) do
      [[source_event_id, "due"]] ->
        Txn.q(
          txn,
          "UPDATE harness_health_recovery_schedules SET status='withdrawn',updatedAt=?3 WHERE holdId=?1 AND cycleId=?2 AND status='due'",
          [hold_id, cycle_id, now]
        )

        if Txn.changes(txn) == 1 do
          case Snapshot.harness_health_hold(txn, hold_id) do
            %{"state" => "open"} = hold ->
              reconcile_hold_in_txn(txn, hold, source_event_id, now)

            _ ->
              :ok
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  @doc false
  def complete_cycle_in_txn(txn, hold_id, cycle_id, now) do
    Txn.q(
      txn,
      "UPDATE harness_health_recovery_schedules SET status='completed',updatedAt=?3 WHERE holdId=?1 AND cycleId=?2 AND status IN ('due','withdrawn')",
      [hold_id, cycle_id, now]
    )

    if Txn.changes(txn) != 1, do: raise("harness health recovery cycle lost its release claim")
    :ok
  end

  @doc false
  def due_cycle_for_delivery_in_txn(txn, hold_id, cycle_id, now) do
    case Txn.q(
           txn,
           "SELECT startedAt,timeoutMs,status FROM harness_health_recovery_schedules WHERE holdId=?1 AND cycleId=?2",
           [hold_id, cycle_id]
         ) do
      [[started_at, timeout_ms, "due"]] ->
        hold = Snapshot.harness_health_hold(txn, hold_id)

        case {hold, policy()} do
          {%{"state" => "open"} = hold, {:ok, settings, _digest}} ->
            if eligible?(hold, settings) do
              {:ok,
               %{cycle_id: cycle_id, started_at: started_at, timeout_ms: timeout_ms}, hold}
            else
              finish_cycle_in_txn(txn, hold_id, cycle_id, now)
              :withdrawn
            end

          _ ->
            finish_cycle_in_txn(txn, hold_id, cycle_id, now)
            :withdrawn
        end

      _ ->
        :withdrawn
    end
  end

  defp reconcile_with_policy(txn, hold, source_event_id, settings, digest, now, opts) do
    if eligible?(hold, settings) do
      upsert(txn, hold, source_event_id, settings, digest, now, opts)
    else
      withdraw(txn, hold["id"], now)
    end
  end

  defp upsert(txn, hold, source_event_id, settings, digest, now, opts) do
    hold_id = hold["id"]
    interval_ms = settings["interval_ms"]

    case Txn.q(
           txn,
           "SELECT cycleId,status,policyDigest,intervalMs,previousStartedAt FROM harness_health_recovery_schedules WHERE holdId=?1",
           [hold_id]
         ) do
      [] ->
        due_at = initial_due_at(hold, settings, now, opts, nil)
        insert_cycle(txn, hold, source_event_id, settings, digest, due_at, now)

      [[cycle_id, "pending", ^digest, ^interval_ms, _previous_started_at]] ->
        Txn.q(
          txn,
          "UPDATE harness_health_recovery_schedules SET sourceEventId=?2,updatedAt=?3 WHERE holdId=?1 AND status='pending'",
          [hold_id, source_event_id, now]
        )

        cycle_id

      [[cycle_id, "pending", _old_digest, _old_interval, previous_started_at]] ->
        due_at =
          max(
            hold["openedAt"] + settings["interval_ms"],
            if(previous_started_at, do: previous_started_at + settings["interval_ms"], else: 0)
          )

        Txn.q(
          txn,
          "UPDATE harness_health_recovery_schedules SET sourceEventId=?2,eligibleClasses=?3,intervalMs=?4,timeoutMs=?5,policyDigest=?6,dueAt=?7,updatedAt=?8 WHERE holdId=?1 AND status='pending'",
          [
            hold_id,
            source_event_id,
            JSON.encode!(settings["eligible_failure_classes"]),
            settings["interval_ms"],
            settings["timeout_ms"],
            digest,
            due_at,
            now
          ]
        )

        cycle_id

      [[_cycle_id, "due", _old_digest, _old_interval, _previous_started_at]] ->
        :ok

      [[_cycle_id, "withdrawn", _old_digest, _old_interval, previous_started_at]] ->
        due_at = initial_due_at(hold, settings, now, opts, previous_started_at)
        insert_cycle(txn, hold, source_event_id, settings, digest, due_at, now, replace: true)
    end
  end

  defp insert_cycle(txn, hold, source_event_id, settings, digest, due_at, now, opts \\ []) do
    cycle_id = "hhrc_" <> Id.uuid4()
    hold_id = hold["id"]

    eligible_classes = JSON.encode!(settings["eligible_failure_classes"])

    if Keyword.get(opts, :replace, false) do
      Txn.q(
        txn,
        "UPDATE harness_health_recovery_schedules SET org=?2,family=?3,slot=?4,sourceEventId=?5,cycleId=?6,failureClass=?7,eligibleClasses=?8,intervalMs=?9,timeoutMs=?10,policyDigest=?11,dueAt=?12,startedAt=NULL,status='pending',updatedAt=?13 WHERE holdId=?1",
        [
          hold_id,
          hold["ownerUserId"] || "system",
          @family,
          @slot,
          source_event_id,
          cycle_id,
          hold["failureClass"],
          eligible_classes,
          settings["interval_ms"],
          settings["timeout_ms"],
          digest,
          due_at,
          now
        ]
      )
    else
      Txn.q(
        txn,
        "INSERT INTO harness_health_recovery_schedules(holdId,org,family,slot,sourceEventId,cycleId,failureClass,eligibleClasses,intervalMs,timeoutMs,policyDigest,dueAt,startedAt,previousStartedAt,status,createdAt,updatedAt) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,NULL,NULL,'pending',?13,?13)",
        [
          hold_id,
          hold["ownerUserId"] || "system",
          @family,
          @slot,
          source_event_id,
          cycle_id,
          hold["failureClass"],
          eligible_classes,
          settings["interval_ms"],
          settings["timeout_ms"],
          digest,
          due_at,
          now
        ]
      )
    end

    cycle_id
  end

  defp initial_due_at(hold, settings, now, opts, previous_started_at) do
    interval_ms = settings["interval_ms"]

    due_at =
      max(
        hold["openedAt"] + interval_ms,
        if(previous_started_at, do: previous_started_at + interval_ms, else: 0)
      )

    if Keyword.get(opts, :cutover, false), do: max(due_at, now), else: due_at
  end

  defp withdraw(txn, hold_id, now) do
    Txn.q(
      txn,
      "UPDATE harness_health_recovery_schedules SET status='withdrawn',updatedAt=?2 WHERE holdId=?1 AND status IN ('pending','due')",
      [hold_id, now]
    )

    :ok
  end

  defp policy do
    case Rules.reaction_policy(@family) do
      %{settings: settings} when is_map(settings) ->
        if valid_settings?(settings) do
          digest =
            :crypto.hash(:sha256, JSON.encode!(settings))
            |> Base.encode16(case: :lower)

          {:ok, settings, digest}
        else
          Logger.warning("harness health recovery settings are invalid; no cycle selected")
          :unavailable
        end

      _ ->
        :unavailable
    end
  end

  defp valid_settings?(settings) do
    keys = settings |> Map.keys() |> Enum.sort()

    keys == Enum.sort(@settings) and
      is_list(settings["eligible_failure_classes"]) and
      Enum.all?(settings["eligible_failure_classes"], &(&1 in @classes)) and
      length(settings["eligible_failure_classes"]) ==
        length(Enum.uniq(settings["eligible_failure_classes"])) and
      is_integer(settings["interval_ms"]) and settings["interval_ms"] > 0 and
      is_integer(settings["timeout_ms"]) and settings["timeout_ms"] > 0 and
      Enum.all?(@reactions, fn {key, expected} -> settings[key] == expected end)
  end

  defp eligible?(%{"state" => "open", "failureClass" => failure_class}, settings),
    do: failure_class != "other" and failure_class in settings["eligible_failure_classes"]

  defp eligible?(_, _settings), do: false

  defp validate_schema!(txn) do
    columns =
      Txn.q(txn, "PRAGMA table_info(harness_health_recovery_schedules)")
      |> Enum.map(fn [_cid, name | _rest] -> name end)

    expected =
      ~w(holdId org family slot sourceEventId cycleId failureClass eligibleClasses intervalMs timeoutMs policyDigest dueAt startedAt previousStartedAt status createdAt updatedAt)

    unless columns == expected do
      raise ArgumentError, "incompatible harness health recovery schedule schema"
    end

    case Txn.q(
           txn,
           "SELECT 1 FROM sqlite_schema WHERE type='index' AND name='harness_health_recovery_schedule_due'"
         ) do
      [[1]] -> :ok
      _ -> raise ArgumentError, "harness health recovery schedule index is missing"
    end
  end
end

defmodule Tightbeam.HarnessHealth.RecoveryScheduler do
  @moduledoc false
  use GenServer

  alias Tightbeam.HarnessHealth.RecoverySchedule

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def refresh(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, :refresh)
    :ok
  end

  @impl true
  def init(opts) do
    db = Keyword.fetch!(opts, :db)
    base_dir = Keyword.get(opts, :base_dir)
    task_sup = Keyword.get(opts, :task_sup)
    :ok = Tightbeam.HarnessHealth.RecoveryCheck.ensure_schema(db)
    :ok = Tightbeam.HarnessHealth.RecoveryCheck.recover_running(db)
    :ok = RecoverySchedule.reconcile_open_holds(db)
    send(self(), :resume_due)
    {:ok, arm(%{db: db, base_dir: base_dir, task_sup: task_sup, timer: nil, token: nil})}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, arm(state)}

  @impl true
  def handle_info(:resume_due, state) do
    resume_due(state)
    {:noreply, arm(state)}
  end

  @impl true
  def handle_info({:recovery_deadline, token}, %{token: token} = state) do
    resume_due(state)
    {:noreply, arm(%{state | timer: nil, token: nil})}
  end

  def handle_info({:recovery_deadline, _stale_token}, state), do: {:noreply, state}

  defp resume_due(%{base_dir: base_dir, task_sup: task_sup} = state)
       when is_binary(base_dir) and not is_nil(task_sup) do
    Tightbeam.HarnessHealth.RecoveryCheck.resume_due(state.db, base_dir, task_sup)
  end

  defp resume_due(_state), do: :ok

  defp arm(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    token = make_ref()

    timer =
      case RecoverySchedule.next_due_at(state.db) do
        nil ->
          nil

        due_at ->
          delay = min(max(due_at - System.system_time(:millisecond), 0), 2_147_483_647)
          Process.send_after(self(), {:recovery_deadline, token}, delay)
      end

    %{state | timer: timer, token: if(timer, do: token, else: nil)}
  end
end
