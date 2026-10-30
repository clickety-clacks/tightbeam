defmodule Tightbeam.Wire.WakeSenderAttributionTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{Archetypes, DB, Gateway, Model, Org, Rules, Schema}
  alias Tightbeam.Wire.Router

  setup do
    db = :"wake_sender_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('owner', 0, 1)")

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-wake-sender-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base_dir) end)
    Archetypes.load!(base_dir)

    handlers = Gateway.handlers(%{db: db, base_dir: base_dir, wake_tick_ms: 1_000})
    Rules.load!(System.tmp_dir!(), Map.keys(handlers))

    %{db: db, opts: [db: db, base_dir: base_dir, handlers: handlers, cli_token: "test_org"]}
  end

  test "persisted wakes keep the authenticated session or explicit user and process sender",
       ctx do
    sender = create_session(ctx.db, "roleless-sender")
    target = create_session(ctx.db, "wake-target")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM roles WHERE boundSessionKey=?1", [
               sender.session_key
             ])

    cases = [
      {sender.cli_token, %{}, "agent:roleless-sender", "roleless-sender",
       "session:roleless-sender"},
      {"test_org", %{asUser: "owner"}, "user:owner", nil, "user:owner"},
      {"test_org", %{asProcess: "automation"}, "process:automation", nil, "process:automation"}
    ]

    for {bearer, selector, origin, creator, principal} <- cases do
      body =
        %{verb: "wake", sessionKey: target.session_key, params: %{prompt: "sender proof"}}
        |> Map.merge(selector)

      response = dispatch(ctx, bearer, body)
      assert response.status == 200, response.resp_body
      wake_id = JSON.decode!(response.resp_body)["result"]["wakeId"]

      assert {:ok, [[^origin, ^creator]]} =
               DB.query(ctx.db, "SELECT origin, creatorSessionKey FROM wakes WHERE wakeId=?1", [
                 wake_id
               ])

      assert {:ok, [[^origin, ^principal]]} =
               DB.query(
                 ctx.db,
                 "SELECT origin, principal FROM events WHERE verb='wake' AND sessionKey=?1 ORDER BY id DESC LIMIT 1",
                 [target.session_key]
               )
    end
  end

  defp create_session(db, key) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "owner",
      origin: "user:owner",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp dispatch(ctx, bearer, body) do
    conn(:post, "/agent/dispatch", JSON.encode!(body))
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Router.call(Router.init(ctx.opts))
  end
end
