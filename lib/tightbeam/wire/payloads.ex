defmodule Tightbeam.Wire.Payloads do
  @moduledoc """
  Outbound wire payload builders (TS reference: src/wire/payloads.ts — port
  every builder EXACTLY; the golden-trace comparator diffs frame shapes, so a
  missing/extra key is a failure). Builders are TOTAL: every contract field,
  always. All return maps with STRING keys ready for JSON encoding — the wire
  contract is camelCase (sessionKey, clientMessageId, …), so builders do the
  snake→camel translation at this boundary and nowhere else.

  PROVENANCE CONVENTION (normative — clients render from these fields,
  never from text parsing; the bible's §wakes origin-class set is the
  source of truth):
  - Origin classes are a CLOSED set: `user:<id>` (human), `agent:<handle>`
    (session), `process:<name>` (automation — cron/CI/webhooks), plus the
    substrate-reserved `remedy:<statute>` a rail remedy dispatches under.
  - A stream carries `startedBy` (user | agent | substrate) — the origin's
    class already collapsed for rendering, TOTAL, classified in
    `Tightbeam.Origin`. `origin` stays beside it as the detailed provenance;
    clients render from `startedBy` and never parse the origin string.
  - A message may carry optional `messageType`: assistant | substrate |
    marker | agent. The value is OPEN for additive compatibility. A missing
    or unknown value means assistant to a client. The outer frame `type`
    remains "message".
  - Older rows omit `messageType`. Their role and sender provenance remain
    intact so an unchanged OpenClaw client decodes the stream exactly as before.
  - Wake-delivered messages carry a first-line `[from <origin>]` stamp in
    BOTH stored content and the model prompt — one string, three
    audiences: readable text in any client, a rendering cue in aware ones
    (strip the first line and show a chip ONLY when it matches the
    `sender` field — the cross-check is the anti-forgery), and the model's
    return address. Only the first line is provenance; any `[from ...]`
    deeper in a body is quoted text.

  MARKER MESSAGES (normative): structural boundaries carry
  `messageType=marker` plus a `marker` object with exactly `kind`, `from`,
  and `to`. Current kinds are harness-switch, model-retune, and
  session-restart. Writers supply those facts; `Tightbeam.Projection` owns
  each readable content template. Never infer a marker from content. Ordinary
  Tightbeam notices, including turn failures and adapter state, carry
  `messageType=substrate` and remain readable records rather than boundaries.

  Markers carry `attentionTier` like any other message. The substrate elects
  it the way an agent elects its reply's, over the SAME vocabulary, and -1
  (low) is the tier for ambient information a client is expected to hide by
  default. A client that hides low-attention messages must still replay and
  store them: elevation is a new, higher-attention message referencing the
  event, so the hidden record is what the elevated one refers back to.

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

  @typedoc "Closed durable onboarding states before their wire spelling is applied."
  @type onboarding_state :: String.t()

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
      # Store commit order, on every frame. Delivery is a hint and may arrive
      # out of order; seq is what lets a client settle order and identity.
      # Without it the ids are opaque and a late frame cannot be placed.
      "seq" => Map.fetch!(m, :seq),
      "role" => Map.fetch!(m, :role),
      "content" => Map.fetch!(m, :content),
      "timestamp" => Map.fetch!(m, :timestamp),
      "streaming" => false,
      "sessionKey" => Map.fetch!(m, :session_key),
      "llmVisibleMessageId" => Map.fetch!(m, :llm_visible_message_id),
      "attachments" => Map.fetch!(m, :attachments),
      # The agent's own election for this reply, emitted verbatim. What a client
      # does with it — pin, push, hide — is the client's business, not ours.
      "attentionTier" => Map.fetch!(m, :attention_tier)
    }
    |> put_if_present("deviceId", Map.get(m, :device_id))
    |> put_if_present("clientMessageId", Map.get(m, :client_message_id))
    |> put_if_present("sender", Map.get(m, :sender))
    |> put_if_present("replyToMessageId", Map.get(m, :reply_to_message_id))
    |> put_if_present("replyToClientMessageId", Map.get(m, :reply_to_client_message_id))
    |> put_if_present("messageType", Map.get(m, :message_type))
    |> put_if_present("marker", marker_payload(Map.get(m, :marker)))
  end

  defp marker_payload(nil), do: nil

  defp marker_payload(%{kind: kind, from: from, to: to}) do
    %{"kind" => kind, "from" => from, "to" => to}
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
    Map.merge(
      %{
        "sessionKey" => Map.fetch!(s, :session_key),
        "displayName" => Map.fetch!(s, :display_name),
        "kind" => Map.fetch!(s, :kind),
        "orderIndex" => Map.fetch!(s, :order_index),
        "isBuiltIn" => Map.fetch!(s, :is_built_in),
        "createdAt" => Map.fetch!(s, :created_at),
        "updatedAt" => Map.fetch!(s, :updated_at),
        "adopted" => Map.fetch!(s, :adopted),
        "startedBy" => Tightbeam.Origin.started_by(s[:origin])
      },
      for(
        {key, value} <- [{"origin", s[:origin]}, {"spawnedBy", s[:spawned_by]}],
        not is_nil(value),
        into: %{},
        do: {key, value}
      )
    )
  end

  @spec stream_snapshot([payload()]) :: payload()
  def stream_snapshot(streams), do: %{"type" => "stream_snapshot", "streams" => streams}

  @spec stream_created(payload()) :: payload()
  def stream_created(stream), do: %{"type" => "stream_created", "stream" => stream}

  @spec stream_updated(payload()) :: payload()
  def stream_updated(stream), do: %{"type" => "stream_updated", "stream" => stream}

  @doc "History barrier applied: live clients drop their local view of the stream."
  @spec stream_history_cleared(String.t()) :: payload()
  def stream_history_cleared(session_key),
    do: %{"type" => "stream_history_cleared", "sessionKey" => session_key}

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
          required(:client_message_id) => String.t(),
          required(:session_key) => String.t(),
          required(:state) => turn_state(),
          required(:error) => String.t() | nil,
          optional(:failure) => map() | nil
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
      "payload" =>
        payload
        |> put_if_present("error", Map.fetch!(input, :error))
        |> put_if_present("failure", Map.get(input, :failure))
    }
  end

  @doc "Encode the complete closed durable-to-wire onboarding state table."
  @spec onboarding_wire_state(onboarding_state()) :: String.t()
  def onboarding_wire_state("preparing"), do: "preparing"
  def onboarding_wire_state("awaiting_user"), do: "awaitingUser"
  def onboarding_wire_state("validating"), do: "validating"
  def onboarding_wire_state("ready_to_commit"), do: "readyToCommit"
  def onboarding_wire_state("committing"), do: "committing"
  def onboarding_wire_state("recovery_required"), do: "recoveryRequired"
  def onboarding_wire_state("succeeded"), do: "succeeded"
  def onboarding_wire_state("canceled"), do: "canceled"
  def onboarding_wire_state("expired"), do: "expired"
  def onboarding_wire_state("superseded"), do: "superseded"
  def onboarding_wire_state("failed"), do: "failed"

  def onboarding_wire_state(_unknown) do
    raise ArgumentError, "unknown onboarding stored state"
  end

  @doc "Wrap one authorized public ceremony view for device delivery."
  @spec onboarding_update(%{required(String.t()) => term()}) :: payload()
  def onboarding_update(%{"state" => stored_state} = public_view) do
    %{
      "type" => "onboarding_update",
      "onboarding" => Map.put(public_view, "state", onboarding_wire_state(stored_state))
    }
  end

  @spec sync_complete() :: payload()
  def sync_complete, do: %{"type" => "sync_complete"}

  @spec work_state_event(map()) :: payload()
  def work_state_event(event) do
    %{
      "type" => "work_state_event",
      "ref" => Map.fetch!(event, :assignmentId),
      "sessionKey" => Map.fetch!(event, :sessionKey),
      "from" => Map.fetch!(event, :fromState),
      "to" => Map.fetch!(event, :toState),
      "cursor" => Map.fetch!(event, :cursor),
      "ts" => Map.fetch!(event, :ts)
    }
  end

  @spec work_item_event(map()) :: payload()
  def work_item_event(event) do
    %{
      "type" => "work_item_event",
      "ref" => Map.fetch!(event, :workItemId),
      "kind" => Map.fetch!(event, :kind),
      "cursor" => Map.fetch!(event, :cursor),
      "ts" => Map.fetch!(event, :ts)
    }
  end

  @doc """
  Live turn progress for the typing indicator's label (client contract:
  AgentProgressEvent — first non-empty of progressText/title/summary/name is
  shown; messageId matching the turn's correlation lets the assistant final
  clear it; a terminal `state` ("completed"/"failed") clears it explicitly).
  `seq` is a per-turn monotonic counter for the client's stale-guard.
  """
  @spec agent_progress(String.t(), String.t(), pos_integer(), String.t(), String.t() | nil) ::
          payload()
  def agent_progress(session_key, message_id, seq, progress_text, state \\ nil) do
    %{
      "type" => "agent_progress",
      "sessionKey" => session_key,
      "messageId" => message_id,
      "seq" => seq,
      "progressText" => progress_text
    }
    |> put_if_present("state", state)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
