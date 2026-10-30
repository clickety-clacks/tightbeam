defmodule Tightbeam.SentinelSubscriptions do
  @moduledoc """
  Durable subscriptions to events declared by learned sentinels.

  Event occurrences stay in the condition-fact stream. This module stores only
  subscriptions and the subscription IDs that matched each occurrence, so
  cancellation can keep a shared wake alive only for subscriptions that matched
  when the event was recorded.
  """

  alias Tightbeam.{DB, Wakes}
  alias Tightbeam.DB.Txn

  @event_prefix "sentinel-event:"

  @ddl """
  CREATE TABLE IF NOT EXISTS sentinel_subscriptions (
    subscriptionId TEXT PRIMARY KEY,
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    event TEXT NOT NULL,
    filter TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    endedAt INTEGER
  );
  CREATE INDEX IF NOT EXISTS sentinel_subscriptions_active
    ON sentinel_subscriptions (sessionKey, event, endedAt, createdAt);
  CREATE TABLE IF NOT EXISTS sentinel_subscription_wake_matches (
    wakeId TEXT NOT NULL REFERENCES wakes(wakeId) ON DELETE CASCADE,
    subscriptionId TEXT NOT NULL REFERENCES sentinel_subscriptions(subscriptionId),
    PRIMARY KEY (wakeId, subscriptionId)
  );
  CREATE INDEX IF NOT EXISTS sentinel_subscription_wake_matches_subscription
    ON sentinel_subscription_wake_matches (subscriptionId, wakeId);
  """

  @doc "Create the durable subscription tables."
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc false
  def event_kind(qualified_event) when is_binary(qualified_event),
    do: @event_prefix <> qualified_event

  @doc false
  def event_kind?(kind) when is_binary(kind), do: String.starts_with?(kind, @event_prefix)
  def event_kind?(_kind), do: false

  @doc false
  def prepare_event_in_txn(%Txn{} = txn, event, details, origin)
      when is_map(event) and is_map(details) and is_binary(origin) do
    detail_names = Enum.map(event.details, & &1.name) |> MapSet.new()

    if MapSet.new(Map.keys(details)) != detail_names or
         not Enum.all?(details, fn {name, value} -> is_binary(name) and is_binary(value) end) do
      {:error,
       %{code: "invalid", message: "event details do not match the declared event fields"}}
    else
      txn
      |> active_for_event(event.qualified)
      |> Enum.filter(fn [_id, _session_key, encoded_filter] ->
        matches?(JSON.decode!(encoded_filter), details)
      end)
      |> Enum.group_by(fn [_id, session_key, _filter] -> session_key end)
      |> Enum.each(fn {session_key, rows} ->
        subscription_ids = rows |> Enum.map(&hd/1) |> Enum.sort()

        wake =
          Wakes.schedule_in_txn(txn, %{
            session_key: session_key,
            origin: origin,
            creator_session_key: session_key,
            condition_kind: event_kind(event.qualified),
            condition_scope: nil,
            due_at: System.system_time(:millisecond),
            prompt: event_prompt(event.qualified, subscription_ids, event.details, details)
          })

        Enum.each(subscription_ids, fn subscription_id ->
          Txn.q(
            txn,
            "INSERT INTO sentinel_subscription_wake_matches (wakeId, subscriptionId) VALUES (?1, ?2)",
            [wake.wake_id, subscription_id]
          )
        end)
      end)

      :ok
    end
  end

  @doc false
  def subscribe_in_txn(%Txn{} = txn, session_key, event, where_pairs)
      when is_binary(session_key) and is_map(event) and is_list(where_pairs) do
    case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [session_key]) do
      [["active"]] ->
        case normalize_filter(event, where_pairs) do
          {:ok, filter} ->
            encoded_filter = JSON.encode!(filter)

            prior =
              Txn.q(
                txn,
                "SELECT subscriptionId, filter, createdAt FROM sentinel_subscriptions WHERE sessionKey=?1 AND event=?2 AND endedAt IS NULL ORDER BY createdAt, subscriptionId",
                [session_key, event.qualified]
              )
              |> Enum.find(fn [_id, stored_filter, _created_at] ->
                JSON.decode!(stored_filter) == filter
              end)

            case prior do
              [subscription_id, _stored_filter, created_at] ->
                subscription_result(subscription_id, event.qualified, filter, created_at)

              nil ->
                subscription_id = "sub_" <> Tightbeam.Id.uuid4()
                created_at = System.system_time(:millisecond)

                Txn.q(
                  txn,
                  "INSERT INTO sentinel_subscriptions (subscriptionId, sessionKey, event, filter, createdAt) VALUES (?1, ?2, ?3, ?4, ?5)",
                  [subscription_id, session_key, event.qualified, encoded_filter, created_at]
                )

                subscription_result(subscription_id, event.qualified, filter, created_at)
            end

          {:error, _} = error ->
            error_result(error)
        end

      _ ->
        %{code: "not_authorized", message: "an active session is required to subscribe"}
    end
  end

  @doc false
  def list_in_txn(%Txn{} = txn, session_key) when is_binary(session_key) do
    Txn.q(
      txn,
      "SELECT subscriptionId, event, filter, createdAt FROM sentinel_subscriptions WHERE sessionKey=?1 AND endedAt IS NULL ORDER BY createdAt, subscriptionId",
      [session_key]
    )
    |> Enum.map(fn [id, event, encoded_filter, created_at] ->
      subscription_result(id, event, JSON.decode!(encoded_filter), created_at)
    end)
  end

  @doc false
  def unsubscribe_in_txn(%Txn{} = txn, call, subscription_id)
      when is_map(call) and is_binary(subscription_id) do
    case Txn.q(
           txn,
           "SELECT sessionKey, endedAt FROM sentinel_subscriptions WHERE subscriptionId=?1",
           [subscription_id]
         ) do
      [] ->
        %{code: "not_found", message: "unknown subscription #{subscription_id}"}

      [[_session_key, ended_at]] when not is_nil(ended_at) ->
        %{ended: true, subscription: subscription_id}

      [[_session_key, nil]] ->
        ended_at = System.system_time(:millisecond)

        Txn.q(
          txn,
          "UPDATE sentinel_subscriptions SET endedAt=?2 WHERE subscriptionId=?1 AND endedAt IS NULL",
          [subscription_id, ended_at]
        )

        retract_unused_wakes_in_txn(txn, [subscription_id], call)
        %{unsubscribed: subscription_id}
    end
  end

  def unsubscribe_in_txn(%Txn{}, _call, _subscription_id),
    do: %{code: "invalid", message: "a subscription ID is required"}

  @doc false
  def end_session_in_txn(%Txn{} = txn, session_key) when is_binary(session_key) do
    ended_at = System.system_time(:millisecond)

    subscriptions =
      Txn.q(
        txn,
        "SELECT subscriptionId FROM sentinel_subscriptions WHERE sessionKey=?1 AND endedAt IS NULL",
        [session_key]
      )
      |> Enum.map(&hd/1)

    if subscriptions != [] do
      Txn.q(
        txn,
        "UPDATE sentinel_subscriptions SET endedAt=?2 WHERE sessionKey=?1 AND endedAt IS NULL",
        [session_key, ended_at]
      )

      retract_unused_wakes_in_txn(txn, subscriptions, {:retirement, session_key})
    end

    :ok
  end

  defp active_for_event(txn, event) do
    Txn.q(
      txn,
      "SELECT subscriptionId, sessionKey, filter FROM sentinel_subscriptions WHERE event=?1 AND endedAt IS NULL ORDER BY sessionKey, subscriptionId",
      [event]
    )
  end

  defp normalize_filter(event, where_pairs) do
    known = MapSet.new(Enum.map(event.details, & &1.name))

    Enum.reduce_while(where_pairs, {:ok, %{}}, fn
      {name, value}, {:ok, acc} when is_binary(name) and is_binary(value) ->
        if MapSet.member?(known, name) do
          {:cont, {:ok, Map.update(acc, name, [value], &[value | &1])}}
        else
          {:halt,
           {:error,
            %{code: "invalid", message: "unknown event detail #{name} for #{event.qualified}"}}}
        end

      _, _ ->
        {:halt, {:error, %{code: "invalid", message: "--where must be detail=value"}}}
    end)
    |> case do
      {:ok, filter} ->
        {:ok,
         Map.new(filter, fn {name, values} -> {name, values |> Enum.uniq() |> Enum.sort()} end)}

      {:error, _} = error ->
        error
    end
  end

  defp matches?(filter, details) do
    Enum.all?(filter, fn {name, values} -> details[name] in values end)
  end

  defp event_prompt(qualified, subscription_ids, event_details, values) do
    subscriptions =
      Enum.map_join(subscription_ids, "\n", fn id ->
        "- #{id}: tightbeam sentinel unsubscribe #{id}"
      end)

    detail_text =
      Enum.map_join(event_details, "\n", fn %{name: name} ->
        "#{name}:\n#{Map.fetch!(values, name)}"
      end)

    "Sentinel event #{qualified}\n" <>
      "Matching subscriptions:\n#{subscriptions}\n" <>
      "Details:\n#{detail_text}"
  end

  defp retract_unused_wakes_in_txn(txn, subscription_ids, cancellation_context) do
    wake_ids =
      Enum.flat_map(subscription_ids, fn subscription_id ->
        Txn.q(
          txn,
          "SELECT DISTINCT m.wakeId FROM sentinel_subscription_wake_matches m JOIN wakes w ON w.wakeId=m.wakeId WHERE m.subscriptionId=?1 AND w.state='pending'",
          [subscription_id]
        )
        |> Enum.map(&hd/1)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.each(wake_ids, fn wake_id ->
      active_original_match? =
        Txn.q(
          txn,
          "SELECT 1 FROM sentinel_subscription_wake_matches m JOIN sentinel_subscriptions s ON s.subscriptionId=m.subscriptionId WHERE m.wakeId=?1 AND s.endedAt IS NULL LIMIT 1",
          [wake_id]
        ) != []

      unless active_original_match? do
        cancel_subscription_wake_in_txn(txn, wake_id, cancellation_context)
      end
    end)

    :ok
  end

  defp cancel_subscription_wake_in_txn(txn, wake_id, {:retirement, session_key}) do
    command = %{
      wake_id: wake_id,
      requester: %{kind: "process", id: "tightbeam:retirement"},
      reason_kind: "target_retired",
      causal_source: %{kind: "session_transition", id: session_key},
      outcome: %{kind: "no_replacement"}
    }

    case Wakes.cancel_in_txn(txn, command) do
      true -> :ok
      false -> raise DB.Error, message: "retirement could not cancel a pending subscription wake"
      _ -> :ok
    end
  end

  defp cancel_subscription_wake_in_txn(txn, wake_id, call) do
    {:session, session_key} = Map.fetch!(call, :principal)

    command = %{
      wake_id: wake_id,
      expected_origin: call.origin,
      requester: %{kind: "session", id: session_key},
      reason_kind: "requester_withdrew",
      causal_source: %{
        kind: "verb_call",
        accepted_event: %{
          origin: call.origin,
          session_key: call[:session_key],
          principal: call.principal
        }
      },
      outcome: %{kind: "no_replacement"},
      subscription_withdrawal: true
    }

    case Wakes.cancel_in_txn(txn, command) do
      {:accepted_in_txn, _event_id, %{canceled: true}} -> :ok
      false -> raise DB.Error, message: "unsubscribe could not cancel a pending subscription wake"
      _ -> :ok
    end
  end

  defp subscription_result(id, event, filter, created_at),
    do: %{id: id, event: event, filter: filter, created_at: created_at}

  defp error_result({:error, error}), do: error
end
