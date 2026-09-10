[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions
alias Tightbeam.{DB, LiveBaseLock, NoticeBatcher, Org, Schema, Wakes}

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

try do
  :ok = Schema.ensure_all(db)
  :ok = DB.assert_base_admitted!(db, base)
  marker = File.read!(Path.join(base, "build-owner.json"))

  {:ok, policy} =
    DB.transaction(db, fn txn ->
      Org.apply_notice_batching_lane_policy_in_txn(
        txn,
        %{session_key: "agent:recipient", target_role: nil},
        true,
        "notice-batching-test-policy:cold-restart",
        "agent:test-policy",
        "acceptance-fixture",
        1
      )
    end)

  assert policy.enabled

  source =
    Wakes.schedule(db, %{
      session_key: "agent:recipient",
      origin: "process:tightbeam",
      creator_session_key: "agent:sender",
      prompt: "routine",
      due_at: 0,
      class: "fyi"
    })

  [%{batch_id: batch_id}] = NoticeBatcher.source_refs(db, source.wake_id)

  assert {:ok, :sealed} =
           DB.transaction(db, fn txn ->
             NoticeBatcher.enqueue_or_recover_in_txn(txn, {:seal_if_due, batch_id, source.due_at})
           end)

  assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM wakes WHERE digest=1")
  :ok = GenServer.stop(db)
  refute Process.alive?(db)

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
    [carrier_id] = NoticeBatcher.recover(reopened, source.due_at)
    batch = NoticeBatcher.batch(reopened, batch_id)

    assert {:ok, [[1]]} =
             DB.query(reopened, "SELECT count(*) FROM wakes WHERE wakeId=?1", [carrier_id])

    assert Enum.map(Wakes.digest_members(reopened, carrier_id), & &1.wake_id) == [source.wake_id]

    assert %{wake_id: ^carrier_id} =
             NoticeBatcher.deliver_batch(reopened, batch_id, batch.delivery_token)

    assert File.read!(Path.join(base, "build-owner.json")) == marker
    assert {:ok, []} = DB.query(reopened, "PRAGMA foreign_key_check")
  after
    GenServer.stop(reopened)
  end

  await.(await, 100)
  IO.puts("guarded-notice-batch-reopen: ok")
after
  if Process.alive?(db), do: GenServer.stop(db)
end
