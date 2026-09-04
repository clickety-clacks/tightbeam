defmodule Tightbeam.StaleTurnSettlementTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    AdapterCoordinator,
    DB,
    Dispatch,
    Gateway,
    LaneManager,
    Ledger,
    Org,
    Rules,
    StaleTurnSettlement,
    TurnLifecycle
  }

  alias Tightbeam.Acp.{Adapter, Conn}

  @fake ~S"""
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  rl.on("line", (line) => {
    const m = JSON.parse(line);
    if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
  });
  """

  setup do
    nonce = System.unique_integer([:positive])
    db = :"stale_settlement_db_#{nonce}"
    base = Path.join(System.tmp_dir!(), "stale-turn-settlement-#{nonce}")
    File.mkdir_p!(base)
    fake = Path.join(base, "fake_harness.js")
    File.write!(fake, @fake)
    on_exit(fn -> File.rm_rf!(base) end)

    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO users (userId,isAdmin,creationKind,createdAt)
      VALUES ('mike',1,'admin_add',1),('other-admin',1,'admin_add',1),
             ('reader',0,'admin_add',1);

      INSERT INTO sessions
        (sessionKey,displayName,ownerUserId,origin,operationalParent,archetype,
         harness,provider,model,thinkingLevel,host,createdAt,updatedAt)
      VALUES
        ('k1','K1','mike','user:mike','k1','default','claude','anthropic',
         'claude-sonnet-5','medium','testhost',1,1),
        ('k2','K2','mike','user:mike','k1','default','claude','anthropic',
         'claude-sonnet-5','medium','testhost',2,2);
      """)

    Org.append_pointer(db, "k1", "hs-1", "created")
    Org.append_pointer(db, "k2", "hs-2", "created")

    start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})
    task_sup = :"stale_task_sup_#{nonce}"
    lane_sup = :"stale_lane_sup_#{nonce}"
    adapter_sup = :"stale_adapter_sup_#{nonce}"
    start_supervised!({Task.Supervisor, name: task_sup})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: lane_sup})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: adapter_sup})

    owner = self()

    start_supervised!(
      {LaneManager,
       db: db,
       lane_sup: lane_sup,
       task_sup: task_sup,
       runner: fn turn ->
         send(owner, {:runner_started, turn.seq})

         if turn.prompt == "hold live" do
           seq = turn.seq

           receive do
             {:release_runner, ^seq} -> {:ok, %{text: turn.prompt}}
           end
         else
           {:ok, %{text: turn.prompt}}
         end
       end,
       terminal_publisher: fn payload -> send(owner, {:terminal_published, payload}) end,
       on_terminal: fn session_key, seq -> send(owner, {:terminal_callback, session_key, seq}) end,
       interval: 60_000,
       name: Tightbeam.LaneManager}
    )

    start_supervised!(
      {AdapterCoordinator,
       adapter_sup: adapter_sup,
       adapter_context: fn _ -> [] end,
       adapter_opts: fn _, _ ->
         [
           harness: :claude,
           cmd: [System.find_executable("node"), fake],
           home: base,
           cwd: base
         ]
       end,
       db: db,
       name: Tightbeam.AdapterCoordinator}
    )

    key = {:claude, "shared", "testhost"}
    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(Tightbeam.AdapterCoordinator, key)
    assert eventually(fn -> AdapterCoordinator.ready?(Tightbeam.AdapterCoordinator, key) end)

    handlers = Gateway.handlers(%{db: db})
    Rules.load!(base, Map.keys(handlers))

    %{db: db, base: base, handlers: handlers, adapter: adapter}
  end

  test "authorized cancel is atomic, replay-safe, private, and releases queued work", ctx do
    target = stale_turn!(ctx.db, "k1", "phantom", 42)
    successor = enqueue!(ctx.db, "k1", "successor")
    call = settle_call("k1", target, "cancel", "operator confirmed phantom", "settle-1")

    assert {:ok,
            %{
              session_key: "k1",
              turn_seq: ^target,
              status: "canceled",
              won: true,
              replayed: false
            }} = Dispatch.dispatch(ctx.db, ctx.handlers, call)

    assert_receive {:terminal_published, %{status: "canceled", session_key: "k1"}}
    assert_receive {:terminal_callback, "k1", ^target}
    assert_receive {:runner_started, ^successor}
    assert eventually(fn -> turn_status(ctx.db, successor) == "delivered" end)

    assert terminal_truth(ctx.db, target) == {"canceled", nil, 1, 1}
    assert queue_row(ctx.db, successor) == {"delivered", 1}

    assert {:ok,
            %{
              session_key: "k1",
              turn_seq: ^target,
              status: "canceled",
              won: false,
              replayed: true
            }} = Dispatch.dispatch(ctx.db, ctx.handlers, call)

    conflict = put_in(call.params[:reason], "a different claim")

    assert {:error, %{code: "idempotency_key_conflict"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, conflict)

    assert terminal_truth(ctx.db, target) == {"canceled", nil, 1, 1}

    {:ok, rows} =
      DB.query(
        ctx.db,
        "SELECT kind,payload,principal FROM events WHERE verb='settle-turn' ORDER BY id"
      )

    assert [
             ["verb", accepted, "user:mike"],
             ["verb", replay, "user:mike"],
             ["denied", denied, "user:mike"]
           ] = rows

    for payload <- [accepted, replay, denied] do
      refute payload =~ "settle-1"
      refute payload =~ "operator confirmed phantom"
      assert payload =~ sha256("settle-1")
    end
  end

  test "authorized fail stores only the bounded reason and authorization refusals do not mutate",
       ctx do
    target = stale_turn!(ctx.db, "k1", "failed phantom", 43)
    reason = "operator verified the provider request is absent"

    assert {:error, %{code: "not_authorized"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               settle_call("k1", target, "fail", reason, "reader-key", {:user, "reader"})
             )

    for principal <- [{:session, "k1"}, {:process, "tightbeam"}, nil] do
      assert {:error, %{code: "not_authorized"}} =
               Dispatch.dispatch(
                 ctx.db,
                 ctx.handlers,
                 settle_call("k1", target, "fail", reason, inspect(principal), principal)
               )
    end

    assert terminal_truth(ctx.db, target) == {"running", nil, 0, 0}

    assert {:ok, %{status: "failed", won: true, replayed: false}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               settle_call("k1", target, "fail", reason, "fail-key")
             )

    assert terminal_truth(ctx.db, target) == {"failed", reason, 1, 1}
    refute turn_status(ctx.db, target) == "failed_unknown"
  end

  test "lane-live, provider-live, and uncorrelatable targets are zero-mutation refusals", ctx do
    lane_live = enqueue!(ctx.db, "k1", "hold live")
    :ok = LaneManager.ensure_lane(Tightbeam.LaneManager, "k1")
    assert_receive {:runner_started, ^lane_live}
    before_lane = mutation_snapshot(ctx.db, lane_live)

    assert {:error, %{code: "turn_live"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               settle_call("k1", lane_live, "cancel", "lane owns task", "lane-live")
             )

    assert mutation_snapshot(ctx.db, lane_live) == before_lane

    different_target = enqueue!(ctx.db, "k1", "not the lane-owned turn")
    different_before = mutation_snapshot(ctx.db, different_target)

    assert {:error, %{code: "turn_status_ambiguous"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               settle_call(
                 "k1",
                 different_target,
                 "cancel",
                 "another turn owns the lane",
                 "different-live-turn"
               )
             )

    assert mutation_snapshot(ctx.db, different_target) == different_before
    [{lane, _}] = Registry.lookup(Tightbeam.LaneRegistry, "k1")
    send(:sys.get_state(lane).task_pid, {:release_runner, lane_live})
    assert eventually(fn -> turn_status(ctx.db, lane_live) == "delivered" end)

    provider_live = stale_turn!(ctx.db, "k2", "provider live", 2)
    conn = Adapter.conn(ctx.adapter)

    pending =
      Task.async(fn ->
        Conn.request(conn, "never/reply", %{}, timeout: :infinity, session_id: "hs-2")
      end)

    assert eventually(fn -> Conn.probe_request(conn, 2, "hs-2", 1, 1_000) == {:live, 2} end)
    before_provider = mutation_snapshot(ctx.db, provider_live)

    assert {:error, %{code: "turn_live"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               settle_call(
                 "k2",
                 provider_live,
                 "cancel",
                 "provider may still run",
                 "provider-live"
               )
             )

    assert mutation_snapshot(ctx.db, provider_live) == before_provider
    Task.shutdown(pending, :brutal_kill)

    ambiguous = stale_turn!(ctx.db, "k1", "uncorrelatable", nil)
    before_ambiguous = mutation_snapshot(ctx.db, ambiguous)

    assert {:error, %{code: "turn_status_ambiguous"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               settle_call("k1", ambiguous, "fail", "dispatch missing", "ambiguous")
             )

    assert mutation_snapshot(ctx.db, ambiguous) == before_ambiguous
  end

  test "concurrent distinct requests produce one terminal truth and one publication", ctx do
    target = stale_turn!(ctx.db, "k1", "CAS race", 44)
    parent = self()

    tasks =
      for {outcome, key} <- [{"cancel", "race-cancel"}, {"fail", "race-fail"}] do
        Task.async(fn ->
          receive do
            :go -> :ok
          end

          result =
            Dispatch.dispatch(
              ctx.db,
              ctx.handlers,
              settle_call("k1", target, outcome, "race reason", key)
            )

          send(parent, {:race_result, result})
          result
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, fn
             {:ok, %{won: true}} -> true
             _ -> false
           end) == 1,
           inspect(results)

    assert Enum.count(results, fn
             {:ok, %{won: false, replayed: true}} -> true
             _ -> false
           end) == 1

    assert {status, _error, 1, 1} = terminal_truth(ctx.db, target)
    assert status in ["canceled", "failed"]
    assert_receive {:terminal_published, %{session_key: "k1", status: ^status}}
    refute_receive {:terminal_published, %{session_key: "k1"}}
  end

  test "a commit with a lost response is published and its successor drained by reconciliation",
       ctx do
    target = stale_turn!(ctx.db, "k1", "lost response", 45)
    successor = enqueue!(ctx.db, "k1", "after restart")
    request = request!("k1", target, "cancel", "commit then lose response", "lost-response")

    settle = Task.async(fn -> StaleTurnSettlement.settle(ctx.db, request) end)
    assert {:ok, %{status: "canceled", won: true}} = Task.await(settle, 5_000)
    assert terminal_truth(ctx.db, target) == {"canceled", nil, 1, 0}
    refute_received {:terminal_published, _}

    :ok = LaneManager.reconcile(Tightbeam.LaneManager)
    assert_receive {:terminal_published, %{session_key: "k1", status: "canceled"}}
    assert_receive {:terminal_callback, "k1", ^target}
    assert_receive {:runner_started, ^successor}
    assert eventually(fn -> turn_status(ctx.db, successor) == "delivered" end)
    assert terminal_truth(ctx.db, target) == {"canceled", nil, 1, 1}

    assert {:ok, %{status: "canceled", won: false, replayed: true}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               settle_call("k1", target, "cancel", "commit then lose response", "lost-response")
             )

    assert terminal_truth(ctx.db, target) == {"canceled", nil, 1, 1}
  end

  test "eligibility refusals use stable codes and preserve non-running truth", ctx do
    missing_session = settle_call("absent", 99, "cancel", "no session", "missing-session")

    assert {:error, %{code: "session_not_found"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, missing_session)

    missing_turn = settle_call("k1", 99, "cancel", "no turn", "missing-turn")

    assert {:error, %{code: "turn_not_found"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, missing_turn)

    queued = enqueue!(ctx.db, "k1", "queued target")
    queued_before = mutation_snapshot(ctx.db, queued)

    assert {:error, %{code: "turn_not_running"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               settle_call("k1", queued, "cancel", "still queued", "queued-target")
             )

    assert mutation_snapshot(ctx.db, queued) == queued_before

    terminal = stale_turn!(ctx.db, "k2", "already completed", 46)

    {:ok, [[lease]]} =
      DB.query(
        ctx.db,
        "SELECT ownerLease FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='claimed'",
        [terminal]
      )

    assert :ok = Ledger.finish(ctx.db, terminal, "delivered", nil, owner_lease: lease)
    before_terminal = terminal_truth(ctx.db, terminal)

    assert {:ok, %{status: "delivered", won: false, replayed: true}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               settle_call("k2", terminal, "cancel", "stale receipt", "terminal-truth")
             )

    assert terminal_truth(ctx.db, terminal) == before_terminal

    retired = stale_turn!(ctx.db, "k2", "retired target", 47)
    :ok = DB.execute(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='k2'")
    retired_before = mutation_snapshot(ctx.db, retired)

    assert {:error, %{code: "session_retired"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               settle_call("k2", retired, "fail", "session retired", "retired-target")
             )

    assert mutation_snapshot(ctx.db, retired) == retired_before
  end

  test "pointer replacement during the provider probe makes the target ambiguous", ctx do
    target = stale_turn!(ctx.db, "k1", "pointer race", 48)
    conn = Adapter.conn(ctx.adapter)
    :ok = :sys.suspend(conn)
    on_exit(fn -> if Process.alive?(conn), do: :sys.resume(conn) end)

    settlement =
      Task.async(fn ->
        Dispatch.dispatch(
          ctx.db,
          ctx.handlers,
          settle_call("k1", target, "cancel", "pointer raced", "pointer-race")
        )
      end)

    assert eventually(fn -> queued_messages(conn) > 0 end)
    Org.append_pointer(ctx.db, "k1", "hs-replacement", "loaded")
    :ok = :sys.resume(conn)

    assert {:error, %{code: "turn_status_ambiguous"}} = Task.await(settlement, 5_000)
    assert terminal_truth(ctx.db, target) == {"running", nil, 0, 0}
  end

  test "gateway owner loss releases the fence and boot recovery alone classifies the turn", ctx do
    target = stale_turn!(ctx.db, "k1", "owner loss", 49)
    conn = Adapter.conn(ctx.adapter)
    :ok = :sys.suspend(conn)
    on_exit(fn -> if Process.alive?(conn), do: :sys.resume(conn) end)
    parent = self()

    gateway =
      spawn(fn ->
        result =
          Dispatch.dispatch(
            ctx.db,
            ctx.handlers,
            settle_call("k1", target, "cancel", "caller disappeared", "owner-loss")
          )

        send(parent, {:unexpected_owner_result, result})
      end)

    monitor = Process.monitor(gateway)
    assert eventually(fn -> queued_messages(conn) > 0 end)
    Process.exit(gateway, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^gateway, :killed}
    assert eventually(fn -> generation_fences() == 0 end)
    :ok = :sys.resume(conn)
    refute_receive {:unexpected_owner_result, _}
    assert terminal_truth(ctx.db, target) == {"running", nil, 0, 0}

    assert [^target] = Ledger.recover_running(ctx.db)

    assert terminal_truth(ctx.db, target) ==
             {"failed_unknown", "interrupted: outcome unknown", 1, 0}

    {:ok, [["boot-recovery", "process:tightbeam"]]} =
      DB.query(
        ctx.db,
        """
        SELECT cause,principal FROM turn_lifecycle_events
        WHERE turnSeq=?1 AND kind='terminal_committed'
        """,
        [target]
      )
  end

  defp stale_turn!(db, session_key, prompt, request_id) do
    seq = enqueue!(db, session_key, prompt)
    assert {:ok, %{owner_lease: lease}} = Ledger.claim_next(db, session_key, "stale-fixture")
    assert :ok = Ledger.stamp_adapter(db, seq, 1, lease)

    if request_id do
      assert :ok =
               TurnLifecycle.append(db, seq, %{
                 event_key: "prompt:dispatched",
                 producer_event_id: "fixture:prompt:#{seq}",
                 kind: "prompt_dispatched",
                 stage: "prompt",
                 outcome: "dispatched",
                 cause: "fixture:provider-dispatch",
                 principal: "process:tightbeam",
                 owner_lease: lease,
                 acp_request_id: request_id,
                 detail: %{v: 1}
               })
    end

    seq
  end

  defp enqueue!(db, session_key, prompt) do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "m_#{System.unique_integer([:positive])}",
        origin: "user:mike",
        prompt: prompt
      })

    seq
  end

  defp settle_call(session_key, turn_seq, outcome, reason, key, principal \\ {:user, "mike"}) do
    %{
      verb: "settle-turn",
      origin: principal_origin(principal),
      principal: principal,
      session_key: nil,
      params: %{
        session_key: session_key,
        turn_seq: turn_seq,
        outcome: outcome,
        reason: reason,
        idempotency_key: key
      }
    }
  end

  defp request!(session_key, turn_seq, outcome, reason, key) do
    {:ok, request} =
      StaleTurnSettlement.request(
        %{
          session_key: session_key,
          turn_seq: turn_seq,
          outcome: outcome,
          reason: reason,
          idempotency_key: key
        },
        {:user, "mike"}
      )

    request
  end

  defp principal_origin({kind, value}), do: "#{kind}:#{value}"
  defp principal_origin(nil), do: "unknown"

  defp turn_status(db, seq) do
    {:ok, [[status]]} = DB.query(db, "SELECT status FROM turns WHERE seq=?1", [seq])
    status
  end

  defp terminal_truth(db, seq) do
    {:ok, [[status, error, lifecycle, published]]} =
      DB.query(
        db,
        """
        SELECT t.status,t.error,
          (SELECT COUNT(*) FROM turn_lifecycle_events e
           WHERE e.turnSeq=t.seq AND e.kind='terminal_committed'),
          (SELECT COUNT(*) FROM turn_lifecycle_events e
           WHERE e.turnSeq=t.seq AND e.kind='terminal_published')
        FROM turns t WHERE t.seq=?1
        """,
        [seq]
      )

    {status, error, lifecycle, published}
  end

  defp queue_row(db, seq) do
    {:ok, [[status, claimed]]} =
      DB.query(
        db,
        "SELECT status, CASE WHEN startedAt IS NULL THEN 0 ELSE 1 END FROM turns WHERE seq=?1",
        [seq]
      )

    {status, claimed}
  end

  defp mutation_snapshot(db, seq) do
    {:ok, [turn]} =
      DB.query(
        db,
        "SELECT status,endedAt,error,publishedAt FROM turns WHERE seq=?1",
        [seq]
      )

    {:ok, [[lifecycle]]} =
      DB.query(db, "SELECT COUNT(*) FROM turn_lifecycle_events WHERE turnSeq=?1", [seq])

    {turn, lifecycle}
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp queued_messages(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} -> count
      nil -> 0
    end
  end

  defp generation_fences do
    :sys.get_state(Tightbeam.AdapterCoordinator).adapters
    |> Map.values()
    |> Enum.count(fn entry -> Map.get(entry, :fence) != nil end)
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end
end
