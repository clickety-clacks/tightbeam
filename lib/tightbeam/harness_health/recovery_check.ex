defmodule Tightbeam.HarnessHealth.RecoveryCheck do
  @moduledoc false

  alias Tightbeam.{DB, ErrorDiagnostic, EventLog, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Harness.RecoveryCheck, as: HarnessCheck
  alias Tightbeam.HarnessHealth.{RecoverySchedule, RecoveryScheduler}
  alias Tightbeam.RowReactions.Snapshot

  @checks_ddl """
  CREATE TABLE IF NOT EXISTS harness_health_recovery_checks (
    holdId TEXT NOT NULL REFERENCES harness_health_incidents(id),
    cycleId TEXT NOT NULL,
    routeKey TEXT NOT NULL,
    routeJson TEXT NOT NULL,
    harness TEXT NOT NULL,
    host TEXT NOT NULL,
    sharedAccount TEXT NOT NULL,
    model TEXT NOT NULL,
    startedAt INTEGER NOT NULL CHECK(startedAt >= 0),
    finishedAt INTEGER,
    outcome TEXT NOT NULL CHECK(outcome IN ('running','succeeded','failed','inconclusive','uncheckable')),
    errorExcerpt TEXT,
    eventId TEXT NOT NULL UNIQUE,
    org TEXT NOT NULL,
    PRIMARY KEY(holdId,cycleId,routeKey),
    CHECK((outcome='running' AND finishedAt IS NULL) OR
          (outcome!='running' AND finishedAt IS NOT NULL)),
    CHECK(errorExcerpt IS NULL OR length(errorExcerpt) <= 512)
  );
  CREATE INDEX IF NOT EXISTS harness_health_recovery_check_cycle
    ON harness_health_recovery_checks(holdId,cycleId,outcome,routeKey);

  CREATE TABLE IF NOT EXISTS harness_health_recovery_warnings (
    holdId TEXT PRIMARY KEY REFERENCES harness_health_incidents(id),
    reason TEXT NOT NULL,
    eventId TEXT NOT NULL UNIQUE,
    createdAt INTEGER NOT NULL CHECK(createdAt >= 0)
  );
  """

  @checks_columns ~w(
    holdId cycleId routeKey routeJson harness host sharedAccount model startedAt finishedAt
    outcome errorExcerpt eventId org
  )
  @warnings_columns ~w(holdId reason eventId createdAt)
  @error_limit 512

  def ensure_schema(db) do
    case DB.transaction(db, fn txn ->
           Txn.exec(txn, @checks_ddl)
           validate_schema!(txn)
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  def start_cycle(db, base_dir, task_sup, hold_id, cycle_id) do
    now = System.system_time(:millisecond)

    case DB.transaction(db, fn txn ->
             case RecoverySchedule.due_cycle_for_delivery_in_txn(txn, hold_id, cycle_id, now) do
             {:ok, schedule, hold} ->
               if hold["routesComplete"] and hold["routes"] != [] do
                 checks =
                   hold["routes"]
                   |> Enum.sort_by(&route_key/1)
                   |> Enum.flat_map(fn route ->
                     case insert_running_in_txn(txn, schedule, hold, route) do
                       {:inserted, check} -> [check]
                       :already_recorded -> []
                     end
                   end)

                 {checks, :running}
               else
                 warn_uncheckable_in_txn(txn, hold_id, "constituent routes are incomplete", now)
                 RecoverySchedule.finish_cycle_in_txn(txn, hold_id, cycle_id, now)
                 {[], :finished}
               end

             :withdrawn ->
               {[], :withdrawn}
           end
         end) do
      {:ok, {checks, _status}} ->
        Enum.each(checks, &start_check(task_sup, db, base_dir, &1))
        RecoveryScheduler.refresh()
        :ok

      {:error, error} ->
        raise error
    end
  end

  def recover_running(db) do
    now = System.system_time(:millisecond)

    case DB.transaction(db, fn txn ->
           rows =
             Txn.q(
               txn,
               "SELECT holdId,cycleId,routeKey FROM harness_health_recovery_checks WHERE outcome='running' ORDER BY holdId,cycleId,routeKey"
             )

           cycles =
             rows
             |> Enum.map(fn [hold_id, cycle_id, _route_key] -> {hold_id, cycle_id} end)
             |> Enum.uniq()

           Enum.each(rows, fn [hold_id, cycle_id, route_key] ->
             record_result_in_txn(txn, hold_id, cycle_id, route_key, "inconclusive", nil, now)
           end)

           Enum.each(cycles, fn {hold_id, cycle_id} ->
             finalize_cycle_in_txn(txn, hold_id, cycle_id, now)
           end)

           :ok
         end) do
      {:ok, :ok} ->
        RecoveryScheduler.refresh()
        :ok

      {:error, error} ->
        raise error
    end
  end

  def resume_due(db, base_dir, task_sup) do
    Wakes.resume_cycle_release_redeliveries(db)
    RecoverySchedule.fire_due(db, System.system_time(:millisecond))

    RecoverySchedule.due_cycles(db)
    |> Enum.each(fn cycle ->
      start_cycle(db, base_dir, task_sup, cycle["hold_id"], cycle["cycle_id"])
    end)

    :ok
  end

  @doc false
  def route_key(route) do
    route
    |> Map.take(~w(harness host sharedAccount model))
    |> JSON.encode!()
  end

  defp insert_running_in_txn(txn, schedule, hold, route) do
    key = route_key(route)
    event_id = check_event_id(hold["id"], schedule.cycle_id, key)
    route_json = JSON.encode!(Map.take(route, ~w(harness host sharedAccount model)))

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO harness_health_recovery_checks
        (holdId,cycleId,routeKey,routeJson,harness,host,sharedAccount,model,startedAt,
         finishedAt,outcome,errorExcerpt,eventId,org)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,NULL,'running',NULL,?10,?11)
      """,
      [
        hold["id"],
        schedule.cycle_id,
        key,
        route_json,
        route["harness"],
        route["host"],
        route["sharedAccount"],
        route["model"],
        schedule.started_at,
        event_id,
        hold["ownerUserId"] || "system"
      ]
    )

    if Txn.changes(txn) == 1 do
      {:inserted,
       %{
         hold_id: hold["id"],
         cycle_id: schedule.cycle_id,
         route_key: key,
         route: Map.take(route, ~w(harness host sharedAccount model)),
         started_at: schedule.started_at,
         timeout_ms: schedule.timeout_ms,
         org: hold["ownerUserId"] || "system"
       }}
    else
      :already_recorded
    end
  end

  defp start_check(task_sup, db, base_dir, check) do
    case Task.Supervisor.start_child(task_sup, fn ->
           result = HarnessCheck.run(base_dir, db, check.route, check.timeout_ms)
           record_result(db, check, result)
         end) do
      {:ok, _pid} -> :ok
      {:error, reason} ->
        record_result(db, check, {:inconclusive, diagnostic(reason)})
    end
  end

  @doc false
  def binary_selection_program(harness), do: HarnessCheck.binary_selection_program(harness)

  defp record_result(db, check, {outcome, excerpt}) do
    now = System.system_time(:millisecond)
    excerpt = sanitize_excerpt(excerpt)

    case DB.transaction(db, fn txn ->
           record_result_in_txn(
             txn,
             check.hold_id,
             check.cycle_id,
             check.route_key,
             Atom.to_string(outcome),
             excerpt,
             now
           )
         end) do
      {:ok, {:released, release}} ->
        Wakes.redeliver_cycle_release(
          db,
          release.correlation,
          release.harness,
          release.host
        )

        RecoveryScheduler.refresh()
        :ok

      {:ok, _} ->
        RecoveryScheduler.refresh()
        :ok

      {:error, error} ->
        raise error
    end
  end

  @doc false
  @spec record_result_in_txn(
          Txn.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          integer()
        ) :: :ok | {:released, map()}
  def record_result_in_txn(txn, hold_id, cycle_id, route_key, outcome, excerpt, finished_at)
       when outcome in ["succeeded", "failed", "inconclusive", "uncheckable"] do
    case Txn.q(
           txn,
           "SELECT routeJson,startedAt,eventId,org,outcome FROM harness_health_recovery_checks WHERE holdId=?1 AND cycleId=?2 AND routeKey=?3",
           [hold_id, cycle_id, route_key]
         ) do
      [[route_json, started_at, event_id, org, "running"]] ->
        Txn.q(
          txn,
          "UPDATE harness_health_recovery_checks SET finishedAt=?4,outcome=?5,errorExcerpt=?6 WHERE holdId=?1 AND cycleId=?2 AND routeKey=?3 AND outcome='running'",
          [hold_id, cycle_id, route_key, finished_at, outcome, excerpt]
        )

        if Txn.changes(txn) == 1 do
          check = %{
            event_id: event_id,
            org: org,
            hold_id: hold_id,
            cycle_id: cycle_id,
            route: JSON.decode!(route_json),
            started_at: started_at,
            finished_at: finished_at,
            outcome: outcome,
            error_excerpt: excerpt
          }

          Tightbeam.RowReactions.remember_harness_health_recovery_check_in_txn(txn, check)
          if outcome == "uncheckable", do: warn_uncheckable_in_txn(txn, hold_id, "route capability unavailable", finished_at)
          finalize_cycle_in_txn(txn, hold_id, cycle_id, finished_at)
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp finalize_cycle_in_txn(txn, hold_id, cycle_id, now) do
    running =
      Txn.q(
        txn,
        "SELECT 1 FROM harness_health_recovery_checks WHERE holdId=?1 AND cycleId=?2 AND outcome='running' LIMIT 1",
        [hold_id, cycle_id]
      )

    if running == [] do
      case RecoverySchedule.due_cycle_for_delivery_in_txn(txn, hold_id, cycle_id, now) do
        {:ok, _schedule, hold} ->
          if all_current_routes_succeeded?(txn, hold_id, hold, cycle_id) do
            case Tightbeam.HarnessHealth.resolve_recovery_cycle_in_txn(txn, hold_id, cycle_id, now) do
              {:resolved, incident, correlation} ->
                RecoverySchedule.complete_cycle_in_txn(txn, hold_id, cycle_id, now)

                {:released,
                 %{
                   correlation: correlation,
                   harness: incident.harness,
                   host: incident.host
                 }}

              _ ->
                RecoverySchedule.finish_cycle_in_txn(txn, hold_id, cycle_id, now)
                :ok
            end
          else
            RecoverySchedule.finish_cycle_in_txn(txn, hold_id, cycle_id, now)
            :ok
          end

        :withdrawn ->
          :ok
      end
    else
      :ok
    end
  end

  defp all_current_routes_succeeded?(
         txn,
         hold_id,
         %{"routesComplete" => true, "routes" => routes},
         cycle_id
       )
       when is_list(routes) and routes != [] do
    Enum.all?(routes, fn route ->
      case Txn.q(
             txn,
             "SELECT outcome FROM harness_health_recovery_checks WHERE holdId=?1 AND cycleId=?2 AND routeKey=?3",
             [hold_id, cycle_id, route_key(route)]
           ) do
        [["succeeded"]] -> true
        _ -> false
      end
    end)
  end

  defp all_current_routes_succeeded?(_txn, _hold_id, _hold, _cycle_id), do: false

  defp warn_uncheckable_in_txn(txn, hold_id, reason, at) do
    event_id = "harness-health-recovery-uncheckable:" <> hold_id

    Txn.q(
      txn,
      "INSERT OR IGNORE INTO harness_health_recovery_warnings(holdId,reason,eventId,createdAt) VALUES(?1,?2,?3,?4)",
      [hold_id, reason, event_id, at]
    )

    if Txn.changes(txn) == 1 do
      EventLog.lifecycle_in_txn(
        txn,
        "harness_health_recovery_uncheckable",
        hold_id,
        JSON.encode!(%{holdId: hold_id, reason: reason, eventId: event_id})
      )
    end

    :ok
  end

  defp check_event_id(hold_id, cycle_id, route_key) do
    digest = :crypto.hash(:sha256, JSON.encode!([hold_id, cycle_id, route_key])) |> Base.url_encode64(padding: false)
    "harness-health-recovery-check:" <> digest
  end

  defp sanitize_excerpt(nil), do: nil

  defp sanitize_excerpt(value) do
    value
    |> to_string()
    |> ErrorDiagnostic.redact_text()
    |> String.slice(0, @error_limit)
  end

  defp diagnostic(reason), do: reason |> inspect() |> sanitize_excerpt()

  defp validate_schema!(txn) do
    checks =
      Txn.q(txn, "PRAGMA table_info(harness_health_recovery_checks)")
      |> Enum.map(fn [_cid, name | _rest] -> name end)

    warnings =
      Txn.q(txn, "PRAGMA table_info(harness_health_recovery_warnings)")
      |> Enum.map(fn [_cid, name | _rest] -> name end)

    unless checks == @checks_columns and warnings == @warnings_columns do
      raise ArgumentError, "incompatible harness health recovery check schema"
    end

    case Txn.q(
           txn,
           "SELECT 1 FROM sqlite_schema WHERE type='index' AND name='harness_health_recovery_check_cycle'"
         ) do
      [[1]] -> :ok
      _ -> raise ArgumentError, "harness health recovery check index is missing"
    end
  end
end
