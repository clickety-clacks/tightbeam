defmodule Tightbeam.FirehoseOrgEscalationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Escalation, Model, Org, Schema}
  alias Tightbeam.DB.Txn

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)

    session =
      Org.create(db, %{
        session_key: "firehose-owner",
        display_name: "synthetic",
        owner_user_id: "synthetic-owner",
        origin: "user:synthetic-owner",
        archetype: "default",
        host: "synthetic-host",
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture-model")
      })

    %{db: db, session: session}
  end

  test "holder marker invalidation requires assignment and tenant grants", %{db: db} do
    alias Tightbeam.{Assignments, WorkItems, SubagentMarkers, StateVisibility}
    alias Tightbeam.Firehose.Hub

    base = %{
      origin: "user:synthetic-owner",
      principal: {:user, "synthetic-owner"},
      session_key: nil
    }

    work =
      WorkItems.__handle__(
        db,
        "work-item-create",
        Map.merge(base, %{verb: "work-item-create", params: %{title: "marker grants"}})
      )

    assert %{id: work_id} = work

    assignment =
      Assignments.__handle__(
        db,
        "assign",
        Map.merge(base, %{
          verb: "assign",
          session_key: "firehose-owner",
          target_role: nil,
          role_fallback: false,
          supervision_interval_ms: 1000,
          params: %{subject: "marker grant", work_item_id: work_id}
        })
      )

    assert %{id: assignment_id} = assignment
    hub = start_supervised!({Hub, name: Hub})

    :ok =
      Hub.register(hub, self(), %{mode: :all, db: db, user_id: "synthetic-owner", is_admin: false})

    input = %{
      kind: "subagent_start",
      principal: "firehose-owner",
      subagent_ref: "granted-child",
      source_event_ref: "granted-source",
      harness: "fixture",
      at: 101,
      assignment_id: assignment_id,
      firehose_hub: hub
    }

    assert {:ok, %{appended: true, assignment_id: ^assignment_id}} =
             DB.transaction(db, fn txn -> SubagentMarkers.append_in_txn(txn, input) end)

    assert_receive {:firehose_notice,
                    %{"class" => "subagent_marker.appended", "refs" => refs} = notice}

    assert refs["assignmentId"] == assignment_id
    assert refs["workItemId"] == work_id
    assert StateVisibility.visible?(db, notice, "synthetic-owner", false)
    refute StateVisibility.visible?(db, notice, "different-tenant", false)

    refute StateVisibility.visible?(
             db,
             put_in(notice, ["refs", "assignmentId"], "wrong-assignment"),
             "synthetic-owner",
             false
           )

    Hub.delivered(hub, self())

    :ok =
      Hub.register(hub, self(), %{
        mode: :all,
        db: db,
        user_id: "different-tenant",
        is_admin: false
      })

    GenServer.cast(hub, {:publish, notice})
    refute_receive {:firehose_notice, %{"class" => "subagent_marker.appended"}}
  end

  test "marker publication follows commit dedup and captured assignment", %{db: db} do
    alias Tightbeam.SubagentMarkers
    alias Tightbeam.Firehose.Hub
    hub = start_supervised!({Hub, name: Hub})

    :ok =
      Hub.register(hub, self(), %{mode: :all, db: db, user_id: "synthetic-owner", is_admin: true})

    input = %{
      kind: "subagent_start",
      principal: "firehose-owner",
      subagent_ref: "synthetic-child",
      source_event_ref: "synthetic-source",
      harness: "fixture",
      at: 100,
      assignment_id: nil,
      firehose_hub: self()
    }

    assert {:ok, %{appended: true, assignment_id: nil}} =
             DB.transaction(db, fn txn -> SubagentMarkers.append_in_txn(txn, input) end)

    assert_receive {:"$gen_cast",
                    {:publish, %{"class" => "subagent_marker.appended", "refs" => refs} = notice}}

    assert refs["sessionKey"] == "firehose-owner"
    refute Map.has_key?(refs, "assignmentId")
    refute Tightbeam.StateVisibility.visible?(db, notice, "synthetic-owner", true)
    GenServer.cast(hub, {:publish, notice})
    refute_receive {:firehose_notice, %{"class" => "subagent_marker.appended"}}

    assert {:ok, %{appended: false, assignment_id: nil}} =
             DB.transaction(db, fn txn -> SubagentMarkers.append_in_txn(txn, input) end)

    refute_receive {:"$gen_cast", {:publish, %{"class" => "subagent_marker.appended"}}}
    before = SubagentMarkers.list(db)

    assert {:error, %RuntimeError{message: "marker rollback"}} =
             DB.transaction(db, fn txn ->
               SubagentMarkers.append_in_txn(txn, %{
                 input
                 | source_event_ref: "rollback-source",
                   subagent_ref: "rollback-child"
               })

               raise "marker rollback"
             end)

    assert SubagentMarkers.list(db) == before
    refute_receive {:"$gen_cast", {:publish, %{"class" => "subagent_marker.appended"}}}
  end

  test "connection takeover publishes once and preserves winning generation", %{db: db} do
    alias Tightbeam.ConnRegistry
    alias Tightbeam.Firehose.Hub
    hub = start_supervised!({Hub, name: Hub})

    :ok =
      Hub.register(hub, self(), %{mode: :all, db: db, user_id: "synthetic-owner", is_admin: true})

    reg = start_supervised!({ConnRegistry, name: :firehose_takeover_fixture})

    conn = %{
      pid: self(),
      user_id: "synthetic-owner",
      device_id: "synthetic-device",
      is_admin: true,
      subscriptions: MapSet.new(["chat"])
    }

    assert {:ok, old, nil} = ConnRegistry.register(reg, conn)
    refute_receive {:firehose_notice, %{"class" => "lifecycle.takeover"}}
    assert {:ok, current, ^old} = ConnRegistry.register(reg, conn)
    assert_receive {:firehose_notice, %{"class" => "lifecycle.takeover", "refs" => refs}}
    assert refs["deviceId"] == "synthetic-device"
    assert refs["userId"] == "synthetic-owner"
    Hub.delivered(hub, self())
    ConnRegistry.unregister(reg, old)
    state = :sys.get_state(reg)
    assert Map.has_key?(state.conns, current)
    refute Map.has_key?(state.conns, old)
    assert map_size(state.conns) == 1
    refute_receive {:firehose_notice, %{"class" => "lifecycle.takeover"}}
  end

  test "admin transitions publish distinct canonical events and preserve demotion", %{db: db} do
    alias Tightbeam.{Devices, Dispatch, StateResources}
    alias Tightbeam.Firehose.Hub
    Devices.add_user(db, "synthetic-owner", true)
    Devices.add_user(db, "target-user", false)
    hub = start_supervised!({Hub, name: Hub})

    :ok =
      Hub.register(hub, self(), %{mode: :all, db: db, user_id: "synthetic-owner", is_admin: true})

    handlers = Tightbeam.Gateway.handlers(%{db: db})

    call = %{
      verb: "promote-user",
      origin: "user:synthetic-owner",
      principal: {:user, "synthetic-owner"},
      session_key: nil,
      params: %{user_id: "target-user"},
      firehose_hub: hub
    }

    for {admin, class} <- [{true, "user.promoted"}, {false, "user.demoted"}] do
      current = put_in(call.params, %{user_id: "target-user", is_admin: admin})
      assert {:ok, %{user: public, changed: true}} = Dispatch.dispatch(db, handlers, current)
      assert public["isAdmin"] == admin
      assert Devices.user(db, "target-user").is_admin == admin
      assert public == StateResources.user(StateResources.query_user(db, "target-user"))
      assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
      Hub.delivered(hub, self())
      assert_receive {:firehose_notice, %{"class" => ^class, "payload" => ^public}}
      Hub.delivered(hub, self())
      assert {:ok, %{changed: false, user: ^public}} = Dispatch.dispatch(db, handlers, current)
      assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
      Hub.delivered(hub, self())
      refute_receive {:firehose_notice, %{"class" => ^class}}
    end

    denied = %{call | origin: "user:target-user", principal: {:user, "target-user"}}
    assert {:error, %{code: "forbidden"}} = Dispatch.dispatch(db, handlers, denied)
    refute Devices.user(db, "target-user").is_admin
  end

  test "default archetype config publishes once and rejects unknown names", %{db: db} do
    alias Tightbeam.{Devices, Dispatch}
    alias Tightbeam.Firehose.Hub
    previous = :persistent_term.get(Tightbeam.Archetypes, :absent)

    base =
      Path.join(System.tmp_dir!(), "firehose-archetypes-#{System.unique_integer([:positive])}")

    Tightbeam.Archetypes.load!(base)

    on_exit(fn ->
      if previous == :absent,
        do: :persistent_term.erase(Tightbeam.Archetypes),
        else: :persistent_term.put(Tightbeam.Archetypes, previous)
    end)

    assert Tightbeam.Archetypes.get("default")
    Devices.add_user(db, "synthetic-owner", true)
    hub = start_supervised!({Hub, name: Hub})

    :ok =
      Hub.register(hub, self(), %{
        mode: :all,
        db: db,
        user_id: "synthetic-owner",
        is_admin: true
      })

    handlers = Tightbeam.Gateway.handlers(%{db: db})

    call = %{
      verb: "config",
      origin: "user:synthetic-owner",
      principal: {:user, "synthetic-owner"},
      session_key: nil,
      params: %{action: "set", setting: "default-archetype", value: "default"},
      firehose_hub: hub
    }

    assert {:ok, %{value: "default", changed: true, config: public}} =
             Dispatch.dispatch(db, handlers, call)

    assert Org.get_setting(db, "default-archetype") == "default"
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "config.updated", "payload" => ^public}}
    Hub.delivered(hub, self())
    assert {:ok, %{changed: false, config: ^public}} = Dispatch.dispatch(db, handlers, call)
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, %{"class" => "config.updated"}}

    assert {:error, %{code: "unknown_archetype"}} =
             Dispatch.dispatch(
               db,
               handlers,
               put_in(call.params.value, "missing-firehose-archetype")
             )

    assert Org.get_setting(db, "default-archetype") == "default"

    assert {:ok, %{value: "default", config: ^public}} =
             Dispatch.dispatch(
               db,
               handlers,
               put_in(call.params, %{action: "get", setting: "default-archetype"})
             )
  end

  test "config and add-user handlers publish exact committed values with admin checks", %{db: db} do
    alias Tightbeam.{Devices, Dispatch}
    alias Tightbeam.Firehose.Hub
    Devices.add_user(db, "synthetic-owner", true)
    hub = start_supervised!({Hub, name: Hub})

    :ok =
      Hub.register(hub, self(), %{mode: :all, db: db, user_id: "synthetic-owner", is_admin: true})

    handlers = Tightbeam.Gateway.handlers(%{db: db})

    call = %{
      verb: "add-user",
      origin: "user:synthetic-owner",
      principal: {:user, "synthetic-owner"},
      session_key: nil,
      params: %{user_id: "new-user", is_admin: false},
      firehose_hub: hub
    }

    assert {:ok, %{user: user}} = Dispatch.dispatch(db, handlers, call)
    assert user["userId"] == "new-user"
    assert user["isAdmin"] == false
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "user.added", "payload" => ^user}}
    Hub.delivered(hub, self())

    config = %{
      call
      | verb: "config",
        params: %{action: "set", setting: "default-priority", value: 6}
    }

    denied = %{config | origin: "user:new-user", principal: {:user, "new-user"}}
    assert {:error, %{code: "forbidden"}} = Dispatch.dispatch(db, handlers, denied)
    assert_receive {:firehose_notice, %{"class" => "verb.denied"}}
    Hub.delivered(hub, self())

    assert {:ok, %{value: 6, changed: true, config: public}} =
             Dispatch.dispatch(db, handlers, config)

    assert Org.get_setting(db, "default-priority") == "6"
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "config.updated", "payload" => ^public}}
    Hub.delivered(hub, self())
    assert {:ok, %{changed: false, config: ^public}} = Dispatch.dispatch(db, handlers, config)
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, %{"class" => "config.updated"}}

    assert {:error, %{code: "invalid_priority"}} =
             Dispatch.dispatch(db, handlers, put_in(config.params.value, 9))

    assert Org.get_setting(db, "default-priority") == "6"
  end

  test "host overlay failure rolls back private row projection version and notices", %{db: db} do
    alias Tightbeam.{Placement, StateResources, AdminProjection}
    alias Tightbeam.Firehose.Hub

    {:ok, _} =
      Placement.register_host(db, "rollback-host", %{ssh: "never", base_dir: "/synthetic"})

    call = %{
      verb: "host-env-set",
      origin: "user:synthetic-owner",
      principal: {:user, "synthetic-owner"},
      session_key: nil,
      params: %{host: "rollback-host", harness: "fixture", name: "SAFE_SETTING"}
    }

    assert %{changed: true} =
             Placement.set_env_overlay_with_firehose(
               db,
               "rollback-host",
               "fixture",
               "SAFE_SETTING",
               "before",
               call.origin,
               call
             )

    before = Placement.env_overlays(db, "rollback-host", "fixture")

    projection =
      StateResources.query_host_environment(db, "rollback-host", "fixture", "SAFE_SETTING")

    version =
      AdminProjection.version(db, "host environment", ["rollback-host", "fixture", "SAFE_SETTING"])

    hub = start_supervised!({Hub, name: Hub})

    :ok =
      Hub.register(hub, self(), %{mode: :all, db: db, user_id: "synthetic-owner", is_admin: true})

    call = Map.merge(call, %{firehose_in_txn: true, firehose_hub: hub})

    assert {:error, %{code: "reserved_env_name"}} =
             Placement.set_env_overlay_with_firehose(
               db,
               "rollback-host",
               "fixture",
               "TIGHTBEAM_SYNTHETIC",
               "value",
               call.origin,
               call
             )

    assert {:error, %{code: "unknown_host"}} =
             Placement.set_env_overlay_with_firehose(
               db,
               "absent-host",
               "fixture",
               "SAFE_SETTING",
               "value",
               call.origin,
               call
             )

    :ok =
      DB.execute(db, """
      CREATE TRIGGER synthetic_host_projection_failure BEFORE INSERT ON host_environment_projection
      BEGIN SELECT RAISE(ABORT, 'synthetic projection failure'); END;
      """)

    assert_raise Tightbeam.DB.Error, "synthetic projection failure", fn ->
      Placement.set_env_overlay_with_firehose(
        db,
        "rollback-host",
        "fixture",
        "SAFE_SETTING",
        "after",
        call.origin,
        call
      )
    end

    assert Placement.env_overlays(db, "rollback-host", "fixture") == before

    assert StateResources.query_host_environment(db, "rollback-host", "fixture", "SAFE_SETTING") ==
             projection

    assert AdminProjection.version(db, "host environment", [
             "rollback-host",
             "fixture",
             "SAFE_SETTING"
           ]) == version

    refute_receive {:firehose_notice, _}
  end

  test "host environment handlers publish value-free changes and preserve no-op admin boundaries",
       %{db: db} do
    alias Tightbeam.{Devices, Dispatch, Placement}
    alias Tightbeam.Firehose.Hub
    Devices.add_user(db, "synthetic-owner", true)
    hub = start_supervised!({Hub, name: Hub})

    :ok =
      Hub.register(hub, self(), %{mode: :all, db: db, user_id: "synthetic-owner", is_admin: true})

    registration_call = %{
      verb: "register-host",
      origin: "user:synthetic-owner",
      principal: {:user, "synthetic-owner"},
      session_key: nil,
      params: %{name: "synthetic-host"},
      firehose_hub: hub,
      firehose_in_txn: true
    }

    assert {:ok, %{changed: true}} =
             Placement.register_host_with_firehose(
               db,
               "synthetic-host",
               %{ssh: "never-execute", base_dir: "/synthetic-only"},
               registration_call
             )

    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "host.registered"}}
    Hub.delivered(hub, self())
    handlers = Tightbeam.Gateway.handlers(%{db: db})

    call = %{
      verb: "host-env-set",
      origin: "user:outsider",
      principal: {:user, "outsider"},
      session_key: nil,
      params: %{
        host: "synthetic-host",
        harness: "fixture",
        name: "SYNTHETIC_SETTING",
        value: "synthetic-private-value"
      },
      firehose_hub: hub
    }

    assert {:error, %{code: "forbidden"}} = Dispatch.dispatch(db, handlers, call)
    assert Placement.env_overlays(db, "synthetic-host", "fixture") == []
    assert_receive {:firehose_notice, %{"class" => "verb.denied"}}
    Hub.delivered(hub, self())
    call = %{call | origin: "user:synthetic-owner", principal: {:user, "synthetic-owner"}}

    assert {:ok, %{changed: true, host_environment: public}} =
             Dispatch.dispatch(db, handlers, call)

    assert public["value"] == nil
    assert public["valuePresent"] == true
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "host_env.updated", "payload" => payload}}
    refute inspect(payload) =~ "synthetic-private-value"
    Hub.delivered(hub, self())
    assert {:ok, %{changed: false}} = Dispatch.dispatch(db, handlers, call)
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, %{"class" => "host_env.updated"}}

    assert {:ok, %{overlays: [^public]}} =
             Dispatch.dispatch(db, handlers, %{call | verb: "host-env-list"})

    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())

    assert {:ok, %{changed: true, host_environment: cleared}} =
             Dispatch.dispatch(db, handlers, %{call | verb: "host-env-unset"})

    assert cleared["value"] == nil
    assert cleared["valuePresent"] == false
    assert cleared["rowVersion"] > public["rowVersion"]
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "host_env.updated"}}
    Hub.delivered(hub, self())
  end

  test "device handlers preserve admin refusal and publish committed public versions", %{db: db} do
    alias Tightbeam.{Devices, Dispatch, StateResources}
    alias Tightbeam.Firehose.Hub
    Devices.add_user(db, "synthetic-owner", true)

    Devices.pair(db, %{
      device_id: "first-admin",
      claimed_name: "synthetic",
      platform: nil,
      model: nil
    })

    hub = start_supervised!({Hub, name: nil})

    :ok =
      Hub.register(hub, self(), %{mode: :all, db: db, user_id: "synthetic-owner", is_admin: true})

    handlers = Tightbeam.Gateway.handlers(%{db: db})

    for {verb, class} <- [
          {"approve-device", "device.approved"},
          {"deny-device", "device.denied"},
          {"revoke-device", "device.revoked"}
        ] do
      id = "synthetic-" <> verb
      Devices.pair(db, %{device_id: id, claimed_name: "synthetic", platform: nil, model: nil})
      before = StateResources.query_device(db, id)

      call = %{
        verb: verb,
        origin: "user:outsider",
        principal: {:user, "outsider"},
        session_key: nil,
        params: %{device_id: id, user_id: "synthetic-owner"},
        firehose_hub: hub
      }

      assert {:error, %{code: "forbidden"}} = Dispatch.dispatch(db, handlers, call)
      assert StateResources.query_device(db, id) == before
      assert_receive {:firehose_notice, %{"class" => "verb.denied"}}
      Hub.delivered(hub, self())
      allowed = %{call | origin: "user:synthetic-owner", principal: {:user, "synthetic-owner"}}
      assert {:ok, _} = Dispatch.dispatch(db, handlers, allowed)
      assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
      Hub.delivered(hub, self())
      assert_receive {:firehose_notice, %{"class" => ^class, "payload" => payload}}
      assert payload["deviceId"] == id
      refute Map.has_key?(payload, "token")
      current = StateResources.query_device(db, id)
      assert payload == StateResources.device(current)
      assert payload["rowVersion"] > StateResources.device(before)["rowVersion"]
      Hub.delivered(hub, self())
      refute_receive {:firehose_notice, %{"class" => ^class}}
    end
  end

  test "gateway decision handlers commit answers and returns with immutable replay", %{db: db} do
    alias Tightbeam.Firehose.Hub
    hub = start_supervised!({Hub, name: nil})

    :ok =
      Hub.register(hub, self(), %{mode: :all, db: db, user_id: "synthetic-owner", is_admin: true})

    Org.create(db, %{
      session_key: "decision-reader",
      display_name: "reader",
      owner_user_id: "synthetic-owner",
      origin: "user:synthetic-owner",
      archetype: "default",
      host: "synthetic-host",
      harness: "fixture",
      provider: "fixture_provider",
      model: Model.new("fixture-model")
    })

    handlers = Tightbeam.Gateway.handlers(%{db: db})

    for {verb, field, text, status, class} <- [
          {"answer", :answer, "Actual answer", "answered", "decision_request.ruled"},
          {"return", :reason, "Need exact source", "returned", "decision_request.returned"}
        ] do
      ask = %{
        verb: "ask",
        origin: "agent:firehose-owner",
        principal: {:session, "firehose-owner"},
        session_key: "decision-reader",
        transport_session_key: "firehose-owner",
        params: %{question: "Which source?"},
        firehose_hub: hub
      }

      assert {:ok, request} = Tightbeam.Dispatch.dispatch(db, handlers, ask)
      assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
      Hub.delivered(hub, self())
      assert request.status == "open"
      id = request.id

      assert_receive {:firehose_notice,
                      %{"class" => "decision_request.opened", "payload" => opened}}

      assert opened["id"] == id
      Hub.delivered(hub, self())

      reply = %{
        ask
        | verb: verb,
          origin: "agent:decision-reader",
          principal: {:session, "decision-reader"},
          transport_session_key: "decision-reader",
          session_key: "decision-reader",
          params: Map.put(%{request: id}, field, text)
      }

      assert {:ok, result} = Tightbeam.Dispatch.dispatch(db, handlers, reply)
      assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
      Hub.delivered(hub, self())
      assert result.status == status
      assert result.row_version > request.row_version
      assert_receive {:firehose_notice, %{"class" => ^class, "payload" => payload}}
      assert payload["id"] == id
      assert payload["rowVersion"] == result.row_version
      Hub.delivered(hub, self())
      assert {:ok, ^result} = Tightbeam.Dispatch.dispatch(db, handlers, reply)
      assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
      Hub.delivered(hub, self())
      assert Escalation.raw_by_id(db, id) == result
      refute_receive {:firehose_notice, %{"class" => ^class}}

      assert {:ok, [[0]]} =
               DB.query(
                 db,
                 "SELECT COUNT(*) FROM condition_facts WHERE kind='escalation-ruled' AND scope=?1",
                 [id]
               )
    end
  end

  test "missing gateway routes preserve read-marker owner CAS and decision refusals", %{db: db} do
    Tightbeam.Roles.create!(db, "firehose-owner", "synthetic-owner", "firehose-owner")
    handlers = Tightbeam.Gateway.handlers(%{db: db})

    call = %{
      origin: "agent:firehose-owner",
      principal: {:session, "firehose-owner"},
      session_key: "firehose-owner",
      params: %{scope_key: "scope", marker: "first"}
    }

    assert %{changed: true, user_id: "synthetic-owner"} = handlers["read-marker-set"].(call)
    before = Tightbeam.ReadMarkers.get(db, "synthetic-owner", "scope")
    assert %{changed: false} = handlers["read-marker-set"].(call)
    assert Tightbeam.ReadMarkers.get(db, "synthetic-owner", "scope") == before
    stale = put_in(call.params, %{scope_key: "scope", marker: "next", expected_current: "stale"})
    assert %{code: "read_marker_conflict"} = handlers["read-marker-set"].(stale)
    assert Tightbeam.ReadMarkers.get(db, "synthetic-owner", "scope") == before

    assert %{code: "unknown_caller"} =
             handlers["read-marker-set"].(%{call | origin: "agent:missing"})

    assert %{code: "invalid"} =
             handlers["read-marker-set"].(put_in(call.params.marker, -1))

    assert %{changed: true} =
             handlers["read-marker-clear"].(
               put_in(call.params, %{scope_key: "scope", expected_current: "first"})
             )

    assert %{marker: nil} = Tightbeam.ReadMarkers.get(db, "synthetic-owner", "scope")
    assert Tightbeam.ReadMarkers.get(db, "another-owner", "scope") == nil

    for verb <- ["answer", "return"] do
      denied = %{call | params: %{request: "missing", answer: "answer", reason: "reason"}}
      assert %{code: "not_found"} = handlers[verb].(denied)
    end

    user_ask = %{
      call
      | origin: "user:synthetic-owner",
        principal: {:user, "synthetic-owner"},
        params: %{question: "Question?"}
    }

    assert %{code: _} = handlers["ask"].(user_ask)
  end

  test "transactional decision reads retain version, nullable fields and rollback", %{db: db} do
    :ok =
      DB.execute(db, """
      INSERT INTO decision_requests(id,kind,raiserId,ownerUserId,raisedAt,deadlineAt,
        statuteName,actionKey,question,context,status)
      VALUES ('dr-synthetic','statute','session:firehose-owner','synthetic-owner',1,2,
        'synthetic-law','synthetic-action','Question?','{}','open')
      """)

    before = Escalation.raw_by_id(db, "dr-synthetic")
    assert before.row_version == 1
    assert before.answer == nil
    assert before.return_reason == nil
    assert {:ok, ^before} = DB.transaction(db, &Escalation.raw_by_id_in_txn(&1, "dr-synthetic"))
    assert {:ok, nil} = DB.transaction(db, &Escalation.raw_by_id_in_txn(&1, "missing"))

    assert {:error, %RuntimeError{message: "rollback decision"}} =
             DB.transaction(db, fn txn ->
               Txn.q(
                 txn,
                 "UPDATE decision_requests SET rationale='changed' WHERE id='dr-synthetic'"
               )

               changed = Escalation.raw_by_id_in_txn(txn, "dr-synthetic")
               assert changed.row_version == 2
               assert changed.rationale == "changed"
               raise "rollback decision"
             end)

    assert Escalation.raw_by_id(db, "dr-synthetic") == before

    assert {:ok, 2} =
             DB.transaction(db, fn txn ->
               Txn.q(
                 txn,
                 "UPDATE decision_requests SET rationale='committed' WHERE id='dr-synthetic'"
               )

               changed = Escalation.raw_by_id_in_txn(txn, "dr-synthetic")

               Txn.q(
                 txn,
                 "UPDATE decision_requests SET rationale=rationale WHERE id='dr-synthetic'"
               )

               assert Escalation.raw_by_id_in_txn(txn, "dr-synthetic") == changed
               changed.row_version
             end)

    assert Escalation.principal_id({:process, "tightbeam"}) == "process:tightbeam"

    assert Escalation.principal_id(%{principal: {:session, "firehose-owner"}}) ==
             "session:firehose-owner"
  end

  test "real ruling publishes its committed version once and replay is observation only", %{
    db: db
  } do
    alias Tightbeam.Firehose.Hub
    hub = start_supervised!({Hub, name: nil})

    :ok =
      Hub.register(hub, self(), %{mode: :all, db: db, user_id: "synthetic-owner", is_admin: true})

    :ok =
      DB.execute(db, """
      INSERT INTO decision_requests(id,kind,raiserId,ownerUserId,raisedAt,deadlineAt,
        statuteName,actionKey,question,context,status)
      VALUES ('dr-publish','statute','session:firehose-owner','synthetic-owner',1,2,
        'synthetic-law','publish','Question?','{}','open')
      """)

    call = %{
      verb: "rule",
      origin: "user:synthetic-owner",
      principal: {:user, "synthetic-owner"},
      params: %{request_id: "dr-publish", decision: "allow"},
      firehose_in_txn: true,
      firehose_hub: hub
    }

    ruled = Escalation.rule(db, call, authorized: true)
    assert ruled.status == "ruled"
    assert ruled.row_version == 2
    assert ruled == Escalation.raw_by_id(db, "dr-publish")
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())

    assert_receive {:firehose_notice,
                    %{"class" => "decision_request.ruled", "payload" => payload}}

    assert payload["id"] == "dr-publish"
    assert payload["rowVersion"] == ruled.row_version
    Hub.delivered(hub, self())
    assert Escalation.rule(db, call, authorized: true) == ruled
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, _}

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='escalation-ruled' AND scope='dr-publish'"
             )

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject='dr-publish'"
             )
  end

  test "owner and mechanical reads share transaction and rollback without false version changes",
       %{db: db, session: session} do
    key = session.session_key
    assert session.mechanical_status == "idle"

    assert {:error, %RuntimeError{message: "rollback session"}} =
             DB.transaction(db, fn txn ->
               assert Org.owner_user_id_in_txn(txn, key) == "synthetic-owner"
               assert Org.owner_user_id_in_txn(txn, "missing") == nil
               assert Org.get_in_txn(txn, key) == session
               changed = Org.set_host_in_txn(txn, key, "next-synthetic-host")
               assert changed.updated_at > session.updated_at
               assert Org.get_in_txn(txn, key).host == "next-synthetic-host"
               raise "rollback session"
             end)

    assert Org.get(db, key) == session

    assert {:ok, running} =
             DB.transaction(db, fn txn ->
               Txn.q(
                 txn,
                 "INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt) VALUES (?1,'synthetic-message','user:synthetic-owner','synthetic','queued',1)",
                 [key]
               )

               changed = Org.sync_mechanical_status_in_txn(txn, key)
               assert changed.mechanical_status == "running"
               assert changed.updated_at > session.updated_at
               assert Org.sync_mechanical_status_in_txn(txn, key) == changed
               changed
             end)

    assert Org.get(db, key) == running

    assert {:ok, idle} =
             DB.transaction(db, fn txn ->
               Txn.q(
                 txn,
                 "UPDATE turns SET status='failed_unknown',error='interrupted: outcome unknown' WHERE sessionKey=?1",
                 [key]
               )

               Org.sync_mechanical_status_in_txn(txn, key)
             end)

    assert idle.mechanical_status == "idle"
    assert idle.updated_at > running.updated_at

    assert {:ok, [["failed_unknown", "interrupted: outcome unknown"]]} =
             DB.query(db, "SELECT status,error FROM turns WHERE sessionKey=?1", [key])
  end
end
