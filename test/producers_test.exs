defmodule Tightbeam.ProducersTest do
  use ExUnit.Case, async: false

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

    for module <- [Devices, Idempotency, Org, Roles, WorkItems, Assignments, EventLog, Producers] do
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

  test "cancel winning against a running command prevents the success verdict", ctx do
    started = Path.join(ctx.base_dir, "started")
    finished = Path.join(ctx.base_dir, "finished")

    command =
      "printf started > #{shell_quote(started)}; sh -c #{shell_quote("sleep 5; printf finished > #{shell_quote(finished)}")} & wait"

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
      File.exists?(started) and Producers.get(ctx.db, job_id).state == "running"
    end)

    assert %{cancelled: ^job_id} =
             Producers.__handle__(
               ctx.db,
               "cancel-producer-job",
               cancel_call({:session, ctx.holder.session_key}, job_id),
               runner: runner
             )

    assert_wait(fn -> Producers.get(ctx.db, job_id).state == "cancelled" end)
    Process.sleep(100)
    refute File.exists?(finished)
    assert Assignments.list_attests(ctx.db, ctx.assignment.id) == []
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

    Application.put_env(:tightbeam, :hosts, %{
      "remote-host" => %{ssh: "remote", base_dir: "/remote"}
    })

    on_exit(fn -> Application.delete_env(:tightbeam, :hosts) end)
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

  test "produced-tests gate stays denied until the async runner files its verdict", ctx do
    write_config(ctx.base_dir, "tests = \"true\"\ntimeout_ms = 5000\n")
    producer_config = Producers.load!(ctx.base_dir)
    handlers = Gateway.handlers(%{db: ctx.db})
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

    {_sup, runner} = start_runner(ctx, producer_config)

    assert %{queued: job_id} =
             Producers.__handle__(
               ctx.db,
               "run-tests",
               producer_call(
                 "run-tests",
                 {:session, ctx.holder.session_key},
                 ctx.assignment.id
               ),
               config: producer_config,
               runner: runner
             )

    assert_wait(fn -> Producers.get(ctx.db, job_id).state == "done" end)

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

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
