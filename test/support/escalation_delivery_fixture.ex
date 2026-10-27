defmodule Tightbeam.EscalationDeliveryFixture do
  @moduledoc """
  Proofs for spec escalation-delivery-v1 — a decision request and its
  notification are one durable intent.

  Every property asserted here lives on OUR side of the ACP seam: SQL
  atomicity, wake durability, dedupe, and the composition root's own delivery
  wiring. Delivery always runs through the REAL `Tightbeam.Wakes` child that
  `Gateway.children_after_preflight/1` returns, so the closure under test is
  production's, never a stand-in. The only staged pathologies are an aborting
  SQLite trigger and a raising/exiting delivery function — both of which exist
  to make a crash window deterministic.
  """
  import ExUnit.Assertions
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    DB,
    Escalation,
    Gateway,
    Ledger,
    NoticeBatcher,
    Org,
    Placement,
    Wakes,
    WorkItems
  }

  @origin "process:tightbeam"

  defmodule Doorbell do
    @moduledoc "Records which registry/lane-manager a delivery actually reached."
    use GenServer

    def start_link({parent, tag, name}),
      do: GenServer.start_link(__MODULE__, {parent, tag}, name: name)

    def init(state), do: {:ok, state}

    def handle_call({:publish_message, key, _owner, _seq, _payload, _deliver}, _from, state) do
      {parent, tag} = state
      send(parent, {:published, tag, key})
      {:reply, :ok, state}
    end

    def handle_call({:broadcast, _owner, _payload, _deliver}, _from, state) do
      {:reply, :ok, state}
    end

    def handle_call({:ensure_lane, key}, _from, state) do
      {parent, tag} = state
      send(parent, {:lane_nudged, tag, key})
      {:reply, :ok, state}
    end

    # Work-state and work-item doorbells are not this proof's subject.
    def handle_call(_other, _from, state), do: {:reply, :ok, state}
  end

  def run_case!(scenario, base) do
    {:ok, fixtures} = Supervisor.start_link([], strategy: :one_for_one)
    Process.put({__MODULE__, :supervisor}, fixtures)
    Process.put({__MODULE__, :dbs}, [])
    db = open_db!(base)

    try do
      seed_world!(db)
      :ok = DB.assert_base_admitted!(db, base)
      marker = File.read!(Path.join(base, "build-owner.json"))

      for {tag, name} <- [
            {:default_registry, Tightbeam.ConnRegistry},
            {:default_lanes, Tightbeam.LaneManager}
          ] do
        start_supervised!(%{id: name, start: {Doorbell, :start_link, [{self(), tag, name}]}})
      end

      scenario(scenario, %{db: db, base_dir: base, config: config(base, db)})
      assert File.read!(Path.join(base, "build-owner.json")) == marker
    after
      if Process.alive?(fixtures), do: Supervisor.stop(fixtures)
      for db <- Process.get({__MODULE__, :dbs}), Process.alive?(db), do: GenServer.stop(db)
    end

    IO.puts("escalation_delivery-case: #{scenario}: ok")
  end

  defp open_db!(base) do
    {:ok, db} =
      DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

    Process.put({__MODULE__, :dbs}, [db | Process.get({__MODULE__, :dbs}, [])])
    db
  end

  ## Proof 1 — statute atomicity

  defp scenario(0, ctx) do
    call = statute_call()

    # FAIL-BEFORE: with the prompt-wake insert aborting, the whole intent dies.
    block_prompt_wakes!(ctx.db)
    assert_aborts!(fn -> Escalation.escalate(ctx.db, call, statute(), escalation_ctx()) end)

    assert count(ctx.db, "SELECT COUNT(*) FROM decision_requests") == 0
    assert notification_wakes(ctx.db) == []

    # PASS-AFTER: the retry commits both.
    unblock_prompt_wakes!(ctx.db)

    assert {:decision_pending, id} =
             Escalation.escalate(ctx.db, call, statute(), escalation_ctx())

    assert count(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE status='open'") == 1

    owner_session = Org.personal_session_key("flynn")

    assert [
             %{
               session_key: ^owner_session,
               consumer: "prompt",
               state: "pending",
               target_gate: 0,
               origin: @origin
             } = wake
           ] = notification_wakes(ctx.db)

    assert wake.due_at <= System.system_time(:millisecond)
    assert wake.prompt =~ "Decision #{id} pending on review."
  end

  defp scenario(1, ctx) do
    call = operator_call()

    block_prompt_wakes!(ctx.db)
    assert_aborts!(fn -> Escalation.operator_ask(ctx.db, call) end)

    assert count(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE kind='operator'") == 0
    assert notification_wakes(ctx.db) == []

    unblock_prompt_wakes!(ctx.db)
    request = Escalation.operator_ask(ctx.db, call)

    assert request.kind == "operator"
    assert request.status == "open"
    assert request.deadline_wake_id == nil

    assert [%{session_key: main, consumer: "prompt", target_gate: 0, state: "pending"} = wake] =
             notification_wakes(ctx.db)

    assert main == Org.personal_session_key("flynn")
    assert wake.prompt =~ request.id
    assert wake.prompt =~ "ship window?"
  end

  ## Proof 4 — crash before delivery, boot recovery

  defp scenario(4, ctx) do
    db = ctx.db

    # Commit the request and its due notification with NO scheduler running,
    # then take the DB process down: the crash window the spec names.
    assert {:decision_pending, id} =
             Escalation.escalate(db, statute_call(), statute(), escalation_ctx())

    assert [%{state: "pending"} = wake] = notification_wakes(db)
    assert count(db, "SELECT COUNT(*) FROM turns") == 0
    GenServer.stop(db)

    # FAIL-BEFORE: without the Wakes child nothing recovers. The window has to be
    # long enough that a recovery which DID happen would have been seen, so it is
    # denominated in the PASS-AFTER leg's own measured latency, not in a round
    # number. That leg — same fixture, same 25ms boot tick — fires this wake in
    # 27-52ms on this box at load 24 and 32-129ms at load 42, i.e. one to five
    # ticks. The 20 periods below are 500ms, ~4x the slowest recovery yet
    # observed, so a producer on anything like that cadence lands inside the
    # window rather than after it.
    restarted = open_db!(ctx.base_dir)
    :ok = DB.assert_base_admitted!(restarted, ctx.base_dir)

    assert consistently(fn -> Wakes.get(restarted, wake.wake_id).state == "pending" end)

    # PASS-AFTER: the exact gateway child, no operator verb, no fire_due/1.
    {Wakes, opts} = wakes_child(config(ctx.base_dir, restarted) |> Map.put(:wake_tick_ms, 25))
    name = :"delivery_boot_#{System.unique_integer([:positive])}"
    start_supervised!({Wakes, Keyword.put(opts, :name, name)}, id: name)

    assert eventually(fn -> delivery_wake(restarted, wake).state == "fired" end)

    carrier = delivery_wake(restarted, wake)

    assert rows(restarted, "SELECT wakeId FROM turns WHERE wakeId = ?1", [carrier.wake_id]) == [
             [carrier.wake_id]
           ]

    assert count(restarted, "SELECT COUNT(*) FROM decision_requests WHERE id = ?1", [id]) == 1
  end

  ## Proof 5 — failure before durable acceptance stays observable

  defp scenario(5, ctx) do
    assert {:decision_pending, _id} =
             Escalation.escalate(ctx.db, statute_call(), statute(), escalation_ctx())

    [wake] = notification_wakes(ctx.db)
    owner_session = Org.personal_session_key("flynn")

    # Fail the NORMAL path at its actual durable turn admission. The legacy
    # callback below is still exercised separately; normal sources never use it.
    assert :ok =
             DB.execute(ctx.db, """
             CREATE TRIGGER refuse_escalation_carrier BEFORE INSERT ON turns
             WHEN EXISTS (
               SELECT 1 FROM notice_batches b JOIN notice_batch_members m ON m.batchId=b.batchId
               WHERE b.deliveryWakeId=NEW.wakeId AND m.sourceWakeId='#{wake.wake_id}'
             )
             BEGIN SELECT RAISE(ABORT,'forced escalation readiness failure'); END
             """)

    assert {:ok, before_source} =
             DB.query(ctx.db, "SELECT * FROM wakes WHERE wakeId=?1", [wake.wake_id])

    drain!(ctx)
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"

    assert {:ok, ^before_source} =
             DB.query(ctx.db, "SELECT * FROM wakes WHERE wakeId=?1", [wake.wake_id])

    assert NoticeBatcher.source_refs(ctx.db, wake.wake_id) == []

    for table <- ["turns", "messages", "notice_batches", "notice_batch_members"] do
      assert count(ctx.db, "SELECT COUNT(*) FROM #{table}") == 0
    end

    # Both original failure modes remain live controls on supported legacy
    # digest carriers, with no reinterpretation of normal source admission.
    for {tag, failure} <- [
          {:raise, fn _wake -> raise "delivery down" end},
          {:exit, fn _wake -> exit(:delivery_down) end}
        ] do
      probe =
        Wakes.schedule(ctx.db, %{
          session_key: owner_session,
          origin: "process:tightbeam",
          prompt: "#{tag} callback control",
          due_at: wake.due_at,
          target_gate: 0,
          digest: true,
          class: "fyi",
          delivery_rule: "turn-boundary-digest r1"
        })

      name = :"delivery_broken_#{tag}_#{System.unique_integer([:positive])}"
      attempts = :counters.new(1, [])

      failing = fn current ->
        assert current.wake_id == probe.wake_id
        :counters.add(attempts, 1, 1)
        failure.(current)
      end

      start_supervised!({Wakes, db: ctx.db, name: name, tick_ms: 60_000, deliver: failing},
        id: name
      )

      :ok = Wakes.fire_due(name)
      stop_supervised!(name)

      assert :counters.get(attempts, 1) == 1
      assert Wakes.get(ctx.db, probe.wake_id).state == "pending"
      assert Wakes.get(ctx.db, wake.wake_id).state == "pending", "#{tag} consumed the wake"
      assert Enum.any?(Wakes.list_pending(ctx.db), &(&1.wake_id == wake.wake_id))
      assert Wakes.pending_count(ctx.db, owner_session) >= 1
      assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [wake.wake_id]) == 0
      assert NoticeBatcher.source_refs(ctx.db, wake.wake_id) == []
      parent = self()
      healthy = :"delivery_healthy_#{tag}_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Wakes,
         db: ctx.db,
         name: healthy,
         tick_ms: 60_000,
         deliver: fn current ->
           send(parent, {:callback_retry, current.wake_id})
           :ok
         end},
        id: healthy
      )

      assert :ok = Wakes.fire_due(healthy)
      assert_receive {:callback_retry, probe_id}
      assert probe_id == probe.wake_id
      assert Wakes.get(ctx.db, probe.wake_id).state == "fired"
      assert :ok = Wakes.fire_due(healthy)
      refute_receive {:callback_retry, _}
      stop_supervised!(healthy)
      assert Wakes.get(ctx.db, wake.wake_id).state == "pending"
      assert count(ctx.db, "SELECT COUNT(*) FROM turns") == 0
    end

    # PASS-AFTER: a restart with a healthy delivery drains it on the ordinary tick.
    assert :ok = DB.execute(ctx.db, "DROP TRIGGER refuse_escalation_carrier")
    drain!(ctx)
    carrier = delivery_wake(ctx.db, wake)
    assert carrier.state == "fired"
    assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [carrier.wake_id]) == 1
    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"
    assert Wakes.get(ctx.db, wake.wake_id).prompt == wake.prompt

    assert [%{delivery_wake_id: carrier_id, member_state: "included", batch_state: "delivered"}] =
             NoticeBatcher.source_refs(ctx.db, wake.wake_id)

    assert carrier_id == carrier.wake_id

    assert [[content]] =
             rows(
               ctx.db,
               "SELECT m.content FROM turns t JOIN messages m ON m.id=t.messageId WHERE t.wakeId=?1",
               [carrier.wake_id]
             )

    assert content =~ wake.wake_id
    assert content =~ wake.prompt
    assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake.wake_id]) == 0
    before_turns = rows(ctx.db, "SELECT * FROM turns ORDER BY seq")
    before_messages = rows(ctx.db, "SELECT * FROM messages ORDER BY id")
    drain!(ctx)
    assert rows(ctx.db, "SELECT * FROM turns ORDER BY seq") == before_turns
    assert rows(ctx.db, "SELECT * FROM messages ORDER BY id") == before_messages
  end

  ## Proof 6 — exactly one initial delivery, and the dedupe backstop

  defp scenario(6, ctx) do
    assert {:decision_pending, _id} =
             Escalation.escalate(ctx.db, statute_call(), statute(), escalation_ctx())

    assert [wake] = notification_wakes(ctx.db)
    owner_session = Org.personal_session_key("flynn")

    drain!(ctx)

    carrier = delivery_wake(ctx.db, wake)
    assert carrier.state == "fired"
    assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [carrier.wake_id]) == 1

    assert count(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey = ?1", [owner_session]) ==
             1

    # A second source lands while the first carrier's recipient turn is still
    # queued. It remains an editable row until that recipient becomes ready.
    assert {:decision_pending, _} =
             Escalation.escalate(
               ctx.db,
               statute_call(%{assignment_id: "a-backstop"}),
               statute(),
               escalation_ctx()
             )

    assert [first, synthetic] = notification_wakes(ctx.db)
    assert first.wake_id == wake.wake_id

    assert Wakes.get(ctx.db, synthetic.wake_id).state == "pending"
    assert NoticeBatcher.source_refs(ctx.db, synthetic.wake_id) == []
    assert [] == NoticeBatcher.recover(ctx.db, synthetic.due_at)
    assert message_count(ctx.db) == 1

    assert {:ok, recipient_turn} = Ledger.claim_next(ctx.db, owner_session, "delivery-fixture")

    assert :ok =
             Ledger.finish(ctx.db, recipient_turn.seq, "delivered", nil,
               owner_lease: recipient_turn.owner_lease
             )

    drain!(ctx)

    synthetic_carrier = delivery_wake(ctx.db, synthetic)
    assert synthetic_carrier.wake_id != synthetic.wake_id
    assert synthetic_carrier.state == "fired"
    assert Wakes.get(ctx.db, synthetic.wake_id).state == "fired"

    assert [%{delivery_wake_id: synthetic_carrier_id, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(ctx.db, synthetic.wake_id)

    assert synthetic_carrier_id == synthetic_carrier.wake_id

    assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [
             synthetic.wake_id
           ]) == 0

    assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [
             synthetic_carrier.wake_id
           ]) == 1

    assert count(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey = ?1", [owner_session]) ==
             2

    message_count_before_retry = message_count(ctx.db)

    assert :duplicate =
             Gateway.deliver_prompt(
               synthetic_carrier.session_key,
               synthetic_carrier.origin,
               synthetic_carrier.prompt,
               db: ctx.db,
               wake_id: synthetic_carrier.wake_id,
               sender: synthetic_carrier.origin
             )

    assert message_count(ctx.db) == message_count_before_retry

    drain!(ctx)

    assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [
             synthetic_carrier.wake_id
           ]) == 1

    assert [[content]] =
             rows(
               ctx.db,
               "SELECT content FROM messages WHERE sessionKey = ?1 ORDER BY rowid DESC LIMIT 1",
               [owner_session]
             )

    assert content =~ synthetic.wake_id
    assert content =~ synthetic.prompt
  end

  ## Proof 7 — replay and conflict are silent

  defp scenario(7, ctx) do
    call = statute_call()

    assert {:decision_pending, id} =
             Escalation.escalate(ctx.db, call, statute(), escalation_ctx())

    [wake] = notification_wakes(ctx.db)
    drain!(ctx)

    before = {message_count(ctx.db), turn_count(ctx.db)}

    # The `{:decision_pending, id}` replay path.
    assert {:decision_pending, ^id} =
             Escalation.escalate(
               ctx.db,
               call,
               statute(),
               Map.put(escalation_ctx(), :dr_id, id)
             )

    assert Enum.map(notification_wakes(ctx.db), & &1.wake_id) == [wake.wake_id]
    assert {message_count(ctx.db), turn_count(ctx.db)} == before

    # The open-request conflict path: same raiser, statute and action key, no
    # dr_id — the insert loses to `ON CONFLICT DO NOTHING`.
    assert {:decision_pending, ^id} =
             Escalation.escalate(ctx.db, call, statute(), escalation_ctx())

    assert Enum.map(notification_wakes(ctx.db), & &1.wake_id) == [wake.wake_id]
    assert {message_count(ctx.db), turn_count(ctx.db)} == before
  end

  ## Proof 9 — configured delivery dependencies only

  defp scenario(9, ctx) do
    parent = self()
    registry = :"delivery_registry_#{System.unique_integer([:positive])}"
    lanes = :"delivery_lanes_#{System.unique_integer([:positive])}"

    for {tag, name} <- [{:injected_registry, registry}, {:injected_lanes, lanes}] do
      start_supervised!(%{id: name, start: {Doorbell, :start_link, [{parent, tag, name}]}})
    end

    config =
      ctx.config
      |> Map.put(:conn_registry, registry)
      |> Map.put(:lane_manager, lanes)

    assert {:decision_pending, _id} =
             Escalation.escalate(ctx.db, statute_call(), statute(), escalation_ctx())

    assert [statute_wake] = notification_wakes(ctx.db)

    drain!(%{ctx | config: config})

    carrier = delivery_wake(ctx.db, statute_wake)
    assert carrier.state == "fired"
    key = carrier.session_key
    assert_received {:published, :injected_registry, ^key}
    assert_received {:lane_nudged, :injected_lanes, ^key}

    refute_received {:published, :default_registry, _}
    refute_received {:lane_nudged, :default_lanes, _}
  end

  ## Proof 10 — the closure law

  defp scenario(10, _ctx) do
    # Every production `decision_requests` insert/retarget site, and the
    # in-transaction prompt arm each one owes.
    request_sites = [
      {"lib/tightbeam/escalation.ex", "escalate/4"},
      {"lib/tightbeam/escalation.ex", "file_agent_request_in_txn/2"},
      {"lib/tightbeam/escalation.ex", "insert_operator_request_in_txn/7"}
    ]

    assert Enum.sort(request_sites) == Enum.sort(decision_request_sites())

    for {file, ref} <- request_sites do
      assert arms_prompt_wake_in_txn?(file, ref),
             "#{file} #{ref} inserts/retargets a decision request without arming a prompt wake in the transaction"
    end

    # Every turn-bearing delivery sink, keyed by enclosing definition with its
    # exact call count: a new site changes the map and fails.
    assert sink_sites() == %{
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt/4",
              "children_after_preflight/1"} => 1,
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt/4", "handler_specs/1"} => 1,
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt/4",
              "execute_assignment_repair/6"} => 1,
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt/4", "notify_session/4"} => 1,
             # The fault bubble's transactional notice enqueue: a
             # substrate-authored turn to the failing session's nearest active
             # ancestor, deduped by deterministic wakeId and committed with
             # the current cannot-proceed disposer.
             {"lib/tightbeam/productions/bubble.ex", "Gateway.deliver_prompt_in_txn/5",
              "deliver_bubble_notice_in_txn/4"} => 1,
             {"lib/tightbeam/gateway.ex", "Gateway.notify_session/4", "remove_override_result/3"} =>
               1,
             # A queued human post carries its source wake, client identity and
             # attachments through the transaction that admits its prompt and turn.
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt_in_txn/5",
              "deliver_waiting_human_post_in_txn/6"} => 1,
             {"lib/tightbeam/assignments.ex", "Gateway.deliver_prompt_in_txn/5",
              "open_dispatch_result/2"} => 1,
             {"lib/tightbeam/wakes.ex", "Gateway.deliver_prompt_in_txn/5", "fire_in_txn/3"} => 1,
             {"lib/tightbeam/wakes.ex", "Gateway.deliver_prompt_in_txn/5",
              "deliver_wait_in_txn/3"} => 1,
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt_in_txn/5", "deliver_prompt/4"} =>
               1,
             # `deliver_prompt_in_txn/5` declines undeliverable addresses before
             # appending the echo. Message enqueue then reaches this one turn sink.
             {"lib/tightbeam/gateway.ex", "Ledger.enqueue_in_txn/2", "enqueue_message_in_txn/9"} =>
               1,
             {"lib/tightbeam/harness_health.ex", "Gateway.deliver_prompt_in_txn/5",
              "incident_notice_in_txn/4"} => 1,
             # One concrete-session snapshot admits its carrier and actual turn
             # together; the inventory still rejects any additional turn sink.
             {"lib/tightbeam/notice_batcher.ex", "Gateway.deliver_prompt_in_txn/5",
              "admit_session_chunk_in_txn/6"} => 1,
             {"lib/tightbeam/wakes.ex", "Ledger.enqueue_in_txn/2",
              "redeliver_health_source_in_txn/3"} => 1,
             {"lib/tightbeam/ledger.ex", "Ledger.enqueue_in_txn/2", "enqueue/2"} => 1,
             {"lib/tightbeam/ledger.ex", "Ledger.enqueue_in_txn/2", "append_repair_attempt/5"} =>
               1
           }

    # `Ledger.enqueue/2` has zero production call sites: the wrapper exists for
    # tests only, so no path bypasses `enqueue_in_txn/2`'s callers.
    assert Enum.filter(Map.keys(sink_sites()), &(elem(&1, 1) == "Ledger.enqueue/2")) == []

    # A hand-written turn insert would step around every AST allowlist above.
    # Case-, whitespace- and quoting-insensitive: `insert into turns`, the phrase
    # broken across lines, and `insert into "turns"` / `[turns]` / backticked are
    # all the same step-around as the canonical spelling (SQLite accepts every
    # one of those identifier quotings).
    #
    # The quoting class is a RUN that includes a backslash on purpose. Because
    # this scan reads SOURCE TEXT, a double-quoted identifier inside an ordinary
    # Elixir string is spelled `\"turns\"` in the file, while the same identifier
    # in a heredoc is spelled `"turns"`. A class matching only the quote character
    # catches the heredoc form and misses the escaped one — which is exactly how
    # the first attempt at this fix still let the reviewer's case through.
    #
    # WHAT EACH SCAN READS, AND WHAT NEITHER CATCHES. This one greps the ENTIRE
    # SOURCE TEXT of each production file, so it sees the phrase wherever it is
    # written — including in a comment, which would be a false positive it
    # deliberately accepts rather than parsing to exclude. The decision-request
    # scan below is different: it walks the AST and inspects individual string
    # LITERALS.
    #
    # Neither catches SQL whose table name is assembled at runtime —
    # `"INSERT INTO " <> table`, an interpolated name, or a query built from
    # fragments — because the phrase is then never adjacent in one place to be
    # found. That limit is deliberate: folding arbitrary concatenation is
    # unbounded, and someone concatenating SQL to slip past a named guard is
    # evading review, which no test prevents. The guard is a floor against drift,
    # not a sandbox against intent.
    assert Enum.filter(
             production_files(),
             &(File.read!(&1) =~ ~r/insert\s+into\s*[\\"\[`\s]*turns\b/i)
           ) == ["lib/tightbeam/ledger.ex"]

    # The request modules cannot reach a delivery seam through an injected fun.
    for file <- ["lib/tightbeam/escalation.ex", "lib/tightbeam/effort_checkin.ex"] do
      assert indirect_invocations(file) == [],
             "#{file} contains an indirect function invocation"
    end

    # The deleted callback/config seams stay deleted.
    for seam <- [
          "deliver_owner",
          "effort_notify",
          "notify_expecter",
          "deliver_notification",
          "escalation_context"
        ] do
      assert Enum.filter(production_files(), &(File.read!(&1) =~ seam)) == [],
             "production still mentions the #{seam} seam"
    end
  end

  ## Proof 11 — retirement readdresses before ordinary delivery

  defp scenario(11, ctx) do
    assert {:decision_pending, _id} =
             Escalation.escalate(ctx.db, statute_call(), statute(), escalation_ctx())

    system_wake =
      Wakes.schedule(ctx.db, %{
        session_key: "mid",
        origin: @origin,
        consumer: "prompt",
        prompt: "System notice",
        due_at: System.system_time(:millisecond),
        target_gate: 0
      })

    assert [statute_wake, system_wake] = notification_wakes(ctx.db)
    main_key = Org.personal_session_key("flynn")
    assert statute_wake.session_key == main_key

    # A control prompt wake on the retiring target carries the schema default
    # targetGate = 1. Retirement must preserve it as an ordinary address too.
    control =
      Wakes.schedule(ctx.db, %{
        session_key: system_wake.session_key,
        origin: @origin,
        prompt: "control gated wake",
        due_at: System.system_time(:millisecond)
      })

    assert control.target_gate == 1

    # Retire the actual active recipient through Org. The gate-zero system
    # notice moves up the lineage in that transaction; the active Main
    # decision notice stays gate zero and is delivered through the ordinary path.
    assert %{state: "retired"} =
             Org.retire(ctx.db, system_wake.session_key, "user:flynn", 1_000)

    readdressed_system_wake = Wakes.get(ctx.db, system_wake.wake_id)

    assert %{
             state: "pending",
             session_key: "top",
             target_gate: 1,
             target_role: nil,
             reresolve: nil
           } =
             readdressed_system_wake

    assert readdressed_system_wake.wake_id == system_wake.wake_id
    assert readdressed_system_wake.prompt == system_wake.prompt

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wake_cancellations WHERE wakeId=?1",
               [system_wake.wake_id]
             )

    assert %{state: "pending", session_key: "top", target_gate: 1} =
             Wakes.get(ctx.db, control.wake_id)

    assert %{state: "pending", session_key: ^main_key, target_gate: 0} =
             Wakes.get(ctx.db, statute_wake.wake_id)

    drain!(ctx)

    for {wake, expected_session} <- [
          {readdressed_system_wake, "top"},
          {statute_wake, main_key},
          {Wakes.get(ctx.db, control.wake_id), "top"}
        ] do
      carrier = delivery_wake(ctx.db, wake)
      assert carrier.state == "fired"
      assert carrier.session_key == expected_session

      assert rows(ctx.db, "SELECT sessionKey FROM turns WHERE wakeId = ?1", [carrier.wake_id]) ==
               [[expected_session]]
    end

    before_turns = rows(ctx.db, "SELECT * FROM turns ORDER BY seq")
    before_messages = rows(ctx.db, "SELECT * FROM messages ORDER BY id")
    drain!(ctx)
    assert rows(ctx.db, "SELECT * FROM turns ORDER BY seq") == before_turns
    assert rows(ctx.db, "SELECT * FROM messages ORDER BY id") == before_messages
  end

  ## Helpers — world

  defp seed_world!(db) do
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(
        db,
        "INSERT OR IGNORE INTO users (userId, isAdmin, createdAt) VALUES ('flynn',0,1)"
      )

    host = Placement.local_host_name()
    create_session(db, "top", host)
    create_session(db, "mid", host, "top")
    create_session(db, "holder", host, "mid")
    create_session(db, "raiser", host)
    create_session(db, Org.personal_session_key("flynn"), host)
    :ok
  end

  defp create_session(db, key, host, spawned_by \\ nil) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: if(key == Org.personal_session_key("flynn"), do: "main", else: "custom"),
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: host,
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5"),
      spawned_by: spawned_by
    })
  end

  defp config(base_dir, db) do
    %{
      base_dir: base_dir,
      cwd: base_dir,
      port: 0,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 60_000,
      onboarding_lease_ms: 1_800_000,
      db: db,
      effort_checkin_horizon_ms: 1,
      credential_status: fn _provider -> :onboarded end,
      credential_kind: fn _provider -> :subscription end,
      patch_adapter: fn _harness, _path -> :ok end,
      # The real probe command, answered by a canned shell: these proofs are
      # about transaction atomicity, not about what a filesystem contains.
      sh: fn _invocation -> {"B\tobserved\t0\n/w\n", 0} end
    }
  end

  ## Helpers — statute and effort requests

  defp statute, do: %{name: "review", text: "owner denied review"}
  defp escalation_ctx, do: %{question: "Allow this action?", options: nil}

  defp statute_call(params \\ %{assignment_id: "a-statute", kind: "completion"}) do
    %{
      verb: "attest",
      origin: "agent:raiser",
      principal: {:session, "raiser"},
      session_key: nil,
      params: params
    }
  end

  defp operator_call do
    %{
      verb: "operator-ask",
      origin: "agent:raiser",
      principal: {:session, "raiser"},
      transport_session_key: "raiser",
      params: %{question: "ship window?"}
    }
  end

  defp dispatch!(ctx) do
    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        params: %{title: "Delivery trace"}
      })

    assert %{deliveryOwnerSessionKey: "mid"} =
             WorkItems.__handle__(ctx.db, "work-item-update", %{
               verb: "work-item-update",
               origin: "user:flynn",
               principal: {:user, "flynn"},
               session_key: nil,
               params: %{work_item_id: item.id, delivery_owner_session_key: "mid"}
             })

    # Dispatching a work-item-linked assignment requires the dispatcher to have
    # ruminated on the item first (a fired rumination wake it created).
    rumination =
      Wakes.schedule(ctx.db, %{
        session_key: "mid",
        origin: @origin,
        prompt: "ruminate on #{item.id}",
        due_at: System.system_time(:millisecond),
        work_item_id: item.id,
        rumination: true,
        creator_session_key: "mid"
      })

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE wakes SET state='fired' WHERE wakeId='#{rumination.wake_id}'"
      )

    assignment =
      Assignments.__handle__(ctx.db, "dispatch", %{
        verb: "dispatch",
        origin: "agent:mid",
        principal: {:session, "mid"},
        session_key: "holder",
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: ctx.config.wake_tick_ms,
        params: %{
          subject: "delivery",
          brief: "exercise the durable notification",
          work_item_id: item.id
        },
        effort_config: ctx.config
      })

    _ = item
    assignment
  end

  defp job_ref(db, assignment_id) do
    [[job_ref]] = rows(db, "SELECT workItemId FROM assignments WHERE id = ?1", [assignment_id])
    job_ref
  end

  ## Helpers — wakes and delivery

  defp notification_wakes(db) do
    db
    |> rows("SELECT wakeId FROM wakes WHERE targetGate = 0 AND digest=0 ORDER BY rowid")
    |> Enum.map(fn [wake_id] -> Wakes.get(db, wake_id) end)
  end

  defp delivery_wake(db, source) do
    case NoticeBatcher.source_refs(db, source.wake_id) do
      [%{batch_id: batch_id}] ->
        case NoticeBatcher.batch(db, batch_id) do
          %{delivery_wake_id: wake_id} when is_binary(wake_id) -> Wakes.get(db, wake_id)
          _ -> source
        end

      _ ->
        source
    end
  end

  defp wakes_child(config) do
    config
    |> Gateway.children_after_preflight()
    |> Enum.find(&match?({Wakes, _}, &1))
  end

  # The REAL gateway prompt-wake child, drained once.
  defp drain!(ctx) do
    {Wakes, opts} = wakes_child(ctx.config)
    name = :"delivery_drain_#{System.unique_integer([:positive])}"
    start_supervised!({Wakes, Keyword.merge(opts, name: name, tick_ms: 60_000)}, id: name)
    :ok = Wakes.fire_due(name)
    stop_supervised!(name)
    :ok
  end

  ## Helpers — closure law

  ## Helpers — SQL

  # The trigger's ABORT surfaces from the transaction as `DB.Error`; the effort
  # callers re-raise it directly, while `escalate/4` matches on `{:ok, _}` and so
  # raises the MatchError that wraps it. Either way the intent did not commit.
  defp assert_aborts!(fun) do
    error = catch_error(fun.())

    assert match?(%DB.Error{}, error) or
             match?({:badmatch, {:error, %DB.Error{}}}, error),
           "expected the prompt-wake abort to propagate, got #{inspect(error)}"
  end

  defp block_prompt_wakes!(db) do
    :ok =
      DB.execute(db, """
      CREATE TRIGGER block_prompt_wakes BEFORE INSERT ON wakes
      WHEN NEW.consumer = 'prompt'
      BEGIN SELECT RAISE(ABORT, 'prompt wake blocked'); END;
      """)
  end

  defp unblock_prompt_wakes!(db), do: :ok = DB.execute(db, "DROP TRIGGER block_prompt_wakes")

  defp rows(db, sql, params \\ []) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  defp count(db, sql, params \\ []) do
    [[count]] = rows(db, sql, params)
    count
  end

  defp message_count(db), do: count(db, "SELECT COUNT(*) FROM messages")
  defp turn_count(db), do: count(db, "SELECT COUNT(*) FROM turns")

  defp eventually(check, remaining \\ 60) do
    cond do
      check.() -> true
      remaining == 0 -> false
      true -> Process.sleep(25) && eventually(check, remaining - 1)
    end
  end

  # `eventually`'s negative twin: the condition must hold at EVERY sample across
  # the window. Be precise about what that buys here, because the state under
  # observation is DURABLE — a wake that goes pending -> fired stays fired, so a
  # single check at the end of a nap would also catch an early fire. The win is
  # the WINDOW, not the sampling: a producer slower than the nap is not observed
  # at all, and a nap is only ever as good as the number someone picked for it.
  # The sampling earns its keep on the diagnostic, reporting the failure at the
  # sample it first fires rather than at the end of the budget. Reach for the
  # sampling itself when the state is transient, where a final snapshot really
  # can miss a value that came and went.
  defp consistently(check, remaining \\ 20) do
    cond do
      not check.() -> false
      remaining == 0 -> true
      true -> Process.sleep(25) && consistently(check, remaining - 1)
    end
  end

  def run!(tmp, scenario) do
    %{executable: executable, args: args, env: env} =
      Tightbeam.GuardRuntimeFixture.prepare!(tmp, "escalation_delivery_runtime.exs")

    {output, status} =
      System.cmd(executable, args,
        env: [{"DD36_SCENARIO", Integer.to_string(scenario)} | env],
        stderr_to_stdout: true
      )

    File.write!(Path.join(tmp, "runtime.log"), output)
    assert status == 0, output
    assert output =~ "escalation_delivery-case: #{scenario}: ok"
  end

  defp start_supervised!(child, opts \\ []) do
    spec = Supervisor.child_spec(child, opts)
    {:ok, pid} = Supervisor.start_child(Process.get({__MODULE__, :supervisor}), spec)
    pid
  end

  defp stop_supervised!(id) do
    sup = Process.get({__MODULE__, :supervisor})
    :ok = Supervisor.terminate_child(sup, id)
    :ok = Supervisor.delete_child(sup, id)
  end
end
