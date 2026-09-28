defmodule Tightbeam.RequestObservationTest do
  use Tightbeam.TestCase, async: false
  import Plug.Conn
  import Plug.Test
  alias Tightbeam.{DB, Diagnostics, Org, RequestContext, Schema}
  alias Tightbeam.Wire.{OperationRegistry, Router}

  setup do
    start_supervised!({Diagnostics, notify: self()})
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    %{db: db, opts: Router.init(db: db, cli_token: "private_org_token", handlers: %{})}
  end

  test "finite rows cover exactly current .9 routes, including terminal and work-items" do
    assert {:ok, routes} = OperationRegistry.router_routes()
    assert :ok = OperationRegistry.check_source(:http, routes)
    assert {:ok, rows} = OperationRegistry.rows(:http)
    assert length(rows) == 45
    assert OperationRegistry.http("POST", "/agent/terminal") == "http.agent_terminal"
    assert OperationRegistry.http("GET", "/api/work-items/:id") == "http.api_work_items.get"

    assert OperationRegistry.http("GET", "/api/sessions/:session_key/messages") ==
             "http.api_sessions.messages.list"

    assert OperationRegistry.http("GET", "/api/sessions/:session_key/turns") ==
             "http.api_sessions.turns.list"

    assert OperationRegistry.http("GET", "/api/sessions/:session_key/wakes") ==
             "http.api_sessions.wakes.list"

    assert {:error, [{:unmapped_source, {"GET", "/new"}}]} =
             OperationRegistry.check(rows, [{"GET", "/new"} | routes])

    assert {:error, [{:orphan_row, {"GET", "/stale"}}]} =
             OperationRegistry.check([{{"GET", "/stale"}, "http.stale"} | rows], routes)
  end

  test "malformed and repeated IDs refuse before authentication and restore prior context", %{
    opts: opts,
    db: db
  } do
    :sys.suspend(db)

    outer = %{
      request_id: RequestContext.id("int_"),
      principal_kind: "internal",
      principal_ref: "internal:test"
    }

    try do
      RequestContext.bind(outer, fn ->
        for headers <- [
              [{"x-tightbeam-request-id", "bad_secret"}],
              [
                {"x-tightbeam-request-id", RequestContext.id("req_")},
                {"x-tightbeam-request-id", RequestContext.id("req_")}
              ]
            ] do
          request = conn(:post, "/agent/dispatch", "{}")

          request = %{
            request
            | req_headers: [{"authorization", "Bearer private_session_token"} | headers]
          }

          response = Router.call(request, opts)
          assert response.status == 400

          assert %{"error" => %{"code" => "invalid_request_id"}} =
                   JSON.decode!(response.resp_body)

          assert [id] = get_resp_header(response, "x-tightbeam-request-id")
          assert id =~ ~r/\Areq_[A-Za-z0-9_-]{22}\z/
          refute response.resp_body =~ "bad_secret"
          assert RequestContext.capture() == outer
        end

        {:messages, messages} = Process.info(db, :messages)
        refute Enum.any?(messages, &match?({:"$gen_call", _, _}, &1))
      end)
    after
      :sys.resume(db)
    end
  end

  test "real HTTP authentication timeout is a safe correlated 503", %{opts: opts, db: db} do
    previous = Application.fetch_env(:tightbeam, :db_call_timeout_ms)
    Application.put_env(:tightbeam, :db_call_timeout_ms, 50)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tightbeam, :db_call_timeout_ms, value)
        :error -> Application.delete_env(:tightbeam, :db_call_timeout_ms)
      end
    end)

    bandit =
      start_supervised!(
        {Bandit, plug: {Router, opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)
    :sys.suspend(db)
    id = RequestContext.id("req_")

    try do
      {:ok, {{_, status, _}, headers, body}} =
        :httpc.request(
          :get,
          {String.to_charlist("http://127.0.0.1:#{port}/api/work-items"),
           [
             {~c"authorization", ~c"Bearer private_http_token"},
             {~c"x-tightbeam-request-id", String.to_charlist(id)}
           ]},
          [timeout: 5_000],
          body_format: :binary
        )

      assert status == 503
      assert {~c"x-tightbeam-request-id", String.to_charlist(id)} in headers
      assert %{"error" => error} = JSON.decode!(body)
      assert error["requestId"] == id
      assert error["operation"] == "auth.session_by_cli_token"
      assert error["code"] == "db_timeout"
      assert error["action"] == "retry_safe"
      assert error["effectState"] == "none"
      assert error["budgetMs"] == 50
      assert error["gatewayAccepted"] == true
      refute body =~ "private_http_token"

      assert_receive {:diagnostic,
                      %{event: "http_response_terminal", request_id: ^id} = terminal},
                     1_000

      assert terminal.operation == "http.api_work_items.list"
      assert terminal.response_state == "complete"
      assert terminal.principal_kind == "unknown"
      refute_receive {:diagnostic, %{event: "http_response_terminal", request_id: ^id}}, 20
      refute inspect(Diagnostics.records()) =~ "private_http_token"
    after
      :sys.resume(db)
    end
  end

  test "real core and d1 state reads carry resolved session then authorized user", %{
    opts: opts,
    db: db
  } do
    session =
      Org.create(db, %{
        session_key: "diagnostic_session",
        display_name: "diagnostic_session",
        owner_user_id: "diagnostic_owner",
        origin: "user:diagnostic_owner",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Tightbeam.Model.new("fable"),
        kind: "custom"
      })

    for {path, status} <- [{"/api/sessions/absent", 404}, {"/api/work-items", 200}],
        {query, principal} <- [
          {"", "session:diagnostic_session"},
          {"?asUser=diagnostic_owner", "user:diagnostic_owner"}
        ] do
      id = RequestContext.id("req_")

      response =
        conn(:get, path <> query)
        |> put_req_header("authorization", "Bearer " <> session.cli_token)
        |> put_req_header("x-tightbeam-request-id", id)
        |> Router.call(opts)

      assert response.status == status, "#{path}#{query}: #{response.resp_body}"
      assert_receive {:diagnostic, %{event: "http_response_terminal", request_id: ^id} = terminal}
      assert terminal.principal_ref == principal

      records =
        Diagnostics.records()
        |> Enum.filter(&(&1[:request_id] == id and &1.event == "db_server_completed"))

      assert [%{principal_kind: "unknown", operation: "auth.session_by_cli_token"} | later] =
               records

      assert Enum.any?(later, &(&1.principal_ref == principal))
    end

    refute inspect(Diagnostics.records()) =~ session.cli_token
  end

  test "only a validated existing keyed assignment contract marks retry advice", %{db: db} do
    context = %{
      request_id: RequestContext.id("req_"),
      principal_kind: "unknown",
      principal_ref: nil
    }

    call = %{
      verb: "assign",
      principal: {:user, "owner"},
      params: %{
        subject: "test",
        idempotency_key: "existing-key",
        effect_kind: "code",
        files: ["lib/test.ex"]
      }
    }

    RequestContext.bind(context, fn ->
      assert :proceed = Tightbeam.Assignments.dispatch_precheck(db, call)
      assert RequestContext.idempotent?()
    end)

    RequestContext.bind(context, fn ->
      assert {:refuse, _} =
               Tightbeam.Assignments.dispatch_precheck(
                 db,
                 put_in(call.params.idempotency_key, " ")
               )

      refute RequestContext.idempotent?()
    end)

    refute RequestContext.idempotent?()
  end

  test "a real dispatched write timeout reaches the router without claiming retry safety", %{
    db: db,
    opts: opts
  } do
    previous = Application.fetch_env(:tightbeam, :db_call_timeout_ms)
    Application.put_env(:tightbeam, :db_call_timeout_ms, 50)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tightbeam, :db_call_timeout_ms, value)
        :error -> Application.delete_env(:tightbeam, :db_call_timeout_ms)
      end
    end)

    handler = fn _call ->
      refute RequestContext.idempotent?()
      :sys.suspend(db)
      DB.transaction(db, fn _txn -> :ok end)
    end

    opts = Keyword.put(opts, :handlers, %{"inspect" => handler})
    id = RequestContext.id("req_")

    try do
      response =
        conn(
          :post,
          "/agent/dispatch",
          JSON.encode!(%{
            verb: "inspect",
            asUser: "owner",
            params: %{idempotencyKey: "unsupported-key"}
          })
        )
        |> put_req_header("authorization", "Bearer private_org_token")
        |> put_req_header(
          "x-tightbeam-cli-version",
          Tightbeam.CliCompatibility.required_version()
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-tightbeam-request-id", id)
        |> Router.call(opts)

      assert response.status == 503, response.resp_body
      error = JSON.decode!(response.resp_body)["error"]
      assert error["requestId"] == id
      assert error["action"] == "do_not_retry_report"
      assert error["effectState"] == "unknown"
      assert_receive {:diagnostic, %{event: "http_response_terminal", request_id: ^id} = terminal}
      assert terminal.principal_ref == "user:owner"
      assert terminal.operation == "http.agent_dispatch"
    after
      :sys.resume(db)
    end
  end
end
