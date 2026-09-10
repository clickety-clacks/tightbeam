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
alias Tightbeam.ClientE2E.{SimClient, WS}

try do
  Tightbeam.Readiness.await_settled()
  :ok = DB.assert_base_admitted!(DB, base)

  {:ok, device} =
    SimClient.pair("127.0.0.1", port, device_id: "cold-firehose", claimed_name: "Synthetic")

  {:ok, ws} = WS.connect("127.0.0.1", port, "/ws/changes?protocolVersion=1")

  try do
    :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => device.token}))
    {:ok, {:text, auth}, ws} = WS.recv(ws, 2_000)
    assert %{"type" => "auth_result", "success" => true} = JSON.decode!(auth)

    :ok =
      WS.send_text(
        ws,
        JSON.encode!(%{
          "type" => "subscribe",
          "protocolVersion" => 1,
          "subscriptionId" => "cold",
          "filters" => %{"classes" => ["work_item.created"]}
        })
      )

    {:ok, {:text, ready}, ws} = WS.recv(ws, 2_000)
    assert %{"type" => "subscription_ready"} = JSON.decode!(ready)
    %{"cliToken" => token} = base |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"x-tightbeam-cli-version",
       String.to_charlist(Tightbeam.CliCompatibility.required_version())}
    ]

    body =
      JSON.encode!(%{
        "verb" => "work-item-create",
        "asUser" => device.user_id,
        "params" => %{"title" => "Cold persistent delivery"}
      })

    {:ok, {{_, 200, _}, _, response}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{port}/agent/dispatch", headers, ~c"application/json", body},
        [timeout: 2_000],
        body_format: :binary
      )

    assert %{"result" => %{"id" => id}} = JSON.decode!(response)
    {:ok, {:text, raw}, ws} = WS.recv(ws, 2_000)

    assert %{
             "type" => "change",
             "class" => "work_item.created",
             "refs" => %{"workItemId" => ^id},
             "payload" => item
           } = JSON.decode!(raw)

    {:ok, {{_, 200, _}, _, detail}} =
      :httpc.request(
        :get,
        {String.to_charlist("http://127.0.0.1:#{port}/api/work-items/#{id}"),
         [{~c"authorization", String.to_charlist("Bearer " <> device.token)}]},
        [timeout: 2_000],
        body_format: :binary
      )

    assert JSON.decode!(detail)["item"] == item
    assert File.regular?(Path.join(base, "state.db"))
    assert File.read!(Path.join(base, "build-owner.json")) == marker
    refute File.exists?(tripwire)
    :ok = WS.close(ws)
  after
    WS.close(ws)
  end
after
  :ok = Application.stop(:tightbeam)
end

await.(await, 100)
refute File.exists?(tripwire)
IO.puts("guarded-firehose-loopback: ok")
