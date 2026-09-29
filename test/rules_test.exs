defmodule Tightbeam.RulesTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Artifacts,
    Assignments,
    DB,
    Devices,
    Dispatch,
    DeliveryResponsibilities,
    Escalation,
    EventLog,
    Gateway,
    Ledger,
    Org,
    Roles,
    Rules,
    SessionPoAssociations,
    Toplines,
    Wakes
  }

  setup do
    db = :"rules_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-rules-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base_dir, "identity/rules"))

    on_exit(fn ->
      File.rm_rf!(base_dir)
      Rules.load!(System.tmp_dir!() <> "/missing-rules-reset", [])
    end)

    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
    Rules.load!(Path.join(base_dir, "missing-rules"), Map.keys(handlers))

    %{
      db: db,
      base_dir: base_dir,
      handlers: handlers
    }
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

  test "shipped wait qualification matrix follows TOML reload with a fresh query snapshot", ctx do
    shipped =
      File.read!(
        Path.expand("../priv/kungfu/agentic-engineering/rules/verification.toml", __DIR__)
      )

    put_raw(ctx, shipped)
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    facts = %{
      "wait.obligation_matches" => true,
      "wait.admitted" => true,
      "wait.after_turn_eligible" => true,
      "wait.coverage_valid" => true,
      "wait.continuation_state" => "pending",
      "wait.recognized" => false,
      "resolver.open" => true,
      "resolver.owed_by_other" => true,
      "wait.declaration_complete" => true,
      "wait.verification_accountable" => true,
      "wait.verification_state" => "provisional"
    }

    query = fn purpose, snapshot ->
      DB.transaction(ctx.db, &Rules.select_policy_in_txn(&1, purpose, %{wait_facts: snapshot}))
    end

    assert {:ok, {:ok, %{name: "holder-continuation-coverage"}}} =
             query.("wait-prod-coverage", facts)

    assert {:ok, {:ok, %{name: "justified-unresolved-dependency"}}} =
             query.("wait-effort-relief", facts)

    for field <-
          ~w(wait.obligation_matches wait.admitted wait.after_turn_eligible wait.coverage_valid) do
      assert {:ok, :none} = query.("wait-prod-coverage", Map.put(facts, field, false))
    end

    for state <- ~w(queued running) do
      snapshot = Map.put(facts, "wait.continuation_state", state)
      assert {:ok, {:ok, _}} = query.("wait-prod-coverage", snapshot)
      assert {:ok, :none} = query.("wait-effort-relief", snapshot)
    end

    for field <-
          ~w(resolver.open resolver.owed_by_other wait.declaration_complete wait.verification_accountable) do
      assert {:ok, :none} = query.("wait-effort-relief", Map.put(facts, field, false))
    end

    assert {:ok, :none} = query.("wait-effort-relief", Map.put(facts, "wait.recognized", true))

    assert {:ok, :none} =
             query.("wait-effort-relief", Map.put(facts, "wait.verification_state", "challenged"))

    assert {:ok, {:ok, _}} =
             query.("wait-effort-relief", Map.put(facts, "wait.verification_state", "confirmed"))

    put_raw(
      ctx,
      String.replace(
        shipped,
        ~s(fact = "resolver.owed_by_other", op = "eq", value = true),
        ~s(fact = "resolver.owed_by_other", op = "eq", value = false)
      )
    )

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    assert {:ok, :none} = query.("wait-effort-relief", facts)

    assert {:ok, {:ok, _}} =
             query.("wait-effort-relief", Map.put(facts, "resolver.owed_by_other", false))
  end

  test "predicate policy loading refuses incomplete verification and invalid conditions", ctx do
    valid = """
    [[policy]]
    name = "verifier"
    purpose = "wait-verification-admission"
    when = [{ fact = "verifier.open", op = "eq", value = true }]
    verification = { trigger = "registration", terminal = "bound-verdict-or-obligation-terminal", fallback = "wake-due-at" }
    """

    for contents <- [
          String.replace(valid, ~r/^verification.*$/m, ""),
          String.replace(valid, "registration", "never"),
          String.replace(valid, "verifier.open", "verifier.unknown"),
          String.replace(valid, "value = true", "value = 1"),
          String.replace(valid, ~r/when = .*\n/, "when = []\n"),
          valid <> "effect = \"deny\"\n",
          valid <> "\n" <> valid
        ] do
      path = put_raw(ctx, contents)

      error =
        assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

      assert error.message =~ path
      assert error.message =~ "verifier"
    end
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
      error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"]) end
      assert error.message =~ path
      assert error.message =~ reason
      assert error.message =~ "rule"
    end
  end

  test "subagent facts are refused by the observability-only registration boundary", ctx do
    path = put_raw(ctx, rule("no-child-obligation", "post", "subagent_stop", "eq", "child"))

    error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["post"]) end

    assert error.message =~ path
    assert error.message =~ "observability-only"
    refute error.message =~ "unknown fact"
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
    Org.retire(ctx.db, retired.session_key, "user:mike", 1_000)
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

  test "work_item.has_topline distinguishes unknown, invisible, inactive, and active membership",
       ctx do
    :ok = Toplines.ensure_schema(ctx.db)

    :ok =
      DB.execute(
        ctx.db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('fact_flynn',0,1),('fact_kay',0,1),('fact_root',1,1)"
      )

    for {id, owner} <- [
          {"wi_fact_none", "fact_flynn"},
          {"wi_fact_linked", "fact_flynn"},
          {"wi_fact_foreign", "fact_kay"}
        ] do
      {:ok, _} =
        DB.query(
          ctx.db,
          """
          INSERT INTO work_items
            (id, title, ownerUserId, state, createdByUser, createdContextKnown, createdAt)
          VALUES (?1, ?1, ?2, 'open', ?2, 1, 1)
          """,
          [id, owner]
        )
    end

    fact_call = fn origin, work_item_id ->
      call(origin) |> put_in([:params, :work_item_id], work_item_id)
    end

    put_rule(ctx, rule("known-none", "post", "work_item.has_topline", "eq", false))
    Rules.load!(ctx.base_dir, ["post"])

    assert {:deny, %{rule: "known-none"}} =
             Rules.evaluate(ctx.db, fact_call.("user:fact_flynn", "wi_fact_none"))

    assert {:deny, %{rule: "known-none"}} =
             Rules.evaluate(ctx.db, fact_call.("user:fact_root", "wi_fact_foreign"))

    assert :ok = Rules.evaluate(ctx.db, fact_call.("user:fact_flynn", "wi_missing"))
    assert :ok = Rules.evaluate(ctx.db, fact_call.("user:fact_flynn", "wi_fact_foreign"))
    assert :ok = Rules.evaluate(ctx.db, call("process:tightbeam"))
    assert :ok = Rules.evaluate(ctx.db, fact_call.("process:tightbeam", "wi_fact_none"))

    topline =
      Toplines.create(ctx.db, %{
        principal: {:user, "fact_flynn"},
        params: %{title: "Fact proof", idempotency_key: "fact-create"},
        now: 10
      }).topline

    linked =
      Toplines.link_work(ctx.db, %{
        principal: {:user, "fact_flynn"},
        params: %{
          topline_id: topline.id,
          work_item_id: "wi_fact_linked",
          reason: "explicit membership",
          idempotency_key: "fact-link"
        },
        now: 11
      }).membership

    put_rule(ctx, rule("known-active", "post", "work_item.has_topline", "eq", true))
    Rules.load!(ctx.base_dir, ["post"])

    assert {:deny, %{rule: "known-active"}} =
             Rules.evaluate(ctx.db, fact_call.("user:fact_flynn", "wi_fact_linked"))

    assert {:deny, %{rule: "known-active"}} =
             Rules.evaluate(ctx.db, fact_call.("user:fact_root", "wi_fact_linked"))

    Toplines.unlink_work(ctx.db, %{
      principal: {:user, "fact_flynn"},
      params: %{
        membership_id: linked.id,
        reason: "episode ended",
        idempotency_key: "fact-unlink"
      },
      now: 12
    })

    assert :ok = Rules.evaluate(ctx.db, fact_call.("user:fact_flynn", "wi_fact_linked"))

    put_rule(ctx, rule("known-ended", "post", "work_item.has_topline", "eq", false))
    Rules.load!(ctx.base_dir, ["post"])

    assert {:deny, %{rule: "known-ended"}} =
             Rules.evaluate(ctx.db, fact_call.("user:fact_flynn", "wi_fact_linked"))
  end

  test "target facts cover active retired missing ghost dm and main sessions", ctx do
    active = session(ctx.db, Org.personal_session_key("flynn"), "flynn", kind: "main")
    dm = session(ctx.db, "dm", "mike", kind: "dm")
    custom = session(ctx.db, "custom", "mike")
    retired = session(ctx.db, "retired", "flynn")
    Org.retire(ctx.db, retired.session_key, "user:flynn", 1_000)

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

  test "zero rules cannot bypass code completion evidence",
       ctx do
    holder = session(ctx.db, "zero-rule-holder", "flynn", archetype: "coder")
    assignment = assignment(ctx, holder.session_key, {:user, "flynn"})
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    completion =
      p3_call("attest", {:session, holder.session_key}, %{
        assignment_id: assignment.id,
        kind: "completion"
      })

    assert {:error, %{code: "inapplicable_code_evidence"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert {:ok, [["open", nil]]} =
             DB.query(
               ctx.db,
               "SELECT state,closingAttestId FROM assignments WHERE id=?1",
               [assignment.id]
             )

    assert [%{kind: "denied", verb: "attest"}] = EventLog.events_after(ctx.db, 0, 10)
  end

  test "matching a constitutional denial is monotonic and leaves domain state unchanged", ctx do
    config = %{
      db: ctx.db,
      base_dir: ctx.base_dir,
      default_harness: :claude,
      default_model: Model.new("fable"),
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

  test "P3 fact registry has exact names and load-time types", ctx do
    list_facts = [
      "assignment.independent_verdict_kinds",
      "assignment.qualifying_review_verdict_kinds",
      "assignment.artifact_kinds"
    ]

    for fact <- list_facts do
      put_rule(ctx, rule("valid-list", "attest", fact, "in", ["reviewed-clean"]))
      assert [_] = Rules.load!(ctx.base_dir, ["attest"])

      put_rule(ctx, rule("bad-list-op", "attest", fact, "eq", ["reviewed-clean"]))

      assert_raise ArgumentError, ~r/invalid for a list fact/, fn ->
        Rules.load!(ctx.base_dir, ["attest"])
      end

      put_rule(ctx, rule("bad-list-value", "attest", fact, "not_in", []))

      assert_raise ArgumentError, ~r/non-empty flat list/, fn ->
        Rules.load!(ctx.base_dir, ["attest"])
      end
    end

    for removed <- [
          "assignment.cross_harness_verdict_kinds",
          "assignment.cross_provider_verdict_kinds"
        ] do
      put_rule(ctx, rule("removed-review-fact", "attest", removed, "in", ["reviewed-clean"]))

      assert_raise ArgumentError, ~r/unknown fact/, fn ->
        Rules.load!(ctx.base_dir, ["attest"])
      end
    end

    put_rule(
      ctx,
      rule("overlap", "assign", "assign.declared_files_overlap_open", "eq", true)
    )

    assert [_] = Rules.load!(ctx.base_dir, ["assign"])

    put_rule(
      ctx,
      rule("overlap-ne", "assign", "assign.declared_files_overlap_open", "ne", false)
    )

    assert [_] = Rules.load!(ctx.base_dir, ["assign"])

    put_rule(
      ctx,
      rule("bad-overlap", "assign", "assign.declared_files_overlap_open", "eq", "true")
    )

    assert_raise ArgumentError, ~r/does not match bool/, fn ->
      Rules.load!(ctx.base_dir, ["assign"])
    end

    put_rule(
      ctx,
      rule("producing", "attest", "assignment.is_producing_card", "eq", true)
    )

    assert [_] = Rules.load!(ctx.base_dir, ["attest"])

    put_rule(
      ctx,
      rule("bad-producing", "attest", "assignment.is_producing_card", "eq", "true")
    )

    assert_raise ArgumentError, ~r/does not match bool/, fn ->
      Rules.load!(ctx.base_dir, ["attest"])
    end

    put_rule(ctx, rule("removed", "attest", "assignment.verdict_kinds_any", "in", ["x"]))

    assert_raise ArgumentError, ~r/unknown fact/, fn ->
      Rules.load!(ctx.base_dir, ["attest"])
    end

    # Migration proof (verification-papertrail-v1): an org rule still gating the
    # deleted producer fact fails loud at boot, naming file and rule.
    put_rule(
      ctx,
      rule("dead-produced", "attest", "assignment.produced_verdict_kinds", "not_in", [
        "tests-passed"
      ])
    )

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["attest"]) end

    assert error.message =~ "unknown fact"
    assert error.message =~ "dead-produced"
    assert error.message =~ "rule.toml"

    put_rule(
      ctx,
      rule(
        "bad-list-member",
        "attest",
        "assignment.qualifying_review_verdict_kinds",
        "in",
        [1]
      )
    )

    assert_raise ArgumentError, ~r/non-empty flat list/, fn ->
      Rules.load!(ctx.base_dir, ["attest"])
    end
  end

  test "P3 fact nil, empty-list, and overlap presence matrix", ctx do
    holder = session(ctx.db, "p3-holder", "flynn", archetype: "coder")
    assignment = assignment(ctx, holder.session_key, {:user, "flynn"})
    review = assignment(ctx, holder.session_key, {:user, "flynn"}, reviews: assignment.id)

    list_facts = [
      "assignment.qualifying_review_verdict_kinds",
      "assignment.artifact_kinds"
    ]

    for fact <- list_facts do
      put_rule(ctx, rule("missing", "attest", fact, "not_in", ["required"]))
      Rules.load!(ctx.base_dir, ["attest"])

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

    put_rule(
      ctx,
      rule("producing", "attest", "assignment.is_producing_card", "eq", true)
    )

    Rules.load!(ctx.base_dir, ["attest"])

    for params <- [
          %{kind: "completion"},
          %{assignment_id: 123, kind: "completion"},
          %{assignment_id: "unknown", kind: "completion"}
        ] do
      assert :ok = Rules.evaluate(ctx.db, p3_call("attest", nil, params))
    end

    assert {:deny, %{rule: "producing"}} =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: assignment.id, kind: "completion"})
             )

    assert :ok =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: review.id, kind: "completion"})
             )

    assert {:deny, %{code: "rule_error", fact: "assignment.is_producing_card"}} =
             Rules.evaluate(
               :missing_db,
               p3_call("attest", nil, %{assignment_id: assignment.id, kind: "completion"})
             )

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

      Rules.load!(ctx.base_dir, ["assign"])
      result = Rules.evaluate(ctx.db, p3_call("assign", {:user, "flynn"}, params))
      assert match_result(result) == fires?
    end

    put_rule(
      ctx,
      rule("wrong-verb", "attest", "assign.declared_files_overlap_open", "eq", true)
    )

    Rules.load!(ctx.base_dir, ["attest"])
    assert :ok = Rules.evaluate(ctx.db, p3_call("attest", nil, %{files: ["lib/a.ex"]}))

    put_rule(
      ctx,
      rule("overlap-error", "assign", "assign.declared_files_overlap_open", "eq", true)
    )

    Rules.load!(ctx.base_dir, ["assign"])

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
        Rules.load!(ctx.base_dir, ["attest"])

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

    Rules.load!(ctx.base_dir, ["attest"])

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

    Rules.load!(ctx.base_dir, ["attest"])

    completion =
      p3_call("attest", {:session, holder.session_key}, %{
        assignment_id: assignment.id,
        kind: "completion"
      })

    assert {:deny, %{rule: "needs-tests"}} = Rules.evaluate(ctx.db, completion)
    verdict(ctx, holder.session_key, assignment.id, "tests-passed")
    assert {:deny, %{rule: "needs-review"}} = Rules.evaluate(ctx.db, completion)
  end

  test "completion notice loader exception preserves unrelated wake and review-link validation",
       ctx do
    shipped = File.read!("priv/kungfu/agentic-engineering/rules/engineering.toml")
    put_raw(ctx, shipped)
    assert [loaded] = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    assert loaded.name == "completion-requires-review"
    assert loaded.external_producer
    assert loaded.remedy.action == "wake"
    assert loaded.remedy.produces == "reviewed-clean"
    refute Map.has_key?(loaded.remedy.params, :reviews)

    put_raw(ctx, String.replace(shipped, "completion-requires-review", "unrelated-review-rule"))

    assert_raise ArgumentError, ~r/linked-review-fact remedy requires reviews/, fn ->
      Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    end

    for extra <- [~s(reviews = "{assignment_id}"), ~s(arbitrary = "value")] do
      put_raw(ctx, shipped <> "\n" <> extra <> "\n")

      assert_raise ArgumentError, ~r/remedy wake has invalid params/, fn ->
        Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
      end
    end

    put_raw(ctx, String.replace(shipped, "external_producer = true", "external_producer = false"))

    assert_raise ArgumentError, ~r/F1 unsatisfied verdict gate/, fn ->
      Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    end

    assigned =
      shipped
      |> String.replace(~s(action = "wake"), ~s(action = "assign"))
      |> String.replace(~s(target_session = "{holder_key}"), ~s(target_role = "reviewer-code"))
      |> String.replace(~r/^prompt = .*$/m, ~s(subject = "review {assignment_id}"))

    put_raw(ctx, assigned)

    assert_raise ArgumentError, ~r/linked-review-fact remedy requires reviews/, fn ->
      Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    end

    put_raw(ctx, assigned <> ~s(\nreviews = "{holder_key}"\n))

    assert_raise ArgumentError, ~r/linked-review-fact remedy requires reviews/, fn ->
      Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    end

    put_raw(ctx, assigned <> ~s(\nreviews = "{assignment_id}"\n))
    assert [linked] = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    assert linked.remedy.params.reviews == "{assignment_id}"
    assert linked.conditions == loaded.conditions
  end

  test "restored independent verdict fact accepts the prior linked-review shape", ctx do
    {:ok, _} =
      DB.query(ctx.db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    holder = session(ctx.db, "producer", "flynn", archetype: "coder")
    reviewer = session(ctx.db, "reviewer", "other", harness: "claude", provider: "anthropic")
    producer = assignment(ctx, holder.session_key, {:user, "flynn"})
    review = assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: producer.id)

    verdict(ctx, reviewer.session_key, review.id, "reviewed-clean")

    put_rule(
      ctx,
      rule(
        "independent",
        "attest",
        "assignment.independent_verdict_kinds",
        "in",
        ["reviewed-clean"]
      )
    )

    Rules.load!(ctx.base_dir, ["attest"])

    assert {:deny, %{rule: "independent"}} =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: producer.id, kind: "completion"})
             )
  end

  test "qualifying review ignores harness/provider", ctx do
    {:ok, _} =
      DB.query(ctx.db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    holder = session(ctx.db, "producer", "flynn", archetype: "coder")
    reviewer = session(ctx.db, "reviewer", "other", harness: "claude", provider: "anthropic")
    third = session(ctx.db, "third", "other", harness: "codex", provider: "openai")
    producer = assignment(ctx, holder.session_key, {:user, "flynn"}, effect_kind: "policy")

    verdict(ctx, reviewer.session_key, producer.id, "direct")

    valid_review =
      assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: producer.id)

    verdict(ctx, third.session_key, valid_review.id, "third-session")
    user_verdict(ctx, "flynn", valid_review.id, "user-on-review")

    put_rule(
      ctx,
      rule(
        "qualified",
        "attest",
        "assignment.qualifying_review_verdict_kinds",
        "in",
        ["reviewed-clean"]
      )
    )

    Rules.load!(ctx.base_dir, ["attest"])

    assert :ok =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: producer.id, kind: "completion"})
             )

    verdict(ctx, reviewer.session_key, valid_review.id, "changes-requested")

    assert :ok =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: producer.id, kind: "completion"})
             )

    verdict(ctx, reviewer.session_key, valid_review.id, "reviewed-clean")

    assert {:deny, %{rule: "qualified"}} =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: producer.id, kind: "completion"})
             )
  end

  test "artifact kinds fact resolves holder-recorded kinds only (A6)", ctx do
    holder = session(ctx.db, "artifact-holder", "flynn", archetype: "coder")
    other = session(ctx.db, "artifact-other", "other")
    assignment = assignment(ctx, holder.session_key, {:user, "flynn"})
    attach_work_item(ctx, assignment.id, "wi_artifact_fact")

    # Empty list for a holder who recorded nothing: `not_in` fires.
    put_rule(
      ctx,
      rule("no-report", "attest", "assignment.artifact_kinds", "not_in", ["report"])
    )

    Rules.load!(ctx.base_dir, ["attest"])

    assert {:deny, %{rule: "no-report"}} =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: assignment.id, kind: "completion"})
             )

    # Another session's report and the holder's kinds on OTHER items do not count.
    record_artifact(ctx, "wi_artifact_fact", other.session_key, "report", "in-workspace")

    other_assignment = assignment(ctx, holder.session_key, {:user, "flynn"})
    attach_work_item(ctx, other_assignment.id, "wi_artifact_elsewhere")
    record_artifact(ctx, "wi_artifact_elsewhere", holder.session_key, "report", "in-workspace")

    assert {:deny, %{rule: "no-report"}} =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: assignment.id, kind: "completion"})
             )

    # The holder's own recording on the assignment's work item resolves, in every
    # state — a released row counts exactly as an in-workspace one.
    record_artifact(ctx, "wi_artifact_fact", holder.session_key, "report", "released")

    assert :ok =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: assignment.id, kind: "completion"})
             )

    # Nil for an unresolvable assignment: the statute never matches.
    assert :ok =
             Rules.evaluate(
               ctx.db,
               p3_call("attest", nil, %{assignment_id: "asg_missing", kind: "completion"})
             )
  end

  test "P3 review and artifact statutes deny before attest and allow after proof", ctx do
    :ok =
      DB.execute(ctx.db, "INSERT INTO users (userId,createdAt) VALUES ('flynn',1),('other',1)")

    holder = session(ctx.db, "gate-holder", "flynn", archetype: "coder")
    reviewer = session(ctx.db, "gate-reviewer", "other", archetype: "reviewer")
    assignment = assignment(ctx, holder.session_key, {:user, "flynn"}, effect_kind: "policy")
    parent = self()
    actual_attest = ctx.handlers["attest"]

    handlers =
      Map.put(ctx.handlers, "attest", fn call ->
        send(parent, :attest_handler_invoked)
        actual_attest.(call)
      end)

    put_raw(ctx, review_gate_rule())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    completion =
      p3_call("attest", {:session, holder.session_key}, %{
        assignment_id: assignment.id,
        kind: "completion"
      })

    assert {:error, %{code: "rule_denied", rule: "needs-independent-review"}} =
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

    review_completion =
      p3_call("attest", {:session, reviewer.session_key}, %{
        assignment_id: review.id,
        kind: "completion"
      })

    assert {:ok, %{assignment: %{state: "closed", effectKind: "review"}}} =
             Dispatch.dispatch(ctx.db, handlers, review_completion)

    evidence_assignment =
      assignment(ctx, holder.session_key, {:user, "flynn"}, effect_kind: "evidence")

    evidence_completion =
      p3_call("attest", {:session, holder.session_key}, %{
        assignment_id: evidence_assignment.id,
        kind: "completion"
      })

    assert {:ok, %{assignment: %{state: "closed", effectKind: "evidence"}}} =
             Dispatch.dispatch(ctx.db, handlers, evidence_completion)

    artifact_assignment =
      assignment(ctx, holder.session_key, {:user, "flynn"}, effect_kind: "policy")

    attach_work_item(ctx, artifact_assignment.id, "wi_artifact_gate")
    put_raw(ctx, artifact_gate_rule())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    artifact_completion =
      p3_call("attest", {:session, holder.session_key}, %{
        assignment_id: artifact_assignment.id,
        kind: "completion"
      })

    # A spec artifact by the holder and a report by ANOTHER session do not
    # satisfy the gate: the papertrail must be the holder's own report.
    record_artifact(ctx, "wi_artifact_gate", holder.session_key, "spec", "in-workspace")
    record_artifact(ctx, "wi_artifact_gate", "gate-reviewer", "report", "in-workspace")

    assert {:error, %{code: "rule_denied", rule: "needs-results-artifact"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, artifact_completion)

    # A holder-recorded report satisfies it — state-blind, an archived row counts.
    record_artifact(ctx, "wi_artifact_gate", holder.session_key, "report", "archived")

    assert {:ok, %{assignment: %{state: "closed"}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, artifact_completion)
  end

  test "shipped code review opens before any holder test receipt", ctx do
    holder = session(ctx.db, "receipt-holder", "flynn", archetype: "coder")
    other = session(ctx.db, "receipt-other", "other", archetype: "coder")
    reviewer = session(ctx.db, "receipt-reviewer", "reviewer", archetype: "reviewer")
    producer = assignment(ctx, holder.session_key, {:user, "flynn"})

    {:ok, _} =
      DB.query(ctx.db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1)")

    put_raw(ctx, File.read!("priv/kungfu/agentic-engineering/rules/engineering.toml"))
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    review_call =
      p3_call("assign", {:user, "reviewer"}, %{
        subject: "review receipt producer",
        reviews_assignment_id: producer.id,
        idempotency_key: nil,
        files: nil
      })
      |> Map.put(:session_key, reviewer.session_key)

    assert {:ok, early} = Dispatch.dispatch(ctx.db, ctx.handlers, review_call)
    producer_id = producer.id
    assert early.reviewsAssignmentId == producer_id
    assert early.effectKind == "review"
    assert early.holderKey != holder.session_key
    assert review_count(ctx.db, producer.id) == 1

    user_verdict(ctx, "flynn", producer.id, "tests-passed", "user claim")
    verdict(ctx, other.session_key, producer.id, "tests-passed", "other session claim")
    verdict(ctx, holder.session_key, producer.id, "tests-passed")

    assert review_count(ctx.db, producer.id) == 1

    verdict(
      ctx,
      holder.session_key,
      producer.id,
      "tests-passed",
      "gibson:/repo abc123; mix test test/rules_test.exs; passed: 1 test"
    )

    assert {:ok, %{reviewsAssignmentId: ^producer_id, effectKind: "review"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, review_call)

    assert review_count(ctx.db, producer.id) == 2
  end

  test "early review admission is independent of producer effect and holder label", ctx do
    reviewer = session(ctx.db, "effect-reviewer", "reviewer", archetype: "reviewer")

    {:ok, _} =
      DB.query(ctx.db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1)")

    put_raw(ctx, File.read!("priv/kungfu/agentic-engineering/rules/engineering.toml"))
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    cases = [
      {"code held by coder", "coder", "code", true},
      {"code held by product owner", "product-owner", "code", true},
      {"policy held by product owner", "product-owner", "policy", false},
      {"policy held by coder", "coder", "policy", false},
      {"documentation classified as policy", "coder", "policy", false}
    ]

    for {label, holder_archetype, effect_kind, needs_receipt?} <- cases do
      holder =
        session(ctx.db, "effect-holder-#{label}", "flynn", archetype: holder_archetype)

      producer =
        assignment(ctx, holder.session_key, {:user, "flynn"},
          effect_kind: effect_kind,
          subject: label
        )

      review_call =
        p3_call("assign", {:user, "reviewer"}, %{
          subject: "review #{label}",
          reviews_assignment_id: producer.id,
          idempotency_key: nil,
          files: nil
        })
        |> Map.put(:session_key, reviewer.session_key)

      if needs_receipt? do
        assert {:ok, early} = Dispatch.dispatch(ctx.db, ctx.handlers, review_call)

        assert early.reviewsAssignmentId == producer.id
        assert early.effectKind == "review"
        assert early.holderKey != holder.session_key
        assert review_count(ctx.db, producer.id) == 1

        verdict(
          ctx,
          holder.session_key,
          producer.id,
          "tests-passed",
          "gibson:/repo effect123; mix test test/rules_test.exs; passed: #{label}"
        )
      end

      assert {:ok, %{reviewsAssignmentId: producer_id, effectKind: "review"}} =
               Dispatch.dispatch(ctx.db, ctx.handlers, review_call)

      assert producer_id == producer.id
      assert review_count(ctx.db, producer.id) == if(needs_receipt?, do: 2, else: 1)
    end
  end

  test "shipped completion notifies its owner without forced review staffing", ctx do
    holder = session(ctx.db, "receipt-remedy-holder", "flynn", archetype: "coder")
    reviewer = session(ctx.db, "receipt-remedy-reviewer", "flynn", archetype: "reviewer-code")
    owner = session(ctx.db, Org.personal_session_key("flynn"), "flynn", archetype: "orchestrator")

    {:ok, _} =
      DB.query(ctx.db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1)")

    Roles.create!(ctx.db, "reviewer-code", "flynn", reviewer.session_key)
    producer = assignment(ctx, holder.session_key, {:user, "flynn"})
    attach_work_item(ctx, producer.id, "wi-accountable-review-notice")

    put_raw(ctx, File.read!("priv/kungfu/agentic-engineering/rules/engineering.toml"))
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    completion =
      p3_call("attest", {:session, holder.session_key}, %{
        assignment_id: producer.id,
        kind: "completion"
      })

    assert {:error,
            %{
              reason: "remedy_fired",
              producer: notice_id,
              rule: "completion-requires-review",
              ref: producer_id
            }} = Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert producer_id == producer.id
    assert review_count(ctx.db, producer.id) == 0
    notice = Wakes.get(ctx.db, notice_id)
    assert notice.session_key == owner.session_key
    assert notice.owner_user_id == "flynn"
    assert notice.assignment_id == producer.id
    assert notice.prompt =~ producer.id

    verdict(
      ctx,
      holder.session_key,
      producer.id,
      "tests-passed",
      "gibson:/repo 378807eabb39cecc25ea801494053f8aa20feafa; " <>
        "mix test test/rules_test.exs; passed: 1 test"
    )

    previous_runner = Application.get_env(:tightbeam, :commit_ref_command)

    on_exit(fn ->
      if previous_runner,
        do: Application.put_env(:tightbeam, :commit_ref_command, previous_runner),
        else: Application.delete_env(:tightbeam, :commit_ref_command)
    end)

    Application.put_env(:tightbeam, :commit_ref_command, fn _executable, _args, _opts ->
      {"", 0}
    end)

    refs = [
      %{
        "repo" => "#{Tightbeam.Placement.local_host_name()}:/tmp/o2-result",
        "commit" => String.duplicate("a", 40)
      }
    ]

    assert %{attest: %{verdictKind: "verified"}} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               p3_call("attest", {:session, holder.session_key}, %{
                 assignment_id: producer.id,
                 kind: "verdict",
                 verdict_kind: "verified",
                 commit_refs: refs
               })
             )

    completion = put_in(completion, [:params, :commit_refs], refs)

    assert {:error,
            %{
              reason: "remedy_fired",
              producer: review_id,
              rule: "completion-requires-review"
            }} = Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert review_id == notice_id
    assert review_count(ctx.db, producer.id) == 0

    assert {:error, %{reason: "remedy_fired", producer: ^review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert review_count(ctx.db, producer.id) == 0
    assert Wakes.get(ctx.db, review_id) != nil

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wakes WHERE assignmentId=?1 AND consumer='prompt' AND origin='remedy:completion-requires-review'",
               [producer.id]
             )

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE workItemId=?1", [
               "wi-accountable-review-notice"
             ])

    assert {:ok, [["open"]]} =
             DB.query(ctx.db, "SELECT state FROM assignments WHERE id=?1", [producer.id])

    assert {:ok, review} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               p3_call("assign", {:user, "flynn"}, %{
                 subject: "owner-directed independent review",
                 reviews_assignment_id: producer.id,
                 idempotency_key: nil,
                 files: nil
               })
               |> Map.put(:session_key, reviewer.session_key)
             )

    review_id = review.id
    assert review.holderKey != holder.session_key

    assert %{attest: %{verdictKind: "reviewed-clean"}} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               p3_call("attest", {:session, reviewer.session_key}, %{
                 assignment_id: review_id,
                 kind: "verdict",
                 verdict_kind: "reviewed-clean",
                 note: "reviewed exact receipt tip",
                 commit_refs: refs
               })
             )

    assert {:ok, %{assignment: %{id: completed_id, state: "closed"}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert completed_id == producer.id
    assert review_count(ctx.db, producer.id) == 1
  end

  test "typed completion keeps code reviewed while receipt exemptions stay narrow", ctx do
    :ok =
      DB.execute(ctx.db, "INSERT INTO users (userId,createdAt) VALUES ('flynn',1),('reviewer',1)")

    coder = session(ctx.db, "receipt-closed", "flynn", archetype: "coder")
    noncoder = session(ctx.db, "receipt-orchestrator", "flynn", archetype: "orchestrator")
    reviewer = session(ctx.db, "receipt-exempt-reviewer", "reviewer", archetype: "reviewer")
    closed = assignment(ctx, coder.session_key, {:user, "flynn"}, effect_kind: "coordination")
    open_coder = assignment(ctx, coder.session_key, {:user, "flynn"})

    policy =
      assignment(ctx, noncoder.session_key, {:user, "flynn"}, effect_kind: "policy")

    orchestration =
      assignment(ctx, noncoder.session_key, {:user, "flynn"}, effect_kind: "evidence")

    assert %{assignment: %{state: "closed"}} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               p3_call("attest", {:session, coder.session_key}, %{
                 assignment_id: closed.id,
                 kind: "completion"
               })
             )

    put_raw(ctx, File.read!("priv/kungfu/agentic-engineering/rules/engineering.toml"))
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    coder_completion =
      p3_call("attest", {:session, coder.session_key}, %{
        assignment_id: open_coder.id,
        kind: "completion"
      })

    evidence_completion =
      p3_call("attest", {:session, noncoder.session_key}, %{
        assignment_id: orchestration.id,
        kind: "completion"
      })

    assert {:deny, %{rule: "completion-requires-review"}} =
             Rules.evaluate(ctx.db, coder_completion)

    assert orchestration.reviewsAssignmentId == nil
    assert orchestration.effectKind == "evidence"

    assert {:ok, %{assignment: %{id: orchestration_id, state: "closed"}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, evidence_completion)

    assert orchestration_id == orchestration.id

    ordinary =
      p3_call("assign", {:user, "reviewer"}, %{
        subject: "ordinary assignment",
        idempotency_key: nil,
        files: nil
      })
      |> Map.put(:session_key, reviewer.session_key)

    assert {:ok, %{reviewsAssignmentId: nil}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, ordinary)

    for producer <- [policy, closed] do
      call =
        p3_call("assign", {:user, "reviewer"}, %{
          subject: "exempt review",
          reviews_assignment_id: producer.id,
          idempotency_key: nil,
          files: nil
        })
        |> Map.put(:session_key, reviewer.session_key)

      assert {:ok, %{reviewsAssignmentId: reviewed}} =
               Dispatch.dispatch(ctx.db, ctx.handlers, call)

      assert reviewed == producer.id
    end
  end

  test "row-commit and verb notices summon without bypassing a later deny", ctx do
    holder = session(ctx.db, "notice-holder", "flynn", archetype: "coder")

    put_raw(ctx, """
    [[rule]]
    name = "assignment-opened"
    verb = "assign"
    edges = ["row-commit"]
    effect = "notice"
    text = "record assignment opening"
    deny_when = [{ fact = "assignment.state", op = "eq", value = "open" }]

    [rule.notice]
    target_session = "notice-holder"
    prompt = "assignment {assignment_id} opened"
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    opened = assignment(ctx, holder.session_key, {:user, "flynn"})

    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.session_key == holder.session_key
    assert wake.prompt == "assignment #{opened.id} opened"
    assert wake.origin == "remedy:assignment-opened"

    assert %{detail: detail} =
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.find(&(&1.kind == "rule_notice" and &1.subject == wake.wake_id))

    assert detail =~ ~s("rule":"assignment-opened")
    assert detail =~ ~s("edge":"row-commit")
    assert detail =~ ~s("row_id":"#{opened.id}")
    assert detail =~ ~s("principal":"user:flynn")

    put_raw(ctx, """
    [[rule]]
    name = "observe-post"
    verb = "post"
    effect = "notice"
    text = "observe the attempt"
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]

    [rule.notice]
    target_session = "notice-holder"
    prompt = "post observed"

    [[rule]]
    name = "deny-post"
    verb = "post"
    text = "deny after observation"
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error, %{code: "rule_denied", rule: "deny-post"}} =
             Dispatch.dispatch(
               ctx.db,
               %{"post" => fn _ -> flunk("handler ran") end},
               p3_call("post", {:user, "flynn"}, %{})
             )

    assert Enum.any?(Wakes.list_pending(ctx.db), &(&1.prompt == "post observed"))
  end

  test "refused operator ask does not publish a fabricated supersession", ctx do
    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1)"
             )

    raiser = session(ctx.db, "ask-raiser", "flynn")
    closed_assignment = assignment(ctx, raiser.session_key, {:user, "flynn"})

    assert %{state: "closed", outcome: "revoked"} =
             Assignments.__handle__(
               ctx.db,
               "revoke-assignment",
               p3_call("revoke-assignment", {:user, "flynn"}, %{
                 assignment_id: closed_assignment.id,
                 reason: "closed assignment refusal fixture"
               })
             )

    old =
      Escalation.operator_ask(
        ctx.db,
        operator_ask_call(raiser.session_key, %{question: "original decision?"})
      )

    put_raw(ctx, """
    [[rule]]
    name = "observe-supersession"
    verb = "operator-ask"
    edges = ["row-commit"]
    effect = "notice"
    text = "record decision supersession"
    deny_when = [{ fact = "decision_request.status", op = "eq", value = "open" }]

    [rule.notice]
    target_session = "ask-raiser"
    prompt = "decision superseded"
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    before_wake_ids = MapSet.new(Wakes.list_pending(ctx.db), & &1.wake_id)

    assert %{code: "not_open"} =
             Escalation.operator_ask(
               ctx.db,
               operator_ask_call(raiser.session_key, %{
                 question: "refused replacement?",
                 supersedes: old.id,
                 assignment: closed_assignment.id
               })
             )

    assert Escalation.get(
             ctx.db,
             %{origin: "user:flynn", principal: {:user, "flynn"}, params: %{}},
             old.id
           ).status == "open"

    pending = Wakes.list_pending(ctx.db)
    assert MapSet.new(pending, & &1.wake_id) == before_wake_ids
    refute Enum.any?(pending, &(&1.prompt == "decision superseded"))
  end

  test "row-commit caller facts use the acting session principal", ctx do
    actor = session(ctx.db, "row-actor", "flynn", archetype: "coder")
    target = session(ctx.db, "row-caller-target", "flynn", archetype: "coder")

    put_raw(ctx, """
    [[rule]]
    name = "agent-opened-assignment"
    verb = "assign"
    edges = ["row-commit"]
    effect = "notice"
    text = "record agent assignment opening"
    deny_when = [
      { fact = "assignment.state", op = "eq", value = "open" },
      { fact = "caller.origin_class", op = "eq", value = "agent" },
      { fact = "caller.user", op = "eq", value = "flynn" }
    ]

    [rule.notice]
    target_session = "row-caller-target"
    prompt = "agent assignment opened"
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    _opened = assignment(ctx, target.session_key, {:session, actor.session_key})

    assert Enum.any?(Wakes.list_pending(ctx.db), fn wake ->
             wake.prompt == "agent assignment opened" and
               wake.creator_session_key == actor.session_key
           end)
  end

  test "row-commit caller facts and notices preserve a remedy principal", ctx do
    target = session(ctx.db, "row-remedy-target", "flynn", archetype: "coder")

    put_raw(ctx, """
    [[rule]]
    name = "remedy-opened-assignment"
    verb = "assign"
    edges = ["row-commit"]
    effect = "notice"
    text = "record remedy assignment opening"
    deny_when = [
      { fact = "assignment.state", op = "eq", value = "open" },
      { fact = "caller.origin_class", op = "eq", value = "remedy" },
      { fact = "caller.user", op = "eq", value = "flynn" }
    ]

    [rule.notice]
    target_session = "row-remedy-target"
    prompt = "remedy assignment opened"
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    item =
      Tightbeam.WorkItems.__handle__(ctx.db, "work-item-create", %{
        principal: {:user, "flynn"},
        origin: "user:flynn",
        params: %{title: "Assignment remedy notice"}
      })

    assert %{deliveryOwnerSessionKey: owner} =
             Tightbeam.WorkItems.__handle__(ctx.db, "work-item-update", %{
               principal: {:user, "flynn"},
               origin: "user:flynn",
               params: %{work_item_id: item.id, delivery_owner_session_key: target.session_key}
             })

    assert owner == target.session_key

    principal = {:remedy, %{statute: "assignment-remedy", action: "assign", owner: "flynn"}}

    call =
      p3_call("assign", {:user, "flynn"}, %{
        subject: "remedy-created assignment",
        work_item_id: item.id,
        idempotency_key: nil,
        reviews_assignment_id: nil,
        effect_kind: nil,
        files: nil
      })
      |> Map.merge(%{
        origin: "remedy:assignment-remedy",
        principal: principal,
        session_key: target.session_key
      })

    assert %{code: "work_item_required"} =
             Assignments.__handle__(
               ctx.db,
               "assign",
               update_in(call.params, &Map.delete(&1, :work_item_id))
             )

    assert %{id: _assignment_id} = Assignments.__handle__(ctx.db, "assign", call)

    assert [wake] =
             ctx.db
             |> Wakes.list_pending()
             |> Enum.filter(&(&1.prompt == "remedy assignment opened"))

    assert %{detail: detail} =
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.find(&(&1.kind == "rule_notice" and &1.subject == wake.wake_id))

    assert detail =~ ~s("principal":"remedy:assignment-remedy")
  end

  test "row-commit queue facts are scoped to the queued session and caller", ctx do
    target = session(ctx.db, "queue-fact-target", "flynn", archetype: "coder")
    other = session(ctx.db, "queue-fact-other", "flynn", archetype: "coder")

    {:ok, oldest_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: target.session_key,
        message_id: "queue-fact-oldest",
        origin: "agent:queue-spammer",
        prompt: "oldest queued message"
      })

    {:ok, newer_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: target.session_key,
        message_id: "queue-fact-newer",
        origin: "agent:queue-spammer",
        prompt: "newer queued message"
      })

    {:ok, newest_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: target.session_key,
        message_id: "queue-fact-other-caller",
        origin: "user:flynn",
        prompt: "different caller"
      })

    {:ok, _other_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: other.session_key,
        message_id: "queue-fact-other-session",
        origin: "agent:queue-spammer",
        prompt: "different session"
      })

    now = System.system_time(:millisecond)

    for {seq, age_ms} <- [{oldest_seq, 120_000}, {newer_seq, 60_000}, {newest_seq, 10_000}] do
      assert {:ok, _} =
               DB.query(ctx.db, "UPDATE turns SET createdAt=?1 WHERE seq=?2", [now - age_ms, seq])
    end

    put_raw(ctx, """
    [[rule]]
    name = "queue-snapshot"
    verb = "post"
    edges = ["row-commit"]
    effect = "notice"
    text = "observe queued-turn facts"
    deny_when = [
      { fact = "turn.queued_count", op = "eq", value = 3 },
      { fact = "turn.oldest_age_ms", op = "gte", value = 90000 },
      { fact = "turn.caller_queued_count", op = "eq", value = 2 }
    ]

    [rule.notice]
    target_session = "{session_key}"
    prompt = "queued by {caller_origin}"
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    transition = %{
      verb: "post",
      domain: "queued_turn",
      owner_user_id: "flynn",
      principal: "session:queue-spammer",
      row_id: "queue-fact-oldest",
      bindings: %{
        sessionKey: target.session_key,
        callerOrigin: "agent:queue-spammer"
      }
    }

    assert {:ok, [{:notice, rule, call, facts}]} =
             DB.transaction(ctx.db, &Rules.row_commit_effects_in_txn(&1, transition))

    assert {"turn.queued_count", 3} in facts
    assert {"turn.caller_queued_count", 2} in facts
    assert {"turn.oldest_age_ms", age_ms} = List.keyfind(facts, "turn.oldest_age_ms", 0)
    assert age_ms >= 120_000

    assert {:ok, {:ok, resolved}} =
             DB.transaction(ctx.db, &Rules.resolve_notice_in_txn(&1, rule, call))

    assert resolved.bound_session == target.session_key
    assert resolved.params.prompt == "queued by agent:queue-spammer"
  end

  test "row-commit notice bindings resolve the assignment opener session", ctx do
    opener = session(ctx.db, Org.personal_session_key("flynn"), "flynn", kind: "main")
    holder = session(ctx.db, "opener-binding-holder", "flynn", archetype: "coder")
    opened = assignment(ctx, holder.session_key, {:user, "flynn"})

    put_raw(ctx, """
    [[rule]]
    name = "assignment-opener-binding"
    verb = "assign"
    edges = ["row-commit"]
    effect = "notice"
    text = "route the notice to the assignment opener"
    deny_when = [{ fact = "assignment.state", op = "eq", value = "open" }]

    [rule.notice]
    target_session = "{assignment_opener_session}"
    prompt = "assignment {assignment_id} opened for {holder_key}"
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    transition = %{
      verb: "assign",
      domain: "assignment",
      owner_user_id: "flynn",
      principal: "user:flynn",
      bindings: %{assignmentId: opened.id}
    }

    assert {:ok, [{:notice, rule, call, _facts}]} =
             DB.transaction(ctx.db, &Rules.row_commit_effects_in_txn(&1, transition))

    assert {:ok, {:ok, resolved}} =
             DB.transaction(ctx.db, &Rules.resolve_notice_in_txn(&1, rule, call))

    assert resolved.bound_session == opener.session_key

    assert resolved.params.prompt ==
             "assignment #{opened.id} opened for #{holder.session_key}"
  end

  test "row-commit review-round and completed-fix facts use the subject work item", ctx do
    {:ok, _} =
      DB.query(ctx.db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1)")

    work_item_id = "wi_row_commit_rounds"
    prior_holder = session(ctx.db, "round-prior-holder", "flynn", archetype: "coder")
    current_holder = session(ctx.db, "round-current-holder", "flynn", archetype: "coder")
    reviewer = session(ctx.db, "round-reviewer", "flynn", archetype: "reviewer-code")

    prior_fix =
      assignment(ctx, prior_holder.session_key, {:user, "flynn"}, effect_kind: "coordination")

    attach_work_item(ctx, prior_fix.id, work_item_id)

    assert %{assignment: %{state: "closed"}} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               p3_call("attest", {:session, prior_holder.session_key}, %{
                 assignment_id: prior_fix.id,
                 kind: "completion"
               })
             )

    current_fix = assignment(ctx, current_holder.session_key, {:user, "flynn"})

    {:ok, _} =
      DB.query(ctx.db, "UPDATE assignments SET workItemId = ?2 WHERE id = ?1", [
        current_fix.id,
        work_item_id
      ])

    review = assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: current_fix.id)
    verdict(ctx, reviewer.session_key, review.id, "changes-requested", "first round")
    verdict(ctx, reviewer.session_key, review.id, "changes-requested", "second round")

    put_raw(ctx, """
    [[rule]]
    name = "review-round-count"
    verb = "attest"
    edges = ["row-commit"]
    effect = "notice"
    text = "observe repeated review rounds"
    deny_when = [{ fact = "assignment.review_verdict_count", op = "eq", value = 2 }]

    [rule.notice]
    target_session = "round-reviewer"
    prompt = "review rounds observed"

    [[rule]]
    name = "completed-fix-count"
    verb = "assign"
    edges = ["row-commit"]
    effect = "notice"
    text = "observe prior completed fixes"
    deny_when = [{ fact = "assignment.prior_completed_fix_count", op = "eq", value = 1 }]

    [rule.notice]
    target_session = "round-reviewer"
    prompt = "completed fixes observed"
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    transitions = [
      %{
        verb: "attest",
        domain: "attest",
        owner_user_id: "flynn",
        principal: "session:round-reviewer",
        bindings: %{assignmentId: review.id, workItemId: work_item_id}
      },
      %{
        verb: "assign",
        domain: "assignment",
        owner_user_id: "flynn",
        principal: "user:flynn",
        bindings: %{assignmentId: current_fix.id, workItemId: work_item_id}
      }
    ]

    assert {:ok, effects} =
             DB.transaction(ctx.db, &Rules.row_commit_effects_in_txn(&1, transitions))

    assert MapSet.new(effects, fn {:notice, rule, _call, _facts} -> rule.name end) ==
             MapSet.new(["review-round-count", "completed-fix-count"])

    assert Enum.any?(effects, fn {:notice, rule, _call, facts} ->
             rule.name == "review-round-count" and {"assignment.review_verdict_count", 2} in facts
           end)

    assert Enum.any?(effects, fn {:notice, rule, _call, facts} ->
             rule.name == "completed-fix-count" and
               {"assignment.prior_completed_fix_count", 1} in facts
           end)
  end

  test "working-without-assignment is evaluated only for a running-turn commit", ctx do
    unassigned = session(ctx.db, "running-unassigned", "flynn", archetype: "coder")
    assigned = session(ctx.db, "running-assigned", "flynn", archetype: "coder")
    _open = assignment(ctx, assigned.session_key, {:user, "flynn"})

    put_raw(ctx, """
    [[rule]]
    name = "working-without-assignment"
    verb = "post"
    edges = ["row-commit"]
    effect = "notice"
    text = "observe working session without assignment"
    deny_when = [{ fact = "session.working_without_open_assignment", op = "eq", value = true }]

    [rule.notice]
    target_session = "running-unassigned"
    prompt = "unassigned work observed"
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    transitions = [
      %{
        verb: "post",
        domain: "running_turn",
        owner_user_id: "flynn",
        principal: "session:running-unassigned",
        bindings: %{
          sessionKey: unassigned.session_key,
          callerOrigin: "session:#{unassigned.session_key}"
        }
      },
      %{
        verb: "post",
        domain: "running_turn",
        owner_user_id: "flynn",
        principal: "session:running-assigned",
        bindings: %{
          sessionKey: assigned.session_key,
          callerOrigin: "session:#{assigned.session_key}"
        }
      },
      %{
        verb: "post",
        domain: "queued_turn",
        owner_user_id: "flynn",
        principal: "session:running-unassigned",
        bindings: %{
          sessionKey: unassigned.session_key,
          callerOrigin: "session:#{unassigned.session_key}"
        }
      }
    ]

    assert {:ok, [{:notice, rule, _call, facts}]} =
             DB.transaction(ctx.db, &Rules.row_commit_effects_in_txn(&1, transitions))

    assert rule.name == "working-without-assignment"
    assert {"session.working_without_open_assignment", true} in facts
  end

  test "Ledger queue and claim commits reach AC6a row-commit rules", ctx do
    holder = session(ctx.db, "ac6a-ledger-event-holder", "flynn", archetype: "coder")

    put_raw(ctx, """
    [[rule]]
    name = "ac6a-queued-depth-one"
    verb = "post"
    edges = ["row-commit"]
    effect = "notice"
    text = "observe one queued turn"
    deny_when = [{ fact = "turn.queued_count", op = "eq", value = 1 }]

    [rule.notice]
    target_session = "ac6a-ledger-event-holder"
    prompt = "one queued turn observed"

    [[rule]]
    name = "ac6a-queued-depth-two"
    verb = "post"
    edges = ["row-commit"]
    effect = "notice"
    text = "observe two queued turns"
    deny_when = [{ fact = "turn.queued_count", op = "eq", value = 2 }]

    [rule.notice]
    target_session = "ac6a-ledger-event-holder"
    prompt = "two queued turns observed"

    [[rule]]
    name = "ac6a-unassigned-running"
    verb = "post"
    edges = ["row-commit"]
    effect = "notice"
    text = "observe unassigned running work"
    deny_when = [
      { fact = "session.working_without_open_assignment", op = "eq", value = true }
    ]

    [rule.notice]
    target_session = "ac6a-ledger-event-holder"
    prompt = "unassigned running turn observed"
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: holder.session_key,
               message_id: "ac6a-ledger-event-one",
               origin: "session:#{holder.session_key}",
               prompt: "one queued turn"
             })

    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: holder.session_key,
               message_id: "ac6a-ledger-event-two",
               origin: "user:flynn",
               prompt: "second queued turn"
             })

    assert {:ok, %{seq: _seq}} = Ledger.claim_next(ctx.db, holder.session_key, "ac6a-claim")

    assert {:ok, [[3]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE origin LIKE 'remedy:ac6a-%' AND state='pending'"
             )
  end

  test "row-commit rejects effects that cannot run after the governed write", ctx do
    put_raw(ctx, """
    [[rule]]
    name = "late-denial"
    verb = "assign"
    edges = ["row-commit"]
    text = "cannot deny a committed assignment"
    deny_when = [{ fact = "assignment.state", op = "eq", value = "open" }]
    """)

    assert_raise ArgumentError, ~r/edge "row-commit" requires effect = "notice"/, fn ->
      Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    end
  end

  test "AC6a backlog crosses at 20, preserves protected traffic, and replays without a notice loop",
       ctx do
    holder = session(ctx.db, "ac6a-backlog-self-holder", "flynn", archetype: "coder")
    caller = session(ctx.db, "ac6a-backlog-caller", "flynn", archetype: "coder")
    opened = assignment(ctx, holder.session_key, {:user, "flynn"})
    work_item_id = "wi_ac6a_backlog_replay"
    attach_work_item(ctx, opened.id, work_item_id)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE assignments SET openedByUser=NULL,openedBySession=?2 WHERE id=?1",
               [opened.id, holder.session_key]
             )

    rules = load_ac6a_rules(ctx)
    assert Enum.count(rules, &String.starts_with?(&1.name, "ac6a-")) == 4

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: holder.session_key,
               message_id: "ac6a-protected-request",
               origin: "process:protected-traffic",
               request_ref: "decision:ac6a-protected",
               assignment_id: opened.id,
               prompt: "protected decision traffic"
             })

    for index <- 1..18 do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: holder.session_key,
                 message_id: "ac6a-backlog-before-#{index}",
                 origin: "session:#{caller.session_key}",
                 assignment_id: opened.id,
                 prompt: "queue below threshold"
               })
    end

    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 0

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: holder.session_key,
               message_id: "ac6a-backlog-threshold",
               wake_id: "ac6a-backlog-threshold-wake",
               origin: "session:#{caller.session_key}",
               assignment_id: opened.id,
               prompt: "cross the 20 queued-turn threshold"
             })

    assert {:ok, [[trigger_seq]]} =
             DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId='ac6a-backlog-threshold-wake'")

    assert {:ok, [[backlog_target, backlog_origin, backlog_assignment, backlog_work_item]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,origin,assignmentId,work_item_id FROM wakes WHERE origin='remedy:ac6a-queue-backlog'"
             )

    assert [backlog_target, backlog_origin, backlog_assignment, backlog_work_item] ==
             [holder.session_key, "remedy:ac6a-queue-backlog", opened.id, work_item_id]

    replay = %{
      verb: "wake",
      domain: "queued_turn",
      row_id: trigger_seq,
      owner_user_id: "flynn",
      principal: "session:#{caller.session_key}",
      bindings: %{
        sessionKey: holder.session_key,
        callerOrigin: "session:#{caller.session_key}",
        assignmentId: opened.id,
        workItemId: work_item_id
      }
    }

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.row_commit_in_txn(txn, replay)
               :ok
             end)

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: holder.session_key,
               message_id: "ac6a-backlog-still-over-threshold",
               origin: "session:#{caller.session_key}",
               assignment_id: opened.id,
               prompt: "remain above the threshold"
             })

    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1

    assert {:ok, [["queued", "decision:ac6a-protected"]]} =
             DB.query(
               ctx.db,
               "SELECT status,requestRef FROM turns WHERE messageId='ac6a-protected-request'"
             )

    assert {:ok,
            [
              [
                notice_wake_id,
                delivered_target,
                delivered_origin,
                delivered_assignment,
                delivered_work_item
              ]
            ]} =
             DB.query(
               ctx.db,
               "SELECT wakeId,sessionKey,origin,assignmentId,work_item_id FROM wakes WHERE origin='remedy:ac6a-queue-backlog'"
             )

    assert [delivered_target, delivered_origin, delivered_assignment, delivered_work_item] ==
             [holder.session_key, "remedy:ac6a-queue-backlog", opened.id, work_item_id]

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: holder.session_key,
               message_id: "ac6a-delivered-notice",
               wake_id: notice_wake_id,
               origin: "remedy:ac6a-queue-backlog",
               assignment_id: opened.id,
               prompt: "the persisted backlog notice was delivered"
             })

    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1
  end

  test "AC6a depth backlog survives claims and rearms after an observed recovery", ctx do
    {holder, opened} = ac6a_backlog_fixture(ctx, "depth-episode")

    for index <- 1..21, do: ac6a_enqueue(ctx, holder, opened, "initial-#{index}")
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1

    assert {:ok, claimed} = Ledger.claim_next(ctx.db, holder.session_key, "depth-first")
    assert queued_depth(ctx.db, holder.session_key) == 20
    # Re-loading rules must not discard the episode: it is derived from durable rows.
    load_ac6a_rules(ctx)
    ac6a_enqueue(ctx, holder, opened, "after-first-claim")
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1
    finish_claim(ctx.db, claimed)

    for index <- 1..3 do
      assert {:ok, claimed} = Ledger.claim_next(ctx.db, holder.session_key, "drain-#{index}")
      finish_claim(ctx.db, claimed)
    end

    assert queued_depth(ctx.db, holder.session_key) == 18
    # A positive-duration gap distinguishes recovery from same-millisecond churn.
    Process.sleep(2)
    ac6a_enqueue(ctx, holder, opened, "below-again")
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1
    ac6a_enqueue(ctx, holder, opened, "recross")
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 2
    ac6a_enqueue(ctx, holder, opened, "after-recross")
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 2
  end

  test "AC6a age backlog survives oldest turnover and a handoff to depth backlog", ctx do
    {holder, opened} = ac6a_backlog_fixture(ctx, "age-episode")
    first = ac6a_enqueue(ctx, holder, opened, "oldest")
    second = ac6a_enqueue(ctx, holder, opened, "next-oldest")
    now = System.system_time(:millisecond)

    for {seq, age} <- [{first, 3_601_000}, {second, 3_600_500}] do
      assert {:ok, _} =
               DB.query(ctx.db, "UPDATE turns SET createdAt=?1 WHERE seq=?2", [now - age, seq])
    end

    ac6a_enqueue(ctx, holder, opened, "age-trigger")
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1

    assert {:ok, %{seq: ^first} = claimed} =
             Ledger.claim_next(ctx.db, holder.session_key, "age-first")

    ac6a_enqueue(ctx, holder, opened, "after-aged-claim")
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1
    finish_claim(ctx.db, claimed)

    for index <- 1..19, do: ac6a_enqueue(ctx, holder, opened, "depth-handoff-#{index}")

    assert {:ok, %{seq: ^second} = claimed} =
             Ledger.claim_next(ctx.db, holder.session_key, "age-second")

    ac6a_enqueue(ctx, holder, opened, "after-last-aged-claim")
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1
    finish_claim(ctx.db, claimed)

    for index <- 1..4 do
      assert {:ok, claimed} = Ledger.claim_next(ctx.db, holder.session_key, "age-drain-#{index}")
      finish_claim(ctx.db, claimed)
    end

    assert queued_depth(ctx.db, holder.session_key) == 18
    Process.sleep(2)
    ac6a_enqueue(ctx, holder, opened, "age-recovery-below")
    ac6a_enqueue(ctx, holder, opened, "age-recovery-recross")
    ac6a_enqueue(ctx, holder, opened, "age-recovery-repeat")
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 2
  end

  test "AC6a coalesces indistinguishable same-millisecond recovery and re-cross", ctx do
    {holder, opened} = ac6a_backlog_fixture(ctx, "tied-episode")
    for index <- 1..20, do: ac6a_enqueue(ctx, holder, opened, "tied-initial-#{index}")
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1
    Process.sleep(2)
    assert {:ok, claimed} = Ledger.claim_next(ctx.db, holder.session_key, "tied-claim")
    assert queued_depth(ctx.db, holder.session_key) == 19

    assert {:ok, [[claimed_at]]} =
             DB.query(ctx.db, "SELECT startedAt FROM turns WHERE seq=?1", [claimed.seq])

    # Use the real enqueue/drain path, fixing only the clock resolution so the
    # ambiguous claim/enqueue boundary is deterministic on every test host.
    assert {:ok, :ok} =
             DB.transaction_then(
               ctx.db,
               fn txn ->
                 assert {:ok, seq} =
                          Ledger.enqueue_in_txn(txn, %{
                            session_key: holder.session_key,
                            message_id: "tied-recross",
                            origin: "process:seed",
                            assignment_id: opened.id,
                            prompt: "same millisecond as claim"
                          })

                 assert {:ok, _} =
                          DB.query(txn, "UPDATE turns SET createdAt=?1 WHERE seq=?2", [
                            claimed_at,
                            seq
                          ])

                 :ok
               end,
               fn txn, :ok -> Wakes.row_commit_in_txn(txn, []) end
             )

    assert queued_depth(ctx.db, holder.session_key) == 20
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1
    finish_claim(ctx.db, claimed)
    Process.sleep(2)
    assert {:ok, claimed} = Ledger.claim_next(ctx.db, holder.session_key, "untied-claim")
    finish_claim(ctx.db, claimed)
    Process.sleep(2)
    ac6a_enqueue(ctx, holder, opened, "untied-recross")
    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 2
  end

  test "AC6a age and sender-flood thresholds fire on crossing, then dedupe", ctx do
    holder = session(ctx.db, "ac6a-age-holder", "flynn", archetype: "coder")
    sender = session(ctx.db, "ac6a-flood-sender", "flynn", archetype: "coder")
    opener = session(ctx.db, Org.personal_session_key("flynn"), "flynn", kind: "main")
    opened = assignment(ctx, holder.session_key, {:user, "flynn"})
    work_item_id = "wi_ac6a_age_threshold"
    attach_work_item(ctx, opened.id, work_item_id)
    _rules = load_ac6a_rules(ctx)

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: holder.session_key,
               message_id: "ac6a-age-oldest",
               origin: "process:seed",
               assignment_id: opened.id,
               prompt: "old queued turn"
             })

    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE turns SET createdAt=?1 WHERE messageId='ac6a-age-oldest'", [
               now - 3_599_000
             ])

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: holder.session_key,
               message_id: "ac6a-age-below",
               origin: "process:seed",
               assignment_id: opened.id,
               prompt: "still below 60 minutes"
             })

    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 0

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE turns SET createdAt=?1 WHERE messageId='ac6a-age-oldest'", [
               System.system_time(:millisecond) - 3_600_001
             ])

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: holder.session_key,
               message_id: "ac6a-age-crossing",
               origin: "process:seed",
               assignment_id: opened.id,
               prompt: "cross 60 minutes"
             })

    assert {:ok, [[age_notice_target]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey FROM wakes WHERE origin='remedy:ac6a-queue-backlog'"
             )

    assert age_notice_target == opener.session_key

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: holder.session_key,
               message_id: "ac6a-age-still-over",
               origin: "process:seed",
               assignment_id: opened.id,
               prompt: "remain age-backlogged"
             })

    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1

    for index <- 1..16 do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: holder.session_key,
                 message_id: "ac6a-age-depth-crossing-#{index}",
                 origin: "process:seed",
                 assignment_id: opened.id,
                 prompt: "the same oldest queued turn remains the backlog episode"
               })
    end

    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 1

    flood_holder = session(ctx.db, "ac6a-flood-holder", "flynn", archetype: "coder")
    sender_role = "ac6a-flood-sender-role"
    assert %{name: ^sender_role} = Roles.create!(ctx.db, sender_role, "flynn", sender.session_key)
    flood_assignment = assignment(ctx, flood_holder.session_key, {:user, "flynn"})
    flood_work_item = "wi_ac6a_flood_threshold"
    attach_work_item(ctx, flood_assignment.id, flood_work_item)

    for index <- 1..3 do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: flood_holder.session_key,
                 message_id: "ac6a-flood-before-backlog-#{index}",
                 origin: "agent:#{sender_role}",
                 assignment_id: flood_assignment.id,
                 prompt: "sender threshold before the recipient is backlogged"
               })
    end

    assert notice_count(ctx.db, "remedy:ac6a-sender-flood") == 0

    for index <- 1..20 do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: flood_holder.session_key,
                 message_id: "ac6a-flood-backlog-seed-#{index}",
                 origin: "process:seed",
                 assignment_id: flood_assignment.id,
                 prompt: "establish the recipient backlog"
               })
    end

    assert notice_count(ctx.db, "remedy:ac6a-queue-backlog") == 2

    assert {:ok, [[backlog_crossing_flood_target]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey FROM wakes WHERE origin='remedy:ac6a-sender-flood' " <>
                 "AND assignmentId=?1",
               [flood_assignment.id]
             )

    assert backlog_crossing_flood_target == sender.session_key

    assert {:ok, [[flood_creator]]} =
             DB.query(
               ctx.db,
               "SELECT creatorSessionKey FROM wakes WHERE origin='remedy:ac6a-sender-flood' " <>
                 "AND assignmentId=?1 ORDER BY createdAt LIMIT 1",
               [flood_assignment.id]
             )

    assert flood_creator == sender.session_key

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: flood_holder.session_key,
               message_id: "ac6a-flood-after-backlog",
               origin: "agent:#{sender_role}",
               assignment_id: flood_assignment.id,
               prompt: "fourth sender message after backlog threshold"
             })

    assert {:ok, [[flood_notice_target]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey FROM wakes WHERE origin='remedy:ac6a-sender-flood'"
             )

    assert flood_notice_target == sender.session_key

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: flood_holder.session_key,
               message_id: "ac6a-flood-after-duplicate",
               origin: "agent:#{sender_role}",
               assignment_id: flood_assignment.id,
               prompt: "fifth sender message"
             })

    assert notice_count(ctx.db, "remedy:ac6a-sender-flood") == 1

    threshold_holder = session(ctx.db, "ac6a-flood-threshold-holder", "flynn", archetype: "coder")
    threshold_assignment = assignment(ctx, threshold_holder.session_key, {:user, "flynn"})
    attach_work_item(ctx, threshold_assignment.id, "wi_ac6a_flood_exact_threshold")

    for index <- 1..20 do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: threshold_holder.session_key,
                 message_id: "ac6a-exact-flood-backlog-#{index}",
                 origin: "process:seed",
                 assignment_id: threshold_assignment.id,
                 prompt: "already-backlogged before sender threshold"
               })
    end

    for index <- 1..2 do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: threshold_holder.session_key,
                 message_id: "ac6a-exact-flood-before-#{index}",
                 origin: "agent:#{sender_role}",
                 assignment_id: threshold_assignment.id,
                 prompt: "two of three sender turns"
               })
    end

    assert notice_count(ctx.db, "remedy:ac6a-sender-flood") == 1

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: threshold_holder.session_key,
               message_id: "ac6a-exact-flood-threshold",
               origin: "agent:#{sender_role}",
               assignment_id: threshold_assignment.id,
               prompt: "third sender turn while already backlogged"
             })

    assert {:ok, [[exact_threshold_target]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey FROM wakes WHERE origin='remedy:ac6a-sender-flood' " <>
                 "ORDER BY createdAt DESC LIMIT 1"
             )

    assert exact_threshold_target == sender.session_key
    assert notice_count(ctx.db, "remedy:ac6a-sender-flood") == 2

    user_holder = session(ctx.db, "ac6a-flood-user-holder", "flynn", archetype: "coder")
    user_assignment = assignment(ctx, user_holder.session_key, {:user, "flynn"})
    attach_work_item(ctx, user_assignment.id, "wi_ac6a_user_flood")

    for index <- 1..20 do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: user_holder.session_key,
                 message_id: "ac6a-user-flood-backlog-#{index}",
                 origin: "process:seed",
                 assignment_id: user_assignment.id,
                 prompt: "backlog for user sender attribution"
               })
    end

    for index <- 1..3 do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: user_holder.session_key,
                 message_id: "ac6a-user-flood-sender-#{index}",
                 origin: "user:flynn",
                 assignment_id: user_assignment.id,
                 prompt: "human sender contributes to a backlogged agent queue"
               })
    end

    assert {:ok, [[user_notice_target]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey FROM wakes WHERE origin='remedy:ac6a-sender-flood' AND assignmentId=?1",
               [user_assignment.id]
             )

    assert user_notice_target == opener.session_key
    assert notice_count(ctx.db, "remedy:ac6a-sender-flood") == 3
  end

  test "AC6a legacy review verdict count spans fresh reviewers and all verdict kinds", ctx do
    review_opener = session(ctx.db, "ac6a-rejection-review-opener", "flynn")

    producer_rounds =
      for index <- 1..4 do
        opener = session(ctx.db, "ac6a-rejection-producer-opener-#{index}", "flynn")
        holder = session(ctx.db, "ac6a-rejection-producer-#{index}", "flynn", archetype: "coder")
        {opener, holder}
      end

    reviewers =
      for index <- 1..4 do
        session(ctx.db, "ac6a-rejection-reviewer-#{index}", "flynn", archetype: "reviewer-code")
      end

    work_item_id = "wi_ac6a_third_review_rejection"
    create_work_item(ctx, work_item_id)
    _rules = load_ac6a_rules(ctx)

    put_raw(
      ctx,
      """
      [[rule]]
      name = "compat-work-item-review-verdict-count"
      verb = "attest"
      edges = ["row-commit"]
      effect = "notice"
      text = "observe the preserved work-item review count"
      deny_when = [{ fact = "work_item.review_verdict_count", op = "eq", value = 3 }]

      [rule.notice]
      target_session = "{assignment_opener_session}"
      prompt = "preserved work-item review count observed"
      idempotency_key = "compat-review-count:{work_item_id}:3"
      """,
      "compat-review-count.toml"
    )

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    compat_producer_opener = session(ctx.db, "ac6a-compat-producer-opener", "flynn")

    compat_producer_holder =
      session(ctx.db, "ac6a-compat-producer-holder", "flynn", archetype: "coder")

    compat_reviewer = session(ctx.db, "ac6a-compat-reviewer", "flynn", archetype: "reviewer-code")

    compat_producer =
      assignment(
        ctx,
        compat_producer_holder.session_key,
        {:session, compat_producer_opener.session_key},
        work_item_id: work_item_id
      )

    compat_review =
      assignment(ctx, compat_reviewer.session_key, {:session, review_opener.session_key},
        reviews: compat_producer.id
      )

    verdict(
      ctx,
      compat_reviewer.session_key,
      compat_review.id,
      "reviewed-clean",
      "compat baseline"
    )

    assert notice_count(ctx.db, "remedy:compat-work-item-review-verdict-count") == 0

    for {reviewer, index} <- Enum.with_index(Enum.take(reviewers, 3), 1) do
      {producer_opener, producer_holder} = Enum.at(producer_rounds, index - 1)

      producer_assignment =
        assignment(ctx, producer_holder.session_key, {:session, producer_opener.session_key},
          work_item_id: work_item_id
        )

      review_assignment =
        assignment(ctx, reviewer.session_key, {:session, review_opener.session_key},
          reviews: producer_assignment.id
        )

      verdict(
        ctx,
        reviewer.session_key,
        review_assignment.id,
        "changes-requested",
        "fresh reviewer #{index}"
      )

      assert notice_count(ctx.db, "remedy:compat-work-item-review-verdict-count") ==
               if(index >= 2, do: 1, else: 0)

      {producer_assignment, review_assignment}
    end

    assert {:ok, [[compat_target, compat_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,prompt FROM wakes " <>
                 "WHERE origin='remedy:compat-work-item-review-verdict-count'"
             )

    assert [compat_target, compat_prompt] ==
             [review_opener.session_key, "preserved work-item review count observed"]

    {fourth_opener, fourth_holder} = Enum.at(producer_rounds, 3)

    fourth_producer_assignment =
      assignment(ctx, fourth_holder.session_key, {:session, fourth_opener.session_key},
        work_item_id: work_item_id
      )

    fourth_review =
      assignment(ctx, Enum.at(reviewers, 3).session_key, {:session, review_opener.session_key},
        reviews: fourth_producer_assignment.id
      )

    verdict(
      ctx,
      Enum.at(reviewers, 3).session_key,
      fourth_review.id,
      "changes-requested",
      "fourth"
    )

    assert notice_count(ctx.db, "remedy:compat-work-item-review-verdict-count") == 1
  end

  test "AC6a fourth review and fix rounds route through real assignment and attest commits",
       ctx do
    assert %{user_id: "flynn"} = Devices.add_user(ctx.db, "flynn", false)
    opener = session(ctx.db, Org.personal_session_key("flynn"), "flynn", kind: "main")
    fix_holder = session(ctx.db, "ac6a-round-fix-holder", "flynn", archetype: "coder")
    reviewer = session(ctx.db, "ac6a-round-reviewer", "flynn", archetype: "reviewer-code")
    review_item = "wi_ac6a_review_round"
    create_work_item(ctx, review_item)
    _rules = load_ac6a_rules(ctx)

    for round <- 1..3 do
      review_subject =
        assignment(ctx, fix_holder.session_key, {:user, "flynn"}, work_item_id: review_item)

      review_assignment =
        assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: review_subject.id)

      verdict(
        ctx,
        reviewer.session_key,
        review_assignment.id,
        "changes-requested",
        "round #{round}"
      )
    end

    churn_origin = "remedy:ac6a-fourth-review-or-fix-round"
    assert notice_count(ctx.db, churn_origin) == 0

    fourth_subject =
      assignment(ctx, fix_holder.session_key, {:user, "flynn"}, work_item_id: review_item)

    fourth_review =
      assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: fourth_subject.id)

    verdict(ctx, reviewer.session_key, fourth_review.id, "changes-requested", "fourth round")

    assert {:ok, [[review_target, review_notice_assignment, review_work_item, review_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,assignmentId,work_item_id,prompt FROM wakes WHERE origin=?1",
               [churn_origin]
             )

    assert [review_target, review_notice_assignment, review_work_item] ==
             [opener.session_key, fourth_review.id, review_item]

    assert review_prompt =~ "fourth review round"

    assert {:ok, [[fourth_attest_id]]} =
             DB.query(
               ctx.db,
               "SELECT id FROM attests WHERE assignmentId=?1 AND note='fourth round'",
               [fourth_review.id]
             )

    replayed_review = %{
      verb: "attest",
      domain: "attest",
      row_id: fourth_attest_id,
      owner_user_id: "flynn",
      principal: "session:#{reviewer.session_key}",
      bindings: %{assignmentId: fourth_review.id, workItemId: nil},
      fields: %{
        kind: %{old: nil, new: "verdict"},
        verdictKind: %{old: nil, new: "changes-requested"}
      }
    }

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.row_commit_in_txn(txn, replayed_review)
               :ok
             end)

    assert notice_count(ctx.db, churn_origin) == 1

    fifth_subject =
      assignment(ctx, fix_holder.session_key, {:user, "flynn"}, work_item_id: review_item)

    fifth_review =
      assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: fifth_subject.id)

    verdict(ctx, reviewer.session_key, fifth_review.id, "changes-requested", "fifth round")
    assert notice_count(ctx.db, churn_origin) == 1

    fix_item = "wi_ac6a_fourth_fix_round"
    create_work_item(ctx, fix_item)

    for round <- 1..3 do
      prior =
        assignment(ctx, fix_holder.session_key, {:user, "flynn"},
          work_item_id: fix_item,
          effect_kind: "code"
        )

      refs = verified_code_refs(ctx, prior, fix_holder, reviewer)

      assert %{assignment: %{state: "closed", outcome: "completed"}} =
               Assignments.__handle__(
                 ctx.db,
                 "attest",
                 p3_call("attest", {:session, fix_holder.session_key}, %{
                   assignment_id: prior.id,
                   kind: "completion",
                   commit_refs: refs
                 })
               )
    end

    assert notice_count(ctx.db, churn_origin) == 1

    fourth =
      assignment(ctx, fix_holder.session_key, {:user, "flynn"},
        work_item_id: fix_item,
        effect_kind: "code"
      )

    assert {:ok, [[fix_target, fix_assignment, fix_work_item, fix_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,assignmentId,work_item_id,prompt FROM wakes " <>
                 "WHERE origin=?1 AND prompt LIKE '%fourth fix round%'",
               [churn_origin]
             )

    assert [fix_target, fix_assignment, fix_work_item] ==
             [opener.session_key, fourth.id, fix_item]

    assert fix_prompt =~ "fourth fix round"

    fifth =
      assignment(ctx, fix_holder.session_key, {:user, "flynn"},
        work_item_id: fix_item,
        effect_kind: "code"
      )

    assert fourth.id != fifth.id
    assert notice_count(ctx.db, churn_origin) == 2
  end

  test "AC6a routes unassigned agent stretches to the item coordinator once and excludes human starts",
       ctx do
    assert %{user_id: "flynn"} = Devices.add_user(ctx.db, "flynn", false)
    agent = session(ctx.db, "ac6a-unassigned-agent", "flynn", archetype: "coder")
    foreign_sender = session(ctx.db, "ac6a-foreign-agent", "flynn", archetype: "coder")
    human_started = session(ctx.db, "ac6a-human-started", "flynn", archetype: "coder")
    agent_role = "ac6a-unassigned-agent-role"
    assert %{name: ^agent_role} = Roles.create!(ctx.db, agent_role, "flynn", agent.session_key)

    work_item_id = "wi_ac6a_unassigned_stretch"
    create_work_item(ctx, work_item_id)
    coordinator = setup_work_item_coordinator(ctx, work_item_id)

    stale_assignment =
      assignment(ctx, agent.session_key, {:user, "flynn"}, work_item_id: work_item_id)

    assert %{state: "closed", outcome: "revoked"} =
             Assignments.__handle__(
               ctx.db,
               "revoke-assignment",
               p3_call("revoke-assignment", {:user, "flynn"}, %{
                 assignment_id: stale_assignment.id,
                 reason: "end the earlier assignment before the unassigned stretch"
               })
             )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE assignments SET openedByUser=NULL,openedBySession='missing-opener' WHERE id=?1",
               [stale_assignment.id]
             )

    _rules = load_ac6a_rules(ctx)

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: agent.session_key,
               message_id: "ac6a-agent-turn-one",
               assignment_id: stale_assignment.id,
               origin: "agent:#{agent_role}",
               prompt: "agent started without an open assignment"
             })

    assert {:ok, %{seq: first_seq, owner_lease: first_lease}} =
             Ledger.claim_next(ctx.db, agent.session_key, "ac6a-agent-claim-one")

    assert {:ok, [[first_target, first_assignment, first_work_item]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,assignmentId,work_item_id FROM wakes " <>
                 "WHERE origin='remedy:ac6a-unassigned-agent-turn'"
             )

    assert [first_target, first_assignment, first_work_item] ==
             [coordinator.session_key, stale_assignment.id, work_item_id]

    assert :ok = Ledger.finish(ctx.db, first_seq, "delivered", nil, owner_lease: first_lease)

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: agent.session_key,
               message_id: "ac6a-agent-turn-two",
               assignment_id: stale_assignment.id,
               origin: "session:#{agent.session_key}",
               prompt: "same unassigned stretch"
             })

    assert {:ok, %{seq: second_seq, owner_lease: second_lease}} =
             Ledger.claim_next(ctx.db, agent.session_key, "ac6a-agent-claim-two")

    assert notice_count(ctx.db, "remedy:ac6a-unassigned-agent-turn") == 1
    assert :ok = Ledger.finish(ctx.db, second_seq, "delivered", nil, owner_lease: second_lease)

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: agent.session_key,
               message_id: "ac6a-foreign-started-turn",
               assignment_id: stale_assignment.id,
               origin: "session:#{foreign_sender.session_key}",
               prompt: "another agent started this turn"
             })

    assert {:ok, %{seq: foreign_seq, owner_lease: foreign_lease}} =
             Ledger.claim_next(ctx.db, agent.session_key, "ac6a-foreign-claim")

    assert :ok = Ledger.finish(ctx.db, foreign_seq, "delivered", nil, owner_lease: foreign_lease)
    assert notice_count(ctx.db, "remedy:ac6a-unassigned-agent-turn") == 1

    opened =
      assignment(ctx, agent.session_key, {:user, "flynn"},
        work_item_id: work_item_id,
        effect_kind: "code"
      )

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: agent.session_key,
               message_id: "ac6a-assigned-agent-turn",
               assignment_id: opened.id,
               origin: "session:#{agent.session_key}",
               prompt: "an open assignment suppresses the finding"
             })

    assert {:ok, %{seq: assigned_seq, owner_lease: assigned_lease}} =
             Ledger.claim_next(ctx.db, agent.session_key, "ac6a-assigned-claim")

    assert notice_count(ctx.db, "remedy:ac6a-unassigned-agent-turn") == 1

    assert :ok =
             Ledger.finish(ctx.db, assigned_seq, "delivered", nil, owner_lease: assigned_lease)

    reviewer = session(ctx.db, "ac6a-unassigned-reviewer", "flynn", archetype: "reviewer-code")
    refs = verified_code_refs(ctx, opened, agent, reviewer)

    assert %{assignment: %{state: "closed", outcome: "completed"}} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               p3_call("attest", {:session, agent.session_key}, %{
                 assignment_id: opened.id,
                 kind: "completion",
                 commit_refs: refs
               })
             )

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: agent.session_key,
               message_id: "ac6a-agent-turn-after-assignment",
               assignment_id: opened.id,
               origin: "session:#{agent.session_key}",
               prompt: "a new unassigned stretch starts after the assignment closes"
             })

    assert {:ok, %{seq: after_assignment_seq, owner_lease: after_assignment_lease}} =
             Ledger.claim_next(ctx.db, agent.session_key, "ac6a-after-assignment-claim")

    assert notice_count(ctx.db, "remedy:ac6a-unassigned-agent-turn") == 2

    assert :ok =
             Ledger.finish(ctx.db, after_assignment_seq, "delivered", nil,
               owner_lease: after_assignment_lease
             )

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: agent.session_key,
               message_id: "ac6a-agent-turn-after-assignment-two",
               assignment_id: opened.id,
               origin: "session:#{agent.session_key}",
               prompt: "same later stretch"
             })

    assert {:ok, %{seq: _later_seq}} =
             Ledger.claim_next(ctx.db, agent.session_key, "ac6a-after-assignment-claim-two")

    assert notice_count(ctx.db, "remedy:ac6a-unassigned-agent-turn") == 2

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: human_started.session_key,
               message_id: "ac6a-human-started-turn",
               origin: "user:flynn",
               prompt: "human-started work does not count"
             })

    assert {:ok, %{seq: _human_seq}} =
             Ledger.claim_next(ctx.db, human_started.session_key, "ac6a-human-claim")

    assert notice_count(ctx.db, "remedy:ac6a-unassigned-agent-turn") == 2

    no_context = session(ctx.db, "ac6a-unassigned-no-context", "flynn", archetype: "coder")
    no_context_role = "ac6a-unassigned-no-context-role"

    assert %{name: ^no_context_role} =
             Roles.create!(ctx.db, no_context_role, "flynn", no_context.session_key)

    assert {:ok, _} =
             Ledger.enqueue(ctx.db, %{
               session_key: no_context.session_key,
               message_id: "ac6a-unassigned-no-context",
               origin: "agent:#{no_context_role}",
               prompt: "no assignment or work item context"
             })

    assert {:ok, %{seq: no_context_seq, owner_lease: no_context_lease}} =
             Ledger.claim_next(ctx.db, no_context.session_key, "ac6a-unassigned-no-context-claim")

    assert notice_count(ctx.db, "remedy:ac6a-unassigned-agent-turn") == 2

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM lifecycle_events WHERE kind='rule_notice_failed' " <>
                 "AND subject='ac6a-unassigned-agent-turn'"
             )

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE kind='operator'")

    assert :ok =
             Ledger.finish(ctx.db, no_context_seq, "delivered", nil,
               owner_lease: no_context_lease
             )
  end

  test "AC6a absent or invalid opener falls back and missing context keeps the enqueue",
       ctx do
    holder = session(ctx.db, "ac6a-fallback-holder", "flynn", archetype: "coder")
    opened = assignment(ctx, holder.session_key, {:user, "flynn"})
    work_item_id = "wi_ac6a_invalid_opener_fallback"
    attach_work_item(ctx, opened.id, work_item_id)
    coordinator = setup_work_item_coordinator(ctx, work_item_id)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE assignments SET openedByUser=NULL,openedBySession='missing-opener' WHERE id=?1",
               [opened.id]
             )

    _rules = load_ac6a_rules(ctx)

    for index <- 1..20 do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: holder.session_key,
                 message_id: "ac6a-fallback-#{index}",
                 origin: "process:seed",
                 assignment_id: opened.id,
                 prompt: "cross the coordinator fallback threshold"
               })
    end

    assert {:ok, [[fallback_target, fallback_assignment, fallback_work_item]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,assignmentId,work_item_id FROM wakes WHERE origin='remedy:ac6a-queue-backlog'"
             )

    assert [fallback_target, fallback_assignment, fallback_work_item] ==
             [coordinator.session_key, opened.id, work_item_id]

    absent_holder = session(ctx.db, "ac6a-absent-opener-holder", "flynn", archetype: "coder")

    absent_opener_assignment =
      assignment(ctx, absent_holder.session_key, {:user, "flynn"}, work_item_id: work_item_id)

    # A user opener without a Main session has no reachable notice recipient.
    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM sessions WHERE sessionKey=?1", [
               Org.personal_session_key("flynn")
             ])

    for index <- 1..20 do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: absent_holder.session_key,
                 message_id: "ac6a-absent-opener-#{index}",
                 origin: "process:seed",
                 assignment_id: absent_opener_assignment.id,
                 prompt: "cross the threshold with no opener"
               })
    end

    assert {:ok, [[absent_fallback_target, absent_fallback_assignment, absent_fallback_item]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,assignmentId,work_item_id FROM wakes WHERE origin='remedy:ac6a-queue-backlog' AND assignmentId=?1",
               [absent_opener_assignment.id]
             )

    assert [absent_fallback_target, absent_fallback_assignment, absent_fallback_item] ==
             [coordinator.session_key, absent_opener_assignment.id, work_item_id]

    no_context = session(ctx.db, "ac6a-missing-owner-context", "flynn", archetype: "coder")

    for index <- 1..20 do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: no_context.session_key,
                 message_id: "ac6a-no-context-#{index}",
                 origin: "process:seed",
                 prompt: "no opener or work item context"
               })
    end

    assert {:ok, [[20]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE sessionKey=?1 AND status='queued'",
               [no_context.session_key]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM lifecycle_events WHERE kind='rule_notice_failed' AND subject='ac6a-queue-backlog'"
             )
  end

  test "ad hoc predicates validate ownership and make nil fail every operator", ctx do
    own = session(ctx.db, "predicate-own", "flynn")
    foreign = session(ctx.db, "predicate-foreign", "kay")
    own_assignment = assignment(ctx, own.session_key, {:user, "flynn"})
    foreign_assignment = assignment(ctx, foreign.session_key, {:user, "kay"})

    valid_predicate = %{
      owner_user_id: "flynn",
      conditions: [%{fact: "assignment.state", op: "eq", value: "open"}],
      bindings: %{assignment_id: own_assignment.id}
    }

    assert {:error, %{code: "invalid_predicate", message: dropped_message}} =
             Rules.evaluate_predicate(ctx.db, Map.delete(valid_predicate, :conditions))

    assert dropped_message =~ "predicate conditions must be a non-empty list"

    assert {:ok, %{matched: true, facts: [{"assignment.state", "open"}]}} =
             Rules.evaluate_predicate(ctx.db, valid_predicate)

    for op <- ~w(ne not_in) do
      value = if op == "ne", do: "completed", else: ["completed"]

      assert {:ok, %{matched: false, facts: [{"assignment.outcome", nil}]}} =
               Rules.evaluate_predicate(ctx.db, %{
                 owner_user_id: "flynn",
                 conditions: [%{fact: "assignment.outcome", op: op, value: value}],
                 bindings: %{assignment_id: own_assignment.id}
               })
    end

    assert {:error, %{code: "invalid_predicate", message: ownership_error}} =
             Rules.evaluate_predicate(ctx.db, %{
               owner_user_id: "flynn",
               conditions: [%{fact: "assignment.state", op: "eq", value: "open"}],
               bindings: %{assignment_id: foreign_assignment.id}
             })

    assert ownership_error == "unknown or inaccessible assignment binding"

    for condition <- [
          %{fact: "assignment.unknown", op: "eq", value: "open"},
          %{fact: "assignment.state", op: "matches", value: "open"},
          %{fact: "assignment.state", op: "eq", value: 1}
        ] do
      assert {:error, %{code: "invalid_predicate"}} =
               Rules.evaluate_predicate(ctx.db, %{
                 owner_user_id: "flynn",
                 conditions: [condition],
                 bindings: %{assignment_id: own_assignment.id}
               })
    end
  end

  test "artifact revisions bind their producer, review verdict, and predicate candidate", ctx do
    producer_holder = session(ctx.db, "revision-producer", "flynn", archetype: "coder")
    reviewer = session(ctx.db, "revision-reviewer", "flynn", archetype: "reviewer")
    foreign_holder = session(ctx.db, "revision-foreign", "kay", archetype: "coder")
    producer = assignment(ctx, producer_holder.session_key, {:user, "flynn"})
    attach_work_item(ctx, producer.id, "wi_revision_binding")

    review = assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: producer.id)

    foreign = assignment(ctx, foreign_holder.session_key, {:user, "kay"})

    {:ok, _} =
      DB.query(ctx.db, "UPDATE assignments SET workItemId=?2 WHERE id=?1", [
        foreign.id,
        "wi_revision_binding"
      ])

    hash = String.duplicate("a", 64)

    assert %{code: "invalid_producer"} =
             record_revision_artifact(
               ctx,
               foreign_holder.session_key,
               foreign.id,
               "wi_revision_binding",
               hash
             )

    artifact =
      record_revision_artifact(
        ctx,
        producer_holder.session_key,
        producer.id,
        "wi_revision_binding",
        hash
      )

    assert artifact.produced_by_assignment_id == producer.id
    assert artifact.content_sha256 == hash

    legacy = verdict(ctx, reviewer.session_key, review.id, "reviewed-clean")
    assert legacy.attest.artifactId == nil
    assert legacy.attest.contentSha256 == nil

    predicate = %{
      owner_user_id: "flynn",
      conditions: [
        %{fact: "artifact.present", op: "eq", value: true},
        %{fact: "artifact.content_sha256", op: "eq", value: hash},
        %{
          fact: "review.qualifying_verdict_kinds",
          op: "in",
          value: ["reviewed-clean"]
        }
      ],
      bindings: %{artifact: %{artifact_id: artifact.artifact_id, content_sha256: hash}}
    }

    assert {:ok, %{matched: false}} = Rules.evaluate_predicate(ctx.db, predicate)

    assert %{code: "invalid_revision_binding"} =
             revision_verdict(ctx, reviewer.session_key, review.id, artifact.artifact_id, nil)

    assert %{code: "invalid_revision_binding"} =
             revision_verdict(
               ctx,
               reviewer.session_key,
               review.id,
               artifact.artifact_id,
               String.duplicate("b", 64)
             )

    valid =
      revision_verdict(
        ctx,
        reviewer.session_key,
        review.id,
        artifact.artifact_id,
        hash,
        "reviewed-clean"
      )

    assert valid.attest.artifactId == artifact.artifact_id
    assert valid.attest.contentSha256 == hash
    assert {:ok, %{matched: true}} = Rules.evaluate_predicate(ctx.db, predicate)

    revision_verdict(
      ctx,
      reviewer.session_key,
      review.id,
      artifact.artifact_id,
      hash,
      "changes-requested"
    )

    assert {:ok, %{matched: false}} = Rules.evaluate_predicate(ctx.db, predicate)
  end

  test "artifact presence is one boolean for a fixed producer and hash selector", ctx do
    producer_holder = session(ctx.db, "presence-producer", "flynn", archetype: "coder")
    producer = assignment(ctx, producer_holder.session_key, {:user, "flynn"})
    attach_work_item(ctx, producer.id, "wi_presence_selector")

    old_hash = String.duplicate("0", 64)
    wanted_hash = String.duplicate("1", 64)
    missing_hash = String.duplicate("2", 64)

    record_revision_artifact(
      ctx,
      producer_holder.session_key,
      producer.id,
      "wi_presence_selector",
      old_hash
    )

    record_revision_artifact(
      ctx,
      producer_holder.session_key,
      producer.id,
      "wi_presence_selector",
      wanted_hash
    )

    predicate = fn hash, present ->
      %{
        owner_user_id: "flynn",
        conditions: [%{fact: "artifact.present", op: "eq", value: present}],
        bindings: %{
          artifact: %{produced_by_assignment_id: producer.id, content_sha256: hash}
        }
      }
    end

    assert {:ok, %{matched: false}} =
             Rules.evaluate_predicate(ctx.db, predicate.(wanted_hash, false))

    assert {:ok, %{matched: true}} =
             Rules.evaluate_predicate(ctx.db, predicate.(wanted_hash, true))

    assert {:ok, %{matched: true}} =
             Rules.evaluate_predicate(ctx.db, predicate.(missing_hash, false))
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
      role_fallback: false,
      supervision_interval_ms: 1_000
    }
  end

  defp operator_ask_call(session_key, params) do
    %{
      verb: "operator-ask",
      origin: "agent:#{session_key}",
      principal: {:session, session_key},
      transport_session_key: session_key,
      params: params
    }
  end

  defp assignment(ctx, holder_key, opener, opts \\ []) do
    call =
      p3_call("assign", opener, %{
        subject: opts[:subject] || "P3 assignment #{System.unique_integer([:positive])}",
        idempotency_key: nil,
        work_item_id: opts[:work_item_id],
        reviews_assignment_id: opts[:reviews],
        effect_kind: opts[:effect_kind],
        files: opts[:files]
      })

    Assignments.__handle__(ctx.db, "assign", %{call | session_key: holder_key})
  end

  defp verdict(ctx, session_key, assignment_id, verdict_kind, note \\ nil) do
    Assignments.__handle__(
      ctx.db,
      "attest",
      p3_call("attest", {:session, session_key}, %{
        assignment_id: assignment_id,
        kind: "verdict",
        verdict_kind: verdict_kind,
        note: note
      })
    )
  end

  defp user_verdict(ctx, user, assignment_id, verdict_kind, note \\ nil) do
    Assignments.__handle__(
      ctx.db,
      "attest",
      p3_call("attest", {:user, user}, %{
        assignment_id: assignment_id,
        kind: "verdict",
        verdict_kind: verdict_kind,
        note: note
      })
    )
  end

  defp revision_verdict(
         ctx,
         session_key,
         assignment_id,
         artifact_id,
         hash,
         verdict_kind \\ "reviewed-clean"
       ) do
    Assignments.__handle__(
      ctx.db,
      "attest",
      p3_call("attest", {:session, session_key}, %{
        assignment_id: assignment_id,
        kind: "verdict",
        verdict_kind: verdict_kind,
        artifact_id: artifact_id,
        content_sha256: hash
      })
    )
  end

  defp record_revision_artifact(ctx, session_key, producer_id, work_item_id, hash) do
    Artifacts.record(ctx.db, %{
      principal: {:session, session_key},
      session_key: session_key,
      params: %{
        kind: "report",
        title: "candidate revision",
        origin_path: "/tmp/candidate-revision",
        work_item_id: work_item_id,
        content_sha256: hash,
        produced_by_assignment_id: producer_id
      }
    })
  end

  defp review_count(db, producer_id) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT count(*) FROM assignments WHERE reviewsAssignmentId = ?1", [
        producer_id
      ])

    count
  end

  defp attach_work_item(ctx, assignment_id, work_item_id) do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO work_items (id, title, ownerUserId, state, createdByUser, createdAt) VALUES (?1, 'artifact gate item', 'flynn', 'open', 'flynn', 1)",
        [work_item_id]
      )

    {:ok, _} =
      DB.query(ctx.db, "UPDATE assignments SET workItemId = ?2 WHERE id = ?1", [
        assignment_id,
        work_item_id
      ])
  end

  defp create_work_item(ctx, work_item_id) do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO work_items (id, title, ownerUserId, state, createdByUser, createdAt) " <>
          "VALUES (?1, 'AC6a row test', 'flynn', 'open', 'flynn', 1)",
        [work_item_id]
      )
  end

  defp load_ac6a_rules(ctx) do
    put_raw(
      ctx,
      File.read!("priv/kungfu/agentic-engineering/rules/ac6a.toml"),
      "ac6a.toml"
    )

    rules = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
    # Gateway startup activates row-commit recognition after loading rules.
    :ok = Wakes.activate_wait_recognition(ctx.db)
    rules
  end

  defp ac6a_backlog_fixture(ctx, name) do
    holder = session(ctx.db, "ac6a-#{name}", "flynn", archetype: "coder")
    session(ctx.db, Org.personal_session_key("flynn"), "flynn", kind: "main")
    opened = assignment(ctx, holder.session_key, {:user, "flynn"})
    attach_work_item(ctx, opened.id, "wi_ac6a_#{name}")
    load_ac6a_rules(ctx)
    {holder, opened}
  end

  defp ac6a_enqueue(ctx, holder, opened, message_id) do
    assert {:ok, seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: holder.session_key,
               message_id: message_id,
               origin: "process:seed",
               assignment_id: opened.id,
               prompt: "backlog episode regression"
             })

    seq
  end

  defp queued_depth(db, session_key) do
    assert {:ok, [[count]]} =
             DB.query(db, "SELECT COUNT(*) FROM turns WHERE sessionKey=?1 AND status='queued'", [
               session_key
             ])

    count
  end

  defp finish_claim(db, claimed) do
    assert :ok =
             Ledger.finish(db, claimed.seq, "delivered", nil, owner_lease: claimed.owner_lease)
  end

  defp verified_code_refs(ctx, producer, holder, reviewer) do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])

    refs = [
      %{
        "repo" => "#{Tightbeam.Placement.local_host_name()}:#{File.cwd!()}",
        "commit" => String.trim(sha)
      }
    ]

    review = assignment(ctx, reviewer.session_key, {:user, "flynn"}, reviews: producer.id)

    for {session_key, assignment_id, kind} <- [
          {holder.session_key, producer.id, "verified"},
          {reviewer.session_key, review.id, "reviewed-clean"}
        ] do
      assert %{attest: %{verdictKind: ^kind}} =
               Assignments.__handle__(
                 ctx.db,
                 "attest",
                 p3_call("attest", {:session, session_key}, %{
                   assignment_id: assignment_id,
                   kind: "verdict",
                   verdict_kind: kind,
                   commit_refs: refs
                 })
               )
    end

    refs
  end

  defp notice_count(db, origin) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM wakes WHERE origin=?1", [origin])
    count
  end

  defp setup_work_item_coordinator(ctx, work_item_id) do
    po_office = session(ctx.db, "ac6a-po-office", "flynn", archetype: "product-owner")
    coordinator = session(ctx.db, "ac6a-work-item-coordinator", "flynn", archetype: "pdo")
    po_role = "product-owner:ac6a-test"
    assert %{name: ^po_role} = Roles.create!(ctx.db, po_role, "flynn", po_office.session_key)

    assert %{"changed" => true} =
             SessionPoAssociations.handle(ctx.db, %{
               origin: "user:flynn",
               principal: {:user, "flynn"},
               params: %{
                 session_key: coordinator.session_key,
                 po_role: po_role,
                 idempotency_key: "ac6a-coordinator-association"
               }
             })

    assert %{"changed" => true} =
             DeliveryResponsibilities.handle(ctx.db, %{
               verb: "delivery-scope-owner-set",
               origin: "user:flynn",
               principal: {:user, "flynn"},
               params: %{
                 session_key: coordinator.session_key,
                 association_revision: 1,
                 expected_owner_session_key: nil,
                 expected_owner_revision: 0,
                 idempotency_key: "ac6a-coordinator-owner"
               }
             })

    assert %{"changed" => true} =
             DeliveryResponsibilities.handle(ctx.db, %{
               verb: "work-item-delivery-scope-set",
               origin: "user:flynn",
               principal: {:user, "flynn"},
               params: %{
                 work_item_id: work_item_id,
                 association_session_key: coordinator.session_key,
                 association_revision: 1,
                 expected_binding_revision: 0,
                 idempotency_key: "ac6a-coordinator-work-item-binding"
               }
             })

    coordinator
  end

  defp record_artifact(ctx, work_item_id, session_key, kind, state) do
    home = if state == "archived", do: "/tmp/archive/#{System.unique_integer([:positive])}"
    message_id = "msg_#{System.unique_integer([:positive])}"

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO messages (id, sessionKey, role, content, timestamp, llmVisibleMessageId) VALUES (?1, ?2, 'assistant', 'recorded', 1, ?1)",
        [message_id, session_key]
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO artifacts
          (artifactId, kind, title, createdBySession, workItemId, originPath,
           recordedMessageId, state, home, createdAt, updatedAt)
        VALUES (?1, ?2, 'results', ?3, ?4, '/tmp/results.txt', ?5, ?6, ?7, 1, 1)
        """,
        [
          "art_#{System.unique_integer([:positive])}",
          kind,
          session_key,
          work_item_id,
          message_id,
          state,
          home
        ]
      )
  end

  defp review_gate_rule do
    """
    [[rule]]
    name = "needs-independent-review"
    verb = "attest"
    text = "producing completion requires exactly one independent linked review"
    external_producer = true
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.effect_kind", op = "in", value = ["code", "policy", "release", "live_mutation"] },
      { fact = "assignment.qualifying_review_verdict_kinds", op = "not_in", value = ["reviewed-clean"] }
    ]
    """
  end

  defp artifact_gate_rule do
    """
    [[rule]]
    name = "needs-results-artifact"
    verb = "attest"
    text = "completion requires a holder-recorded results artifact"
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.holder_archetype", op = "eq", value = "coder" },
      { fact = "assignment.artifact_kinds", op = "not_in", value = ["report"] }
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
             "assignment.qualifying_review_verdict_kinds"
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
      kind:
        Keyword.get(
          opts,
          :kind,
          if(key == Org.personal_session_key(owner), do: "main", else: "custom")
        ),
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: Keyword.get(opts, :archetype, "default"),
      host: "testhost",
      harness: Keyword.get(opts, :harness, "claude"),
      provider: Keyword.get(opts, :provider, "anthropic"),
      model: Model.new("fable")
    })
  end
end
