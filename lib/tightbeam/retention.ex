defmodule Tightbeam.Retention do
  @moduledoc """
  Deletes allowlisted expired lifecycle observations after boot in bounded batches.
  Configure `:retention_days` with `TIGHTBEAM_RETENTION_DAYS`, default 60.
  """
  use GenServer

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  require Logger

  @day_ms 86_400_000
  @batch 2_000
  @boot_delay 30_000
  @yield_ms 100
  @interval 3_600_000

  # Audited lifecycle_events readers in lib/:
  # escalation.ex: decision_request_ruled proves exactly one ruling for terminal
  # requests, including migration, list/get, consumption and replay validation.
  # supervision.ex: every supervision_entitlement_* kind preserves controller
  # coherence and surviving liveness lineage. recovery_refused also deduplicates
  # refusals. This includes armed, claimed, cleared, deferred, rearmed, rebased,
  # recovered, recovery_refused, terminated and transferred, plus future suffixes.
  # supervision.ex: idle_cleanup_pending_observed deduplicates pending wakes and
  # identifies cleanup occurrences, even when a wake has been pending for months.
  # productions/bubble.ex: lineage_exhausted is the exhaustion deduplication fence.
  # wakes.ex: wake_undeliverable supplies durable delivery-failure evidence.
  # gateway.ex: queued_message_suppressed prevents old queued messages reappearing;
  # retired_workspace_cleanup_completed and retired_workspace_cleanup_incomplete
  # determine whether retirement replay must retry workspace cleanup.
  # EventLog.lifecycle_events/1 lists history without interpreting kinds; it has
  # no callers in lib/. Its observational history can expire for the kinds below.
  # All other table mentions are writers, schema/index definitions or comments.
  # These literal writer kinds have no state reader. Unknown and dynamically
  # generated kinds remain retained unless explicitly audited into this list.
  @expirable_kinds ~w(
    adapter_down
    adapter_park_failed
    adapter_shutdown_cleanup_failed
    assignment_turn_stopped
    bubble_cause_missing
    bubble_marker_malformed
    cannot_proceed_disposer_transferred
    cli_compatibility_observed
    condition_fact_filed
    condition_fact_owner_unattributed
    decision_request_answered
    decision_request_asked
    decision_request_failed
    decision_request_opened
    decision_request_returned
    decision_request_superseded
    decision_request_withdrawn
    endpoint_not_provisioned
    harness_boot_identity_unknown
    harness_cleanup_failed
    harness_context_resident
    harness_health_auth_blocker
    harness_health_evidence_attached
    harness_health_incident_expired
    harness_health_incident_opened
    harness_health_incident_refused
    harness_health_incident_resolved
    harness_health_other_review
    harness_health_schema_migrated
    harness_launch_reboot_orphan
    harness_launch_unlaunched
    harness_turn_error
    identity_remove_failed
    idle_cleanup_main_unavailable
    idle_cleanup_parent_invalid
    idle_cleanup_prompt_claimed
    idle_cleanup_refused
    idle_cleanup_stale
    idle_cleanup_suppressed
    model_selection_attempt
    notice_batching_admission_bypassed
    notice_batching_lane_policy_applied
    notice_lane_policy_retired
    notice_prewrite_source_restored
    notice_source_policy_retired
    notice_source_submission_too_large
    override_discrepancy
    patrol_failure_lineage_exhausted
    patrol_failure_threshold
    patrol_terminal_classified
    pointer_fallback
    rail_episode_writer_unavailable
    rail_remedy
    rail_remedy_disposed
    rail_script
    rail_sweep
    rule_notice
    rule_notice_failed
    runtime_cleanup_unverified
    spinup
    stranded_turn_cleared
    supervision_blocked
    supervision_controller_restored
    supervision_controller_settlement_recovered
    supervision_controller_unavailable
    supervision_dispatch_failed
    supervision_evaluate_failed
    supervision_prod_denied
    supervision_stranded
    supervision_terminus
    supervision_wake_suppressed
    terminal_notice_recovery_admitted
    turn_finalize_fallback_failed
    turn_finalize_transaction_failed
    turn_task_crash
    turn_undeliverable
    user_alert_cleared
    waiver_granted
    waiver_revoked
    wake_class_policy_skew
    wake_condition_canceled
    wake_condition_fired
    wake_condition_scheduled
    wake_delivery_failed
    wake_digest_materialization_failed
    wake_digest_materialized
    wake_fallback_fired
    wake_retry_scheduled
    wake_unresolved
    wake_wait_recognized
    wake_wait_staged
  )
  @expirable_sql Enum.map_join(@expirable_kinds, ",", &"'#{&1}'")

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    days = Application.get_env(:tightbeam, :retention_days, 60)

    days =
      if is_integer(days) and days > 0 do
        days
      else
        Logger.error("invalid retention_days #{inspect(days)}; using 60 days")
        60
      end

    Process.send_after(self(), :trim, @boot_delay)
    {:ok, %{db: Keyword.get(opts, :db, DB), days: days, cursor: 0, cutoff: nil}}
  end

  @impl true
  def handle_info(:trim, state) do
    cutoff = state.cutoff || System.system_time(:millisecond) - state.days * @day_ms

    case trim_batch(state.db, state.cursor, cutoff) do
      {:ok, nil} ->
        Process.send_after(self(), :trim, @interval)
        {:noreply, %{state | cursor: 0, cutoff: nil}}

      {:ok, cursor} ->
        Process.send_after(self(), :trim, @yield_ms)
        {:noreply, %{state | cursor: cursor, cutoff: cutoff}}

      {:error, %DB.Overloaded{}} ->
        Logger.debug("database overloaded; background pass deferred")
        Process.send_after(self(), :trim, @interval)
        {:noreply, state}

      {:error, error} ->
        Logger.error("lifecycle retention failed: #{inspect(error)}")
        Process.send_after(self(), :trim, @interval)
        {:noreply, state}
    end
  end

  # Primary-key batches bound each transaction. Production ids and timestamps
  # are monotone: stop at a nondeleting batch whose last timestamp is current.
  # Recheck both kind and timestamp in the delete to preserve state and cutoff rows.
  defp trim_batch(db, cursor, cutoff) do
    DB.transaction(db, fn txn ->
      rows =
        Txn.q(
          txn,
          "SELECT id, ts FROM lifecycle_events WHERE id > ?1 ORDER BY id LIMIT ?2",
          [cursor, @batch]
        )

      case List.last(rows) do
        nil ->
          nil

        [last, last_ts] ->
          Txn.q(
            txn,
            "DELETE FROM lifecycle_events WHERE id > ?1 AND id <= ?2 AND ts < ?3 " <>
              "AND kind IN (#{@expirable_sql})",
            [cursor, last, cutoff]
          )

          deleted = Txn.changes(txn)
          if deleted == 0 and last_ts >= cutoff, do: nil, else: last
      end
    end)
  catch
    :exit, reason -> {:error, reason}
  end
end
