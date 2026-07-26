defmodule Tightbeam.AdapterHealTest do
  @moduledoc """
  Proofs for spec s4-operability-v1 — adapter faults heal DARK.

  Everything asserted here lives on OUR side of the ACP seam (SQL, durability,
  ordering, races), which is what makes staged pathologies legitimate: the
  coordinator is a stub so a fault can be induced deterministically, but the
  adapter in proof 1 is a REAL process spawning a REAL non-executable binary —
  the reason under test is produced by `sh`, not by the test.
  """
  use ExUnit.Case, async: false

  alias Tightbeam.{
    AdapterCoordinator,
    Adjudication,
    Artifacts,
    Assignments,
    ConditionFacts,
    ConnRegistry,
    CriticalLeases,
    DB,
    Devices,
    Escalation,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    ModelCatalog,
    Org,
    Projection,
    Roles,
    Wakes,
    WorkItems,
    WorkState
  }

  @cause "adapter_fault:claude:shared@testhost"

  defmodule LaneDoorbell do
    @moduledoc false
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)
    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, key}, _from, parent) do
      send(parent, {:ensure_lane, key})
      {:reply, :ok, parent}
    end
  end

  defmodule AdapterStub do
    @moduledoc false
    use GenServer
    def start_link(replies), do: GenServer.start_link(__MODULE__, Map.new(replies))
    def init(replies), do: {:ok, replies}

    def handle_call({:knows_session?, _sid}, _from, state),
      do: {:reply, Map.get(state, :knows?, false), state}

    def handle_call({:load_session, _sid, _model, _cwd, _mcp, _guidance}, _from, state),
      do: {:reply, Map.fetch!(state, :load_session), state}
  end

  defmodule WakeSchedulerStub do
    @moduledoc false
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}
    def handle_call(:fire_due, _from, parent), do: {:reply, :ok, parent}
  end

  defmodule CoordinatorStub do
    @moduledoc false
    use GenServer

    @doc "checkout: a checkout result or fun; ready: `:not_ready` or a heal token."
    def start_link(opts),
      do: GenServer.start_link(__MODULE__, Map.new(opts), name: Tightbeam.AdapterCoordinator)

    def init(state) do
      # The real coordinator MONITORS adapters; trapping exits is how this stub
      # survives the adapter death it is staging.
      Process.flag(:trap_exit, true)
      {:ok, state}
    end

    def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

    def handle_call({:adapter_for, _key}, _from, state) do
      reply =
        case Map.get(state, :checkout, {:error, :degraded}) do
          fun when is_function(fun, 0) -> fun.()
          checkout -> checkout
        end

      {:reply, reply, state}
    end

    def set_ready(token), do: GenServer.call(Tightbeam.AdapterCoordinator, {:set_ready, token})

    def handle_call({:ready_token, _key}, _from, state) do
      {:reply, Map.get(state, :ready, :not_ready), state}
    end

    def handle_call({:set_ready, token}, _from, state),
      do: {:reply, :ok, Map.put(state, :ready, token)}

    def handle_call({:acquire_load_slot, _borrower}, _from, state),
      do: {:reply, make_ref(), state}

    def handle_cast({:release_load_slot, _slot}, state), do: {:noreply, state}
  end

  setup do
    db = :"heal_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})
    scheduler = start_supervised!({WakeSchedulerStub, self()})

    catalog_base =
      Path.join(System.tmp_dir!(), "heal-catalog-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([catalog_base, "auth", "claude"]))
    File.write!(Path.join([catalog_base, "auth", "claude", "oauth-token"]), "test-token")
    on_exit(fn -> File.rm_rf!(catalog_base) end)

    start_supervised!(
      {ModelCatalog,
       base_dir: catalog_base,
       codex_home: Path.join(catalog_base, "codex"),
       claude_fetch: fn _, _ -> {:error, :offline} end,
       codex_read: fn _ -> {:error, :offline} end}
    )

    for module <- [
          Devices,
          Artifacts,
          EventLog,
          ConditionFacts,
          Idempotency,
          Ledger,
          Org,
          CriticalLeases,
          Projection,
          Roles,
          Wakes,
          Escalation,
          Adjudication,
          WorkItems,
          Assignments,
          WorkState
        ],
        do: :ok = module.ensure_schema(db)

    {:paired, _device} =
      Devices.pair(db, %{
        device_id: "flynn-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    Org.create(db, %{
      session_key: "k1",
      display_name: "Main",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "claude-fable-5"
    })

    base = Path.join(System.tmp_dir!(), "heal_base_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: "claude-fable-5",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 60_000,
      wake_scheduler: scheduler,
      db: db
    }

    %{db: db, config: config}
  end

  ## Proof 1 — the boot failure's DESIGNED reason reaches the turn

  test "proof 1: an adapter whose binary cannot execute fails the TURN with the spawn error", ctx do
    dir = Path.join(System.tmp_dir!(), "heal_bin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    binary = Path.join(dir, "adapter")
    File.write!(binary, "#!/bin/sh\nexit 0\n")
    File.chmod!(binary, 0o644)

    # The REAL coordinator and a REAL adapter: nothing between the broken binary
    # and the turn row is staged. A lazily-booted adapter can be dead before the
    # turn's first call goes out, so the reason has to survive the death — this
    # proves it does, whichever way that race falls.
    sup =
      start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, name: :"heal_adapter_sup_#{:erlang.unique_integer([:positive])}"}
      )

    start_supervised!(
      {AdapterCoordinator,
       adapter_sup: sup,
       db: ctx.db,
       adapter_opts: fn _key ->
         [
           harness: :claude,
           cmd: [binary],
           home: "/tmp",
           cwd: "/tmp",
           stderr_path: Path.join(dir, "stderr.log")
         ]
       end,
       name: Tightbeam.AdapterCoordinator}
    )

    {seq, reason} = run_failing_turn(ctx, "hello")

    # The DESIGNED shape, carrying the REAL spawn error — sh wrote that line,
    # and its wording is the OS's (macOS "cannot execute", Linux
    # "Permission denied"), so the assertion is on substance.
    assert {:adapter_unavailable, text} = reason
    assert text =~ "initialize_failed"
    assert text =~ binary
    assert text =~ "Permission denied" or text =~ "cannot execute"

    error = turn_error(ctx.db, seq)
    assert error =~ "adapter_unavailable"
    assert error =~ binary
    refute error =~ "task_crash"
    assert turn_status(ctx.db, seq) == "failed"

    # And it is classified as an adapter fault, so the heal machinery owns it.
    assert episode(ctx.db).cause == @cause
  end

  ## Proof 2 — fault → hold → heal → auto-release, probe FIRST

  test "proof 2: heal releases the hold via a probe that claims before an older queued turn", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})

    {failed_seq, _reason} = run_failing_turn(ctx, "the turn that faults")
    assert turn_status(ctx.db, failed_seq) == "failed"

    # The hold, its cause, and the notified owner wake.
    assert hold(ctx.db) == "*"
    episode = episode(ctx.db)
    assert episode.cause == @cause
    assert episode.status == "notified"
    assert is_binary(episode.episode_id)
    assert is_nil(episode.heal_token)
    owner_wake = episode.owner_wake_id
    assert Wakes.get(ctx.db, owner_wake).state == "pending"

    # A REAL turn, older than any probe, waiting behind the hold.
    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "seeded real work",
               db: ctx.db,
               client_message_id: "c_seeded"
             )

    seeded_seq = last_queued_seq(ctx.db)
    assert :none = Ledger.claim_next(ctx.db, "k1", "held")

    # The verified ready event.
    heal(ctx, {"01AAAAAAAAAAAAAAAAAAAAAAAA", 2})

    probe_wake = hold(ctx.db)
    assert is_binary(probe_wake) and probe_wake != "*"
    assert Adjudication.get(ctx.db, "k1", "other").recovery_wake_id == probe_wake
    assert Adjudication.get(ctx.db, "k1", "other").status == "resolved"

    # The stale owner-adjudication wake is gone.
    assert Wakes.get(ctx.db, owner_wake).state == "canceled"

    # PROBE FIRST: the older seeded turn cannot jump the '*'→probeWakeId filter.
    assert {:ok, probe_turn} = Ledger.claim_next(ctx.db, "k1", "lane")
    probe_seq = probe_turn.seq
    assert probe_seq > seeded_seq
    assert probe_turn.wake_id == probe_wake
    assert probe_turn.prompt =~ "adapter recovered"

    # Probe SUCCEEDS -> the hold clears.
    assert :ok = Ledger.finish(ctx.db, probe_seq, "delivered")
    assert is_nil(hold(ctx.db))

    # The seeded turn runs, then fresh work runs — on the SAME session.
    assert {:ok, %{seq: ^seeded_seq}} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert :ok = Ledger.finish(ctx.db, seeded_seq, "delivered")

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "fresh work",
               db: ctx.db,
               client_message_id: "c_fresh"
             )

    assert {:ok, fresh} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert :ok = Ledger.finish(ctx.db, fresh.seq, "delivered")

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), &(&1.kind == "adjudication_hold_healed"))
  end

  ## Proof 3 — storm freedom, probe-terminal totality, restart stability

  test "proof 3: replaying a token probes nothing; a strictly newer one probes exactly once", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")

    epoch = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    heal(ctx, {epoch, 2})
    first_probe = hold(ctx.db)
    assert is_binary(first_probe) and first_probe != "*"
    assert probe_count(ctx.db) == 1

    # REPLAY: same token, zero additional probes (and the hold is untouched).
    heal(ctx, {epoch, 2})
    assert probe_count(ctx.db) == 1
    assert hold(ctx.db) == first_probe

    # A strictly newer token while a probe is already in flight is also inert —
    # the hold is no longer '*'.
    heal(ctx, {epoch, 3})
    assert probe_count(ctx.db) == 1
  end

  for {terminal, label} <- [
        {"failed", "failed"},
        {"canceled", "canceled"},
        {"failed_unknown", "boot failed_unknown"}
      ] do
    test "proof 3: a probe terminalizing #{label} re-holds with the same cause", ctx do
      start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
      run_failing_turn(ctx, "fault")

      epoch = "01AAAAAAAAAAAAAAAAAAAAAAAA"
      heal(ctx, {epoch, 2})
      probe_wake = hold(ctx.db)
      assert {:ok, probe} = Ledger.claim_next(ctx.db, "k1", "lane")

      case unquote(terminal) do
        "failed_unknown" ->
          # The boot writer: recover_running, not finish_in_txn.
          assert [probe.seq] == Ledger.recover_running(ctx.db)
          # Boot reconciliation must ALSO leave it re-held, not clear it.
          :ok = Adjudication.reconcile(ctx.db)

        terminal ->
          assert :ok = Ledger.finish(ctx.db, probe.seq, terminal)
      end

      assert hold(ctx.db) == "*", "a non-delivered probe terminal must RE-HOLD"
      episode = episode(ctx.db)
      assert episode.cause == @cause
      assert AdapterCoordinator.decode_token(episode.heal_token) == {epoch, 2}

      # No further probe on the SAME token...
      heal(ctx, {epoch, 2})
      assert probe_count(ctx.db) == 1
      assert hold(ctx.db) == "*"

      # ...and exactly one on a strictly larger one.
      heal(ctx, {epoch, 3})
      assert probe_count(ctx.db) == 2
      next_probe = hold(ctx.db)
      assert next_probe != "*" and next_probe != probe_wake
    end
  end

  test "proof 3: a probe that fails through the REAL failure path does not re-probe its own token",
       ctx do
    # The storm this defends against: the failed probe reopens its episode, and
    # the reopen must NOT clear healToken — otherwise the post-commit level check
    # (the coordinator has not yet observed the death, so it still reports ready
    # at the SAME token) immediately probes again, and again.
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")

    epoch = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    :ok = CoordinatorStub.set_ready({:ok, {epoch, 2}})
    heal(ctx, {epoch, 2})
    assert probe_count(ctx.db) == 1
    assert {:ok, probe} = Ledger.claim_next(ctx.db, "k1", "lane")

    # The probe turn fails the way any turn fails — runner, terminal CAS,
    # adjudication closure, post-commit — with the adapter still reported ready.
    fail_claimed_turn(ctx, probe)

    assert probe_count(ctx.db) == 1, "a re-held probe must not re-probe its own token"
    assert hold(ctx.db) == "*"

    episode = episode(ctx.db)
    assert episode.cause == @cause

    assert AdapterCoordinator.decode_token(episode.heal_token) == {epoch, 2},
           "the token that already probed must survive the re-hold"

    # A strictly larger token probes exactly once more.
    heal(ctx, {epoch, 3})
    assert probe_count(ctx.db) == 2
  end

  test "proof 3: a task-crash probe terminal re-holds (no adjudication closure runs)", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")
    heal(ctx, {"01AAAAAAAAAAAAAAAAAAAAAAAA", 2})
    assert {:ok, probe} = Ledger.claim_next(ctx.db, "k1", "lane")

    # SessionLane's :DOWN path: `failed` with :task_crash and NO
    # adjudicate_in_txn closure — the re-hold cannot come from the failure
    # branch, only from the terminal writer.
    assert :ok = Ledger.finish(ctx.db, probe.seq, "failed", inspect(:task_crash))
    assert hold(ctx.db) == "*"
    assert episode(ctx.db).cause == @cause
  end

  test "proof 3: a post-restart ready sweeps a hold stamped under the old epoch", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")

    heal(ctx, {"01BBBBBBBBBBBBBBBBBBBBBBBB", 7})
    assert {:ok, probe} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert :ok = Ledger.finish(ctx.db, probe.seq, "failed")
    assert hold(ctx.db) == "*"

    # A restarted coordinator mints a LARGER epoch and resets generation to 1.
    # Generation alone would read as older; epoch-first ordering is what makes
    # the sweep restart-stable.
    assert AdapterCoordinator.newer_token?(
             {"01CCCCCCCCCCCCCCCCCCCCCCCC", 1},
             {"01BBBBBBBBBBBBBBBBBBBBBBBB", 7}
           )

    heal(ctx, {"01CCCCCCCCCCCCCCCCCCCCCCCC", 1})
    assert probe_count(ctx.db) == 2
    assert hold(ctx.db) != "*"
  end

  test "proof 3: the LEVEL trigger probes a hold that commits after the ready already fired", ctx do
    # No ready EDGE will arrive — the adapter was already ready when the hold
    # committed (the lost-edge case). The post-commit level read must probe.
    start_supervised!(
      {CoordinatorStub,
       checkout: {:error, :degraded}, ready: {:ok, {"01AAAAAAAAAAAAAAAAAAAAAAAA", 4}}}
    )

    run_failing_turn(ctx, "fault")

    assert probe_count(ctx.db) == 1
    assert hold(ctx.db) != "*"
    assert AdapterCoordinator.decode_token(episode(ctx.db).heal_token) ==
             {"01AAAAAAAAAAAAAAAAAAAAAAAA", 4}
  end

  ## Proof 4 — visibility, and genuine decisions stay human

  test "proof 4: decision-requests lists open holds with their cause, to owner and admin", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")
    episode_id = episode(ctx.db).episode_id

    owner_call = %{origin: "user:flynn", principal: {:user, "flynn"}, params: %{}}

    holds =
      Escalation.list(ctx.db, owner_call, "open", owner_user_id: "flynn")
      |> Enum.filter(&(&1.kind == "adjudication_hold"))

    assert [
             %{
               kind: "adjudication_hold",
               id: id,
               status: "open",
               cause: @cause,
               disposition: "auto_on_adapter_heal",
               session_key: "k1"
             } = row
           ] = holds

    assert id == "hold:" <> episode_id
    assert is_integer(row.raised_at)

    # The singular fetch accepts the hold id form, read-only.
    assert ^row = Escalation.get(ctx.db, owner_call, id, owner_user_id: "flynn")

    # A probe-in-flight hold is STILL a hold: the resolved episode stays listed.
    heal(ctx, {"01AAAAAAAAAAAAAAAAAAAAAAAA", 2})
    assert Adjudication.get(ctx.db, "k1", "other").status == "resolved"

    assert [%{id: ^id}] =
             Escalation.list(ctx.db, owner_call, "open", owner_user_id: "flynn")
             |> Enum.filter(&(&1.kind == "adjudication_hold"))

    # A stranger sees nothing; an admin sees the synthetic row.
    stranger = %{origin: "user:sam", principal: {:user, "sam"}, params: %{}}

    assert [] =
             Escalation.list(ctx.db, stranger, "open", owner_user_id: "sam")
             |> Enum.filter(&(&1.kind == "adjudication_hold"))

    assert [%{id: ^id}] =
             Escalation.list(ctx.db, stranger, "open", owner_user_id: "sam", admin: true)
             |> Enum.filter(&(&1.kind == "adjudication_hold"))

    # Releasing clears the row from the listing once the probe succeeds.
    assert {:ok, probe} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert :ok = Ledger.finish(ctx.db, probe.seq, "delivered")

    assert [] =
             Escalation.list(ctx.db, owner_call, "open", owner_user_id: "flynn")
             |> Enum.filter(&(&1.kind == "adjudication_hold"))
  end

  test "proof 4: a model_decision hold is never auto-released by an adapter heal", ctx do
    # The load-apply route: session/load succeeded but the model would not
    # apply. That is a GENUINE decision, and it must NOT be tagged adapter_fault
    # even though the failure came back through the adapter.
    Org.append_pointer(ctx.db, "k1", "harness-sid-1", "created")

    adapter =
      start_supervised!(
        {AdapterStub, knows?: false, load_session: {:error, {:model_apply_failed, :model_unavailable}}}
      )

    start_supervised!({CoordinatorStub, checkout: {:ok, adapter, 1}})

    {_seq, reason} = run_failing_turn(ctx, "swap me")
    assert reason == {:model_apply_failed, :model_unavailable}
    assert episode(ctx.db).cause == "model_decision"
    assert hold(ctx.db) == "*"

    # An adapter heal for this very session's adapter changes nothing.
    heal(ctx, {"01AAAAAAAAAAAAAAAAAAAAAAAA", 9})
    assert hold(ctx.db) == "*"
    assert probe_count(ctx.db) == 0
    assert episode(ctx.db).status == "notified"
    assert is_nil(episode(ctx.db).heal_token)

    # It IS visible, as awaiting a human ruling.
    owner_call = %{origin: "user:flynn", principal: {:user, "flynn"}, params: %{}}

    assert [%{disposition: "awaits_ruling", cause: "model_decision"}] =
             Escalation.list(ctx.db, owner_call, "open", owner_user_id: "flynn")
             |> Enum.filter(&(&1.kind == "adjudication_hold"))
  end

  test "proof 4: a human ruling on a healed episode is an acknowledged no-op", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)

    # The owner wake FIRED and its owner turn is queued — the r2-F2 case.
    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        DB.Txn.q(txn, "UPDATE wakes SET state='fired', firedAt=?2 WHERE wakeId=?1", [
          episode.owner_wake_id,
          System.system_time(:millisecond)
        ])
      end)

    heal(ctx, {"01AAAAAAAAAAAAAAAAAAAAAAAA", 2})
    probe_wake = hold(ctx.db)
    assert probe_wake != "*"

    # The ruling arrives late and loses to the episode-state CAS.
    handlers = Gateway.handlers(Map.put(ctx.config, :db, ctx.db))

    assert %{code: "denied"} =
             handlers["adjudicate"].(%{
               origin: "user:flynn",
               principal: {:session, episode.owner_target},
               params: %{episode: episode.correlation_key, action: "park"}
             })

    assert hold(ctx.db) == probe_wake

    assert Enum.any?(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "adjudication_ruling_superseded")
           )
  end

  test "proof 4: a ruling that armed its hold first is not swept", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")

    # A ruling already narrowed the hold to its own recovery wake — the sweep
    # only ever considers a WIDE hold, so this session is not a candidate.
    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        DB.Txn.q(txn, "UPDATE sessions SET adjudicationHold='w_ruling' WHERE sessionKey='k1'")
      end)

    heal(ctx, {"01AAAAAAAAAAAAAAAAAAAAAAAA", 2})

    assert hold(ctx.db) == "w_ruling"
    assert probe_count(ctx.db) == 0
    assert is_nil(episode(ctx.db).heal_token), "the loser must not stamp the token"
  end

  test "proof 4: two adapter-fault episodes on one session yield ONE probe; the loser logs", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")

    # A second open episode on the SAME session, same cause. Both are swept, but
    # the first release narrows the hold, so the second loses the in-transaction
    # CAS — the interleaving a concurrent human ruling would also produce.
    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        Adjudication.claim_in_txn(txn, "k1", "boot_failed",
          claim_window_ms: 300_000,
          cause: @cause
        )
      end)

    heal(ctx, {"01AAAAAAAAAAAAAAAAAAAAAAAA", 2})

    assert probe_count(ctx.db) == 1, "a session gets one probe, not one per episode"
    assert hold(ctx.db) != "*"

    assert [%{subject: "k1", detail: detail}] =
             Enum.filter(EventLog.lifecycle_events(ctx.db), &(&1.kind == "adjudication_heal_lost"))

    # Exactly one episode stamped the token; the logged loser is the other, and
    # having stamped nothing it stays eligible for a later token.
    stamped =
      for condition <- ["other", "boot_failed"],
          episode = Adjudication.get(ctx.db, "k1", condition),
          not is_nil(episode.heal_token),
          do: condition

    assert [winner] = stamped
    loser = Enum.find(["other", "boot_failed"], &(&1 != winner))
    assert detail =~ loser
  end

  ## Proof 5 — legacy holds are untouched

  test "proof 5: a legacy NULL-cause hold is never swept by a heal event", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")

    # A row predating the column: cause and episodeId NULL.
    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        DB.Txn.q(
          txn,
          "UPDATE adjudication_episodes SET cause=NULL, episodeId=NULL WHERE sessionKey='k1'"
        )
      end)

    heal(ctx, {"01AAAAAAAAAAAAAAAAAAAAAAAA", 2})

    assert hold(ctx.db) == "*"
    assert probe_count(ctx.db) == 0
    assert is_nil(episode(ctx.db).cause)
    assert is_nil(episode(ctx.db).heal_token)

    # A legacy row IS listed once boot reconciliation gives it a read handle.
    :ok = Adjudication.reconcile(ctx.db)
    assert is_binary(episode(ctx.db).episode_id)

    owner_call = %{origin: "user:flynn", principal: {:user, "flynn"}, params: %{}}

    assert [%{cause: nil, disposition: "awaits_ruling"}] =
             Escalation.list(ctx.db, owner_call, "open", owner_user_id: "flynn")
             |> Enum.filter(&(&1.kind == "adjudication_hold"))
  end

  ## Helpers

  # Deliver a prompt, claim it, run the real gateway turn runner, then close the
  # turn exactly the way SessionLane.finalize does for an adjudicated failure.
  defp run_failing_turn(ctx, prompt) do
    runner = turn_runner(ctx)

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", prompt,
               db: ctx.db,
               client_message_id: "c_#{System.unique_integer([:positive])}"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "lane")
    fail_claimed_turn(ctx, turn, runner)
  end

  defp fail_claimed_turn(ctx, turn, runner \\ nil) do
    runner = runner || turn_runner(ctx)

    assert {:error, %{reason: reason, adjudicate_in_txn: adjudicate, post_commit: post_commit}} =
             runner.(Map.put(turn, :session_key, "k1"))

    assert {:ok, true} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", inspect(reason))
               adjudicate.(txn)
               true
             end)

    post_commit.()
    {turn.seq, reason}
  end

  defp turn_runner(ctx) do
    {Tightbeam.LaneManager, lane_opts} =
      ctx.config
      |> Gateway.children()
      |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

    Keyword.fetch!(lane_opts, :runner)
  end

  defp heal(ctx, token), do: Gateway.adapter_healed(ctx.config, ctx.db, @cause, token)

  defp hold(db) do
    {:ok, [[hold]]} =
      DB.query(db, "SELECT adjudicationHold FROM sessions WHERE sessionKey='k1'")

    hold
  end

  defp episode(db), do: Adjudication.get(db, "k1", "other")

  # Probe turns are the ones carrying the probe prompt — counting them is how
  # storm-freedom is measured.
  defp probe_count(db) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT count(*) FROM turns WHERE sessionKey='k1' AND prompt LIKE ?1", [
        "%adapter recovered%"
      ])

    count
  end

  defp last_queued_seq(db) do
    {:ok, [[seq]]} =
      DB.query(db, "SELECT max(seq) FROM turns WHERE sessionKey='k1' AND status='queued'")

    seq
  end

  defp turn_status(db, seq) do
    {:ok, [[status]]} = DB.query(db, "SELECT status FROM turns WHERE seq=?1", [seq])
    status
  end

  defp turn_error(db, seq) do
    {:ok, [[error]]} = DB.query(db, "SELECT error FROM turns WHERE seq=?1", [seq])
    error
  end
end
