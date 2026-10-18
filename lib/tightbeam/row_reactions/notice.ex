defmodule Tightbeam.RowReactions.Notice do
  @moduledoc false
  alias Tightbeam.DB.Txn
  alias Tightbeam.Wakes
  alias Tightbeam.RowReactions.Store

  @required ~w(session_key owner_user_id origin prompt due_at target_gate on_unavailable)
  @optional ~w(wake_id creator_session_key assignment_id work_item_id obligation_ref sender_scheduled unavailable)
  @wake_keys ~w(session_key owner_user_id origin prompt due_at target_gate wake_id creator_session_key assignment_id work_item_id obligation_ref sender_scheduled)a

  # Freeze the action at the same durable boundary that freezes a source notice.
  # Do this before a new election can alter the action's plan.
  def synchronize_in_txn(
        txn,
        %{"status" => "pending", "result" => %{"wake_id" => id}} = action,
        at
      )
      when is_binary(id) do
    case Wakes.get_in_txn(txn, id) do
      nil ->
        raise ArgumentError, "reaction refers to missing wake #{id}"

      %{state: "canceled"} ->
        Store.cancel_pending_in_txn(txn, action["id"], at)

      %{state: "pending"} ->
        if Wakes.notice_snapshot_exists_in_txn?(txn, id),
          do: Store.accept_in_txn(txn, action["id"], action["result"], at)

      _ ->
        Store.accept_in_txn(txn, action["id"], action["result"], at)
    end

    :ok
  end

  def synchronize_in_txn(_txn, _action, _at), do: :ok

  def execute_in_txn(txn, %{"status" => "canceled"} = action, at) do
    case get_in(action, ["result", "wake_id"]) do
      nil -> :ok
      id -> withdraw_in_txn(txn, id, at, action["plan"]["withdraw"])
    end
  end

  def execute_in_txn(_txn, %{"status" => state}, _at) when state in ~w(accepted held), do: :ok

  def execute_in_txn(
        txn,
        %{"status" => "pending", "plan" => %{"kind" => "notice", "value" => value}} = action,
        at
      ) do
    validate!(value)

    if available?(txn, value["session_key"]) do
      schedule_in_txn(txn, action, value, at)
    else
      case value["on_unavailable"] do
        "skip" ->
          if action["result"] do
            execute_in_txn(txn, %{action | "status" => "canceled"}, at)
            Store.cancel_pending_in_txn(txn, action["id"], at)
          else
            Store.skip_in_txn(txn, action["id"])
          end

        "pending" ->
          # Retain the action, but withdraw its obsolete target before it can
          # receive a message. A later attempt is linked to the same action.
          result = action["result"] || %{}

          case result["wake_id"] do
            nil ->
              :ok

            id ->
              withdraw_in_txn(txn, id, at)

              result =
                result
                |> Map.put("wake_id", nil)
                |> Map.update("previous_wake_ids", [id], &(&1 ++ [id]))
                |> Map.update("generation", 1, &(&1 + 1))

              Store.pending_result_in_txn(txn, action["id"], result, at)
          end

          Store.failure_in_txn(txn, action["id"], "target unavailable", at)

        "undelivered" ->
          disposition = value["unavailable"]

          schedule_in_txn(
            txn,
            action,
            Map.put(value, "session_key", disposition["session_key"]),
            at
          )

          # A pre-existing accepted/global output is immutable. Only this
          # pending action's actual pending output can receive a disposition.
          current =
            Store.actions_in_txn(
              txn,
              action["plan"]["identity"] |> hd(),
              action["plan"]["source_event_id"]
            )
            |> Enum.find(&(&1["id"] == action["id"]))

          if current["status"] == "pending" do
            wake = Wakes.get_in_txn(txn, current["result"]["wake_id"])

            {:undelivered, _} =
              Wakes.notice_undeliverable_in_txn(
                txn,
                wake,
                disposition["purpose"],
                disposition["reason"]
              )

            Store.cancel_pending_in_txn(txn, action["id"], at)
          end

        "refuse" ->
          raise ArgumentError, "elected notice has no available target"
      end
    end

    :ok
  end

  defp schedule_in_txn(txn, action, value, at) do
    result = reconcile_wake_identity_in_txn(txn, action["result"] || %{}, value["wake_id"], at)
    existing_id = result["wake_id"]

    id =
      existing_id || value["wake_id"] ||
        default_id(action["id"], Map.get(result, "generation", 0))

    input =
      Map.new(@wake_keys, fn key -> {key, Map.get(value, Atom.to_string(key))} end)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.put(:wake_id, id)

    case {existing_id, Wakes.get_in_txn(txn, id)} do
      {nil, nil} ->
        Wakes.schedule_in_txn(txn, input)
        record_scheduled(txn, action, result, id, value, at)

      {nil, _existing} ->
        # An explicitly elected legacy/global wake identity already exists.
        # Link it as evidence; never reschedule it in a new state or recipient.
        Store.accept_in_txn(
          txn,
          action["id"],
          Map.merge(result, %{"wake_id" => id, "existing" => true}),
          at
        )


      {^id, _} ->
        case Wakes.revise_notice_in_txn(txn, id, input) do
          :updated -> record_scheduled(txn, action, result, id, value, at)
          :accepted -> Store.accept_in_txn(txn, action["id"], result, at)
          :canceled -> Store.cancel_pending_in_txn(txn, action["id"], at)
        end
    end
  end

  # A rail can change an explicit global identity while its action is pending.
  # Preserve the old cancellation and the action identity; never leave two
  # deliverable notices for that action or rewrite an accepted source.
  defp reconcile_wake_identity_in_txn(
         _txn,
         %{"elected_wake_id" => elected} = result,
         elected,
         _at
       ),
       do: result

  defp reconcile_wake_identity_in_txn(txn, %{"wake_id" => old} = result, elected, at)
       when is_binary(old) and is_binary(elected) and old != elected do
    withdraw_in_txn(txn, old, at)

    result
    |> Map.put("wake_id", nil)
    |> Map.delete("elected_wake_id")
    |> Map.update("previous_wake_ids", [old], &(&1 ++ [old]))
    |> Map.update("generation", 1, &(&1 + 1))
  end

  defp reconcile_wake_identity_in_txn(_txn, result, _elected, _at), do: result

  defp record_scheduled(txn, action, result, id, _value, at) do
    Store.pending_result_in_txn(txn, action["id"], Map.put(result, "wake_id", id), at)
  end

  defp withdraw_in_txn(txn, id, at, withdrawal \\ nil) do
    case Wakes.get_in_txn(txn, id) do
      %{state: "canceled"} ->
        :ok

      %{state: "pending"} ->
        if Wakes.notice_snapshot_exists_in_txn?(txn, id),
          do: raise(ArgumentError, "cannot withdraw accepted reaction notice")

        command = withdrawal_command(id, withdrawal)

        # Reuse the cancellation seam's existing linked-work liveness evidence.
        # Selection of a rail does not waive the central no-stranding validator.
        {:ok, outcome} = Wakes.public_cancellation_outcome_in_txn(txn, command)

        unless Wakes.cancel_in_txn(txn, Map.put(command, :outcome, outcome), fn -> at end),
          do: raise(ArgumentError, "reaction notice cancellation refused")

        :ok

      nil ->
        raise ArgumentError, "reaction refers to missing wake #{id}"

      _ ->
        raise ArgumentError, "cannot withdraw accepted reaction notice"
    end
  end

  defp withdrawal_command(id, nil) do
    %{
      wake_id: id,
      requester: %{kind: "process", id: "tightbeam:row-reactions"},
      reason_kind: "superseded",
      causal_source: %{kind: "wake", id: id}
    }
  end

  defp withdrawal_command(id, value) do
    keys = ~w(requester_id reason_kind source_kind source_id)

    unless is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys) and
             Enum.all?(Map.values(value), &(is_binary(&1) and &1 != "")),
           do: raise(ArgumentError, "invalid notice withdrawal arguments")

    %{
      wake_id: id,
      requester: %{kind: "process", id: value["requester_id"]},
      reason_kind: value["reason_kind"],
      causal_source: %{kind: value["source_kind"], id: value["source_id"]}
    }
  end

  defp available?(txn, key) when is_binary(key),
    do: Txn.q(txn, "SELECT 1 FROM sessions WHERE sessionKey=?1", [key]) != []

  defp available?(_txn, _key), do: false

  defp default_id(action_id, generation),
    do:
      "w_" <>
        Base.encode16(:crypto.hash(:sha256, JSON.encode!([action_id, generation])), case: :lower)

  defp validate!(value) do
    keys = Map.keys(value)

    unless @required -- keys == [] and keys -- (@required ++ @optional) == [],
      do: raise(ArgumentError, "invalid notice fields")

    unless value["on_unavailable"] in ~w(skip pending refuse undelivered) and
             value["target_gate"] in [0, 1] and
             is_integer(value["due_at"]) and is_binary(value["prompt"]) and
             is_binary(value["origin"]) and is_binary(value["owner_user_id"]),
           do: raise(ArgumentError, "invalid notice values")

    if value["on_unavailable"] == "undelivered" do
      unless is_map(value["unavailable"]) and
               Enum.sort(Map.keys(value["unavailable"])) == ~w(purpose reason session_key) and
               Enum.all?(Map.values(value["unavailable"]), &(is_binary(&1) and &1 != "")),
             do:
               raise(
                 ArgumentError,
                 "undelivered notice requires an elected address, purpose and reason"
               )
    end
  end
end
