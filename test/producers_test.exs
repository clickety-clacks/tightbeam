defmodule Tightbeam.ProducersTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    DB,
    Devices,
    Dispatch,
    EventLog,
    Gateway,
    Idempotency,
    Org,
    Producers,
    Roles,
    Rules,
    WorkItems
  }

  setup do
    db = :"producer_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [
          Tightbeam.CausalEvents,
          Devices,
          Idempotency,
          Org,
          Roles,
          WorkItems,
          Assignments,
          EventLog,
          Producers
        ] do
      :ok = module.ensure_schema(db)
    end

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1), ('other', 0, 1), ('admin', 1, 1)"
      )

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-producers-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base_dir, "identity"))
    init_identity_repo(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    holder = session(db, "holder", "flynn", "claude", "anthropic")
    other = session(db, "other-session", "other", "codex", "openai")
    assignment = assignment(db, holder.session_key)

    %{db: db, base_dir: base_dir, holder: holder, other: other, assignment: assignment}
  end

  test "loads only committed config with the exact shape and permits an absent file", ctx do
    assert Producers.load!(ctx.base_dir) == %{timeout_ms: 600_000}

    write_config(ctx.base_dir, "tests = \"true\"\nsmoke = \"false\"\ntimeout_ms = 42\n")

    assert Producers.load!(ctx.base_dir) == %{tests: "true", smoke: "false", timeout_ms: 42}

    File.write!(
      Path.join(ctx.base_dir, "identity/producers.toml"),
      "tests = \"uncommitted\"\nextra = \"no\"\n"
    )

    assert Producers.load!(ctx.base_dir) == %{tests: "true", smoke: "false", timeout_ms: 42}

    commit_identity(ctx.base_dir, "uncommitted producer edit")
    assert_raise ArgumentError, ~r/unknown keys: extra/, fn -> Producers.load!(ctx.base_dir) end
  end

  test "accept is fast and durable, idempotent outside wire_idempotency, then files frozen verdict",
       ctx do
    marker = Path.join(ctx.base_dir, "ran")
    command = "printf ran > #{shell_quote(marker)}"
    write_config(ctx.base_dir, "tests = #{JSON.encode!(command)}\ntimeout_ms = 5000\n")
    producer_config = Producers.load!(ctx.base_dir)
    call = producer_call("run-tests", {:session, ctx.holder.session_key}, ctx.assignment.id)
    handler = Gateway.handlers(%{db: ctx.db})["run-tests"]

    assert %{queued: job_id} = handler.(call)

    refute File.exists?(marker)
    assert %{state: "queued", command: ^command} = Producers.get(ctx.db, job_id)

    assert %{queued: ^job_id} = handler.(call)

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM producer_jobs")
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM wire_idempotency")
    assert Assignments.list_attests(ctx.db, ctx.assignment.id) == []

    Org.set_harness(ctx.db, ctx.holder.session_key, "codex", "openai", "gpt")
    {_sup, _runner} = start_runner(ctx, producer_config)

    assert_wait(fn -> Producers.get(ctx.db, job_id).state == "done" end)
    assert File.read!(marker) == "ran"

    assert [verdict] = Assignments.list_attests(ctx.db, ctx.assignment.id)
    assert verdict.verdictKind == "tests-passed"
    assert verdict.producer == "build"
    assert verdict.producerCommand == command
    assert verdict.bySession == ctx.holder.session_key
    assert verdict.byHarness == "claude"
    assert verdict.byProvider == "anthropic"
    assert Assignments.produced_verdict_kinds(ctx.db, ctx.assignment.id) == ["tests-passed"]
  end

  test "boot recovery reruns queued with frozen stamps but fails orphaned running closed", ctx do
    marker = Path.join(ctx.base_dir, "queued-ran")
    orphan_marker = Path.join(ctx.base_dir, "orphan-ran")
    producer_config = %{tests: "printf queued > #{shell_quote(marker)}", timeout_ms: 5_000}

    %{queued: queued_id} =
      Producers.__handle__(
        ctx.db,
        "run-tests",
        producer_call("run-tests", {:session, ctx.holder.session_key}, ctx.assignment.id),
        config: producer_config
      )

    second_assignment = assignment(ctx.db, ctx.holder.session_key, "orphan")

    %{queued: orphan_id} =
      Producers.__handle__(
        ctx.db,
        "run-tests",
        producer_call("run-tests", {:session, ctx.holder.session_key}, second_assignment.id),
        config: %{
          tests: "printf orphan > #{shell_quote(orphan_marker)}",
          timeout_ms: 5_000
        }
      )

    {:ok, _} =
      DB.query(ctx.db, "UPDATE producer_jobs SET state = 'running' WHERE id = ?1", [orphan_id])

    Org.set_harness(ctx.db, ctx.holder.session_key, "codex", "openai", "gpt")
    {_sup, _runner} = start_runner(ctx, producer_config)

    assert_wait(fn -> Producers.get(ctx.db, queued_id).state == "done" end)
    assert Producers.get(ctx.db, orphan_id).state == "failed"
    refute File.exists?(orphan_marker)
    assert Assignments.list_attests(ctx.db, second_assignment.id) == []

    assert [verdict] = Assignments.list_attests(ctx.db, ctx.assignment.id)
    assert verdict.byHarness == "claude"
    assert verdict.byProvider == "anthropic"

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "producer_failed" and event.subject == second_assignment.id and
               event.detail =~ "orphaned"
           end)
  end

  test "cancel-before-claim, terminal noop, and cancellation authorization use one CAS", ctx do
    producer_config = %{tests: "true", timeout_ms: 5_000}

    %{queued: job_id} =
      Producers.__handle__(
        ctx.db,
        "run-tests",
        producer_call("run-tests", {:user, "flynn"}, ctx.assignment.id),
        config: producer_config
      )

    assert %{by_user: "flynn", by_session: nil, by_harness: nil, by_provider: nil} =
             Producers.get(ctx.db, job_id)

    assert %{code: "forbidden"} =
             Producers.__handle__(
               ctx.db,
               "cancel-producer-job",
               cancel_call({:session, ctx.other.session_key}, job_id)
             )

    assert %{code: "process_denied"} =
             Producers.__handle__(
               ctx.db,
               "cancel-producer-job",
               cancel_call({:process, "cron"}, job_id)
             )

    assert %{code: "principal_required"} =
             Producers.__handle__(ctx.db, "cancel-producer-job", cancel_call(nil, job_id))

    assert %{code: "unknown_producer_job"} =
             Producers.__handle__(
               ctx.db,
               "cancel-producer-job",
               cancel_call({:user, "admin"}, "pj_missing")
             )

    assert %{cancelled: ^job_id} =
             Producers.__handle__(
               ctx.db,
               "cancel-producer-job",
               cancel_call({:session, ctx.holder.session_key}, job_id)
             )

    assert Producers.get(ctx.db, job_id).state == "cancelled"
    event_count = length(EventLog.lifecycle_events(ctx.db))

    assert %{cancelled: ^job_id, noop: true} =
             Producers.__handle__(
               ctx.db,
               "cancel-producer-job",
               cancel_call({:user, "admin"}, job_id)
             )

    assert length(EventLog.lifecycle_events(ctx.db)) == event_count
  end

  test "cancellation kills the producer shell, child, and grandchild before delayed effects",
       ctx do
    tree = descendant_tree(ctx.base_dir, "cancel")
    command = descendant_command(tree)

    producer_config = %{tests: command, timeout_ms: 10_000}
    {_sup, runner} = start_runner(ctx, producer_config)

    %{queued: job_id} =
      Producers.__handle__(
        ctx.db,
        "run-tests",
        producer_call("run-tests", {:session, ctx.holder.session_key}, ctx.assignment.id),
        config: producer_config,
        runner: runner
      )

    assert_wait(fn ->
      descendant_pids_ready?(tree) and Producers.get(ctx.db, job_id).state == "running"
    end)

    pids = descendant_pids(tree)
    assert Enum.all?(pids, &process_exists?/1)

    assert %{cancelled: ^job_id} =
             Producers.__handle__(
               ctx.db,
               "cancel-producer-job",
               cancel_call({:session, ctx.holder.session_key}, job_id),
               runner: runner
             )

    assert_wait(fn -> Producers.get(ctx.db, job_id).state == "cancelled" end)
    assert_wait(fn -> Enum.all?(pids, &(not process_exists?(&1))) end)
    Process.sleep(2_200)
    refute File.exists?(tree.finished)
    assert Assignments.list_attests(ctx.db, ctx.assignment.id) == []
  end

  test "timeout kills the producer shell, child, and grandchild before delayed effects", ctx do
    tree = descendant_tree(ctx.base_dir, "timeout")
    producer_config = %{tests: descendant_command(tree), timeout_ms: 1_000}
    {_sup, runner} = start_runner(ctx, producer_config)
    assignment = assignment(ctx.db, ctx.holder.session_key, "timeout descendants")

    %{queued: job_id} =
      Producers.__handle__(
        ctx.db,
        "run-tests",
        producer_call("run-tests", {:session, ctx.holder.session_key}, assignment.id),
        config: producer_config,
        runner: runner
      )

    assert_wait(fn ->
      descendant_pids_ready?(tree) and Producers.get(ctx.db, job_id).state == "running"
    end)

    pids = descendant_pids(tree)
    assert Enum.all?(pids, &process_exists?/1)
    assert_wait(fn -> Producers.get(ctx.db, job_id).state == "failed" end)
    assert_wait(fn -> Enum.all?(pids, &(not process_exists?(&1))) end)
    Process.sleep(1_200)
    refute File.exists?(tree.finished)
    assert Assignments.list_attests(ctx.db, assignment.id) == []

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.subject == assignment.id and event.detail =~ "timeout"
           end)
  end

  test "unconfigured, nonzero, timeout, and remote holder fail loudly without verdicts", ctx do
    call = producer_call("run-tests", {:session, ctx.holder.session_key}, ctx.assignment.id)

    assert %{code: "producer_unconfigured"} =
             Producers.__handle__(ctx.db, "run-tests", put_in(call.params[:command], "true"),
               config: %{timeout_ms: 5_000}
             )

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM producer_jobs")

    assert Enum.count(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "producer_failed" and event.subject == ctx.assignment.id and
               event.detail =~ "producer_unconfigured"
           end) == 1

    for {command, timeout_ms, reason} <- [{"exit 9", 5_000, "exit 9"}, {"sleep 2", 20, "timeout"}] do
      assignment = assignment(ctx.db, ctx.holder.session_key, reason)
      producer_config = %{tests: command, timeout_ms: timeout_ms}
      {_sup, runner} = start_runner(ctx, producer_config)

      %{queued: job_id} =
        Producers.__handle__(
          ctx.db,
          "run-tests",
          producer_call("run-tests", {:user, "flynn"}, assignment.id),
          config: producer_config,
          runner: runner
        )

      assert_wait(fn -> Producers.get(ctx.db, job_id).state == "failed" end)
      assert Assignments.list_attests(ctx.db, assignment.id) == []

      assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
               event.subject == assignment.id and event.detail =~ reason
             end)
    end

    remote_marker = Path.join(ctx.base_dir, "remote-ran")
    remote = session(ctx.db, "remote", "flynn", "claude", "anthropic", "remote-host")
    remote_assignment = assignment(ctx.db, remote.session_key, "remote")

    register_hosts(ctx.base_dir, %{
      "remote-host" => %{ssh: "remote", base_dir: "/remote"}
    })

    producer_config = %{tests: "printf remote > #{shell_quote(remote_marker)}", timeout_ms: 5_000}
    {_sup, runner} = start_runner(ctx, producer_config)

    %{queued: remote_id} =
      Producers.__handle__(
        ctx.db,
        "run-tests",
        producer_call("run-tests", {:user, "flynn"}, remote_assignment.id),
        config: producer_config,
        runner: runner
      )

    assert_wait(fn -> Producers.get(ctx.db, remote_id).state == "failed" end)
    refute File.exists?(remote_marker)
    assert Assignments.list_attests(ctx.db, remote_assignment.id) == []
  end

  test "run-smoke is symmetric and retiring a holder cancels its queued jobs", ctx do
    producer_config = %{smoke: "true", timeout_ms: 5_000}

    %{queued: cancelled_id} =
      Producers.__handle__(
        ctx.db,
        "run-smoke",
        producer_call("run-smoke", {:user, "flynn"}, ctx.assignment.id),
        config: producer_config
      )

    assert :ok = Producers.cancel_for_holder(ctx.db, ctx.holder.session_key)
    assert Producers.get(ctx.db, cancelled_id).state == "cancelled"

    second = assignment(ctx.db, ctx.holder.session_key, "smoke-success")
    {_sup, runner} = start_runner(ctx, producer_config)

    %{queued: smoke_id} =
      Producers.__handle__(
        ctx.db,
        "run-smoke",
        producer_call("run-smoke", {:user, "flynn"}, second.id),
        config: producer_config,
        runner: runner
      )

    assert_wait(fn -> Producers.get(ctx.db, smoke_id).state == "done" end)
    assert [verdict] = Assignments.list_attests(ctx.db, second.id)
    assert verdict.verdictKind == "real-run-passed"
    assert verdict.producer == "smoke"

    assert %{cancelled: ^smoke_id, noop: true} =
             Producers.__handle__(
               ctx.db,
               "cancel-producer-job",
               cancel_call({:user, "admin"}, smoke_id),
               runner: runner
             )

    assert Producers.get(ctx.db, smoke_id).state == "done"
    assert length(Assignments.list_attests(ctx.db, second.id)) == 1
  end

  test "public run-tests stays behind the gate until its async worker files the verdict", ctx do
    release = Path.join(ctx.base_dir, "release-produced-tests")
    command = "while [ ! -f #{shell_quote(release)} ]; do sleep 0.01; done"
    write_config(ctx.base_dir, "tests = #{JSON.encode!(command)}\ntimeout_ms = 5000\n")
    producer_config = Producers.load!(ctx.base_dir)
    {_sup, runner} = start_runner(ctx, producer_config)

    handlers =
      Gateway.handlers(%{
        db: ctx.db,
        producer_config: producer_config,
        producer_runner: runner
      })

    rules_dir = Path.join(ctx.base_dir, "identity/rules")
    File.mkdir_p!(rules_dir)

    File.write!(Path.join(rules_dir, "produced-tests.toml"), """
    [[rule]]
    name = "completion-needs-produced-tests"
    verb = "attest"
    text = "completion needs produced tests"
    [[rule.deny_when]]
    fact = "attest.kind"
    op = "eq"
    value = "completion"
    [[rule.deny_when]]
    fact = "assignment.produced_verdict_kinds"
    op = "not_in"
    value = ["tests-passed"]
    """)

    Rules.load!(ctx.base_dir, Map.keys(handlers), producer_config)
    completion = attest_call(ctx.holder.session_key, ctx.assignment.id, "completion")

    assert {:error, %{code: "rule_denied"}} =
             Dispatch.dispatch(ctx.db, handlers, completion)

    assert %{state: "open"} =
             Assignments.list(ctx.db, %{state: "all"})
             |> Enum.find(&(&1.id == ctx.assignment.id))

    assert {:ok, %{queued: job_id}} =
             Dispatch.dispatch(
               ctx.db,
               handlers,
               producer_call(
                 "run-tests",
                 {:session, ctx.holder.session_key},
                 ctx.assignment.id
               )
             )

    assert Producers.get(ctx.db, job_id).state in ["queued", "running"]
    assert Assignments.produced_verdict_kinds(ctx.db, ctx.assignment.id) == []

    assert {:error, %{code: "rule_denied"}} =
             Dispatch.dispatch(ctx.db, handlers, completion)

    File.write!(release, "run")
    assert_wait(fn -> Producers.get(ctx.db, job_id).state == "done" end)
    assert Assignments.produced_verdict_kinds(ctx.db, ctx.assignment.id) == ["tests-passed"]

    assert {:ok, %{assignment: %{state: "closed"}}} =
             Dispatch.dispatch(ctx.db, handlers, completion)
  end

  test "principal and assignment denials have pinned precedence", ctx do
    unconfigured = %{timeout_ms: 5_000}

    assert %{code: "process_denied"} =
             Producers.__handle__(
               ctx.db,
               "run-tests",
               producer_call("run-tests", {:process, "cron"}, ctx.assignment.id),
               config: unconfigured
             )

    assert %{code: "principal_required"} =
             Producers.__handle__(
               ctx.db,
               "run-tests",
               producer_call("run-tests", nil, ctx.assignment.id),
               config: unconfigured
             )

    assert %{code: "unknown_assignment"} =
             Producers.__handle__(
               ctx.db,
               "run-tests",
               producer_call("run-tests", {:user, "flynn"}, "missing"),
               config: unconfigured
             )

    assert %{assignment: closed} =
             Assignments.__handle__(ctx.db, "attest", %{
               verb: "attest",
               origin: "agent:holder",
               principal: {:session, ctx.holder.session_key},
               session_key: nil,
               params: %{assignment_id: ctx.assignment.id, kind: "completion"}
             })

    assert closed.state == "closed"

    assert %{code: "assignment_closed"} =
             Producers.__handle__(
               ctx.db,
               "run-tests",
               producer_call("run-tests", {:user, "flynn"}, ctx.assignment.id),
               config: unconfigured
             )
  end

  defp start_runner(ctx, _producer_config) do
    suffix = System.unique_integer([:positive])
    supervisor = :"producer_sup_#{suffix}"
    runner = :"producer_runner_#{suffix}"

    start_supervised!(%{
      id: supervisor,
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: supervisor]]}
    })

    start_supervised!(
      {Tightbeam.ProducerRunner,
       db: ctx.db,
       config: %{base_dir: ctx.base_dir, port: 1},
       supervisor: supervisor,
       name: runner},
      id: runner
    )

    {supervisor, runner}
  end

  defp producer_call(verb, principal, assignment_id) do
    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: %{assignment_id: assignment_id}
    }
  end

  defp attest_call(holder, assignment_id, kind) do
    %{
      verb: "attest",
      origin: "agent:#{holder}",
      principal: {:session, holder},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: kind}
    }
  end

  defp cancel_call(principal, job_id) do
    %{
      verb: "cancel-producer-job",
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: %{job_id: job_id}
    }
  end

  defp origin({:session, session}), do: "agent:#{session}"
  defp origin({:user, user}), do: "user:#{user}"
  defp origin({:process, process}), do: "process:#{process}"
  defp origin(nil), do: "unknown"

  defp assignment(db, holder, subject \\ "producer work") do
    Assignments.__handle__(db, "assign", %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      params: %{subject: subject}
    })
  end

  defp session(db, key, owner, harness, provider, host \\ nil) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: host || Tightbeam.Placement.local_host_name(),
      harness: harness,
      provider: provider,
      model: "model"
    })
  end

  defp write_config(base_dir, contents) do
    File.write!(Path.join(base_dir, "identity/producers.toml"), contents)
    commit_identity(base_dir, "update producers")
  end

  defp init_identity_repo(base_dir) do
    identity_dir = Path.join(base_dir, "identity")
    git!(identity_dir, ["init", "-q"])
    File.write!(Path.join(identity_dir, ".gitkeep"), "")
    git!(identity_dir, ["add", ".gitkeep"])
    git!(identity_dir, ["commit", "-q", "-m", "initialize identity"])
  end

  defp commit_identity(base_dir, message) do
    identity_dir = Path.join(base_dir, "identity")
    git!(identity_dir, ["add", "producers.toml"])
    git!(identity_dir, ["commit", "-q", "-m", message])
  end

  defp git!(identity_dir, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Tightbeam Test"},
      {"GIT_AUTHOR_EMAIL", "tightbeam@test.local"},
      {"GIT_COMMITTER_NAME", "Tightbeam Test"},
      {"GIT_COMMITTER_EMAIL", "tightbeam@test.local"}
    ]

    assert {_output, 0} =
             System.cmd("git", args, cd: identity_dir, stderr_to_stdout: true, env: env)
  end

  defp assert_wait(fun, attempts \\ 200)
  defp assert_wait(fun, 0), do: assert(fun.())

  defp assert_wait(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_wait(fun, attempts - 1)
    end
  end

  defp descendant_tree(base_dir, prefix) do
    %{
      root: Path.join(base_dir, "#{prefix}-root.pid"),
      child: Path.join(base_dir, "#{prefix}-child.pid"),
      grandchild: Path.join(base_dir, "#{prefix}-grandchild.pid"),
      finished: Path.join(base_dir, "#{prefix}-finished")
    }
  end

  defp descendant_command(tree) do
    child =
      "printf '%s' \"$$\" > #{shell_quote(tree.child)}; " <>
        "sleep 2 & printf '%s' \"$!\" > #{shell_quote(tree.grandchild)}; " <>
        "wait; printf finished > #{shell_quote(tree.finished)}"

    "printf '%s' \"$$\" > #{shell_quote(tree.root)}; sh -c #{shell_quote(child)} & wait"
  end

  defp descendant_pids_ready?(tree) do
    Enum.all?([tree.root, tree.child, tree.grandchild], &File.exists?/1)
  end

  defp descendant_pids(tree) do
    Enum.map([tree.root, tree.child, tree.grandchild], fn path ->
      path |> File.read!() |> String.trim() |> String.to_integer()
    end)
  end

  # Task #45. A signal's only failure channel on Unix is the exit status, so these
  # pin the three outcomes the cancel path must tell apart. Before the fix every one
  # of them returned a bare `:ok` and the job was recorded cancelled regardless.
  describe "producer kill verification" do
    test "a verified live group is signalled and records nothing", ctx do
      %{os_pid: os_pid, started: started} = spawn_leader("sleep 30")

      assert :signalled = Producers.kill_process_group(ctx.db, "job-ok", os_pid, started)
      assert kill_failures(ctx.db) == []
      wait_until_gone(os_pid)
    end

    test "a pid whose start time changed is NOT signalled", ctx do
      %{os_pid: os_pid, started: started} = spawn_leader("sleep 30")
      stale = started <> " (stale)"

      assert {:noop, why} = Producers.kill_process_group(ctx.db, "job-recycled", os_pid, stale)
      assert why =~ "recycled"

      # The refusal is the point: a pid we cannot match is somebody else's now, so
      # it must still be running afterwards.
      assert process_exists?(os_pid)
      assert kill_failures(ctx.db) == []
      System.cmd("kill", ["-TERM", "--", "-#{os_pid}"], stderr_to_stdout: true)
    end

    test "an unverifiable live pid is refused AND recorded", ctx do
      %{os_pid: os_pid} = spawn_leader("sleep 30")

      assert {:failed, why} = Producers.kill_process_group(ctx.db, "job-blind", os_pid, nil)
      assert why =~ "no captured start time"
      assert process_exists?(os_pid)

      assert [{"job-blind", detail}] = kill_failures(ctx.db)
      assert detail =~ "no captured start time"
      System.cmd("kill", ["-TERM", "--", "-#{os_pid}"], stderr_to_stdout: true)
    end

    test "a nonzero kill exit is reported as failed and recorded", ctx do
      # A non-leader child: `kill -TERM -<pid>` finds no process GROUP with that id,
      # so the kernel refuses with a nonzero exit. Identity still verifies, which is
      # what isolates the exit-status check from the identity check.
      %{os_pid: leader} = spawn_leader("sleep 30 & sleep 30")
      child = non_leader_child(leader)
      started = process_started!(child)

      assert {:failed, why} = Producers.kill_process_group(ctx.db, "job-exit", child, started)
      assert why =~ "exited"

      assert [{"job-exit", detail}] = kill_failures(ctx.db)
      assert detail =~ "exited 1"
      System.cmd("kill", ["-TERM", "--", "-#{leader}"], stderr_to_stdout: true)
    end

    test "an already-dead pid is a no-op, not a failure", ctx do
      %{os_pid: os_pid, started: started} = spawn_leader("true")
      wait_until_gone(os_pid)

      assert {:noop, why} = Producers.kill_process_group(ctx.db, "job-gone", os_pid, started)
      assert why =~ "already gone"
      assert kill_failures(ctx.db) == []
    end
  end

  defp spawn_leader(command) do
    shell = System.find_executable("sh")

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args,
         ["-c", "kill -STOP $$; exec \"$1\" -lc \"$2\"", "tightbeam-producer", shell, command]},
        {:cd, System.tmp_dir!()}
      ])

    os_pid = port |> Port.info(:os_pid) |> elem(1)
    started = process_started!(os_pid)
    # Wait for state T before CONT, exactly as Producers.verify_process_group/2
    # does in production. A SIGCONT that arrives before the shell has run its own
    # `kill -STOP $$` is simply lost, and the leader then stays STOPped forever —
    # so every later observation ("is it gone yet?") reads a process that never
    # ran. Cheap and invisible on an idle machine, which is why it survived here;
    # a loaded macOS runner lost the race and reported it as `:signalled` against
    # a pid the test believed was dead.
    wait_until_stopped(os_pid)
    # `--` before the negative target, for the reason Producers.deliver_signal/2
    # documents: without it procps-ng kill(1) exits 0 and delivers nothing, so on
    # linux the leader never resumes and never forks the children these tests read.
    System.cmd("kill", ["-CONT", "--", "-#{os_pid}"], stderr_to_stdout: true)
    %{port: port, os_pid: os_pid, started: started}
  end

  defp wait_until_stopped(os_pid) do
    Enum.reduce_while(1..1_000, nil, fn _, _ ->
      case System.cmd("ps", ["-o", "state=", "-p", Integer.to_string(os_pid)],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          # macOS appends flag letters (s, N, +) to the state, so read the first.
          if String.starts_with?(String.trim(output), "T"),
            do: {:halt, :stopped},
            else: Process.sleep(1) && {:cont, nil}

        _ ->
          Process.sleep(1) && {:cont, nil}
      end
    end) || flunk("the spawned leader never reached state T, so its SIGCONT would be lost")
  end

  # Poll, don't one-shot. Production reads the LEADER pid it holds through the port and
  # only AFTER verify_process_group/2 has polled it into state T (producers.ex), and its
  # process_started/1 returns nil rather than crashing — so production never races a
  # not-yet-visible process. This helper reads a CHILD discovered by a `ps -g` scan, and
  # on a loaded macOS runner `ps -p <child>` can return {"", 1} in the window before that
  # child is resolvable, which the one-shot `{output, 0} = ...` turned into a MatchError
  # that read as a producer defect. Wait for the pid to become observable, matching
  # wait_until_stopped/2 and verify_process_group/2; flunk clearly if it never does —
  # that WOULD be a real fault, and it still surfaces.
  defp process_started!(os_pid) do
    Enum.reduce_while(1..1_000, nil, fn _, _ ->
      case System.cmd("ps", ["-o", "lstart=", "-p", Integer.to_string(os_pid)],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          case String.trim(output) do
            "" -> Process.sleep(1) && {:cont, nil}
            started -> {:halt, started}
          end

        _ ->
          Process.sleep(1) && {:cont, nil}
      end
    end) ||
      flunk("pid #{os_pid} never became observable to `ps -o lstart` within the poll window")
  end

  defp non_leader_child(leader) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      {out, _} =
        System.cmd("ps", ["-o", "pid=", "-g", Integer.to_string(leader)], stderr_to_stdout: true)

      out
      |> String.split()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reject(&(&1 == leader))
      |> case do
        [child | _] -> {:halt, child}
        [] -> Process.sleep(10) && {:cont, nil}
      end
    end) || flunk("no non-leader child appeared in the producer group")
  end

  # Says so when it gives up. Silently returning nil made the caller assert the
  # WRONG thing: kill_process_group/4 was then handed a live pid and correctly
  # reported :signalled, and the failure read as a defect in the signal path
  # rather than as "the process this test needs dead is still running".
  defp wait_until_gone(os_pid) do
    Enum.reduce_while(1..300, nil, fn _, _ ->
      if process_exists?(os_pid), do: Process.sleep(10) && {:cont, nil}, else: {:halt, :gone}
    end) || flunk("pid #{os_pid} was still there after 3s; it was supposed to exit on its own")
  end

  defp kill_failures(db) do
    EventLog.lifecycle_events(db)
    |> Enum.filter(&(&1.kind == "producer_kill_failed"))
    |> Enum.map(&{&1.subject, &1.detail})
  end

  defp process_exists?(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "pid="], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
