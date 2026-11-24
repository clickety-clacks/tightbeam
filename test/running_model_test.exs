defmodule Tightbeam.RunningModelTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{AdapterCoordinator, DB, Gateway, Model, Org, RunningModel, StateResources}
  alias Tightbeam.Firehose.Hub

  @fake ~S"""
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  rl.on("line", (line) => {
    const m = JSON.parse(line);
    if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
  });
  """

  setup do
    start_supervised!({Hub, name: Hub})
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})
    writer = start_supervised!({RunningModel, db: db, name: RunningModel})
    _ = :sys.get_state(writer)
    _ = drain_notices()

    session = create_session(db, "s1", "claude", "anthropic", "sonnet")
    Org.append_pointer(db, "s1", "sid-1", "created")

    %{db: db, writer: writer, session: session, key: Gateway.adapter_key(session)}
  end

  test "a report is stored, published once with the session, and an unchanged one is silent",
       ctx do
    before = Org.get(ctx.db, "s1")
    assert before.running_model == nil
    assert {nil, _} = running_model_field(ctx.db)
    _ = drain_notices()

    report(ctx, "sid-1", %{id: "claude-fable-5", label: "Fable 5"})

    assert %{id: "claude-fable-5", label: "Fable 5", harness: "claude"} =
             Org.get(ctx.db, "s1").running_model

    assert [%{"class" => "session.updated", "payload" => payload}] = drain_notices()

    assert payload["runningModel"] ==
             %{"id" => "claude-fable-5", "label" => "Fable 5", "harness" => "claude"}

    version = Org.get(ctx.db, "s1").updated_at
    assert version > before.updated_at

    # The REST row is the Firehose row.
    assert ctx.db |> StateResources.query_session("s1") |> StateResources.session() == payload

    report(ctx, "sid-1", %{id: "claude-fable-5", label: "Fable 5"})
    assert drain_notices() == []
    assert Org.get(ctx.db, "s1").updated_at == version
  end

  test "a label the harness does not report is stored as null", ctx do
    report(ctx, "sid-1", %{id: "claude-fable-5", label: nil})

    assert %{"runningModel" => %{"id" => "claude-fable-5", "label" => nil}} =
             ctx.db |> StateResources.query_session("s1") |> StateResources.session()
  end

  test "a changed model replaces the old one and a refusal clears it", ctx do
    report(ctx, "sid-1", %{id: "sonnet", label: "Sonnet"})
    report(ctx, "sid-1", %{id: "opus", label: "Opus"})
    assert %{id: "opus"} = Org.get(ctx.db, "s1").running_model

    report(ctx, "sid-1", nil)
    assert Org.get(ctx.db, "s1").running_model == nil
    assert {nil, nil} = running_model_field(ctx.db)
  end

  test "a report no pointer names yet waits for the pointer, then applies", ctx do
    create_session(ctx.db, "s2", "claude", "anthropic", "sonnet")
    report(ctx, "sid-new", %{id: "haiku", label: nil})
    assert Org.get(ctx.db, "s2").running_model == nil

    Org.append_pointer(ctx.db, "s2", "sid-new", "created")
    _ = :sys.get_state(ctx.writer)
    assert %{id: "haiku"} = Org.get(ctx.db, "s2").running_model
  end

  test "a report from a superseded pointer or another harness is dropped", ctx do
    report(ctx, "sid-1", %{id: "sonnet", label: nil})
    Org.append_pointer(ctx.db, "s1", "sid-2", "loaded")
    _ = :sys.get_state(ctx.writer)
    assert Org.get(ctx.db, "s1").running_model == nil
    _ = drain_notices()

    # The old harness session may still report; it is no longer the session's.
    report(ctx, "sid-1", %{id: "opus", label: nil})
    report(ctx, "sid-1", nil)
    assert Org.get(ctx.db, "s1").running_model == nil

    wrong_host = {elem(ctx.key, 0), "shared", "elsewhere"}
    RunningModel.report(ctx.writer, wrong_host, 1, "sid-2", %{id: "opus", label: nil})
    _ = :sys.get_state(ctx.writer)
    assert Org.get(ctx.db, "s1").running_model == nil
    assert drain_notices() == []

    report(ctx, "sid-2", %{id: "haiku", label: nil})
    assert %{id: "haiku"} = Org.get(ctx.db, "s1").running_model

    # A nil from the superseded id cannot clear what the current one said.
    report(ctx, "sid-1", nil)
    assert %{id: "haiku"} = Org.get(ctx.db, "s1").running_model
  end

  test "adapter loss clears every session on that adapter and no other", ctx do
    create_session(ctx.db, "s2", "codex", "openai", "gpt-5.6-sol")
    Org.append_pointer(ctx.db, "s2", "sid-c", "created")
    report(ctx, "sid-1", %{id: "sonnet", label: nil})

    other_key = Gateway.adapter_key(Org.get(ctx.db, "s2"))
    RunningModel.report(ctx.writer, other_key, 1, "sid-c", %{id: "gpt-5.6-sol", label: nil})
    _ = :sys.get_state(ctx.writer)
    _ = drain_notices()

    RunningModel.adapter_gone(ctx.writer, ctx.key)
    _ = :sys.get_state(ctx.writer)

    assert Org.get(ctx.db, "s1").running_model == nil
    assert %{id: "gpt-5.6-sol"} = Org.get(ctx.db, "s2").running_model

    assert [%{"class" => "session.updated", "payload" => %{"sessionKey" => "s1"}}] =
             drain_notices()
  end

  test "a harness swap clears the model in the swap's own change until the new one reports",
       ctx do
    report(ctx, "sid-1", %{id: "sonnet", label: nil})
    _ = drain_notices()

    Org.set_harness(ctx.db, "s1", "codex", "openai", Model.new("gpt-5.6-sol"))

    assert Org.get(ctx.db, "s1").running_model == nil

    assert [%{"class" => "session.harness_changed", "payload" => %{"runningModel" => nil}}] =
             drain_notices()

    # The old adapter's late report cannot revive it on the new harness.
    report(ctx, "sid-1", %{id: "sonnet", label: nil})
    assert Org.get(ctx.db, "s1").running_model == nil

    Org.append_pointer(ctx.db, "s1", "sid-codex", "created")
    new_key = Gateway.adapter_key(Org.get(ctx.db, "s1"))
    RunningModel.report(ctx.writer, new_key, 1, "sid-codex", %{id: "gpt-5.6-sol", label: "GPT"})
    _ = :sys.get_state(ctx.writer)
    assert %{id: "gpt-5.6-sol", harness: "codex"} = Org.get(ctx.db, "s1").running_model
  end

  test "a retired session is cleared and cannot be filled again", ctx do
    report(ctx, "sid-1", %{id: "sonnet", label: nil})
    _ = drain_notices()

    Org.retire(ctx.db, "s1", "user:flynn")
    assert Org.get(ctx.db, "s1").running_model == nil
    assert {nil, nil} = running_model_field(ctx.db)
    assert %{state: "retired", running_model: nil} = Org.get(ctx.db, "s1")
    _ = drain_notices()

    report(ctx, "sid-1", %{id: "sonnet", label: nil})
    assert Org.get(ctx.db, "s1").running_model == nil
    assert drain_notices() == []
  end

  test "the gateway starts with every stored model cleared and announced", ctx do
    report(ctx, "sid-1", %{id: "sonnet", label: nil})
    _ = drain_notices()
    stop_supervised!(RunningModel)

    restarted = start_supervised!({RunningModel, db: ctx.db, name: RunningModel})
    _ = :sys.get_state(restarted)

    assert Org.get(ctx.db, "s1").running_model == nil

    assert [%{"class" => "session.updated", "payload" => %{"runningModel" => nil}}] =
             drain_notices()
  end

  test "two changes in one millisecond still get strictly increasing versions", ctx do
    versions =
      for id <- ~w(a b c d) do
        report(ctx, "sid-1", %{id: id, label: nil})
        Org.get(ctx.db, "s1").updated_at
      end

    assert versions == Enum.sort(Enum.uniq(versions))
    assert length(Enum.uniq(versions)) == 4
  end

  test "a new pointer on the same harness empties the model until the new id reports", ctx do
    report(ctx, "sid-1", %{id: "sonnet", label: nil})
    _ = drain_notices()

    Org.append_pointer(ctx.db, "s1", "sid-fork", "created")
    _ = :sys.get_state(ctx.writer)

    # The fork has not reported: nothing may say what it runs.
    assert Org.get(ctx.db, "s1").running_model == nil

    assert [%{"class" => "session.updated", "payload" => %{"runningModel" => nil}}] =
             drain_notices()

    report(ctx, "sid-fork", %{id: "opus", label: nil})
    assert %{id: "opus"} = Org.get(ctx.db, "s1").running_model

    # The first pointer for a session with nothing stored publishes nothing.
    create_session(ctx.db, "s3", "claude", "anthropic", "sonnet")
    _ = drain_notices()
    Org.append_pointer(ctx.db, "s3", "sid-3", "created")
    assert drain_notices() |> Enum.filter(&(&1["class"] == "session.updated")) == []
  end

  test "a fork's report that came before its pointer survives the pointer's clear", ctx do
    report(ctx, "sid-1", %{id: "sonnet", label: nil})
    report(ctx, "sid-fork", %{id: "opus", label: nil})
    assert %{id: "sonnet"} = Org.get(ctx.db, "s1").running_model

    Org.append_pointer(ctx.db, "s1", "sid-fork", "created")
    _ = :sys.get_state(ctx.writer)
    assert %{id: "opus"} = Org.get(ctx.db, "s1").running_model
  end

  test "a remembered report does not outlive its adapter, in either arrival order", ctx do
    create_session(ctx.db, "s2", "claude", "anthropic", "sonnet")

    # Report first, loss second: the held report is dropped with the adapter.
    report(ctx, "sid-new", %{id: "haiku", label: nil})
    RunningModel.adapter_gone(ctx.writer, ctx.key)
    _ = :sys.get_state(ctx.writer)
    Org.append_pointer(ctx.db, "s2", "sid-new", "created")
    _ = :sys.get_state(ctx.writer)
    assert Org.get(ctx.db, "s2").running_model == nil

    # Loss first, report second: the next adapter's report is believed.
    report(ctx, "sid-new", %{id: "haiku", label: nil})
    assert %{id: "haiku"} = Org.get(ctx.db, "s2").running_model
  end

  test "moving a session to another host empties the model in the move itself", ctx do
    report(ctx, "sid-1", %{id: "sonnet", label: nil})
    before = Org.get(ctx.db, "s1")
    _ = drain_notices()

    Org.set_host(ctx.db, "s1", "elsewhere")

    assert %{host: "elsewhere", running_model: nil} = moved = Org.get(ctx.db, "s1")
    assert moved.updated_at > before.updated_at
    assert [%{"payload" => %{"host" => "elsewhere", "runningModel" => nil}}] = drain_notices()
  end

  test "a model change on the same harness keeps the reported model", ctx do
    report(ctx, "sid-1", %{id: "sonnet", label: nil})
    Org.set_harness(ctx.db, "s1", "claude", "anthropic", Model.new("opus"))
    assert %{id: "sonnet"} = Org.get(ctx.db, "s1").running_model
  end

  test "an upgraded database gains the nullable columns and reopens", ctx do
    {:ok, columns} = DB.query(ctx.db, "PRAGMA table_info(sessions)")
    names = Enum.map(columns, &Enum.at(&1, 1))
    assert ~w(runningModelId runningModelLabel runningModelHarness) -- names == []

    # Drop the columns to stand in for a database written before this change,
    # then open it the way the gateway does.
    for column <- ~w(runningModelId runningModelLabel runningModelHarness),
        do: :ok = DB.execute(ctx.db, "ALTER TABLE sessions DROP COLUMN #{column}")

    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
    assert Org.get(ctx.db, "s1").running_model == nil
  end

  describe "failed writes" do
    # A writer whose database writes fail on demand, to prove a failure never
    # leaves a value standing.
    setup ctx do
      {:ok, fail} = Agent.start_link(fn -> %{clears: false, reports: false} end)
      stop_supervised!(RunningModel)

      set = fn db, session_key, report, current? ->
        kind = if report, do: :reports, else: :clears
        if Agent.get(fail, &Map.fetch!(&1, kind)), do: raise("synthetic #{kind} failure")
        Org.set_running_model(db, session_key, report, current?)
      end

      writer =
        start_supervised!(
          {RunningModel, db: ctx.db, name: RunningModel, set_running_model: set, retry_ms: 10}
        )

      %{writer: writer, fail: fail}
    end

    test "a boot clear that fails stops startup; the next start clears and waits out overload",
         ctx do
      report(ctx, "sid-1", %{id: "sonnet", label: nil})
      stop_supervised!(RunningModel)

      boom = fn _db, _session_key, _report, _current? -> raise "synthetic boot failure" end

      assert {:error, _} =
               start_supervised(
                 {RunningModel, db: ctx.db, name: RunningModel, set_running_model: boom}
               )

      assert %{id: "sonnet"} = Org.get(ctx.db, "s1").running_model

      writer = start_supervised!({RunningModel, db: ctx.db, name: RunningModel})
      assert Org.get(ctx.db, "s1").running_model == nil

      # Owed work: the writer's database calls wait out an overloaded owner.
      {:dictionary, dictionary} = Process.info(writer, :dictionary)
      assert List.keyfind(dictionary, {DB, :owed_work}, 0) == {{DB, :owed_work}, true}
    end

    test "a failed clear on adapter loss is retried until the value is gone", ctx do
      report(ctx, "sid-1", %{id: "sonnet", label: nil})
      Agent.update(ctx.fail, &%{&1 | clears: true})

      RunningModel.adapter_gone(ctx.writer, ctx.key)
      _ = :sys.get_state(ctx.writer)
      assert %{id: "sonnet"} = Org.get(ctx.db, "s1").running_model

      Agent.update(ctx.fail, &%{&1 | clears: false})
      assert eventually(fn -> Org.get(ctx.db, "s1").running_model == nil end)
    end

    test "a retried clear never erases a report that arrived after the loss", ctx do
      report(ctx, "sid-1", %{id: "sonnet", label: nil})
      Agent.update(ctx.fail, &%{&1 | clears: true})

      RunningModel.adapter_gone(ctx.writer, ctx.key)
      _ = :sys.get_state(ctx.writer)
      assert %{id: "sonnet"} = Org.get(ctx.db, "s1").running_model

      # The replacement adapter reports while the clear is still failing.
      RunningModel.report(ctx.writer, ctx.key, 2, "sid-1", %{id: "opus", label: nil})
      _ = :sys.get_state(ctx.writer)
      assert %{id: "opus"} = Org.get(ctx.db, "s1").running_model

      Agent.update(ctx.fail, &%{&1 | clears: false})
      # Let the retry run, and prove it did by waiting for it to settle.
      :timer.sleep(100)
      _ = :sys.get_state(ctx.writer)
      assert %{id: "opus"} = Org.get(ctx.db, "s1").running_model
      assert :sys.get_state(ctx.writer).lost == %{}
    end

    test "a report whose write fails is kept and retried", ctx do
      Agent.update(ctx.fail, &%{&1 | reports: true})
      report(ctx, "sid-1", %{id: "sonnet", label: nil})
      assert Org.get(ctx.db, "s1").running_model == nil

      Agent.update(ctx.fail, &%{&1 | reports: false})
      assert eventually(fn -> match?(%{id: "sonnet"}, Org.get(ctx.db, "s1").running_model) end)
    end

    test "a failed unload (nil report) is retried and clears the value", ctx do
      report(ctx, "sid-1", %{id: "sonnet", label: nil})
      Agent.update(ctx.fail, &%{&1 | clears: true})

      report(ctx, "sid-1", nil)
      assert %{id: "sonnet"} = Org.get(ctx.db, "s1").running_model

      Agent.update(ctx.fail, &%{&1 | clears: false})
      assert eventually(fn -> Org.get(ctx.db, "s1").running_model == nil end)
    end

    test "a report dropped as stale does not shield a value from the retried loss clear", ctx do
      report(ctx, "sid-1", %{id: "sonnet", label: nil})
      Agent.update(ctx.fail, &%{&1 | clears: true})

      RunningModel.adapter_gone(ctx.writer, ctx.key)
      _ = :sys.get_state(ctx.writer)

      # A later report that names this session's id but not its adapter is stale
      # and changes nothing; the old value is still standing.
      wrong_host = {elem(ctx.key, 0), "shared", "elsewhere"}
      RunningModel.report(ctx.writer, wrong_host, 2, "sid-1", %{id: "opus", label: nil})
      _ = :sys.get_state(ctx.writer)
      assert %{id: "sonnet"} = Org.get(ctx.db, "s1").running_model

      Agent.update(ctx.fail, &%{&1 | clears: false})
      assert eventually(fn -> Org.get(ctx.db, "s1").running_model == nil end)
    end

    test "a newer report replaces a failed one before its retry", ctx do
      Agent.update(ctx.fail, &%{&1 | reports: true})
      report(ctx, "sid-1", %{id: "sonnet", label: nil})
      report(ctx, "sid-1", %{id: "opus", label: nil})

      Agent.update(ctx.fail, &%{&1 | reports: false})
      assert eventually(fn -> match?(%{id: "opus"}, Org.get(ctx.db, "s1").running_model) end)
    end
  end

  describe "adapter coordinator" do
    setup do
      dir = Path.join(System.tmp_dir!(), "running-model-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, "fake.js")
      File.write!(path, @fake)
      db = :"running_model_coordinator_db_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec({DB, path: ":memory:", name: db}, id: :coordinator_db)
      )

      :ok = ensure_all_schemas(db)
      sup = :"running_model_sup_#{System.unique_integer([:positive])}"
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
      probe = :"running_model_probe_#{System.unique_integer([:positive])}"
      Process.register(self(), probe)

      coordinator =
        start_supervised!(
          {AdapterCoordinator,
           adapter_sup: sup,
           adapter_context: fn _ -> [] end,
           adapter_opts: fn _, _ ->
             [harness: :claude, cmd: [System.find_executable("node"), path], home: dir, cwd: dir]
           end,
           db: db,
           running_model: probe,
           name: :"running_model_coordinator_#{System.unique_integer([:positive])}"}
        )

      %{coordinator: coordinator, key: {:claude, "shared", "testhost"}}
    end

    test "only the adapter the coordinator holds is believed, and its loss is announced", ctx do
      assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(ctx.coordinator, ctx.key)
      assert is_function(:sys.get_state(adapter).on_running_model, 2)

      report = %{id: "sonnet", label: nil}
      cast = &GenServer.cast(ctx.coordinator, {:running_model, ctx.key, &1, &2, "sid", report})

      # The adapter's own hook, run inside the adapter process the way a report is.
      :sys.replace_state(adapter, fn state ->
        state.on_running_model.("sid", report)
        state
      end)

      assert_receive {:"$gen_cast", {:report, key, 1, "sid", ^report}} when key == ctx.key

      # An old generation, and a process that is not the held adapter.
      cast.(2, adapter)
      cast.(1, self())
      _ = :sys.get_state(ctx.coordinator)
      refute_received {:"$gen_cast", {:report, _key, _generation, _sid, _report}}

      monitor = Process.monitor(adapter)
      Process.exit(adapter, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^adapter, :killed}
      assert_receive {:"$gen_cast", {:adapter_gone, key}} when key == ctx.key

      # The dead adapter's late report is dropped.
      cast.(1, adapter)
      _ = :sys.get_state(ctx.coordinator)
      refute_received {:"$gen_cast", {:report, _key, _generation, _sid, _report}}
    end
  end

  describe "writer restart" do
    setup ctx do
      dir = Path.join(System.tmp_dir!(), "running-model-w-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, "fake.js")
      File.write!(path, @fake)
      sup = :"running_model_w_sup_#{System.unique_integer([:positive])}"
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})

      coordinator =
        start_supervised!(
          {AdapterCoordinator,
           adapter_sup: sup,
           adapter_context: fn _ -> [] end,
           adapter_opts: fn _, _ ->
             [harness: :claude, cmd: [System.find_executable("node"), path], home: dir, cwd: dir]
           end,
           db: ctx.db,
           name: :"running_model_w_coordinator_#{System.unique_integer([:positive])}"}
        )

      %{coordinator: coordinator}
    end

    test "a restarted writer learns what live adapters already know", ctx do
      assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(ctx.coordinator, ctx.key)
      _ = :sys.get_state(adapter)

      :sys.replace_state(adapter, fn state ->
        %{state | models: %{"sid-1" => Model.new("opus")}}
      end)

      report(ctx, "sid-1", %{id: "opus", label: nil})
      assert %{id: "opus"} = Org.get(ctx.db, "s1").running_model

      # The writer alone dies; its restart clears the row and the live adapter
      # says again what it runs.
      stop_supervised!(RunningModel)

      start_supervised!(
        {RunningModel, db: ctx.db, name: RunningModel, coordinator: ctx.coordinator}
      )

      assert eventually(fn -> match?(%{id: "opus"}, Org.get(ctx.db, "s1").running_model) end)
    end
  end

  defp create_session(db, key, harness, provider, model) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: harness,
      provider: provider,
      model: Model.new(model)
    })
  end

  defp report(ctx, sid, report) do
    RunningModel.report(ctx.writer, ctx.key, 1, sid, report)
    _ = :sys.get_state(ctx.writer)
    :ok
  end

  defp running_model_field(db) do
    {:ok, [[id, label]]} =
      DB.query(db, "SELECT runningModelId, runningModelLabel FROM sessions WHERE sessionKey='s1'")

    {id, label}
  end

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end

  defp drain_notices(acc \\ []) do
    receive do
      {:firehose_notice, notice} ->
        Hub.delivered(Hub, self())
        drain_notices([notice | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
