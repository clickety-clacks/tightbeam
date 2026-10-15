[payload, base] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:ex_unit, :assert_receive_timeout, 1_000)
import ExUnit.Assertions
alias Tightbeam.{DB, Dispatch, Rules}
{:ok, db} = DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

try do
  :ok = Tightbeam.Schema.ensure_all(db)
  :persistent_term.erase(Rules)
  hub = :dispatch_read_hub
  {:ok, _} = Tightbeam.Firehose.Hub.start_link(name: hub)
  :ok = Tightbeam.Firehose.Hub.register(hub, self(), %{
    mode: :all, db: db, user_id: "reader", is_admin: true
  })
  parent = self()

  writer = Task.async(fn ->
    DB.transaction(db, fn txn ->
      DB.Txn.q(txn, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('pending', 0, 1)")
      send(parent, :writer_busy)
      receive do: (:release_writer -> :written)
    end)
  end)

  assert_receive :writer_busy

  reader = Task.async(fn ->
    handler = fn _ ->
      Tightbeam.Assignments.__handle__(db, "assignments", %{
        principal: {:user, "reader"}, session_key: nil, params: %{}
      })
    end

    Dispatch.dispatch(db, %{"assignments" => handler}, %{
      verb: "assignments", origin: "user:reader", session_key: nil, params: %{},
      principal: {:user, "reader"}, firehose_hub: hub
    })
  end)

  try do
    assert {:ok, {:ok, %{assignments: []}}} = Task.yield(reader, 1_000)
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM events WHERE verb='assignments'")
    refute_received {:firehose_notice, _}
  after
    send(db, :release_writer)
  end

  assert {:ok, :written} = Task.await(writer)
  assert {:ok, :barrier} = DB.transaction(db, fn _ -> :barrier end)
  assert {:ok, [["null"]]} = DB.query(db, "SELECT payload FROM events WHERE verb='assignments'")
  assert_receive {:firehose_notice,
                  %{"class" => "verb.accepted", "payload" => %{"verb" => "assignments"}}}
after
  GenServer.stop(db)
end

IO.puts("dispatch-read: ok")
