[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions
alias Tightbeam.{Artifacts, DB, LiveBaseLock, Model, Org, Schema, StateResources}
alias Tightbeam.Firehose.Hub
{:ok, hub} = Hub.start_link(name: Hub)

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

try do
  :ok = Schema.ensure_all(db)
  :ok = DB.assert_base_admitted!(db, base)
  marker = File.read!(Path.join(base, "build-owner.json"))

  :ok =
    DB.execute(
      db,
      "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',0,1),('linked',0,1)"
    )

  Org.create(db, %{
    session_key: "al_owner",
    display_name: "AL",
    owner_user_id: "flynn",
    origin: "user:flynn",
    archetype: "default",
    host: "testhost",
    harness: "fixture",
    provider: "fixture_provider",
    model: Model.new("fixture-model")
  })

  :ok =
    DB.execute(
      db,
      "INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt) VALUES ('wi_al','AL','flynn','flynn',1)"
    )

  :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: false})

  row =
    Artifacts.record(db, %{
      principal: {:session, "al_owner"},
      session_key: "al_owner",
      params: %{
        kind: "report",
        title: "AL",
        origin_path: "synthetic-host:/unavailable/artifact",
        work_item_id: "wi_al"
      }
    })

  assert_receive {:firehose_notice, %{"class" => "artifact.recorded", "payload" => old}}, 5_000
  Hub.delivered(Hub, self())
  :ok = DB.execute(db, "UPDATE work_items SET ownerUserId='linked' WHERE id='wi_al'")
  :ok = GenServer.stop(hub)
  work = Path.join(base, "synthetic-work")
  File.mkdir_p!(work)

  assert :ok =
           Artifacts.archive_session(db, "al_owner", work, Path.join(base, "synthetic-archive"))

  refute_receive {:firehose_notice, _}, 100
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

    for principal <- [
          %{kind: "session", id: "al_owner", is_admin: false},
          %{kind: "user", id: "linked", is_admin: false},
          %{kind: "user", id: "admin", is_admin: true}
        ] do
      restored =
        StateResources.query_artifact(reopened, %{key: row.artifact_id, principal: principal})
        |> StateResources.artifact()

      assert restored["state"] == "released"
      assert restored["rowVersion"] == 2
      assert old["rowVersion"] < restored["rowVersion"]
    end

    assert StateResources.query_artifact(reopened, %{
             key: row.artifact_id,
             principal: %{kind: "user", id: "denied", is_admin: false}
           }) == nil

    {:ok, new_hub} = Hub.start_link(name: Hub)

    try do
      :ok =
        Hub.register(Hub, self(), %{mode: :all, db: reopened, user_id: "admin", is_admin: true})

      :sys.get_state(Hub)
      refute_receive {:firehose_notice, _}, 100
    after
      GenServer.stop(new_hub)
    end

    # Physical deletion is test-only; floors survive it and reject stale replay.
    alias Tightbeam.DB.Txn
    released = StateResources.query_artifact(reopened, row.artifact_id)
    assert Artifacts.release(reopened, row.artifact_id).state == "released"
    assert StateResources.query_artifact(reopened, row.artifact_id) == released

    assert {:error, %RuntimeError{message: "delete rollback"}} =
             DB.transaction(reopened, fn txn ->
               assert Artifacts.reserve_version_in_txn(txn, row.artifact_id) == 3
               Txn.q(txn, "DELETE FROM artifacts WHERE artifactId=?1", [row.artifact_id])
               raise "delete rollback"
             end)

    assert StateResources.query_artifact(reopened, row.artifact_id) == released
    :ok = DB.execute(reopened, "CREATE TEMP TABLE saved_artifact AS SELECT * FROM artifacts")

    assert {:ok, 3} =
             DB.transaction(reopened, fn txn ->
               version = Artifacts.reserve_version_in_txn(txn, row.artifact_id)
               Txn.q(txn, "DELETE FROM artifacts WHERE artifactId=?1", [row.artifact_id])
               version
             end)

    assert StateResources.query_artifact(reopened, row.artifact_id) == nil

    assert {:ok, [[3]]} =
             DB.query(
               reopened,
               "SELECT rowVersion FROM artifact_version_floors WHERE artifactId=?1",
               [row.artifact_id]
             )

    assert {:ok, 4} =
             DB.transaction(reopened, fn txn ->
               version = Artifacts.reserve_version_in_txn(txn, row.artifact_id)
               Txn.q(txn, "INSERT INTO artifacts SELECT * FROM saved_artifact")
               version
             end)

    recreated = StateResources.query_artifact(reopened, row.artifact_id)
    assert recreated.row_version == 4
    buffered = [{:upsert, released.row_version, released}, {:delete, 3, nil}]

    assert Enum.reduce(buffered, {4, recreated}, fn {_op, version, payload},
                                                    {seen, _} = current ->
             if version > seen, do: {version, payload}, else: current
           end) == {4, recreated}

    assert File.read!(Path.join(base, "build-owner.json")) == marker
  after
    GenServer.stop(reopened)
  end

  await.(await, 100)

  {:ok, final_db} =
    DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

  try do
    :ok = Schema.ensure_all(final_db)
    :ok = DB.assert_base_admitted!(final_db, base)
    assert StateResources.query_artifact(final_db, row.artifact_id).row_version == 4
    assert File.read!(Path.join(base, "build-owner.json")) == marker
  after
    GenServer.stop(final_db)
  end

  await.(await, 100)
  IO.puts("guarded-artifact-lost-handoff: ok")
after
  if Process.alive?(hub), do: GenServer.stop(hub)
  if Process.alive?(db), do: GenServer.stop(db)
end
