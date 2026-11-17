defmodule Tightbeam.UnresponsiveBounceTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, HarnessHealth, Model, Org}

  defmodule AcceptingLaneManager do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)
    def init(state), do: {:ok, state}
    def handle_call({:ensure_lane, _session_key}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    db = :"unresponsive_bounce_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
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
      {:staged, source} ->
        assert source.state == "pending"

      {:appended, _, _, _} ->
        assert {:ok, [["queued"]]} =
                 DB.query(ctx.db, "SELECT status FROM turns WHERE wakeId='w_unresponsive_source'")
    end
  end

  test "a rate-limit incident with a park fence tells the sender why", ctx do
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
                 failure_class: "rate-limit-dead",
                 evidence_kind: "authoritative-provider",
                 session_key: ctx.target,
                 assignment_id: "asg_unresponsive_hold",
                 observed_at: System.system_time(:millisecond),
                 correlation_id: "unresponsive-hold",
                 cause: "provider usage limit",
                 principal: "process:tightbeam"
               })
             end)

    assert Tightbeam.HarnessProcess.parked?(ctx.db, {:claude, "shared", "testhost"})

    assert {:ok, delivery} = deliver_in_txn(ctx, "w_unresponsive_hold_source")
    assert_source_queued(ctx.db, "w_unresponsive_hold_source", delivery)
    assert {:ok, [[notice]]} = bounce_prompts(ctx.db)
    assert notice =~ "held by a harness incident"
  end

  test "incident membership without a park fence does not claim the recipient is held", ctx do
    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider) VALUES('asg_unresponsive_unparked','affected work',?1,?1,1,'open','claude','anthropic')",
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
                 assignment_id: "asg_unresponsive_unparked",
                 observed_at: System.system_time(:millisecond),
                 correlation_id: "unresponsive-unparked",
                 cause: "credential refused",
                 principal: "process:tightbeam"
               })
             end)

    refute Tightbeam.HarnessProcess.parked?(ctx.db, {:claude, "shared", "testhost"})
    assert {:ok, delivery} = deliver_in_txn(ctx, "w_unresponsive_unparked_source")
    assert_source_queued(ctx.db, "w_unresponsive_unparked_source", delivery)
    assert {:ok, []} = bounce_prompts(ctx.db)
  end

  test "a recipient not admitting turns queues the sender notice", ctx do
    :persistent_term.put({Tightbeam.Application, :draining}, true)

    assert {:ok, delivery} = deliver_in_txn(ctx, "w_unresponsive_drain_source")
    assert_source_queued(ctx.db, "w_unresponsive_drain_source", delivery)
    assert {:ok, [[notice]]} = bounce_prompts(ctx.db)
    assert notice =~ "not admitting turns"
  end

  test "a down lane leaves the original turn and the bounce queued", ctx do
    assert :appended =
             Gateway.deliver_prompt(
               ctx.target,
               "user:flynn",
               "Please read this",
               db: ctx.db,
               wake_id: "w_unresponsive_lane_source",
               lane_manager: :missing_lane_manager
             )

    assert {:ok, [["queued"]]} =
             DB.query(
               ctx.db,
               "SELECT status FROM turns WHERE wakeId='w_unresponsive_lane_source'"
             )

    assert {:ok, [[notice]]} = bounce_prompts(ctx.db)
    assert notice =~ "lane is down"
    assert notice =~ "original message remains queued"
  end

  test "an accepted nudge without a lane registry does not claim the lane is down", ctx do
    lane_manager = start_supervised!(AcceptingLaneManager)
    refute Process.whereis(Tightbeam.LaneRegistry)

    assert :appended =
             Gateway.deliver_prompt(
               ctx.target,
               "user:flynn",
               "Please read this",
               db: ctx.db,
               wake_id: "w_unresponsive_accepted_source",
               lane_manager: lane_manager
             )

    assert {:ok, [["queued"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE wakeId='w_unresponsive_accepted_source'")

    assert {:ok, []} = bounce_prompts(ctx.db)
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
    DB.query(
      db,
      "SELECT prompt FROM wakes WHERE wakeId LIKE 'w_unresponsive_%' AND origin='process:tightbeam'"
    )
  end

  defp assert_source_queued(_db, _wake_id, {:staged, source}),
    do: assert(source.state == "pending")

  defp assert_source_queued(db, wake_id, {:appended, _, _, _}) do
    assert {:ok, [["queued"]]} =
             DB.query(db, "SELECT status FROM turns WHERE wakeId=?1", [wake_id])
  end
end
