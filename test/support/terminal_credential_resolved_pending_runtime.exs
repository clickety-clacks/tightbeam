[payload, base] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions

alias Tightbeam.{ConditionFacts, DB, Devices, Model, Org, Schema, TerminalCredentialFailure}

{:ok, hub} = Tightbeam.Firehose.Hub.start_link(name: Tightbeam.Firehose.Hub)
{:ok, db} = DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

try do
  :ok = Schema.ensure_all(db)
  :ok = TerminalCredentialFailure.ensure_schema(db)
  Devices.add_user(db, "mike", true)

  assert {:opened, incident} =
           TerminalCredentialFailure.open(db, %{
             host: "racter",
             harness: "codex",
             provider: "openai",
             correlation_id: "resolved-before-session",
             source_kind: "catalog-final-401",
             principal: "process:tightbeam/model-catalog"
           })

  assert {:ok, [["pending", nil]]} =
           DB.query(
             db,
             "SELECT state,messageId FROM terminal_credential_deliveries WHERE incidentId=?1 AND adminUserId='mike'",
             [incident.id]
           )

  assert {:ok, %{fact_id: recovery_fact}} =
           DB.transaction(db, fn txn ->
             ConditionFacts.file_in_txn(txn, %{
               kind: "credential-present",
               scope: "racter:openai",
               origin: "process:tightbeam"
             })
           end)

  assert [claim] = TerminalCredentialFailure.claim_recoveries(db, recovery_fact)

  assert {:resolved, _resolved} =
           TerminalCredentialFailure.finish_recovery(
             db,
             incident.id,
             claim.fact_id,
             "catalog_published"
           )

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

  assert {:ok, [["resolved", nil]]} =
           DB.query(
             db,
             "SELECT state,messageId FROM terminal_credential_deliveries WHERE incidentId=?1 AND adminUserId='mike'",
             [incident.id]
           )

  assert {:ok, [[0]]} =
           DB.query(db, "SELECT COUNT(*) FROM messages WHERE clientMessageId=?1", [
             incident.statement_id <> ":mike"
           ])
after
  if Process.alive?(db), do: GenServer.stop(db)
  if Process.alive?(hub), do: GenServer.stop(hub)
end

IO.puts("terminal-credential-resolved-pending: ok")
