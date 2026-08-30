defmodule Tightbeam.FirehoseAcceptanceFixture do
  @moduledoc false

  alias Tightbeam.ClientE2E.WS
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router
  alias Tightbeam.{DB, Gateway, Rules}

  defstruct [
    :base_dir,
    :cli_token,
    :db,
    :db_path,
    :device,
    :gateway,
    :hub,
    :port,
    :supervisor,
    :user_id
  ]

  def start!(opts \\ []) do
    id = System.unique_integer([:positive, :monotonic])
    base_dir = Path.join(System.tmp_dir!(), "tightbeam-firehose-acceptance-#{id}")
    File.mkdir_p!(base_dir)

    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)
    Process.unlink(supervisor)

    try do
      db_path = Path.join(base_dir, "state.db")
      {:ok, db} = Supervisor.start_child(supervisor, {DB, path: db_path, name: nil})

      {:ok, hub} =
        Supervisor.start_child(
          supervisor,
          {Hub, name: nil, queue_limit: Keyword.get(opts, :queue_limit, 1_000)}
        )

      :ok = Tightbeam.Schema.ensure_all(db)

      {:paired, device} =
        Tightbeam.TestCase.claim_org(db, %{
          device_id: "firehose-acceptance-#{id}",
          claimed_name: "Flynn",
          platform: nil,
          model: nil
        })

      handlers = Gateway.handlers(%{db: db, base_dir: base_dir, wake_tick_ms: 1_000})
      Rules.load!(Path.join(base_dir, "no-rules"), Map.keys(handlers))
      cli_token = "tbc_firehose_acceptance_#{id}"

      router_opts =
        Router.init(
          db: db,
          base_dir: base_dir,
          cursor_signing: Tightbeam.TestCase.cursor_signing!(base_dir),
          handlers: handlers,
          cli_token: cli_token,
          firehose_hub: hub,
          firehose_delivery_barrier: Keyword.get(opts, :delivery_barrier),
          session_status: fn _ -> nil end
        )

      {:ok, gateway} =
        Supervisor.start_child(
          supervisor,
          {Bandit, plug: {Router, router_opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(gateway)

      %__MODULE__{
        base_dir: base_dir,
        cli_token: cli_token,
        db: db,
        db_path: db_path,
        device: device,
        gateway: gateway,
        hub: hub,
        port: port,
        supervisor: supervisor,
        user_id: device.user_id
      }
    rescue
      exception ->
        if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
        File.rm_rf!(base_dir)
        reraise exception, __STACKTRACE__
    end
  end

  def stop(%__MODULE__{} = fixture) do
    if Process.alive?(fixture.supervisor), do: Supervisor.stop(fixture.supervisor)

    processes = [fixture.supervisor, fixture.db, fixture.hub, fixture.gateway]
    processes_stopped? = Enum.all?(processes, &(not Process.alive?(&1)))
    port_closed? = port_closed?(fixture.port)

    removal = File.rm_rf(fixture.base_dir)
    directory_removed? = not File.exists?(fixture.base_dir)

    if processes_stopped? and port_closed? and match?({:ok, _}, removal) and directory_removed? do
      :ok
    else
      {:error,
       %{
         directory_removed?: directory_removed?,
         port_closed?: port_closed?,
         processes_stopped?: processes_stopped?,
         removal: removal
       }}
    end
  end

  def connect(%__MODULE__{} = fixture) do
    {:ok, ws} = WS.connect("127.0.0.1", fixture.port, "/ws/changes?protocolVersion=1")
    :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => fixture.device.token}))
    {:ok, {:text, auth}, ws} = WS.recv(ws, 2_000)
    %{"type" => "auth_result", "success" => true} = JSON.decode!(auth)

    :ok =
      WS.send_text(
        ws,
        JSON.encode!(%{
          "type" => "subscribe",
          "protocolVersion" => 1,
          "subscriptionId" => "work-items",
          "filters" => %{"classes" => ["work_item."]}
        })
      )

    {:ok, {:text, ready}, ws} = WS.recv(ws, 2_000)
    %{"type" => "subscription_ready"} = JSON.decode!(ready)
    ws
  end

  def recv_change(ws) do
    case WS.recv(ws, 2_000) do
      {:ok, {:text, bytes}, ws} ->
        case JSON.decode!(bytes) do
          %{"type" => "change"} = notice -> {notice, ws}
          _other -> recv_change(ws)
        end

      other ->
        raise "change socket closed before notice: #{inspect(other)}"
    end
  end

  def recv_close(ws, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    recv_close_until(ws, deadline)
  end

  def create_item(%__MODULE__{} = fixture, title) do
    %{"result" => %{"id" => id}} =
      dispatch(fixture, "work-item-create", %{"title" => title})

    id
  end

  def snapshot(%__MODULE__{} = fixture) do
    %{"result" => %{"workItems" => items}} = dispatch(fixture, "work-item-list", %{})
    Map.new(items, &{&1["id"], Tightbeam.StateResources.work_item(&1)})
  end

  defp recv_close_until(ws, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case WS.recv_event(ws, remaining) do
      {:ok, {:closed, _code}, _ws} = closed -> closed
      {:ok, {:text, _bytes}, ws} -> recv_close_until(ws, deadline)
      other -> other
    end
  end

  defp dispatch(fixture, verb, params) do
    body = JSON.encode!(%{"verb" => verb, "asUser" => fixture.user_id, "params" => params})
    url = ~c"http://127.0.0.1:#{fixture.port}/agent/dispatch"

    {:ok, {{_version, 200, _reason}, _headers, response}} =
      :httpc.request(
        :post,
        {url,
         [
           {~c"authorization", ~c"Bearer #{fixture.cli_token}"},
           {~c"x-tightbeam-cli-version",
            String.to_charlist(Tightbeam.CliCompatibility.required_version())},
           {~c"content-type", ~c"application/json"}
         ], ~c"application/json", body},
        [{:timeout, 2_000}],
        body_format: :binary
      )

    JSON.decode!(response)
  end

  defp port_closed?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 200) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        false

      {:error, :econnrefused} ->
        true

      {:error, _reason} ->
        false
    end
  end
end
