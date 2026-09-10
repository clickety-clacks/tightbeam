[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions
alias Tightbeam.{DB, D1Read, Harness, LiveBaseLock, Placement, Schema}
alias Tightbeam.Firehose.{Hub, Rebuild}

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

{:ok, hub} = Hub.start_link(name: Hub)

try do
  :ok = Schema.ensure_all(db)
  :ok = DB.assert_base_admitted!(db, base)
  marker = File.read!(Path.join(base, "build-owner.json"))
  :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "admin", is_admin: true})

  assert {:ok, _} =
           Placement.register_host(db, "parity", %{
             ssh: nil,
             base_dir: "/unused",
             cli_bin: nil,
             adapter_bin_dir: nil
           })

  harness = hd(Harness.all()).wire_name()
  key = {"parity", harness, "PARITY_VALUE"}
  refs = %{"host" => "parity", "harness" => harness, "name" => "PARITY_VALUE"}
  call = %{verb: "host-env-set", origin: "user:admin", principal: {:user, "admin"}, params: %{}}

  parity = fn version, present ->
    _barrier = Hub.sequence(Hub, self())
    assert_received {:firehose_notice, %{"class" => "host_env.updated", "payload" => payload}}
    Hub.delivered(Hub, self())

    assert [^payload] =
             D1Read.collection(db, base, :host_environment, %{"host" => ["parity"]})

    assert ^payload = D1Read.detail(db, base, :host_environment, key)
    assert {:ok, ^payload} = Rebuild.fetch(db, "host_env.updated", refs, "admin", true)
    assert payload["rowVersion"] == version
    assert payload["valuePresent"] == present
    assert payload["value"] == nil
    assert :forbidden == Rebuild.fetch(db, "host_env.updated", refs, "operator", false)
    payload
  end

  assert %{changed: true} =
           Placement.set_env_overlay_with_firehose(
             db,
             "parity",
             harness,
             "PARITY_VALUE",
             "first-secret",
             "user:admin",
             call
           )

  parity.(1, true)

  assert %{changed: true} =
           Placement.set_env_overlay_with_firehose(
             db,
             "parity",
             harness,
             "PARITY_VALUE",
             "second-secret",
             "user:admin",
             call
           )

  second = parity.(2, true)

  assert %{changed: false} =
           Placement.set_env_overlay_with_firehose(
             db,
             "parity",
             harness,
             "PARITY_VALUE",
             "second-secret",
             "user:admin",
             call
           )

  _barrier = Hub.sequence(Hub, self())
  refute_received {:firehose_notice, %{"class" => "host_env.updated"}}
  assert second == D1Read.detail(db, base, :host_environment, key)

  assert %{changed: true} =
           Placement.unset_env_overlay_with_firehose(db, "parity", harness, "PARITY_VALUE", %{
             call
             | verb: "host-env-unset"
           })

  unset = parity.(3, false)

  assert %{changed: false} =
           Placement.unset_env_overlay_with_firehose(db, "parity", harness, "PARITY_VALUE", %{
             call
             | verb: "host-env-unset"
           })

  _barrier = Hub.sequence(Hub, self())
  refute_received {:firehose_notice, %{"class" => "host_env.updated"}}

  :ok = GenServer.stop(hub)
  :ok = GenServer.stop(db)

  lock_path =
    Path.join(locks, Base.encode16(:crypto.hash(:sha256, base), case: :lower) <> ".lock")

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

  {:ok, reopened} =
    DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

  try do
    :ok = Schema.ensure_all(reopened)
    :ok = DB.assert_base_admitted!(reopened, base)
    assert [^unset] = D1Read.collection(reopened, base, :host_environment, %{})
    assert ^unset = D1Read.detail(reopened, base, :host_environment, key)
    assert {:ok, ^unset} = Rebuild.fetch(reopened, "host_env.updated", refs, "admin", true)
    assert :forbidden == Rebuild.fetch(reopened, "host_env.updated", refs, "operator", false)
    assert File.read!(Path.join(base, "build-owner.json")) == marker
  after
    GenServer.stop(reopened)
  end

  await.(await, 100)
  IO.puts("guarded-environment-parity: ok")
after
  if Process.alive?(hub), do: GenServer.stop(hub)
  if Process.alive?(db), do: GenServer.stop(db)
end
