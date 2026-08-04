defmodule Tightbeam.AdapterHealTest do
  @moduledoc """
  Proofs for spec s4-operability-v1 — adapter faults heal DARK.

  Everything asserted here lives on OUR side of the ACP seam (SQL, durability,
  ordering, races), which is what makes staged pathologies legitimate: the
  coordinator is a stub so a fault can be induced deterministically, but the
  adapter in proof 1 is a REAL process spawning a REAL non-executable binary —
  the reason under test is produced by `sh`, not by the test.
  """
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    AdapterCoordinator,
    Adjudication,
    ConnRegistry,
    DB,
    Devices,
    Escalation,
    EventLog,
    Gateway,
    Ledger,
    ModelCatalog,
    Org,
    Wakes
  }

  @cause "adapter_fault:claude:shared@testhost"

  defmodule LaneDoorbell do
    @moduledoc false
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

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

    def handle_call({:current_model, _sid}, _from, state),
      do: {:reply, Map.get(state, :current_model, {:error, :model_readback_unavailable}), state}
  end

  # The HARNESS side of a model swap. `held/1` is a read of the running agent,
  # while the record is the canonical value each reattach pushes. `on_applied`
  # fires INSIDE the accepted swap, which is the seam F3 needs — the live
  # harness has already moved, and nothing the ruling does has run yet.
  defmodule SwapAdapterStub do
    @moduledoc false
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    def init(state) do
      model = Map.fetch!(state, :model)

      state =
        state
        |> Map.put_new(:apply_count, 0)
        |> Map.put_new(:load_count, 0)
        |> Map.put_new(:known, true)
        |> Map.put_new(:cached_model, model)

      {:ok, state}
    end

    def held(pid), do: GenServer.call(pid, :held)
    def apply_count(pid), do: GenServer.call(pid, :apply_count)
    def load_count(pid), do: GenServer.call(pid, :load_count)
    def cached(pid), do: GenServer.call(pid, :cached)

    def handle_call({:apply_model_strict, _sid, model, prior_model, _deadline}, _from, state) do
      if state.cached_model == prior_model do
        state =
          %{
            state
            | model: model,
              cached_model: model,
              apply_count: state.apply_count + 1
          }
          |> Map.put(:known, is_nil(state[:strict_error]))

        if fire = state[:on_applied], do: fire.()

        case state[:strict_error] do
          nil -> {:reply, {:ok, model}, state}
          reason -> {:reply, {:error, reason}, %{state | cached_model: nil}}
        end
      else
        state = %{state | known: false}
        {:reply, {:error, :model_readback_unavailable}, state}
      end
    end

    def handle_call(:held, _from, state), do: {:reply, state.model, state}
    def handle_call(:cached, _from, state), do: {:reply, state.cached_model, state}
    def handle_call(:apply_count, _from, state), do: {:reply, state.apply_count, state}
    def handle_call(:load_count, _from, state), do: {:reply, state.load_count, state}

    def handle_call({:knows_session?, _sid}, _from, state),
      do: {:reply, state.known, state}

    def handle_call({:load_session, _sid, model, _cwd, _mcp, _guidance}, _from, state) do
      case model do
        %Tightbeam.Model{} = model ->
          state = %{
            state
            | model: model,
              known: true,
              cached_model: model,
              load_count: state.load_count + 1
          }

          {:reply, {:ok, model}, state}

        _unknown ->
          state = %{state | known: true, cached_model: nil, load_count: state.load_count + 1}
          {:reply, {:ok, :unknown}, state}
      end
    end

    def handle_call({:apply_model, _sid, model}, _from, state) do
      if state[:block_apply] do
        send(state.parent, {:tune_apply_waiting, self()})

        receive do
          :release_tune_apply -> :ok
        end
      end

      if parent = state[:parent], do: send(parent, {:tune_model_applied, model})

      case state[:apply_error] do
        nil -> {:reply, :ok, %{state | model: model, cached_model: model}}
        reason -> {:reply, {:error, reason}, state}
      end
    end

    def handle_call({:prompt, _sid, _text, _opts}, _from, state) do
      case state[:prompt_error] do
        nil -> {:reply, {:ok, %{stop_reason: "end_turn", text: "continued"}}, state}
        reason -> {:reply, {:error, reason}, state}
      end
    end

    def handle_call({:current_model, _sid}, _from, state),
      do: {:reply, {:ok, state.cached_model}, state}

    def handle_call({:forget_model_residency, _sid}, _from, state),
      do: {:reply, :ok, %{state | known: false, cached_model: nil}}

    def handle_call({:on_applied, fun}, _from, state),
      do: {:reply, :ok, Map.put(state, :on_applied, fun)}
  end

  defmodule DyingAdapter do
    @moduledoc false
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)
    def init(state), do: {:ok, state}

    def handle_call({:knows_session?, _sid}, _from, state), do: {:reply, true, state}

    def handle_call({:current_model, _sid}, _from, state),
      do: {:reply, {:ok, "claude-fable-5"}, state}

    def handle_call({:apply_model, _sid, _model}, _from, state), do: {:reply, :ok, state}

    # What Acp.Adapter's own {:acp_exit, status} handler produces when the harness
    # process dies mid-turn: the adapter stops before it can reply.
    def handle_call({:prompt, _sid, _text, _opts}, _from, state),
      do:
        {:stop, {:adapter_fault, %{reason: {:acp_exit, 137}, stderr: "harness died mid-turn"}},
         state}
  end

  defmodule RaceDB do
    @moduledoc false
    use GenServer

    @doc "Forwards to `real`; runs `before_txn` once, just before transaction #`at`."
    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    def init(state), do: {:ok, Map.put(state, :txns, 0)}

    def handle_call({:transaction, fun}, _from, state) do
      count = state.txns + 1

      state =
        if count == state.at do
          state.before_txn.()
          Map.put(state, :fired, true)
        else
          state
        end

      {:reply, GenServer.call(state.real, {:transaction, fun}, 30_000),
       Map.put(state, :txns, count)}
    end

    def handle_call(message, _from, state),
      do: {:reply, GenServer.call(state.real, message, 30_000), state}
  end

  defmodule RulingQueryBarrierDB do
    @moduledoc false
    use GenServer

    @doc "Captures the first correlation query result, then blocks before returning it."
    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    def init(state), do: {:ok, Map.put(state, :captured, false)}

    def handle_call({:query, sql, _params} = message, _from, state) do
      reply = GenServer.call(state.real, message, 30_000)

      state =
        if not state.captured and String.contains?(sql, "WHERE correlationKey=?1") do
          send(state.parent, {:ruling_read_episode, self()})

          receive do
            :release_ruling -> :ok
          end

          %{state | captured: true}
        else
          state
        end

      {:reply, reply, state}
    end

    def handle_call(message, _from, state),
      do: {:reply, GenServer.call(state.real, message, 30_000), state}
  end

  defmodule ModelReadBarrierDB do
    @moduledoc false
    use GenServer

    @doc "Forwards to `real`; blocks the turn's first post-session-read query."
    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    def init(state), do: {:ok, Map.merge(state, %{blocked: false, read_model: nil})}

    def handle_call({:query, sql, params} = message, _from, state) do
      state =
        if not state.blocked and String.contains?(sql, "FROM messages WHERE id = ?1") do
          send(state.parent, {:turn_has_read_model, self(), state.read_model})

          receive do
            :release_turn -> :ok
          end

          %{state | blocked: true}
        else
          state
        end

      reply = GenServer.call(state.real, message, 30_000)

      state =
        case {String.contains?(sql, "FROM sessions"), params, reply} do
          {true, ["k1"], {:ok, [row]}} -> Map.put(state, :read_model, Enum.at(row, 17))
          _ -> state
        end

      {:reply, reply, state}
    end

    def handle_call(message, _from, state),
      do: {:reply, GenServer.call(state.real, message, 30_000), state}
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

    def set_ready(token), do: GenServer.call(Tightbeam.AdapterCoordinator, {:set_ready, token})

    def handle_call({:adapter_for, _key}, _from, state) do
      reply =
        case Map.get(state, :checkout, {:error, :degraded}) do
          fun when is_function(fun, 0) -> fun.()
          checkout -> checkout
        end

      {:reply, reply, state}
    end

    def handle_call({:ready_token, _key}, _from, state) do
      {:reply, Map.get(state, :ready, :not_ready), state}
    end

    def handle_call({:last_failure, _key, generation}, _from, state) do
      {:reply, Map.get(state, :failures, %{})[generation], state}
    end

    def handle_call({:set_ready, token}, _from, state),
      do: {:reply, :ok, Map.put(state, :ready, token)}

    def handle_call({:acquire_load_slot, _machine, _borrower}, _from, state),
      do: {:reply, make_ref(), state}

    def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
    def handle_cast({:release_load_slot, _machine, _slot}, state), do: {:noreply, state}
  end

  setup do
    db = :"heal_db_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: Tightbeam.TurnTaskSupervisor})
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})
    scheduler = start_supervised!({WakeSchedulerStub, self()})

    catalog_base =
      Path.join(System.tmp_dir!(), "heal-catalog-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([catalog_base, "auth", "claude"]))
    File.write!(Path.join([catalog_base, "auth", "claude", ".credentials.json"]), ~s({"claudeAiOauth":{"accessToken":"test-token"}}))
    on_exit(fn -> File.rm_rf!(catalog_base) end)

    start_supervised!(
      {ModelCatalog,
       base_dir: catalog_base,
       db: db,
       codex_home: Path.join(catalog_base, "codex"),
       claude_fetch: fn _, _ -> {:error, :offline} end,
       codex_read: fn _ -> {:error, :offline} end}
    )

    {:paired, _device} =
      Devices.pair(db, %{
        device_id: "flynn-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    # flynn's actual main stream. `k1` is named "Main" but is not keyed as one,
    # and adjudication notices climb the lineage ladder to the OWNER's main
    # session — which the ladder now verifies exists instead of composing its
    # key. Without this row every episode here is undeliverable and stays
    # claimed, which is a different proof from the ones in this file.
    for key <- [Org.personal_session_key("flynn"), "k1"] do
      Org.create(db, %{
        session_key: key,
        display_name: "Main",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("claude-fable-5")
      })
    end

    base = Path.join(System.tmp_dir!(), "heal_base_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 60_000,
      onboarding_lease_ms: 1_800_000,
      wake_scheduler: scheduler,
      db: db
    }

    %{db: db, config: config}
  end

  ## Proof 1 — the boot failure's DESIGNED reason reaches the turn

  test "proof 1: an adapter whose binary cannot execute fails the TURN with the spawn error",
       ctx do
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
        {DynamicSupervisor,
         strategy: :one_for_one, name: :"heal_adapter_sup_#{:erlang.unique_integer([:positive])}"}
      )

    start_supervised!(
      {AdapterCoordinator,
       adapter_sup: sup,
       db: ctx.db,
       adapter_context: fn _ -> [] end,
       adapter_opts: fn _key, _context ->
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
    #
    # These four already accept BOTH informative outcomes of the boot race and
    # reject only the uninformative one, so they are deliberately left as they
    # are. The turn either queued behind the failing boot and carries
    # {:initialize_failed, _} directly, or it arrived after the death and the
    # gateway enriched :noproc from the coordinator's attempt-scoped record
    # (gateway.ex enrich_adapter_unavailable/4) — and that record IS the
    # adapter's exit reason, {:adapter_fault, %{reason: {:initialize_failed, _},
    # stderr: line}}, which failure_text/1 renders with all three tokens below.
    # Both sides name the binary; that is what #78 entitles a caller to.
    #
    # The THIRD outcome is the one this must keep catching: if the coordinator
    # has not yet processed the :DOWN, last_failure returns nil and the caller
    # gets the bare string "adapter is not running", naming neither the binary
    # nor the stderr. A red here under load is that window being visible, NOT a
    # flake to silence — see #121. Widening this to accept the bare string would
    # delete the only binary-naming assertion in the suite.
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

  test "the owner's brief names the precise cause and known canonical model", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "the turn whose brief must be legible")

    episode = episode(ctx.db)
    assert episode.cause == @cause
    prompt = Wakes.get(ctx.db, episode.owner_wake_id).prompt

    # The brief used to carry only the coarse bucket, so a reader saw
    # `condition=other` for a fault the record already named precisely.
    assert prompt =~ "cause=#{@cause}"
    assert prompt =~ "affected_session=k1"

    # The condition stays too — it is what the episode is keyed on — but it is
    # no longer the only classification the human gets.
    assert prompt =~ "condition="
    refute prompt =~ "cause=unclassified"
    assert prompt =~ "current_model=claude-fable-5"
  end

  test "the owner's brief reports the known canonical record after it is pushed", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        model: Model.new("claude-sonnet-4-6"),
        cached_model: Model.new("claude-fable-5"),
        prompt_error: :prompt_dispatch_failed
      )

    swap_ready(adapter, nil)
    run_failing_turn(ctx, "the turn whose brief must name the owner")

    assert Org.get(ctx.db, "k1").model == Model.new("claude-fable-5")
    assert SwapAdapterStub.held(adapter) == Model.new("claude-fable-5")
    assert SwapAdapterStub.cached(adapter) == Model.new("claude-fable-5")

    prompt = Wakes.get(ctx.db, episode(ctx.db).owner_wake_id).prompt
    assert prompt =~ "current_model=claude-fable-5"
    refute prompt =~ "current_model=claude-sonnet-4-6"
  end

  test "the owner's brief reports unknown when the canonical record is unknown", ctx do
    make_model_unknown(ctx.db, "k1")
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})

    run_failing_turn(ctx, "the turn whose model is genuinely unknown")

    prompt = Wakes.get(ctx.db, episode(ctx.db).owner_wake_id).prompt
    assert prompt =~ "current_model=unknown"
  end

  test "resident stale adapter cache is replaced by the canonical record", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        model: Model.new("claude-sonnet-4-6"),
        cached_model: Model.new("claude-fable-5")
      )

    Org.set_model(ctx.db, "k1", Model.new("claude-sonnet-4-6"), "anthropic")
    swap_ready(adapter, nil)

    run_residency_pass(ctx)

    assert Org.get(ctx.db, "k1").model == Model.new("claude-sonnet-4-6")
    assert SwapAdapterStub.held(adapter) == Model.new("claude-sonnet-4-6")
    assert SwapAdapterStub.cached(adapter) == Model.new("claude-sonnet-4-6")
    assert SwapAdapterStub.load_count(adapter) == 0
  end

  ## Proof 2 — fault → hold → heal → auto-release, probe FIRST

  test "proof 2: heal releases the hold via a probe that claims before an older queued turn",
       ctx do
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
    heal(ctx, {7, 2})

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

  test "proof 3: replaying a token probes nothing; a strictly newer one probes exactly once",
       ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")

    epoch = 7
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

      before_rehold = System.system_time(:millisecond)
      epoch = 7
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

      # TOTALITY: every non-delivered probe terminal arms exactly one retry
      # wake, deferred by the backoff — never due at the instant of the re-hold.
      assert [%{state: "pending", due_at: due_at}] = retry_wakes(ctx.db)
      assert due_at - before_rehold >= 5_000, "the retry must wait out a real backoff"

      # A replayed ready event on the SAME token still probes nothing...
      heal(ctx, {epoch, 2})
      assert probe_count(ctx.db) == 1
      assert hold(ctx.db) == "*"

      # ...and a strictly larger one probes exactly once, as before.
      heal(ctx, {epoch, 3})
      assert probe_count(ctx.db) == 2
      next_probe = hold(ctx.db)
      assert next_probe != "*" and next_probe != probe_wake
    end
  end

  test "proof 3: a re-held probe re-probes its own token exactly once, AFTER backoff — never immediately",
       ctx do
    # The storm guard survives verbatim: the failed probe reopens its episode
    # keeping healToken, so the post-commit level check (the coordinator still
    # reports ready at the SAME token) must NOT immediately probe again. What
    # died with the old clause (task #103): the re-held session then waited for
    # a strictly newer token that a HEALTHY adapter never mints. A re-hold is a
    # NEW hold; its one probe arrives via the armed retry wake instead.
    retry_immediately()
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")

    epoch = 7
    :ok = CoordinatorStub.set_ready({:ok, {epoch, 2}})
    heal(ctx, {epoch, 2})
    assert probe_count(ctx.db) == 1
    assert {:ok, probe} = Ledger.claim_next(ctx.db, "k1", "lane")

    # The probe turn fails the way any turn fails — runner, terminal CAS,
    # adjudication closure, post-commit — with the adapter still reported ready.
    fail_claimed_turn(ctx, probe)

    assert probe_count(ctx.db) == 1, "the level check must still refuse the equal token"
    assert hold(ctx.db) == "*"

    episode = episode(ctx.db)
    assert episode.cause == @cause

    assert AdapterCoordinator.decode_token(episode.heal_token) == {epoch, 2},
           "the token that already probed must survive the re-hold"

    # The scheduler's own tick delivers the retry: ONE probe, SAME token.
    fire_due_retries(ctx)
    assert probe_count(ctx.db) == 2
    next_probe = hold(ctx.db)
    assert is_binary(next_probe) and next_probe != "*"
    assert AdapterCoordinator.decode_token(episode(ctx.db).heal_token) == {epoch, 2}

    # The consumed retry replays as nothing: the probe is in flight.
    fire_due_retries(ctx)
    assert probe_count(ctx.db) == 2

    # A strictly larger token later still behaves as before.
    assert {:ok, probe2} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert :ok = Ledger.finish(ctx.db, probe2.seq, "failed")
    heal(ctx, {epoch, 3})
    assert probe_count(ctx.db) == 3
  end

  test "task #103 production shape: a healed adapter's queued backlog drains after a transient probe failure, with NO further heal edge",
       ctx do
    retry_immediately()
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")

    # FIVE real turns queue behind the hold — the wedged run's exact shape.
    for i <- 1..5 do
      assert :appended =
               Gateway.deliver_prompt("k1", "user:flynn", "work #{i}",
                 db: ctx.db,
                 client_message_id: "c_w#{i}"
               )
    end

    assert :none = Ledger.claim_next(ctx.db, "k1", "held")

    # The adapter heals: its ONE ready edge fires, and it stays level-ready.
    epoch = 7
    :ok = CoordinatorStub.set_ready({:ok, {epoch, 2}})
    heal(ctx, {epoch, 2})

    # The probe claims first — and fails transiently (the #20 boot-boundary
    # shape: the adapter reports ready, the probe's own call still failed).
    assert {:ok, probe} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert probe.prompt =~ "adapter recovered"
    fail_claimed_turn(ctx, probe)
    assert hold(ctx.db) == "*"

    # From here the adapter is HEALTHY — circuit closed, zero failures, no
    # death — so no further ready edge will EVER fire. Only the substrate's own
    # time machinery may act.
    fire_due_retries(ctx)

    # The retry probed; this probe succeeds — and the backlog drains IN ORDER.
    assert {:ok, probe2} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert probe2.prompt =~ "adapter recovered"
    assert :ok = Ledger.finish(ctx.db, probe2.seq, "delivered")
    assert is_nil(hold(ctx.db))

    for i <- 1..5 do
      assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "lane")
      assert turn.prompt == "work #{i}"
      assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    end

    assert Ledger.pending_count(ctx.db, "k1") == 0
  end

  test "a task-crash probe terminal (episode left RESOLVED, no reopen) still feeds the retry and drains",
       ctx do
    # The silent half of the wedge: a crashed probe re-holds without reopening
    # its episode, so neither the escalation ladder nor any future edge would
    # ever act. The retry must feed off the resolved-with-token episode too.
    retry_immediately()
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "queued work",
               db: ctx.db,
               client_message_id: "c_q"
             )

    :ok = CoordinatorStub.set_ready({:ok, {7, 2}})
    heal(ctx, {7, 2})
    assert {:ok, probe} = Ledger.claim_next(ctx.db, "k1", "lane")

    # SessionLane's :DOWN path: no adjudication closure runs.
    assert :ok = Ledger.finish(ctx.db, probe.seq, "failed", inspect(:task_crash))
    assert hold(ctx.db) == "*"
    assert episode(ctx.db).status == "resolved"

    fire_due_retries(ctx)

    assert {:ok, probe2} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert probe2.prompt =~ "adapter recovered"
    assert :ok = Ledger.finish(ctx.db, probe2.seq, "delivered")
    assert is_nil(hold(ctx.db))

    assert {:ok, work} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert work.prompt == "queued work"
  end

  test "credential stop/start inside the retry window still ends with the hold fed", ctx do
    retry_immediately()
    # The STOP half: a credential stop calls close_adapter, so by the time the
    # retry fires the adapter is torn down — ready defaults to :not_ready. The
    # retry probes nothing and consumes itself; the next edge owns the wake-up.
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")
    heal(ctx, {7, 2})
    assert {:ok, probe} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert :ok = Ledger.finish(ctx.db, probe.seq, "failed")
    assert hold(ctx.db) == "*"

    fire_due_retries(ctx)

    assert probe_count(ctx.db) == 1, "no readiness, no probe"
    assert hold(ctx.db) == "*"
    assert [%{state: "fired"}] = retry_wakes(ctx.db), "the retry is consumed, not left spinning"

    # The START half: close_adapter BUMPED the generation (the coordinator's
    # planned-close proof), so the restarted adapter's ready is STRICTLY newer
    # than the stamped {7, 2} — the ordinary edge sweep feeds the hold.
    heal(ctx, {7, 3})
    assert probe_count(ctx.db) == 2
    assert hold(ctx.db) != "*"
  end

  test "the retry honors a REAL backoff: a scheduler fire before dueAt delivers nothing", ctx do
    Application.put_env(:tightbeam, :adjudication_probe_retry_ms, 400)
    on_exit(fn -> Application.delete_env(:tightbeam, :adjudication_probe_retry_ms) end)

    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    # Built BEFORE the clock starts: the timed window below must measure the
    # backoff, not scheduler assembly.
    scheduler = retry_scheduler(ctx)
    run_failing_turn(ctx, "fault")
    :ok = CoordinatorStub.set_ready({:ok, {7, 2}})
    heal(ctx, {7, 2})
    assert {:ok, probe} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert :ok = Ledger.finish(ctx.db, probe.seq, "failed")
    assert [%{state: "pending", due_at: due_at}] = retry_wakes(ctx.db)

    # BEFORE the backoff elapses, the scheduler's fire delivers nothing — even
    # with the adapter ready and the hold eligible.
    #
    # The dueAt check states the precondition this negative rests on: the few
    # statements above have to fit inside the 400ms backoff. Load makes that RED
    # rather than a false pass — an overrun DELIVERS the probe — and this way the
    # failure names the overrun instead of blaming the probe count for it.
    assert due_at > System.system_time(:millisecond),
           "the backoff elapsed before the pre-deadline fire; this run proves nothing"

    Wakes.fire_due(scheduler)
    assert probe_count(ctx.db) == 1
    assert [%{state: "pending"}] = retry_wakes(ctx.db)

    # After it elapses: exactly one probe, and firing again adds nothing.
    Process.sleep(500)
    Wakes.fire_due(scheduler)
    assert probe_count(ctx.db) == 2
    Wakes.fire_due(scheduler)
    assert probe_count(ctx.db) == 2
  end

  test "a probe task crash through SessionLane's REAL monitored-task :DOWN branch re-holds and arms the retry",
       ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")
    :ok = CoordinatorStub.set_ready({:ok, {7, 2}})
    heal(ctx, {7, 2})
    probe_wake = hold(ctx.db)

    # A real lane, a real monitored TurnTask, a real crash — the exact :DOWN
    # branch production takes, not a hand-written terminal.
    start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})

    task_sup =
      start_supervised!(
        {Task.Supervisor, name: :"heal_tsup_#{System.unique_integer([:positive])}"}
      )

    start_supervised!(
      {Tightbeam.SessionLane,
       session_key: "k1", db: ctx.db, task_sup: task_sup, runner: fn _turn -> exit(:boom) end}
    )

    assert eventually(fn -> hold(ctx.db) == "*" end),
           "the crashed probe's :DOWN must re-hold the session"

    {:ok, [[error]]} = DB.query(ctx.db, "SELECT error FROM turns WHERE wakeId = ?1", [probe_wake])

    assert error =~ "task_crash"
    assert episode(ctx.db).status == "resolved", "no adjudication closure ran"

    assert [%{state: "pending"}] = retry_wakes(ctx.db),
           "the :DOWN terminal writer armed the retry"
  end

  test "a newer failure SUPERSEDES the pending retry: one pending wake, the newest, honoring its own full backoff",
       ctx do
    # Default (real) backoff throughout — dueAt comparisons are meaningful.
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")
    epoch = 7
    heal(ctx, {epoch, 2})
    assert {:ok, p1} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert :ok = Ledger.finish(ctx.db, p1.seq, "failed")
    assert [%{state: "pending", wake_id: r1}] = retry_wakes(ctx.db)

    # A genuinely newer edge probes immediately (the strict path, unchanged)...
    heal(ctx, {epoch, 3})
    assert probe_count(ctx.db) == 2
    assert {:ok, p2} = Ledger.claim_next(ctx.db, "k1", "lane")

    # ...and ITS failure arms the newest retry, superseding the stale one — a
    # stale retry firing early would hand the newer hold a probe before its
    # backoff elapsed.
    armed_at = System.system_time(:millisecond)
    assert :ok = Ledger.finish(ctx.db, p2.seq, "failed")

    assert %{state: "canceled"} = Enum.find(retry_wakes(ctx.db), &(&1.wake_id == r1))
    assert [%{due_at: due_at}] = Enum.filter(retry_wakes(ctx.db), &(&1.state == "pending"))
    assert due_at - armed_at >= 25_000, "the newest retry honors its own FULL backoff"
  end

  test "boot reconciliation of a VANISHED probe turn re-holds and arms the same retry exactly once",
       ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")
    heal(ctx, {7, 2})
    probe_wake = hold(ctx.db)

    # The probe turn never reached a terminal and its row is gone — the shape
    # boot reconciliation re-holds rather than clears.
    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        DB.Txn.q(txn, "DELETE FROM turns WHERE wakeId = ?1", [probe_wake])
      end)

    :ok = Adjudication.reconcile(ctx.db)
    assert hold(ctx.db) == "*"
    assert [%{state: "pending"}] = retry_wakes(ctx.db)

    # Reconciling again arms nothing further (idempotent per failed probe).
    :ok = Adjudication.reconcile(ctx.db)
    assert [_only_one] = retry_wakes(ctx.db)
  end

  test "proof 3: a task-crash probe terminal re-holds (no adjudication closure runs)", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")
    heal(ctx, {7, 2})
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

    heal(ctx, {11, 7})
    assert {:ok, probe} = Ledger.claim_next(ctx.db, "k1", "lane")
    assert :ok = Ledger.finish(ctx.db, probe.seq, "failed")
    assert hold(ctx.db) == "*"

    # A restarted coordinator mints a LARGER epoch and resets generation to 1.
    # Generation alone would read as older; epoch-first ordering is what makes
    # the sweep restart-stable.
    assert AdapterCoordinator.newer_token?({12, 1}, {11, 7})

    heal(ctx, {12, 1})
    assert probe_count(ctx.db) == 2
    assert hold(ctx.db) != "*"
  end

  test "proof 3: the LEVEL trigger probes a hold that commits after the ready already fired",
       ctx do
    # No ready EDGE will arrive — the adapter was already ready when the hold
    # committed (the lost-edge case). The post-commit level read must probe.
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}, ready: {:ok, {7, 4}}})

    run_failing_turn(ctx, "fault")

    assert probe_count(ctx.db) == 1
    assert hold(ctx.db) != "*"

    assert AdapterCoordinator.decode_token(episode(ctx.db).heal_token) ==
             {7, 4}
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
    heal(ctx, {7, 2})
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
        {AdapterStub,
         knows?: false, load_session: {:error, {:model_apply_failed, :model_unavailable}}}
      )

    start_supervised!({CoordinatorStub, checkout: {:ok, adapter, 1}})

    {_seq, reason} = run_failing_turn(ctx, "swap me")
    assert reason == {:model_apply_failed, :model_unavailable}
    assert episode(ctx.db).cause == "model_decision"
    assert hold(ctx.db) == "*"

    # An adapter heal for this very session's adapter changes nothing.
    heal(ctx, {7, 9})
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

    heal(ctx, {7, 2})
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

    superseded =
      Enum.find(
        EventLog.lifecycle_events(ctx.db),
        &(&1.kind == "adjudication_ruling_superseded")
      )

    assert JSON.decode!(superseded.detail)["healToken"] == "7:2"
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

    heal(ctx, {7, 2})

    assert hold(ctx.db) == "w_ruling"
    assert probe_count(ctx.db) == 0
    assert is_nil(episode(ctx.db).heal_token), "the loser must not stamp the token"
  end

  test "proof 4: two adapter-fault episodes on one session yield ONE probe; the loser logs",
       ctx do
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

    heal(ctx, {7, 2})

    assert probe_count(ctx.db) == 1, "a session gets one probe, not one per episode"
    assert hold(ctx.db) != "*"

    assert [%{subject: "k1", detail: detail}] =
             Enum.filter(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "adjudication_heal_lost")
             )

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

    heal(ctx, {7, 2})

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

  ## Cross-review regressions (Sol CHANGES-REQUIRED, 2026-07-26)

  test "F1: a harness that dies MID-PROMPT opens an adapter_fault hold, not a bare task_crash",
       ctx do
    Org.append_pointer(ctx.db, "k1", "harness-sid-live", "created")
    adapter = start_supervised!({DyingAdapter, []}, restart: :temporary)
    start_supervised!({CoordinatorStub, checkout: {:ok, adapter, 1}})

    {seq, reason} = run_failing_turn(ctx, "a turn the harness dies during")

    # The designed error, NOT an exit the lane can only record as :task_crash.
    assert {:adapter_unavailable, text} = reason
    assert text =~ "acp_exit"
    assert text =~ "harness died mid-turn"
    refute turn_error(ctx.db, seq) =~ "task_crash"

    # ...which is what lets the adjudication closure run at all: a runtime fault
    # is a tagged, heal-eligible hold.
    assert hold(ctx.db) == "*"
    assert episode(ctx.db).cause == @cause
  end

  test "F2: coordinator epochs are STRICTLY increasing, with no same-millisecond ties", ctx do
    # ULIDs tie randomly inside a millisecond, which could make a fast restart
    # reject its own ready token and wedge the hold. The durable counter cannot.
    epochs = for _ <- 1..2_000, do: AdapterCoordinator.mint_epoch(ctx.db)

    assert length(Enum.uniq(epochs)) == 2_000
    assert epochs == Enum.sort(epochs)
    assert Enum.chunk_every(epochs, 2, 1, :discard) |> Enum.all?(fn [a, b] -> b > a end)

    # The SAME-MILLISECOND pair the reviewer's probe found a ULID losing: two
    # epochs minted inside one millisecond must still be strictly ordered.
    same_ms =
      Stream.repeatedly(fn ->
        before = System.system_time(:millisecond)
        pair = {AdapterCoordinator.mint_epoch(ctx.db), AdapterCoordinator.mint_epoch(ctx.db)}
        {before == System.system_time(:millisecond), pair}
      end)
      |> Enum.find(fn {same_ms?, _pair} -> same_ms? end)

    assert {true, {first, second}} = same_ms
    assert second > first, "a same-millisecond mint pair must still be strictly increasing"

    # And the ordering the sweep actually relies on: a later epoch with a RESET
    # generation still outranks an earlier epoch's high generation.
    [early, late] = [Enum.at(epochs, 0), Enum.at(epochs, -1)]
    assert AdapterCoordinator.newer_token?({late, 1}, {early, 999})
    refute AdapterCoordinator.newer_token?({early, 999}, {late, 1})
  end

  test "F2: an epoch survives a coordinator restart and keeps increasing", ctx do
    first = AdapterCoordinator.mint_epoch(ctx.db)
    # A restart re-reads the durable counter rather than minting from the clock.
    second = AdapterCoordinator.mint_epoch(ctx.db)
    assert second > first
  end

  test "F3: a DELAYED PARK ruling is not overwritten by a later heal", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)

    # The REAL park verb: it resolves the episode and schedules a condition wake,
    # and it deliberately leaves the hold WIDE until that wake fires. A hold-only
    # guard would let the heal below overwrite this human ruling.
    handlers = Gateway.handlers(Map.put(ctx.config, :db, ctx.db))

    assert %{ok: true, action: "park"} =
             handlers["adjudicate"].(%{
               origin: "user:flynn",
               principal: {:session, episode.owner_target},
               params: %{episode: episode.correlation_key, action: "park"}
             })

    parked = episode(ctx.db)
    assert parked.status == "resolved"
    assert is_nil(parked.heal_token), "a human ruling stamps no heal token"
    assert hold(ctx.db) == "*", "park leaves the hold wide — the F3 precondition"

    heal(ctx, {7, 2})

    assert probe_count(ctx.db) == 0, "the heal must not overwrite a winning ruling"
    assert hold(ctx.db) == "*"
    assert episode(ctx.db).recovery_wake_id == parked.recovery_wake_id
    assert is_nil(episode(ctx.db).heal_token)
    assert Enum.any?(EventLog.lifecycle_events(ctx.db), &(&1.kind == "adjudication_heal_lost"))
  end

  test "F3: a ruling queued behind a winning heal is DENIED, not a crash", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)

    # The heal owns the session-mutation lock before its transaction starts.
    # The ruling still validates the old notified snapshot while the heal is
    # paused, then queues behind the lock and must observe the heal as winner.
    parent = self()

    proxy =
      start_supervised!(
        {RaceDB,
         real: ctx.db,
         at: 1,
         before_txn: fn ->
           send(parent, {:heal_has_lock, self()})

           receive do
             :release_heal -> :ok
           end
         end}
      )

    healing =
      Task.async(fn ->
        Gateway.adapter_healed(ctx.config, proxy, @cause, {7, 2})
      end)

    assert_receive {:heal_has_lock, heal_proxy}

    ruling_db =
      start_supervised!({RulingQueryBarrierDB, real: ctx.db, parent: self()})

    ruling =
      Task.async(fn ->
        Gateway.handlers(Map.put(ctx.config, :db, ruling_db))["adjudicate"].(%{
          origin: "user:flynn",
          principal: {:session, episode.owner_target},
          params: %{episode: episode.correlation_key, action: "park"}
        })
      end)

    assert_receive {:ruling_read_episode, ruling_db}
    send(heal_proxy, :release_heal)
    assert [{"k1", "other", :released}] = Task.await(healing)

    send(ruling_db, :release_ruling)
    result = Task.await(ruling)

    # The ruling is DENIED — not a MatchError escaping to the wire.
    assert %{code: "denied"} = result

    probe = hold(ctx.db)
    assert is_binary(probe) and probe != "*"

    # The probe still owns the hold, and park's own wake was never left behind.
    assert Adjudication.get(ctx.db, "k1", "other").recovery_wake_id == probe

    superseded =
      Enum.find(
        EventLog.lifecycle_events(ctx.db),
        &(&1.kind == "adjudication_ruling_superseded")
      )

    assert is_nil(JSON.decode!(superseded.detail)["healToken"])
  end

  test "F3: a heal arriving after the harness moved cannot split the atomic ruling", ctx do
    adapter = swap_harness(ctx, checkout: {:error, :degraded})
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    assert Org.get(ctx.db, "k1").model == Model.new("claude-fable-5")

    # The heal starts after the harness accepted the model. The session-mutation
    # worker still owns the lock, so the heal cannot resolve the episode until
    # the ruling's projection and recovery prompt commit.
    parent = self()

    swap_ready(adapter, fn ->
      adapter_process = self()

      spawn(fn ->
        send(adapter_process, :heal_started)
        heal(ctx, {7, 2})
        send(parent, {:heal_finished, hold(ctx.db)})
      end)

      receive do
        :heal_started -> :ok
      end
    end)

    result =
      Gateway.handlers(ctx.config)["adjudicate"].(%{
        origin: "user:flynn",
        principal: {:session, episode.owner_target},
        params: %{
          episode: episode.correlation_key,
          action: "swap",
          model: "claude-sonnet-4-6"
        }
      })

    assert %{ok: true, action: "swap", model: "claude-sonnet-4-6"} = result
    assert_receive {:heal_finished, recovery_wake}
    assert is_binary(recovery_wake) and recovery_wake != "*"
    assert is_nil(episode(ctx.db).heal_token)

    # Which model is loaded is the HARNESS's fact; the record is its projection.
    assert SwapAdapterStub.held(adapter) == Model.new("claude-sonnet-4-6")

    assert Org.get(ctx.db, "k1").model == SwapAdapterStub.held(adapter),
           "the record disagrees with the running agent about which model is loaded"

    # And it is legible: `sessions.model` moved, so the row that says WHY is there.
    assert Enum.any?(EventLog.lifecycle_events(ctx.db), &(&1.kind == "model_adjudication"))

    assert Org.get(ctx.db, "k1").model == Model.new("claude-sonnet-4-6")
  end

  # An adjudication record has to be able to say what happened. Serializing the
  # identity WITHOUT its effort made a medium->high ruling record the same value
  # on both sides: existing audit information, destroyed.
  test "a same-model effort ruling is legible in the record", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        efforts: ["medium", "high"],
        model: Model.new("claude-fable-5", effort: "medium"),
        cached_model: Model.new("claude-fable-5", effort: "medium")
      )

    Org.set_model(ctx.db, "k1", Model.new("claude-fable-5", effort: "medium"), "anthropic")
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    swap_ready(adapter, nil)

    assert %{ok: true, action: "swap", model: "claude-fable-5", effort: "high"} =
             Gateway.handlers(ctx.config)["adjudicate"].(%{
               origin: "user:flynn",
               principal: {:session, episode.owner_target},
               params: %{
                 episode: episode.correlation_key,
                 action: "swap",
                 model: "claude-fable-5",
                 effort: "high"
               }
             })

    detail =
      EventLog.lifecycle_events(ctx.db)
      |> Enum.find(&(&1.kind == "model_adjudication"))
      |> Map.fetch!(:detail)
      |> JSON.decode!()

    # Same model on both sides — so the EFFORT is the only thing that can say
    # what the ruling did, and it has to be in the record.
    assert detail["from_model"] == "claude-fable-5"
    assert detail["to_model"] == "claude-fable-5"
    assert detail["from_effort"] == "medium"
    assert detail["to_effort"] == "high"
  end

  # A refusal has to be TRUE. An effort-less ruling on a tiered model used to
  # come back "model is not in a fresh harness inventory" — the model is right
  # there; what is missing is a tier. The asymmetry with spawn and tune is
  # deliberate: they INHERIT from a base they can name, and mid-swap there is
  # no clean base, so a ruling names its selection completely or is refused.
  test "an effort-less ruling on a tiered model is refused by name, not miscategorised", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        efforts: ["medium", "high"],
        model: Model.new("claude-fable-5", effort: "medium"),
        cached_model: Model.new("claude-fable-5", effort: "medium")
      )

    Org.set_model(ctx.db, "k1", Model.new("claude-fable-5", effort: "medium"), "anthropic")
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    swap_ready(adapter, nil)

    result =
      Gateway.handlers(ctx.config)["adjudicate"].(%{
        origin: "user:flynn",
        principal: {:session, episode.owner_target},
        params: %{
          episode: episode.correlation_key,
          action: "swap",
          model: "claude-sonnet-4-6"
        }
      })

    assert %{code: "invalid"} = result
    assert result.message =~ "has effort tiers"
    assert result.message =~ "medium|high"

    # The lie: the model IS in the inventory, so this must not be the refusal.
    refute result.message =~ "not in a fresh harness inventory"
    assert Org.get(ctx.db, "k1").model == Model.new("claude-fable-5", effort: "medium")
  end

  # ROUTABILITY IS ABOUT FRESH ENTRIES ONLY. A stale inventory is not evidence
  # that a model is absent — it is evidence of nothing — so a model offered
  # only by a stale harness must not be treated as routable, and the refusal
  # must say the model is not in a FRESH inventory rather than implying the
  # fleet does not have it.
  test "a model only a stale harness offers is not routable", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        efforts: ["medium", "high"],
        model: Model.new("claude-fable-5", effort: "medium"),
        cached_model: Model.new("claude-fable-5", effort: "medium")
      )

    Org.set_model(ctx.db, "k1", Model.new("claude-fable-5", effort: "medium"), "anthropic")
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    swap_ready(adapter, nil)

    # Age codex's inventory past its TTL. `refreshing: true` is load-bearing:
    # without it the next read triggers a refresh that resets `derived_at` and
    # the entry is fresh again by the time routability looks — a fixture that
    # would have made this test pass for the wrong reason.
    :sys.replace_state(ModelCatalog, fn state ->
      # Aged against the catalog's OWN clock. A literal timestamp is not
      # reliably old here — monotonic time starts negative — which is the sort
      # of fixture that silently ages nothing.
      stale_at = state.now.() - state.ttl_ms * 2

      state
      |> put_in([:entries, {"testhost", "codex"}, :derived_at], stale_at)
      |> put_in([:entries, {"testhost", "codex"}, :refreshing], true)
    end)

    assert {_entries, :stale} = ModelCatalog.get("testhost", "codex", ModelCatalog),
           "the fixture must actually be stale, or this test proves nothing"

    result =
      Gateway.handlers(ctx.config)["adjudicate"].(%{
        origin: "user:flynn",
        principal: {:session, episode.owner_target},
        params: %{episode: episode.correlation_key, action: "swap", model: "shared-model"}
      })

    # Claude has it TIERED and fresh, so the tier refusal is the true cause —
    # the stale codex entry contributes nothing in either direction.
    assert %{code: "invalid"} = result
    assert result.message =~ "has effort tiers"
    refute result.message =~ "codex"
  end

  # Two FRESH harnesses both completely matching is genuine ambiguity, and it
  # must stay ambiguous rather than silently resolving to whichever was
  # enumerated first.
  test "two harnesses that both completely match are refused as ambiguous", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        efforts: ["medium", "high"],
        model: Model.new("claude-fable-5", effort: "medium"),
        cached_model: Model.new("claude-fable-5", effort: "medium")
      )

    Org.set_model(ctx.db, "k1", Model.new("claude-fable-5", effort: "medium"), "anthropic")
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    swap_ready(adapter, nil)

    # Give codex the same family at the same tier: now BOTH match completely.
    :sys.replace_state(ModelCatalog, fn state ->
      update_in(state.entries[{"testhost", "codex"}].entries, fn entries ->
        entries ++
          [
            %{
              family: "claude-fable-5",
              context: nil,
              display_name: "claude-fable-5",
              name: "claude-fable-5",
              efforts: ["medium", "high"],
              max_input_tokens: 200_000,
              capabilities: %{},
              provider: :openai
            }
          ]
      end)
    end)

    result =
      Gateway.handlers(ctx.config)["adjudicate"].(%{
        origin: "user:flynn",
        principal: {:session, episode.owner_target},
        params: %{
          episode: episode.correlation_key,
          action: "swap",
          model: "claude-fable-5",
          effort: "high"
        }
      })

    assert %{code: "ambiguous_ref"} = result
    assert Org.get(ctx.db, "k1").model == Model.new("claude-fable-5", effort: "medium")
  end

  # THE THIRD DIRECTION of the same distinction. `unroutable/2` tells three
  # causes apart, and the other two tests only assert this message is NOT used
  # for them — a refute cannot catch the clause that produces it going wrong.
  # A model no fresh harness carries must still be reported as absent, or the
  # "named but wrong tier" message would start claiming models exist that do not.
  test "a model no fresh harness carries is still reported as absent", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        efforts: ["medium", "high"],
        model: Model.new("claude-fable-5", effort: "medium"),
        cached_model: Model.new("claude-fable-5", effort: "medium")
      )

    Org.set_model(ctx.db, "k1", Model.new("claude-fable-5", effort: "medium"), "anthropic")
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    swap_ready(adapter, nil)

    result =
      Gateway.handlers(ctx.config)["adjudicate"].(%{
        origin: "user:flynn",
        principal: {:session, episode.owner_target},
        params: %{
          episode: episode.correlation_key,
          action: "swap",
          model: "no-such-model",
          effort: "high"
        }
      })

    assert %{code: "model_unavailable"} = result
    assert result.message =~ "not in a fresh harness inventory"

    # …and it must NOT borrow the tier vocabulary for a model that is absent.
    refute result.message =~ "does not offer effort"
    refute result.message =~ "has effort tiers"
  end

  # THE TIER REFUSAL MUST NOT FIRE TOO EARLY. Whether a selection is routable is
  # a question about the WHOLE fleet: one harness tiering a model says nothing
  # if another offers it untiered, where an effort-less ruling is complete and
  # uniquely routable. Refusing on the first tiered entry found blocked a valid
  # swap — a check answering a narrower question than the caller asked.
  test "an effort-less ruling routes to a harness that offers the model untiered", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        efforts: ["medium", "high"],
        model: Model.new("claude-fable-5", effort: "medium"),
        cached_model: Model.new("claude-fable-5", effort: "medium")
      )

    Org.set_model(ctx.db, "k1", Model.new("claude-fable-5", effort: "medium"), "anthropic")
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    swap_ready(adapter, nil)

    # `shared-model` is TIERED on claude and UNTIERED on codex. Naming no effort
    # is therefore complete, and the only entry that can take it is codex's.
    result =
      Gateway.handlers(ctx.config)["adjudicate"].(%{
        origin: "user:flynn",
        principal: {:session, episode.owner_target},
        params: %{
          episode: episode.correlation_key,
          action: "swap",
          model: "shared-model"
        }
      })

    refute match?(%{code: "invalid"}, result),
           "a routable untiered selection must not be refused for naming no tier"

    # It routes, and reaches the cross-harness rule rather than a tier refusal.
    assert %{code: "cross_harness_requires_respawn"} = result
  end

  # Resolving a ruling on family and context alone would accept a level the
  # model does not offer and respawn the session onto an invalid selection.
  test "a ruling naming an effort the model does not offer is refused", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        efforts: ["medium", "high"],
        model: Model.new("claude-fable-5", effort: "medium"),
        cached_model: Model.new("claude-fable-5", effort: "medium")
      )

    Org.set_model(ctx.db, "k1", Model.new("claude-fable-5", effort: "medium"), "anthropic")
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    swap_ready(adapter, nil)

    assert %{code: "model_unavailable"} =
             Gateway.handlers(ctx.config)["adjudicate"].(%{
               origin: "user:flynn",
               principal: {:session, episode.owner_target},
               params: %{
                 episode: episode.correlation_key,
                 action: "swap",
                 model: "claude-fable-5",
                 effort: "ultra"
               }
             })

    assert Org.get(ctx.db, "k1").model == Model.new("claude-fable-5", effort: "medium")
  end

  test "F3: a swap that WINS records the model the harness confirmed, exactly once", ctx do
    adapter = swap_harness(ctx, checkout: {:error, :degraded})
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)

    swap_ready(adapter, nil)

    assert %{ok: true, action: "swap", model: "claude-sonnet-4-6"} =
             Gateway.handlers(ctx.config)["adjudicate"].(%{
               origin: "user:flynn",
               principal: {:session, episode.owner_target},
               params: %{
                 episode: episode.correlation_key,
                 action: "swap",
                 model: "claude-sonnet-4-6"
               }
             })

    assert SwapAdapterStub.held(adapter) == Model.new("claude-sonnet-4-6")
    assert Org.get(ctx.db, "k1").model == Model.new("claude-sonnet-4-6")
    assert Adjudication.get(ctx.db, "k1", "other").status == "resolved"

    assert Enum.count(EventLog.lifecycle_events(ctx.db), &(&1.kind == "model_adjudication")) == 1
  end

  test "F3: a swap cannot project when no resident harness was contacted", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    seed_swap_catalog(ctx)
    Org.append_pointer(ctx.db, "k1", "harness-sid-1", "created")
    run_failing_turn(ctx, "fault")
    stop_supervised!(CoordinatorStub)
    episode = episode(ctx.db)

    result =
      Gateway.handlers(ctx.config)["adjudicate"].(%{
        origin: "user:flynn",
        principal: {:session, episode.owner_target},
        params: %{
          episode: episode.correlation_key,
          action: "swap",
          model: "claude-sonnet-4-6"
        }
      })

    assert %{code: "adapter_unavailable"} = result
    assert Org.get(ctx.db, "k1").model == Model.new("claude-fable-5")
    refute Enum.any?(EventLog.lifecycle_events(ctx.db), &(&1.kind == "model_adjudication"))
  end

  test "F3: concurrent swaps are handled and the winning prompt names the owner model", ctx do
    adapter = swap_harness(ctx, checkout: {:error, :degraded})
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    swap_ready(adapter, nil)
    parent = self()

    proxy =
      start_supervised!(
        {RaceDB,
         real: ctx.db,
         at: 2,
         before_txn: fn ->
           send(parent, :first_swap_reached_projection)

           receive do
             :release_first_swap -> :ok
           end
         end}
      )

    call = fn db, model ->
      try do
        Gateway.handlers(Map.put(ctx.config, :db, db))["adjudicate"].(%{
          origin: "user:flynn",
          principal: {:session, episode.owner_target},
          params: %{
            episode: episode.correlation_key,
            action: "swap",
            model: model
          }
        })
      rescue
        error -> {:raised, error}
      end
    end

    first = Task.async(fn -> call.(proxy, "claude-sonnet-4-6") end)
    assert_receive :first_swap_reached_projection

    second = Task.async(fn -> call.(ctx.db, "claude-opus-4-6") end)
    send(proxy, :release_first_swap)
    first_result = Task.await(first)
    second_result = Task.await(second)

    refute match?({:raised, _}, first_result)
    refute match?({:raised, _}, second_result)

    applied_model = SwapAdapterStub.held(adapter)
    assert Org.get(ctx.db, "k1").model == applied_model

    resolved = Adjudication.get(ctx.db, "k1", "other")
    prompt = Wakes.get(ctx.db, resolved.recovery_wake_id).prompt
    assert prompt =~ "You now run on #{Model.describe(applied_model)}"
  end

  test "F3: a concurrent tune cannot invalidate the model before its ruling commits", ctx do
    adapter = swap_harness(ctx, checkout: {:error, :degraded})
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    parent = self()

    swap_ready(adapter, nil)

    proxy =
      start_supervised!(
        {RaceDB,
         real: ctx.db,
         at: 2,
         before_txn: fn ->
           send(parent, {:swap_confirmed, self()})

           receive do
             :release_swap_commit -> :ok
           end
         end}
      )

    swap =
      Task.async(fn ->
        Gateway.handlers(Map.put(ctx.config, :db, proxy))["adjudicate"].(%{
          origin: "user:flynn",
          principal: {:session, episode.owner_target},
          params: %{
            episode: episode.correlation_key,
            action: "swap",
            model: "claude-sonnet-4-6"
          }
        })
      end)

    assert_receive {:swap_confirmed, db_proxy}

    tune =
      Task.async(fn ->
        Gateway.handlers(ctx.config)["tune"].(%{
          origin: "user:flynn",
          session_key: "k1",
          params: %{setting: "set_model", model: "claude-opus-4-6"}
        })
      end)

    try do
      refute_receive {:tune_model_applied, "claude-opus-4-6"}, 100
      assert SwapAdapterStub.held(adapter) == Model.new("claude-sonnet-4-6")
    after
      send(db_proxy, :release_swap_commit)
    end

    assert %{ok: true, action: "swap", model: "claude-sonnet-4-6"} = Task.await(swap)
    assert %{ok: true} = Task.await(tune)

    resolved = Adjudication.get(ctx.db, "k1", "other")

    assert Wakes.get(ctx.db, resolved.recovery_wake_id).prompt =~
             "You now run on claude-sonnet-4-6"

    assert SwapAdapterStub.held(adapter) == Model.new("claude-opus-4-6")
    assert Org.get(ctx.db, "k1").model == Model.new("claude-opus-4-6")
  end

  test "before-turn push waits for tune commit and reads the new canonical model", ctx do
    adapter = swap_harness(ctx, checkout: {:error, :degraded})
    swap_ready(adapter, nil)
    parent = self()

    proxy =
      start_supervised!(
        {RaceDB,
         real: ctx.db,
         at: 1,
         before_txn: fn ->
           send(parent, {:tune_waiting_to_commit, self()})

           receive do
             :release_tune_commit -> :ok
           end
         end}
      )

    tune =
      Task.async(fn ->
        Gateway.handlers(Map.put(ctx.config, :db, proxy))["tune"].(%{
          origin: "user:flynn",
          session_key: "k1",
          params: %{setting: "set_model", model: "claude-sonnet-4-6"}
        })
      end)

    assert_receive {:tune_model_applied, %Model{family: "claude-sonnet-4-6"}}
    assert_receive {:tune_waiting_to_commit, db_proxy}

    turn_db =
      start_supervised!(
        {ModelReadBarrierDB, real: ctx.db, parent: self()},
        id: :model_read_barrier_db
      )

    turn_ctx = put_in(ctx.config.db, turn_db)
    turn = Task.async(fn -> run_residency_pass(turn_ctx) end)

    assert_receive {:turn_has_read_model, turn_proxy, "claude-fable-5"}

    try do
      send(db_proxy, :release_tune_commit)
      assert %{ok: true} = Task.await(tune)
      assert Org.get(ctx.db, "k1").model == Model.new("claude-sonnet-4-6")
    after
      send(turn_proxy, :release_turn)
    end

    assert :ok = Task.await(turn)
    assert Org.get(ctx.db, "k1").model == Model.new("claude-sonnet-4-6")
    assert SwapAdapterStub.held(adapter) == Model.new("claude-sonnet-4-6")
  end

  test "resident before-turn refusal has the same model-decision cause as reattach", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        apply_error: :model_unavailable
      )

    swap_ready(adapter, nil)
    {_seq, reason} = run_failing_turn(ctx, "refuse the canonical model")

    assert reason == {:model_apply_failed, :model_unavailable}
    assert episode(ctx.db).cause == "model_decision"
  end

  test "F3: a non-replying adapter apply never occupies the DB owner", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        block_apply: true
      )

    swap_ready(adapter, nil)

    tune =
      Task.async(fn ->
        Gateway.handlers(ctx.config)["tune"].(%{
          origin: "user:flynn",
          session_key: "k1",
          params: %{setting: "set_model", model: "claude-opus-4-6"}
        })
      end)

    assert_receive {:tune_apply_waiting, ^adapter}

    db_read =
      Task.async(fn ->
        DB.query(ctx.db, "SELECT model FROM sessions WHERE sessionKey='k1'")
      end)

    try do
      assert {:ok, {:ok, [["claude-fable-5"]]}} = Task.yield(db_read, 2_000)
    after
      send(adapter, :release_tune_apply)
    end

    assert %{ok: true} = Task.await(tune)
    assert Org.get(ctx.db, "k1").model == Model.new("claude-opus-4-6")
  end

  test "F3: the DB owner finishes projection and ruling after the wire caller dies", ctx do
    adapter = swap_harness(ctx, checkout: {:error, :degraded})
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    parent = self()

    swap_ready(adapter, fn ->
      send(parent, :harness_applied)

      receive do
        :release_harness_apply -> :ok
      end
    end)

    {caller, monitor} =
      spawn_monitor(fn ->
        Gateway.handlers(ctx.config)["adjudicate"].(%{
          origin: "user:flynn",
          principal: {:session, episode.owner_target},
          params: %{
            episode: episode.correlation_key,
            action: "swap",
            model: "claude-sonnet-4-6"
          }
        })
      end)

    assert_receive :harness_applied
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    send(adapter, :release_harness_apply)

    assert eventually(fn ->
             Org.get(ctx.db, "k1").model == Model.new("claude-sonnet-4-6") and
               episode(ctx.db).status == "resolved"
           end)

    resolved = episode(ctx.db)
    assert SwapAdapterStub.held(adapter) == Org.get(ctx.db, "k1").model

    assert Wakes.get(ctx.db, resolved.recovery_wake_id).prompt =~
             "You now run on claude-sonnet-4-6"
  end

  test "F3: a failed projection reasserts the canonical record on the next residency pass",
       ctx do
    adapter = swap_harness(ctx, checkout: {:error, :degraded})
    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    swap_ready(adapter, nil)

    :ok =
      DB.execute(
        ctx.db,
        """
        CREATE TRIGGER fail_model_projection
        BEFORE UPDATE OF model ON sessions
        WHEN NEW.model = 'claude-sonnet-4-6'
        BEGIN
          SELECT RAISE(ABORT, 'staged projection failure');
        END
        """
      )

    assert_raise DB.Error, ~r/staged projection failure/, fn ->
      Gateway.handlers(ctx.config)["adjudicate"].(%{
        origin: "user:flynn",
        principal: {:session, episode.owner_target},
        params: %{
          episode: episode.correlation_key,
          action: "swap",
          model: "claude-sonnet-4-6"
        }
      })
    end

    assert SwapAdapterStub.held(adapter) == Model.new("claude-sonnet-4-6")
    assert Org.get(ctx.db, "k1").model == Model.new("claude-fable-5")
    assert SwapAdapterStub.apply_count(adapter) == 1

    :ok = DB.execute(ctx.db, "DROP TRIGGER fail_model_projection")

    run_residency_pass(ctx)
    assert Org.get(ctx.db, "k1").model == Model.new("claude-fable-5")
    assert Org.get(ctx.db, "k1").model == SwapAdapterStub.held(adapter)
    assert SwapAdapterStub.apply_count(adapter) == 1
    assert episode(ctx.db).status == "notified"
  end

  test "F3: an uncertain strict apply reasserts the record on the next residency pass", ctx do
    adapter =
      swap_harness(ctx,
        checkout: {:error, :degraded},
        strict_error: :partial_apply
      )

    run_failing_turn(ctx, "fault")
    episode = episode(ctx.db)
    swap_ready(adapter, nil)

    assert %{code: "partial_apply"} =
             Gateway.handlers(ctx.config)["adjudicate"].(%{
               origin: "user:flynn",
               principal: {:session, episode.owner_target},
               params: %{
                 episode: episode.correlation_key,
                 action: "swap",
                 model: "claude-sonnet-4-6"
               }
             })

    assert SwapAdapterStub.held(adapter) == Model.new("claude-sonnet-4-6")
    assert Org.get(ctx.db, "k1").model == Model.new("claude-fable-5")
    assert SwapAdapterStub.load_count(adapter) == 0

    run_residency_pass(ctx)

    assert SwapAdapterStub.load_count(adapter) == 1
    assert Org.get(ctx.db, "k1").model == Model.new("claude-fable-5")
    assert Org.get(ctx.db, "k1").model == SwapAdapterStub.held(adapter)
  end

  test "F4: a remembered death reason is served ONLY to the generation that died", ctx do
    sup =
      start_supervised!(
        {DynamicSupervisor,
         strategy: :one_for_one, name: :"f4_sup_#{:erlang.unique_integer([:positive])}"}
      )

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: sup,
         db: ctx.db,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _key, _context ->
           [harness: :claude, cmd: ["/nonexistent/adapter"], home: "/tmp", cwd: "/tmp"]
         end,
         name: :"f4_coord_#{:erlang.unique_integer([:positive])}"}
      )

    key = {:claude, "shared", "testhost"}
    assert {:ok, _pid, generation} = AdapterCoordinator.adapter_for(coordinator, key)

    assert eventually(fn ->
             AdapterCoordinator.last_failure(coordinator, key, generation) != nil
           end)

    # The generation that died gets its reason...
    assert AdapterCoordinator.last_failure(coordinator, key, generation)

    # ...and no other generation is ever labelled with it. Reporting a
    # predecessor's reason for a new death is worse than reporting none.
    refute AdapterCoordinator.last_failure(coordinator, key, generation + 1)
    refute AdapterCoordinator.last_failure(coordinator, key, generation + 5)
  end

  test "F7: adding hold rows never reorders existing decision requests", ctx do
    start_supervised!({CoordinatorStub, checkout: {:error, :degraded}})
    run_failing_turn(ctx, "fault")

    # Requests whose raisedAt does NOT track rowid — a clock rollback, or rows
    # migrated with timestamps that do not match insertion order. A global sort
    # over the union would permute these; the listing must not.
    for {id, raised_at} <- [{"dr_first", 9_000}, {"dr_second", 1_000}, {"dr_third", 5_000}] do
      :ok =
        DB.execute(ctx.db, """
        INSERT INTO decision_requests
          (id, kind, raiserId, ownerUserId, raisedAt, deadlineAt, statuteName,
           actionKey, question, options, context, status)
        VALUES ('#{id}', 'statute', 'user:flynn', 'flynn', #{raised_at}, 1,
                'st', '#{id}', 'q', '[]', '{}', 'open')
        """)
    end

    call = %{origin: "user:flynn", principal: {:user, "flynn"}, params: %{}}

    baseline =
      Escalation.list(ctx.db, call, "open", owner_user_id: "flynn")
      |> Enum.filter(&(&1.kind == "statute"))
      |> Enum.map(& &1.id)

    assert "hold:" <> _ =
             Escalation.list(ctx.db, call, "open", owner_user_id: "flynn")
             |> Enum.find(&(&1.kind == "adjudication_hold"))
             |> Map.fetch!(:id)

    with_holds =
      Escalation.list(ctx.db, call, "open", owner_user_id: "flynn")
      |> Enum.filter(&(&1.kind == "statute"))
      |> Enum.map(& &1.id)

    assert with_holds == baseline, "existing rows keep their exact relative order"
    assert baseline == ["dr_third", "dr_second", "dr_first"], "the shipped rowid DESC direction"
  end

  defp eventually(fun, tries \\ 60) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.(),
        do: {:halt, true},
        else:
          (
            Process.sleep(25)
            {:cont, false}
          )
    end)
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

  defp run_residency_pass(ctx) do
    message_id = "residency_#{System.unique_integer([:positive])}"

    assert {:ok, seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: "k1",
               message_id: message_id,
               origin: "process:tightbeam",
               prompt: "continue"
             })

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE turns SET status='running' WHERE seq=?1", [seq])

    assert {:ok, _} =
             turn_runner(ctx).(%{
               session_key: "k1",
               seq: seq,
               message_id: message_id,
               prompt: "continue",
               wake_id: nil
             })

    assert :ok = Ledger.finish(ctx.db, seq, "delivered")
  end

  defp heal(ctx, token), do: Gateway.adapter_healed(ctx.config, ctx.db, @cause, token)

  # The harness half of a model swap: a coordinator checkout that can be flipped
  # from faulted to serving, plus the catalog inventory and residency pointer the
  # swap path reads. Returns the adapter — the owner of the loaded model.
  defp swap_harness(ctx, opts) do
    start_supervised!(%{
      id: :swap_checkout,
      start:
        {Agent, :start_link, [fn -> Keyword.fetch!(opts, :checkout) end, [name: :swap_checkout]]}
    })

    start_supervised!({CoordinatorStub, checkout: fn -> Agent.get(:swap_checkout, & &1) end})

    adapter_opts =
      opts
      |> Keyword.take([
        :strict_error,
        :prompt_error,
        :model,
        :cached_model,
        :block_apply,
        :apply_error
      ])
      |> Keyword.put_new(:model, Model.new("claude-fable-5"))
      |> Keyword.put(:parent, self())

    adapter = start_supervised!({SwapAdapterStub, adapter_opts}, id: :swap_adapter)

    seed_swap_catalog(ctx, Keyword.get(opts, :efforts, []))
    Org.append_pointer(ctx.db, "k1", "harness-sid-1", "created")
    adapter
  end

  defp swap_ready(adapter, on_applied) do
    :ok = GenServer.call(adapter, {:on_applied, on_applied})
    Agent.update(:swap_checkout, fn _ -> {:ok, adapter, 1} end)
  end

  # `ModelCatalog.route/2` reads the OWNING host's inventory, so the catalog has to
  # know testhost at all — the setup's instance enumerates the real registry and
  # drops it.
  defp seed_swap_catalog(ctx, efforts \\ []) do
    stop_supervised!(ModelCatalog)

    start_supervised!(
      {ModelCatalog,
       base_dir: ctx.config.base_dir,
       db: ctx.db,
       hosts: fn ->
         %{"testhost" => %{ssh: nil, base_dir: ctx.config.base_dir, cli_bin: nil}}
       end,
       codex_home: Path.join(ctx.config.base_dir, "codex"),
       claude_fetch: fn _, _ -> {:error, :offline} end,
       codex_read: fn _ -> {:error, :offline} end}
    )

    # THE SAME FAMILY on the other harness, carried UNTIERED. An effort-less
    # ruling naming it is complete and uniquely routable — claude's tiered entry
    # cannot take a nil effort, codex's untiered one can — so nothing may refuse
    # it on the strength of claude's entry alone.
    untiered = [
      %{
        family: "shared-model",
        context: nil,
        display_name: "shared-model",
        name: "shared-model",
        efforts: [],
        max_input_tokens: 200_000,
        capabilities: %{},
        provider: :openai
      }
    ]

    entries =
      for ref <- ["claude-fable-5", "claude-sonnet-4-6", "claude-opus-4-6", "shared-model"] do
        %{
          family: ref,
          context: nil,
          display_name: ref,
          name: ref,
          efforts: efforts,
          max_input_tokens: 200_000,
          capabilities: %{},
          provider: :anthropic
        }
      end

    :sys.replace_state(ModelCatalog, fn state ->
      now = state.now.()

      fresh = fn rows ->
        %{entries: rows, derived_at: now, attempted_at: now, reason: nil, refreshing: false}
      end

      state
      |> put_in([:entries, {"testhost", "claude"}], fresh.(entries))
      |> put_in([:entries, {"testhost", "codex"}], fresh.(untiered))
    end)
  end

  defp make_model_unknown(db, session_key) do
    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")

    try do
      :ok =
        DB.execute(
          db,
          """
          CREATE TABLE sessions_with_unknown AS SELECT * FROM sessions;
          DROP TABLE sessions;
          ALTER TABLE sessions_with_unknown RENAME TO sessions;
          CREATE UNIQUE INDEX sessions_unknown_key ON sessions(sessionKey);
          UPDATE sessions SET model=NULL WHERE sessionKey='#{session_key}';
          """
        )
    after
      :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    end
  end

  # Collapse the retry backoff so the next scheduler fire delivers it; the app
  # env is global, so it is restored when the test exits.
  defp retry_immediately do
    Application.put_env(:tightbeam, :adjudication_probe_retry_ms, 0)
    on_exit(fn -> Application.delete_env(:tightbeam, :adjudication_probe_retry_ms) end)
  end

  defp retry_wakes(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT wakeId, sessionKey, dueAt, state FROM wakes WHERE consumer = ?1 ORDER BY createdAt, wakeId",
        [Adjudication.probe_retry_consumer()]
      )

    Enum.map(rows, fn [wake_id, session_key, due_at, state] ->
      %{wake_id: wake_id, session_key: session_key, due_at: due_at, state: state}
    end)
  end

  # A REAL scheduler wired exactly as the composition root wires it (the same
  # internal_consumers map) — the substrate's own time machinery, no external
  # stimulus. Prompt-wake delivery is stubbed out: this seam exercises the
  # internal retry consumer.
  defp retry_scheduler(ctx) do
    {Tightbeam.Wakes, wake_opts} =
      ctx.config
      |> Gateway.children()
      |> Enum.find(&match?({Tightbeam.Wakes, _}, &1))

    name = :"retry_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Wakes,
       db: ctx.db,
       deliver: fn _wake -> :ok end,
       internal_consumers: Keyword.fetch!(wake_opts, :internal_consumers),
       tick_ms: 3_600_000,
       name: name},
      id: name
    )
  end

  defp fire_due_retries(ctx), do: Wakes.fire_due(retry_scheduler(ctx))

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
