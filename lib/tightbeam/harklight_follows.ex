defmodule Tightbeam.HarklightFollows do
  @moduledoc false
  alias Tightbeam.{DB, HarklightLifecycle, HarklightWakes, Id, Org, Placement}
  alias Tightbeam.DB.Txn

  def follow(db, call, opts \\ []) do
    case target(call.params) do
      {:ok, kind, target} ->
        follow_target(db, call, kind, target, opts)

      {:error, reason} ->
        failure("conversation", nil, "The follow could not be recorded: #{reason}.")
    end
  end

  defp follow_target(db, call, kind, target, opts) do
    with :ok <- origin!(db, call),
         {:ok, resolved} <- resolve(db, kind, target),
         :ok <- origin_handle(db, resolved),
         {:ok, resolved} <- settled(resolved, kind, target) do
      record(db, call.session_key, kind, resolved, opts)
    else
      {:error, {:unresolved, id, sender_id, handle}} ->
        result("message", "refused", "none", id, handle, sender_id, unresolved_reason(id))

      {:error, {:unknown, kind, target}} ->
        result(
          kind,
          "refused",
          "none",
          if(kind == "message", do: target, else: nil),
          if(kind == "conversation", do: target, else: nil),
          nil,
          unknown_reason()
        )

      {:error, {:origin_unavailable, resolved}} ->
        failure(
          kind,
          resolved,
          "Run the follow command from an active session on the conversation's original host.",
          "harklight_origin_unavailable"
        )

      {:error, {:origin_lookup_failed, resolved, reason}} ->
        failure(
          kind,
          resolved,
          "The conversation's original host could not be checked: #{inspect(reason)}. Retry when it is available."
        )

      {:error, "harklight_origin_unavailable"} ->
        failure(
          kind,
          selected_target(kind, target),
          "Run the follow command from an active session on the conversation's original host.",
          "harklight_origin_unavailable"
        )

      {:error, code} when is_binary(code) ->
        failure(kind, selected_target(kind, target), "The follow could not be recorded: #{code}.")

      {:error, reason} ->
        failure(
          kind,
          selected_target(kind, target),
          "The follow could not be recorded: #{inspect(reason)}."
        )
    end
  end

  defp target(params) do
    case Map.to_list(params) do
      [{:message_id, message}] when is_binary(message) and message != "" ->
        {:ok, "message", message}

      [{:handle, handle}] when is_binary(handle) and handle != "" ->
        {:ok, "conversation", handle}

      _ ->
        {:error, "invalid_harklight_follow"}
    end
  end

  defp resolve(db, "message", message_id) do
    case HarklightLifecycle.lookup(db, message_id) do
      nil ->
        {:error, {:unknown, "message", message_id}}

      %{state: "pending", sender_id: sender_id, handle: handle} ->
        {:error, {:unresolved, message_id, sender_id, handle}}

      %{state: "committed"} = record ->
        {:ok,
         %{
           handle: record.handle,
           sender_id: record.sender_id,
           message_id: record.message_id || message_id
         }}

      _ ->
        {:error, {:unknown, "message", message_id}}
    end
  end

  defp resolve(db, "conversation", handle) do
    case DB.query(
           db,
           """
           SELECT h.handle,s.senderId
           FROM harklight_wake_handles h
           JOIN harklight_send_operations s ON s.handle=h.handle AND s.state='bound'
           WHERE h.handle=?1
           ORDER BY s.createdAt,s.opId
           LIMIT 1
           """,
           [handle]
         ) do
      {:ok, [[^handle, sender_id]]} ->
        {:ok, %{handle: handle, sender_id: sender_id, message_id: nil}}

      _ ->
        {:error, {:unknown, "conversation", handle}}
    end
  end

  defp settled(%{handle: handle} = resolved, _kind, _target) when is_binary(handle),
    do: {:ok, resolved}

  defp settled(_resolved, "message", message_id),
    do: {:error, {:unresolved, message_id, nil, nil}}

  defp settled(_resolved, kind, target), do: {:error, {:unknown, kind, target}}

  defp origin_handle(db, resolved) do
    local_host = Placement.local_host_name()

    case DB.query(db, "SELECT host FROM harklight_wake_handles WHERE handle=?1", [resolved.handle]) do
      {:ok, [[^local_host]]} -> :ok
      {:ok, [[_host]]} -> {:error, {:origin_unavailable, resolved}}
      {:ok, []} -> {:error, {:origin_unavailable, resolved}}
      {:error, reason} -> {:error, {:origin_lookup_failed, resolved, reason}}
    end
  end

  defp record(db, session_key, kind, resolved, opts) do
    message_id = if kind == "message", do: resolved.message_id, else: ""

    case DB.transaction(db, fn txn ->
           case Txn.q(txn, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [
                  resolved.handle
                ]) do
             [["complete"]] ->
               :finished

             _ ->
               own_message_subscription =
                 kind == "message" and
                   Txn.q(
                     txn,
                     """
                     SELECT 1 FROM harklight_send_operations s
                     LEFT JOIN harklight_subscription_ends e ON e.senderId=s.senderId AND e.messageId=s.messageId
                     WHERE s.sessionKey=?1 AND s.senderId=?2 AND s.messageId=?3
                       AND s.handle=?4 AND s.state='bound' AND e.messageId IS NULL
                     LIMIT 1
                     """,
                     [session_key, resolved.sender_id, resolved.message_id, resolved.handle]
                   ) != []

               existing =
                 if own_message_subscription do
                   [["own-message"]]
                 else
                   Txn.q(
                     txn,
                     "SELECT followId FROM harklight_wake_follows WHERE sessionKey=?1 AND kind=?2 AND handle=?3 AND messageId=?4 AND state='open' LIMIT 1",
                     [session_key, kind, resolved.handle, message_id]
                   )
                 end

               wake_effect =
                 case existing do
                   [[_]] ->
                     "kept"

                   [] ->
                     Txn.q(
                       txn,
                       "INSERT INTO harklight_wake_follows(followId,sessionKey,kind,handle,senderId,messageId,state,createdAt) VALUES(?1,?2,?3,?4,?5,?6,'open',?7)",
                       [
                         Id.uuid4(),
                         session_key,
                         kind,
                         resolved.handle,
                         if(kind == "message", do: resolved.sender_id, else: nil),
                         message_id,
                         System.system_time(:millisecond)
                       ]
                     )

                     "subscribed"
                 end

               %{
                 wake_effect: wake_effect,
                 subscriptions: subscriptions_in_txn(txn, resolved.handle)
               }
           end
         end) do
      {:ok, :finished} ->
        refusal(kind, resolved, "The Harklight conversation is already finished.")

      {:ok, details} ->
        if Keyword.get(opts, :activate, true), do: HarklightWakes.activate(resolved.handle)

        %{
          command: "follow",
          following: kind,
          outcome: "committed",
          message_id: if(kind == "message", do: resolved.message_id, else: nil),
          handle: resolved.handle,
          sender_id: resolved.sender_id,
          wake_effect: details.wake_effect,
          subscriptions: details.subscriptions
        }

      {:error, reason} ->
        failure(
          kind,
          resolved,
          "The follow could not be recorded: #{inspect(reason)}."
        )
    end
  end

  defp subscriptions_in_txn(txn, handle) do
    own =
      Txn.q(
        txn,
        """
        SELECT s.sessionKey,s.messageId,CASE WHEN e.messageId IS NULL THEN 'open' ELSE 'ended' END
        FROM harklight_send_operations s
        LEFT JOIN harklight_subscription_ends e ON e.senderId=s.senderId AND e.messageId=s.messageId
        WHERE s.handle=?1 AND s.state='bound'
        ORDER BY s.createdAt,s.messageId
        """,
        [handle]
      )
      |> Enum.map(fn [follower, message_id, state] ->
        %{follower: follower, kind: "message", message_id: message_id, state: state}
      end)

    follows =
      Txn.q(
        txn,
        "SELECT sessionKey,kind,messageId,state FROM harklight_wake_follows WHERE handle=?1 ORDER BY createdAt,followId",
        [handle]
      )
      |> Enum.map(fn [follower, kind, message_id, state] ->
        %{
          follower: follower,
          kind: kind,
          message_id: if(message_id == "", do: nil, else: message_id),
          state: state
        }
      end)

    own ++ follows
  end

  defp origin!(db, call) do
    org = if is_binary(call[:session_key]), do: Org.get(db, call.session_key), else: nil

    if is_binary(call[:session_key]) and call[:principal] == {:session, call.session_key} and
         call[:transport_session_key] == call.session_key and
         match?(%{state: "active"}, org) and org.host == Placement.local_host_name(),
       do: :ok,
       else: {:error, "harklight_origin_unavailable"}
  end

  defp refusal(kind, resolved, reason) do
    result(
      kind,
      "refused",
      "none",
      resolved.message_id,
      resolved.handle,
      resolved.sender_id,
      reason
    )
  end

  defp failure(kind, target, reason, code \\ nil) do
    message_id = Map.get(target || %{}, :message_id)
    handle = Map.get(target || %{}, :handle)
    sender_id = Map.get(target || %{}, :sender_id)
    result = result(kind, "failed", "none", message_id, handle, sender_id, reason)
    if code, do: Map.put(result, :code, code), else: result
  end

  defp selected_target("message", target), do: %{message_id: target}
  defp selected_target("conversation", target), do: %{handle: target}

  defp result(kind, outcome, wake_effect, message_id, handle, sender_id, reason) do
    %{
      command: "follow",
      following: kind,
      outcome: outcome,
      wake_effect: wake_effect,
      reason: reason
    }
    |> maybe_put(:message_id, message_id)
    |> maybe_put(:handle, handle)
    |> maybe_put(:sender_id, sender_id)
    |> maybe_put(:code, if(outcome == "committed", do: nil, else: "harklight_follow_#{outcome}"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp unknown_reason do
    "Tightbeam can follow only messages and conversations sent through tightbeam harklight-send. Harklight has no message-to-conversation lookup or listener for conversations Tightbeam did not send."
  end

  defp unresolved_reason(id) do
    "Message #{id} is unresolved. Wait until it is settled before following. Its sender can run `tightbeam harklight-settle --message #{id}`, or let the next gateway start recover it. Run `tightbeam harklight-follow --message #{id}` again once settled. Tightbeam will not wait or retry automatically."
  end
end
