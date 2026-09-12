[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:ex_unit, :assert_receive_timeout, 1_000)
import ExUnit.Assertions
alias Tightbeam.{DB, Schema}
path = Path.join(base, "state.db")
{:ok, db} = DB.start_link(path: path, name: nil, guard_inputs: [lock_dir: locks])

try do
  :ok = Schema.ensure_all(db)
  :ok = DB.assert_base_admitted!(db, base)
  marker = File.read!(Path.join(base, "build-owner.json"))
  alias Tightbeam.DeployReadiness, as: Ready
  assert {:ok, [["session-reparent-v1-019"]]} = DB.query(db, "SELECT shape FROM schema_stamp")

  :ok =
    DB.execute(db, """
    INSERT INTO turns(sessionKey,wakeId,messageId,origin,prompt,status,createdAt)
      VALUES ('new-session','new-wake','prompt','process:fixture','DEPLOY READY test','delivered',1);
    INSERT INTO messages(id,sessionKey,replyToMessageId,role,content,timestamp,llmVisibleMessageId)
      VALUES ('wrong','other','prompt','assistant','DEPLOY READY test',1,'wrong');
    """)

  assert [%{"replyId" => nil}] = Ready.observe!(path, "new-session", "new-wake")

  :ok =
    DB.execute(db, """
    INSERT INTO messages(id,sessionKey,replyToMessageId,role,content,timestamp,llmVisibleMessageId)
      VALUES ('answer','new-session','prompt','assistant','DEPLOY READY test',2,'answer');
    """)

  assert [%{"replyId" => "answer", "status" => "delivered"}] =
           Ready.observe!(path, "new-session", "new-wake")

  assert Ready.observe!(path, "new-session", "other-wake") == []
  assert Ready.observe!(path, "other-session", "new-wake") == []
  assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  assert File.read!(Path.join(base, "build-owner.json")) == marker
  :ok = DB.assert_base_admitted!(db, base)
after
  if Process.alive?(db), do: GenServer.stop(db)
end

IO.puts("guarded-readiness-reply-binding: ok")
