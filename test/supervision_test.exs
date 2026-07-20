defmodule Tightbeam.SupervisionTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{
    Assignments,
    ConnRegistry,
    DB,
    Devices,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Projection,
    Roles,
    Rules,
    Supervision,
    Wakes,
    WorkItems
  }

  defmodule LaneDoorbell do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(state), do: {:ok, state}
    def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    db = :"supervision_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [
          Devices,
          EventLog,
          Idempotency,
          Projection,
          Org,
          Roles,
          WorkItems,
          Assignments,
          Ledger,
          Wakes,
          Supervision
        ] do
      :ok = module.ensure_schema(db)
    end

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    main = session(db, Org.personal_session_key("flynn"), nil, true)
    supervisor = session(db, "supervisor", main.session_key)
    holder = session(db, "holder", supervisor.session_key)
    assignment(db, "asg_1", holder.session_key, "ship it", 1)

    base =
      Path.join(System.tmp_dir!(), "tb-supervision-rules-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    handlers = Gateway.handlers(%{db: db})
    Rules.load!(base, Map.keys(handlers))
    on_exit(fn -> File.rm_rf!(base) end)

    %{db: db, handlers: handlers, main: main, supervisor: supervisor, holder: holder}
  end

  test "schema and neutral row APIs expose the exact durable state", ctx do
    assert Assignments.oldest_open(ctx.db, "holder").id == "asg_1"
    assert Assignments.attest_count(ctx.db, "asg_1") == 0
    assert Ledger.pending_count(ctx.db, "holder") == 0
    assert Ledger.last_terminal_seq(ctx.db, "holder") == nil
    assert Wakes.pending_count(ctx.db, "holder") == 0
    assert Supervision.prod_state(ctx.db, "asg_1") == nil
    assert Supervision.watermark(ctx.db, "holder") == nil

    assert {:ok, columns} = DB.query(ctx.db, "PRAGMA table_info(supervision_watermarks)")
    names = Enum.map(columns, &Enum.at(&1, 1))

    assert names ==
             ~w(sessionKey lastEvaluatedTerminal pendingBranch pendingAssignment pendingK pendingN)

    refute "pendingTarget" in names
  end

  test "prod claims once, counts delivery once, and freezes its outbox numbers", ctx do
    seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 99, "holder", seq)

    assert %{attemptCount: 1, prodCount: 1, deniedStreak: 0} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert %{
             lastEvaluatedTerminal: ^seq,
             pendingBranch: nil,
             pendingAssignment: nil,
             pendingK: nil,
             pendingN: nil
           } = Supervision.watermark(ctx.db, "holder")

    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.session_key == "holder"
    assert wake.origin == "process:tightbeam"
    assert wake.prompt =~ "prod 1 of 3"
    assert wake.reresolve == nil
  end

  test "progress resets delivered and attempted counters before the next claim", ctx do
    seq1 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq1)
    [wake] = Wakes.list_pending(ctx.db)
    assert Wakes.cancel(ctx.db, wake.wake_id, wake.origin)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES ('att_1','asg_1','progress','holder',2)"
      )

    seq2 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq2)

    assert %{attemptCount: 1, prodCount: 1, attestCount: 1, stalledAt: nil} =
             Supervision.prod_state(ctx.db, "asg_1")
  end

  test "n zero escalates, retired rungs are skipped, and the holder-seeded cycle sinks at Main",
       ctx do
    seq = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", seq)

    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.reresolve == "lineage"
    assert wake.reresolve_seed == "holder"
    assert wake.reresolve_rung == 1

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy = 'holder' WHERE sessionKey = 'supervisor'")

    assert Supervision.ladder_target(ctx.db, "holder", 1) == "supervisor"
    assert Supervision.ladder_target(ctx.db, "holder", 2) == ctx.main.session_key

    Org.retire(ctx.db, "supervisor")
    assert Supervision.ladder_target(ctx.db, "holder", 1) == ctx.main.session_key
  end

  test "a retired holder is derived-stranded and receives no claim or wake", ctx do
    Org.retire(ctx.db, "holder")
    seq = terminal!(ctx.db, "holder")

    assert :stranded = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert Supervision.watermark(ctx.db, "holder") == nil
    assert Wakes.list_pending(ctx.db) == []

    stranded =
      Assignments.list(ctx.db, %{holder_key: "holder", state: "open"})
      |> Enum.filter(fn assignment ->
        Org.get(ctx.db, assignment.holderKey).state == "retired"
      end)

    assert Enum.map(stranded, & &1.id) == ["asg_1"]
  end

  test "atomic target gate skips plain dead targets and re-runs the ladder for escalation", ctx do
    registry = start_supervised!({ConnRegistry, name: :supervision_conn_registry})
    lane = start_supervised!({LaneDoorbell, :supervision_lane_manager})
    Org.retire(ctx.db, "supervisor")

    plain = %{reresolve: nil, reresolve_seed: nil, reresolve_rung: nil}

    assert :skipped =
             Gateway.deliver_prompt("supervisor", "process:tightbeam", "plain",
               db: ctx.db,
               wake_id: "w_plain",
               sender: "process:tightbeam",
               target_gate: plain,
               conn_registry: registry,
               lane_manager: lane
             )

    assert Ledger.pending_count(ctx.db, "supervisor") == 0

    gate = %{reresolve: "lineage", reresolve_seed: "holder", reresolve_rung: 1}

    assert :appended =
             Gateway.deliver_prompt("supervisor", "process:tightbeam", "escalate",
               db: ctx.db,
               wake_id: "w_lineage",
               sender: "process:tightbeam",
               target_gate: gate,
               conn_registry: registry,
               lane_manager: lane
             )

    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 1
    assert Ledger.pending_count(ctx.db, "holder") == 0
  end

  test "wake validation requires the complete re-resolution triple and nudge false leaves due work pending",
       ctx do
    wake = ctx.handlers["wake"]

    invalid = %{
      origin: "process:tightbeam",
      session_key: "holder",
      params: %{prompt: "x", reresolve: "lineage"}
    }

    assert %{code: "invalid"} = wake.(invalid)

    valid = %{
      origin: "process:tightbeam",
      session_key: "supervisor",
      params: %{
        prompt: "x",
        after_ms: 0,
        nudge: false,
        reresolve: "lineage",
        reresolve_seed: "holder",
        reresolve_rung: 1
      }
    }

    assert %{state: "pending"} = wake.(valid)
    assert [%{reresolve: "lineage"}] = Wakes.list_pending(ctx.db)
  end

  test "transient refusal preserves the outbox and a later edge drains without recounting", ctx do
    transient = Map.put(ctx.handlers, "wake", fn _ -> %{code: "server_error"} end)
    seq1 = terminal!(ctx.db, "holder")

    assert {:refused, "server_error"} =
             Supervision.evaluate(ctx.db, transient, 3, "holder", seq1)

    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")

    assert %{pendingBranch: "prod", pendingK: 1, pendingN: 3} =
             Supervision.watermark(ctx.db, "holder")

    seq2 = terminal!(ctx.db, "holder")
    assert :continuation = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq2)
    assert %{attemptCount: 1, prodCount: 1} = Supervision.prod_state(ctx.db, "asg_1")

    assert %{lastEvaluatedTerminal: ^seq1, pendingBranch: nil} =
             Supervision.watermark(ctx.db, "holder")

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "supervision_dispatch_failed")
           ) == 1
  end

  test "statute-tier denials clear atomically, count attempts only, and block at the threshold",
       ctx do
    denied = Map.put(ctx.handlers, "wake", fn _ -> %{code: "rule_denied"} end)
    seq1 = terminal!(ctx.db, "holder")
    seq2 = terminal!(ctx.db, "holder")

    assert {:refused, "rule_denied"} = Supervision.evaluate(ctx.db, denied, 2, "holder", seq1)
    assert {:refused, "rule_denied"} = Supervision.evaluate(ctx.db, denied, 2, "holder", seq2)

    assert %{attemptCount: 2, prodCount: 0, deniedStreak: 2, lastProdAt: nil} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert %{pendingBranch: nil, lastEvaluatedTerminal: ^seq2} =
             Supervision.watermark(ctx.db, "holder")

    lifecycle = EventLog.lifecycle_events(ctx.db)
    assert Enum.count(lifecycle, &(&1.kind == "supervision_prod_denied")) == 2
    assert Enum.count(lifecycle, &(&1.kind == "supervision_blocked")) == 1
    assert Wakes.list_pending(ctx.db) == []
  end

  test "drain precedes idle and dedupe for a stale closed-assignment promise", ctx do
    transient = Map.put(ctx.handlers, "wake", fn _ -> %{code: "server_error"} end)
    seq = terminal!(ctx.db, "holder")
    assert {:refused, "server_error"} = Supervision.evaluate(ctx.db, transient, 3, "holder", seq)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET state='closed', outcome='revoked', closedAt=2, closedByUser='flynn' WHERE id='asg_1'"
      )

    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{pendingBranch: nil, lastEvaluatedTerminal: ^seq} =
             Supervision.watermark(ctx.db, "holder")

    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")
    assert Wakes.list_pending(ctx.db) == []
  end

  test "Main self-target takes the no-wake terminus exactly once", ctx do
    assignment(ctx.db, "asg_main", ctx.main.session_key, "main work", 2)
    seq = terminal!(ctx.db, ctx.main.session_key)

    assert :terminus =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, seq)

    assert :duplicate =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, seq)

    assert %{attemptCount: 1, prodCount: 0, stalledAt: stalled} =
             Supervision.prod_state(ctx.db, "asg_main")

    assert is_integer(stalled)
    assert Wakes.list_pending(ctx.db) == []

    assert Enum.count(EventLog.lifecycle_events(ctx.db), &(&1.kind == "supervision_terminus")) ==
             1
  end

  test "request sweep reclaims one suppressed terminal and never reclaims it twice", ctx do
    continuation =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "later",
        due_at: System.system_time(:millisecond) + 60_000
      })

    seq = terminal!(ctx.db, "holder")
    assert :continuation = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert Wakes.cancel(ctx.db, continuation.wake_id, continuation.origin)

    name = :"supervision_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Supervision, db: ctx.db, handlers: ctx.handlers, prod_limit: 3, name: name}
    )

    Supervision.request_sweep(name)
    eventually(fn -> Supervision.prod_state(ctx.db, "asg_1") != nil end)

    first_count = length(Wakes.list_pending(ctx.db))
    Supervision.request_sweep(name)
    Process.sleep(20)
    assert length(Wakes.list_pending(ctx.db)) == first_count
    assert first_count == 1
  end

  test "total catch contains exits and records evaluation failure without losing the claim",
       ctx do
    exiting = Map.put(ctx.handlers, "wake", fn _ -> exit(:handler_exit) end)
    seq = terminal!(ctx.db, "holder")
    name = :"supervision_exit_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!({Supervision, db: ctx.db, handlers: exiting, prod_limit: 3, name: name})

    Supervision.notify_terminal(name, "holder", seq)

    eventually(fn ->
      Enum.any?(EventLog.lifecycle_events(ctx.db), &(&1.kind == "supervision_evaluate_failed"))
    end)

    assert Process.alive?(pid)
    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")
    assert %{pendingBranch: "prod"} = Supervision.watermark(ctx.db, "holder")
  end

  test "N=0 cross-assignment re-entry exceeds N+1 and then quiesces at Main", ctx do
    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy='holder' WHERE sessionKey='supervisor'")

    assignment(ctx.db, "asg_2", "supervisor", "second", 2)

    h1 = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", h1)

    fire_all_pending(ctx.db)
    s1 = terminal!(ctx.db, "supervisor")

    assert {:escalated, 1, "holder"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "supervisor", s1)

    fire_all_pending(ctx.db)
    h2 = terminal!(ctx.db, "holder")

    assert {:escalated, 2, main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", h2)

    assert main == ctx.main.session_key
    assert Supervision.prod_state(ctx.db, "asg_1").prodCount == 2
    assert Supervision.prod_state(ctx.db, "asg_1").prodCount > 0 + 1

    fire_all_pending(ctx.db)
    main_terminal = terminal!(ctx.db, ctx.main.session_key)

    assert :idle =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, main_terminal)

    assert Wakes.list_pending(ctx.db) == []
  end

  test "past-sink open assignment emits one escalation per external terminal and duplicate re-entry is inert",
       ctx do
    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET spawnedBy=NULL WHERE sessionKey='holder'")

    first = terminal!(ctx.db, "holder")

    assert {:escalated, 1, main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", first)

    assert main == ctx.main.session_key
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", first)
    assert length(Wakes.list_pending(ctx.db)) == 1

    fire_all_pending(ctx.db)
    second = terminal!(ctx.db, "holder")

    assert {:escalated, 2, ^main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", second)

    assert length(Wakes.list_pending(ctx.db)) == 1
  end

  test "atomic delivery concurrent-retirement race has only before-or-after outcomes", ctx do
    registry = start_supervised!({ConnRegistry, name: :race_conn_registry})
    lane = start_supervised!({LaneDoorbell, :race_lane_manager})

    for iteration <- 1..20 do
      target = "race_target_#{iteration}"
      session(ctx.db, target, ctx.main.session_key)

      {:ok, _} =
        DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?1 WHERE sessionKey='holder'", [target])

      gate = %{reresolve: "lineage", reresolve_seed: "holder", reresolve_rung: 1}

      delivery =
        Task.async(fn ->
          Gateway.deliver_prompt(target, "process:tightbeam", "race",
            db: ctx.db,
            wake_id: "w_race_#{iteration}",
            sender: "process:tightbeam",
            target_gate: gate,
            conn_registry: registry,
            lane_manager: lane
          )
        end)

      retirement = Task.async(fn -> Org.retire(ctx.db, target) end)
      assert :appended = Task.await(delivery)
      Task.await(retirement)

      {:ok, rows} =
        DB.query(ctx.db, "SELECT sessionKey FROM turns WHERE wakeId=?1", ["w_race_#{iteration}"])

      assert [[recipient]] = rows
      assert recipient in [target, ctx.main.session_key]
      refute recipient == "holder"
    end
  end

  defp terminal!(db, session_key) do
    message_id = "m_#{System.unique_integer([:positive])}"

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: message_id,
        origin: "user:flynn",
        prompt: "external"
      })

    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(db, session_key, "test")
    assert :ok = Ledger.finish(db, seq, "delivered")
    seq
  end

  defp assignment(db, id, holder, subject, opened_at) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) VALUES (?1, ?2, ?3, 'flynn', ?4)",
        [id, subject, holder, opened_at]
      )
  end

  defp session(db, key, spawned_by, built_in \\ false) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: spawned_by,
      is_built_in: built_in,
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: "fable",
      host: "eezo"
    })
  end

  defp fire_all_pending(db) do
    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state='fired', firedAt=?1 WHERE state='pending'", [
        System.system_time(:millisecond)
      ])

    :ok
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end
end
