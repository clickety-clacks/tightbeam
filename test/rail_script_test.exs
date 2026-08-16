defmodule Tightbeam.RailScriptTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  @release_binary Path.expand("../cli/target/release/tightbeam", __DIR__)
  @cli_dir Path.expand("../cli", __DIR__)

  # The real-binary integration test invokes @release_binary, and `File.exists?`
  # is not enough: a STALE binary (built before rail-exec existed) passes
  # existence yet fails the subcommand. That is a real hazard and this guard
  # still covers it.
  #
  # It USED to cover it by running `cargo build --release` here. That rebuilt a
  # SHARED artifact in the middle of the suite — cli/target/release/tightbeam is
  # read by absolute path from test_helper, containment, conformance and
  # cli_integration too — so a test could read the file inside cargo's
  # replacement window and exercise a binary that was not this checkout's.
  # Measured, not theorised (att_9e4e06df): a failing run read md5 53504aa9 from
  # that path while the on-disk artifact immediately before and after was
  # b3e23ad8. Intermittent, and invisible to a before/after comparison because
  # the file is restored.
  #
  # So the protection is now a REFUSAL rather than a mutation: assert the binary
  # is at least as new as the sources that produce it, and if it is not, say so
  # and name the exact command. A test suite may depend on a shared artifact; it
  # must not rewrite one while its neighbours are reading it.
  setup_all do
    if File.exists?(@release_binary) do
      built_at = File.stat!(@release_binary).mtime

      newest_source =
        [Path.join(@cli_dir, "Cargo.toml") | Path.wildcard(Path.join(@cli_dir, "src/**/*.rs"))]
        |> Enum.filter(&File.exists?/1)
        |> Enum.map(&File.stat!(&1).mtime)
        |> Enum.max(fn -> built_at end)

      if newest_source > built_at do
        flunk("""
        the release CLI is older than cli/ sources, so real-binary tests would
        exercise code that is not this checkout:

            #{@release_binary}

        Build it before the gate, which is what AGENTS.md already requires:

            cargo build --release --manifest-path cli/Cargo.toml

        This check deliberately does NOT rebuild: the binary is shared with
        other test files that read it by absolute path, and rebuilding it here
        replaces it underneath them mid-run (att_9e4e06df).
        """)
      end
    end

    :ok
  end

  alias Tightbeam.{
    ConditionFacts,
    DB,
    Dispatch,
    Escalation,
    EventLog,
    RailEpisodes,
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
    :ok = Placement.ensure_schema(db)

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
        model: Model.new("fable")
      })

    on_exit(fn ->
      File.rm_rf!(base_dir)
      Rules.load!(System.tmp_dir!() <> "/missing-p4-rules-reset", [])
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
    workdir = Placement.holder_workdir(%{base_dir: ctx.base_dir, db: ctx.db, port: 0}, ctx.holder)
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

      workdir =
        Placement.holder_workdir(%{base_dir: ctx.base_dir, db: ctx.db, port: 0}, ctx.holder)

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

    register_hosts(ctx.db, %{
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
        model: Model.new("fable")
      })

    expected_workdir =
      Placement.workdir_path(%{base_dir: ctx.base_dir, db: ctx.db, port: 0}, remote_holder)

    # The workdir must resolve under the REGISTERED host's base, which is what makes
    # this a remote-holder case at all. Without this the test passed identically with
    # `remote-testhost` never registered — an unregistered host also refuses, so every
    # assertion below held for the wrong reason and the registration above proved
    # nothing (#79).
    assert String.starts_with?(expected_workdir, remote_base)

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
             Rules.load!(ctx.base_dir, ["post"])

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
        Rules.load!(ctx.base_dir, ["post"])
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
    Rules.load!(ctx.base_dir, ["attest"])
    attest = %{call(%{assignment_id: "a-edge"}) | verb: "attest"}

    assert {:allow, [], []} = Rules.decide(ctx.db, attest)
    assert EventLog.lifecycle_events(ctx.db) == []

    # What this pins is the EDGE: the statute is reached at turn-end and not at the verb
    # edge, and the payload carries the gated ref. It is not the script's verdict — this
    # suite has no `assignments` table, so `a-edge` never resolves and the check is never
    # spawned. The old assertion named neither reason nor class, which is how it sat here
    # asserting a fabricated `error:1` without anyone seeing it.
    assert {{:deny_escalate, %{name: "script-escalate"},
             %{
               error: %{
                 edge: "turn-end",
                 ref: "a-edge",
                 reason: "script_error",
                 script_exit_class: "unreported"
               }
             }}, [], []} = Rules.decide(ctx.db, Map.put(attest, :edge, :turn_end))

    put_statute(
      ctx,
      statute("rail-would-crash", %{"pass" => "allow"},
        predicate: ~s({ fact = "caller.origin_class", op = "eq", value = "agent" })
      )
    )

    Rules.load!(ctx.base_dir, ["post"])
    before_count = length(EventLog.lifecycle_events(ctx.db))
    assert {:allow, [], []} = Rules.decide(ctx.db, call())
    assert length(EventLog.lifecycle_events(ctx.db)) == before_count

    # A crashing script is a malfunction, so the decision carries the summons alongside
    # the unchanged deny (§A3); `decide` still opens nothing.
    assert {{:deny_escalate, %{name: "script-escalate"},
             %{error: %{reason: "script_error", script_exit_class: "error:99"}}}, [], []} =
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
      assert [loaded] = Rules.load!(ctx.base_dir, ["post"])

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
    Rules.load!(ctx.base_dir, ["post"])

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
    [loaded] = Rules.load!(ctx.base_dir, ["post"])
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
    Rules.load!(ctx.base_dir, ["post"])
    assert {:ok, %{ok: true}} = Dispatch.dispatch(ctx.db, handlers, call())
    assert_received :handler_ran
    assert EventLog.rail_denials(ctx.db, 0, 10) == []

    put_statute(ctx, statute("rail-deny", %{"blocked" => "deny"}))
    Rules.load!(ctx.base_dir, ["post"])

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
      Rules.load!(ctx.base_dir, ["post"])

      assert {:error, %{reason: ^reason, script_exit_class: ^exit_class}} =
               Dispatch.dispatch(ctx.db, handlers, call(%{work_item_id: "w-bands"}))

      assert [denial] = EventLog.rail_denials(ctx.db, since_id, 10)
      assert denial.reason == reason
      assert denial.script_exit_class == exit_class
      denial.id
    end)

    events = EventLog.lifecycle_events(ctx.db)
    assert Enum.count(events, &(&1.kind == "rail_script")) == length(cases)

    # Four of these five also summon a mind (§A3). The one that does not is `rail-deny`:
    # the sensor answered with a declared token that the statute maps to `deny`. Every
    # other row is a malfunction — a clock, a crash, a refusal, a token outside the
    # declared set — and each opens its own episode, because the key is the exit class.
    assert Enum.count(events, &(&1.kind == "decision_request_opened")) == 4
  end

  # Flynn's ruling (§A3, 2026-07-29): "no sensor malfunction silently decides against
  # work." The two halves pull in opposite directions, so both are asserted: the denial
  # the caller receives is the one it received before the ruling, AND a decision request
  # now names the statute behind it.
  test "a timeout denies exactly as before and additionally summons a mind", ctx do
    handlers = %{"post" => fn _call -> flunk("a timed-out rail must not run the handler") end}

    put_statute(ctx, statute("rail-timeout", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])

    assert {:error,
            %{
              code: "rule_denied",
              rule: "script-escalate",
              edge: "verb",
              reason: "script_timeout",
              script_exit_class: "timeout",
              ref: "w-timeout"
            }} = Dispatch.dispatch(ctx.db, handlers, call(%{work_item_id: "w-timeout"}))

    # The denial stands on its own row, unchanged and independent of the summons.
    assert [denial] = EventLog.rail_denials(ctx.db, 0, 10)
    assert denial.reason == "script_timeout"
    assert denial.script_exit_class == "timeout"

    assert [%{"exit_class" => "timeout", "reason" => "script_timeout"}] =
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.filter(&(&1.kind == "rail_script"))
             |> Enum.map(&JSON.decode!(&1.detail))

    # And the summons carries what a mind needs to adjudicate the sensor: which statute,
    # which reason code, which exit class.
    assert {:ok, [["script-escalate", question, "open"]]} =
             DB.query(ctx.db, "SELECT statuteName, question, status FROM decision_requests")

    assert question =~ "script-escalate"
    assert question =~ "denied script_timeout"
    assert question =~ "script_exit_class timeout"
  end

  # The other producer of `script_timeout`: the wrapper never reports and the BEAM
  # backstop closes the port at `timeout_ms + 2_000`, recording `unreported`. A ten-
  # millisecond budget against a wrapper that sleeps for thirty seconds makes the expiry
  # deterministic rather than load-dependent.
  test "the backstop producer summons too, and a retry opens no second request", ctx do
    handlers = %{"post" => fn _call -> flunk("a timed-out rail must not run the handler") end}

    wrapper = Path.join([ctx.base_dir, "bin", "tightbeam"])
    File.write!(wrapper, "#!/bin/sh\nexec /bin/sleep 30\n")
    File.chmod!(wrapper, 0o755)

    put_statute(ctx, statute("rail-pass", %{"pass" => "allow"}, timeout_ms: 10))
    Rules.load!(ctx.base_dir, ["post"])
    timed_out = call(%{work_item_id: "w-backstop"})

    assert {:error, %{reason: "script_timeout", script_exit_class: "unreported"}} =
             Dispatch.dispatch(ctx.db, handlers, timed_out)

    assert {:ok, [["script-escalate", "open"]]} =
             DB.query(ctx.db, "SELECT statuteName, status FROM decision_requests")

    # The same call times out again. The deny recurs — it must — but the mind is already
    # summoned, and escalation's one-open-request index is what keeps it single.
    assert {:error, %{reason: "script_timeout", script_exit_class: "unreported"}} =
             Dispatch.dispatch(ctx.db, handlers, timed_out)

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")
  end

  # A crash, a containment refusal, and a token outside the declared set are malfunctions
  # for the same reason a timeout is: something other than a mind decided, and the
  # available repairs differ per class, so each carries its own reason code and class into
  # its own episode.
  test "every malfunction class summons a mind naming its own reason and class", ctx do
    handlers = %{"post" => fn _call -> flunk("a non-pass rail must not run the handler") end}

    cases = [
      {"rail-error", "script_error", "error:7"},
      {"rail-out-of-set", "script_out_of_set", "out-of-set"},
      {"rail-contained-refused", "script_contained_refused", "contained"}
    ]

    for {script, reason, exit_class} <- cases do
      put_statute(ctx, statute(script, %{"pass" => "allow"}))
      Rules.load!(ctx.base_dir, ["post"])

      assert {:error, %{reason: ^reason, script_exit_class: ^exit_class}} =
               Dispatch.dispatch(ctx.db, handlers, call(%{work_item_id: "w-#{script}"}))
    end

    assert {:ok, rows} =
             DB.query(
               ctx.db,
               "SELECT question, status FROM decision_requests ORDER BY rowid"
             )

    assert length(rows) == 3

    for {[question, status], {_script, reason, exit_class}} <- Enum.zip(rows, cases) do
      assert status == "open"
      assert question =~ "denied #{reason}"
      assert question =~ "script_exit_class #{exit_class}"
    end
  end

  # The one non-pass outcome that is NOT a malfunction: the script answered, with a
  # declared token, and `[rule.check.effects]` maps that token to `deny`. The sensor did
  # its job — there is nothing for a mind to repair, so nobody is summoned.
  test "a token-mapped deny is the sensor answering, and summons nobody", ctx do
    handlers = %{"post" => fn _call -> flunk("a denied rail must not run the handler") end}

    put_statute(ctx, statute("rail-deny", %{"blocked" => "deny"}))
    Rules.load!(ctx.base_dir, ["post"])

    assert {:error, %{reason: "rule_denied", script_exit_class: "returned"}} =
             Dispatch.dispatch(ctx.db, handlers, call(%{work_item_id: "w-token-deny"}))

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")
  end

  # DEDUP (§A3): one live episode per (statute, script_exit_class). The key is the
  # CONDITION, not the caller and not the action — two different callers tripping the same
  # broken check land on one episode, which is what stops a retry loop from storming the
  # engine. Two different classes on the same statute stay separate, because they are
  # different repairs.
  test "identical malfunctions share one episode; different classes get their own", ctx do
    handlers = %{"post" => fn _call -> flunk("a non-pass rail must not run the handler") end}

    put_statute(ctx, statute("rail-timeout", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])

    # Same statute, same class, but a different caller AND a different action each time.
    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, call(%{work_item_id: "w-one"}))

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, %{
               call(%{work_item_id: "w-two"})
               | origin: "agent:rail-holder",
                 principal: {:session, ctx.holder.session_key}
             })

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE status = 'open'")

    # A different class on the same statute is a different malfunction and a different fix.
    put_statute(ctx, statute("rail-error", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])

    assert {:error, %{script_exit_class: "error:7"}} =
             Dispatch.dispatch(ctx.db, handlers, call(%{work_item_id: "w-one"}))

    assert {:ok, [[2]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE status = 'open'")
  end

  # AUTO-CLOSE (§A3): recovery is automatic when the cause heals. An observed verdict —
  # pass OR a genuine token-deny — means the check is rendering verdicts again, which is
  # the repair itself. No operator verb, and the episode must not linger demanding that a
  # mind acknowledge a sensor that already recovered.
  test "an observed verdict closes the episode with no operator verb", ctx do
    parent = self()

    handlers = %{
      "post" => fn _call ->
        send(parent, :handler_ran)
        %{ok: true}
      end
    }

    heal = call(%{work_item_id: "w-heal"})

    load = fn script, effects ->
      put_statute(ctx, statute(script, effects))
      Rules.load!(ctx.base_dir, ["post"])
    end

    open_episodes = fn ->
      {:ok, [[count]]} =
        DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE status = 'open'")

      count
    end

    load.("rail-timeout", %{"pass" => "allow"})
    assert {:error, %{script_exit_class: "timeout"}} = Dispatch.dispatch(ctx.db, handlers, heal)
    assert {:ok, [[id, "open"]]} = DB.query(ctx.db, "SELECT id, status FROM decision_requests")

    # The check recovers and passes.
    load.("rail-pass", %{"pass" => "allow"})
    assert {:ok, %{ok: true}} = Dispatch.dispatch(ctx.db, handlers, heal)
    assert_received :handler_ran

    assert {:ok, [["withdrawn", "process:tightbeam", "sensor-recovered"]]} =
             DB.query(
               ctx.db,
               "SELECT status, withdrawnBy, withdrawnReason FROM decision_requests WHERE id = ?1",
               [id]
             )

    # It breaks again, and a fresh episode opens — the closure was recovery, not a mute.
    load.("rail-timeout", %{"pass" => "allow"})
    assert {:error, %{script_exit_class: "timeout"}} = Dispatch.dispatch(ctx.db, handlers, heal)
    assert open_episodes.() == 1

    # A genuine token-deny is an observed verdict too, and closes the episode just as a
    # pass does: what healed is the sensor, not the verdict it renders.
    load.("rail-deny", %{"blocked" => "deny"})

    assert {:error, %{reason: "rule_denied", script_exit_class: "returned"}} =
             Dispatch.dispatch(ctx.db, handlers, heal)

    assert open_episodes.() == 0
  end

  # The malfunction that never reached the engine: the invocation context could not be
  # resolved, so NO script was spawned — the third `unreported` row of §A3's table. It
  # recorded `error:1`, a child exit asserted for a child that never existed and
  # byte-identical to a script that really did exit 1. That is task #43's fabrication,
  # surviving here because it sits a level above `rail_script.ex` where the rest of it
  # was cleaned out.
  test "an unresolvable invocation context records unreported, never a fabricated exit", ctx do
    handlers = %{
      "post" => fn _call -> flunk("an unresolved context must not run the handler") end
    }

    put_statute(ctx, statute("rail-pass", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])

    # This suite has no `assignments` table, so resolving the named assignment raises
    # inside the fact and the check is never spawned.
    unresolvable = call(%{assignment_id: "a-missing"})

    assert {:error,
            %{
              code: "rule_denied",
              rule: "script-escalate",
              reason: "script_error",
              script_exit_class: exit_class,
              ref: "a-missing"
            }} = Dispatch.dispatch(ctx.db, handlers, unresolvable)

    assert exit_class == "unreported"
    refute exit_class == "error:1"

    assert [denial] = EventLog.rail_denials(ctx.db, 0, 10)
    assert denial.script_exit_class == "unreported"

    # Nothing was spawned, so nothing wrote a rail_script row to disagree with.
    assert ctx.db |> EventLog.lifecycle_events() |> Enum.filter(&(&1.kind == "rail_script")) == []

    # And the episode carries the class the missing observation would have carried.
    assert {:ok, [["script-escalate", question, "open"]]} =
             DB.query(ctx.db, "SELECT statuteName, question, status FROM decision_requests")

    assert question =~ "denied script_error"
    assert question =~ "script_exit_class unreported"
  end

  # BLOCKING review finding. Recovery used to be ordered by the ACTOR's delayed mutation
  # instead of by what the evaluation observed: `decide` read "this statute has an open
  # episode", and the actor later withdrew EVERY open episode for that statute — including
  # ones opened in the interval between. A malfunction landing inside that window was
  # silenced without being repaired, which is exactly the state §A3 forbids. Expressed
  # sequentially here rather than with racing processes, because the hazard is the
  # ordering, not the concurrency: these are the operations in the order that breaks it.
  test "a malfunction landing after a healthy evaluation is not swept away by it", ctx do
    handlers = %{"post" => fn _call -> %{ok: true} end}
    subject = call(%{work_item_id: "w-race"})

    load = fn script ->
      put_statute(ctx, statute(script, %{"pass" => "allow"}))
      Rules.load!(ctx.base_dir, ["post"])
    end

    # An episode is open for the timeout class.
    load.("rail-timeout")

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    # A healthy evaluation observes it and is handed the close — but its actor has NOT run.
    load.("rail-pass")
    {_decision, to_close, _to_consume} = Rules.decide(ctx.db, subject)
    assert [{:episodes, "script-escalate", position}] = to_close

    # Inside that interval a different malfunction opens its own episode.
    load.("rail-error")

    assert {:error, %{script_exit_class: "error:7"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    # A real cutoff was minted, and it predates this summons — the writer holds the
    # ordering, so the proof of it is behavioral rather than a number read back out of
    # SQL. That is the point of the redesign: there is no table quantity left to compare.
    assert {_incarnation, seq} = position
    assert is_integer(seq)

    # Only now does the delayed actor run the close it was handed.
    Enum.each(to_close, fn {:episodes, name, mark} ->
      RailEpisodes.recovered(ctx.db, name, mark)
    end)

    # The observed episode recovered; the one that arrived afterwards still summons.
    assert {:ok, [["episode:timeout", "withdrawn"], ["episode:error:7", "open"]]} =
             DB.query(ctx.db, "SELECT actionKey, status FROM decision_requests ORDER BY rowid")
  end

  # The same interleaving through the ATTACH path, which the class-differing case above
  # cannot reach. A recurrence of a class already open writes NO new row — `ON CONFLICT DO
  # NOTHING` — so any cutoff taken over rows is blind to it. The writer is not: it stamps
  # the attach with its own sequence, inside the process that also decides the closure.
  test "a same-class recurrence attaching to an open episode is not swept away", ctx do
    handlers = %{"post" => fn _call -> %{ok: true} end}
    subject = call(%{work_item_id: "w-samekey"})

    load = fn script ->
      put_statute(ctx, statute(script, %{"pass" => "allow"}))
      Rules.load!(ctx.base_dir, ["post"])
    end

    load.("rail-timeout")

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    assert {:ok, [[id]]} = DB.query(ctx.db, "SELECT id FROM decision_requests")

    # A healthy evaluation observes it and is handed the close — its actor has NOT run.
    load.("rail-pass")
    {_decision, [{:episodes, name, position}], _} = Rules.decide(ctx.db, subject)

    # The SAME class malfunctions again inside the interval, and attaches.
    load.("rail-timeout")

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    # No new row: this is precisely why any row-ordered cutoff was blind to it. The writer
    # is not, because it stamped the attach with its own sequence.
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")
    assert {_incarnation, seq} = position
    assert is_integer(seq)

    # The delayed actor runs its now-stale close.
    :ok = RailEpisodes.recovered(ctx.db, name, position)

    # The recurrence was never repaired, so its episode still summons.
    assert {:ok, [["open"]]} =
             DB.query(ctx.db, "SELECT status FROM decision_requests WHERE id = ?1", [id])
  end

  # THE VERDICT WINDOW — the interleaving that killed the previous two designs, and the
  # test that pins WHERE the cutoff is minted rather than merely asserting the outcome.
  #
  # The earlier version of this test called `RailEpisodes.evaluating/3` by hand, so moving
  # the production mint after `RailScript.run/5` would not have failed it — it proved the
  # writer works, not that `decide` mints at the right moment. The fix is to make the
  # healthy evaluation the REAL `Rules.decide/2` path and land the malfunction WHILE its
  # check is still executing. A cutoff minted before the check is below that summons; a
  # cutoff minted after the check is above it and sweeps it.
  #
  # The ordering is deterministic, not timed: the healthy script blocks until this test
  # releases it, and we wait on the writer's own sequence to prove the mint happened
  # before firing the malfunction. A slow box makes this test RED, never falsely green.
  test "the healthy evaluation's cutoff is minted before its check runs", ctx do
    handlers = %{"post" => fn _call -> %{ok: true} end}
    subject = call(%{work_item_id: "w-mint-point"})
    release = Path.join(ctx.base_dir, "release-the-check")

    load = fn script ->
      put_statute(ctx, statute(script, %{"pass" => "allow"}))
      Rules.load!(ctx.base_dir, ["post"])
    end

    # A healthy check that hangs until released. Reads are permitted under the rail
    # profile, so waiting on a file it can only observe is legal inside containment.
    blocking = Path.join([ctx.base_dir, "identity", "rails", "scripts", "rail-blocks"])

    File.write!(
      blocking,
      "#!/bin/sh\nwhile [ ! -f #{release} ]; do sleep 0.02; done\nprintf pass\n"
    )

    File.chmod!(blocking, 0o755)

    # An episode is open for the timeout class.
    load.("rail-timeout")

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    assert {:ok, [[id]]} = DB.query(ctx.db, "SELECT id FROM decision_requests")

    before_seq = writer_seq()
    load.("rail-blocks")

    # The real decide path: it mints, then blocks inside the check.
    evaluation = Task.async(fn -> Rules.decide(ctx.db, subject) end)

    # Proof we are PAST the mint and INSIDE the check — the writer's sequence moved and
    # the script has not been released. No sleep, no guess.
    wait_until(
      fn -> writer_seq() > before_seq end,
      "the writer's sequence never moved while the check was still running, so the " <>
        "evaluation did not mint its cutoff BEFORE running the check"
    )

    # The malfunction lands here, in the window a post-check mint would have covered.
    load.("rail-timeout")

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    File.touch!(release)

    assert {_decision, [{:episodes, name, position}], _} = Task.await(evaluation, 30_000)
    assert {_incarnation, seq} = position
    assert is_integer(seq)

    # The actor enacts the healthy evaluation's recovery.
    :ok = RailEpisodes.recovered(ctx.db, name, position)

    # The malfunction that happened while the check was running still summons a mind.
    assert {:ok, [["open"]]} =
             DB.query(ctx.db, "SELECT status FROM decision_requests WHERE id = ?1", [id])
  end

  # BOUNDED WRITER STATE. An episode adjudicated by a mind leaves the open set without the
  # writer withdrawing it, so a recovery that dropped only what IT withdrew would keep that
  # episode's entry for the life of the process — unbounded under repeated adjudication.
  #
  # The forgetting happens at the EVALUATION's read of the open set, not at recovery.
  # Recovery never runs in this scenario at all: nothing is open once the ruling lands, so
  # no recovery is ever scheduled. That is exactly why pruning at recovery — the obvious
  # place — cannot fix this leak, and why this test drives a plain healthy evaluation
  # rather than a recovery.
  test "an externally adjudicated episode is forgotten at the next evaluation", ctx do
    handlers = %{"post" => fn _call -> %{ok: true} end}
    subject = call(%{work_item_id: "w-bounded"})

    load = fn script ->
      put_statute(ctx, statute(script, %{"pass" => "allow"}))
      Rules.load!(ctx.base_dir, ["post"])
    end

    load.("rail-timeout")

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    assert {:ok, [[id]]} = DB.query(ctx.db, "SELECT id FROM decision_requests")

    # The writer is tracking it.
    assert Map.has_key?(:sys.get_state(Tightbeam.RailEpisodes).last_summon, id)

    # A mind rules on it — it leaves the open set without the writer touching it.
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

    # A later healthy evaluation. It schedules NO recovery — nothing is open to recover —
    # and its read of the open set is where the writer learns the entry is dead.
    load.("rail-pass")
    assert {:ok, %{ok: true}} = Dispatch.dispatch(ctx.db, handlers, subject)

    refute Map.has_key?(:sys.get_state(Tightbeam.RailEpisodes).last_summon, id)
  end

  # STALE POSITION ACROSS A RESTART. The episode side of a restart is safe for free — an
  # empty map reads older-than-everything, so a later verdict closes what survived. The
  # POSITION side is not: `seq` restarts from zero, so a position a slow actor still holds
  # from the previous incarnation is not merely old, it is meaningless against the new
  # sequence, and for some values it would authorize closing episodes summoned SINCE the
  # restart. The incarnation tag is what makes that arithmetic impossible rather than
  # unlikely.
  test "a position from a previous writer incarnation authorizes nothing", ctx do
    handlers = %{"post" => fn _call -> %{ok: true} end}
    subject = call(%{work_item_id: "w-incarnation"})

    load = fn script ->
      put_statute(ctx, statute(script, %{"pass" => "allow"}))
      Rules.load!(ctx.base_dir, ["post"])
    end

    load.("rail-timeout")

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    # A cutoff is minted, and its holder then stalls.
    stale_position = RailEpisodes.evaluating(ctx.db, "script-escalate")
    assert {_incarnation, _seq} = stale_position

    # The writer restarts. New incarnation, sequence back to zero, map empty.
    stop_supervised!(Tightbeam.RailEpisodes)
    start_supervised!({Tightbeam.RailEpisodes, name: Tightbeam.RailEpisodes})

    # A malfunction summons under the NEW incarnation, taking a low seq — precisely the
    # value a naive numeric comparison against the stale position would sweep.
    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    assert {:ok, [[id]]} = DB.query(ctx.db, "SELECT id FROM decision_requests")

    # The stalled actor finally lands, quoting the dead incarnation.
    :ok = RailEpisodes.recovered(ctx.db, "script-escalate", stale_position)

    # Nothing was authorized, and the skip is legible rather than silent.
    assert {:ok, [["open"]]} =
             DB.query(ctx.db, "SELECT status FROM decision_requests WHERE id = ?1", [id])

    assert [%{detail: "recovered:foreign-incarnation"}] =
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.filter(&(&1.kind == "rail_episode_writer_unavailable"))
  end

  # WRITER DOWN, property 1: a denial never depends on the writer. The deny is decided
  # before any hand-off and must come back byte-identical with the writer absent.
  test "a malfunction denies identically when the episode writer is down", ctx do
    handlers = %{"post" => fn _call -> flunk("a malfunctioning rail must not run") end}
    subject = call(%{work_item_id: "w-writer-down"})

    put_statute(ctx, statute("rail-timeout", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])

    # BASELINE first, with the writer up. Asserting a partial map against no baseline
    # would pass on a payload that had quietly lost half its fields, so the property is
    # equality against what the same call produces normally — not a shape spot-check.
    assert {:error, with_writer} = Dispatch.dispatch(ctx.db, handlers, subject)

    stop_supervised!(Tightbeam.RailEpisodes)

    assert {:error, without_writer} = Dispatch.dispatch(ctx.db, handlers, subject)

    # Whole payload, no exclusions: every field of a malfunction denial is a function of
    # the statute and the call, and neither changed. Nothing here legitimately varies —
    # if a future field does, it must be excluded HERE with a reason, not by weakening
    # this to a partial match.
    assert without_writer == with_writer

    # And the durable denial rows agree too, so the equality is not just in the return.
    assert [first, second] = EventLog.rail_denials(ctx.db, 0, 10)
    assert first.reason == second.reason
    assert first.script_exit_class == second.script_exit_class
    assert first.rule == second.rule
    assert second.reason == "script_timeout"
    assert second.script_exit_class == "timeout"
  end

  # WRITER DOWN, property 2: the summons fails soft exactly as an unreachable owner does —
  # nobody is summoned, and the gap is recorded rather than silent.
  test "a summons with the writer down fails soft and is recorded", ctx do
    handlers = %{"post" => fn _call -> flunk("a malfunctioning rail must not run") end}

    put_statute(ctx, statute("rail-timeout", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])
    stop_supervised!(Tightbeam.RailEpisodes)

    assert {:error, %{reason: "script_timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, call(%{work_item_id: "w-soft"}))

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")

    # Both hand-offs this call makes record their own gap: `evaluating` before the check
    # and `summon` after it. The summons one is the property under test.
    assert ["evaluating", "summon"] =
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.filter(&(&1.kind == "rail_episode_writer_unavailable"))
             |> Enum.map(& &1.detail)
  end

  # WRITER DOWN, property 3: recovery does not happen that evaluation, is recorded, and
  # RESUMES when the writer returns. The episode must survive the outage rather than be
  # swept or stranded.
  test "recovery skips while the writer is down and resumes when it returns", ctx do
    handlers = %{"post" => fn _call -> %{ok: true} end}
    subject = call(%{work_item_id: "w-resume"})

    load = fn script ->
      put_statute(ctx, statute(script, %{"pass" => "allow"}))
      Rules.load!(ctx.base_dir, ["post"])
    end

    load.("rail-timeout")

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    # The writer goes down, and a healthy evaluation runs without it.
    stop_supervised!(Tightbeam.RailEpisodes)
    load.("rail-pass")

    {_decision, to_close, _} = Rules.decide(ctx.db, subject)

    # No cutoff could be minted, so no recovery is scheduled — and the skip is recorded.
    assert to_close == []

    assert [%{detail: "evaluating"}] =
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.filter(&(&1.kind == "rail_episode_writer_unavailable"))

    # The episode is untouched: not swept, still summoning.
    assert {:ok, [["open"]]} = DB.query(ctx.db, "SELECT status FROM decision_requests")

    # The writer returns and the next healthy evaluation recovers normally.
    start_supervised!({Tightbeam.RailEpisodes, name: Tightbeam.RailEpisodes})

    assert {:ok, %{ok: true}} = Dispatch.dispatch(ctx.db, handlers, subject)

    assert {:ok, [["withdrawn", "sensor-recovered"]]} =
             DB.query(ctx.db, "SELECT status, withdrawnReason FROM decision_requests")
  end

  # The close side of the same CAS as the recovery-then-ruling test: a ruling lands first,
  # and the delayed recovery must not withdraw a row that is no longer open. `status =
  # 'open'` in the UPDATE is what holds this, and nothing else does.
  test "a ruling that lands first is not withdrawn by a delayed recovery", ctx do
    handlers = %{"post" => fn _call -> %{ok: true} end}
    subject = call(%{work_item_id: "w-ruled-first"})

    put_statute(ctx, statute("rail-timeout", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    assert {:ok, [[id]]} = DB.query(ctx.db, "SELECT id FROM decision_requests")

    put_statute(ctx, statute("rail-pass", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])
    {_decision, [{:episodes, name, position}], _} = Rules.decide(ctx.db, subject)

    # The mind rules before the healthy actor gets to run.
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

    # The stale recovery lands afterwards and leaves the ruling alone.
    :ok = RailEpisodes.recovered(ctx.db, name, position)

    assert {:ok, [["ruled", nil]]} =
             DB.query(
               ctx.db,
               "SELECT status, withdrawnReason FROM decision_requests WHERE id = ?1",
               [id]
             )
  end

  # Both actors close, and the sweep is the one with no coverage before this. It also has
  # to be idempotent: the verb edge and the sweep can each be handed a close for the same
  # statute, and the second must be a no-op rather than a second withdrawal.
  test "the sweep recovers an episode too, and a double close is harmless", ctx do
    handlers = %{"post" => fn _call -> %{ok: true} end}
    subject = call(%{work_item_id: "w-double"})

    put_statute(ctx, statute("rail-timeout", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    put_statute(ctx, statute("rail-pass", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])
    {_decision, to_close, _} = Rules.decide(ctx.db, subject)
    assert [{:episodes, name, position}] = to_close

    # First close recovers it and writes exactly one withdrawal row.
    :ok = RailEpisodes.recovered(ctx.db, name, position)

    withdrawals = fn ->
      ctx.db
      |> EventLog.lifecycle_events()
      |> Enum.count(&(&1.kind == "decision_request_withdrawn"))
    end

    assert withdrawals.() == 1

    # The other actor runs the same close. Nothing is open, so nothing happens twice.
    :ok = RailEpisodes.recovered(ctx.db, name, position)
    assert withdrawals.() == 1

    assert {:ok, [["withdrawn"]]} = DB.query(ctx.db, "SELECT status FROM decision_requests")
  end

  # Recovery and a ruling race for the same row. Both are single-statement CASes on
  # `status = 'open'`, so exactly one can win: a recovered episode must not then be
  # rulable, and a ruled one must not be silently withdrawn out from under the ruling.
  test "recovery and a ruling cannot both land on one episode", ctx do
    handlers = %{"post" => fn _call -> %{ok: true} end}
    subject = call(%{work_item_id: "w-cas"})

    put_statute(ctx, statute("rail-timeout", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])

    assert {:error, %{script_exit_class: "timeout"}} =
             Dispatch.dispatch(ctx.db, handlers, subject)

    assert {:ok, [[id]]} = DB.query(ctx.db, "SELECT id FROM decision_requests")

    put_statute(ctx, statute("rail-pass", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])
    {_decision, [{:episodes, name, position}], _} = Rules.decide(ctx.db, subject)

    # Recovery lands first.
    :ok = RailEpisodes.recovered(ctx.db, name, position)

    # The ruling now finds nothing open to rule on, and does not resurrect it.
    ruling =
      Escalation.rule(
        ctx.db,
        %{
          origin: "user:flynn",
          principal: {:user, "flynn"},
          params: %{request_id: id, decision: "allow"}
        },
        authorized: true
      )

    refute match?(%{status: "ruled"}, ruling)

    assert {:ok, [["withdrawn", "sensor-recovered"]]} =
             DB.query(
               ctx.db,
               "SELECT status, withdrawnReason FROM decision_requests WHERE id = ?1",
               [id]
             )
  end

  # The dedup rests entirely on `decision_requests_one_open`, so the index has to hold
  # under a genuine simultaneous insert, not just under sequential calls. Both processes
  # hand off at once; one row exists and both callers learn the same episode.
  test "two processes tripping the same malfunction at once open exactly one episode", ctx do
    handlers = %{"post" => fn _call -> %{ok: true} end}

    put_statute(ctx, statute("rail-timeout", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])

    gate = self()

    racers =
      for n <- 1..2 do
        Task.async(fn ->
          send(gate, {:ready, self()})
          assert_receive :go, 5_000
          Dispatch.dispatch(ctx.db, handlers, call(%{work_item_id: "w-racer-#{n}"}))
        end)
      end

    for _ <- racers, do: assert_receive({:ready, pid}, 5_000) && send(pid, :go)

    for task <- racers do
      assert {:error, %{reason: "script_timeout", script_exit_class: "timeout"}} =
               Task.await(task, 30_000)
    end

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")

    assert {:ok, [["episode:timeout", "open"]]} =
             DB.query(ctx.db, "SELECT actionKey, status FROM decision_requests")
  end

  # The summons is SUBORDINATE to the deny (§B3). A caller with no accountable owner
  # cannot have a mind summoned on its behalf — `owner_user_id!/2` raises for it — and
  # before this that raise escaped the actor and turned a settled denial into a crashed
  # call. An unreachable mind is a recorded gap; it is never an outage.
  test "a summons with no reachable owner still denies, and records the failure", ctx do
    handlers = %{
      "post" => fn _call -> flunk("a malfunctioning rail must not run the handler") end
    }

    put_statute(ctx, statute("rail-timeout", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])

    ownerless = %{
      call(%{work_item_id: "w-ownerless"})
      | origin: "process:tightbeam",
        principal: nil
    }

    # Byte-identical to the denial an owned caller receives for the same malfunction.
    assert {:error,
            %{
              code: "rule_denied",
              rule: "script-escalate",
              edge: "verb",
              reason: "script_timeout",
              script_exit_class: "timeout",
              ref: "w-ownerless"
            }} = Dispatch.dispatch(ctx.db, handlers, ownerless)

    assert [denial] = EventLog.rail_denials(ctx.db, 0, 10)
    assert denial.reason == "script_timeout"
    assert denial.script_exit_class == "timeout"

    # Nobody was summoned...
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")

    # ...and that gap is legible rather than silent.
    assert [%{subject: "script-escalate", detail: detail}] =
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.filter(&(&1.kind == "decision_request_failed"))

    assert detail =~ "summons failed"
    assert detail =~ "no accountable owner"
  end

  # Dedup binds only LIVE requests (§B3). A mind ruling on the WORK does not repair the
  # SENSOR, so a malfunction arriving after a resolved-but-unhealed request must open a
  # fresh episode — otherwise the second failure is exactly the silent recurrence §A3
  # forbids, hidden behind a request that was already answered.
  test "a malfunction after a resolved request opens a fresh episode", ctx do
    handlers = %{
      "post" => fn _call -> flunk("a malfunctioning rail must not run the handler") end
    }

    put_statute(ctx, statute("rail-timeout", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])
    broken = call(%{work_item_id: "w-resolved"})

    assert {:error, %{script_exit_class: "timeout"}} = Dispatch.dispatch(ctx.db, handlers, broken)
    assert {:ok, [[id, "open"]]} = DB.query(ctx.db, "SELECT id, status FROM decision_requests")

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

    # The sensor is still broken, so the deny recurs — and it must not recur silently
    # under the ruling that was about the work, not the clock.
    assert {:error, %{script_exit_class: "timeout"}} = Dispatch.dispatch(ctx.db, handlers, broken)

    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")

    assert {:ok, [[fresh]]} =
             DB.query(ctx.db, "SELECT id FROM decision_requests WHERE status = 'open'")

    refute fresh == id
  end

  # The summons is an EFFECT, so it belongs to the actors, not to the decision function
  # (§B). `decide` runs the script and writes its row and stops there; `evaluate` is the
  # legacy collapse, and fires nothing at all.
  test "decide stays dry on a timeout and evaluate collapses it to the deny", ctx do
    put_statute(ctx, statute("rail-timeout", %{"pass" => "allow"}))
    Rules.load!(ctx.base_dir, ["post"])

    assert {{:deny_escalate, %{name: "script-escalate"},
             %{error: %{reason: "script_timeout", script_exit_class: "timeout"}}}, [], []} =
             Rules.decide(ctx.db, call())

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")
    assert [%{kind: "rail_script"}] = EventLog.lifecycle_events(ctx.db)

    assert {:deny, %{reason: "script_timeout", script_exit_class: "timeout"}} =
             Rules.evaluate(ctx.db, call())

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests")
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

      # REAP THE ESCAPEE BEFORE LEAVING. The daemon child setsids out of the
      # process group — escaping the timeout kill is the very thing this leg
      # proves — and then self-exits after 5s. A test that returns while its
      # fixture is still alive hands those seconds to whoever runs next: with
      # random test order on a slow runner, that was the suite-end census,
      # which correctly refused to call the run green (CI macOS, run
      # 30944574943). The fixture is this test's; waiting for it is too.
      deadline = System.monotonic_time(:millisecond) + 8_000

      wait_for_exit = fn wait ->
        alive? = fn ->
          {out, 0} = System.cmd("ps", ["-eo", "command="])
          String.contains?(out, Path.join(ctx.base_dir, "identity/rails/scripts"))
        end

        while_alive = fn f ->
          if alive?.() and System.monotonic_time(:millisecond) < deadline do
            Process.sleep(100)
            f.(f)
          else
            refute alive?.(), "the daemon fixture outlived its 5s self-exit"
          end
        end

        wait.(while_alive)
      end

      wait_for_exit.(fn f -> f.(f) end)
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

  defp writer_seq, do: :sys.get_state(Tightbeam.RailEpisodes).seq

  defp wait_until(condition, why, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    cond do
      condition.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk(why)
      true -> Process.sleep(10) && wait_until(condition, why, deadline)
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
    timeout_ms = Keyword.get(opts, :timeout_ms)

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
    #{if timeout_ms, do: "timeout_ms = #{timeout_ms}", else: ""}
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
