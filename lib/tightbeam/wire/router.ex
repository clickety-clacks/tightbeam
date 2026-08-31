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
  cursor_signing provider, session_status fun) arrive via `init_opts` from the
  composition root and ride `conn.private`. Handlers run in the request process
  — fine, because every verb is bounded (long work goes through the Ledger).
  """

  use Plug.Router

  alias Tightbeam.{
    Assets,
    CliCompatibility,
    ColdStart,
    Devices,
    Dispatch,
    ModelCatalog,
    Org,
    Roles,
    StateResources,
    StateVisibility,
    WorkState
  }

  alias Tightbeam.Firehose.Registry
  alias Tightbeam.Wire.{ChangeSocket, Payloads, Socket}

  Module.register_attribute(__MODULE__, :agent_verbs, persist: true)

  @agent_verbs ~w(wake condition facts-read artifact-record artifact-get artifacts spawn retire critical inspect cancel tune approve-device deny-device revoke-device promote-user add-user read-marker-set read-marker-clear config register-host host-env-set host-env-list host-env-unset update-clients identity-edit identity-status identity-relearn identity-repoint learn unlearn kungfu-list identity-apply kungfu-scaffold onboard role-create role-bind role-rm role-list assign dispatch assignment-get attest attests revoke-assignment reopen-assignment assignments work-item-create work-item-get work-item-trace work-item-list work-item-update work-item-icebox work-item-reopen work-item-close work-item-fail rule effort-rule waive revoke-waiver withdraw ask answer return operator-ask operator-rule operator-withdraw decision-requests decision-request transcript turn-trace attend toplines topline coordination-share digest-members harness-processes)
  @max_upload_bytes 32 * 1024 * 1024
  @state_cursor_version 1
  @state_default_limit 50
  @state_max_limit 500
  @state_not_found_floor_us 3_000
  @state_malformed_percent_escape ~r/%(?![0-9A-Fa-f]{2})/
  @state_read_specs %{
    config: %{
      route: "config.collection",
      resource: "config",
      class: "config.updated",
      filters: %{"key" => :string},
      order: [{:key, :string}],
      detail: true
    },
    host_environment: %{
      route: "host_environment.collection",
      resource: "host environment",
      class: "host_env.updated",
      filters: %{"host" => :string, "harness" => :string, "name" => :string},
      order: [{:host, :string}, {:harness, :string}, {:name, :string}],
      detail: false
    },
    hosts: %{
      route: "hosts.collection",
      resource: "hosts",
      class: "host.registered",
      filters: %{"host" => :string},
      order: [{:host, :string}],
      detail: true
    },
    users: %{
      route: "users.collection",
      resource: "users",
      class: "user.added",
      filters: %{"userId" => :string},
      order: [{:created_at, :integer}, {:user_id, :string}],
      detail: true
    },
    identity: %{
      route: "identity.collection",
      resource: "identity",
      class: "identity.updated",
      filters: %{
        "name" => :string,
        "state" => {:enum, ~w(ready relearn_conflicted)}
      },
      order: [{:name, :string}],
      detail: true
    },
    kungfu: %{
      route: "kungfu.collection",
      resource: "kungfu",
      class: "kungfu.updated",
      filters: %{
        "status" => {:enum, ~w(available installed)},
        "rootArchetype" => :string
      },
      order: [{:name, :string}],
      detail: true
    }
  }
  @multipart_opts Plug.Parsers.init(
                    parsers: [{:multipart, length: @max_upload_bytes + 1_000_000}],
                    pass: ["*/*"]
                  )

  @impl Plug
  def init(opts) do
    deps = Map.new(opts)
    _provider = deps |> Map.get(:cursor_signing) |> Tightbeam.CursorSigning.validate!()
    deps
  end

  @impl Plug
  def call(conn, opts) do
    deps = Map.new(opts)
    conn = Plug.Conn.put_private(conn, :tightbeam_deps, deps)

    case Tightbeam.CursorSigning.admit_request(deps.cursor_signing) do
      :ok ->
        super(conn, deps)

      {:error, _reason} ->
        conn
        |> Plug.Conn.put_resp_header("cache-control", "no-store")
        |> error(500, "projection_invalid")
    end
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

  get "/ws/changes" do
    conn = Plug.Conn.fetch_query_params(conn)

    if Plug.Conn.get_req_header(conn, "upgrade") == ["websocket"] and
         conn.query_params["protocolVersion"] == "1" do
      WebSockAdapter.upgrade(conn, ChangeSocket, deps(conn), max_frame_size: 2 * 1024 * 1024)
    else
      error(conn, 426, "unsupported_protocol_version")
    end
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
         {:ok, verb} <- required_string(body["verb"]) do
      dispatch_agent_request(conn, auth, verb, body)
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

  get "/api/config" do
    state_collection(conn, Map.fetch!(@state_read_specs, :config))
  end

  get "/api/config/:key" do
    state_detail(conn, Map.fetch!(@state_read_specs, :config), key)
  end

  get "/api/host-env" do
    state_collection(conn, Map.fetch!(@state_read_specs, :host_environment))
  end

  get "/api/hosts" do
    state_collection(conn, Map.fetch!(@state_read_specs, :hosts))
  end

  get "/api/hosts/:host" do
    state_detail(conn, Map.fetch!(@state_read_specs, :hosts), host)
  end

  get "/api/users" do
    state_collection(conn, Map.fetch!(@state_read_specs, :users))
  end

  get "/api/users/:user_id" do
    state_detail(conn, Map.fetch!(@state_read_specs, :users), user_id)
  end

  get "/api/identity" do
    state_collection(conn, Map.fetch!(@state_read_specs, :identity))
  end

  get "/api/identity/:name" do
    state_detail(conn, Map.fetch!(@state_read_specs, :identity), name)
  end

  get "/api/kungfu" do
    state_collection(conn, Map.fetch!(@state_read_specs, :kungfu))
  end

  get "/api/kungfu/:name" do
    state_detail(conn, Map.fetch!(@state_read_specs, :kungfu), name)
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

  defp state_collection(conn, spec) do
    started_at = System.monotonic_time(:microsecond)

    with {:ok, auth} <- state_bearer_auth(conn),
         {:ok, query} <- decode_state_query(conn),
         {:ok, principal} <- state_principal(auth, query, conn),
         {:ok, request} <- state_collection_request(query, spec),
         {:ok, boundary} <- state_cursor_boundary(request, principal, spec, conn),
         seam <- state_seam!(spec),
         visible <- apply(StateVisibility, seam.visibility, [principal.is_admin]),
         rows <- state_collection_rows(conn, spec, seam, request.filters, visible),
         {page_rows, page} <- state_page(rows, boundary, request, principal, spec, conn),
         items <- state_serialize_rows(page_rows, spec) do
      state_send(conn, 200, state_collection_envelope(conn, spec.resource, items, page))
    else
      {:error, 404, "not_found", _message} ->
        state_not_found(conn, spec.resource, started_at)

      {:error, status, code, message} ->
        state_error(conn, spec.resource, status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      state_error(conn, spec.resource, 500, "projection_invalid", nil)
  end

  defp state_detail(conn, %{resource: "identity"} = spec, id) do
    started_at = System.monotonic_time(:microsecond)

    with {:ok, auth} <- state_bearer_auth(conn),
         {:ok, query} <- decode_state_query(conn),
         {:ok, principal} <- state_principal(auth, query, conn),
         :ok <- state_detail_request(query),
         {:ok, item_bytes} <- state_identity_detail_item(conn, spec, id, principal) do
      state_send(conn, 200, state_detail_envelope(spec.resource, item_bytes))
    else
      :not_found ->
        state_not_found(conn, spec.resource, started_at)

      {:error, 404, "not_found", _message} ->
        state_not_found(conn, spec.resource, started_at)

      {:error, status, code, message} ->
        state_error(conn, spec.resource, status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      state_error(conn, spec.resource, 500, "projection_invalid", nil)
  end

  defp state_detail(conn, spec, id) do
    started_at = System.monotonic_time(:microsecond)

    with {:ok, auth} <- state_bearer_auth(conn),
         {:ok, query} <- decode_state_query(conn),
         {:ok, principal} <- state_principal(auth, query, conn),
         :ok <- state_detail_request(query),
         seam <- state_seam!(spec),
         visible <- apply(StateVisibility, seam.visibility, [principal.is_admin]),
         true <- visible,
         row <- apply(StateResources, seam.query, [db(conn), id]),
         true <- not is_nil(row),
         item <- apply(StateResources, seam.serializer, [row]),
         item_bytes <- StateResources.encode_item(spec.resource, item, state_catalog(conn)) do
      state_send(conn, 200, state_detail_envelope(spec.resource, item_bytes))
    else
      false ->
        state_not_found(conn, spec.resource, started_at)

      {:error, status, code, message} ->
        state_error(conn, spec.resource, status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      state_error(conn, spec.resource, 500, "projection_invalid", nil)
  end

  defp state_identity_detail_item(conn, spec, id, principal) do
    seam = state_seam!(spec)
    request_binding = make_ref()
    principal_binding = state_identity_principal_binding(principal)

    try do
      state_identity_detail_attempt(
        conn,
        spec,
        seam,
        id,
        principal,
        principal_binding,
        request_binding,
        false
      )
    after
      :ok =
        apply(StateResources, seam.query, [
          db(conn),
          {:close, request_binding}
        ])
    end
  end

  defp state_identity_detail_attempt(
         conn,
         spec,
         seam,
         id,
         principal,
         principal_binding,
         request_binding,
         retried?
       ) do
    with {:ok, descriptor} <-
           apply(StateResources, seam.query, [
             db(conn),
             {:metadata, id, request_binding, principal_binding}
           ]),
         true <- apply(StateVisibility, seam.visibility, [principal.is_admin]) do
      case apply(StateResources, seam.query, [
             db(conn),
             {:hydrate, descriptor, request_binding, principal_binding}
           ]) do
        {:ok, row} ->
          item = apply(StateResources, seam.serializer, [row])
          {:ok, StateResources.encode_item(spec.resource, item, state_catalog(conn))}

        :not_found ->
          :not_found

        :stale when not retried? ->
          state_identity_detail_attempt(
            conn,
            spec,
            seam,
            id,
            principal,
            principal_binding,
            request_binding,
            true
          )

        :stale ->
          :not_found

        {:error, :invalid_identity_descriptor} ->
          {:error, 500, "projection_invalid", nil}
      end
    else
      false -> :not_found
      {:error, :invalid_identity_descriptor} -> {:error, 500, "projection_invalid", nil}
    end
  end

  defp state_identity_principal_binding(%{kind: "session", id: id}), do: {:session, id}
  defp state_identity_principal_binding(%{kind: "user", id: id}), do: {:user, id}

  defp state_bearer_auth(conn) do
    token =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token] when token != "" -> token
        _ -> nil
      end

    cond do
      is_nil(token) ->
        {:error, 401, "auth_failed", nil}

      token == deps(conn).cli_token ->
        {:ok, :org}

      session = Org.by_cli_token(db(conn), token) ->
        {:ok, {:session, session}}

      device = Devices.by_token(db(conn), token) ->
        {:ok, {:device, device}}

      true ->
        {:error, 401, "auth_failed", nil}
    end
  end

  defp state_principal(:org, query, conn) do
    case Map.get(query, "asUser", []) do
      [user_id] when user_id != "" ->
        with {:ok, principal} <- resolve_cli_as_user(:org, user_id) do
          {:ok, state_principal_view(principal, conn)}
        end

      [_empty] ->
        {:error, 400, "invalid_message", nil}

      [] ->
        {:error, 400, "invalid_message", nil}

      _repeated ->
        {:error, 400, "invalid_as_user", nil}
    end
  end

  defp state_principal({:session, session}, query, conn) do
    case Map.get(query, "asUser", []) do
      [] ->
        {:ok, %{kind: "session", id: session.session_key, is_admin: false}}

      [as_user] ->
        with {:ok, principal} <- resolve_cli_as_user({:session, session}, as_user) do
          {:ok, state_principal_view(principal, conn)}
        end

      _repeated ->
        {:error, 400, "invalid_as_user", nil}
    end
  end

  defp state_principal({:device, device}, query, _conn) do
    if Map.has_key?(query, "asUser") do
      {:error, 400, "invalid_as_user", nil}
    else
      {:ok, %{kind: "user", id: device.user_id, is_admin: device.is_admin}}
    end
  end

  defp state_user_principal(user_id, conn) do
    is_admin =
      case Devices.user(db(conn), user_id) do
        %{is_admin: true} -> true
        _ -> false
      end

    %{kind: "user", id: user_id, is_admin: is_admin}
  end

  defp state_principal_view({:user, user_id}, conn), do: state_user_principal(user_id, conn)

  defp state_principal_view({:session, session_key}, _conn),
    do: %{kind: "session", id: session_key, is_admin: false}

  defp resolve_cli_as_user(:org, user_id) when is_binary(user_id) and user_id != "",
    do: {:ok, {:user, user_id}}

  defp resolve_cli_as_user({:session, %{owner_user_id: owner}}, owner),
    do: {:ok, {:user, owner}}

  defp resolve_cli_as_user({:session, %{owner_user_id: owner}}, _other),
    do: {:error, 403, "identity_not_yours", "this session belongs to #{owner}"}

  defp decode_state_query(conn), do: decode_state_query_string(conn.query_string)

  defp decode_state_query_string(""), do: {:ok, %{}}

  defp decode_state_query_string(query_string) do
    Enum.reduce_while(String.split(query_string, "&", trim: false), {:ok, %{}}, fn encoded,
                                                                                   {:ok, query} ->
      {raw_key, raw_value} =
        case String.split(encoded, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end

      with {:ok, key} <- decode_state_query_part(raw_key),
           {:ok, value} <- decode_state_query_part(raw_value) do
        {:cont, {:ok, Map.update(query, key, [value], &[value | &1])}}
      else
        :error -> {:halt, {:error, 400, "malformed_query", nil}}
      end
    end)
  end

  defp decode_state_query_part(part) do
    if Regex.match?(@state_malformed_percent_escape, part) do
      :error
    else
      decoded = URI.decode_www_form(part)
      if String.valid?(decoded), do: {:ok, decoded}, else: :error
    end
  rescue
    ArgumentError -> :error
  end

  defp state_detail_request(query) do
    if Enum.all?(Map.keys(query), &(&1 == "asUser")),
      do: :ok,
      else: {:error, 400, "invalid_filter", nil}
  end

  defp state_collection_request(query, spec) do
    allowed = Map.keys(spec.filters) ++ ~w(asUser before after limit)

    with true <- Enum.all?(Map.keys(query), &(&1 in allowed)),
         {:ok, before_cursor} <- state_single_value(query, "before"),
         {:ok, after_cursor} <- state_single_value(query, "after"),
         true <- is_nil(before_cursor) or is_nil(after_cursor),
         {:ok, limit_value} <- state_single_value(query, "limit"),
         {:ok, limit} <- state_limit(limit_value),
         {:ok, filters} <- state_filters(query, spec.filters) do
      {:ok,
       %{
         before: before_cursor,
         after: after_cursor,
         limit: limit,
         filters: filters,
         filter_fingerprint: state_filter_fingerprint(filters)
       }}
    else
      _ -> {:error, 400, "invalid_filter", nil}
    end
  end

  defp state_single_value(query, key) do
    case Map.get(query, key, []) do
      [] -> {:ok, nil}
      [value] -> {:ok, value}
      _ -> {:error, :repeated}
    end
  end

  defp state_limit(nil), do: {:ok, @state_default_limit}

  defp state_limit(value) when is_binary(value) do
    if Regex.match?(~r/^[1-9][0-9]*$/, value) do
      {:ok, min(String.to_integer(value), @state_max_limit)}
    else
      {:error, :invalid}
    end
  end

  defp state_filters(query, filter_specs) do
    Enum.reduce_while(filter_specs, {:ok, %{}}, fn {field, validator}, {:ok, filters} ->
      values = Map.get(query, field, [])

      if Enum.all?(values, &state_filter_value?(&1, validator)) do
        normalized = values |> Enum.uniq() |> Enum.sort()
        next = if normalized == [], do: filters, else: Map.put(filters, field, normalized)
        {:cont, {:ok, next}}
      else
        {:halt, {:error, :invalid}}
      end
    end)
  end

  defp state_filter_value?(value, :string), do: is_binary(value) and value != ""

  defp state_filter_value?(value, {:enum, values}),
    do: is_binary(value) and value in values

  defp state_filter_fingerprint(filters) do
    filters
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {field, values} -> [field, values] end)
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp state_cursor_boundary(%{before: nil, after: nil}, _principal, _spec, _conn),
    do: {:ok, :latest}

  defp state_cursor_boundary(%{before: cursor} = request, principal, spec, conn)
       when is_binary(cursor) do
    with {:ok, tuple} <- decode_state_cursor(cursor, "before", request, principal, spec, conn) do
      {:ok, {:before, tuple}}
    end
  end

  defp state_cursor_boundary(%{after: cursor} = request, principal, spec, conn)
       when is_binary(cursor) do
    with {:ok, tuple} <- decode_state_cursor(cursor, "after", request, principal, spec, conn) do
      {:ok, {:after, tuple}}
    end
  end

  defp decode_state_cursor(cursor, direction, request, principal, spec, conn) do
    invalid = {:error, 400, "invalid_cursor", nil}

    with [payload_part, signature_part] <- String.split(cursor, ".", parts: 2),
         {:ok, payload_bytes} <- Base.url_decode64(payload_part, padding: false),
         {:ok, signature} <- Base.url_decode64(signature_part, padding: false),
         {:ok, true} <- state_cursor_signature_valid?(payload_bytes, signature, conn),
         {:ok, payload} when is_map(payload) <- JSON.decode(payload_bytes),
         true <- Enum.sort(Map.keys(payload)) == state_cursor_keys(),
         true <- payload["version"] == @state_cursor_version,
         true <- payload["route"] == spec.route,
         true <- payload["resource"] == spec.resource,
         true <- payload["direction"] == direction,
         true <- payload["filters"] == request.filter_fingerprint,
         true <- state_cursor_tuple_valid?(payload["tuple"], spec.order) do
      if payload["principalKind"] == principal.kind and payload["principalId"] == principal.id do
        {:ok, payload["tuple"]}
      else
        {:error, 404, "not_found", nil}
      end
    else
      {:error, 500, "projection_invalid", nil} = error -> error
      _ -> invalid
    end
  end

  defp state_cursor_keys do
    Enum.sort(~w(direction filters principalId principalKind resource route tuple version))
  end

  defp state_cursor_signature_valid?(payload, signature, conn) do
    case Tightbeam.CursorSigning.verify(deps(conn).cursor_signing, payload, signature) do
      {:ok, valid?} -> {:ok, valid?}
      _error -> {:error, 500, "projection_invalid", nil}
    end
  end

  defp state_cursor_tuple_valid?(tuple, order) when is_list(tuple) do
    length(tuple) == length(order) and
      Enum.zip(tuple, order)
      |> Enum.all?(fn
        {value, {_field, :string}} -> is_binary(value) and value != ""
        {value, {_field, :integer}} -> is_integer(value)
      end)
  end

  defp state_cursor_tuple_valid?(_tuple, _order), do: false

  defp state_collection_rows(_conn, _spec, _seam, _filters, false), do: []

  defp state_collection_rows(conn, spec, seam, filters, true) do
    filters
    |> state_filter_combinations()
    |> Enum.flat_map(fn combination ->
      case apply(StateResources, seam.query, [db(conn), combination]) do
        rows when is_list(rows) -> rows
        _ -> raise ArgumentError, "#{spec.resource} collection query did not return a list"
      end
    end)
    |> Enum.uniq_by(&state_row_tuple(&1, spec.order))
    |> Enum.sort_by(&state_row_tuple(&1, spec.order))
  end

  defp state_filter_combinations(filters) do
    filters
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce([%{}], fn {field, values}, combinations ->
      for combination <- combinations, value <- values do
        Map.put(combination, field, value)
      end
    end)
  end

  defp state_seam!(spec) do
    row = Registry.rows() |> Map.fetch!(spec.class)

    unless row.resource == spec.resource and is_atom(row.query) and is_atom(row.serializer) and
             is_atom(row.visibility) do
      raise ArgumentError, "#{spec.resource} shared seam registry row is incomplete"
    end

    row
  end

  defp state_page(rows, boundary, request, principal, spec, conn) do
    selected =
      case boundary do
        :latest ->
          Enum.take(rows, -request.limit)

        {:before, tuple} ->
          rows
          |> Enum.filter(&(state_row_tuple(&1, spec.order) < tuple))
          |> Enum.take(-request.limit)

        {:after, tuple} ->
          rows
          |> Enum.filter(&(state_row_tuple(&1, spec.order) > tuple))
          |> Enum.take(request.limit)
      end

    tuples = Enum.map(selected, &state_row_tuple(&1, spec.order))

    page =
      case tuples do
        [] ->
          state_empty_page(rows, boundary, spec)

        _ ->
          oldest = hd(tuples)
          newest = List.last(tuples)

          %{
            oldest_cursor:
              encode_state_cursor(
                oldest,
                "before",
                request.filter_fingerprint,
                principal,
                spec,
                conn
              ),
            newest_cursor:
              encode_state_cursor(
                newest,
                "after",
                request.filter_fingerprint,
                principal,
                spec,
                conn
              ),
            has_more_before: Enum.any?(rows, &(state_row_tuple(&1, spec.order) < oldest)),
            has_more_after: Enum.any?(rows, &(state_row_tuple(&1, spec.order) > newest))
          }
      end

    {selected, page}
  end

  defp state_empty_page(rows, boundary, spec) do
    {has_more_before, has_more_after} =
      case boundary do
        :latest ->
          {false, false}

        {:before, tuple} ->
          {false, Enum.any?(rows, &(state_row_tuple(&1, spec.order) >= tuple))}

        {:after, tuple} ->
          {Enum.any?(rows, &(state_row_tuple(&1, spec.order) <= tuple)), false}
      end

    %{
      oldest_cursor: nil,
      newest_cursor: nil,
      has_more_before: has_more_before,
      has_more_after: has_more_after
    }
  end

  defp encode_state_cursor(tuple, direction, filter_fingerprint, principal, spec, conn) do
    payload =
      JSON.encode!(%{
        "version" => @state_cursor_version,
        "route" => spec.route,
        "resource" => spec.resource,
        "direction" => direction,
        "filters" => filter_fingerprint,
        "principalKind" => principal.kind,
        "principalId" => principal.id,
        "tuple" => tuple
      })

    signature =
      case Tightbeam.CursorSigning.sign(deps(conn).cursor_signing, payload) do
        {:ok, signature} -> signature
        _error -> raise ArgumentError, "cursor signing unavailable"
      end

    Base.url_encode64(payload, padding: false) <>
      "." <> Base.url_encode64(signature, padding: false)
  end

  defp state_row_tuple(row, order) do
    Enum.map(order, fn {field, _type} -> state_row_value!(row, field) end)
  end

  defp state_row_value!(row, field) when is_map(row) do
    atom = field
    snake = Atom.to_string(field)
    camel = lower_camel(snake)

    cond do
      Map.has_key?(row, atom) -> Map.fetch!(row, atom)
      Map.has_key?(row, snake) -> Map.fetch!(row, snake)
      Map.has_key?(row, camel) -> Map.fetch!(row, camel)
      true -> raise KeyError, key: field, term: row
    end
  end

  defp state_serialize_rows(rows, spec) do
    seam = state_seam!(spec)
    Enum.map(rows, &apply(StateResources, seam.serializer, [&1]))
  end

  defp state_collection_envelope(conn, resource, items, page) do
    catalog = state_catalog(conn)
    item_bytes = Enum.map_join(items, ",", &StateResources.encode_item(resource, &1, catalog))

    "{" <>
      ~s("schemaVersion":1,"resource":#{JSON.encode!(resource)},"items":[#{item_bytes}],) <>
      ~s("page":{"oldestCursor":#{JSON.encode!(page.oldest_cursor)},) <>
      ~s("newestCursor":#{JSON.encode!(page.newest_cursor)},) <>
      ~s("hasMoreBefore":#{JSON.encode!(page.has_more_before)},) <>
      ~s("hasMoreAfter":#{JSON.encode!(page.has_more_after)}}})
  end

  defp state_detail_envelope(resource, item_bytes) do
    "{" <>
      ~s("schemaVersion":1,"resource":#{JSON.encode!(resource)},"item":#{item_bytes}})
  end

  defp state_not_found(conn, resource, started_at) do
    elapsed = System.monotonic_time(:microsecond) - started_at
    remaining = @state_not_found_floor_us - elapsed
    if remaining > 0, do: Process.sleep(div(remaining + 999, 1_000))
    state_error(conn, resource, 404, "not_found", nil)
  end

  defp state_error(conn, resource, status, "identity_not_yours" = code, message) do
    bytes =
      "{" <>
        ~s("schemaVersion":1,"resource":#{JSON.encode!(resource)},) <>
        ~s("error":{"code":#{JSON.encode!(code)},"message":#{JSON.encode!(message)}}})

    state_send(conn, status, bytes)
  end

  defp state_error(conn, resource, status, code, _message) do
    bytes =
      "{" <>
        ~s("schemaVersion":1,"resource":#{JSON.encode!(resource)},) <>
        ~s("error":{"code":#{JSON.encode!(code)}}})

    state_send(conn, status, bytes)
  end

  defp state_send(conn, status, bytes) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(status, bytes)
  end

  defp deps(conn), do: conn.private.tightbeam_deps
  defp db(conn), do: deps(conn)[:db] || Tightbeam.DB
  defp handlers(conn), do: Map.fetch!(deps(conn), :handlers)

  defp state_catalog(conn) do
    case deps(conn)[:model_catalog] || ModelCatalog do
      catalog when is_map(catalog) -> catalog
      server -> ModelCatalog.get(server)
    end
  end

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

  defp dispatch_agent_request(conn, _auth, "cold-start-state", _body) do
    json(conn, 200, %{"result" => ColdStart.state(db(conn))})
  end

  defp dispatch_agent_request(conn, :org, "add-user", body)
       when not is_map_key(body, "as") and not is_map_key(body, "asUser") and
              not is_map_key(body, "asProcess") and not is_map_key(body, "asSession") do
    with :ok <- loopback_bootstrap(conn),
         {:ok, user_id} <- required_string(get_in(body, ["params", "userId"])),
         {:ok, result} <-
           ColdStart.add_first_user(db(conn), user_id, Map.fetch!(deps(conn), :defaults)) do
      json(conn, 200, %{"result" => result})
    else
      {:error, "bootstrap_closed"} ->
        error(conn, 409, "bootstrap_closed", "bootstrap is already claimed")

      {:error, "bootstrap_incomplete"} ->
        error(conn, 409, "bootstrap_incomplete", nil)

      {:error, "bootstrap_failed"} ->
        error(conn, 500, "bootstrap_failed", nil)

      {:error, status, code, message} ->
        error(conn, status, code, message)
    end
  end

  defp dispatch_agent_request(conn, auth, verb, body) do
    with :ok <- allowed_agent_verb(verb),
         {:ok, origin, principal} <- agent_identity(body, auth, conn),
         :ok <- canonical_actor_exists(origin, principal, conn),
         {:ok, session_key, target_meta} <- typed_target(verb, body, conn) do
      call = %{
        verb: verb,
        origin: origin,
        principal: principal,
        firehose_hub: deps(conn)[:firehose_hub] || Tightbeam.Firehose.Hub,
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

  defp loopback_bootstrap(%{remote_ip: {127, _, _, _}}), do: :ok
  defp loopback_bootstrap(%{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: :ok
  defp loopback_bootstrap(_conn), do: {:error, 403, "forbidden", "local bootstrap required"}

  defp canonical_actor_exists("process:" <> _process, _principal, _conn), do: :ok

  # AU2's org/session asUser path is a self-declared, transport-only principal.
  # It is deliberately not an existence assertion; downstream authorization
  # evaluates the same resolved principal used by REST.
  defp canonical_actor_exists("user:" <> user_id, {:user, user_id}, _conn), do: :ok

  defp canonical_actor_exists(_origin, {:user, user_id}, conn),
    do: user_exists(user_id, conn)

  defp canonical_actor_exists(_origin, {:session, session_key}, conn) do
    case Org.get(db(conn), session_key) do
      %{owner_user_id: user_id} -> user_exists(user_id, conn)
      _ -> invalid_identity()
    end
  end

  defp canonical_actor_exists("user:" <> user_id, nil, conn), do: user_exists(user_id, conn)

  defp canonical_actor_exists("agent:" <> role, nil, conn) do
    case Roles.resolve(db(conn), role) do
      {:ok, session_key, _fallback} -> canonical_actor_exists(nil, {:session, session_key}, conn)
      _ -> :ok
    end
  end

  defp canonical_actor_exists(_origin, _principal, _conn), do: :ok

  defp user_exists(user_id, conn) do
    if Devices.user(db(conn), user_id), do: :ok, else: invalid_identity()
  end

  defp invalid_identity,
    do: {:error, 403, "invalid_identity", "asserted user does not exist"}

  defp agent_identity(%{"asProcess" => "tightbeam"}, :org, _conn) do
    {:error, 403, "reserved_origin", "process:tightbeam is reserved to the substrate"}
  end

  defp agent_identity(body, :org, conn) do
    with {:ok, origin} <- agent_origin(body, conn),
         {:ok, principal} <- agent_principal(body, :org) do
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

      is_binary(body["asUser"]) ->
        case resolve_cli_as_user({:session, session}, body["asUser"]) do
          {:ok, principal} -> {:ok, "user:#{session.owner_user_id}", principal}
          error -> error
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

  defp agent_principal(body, auth) do
    cond do
      is_binary(body["as"]) and body["as"] != "" ->
        {:ok, nil}

      is_binary(body["asUser"]) and body["asUser"] != "" ->
        resolve_cli_as_user(auth, body["asUser"])

      is_binary(body["asProcess"]) and body["asProcess"] != "" ->
        {:ok, {:process, body["asProcess"]}}

      true ->
        {:ok, nil}
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
  # `answer` joins them because it addresses a REQUEST ID, never a principal: the
  # row already records who was asked. Resolving a volunteered `--session` here
  # would answer "does this session exist?" ahead of the answerer check that
  # actually decides. (`ask` is deliberately NOT here — its target IS a
  # principal, resolved by the same machinery `wake` uses.)
  # `digest-members` (O5) addresses a WAKE ID, never a principal — its own
  # owner-or-admin check (mirroring `coordination-share`'s) is the read's
  # actual gate, and a volunteered `--session` alongside `--wake-id` must not
  # get answered by the router first.
  @non_target_verbs ~w(transcript turn-trace toplines topline coordination-share digest-members answer return operator-ask operator-rule operator-withdraw decision-request decision-requests)

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

        # F6 (Sol xhigh review): a value this seam does not know how to read
        # (a number, a bool, an object) is NOT a field value it silently
        # discards. Dropping it here used to hand the gateway a params map
        # indistinguishable from "the caller named nothing", which activated
        # the destination's default — the caller's malformed input read back
        # as `ok: true` on a switch it never elected. Carried through AS SENT
        # instead, so the gateway's own field validation names it
        # (`invalid_model_field`), not this mapper's silence.
        {:ok, value} ->
          Map.put(params, String.to_existing_atom(key), value)

        :error ->
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

      {:error,
       %{
         code: "decision_request_integrity_invalid",
         message: message,
         request_id: request_id
       }} ->
        json(conn, 500, %{
          "error" => %{
            "code" => "decision_request_integrity_invalid",
            "message" => message,
            "requestId" => request_id
          }
        })

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
  defp error_status("decision_request_integrity_invalid"), do: 500
  defp error_status("decision_request_integrity_evidence_conflict"), do: 500
  defp error_status("decision_request_integrity_evidence_unavailable"), do: 500
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
    "operator-rule" => ~w(ruled_via_session_key ruled_via_principal ruled_via_session_state)a,
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
  #
  # `tune.reasoningLevel` is the second: `Macro.underscore` turns the wire word
  # into `:reasoning_level`, but the handler reads `:reasoningLevel` — the raw
  # COLUMN spelling, which the device path builds by hand and so never went
  # through atomization. Without this alias an agent's `--effort` crossed
  # `/agent/dispatch`, matched no branch, and came back "tune does not support
  # set_reasoning yet": a caller's explicit election answered as an unbuilt
  # feature.
  @param_aliases %{
    "assign" => %{reviews: :reviews_assignment_id},
    "tune" => %{reasoning_level: :reasoningLevel}
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
