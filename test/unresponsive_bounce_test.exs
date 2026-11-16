defmodule Tightbeam.UnresponsiveBounceTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, HarnessHealth, Model, Org}

  setup do
    db = :"unresponsive_bounce_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)
    sender = ensure_main_session(db, "flynn")

    Org.create(db, %{
      session_key: "agent:unresponsive:recipient",
      display_name: "Recipient",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "coder",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    %{db: db, sender: sender.session_key, target: "agent:unresponsive:recipient"}
  end

  test "a parked recipient leaves the source queued and bounces to its sender once", ctx do
    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO harness_park_fences(adapterKey,requestedAt) VALUES('claude:shared@testhost',1)"
             )

    deliver = fn ->
      DB.transaction(ctx.db, fn txn ->
        Gateway.deliver_prompt_in_txn(
          txn,
          ctx.target,
          "user:flynn",
          "Please read this",
          wake_id: "w_unresponsive_source"
        )
      end)
    end

    assert {:ok, first} = deliver.()
    assert match?({:staged, _}, first) or match?({:appended, _, _, _}, first)
    assert {:ok, _duplicate} = deliver.()

    assert {:ok, [[notice, sender, "pending"]]} =
             DB.query(
               ctx.db,
               "SELECT prompt,sessionKey,state FROM wakes WHERE wakeId LIKE 'w_unresponsive_%' AND wakeId!='w_unresponsive_source'"
             )

    assert sender == ctx.sender
    assert notice =~ "has not been read yet"
    assert notice =~ "harness is parked"
    assert notice =~ "original message remains queued"

    case first do
      {:staged, source} -> assert source.state == "pending"
      {:appended, _, _, _} ->
        assert {:ok, [["queued"]]} =
                 DB.query(ctx.db, "SELECT status FROM turns WHERE wakeId='w_unresponsive_source'")
    end
  end

  test "an open harness hold tells the sender why the recipient has not read the message", ctx do
    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider) VALUES('asg_unresponsive_hold','held work',?1,?1,1,'open','claude','anthropic')",
               [ctx.target]
             )

    assert {:ok, {:opened, _incident}} =
             DB.transaction(ctx.db, fn txn ->
               HarnessHealth.observe_in_txn(txn, %{
                 harness: "claude",
                 host: "testhost",
                 failure_class: "auth-dead",
                 evidence_kind: "authoritative-provider",
                 session_key: ctx.target,
                 assignment_id: "asg_unresponsive_hold",
                 observed_at: System.system_time(:millisecond),
                 correlation_id: "unresponsive-hold",
                 cause: "credential refused",
                 principal: "process:tightbeam"
               })
             end)

    assert {:ok, delivery} = deliver_in_txn(ctx, "w_unresponsive_hold_source")
    assert_source_queued(ctx.db, "w_unresponsive_hold_source", delivery)
    assert {:ok, [[notice]]} = bounce_prompts(ctx.db)
    assert notice =~ "held by a harness incident"
  end

  test "a recipient not admitting turns queues the sender notice", ctx do
    :persistent_term.put({Tightbeam.Application, :draining}, true)

    assert {:ok, delivery} = deliver_in_txn(ctx, "w_unresponsive_drain_source")
    assert_source_queued(ctx.db, "w_unresponsive_drain_source", delivery)
    assert {:ok, [[notice]]} = bounce_prompts(ctx.db)
    assert notice =~ "not admitting turns"
  end

  defp deliver_in_txn(ctx, wake_id) do
    DB.transaction(ctx.db, fn txn ->
      Gateway.deliver_prompt_in_txn(
        txn,
        ctx.target,
        "user:flynn",
        "Please read this",
        wake_id: wake_id
      )
    end)
  end

  defp bounce_prompts(db) do
    DB.query(db, "SELECT prompt FROM wakes WHERE wakeId LIKE 'w_unresponsive_%' AND origin='process:tightbeam'")
  end

  defp assert_source_queued(_db, _wake_id, {:staged, source}),
    do: assert(source.state == "pending")

  defp assert_source_queued(db, wake_id, {:appended, _, _, _}) do
    assert {:ok, [["queued"]]} =
             DB.query(db, "SELECT status FROM turns WHERE wakeId=?1", [wake_id])
  end
end
