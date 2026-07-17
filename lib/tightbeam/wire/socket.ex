defmodule Tightbeam.Wire.Socket do
  @moduledoc """
  The Clawline WebSocket handler — a `WebSock` implementation, one process
  per socket under Bandit (TS reference: src/wire/server.ts; its behavior,
  frame-for-frame, is the oracle — including the E0 golden frame ORDER for
  the canonical turn).

  Two socket lifecycles:
  - pairing socket: pair_request → pair_result (+ close)
  - authed socket:  auth → auth_result → stream_snapshot → replay messages →
    sync_complete → live

  Process/ownership rules (the Elixir-shape decisions — binding):
  - This process owns NOTHING shared. Fan-out scoping, device takeover, and
    the replay/live de-dup watermark live in `Tightbeam.ConnRegistry`; this
    process registers on auth, unregisters on terminate, and forwards frames.
  - Replay protocol vs the registry (the race-closing order): register FIRST
    (live pushes start arriving as `{:push, payload}` messages and are
    buffered by this process), then read the replay window from Projection,
    sending each and advancing the watermark via `ConnRegistry.note_replayed`,
    then drain the buffer THROUGH the watermark, then send sync_complete, then
    go live (pushes flow through the registry's persistent filter forever).
  - Takeover: `ConnRegistry.register` returns the replaced ref; the SOCKET
    (not the registry) then sends session_replaced+close to the old pid via
    the registry's message — the old socket receives `{:takeover_close}` and
    closes itself. The registry has already swapped the slot, so the old
    socket's unregister cannot evict the new one.
  - Keepalive: WebSock ping/pong with a pong deadline (Process.send_after);
    silence past the deadline closes the socket. Defaults: ping every 30s,
    pong timeout 90s.
  - Rate limits are GLOBAL per deviceId and live in ConnRegistry (a
    per-process window would reset on reconnect): typing 2/s, pair 5/min.

  Inbound frames (server.ts message handler, same semantics):
  - pair_request: protocolVersion must be 1; pair via Devices; reply
    pair_result; close.
  - auth: token → Devices.by_token; failure reasons: pending device →
    device_not_approved, allowlisted-but-stale-token → token_revoked, unknown
    → auth_failed. Success: seed the main stream if absent (defaults come
    from the gateway config — NEVER hardcoded here), register, replay, live.
  - message: id must start with "c_" (else invalid_message); content ≤ 64KiB
    utf8 (else payload_too_large); session ownership enforced (not_found);
    then verb "post" through Dispatch. dedupe: :duplicate → ack again;
    :conflict → invalid_message and NO ack.
  - stream_read: write read state, echo stream_read_state.
  - typing: rate-limited, otherwise dropped silently (not fanned out in v1).
  - anything else: invalid_message.
  """

  @behaviour WebSock

  @max_content_bytes 64 * 1024

  @typedoc "Socket state; `conn_ref` is nil until authed."
  @type t :: %__MODULE__{
          conn_ref: reference() | nil,
          user_id: String.t() | nil,
          device_id: String.t() | nil,
          is_admin: boolean(),
          phase: :unauthed | :replaying | :live,
          buffer: [map()],
          deps: map()
        }

  defstruct conn_ref: nil,
            user_id: nil,
            device_id: nil,
            is_admin: false,
            phase: :unauthed,
            buffer: [],
            deps: %{}

  @impl true
  def init(deps) do
    _ = @max_content_bytes
    raise "TODO(sol): #{inspect(deps)}"
  end

  @impl true
  def handle_in(frame, state) do
    raise "TODO(sol): decode JSON (malformed → invalid_message), route by type — #{inspect({frame, state})}"
  end

  @impl true
  def handle_info(msg, state) do
    raise "TODO(sol): {:push, payload} (buffer or send by phase), {:takeover_close}, pong deadline — #{inspect({msg, state})}"
  end

  @impl true
  def terminate(reason, state) do
    raise "TODO(sol): ConnRegistry.unregister(conn_ref) if authed — #{inspect({reason, state})}"
  end
end
