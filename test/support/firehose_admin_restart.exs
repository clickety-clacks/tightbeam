[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions
alias Tightbeam.{AdminProjection, DB, LiveBaseLock, Schema}
alias Tightbeam.Firehose.{Hub, Publisher}
{:ok, hub} = Hub.start_link(name: Hub)

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

try do
  :ok = Schema.ensure_all(db)
  :ok = DB.assert_base_admitted!(db, base)
  marker = File.read!(Path.join(base, "build-owner.json"))

  :ok =
    Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "synthetic-admin", is_admin: true})

  versions =
    1..16
    |> Enum.map(fn _ ->
      Task.async(fn ->
        {:ok, version} =
          DB.transaction(db, fn txn ->
            AdminProjection.allocate_in_txn(
              txn,
              "config",
              "concurrent-key",
              System.system_time(:millisecond)
            )
          end)

        version
      end)
    end)
    |> Enum.map(&Task.await(&1, 5_000))

  assert Enum.sort(versions) == Enum.to_list(1..16)

  assert {:error, %RuntimeError{message: "rollback"}} =
           DB.transaction(db, fn txn ->
             AdminProjection.allocate_in_txn(txn, "config", "concurrent-key", 42)
             raise "rollback"
           end)

  assert AdminProjection.version(db, "config", "concurrent-key") == 16

  assert {:error, %RuntimeError{message: "rollback with notice"}} =
           DB.transaction(db, fn txn ->
             version = AdminProjection.allocate_in_txn(txn, "config", "rolled-back-key", 43)

             Publisher.committed_in_txn(
               txn,
               "config.updated",
               %{key: "rolled-back-key", value: nil, updated_at: 43, row_version: version},
               %{"key" => "rolled-back-key"}
             )

             raise "rollback with notice"
           end)

  assert AdminProjection.version(db, "config", "rolled-back-key") == nil
  :sys.get_state(Hub)
  refute_receive {:firehose_notice, _}, 100

  {:ok, floors} =
    DB.query(db, "SELECT * FROM admin_projection_versions ORDER BY resource,primaryKey")

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

  {:ok, reopened} =
    DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

  try do
    :ok = Schema.ensure_all(reopened)
    :ok = DB.assert_base_admitted!(reopened, base)
    assert AdminProjection.version(reopened, "config", "concurrent-key") == 16
    assert AdminProjection.version(reopened, "config", "rolled-back-key") == nil

    assert {:ok, ^floors} =
             DB.query(
               reopened,
               "SELECT * FROM admin_projection_versions ORDER BY resource,primaryKey"
             )

    assert File.read!(Path.join(base, "build-owner.json")) == marker
    assert {:ok, []} = DB.query(reopened, "PRAGMA foreign_key_check")
  after
    GenServer.stop(reopened)
  end

  await.(await, 100)
  IO.puts("guarded-admin-floor-restart: ok")
after
  if Process.alive?(db), do: GenServer.stop(db)
  GenServer.stop(hub)
end
