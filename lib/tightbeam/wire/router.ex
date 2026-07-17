defmodule Tightbeam.Wire.Router do
  @moduledoc """
  HTTP control plane + WS upgrade — a Plug router served by Bandit on the ONE
  gateway port (TS reference: src/wire/http.ts; its test file is the
  acceptance oracle). The client derives its HTTP base from the ws URL, so WS
  and HTTP share the port: GET /ws upgrades to `Tightbeam.Wire.Socket` via
  WebSockAdapter; everything else is JSON.

  Conventions (identical to TS — imitate, don't improve):
  - Bearer auth on everything except /version. Two credential classes here:
    device tokens (Devices.by_token) for client routes; the gateway-owned
    cliToken for POST /agent/dispatch (the tightbeam CLI facade).
  - Errors: `{"error": {"code", "message"?}}` + matching HTTP status.
  - Anything that CHANGES state goes through Dispatch as a verb — handlers
    here NEVER write to Org/Projection/Devices directly. Reads query directly.

  Routes (http.ts as-built):
  - GET  /version            — no auth; version, loop-lag/health numbers.
  - GET  /streams            — device auth; owner-only catalog (even admins).
  - POST /streams            — spawn verb. POST /streams/:key/rename — tune.
  - DELETE /streams/:key     — retire verb.
  - GET  /sessions/:key/status — sessionStatus projection (picker surface).
  - POST /sessions/:key/control — control actions mapped to verbs
    (cancel_current_run → cancel, set_model → tune; the rest are
    unsupported-with-reason per the capability advertisement).
  - POST /upload             — multipart, ≤ 32MiB, stored via Assets (E3;
    returns not_implemented until Assets is ported).
  - POST /agent/dispatch     — cliToken auth; body {verb, target?, params,
    as|asUser} → origin resolution; verb must be in the closed AGENT_VERBS
    set (post excluded on purpose: an agent DM IS a wake-with-prompt).

  Elixir shape: `use Plug.Router`; deps (handlers table, db, cli_token,
  session_status fun) arrive via `init_opts` from the composition root and
  ride `conn.private`. Handlers run in the request process — fine, because
  every verb is bounded (long work goes through the Ledger).
  """

  use Plug.Router

  plug :match
  plug :dispatch

  match _ do
    # TODO(sol): implement routes per moduledoc; this catch-all 404s in the
    # TS error shape.
    send_resp(conn, 404, ~s({"error":{"code":"not_found"}}))
  end
end
