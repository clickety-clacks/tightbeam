defmodule Tightbeam.Wire.Payloads do
  @moduledoc """
  Outbound wire payload builders (TS reference: src/wire/payloads.ts — port
  every builder EXACTLY; the golden-trace comparator diffs frame shapes, so a
  missing/extra key is a failure). Builders are TOTAL: every contract field,
  always. All return maps with STRING keys ready for JSON encoding — the wire
  contract is camelCase (sessionKey, clientMessageId, …), so builders do the
  snake→camel translation at this boundary and nowhere else.

  Conditional-key rules from the TS reference (omit, don't nil):
  - server message: deviceId/clientMessageId only when non-nil (user echoes);
    sender/replyToMessageId/replyToClientMessageId only when non-nil
    (assistant correlation); `streaming` is always false (store is finalized).
  - wire error: message/messageId keys present only when given.
  - prompt_turn_state: payload carries messageId==correlationId==the
    clientMessageId, and terminalState: true iff state ∈
    delivered|canceled|failed.
  """

  @type payload :: %{optional(String.t()) => term()}

  @typedoc "Closed set of wire error codes (payloads.ts WireErrorCode)."
  @type error_code :: String.t()

  @typedoc "prompt_turn_state names: accepted | queued | running | delivered | canceled | failed."
  @type turn_state :: String.t()

  @doc "pair_result: `{success: true, token, userId}` or `{success: false, reason}`."
  @spec pair_result({:ok, String.t(), String.t()} | {:error, String.t()}) :: payload()
  def pair_result({:ok, token, user_id}) do
    %{"type" => "pair_result", "success" => true, "token" => token, "userId" => user_id}
  end

  def pair_result({:error, reason}) do
    %{"type" => "pair_result", "success" => false, "reason" => reason}
  end

  @doc "auth_result success frame — takes the full assembled field map (see socket.ex)."
  @spec auth_result_success(map()) :: payload()
  def auth_result_success(input) do
    %{
      "type" => "auth_result",
      "success" => true,
      "userId" => Map.fetch!(input, :user_id),
      "sessionId" => Map.fetch!(input, :session_id),
      "isAdmin" => Map.fetch!(input, :is_admin),
      "replayCount" => Map.fetch!(input, :replay_count),
      "replayTruncated" => Map.fetch!(input, :replay_truncated),
      "historyReset" => Map.fetch!(input, :history_reset),
      "sessionKeys" => Map.fetch!(input, :session_keys),
      "streamReadStates" => Map.fetch!(input, :stream_read_states),
      "streamTailStates" => Map.fetch!(input, :stream_tail_states),
      "features" => Map.fetch!(input, :features),
      "dmScope" => Map.fetch!(input, :dm_scope)
    }
  end

  @spec auth_result_failure(error_code()) :: payload()
  def auth_result_failure(reason) do
    %{"type" => "auth_result", "success" => false, "reason" => reason}
  end

  @doc "A finalized message frame from a Projection.message (conditional keys per moduledoc)."
  @spec server_message(Tightbeam.Projection.message()) :: payload()
  def server_message(m) do
    %{
      "type" => "message",
      "id" => Map.fetch!(m, :id),
      "role" => Map.fetch!(m, :role),
      "content" => Map.fetch!(m, :content),
      "timestamp" => Map.fetch!(m, :timestamp),
      "streaming" => false,
      "sessionKey" => Map.fetch!(m, :session_key),
      "llmVisibleMessageId" => Map.fetch!(m, :llm_visible_message_id),
      "attachments" => Map.fetch!(m, :attachments)
    }
    |> put_if_present("deviceId", Map.get(m, :device_id))
    |> put_if_present("clientMessageId", Map.get(m, :client_message_id))
    |> put_if_present("sender", Map.get(m, :sender))
    |> put_if_present("replyToMessageId", Map.get(m, :reply_to_message_id))
    |> put_if_present("replyToClientMessageId", Map.get(m, :reply_to_client_message_id))
  end

  @spec ack(String.t()) :: payload()
  def ack(client_message_id), do: %{"type" => "ack", "id" => client_message_id}

  @spec wire_error(error_code(), String.t() | nil, String.t() | nil) :: payload()
  def wire_error(code, message \\ nil, message_id \\ nil) do
    %{"type" => "error", "code" => code}
    |> put_if_present("message", message)
    |> put_if_present("messageId", message_id)
  end

  @spec assistant_typing(String.t(), boolean()) :: payload()
  def assistant_typing(session_key, active) do
    %{"type" => "typing", "active" => active, "role" => "assistant", "sessionKey" => session_key}
  end

  @spec activity_event(%{is_active: boolean(), message_id: String.t(), session_key: String.t()}) ::
          payload()
  def activity_event(input) do
    %{
      "type" => "event",
      "event" => "activity",
      "payload" => %{
        "isActive" => Map.fetch!(input, :is_active),
        "messageId" => Map.fetch!(input, :message_id),
        "sessionKey" => Map.fetch!(input, :session_key)
      }
    }
  end

  @doc "Stream (session catalog entry) payload from an Org.session."
  @spec stream_session(Tightbeam.Org.session()) :: payload()
  def stream_session(s) do
    %{
      "sessionKey" => Map.fetch!(s, :session_key),
      "displayName" => Map.fetch!(s, :display_name),
      "kind" => Map.fetch!(s, :kind),
      "orderIndex" => Map.fetch!(s, :order_index),
      "isBuiltIn" => Map.fetch!(s, :is_built_in),
      "createdAt" => Map.fetch!(s, :created_at),
      "updatedAt" => Map.fetch!(s, :updated_at),
      "adopted" => Map.fetch!(s, :adopted)
    }
  end

  @spec stream_snapshot([payload()]) :: payload()
  def stream_snapshot(streams), do: %{"type" => "stream_snapshot", "streams" => streams}

  @spec stream_created(payload()) :: payload()
  def stream_created(stream), do: %{"type" => "stream_created", "stream" => stream}

  @spec stream_updated(payload()) :: payload()
  def stream_updated(stream), do: %{"type" => "stream_updated", "stream" => stream}

  @spec stream_deleted(String.t()) :: payload()
  def stream_deleted(session_key), do: %{"type" => "stream_deleted", "sessionKey" => session_key}

  @spec stream_read_state(String.t(), String.t()) :: payload()
  def stream_read_state(session_key, last_read_message_id) do
    %{
      "type" => "stream_read_state",
      "sessionKey" => session_key,
      "lastReadMessageId" => last_read_message_id
    }
  end

  @spec prompt_turn_state_event(%{
          client_message_id: String.t(),
          session_key: String.t(),
          state: turn_state(),
          error: String.t() | nil
        }) :: payload()
  def prompt_turn_state_event(input) do
    client_message_id = Map.fetch!(input, :client_message_id)
    state = Map.fetch!(input, :state)

    payload = %{
      "messageId" => client_message_id,
      "sessionKey" => Map.fetch!(input, :session_key),
      "state" => state,
      "terminalState" => state in ~w(delivered canceled failed),
      "correlationId" => client_message_id
    }

    %{
      "type" => "event",
      "event" => "prompt_turn_state",
      "payload" => put_if_present(payload, "error", Map.fetch!(input, :error))
    }
  end

  @spec sync_complete() :: payload()
  def sync_complete, do: %{"type" => "sync_complete"}

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
