defmodule Tightbeam.Wire.RouterTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model
  import Plug.Test
  import Plug.Conn

  alias Tightbeam.{
    Assignments,
    Credentials,
    DB,
    Devices,
    Gateway,
    Org,
    Placement,
    Roles,
    Wakes,
    WorkItems,
    WorkState
  }

  alias Tightbeam.Wire.Router

  setup do
    db = :"router_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-router-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base_dir) end)

    {:paired, device} =
      claim_org(db, %{device_id: "d1", claimed_name: "Flynn", platform: nil, model: nil})

    parent = self()

    handlers = %{
      "wake" => fn call ->
        send(parent, {:call, call})
        %{wake_id: "w_test"}
      end,
      "inspect" => fn call ->
        send(parent, {:call, call})
        %{sessions: [], wakes: []}
      end,
      "tune" => fn call ->
        send(parent, {:call, call})
        %{ok: false, code: "not_found", message: "session not found"}
      end,
      "assign" => fn call ->
        send(parent, {:call, call})
        %{id: "asg_test"}
      end,
      "attest" => fn call ->
        send(parent, {:call, call})
        %{code: call.params[:return_code] || "not_holder"}
      end,
      "revoke-assignment" => fn call ->
        send(parent, {:call, call})
        %{code: call.params[:return_code] || "not_authorized"}
      end,
      "assignments" => fn call ->
        send(parent, {:call, call})
        %{assignments: []}
      end,
      "work-item-create" => fn call ->
        send(parent, {:call, call})
        %{id: "wi_test", title: call.params.title}
      end,
      "work-item-get" => fn call ->
        send(parent, {:call, call})

        if call.params[:return_code],
          do: %{code: call.params.return_code},
          else: %{workItem: %{id: call.params.work_item_id}, assignments: []}
      end,
      "work-item-trace" => fn call ->
        send(parent, {:call, call})
        %{workItem: %{id: call.params.work_item_id}, assignments: [], timeline: []}
      end,
      "work-item-list" => fn call ->
        send(parent, {:call, call})
        %{workItems: []}
      end,
      "work-item-update" => fn call ->
        send(parent, {:call, call})
        %{id: call.params.work_item_id, title: call.params[:title]}
      end,
      "artifact-record" => fn call ->
        send(parent, {:call, call})
        %{artifact_id: "art_12345678", created_by_session: call.session_key}
      end,
      "artifact-get" => fn call ->
        send(parent, {:call, call})

        if call.params[:return_code],
          do: %{code: call.params.return_code},
          else: %{artifact_id: call.params.artifact_id}
      end,
      "artifacts" => fn call ->
        send(parent, {:call, call})
        %{artifacts: []}
      end,
      "identity-status" => fn call ->
        send(parent, {:call, call})
        %{live: "abc123", conflict: false}
      end,
      "kungfu-scaffold" => fn call ->
        send(parent, {:call, call})
        %{kungfu: call.params.name}
      end,
      "kungfu-list" => fn call ->
        send(parent, {:call, call})

        %{
          bundles: [
            %{
              name: "agentic-engineering",
              purpose: "Turn ideas into reviewed software.",
              phrases: ["I want someone to check the work before it goes out."],
              root_archetype: "product-owner"
            }
          ]
        }
      end
    }

    %{
      db: db,
      base_dir: base_dir,
      device: device,
      opts: [
        db: db,
        base_dir: base_dir,
        handlers: handlers,
        cli_token: "tbc_test",
        defaults: %{
          host: "testhost",
          harness: :claude,
          provider: :anthropic,
          model: Model.new("fable")
        },
        session_status: fn _ -> nil end
      ]
    }
  end

  test "agent verb allowlist is covered by the real Gateway handler table", ctx do
    agent_verbs =
      Router.__info__(:attributes)
      |> Keyword.fetch!(:agent_verbs)
      |> List.flatten()

    handler_keys = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir}) |> Map.keys()

    assert agent_verbs -- handler_keys == []
  end

  # The seam gh#11 named: operator-ask/-rule/-withdraw had a working Escalation
  # implementation, a CLI that sent them, and unit tests that called Escalation
  # DIRECTLY — but the wire router omitted them from @agent_verbs (rejected as
  # "verb not allowed") and the Gateway handler table had no entry (unknown_verb).
  # The unit tests never crossed the router, so the dead seam shipped. This test
  # drives the whole operator lifecycle THROUGH /agent/dispatch against the REAL
  # Gateway handlers, so the allowlist and the handler table must both carry the
  # verbs for it to pass.
  test "operator decision lifecycle crosses the wire router: ask -> list -> rule -> withdraw",
       ctx do
    owner = ctx.device.user_id
    raiser = create_session(ctx.db, "operator-raiser", owner, is_built_in: true)
    handlers = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})
    ctx = %{ctx | opts: Keyword.put(ctx.opts, :handlers, handlers)}

    # ask — as the raiser session (a session principal, which operator-ask requires)
    ask =
      dispatch_cli(ctx, raiser.cli_token, %{
        verb: "operator-ask",
        params: %{question: "ship 0.1.8?", options: [%{label: "ship"}, %{label: "hold"}]}
      })

    assert ask.status == 200
    asked = JSON.decode!(ask.resp_body)["result"]
    assert asked["status"] == "open"
    assert is_binary(dr_id = asked["id"])

    # list — as the owner over the org transport; the open request appears
    listed =
      dispatch_cli(ctx, "tbc_test", %{verb: "decision-requests", asUser: owner, params: %{}})

    assert listed.status == 200

    ids =
      JSON.decode!(listed.resp_body)["result"]["decisionRequests"] |> Enum.map(& &1["id"])

    assert dr_id in ids

    # rule — as the owner; org transport (not the owner's personal session) so it
    # is a genuine ruling, not the proxy_only refusal
    ruled =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "operator-rule",
        asUser: owner,
        params: %{request: dr_id, decision: "ship"}
      })

    assert ruled.status == 200
    assert JSON.decode!(ruled.resp_body)["result"]["status"] == "ruled"

    # withdraw — needs an open request, so open a second and withdraw it, closing
    # the fourth verb through the same seam
    ask2 =
      dispatch_cli(ctx, raiser.cli_token, %{
        verb: "operator-ask",
        params: %{question: "cut 0.1.9?", options: [%{label: "cut"}, %{label: "wait"}]}
      })

    assert is_binary(dr2 = JSON.decode!(ask2.resp_body)["result"]["id"])

    withdrawn =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "operator-withdraw",
        asUser: owner,
        params: %{request: dr2, reason: "moot after ship"}
      })

    assert withdrawn.status == 200
    assert JSON.decode!(withdrawn.resp_body)["result"]["status"] == "withdrawn"

    # The negative side of the SAME seam. The defect was the allowlist gate: a
    # verb it omits is refused here, before any handler, with this exact shape —
    # the refusal the three operator verbs used to draw. Assert it directly so a
    # future drop from @agent_verbs is caught as a refusal, not a silent 200.
    denied = dispatch_cli(ctx, raiser.cli_token, %{verb: "operator-nonsense", params: %{}})

    assert denied.status == 400

    assert JSON.decode!(denied.resp_body) == %{
             "error" => %{
               "code" => "invalid_message",
               "message" => "verb not allowed: operator-nonsense"
             }
           }

    # And an allowed operator verb still enforces its owner authorization THROUGH
    # the router: a session principal (not the human owner) is refused not_owner,
    # proving the verb is genuinely routed to its handler's auth, not merely let
    # past the allowlist.
    ask3 =
      dispatch_cli(ctx, raiser.cli_token, %{
        verb: "operator-ask",
        params: %{question: "who rules?", options: [%{label: "a"}, %{label: "b"}]}
      })

    assert is_binary(dr3 = JSON.decode!(ask3.resp_body)["result"]["id"])

    not_owner =
      dispatch_cli(ctx, raiser.cli_token, %{
        verb: "operator-rule",
        params: %{request: dr3, decision: "a"}
      })

    assert JSON.decode!(not_owner.resp_body)["error"]["code"] == "not_owner"
  end

  # The --status filter had the same shape of defect the operator verbs did: a working
  # unit but an unproven wire path. Escalation.list appended `AND status = ?` for ANY
  # binary status, so `decision-requests --status all` filtered on the literal 'all' and
  # returned nothing. The unit tests in escalation_test.exs call Escalation.list/list_status
  # DIRECTLY; this drives the filter THROUGH /agent/dispatch against the REAL Gateway
  # handler, so status=all listing rows and status=bogus reaching the client as a named
  # refusal are both proven on the wire, not just at the seam.
  test "decision-requests status filter crosses the wire router: all lists, illegal refuses",
       ctx do
    owner = ctx.device.user_id
    raiser = create_session(ctx.db, "dr-filter-raiser", owner, is_built_in: true)
    handlers = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})
    ctx = %{ctx | opts: Keyword.put(ctx.opts, :handlers, handlers)}

    # Two requests spanning two statuses: one left open, one ruled.
    open_ask =
      dispatch_cli(ctx, raiser.cli_token, %{
        verb: "operator-ask",
        params: %{question: "q-open?", options: [%{label: "a"}, %{label: "b"}]}
      })

    assert is_binary(open_id = JSON.decode!(open_ask.resp_body)["result"]["id"])

    ruled_ask =
      dispatch_cli(ctx, raiser.cli_token, %{
        verb: "operator-ask",
        params: %{question: "q-ruled?", options: [%{label: "a"}, %{label: "b"}]}
      })

    assert is_binary(ruled_id = JSON.decode!(ruled_ask.resp_body)["result"]["id"])

    ruled =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "operator-rule",
        asUser: owner,
        params: %{request: ruled_id, decision: "a"}
      })

    assert ruled.status == 200

    list_ids = fn params ->
      resp =
        dispatch_cli(ctx, "tbc_test", %{verb: "decision-requests", asUser: owner, params: params})

      assert resp.status == 200
      JSON.decode!(resp.resp_body)["result"]["decisionRequests"] |> Enum.map(& &1["id"])
    end

    # status=all returns rows in BOTH statuses over the wire — the regression: before the
    # fix this filtered on literal 'all' and returned [].
    all_ids = list_ids.(%{status: "all"})
    assert open_id in all_ids
    assert ruled_id in all_ids

    # Absent status defaults to "open" through the router: the open row shows, the ruled
    # one is filtered out.
    default_ids = list_ids.(%{})
    assert open_id in default_ids
    refute ruled_id in default_ids

    # An explicit legal status filters over the wire to exactly that status.
    open_only = list_ids.(%{status: "open"})
    assert open_id in open_only
    refute ruled_id in open_only

    # An illegal status reaches the client as a NAMED refusal (HTTP 400), not a silent
    # empty 200 — the refusal names the legal set.
    bogus =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "decision-requests",
        asUser: owner,
        params: %{status: "bogus"}
      })

    assert bogus.status == 400
    error = JSON.decode!(bogus.resp_body)["error"]
    assert error["code"] == "invalid"
    assert error["message"] =~ "open, ruled, consumed, withdrawn, superseded, all"
  end

  test "identity status crosses the closed CLI verb router", ctx do
    response =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "identity-status",
        asUser: "flynn",
        params: %{}
      })

    assert response.status == 200

    assert JSON.decode!(response.resp_body) ==
             %{"result" => %{"live" => "abc123", "conflict" => false}}

    assert_receive {:call,
                    %{
                      verb: "identity-status",
                      origin: "user:flynn",
                      params: %{}
                    }}
  end

  test "agent tune defers an unknown session key to the gateway privacy seam", ctx do
    response =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "tune",
        asUser: "flynn",
        sessionKey: "unknown-private-target",
        params: %{setting: "set_model", model: "claude-fable-5"}
      })

    assert response.status == 404

    assert_receive {:call,
                    %{
                      verb: "tune",
                      origin: "user:flynn",
                      session_key: "unknown-private-target",
                      params: %{setting: "set_model", model: "claude-fable-5"}
                    }}

    assert JSON.decode!(response.resp_body) == %{
             "error" => %{"code" => "not_found", "message" => "session not found"}
           }
  end

  test "agent tune preserves public control keys and structured failure fields", ctx do
    parent = self()

    handlers =
      Map.put(ctx.opts[:handlers], "tune", fn call ->
        send(parent, {:call, call})

        %{
          ok: false,
          code: "runtime_config_mismatch",
          message: "readback differed",
          model: "gpt-5.6-sol",
          effort: "high",
          projection_committed: false,
          cleanup_status: "unverified",
          lifecycle_event_id: "le_123",
          warnings: ["candidate close unverified"]
        }
      end)

    ctx = %{ctx | opts: Keyword.put(ctx.opts, :handlers, handlers)}

    response =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "tune",
        asUser: "flynn",
        sessionKey: "live-session",
        params: %{setting: "set_fast_mode", fastMode: "on"}
      })

    assert response.status == 400

    assert_receive {:call,
                    %{
                      verb: "tune",
                      session_key: "live-session",
                      params: %{setting: "set_fast_mode", fastMode: "on"}
                    }}

    assert JSON.decode!(response.resp_body) == %{
             "error" => %{
               "code" => "runtime_config_mismatch",
               "message" => "readback differed",
               "model" => "gpt-5.6-sol",
               "effort" => "high",
               "projectionCommitted" => false,
               "cleanupStatus" => "unverified",
               "lifecycleEventId" => "le_123",
               "warnings" => ["candidate close unverified"]
             }
           }

    effort =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "tune",
        asUser: "flynn",
        sessionKey: "live-session",
        params: %{setting: "set_reasoning", reasoningLevel: "high"}
      })

    assert effort.status == 400

    assert_receive {:call,
                    %{
                      verb: "tune",
                      session_key: "live-session",
                      params: %{setting: "set_reasoning", reasoningLevel: "high"}
                    }}
  end

  test "an empty org cannot use the local first-user exception over the wire", ctx do
    db = :"empty_wire_add_user_db_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: db,
      start: {DB, :start_link, [[path: ":memory:", name: db]]}
    })

    :ok = Tightbeam.Schema.ensure_all(db)

    opts =
      Keyword.merge(ctx.opts,
        db: db,
        handlers: Gateway.handlers(%{db: db, base_dir: ctx.base_dir})
      )

    response =
      dispatch_cli(%{ctx | opts: opts}, "tbc_test", %{
        verb: "add-user",
        asUser: "first",
        params: %{userId: "first", isAdmin: true}
      })

    assert response.status == 403

    assert JSON.decode!(response.resp_body) == %{
             "error" => %{
               "code" => "invalid_identity",
               "message" => "asserted user does not exist"
             }
           }

    assert Devices.user(db, "first") == nil
  end

  test "loopback bootstrap-user reserves the first user and Main through the gateway", ctx do
    {db, opts} = empty_router(ctx, "loopback_bootstrap")

    response =
      dispatch_cli(%{ctx | opts: opts}, "tbc_test", %{
        verb: "bootstrap-user",
        params: %{userId: "alice"}
      })

    assert response.status == 200

    assert %{
             "result" => %{
               "phase" => "reserved",
               "userId" => "alice",
               "isAdmin" => true,
               "rootSessionKey" => root
             }
           } = JSON.decode!(response.resp_body)

    assert root == Org.personal_session_key("alice")
    assert Devices.user(db, "alice").creation_kind == "gateway_local_bootstrap"
  end

  test "non-loopback bootstrap-user refuses before any database write", ctx do
    {db, opts} = empty_router(ctx, "remote_bootstrap")

    response =
      conn(
        :post,
        "/agent/dispatch",
        JSON.encode!(%{verb: "bootstrap-user", params: %{userId: "alice"}})
      )
      |> Map.put(:remote_ip, {10, 0, 0, 8})
      |> put_req_header("authorization", "Bearer tbc_test")
      |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
      |> Router.call(Router.init(opts))

    assert response.status == 403

    assert JSON.decode!(response.resp_body) == %{
             "error" => %{"code" => "forbidden", "message" => "local bootstrap required"}
           }

    assert Devices.user(db, "alice") == nil
  end

  test "authenticated harness projection route returns the registry bytes", ctx do
    request =
      conn(:get, "/harnesses")
      |> put_req_header("authorization", "Bearer tbc_test")
      |> put_req_header(
        "x-tightbeam-cli-version",
        Tightbeam.CliCompatibility.required_version()
      )

    response = Router.call(request, Router.init(ctx.opts))
    expected = "[" <> Enum.map_join(Tightbeam.Harness.all(), ",", & &1.wire_projection()) <> "]"

    assert response.status == 200
    assert response.resp_body == expected
  end

  test "/version states which bytes the gateway is: version + build stamp", ctx do
    response = Router.call(conn(:get, "/version"), Router.init(ctx.opts))

    assert response.status == 200
    body = JSON.decode!(response.resp_body)

    # The release version comes from its single home; the seam only asserts the
    # body carries it, not a hardcoded string that every bump would break.
    assert body["version"] == Tightbeam.CliCompatibility.required_version()

    # build is the compile-time rev-list count: a positive integer, and the exact
    # value the stamp captured — never runtime git.
    assert is_integer(body["build"]) and body["build"] > 0
    assert body["build"] == Tightbeam.BuildStamp.build()
    assert body["sha"] == Tightbeam.BuildStamp.sha()
  end

  test "CLI exact-version refusal is loud and precedes bearer authentication", ctx do
    body = JSON.encode!(%{verb: "inspect", asUser: "flynn", params: %{}})

    incompatible =
      conn(:post, "/agent/dispatch", body)
      |> put_req_header("authorization", "Bearer tbc_test")
      |> put_req_header("x-tightbeam-cli-version", "0.2.0")
      |> Router.call(Router.init(ctx.opts))

    assert incompatible.status == 426

    assert JSON.decode!(incompatible.resp_body) == %{
             "error" => %{
               "code" => "incompatible_cli",
               "message" =>
                 "your CLI offered 0.2.0; this gateway requires #{Tightbeam.CliCompatibility.required_version()}"
             }
           }

    auth_failure =
      conn(:post, "/agent/dispatch", body)
      |> put_req_header("authorization", "Bearer wrong")
      |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
      |> Router.call(Router.init(ctx.opts))

    assert auth_failure.status == 401
    assert JSON.decode!(auth_failure.resp_body) == %{"error" => %{"code" => "auth_failed"}}

    non_cli =
      conn(:get, "/api/streams")
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(ctx.opts))

    assert non_cli.status == 200
  end

  test "kungfu scaffold crosses the closed CLI verb router with its attributed name", ctx do
    response =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "kungfu-scaffold",
        asUser: "flynn",
        params: %{name: "demo", purpose: "Help a team do demo work."}
      })

    assert response.status == 200
    assert JSON.decode!(response.resp_body) == %{"result" => %{"kungfu" => "demo"}}

    assert_receive {:call,
                    %{
                      verb: "kungfu-scaffold",
                      origin: "user:flynn",
                      params: %{name: "demo", purpose: "Help a team do demo work."}
                    }}
  end

  test "kungfu listing crosses the closed CLI verb router", ctx do
    response =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "kungfu-list",
        asUser: "flynn",
        params: %{}
      })

    assert response.status == 200

    assert JSON.decode!(response.resp_body) == %{
             "result" => %{
               "bundles" => [
                 %{
                   "name" => "agentic-engineering",
                   "purpose" => "Turn ideas into reviewed software.",
                   "phrases" => ["I want someone to check the work before it goes out."],
                   "rootArchetype" => "product-owner"
                 }
               ]
             }
           }

    assert_receive {:call,
                    %{
                      verb: "kungfu-list",
                      origin: "user:flynn",
                      params: %{}
                    }}
  end

  test "work and work-item device routes expose owner-scoped random-access snapshots", ctx do
    :ok = Tightbeam.Schema.ensure_all(ctx.db)

    create_session(ctx.db, "holder", ctx.device.user_id)

    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        principal: {:user, ctx.device.user_id},
        params: %{title: "Observed"}
      })

    assignment =
      Assignments.__handle__(ctx.db, "assign", %{
        principal: {:user, ctx.device.user_id},
        session_key: "holder",
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{subject: "Build it", work_item_id: item.id}
      })

    WorkState.emit(ctx.db, assignment.id, nil)
    WorkState.emit_item(ctx.db, item.id, "composition")

    work = get_device(ctx, ctx.device, "/api/work?state=all&status=open&sessionKey=holder")
    assert work.status == 200

    assert %{"work" => [%{"id" => id, "status" => "open", "workItemId" => item_id}]} =
             JSON.decode!(work.resp_body)

    assert id == assignment.id
    assert item_id == item.id

    detail = get_device(ctx, ctx.device, "/api/work/#{assignment.id}")
    assert detail.status == 200
    assert JSON.decode!(detail.resp_body)["holder"]["sessionKey"] == "holder"

    items = get_device(ctx, ctx.device, "/api/work-items")
    assert items.status == 200

    assert %{
             "items" => [
               %{"workItem" => %{"id" => item_id}, "assignments" => [%{"id" => assignment_id}]}
             ],
             "cursor" => %{"assignment" => _, "workItem" => _}
           } = JSON.decode!(items.resp_body)

    assert item_id == item.id
    assert assignment_id == assignment.id

    item_detail = get_device(ctx, ctx.device, "/api/work-items/#{item.id}")
    assert item_detail.status == 200

    invalid = get_device(ctx, ctx.device, "/api/work?status=blocked")
    assert invalid.status == 400
    assert JSON.decode!(invalid.resp_body)["error"]["code"] == "invalid_status"

    other = approved_device(ctx.db, "other-device", "Other")
    assert get_device(ctx, other, "/api/work/#{assignment.id}").status == 404
    assert get_device(ctx, other, "/api/work-items/#{item.id}").status == 404
  end

  test "all work-item verbs route, preserve generic target behavior, and map unknown ids", ctx do
    target = create_session(ctx.db, "work-item-target", "flynn")

    for {verb, params} <- [
          {"work-item-create", %{title: "Create"}},
          {"work-item-get", %{workItemId: "wi_test"}},
          {"work-item-trace", %{workItemId: "wi_test"}},
          {"work-item-list", %{}},
          {"work-item-update", %{workItemId: "wi_test", title: "Update"}}
        ] do
      response =
        dispatch_cli(ctx, "tbc_test", %{
          verb: verb,
          asUser: "flynn",
          sessionKey: target.session_key,
          params: params
        })

      assert response.status == 200
      assert_receive {:call, %{verb: ^verb, session_key: "work-item-target"}}
    end

    missing =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "work-item-get",
        asUser: "flynn",
        params: %{workItemId: "missing", returnCode: "unknown_work_item"}
      })

    assert missing.status == 404
    assert JSON.decode!(missing.resp_body)["error"]["code"] == "unknown_work_item"
  end

  test "device routes require a device bearer", ctx do
    conn = Router.call(conn(:get, "/api/streams"), Router.init(ctx.opts))
    assert conn.status == 401
    assert JSON.decode!(conn.resp_body) == %{"error" => %{"code" => "auth_failed"}}

    conn =
      conn(:get, "/api/streams") |> put_req_header("authorization", "Bearer #{ctx.device.token}")

    conn = Router.call(conn, Router.init(ctx.opts))
    assert conn.status == 200
  end

  test "/api/streams refuses overrides as an unsupported transport", ctx do
    body =
      JSON.encode!(%{
        displayName: "Overridden",
        idempotencyKey: "unsupported-overrides",
        overrides: %{skills_add: ["review"]}
      })

    response =
      conn(:post, "/api/streams", body)
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(ctx.opts))

    assert response.status == 400

    assert JSON.decode!(response.resp_body) == %{
             "error" => %{
               "code" => "invalid_overrides",
               "message" => "overrides are unsupported on /api/streams; use /agent/dispatch"
             }
           }
  end

  test "PATCH /api/streams/:key decodes a clawline '+' path key as a space", ctx do
    key = "agent:main:clawline:mike:main s_test1234"
    create_session(ctx.db, key, ctx.device.user_id)
    opts = with_handler(ctx.opts, "tune", &send_call/1)

    plus_key = String.replace(key, " ", "+")

    response =
      conn(:patch, "/api/streams/#{plus_key}", JSON.encode!(%{"displayName" => "Renamed"}))
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 200
    assert_receive {:call, %{verb: "tune", session_key: ^key}}
  end

  test "PATCH /api/streams/:key still accepts an already-decoded space in the key", ctx do
    key = "agent:main:clawline:mike:main s_test5678"
    create_session(ctx.db, key, ctx.device.user_id)
    opts = with_handler(ctx.opts, "tune", &send_call/1)

    response =
      conn(:patch, "/api/streams/#{key}", JSON.encode!(%{"displayName" => "Renamed"}))
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 200
    assert_receive {:call, %{verb: "tune", session_key: ^key}}
  end

  test "DELETE /api/streams/:key decodes a clawline '+' path key as a space", ctx do
    key = "agent:main:clawline:mike:main s_test9012"
    create_session(ctx.db, key, ctx.device.user_id)

    opts =
      with_handler(ctx.opts, "retire", fn call ->
        send_call(call)
        %{deleted_session_key: call.session_key}
      end)

    plus_key = String.replace(key, " ", "+")

    response =
      conn(:delete, "/api/streams/#{plus_key}", JSON.encode!(%{}))
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 200
    assert_receive {:call, %{verb: "retire", session_key: ^key}}
    assert JSON.decode!(response.resp_body) == %{"deletedSessionKey" => key}
  end

  test "PATCH /api/streams/:key still accepts a single-encoded %20 space in the key", ctx do
    key = "agent:main:clawline:mike:main s_test0020"
    create_session(ctx.db, key, ctx.device.user_id)
    opts = with_handler(ctx.opts, "tune", &send_call/1)

    percent_encoded_key = String.replace(key, " ", "%20")

    response =
      conn(
        :patch,
        "/api/streams/#{percent_encoded_key}",
        JSON.encode!(%{"displayName" => "Renamed"})
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 200
    assert_receive {:call, %{verb: "tune", session_key: ^key}}
  end

  test "PATCH /api/streams/:key decodes the captured double-encoded Clawline path", ctx do
    key = "agent:main:clawline:flynn:main s_request_path"
    create_session(ctx.db, key, ctx.device.user_id)
    opts = with_handler(ctx.opts, "tune", &send_call/1)

    response =
      conn(
        :patch,
        "/api/streams/agent%253Amain%253Aclawline%253Aflynn%253Amain%2520s_request_path",
        JSON.encode!(%{"displayName" => "Renamed"})
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 200
    assert_receive {:call, %{verb: "tune", session_key: ^key}}
  end

  test "DELETE /api/streams/:key decodes the captured double-encoded Clawline path", ctx do
    key = "agent:main:clawline:flynn:main s_request_path"
    create_session(ctx.db, key, ctx.device.user_id)

    opts =
      with_handler(ctx.opts, "retire", fn call ->
        send_call(call)
        %{deleted_session_key: call.session_key}
      end)

    response =
      conn(
        :delete,
        "/api/streams/agent%253Amain%253Aclawline%253Aflynn%253Amain%2520s_request_path",
        JSON.encode!(%{})
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 200
    assert_receive {:call, %{verb: "retire", session_key: ^key}}
    assert JSON.decode!(response.resp_body) == %{"deletedSessionKey" => key}
  end

  test "PATCH /api/streams/:key accepts at most four total percent-decode layers", ctx do
    key = "agent:main:clawline:mike:main s_test_decode_cap"
    create_session(ctx.db, key, ctx.device.user_id)
    opts = with_handler(ctx.opts, "tune", &send_call/1)

    four_layer_key = String.replace(key, " ", "%25252520")

    accepted =
      conn(
        :patch,
        "/api/streams/#{four_layer_key}",
        JSON.encode!(%{"displayName" => "Renamed"})
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert accepted.status == 200
    assert_receive {:call, %{verb: "tune", session_key: ^key}}

    five_layer_key = String.replace(key, " ", "%2525252520")

    rejected =
      conn(
        :patch,
        "/api/streams/#{five_layer_key}",
        JSON.encode!(%{"displayName" => "Not renamed"})
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert rejected.status == 404
    refute_received {:call, _}
  end

  test "stream mutations reject a repeatedly encoded path separator before lookup", ctx do
    key = "agent:main:clawline:mike:main/child"
    create_session(ctx.db, key, ctx.device.user_id)

    opts =
      ctx.opts
      |> with_handler("tune", &send_call/1)
      |> with_handler("retire", &send_call/1)

    encoded_key = String.replace(key, "/", "%252F")

    patch =
      conn(:patch, "/api/streams/#{encoded_key}", JSON.encode!(%{"displayName" => "Renamed"}))
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    delete =
      conn(:delete, "/api/streams/#{encoded_key}", JSON.encode!(%{}))
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert patch.status == 400
    assert delete.status == 400
    refute_received {:call, _}
  end

  test "stream mutations reject malformed percent encoding before lookup", ctx do
    key = "agent:main:clawline:mike:main%zz"
    create_session(ctx.db, key, ctx.device.user_id)

    opts =
      ctx.opts
      |> with_handler("tune", &send_call/1)
      |> with_handler("retire", &send_call/1)

    encoded_key = String.replace(key, "%", "%2525")

    patch =
      conn(:patch, "/api/streams/#{encoded_key}", JSON.encode!(%{"displayName" => "Renamed"}))
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    delete =
      conn(:delete, "/api/streams/#{encoded_key}", JSON.encode!(%{}))
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert patch.status == 400
    assert delete.status == 400
    refute_received {:call, _}
  end

  test "encoded stream keys do not widen PATCH or DELETE ownership", ctx do
    other = approved_device(ctx.db, "other-stream-device", "Other Stream Owner")
    key = "agent:main:clawline:other:main s_private"
    create_session(ctx.db, key, other.user_id)

    opts =
      ctx.opts
      |> with_handler("tune", &send_call/1)
      |> with_handler("retire", &send_call/1)

    encoded_key = String.replace(key, " ", "%2520")

    patch =
      conn(:patch, "/api/streams/#{encoded_key}", JSON.encode!(%{"displayName" => "Renamed"}))
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    delete =
      conn(:delete, "/api/streams/#{encoded_key}", JSON.encode!(%{}))
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert patch.status == 404
    assert delete.status == 404
    refute_received {:call, _}
  end

  test "PATCH /api/streams/:key resolves a double-encoded '%252B' path key as a literal plus",
       ctx do
    key = "agent:main:clawline:mike:main+plus_test2b"
    create_session(ctx.db, key, ctx.device.user_id)
    opts = with_handler(ctx.opts, "tune", &send_call/1)

    double_encoded_key = String.replace(key, "+", "%252B")

    response =
      conn(
        :patch,
        "/api/streams/#{double_encoded_key}",
        JSON.encode!(%{"displayName" => "Renamed"})
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 200
    assert_receive {:call, %{verb: "tune", session_key: ^key}}
  end

  test "PATCH /api/streams/:key rejects a malformed percent escape in the key", ctx do
    opts = with_handler(ctx.opts, "tune", &send_call/1)

    response =
      conn(
        :patch,
        "/api/streams/agent:main:clawline:mike:main%zzmalformed",
        JSON.encode!(%{"displayName" => "Renamed"})
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 400
    refute_received {:call, _}
  end

  test "agent dispatch enforces cli bearer, allowlist, and identity/target resolution", ctx do
    actor =
      Org.create(ctx.db, %{
        session_key: "orch",
        display_name: "Orchestrator",
        owner_user_id: "flynn",
        origin: "user:flynn",
        handle: "orchestrator:demo",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    Roles.create!(ctx.db, "orchestrator:demo", "flynn", actor.session_key)

    body =
      JSON.encode!(%{
        verb: "wake",
        as: "orchestrator:demo",
        role: "orchestrator:demo",
        params: %{prompt: "hi"}
      })

    unauth =
      conn(:post, "/agent/dispatch", body)
      |> put_req_header(
        "x-tightbeam-cli-version",
        Tightbeam.CliCompatibility.required_version()
      )
      |> Router.call(Router.init(ctx.opts))

    assert unauth.status == 401

    request =
      conn(:post, "/agent/dispatch", body)
      |> put_req_header("authorization", "Bearer tbc_test")
      |> put_req_header(
        "x-tightbeam-cli-version",
        Tightbeam.CliCompatibility.required_version()
      )

    response = Router.call(request, Router.init(ctx.opts))
    assert response.status == 200

    assert_receive {:call,
                    %{verb: "wake", origin: "agent:orchestrator:demo", session_key: "orch"}}

    disallowed =
      conn(:post, "/agent/dispatch", JSON.encode!(%{verb: "post", as_user: "flynn"}))
      |> put_req_header("authorization", "Bearer tbc_test")
      |> put_req_header(
        "x-tightbeam-cli-version",
        Tightbeam.CliCompatibility.required_version()
      )
      |> Router.call(Router.init(ctx.opts))

    assert disallowed.status == 400
  end

  test "the dispatch boundary strips a wake's substrate-only carriers", ctx do
    # Law 0: a client-supplied wake `assignmentId` would forge
    # wake -> turn -> trace attribution. The spec pins that it is STRIPPED at the
    # dispatch boundary, so this drives a REAL authenticated /agent/dispatch
    # request rather than calling the handler or the strip helper directly.
    #
    # The other half of the rule — that the strip is SCOPED to that carrier and
    # leaves `assignmentId` alone on attest/assign/dispatch — is proven at the
    # pure `atomize_params/2` seam in job_forensics_test, because asserting it
    # here would run through Dispatch's rule engine (global persistent_term state)
    # and prove nothing reliably.
    forge =
      JSON.encode!(%{
        verb: "wake",
        asUser: "flynn",
        params: %{
          prompt: "an ordinary conversational wake",
          assignmentId: "asg_victim",
          requestRef: "dr_forged"
        }
      })

    response =
      conn(:post, "/agent/dispatch", forge)
      |> put_req_header("authorization", "Bearer tbc_test")
      |> put_req_header(
        "x-tightbeam-cli-version",
        Tightbeam.CliCompatibility.required_version()
      )
      |> Router.call(Router.init(ctx.opts))

    # The handler being REACHED with the params is the proof; assert that first, so
    # a refusal upstream fails here with a legible message rather than as a status
    # mismatch. (Dispatch consults Rules, which lives in :persistent_term — global
    # across test files — so coupling this proof to an HTTP status makes it hostage
    # to whatever rule set another file last loaded.)
    assert_receive {:call, %{verb: "wake", params: wake_params}}

    refute Map.has_key?(wake_params, :assignment_id),
           "a client-supplied wake assignmentId must never reach the handler"

    refute Map.has_key?(wake_params, :request_ref),
           "a client-supplied wake requestRef must never reach the handler"

    assert wake_params[:prompt] == "an ordinary conversational wake"
    assert response.status == 200
  end

  test "operator ruling provenance is substrate-only" do
    params =
      Router.atomize_params_for_test("operator-rule", %{
        "request" => "dr_1",
        "decision" => "accept",
        "ruledViaSessionKey" => "forged-session"
      })

    assert params == %{request: "dr_1", decision: "accept"}
  end

  test "Proof 2: agent-supplied createdInTurnSeq and createdContextKnown are stripped from work-item-create",
       ctx do
    forged =
      JSON.encode!(%{
        verb: "work-item-create",
        asUser: "flynn",
        params: %{
          title: "substrate-stamped",
          createdInTurnSeq: 999_999,
          createdContextKnown: 0
        }
      })

    response =
      conn(:post, "/agent/dispatch", forged)
      |> put_req_header("authorization", "Bearer tbc_test")
      |> put_req_header(
        "x-tightbeam-cli-version",
        Tightbeam.CliCompatibility.required_version()
      )
      |> Router.call(Router.init(ctx.opts))

    assert_receive {:call, %{verb: "work-item-create", params: params}}
    assert params[:title] == "substrate-stamped"
    refute Map.has_key?(params, :created_in_turn_seq)
    refute Map.has_key?(params, :created_context_known)
    assert response.status == 200
  end

  test "typed target grammar distinguishes keys, users, and roles without unions", ctx do
    {:pending, _device} =
      Devices.pair(ctx.db, %{
        device_id: "mike-device",
        claimed_name: "Mike",
        platform: nil,
        model: nil
      })

    main_key = Org.personal_session_key("mike")

    Org.create(ctx.db, %{
      session_key: main_key,
      display_name: "Main",
      owner_user_id: "mike",
      origin: "user:mike",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    assert dispatch_wake(ctx, %{"userId" => "mike"}).status == 200
    assert_receive {:call, %{verb: "wake", session_key: ^main_key, target_role: nil}}

    # The type is the FIELD: "mike" as a role is a role lookup, never a user.
    bare_user = dispatch_wake(ctx, %{"role" => "mike"})
    assert bare_user.status == 404
    assert JSON.decode!(bare_user.resp_body)["error"]["message"] == "unknown role: mike"

    unknown_user = dispatch_wake(ctx, %{"userId" => "missing"})
    assert unknown_user.status == 404

    # Seam validation: retired field teaches; unions are refused.
    retired = dispatch_wake(ctx, %{"target" => "anything"})
    assert retired.status == 400
    assert JSON.decode!(retired.resp_body)["error"]["message"] =~ ~s("target" is retired)

    union = dispatch_wake(ctx, %{"role" => "x", "userId" => "mike"})
    assert union.status == 400

    assert JSON.decode!(union.resp_body)["error"]["message"] ==
             "exactly one of sessionKey, role, userId"

    key =
      Org.create(ctx.db, %{
        session_key: "agent:direct",
        display_name: "Direct",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    assert dispatch_wake(ctx, %{"sessionKey" => key.session_key}).status == 200
    assert_receive {:call, %{session_key: "agent:direct", target_role: nil}}

    unknown_key = dispatch_wake(ctx, %{"sessionKey" => "agent:missing"})
    assert unknown_key.status == 404
    assert JSON.decode!(unknown_key.resp_body)["error"]["message"] =~ "unknown sessionKey"

    Org.create(ctx.db, %{
      session_key: "role-session",
      display_name: "Role holder",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    Roles.create!(ctx.db, "mike", "flynn", "role-session")
    Roles.create!(ctx.db, "fallback", "mike", nil)

    assert dispatch_wake(ctx, %{"role" => "mike"}).status == 200

    assert_receive {:call,
                    %{
                      verb: "wake",
                      session_key: "role-session",
                      target_role: "mike",
                      role_fallback: false
                    }}

    assert dispatch_wake(ctx, %{"role" => "fallback"}).status == 200

    assert_receive {:call,
                    %{
                      session_key: ^main_key,
                      target_role: "fallback",
                      role_fallback: true
                    }}

    unknown = dispatch_wake(ctx, %{"role" => "unknown-role"})
    assert unknown.status == 404

    assert JSON.decode!(unknown.resp_body) == %{
             "error" => %{"code" => "not_found", "message" => "unknown role: unknown-role"}
           }
  end

  test "assignment typed-target teaching errors precede Dispatch and status classes are pinned",
       ctx do
    create_session(ctx.db, "holder-target", "flynn")

    missing =
      dispatch_cli(ctx, "tbc_test", %{verb: "assign", asProcess: "cron", params: %{subject: "x"}})

    assert missing.status == 400
    assert JSON.decode!(missing.resp_body)["error"]["code"] == "missing_target"

    wrong =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "assign",
        asProcess: "cron",
        userId: "flynn",
        params: %{subject: "x"}
      })

    assert wrong.status == 400
    assert JSON.decode!(wrong.resp_body)["error"]["code"] == "invalid_target_kind"

    union =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "assign",
        asProcess: "cron",
        sessionKey: "holder-target",
        role: "x",
        params: %{subject: "x"}
      })

    assert union.status == 400
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM events")

    forbidden =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "attest",
        asUser: "flynn",
        params: %{returnCode: "not_holder"}
      })

    assert forbidden.status == 403

    missing_assignment =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "attest",
        asUser: "flynn",
        params: %{returnCode: "unknown_assignment"}
      })

    assert missing_assignment.status == 404
  end

  test "org CLI reserves process:tightbeam while other process origins still attribute", ctx do
    target = create_session(ctx.db, "reserved-origin-target", "flynn")

    wake_handler = fn call ->
      wake =
        Wakes.schedule(ctx.db, %{
          session_key: call.session_key,
          target_role: nil,
          origin: call.origin,
          prompt: call.params.prompt,
          due_at: 0
        })

      send(self(), {:persisted_wake, wake})
      wake
    end

    handlers = ctx.opts |> Keyword.fetch!(:handlers) |> Map.put("wake", wake_handler)
    ctx = %{ctx | opts: Keyword.put(ctx.opts, :handlers, handlers)}

    rejected =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "wake",
        asProcess: "tightbeam",
        sessionKey: target.session_key,
        params: %{prompt: "forged"}
      })

    assert rejected.status == 403

    assert JSON.decode!(rejected.resp_body) == %{
             "error" => %{
               "code" => "reserved_origin",
               "message" => "process:tightbeam is reserved to the substrate"
             }
           }

    refute_received {:persisted_wake, _}
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM wakes")

    accepted =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "wake",
        asProcess: "ci",
        sessionKey: target.session_key,
        params: %{prompt: "build finished"}
      })

    assert accepted.status == 200
    assert_receive {:persisted_wake, %{origin: "process:ci", state: "pending"}}

    assert {:ok, [["process:ci", "pending"]]} =
             DB.query(ctx.db, "SELECT origin, state FROM wakes")
  end

  test "assign resolves a live-bound role and refuses unusable references", ctx do
    ensure_main_session(ctx.db, "flynn")
    holder = create_session(ctx.db, "assign-holder", "flynn")
    retired = create_session(ctx.db, "assign-retired", "flynn")
    Roles.create!(ctx.db, "bound-assignment", "flynn", holder.session_key)
    Roles.create!(ctx.db, "fallback-assignment", "flynn", nil)
    Org.retire(ctx.db, retired.session_key, "user:flynn", 1_000)

    assert dispatch_cli(ctx, "tbc_test", %{
             verb: "assign",
             asUser: "flynn",
             role: "bound-assignment",
             params: %{subject: "x"}
           }).status == 200

    assert_receive {:call,
                    %{
                      verb: "assign",
                      session_key: "assign-holder",
                      target_role: "bound-assignment",
                      role_fallback: false
                    }}

    # Previously 200 on the owner's personal session with role_fallback: true —
    # the phantom binding of wi_756153b7. The seam refuses it now.
    unbound =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "assign",
        asUser: "flynn",
        role: "fallback-assignment",
        params: %{subject: "x"}
      })

    assert unbound.status == 400
    assert JSON.decode!(unbound.resp_body)["error"]["code"] == "no_live_role_holder"
    refute_receive {:call, %{verb: "assign", target_role: "fallback-assignment"}}

    for body <- [
          %{verb: "assign", asUser: "flynn", role: "missing-assignment", params: %{subject: "x"}},
          %{verb: "assign", asUser: "flynn", sessionKey: "missing", params: %{subject: "x"}}
        ] do
      response = dispatch_cli(ctx, "tbc_test", body)
      assert response.status == 404
      assert JSON.decode!(response.resp_body)["error"]["code"] == "not_found"
    end

    response =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "assign",
        asUser: "flynn",
        sessionKey: retired.session_key,
        params: %{subject: "x"}
      })

    assert response.status == 400
    assert JSON.decode!(response.resp_body)["error"]["code"] == "session_retired"
  end

  # wi_756153b7. Assigning to a role with no live holder used to bind the owner's
  # personal session with holderFallback=1: an obligation on a session that is not
  # the role's holder and commonly not even the requested provider, while the
  # requester believed it dispatched. Specimens asg_6f380b79 (unbound role) and
  # asg_388a5a54 (role whose bound session had been retired) — both shapes below.
  #
  # Run against the REAL assign/dispatch handlers over a session-authenticated
  # request, because the claim is "no row", and a mocked handler writes none either
  # way. The positive control proves this same wiring DOES write a row for a live
  # holder, so the zero rows above it is the refusal and not dead plumbing.
  test "assign and dispatch refuse a role with no live holder and open no assignment", ctx do
    ensure_main_session(ctx.db, "flynn")
    live = create_session(ctx.db, "live-holder", "flynn")
    dead = create_session(ctx.db, "dead-holder", "flynn")
    caller = create_session(ctx.db, "phantom-caller", "flynn")

    Roles.create!(ctx.db, "live-role", "flynn", live.session_key)
    Roles.create!(ctx.db, "unbound-role", "flynn", nil)
    Roles.create!(ctx.db, "retired-role", "flynn", dead.session_key)
    Roles.create!(ctx.db, "caller-role", "flynn", caller.session_key)
    Org.retire(ctx.db, dead.session_key, "user:flynn", 1_000)

    ctx = %{ctx | opts: Keyword.put(ctx.opts, :handlers, observed_real_handlers(ctx))}

    for verb <- ["assign", "dispatch"], role <- ["unbound-role", "retired-role"] do
      response =
        dispatch_session(ctx, caller, %{
          verb: verb,
          role: role,
          params: %{subject: "phantom #{verb} on #{role}", brief: "Bind no ghost."}
        })

      assert response.status == 400

      assert JSON.decode!(response.resp_body)["error"] == %{
               "code" => "no_live_role_holder",
               "message" =>
                 "role #{role} has no live bound session; spawn one and bind the role, " <>
                   "or target an active sessionKey"
             }

      refute_receive {:call, %{verb: ^verb}}
    end

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM assignments")

    accepted =
      dispatch_session(ctx, caller, %{
        verb: "assign",
        role: "live-role",
        params: %{subject: "work a live holder can actually do"}
      })

    assert accepted.status == 200
    assert_receive {:call, %{verb: "assign", session_key: "live-holder", role_fallback: false}}

    assert {:ok, [["live-holder", "live-role", 0]]} =
             DB.query(ctx.db, "SELECT holderKey, holderRole, holderFallback FROM assignments")
  end

  test "acting as a role requires its active binding", ctx do
    holder =
      Org.create(ctx.db, %{
        session_key: "holder",
        display_name: "Holder",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    Roles.create!(ctx.db, "held", "flynn", holder.session_key)
    Roles.create!(ctx.db, "vacant", "flynn", nil)

    held = dispatch_as_role(ctx, "held")
    assert held.status == 200
    assert_receive {:call, %{origin: "agent:held"}}

    vacant = dispatch_as_role(ctx, "vacant")
    assert vacant.status == 400
    assert JSON.decode!(vacant.resp_body)["error"]["message"] =~ "vacant"
  end

  # The credential kind reaches the client as "apiKey", and it is NOT the
  # camelizer that makes it so. `wire_value/1` lower-camelizes KEYS only; an atom
  # VALUE encodes verbatim. This pins that fact, so the day someone "simplifies"
  # Gateway.wire_credential_kind/1 into an atom passthrough, this goes red here
  # rather than silently shipping "api_key" to a decoder that has no case for it.
  test "the wire camelizes keys but never values, so the credential kind is a literal", ctx do
    Org.create(ctx.db, %{
      session_key: "k1",
      display_name: "Kind",
      owner_user_id: ctx.device.user_id,
      origin: "user:#{ctx.device.user_id}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-sonnet-5")
    })

    opts =
      Keyword.put(ctx.opts, :session_status, fn _key ->
        %{sessionKey: "k1", display: %{credential_kind: :api_key}}
      end)

    conn =
      Plug.Test.conn(:get, "/api/session-status?sessionKey=k1")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.device.token)
      |> Router.call(Router.init(opts))

    assert conn.status == 200

    # The KEY camelized (credential_kind -> credentialKind). The VALUE did not:
    # the atom shipped verbatim as "api_key", which is not a kind the client
    # knows. That is the whole reason `Gateway.wire_credential_kind/1` emits the
    # literal instead of leaning on this transform.
    assert conn.resp_body =~ ~s("credentialKind":"api_key")
    refute conn.resp_body =~ "apiKey"
  end

  test "facts-read routes as a read verb and list sessions use createdAt on the wire", ctx do
    parent = self()

    facts_opts =
      with_handler(ctx.opts, "facts-read", fn call ->
        send(parent, {:call, call})
        %{exists: false, fact: nil}
      end)

    facts =
      dispatch_cli(%{ctx | opts: facts_opts}, "tbc_test", %{
        verb: "facts-read",
        asUser: "flynn",
        params: %{kind: "tour-given", scope: "agent:tour:app"}
      })

    assert facts.status == 200

    assert_receive {:call,
                    %{
                      verb: "facts-read",
                      params: %{kind: "tour-given", scope: "agent:tour:app"}
                    }}

    assert JSON.decode!(facts.resp_body)["result"] == %{"exists" => false, "fact" => nil}

    list_opts =
      with_handler(ctx.opts, "inspect", fn _call ->
        %{sessions: [%{session_key: "agent:tour:app", created_at: 123}]}
      end)

    list =
      dispatch_cli(%{ctx | opts: list_opts}, "tbc_test", %{
        verb: "inspect",
        asUser: "flynn"
      })

    assert %{"createdAt" => 123} =
             JSON.decode!(list.resp_body)["result"]["sessions"] |> List.first()

    refute JSON.decode!(list.resp_body)["result"]["sessions"]
           |> List.first()
           |> Map.has_key?("created_at")
  end

  test "artifact verbs are agent verbs and recording binds the authenticated session caller",
       ctx do
    session = create_session(ctx.db, "artifact-writer", "flynn")
    Roles.create!(ctx.db, "artifact-writer", "flynn", session.session_key)

    recorded =
      dispatch_cli(ctx, session.cli_token, %{
        verb: "artifact-record",
        params: %{kind: "spec", title: "Design", originPath: "spec.md"}
      })

    assert recorded.status == 200

    assert_receive {:call,
                    %{
                      verb: "artifact-record",
                      principal: {:session, "artifact-writer"},
                      session_key: "artifact-writer",
                      params: %{kind: "spec", title: "Design", origin_path: "spec.md"}
                    }}

    assert JSON.decode!(recorded.resp_body)["result"]["createdBySession"] == "artifact-writer"

    for {verb, params} <- [
          {"artifact-get", %{artifactId: "art_12345678"}},
          {"artifacts", %{workItemId: "wi_1", sessionKey: "artifact-writer", kind: "spec"}}
        ] do
      response =
        dispatch_cli(ctx, "tbc_test", %{verb: verb, asUser: "flynn", params: params})

      assert response.status == 200
      assert_receive {:call, %{verb: ^verb}}
    end

    missing =
      dispatch_cli(ctx, "tbc_test", %{
        verb: "artifact-get",
        asUser: "flynn",
        params: %{artifactId: "missing", returnCode: "not_found"}
      })

    assert missing.status == 404
    assert JSON.decode!(missing.resp_body)["error"]["code"] == "not_found"
  end

  test "session bearer enforces the identity ladder and threads the normative principal seam",
       ctx do
    holder = create_session(ctx.db, "holder-token", "flynn")
    sibling = create_session(ctx.db, "sibling-token", "mike")
    main = create_session(ctx.db, "main-token", "flynn", is_built_in: true, kind: "main")
    roleless = create_session(ctx.db, "roleless-token", "flynn")
    several = create_session(ctx.db, "several-token", "flynn")

    Roles.create!(ctx.db, "held", "flynn", holder.session_key)
    Roles.create!(ctx.db, "sibling", "mike", sibling.session_key)
    Roles.create!(ctx.db, "fallback", "mike", nil)
    Roles.create!(ctx.db, "alpha", "flynn", several.session_key)
    Roles.create!(ctx.db, "beta", "flynn", several.session_key)

    assert dispatch_cli(ctx, holder.cli_token, %{verb: "inspect", as: "held"}).status == 200

    assert_receive {:call,
                    %{
                      origin: "agent:held",
                      principal: {:session, "holder-token"},
                      transport_session_key: "holder-token"
                    }}

    assert dispatch_cli(ctx, holder.cli_token, %{verb: "inspect"}).status == 200
    assert_receive {:call, %{origin: "agent:held", principal: {:session, "holder-token"}}}

    assert dispatch_cli(ctx, holder.cli_token, %{verb: "inspect", asUser: "flynn"}).status == 200

    assert_receive {:call,
                    %{
                      origin: "user:flynn",
                      principal: {:user, "flynn"},
                      transport_session_key: "holder-token"
                    }}

    # Registering a satellite also provisions its operator endpoint over ssh; this
    # test is about the identity ladder, so the reach is stubbed and the gateway
    # is given the advertised url a real satellite registration requires.
    old_url = Application.get_env(:tightbeam, :advertised_url)
    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:11373")

    on_exit(fn ->
      if old_url,
        do: Application.put_env(:tightbeam, :advertised_url, old_url),
        else: Application.delete_env(:tightbeam, :advertised_url)
    end)

    credential_supervisor =
      start_supervised!(%{
        id: :router_credential_supervisor,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]}
      })

    register_host =
      Gateway.handlers(%{
        db: ctx.db,
        base_dir: ctx.base_dir,
        default_harness: :claude,
        default_model: Model.new("fable"),
        max_live_sessions_per_user: 50,
        onboarding_lease_ms: 1_800_000,
        credential_supervisor: credential_supervisor,
        sh: fn _command -> {"", 0} end
      })["register-host"]

    File.mkdir_p!(ctx.base_dir)

    File.write!(
      Path.join(ctx.base_dir, "gateway.json"),
      JSON.encode!(%{port: 11_373, cliToken: "tbc_router_org"})
    )

    admin_ctx = %{
      ctx
      | opts: Keyword.update!(ctx.opts, :handlers, &Map.put(&1, "register-host", register_host))
    }

    admin =
      dispatch_cli(admin_ctx, holder.cli_token, %{
        verb: "register-host",
        asUser: "flynn",
        params: %{
          name: "worker",
          ssh: "worker",
          baseDir: "/srv/tightbeam",
          cliBin: "/srv/tightbeam/bin",
          adapterBinDir: "/srv/tightbeam/adapters"
        }
      })

    assert admin.status == 200, admin.resp_body

    assert Enum.any?(Supervisor.which_children(credential_supervisor), fn
             {{Credentials, "worker"}, _pid, :worker, [Credentials]} -> true
             _child -> false
           end)

    refute Enum.any?(Supervisor.which_children(Tightbeam.Supervisor), fn
             {{Credentials, "worker"}, _pid, :worker, [Credentials]} -> true
             _child -> false
           end)

    assert dispatch_cli(ctx, main.cli_token, %{verb: "inspect"}).status == 200
    assert_receive {:call, %{origin: "user:flynn", principal: {:session, "main-token"}}}

    Roles.create!(ctx.db, "main-role", "flynn", main.session_key)
    assert dispatch_cli(ctx, main.cli_token, %{verb: "inspect"}).status == 200
    assert_receive {:call, %{origin: "agent:main-role", principal: {:session, "main-token"}}}

    assert dispatch_cli(ctx, "tbc_test", %{verb: "inspect", asUser: "flynn"}).status == 200

    assert_receive {:call,
                    %{
                      origin: "user:flynn",
                      principal: {:user, "flynn"},
                      transport_session_key: nil
                    }}

    assert dispatch_cli(ctx, "tbc_test", %{verb: "inspect", asProcess: "cron"}).status == 200
    assert_receive {:call, %{origin: "process:cron", principal: {:process, "cron"}}}

    assert dispatch_cli(ctx, "tbc_test", %{verb: "inspect", as: "held"}).status == 200
    assert_receive {:call, %{origin: "agent:held", principal: nil}}

    for role <- ["sibling", "fallback", "missing"] do
      response = dispatch_cli(ctx, holder.cli_token, %{verb: "inspect", as: role})
      assert response.status == 403
      error = JSON.decode!(response.resp_body)["error"]
      assert error["code"] == "role_not_held"
      assert error["message"] =~ role
      assert error["message"] =~ "held"
    end

    wrong_user =
      dispatch_cli(ctx, holder.cli_token, %{verb: "inspect", asUser: "mike"})

    assert wrong_user.status == 403

    assert JSON.decode!(wrong_user.resp_body)["error"] == %{
             "code" => "identity_not_yours",
             "message" => "this session belongs to flynn"
           }

    process = dispatch_cli(ctx, holder.cli_token, %{verb: "inspect", asProcess: "cron"})
    assert process.status == 403
    assert JSON.decode!(process.resp_body)["error"]["code"] == "identity_not_yours"

    {:ok, [[before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM events")
    no_role = dispatch_cli(ctx, roleless.cli_token, %{verb: "inspect"})
    assert no_role.status == 403
    assert JSON.decode!(no_role.resp_body)["error"]["code"] == "no_role"
    {:ok, [[after_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM events")
    assert after_count == before_count

    ambiguous = dispatch_cli(ctx, several.cli_token, %{verb: "inspect"})
    assert ambiguous.status == 400
    assert JSON.decode!(ambiguous.resp_body)["error"]["code"] == "ambiguous_identity"
    assert ambiguous.resp_body =~ "alpha"
    assert ambiguous.resp_body =~ "beta"

    assert dispatch_cli(ctx, "tbs_unknown", %{verb: "inspect"}).status == 401
    Org.retire(ctx.db, holder.session_key, "user:flynn", 1_000)
    assert dispatch_cli(ctx, holder.cli_token, %{verb: "inspect"}).status == 401

    {:ok, principals} =
      DB.query(ctx.db, "SELECT principal FROM events ORDER BY id")

    assert ["session:holder-token"] in principals
    assert ["session:main-token"] in principals
    assert ["user:flynn"] in principals
    assert ["process:cron"] in principals
    assert [nil] in principals

    refute Enum.any?(principals, fn [value] ->
             is_binary(value) and String.contains?(value, "tbs_")
           end)
  end

  test "multipart upload returns asset metadata", ctx do
    response =
      ctx
      |> upload_conn(ctx.device, "hello-bytes", "pic.png", "image/png")
      |> Router.call(Router.init(ctx.opts))

    assert response.status == 200
    body = JSON.decode!(response.resp_body)
    assert body["assetId"] =~ ~r/^a_/
    assert body["mimeType"] == "image/png"
    assert body["size"] == 11
  end

  test "upload rejects files over 32 MiB", ctx do
    response =
      ctx
      |> upload_conn(
        ctx.device,
        :binary.copy(<<0>>, 32 * 1024 * 1024 + 1),
        "large.bin",
        "application/octet-stream"
      )
      |> Router.call(Router.init(ctx.opts))

    assert response.status == 413
    assert JSON.decode!(response.resp_body) == %{"error" => %{"code" => "payload_too_large"}}
  end

  test "upload rejects a missing file field", ctx do
    request =
      conn(:post, "/upload", %{"other" => "value"})
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")

    response = Router.call(request, Router.init(ctx.opts))
    assert response.status == 400

    assert JSON.decode!(response.resp_body) == %{
             "error" => %{
               "code" => "invalid_message",
               "message" => "multipart field 'file' required"
             }
           }
  end

  test "download is owner-scoped with admin override", ctx do
    other = approved_device(ctx.db, "d2", "Other")
    stranger = approved_device(ctx.db, "d3", "Stranger")

    upload =
      ctx
      |> upload_conn(other, "private-bytes", "private.txt", "text/plain")
      |> Router.call(Router.init(ctx.opts))

    asset_id = JSON.decode!(upload.resp_body)["assetId"]

    owner = download(ctx, other, asset_id)
    assert owner.status == 200
    assert get_resp_header(owner, "content-type") == ["text/plain"]
    assert owner.resp_body == "private-bytes"

    denied = download(ctx, stranger, asset_id)
    assert denied.status == 404
    assert JSON.decode!(denied.resp_body) == %{"error" => %{"code" => "not_found"}}

    admin = download(ctx, ctx.device, asset_id)
    assert admin.status == 200
    assert admin.resp_body == "private-bytes"
  end

  defp upload_conn(ctx, device, data, filename, content_type) do
    path = Path.join(ctx.base_dir, "upload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ctx.base_dir)
    File.write!(path, data)

    upload = %Plug.Upload{path: path, filename: filename, content_type: content_type}

    conn(:post, "/upload", %{"file" => upload})
    |> put_req_header("authorization", "Bearer #{device.token}")
  end

  defp approved_device(db, device_id, name) do
    {:pending, pending} =
      Devices.pair(db, %{device_id: device_id, claimed_name: name, platform: nil, model: nil})

    Devices.approve(db, pending.device_id)
  end

  defp download(ctx, device, asset_id) do
    conn(:get, "/download/#{asset_id}")
    |> put_req_header("authorization", "Bearer #{device.token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp get_device(ctx, device, path) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{device.token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp dispatch_wake(ctx, fields) when is_map(fields) do
    body =
      JSON.encode!(
        Map.merge(
          %{"verb" => "wake", "asUser" => "flynn", "params" => %{"prompt" => "hi"}},
          fields
        )
      )

    conn(:post, "/agent/dispatch", body)
    |> put_req_header("authorization", "Bearer tbc_test")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Router.call(Router.init(ctx.opts))
  end

  defp dispatch_as_role(ctx, role) do
    body =
      JSON.encode!(%{
        "verb" => "inspect",
        "as" => role,
        "params" => %{}
      })

    conn(:post, "/agent/dispatch", body)
    |> put_req_header("authorization", "Bearer tbc_test")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Router.call(Router.init(ctx.opts))
  end

  # Authenticate as the session itself — the path a working agent actually takes
  # when it assigns to a role, and the one the phantom specimens came in on.
  defp dispatch_session(ctx, session, body) do
    dispatch_cli(ctx, session.cli_token, body)
  end

  # The real handler table, each verb announcing its call before it runs. A mock
  # cannot answer "was a row written"; this can, and it still proves "no handler
  # ran" the same way the mocked table does.
  defp observed_real_handlers(ctx) do
    parent = self()

    Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir, wake_tick_ms: 1_000})
    |> Map.new(fn {verb, handler} ->
      {verb,
       fn call ->
         send(parent, {:call, call})
         handler.(call)
       end}
    end)
  end

  defp dispatch_cli(ctx, bearer, body) do
    conn(:post, "/agent/dispatch", JSON.encode!(Map.put_new(body, :params, %{})))
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Router.call(Router.init(ctx.opts))
  end

  defp empty_router(ctx, label) do
    db = :"#{label}_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: db, start: {DB, :start_link, [[path: ":memory:", name: db]]}})
    :ok = Tightbeam.Schema.ensure_all(db)

    opts =
      Keyword.merge(ctx.opts,
        db: db,
        handlers: Gateway.handlers(%{db: db, base_dir: ctx.base_dir})
      )

    {db, opts}
  end

  # INVARIANT: a non-ok session-control response always carries a code.
  #
  # `ok: false` alone was observed in production and could not be reproduced,
  # because it is not a bug in any one handler -- it is what the wire renders for
  # ANY handler result that forgets a code, and `reason:` (which one path did set)
  # is not a key this seam emits, so it was dropped silently. A client receiving it
  # cannot tell a refusal it should surface from a fault it should retry.
  #
  # Asserted through the router rather than against a handler, because the seam is
  # what makes it total: it holds for handlers that do not exist yet.
  test "POST /api/session-control never returns a bare ok:false", ctx do
    key = "control-invariant"
    create_session(ctx.db, key, ctx.device.user_id)

    for result <- [%{ok: false}, %{ok: false, reason: :adapter_said_no}] do
      opts = with_handler(ctx.opts, "tune", fn _call -> result end)

      response =
        conn(
          :post,
          "/api/session-control",
          JSON.encode!(%{"sessionKey" => key, "action" => "set_model", "model" => "fable"})
        )
        |> put_req_header("authorization", "Bearer #{ctx.device.token}")
        |> Router.call(Router.init(opts))

      body = JSON.decode!(response.resp_body)

      assert body["ok"] == false, "#{inspect(result)} -> #{inspect(body)}"

      assert is_binary(body["code"]) and body["code"] != "",
             "a non-ok control response must name a code: #{inspect(result)} -> #{inspect(body)}"
    end
  end

  test "POST /api/session-control renders an unreadable session status as its named refusal",
       ctx do
    key = "control-unreadable-status"
    create_session(ctx.db, key, ctx.device.user_id)
    message = "credential store /broken/auth/claude is unreadable"

    opts =
      ctx.opts
      |> with_handler("tune", fn _call -> %{ok: true} end)
      |> Keyword.put(:session_status, fn ^key ->
        {:error, 503, "credential_store_unreadable", message}
      end)

    response = post_control(opts, ctx.device.token, key, "adopt")

    assert response.status == 503

    assert JSON.decode!(response.resp_body) == %{
             "error" => %{
               "code" => "credential_store_unreadable",
               "message" => message
             }
           }
  end

  test "session-control adopt and unadopt reach tune, and a foreign session is refused", ctx do
    key = "adopt-control"
    create_session(ctx.db, key, ctx.device.user_id)
    opts = with_handler(ctx.opts, "tune", fn call -> send_call(call) end)

    for {action, adopted} <- [{"adopt", true}, {"unadopt", false}] do
      response = post_control(opts, ctx.device.token, key, action)

      assert response.status == 200

      assert %{"ok" => true, "action" => ^action, "sessionKey" => ^key} =
               JSON.decode!(response.resp_body)

      assert_received {:call,
                       %{
                         verb: "tune",
                         origin: origin,
                         session_key: ^key,
                         params: %{setting: "adopt", adopted: ^adopted}
                       }}

      assert origin == "user:#{ctx.device.user_id}"
    end

    # Adoption invents no authorization rule of its own: the seam already refuses
    # a session the caller neither owns nor administers, before dispatch and
    # indistinguishably from one that does not exist (the existence oracle).
    stranger = approved_device(ctx.db, "adopt-stranger", "Stranger")
    response = post_control(opts, stranger.token, key, "adopt")

    assert response.status == 404
    assert %{"error" => %{"code" => "not_found"}} = JSON.decode!(response.resp_body)
    refute_received {:call, %{verb: "tune"}}
  end

  # SPAWN, through the real wire payload. The session-control test below covers
  # the same `model_params/1`, but spawn is where the consequence bites: a
  # configured 1M default plus an explicit `context: null` must select the
  # default window, and a dropped key would inherit `1m` instead. Testing this
  # at the gateway with a hand-built params map bypasses the very seam that
  # was losing the field.
  test "spawn carries an explicitly null context across the wire, not omitted", ctx do
    opts = with_handler(ctx.opts, "spawn", fn call -> send_call(call) end)

    body =
      JSON.encode!(%{
        "displayName" => "Wire Spawn",
        "idempotencyKey" => "k-wire-null-context",
        "model" => "claude-fable-5",
        "context" => nil,
        "effort" => "high"
      })

    response =
      conn(:post, "/api/streams", body)
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status in [200, 201]
    assert_received {:call, %{verb: "spawn", params: params}}

    assert params.model == "claude-fable-5"
    assert params.effort == "high"

    assert Map.has_key?(params, :context),
           "an explicit null must reach spawn as a NAMED field, or the default " <>
             "window is indistinguishable from silence and 1m gets inherited"

    assert params.context == nil

    # And an omitted context still arrives omitted, so inheritance can fire.
    omitted_body =
      JSON.encode!(%{
        "displayName" => "Wire Spawn",
        "idempotencyKey" => "k-wire-omitted-context",
        "model" => "claude-fable-5"
      })

    conn(:post, "/api/streams", omitted_body)
    |> put_req_header("authorization", "Bearer #{ctx.device.token}")
    |> Router.call(Router.init(opts))

    assert_received {:call, %{verb: "spawn", params: omitted}}
    refute Map.has_key?(omitted, :context)
  end

  test "a disappeared placement host reaches HTTP as a named refusal", ctx do
    opts =
      with_handler(ctx.opts, "spawn", fn _call ->
        Placement.workdir_path(
          %{base_dir: ctx.base_dir, db: ctx.db},
          %{session_key: "vanished-session", host: "eurisko", harness: "codex"}
        )
      end)

    response =
      conn(
        :post,
        "/api/streams",
        JSON.encode!(%{
          "displayName" => "Vanished",
          "idempotencyKey" => "vanished-placement"
        })
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 400

    assert JSON.decode!(response.resp_body) == %{
             "error" => %{
               "code" => "unknown_host",
               "message" =>
                 "host eurisko is not configured for codex; run tightbeam assimilate <ssh-dest> --name eurisko --as-user <adminUserId>"
             }
           }
  end

  # THE THIRD DESTRUCTION SITE. JSON can say `null`, and the router dropped it —
  # so "the caller named context and named it empty" arrived downstream
  # indistinguishable from "the caller said nothing about context", which is
  # the exact collapse `named_fields/1` and `put_named/3` exist to prevent.
  # Two seams below carrying the distinction is worth nothing if the seam that
  # faces the outside throws it away first.
  test "an explicitly null model field crosses the wire as named, not omitted", ctx do
    key = "explicit-null-control"
    create_session(ctx.db, key, ctx.device.user_id)
    opts = with_handler(ctx.opts, "tune", fn call -> send_call(call) end)

    response =
      conn(
        :post,
        "/api/session-control",
        JSON.encode!(%{
          "sessionKey" => key,
          "action" => "set_model",
          "model" => "claude-fable-5",
          "context" => nil,
          "effort" => "high"
        })
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 200

    assert_received {:call, %{verb: "tune", params: params}}

    assert params.model == "claude-fable-5"
    assert params.effort == "high"

    assert Map.has_key?(params, :context),
           "an explicit null must arrive as a NAMED field holding nil, not vanish"

    assert params.context == nil

    # …and an omitted field still arrives omitted, or the distinction is only
    # half carried and inheritance downstream can never fire.
    response =
      conn(
        :post,
        "/api/session-control",
        JSON.encode!(%{
          "sessionKey" => key,
          "action" => "set_model",
          "model" => "claude-fable-5"
        })
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 200
    assert_received {:call, %{verb: "tune", params: omitted}}
    refute Map.has_key?(omitted, :context)

    # An empty string is the same statement as null: the field, named, empty.
    response =
      conn(
        :post,
        "/api/session-control",
        JSON.encode!(%{
          "sessionKey" => key,
          "action" => "set_model",
          "model" => "claude-fable-5",
          "context" => ""
        })
      )
      |> put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Router.call(Router.init(opts))

    assert response.status == 200
    assert_received {:call, %{verb: "tune", params: blank}}
    assert Map.has_key?(blank, :context)
    assert blank.context == nil
  end

  defp post_control(opts, token, session_key, action) do
    conn(
      :post,
      "/api/session-control",
      JSON.encode!(%{"sessionKey" => session_key, "action" => action})
    )
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(Router.init(opts))
  end

  defp with_handler(opts, verb, handler) do
    Keyword.update!(opts, :handlers, &Map.put(&1, verb, handler))
  end

  defp send_call(call) do
    send(self(), {:call, call})
    %{}
  end

  defp create_session(db, key, owner, extra \\ []) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      is_built_in: Keyword.get(extra, :is_built_in, false),
      kind: Keyword.get(extra, :kind, "custom")
    })
  end
end
