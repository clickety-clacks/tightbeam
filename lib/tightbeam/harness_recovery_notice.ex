defmodule Tightbeam.HarnessRecoveryNotice do
  @moduledoc false

  alias Tightbeam.{DB, EventLog, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.Store

  @origin "process:tightbeam"
  @migration "harness-recovery-notices/v1"
  @retryable_cancellations ~w(target_unresolvable consumer_unavailable target_retired)

  @ddl """
  CREATE TABLE harness_recovery_notices (
    holdId TEXT NOT NULL,
    ownerUserId TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('awaiting_main','attempting','delivered','canceled')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
    wakeId TEXT,
    turnSeq INTEGER,
    lastOutcome TEXT,
    canceledBy TEXT,
    prompt TEXT NOT NULL,
    failedRoutesJson TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL,
    PRIMARY KEY(holdId,ownerUserId),
    CHECK(state != 'attempting' OR wakeId IS NOT NULL),
    CHECK(state != 'delivered' OR turnSeq IS NOT NULL)
  );
  CREATE INDEX harness_recovery_notice_waiting
    ON harness_recovery_notices(state,ownerUserId,createdAt,holdId);
  CREATE INDEX harness_recovery_notice_wake
    ON harness_recovery_notices(wakeId);
  """

  @doc false
  def ensure_schema(db \\ DB) do
    case DB.transaction(db, fn txn ->
           case Txn.q(txn, "SELECT 1 FROM supervision_liveness_migrations WHERE migrationId=?1", [
                  @migration
                ]) do
             [[1]] ->
               :ok

             [] ->
               :ok = Txn.exec(txn, @ddl)

               Txn.q(
                 txn,
                 "INSERT INTO supervision_liveness_migrations(migrationId,appliedAt,affectedRows,cause,principal) VALUES(?1,?2,0,'release_upgrade',?3)",
                 [@migration, System.system_time(:millisecond), @origin]
               )
           end

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  @doc false
  def create_notice_in_txn(%Txn{} = txn, hold_id, owner_user_id, prompt, failed_routes, at)
      when is_binary(hold_id) and is_binary(owner_user_id) and is_binary(prompt) and
             is_list(failed_routes) and is_integer(at) do
    routes_json = JSON.encode!(failed_routes)

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO harness_recovery_notices
        (holdId,ownerUserId,state,attempts,wakeId,turnSeq,lastOutcome,canceledBy,
         prompt,failedRoutesJson,createdAt,updatedAt)
      VALUES(?1,?2,'awaiting_main',0,NULL,NULL,NULL,NULL,?3,?4,?5,?5)
      """,
      [hold_id, owner_user_id, prompt, routes_json, at]
    )

    created? = Txn.changes(txn) == 1

    case notice_in_txn(txn, hold_id, owner_user_id) do
      %{prompt: ^prompt, failed_routes_json: ^routes_json} ->
        :ok

      _ ->
        raise ArgumentError, "harness recovery notice identity conflict"
    end

    if created? do
      record(txn, "harness_recovery_notice_created", hold_id, owner_user_id, 0, nil, nil, at)
      attempt_in_txn(txn, hold_id, owner_user_id, at)
    end

    :ok
  end

  @doc false
  def admit_selected_recovery_in_txn(
        %Txn{} = txn,
        action,
        %{
          "hold_id" => hold_id,
          "resolved_at" => resolved_at,
          "failed_routes" => failed_routes,
          "prompt_template" => prompt_template
        },
        at,
        release?
      )
      when is_map(action) and is_binary(hold_id) and is_list(failed_routes) and
             is_binary(prompt_template) and is_integer(resolved_at) and is_integer(at) and
             is_boolean(release?) do
    checkpoint = Txn.handoff_checkpoint(txn)
    :ok = Txn.exec(txn, "SAVEPOINT harness_recovery_notice_admission")

    try do
      hold = resolved_hold_in_txn(txn, hold_id)

      episodes =
        hold_members_by_owner_in_txn(txn, hold_id)
        |> Enum.map(fn {owner_user_id, member_count} ->
          prompt =
            render_prompt(
              prompt_template,
              hold,
              hold_id,
              resolved_at,
              failed_routes,
              member_count
            )

          :ok = create_notice_in_txn(txn, hold_id, owner_user_id, prompt, failed_routes, at)
          %{"hold_id" => hold_id, "owner_user_id" => owner_user_id}
        end)

      Store.record(txn, action, "accepted", %{"notice_episodes" => episodes}, at)
      :ok = Txn.exec(txn, "RELEASE harness_recovery_notice_admission")
      :ok
    rescue
      error ->
        stacktrace = __STACKTRACE__
        rollback_notice_admission!(txn, checkpoint)

        if release? do
          reraise(error, stacktrace)
        else
          # The event and action predate this savepoint. Any failure in a
          # normal or other resolution leaves that action pending for replay;
          # lastError preserves why this attempt did not create a notice.
          Store.record(txn, action, "pending", action["result"], at, Exception.message(error))
          :ok
        end
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        rollback_notice_admission!(txn, checkpoint)

        if release? do
          :erlang.raise(kind, reason, stacktrace)
        else
          Store.record(txn, action, "pending", action["result"], at, inspect({kind, reason}))
          :ok
        end
    end
  end

  defp resolved_hold_in_txn(txn, hold_id) do
    case Txn.q(
           txn,
           "SELECT harness,host,failureClass,openedAt FROM harness_health_incidents WHERE id=?1",
           [hold_id]
         ) do
      [[harness, host, failure_class, opened_at]] ->
        %{
          harness: harness,
          host: host,
          failure_class: failure_class,
          opened_at: opened_at
        }

      _ ->
        raise ArgumentError, "harness recovery reaction references a missing hold"
    end
  end

  defp hold_members_by_owner_in_txn(txn, hold_id) do
    Txn.q(
      txn,
      """
      SELECT s.ownerUserId,COUNT(*)
      FROM harness_health_members m
      JOIN sessions s ON s.sessionKey=m.sessionKey
      WHERE m.incidentId=?1 AND s.ownerUserId IS NOT NULL
      GROUP BY s.ownerUserId
      ORDER BY s.ownerUserId
      """,
      [hold_id]
    )
    |> Enum.map(fn [owner_user_id, member_count] -> {owner_user_id, member_count} end)
  end

  defp render_prompt(template, hold, hold_id, resolved_at, failed_routes, member_count) do
    [
      {"@@harness@@", hold.harness},
      {"@@host@@", hold.host},
      {"@@failure_class@@", hold.failure_class},
      {"@@hold_id@@", hold_id},
      {"@@opened_at@@", to_string(hold.opened_at)},
      {"@@released_at@@", to_string(resolved_at)},
      {"@@resolved_at@@", to_string(resolved_at)},
      {"@@routes@@", JSON.encode!(failed_routes)},
      {"@@member_count@@", Integer.to_string(member_count)}
    ]
    |> Enum.reduce(template, fn {field, value}, prompt -> String.replace(prompt, field, value) end)
  end

  defp rollback_notice_admission!(txn, checkpoint) do
    :ok = Txn.exec(txn, "ROLLBACK TO harness_recovery_notice_admission")
    :ok = Txn.exec(txn, "RELEASE harness_recovery_notice_admission")
    :ok = Txn.restore_handoffs(txn, checkpoint)
  end

  @doc false
  def retry_owner_in_txn(%Txn{} = txn, owner_user_id, at)
      when is_binary(owner_user_id) and is_integer(at) do
    Txn.q(
      txn,
      "SELECT holdId FROM harness_recovery_notices WHERE ownerUserId=?1 AND state='awaiting_main' ORDER BY createdAt,holdId",
      [owner_user_id]
    )
    |> Enum.each(fn [hold_id] -> attempt_in_txn(txn, hold_id, owner_user_id, at) end)

    :ok
  end

  @doc false
  def retry_all_in_txn(%Txn{} = txn, at) when is_integer(at) do
    Txn.q(
      txn,
      "SELECT holdId,ownerUserId FROM harness_recovery_notices WHERE state='awaiting_main' ORDER BY createdAt,holdId,ownerUserId",
      []
    )
    |> Enum.each(fn [hold_id, owner_user_id] ->
      attempt_in_txn(txn, hold_id, owner_user_id, at)
    end)

    :ok
  end

  @doc false
  def retry_owner(db \\ DB, owner_user_id, at \\ System.system_time(:millisecond)) do
    transaction!(db, &retry_owner_in_txn(&1, owner_user_id, at))
  end

  @doc false
  def retry_all(db \\ DB, at \\ System.system_time(:millisecond)) do
    transaction!(db, &retry_all_in_txn(&1, at))
  end

  @doc false
  def attempt_in_txn(%Txn{} = txn, hold_id, owner_user_id, at)
      when is_binary(hold_id) and is_binary(owner_user_id) and is_integer(at) do
    case notice_in_txn(txn, hold_id, owner_user_id) do
      %{state: "awaiting_main"} = notice ->
        case owner_main_in_txn(txn, owner_user_id) do
          nil ->
            Txn.q(
              txn,
              "UPDATE harness_recovery_notices SET lastOutcome='no_owner_main',updatedAt=?3 WHERE holdId=?1 AND ownerUserId=?2 AND state='awaiting_main'",
              [hold_id, owner_user_id, at]
            )

            record(
              txn,
              "harness_recovery_notice_non_delivered",
              hold_id,
              owner_user_id,
              notice.attempts,
              nil,
              nil,
              at,
              "no_owner_main"
            )

          main_key ->
            start_attempt_in_txn(txn, notice, main_key, at)
        end

      _ ->
        :ok
    end

    :ok
  end

  @doc false
  def settle_turn_in_txn(%Txn{} = txn, turn_seq, terminal_state, at)
      when is_integer(turn_seq) and is_binary(terminal_state) and is_integer(at) do
    attempts =
      Txn.q(
        txn,
        """
        SELECT n.holdId,n.ownerUserId,n.attempts,n.wakeId,n.state
        FROM harness_recovery_notices n
        JOIN wakes w ON w.wakeId=n.wakeId AND w.deliveredTurnSeq=?1
        JOIN turns t ON t.seq=w.deliveredTurnSeq
        JOIN sessions s ON s.sessionKey=t.sessionKey
          AND s.ownerUserId=n.ownerUserId AND s.kind='main'
        WHERE t.status=?2 AND t.sessionKey=w.sessionKey
          AND n.state IN ('attempting','awaiting_main')
        ORDER BY n.holdId,n.ownerUserId
        """,
        [turn_seq, terminal_state]
      )

    Enum.each(attempts, fn [hold_id, owner_user_id, attempt, wake_id, _state] ->
      if terminal_state == "delivered" do
        Txn.q(
          txn,
          "UPDATE harness_recovery_notices SET state='delivered',turnSeq=?4,lastOutcome=NULL,canceledBy=NULL,updatedAt=?5 WHERE holdId=?1 AND ownerUserId=?2 AND wakeId=?3 AND state IN ('attempting','awaiting_main')",
          [hold_id, owner_user_id, wake_id, turn_seq, at]
        )

        record(
          txn,
          "harness_recovery_notice_delivered",
          hold_id,
          owner_user_id,
          attempt,
          wake_id,
          turn_seq,
          at
        )
      else
        Txn.q(
          txn,
          "UPDATE harness_recovery_notices SET state='awaiting_main',turnSeq=?4,lastOutcome=?5,updatedAt=?6 WHERE holdId=?1 AND ownerUserId=?2 AND wakeId=?3 AND state IN ('attempting','awaiting_main')",
          [hold_id, owner_user_id, wake_id, turn_seq, terminal_state, at]
        )

        record(
          txn,
          "harness_recovery_notice_non_delivered",
          hold_id,
          owner_user_id,
          attempt,
          wake_id,
          turn_seq,
          at,
          terminal_state
        )
      end
    end)

    record_late_deliveries_in_txn(txn, turn_seq, terminal_state, at)

    if terminal_state == "delivered" do
      case Txn.q(
             txn,
             "SELECT s.ownerUserId FROM turns t JOIN sessions s ON s.sessionKey=t.sessionKey WHERE t.seq=?1 AND t.status='delivered' AND s.kind='main' AND s.state='active'",
             [turn_seq]
           ) do
        [[owner_user_id]] -> retry_owner_after_turn_in_txn(txn, owner_user_id, turn_seq, at)
        [] -> :ok
        _ -> raise ArgumentError, "a Main turn resolved to multiple owners"
      end
    end

    :ok
  end

  @doc false
  def settle_wake_cancellation_in_txn(%Txn{} = txn, wake_id, canceller, reason, at)
      when is_binary(wake_id) and is_map(canceller) and is_binary(reason) and is_integer(at) do
    canceller_json = JSON.encode!(canceller)

    case Txn.q(
           txn,
           "SELECT holdId,ownerUserId,attempts,turnSeq,state FROM harness_recovery_notices WHERE wakeId=?1",
           [wake_id]
         ) do
      [[hold_id, owner_user_id, attempt, turn_seq, "attempting"]] ->
        if reason in @retryable_cancellations do
          Txn.q(
            txn,
            "UPDATE harness_recovery_notices SET state='awaiting_main',lastOutcome=?2,canceledBy=?3,updatedAt=?4 WHERE wakeId=?1 AND state='attempting'",
            [wake_id, reason, canceller_json, at]
          )

          record(
            txn,
            "harness_recovery_notice_non_delivered",
            hold_id,
            owner_user_id,
            attempt,
            wake_id,
            turn_seq,
            at,
            reason,
            canceller
          )
        else
          Txn.q(
            txn,
            "UPDATE harness_recovery_notices SET state='canceled',lastOutcome=?2,canceledBy=?3,updatedAt=?4 WHERE wakeId=?1 AND state='attempting'",
            [wake_id, reason, canceller_json, at]
          )

          record(
            txn,
            "harness_recovery_notice_canceled",
            hold_id,
            owner_user_id,
            attempt,
            wake_id,
            turn_seq,
            at,
            reason,
            canceller
          )
        end

      _ ->
        :ok
    end
  end

  @doc false
  def sync_attempt_turn_in_txn(%Txn{} = txn, wake_id)
      when is_binary(wake_id) do
    case Wakes.get_in_txn(txn, wake_id) do
      %{delivered_turn_seq: turn_seq} when is_integer(turn_seq) ->
        at = System.system_time(:millisecond)

        case Txn.q(
               txn,
               "SELECT holdId,ownerUserId,attempts,state,turnSeq,lastOutcome,canceledBy FROM harness_recovery_notices WHERE wakeId=?1",
               [wake_id]
             ) do
          [[_hold_id, _owner_user_id, _attempt, "canceled", _turn_seq, _reason, _canceller]] ->
            :ok

          [[_hold_id, _owner_user_id, _attempt, state, nil, _reason, _canceller]]
          when state in ["attempting", "awaiting_main"] ->
            Txn.q(
              txn,
              "UPDATE harness_recovery_notices SET turnSeq=?2,updatedAt=?3 WHERE wakeId=?1 AND state=?4 AND turnSeq IS NULL",
              [wake_id, turn_seq, at, state]
            )

          _ ->
            :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  @doc false
  def notice_in_txn(%Txn{} = txn, hold_id, owner_user_id) do
    case Txn.q(
           txn,
           "SELECT holdId,ownerUserId,state,attempts,wakeId,turnSeq,lastOutcome,canceledBy,prompt,failedRoutesJson,createdAt,updatedAt FROM harness_recovery_notices WHERE holdId=?1 AND ownerUserId=?2",
           [hold_id, owner_user_id]
         ) do
      [row] ->
        Map.new(
          Enum.zip(
            ~w(hold_id owner_user_id state attempts wake_id turn_seq last_outcome canceled_by prompt failed_routes_json created_at updated_at)a,
            row
          )
        )

      [] ->
        nil
    end
  end

  defp start_attempt_in_txn(txn, notice, main_key, at) do
    attempt = notice.attempts + 1
    wake_id = "harness-recovery:#{notice.hold_id}:#{notice.owner_user_id}:#{attempt}"

    wake =
      Wakes.schedule_in_txn(txn, %{
        wake_id: wake_id,
        session_key: main_key,
        owner_user_id: notice.owner_user_id,
        origin: @origin,
        prompt: notice.prompt,
        due_at: at,
        class: "blocker"
      })

    Txn.q(
      txn,
      "UPDATE harness_recovery_notices SET state='attempting',attempts=?3,wakeId=?4,turnSeq=NULL,lastOutcome=NULL,canceledBy=NULL,updatedAt=?5 WHERE holdId=?1 AND ownerUserId=?2 AND state='awaiting_main'",
      [notice.hold_id, notice.owner_user_id, attempt, wake.wake_id, at]
    )

    record(
      txn,
      "harness_recovery_notice_attempt_started",
      notice.hold_id,
      notice.owner_user_id,
      attempt,
      wake.wake_id,
      nil,
      at
    )
  end

  defp owner_main_in_txn(txn, owner_user_id) do
    case Txn.q(
           txn,
           "SELECT sessionKey FROM sessions WHERE kind='main' AND state='active' AND ownerUserId=?1 ORDER BY sessionKey LIMIT 1",
           [owner_user_id]
         ) do
      [[session_key]] -> session_key
      [] -> nil
    end
  end

  defp retry_owner_after_turn_in_txn(txn, owner_user_id, turn_seq, at) do
    Txn.q(
      txn,
      """
      SELECT n.holdId
      FROM harness_recovery_notices n
      WHERE n.ownerUserId=?1 AND n.state='awaiting_main'
        AND NOT EXISTS (
          SELECT 1 FROM harness_recovery_notices carried
          JOIN wakes w ON w.wakeId=carried.wakeId
          WHERE carried.holdId=n.holdId AND carried.ownerUserId=n.ownerUserId
            AND w.deliveredTurnSeq=?2
        )
      ORDER BY n.createdAt,n.holdId
      """,
      [owner_user_id, turn_seq]
    )
    |> Enum.each(fn [hold_id] -> attempt_in_txn(txn, hold_id, owner_user_id, at) end)

    :ok
  end

  defp record_late_deliveries_in_txn(txn, turn_seq, terminal_state, at) do
    Txn.q(
      txn,
      """
      SELECT n.holdId,n.ownerUserId,n.attempts,n.wakeId,n.lastOutcome,n.canceledBy,n.turnSeq
      FROM harness_recovery_notices n
      JOIN wakes w ON w.wakeId=n.wakeId AND w.deliveredTurnSeq=?1
      JOIN turns t ON t.seq=w.deliveredTurnSeq AND t.sessionKey=w.sessionKey
      JOIN sessions s ON s.sessionKey=t.sessionKey
        AND s.ownerUserId=n.ownerUserId AND s.kind='main'
      WHERE n.state='canceled' AND (n.turnSeq IS NULL OR n.turnSeq=?1)
        AND t.status=?2
      ORDER BY n.holdId,n.ownerUserId
      """,
      [turn_seq, terminal_state]
    )
    |> Enum.each(fn [
                      hold_id,
                      owner_user_id,
                      attempt,
                      wake_id,
                      reason,
                      canceller_json,
                      current_turn_seq
                    ] ->
      if is_nil(current_turn_seq) do
        Txn.q(
          txn,
          "UPDATE harness_recovery_notices SET turnSeq=?3,updatedAt=?4 WHERE holdId=?1 AND ownerUserId=?2 AND state='canceled' AND turnSeq IS NULL",
          [hold_id, owner_user_id, turn_seq, at]
        )
      end

      already_recorded? =
        Txn.q(
          txn,
          "SELECT 1 FROM lifecycle_events WHERE kind='harness_recovery_notice_late_delivery' AND subject=?1 AND json_extract(detail,'$.wake_id')=?2 AND json_extract(detail,'$.turn_seq')=?3 LIMIT 1",
          [hold_id, wake_id, turn_seq]
        ) != []

      if terminal_state == "delivered" and not already_recorded? do
        record(
          txn,
          "harness_recovery_notice_late_delivery",
          hold_id,
          owner_user_id,
          attempt,
          wake_id,
          turn_seq,
          at,
          reason,
          if(is_binary(canceller_json), do: JSON.decode!(canceller_json), else: nil)
        )
      end
    end)

    :ok
  end

  defp record(
         txn,
         kind,
         hold_id,
         owner_user_id,
         attempt,
         wake_id,
         turn_seq,
         _at,
         outcome \\ nil,
         canceled_by \\ nil
       ) do
    detail =
      JSON.encode!(%{
        "principal" => @origin,
        "hold_id" => hold_id,
        "owner_user_id" => owner_user_id,
        "attempt" => attempt,
        "wake_id" => wake_id,
        "turn_seq" => turn_seq,
        "outcome" => outcome,
        "canceled_by" => canceled_by
      })

    EventLog.lifecycle_in_txn(txn, kind, hold_id, detail)
    :ok
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
