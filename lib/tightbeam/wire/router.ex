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

  Routes — the PATHS ARE THE WIRE CONTRACT, verbatim from http.ts as-built
  (the real client and the black-box drivers speak these; never rename):
  - GET  /version              — no auth; protocolVersion + health numbers.
  - POST /agent/dispatch       — cliToken auth; body {verb, target?, params,
    as|asUser} → origin resolution; verb must be in the closed AGENT_VERBS
    set (post excluded on purpose: an agent DM IS a wake-with-prompt).
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

  alias Tightbeam.{Assets, Devices, Dispatch, Org, Roles}
  alias Tightbeam.Wire.{Payloads, Socket}

  @agent_verbs ~w(wake spawn retire inspect cancel tune approve-device deny-device revoke-device promote-user register-host skill-put skill-rm skill-list role-create role-bind role-rm role-list)
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

  post "/agent/dispatch" do
    with :ok <- cli_auth(conn),
         {:ok, body, conn} <- read_json(conn),
         {:ok, verb} <- required_string(body["verb"]),
         :ok <- allowed_agent_verb(verb),
         {:ok, origin} <- agent_origin(body, conn),
         {:ok, session_key, target_meta} <- typed_target(verb, body, conn) do
      call = %{
        verb: verb,
        origin: origin,
        session_key: session_key,
        target_role: target_meta.role,
        role_fallback: target_meta.fallback,
        params: atomize_params(body["params"] || %{})
      }

      dispatch_response(conn, call, 200, &%{"result" => &1})
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
         {:ok, display_name} <- required_string(body["displayName"]),
         {:ok, idempotency_key} <- required_string(body["idempotencyKey"]) do
      picker =
        for {k, atom} <- [{"harness", :harness}, {"model", :model}, {"host", :host}, {"archetype", :archetype}],
            is_binary(body[k]) and body[k] != "",
            into: %{},
            do: {atom, body[k]}

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
         {:ok, session} <- owned_session(key, device, conn),
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
         {:ok, session_key} <- retire_target(key, body, device, conn) do
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

      dispatch_response(conn, call, 200, &%{"deletedSessionKey" => &1[:deleted_session_key]})
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
    if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{deps(conn).cli_token}"] do
      :ok
    else
      {:error, 401, "auth_failed", nil}
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
        # powers are narrow: wake + cancel-wake, nothing else.
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

  defp typed_target(verb, body, conn) do
    given = Enum.filter(@target_fields, &is_binary(body[&1]))

    cond do
      is_binary(body["target"]) ->
        {:error, 400, "invalid_message", ~s("target" is retired: use sessionKey | role | userId)}

      length(given) > 1 ->
        {:error, 400, "invalid_message", "exactly one of sessionKey, role, userId"}

      verb == "retire" and (given == ["role"] or given == ["userId"]) ->
        {:error, 400, "invalid_message", "retire takes sessionKey only"}

      given == [] ->
        {:ok, nil, %{role: nil, fallback: false}}

      given == ["sessionKey"] ->
        case Org.get(db(conn), body["sessionKey"]) do
          nil -> {:error, 404, "not_found", "unknown sessionKey: #{body["sessionKey"]}"}
          session -> {:ok, session.session_key, %{role: nil, fallback: false}}
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

  defp control_call(%{"action" => "cancel_current_run"}), do: {:ok, "cancel", %{}}

  defp control_call(%{"action" => "set_model", "model" => model}),
    do: {:ok, "tune", %{setting: "set_model", model: model}}

  defp control_call(%{"action" => "set_harness", "harness" => harness} = body),
    do: {:ok, "tune", %{setting: "set_harness", harness: harness, model: body["model"]}}

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
    end
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

  defp control_json(conn, result, session_key, action) do
    %{
      "ok" => Map.get(result, :ok, not Map.has_key?(result, :code)),
      "sessionKey" => session_key,
      "action" => action,
      "status" => session_status(conn).(session_key)
    }
    |> put_optional("code", result[:code])
    |> put_optional("message", result[:message])
    |> then(&json(conn, 200, &1))
  end

  defp error_status("forbidden"), do: 403
  defp error_status("not_found"), do: 404
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

  defp atomize_params(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {key |> Macro.underscore() |> String.to_atom(), value} end)
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
