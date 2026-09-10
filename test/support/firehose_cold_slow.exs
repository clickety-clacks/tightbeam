[payload, base, locks] = System.argv()
payload = Path.expand(payload)
^payload = Application.app_dir(:tightbeam) |> Path.expand()
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :fixture_harness, true)
Application.put_env(:tightbeam, :local_host_name, "testhost")
alias Tightbeam.{Boot, DB, Harness, LiveBaseLock, Model}

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [lock_dir: locks])

:ignore = Boot.start_link(%{base_dir: base})
marker = File.read!(Path.join(base, "build-owner.json"))
:ok = GenServer.stop(db)
key = :crypto.hash(:sha256, base) |> Base.encode16(case: :lower)
lock_path = Path.join(locks, key <> ".lock")

await = fn recur, remaining ->
  case LiveBaseLock.acquire(lock_path) do
    {:ok, lock} ->
      :ok = LiveBaseLock.release(lock)

    {:error, :lock_busy} when remaining > 0 ->
      Process.sleep(10)
      recur.(recur, remaining - 1)

    other ->
      raise "lock did not release: #{inspect(other)}"
  end
end

await.(await, 100)
File.write!(Path.join(base, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
Tightbeam.RecoveryFixture.place_adapter!(base, seed_credential: false)
tripwire = Path.join(base, "forbidden-execution.log")
bin = Path.join(base, "fixture-bin")
File.mkdir_p!(bin)
# These are synthetic CLI probes, never harness adapters or provider clients.
for name <- ["claude", "codex", "fixture"] do
  path = Path.join(bin, name)

  File.write!(path, """
  #!/bin/sh
  if [ '#{name}' = codex ] && [ "$#" = 2 ] && [ "$1" = --dangerously-bypass-hook-trust ] && [ "$2" = --version ]; then
    shift
  fi
  if [ "$#" = 1 ] && [ "$1" = --version ]; then
    echo '#{name} fixture-only 0.0.0'
    exit 0
  fi
  echo '#{name}: forbidden non-probe' >> "$GUARD_TRIPWIRE"
  exit 64
  """)

  File.chmod!(path, 0o755)
end

for name <- ["npm", "ssh"] do
  path = Path.join(bin, name)
  File.write!(path, "#!/bin/sh\necho '#{name}: forbidden' >> \"$GUARD_TRIPWIRE\"\nexit 64\n")
  File.chmod!(path, 0o755)
end

System.put_env("GUARD_TRIPWIRE", tripwire)
System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
for module <- Harness.all(), key <- module.credential_env_vars(), do: System.delete_env(key)

for name <- ["claude", "codex", "fixture", "npm", "ssh"] do
  true = System.find_executable(name) == Path.join(bin, name)
end

for module <- Harness.all() do
  %{input: %{profile: profile}} =
    Enum.find(
      module.conformance_vectors()["ensure_adapter"],
      &(&1.case == "local_present")
    )

  true = File.exists?(Path.join(base, "adapters/node_modules/.bin/#{profile.adapter_bin}"))
end

File.mkdir_p!(Path.join(base, "work"))
Application.put_env(:tightbeam, :cwd, Path.join(base, "work"))
{:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
{:ok, {_, port}} = :inet.sockname(listener)
:ok = :gen_tcp.close(listener)
Application.put_env(:tightbeam, :port, port)
Application.put_env(:tightbeam, :default_harness, :fixture)
Application.put_env(:tightbeam, :default_model, Model.new("fixture-model"))
Application.put_env(:tightbeam, :live_base_guard, lock_dir: locks)
Application.put_env(:tightbeam, :autostart, true)
Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)
{:ok, _apps} = Application.ensure_all_started(:tightbeam)

import ExUnit.Assertions
alias Tightbeam.ClientE2E.WS
alias Tightbeam.Firehose.Hub
alias Tightbeam.Wire.Router
owner = self()
held = :atomics.new(1, signed: false)

barrier = fn notice ->
  if :atomics.compare_exchange(held, 1, 0, 1) == :ok do
    send(owner, {:held, self(), notice})

    receive do
      :release -> :ok
    after
      5_000 -> raise "delivery release missing"
    end
  end
end

# Configure only this synthetic application's canonical producer destination.
db_owner = Process.whereis(DB)
:ok = Supervisor.terminate_child(Tightbeam.Supervisor, Hub)
:ok = Supervisor.delete_child(Tightbeam.Supervisor, Hub)
{:ok, hub} = Supervisor.start_child(Tightbeam.Supervisor, {Hub, name: Hub, queue_limit: 2})
^db_owner = Process.whereis(DB)
:ok = DB.assert_base_admitted!(DB, base)
%{"cliToken" => token} = base |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()
handlers = Tightbeam.Gateway.handlers(%{db: DB, base_dir: base, wake_tick_ms: 60_000})

opts =
  Router.init(
    db: DB,
    base_dir: base,
    handlers: handlers,
    cli_token: token,
    firehose_hub: hub,
    firehose_delivery_barrier: barrier,
    model_catalog: %{},
    session_status: fn _ -> nil end
  )

{:ok, server} =
  Bandit.start_link(plug: {Router, opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false)

{:ok, {_, slow_port}} = ThousandIsland.listener_info(server)

try do
  {:ok, device} =
    Tightbeam.ClientE2E.SimClient.pair("127.0.0.1", slow_port,
      device_id: "slow-cold",
      claimed_name: "Synthetic"
    )

  connect = fn ->
    {:ok, ws} = WS.connect("127.0.0.1", slow_port, "/ws/changes?protocolVersion=1")
    :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => device.token}))
    {:ok, {:text, auth}, ws} = WS.recv(ws, 2_000)
    assert JSON.decode!(auth)["success"]

    :ok =
      WS.send_text(
        ws,
        JSON.encode!(%{
          "type" => "subscribe",
          "protocolVersion" => 1,
          "subscriptionId" => "slow",
          "filters" => %{"classes" => ["work_item.created"]}
        })
      )

    {:ok, {:text, ready}, ws} = WS.recv(ws, 2_000)
    assert JSON.decode!(ready)["type"] == "subscription_ready"
    ws
  end

  create = fn title ->
    Tightbeam.WorkItems.__handle__(DB, "work-item-create", %{
      verb: "work-item-create",
      origin: "user:#{device.user_id}",
      principal: {:user, device.user_id},
      session_key: nil,
      params: %{title: title},
      firehose_in_txn: true,
      firehose_hub: hub
    })
  end

  ws = connect.()

  try do
    first = create.("held")
    assert_receive {:held, socket, notice}, 2_000
    assert notice["refs"]["workItemId"] == first.id
    second = create.("queued")
    third = create.("overflow")

    assert Hub.connection_stats(hub, socket) == %{
             in_flight: true,
             overflowed: true,
             queued: 0,
             seq: 3
           }

    send(socket, :release)

    receive_close = fn recur, ws ->
      case WS.recv_event(ws, 2_000) do
        {:ok, {:closed, code}, ws} -> {code, ws}
        {:ok, {:text, _}, ws} -> recur.(recur, ws)
        other -> raise "close missing: #{inspect(other)}"
      end
    end

    assert {4008, closed} = receive_close.(receive_close, ws)
    WS.close(closed)

    rebuilt = fn id ->
      {:ok, {{_, 200, _}, _, body}} =
        :httpc.request(
          :get,
          {String.to_charlist("http://127.0.0.1:#{slow_port}/api/work-items/#{id}"),
           [{~c"authorization", String.to_charlist("Bearer " <> device.token)}]},
          [timeout: 2_000],
          body_format: :binary
        )

      JSON.decode!(body)["item"]
    end

    for row <- [first, second, third], do: assert(rebuilt.(row.id)["id"] == row.id)
    fresh = connect.()

    try do
      fourth = create.("after reconnect")
      {:ok, {:text, raw}, fresh} = WS.recv(fresh, 2_000)
      assert %{"class" => "work_item.created", "payload" => item} = JSON.decode!(raw)
      assert item == rebuilt.(fourth.id)
      WS.close(fresh)
    after
      WS.close(fresh)
    end
  after
    WS.close(ws)
  end

  assert File.regular?(Path.join(base, "state.db"))
  assert File.read!(Path.join(base, "build-owner.json")) == marker
  refute File.exists?(tripwire)
after
  Supervisor.stop(server)
  Application.stop(:tightbeam)
end

await.(await, 100)
refute File.exists?(tripwire)
IO.puts("guarded-firehose-slow-consumer: ok")
