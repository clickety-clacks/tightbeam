defmodule Tightbeam.RulesTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{DB, Devices, Dispatch, EventLog, Gateway, Org, Roles, Rules}

  setup do
    db = :"rules_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    for module <- [Devices, EventLog, Org, Roles], do: :ok = module.ensure_schema(db)

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-rules-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base_dir, "identity/rules"))

    on_exit(fn ->
      File.rm_rf!(base_dir)
      Rules.load!(System.tmp_dir!() <> "/missing-rules-reset", [])
    end)

    %{db: db, base_dir: base_dir}
  end

  test "missing and empty directories load zero rules and an empty load clears prior rules",
       ctx do
    assert Rules.load!(ctx.base_dir, ["post"]) == []
    put_rule(ctx, rule("one", "post", "caller.origin_class", "eq", "user"))
    assert [_] = Rules.load!(ctx.base_dir, ["post"])

    File.rm_rf!(Path.join(ctx.base_dir, "identity/rules"))
    assert Rules.load!(ctx.base_dir, ["post"]) == []
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
      error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"]) end
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
      {rule("roles-type", "post", "caller.roles", "in", "[1]", raw: true), "non-empty flat list"}
    ]

    for {contents, reason} <- cases do
      path = put_raw(ctx, contents)
      error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"]) end
      assert error.message =~ path
      assert error.message =~ reason
      assert error.message =~ "rule"
    end
  end

  test "duplicate names across tables and files identify file and rule", ctx do
    put_raw(ctx, rule("same", "post", "caller.origin_class", "eq", "user"), "a.toml")
    path = put_raw(ctx, rule("same", "post", "caller.origin_class", "eq", "agent"), "b.toml")

    error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"]) end
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

    error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"]) end
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
      Rules.load!(ctx.base_dir, ["post"])
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
      Rules.load!(ctx.base_dir, ["post"])
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
      Rules.load!(ctx.base_dir, ["post"])
      assert :ok = Rules.evaluate(ctx.db, %{call() | origin: "malformed"})
    end

    put_rule(ctx, rule("malformed-no-read", "post", "caller.verb_count_24h", "gte", 0))
    Rules.load!(ctx.base_dir, ["post"])
    assert :ok = Rules.evaluate(:missing_db, call("user:"))
  end

  test "an empty roles list is present and not_in fires", ctx do
    put_rule(ctx, rule("no-admin-role", "post", "caller.roles", "not_in", ["admin"]))
    Rules.load!(ctx.base_dir, ["post"])

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

    Rules.load!(ctx.base_dir, ["post", "wake"])
    assert :ok = Rules.evaluate(dead_db, call())

    put_rule(ctx, rule("other-verb", "wake", "caller.is_admin", "eq", true))
    Rules.load!(ctx.base_dir, ["post", "wake"])
    assert :ok = Rules.evaluate(dead_db, call())

    put_raw(
      ctx,
      rule("first", "post", "caller.origin_class", "eq", "user") <>
        "\n" <>
        rule("later", "post", "caller.is_admin", "eq", true)
    )

    Rules.load!(ctx.base_dir, ["post"])
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

    Rules.load!(ctx.base_dir, ["post"])
    assert {:deny, %{rule: "table-two"}} = Rules.evaluate(ctx.db, call())
  end

  test "fact escapes are total and dispatch denies even when the audit sink is unavailable",
       ctx do
    put_rule(ctx, rule("admin-read", "post", "caller.is_admin", "eq", true))
    Rules.load!(ctx.base_dir, ["post"])

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
      Rules.load!(ctx.base_dir, ["post"])
      assert match_result(Rules.evaluate(ctx.db, dispatch_call)) == fires?
    end

    put_rule(
      ctx,
      rule("live-count", "post", "org.live_sessions_owned_by_caller", "eq", 1)
    )

    Rules.load!(ctx.base_dir, ["post"])
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
      Rules.load!(ctx.base_dir, ["post"])
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
    Rules.load!(ctx.base_dir, ["post"])
    assert {:deny, %{rule: "quota"}} = Rules.evaluate(ctx.db, call())
    assert :ok = Rules.evaluate(ctx.db, call("malformed"))
  end

  test "rule denial is before the handler and records exactly one denied row", ctx do
    put_rule(ctx, rule("stop", "post", "caller.origin_class", "eq", "user"))
    Rules.load!(ctx.base_dir, ["post"])

    assert {:error, %{code: "rule_denied", message: "stop: denied"}} =
             Dispatch.dispatch(ctx.db, %{"post" => fn _ -> flunk("handler ran") end}, call())

    assert [%{kind: "denied", verb: "post"}] = EventLog.events_after(ctx.db, 0, 10)
    {:ok, [[payload]]} = DB.query(ctx.db, "SELECT payload FROM events")
    assert payload =~ "rule_denied"
    assert payload =~ "stop"
  end

  test "zero rules preserves success, handler denial, mutation, and event behavior", ctx do
    Rules.load!(ctx.base_dir, ["post"])
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

  test "matching a constitutional denial is monotonic and leaves domain state unchanged", ctx do
    config = %{
      db: ctx.db,
      base_dir: ctx.base_dir,
      default_harness: :claude,
      default_model: "claude-opus-4-8[high]",
      max_live_sessions_per_user: 5
    }

    handler = Gateway.handlers(config)["spawn"]
    process_call = %{call("process:cron") | verb: "spawn"}

    Rules.load!(ctx.base_dir, ["spawn"])

    assert {:error, %{code: "forbidden"}} =
             Dispatch.dispatch(ctx.db, %{"spawn" => handler}, process_call)

    put_rule(ctx, rule("statute", "spawn", "caller.origin_class", "eq", "process"))
    Rules.load!(ctx.base_dir, ["spawn"])

    assert {:error, %{code: "rule_denied"}} =
             Dispatch.dispatch(ctx.db, %{"spawn" => handler}, process_call)

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM sessions")
  end

  defp call(origin \\ "user:flynn") do
    %{verb: "post", origin: origin, session_key: nil, params: %{}}
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

    """
    [[rule]]
    name = #{toml(name)}
    verb = #{toml(verb)}
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
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: "fable"
    })
  end
end
