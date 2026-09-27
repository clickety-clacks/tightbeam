defmodule Tightbeam.TerminalCredentialCoreFixture do
  @moduledoc false

  import ExUnit.Assertions

  alias Tightbeam.{
    ConditionFacts,
    DB,
    Devices,
    EventLog,
    Firehose.Publisher,
    Firehose.Registry,
    HarnessHealth,
    Model,
    Org,
    TerminalCredentialFailure
  }

  def proof!("statement-delivery", db, base) do
    Devices.add_user(db, "mike", true)

    assert {:opened, incident} = open(db, "opening-1")
    assert {:existing, %{id: same_id}} = open(db, "opening-2")
    assert same_id == incident.id

    assert TerminalCredentialFailure.statement(db, incident.id) ==
             "racter lost codex: its openai credential was rejected. Redirect destination: not yet observed; lawful alternate " <>
               "routing remains enabled. racter needs a human sign-in for codex; run on " <>
               "racter: tightbeam onboard openai --as-user <adminUserId> (replace " <>
               "<adminUserId> with your own administrator id)."

    expected =
      "racter lost codex: its openai credential was rejected. Redirect destination: alternate. racter needs a human sign-in for codex; " <>
        "run on racter: tightbeam onboard openai --as-user <adminUserId> " <>
        "(replace <adminUserId> with your own administrator id)."

    assert {:ok, :recorded} =
             DB.transaction(db, fn txn ->
               TerminalCredentialFailure.record_redirect_in_txn(
                 txn,
                 incident.id,
                 "spawn:mike:req-1",
                 "alternate"
               )
             end)

    Org.create(db, %{
      session_key: Org.personal_session_key("mike"),
      display_name: "Main",
      kind: "main",
      owner_user_id: "mike",
      origin: "user:mike",
      archetype: "default",
      host: "alternate",
      harness: "codex",
      provider: "openai",
      model: Model.new("gpt-fixture")
    })

    assert TerminalCredentialFailure.statement(db, incident.id) == expected

    assert [view] = TerminalCredentialFailure.views(db)
    assert view.canonical_statement == expected
    assert view.redirect_destinations == ["alternate"]

    assert {:ok, [["delivery-owner-reparent-v1-019"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert [readonly] = TerminalCredentialFailure.readonly_views(base)
    assert readonly == view

    assert {:ok, [["delivered", message_id]]} =
             DB.query(
               db,
               "SELECT state,messageId FROM terminal_credential_deliveries WHERE incidentId=?1 AND adminUserId='mike'",
               [incident.id]
             )

    assert {:ok, [[^expected]]} =
             DB.query(db, "SELECT content FROM messages WHERE id=?1", [message_id])

    assert {:ok, :recorded} =
             DB.transaction(db, fn txn ->
               TerminalCredentialFailure.record_redirect_in_txn(
                 txn,
                 incident.id,
                 "spawn:mike:req-2",
                 "zeta"
               )
             end)

    updated = String.replace(expected, "alternate.", "alternate, zeta.")

    assert {:ok, [[^updated]]} =
             DB.query(db, "SELECT content FROM messages WHERE id=?1", [message_id])

    assert {:ok, :duplicate} =
             DB.transaction(db, fn txn ->
               TerminalCredentialFailure.record_redirect_in_txn(
                 txn,
                 incident.id,
                 "spawn:mike:req-1",
                 "alternate"
               )
             end)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM messages WHERE clientMessageId=?1", [
               incident.statement_id <> ":mike"
             ])

    recovery_fact = credential_fact(db)
    assert [claim] = TerminalCredentialFailure.claim_recoveries(db, recovery_fact)

    assert {:resolved, _resolved} =
             TerminalCredentialFailure.finish_recovery(
               db,
               incident.id,
               claim.fact_id,
               "catalog_published"
             )

    lifecycle_kinds =
      db
      |> EventLog.lifecycle_events()
      |> Enum.filter(&(&1.subject == incident.id))
      |> MapSet.new(& &1.kind)

    assert MapSet.subset?(
             MapSet.new([
               "terminal_credential_opened",
               "terminal_credential_suppression_activated",
               "terminal_credential_redirect_observed",
               "terminal_credential_recovery_claimed",
               "terminal_credential_recovery_outcome",
               "terminal_credential_resolved"
             ]),
             lifecycle_kinds
           )

    for kind <- lifecycle_kinds do
      assert ("lifecycle." <> kind) in Registry.observational_classes()

      notice = %{
        "class" => "lifecycle." <> kind,
        "op" => "observe",
        "payload" => %{"incidentId" => incident.id}
      }

      assert Publisher.wire_notice(notice) == notice
    end

    assert {:ok, [["resolved", ^message_id]]} =
             DB.query(
               db,
               "SELECT state,messageId FROM terminal_credential_deliveries WHERE incidentId=?1 AND adminUserId='mike'",
               [incident.id]
             )

    assert TerminalCredentialFailure.views(db) == []

    assert {:ok, :recorded} =
             DB.transaction(db, fn txn ->
               TerminalCredentialFailure.record_redirect_in_txn(
                 txn,
                 incident.id,
                 "spawn:mike:req-late-accept",
                 "yarrow"
               )
             end)

    assert TerminalCredentialFailure.views(db) == []

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM terminal_credential_redirects WHERE incidentId=?1 AND requestIdentity='spawn:mike:req-late-accept' AND destinationHost='yarrow'",
               [incident.id]
             )
  end

  def proof!("rollback-documentation", _db, _base) do
    readme = Path.expand("../../README.md", __DIR__) |> File.read!()

    assert readme =~
             "Before rolling back a database that contains terminal credential incidents"

    assert readme =~
             "the automatic provider credential probe loop will return"
  end

  def proof!("concurrent-open", db, _base) do
    ids =
      1..32
      |> Task.async_stream(
        fn n ->
          {:status, incident} =
            case open(db, "concurrent-opening-#{n}") do
              {:opened, incident} -> {:status, incident}
              {:existing, incident} -> {:status, incident}
            end

          incident.id
        end,
        max_concurrency: 16,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, id} -> id end)

    assert ids |> MapSet.new() |> MapSet.size() == 1

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM terminal_credential_incidents WHERE host='racter' AND harness='codex' AND state='open'"
             )

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='catalog-terminal-credential-failure' AND scope=?1",
               [TerminalCredentialFailure.scope("racter", "codex")]
             )
  end

  def proof!("newer-fact-recovery", db, _base) do
    old_fact = credential_fact(db)
    assert {:opened, incident} = open(db, "recovery-opening")
    assert old_fact <= incident.opening_watermark
    assert TerminalCredentialFailure.claim_recoveries(db, old_fact) == []

    recovery_fact = credential_fact(db)

    assert [claim] = TerminalCredentialFailure.claim_recoveries(db, recovery_fact)
    assert claim.incident_id == incident.id
    assert claim.fact_id == recovery_fact
    assert TerminalCredentialFailure.claim_recoveries(db, recovery_fact) == []

    assert [resume] = TerminalCredentialFailure.resume_recoveries(db)
    assert resume == claim
    assert TerminalCredentialFailure.resume_recoveries(db) == []

    assert {:open, failed, nil} =
             TerminalCredentialFailure.finish_recovery(
               db,
               incident.id,
               recovery_fact,
               "transient_failure"
             )

    assert failed.state == "open"
    assert failed.consumed_fact_id == recovery_fact

    success_fact = credential_fact(db)
    assert [success_claim] = TerminalCredentialFailure.claim_recoveries(db, success_fact)

    assert {:resolved, resolved} =
             TerminalCredentialFailure.finish_recovery(
               db,
               incident.id,
               success_claim.fact_id,
               "catalog_published"
             )

    assert resolved.state == "resolved"
    refute TerminalCredentialFailure.open?(db, "racter", "codex")
    assert TerminalCredentialFailure.views(db) == []
  end

  def proof!("startup-recovery", db, _base) do
    assert {:opened, incident} = open(db, "pre-claim-crash")
    fact_id = credential_fact(db)

    assert [claim] = TerminalCredentialFailure.resume_recoveries(db)

    assert claim == %{
             incident_id: incident.id,
             host: "racter",
             harness: "codex",
             fact_id: fact_id
           }

    assert TerminalCredentialFailure.resume_recoveries(db) == [claim]
    assert TerminalCredentialFailure.resume_recoveries(db) == []
  end

  def proof!("racing-recovery", db, _base) do
    assert {:opened, incident} = open(db, "pending-recovery-opening")
    first = credential_fact(db)
    assert [first_claim] = TerminalCredentialFailure.claim_recoveries(db, first)

    second = credential_fact(db)
    third = credential_fact(db)
    assert TerminalCredentialFailure.claim_recoveries(db, second) == []
    assert TerminalCredentialFailure.claim_recoveries(db, third) == []

    assert {:open, still_open, successor} =
             TerminalCredentialFailure.finish_recovery(
               db,
               incident.id,
               first_claim.fact_id,
               "transient_failure"
             )

    assert still_open.claimed_fact_id == third
    assert successor.fact_id == third

    assert {:ok, [[^first], [^third]]} =
             DB.query(
               db,
               "SELECT factId FROM terminal_credential_observations WHERE incidentId=?1 AND kind='recovery-claim' ORDER BY factId",
               [incident.id]
             )

    assert {:open, failed_again, nil} =
             TerminalCredentialFailure.finish_recovery(
               db,
               incident.id,
               successor.fact_id,
               "empty_catalog"
             )

    assert failed_again.recovery_state == "idle"
    assert failed_again.consumed_fact_id == third
  end

  def proof!("normal-turn-exclusion", db, _base) do
    assert {:opened, incident} = open(db, "normal-turn-exclusion")

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               HarnessHealth.resolve_normal_turn_in_txn(
                 txn,
                 %{host: "racter", harness: "codex"},
                 %{seq: 42, session_key: "fixture-session", origin: "agent:fixture"}
               )
             end)

    assert TerminalCredentialFailure.get_open(db, "racter", "codex").id == incident.id
  end

  def proof!("call-site-accounting", _db, _base) do
    catalog_path = Path.expand("../../lib/tightbeam/model_catalog.ex", __DIR__)
    {:ok, ast} = catalog_path |> File.read!() |> Code.string_to_quoted(file: catalog_path)

    {_ast, task_bodies} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Task]}, starter]}, _, _args} = node, found
        when starter in [:start, :start_link] ->
          {node, [Macro.to_string(node) | found]}

        node, found ->
          {node, found}
      end)

    assert length(task_bodies) == 2
    assert Enum.all?(task_bodies, &String.contains?(&1, "safely_derive"))
    assert Enum.any?(task_bodies, &(&1 =~ "Task.start(" and &1 =~ ":catalog_refresh"))
    assert Enum.any?(task_bodies, &(&1 =~ "Task.start(" and &1 =~ ":catalog_recovery"))

    transition_sites =
      Path.wildcard(Path.expand("../../lib/**/*.ex", __DIR__))
      |> Enum.filter(fn path ->
        path |> File.read!() |> String.contains?("ModelCatalog.credential_transition(")
      end)

    assert transition_sites == [
             Path.expand("../../lib/tightbeam/productions/catalog_rederive.ex", __DIR__)
           ]
  end

  defp open(db, correlation_id) do
    TerminalCredentialFailure.open(db, %{
      host: "racter",
      harness: "codex",
      provider: "openai",
      correlation_id: correlation_id,
      source_kind: "catalog-final-401",
      principal: "process:tightbeam/model-catalog"
    })
  end

  defp credential_fact(db) do
    assert {:ok, %{fact_id: fact_id}} =
             DB.transaction(db, fn txn ->
               ConditionFacts.file_in_txn(txn, %{
                 kind: "credential-present",
                 scope: "racter:openai",
                 origin: "process:tightbeam"
               })
             end)

    fact_id
  end
end
