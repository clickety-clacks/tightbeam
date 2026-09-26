[payload, base] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions

alias Tightbeam.{DB, Devices, Model, Org, Schema, TerminalCredentialFailure}

{:ok, hub} = Tightbeam.Firehose.Hub.start_link(name: Tightbeam.Firehose.Hub)
{:ok, db} = DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

try do
  :ok = Schema.ensure_all(db)
  :ok = TerminalCredentialFailure.ensure_schema(db)
  Devices.add_user(db, "mike", true)

  Org.create(db, %{
    session_key: Org.personal_session_key("mike"),
    display_name: "Main",
    kind: "main",
    owner_user_id: "mike",
    origin: "user:mike",
    archetype: "default",
    host: "racter",
    harness: "codex",
    provider: "openai",
    model: Model.new("gpt-fixture")
  })

  assert {:opened, incident} =
           TerminalCredentialFailure.open(db, %{
             host: "racter",
             harness: "codex",
             provider: "openai",
             correlation_id: "admin-lifecycle",
             source_kind: "catalog-final-401",
             principal: "process:tightbeam/model-catalog"
           })

  assert {:ok, [["delivered", message_id]]} =
           DB.query(
             db,
             "SELECT state,messageId FROM terminal_credential_deliveries WHERE incidentId=?1 AND adminUserId='mike'",
             [incident.id]
           )

  assert {:ok, [[initial]]} =
           DB.query(db, "SELECT content FROM messages WHERE id=?1", [message_id])

  refute Devices.set_user_admin(db, "mike", false).is_admin

  assert {:ok, :recorded} =
           DB.transaction(db, fn txn ->
             TerminalCredentialFailure.record_redirect_in_txn(
               txn,
               incident.id,
               "spawn:mike:while-demoted",
               "alternate"
             )
           end)

  assert {:ok, [[^initial]]} =
           DB.query(db, "SELECT content FROM messages WHERE id=?1", [message_id])

  assert Devices.set_user_admin(db, "mike", true).is_admin
  current = TerminalCredentialFailure.statement(db, incident.id)

  assert {:ok, [["delivered", ^message_id]]} =
           DB.query(
             db,
             "SELECT state,messageId FROM terminal_credential_deliveries WHERE incidentId=?1 AND adminUserId='mike'",
             [incident.id]
           )

  assert {:ok, [[^current]]} =
           DB.query(db, "SELECT content FROM messages WHERE id=?1", [message_id])

  assert {:ok, [[1]]} =
           DB.query(db, "SELECT COUNT(*) FROM messages WHERE clientMessageId=?1", [
             incident.statement_id <> ":mike"
           ])
after
  if Process.alive?(db), do: GenServer.stop(db)
  if Process.alive?(hub), do: GenServer.stop(hub)
end

IO.puts("terminal-credential-admin-lifecycle: ok")
