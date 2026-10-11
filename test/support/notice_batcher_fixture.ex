defmodule Tightbeam.NoticeBatcherFixture.LaneStub do
  use GenServer
  def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
  @impl true
  def init(:ok), do: {:ok, :ok}
  @impl true
  def handle_call({:ensure_lane, _session}, _from, state), do: {:reply, :ok, state}
end

defmodule Tightbeam.NoticeBatcherFixture do
  @moduledoc false
  import ExUnit.Assertions
  import Tightbeam.TestCase, only: [ensure_all_schemas: 1, ensure_main_session: 2]

  alias Tightbeam.{
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    Ledger,
    NoticeBatcher,
    Org,
    Roles,
    Schema,
    Wakes
  }

  def run!(tmp, scenario) do
    %{executable: executable, args: args, env: env} =
      Tightbeam.GuardRuntimeFixture.prepare!(tmp, "notice_batcher_runtime.exs")

    {output, status} =
      System.cmd(executable, args ++ [Integer.to_string(scenario)],
        env: env,
        stderr_to_stdout: true
      )

    File.write!(Path.join(tmp, "runtime.log"), output)
    assert status == 0, output
    assert output =~ "notice-batcher-case: #{scenario}: ok"
  end

  def run_case!(scenario, base) do
    {:ok, db} =
      DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

    # The child owns these local delivery services; no adapter or live lane starts.
    {:ok, registry} = ConnRegistry.start_link(name: Tightbeam.ConnRegistry)
    {:ok, lane} = Tightbeam.NoticeBatcherFixture.LaneStub.start_link(Tightbeam.LaneManager)
    Process.put({__MODULE__, :db}, db)
    Process.put({__MODULE__, :schedulers}, [])

    try do
      :ok = ensure_all_schemas(db)
      :ok = DB.assert_base_admitted!(db, base)
      seed_session(db, "agent:recipient", "recipient-owner")
      marker = File.read!(Path.join(base, "build-owner.json"))
      scenario(scenario, db)
      assert File.read!(Path.join(base, "build-owner.json")) == marker
    after
      for scheduler <- Process.get({__MODULE__, :schedulers}, []) do
        if Process.alive?(scheduler), do: GenServer.stop(scheduler)
      end

      current_db = Process.get({__MODULE__, :db})
      if Process.alive?(current_db), do: GenServer.stop(current_db)
      if Process.alive?(lane), do: GenServer.stop(lane)
      if Process.alive?(registry), do: GenServer.stop(registry)
    end

    IO.puts("notice-batcher-case: #{scenario}: ok")
  end

  defp scenario(0, db) do
    first = eligible(db, prompt: "alpha")
    second = eligible(db, prompt: "beta")
    [carrier_id] = Wakes.materialize_digests(db, second.due_at)
    carrier = Wakes.get(db, carrier_id)

    assert carrier.prompt =~ first.wake_id
    assert carrier.prompt =~ second.wake_id
    assert carrier.prompt =~ "alpha"
    assert carrier.prompt =~ "beta"
    assert source_ids(db, carrier_id) == [first.wake_id, second.wake_id]

    {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [carrier_id])
    scheduler = start_scheduler(db, fn wake -> deliver(db, wake) end)
    assert :ok = Wakes.fire_due(scheduler)
    assert count(db, "turns", "wakeId=?1", [carrier_id]) == 1
  end

  defp scenario(1, db) do
    routine = eligible(db, prompt: "routine")

    user =
      Wakes.schedule(db, %{
        session_key: "agent:recipient",
        origin: "user:mike",
        prompt: "human message",
        due_at: 0,
        class: "fyi"
      })

    assert NoticeBatcher.source_refs(db, routine.wake_id) == []
    assert NoticeBatcher.source_refs(db, user.wake_id) == []
    assert count(db, "notice_batches") == 0
    scheduler = start_scheduler(db, fn wake -> deliver(db, wake) end)
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(db, user.wake_id).state == "fired"

    assert [%{batch_id: user_batch_id, member_state: "included", batch_state: "delivered"}] =
             NoticeBatcher.source_refs(db, user.wake_id)

    assert user_batch_id == batch_id(db, routine)
    assert count(db, "turns", "wakeId IN (SELECT deliveryWakeId FROM notice_batches)") == 1
    assert length(NoticeBatcher.members(db, batch_id(db, routine))) == 2
  end

  defp scenario(2, db) do
    routine = eligible(db)

    for class <- ~w(input-needed blocker algedonic) do
      wake = ordinary(db, class, "urgent #{class}")
      assert NoticeBatcher.source_refs(db, wake.wake_id) == []
    end

    agent_fyi = ordinary(db, "fyi", "pre-v2 agent message")
    assert NoticeBatcher.source_refs(db, agent_fyi.wake_id) == []
    assert NoticeBatcher.source_refs(db, routine.wake_id) == []
    assert count(db, "notice_batches") == 0

    _carriers = Wakes.materialize_digests(db, agent_fyi.due_at)

    assert NoticeBatcher.batch(db, batch_id(db, routine)).member_count == 5
  end

  defp scenario(3, db) do
    routine = eligible(db)
    blocker = ordinary(db, "blocker", "stop")

    assert NoticeBatcher.source_refs(db, routine.wake_id) == []
    assert NoticeBatcher.source_refs(db, blocker.wake_id) == []
    assert count(db, "notice_batches") == 0

    _carriers = Wakes.materialize_digests(db, blocker.due_at)
    batch = NoticeBatcher.batch(db, batch_id(db, routine))

    assert batch.member_count == 2
    assert batch.rendered_bytes > byte_size(routine.prompt)
    assert batch.due_at == routine.due_at
  end

  defp scenario(4, db) do
    status =
      Wakes.schedule(db, %{
        session_key: "agent:recipient",
        origin: "process:tightbeam",
        consumer: "internal",
        prompt: "rows answer",
        due_at: 0,
        class: "status-query"
      })

    assert NoticeBatcher.source_refs(db, status.wake_id) == []
    assert count(db, "notice_batch_members") == 0
    assert count(db, "notice_batches") == 0
  end

  defp scenario(5, db) do
    source = eligible(db)
    assert Wakes.materialize_digests(db, source.due_at - 1) == []
    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    batch = NoticeBatcher.batch(db, batch_id(db, source))

    assert batch.state == "delivered"
    assert batch.release_cause == "idle"
    assert batch.delivery_wake_id == carrier_id
    assert count(db, "decision_requests") == 0
  end

  defp scenario(6, db) do
    running_seq = running_turn(db, "agent:recipient")
    source = eligible(db)
    boundary = source.created_at + 5
    assert NoticeBatcher.recover(db, source.due_at) == []
    assert NoticeBatcher.source_refs(db, source.wake_id) == []
    finish_running_turn(db, running_seq, boundary)
    [carrier_id] = Wakes.materialize_digests(db, boundary + 1)

    assert Wakes.get(db, carrier_id).due_at == boundary + 1
    assert NoticeBatcher.batch(db, batch_id(db, source)).release_cause == "turn-boundary"
    assert source.due_at < boundary
  end

  defp scenario(7, db) do
    first = eligible(db, prompt: "first")
    terminal_turn(db, first.session_key, first.created_at + 1)

    insert = Task.async(fn -> eligible(db, prompt: "racing") end)
    seal = Task.async(fn -> Wakes.materialize_digests(db, first.created_at + 2) end)
    later = Task.await(insert)
    _ = Task.await(seal)
    finish_queued_turns!(db, "agent:recipient")
    _ = Wakes.materialize_digests(db, later.due_at)

    assert count(db, "notice_batch_members", "sourceWakeId=?1", [later.wake_id]) == 1
    assert length(NoticeBatcher.source_refs(db, later.wake_id)) == 1
  end

  defp scenario(8, db) do
    sources = for payload <- ~w(one two three), do: eligible(db, prompt: payload)
    stamp = hd(sources).created_at

    for source <- sources do
      {:ok, _} =
        DB.query(db, "UPDATE wakes SET createdAt=?2 WHERE wakeId=?1", [source.wake_id, stamp])
    end

    [carrier_id] = Wakes.materialize_digests(db, List.last(sources).due_at)
    assert source_ids(db, carrier_id) == Enum.map(sources, & &1.wake_id)
  end

  defp scenario(9, db) do
    sources = for n <- 1..51, do: eligible(db, prompt: "notice #{n}")
    assert_capacity_hold!(db, sources, hd(sources).due_at)
    last = List.last(sources)
    withdraw!(db, last)
    [carrier] = NoticeBatcher.recover(db, hd(sources).due_at)
    ids = Enum.map(Enum.take(sources, 50), & &1.wake_id)
    assert_actual_carrier!(db, carrier, ids)
    batch = NoticeBatcher.batch(db, batch_id(db, hd(sources)))
    assert batch.member_count == 50
    assert batch.release_cause == "idle"
    assert NoticeBatcher.source_refs(db, last.wake_id) == []
    assert Wakes.get(db, last.wake_id).state == "canceled"
    assert count(db, "notice_batches") == 1
  end

  defp scenario(10, db) do
    first = eligible(db, prompt: String.duplicate("a", 1_000))
    payload = String.duplicate("b", 65_000)
    candidate = eligible(db, prompt: payload)
    assert_capacity_hold!(db, [first, candidate], candidate.due_at)
    assert Wakes.get(db, candidate.wake_id).prompt == payload
    withdraw!(db, first)
    [carrier] = NoticeBatcher.recover(db, candidate.due_at)
    assert [%{payload: ^payload}] = NoticeBatcher.members(db, batch_id(db, candidate))
    assert_actual_carrier!(db, carrier, [candidate.wake_id])
    assert count(db, "notice_batches") == 1
    assert NoticeBatcher.source_refs(db, first.wake_id) == []
  end

  defp scenario(11, db) do
    sources = for n <- 1..51, do: eligible(db, prompt: "boundary notice #{n}")
    boundary = List.last(sources).created_at + 1
    terminal_turn(db, hd(sources).session_key, boundary)
    assert_capacity_hold!(db, sources, boundary)
    # This is a later eligibility boundary, never an automatic capped prefix.
    last = List.last(sources)

    {:ok, []} =
      DB.query(db, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1", [last.wake_id, boundary + 100])

    [first_carrier] = NoticeBatcher.recover(db, boundary)
    assert_actual_carrier!(db, first_carrier, Enum.map(Enum.take(sources, 50), & &1.wake_id))
    first_batch = NoticeBatcher.batch(db, batch_id(db, hd(sources)))
    assert first_batch.release_cause == "turn-boundary"
    assert Wakes.get(db, first_carrier).due_at == boundary
    assert NoticeBatcher.source_refs(db, last.wake_id) == []
    finish_queued_turns!(db, "agent:recipient")
    [last_carrier] = NoticeBatcher.recover(db, boundary + 100)
    assert_actual_carrier!(db, last_carrier, [last.wake_id])
    assert first_carrier != last_carrier
    assert count(db, "notice_batches") == 2

    assert Enum.any?(EventLog.lifecycle_events(db), fn event ->
             event.kind == "wake_digest_materialized" and event.subject == first_carrier and
               event.detail =~ "trigger=session-readiness"
           end)
  end

  defp scenario(12, db) do
    source = eligible(db)
    ref = NoticeBatcher.policy_ref(source.wake_id)
    first = NoticeBatcher.enqueue_or_recover(db, source.wake_id, ref)
    second = NoticeBatcher.enqueue_or_recover(db, source.wake_id, ref)
    assert first == second
    assert {:deferred, %{code: "recipient_readiness_required"}} = first
    assert count(db, "notice_batch_members") == 0
    [carrier] = NoticeBatcher.recover(db, source.due_at)
    refs = NoticeBatcher.source_refs(db, source.wake_id)
    assert NoticeBatcher.recover(db, source.due_at) == []
    assert NoticeBatcher.source_refs(db, source.wake_id) == refs
    assert count(db, "notice_batch_members", "sourceWakeId=?1", [source.wake_id]) == 1
    assert_actual_carrier!(db, carrier, [source.wake_id])
  end

  defp scenario(13, db) do
    source = eligible(db)
    # A storage fault rolls back the whole admission, including carrier and turn.
    :ok =
      DB.execute(
        db,
        "CREATE TRIGGER transient_notice_failure BEFORE INSERT ON turns BEGIN SELECT RAISE(ABORT, 'transient delivery failure'); END;"
      )

    assert NoticeBatcher.recover(db, source.due_at) == []
    assert Wakes.get(db, source.wake_id).state == "pending"
    assert count(db, "notice_batches") == 0
    assert count(db, "notice_batch_members") == 0
    assert count(db, "wakes", "digest=1") == 0
    assert count(db, "turns") == 0
    :ok = DB.execute(db, "DROP TRIGGER transient_notice_failure;")
    [carrier] = NoticeBatcher.recover(db, source.due_at)
    assert_actual_carrier!(db, carrier, [source.wake_id])
    batch = NoticeBatcher.batch(db, batch_id(db, source))
    assert batch.state == "delivered"
    assert batch.retry_count == 0
    assert NoticeBatcher.recover(db, source.due_at) == []
    assert count(db, "turns", "wakeId=?1", [carrier]) == 1

    seed_session(db, "agent:unresolved", "unresolved-owner")
    unresolved = eligible(db, session: "agent:unresolved")
    {old_batch, old_carrier} = historical_transport!(db, unresolved)

    {:ok, []} =
      DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        unresolved.session_key
      ])

    assert NoticeBatcher.recover(db, unresolved.due_at) == []
    failed = NoticeBatcher.batch(db, old_batch)
    assert failed.state == "delivery_failed"
    assert failed.terminal_cause == "recipient-readiness-regroup"
    assert failed.terminal_principal == "process:tightbeam:wake-scheduler"
    assert failed.retry_count == 0
    assert Wakes.get(db, old_carrier).state == "fired"
    assert deliver(db, Wakes.get(db, unresolved.wake_id)) == :skipped
    assert Wakes.get(db, unresolved.wake_id).state == "pending"
    assert count(db, "turns", "sessionKey=?1", [unresolved.session_key]) == 0
    assert NoticeBatcher.recover(db, unresolved.due_at) == []
    assert NoticeBatcher.batch(db, old_batch) == failed
  end

  defp scenario(14, db) do
    source = eligible(db)
    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    assert_actual_carrier!(db, carrier_id, [source.wake_id])

    assert NoticeBatcher.recover(db, source.due_at + 1) == []
    assert NoticeBatcher.batch(db, batch_id(db, source)).state == "delivered"
    assert count(db, "wakes", "wakeId=?1", [carrier_id]) == 1
    assert count(db, "turns", "wakeId=?1", [carrier_id]) == 1
  end

  defp scenario(15, db) do
    source = eligible(db, prompt: "sealed")
    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    before = Wakes.get(db, carrier_id).prompt
    later = eligible(db, prompt: "later")

    assert NoticeBatcher.source_refs(db, later.wake_id) == []
    assert Wakes.get(db, carrier_id).prompt == before

    finish_queued_turns!(db, source.session_key)
    _carriers = Wakes.materialize_digests(db, later.due_at)
    assert batch_id(db, later) != batch_id(db, source)

    assert NoticeBatcher.members(db, batch_id(db, later)) |> Enum.map(& &1.source_wake_id) ==
             [later.wake_id]
  end

  defp scenario(16, db) do
    seed_session(db, "agent:cancel-before", "cancel-before-owner")
    seed_session(db, "agent:cancel-after", "cancel-after-owner")

    early =
      eligible(db,
        session: "agent:cancel-before",
        origin: "agent:sender",
        prompt: "exclude"
      )

    assert {:ok, {:accepted_in_txn, _event_id, %{canceled: true}}} =
             DB.transaction(db, fn txn ->
               Wakes.cancel_in_txn(txn, requester_withdrawal(early))
             end)

    assert Wakes.get(db, early.wake_id).state == "canceled"

    assert {:ok, [["requester_withdrew", "no_replacement"]]} =
             DB.query(
               db,
               "SELECT reasonKind, outcomeKind FROM wake_cancellations WHERE wakeId=?1",
               [early.wake_id]
             )

    assert NoticeBatcher.source_refs(db, early.wake_id) == []
    assert count(db, "notice_batches") == 0

    sealed =
      eligible(db,
        session: "agent:cancel-after",
        origin: "agent:sender",
        prompt: "immutable"
      )

    [carrier_id] = Wakes.materialize_digests(db, sealed.due_at)
    envelope = Wakes.get(db, carrier_id).prompt

    before = Wakes.get(db, sealed.wake_id)
    assert before.state == "fired"

    assert {:ok, false} =
             DB.transaction(db, fn txn ->
               Wakes.cancel_in_txn(txn, requester_withdrawal(sealed))
             end)

    assert Wakes.get(db, sealed.wake_id) == before
    assert count(db, "wake_cancellations", "wakeId=?1", [sealed.wake_id]) == 0
    assert_actual_carrier!(db, carrier_id, [sealed.wake_id])
    assert Wakes.get(db, carrier_id).prompt == envelope
    assert [%{state: "included"}] = NoticeBatcher.members(db, batch_id(db, sealed))
  end

  defp scenario(17, db) do
    seed_session(db, "agent:scope-a", "owner-a")
    seed_session(db, "agent:scope-b", "owner-b")
    Roles.create!(db, "shared", "owner-a", "agent:scope-a")

    first =
      manual_member(db, "role:shared:scope-a",
        target_role: "shared",
        session: "agent:scope-a",
        due_at: 0
      )

    second =
      manual_member(db, "role:shared:scope-b",
        target_role: "shared",
        session: "agent:scope-b",
        due_at: 0
      )

    [carrier] = NoticeBatcher.recover(db, second.due_at)
    batch = batch_id(db, first)
    assert batch_id(db, second) == batch
    assert_actual_carrier!(db, carrier, [first.wake_id, second.wake_id])
    # A concrete-session carrier cannot disclose a subset of mixed-owner sources.
    assert NoticeBatcher.read_batch(db, batch, {:user, "owner-a"}) == nil
    assert NoticeBatcher.read_batch(db, batch, {:user, "owner-b"}) == nil

    assert {:ok,
            [["agent:scope-a", "role:shared:scope-a"], ["agent:scope-b", "role:shared:scope-b"]]} =
             DB.query(
               db,
               "SELECT sessionKey,sourceVisibilityScope FROM wakes WHERE wakeId IN (?1,?2) ORDER BY rowid",
               [first.wake_id, second.wake_id]
             )

    assert count(db, "turns", "sessionKey='agent:scope-a'") == 1
    assert count(db, "turns", "sessionKey='agent:scope-b'") == 0
  end

  defp scenario(18, db) do
    seed_session(db, "agent:desk", "owner")
    Roles.create!(db, "exec-desk", "owner", "agent:desk")
    source = eligible(db, target_role: "exec-desk", session: "agent:desk")
    [carrier] = Wakes.materialize_digests(db, source.due_at)
    assert_actual_carrier!(db, carrier, [source.wake_id])
    assert Wakes.get(db, carrier).session_key == "agent:desk"
    assert Wakes.get(db, source.wake_id).target_role == "exec-desk"

    assert {:ok, [["agent:desk", prompt]]} =
             DB.query(db, "SELECT sessionKey,prompt FROM turns WHERE wakeId=?1", [carrier])

    assert prompt =~ source.wake_id

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM sqlite_schema WHERE type='table' AND name LIKE 'exec_desk%'"
             )
  end

  defp scenario(19, db) do
    {:ok, tables} =
      DB.query(
        db,
        "SELECT name FROM sqlite_schema WHERE type='table' AND (name LIKE 'recurrence_%' OR name LIKE 'production_%' OR name='turns') ORDER BY name"
      )

    before = Map.new(tables, fn [table] -> {table, count(db, table)} end)
    assert NoticeBatcher.recover(db, System.system_time(:millisecond)) == []
    after_counts = Map.new(tables, fn [table] -> {table, count(db, table)} end)

    assert after_counts == before
    assert count(db, "notice_batch_members") == 0
  end

  defp scenario(20, db) do
    lane = [session: "agent:rollback"]
    seed_session(db, "agent:rollback", "rollback-owner")
    legacy_disabled = set_lane_policy(db, lane, false)
    refute legacy_disabled.enabled
    assert legacy_disabled.effective_enabled
    source = fyi(db, lane)
    assert source.delivery_rule == NoticeBatcher.rule()
    assert NoticeBatcher.source_refs(db, source.wake_id) == []
    assert_retired_tables_absent!(db)
    [carrier] = Wakes.materialize_digests(db, source.due_at)
    assert_actual_carrier!(db, carrier, [source.wake_id])
    assert NoticeBatcher.batch(db, batch_id(db, source)).member_count == 1
    assert_retired_tables_absent!(db)
  end

  defp scenario(21, db) do
    seed_session(db, "agent:legacy-recipient", "legacy-owner")

    source =
      Wakes.schedule(db, %{
        session_key: "agent:legacy-recipient",
        origin: "process:tightbeam",
        creator_session_key: "agent:legacy-recipient",
        prompt: "default-off legacy payload",
        due_at: 0,
        class: "fyi"
      })

    assert source.delivery_rule == NoticeBatcher.rule()
    assert NoticeBatcher.source_refs(db, source.wake_id) == []
    assert Wakes.self_pending_count(db, source.session_key) == 0

    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    carrier = Wakes.get(db, carrier_id)

    assert carrier.delivery_rule == NoticeBatcher.rule()
    assert carrier.prompt =~ "coalesced by notice-batching-v1 r2"

    assert Enum.any?(EventLog.lifecycle_events(db), fn event ->
             event.kind == "wake_digest_materialized" and event.subject == carrier_id and
               event.detail =~ "rule=notice-batching-v1 r2"
           end)
  end

  defp scenario(22, db) do
    first = manual_member(db, "deadline-scope", due_at: 9_000)
    second = manual_member(db, "deadline-scope", due_at: 4_000)
    assert NoticeBatcher.recover(db, 3_999) == []
    [carrier] = NoticeBatcher.recover(db, 4_000)
    assert_actual_carrier!(db, carrier, [second.wake_id])
    assert NoticeBatcher.batch(db, batch_id(db, second)).due_at == 4_000
    assert Wakes.get(db, carrier).due_at == 4_000
    assert Wakes.get(db, first.wake_id).state == "pending"
    assert NoticeBatcher.source_refs(db, first.wake_id) == []
    finish_queued_turns!(db, "agent:recipient")
    [later_carrier] = NoticeBatcher.recover(db, 9_000)
    assert_actual_carrier!(db, later_carrier, [first.wake_id])
    assert later_carrier != carrier
  end

  defp scenario(23, db) do
    lane = [session: "agent:payload-floor"]
    seed_session(db, "agent:payload-floor", "payload-floor-owner")
    set_lane_policy(db, lane, false)

    source =
      fyi(
        db,
        Keyword.merge(lane, wake_id: "w_payload_floor", prompt: String.duplicate("x", 65_536))
      )

    assert byte_size(source.prompt) == 65_536
    assert source.delivery_rule == NoticeBatcher.rule()
    assert_retired_tables_absent!(db)
    assert_capacity_hold!(db, [source], source.due_at)
    later = fyi(db, Keyword.put(lane, :prompt, "fits after withdrawal"))
    assert_capacity_hold!(db, [source, later], later.due_at)
    assert Wakes.get(db, source.wake_id).prompt == source.prompt
    assert Wakes.get(db, source.wake_id).delivery_rule == NoticeBatcher.rule()
    withdraw!(db, source)
    [carrier] = Wakes.materialize_digests(db, later.due_at)
    assert_actual_carrier!(db, carrier, [later.wake_id])
    assert_retired_tables_absent!(db)
  end

  defp scenario(24, db) do
    fitting_id = "w_rendered_boundary_fit"
    overflow_id = "w_rendered_boundary_over"
    fitting_header = rendered_member_header(fitting_id)
    overflow_header = rendered_member_header(overflow_id)
    seed_session(db, "agent:rendered-fit", "rendered-fit-owner")
    seed_session(db, "agent:rendered-over", "rendered-over-owner")

    fitting =
      eligible(db,
        session: "agent:rendered-fit",
        wake_id: fitting_id,
        prompt: String.duplicate("a", 65_536 - byte_size(fitting_header))
      )

    assert NoticeBatcher.source_refs(db, fitting.wake_id) == []
    [fitting_carrier] = Wakes.materialize_digests(db, fitting.due_at)
    fitting_batch_id = batch_id(db, fitting)

    assert [%{rendered_bytes: 65_536}] = NoticeBatcher.members(db, fitting_batch_id)
    assert NoticeBatcher.batch(db, fitting_batch_id).delivery_wake_id == fitting_carrier

    overflow =
      eligible(db,
        session: "agent:rendered-over",
        wake_id: overflow_id,
        prompt: String.duplicate("b", 65_537 - byte_size(overflow_header))
      )

    assert overflow.delivery_rule == NoticeBatcher.rule()
    assert Wakes.get(db, overflow.wake_id).state == "pending"
    assert NoticeBatcher.source_refs(db, overflow.wake_id) == []
    assert_capacity_hold!(db, [overflow], overflow.due_at)
    assert Wakes.get(db, overflow.wake_id).delivery_rule == NoticeBatcher.rule()
    assert Wakes.get(db, overflow.wake_id).prompt == overflow.prompt
    assert_actual_carrier!(db, fitting_carrier, [fitting.wake_id])
  end

  defp scenario(25, db) do
    payload = "line one\nline two\n \t"
    source = eligible(db, wake_id: "w_trailing_payload", prompt: payload)
    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    envelope = Wakes.get(db, carrier_id).prompt

    assert envelope =~ rendered_member_header(source.wake_id) <> payload <> "\n\n"
  end

  defp scenario(26, db) do
    {:ok, _} = Application.ensure_all_started(:plug)
    seed_session(db, "agent:sender-session", "owner")
    seed_session(db, "agent:other-session", "other")
    Roles.create!(db, "sender", "owner", "agent:sender-session")
    owner_session = Org.personal_session_key("owner")
    Roles.create!(db, "recipient", "owner", owner_session)

    sender = Org.get(db, "agent:sender-session")
    scheduler = start_scheduler(db, fn _wake -> true end)

    router =
      Tightbeam.Wire.Router.init(
        db: db,
        cli_token: "tbc_test",
        handlers: Gateway.handlers(%{db: db, wake_scheduler: scheduler}),
        session_status: fn _ -> nil end
      )

    owner_busy = running_turn(db, owner_session)
    other_session = Org.personal_session_key("other")
    other_busy = running_turn(db, other_session)
    user = public_information(router, sender, "userId", "owner")
    session = public_information(router, sender, "sessionKey", owner_session)
    role = public_information(router, sender, "role", "recipient")
    other = public_information(router, sender, "userId", "other")

    assert Enum.map([user, session, role], &Wakes.get(db, &1).session_key) == [
             owner_session,
             owner_session,
             owner_session
           ]

    for wake_id <- [user, session, role, other] do
      source = Wakes.get(db, wake_id)
      assert source.class == "information"
      assert source.class_election == "sender"
      assert source.creator_session_key == sender.session_key
      assert source.origin == "agent:sender"
      assert NoticeBatcher.source_refs(db, wake_id) == []
    end

    addresses =
      for wake_id <- [user, session, role] do
        {:ok, [[address]]} =
          DB.query(db, "SELECT sourceAddress FROM wakes WHERE wakeId=?1", [wake_id])

        address
      end

    assert addresses == ["user:owner", "session:" <> owner_session, "role:recipient"]
    assert_retired_tables_absent!(db)
    assert count(db, "notice_batches") == 0
    at = Enum.max(Enum.map([user, session, role, other], &Wakes.get(db, &1).due_at))
    finish_running_turn(db, owner_busy, at)
    finish_running_turn(db, other_busy, at)
    carriers = NoticeBatcher.recover(db, at)
    assert length(carriers) == 2
    batch_ids = Enum.map([user, session, role], &batch_id(db, Wakes.get(db, &1)))
    assert length(Enum.uniq(batch_ids)) == 1
    owner_batch = hd(batch_ids)

    assert Enum.map(NoticeBatcher.members(db, owner_batch), & &1.source_wake_id) == [
             user,
             session,
             role
           ]

    assert Enum.all?(NoticeBatcher.members(db, owner_batch), &(&1.class == "information"))
    assert NoticeBatcher.read_batch(db, owner_batch, {:user, "owner"}).member_count == 3
    assert NoticeBatcher.read_batch(db, owner_batch, {:user, "other"}) == nil
    other_batch = batch_id(db, Wakes.get(db, other))
    refute other_batch in batch_ids

    assert [%{source_wake_id: ^other, class: "information"}] =
             NoticeBatcher.members(db, other_batch)

    assert NoticeBatcher.read_batch(db, other_batch, {:user, "owner"}) == nil
    assert NoticeBatcher.read_batch(db, other_batch, {:user, "other"}).member_count == 1
    owner_carrier = NoticeBatcher.batch(db, owner_batch).delivery_wake_id
    assert_actual_carrier!(db, owner_carrier, [user, session, role])
    assert Wakes.get(db, owner_carrier).session_key == owner_session
    assert Wakes.get(db, owner_carrier).prompt =~ "class=information"
    refute Wakes.get(db, owner_carrier).prompt =~ other
    other_carrier = NoticeBatcher.batch(db, other_batch).delivery_wake_id
    assert_actual_carrier!(db, other_carrier, [other])
    assert :ok = Wakes.fire_due(scheduler)
    assert count(db, "turns", "wakeId IN (SELECT deliveryWakeId FROM notice_batches)") == 2
  end

  defp scenario(27, db) do
    user =
      Wakes.schedule(db, %{
        session_key: "agent:recipient",
        origin: "user:mike",
        prompt: "human note",
        due_at: 0,
        class: "fyi"
      })

    dispatch = ordinary(db, "information", "dispatch note")
    query = ordinary(db, "status-query", "status query")
    decision = ordinary(db, "input-needed", "decision needed")
    blocker = ordinary(db, "blocker", "blocked")
    alarm = ordinary(db, "algedonic", "alarm")

    unclassed =
      Wakes.schedule(db, %{
        session_key: "agent:recipient",
        origin: "agent:sender",
        creator_session_key: "agent:sender",
        prompt: "unclassified prompt",
        due_at: 0
      })

    sources = [user, dispatch, query, decision, blocker, alarm, unclassed]
    assert Enum.all?(sources, &(NoticeBatcher.source_refs(db, &1.wake_id) == []))
    assert count(db, "notice_batches") == 0

    [carrier_id] = Wakes.materialize_digests(db, user.due_at)
    batch_ids = Enum.map(sources, &batch_id(db, &1))
    assert length(Enum.uniq(batch_ids)) == 1
    assert_retired_tables_absent!(db)

    batch_key = hd(batch_ids)
    assert NoticeBatcher.batch(db, batch_key).state == "delivered"
    assert is_binary(NoticeBatcher.batch(db, batch_key).envelope)

    assert Enum.map(NoticeBatcher.members(db, batch_key), & &1.class) ==
             ["algedonic", "blocker", "input-needed", "status-query", "fyi", "information", "fyi"]

    assert Enum.all?(NoticeBatcher.members(db, batch_key), &(&1.state == "included"))

    assert Wakes.get(db, unclassed.wake_id).class == "fyi"
    assert Wakes.get(db, unclassed.wake_id).class_election == "classifier"

    carrier = Wakes.get(db, carrier_id)

    assert carrier.prompt =~ "source=#{alarm.wake_id}"
    assert carrier.prompt =~ "class=algedonic"
    assert carrier.prompt =~ "source=#{user.wake_id}"
    assert carrier.prompt =~ "sender=user:mike"
    assert carrier.prompt =~ "class=information"

    assert source_ids(db, carrier_id) == [
             alarm.wake_id,
             blocker.wake_id,
             decision.wake_id,
             query.wake_id,
             user.wake_id,
             dispatch.wake_id,
             unclassed.wake_id
           ]
  end

  defp scenario(28, db) do
    running_seq = running_turn(db, "agent:recipient")
    first = ordinary(db, "blocker", "withdraw while recipient is busy")
    second = ordinary(db, "fyi", "keep for the next turn")

    assert NoticeBatcher.source_refs(db, first.wake_id) == []
    assert NoticeBatcher.source_refs(db, second.wake_id) == []
    assert count(db, "notice_batches") == 0
    assert NoticeBatcher.recover(db, System.system_time(:millisecond)) == []

    assert {:ok, {:accepted_in_txn, _event_id, %{canceled: true}}} =
             DB.transaction(db, fn txn ->
               Wakes.cancel_in_txn(txn, requester_withdrawal(first))
             end)

    boundary = System.system_time(:millisecond) + 10
    finish_running_turn(db, running_seq, boundary)

    [carrier_id] = NoticeBatcher.recover(db, boundary + 1)
    batch_key = batch_id(db, second)
    batch = NoticeBatcher.batch(db, batch_key)

    assert batch.state == "delivered"
    assert batch.release_cause == "turn-boundary"
    assert NoticeBatcher.members(db, batch_key) |> Enum.map(& &1.state) == ["included"]
    assert Wakes.get(db, carrier_id).prompt =~ second.wake_id
    refute Wakes.get(db, carrier_id).prompt =~ first.wake_id
    assert source_ids(db, carrier_id) == [second.wake_id]
  end

  defp scenario(29, db) do
    source = eligible(db, prompt: "cold-restart source")
    {old_batch, old_carrier} = historical_transport!(db, source)
    old_envelope = Wakes.get(db, old_carrier).prompt
    base = Application.fetch_env!(:tightbeam, :base_dir)
    marker = File.read!(Path.join(base, "build-owner.json"))
    :ok = GenServer.stop(db)

    {:ok, reopened} =
      DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

    Process.put({__MODULE__, :db}, reopened)
    :ok = Schema.ensure_all(reopened)
    :ok = DB.assert_base_admitted!(reopened, base)
    [carrier] = NoticeBatcher.recover(reopened, source.due_at)
    assert carrier != old_carrier
    assert_actual_carrier_history!(reopened, carrier, source.wake_id)
    assert NoticeBatcher.batch(reopened, old_batch).state == "delivery_failed"
    assert Wakes.get(reopened, old_carrier).prompt == old_envelope
    assert count(reopened, "turns", "wakeId=?1", [old_carrier]) == 0
    assert NoticeBatcher.recover(reopened, source.due_at) == []
    assert count(reopened, "turns", "wakeId=?1", [carrier]) == 1
    assert File.read!(Path.join(base, "build-owner.json")) == marker
    assert {:ok, []} = DB.query(reopened, "PRAGMA foreign_key_check")
  end

  defp assert_actual_carrier_history!(db, carrier, source) do
    assert source_ids(db, carrier) == [source]
    assert count(db, "turns", "wakeId=?1", [carrier]) == 1
    assert Wakes.get(db, source).state == "fired"

    assert [
             %{member_state: "canceled", batch_state: "delivery_failed"},
             %{member_state: "included", delivery_wake_id: ^carrier, batch_state: "delivered"}
           ] =
             NoticeBatcher.source_refs(db, source)
  end

  defp public_information(router, sender, field, value) do
    body = %{
      "verb" => "wake",
      "as" => "sender",
      field => value,
      "params" => %{"prompt" => "typed recipient report", "class" => "information"}
    }

    response =
      Plug.Test.conn(:post, "/agent/dispatch", JSON.encode!(body))
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sender.cli_token}")
      |> Plug.Conn.put_req_header(
        "x-tightbeam-cli-version",
        Tightbeam.CliCompatibility.required_version()
      )
      |> Tightbeam.Wire.Router.call(router)

    assert response.status == 200, response.resp_body
    %{"result" => %{"wakeId" => wake_id}} = JSON.decode!(response.resp_body)
    wake_id
  end

  defp eligible(db, opts \\ []) do
    fyi(db, opts)
  end

  defp fyi(db, opts) do
    input = %{
      session_key: Keyword.get(opts, :session, "agent:recipient"),
      target_role: Keyword.get(opts, :target_role),
      origin: Keyword.get(opts, :origin, "process:tightbeam"),
      creator_session_key: "agent:sender",
      prompt: Keyword.get(opts, :prompt, "routine"),
      due_at: Keyword.get(opts, :due_at, 0),
      class: Keyword.get(opts, :class, "fyi")
    }

    input =
      case Keyword.fetch(opts, :wake_id) do
        {:ok, wake_id} -> Map.put(input, :wake_id, wake_id)
        :error -> input
      end

    Wakes.schedule(db, input)
  end

  defp rendered_member_header(wake_id) do
    "[1] source=#{wake_id} sender=process:tightbeam cause=wake class=fyi\n"
  end

  defp set_lane_policy(db, opts, enabled) do
    lane = %{
      session_key: Keyword.get(opts, :session, "agent:recipient"),
      target_role: Keyword.get(opts, :target_role),
      target_user_id: Keyword.get(opts, :target_user_id)
    }

    seq = System.unique_integer([:positive, :monotonic])

    {:ok, policy} =
      DB.transaction(db, fn txn ->
        Org.apply_notice_batching_lane_policy_in_txn(
          txn,
          lane,
          enabled,
          "notice-batching-test-policy:#{seq}",
          "agent:test-policy",
          "acceptance-fixture",
          seq
        )
      end)

    policy
  end

  defp ordinary(db, class, prompt) do
    Wakes.schedule(db, %{
      session_key: "agent:recipient",
      origin: "agent:sender",
      creator_session_key: "agent:sender",
      prompt: prompt,
      due_at: 0,
      class: class
    })
  end

  defp requester_withdrawal(wake) do
    %{
      wake_id: wake.wake_id,
      expected_origin: wake.origin,
      requester: %{kind: "session", id: "agent:sender"},
      reason_kind: "requester_withdrew",
      causal_source: %{
        kind: "verb_call",
        accepted_event: %{
          origin: wake.origin,
          session_key: "agent:sender",
          principal: {:session, "agent:sender"}
        }
      },
      outcome: %{kind: "no_replacement"}
    }
  end

  defp manual_member(db, scope, opts) do
    wake =
      Wakes.schedule(db, %{
        session_key: Keyword.get(opts, :session, "agent:recipient"),
        target_role: Keyword.get(opts, :target_role),
        origin: "process:tightbeam",
        creator_session_key: "agent:sender",
        prompt: Keyword.get(opts, :prompt, "manual"),
        due_at: Keyword.get(opts, :due_at, 10_000),
        visibility_scope: scope,
        sender_scheduled: true,
        class: "fyi"
      })

    enabled = Keyword.get(opts, :enabled, true)

    {:ok, result} =
      DB.transaction(db, fn txn ->
        ref =
          NoticeBatcher.record_policy_in_txn(txn, wake,
            visibility_scope: scope,
            enabled: enabled
          )

        NoticeBatcher.enqueue_or_recover_in_txn(txn, wake.wake_id, ref)
      end)

    assert {:deferred, %{code: "recipient_readiness_required"}} = result
    assert NoticeBatcher.source_refs(db, wake.wake_id) == []
    wake
  end

  defp batch_id(db, source) do
    [%{batch_id: batch_id}] = NoticeBatcher.source_refs(db, source.wake_id)
    batch_id
  end

  defp source_ids(db, carrier_id),
    do: Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id)

  defp terminal_turn(db, session_key, ended_at) do
    seq = running_turn(db, session_key)
    finish_running_turn(db, seq, ended_at)
    seq
  end

  defp running_turn(db, session_key) do
    message = "notice-busy-#{System.unique_integer([:positive])}"

    assert {:ok, seq} =
             Ledger.enqueue(db, %{
               session_key: session_key,
               message_id: message,
               origin: "agent:recipient",
               prompt: "owned busy fixture"
             })

    assert {:ok, %{seq: ^seq, owner_lease: lease}} =
             Ledger.claim_next(db, session_key, "notice-fixture")

    Process.put({__MODULE__, :lease, seq}, lease)
    seq
  end

  defp finish_running_turn(db, seq, ended_at) do
    lease = Process.delete({__MODULE__, :lease, seq})
    assert is_binary(lease)
    assert :ok = Ledger.finish(db, seq, "delivered", nil, owner_lease: lease)
    # Only the deterministic eligibility clock is fixture-controlled.
    assert {:ok, []} =
             DB.query(db, "UPDATE turns SET endedAt=?2 WHERE seq=?1 AND status='delivered'", [
               seq,
               ended_at
             ])

    assert {:ok, [["delivered", ^ended_at]]} =
             DB.query(db, "SELECT status,endedAt FROM turns WHERE seq=?1", [seq])
  end

  defp deliver(db, wake) do
    Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
      db: db,
      wake_id: wake.wake_id,
      sender: wake.origin,
      target_gate: if(wake.target_gate == 0, do: nil, else: wake),
      fire_wake_in_txn: true
    )
  end

  defp assert_actual_carrier!(db, carrier, sources) do
    assert source_ids(db, carrier) == sources
    assert count(db, "turns", "wakeId=?1", [carrier]) == 1

    assert count(
             db,
             "turns",
             "wakeId IN (" <> Enum.map_join(sources, ",", fn _ -> "?" end) <> ")",
             sources
           ) == 0

    assert Wakes.get(db, carrier).state == "fired"

    for source <- sources do
      assert Wakes.get(db, source).state == "fired"

      assert [%{delivery_wake_id: ^carrier, member_state: "included", batch_state: "delivered"}] =
               NoticeBatcher.source_refs(db, source)
    end
  end

  defp assert_capacity_hold!(db, sources, at) do
    assert NoticeBatcher.recover(db, at) == []

    for source <- sources do
      current = Wakes.get(db, source.wake_id)
      assert current.state == "pending"
      assert current.prompt == source.prompt
      assert current.delivery_rule == NoticeBatcher.rule()
      assert NoticeBatcher.source_refs(db, source.wake_id) == []
      assert count(db, "turns", "wakeId=?1", [source.wake_id]) == 0
    end

    assert count(db, "notice_batches", "sessionKey=?1", [hd(sources).session_key]) == 0

    assert count(db, "turns", "sessionKey=?1 AND wakeId IS NOT NULL", [hd(sources).session_key]) ==
             0

    assert Enum.any?(EventLog.lifecycle_events(db), fn event ->
             event.kind == "notice_session_capacity_refused" and
               event.subject == hd(sources).session_key and event.detail =~ "decision=dr_58874264"
           end)
  end

  defp assert_retired_tables_absent!(db) do
    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM sqlite_schema WHERE type='table' AND name IN ('notice_delivery_policies','notice_batching_lane_policies','staged_message_dedupes','notice_batch_source_attachments')"
             )
  end

  defp withdraw!(db, source) do
    assert {:ok, {:accepted_in_txn, _, %{canceled: true}}} =
             DB.transaction(db, fn txn ->
               Wakes.cancel_in_txn(txn, requester_withdrawal(source))
             end)

    assert Wakes.get(db, source.wake_id).state == "canceled"
  end

  defp finish_queued_turns!(db, session) do
    case Ledger.claim_next(db, session, "notice-fixture") do
      {:ok, turn} ->
        assert :ok = Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)
        finish_queued_turns!(db, session)

      :none ->
        :ok

      other ->
        flunk("expected an owned queued turn or empty lane: #{inspect(other)}")
    end
  end

  # Captured predecessor transport is historical input, never a normal admission API.
  defp historical_transport!(db, source) do
    batch = "historical-batch:" <> source.wake_id
    carrier = "historical-carrier:" <> source.wake_id
    frozen = "historical sealed bytes\n" <> source.prompt

    Wakes.schedule(db, %{
      wake_id: carrier,
      session_key: source.session_key,
      origin: "process:tightbeam",
      prompt: frozen,
      due_at: source.due_at,
      class: "fyi",
      digest: true,
      target_gate: source.target_gate
    })

    {:ok, [[address, scope]]} =
      DB.query(db, "SELECT sourceAddress,sourceVisibilityScope FROM wakes WHERE wakeId=?1", [
        source.wake_id
      ])

    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO notice_batches(batchId,recipientAddress,sessionKey,visibilityScope,policyRevision,
                 state,dueAt,openedAt,sealedAt,releaseCause,deliveryToken,envelope,envelopeSha256,deliveryWakeId,memberCount,renderedBytes)
               VALUES(?1,?2,?3,?4,'captured-predecessor','delivery_pending',?5,?6,?6,'idle',?7,?8,?9,?10,1,?11)
               """,
               [
                 batch,
                 address,
                 source.session_key,
                 scope,
                 source.due_at,
                 source.created_at,
                 "historical-token:" <> source.wake_id,
                 frozen,
                 Base.encode16(:crypto.hash(:sha256, frozen), case: :lower),
                 carrier,
                 byte_size(frozen)
               ]
             )

    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO notice_batch_members(memberId,batchId,sourceWakeId,policyRef,recipientAddress,
                 visibilityScope,publicationSeq,policyRevision,senderPrincipal,cause,class,payload,renderedBytes,state,addedAt)
               VALUES(?1,?2,?3,?4,?5,?6,1,'captured-predecessor',?7,'wake','fyi',?8,?9,'included',?10)
               """,
               [
                 "historical-member:" <> source.wake_id,
                 batch,
                 source.wake_id,
                 NoticeBatcher.policy_ref(source.wake_id),
                 address,
                 scope,
                 source.origin,
                 source.prompt,
                 byte_size(source.prompt),
                 source.created_at
               ]
             )

    assert count(db, "turns", "wakeId=?1", [carrier]) == 0
    {batch, carrier}
  end

  defp start_scheduler(db, deliver) do
    name = :"notice_scheduler_#{System.unique_integer([:positive])}"
    {:ok, pid} = Wakes.start_link(db: db, name: name, tick_ms: 60_000, deliver: deliver)
    Process.put({__MODULE__, :schedulers}, [pid | Process.get({__MODULE__, :schedulers}, [])])
    pid
  end

  defp count(db, table, where \\ nil, params \\ []) do
    clause = if where, do: " WHERE " <> where, else: ""
    {:ok, [[value]]} = DB.query(db, "SELECT COUNT(*) FROM #{table}#{clause}", params)
    value
  end

  defp seed_session(db, session_key, owner) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT OR IGNORE INTO users (userId, isAdmin, creationKind, createdAt) VALUES (?1, 0, 'admin_add', 1)",
        [owner]
      )

    ensure_main_session(db, owner)

    Tightbeam.Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "coder",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable"),
      host: Tightbeam.Placement.local_host_name()
    })

    :ok
  end
end
