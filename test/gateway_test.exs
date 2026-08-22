defmodule Tightbeam.GatewayTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

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

  @archetype_reference_writers [
    {:main_session_seed, "lib/tightbeam/wire/socket.ex", "Org.create_in_txn"},
    {:typed_spawn, "lib/tightbeam/gateway.ex", "Org.create_in_txn"},
    {:default_setting, "lib/tightbeam/gateway.ex", "Org.put_setting_in_txn"},
    {:identity_repoint, "lib/tightbeam/gateway.ex", "Org.repoint_archetype_in_txn"}
  ]

  import ExUnit.CaptureLog

  alias Tightbeam.{
    Archetypes,
    Artifacts,
    Assignments,
    ConnRegistry,
    Credentials,
    DB,
    Devices,
    Dispatch,
    EventLog,
    EffortCheckin,
    Gateway,
    HarnessHealth,
    Identity,
    Idempotency,
    LaneManager,
    Ledger,
    ModelCatalog,
    NoticeBatcher,
    Org,
    Placement,
    Projection,
    Rails,
    Roles,
    Rules,
    SessionLane,
    Wakes,
    WorkItems
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
      {:reply, [%{launch_id: "launch-1", state: "kill_failed"}], state}
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

    def handle_call({:new_candidate_session, model, cwd, mcp_servers, guidance}, from, parent),
      do: handle_call({:new_session, model, cwd, mcp_servers, guidance}, from, parent)

    def handle_call(
          {:new_session, model, cwd, mcp_servers, guidance, _request_timeout},
          from,
          parent
        ),
        do: handle_call({:new_session, model, cwd, mcp_servers, guidance}, from, parent)

    def handle_call(:conn, _from, parent), do: {:reply, parent, parent}

    def handle_call({:knows_session?, _sid}, _from, parent), do: {:reply, false, parent}

    def handle_call({:current_model, "harness-1"}, _from, parent),
      do: {:reply, {:ok, Model.new("gpt-5.6-sol", effort: "medium")}, parent}

    def handle_call({:load_session, _sid, _model, _cwd, _mcp_servers, _guidance}, _from, parent),
      do: {:reply, {:error, %{"code" => -32602, "message" => "Invalid params"}}, parent}

    def handle_call(
          {:load_session, sid, model, cwd, mcp_servers, guidance, _request_timeout},
          from,
          parent
        ),
        do: handle_call({:load_session, sid, model, cwd, mcp_servers, guidance}, from, parent)

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

      messages =
        case prompt do
          "split assistant messages" ->
            [
              %{message_id: "fake-message-1", text: "FIRST"},
              %{message_id: "fake-message-2", text: "SECOND"}
            ]

          _ ->
            [%{message_id: "fake-message", text: String.upcase(prompt)}]
        end

      receive do: (:continue_prompt ->
                     GenServer.reply(
                       from,
                       {:ok,
                        %{
                          text: Enum.map_join(messages, & &1.text),
                          messages: messages,
                          stop_reason: "end_turn"
                        }}
                     ))

      {:noreply, parent}
    end
  end

  defmodule CandidateAdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, {parent, %{}})
    def init(state), do: {:ok, state}

    def handle_call({:new_session, model, _cwd, _mcp, guidance}, _from, {parent, models}) do
      sid = "candidate-#{map_size(models) + 1}"
      send(parent, {:candidate_created, sid, model})
      send(parent, {:candidate_guidance, sid, guidance})
      {:reply, {:ok, sid}, {parent, Map.put(models, sid, model)}}
    end

    def handle_call({:new_candidate_session, model, cwd, mcp, guidance}, from, state),
      do: handle_call({:new_session, model, cwd, mcp, guidance}, from, state)

    def handle_call({:current_model, sid}, _from, {_parent, models} = state),
      do: {:reply, Map.fetch(models, sid), state}

    def handle_call({:knows_session?, sid}, _from, {_parent, models} = state),
      do: {:reply, Map.has_key?(models, sid), state}

    def handle_call({:fast_status, _sid}, _from, state),
      do: {:reply, {:error, :fast_unsupported}, state}

    def handle_call({:close_session, sid}, _from, {parent, models}) do
      send(parent, {:candidate_closed, sid})
      {:reply, :ok, {parent, Map.delete(models, sid)}}
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

    def handle_call({:current_model, _sid}, _from, {_parent, opts} = state),
      do: {:reply, {:ok, Keyword.get(opts, :current_model, Model.new("fable"))}, state}

    def handle_call({:close_session, sid}, _from, {parent, _opts} = state) do
      send(parent, {:tune_session_closed, sid})
      {:reply, :ok, state}
    end

    def handle_call({:fast_status, _sid}, _from, state),
      do: {:reply, {:error, :fast_unsupported}, state}

    def handle_call(
          {:switch_model_session, sid, model, cwd, mcp_servers, guidance},
          _from,
          {parent, opts} = state
        ) do
      send(parent, {:tune_session_switched, sid, model, cwd, mcp_servers, guidance})

      result =
        Keyword.get_lazy(opts, :switch_result, fn ->
          {:ok, Keyword.get(opts, :switched_sid, "switched-session")}
        end)

      {:reply, result, state}
    end

    def handle_call(
          {:load_session, sid, model, cwd, mcp_servers, guidance},
          _from,
          {parent, opts} = state
        ) do
      send(parent, {:tune_session_loaded, sid, model, cwd, mcp_servers, guidance})
      {:reply, Keyword.get(opts, :load_result, {:ok, model}), state}
    end
  end

  defmodule FastTuneAdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, {parent, "off"})
    def init(state), do: {:ok, state}

    def handle_call({:knows_session?, _sid}, _from, state), do: {:reply, true, state}

    def handle_call({:fast_status, _sid}, _from, {_parent, fast} = state),
      do: {:reply, {:ok, %{fast: fast, option_id: "fast"}}, state}

    def handle_call({:current_model, _sid}, _from, state),
      do: {:reply, {:ok, Model.new("fable")}, state}

    def handle_call({:apply_fast, sid, requested}, _from, {parent, _fast}) do
      send(parent, {:fast_applied, sid, requested})
      {:reply, {:ok, %{fast: requested, option_id: "fast"}}, {parent, requested}}
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

    def handle_call(
          {:load_session, sid, model, cwd, mcp, guidance, _request_timeout},
          from,
          parent
        ),
        do: handle_call({:load_session, sid, model, cwd, mcp, guidance}, from, parent)

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

    def handle_call(
          {:new_session, model, cwd, mcp, guidance, _request_timeout},
          from,
          parent
        ),
        do: handle_call({:new_session, model, cwd, mcp, guidance}, from, parent)

    def handle_call({:knows_session?, _sid}, _from, parent), do: {:reply, false, parent}

    def handle_call({:load_session, sid, model, _cwd, _mcp, _guidance}, _from, parent) do
      send(parent, {:unknown_load_lost, sid, model})
      {:reply, {:error, :session_lost}, parent}
    end

    def handle_call(
          {:load_session, sid, model, cwd, mcp, guidance, _request_timeout},
          from,
          parent
        ),
        do: handle_call({:load_session, sid, model, cwd, mcp, guidance}, from, parent)

    def handle_call({:current_model, "default-session"}, _from, parent) do
      send(parent, :default_model_captured)
      {:reply, {:ok, Model.new("harness-default")}, parent}
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
    :ok = Tightbeam.Schema.ensure_all(db)
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

    File.write!(
      Path.join([catalog_base, "auth", "claude", ".credentials.json"]),
      ~s({"claudeAiOauth":{"accessToken":"test-token"}})
    )

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

    {:paired, device} =
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
      model: Model.new("fable")
    })

    {:ok, _ref, nil} =
      ConnRegistry.register(registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "d1",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    %{db: db, registry: registry, lane: lane, catalog_base: catalog_base, device: device}
  end

  test "assignment handlers inject configured supervision and effort settings before mutation",
       ctx do
    ensure_global_registry()
    base_dir = role_test_base("gateway-supervision-interval")

    register_hosts(ctx.db, %{
      "testhost" => %{ssh: "testhost", base_dir: base_dir, cli_bin: nil}
    })

    handlers =
      Gateway.handlers(
        gateway_config(base_dir, ctx.db, 0)
        |> Map.put(:wake_tick_ms, 1_234)
        |> Map.put(:effort_checkin_horizon_ms, 123)
      )

    common = %{
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: "k1",
      target_role: nil,
      role_fallback: false
    }

    assert %{id: assign_id} =
             handlers["assign"].(
               Map.merge(common, %{
                 verb: "assign",
                 params: %{subject: "gateway interval assign"}
               })
             )

    assert %{id: dispatch_id} =
             handlers["dispatch"].(
               Map.merge(common, %{
                 verb: "dispatch",
                 params: %{
                   subject: "gateway interval dispatch",
                   brief: "prove the configured interval"
                 }
               })
             )

    assert {:ok, [[123, effort_root]]} =
             DB.query(
               ctx.db,
               "SELECT baseHorizonMs,root FROM effort_checkin_generations WHERE assignmentId=?1",
               [assign_id]
             )

    assert Path.dirname(effort_root) == Path.join(base_dir, "work")

    for assignment_id <- [assign_id, dispatch_id] do
      assert {:ok, [[1_234, 1_234]]} =
               DB.query(
                 ctx.db,
                 """
                 SELECT e.dueAt - a.openedAt, e.supervisionIntervalMs
                 FROM assignments a
                 JOIN supervision_entitlements e ON e.assignmentId=a.id
                 WHERE a.id=?1
                 """,
                 [assignment_id]
               )
    end
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
      model: Model.new("fable")
    })

    handlers =
      Gateway.handlers(%{
        db: ctx.db,
        base_dir: System.tmp_dir!(),
        default_harness: :claude,
        default_model: Model.new("claude-fable-5"),
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

  test "admin operator handler lists durable harness launches", ctx do
    adapter = start_supervised!({AdapterStub, self()})
    coordinator = start_supervised!({CoordinatorStub, {adapter, self()}})
    handlers = Gateway.handlers(%{db: ctx.db, adapter_coordinator: coordinator})
    call = %{origin: "user:flynn", session_key: nil, params: %{}}

    assert %{harness_processes: [%{launch_id: "launch-1", state: "kill_failed"}]} =
             handlers["harness-processes"].(call)

    assert_receive :harness_processes
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
        wake_tick_ms: 1_000,
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
    Org.retire(ctx.db, "k1", "test:gateway", 1_000)
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
      Gateway.handlers(%{
        db: ctx.db,
        wake_tick_ms: 1_000,
        adapter_coordinator: coordinator
      })["retire"].(%{
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
      Gateway.handlers(%{db: ctx.db, base_dir: base_dir, wake_tick_ms: 1_000})["retire"].(%{
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
      Gateway.handlers(%{
        db: ctx.db,
        wake_tick_ms: 1_000,
        adapter_coordinator: coordinator
      })["retire"].(%{
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
    Org.retire(ctx.db, "k1", "test:gateway", 1_000)
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
      Gateway.handlers(%{
        db: ctx.db,
        wake_tick_ms: 1_000,
        adapter_coordinator: coordinator
      })["retire"].(%{
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

    handlers =
      Gateway.handlers(%{
        db: ctx.db,
        wake_tick_ms: 1_000,
        critical_lease_hard_cap_ms: 2_000
      })

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

  test "children recovers liveness before any runtime child can start", ctx do
    :ok =
      DB.execute(
        ctx.db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) VALUES ('asg_boot_recovery', 'boot recovery', 'k1', 'flynn', 1)"
      )

    children =
      Gateway.children(
        gateway_config(gateway_children_base!(), ctx.db, 0)
        |> Map.put(:wake_tick_ms, 1_234)
      )

    assert {:ok,
            [
              [
                1,
                "armed",
                "recovery_backfill",
                "asg_boot_recovery",
                "recovery_backfill",
                "process:tightbeam",
                1_234
              ]
            ]} =
             DB.query(
               ctx.db,
               """
               SELECT generation,state,basisKind,basisId,cause,principal,supervisionIntervalMs
               FROM supervision_entitlements
               WHERE assignmentId='asg_boot_recovery'
               """
             )

    {Tightbeam.Supervision, supervision_opts} =
      Enum.find(children, &match?({Tightbeam.Supervision, _}, &1))

    assert Keyword.fetch!(supervision_opts, :recover) == false
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

    assert %{harness: "claude", provider: "anthropic", model: %Model{family: "claude-fable-5"}} =
             Org.get(ctx.db, Org.personal_session_key(device.user_id))
  end

  # Both spellings of the routability question reach the running catalog: the
  # fleet one that the catalog asks, and the per-harness one that validation and
  # boot ask. Written against the DEFAULT server, because that is the whole
  # difference between them and a spelling that raises instead of routing is not
  # an API at all.
  test "route answers the fleet and one harness alike, against the running catalog", _ctx do
    put_host_catalog("testhost", "claude", [{"tiered-here", ["low", "high"]}])

    assert {:ok, %{harness: "claude", provider: "anthropic"}} =
             ModelCatalog.route("testhost", Model.new("tiered-here", effort: "high"))

    assert {:ok, %{harness: "claude"}} =
             ModelCatalog.route("testhost", "claude", Model.new("tiered-here", effort: "high"))

    assert {:error, %Tightbeam.Unroutable{cause: :needs_effort}} =
             ModelCatalog.route("testhost", "claude", Model.new("tiered-here"))
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

    assert message =~ ~s("claude-opus-5" is not offered by claude on host testhost)

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

  test "children installs the CLI from the RELEASE layout when there is no source tree", ctx do
    # The release-install defect both first-install agents found within minutes
    # of each other (macOS and linux, 2026-08-04): the seeding knew only
    # cli/target/release, so every npm install got a bin/tightbeam telling a
    # toolchain-free customer to run cargo. In a release, the compiled CLI is
    # the npm package's own bin — a sibling of RELEASE_ROOT.
    pkg_dir =
      Path.join(System.tmp_dir!(), "gateway_release_cli_#{System.unique_integer([:positive])}")

    release_root = Path.join(pkg_dir, "release")
    File.mkdir_p!(Path.join(pkg_dir, "bin"))
    File.mkdir_p!(release_root)
    File.write!(Path.join(pkg_dir, "bin/tightbeam"), "release-cli-binary")

    # cwd deliberately holds NO cli/target — a customer box has no source tree.
    cwd = Path.join(pkg_dir, "cwd")
    File.mkdir_p!(cwd)
    base = Path.join(pkg_dir, "base")

    previous = System.get_env("RELEASE_ROOT")
    System.put_env("RELEASE_ROOT", release_root)

    on_exit(fn ->
      if previous,
        do: System.put_env("RELEASE_ROOT", previous),
        else: System.delete_env("RELEASE_ROOT")

      File.rm_rf!(pkg_dir)
    end)

    File.cd!(cwd, fn ->
      Gateway.children(gateway_config(base, ctx.db, 0))
      installed = Path.join(base, "bin/tightbeam")
      assert File.read!(installed) == "release-cli-binary"
      assert File.stat!(installed).mode |> Bitwise.band(0o777) == 0o755
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

    assert_raise RuntimeError, ~r/no registered harness CLI is installed/, fn ->
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

    handlers = Gateway.handlers(gateway_config("/tmp", ctx.db, 0))
    Rules.load!(System.tmp_dir!(), Map.keys(handlers))

    assert {:ok, %{canceled: true}} =
             Dispatch.dispatch(ctx.db, handlers, %{
               verb: "wake",
               origin: "process:scheduler",
               principal: {:process, "scheduler"},
               session_key: nil,
               params: %{cancel_wake_id: own.wake_id}
             })

    assert {:ok, [[event_id, causal_source_id]]} =
             DB.query(
               ctx.db,
               """
               SELECT e.id, c.causalSourceId
               FROM events e
               JOIN wake_cancellations c ON c.causalSourceId=CAST(e.id AS TEXT)
               WHERE c.wakeId=?1 AND e.kind='verb' AND e.verb='wake'
               """,
               [own.wake_id]
             )

    assert causal_source_id == Integer.to_string(event_id)

    assert {:ok, %{canceled: false}} =
             Dispatch.dispatch(ctx.db, handlers, %{
               verb: "wake",
               origin: "process:scheduler",
               principal: {:process, "scheduler"},
               session_key: nil,
               params: %{cancel_wake_id: other.wake_id}
             })

    assert Wakes.get(ctx.db, own.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, other.wake_id).state == "pending"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1",
               [other.wake_id]
             )
  end

  test "public cancel rolls its accepted event and carrier back with the wake transition", ctx do
    wake =
      Wakes.schedule(ctx.db, %{
        session_key: "k1",
        origin: "process:scheduler",
        prompt: "rollback wake",
        due_at: 1_000
      })

    :ok =
      DB.execute(
        ctx.db,
        """
        CREATE TRIGGER force_gateway_cancel_rollback
        BEFORE UPDATE OF state ON wakes
        WHEN OLD.wakeId='#{wake.wake_id}' AND NEW.state='canceled'
        BEGIN
          SELECT RAISE(ABORT, 'forced gateway cancellation rollback');
        END;
        """
      )

    handlers = Gateway.handlers(gateway_config("/tmp", ctx.db, 0))
    Rules.load!(System.tmp_dir!(), Map.keys(handlers))

    assert {:error, %{code: "server_error", message: message}} =
             Dispatch.dispatch(ctx.db, handlers, %{
               verb: "wake",
               origin: "process:scheduler",
               principal: {:process, "scheduler"},
               session_key: nil,
               params: %{cancel_wake_id: wake.wake_id}
             })

    assert message =~ "forced gateway cancellation rollback"

    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               """
               SELECT COUNT(*) FROM events
               WHERE verb='wake' AND json_valid(payload)
                 AND json_extract(payload, '$.canceled')=1
               """,
               []
             )
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

  test "removed role makes a notice batch terminally fail instead of claiming delivery", ctx do
    base_dir = role_test_base("batched-role-removal")
    config = gateway_config(base_dir, ctx.db, 0)
    {Wakes, wake_opts} = Gateway.children(config) |> Enum.find(&match?({Wakes, _}, &1))
    scheduler = :"batched_role_wakes_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: :batched_role_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    start_supervised!({Wakes, Keyword.put(wake_opts, :name, scheduler)})

    recipient = create_session(ctx.db, "agent:batch-recipient", "flynn")
    Roles.create!(ctx.db, "batch-recipient", "flynn", recipient.session_key)

    {:ok, _policy} =
      DB.transaction(ctx.db, fn txn ->
        Org.apply_notice_batching_lane_policy_in_txn(
          txn,
          %{session_key: recipient.session_key, target_role: "batch-recipient"},
          true,
          "notice-batching-test-policy:role-removal",
          "agent:test-policy",
          "role-removal-regression",
          1
        )
      end)

    source =
      Wakes.schedule(ctx.db, %{
        session_key: recipient.session_key,
        target_role: "batch-recipient",
        origin: "process:tightbeam",
        prompt: "batched role delivery",
        due_at: 0,
        class: "fyi"
      })

    [carrier_id] = Wakes.materialize_digests(ctx.db, source.due_at)
    [%{batch_id: batch_id}] = NoticeBatcher.source_refs(ctx.db, source.wake_id)
    assert :ok = Roles.rm(ctx.db, "batch-recipient")
    {:ok, _} = DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [carrier_id])

    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(ctx.db, carrier_id).state == "fired"

    assert %{state: "delivery_failed", terminal_cause: ":skipped"} =
             NoticeBatcher.batch(ctx.db, batch_id)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [carrier_id])
  end

  test "inspect exposes batch refs and denies a batch when any source is unauthorized", ctx do
    base_dir = role_test_base("notice-batch-inspect")
    Archetypes.load!(base_dir)
    other = create_session(ctx.db, "agent:batch-other-owner", "tron")

    {:ok, _policy} =
      DB.transaction(ctx.db, fn txn ->
        Org.apply_notice_batching_lane_policy_in_txn(
          txn,
          %{session_key: "k1", target_role: nil},
          true,
          "notice-batching-test-policy:inspect",
          "agent:test-policy",
          "inspect-authorization-regression",
          1
        )
      end)

    first =
      Wakes.schedule(ctx.db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        prompt: "first authorized member",
        due_at: 0,
        class: "fyi"
      })

    second =
      Wakes.schedule(ctx.db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        prompt: "second authorized member",
        due_at: 0,
        class: "fyi"
      })

    [%{batch_id: batch_id}] = NoticeBatcher.source_refs(ctx.db, first.wake_id)
    inspect = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["inspect"]

    readable =
      inspect.(%{
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        params: %{batch_id: batch_id}
      })

    assert %{member_count: 2, members: members} = readable.batch
    assert Enum.map(members, & &1.source_wake_id) == [first.wake_id, second.wake_id]

    assert %{batch_refs: [%{batch_id: ^batch_id}]} =
             Enum.find(readable.wakes, &(&1.wake_id == first.wake_id))

    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET sessionKey=?2 WHERE wakeId=?1", [
        second.wake_id,
        other.session_key
      ])

    denied =
      inspect.(%{
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        params: %{batch_id: batch_id}
      })

    assert denied.batch == nil
    assert Enum.any?(denied.wakes, &(&1.wake_id == first.wake_id))
    refute Enum.any?(denied.wakes, &(&1.wake_id == second.wake_id))
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
    assert Org.get(ctx.db, key).model == Model.new("claude-fable-5")

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

  test "spawn has no session-count gate when the cap is unset", ctx do
    base_dir = role_test_base("spawn-unlimited")
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :spawn_unlimited_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    for index <- 1..50 do
      Org.create(ctx.db, %{
        session_key: "agent:existing-#{index}",
        display_name: "Existing #{index}",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("claude-fable-5")
      })
    end

    spawn =
      base_dir
      |> gateway_config(ctx.db, 0)
      |> Map.delete(:max_live_sessions_per_user)
      |> Gateway.handlers()
      |> Map.fetch!("spawn")

    assert %{session_key: session_key} =
             spawn.(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Fifty-first worker",
                 idempotency_key: "spawn-unlimited"
               }
             })

    assert Org.get(ctx.db, session_key).state == "active"
  end

  test "spawn enforces an explicit positive session cap", ctx do
    base_dir = role_test_base("spawn-capped")
    Archetypes.load!(base_dir)

    spawn =
      base_dir
      |> gateway_config(ctx.db, 0)
      |> Map.put(:max_live_sessions_per_user, 1)
      |> Gateway.handlers()
      |> Map.fetch!("spawn")

    assert %{code: "cap_exceeded", message: message} =
             spawn.(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Over cap",
                 idempotency_key: "spawn-capped"
               }
             })

    assert message =~ "live-session cap (1) reached for flynn"
    assert Idempotency.get(ctx.db, "flynn", "spawn", "spawn-capped") == nil
  end

  test "concurrent spawns cannot exceed an explicit positive session cap", ctx do
    parent = self()
    base_dir = role_test_base("spawn-cap-race")
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :spawn_cap_race_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    spawn =
      base_dir
      |> gateway_config(ctx.db, 0)
      |> Map.put(:max_live_sessions_per_user, 2)
      |> Map.put(:credential_status, fn _provider ->
        send(parent, {:past_cap_precheck, self()})

        receive do
          :continue -> :onboarded
        end
      end)
      |> Gateway.handlers()
      |> Map.fetch!("spawn")

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          spawn.(%{
            origin: "user:flynn",
            session_key: nil,
            params: %{
              display_name: "Concurrent worker #{index}",
              idempotency_key: "spawn-cap-race-#{index}"
            }
          })
        end)
      end

    callers =
      for _ <- 1..2 do
        assert_receive {:past_cap_precheck, caller}, 5_000
        caller
      end

    Enum.each(callers, &send(&1, :continue))
    results = tasks |> Enum.map(&Task.await(&1, 10_000)) |> Enum.with_index(1)

    assert Enum.count(results, fn {result, _index} -> Map.has_key?(result, :session_key) end) == 1

    assert [{%{code: "cap_exceeded"}, rejected_index}] =
             Enum.reject(results, fn {result, _index} -> Map.has_key?(result, :session_key) end)

    assert Idempotency.get(
             ctx.db,
             "flynn",
             "spawn",
             "spawn-cap-race-#{rejected_index}"
           ) == nil

    assert length(Org.list_for_user(ctx.db, "flynn", false)) == 2
  end

  test "spawn serves a populated stale catalog while preserving its health", ctx do
    base_dir = role_test_base("spawn-stale-populated")
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :spawn_stale_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    put_host_catalog("testhost", "claude", ["claude-fable-5"])
    stale_host_catalog("testhost", "claude")

    assert {[_entry], :stale} = ModelCatalog.get("testhost", "claude", ModelCatalog)

    assert {:ok, %{health: :stale}} =
             ModelCatalog.route("testhost", "claude", Model.new("claude-fable-5"))

    spawn = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["spawn"]

    assert %{session_key: session_key} =
             spawn.(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Stale catalog builder",
                 handle: "stale-catalog-builder",
                 idempotency_key: "spawn-stale-catalog-builder"
               }
             })

    assert Org.get(ctx.db, session_key).model == Model.new("claude-fable-5")
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
    candidate = start_supervised!({CandidateAdapterStub, self()})
    start_supervised!({CoordinatorStub, candidate})

    ensure_global_registry()

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:default_harness, :fixture)
      |> Map.put(:default_model, Model.new("fixture-model"))

    handlers = Gateway.handlers(config)
    start_lane!(ctx.db, "k1")

    assert %{session_key: spawned_key} =
             handlers["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Fixture default",
                 idempotency_key: "fixture-default"
               }
             })

    assert %{
             harness: "fixture",
             provider: "fixture_provider",
             model: %Model{family: "fixture-model"}
           } =
             Org.get(ctx.db, spawned_key)

    assert %{ok: true, harness: "fixture", model: "fixture-model", effort: nil} =
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
    learn_engineering_identity!(base_dir)
    candidate = start_supervised!({CandidateAdapterStub, self()})
    start_supervised!({CoordinatorStub, candidate})

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
      archetype: "coder",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("before-model")
    })

    start_lane!(ctx.db, "swapme")

    # Real prior conversation, so the barrier has something to bury.
    for body <- ["REPLAY_SENTINEL_ONE", "REPLAY_SENTINEL_TWO"] do
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

    assert_receive {:candidate_guidance, "candidate-1", guidance}
    assert guidance =~ "tightbeam transcript --session \"swapme\" --limit 50"
    assert guidance =~ "Do not replay or inject earlier messages"
    refute guidance =~ "REPLAY_SENTINEL_ONE"
    refute guidance =~ "REPLAY_SENTINEL_TWO"

    cwd = Placement.holder_workdir(gateway_config(base_dir, ctx.db, 0), Org.get(ctx.db, "swapme"))

    assert File.read!(Path.join(cwd, ".fixture/skills/tightbeam__worktree-session/SKILL.md"))

    refute guidance =~ "[engine swap]"

    barrier = Org.get(ctx.db, "swapme").cleared_through_seq
    visible = Projection.list_after(ctx.db, "swapme", nil, 50, barrier)

    # THE PROPERTY, and the one worth proving rather than assuming: a tombstone
    # buried by the barrier it explains would be the joke version of this fix.
    assert [tombstone] = visible,
           "the swap must leave exactly the tombstone visible, got #{inspect(visible)}"

    assert tombstone.seq > barrier
    assert tombstone.sender == "process:tightbeam"
    assert tombstone.message_type == "marker"

    assert tombstone.marker == %{
             kind: "harness-switch",
             from: "claude (before-model)",
             to: "fixture (fixture-model)"
           }

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
    candidate = start_supervised!({CandidateAdapterStub, self()})
    start_supervised!({CoordinatorStub, candidate})

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
      model: Model.new("before-model")
    })

    start_lane!(ctx.db, "atomic")

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

    assert %{setting: "default-priority", value: 4} =
             config.(%{
               origin: "user:flynn",
               params: %{action: "get", setting: "default-priority"}
             })

    assert %{code: "invalid_priority"} =
             config.(%{
               origin: "user:flynn",
               params: %{action: "set", setting: "default-priority", value: 9}
             })

    assert %{code: "forbidden", message: "admin required"} =
             config.(%{
               origin: "user:not-admin",
               params: %{action: "set", setting: "default-priority", value: 6}
             })

    assert %{setting: "default-priority", value: 6, changed: true} =
             config.(%{
               origin: "user:flynn",
               params: %{action: "set", setting: "default-priority", value: 6}
             })

    assert Org.get_setting(ctx.db, "default-priority") == "6"
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
    assert message =~ "Tightbeam has no credential for anthropic on testhost"
    assert {:ok, [[^before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM sessions")
    assert Roles.get(ctx.db, "unready") == nil
    assert Idempotency.get(ctx.db, "flynn", "spawn", "spawn-unready") == nil
  end

  test "spawn uses the next where host when the first cannot run the requested harness", ctx do
    base_dir = placement_test_base("later-eligible", ["eurisko", "racter"])
    ensure_global_registry()

    register_hosts(ctx.db, %{
      "eurisko" => %{ssh: "eurisko", base_dir: "/srv/eurisko", cli_bin: nil},
      "racter" => %{ssh: "racter", base_dir: "/srv/racter", cli_bin: nil}
    })

    await_host_catalog("racter", "codex")

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:default_harness, :codex)
      |> Map.put(:default_model, Model.new("gpt-5.6-sol", effort: "medium"))
      |> Map.put(:credential_status, fn
        :openai, "eurisko" -> {:needs_onboarding, :missing}
        :openai, "racter" -> :onboarded
      end)
      |> Map.put(:sh, fn _command -> {"", 0} end)

    assert %{session_key: session_key} =
             Gateway.handlers(config)["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Placed later",
                 idempotency_key: "spawn-later-eligible"
               }
             })

    assert Org.get(ctx.db, session_key).host == "racter"
  end

  test "spawn uses the next where host when the first has no usable catalog", ctx do
    base_dir = placement_test_base("later-catalog", ["eurisko", "racter"])
    ensure_global_registry()

    register_hosts(ctx.db, %{
      "eurisko" => %{ssh: "eurisko", base_dir: "/srv/eurisko", cli_bin: nil},
      "racter" => %{ssh: "racter", base_dir: "/srv/racter", cli_bin: nil}
    })

    await_host_catalog("eurisko", "codex")
    await_host_catalog("racter", "codex")
    degrade_host_catalog("eurisko", "codex", :ssh_unreachable)

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:default_harness, :codex)
      |> Map.put(:default_model, Model.new("gpt-5.6-sol", effort: "medium"))
      |> Map.put(:credential_status, fn :openai, _host -> :onboarded end)
      |> Map.put(:sh, fn _command -> {"", 0} end)

    assert %{session_key: session_key} =
             Gateway.handlers(config)["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Catalog placed later",
                 idempotency_key: "spawn-later-catalog"
               }
             })

    assert Org.get(ctx.db, session_key).host == "racter"
  end

  test "spawn refusal relays each where host's catalog cause and remedy", ctx do
    base_dir = placement_test_base("catalog-causes", ["eurisko", "racter"])

    register_hosts(ctx.db, %{
      "eurisko" => %{ssh: "eurisko", base_dir: "/srv/eurisko", cli_bin: nil},
      "racter" => %{ssh: "racter", base_dir: "/srv/racter", cli_bin: nil}
    })

    await_host_catalog("eurisko", "codex")
    await_host_catalog("racter", "codex")

    degrade_host_catalog(
      "eurisko",
      "codex",
      {:empty_catalog_for_client_version, "0.145.0"}
    )

    degrade_host_catalog("racter", "codex", {:needs_onboarding, :missing})

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:default_harness, :codex)
      |> Map.put(:default_model, Model.new("gpt-5.6-sol", effort: "medium"))
      |> Map.put(:credential_status, fn :openai, _host -> :onboarded end)

    assert %{code: "placement_denied", detail: %{code: "host_unready"}, message: message} =
             Gateway.handlers(config)["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Catalog nowhere",
                 idempotency_key: "spawn-catalog-nowhere"
               }
             })

    assert message =~ "eurisko: cannot route gpt-5.6-sol (effort medium) on eurisko"
    assert message =~ "upgrade codex on eurisko"
    assert message =~ "racter: cannot route gpt-5.6-sol (effort medium) on racter"
    assert message =~ "run tightbeam onboard openai on racter"
  end

  test "spawn uses the next where host when the first fails live spinup", ctx do
    base_dir = placement_test_base("later-spinup", ["eurisko", "racter"])
    ensure_global_registry()

    register_hosts(ctx.db, %{
      "eurisko" => %{ssh: "eurisko", base_dir: "/srv/eurisko", cli_bin: nil},
      "racter" => %{ssh: "racter", base_dir: "/srv/racter", cli_bin: nil}
    })

    await_host_catalog("eurisko", "codex")
    await_host_catalog("racter", "codex")

    sh = fn command ->
      if List.last(command) == "true" and Enum.member?(command, "eurisko") do
        {"ssh: connect to host eurisko port 22: Connection refused", 255}
      else
        {"", 0}
      end
    end

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:default_harness, :codex)
      |> Map.put(:default_model, Model.new("gpt-5.6-sol", effort: "medium"))
      |> Map.put(:credential_status, fn :openai, _host -> :onboarded end)
      |> Map.put(:sh, sh)

    assert %{session_key: session_key} =
             Gateway.handlers(config)["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Spinup placed later",
                 idempotency_key: "spawn-later-spinup"
               }
             })

    assert Org.get(ctx.db, session_key).host == "racter"
  end

  test "spawn stops after the first ready where host and probes it once", ctx do
    base_dir = placement_test_base("first-ready-once", ["eurisko", "racter"])
    ensure_global_registry()

    register_hosts(ctx.db, %{
      "eurisko" => %{ssh: "eurisko", base_dir: "/srv/eurisko", cli_bin: nil},
      "racter" => %{ssh: "racter", base_dir: "/srv/racter", cli_bin: nil}
    })

    await_host_catalog("eurisko", "codex")
    await_host_catalog("racter", "codex")
    parent = self()

    sh = fn command ->
      if List.last(command) == "true" do
        host = Enum.find(["eurisko", "racter"], &Enum.member?(command, &1))
        send(parent, {:spinup_probe, host})
      end

      {"", 0}
    end

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:default_harness, :codex)
      |> Map.put(:default_model, Model.new("gpt-5.6-sol", effort: "medium"))
      |> Map.put(:credential_status, fn :openai, _host -> :onboarded end)
      |> Map.put(:sh, sh)

    assert %{session_key: session_key} =
             Gateway.handlers(config)["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "First ready once",
                 idempotency_key: "spawn-first-ready-once"
               }
             })

    assert Org.get(ctx.db, session_key).host == "eurisko"
    assert_receive {:spinup_probe, "eurisko"}
    refute_receive {:spinup_probe, _host}
  end

  test "spawn acts on the routed answer from the candidate decision", ctx do
    base_dir = placement_test_base("one-route-answer", ["eurisko", "racter"])
    ensure_global_registry()

    register_hosts(ctx.db, %{
      "eurisko" => %{ssh: "eurisko", base_dir: "/srv/eurisko", cli_bin: nil},
      "racter" => %{ssh: "racter", base_dir: "/srv/racter", cli_bin: nil}
    })

    await_host_catalog("eurisko", "codex")
    await_host_catalog("racter", "codex")
    degraded = :atomics.new(1, [])

    sh = fn command ->
      if List.last(command) == "true" and Enum.member?(command, "eurisko") and
           :atomics.compare_exchange(degraded, 1, 0, 1) == :ok do
        degrade_host_catalog("eurisko", "codex", :catalog_refreshed)
      end

      {"", 0}
    end

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:default_harness, :codex)
      |> Map.put(:default_model, Model.new("gpt-5.6-sol", effort: "medium"))
      |> Map.put(:credential_status, fn :openai, _host -> :onboarded end)
      |> Map.put(:sh, sh)

    assert %{session_key: session_key} =
             Gateway.handlers(config)["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "One route answer",
                 idempotency_key: "spawn-one-route-answer"
               }
             })

    assert Org.get(ctx.db, session_key).host == "eurisko"
  end

  test "spawn refusal gives an unconfigured where host its assimilation remedy", ctx do
    base_dir = placement_test_base("missing-host-remedy", ["eurisko"])

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:default_harness, :codex)
      |> Map.put(:default_model, Model.new("gpt-5.6-sol", effort: "medium"))

    assert %{code: "placement_denied", detail: %{code: "host_unready"}, message: message} =
             Gateway.handlers(config)["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Missing host",
                 idempotency_key: "spawn-missing-host-remedy"
               }
             })

    assert message =~ "no host in archetype default's where can run codex"
    assert message =~ "eurisko: host eurisko is not configured"
    assert message =~ "tightbeam assimilate <ssh-dest> --name eurisko"
  end

  test "spawn refusal names every where host, harness, cause, and remedy", ctx do
    base_dir = placement_test_base("all-ineligible", ["eurisko", "racter"])

    register_hosts(ctx.db, %{
      "eurisko" => %{ssh: "eurisko", base_dir: "/srv/eurisko", cli_bin: nil},
      "racter" => %{ssh: "racter", base_dir: "/srv/racter", cli_bin: nil}
    })

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:default_harness, :codex)
      |> Map.put(:default_model, Model.new("gpt-5.6-sol", effort: "medium"))
      |> Map.put(:credential_status, fn :openai, _host -> {:needs_onboarding, :missing} end)

    assert %{
             code: "placement_denied",
             detail: %{code: "host_unready"},
             message: message
           } =
             Gateway.handlers(config)["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Nowhere",
                 idempotency_key: "spawn-all-ineligible"
               }
             })

    assert message =~ "no host in archetype default's where can run codex"

    for {host, _base} <- [{"eurisko", "/srv/eurisko"}, {"racter", "/srv/racter"}] do
      assert message =~ "Tightbeam has no credential for openai on #{host}"
      assert message =~ "Run on #{host}: tightbeam onboard openai --as-user <userId>"
    end
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

    # r4.2: the `:credential_server_unavailable` transient ("could not ASK") must NOT be
    # misrouted into an onboard remedy — the shared credential_remedy function names retry.
    expected_message =
      "Tightbeam could not reach the credential server for anthropic on #{machine}. " <>
        "This is transient — retry shortly. Do not re-onboard; the credential may be fine."

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
    first_commands = collect_credential_commands([])
    assert first_commands != []
    assert Enum.all?(first_commands, &(Enum.join(&1, " ") =~ "/remote/tb"))

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
    second_commands = collect_credential_commands([])
    assert second_commands != []
    assert Enum.all?(second_commands, &(Enum.join(&1, " ") =~ "/remote/new-tb"))

    assert %{
             code: "placement_denied",
             detail: %{code: "needs_onboarding"},
             message: message
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

    assert message =~ "Tightbeam has no credential for anthropic on #{machine}"
    assert message =~ "normal CLI login"

    assert message =~
             "Run on #{machine}: tightbeam onboard anthropic --as-user <userId>"
  end

  test "host env verbs set, list, and unset one identity-attributed row with explicit timing",
       ctx do
    handlers = Gateway.handlers(%{db: ctx.db})
    host = Placement.local_host_name()

    set =
      handlers["host-env-set"].(%{
        origin: "user:flynn",
        params: %{
          host: host,
          harness: "claude",
          name: "EXAMPLE_OVERLAY_VAR",
          value: "example"
        }
      })

    assert set.host == host
    assert set.harness == "claude"
    assert set.name == "EXAMPLE_OVERLAY_VAR"
    assert set.value == "example"
    assert set.set_by == "user:flynn"
    assert is_integer(set.set_at)
    assert set.effect == "takes effect on next claude adapter start on #{host}"

    assert %{overlays: [listed]} =
             handlers["host-env-list"].(%{
               origin: "agent:operator",
               params: %{host: host, harness: "claude"}
             })

    assert listed == Map.delete(set, :effect)

    assert %{host: ^host, harness: "claude", name: "EXAMPLE_OVERLAY_VAR", removed: true} =
             handlers["host-env-unset"].(%{
               origin: "user:flynn",
               params: %{host: host, harness: "claude", name: "EXAMPLE_OVERLAY_VAR"}
             })

    assert %{overlays: []} =
             handlers["host-env-list"].(%{origin: "agent:operator", params: %{}})
  end

  test "host-env-set names every reserved and malformed boundary refusal", ctx do
    set = Gateway.handlers(%{db: ctx.db})["host-env-set"]
    host = Placement.local_host_name()

    declared_credentials =
      Tightbeam.Harness.all()
      |> Enum.flat_map(& &1.credential_env_vars())

    reserved_names =
      ([
         "TIGHTBEAM_EXAMPLE",
         "PATH",
         "CLAUDE_CONFIG_DIR",
         "CODEX_HOME",
         "TIGHTBEAM_URL"
       ] ++ declared_credentials)
      |> Enum.uniq()

    for name <- reserved_names do
      assert %{code: "reserved_env_name", message: message} =
               set.(%{
                 origin: "user:flynn",
                 params: %{
                   host: host,
                   harness: "claude",
                   name: name,
                   value: "example"
                 }
               })

      assert message =~ "reserved_env_name rule"
      assert message =~ name
    end

    assert %{code: "invalid_env_name", message: invalid_message} =
             set.(%{
               origin: "user:flynn",
               params: %{
                 host: host,
                 harness: "claude",
                 name: "lowercase",
                 value: "example"
               }
             })

    assert invalid_message =~ "invalid_env_name rule"

    assert %{code: "unknown_host", message: host_message} =
             set.(%{
               origin: "user:flynn",
               params: %{
                 host: "missing-host",
                 harness: "claude",
                 name: "EXAMPLE_OVERLAY_VAR",
                 value: "example"
               }
             })

    assert host_message =~ "unknown_host rule"
    assert host_message =~ "host missing-host is not configured for claude"

    assert %{code: "unknown_harness", message: harness_message} =
             set.(%{
               origin: "user:flynn",
               params: %{
                 host: host,
                 harness: "unknown-harness",
                 name: "EXAMPLE_OVERLAY_VAR",
                 value: "example"
               }
             })

    assert harness_message =~ "unknown_harness rule"
    assert Placement.env_overlays(ctx.db) == []
  end

  test "host env writes refuse a resolved non-admin agent while list stays readable", ctx do
    handlers = Gateway.handlers(%{db: ctx.db})
    host = Placement.local_host_name()

    {:pending, _operator_device} =
      Devices.pair(ctx.db, %{
        device_id: "operator-device",
        claimed_name: "Operator",
        platform: nil,
        model: nil
      })

    assert %{is_admin: false} = Devices.user(ctx.db, "operator")

    operator = create_session(ctx.db, "operator-session", "operator")
    Roles.create!(ctx.db, "operator", "operator", operator.session_key)

    assert %{set_by: "user:flynn"} =
             handlers["host-env-set"].(%{
               origin: "user:flynn",
               params: %{
                 host: host,
                 harness: "claude",
                 name: "EXAMPLE_OVERLAY_VAR",
                 value: "example"
               }
             })

    assert %{code: "forbidden", message: "admin required"} =
             handlers["host-env-set"].(%{
               origin: "agent:operator",
               params: %{
                 host: host,
                 harness: "claude",
                 name: "NODE_OPTIONS",
                 value: "--require=example"
               }
             })

    assert %{code: "forbidden", message: "admin required"} =
             handlers["host-env-unset"].(%{
               origin: "agent:operator",
               params: %{host: host, harness: "claude", name: "EXAMPLE_OVERLAY_VAR"}
             })

    assert %{overlays: [%{name: "EXAMPLE_OVERLAY_VAR", value: "example"}]} =
             handlers["host-env-list"].(%{
               origin: "agent:operator",
               params: %{host: host, harness: "claude"}
             })
  end

  test "host-toolchain-set replaces one ordered registry row set and previews the PATH switch",
       ctx do
    config =
      ctx.catalog_base
      |> gateway_config(ctx.db, 0)
      |> Map.put(:cli_bin, "/local/bin")

    set = Gateway.handlers(config)["host-toolchain-set"]
    host = Placement.local_host_name()

    assert %{
             host: ^host,
             dirs: ["/tools/one", "/tools/two"],
             set_by: "user:flynn",
             set_at: set_at,
             effect:
               "this host's adapter PATH is now fully constructed: /local/bin:/tools/one:/tools/two:/usr/local/bin:/usr/bin:/bin"
           } =
             set.(%{
               origin: "user:flynn",
               params: %{host: host, dirs: ["/tools/one", "/tools/two"]}
             })

    assert is_integer(set_at)

    assert {:ok,
            [
              [^host, 0, "/tools/one", "user:flynn", ^set_at],
              [^host, 1, "/tools/two", "user:flynn", ^set_at]
            ]} =
             DB.query(
               ctx.db,
               "SELECT host, position, dir, setBy, setAt FROM host_toolchain_dirs ORDER BY position"
             )

    assert %{code: "unknown_host", message: message} =
             set.(%{
               origin: "user:flynn",
               params: %{host: "missing-host", dirs: ["/tools"]}
             })

    assert message =~ "unknown_host rule"

    assert %{
             host: ^host,
             dirs: [],
             effect: "this host's adapter PATH now keeps the inherited value unchanged"
           } =
             set.(%{origin: "user:flynn", params: %{host: host, dirs: []}})

    assert {:ok, []} = DB.query(ctx.db, "SELECT host FROM host_toolchain_dirs")
  end

  test "host-toolchain-set refuses a resolved non-admin agent", ctx do
    handlers = Gateway.handlers(%{db: ctx.db})
    host = Placement.local_host_name()

    {:pending, _operator_device} =
      Devices.pair(ctx.db, %{
        device_id: "toolchain-operator-device",
        claimed_name: "Toolchain operator",
        platform: nil,
        model: nil
      })

    operator = create_session(ctx.db, "toolchain-operator-session", "operator")
    Roles.create!(ctx.db, "operator", "operator", operator.session_key)

    assert %{code: "forbidden", message: "admin required"} =
             handlers["host-toolchain-set"].(%{
               origin: "agent:operator",
               params: %{host: host, dirs: ["/tools"]}
             })
  end

  test "update-clients refuses non-admin callers and enumerates satellites for admins", ctx do
    register_hosts(ctx.db, %{
      "alpha" => %{
        ssh: "flynn@alpha.local",
        base_dir: "/srv/alpha",
        cli_bin: "/srv/alpha/bin"
      },
      "beta" => %{ssh: "beta.local", base_dir: "/srv/beta", cli_bin: nil}
    })

    handler = Gateway.handlers(gateway_config(ctx.catalog_base, ctx.db, 0))["update-clients"]

    # A RESOLVED non-admin, not an unknown caller: an unknown origin is refused
    # by resolution failing, which would keep this green even if every real
    # non-admin were wrongly authorized. Pair a second user (the cold-start rule
    # gives admin only to the first) and refuse THAT principal.
    {:pending, _guest_device} =
      Devices.pair(ctx.db, %{
        device_id: "guest-device",
        claimed_name: "Guest",
        platform: nil,
        model: nil
      })

    refute match?(%{is_admin: true}, Devices.user(ctx.db, "guest"))

    assert %{code: "forbidden", message: "admin required"} =
             handler.(%{
               origin: "user:guest",
               session_key: nil,
               params: %{}
             })

    # Prove the admin BIT is what decided, not a resolution failure that
    # produces the same refusal shape: the same principal, promoted, passes.
    %{is_admin: true} = Devices.set_user_admin(ctx.db, "guest", true)
    assert %{hosts: _} = handler.(%{origin: "user:guest", session_key: nil, params: %{}})
    %{is_admin: false} = Devices.set_user_admin(ctx.db, "guest", false)

    assert %{
             hosts: [
               %{name: "alpha", ssh: "flynn@alpha.local", cli_bin: "/srv/alpha/bin"},
               %{name: "beta", ssh: "beta.local", cli_bin: nil}
             ]
           } =
             handler.(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{}
             })
  end

  test "add-user lets an admin add admins and non-admins but refuses a non-admin", ctx do
    handler = Gateway.handlers(gateway_config(ctx.catalog_base, ctx.db, 0))["add-user"]

    assert %{user: %{user_id: "second-admin", is_admin: true}} =
             handler.(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{user_id: "second-admin", is_admin: true}
             })

    assert %{user: %{user_id: "guest", is_admin: false}} =
             handler.(%{
               origin: "user:second-admin",
               session_key: nil,
               params: %{user_id: "guest", is_admin: false}
             })

    assert %{code: "forbidden", message: "admin required"} =
             handler.(%{
               origin: "user:guest",
               session_key: nil,
               params: %{user_id: "blocked", is_admin: false}
             })

    assert Devices.user(ctx.db, "blocked") == nil
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

    assert marker, "crash recovery must append the turn-failed notice"
    assert marker.message_type == "substrate"
    assert marker.marker == nil
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

    assert message =~ ~s("gateway-only-model" is not offered by claude on host worker)
    assert message =~ "worker-only-model"

    # Symmetrically, on the gateway's own host (session k1) the gateway's ref is
    # good and the satellite's is not — tune, because it judges the ref against
    # the session's host without going through spinup.
    candidate = start_supervised!({CandidateAdapterStub, self()})
    start_supervised!({CoordinatorStub, candidate})
    tune = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["tune"]
    start_lane!(ctx.db, "k1")

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
               params: %{
                 setting: "set_harness",
                 harness: "codex",
                 model: "gpt-5.6-sol",
                 effort: "medium"
               }
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
             scaffold.(%{
               origin: "user:not-admin",
               params: %{name: "demo", purpose: "Help a team do demo work."}
             })

    refute File.exists?(Path.join(base_dir, "identity"))

    expected_relatives = [
      "archetypes/demo-role.toml",
      "guidance/demo-role.md",
      "skills/demo-example/SKILL.md",
      "rails/demo-example.toml",
      "kungfu/demo/capabilities.md",
      "kungfu/demo/preferred-models.md",
      "kungfu/demo/intake.md",
      "kungfu/demo/manifest.toml",
      "kungfu/demo/README.md"
    ]

    assert %{kungfu: "demo", paths: paths} =
             scaffold.(%{
               origin: "user:flynn",
               params: %{name: "demo", purpose: "Help a team do demo work."}
             })

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

    bundle_manifest =
      Toml.decode!(File.read!(Path.join(identity_dir, "kungfu/demo/manifest.toml")))

    assert bundle_manifest == %{
             "purpose" => "Help a team do demo work.",
             "root_archetype" => "demo-role"
           }

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
                   scaffold.(%{
                     origin: "user:flynn",
                     params: %{name: "demo", purpose: "Help a team do demo work."}
                   })
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

  test "invalid spawn overrides still precede an invalid harness", ctx do
    base_dir = role_test_base("override-before-harness")
    Archetypes.load!(base_dir)

    result =
      Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["spawn"].(%{
        origin: "user:flynn",
        session_key: nil,
        params: %{
          display_name: "Invalid both",
          idempotency_key: "override-before-harness",
          harness: "not-a-harness",
          overrides: %{"skills_add" => ["missing-skill"]}
        }
      })

    assert %{code: "config_denied", detail: %{code: "invalid_overrides"}} = result
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

  test "set_model moves a resident harness session before recording the selection", ctx do
    base_dir = role_test_base("override-set-model")
    put_skill!(base_dir, "review", "# Review")
    base = Archetypes.load!(base_dir)["default"]

    {:ok, overrides} =
      Archetypes.normalize_overrides(base_dir, base, %{"skills_add" => ["review"]})

    config = gateway_config(base_dir, ctx.db, 0)
    identity_name = Placement.identity_name(config, base, overrides, :claude)
    Org.set_identity(ctx.db, "k1", overrides, identity_name)
    local_host = Placement.local_host_name()
    Org.set_host(ctx.db, "k1", local_host)
    Org.append_pointer(ctx.db, "k1", "existing-session", "created")
    start_lane!(ctx.db, "k1")

    adapter = start_supervised!({TuneAdapterStub, {self(), resident: true}})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    put_host_catalog(local_host, "claude", ["claude-sonnet-4-6"])

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_model", model: "claude-sonnet-4-6"}
             })

    assert_receive {:adapter_key, {:claude, "shared", ^local_host}}
    assert_receive {:tune_residency_checked, "existing-session"}

    assert_receive {:tune_session_switched, "existing-session",
                    %Model{family: "claude-sonnet-4-6"}, _cwd, _mcp_servers, guidance}

    assert guidance =~ "Tightbeam · default"
    assert_receive {:tune_session_closed, "existing-session"}
    assert Org.get(ctx.db, "k1").model == Model.new("claude-sonnet-4-6")

    assert %{harness_session_id: "switched-session", reason: "loaded"} =
             Org.current_pointer(ctx.db, "k1")

    assert %{message_type: "marker", marker: marker_facts} =
             ctx.db
             |> Projection.list_after("k1", nil, 100)
             |> Enum.find(&(&1.message_type == "marker"))

    assert marker_facts.kind == "model-retune"
    assert marker_facts.from == "fable"
    assert marker_facts.to == "claude-sonnet-4-6"
  end

  test "runtime tune hides unknown, foreign, retired, and process targets behind one refusal",
       ctx do
    retired = create_session(ctx.db, "retired-tune", "flynn")
    Org.retire(ctx.db, retired.session_key, "user:flynn", 1_000)
    tune = Gateway.handlers(gateway_config(ctx.catalog_base, ctx.db, 0))["tune"]

    calls = [
      %{origin: "user:other-owner", session_key: "missing-tune"},
      %{origin: "user:other-owner", session_key: "k1"},
      %{origin: "user:flynn", session_key: retired.session_key},
      %{origin: "process:automation", session_key: "k1"}
    ]

    results =
      Enum.map(calls, fn call ->
        tune.(Map.put(call, :params, %{setting: "set_model", model: "claude-fable-5"}))
      end)

    assert Enum.uniq(results) == [
             %{ok: false, code: "not_found", message: "session not found"}
           ]
  end

  test "an idle lane with durable queued work refuses tune before adapter mutation", ctx do
    base_dir = role_test_base("queued-tune-fence")
    Archetypes.load!(base_dir)

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:on_tune_fence, fn ->
        assert {:ok, _seq} =
                 Ledger.enqueue(ctx.db, %{
                   session_key: "k1",
                   message_id: "queued-before-tune",
                   origin: "user:flynn",
                   prompt: "queued"
                 })
      end)

    local_host = Placement.local_host_name()
    Org.set_host(ctx.db, "k1", local_host)
    put_host_catalog(local_host, "claude", ["claude-sonnet-4-6"])
    start_lane!(ctx.db, "k1")

    adapter = start_supervised!({TuneAdapterStub, {self(), resident: true}})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    assert %{ok: false, code: "turn_in_progress"} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_model", model: "claude-sonnet-4-6"}
             })

    refute_received {:tune_residency_checked, _sid}
  end

  test "same-harness names refuse without a pointer, barrier, or tombstone", ctx do
    start_lane!(ctx.db, "k1")
    before = Org.get(ctx.db, "k1")

    {:ok, [[before_messages]]} =
      DB.query(ctx.db, "SELECT count(*) FROM messages WHERE sessionKey = 'k1'")

    assert %{ok: false, code: "same_harness"} =
             Gateway.handlers(gateway_config(ctx.catalog_base, ctx.db, 0))["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_harness", harness: "claude", model: "fable"}
             })

    assert Org.get(ctx.db, "k1") == before
    assert Org.current_pointer(ctx.db, "k1") == nil

    assert {:ok, [[^before_messages]]} =
             DB.query(ctx.db, "SELECT count(*) FROM messages WHERE sessionKey = 'k1'")
  end

  test "Fast changes one live control and never writes stored intent", ctx do
    base_dir = role_test_base("fast-tune")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)
    local_host = Placement.local_host_name()
    Org.set_host(ctx.db, "k1", local_host)
    Org.append_pointer(ctx.db, "k1", "fast-session", "created")
    start_lane!(ctx.db, "k1")
    before = Org.get(ctx.db, "k1")

    adapter = start_supervised!({FastTuneAdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    assert %{
             ok: true,
             fast: "on",
             fast_status: "known",
             fast_persistence: "ephemeral",
             projection_committed: nil,
             engine_context: "preserved"
           } =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_fast_mode", fastMode: "on"}
             })

    assert_receive {:fast_applied, "fast-session", "on"}
    assert Org.get(ctx.db, "k1") == before

    assert %{
             runtimeStatus: "known",
             fastStatus: "known",
             fast: "on",
             fastPersistence: "ephemeral",
             display: %{fastMode: "on"},
             capabilities: %{setFastMode: %{supported: true}}
           } = Gateway.session_status("k1", ctx.db)
  end

  test "set_model reports a resident switch failure and leaves the selected model unchanged",
       ctx do
    base_dir = role_test_base("resident-set-model-failure")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)
    before = Org.get(ctx.db, "k1").model
    local_host = Placement.local_host_name()
    Org.set_host(ctx.db, "k1", local_host)
    Org.append_pointer(ctx.db, "k1", "resident-session", "created")
    start_lane!(ctx.db, "k1")

    adapter =
      start_supervised!(
        {TuneAdapterStub, {self(), resident: true, switch_result: {:error, :model_unavailable}}}
      )

    start_supervised!({CoordinatorStub, adapter})
    put_host_catalog(local_host, "claude", ["claude-sonnet-4-6"])

    # The reason rides an honest sentence. The frozen offered-set refusal is gone;
    # this case is a real reload failure and the selected model stays unchanged.
    assert %{ok: false, code: "model_apply_failed", message: message} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_model", model: "claude-sonnet-4-6"}
             })

    assert message =~ "model_unavailable"
    assert message =~ "could not prepare the new model"

    assert_receive {:tune_session_switched, "resident-session",
                    %Model{family: "claude-sonnet-4-6"}, _cwd, _mcp_servers, _guidance}

    assert Org.get(ctx.db, "k1").model == before
    assert Org.current_pointer(ctx.db, "k1").harness_session_id == "resident-session"
    refute_receive {:tune_session_closed, "resident-session"}
  end

  test "set_model refuses while the lane owns a running turn", ctx do
    base_dir = role_test_base("resident-set-model-busy")
    Archetypes.load!(base_dir)
    config = gateway_config(base_dir, ctx.db, 0)
    before = Org.get(ctx.db, "k1").model
    local_host = Placement.local_host_name()
    Org.set_host(ctx.db, "k1", local_host)
    put_host_catalog(local_host, "claude", ["claude-sonnet-4-6"])

    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: "k1",
               message_id: "set-model-running",
               origin: "user:flynn",
               prompt: "hold the boundary"
             })

    parent = self()

    start_lane!(ctx.db, "k1", fn _turn ->
      send(parent, {:set_model_turn_started, self()})

      receive do
        :finish_set_model_turn -> {:ok, %{}}
      end
    end)

    assert_receive {:set_model_turn_started, runner}

    assert %{ok: false, code: "turn_in_progress", message: message} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_model", model: "claude-sonnet-4-6"}
             })

    assert message =~ "Try again once the current turn finishes"
    assert Org.get(ctx.db, "k1").model == before
    send(runner, :finish_set_model_turn)
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
        model: Model.new("claude-sonnet-5", effort: "medium")
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
      {:ok, staging, lease_id} = Credentials.begin_onboard(:anthropic, server)
      File.write!(Path.join(staging, ".credentials.json"), "credential-bytes")
      :ok = Credentials.finish_onboard(:anthropic, kind, lease_id, server)
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

    test "an unreadable credential store refuses status instead of reporting none", ctx do
      store = Path.join([ctx.cred_base, "auth", "claude"])
      target = Path.join(ctx.cred_base, "credential-target")
      File.mkdir_p!(target)
      File.mkdir_p!(Path.dirname(store))
      File.ln_s!(target, store)
      owner!(ctx.cred_base)

      assert {:error, 503, "credential_store_unreadable", message} =
               Gateway.session_status("k-kind", ctx.db)

      assert message =~ store
      refute message =~ ~s(credentialKind: "none")
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

  # A named field that is accepted and then dropped is the silent-no-op class
  # this codebase keeps producing. `--effort high` with no `--model` says
  # something real; it must reach the spawn, not vanish because the identity
  # could not be built without a family.
  test "a partial selection completes against the default instead of being dropped", ctx do
    base_dir = role_test_base("partial-selection")
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :partial_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    put_host_catalog("testhost", "claude", [
      {"claude-fable-5", ["low", "high"]},
      {"claude-sonnet-4-6", ["low", "high"]}
    ])

    config =
      base_dir
      |> gateway_config(ctx.db, 0)
      |> Map.put(:default_model, Model.new("claude-fable-5", effort: "low"))

    spawn_with = fn params, key ->
      Gateway.handlers(config)["spawn"].(%{
        origin: "user:flynn",
        session_key: nil,
        params: Map.merge(%{display_name: "Partial", idempotency_key: key}, params)
      })
    end

    # Effort alone: the DEFAULT model, at the effort named.
    assert %{session_key: only_effort} = spawn_with.(%{effort: "high"}, "k-effort")
    assert Org.get(ctx.db, only_effort).model == Model.new("claude-fable-5", effort: "high")

    # Nothing named: the default, untouched.
    assert %{session_key: neither} = spawn_with.(%{}, "k-neither")
    assert Org.get(ctx.db, neither).model == Model.new("claude-fable-5", effort: "low")

    # A model alone carries the default's tier forward, composed against what
    # that model actually offers — one mechanism decides effort.
    assert %{session_key: only_model} = spawn_with.(%{model: "claude-sonnet-4-6"}, "k-model")
    assert Org.get(ctx.db, only_model).model == Model.new("claude-sonnet-4-6", effort: "low")
  end

  # The OTHER half of the omitted-versus-explicit distinction, and it only
  # means anything as a pair: an omitted context INHERITS, where an explicit
  # default-window selection does not (see the wire round-trip tests). Collapse
  # the two representations into one nil and exactly one of these two breaks,
  # whichever way the collapse falls.
  test "an omitted context inherits from the default, unlike an explicit one", ctx do
    base_dir = role_test_base("omitted-context-inherits")
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :omitted_context_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    put_host_catalog("testhost", "claude", [{"claude-fable-5", ["low", "high"]}])

    put_host_catalog_entry("testhost", "claude", %{
      family: "claude-fable-5",
      context: "1m",
      efforts: ["low", "high"]
    })

    config =
      base_dir
      |> gateway_config(ctx.db, 0)
      |> Map.put(:default_model, Model.new("claude-fable-5", context: "1m", effort: "low"))

    assert %{session_key: key} =
             Gateway.handlers(config)["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Omitted",
                 idempotency_key: "k-omitted-context",
                 effort: "high"
               }
             })

    assert Org.get(ctx.db, key).model ==
             Model.new("claude-fable-5", context: "1m", effort: "high"),
           "naming only an effort must keep the default's context"

    # …and the same request with the context NAMED as nil selects the default
    # window instead. Identical params but for one key's presence, opposite
    # outcomes — which is the whole point of carrying presence, and what a
    # nil-dropping `put_named/3` silently made impossible.
    assert %{session_key: explicit} =
             Gateway.handlers(config)["spawn"].(%{
               origin: "user:flynn",
               session_key: nil,
               params: %{
                 display_name: "Explicit",
                 idempotency_key: "k-explicit-context",
                 effort: "high",
                 context: nil
               }
             })

    assert Org.get(ctx.db, explicit).model == Model.new("claude-fable-5", effort: "high"),
           "naming the context as nil must select the default window, not inherit 1m"
  end

  # THE FAMILY EXCEPTION, THROUGH THE SEAM. A unit test on `named_fields/1`
  # proves the field map; it does not prove what `complete/2` builds from it.
  # An explicitly nil family must behave like an absent one — inherit — and
  # never construct a `%Model{family: nil}` that is routed as though nil were
  # a model and refused downstream for the wrong reason.
  test "an explicitly nil family inherits the default rather than becoming a nil model", ctx do
    base_dir = role_test_base("nil-family")
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :nil_family_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    put_host_catalog("testhost", "claude", [{"claude-fable-5", ["low", "high"]}])

    config =
      base_dir
      |> gateway_config(ctx.db, 0)
      |> Map.put(:default_model, Model.new("claude-fable-5", effort: "low"))

    # `model: nil` is what the wire delivers for `{"model": null}` now that the
    # router carries an explicit null instead of dropping it.
    for empty <- [nil, ""] do
      key = "k-nil-family-#{inspect(empty)}"

      assert %{session_key: spawned} =
               Gateway.handlers(config)["spawn"].(%{
                 origin: "user:flynn",
                 session_key: nil,
                 params: %{
                   display_name: "Nil Family",
                   idempotency_key: key,
                   model: empty,
                   effort: "high"
                 }
               }),
             "an empty family must not refuse — it is a partial selection"

      assert Org.get(ctx.db, spawned).model ==
               Model.new("claude-fable-5", effort: "high"),
             "the family inherits from the default; the named effort is honoured"
    end
  end

  # A refusal has to name the right cause. An effort-only selection whose
  # EFFORT is the invalid part was reported as a broken configured default,
  # sending the operator to change a setting that was never the problem.
  test "an invalid caller effort is not blamed on the configured default", ctx do
    base_dir = role_test_base("effort-not-default")
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :effort_blame_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    put_host_catalog("testhost", "claude", [{"claude-fable-5", ["low", "high"]}])

    config =
      base_dir
      |> gateway_config(ctx.db, 0)
      |> Map.put(:default_model, Model.new("claude-fable-5", effort: "low"))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{code: "model_unavailable"} =
                 Gateway.handlers(config)["spawn"].(%{
                   origin: "user:flynn",
                   session_key: nil,
                   params: %{
                     display_name: "Blame",
                     idempotency_key: "k-blame",
                     effort: "bogus"
                   }
                 })
      end)

    refute log =~ "configured default model",
           "the caller's effort was invalid; the configured default is fine"

    # And the genuine case still warns — the flag means "entirely from policy".
    dead = Map.put(config, :default_model, Model.new("not-in-catalog", effort: "low"))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{code: "model_unavailable"} =
                 Gateway.handlers(dead)["spawn"].(%{
                   origin: "user:flynn",
                   session_key: nil,
                   params: %{display_name: "Blame", idempotency_key: "k-blame-2"}
                 })
      end)

    assert log =~ "configured default model"
  end

  # An archetype default is a `%Model{}` internally. Publishing it raw put
  # `__struct__`/`family` — an INTERNAL shape — into a client payload, and JSON
  # encoding refused it outright, so every org-options read broke the moment an
  # archetype declared a default model.
  test "archetype defaults and preferences cross org_options as named fields", ctx do
    base_dir = role_test_base("org-options-defaults")
    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)

    File.write!(Path.join(manifests, "defaulted.toml"), """
    name = "defaulted"

    [defaults]
    model = "claude-fable-5"
    effort = "high"
    context = "1m"

    [[model_preferences]]
    model = "gpt-5.6-sol"
    effort = "medium"
    """)

    Archetypes.load!(base_dir)

    inspected =
      Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["inspect"].(%{
        origin: "user:flynn",
        session_key: nil,
        params: %{}
      })

    defaulted = Enum.find(inspected.archetypes, &(&1.name == "defaulted"))

    assert defaulted.defaults[:model] == "claude-fable-5"
    assert defaulted.defaults[:effort] == "high"
    assert defaulted.defaults[:context] == "1m"

    assert defaulted.modelPreferences ==
             [%{model: "gpt-5.6-sol", effort: "medium", context: nil}]

    # It must actually SERIALIZE — a `%Model{}` here raised on encode, so the
    # whole payload failed the moment an archetype declared a default model.
    encoded = JSON.encode!(inspected)
    refute encoded =~ "__struct__"
    refute encoded =~ "family"
  end

  # THE WIRE SEAM, both directions. The ruling names the wire as a seam that
  # carries NAMED FIELDS: a 1M selection that crossed as the bare string
  # `claude-fable-5[1m]`, with nothing saying which part was the context, left
  # the client no way to read it and left this side re-parsing on the way back.
  test "the wire publishes a model identity as named fields and resolves it back", ctx do
    Archetypes.load!(role_test_base("wire-named-fields"))
    put_host_catalog("testhost", "claude", [{"claude-fable-5", ["low", "high"]}])

    put_host_catalog_entry("testhost", "claude", %{
      family: "claude-fable-5",
      context: "1m",
      efforts: ["low", "high"]
    })

    Org.create(ctx.db, %{
      session_key: "k-wire",
      display_name: "Wire",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5", effort: "low")
    })

    Org.append_pointer(ctx.db, "k-wire", "status-wire", "created")

    adapter =
      start_supervised!(
        {TuneAdapterStub, {self(), current_model: Model.new("claude-fable-5", effort: "low")}}
      )

    start_supervised!({CoordinatorStub, {adapter, self()}})

    status = Gateway.session_status("k-wire", ctx.db)

    wide =
      Enum.find(status.modelCatalog.models, &(&1.context == "1m"))

    # OUTBOUND: the fields are named. `context` is a field a client can read,
    # not a bracket it would have to split off a string itself.
    assert wide.model == "claude-fable-5"
    assert wide.context == "1m"
    assert wide.efforts == ["low", "high"]

    assert Enum.any?(
             status.modelCatalog.models,
             &(&1.model == "claude-fable-5" and is_nil(&1.context))
           )

    # The current selection, likewise.
    assert status.display.modelFamily == "claude-fable-5"
    assert status.display.modelContext == nil
    assert status.display.reasoningLevel == "low"

    # INBOUND: named fields select the 1M variant, without anything parsing a
    # bracket to find it.
    config = gateway_config(role_test_base("wire-named-fields-in"), ctx.db, 0)
    start_lane!(ctx.db, "k-wire")

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-wire",
               params: %{setting: "set_model", model: "claude-fable-5", context: "1m"}
             })

    assert Org.get(ctx.db, "k-wire").model ==
             Model.new("claude-fable-5", context: "1m", effort: "low")
  end

  # THE OTHER DIRECTION of the round trip, and a silent-retain if the two are
  # confused: a session ON the 1M variant, whose client selects the DEFAULT
  # row. `resolve_issued/3` resolves that id to `context: nil` — an explicit
  # "the default window" — but a nil that also means "the caller said nothing"
  # gets inherited over, and the tune reports success while the session stays
  # on the 1M model. Explicit-default and omitted must not share a slot.
  test "selecting the default-context row leaves the 1M variant, not inherits it", ctx do
    Archetypes.load!(role_test_base("wire-default-context"))
    put_host_catalog("testhost", "claude", [{"claude-fable-5", ["low"]}])

    put_host_catalog_entry("testhost", "claude", %{
      family: "claude-fable-5",
      context: "1m",
      efforts: ["low"]
    })

    Org.create(ctx.db, %{
      session_key: "k-wide",
      display_name: "Wide",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5", context: "1m", effort: "low")
    })

    default_row =
      Gateway.session_status("k-wide", ctx.db).modelCatalog.models
      |> Enum.find(&is_nil(&1.context))

    config = gateway_config(role_test_base("wire-default-context-in"), ctx.db, 0)
    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    start_lane!(ctx.db, "k-wide")

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-wide",
               params: %{setting: "set_model", model: default_row.ref}
             })

    assert Org.get(ctx.db, "k-wide").model ==
             Model.new("claude-fable-5", effort: "low"),
           "selecting the default-window row must LEAVE the 1M variant"
  end

  # The identity this seam ISSUES is what a client echoes back, so it has to
  # come home to the same row. Resolution is a catalog lookup, never a regex:
  # a lookup cannot invent a context the host does not offer.
  #
  # THIS TEST IS THE GUARD on `wire_identity/1` rendering family and context
  # ONLY. It is what fails if effort is ever rendered into the wire id, which
  # would silently restore the 1M collision by giving that slot two meanings
  # again. It reads as redundant beside the catalog tests. It is not.
  test "an issued row identity echoed back resolves to that row's fields", ctx do
    Archetypes.load!(role_test_base("wire-echo"))
    put_host_catalog("testhost", "claude", [{"claude-fable-5", ["low"]}])

    put_host_catalog_entry("testhost", "claude", %{
      family: "claude-fable-5",
      context: "1m",
      efforts: ["low"]
    })

    Org.create(ctx.db, %{
      session_key: "k-echo",
      display_name: "Echo",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5", effort: "low")
    })

    issued =
      Gateway.session_status("k-echo", ctx.db).modelCatalog.models
      |> Enum.find(&(&1.context == "1m"))
      |> Map.fetch!(:ref)

    config = gateway_config(role_test_base("wire-echo-in"), ctx.db, 0)
    adapter = start_supervised!({CandidateAdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    start_lane!(ctx.db, "k-echo")

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-echo",
               params: %{setting: "set_model", model: issued}
             })

    # THE Q1 CONTRACT IN ONE ASSERTION. The bracket in an issued id can only
    # ever mean context, because effort is never rendered into it — so the
    # round trip must land the context in `context` and leave effort alone.
    # Losing the context, or growing an effort out of the bracket, are the two
    # ways this seam can be wrong, and both are pinned here.
    stored = Org.get(ctx.db, "k-echo").model
    assert stored.family == "claude-fable-5"
    assert stored.context == "1m"
    assert stored.effort == "low", "the effort came from the session, never from the id"

    # And the identity it publishes for that row is the one it was handed.
    assert Gateway.session_status("k-echo", ctx.db).display.model == issued
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
      model: Model.new("gpt-5.6-sol", effort: "medium")
    })

    Org.append_pointer(ctx.db, "k-reasoning", "status-reasoning", "created")

    adapter =
      start_supervised!(
        {TuneAdapterStub, {self(), current_model: Model.new("gpt-5.6-sol", effort: "medium")}}
      )

    start_supervised!({CoordinatorStub, {adapter, self()}})

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

  test "session_status publishes the live harness switch capability", ctx do
    Archetypes.load!(role_test_base("session-status-harness-switch"))
    status = Gateway.session_status("k1", ctx.db)

    assert %{supported: true, options: harness_options} = status.capabilities.setHarness

    assert Enum.map(harness_options, & &1.value) ==
             Enum.map(Tightbeam.Harness.all(), & &1.wire_name())
  end

  test "session_status separates unknown live runtime from configured intent", ctx do
    Archetypes.load!(role_test_base("session-status-runtime-truth"))
    configured = Org.get(ctx.db, "k1").model

    status = Gateway.session_status("k1", ctx.db)

    assert status.runtimeStatus == "unknown"
    assert status.display.model == "unknown"
    assert status.display.modelFamily == nil
    assert status.display.modelContext == nil
    assert status.display.reasoningLevel == nil

    assert status.configuredProjection == %{
             model: configured.family,
             context: configured.context,
             effort: configured.effort
           }
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
      model: Model.new("claude-sonnet-4-6")
    })

    Org.append_pointer(ctx.db, "k-untiered", "status-untiered", "created")

    adapter =
      start_supervised!(
        {TuneAdapterStub, {self(), current_model: Model.new("claude-sonnet-4-6")}}
      )

    start_supervised!({CoordinatorStub, {adapter, self()}})

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

    candidate = start_supervised!({CandidateAdapterStub, self()})
    start_supervised!({CoordinatorStub, candidate})
    tune = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["tune"]

    assert %{ok: false, code: "model_unknown"} =
             tune.(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_reasoning", reasoningLevel: "high"}
             })

    start_lane!(ctx.db, "k1")

    assert %{ok: true} =
             tune.(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_model", model: "claude-sonnet-4-6"}
             })

    assert Org.get(ctx.db, "k1").model == Model.new("claude-sonnet-4-6")
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
      model: Model.new("gpt-5.6-sol", effort: "medium")
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    start_lane!(ctx.db, "k-round-trip")

    # The client sends modelCatalog.models[].ref back as the set_model value.
    emitted = Gateway.session_status("k-round-trip", ctx.db).modelCatalog.models
    terra_ref = Enum.find(emitted, &(&1.name == "GPT-5.6 Terra")).ref

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-round-trip",
               params: %{setting: "set_model", model: terra_ref}
             })

    stored = Org.get(ctx.db, "k-round-trip").model
    assert {stored.family, stored.context} == {"gpt-5.6-terra", nil}
    assert stored.effort in ["low", "high"]
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
      model: Model.new("gpt-5.6-sol", effort: "xhigh")
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    start_lane!(ctx.db, "k-codex")

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex",
               params: %{setting: "set_model", model: "gpt-5.6-sol"}
             })

    assert Org.get(ctx.db, "k-codex").model == Model.new("gpt-5.6-sol", effort: "xhigh")
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
      model: Model.new("gpt-5.6-sol", effort: "xhigh")
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    start_lane!(ctx.db, "k-codex-fallback")

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex-fallback",
               params: %{setting: "set_model", model: "gpt-5.6-terra"}
             })

    # gpt-5.6-terra only offers low/high (in that catalog order); xhigh
    # doesn't carry over and terra has no "medium" either, so this lands on
    # its first listed tier.
    assert Org.get(ctx.db, "k-codex-fallback").model == Model.new("gpt-5.6-terra", effort: "low")
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
      model: Model.new("gpt-5.6-nano", effort: "turbo")
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    start_lane!(ctx.db, "k-codex-medium")

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex-medium",
               params: %{setting: "set_model", model: "gpt-5.6-sol"}
             })

    # "turbo" doesn't exist on sol, but sol does offer "medium", so that's
    # preferred over just taking the first listed tier.
    assert Org.get(ctx.db, "k-codex-medium").model == Model.new("gpt-5.6-sol", effort: "medium")
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
      model: Model.new("gpt-5.6-sol", effort: "high")
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    start_lane!(ctx.db, "k-codex-untiered")

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex-untiered",
               params: %{setting: "set_model", model: "gpt-5.6-classic"}
             })

    assert Org.get(ctx.db, "k-codex-untiered").model == Model.new("gpt-5.6-classic")
  end

  # Renamed with the shape it now tests. There is no bracketed ref to be
  # backward-compatible WITH: an explicit effort arrives as its own field and
  # is honoured as given, never composed over.
  test "set_model honours an explicitly named effort rather than composing one", ctx do
    base_dir = role_test_base("set-model-explicit-effort")
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
      model: Model.new("gpt-5.6-sol", effort: "medium")
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    start_lane!(ctx.db, "k-codex-full-ref")

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex-full-ref",
               params: %{setting: "set_model", model: "gpt-5.6-sol", effort: "low"}
             })

    assert Org.get(ctx.db, "k-codex-full-ref").model == Model.new("gpt-5.6-sol", effort: "low")
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
      model: Model.new("gpt-5.6-sol", effort: "medium")
    })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    start_lane!(ctx.db, "k-codex-reasoning")

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k-codex-reasoning",
               params: %{setting: "set_reasoning", reasoningLevel: "xhigh"}
             })

    assert Org.get(ctx.db, "k-codex-reasoning").model == Model.new("gpt-5.6-sol", effort: "xhigh")
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

    {dead_adapter, monitor} = spawn_monitor(fn -> :ok end)
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

    assert message =~ "Tightbeam has no credential for anthropic on worker"
    assert Org.get(ctx.db, "k1").host == "testhost"
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
                 model: "gpt-5.6-sol",
                 effort: "medium"
               }
             })

    assert message =~ "Tightbeam has no credential for openai on testhost"
    assert Org.get(ctx.db, "k1") == before
  end

  test "model-free session-control round trip uses each destination harness default", ctx do
    base_dir = role_test_base("harness-destination-default-round-trip")
    codex_auth = Path.join([base_dir, "auth", "codex"])
    File.mkdir_p!(codex_auth)
    File.write!(Path.join(codex_auth, "auth.json"), "test-token")
    Archetypes.load!(base_dir)
    ensure_global_registry()

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:conn_registry, ctx.registry)
      |> Map.put(:lane_manager, ctx.lane)

    local_host = Placement.local_host_name()
    Org.set_host(ctx.db, "k1", local_host)
    Org.set_model(ctx.db, "k1", Model.new("source-claude", effort: "high"), "anthropic")

    stable_identity =
      ctx.db
      |> Org.get("k1")
      |> Map.take([:session_key, :display_name, :owner_user_id, :origin, :archetype])

    put_host_catalog(local_host, "codex", [])

    put_host_catalog_entry(local_host, "codex", %{
      family: "gpt-5.6-sol",
      efforts: ["low", "high"],
      provider: :openai
    })

    put_host_catalog_entry(local_host, "codex", %{
      family: "gpt-explicit",
      efforts: ["high"],
      provider: :openai
    })

    put_host_catalog(local_host, "claude", [])

    put_host_catalog_entry(local_host, "claude", %{
      family: "claude-sonnet-5",
      efforts: [],
      provider: :anthropic
    })

    candidate = start_supervised!({CandidateAdapterStub, self()})
    start_supervised!({CoordinatorStub, candidate})
    start_lane!(ctx.db, "k1")

    router_opts = [
      db: ctx.db,
      base_dir: base_dir,
      handlers: Gateway.handlers(config),
      session_status: fn session_key -> Gateway.session_status(session_key, ctx.db) end
    ]

    post = fn body ->
      Plug.Test.conn(
        :post,
        "/api/session-control",
        JSON.encode!(Map.put(body, "sessionKey", "k1"))
      )
      |> Plug.Conn.put_req_header("authorization", "Bearer #{ctx.device.token}")
      |> Tightbeam.Wire.Router.call(Tightbeam.Wire.Router.init(router_opts))
      |> then(&JSON.decode!(&1.resp_body))
    end

    assert %{
             "ok" => true,
             "status" => %{
               "display" => %{
                 "harness" => "codex",
                 "modelFamily" => "gpt-5.6-sol",
                 "reasoningLevel" => "low"
               }
             }
           } = post.(%{"action" => "set_harness", "harness" => "codex"})

    assert Org.get(ctx.db, "k1").model == Model.new("gpt-5.6-sol", effort: "low")

    [codex_marker] =
      Projection.list_after(
        ctx.db,
        "k1",
        nil,
        50,
        Org.get(ctx.db, "k1").cleared_through_seq
      )

    assert codex_marker.content =~
             "changed from claude (source-claude (effort high)) to " <>
               "codex (gpt-5.6-sol (effort low))"

    assert %{
             "ok" => true,
             "status" => %{
               "display" => %{
                 "harness" => "claude",
                 "modelFamily" => "claude-sonnet-5",
                 "reasoningLevel" => nil
               }
             }
           } = post.(%{"action" => "set_harness", "harness" => "claude"})

    assert Org.get(ctx.db, "k1").model == Model.new("claude-sonnet-5")

    before_missing_default = Org.get(ctx.db, "k1")

    {:ok, [[before_message_count]]} =
      DB.query(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey = ?1", ["k1"])

    put_host_catalog(local_host, "codex", [{"other-codex-model", ["low"]}])

    assert %{"ok" => false, "code" => "model_unavailable"} =
             post.(%{"action" => "set_harness", "harness" => "codex"})

    assert Org.get(ctx.db, "k1") == before_missing_default

    assert {:ok, [[^before_message_count]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey = ?1", ["k1"])

    put_host_catalog(local_host, "codex", [])

    put_host_catalog_entry(local_host, "codex", %{
      family: "gpt-5.6-sol",
      efforts: ["low", "high"],
      provider: :openai
    })

    put_host_catalog_entry(local_host, "codex", %{
      family: "gpt-explicit",
      efforts: ["high"],
      provider: :openai
    })

    assert %{
             "ok" => true,
             "status" => %{
               "display" => %{"harness" => "codex"},
               "configuredProjection" => %{
                 "context" => nil,
                 "effort" => "low",
                 "model" => "gpt-5.6-sol"
               }
             }
           } = post.(%{"action" => "set_harness", "harness" => "codex"})

    assert Org.get(ctx.db, "k1").model == Model.new("gpt-5.6-sol", effort: "low")

    assert %{"ok" => true} = post.(%{"action" => "set_harness", "harness" => "claude"})

    assert %{
             "ok" => true,
             "status" => %{
               "configuredProjection" => %{
                 "model" => "gpt-explicit",
                 "context" => nil,
                 "effort" => "high"
               }
             }
           } =
             post.(%{
               "action" => "set_harness",
               "harness" => "codex",
               "model" => "gpt-explicit",
               "effort" => "high"
             })

    assert Org.get(ctx.db, "k1").model == Model.new("gpt-explicit", effort: "high")

    assert ctx.db
           |> Org.get("k1")
           |> Map.take([:session_key, :display_name, :owner_user_id, :origin, :archetype]) ==
             stable_identity

    before_refusal = Org.get(ctx.db, "k1")

    assert %{"ok" => false, "code" => "model_unavailable"} =
             post.(%{
               "action" => "set_harness",
               "harness" => "claude",
               "model" => "not-a-claude-model",
               "effort" => "high"
             })

    assert Org.get(ctx.db, "k1") == before_refusal
  end

  test "set_harness changes the engine and projects its home at a turn boundary", ctx do
    base_dir = role_test_base("harness-turn-boundary")
    codex_auth = Path.join([base_dir, "auth", "codex"])
    File.mkdir_p!(codex_auth)
    File.write!(Path.join(codex_auth, "auth.json"), "test-token")
    Archetypes.load!(base_dir)
    ensure_global_registry()

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:conn_registry, ctx.registry)
      |> Map.put(:lane_manager, ctx.lane)

    {Tightbeam.LaneManager, lane_opts} =
      config
      |> Gateway.children()
      |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)
    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    local_host = Placement.local_host_name()
    Org.set_host(ctx.db, "k1", local_host)
    put_host_catalog(local_host, "codex", [])

    put_host_catalog_entry(local_host, "codex", %{
      family: "gpt-5.6-sol",
      efforts: ["medium"],
      provider: :openai
    })

    start_lane!(ctx.db, "k1", runner)

    assert %{ok: true, harness: "codex", model: "gpt-5.6-sol", effort: "medium"} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{
                 setting: "set_harness",
                 harness: "codex",
                 model: "gpt-5.6-sol",
                 effort: "medium"
               }
             })

    assert %{harness: "codex", provider: "openai", model: model} = Org.get(ctx.db, "k1")
    assert model == Model.new("gpt-5.6-sol", effort: "medium")

    home = Tightbeam.Homes.home_path(base_dir, local_host, :codex)

    assert JSON.decode!(File.read!(Path.join([home, ".tightbeam", "manifest"])))["harness"] ==
             "codex"

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "next turn",
               db: ctx.db,
               conn_registry: ctx.registry,
               lane_manager: ctx.lane,
               device_id: "d1",
               client_message_id: "after-harness-switch"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")
    task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)

    assert_receive {:adapter_key, {:codex, "shared", ^local_host}}
    assert_receive {:new_session_mcp_servers, _mcp_servers}, @cold_runner_prompt_timeout
    assert_receive {:prompt_started, ^adapter}, @cold_runner_prompt_timeout

    send(adapter, :continue_prompt)
    assert {:ok, %{terminal_publish: publish}} = Task.await(task)
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    publish.("delivered")

    assert %{harness_session_id: "harness-1", harness: "codex"} =
             Org.current_pointer(ctx.db, "k1")
  end

  test "a committed harness replacement reports and records an unverified source close", ctx do
    base_dir = role_test_base("harness-unverified-source-close")
    codex_auth = Path.join([base_dir, "auth", "codex"])
    File.mkdir_p!(codex_auth)
    File.write!(Path.join(codex_auth, "auth.json"), "test-token")
    Archetypes.load!(base_dir)

    start_supervised!(%{
      id: :harness_cleanup_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    config = gateway_config(base_dir, ctx.db, 0)
    local_host = Placement.local_host_name()
    Org.set_host(ctx.db, "k1", local_host)
    Org.append_pointer(ctx.db, "k1", "source-runtime", "created")
    put_host_catalog(local_host, "codex", [])

    put_host_catalog_entry(local_host, "codex", %{
      family: "gpt-5.6-sol",
      efforts: ["medium"],
      provider: :openai
    })

    start_lane!(ctx.db, "k1")
    destination = start_supervised!({AdapterStub, self()})
    source = start_supervised!({CloseErrorAdapterStub, self()})

    selector = fn
      {:codex, "shared", ^local_host} -> {:ok, destination, 1}
      {:claude, "shared", ^local_host} -> {:ok, source, 1}
    end

    start_supervised!({CoordinatorStub, selector})

    assert %{
             ok: true,
             harness: "codex",
             engine_context: "reset",
             cleanup_status: "unverified",
             warning: "runtime close could not be verified",
             lifecycle_event_id: event_id
           } =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               principal: {:user, "flynn"},
               session_key: "k1",
               params: %{
                 setting: "set_harness",
                 harness: "codex",
                 model: "gpt-5.6-sol",
                 effort: "medium"
               }
             })

    assert is_integer(event_id)
    assert_receive {:close_session_failed, "source-runtime"}

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "runtime_cleanup_unverified" and
               event.subject == "source-runtime" and
               JSON.decode!(event.detail)["principal"] == inspect({:user, "flynn"})
           end)
  end

  test "set_harness refuses before writing the new home while a turn runs", ctx do
    base_dir = role_test_base("harness-running-turn")
    codex_auth = Path.join([base_dir, "auth", "codex"])
    File.mkdir_p!(codex_auth)
    File.write!(Path.join(codex_auth, "auth.json"), "test-token")
    Archetypes.load!(base_dir)

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:conn_registry, ctx.registry)
      |> Map.put(:lane_manager, ctx.lane)

    local_host = Placement.local_host_name()
    Org.set_host(ctx.db, "k1", local_host)
    before = Org.get(ctx.db, "k1")
    put_host_catalog(local_host, "codex", [])

    put_host_catalog_entry(local_host, "codex", %{
      family: "gpt-5.6-sol",
      efforts: ["medium"],
      provider: :openai
    })

    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: "k1",
               message_id: "set-harness-running",
               origin: "user:flynn",
               prompt: "hold the harness boundary"
             })

    parent = self()

    start_lane!(ctx.db, "k1", fn _turn ->
      send(parent, {:set_harness_turn_started, self()})

      receive do
        :finish_set_harness_turn -> {:ok, %{}}
      end
    end)

    assert_receive {:set_harness_turn_started, runner}
    home = Tightbeam.Homes.home_path(base_dir, local_host, :codex)
    refute File.exists?(home)

    assert %{ok: false, code: "turn_in_progress", message: message} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{
                 setting: "set_harness",
                 harness: "codex",
                 model: "gpt-5.6-sol",
                 effort: "medium"
               }
             })

    assert message =~ "Try again once the current turn finishes"
    assert Org.get(ctx.db, "k1") == before
    refute File.exists?(home)
    send(runner, :finish_set_harness_turn)
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
    candidate = start_supervised!({CandidateAdapterStub, self()})
    start_supervised!({CoordinatorStub, candidate})

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:conn_registry, ctx.registry)
      |> Map.put(:lane_manager, ctx.lane)

    start_supervised!(%{
      id: :harness_bare_model_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    start_lane!(ctx.db, "k1")

    assert %{ok: true, harness: "codex"} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_harness", harness: "codex", model: "gpt-5.6-sol"}
             })

    # Composed, not passed through: the tier is real information and the session must
    # end up on a ref the catalog actually offers.
    assert Org.get(ctx.db, "k1").model == Model.new("gpt-5.6-sol", effort: "medium")

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
    candidate = start_supervised!({CandidateAdapterStub, self()})
    start_supervised!({CoordinatorStub, candidate})

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
    start_lane!(ctx.db, "k1")

    assert %{ok: true, harness: "codex"} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{
                 setting: "set_harness",
                 harness: "codex",
                 model: "gpt-5.6-sol",
                 effort: "medium"
               }
             })

    assert Org.get(ctx.db, "k1").identity_name == identity_name
    home = Tightbeam.Homes.home_path(base_dir, "testhost", :codex)
    assert_receive {:candidate_guidance, "candidate-1", guidance}
    assert guidance =~ "Codex developer message"
    assert guidance =~ "tightbeam transcript --session \"k1\" --limit 50"
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

  test "a checkout refusal keeps its stable code through the real runner and turn wire", ctx do
    refusal = %{
      code: "DIV-CURSOR-API-KEY-ONLY",
      message: "Cursor requires a banked API key"
    }

    coordinator =
      start_supervised!({CoordinatorStub, fn _key -> {:error, {:launch_refused, refusal}} end})

    exact_registry =
      case ConnRegistry.start_link(name: Tightbeam.ConnRegistry) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    ConnRegistry.register(exact_registry, %{
      pid: self(),
      user_id: "flynn",
      device_id: "cursor-refusal-wire",
      is_admin: false,
      subscriptions: MapSet.new(["chat"])
    })

    ConnRegistry.register(ctx.registry, %{
      pid: self(),
      user_id: "flynn",
      device_id: "cursor-refusal",
      is_admin: false,
      subscriptions: MapSet.new(["chat"])
    })

    config =
      gateway_config(gateway_children_base!(), ctx.db, 0)
      |> Map.put(:adapter_coordinator, coordinator)

    {Tightbeam.LaneManager, lane_opts} =
      config
      |> Gateway.children()
      |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "cursor refusal",
               db: ctx.db,
               conn_registry: ctx.registry,
               lane_manager: ctx.lane,
               device_id: "cursor-refusal",
               client_message_id: "c_cursor_refusal"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")

    assert {:error, %{reason: ^refusal, terminal_publish: publish}} =
             runner.(Map.put(turn, :session_key, "k1"))

    publish.("failed")

    assert_receive {:push,
                    %{
                      "event" => "prompt_turn_state",
                      "payload" => %{
                        "state" => "failed",
                        "error" => %{
                          code: "DIV-CURSOR-API-KEY-ONLY",
                          message: "Cursor requires a banked API key"
                        }
                      }
                    }},
                   2_000
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
  test "one turn stores and publishes distinct ACP assistant messages as separate records", ctx do
    exact_registry =
      start_supervised!(%{
        id: :boundary_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "boundaries",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    config = %{
      base_dir: gateway_children_base!(),
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
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
             Gateway.deliver_prompt("k1", "user:flynn", "split assistant messages",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "boundaries",
               client_message_id: "c_boundaries"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")
    echo = Projection.get(ctx.db, turn.message_id)
    task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)

    assert_receive {:prompt_started, ^adapter}, @cold_runner_prompt_timeout
    send(adapter, :continue_prompt)
    assert {:ok, %{terminal_publish: publish}} = Task.await(task)
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    publish.("delivered")

    replies =
      ctx.db
      |> Projection.list_after("k1", echo.id, 10)
      |> Enum.filter(&(&1.sender == "tightbeam"))

    assert Enum.map(replies, & &1.content) == ["FIRST", "SECOND"]
    assert Enum.map(replies, & &1.reply_to_message_id) == [echo.id, echo.id]
    assert Enum.map(replies, & &1.reply_to_client_message_id) == ["c_boundaries", "c_boundaries"]
    assert Enum.map(replies, & &1.seq) == Enum.sort(Enum.map(replies, & &1.seq))

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

    assert frames
           |> Enum.filter(&(&1["type"] == "message" and &1["role"] == "assistant"))
           |> Enum.map(& &1["content"]) == ["FIRST", "SECOND"]
  end

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

    identity_edit!(
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
      default_model: Model.new("claude-fable-5"),
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

  test "a disappeared turn host reaches the socket turn-state payload by name", ctx do
    ensure_global_registry()
    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    {:ok, _ref, nil} =
      ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "placement-refusal",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    base = gateway_children_base!()

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db
    }

    {Tightbeam.LaneManager, lane_opts} =
      config
      |> Gateway.children()
      |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

    lane_sup =
      start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, name: :placement_refusal_lane_supervisor}
      )

    manager =
      start_supervised!({
        LaneManager,
        db: ctx.db,
        lane_sup: lane_sup,
        task_sup: Tightbeam.TurnTaskSupervisor,
        runner: Keyword.fetch!(lane_opts, :runner),
        terminal_publisher: Keyword.fetch!(lane_opts, :terminal_publisher),
        interval: 60_000,
        name: :placement_refusal_lane_manager
      })

    Org.set_host(ctx.db, "k1", "eurisko")

    expected =
      "host eurisko is not configured for claude; run tightbeam assimilate <ssh-dest> " <>
        "--name eurisko --as-user <adminUserId>"

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "try vanished host",
               db: ctx.db,
               conn_registry: Tightbeam.ConnRegistry,
               lane_manager: manager,
               device_id: "placement-refusal",
               client_message_id: "c_placement_refusal"
             )

    frames = collect_pushes(10, [])

    failed =
      Enum.find(frames, fn
        %{
          "type" => "event",
          "event" => "prompt_turn_state",
          "payload" => %{"state" => "failed"}
        } ->
          true

        _ ->
          false
      end)

    assert failed["payload"]["error"] == expected

    assert Enum.any?(frames, fn
             %{"type" => "message", "content" => content} ->
               content ==
                 "[turn failed]\n\nThe agent could not answer the message above: " <> expected

             _ ->
               false
           end)
  end

  # Install a fresh catalog for one {host, harness}, so a test can give two hosts
  # genuinely different entitlements without a provider on either end.
  defp put_host_catalog_entry(host, harness, overrides) do
    entry =
      Map.merge(
        %{
          family: "seeded",
          context: nil,
          display_name: "Seeded",
          name: "Seeded",
          efforts: [],
          max_input_tokens: 200_000,
          capabilities: %{},
          provider: :anthropic
        },
        overrides
      )

    :sys.replace_state(ModelCatalog, fn state ->
      update_in(state.entries[{host, harness}].entries, &(&1 ++ [entry]))
    end)
  end

  # A seeded catalog entry names a MODEL and the efforts it offers — the shape
  # `ModelCatalog` really holds, so the stub cannot drift from it.
  defp put_host_catalog(host, harness, models) do
    entries =
      Enum.map(models, fn spec ->
        {family, efforts} = if is_tuple(spec), do: spec, else: {spec, []}

        %{
          family: family,
          context: nil,
          display_name: family,
          name: family,
          efforts: efforts,
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

  defp stale_host_catalog(host, harness) do
    :sys.replace_state(ModelCatalog, fn state ->
      now = state.now.()

      update_in(state.entries[{host, harness}], fn cache ->
        %{
          cache
          | derived_at: now - state.ttl_ms - 1,
            attempted_at: now,
            reason: :refresh_failed,
            refreshing: true
        }
      end)
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

    identity_edit!(base, "default", :manifest, manifest, "test")

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

      if Enum.any?(command, &String.contains?(&1, "credential-harvest")) and
           Enum.any?(command, &String.contains?(&1, "cat")),
         do: {"", 42},
         else: {"", 0}
    end

    sh_out = fn command ->
      if Enum.any?(command, &String.contains?(&1, "credential-harvest")) and
           Enum.any?(command, &String.contains?(&1, "cat")),
         do: {"", 42},
         else: {"", 0}
    end

    config =
      gateway_config(base, ctx.db, 4_321)
      |> Map.put(:sh, sh)
      |> Map.put(:sh_out, sh_out)

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

  # wi_263814d3 — the PROVISIONING SEAM, not just deliver_home: a real turn that
  # provisions a fresh harness session must pin the shared home to the SESSION'S
  # selected model (not the org default), so the adapter offers+accepts it at
  # session/new. Deleting the harness_session pin calls leaves settings.json
  # unwritten on the turn path and fails this — the coverage the deliver_home
  # unit tests alone do not give (asg_6508eff5 finding #2).
  @tag timeout: 180_000
  test "provisioning a turn pins the shared home to the session's selected model", ctx do
    exact_registry =
      start_supervised!(%{
        id: :home_pin_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, adapter})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "home-pin",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    base =
      Path.join(System.tmp_dir!(), "gateway_home_pin_#{System.unique_integer([:positive])}")

    File.rm_rf!(base)
    Identity.init!(base)
    Rails.load!(base)

    manifest_path = Path.join([base, "identity", "archetypes", "default.toml"])

    manifest =
      manifest_path
      |> File.read!()
      |> String.replace("name = \"default\"", "name = \"default\"\nwhere = [\"testhost\"]")

    identity_edit!(base, "default", :manifest, manifest, "test")

    on_exit(fn ->
      File.rm_rf!(base)
      :persistent_term.erase(Archetypes)
      :persistent_term.erase(Tightbeam.Rails)
    end)

    # Org default is claude-fable-5 (gateway_config); the session SELECTED a
    # different catalog model. The provisioned home must follow the selection.
    _ = Org.set_model(ctx.db, "k1", Model.new("claude-sonnet-4-6"), "anthropic")
    assert Org.get(ctx.db, "k1").model == Model.new("claude-sonnet-4-6")

    config = gateway_config(base, ctx.db, 0)
    assert config.default_model.family == "claude-fable-5"

    children = Gateway.children(config)

    {Tightbeam.LaneManager, lane_opts} =
      Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "ping",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "home-pin",
               client_message_id: "c_home_pin"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")
    task = Task.async(fn -> runner.(Map.put(turn, :session_key, "k1")) end)

    # new_session having been reached proves harness_session ran the pin first.
    assert_receive {:new_session_mcp_servers, _}, @cold_runner_prompt_timeout

    settings =
      [base, "homes", "testhost", "claude", "settings.json"]
      |> Path.join()
      |> File.read!()
      |> JSON.decode!()

    assert settings["model"] == "claude-sonnet-4-6"

    assert_receive {:prompt_started, ^adapter}, @cold_runner_prompt_timeout
    send(adapter, :continue_prompt)
    assert {:ok, _} = Task.await(task)
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
      default_model: Model.new("claude-fable-5"),
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
    assert marker["messageType"] == "marker"
    assert marker["marker"]["kind"] == "session-restart"
    assert marker["marker"]["from"] == "stale-harness-sid"
    assert is_binary(marker["marker"]["to"])

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
      default_model: Model.new("claude-fable-5"),
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

    assert_receive {:canonical_model_pushed_on_load, "load-apply-session",
                    %Model{family: "fable"}}

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
      default_model: Model.new("claude-fable-5"),
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
    assert Org.get(ctx.db, "k1").model == Model.new("harness-default")

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
    assert Org.get(ctx.db, "k1").model == Model.new("harness-default")
    assert Enum.map(Org.pointer_chain(ctx.db, "k1"), & &1.reason) == ["created", "fallback"]
  end

  test "a failed turn publishes its reason as a chat marker and a terminal state", ctx do
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
      default_model: Model.new("claude-fable-5"),
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

    assert {:error, %{reason: _, terminal_publish: publish, record_in_txn: record}} =
             runner.(Map.put(turn, :session_key, "k1"))

    assert {:ok, true} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", "boom")
               record.(txn)
               true
             end)

    publish.("failed")

    # EVERY failed turn speaks now. Adjudication used to route a failure into a
    # brief instead of the marker, so deleting the brief (2026-08-05) would have
    # left this class of failure with no channel at all — the "agent progress
    # interrupted, no reason given" that Flynn hit on gibson twice.
    frames = collect_pushes(9, [])

    assert Enum.any?(frames, fn frame ->
             frame["type"] == "message" and
               String.starts_with?(frame["content"] || "", "[turn failed]\n")
           end)

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "harness_turn_error" and event.subject == "k1"
           end)

    assert Enum.any?(
             frames,
             &match?(
               %{"event" => "prompt_turn_state", "payload" => %{"state" => "failed"}},
               &1
             )
           )
  end

  # AC6 (spec 1ae8fa52 §O6/I7+I9). O6 RATIFIES the existing turn-path refuse-by-name
  # (`unonboarded_refusal`): a turn onto a {host, harness} whose catalog health is
  # `unavailable({:needs_onboarding, :missing})` is refused with the EXACT
  # `tightbeam onboard <provider> --as-user <userId>` remedy — the same sentence boot
  # prints — and that refusal FAILS-TELLS-RECORDS (I9): a failed turn (the runner returns
  # an error with a terminal publish, never a hold/park), the named reason in the
  # `[turn failed]` chat marker, and a `harness_turn_error` lifecycle event, with the
  # engine never reaching the session/prompt stages (it dies at :checkout, the pre-engine
  # stage a missing credential kills). The spawn seam is pinned separately
  # (spinup_test / "spawn refusal names every where host, harness, cause, and remedy");
  # this pins the turn seam — the AC6 intersection that previously had only generic
  # turn-failure coverage (see "a failed turn publishes its reason as a chat marker").
  test "a turn onto a needs_onboarding host is refused by name and fails-tells-records", ctx do
    exact_registry =
      start_supervised!(%{
        id: :o6_refuse_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    # Checkout DEGRADES — the engine cannot start — so the turn fails at the :checkout
    # stage. No AdapterStub: the coordinator never yields an adapter, so no session/prompt
    # engine call is ever made (the "never launch a dead engine" half of I7).
    start_supervised!({CoordinatorStub, {fn _key -> {:error, :degraded} end, self()}})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "o6-refuse",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    base = gateway_children_base!()

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db
    }

    children = Gateway.children(config)

    {Tightbeam.LaneManager, lane_opts} =
      Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    # testhost/claude has NO credential: the catalog affirmatively answers "missing"
    # (`:missing`, not the `:credential_server_unavailable` transient — see the guard test).
    degrade_host_catalog("testhost", "claude", {:needs_onboarding, :missing})

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "hi",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "o6-refuse",
               client_message_id: "c_o6_refuse"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")

    # FAILS (not parks): the runner returns an error with a terminal publish + record,
    # never a hold/episode/queue.
    assert {:error, %{reason: reason, terminal_publish: publish, record_in_txn: record}} =
             runner.(Map.put(turn, :session_key, "k1"))

    # TELLS: the EXACT remedy, on the host, naming the provider — NOT the raw
    # "adapter is degraded" checkout fault (that fault is kept in the record instead).
    assert reason =~ "tightbeam onboard anthropic --as-user <userId>"
    assert reason =~ "on testhost"
    refute reason =~ "is degraded"

    # RECORDS: the failed row and the lifecycle event, one transaction. The record keeps
    # the STAGE (:checkout — pre-engine) and the raw fault the user-facing sentence flattened.
    assert {:ok, true} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", reason)
               record.(txn)
               true
             end)

    publish.("failed")

    lifecycle =
      Enum.find(EventLog.lifecycle_events(ctx.db), fn event ->
        event.kind == "harness_turn_error" and event.subject == "k1"
      end)

    assert lifecycle, "the refusal must record a harness_turn_error lifecycle event"
    assert lifecycle.detail =~ "checkout"

    # TELLS (chat channel): the remedy reaches the user durably as the `[turn failed]`
    # marker, read from the projection rather than a brittle push count.
    marker =
      ctx.db
      |> Projection.list_after("k1", nil, 100)
      |> Enum.find(&String.starts_with?(&1.content || "", "[turn failed]"))

    assert marker, "a refused turn must speak its reason in chat"
    assert marker.content =~ "tightbeam onboard anthropic --as-user <userId>"

    # NEVER LAUNCHES A DEAD ENGINE: checkout failed pre-engine, so the session/prompt
    # stages never ran — no engine was asked to serve (belt-and-suspenders to the
    # :checkout stage recorded above).
    refute_received {:new_session_mcp_servers, _}
    refute_received {:prompt_started, _}
  end

  # AC6 (spec 1ae8fa52 §O6), the present-but-unverified clause: a host whose credential
  # is present-and-live but whose harness cannot execute surfaces as catalog `fresh` +
  # broken executability (spec O1/AC1), which is NOT `needs_onboarding`. Such a turn MUST
  # NOT be refused with the onboarding remedy — "run onboard" would be false, the
  # credential is already present. Here the observable precondition is reproduced directly:
  # a FRESH catalog for testhost/claude while checkout is broken. `unonboarded_refusal`
  # reads `fresh`, returns `:not_applicable`, and the turn's reason stays its real
  # executability/adapter gap. This guards the `:fresh` axis of I7's narrow `:missing`
  # match; the `:credential_server_unavailable` transient axis is guarded by the next test
  # (the two together pin that I7 refuses on `:missing` specifically, never the wildcard).
  test "a turn on a fresh-but-unexecutable host is not misrouted to the onboarding remedy",
       ctx do
    exact_registry =
      start_supervised!(%{
        id: :o6_pbu_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    start_supervised!({CoordinatorStub, {fn _key -> {:error, :degraded} end, self()}})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "o6-pbu",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    base = gateway_children_base!()

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db
    }

    children = Gateway.children(config)

    {Tightbeam.LaneManager, lane_opts} =
      Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    # No `degrade_host_catalog`: the setup left testhost/claude FRESH (await_catalog).
    # A live credential is present; only executability (checkout) is broken.
    assert {_entries, :fresh} = ModelCatalog.get("testhost", "claude", ModelCatalog)

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "hi",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "o6-pbu",
               client_message_id: "c_o6_pbu"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")

    assert {:error, %{reason: reason}} = runner.(Map.put(turn, :session_key, "k1"))

    # The refusal names the REAL gap (executability/adapter degraded), never the
    # onboarding remedy — the credential is present, so "run onboard" would be false.
    assert reason =~ "is degraded"
    refute reason =~ "tightbeam onboard"
    refute reason =~ "--as-user"
  end

  # AC6 / I7 (spec 1ae8fa52 §O6), the r4.2 narrowing guard: I7 refuses ONLY on `:missing`
  # (the credential store AFFIRMATIVELY answering "absent"), NEVER on the wildcard
  # `{:needs_onboarding, _}`. The `:credential_server_unavailable` transient means "could
  # not ASK" — the Credentials server was momentarily unreachable — and MUST NOT be
  # misrouted into a false onboarding remedy: telling an operator to `onboard` when the
  # real fault is a down credential server aims them at the wrong repair (the misrouting
  # hazard r4.2 names, and gateway.ex:4108-4116 guards with the narrow match). A turn whose
  # turn-seam catalog health is that transient (checkout also broken) is refused by its
  # real executability gap, never the onboarding remedy. This is the turn-seam axis Test A
  # (`:missing`) and Test B (`:fresh`) leave uncovered: a regression reverting
  # gateway.ex:4117 `:missing` back to the wildcard `{:needs_onboarding, _}` passes both of
  # them but goes RED here. (The 29 adapter-heal arenas cover the SPAWN path's
  # credential_status, gateway.ex:4160 — a different seam from unonboarded_refusal.)
  test "a turn on a credential-server-unavailable transient is not misrouted to the onboarding remedy",
       ctx do
    exact_registry =
      start_supervised!(%{
        id: :o6_transient_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    start_supervised!({CoordinatorStub, {fn _key -> {:error, :degraded} end, self()}})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "o6-transient",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    base = gateway_children_base!()

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db
    }

    children = Gateway.children(config)

    {Tightbeam.LaneManager, lane_opts} =
      Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    # The transient: "could not ASK" (credential server unreachable), NOT an affirmative
    # "absent". Health becomes {:unavailable, {:needs_onboarding, :credential_server_unavailable}},
    # which is NOT :missing, so unonboarded_refusal returns :not_applicable.
    degrade_host_catalog(
      "testhost",
      "claude",
      {:needs_onboarding, :credential_server_unavailable}
    )

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "hi",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "o6-transient",
               client_message_id: "c_o6_transient"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")

    assert {:error, %{reason: reason}} = runner.(Map.put(turn, :session_key, "k1"))

    # Refused by its real (executability/adapter) gap, never the onboarding remedy —
    # a "could not ask" transient is not a "you have no credential" verdict.
    assert reason =~ "is degraded"
    refute reason =~ "tightbeam onboard"
    refute reason =~ "--as-user"
  end

  # O6 reactive fix (spec 1ae8fa52) — THE INCIDENT PATH (G3 flatten). Guards A/B/C all force
  # :checkout, but the incident 401s at :prompt: an expired/rejected credential 401s at
  # API-call time, so checkout AND session SUCCEED (the harness holds a token) and catalog
  # health is still `:fresh` — a health lookup is blind to it (reviewer-3 confirmed real expiry
  # is storage-blind). The common-path guarantee here: the operator reads the auth error as
  # human PROSE, never a raw inspected ACP map (G3 error_sentence flatten). RED-before-green:
  # without the flatten, error_sentence inspects the map (`=>`/`%{` markers reach chat). The
  # precise re-onboard NAMING of this health-blind :prompt 401 is the HELD option-a piece
  # (auth-shape detection), pending the PO's a-vs-b ruling; it lands on top without changing
  # this seam (preserved on branch o6-prompt401-naming-built).
  test "an expired-credential turn 401ing at :prompt (fresh health) flattens the raw ACP map to prose (G3)",
       ctx do
    exact_registry =
      start_supervised!(%{
        id: :o6_prompt401_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    # A REAL adapter: checkout + session succeed; the 401 lands at :prompt. AdapterStub
    # returns the auth-expired ACP error for the prompt "fail this turn" (gateway_test:162).
    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "o6-prompt401",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    base = gateway_children_base!()

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db
    }

    children = Gateway.children(config)

    {Tightbeam.LaneManager, lane_opts} =
      Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(lane_opts, :runner)

    # Incident-faithful: catalog LEFT FRESH — real expiry is storage-blind, so health gives
    # NO signal. The only signal is the :prompt auth-fault shape.
    assert {_entries, :fresh} = ModelCatalog.get("testhost", "claude", ModelCatalog)

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "fail this turn",
               db: ctx.db,
               conn_registry: exact_registry,
               lane_manager: ctx.lane,
               device_id: "o6-prompt401",
               client_message_id: "c_o6_prompt401"
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, "k1", "test")

    assert {:error, %{reason: reason, terminal_publish: publish, record_in_txn: record}} =
             runner.(Map.put(turn, :session_key, "k1"))

    # It genuinely failed at :prompt — checkout + session succeeded (the incident path, not a
    # pre-engine refusal). The record keeps the stage.
    # reason is the raw ACP map here (health :fresh -> :not_applicable, no reclassify); the lane
    # stringifies it via error_text before the ledger, and the OPERATOR-facing marker flattens
    # it via error_sentence (asserted below). Finish with a stand-in string, as SessionLane's
    # error_text would produce one.
    assert {:ok, true} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", "prompt auth 401")
               record.(txn)
               true
             end)

    publish.("failed")

    lifecycle =
      Enum.find(EventLog.lifecycle_events(ctx.db), fn event ->
        event.kind == "harness_turn_error" and event.subject == "k1"
      end)

    assert lifecycle, "the :prompt turn failure must record a harness_turn_error"
    assert lifecycle.detail =~ "prompt"

    assert HarnessHealth.active(ctx.db) == []

    assert {:ok, [["auth-dead", "terminal-failure", "k1", cause]]} =
             DB.query(
               ctx.db,
               """
               SELECT failureClass,evidenceKind,sessionKey,cause
               FROM harness_health_observations
               WHERE correlationId=?1
               """,
               ["harness-turn:#{turn.seq}:auth-dead"]
             )

    assert cause =~ "stage=prompt"
    assert cause =~ "auth expired"

    # G3: the operator reads the human message/details as PROSE, never a raw inspected ACP
    # error map. The auth detail survives as text; the map's inspect markers (`=>`, `%{`) do
    # NOT. (The precise re-onboard NAMING for this health-blind :prompt 401 is the held
    # option-a piece, pending the PO's a-vs-b ruling; the common path guarantees only that no
    # raw map reaches chat.)
    marker =
      ctx.db
      |> Projection.list_after("k1", nil, 100)
      |> Enum.find(&String.starts_with?(&1.content || "", "[turn failed]"))

    assert marker, "a :prompt failure must speak in chat"
    assert marker.content =~ "auth expired"
    refute marker.content =~ "=>"
    refute marker.content =~ "%{"
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

  test "learn and unlearn reload all law and unlearn names durable references", ctx do
    case ConnRegistry.start_link(name: Tightbeam.ConnRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    base_dir = role_test_base("learn-unlearn")
    Identity.init!(base_dir)
    handlers = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))
    learn = handlers["learn"]
    unlearn = handlers["unlearn"]
    repoint = handlers["identity-repoint"]
    retire = handlers["retire"]

    assert %{state: "published", kungfu: "agentic-engineering", live_revision: revision} =
             learn.(%{origin: "user:flynn", params: %{name: "agentic-engineering"}})

    assert revision == Identity.live_revision!(base_dir)
    assert Archetypes.get("coder").name == "coder"
    assert Rails.statutes?()
    assert :persistent_term.get(Rules, []) != []

    active =
      Org.create(ctx.db, %{
        session_key: "agent:bundle-active",
        display_name: "Bundle active",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    retired =
      Org.create(ctx.db, %{
        session_key: "agent:bundle-retired",
        display_name: "Bundle retired",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })
      |> then(&Org.retire(ctx.db, &1.session_key, "test:gateway", 1_000))

    assert %{
             state: "referenced",
             code: "kungfu_referenced",
             message: message,
             sessions: sessions,
             setting: nil
           } = unlearn.(%{origin: "user:flynn", params: %{name: "agentic-engineering"}})

    assert message =~ active.session_key
    assert message =~ retired.session_key

    assert Enum.map(sessions, &{&1.session_key, &1.state}) |> Enum.sort() ==
             [{active.session_key, "active"}, {retired.session_key, "retired"}]

    assert %{state: "repointed", session_key: retired_key, archetype: "default"} =
             repoint.(%{
               origin: "user:flynn",
               session_key: retired.session_key,
               params: %{archetype: "default"}
             })

    assert retired_key == retired.session_key

    assert %{retired_session_keys: [active_key]} =
             retire.(%{
               origin: "user:flynn",
               session_key: active.session_key,
               params: %{}
             })

    assert active_key == active.session_key

    assert %{state: "repointed", session_key: ^active_key, archetype: "default"} =
             repoint.(%{
               origin: "user:flynn",
               session_key: active.session_key,
               params: %{archetype: "default"}
             })

    assert Org.get(ctx.db, retired.session_key).archetype == "default"
    assert Org.get(ctx.db, retired.session_key).identity_name == "default"

    :ok = Org.put_setting(ctx.db, "default-archetype", "coder")

    assert %{state: "referenced", sessions: [], setting: "coder", message: setting_message} =
             unlearn.(%{origin: "user:flynn", params: %{name: "agentic-engineering"}})

    assert setting_message =~ "default-archetype setting: coder"
    :ok = Org.put_setting(ctx.db, "default-archetype", "default")

    assert %{state: "published", kungfu: "agentic-engineering"} =
             unlearn.(%{origin: "user:flynn", params: %{name: "agentic-engineering"}})

    assert Archetypes.get("coder") == nil
    refute Rails.statutes?()
    assert :persistent_term.get(Rules, []) == []
  end

  test "kungfu list reports shipped bundles and their offer metadata",
       ctx do
    base_dir = role_test_base("kungfu-list")
    list = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["kungfu-list"]

    assert %{
             bundles: [
               %{
                 name: "agentic-engineering",
                 purpose: purpose,
                 phrases: phrases,
                 root_archetype: "product-owner"
               }
             ]
           } =
             list.(%{origin: "agent:k1", params: %{}})

    assert purpose =~ "turn product ideas and bug reports into shipped software"
    assert "I want my code reviewed before it merges." in phrases

    # The point of phrases is DISCRIMINATION: a phrase another domain's bundle could
    # honestly claim buys nothing. This one could only be a software-engineering bundle.
    refute Enum.any?(phrases, &(&1 == "I keep losing track of what I asked for."))
  end

  test "every unlearn reference kind supplies supported commands that clear it", ctx do
    ensure_global_registry()
    base_dir = role_test_base("unlearn-reference-property")
    learn_engineering_identity!(base_dir)
    handlers = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))

    active =
      Org.create(ctx.db, %{
        session_key: "agent:clear-active",
        display_name: "Clear active",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    retired =
      Org.create(ctx.db, %{
        session_key: "agent:clear-retired",
        display_name: "Clear retired",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })
      |> then(&Org.retire(ctx.db, &1.session_key, "test:gateway", 1_000))

    main =
      Org.create(ctx.db, %{
        session_key: "user:bundle-main",
        display_name: "Main",
        kind: "main",
        is_built_in: true,
        owner_user_id: "bundle-owner",
        origin: "user:bundle-owner",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    Org.append_pointer(ctx.db, main.session_key, "bundle-main-resident", "created")
    start_lane!(ctx.db, main.session_key)
    adapter = start_supervised!({IdentityApplyAdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})
    :ok = Org.put_setting(ctx.db, "default-archetype", "coder")

    assert %{state: "referenced", references: references} =
             handlers["unlearn"].(%{
               origin: "user:flynn",
               params: %{name: "agentic-engineering"}
             })

    assert MapSet.new(Enum.map(references, & &1.kind)) == MapSet.new(["session", "setting"])
    assert Enum.all?(references, &(&1.clear_commands != []))

    for reference <- references, command <- reference.clear_commands do
      assert Map.has_key?(handlers, command.verb)
      result = handlers[command.verb].(Map.put(command, :origin, "user:flynn"))
      refute result[:code], inspect({reference, command, result})
    end

    assert Org.get(ctx.db, active.session_key).archetype == "default"
    assert Org.get(ctx.db, retired.session_key).archetype == "default"
    assert Org.get(ctx.db, main.session_key).archetype == "default"
    assert Org.get(ctx.db, main.session_key).state == "active"
    assert_received {:identity_apply_close, "bundle-main-resident"}

    assert %{state: "published", kungfu: "agentic-engineering"} =
             handlers["unlearn"].(%{
               origin: "user:flynn",
               params: %{name: "agentic-engineering"}
             })
  end

  test "archetype reference writer enumeration covers every production mutation call" do
    expected =
      Enum.frequencies_by(@archetype_reference_writers, fn {_name, file, call} -> {file, call} end)

    calls = @archetype_reference_writers |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

    actual =
      for file <- Path.wildcard("lib/**/*.ex"), call <- calls, reduce: %{} do
        counts ->
          count =
            Regex.scan(Regex.compile!("\\b#{Regex.escape(call)}\\s*\\("), File.read!(file))
            |> length()

          if count == 0,
            do: counts,
            else: Map.put(counts, {file, call}, count)
      end

    assert actual == expected
  end

  test "identity apply refreshes one stamped session at a turn boundary without restarting runtime",
       ctx do
    base_dir = role_test_base("identity-apply")
    learn_engineering_identity!(base_dir)
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-stable", "created")
    start_lane!(ctx.db, session.session_key)
    cwd = Placement.holder_workdir(gateway_config(base_dir, ctx.db, 0), session)
    Identity.provision_at!(base_dir, revision, "coder", :codex, cwd)
    old_body = File.read!(Path.join(cwd, ".codex/skills/tightbeam__worktree-session/SKILL.md"))

    next =
      identity_edit!(
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

    assert_receive {:identity_apply_load, "thread-stable",
                    %Model{family: "gpt-5.6-sol", effort: "medium"}, ^cwd, _mcp, guidance}

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
    learn_engineering_identity!(base_dir)
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
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
    learn_engineering_identity!(base_dir)
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
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
    learn_engineering_identity!(base_dir)
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
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
    learn_engineering_identity!(base_dir)
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-toctou", "created")
    cwd = Placement.holder_workdir(gateway_config(base_dir, ctx.db, 0), session)
    Identity.provision_at!(base_dir, revision, "coder", :codex, cwd)

    next =
      identity_edit!(
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
    learn_engineering_identity!(base_dir)
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-newborn", "created")
    cwd = Placement.holder_workdir(gateway_config(base_dir, ctx.db, 0), session)
    Identity.provision_at!(base_dir, revision, "coder", :codex, cwd)

    next =
      identity_edit!(
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
    learn_engineering_identity!(base_dir)
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-cancel-wait", "created")
    cwd = Placement.holder_workdir(gateway_config(base_dir, ctx.db, 0), session)
    Identity.provision_at!(base_dir, revision, "coder", :codex, cwd)

    identity_edit!(
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
    learn_engineering_identity!(base_dir)
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-residual", "created")
    cwd = Placement.holder_workdir(gateway_config(base_dir, ctx.db, 0), session)
    Identity.provision_at!(base_dir, revision, "coder", :codex, cwd)

    next =
      identity_edit!(
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
  # session has no adapter work, but apply still records the complete live render stamp.
  test "identity apply stamps a never-started session without touching an adapter", ctx do
    base_dir = role_test_base("identity-apply-unstarted")
    learn_engineering_identity!(base_dir)
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
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
    stamped = Org.get(ctx.db, session.session_key)
    assert stamped.identity_render_contract == "universal-root-render-v1"

    base_guidance =
      Identity.snapshot_at!(base_dir, revision, session.archetype, :codex).guidance

    final_guidance =
      base_guidance <>
        "\n\n## Inspect recent Tightbeam transcript\n\n" <>
        "Before continuing, inspect this session's recent Tightbeam transcript. " <>
        "Run `tightbeam transcript --session #{inspect(session.session_key)} --limit 50` and read only the bounded result you need. " <>
        "Do not replay or inject earlier messages, and do not assume another " <>
        "harness's private memory transferred."

    expected_digest =
      :crypto.hash(:sha256, final_guidance) |> Base.encode16(case: :lower)

    assert stamped.identity_guidance_digest == expected_digest

    status = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["identity-status"]
    %{sessions: sessions} = status.(%{origin: "user:flynn", params: %{}})
    rendered = Enum.find(sessions, &(&1.session_key == session.session_key))
    assert rendered.expected_guidance_digest == expected_digest
    refute "guidance_digest_mismatch" in rendered.identity_stale_reasons
    assert_receive {:push, %{"type" => "stream_updated"}}
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
    learn_engineering_identity!(base_dir)
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-vanished", "created")
    start_lane!(ctx.db, session.session_key)

    next =
      identity_edit!(
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
    learn_engineering_identity!(base_dir)
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
          model: Model.new("gpt-5.6-sol", effort: "medium")
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
      identity_edit!(
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
    learn_engineering_identity!(base_dir)
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

    Org.append_pointer(ctx.db, session.session_key, "thread-resident", "created")
    start_lane!(ctx.db, session.session_key)

    identity_edit!(
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
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
        model: Model.new("gpt-5.6-sol", effort: "medium")
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
        model: Model.new("fixture-model")
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
      model: Model.new("claude-fable-5")
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
      Org.retire(ctx.db, first.session_key, "test:gateway", 1_000)

      Org.create(ctx.db, %{
        session_key: "agent:credential-late",
        display_name: "Credential late",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: Model.new("gpt-5.6-sol", effort: "medium")
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
      default_model: Model.new("claude-fable-5"),
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

      File.write!(
        Path.join(auth_dir, ".credentials.json"),
        ~s({"claudeAiOauth":{"accessToken":"test-token"}})
      )
    end

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Archetypes)
    end)

    base_dir
  end

  defp learn_engineering_identity!(base_dir) do
    assert :initialized = Identity.init!(base_dir)
    assert {:ok, _revision} = identity_learn!(base_dir, "agentic-engineering", "test")
    Archetypes.load!(base_dir)
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
      model: Model.new("fable")
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

  defp assert_process_mailbox(name, minimum, attempts \\ 100)

  defp assert_process_mailbox(name, minimum, attempts) when attempts > 0 do
    case Process.info(Process.whereis(name), :message_queue_len) do
      {:message_queue_len, count} when count >= minimum ->
        :ok

      _ ->
        Process.sleep(10)
        assert_process_mailbox(name, minimum, attempts - 1)
    end
  end

  defp assert_process_mailbox(name, minimum, 0),
    do: flunk("#{inspect(name)} mailbox did not reach #{minimum} queued message(s)")

  defp credential_probe(parent, command) do
    send(parent, {:credential_command, command})

    case Enum.take(command, -3) do
      ["test", operator, path] when operator in ["-d", "-x"] ->
        if String.ends_with?(path, "/auth") or String.ends_with?(path, "/auth/") do
          {"", 0}
        else
          {"", 1}
        end

      _ ->
        {"", 1}
    end
  end

  defp collect_credential_commands(commands) do
    receive do
      {:credential_command, command} -> collect_credential_commands([command | commands])
    after
      0 -> Enum.reverse(commands)
    end
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

  defp placement_test_base(suffix, where) do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "gateway_placement_#{suffix}_#{System.unique_integer([:positive])}"
      )

    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)

    hosts = Enum.map_join(where, ", ", &inspect/1)
    File.write!(Path.join(manifests, "default.toml"), "name = \"default\"\nwhere = [#{hosts}]\n")
    Archetypes.load!(base_dir)

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Archetypes)
    end)

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
    identity_edit!(base_dir, "default", {:skill, name, false}, body, "test")
    Archetypes.load!(base_dir)
  end

  defp identity_edit!(base, archetype, target, content, author) do
    candidate = Identity.edit!(base, archetype, target, content, author)
    assert {:ok, revision} = Identity.publish_live!(base, candidate)
    revision
  end

  defp identity_learn!(base, name, author) do
    case Identity.learn!(base, name, author) do
      {:ok, candidate} ->
        assert {:ok, revision} = Identity.publish_live!(base, candidate)
        {:ok, revision}

      other ->
        other
    end
  end
end
