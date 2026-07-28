defmodule Tightbeam.RailScriptTest do
  use Tightbeam.TestCase, async: false

  @release_binary Path.expand("../cli/target/release/tightbeam", __DIR__)
  @cli_dir Path.expand("../cli", __DIR__)

  # The real-binary integration test invokes @release_binary. `File.exists?` is not
  # enough — a STALE binary (built before rail-exec existed) passes existence yet fails
  # the subcommand. Refresh it to current before the suite so the test always exercises
  # code matching this checkout. Cached cargo makes this ~seconds after the first build;
  # a cargo-less environment leaves whatever exists and the compile-time guard skips.
  setup_all do
    if File.exists?(@release_binary) do
      _ = System.cmd("cargo", ["build", "--release"], cd: @cli_dir, stderr_to_stdout: true)
    end

    :ok
  end

  alias Tightbeam.{
    ConditionFacts,
    DB,
    Dispatch,
    Escalation,
    EventLog,
    Org,
    Placement,
    RailScript,
    Rules,
    Wakes
  }

  setup do
    db = :"rail_script_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Org.ensure_schema(db)
    :ok = EventLog.ensure_schema(db)
    :ok = ConditionFacts.ensure_schema(db)
    :ok = Escalation.ensure_schema(db)
    # Opening a request arms its owner notification wake in the same transaction.
    :ok = Wakes.ensure_schema(db)

    {tmp, 0} = System.cmd("/bin/realpath", [System.tmp_dir!()])

    base_dir =
      Path.join(String.trim(tmp), "tightbeam-rail-script-#{System.unique_integer([:positive])}")

    scripts = Path.join([base_dir, "identity", "rails", "scripts"])
    bin = Path.join(base_dir, "bin")
    File.mkdir_p!(scripts)
    File.mkdir_p!(bin)

    source_scripts = Path.expand("../identity/rails/scripts", __DIR__)

    for source <- Path.wildcard(Path.join(source_scripts, "*")) do
      destination = Path.join(scripts, Path.basename(source))
      File.cp!(source, destination)
      File.chmod!(destination, 0o755)
    end

    wrapper = Path.join(bin, "tightbeam")
    File.cp!(Path.expand("fixtures/rail_exec/tightbeam", __DIR__), wrapper)
    File.chmod!(wrapper, 0o755)

    holder =
      Org.create(db, %{
        session_key: "rail-holder",
        display_name: "Rail holder",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    on_exit(fn ->
      File.rm_rf!(base_dir)
      Rules.load!(System.tmp_dir!() <> "/missing-p4-rules-reset", [], %{})
    end)

    %{db: db, base_dir: base_dir, holder: holder}
  end

  test "decodes every rail-exec exit band and records one lifecycle row", ctx do
    cases = [
      {"rail-pass", {:ok, "pass", "returned"}},
      {"rail-out-of-set", {:error, "script_out_of_set", "out-of-set"}},
      {"rail-error", {:error, "script_error", "error:7"}},
      {"rail-timeout", {:error, "script_timeout", "timeout"}},
      {"rail-contained-refused", {:error, "script_contained_refused", "contained"}}
    ]

    for {script, expected} <- cases do
      assert RailScript.run(ctx.db, ctx.base_dir, rule(script), call(), nil) == expected
    end

    events = EventLog.lifecycle_events(ctx.db)
    assert length(events) == length(cases)
    assert Enum.all?(events, &(&1.kind == "rail_script" and &1.subject == "fixture-rail"))

    details = Enum.map(events, &JSON.decode!(&1.detail))

    assert Enum.map(details, & &1["exit_class"]) ==
             ~w(returned out-of-set error:7 timeout contained)

    assert Enum.all?(details, &(&1["edge"] == "verb" and &1["verb"] == "post"))

    # A refusal has to say WHY on a row that outlives the run. The wrapper writes its
    # reason to stderr, that stderr lives in the scratch dir, and the scratch dir is
    # deleted on the way out — so a host that refuses EVERY rail used to record nothing
    # but the class `contained`. That is the shape of the outage this seam exists because
    # of: failing closed, correctly, with nothing for anyone to read.
    contained = Enum.find(details, &(&1["exit_class"] == "contained"))
    assert contained["containment"] =~ "fixture refusal"

    # And only a refusal carries it — a normal verdict is not decorated with one.
    assert Enum.all?(
             Enum.reject(details, &(&1["exit_class"] == "contained")),
             &is_nil(&1["containment"])
           )
  end

  test "wrapper infrastructure failure fails closed and remains observable", ctx do
    File.rm!(Path.join([ctx.base_dir, "bin", "tightbeam"]))

    assert {:error, "script_error", exit_class} =
             RailScript.run(ctx.db, ctx.base_dir, rule("rail-pass"), call(), nil)

    assert String.starts_with?(exit_class, "error:")

    assert [%{kind: "rail_script", detail: detail}] = EventLog.lifecycle_events(ctx.db)
    assert %{"reason" => "script_error", "exit_class" => ^exit_class} = JSON.decode!(detail)
  end

  test "serializes a reserved remedy principal into script input", ctx do
    script = Path.join([ctx.base_dir, "identity", "rails", "scripts", "remedy-principal"])

    File.write!(
      script,
      """
      #!/bin/sh
      IFS= read -r input
      case "$input" in
        *'"principal":"remedy:assign:completion-needs-review"'*) printf pass ;;
        *) printf wrong ;;
      esac
      """
    )

    File.chmod!(script, 0o755)

    remedy_call =
      call()
      |> Map.put(
        :principal,
        {:remedy, %{statute: "completion-needs-review", action: "assign", owner: "flynn"}}
      )

    assert {:ok, "pass", "returned"} =
             RailScript.run(
               ctx.db,
               ctx.base_dir,
               rule("remedy-principal"),
               remedy_call,
               nil
             )
  end

  # This test used to assert `"timeout"` here — the SAME pair the fixture wrapper returns
  # when it genuinely times out — which is what locked the two origins together in the
  # record. Same subject, and now the proof they are distinguishable: the reason is
  # identical because both really are timeouts, and the class differs because only one of
  # them was reported by the wrapper (task #43).
  test "BEAM backstop closes a wrapper that outlives its timeout", ctx do
    wrapper = Path.join([ctx.base_dir, "bin", "tightbeam"])
    File.write!(wrapper, "#!/bin/sh\nexec /bin/sleep 30\n")
    File.chmod!(wrapper, 0o755)
    started = System.monotonic_time(:millisecond)

    assert {:error, "script_timeout", "unreported"} =
             RailScript.run(
               ctx.db,
               ctx.base_dir,
               put_in(rule("rail-pass").check.timeout_ms, 10),
               call(),
               nil
             )

    assert System.monotonic_time(:millisecond) - started < 2_500

    # The wrapper-reported timeout, through the same call, for contrast.
    File.cp!(Path.expand("fixtures/rail_exec/tightbeam", __DIR__), wrapper)
    File.chmod!(wrapper, 0o755)

    assert {:error, "script_timeout", "timeout"} =
             RailScript.run(ctx.db, ctx.base_dir, rule("rail-timeout"), call(), nil)
  end

  # Every class other than this one asserts an observation: `returned`/`out-of-set` read
  # the wrapper's stdout, `error:<N>` carries a child code parsed off wrapper stderr,
  # `timeout` means the wrapper's own timer elapsed, `contained` means the sandbox refused
  # to apply. Each of the paths below reaches a deny WITHOUT the observation, and each
  # used to record the value the observation would have carried — so a fabricated
  # `error:1` was byte-identical to a script that really did exit 1, and the invariant
  # "every failure names itself" could not be checked by anything (task #43).
  #
  # The `reason` column is deliberately unchanged from what each path recorded before.
  test "a deny reached without an observation is classed unreported, not fabricated", ctx do
    # Wrapper exit 10 promises the child's code on its stderr; here there is none.
    wrapper = Path.join([ctx.base_dir, "bin", "tightbeam"])
    File.write!(wrapper, "#!/bin/sh\nIFS= read -r _input\nexit 10\n")
    File.chmod!(wrapper, 0o755)

    assert {:error, "script_error", "unreported"} =
             RailScript.run(ctx.db, ctx.base_dir, rule("rail-pass"), call(), nil)

    # A substrate crash inside run/5 — a non-integer timeout raises in run_wrapper, which
    # the rescue catches. No script was ever spawned.
    assert {:error, "script_error", "unreported"} =
             RailScript.run(
               ctx.db,
               ctx.base_dir,
               put_in(rule("rail-pass").check.timeout_ms, :not_an_integer),
               call(),
               nil
             )

    # The holder named by the assignment does not exist, so invocation_context refuses
    # before any script runs.
    assert {:error, "script_error", "unreported"} =
             RailScript.run(
               ctx.db,
               ctx.base_dir,
               rule("rail-pass"),
               call(),
               %{holder_key: "no-such-holder"}
             )

    # The collision this closes: a script that really exits 1 still reports its own code,
    # and it is no longer the same string as any of the three above.
    script = Path.join([ctx.base_dir, "identity", "rails", "scripts", "rail-exit-1"])
    File.write!(script, "#!/bin/sh\nexit 1\n")
    File.chmod!(script, 0o755)
    File.cp!(Path.expand("fixtures/rail_exec/tightbeam", __DIR__), wrapper)
    File.chmod!(wrapper, 0o755)

    assert {:error, "script_error", "error:1"} =
             RailScript.run(ctx.db, ctx.base_dir, rule("rail-exit-1"), call(), nil)

    # All four are observable as separate rows carrying their own class.
    classes =
      EventLog.lifecycle_events(ctx.db)
      |> Enum.filter(&(&1.kind == "rail_script"))
      |> Enum.map(&JSON.decode!(&1.detail)["exit_class"])

    assert classes == ~w(unreported unreported unreported error:1)
  end

  # The `catch` half of the same rescue, which takes exits and throws rather than raises.
  # Reached in production when the DB process is down: `invocation_context` calls
  # `Org.get`, which exits `:noproc`. Nothing was spawned and nothing was observed, and
  # the row that would have recorded it cannot be written either — so the returned class
  # is the only place this can be said (task #43).
  test "a substrate exit is classed unreported, like a substrate raise", ctx do
    stop_supervised!(Tightbeam.DB)

    assert {:error, "script_error", "unreported"} =
             RailScript.run(
               ctx.db,
               ctx.base_dir,
               rule("rail-pass"),
               call(),
               %{holder_key: ctx.holder.session_key}
             )
  end

  # The recorded duration cannot locate a `script_timeout` in either timeout window, so
  # no timing rule can name the layer (task #38).
  #
  # `RailScript.run/5` measures with `System.monotonic_time` in the CALLING BEAM process
  # (rail_script.ex:13 and :27), while the wrapper is an OS process that keeps running on
  # its own clock. Starve the caller and the measurement inflates without bound. This runs
  # the REAL Rust rail-exec against the REAL sleeping `rail-timeout` script (`sleep 30`)
  # with a 2s budget, so the wrapper's own time-box is what ends the script — then
  # suspends the caller across the backstop threshold. The measurement lands
  # past `timeout_ms + 2_000`, which is where a naive reading would place the BEAM
  # backstop. The `+2_000` gap at rail_script.ex:166 is fixed in the CODE; the MEASUREMENT
  # is not, so the two windows overlap.
  #
  # Task #43 recorded the fact that DOES separate them, so this test now carries both
  # halves: the duration still misleads, and the exit class still reads binary-enforced
  # under exactly that inflation. A discriminator that survives the condition which broke
  # the timing rule is the point — if someone rebuilds the layer claim on top of the
  # duration, the second assertion here is what fails.
  if File.exists?(@release_binary) do
    test "starvation puts a real rail-exec timeout past the backstop threshold", ctx do
      wrapper = Path.join([ctx.base_dir, "bin", "tightbeam"])
      File.cp!(@release_binary, wrapper)
      File.chmod!(wrapper, 0o755)

      budget = 2_000

      task =
        Task.async(fn ->
          RailScript.run(
            ctx.db,
            ctx.base_dir,
            put_in(rule("rail-timeout").check.timeout_ms, budget),
            call(),
            nil
          )
        end)

      # Suspend the measuring process while the wrapper is still alive, and stay suspended
      # past budget + the 2_000ms backstop margin. 100 + 3_900 cleared that threshold by
      # exactly nothing, so the run's own clock starting a millisecond late — Task
      # scheduling latency — failed the assertion (observed at 3_998ms of a needed 4_000).
      # The margin is the point, not the total: the discriminator has to survive an
      # inflated measurement, and how far past it we are is arbitrary.
      Process.sleep(100)
      true = :erlang.suspend_process(task.pid)
      Process.sleep(4_400)
      :erlang.resume_process(task.pid)

      assert {:error, "script_timeout", "timeout"} = Task.await(task, 30_000)

      measured = Tightbeam.RailTimeoutEvidence.duration_ms(ctx.db)

      assert measured >= budget + 2_000,
             "expected the suspension to inflate the measurement past " <>
               "#{budget + 2_000}ms, got #{measured}ms"

      # The binary ran its timer to expiry and reported exit 20 — under a measurement
      # that says otherwise. The class is what the wrapper reported, so it is unmoved.
      assert Tightbeam.RailTimeoutEvidence.exit_class(ctx.db) == "timeout"

      evidence =
        Tightbeam.RailTimeoutEvidence.render(
          {:deny, %{rule: "fixture-rail", reason: "script_timeout"}},
          %{db: ctx.db, timeout_ms: budget}
        )

      # Named from the class, not from the numbers. A layer claim rebuilt on the
      # duration would read the other way here, because the duration is past the
      # backstop threshold on a run rail-exec genuinely enforced.
      assert evidence =~ "layer: RAIL-EXEC BINARY (enforcement)"
      assert evidence =~ "recorded exit class: timeout"
      assert evidence =~ "measured duration : #{measured}ms"
      assert evidence =~ "NOT the discriminator"
      refute evidence =~ "BEAM BACKSTOP"
    end
  else
    @tag :skip
    test "starvation puts a real rail-exec timeout past the backstop threshold" do
      flunk("real rail-exec binary missing: #{@release_binary}; cargo build --release in cli/")
    end
  end

  test "runs at the holder workdir with scratch as its only rail write root", ctx do
    workdir = Placement.holder_workdir(%{base_dir: ctx.base_dir, port: 0}, ctx.holder)
    File.write!(Path.join(workdir, ".rail-cwd-marker"), "cwd")
    assignment = %{holder_key: ctx.holder.session_key}

    assert {:ok, "pass", "returned"} =
             RailScript.run(
               ctx.db,
               ctx.base_dir,
               rule("rail-cwd-scratch"),
               call(%{assignment_id: "a1"}),
               assignment
             )

    assert File.exists?(Path.join(workdir, ".rail-cwd-marker"))
    refute File.exists?(Path.join(workdir, "rail-write"))
    assert Path.wildcard(Path.join([ctx.base_dir, "rails", "scratch", "*"])) == []
  end

  # The write wall is the real mechanism's to enforce, so it is asserted against the real
  # binary. It used to ride on the fixture double, which interposed `sandbox-exec` — so
  # this assertion held on macOS and could not hold on linux, which is how a macOS-only
  # containment mechanism stayed invisible under a green suite.
  if File.exists?(@release_binary) do
    test "a rail script cannot write outside its scratch root", ctx do
      wrapper = Path.join([ctx.base_dir, "bin", "tightbeam"])
      File.cp!(@release_binary, wrapper)
      File.chmod!(wrapper, 0o755)

      workdir = Placement.holder_workdir(%{base_dir: ctx.base_dir, port: 0}, ctx.holder)
      File.write!(Path.join(workdir, ".rail-cwd-marker"), "cwd")
      assignment = %{holder_key: ctx.holder.session_key}

      assert {:ok, "pass", "returned"} =
               RailScript.run(
                 ctx.db,
                 ctx.base_dir,
                 put_in(rule("rail-cwd-scratch").check.timeout_ms, 10_000),
                 call(%{assignment_id: "a1"}),
                 assignment
               )

      assert {:error, "script_error", _exit_class} =
               RailScript.run(
                 ctx.db,
                 ctx.base_dir,
                 put_in(rule("rail-write-workdir").check.timeout_ms, 10_000),
                 call(%{assignment_id: "a1"}),
                 assignment
               )

      refute File.exists?(Path.join(workdir, "rail-forbidden-write"))
    end
  else
    @tag skip:
           "real rail-exec integration binary missing: #{@release_binary}; run cargo build --release in cli/"
    test "a rail script cannot write outside its scratch root" do
      flunk("release binary is required when this test is enabled")
    end
  end

  test "remote holder fails closed before ensuring its workdir", ctx do
    remote_base = Path.join(ctx.base_dir, "remote-host")

    register_hosts(ctx.base_dir, %{
      "remote-testhost" => %{ssh: nil, base_dir: remote_base, cli_bin: nil}
    })

    on_exit(fn -> nil end)

    remote_holder =
      Org.create(ctx.db, %{
        session_key: "remote-rail-holder",
        display_name: "Remote rail holder",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "remote-testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    expected_workdir =
      Placement.workdir_path(%{base_dir: ctx.base_dir, port: 0}, remote_holder)

    refute File.exists?(expected_workdir)

    # The class used to be `error:1` — a child exit for a child that was never spawned,
    # and the same string a script that really exits 1 produces (task #43).
    assert {:error, "script_error", "unreported"} =
             RailScript.run(
               ctx.db,
               ctx.base_dir,
               rule("rail-pass"),
               call(%{assignment_id: "remote-a1"}),
               %{holder_key: remote_holder.session_key}
             )

    refute File.exists?(expected_workdir)
  end

  test "validates the nested check grammar and edge restrictions", ctx do
    valid = statute("rail-pass", %{"pass" => "allow"})
    put_statute(ctx, valid)

    assert [%{check: %{timeout_ms: 5_000}, edges: ["verb"]}] =
             Rules.load!(ctx.base_dir, ["post"], %{})

    cases = [
      {"[[rule]]\nname='empty'\nverb='post'\ntext='empty'\n", "at least one"},
      {String.replace(valid, "[rule.check]", "[check]"), "unknown root keys"},
      {String.replace(valid, "script = \"rail-pass\"", "script = \"missing\""), "executable"},
      {String.replace(valid, "returns = [\"pass\"]", "returns = []"), "non-empty unique"},
      {String.replace(valid, "returns = [\"pass\"]", "returns = [\"pass\", \"pass\"]"),
       "non-empty unique"},
      {String.replace(valid, "pass = \"allow\"", "other = \"allow\""), "map every"},
      {String.replace(valid, "pass = \"allow\"", "pass = \"rewrite\""), "one of"},
      {String.replace(valid, "[rule.check.effects]", "timeout_ms = 0\n[rule.check.effects]"),
       "1..60000"},
      {String.replace(valid, "text = \"fixture\"", "text = \"fixture\"\nedges = []"),
       "non-empty subset"},
      {String.replace(valid, "text = \"fixture\"", "text = \"fixture\"\nedges = [\"turn-end\"]"),
       "only for verb"},
      {String.replace(valid, "text = \"fixture\"", "text = \"fixture\"\neffect = \"deny\""),
       "predicate-only"}
    ]

    for {contents, message} <- cases do
      put_statute(ctx, contents)

      assert_raise ArgumentError, ~r/#{Regex.escape(message)}/, fn ->
        Rules.load!(ctx.base_dir, ["post"], %{})
      end
    end
  end

  test "routes edges and evaluates the predicate before the script", ctx do
    turn_end =
      statute("rail-deny", %{"blocked" => "deny"},
        verb: "attest",
        edges: ["turn-end"]
      )

    put_statute(ctx, turn_end)
    Rules.load!(ctx.base_dir, ["attest"], %{})
    attest = %{call(%{assignment_id: "a-edge"}) | verb: "attest"}

    assert {:allow, [], []} = Rules.decide(ctx.db, attest)
    assert EventLog.lifecycle_events(ctx.db) == []

    assert {{:deny, %{edge: "turn-end", ref: "a-edge"}}, [], []} =
             Rules.decide(ctx.db, Map.put(attest, :edge, :turn_end))

    put_statute(
      ctx,
      statute("rail-would-crash", %{"pass" => "allow"},
        predicate: ~s({ fact = "caller.origin_class", op = "eq", value = "agent" })
      )
    )

    Rules.load!(ctx.base_dir, ["post"], %{})
    before_count = length(EventLog.lifecycle_events(ctx.db))
    assert {:allow, [], []} = Rules.decide(ctx.db, call())
    assert length(EventLog.lifecycle_events(ctx.db)) == before_count

    assert {{:deny, %{reason: "script_error", script_exit_class: "error:99"}}, [], []} =
             Rules.decide(ctx.db, %{call() | origin: "agent:coder"})
  end

  test "escalate effects load cleanly for predicate and script statutes", ctx do
    predicate =
      """
      [[rule]]
      name = "predicate-escalate"
      verb = "post"
      text = "fixture"
      effect = "escalate"
      deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
      """

    for contents <- [predicate, statute("rail-pass", %{"pass" => "escalate"})] do
      put_statute(ctx, contents)
      assert [loaded] = Rules.load!(ctx.base_dir, ["post"], %{})

      assert loaded.effect == "escalate" or
               "escalate" in Map.values(loaded.check.effects)
    end
  end

  test "verb-edge escalation opens once, returns pending, and consumes an allow ruling", ctx do
    parent = self()

    escalated_call = %{
      call()
      | origin: "agent:rail-holder",
        principal: {:session, ctx.holder.session_key}
    }

    handlers = %{
      "post" => fn _call ->
        send(parent, :handler_ran)
        %{ok: true}
      end
    }

    put_statute(ctx, statute("rail-pass", %{"pass" => "escalate"}))
    Rules.load!(ctx.base_dir, ["post"], %{})

    assert {:decision_pending, id} = Dispatch.dispatch(ctx.db, handlers, escalated_call)
    refute_received :handler_ran

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE status = 'open'")

    assert {:decision_pending, ^id} = Dispatch.dispatch(ctx.db, handlers, escalated_call)
    refute_received :handler_ran

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")

    assert %{status: "ruled"} =
             Escalation.rule(
               ctx.db,
               %{
                 origin: "user:flynn",
                 principal: {:user, "flynn"},
                 params: %{request_id: id, decision: "allow"}
               },
               authorized: true
             )

    assert {:ok, %{ok: true}} = Dispatch.dispatch(ctx.db, handlers, escalated_call)
    assert_received :handler_ran

    assert {:ok, [["consumed"]]} =
             DB.query(ctx.db, "SELECT status FROM decision_requests WHERE id = ?1", [id])
  end

  test "decide is dry and evaluate preserves its collapsing legacy contract", ctx do
    put_statute(ctx, statute("rail-pass", %{"pass" => "allow"}))
    [loaded] = Rules.load!(ctx.base_dir, ["post"], %{})
    :persistent_term.put(Rules, [put_in(loaded.check.effects["pass"], "escalate")])

    assert {{:escalate, %{name: "script-escalate"}, %{question: "fixture"}, nil}, [], []} =
             Rules.decide(ctx.db, call())

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")
    assert [%{kind: "rail_script"}] = EventLog.lifecycle_events(ctx.db)

    assert {:deny, %{reason: "escalated"}} = Rules.evaluate(ctx.db, call())
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")
  end

  test "a contained check gates a real dispatch and rail_denials projects its payload", ctx do
    parent = self()

    handlers = %{
      "post" => fn _call ->
        send(parent, :handler_ran)
        %{ok: true}
      end
    }

    put_statute(ctx, statute("rail-pass", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"], %{})
    assert {:ok, %{ok: true}} = Dispatch.dispatch(ctx.db, handlers, call())
    assert_received :handler_ran
    assert EventLog.rail_denials(ctx.db, 0, 10) == []

    put_statute(ctx, statute("rail-deny", %{"blocked" => "deny"}))
    Rules.load!(ctx.base_dir, ["post"], %{})

    assert {:error,
            %{
              code: "rule_denied",
              rule: "script-escalate",
              edge: "verb",
              reason: "rule_denied",
              script_exit_class: "returned"
            }} = Dispatch.dispatch(ctx.db, handlers, call(%{work_item_id: "w1"}))

    refute_received :handler_ran

    assert [denial] = EventLog.rail_denials(ctx.db, 0, 10)
    assert denial.rule == "script-escalate"
    assert denial.edge == "verb"
    assert denial.reason == "rule_denied"
    assert denial.script_exit_class == "returned"
    assert denial.ref == "w1"
    assert denial.origin == "user:flynn"
    assert denial.principal == "user:flynn"
  end

  test "every non-pass exit class denies dispatch with the named legibility payload", ctx do
    handlers = %{"post" => fn _call -> flunk("a non-pass rail must not run the handler") end}

    cases = [
      {"rail-deny", %{"blocked" => "deny"}, "rule_denied", "returned"},
      {"rail-out-of-set", %{"pass" => "allow"}, "script_out_of_set", "out-of-set"},
      {"rail-error", %{"pass" => "allow"}, "script_error", "error:7"},
      {"rail-timeout", %{"pass" => "allow"}, "script_timeout", "timeout"},
      {"rail-contained-refused", %{"pass" => "allow"}, "script_contained_refused", "contained"}
    ]

    Enum.reduce(cases, 0, fn {script, effects, reason, exit_class}, since_id ->
      put_statute(ctx, statute(script, effects))
      Rules.load!(ctx.base_dir, ["post"], %{})

      assert {:error, %{reason: ^reason, script_exit_class: ^exit_class}} =
               Dispatch.dispatch(ctx.db, handlers, call(%{work_item_id: "w-bands"}))

      assert [denial] = EventLog.rail_denials(ctx.db, since_id, 10)
      assert denial.reason == reason
      assert denial.script_exit_class == exit_class
      denial.id
    end)

    assert length(EventLog.lifecycle_events(ctx.db)) == length(cases)
  end

  if File.exists?(@release_binary) do
    test "real Rust rail-exec matches BEAM framing for pass, deny, and escaped timeout", ctx do
      wrapper = Path.join([ctx.base_dir, "bin", "tightbeam"])
      File.cp!(@release_binary, wrapper)
      File.chmod!(wrapper, 0o755)

      assert {:ok, "pass", "returned"} =
               RailScript.run(
                 ctx.db,
                 ctx.base_dir,
                 put_in(rule("rail-pass").check.timeout_ms, 2_000),
                 call(),
                 nil
               )

      assert {:error, "script_out_of_set", "out-of-set"} =
               RailScript.run(
                 ctx.db,
                 ctx.base_dir,
                 put_in(rule("rail-deny").check.timeout_ms, 2_000),
                 call(),
                 nil
               )

      started = System.monotonic_time(:millisecond)

      assert {:error, "script_timeout", "timeout"} =
               RailScript.run(
                 ctx.db,
                 ctx.base_dir,
                 put_in(rule("rail-daemon-timeout").check.timeout_ms, 200),
                 call(),
                 nil
               )

      assert System.monotonic_time(:millisecond) - started < 1_000
    end

    # The fabrication this closes lived on the WRAPPER's side of the seam: the substrate
    # parses `tightbeam rail-exec child exit: <N>` off wrapper stderr and has no way to
    # disagree with it, so a made-up line there was undetectable by construction. The
    # `cli` suite asserts the binary's bytes; this asserts what the substrate ends up
    # recording, with the real binary in the path (task #43).
    test "a check whose input never arrived records unreported, not a child exit", ctx do
      wrapper = Path.join([ctx.base_dir, "bin", "tightbeam"])
      File.cp!(@release_binary, wrapper)
      File.chmod!(wrapper, 0o755)

      script = Path.join([ctx.base_dir, "identity", "rails", "scripts", "rail-ignores-stdin"])
      File.write!(script, "#!/bin/sh\nexit 0\n")
      File.chmod!(script, 0o755)

      # Over the pipe buffer, so the write blocks until the unreading script exits and
      # then fails. The script exits ZERO — `error:1` was false about the number AND
      # about there having been a child failure at all.
      oversized = call(%{work_item_id: String.duplicate("x", 512 * 1024)})

      assert {:error, "script_error", "unreported"} =
               RailScript.run(
                 ctx.db,
                 ctx.base_dir,
                 put_in(rule("rail-ignores-stdin").check.timeout_ms, 5_000),
                 oversized,
                 nil
               )

      assert [%{kind: "rail_script", detail: detail}] = EventLog.lifecycle_events(ctx.db)
      assert JSON.decode!(detail)["exit_class"] == "unreported"
    end
  else
    @tag skip:
           "real rail-exec integration binary missing: #{@release_binary}; run cargo build --release in cli/"
    test "real Rust rail-exec matches BEAM framing for pass, deny, and escaped timeout" do
      flunk("release binary is required when this test is enabled")
    end

    @tag skip:
           "real rail-exec integration binary missing: #{@release_binary}; run cargo build --release in cli/"
    test "a check whose input never arrived records unreported, not a child exit" do
      flunk("release binary is required when this test is enabled")
    end
  end

  defp rule(script) do
    %{
      name: "fixture-rail",
      check: %{script: script, returns: ["pass"], timeout_ms: 100, effects: %{"pass" => "allow"}}
    }
  end

  defp call(params \\ %{}) do
    %{
      verb: "post",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: params
    }
  end

  defp statute(script, effects, opts \\ []) do
    verb = Keyword.get(opts, :verb, "post")
    edges = Keyword.get(opts, :edges)
    predicate = Keyword.get(opts, :predicate)

    """
    [[rule]]
    name = "script-escalate"
    verb = "#{verb}"
    text = "fixture"
    #{if edges, do: "edges = #{inspect(edges)}", else: ""}
    #{if predicate, do: "deny_when = [#{predicate}]", else: ""}
    [rule.check]
    script = "#{script}"
    returns = #{inspect(Map.keys(effects))}
    [rule.check.effects]
    #{Enum.map_join(effects, "\n", fn {token, effect} -> "#{token} = \"#{effect}\"" end)}
    """
  end

  defp put_statute(ctx, contents) do
    path = Path.join([ctx.base_dir, "identity", "rules", "p4.toml"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end
end
