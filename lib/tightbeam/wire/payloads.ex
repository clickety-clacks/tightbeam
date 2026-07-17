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
  def pair_result(input), do: raise("TODO(sol): #{inspect(input)}")

  @doc "auth_result success frame — takes the full assembled field map (see socket.ex)."
  @spec auth_result_success(map()) :: payload()
  def auth_result_success(input), do: raise("TODO(sol): #{inspect(input)}")

  @spec auth_result_failure(error_code()) :: payload()
  def auth_result_failure(reason), do: raise("TODO(sol): #{inspect(reason)}")

  @doc "A finalized message frame from a Projection.message (conditional keys per moduledoc)."
  @spec server_message(Tightbeam.Projection.message()) :: payload()
  def server_message(m), do: raise("TODO(sol): #{inspect(m)}")

  @spec ack(String.t()) :: payload()
  def ack(client_message_id), do: raise("TODO(sol): #{inspect(client_message_id)}")

  @spec wire_error(error_code(), String.t() | nil, String.t() | nil) :: payload()
  def wire_error(code, message \\ nil, message_id \\ nil),
    do: raise("TODO(sol): #{inspect({code, message, message_id})}")

  @spec assistant_typing(String.t(), boolean()) :: payload()
  def assistant_typing(session_key, active), do: raise("TODO(sol): #{inspect({session_key, active})}")

  @spec activity_event(%{is_active: boolean(), message_id: String.t(), session_key: String.t()}) ::
          payload()
  def activity_event(input), do: raise("TODO(sol): #{inspect(input)}")

  @doc "Stream (session catalog entry) payload from an Org.session."
  @spec stream_session(Tightbeam.Org.session()) :: payload()
  def stream_session(s), do: raise("TODO(sol): #{inspect(s)}")

  @spec stream_snapshot([payload()]) :: payload()
  def stream_snapshot(streams), do: raise("TODO(sol): #{inspect(streams)}")

  @spec stream_created(payload()) :: payload()
  def stream_created(stream), do: raise("TODO(sol): #{inspect(stream)}")

  @spec stream_updated(payload()) :: payload()
  def stream_updated(stream), do: raise("TODO(sol): #{inspect(stream)}")

  @spec stream_deleted(String.t()) :: payload()
  def stream_deleted(session_key), do: raise("TODO(sol): #{inspect(session_key)}")

  @spec stream_read_state(String.t(), String.t()) :: payload()
  def stream_read_state(session_key, last_read_message_id),
    do: raise("TODO(sol): #{inspect({session_key, last_read_message_id})}")

  @spec prompt_turn_state_event(%{
          client_message_id: String.t(),
          session_key: String.t(),
          state: turn_state(),
          error: String.t() | nil
        }) :: payload()
  def prompt_turn_state_event(input), do: raise("TODO(sol): #{inspect(input)}")

  @spec sync_complete() :: payload()
  def sync_complete, do: raise("TODO(sol)")
end
