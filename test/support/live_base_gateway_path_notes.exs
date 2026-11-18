defmodule PathNotesDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}
  def handle_call({:ensure_lane, _key}, _from, parent), do: {:reply, :ok, parent}
end

# Delivered turns carry one presence note per distinct handed-on path, after
# the delivered text. Every turn here runs through the gateway's own runner
# and is captured where the adapter receives it.
defmodule GuardPathNotes do
  import ExUnit.Assertions
  alias Tightbeam.{DB, Gateway, Identity, Ledger, Model, Org, PathNotes, Placement, Wakes}
  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

  @key "path-notes-target"

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{base: base, db: db, config: config} ->
      assert {:ok, candidate} = Identity.learn!(base, "agentic-engineering", "test")
      assert {:ok, _revision} = Identity.publish_live!(base, candidate)
      Tightbeam.Archetypes.load!(base)

      session =
        Org.create(db, %{
          session_key: @key,
          display_name: "Path notes target",
          owner_user_id: "test-owner",
          origin: "user:test-owner",
          archetype: "agentic-engineering.coder",
          host: "testhost",
          harness: "claude",
          provider: "anthropic",
          model: Model.new("claude-fable-5")
        })

      dir = Path.join(base, "handed-on")
      File.mkdir_p!(dir)
      present = Path.join(dir, "spec.md")
      File.write!(present, "spec")
      missing = Path.join(dir, "missing.md")
      locked = Path.join(dir, "locked")
      File.mkdir_p!(locked)
      denied = Path.join(locked, "x")
      design = Path.join(dir, "design notes.md")
      File.write!(design, "design")
      hanging = Path.join(dir, "hanging.md")
      File.write!(hanging, "never reported")
      File.chmod!(locked, 0o000)
      parent = self()

      # Real stats, except one path whose stat never returns until released.
      file_stat = fn
        ^hanging ->
          send(parent, {:hanging_check, self()})
          receive do: (:release -> File.stat(hanging))

        path ->
          File.stat(path)
      end

      # Delivery nudges a session's lane through this registry; no lane is
      # registered here, so a nudge finds none and the test runs each turn.
      {:ok, registry} = Registry.start_link(keys: :unique, name: Tightbeam.LaneRegistry)
      {:ok, lane} = GenServer.start_link(PathNotesDoorbell, self())
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link(adapter)

      config =
        config
        |> Map.merge(%{default_harness: :claude, port: 0})
        |> Map.put(:file_stat, file_stat)

      try do
        children = Gateway.children(config)

        {Tightbeam.LaneManager, lane_opts} =
          Enum.find(children, &match?({Tightbeam.LaneManager, _}, &1))

        {Tightbeam.Wakes, wake_opts} =
          Enum.find(children, &match?({Tightbeam.Wakes, _}, &1))

        {Tightbeam.PathNotes, notes_opts} =
          Enum.find(children, &match?({Tightbeam.PathNotes, _}, &1))

        {:ok, scheduler} = Wakes.start_link(wake_opts)
        {:ok, _notes} = PathNotes.start_link(notes_opts)
        runner = Keyword.fetch!(lane_opts, :runner)

        revision = Identity.live_revision!(base)
        cwd = Placement.holder_workdir(config, session)
        snapshot = Identity.provision_at!(base, revision, "agentic-engineering.coder", :claude, cwd)

        Org.set_identity_stamp(
          db,
          @key,
          revision,
          snapshot.render_contract,
          snapshot.guidance_digest
        )

        Org.append_pointer(db, @key, "resident-session", "created")
        handlers = Gateway.handlers(config)

        # A dispatch brief: present, absent and unreadable paths, one repeated.
        dispatch!(handlers, "read #{present}, #{missing} and #{denied}; review #{present} again.")
        brief = queued_turn!(db)
        await_checked!(brief, [present, missing, denied])
        {delivered, row} = run_next!(db, runner, adapter)

        assert delivered ==
                 row <>
                   "\n\n" <>
                   Enum.join(
                     [
                       "verified present at #{present}",
                       "not found at #{missing}; check before relying on it",
                       "could not check #{denied}: eacces; check before relying on it"
                     ],
                     "\n"
                   )

        refute row =~ "verified present"

        # A wake prompt naming one path twice gets exactly one note for it.
        x = Path.join(dir, "x.md")
        File.write!(x, "x")
        y = Path.join(dir, "y.md")
        wake!(handlers, "review #{x} and #{x}, then #{y}.")
        :ok = Wakes.fire_due(scheduler)
        await_checked!(queued_turn!(db), [x, y])
        {delivered, row} = run_next!(db, runner, adapter)

        assert delivered ==
                 row <>
                   "\n\nverified present at #{x}\nnot found at #{y}; check before relying on it"

        assert stored_wake_prompts(db) =~ "review #{x} and #{x}, then #{y}."
        refute stored_wake_prompts(db) =~ "check before relying on it"

        # A URL is not a path: delivered unchanged.
        wake!(handlers, "see https://example.test/a/b")
        :ok = Wakes.fire_due(scheduler)
        {delivered, row} = run_next!(db, runner, adapter)
        assert delivered == row
        assert delivered =~ "see https://example.test/a/b"

        # A quoted path is one path, spaces included.
        wake!(handlers, ~s(open "#{design}" first))
        :ok = Wakes.fire_due(scheduler)
        await_checked!(queued_turn!(db), [design])
        {delivered, row} = run_next!(db, runner, adapter)
        assert delivered == row <> "\n\nverified present at #{design}"

        # A chat post is delivered without notes.
        assert :appended =
                 Gateway.deliver_prompt(@key, "user:test-owner", "please read #{present}",
                   db: db,
                   device_id: "path-notes-device",
                   client_message_id: "path-notes-post",
                   human_post: true,
                   lane_manager: lane
                 )

        {delivered, row} = run_next!(db, runner, adapter)
        assert delivered == row
        refute delivered =~ "verified present"

        # A check that has not returned never holds the turn: the turn is sent
        # with its other notes and says this one is still running.
        wake!(handlers, "check #{hanging} against #{present}")
        :ok = Wakes.fire_due(scheduler)
        hung = queued_turn!(db)
        assert_receive {:hanging_check, check_pid}, 10_000
        await_checked!(hung, [present])
        {delivered, row} = run_next!(db, runner, adapter)

        assert delivered ==
                 row <>
                   "\n\ncould not check #{hanging}: check still running; check before relying on it" <>
                   "\nverified present at #{present}"

        # Once the turn's notes are read the unfinished check is ended, not
        # left running. The forget is cast before the adapter saw the prompt,
        # so this call is ordered after it.
        _ = :sys.get_state(PathNotes)
        refute Process.alive?(check_pid)
        assert :ets.lookup(PathNotes, {hung.seq, "testhost", hanging}) == []

        # A batched delivery carries notes for paths across its members.
        a = Path.join(dir, "a.md")
        File.write!(a, "a")
        b = Path.join(dir, "b.md")
        assign_and_wake!(handlers, "first notice about #{a}")
        assign_and_wake!(handlers, "second notice about #{b}")
        :ok = Wakes.fire_due(scheduler)
        batch = queued_turn!(db)

        assert {:ok, [[carrier]]} =
                 DB.query(db, "SELECT wakeId FROM turns WHERE seq=?1", [batch.seq])

        assert String.starts_with?(carrier, "w_nb_")
        await_checked!(batch, [a, b])
        {delivered, row} = run_next!(db, runner, adapter)

        assert delivered ==
                 row <>
                   "\n\nverified present at #{a}\nnot found at #{b}; check before relying on it"
      after
        File.chmod(locked, 0o700)
        if Process.whereis(Tightbeam.WakeScheduler), do: GenServer.stop(Tightbeam.WakeScheduler)
        if Process.whereis(PathNotes), do: GenServer.stop(PathNotes)
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(lane)
        GenServer.stop(registry)
      end
    end)
  end

  defp dispatch!(handlers, brief) do
    assert %{id: _id} =
             handlers["dispatch"].(%{
               verb: "dispatch",
               origin: "user:test-owner",
               principal: {:user, "test-owner"},
               session_key: @key,
               target_role: nil,
               role_fallback: false,
               params: %{subject: "path notes brief", brief: brief}
             })
  end

  defp wake!(handlers, prompt) do
    assert %{wake_id: _} =
             handlers["wake"].(%{
               verb: "wake",
               origin: "user:test-owner",
               principal: {:user, "test-owner"},
               session_key: @key,
               target_role: nil,
               role_fallback: false,
               params: %{prompt: prompt, after_ms: 0}
             })
  end

  defp assign_and_wake!(handlers, brief) do
    assert %{id: assignment_id} =
             handlers["assign"].(%{
               verb: "assign",
               origin: "user:test-owner",
               principal: {:user, "test-owner"},
               session_key: @key,
               target_role: nil,
               role_fallback: false,
               params: %{subject: "batched notice"}
             })

    assert %{wake_id: _} =
             handlers["wake"].(%{
               verb: "wake",
               origin: "user:test-owner",
               principal: {:user, "test-owner"},
               session_key: @key,
               target_role: nil,
               role_fallback: false,
               params: %{prompt: brief, assignment_id: assignment_id, after_ms: 0}
             })
  end

  defp queued_turn!(db) do
    assert {:ok, [[seq]]} =
             DB.query(
               db,
               "SELECT seq FROM turns WHERE sessionKey=?1 AND status='queued' ORDER BY seq DESC LIMIT 1",
               [@key]
             )

    %{seq: seq}
  end

  # The enqueue started these checks; wait until each one has reported, so the
  # delivered notes below are deterministic.
  defp await_checked!(turn, paths, attempts \\ 2_000)

  defp await_checked!(_turn, paths, 0), do: flunk("path checks did not report: #{inspect(paths)}")

  defp await_checked!(turn, paths, attempts) do
    done? =
      Enum.all?(paths, fn path ->
        match?(
          [{_, {:done, _}}],
          :ets.lookup(PathNotes, {turn.seq, "testhost", path})
        )
      end)

    if done? do
      :ok
    else
      Process.sleep(5)
      await_checked!(turn, paths, attempts - 1)
    end
  end

  defp run_next!(db, runner, adapter) do
    assert {:ok, turn} = Ledger.claim_next(db, @key, "test")
    task = Task.async(fn -> runner.(Map.put(turn, :session_key, @key)) end)

    try do
      assert_receive {:prompt_started, ^adapter}, 60_000
      assert_receive {:prompt_content, delivered}, 60_000
      send(adapter, :continue_prompt)
      assert {:ok, %{record_in_txn: record}} = Task.await(task, 60_000)
      :ok = Tightbeam.GatewayTurnFixture.commit_success!(db, turn, record)
      assert {:ok, [[row]]} = DB.query(db, "SELECT prompt FROM turns WHERE seq=?1", [turn.seq])
      {delivered, row}
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp stored_wake_prompts(db) do
    assert {:ok, rows} =
             DB.query(db, "SELECT prompt FROM wakes WHERE sessionKey=?1", [@key])

    rows |> List.flatten() |> Enum.join("\n")
  end
end

GuardPathNotes.run()
IO.puts("guarded-gateway-path-notes: ok")
