defmodule Tightbeam.RowReactions.Notice do
  @moduledoc false
  alias Tightbeam.{NoticeBatcher, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.Store

  @keys ~w(wake_id session_key owner_user_id origin prompt due_at target_gate creator_session_key assignment_id work_item_id obligation_ref condition_kind condition_scope)a

  def synchronize(txn, %{"status" => "pending", "result" => %{"wake_id" => id}} = action, at) do
    case Wakes.get_in_txn(txn, id) do
      nil ->
        raise ArgumentError, "reaction output is missing"

      %{delivered_turn_seq: seq} when is_integer(seq) ->
        Store.record(
          txn,
          action,
          "accepted",
          Map.put(action["result"], "delivery", "delivered"),
          at
        )

      %{state: "canceled"} ->
        Store.record(txn, action, "canceled", action["result"], at)

      %{state: "fired"} ->
        Store.record(txn, action, "accepted", Map.put(action["result"], "delivery", "failed"), at)

      _ ->
        :ok
    end
  end

  def synchronize(_txn, _action, _at), do: :ok

  def execute(txn, %{"status" => "canceled", "result" => %{"wake_id" => id}} = action, at),
    do: withdraw(txn, id, action["plan"]["withdraw"], at)

  def execute(_txn, %{"status" => state}, _at) when state != "pending", do: :ok

  def execute(txn, action, at) do
    value = action["plan"]["value"]
    value = Map.put(value, "prompt", render(txn, value, at))

    unless is_map(value) and is_binary(value["wake_id"]) and is_binary(value["prompt"]) and
             is_binary(value["origin"]) and is_binary(value["owner_user_id"]) and
             is_integer(value["due_at"]) and
             value["on_unavailable"] in ~w(schedule skip undelivered),
           do: raise(ArgumentError, "invalid reaction notice")

    available =
      is_binary(value["session_key"]) and
        Txn.q(
          txn,
          "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active'",
          [value["session_key"], value["owner_user_id"]]
        ) == [[1]]

    cond do
      not available and value["on_unavailable"] == "skip" ->
        if id = get_in(action, ["result", "wake_id"]),
          do: withdraw(txn, id, action["plan"]["withdraw"], at)

        Store.record(txn, action, "canceled", action["result"], at)

      true ->
        input =
          Map.new(@keys, fn key -> {key, value[Atom.to_string(key)]} end)
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        input =
          if not available and value["on_unavailable"] == "undelivered",
            do: Map.put(input, :session_key, get_in(value, ["unavailable", "session_key"])),
            else: input

        # The durable address in an unavailable disposition is a record address,
        # not permission to deliver to another recipient.
        input = Map.put_new(input, :session_key, nil)
        id = get_in(action, ["result", "wake_id"]) || input.wake_id
        input = Map.put(input, :wake_id, id)

        result =
          Map.merge(
            action["result"] || %{},
            %{
              "wake_id" => id,
              "delivery" => "queued",
              "requested_due_at" => input.due_at,
              "emitted" => Map.new(input, fn {key, value} -> {Atom.to_string(key), value} end)
            }
          )

        case Wakes.get_in_txn(txn, id) do
          nil ->
            Wakes.schedule_in_txn(txn, input)

          %{state: "pending", delivered_turn_seq: nil} = old ->
            unless is_nil(action["result"]) or action["result"]["wake_id"] == id,
              do: raise(ArgumentError, "reaction cannot replace its output identity")

            revise(txn, old, input, action["result"])

          _ ->
            raise ArgumentError, "reaction output identity is already terminal"
        end

        Store.record(txn, action, "pending", result, at)

        if not available and value["on_unavailable"] == "undelivered" do
          reason = get_in(value, ["unavailable", "reason"]) || "recipient unavailable"

          case Wakes.undeliverable_delivery_in_txn(txn, id, reason, at) do
            {:canceled, _} ->
              Store.record(
                txn,
                action,
                "canceled",
                Map.put(result, "delivery", "undelivered"),
                at
              )

            _ ->
              raise ArgumentError, "undelivered reaction evidence was not persisted"
          end
        end
    end

    :ok
  end

  def replay_in_txn(txn, action) do
    id = get_in(action, ["result", "wake_id"])
    wake = id && Wakes.get_in_txn(txn, id)
    expected = get_in(action, ["result", "emitted"]) || action["plan"]["value"]
    fields = ~w(prompt owner_user_id origin creator_session_key assignment_id work_item_id)a

    if wake && Enum.all?(fields, &(Map.get(wake, &1) == expected[Atom.to_string(&1)])) do
      {:ok, wake}
    else
      {:error,
       %{
         code: "terminal_notification_conflict",
         message: "existing wake does not match its recorded terminal action"
       }}
    end
  end

  defp render(_txn, %{"prompt" => prompt}, _at) when is_binary(prompt), do: prompt

  defp render(txn, %{"template" => template, "arguments" => arguments}, at) do
    values =
      Map.new(arguments, fn
        {key, %{"activity_at" => time}} -> {key, Tightbeam.Reminders.activity(time, at)}
        pair -> pair
      end)

    Tightbeam.Reminders.render(txn, template, values)
  end

  defp revise(txn, old, input, result) do
    # A scheduler may defer an unchanged request while its recipient is busy.
    # Reconciliation changes that deadline only when the elected request changes.
    previous_due = if is_map(result), do: result["requested_due_at"]
    input = if previous_due == input.due_at, do: Map.put(input, :due_at, old.due_at), else: input

    changed =
      Enum.any?([:session_key, :prompt, :due_at], &(Map.fetch!(old, &1) != Map.fetch!(input, &1)))

    if changed do
      # Unclaimed batches must release their members before a pending source
      # changes; a turn that already owns the bytes is immutable.
      :ok = NoticeBatcher.readdress_source_in_txn(txn, old.wake_id)

      Txn.q(
        txn,
        "UPDATE wakes SET sessionKey=?2,prompt=?3,dueAt=?4,firedAt=NULL WHERE wakeId=?1 AND state='pending' AND deliveredTurnSeq IS NULL",
        [old.wake_id, input.session_key, input.prompt, input.due_at]
      )

      NoticeBatcher.record_policy_in_txn(txn, Wakes.get_in_txn(txn, old.wake_id))
      Wakes.schedule_changed_in_txn(txn, :wake_ready)
    end
  end

  defp withdraw(txn, id, withdrawal, at) do
    case Wakes.get_in_txn(txn, id) do
      %{state: "canceled"} ->
        :ok

      %{delivered_turn_seq: seq} when is_integer(seq) ->
        :ok

      %{state: "pending"} ->
        command =
          if is_map(withdrawal) do
            %{
              wake_id: id,
              requester: %{kind: "process", id: withdrawal["requester_id"]},
              reason_kind: withdrawal["reason_kind"],
              causal_source: %{kind: withdrawal["source_kind"], id: withdrawal["source_id"]}
            }
          else
            %{
              wake_id: id,
              requester: %{kind: "process", id: "tightbeam:row-reactions"},
              reason_kind: "superseded",
              causal_source: %{kind: "wake", id: id}
            }
          end

        outcome =
          case withdrawal do
            %{
              "outcome" => %{
                "kind" => "disposition",
                "disposition_kind" => kind,
                "disposition_id" => source
              }
            } ->
              %{kind: "disposition", disposition_kind: kind, disposition_id: source}

            _ ->
              {:ok, outcome} = Wakes.public_cancellation_outcome_in_txn(txn, command)
              outcome
          end

        unless Wakes.cancel_in_txn(txn, Map.put(command, :outcome, outcome), fn -> at end),
          do: raise(ArgumentError, "reaction withdrawal refused")

      nil ->
        raise ArgumentError, "reaction output is missing"

      _ ->
        :ok
    end
  end
end
