defmodule Tightbeam.RulesTest do
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
    Roles,
    Rules,
    WorkItems,
    WorkState
  }

  setup do
    db = :"rules_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [Tightbeam.CausalEvents,Devices, Idempotency, Org, Roles, WorkItems, Assignments, WorkState, EventLog],
        do: :ok = module.ensure_schema(db)

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-rules-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base_dir, "identity/rules"))

    on_exit(fn ->
      File.rm_rf!(base_dir)
      Rules.load!(System.tmp_dir!() <> "/missing-rules-reset", [], %{})
    end)

    %{db: db, base_dir: base_dir, handlers: Gateway.handlers(%{db: db})}
  end

  test "missing and empty directories load zero rules and an empty load clears prior rules",
       ctx do
    assert Rules.load!(ctx.base_dir, ["post"], %{}) == []
    put_rule(ctx, rule("one", "post", "caller.origin_class", "eq", "user"))
    assert [_] = Rules.load!(ctx.base_dir, ["post"], %{})

    File.rm_rf!(Path.join(ctx.base_dir, "identity/rules"))
    assert Rules.load!(ctx.base_dir, ["post"], %{}) == []
    assert :ok = Rules.evaluate(ctx.db, call())
  end

  test "Dispatch without a prior load uses the persistent-term default", ctx do
    :persistent_term.erase(Rules)

    assert {:ok, %{ok: true}} =
             Dispatch.dispatch(ctx.db, %{"post" => fn _ -> %{ok: true} end}, call())
  end

  test "file-level validation names only the file", ctx do
    cases = [
      {"", "empty TOML"},
      {"[[rule]\n", "invalid TOML"},
      {"answer = 42\n", "unknown root keys"},
      {"title = \"only metadata\"\n", "unknown root keys"},
      {"# comment only\n", "must contain one or more"}
    ]

    for {contents, reason} <- cases do
      path = put_raw(ctx, contents)
      error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"], %{}) end
      assert error.message =~ path
      assert error.message =~ reason
      refute error.message =~ "rule #"
    end
  end

  test "all rule and condition validation failures name file plus rule or ordinal", ctx do
    valid = rule("valid", "post", "caller.origin_class", "eq", "user")

    cases = [
      {String.replace(valid, "text = \"denied\"", "extra = true\ntext = \"denied\""),
       "unknown keys"},
      {String.replace(valid, "name = \"valid\"\n", ""), "rule #1"},
      {String.replace(valid, "name = \"valid\"", "name = \"Bad Name\""), "rule #1"},
      {String.replace(valid, "verb = \"post\"\n", ""), "missing or blank verb"},
      {String.replace(valid, "verb = \"post\"", "verb = \"wake\""), "unknown verb"},
      {String.replace(valid, "text = \"denied\"\n", ""), "missing or blank text"},
      {String.replace(valid, "text = \"denied\"", "text = \"   \""), "missing or blank text"},
      {String.replace(
         valid,
         ~s(deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]),
         ""
       ), "deny_when"},
      {String.replace(
         valid,
         ~s(deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]),
         "deny_when = []"
       ), "deny_when"},
      {String.replace(
         valid,
         ~s(deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]),
         "deny_when = [1]"
       ), "deny_when"},
      {String.replace(valid, "value = \"user\"", "value = \"user\", extra = 1"), "unknown keys"},
      {String.replace(valid, "fact = \"caller.origin_class\", ", ""), "missing fact"},
      {String.replace(valid, "op = \"eq\", ", ""), "missing op"},
      {String.replace(valid, ", value = \"user\"", ""), "missing value"},
      {String.replace(valid, "caller.origin_class", "caller.unknown"), "unknown fact"},
      {String.replace(valid, "op = \"eq\"", "op = \"matches\""), "unknown op"},
      {String.replace(valid, "op = \"eq\"", "op = \"gt\""), "invalid for string"},
      {String.replace(valid, "value = \"user\"", "value = [\"user\"]"), "does not match string"},
      {rule("float", "post", "caller.verb_count_24h", "gte", "3.0", raw: true),
       "must be an integer"},
      {rule("nested", "post", "caller.origin_class", "in", "[[\"user\"]]", raw: true),
       "non-empty flat list"},
      {rule("mixed", "post", "caller.origin_class", "in", "[\"user\", 1]", raw: true),
       "non-empty flat list"},
      {rule("empty", "post", "caller.origin_class", "in", "[]", raw: true),
       "non-empty flat list"},
      {rule("roles-eq", "post", "caller.roles", "eq", "[\"admin\"]", raw: true),
       "invalid for a list fact"},
      {rule("roles-type", "post", "caller.roles", "in", "[1]", raw: true), "non-empty flat list"},
      {rule(
         "verdicts-not-in-type",
         "post",
         "assignment.verdicts",
         "not_in",
         "[1]",
         raw: true
       ), "non-empty flat list"}
    ]

    for {contents, reason} <- cases do
      path = put_raw(ctx, contents)
      error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"], %{}) end
      assert error.message =~ path
      assert error.message =~ reason
      assert error.message =~ "rule"
    end
  end

  test "subagent facts are refused by the observability-only registration boundary", ctx do
    path = put_raw(ctx, rule("no-child-obligation", "post", "subagent_stop", "eq", "child"))

    error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"], %{}) end

    assert error.message =~ path
    assert error.message =~ "observability-only"
    refute error.message =~ "unknown fact"
  end

  test "duplicate names across tables and files identify file and rule", ctx do
    put_raw(ctx, rule("same", "post", "caller.origin_class", "eq", "user"), "a.toml")
    path = put_raw(ctx, rule("same", "post", "caller.origin_class", "eq", "agent"), "b.toml")

    error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"], %{}) end
    assert error.message =~ "same"
    assert error.message =~ "rule"
    assert error.message =~ Path.dirname(path)

    File.rm_rf!(Path.join(ctx.base_dir, "identity/rules"))

    same_file =
      put_raw(
        ctx,
        rule("same-table", "post", "caller.origin_class", "eq", "user") <>
          "\n" <> rule("same-table", "post", "caller.origin_class", "eq", "agent")
      )

    error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"], %{}) end
    assert error.message =~ same_file
    assert error.message =~ "same-table"
  end

  test "scalar and ordered operators cover positive negative and boundaries", ctx do
    scalar_cases = [
      {"eq", "user", true},
      {"eq", "agent", false},
      {"ne", "agent", true},
      {"ne", "user", false},
      {"in", ["agent", "user"], true},
      {"in", ["agent"], false},
      {"not_in", ["agent"], true},
      {"not_in", ["user"], false}
    ]

    for {op, value, fires?} <- scalar_cases do
      put_rule(ctx, rule("scalar", "post", "caller.origin_class", op, value))
      Rules.load!(ctx.base_dir, ["post"], %{})
      assert match_result(Rules.evaluate(ctx.db, call())) == fires?
    end

    :ok = EventLog.append_event(ctx.db, "verb", "post", "user:flynn")

    for {op, value, fires?} <- [
          {"gt", 0, true},
          {"gt", 1, false},
          {"gte", 1, true},
          {"gte", 2, false},
          {"lt", 2, true},
          {"lt", 1, false},
          {"lte", 1, true},
          {"lte", 0, false}
        ] do
      put_rule(ctx, rule("ordered", "post", "caller.verb_count_24h", op, value))
      Rules.load!(ctx.base_dir, ["post"], %{})
      assert match_result(Rules.evaluate(ctx.db, call())) == fires?
    end
  end

  test "nil never fires for every operator, including ne and not_in", ctx do
    cases = [
      {"caller.origin_class", "eq", "user"},
      {"caller.origin_class", "ne", "user"},
      {"caller.origin_class", "in", ["user"]},
      {"caller.origin_class", "not_in", ["user"]},
      {"caller.verb_count_24h", "gt", 0},
      {"caller.verb_count_24h", "gte", 0},
      {"caller.verb_count_24h", "lt", 1},
      {"caller.verb_count_24h", "lte", 1}
    ]

    for {fact, op, value} <- cases do
      put_rule(ctx, rule("nil", "post", fact, op, value))
      Rules.load!(ctx.base_dir, ["post"], %{})
      assert :ok = Rules.evaluate(ctx.db, %{call() | origin: "malformed"})
    end

    put_rule(ctx, rule("malformed-no-read", "post", "caller.verb_count_24h", "gte", 0))
    Rules.load!(ctx.base_dir, ["post"], %{})
    assert :ok = Rules.evaluate(:missing_db, call("user:"))
  end

  test "an empty roles list is present and not_in fires", ctx do
    put_rule(ctx, rule("no-admin-role", "post", "caller.roles", "not_in", ["admin"]))
    Rules.load!(ctx.base_dir, ["post"], %{})

    assert {:deny, %{code: "rule_denied", rule: "no-admin-role"}} =
             Rules.evaluate(ctx.db, call())
  end

  test "AND short-circuits, nonmatching verbs compute no facts, and deciding rules stop later facts",
       ctx do
    dead_db = :rules_db_that_does_not_exist

    put_raw(ctx, """
    [[rule]]
    name = "and-short-circuit"
    verb = "post"
    text = "no"
    deny_when = [
      { fact = "caller.origin_class", op = "eq", value = "agent" },
      { fact = "caller.is_admin", op = "eq", value = true }
    ]
    """)

    Rules.load!(ctx.base_dir, ["post", "wake"], %{})
    assert :ok = Rules.evaluate(dead_db, call())

    put_rule(ctx, rule("other-verb", "wake", "caller.is_admin", "eq", true))
    Rules.load!(ctx.base_dir, ["post", "wake"], %{})
    assert :ok = Rules.evaluate(dead_db, call())

    put_raw(
      ctx,
      rule("first", "post", "caller.origin_class", "eq", "user") <>
        "\n" <>
        rule("later", "post", "caller.is_admin", "eq", true)
    )

    Rules.load!(ctx.base_dir, ["post"], %{})
    assert {:deny, %{rule: "first"}} = Rules.evaluate(dead_db, call())
  end

  test "rules retain filename-then-table order and stop at the first match", ctx do
    put_raw(ctx, rule("file-b", "post", "caller.origin_class", "eq", "user"), "b.toml")

    put_raw(
      ctx,
      rule("table-one", "post", "caller.origin_class", "eq", "agent") <>
        "\n" <>
        rule("table-two", "post", "caller.origin_class", "eq", "user"),
      "a.toml"
    )

    Rules.load!(ctx.base_dir, ["post"], %{})
    assert {:deny, %{rule: "table-two"}} = Rules.evaluate(ctx.db, call())
  end

  test "fact escapes are total and dispatch denies even when the audit sink is unavailable",
       ctx do
    put_rule(ctx, rule("admin-read", "post", "caller.is_admin", "eq", true))
    Rules.load!(ctx.base_dir, ["post"], %{})

    assert {:deny, %{code: "rule_error", rule: "admin-read", fact: "caller.is_admin"}} =
             Rules.evaluate(:missing_db, call())

    assert {:error, %{code: "rule_error"}} =
             Dispatch.dispatch(:missing_db, %{"post" => fn _ -> flunk("handler ran") end}, call())
  end

  test "caller facts cover origin, admin, multi-role, unbound, retired, and malformed cases",
       ctx do
    {:paired, _} =
      Devices.pair(ctx.db, %{device_id: "d1", claimed_name: "Flynn", platform: nil, model: nil})

    {:pending, _} =
      Devices.pair(ctx.db, %{device_id: "d2", claimed_name: "Mike", platform: nil, model: nil})

    active = session(ctx.db, "active", "flynn")
    retired = session(ctx.db, "retired", "mike")
    Org.retire(ctx.db, retired.session_key)
    Roles.create!(ctx.db, "alpha", "flynn", active.session_key)
    Roles.create!(ctx.db, "beta", "flynn", active.session_key)
    Roles.create!(ctx.db, "vacant", "mike", nil)
    Roles.create!(ctx.db, "old", "mike", nil)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE roles SET boundSessionKey = ?2 WHERE name = ?1", [
        "old",
        retired.session_key
      ])

    assertions = [
      {call("user:flynn"), "caller.origin_class", "eq", "user", true},
      {call("agent:alpha"), "caller.origin_class", "eq", "agent", true},
      {call("process:cron"), "caller.origin_class", "eq", "process", true},
      {call("agent:alpha"), "caller.user", "eq", "flynn", true},
      {call("agent:vacant"), "caller.user", "eq", "mike", false},
      {call("agent:old"), "caller.user", "eq", "mike", true},
      {call("process:cron"), "caller.user", "eq", "flynn", false},
      {call("user:flynn"), "caller.is_admin", "eq", true, true},
      {call("user:mike"), "caller.is_admin", "eq", false, true},
      {call("user:unknown"), "caller.is_admin", "eq", false, false},
      {call("agent:alpha"), "caller.roles", "in", ["alpha", "beta"], true},
      {call("agent:vacant"), "caller.roles", "not_in", ["alpha"], true},
      {call("agent:old"), "caller.roles", "not_in", ["old"], true},
      {call("broken"), "caller.roles", "not_in", ["alpha"], false}
    ]

    for {dispatch_call, fact, op, value, fires?} <- assertions do
      put_rule(ctx, rule("matrix", "post", fact, op, value))
      Rules.load!(ctx.base_dir, ["post"], %{})
      assert match_result(Rules.evaluate(ctx.db, dispatch_call)) == fires?
    end

    put_rule(
      ctx,
      rule("live-count", "post", "org.live_sessions_owned_by_caller", "eq", 1)
    )

    Rules.load!(ctx.base_dir, ["post"], %{})
    assert {:deny, %{rule: "live-count"}} = Rules.evaluate(ctx.db, call("user:flynn"))
    assert :ok = Rules.evaluate(ctx.db, call("process:cron"))
    assert :ok = Rules.evaluate(ctx.db, call("broken"))
  end

  test "target facts cover active retired missing ghost dm and main sessions", ctx do
    active = session(ctx.db, "active", "flynn", kind: "main")
    dm = session(ctx.db, "dm", "mike", kind: "dm")
    custom = session(ctx.db, "custom", "mike")
    retired = session(ctx.db, "retired", "flynn")
    Org.retire(ctx.db, retired.session_key)

    assertions = [
      {active.session_key, "target.owner", "flynn", true},
      {active.session_key, "target.archetype", "default", true},
      {active.session_key, "target.host", "testhost", true},
      {active.session_key, "target.kind", "main", true},
      {active.session_key, "target.state", "active", true},
      {dm.session_key, "target.kind", "dm", true},
      {custom.session_key, "target.kind", "custom", true},
      {retired.session_key, "target.state", "retired", true},
      {"missing", "target.kind", "main", false},
      {"ghost-key", "target.state", "retired", false},
      {nil, "target.kind", "main", false}
    ]

    for {key, fact, value, fires?} <- assertions do
      put_rule(ctx, rule("target", "post", fact, "eq", value))
      Rules.load!(ctx.base_dir, ["post"], %{})
      assert match_result(Rules.evaluate(ctx.db, %{call() | session_key: key})) == fires?
    end
  end

  test "quota counts exact verb attempts strictly inside 24h and excludes denied rows", ctx do
    now = System.system_time(:millisecond)

    for {ts, kind, verb, origin} <- [
          {now - 1, "verb", "post", "user:flynn"},
          {now - 86_400_000, "verb", "post", "user:flynn"},
          {now - 2, "denied", "post", "user:flynn"},
          {now - 2, "verb", "wake", "user:flynn"},
          {now - 2, "verb", "post", "user:mike"}
        ] do
      {:ok, _} =
        DB.query(ctx.db, "INSERT INTO events (ts, kind, verb, origin) VALUES (?1, ?2, ?3, ?4)", [
          ts,
          kind,
          verb,
          origin
        ])
    end

    assert EventLog.verb_count(ctx.db, "user:flynn", "post", now - 86_400_000) == 1

    put_rule(ctx, rule("quota", "post", "caller.verb_count_24h", "gte", 1))
    Rules.load!(ctx.base_dir, ["post"], %{})
    assert {:deny, %{rule: "quota"}} = Rules.evaluate(ctx.db, call())
    assert :ok = Rules.evaluate(ctx.db, call("malformed"))
  end

  test "rule denial is before the handler and records exactly one denied row", ctx do
    put_rule(ctx, rule("stop", "post", "caller.origin_class", "eq", "user"))
    Rules.load!(ctx.base_dir, ["post"], %{})

    assert {:error, %{code: "rule_denied", message: "stop: denied"}} =
             Dispatch.dispatch(ctx.db, %{"post" => fn _ -> flunk("handler ran") end}, call())

    assert [%{kind: "denied", verb: "post"}] = EventLog.events_after(ctx.db, 0, 10)
    {:ok, [[payload]]} = DB.query(ctx.db, "SELECT payload FROM events")
    assert payload =~ "rule_denied"
    assert payload =~ "stop"
  end

  test "zero rules preserves success, handler denial, mutation, and event behavior", ctx do
    Rules.load!(ctx.base_dir, ["post"], %{})
    {:ok, _} = DB.query(ctx.db, "CREATE TABLE domain (value INTEGER NOT NULL)")

    success = fn _ ->
      {:ok, _} = DB.query(ctx.db, "INSERT INTO domain VALUES (1)")
      %{ok: true}
    end

    assert {:ok, %{ok: true}} = Dispatch.dispatch(ctx.db, %{"post" => success}, call())

    assert {:error, %{code: "constitutional"}} =
             Dispatch.dispatch(ctx.db, %{"post" => fn _ -> %{code: "constitutional"} end}, call())

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM domain")
    assert Enum.map(EventLog.events_after(ctx.db, 0, 10), & &1.kind) == ["verb", "denied"]
  end

  test "zero rules lets completion close with null verdict filer fields and one verb event",
       ctx do
    holder = session(ctx.db, "zero-rule-holder", "flynn", archetype: "coder")
    assignment = assignment(ctx, holder.session_key, {:user, "flynn"})
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{})

    completion =
      p3_call("attest", {:session, holder.session_key}, %{
        assignment_id: assignment.id,
        kind: "completion"
      })

    assert {:ok,
            %{
              assignment: %{state: "closed"},
              attest: %{kind: "completion", verdictKind: nil, byUser: nil}
            }} = Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert [%{kind: "verb", verb: "attest"}] = EventLog.events_after(ctx.db, 0, 10)
  end

  test "matching a constitutional denial is monotonic and leaves domain state unchanged", ctx do
    config = %{
      db: ctx.db,
      base_dir: ctx.base_dir,
      default_harness: :claude,
      default_model: "fable",
      max_live_sessions_per_user: 5
    }

    handler = Gateway.handlers(config)["spawn"]
    process_call = %{call("process:cron") | verb: "spawn"}

    Rules.load!(ctx.base_dir, ["spawn"], %{})

    assert {:error, %{code: "forbidden"}} =
             Dispatch.dispatch(ctx.db, %{"spawn" => handler}, process_call)

    put_rule(ctx, rule("statute", "spawn", "caller.origin_class", "eq", "process"))
    Rules.load!(ctx.base_dir, ["spawn"], %{})

    assert {:error, %{code: "rule_denied"}} =
             Dispatch.dispatch(ctx.db, %{"spawn" => handler}, process_call)

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM sessions")
  end

  test "P3 fact registry has exact names and load-time types", ctx do
    list_facts = [
      "assignment.independent_verdict_kinds",
      "assignment.cross_harness_verdict_kinds",
      "assignment.cross_provider_verdict_kinds",
      "assignment.produced_verdict_kinds"
    ]

    for fact <- list_facts do
      put_rule(ctx, rule("valid-list", "attest", fact, "in", ["reviewed-clean"]))
      assert [_] = Rules.load!(ctx.base_dir, ["attest"], %{})

      put_rule(ctx, rule("bad-list-op", "attest", fact, "eq", ["reviewed-clean"]))

      assert_raise ArgumentError, ~r/invalid for a list fact/, fn ->
        Rules.load!(ctx.base_dir, ["attest"], %{})
      end

      put_rule(ctx, rule("bad-list-value", "attest", fact, "not_in", []))

      assert_raise ArgumentError, ~r/non-empty flat list/, fn ->
        Rules.load!(ctx.base_dir, ["attest"], %{})
      end
    end

    put_rule(
      ctx,
      rule("overlap", "assign", "assign.declared_files_overlap_open", "eq", true)
    )

    assert [_] = Rules.load!(ctx.base_dir, ["assign"], %{})

    put_rule(
      ctx,
      rule("overlap-ne", "assign", "assign.declared_files_overlap_open", "ne", false)
    )

    assert [_] = Rules.load!(ctx.base_dir, ["assign"], %{})

    put_rule(
      ctx,
      rule("bad-overlap", "assign", "assign.declared_files_overlap_open", "eq", "true")
    )

    assert_raise ArgumentError, ~r/does not match bool/, fn ->
      Rules.load!(ctx.base_dir, ["assign"], %{})
    end

    put_rule(ctx, rule("removed", "attest", "assignment.verdict_kinds_any", "in", ["x"]))

    assert_raise ArgumentError, ~r/unknown fact/, fn ->
      Rules.load!(ctx.base_dir, ["attest"], %{})
    end

    put_rule(
      ctx,
      rule(
        "bad-list-member",
        "attest",
        "assignment.independent_verdict_kinds",
        "in",
        [1]
      )
    )

    assert_raise ArgumentError, ~r/non-empty flat list/, fn ->
      Rules.load!(ctx.base_dir, ["attest"], %{})
    end
  end

  test "P3 fact nil, empty-list, and overlap presence matrix", ctx do
    holder = session(ctx.db, "p3-holder", "flynn", archetype: "coder")
    assignment = assignment(ctx, holder.session_key, {:user, "flynn"})

    list_facts = [
      "assignment.independent_verdict_kinds",
      "assignment.cross_harness_verdict_kinds",
      "assignment.cross_provider_verdict_kinds",
      "assignment.produced_verdict_kinds"
    ]

    for fact <- list_facts do
      kind = if fact == "assignment.produced_verdict_kinds", do: "tests-passed", else: "required"

      producers =
        if fact == "assignment.produced_verdict_kinds", do: %{tests: "fixture"}, else: %{}

      put_rule(ctx, rule("missing", "attest", fact, "not_in", [kind]))
      Rules.load!(ctx.base_dir, ["attest"], producers)

      assert :ok = Rules.evaluate(ctx.db, p3_call("attest", nil, %{kind: "completion"}))

      assert :ok =
               Rules.evaluate(
                 ctx.db,
                 p3_call("attest", nil, %{assignment_id: 123, kind: "completion"})
               )

      assert :ok =
               Rules.evaluate(
                 ctx.db,
                 p3_call("attest", nil, %{assignment_id: "unknown", kind: "completion"})
               )

      assert {:deny, %{rule: "missing"}} =
               Rules.evaluate(
                 ctx.db,
                 p3_call("attest", nil, %{assignment_id: assignment.id, kind: "completion"})
               )

      assert {:deny, %{code: "rule_error", fact: ^fact}} =
               Rules.evaluate(
                 :missing_db,
                 p3_call("attest", nil, %{assignment_id: assignment.id, kind: "completion"})
               )
    end

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET holderHarness = NULL, holderProvider = NULL WHERE id = ?1",
        [assignment.id]
      )

    for fact <- [
          "assignment.cross_harness_verdict_kinds",
          "assignment.cross_provider_verdict_kinds"
        ] do
      put_rule(ctx, rule("unstamped", "attest", fact, "not_in", ["required"]))
      Rules.load!(ctx.base_dir, ["attest"], %{})

      assert :ok =
               Rules.evaluate(
                 ctx.db,
                 p3_call("attest", nil, %{assignment_id: assignment.id, kind: "completion"})
               )
    end

    _existing = assignment(ctx, holder.session_key, {:user, "flynn"}, files: ["lib/a.ex"])

    overlap_cases = [
      {%{}, true, false},
      {%{files: []}, true, false},
      {%{files: "lib/a.ex"}, true, false},
      {%{files: ["ok", " "]}, true, false},
      {%{files: [String.duplicate("x", 2_001)]}, true, false},
      {%{files: [String.duplicate("é", 2_000)]}, false, true},
      {%{files: [" " <> String.duplicate("x", 2_000) <> " "]}, false, true},
      {%{files: ["lib/other.ex"]}, false, true},
      {%{files: ["lib/a.ex", "lib/a.ex"]}, true, true}
    ]

    for {params, expected, fires?} <- overlap_cases do
      put_rule(
        ctx,
        rule("overlap", "assign", "assign.declared_files_overlap_open", "eq", expected)
      )

      Rules.load!(ctx.base_dir, ["assign"], %{})
      result = Rules.evaluate(ctx.db, p3_call("assign", {:user, "flynn"}, params))
      assert match_result(result) == fires?
    end

    put_rule(
      ctx,
      rule("wrong-verb", "attest", "assign.declared_files_overlap_open", "eq", true)
    )

    Rules.load!(ctx.base_dir, ["attest"], %{})
    assert :ok = Rules.evaluate(ctx.db, p3_call("attest", nil, %{files: ["lib/a.ex"]}))

    put_rule(
      ctx,
      rule("overlap-error", "assign", "assign.declared_files_overlap_open", "eq", true)
    )

    Rules.load!(ctx.base_dir, ["assign"], %{})

    assert {:deny, %{code: "rule_error", fact: "assign.declared_files_overlap_open"}} =
             Rules.evaluate(
               :missing_db,
               p3_call("assign", {:user, "flynn"}, %{files: ["lib/a.ex"]})
             )
  end

  test "check-tier assignment facts are nil for every unresolved assignment shape", ctx do
    holder = session(ctx.db, "check-tier-holder", "flynn", archetype: "coder")
    assignment = assignment(ctx, holder.session_key, {:user, "flynn"})

    unresolved_params = [
      %{kind: "completion"},
      %{assignment_id: 123, kind: "completion"},
      %{assignment_id: "unknown", kind: "completion"}
    ]

    for params <- unresolved_params do
      for {fact, op, value} <- [
            {"assignment.verdicts", "not_in", ["required"]},
            {"assignment.holder_archetype", "eq", "coder"},
            {"assignment.caller_is_holder", "eq", true},
            {"assignment.caller_is_holder", "eq", false}
          ] do
        put_rule(ctx, rule("unresolved", "attest", fact, op, value))
        Rules.load!(ctx.base_dir, ["attest"], %{})

        assert :ok =
                 Rules.evaluate(
                   ctx.db,
                   p3_call("attest", {:session, holder.session_key}, params)
                 )
      end
    end

    put_rule(
      ctx,
      rule("resolved", "attest", "assignment.caller_is_holder", "eq", true)
    )

    Rules.load!(ctx.base_dir, ["attest"], %{})

    assert {:deny, %{rule: "resolved"}} =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", {:session, holder.session_key}, %{
                 assignment_id: assignment.id,
                 kind: "completion"
               })
             )
  end

  test "two required verdict statutes deny under each missing kind's own name", ctx do
    holder = session(ctx.db, "two-kind-holder", "flynn", archetype: "coder")
    assignment = assignment(ctx, holder.session_key, {:user, "flynn"})

    put_raw(ctx, """
    [[rule]]
    name = "needs-tests"
    verb = "attest"
    text = "tests required"
    external_producer = true
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.verdicts", op = "not_in", value = ["tests-passed"] }
    ]

    [[rule]]
    name = "needs-review"
    verb = "attest"
    text = "review required"
    external_producer = true
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    """)

    Rules.load!(ctx.base_dir, ["attest"], %{})

    completion =
      p3_call("attest", {:session, holder.session_key}, %{
        assignment_id: assignment.id,
        kind: "completion"
      })

    assert {:deny, %{rule: "needs-tests"}} = Rules.evaluate(ctx.db, completion)
    verdict(ctx, holder.session_key, assignment.id, "tests-passed")
    assert {:deny, %{rule: "needs-review"}} = Rules.evaluate(ctx.db, completion)
  end

  test "independence facts enforce commissioned-review provenance and frozen stamps", ctx do
    {:ok, _} =
      DB.query(ctx.db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    holder = session(ctx.db, "producer", "flynn", archetype: "coder")
    reviewer = session(ctx.db, "reviewer", "other", harness: "codex", provider: "openai")
    same = session(ctx.db, "same-reviewer", "other")
    third = session(ctx.db, "third", "other", harness: "codex", provider: "openai")
    producer = assignment(ctx, holder.session_key, {:user, "flynn"})

    verdict(ctx, reviewer.session_key, producer.id, "direct")

    valid_review =
      assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: producer.id)

    verdict(ctx, third.session_key, valid_review.id, "third-session")
    user_verdict(ctx, "flynn", valid_review.id, "user-on-review")
    verdict(ctx, reviewer.session_key, valid_review.id, "reviewed-clean")
    verdict(ctx, reviewer.session_key, valid_review.id, "reviewed-clean")

    same_review = assignment(ctx, same.session_key, {:user, "flynn"}, reviews: producer.id)
    verdict(ctx, same.session_key, same_review.id, "same-harness")

    self_review =
      assignment(ctx, third.session_key, {:session, holder.session_key}, reviews: producer.id)

    verdict(ctx, third.session_key, self_review.id, "self-commissioned")

    other_producer = assignment(ctx, holder.session_key, {:user, "flynn"})

    wrong_review =
      assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: other_producer.id)

    verdict(ctx, reviewer.session_key, wrong_review.id, "wrong-link")

    assertions = [
      {"assignment.independent_verdict_kinds", "direct", false},
      {"assignment.independent_verdict_kinds", "third-session", false},
      {"assignment.independent_verdict_kinds", "user-on-review", false},
      {"assignment.independent_verdict_kinds", "self-commissioned", false},
      {"assignment.independent_verdict_kinds", "wrong-link", false},
      {"assignment.independent_verdict_kinds", "reviewed-clean", true},
      {"assignment.independent_verdict_kinds", "same-harness", true},
      {"assignment.cross_harness_verdict_kinds", "direct", false},
      {"assignment.cross_harness_verdict_kinds", "third-session", false},
      {"assignment.cross_harness_verdict_kinds", "user-on-review", false},
      {"assignment.cross_harness_verdict_kinds", "self-commissioned", false},
      {"assignment.cross_harness_verdict_kinds", "wrong-link", false},
      {"assignment.cross_harness_verdict_kinds", "reviewed-clean", true},
      {"assignment.cross_harness_verdict_kinds", "same-harness", false},
      {"assignment.cross_provider_verdict_kinds", "reviewed-clean", true},
      {"assignment.cross_provider_verdict_kinds", "wrong-link", false},
      {"assignment.cross_provider_verdict_kinds", "same-harness", false}
    ]

    for {fact, kind, fires?} <- assertions do
      put_rule(ctx, rule("matrix", "attest", fact, "in", [kind]))
      Rules.load!(ctx.base_dir, ["attest"], %{})

      result =
        Rules.evaluate(
          ctx.db,
          p3_call("attest", nil, %{assignment_id: producer.id, kind: "completion"})
        )

      assert match_result(result) == fires?
    end

    put_raw(ctx, """
    [[rule]]
    name = "cached-authors"
    verb = "attest"
    text = "all projections derive from one cached author list"
    deny_when = [
      { fact = "assignment.independent_verdict_kinds", op = "in", value = ["reviewed-clean"] },
      { fact = "assignment.cross_harness_verdict_kinds", op = "in", value = ["reviewed-clean"] },
      { fact = "assignment.cross_provider_verdict_kinds", op = "in", value = ["reviewed-clean"] }
    ]
    """)

    Rules.load!(ctx.base_dir, ["attest"], %{})

    assert {:deny, %{rule: "cached-authors"}} =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: producer.id, kind: "completion"})
             )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET harness = 'codex', provider = 'openai' WHERE sessionKey = ?1",
        [holder.session_key]
      )

    put_rule(
      ctx,
      rule(
        "frozen",
        "attest",
        "assignment.cross_harness_verdict_kinds",
        "in",
        ["reviewed-clean"]
      )
    )

    Rules.load!(ctx.base_dir, ["attest"], %{})

    assert {:deny, %{rule: "frozen"}} =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: producer.id, kind: "completion"})
             )
  end

  test "produced verdict fact requires a direct producer stamp", ctx do
    holder = session(ctx.db, "produced-holder", "flynn", archetype: "coder")
    reviewer = session(ctx.db, "produced-reviewer", "other")
    assignment = assignment(ctx, holder.session_key, {:user, "flynn"})
    review = assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: assignment.id)

    verdict(ctx, holder.session_key, assignment.id, "tests-passed")
    producer_verdict(ctx, review.id, reviewer.session_key, "review-only-produced")

    for kind <- ["tests-passed", "review-only-produced"] do
      put_rule(
        ctx,
        rule("absent", "attest", "assignment.produced_verdict_kinds", "in", [kind])
      )

      Rules.load!(ctx.base_dir, ["attest"], %{})

      assert :ok =
               Rules.evaluate(
                 ctx.db,
                 p3_call("attest", nil, %{assignment_id: assignment.id, kind: "completion"})
               )
    end

    producer_verdict(ctx, assignment.id, holder.session_key, "tests-passed")

    put_rule(
      ctx,
      rule(
        "present",
        "attest",
        "assignment.produced_verdict_kinds",
        "in",
        ["tests-passed"]
      )
    )

    Rules.load!(ctx.base_dir, ["attest"], %{})

    assert {:deny, %{rule: "present"}} =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: assignment.id, kind: "completion"})
             )
  end

  test "P3 review and producer statutes deny before attest and allow after proof", ctx do
    holder = session(ctx.db, "gate-holder", "flynn", archetype: "coder")
    reviewer = session(ctx.db, "gate-reviewer", "other", harness: "codex", provider: "openai")
    assignment = assignment(ctx, holder.session_key, {:user, "flynn"})
    parent = self()
    actual_attest = ctx.handlers["attest"]

    handlers =
      Map.put(ctx.handlers, "attest", fn call ->
        send(parent, :attest_handler_invoked)
        actual_attest.(call)
      end)

    put_raw(ctx, review_gate_rule())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{tests: "fixture"})

    completion =
      p3_call("attest", {:session, holder.session_key}, %{
        assignment_id: assignment.id,
        kind: "completion"
      })

    assert {:error, %{code: "rule_denied", rule: "needs-cross-review"}} =
             Dispatch.dispatch(ctx.db, handlers, completion)

    refute_received :attest_handler_invoked
    assert Assignments.attest_count(ctx.db, assignment.id) == 0
    assert Assignments.open_count(ctx.db, holder.session_key) == 1
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM events WHERE kind = 'denied'")

    review = assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: assignment.id)
    verdict(ctx, reviewer.session_key, review.id, "reviewed-clean")

    assert {:ok, %{assignment: %{state: "closed"}}} =
             Dispatch.dispatch(ctx.db, handlers, completion)

    assert_received :attest_handler_invoked

    tests_assignment = assignment(ctx, holder.session_key, {:user, "flynn"})
    put_raw(ctx, producer_gate_rule())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{tests: "fixture"})

    tests_completion =
      p3_call("attest", {:session, holder.session_key}, %{
        assignment_id: tests_assignment.id,
        kind: "completion"
      })

    verdict(ctx, holder.session_key, tests_assignment.id, "tests-passed")

    assert {:error, %{code: "rule_denied", rule: "needs-produced-tests"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, tests_completion)

    producer_verdict(ctx, tests_assignment.id, holder.session_key, "tests-passed")

    assert {:ok, %{assignment: %{state: "closed"}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, tests_completion)
  end

  defp call(origin \\ "user:flynn") do
    %{verb: "post", origin: origin, session_key: nil, params: %{}}
  end

  defp p3_call(verb, principal, params) do
    origin =
      case principal do
        {:session, key} -> "agent:#{key}"
        {:user, user} -> "user:#{user}"
        nil -> "process:test"
      end

    %{
      verb: verb,
      origin: origin,
      principal: principal,
      session_key: nil,
      params: params,
      target_role: nil,
      role_fallback: false
    }
  end

  defp assignment(ctx, holder_key, opener, opts \\ []) do
    call =
      p3_call("assign", opener, %{
        subject: "P3 assignment #{System.unique_integer([:positive])}",
        idempotency_key: nil,
        reviews_assignment_id: opts[:reviews],
        files: opts[:files]
      })

    Assignments.__handle__(ctx.db, "assign", %{call | session_key: holder_key})
  end

  defp verdict(ctx, session_key, assignment_id, verdict_kind) do
    Assignments.__handle__(
      ctx.db,
      "attest",
      p3_call("attest", {:session, session_key}, %{
        assignment_id: assignment_id,
        kind: "verdict",
        verdict_kind: verdict_kind
      })
    )
  end

  defp user_verdict(ctx, user, assignment_id, verdict_kind) do
    Assignments.__handle__(
      ctx.db,
      "attest",
      p3_call("attest", {:user, user}, %{
        assignment_id: assignment_id,
        kind: "verdict",
        verdict_kind: verdict_kind
      })
    )
  end

  defp producer_verdict(ctx, assignment_id, session_key, verdict_kind) do
    session = Org.get(ctx.db, session_key)

    assert {:ok, {:ok, attest}} =
             DB.transaction(ctx.db, fn txn ->
               Assignments.insert_producer_verdict_in_txn(txn, %{
                 assignment_id: assignment_id,
                 verdict_kind: verdict_kind,
                 producer: "build",
                 producer_command: "mix test",
                 by_session: session_key,
                 by_user: nil,
                 by_harness: session.harness,
                 by_provider: session.provider
               })
             end)

    attest
  end

  defp review_gate_rule do
    """
    [[rule]]
    name = "needs-cross-review"
    verb = "attest"
    text = "completion requires cross-harness review"
    external_producer = true
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.holder_archetype", op = "eq", value = "coder" },
      { fact = "assignment.cross_harness_verdict_kinds", op = "not_in", value = ["reviewed-clean"] }
    ]
    """
  end

  defp producer_gate_rule do
    """
    [[rule]]
    name = "needs-produced-tests"
    verb = "attest"
    text = "completion requires produced tests"
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.holder_archetype", op = "eq", value = "coder" },
      { fact = "assignment.produced_verdict_kinds", op = "not_in", value = ["tests-passed"] }
    ]
    """
  end

  defp match_result({:deny, %{code: "rule_denied"}}), do: true
  defp match_result(:ok), do: false

  defp put_rule(ctx, contents), do: put_raw(ctx, contents)

  defp put_raw(ctx, contents, filename \\ "rule.toml") do
    dir = Path.join(ctx.base_dir, "identity/rules")
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, contents)
    path
  end

  defp rule(name, verb, fact, op, value, opts \\ []) do
    encoded = if opts[:raw], do: value, else: toml(value)

    external =
      if op == "not_in" and
           fact in [
             "assignment.verdicts",
             "assignment.independent_verdict_kinds",
             "assignment.cross_harness_verdict_kinds",
             "assignment.cross_provider_verdict_kinds"
           ] do
        "external_producer = true"
      else
        ""
      end

    """
    [[rule]]
    name = #{toml(name)}
    verb = #{toml(verb)}
    #{external}
    deny_when = [{ fact = #{toml(fact)}, op = #{toml(op)}, value = #{encoded} }]
    text = "denied"
    """
  end

  defp toml(value) when is_binary(value), do: inspect(value)
  defp toml(value) when is_boolean(value) or is_integer(value), do: to_string(value)
  defp toml(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &toml/1) <> "]"

  defp session(db, key, owner, opts \\ []) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: Keyword.get(opts, :kind, "custom"),
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: Keyword.get(opts, :archetype, "default"),
      host: "testhost",
      harness: Keyword.get(opts, :harness, "claude"),
      provider: Keyword.get(opts, :provider, "anthropic"),
      model: "fable"
    })
  end
end
