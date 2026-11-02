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
  def ensure_schema(db \\ DB) do
    :ok = DB.execute(db, @ddl)
    {:ok, :ok} = DB.transaction(db, fn txn ->
      :ok = Txn.exec(txn, "CREATE TABLE IF NOT EXISTS subscription_schema (version INTEGER PRIMARY KEY)")
      case Txn.q(txn, "SELECT version FROM subscription_schema") do
        [] ->
          columns = Txn.q(txn, "PRAGMA table_info(sentinel_subscriptions)") |> Enum.map(&Enum.at(&1, 1))
          unless columns == ~w(subscriptionId sessionKey event filter createdAt endedAt),
            do: raise(DB.Error, message: "unknown subscription predecessor schema")
          for ddl <- [
            "ALTER TABLE sentinel_subscriptions ADD COLUMN mode TEXT NOT NULL DEFAULT 'standing'",
            "ALTER TABLE sentinel_subscriptions ADD COLUMN afterFact INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE sentinel_subscriptions ADD COLUMN fallbackMs INTEGER",
            "ALTER TABLE sentinel_subscriptions ADD COLUMN fallbackAt INTEGER",
            "ALTER TABLE sentinel_subscriptions ADD COLUMN fulfilledAt INTEGER"
          ], do: :ok = Txn.exec(txn, ddl)
          Txn.q(txn, "UPDATE sentinel_subscriptions SET afterFact=(SELECT COALESCE(MAX(id),0) FROM condition_facts)")
          Txn.q(txn, "INSERT INTO subscription_schema(version) VALUES (1)")
          :ok
        [[1]] -> :ok
        other -> raise DB.Error, message: "unknown subscription schema #{inspect(other)}"
      end
    end)
    :ok
  end

  # The legacy surface keeps its wake row, prompt and targeting policy. Both
  # surfaces use this literal occurrence matcher and the existing wake delivery.
  def matching_fact(db, kind, filter, cursor, owner, fact_id \\ nil) do
    {:ok, rows} = DB.query(db,
      "SELECT id, scope, payload FROM condition_facts WHERE kind=?1 AND id>?2 AND (?3 IS NULL OR id=?3) AND (ownerUserId IS NULL OR ownerUserId=?4) ORDER BY id",
      [kind, cursor, fact_id, owner])
    Enum.find_value(rows, fn [id, scope, payload] ->
      details = if is_nil(payload), do: %{}, else: JSON.decode!(payload)
      details = if is_binary(scope), do: Map.put(details, "scope", scope), else: details
      if matches?(filter, details), do: %{id: id, scope: scope, details: details}
    end)
  end

  def demand(db, prefixes \\ []) do
    {:ok, result} = DB.transaction(db, fn txn ->
      subscriptions = Txn.q(txn, "SELECT event,filter FROM sentinel_subscriptions WHERE endedAt IS NULL AND fulfilledAt IS NULL")
        |> Enum.map(fn [kind, filter] -> %{kind: kind, filter: JSON.decode!(filter)} end)
      legacy = Txn.q(txn, "SELECT conditionKind,conditionScope FROM wakes w WHERE state='pending' AND firedAt IS NULL AND conditionKind IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sentinel_subscription_wake_matches m WHERE m.wakeId=w.wakeId)")
        |> Enum.map(fn [kind, scope] -> %{kind: kind, filter: if(is_nil(scope), do: %{}, else: %{"scope" => [scope]})} end)
      (subscriptions ++ legacy)
      |> Enum.filter(fn %{kind: kind} -> prefixes == [] or Enum.any?(prefixes, &String.starts_with?(kind, &1)) end)
      |> Enum.uniq()
      |> Enum.sort_by(&{&1.kind, &1.filter})
    end)
    %{demand: result}
  end

  def event_kind(event), do: event

  def fulfill_fact_in_txn(%Txn{} = txn, fact) do
    rows = Txn.q(txn,
      "SELECT s.subscriptionId,s.sessionKey,s.filter,s.afterFact,s.mode,u.ownerUserId FROM sentinel_subscriptions s JOIN sessions u ON u.sessionKey=s.sessionKey WHERE s.event=?1 AND s.endedAt IS NULL AND s.fulfilledAt IS NULL AND u.state='active' ORDER BY s.subscriptionId",
      [fact.kind])
    rows
    |> Enum.filter(fn [_id, _session, filter, cursor, _mode, owner] ->
      matching_fact(txn, fact.kind, JSON.decode!(filter), cursor, owner, fact.fact_id) != nil
    end)
    |> Enum.group_by(fn [_id, session, _, _, _, _] -> session end)
    |> Enum.each(fn {session, matches} ->
      ids = Enum.map(matches, &hd/1)
      details = fact.payload || %{}
      details = if is_binary(fact.scope), do: Map.put(details, "scope", fact.scope), else: details
      prompt = event_prompt(fact.kind, ids, Enum.map(Map.keys(details) |> Enum.sort(), &%{name: &1}), details)
      queue_in_txn(txn, session, ids, prompt, fact.origin, fact)
      for [id, _, _, _, "once", _] <- matches do
        Txn.q(txn, "UPDATE sentinel_subscriptions SET fulfilledAt=?2 WHERE subscriptionId=?1", [id, System.system_time(:millisecond)])
      end
    end)
    :ok
  end

  def fulfill_due_in_txn(%Txn{} = txn, at) do
    rows = Txn.q(txn,
      "SELECT subscriptionId,sessionKey,event,filter,fallbackAt FROM sentinel_subscriptions WHERE endedAt IS NULL AND fulfilledAt IS NULL AND fallbackAt<=?1 ORDER BY fallbackAt,subscriptionId", [at])
    Enum.each(rows, fn [id, session, event, filter, deadline] ->
      prompt = "Subscription fallback for #{event}\nSubscription: #{id}\nFilter: #{filter}\nDeadline: #{deadline}\nCause: fallback\nCancel: tightbeam sentinel unsubscribe #{id}"
      queue_in_txn(txn, session, [id], prompt, "process:tightbeam", nil)
      Txn.q(txn, "UPDATE sentinel_subscriptions SET fulfilledAt=?2 WHERE subscriptionId=?1", [id, at])
    end)
    :ok
  end

  defp queue_in_txn(txn, session, ids, prompt, origin, fact) do
    input = %{session_key: session, creator_session_key: session, origin: origin,
      due_at: System.system_time(:millisecond), prompt: prompt}
    input = if fact, do: Map.merge(input, %{condition_kind: fact.kind, condition_scope: fact.scope,
      condition_after_id: fact.fact_id - 1}), else: input
    wake = Wakes.schedule_in_txn(txn, input)
    Enum.each(ids, fn id ->
      Txn.q(txn, "INSERT INTO sentinel_subscription_wake_matches(wakeId,subscriptionId) VALUES (?1,?2)", [wake.wake_id, id])
    end)
  end

  def subscribe_in_txn(%Txn{} = txn, session_key, event, where_pairs, options \\ %{}) do
    mode = Map.get(options, :mode) || "standing"
    fallback = options[:fallback_ms]
    cond do
      mode not in ["once", "standing"] -> %{code: "invalid", message: "mode must be once or standing"}
      not is_nil(fallback) and (not is_integer(fallback) or fallback <= 0) ->
        %{code: "invalid", message: "fallback must be a positive duration"}
      mode == "standing" and not is_nil(fallback) ->
        %{code: "invalid", message: "fallback is only supported for once subscriptions"}
      Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [session_key]) != [["active"]] ->
        %{code: "not_authorized", message: "an active session is required to subscribe"}
      true ->
        case normalize_filter(event, where_pairs) do
          {:ok, filter} ->
            prior = list_in_txn(txn, session_key)
              |> Enum.find(&(&1.event == event.qualified and &1.filter == filter and &1.mode == mode and &1.fallback_ms == fallback))
            if prior do
              prior
            else
              id = "sub_" <> Tightbeam.Id.uuid4()
              at = System.system_time(:millisecond)
              deadline = if fallback, do: at + fallback
              [[cursor]] = Txn.q(txn, "SELECT COALESCE(MAX(id),0) FROM condition_facts")
              Txn.q(txn, "INSERT INTO sentinel_subscriptions(subscriptionId,sessionKey,event,filter,createdAt,mode,afterFact,fallbackMs,fallbackAt) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
                [id,session_key,event.qualified,JSON.encode!(filter),at,mode,cursor,fallback,deadline])
              if deadline, do: Wakes.schedule_changed_in_txn(txn, :wake_ready)
              subscription_result(id,event.qualified,filter,at,mode,fallback,deadline)
            end
          {:error, error} -> error
        end
    end
  end

  @doc false
  def list_in_txn(%Txn{} = txn, session_key) when is_binary(session_key) do
    Txn.q(
      txn,
      "SELECT subscriptionId, event, filter, createdAt, mode, fallbackMs, fallbackAt FROM sentinel_subscriptions WHERE sessionKey=?1 AND endedAt IS NULL AND fulfilledAt IS NULL ORDER BY createdAt, subscriptionId",
      [session_key]
    )
    |> Enum.map(fn [id, event, encoded_filter, created_at, mode, fallback, deadline] ->
      subscription_result(id, event, JSON.decode!(encoded_filter), created_at, mode, fallback, deadline)
    end)
  end

  @doc false
  def unsubscribe_in_txn(%Txn{} = txn, call, subscription_id)
      when is_map(call) and is_binary(subscription_id) do
    case Txn.q(
           txn,
           "SELECT sessionKey, endedAt, fulfilledAt FROM sentinel_subscriptions WHERE subscriptionId=?1",
           [subscription_id]
         ) do
      [] ->
        %{code: "not_found", message: "unknown subscription #{subscription_id}"}

      [[_session_key, ended_at, _fulfilled]] when not is_nil(ended_at) ->
        %{ended: true, subscription: subscription_id}

      [[_session_key, nil, fulfilled]] ->
        ended_at = System.system_time(:millisecond)

        Txn.q(
          txn,
          "UPDATE sentinel_subscriptions SET endedAt=?2 WHERE subscriptionId=?1 AND endedAt IS NULL",
          [subscription_id, ended_at]
        )

        retract_unused_wakes_in_txn(txn, [subscription_id], call)
        if fulfilled, do: %{ended: true, subscription: subscription_id}, else: %{unsubscribed: subscription_id}
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
      "Cause: event\nDetails:\n#{detail_text}"
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

  defp subscription_result(id, event, filter, created_at, mode, fallback, deadline),
    do: %{id: id, event: event, filter: filter, created_at: created_at, mode: mode,
      fallback_ms: fallback, fallback_at: deadline}
end
