defmodule Tightbeam.FirehoseAcceptanceFixture do
  @moduledoc false

  alias Tightbeam.ClientE2E.{LegGateway, SimClient, WS}
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router
  alias Tightbeam.{CursorSigning, DB, Gateway, Rules}

  defstruct [
    :base_dir,
    :cli_token,
    :db,
    :db_path,
    :device,
    :gateway,
    :hub,
    :mode,
    :port,
    :process_tracker,
    :repo_root,
    :socket_tracker,
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
        mode: :in_process,
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

  def start_subprocess!(opts \\ []) do
    id = System.unique_integer([:positive, :monotonic])

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-client-e2e-firehose-acceptance-#{id}")

    db_path = Path.join(base_dir, "state.db")
    port = os_port!()
    repo_root = Keyword.get(opts, :repo_root, File.cwd!())
    {:ok, process_tracker} = Agent.start(fn -> nil end)
    {:ok, socket_tracker} = Agent.start(fn -> [] end)

    try do
      File.mkdir_p!(base_dir)
      CursorSigning.provision!(base_dir)

      gateway =
        case boot_subprocess(base_dir, port, repo_root) do
          {:ok, gateway} ->
            gateway

          {:error, reason, gateway} ->
            Agent.update(process_tracker, fn _ -> gateway end)

            raise "firehose subprocess gateway did not boot: #{inspect(reason)}; " <>
                    "log=#{gateway.log_path}"
        end

      Agent.update(process_tracker, fn _ -> gateway end)

      {:ok, device} =
        SimClient.pair("127.0.0.1", port,
          device_id: "firehose-acceptance-#{id}",
          claimed_name: "Firehose acceptance"
        )

      %__MODULE__{
        base_dir: base_dir,
        cli_token: gateway_token!(base_dir),
        db_path: db_path,
        device: device,
        mode: :subprocess,
        port: port,
        process_tracker: process_tracker,
        repo_root: repo_root,
        socket_tracker: socket_tracker,
        user_id: device.user_id
      }
    rescue
      exception ->
        cleanup_failed_subprocess_start(
          process_tracker,
          socket_tracker,
          base_dir
        )

        reraise exception, __STACKTRACE__
    end
  end

  def with_subprocess!(fun, opts \\ []) when is_function(fun, 1) do
    fixture = start_subprocess!(opts)

    try do
      fun.(fixture)
    after
      case stop(fixture) do
        :ok -> :ok
        {:error, details} -> raise "firehose subprocess teardown failed: #{inspect(details)}"
      end
    end
  end

  def active_subprocess(%__MODULE__{mode: :subprocess, process_tracker: tracker}) do
    Agent.get(tracker, & &1)
  end

  def kill_subprocess!(%__MODULE__{mode: :subprocess} = fixture) do
    gateway = active_subprocess(fixture)

    unless LegGateway.ours?(gateway) do
      raise "refusing to signal a gateway whose captured PID identity no longer matches"
    end

    captured = gateway_processes(gateway)

    case LegGateway.teardown(gateway, remove: false) do
      :ok -> :ok
      error -> raise "gateway kill failed: #{inspect(error)}"
    end

    unless await_port_closed?(fixture.port, 5_000) do
      raise "gateway port #{fixture.port} remained open after exact process exit"
    end

    unless processes_released?(captured) do
      raise "gateway process tree remained alive after exact process exit"
    end

    gateway
  end

  def restart_subprocess!(%__MODULE__{mode: :subprocess} = fixture) do
    old_gateway = active_subprocess(fixture)

    if LegGateway.ours?(old_gateway) do
      raise "refusing to restart before the captured gateway process has exited"
    end

    restarted =
      case boot_subprocess(fixture.base_dir, fixture.port, fixture.repo_root) do
        {:ok, gateway} ->
          gateway

        {:error, reason, gateway} ->
          Agent.update(fixture.process_tracker, fn _ -> gateway end)

          raise "firehose subprocess gateway did not restart: #{inspect(reason)}; " <>
                  "log=#{gateway.log_path}"
      end

    Agent.update(fixture.process_tracker, fn _ -> restarted end)

    if restarted.os_pid == old_gateway.os_pid do
      raise "gateway restart reused PID #{restarted.os_pid}"
    end

    restarted
  end

  def capture_subprocess(%__MODULE__{mode: :subprocess} = fixture) do
    gateway = active_subprocess(fixture)

    %{
      base_dir: fixture.base_dir,
      db_path: fixture.db_path,
      gateway: gateway,
      port: fixture.port,
      process_tracker: fixture.process_tracker,
      processes: gateway_processes(gateway),
      socket_tracker: fixture.socket_tracker,
      sockets: Agent.get(fixture.socket_tracker, & &1)
    }
  end

  def subprocess_released?(capture) do
    processes_released?(capture.processes) and
      Enum.all?(capture.sockets, &socket_closed?/1) and
      port_closed?(capture.port) and
      not File.exists?(capture.db_path) and
      not File.exists?(capture.base_dir) and
      not Process.alive?(capture.process_tracker) and
      not Process.alive?(capture.socket_tracker)
  end

  def stop(%__MODULE__{mode: :subprocess} = fixture) do
    capture = capture_subprocess(fixture)
    close_tracked_sockets(fixture.socket_tracker)

    teardown = LegGateway.teardown(capture.gateway)
    port_closed? = await_port_closed?(fixture.port, 5_000)
    processes_stopped? = processes_released?(capture.processes)
    directory_removed? = not File.exists?(fixture.base_dir)
    db_removed? = not File.exists?(fixture.db_path)
    sockets_closed? = Enum.all?(capture.sockets, &socket_closed?/1)

    stop_tracker(fixture.process_tracker)
    stop_tracker(fixture.socket_tracker)

    trackers_stopped? =
      not Process.alive?(fixture.process_tracker) and
        not Process.alive?(fixture.socket_tracker)

    if teardown == :ok and port_closed? and processes_stopped? and directory_removed? and
         db_removed? and sockets_closed? and trackers_stopped? do
      :ok
    else
      {:error,
       %{
         db_removed?: db_removed?,
         directory_removed?: directory_removed?,
         port_closed?: port_closed?,
         processes_stopped?: processes_stopped?,
         sockets_closed?: sockets_closed?,
         teardown: teardown,
         trackers_stopped?: trackers_stopped?
       }}
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

  def connect(%__MODULE__{} = fixture, opts \\ []) do
    subscription_id = Keyword.get(opts, :subscription_id, "work-items")
    filters = Keyword.get(opts, :filters, %{"classes" => ["work_item."]})

    {:ok, ws} = WS.connect("127.0.0.1", fixture.port, "/ws/changes?protocolVersion=1")
    track_socket(fixture, ws)
    :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => fixture.device.token}))
    {:ok, {:text, auth}, ws} = WS.recv(ws, 2_000)
    %{"type" => "auth_result", "success" => true} = JSON.decode!(auth)

    :ok =
      WS.send_text(
        ws,
        JSON.encode!(%{
          "type" => "subscribe",
          "protocolVersion" => 1,
          "subscriptionId" => subscription_id,
          "filters" => filters
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

  def port_closed?(port) do
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

  defp await_port_closed?(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_port_closed?(port, deadline)
  end

  defp poll_port_closed?(port, deadline) do
    cond do
      port_closed?(port) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(100)
        poll_port_closed?(port, deadline)
    end
  end

  defp os_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp boot_subprocess(base_dir, port, repo_root) do
    # CI installs only the test registry's Fixture CLI. A dev child excludes
    # that harness and exits at preflight before /version can bind. Keep the
    # child test VM's own scratch root inside base_dir so exact teardown owns it.
    LegGateway.boot(base_dir, port,
      repo_root: repo_root,
      mix_env: "test",
      env: [
        {"TMPDIR", base_dir},
        {"TIGHTBEAM_FIREHOSE_ACCEPTANCE_GATEWAY", "1"}
      ]
    )
  end

  defp gateway_token!(base_dir) do
    %{"cliToken" => token} =
      base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    token
  end

  defp gateway_processes(nil), do: []

  defp gateway_processes(gateway) do
    [{to_string(gateway.os_pid), gateway.os_command} | LegGateway.capture_tree(gateway.os_pid)]
  end

  defp processes_released?(captured) do
    Enum.all?(captured, fn {pid, command} ->
      is_nil(command) or LegGateway.process_command(pid) != command
    end)
  end

  defp track_socket(%__MODULE__{socket_tracker: nil}, _ws), do: :ok

  defp track_socket(%__MODULE__{socket_tracker: tracker}, ws) do
    Agent.update(tracker, &[ws | &1])
  end

  defp close_tracked_sockets(tracker) do
    sockets = Agent.get_and_update(tracker, &{&1, []})
    Enum.each(sockets, &WS.close/1)
  end

  defp socket_closed?(%WS{socket: socket}) do
    case :inet.sockname(socket) do
      {:ok, _address} -> false
      {:error, reason} when reason in [:closed, :einval, :enotconn] -> true
      {:error, _reason} -> false
    end
  end

  defp stop_tracker(tracker) do
    if Process.alive?(tracker), do: Agent.stop(tracker, :normal, 5_000)
    :ok
  end

  defp cleanup_failed_subprocess_start(process_tracker, socket_tracker, base_dir) do
    close_tracked_sockets(socket_tracker)

    case Agent.get(process_tracker, & &1) do
      nil -> File.rm_rf(base_dir)
      gateway -> LegGateway.teardown(gateway)
    end

    stop_tracker(process_tracker)
    stop_tracker(socket_tracker)
  end
end
