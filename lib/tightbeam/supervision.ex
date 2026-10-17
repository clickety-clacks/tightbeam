defmodule Tightbeam.Supervision do
  @moduledoc """
  Assignment inactivity deadlines and their ordinary notice climb.

  The event scheduler owns timing. This module only writes durable wake rows
  and consumes the two internal wake kinds used by an inactivity episode.
  Delivery remains the ordinary wake and notice-batching path.
  """

  alias Tightbeam.{DB, EventLog, Org, Wakes}
  alias Tightbeam.DB.Txn

  require Logger

  @deadline_consumer "assignment_inactivity_deadline"
  @climb_consumer "assignment_inactivity_climb"
  @deadline_ref "assignment-inactivity-deadline-v1:"
  @episode_ref "assignment-inactivity-episode-v1:"
  @default_interval_ms 1_000

  # Retained only for the exact predecessor-shape migration in Schema. The
  # current runtime keeps no supervision production tables.
  @watermarks_ddl """
  CREATE TABLE IF NOT EXISTS supervision_watermarks (
    sessionKey TEXT NOT NULL,
    assignmentId TEXT NOT NULL DEFAULT '',
    lastEvaluatedTerminal INTEGER NOT NULL,
    pendingBranch TEXT CHECK (pendingBranch IN ('prod','escalation','terminus')),
    pendingAssignment TEXT,
    pendingK INTEGER NULL,
    pendingN INTEGER NULL,
    PRIMARY KEY (sessionKey, assignmentId)
  )
  """

  @doc false
  def ensure_schema(_db), do: :ok

  @doc false
  def watermarks_ddl, do: @watermarks_ddl

  @doc false
  def assignment_opened_in_txn(%Txn{} = txn, assignment_id, opened_at, interval_ms)
      when is_binary(assignment_id) and is_integer(opened_at) and is_integer(interval_ms) and
             interval_ms > 0 do
    isolated_side_task(txn, assignment_id, "open", fn ->
      with [[holder, work_item_id, "open"]] <-
             Txn.q(
               txn,
               "SELECT holderKey,workItemId,state FROM assignments WHERE id=?1",
               [assignment_id]
             ),
           true <- is_binary(holder) and holder != "" do
        deadline =
          schedule_deadline_in_txn(
            txn,
            assignment_id,
            holder,
            work_item_id,
            opened_at,
            interval_ms
          )

        cancel_assignment_sources_in_txn(txn, assignment_id, {:replacement, deadline.wake_id})
        :ok
      else
        _ ->
          Logger.warning(
            "assignment inactivity deadline unavailable for #{inspect(assignment_id)}"
          )

          :ok
      end
    end)
  end

  def assignment_opened_in_txn(_txn, assignment_id, _opened_at, _interval_ms) do
    Logger.warning("invalid assignment inactivity deadline input for #{inspect(assignment_id)}")
    :ok
  end

  @doc false
  def assignment_closed_in_txn(%Txn{} = txn, assignment_id)
      when is_binary(assignment_id) do
    isolated_side_task(txn, assignment_id, "close", fn ->
      cancel_assignment_sources_in_txn(txn, assignment_id, :disposed)
      :ok
    end)
  end

  def assignment_closed_in_txn(_txn, _assignment_id), do: :ok

  @doc false
  def activity_in_txn(%Txn{} = txn, assignment_id, actor_session_key, at)
      when is_binary(assignment_id) and is_binary(actor_session_key) and is_integer(at) do
    isolated_side_task(txn, assignment_id, "activity", fn ->
      case Txn.q(
             txn,
             "SELECT holderKey,workItemId,openedAt,state FROM assignments WHERE id=?1",
             [assignment_id]
           ) do
        [[^actor_session_key, work_item_id, opened_at, "open"]]
        when is_integer(opened_at) ->
          interval_ms = current_interval_in_txn(txn, assignment_id)
          activity_start = activity_start_in_txn(txn, assignment_id, opened_at)

          last_activity =
            current_activity_time_in_txn(txn, assignment_id, actor_session_key, activity_start)

          effective_at = max(activity_start, max(last_activity, at))

          deadline =
            schedule_deadline_in_txn(
              txn,
              assignment_id,
              actor_session_key,
              work_item_id,
              effective_at,
              interval_ms
            )

          cancel_assignment_sources_in_txn(txn, assignment_id, {:replacement, deadline.wake_id})
          :reset

        _ ->
          :ignored
      end
    end)
  end

  def activity_in_txn(_txn, _assignment_id, _actor_session_key, _at), do: :ignored

  @doc false
  def migrate_open_assignments(db, default_interval_ms \\ @default_interval_ms)
      when is_integer(default_interval_ms) and default_interval_ms > 0 do
    case DB.migration_transaction(db, :assignment_inactivity_deadlines_v1, [], [], fn txn ->
           rows =
             Txn.q(
               txn,
               "SELECT id,holderKey,workItemId,openedAt FROM assignments WHERE state='open' ORDER BY openedAt,id"
             )

           Enum.each(rows, fn row ->
             case row do
               [assignment_id, holder, work_item_id, opened_at]
               when is_binary(assignment_id) and is_binary(holder) and is_integer(opened_at) ->
                 isolated_side_task(txn, assignment_id, "migration", fn ->
                   unless pending_deadline_in_txn?(txn, assignment_id) do
                     interval_ms =
                       interval_from_entitlement_in_txn(txn, assignment_id, default_interval_ms)

                     activity_start = activity_start_in_txn(txn, assignment_id, opened_at)

                     last_activity =
                       current_activity_time_in_txn(txn, assignment_id, holder, activity_start)

                     deadline =
                       schedule_deadline_in_txn(
                         txn,
                         assignment_id,
                         holder,
                         work_item_id,
                         max(opened_at, last_activity),
                         interval_ms
                       )

                     cancel_assignment_sources_in_txn(
                       txn,
                       assignment_id,
                       {:replacement, deadline.wake_id}
                     )
                   end

                   :ok
                 end)

               _ ->
                 Logger.warning("skipping malformed open assignment during inactivity migration")
             end
           end)

           cancel_legacy_controllers_in_txn(txn)

           :ok
         end) do
      {:ok, :ok} ->
        :ok

      {:error, error} ->
        Logger.error("assignment inactivity migration failed: #{Exception.message(error)}")
        {:error, error}
    end
  end

  @doc false
  def deadline(db, wake) when is_map(wake) do
    with {:ok, payload} <- decode_payload(wake, @deadline_consumer),
         {:ok, assignment_id, interval_ms, activity_at} <- deadline_payload(payload, wake) do
      DB.transaction(db, fn txn ->
        consume_deadline_in_txn(txn, wake, assignment_id, interval_ms, activity_at)
      end)
    else
      {:error, reason} ->
        Logger.warning("discarding malformed assignment inactivity deadline: #{inspect(reason)}")
        discard_internal_wake(db, wake, @deadline_consumer, reason)
    end
  end

  def deadline(_db, wake) do
    Logger.warning("discarding malformed assignment inactivity deadline: #{inspect(wake)}")
    :ok
  end

  @doc false
  def climb(db, wake) when is_map(wake) do
    with {:ok, payload} <- decode_payload(wake, @climb_consumer),
         {:ok, assignment_id, episode_ref, origin_holder, rung, interval_ms, previous_wake_id,
          visited} <- climb_payload(payload, wake) do
      DB.transaction(db, fn txn ->
        consume_climb_in_txn(
          txn,
          wake,
          assignment_id,
          episode_ref,
          origin_holder,
          rung,
          interval_ms,
          previous_wake_id,
          visited
        )
      end)
    else
      {:error, reason} ->
        Logger.warning("discarding malformed assignment inactivity climb: #{inspect(reason)}")
        discard_internal_wake(db, wake, @climb_consumer, reason)
    end
  end

  def climb(_db, wake) do
    Logger.warning("discarding malformed assignment inactivity climb: #{inspect(wake)}")
    :ok
  end

  @doc false
  def inactivity_deadline_trigger_in_txn(%Txn{} = txn, {:assignment, assignment_id})
      when is_binary(assignment_id) do
    case Txn.q(
           txn,
           "SELECT wakeId FROM wakes WHERE assignmentId=?1 AND consumer IN (?2,?3) AND state='pending' ORDER BY dueAt,wakeId LIMIT 1",
           [assignment_id, @deadline_consumer, @climb_consumer]
         ) do
      [[wake_id]] when is_binary(wake_id) -> {:ok, %{kind: "pending_wake", id: wake_id}}
      _ -> :none
    end
  rescue
    error ->
      Logger.warning(
        "assignment deadline unavailable for #{inspect(assignment_id)}: #{Exception.message(error)}"
      )

      :none
  end

  def inactivity_deadline_trigger_in_txn(%Txn{} = txn, {:work_item, work_item_id})
      when is_binary(work_item_id) do
    case Txn.q(
           txn,
           """
           SELECT 1 FROM work_items wi
           JOIN wakes w ON w.wakeId=wi.routingWakeId OR w.wakeId=wi.slateWakeId
           WHERE wi.id=?1 AND wi.state='open' AND w.state='pending' LIMIT 1
           """,
           [work_item_id]
         ) do
      [[1]] ->
        {:ok, %{kind: "routing_bracket", id: work_item_id}}

      _ ->
        Txn.q(
          txn,
          "SELECT w.wakeId FROM assignments a JOIN wakes w ON w.assignmentId=a.id WHERE a.workItemId=?1 AND a.state='open' AND w.consumer IN (?2,?3) AND w.state='pending' ORDER BY a.openedAt,a.id,w.dueAt,w.wakeId LIMIT 1",
          [work_item_id, @deadline_consumer, @climb_consumer]
        )
        |> case do
          [[wake_id]] when is_binary(wake_id) -> {:ok, %{kind: "pending_wake", id: wake_id}}
          _ -> :none
        end
    end
  rescue
    error ->
      Logger.warning(
        "work item deadline unavailable for #{inspect(work_item_id)}: #{Exception.message(error)}"
      )

      :none
  end

  def inactivity_deadline_trigger_in_txn(_txn, _primary), do: :none

  @doc false
  def ladder_target(db_or_txn, holder_key, rung)
      when is_binary(holder_key) and is_integer(rung) and rung > 0 do
    case query(
           db_or_txn,
           "SELECT ownerUserId, #{Org.current_parent_sql("sessions")} FROM sessions WHERE sessionKey=?1",
           [holder_key]
         ) do
      [[owner, spawned_by]] ->
        chain = lineage(db_or_txn, spawned_by, MapSet.new([holder_key]), [])

        case Enum.at(chain, rung - 1) do
          nil -> active_personal_key(db_or_txn, owner)
          target -> target
        end

      [] ->
        Logger.warning("assignment notice holder session missing for #{inspect(holder_key)}")
        nil

      other ->
        Logger.warning(
          "assignment notice holder session unreadable for #{inspect(holder_key)}: #{inspect(other)}"
        )

        nil
    end
  rescue
    error ->
      Logger.warning("assignment notice lineage unavailable: #{Exception.message(error)}")
      nil
  catch
    kind, reason ->
      Logger.warning("assignment notice lineage unavailable: #{inspect({kind, reason})}")
      nil
  end

  def ladder_target(_db_or_txn, _holder_key, _rung), do: nil

  defp consume_deadline_in_txn(txn, wake, assignment_id, interval_ms, activity_at) do
    now = now()

    case Txn.q(
           txn,
           "SELECT state,dueAt,sessionKey,work_item_id FROM wakes WHERE wakeId=?1 AND consumer=?2 AND assignmentId=?3",
           [wake.wake_id, @deadline_consumer, assignment_id]
         ) do
      [["pending", due_at, holder, work_item_id]] when is_integer(due_at) and due_at <= now ->
        case Txn.q(
               txn,
               "SELECT holderKey,workItemId,subject,state,openedAt FROM assignments WHERE id=?1",
               [assignment_id]
             ) do
          [[^holder, assignment_work_item_id, subject, "open", opened_at]]
          when is_integer(opened_at) ->
            if assignment_work_item_id == work_item_id do
              activity_start = activity_start_in_txn(txn, assignment_id, opened_at)

              latest_activity =
                current_activity_time_in_txn(txn, assignment_id, holder, activity_start)

              cond do
                latest_activity > activity_at ->
                  replacement =
                    schedule_deadline_in_txn(
                      txn,
                      assignment_id,
                      holder,
                      work_item_id,
                      latest_activity,
                      interval_ms
                    )

                  fire_internal_in_txn(txn, wake.wake_id, @deadline_consumer, now)

                  cancel_assignment_sources_in_txn(
                    txn,
                    assignment_id,
                    {:replacement, replacement.wake_id}
                  )

                fire_internal_in_txn(txn, wake.wake_id, @deadline_consumer, now) ->
                  begin_episode_in_txn(
                    txn,
                    assignment_id,
                    subject,
                    holder,
                    work_item_id,
                    interval_ms,
                    latest_activity,
                    now
                  )

                true ->
                  :ok
              end
            else
              fire_internal_in_txn(txn, wake.wake_id, @deadline_consumer, now)
            end

          _ ->
            fire_internal_in_txn(txn, wake.wake_id, @deadline_consumer, now)
        end

      [["pending", due_at, _holder, _work_item_id]] when is_integer(due_at) and due_at > now ->
        {:deferred, :deadline_moved}

      _ ->
        :ok
    end
  end

  defp begin_episode_in_txn(
         txn,
         assignment_id,
         subject,
         holder,
         work_item_id,
         interval_ms,
         activity_at,
         now
       ) do
    episode_ref = @episode_ref <> Tightbeam.Id.uuid4()

    notice =
      schedule_notice_in_txn(
        txn,
        assignment_id,
        subject,
        holder,
        activity_at,
        holder,
        work_item_id,
        episode_ref,
        now
      )

    schedule_climb_in_txn(
      txn,
      assignment_id,
      holder,
      work_item_id,
      episode_ref,
      1,
      interval_ms,
      notice.wake_id,
      [holder],
      now + interval_ms
    )

    :ok
  end

  defp consume_climb_in_txn(
         txn,
         wake,
         assignment_id,
         episode_ref,
         origin_holder,
         rung,
         interval_ms,
         previous_wake_id,
         visited
       ) do
    now = now()

    case Txn.q(
           txn,
           "SELECT state,dueAt,sessionKey FROM wakes WHERE wakeId=?1 AND consumer=?2 AND assignmentId=?3 AND obligationRef=?4",
           [wake.wake_id, @climb_consumer, assignment_id, episode_ref]
         ) do
      [["pending", due_at, ^origin_holder]] when is_integer(due_at) and due_at <= now ->
        case Txn.q(txn, "SELECT holderKey,state,workItemId FROM assignments WHERE id=?1", [
               assignment_id
             ]) do
          [[^origin_holder, "open", work_item_id]] ->
            case ladder_target(txn, origin_holder, rung) do
              target when is_binary(target) ->
                if target in visited do
                  fire_internal_in_txn(txn, wake.wake_id, @climb_consumer, now)
                  :ok
                else
                  case next_notice_in_txn(
                         txn,
                         previous_wake_id,
                         target,
                         assignment_id,
                         work_item_id,
                         episode_ref,
                         now
                       ) do
                    {:ok, notice_id} ->
                      fire_internal_in_txn(txn, wake.wake_id, @climb_consumer, now)

                      schedule_climb_in_txn(
                        txn,
                        assignment_id,
                        origin_holder,
                        work_item_id,
                        episode_ref,
                        rung + 1,
                        interval_ms,
                        notice_id,
                        [target | visited],
                        now + interval_ms
                      )

                      :ok

                    {:error, reason} ->
                      Logger.warning(
                        "assignment notice climb deferred for #{assignment_id}: #{inspect(reason)}"
                      )

                      fire_internal_in_txn(txn, wake.wake_id, @climb_consumer, now)
                      :ok
                  end
                end

              _ ->
                fire_internal_in_txn(txn, wake.wake_id, @climb_consumer, now)
                :ok
            end

          _ ->
            fire_internal_in_txn(txn, wake.wake_id, @climb_consumer, now)
            :ok
        end

      [["pending", due_at, ^origin_holder]] when is_integer(due_at) and due_at > now ->
        {:deferred, :climb_moved}

      _ ->
        :ok
    end
  end

  defp next_notice_in_txn(
         txn,
         previous_wake_id,
         target,
         assignment_id,
         work_item_id,
         episode_ref,
         now
       ) do
    case Txn.q(
           txn,
           "SELECT state,deliveredTurnSeq,prompt FROM wakes WHERE wakeId=?1 AND consumer='prompt' AND assignmentId=?2 AND obligationRef=?3",
           [previous_wake_id, assignment_id, episode_ref]
         ) do
      [["pending", nil, _prompt]] ->
        case Wakes.readdress_pending_in_txn(txn, previous_wake_id, target) do
          {:ok, %{wake_id: ^previous_wake_id}} -> {:ok, previous_wake_id}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:invalid_readdress_result, other}}
        end

      [["fired", delivered_turn_seq, prompt]]
      when is_integer(delivered_turn_seq) and is_binary(prompt) ->
        notice =
          schedule_notice_with_prompt_in_txn(
            txn,
            assignment_id,
            target,
            work_item_id,
            episode_ref,
            now,
            prompt
          )

        {:ok, notice.wake_id}

      [[state, nil, prompt]] when state in ["fired", "canceled"] and is_binary(prompt) ->
        case Txn.q(
               txn,
               "SELECT reasonKind FROM wake_cancellations WHERE wakeId=?1 ORDER BY canceledAt DESC LIMIT 1",
               [previous_wake_id]
             ) do
          [[reason]] when reason in ["target_unresolvable", "consumer_unavailable"] ->
            notice =
              schedule_notice_with_prompt_in_txn(
                txn,
                assignment_id,
                target,
                work_item_id,
                episode_ref,
                now,
                prompt
              )

            {:ok, notice.wake_id}

          _ ->
            {:error, :previous_notice_fired_without_delivery_or_undeliverable_record}
        end

      [] ->
        Logger.warning(
          "assignment notice history missing for #{previous_wake_id}; stopping this climb"
        )

        {:error, :previous_notice_missing}

      _ ->
        {:error, :previous_notice_not_pending_or_terminal}
    end
  end

  defp schedule_deadline_in_txn(
         txn,
         assignment_id,
         holder,
         work_item_id,
         activity_at,
         interval_ms
       ) do
    due_at = activity_at + interval_ms

    reusable_deadline_in_txn(
      txn,
      assignment_id,
      holder,
      work_item_id,
      activity_at,
      interval_ms,
      due_at
    ) ||
      Wakes.schedule_in_txn(txn, %{
        session_key: holder,
        origin: "process:tightbeam",
        consumer: @deadline_consumer,
        prompt:
          JSON.encode!(%{
            "version" => 1,
            "assignmentId" => assignment_id,
            "activityAt" => activity_at,
            "intervalMs" => interval_ms
          }),
        due_at: due_at,
        assignment_id: assignment_id,
        work_item_id: work_item_id,
        obligation_ref: @deadline_ref <> assignment_id
      })
  end

  defp reusable_deadline_in_txn(
         txn,
         assignment_id,
         holder,
         work_item_id,
         activity_at,
         interval_ms,
         due_at
       ) do
    Txn.q(
      txn,
      "SELECT wakeId,prompt,sessionKey,work_item_id,dueAt FROM wakes WHERE assignmentId=?1 AND consumer=?2 AND state='pending' ORDER BY createdAt DESC,wakeId DESC LIMIT 1",
      [assignment_id, @deadline_consumer]
    )
    |> Enum.find_value(fn
      [wake_id, prompt, ^holder, ^work_item_id, ^due_at]
      when is_binary(wake_id) and is_binary(prompt) ->
        case decode_payload(%{consumer: @deadline_consumer, prompt: prompt}, @deadline_consumer) do
          {:ok,
           %{
             "assignmentId" => ^assignment_id,
             "intervalMs" => ^interval_ms,
             "activityAt" => ^activity_at
           }} ->
            Wakes.get_in_txn(txn, wake_id)

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  defp schedule_notice_in_txn(
         txn,
         assignment_id,
         subject,
         holder,
         activity_at,
         target,
         work_item_id,
         episode_ref,
         due_at
       ) do
    schedule_notice_with_prompt_in_txn(
      txn,
      assignment_id,
      target,
      work_item_id,
      episode_ref,
      due_at,
      inactivity_notice_text(assignment_id, subject, holder, activity_at)
    )
  end

  defp schedule_notice_with_prompt_in_txn(
         txn,
         assignment_id,
         target,
         work_item_id,
         episode_ref,
         due_at,
         prompt
       ) do
    Wakes.schedule_in_txn(txn, %{
      session_key: target,
      origin: "process:tightbeam",
      consumer: "prompt",
      prompt: prompt,
      class: "fyi",
      due_at: due_at,
      assignment_id: assignment_id,
      work_item_id: work_item_id,
      obligation_ref: episode_ref
    })
  end

  defp inactivity_notice_text(assignment_id, subject, holder, activity_at) do
    subject = if is_binary(subject) and subject != "", do: subject, else: "(subject unavailable)"
    holder = if is_binary(holder) and holder != "", do: holder, else: "(holder unavailable)"

    "Assignment #{assignment_id} (#{subject}), held by #{holder}, has had no recorded activity since #{activity_at} ms. " <>
      "Record progress, ask for a decision, or complete it."
  end

  defp schedule_climb_in_txn(
         txn,
         assignment_id,
         origin_holder,
         work_item_id,
         episode_ref,
         rung,
         interval_ms,
         previous_wake_id,
         visited,
         due_at
       ) do
    Wakes.schedule_in_txn(txn, %{
      session_key: origin_holder,
      origin: "process:tightbeam",
      consumer: @climb_consumer,
      prompt:
        JSON.encode!(%{
          "version" => 1,
          "assignmentId" => assignment_id,
          "episodeRef" => episode_ref,
          "originHolder" => origin_holder,
          "rung" => rung,
          "intervalMs" => interval_ms,
          "previousWakeId" => previous_wake_id,
          "visited" => visited
        }),
      due_at: due_at,
      assignment_id: assignment_id,
      work_item_id: work_item_id,
      obligation_ref: episode_ref
    })
  end

  defp cancel_assignment_sources_in_txn(txn, assignment_id, disposition) do
    replacement_id =
      case disposition do
        {:replacement, id} -> id
        :disposed -> nil
      end

    rows =
      Txn.q(
        txn,
        """
        SELECT wakeId FROM wakes
        WHERE assignmentId=?1 AND state='pending'
          AND (consumer IN (?2,?3) OR obligationRef LIKE ?4)
          AND (?5 IS NULL OR wakeId<>?5)
        ORDER BY createdAt,wakeId
        """,
        [assignment_id, @deadline_consumer, @climb_consumer, @episode_ref <> "%", replacement_id]
      )

    Enum.each(rows, fn
      [wake_id] when is_binary(wake_id) ->
        command =
          case disposition do
            :disposed ->
              %{
                wake_id: wake_id,
                requester: %{kind: "process", id: "tightbeam:assignments"},
                reason_kind: "obligation_disposed",
                causal_source: %{kind: "assignment_transition", id: assignment_id},
                outcome: %{
                  kind: "disposition",
                  disposition_kind: "assignment_transition",
                  disposition_id: assignment_id
                }
              }

            {:replacement, replacement_id} ->
              %{
                wake_id: wake_id,
                requester: %{kind: "process", id: "tightbeam:assignments"},
                reason_kind: "superseded",
                causal_source: %{kind: "wake", id: replacement_id},
                outcome: %{kind: "replacement", replacement_wake_id: replacement_id}
              }
          end

        unless Wakes.cancel_in_txn(txn, command) do
          Logger.warning("assignment inactivity wake #{wake_id} could not be retracted")
        end

      _ ->
        Logger.warning("skipping malformed assignment inactivity wake reference")
    end)

    :ok
  end

  defp fire_internal_in_txn(txn, wake_id, consumer, at) do
    Txn.q(
      txn,
      "UPDATE wakes SET state='fired',firedAt=COALESCE(firedAt,?3) WHERE wakeId=?1 AND consumer=?2 AND state='pending'",
      [wake_id, consumer, at]
    )

    if Txn.changes(txn) == 1, do: Wakes.publish_change_in_txn(txn, "wake.fired", wake_id)
    Txn.changes(txn) == 1
  end

  defp discard_internal_wake(db, wake, consumer, reason) do
    with wake_id when is_binary(wake_id) <- Map.get(wake, :wake_id),
         {:ok, _} <-
           DB.transaction(db, fn txn ->
             Txn.q(
               txn,
               "UPDATE wakes SET state='fired',firedAt=COALESCE(firedAt,?3) WHERE wakeId=?1 AND consumer=?2 AND state='pending'",
               [wake_id, consumer, now()]
             )

             if Txn.changes(txn) == 1 do
               EventLog.lifecycle_in_txn(
                 txn,
                 "assignment_inactivity_record_unavailable",
                 wake_id,
                 inspect(reason)
               )

               Wakes.publish_change_in_txn(txn, "wake.fired", wake_id)
             end

             :ok
           end) do
      :ok
    else
      _ -> :ok
    end
  end

  defp current_interval_in_txn(txn, assignment_id) do
    rows =
      Txn.q(
        txn,
        "SELECT prompt FROM wakes WHERE assignmentId=?1 AND consumer=?2 ORDER BY createdAt DESC,wakeId DESC LIMIT 1",
        [assignment_id, @deadline_consumer]
      )

    interval =
      case rows do
        [[prompt]] when is_binary(prompt) ->
          case JSON.decode(prompt) do
            {:ok, %{"intervalMs" => value}} when is_integer(value) and value > 0 -> value
            _ -> nil
          end

        _ ->
          nil
      end

    if is_integer(interval) do
      interval
    else
      Logger.warning(
        "assignment inactivity interval unavailable for #{assignment_id}; using default"
      )

      @default_interval_ms
    end
  end

  defp current_activity_time_in_txn(txn, assignment_id, holder, opened_at) do
    candidates = [
      max_row(
        txn,
        "SELECT MAX(ts) FROM attests WHERE assignmentId=?1 AND bySession=?2 AND ts>=?3",
        [assignment_id, holder, opened_at]
      ),
      max_row(
        txn,
        "SELECT MAX(createdAt) FROM artifacts WHERE producedByAssignmentId=?1 AND createdBySession=?2 AND createdAt>=?3",
        [assignment_id, holder, opened_at]
      ),
      max_row(
        txn,
        "SELECT MAX(createdAt) FROM wakes WHERE assignmentId=?1 AND creatorSessionKey=?2 AND createdAt>=?3",
        [assignment_id, holder, opened_at]
      ),
      max_row(
        txn,
        "SELECT MAX(raisedAt) FROM decision_requests WHERE assignmentId=?1 AND raiserSessionKey=?2 AND raisedAt>=?3",
        [assignment_id, holder, opened_at]
      )
    ]

    [opened_at | Enum.filter(candidates, &is_integer/1)] |> Enum.max()
  end

  defp activity_start_in_txn(txn, assignment_id, opened_at) do
    case Txn.q(txn, "SELECT MAX(ts) FROM assignment_reopenings WHERE assignmentId=?1", [
           assignment_id
         ]) do
      [[at]] when is_integer(at) ->
        max(opened_at, at)

      [[nil]] ->
        opened_at

      other ->
        Logger.warning(
          "assignment reopen time unreadable for #{assignment_id}: #{inspect(other)}"
        )

        opened_at
    end
  end

  defp max_row(txn, sql, params) do
    case Txn.q(txn, sql, params) do
      [[at]] when is_integer(at) ->
        at

      [[nil]] ->
        nil

      other ->
        Logger.warning("assignment activity time unavailable: #{inspect(other)}")
        nil
    end
  end

  defp interval_from_entitlement_in_txn(txn, assignment_id, default_interval_ms) do
    case Txn.q(
           txn,
           "SELECT state,supervisionIntervalMs FROM supervision_entitlements WHERE assignmentId=?1",
           [assignment_id]
         ) do
      [[state, interval]]
      when state in ["armed", "claimed"] and is_integer(interval) and interval > 0 ->
        interval

      [["terminus", nil]] ->
        default_interval_ms

      [] ->
        default_interval_ms

      other ->
        Logger.warning(
          "assignment legacy interval unavailable for #{assignment_id}: #{inspect(other)}; using default"
        )

        default_interval_ms
    end
  end

  defp cancel_legacy_controllers_in_txn(txn) do
    rows =
      Txn.q(
        txn,
        """
        SELECT s.wakeId,s.assignmentId,a.state
        FROM supervision_liveness_sidecar s
        JOIN wakes w ON w.wakeId=s.wakeId
        LEFT JOIN assignments a ON a.id=s.assignmentId
        WHERE s.controllerOrigin='scheduled' AND s.controllerState='pending'
          AND w.state='pending'
        ORDER BY w.createdAt,w.wakeId
        """
      )

    Enum.each(rows, fn
      [wake_id, assignment_id, assignment_state]
      when is_binary(wake_id) and is_binary(assignment_id) ->
        isolated_side_task(txn, assignment_id, "legacy-controller", fn ->
          result =
            case {assignment_state, pending_deadline_wake_id(txn, assignment_id)} do
              {"open", replacement_id} when is_binary(replacement_id) ->
                Wakes.cancel_in_txn(txn, %{
                  wake_id: wake_id,
                  requester: %{kind: "process", id: "tightbeam:supervision"},
                  reason_kind: "superseded",
                  causal_source: %{kind: "wake", id: replacement_id},
                  outcome: %{kind: "replacement", replacement_wake_id: replacement_id}
                })

              {"closed", _replacement_id} ->
                Wakes.cancel_in_txn(txn, %{
                  wake_id: wake_id,
                  requester: %{kind: "process", id: "tightbeam:assignments"},
                  reason_kind: "obligation_disposed",
                  causal_source: %{kind: "assignment_transition", id: assignment_id},
                  outcome: %{
                    kind: "disposition",
                    disposition_kind: "assignment_transition",
                    disposition_id: assignment_id
                  }
                })

              _ ->
                false
            end

          if result do
            Txn.q(
              txn,
              "UPDATE supervision_liveness_sidecar SET controllerState='settled' WHERE wakeId=?1 AND controllerOrigin='scheduled' AND controllerState='pending'",
              [wake_id]
            )
          else
            Logger.warning("legacy supervision controller could not be retired: #{wake_id}")
          end

          :ok
        end)

      [wake_id, _assignment_id, _assignment_state] when is_binary(wake_id) ->
        Logger.warning("skipping malformed legacy supervision controller #{wake_id}")

      _ ->
        Logger.warning("skipping malformed legacy supervision controller reference")
    end)

    :ok
  rescue
    error ->
      Logger.warning(
        "legacy supervision controller migration deferred: #{Exception.message(error)}"
      )

      :ok
  end

  defp isolated_side_task(txn, subject, action, fun) do
    savepoint = "assignment_inactivity_#{action}"
    :ok = Txn.exec(txn, "SAVEPOINT #{savepoint}")

    try do
      result = fun.()
      :ok = Txn.exec(txn, "RELEASE #{savepoint}")
      result
    rescue
      error ->
        :ok = Txn.exec(txn, "ROLLBACK TO #{savepoint}")
        :ok = Txn.exec(txn, "RELEASE #{savepoint}")

        Logger.warning(
          "assignment inactivity #{action} skipped for #{inspect(subject)}: #{Exception.message(error)}"
        )

        :ignored
    end
  end

  defp pending_deadline_in_txn?(txn, assignment_id) do
    is_binary(pending_deadline_wake_id(txn, assignment_id))
  end

  defp pending_deadline_wake_id(txn, assignment_id) do
    case Txn.q(
           txn,
           "SELECT wakeId FROM wakes WHERE assignmentId=?1 AND consumer=?2 AND state='pending' ORDER BY dueAt,wakeId LIMIT 1",
           [assignment_id, @deadline_consumer]
         ) do
      [[wake_id]] when is_binary(wake_id) -> wake_id
      _ -> nil
    end
  end

  defp decode_payload(%{consumer: consumer, prompt: prompt}, consumer) when is_binary(prompt) do
    case JSON.decode(prompt) do
      {:ok, %{"version" => 1} = payload} -> {:ok, payload}
      _ -> {:error, :invalid_payload}
    end
  end

  defp decode_payload(_wake, _consumer), do: {:error, :consumer_or_payload_mismatch}

  defp deadline_payload(
         %{
           "assignmentId" => assignment_id,
           "intervalMs" => interval,
           "activityAt" => activity_at
         },
         wake
       )
       when is_binary(assignment_id) and is_integer(interval) and interval > 0 and
              is_integer(activity_at) and activity_at >= 0 do
    if assignment_id == wake.assignment_id,
      do: {:ok, assignment_id, interval, activity_at},
      else: {:error, :assignment_mismatch}
  end

  defp deadline_payload(_payload, _wake), do: {:error, :invalid_deadline_fields}

  defp climb_payload(
         %{
           "assignmentId" => assignment_id,
           "episodeRef" => episode_ref,
           "originHolder" => origin_holder,
           "rung" => rung,
           "intervalMs" => interval,
           "previousWakeId" => previous_wake_id,
           "visited" => visited
         },
         wake
       )
       when is_binary(assignment_id) and is_binary(episode_ref) and is_binary(origin_holder) and
              is_integer(rung) and rung > 0 and is_integer(interval) and interval > 0 and
              is_binary(previous_wake_id) and is_list(visited) do
    valid_visited? = Enum.all?(visited, &(is_binary(&1) and &1 != ""))

    if assignment_id == wake.assignment_id and episode_ref == wake.obligation_ref and
         valid_visited?,
       do:
         {:ok, assignment_id, episode_ref, origin_holder, rung, interval, previous_wake_id,
          Enum.uniq(visited)},
       else: {:error, :climb_mismatch}
  end

  defp climb_payload(_payload, _wake), do: {:error, :invalid_climb_fields}

  defp lineage(_db, nil, _visited, acc), do: Enum.reverse(acc)

  defp lineage(db_or_txn, session_key, visited, acc) do
    if MapSet.member?(visited, session_key) do
      Logger.warning("assignment notice lineage contains a cycle at #{inspect(session_key)}")
      Enum.reverse(acc)
    else
      case query(
             db_or_txn,
             "SELECT state, #{Org.current_parent_sql("sessions")} FROM sessions WHERE sessionKey=?1",
             [session_key]
           ) do
        [[state, parent]] ->
          next = if state == "active", do: [session_key | acc], else: acc
          lineage(db_or_txn, parent, MapSet.put(visited, session_key), next)

        [] ->
          Logger.warning("assignment notice lineage session missing for #{inspect(session_key)}")
          Enum.reverse(acc)

        other ->
          Logger.warning(
            "assignment notice lineage unreadable for #{inspect(session_key)}: #{inspect(other)}"
          )

          Enum.reverse(acc)
      end
    end
  end

  defp active_personal_key(_db_or_txn, nil), do: nil

  defp active_personal_key(db_or_txn, owner) do
    key = Org.personal_session_key(owner)

    case query(db_or_txn, "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'", [key]) do
      [[1]] ->
        key

      [] ->
        Logger.warning("assignment notice personal target unavailable for #{inspect(owner)}")
        nil

      other ->
        Logger.warning(
          "assignment notice personal target unreadable for #{inspect(owner)}: #{inspect(other)}"
        )

        nil
    end
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    case DB.query(db, sql, params) do
      {:ok, rows} -> rows
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)
end
