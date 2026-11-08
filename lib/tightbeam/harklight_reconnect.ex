defmodule Tightbeam.HarklightReconnect do
  @moduledoc false

  alias Tightbeam.{DB, HarklightLifecycle, HarklightWakes, Placement}

  @status_timeout_ms 5_000

  def reconnect(db, call, opts \\ []) do
    if agent_session_caller?(call) do
      case target(call) do
        {:ok, message_id} ->
          with {:ok, resolved} <- resolve(db, call.session_key, message_id),
               {:ok, _status} <- status(opts, resolved.handle) do
            run_reconnect(db, call.session_key, resolved, message_id, opts)
          else
            {:error, {:unknown_message, message_id}} ->
              result(
                "refused",
                message_id,
                nil,
                nil,
                "harklight_message_unknown",
                "The Harklight message is not an existing committed request."
              )

            {:error, {:unauthorized, resolved}} ->
              result(
                "refused",
                message_id,
                resolved.handle,
                Map.get(resolved, :sender_id),
                "harklight_reconnect_unauthorized",
                "Reconnect requires the message owner or an open follow on this thread."
              )

            {:error, {:closed, resolved}} ->
              result(
                "refused",
                message_id,
                resolved.handle,
                Map.get(resolved, :sender_id),
                "harklight_chat_closed",
                "The Harklight chat is already answered, closed, or ended."
              )

            {:error, {:busy, resolved}} ->
              result(
                "refused",
                message_id,
                resolved.handle,
                Map.get(resolved, :sender_id),
                "harklight_reconnect_busy",
                "The Harklight handle is not idle and disconnected."
              )

            {:error, {:origin_unavailable, resolved}} ->
              result(
                "failed",
                message_id,
                resolved.handle,
                Map.get(resolved, :sender_id),
                "harklight_origin_unavailable",
                "The original Harklight host is not available here."
              )

            {:error, {:status_unavailable, resolved, reason}} ->
              result(
                "failed",
                message_id,
                resolved.handle,
                Map.get(resolved, :sender_id),
                "harklight_status_unavailable",
                reason
              )

            {:error, {:status_closed, resolved}} ->
              result(
                "refused",
                message_id,
                resolved.handle,
                Map.get(resolved, :sender_id),
                "harklight_chat_closed",
                "The Harklight chat has no unanswered chat remaining."
              )

            {:error, reason} ->
              result(
                "failed",
                message_id,
                nil,
                nil,
                "harklight_reconnect_failed",
                safe_reason("The Harklight reconnect could not be prepared.", reason)
              )
          end

        {:error, _reason} ->
          result(
            "refused",
            nil,
            nil,
            nil,
            "invalid_harklight_reconnect",
            "Provide one existing Harklight message with --message."
          )
      end
    else
      result(
        "failed",
        message_id_from_call(call),
        nil,
        nil,
        "harklight_origin_unavailable",
        "Reconnect requires an authenticated Agent session."
      )
    end
  rescue
    error ->
      result(
        "failed",
        nil,
        nil,
        nil,
        "harklight_reconnect_failed",
        safe_reason("The Harklight reconnect could not be prepared.", Exception.message(error))
      )
  end

  @doc false
  def parse_agent_line(line, handle) when is_binary(line) and is_binary(handle) do
    case JSON.decode(line) do
      {:ok, %{"kind" => "reconnected", "session_handle" => ^handle, "feed_cursor" => cursor}}
      when is_integer(cursor) and cursor >= 0 ->
        {:connected, cursor}

      {:ok, %{"kind" => "event", "session_handle" => ^handle}} ->
        {:event, line}

      {:ok, %{"kind" => "event"}} ->
        {:error, :connection_error, "harklight_reconnect_unconfirmed",
         "Agent returned an event for a different Harklight handle.", nil}

      {:ok, %{"kind" => "idle", "session_handle" => ^handle, "open_requests" => 0}} ->
        :idle

      {:ok, %{"kind" => "idle", "session_handle" => other}}
      when is_binary(other) and other != handle ->
        {:error, :connection_error, "harklight_reconnect_unconfirmed",
         "Agent returned an idle result for a different Harklight handle.", nil}

      {:ok, %{"kind" => "idle"}} ->
        {:error, :connection_error, "harklight_reconnect_unconfirmed",
         "Agent returned an incomplete idle result.", nil}

      {:ok, %{"kind" => kind} = frame} when kind in ["refused", "unsupported", "error"] ->
        {:error, :refused, reason_code(frame), reason([frame]), frame["op_id"]}

      {:ok, %{"kind" => "outcome_unknown"} = frame} ->
        {:error, :outcome_unknown, reason_code(frame), reason([frame]), frame["op_id"]}

      {:ok, %{"kind" => "connection_error"} = frame} ->
        {:error, :connection_error, reason_code(frame), reason([frame]), frame["op_id"]}

      {:ok, %{"kind" => kind}} when kind in ["reconnected", "idle"] ->
        {:error, :connection_error, "harklight_reconnect_unconfirmed",
         "Agent returned a result for a different Harklight handle.", nil}

      {:ok, _frame} ->
        :ignore

      {:error, _reason} ->
        trimmed = String.trim_leading(line)

        if String.starts_with?(trimmed, ["{", "["]) do
          {:error, :connection_error, "harklight_reconnect_unconfirmed",
           "Agent returned malformed reconnect output.", nil}
        else
          case Tightbeam.HarklightWakes.sanitize_refusal_output(line) do
            nil -> :ignore
            diagnostic -> {:diagnostic, diagnostic}
          end
        end
    end
  rescue
    _ ->
      {:error, :connection_error, "harklight_reconnect_unconfirmed",
       "Agent returned malformed reconnect output.", nil}
  end

  def parse_agent_line(_line, _handle),
    do: {:error, :connection_error, "harklight_reconnect_unconfirmed", nil, nil}

  defp agent_session_caller?(%{session_key: session_key, principal: {:session, session_key}})
       when is_binary(session_key) and session_key != "",
       do: true

  defp agent_session_caller?(_call), do: false

  defp message_id_from_call(%{params: %{message_id: message_id}}) when is_binary(message_id),
    do: message_id

  defp message_id_from_call(_call), do: nil

  defp target(%{params: %{message_id: message_id}})
       when is_binary(message_id) and message_id != "",
       do: {:ok, message_id}

  defp target(_call), do: {:error, :invalid_message}

  defp resolve(db, caller_session_key, message_id) do
    case HarklightLifecycle.lookup(db, message_id) do
      %{state: "committed", handle: handle, sender_id: sender_id, session_key: origin_session}
      when is_binary(handle) and is_binary(sender_id) and is_binary(origin_session) ->
        case DB.query(
               db,
               """
               SELECT h.sessionKey,h.host,h.state,s.senderId,s.messageId
               FROM harklight_wake_handles h
               JOIN harklight_send_operations s ON s.handle=h.handle AND s.state='bound'
               WHERE h.handle=?1 AND s.messageId=?2
               ORDER BY s.createdAt,s.opId LIMIT 1
               """,
               [handle, message_id]
             ) do
          {:ok, [[^origin_session, host, handle_state, ^sender_id, ^message_id]]} ->
            resolved = %{
              handle: handle,
              sender_id: sender_id,
              message_id: message_id,
              origin_session: origin_session,
              host: host,
              handle_state: handle_state
            }

            ending = ended?(db, sender_id, message_id)

            cond do
              host != Placement.local_host_name() ->
                {:error, {:origin_unavailable, resolved}}

              ending == true ->
                {:error, {:closed, resolved}}

              match?({:error, _}, ending) ->
                {:error, reason} = ending

                {:error,
                 {:status_unavailable, resolved,
                  "The Harklight message ending could not be checked: #{inspect(reason)}."}}

              not authorized?(db, caller_session_key, resolved) ->
                {:error, {:unauthorized, resolved}}

              handle_state == "complete" ->
                {:error, {:closed, resolved}}

              handle_state != "unavailable" ->
                {:error, {:busy, resolved}}

              true ->
                {:ok, resolved}
            end

          {:ok, _} ->
            {:error, {:unknown_message, message_id}}

          {:error, reason} ->
            {:error,
             {:status_unavailable, %{handle: handle, sender_id: sender_id},
              "The stored Harklight message could not be checked: #{inspect(reason)}."}}
        end

      _ ->
        {:error, {:unknown_message, message_id}}
    end
  end

  defp ended?(db, sender_id, message_id) do
    case DB.query(
           db,
           """
           SELECT 1 FROM harklight_subscription_ends
           WHERE senderId=?1 AND messageId=?2
           UNION ALL
           SELECT 1 FROM harklight_follow_message_ends
           WHERE senderId=?1 AND messageId=?2
           LIMIT 1
           """,
           [sender_id, message_id]
         ) do
      {:ok, []} -> false
      {:ok, [_ | _]} -> true
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorized?(_db, caller_session_key, %{origin_session: origin_session})
       when caller_session_key == origin_session,
       do: true

  defp authorized?(db, caller_session_key, %{handle: handle, message_id: message_id}) do
    case DB.query(
           db,
           """
           SELECT 1 FROM harklight_wake_follows
           WHERE sessionKey=?1 AND handle=?2 AND state='open'
             AND (kind='conversation' OR (kind='message' AND messageId=?3))
           LIMIT 1
           """,
           [caller_session_key, handle, message_id]
         ) do
      {:ok, [[1]]} -> true
      _ -> false
    end
  end

  defp status(opts, handle) do
    with {:ok, runner} <- status_runner(opts),
         {:ok, output} <- run_status(runner, handle),
         {:ok, status} <- decode_status(output, handle) do
      open_chats = status["open_chats"]

      if open_chats > 0 do
        {:ok, status}
      else
        if status["pending_undelivered"] > 0 or status["pending_delivered_unacted"] > 0 do
          {:ok, status}
        else
          {:error, {:status_closed, %{handle: handle}}}
        end
      end
    else
      {:error, reason} ->
        {:error,
         {:status_unavailable, %{handle: handle},
          "Harklight status could not be read: #{reason}. Retry when it is available."}}

      _ ->
        {:error,
         {:status_unavailable, %{handle: handle},
          "Harklight status did not provide the counts needed to confirm an unanswered chat."}}
    end
  end

  defp status_runner(opts) do
    case Keyword.get(opts, :agent_runner) || Keyword.get(opts, :runner) do
      runner when is_function(runner, 1) ->
        {:ok, runner}

      nil ->
        case System.find_executable("harklight-agent") do
          nil -> {:error, "Harklight Agent could not be run to read conversation status."}
          executable -> {:ok, fn args -> System.cmd(executable, args, stderr_to_stdout: true) end}
        end
    end
  end

  defp run_status(runner, handle) do
    task =
      Task.async(fn ->
        try do
          runner.(["status", "--session", handle])
        rescue
          _ -> :error
        catch
          _, _ -> :error
        end
      end)

    case Task.yield(task, @status_timeout_ms) || Task.shutdown(task, 100) do
      {:ok, {output, 0}} when is_binary(output) -> {:ok, output}
      {:ok, {_output, status}} -> {:error, "status command exited #{status}"}
      _ -> {:error, "status command did not finish"}
    end
  rescue
    _ -> {:error, "status command could not be run"}
  end

  defp decode_status(output, handle) do
    output
    |> json_lines()
    |> Enum.find(&(&1["session_handle"] == handle))
    |> case do
      %{
        "open_requests" => open_requests,
        "open_chats" => open_chats,
        "pending_undelivered" => pending_undelivered,
        "pending_delivered_unacted" => pending_delivered_unacted
      } = value
      when is_integer(open_requests) and open_requests >= 0 and is_integer(open_chats) and
             open_chats >= 0 and is_integer(pending_undelivered) and pending_undelivered >= 0 and
             is_integer(pending_delivered_unacted) and pending_delivered_unacted >= 0 ->
        {:ok, value}

      _ ->
        {:error, :invalid_status}
    end
  end

  defp json_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case JSON.decode(line) do
        {:ok, value} when is_map(value) -> [value]
        _ -> []
      end
    end)
  end

  defp reason(lines) do
    lines
    |> Enum.find_value(fn line ->
      if line["kind"] in [
           "refused",
           "unsupported",
           "outcome_unknown",
           "connection_error",
           "error"
         ],
         do: line["reason"]
    end)
    |> case do
      value when is_binary(value) -> Tightbeam.HarklightWakes.sanitize_refusal_output(value)
      _ -> nil
    end
  end

  defp reason_code(line) do
    case line["reason_code"] do
      value when is_binary(value) ->
        if Regex.match?(~r/\A[a-zA-Z0-9_]{1,64}\z/, value),
          do: value,
          else: "harklight_reconnect_failed"

      _ ->
        "harklight_reconnect_failed"
    end
  end

  defp run_reconnect(_db, caller_session_key, resolved, message_id, opts) do
    reconnecter =
      Keyword.get(opts, :reconnector, fn handle, session_key ->
        HarklightWakes.reconnect_handle(
          handle,
          session_key,
          Keyword.get(opts, :manager, HarklightWakes)
        )
      end)

    case reconnecter.(resolved.handle, caller_session_key) do
      {:ok, %{feed_cursor: cursor}} when is_integer(cursor) and cursor >= 0 ->
        result("committed", message_id, resolved.handle, resolved.sender_id, nil, nil)
        |> Map.put(:feed_cursor, cursor)

      {:error, {:refused, code, reason}} ->
        result("refused", message_id, resolved.handle, resolved.sender_id, code, reason)

      {:error, {:outcome_unknown, code, reason, op_id}} ->
        result("outcome_unknown", message_id, resolved.handle, resolved.sender_id, code, reason)
        |> Map.put(:op_id, op_id)

      {:error, {:connection_error, code, reason}} ->
        result("failed", message_id, resolved.handle, resolved.sender_id, code, reason)

      {:error, {:busy, reason}} ->
        result(
          "refused",
          message_id,
          resolved.handle,
          resolved.sender_id,
          "harklight_reconnect_busy",
          HarklightWakes.sanitize_refusal_output(reason)
        )

      {:error, reason} ->
        result(
          "failed",
          message_id,
          resolved.handle,
          resolved.sender_id,
          "harklight_reconnect_failed",
          safe_reason("The Harklight reconnect failed.", reason)
        )

      other ->
        result(
          "failed",
          message_id,
          resolved.handle,
          resolved.sender_id,
          "harklight_reconnect_unconfirmed",
          safe_reason("The Harklight reconnect returned an unrecognized result.", other)
        )
    end
  rescue
    error ->
      result(
        "failed",
        message_id,
        resolved.handle,
        resolved.sender_id,
        "harklight_reconnect_failed",
        safe_reason("The Harklight reconnect failed.", Exception.message(error))
      )
  end

  defp safe_reason(prefix, reason) do
    text = if is_binary(reason), do: reason, else: inspect(reason)
    detail = HarklightWakes.sanitize_refusal_output(text)
    if detail, do: "#{prefix} #{detail}", else: prefix
  end

  defp result(outcome, message_id, handle, sender_id, reason_code, reason) do
    %{
      command: "harklight-reconnect",
      outcome: outcome,
      message_id: message_id,
      handle: handle,
      sender_id: sender_id,
      reason_code: reason_code,
      reason: reason
    }
  end
end
