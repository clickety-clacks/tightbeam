defmodule ItemlessSpawnDoorbell do
  use GenServer

  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule ItemlessSpawnDispatchRuntime do
  import ExUnit.Assertions

  alias Tightbeam.{
    Assignments,
    Archetypes,
    DB,
    Dispatch,
    Ephemeral,
    Gateway,
    Identity,
    Ledger,
    Model,
    NoticeBatcher,
    Org,
    Projection,
    Rules,
    WorkItems,
    Wakes
  }

  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

  @staffing_rule "agentic-engineering.engineering-spawn-staffing-needs-work-item"
  @staffing_message "#{@staffing_rule}: Worker staffing requires a known work item. Create or link the work item before retrying."

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: initial_config, base: base} ->
      {:ok, candidate} = Identity.learn!(base, "agentic-engineering", "test")
      {:ok, _revision} = Identity.publish_live!(base, candidate)

      helper_candidate =
        Identity.edit!(base, "helper", :manifest, "name = \"helper\"\nephemeral = true\n", "test")

      {:ok, _revision} = Identity.publish_live!(base, helper_candidate)
      install_fixture_adapter!(base)
      archetypes = Archetypes.load!(base)

      config =
        initial_config
        |> Map.put(:credential_status, fn _provider -> :onboarded end)
        |> Map.put(:credential_kind, fn _provider -> :subscription end)

      handlers = Gateway.handlers(config)
      rules = Rules.load!(base, Map.keys(handlers))
      assert Enum.any?(rules, &(&1.name == @staffing_rule))
      report_loaded_rule_set!(base)

      :ok =
        DB.execute(
          db,
          "INSERT OR IGNORE INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1)"
        )

      for {key, archetype} <- [
            {"caller", "pdo"},
            {"default-caller", "default"},
            {"unqualified", "default"},
            {"coordinator", "pdo"},
            {"engineering-caller", "agentic-engineering.orchestrator"},
            {"engineering-unqualified", "agentic-engineering.orchestrator"}
          ] do
        Org.create(db, %{
          session_key: key,
          display_name: key,
          owner_user_id: "owner",
          origin: "user:owner",
          archetype: archetype,
          host: "testhost",
          harness: "fixture",
          provider: "fixture_provider",
          model: Model.new("fixture-model")
        })
      end

      :ok =
        DB.execute(
          db,
          "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt) VALUES ('caller-open','WI3FE helper scope','caller','owner',1)"
        )

      assert {:ok, [["open"]]} =
               DB.query(db, "SELECT state FROM assignments WHERE id='caller-open'")

      :ok =
        DB.execute(
          db,
          "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt) VALUES ('engineering-open','Helper scope','engineering-caller','owner',1)"
        )

      :ok =
        DB.execute(
          db,
          "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt) VALUES ('default-open','Helper scope','default-caller','owner',1)"
        )

      # R4 is unreachable with shipped archetypes. Inspect the loaded rule and
      # its real archetypes; do not invent an engineering helper to exercise it.
      staffing = Enum.find(rules, &(&1.name == @staffing_rule))
      for name <- staffing.archetypes, do: refute(archetypes[name].ephemeral)

      assert Enum.any?(staffing.conditions, fn condition ->
               condition.fact == "spawn.itemless_ephemeral_caller_qualified" and
                 condition.op == "eq" and condition.value == false
             end)

      IO.puts("R4: unreachable with shipped archetypes; no staffing participant is ephemeral")
      IO.puts("adapter: synthetic; real model turn unproven")

      # R1/R2: both engineering and substrate callers use the actual session route.
      for caller <- ["caller", "engineering-caller"] do
        helper_call = spawn_call(caller, "session:#{caller}", "helper")
        session_count_before = count_sessions(db)
        assert {:ok, helper} = Dispatch.dispatch(db, handlers, helper_call)
        helper_key = helper.session_key
        assert Org.get(db, helper_key).state == "active"
        assert Ephemeral.caller(db, helper_key) == caller
        assert count_sessions(db) == session_count_before + 1

        assert {:ok, [[0]]} =
                 DB.query(
                   db,
                   "SELECT COUNT(*) FROM events WHERE kind='denied' AND verb='spawn' AND origin=?1",
                   ["session:#{caller}"]
                 )

        assert {:ok, [[0]]} =
                 DB.query(db, "SELECT COUNT(*) FROM assignments WHERE holderKey=?1", [helper_key])

        deliver_helper_result!(config, db, helper_key, caller)
      end

      # R3 holds whether or not the engineering caller has an open assignment.
      for caller <- ["engineering-caller", "engineering-unqualified"] do
        assert_exact_staffing_refusal!(
          db,
          handlers,
          spawn_call(caller, "session:#{caller}", "agentic-engineering.coder")
        )
      end

      # R7: substrate participants never receive the engineering rail's refusal.
      assert_substrate_staffing_refusal!(
        db,
        handlers,
        spawn_call("unqualified", "session:unqualified", "helper")
      )

      assert_substrate_staffing_refusal!(
        db,
        handlers,
        spawn_call("default-caller", "session:default-caller", "agentic-engineering.coder")
        |> Map.update!(:params, &Map.merge(&1, %{harness: "fixture", model: "fixture-model"}))
      )

      count_before = count_sessions(db)

      assert {:error, %{code: "qualified_archetype_required", message: message}} =
               Dispatch.dispatch(
                 db,
                 handlers,
                 spawn_call("unqualified", "session:unqualified", "coder")
               )

      assert message =~ "agentic-engineering.coder"
      assert count_sessions(db) == count_before

      # R5 is independent of the caller's archetype.
      for caller <- ["caller", "engineering-caller"] do
        assert_ephemeral_obligation_refusal!(db, handlers, caller)
      end
    end)
  end

  defp report_loaded_rule_set!(base) do
    shipped = Application.app_dir(:tightbeam, "priv")

    expected =
      (Path.wildcard(Path.join([shipped, "seed", "rules", "*.toml"])) ++
         Path.wildcard(Path.join([shipped, "kungfu", "agentic-engineering", "rules", "*.toml"])))
      |> Enum.map(fn path ->
        relative = Path.relative_to(path, shipped)

        String.replace_prefix(relative, "seed/", "identity/")
        |> String.replace_prefix("kungfu/", "identity/kungfu/")
      end)
      |> Enum.sort()

    files =
      (Path.wildcard(Path.join([base, "identity", "rules", "*.toml"])) ++
         Path.wildcard(Path.join([base, "identity", "kungfu", "*", "rules", "*.toml"])))
      |> Enum.sort()

    assert Enum.map(files, &Path.relative_to(&1, base)) == expected

    hashes =
      Enum.map(files, fn path ->
        sha256 =
          path
          |> File.read!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        %{path: Path.relative_to(path, base), sha256: sha256}
      end)

    IO.puts("loaded-rule-set: #{JSON.encode!(hashes)}")
  end

  defp spawn_call(caller, origin, archetype) do
    %{
      verb: "spawn",
      origin: origin,
      principal: {:session, caller},
      session_key: nil,
      params: %{
        display_name: "WI3FE #{archetype}",
        archetype: archetype,
        idempotency_key: "wi3fe-#{caller}-#{archetype}"
      }
    }
  end

  defp install_fixture_adapter!(base) do
    adapter = Path.join([base, "adapters", "node_modules", ".bin", "fixture-acp"])

    package_dir =
      Path.join([base, "adapters", "node_modules", "@agentclientprotocol", "fixture-acp"])

    package = Path.join(package_dir, "package.json")
    bundle = Path.join([package_dir, "dist", "fixture.js"])
    credential = Path.join([base, "homes", "testhost", "fixture", "fixture.json"])

    File.mkdir_p!(Path.dirname(adapter))
    File.write!(adapter, "#!/bin/sh\nexit 0\n")
    File.chmod!(adapter, 0o755)
    File.mkdir_p!(Path.dirname(package))
    File.write!(package, JSON.encode!(%{"version" => "1.0.0"}))
    File.mkdir_p!(Path.dirname(bundle))
    File.write!(bundle, "fixture-anchor")
    File.mkdir_p!(Path.dirname(credential))
    File.write!(credential, "fixture-provider-credential")
  end

  defp assert_exact_staffing_refusal!(db, handlers, call) do
    count_before = count_sessions(db)

    assert {:error, %{code: "rule_denied", rule: @staffing_rule, message: @staffing_message}} =
             Dispatch.dispatch(db, handlers, call)

    assert count_sessions(db) == count_before
  end

  defp assert_substrate_staffing_refusal!(db, handlers, call) do
    count_before = count_sessions(db)

    assert {:error, %{code: "work_item_required", message: message}} =
             Dispatch.dispatch(db, handlers, call)

    assert message ==
             "production staffing requires an exact work item; create or link the item before staffing"

    assert count_sessions(db) == count_before
  end

  defp assert_ephemeral_obligation_refusal!(db, handlers, caller) do
    item =
      WorkItems.__handle__(db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:owner",
        principal: {:user, "owner"},
        params: %{title: "WI3FE linked helper refusal"}
      })

    assert is_binary(item.id)

    assert %{deliveryOwnerSessionKey: "coordinator"} =
             WorkItems.__handle__(db, "work-item-update", %{
               verb: "work-item-update",
               origin: "user:owner",
               principal: {:user, "owner"},
               params: %{work_item_id: item.id, delivery_owner_session_key: "coordinator"}
             })

    assignment =
      Assignments.__handle__(db, "assign", %{
        verb: "assign",
        origin: "agent:coordinator",
        principal: {:session, "coordinator"},
        session_key: "coordinator",
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{
          subject: "Return attributable topology",
          brief: "Decide the synthetic staffing topology.",
          idempotency_key: nil,
          work_item_id: item.id,
          effect_kind: "coordination",
          reviews_assignment_id: nil,
          files: nil
        }
      })

    assert is_binary(assignment.id)

    assert %{attest: %{verdictKind: "topology-decided"}} =
             Assignments.__handle__(db, "attest", %{
               verb: "attest",
               origin: "agent:coordinator",
               principal: {:session, "coordinator"},
               params: %{
                 assignment_id: assignment.id,
                 kind: "verdict",
                 verdict_kind: "topology-decided",
                 note: "One synthetic worker for the linked helper control."
               }
             })

    count_before = count_sessions(db)
    call = spawn_call(caller, "session:#{caller}", "helper")
    call = %{call | params: Map.put(call.params, :work_item_id, item.id)}

    call = %{
      call
      | params: Map.put(call.params, :idempotency_key, "wi3fe-linked-helper-#{caller}")
    }

    assert {:error,
            %{code: "ephemeral_obligation", message: "ephemeral spawns cannot bind work items"}} =
             Dispatch.dispatch(db, handlers, call)

    assert count_sessions(db) == count_before
  end

  defp deliver_helper_result!(config, db, helper_key, caller) do
    {:ok, lane} = GenServer.start_link(ItemlessSpawnDoorbell, self())
    {:ok, adapter} = AdapterStub.start_link(self())
    {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})

    try do
      {Tightbeam.LaneManager, opts} =
        Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

      runner = Keyword.fetch!(opts, :runner)

      {:appended, message} =
        Projection.append(db, %{
          session_key: helper_key,
          role: "user",
          content: "inspection: 3 files"
        })

      {:ok, seq} =
        Ledger.enqueue(db, %{
          session_key: helper_key,
          message_id: message.id,
          origin: "session:#{caller}",
          prompt: "inspection: 3 files"
        })

      {:ok, turn} = Ledger.claim_next(db, helper_key, "test")
      task = Task.async(fn -> runner.(Map.put(turn, :session_key, helper_key)) end)
      assert_receive {:prompt_started, ^adapter}, 60_000
      send(adapter, :continue_prompt)
      assert {:ok, %{record_in_txn: record}} = Task.await(task)
      assert :ok = Tightbeam.GatewayTurnFixture.commit_success!(db, turn, record)

      assert Org.get(db, helper_key).state == "retired"
      assert Wakes.get(db, "ephemeral-result:" <> helper_key).session_key == caller

      assert Wakes.get(db, "ephemeral-result:" <> helper_key).prompt ==
               "Ephemeral spawn result from #{helper_key}:\n\nINSPECTION: 3 FILES"

      assert :already_terminal = Ledger.finish(db, seq, "delivered")

      NoticeBatcher.recover(db, System.system_time(:millisecond) + 1_000,
        conn_registry: Tightbeam.ConnRegistry,
        lane_manager: lane
      )

      result_wake_id = "ephemeral-result:" <> helper_key

      assert {:ok, [[^caller, delivered_content]]} =
               DB.query(
                 db,
                 """
                 SELECT t.sessionKey,m.content
                 FROM wakes w JOIN turns t ON t.seq=w.deliveredTurnSeq
                 JOIN messages m ON m.id=t.messageId
                 WHERE w.wakeId=?1
                 """,
                 [result_wake_id]
               )

      assert delivered_content =~ "INSPECTION: 3 FILES"

      assert {:ok, [[1]]} =
               DB.query(
                 db,
                 "SELECT COUNT(*) FROM wakes WHERE wakeId=?1 AND deliveredTurnSeq IS NOT NULL",
                 [result_wake_id]
               )

      assert {:ok, returned} = Ledger.claim_next(db, caller, "test")
      assert returned.prompt =~ "INSPECTION: 3 FILES"

      assert {:ok, [[1]]} =
               DB.query(db, "SELECT COUNT(*) FROM wakes WHERE wakeId=?1", [result_wake_id])
    after
      GenServer.stop(coordinator)
      GenServer.stop(adapter)
      GenServer.stop(lane)
    end
  end

  defp count_sessions(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM sessions")
    count
  end
end

ItemlessSpawnDispatchRuntime.run()
IO.puts("itemless-spawn-dispatch: ok")
