defmodule Tightbeam.ReminderDelivery do
  @moduledoc false

  # Pure terminal transition; callers must persist it inside the winning
  # terminal transaction. Enqueue, running, and unknown outcomes are not success.
  @gaps [300_000, 900_000, 1_800_000, 1_800_000]

  alias Tightbeam.DB.Txn

  # The caller has already established ordinary supervision eligibility. This
  # shares its transaction with wake creation, never with effort adjudication.
  def schedule_in_txn(txn, assignment, kind, target, create_wake) do
    case Txn.q(txn, "SELECT reminderState FROM assignments WHERE id=?1 AND state='open'", [
           assignment
         ]) do
      [[encoded]] ->
        state =
          if is_nil(encoded),
            do: %{"version" => 1, "claimEpoch" => 0},
            else: JSON.decode!(encoded)

        snapshot = %{
          "kind" => kind,
          "target" => target,
          "consequence" => state["currentConsequence"]
        }

        now = System.system_time(:millisecond)

        cond do
          is_map(state["pending"]) ->
            %{
              code: "reminder_pending",
              message: "existing notification requires terminal delivery or authorized recovery"
            }

          state["lastSnapshot"] == snapshot and now < Map.fetch!(state, "nextEligibleAt") ->
            %{
              code: "reminder_not_eligible",
              message: "unchanged notification is within its successful-delivery gap"
            }

          true ->
            wake = create_wake.()
            epoch = Map.fetch!(state, "claimEpoch") + 1

            pending = %{
              "consumer" => %{"wake" => wake.wake_id},
              "intent" => wake.wake_id,
              "epoch" => epoch,
              "snapshot" => snapshot
            }

            next = state |> Map.put("claimEpoch", epoch) |> Map.put("pending", pending)

            Txn.q(txn, "UPDATE assignments SET reminderState=?1 WHERE id=?2", [
              JSON.encode!(next),
              assignment
            ])

            wake
        end

      [] ->
        %{code: "not_found", message: "notification assignment is not open"}
    end
  end

  # A validated cancellation may retire an unconsumed notice, but never prove
  # delivery or erase a consumer whose effects need reconciliation.
  def canceled_in_txn(txn, assignment, wake) when is_binary(assignment) do
    proven =
      Txn.q(
        txn,
        "SELECT 1 FROM wakes w JOIN wake_cancellations c ON c.wakeId=w.wakeId WHERE w.wakeId=?1 AND w.assignmentId=?2 AND w.state='canceled' AND c.outcomeKind='no_replacement' AND NOT EXISTS (SELECT 1 FROM turns t WHERE t.wakeId=w.wakeId)",
        [wake, assignment]
      )

    if proven != [] do
      transition_in_txn(txn, assignment, nil, wake, fn state, consumer, epoch ->
        {:ok,
         state
         |> Map.put("claimEpoch", epoch + 1)
         |> Map.put("pending", nil)
         |> Map.put("lastDisposition", %{
           "kind" => "canceled",
           "consumer" => consumer,
           "epoch" => epoch,
           "intent" => state["pending"]["intent"]
         })}
      end)
    else
      :unresolved_consumer
    end
  end

  def canceled_in_txn(_txn, _assignment, _wake), do: :no_claim

  # Called only inside Gateway's successful terminal callback, after the
  # ledger terminal CAS. The stored consumer is the authoritative epoch fence.
  def delivered_in_txn(txn, turn_seq) do
    case Txn.q(
           txn,
           "SELECT assignmentId, wakeId, endedAt FROM turns WHERE seq=?1 AND status='delivered'",
           [turn_seq]
         ) do
      [[assignment, wake, finished_at]] when is_binary(assignment) ->
        transition_in_txn(txn, assignment, turn_seq, wake, fn state, consumer, epoch ->
          delivered(state, consumer, epoch, finished_at)
        end)

      _ ->
        :no_claim
    end
  end

  # This function supplies no repair authority. Its only caller is the existing
  # authorized repair transaction, after the successor turn has been inserted.
  def rebind_turn_in_txn(txn, assignment, source_seq, successor_seq) do
    case Txn.q(
           txn,
           "SELECT wakeId FROM turns WHERE seq=?1 AND assignmentId=?2 AND status IN ('failed','failed_unknown')",
           [source_seq, assignment]
         ) do
      [[wake]] ->
        transition_in_txn(txn, assignment, source_seq, wake, fn state, consumer, epoch ->
          rebind(state, consumer, epoch, %{"turn" => successor_seq})
        end)

      _ ->
        :no_claim
    end
  end

  def rebind_wake_in_txn(txn, assignment, source_seq, source_wake, successor_wake)
      when is_binary(assignment) do
    transition_in_txn(txn, assignment, source_seq, source_wake, fn state, consumer, epoch ->
      rebind(state, consumer, epoch, %{"wake" => successor_wake})
    end)
  end

  def rebind_wake_in_txn(_txn, _assignment, _source_seq, _source_wake, _successor_wake),
    do: :no_claim

  defp transition_in_txn(txn, assignment, seq, wake, transition) do
    case Txn.q(txn, "SELECT reminderState FROM assignments WHERE id=?1", [assignment]) do
      [[encoded]] when is_binary(encoded) ->
        state = JSON.decode!(encoded)

        case state do
          %{"pending" => %{"consumer" => consumer, "epoch" => epoch}} ->
            if consumer == %{"turn" => seq} or (is_binary(wake) and consumer == %{"wake" => wake}) do
              case transition.(state, consumer, epoch) do
                {:ok, next} ->
                  Txn.q(
                    txn,
                    "UPDATE assignments SET reminderState=?1 WHERE id=?2 AND reminderState=?3",
                    [JSON.encode!(next), assignment, encoded]
                  )

                  [[changed]] = Txn.q(txn, "SELECT changes()")
                  if changed == 1, do: :recorded, else: :stale_claim

                {:error, reason} ->
                  reason
              end
            else
              :stale_claim
            end

          _ ->
            :no_claim
        end

      _ ->
        :no_claim
    end
  end

  # This transition is not recovery authorization. The existing authorized
  # repair transaction must create the successor and persist this state together.
  def rebind(state, consumer, epoch, successor)
      when is_map(state) and is_integer(epoch) and epoch >= 0 do
    case state do
      %{
        "claimEpoch" => ^epoch,
        "pending" => %{"consumer" => ^consumer, "epoch" => ^epoch} = pending
      } ->
        if valid_consumer?(successor) and successor != consumer do
          {:ok,
           state
           |> Map.put("claimEpoch", epoch + 1)
           |> Map.put(
             "pending",
             pending |> Map.put("consumer", successor) |> Map.put("epoch", epoch + 1)
           )}
        else
          {:error, :invalid_successor}
        end

      _ ->
        {:error, :stale_claim}
    end
  end

  defp valid_consumer?(%{"wake" => id} = value),
    do: map_size(value) == 1 and is_binary(id) and byte_size(id) > 0

  defp valid_consumer?(%{"turn" => id} = value),
    do: map_size(value) == 1 and is_integer(id) and id > 0

  defp valid_consumer?(_), do: false

  def delivered(state, consumer, epoch, delivered_at)
      when is_map(state) and is_integer(delivered_at) and delivered_at >= 0 do
    case state do
      %{
        "pending" => %{
          "consumer" => ^consumer,
          "epoch" => ^epoch,
          "snapshot" => snapshot,
          "intent" => intent
        },
        "claimEpoch" => ^epoch
      } ->
        step =
          if Map.get(state, "lastSnapshot") == snapshot do
            min(Map.get(state, "backoffStep", -1) + 1, 3)
          else
            0
          end

        {:ok,
         state
         |> Map.put("pending", nil)
         |> Map.put("lastSnapshot", snapshot)
         |> Map.put("lastIntent", intent)
         |> Map.put("lastConsumer", consumer)
         |> Map.put("lastDeliveredAt", delivered_at)
         |> Map.put("backoffStep", step)
         |> Map.put("nextEligibleAt", delivered_at + Enum.at(@gaps, step))}

      _ ->
        {:error, :stale_claim}
    end
  end
end
