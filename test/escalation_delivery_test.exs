defmodule Tightbeam.EscalationDeliveryTest do
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
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    DB,
    EffortCheckin,
    Escalation,
    Gateway,
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

  setup do
    db = :"delivery_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    base_dir = seed_base_dir!("delivery")
    seed_world!(db)

    # The DEFAULT-named registry and lane manager. Proof 9 adds injected ones
    # beside these and proves the notification never touches these.
    for {tag, name} <- [
          {:default_registry, Tightbeam.ConnRegistry},
          {:default_lanes, Tightbeam.LaneManager}
        ] do
      start_supervised!(%{id: name, start: {Doorbell, :start_link, [{self(), tag, name}]}})
    end

    %{db: db, base_dir: base_dir, config: config(base_dir, db)}
  end

  ## Proof 1 — statute atomicity

  test "proof 1: a statute request and its owner notification commit or roll back together",
       ctx do
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

  ## Proof 2 — effort-open atomicity (and the assignmentId carrier)

  test "proof 2: an effort request, its deadline wake, and its notification are one commit",
       ctx do
    assignment = dispatch!(ctx)

    # Rung one is the agent prod (no request, no owner notification); the OWNER
    # request is the next bracket, and that is the commit under test here.
    :ok = EffortCheckin.probe(ctx.db, ctx.config, bracket_wake(ctx.db, assignment.id))
    assert notification_wakes(ctx.db) == []

    probe_wake = bracket_wake(ctx.db, assignment.id)
    generations_before = count(ctx.db, "SELECT COUNT(*) FROM effort_checkin_generations")

    # FAIL-BEFORE: the probe transaction rolls back whole — no request, no
    # generation transition, no source-wake fire, no deadline wake, no notification.
    block_prompt_wakes!(ctx.db)
    assert_aborts!(fn -> EffortCheckin.probe(ctx.db, ctx.config, probe_wake) end)

    assert count(ctx.db, "SELECT COUNT(*) FROM decision_requests") == 0
    assert count(ctx.db, "SELECT COUNT(*) FROM effort_checkin_generations") == generations_before
    assert Wakes.get(ctx.db, probe_wake.wake_id).state == "pending"
    assert generation_state(ctx.db, probe_wake.wake_id) == "armed"
    assert notification_wakes(ctx.db) == []
    assert count(ctx.db, "SELECT COUNT(*) FROM wakes WHERE consumer='effort_deadline'") == 0

    # PASS-AFTER.
    unblock_prompt_wakes!(ctx.db)
    :ok = EffortCheckin.probe(ctx.db, ctx.config, probe_wake)

    assert [[request_id, deadline_wake_id]] =
             rows(
               ctx.db,
               "SELECT id, deadlineWakeId FROM decision_requests WHERE kind='effort' AND status='open'"
             )

    assert %{consumer: "effort_deadline", state: "pending"} = Wakes.get(ctx.db, deadline_wake_id)

    assert [%{state: "pending", target_gate: 0, consumer: "prompt"} = wake] =
             notification_wakes(ctx.db)

    assert wake.session_key == "mid"
    assert wake.prompt =~ "Effort check-in #{request_id} for assignment #{assignment.id}"

    # The wake's assignmentId is the carrier that replaced the deleted explicit
    # `assignment_id`/`job_ref` delivery opts; delivery derives the same
    # attribution from it through `Gateway.wake_attribution/2`.
    assert wake.assignment_id == assignment.id
    drain!(ctx)

    assert rows(ctx.db, "SELECT assignmentId, jobRef FROM turns WHERE wakeId = ?1", [
             wake.wake_id
           ]) == [[assignment.id, job_ref(ctx.db, assignment.id)]]
  end

  ## Proof 3 — effort-retarget atomicity

  test "proof 3: a deadline advance and its new-rung notification are one commit", ctx do
    assignment = dispatch!(ctx)
    :ok = escalate!(ctx, assignment.id)
    before = effort_request(ctx.db)
    [notification] = notification_wakes(ctx.db)

    # FAIL-BEFORE: the CAS, the replacement deadline wake, and the new-rung
    # notification all roll back together.
    block_prompt_wakes!(ctx.db)

    assert_aborts!(fn ->
      EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, before.deadline_wake_id))
    end)

    unchanged = effort_request(ctx.db)
    assert unchanged.expecter_session_key == before.expecter_session_key
    assert unchanged.lineage_rung == before.lineage_rung
    assert unchanged.deadline_wake_id == before.deadline_wake_id
    assert Wakes.get(ctx.db, before.deadline_wake_id).state == "pending"
    assert Enum.map(notification_wakes(ctx.db), & &1.wake_id) == [notification.wake_id]

    # PASS-AFTER: one advance, one replacement deadline wake, one prompt wake.
    unblock_prompt_wakes!(ctx.db)
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, before.deadline_wake_id))
    advanced = effort_request(ctx.db)

    assert advanced.lineage_rung == before.lineage_rung + 1
    assert advanced.deadline_wake_id != before.deadline_wake_id
    assert Wakes.get(ctx.db, before.deadline_wake_id).state == "fired"

    assert %{consumer: "effort_deadline", state: "pending"} =
             Wakes.get(ctx.db, advanced.deadline_wake_id)

    assert count(
             ctx.db,
             "SELECT COUNT(*) FROM wakes WHERE consumer='effort_deadline' AND state='pending'"
           ) == 1

    assert [_opened, %{state: "pending", target_gate: 0} = rung] = notification_wakes(ctx.db)
    assert rung.session_key == advanced.expecter_session_key
  end

  ## Proof 4 — crash before delivery, boot recovery

  test "proof 4: a committed notification is delivered by the boot tick alone", ctx do
    path = Path.join(ctx.base_dir, "recovery.sqlite3")
    db = :"delivery_file_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: path, name: db}, id: db)
    seed_world!(db)

    # Commit the request and its due notification with NO scheduler running,
    # then take the DB process down: the crash window the spec names.
    assert {:decision_pending, id} =
             Escalation.escalate(db, statute_call(), statute(), escalation_ctx())

    assert [%{state: "pending"} = wake] = notification_wakes(db)
    assert count(db, "SELECT COUNT(*) FROM turns") == 0
    stop_supervised!(db)

    # FAIL-BEFORE: without the Wakes child nothing recovers. The window has to be
    # long enough that a recovery which DID happen would have been seen, so it is
    # denominated in the PASS-AFTER leg's own measured latency, not in a round
    # number. That leg — same fixture, same 25ms boot tick — fires this wake in
    # 27-52ms on this box at load 24 and 32-129ms at load 42, i.e. one to five
    # ticks. The 20 periods below are 500ms, ~4x the slowest recovery yet
    # observed, so a producer on anything like that cadence lands inside the
    # window rather than after it.
    restarted = :"delivery_file_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: path, name: restarted}, id: restarted)

    assert consistently(fn -> Wakes.get(restarted, wake.wake_id).state == "pending" end)

    # PASS-AFTER: the exact gateway child, no operator verb, no fire_due/1.
    {Wakes, opts} = wakes_child(config(ctx.base_dir, restarted) |> Map.put(:wake_tick_ms, 25))
    name = :"delivery_boot_#{System.unique_integer([:positive])}"
    start_supervised!({Wakes, Keyword.put(opts, :name, name)}, id: name)

    assert eventually(fn -> Wakes.get(restarted, wake.wake_id).state == "fired" end)

    assert rows(restarted, "SELECT wakeId FROM turns WHERE wakeId = ?1", [wake.wake_id]) == [
             [wake.wake_id]
           ]

    assert count(restarted, "SELECT COUNT(*) FROM decision_requests WHERE id = ?1", [id]) == 1
  end

  ## Proof 5 — failure before durable acceptance stays observable

  test "proof 5: a raising or exiting delivery leaves the notification pending", ctx do
    assert {:decision_pending, _id} =
             Escalation.escalate(ctx.db, statute_call(), statute(), escalation_ctx())

    [wake] = notification_wakes(ctx.db)
    owner_session = Org.personal_session_key("flynn")

    # FAIL-BEFORE: two failure modes, neither of which may consume the wake.
    for {tag, failure} <- [
          {:raise, fn _wake -> raise "delivery down" end},
          {:exit, fn _wake -> exit(:delivery_down) end}
        ] do
      name = :"delivery_broken_#{tag}_#{System.unique_integer([:positive])}"

      start_supervised!({Wakes, db: ctx.db, name: name, tick_ms: 60_000, deliver: failure},
        id: name
      )

      :ok = Wakes.fire_due(name)
      stop_supervised!(name)

      assert Wakes.get(ctx.db, wake.wake_id).state == "pending", "#{tag} consumed the wake"
      assert Enum.any?(Wakes.list_pending(ctx.db), &(&1.wake_id == wake.wake_id))
      assert Wakes.pending_count(ctx.db, owner_session) >= 1
      assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [wake.wake_id]) == 0
    end

    # PASS-AFTER: a restart with a healthy delivery drains it on the ordinary tick.
    drain!(ctx)
    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"
    assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [wake.wake_id]) == 1
  end

  ## Proof 6 — exactly one initial delivery, and the dedupe backstop

  test "proof 6: one delivery commits message, turn and fired-mark; the backstop dedupes", ctx do
    assert {:decision_pending, _id} =
             Escalation.escalate(ctx.db, statute_call(), statute(), escalation_ctx())

    assert [wake] = notification_wakes(ctx.db)
    owner_session = Org.personal_session_key("flynn")

    drain!(ctx)

    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"
    assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [wake.wake_id]) == 1

    assert count(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey = ?1", [owner_session]) ==
             1

    # The otherwise-unreachable legacy/synthetic state: a committed turn for a
    # wake that is still pending. Only `turns.wakeId UNIQUE` stands between that
    # and a second turn.
    assert {:decision_pending, _} =
             Escalation.escalate(
               ctx.db,
               statute_call(%{assignment_id: "a-backstop"}),
               statute(),
               escalation_ctx()
             )

    assert [first, synthetic] = notification_wakes(ctx.db)
    assert first.wake_id == wake.wake_id

    assert :appended =
             Gateway.deliver_prompt(synthetic.session_key, synthetic.origin, synthetic.prompt,
               db: ctx.db,
               wake_id: synthetic.wake_id,
               sender: synthetic.origin
             )

    assert Wakes.get(ctx.db, synthetic.wake_id).state == "pending"
    assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [synthetic.wake_id]) == 1

    drain!(ctx)

    assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [synthetic.wake_id]) == 1

    assert count(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey = ?1 AND content = ?2", [
             owner_session,
             "[from #{@origin}]\n\n" <> synthetic.prompt
           ]) == 1

    assert Wakes.get(ctx.db, synthetic.wake_id).state == "fired"
  end

  ## Proof 7 — replay and conflict are silent

  test "proof 7: decision-pending replay and open-request conflict arm nothing", ctx do
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

    # And a stale effort-deadline replay is silent too.
    assignment = dispatch!(ctx)
    :ok = escalate!(ctx, assignment.id)
    opened = effort_request(ctx.db)
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, opened.deadline_wake_id))
    after_advance = Enum.map(notification_wakes(ctx.db), & &1.wake_id)

    :ok = EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, opened.deadline_wake_id))
    assert Enum.map(notification_wakes(ctx.db), & &1.wake_id) == after_advance
  end

  ## Proof 8 — effort ladder conservation

  test "proof 8: every rung expiry re-arms one deadline wake and one prompt wake", ctx do
    assignment = dispatch!(ctx)
    :ok = escalate!(ctx, assignment.id)

    opened = effort_request(ctx.db)
    assert opened.expecter_session_key == "mid"
    assert opened.lineage_rung == 0
    assert notified_rungs(ctx.db) == ["mid"]

    # Rung 1 — a LIVE ancestor.
    live = expire_rung!(ctx, opened)
    assert live.expecter_session_key == "top"
    assert live.expecter_user_id == nil
    assert live.lineage_rung == 1
    assert notified_rungs(ctx.db) == ["mid", "top"]

    # Rung 2 — the ancestor is retired, so routing SKIPS it to the owner user.
    :ok = DB.execute(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='top'")
    skipped = expire_rung!(ctx, live)
    assert skipped.expecter_session_key == nil
    assert skipped.expecter_user_id == "flynn"
    assert skipped.lineage_rung == 2
    personal = Org.personal_session_key("flynn")
    assert notified_rungs(ctx.db) == ["mid", "top", personal]

    # Terminal user rung — expiry re-arms against the SAME user, same rung.
    terminal = expire_rung!(ctx, skipped)
    assert terminal.expecter_user_id == "flynn"
    assert terminal.lineage_rung == 2
    assert notified_rungs(ctx.db) == ["mid", "top", personal, personal]
  end

  ## Proof 9 — configured delivery dependencies only

  test "proof 9: delivery reaches only the injected registry and lane manager", ctx do
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

    assignment = dispatch!(ctx)
    :ok = escalate!(%{ctx | config: config}, assignment.id)

    assert {:decision_pending, _id} =
             Escalation.escalate(ctx.db, statute_call(), statute(), escalation_ctx())

    assert [effort_wake, statute_wake] = Enum.sort_by(notification_wakes(ctx.db), & &1.created_at)

    drain!(%{ctx | config: config})

    for wake <- [effort_wake, statute_wake] do
      assert Wakes.get(ctx.db, wake.wake_id).state == "fired"
      key = wake.session_key
      assert_received {:published, :injected_registry, ^key}
      assert_received {:lane_nudged, :injected_lanes, ^key}
    end

    refute_received {:published, :default_registry, _}
    refute_received {:lane_nudged, :default_lanes, _}
  end

  ## Proof 10 — the closure law

  test "proof 10: every request site arms in-transaction and every turn sink is enumerated" do
    # Every production `decision_requests` insert/retarget site, and the
    # in-transaction prompt arm each one owes.
    request_sites = [
      {"lib/tightbeam/escalation.ex", "escalate/4"},
      {"lib/tightbeam/effort_checkin.ex", "open_request_in_txn/4"},
      {"lib/tightbeam/effort_checkin.ex", "deadline_in_txn/3"}
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
              "children_after_preflight/1"} => 2,
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt/4", "handlers/1"} => 1,
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt/4", "notify_session/4"} => 1,
             {"lib/tightbeam/supervision.ex", "Gateway.deliver_prompt/4",
              "notify_stranded_ancestor/2"} => 1,
             {"lib/tightbeam/gateway.ex", "Gateway.notify_session/4", "remove_override_result/3"} =>
               1,
             {"lib/tightbeam/assignments.ex", "Gateway.deliver_prompt_in_txn/5",
              "open_dispatch_result/2"} => 1,
             {"lib/tightbeam/wakes.ex", "Gateway.deliver_prompt_in_txn/5", "fire_in_txn/2"} => 1,
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt_in_txn/5", "deliver_prompt/4"} =>
               1,
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt_in_txn/5", "adjudicate_park/4"} =>
               1,
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt_in_txn/5",
              "commit_adjudicated_model_swap/5"} => 1,
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt_in_txn/5",
              "adjudicate_respawn/5"} => 1,
             {"lib/tightbeam/gateway.ex", "Gateway.deliver_prompt_in_txn/5", "release_hold/6"} =>
               1,
             # `deliver_prompt_in_txn/5` declines undeliverable addresses BEFORE
             # appending the echo, and hands the append+enqueue pair to this one
             # private. Still exactly one turn sink; it simply has a name now.
             {"lib/tightbeam/gateway.ex", "Ledger.enqueue_in_txn/2",
              "append_and_enqueue_in_txn/7"} => 1,
             {"lib/tightbeam/ledger.ex", "Ledger.enqueue_in_txn/2", "enqueue/2"} => 1
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

  ## Proof 11 — a retired target is still delivered

  test "proof 11: targetGate 0 delivers to a retired target; the default gate still gates", ctx do
    assignment = dispatch!(ctx)
    :ok = escalate!(ctx, assignment.id)

    assert {:decision_pending, _id} =
             Escalation.escalate(ctx.db, statute_call(), statute(), escalation_ctx())

    assert [effort_wake, statute_wake] = Enum.sort_by(notification_wakes(ctx.db), & &1.created_at)

    # A CONTROL prompt wake on the same target, carrying the schema default
    # targetGate = 1 — the gate every pre-existing wake producer relies on.
    control =
      Wakes.schedule(ctx.db, %{
        session_key: statute_wake.session_key,
        origin: @origin,
        prompt: "control gated wake",
        due_at: System.system_time(:millisecond)
      })

    assert control.target_gate == 1

    # Retire both recorded targets AFTER the requests committed.
    for key <- [effort_wake.session_key, statute_wake.session_key] do
      :ok = DB.execute(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='#{key}'")
    end

    drain!(ctx)

    for wake <- [effort_wake, statute_wake] do
      assert Wakes.get(ctx.db, wake.wake_id).state == "fired"

      assert rows(ctx.db, "SELECT sessionKey FROM turns WHERE wakeId = ?1", [wake.wake_id]) == [
               [wake.session_key]
             ]

      assert count(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey = ?1", [
               wake.session_key
             ]) >= 1
    end

    # The control wake keeps the active-session gate: nothing was committed for it.
    assert count(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [control.wake_id]) == 0
  end

  ## Helpers — world

  defp seed_base_dir!(suffix) do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "escalation_delivery_#{suffix}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(base_dir)
    File.mkdir_p!(Path.join([base_dir, "auth", "claude"]))

    File.write!(
      Path.join([base_dir, "auth", "claude", ".credentials.json"]),
      ~s({"claudeAiOauth":{"accessToken":"test-token"}})
    )

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Tightbeam.Archetypes)
    end)

    base_dir
  end

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

  defp dispatch!(ctx) do
    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        params: %{title: "Delivery trace"}
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

  # Zero effect prods the HOLDER first; the owner's request is the next bracket.
  defp escalate!(ctx, assignment_id) do
    :ok = EffortCheckin.probe(ctx.db, ctx.config, bracket_wake(ctx.db, assignment_id))
    :ok = EffortCheckin.probe(ctx.db, ctx.config, bracket_wake(ctx.db, assignment_id))
  end

  defp bracket_wake(db, assignment_id) do
    [[wake_id]] =
      rows(
        db,
        "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed' ORDER BY generation DESC LIMIT 1",
        [assignment_id]
      )

    Wakes.get(db, wake_id)
  end

  defp generation_state(db, wake_id) do
    [[state]] =
      rows(db, "SELECT state FROM effort_checkin_generations WHERE wakeId=?1", [wake_id])

    state
  end

  defp effort_request(db) do
    [[id, session, user, rung, deadline_wake]] =
      rows(
        db,
        "SELECT id, expecterSessionKey, expecterUserId, lineageRung, deadlineWakeId FROM decision_requests WHERE kind='effort' AND status='open'"
      )

    %{
      id: id,
      expecter_session_key: session,
      expecter_user_id: user,
      lineage_rung: rung,
      deadline_wake_id: deadline_wake
    }
  end

  # One deadline expiry: the fresh interval, the single replacement deadline wake,
  # and the single new prompt wake are asserted at every rung.
  defp expire_rung!(ctx, request) do
    notifications_before = length(notification_wakes(ctx.db))
    fired_at = System.system_time(:millisecond)
    :ok = EffortCheckin.deadline(ctx.db, ctx.config, Wakes.get(ctx.db, request.deadline_wake_id))
    advanced = effort_request(ctx.db)

    assert advanced.deadline_wake_id != request.deadline_wake_id
    replacement = Wakes.get(ctx.db, advanced.deadline_wake_id)
    assert replacement.consumer == "effort_deadline"
    assert replacement.state == "pending"
    assert replacement.due_at >= fired_at + 86_400_000

    assert count(
             ctx.db,
             "SELECT COUNT(*) FROM wakes WHERE consumer='effort_deadline' AND state='pending'"
           ) == 1

    assert length(notification_wakes(ctx.db)) == notifications_before + 1
    advanced
  end

  defp notified_rungs(db) do
    db |> notification_wakes() |> Enum.map(& &1.session_key)
  end

  ## Helpers — wakes and delivery

  defp notification_wakes(db) do
    db
    |> rows("SELECT wakeId FROM wakes WHERE targetGate = 0 ORDER BY rowid")
    |> Enum.map(fn [wake_id] -> Wakes.get(db, wake_id) end)
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

  @sinks %{
    {:deliver_prompt, 4} => "Gateway.deliver_prompt/4",
    {:deliver_prompt_in_txn, 5} => "Gateway.deliver_prompt_in_txn/5",
    {:notify_session, 4} => "Gateway.notify_session/4",
    {:enqueue_in_txn, 2} => "Ledger.enqueue_in_txn/2",
    {:enqueue, 2} => "Ledger.enqueue/2"
  }

  defp production_files, do: Path.wildcard("lib/**/*.ex") |> Enum.sort()

  defp definitions(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!()
    |> then(fn ast ->
      {_, found} =
        Macro.prewalk(ast, [], fn
          {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] ->
            {node, [{definition_ref(head), body} | acc]}

          node, acc ->
            {node, acc}
        end)

      found
    end)
  end

  defp definition_ref({:when, _, [head | _]}), do: definition_ref(head)
  defp definition_ref({name, _, args}) when is_list(args), do: "#{name}/#{length(args)}"
  defp definition_ref({name, _, nil}), do: "#{name}/0"

  # {file, sink, enclosing definition} => call count. Keyed on definitions, not
  # line numbers, so an unrelated edit cannot make the law lie either way.
  defp sink_sites do
    for file <- production_files(),
        {ref, body} <- definitions(file),
        sink <- collect(body, &sink_label/1),
        reduce: %{} do
      acc -> Map.update(acc, {file, sink, ref}, 1, &(&1 + 1))
    end
  end

  defp sink_label({{:., _, [_mod, name]}, _meta, args}), do: sink_label(name, args)

  defp sink_label({name, _meta, args}) when is_atom(name) and is_list(args),
    do: sink_label(name, args)

  defp sink_label(_), do: nil

  defp sink_label(name, args), do: Map.get(@sinks, {name, length(args)})

  # Every definition whose body inserts into or retargets `decision_requests`.
  defp decision_request_sites do
    for file <- production_files(),
        {ref, body} <- definitions(file),
        touches_decision_requests?(body),
        do: {file, ref}
  end

  # Per-LITERAL, unlike the whole-file turn scan above: case, spacing and
  # identifier quoting cannot hide a writer, but SQL assembled from fragments can
  # (no single literal then holds the phrase).
  defp touches_decision_requests?(body) do
    body
    |> collect(fn
      sql when is_binary(sql) ->
        cond do
          # `\b` excludes the schema-rebuild copy into `decision_requests_new`.
          sql_matches?(sql, ~r/insert\s+into\s+["\[`]?decision_requests\b/i) -> :insert
          retarget_sql?(sql) -> :retarget
          true -> nil
        end

      _ ->
        nil
    end)
    |> Kernel.!=([])
  end

  # A retarget is the expecter/deadline rotation CAS, not a ruling or withdrawal.
  #
  # This is INTENTIONALLY not what the pre-r2 check matched, in two cases the
  # cross-review found, and both changes are the point rather than a side effect:
  #
  #   `UPDATE decision_requests SET expecterSessionKey=?1` — no space before `=`.
  #   Was NOT matched, now IS. SQL does not require that space, so the old check
  #   had a false negative on a real retarget site.
  #
  #   `UPDATE decision_requests_new SET expecterSessionKey = ?1` — the
  #   schema-rebuild copy table. WAS matched, now is NOT. A rebuild is not a
  #   retarget site, and `\b` here now agrees with the insert scan, which always
  #   excluded `decision_requests_new`.
  #
  # The production site as written today matches under both, so the allowlist did
  # not move when this changed.
  defp retarget_sql?(sql) do
    sql_matches?(sql, ~r/update\s+["\[`]?decision_requests\b/i) and
      sql_matches?(sql, ~r/expecterSessionKey\s*=/i)
  end

  defp sql_matches?(sql, pattern),
    do: sql |> String.replace(~r/\s+/, " ") |> then(&Regex.match?(pattern, &1))

  # The arm may be inline or one local private helper away (effort's shared
  # `arm_notification_in_txn/2`), so resolution follows same-file local calls.
  defp arms_prompt_wake_in_txn?(file, ref, seen \\ []) do
    bodies = for {^ref, body} <- definitions(file), do: body

    cond do
      ref in seen ->
        false

      Enum.any?(bodies, fn body -> collect(body, &prompt_arm/1) != [] end) ->
        true

      true ->
        bodies
        |> Enum.flat_map(fn body -> collect(body, &local_call/1) end)
        |> Enum.any?(&arms_prompt_wake_in_txn?(file, &1, [ref | seen]))
    end
  end

  defp prompt_arm({{:., _, [{:__aliases__, _, aliases}, :schedule_in_txn]}, _, [_txn, arg]}) do
    if List.last(aliases) == :Wakes and ungated_prompt_arm?(arg), do: :armed, else: nil
  end

  defp prompt_arm(_), do: nil

  defp local_call({name, _, args}) when is_atom(name) and is_list(args),
    do: "#{name}/#{length(args)}"

  defp local_call(_), do: nil

  # A notification arm carries `target_gate: 0` and a prompt (the wakes CHECK
  # makes a prompt-consumer row without prompt text impossible).
  defp ungated_prompt_arm?({:%{}, _, pairs}) do
    Keyword.get(pairs, :target_gate) == 0 and Keyword.has_key?(pairs, :prompt)
  end

  defp ungated_prompt_arm?(_), do: false

  # `apply/2,3` or a `fun.(...)` call — the shapes a post-commit callback seam
  # would have to come back through.
  defp indirect_invocations(file) do
    for {ref, body} <- definitions(file),
        _ <-
          collect(body, fn
            {{:., _, [{name, _, nil}]}, _, _} when is_atom(name) -> :dot_call
            {:apply, _, args} when length(args) in [2, 3] -> :apply
            _ -> nil
          end),
        do: ref
  end

  defp collect(ast, matcher) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        case matcher.(node) do
          nil -> {node, acc}
          hit -> {node, [hit | acc]}
        end
      end)

    found
  end

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
end
