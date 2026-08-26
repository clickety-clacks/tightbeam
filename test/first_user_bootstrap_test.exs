defmodule Tightbeam.FirstUserBootstrapTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{DB, Devices, Gateway, Model, Org, Rules}
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  @approval_required %{
    "error" => %{
      "code" => "approval_required",
      "message" => "an existing admin must approve user creation"
    }
  }

  setup do
    start_supervised!({Hub, name: Hub})
    :ok = Hub.register(Hub, self())

    on_exit(fn ->
      Rules.load!(Path.join(System.tmp_dir!(), "missing-first-user-bootstrap-reset"), [])
    end)

    :ok
  end

  test "absent, malformed, unknown, and valid bearers all admit a bare first-user candidate" do
    cases = [
      {:absent, nil},
      {:malformed, "Basic malformed-bearer-sentinel"},
      {:unknown, "Bearer unknown-bearer-sentinel"},
      {:valid, "Bearer tbc_first_user_test"}
    ]

    for {label, authorization} <- cases do
      env = environment(label)
      response = dispatch(env, add_user_body("user-#{label}"), authorization: authorization)

      assert response.status == 200
      body = JSON.decode!(response.resp_body)
      assert get_in(body, ["result", "user", "userId"]) == "user-#{label}"
      assert get_in(body, ["result", "user", "isAdmin"]) == true

      assert {:ok,
              [["verb", "add-user", "bootstrap:first-user", "bootstrap:first-user", nil, payload]]} =
               DB.query(
                 env.db,
                 "SELECT kind,verb,origin,principal,sessionKey,payload FROM events"
               )

      assert payload =~ ~s(user_id: "user-#{label}")
      assert {:ok, [[0]]} = DB.query(env.db, "SELECT COUNT(*) FROM devices")
      assert {:ok, [[0]]} = DB.query(env.db, "SELECT COUNT(*) FROM sessions")
      assert {:ok, [[0]]} = DB.query(env.db, "SELECT COUNT(*) FROM roles")
      notices = accepted_notices()
      assert Enum.map(notices, & &1["class"]) == ["verb.accepted", "user.added"]

      serialized = JSON.encode!(%{response: body, payload: payload, notices: notices})

      for sentinel <- [
            "malformed-bearer-sentinel",
            "unknown-bearer-sentinel",
            "tbc_first_user_test"
          ] do
        refute serialized =~ sentinel
      end
    end
  end

  test "the first user is forced admin for omitted, false, and true isAdmin" do
    for {label, params} <- [
          {:omitted, %{"userId" => "user-omitted"}},
          {false, %{"userId" => "user-false", "isAdmin" => false}},
          {true, %{"userId" => "user-true", "isAdmin" => true}}
        ] do
      env = environment(label)
      response = dispatch(env, %{"verb" => "add-user", "params" => params})

      assert response.status == 200
      assert JSON.decode!(response.resp_body)["result"]["user"]["isAdmin"] == true
      assert Devices.user(env.db, params["userId"]).is_admin
      _ = accepted_notices()
    end
  end

  test "a retry after commit gets the exact closed response and a denied bootstrap event" do
    env = environment(:closed_retry)
    first = dispatch(env, add_user_body("first"))
    assert first.status == 200
    _ = accepted_notices()

    retry = dispatch(env, add_user_body("first"), authorization: "Bearer retry-secret")
    assert retry.status == 403
    assert JSON.decode!(retry.resp_body) == @approval_required

    assert {:ok, [[1]]} = DB.query(env.db, "SELECT COUNT(*) FROM users")

    assert {:ok, [["verb", accepted], ["denied", denied]]} =
             DB.query(env.db, "SELECT kind,payload FROM events ORDER BY id")

    assert accepted =~ ~s(user_id: "first")
    assert denied =~ ~s(code: "approval_required")
    assert denied =~ "an existing admin must approve user creation"

    assert notice = denied_notice()

    assert notice["refs"] == %{
             "origin" => "bootstrap:first-user",
             "principal" => "bootstrap:first-user"
           }

    refute JSON.encode!(%{response: retry.resp_body, event: denied, notice: notice}) =~
             "retry-secret"
  end

  test "each explicit identity selector without a valid bearer stays on ordinary auth" do
    for {label, selector} <- [
          {:role, %{"as" => "candidate"}},
          {:user, %{"asUser" => "candidate"}},
          {:process, %{"asProcess" => "candidate"}}
        ] do
      env = environment(label)
      response = dispatch(env, Map.merge(add_user_body("candidate"), selector))

      assert response.status == 401
      assert JSON.decode!(response.resp_body) == %{"error" => %{"code" => "auth_failed"}}
      assert_no_domain_writes(env.db)
    end
  end

  test "nonexistent user actors fail after auth and ownership but before dispatch" do
    env = environment(:missing_actor)

    org_response =
      dispatch(env, Map.put(add_user_body("candidate"), "asUser", "missing-user"),
        authorization: "Bearer tbc_first_user_test"
      )

    assert org_response.status == 403

    assert JSON.decode!(org_response.resp_body) == %{
             "error" => %{
               "code" => "invalid_identity",
               "message" => "asserted user does not exist"
             }
           }

    built_in =
      Org.create(env.db, %{
        session_key: "missing-owner-main",
        display_name: "Main",
        kind: "main",
        is_built_in: true,
        owner_user_id: "alice",
        origin: "user:alice",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    wrong_owner =
      dispatch(env, %{"verb" => "inspect", "asUser" => "bob", "params" => %{}},
        authorization: "Bearer #{built_in.cli_token}"
      )

    assert wrong_owner.status == 403
    assert JSON.decode!(wrong_owner.resp_body)["error"]["code"] == "identity_not_yours"

    for body <- [
          %{"verb" => "inspect", "asUser" => "alice", "params" => %{}},
          %{"verb" => "inspect", "params" => %{}}
        ] do
      response = dispatch(env, body, authorization: "Bearer #{built_in.cli_token}")
      assert response.status == 403

      assert JSON.decode!(response.resp_body) == %{
               "error" => %{
                 "code" => "invalid_identity",
                 "message" => "asserted user does not exist"
               }
             }
    end

    assert_no_domain_writes(env.db)
    refute_receive {:firehose_notice, _}
  end

  test "existing admins retain ordinary add-user behavior and non-admins remain forbidden" do
    env = environment(:ordinary)
    assert dispatch(env, add_user_body("admin")).status == 200
    _ = accepted_notices()

    ordinary =
      dispatch(
        env,
        %{
          "verb" => "add-user",
          "asUser" => "admin",
          "params" => %{"userId" => "member", "isAdmin" => false}
        },
        authorization: "Bearer tbc_first_user_test"
      )

    assert ordinary.status == 200
    refute Devices.user(env.db, "member").is_admin
    _ = accepted_notices()

    refused =
      dispatch(
        env,
        %{
          "verb" => "add-user",
          "asUser" => "member",
          "params" => %{"userId" => "forbidden", "isAdmin" => true}
        },
        authorization: "Bearer tbc_first_user_test"
      )

    assert refused.status == 403

    assert JSON.decode!(refused.resp_body) == %{
             "error" => %{"code" => "forbidden", "message" => "admin required"}
           }

    assert Devices.user(env.db, "forbidden") == nil

    assert {:ok, [["user:admin", "user:admin"]]} =
             DB.query(
               env.db,
               "SELECT origin,principal FROM events WHERE verb = 'add-user' AND kind = 'verb' ORDER BY id DESC LIMIT 1"
             )
  end

  test "different-id and same-id bootstrap races each have one winner and one state denial" do
    for {label, ids} <- [different_ids: ["alpha", "beta"], same_id: ["same", "same"]] do
      env = environment(label)
      [left, right] = concurrent_dispatches(env, ids)
      responses = [Task.await(left), Task.await(right)]

      assert Enum.sort(Enum.map(responses, & &1.status)) == [200, 403]
      winner = Enum.find(responses, &(&1.status == 200))
      loser = Enum.find(responses, &(&1.status == 403))
      assert JSON.decode!(loser.resp_body) == @approval_required

      winner_id = JSON.decode!(winner.resp_body)["result"]["user"]["userId"]
      assert {:ok, [[^winner_id, 1]]} = DB.query(env.db, "SELECT userId,isAdmin FROM users")

      assert {:ok, [["verb", "bootstrap:first-user"], ["denied", "bootstrap:first-user"]]} =
               DB.query(env.db, "SELECT kind,principal FROM events ORDER BY id")
    end
  end

  test "a concurrent pair can never create the first user" do
    env = environment(:pair_race)
    parent = self()

    pair =
      Task.async(fn ->
        send(parent, {:pair_race_ready, self()})

        receive do
          :race ->
            Devices.pair(env.db, %{
              device_id: "racing-device",
              claimed_name: "Pair User",
              platform: nil,
              model: nil
            })
        end
      end)

    rest =
      Task.async(fn ->
        send(parent, {:pair_race_ready, self()})

        receive do
          :race -> dispatch(env, add_user_body("rest-user"))
        end
      end)

    pids =
      for _ <- 1..2 do
        assert_receive {:pair_race_ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :race))

    pair_result = Task.await(pair)
    response = Task.await(rest)
    assert response.status == 200
    assert Devices.user(env.db, "rest-user").is_admin
    assert pair_result == :first_user_required or match?({:pending, _}, pair_result)

    case pair_result do
      :first_user_required ->
        assert Devices.by_id(env.db, "racing-device") == nil
        assert Devices.user(env.db, "pair-user") == nil

      {:pending, device} ->
        assert device.user_id == "pair-user"
        refute Devices.user(env.db, "pair-user").is_admin
    end

    assert {:ok, [[1]]} = DB.query(env.db, "SELECT COUNT(*) FROM events WHERE kind = 'verb'")
  end

  test "structural failures happen before a first-user transaction" do
    cases = [
      {:malformed_json, "{", []},
      {:malformed_user, %{"verb" => "add-user", "params" => %{"userId" => ""}}, []},
      {:typed_target, Map.put(add_user_body("typed"), "sessionKey", "target"), []},
      {:bad_version, add_user_body("version"), [version: "0.0.0"]}
    ]

    for {label, body, opts} <- cases do
      env = environment(label)
      response = dispatch(env, body, opts)
      assert response.status in [400, 426]
      assert_no_domain_writes(env.db)
    end
  end

  test "failure before the accepted event rolls back the user and staged user notice" do
    env = environment(:event_failure)

    :ok =
      DB.execute(env.db, """
      CREATE TRIGGER fail_bootstrap_event
      BEFORE INSERT ON events
      WHEN NEW.kind = 'verb'
       AND NEW.origin = 'bootstrap:first-user'
       AND NEW.payload LIKE '%user:%'
      BEGIN
        SELECT RAISE(ABORT, 'injected accepted-event failure');
      END;
      """)

    response = dispatch(env, add_user_body("retryable"))
    assert response.status == 500
    assert Devices.user(env.db, "retryable") == nil

    assert {:ok, [["verb", payload]]} = DB.query(env.db, "SELECT kind,payload FROM events")
    assert payload =~ ~s(code: "server_error")
    assert denied_notice()["class"] == "verb.denied"
    refute_receive {:firehose_notice, %{"class" => "user.added"}}

    :ok = DB.execute(env.db, "DROP TRIGGER fail_bootstrap_event")
    assert dispatch(env, add_user_body("retryable")).status == 200
    assert Devices.user(env.db, "retryable").is_admin
  end

  test "a deferred commit failure discards the user, accepted event, and user notice handoff" do
    env = environment(:commit_failure)

    :ok =
      DB.execute(env.db, """
      CREATE TABLE bootstrap_fault_parents (id INTEGER PRIMARY KEY);
      CREATE TABLE bootstrap_fault_children (
        userId TEXT NOT NULL,
        parentId INTEGER NOT NULL,
        FOREIGN KEY(parentId) REFERENCES bootstrap_fault_parents(id)
          DEFERRABLE INITIALLY DEFERRED
      );
      CREATE TRIGGER fail_bootstrap_commit
      AFTER INSERT ON users
      BEGIN
        INSERT INTO bootstrap_fault_children (userId, parentId) VALUES (NEW.userId, 1);
      END;
      """)

    response = dispatch(env, add_user_body("commit-failure"))
    assert response.status == 500
    assert Devices.user(env.db, "commit-failure") == nil

    assert {:ok, [["verb", payload]]} = DB.query(env.db, "SELECT kind,payload FROM events")
    assert payload =~ ~s(code: "server_error")
    assert denied_notice()["class"] == "verb.denied"
    refute_receive {:firehose_notice, %{"class" => "user.added"}}
  end

  test "a lost post-commit notice does not weaken the durable close" do
    env = environment(:lost_handoff)
    :ok = stop_supervised(Hub)

    first = dispatch(env, add_user_body("durable"))
    assert first.status == 200
    assert Devices.user(env.db, "durable").is_admin
    assert {:ok, [["verb"]]} = DB.query(env.db, "SELECT kind FROM events")

    start_supervised!({Hub, name: Hub})
    :ok = Hub.register(Hub, self())

    retry = dispatch(env, add_user_body("durable"))
    assert retry.status == 403
    assert JSON.decode!(retry.resp_body) == @approval_required
    assert {:ok, [[1]]} = DB.query(env.db, "SELECT COUNT(*) FROM users")
    assert {:ok, [[1]]} = DB.query(env.db, "SELECT COUNT(*) FROM events WHERE kind = 'verb'")
    assert {:ok, [[1]]} = DB.query(env.db, "SELECT COUNT(*) FROM events WHERE kind = 'denied'")
    assert denied_notice()["class"] == "verb.denied"
  end

  defp environment(label) do
    suffix = System.unique_integer([:positive])
    db = String.to_atom("first_user_#{label}_#{suffix}")

    start_supervised!(%{
      id: db,
      start: {DB, :start_link, [[path: ":memory:", name: db]]}
    })

    :ok = Tightbeam.Schema.ensure_all(db)
    base_dir = Path.join(System.tmp_dir!(), "first-user-bootstrap-#{suffix}")
    handlers = Gateway.handlers(%{db: db, base_dir: base_dir, wake_tick_ms: 1_000})
    Rules.load!(Path.join(base_dir, "no-rules"), Map.keys(handlers))

    %{
      db: db,
      opts: [
        db: db,
        base_dir: base_dir,
        handlers: handlers,
        cli_token: "tbc_first_user_test",
        session_status: fn _ -> nil end
      ]
    }
  end

  defp add_user_body(user_id) do
    %{"verb" => "add-user", "params" => %{"userId" => user_id}}
  end

  defp dispatch(env, body, opts \\ []) do
    bytes = if is_binary(body), do: body, else: JSON.encode!(body)

    request =
      conn(:post, "/agent/dispatch", bytes)
      |> put_req_header(
        "x-tightbeam-cli-version",
        Keyword.get(opts, :version, Tightbeam.CliCompatibility.required_version())
      )

    request =
      case Keyword.get(opts, :authorization) do
        nil -> request
        value -> put_req_header(request, "authorization", value)
      end

    Router.call(request, Router.init(env.opts))
  end

  defp accepted_notices do
    first = next_notice()
    second = next_notice()
    [first, second]
  end

  defp denied_notice do
    notice = next_notice()
    assert notice["class"] == "verb.denied"
    notice
  end

  defp next_notice do
    assert_receive {:firehose_notice, notice}
    Hub.delivered(Hub, self())
    _ = Hub.sequence(Hub, self())
    notice
  end

  defp assert_no_domain_writes(db) do
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM users")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM devices")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM events")
  end

  defp concurrent_dispatches(env, [left_id, right_id]) do
    parent = self()

    tasks =
      for id <- [left_id, right_id] do
        Task.async(fn ->
          send(parent, {:bootstrap_ready, self()})

          receive do
            :dispatch -> dispatch(env, add_user_body(id))
          end
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:bootstrap_ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :dispatch))
    tasks
  end
end
