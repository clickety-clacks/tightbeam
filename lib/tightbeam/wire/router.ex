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

  alias Tightbeam.{
    Assets,
    CliCompatibility,
    D1Read,
    Devices,
    Dispatch,
    Org,
    Roles,
    WorkState
  }

  alias Tightbeam.Wire.{Payloads, Socket}

  Module.register_attribute(__MODULE__, :agent_verbs, persist: true)

  @agent_verbs ~w(wake condition facts-read artifact-record artifact-get artifacts spawn retire critical inspect cancel tune approve-device deny-device revoke-device promote-user add-user config register-host host-env-set host-env-list host-env-unset host-toolchain-set update-clients identity-edit identity-status identity-relearn identity-repoint learn unlearn kungfu-list identity-apply kungfu-scaffold onboard role-create role-bind role-rm role-list assign dispatch assignment-get attest attests revoke-assignment assignments work-item-create work-item-get work-item-trace work-item-list work-item-update work-item-icebox work-item-reopen work-item-close work-item-fail rule effort-rule waive revoke-waiver withdraw operator-ask operator-rule operator-withdraw decision-requests decision-request transcript attend toplines topline harness-processes)
  @max_upload_bytes 32 * 1024 * 1024
  @d1_default_limit 50
  @d1_max_limit 500
  @d1_cursor_version 1
  @d1_resources %{
    config: D1Read.spec(:config),
    host_environment: D1Read.spec(:host_environment),
    hosts: D1Read.spec(:hosts),
    users: D1Read.spec(:users),
    identity: D1Read.spec(:identity),
    kungfu: D1Read.spec(:kungfu)
  }
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

    # builds-identify-bytes: a running gateway states which bytes it is. version is
    # the release version (single home: the CLI-compat policy); build/sha are the
    # compile-time stamp (Tightbeam.BuildStamp), not runtime git.
    json(conn, 200, %{
      "protocolVersion" => 1,
      "server" => "tightbeam",
      "version" => Tightbeam.CliCompatibility.required_version(),
      "build" => Tightbeam.BuildStamp.build(),
      "sha" => Tightbeam.BuildStamp.sha(),
      "adapters" => health
    })
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
        # Identity resolution can turn a session-authenticated call into a user
        # principal. Keep the authenticated transport beside that principal so a
        # handler can stamp the hop without trusting a caller param.
        transport_session_key: authenticated_session_key(auth),
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

  # D1 is a read-only public contract. One maintenance seam owns all six
  # current-line projections; no route may select or serialize a raw row.
  get "/api/config" do
    d1_collection(conn, Map.fetch!(@d1_resources, :config))
  end

  get "/api/config/:key" do
    d1_detail(conn, Map.fetch!(@d1_resources, :config), key)
  end

  get "/api/host-env" do
    d1_collection(conn, Map.fetch!(@d1_resources, :host_environment))
  end

  get "/api/hosts" do
    d1_collection(conn, Map.fetch!(@d1_resources, :hosts))
  end

  get "/api/hosts/:host" do
    d1_detail(conn, Map.fetch!(@d1_resources, :hosts), host)
  end

  get "/api/users" do
    d1_collection(conn, Map.fetch!(@d1_resources, :users))
  end

  get "/api/users/:user_id" do
    d1_detail(conn, Map.fetch!(@d1_resources, :users), user_id)
  end

  get "/api/identity" do
    d1_collection(conn, Map.fetch!(@d1_resources, :identity))
  end

  get "/api/identity/:name" do
    d1_detail(conn, Map.fetch!(@d1_resources, :identity), name)
  end

  get "/api/kungfu" do
    d1_collection(conn, Map.fetch!(@d1_resources, :kungfu))
  end

  get "/api/kungfu/:name" do
    d1_detail(conn, Map.fetch!(@d1_resources, :kungfu), name)
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

  defp d1_collection(conn, spec) do
    with {:ok, auth} <- d1_bearer_auth(conn),
         {:ok, query} <- d1_query(conn.query_string),
         {:ok, principal} <- d1_principal(auth, query, conn),
         {:ok, request} <- d1_collection_request(query, spec),
         {:ok, boundary} <- d1_boundary(request, principal, spec, conn) do
      rows =
        if D1Read.visible?(d1_resource(spec), principal.is_admin) do
          D1Read.collection(db(conn), deps(conn).base_dir, d1_resource(spec), request.filters)
        else
          []
        end

      {items, page} = d1_page(rows, boundary, request, principal, spec, conn)
      d1_send(conn, 200, d1_collection_envelope(spec, items, page))
    else
      {:error, status, code, message} -> d1_error(conn, spec.resource, status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      d1_error(conn, spec.resource, 500, "projection_invalid", nil)
  end

  defp d1_detail(conn, spec, id) do
    with {:ok, auth} <- d1_bearer_auth(conn),
         {:ok, query} <- d1_query(conn.query_string),
         {:ok, principal} <- d1_principal(auth, query, conn),
         :ok <- d1_detail_request(query),
         true <- D1Read.visible?(d1_resource(spec), principal.is_admin),
         item when not is_nil(item) <-
           D1Read.detail(db(conn), deps(conn).base_dir, d1_resource(spec), id) do
      d1_send(conn, 200, d1_detail_envelope(spec, item))
    else
      false -> d1_error(conn, spec.resource, 404, "not_found", nil)
      nil -> d1_error(conn, spec.resource, 404, "not_found", nil)
      {:error, status, code, message} -> d1_error(conn, spec.resource, status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      d1_error(conn, spec.resource, 500, "projection_invalid", nil)
  end

  defp d1_bearer_auth(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" ->
        cond do
          token == deps(conn).cli_token -> {:ok, :org}
          session = Org.by_cli_token(db(conn), token) -> {:ok, {:session, session}}
          device = Devices.by_token(db(conn), token) -> {:ok, {:device, device}}
          true -> {:error, 401, "auth_failed", nil}
        end

      _ ->
        {:error, 401, "auth_failed", nil}
    end
  end

  defp d1_principal(:org, %{"asUser" => [user_id]}, conn) when user_id != "" do
    {:ok, d1_user_principal(user_id, conn)}
  end

  defp d1_principal(:org, %{"asUser" => [_]}, _conn), do: {:error, 400, "invalid_message", nil}
  defp d1_principal(:org, %{}, _conn), do: {:error, 400, "invalid_message", nil}
  defp d1_principal(:org, _query, _conn), do: {:error, 400, "invalid_as_user", nil}

  defp d1_principal({:session, session}, query, conn) do
    case Map.get(query, "asUser", []) do
      [] ->
        {:ok, %{kind: "session", id: session.session_key, is_admin: false}}

      [user_id] when user_id == session.owner_user_id and user_id != "" ->
        {:ok, d1_user_principal(user_id, conn)}

      [_user_id] ->
        {:error, 403, "identity_not_yours", "this session belongs to #{session.owner_user_id}"}

      _repeated ->
        {:error, 400, "invalid_as_user", nil}
    end
  end

  defp d1_principal({:device, device}, query, _conn) do
    if Map.has_key?(query, "asUser") do
      {:error, 400, "invalid_as_user", nil}
    else
      {:ok, %{kind: "user", id: device.user_id, is_admin: device.is_admin}}
    end
  end

  defp d1_user_principal(user_id, conn) do
    is_admin = match?(%{is_admin: true}, Devices.user(db(conn), user_id))
    %{kind: "user", id: user_id, is_admin: is_admin}
  end

  defp d1_query(""), do: {:ok, %{}}

  defp d1_query(query_string) do
    Enum.reduce_while(String.split(query_string, "&", trim: false), {:ok, %{}}, fn part,
                                                                                   {:ok, query} ->
      with [key, value] <- String.split(part, "=", parts: 2),
           false <- Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, key <> value),
           key <- URI.decode_www_form(key),
           value <- URI.decode_www_form(value),
           true <- String.valid?(key) and String.valid?(value) do
        {:cont, {:ok, Map.update(query, key, [value], &[value | &1])}}
      else
        _ -> {:halt, {:error, 400, "malformed_query", nil}}
      end
    end)
  rescue
    ArgumentError -> {:error, 400, "malformed_query", nil}
  end

  defp d1_detail_request(query) do
    if Enum.all?(Map.keys(query), &(&1 == "asUser")),
      do: :ok,
      else: {:error, 400, "invalid_filter", nil}
  end

  defp d1_collection_request(query, spec) do
    allowed = spec.filters ++ ~w(asUser before after limit)

    with true <- Enum.all?(Map.keys(query), &(&1 in allowed)),
         {:ok, before} <- d1_single(query, "before"),
         {:ok, after_cursor} <- d1_single(query, "after"),
         true <- is_nil(before) or is_nil(after_cursor),
         {:ok, limit_value} <- d1_single(query, "limit"),
         {:ok, limit} <- d1_limit(limit_value),
         {:ok, filters} <- d1_filters(query, spec.filters) do
      {:ok, %{before: before, after: after_cursor, limit: limit, filters: filters}}
    else
      _ -> {:error, 400, "invalid_filter", nil}
    end
  end

  defp d1_single(query, key) do
    case Map.get(query, key, []) do
      [] -> {:ok, nil}
      [value] -> {:ok, value}
      _ -> :error
    end
  end

  defp d1_limit(nil), do: {:ok, @d1_default_limit}

  defp d1_limit(value) when is_binary(value) do
    if value =~ ~r/^[1-9][0-9]*$/ do
      {:ok, min(String.to_integer(value), @d1_max_limit)}
    else
      :error
    end
  end

  defp d1_limit(_value), do: :error

  defp d1_filters(query, fields) do
    fields
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, filters} ->
      values = Map.get(query, field, [])

      if Enum.all?(values, &d1_filter_value?(field, &1)) do
        next =
          if values == [],
            do: filters,
            else: Map.put(filters, field, values |> Enum.uniq() |> Enum.sort())

        {:cont, {:ok, next}}
      else
        {:halt, :error}
      end
    end)
  end

  defp d1_filter_value?("state", value), do: value in ~w(ready relearn_conflicted)
  defp d1_filter_value?("status", value), do: value in ~w(available installed)
  defp d1_filter_value?(_field, value), do: is_binary(value) and value != ""

  defp d1_boundary(%{before: nil, after: nil}, _principal, _spec, _conn), do: {:ok, :latest}

  defp d1_boundary(%{before: cursor} = request, principal, spec, conn) when is_binary(cursor),
    do: d1_decode_cursor(cursor, "before", request, principal, spec, conn)

  defp d1_boundary(%{after: cursor} = request, principal, spec, conn) when is_binary(cursor),
    do: d1_decode_cursor(cursor, "after", request, principal, spec, conn)

  defp d1_decode_cursor(cursor, direction, request, principal, spec, _conn) do
    with {:ok, payload_bytes} <- Base.url_decode64(cursor, padding: false),
         {:ok, payload} when is_map(payload) <- JSON.decode(payload_bytes),
         true <- Enum.sort(Map.keys(payload)) == d1_cursor_keys(),
         true <- payload["version"] == @d1_cursor_version,
         true <- payload["route"] == spec.route and payload["resource"] == spec.resource,
         true <-
           payload["direction"] == direction and
             payload["filters"] == d1_filter_fingerprint(request.filters),
         true <-
           payload["principalKind"] == principal.kind and payload["principalId"] == principal.id,
         true <- d1_tuple?(payload["tuple"], d1_resource(spec)) do
      {:ok, {String.to_atom(direction), payload["tuple"]}}
    else
      _ -> {:error, 400, "invalid_cursor", nil}
    end
  end

  defp d1_tuple?(tuple, resource),
    do:
      is_list(tuple) and length(tuple) == length(D1Read.spec(resource).order) and
        Enum.all?(tuple, &(is_binary(&1) and &1 != ""))

  defp d1_page(rows, boundary, request, principal, spec, conn) do
    selected =
      case boundary do
        :latest ->
          Enum.take(rows, -request.limit)

        {:before, tuple} ->
          rows
          |> Enum.filter(&(D1Read.tuple(d1_resource(spec), &1) < tuple))
          |> Enum.take(-request.limit)

        {:after, tuple} ->
          rows
          |> Enum.filter(&(D1Read.tuple(d1_resource(spec), &1) > tuple))
          |> Enum.take(request.limit)
      end

    tuples = Enum.map(selected, &D1Read.tuple(d1_resource(spec), &1))

    page =
      case tuples do
        [] ->
          d1_empty_page(rows, boundary, spec)

        _ ->
          oldest = hd(tuples)
          newest = List.last(tuples)

          %{
            oldest: d1_cursor(oldest, "before", request.filters, principal, spec, conn),
            newest: d1_cursor(newest, "after", request.filters, principal, spec, conn),
            before: Enum.any?(rows, &(D1Read.tuple(d1_resource(spec), &1) < oldest)),
            after: Enum.any?(rows, &(D1Read.tuple(d1_resource(spec), &1) > newest))
          }
      end

    {selected, page}
  end

  defp d1_empty_page(rows, boundary, spec) do
    {before_more, after_more} =
      case boundary do
        :latest ->
          {false, false}

        {:before, tuple} ->
          {false, Enum.any?(rows, &(D1Read.tuple(d1_resource(spec), &1) >= tuple))}

        {:after, tuple} ->
          {Enum.any?(rows, &(D1Read.tuple(d1_resource(spec), &1) <= tuple)), false}
      end

    %{oldest: nil, newest: nil, before: before_more, after: after_more}
  end

  defp d1_cursor(tuple, direction, filters, principal, spec, _conn) do
    payload =
      JSON.encode!(%{
        "version" => @d1_cursor_version,
        "route" => spec.route,
        "resource" => spec.resource,
        "direction" => direction,
        "filters" => d1_filter_fingerprint(filters),
        "principalKind" => principal.kind,
        "principalId" => principal.id,
        "tuple" => tuple
      })

    Base.url_encode64(payload, padding: false)
  end

  defp d1_cursor_keys do
    Enum.sort(~w(direction filters principalId principalKind resource route tuple version))
  end

  defp d1_filter_fingerprint(filters),
    do:
      filters
      |> Enum.sort()
      |> Enum.map(fn {field, values} -> [field, values] end)
      |> JSON.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp d1_resource(spec),
    do:
      Enum.find_value(@d1_resources, fn {resource, candidate} ->
        if candidate == spec, do: resource
      end)

  defp d1_collection_envelope(spec, items, page) do
    encoded_items = Enum.map_join(items, ",", &D1Read.encode(d1_resource(spec), &1))

    "{\"schemaVersion\":1,\"resource\":" <>
      JSON.encode!(spec.resource) <>
      ",\"items\":[" <>
      encoded_items <>
      "],\"page\":{\"oldestCursor\":" <>
      JSON.encode!(page.oldest) <>
      ",\"newestCursor\":" <>
      JSON.encode!(page.newest) <>
      ",\"hasMoreBefore\":" <>
      JSON.encode!(page.before) <> ",\"hasMoreAfter\":" <> JSON.encode!(page.after) <> "}}"
  end

  defp d1_detail_envelope(spec, item),
    do:
      "{\"schemaVersion\":1,\"resource\":" <>
        JSON.encode!(spec.resource) <>
        ",\"item\":" <> D1Read.encode(d1_resource(spec), item) <> "}"

  defp d1_send(conn, status, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> Plug.Conn.send_resp(status, body)

  defp d1_error(conn, resource, status, code, nil),
    do:
      d1_send(
        conn,
        status,
        "{\"schemaVersion\":1,\"resource\":" <>
          JSON.encode!(resource) <> ",\"error\":{\"code\":" <> JSON.encode!(code) <> "}}"
      )

  defp d1_error(conn, resource, status, code, message),
    do:
      d1_send(
        conn,
        status,
        "{\"schemaVersion\":1,\"resource\":" <>
          JSON.encode!(resource) <>
          ",\"error\":{\"code\":" <>
          JSON.encode!(code) <> ",\"message\":" <> JSON.encode!(message) <> "}}"
      )

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

  defp authenticated_session_key({:session, session}), do: session.session_key
  defp authenticated_session_key(:org), do: nil

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
  @non_target_verbs ~w(transcript toplines topline)

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
        if verb == "tune" do
          # Runtime tuning authorizes before existence can become visible. The
          # gateway receives the opaque key and returns the same not_found for
          # unknown, retired, foreign, and process callers. Other verbs retain
          # the router's existing eager target semantics.
          {:ok, body["sessionKey"], %{role: nil, fallback: false}}
        else
          case Org.get(db(conn), body["sessionKey"]) do
            nil ->
              {:error, 404, "not_found", "unknown sessionKey: #{body["sessionKey"]}"}

            %{state: "retired"} when verb in ["assign", "dispatch"] ->
              {:error, 400, "session_retired", "assignments require an active holder session"}

            session ->
              {:ok, session.session_key, %{role: nil, fallback: false}}
          end
        end

      given == ["userId"] ->
        if Devices.user(db(conn), body["userId"]),
          do: {:ok, Org.personal_session_key(body["userId"]), %{role: nil, fallback: false}},
          else: {:error, 404, "not_found", "unknown userId: #{body["userId"]}"}

      given == ["role"] ->
        case Roles.resolve(db(conn), body["role"]) do
          # `Roles.resolve/2` answers "who stands in for this role", falling back to
          # the owner's personal session when the role is unbound or its binding is
          # not active. That is a fair answer for a wake and a PHANTOM for an
          # assignment: assign/dispatch BIND an obligation, and the owner's session
          # is not the requested role's holder — commonly not even its provider — so
          # the card lands on a session that cannot do the work while the requester
          # believes it dispatched (wi_756153b7, specimens asg_6f380b79 and
          # asg_388a5a54, the latter against a role whose bound session was retired).
          # Refuse HERE, the one place the fallback is still distinguishable: past
          # this seam only a boolean survives, and the handler sees an active session
          # it has no reason to doubt. Every other consumer keeps the fallback.
          {:ok, _session_key, true} when verb in ["assign", "dispatch"] ->
            {:error, 400, "no_live_role_holder",
             "role #{body["role"]} has no live bound session; spawn one and bind the role, " <>
               "or target an active sessionKey"}

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
        dispatch_error(conn, call, error_status(result[:code]), result)

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

  defp error_status(code)
       when code in [
              "decision_request_integrity_invalid",
              "decision_request_integrity_evidence_conflict",
              "decision_request_integrity_evidence_unavailable"
            ],
       do: 500

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
  # An operator ruling's transport provenance follows the same rule: the router
  # derives it from bearer authentication above, so `ruledViaSessionKey` cannot
  # enter through params. `wake.requestRef` is also internal because delayed
  # delivery uses it to bind the wake to its authoritative decision row.
  #
  # Scoped per verb deliberately: `assignmentId` is an ORDINARY caller param on
  # attest/assign/dispatch/effort-rule, which name the assignment they act on. A
  # blanket strip breaks all of those (the CLI round-trip suite proves it), so the
  # spec's "stripped from any agent/dispatch param map" is read as scoped to the
  # carrier it is written about, not to the parameter name everywhere.
  @substrate_only_params %{
    "wake" => ~w(assignment_id request_ref)a,
    "operator-rule" => ~w(ruled_via_session_key)a,
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
    "assign" => %{reviews: :reviews_assignment_id},
    "tune" => %{
      reasoning_level: :reasoningLevel,
      fast_mode: :fastMode
    }
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

  defp dispatch_error(conn, %{verb: "tune"}, status, result) do
    json(conn, status, %{"error" => Map.delete(result, :ok)})
  end

  defp dispatch_error(conn, _call, status, %{code: code} = result)
       when code in [
              "decision_request_integrity_invalid",
              "decision_request_integrity_evidence_conflict",
              "decision_request_integrity_evidence_unavailable"
            ] do
    json(conn, status, %{"error" => Map.delete(result, :ok)})
  end

  defp dispatch_error(conn, _call, status, result) do
    error(conn, status, result[:code], result[:message])
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
