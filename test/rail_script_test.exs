defmodule Tightbeam.RailScriptTest do
  use ExUnit.Case, async: false

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

  alias Tightbeam.{DB, Dispatch, Escalation, EventLog, Org, Placement, RailScript, Rules}

  setup do
    db = :"rail_script_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Org.ensure_schema(db)
    :ok = EventLog.ensure_schema(db)
    :ok = Escalation.ensure_schema(db)

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
  end

  test "wrapper infrastructure failure fails closed and remains observable", ctx do
    File.rm!(Path.join([ctx.base_dir, "bin", "tightbeam"]))

    assert {:error, "script_error", exit_class} =
             RailScript.run(ctx.db, ctx.base_dir, rule("rail-pass"), call(), nil)

    assert String.starts_with?(exit_class, "error:")

    assert [%{kind: "rail_script", detail: detail}] = EventLog.lifecycle_events(ctx.db)
    assert %{"reason" => "script_error", "exit_class" => ^exit_class} = JSON.decode!(detail)
  end

  test "BEAM backstop closes a wrapper that outlives its timeout", ctx do
    wrapper = Path.join([ctx.base_dir, "bin", "tightbeam"])
    File.write!(wrapper, "#!/bin/sh\nexec /bin/sleep 30\n")
    File.chmod!(wrapper, 0o755)
    started = System.monotonic_time(:millisecond)

    assert {:error, "script_timeout", "timeout"} =
             RailScript.run(
               ctx.db,
               ctx.base_dir,
               put_in(rule("rail-pass").check.timeout_ms, 10),
               call(),
               nil
             )

    assert System.monotonic_time(:millisecond) - started < 2_500
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

    assert {:error, "script_error", _exit_class} =
             RailScript.run(
               ctx.db,
               ctx.base_dir,
               rule("rail-write-workdir"),
               call(%{assignment_id: "a1"}),
               assignment
             )

    refute File.exists?(Path.join(workdir, "rail-forbidden-write"))
  end

  test "remote holder fails closed before ensuring its workdir", ctx do
    remote_base = Path.join(ctx.base_dir, "remote-host")
    prior_hosts = Application.get_env(:tightbeam, :hosts)

    Application.put_env(:tightbeam, :hosts, %{
      "remote-testhost" => %{ssh: nil, base_dir: remote_base, cli_bin: nil}
    })

    on_exit(fn ->
      if prior_hosts,
        do: Application.put_env(:tightbeam, :hosts, prior_hosts),
        else: Application.delete_env(:tightbeam, :hosts)
    end)

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

    assert {:error, "script_error", "error:1"} =
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

  test "escalate effects are load-gated for predicate and script statutes", ctx do
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
      path = put_statute(ctx, contents)
      error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"], %{}) end
      assert error.message =~ path
      assert error.message =~ "rule"

      assert error.message =~
               "effect escalate requires the escalation actor wiring (not yet wired)"
    end
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
  else
    @tag skip:
           "real rail-exec integration binary missing: #{@release_binary}; run cargo build --release in cli/"
    test "real Rust rail-exec matches BEAM framing for pass, deny, and escaped timeout" do
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
