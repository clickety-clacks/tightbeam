defmodule GuardClientWire do
  import ExUnit.Assertions
  alias Tightbeam.{Model, ConnRegistry, DB, Gateway, Org, Rules}
  alias Tightbeam.ClientE2E.{Journeys, SimClient}
  alias Tightbeam.Wire.Router

  def run(base, locks, selected) do
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)
    Process.put(:wire_supervisor, supervisor)

    try do
      ctx = real_gateway(base, locks)
      :ok = DB.assert_base_admitted!(ctx.db, base)
      marker = File.read!(Path.join(base, "build-owner.json"))
      run_case(selected, ctx)
      assert File.read!(Path.join(base, "build-owner.json")) == marker
      assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM turns")
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
    end
  end

  defp start_supervised!(spec) do
    {:ok, pid} = Supervisor.start_child(Process.get(:wire_supervisor), spec)
    pid
  end

  defp run_case(0, ctx) do
    {:ok, %{token: token}} =
      SimClient.pair("127.0.0.1", ctx.port, device_id: "sim-j0", claimed_name: "Flynn")

    {:ok, client} = SimClient.connect("127.0.0.1", ctx.port, token, device_id: "sim-j0")

    {journey_ctx, rows} = Journeys.run(journey_ctx(ctx, client), "J0")
    SimClient.disconnect(journey_ctx.client)

    assert Enum.map(rows, & &1.status) == [:pass, :pass],
           "J0 rows: #{inspect(Enum.map(rows, &{&1.step, &1.status, &1.note}))}"

    assert journey_ctx.main_key =~ "main"
  end

  defp run_case(1, ctx) do
    assert {:error, "auth_failed"} =
             SimClient.connect("127.0.0.1", ctx.port, "not-a-token", device_id: "sim-bad")
  end

  defp run_case(2, ctx) do
    {:ok, %{token: token}} =
      SimClient.pair("127.0.0.1", ctx.port, device_id: "sim-bad-id", claimed_name: "Flynn")

    {:ok, client} = SimClient.connect("127.0.0.1", ctx.port, token, device_id: "sim-bad-id")
    watermark = SimClient.mark(client)
    key = Org.personal_session_key(client.user_id)

    :ok =
      Tightbeam.ClientE2E.WS.send_text(
        client.ws,
        JSON.encode!(%{
          "type" => "message",
          "id" => "nope",
          "sessionKey" => key,
          "content" => "hi"
        })
      )

    assert {:ok, frame, client} =
             SimClient.await(client, watermark, &(&1["type"] == "error"), 5_000)

    assert frame["code"] == "invalid_message"
    SimClient.disconnect(client)
  end

  defp journey_ctx(ctx, client) do
    %{
      base_dir: ctx.base_dir,
      host: "127.0.0.1",
      port: ctx.port,
      client: client,
      main_key: nil,
      gateway: nil,
      leg: %{harness: "claude", host: "testhost", model: "fable"},
      turn_wait_ms: 10_000,
      settle_ms: 250
    }
  end

  defp real_gateway(base_dir, locks) do
    db = :"client_e2e_db_#{System.unique_integer([:positive])}"

    start_supervised!(
      {DB, path: Path.join(base_dir, "state.db"), name: db, guard_inputs: [lock_dir: locks]}
    )

    :ok = Tightbeam.Schema.ensure_all(db)

    start_supervised!(%{
      id: :client_e2e_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    handlers = Gateway.handlers(%{db: db, base_dir: base_dir, port: 0})
    Rules.load!(Path.join(base_dir, "no-rules"), Map.keys(handlers))

    router_opts =
      Router.init(
        db: db,
        base_dir: base_dir,
        handlers: handlers,
        conn_registry: Tightbeam.ConnRegistry,
        cli_token: "tbc_client_e2e",
        session_status: fn _key -> nil end,
        defaults: %{
          archetype: "default",
          host: "testhost",
          harness: :claude,
          provider: fn -> :anthropic end,
          model: Model.new("fable")
        }
      )

    bandit =
      start_supervised!(
        {Bandit, plug: {Router, router_opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    %{db: db, base_dir: base_dir, port: port}
  end
end

[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
for app <- [:exqlite, :crypto, :bandit], do: {:ok, _} = Application.ensure_all_started(app)
selected = File.read!(Path.join(Path.dirname(base), "wire-case")) |> String.to_integer()
GuardClientWire.run(base, locks, selected)
IO.puts("guarded-client-wire-#{selected}: ok")
