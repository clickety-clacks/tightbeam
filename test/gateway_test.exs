defmodule Tightbeam.GatewayTest do
  use Tightbeam.TestCase, async: false

  # How long a COLD runner Task is allowed to take to reach `Adapter.prompt`.
  #
  # One budget rather than three literals, because the three sites that wait on
  # this are the same race and they had drifted apart: after the measurement
  # below, one was raised to 15s and its two structurally identical siblings —
  # same `Task.async(fn -> runner.(...) end)`, same `{:prompt_started, adapter}`
  # — were left at 1s. A budget with no single home gets fixed one site at a
  # time, and the sites that were not in the failing sample keep the number that
  # was already shown to be wrong.
  #
  # MEASURED: at 1s this failed 2 of 5 samples on loaded macOS CI while the SAME
  # runner Task went on to complete (the Task.await below it passes), so the
  # message is sent and received, just later than 1s. #56 gave a bare `node`
  # handshake 1s for the same reason (fdb2a21); a full turn needs more.
  #
  # RE-MEASURED 2026-07-29 under a 5-lane load (load average ~93 on 16 cores),
  # which moved both the number and the explanation:
  #
  #   at 1_000:  4 of 4 runs failed here, and 5 of 5 at the mcp-servers wait
  #   at 15_000: 15498 / 17886 / 21518 ms observed — 2 of 3 samples OVER it
  #
  # The cost is not scheduler contention. A cold turn's identity work is a chain
  # of SEQUENTIAL git subprocess forks — three `rev-parse --verify` for the
  # required refs, one `rev-parse` for the live revision, one `ls-tree` for the
  # guidance set, then one `git show` per fragment, per manifest and per skill —
  # and on this box a single git fork measured 1.6-2.6s (10 samples) at that
  # load. Ten-odd forks is the entire budget. Fork latency scales with machine
  # load, so the headroom here is deliberate rather than fitted to the max.
  #
  # This is a BUDGET because there is no readiness contract to wait on: the
  # runner Task exposes no "started" signal a test can block against (#111). It
  # weakens nothing — assert_receive still fails if the message never arrives.
  @cold_runner_prompt_timeout 60_000

  import ExUnit.CaptureLog

  alias Tightbeam.{
    Adjudication,
    Archetypes,
    Artifacts,
    Assignments,
    ConnRegistry,
    ConditionFacts,
    Credentials,
    CriticalLeases,
    DB,
    Devices,
    EventLog,
    Escalation,
    EffortCheckin,
    Gateway,
    Identity,
    Idempotency,
    LaneManager,
    Ledger,
    ModelCatalog,
    Org,
    Placement,
    Projection,
    Rails,
    Roles,
    SessionLane,
    Wakes,
    WorkItems,
    WorkState
  }

  alias Tightbeam.Wire.Payloads

  defmodule LaneDoorbell do
    use GenServer
    def start_link({parent, name}), do: GenServer.start_link(__MODULE__, parent, name: name)
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, key}, _from, parent) do
      send(parent, {:ensure_lane, key})
      {:reply, :ok, parent}
    end

    # identity apply ensures a lane WITHOUT ringing the doorbell. This stub only
    # records it; tests that need a real lane start one themselves, so that the
    # boundary they exercise is a real mailbox rather than a stub's reply.
    def handle_call({:ensure_lane_quiet, key}, _from, parent) do
      send(parent, {:ensure_lane_quiet, key})
      {:reply, :ok, parent}
    end
  end

  defmodule CoordinatorStub do
    use GenServer

    def start_link({adapter, parent}),
      do: GenServer.start_link(__MODULE__, {adapter, parent}, name: Tightbeam.AdapterCoordinator)

    def start_link(adapter),
      do: GenServer.start_link(__MODULE__, {adapter, nil}, name: Tightbeam.AdapterCoordinator)

    def init({adapter, parent}), do: {:ok, {adapter, parent}}

    def handle_call({:adapter_for, key}, _from, {adapter, parent} = state) do
      if is_pid(parent), do: send(parent, {:adapter_key, key})
      reply = if is_function(adapter, 1), do: adapter.(key), else: {:ok, adapter, 1}
      {:reply, reply, state}
    end

    def handle_call({:adapter_for, key, _context}, from, state),
      do: handle_call({:adapter_for, key}, from, state)

    def handle_call({:acquire_load_slot, _machine, _borrower}, _from, state),
      do: {:reply, make_ref(), state}

    def handle_call({:close_adapter, key}, _from, {adapter, parent} = state) do
      if is_pid(parent), do: send(parent, {:close_adapter, key})
      GenServer.stop(adapter)
      {:reply, :ok, state}
    end

    def handle_call(:harness_processes, _from, {_adapter, parent} = state) do
      if is_pid(parent), do: send(parent, :harness_processes)
      {:reply, [%{launch_id: "launch-1", state: "unconfirmed"}], state}
    end

    def handle_call({:retry_harness_park, launch_id}, _from, {_adapter, parent} = state) do
      if is_pid(parent), do: send(parent, {:retry_harness_park, launch_id})
      {:reply, :ok, state}
    end

    def handle_call(
          {:release_harness_park, launch_id, reason},
          _from,
          {_adapter, parent} = state
        ) do
      if is_pid(parent), do: send(parent, {:release_harness_park, launch_id, reason})
      {:reply, :ok, state}
    end

    def handle_cast({:release_load_slot, _machine, _slot}, state), do: {:noreply, state}

    def handle_cast({:close_adapter, key}, {adapter, parent} = state) do
      if is_pid(parent), do: send(parent, {:close_adapter, key})
      GenServer.stop(adapter)
      {:noreply, state}
    end
  end

  defmodule AdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:new_session, _model, _cwd, mcp_servers, _guidance}, _from, parent) do
      send(parent, {:new_session_mcp_servers, mcp_servers})
      {:reply, {:ok, "harness-1"}, parent}
    end

    def handle_call(:conn, _from, parent), do: {:reply, parent, parent}

    def handle_call({:knows_session?, _sid}, _from, parent), do: {:reply, false, parent}

    def handle_call({:load_session, _sid, _model, _cwd, _mcp_servers, _guidance}, _from, parent),
      do: {:reply, {:error, %{"code" => -32602, "message" => "Invalid params"}}, parent}

    def handle_call({:close_session, sid}, _from, parent) do
      send(parent, {:close_session, sid})
      {:reply, :ok, parent}
    end

    def handle_call({:prompt, _sid, "fail this turn", _opts}, _from, parent),
      do:
        {:reply,
         {:error, %{"message" => "Internal error", "data" => %{"details" => "auth expired"}}},
         parent}

    def handle_call({:prompt, _sid, prompt, _opts}, from, parent) do
      send(parent, {:prompt_started, self()})

      receive do: (:continue_prompt ->
                     GenServer.reply(
                       from,
                       {:ok, %{text: String.upcase(prompt), stop_reason: "end_turn"}}
                     ))

      {:noreply, parent}
    end
  end

  defmodule CloseErrorAdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:close_session, sid}, _from, parent) do
      send(parent, {:close_session_failed, sid})
      {:reply, {:error, :closed}, parent}
    end
  end

  defmodule RejectingCredentialSupervisor do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, nil)
    def init(nil), do: {:ok, nil}

    def handle_call({:start_child, _child}, _from, state),
      do: {:reply, {:error, :deliberate_start_failure}, state}
  end

  defmodule TuneAdapterStub do
    use GenServer

    def start_link({parent, opts}), do: GenServer.start_link(__MODULE__, {parent, opts})
    def init(state), do: {:ok, state}

    def handle_call({:knows_session?, sid}, _from, {parent, opts} = state) do
      send(parent, {:tune_residency_checked, sid})
      {:reply, Keyword.get(opts, :resident, true), state}
    end

    def handle_call(
          {:apply_model, sid, model},
          _from,
          {parent, opts} = state
        ) do
      send(parent, {:tune_model_applied, sid, model})
      {:reply, Keyword.get(opts, :apply_result, :ok), state}
    end
  end

  defmodule SlowConnAdapterStub do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call(:conn, from, parent) do
      send(parent, {:cancel_conn_waiting, self()})

      receive do
        :release_cancel_conn -> GenServer.reply(from, parent)
      end

      {:noreply, parent}
    end
  end

  defmodule IdentityApplyAdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    # A RESIDENT session: the adapter still holds it, so apply bounces it.
    def handle_call({:knows_session?, _sid}, _from, parent), do: {:reply, true, parent}

    def handle_call({:close_session, sid}, _from, parent) do
      send(parent, {:identity_apply_close, sid})
      {:reply, :ok, parent}
    end

    def handle_call(
          {:load_session, sid, model, cwd, mcp_servers, guidance},
          _from,
          parent
        ) do
      send(parent, {:identity_apply_load, sid, model, cwd, mcp_servers, guidance})
      {:reply, {:ok, model}, parent}
    end
  end

  # Holds the bounce OPEN, so the apply-vs-claim window is real elapsed time
  # rather than a scheduling accident the test hopes for: close_session parks
  # until the test releases it.
  defmodule HoldingAdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:knows_session?, _sid}, _from, parent), do: {:reply, true, parent}

    def handle_call({:close_session, sid}, _from, parent) do
      send(parent, {:holding_close, sid})

      receive do
        :release -> :ok
      end

      {:reply, :ok, parent}
    end

    def handle_call({:load_session, sid, model, _cwd, _mcp, _guidance}, _from, parent) do
      send(parent, {:holding_load, sid})
      {:reply, {:ok, model}, parent}
    end
  end

  # The state EVERY started session is in after a gateway restart: its pointer row
  # survives in the DB, the adapter process is new and holds nothing.
  defmodule GoneSessionAdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:knows_session?, sid}, _from, parent) do
      send(parent, {:gone_residency_asked, sid})
      {:reply, false, parent}
    end

    # Answering these at all is the point: the harness never heard of this
    # session, so asking it to close one is what produced the raw -32603.
    def handle_call({:close_session, sid}, _from, parent) do
      send(parent, {:gone_close_attempted, sid})
      {:reply, {:error, %{"code" => -32603, "message" => "Session not found"}}, parent}
    end

    def handle_call({:load_session, sid, model, _cwd, _mcp, _guidance}, _from, parent) do
      send(parent, {:gone_load_attempted, sid})
      {:reply, {:ok, model}, parent}
    end
  end

  # One adapter, three sessions, one truthful answer each — the org-wide shape
  # `--all` actually meets.
  defmodule MixedResidencyAdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:knows_session?, sid}, _from, parent),
      do: {:reply, sid == "thread-resident", parent}

    def handle_call({:close_session, sid}, _from, parent) do
      send(parent, {:mixed_close, sid})
      {:reply, :ok, parent}
    end

    def handle_call({:load_session, sid, model, _cwd, _mcp, _guidance}, _from, parent) do
      send(parent, {:mixed_load, sid})
      {:reply, {:ok, model}, parent}
    end
  end

  # A LIVE adapter that holds the session and fails for its own reason — which
  # must still refuse, and must not be swallowed by the residency branch.
  defmodule ApplyErrorAdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:knows_session?, _sid}, _from, parent), do: {:reply, true, parent}

    def handle_call({:close_session, sid}, _from, parent) do
      send(parent, {:apply_error_close, sid})
      {:reply, {:error, %{"code" => -32000, "message" => "harness is shutting down"}}, parent}
    end
  end

  defmodule LoadWithoutOwnerReadAdapterStub do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:knows_session?, sid}, _from, parent) do
      send(parent, {:load_apply_residency, sid})
      {:reply, false, parent}
    end

    def handle_call({:load_session, sid, model, _cwd, _mcp, _guidance}, _from, parent) do
      send(parent, {:canonical_model_pushed_on_load, sid, model})
      {:reply, {:ok, model}, parent}
    end

    def handle_call({:new_session, _model, _cwd, _mcp, _guidance}, _from, parent) do
      send(parent, :unexpected_load_apply_new_session)
      {:reply, {:ok, "unexpected"}, parent}
    end

    def handle_call({:prompt, _sid, _prompt, _opts}, _from, parent) do
      send(parent, :load_without_owner_read_prompted)
      {:reply, {:ok, %{text: "continued", stop_reason: "end_turn"}}, parent}
    end
  end

  defmodule UnknownDefaultAdapterStub do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:new_session, model, _cwd, _mcp, _guidance}, _from, parent) do
      send(parent, {:unknown_new_session, model})
      {:reply, {:ok, "default-session"}, parent}
    end

    def handle_call({:knows_session?, _sid}, _from, parent), do: {:reply, false, parent}

    def handle_call({:load_session, sid, model, _cwd, _mcp, _guidance}, _from, parent) do
      send(parent, {:unknown_load_lost, sid, model})
      {:reply, {:error, :session_lost}, parent}
    end

    def handle_call({:current_model, "default-session"}, _from, parent) do
      send(parent, :default_model_captured)
      {:reply, {:ok, "harness-default"}, parent}
    end

    def handle_call({:prompt, "default-session", _prompt, _opts}, _from, parent) do
      send(parent, :default_session_prompted)
      {:reply, {:ok, %{text: "continued", stop_reason: "end_turn"}}, parent}
    end
  end

  setup do
    db = :"gateway_db_#{System.unique_integer([:positive])}"
    registry = :"gateway_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: Tightbeam.TurnTaskSupervisor})
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Placement.ensure_schema(db)
    start_supervised!({ConnRegistry, name: registry})
    # Named globally, like CoordinatorStub: identity apply reaches its lane manager
    # through `config[:lane_manager] || Tightbeam.LaneManager`, so the default has
    # to resolve to something for every test that applies to a started session.
    lane = start_supervised!({LaneDoorbell, {self(), Tightbeam.LaneManager}})
    # Production always has this (Application.children/0); the test env boots no
    # tree, and identity apply now looks a session's lane up by name.
    start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})

    catalog_base =
      Path.join(System.tmp_dir!(), "gateway-catalog-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([catalog_base, "auth", "claude"]))
    File.write!(Path.join([catalog_base, "auth", "claude", "oauth-token"]), "test-token")

    claude_models =
      JSON.encode!(%{
        data: [
          %{
            id: "claude-fable-5",
            display_name: "Claude Fable 5",
            max_input_tokens: 200_000,
            capabilities: %{effort: %{}}
          },
          %{
            id: "claude-sonnet-4-6",
            display_name: "Claude Sonnet 4.6",
            max_input_tokens: 200_000,
            capabilities: %{effort: %{}}
          }
        ]
      })

    start_supervised!({
      ModelCatalog,
      # This suite's subject is the gateway, not the claude selectable-model pin
      # (tested in model_catalog_test). Leaving the pin on would filter this
      # fixture to nothing and starve the catalog.
      # Every catalog probe that runs a script: codex on both localities, claude
      # on satellites. Tests that register a host get a catalog for it without an
      # ssh ever leaving this machine.
      base_dir: catalog_base,
      db: db,
      credential_status: fn _provider -> :onboarded end,
      credential_kind: fn _provider -> :subscription end,
      claude_selectable_models: :all,
      claude_fetch: fn _, _ -> {:ok, claude_models} end,
      sh: fn command ->
        case catalog_probe_harness(command) do
          :claude -> catalog_reply(claude_models)
          :codex -> catalog_reply(codex_models())
        end
      end
    })

    await_catalog("claude")
    await_catalog("codex")
    await_catalog("fixture")

    on_exit(fn ->
      File.rm_rf!(catalog_base)
    end)

    for module <- [
          Tightbeam.CausalEvents,
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
      model: "fable"
    })

    {:ok, _ref, nil} =
      ConnRegistry.register(registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "d1",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    %{db: db, registry: registry, lane: lane, catalog_base: catalog_base}
  end

  test "retire refuses built-in mains — the fallback target is permanent", ctx do
    Org.create(ctx.db, %{
      session_key: Org.personal_session_key("flynn"),
      display_name: "Main",
      kind: "main",
      is_built_in: true,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })

    handlers =
      Gateway.handlers(%{
        db: ctx.db,
        base_dir: System.tmp_dir!(),
        default_harness: :claude,
        default_model: "claude-fable-5",
        max_live_sessions_per_user: 5
      })

    assert %{code: "denied", message: message} =
             handlers["retire"].(%{
               origin: "user:flynn",
               session_key: Org.personal_session_key("flynn"),
               params: %{}
             })

    assert message =~ "permanent"
    assert Org.get(ctx.db, Org.personal_session_key("flynn")).state == "active"
  end

  test "admin operator handlers list, retry, and release durable harness launches", ctx do
    adapter = start_supervised!({AdapterStub, self()})
    coordinator = start_supervised!({CoordinatorStub, {adapter, self()}})
    handlers = Gateway.handlers(%{db: ctx.db, adapter_coordinator: coordinator})
    call = %{origin: "user:flynn", session_key: nil, params: %{}}

    assert %{harness_processes: [%{launch_id: "launch-1", state: "unconfirmed"}]} =
             handlers["harness-processes"].(call)

    assert_receive :harness_processes

    assert %{retried: "launch-1"} =
             handlers["harness-process-retry"].(%{
               call
               | params: %{launch_id: "launch-1"}
             })

    assert_receive {:retry_harness_park, "launch-1"}

    assert %{released: "launch-1"} =
             handlers["harness-process-release"].(%{
               call
               | params: %{launch_id: "launch-1", reason: "verified absent"}
             })

    assert_receive {:release_harness_park, "launch-1", "verified absent"}
  end

  test "retire atomically cascades parent-last, interrupts assignments, and removes every wire",
       ctx do
    case ConnRegistry.start_link(name: Tightbeam.ConnRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    {:ok, _ref, nil} =
      ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "cascade-device",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    root = create_session(ctx.db, "cascade-root", "flynn")
    child = create_session(ctx.db, "cascade-child", "flynn", root.session_key)
    grandchild = create_session(ctx.db, "cascade-grandchild", "flynn", child.session_key)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) VALUES ('asg_retire', 'work', ?1, 'flynn', 1)",
        [child.session_key]
      )

    parent = self()

    handlers =
      Gateway.handlers(%{
        db: ctx.db,
        on_retired: fn key -> send(parent, {:retired, key}) end
      })

    result =
      handlers["retire"].(%{
        origin: "user:flynn",
        session_key: root.session_key,
        params: %{}
      })

    assert result.retired_session_keys == [
             grandchild.session_key,
             child.session_key,
             root.session_key
           ]

    assert result.deferred == []
    assert_receive {:retired, "cascade-grandchild"}
    assert_receive {:retired, "cascade-child"}
    assert_receive {:retired, "cascade-root"}

    for key <- result.retired_session_keys do
      assert Org.get(ctx.db, key).state == "retired"
      expected = Payloads.stream_deleted(key)
      assert_receive {:push, ^expected}
    end

    assert {:ok, [["closed", "revoked"]]} =
             DB.query(ctx.db, "SELECT state, outcome FROM assignments WHERE id='asg_retire'")

    assert {:ok, [["cascade-child", "interrupted-by-retire"]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey, reason FROM assignment_interruptions WHERE assignmentId='asg_retire'"
             )
  end

  test "retiring the last live session closes its harness session and shared adapter", ctx do
    ensure_global_registry()
    Org.retire(ctx.db, "k1")
    session = create_session(ctx.db, "reap-last", "flynn")
    session = Org.set_identity(ctx.db, session.session_key, nil, "reap-last-identity")
    Org.append_pointer(ctx.db, session.session_key, "harness-last", "created")

    adapter =
      start_supervised!(%{
        id: {:reap_adapter, System.unique_integer([:positive])},
        start: {AdapterStub, :start_link, [self()]},
        restart: :temporary
      })

    coordinator = start_supervised!({CoordinatorStub, {adapter, self()}})
    monitor = Process.monitor(adapter)

    result =
      Gateway.handlers(%{db: ctx.db, adapter_coordinator: coordinator})["retire"].(%{
        origin: "user:flynn",
        session_key: session.session_key,
        params: %{}
      })

    assert result.retired_session_keys == [session.session_key]
    assert_receive {:close_session, "harness-last"}
    assert_receive {:close_adapter, {:claude, "shared", "testhost"}}
    assert_receive {:DOWN, ^monitor, :process, ^adapter, :normal}
  end

  test "reap archives a local workspace with artifacts before adapter teardown", ctx do
    ensure_global_registry()

    base_dir =
      Path.join(System.tmp_dir!(), "gateway_artifacts_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base_dir) end)

    session = create_session(ctx.db, "artifact:writer", "flynn")
    local_host = Placement.local_host_name()

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET host = ?2 WHERE sessionKey = ?1", [
        session.session_key,
        local_host
      ])

    session = Org.get(ctx.db, session.session_key)
    workspace = Placement.workdir_path(%{base_dir: base_dir, db: ctx.db}, session)
    artifact_path = Path.join(workspace, "specs/banana.md")
    File.mkdir_p!(Path.dirname(artifact_path))
    File.write!(artifact_path, "banana")

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO work_items
          (id, title, ownerUserId, createdByUser, createdAt)
        VALUES ('wi_banana', 'Banana', 'flynn', 'flynn', 1)
        """
      )

    for message_id <- ~w(msg_banana_artifact msg_external_artifact) do
      {:ok, _} =
        DB.query(
          ctx.db,
          """
          INSERT INTO messages
            (id, sessionKey, role, content, timestamp, llmVisibleMessageId)
          VALUES (?1, ?2, 'assistant', 'artifact-record', 1, ?1)
          """,
          [message_id, session.session_key]
        )
    end

    artifact =
      Artifacts.record(ctx.db, %{
        principal: {:session, session.session_key},
        session_key: session.session_key,
        recorded_message_id: "msg_banana_artifact",
        params: %{
          kind: "spec",
          title: "Banana spec",
          origin_path: artifact_path,
          work_item_id: "wi_banana"
        }
      })

    external =
      Artifacts.record(ctx.db, %{
        principal: {:session, session.session_key},
        session_key: session.session_key,
        recorded_message_id: "msg_external_artifact",
        params: %{
          kind: "report",
          title: "External report",
          origin_path: "/outside/report.md",
          work_item_id: "wi_banana"
        }
      })

    result =
      Gateway.handlers(%{db: ctx.db, base_dir: base_dir})["retire"].(%{
        origin: "user:flynn",
        session_key: session.session_key,
        params: %{}
      })

    assert result.retired_session_keys == [session.session_key]
    refute File.exists?(workspace)

    [archive_dir] = Path.wildcard(Path.join(base_dir, "archive/artifact_writer-*"))
    archived = Artifacts.get(ctx.db, artifact.artifact_id)
    assert archived.state == "archived"
    assert archived.home == Path.join(archive_dir, "specs/banana.md")
    assert File.read!(archived.home) == "banana"

    unchanged_external = Artifacts.get(ctx.db, external.artifact_id)
    assert unchanged_external.state == "in-workspace"
    assert unchanged_external.home == nil
  end

  test "retiring with a live adapter sibling leaves the adapter up and records residency", ctx do
    ensure_global_registry()
    retired = create_session(ctx.db, "reap-sibling-retired", "flynn")
    retired = Org.set_identity(ctx.db, retired.session_key, nil, "reap-sibling-identity")
    sibling = create_session(ctx.db, "reap-sibling-live", "flynn")
    _sibling = Org.set_identity(ctx.db, sibling.session_key, nil, "reap-sibling-identity")
    Org.append_pointer(ctx.db, retired.session_key, "harness-retired", "created")

    adapter =
      start_supervised!(%{
        id: {:reap_adapter, System.unique_integer([:positive])},
        start: {AdapterStub, :start_link, [self()]},
        restart: :temporary
      })

    coordinator = start_supervised!({CoordinatorStub, {adapter, self()}})

    result =
      Gateway.handlers(%{db: ctx.db, adapter_coordinator: coordinator})["retire"].(%{
        origin: "user:flynn",
        session_key: retired.session_key,
        params: %{}
      })

    assert result.retired_session_keys == [retired.session_key]
    assert_receive {:close_session, "harness-retired"}
    refute_receive {:close_adapter, _key}
    assert Process.alive?(adapter)

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "harness_context_resident" and
               event.subject == retired.session_key and
               event.detail == "harness context resident until adapter recycle"
           end)
  end

  test "a harness session close error cannot fail the committed retire", ctx do
    ensure_global_registry()
    Org.retire(ctx.db, "k1")
    session = create_session(ctx.db, "reap-close-error", "flynn")
    session = Org.set_identity(ctx.db, session.session_key, nil, "reap-error-identity")
    Org.append_pointer(ctx.db, session.session_key, "harness-close-error", "created")

    adapter =
      start_supervised!(%{
        id: {:reap_error_adapter, System.unique_integer([:positive])},
        start: {CloseErrorAdapterStub, :start_link, [self()]},
        restart: :temporary
      })

    coordinator = start_supervised!({CoordinatorStub, {adapter, self()}})

    result =
      Gateway.handlers(%{db: ctx.db, adapter_coordinator: coordinator})["retire"].(%{
        origin: "user:flynn",
        session_key: session.session_key,
        params: %{}
      })

    assert result.retired_session_keys == [session.session_key]
    assert Org.get(ctx.db, session.session_key).state == "retired"
    assert_receive {:close_session_failed, "harness-close-error"}
    assert_receive {:close_adapter, {:claude, "shared", "testhost"}}
  end

  test "critical lease renewal is hard-capped and defers the entire cascade idempotently", ctx do
    root = create_session(ctx.db, "leased-root", "flynn")
    child = create_session(ctx.db, "leased-child", "flynn", root.session_key)
    handlers = Gateway.handlers(%{db: ctx.db, critical_lease_hard_cap_ms: 2_000})

    first =
      handlers["critical"].(%{
        principal: {:session, child.session_key},
        params: %{for_ms: 1_500, reason: "main commit"}
      })

    renewed =
      handlers["critical"].(%{
        principal: {:session, child.session_key},
        params: %{for_ms: 1_500, reason: "finish commit"}
      })

    assert renewed.hard_deadline == first.hard_deadline
    assert renewed.expires_at == first.hard_deadline

    call = %{origin: "user:flynn", session_key: root.session_key, params: %{}}
    deferred = handlers["retire"].(call)

    assert deferred.retired_session_keys == []
    assert Enum.map(deferred.deferred, & &1.session_key) == [child.session_key, root.session_key]
    assert Org.get(ctx.db, root.session_key).state == "active"
    assert Org.get(ctx.db, child.session_key).state == "active"
    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.session_key == child.session_key
    assert wake.due_at == first.hard_deadline
    assert wake.prompt =~ "FINAL RETIRE INSTRUCTION"

    again = handlers["retire"].(call)
    assert again.deferred == deferred.deferred
    assert [same_wake] = Wakes.list_pending(ctx.db)
    assert same_wake.wake_id == wake.wake_id
  end

  test "children preserves the cli token while refreshing the gateway port", ctx do
    base_dir = Path.join(System.tmp_dir!(), "gateway_token_#{System.unique_integer([:positive])}")
    config = gateway_config(base_dir, ctx.db, 4_321)

    Gateway.children(config)
    first = base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    Gateway.children(%{config | port: 5_432})
    second = base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    assert first["cliToken"] == second["cliToken"]
    assert second["port"] == 5_432
    assert File.stat!(Path.join(base_dir, "gateway.json")).mode |> Bitwise.band(0o777) == 0o600
  end

  # Hosts assimilated before the endpoint file existed, and hosts whose org token
  # has since been rotated, must not need a second ceremony: boot re-provisions
  # every registered satellite, so the operator shell heals on restart.
  test "children re-provisions the endpoint of an already-registered satellite", ctx do
    base_dir =
      Path.join(System.tmp_dir!(), "gateway_endpoint_boot_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)

    register_hosts(ctx.db, %{
      "already-assimilated" => %{
        ssh: "clu@already-assimilated",
        base_dir: "/remote/tb",
        cli_bin: nil
      }
    })

    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:11373")
    on_exit(fn -> Application.delete_env(:tightbeam, :advertised_url) end)
    parent = self()

    sh = fn command ->
      if hd(command) == "rsync", do: send(parent, {:staged, File.read!(Enum.at(command, -2))})
      {"", 0}
    end

    Gateway.children(gateway_config(base_dir, ctx.db, 11_373) |> Map.put(:sh, sh))

    token =
      base_dir
      |> Path.join("gateway.json")
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("cliToken")

    assert_receive {:staged, content}

    assert JSON.decode!(content) == %{
             "url" => "http://gateway.example:11373",
             "cliToken" => token,
             "machine" => "already-assimilated"
           }
  end

  test "Proof 5: the boot audit logs conflicts without mutating and terminates on a synthetic cycle",
       ctx do
    first_item = create_work_item(ctx.db, "Audit reviewed")
    second_item = create_work_item(ctx.db, "Audit conflict")

    :ok =
      DB.execute(
        ctx.db,
        """
        INSERT INTO assignments
          (id, subject, holderKey, openedByUser, openedAt, workItemId)
        VALUES
          ('asg_audit_target', 'target', 'k1', 'flynn', 1, '#{first_item.id}'),
          ('asg_audit_conflict', 'conflict', 'k1', 'flynn', 2, '#{second_item.id}');
        UPDATE assignments
        SET reviewsAssignmentId = 'asg_audit_target'
        WHERE id = 'asg_audit_conflict';

        INSERT INTO assignments
          (id, subject, holderKey, openedByUser, openedAt)
        VALUES
          ('asg_cycle_a', 'cycle a', 'k1', 'flynn', 3),
          ('asg_cycle_b', 'cycle b', 'k1', 'flynn', 4);
        UPDATE assignments SET reviewsAssignmentId = 'asg_cycle_b' WHERE id = 'asg_cycle_a';
        UPDATE assignments SET reviewsAssignmentId = 'asg_cycle_a' WHERE id = 'asg_cycle_b';
        """
      )

    {:ok, before_rows} =
      DB.query(
        ctx.db,
        """
        SELECT id, workItemId, reviewsAssignmentId
        FROM assignments
        WHERE id LIKE 'asg_audit_%' OR id LIKE 'asg_cycle_%'
        ORDER BY id
        """
      )

    base_dir = role_test_base("review-item-audit")

    log =
      capture_log(fn ->
        Gateway.children(gateway_config(base_dir, ctx.db, 0))
      end)

    assert log =~ "review_item_conflict legacy assignment=asg_audit_conflict"
    assert log =~ "workItemId=#{second_item.id}"
    assert log =~ "reviewedWorkItemId=#{inspect(first_item.id)}"

    assert {:ok, ^before_rows} =
             DB.query(
               ctx.db,
               """
               SELECT id, workItemId, reviewsAssignmentId
               FROM assignments
               WHERE id LIKE 'asg_audit_%' OR id LIKE 'asg_cycle_%'
               ORDER BY id
               """
             )
  end

  test "children mints a cli token when gateway.json is missing", ctx do
    base_dir =
      Path.join(System.tmp_dir!(), "gateway_missing_#{System.unique_integer([:positive])}")

    Gateway.children(gateway_config(base_dir, ctx.db, 0))

    assert %{"cliToken" => "tbc_" <> token} =
             base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    assert token != ""
  end

  test "fresh auth seeds Main while the model catalog is genuinely empty", ctx do
    base_dir = role_test_base("fresh-auth-empty-catalog")
    children = Gateway.children(gateway_config(base_dir, ctx.db, 0))

    {Bandit, bandit_opts} = List.last(children)
    {Tightbeam.Wire.Router, socket_deps} = Keyword.fetch!(bandit_opts, :plug)
    socket_deps = %{socket_deps | conn_registry: ctx.registry}

    empty_catalog(:not_derived)

    {:pending, pending} =
      Devices.pair(ctx.db, %{
        device_id: "fresh-empty",
        claimed_name: "Fresh Empty",
        platform: nil,
        model: nil
      })

    device = Devices.approve(ctx.db, pending.device_id)

    {:ok, socket} = Tightbeam.Wire.Socket.init(socket_deps)
    auth = %{"type" => "auth", "token" => device.token, "deviceId" => device.device_id}

    assert {:push, _frames, _state} =
             Tightbeam.Wire.Socket.handle_in({JSON.encode!(auth), opcode: :text}, socket)

    assert %{harness: "claude", provider: "anthropic", model: "claude-fable-5"} =
             Org.get(ctx.db, Org.personal_session_key(device.user_id))
  end

  # Task #41. A model the adapter cannot select must be refused by NAME and the
  # operator told what IS available — before, this died deep in the adapter as
  # "Invalid value for config option model", on every session/new and session/load.
  test "an unavailable model is refused by name and names what is offered", ctx do
    base_dir = role_test_base("model-not-offered")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)

    assert %{code: "model_unavailable", message: message} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_model", model: "claude-opus-5"}
             })

    assert message =~ ~s(model "claude-opus-5" is not offered by claude on host testhost)

    # The hint is the point: naming only the rejection makes the operator guess.
    assert message =~ "offered:"
    assert message =~ "claude-sonnet-4-6"

    # ...and it must not recommend the very thing it just refused.
    refute message =~ "offered: claude-opus-5"
  end

  test "a catalog missing for want of a GATEWAY credential says so, with the repair", ctx do
    base_dir = role_test_base("catalog-cred-legible")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)

    # Force the session host's OWN derivation to have failed for a missing
    # credential — the catalog belongs to the host that will run the turn.
    empty_catalog({:needs_onboarding, :no_credential})

    assert %{code: "catalog_unavailable", message: message} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_model", model: "claude-sonnet-4-6"}
             })

    # Names what is missing, on WHICH HOST, for which provider, and the repair —
    # and the host is the SESSION's, not the gateway's. Before per-host catalogs
    # this line sent the operator to the gateway to fix a satellite's grant.
    assert message =~ "anthropic has no usable credential on testhost"
    assert message =~ ":no_credential"
    assert message =~ "run tightbeam onboard anthropic on testhost"
    refute message =~ "GATEWAY host"

    # ...and never regresses to the bare inspected health term, which named
    # neither the provider, the host, nor the fix (sat-e2e mac-0726a S2).
    refute message =~ "for claude on host testhost: {:unavailable,"
  end

  test "children refuses a broken harness on PATH without creating any org artifact", ctx do
    base_dir =
      Path.join(System.tmp_dir!(), "gateway_no_harness_#{System.unique_integer([:positive])}")

    bin_dir =
      Path.join(System.tmp_dir!(), "gateway_broken_bin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)
    codex = Path.join(bin_dir, "codex")
    File.write!(codex, "#!/bin/sh\necho broken >&2\nexit 1\n")
    File.chmod!(codex, 0o755)
    previous_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir)
    File.rm_rf!(base_dir)

    on_exit(fn ->
      if previous_path,
        do: System.put_env("PATH", previous_path),
        else: System.delete_env("PATH")

      File.rm_rf!(base_dir)
      File.rm_rf!(bin_dir)
    end)

    exception =
      assert_raise RuntimeError, fn ->
        Gateway.children(gateway_config(base_dir, ctx.db, 0))
      end

    message = Exception.message(exception)

    assert message =~ "no usable harness CLI"
    assert message =~ "codex: exec failed"
    assert message =~ "Install a registered harness CLI"
    refute File.exists?(base_dir)
  end

  test "children backfills distinct tokens for active NULL rows only", ctx do
    second =
      Org.create(ctx.db, %{
        session_key: "backfill-active",
        display_name: "Active",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    retired =
      Org.create(ctx.db, %{
        session_key: "backfill-retired",
        display_name: "Retired",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })
      |> then(&Org.retire(ctx.db, &1.session_key))

    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET cliToken = NULL")

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "gateway_backfill_#{:os.getpid()}_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base_dir) end)

    Gateway.children(gateway_config(base_dir, ctx.db, 0))

    first_token = Org.get(ctx.db, "k1").cli_token
    second_token = Org.get(ctx.db, second.session_key).cli_token
    assert first_token =~ ~r/^tbs_/
    assert second_token =~ ~r/^tbs_/
    refute first_token == second_token
    assert Org.get(ctx.db, retired.session_key).cli_token == nil
  end

  test "session projections never expose cli tokens", ctx do
    session = Org.get(ctx.db, "k1")
    base_dir = role_test_base("projection-leak")
    Archetypes.load!(base_dir)

    inspect =
      Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["inspect"].(%{
        origin: "user:flynn",
        session_key: nil,
        params: %{}
      })

    assert [%{created_at: created_at}] = inspect.sessions
    assert created_at == session.created_at

    projections = [
      inspect,
      Payloads.stream_session(session),
      Gateway.session_status(session.session_key, ctx.db)
    ]

    Enum.each(projections, fn projection ->
      encoded = JSON.encode!(projection)
      refute encoded =~ "cliToken"
      refute encoded =~ "cli_token"
      refute encoded =~ session.cli_token
    end)
  end

  test "children sweeps newer credentials from abandoned identity homes before adapters", ctx do
    base_dir = Path.join(System.tmp_dir!(), "gateway_sweep_#{System.unique_integer([:positive])}")
    auth_dir = Path.join([base_dir, "auth", "codex"])
    abandoned = Path.join([base_dir, "homes", "default--abandoned", "codex"])
    File.mkdir_p!(auth_dir)
    File.mkdir_p!(abandoned)
    store = Path.join(auth_dir, "auth.json")
    rotated = Path.join(abandoned, "auth.json")
    File.write!(store, "stale")
    File.write!(rotated, "rotated")
    File.touch!(store, {{2026, 1, 1}, {0, 0, 0}})
    File.touch!(rotated, {{2026, 1, 2}, {0, 0, 0}})

    Gateway.children(gateway_config(base_dir, ctx.db, 0))

    assert File.read!(store) == "rotated"
  end

  test "children mints a cli token when gateway.json is corrupt", ctx do
    base_dir =
      Path.join(System.tmp_dir!(), "gateway_corrupt_#{System.unique_integer([:positive])}")

    File.rm_rf!(base_dir)
    File.mkdir_p!(base_dir)
    File.write!(Path.join(base_dir, "gateway.json"), "not json")

    Gateway.children(gateway_config(base_dir, ctx.db, 0))

    assert %{"cliToken" => "tbc_" <> token} =
             base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    assert token != ""
  end

  test "children installs the release Rust CLI, and refuses instead of falling back", ctx do
    repo_dir =
      Path.join(
        System.tmp_dir!(),
        "gateway_cli_install_#{System.unique_integer([:positive])}"
      )

    rust_cli = Path.join(repo_dir, "cli/target/release/tightbeam")
    rust_base = Path.join(repo_dir, "rust-base")
    fallback_base = Path.join(repo_dir, "fallback-base")
    File.mkdir_p!(Path.dirname(rust_cli))
    File.write!(rust_cli, "rust-cli-binary")

    on_exit(fn -> File.rm_rf!(repo_dir) end)

    File.cd!(repo_dir, fn ->
      Gateway.children(gateway_config(rust_base, ctx.db, 0))
      installed = Path.join(rust_base, "bin/tightbeam")
      assert File.read!(installed) == "rust-cli-binary"
      assert File.stat!(installed).mode |> Bitwise.band(0o777) == 0o755

      File.rm!(rust_cli)
      Gateway.children(gateway_config(fallback_base, ctx.db, 0))
      fallback = Path.join(fallback_base, "bin/tightbeam")
      body = File.read!(fallback)

      # This test's subject is unchanged — what gets installed at bin/tightbeam
      # when the Rust CLI is absent — but the answer is now the OPPOSITE of its old
      # name. There is deliberately no fallback: it pointed at the retired
      # TypeScript CLI in a sibling checkout, so on a machine that had one the
      # operator silently ran a different implementation than the gateway that
      # installed it, and on a machine without one an executable that died on a
      # path they never chose.
      refute body =~ "exec node"
      refute body =~ "dist/cli/main.js"

      assert body =~ "tightbeam CLI is not installed"
      assert body =~ "cargo build --release --manifest-path cli/Cargo.toml"
      assert body =~ rust_cli
      assert File.stat!(fallback).mode |> Bitwise.band(0o777) == 0o755

      # Executed, not merely matched: it must actually refuse.
      assert {refusal, 127} = System.cmd(fallback, ["list"], stderr_to_stdout: true)
      assert refusal =~ "tightbeam CLI is not installed"
      assert refusal =~ "cargo build --release"
    end)
  end

  test "children installs the codex hook-trust shim and preserves missing or self-resolved codex",
       ctx do
    root =
      Path.join(
        System.tmp_dir!(),
        "gateway_codex_shim_#{System.unique_integer([:positive])}"
      )

    real_bin = Path.join(root, "real-bin")
    real_codex = Path.join(real_bin, "codex")
    shim_base = Path.join(root, "shim-base")
    missing_bin = Path.join(root, "missing-bin")
    missing_base = Path.join(root, "missing-base")
    self_base = Path.join(root, "self-base")
    self_codex = Path.join(self_base, "bin/codex")
    original_path = System.get_env("PATH")
    git = System.find_executable("git")

    File.mkdir_p!(real_bin)
    File.write!(real_codex, "#!/bin/sh\n")
    File.chmod!(real_codex, 0o755)
    File.ln_s!(git, Path.join(real_bin, "git"))
    File.mkdir_p!(missing_bin)
    File.ln_s!(git, Path.join(missing_bin, "git"))
    File.mkdir_p!(Path.dirname(self_codex))
    File.write!(self_codex, "self-sentinel")
    File.chmod!(self_codex, 0o755)
    File.ln_s!(git, Path.join(Path.dirname(self_codex), "git"))

    for base <- [shim_base, missing_base, self_base], do: Identity.init!(base)

    on_exit(fn ->
      File.rm_rf!(root)

      if original_path do
        System.put_env("PATH", original_path)
      else
        System.delete_env("PATH")
      end
    end)

    System.put_env("PATH", real_bin)

    Gateway.children(gateway_config(shim_base, ctx.db, 0))

    shim = Path.join(shim_base, "bin/codex")

    assert File.read!(shim) ==
             "#!/bin/sh\nexec \"#{real_codex}\" --dangerously-bypass-hook-trust \"$@\"\n"

    assert File.stat!(shim).mode |> Bitwise.band(0o777) == 0o755

    System.put_env("PATH", missing_bin)

    assert_raise RuntimeError, ~r/no usable harness CLI/, fn ->
      Gateway.children(gateway_config(missing_base, ctx.db, 0))
    end

    refute File.exists?(Path.join(missing_base, "bin/codex"))

    System.put_env("PATH", Path.dirname(self_codex))

    assert_raise RuntimeError, ~r/no usable harness CLI/, fn ->
      Gateway.children(gateway_config(self_base, ctx.db, 0))
    end

    assert File.read!(self_codex) == "self-sentinel"
  end

  test "wake idempotency replays one scheduled wake", ctx do
    wake = Gateway.handlers(gateway_config("/tmp", ctx.db, 0))["wake"]
    due_at = System.system_time(:millisecond) + 60_000

    call = %{
      origin: "process:scheduler",
      session_key: "k1",
      params: %{prompt: "follow up", at: due_at, idempotency_key: "schedule-1"}
    }

    first = wake.(call)
    second = wake.(call)

    assert first.wake_id == second.wake_id
    assert first == second
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")
  end

  test "process inspect returns exactly its own pending wakes", ctx do
    own =
      Wakes.schedule(ctx.db, %{
        session_key: "k1",
        origin: "process:scheduler",
        prompt: "own wake",
        due_at: 2_000
      })

    Wakes.schedule(ctx.db, %{
      session_key: "k1",
      origin: "process:other",
      prompt: "other wake",
      due_at: 1_000
    })

    inspect_handler = Gateway.handlers(gateway_config("/tmp", ctx.db, 0))["inspect"]

    assert inspect_handler.(%{origin: "process:scheduler", params: %{}, session_key: nil}) == %{
             roles: [],
             wakes: [
               %{
                 wake_id: own.wake_id,
                 session_key: "k1",
                 due_at: 2_000,
                 prompt: "own wake"
               }
             ]
           }
  end

  test "process cancel-wake cancels only its own pending wakes", ctx do
    own =
      Wakes.schedule(ctx.db, %{
        session_key: "k1",
        origin: "process:scheduler",
        prompt: "own wake",
        due_at: 1_000
      })

    other =
      Wakes.schedule(ctx.db, %{
        session_key: "k1",
        origin: "process:other",
        prompt: "other wake",
        due_at: 2_000
      })

    wake = Gateway.handlers(gateway_config("/tmp", ctx.db, 0))["wake"]

    assert wake.(%{
             origin: "process:scheduler",
             session_key: nil,
             params: %{cancel_wake_id: own.wake_id}
           }) == %{canceled: true}

    assert wake.(%{
             origin: "process:scheduler",
             session_key: nil,
             params: %{cancel_wake_id: other.wake_id}
           }) == %{canceled: false}

    assert Wakes.get(ctx.db, own.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, other.wake_id).state == "pending"
  end

  test "role wakes late-bind at fire time and deleted roles fail visibly", ctx do
    base_dir = role_test_base("late-bind")
    config = gateway_config(base_dir, ctx.db, 0)
    children = Gateway.children(config)
    {Wakes, wake_opts} = Enum.find(children, &match?({Wakes, _}, &1))
    scheduler = :"role_wakes_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: :role_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    start_supervised!({Wakes, Keyword.put(wake_opts, :name, scheduler)})

    old = create_session(ctx.db, "agent:old", "flynn")
    new = create_session(ctx.db, "agent:new", "flynn")
    Roles.create!(ctx.db, "reviewer", "flynn", old.session_key)
    wake_handler = Gateway.handlers(Map.put(config, :wake_scheduler, scheduler))["wake"]
    future = System.system_time(:millisecond) + 60_000

    scheduled =
      wake_handler.(%{
        origin: "user:flynn",
        session_key: old.session_key,
        target_role: "reviewer",
        role_fallback: false,
        params: %{prompt: "review this", at: future}
      })

    assert Wakes.get(ctx.db, scheduled.wake_id).target_role == "reviewer"
    assert :ok = Roles.bind(ctx.db, "reviewer", new.session_key)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET dueAt = 0 WHERE wakeId = ?1", [scheduled.wake_id])

    assert :ok = Wakes.fire_due(scheduler)

    assert {:ok, [["agent:new", "reviewer", 0]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey, roleRef, roleFallback FROM turns WHERE wakeId = ?1",
               [scheduled.wake_id]
             )

    deleted =
      wake_handler.(%{
        origin: "user:flynn",
        session_key: new.session_key,
        target_role: "reviewer",
        role_fallback: false,
        params: %{prompt: "will disappear", at: future}
      })

    assert :ok = Roles.rm(ctx.db, "reviewer")
    {:ok, _} = DB.query(ctx.db, "UPDATE wakes SET dueAt = 0 WHERE wakeId = ?1", [deleted.wake_id])
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(ctx.db, deleted.wake_id).state == "fired"

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [deleted.wake_id])

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "wake_unresolved" and event.subject == deleted.wake_id and
               event.detail == "role reviewer no longer exists"
           end)
  end

  test "Gateway.children effort consumer routes a due dispatch bracket through Wakes once", ctx do
    base_dir = role_test_base("effort-wake-seam")

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:effort_checkin_horizon_ms, 1)
      # Injected at the SHELL: the real observation command is built, run and
      # parsed; only what a filesystem would have said is supplied.
      |> Map.put(:sh, fn _invocation -> {"B\tobserved\t0\n/w\n", 0} end)

    {Wakes, wake_opts} =
      config
      |> Gateway.children()
      |> Enum.find(&match?({Wakes, _}, &1))

    scheduler = :"effort_wakes_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: :effort_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    start_supervised!({Wakes, Keyword.put(wake_opts, :name, scheduler)})

    create_session(ctx.db, "effort-parent", "flynn")

    :ok =
      DB.execute(ctx.db, "UPDATE sessions SET spawnedBy='effort-parent' WHERE sessionKey='k1'")

    assignment =
      Gateway.handlers(config)["dispatch"].(%{
        verb: "dispatch",
        origin: "agent:effort-parent",
        principal: {:session, "effort-parent"},
        session_key: "k1",
        target_role: nil,
        role_fallback: false,
        params: %{subject: "scheduler seam", brief: "exercise the real effort wake route"}
      })

    {:ok, [[wake_id]]} =
      DB.query(
        ctx.db,
        "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
        [assignment.id]
      )

    assert %{consumer: "effort_probe", state: "pending"} = Wakes.get(ctx.db, wake_id)
    {:ok, _} = DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [wake_id])

    # Rung one prods the HOLDER and re-arms; the owner's request is rung two.
    assert :ok = Wakes.fire_due(scheduler)

    {:ok, [[rearmed_wake_id]]} =
      DB.query(
        ctx.db,
        "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
        [assignment.id]
      )

    {:ok, _} = DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [rearmed_wake_id])
    assert :ok = Wakes.fire_due(scheduler)

    assert {:ok, [[request_id]]} =
             DB.query(
               ctx.db,
               "SELECT id FROM decision_requests WHERE kind='effort' AND assignmentId=?1",
               [assignment.id]
             )

    assert is_binary(request_id)
    assert Wakes.get(ctx.db, wake_id).state == "fired"

    # The expecter notification is a durable ungated wake armed with the request,
    # still pending: the same tick that opened the request delivers nothing.
    assert {:ok, [[notify_id]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId FROM wakes WHERE targetGate = 0 AND state = 'pending'"
             )

    assert %{consumer: "prompt", session_key: expecter} = Wakes.get(ctx.db, notify_id)

    # The next ordinary tick delivers it through the gateway's own configured
    # prompt closure — real ConnRegistry, real lane nudge, one turn.
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(ctx.db, notify_id).state == "fired"

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [notify_id])

    assert_received {:ensure_lane, ^expecter}

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM decision_requests WHERE kind='effort' AND assignmentId=?1",
               [assignment.id]
             )
  end

  test "spawn --name creates a bound role and role_exists rolls back the session", ctx do
    base_dir = role_test_base("spawn")
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :spawn_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    spawn = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["spawn"]

    created =
      spawn.(%{
        origin: "user:flynn",
        session_key: nil,
        params: %{
          display_name: "Builder",
          handle: "builder",
          idempotency_key: "spawn-builder"
        }
      })

    assert %{name: "builder", bound_session_key: key, owner_user_id: "flynn"} =
             Roles.get(ctx.db, "builder")

    assert key == created.session_key
    assert Org.get(ctx.db, key).handle == "builder"
    assert Org.get(ctx.db, key).model == "claude-fable-5"

    Roles.create!(ctx.db, "taken", "flynn", nil)
    {:ok, [[before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM sessions")

    assert %{code: "config_denied", detail: %{code: "role_exists"}} =
             spawn.(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Must roll back",
                 handle: "taken",
                 idempotency_key: "spawn-taken"
               }
             })

    assert {:ok, [[^before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM sessions")
    assert Idempotency.get(ctx.db, "flynn", "spawn", "spawn-taken") == nil
  end

  test "registered fixture is selectable as the default spawn path and by tune", ctx do
    base_dir = role_test_base("fixture-default")
    auth_dir = Path.join([base_dir, "auth", "fixture"])
    adapter = Path.join([base_dir, "adapters", "node_modules", ".bin", "fixture-acp"])
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "fixture.json"), "fixture-token")
    File.mkdir_p!(Path.dirname(adapter))
    File.write!(adapter, "#!/bin/sh\n")
    File.chmod!(adapter, 0o755)
    Archetypes.load!(base_dir)

    ensure_global_registry()

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:default_harness, :fixture)
      |> Map.put(:default_model, "fixture-model")

    handlers = Gateway.handlers(config)

    assert %{session_key: spawned_key} =
             handlers["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Fixture default",
                 idempotency_key: "fixture-default"
               }
             })

    assert %{harness: "fixture", provider: "fixture_provider", model: "fixture-model"} =
             Org.get(ctx.db, spawned_key)

    assert %{ok: true, harness: "fixture", model: "fixture-model"} =
             handlers["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{
                 setting: "set_harness",
                 harness: "fixture",
                 model: "fixture-model"
               }
             })

    assert %{harness: "fixture", provider: "fixture_provider"} = Org.get(ctx.db, "k1")

    fixture_home = Tightbeam.Homes.home_path(base_dir, "testhost", :fixture)

    assert File.read_link!(Path.join(fixture_home, "fixture.json")) ==
             Path.join(auth_dir, "fixture.json")
  end

  test "a harness swap leaves a tombstone ABOVE its own barrier", ctx do
    base_dir = role_test_base("swap-tombstone")
    auth_dir = Path.join([base_dir, "auth", "fixture"])
    adapter = Path.join([base_dir, "adapters", "node_modules", ".bin", "fixture-acp"])
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "fixture.json"), "fixture-token")
    File.mkdir_p!(Path.dirname(adapter))
    File.write!(adapter, "#!/bin/sh\n")
    File.chmod!(adapter, 0o755)
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :swap_tombstone_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    handlers = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))

    Org.create(ctx.db, %{
      session_key: "swapme",
      display_name: "Swap me",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "before-model"
    })

    # Real prior conversation, so the barrier has something to bury.
    for body <- ["first", "second"] do
      Projection.append(ctx.db, %{
        session_key: "swapme",
        role: "user",
        sender: "user:flynn",
        content: body
      })
    end

    assert %{ok: true} =
             handlers["tune"].(%{
               origin: "user:flynn",
               session_key: "swapme",
               params: %{setting: "set_harness", harness: "fixture", model: "fixture-model"}
             })

    barrier = Org.get(ctx.db, "swapme").cleared_through_seq
    visible = Projection.list_after(ctx.db, "swapme", nil, 50, barrier)

    # THE PROPERTY, and the one worth proving rather than assuming: a tombstone
    # buried by the barrier it explains would be the joke version of this fix.
    assert [tombstone] = visible,
           "the swap must leave exactly the tombstone visible, got #{inspect(visible)}"

    assert tombstone.seq > barrier
    assert tombstone.sender == "process:tightbeam"

    # It names the change, both ends of it, and that nothing was deleted.
    assert tombstone.content =~ "[engine swap]"
    assert tombstone.content =~ "claude (before-model)"
    assert tombstone.content =~ "fixture (fixture-model)"
    assert tombstone.content =~ "RETAINED"
    assert tombstone.content =~ "not deleted"
    assert tombstone.content =~ "expected"

    # And the buried rows really are retained, not deleted — the marker's claim
    # has to be true, not merely reassuring.
    {:ok, [[total]]} =
      DB.query(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey = ?1", ["swapme"])

    assert total == 3, "the two earlier rows must still exist beneath the barrier"
  end

  test "a failure between the barrier and its tombstone rolls BOTH back", ctx do
    base_dir = role_test_base("swap-atomic")
    auth_dir = Path.join([base_dir, "auth", "fixture"])
    adapter = Path.join([base_dir, "adapters", "node_modules", ".bin", "fixture-acp"])
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "fixture.json"), "fixture-token")
    File.mkdir_p!(Path.dirname(adapter))
    File.write!(adapter, "#!/bin/sh\n")
    File.chmod!(adapter, 0o755)
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :swap_atomic_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    handlers = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))

    Org.create(ctx.db, %{
      session_key: "atomic",
      display_name: "Atomic",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "before-model"
    })

    for body <- ["first", "second"] do
      Projection.append(ctx.db, %{
        session_key: "atomic",
        role: "user",
        sender: "user:flynn",
        content: body
      })
    end

    before_barrier = Org.get(ctx.db, "atomic").cleared_through_seq

    # Fail INSIDE the transaction, after the barrier write and before the marker
    # append — the exact window this change closes. Same probe idiom as
    # `on_work_item_interlock`, which drives a concurrent disposition between an
    # assignment's two checks.
    result =
      handlers["tune"].(%{
        origin: "user:flynn",
        session_key: "atomic",
        on_swap_interlock: fn _txn -> raise "crash between the barrier and its marker" end,
        params: %{setting: "set_harness", harness: "fixture", model: "fixture-model"}
      })

    # The verb fails rather than reporting a swap that did not fully happen.
    refute match?(%{ok: true}, result)

    # THE PROPERTY: the barrier is UNMOVED, not moved-with-no-marker.
    assert Org.get(ctx.db, "atomic").cleared_through_seq == before_barrier,
           "the barrier moved without its tombstone — the crash window is still open"

    # And the conversation is still visible: nothing was buried by a swap that
    # never completed.
    visible = Projection.list_after(ctx.db, "atomic", nil, 50, before_barrier)
    assert Enum.map(visible, & &1.content) == ["first", "second"]
    refute Enum.any?(visible, &(&1.content =~ "[engine swap]"))
  end

  test "spawn admits only its matching reserved remedy principal", ctx do
    base_dir = role_test_base("remedy-spawn")
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :remedy_spawn_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    spawn = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["spawn"]

    created =
      spawn.(%{
        verb: "spawn",
        origin: "remedy:hire-reviewer",
        principal: {:remedy, %{statute: "hire-reviewer", action: "spawn", owner: "flynn"}},
        session_key: nil,
        params: %{
          display_name: "Remedy Reviewer",
          handle: "remedy-reviewer",
          idempotency_key: "rail-dispatch:hire-reviewer:subject:1"
        }
      })

    assert is_binary(created.session_key)
    assert Org.get(ctx.db, created.session_key).owner_user_id == "flynn"

    assert %{code: "unknown_caller"} =
             spawn.(%{
               verb: "spawn",
               origin: "remedy:wrong-action",
               principal: {:remedy, %{statute: "wrong-action", action: "wake", owner: "flynn"}},
               session_key: nil,
               params: %{
                 display_name: "Rejected",
                 idempotency_key: "rail-dispatch:wrong-action:subject:1"
               }
             })
  end

  test "config validates, persists, and controls only omitted spawn archetypes", ctx do
    base_dir = role_test_base("default-archetype")
    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)

    File.write!(Path.join(manifests, "coder.toml"), """
    name = "coder"
    """)

    Archetypes.load!(base_dir)

    case ConnRegistry.start_link(name: Tightbeam.ConnRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    handlers = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))
    config = handlers["config"]
    spawn = handlers["spawn"]

    assert %{setting: "default-archetype", value: "default"} =
             config.(%{
               origin: "user:flynn",
               params: %{action: "get", setting: "default-archetype"}
             })

    fallback =
      spawn.(%{
        origin: "user:flynn",
        session_key: nil,
        params: %{display_name: "Fallback", idempotency_key: "spawn-fallback"}
      })

    assert Org.get(ctx.db, fallback.session_key).archetype == "default"

    assert %{code: "unknown_archetype", message: "no such archetype: missing"} =
             config.(%{
               origin: "user:flynn",
               params: %{action: "set", setting: "default-archetype", value: "missing"}
             })

    assert Org.get_setting(ctx.db, "default-archetype") == nil

    assert %{setting: "default-archetype", value: "coder"} =
             config.(%{
               origin: "user:flynn",
               params: %{action: "set", setting: "default-archetype", value: "coder"}
             })

    assert Org.get_setting(ctx.db, "default-archetype") == "coder"

    configured =
      spawn.(%{
        origin: "user:flynn",
        session_key: nil,
        params: %{display_name: "Configured", idempotency_key: "spawn-configured"}
      })

    assert Org.get(ctx.db, configured.session_key).archetype == "coder"

    explicit =
      spawn.(%{
        origin: "user:flynn",
        session_key: nil,
        params: %{
          display_name: "Explicit",
          archetype: "default",
          idempotency_key: "spawn-explicit"
        }
      })

    assert Org.get(ctx.db, explicit.session_key).archetype == "default"

    assert %{code: "forbidden", message: "admin required"} =
             config.(%{
               origin: "user:not-admin",
               params: %{action: "set", setting: "default-archetype", value: "default"}
             })

    assert Org.get_setting(ctx.db, "default-archetype") == "coder"
  end

  test "spawn readiness denial creates no session, role, or idempotency row", ctx do
    base_dir = role_test_base("spawn-unready", false)
    Archetypes.load!(base_dir)
    spawn = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["spawn"]
    {:ok, [[before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM sessions")

    result =
      spawn.(%{
        origin: "user:flynn",
        session_key: nil,
        params: %{
          display_name: "Unready",
          handle: "unready",
          idempotency_key: "spawn-unready"
        }
      })

    assert %{code: "placement_denied", detail: %{code: "host_unready"}, message: message} = result
    assert message =~ "no claude credentials"
    assert {:ok, [[^before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM sessions")
    assert Roles.get(ctx.db, "unready") == nil
    assert Idempotency.get(ctx.db, "flynn", "spawn", "spawn-unready") == nil
  end

  test "spawn fails closed when a registered host has no credential server", ctx do
    machine = "credential-worker-missing"
    base_dir = move_test_base(ctx.db, "credential-server-missing", machine)

    {:ok, _entry} =
      Placement.register_host(ctx.db, machine, %{
        ssh: machine,
        base_dir: "/remote/tb"
      })

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.delete(:credential_status)

    assert GenServer.whereis(Credentials.server(machine)) == nil

    expected_message =
      "claude on #{machine} needs onboarding: :credential_server_unavailable; run tightbeam onboard anthropic on #{machine}"

    assert %{
             code: "placement_denied",
             detail: %{code: "needs_onboarding"},
             message: ^expected_message
           } =
             Gateway.handlers(config)["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "No credential owner",
                 host: machine,
                 idempotency_key: "spawn-no-credential-owner"
               }
             })
  end

  test "register-host supervises credentials and refuses spawn until onboarding", ctx do
    machine = "credential-worker-registration"
    base_dir = move_test_base(ctx.db, "credential-server-registration", machine)

    File.write!(
      Path.join(base_dir, "gateway.json"),
      JSON.encode!(%{port: 11_373, cliToken: "tbc_org"})
    )

    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:11373")
    on_exit(fn -> Application.delete_env(:tightbeam, :advertised_url) end)
    parent = self()

    # Registration provisions the satellite's operator endpoint through the same
    # runner; only the credential probe is being failed here.
    sh = fn
      ["ssh" | _] = command ->
        if "mkdir" in command, do: {"", 0}, else: credential_probe(parent, command)

      ["rsync" | _] ->
        {"", 0}

      command ->
        credential_probe(parent, command)
    end

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.delete(:credential_status)
      |> Map.put(:sh, sh)

    handlers = Gateway.handlers(config)
    child_id = {Credentials, machine}

    on_exit(fn ->
      Supervisor.terminate_child(Tightbeam.Supervisor, child_id)
      Supervisor.delete_child(Tightbeam.Supervisor, child_id)
    end)

    assert %{host: ^machine} =
             handlers["register-host"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 name: machine,
                 ssh: machine,
                 base_dir: "/remote/tb"
               }
             })

    server = Credentials.server(machine)
    first_pid = GenServer.whereis(server)
    assert is_pid(first_pid)
    assert Credentials.status(:anthropic, server) == {:needs_onboarding, :missing}
    assert_receive {:credential_command, first_command}
    assert Enum.join(first_command, " ") =~ "/remote/tb"

    :ok = :sys.suspend(first_pid)

    try do
      reregister =
        Task.async(fn ->
          handlers["register-host"].(%{
            origin: "user:flynn",
            session_key: nil,
            params: %{
              name: machine,
              ssh: machine,
              base_dir: "/remote/tb"
            }
          })
        end)

      # Two bounds, and the budget must sit between them. It must exceed a real
      # register-host round (DB write, host-registry read-modify-write, endpoint
      # staging) — measured in the hundreds of ms, but this box has taken 2s+ for
      # a single subprocess under load. And it must stay well under the 5s
      # GenServer.call default, because a re-registration that DID consult the
      # suspended server would block on exactly that call: a budget at or past 5s
      # would let the hang complete as a timeout and stop proving non-blocking.
      #
      # So the budget is pinned INSIDE a hard interval rather than measured: the
      # upper bound is a property of the code (the 5s call default), the lower is
      # the 2s+ subprocess this box has been seen to take. 2s sat on the lower
      # bound itself, which is the racing regime; 3.5s is the middle of the only
      # room the interval leaves. Widening past 5s would not be a safer budget,
      # it would be a different and weaker test.
      assert %{host: ^machine} = Task.await(reregister, 3_500)
      assert GenServer.whereis(server) == first_pid
    after
      :ok = :sys.resume(first_pid)
    end

    assert %{host: ^machine} =
             handlers["register-host"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 name: machine,
                 ssh: machine,
                 base_dir: "/remote/new-tb"
               }
             })

    second_pid = GenServer.whereis(server)
    assert is_pid(second_pid)
    refute second_pid == first_pid
    assert Credentials.status(:anthropic, server) == {:needs_onboarding, :missing}
    assert_receive {:credential_command, second_command}
    assert Enum.join(second_command, " ") =~ "/remote/new-tb"

    expected_message =
      "claude on #{machine} needs onboarding: :missing; run tightbeam onboard anthropic on #{machine}"

    assert %{
             code: "placement_denied",
             detail: %{code: "needs_onboarding"},
             message: ^expected_message
           } =
             handlers["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Fresh remote",
                 host: machine,
                 idempotency_key: "spawn-fresh-remote"
               }
             })
  end

  test "a crash-recovered turn warns that side effects are unknown, not undone", ctx do
    # Boot recovery terminalizes an interrupted turn as "outcome unknown". The
    # in-chat marker must tell the agent to VERIFY before repeating anything
    # non-idempotent — re-running `mix test` is fine, re-running a deploy is not.
    {:appended, message} =
      Projection.append(ctx.db, %{
        session_key: "k1",
        role: "user",
        content: "do the thing",
        sender: "user:flynn"
      })

    {:ok, seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: "k1",
        message_id: message.id,
        origin: "user:flynn",
        prompt: "do the thing"
      })

    :ok = DB.execute(ctx.db, "UPDATE turns SET status='running' WHERE seq=#{seq}")
    _ = Ledger.recover_running(ctx.db)

    assert [%{error: reason}] =
             ctx.db |> Ledger.unpublished_terminals() |> Enum.filter(&(&1.seq == seq))

    publisher = Gateway.terminal_publisher_for_test(ctx.db)
    # The marker is appended before the wire publish; the publish leg needs a
    # live registry that this test does not care about.
    try do
      publisher.(%{session_key: "k1", message_id: nil, status: "failed_unknown", error: reason})
    catch
      :exit, _ -> :ok
    end

    marker =
      ctx.db
      |> Projection.list_after("k1", nil, 100)
      |> Enum.find(&String.starts_with?(&1.content || "", "[turn failed]"))

    assert marker, "crash recovery must append the turn-failed marker"
    assert marker.content =~ "side effects are UNKNOWN, not undone"
    assert marker.content =~ "non-idempotent"
  end

  test "an ordinary failure with a known reason gets NO unknown-outcome warning", ctx do
    publisher = Gateway.terminal_publisher_for_test(ctx.db)

    try do
      publisher.(%{
        session_key: "k2",
        message_id: nil,
        status: "failed",
        error: "model refused the request"
      })
    catch
      :exit, _ -> :ok
    end

    marker =
      ctx.db
      |> Projection.list_after("k2", nil, 100)
      |> Enum.find(&String.starts_with?(&1.content || "", "[turn failed]"))

    assert marker
    assert marker.content =~ "model refused the request"
    refute marker.content =~ "side effects are UNKNOWN"
  end

  test "register-host with the LOCAL hostname never touches the boot-owned credential server",
       ctx do
    local = Tightbeam.Placement.local_host_name()
    base_dir = move_test_base(ctx.db, "local-host-reregistration", local)
    config = gateway_config(base_dir, ctx.db, 0)
    handlers = Gateway.handlers(config)

    local_server = GenServer.whereis(Credentials.server(local))

    # An operator assimilating the gateway's own hostname (plausible re-sweep
    # mistake) must be inert for credential supervision: replacing the local
    # server with a foreign base_dir + non-nil ssh wedges every local spawn
    # until restart (fail-closed), and Placement.hosts/1 ignores the registry
    # entry for the local name anyway.
    assert %{host: ^local} =
             handlers["register-host"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 name: local,
                 ssh: "clu@#{local}",
                 base_dir: "/remote/definitely-elsewhere"
               }
             })

    assert GenServer.whereis(Credentials.server(local)) == local_server,
           "local credential server was replaced by re-registering the local hostname"

    refute Enum.any?(Supervisor.which_children(Tightbeam.Supervisor), fn {id, _, _, _} ->
             id == {Credentials, local}
           end),
           "re-registering the local hostname minted a dynamic credential child"
  end

  # A satellite's OPERATOR shell has no session and therefore no endpoint: the
  # gateway injects a per-session token into every agent it launches there, and
  # an operator running `tightbeam onboard` is not one of those. Assimilation
  # left that shell with no url and no token at all, so onboarding — a three-
  # phase conversation with the gateway — died on ENOENT reading gateway.json,
  # and the documented install could not be completed on any assimilated host.
  # Registration is where the gateway learns the host exists, and it is the only
  # party that knows both its advertised url and the org token.
  test "register-host provisions the satellite's operator endpoint file", ctx do
    machine = "endpoint-worker"
    base_dir = move_test_base(ctx.db, "endpoint-provisioning", machine)

    File.write!(
      Path.join(base_dir, "gateway.json"),
      JSON.encode!(%{port: 11_373, cliToken: "tbc_org_secret"})
    )

    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:11373")
    on_exit(fn -> Application.delete_env(:tightbeam, :advertised_url) end)
    parent = self()

    sh = fn command ->
      if hd(command) == "rsync" do
        stage_file = Enum.at(command, -2)

        send(
          parent,
          {:staged, File.read!(stage_file), Bitwise.band(File.stat!(stage_file).mode, 0o777)}
        )
      end

      send(parent, {:command, command})
      {"", 0}
    end

    handlers = Gateway.handlers(gateway_config(base_dir, ctx.db, 11_373) |> Map.put(:sh, sh))

    assert %{host: ^machine} =
             handlers["register-host"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{name: machine, ssh: machine, base_dir: "/remote/tb"}
             })

    assert_receive {:staged, content, 0o600}

    assert JSON.decode!(content) == %{
             "url" => "http://gateway.example:11373",
             "cliToken" => "tbc_org_secret",
             "machine" => machine
           }

    assert_receive {:command, ["rsync" | _] = rsync}
    assert List.last(rsync) == "#{machine}:/remote/tb/"

    # Staged and rsynced, never interpolated into a command line: the org token
    # must not appear in the satellite's process table.
    refute Enum.any?(rsync, &String.contains?(&1, "tbc_org_secret"))
    refute File.exists?(Path.join([base_dir, "staging", "gateway-files", machine]))
  end

  test "register-host refuses a satellite when the gateway has no advertised url", ctx do
    machine = "unreachable-gateway-worker"
    base_dir = move_test_base(ctx.db, "endpoint-no-advertised-url", machine)

    File.write!(
      Path.join(base_dir, "gateway.json"),
      JSON.encode!(%{port: 11_373, cliToken: "tbc_org_secret"})
    )

    Application.delete_env(:tightbeam, :advertised_url)

    handlers =
      Gateway.handlers(
        gateway_config(base_dir, ctx.db, 11_373)
        |> Map.put(:sh, fn command -> flunk("unexpected command: #{inspect(command)}") end)
      )

    # Fail at registration rather than at the operator's first `onboard`: a host
    # with an ssh destination is a satellite, and a satellite whose gateway has no
    # advertised url cannot be reached by its own adapters either.
    assert %{code: "advertised_url_missing", message: message} =
             handlers["register-host"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{name: machine, ssh: machine, base_dir: "/remote/tb"}
             })

    assert message =~ "TIGHTBEAM_ADVERTISED_URL"
    assert Placement.hosts(base_dir, ctx.db)[machine].base_dir == "/remote/tb"
  end

  test "register-host raises a host-named error when credential child startup fails", ctx do
    machine = "credential-worker-start-failure"
    base_dir = move_test_base(ctx.db, "credential-server-start-failure", machine)
    {:ok, rejecting_supervisor} = RejectingCredentialSupervisor.start_link()

    handler =
      Gateway.handlers(
        gateway_config(base_dir, ctx.db, 0)
        |> Map.put(:credential_supervisor, rejecting_supervisor)
      )["register-host"]

    assert_raise RuntimeError,
                 "failed to start credential server for host #{machine}: :deliberate_start_failure",
                 fn ->
                   handler.(%{
                     origin: "user:flynn",
                     session_key: nil,
                     params: %{name: machine, ssh: machine, base_dir: "/remote/failed"}
                   })
                 end

    assert Placement.hosts(base_dir, ctx.db)[machine].base_dir == "/remote/failed"
  end

  test "spawn proceeds after a live remote readiness probe", ctx do
    base_dir = move_test_base(ctx.db, "spawn-ready")
    parent = self()

    # The catalog derives per {host, harness}, so the target host must be in the
    # registry the catalog server reads before it can hold a catalog for it.
    register_hosts(ctx.db, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: nil}
    })

    await_host_catalog("worker", "claude")

    sh = fn command ->
      send(parent, {:spinup_command, command})
      {"", 0}
    end

    start_supervised!(%{
      id: :ready_spawn_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    spawn =
      Gateway.handlers(gateway_config(base_dir, ctx.db, 0) |> Map.put(:sh, sh))["spawn"]

    assert %{session_key: session_key} =
             spawn.(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Remote",
                 host: "worker",
                 idempotency_key: "spawn-remote"
               }
             })

    assert Org.get(ctx.db, session_key).host == "worker"
    assert_receive {:spinup_command, ["ssh" | _]}
  end

  # Task #88 / per-host-catalogs-v1 acceptance 1. Both failure directions of one
  # defect: the catalog used to be the GATEWAY account's, applied to every host,
  # so a ref was validated against entitlements that had nothing to do with the
  # account the turn would run under. On the old tree this test is red twice —
  # the gateway-only ref spawns onto the satellite, and the satellite-only ref is
  # refused there.
  test "spawn validates the model against the TARGET host's catalog, not the gateway's", ctx do
    base_dir = move_test_base(ctx.db, "per-host-validate", "worker")
    parent = self()
    sh = fn command -> send(parent, {:spinup_command, command}) && {"", 0} end

    start_supervised!(%{
      id: :per_host_validate_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    register_hosts(ctx.db, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: nil}
    })

    await_host_catalog("worker", "claude")

    # Two accounts, two entitlements. Neither ref is offered by the other host.
    put_host_catalog("testhost", "claude", ["gateway-only-model"])
    put_host_catalog("worker", "claude", ["worker-only-model"])

    spawn = Gateway.handlers(gateway_config(base_dir, ctx.db, 0) |> Map.put(:sh, sh))["spawn"]

    place = fn host, model, key ->
      spawn.(%{
        origin: "user:flynn",
        session_key: nil,
        params: %{display_name: "S", host: host, model: model, idempotency_key: key}
      })
    end

    # Refused-though-runnable: worker CAN run this, and now says so.
    assert %{session_key: on_worker} = place.("worker", "worker-only-model", "k-worker-ok")
    assert Org.get(ctx.db, on_worker).host == "worker"

    # Masquerading (#81): the gateway's grant covers this ref, worker's does not.
    assert %{code: "model_unavailable", message: message} =
             place.("worker", "gateway-only-model", "k-worker-bad")

    assert message =~ ~s(model "gateway-only-model" is not offered by claude on host worker)
    assert message =~ "worker-only-model"

    # Symmetrically, on the gateway's own host (session k1) the gateway's ref is
    # good and the satellite's is not — tune, because it judges the ref against
    # the session's host without going through spinup.
    tune = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["tune"]

    retune = fn model ->
      tune.(%{
        origin: "user:flynn",
        session_key: "k1",
        params: %{setting: "set_model", model: model}
      })
    end

    assert %{ok: true} = retune.("gateway-only-model")

    assert %{code: "model_unavailable", message: gateway_message} =
             retune.("worker-only-model")

    assert gateway_message =~ "on host testhost"
  end

  # The codex models endpoint filters by client_version and reports nothing about
  # it — a too-old binary yields 200 with an empty list. The refusal must not
  # blame the grant, because re-onboarding will not change a thing.
  test "an empty catalog from a client_version filter blames the binary, not the grant", ctx do
    base_dir = role_test_base("client-version-empty")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)

    degrade_host_catalog(
      "testhost",
      "codex",
      {:empty_catalog_for_client_version, "0.99.0"}
    )

    assert %{code: "catalog_unavailable", message: message} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_harness", harness: "codex", model: "gpt-5.6-sol[medium]"}
             })

    assert message =~ "EMPTY model list for client_version \"0.99.0\""
    assert message =~ "upgrade codex on testhost"
    assert message =~ "credential is not implicated"
    refute message =~ "onboard"
  end

  # Acceptance 2: the gateway no longer needs a credential for a harness it does
  # not itself run. SATELLITE.md carried the opposite rule until this change.
  test "a harness with no GATEWAY credential still spawns on a satellite that has one", ctx do
    base_dir = move_test_base(ctx.db, "satellite-only-harness", "worker")
    parent = self()
    sh = fn command -> send(parent, {:spinup_command, command}) && {"", 0} end

    start_supervised!(%{
      id: :satellite_only_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    register_hosts(ctx.db, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: nil}
    })

    await_host_catalog("worker", "claude")

    put_host_catalog("worker", "claude", ["worker-only-model"])
    degrade_host_catalog("testhost", "claude", {:needs_onboarding, :no_credential})

    spawn = Gateway.handlers(gateway_config(base_dir, ctx.db, 0) |> Map.put(:sh, sh))["spawn"]

    assert %{session_key: session_key} =
             spawn.(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "SatOnly",
                 host: "worker",
                 model: "worker-only-model",
                 idempotency_key: "k-sat-only"
               }
             })

    assert Org.get(ctx.db, session_key).host == "worker"

    # The gateway's own host still refuses, and blames ITSELF rather than
    # demanding a grant for a machine that already has one.
    assert %{code: "catalog_unavailable", message: message} =
             spawn.(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "OnGateway",
                 host: "testhost",
                 model: "worker-only-model",
                 idempotency_key: "k-sat-only-gw"
               }
             })

    assert message =~ "anthropic has no usable credential on testhost"
    assert message =~ "run tightbeam onboard anthropic on testhost"
    refute message =~ "GATEWAY host"
    refute message =~ "onboard anthropic on worker"
  end

  test "kungfu-scaffold is admin-tier and commits a real starter that composes cleanly", ctx do
    base_dir = role_test_base("kungfu-scaffold")
    scaffold = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["kungfu-scaffold"]

    assert %{code: "forbidden", message: "admin required"} =
             scaffold.(%{origin: "user:not-admin", params: %{name: "demo"}})

    refute File.exists?(Path.join(base_dir, "identity"))

    expected_relatives = [
      "archetypes/demo-role.toml",
      "guidance/demo-role.md",
      "skills/demo-example/SKILL.md",
      "rails/demo-example.toml",
      "kungfu/demo/capabilities.md",
      "kungfu/demo/preferred-models.md",
      "kungfu/demo/intake.md",
      "kungfu/demo/README.md"
    ]

    assert %{kungfu: "demo", paths: paths} =
             scaffold.(%{origin: "user:flynn", params: %{name: "demo"}})

    identity_dir = Path.join(base_dir, "identity")

    assert Enum.map(paths, &Path.relative_to(&1, identity_dir)) == expected_relatives

    for relative <- expected_relatives do
      assert File.regular?(Path.join(identity_dir, relative))
    end

    manifest = Toml.decode!(File.read!(Path.join(identity_dir, "archetypes/demo-role.toml")))
    assert manifest["name"] == "demo-role"
    assert manifest["skills"] == []
    refute Map.has_key?(manifest, "where")
    assert manifest["guidance"]["text"] =~ ~s(#include "demo-role.md")

    skill = File.read!(Path.join(identity_dir, "skills/demo-example/SKILL.md"))
    assert skill =~ ~r/\A---\nname: demo-example\ndescription: .+\n---\n\n/s

    capabilities = File.read!(Path.join(identity_dir, "kungfu/demo/capabilities.md"))
    assert capabilities =~ "Root archetype: `demo-role`"
    assert capabilities =~ "| Capability | What adoption provides | Conversation watch-fors |"

    preferred_models = File.read!(Path.join(identity_dir, "kungfu/demo/preferred-models.md"))
    assert preferred_models =~ "| Activity | Wants | Minds, in order (park if none) |"

    intake = File.read!(Path.join(identity_dir, "kungfu/demo/intake.md"))
    assert intake =~ "Destination: `identity/kungfu/demo/capabilities.md`"
    assert intake =~ "Destination: `identity/kungfu/demo/preferred-models.md`"
    assert intake =~ "`tightbeam config set default-archetype demo-role`"

    readme = File.read!(Path.join(identity_dir, "kungfu/demo/README.md"))
    assert readme =~ "tightbeam-kungfu-crafting"
    assert readme =~ "identity/archetypes"

    archetypes = Archetypes.load!(base_dir)
    assert archetypes["demo-role"].skills == []
    assert Archetypes.guidance(archetypes["demo-role"]) =~ "# demo role"

    rail_manifest = Toml.decode!(File.read!(Path.join(identity_dir, "rails/demo-example.toml")))
    assert [starter_statute] = rail_manifest["statute"]
    assert starter_statute["name"] == "demo-example"

    statutes = Rails.load!(base_dir)
    statute = Enum.find(statutes, &(&1.name == "demo-example"))
    assert statute.pattern == "TIGHTBEAM_KUNGFU_TEMPLATE_PLACEHOLDER_NEVER_MATCHES"

    assert {"2\n", 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: identity_dir)

    assert {"kungfu-scaffold: demo|user:flynn|user-flynn@tightbeam.local\n", 0} =
             System.cmd("git", ["log", "-1", "--format=%s|%an|%ae"], cd: identity_dir)

    before = Map.new(expected_relatives, &{&1, File.read!(Path.join(identity_dir, &1))})

    assert_raise ArgumentError,
                 "kungfu scaffold target already exists: identity/archetypes/demo-role.toml",
                 fn ->
                   scaffold.(%{origin: "user:flynn", params: %{name: "demo"}})
                 end

    assert Map.new(expected_relatives, &{&1, File.read!(Path.join(identity_dir, &1))}) == before
    assert {"2\n", 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: identity_dir)
    assert {"", 0} = System.cmd("git", ["status", "--short"], cd: identity_dir)
  end

  test "invalid spawn overrides fail before spinup or any session side effect", ctx do
    base_dir = role_test_base("invalid-overrides")
    Archetypes.load!(base_dir)
    parent = self()

    sh = fn command ->
      send(parent, {:spinup_command, command})
      {"", 0}
    end

    spawn =
      Gateway.handlers(gateway_config(base_dir, ctx.db, 0) |> Map.put(:sh, sh))["spawn"]

    invalid = [
      nil,
      %{"unknown" => true},
      %{"skills_add" => "not-a-list"},
      %{"skills_add" => [1]},
      %{"skills_add" => ["missing"]},
      %{"guidance_extra" => 1},
      %{"guidance_extra" => ~s(#include "missing.md")}
    ]

    {:ok, [[before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM sessions")

    for {overrides, index} <- Enum.with_index(invalid) do
      result =
        spawn.(%{
          origin: "user:flynn",
          session_key: nil,
          params: %{
            display_name: "Invalid",
            idempotency_key: "invalid-overrides-#{index}",
            overrides: overrides
          }
        })

      assert result.code == "config_denied"
      assert result.detail.code == "invalid_overrides"
      assert is_binary(result.message)
    end

    assert {:ok, [[^before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM sessions")
    refute_received {:spinup_command, _}
  end

  test "semantically empty spawn overrides store NULL and the bare identity name", ctx do
    base_dir = role_test_base("empty-overrides")
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :empty_override_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    spawn = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["spawn"]

    created =
      spawn.(%{
        origin: "user:flynn",
        session_key: nil,
        params: %{
          display_name: "No effective override",
          idempotency_key: "empty-overrides",
          overrides: %{
            "skills_add" => [],
            "guidance_extra" => "   "
          }
        }
      })

    session = Org.get(ctx.db, created.session_key)
    assert session.overrides == nil
    assert session.identity_name == "default"

    assert {:ok, [[nil, "default"]]} =
             DB.query(
               ctx.db,
               "SELECT overrides, identityName FROM sessions WHERE sessionKey = ?1",
               [session.session_key]
             )
  end

  test "set_model applies a resident harness session before recording the selection", ctx do
    base_dir = role_test_base("override-set-model")
    put_skill!(base_dir, "review", "# Review")
    base = Archetypes.load!(base_dir)["default"]

    {:ok, overrides} =
      Archetypes.normalize_overrides(base_dir, base, %{"skills_add" => ["review"]})

    config = gateway_config(base_dir, ctx.db, 0)
    identity_name = Placement.identity_name(config, base, overrides, :claude)
    Org.set_identity(ctx.db, "k1", overrides, identity_name)
    Org.append_pointer(ctx.db, "k1", "existing-session", "created")

    adapter = start_supervised!({TuneAdapterStub, {self(), resident: true}})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_model", model: "claude-sonnet-4-6"}
             })

    assert_receive {:adapter_key, {:claude, "shared", "testhost"}}
    assert_receive {:tune_residency_checked, "existing-session"}
    assert_receive {:tune_model_applied, "existing-session", "claude-sonnet-4-6"}
    assert Org.get(ctx.db, "k1").model == "claude-sonnet-4-6"
  end

  test "set_model records a resident apply failure and leaves the selected model unchanged",
       ctx do
    base_dir = role_test_base("resident-set-model-failure")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)
    before = Org.get(ctx.db, "k1").model
    Org.append_pointer(ctx.db, "k1", "resident-session", "created")

    adapter =
      start_supervised!(
        {TuneAdapterStub, {self(), resident: true, apply_result: {:error, :model_unavailable}}}
      )

    start_supervised!({CoordinatorStub, adapter})

    # The reason rides the MESSAGE now. It used to ride a `reason:` key the wire
    # does not emit, so this refusal reached clients as a bare `ok: false` (#68).
    assert %{ok: false, code: "model_apply_failed", message: message} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_model", model: "claude-sonnet-4-6"}
             })

    assert message =~ "model_unavailable"

    assert_receive {:tune_model_applied, "resident-session", "claude-sonnet-4-6"}
    assert Org.get(ctx.db, "k1").model == before
  end

  describe "session status reports its host's credential kind" do
    setup ctx do
      base =
        Path.join(
          System.tmp_dir!(),
          "gateway-credential-kind-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf!(base) end)
      Archetypes.load!(role_test_base("session-status-credential-kind"))

      # `Credentials.server/1` resolves to the local name, so the session's host
      # must BE this machine for the status read to reach the owner started here.
      Application.put_env(:tightbeam, :local_host_name, "kindhost")

      Org.create(ctx.db, %{
        session_key: "k-kind",
        display_name: "Kind",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "kindhost",
        harness: "claude",
        provider: "anthropic",
        model: "claude-sonnet-5[medium]"
      })

      %{cred_base: base}
    end

    # start_supervised! rather than start_link: this server registers under the
    # module name that `Credentials.server/1` resolves to for the local host, so
    # a leaked one would answer for every later test in the run. ExUnit owning
    # its lifecycle is what keeps that from happening.
    defp owner!(base) do
      start_supervised!({Credentials, name: Credentials, base_dir: base, machine: "kindhost"})
      Credentials
    end

    defp bank!(base, kind) do
      server = owner!(base)
      bank_into!(server, kind)
      server
    end

    defp bank_into!(server, kind) do
      {:ok, staging} = Credentials.begin_onboard(:anthropic, server)
      File.write!(Path.join(staging, "oauth-token"), "credential-bytes")
      :ok = Credentials.finish_onboard(:anthropic, kind, server)
    end

    test "an API-key host reports apiKey", ctx do
      bank!(ctx.cred_base, :api_key)

      assert Gateway.session_status("k-kind", ctx.db).display.credentialKind == "apiKey"
    end

    test "a subscription host reports subscription", ctx do
      bank!(ctx.cred_base, :subscription)

      assert Gateway.session_status("k-kind", ctx.db).display.credentialKind == "subscription"
    end

    test "a host with no credential reports its own state, not a missing field", ctx do
      owner!(ctx.cred_base)

      display = Gateway.session_status("k-kind", ctx.db).display

      # Absence is a VALUE. A client that saw the field vanish could not tell
      # "no credential here" from a decoder change.
      assert Map.has_key?(display, :credentialKind)
      assert display.credentialKind == "none"
    end

    # The test that distinguishes "resolved at read time" from "stamped on the
    # row" — a row-stamped implementation passes all three above and fails this.
    test "the reported kind flips when the host is re-onboarded on the other kind", ctx do
      server = bank!(ctx.cred_base, :subscription)
      assert Gateway.session_status("k-kind", ctx.db).display.credentialKind == "subscription"

      bank_into!(server, :api_key)

      # The session row was never touched between the two reads.
      assert Gateway.session_status("k-kind", ctx.db).display.credentialKind == "apiKey"
    end
  end

  test "session_status splits setModel (one row per model) from setReasoning (current model's tiers)",
       ctx do
    Archetypes.load!(role_test_base("session-status-reasoning"))

    Org.create(ctx.db, %{
      session_key: "k-reasoning",
      display_name: "Reasoning",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "codex",
      provider: "openai",
      model: "gpt-5.6-sol[medium]"
    })

    status = Gateway.session_status("k-reasoning", ctx.db)

    assert %{supported: true, options: options} = status.capabilities.setReasoning

    assert Enum.map(options, & &1.value) |> Enum.sort() ==
             Enum.sort(~w(low medium high xhigh max ultra))

    assert Enum.all?(options, &(&1.title == &1.value))
    assert status.capabilities.canChangeReasoning == true

    assert %{supported: true, options: model_options} = status.capabilities.setModel
    refute Enum.any?(model_options, fn o -> String.contains?(o.value, "[") end)
    sol = Enum.find(model_options, &(&1.value == "gpt-5.6-sol"))
    assert sol.title == "GPT-5.6 Sol"
    assert length(Enum.filter(model_options, &(&1.value == "gpt-5.6-sol"))) == 1

    # modelCatalog.models is the client picker's PRIMARY data source
    # (SessionStatusFooter falls back to setModel.options only when the
    # catalog is unavailable) — same one-row-per-model collapse, base refs.
    catalog_models = status.modelCatalog.models
    refute Enum.any?(catalog_models, &String.contains?(&1.ref, "["))
    refute Enum.any?(catalog_models, &String.contains?(&1.id, "["))
    assert Enum.map(catalog_models, & &1.ref) == Enum.uniq(Enum.map(catalog_models, & &1.ref))
    assert Enum.map(catalog_models, & &1.name) == Enum.uniq(Enum.map(catalog_models, & &1.name))
    assert %{name: "GPT-5.6 Sol"} = Enum.find(catalog_models, &(&1.ref == "gpt-5.6-sol"))

    # display.model must match a catalog row (the footer shows it verbatim
    # otherwise, leaking the machine ref) and reasoningLevel carries the tier.
    assert status.display.model == "gpt-5.6-sol"
    assert status.display.reasoningLevel == "medium"
  end

  test "session_status marks setReasoning unsupported for a model with no effort tiers", ctx do
    Archetypes.load!(role_test_base("session-status-untiered"))

    Org.create(ctx.db, %{
      session_key: "k-untiered",
      display_name: "Untiered",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "claude-sonnet-4-6"
    })

    status = Gateway.session_status("k-untiered", ctx.db)

    assert %{supported: false, reason: reason} = status.capabilities.setReasoning
    assert reason =~ "no effort tiers"
    assert status.capabilities.canChangeReasoning == false
  end

  test "unknown model status degrades and tune never composes it as a model ref", ctx do
    base_dir = role_test_base("unknown-model-status")
    Archetypes.load!(base_dir)
    make_model_unknown(ctx.db, "k1")

    status = Gateway.session_status("k1", ctx.db)

    assert status.display.model == "unknown"
    assert status.display.reasoningLevel == nil

    assert %{supported: false, reason: "current model is unknown"} =
             status.capabilities.setReasoning

    refute status.capabilities.canChangeReasoning

    tune = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["tune"]

    assert %{ok: false, code: "model_unknown"} =
             tune.(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_reasoning", reasoningLevel: "high"}
             })

    assert %{ok: true} =
             tune.(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_model", model: "claude-sonnet-4-6"}
             })

    assert Org.get(ctx.db, "k1").model == "claude-sonnet-4-6"
  end

  test "a ref emitted by modelCatalog.models round-trips through set_model", ctx do
    base_dir = role_test_base("catalog-ref-round-trip")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)

    Org.create(ctx.db, %{
      session_key: "k-round-trip",
      display_name: "Codex",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "codex",
      provider: "anthropic",
      model: "gpt-5.6-sol[medium]"
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    # The client sends modelCatalog.models[].ref back as the set_model value.
    emitted = Gateway.session_status("k-round-trip", ctx.db).modelCatalog.models
    terra_ref = Enum.find(emitted, &(&1.name == "GPT-5.6 Terra")).ref

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-round-trip",
               params: %{setting: "set_model", model: terra_ref}
             })

    assert Org.get(ctx.db, "k-round-trip").model =~ ~r/^gpt-5\.6-terra\[(low|high)\]$/
    assert Org.get(ctx.db, "k-round-trip").provider == "openai"
  end

  test "set_model with a bare model id keeps the current effort tier", ctx do
    base_dir = role_test_base("set-model-bare-keeps-effort")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)

    Org.create(ctx.db, %{
      session_key: "k-codex",
      display_name: "Codex",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "codex",
      provider: "openai",
      model: "gpt-5.6-sol[xhigh]"
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex",
               params: %{setting: "set_model", model: "gpt-5.6-sol"}
             })

    assert Org.get(ctx.db, "k-codex").model == "gpt-5.6-sol[xhigh]"
  end

  test "set_model with a bare model id falls back to the new model's first tier when the current effort doesn't apply",
       ctx do
    base_dir = role_test_base("set-model-bare-falls-back")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)

    Org.create(ctx.db, %{
      session_key: "k-codex-fallback",
      display_name: "Codex",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "codex",
      provider: "openai",
      model: "gpt-5.6-sol[xhigh]"
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex-fallback",
               params: %{setting: "set_model", model: "gpt-5.6-terra"}
             })

    # gpt-5.6-terra only offers low/high (in that catalog order); xhigh
    # doesn't carry over and terra has no "medium" either, so this lands on
    # its first listed tier.
    assert Org.get(ctx.db, "k-codex-fallback").model == "gpt-5.6-terra[low]"
  end

  test "set_model with a bare model id prefers 'medium' when the current effort doesn't apply but medium does",
       ctx do
    base_dir = role_test_base("set-model-bare-prefers-medium")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)

    Org.create(ctx.db, %{
      session_key: "k-codex-medium",
      display_name: "Codex",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "codex",
      provider: "openai",
      model: "gpt-5.6-nano[turbo]"
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex-medium",
               params: %{setting: "set_model", model: "gpt-5.6-sol"}
             })

    # "turbo" doesn't exist on sol, but sol does offer "medium", so that's
    # preferred over just taking the first listed tier.
    assert Org.get(ctx.db, "k-codex-medium").model == "gpt-5.6-sol[medium]"
  end

  test "set_model with a bare model id switching to an untiered model drops the effort qualifier",
       ctx do
    base_dir = role_test_base("set-model-bare-to-untiered")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)

    Org.create(ctx.db, %{
      session_key: "k-codex-untiered",
      display_name: "Codex",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "codex",
      provider: "openai",
      model: "gpt-5.6-sol[high]"
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex-untiered",
               params: %{setting: "set_model", model: "gpt-5.6-classic"}
             })

    assert Org.get(ctx.db, "k-codex-untiered").model == "gpt-5.6-classic"
  end

  test "set_model still accepts a full bracketed ref directly (back-compat)", ctx do
    base_dir = role_test_base("set-model-full-ref-back-compat")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)

    Org.create(ctx.db, %{
      session_key: "k-codex-full-ref",
      display_name: "Codex",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "codex",
      provider: "openai",
      model: "gpt-5.6-sol[medium]"
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex-full-ref",
               params: %{setting: "set_model", model: "gpt-5.6-sol[low]"}
             })

    assert Org.get(ctx.db, "k-codex-full-ref").model == "gpt-5.6-sol[low]"
  end

  test "set_reasoning composes the current model with the newly selected effort tier", ctx do
    base_dir = role_test_base("set-reasoning")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)

    Org.create(ctx.db, %{
      session_key: "k-codex-reasoning",
      display_name: "Codex",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "codex",
      provider: "openai",
      model: "gpt-5.6-sol[medium]"
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex-reasoning",
               params: %{setting: "set_reasoning", reasoningLevel: "xhigh"}
             })

    assert Org.get(ctx.db, "k-codex-reasoning").model == "gpt-5.6-sol[xhigh]"
  end

  test "set_reasoning rejects a level the current model does not offer", ctx do
    base_dir = role_test_base("set-reasoning-invalid")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)
    before = Org.get(ctx.db, "k1")

    assert %{code: code} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_reasoning", reasoningLevel: "nonexistent"}
             })

    assert code in ["model_unavailable", "catalog_unavailable"]
    assert Org.get(ctx.db, "k1") == before
  end

  test "cancel addresses the overridden adapter key", ctx do
    base_dir = role_test_base("override-cancel")
    put_skill!(base_dir, "review", "# Review")
    base = Archetypes.load!(base_dir)["default"]

    {:ok, overrides} =
      Archetypes.normalize_overrides(base_dir, base, %{"skills_add" => ["review"]})

    config = gateway_config(base_dir, ctx.db, 0)
    identity_name = Placement.identity_name(config, base, overrides, :claude)
    Org.set_identity(ctx.db, "k1", overrides, identity_name)
    Org.append_pointer(ctx.db, "k1", "cancel-session", "created")

    task_sup = start_supervised!({Task.Supervisor, name: :override_cancel_tasks})

    start_supervised!(%{
      id: :override_cancel_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "cancel me",
               db: ctx.db,
               conn_registry: ctx.registry,
               lane_manager: ctx.lane
             )

    parent = self()

    lane =
      start_supervised!(
        {Tightbeam.SessionLane,
         session_key: "k1",
         db: ctx.db,
         task_sup: task_sup,
         runner: fn _turn ->
           send(parent, :cancel_runner_started)
           receive do: (:never -> {:ok, %{}})
         end}
      )

    barrier_lane_started(lane)
    assert_receive :cancel_runner_started

    assert %{ok: true} =
             Gateway.handlers(config)["cancel"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{}
             })

    assert_receive {:adapter_key, {:claude, "shared", "testhost"}}
    assert Process.alive?(lane)

    assert {:ok, [["canceled"]]} =
             DB.query(ctx.db, "SELECT status FROM turns ORDER BY seq DESC LIMIT 1")
  end

  test "cancel stays durable and the lane alive when the adapter is dead", ctx do
    base_dir = role_test_base("dead-adapter-cancel")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)
    Org.append_pointer(ctx.db, "k1", "dead-session", "created")
    task_sup = start_supervised!({Task.Supervisor, name: :dead_cancel_tasks})
    ensure_global_registry()

    dead_adapter = spawn(fn -> :ok end)
    monitor = Process.monitor(dead_adapter)
    assert_receive {:DOWN, ^monitor, :process, ^dead_adapter, :normal}
    start_supervised!({CoordinatorStub, dead_adapter})

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "cancel dead adapter",
               db: ctx.db,
               conn_registry: ctx.registry,
               lane_manager: ctx.lane
             )

    parent = self()

    lane =
      start_supervised!(
        {Tightbeam.SessionLane,
         session_key: "k1",
         db: ctx.db,
         task_sup: task_sup,
         runner: fn _turn ->
           send(parent, :dead_adapter_runner_started)
           receive do: (:never -> {:ok, %{}})
         end}
      )

    barrier_lane_started(lane)
    assert_receive :dead_adapter_runner_started

    assert %{ok: true} =
             Gateway.handlers(config)["cancel"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{}
             })

    assert Process.alive?(lane)

    assert {:ok, [["canceled"]]} =
             DB.query(ctx.db, "SELECT status FROM turns ORDER BY seq DESC LIMIT 1")
  end

  test "cancel commits before a slow adapter and leaves the lane alive", ctx do
    base_dir = role_test_base("slow-adapter-cancel")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)
    Org.append_pointer(ctx.db, "k1", "slow-session", "created")
    task_sup = start_supervised!({Task.Supervisor, name: :slow_cancel_tasks})
    ensure_global_registry()
    adapter = start_supervised!({SlowConnAdapterStub, self()})
    start_supervised!({CoordinatorStub, adapter})

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "cancel slow adapter",
               db: ctx.db,
               conn_registry: ctx.registry,
               lane_manager: ctx.lane
             )

    parent = self()

    lane =
      start_supervised!(
        {Tightbeam.SessionLane,
         session_key: "k1",
         db: ctx.db,
         task_sup: task_sup,
         runner: fn _turn ->
           send(parent, :slow_adapter_runner_started)
           receive do: (:never -> {:ok, %{}})
         end}
      )

    barrier_lane_started(lane)
    assert_receive :slow_adapter_runner_started

    cancel =
      Task.async(fn ->
        Gateway.handlers(config)["cancel"].(%{
          origin: "user:flynn",
          session_key: "k1",
          params: %{}
        })
      end)

    assert_receive {:cancel_conn_waiting, ^adapter}

    assert {:ok, [["canceled"]]} =
             DB.query(ctx.db, "SELECT status FROM turns ORDER BY seq DESC LIMIT 1")

    assert Process.alive?(lane)

    send(adapter, :release_cancel_conn)
    assert %{ok: true} = Task.await(cancel)
  end

  test "boot migration turns legacy handles into roles idempotently", ctx do
    legacy =
      Org.create(ctx.db, %{
        session_key: "legacy-session",
        display_name: "Legacy",
        owner_user_id: "flynn",
        origin: "user:flynn",
        handle: "legacy-office",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    base_dir = role_test_base("migration")
    config = gateway_config(base_dir, ctx.db, 0)
    Gateway.children(config)
    Gateway.children(config)

    assert %{bound_session_key: key, owner_user_id: "flynn"} =
             Roles.get(ctx.db, "legacy-office")

    assert key == legacy.session_key

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM roles WHERE name = 'legacy-office'")
  end

  test "role verbs enforce owner, admin, binding ownership, and process denials", ctx do
    {:pending, _} =
      Devices.pair(ctx.db, %{
        device_id: "other-device",
        claimed_name: "Other",
        platform: nil,
        model: nil
      })

    other = create_session(ctx.db, "agent:other", "other")
    other_second = create_session(ctx.db, "agent:other-second", "other")
    handlers = Gateway.handlers(gateway_config("/tmp", ctx.db, 0))

    assert %{role: %{owner_user_id: "flynn"}} =
             handlers["role-create"].(%{
               origin: "user:flynn",
               params: %{name: "flynn-office"}
             })

    Roles.create!(ctx.db, "other-office", "other", other.session_key)

    for verb <- ["role-create", "role-bind", "role-rm"] do
      params =
        case verb do
          "role-create" -> %{name: "process-office"}
          "role-bind" -> %{name: "flynn-office", session_key: "k1"}
          "role-rm" -> %{name: "flynn-office"}
        end

      assert %{code: "denied"} = handlers[verb].(%{origin: "process:cron", params: params})
    end

    assert %{code: "denied"} =
             handlers["role-bind"].(%{
               origin: "user:other",
               params: %{name: "flynn-office", session_key: other.session_key}
             })

    assert %{code: "denied"} =
             handlers["role-create"].(%{
               origin: "user:other",
               params: %{name: "foreign-binding", bind: "k1"}
             })

    assert %{code: "denied"} =
             handlers["role-bind"].(%{
               origin: "user:other",
               params: %{name: "other-office", session_key: "k1"}
             })

    assert %{role: %{bound_session_key: "agent:other-second"}} =
             handlers["role-bind"].(%{
               origin: "user:other",
               params: %{name: "other-office", session_key: other_second.session_key}
             })

    Roles.create!(ctx.db, "other-remove", "other", nil)

    assert %{removed: "other-remove"} =
             handlers["role-rm"].(%{
               origin: "user:other",
               params: %{name: "other-remove"}
             })

    assert %{role: %{bound_session_key: "k1"}} =
             handlers["role-bind"].(%{
               origin: "user:flynn",
               params: %{name: "other-office", session_key: "k1"}
             })

    assert %{removed: "other-office"} =
             handlers["role-rm"].(%{origin: "user:flynn", params: %{name: "other-office"}})

    assert %{roles: roles} = handlers["role-list"].(%{origin: "process:cron", params: %{}})

    assert Enum.any?(
             roles,
             &(&1.name == "flynn-office" and
                 &1.fallback_target == Org.personal_session_key("flynn"))
           )
  end

  test "set_host denies on workdir sync failure and leaves Org unchanged", ctx do
    base_dir = move_test_base(ctx.db, "failure")
    source = test_workdir(base_dir, "k1")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "memory.md"), "keep")

    sh = fn command ->
      if hd(command) == "rsync", do: {"copy failed", 23}, else: {"", 0}
    end

    tune =
      Gateway.handlers(gateway_config(base_dir, ctx.db, 0) |> Map.put(:sh, sh))["tune"]

    result =
      tune.(%{
        origin: "user:flynn",
        session_key: "k1",
        params: %{setting: "set_host", host: "worker"}
      })

    assert %{code: "workdir_move_failed", message: message} = result
    assert message =~ "exit 23"
    assert Org.get(ctx.db, "k1").host == "testhost"
  end

  test "set_host proceeds when the source workdir is missing", ctx do
    base_dir = move_test_base(ctx.db, "missing")
    parent = self()

    sh = fn command ->
      if hd(command) == "rsync", do: send(parent, {:unexpected_command, command})
      {"", 0}
    end

    tune =
      Gateway.handlers(gateway_config(base_dir, ctx.db, 0) |> Map.put(:sh, sh))["tune"]

    assert tune.(%{
             origin: "user:flynn",
             session_key: "k1",
             params: %{setting: "set_host", host: "worker"}
           }) == %{ok: true, host: "worker"}

    assert Org.get(ctx.db, "k1").host == "worker"
    refute_received {:unexpected_command, _}
  end

  test "set_host readiness denial leaves Org unchanged", ctx do
    base_dir = move_test_base(ctx.db, "readiness-denial")

    sh = fn command ->
      if String.contains?(List.last(command), "test -f"), do: {"", 1}, else: {"", 0}
    end

    tune =
      Gateway.handlers(gateway_config(base_dir, ctx.db, 0) |> Map.put(:sh, sh))["tune"]

    assert %{code: "host_unready", message: message} =
             tune.(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_host", host: "worker"}
             })

    assert message =~ "no claude credentials"
    assert Org.get(ctx.db, "k1").host == "testhost"
  end

  test "effort request survives park/swap and respawn supersedes then re-arms", ctx do
    parent =
      Org.create(ctx.db, %{
        session_key: "effort-parent",
        display_name: "Effort parent",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE sessions SET spawnedBy='effort-parent' WHERE sessionKey='k1'"
      )

    base_dir = role_test_base("effort-adjudication")

    config =
      gateway_config(base_dir, ctx.db, 0)
      # Injected at the SHELL: the real observation command is built, run and
      # parsed; only what a filesystem would have said is supplied.
      |> Map.put(:sh, fn _invocation -> {"B\tobserved\t0\n/w\n", 0} end)

    item =
      Assignments.__handle__(ctx.db, "dispatch", %{
        verb: "dispatch",
        origin: "agent:effort-parent",
        principal: {:session, "effort-parent"},
        session_key: "k1",
        target_role: nil,
        role_fallback: false,
        params: %{subject: "adjudication motion", brief: "adjudication motion"},
        effort_config: config
      })

    {:ok, [[probe_wake_id]]} =
      DB.query(
        ctx.db,
        "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
        [item.id]
      )

    # Rung one prods the holder; the owner's request is rung two.
    :ok = EffortCheckin.probe(ctx.db, config, Wakes.get(ctx.db, probe_wake_id))

    {:ok, [[second_probe_wake_id]]} =
      DB.query(
        ctx.db,
        "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
        [item.id]
      )

    :ok = EffortCheckin.probe(ctx.db, config, Wakes.get(ctx.db, second_probe_wake_id))

    {:ok, [[request_id]]} =
      DB.query(
        ctx.db,
        "SELECT id FROM decision_requests WHERE kind='effort' AND assignmentId=?1 AND status='open'",
        [item.id]
      )

    {:appended, failed_message} =
      Projection.append(ctx.db, %{
        session_key: "k1",
        role: "user",
        content: "failed prompt",
        sender: "user:flynn"
      })

    {:ok, failed_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: "k1",
        message_id: failed_message.id,
        origin: "user:flynn",
        prompt: "failed prompt"
      })

    :ok = DB.execute(ctx.db, "UPDATE turns SET status='running' WHERE seq=#{failed_seq}")
    :ok = Ledger.finish(ctx.db, failed_seq, "failed", "quota")

    handlers = Gateway.handlers(config)

    for {action, model} <- [{"park", nil}, {"swap", "claude-sonnet-4-6"}] do
      episode = notify_adjudication(ctx.db, "k1", parent.session_key)

      call = %{
        origin: "agent:effort-parent",
        principal: {:session, parent.session_key},
        session_key: "k1",
        params: %{episode: episode.correlation_key, action: action, model: model}
      }

      if action == "swap" do
        assert %{code: "adapter_unavailable"} = handlers["adjudicate"].(call)

        assert {:ok, true} =
                 DB.transaction(ctx.db, fn txn ->
                   current = Adjudication.get_in_txn(txn, "k1", "other")
                   Adjudication.resolve_in_txn(txn, current)
                 end)
      else
        assert %{ok: true, action: "park"} = handlers["adjudicate"].(call)
      end

      assert {:ok, [[^request_id, "open"]]} =
               DB.query(ctx.db, "SELECT id,status FROM decision_requests WHERE id=?1", [
                 request_id
               ])
    end

    assert %{status: "ruled", decision: "dismiss"} =
             EffortCheckin.rule(ctx.db, config, %{
               origin: "agent:effort-parent",
               principal: {:session, parent.session_key},
               params: %{request_id: request_id, action: "dismiss"}
             })

    assert {:ok, [[ruleable_probe_wake]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
               [item.id]
             )

    # A dismissal re-arms a FRESH bracket, so the agent is prodded once more
    # before its owner is asked anything again.
    :ok = EffortCheckin.probe(ctx.db, config, Wakes.get(ctx.db, ruleable_probe_wake))

    assert {:ok, [[reprodded_probe_wake]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
               [item.id]
             )

    :ok = EffortCheckin.probe(ctx.db, config, Wakes.get(ctx.db, reprodded_probe_wake))

    assert {:ok, [[motion_request_id]]} =
             DB.query(
               ctx.db,
               "SELECT id FROM decision_requests WHERE assignmentId=?1 AND status='open'",
               [item.id]
             )

    episode = notify_adjudication(ctx.db, "k1", parent.session_key)

    catch_exit(
      handlers["adjudicate"].(%{
        origin: "agent:effort-parent",
        principal: {:session, parent.session_key},
        session_key: "k1",
        params: %{
          episode: episode.correlation_key,
          action: "respawn",
          model: "claude-sonnet-4-6"
        }
      })
    )

    assert {:ok, [[new_holder, "superseded"]]} =
             DB.query(
               ctx.db,
               """
               SELECT a.holderKey,r.status
               FROM assignments a JOIN decision_requests r ON r.assignmentId=a.id
               WHERE a.id=?1 AND r.id=?2
               """,
               [item.id, motion_request_id]
             )

    refute new_holder == "k1"

    assert {:ok, [[fresh_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
               [item.id]
             )

    # Respawn re-armed on the NEW holder, so that holder gets the prod rung too.
    :ok = EffortCheckin.probe(ctx.db, config, Wakes.get(ctx.db, fresh_wake_id))

    assert {:ok, [[fresh_second_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
               [item.id]
             )

    :ok = EffortCheckin.probe(ctx.db, config, Wakes.get(ctx.db, fresh_second_wake_id))

    assert {:ok, [[fresh_request_id]]} =
             DB.query(
               ctx.db,
               "SELECT id FROM decision_requests WHERE kind='effort' AND assignmentId=?1 AND status='open'",
               [item.id]
             )

    stop_episode = notify_adjudication(ctx.db, new_holder, parent.session_key)

    catch_exit(
      handlers["adjudicate"].(%{
        origin: "agent:effort-parent",
        principal: {:session, parent.session_key},
        session_key: new_holder,
        params: %{episode: stop_episode.correlation_key, action: "stop"}
      })
    )

    assert {:ok, [["closed", "superseded"]]} =
             DB.query(
               ctx.db,
               """
               SELECT a.state,r.status
               FROM assignments a JOIN decision_requests r ON r.assignmentId=a.id
               WHERE a.id=?1 AND r.id=?2
               """,
               [item.id, fresh_request_id]
             )
  end

  test "set_harness readiness denial leaves Org unchanged", ctx do
    base_dir = role_test_base("harness-unready", false)
    tune = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["tune"]
    before = Org.get(ctx.db, "k1")

    assert %{code: "host_unready", message: message} =
             tune.(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{
                 setting: "set_harness",
                 harness: "codex",
                 model: "gpt-5.6-sol[medium]"
               }
             })

    assert message =~ "no codex credentials"
    assert Org.get(ctx.db, "k1") == before
  end

  # The value a client is TOLD to send must be a value this accepts. `setModel.options`
  # and `modelCatalog.models` advertise one row per model with a base ref, deliberately
  # — the effort tier belongs to the reasoning picker — while the catalog only holds an
  # effort-bearing model as `id[effort]`. `set_model` composes the two and has since
  # cbc8d2e; `set_harness` did not, so the same bare id round-tripped through one verb
  # and was refused by the other as "not offered by codex on testhost" (#69).
  test "set_harness accepts the bare model id the picker advertises", ctx do
    base_dir = role_test_base("harness-bare-model")
    codex_auth = Path.join([base_dir, "auth", "codex"])
    File.mkdir_p!(codex_auth)
    File.write!(Path.join(codex_auth, "auth.json"), "test-token")
    Archetypes.load!(base_dir)

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:conn_registry, ctx.registry)
      |> Map.put(:lane_manager, ctx.lane)

    start_supervised!(%{
      id: :harness_bare_model_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    assert %{ok: true, harness: "codex"} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_harness", harness: "codex", model: "gpt-5.6-sol"}
             })

    # Composed, not passed through: the tier is real information and the session must
    # end up on a ref the catalog actually offers.
    assert Org.get(ctx.db, "k1").model == "gpt-5.6-sol[medium]"

    # And the value under test is one the picker really does advertise for this
    # session, so the case cannot keep passing if the advertised shape drifts. Read
    # after the swap, because that is when the picker is offering codex's models.
    advertised =
      Gateway.session_status("k1", ctx.db).capabilities.setModel.options
      |> Enum.map(& &1.value)

    assert "gpt-5.6-sol" in advertised
    refute Enum.any?(advertised, &String.contains?(&1, "["))
  end

  test "set_harness keeps an overridden identity name and projects the new harness home", ctx do
    base_dir = role_test_base("harness-override")
    codex_auth = Path.join([base_dir, "auth", "codex"])
    File.mkdir_p!(codex_auth)
    File.write!(Path.join(codex_auth, "auth.json"), "test-token")
    put_skill!(base_dir, "review", "# Review")
    base = Archetypes.load!(base_dir)["default"]

    {:ok, overrides} =
      Archetypes.normalize_overrides(base_dir, base, %{"skills_add" => ["review"]})

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:conn_registry, ctx.registry)
      |> Map.put(:lane_manager, ctx.lane)

    start_supervised!(%{
      id: :harness_override_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    identity_name = Placement.identity_name(config, base, overrides, :claude)
    assert Placement.identity_name(config, base, overrides, :codex) == identity_name
    Org.set_identity(ctx.db, "k1", overrides, identity_name)

    assert %{ok: true, harness: "codex"} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{
                 setting: "set_harness",
                 harness: "codex",
                 model: "gpt-5.6-sol[medium]"
               }
             })

    assert Org.get(ctx.db, "k1").identity_name == identity_name
    home = Tightbeam.Homes.home_path(base_dir, "testhost", :codex)
    refute File.exists?(Path.join(home, "AGENTS.md"))

    assert JSON.decode!(File.read!(Path.join([home, ".tightbeam", "manifest"])))["harness"] ==
             "codex"
  end

  test "deliver_prompt commits echo+turn once and client duplicate short-circuits", ctx do
    opts = [
      db: ctx.db,
      conn_registry: ctx.registry,
      lane_manager: ctx.lane,
      device_id: "d1",
      client_message_id: "c_1"
    ]

    assert Gateway.deliver_prompt("k1", "user:flynn", "hello", opts) == :appended
    assert_receive {:push_message, "k1", _seq, %{"type" => "message", "role" => "user"}}

    assert_receive {:push,
                    %{"event" => "prompt_turn_state", "payload" => %{"state" => "accepted"}}}

    assert_receive {:ensure_lane, "k1"}
    assert Gateway.deliver_prompt("k1", "user:flynn", "hello", opts) == :duplicate
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM messages")
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")
  end

  test "conversational turns stay unattributed and bracket-1 nags reverse-link jobRef only",
       ctx do
    :ok =
      DB.execute(ctx.db, """
      INSERT INTO work_items
        (id, title, ownerUserId, state, routingWakeId, createdByUser, createdAt)
      VALUES ('wi_nag', 'Route me', 'flynn', 'open', 'w_nag', 'flynn', 1)
      """)

    common = [
      db: ctx.db,
      conn_registry: ctx.registry,
      lane_manager: ctx.lane,
      sender: "process:tightbeam"
    ]

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "conversation", common)

    assert :appended =
             Gateway.deliver_prompt(
               "k1",
               "process:tightbeam",
               "route it or icebox it",
               Keyword.put(common, :wake_id, "w_nag")
             )

    assert {:ok, rows} =
             DB.query(
               ctx.db,
               "SELECT assignmentId, jobRef FROM turns ORDER BY seq ASC"
             )

    assert rows == [[nil, nil], [nil, "wi_nag"]]
  end

  test "wake_id dedupes the transaction including its second echo", ctx do
    opts = [
      db: ctx.db,
      conn_registry: ctx.registry,
      lane_manager: ctx.lane,
      wake_id: "w_1",
      sender: "agent:caller"
    ]

    assert Gateway.deliver_prompt("k1", "agent:caller", "wake", opts) == :appended
    assert Gateway.deliver_prompt("k1", "agent:caller", "wake", opts) == :duplicate
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM messages")
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId = 'w_1'")
  end

  # @cold_runner_prompt_timeout is 60_000 and ExUnit's default per-test timeout is
  # also 60_000, so the budget would be capped by the test timeout and would report
  # as "test timed out" rather than naming the wait that actually ran out. Raise the
  # ceiling above the budget it contains.
  @tag timeout: 180_000
  test "one fake-adapter turn uses the MCP fallback and publishes the golden frame order", ctx do
    exact_registry =
      start_supervised!(%{
        id: :exact_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "golden",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    base = gateway_children_base!()
    put_skill!(base, "review", "# Review")
    manifest_path = Path.join([base, "identity", "archetypes", "default.toml"])

    Identity.edit!(
      base,
      "default",
      :manifest,
      File.read!(manifest_path) <>
        """

        [mcp.xcodebuild]
        command = "xcodebuildmcp"
        args = ["--daemon"]
        env = { XCODEBUILD_MCP_MODE = "cli" }
        """,
      "test"
    )

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: "claude-fable-5",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db
    }

    children = Gateway.children(config)
    archetype = Archetypes.get("default")

    {:ok, overrides} =
      Archetypes.normalize_overrides(base, archetype, %{"skills_add" => ["review"]})

    identity_name = Placement.identity_name(config, archetype, overrides, :claude)
    Org.set_identity(ctx.db, "k1", overrides, identity_name)

    {_archetypes, fragments} = :persistent_term.get(Archetypes)
    :persistent_term.put(Archetypes, {%{}, fragments})
    refute Archetypes.get("default")
    assert archetype.mcp != []
    assert Archetypes.builtin_default().mcp == []

    {Tightbeam.LaneManager, lane_opts} =
      Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "ping",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "golden",
               client_message_id: "c_gold"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")

    task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)

    assert_receive {:adapter_key, {:claude, "shared", "testhost"}}

    assert_receive {:new_session_mcp_servers, []}, @cold_runner_prompt_timeout

    # Four ms behind the wait above in every sample: the forks are already paid.
    assert_receive {:prompt_started, ^adapter}, @cold_runner_prompt_timeout

    digest =
      :crypto.hash(:sha256, "k1")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    session_file = Path.join([base, "work", digest, ".tightbeam-session"])

    assert File.read!(session_file) ==
             JSON.encode!(%{
               url: "http://127.0.0.1:0",
               token: Org.get(ctx.db, "k1").cli_token,
               sessionKey: "k1"
             })

    assert Bitwise.band(File.stat!(session_file).mode, 0o777) == 0o600
    send(self(), {:push, Tightbeam.Wire.Payloads.ack("c_gold")})
    send(adapter, :continue_prompt)
    assert {:ok, %{terminal_publish: publish}} = Task.await(task)
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    publish.("delivered")

    frames = collect_pushes(10, [])

    assert Enum.map(frames, &frame_name/1) == [
             "message:user",
             "turn:accepted",
             "turn:running",
             "typing:true",
             "activity:true",
             "ack",
             "message:assistant",
             "turn:delivered",
             "typing:false",
             "activity:false"
           ]
  end

  # Install a fresh catalog for one {host, harness}, so a test can give two hosts
  # genuinely different entitlements without a provider on either end.
  defp put_host_catalog(host, harness, refs) do
    entries =
      Enum.map(refs, fn ref ->
        %{
          ref: ref,
          display_name: ref,
          name: ref,
          efforts: [],
          max_input_tokens: 200_000,
          capabilities: %{},
          provider: :anthropic
        }
      end)

    :sys.replace_state(ModelCatalog, fn state ->
      now = state.now.()

      put_in(state.entries[{host, harness}], %{
        entries: entries,
        derived_at: now,
        attempted_at: now,
        reason: nil,
        refreshing: false
      })
    end)
  end

  defp degrade_host_catalog(host, harness, reason) do
    :sys.replace_state(ModelCatalog, fn state ->
      put_in(state.entries[{host, harness}], %{
        entries: [],
        derived_at: nil,
        attempted_at: state.now.(),
        reason: reason,
        refreshing: true
      })
    end)
  end

  defp codex_models do
    JSON.encode!(%{
      models: [
        %{
          slug: "gpt-5.6-sol",
          display_name: "GPT-5.6 Sol",
          supported_reasoning_levels: [
            %{effort: "low"},
            %{effort: "medium"},
            %{effort: "high"},
            %{effort: "xhigh"},
            %{effort: "max"},
            %{effort: "ultra"}
          ]
        },
        %{
          slug: "gpt-5.6-terra",
          display_name: "GPT-5.6 Terra",
          supported_reasoning_levels: [
            %{effort: "low"},
            %{effort: "high"}
          ]
        },
        %{
          slug: "gpt-5.6-nano",
          display_name: "GPT-5.6 Nano",
          supported_reasoning_levels: [%{effort: "turbo"}]
        },
        %{
          slug: "gpt-5.6-classic",
          display_name: "GPT-5.6 Classic",
          supported_reasoning_levels: []
        }
      ]
    })
  end

  # Force every cached entry empty with a given degraded reason, keeping the
  # server's own key set (one per {host, harness}) intact.
  defp empty_catalog(reason) do
    :sys.replace_state(ModelCatalog, fn state ->
      entries =
        Map.new(state.entries, fn {key, cache} ->
          {key,
           %{
             cache
             | entries: [],
               derived_at: nil,
               attempted_at: state.now.(),
               reason: reason,
               refreshing: true
           }}
        end)

      %{state | entries: entries}
    end)
  end

  defp await_catalog(harness), do: await_host_catalog(Placement.local_host_name(), harness)

  defp await_host_catalog(host, harness, attempts \\ 100)

  defp await_host_catalog(host, harness, attempts) when attempts > 0 do
    case ModelCatalog.get(host, harness, ModelCatalog) do
      {_entries, :fresh} ->
        :ok

      _ ->
        Process.sleep(5)
        await_host_catalog(host, harness, attempts - 1)
    end
  end

  defp await_host_catalog(host, harness, 0),
    do: flunk("catalog did not become fresh: #{harness} on #{host}")

  # @cold_runner_prompt_timeout is 60_000 and ExUnit's default per-test timeout is
  # also 60_000, so the budget would be capped by the test timeout and would report
  # as "test timed out" rather than naming the wait that actually ran out. Raise the
  # ceiling above the budget it contains.
  @tag timeout: 180_000
  test "next turn after set_host delivers the advertised remote URL", ctx do
    exact_registry =
      start_supervised!(%{
        id: :remote_url_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, adapter})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "remote-url",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    base =
      Path.join(System.tmp_dir!(), "gateway_remote_url_#{System.unique_integer([:positive])}")

    File.rm_rf!(base)
    Identity.init!(base)
    manifest_path = Path.join([base, "identity", "archetypes", "default.toml"])

    manifest =
      manifest_path
      |> File.read!()
      |> String.replace(
        "name = \"default\"",
        "name = \"default\"\nwhere = [\"testhost\", \"worker\"]"
      )

    Identity.edit!(base, "default", :manifest, manifest, "test")

    old_url = Application.get_env(:tightbeam, :advertised_url)

    on_exit(fn ->
      File.rm_rf!(base)
      :persistent_term.erase(Archetypes)

      if old_url,
        do: Application.put_env(:tightbeam, :advertised_url, old_url),
        else: Application.delete_env(:tightbeam, :advertised_url)
    end)

    parent = self()

    sh = fn command ->
      if hd(command) == "rsync" do
        stage_file = Enum.at(command, -2)

        if String.contains?(stage_file, "/staging/session-files/") do
          send(parent, {:delivered_session_file, File.read!(stage_file)})
        end
      end

      {"", 0}
    end

    config =
      gateway_config(base, ctx.db, 4_321)
      |> Map.put(:sh, sh)
      |> Map.put(:sh_out, fn _ -> {"", 0} end)

    children = Gateway.children(config)

    {Tightbeam.LaneManager, lane_opts} =
      Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    Application.put_env(:tightbeam, :advertised_url, "https://new-gateway.example")

    register_hosts(ctx.db, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: nil}
    })

    assert %{ok: true, host: "worker"} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_host", host: "worker"}
             })

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "remote ping",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "d1",
               client_message_id: "c_remote_url"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")
    task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)

    token = Org.get(ctx.db, "k1").cli_token

    assert_receive {:delivered_session_file, content}

    assert JSON.decode!(content) == %{
             "url" => "https://new-gateway.example",
             "token" => token,
             "sessionKey" => "k1"
           }

    # Proven late, not lost -- see @cold_runner_prompt_timeout for the measurement.
    assert_receive {:prompt_started, ^adapter}, @cold_runner_prompt_timeout
    send(adapter, :continue_prompt)
    assert {:ok, %{terminal_publish: publish}} = Task.await(task)
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    publish.("delivered")
  end

  # @cold_runner_prompt_timeout is 60_000 and ExUnit's default per-test timeout is
  # also 60_000, so the budget would be capped by the test timeout and would report
  # as "test timed out" rather than naming the wait that actually ran out. Raise the
  # ceiling above the budget it contains.
  @tag timeout: 180_000
  test "a fallback turn appends the context-reset marker between echo and reply", ctx do
    exact_registry =
      start_supervised!(%{
        id: :marker_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "marker",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    base = gateway_children_base!()

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: "claude-fable-5",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db
    }

    children = Gateway.children(config)

    {Tightbeam.LaneManager, lane_opts} =
      Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    # A pre-existing pointer the stub adapter refuses to load → the runner
    # must fall back AND put the memory-loss line on the wire.
    Org.append_pointer(ctx.db, "k1", "stale-harness-sid", "created")

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "ping",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "marker",
               client_message_id: "c_marker"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")

    task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)
    assert_receive {:prompt_started, ^adapter}, @cold_runner_prompt_timeout
    send(adapter, :continue_prompt)
    assert {:ok, %{terminal_publish: publish}} = Task.await(task)
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    publish.("delivered")

    frames = collect_pushes(10, [])

    assert Enum.map(frames, &frame_name/1) == [
             "message:user",
             "turn:accepted",
             "turn:running",
             "typing:true",
             "activity:true",
             "message:assistant",
             "message:assistant",
             "turn:delivered",
             "typing:false",
             "activity:false"
           ]

    marker = Enum.find(frames, &(&1["type"] == "message" and &1["sender"] == "process:tightbeam"))
    assert String.starts_with?(marker["content"], "[context reset]\n")

    assert Enum.map(Org.pointer_chain(ctx.db, "k1"), & &1.reason) == ["created", "fallback"]

    assert [%{kind: "pointer_fallback", subject: "k1"}] =
             EventLog.lifecycle_events(ctx.db) |> Enum.filter(&(&1.kind == "pointer_fallback"))
  end

  test "reattach pushes the canonical record without requiring an owner read", ctx do
    exact_registry =
      start_supervised!(%{
        id: :load_apply_failure_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    adapter = start_supervised!({LoadWithoutOwnerReadAdapterStub, self()})
    start_supervised!({CoordinatorStub, adapter})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "load-apply-failure",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    base = gateway_children_base!()

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: "claude-fable-5",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db
    }

    {Tightbeam.LaneManager, lane_opts} =
      config
      |> Gateway.children()
      |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)
    Org.append_pointer(ctx.db, "k1", "load-apply-session", "created")

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "ping",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "load-apply-failure",
               client_message_id: "c_load_apply_failure"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")

    assert {:ok, %{terminal_publish: publish}} =
             runner.(Map.put(turn, :session_key, "k1"))

    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    publish.("delivered")
    assert_receive {:load_apply_residency, "load-apply-session"}
    assert_receive {:canonical_model_pushed_on_load, "load-apply-session", "fable"}
    assert_receive :load_without_owner_read_prompted
    refute_receive :unexpected_load_apply_new_session
    assert Enum.map(Org.pointer_chain(ctx.db, "k1"), & &1.reason) == ["created", "loaded"]
    refute Enum.any?(EventLog.lifecycle_events(ctx.db), &(&1.kind == "pointer_fallback"))

    refute Enum.any?(Projection.list_after(ctx.db, "k1", nil, 100), fn message ->
             String.starts_with?(message.content, "[context reset]")
           end)
  end

  test "unknown new-session paths keep and capture the harness default", ctx do
    adapter = start_supervised!({UnknownDefaultAdapterStub, self()})
    start_supervised!({CoordinatorStub, adapter})

    start_supervised!(%{
      id: :unknown_default_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    {:ok, _ref, nil} =
      ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "unknown-default",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    make_model_unknown(ctx.db, "k1")

    config = %{
      base_dir: gateway_children_base!(),
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: "claude-fable-5",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db
    }

    {Tightbeam.LaneManager, lane_opts} =
      config
      |> Gateway.children()
      |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "use the default",
               db: ctx.db,
               conn_registry: Tightbeam.ConnRegistry,
               lane_manager: ctx.lane,
               client_message_id: "c_unknown_default"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")
    assert {:ok, %{terminal_publish: publish}} = runner.(Map.put(turn, :session_key, "k1"))
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    publish.("delivered")

    assert_receive {:unknown_new_session, nil}
    assert_receive :default_model_captured
    assert_receive :default_session_prompted
    assert Org.get(ctx.db, "k1").model == "harness-default"

    # The session/load-lost fallback consumes the same unknown value: it must
    # create without seeding, then capture the new harness default too.
    make_model_unknown(ctx.db, "k1")

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "fall back to the default",
               db: ctx.db,
               conn_registry: Tightbeam.ConnRegistry,
               lane_manager: ctx.lane,
               client_message_id: "c_unknown_fallback"
             )

    assert {:ok, fallback_turn} = Ledger.claim_next(ctx.db, "k1", "test")

    assert {:ok, %{terminal_publish: fallback_publish}} =
             runner.(Map.put(fallback_turn, :session_key, "k1"))

    assert :ok = Ledger.finish(ctx.db, fallback_turn.seq, "delivered")
    fallback_publish.("delivered")

    assert_receive {:unknown_load_lost, "default-session", nil}
    assert_receive {:unknown_new_session, nil}
    assert_receive :default_model_captured
    assert_receive :default_session_prompted
    assert Org.get(ctx.db, "k1").model == "harness-default"
    assert Enum.map(Org.pointer_chain(ctx.db, "k1"), & &1.reason) == ["created", "fallback"]
  end

  test "an adjudication-routed failed turn suppresses the generic failure marker", ctx do
    exact_registry =
      start_supervised!(%{
        id: :failed_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, adapter})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "failed",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    base = gateway_children_base!()

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: "claude-fable-5",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db
    }

    children = Gateway.children(config)

    {Tightbeam.LaneManager, lane_opts} =
      Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "fail this turn",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "failed",
               client_message_id: "c_fail"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")

    assert {:error,
            %{
              reason: _,
              terminal_publish: publish,
              adjudicate_in_txn: adjudicate,
              post_commit: _post_commit
            }} =
             runner.(Map.put(turn, :session_key, "k1"))

    assert {:ok, true} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", "boom")
               adjudicate.(txn)
               true
             end)

    publish.("failed")

    frames = collect_pushes(9, [])

    refute Enum.any?(frames, fn frame ->
             frame["type"] == "message" and
               String.starts_with?(frame["content"] || "", "[turn failed]\n")
           end)

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "unclassified_harness_error" and event.subject == "k1"
           end)

    assert Enum.any?(
             frames,
             &match?(
               %{"event" => "prompt_turn_state", "payload" => %{"state" => "failed"}},
               &1
             )
           )
  end

  test "identity relearn reports a non-conflict git failure legibly", ctx do
    base_dir = role_test_base("identity-relearn-failure")
    Identity.init!(base_dir)
    live = Identity.live_revision!(base_dir)
    hook = Path.join([base_dir, "identity", ".git", "hooks", "pre-merge-commit"])

    File.write!(hook, """
    #!/bin/sh
    echo "pre-merge policy rejected relearn" >&2
    exit 1
    """)

    File.chmod!(hook, 0o755)
    relearn = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-relearn"]

    assert %{
             state: "relearn-failed",
             code: "relearn_failed",
             message: message,
             live_revision: ^live
           } =
             relearn.(%{
               origin: "user:flynn",
               params: %{}
             })

    assert message =~ "pre-merge policy rejected relearn"
  end

  test "identity apply refreshes one stamped session at a turn boundary without restarting runtime",
       ctx do
    base_dir = role_test_base("identity-apply")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    session =
      Org.create(ctx.db, %{
        session_key: "agent:identity-apply",
        display_name: "Identity apply",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        identity_name: "coder",
        identity_revision: revision,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-stable", "created")
    start_lane!(ctx.db, session.session_key)
    cwd = Placement.holder_workdir(gateway_config(base_dir, ctx.db, 0), session)
    Identity.provision_at!(base_dir, revision, "coder", :codex, cwd)
    old_body = File.read!(Path.join(cwd, ".codex/skills/tightbeam__worktree-session/SKILL.md"))

    next =
      Identity.edit!(
        base_dir,
        "coder",
        {:skill, "worktree-session", false},
        "new served skill",
        "test"
      )

    assert File.read!(Path.join(cwd, ".codex/skills/tightbeam__worktree-session/SKILL.md")) ==
             old_body

    adapter = start_supervised!({IdentityApplyAdapterStub, self()})
    runtime_pid = adapter

    start_supervised!({CoordinatorStub, {adapter, self()}})
    ensure_global_registry()

    {:ok, _ref, nil} =
      ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "identity-apply-device",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    apply = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-apply"]

    assert %{applied: [session_key], identity_revision: ^next} =
             apply.(%{
               origin: "user:flynn",
               params: %{session_key: session.session_key}
             })

    assert session_key == session.session_key
    assert_receive {:identity_apply_close, "thread-stable"}

    assert_receive {:identity_apply_load, "thread-stable", "gpt-5.6-sol[medium]", ^cwd, _mcp,
                    guidance}

    assert guidance =~ "Codex developer message"
    assert Process.alive?(runtime_pid)
    assert Org.current_pointer(ctx.db, session.session_key).harness_session_id == "thread-stable"
    assert Org.get(ctx.db, session.session_key).identity_revision == next

    assert_receive {:push,
                    %{"type" => "stream_updated", "stream" => %{"sessionKey" => ^session_key}}}

    assert File.read!(Path.join(cwd, ".codex/skills/tightbeam__worktree-session/SKILL.md")) ==
             "new served skill"

    assert {:ok, seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: session.session_key,
               message_id: "identity-apply-busy",
               origin: "user:flynn",
               prompt: "busy"
             })

    # Claimed, not merely enqueued: the boundary is a turn IN FLIGHT. This test
    # once asserted the refusal on the queued row alone, which is the conflation
    # T-CONCURRENCY names.
    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(ctx.db, session.session_key, "test")

    assert %{code: "turn_in_progress", sessions: [session_key]} =
             apply.(%{
               origin: "user:flynn",
               params: %{session_key: session.session_key}
             })

    assert session_key == session.session_key
    refute_receive {:push, %{"type" => "stream_updated"}}
  end

  # T-CONCURRENCY (PRIME INVARIANT): an org-wide operation may wait on RUNNING
  # work, never on QUEUED work. Field-proven consequence of getting this wrong:
  # a headless org's Main queues indefinitely with no client — the NORMAL state
  # per TEST-HOSTS §3a — so counting queued as busy made org-wide apply
  # permanently impossible, and the smoke manufactured its own wedge every run
  # (drain series 25/11/6/13/8/6/8) from its own bracket nags and DR notifications.
  test "identity apply proceeds with queued turns that have not started", ctx do
    base_dir = role_test_base("identity-apply-queued")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    session =
      Org.create(ctx.db, %{
        session_key: "agent:identity-apply-queued",
        display_name: "Identity apply queued",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        identity_name: "coder",
        identity_revision: revision,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    # No pointer: the queued/running question is decided before any adapter work,
    # so the never-started session isolates it from the whole harness layer.
    for n <- 1..3 do
      assert {:ok, _seq} =
               Ledger.enqueue(ctx.db, %{
                 session_key: session.session_key,
                 message_id: "identity-apply-queued-#{n}",
                 origin: "user:flynn",
                 prompt: "queued, never started"
               })
    end

    assert Ledger.pending_count(ctx.db, session.session_key) == 3
    refute Ledger.running?(ctx.db, session.session_key)

    apply = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-apply"]

    assert %{applied: [session_key], identity_revision: ^revision} =
             apply.(%{origin: "user:flynn", params: %{session_key: session.session_key}})

    assert session_key == session.session_key

    # The queued turns are untouched — apply is not a drain.
    assert Ledger.pending_count(ctx.db, session.session_key) == 3
  end

  # The other half of the same line, and the one that must NOT weaken: a turn
  # whose world is already composed still defers apply. `claim_next/3` sets
  # `status = 'running'` and `startedAt` in one UPDATE, so this is the honest
  # started-and-not-terminal discriminator.
  test "identity apply refuses while a turn is genuinely running", ctx do
    base_dir = role_test_base("identity-apply-running")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    session =
      Org.create(ctx.db, %{
        session_key: "agent:identity-apply-running",
        display_name: "Identity apply running",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        identity_name: "coder",
        identity_revision: revision,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    assert {:ok, seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: session.session_key,
               message_id: "identity-apply-running-1",
               origin: "user:flynn",
               prompt: "in flight"
             })

    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(ctx.db, session.session_key, "test")
    assert Ledger.running?(ctx.db, session.session_key)

    apply = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-apply"]

    assert %{code: "turn_in_progress", sessions: [session_key]} =
             apply.(%{origin: "user:flynn", params: %{session_key: session.session_key}})

    assert session_key == session.session_key

    # And org-wide is refused for the same reason, naming only the running session.
    assert %{code: "turn_in_progress", sessions: [^session_key]} =
             apply.(%{origin: "user:flynn", params: %{all: true}})

    # Terminalizing it releases the boundary — nothing else had to change.
    assert Ledger.finish(ctx.db, seq, "delivered") == :ok
    refute Ledger.running?(ctx.db, session.session_key)

    assert %{applied: applied, identity_revision: ^revision} =
             apply.(%{origin: "user:flynn", params: %{all: true}})

    assert session.session_key in applied
  end

  # The parity scenario, as a fixture. Measured on shrdlu 2026-07-30 13:47Z:
  # leg 1 left queued turns on ITS session, which wedged leg 2's `identity apply
  # --all` — so single-invocation two-harness parity was structurally impossible,
  # and a pre-run drain could not help because the backlog is created BETWEEN the
  # legs, inside the invocation. One session's queued work must never be another
  # session's barrier.
  test "queued turns on a bystander session do not block org-wide apply", ctx do
    base_dir = role_test_base("identity-apply-bystander")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    for {key, name} <- [{"agent:leg-one", "Leg one"}, {"agent:leg-two", "Leg two"}] do
      Org.create(ctx.db, %{
        session_key: key,
        display_name: name,
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        identity_name: "coder",
        identity_revision: revision,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })
    end

    # Leg one's own bracket nags and DR notifications, as the smoke produces them.
    for n <- 1..8 do
      assert {:ok, _seq} =
               Ledger.enqueue(ctx.db, %{
                 session_key: "agent:leg-one",
                 message_id: "bystander-#{n}",
                 origin: "process:tightbeam",
                 prompt: "nag #{n}"
               })
    end

    apply = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-apply"]

    assert %{applied: applied, identity_revision: ^revision} =
             apply.(%{origin: "user:flynn", params: %{all: true}})

    # Neither leg is refused, and leg one's OWN backlog did not exempt it either.
    assert "agent:leg-one" in applied
    assert "agent:leg-two" in applied
  end

  # TOCTOU regression, found in review of the queued/running fix. The busy check
  # and the adapter bounce are separated by adapter work, and the LANE can claim a
  # queued turn inside that window — so apply would close and reload a harness
  # session whose turn had just started, which is precisely the mid-turn identity
  # change the boundary exists to prevent (T-CONCURRENCY; served-identity §520).
  # Checking status twice cannot close this: any gateway-side sample is stale the
  # instant it is read. Ordering is decided where serialization already exists —
  # the lane's own mailbox — so apply asks the lane to perform-or-refuse.
  #
  # The old queued-counts-as-busy behavior MASKED this by rejecting the queued row
  # outright, so this window is newly reachable and gets its own adversarial test.
  test "a queued turn cannot start while apply is bouncing the session", ctx do
    base_dir = role_test_base("identity-apply-toctou")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    session =
      Org.create(ctx.db, %{
        session_key: "agent:identity-apply-toctou",
        display_name: "Identity apply toctou",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        identity_name: "coder",
        identity_revision: revision,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-toctou", "created")
    cwd = Placement.holder_workdir(gateway_config(base_dir, ctx.db, 0), session)
    Identity.provision_at!(base_dir, revision, "coder", :codex, cwd)

    next =
      Identity.edit!(
        base_dir,
        "coder",
        {:skill, "worktree-session", false},
        "identity an in-flight turn must not be switched onto",
        "test"
      )

    adapter = start_supervised!({HoldingAdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    ensure_global_registry()

    test_pid = self()

    start_lane!(ctx.db, session.session_key, fn turn ->
      send(test_pid, {:turn_started, turn.seq})
      {:ok, %{}}
    end)

    # The precondition the whole race depends on: nothing is running, so the busy
    # check passes and apply proceeds into the bounce.
    refute Ledger.running?(ctx.db, session.session_key)

    apply = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-apply"]

    applier =
      Task.async(fn ->
        apply.(%{origin: "user:flynn", params: %{session_key: session.session_key}})
      end)

    # Apply is now INSIDE the bounce, parked in close_session.
    assert_receive {:holding_close, "thread-toctou"}, 5_000

    # THE WINDOW: a turn arrives and the lane is nudged, exactly as a client post
    # or a wake delivery would do it.
    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: session.session_key,
               message_id: "toctou-1",
               origin: "user:flynn",
               prompt: "must not start under the bounce"
             })

    assert :ok = SessionLane.nudge(session.session_key)

    # THE ASSERTION: no turn starts while the session is being reloaded.
    #
    # The budget is deliberately generous and the asymmetry is the reason. While
    # the boundary holds, this message never arrives at ANY budget, so a larger
    # number cannot make the test flaky — it only costs wall time on the happy
    # path. What it buys is the regression direction: if the seam is ever removed,
    # the lane must be given enough room to claim on a loaded box, or this test
    # goes quietly green while broken. Sized for load, not fitted to the observed
    # fail-before (which fired in under 300ms on an idle machine).
    refute_receive {:turn_started, _}, 2_000

    send(adapter, :release)

    assert %{applied: [session_key], identity_revision: ^next} = Task.await(applier, 10_000)
    assert session_key == session.session_key

    # Deferred, never dropped — the nudge waited in the lane's mailbox and the turn
    # runs once the boundary is free, against the identity apply just installed.
    assert_receive {:turn_started, _}, 5_000
  end

  # The same race through the door the first fix left open: a session with NO lane.
  # "No lane exists" is a sample of a mutable fact, not a guarantee — a lane can be
  # BORN inside the window, because a delivery calls ensure_lane and the newborn
  # claims on its own init nudge. Most reachable exactly where apply matters most:
  # after a restart every started session has a pointer and no lane. Apply now
  # ensures the lane before deciding, so there is one path rather than two.
  test "a lane born during the bounce cannot claim a turn either", ctx do
    base_dir = role_test_base("identity-apply-newborn")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    session =
      Org.create(ctx.db, %{
        session_key: "agent:identity-apply-newborn",
        display_name: "Identity apply newborn",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        identity_name: "coder",
        identity_revision: revision,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-newborn", "created")
    cwd = Placement.holder_workdir(gateway_config(base_dir, ctx.db, 0), session)
    Identity.provision_at!(base_dir, revision, "coder", :codex, cwd)

    next =
      Identity.edit!(
        base_dir,
        "coder",
        {:skill, "worktree-session", false},
        "identity a newborn lane must not race",
        "test"
      )

    adapter = start_supervised!({HoldingAdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    ensure_global_registry()

    test_pid = self()

    # A REAL LaneManager, because the thing under test is lane CREATION racing the
    # bounce. Its scan interval is parked so the only lane births in this test are
    # the ones the test causes.
    task_sup =
      start_supervised!(
        {Task.Supervisor, name: :"newborn_tasks_#{System.unique_integer([:positive])}"}
      )

    lane_sup =
      start_supervised!(
        {DynamicSupervisor,
         strategy: :one_for_one, name: :"newborn_lanes_#{System.unique_integer([:positive])}"}
      )

    manager_name = :"newborn_manager_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LaneManager,
       name: manager_name,
       db: ctx.db,
       lane_sup: lane_sup,
       task_sup: task_sup,
       interval: 600_000,
       runner: fn turn ->
         send(test_pid, {:turn_started, turn.seq})
         {:ok, %{}}
       end}
    )

    # THE PRECONDITION: no lane exists for this session when apply begins.
    assert Registry.lookup(Tightbeam.LaneRegistry, session.session_key) == []

    config = Map.put(gateway_config(base_dir, ctx.db, 0), :lane_manager, manager_name)
    apply = Gateway.handlers(config)["identity-apply"]

    applier =
      Task.async(fn ->
        apply.(%{origin: "user:flynn", params: %{session_key: session.session_key}})
      end)

    assert_receive {:holding_close, "thread-newborn"}, 5_000

    # THE WINDOW: a delivery arrives — enqueue, then ensure_lane exactly as
    # complete_delivery/3 does it. On the sampled version this is what creates the
    # lane that then claims under the bounce.
    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: session.session_key,
               message_id: "newborn-1",
               origin: "user:flynn",
               prompt: "arrives while the session is being reloaded"
             })

    assert :ok = LaneManager.ensure_lane(manager_name, session.session_key)

    refute_receive {:turn_started, _}, 2_000

    send(adapter, :release)

    assert %{applied: [session_key], identity_revision: ^next} = Task.await(applier, 10_000)
    assert session_key == session.session_key

    assert_receive {:turn_started, _}, 5_000
  end

  # The cancel verb inherited GenServer.call's 5s default back when the lane only
  # ever did fast work. at_turn_boundary/2 made the lane occupiable for a whole
  # adapter bounce, so that unchosen default became a deadline: a cancel issued
  # during a bounce died of timeout instead of answering. Nothing was running, so
  # the true answer was :not_running all along — a timeout exit reads as "something
  # is broken" when the truth is "nothing was running".
  test "cancel waits for the boundary instead of timing out under it", ctx do
    base_dir = role_test_base("identity-apply-cancel-wait")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    session =
      Org.create(ctx.db, %{
        session_key: "agent:identity-apply-cancel-wait",
        display_name: "Identity apply cancel wait",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        identity_name: "coder",
        identity_revision: revision,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-cancel-wait", "created")
    cwd = Placement.holder_workdir(gateway_config(base_dir, ctx.db, 0), session)
    Identity.provision_at!(base_dir, revision, "coder", :codex, cwd)

    Identity.edit!(
      base_dir,
      "coder",
      {:skill, "worktree-session", false},
      "identity applied while a cancel waits",
      "test"
    )

    adapter = start_supervised!({HoldingAdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    ensure_global_registry()
    start_lane!(ctx.db, session.session_key)

    apply = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-apply"]

    applier =
      Task.async(fn ->
        apply.(%{origin: "user:flynn", params: %{session_key: session.session_key}})
      end)

    assert_receive {:holding_close, "thread-cancel-wait"}, 5_000

    # A cancel arrives while the lane is occupied by the bounce.
    parent = self()

    canceller =
      spawn(fn ->
        send(parent, {:cancel_result, SessionLane.cancel_current(session.session_key)})
      end)

    ref = Process.monitor(canceller)

    # The wait is the subject, not incidental: it must outlast the 5s default this
    # call used to inherit. Under that default the caller is already dead here.
    refute_receive {:DOWN, ^ref, :process, _, _}, 5_500
    refute_received {:cancel_result, _}

    send(adapter, :release)

    # The true answer, late rather than never: nothing was running.
    assert_receive {:cancel_result, :not_running}, 10_000
    assert %{applied: [_]} = Task.await(applier, 10_000)
  end

  # THE ACCEPTED RESIDUAL of ensuring the lane, documented so it is not rediscovered
  # as a bug. A lane created here self-nudges from its own `init/1` — that nudge is
  # in its mailbox before `at_turn_boundary/2` can land — so if claimable queued work
  # exists, the newborn claims it and apply defers to the turn it just caused.
  #
  # Why that is acceptable, which is the whole argument and not a caveat on it: the
  # wedge this branch removes was PERMANENT BY CONSTRUCTION — a headless org's Main
  # queues forever, nothing drains it, org-wide apply impossible for the life of the
  # org, no retry helps. This is TRANSIENT BY CONSTRUCTION — it needs an absent lane
  # AND claimable queued work, the reconciler ensures a lane for every pending session
  # each tick, and the turn we caused would have started inside that tick anyway. Those
  # are different classes, not degrees: "impossible forever" versus "try again in a
  # second". The refusal is also TRUE rather than spurious — a turn really is running
  # by the time we ask — so nothing is ever bounced mid-turn.
  #
  # Note what is NOT claimed: "no lane implies no pending work" is not an invariant.
  # A delivery commits its turn before it calls ensure_lane, so this state has a real
  # window and is reachable rather than theoretical.
  #
  # Filed separately, deliberately not fixed here: under `--all` a refusal halts the
  # whole pass (identity_apply_at_boundary's reduce_while), so one such session defers
  # the org-wide apply. Changing that is a product decision about partial results, not
  # this seam's to make.
  test "a lane ensured over queued work defers, and the retry after it succeeds", ctx do
    base_dir = role_test_base("identity-apply-residual")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    session =
      Org.create(ctx.db, %{
        session_key: "agent:identity-apply-residual",
        display_name: "Identity apply residual",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        identity_name: "coder",
        identity_revision: revision,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-residual", "created")
    cwd = Placement.holder_workdir(gateway_config(base_dir, ctx.db, 0), session)
    Identity.provision_at!(base_dir, revision, "coder", :codex, cwd)

    next =
      Identity.edit!(
        base_dir,
        "coder",
        {:skill, "worktree-session", false},
        "identity the retry must land",
        "test"
      )

    adapter = start_supervised!({IdentityApplyAdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    ensure_global_registry()

    test_pid = self()

    task_sup =
      start_supervised!(
        {Task.Supervisor, name: :"residual_tasks_#{System.unique_integer([:positive])}"}
      )

    lane_sup =
      start_supervised!(
        {DynamicSupervisor,
         strategy: :one_for_one, name: :"residual_lanes_#{System.unique_integer([:positive])}"}
      )

    manager_name = :"residual_manager_#{System.unique_integer([:positive])}"

    # The runner HOLDS the turn open, so the refusal below is a stable state rather
    # than a race the assertion has to win.
    start_supervised!(
      {LaneManager,
       name: manager_name,
       db: ctx.db,
       lane_sup: lane_sup,
       task_sup: task_sup,
       interval: 600_000,
       on_terminal: fn key, seq -> send(test_pid, {:turn_terminal, key, seq}) end,
       runner: fn turn ->
         send(test_pid, {:turn_started, turn.seq})

         receive do
           :finish_turn -> {:ok, %{}}
         end
       end}
    )

    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: session.session_key,
               message_id: "residual-1",
               origin: "user:flynn",
               prompt: "queued before any lane existed"
             })

    # THE PRECONDITION: queued work, and no lane to run it.
    assert Registry.lookup(Tightbeam.LaneRegistry, session.session_key) == []
    refute Ledger.running?(ctx.db, session.session_key)

    config = Map.put(gateway_config(base_dir, ctx.db, 0), :lane_manager, manager_name)
    apply = Gateway.handlers(config)["identity-apply"]

    assert %{code: "turn_in_progress", sessions: [session_key]} =
             apply.(%{origin: "user:flynn", params: %{session_key: session.session_key}})

    assert session_key == session.session_key

    # The refusal is TRUE, not a lie: the newborn lane really did start the turn, and
    # the stamp is untouched because nothing was bounced.
    assert_receive {:turn_started, _}, 5_000
    assert Ledger.running?(ctx.db, session.session_key)
    assert Org.get(ctx.db, session.session_key).identity_revision == revision

    # TRANSIENT: the turn terminals and the retry lands. This is the "try again in a
    # second" half, and it is what makes the trade a trade.
    Enum.each(Task.Supervisor.children(task_sup), &send(&1, :finish_turn))

    assert_receive {:turn_terminal, _, _}, 5_000
    refute Ledger.running?(ctx.db, session.session_key)

    assert %{applied: [^session_key], identity_revision: ^next} =
             apply.(%{origin: "user:flynn", params: %{session_key: session.session_key}})

    assert Org.get(ctx.db, session.session_key).identity_revision == next
  end

  # Regression: spawn creates the harness session LAZILY, so a freshly spawned session
  # has no harness pointer until its first turn. identity-apply once raised on it —
  # bricking `--all` org-wide whenever any never-started session existed (found by
  # feature_smoke: it applied to the session it had just spawned). A pointer-less
  # session is a no-op: it materializes from live at first start, already current.
  test "identity apply skips a never-started session instead of raising", ctx do
    base_dir = role_test_base("identity-apply-unstarted")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    session =
      Org.create(ctx.db, %{
        session_key: "agent:identity-apply-unstarted",
        display_name: "Identity apply unstarted",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        identity_name: "coder",
        identity_revision: revision,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    # No pointer appended: the session has never started. No adapter stub either —
    # a no-op must not touch the adapter at all.
    ensure_global_registry()

    {:ok, _ref, nil} =
      ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "identity-apply-unstarted-device",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    apply = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-apply"]

    assert %{applied: [session_key], identity_revision: ^revision} =
             apply.(%{
               origin: "user:flynn",
               params: %{session_key: session.session_key}
             })

    assert session_key == session.session_key
    assert Org.current_pointer(ctx.db, session.session_key) == nil
    refute_receive {:push, %{"type" => "stream_updated"}}
  end

  # Regression, found live on shrdlu: a pointer row outlives the adapter that
  # made it, so after ANY gateway restart EVERY started session has a pointer
  # naming a harness session no adapter holds. Apply bounced it anyway and the
  # harness answered "Session not found" as a raw JSON-RPC -32603, which the
  # verb then raised — so `identity apply --all` was broken org-wide until every
  # session happened to resume. Main always qualifies.
  test "identity apply advances the stamp of a started session the adapter no longer holds",
       ctx do
    base_dir = role_test_base("identity-apply-gone")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    session =
      Org.create(ctx.db, %{
        session_key: "agent:identity-apply-gone",
        display_name: "Identity apply gone",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        identity_name: "coder",
        identity_revision: revision,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-vanished", "created")
    start_lane!(ctx.db, session.session_key)

    next =
      Identity.edit!(
        base_dir,
        "coder",
        {:skill, "worktree-session", false},
        "guidance the restart must not lose",
        "test"
      )

    adapter = start_supervised!({GoneSessionAdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    ensure_global_registry()

    {:ok, _ref, nil} =
      ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "identity-apply-gone-device",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    apply = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-apply"]

    assert %{applied: [session_key], identity_revision: ^next} =
             apply.(%{origin: "user:flynn", params: %{session_key: session.session_key}})

    assert session_key == session.session_key
    assert_receive {:gone_residency_asked, "thread-vanished"}

    # Nothing is asked of a harness that never heard of this session.
    refute_receive {:gone_close_attempted, _}
    refute_receive {:gone_load_attempted, _}

    # THE STAMP IS THE APPLICATION here. The next start reloads from
    # `identity_revision`, not from live, so a session left behind would
    # materialize stale forever while `identity status` kept calling it stale.
    assert Org.get(ctx.db, session.session_key).identity_revision == next

    # And the pointer chain records only what happened: nothing was loaded.
    assert Org.current_pointer(ctx.db, session.session_key).harness_session_id ==
             "thread-vanished"

    assert Org.current_pointer(ctx.db, session.session_key).reason == "created"
  end

  # The condition this fix meets FIRST, not someday: deploying it restarts the
  # gateway, which stales every started session's pointer at once, so the very
  # next `identity apply --all` hits all three shapes together on a real org.
  # Single-session coverage would not have pinned that.
  test "identity apply --all handles resident, gone, and never-started sessions in one pass",
       ctx do
    base_dir = role_test_base("identity-apply-all")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    make = fn key, pointer ->
      session =
        Org.create(ctx.db, %{
          session_key: key,
          display_name: key,
          owner_user_id: "flynn",
          origin: "user:flynn",
          archetype: "coder",
          identity_name: "coder",
          identity_revision: revision,
          host: "testhost",
          harness: "codex",
          provider: "openai",
          model: "gpt-5.6-sol[medium]"
        })

      if pointer, do: Org.append_pointer(ctx.db, key, pointer, "created")
      session
    end

    resident = make.("agent:apply-all-resident", "thread-resident")
    gone = make.("agent:apply-all-gone", "thread-gone")
    start_lane!(ctx.db, "agent:apply-all-resident")
    start_lane!(ctx.db, "agent:apply-all-gone")
    unstarted = make.("agent:apply-all-unstarted", nil)

    next =
      Identity.edit!(
        base_dir,
        "coder",
        {:skill, "worktree-session", false},
        "org-wide guidance",
        "test"
      )

    adapter = start_supervised!({MixedResidencyAdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    ensure_global_registry()

    apply = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-apply"]

    assert %{applied: applied, identity_revision: ^next} =
             apply.(%{origin: "user:flynn", params: %{all: true}})

    for key <- [resident.session_key, gone.session_key, unstarted.session_key] do
      assert key in applied
    end

    # Only the resident one is bounced, and only it.
    assert_receive {:mixed_close, "thread-resident"}
    assert_receive {:mixed_load, "thread-resident"}
    refute_receive {:mixed_close, "thread-gone"}
    refute_receive {:mixed_load, "thread-gone"}

    # Both started sessions come out on the applied revision — the resident one
    # through the bounce, the gone one through its stamp.
    assert Org.get(ctx.db, resident.session_key).identity_revision == next
    assert Org.get(ctx.db, gone.session_key).identity_revision == next

    # The never-started one is left alone and does not need the stamp: it reads
    # `live` at its first start rather than its stamp, so it self-corrects. That
    # is the whole difference between it and the gone session, which reads its
    # stamp and would otherwise materialize stale forever.
    assert Org.current_pointer(ctx.db, unstarted.session_key) == nil
  end

  test "identity apply refuses by name when a live adapter fails for its own reason", ctx do
    base_dir = role_test_base("identity-apply-error")
    Identity.init!(base_dir)
    Archetypes.load!(base_dir)
    revision = Identity.live_revision!(base_dir)

    session =
      Org.create(ctx.db, %{
        session_key: "agent:identity-apply-error",
        display_name: "Identity apply error",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        identity_name: "coder",
        identity_revision: revision,
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-resident", "created")
    start_lane!(ctx.db, session.session_key)

    Identity.edit!(
      base_dir,
      "coder",
      {:skill, "worktree-session", false},
      "guidance that cannot be delivered",
      "test"
    )

    adapter = start_supervised!({ApplyErrorAdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    ensure_global_registry()

    apply = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-apply"]

    result = apply.(%{origin: "user:flynn", params: %{session_key: session.session_key}})

    # A NAMED refusal, not a raise and not a raw JSON-RPC envelope from three
    # layers down. The residency branch must not have swallowed this.
    assert %{code: "apply_failed", sessions: [session_key]} = result
    assert session_key == session.session_key
    assert result.message =~ "harness is shutting down"
    refute result.message =~ "-32000"
    assert_receive {:apply_error_close, "thread-resident"}

    # A refused apply changes nothing.
    assert Org.get(ctx.db, session.session_key).identity_revision == revision
  end

  test "credential transitions publish the captured provider-session set exactly once", ctx do
    base_dir = role_test_base("credential-emission")
    config = gateway_config(base_dir, ctx.db, 0)
    children = Gateway.children(config)

    %{start: {Credentials, :start_link, [credential_opts]}} =
      Enum.find(children, &match?(%{id: {Credentials, "testhost"}}, &1))

    first =
      Org.create(ctx.db, %{
        session_key: "agent:credential-first",
        display_name: "Credential first",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    second =
      Org.create(ctx.db, %{
        session_key: "agent:credential-second",
        display_name: "Credential second",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

    fixture_session =
      Org.create(ctx.db, %{
        session_key: "agent:credential-fixture",
        display_name: "Credential fixture",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "fixture",
        provider: "fixture_provider",
        model: "fixture-model"
      })

    Org.create(ctx.db, %{
      session_key: "agent:credential-nonmatching",
      display_name: "Credential nonmatching",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "claude-fable-5"
    })

    ensure_global_registry()

    {:ok, _ref, nil} =
      ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "credential-emission-device",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    parent = self()

    park = fn :openai ->
      Org.retire(ctx.db, first.session_key)

      Org.create(ctx.db, %{
        session_key: "agent:credential-late",
        display_name: "Credential late",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: "gpt-5.6-sol[medium]"
      })

      send(parent, :parked)
      :ok
    end

    {:ok, park_receiver} = Tightbeam.CredentialParkTestReceiver.start_link(park)

    opts =
      credential_opts
      |> Keyword.put(:name, nil)
      |> Keyword.put(:park_edge, Tightbeam.CommandEdge.request_to(park_receiver))
      |> Keyword.put(:stop, fn _provider -> :ok end)
      |> Keyword.put(:start, fn _provider, _kind -> :ok end)
      |> Keyword.put(:resume, fn _provider -> :ok end)
      |> Keyword.put(:onboarders, %{
        openai: fn _state -> {:ok, %{bytes: ~S({"token":"replacement"}), expires_at: nil}} end
      })

    {:ok, server} = Credentials.start_link(opts)

    evidence = %{"authMode" => nil, "planType" => nil}

    assert :ok = Credentials.mark_terminal(:openai, evidence, server)
    assert_receive :parked

    terminal_frames = collect_pushes(4, [])

    assert Enum.frequencies_by(terminal_frames, & &1["type"]) == %{
             "message" => 2,
             "stream_updated" => 2
           }

    assert MapSet.new(
             for %{
                   "type" => "message",
                   "role" => "user",
                   "sessionKey" => key,
                   "sender" => "process:tightbeam",
                   "content" => content
                 } <- terminal_frames,
                 content =~ "credential" and content =~ "parked pending re-onboarding",
                 do: key
           ) == MapSet.new([first.session_key, second.session_key])

    assert MapSet.new(
             for %{"type" => "stream_updated", "stream" => %{"sessionKey" => key}} <-
                   terminal_frames,
                 do: key
           ) == MapSet.new([first.session_key, second.session_key])

    assert :ok = Credentials.mark_terminal(:openai, evidence, server)
    refute_receive :parked
    refute_receive {:push, _}
    refute_receive {:push_message, _, _, _}

    assert :ok = Credentials.onboard(:openai, server)
    onboarded_frames = collect_pushes(4, [])

    assert Enum.frequencies_by(onboarded_frames, & &1["type"]) == %{
             "message" => 2,
             "stream_updated" => 2
           }

    assert MapSet.new(
             for %{
                   "type" => "message",
                   "role" => "user",
                   "sessionKey" => key,
                   "sender" => "process:tightbeam",
                   "content" => content
                 } <- onboarded_frames,
                 content =~ "re-onboarded" and content =~ "may resume",
                 do: key
           ) ==
             MapSet.new([
               second.session_key,
               "agent:credential-late"
             ])

    assert MapSet.new(
             for %{"type" => "stream_updated", "stream" => %{"sessionKey" => key}} <-
                   onboarded_frames,
                 do: key
           ) ==
             MapSet.new([
               second.session_key,
               "agent:credential-late"
             ])

    assert Org.get(ctx.db, fixture_session.session_key).provider == "fixture_provider"
  end

  test "provider onboarding starts every matching harness and aggregates runtime failures",
       ctx do
    base_dir = role_test_base("credential-runtime-aggregate")
    config = gateway_config(base_dir, ctx.db, 0)
    children = Gateway.children(config)

    %{start: {Credentials, :start_link, [credential_opts]}} =
      Enum.find(children, &match?(%{id: {Credentials, "testhost"}}, &1))

    parent = self()

    start_result = fn
      {:codex, "shared", "testhost"} = key ->
        send(parent, {:runtime_start, key})
        {:error, :codex_failed}

      {:fixture, "shared", "testhost"} = key ->
        send(parent, {:runtime_start, key})
        {:ok, parent, 1}
    end

    start_supervised!({CoordinatorStub, start_result})

    opts =
      credential_opts
      |> Keyword.put(:name, nil)
      |> Keyword.put(:stop, fn _provider -> :ok end)
      |> Keyword.put(:resume, fn _provider -> :ok end)
      |> Keyword.put(:onboarders, %{
        openai: fn _state -> {:ok, %{bytes: ~S({"token":"replacement"}), expires_at: nil}} end
      })

    {:ok, server} = Credentials.start_link(opts)

    assert {:error,
            {:provider_runtime_start_failed,
             %{
               started: [],
               failed: [%{harness: "codex", reason: :codex_failed}]
             }}} = Credentials.onboard(:openai, server)

    assert_receive {:runtime_start, {:codex, "shared", "testhost"}}
    refute_receive {:runtime_start, {:fixture, "shared", "testhost"}}
    refute Credentials.status(:openai, server) == :onboarded

    fixture_opts =
      credential_opts
      |> Keyword.put(:name, nil)
      |> Keyword.put(:stop, fn _provider -> :ok end)
      |> Keyword.put(:resume, fn _provider -> :ok end)
      |> Keyword.put(:onboarders, %{
        fixture_provider: fn _state ->
          {:ok, %{bytes: "fixture-provider-credential", expires_at: nil}}
        end
      })

    {:ok, fixture_server} = Credentials.start_link(fixture_opts)
    assert :ok = Credentials.onboard(:fixture_provider, fixture_server)
    assert_receive {:runtime_start, {:fixture, "shared", "testhost"}}
  end

  # Driven through real spawns rather than hand-built session maps: the point of
  # the assertion is that the classes the CREATION paths actually stamp are the
  # ones the wire can name, and a fabricated origin proves nothing about that.
  test "startedBy names who started each session the spawn path can create", ctx do
    base_dir = role_test_base("started-by")
    Archetypes.load!(base_dir)
    ensure_global_registry()

    spawn = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["spawn"]

    typed =
      spawn.(%{
        origin: "user:flynn",
        session_key: nil,
        params: %{display_name: "Typed", handle: "typed", idempotency_key: "sb-user"}
      })

    hired =
      spawn.(%{
        origin: "agent:typed",
        session_key: nil,
        params: %{display_name: "Hired", idempotency_key: "sb-agent"}
      })

    # The remedy class never comes off a transport — the rail remedy executor is
    # its only constructor — so it is admitted here by principal, as it is live.
    remedied =
      spawn.(%{
        origin: "remedy:review-before-merge",
        principal: {:remedy, %{action: "spawn", owner: "flynn"}},
        session_key: nil,
        params: %{display_name: "Remedied", idempotency_key: "sb-remedy"}
      })

    for {result, origin, started_by} <- [
          {typed, "user:flynn", "user"},
          {hired, "agent:typed", "agent"},
          {remedied, "remedy:review-before-merge", "substrate"}
        ] do
      stream = ctx.db |> Org.get(result.session_key) |> Payloads.stream_session()

      assert stream["startedBy"] == started_by, inspect(stream)
      assert stream["origin"] == origin, "origin stays as the detailed provenance"
    end
  end

  test "tune adopt writes the flag, unadopt clears it, and each pushes stream_updated", ctx do
    base_dir = role_test_base("adopt")
    Archetypes.load!(base_dir)
    ensure_global_registry()

    {:ok, _ref, nil} =
      ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "adopt-device",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    tune = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["tune"]
    key = "k1"

    refute Org.get(ctx.db, key).adopted

    assert %{ok: true} =
             tune.(%{
               origin: "user:flynn",
               session_key: key,
               params: %{setting: "adopt", adopted: true}
             })

    assert Org.get(ctx.db, key).adopted

    assert_receive {:push,
                    %{
                      "type" => "stream_updated",
                      "stream" => %{"sessionKey" => ^key, "adopted" => true}
                    }}

    assert %{ok: true} =
             tune.(%{
               origin: "user:flynn",
               session_key: key,
               params: %{setting: "adopt", adopted: false}
             })

    refute Org.get(ctx.db, key).adopted

    assert_receive {:push,
                    %{
                      "type" => "stream_updated",
                      "stream" => %{"sessionKey" => ^key, "adopted" => false}
                    }}
  end

  defp gateway_config(base_dir, db, port) do
    %{
      base_dir: base_dir,
      cwd: "/tmp",
      port: port,
      default_harness: :claude,
      default_model: "claude-fable-5",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: db,
      credential_status: fn _provider -> :onboarded end,
      credential_kind: fn _provider -> :subscription end,
      patch_adapter: fn _harness, _path -> :ok end
    }
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

  defp notify_adjudication(db, session_key, expected_owner) do
    {:ok, episode} =
      DB.transaction(db, fn txn ->
        existing = Adjudication.get_in_txn(txn, session_key, "other")

        episode =
          case existing do
            nil ->
              Adjudication.claim_in_txn(txn, session_key, "other", claim_window_ms: 300_000)

            %{status: "resolved"} ->
              Adjudication.reopen_in_txn(txn, session_key, "other", claim_window_ms: 300_000)
          end

        assert {:ok, _wake_id, ^expected_owner} =
                 Adjudication.notify_in_txn(txn, episode, "adjudicate", 86_400_000)

        Adjudication.get_in_txn(txn, session_key, "other")
      end)

    episode
  end

  defp gateway_children_base! do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    base = Path.join(System.tmp_dir!(), "gateway_children_#{suffix}")
    File.rm_rf!(base)
    File.mkdir!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    base
  end

  defp role_test_base(suffix, ready? \\ true) do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "gateway_roles_#{suffix}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(base_dir)
    File.mkdir_p!(base_dir)

    # Adapters are infrastructure, not the readiness variable under test: spinup
    # checks the adapter BEFORE credentials, so a test asking for a credentials
    # denial needs the adapter present regardless. These used to be satisfied by a
    # sibling checkout that happened to exist on the developer's machine (#46).
    for bin <- ["claude-agent-acp", "codex-acp"] do
      adapter = Path.join([base_dir, "adapters", "node_modules", ".bin", bin])
      File.mkdir_p!(Path.dirname(adapter))
      File.write!(adapter, "#!/bin/sh\nexit 0\n")
      File.chmod!(adapter, 0o755)
    end

    if ready? do
      auth_dir = Path.join([base_dir, "auth", "claude"])
      File.mkdir_p!(auth_dir)
      File.write!(Path.join(auth_dir, "oauth-token"), "test-token")
    end

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Archetypes)
    end)

    base_dir
  end

  defp create_session(db, session_key, owner_user_id, spawned_by \\ nil) do
    Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: owner_user_id,
      origin: "user:#{owner_user_id}",
      spawned_by: spawned_by,
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })
  end

  defp create_work_item(db, title) do
    WorkItems.__handle__(db, "work-item-create", %{
      verb: "work-item-create",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{title: title}
    })
  end

  # A REAL lane for a session, because identity apply now decides its boundary in
  # the lane's mailbox: a session without one cannot be applied to at all. The
  # default runner is inert — these lanes exist to own a boundary, not to work.
  defp start_lane!(db, session_key, runner \\ fn _turn -> {:ok, %{}} end) do
    task_sup =
      start_supervised!(
        {Task.Supervisor, name: :"lane_tasks_#{System.unique_integer([:positive])}"}
      )

    start_supervised!(%{
      id: {:lane, session_key},
      start:
        {SessionLane, :start_link,
         [[session_key: session_key, db: db, task_sup: task_sup, runner: runner]]}
    })
  end

  defp ensure_global_registry do
    case ConnRegistry.start_link(name: Tightbeam.ConnRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp credential_probe(parent, command) do
    send(parent, {:credential_command, command})
    {"", 1}
  end

  defp move_test_base(db, suffix, remote_host \\ "worker") do
    base_dir =
      Path.join(System.tmp_dir!(), "gateway_move_#{suffix}_#{System.unique_integer([:positive])}")

    File.rm_rf!(base_dir)
    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)

    File.write!(
      Path.join(manifests, "default.toml"),
      "name = \"default\"\nwhere = [\"testhost\", \"#{remote_host}\"]\n"
    )

    Archetypes.load!(base_dir)
    on_exit(fn -> :persistent_term.erase(Archetypes) end)

    register_hosts(db, %{
      remote_host => %{ssh: remote_host, base_dir: "/remote/tb", cli_bin: nil}
    })

    base_dir
  end

  defp test_workdir(base_dir, session_key) do
    digest =
      :crypto.hash(:sha256, session_key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    Path.join([base_dir, "work", digest])
  end

  # `SessionLane.init/1` ends `send(self(), :nudge)` and returns, so
  # `start_supervised!` hands back a lane that has NOT yet claimed its turn.
  # The nudge sits ahead of this call in the lane's own mailbox, so a reply
  # here proves the claim ran and the runner task was spawned — collapsing
  # four unbarriered hops (supervisor start, lane init, sqlite claim, task
  # spawn) that a bare assert_receive would otherwise be timing.
  #
  # It does NOT prove the runner has RUN: the runner body executes in the
  # task process, so the send we then wait for is still one scheduling hop
  # away. That last hop is why the assert_receive stays. Measured under a
  # 5-lane load (load average ~90): 0-106ms against the 1000ms default.
  defp barrier_lane_started(lane), do: :sys.get_state(lane)

  defp collect_pushes(0, acc), do: Enum.reverse(acc)

  defp collect_pushes(n, acc) do
    receive do
      {:push, payload} -> collect_pushes(n - 1, [payload | acc])
      {:push_message, _key, _seq, payload} -> collect_pushes(n - 1, [payload | acc])
      {:ensure_lane, _key} -> collect_pushes(n, acc)
    after
      1_000 -> flunk("timed out collecting golden frames")
    end
  end

  defp frame_name(%{"type" => "message", "role" => role}), do: "message:#{role}"

  defp frame_name(%{
         "type" => "event",
         "event" => "prompt_turn_state",
         "payload" => %{"state" => state}
       }),
       do: "turn:#{state}"

  defp frame_name(%{"type" => "typing", "active" => active}), do: "typing:#{active}"

  defp frame_name(%{
         "type" => "event",
         "event" => "activity",
         "payload" => %{"isActive" => active}
       }),
       do: "activity:#{active}"

  defp frame_name(%{"type" => "ack"}), do: "ack"

  defp put_skill!(base_dir, name, body) do
    Identity.init!(base_dir)
    Identity.edit!(base_dir, "default", {:skill, name, false}, body, "test")
    Archetypes.load!(base_dir)
  end
end
