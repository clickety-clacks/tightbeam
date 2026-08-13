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
  - Escalation: `202` + `{"decisionPending": {"decisionRequestId", "code",
    "message"}}` — the THIRD dispatch outcome, neither a result nor an error.
    The verb halted without denying and its decision-request is open
    (escalation-substrate-v1 §2, §12 case 1), so it gets its own envelope
    rather than being dressed as a failure the caller could have avoided.
  - Anything that CHANGES state goes through Dispatch as a verb — handlers
    here NEVER write to Org/Projection/Devices directly. Reads query directly.

  Routes — the PATHS ARE THE WIRE CONTRACT, verbatim from http.ts as-built
  (the real client and the black-box drivers speak these; never rename):
  - GET  /version              — no auth; protocolVersion + health numbers.
  - POST /agent/dispatch       — cliToken auth; body {verb, target?, params,
    as|asUser} → origin resolution; verb must be in the closed AGENT_VERBS
    set (post excluded on purpose: an agent DM IS a wake-with-prompt).
  - POST /agent/tool-call-observed — SESSION token only; no body. The
    substrate-reserved PreToolUse hook reporting that this session is about to
    run `tightbeam artifact-record`. Not a verb: it writes no domain state, only
    the in-memory observation window Artifacts reads for its evidence class.
  - GET  /api/streams          — device auth; owner-only catalog (even admins).
  - POST /api/streams          — spawn verb (displayName + idempotencyKey).
  - GET  /api/trackable-sessions — static {sessions: []} (client probe).
  - PATCH  /api/streams/:key   — tune(rename). DELETE /api/streams/:key —
    retire (absent session + idempotencyKey still dispatches; else 404).
  - GET  /api/session-status?sessionKey= — sessionStatus projection
    (owner or admin; picker surface).
  - POST /api/session-control  — body {sessionKey, action}; actions map to
    verbs (cancel_current_run → cancel, set_* → tune); unknown action → 400.
  - POST /upload, GET /download/:id — owner-scoped Assets; admins may download
    any asset.

  Elixir shape: `use Plug.Router`; deps (handlers table, db, cli_token,
  session_status fun) arrive via `init_opts` from the composition root and
  ride `conn.private`. Handlers run in the request process — fine, because
  every verb is bounded (long work goes through the Ledger).
  """

  use Plug.Router

  alias Tightbeam.{Assets, CliCompatibility, Devices, Dispatch, Org, Roles, WorkState}
  alias Tightbeam.Wire.{Payloads, Socket}

  Module.register_attribute(__MODULE__, :agent_verbs, persist: true)

  @agent_verbs ~w(wake condition facts-read artifact-record artifact-get artifacts spawn retire critical inspect cancel tune approve-device deny-device revoke-device promote-user add-user config register-host host-env-set host-env-list host-env-unset update-clients identity-edit identity-status identity-relearn identity-repoint learn unlearn kungfu-list identity-apply kungfu-scaffold onboard role-create role-bind role-rm role-list assign dispatch assignment-get attest attests revoke-assignment reopen-assignment assignments work-item-create work-item-get work-item-trace work-item-list work-item-update work-item-icebox work-item-reopen work-item-close work-item-fail rule effort-rule waive revoke-waiver withdraw decision-requests decision-request transcript attend toplines topline coordination-share harness-processes)
  @max_upload_bytes 32 * 1024 * 1024
  @multipart_opts Plug.Parsers.init(
                    parsers: [{:multipart, length: @max_upload_bytes + 1_000_000}],
                    pass: ["*/*"]
                  )

  @impl Plug
  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:tightbeam_deps, Map.new(opts))
    |> super(opts)
  end

  plug(:match)
  plug(:dispatch)

  # The TS reference upgrades WebSocket on ANY path (bare WebSocketServer);
  # the client connects at "/". Upgrade wherever the upgrade header appears,
  # at "/" and "/ws" alike — the path is not part of the WS contract.
  get "/" do
    upgrade_socket(conn)
  end

  get "/ws" do
    upgrade_socket(conn)
  end

  defp upgrade_socket(conn) do
    if Plug.Conn.get_req_header(conn, "upgrade") == ["websocket"] do
      WebSockAdapter.upgrade(conn, Socket, deps(conn), max_frame_size: 2 * 1024 * 1024)
    else
      error(conn, 404, "not_found")
    end
  end

  get "/version" do
    coordinator = deps(conn)[:adapter_coordinator] || Tightbeam.AdapterCoordinator

    health =
      if Process.whereis(coordinator),
        do: Tightbeam.AdapterCoordinator.health(coordinator),
        else: %{}

    json(conn, 200, %{"protocolVersion" => 1, "server" => "tightbeam", "adapters" => health})
  end

  get "/harnesses" do
    with {:ok, _auth} <- cli_auth(conn) do
      bytes =
        "[" <>
          Enum.map_join(Tightbeam.Harness.all(), ",", & &1.wire_projection()) <>
          "]"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, bytes)
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  post "/agent/dispatch" do
    with {:ok, auth} <- cli_auth(conn),
         {:ok, body, conn} <- read_json(conn),
         {:ok, verb} <- required_string(body["verb"]),
         :ok <- allowed_agent_verb(verb),
         {:ok, origin, principal} <- agent_identity(body, auth, conn),
         {:ok, session_key, target_meta} <- typed_target(verb, body, conn) do
      call = %{
        verb: verb,
        origin: origin,
        principal: principal,
        session_key: artifact_caller_session(verb, session_key, principal),
        target_role: target_meta.role,
        role_fallback: target_meta.fallback,
        params: atomize_params(verb, body["params"] || %{})
      }

      dispatch_response(conn, call, 200, &%{"result" => &1})
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  # The hook seam (artifact-carrier-proposal-v1 §4.1). The turn is resolved HERE,
  # at observation time, because the `artifact-record` that follows may arrive
  # after that turn has ended — a slow command spanning a turn boundary, or a
  # cancel, which terminalizes before it kills the serving task.
  #
  # A SESSION token is required: the org cliToken names no session, so there is
  # no window to open for it. The org's own principal never runs inside a turn.
  post "/agent/tool-call-observed" do
    with {:ok, {:session, session}} <- session_cli_auth(conn) do
      :ok = Tightbeam.TurnObservations.observe(db(conn), session.session_key)
      json(conn, 200, %{"observed" => true})
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  get "/api/streams" do
    with {:ok, device} <- device_auth(conn) do
      streams =
        Org.list_for_user(db(conn), device.user_id, false) |> Enum.map(&Payloads.stream_session/1)

      json(conn, 200, %{"streams" => streams})
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  get "/api/org-options" do
    with {:ok, _device} <- device_auth(conn) do
      json(conn, 200, Tightbeam.Gateway.org_options())
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  get "/api/trackable-sessions" do
    with {:ok, _device} <- device_auth(conn) do
      json(conn, 200, %{"sessions" => []})
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  post "/api/streams" do
    with {:ok, device} <- device_auth(conn),
         {:ok, body, conn} <- read_json(conn),
         :ok <- streams_overrides_unsupported(body),
         {:ok, display_name} <- required_string(body["displayName"]),
         {:ok, idempotency_key} <- required_string(body["idempotencyKey"]) do
      picker =
        for {k, atom} <- [
              {"harness", :harness},
              {"host", :host},
              {"archetype", :archetype}
            ],
            is_binary(body[k]) and body[k] != "",
            into: %{},
            do: {atom, body[k]}

      picker = Map.merge(picker, model_params(body))

      call = %{
        verb: "spawn",
        origin: "user:#{device.user_id}",
        session_key: nil,
        params: Map.merge(%{display_name: display_name, idempotency_key: idempotency_key}, picker)
      }

      dispatch_response(conn, call, 201, & &1)
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  patch "/api/streams/:key" do
    with {:ok, device} <- device_auth(conn),
         {:ok, decoded_key} <- decode_session_key_param(key),
         {:ok, session} <- owned_session(decoded_key, device, conn),
         {:ok, body, conn} <- read_json(conn),
         {:ok, display_name} <- required_string(body["displayName"]) do
      call = %{
        verb: "tune",
        origin: "user:#{device.user_id}",
        session_key: session.session_key,
        params: %{setting: "rename", display_name: display_name}
      }

      dispatch_response(conn, call, 200, & &1)
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  delete "/api/streams/:key" do
    with {:ok, device} <- device_auth(conn),
         {:ok, body, conn} <- read_json(conn),
         {:ok, decoded_key} <- decode_session_key_param(key),
         {:ok, session_key} <- retire_target(decoded_key, body, device, conn) do
      params =
        if is_binary(body["idempotencyKey"]),
          do: %{idempotency_key: body["idempotencyKey"]},
          else: %{}

      call = %{
        verb: "retire",
        origin: "user:#{device.user_id}",
        session_key: session_key,
        params: params
      }

      dispatch_response(conn, call, 200, & &1)
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  get "/api/session-status" do
    conn = Plug.Conn.fetch_query_params(conn)
    key = conn.query_params["sessionKey"] || ""

    with {:ok, device} <- device_auth(conn),
         {:ok, _session} <- visible_session(key, device, conn),
         status when not is_nil(status) <- session_status(conn).(key) do
      json(conn, 200, status)
    else
      nil -> error(conn, 404, "not_found")
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  get "/api/work" do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, device} <- device_auth(conn),
         {:ok, statuses} <- work_status_filter(conn.query_params["status"]),
         {:ok, state} <- work_state_filter(conn.query_params["state"]) do
      filters = %{
        status: statuses,
        state: state,
        session_key: conn.query_params["sessionKey"],
        owner_user_id: if(device.is_admin, do: nil, else: device.user_id)
      }

      json(conn, 200, WorkState.list(db(conn), filters))
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  get "/api/work/:id" do
    with {:ok, device} <- device_auth(conn),
         detail when not is_nil(detail) <- WorkState.detail(db(conn), id),
         true <- visible_assignment_detail?(detail, device, conn) do
      json(conn, 200, detail)
    else
      nil -> error(conn, 404, "unknown_assignment")
      false -> error(conn, 404, "unknown_assignment")
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  get "/api/work-items" do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, device} <- device_auth(conn) do
      filters = %{
        session_key: conn.query_params["sessionKey"],
        owner_user_id: if(device.is_admin, do: nil, else: device.user_id)
      }

      json(conn, 200, WorkState.list_items(db(conn), filters))
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  get "/api/work-items/:id" do
    with {:ok, device} <- device_auth(conn),
         detail when not is_nil(detail) <- WorkState.item_detail(db(conn), id),
         true <- visible_item_detail?(detail, device, conn) do
      json(conn, 200, detail)
    else
      nil -> error(conn, 404, "unknown_work_item")
      false -> error(conn, 404, "unknown_work_item")
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  post "/api/session-control" do
    with {:ok, device} <- device_auth(conn),
         {:ok, body, conn} <- read_json(conn),
         key = to_string(body["sessionKey"] || ""),
         {:ok, _session} <- visible_session(key, device, conn),
         {:ok, verb, params} <- control_call(body) do
      action = body["action"]
      call = %{verb: verb, origin: "user:#{device.user_id}", session_key: key, params: params}
      control_response(conn, call, key, action)
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  post "/upload" do
    with {:ok, device} <- device_auth(conn),
         {:ok, upload, conn} <- read_upload(conn) do
      data = File.read!(upload.path)

      row =
        Assets.put(
          db(conn),
          deps(conn).base_dir,
          device.user_id,
          upload.content_type,
          upload.filename,
          data
        )

      json(conn, 200, %{asset_id: row.asset_id, mime_type: row.mime_type, size: row.size})
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  get "/download/:asset_id" do
    with {:ok, device} <- device_auth(conn),
         {:ok, asset} <- visible_asset(asset_id, device, conn) do
      conn
      |> Plug.Conn.put_resp_header("content-type", asset.mime_type)
      |> Plug.Conn.send_file(
        200,
        Assets.file_path(deps(conn).base_dir, asset.asset_id),
        0,
        asset.size
      )
    else
      {:error, status, code, message} -> error(conn, status, code, message)
    end
  end

  match _ do
    error(conn, 404, "not_found")
  end

  defp deps(conn), do: conn.private.tightbeam_deps
  defp db(conn), do: deps(conn)[:db] || Tightbeam.DB
  defp handlers(conn), do: Map.fetch!(deps(conn), :handlers)

  defp session_status(conn),
    do: deps(conn)[:session_status] || (&Tightbeam.Gateway.session_status/1)

  defp cli_auth(conn) do
    with :ok <- cli_version_compatible(conn) do
      cli_token_auth(conn)
    end
  end

  defp cli_version_compatible(conn) do
    version =
      case Plug.Conn.get_req_header(conn, "x-tightbeam-cli-version") do
        [version] -> version
        _ -> nil
      end

    case CliCompatibility.check(version) do
      :ok -> :ok
      {:error, message} -> {:error, 426, "incompatible_cli", message}
    end
  end

  defp cli_token_auth(conn) do
    token =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end

    cond do
      token == deps(conn).cli_token -> {:ok, :org}
      session = token && Org.by_cli_token(db(conn), token) -> {:ok, {:session, session}}
      true -> {:error, 401, "auth_failed", nil}
    end
  end

  defp session_cli_auth(conn) do
    case cli_auth(conn) do
      {:ok, {:session, _session} = session} -> {:ok, session}
      {:ok, :org} -> {:error, 403, "session_required", "a session token names the caller's turn"}
      error -> error
    end
  end

  defp device_auth(conn) do
    token =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end

    case token && Devices.by_token(db(conn), token) do
      nil -> {:error, 401, "auth_failed", nil}
      device -> {:ok, device}
    end
  end

  defp allowed_agent_verb(verb) do
    if verb in @agent_verbs,
      do: :ok,
      else: {:error, 400, "invalid_message", "verb not allowed: #{verb}"}
  end

  defp agent_identity(%{"asProcess" => "tightbeam"}, :org, _conn) do
    {:error, 403, "reserved_origin", "process:tightbeam is reserved to the substrate"}
  end

  defp agent_identity(body, :org, conn) do
    with {:ok, origin} <- agent_origin(body, conn) do
      principal =
        cond do
          is_binary(body["as"]) and body["as"] != "" ->
            nil

          is_binary(body["asUser"]) and body["asUser"] != "" ->
            {:user, body["asUser"]}

          is_binary(body["asProcess"]) and body["asProcess"] != "" ->
            {:process, body["asProcess"]}

          true ->
            nil
        end

      {:ok, origin, principal}
    end
  end

  defp agent_identity(body, {:session, session}, conn) do
    roles = Roles.for_session(db(conn), session.session_key)
    session_principal = {:session, session.session_key}

    cond do
      is_binary(body["as"]) and body["as"] != "" ->
        role = body["as"]

        case Roles.resolve(db(conn), role) do
          {:ok, key, false} when key == session.session_key ->
            {:ok, "agent:#{role}", session_principal}

          _ ->
            held = if roles == [], do: "none", else: Enum.join(roles, ", ")

            {:error, 403, "role_not_held",
             "role #{role} is not held by this session; held roles: #{held}"}
        end

      is_binary(body["asUser"]) and body["asUser"] != "" ->
        if body["asUser"] == session.owner_user_id do
          {:ok, "user:#{session.owner_user_id}", {:user, session.owner_user_id}}
        else
          {:error, 403, "identity_not_yours", "this session belongs to #{session.owner_user_id}"}
        end

      is_binary(body["asProcess"]) and body["asProcess"] != "" ->
        {:error, 403, "identity_not_yours", "a session token cannot act as a process"}

      length(roles) == 1 ->
        {:ok, "agent:#{hd(roles)}", session_principal}

      roles == [] and session.is_built_in ->
        {:ok, "user:#{session.owner_user_id}", session_principal}

      roles == [] ->
        {:error, 403, "no_role",
         "this session holds no role; its owner must bind one, or pass --as-user #{session.owner_user_id}"}

      true ->
        {:error, 400, "ambiguous_identity",
         "this session holds several roles (#{Enum.join(roles, ", ")}); pass --as <role>"}
    end
  end

  defp agent_origin(%{"asProcess" => "tightbeam"}, _conn) do
    {:error, 403, "reserved_origin", "process:tightbeam is reserved to the substrate"}
  end

  defp agent_origin(body, conn) do
    cond do
      is_binary(body["as"]) and body["as"] != "" ->
        role = body["as"]

        case Roles.resolve(db(conn), role) do
          {:ok, _session_key, false} ->
            {:ok, "agent:#{role}"}

          _ ->
            {:error, 400, "invalid_message", "unknown or unbound role: #{role}"}
        end

      is_binary(body["asUser"]) and body["asUser"] != "" ->
        {:ok, "user:#{body["asUser"]}"}

      is_binary(body["asProcess"]) and body["asProcess"] != "" ->
        # Third origin class (closed set: user | agent | process): automation
        # that is neither a person nor a session — cron, CI, webhooks.
        # Local-trust like --as (named, not authenticated — v1 decision);
        # powers are narrow: wake + cancel-wake + condition, nothing else.
        {:ok, "process:#{body["asProcess"]}"}

      true ->
        {:error, 400, "invalid_message", "as (role) or asUser required"}
    end
  end

  # Strictly typed target seam (spec Addendum A): the reference TYPE is
  # carried by the field name — sessionKey | role | userId, exactly one —
  # never inferred from a string's shape. Nothing here classifies; a
  # request that offers none, several, or the retired `target` field is
  # refused naming the seam. Modeled on the as/asUser/asProcess
  # attribution fields, the seam that was always right.
  @target_fields ["sessionKey", "role", "userId"]

  # Verbs with no legitimate top-level typed-target use. A LOCAL declaration
  # about these verbs, decided here rather than in the handler because the router
  # can answer FIRST — `typed_target/3` would otherwise resolve a volunteered
  # sessionKey through `Org.get/2` and hand back an identifying 404. This clause
  # runs before that lookup and before the generic target-shape refusals, so the
  # response is identical for an unknown key, a readable session, a forbidden
  # session, retired `target` syntax, and several targeting fields at once: the
  # router never queries the volunteered target's existence. The retrieval key
  # travels as an ordinary body param instead.
  # `toplines`/`topline` join transcript here for the same reason and one more:
  # `--session <key>` is a COHORT FILTER over creator identity, not a target, so
  # resolving it as one would turn a roster filter into a session-existence
  # oracle. Both verbs' selectors travel as ordinary body params.
  # `coordination-share` joins them for transcript's exact reason: its
  # `--session <key>` names the session being MEASURED, and resolving it as a
  # target would answer "does this session exist?" ahead of the read's own
  # owner-or-admin check. Same not-found body either way.
  @non_target_verbs ~w(transcript toplines topline coordination-share)

  # PRESENCE of the field, not the type of its value. `sessionKey: null` — and a
  # number, a boolean or an object — is still a caller volunteering a typed target
  # to a verb that has none, and must land on the SAME refusal a string does. The
  # generic clauses below filter on `is_binary/1` for their own reasons (they go on
  # to resolve the value), which is why this check cannot reuse `given`: doing so
  # returned 200 and emitted a verb event for a null-valued key.
  defp volunteers_typed_target?(body) do
    Enum.any?(["target" | @target_fields], &Map.has_key?(body, &1))
  end

  defp typed_target(verb, body, conn) do
    given = Enum.filter(@target_fields, &is_binary(body[&1]))

    cond do
      verb in @non_target_verbs and volunteers_typed_target?(body) ->
        {:error, 400, "invalid_message", "#{verb} takes no typed target"}

      is_binary(body["target"]) ->
        {:error, 400, "invalid_message", ~s("target" is retired: use sessionKey | role | userId)}

      length(given) > 1 ->
        {:error, 400, "invalid_message", "exactly one of sessionKey, role, userId"}

      verb == "retire" and (given == ["role"] or given == ["userId"]) ->
        {:error, 400, "invalid_message", "retire takes sessionKey only"}

      verb in ["assign", "dispatch", "assignments"] and given == ["userId"] ->
        {:error, 400, "invalid_target_kind",
         "assignments are held by sessions; target a sessionKey or role"}

      verb in ["assign", "dispatch"] and given == [] ->
        {:error, 400, "missing_target", "#{verb} requires a sessionKey or role target"}

      given == [] ->
        {:ok, nil, %{role: nil, fallback: false}}

      given == ["sessionKey"] ->
        case Org.get(db(conn), body["sessionKey"]) do
          nil ->
            {:error, 404, "not_found", "unknown sessionKey: #{body["sessionKey"]}"}

          %{state: "retired"} when verb in ["assign", "dispatch"] ->
            {:error, 400, "session_retired", "assignments require an active holder session"}

          session ->
            {:ok, session.session_key, %{role: nil, fallback: false}}
        end

      given == ["userId"] ->
        if Devices.user(db(conn), body["userId"]),
          do: {:ok, Org.personal_session_key(body["userId"]), %{role: nil, fallback: false}},
          else: {:error, 404, "not_found", "unknown userId: #{body["userId"]}"}

      given == ["role"] ->
        case Roles.resolve(db(conn), body["role"]) do
          {:ok, session_key, fallback} ->
            {:ok, session_key, %{role: body["role"], fallback: fallback}}

          {:error, %{code: "unknown_role"}} ->
            {:error, 404, "not_found", "unknown role: #{body["role"]}"}
        end
    end
  end

  defp artifact_caller_session("artifact-record", nil, {:session, session_key}),
    do: session_key

  defp artifact_caller_session(_verb, session_key, _principal), do: session_key

  # Plug decodes %20 in path segments but leaves '+' literal (that's a query-string
  # convention, not a path one) — session keys carry a space, never a literal '+'.
  #
  # The clawline iOS client sometimes double-percent-encodes the :key segment (a
  # space becomes %2520 instead of %20). Plug's router decodes the segment once
  # before we see it, so three additional passes preserve the four-pass wire cap.
  # Stop at the first fixed point. The "+" -> " " replacement runs first so an
  # explicitly-escaped literal plus (%2B, which only becomes "+" via the decode
  # loop) survives the heuristic meant for raw '+' characters.
  @session_key_decode_passes 3
  @malformed_percent_escape ~r/%(?![0-9A-Fa-f]{2})/

  defp decode_session_key_param(key) do
    with {:ok, decoded} <-
           key
           |> String.replace("+", " ")
           |> decode_session_key_percent(@session_key_decode_passes),
         false <- String.contains?(decoded, "/") do
      {:ok, decoded}
    else
      _ -> {:error, 400, "invalid_session_key", nil}
    end
  end

  defp decode_session_key_percent(key, 0) do
    if Regex.match?(@malformed_percent_escape, key), do: :error, else: {:ok, key}
  end

  defp decode_session_key_percent(key, passes_left) do
    if Regex.match?(@malformed_percent_escape, key) do
      :error
    else
      case URI.decode(key) do
        ^key -> {:ok, key}
        decoded -> decode_session_key_percent(decoded, passes_left - 1)
      end
    end
  rescue
    ArgumentError -> :error
  end

  defp owned_session(key, device, conn) do
    case Org.get(db(conn), key) do
      %{owner_user_id: owner} = session when owner == device.user_id -> {:ok, session}
      _ -> {:error, 404, "not_found", nil}
    end
  end

  defp visible_session(key, device, conn) do
    case Org.get(db(conn), key) do
      %{owner_user_id: owner} = session when owner == device.user_id or device.is_admin ->
        {:ok, session}

      _ ->
        {:error, 404, "not_found", nil}
    end
  end

  defp visible_assignment_detail?(_detail, %{is_admin: true}, _conn), do: true

  defp visible_assignment_detail?(detail, device, conn) do
    Org.get(db(conn), detail.assignment.holderKey).owner_user_id == device.user_id
  end

  defp visible_item_detail?(_detail, %{is_admin: true}, _conn), do: true

  defp visible_item_detail?(detail, device, conn) do
    # Owner path (observability-v1 amendment): the owner sees its item even
    # with no assignments; otherwise fall back to assignment-holder ownership.
    detail.workItem.ownerUserId == device.user_id or
      Enum.any?(detail.assignments, fn assignment ->
        Org.get(db(conn), assignment.holderKey).owner_user_id == device.user_id
      end)
  end

  defp work_status_filter(nil), do: {:ok, nil}

  defp work_status_filter(value) do
    statuses = String.split(value, ",")

    if Enum.all?(statuses, &(&1 in ~w(open active stranded claims-done verified abandoned))),
      do: {:ok, statuses},
      else: {:error, 400, "invalid_status", nil}
  end

  defp work_state_filter(nil), do: {:ok, "all"}
  defp work_state_filter(value) when value in ~w(open closed all), do: {:ok, value}
  defp work_state_filter(_), do: {:error, 400, "invalid_state_filter", nil}

  defp visible_asset(asset_id, device, conn) do
    case Assets.get(db(conn), asset_id) do
      %{owner_user_id: owner} = asset when owner == device.user_id or device.is_admin ->
        {:ok, asset}

      _ ->
        {:error, 404, "not_found", nil}
    end
  end

  defp read_upload(conn) do
    conn = Plug.Parsers.call(conn, @multipart_opts)

    case conn.body_params["file"] do
      %Plug.Upload{} = upload ->
        if File.stat!(upload.path).size > @max_upload_bytes,
          do: {:error, 413, "payload_too_large", nil},
          else: {:ok, upload, conn}

      _ ->
        {:error, 400, "invalid_message", "multipart field 'file' required"}
    end
  rescue
    Plug.Parsers.RequestTooLargeError -> {:error, 413, "payload_too_large", nil}
  end

  defp retire_target(key, body, device, conn) do
    session = Org.get(db(conn), key)

    cond do
      match?(%{owner_user_id: owner} when owner == device.user_id, session) -> {:ok, key}
      is_nil(session) and is_binary(body["idempotencyKey"]) -> {:ok, key}
      true -> {:error, 404, "not_found", nil}
    end
  end

  # A model identity crosses the wire as NAMED FIELDS. The router carries them
  # across unchanged — it does not parse `model`, because a bracket in that
  # value is the vendor's context variant and reading it as one of our effort
  # levels is the whole defect this seam exists to prevent. A client that
  # echoes back the row identity this seam issued is resolved against the
  # catalog by the gateway (`resolve_selection/3`), never by a regex here.
  defp model_params(body) do
    Enum.reduce(~w(model context effort), %{}, fn key, params ->
      case Map.fetch(body, key) do
        {:ok, value} when is_binary(value) and value != "" ->
          Map.put(params, String.to_existing_atom(key), value)

        # NAMED, AND NAMED EMPTY. `null` and `""` are the client saying "this
        # field, with nothing in it" — the vendor's default window, no tier —
        # which is a different request from omitting the key. Dropping them
        # here would undo at the outermost seam the distinction every layer
        # below is built to carry, and the caller's explicit choice would
        # arrive as silence and be inherited over.
        {:ok, value} when is_nil(value) or value == "" ->
          Map.put(params, String.to_existing_atom(key), nil)

        # Anything else is not a field value this seam knows how to read, and
        # it is not turned into one by guessing.
        _ ->
          params
      end
    end)
  end

  defp control_call(%{"action" => "cancel_current_run"}), do: {:ok, "cancel", %{}}

  defp control_call(%{"action" => action}) when action in ~w(adopt unadopt),
    do: {:ok, "tune", %{setting: "adopt", adopted: action == "adopt"}}

  defp control_call(%{"action" => "set_model", "model" => model} = body)
       when is_binary(model),
       do: {:ok, "tune", Map.put(model_params(body), :setting, "set_model")}

  defp control_call(%{"action" => "set_harness", "harness" => harness} = body),
    do:
      {:ok, "tune",
       body
       |> model_params()
       |> Map.put(:setting, "set_harness")
       |> Map.put(:harness, harness)}

  defp control_call(%{"action" => action} = body)
       when action in ~w(set_thinking set_reasoning set_fast_mode set_mode set_verbosity) do
    key =
      %{
        "set_thinking" => "thinkingLevel",
        "set_reasoning" => "reasoningLevel",
        "set_fast_mode" => "fastMode",
        "set_mode" => "mode",
        "set_verbosity" => "verbosity"
      }[action]

    {:ok, "tune", Map.put(%{setting: action}, String.to_atom(key), body[key])}
  end

  defp control_call(%{"action" => action}),
    do: {:error, 400, "invalid_message", "unknown action: #{action}"}

  defp control_call(_), do: {:error, 400, "invalid_message", "unknown action: "}

  defp dispatch_response(conn, call, success_status, shape) do
    case Dispatch.dispatch(db(conn), handlers(conn), call) do
      {:ok, result} ->
        json(conn, success_status, shape.(result))

      {:error, result} ->
        error(conn, error_status(result[:code]), result[:code], result[:message])

      {:decision_pending, decision_request_id} ->
        decision_pending(conn, decision_request_id)
    end
  end

  # THE THIRD OUTCOME. `Dispatch.dispatch/3` has always declared three returns and
  # this seam served two, so an escalating verb reached `case` with no clause:
  # CaseClauseError, empty body, and a CLI dying on EOF. The effect had already
  # applied by then — the decision-request opens and the handler does not run —
  # so only the answer was lost, which is why DB-asserting tests stayed green
  # while every real caller hard-failed.
  #
  # NOT an error envelope. escalation-substrate-v1 §2 pins the caller-facing tag
  # as "distinct from any `{:deny,…}`", and §12's first case is "halt without
  # deny": nothing was refused, the action is waiting on its owner. 202 says
  # exactly that in the wire's own vocabulary — accepted, not yet complete —
  # where any 4xx would tell the caller it did something wrong.
  defp decision_pending(conn, decision_request_id) do
    json(conn, 202, %{
      "decisionPending" => %{
        "decisionRequestId" => decision_request_id,
        "code" => "decision_pending",
        "message" => "this action needs an owner decision; request #{decision_request_id} is open"
      }
    })
  end

  defp control_response(conn, call, session_key, action) do
    case Dispatch.dispatch(db(conn), handlers(conn), call) do
      {:ok, result} ->
        control_json(conn, result, session_key, action)

      {:error, %{code: "server_error", message: message}} ->
        json(conn, 200, %{
          "ok" => false,
          "sessionKey" => session_key,
          "action" => action,
          "code" => "control_failed",
          "message" => message
        })

      {:error, result} ->
        control_json(conn, result, session_key, action)
    end
  end

  # INVARIANT: a non-ok control response always carries a code.
  #
  # `ok: false` on its own tells a client that something did not happen and nothing
  # about whether to retry, re-authorize, or report a bug — a rejection and a fault
  # are the same two bytes. Handlers are expected to supply their own code, and all
  # of them do; the fallback exists so that a path which forgets one, or a future
  # handler that returns a bare false, still cannot reach a client as an unexplained
  # negative. Enforced HERE because this is the one seam every session-control
  # response passes through, which is what makes it an invariant rather than a
  # convention.
  defp control_json(conn, result, session_key, action) do
    case session_status(conn).(session_key) do
      {:error, status, code, message} ->
        error(conn, status, code, message)

      session_status ->
        ok = Map.get(result, :ok, not Map.has_key?(result, :code))
        code = result[:code] || if(ok, do: nil, else: "control_failed")

        %{
          "ok" => ok,
          "sessionKey" => session_key,
          "action" => action,
          "status" => session_status
        }
        |> put_optional("code", code)
        |> put_optional("message", result[:message])
        |> then(&json(conn, 200, &1))
    end
  end

  defp error_status("forbidden"), do: 403

  defp error_status(code)
       when code in ["not_holder", "not_authorized", "process_denied", "principal_required"],
       do: 403

  defp error_status("not_found"), do: 404
  defp error_status("unknown_assignment"), do: 404
  defp error_status("unknown_work_item"), do: 404
  defp error_status("server_error"), do: 500
  defp error_status(_), do: 400

  defp read_json(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, "", conn} ->
        {:ok, %{}, conn}

      {:ok, body, conn} ->
        case JSON.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded, conn}
          _ -> {:error, 400, "invalid_message", nil}
        end

      _ ->
        {:error, 400, "invalid_message", nil}
    end
  end

  defp required_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp required_string(_), do: {:error, 400, "invalid_message", nil}

  defp streams_overrides_unsupported(body) do
    if Map.has_key?(body, "overrides") do
      {:error, 400, "invalid_overrides",
       "overrides are unsupported on /api/streams; use /agent/dispatch"}
    else
      :ok
    end
  end

  # SUBSTRATE-INTERNAL params, PER VERB: fields a client may not set on that verb
  # because the substrate is their only legitimate author. `wake.assignmentId` is
  # the wake's attribution CARRIER — a client-supplied one would forge
  # wake -> turn -> trace attribution, which Law 0 forbids (cross-review F6), so
  # it is stripped before the handler sees it.
  #
  # Scoped per verb deliberately: `assignmentId` is an ORDINARY caller param on
  # attest/assign/dispatch/effort-rule, which name the assignment they act on. A
  # blanket strip breaks all of those (the CLI round-trip suite proves it), so the
  # spec's "stripped from any agent/dispatch param map" is read as scoped to the
  # carrier it is written about, not to the parameter name everywhere.
  @substrate_only_params %{
    "wake" => ~w(assignment_id)a,
    "work-item-create" => ~w(created_in_turn_seq created_context_known)a,
    # The artifact's turn edge and the class of evidence behind it are the
    # substrate's own observation, resolved in `Artifacts.record/2` from the hook
    # window and the ledger. A caller-filled edge would be forgeable, which is
    # precisely why no wire carrier can be proof (artifact-carrier-proposal-v1
    # §1.2) — so the words are refused entry rather than trusted and checked.
    "artifact-record" => ~w(recorded_message_id recorded_turn_evidence)a,
    # `attend` carries the agent's TIER election and nothing else. The turn it
    # applies to is the caller's running turn, derived by the substrate, and the
    # raw column value is never accepted — so a caller cannot elect on someone
    # else's turn or write an arbitrary tier. With today's handler these names are
    # inert (it reads only `:high`); the strip pins the boundary so a later handler
    # cannot start honoring them by accident.
    "attend" => ~w(turn_seq session_key reply_attention attention_tier)a
  }

  # WIRE WORD -> HANDLER ATOM, PER VERB: the few params whose wire spelling and
  # handler spelling are deliberately different, because the word the caller says
  # and the edge it sets are not the same noun. `assign --reviews <id>` names the
  # REVIEWED assignment and sets `reviewsAssignmentId`; p3-observables-producers-v1
  # §Review-of relation pins both names ("wire `reviews`, atomized
  # `:reviews_assignment_id`"). Underscoring alone yields `:reviews`, which no
  # handler reads, so the link silently never landed.
  @param_aliases %{
    "assign" => %{reviews: :reviews_assignment_id}
  }

  @doc false
  # Exposed so the Law-0 boundary strip is provable at its own seam.
  def atomize_params_for_test(verb, params), do: atomize_params(verb, params)

  defp atomize_params(verb, params) when is_map(params) do
    aliases = Map.get(@param_aliases, verb, %{})

    params
    |> Map.new(fn {key, value} ->
      atom = key |> Macro.underscore() |> String.to_atom()
      {Map.get(aliases, atom, atom), value}
    end)
    |> Map.drop(Map.get(@substrate_only_params, verb, []))
  end

  defp json(conn, status, body) do
    data = JSON.encode!(wire_value(body))

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, data)
  end

  defp error(conn, status, code, message \\ nil) do
    detail = %{"code" => code} |> put_optional("message", message)
    json(conn, status, %{"error" => detail})
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp wire_value(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {lower_camel(Atom.to_string(key)), wire_value(value)}
      {key, value} -> {key, wire_value(value)}
    end)
  end

  defp wire_value(list) when is_list(list), do: Enum.map(list, &wire_value/1)
  defp wire_value(value), do: value

  defp lower_camel(key) do
    camel = Macro.camelize(key)
    String.downcase(String.first(camel)) <> String.slice(camel, 1..-1//1)
  end
end
