defmodule Tightbeam.HarnessRecoveryTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, HarnessRecovery, Model, Org, Wakes}

  setup do
    db = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    %{db: db}
  end

  test "classifies only named unavailable failures" do
    assert HarnessRecovery.unavailable?(:model_unavailable)
    assert HarnessRecovery.unavailable?({:adapter_unavailable, ":shutdown"})
    assert HarnessRecovery.unavailable?({:model_apply_failed, :model_unavailable})

    assert HarnessRecovery.unavailable?(%{
             "code" => -32603,
             "data" => %{"codexErrorInfo" => %{"code" => "usageLimitExceeded"}}
           })

    refute HarnessRecovery.unavailable?(:closed)
    refute HarnessRecovery.unavailable?(%{"code" => "oauth_org_not_allowed"})
    refute HarnessRecovery.unavailable?("the selected model name is invalid")
  end

  test "first delivered turn closes one episode and schedules one owner-Main wake", %{db: db} do
    create_main(db, "flynn")

    assert :opened =
             observe_failure(db, "flynn", "codex", "worker-a", 10, :model_unavailable, 100)

    assert :opened =
             observe_failure(
               db,
               "flynn",
               "codex",
               "worker-b",
               12,
               {:adapter_unavailable, ":shutdown"},
               120
             )

    assert {:woke, wake_id} = observe_success(db, "flynn", "codex", "worker-c", 15, 150)

    assert %{wake_id: ^wake_id, session_key: main, origin: "process:tightbeam"} =
             Wakes.get(db, wake_id)

    assert main == Org.personal_session_key("flynn")

    wake = Wakes.get(db, wake_id)
    assert wake.state == "pending"
    assert wake.due_at == 150
    assert wake.class == "blocker"
    assert wake.prompt =~ "[harness recovered]"
    assert wake.prompt =~ "installed or learned Kung Fu Main archetypes"
    assert wake.prompt =~ "Tell only affected agents"
    assert wake.prompt =~ "Do not wake unrelated agents"

    assert {:ok, [["closed", 1, 10, 12, 15, ^wake_id]]} =
             DB.query(
               db,
               "SELECT state,generation,openedByTurn,lastFailureTurn,recoveryTurn,recoveryWakeId FROM harness_recovery_episodes"
             )

    assert :no_episode = observe_success(db, "flynn", "codex", "worker-d", 16, 160)
    assert length(Wakes.list_pending(db)) == 1
  end

  test "episodes are scoped by owner and harness, then reopen as a new generation", %{db: db} do
    create_main(db, "flynn")
    create_main(db, "naomi")

    assert :opened =
             observe_failure(db, "flynn", "codex", "flynn-worker", 20, :model_unavailable, 200)

    assert :no_episode = observe_success(db, "naomi", "codex", "naomi-worker", 21, 210)
    assert :no_episode = observe_success(db, "flynn", "claude", "flynn-claude", 22, 220)
    assert Wakes.list_pending(db) == []

    assert {:woke, _first} = observe_success(db, "flynn", "codex", "flynn-worker", 23, 230)

    assert :opened =
             observe_failure(
               db,
               "flynn",
               "codex",
               "flynn-worker",
               30,
               {:adapter_unavailable, :noproc},
               300
             )

    assert {:woke, _second} =
             observe_success(db, "flynn", "codex", "flynn-worker", 31, 310)

    assert {:ok, [["closed", 2, 30, 31]]} =
             DB.query(
               db,
               "SELECT state,generation,openedByTurn,recoveryTurn FROM harness_recovery_episodes WHERE ownerUserId='flynn' AND harness='codex'"
             )

    assert length(Wakes.list_pending(db)) == 2
  end

  test "a missing owner Main leaves the episode open for a later successful turn", %{db: db} do
    assert :opened =
             observe_failure(db, "flynn", "codex", "worker", 40, :model_unavailable, 400)

    assert :no_main = observe_success(db, "flynn", "codex", "worker", 41, 410)
    assert Wakes.list_pending(db) == []

    assert {:ok, [["open", nil]]} =
             DB.query(
               db,
               "SELECT state,recoveryWakeId FROM harness_recovery_episodes WHERE ownerUserId='flynn' AND harness='codex'"
             )

    create_main(db, "flynn")
    assert {:woke, _wake_id} = observe_success(db, "flynn", "codex", "worker", 42, 420)

    assert Enum.any?(Tightbeam.EventLog.lifecycle_events(db), fn event ->
             event.kind == "harness_recovery_wake_undeliverable" and
               event.subject == "flynn/codex"
           end)
  end

  test "an ordinary failed turn does not open an episode", %{db: db} do
    assert :ignored = observe_failure(db, "flynn", "codex", "worker", 50, :bad_prompt, 500)
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM harness_recovery_episodes")
  end

  defp create_main(db, owner) do
    Org.create(db, %{
      session_key: Org.personal_session_key(owner),
      display_name: "#{owner} Main",
      kind: "main",
      is_built_in: true,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "product-owner",
      harness: "codex",
      provider: "openai",
      model: Model.new("gpt-5.6-sol"),
      host: "testhost"
    })
  end

  defp observe_failure(db, owner, harness, session, turn, reason, at) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        HarnessRecovery.observe_failure_in_txn(txn, %{
          owner_user_id: owner,
          harness: harness,
          session_key: session,
          turn_seq: turn,
          reason: reason,
          at: at
        })
      end)

    result
  end

  defp observe_success(db, owner, harness, session, turn, at) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        HarnessRecovery.observe_success_in_txn(txn, %{
          owner_user_id: owner,
          harness: harness,
          session_key: session,
          turn_seq: turn,
          at: at
        })
      end)

    result
  end
end
