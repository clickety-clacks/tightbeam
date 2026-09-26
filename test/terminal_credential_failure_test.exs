defmodule Tightbeam.TerminalCredentialFailureTest do
  use Tightbeam.TestCase, async: false

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

  setup context do
    if context[:guard_runtime] do
      :ok
    else
      base_dir =
        Path.join(System.tmp_dir!(), "terminal-credential-#{System.unique_integer([:positive])}")

      File.mkdir_p!(base_dir)
      db = :"terminal_credential_#{System.unique_integer([:positive])}"
      start_supervised!({DB, path: Path.join(base_dir, "state.db"), name: db, guard_inputs: []})
      :ok = Tightbeam.Schema.ensure_all(db)
      :ok = TerminalCredentialFailure.ensure_schema(db)
      on_exit(fn -> File.rm_rf!(base_dir) end)
      %{base_dir: base_dir, db: db}
    end
  end

  test "one open incident owns the canonical statement and current admin delivery", ctx do
    Devices.add_user(ctx.db, "mike", true)

    assert {:opened, incident} = open(ctx.db, "opening-1")
    assert {:existing, %{id: same_id}} = open(ctx.db, "opening-2")
    assert same_id == incident.id

    assert TerminalCredentialFailure.statement(ctx.db, incident.id) ==
             "racter lost codex: its openai credential was rejected. Redirect destination: not yet observed; lawful alternate " <>
               "routing remains enabled. racter needs a human sign-in for codex; run on " <>
               "racter: tightbeam onboard openai --as-user <adminUserId> (replace " <>
               "<adminUserId> with your own administrator id)."

    expected =
      "racter lost codex: its openai credential was rejected. Redirect destination: alternate. racter needs a human sign-in for codex; " <>
        "run on racter: tightbeam onboard openai --as-user <adminUserId> " <>
        "(replace <adminUserId> with your own administrator id)."

    assert {:ok, :recorded} =
             DB.transaction(ctx.db, fn txn ->
               TerminalCredentialFailure.record_redirect_in_txn(
                 txn,
                 incident.id,
                 "spawn:mike:req-1",
                 "alternate"
               )
             end)

    Org.create(ctx.db, %{
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

    assert TerminalCredentialFailure.statement(ctx.db, incident.id) == expected

    assert [view] = TerminalCredentialFailure.views(ctx.db)
    assert view.canonical_statement == expected
    assert view.redirect_destinations == ["alternate"]

    assert [readonly] = TerminalCredentialFailure.readonly_views(ctx.base_dir)
    assert readonly == view

    assert {:ok, [["delivered", message_id]]} =
             DB.query(
               ctx.db,
               "SELECT state,messageId FROM terminal_credential_deliveries WHERE incidentId=?1 AND adminUserId='mike'",
               [incident.id]
             )

    assert {:ok, [[^expected]]} =
             DB.query(ctx.db, "SELECT content FROM messages WHERE id=?1", [message_id])

    assert {:ok, :recorded} =
             DB.transaction(ctx.db, fn txn ->
               TerminalCredentialFailure.record_redirect_in_txn(
                 txn,
                 incident.id,
                 "spawn:mike:req-2",
                 "zeta"
               )
             end)

    updated = String.replace(expected, "alternate.", "alternate, zeta.")

    assert {:ok, [[^updated]]} =
             DB.query(ctx.db, "SELECT content FROM messages WHERE id=?1", [message_id])

    assert {:ok, :duplicate} =
             DB.transaction(ctx.db, fn txn ->
               TerminalCredentialFailure.record_redirect_in_txn(
                 txn,
                 incident.id,
                 "spawn:mike:req-1",
                 "alternate"
               )
             end)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM messages WHERE clientMessageId=?1", [
               incident.statement_id <> ":mike"
             ])

    recovery_fact = credential_fact(ctx.db)
    assert [claim] = TerminalCredentialFailure.claim_recoveries(ctx.db, recovery_fact)

    assert {:resolved, _resolved} =
             TerminalCredentialFailure.finish_recovery(
               ctx.db,
               incident.id,
               claim.fact_id,
               "catalog_published"
             )

    lifecycle_kinds =
      ctx.db
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
               ctx.db,
               "SELECT state,messageId FROM terminal_credential_deliveries WHERE incidentId=?1 AND adminUserId='mike'",
               [incident.id]
             )

    assert TerminalCredentialFailure.views(ctx.db) == []

    assert {:ok, :recorded} =
             DB.transaction(ctx.db, fn txn ->
               TerminalCredentialFailure.record_redirect_in_txn(
                 txn,
                 incident.id,
                 "spawn:mike:req-late-accept",
                 "yarrow"
               )
             end)

    assert TerminalCredentialFailure.views(ctx.db) == []

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM terminal_credential_redirects WHERE incidentId=?1 AND requestIdentity='spawn:mike:req-late-accept' AND destinationHost='yarrow'",
               [incident.id]
             )
  end

  test "rollback documentation names the old-code probe-loop consequence" do
    readme = Path.expand("../README.md", __DIR__) |> File.read!()

    assert readme =~
             "Before rolling back a database that contains terminal credential incidents"

    assert readme =~
             "the automatic provider credential probe loop will return"
  end

  @tag tmp_dir: true, guard_runtime: true
  test "demotion pauses statement updates and re-promotion reuses its identity", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "terminal_credential_admin_lifecycle_runtime.exs",
      "terminal-credential-admin-lifecycle: ok",
      []
    )
  end

  @tag tmp_dir: true, guard_runtime: true
  test "resolution before a personal session prevents stale pending delivery", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "terminal_credential_resolved_pending_runtime.exs",
      "terminal-credential-resolved-pending: ok",
      []
    )
  end

  test "concurrent final results find one open incident and one assertion", ctx do
    ids =
      1..32
      |> Task.async_stream(
        fn n ->
          {:status, incident} =
            case open(ctx.db, "concurrent-opening-#{n}") do
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
               ctx.db,
               "SELECT COUNT(*) FROM terminal_credential_incidents WHERE host='racter' AND harness='codex' AND state='open'"
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='catalog-terminal-credential-failure' AND scope=?1",
               [TerminalCredentialFailure.scope("racter", "codex")]
             )
  end

  test "only newer facts claim recovery and restart resumes a claim once", ctx do
    old_fact = credential_fact(ctx.db)
    assert {:opened, incident} = open(ctx.db, "recovery-opening")
    assert old_fact <= incident.opening_watermark
    assert TerminalCredentialFailure.claim_recoveries(ctx.db, old_fact) == []

    recovery_fact = credential_fact(ctx.db)

    assert [claim] = TerminalCredentialFailure.claim_recoveries(ctx.db, recovery_fact)
    assert claim.incident_id == incident.id
    assert claim.fact_id == recovery_fact
    assert TerminalCredentialFailure.claim_recoveries(ctx.db, recovery_fact) == []

    assert [resume] = TerminalCredentialFailure.resume_recoveries(ctx.db)
    assert resume == claim
    assert TerminalCredentialFailure.resume_recoveries(ctx.db) == []

    assert {:open, failed, nil} =
             TerminalCredentialFailure.finish_recovery(
               ctx.db,
               incident.id,
               recovery_fact,
               "transient_failure"
             )

    assert failed.state == "open"
    assert failed.consumed_fact_id == recovery_fact

    success_fact = credential_fact(ctx.db)
    assert [success_claim] = TerminalCredentialFailure.claim_recoveries(ctx.db, success_fact)

    assert {:resolved, resolved} =
             TerminalCredentialFailure.finish_recovery(
               ctx.db,
               incident.id,
               success_claim.fact_id,
               "catalog_published"
             )

    assert resolved.state == "resolved"
    refute TerminalCredentialFailure.open?(ctx.db, "racter", "codex")
    assert TerminalCredentialFailure.views(ctx.db) == []
  end

  test "startup claims an eligible fact committed before its recognition cast", ctx do
    assert {:opened, incident} = open(ctx.db, "pre-claim-crash")
    fact_id = credential_fact(ctx.db)

    assert [claim] = TerminalCredentialFailure.resume_recoveries(ctx.db)

    assert claim == %{
             incident_id: incident.id,
             host: "racter",
             harness: "codex",
             fact_id: fact_id
           }

    assert TerminalCredentialFailure.resume_recoveries(ctx.db) == [claim]
    assert TerminalCredentialFailure.resume_recoveries(ctx.db) == []
  end

  test "a newer fact racing a failed recovery coalesces to the greatest successor", ctx do
    assert {:opened, incident} = open(ctx.db, "pending-recovery-opening")
    first = credential_fact(ctx.db)
    assert [first_claim] = TerminalCredentialFailure.claim_recoveries(ctx.db, first)

    second = credential_fact(ctx.db)
    third = credential_fact(ctx.db)
    assert TerminalCredentialFailure.claim_recoveries(ctx.db, second) == []
    assert TerminalCredentialFailure.claim_recoveries(ctx.db, third) == []

    assert {:open, still_open, successor} =
             TerminalCredentialFailure.finish_recovery(
               ctx.db,
               incident.id,
               first_claim.fact_id,
               "transient_failure"
             )

    assert still_open.claimed_fact_id == third
    assert successor.fact_id == third

    assert {:ok, [[^first], [^third]]} =
             DB.query(
               ctx.db,
               "SELECT factId FROM terminal_credential_observations WHERE incidentId=?1 AND kind='recovery-claim' ORDER BY factId",
               [incident.id]
             )

    assert {:open, failed_again, nil} =
             TerminalCredentialFailure.finish_recovery(
               ctx.db,
               incident.id,
               successor.fact_id,
               "empty_catalog"
             )

    assert failed_again.recovery_state == "idle"
    assert failed_again.consumed_fact_id == third
  end

  test "normal harness success cannot resolve the separate terminal catalog incident", ctx do
    assert {:opened, incident} = open(ctx.db, "normal-turn-exclusion")

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               HarnessHealth.resolve_normal_turn_in_txn(
                 txn,
                 %{host: "racter", harness: "codex"},
                 %{seq: 42, session_key: "fixture-session", origin: "agent:fixture"}
               )
             end)

    assert TerminalCredentialFailure.get_open(ctx.db, "racter", "codex").id == incident.id
  end

  test "provider task and recovery injector call sites stay fully accounted" do
    catalog_path = Path.expand("../lib/tightbeam/model_catalog.ex", __DIR__)
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
      Path.wildcard(Path.expand("../lib/**/*.ex", __DIR__))
      |> Enum.filter(fn path ->
        path |> File.read!() |> String.contains?("ModelCatalog.credential_transition(")
      end)

    assert transition_sites == [
             Path.expand("../lib/tightbeam/productions/catalog_rederive.ex", __DIR__)
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
