[payload, base, phase] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions
alias Tightbeam.{DB, RecognitionRestartProbe, Schema}
alias Tightbeam.DB.Txn
{:ok, db} = DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

try do
  :ok = Schema.ensure_all(db)
  publication = %{gate: Path.join(base, "ready"), publication: Path.join(base, "published")}

  case phase do
    "write" ->
      :ok = DB.execute(db, "CREATE TABLE restart_rows(id INTEGER PRIMARY KEY)")
      :ok = DB.execute(db, "CREATE TABLE recognition_gate(ready INTEGER)")

      assert {:ok, :committed} =
               DB.transaction_then(
                 db,
                 fn txn ->
                   Txn.q(txn, "INSERT INTO restart_rows VALUES(1)")
                   :committed
                 end,
                 RecognitionRestartProbe.recognition_callback()
               )

      assert {:ok, ^publication} =
               DB.transaction_then(
                 db,
                 fn _ -> publication end,
                 RecognitionRestartProbe.publication_callback(publication)
               )

      assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM pending_recognition")
      assert {:ok, [[1]]} = DB.query(db, "SELECT id FROM restart_rows")

    "retry" ->
      File.write!(publication.gate, "ready")
      :ok = DB.execute(db, "INSERT INTO recognition_gate VALUES(1)")
      :ok = DB.execute(db, "UPDATE pending_recognition SET nextAt=0")
      retry = :sys.get_state(db).retry

      for _ <- 1..2 do
        send(retry, :retry)
        :sys.get_state(retry)
      end

      assert {:ok, [[1], [2]]} = DB.query(db, "SELECT id FROM restart_rows ORDER BY id")
      assert File.read!(publication.publication) == "published"
      assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM pending_recognition")
  end
after
  GenServer.stop(db)
end

IO.puts("recognition-restart-#{phase}: ok")
