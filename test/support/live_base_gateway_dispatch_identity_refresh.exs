defmodule DispatchRefreshDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardDispatchIdentityRefresh do
  import ExUnit.Assertions
  alias Tightbeam.{DB, Gateway, Identity, Ledger, Model, NoticeBatcher, Org, Placement, Wakes}
  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

  # The engineering bundle is no longer shipped; learn it from the test fixture root.
  @fixture_kungfu Path.expand("fixtures/kungfu", __DIR__)

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{base: base, db: db, config: config} ->
      Application.put_env(:tightbeam, :kungfu_bundle_root_dir, @fixture_kungfu)

      assert {:ok, candidate} = Identity.learn!(base, "agentic-engineering", "test")
      assert {:ok, _revision} = Identity.publish_live!(base, candidate)
      Tightbeam.Archetypes.load!(base)

      session =
        Org.create(db, %{
          session_key: "assignment-target",
          display_name: "Assignment target",
          owner_user_id: "test-owner",
          origin: "user:test-owner",
          archetype: "agentic-engineering.coder",
          host: "testhost",
          harness: "claude",
          provider: "anthropic",
          model: Model.new("claude-fable-5")
        })

      {:ok, lane} = GenServer.start_link(DispatchRefreshDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link(adapter)
      config = %{config | default_harness: :claude, port: 0}

      try do
        children = Gateway.children(config)

        {Tightbeam.LaneManager, lane_opts} =
          Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

        {Tightbeam.Wakes, wake_opts} =
          Enum.find(children, &match?({Tightbeam.Wakes, _}, &1))

        {:ok, scheduler} = Wakes.start_link(wake_opts)

        runner = Keyword.fetch!(lane_opts, :runner)
        old = Identity.live_revision!(base)
        cwd = Placement.holder_workdir(config, session)
        snapshot = Identity.provision_at!(base, old, "agentic-engineering.coder", :claude, cwd)

        Org.set_identity_stamp(
          db,
          session.session_key,
          old,
          snapshot.render_contract,
          snapshot.guidance_digest
        )

        Org.append_pointer(db, session.session_key, "resident-session", "created")
        skill = Path.join(cwd, ".claude/skills/tightbeam__repository-retirement/SKILL.md")
        assert File.exists?(skill)

        first = publish_skill!(base, "first served revision")
        assert first != old
        assert Org.get(db, session.session_key).identity_revision == old
        refute File.read!(skill) == "first served revision"

        dispatch!(config, session.session_key, "first brief")
        first_turn = run_next!(db, runner, adapter, session.session_key)
        assert assignment_id(db, first_turn)
        assert Org.get(db, session.session_key).identity_revision == first
        assert File.read!(skill) == "first served revision"

        assert :appended =
                 Gateway.deliver_prompt(session.session_key, "user:test-owner", "already running",
                   db: db,
                   lane_manager: lane
                 )

        assert {:ok, busy} = Ledger.claim_next(db, session.session_key, "test")
        assert assignment_id(db, busy) == nil

        second = publish_skill!(base, "second served revision")
        dispatch!(config, session.session_key, "queued brief")
        assert File.read!(skill) == "first served revision"
        assert Org.get(db, session.session_key).identity_revision == first

        assert Ledger.finish(db, busy.seq, "delivered", nil, owner_lease: busy.owner_lease)
        :ok = Wakes.fire_due(scheduler)
        queued = run_next!(db, runner, adapter, session.session_key)
        assert assignment_id(db, queued)
        assert Org.get(db, session.session_key).identity_revision == second
        assert File.read!(skill) == "second served revision"

        third = publish_skill!(base, "third served revision")
        handlers = Gateway.handlers(config)

        assert %{id: assignment_id} =
                 handlers["assign"].(%{
                   verb: "assign",
                   origin: "user:test-owner",
                   principal: {:user, "test-owner"},
                   session_key: session.session_key,
                   target_role: nil,
                   role_fallback: false,
                   params: %{subject: "assignment with a separate wake"}
                 })

        assert %{wake_id: _wake_id} =
                 handlers["wake"].(%{
                   verb: "wake",
                   origin: "user:test-owner",
                   principal: {:user, "test-owner"},
                   session_key: session.session_key,
                   target_role: nil,
                   role_fallback: false,
                   params: %{
                     prompt: "separate assignment brief",
                     assignment_id: assignment_id,
                     after_ms: 0
                   }
                 })

        assert File.read!(skill) == "second served revision"
        :ok = Wakes.fire_due(scheduler)
        wake_turn = run_next!(db, runner, adapter, session.session_key)
        assert assignment_id(db, wake_turn) == assignment_id
        assert Org.get(db, session.session_key).identity_revision == third
        assert File.read!(skill) == "third served revision"

        fourth = publish_skill!(base, "fourth served revision")

        {first_assignment, first_wake} =
          assign_and_wake!(handlers, session.session_key, "mixed batch assignment brief")

        {second_assignment, second_wake} =
          assign_and_wake!(handlers, session.session_key, "another assignment notice")

        assert first_assignment != second_assignment
        :ok = Wakes.fire_due(scheduler)
        mixed_turn = run_next!(db, runner, adapter, session.session_key)
        assert assignment_id(db, mixed_turn) == nil

        assert {:ok, [[carrier_wake]]} =
                 DB.query(db, "SELECT wakeId FROM turns WHERE seq=?1", [mixed_turn.seq])

        assert [%{delivery_wake_id: ^carrier_wake}] = NoticeBatcher.source_refs(db, first_wake)
        assert [%{delivery_wake_id: ^carrier_wake}] = NoticeBatcher.source_refs(db, second_wake)
        assert Org.get(db, session.session_key).identity_revision == fourth
        assert File.read!(skill) == "fourth served revision"
      after
        if Process.whereis(Tightbeam.WakeScheduler), do: GenServer.stop(Tightbeam.WakeScheduler)
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(lane)
      end
    end)
  end

  defp publish_skill!(base, text) do
    candidate =
      Identity.edit!(
        base,
        "agentic-engineering.coder",
        {:skill, "repository-retirement", false},
        text,
        "test"
      )

    assert {:ok, revision} = Identity.publish_live!(base, candidate)
    revision
  end

  defp dispatch!(config, session_key, brief) do
    result =
      Gateway.handlers(config)["dispatch"].(%{
        verb: "dispatch",
        origin: "user:test-owner",
        principal: {:user, "test-owner"},
        session_key: session_key,
        target_role: nil,
        role_fallback: false,
        params: %{subject: brief, brief: brief}
      })

    assert %{id: id} = result
    id
  end

  defp assign_and_wake!(handlers, session_key, brief) do
    assert %{id: assignment_id} =
             handlers["assign"].(%{
               verb: "assign",
               origin: "user:test-owner",
               principal: {:user, "test-owner"},
               session_key: session_key,
               target_role: nil,
               role_fallback: false,
               params: %{subject: brief}
             })

    assert %{wake_id: wake_id} =
             handlers["wake"].(%{
               verb: "wake",
               origin: "user:test-owner",
               principal: {:user, "test-owner"},
               session_key: session_key,
               target_role: nil,
               role_fallback: false,
               params: %{prompt: brief, assignment_id: assignment_id, after_ms: 0}
             })

    {assignment_id, wake_id}
  end

  defp run_next!(db, runner, adapter, session_key) do
    assert {:ok, turn} = Ledger.claim_next(db, session_key, "test")
    task = Task.async(fn -> runner.(Map.put(turn, :session_key, session_key)) end)

    try do
      assert_receive {:prompt_started, ^adapter}, 60_000
      assert_receive {:prompt_content, prompt}, 60_000
      assert prompt =~ "Tightbeam identity files were refreshed to revision"
      assert prompt =~ "Re-read your Tightbeam skills before working."
      send(adapter, :continue_prompt)
      assert {:ok, %{record_in_txn: record}} = Task.await(task, 60_000)
      :ok = Tightbeam.GatewayTurnFixture.commit_success!(db, turn, record)
      turn
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp assignment_id(db, turn) do
    assert {:ok, [[id]]} = DB.query(db, "SELECT assignmentId FROM turns WHERE seq=?1", [turn.seq])
    id
  end
end

GuardDispatchIdentityRefresh.run()
IO.puts("guarded-gateway-dispatch-identity-refresh: ok")
