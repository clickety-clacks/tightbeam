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

  @websocket_read_timeout :infinity

  alias Tightbeam.{
    Assets,
    CliCompatibility,
    ConditionFacts,
    D1Read,
    Devices,
    Dispatch,
    ErrorDiagnostic,
    Org,
    Roles,
    WorkItems,
    WorkState
  }

  alias Tightbeam.Wire.{ChangeSocket, Payloads, Socket}
  alias Tightbeam.{ModelCatalog, StateResources}

  Module.register_attribute(__MODULE__, :agent_verbs, persist: true)

  @agent_verbs ~w(ask answer return wake condition facts-read artifact-record artifact-get artifacts memento-set mementos harklight-send harklight-revise harklight-retract harklight-settle spawn session-reparent session-po-set retire critical inspect cancel settle-turn tune approve-device deny-device revoke-device promote-user add-user config register-host host-env-set host-env-list host-env-unset host-toolchain-set update-clients identity-edit identity-status identity-relearn identity-repoint learn unlearn kungfu-list kungfu-setup sentinel-enable sentinel-disable sentinel-list identity-apply kungfu-scaffold onboard role-create role-bind role-rm role-list assign dispatch assignment-get attest attests revoke-assignment reopen-assignment repair-assignment assignments work-item-create work-item-handoff work-item-get breathing work-item-trace work-item-list work-item-update work-item-icebox work-item-reopen work-item-close work-item-fail rule effort-rule waive revoke-waiver withdraw operator-ask operator-rule operator-withdraw decision-requests decision-request transcript attend execution-map execution-map-select toplines topline topline-create topline-update topline-close topline-reopen topline-link-work topline-unlink-work topline-concern-create topline-concern-link-work topline-concern-unlink-work topline-work-leave-unlinked topline-placement-list harness-processes harness-process-settle)
  @agent_verbs @agent_verbs ++
                 [
                   "fact-demand",
                   "fact-producer-claim",
                   "fact-producers",
                   "artifact-content-fetch",
                   "assignment-commitref-correct",
                   "harness-health-observe-other",
                   "harness-health-resolve-other",
                   "harness-health-close-promotion",
                   "harness-health-review-other",
                   "harness-health-evidence-other",
                   "subtree-guidance-set",
                   "subtree-guidance-withdraw",
                   "subtree-guidance-show"
                 ]
  @max_upload_bytes 32 * 1024 * 1024
  @state_malformed_percent_escape ~r/%(?![0-9A-Fa-f]{2})/
  @core_detail_fact_id ~r/\A[1-9][0-9]*\z/
  @core_detail_specs %{
    work_items: %{resource: "work items", query: :query_work_item, serializer: :work_item},
    assignments: %{resource: "assignments", query: :query_assignment, serializer: :assignment},
    attests: %{resource: "attests", query: :query_attest, serializer: :attest},
    wakes: %{resource: "wakes", query: :query_wake, serializer: :wake},
    turns: %{resource: "turns", query: :query_turn_by_seq, serializer: :turn},
    decision_requests: %{
      resource: "decision requests",
      query: :query_decision_request,
      serializer: :decision_request
    },
    sessions: %{resource: "sessions", query: :query_session, serializer: :session},
    messages: %{
      resource: "transcript messages",
      query: :query_message,
      serializer: :message
    },
    tool_calls: %{
      resource: "tool calls",
      query: :query_tool_call,
      serializer: :tool_call
    },
    roles: %{resource: "roles", query: :query_role, serializer: :role},
    facts: %{
      resource: "condition facts",
      query: :query_condition_fact,
      serializer: :condition_fact
    },
    critical_state: %{
      resource: "critical state",
      query: :query_critical_state,
      serializer: :critical_state
    },
    host_environment: %{
      resource: "host environment",
      query: :query_host_environment,
      serializer: :host_environment
    },
    devices: %{resource: "devices", query: :query_device, serializer: :device},
    artifacts: %{resource: "artifacts", query: :query_artifact, serializer: :artifact},
    read_markers: %{resource: "read markers", query: :query_read_marker, serializer: :read_marker}
  }

  # D1, streams, and work open at 50; session and nested history preserve 500.
  # Every pageable route caps a request at 500 rows.
  @d1_default_limit 50
  @d1_max_limit 500
  @state_default_limit 50
  @state_history_default_limit 500
  @state_max_limit 500
  @d1_cursor_version 1
  @d1_resources %{
    assignments: %{
      resource: "assignments",
      route: "assignments.collection",
      filters: [],
      order: ~w(openedAt id)
    },
    wakes: %{
      resource: "wakes",
      route: "wakes.collection",
      filters: [],
      order: ~w(createdAt wakeId)
    },
    turns: %{
      resource: "turns",
      route: "turns.collection",
      filters: [],
      order: ~w(seq)
    },
    execution_map: %{
      resource: "execution map",
      route: "execution_map.collection",
      filters: ~w(origin ownerUserId state quietOverMs specRefName specRefSha256 sessionKey),
      order: ~w(createdAt id)
    },
    work_items: %{
      resource: "work items",
      route: "work_items.collection",
      filters: ~w(state ownerUserId createdBySession createdByUser isBug specRefName holderKey),
      order: ~w(createdAt id)
    },
    artifacts: %{
      resource: "artifacts",
      route: "artifacts.collection",
      filters: ~w(workItemId createdBySession kind state),
      order: ~w(createdAt artifactId)
    },
    harness_processes: %{
      resource: "harness processes",
      route: "harness_processes.collection",
      filters: ~w(host harness state),
      order: ~w(createdAt id)
    },
    assignment_attests: %{
      resource: "attests",
      route: "assignment_attests.collection",
      filters: ~w(assignmentId workItemId kind verdictKind bySession byUser),
      order: ~w(ts id)
    },
    decision_requests: %{
      resource: "decision requests",
      route: "decision_requests.collection",
      filters: ~w(status kind ownerUserId assignmentId raiserSessionKey expecterSessionKey),
      order: ~w(raisedAt id)
    },
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
    Tightbeam.Wire.RequestObservation.call(conn, fn conn ->
      conn
      |> Plug.Conn.put_private(:tightbeam_deps, Map.new(opts))
      |> super(opts)
    end)
  end

  plug(:match)
  plug(:observe_match)
  plug(:dispatch)

  defp observe_match(conn, _opts), do: Tightbeam.Wire.RequestObservation.matched(conn)

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
         conn.query_params["protocolVersion"] == "2" do
      conn = Tightbeam.Wire.ResponseObservationAdapter.unwrap(conn)

      WebSockAdapter.upgrade(conn, ChangeSocket, deps(conn),
        max_frame_size: 2 * 1024 * 1024,
        timeout: @websocket_read_timeout
      )
    else
      Plug.Conn.send_resp(conn, 426, "")
    end
  end

  defp upgrade_socket(conn) do
    if Plug.Conn.get_req_header(conn, "upgrade") == ["websocket"] do
      conn = Tightbeam.Wire.ResponseObservationAdapter.unwrap(conn)

      WebSockAdapter.upgrade(conn, Socket, deps(conn),
        max_frame_size: 2 * 1024 * 1024,
        timeout: @websocket_read_timeout
      )
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
      "features" => ["stale-turn-settlement-v1"],
      "adapters" => health,
      "diagnostics" => diagnostic_health(),
      "schedulerMisses" => Tightbeam.SchedulerMisses.count(),
      "eventPaths" => Tightbeam.SchedulerMisses.health()
    })
  end

  defp diagnostic_health do
    health = Tightbeam.Diagnostics.health()

    %{
      "writeFailures" => health.write_failures,
      "lastFailureAt" => health.last_failure_at,
      "droppedRecords" => health.dropped_records,
      "lastDropAt" => health.last_drop_at
    }
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
      {:error, status, code, message} ->
        error(conn, status, code, message)

      {:error, status, code, message, diagnostic} ->
        error(conn, status, code, message, diagnostic)
    end
  end

  post "/agent/session-diagnose" do
    Tightbeam.SessionDiagnose.handle(conn, deps(conn))
  end

  post "/agent/dispatch" do
    with {:ok, auth} <- cli_auth(conn) do
      with_json(conn, fn body, conn ->
        with {:ok, verb} <- required_string(body["verb"]),
             :ok <- allowed_agent_verb(verb),
             {:ok, origin, principal} <- agent_identity(body, auth, conn),
             {:ok, session_key, target_meta} <- typed_target(verb, body, conn),
             :ok <- visible_cancel_target(verb, session_key, principal, conn) do
          call = %{
            verb: verb,
            origin: origin,
            principal: principal,
            # Retain the authenticated transport separately from the selected origin.
            transport_session_key: authenticated_session_key(auth),
            session_key: artifact_caller_session(verb, session_key, principal),
            target_role: target_meta.role,
            role_fallback: target_meta.fallback,
            params: atomize_params(verb, body["params"] || %{})
          }

          call =
            case Map.get(target_meta, :user_id) do
              user_id when is_binary(user_id) -> Map.put(call, :target_user_id, user_id)
              _ -> call
            end

          call =
            case {verb, principal} do
              {"artifact-content-fetch", {:session, session_key}} ->
                Map.put(call, :rest_principal, %{
                  kind: "session",
                  id: session_key,
                  is_admin: false
                })

              {"artifact-content-fetch", {:process, name}} ->
                Map.put(call, :rest_principal, %{kind: "process", id: name, is_admin: true})

              {"artifact-content-fetch", {:user, user_id}} ->
                Map.put(call, :rest_principal, state_principal_view({:user, user_id}, conn))

              _ ->
                call
            end

          dispatch_response(conn, call, 200, &%{"result" => &1})
        else
          {:error, status, code, message} ->
            error(conn, status, code, message)

          {:error, status, code, message, diagnostic} ->
            error(conn, status, code, message, diagnostic)
        end
      end)
    else
      {:error, status, code, message} ->
        error(conn, status, code, message)

      {:error, status, code, message, diagnostic} ->
        error(conn, status, code, message, diagnostic)
    end
  end

  post "/agent/terminal" do
    with {:ok, {:session, _session}} <- terminal_session_auth(conn),
         :ok <- terminal_version_supported(conn) do
      error(
        conn,
        410,
        "terminal_surrender_removed",
        "terminal surrender was removed; file a typed cannot-proceed attest through /agent"
      )
    else
      {:error, status, code, message} ->
        error(conn, status, code, message)

      {:error, status, code, message, diagnostic} ->
        error(conn, status, code, message, diagnostic)
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
      # Still 200: observation fails open (the hook must never block its tool
      # call), but an unreachable writer is not reported as an observation.
      case Tightbeam.TurnObservations.observe(db(conn), session.session_key) do
        :ok ->
          json(conn, 200, %{"observed" => true})

        {:unavailable, diagnostic} ->
          json(conn, 200, %{"observed" => false, "diagnostic" => diagnostic})
      end
    else
      {:error, status, code, message} ->
        error(conn, status, code, message)

      {:error, status, code, message, diagnostic} ->
        error(conn, status, code, message, diagnostic)
    end
  end

  get "/api/streams" do
    with {:ok, device} <- device_auth(conn),
         {:ok, query} <- decode_state_query(conn),
         :ok <- stream_collection_request(query),
         {:ok, limit, boundary} <-
           state_page_request(
             query,
             "streams.collection",
             "streams",
             %{},
             %{kind: "user", id: device.user_id, is_admin: device.is_admin},
             &stream_tuple?/1,
             @state_default_limit,
             :earliest,
             :earliest,
             :latest
           ) do
      result = Org.list_for_user_page(db(conn), device.user_id, boundary, limit)

      page =
        state_page_metadata(
          result.rows,
          result.flags,
          &stream_tuple/1,
          "streams.collection",
          "streams",
          %{},
          %{kind: "user", id: device.user_id, is_admin: device.is_admin},
          :asc
        )

      streams = Enum.map(result.rows, &Payloads.stream_session/1)
      json(conn, 200, %{"streams" => streams, "page" => page})
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

  get "/api/assignments" do
    d1_collection(conn, Map.fetch!(@d1_resources, :assignments))
  end

  get "/api/assignments/:assignment_id" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :assignments), assignment_id)
  end

  get "/api/assignments/:assignment_id/attests" do
    d1_collection(conn, Map.fetch!(@d1_resources, :assignment_attests), assignment_id)
  end

  get "/api/attests" do
    d2_attests_collection(conn)
  end

  get "/api/attests/:attest_id" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :attests), attest_id)
  end

  get "/api/wakes" do
    d1_collection(conn, Map.fetch!(@d1_resources, :wakes))
  end

  get "/api/wakes/:wake_id" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :wakes), wake_id)
  end

  get "/api/turns" do
    d1_collection(conn, Map.fetch!(@d1_resources, :turns))
  end

  get "/api/turns/:turn_seq" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :turns), turn_seq)
  end

  get "/api/decision-requests/:decision_request_id" do
    core_detail(
      conn,
      Map.fetch!(@core_detail_specs, :decision_requests),
      decision_request_id
    )
  end

  get "/api/sessions" do
    session_index(conn)
  end

  get "/api/sessions/:session_key" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :sessions), session_key)
  end

  get "/api/sessions/:session_key/messages/:message_id" do
    core_detail(
      conn,
      Map.fetch!(@core_detail_specs, :messages),
      {session_key, message_id}
    )
  end

  get "/api/sessions/:session_key/tool-calls/:tool_call_id" do
    core_detail(
      conn,
      Map.fetch!(@core_detail_specs, :tool_calls),
      {session_key, tool_call_id}
    )
  end

  get "/api/roles/:name" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :roles), name)
  end

  get "/api/facts/:fact_id" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :facts), fact_id)
  end

  get "/api/critical-state/:session_key" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :critical_state), session_key)
  end

  get "/api/host-env/:host/:harness/:name" do
    core_detail(
      conn,
      Map.fetch!(@core_detail_specs, :host_environment),
      {host, harness, name}
    )
  end

  get "/api/sessions/:session_key/messages" do
    session_collection(
      conn,
      session_key,
      "transcript messages",
      :query_messages_for_session_page,
      :message
    )
  end

  get "/api/sessions/:session_key/tool-calls" do
    tool_calls_collection(conn, session_key)
  end

  get "/api/sessions/:session_key/wakes" do
    session_collection(conn, session_key, "wakes", :query_wakes_for_session_page, :wake)
  end

  get "/api/sessions/:session_key/turns" do
    session_collection(conn, session_key, "turns", :query_turns_for_session_page, :turn)
  end

  get "/api/devices/:device_id" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :devices), device_id)
  end

  get "/api/artifacts/:artifact_id" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :artifacts), artifact_id)
  end

  get "/api/artifacts" do
    d1_collection(conn, Map.fetch!(@d1_resources, :artifacts))
  end

  get "/api/harness-processes" do
    d1_collection(conn, Map.fetch!(@d1_resources, :harness_processes))
  end

  get "/api/read-markers" do
    read_marker_index(conn)
  end

  get "/api/read-markers/:scope_key" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :read_markers), scope_key)
  end

  post "/api/streams" do
    with {:ok, device} <- device_auth(conn) do
      with_json(conn, fn body, conn ->
        with :ok <- streams_overrides_unsupported(body),
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
            params:
              Map.merge(%{display_name: display_name, idempotency_key: idempotency_key}, picker)
          }

          dispatch_response(conn, call, 201, & &1)
        else
          {:error, status, code, message} ->
            error(conn, status, code, message)

          {:error, status, code, message, diagnostic} ->
            error(conn, status, code, message, diagnostic)
        end
      end)
    else
      {:error, status, code, message} ->
        error(conn, status, code, message)

      {:error, status, code, message, diagnostic} ->
        error(conn, status, code, message, diagnostic)
    end
  end

  patch "/api/streams/:key" do
    with {:ok, device} <- device_auth(conn),
         {:ok, decoded_key} <- decode_session_key_param(key),
         {:ok, session} <- owned_session(decoded_key, device, conn) do
      with_json(conn, fn body, conn ->
        with {:ok, display_name} <- required_string(body["displayName"]) do
          call = %{
            verb: "tune",
            origin: "user:#{device.user_id}",
            session_key: session.session_key,
            params: %{setting: "rename", display_name: display_name}
          }

          dispatch_response(conn, call, 200, & &1)
        else
          {:error, status, code, message} ->
            error(conn, status, code, message)

          {:error, status, code, message, diagnostic} ->
            error(conn, status, code, message, diagnostic)
        end
      end)
    else
      {:error, status, code, message} ->
        error(conn, status, code, message)

      {:error, status, code, message, diagnostic} ->
        error(conn, status, code, message, diagnostic)
    end
  end

  delete "/api/streams/:key" do
    with {:ok, device} <- device_auth(conn) do
      with_json(conn, fn body, conn ->
        with {:ok, decoded_key} <- decode_session_key_param(key),
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
          {:error, status, code, message} ->
            error(conn, status, code, message)

          {:error, status, code, message, diagnostic} ->
            error(conn, status, code, message, diagnostic)
        end
      end)
    else
      {:error, status, code, message} ->
        error(conn, status, code, message)

      {:error, status, code, message, diagnostic} ->
        error(conn, status, code, message, diagnostic)
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
    with {:ok, device} <- device_auth(conn),
         {:ok, query} <- decode_state_query(conn),
         :ok <- work_collection_request(query),
         {:ok, status_value} <- one_query_value(query, "status"),
         {:ok, state_value} <- one_query_value(query, "state"),
         {:ok, session_key} <- one_query_value(query, "sessionKey"),
         :ok <- work_session_filter(session_key),
         {:ok, statuses} <- work_status_filter(status_value),
         {:ok, state} <- work_state_filter(state_value),
         filters <- %{
           status: if(is_nil(statuses), do: nil, else: Enum.sort(Enum.uniq(statuses))),
           state: state,
           session_key: session_key,
           owner_user_id: if(device.is_admin, do: nil, else: device.user_id)
         },
         cursor_filters <- work_cursor_filters(filters),
         {:ok, limit, boundary} <-
           state_page_request(
             query,
             "work.collection",
             "work",
             cursor_filters,
             %{kind: "user", id: device.user_id, is_admin: device.is_admin},
             &work_tuple?/1,
             @state_default_limit,
             :latest,
             :latest,
             :earliest
           ) do
      result = WorkState.page(db(conn), filters, boundary, limit)

      page =
        state_page_metadata(
          result.work,
          %{has_more_before: result.has_more_before, has_more_after: result.has_more_after},
          &work_tuple/1,
          "work.collection",
          "work",
          cursor_filters,
          %{kind: "user", id: device.user_id, is_admin: device.is_admin},
          :desc
        )

      json(conn, 200, %{"work" => result.work, "cursor" => result.cursor, "page" => page})
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
    d1_collection(conn, Map.fetch!(@d1_resources, :work_items))
  end

  get "/api/work-items/:id/trace" do
    d2c_work_item_trace(conn, id)
  end

  get "/api/execution-map" do
    d2b_execution_map(conn, :flat, nil)
  end

  get "/api/execution-map/tree" do
    d2b_execution_map(conn, :tree, nil)
  end

  get "/api/execution-map/subtrees/:work_item_id" do
    d2b_execution_map(conn, :subtree, work_item_id)
  end

  get "/api/execution-map/assignments" do
    d2b_execution_map(conn, :assignments, nil)
  end

  get "/api/decision-requests" do
    d1_collection(conn, Map.fetch!(@d1_resources, :decision_requests))
  end

  get "/api/work-items/:id" do
    core_detail(conn, Map.fetch!(@core_detail_specs, :work_items), id)
  end

  post "/api/session-control" do
    with {:ok, device} <- device_auth(conn) do
      with_json(conn, fn body, conn ->
        with key = to_string(body["sessionKey"] || ""),
             {:ok, _session} <- visible_session(key, device, conn),
             {:ok, verb, params} <- control_call(body) do
          action = body["action"]

          call = %{
            verb: verb,
            origin: "user:#{device.user_id}",
            principal: {:user, device.user_id},
            session_key: key,
            params: params
          }

          control_response(conn, call, key, action)
        else
          {:error, status, code, message} ->
            error(conn, status, code, message)

          {:error, status, code, message, diagnostic} ->
            error(conn, status, code, message, diagnostic)
        end
      end)
    else
      {:error, status, code, message} ->
        error(conn, status, code, message)

      {:error, status, code, message, diagnostic} ->
        error(conn, status, code, message, diagnostic)
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

  defp core_detail(conn, spec, raw_key) do
    with {:ok, auth} <-
           core_detail_operation(conn, spec.resource, :bearer_auth, fn ->
             core_detail_auth(conn, spec.resource)
           end),
         {:ok, query} <-
           core_detail_operation(conn, spec.resource, :query_decode, fn ->
             observer_read_query(conn, spec.resource)
           end),
         {:ok, principal} <-
           core_detail_operation(
             conn,
             spec.resource,
             :principal_resolution,
             fn -> core_detail_route_principal(auth, query, conn, spec.resource) end
           ),
         :ok <-
           core_detail_operation(
             conn,
             spec.resource,
             :request_validation,
             fn -> state_detail_request(query) end
           ),
         {:ok, key} <-
           core_detail_operation(
             conn,
             spec.resource,
             :key_decode,
             fn -> core_detail_key(spec.resource, raw_key) end
           ) do
      if observer_marker_scope_detail?(spec, principal, query) do
        read_marker_index_page(conn, query, principal,
          scope_key: key,
          not_found_when_empty?: true
        )
      else
        core_detail_item(conn, spec, key, principal)
      end
    else
      {:error, :not_found} ->
        state_not_found(conn, spec.resource)

      {:error, status, code, message} ->
        state_error(conn, spec.resource, status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      state_error(conn, spec.resource, 500, "projection_invalid", nil)
  end

  defp core_detail_item(conn, spec, key, principal) do
    with :ok <- core_detail_probe(conn, spec.resource, :lookup),
         row <-
           core_detail_operation(
             conn,
             spec.resource,
             :row_lookup,
             fn ->
               core_detail_row(conn, spec, key, core_detail_trace_principal(conn, principal))
             end
           ),
         true <- not is_nil(row),
         :ok <- core_detail_probe(conn, spec.resource, :schema),
         :ok <- core_detail_probe(conn, spec.resource, :serializer),
         item <- core_detail_serialize(conn, spec, row),
         :ok <- core_detail_probe(conn, spec.resource, :encoder),
         item_bytes <- core_detail_encode(conn, spec.resource, item),
         :ok <- core_detail_probe(conn, spec.resource, :envelope) do
      core_detail_trace(conn, {:envelope, spec.resource})
      state_send(conn, 200, state_detail_envelope(spec.resource, item_bytes))
    else
      false -> state_not_found(conn, spec.resource)
      {:error, :not_found} -> state_not_found(conn, spec.resource)
      {:error, status, code, message} -> state_error(conn, spec.resource, status, code, message)
    end
  end

  defp observer_marker_scope_detail?(%{resource: "read markers"}, %{kind: "observer"}, query),
    do: is_nil(observer_as_user(query))

  defp observer_marker_scope_detail?(_spec, _principal, _query), do: false

  defp read_marker_index(conn) do
    with {:ok, auth} <-
           core_detail_operation(conn, "read markers", :bearer_auth, fn ->
             core_detail_auth(conn, "read markers")
           end),
         {:ok, query} <-
           core_detail_operation(conn, "read markers", :query_decode, fn ->
             observer_read_query(conn, "read markers")
           end),
         {:ok, principal} <-
           core_detail_operation(conn, "read markers", :principal_resolution, fn ->
             read_marker_collection_principal(auth, query, conn)
           end) do
      read_marker_index_page(conn, query, principal)
    else
      {:error, status, code, message} -> state_error(conn, "read markers", status, code, message)
    end
  end

  defp read_marker_index_page(conn, query, principal, opts \\ []) do
    query =
      case Keyword.fetch(opts, :scope_key) do
        {:ok, scope_key} -> Map.put(query, "scopeKey", [scope_key])
        :error -> query
      end

    not_found_when_empty? = Keyword.get(opts, :not_found_when_empty?, false)

    with :ok <-
           core_detail_operation(conn, "read markers", :request_validation, fn ->
             read_marker_collection_request(query)
           end),
         {:ok, scope_key} <- one_query_value(query, "scopeKey"),
         true <- is_nil(scope_key) or scope_key != "",
         filters <- if(scope_key, do: %{"scopeKey" => [scope_key]}, else: %{}),
         {:ok, limit, boundary} <-
           observer_aware_state_page_request(
             query,
             "read_markers.collection",
             "read markers",
             filters,
             principal,
             &read_marker_tuple?/1,
             @state_default_limit,
             :earliest,
             :earliest,
             :latest
           ),
         :ok <- core_detail_probe(conn, "read markers", :lookup),
         page_result <-
           core_detail_operation(conn, "read markers", :row_lookup, fn ->
             StateResources.query_read_markers_page(
               db(conn),
               core_detail_trace_principal(conn, principal),
               scope_key,
               boundary,
               limit
             )
           end),
         false <- not_found_when_empty? and page_result.rows == [],
         page <-
           state_page_metadata(
             page_result.rows,
             page_result.flags,
             &read_marker_tuple/1,
             "read_markers.collection",
             "read markers",
             filters,
             principal,
             :asc
           ),
         :ok <- core_detail_probe(conn, "read markers", :schema),
         :ok <- core_detail_probe(conn, "read markers", :serializer),
         item_bytes <- read_marker_index_item_bytes(page_result.rows, state_catalog(conn)),
         :ok <- core_detail_probe(conn, "read markers", :encoder),
         :ok <- core_detail_probe(conn, "read markers", :envelope) do
      core_detail_trace(conn, {:envelope, "read markers"})

      body =
        "{" <>
          ~s("schemaVersion":1,"resource":"read markers","items":[#{item_bytes}],"page":#{JSON.encode!(page)}})

      state_send(conn, 200, body)
    else
      true -> state_not_found(conn, "read markers")
      false -> state_error(conn, "read markers", 400, "invalid_filter", nil)
      {:error, status, code, message} -> state_error(conn, "read markers", status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      state_error(conn, "read markers", 500, "projection_invalid", nil)
  end

  defp read_marker_index_item_bytes(rows, catalog) do
    Enum.map_join(rows, ",", fn row ->
      StateResources.encode_item("read markers", StateResources.read_marker(row), catalog)
    end)
  end

  defp read_marker_tuple(%{user_id: user_id, scope_key: scope_key}), do: [user_id, scope_key]

  defp read_marker_tuple?([user_id, scope_key]),
    do: is_binary(user_id) and user_id != "" and is_binary(scope_key) and scope_key != ""

  defp read_marker_tuple?(_tuple), do: false

  defp read_marker_collection_request(query) do
    if Enum.all?(
         Map.keys(query),
         &(&1 in ["asUser", "scopeKey", "limit", "before", "after", "tail"])
       ),
       do: :ok,
       else: {:error, 400, "invalid_filter", nil}
  end

  defp core_detail_auth(conn, resource)
       when resource in ["sessions", "transcript messages", "read markers"] do
    observer_read_auth(conn)
  end

  defp core_detail_auth(conn, _resource), do: state_bearer_auth(conn)

  defp core_detail_route_principal(auth, query, conn, resource)
       when resource in ["sessions", "transcript messages", "read markers"],
       do: observer_read_route_principal(auth, query, conn)

  defp core_detail_route_principal(auth, query, conn, _resource),
    do: state_principal(auth, query, conn)

  defp read_marker_collection_principal(auth, query, conn),
    do: observer_read_route_principal(auth, query, conn)

  defp observer_read_route_principal(:observer, query, conn),
    do: observer_principal_for_query(query, conn)

  defp observer_read_route_principal({:session, session} = auth, query, conn) do
    case observer_as_user(query) do
      nil ->
        state_principal(auth, Map.delete(query, "asUser"), conn)

      user_id ->
        case resolve_cli_as_user(auth, user_id) do
          {:ok, principal} ->
            {:ok, state_principal_view(principal, conn)}

          {:error, _status, _code, _message} ->
            state_principal(auth, Map.delete(query, "asUser"), conn)
        end
    end
  end

  defp observer_read_route_principal({:device, _device} = auth, query, conn),
    do: state_principal(auth, Map.delete(query, "asUser"), conn)

  defp observer_read_route_principal(auth, query, conn),
    do: state_principal(auth, query, conn)

  defp observer_principal_for_query(query, conn) do
    case observer_as_user(query) do
      nil -> {:ok, observer_principal()}
      user_id -> observer_user_principal(user_id, conn)
    end
  end

  # Observer reads normalize repeated asUser values to the caller's last value.
  defp observer_as_user(query) do
    case Map.get(query, "asUser", []) do
      [user_id | _earlier] when is_binary(user_id) and user_id != "" -> user_id
      _absent_or_unusable -> nil
    end
  end

  defp observer_user_principal(user_id, conn) do
    with {:ok, principal} <- resolve_cli_as_user(:org, user_id) do
      {:ok, state_principal_view(principal, conn)}
    end
  end

  defp observer_read_auth(conn) do
    case state_bearer_auth(conn) do
      {:error, 401, "auth_failed", _message} -> {:ok, :observer}
      result -> result
    end
  end

  defp observer_principal, do: %{kind: "observer", id: "observer", is_admin: false}

  defp session_index(conn) do
    with {:ok, auth} <-
           core_detail_operation(conn, "sessions", :bearer_auth, fn ->
             core_detail_auth(conn, "sessions")
           end),
         {:ok, query} <-
           core_detail_operation(conn, "sessions", :query_decode, fn ->
             observer_read_query(conn, "sessions")
           end),
         {:ok, principal} <-
           core_detail_operation(conn, "sessions", :principal_resolution, fn ->
             core_detail_route_principal(auth, query, conn, "sessions")
           end),
         :ok <-
           core_detail_operation(conn, "sessions", :request_validation, fn ->
             session_index_request(query)
           end),
         {:ok, limit, boundary} <-
           observer_aware_state_page_request(
             query,
             "sessions.collection",
             "sessions",
             %{},
             principal,
             &session_tuple?/1,
             @state_history_default_limit,
             :earliest,
             :earliest,
             :latest
           ),
         :ok <- core_detail_probe(conn, "sessions", :lookup),
         page_result <-
           core_detail_operation(conn, "sessions", :row_lookup, fn ->
             StateResources.query_sessions_page(
               db(conn),
               core_detail_trace_principal(conn, principal),
               boundary,
               limit
             )
           end),
         page <-
           state_page_metadata(
             page_result.rows,
             page_result.flags,
             &session_tuple/1,
             "sessions.collection",
             "sessions",
             %{},
             principal,
             :asc
           ),
         :ok <- core_detail_probe(conn, "sessions", :schema),
         :ok <- core_detail_probe(conn, "sessions", :serializer),
         item_bytes <- session_index_item_bytes(page_result.rows, state_catalog(conn)),
         :ok <- core_detail_probe(conn, "sessions", :encoder),
         :ok <- core_detail_probe(conn, "sessions", :envelope) do
      core_detail_trace(conn, {:envelope, "sessions"})

      body =
        "{" <>
          ~s("schemaVersion":1,"resource":"sessions","items":[#{item_bytes}],"page":#{JSON.encode!(page)}})

      state_send(conn, 200, body)
    else
      {:error, status, code, message} -> state_error(conn, "sessions", status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      state_error(conn, "sessions", 500, "projection_invalid", nil)
  end

  defp session_index_item_bytes(rows, catalog) do
    Enum.map_join(rows, ",", fn row ->
      StateResources.encode_item("sessions", StateResources.session(row), catalog)
    end)
  end

  defp session_index_request(query) do
    if Enum.all?(Map.keys(query), &(&1 in ["asUser", "limit", "before", "after", "tail"])),
      do: :ok,
      else: {:error, 400, "invalid_filter", nil}
  end

  defp stream_collection_request(query) do
    if Enum.all?(Map.keys(query), &(&1 in ["limit", "before", "after", "tail"])),
      do: :ok,
      else: {:error, 400, "invalid_filter", nil}
  end

  defp work_collection_request(query) do
    if Enum.all?(
         Map.keys(query),
         &(&1 in ["status", "state", "sessionKey", "limit", "before", "after", "tail"])
       ),
       do: :ok,
       else: {:error, 400, "invalid_filter", nil}
  end

  defp work_session_filter(nil), do: :ok
  defp work_session_filter(value) when is_binary(value) and value != "", do: :ok
  defp work_session_filter(_value), do: {:error, 400, "invalid_filter", nil}

  defp work_cursor_filters(filters) do
    %{"state" => [filters.state]}
    |> maybe_put_filter("status", filters.status)
    |> maybe_put_filter("sessionKey", filters.session_key)
  end

  defp maybe_put_filter(filters, _field, nil), do: filters

  defp maybe_put_filter(filters, field, values) when is_list(values),
    do: Map.put(filters, field, values)

  defp maybe_put_filter(filters, field, value), do: Map.put(filters, field, [value])

  defp state_page_request(
         query,
         route,
         resource,
         filters,
         principal,
         tuple_valid?,
         default_limit,
         default,
         head_boundary,
         tail_boundary
       ) do
    with {:ok, limit} <- state_page_limit(Map.get(query, "limit", []), default_limit),
         {:ok, before_cursor} <- state_page_cursor_value(query, "before"),
         {:ok, after_cursor} <- state_page_cursor_value(query, "after"),
         true <- is_nil(before_cursor) or is_nil(after_cursor),
         {:ok, tail_option} <- state_page_tail(Map.get(query, "tail", [])) do
      case {before_cursor, after_cursor, tail_option} do
        {cursor, nil, nil} when is_binary(cursor) ->
          with {:ok, tuple} <-
                 state_cursor_decode(
                   cursor,
                   "before",
                   route,
                   resource,
                   filters,
                   principal,
                   tuple_valid?
                 ) do
            {:ok, limit, {:before, tuple}}
          end

        {nil, cursor, nil} when is_binary(cursor) ->
          with {:ok, tuple} <-
                 state_cursor_decode(
                   cursor,
                   "after",
                   route,
                   resource,
                   filters,
                   principal,
                   tuple_valid?
                 ) do
            {:ok, limit, {:after, tuple}}
          end

        {nil, nil, nil} ->
          {:ok, limit, default}

        {nil, nil, true} ->
          {:ok, limit, tail_boundary}

        {nil, nil, false} ->
          {:ok, limit, head_boundary}

        _ ->
          {:error, 400, "invalid_cursor", nil}
      end
    else
      false -> {:error, 400, "invalid_cursor", nil}
      {:error, _status, _code, _message} = error -> error
      _ -> {:error, 400, "invalid_cursor", nil}
    end
  end

  defp observer_aware_state_page_request(
         query,
         route,
         resource,
         filters,
         principal,
         tuple_valid?,
         default_limit,
         default,
         head_boundary,
         tail_boundary
       ) do
    result =
      state_page_request(
        query,
        route,
        resource,
        filters,
        principal,
        tuple_valid?,
        default_limit,
        default,
        head_boundary,
        tail_boundary
      )

    case result do
      {:error, 400, "invalid_cursor", nil} = error ->
        if page_cursor_for_other_principal?(
             query,
             route,
             resource,
             filters,
             principal,
             tuple_valid?
           ) do
          with {:ok, limit} <- state_page_limit(Map.get(query, "limit", []), default_limit),
               do: {:ok, limit, default}
        else
          error
        end

      other ->
        other
    end
  end

  defp page_cursor_for_other_principal?(query, route, resource, filters, principal, tuple_valid?) do
    Enum.any?(["before", "after"], fn direction ->
      other_direction = if direction == "before", do: "after", else: "before"

      with {:ok, cursor} when is_binary(cursor) <- state_page_cursor_value(query, direction),
           {:ok, nil} <- state_page_cursor_value(query, other_direction),
           {:ok, nil} <- state_page_tail(Map.get(query, "tail", [])),
           true <- cursor != "",
           {:ok, bytes} <- Base.url_decode64(cursor, padding: false),
           {:ok, payload} when is_map(payload) <- JSON.decode(bytes),
           true <- Enum.sort(Map.keys(payload)) == d1_cursor_keys(),
           true <- payload["version"] == @d1_cursor_version,
           true <- payload["route"] == route and payload["resource"] == resource,
           true <- payload["direction"] == direction,
           true <- payload["filters"] == d1_filter_fingerprint(filters),
           true <-
             payload["principalKind"] != state_cursor_principal_kind(principal) or
               payload["principalId"] != Map.get(principal, :id),
           true <- tuple_valid?.(payload["tuple"]) do
        true
      else
        _ -> false
      end
    end)
  rescue
    _error in [ArgumentError, KeyError, MatchError] -> false
  end

  defp state_page_limit([], default), do: {:ok, default}

  defp state_page_limit([value], _default) do
    if value =~ ~r/^[1-9][0-9]*$/ and String.to_integer(value) <= @state_max_limit,
      do: {:ok, String.to_integer(value)},
      else: {:error, 400, "invalid_limit", nil}
  end

  defp state_page_limit(_values, _default), do: {:error, 400, "invalid_limit", nil}

  defp state_page_cursor_value(query, key) do
    case Map.get(query, key, []) do
      [] -> {:ok, nil}
      [value] when value != "" -> {:ok, value}
      _ -> {:error, 400, "invalid_cursor", nil}
    end
  end

  defp state_page_tail([]), do: {:ok, nil}
  defp state_page_tail(["true"]), do: {:ok, true}
  defp state_page_tail(["false"]), do: {:ok, false}
  defp state_page_tail(_values), do: {:error, 400, "invalid_filter", nil}

  defp state_cursor_decode(cursor, direction, route, resource, filters, principal, tuple_valid?) do
    with {:ok, bytes} <- Base.url_decode64(cursor, padding: false),
         {:ok, payload} when is_map(payload) <- JSON.decode(bytes),
         true <- Enum.sort(Map.keys(payload)) == d1_cursor_keys(),
         true <- payload["version"] == @d1_cursor_version,
         true <- payload["route"] == route and payload["resource"] == resource,
         true <- payload["direction"] == direction,
         true <- payload["filters"] == d1_filter_fingerprint(filters),
         true <- payload["principalKind"] == state_cursor_principal_kind(principal),
         true <- payload["principalId"] == principal.id,
         true <- tuple_valid?.(payload["tuple"]) do
      {:ok, payload["tuple"]}
    else
      _ -> {:error, 400, "invalid_cursor", nil}
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] -> {:error, 400, "invalid_cursor", nil}
  end

  defp state_page_metadata(rows, flags, tuple, route, resource, filters, principal, sort) do
    {oldest, newest} =
      case {rows, sort} do
        {[], _} -> {nil, nil}
        {items, :asc} -> {hd(items), List.last(items)}
        {items, :desc} -> {List.last(items), hd(items)}
      end

    %{
      "oldestCursor" =>
        if(oldest,
          do: state_cursor_encode(tuple.(oldest), "before", route, resource, filters, principal)
        ),
      "newestCursor" =>
        if(newest,
          do: state_cursor_encode(tuple.(newest), "after", route, resource, filters, principal)
        ),
      "hasMoreBefore" => flags.has_more_before,
      "hasMoreAfter" => flags.has_more_after
    }
  end

  defp state_cursor_encode(tuple, direction, route, resource, filters, principal) do
    JSON.encode!(%{
      "version" => @d1_cursor_version,
      "route" => route,
      "resource" => resource,
      "direction" => direction,
      "filters" => d1_filter_fingerprint(filters),
      "principalKind" => state_cursor_principal_kind(principal),
      "principalId" => principal.id,
      "tuple" => tuple
    })
    |> Base.url_encode64(padding: false)
  end

  defp state_cursor_principal_kind(%{kind: "user", is_admin: true}), do: "user-admin"
  defp state_cursor_principal_kind(%{kind: kind}), do: kind

  defp one_query_value(query, key) do
    case Map.get(query, key, []) do
      [] -> {:ok, nil}
      [value] -> {:ok, value}
      _ -> {:error, 400, "invalid_filter", nil}
    end
  end

  defp session_tuple(%{created_at: created_at, session_key: session_key}),
    do: [created_at, session_key]

  defp session_tuple?([created_at, session_key]),
    do: is_integer(created_at) and is_binary(session_key) and session_key != ""

  defp session_tuple?(_tuple), do: false

  defp session_collection_tuple("transcript messages", %{seq: seq}), do: [seq]
  defp session_collection_tuple("turns", %{seq: seq}), do: [seq]
  defp session_collection_tuple("tool calls", %{seq: seq, id: id}), do: [seq, id]

  defp session_collection_tuple("wakes", %{created_at: created_at, wake_id: wake_id}),
    do: [created_at, wake_id]

  defp session_collection_tuple?(resource, [seq])
       when resource in ["transcript messages", "turns"] and is_integer(seq) and seq > 0,
       do: true

  defp session_collection_tuple?("tool calls", [seq, id]),
    do: is_integer(seq) and seq > 0 and is_binary(id) and id != ""

  defp session_collection_tuple?(
         "wakes",
         [created_at, wake_id]
       ),
       do: is_integer(created_at) and is_binary(wake_id) and wake_id != ""

  defp session_collection_tuple?(_resource, _tuple), do: false

  defp stream_tuple(%{
         order_index: order_index,
         created_at: created_at,
         session_key: session_key
       }),
       do: [order_index, created_at, session_key]

  defp stream_tuple?([order_index, created_at, session_key]),
    do:
      is_integer(order_index) and is_integer(created_at) and is_binary(session_key) and
        session_key != ""

  defp stream_tuple?(_tuple), do: false

  defp work_tuple(%{openedAt: opened_at, id: id}), do: [opened_at, id]
  defp work_tuple?([opened_at, id]), do: is_integer(opened_at) and is_binary(id) and id != ""
  defp work_tuple?(_tuple), do: false

  defp session_collection(conn, session_key, resource, query_fun, serializer) do
    auth_result =
      if resource == "transcript messages",
        do: session_message_auth(conn),
        else: selected_session_auth(conn)

    with {:ok, auth} <- auth_result,
         {:ok, request} <- observer_read_query(conn, resource),
         {:ok, principal, request} <-
           session_collection_principal(auth, request, conn, session_key, resource),
         :ok <- session_collection_request(request, session_key),
         {:ok, limit, boundary} <-
           observer_aware_state_page_request(
             request,
             "session.#{resource}.collection:#{session_key}",
             resource,
             %{},
             principal,
             &session_collection_tuple?(resource, &1),
             @state_history_default_limit,
             if(resource == "transcript messages", do: :latest, else: :earliest),
             :earliest,
             :latest
           ),
         session when not is_nil(session) <-
           session_collection_session(db(conn), session_key, principal),
         page_result <- apply(StateResources, query_fun, [db(conn), session_key, boundary, limit]),
         page <-
           state_page_metadata(
             page_result.rows,
             page_result.flags,
             &session_collection_tuple(resource, &1),
             "session.#{resource}.collection:#{session_key}",
             resource,
             %{},
             principal,
             :asc
           ),
         items <- Enum.map(page_result.rows, &apply(StateResources, serializer, [&1])) do
      body = %{
        "schemaVersion" => 1,
        "resource" => resource,
        "items" => items,
        "page" => page
      }

      state_send(conn, 200, JSON.encode!(body))
    else
      nil -> state_error(conn, resource, 404, "not_found", nil)
      {:error, status, code, message} -> state_error(conn, resource, status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      state_error(conn, resource, 500, "projection_invalid", nil)
  end

  defp session_collection_session(db, session_key, %{kind: "observer"}),
    do: StateResources.query_session(db, session_key)

  defp session_collection_session(db, session_key, principal),
    do: StateResources.query_session(db, %{key: session_key, principal: principal})

  defp session_message_auth(conn) do
    case selected_session_auth(conn) do
      {:error, 401, "auth_failed", _message} -> {:ok, :observer}
      result -> result
    end
  end

  # REST state API v1 AU1a makes an unselected transcript read an observer read.
  # Organization credentials can still select a user for this session's collection.
  defp session_collection_principal(:org, query, conn, session_key, resource) do
    case Map.get(query, "asUser", []) do
      [] ->
        principal =
          if resource == "transcript messages",
            do: observer_principal(),
            else: org_read_principal(conn)

        {:ok, principal, Map.delete(query, "asUser")}

      [user_id] when user_id != "" ->
        case Tightbeam.Wire.OperatorSession.resolve(db(conn), %{
               "asUser" => user_id,
               "sessionKey" => session_key
             }) do
          {:ok, user, _session} ->
            Tightbeam.RequestContext.resolve_principal("user", user.user_id)
            principal = %{kind: "user", id: user.user_id, is_admin: user.is_admin}
            {:ok, principal, Map.delete(query, "asUser")}

          {:error, _} ->
            {:error, 404, "not_found", nil}
        end

      _ ->
        {:error, 400, "invalid_as_user", nil}
    end
  end

  defp session_collection_principal(:observer, query, conn, session_key, "transcript messages") do
    case observer_as_user(query) do
      nil ->
        {:ok, observer_principal(), Map.delete(query, "asUser")}

      user_id ->
        session_collection_principal(
          :org,
          Map.put(query, "asUser", [user_id]),
          conn,
          session_key,
          "transcript messages"
        )
    end
  end

  defp session_collection_principal(
         {:session, bearer_session_key} = auth,
         query,
         conn,
         _session_key,
         "transcript messages"
       ) do
    request = Map.delete(query, "asUser")

    case Map.get(query, "asUser", []) do
      [user_id] ->
        case Org.get(db(conn), bearer_session_key) do
          %{owner_user_id: _owner} = bearer_session ->
            case resolve_cli_as_user({:session, bearer_session}, user_id) do
              {:ok, principal} ->
                {:ok, state_principal_view(principal, conn), request}

              {:error, _status, _code, _message} ->
                with {:ok, principal} <- selected_session_principal(auth, request, conn),
                     do: {:ok, principal, request}
            end

          nil ->
            {:error, 404, "not_found", nil}
        end

      [] ->
        with {:ok, principal} <- selected_session_principal(auth, request, conn),
             do: {:ok, principal, request}
    end
  end

  defp session_collection_principal(
         {:device, _user_id, _is_admin} = auth,
         query,
         conn,
         _session_key,
         "transcript messages"
       ) do
    request = Map.delete(query, "asUser")

    with {:ok, principal} <- selected_session_principal(auth, request, conn),
         do: {:ok, principal, request}
  end

  defp session_collection_principal(auth, query, conn, _session_key, _resource) do
    with {:ok, principal} <- selected_session_principal(auth, query, conn),
         do: {:ok, principal, query}
  end

  defp session_collection_request(query, session_key) do
    session_collection_request(query, session_key, "transcript messages")
  end

  defp session_collection_request(query, session_key, resource) do
    allowed = ["sessionKey", "limit", "before", "after", "tail"]

    allowed =
      if resource == "tool calls",
        do: allowed ++ ["afterMessageSeqFromInclusive", "afterMessageSeqToExclusive"],
        else: allowed

    valid_keys? = Enum.all?(Map.keys(query), &(&1 in allowed))

    selected? = Map.get(query, "sessionKey", []) in [[], [session_key]]

    if valid_keys? and selected?, do: :ok, else: {:error, 400, "invalid_filter", nil}
  end

  defp tool_calls_collection(conn, session_key) do
    resource = "tool calls"
    route = "session.tool_calls.collection:#{session_key}"

    with {:ok, auth} <- selected_session_auth(conn),
         {:ok, request} <- decode_state_query(conn),
         {:ok, principal, request} <-
           session_collection_principal(auth, request, conn, session_key, resource),
         :ok <- session_collection_request(request, session_key, resource),
         {:ok, after_from} <-
           state_nonnegative_integer_filter(request, "afterMessageSeqFromInclusive"),
         {:ok, after_to} <-
           state_nonnegative_integer_filter(request, "afterMessageSeqToExclusive"),
         filters <- %{
           "afterMessageSeqFromInclusive" => cursor_filter_value(after_from),
           "afterMessageSeqToExclusive" => cursor_filter_value(after_to)
         },
         {:ok, limit, boundary} <-
           state_page_request(
             request,
             route,
             resource,
             filters,
             principal,
             &session_collection_tuple?(resource, &1),
             @state_default_limit,
             :latest,
             :earliest,
             :latest
           ),
         session when not is_nil(session) <-
           StateResources.query_session(db(conn), %{key: session_key, principal: principal}),
         page_result <-
           StateResources.query_tool_calls_for_session_page(
             db(conn),
             session_key,
             boundary,
             limit,
             after_from,
             after_to
           ),
         page <-
           state_page_metadata(
             page_result.rows,
             page_result.flags,
             &session_collection_tuple(resource, &1),
             route,
             resource,
             filters,
             principal,
             :asc
           ),
         items <- Enum.map(page_result.rows, &StateResources.tool_call/1),
         item_bytes <-
           Enum.map(items, &StateResources.encode_item(resource, &1, state_catalog(conn))) do
      body =
        "{" <>
          ~s("schemaVersion":1,"resource":"tool calls","items":[) <>
          Enum.join(item_bytes, ",") <>
          "],\"page\":" <> JSON.encode!(page) <> "}"

      state_send(conn, 200, body)
    else
      nil -> state_error(conn, resource, 404, "not_found", nil)
      {:error, status, code, message} -> state_error(conn, resource, status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      state_error(conn, "tool calls", 500, "projection_invalid", nil)
  end

  defp state_nonnegative_integer_filter(query, key) do
    with {:ok, value} <- one_query_value(query, key) do
      case value do
        nil ->
          {:ok, nil}

        text when is_binary(text) ->
          if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, text) do
            case Integer.parse(text) do
              {integer, ""} when integer <= 9_223_372_036_854_775_807 -> {:ok, integer}
              _ -> {:error, 400, "invalid_filter", nil}
            end
          else
            {:error, 400, "invalid_filter", nil}
          end

        _ ->
          {:error, 400, "invalid_filter", nil}
      end
    end
  end

  defp cursor_filter_value(nil), do: []
  defp cursor_filter_value(value), do: [Integer.to_string(value)]

  defp selected_session_auth(conn) do
    case bearer_token(conn) do
      nil ->
        {:error, 401, "auth_failed", nil}

      token ->
        cond do
          token == deps(conn).cli_token ->
            {:ok, :org}

          session_key = Org.active_session_key_by_cli_token(db(conn), token) ->
            Tightbeam.RequestContext.resolve_principal("session", session_key)
            {:ok, {:session, session_key}}

          true ->
            case Devices.by_token(db(conn), token) do
              %{user_id: user_id, is_admin: is_admin} ->
                Tightbeam.RequestContext.resolve_principal("user", user_id)
                {:ok, {:device, user_id, is_admin}}

              nil ->
                {:error, 401, "auth_failed", nil}
            end
        end
    end
  end

  defp selected_session_principal({:session, session_key}, query, conn) do
    if Map.has_key?(query, "asUser") do
      {:error, 400, "invalid_as_user", nil}
    else
      case Org.get(db(conn), session_key) do
        %{owner_user_id: owner_user_id} -> {:ok, session_read_principal(owner_user_id, conn)}
        nil -> {:error, 404, "not_found", nil}
      end
    end
  end

  defp selected_session_principal({:device, user_id, is_admin}, query, _conn) do
    if Map.has_key?(query, "asUser") do
      {:error, 400, "invalid_as_user", nil}
    else
      {:ok, %{kind: "user", id: user_id, is_admin: is_admin}}
    end
  end

  defp core_detail_serialize(conn, spec, row) do
    core_detail_trace(conn, {:serializer, spec.resource, spec.serializer})
    apply(StateResources, spec.serializer, [row])
  end

  defp core_detail_encode(conn, resource, item) do
    core_detail_trace(conn, {:ordered_item_encoder, resource})
    StateResources.encode_item(resource, item, state_catalog(conn))
  end

  defp core_detail_trace_principal(conn, principal) do
    Map.put(principal, :core_detail_trace, deps(conn)[:core_detail_trace])
  end

  defp core_detail_trace(conn, event) do
    case deps(conn)[:core_detail_trace] do
      nil -> :ok
      pid when is_pid(pid) -> send(pid, {:core_detail_trace, event})
      trace when is_function(trace, 1) -> trace.(event)
    end

    :ok
  end

  defp core_detail_operation(conn, resource, operation, fun) when is_function(fun, 0) do
    core_detail_trace(conn, {:operation, resource, operation})
    fun.()
  end

  defp core_detail_probe(conn, resource, stage) do
    core_detail_trace(conn, {:probe_stage, resource, stage})

    case deps(conn)[:core_detail_probe] do
      nil -> :ok
      probe when is_function(probe, 2) -> probe.(resource, stage)
    end
  end

  defp core_detail_row(conn, %{query: query, resource: resource}, key, principal)
       when resource in ["work items", "assignments"] do
    core_detail_trace(conn, {:shared_lookup, resource, query})

    call = %{
      principal: core_detail_principal(principal),
      rest_principal: principal,
      params: %{}
    }

    apply(StateResources, query, [db(conn), key, call])
  end

  defp core_detail_row(conn, %{query: query, resource: "read markers"}, scope_key, principal) do
    core_detail_trace(conn, {:shared_lookup, "read markers", query})
    apply(StateResources, query, [db(conn), %{key: scope_key, principal: principal}, %{}])
  end

  defp core_detail_row(conn, %{resource: "sessions"}, session_key, %{kind: "observer"}) do
    core_detail_trace(conn, {:shared_lookup, "sessions", :query_session})
    StateResources.query_session(db(conn), session_key)
  end

  defp core_detail_row(
         conn,
         %{resource: "transcript messages"},
         {session_key, message_id},
         %{kind: "observer"}
       ) do
    core_detail_trace(conn, {:shared_lookup, "transcript messages", :query_message})

    case StateResources.query_message(db(conn), message_id) do
      %{session_key: ^session_key} = row -> row
      _ -> nil
    end
  end

  defp core_detail_row(conn, %{query: query, resource: resource}, key, principal) do
    core_detail_trace(conn, {:shared_lookup, resource, query})
    apply(StateResources, query, [db(conn), %{key: key, principal: principal}])
  end

  defp core_detail_principal(%{kind: "user", id: id}), do: {:user, id}
  defp core_detail_principal(%{kind: "session", id: id}), do: {:session, id}

  defp core_detail_key("turns", raw_key) do
    case Integer.parse(raw_key) do
      {seq, ""} when seq > 0 and seq <= 9_223_372_036_854_775_807 ->
        if raw_key == Integer.to_string(seq), do: {:ok, seq}, else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp core_detail_key("condition facts", raw_key) when is_binary(raw_key) do
    if Regex.match?(@core_detail_fact_id, raw_key) do
      case Integer.parse(raw_key) do
        {id, ""} when id <= 9_223_372_036_854_775_807 -> {:ok, id}
        _ -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp core_detail_key("transcript messages", {session_key, message_id})
       when is_binary(session_key) and is_binary(message_id),
       do: {:ok, {session_key, message_id}}

  defp core_detail_key("tool calls", {session_key, tool_call_id})
       when is_binary(session_key) and is_binary(tool_call_id),
       do: {:ok, {session_key, tool_call_id}}

  defp core_detail_key("host environment", {host, harness, name})
       when is_binary(host) and is_binary(harness) and is_binary(name),
       do: {:ok, {host, harness, name}}

  defp core_detail_key(_resource, raw_key) when is_binary(raw_key), do: {:ok, raw_key}
  defp core_detail_key(_resource, _raw_key), do: {:error, :not_found}

  defp state_bearer_auth(conn) do
    token = bearer_token(conn)

    cond do
      is_nil(token) ->
        {:error, 401, "auth_failed", nil}

      token == deps(conn).cli_token ->
        {:ok, :org}

      session_key = Org.active_session_key_by_cli_token(db(conn), token) ->
        Tightbeam.RequestContext.resolve_principal("session", session_key)
        {:ok, {:session, Org.get(db(conn), session_key)}}

      device = Devices.by_token(db(conn), token) ->
        Tightbeam.RequestContext.resolve_principal("user", device.user_id)
        {:ok, {:device, device}}

      true ->
        {:error, 401, "auth_failed", nil}
    end
  end

  defp state_principal(:org, query, conn) do
    case Map.get(query, "asUser", []) do
      [] ->
        {:ok, org_read_principal(conn)}

      [user_id] when user_id != "" ->
        with {:ok, principal} <- resolve_cli_as_user(:org, user_id) do
          {:ok, state_principal_view(principal, conn)}
        end

      [_empty] ->
        {:error, 400, "invalid_message", nil}

      _repeated ->
        {:error, 400, "invalid_as_user", nil}
    end
  end

  defp state_principal({:session, session}, query, conn) do
    case Map.get(query, "asUser", []) do
      [] ->
        {:ok, session_read_principal(session.owner_user_id, conn)}

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
    Tightbeam.RequestContext.resolve_principal("user", user_id)

    is_admin =
      case Devices.user(db(conn), user_id) do
        %{is_admin: true} -> true
        _ -> false
      end

    %{kind: "user", id: user_id, is_admin: is_admin}
  end

  defp org_read_principal(conn) do
    case org_admin_user_id(conn) do
      nil -> %{kind: "user", id: "org", is_admin: true}
      user_id -> state_user_principal(user_id, conn)
    end
  end

  defp d1_org_read_principal(conn) do
    case org_admin_user_id(conn) do
      nil -> %{kind: "user", id: "org", is_admin: true}
      user_id -> d1_user_principal(user_id, conn)
    end
  end

  defp org_admin_user_id(conn) do
    {:ok, rows} =
      Tightbeam.DB.query(
        db(conn),
        "SELECT userId FROM users WHERE isAdmin = 1 ORDER BY createdAt, userId LIMIT 1",
        []
      )

    case rows do
      [[user_id]] -> user_id
      [] -> nil
    end
  end

  defp session_read_principal(user_id, _conn) when is_binary(user_id) and user_id != "",
    do: %{kind: "user", id: user_id, is_admin: true}

  defp session_read_principal(_user_id, _conn),
    do: %{kind: "user", id: "org", is_admin: true}

  defp state_principal_view({:user, user_id}, conn), do: state_user_principal(user_id, conn)

  defp state_principal_view({:session, session_key}, conn) do
    case Org.get(db(conn), session_key) do
      %{owner_user_id: owner_user_id} -> session_read_principal(owner_user_id, conn)
      nil -> session_read_principal(nil, conn)
    end
  end

  defp resolve_cli_as_user(:org, user_id) when is_binary(user_id) and user_id != "",
    do: {:ok, {:user, user_id}}

  defp resolve_cli_as_user({:session, %{session_key: key}}, _selector),
    do: {:ok, {:session, key}}

  defp resolve_cli_as_user(_auth, _empty), do: {:error, 400, "invalid_message", nil}

  defp decode_state_query(conn), do: decode_state_query_string(conn.query_string)

  defp observer_read_query(conn, resource)
       when resource in ["sessions", "transcript messages", "read markers"],
       do: decode_observer_state_query_string(conn.query_string)

  defp observer_read_query(conn, _resource), do: decode_state_query(conn)

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

  defp decode_observer_state_query_string(""), do: {:ok, %{}}

  defp decode_observer_state_query_string(query_string) do
    Enum.reduce_while(String.split(query_string, "&", trim: false), {:ok, %{}}, fn encoded,
                                                                                   {:ok, query} ->
      {raw_key, raw_value} =
        case String.split(encoded, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end

      case decode_state_query_part(raw_key) do
        {:ok, "asUser"} ->
          case decode_state_query_part(raw_value) do
            {:ok, value} when value != "" ->
              {:cont, {:ok, Map.put(query, "asUser", [value])}}

            _unusable_selector ->
              {:cont, {:ok, Map.delete(query, "asUser")}}
          end

        {:ok, key} ->
          case decode_state_query_part(raw_value) do
            {:ok, value} ->
              {:cont, {:ok, Map.update(query, key, [value], &[value | &1])}}

            :error ->
              {:halt, {:error, 400, "malformed_query", nil}}
          end

        :error ->
          {:halt, {:error, 400, "malformed_query", nil}}
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

  defp state_detail_envelope(resource, item_bytes) do
    "{" <>
      ~s("schemaVersion":1,"resource":#{JSON.encode!(resource)},"item":#{item_bytes}})
  end

  defp state_not_found(conn, resource), do: state_error(conn, resource, 404, "not_found", nil)

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

  defp state_catalog(conn) do
    case deps(conn)[:model_catalog] || ModelCatalog do
      catalog when is_map(catalog) -> catalog
      server -> ModelCatalog.get(server)
    end
  end

  defp d1_decision_request_page(conn, request, boundary, principal, spec) do
    result =
      Tightbeam.Escalation.page_collection(
        db(conn),
        request.filters,
        principal,
        boundary,
        request.limit
      )

    items = Enum.map(result.rows, &StateResources.decision_request/1)
    tuples = Enum.map(items, &d1_row_tuple(:decision_requests, &1))

    page =
      case tuples do
        [] ->
          %{
            oldest: nil,
            newest: nil,
            before: result.flags.has_more_before,
            after: result.flags.has_more_after
          }

        _ ->
          %{
            oldest: d1_cursor(hd(tuples), "before", request.filters, principal, spec, conn),
            newest: d1_cursor(List.last(tuples), "after", request.filters, principal, spec, conn),
            before: result.flags.has_more_before,
            after: result.flags.has_more_after
          }
      end

    {items, page}
  end

  defp d1_row_tuple(:work_items, item),
    do: [Map.fetch!(item, "createdAt"), Map.fetch!(item, "id")]

  defp d1_row_tuple(:decision_requests, item),
    do: [Map.fetch!(item, "raisedAt"), Map.fetch!(item, "id")]

  defp d1_row_tuple(:artifacts, item),
    do: [Map.fetch!(item, "createdAt"), Map.fetch!(item, "artifactId")]

  defp d1_row_tuple(:harness_processes, item),
    do: [Map.fetch!(item, "createdAt"), Map.fetch!(item, "id")]

  defp d1_row_tuple(:assignment_attests, item),
    do: [Map.fetch!(item, "ts"), Map.fetch!(item, "id")]

  defp d1_row_tuple(:execution_map, item),
    do: [Map.fetch!(item, :created_at), Map.fetch!(item, :id)]

  defp d1_row_tuple(:assignments, item),
    do: [Map.fetch!(item, "openedAt"), Map.fetch!(item, "id")]

  defp d1_row_tuple(:wakes, item),
    do: [Map.fetch!(item, "createdAt"), Map.fetch!(item, "wakeId")]

  defp d1_row_tuple(:turns, item), do: [Map.fetch!(item, "seq")]

  defp d1_row_tuple(resource, item), do: D1Read.tuple(resource, item)
  defp d1_encode(:work_items, item), do: StateResources.encode_item("work items", item, %{})

  defp d1_encode(:decision_requests, item),
    do: StateResources.encode_item("decision requests", item, %{})

  defp d1_encode(:artifacts, item), do: StateResources.encode_item("artifacts", item, %{})

  defp d1_encode(:harness_processes, item),
    do: StateResources.encode_item("harness processes", item, %{})

  defp d1_encode(:assignment_attests, item), do: StateResources.encode_item("attests", item, %{})

  defp d1_encode(:assignments, item), do: StateResources.encode_item("assignments", item, %{})
  defp d1_encode(:wakes, item), do: StateResources.encode_item("wakes", item, %{})
  defp d1_encode(:turns, item), do: StateResources.encode_item("turns", item, %{})

  defp d1_encode(resource, item), do: D1Read.encode(resource, item)

  defp d1_collection(conn, spec), do: d1_collection(conn, spec, nil)

  defp d1_collection(conn, spec, parent_id) do
    with {:ok, auth} <- d1_bearer_auth(conn),
         {:ok, query} <- d1_query(conn.query_string),
         {:ok, principal} <- d1_principal(auth, query, conn),
         {:ok, request} <- d1_d2_collection_request(query, spec),
         {:ok, request} <- d1_collection_parent_scope(request, d1_resource(spec), parent_id),
         :ok <- d1_d2_filter_validation(d1_resource(spec), request.filters),
         {:ok, boundary} <- d1_boundary(request, principal, spec, conn) do
      case d1_resource(spec) do
        resource when resource in [:artifacts, :assignment_attests] ->
          d1_d2_collection(conn, request, boundary, principal, spec, parent_id)

        resource when resource in [:assignments, :wakes, :turns] ->
          d1_core_state_collection(conn, request, boundary, principal, spec)

        :decision_requests ->
          {items, page} = d1_decision_request_page(conn, request, boundary, principal, spec)
          d1_send(conn, 200, d1_collection_envelope(spec, items, page))

        resource ->
          result =
            cond do
              spec.resource == "work items" ->
                page =
                  StateResources.query_work_item_page(
                    db(conn),
                    request.filters,
                    %{rest_principal: principal},
                    boundary,
                    request.limit
                  )

                %{
                  items: Enum.map(page.rows, &StateResources.work_item/1),
                  flags: %{
                    has_more_before: page.has_more_before,
                    has_more_after: page.has_more_after
                  }
                }

              resource == :harness_processes ->
                if D1Read.visible?(resource, principal.is_admin) do
                  page =
                    Tightbeam.HarnessProcess.rest_collection_page(
                      db(conn),
                      request.filters,
                      boundary,
                      request.limit
                    )

                  %{
                    items: Enum.map(page.rows, &StateResources.harness_process/1),
                    flags: %{
                      has_more_before: page.has_more_before,
                      has_more_after: page.has_more_after
                    }
                  }
                else
                  %{items: [], flags: %{has_more_before: false, has_more_after: false}}
                end

              D1Read.visible?(resource, principal.is_admin) ->
                D1Read.page(
                  db(conn),
                  deps(conn).base_dir,
                  resource,
                  request.filters,
                  boundary,
                  request.limit
                )

              true ->
                %{items: [], flags: %{has_more_before: false, has_more_after: false}}
            end

          {items, page} = d1_keyset_page(result, request, principal, spec, conn)
          d1_send(conn, 200, d1_collection_envelope(spec, items, page))
      end
    else
      {:error, status, code, message} -> d1_error(conn, spec.resource, status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      d1_error(conn, spec.resource, 500, "projection_invalid", nil)
  end

  defp d1_core_state_collection(conn, request, boundary, principal, spec) do
    traced_principal = core_detail_trace_principal(conn, principal)

    result =
      case d1_resource(spec) do
        :assignments ->
          page =
            StateResources.query_assignments_page(
              db(conn),
              traced_principal,
              boundary,
              request.limit
            )

          %{items: Enum.map(page.rows, &StateResources.assignment/1), flags: page.flags}

        :wakes ->
          page =
            StateResources.query_wakes_page(db(conn), traced_principal, boundary, request.limit)

          %{items: Enum.map(page.rows, &StateResources.wake/1), flags: page.flags}

        :turns ->
          page =
            StateResources.query_turns_page(db(conn), traced_principal, boundary, request.limit)

          %{items: Enum.map(page.rows, &StateResources.turn/1), flags: page.flags}
      end

    {items, page} = d1_keyset_page(result, request, principal, spec, conn)
    d1_send(conn, 200, d1_collection_envelope(spec, items, page))
  end

  defp d1_d2_collection_request(query, spec) do
    case d1_resource(spec) do
      :artifacts -> d1_artifact_collection_request(query, spec)
      _resource -> d1_collection_request(query, spec)
    end
  end

  defp d1_artifact_collection_request(query, spec) do
    states = Map.get(query, "state", [])

    with {:ok, request} <- d1_collection_request(Map.delete(query, "state"), spec),
         true <- Enum.all?(states, &(&1 in ~w(in-workspace archived released))) do
      filters =
        if states == [],
          do: request.filters,
          else: Map.put(request.filters, "state", states |> Enum.uniq() |> Enum.sort())

      {:ok, %{request | filters: filters}}
    else
      _ -> {:error, 400, "invalid_filter", nil}
    end
  end

  defp d1_collection_parent_scope(request, :assignment_attests, parent_id)
       when is_binary(parent_id) and parent_id != "" do
    {:ok, %{request | filters: Map.put(request.filters, "$parentAssignmentId", [parent_id])}}
  end

  defp d1_collection_parent_scope(request, :artifacts, nil), do: {:ok, request}

  defp d1_collection_parent_scope(_request, :assignment_attests, _parent_id),
    do: {:error, 404, "not_found", nil}

  defp d1_collection_parent_scope(request, _resource, _parent_id), do: {:ok, request}

  defp d1_d2_filter_validation(:artifacts, filters) do
    valid? = Enum.all?(Map.get(filters, "kind", []), &(&1 in ~w(spec report doc data other)))

    if valid?, do: :ok, else: {:error, 400, "invalid_filter", nil}
  end

  defp d1_d2_filter_validation(:assignment_attests, filters) do
    valid? =
      Enum.all?(Map.get(filters, "kind", []), fn kind ->
        kind in ~w(progress completion surrender cannot-proceed verdict)
      end)

    if valid?, do: :ok, else: {:error, 400, "invalid_filter", nil}
  end

  defp d1_d2_filter_validation(_resource, _filters), do: :ok

  defp d1_d2_collection(conn, request, boundary, principal, spec, parent_id) do
    filters = Map.delete(request.filters, "$parentAssignmentId")

    case d1_resource(spec) do
      :artifacts ->
        principal = core_detail_trace_principal(conn, principal)
        core_detail_trace(conn, {:shared_lookup, spec.resource, :query_artifact})

        page =
          StateResources.query_artifact(db(conn), %{
            collection: %{
              filters: filters,
              principal: principal,
              boundary: boundary,
              limit: request.limit
            }
          })

        result = %{
          items:
            Enum.map(page.rows, fn row ->
              core_detail_trace(conn, {:serializer, spec.resource, :artifact})
              StateResources.artifact(row)
            end),
          flags: %{
            has_more_before: page.has_more_before,
            has_more_after: page.has_more_after
          }
        }

        {items, page} = d1_keyset_page(result, request, principal, spec, conn)
        d1_send(conn, 200, d1_collection_envelope(spec, items, page))

      :assignment_attests ->
        principal = core_detail_trace_principal(conn, principal)
        core_detail_trace(conn, {:shared_lookup, spec.resource, :query_attest})

        case StateResources.query_attest(db(conn), %{
               collection: %{
                 parent_id: parent_id,
                 filters: filters,
                 principal: principal,
                 boundary: boundary,
                 limit: request.limit
               }
             }) do
          :not_found ->
            d1_error(conn, spec.resource, 404, "not_found", nil)

          {:ok, page} ->
            result = %{
              items:
                Enum.map(page.rows, fn row ->
                  core_detail_trace(conn, {:serializer, spec.resource, :attest})
                  StateResources.attest(row)
                end),
              flags: %{
                has_more_before: page.has_more_before,
                has_more_after: page.has_more_after
              }
            }

            {items, page} = d1_keyset_page(result, request, principal, spec, conn)
            d1_send(conn, 200, d1_collection_envelope(spec, items, page))
        end
    end
  end

  defp d2b_execution_map(conn, mode, parent_id) do
    spec = Map.fetch!(@d1_resources, :execution_map)

    with {:ok, auth} <- d1_bearer_auth(conn),
         {:ok, query} <- d1_query(conn.query_string),
         {:ok, principal} <- d1_principal(auth, query, conn),
         {:ok, request} <- d2b_execution_map_request(mode, query),
         principal <- core_detail_trace_principal(conn, principal),
         :ok <- d2b_execution_map_trace(conn, mode),
         {:ok, boundary} <- d2b_execution_map_boundary(mode, request, principal, spec, conn) do
      call = %{
        filters: request.filters,
        principal: principal,
        boundary: boundary,
        limit: request.limit,
        work_item_id: parent_id,
        assignment_ids: request.assignment_ids
      }

      result =
        case mode do
          :flat -> Tightbeam.ExecutionMap.list_execution_map(db(conn), call)
          :tree -> Tightbeam.ExecutionMap.query_execution_map_tree(db(conn), call)
          :subtree -> Tightbeam.ExecutionMap.query_execution_map_subtree(db(conn), call)
          :assignments -> Tightbeam.ExecutionMap.query_execution_map_assignments(db(conn), call)
        end

      case result do
        {:error, :not_found} ->
          d1_error(conn, spec.resource, 404, "not_found", nil)

        {:error, :ambiguous, candidate_ids} ->
          d2b_execution_map_ambiguous(conn, 400, candidate_ids)

        {:error, status, "ambiguous_id", candidate_ids} ->
          d2b_execution_map_ambiguous(conn, status, candidate_ids)

        {:error, status, code, message} ->
          d1_error(conn, spec.resource, status, code, message)

        result when mode == :flat ->
          {items, page} = d1_keyset_page(result, request, principal, spec, conn)
          d1_send(conn, 200, d2b_execution_map_envelope(:flat, result, items, page))

        result ->
          d1_send(conn, 200, d2b_execution_map_envelope(mode, result, nil, nil))
      end
    else
      {:error, status, code, message} -> d1_error(conn, spec.resource, status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      d1_error(conn, "execution map", 500, "projection_invalid", nil)
  end

  defp d2b_execution_map_trace(conn, mode) do
    core_detail_trace(conn, {:shared_lookup, "execution map", :query_execution_map})
    core_detail_trace(conn, {:operation, "execution map", mode})
    :ok
  end

  defp d2b_execution_map_request(mode, query) when mode in [:flat, :tree, :subtree] do
    spec = Map.fetch!(@d1_resources, :execution_map)
    roster_filters = spec.filters
    page_parameters = if mode == :flat, do: ~w(before after limit), else: []
    allowed = roster_filters ++ page_parameters ++ ["asUser"]

    with true <- Enum.all?(Map.keys(query), &(&1 in allowed)),
         :ok <- d2b_single_roster_filters(query, roster_filters),
         {:ok, before} <- d1_single(query, "before"),
         {:ok, after_cursor} <- d1_single(query, "after"),
         true <- is_nil(before) or is_nil(after_cursor),
         {:ok, limit_value} <- d1_single(query, "limit"),
         {:ok, limit} <- d1_limit(limit_value),
         {:ok, filters} <- d2b_execution_map_filters(query) do
      {:ok,
       %{
         before: before,
         after: after_cursor,
         limit: limit,
         filters: filters,
         assignment_ids: []
       }}
    else
      _ -> {:error, 400, "invalid_filter", nil}
    end
  end

  defp d2b_execution_map_request(:assignments, query) do
    with true <- Enum.all?(Map.keys(query), &(&1 in ["assignmentId", "asUser"])),
         [_ | _] = assignment_ids <- Map.get(query, "assignmentId", []),
         true <- Enum.all?(assignment_ids, &(&1 != "")) do
      {:ok,
       %{
         before: nil,
         after: nil,
         limit: @d1_default_limit,
         filters: %{},
         assignment_ids: Enum.reverse(assignment_ids)
       }}
    else
      _ -> {:error, 400, "invalid_filter", nil}
    end
  end

  defp d2b_single_roster_filters(query, fields) do
    if Enum.all?(fields, fn field -> length(Map.get(query, field, [])) <= 1 end),
      do: :ok,
      else: {:error, 400, "invalid_filter", nil}
  end

  defp d2b_execution_map_filters(query) do
    with {:ok, origin} <- d1_single(query, "origin"),
         true <- is_nil(origin) or origin in ~w(user session all),
         {:ok, owner_user_id} <- d1_single(query, "ownerUserId"),
         true <- is_nil(owner_user_id) or owner_user_id != "",
         {:ok, state} <- d1_single(query, "state"),
         true <- is_nil(state) or state in ~w(open iceboxed closed failed),
         {:ok, quiet_over_ms_value} <- d1_single(query, "quietOverMs"),
         {:ok, quiet_over_ms} <- d2b_nonnegative_integer(quiet_over_ms_value),
         {:ok, spec_ref_name} <- d1_single(query, "specRefName"),
         true <- is_nil(spec_ref_name) or spec_ref_name != "",
         {:ok, spec_ref_sha256} <- d1_single(query, "specRefSha256"),
         true <- is_nil(spec_ref_sha256) or is_binary(spec_ref_name),
         true <- is_nil(spec_ref_sha256) or Regex.match?(~r/^[0-9a-f]{64}$/, spec_ref_sha256),
         {:ok, session_key} <- d1_single(query, "sessionKey"),
         true <- is_nil(session_key) or session_key != "" do
      filters = %{}
      filters = if is_nil(origin), do: filters, else: Map.put(filters, "origin", origin)

      filters =
        if is_nil(owner_user_id),
          do: filters,
          else: Map.put(filters, "ownerUserId", owner_user_id)

      filters = if is_nil(state), do: filters, else: Map.put(filters, "state", state)

      filters =
        if is_nil(quiet_over_ms),
          do: filters,
          else: Map.put(filters, "quietOverMs", quiet_over_ms)

      filters =
        if is_nil(spec_ref_name),
          do: filters,
          else: Map.put(filters, "specRefName", spec_ref_name)

      filters =
        if is_nil(spec_ref_sha256),
          do: filters,
          else: Map.put(filters, "specRefSha256", spec_ref_sha256)

      filters =
        if is_nil(session_key), do: filters, else: Map.put(filters, "sessionKey", session_key)

      {:ok, filters}
    else
      _ -> {:error, 400, "invalid_filter", nil}
    end
  end

  defp d2b_nonnegative_integer(nil), do: {:ok, nil}

  defp d2b_nonnegative_integer(value) when is_binary(value) do
    if Regex.match?(~r/^(0|[1-9][0-9]*)$/, value),
      do: {:ok, String.to_integer(value)},
      else: :error
  end

  defp d2b_nonnegative_integer(_value), do: :error

  defp d2b_execution_map_boundary(:flat, request, principal, spec, conn),
    do: d1_boundary(Map.put(request, :tail, nil), principal, spec, conn)

  defp d2b_execution_map_boundary(_mode, _request, _principal, _spec, _conn), do: {:ok, :latest}

  defp d2b_execution_map_ambiguous(conn, status, candidate_ids) do
    body =
      "{\"schemaVersion\":1,\"resource\":\"execution map\",\"error\":{\"code\":\"ambiguous_id\",\"candidateIds\":" <>
        JSON.encode!(candidate_ids) <> "}}"

    d1_send(conn, status, body)
  end

  defp d2b_execution_map_envelope(mode, result, items, page) do
    prefix =
      "{\"schemaVersion\":1,\"resource\":\"execution map\",\"edgeBasis\":\"concurrent_turn\",\"coverage\":{" <>
        "\"attributionCutoff\":" <>
        JSON.encode!(result.attribution_cutoff) <>
        ",\"basis\":\"conservative_shared\"},\"dependencyVersion\":" <>
        JSON.encode!(result.dependency_version)

    case mode do
      :flat ->
        prefix <>
          ",\"items\":[" <>
          Enum.map_join(items, ",", &Tightbeam.ExecutionMap.execution_map_node/1) <>
          "],\"page\":{" <>
          "\"oldestCursor\":" <>
          JSON.encode!(page.oldest) <>
          ",\"newestCursor\":" <>
          JSON.encode!(page.newest) <>
          ",\"hasMoreBefore\":" <>
          JSON.encode!(page.before) <>
          ",\"hasMoreAfter\":" <> JSON.encode!(page.after) <> "}}"

      :tree ->
        prefix <>
          ",\"roots\":[" <>
          Enum.map_join(result.roots, ",", &Tightbeam.ExecutionMap.execution_map_node/1) <>
          "]}"

      :subtree ->
        prefix <>
          ",\"roots\":[" <>
          Enum.map_join(result.roots, ",", &Tightbeam.ExecutionMap.execution_map_node/1) <>
          "]}"

      :assignments ->
        prefix <>
          ",\"items\":[" <>
          Enum.map_join(result.items, ",", &Tightbeam.ExecutionMap.execution_map_node/1) <>
          "],\"noItem\":" <> JSON.encode!(result.no_item) <> "}"
    end
  end

  defp d2_attests_collection(conn) do
    # The nested route binds its parent in this resource's cursor filter fingerprint.
    spec = Map.fetch!(@d1_resources, :assignment_attests)

    with {:ok, auth} <- d1_bearer_auth(conn),
         {:ok, query} <- d1_query(conn.query_string),
         {:ok, principal} <- d1_principal(auth, query, conn),
         {:ok, request} <- d1_collection_request(query, spec),
         :ok <- d1_d2_filter_validation(:assignment_attests, request.filters),
         {:ok, boundary} <- d1_boundary(request, principal, spec, conn) do
      principal = core_detail_trace_principal(conn, principal)
      core_detail_trace(conn, {:shared_lookup, spec.resource, :query_attests})

      page =
        StateResources.query_attests(db(conn), %{
          collection: %{
            filters: request.filters,
            principal: principal,
            boundary: boundary,
            limit: request.limit
          }
        })

      result = %{
        items:
          Enum.map(page.rows, fn row ->
            core_detail_trace(conn, {:serializer, spec.resource, :attest})
            StateResources.attest(row)
          end),
        flags: %{
          has_more_before: page.has_more_before,
          has_more_after: page.has_more_after
        }
      }

      {items, page} = d1_keyset_page(result, request, principal, spec, conn)
      d1_send(conn, 200, d1_collection_envelope(spec, items, page))
    else
      {:error, status, code, message} -> d1_error(conn, "attests", status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      d1_error(conn, "attests", 500, "projection_invalid", nil)
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

  defp d2c_work_item_trace(conn, id) do
    with {:ok, auth} <- d1_bearer_auth(conn),
         {:ok, query} <- d1_query(conn.query_string),
         {:ok, principal} <- d1_principal(auth, query, conn),
         :ok <- d1_detail_request(query) do
      case WorkItems.query_work_item_trace(db(conn), %{id: id, principal: principal}) do
        {:error, status, code, message} ->
          d1_error(conn, "work-item trace", status, code, message)

        trace ->
          d1_send(conn, 200, d2c_work_item_trace_envelope(trace))
      end
    else
      {:error, status, code, message} ->
        d1_error(conn, "work-item trace", status, code, message)
    end
  rescue
    _error in [ArgumentError, KeyError, MatchError] ->
      d1_error(conn, "work-item trace", 500, "projection_invalid", nil)
  end

  defp d1_bearer_auth(conn) do
    case bearer_token(conn) do
      token when is_binary(token) ->
        cond do
          token == deps(conn).cli_token ->
            {:ok, :org}

          session_key = Org.active_session_key_by_cli_token(db(conn), token) ->
            Tightbeam.RequestContext.resolve_principal("session", session_key)
            {:ok, {:session, Org.get(db(conn), session_key)}}

          device = Devices.by_token(db(conn), token) ->
            Tightbeam.RequestContext.resolve_principal("user", device.user_id)
            {:ok, {:device, device}}

          true ->
            {:error, 401, "auth_failed", nil}
        end

      _ ->
        {:error, 401, "auth_failed", nil}
    end
  end

  defp d1_principal(:org, %{"asUser" => [user_id]}, conn) when user_id != "" do
    {:ok, d1_user_principal(user_id, conn)}
  end

  defp d1_principal(:org, %{"asUser" => [_]}, _conn), do: {:error, 400, "invalid_message", nil}

  defp d1_principal(:org, query, conn) when not is_map_key(query, "asUser"),
    do: {:ok, d1_org_read_principal(conn)}

  defp d1_principal(:org, _query, _conn), do: {:error, 400, "invalid_as_user", nil}

  defp d1_principal({:session, session}, query, conn) do
    case Map.get(query, "asUser", []) do
      [] ->
        {:ok, session_read_principal(session.owner_user_id, conn)}

      [_user_id] ->
        {:ok, session_read_principal(session.owner_user_id, conn)}

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
    Tightbeam.RequestContext.resolve_principal("user", user_id)
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
    allowed = spec.filters ++ ~w(asUser before after limit tail)

    with true <- Enum.all?(Map.keys(query), &(&1 in allowed)),
         {:ok, before} <- d1_single(query, "before"),
         {:ok, after_cursor} <- d1_single(query, "after"),
         true <- is_nil(before) or is_nil(after_cursor),
         {:ok, tail_value} <- d1_single(query, "tail"),
         {:ok, tail} <- d1_tail_value(tail_value),
         true <- is_nil(tail) or (is_nil(before) and is_nil(after_cursor)),
         {:ok, limit_value} <- d1_single(query, "limit"),
         {:ok, limit} <- d1_limit(limit_value),
         {:ok, filters} <- d1_filters(query, spec.filters, spec.resource) do
      {:ok, %{before: before, after: after_cursor, tail: tail, limit: limit, filters: filters}}
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

  defp d1_tail_value(nil), do: {:ok, nil}
  defp d1_tail_value("true"), do: {:ok, true}
  defp d1_tail_value("false"), do: {:ok, false}
  defp d1_tail_value(_value), do: :error

  defp d1_limit(nil), do: {:ok, @d1_default_limit}

  defp d1_limit(value) when is_binary(value) do
    if value =~ ~r/^[1-9][0-9]*$/ do
      {:ok, min(String.to_integer(value), @d1_max_limit)}
    else
      :error
    end
  end

  defp d1_limit(_value), do: :error

  defp d1_filters(query, fields, resource) do
    fields
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, filters} ->
      values = Map.get(query, field, [])

      if Enum.all?(values, &d1_filter_value?(resource, field, &1)) do
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

  defp d1_filter_value?("work items", "state", value),
    do: value in ~w(open iceboxed closed failed)

  defp d1_filter_value?("harness processes", "state", value),
    do: value in ~w(launching running park_requested closed_gracefully killed kill_failed exited)

  defp d1_filter_value?("decision requests", "kind", value),
    do: value in ~w(statute effort agent)

  defp d1_filter_value?("decision requests", "status", value),
    do: value in ~w(open ruled consumed withdrawn superseded answered returned)

  defp d1_filter_value?("work items", "isBug", value), do: value in ~w(true false)
  defp d1_filter_value?("work items", _field, value), do: is_binary(value) and value != ""
  defp d1_filter_value?(_resource, field, value), do: d1_filter_value?(field, value)

  defp d1_filter_value?("state", value), do: value in ~w(ready relearn_conflicted)
  defp d1_filter_value?("status", value), do: value in ~w(available installed)
  defp d1_filter_value?(_field, value), do: is_binary(value) and value != ""

  defp d1_boundary(%{before: nil, after: nil, tail: true}, _principal, _spec, _conn),
    do: {:ok, :latest}

  defp d1_boundary(%{before: nil, after: nil, tail: false}, _principal, _spec, _conn),
    do: {:ok, :earliest}

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
             payload["filters"] == d1_cursor_filter_fingerprint(spec, request.filters),
         true <- payload["principalKind"] in ["user", "session"],
         true <- is_binary(payload["principalId"]) and payload["principalId"] != "",
         true <- d1_tuple?(payload["tuple"], d1_resource(spec)) do
      if payload["principalKind"] == principal.kind and payload["principalId"] == principal.id do
        {:ok, {String.to_atom(direction), payload["tuple"]}}
      else
        {:error, 404, "not_found", nil}
      end
    else
      _ -> {:error, 400, "invalid_cursor", nil}
    end
  end

  defp d1_tuple?([created_at, id], :work_items),
    do: is_integer(created_at) and is_binary(id) and id != ""

  defp d1_tuple?(_tuple, :work_items), do: false

  defp d1_tuple?([raised_at, id], :decision_requests),
    do: is_integer(raised_at) and is_binary(id) and id != ""

  defp d1_tuple?(_tuple, :decision_requests), do: false

  defp d1_tuple?([created_at, artifact_id], :artifacts),
    do: is_integer(created_at) and is_binary(artifact_id) and artifact_id != ""

  defp d1_tuple?(_tuple, :artifacts), do: false

  defp d1_tuple?([created_at, id], :harness_processes),
    do: is_integer(created_at) and is_binary(id) and id != ""

  defp d1_tuple?(_tuple, :harness_processes), do: false

  defp d1_tuple?([ts, id], :assignment_attests),
    do: is_integer(ts) and is_binary(id) and id != ""

  defp d1_tuple?(_tuple, :assignment_attests), do: false

  defp d1_tuple?([created_at, id], :execution_map),
    do: is_integer(created_at) and is_binary(id) and id != ""

  defp d1_tuple?(_tuple, :execution_map), do: false

  defp d1_tuple?([opened_at, id], :assignments),
    do: is_integer(opened_at) and is_binary(id) and id != ""

  defp d1_tuple?(_tuple, :assignments), do: false

  defp d1_tuple?([created_at, wake_id], :wakes),
    do: is_integer(created_at) and is_binary(wake_id) and wake_id != ""

  defp d1_tuple?(_tuple, :wakes), do: false

  defp d1_tuple?([seq], :turns), do: is_integer(seq) and seq > 0
  defp d1_tuple?(_tuple, :turns), do: false

  defp d1_tuple?(tuple, resource),
    do:
      is_list(tuple) and length(tuple) == length(D1Read.spec(resource).order) and
        Enum.all?(tuple, &(is_binary(&1) and &1 != ""))

  defp d1_keyset_page(result, request, principal, spec, conn) do
    selected = result.items
    flags = result.flags

    page =
      case selected do
        [] ->
          %{
            oldest: nil,
            newest: nil,
            before: flags.has_more_before,
            after: flags.has_more_after
          }

        _ ->
          oldest = d1_row_tuple(d1_resource(spec), hd(selected))
          newest = d1_row_tuple(d1_resource(spec), List.last(selected))

          %{
            oldest: d1_cursor(oldest, "before", request.filters, principal, spec, conn),
            newest: d1_cursor(newest, "after", request.filters, principal, spec, conn),
            before: flags.has_more_before,
            after: flags.has_more_after
          }
      end

    {selected, page}
  end

  defp d1_cursor(tuple, direction, filters, principal, spec, _conn) do
    payload =
      JSON.encode!(%{
        "version" => @d1_cursor_version,
        "route" => spec.route,
        "resource" => spec.resource,
        "direction" => direction,
        "filters" => d1_cursor_filter_fingerprint(spec, filters),
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

  defp d1_cursor_filter_fingerprint(spec, filters) do
    case d1_resource(spec) do
      :execution_map ->
        ~w(origin ownerUserId state quietOverMs specRefName specRefSha256 sessionKey)
        |> Enum.map(&Map.get(filters, &1))
        |> JSON.encode!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      _resource ->
        d1_filter_fingerprint(filters)
    end
  end

  defp d1_resource(spec),
    do:
      Enum.find_value(@d1_resources, fn {resource, candidate} ->
        if candidate == spec, do: resource
      end)

  defp d1_collection_envelope(spec, items, page) do
    encoded_items = Enum.map_join(items, ",", &d1_encode(d1_resource(spec), &1))

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

  defp d2c_work_item_trace_envelope(trace) do
    encoded_assignments =
      Enum.map_join(trace.assignments, ",", &StateResources.encode_item("assignments", &1))

    attribution = trace.attribution

    "{\"schemaVersion\":1,\"resource\":\"work-item trace\",\"item\":{" <>
      "\"workItem\":" <>
      StateResources.encode_item("work items", trace.work_item) <>
      ",\"assignments\":[" <>
      encoded_assignments <>
      "],\"causalChildren\":" <>
      JSON.encode!(trace.causal_children) <>
      ",\"attribution\":{" <>
      "\"provenanceStatus\":" <>
      JSON.encode!(attribution.provenance_status) <>
      ",\"reasonKind\":" <>
      JSON.encode!(attribution.reason_kind) <>
      ",\"primaryWorkKind\":" <>
      JSON.encode!(attribution.primary_work_kind) <>
      ",\"primaryWorkId\":" <>
      JSON.encode!(attribution.primary_work_id) <>
      "},\"dependencyVersion\":" <>
      JSON.encode!(trace.dependency_version) <> "}}"
  end

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

  defp bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> token
      _ -> nil
    end
  end

  defp session_status(conn),
    do: deps(conn)[:session_status] || (&Tightbeam.Gateway.session_status/1)

  defp cli_auth(conn) do
    with {:ok, auth} <- cli_token_auth(conn),
         :ok <- cli_version_compatible(conn, auth) do
      {:ok, auth}
    end
  end

  defp cli_version_compatible(conn, auth) do
    version =
      case Plug.Conn.get_req_header(conn, "x-tightbeam-cli-version") do
        [version] -> version
        _ -> nil
      end

    case CliCompatibility.check(version) do
      :ok ->
        observe_cli_compatibility(conn, auth, version, :compatible)

      {:error, message} ->
        case observe_cli_compatibility(conn, auth, version, :incompatible) do
          :ok -> {:error, 426, "incompatible_cli", message}
          error -> error
        end
    end
  end

  defp observe_cli_compatibility(_conn, :org, _offered, _state), do: :ok

  defp observe_cli_compatibility(conn, {:session, session}, offered, state) do
    required = CliCompatibility.required_version()
    offered = if is_binary(offered), do: offered, else: "missing"

    case ConditionFacts.observe_cli_compatibility(
           db(conn),
           session.session_key,
           state,
           offered,
           required,
           conn.request_path
         ) do
      {:error, reason} ->
        {:error, 503, "mismatch_state_unavailable", "CLI mismatch state could not be recorded",
         ErrorDiagnostic.from_reason(reason,
           operation: "observe_cli_compatibility",
           origin: "gateway",
           cli_state: state
         )}

      _ ->
        :ok
    end
  end

  defp cli_token_auth(conn) do
    token =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end

    cond do
      token == deps(conn).cli_token ->
        {:ok, :org}

      session_key = token && Org.active_session_key_by_cli_token(db(conn), token) ->
        Tightbeam.RequestContext.resolve_principal("session", session_key)
        {:ok, {:session, Org.get(db(conn), session_key)}}

      true ->
        {:error, 401, "auth_failed", nil}
    end
  end

  defp session_cli_auth(conn) do
    case cli_auth(conn) do
      {:ok, {:session, _session} = session} -> {:ok, session}
      {:ok, :org} -> {:error, 403, "session_required", "a session token names the caller's turn"}
      error -> error
    end
  end

  defp terminal_session_auth(conn) do
    case cli_token_auth(conn) do
      {:ok, {:session, _session} = session} -> {:ok, session}
      {:ok, :org} -> {:error, 403, "session_required", "a session token is required"}
      error -> error
    end
  end

  defp terminal_version_supported(conn) do
    case Plug.Conn.get_req_header(conn, "x-tightbeam-terminal-version") do
      ["1"] ->
        :ok

      _ ->
        {:error, 400, "unsupported_terminal_protocol", "terminal protocol version 1 is required"}
    end
  end

  defp device_auth(conn) do
    token =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end

    case token && Devices.by_token(db(conn), token) do
      nil ->
        {:error, 401, "auth_failed", nil}

      device ->
        Tightbeam.RequestContext.resolve_principal("user", device.user_id)
        {:ok, device}
    end
  end

  defp allowed_agent_verb(verb) do
    if verb in @agent_verbs,
      do: :ok,
      else: {:error, 400, "invalid_message", "verb not allowed: #{verb}"}
  end

  defp agent_identity(%{"asProcess" => "tightbeam"}, _auth, _conn) do
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
    session_principal = {:session, session.session_key}

    cond do
      is_binary(body["as"]) and body["as"] != "" ->
        role = body["as"]

        case Roles.resolve(db(conn), role) do
          {:ok, _session_key, false} ->
            {:ok, "agent:#{role}", session_principal}

          _ ->
            {:error, 400, "invalid_message", "unknown or unbound role: #{role}"}
        end

      is_binary(body["asUser"]) ->
        {:ok, "agent:#{session.session_key}", session_principal}

      is_binary(body["asProcess"]) and body["asProcess"] != "" ->
        {:ok, "process:#{body["asProcess"]}", session_principal}

      true ->
        {:ok, "agent:#{session.session_key}", session_principal}
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
        {:ok, "process:#{body["asProcess"]}"}

      true ->
        {:error, 400, "invalid_message",
         "as, asUser, or asProcess required on an organization credential"}
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
  @non_target_verbs ~w(harklight-send harklight-revise harklight-retract harklight-settle settle-turn answer return transcript execution-map execution-map-select breathing toplines topline topline-create topline-update topline-close topline-reopen topline-link-work topline-unlink-work topline-concern-create topline-concern-link-work topline-concern-unlink-work topline-work-leave-unlinked topline-placement-list)

  @non_target_verbs @non_target_verbs ++
                      [
                        "artifact-content-fetch",
                        "assignment-commitref-correct",
                        "harness-health-observe-other",
                        "harness-health-resolve-other",
                        "harness-health-close-promotion"
                      ]

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
          do:
            {:ok, Org.personal_session_key(body["userId"]),
             %{role: nil, fallback: false, user_id: body["userId"]}},
          else: {:error, 404, "not_found", "unknown userId: #{body["userId"]}"}

      given == ["role"] ->
        case Roles.resolve(db(conn), body["role"]) do
          # `Roles.resolve/2` answers "who stands in for this role", falling back to
          # the owner's personal session when the role is unbound or its binding is
          # not active. That is a fair answer for a wake and a PHANTOM for an
          # assignment: assign/dispatch BIND an obligation, and the owner's session
          # is not the requested role's holder — commonly not even its provider — so
          # the card lands on a session that cannot do the work while the requester
          # believes it dispatched, including when a role's bound session was retired.
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

  defp artifact_caller_session(verb, nil, {:session, session_key})
       when verb in ~w(harklight-send harklight-revise harklight-retract harklight-settle),
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

  defp visible_cancel_target("cancel", session_key, {:user, user_id}, conn)
       when is_binary(session_key) do
    case Devices.user(db(conn), user_id) do
      %{is_admin: is_admin} ->
        case visible_session(
               session_key,
               %{user_id: user_id, is_admin: is_admin},
               conn
             ) do
          {:ok, _session} -> :ok
          error -> error
        end

      nil ->
        {:error, 404, "not_found", nil}
    end
  end

  defp visible_cancel_target(_verb, _session_key, _principal, _conn), do: :ok

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

  defp control_call(%{"action" => "clear_stranded_run"} = body),
    do:
      {:ok, "clear-stranded",
       %{
         turn_seq: body["turnSeq"],
         reason: body["reason"],
         idempotency_key: body["idempotencyKey"]
       }}

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
        "set_thinking" => :thinkingLevel,
        "set_reasoning" => :reasoningLevel,
        "set_fast_mode" => :fastMode,
        "set_mode" => :mode,
        "set_verbosity" => :verbosity
      }[action]

    {:ok, "tune", Map.put(%{setting: action}, key, body[Atom.to_string(key)])}
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

      # A crashed control handler is a server failure, not a refusal: the status
      # says so (500) while the body keeps the control shape clients already read.
      {:error, %{code: "server_error", message: message} = error} ->
        %{
          "ok" => false,
          "sessionKey" => session_key,
          "action" => action,
          "code" => "control_failed",
          "message" => message
        }
        |> put_optional("diagnostic", ErrorDiagnostic.for_error(error))
        |> then(&json(conn, 500, &1))

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
        # A failed control's evidence, or a succeeded one's unconfirmed side leg
        # (cancel's harness notification). A successful tune carries none.
        |> put_optional("diagnostic", result[:diagnostic])
        |> put_optional("turnSeq", result[:turn_seq])
        |> put_optional("replayed", result[:replayed])
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

  # A body that could not be read and a body that is not a JSON object are
  # different failures: the first names the read (too large, timed out, closed),
  # the second where the parser stopped. Both keep the invalid_message code.
  defp with_json(conn, fun) do
    case read_json(conn) do
      {:ok, body, conn} ->
        fun.(body, conn)

      {:error, conn, status, code, message, diagnostic} ->
        error(conn, status, code, message, diagnostic)
    end
  end

  defp read_json(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, "", conn} ->
        {:ok, %{}, conn}

      {:ok, body, conn} ->
        case JSON.decode(body) do
          {:ok, decoded} when is_map(decoded) ->
            {:ok, decoded, conn}

          {:ok, other} ->
            {:error, conn, 400, "invalid_message", nil,
             ErrorDiagnostic.json_decode({:not_object, other}, origin: "http", phase: "decode")}

          {:error, reason} ->
            {:error, conn, 400, "invalid_message", nil,
             ErrorDiagnostic.json_decode(reason, origin: "http", phase: "decode")}
        end

      {:more, _partial, conn} ->
        {:error, conn, 413, "invalid_message", "request body too large",
         ErrorDiagnostic.new("decode", origin: "http", phase: "read", error: "body_too_large")}

      {:error, reason} ->
        {:error, conn, 400, "invalid_message", "request body could not be read",
         ErrorDiagnostic.from_reason(reason, origin: "http", phase: "read")}
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
  # because the substrate is their only legitimate author. An assignment on an
  # immediate conversational wake is a validated message reference; scheduled wakes
  # and typed obligation waits may carry an explicit assignment link. That reference
  # is not authority.
  # `replacement_assignment_id` is derived from `assignmentId` only for the
  # `replaceQueued` operation below.
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
    "wake" => ~w(request_ref replacement_assignment_id)a,
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

  @param_keys %{
    "harklight-send" =>
      ~w(harklight_session sender_id title body choices files vendor_session_id supersedes)a,
    "harklight-revise" => ~w(message_id base_revision title body choices clear_choices)a,
    "harklight-retract" => ~w(message_id)a,
    "harklight-settle" => ~w(message_id)a,
    "work-item-list" =>
      ~w(state status owner_user_id created_by_session created_by_user is_bug spec_ref_name holder_key limit after)a,
    "topline-placement-list" => ~w(state)a,
    "topline-work-leave-unlinked" => ~w(idempotency_key reason work_item_id)a,
    "topline-concern-unlink-work" => ~w(concern_id idempotency_key reason work_item_id)a,
    "topline-concern-link-work" => ~w(concern_id idempotency_key reason work_item_id)a,
    "topline-concern-create" => ~w(idempotency_key title topline_id)a,
    "topline-unlink-work" => ~w(idempotency_key membership_id reason)a,
    "topline-link-work" => ~w(idempotency_key reason topline_id work_item_id)a,
    "topline-reopen" => ~w(idempotency_key reason topline_id)a,
    "topline-close" => ~w(idempotency_key reason topline_id)a,
    "topline-update" => ~w(idempotency_key reason title topline_id)a,
    "topline-create" => ~w(idempotency_key title owner_user_id)a,
    "withdraw" => ~w(request request_id reason)a,
    "revoke-waiver" => ~w(waiver waiver_id reason)a,
    "waive" =>
      ~w(request request_id session session_key statute statute_name reason scope expires_at idempotency_key)a,
    "kungfu-scaffold" => ~w(name purpose idempotency_key)a,
    "promote-user" => ~w(user_id is_admin)a,
    "revoke-device" => ~w(device_id)a,
    "deny-device" => ~w(device_id)a,
    "approve-device" => ~w(device_id user_id)a,
    "assignment-get" => ~w(assignment_id fact_id)a,
    "add-user" => ~w(is_admin user_id)a,
    "answer" => ~w(answer idempotency_key reason request request_id)a,
    "artifact-content-fetch" => ~w(artifact_id)a,
    "artifact-get" => ~w(artifact_id)a,
    "artifact-record" =>
      ~w(content_base64 content_sha256 description kind origin_path produced_by_assignment_id title work_item_id)a,
    "artifacts" => ~w(session_key work_item_id kind)a,
    "memento-set" => ~w(record name values clear)a,
    "mementos" => ~w(record history name limit cursor)a,
    "ask" =>
      ~w(assignment_id context idempotency_key params question reason role session_key target user_id verb)a,
    "assign" =>
      ~w(effect_kind files holder_key idempotency_key mementos prompt reviews reviews_assignment_id role session_key subject succeeds_assignment_id work_item_id owner_user_id)a,
    "assignment-commitref-correct" =>
      ~w(assignment_id commit_refs evidence_artifact_id idempotency_key reason)a,
    "assignments" => ~w(role session_key state)a,
    "attend" => ~w(high)a,
    "attest" =>
      ~w(artifact_id assignment_id commit_refs content_sha256 kind mementos note release_fact_kind release_fact_principal_ref release_fact_scope verdict_kind wait_id)a,
    "attests" => ~w(assignment_id)a,
    "breathing" => ~w(target_id target_kind)a,
    "cancel" => ~w(assignment_id reason)a,
    "condition" => ~w(idempotency_key kind payload scope)a,
    "config" => ~w(action key setting value)a,
    "critical" => ~w(for_ms reason)a,
    "decision-request" => ~w(request request_id)a,
    "decision-requests" => ~w(status)a,
    "dispatch" =>
      ~w(brief effect_kind holder_key idempotency_key mementos prompt session_key subject succeeds_assignment_id work_item_id workdir_root owner_user_id)a,
    "effort-rule" => ~w(action request request_id)a,
    "execution-map" => ~w(tree origin owner state spec spec_sha session quiet_over)a,
    "execution-map-select" =>
      ~w(assignments under origin owner state spec spec_sha session quiet_over)a,
    "facts-read" => ~w(after kind limit scope)a,
    "fact-demand" => ~w(kind_prefixes)a,
    "fact-producer-claim" => ~w(producer kinds live_for_ms)a,
    "fact-producers" => ~w()a,
    "harness-health-close-promotion" =>
      ~w(candidate_commit idempotency_key named_class promotion_id review_artifact_id review_assignment_id review_attest_id spec_artifact_id spec_ref spec_sha256)a,
    "harness-health-evidence-other" => ~w(incident_id)a,
    "harness-health-observe-other" =>
      ~w(accepted_at session_key correlation_id description evidence_mode exact_observed_error exact_probe harness host idempotency_key not_known_class_reason observed_at observed_state output_digest recovery_condition redaction_confirmed source_session_key valid_until world_status)a,
    "harness-health-resolve-other" =>
      ~w(accepted_at cause correlation_id exact_probe harness host idempotency_key incident_id observed_at observed_state output_digest recovery_condition_digest recovery_satisfied redaction_confirmed session_key world_status)a,
    "harness-health-review-other" => ~w(cause idempotency_key incident_id named_class outcome)a,
    "harness-processes" => ~w()a,
    "harness-process-settle" => ~w(launch_id adapter_key)a,
    "host-env-list" => ~w(harness host sentinel)a,
    "host-env-set" => ~w(harness host key name sentinel value)a,
    "host-env-unset" => ~w(harness host key name sentinel)a,
    "host-toolchain-set" => ~w(dirs host)a,
    "identity-apply" => ~w(all session_key)a,
    "identity-edit" =>
      ~w(archetype content expected_revision idempotency_key manifest name path remove skill)a,
    "identity-relearn" => ~w(action idempotency_key)a,
    "identity-repoint" => ~w(archetype name path session_key)a,
    "identity-status" => ~w(archetype)a,
    "inspect" => ~w(batch_id)a,
    "kungfu-list" => ~w()a,
    "kungfu-setup" => ~w(name)a,
    "learn" => ~w(idempotency_key name)a,
    "onboard" =>
      ~w(provider phase kind machine lease_id reason source code callback_url owner_user_id)a,
    "operator-ask" =>
      ~w(assignment assignment_id choices context deadline idempotency_key note options owner_user_id question supersedes work_item_id)a,
    "operator-rule" => ~w(decision idempotency_key rationale reason request request_id response)a,
    "operator-withdraw" => ~w(idempotency_key reason request request_id)a,
    "register-host" => ~w(adapter_bin_dir base_dir cli_bin name ssh)a,
    "reopen-assignment" => ~w(assignment_id reason)a,
    "repair-assignment" =>
      ~w(action assignment_id context effort idempotency_key model outcome turn_seq)a,
    "retire" => ~w(idempotency_key session_key)a,
    "return" => ~w(idempotency_key reason request request_id)a,
    "revoke-assignment" => ~w(assignment_id reason)a,
    "role-bind" => ~w(name session_key)a,
    "role-create" => ~w(name bind description session_key owner_user_id)a,
    "role-list" => ~w()a,
    "role-rm" => ~w(name)a,
    "rule" => ~w(request request_id decision rationale reason scope expires_at idempotency_key)a,
    "sentinel-disable" => ~w(name)a,
    "sentinel-enable" => ~w(name)a,
    "sentinel-list" => ~w()a,
    "session-po-set" => ~w(idempotency_key po_role po_session_key session_key)a,
    "session-reparent" => ~w(assignment_id idempotency_key parent_session_key session_key)a,
    "settle-turn" => ~w(idempotency_key outcome reason session_key turn_seq)a,
    "spawn" =>
      ~w(archetype context display_name effort handle harness host idempotency_key model overrides work_item_id owner_user_id)a,
    "subtree-guidance-set" => ~w(name archetypes text)a,
    "subtree-guidance-show" => ~w(session_key)a,
    "subtree-guidance-withdraw" => ~w(name)a,
    "topline" => ~w(history origin owner quiet_over session spec spec_sha state topline_id)a,
    "toplines" => ~w(origin owner quiet_over session spec spec_sha state)a,
    "transcript" => ~w(after before limit name session_key)a,
    "tune" =>
      ~w(adopted context display_name effort fast_mode harness host idempotency_key mode model reasoning_level session_key setting skill guidance thinking_level verbosity)a,
    "unlearn" => ~w(idempotency_key name)a,
    "wake" =>
      ~w(prompt after_ms after_turn assignment_id at cancel_wake_id class cron condition_kind condition_scope idempotency_key predicate replace_queued reresolve reresolve_rung reresolve_seed nudge)a,
    "work-item-close" => ~w(work_item_id)a,
    "work-item-create" =>
      ~w(title is_bug priority spec_ref_name spec_ref_sha256 idempotency_key body mementos owner_user_id)a,
    "work-item-fail" => ~w(reason work_item_id)a,
    "work-item-get" => ~w(work_item_id)a,
    "work-item-handoff" => ~w(work_item_id title delivery_owner_session_key brief owner_user_id)a,
    "work-item-icebox" => ~w(work_item_id)a,
    "work-item-reopen" => ~w(work_item_id)a,
    "work-item-trace" => ~w(work_item_id)a,
    "work-item-update" =>
      ~w(work_item_id title is_bug priority spec_ref_name spec_ref_sha256 delivery_owner_session_key body clear_body)a
  }

  @param_keys Map.new(@param_keys, fn {verb, keys} ->
                {verb,
                 Map.new(
                   keys ++ Map.get(@substrate_only_params, verb, []),
                   &{Atom.to_string(&1), &1}
                 )}
              end)

  @doc false
  # Exposed so the Law-0 boundary strip is provable at its own seam.
  def atomize_params_for_test(verb, params), do: atomize_params(verb, params)

  defp atomize_params(verb, params) when is_map(params) do
    aliases = Map.get(@param_aliases, verb, %{})

    keys = Map.get(@param_keys, verb, %{})

    params
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case keys[Macro.underscore(key)] do
        nil -> Map.put(acc, key, value)
        atom -> Map.put(acc, Map.get(aliases, atom, atom), value)
      end
    end)
    |> Map.drop(Map.get(@substrate_only_params, verb, []))
    |> strip_notification_assignment(verb)
  end

  defp strip_notification_assignment(params, "wake") do
    cond do
      params[:after_turn] == true or is_map(params[:predicate]) ->
        params

      params[:replace_queued] == true and is_binary(params[:assignment_id]) ->
        params
        |> Map.put(:replacement_assignment_id, params.assignment_id)
        |> Map.delete(:assignment_id)

      is_number(params[:after_ms]) or is_number(params[:at]) or
          is_binary(params[:condition_kind]) ->
        params

      true ->
        if Enum.any?(
             [
               :after_ms,
               :after_turn,
               :at,
               :condition_kind,
               :condition_scope,
               :cron,
               :predicate,
               :replace_queued
             ],
             &Map.has_key?(params, &1)
           ) do
          Map.delete(params, :assignment_id)
        else
          params
        end
    end
  end

  defp strip_notification_assignment(params, _verb), do: params

  defp json(conn, status, body) do
    data = JSON.encode!(wire_value(body))

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, data)
  end

  defp error(conn, status, code, message \\ nil, diagnostic \\ nil) do
    detail =
      %{"code" => code}
      |> put_optional("message", message)
      |> put_optional("diagnostic", diagnostic)

    json(conn, status, %{"error" => detail})
  end

  defp dispatch_error(conn, %{verb: verb}, status, result)
       when verb in ~w(harklight-send harklight-revise harklight-retract harklight-settle) do
    json(conn, status, %{"error" => wire_value(result)})
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
    error(conn, status, result[:code], result[:message], ErrorDiagnostic.for_error(result))
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
