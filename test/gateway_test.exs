defmodule Tightbeam.GatewayTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{
    Archetypes,
    ConnRegistry,
    DB,
    Devices,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Placement,
    Projection,
    Roles,
    Wakes
  }

  defmodule LaneDoorbell do
    use GenServer
    def start_link({parent, name}), do: GenServer.start_link(__MODULE__, parent, name: name)
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, key}, _from, parent) do
      send(parent, {:ensure_lane, key})
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
      {:reply, {:ok, adapter, 1}, state}
    end

    def handle_call({:acquire_load_slot, _borrower}, _from, state),
      do: {:reply, make_ref(), state}

    def handle_cast({:release_load_slot, _slot}, state), do: {:noreply, state}
  end

  defmodule AdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:new_session, _model, _cwd, mcp_servers}, _from, parent) do
      send(parent, {:new_session_mcp_servers, mcp_servers})
      {:reply, {:ok, "harness-1"}, parent}
    end

    def handle_call(:conn, _from, parent), do: {:reply, parent, parent}

    def handle_call({:knows_session?, _sid}, _from, parent), do: {:reply, false, parent}

    def handle_call({:load_session, _sid, _model, _cwd, _mcp_servers}, _from, parent),
      do: {:reply, {:error, %{"code" => -32602, "message" => "Invalid params"}}, parent}

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

  setup do
    db = :"gateway_db_#{System.unique_integer([:positive])}"
    registry = :"gateway_registry_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: registry})
    lane = start_supervised!({LaneDoorbell, self()})
    old_hosts = Application.get_env(:tightbeam, :hosts)

    on_exit(fn ->
      if old_hosts,
        do: Application.put_env(:tightbeam, :hosts, old_hosts),
        else: Application.delete_env(:tightbeam, :hosts)
    end)

    for module <- [Devices, EventLog, Idempotency, Ledger, Org, Projection, Roles, Wakes],
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
        is_admin: false
      })

    %{db: db, registry: registry, lane: lane}
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
        default_model: "fable",
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

  test "children mints a cli token when gateway.json is missing", ctx do
    base_dir =
      Path.join(System.tmp_dir!(), "gateway_missing_#{System.unique_integer([:positive])}")

    Gateway.children(gateway_config(base_dir, ctx.db, 0))

    assert %{"cliToken" => "tbc_" <> token} =
             base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    assert token != ""
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

    File.mkdir_p!(base_dir)
    File.write!(Path.join(base_dir, "gateway.json"), "not json")

    Gateway.children(gateway_config(base_dir, ctx.db, 0))

    assert %{"cliToken" => "tbc_" <> token} =
             base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    assert token != ""
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

    start_supervised!(%{
      id: :role_lane_manager,
      start: {LaneDoorbell, :start_link, [{self(), Tightbeam.LaneManager}]}
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

    Roles.create!(ctx.db, "taken", "flynn", nil)
    {:ok, [[before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM sessions")

    assert %{code: "role_exists"} =
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

    assert %{code: "host_unready", message: message} = result
    assert message =~ "no claude credentials"
    assert {:ok, [[^before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM sessions")
    assert Roles.get(ctx.db, "unready") == nil
    assert Idempotency.get(ctx.db, "flynn", "spawn", "spawn-unready") == nil
  end

  test "spawn proceeds after a live remote readiness probe", ctx do
    base_dir = move_test_base("spawn-ready")
    parent = self()

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

  test "skill-rm removes elected roots, warns, and notifies only active electing sessions", ctx do
    base_dir = role_test_base("skill-rm")
    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)
    skill_dir = Path.join([base_dir, "identity", "skills", "swift"])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "# Swift")

    File.write!(Path.join(manifests, "coder.toml"), """
    name = "coder"
    skills = ["swift"]
    """)

    Archetypes.load!(base_dir)

    active =
      Org.create(ctx.db, %{
        session_key: "agent:coder-active",
        display_name: "Coder active",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    retired =
      Org.create(ctx.db, %{
        session_key: "agent:coder-retired",
        display_name: "Coder retired",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    Org.retire(ctx.db, retired.session_key)

    remove =
      Gateway.handlers(
        gateway_config(base_dir, ctx.db, 0)
        |> Map.put(:conn_registry, ctx.registry)
        |> Map.put(:lane_manager, ctx.lane)
      )["skill-rm"]

    result = remove.(%{origin: "user:flynn", params: %{name: "swift"}})

    assert result.notified == [active.session_key]

    assert result.manifest_warnings == [
             "archetype coder still elects swift in identity/archetypes/coder.toml — " <>
               "edit it before the next restart (boot validation is fail-closed)"
           ]

    expected =
      "The skill \"swift\" has been removed from this org's library. " <>
        "Disregard it, including anything from it already in your context."

    assert {:ok, [["process:tightbeam", "[from process:tightbeam]\n\n" <> ^expected]]} =
             DB.query(
               ctx.db,
               "SELECT origin, prompt FROM turns WHERE sessionKey = ?1",
               [active.session_key]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE sessionKey = ?1",
               [retired.session_key]
             )
  end

  test "skill-rm returns unknown_skill without notifications for a missing skill", ctx do
    base_dir = role_test_base("skill-rm-missing")
    Archetypes.load!(base_dir)

    remove = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["skill-rm"]

    assert %{code: "unknown_skill", message: "unknown skill: missing"} =
             remove.(%{origin: "user:flynn", params: %{name: "missing"}})

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")
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

      assert result.code == "invalid_overrides"
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
            "skills_add" => ["tightbeam-skills", "tightbeam-skills"],
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

  test "override skills pin before library removal and tune removal changes identity with notice",
       ctx do
    base_dir = role_test_base("override-pin")
    Archetypes.put_skill!(base_dir, "review", "# Preserved review content")
    base = Archetypes.load!(base_dir)["default"]

    {:ok, overrides} =
      Archetypes.normalize_overrides(base_dir, base, %{"skills_add" => ["review"]})

    config =
      gateway_config(base_dir, ctx.db, 0)
      |> Map.put(:conn_registry, ctx.registry)
      |> Map.put(:lane_manager, ctx.lane)

    start_supervised!(%{
      id: :override_pin_conn_registry,
      start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
    })

    identity_name = Placement.identity_name(config, base, overrides, :claude)

    session =
      Org.create(ctx.db, %{
        session_key: "agent:override-pin",
        display_name: "Pinned",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        overrides: overrides,
        identity_name: identity_name,
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    home = Placement.deliver_home(config, {:claude, identity_name, "testhost"})
    old_stamp = File.read!(Path.join(home, ".tightbeam-manifest"))
    marker = Path.join(home, "old-home-marker")
    File.write!(marker, "remove on regeneration")

    handlers = Gateway.handlers(config)
    removed = handlers["skill-rm"].(%{origin: "user:flynn", params: %{name: "review"}})
    assert removed.notified == [session.session_key]

    pinned = Path.join([base_dir, "identity", "pinned", identity_name, "review", "SKILL.md"])
    assert File.read!(pinned) == "# Preserved review content"
    refute File.exists?(Path.join([Archetypes.skills_dir(base_dir), "review"]))

    assert File.read_link!(Path.join(home, "skills/review")) == Path.dirname(pinned)
    assert Org.get(ctx.db, session.session_key).identity_name == identity_name
    refute File.exists?(marker)
    refute File.read!(Path.join(home, ".tightbeam-manifest")) == old_stamp

    manifest = home |> Path.join(".tightbeam-manifest") |> File.read!() |> JSON.decode!()

    assert %{
             "name" => "review",
             "provenance" => "override",
             "linkage" => "pinned"
           } in manifest["skills"]

    Application.put_env(:tightbeam, :advertised_url, "http://gateway.example:4000")

    Application.put_env(:tightbeam, :hosts, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: "/remote/tb/bin"}
    })

    parent = self()

    sh = fn command ->
      send(parent, {:pinned_command, command})
      if "cat" in command, do: {"", 1}, else: {"", 0}
    end

    assert Placement.deliver_home(
             Map.put(config, :sh, sh),
             {:claude, identity_name, "worker"},
             sh: sh
           ) == "/remote/tb/homes/#{identity_name}/claude"

    assert Enum.any?(collect_tagged_commands(:pinned_command, []), fn command ->
             Enum.any?(command, &String.contains?(&1, "/identity/pinned/#{identity_name}/review"))
           end)

    preserved_prompt =
      "The skill \"review\" was removed from the library, but your session elected it at " <>
        "spawn, so your copy is preserved. Use \"tune\" override removal if you no longer want it."

    assert {:ok, [["[from process:tightbeam]\n\n" <> ^preserved_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT prompt FROM turns WHERE sessionKey = ?1 ORDER BY seq LIMIT 1",
               [session.session_key]
             )

    assert %{code: "denied"} =
             handlers["tune"].(%{
               origin: "user:other",
               session_key: session.session_key,
               params: %{setting: "remove_override", skill: "review"}
             })

    assert %{ok: true, identity_name: "default", overrides: nil} =
             handlers["tune"].(%{
               origin: "user:flynn",
               session_key: session.session_key,
               params: %{setting: "remove_override", skill: "review"}
             })

    updated = Org.get(ctx.db, session.session_key)
    assert updated.overrides == nil
    assert updated.identity_name == "default"
    refute File.exists?(Path.join([base_dir, "identity", "pinned", identity_name]))

    assert Enum.any?(Projection.list_after(ctx.db, session.session_key, nil, 100), fn message ->
             String.starts_with?(message.content, "[context reset]")
           end)

    assert {:ok, [[tune_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT prompt FROM turns WHERE sessionKey = ?1 ORDER BY seq DESC LIMIT 1",
               [session.session_key]
             )

    assert tune_prompt ==
             "[from process:tightbeam]\n\nYour override \"review\" was removed by the operator; disregard it."
  end

  test "set_model reload checks out the overridden adapter key", ctx do
    base_dir = role_test_base("override-set-model")
    Archetypes.put_skill!(base_dir, "review", "# Review")
    base = Archetypes.load!(base_dir)["default"]

    {:ok, overrides} =
      Archetypes.normalize_overrides(base_dir, base, %{"skills_add" => ["review"]})

    config = gateway_config(base_dir, ctx.db, 0)
    identity_name = Placement.identity_name(config, base, overrides, :claude)
    Org.set_identity(ctx.db, "k1", overrides, identity_name)
    Org.append_pointer(ctx.db, "k1", "existing-session", "created")

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, {adapter, self()}})

    assert %{ok: true} =
             Gateway.handlers(config)["tune"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_model", model: "sonnet"}
             })

    assert_receive {:adapter_key, {:claude, ^identity_name, "testhost"}}
  end

  test "cancel addresses the overridden adapter key", ctx do
    base_dir = role_test_base("override-cancel")
    Archetypes.put_skill!(base_dir, "review", "# Review")
    base = Archetypes.load!(base_dir)["default"]

    {:ok, overrides} =
      Archetypes.normalize_overrides(base_dir, base, %{"skills_add" => ["review"]})

    config = gateway_config(base_dir, ctx.db, 0)
    identity_name = Placement.identity_name(config, base, overrides, :claude)
    Org.set_identity(ctx.db, "k1", overrides, identity_name)
    Org.append_pointer(ctx.db, "k1", "cancel-session", "created")

    start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})
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

    assert_receive :cancel_runner_started

    assert %{ok: true} =
             Gateway.handlers(config)["cancel"].(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{}
             })

    assert_receive {:adapter_key, {:claude, ^identity_name, "testhost"}}
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
    base_dir = move_test_base("failure")
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
    base_dir = move_test_base("missing")
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
    base_dir = move_test_base("readiness-denial")

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

  test "set_harness readiness denial leaves Org unchanged", ctx do
    base_dir = role_test_base("harness-unready", false)
    tune = Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["tune"]
    before = Org.get(ctx.db, "k1")

    assert %{code: "host_unready", message: message} =
             tune.(%{
               origin: "user:flynn",
               session_key: "k1",
               params: %{setting: "set_harness", harness: "codex"}
             })

    assert message =~ "no codex credentials"
    assert Org.get(ctx.db, "k1") == before
  end

  test "set_harness keeps an overridden identity name and projects the new harness home", ctx do
    base_dir = role_test_base("harness-override")
    codex_auth = Path.join([base_dir, "auth", "codex"])
    File.mkdir_p!(codex_auth)
    File.write!(Path.join(codex_auth, "auth.json"), "test-token")
    Archetypes.put_skill!(base_dir, "review", "# Review")
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
               params: %{setting: "set_harness", harness: "codex"}
             })

    assert Org.get(ctx.db, "k1").identity_name == identity_name
    home = Path.join([base_dir, "homes", identity_name, "codex"])
    assert File.exists?(Path.join(home, "AGENTS.md"))
    assert JSON.decode!(File.read!(Path.join(home, ".tightbeam-manifest")))["harness"] == "codex"
  end

  test "set_harness delivery failure leaves Org unchanged", ctx do
    base_dir = role_test_base("harness-delivery-failure")
    codex_auth = Path.join([base_dir, "auth", "codex"])
    File.mkdir_p!(codex_auth)
    File.write!(Path.join(codex_auth, "auth.json"), "test-token")
    base = Archetypes.load!(base_dir)["default"]

    identity_name =
      Placement.identity_name(
        %{base_dir: base_dir},
        base,
        %{"guidance_extra" => "First"},
        :claude
      )

    Org.set_identity(ctx.db, "k1", %{"guidance_extra" => "First"}, identity_name)

    Org.create(ctx.db, %{
      session_key: "retired-collision",
      display_name: "Retired collision",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      overrides: %{"guidance_extra" => "Second"},
      identity_name: identity_name,
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })

    Org.retire(ctx.db, "retired-collision")
    before = Org.get(ctx.db, "k1")

    assert_raise ArgumentError, ~r/identity name collision/, fn ->
      Gateway.handlers(gateway_config(base_dir, ctx.db, 0))["tune"].(%{
        origin: "user:flynn",
        session_key: "k1",
        params: %{setting: "set_harness", harness: "codex"}
      })
    end

    assert Org.get(ctx.db, "k1") == before
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

  test "one fake-adapter turn publishes the golden frame order", ctx do
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
        is_admin: false
      })

    base = Path.join(System.tmp_dir!(), "gateway_children_#{System.unique_integer([:positive])}")
    manifests = Path.join([base, "identity", "archetypes"])
    File.mkdir_p!(manifests)

    File.write!(Path.join(manifests, "default.toml"), """
    [mcp.xcodebuild]
    command = "xcodebuildmcp"
    args = ["--daemon"]
    env = { XCODEBUILD_MCP_MODE = "cli" }
    """)

    Archetypes.put_skill!(base, "review", "# Review")

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: "fable",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      db: ctx.db
    }

    children = Gateway.children(config)
    archetype = Archetypes.get("default")

    {:ok, overrides} =
      Archetypes.normalize_overrides(base, archetype, %{"skills_add" => ["review"]})

    identity_name = Placement.identity_name(config, archetype, overrides, :claude)
    Org.set_identity(ctx.db, "k1", overrides, identity_name)

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

    assert_receive {:adapter_key, {:claude, ^identity_name, "testhost"}}

    assert_receive {:new_session_mcp_servers,
                    [
                      %{
                        "name" => "xcodebuild",
                        "command" => "xcodebuildmcp",
                        "args" => ["--daemon"],
                        "env" => [
                          %{"name" => "XCODEBUILD_MCP_MODE", "value" => "cli"}
                        ]
                      }
                    ]}

    assert_receive {:prompt_started, ^adapter}
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

  test "a fallback turn appends the context-reset marker between echo and reply", ctx do
    exact_registry =
      start_supervised!(%{
        id: :marker_conn_registry,
        start: {ConnRegistry, :start_link, [[name: Tightbeam.ConnRegistry]]}
      })

    adapter = start_supervised!({AdapterStub, self()})
    start_supervised!({CoordinatorStub, adapter})

    {:ok, _ref, nil} =
      ConnRegistry.register(exact_registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "marker",
        is_admin: false
      })

    base = Path.join(System.tmp_dir!(), "gateway_children_#{System.unique_integer([:positive])}")

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: "fable",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
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
    assert_receive {:prompt_started, ^adapter}
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

  test "a failed turn appends the [turn failed] marker with the human reason", ctx do
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
        is_admin: false
      })

    base = Path.join(System.tmp_dir!(), "gateway_children_#{System.unique_integer([:positive])}")

    config = %{
      base_dir: base,
      cwd: "/tmp",
      port: 0,
      default_harness: :claude,
      default_model: "fable",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
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

    assert {:error, %{reason: _, terminal_publish: publish}} =
             runner.(Map.put(turn, :session_key, "k1"))

    assert :ok = Ledger.finish(ctx.db, turn.seq, "failed", "boom")
    publish.("failed")

    frames = collect_pushes(10, [])

    marker = Enum.find(frames, &(&1["type"] == "message" and &1["sender"] == "process:tightbeam"))
    assert String.starts_with?(marker["content"], "[turn failed]\n")
    assert marker["content"] =~ "Internal error — auth expired"

    assert Enum.any?(
             frames,
             &match?(
               %{"event" => "prompt_turn_state", "payload" => %{"state" => "failed"}},
               &1
             )
           )
  end

  defp collect_tagged_commands(tag, acc) do
    receive do
      {^tag, command} -> collect_tagged_commands(tag, [command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp gateway_config(base_dir, db, port) do
    %{
      base_dir: base_dir,
      cwd: "/tmp",
      port: port,
      default_harness: :claude,
      default_model: "fable",
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      db: db
    }
  end

  defp role_test_base(suffix, ready? \\ true) do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "gateway_roles_#{suffix}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)

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

  defp create_session(db, session_key, owner_user_id) do
    Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: owner_user_id,
      origin: "user:#{owner_user_id}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })
  end

  defp move_test_base(suffix) do
    base_dir =
      Path.join(System.tmp_dir!(), "gateway_move_#{suffix}_#{System.unique_integer([:positive])}")

    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)

    File.write!(Path.join(manifests, "default.toml"), """
    name = "default"
    where = ["testhost", "worker"]
    """)

    Archetypes.load!(base_dir)
    on_exit(fn -> :persistent_term.erase(Archetypes) end)

    Application.put_env(:tightbeam, :hosts, %{
      "worker" => %{ssh: "worker", base_dir: "/remote/tb", cli_bin: nil}
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
end
