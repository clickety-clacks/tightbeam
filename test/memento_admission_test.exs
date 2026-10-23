defmodule Tightbeam.MementoAdmissionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    Artifacts,
    DB,
    Dispatch,
    Gateway,
    Mementos,
    MementoJudgments,
    Model,
    Org,
    Placement,
    Rules
  }

  setup context do
    file_owner =
      if context[:file_db] do
        root = Path.join(System.tmp_dir!(), "memento-replay-" <> Tightbeam.Id.uuid4())
        File.mkdir_p!(root)
        on_exit(fn -> File.rm_rf!(root) end)
        %{payload: payload} = Tightbeam.GuardRuntimeFixture.prepare!(root, "unused")

        Supervisor.child_spec(
          {DB,
           path: Path.join(root, "state.db"), name: nil, guard_inputs: [], payload_root: payload},
          id: :memento_file_owner
        )
      end

    db = start_supervised!(file_owner || {DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)
    host = Placement.local_host_name()

    register_hosts(db, %{
      host => %{ssh: nil, base_dir: Application.fetch_env!(:tightbeam, :base_dir), cli_bin: nil}
    })

    DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('owner',1,1)")

    for key <- ["holder", "reviewer", Org.personal_session_key("owner")] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        kind: if(key == Org.personal_session_key("owner"), do: "main", else: "custom"),
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable"),
        host: host
      })
    end

    base = Path.join(System.tmp_dir!(), "memento-admission-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "identity/rules"))
    File.mkdir_p!(Path.join(base, "identity/kungfu/example"))

    File.write!(Path.join(base, "identity/kungfu/example/manifest.toml"), """
    [[mementos]]
    name = "target"
    records = ["work_item"]
    [[mementos]]
    name = "classification"
    records = ["assignment"]
    [[mementos]]
    name = "outcome"
    records = ["assignment"]
    [[mementos]]
    name = "references"
    records = ["attest"]
    many = true
    """)

    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1000})
    Rules.load!(base, Map.keys(handlers), revision: "test-revision")
    on_exit(fn -> File.rm_rf!(base) end)

    commit_repo = Path.join(base, "commit-reference")
    File.mkdir_p!(commit_repo)
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: commit_repo)
    File.write!(Path.join(commit_repo, "fixture.txt"), "immutable fixture\n")
    {_, 0} = System.cmd("git", ["add", "fixture.txt"], cd: commit_repo)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Test Fixture",
          "-c",
          "user.email=test@example.invalid",
          "commit",
          "--quiet",
          "-m",
          "fixture"
        ],
        cd: commit_repo
      )

    {commit, 0} = System.cmd("git", ["-C", commit_repo, "rev-parse", "HEAD"])

    commit_refs = [
      %{
        "repo" => "#{host}:#{Path.expand(commit_repo)}",
        "commit" => String.trim(commit)
      }
    ]

    %{db: db, base: base, handlers: handlers, file_owner: file_owner, commit_refs: commit_refs}
  end

  test "legacy admission keeps effect-kind facts while memento writes remain available", ctx do
    File.write!(Path.join(ctx.base, "identity/rules/legacy.toml"), """
    [[rule]]
    name = "legacy-review"
    verb = "attest"
    external_producer = true
    text = "legacy review remains required while mapping values"
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.effect_kind", op = "eq", value = "code" },
      { fact = "assignment.qualifying_review_verdict_kinds", op = "not_in", value = ["reviewed-clean"] }
    ]
    [[rule]]
    name = "legacy-verification"
    verb = "attest"
    external_producer = true
    text = "legacy verification facts still load"
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.effect_kind", op = "eq", value = "code" },
      { fact = "assignment.qualifying_verification_verdict_kinds", op = "not_in", value = ["verified"] }
    ]
    """)

    assert length(Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "legacy-policy")) == 2
    refute Map.has_key?(Rules.effective_snapshot().unavailable_verbs, "attest")
    producer = ctx.handlers["assign"].(call("assign", %{subject: "legacy default"}, "holder"))
    assert producer.effectKind == "code"

    assert {:ok, [["code"]]} =
             DB.query(ctx.db, "SELECT effectKind FROM assignment_effects WHERE assignmentId=?1", [
               producer.id
             ])

    input =
      call("attest", %{assignment_id: producer.id, kind: "completion"}, nil, {:session, "holder"})

    assert {:error, %{rule: "legacy-review"}} = Dispatch.dispatch(ctx.db, ctx.handlers, input)

    assert {:ok, %{mementos: %{"example/classification" => ["mapped-value"]}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call("memento-set", %{
                 record: "assignment:" <> producer.id,
                 name: "example/classification",
                 values: ["mapped-value"]
               })
             )

    assert Rules.condition_evidence(ctx.db, input, [
             %{fact: "assignment.effect_kind", op: "eq", value: "code"},
             %{
               fact: "assignment.memento.example/classification",
               op: "in",
               value: ["mapped-value"]
             }
           ]).matched

    assert {:error, %{rule: "legacy-review"}} = Dispatch.dispatch(ctx.db, ctx.handlers, input)

    assert {:ok, [["open"]]} =
             DB.query(ctx.db, "SELECT state FROM assignments WHERE id=?1", [producer.id])

    typed =
      call("assign", %{subject: "legacy explicit effect", effect_kind: "coordination"}, "holder")

    before = count(ctx, "assignments")

    assert {:ok, typed_assignment} = Dispatch.dispatch(ctx.db, ctx.handlers, typed)
    assert typed_assignment.effectKind == "coordination"

    assert count(ctx, "assignments") == before + 1
    assert count(ctx, "assignment_effects") == 2
    assert count(ctx, "attests") == 0

    assert Rules.condition_evidence(ctx.db, typed, [
             %{fact: "assign.effect_kind", op: "eq", value: "coordination"}
           ]).matched
  end

  test "legacy inputs remain accepted until replacement admission, then mementos control evidence",
       ctx do
    legacy_producer =
      ctx.handlers["assign"].(
        call("assign", %{subject: "legacy producer", effect_kind: "code"}, "holder")
      )

    assert legacy_producer.effectKind == "code"
    legacy = Rules.effective_snapshot()

    verified =
      call(
        "attest",
        %{assignment_id: legacy_producer.id, kind: "verdict", verdict_kind: "verified"},
        nil,
        {:session, "holder"}
      )

    typed_verified = put_in(verified, [:params, :commit_refs], ctx.commit_refs)
    expected_commit_refs = ctx.commit_refs

    assert %{attest: %{commitRefs: ^expected_commit_refs}} =
             ctx.handlers["attest"].(typed_verified)

    replacement_producer =
      ctx.handlers["assign"].(call("assign", %{subject: "replacement producer"}, "holder"))

    File.write!(Path.join(ctx.base, "identity/rules/replacement.toml"), """
    [[rule]]
    name = "replacement-evidence"
    verb = "attest"
    text = "latest holder evidence must match"
    external_producer = true
    deny_when = [{fact = "attest.kind", op = "eq", value = "completion"}]
    require = [
      {fact = "assignment.latest_holder_verdict.present", op = "eq", value = true},
      {fact = "assignment.latest_holder_verdict.judgment_kind", op = "eq", value = "verified"},
      {fact = "assignment.latest_holder_verdict.memento_matches_call.example/references", op = "eq", value = true}
    ]
    [[admission_contract]]
    verb = "attest"
    classification = "replacement"
    required_rules = ["replacement-evidence"]
    """)

    candidate = Rules.prepare!(ctx.base, Map.keys(ctx.handlers), revision: "replacement-revision")
    assert Rules.active_admission_contract("attest") == "legacy"

    # Isolate host selection here. No production activation/readiness route is
    # exercised by installing this validated snapshot as a fixture.
    selected = %{candidate | active_admission_contract: %{"attest" => "replacement"}}
    :persistent_term.put(Rules, selected)
    on_exit(fn -> :persistent_term.put(Rules, legacy) end)

    replacement_call =
      put_in(typed_verified, [:params, :assignment_id], replacement_producer.id)

    Tightbeam.RuleRuntime.with_policy_snapshot(legacy, fn ->
      assert Rules.active_admission_contract("attest") == "legacy"
      assert :ok = Assignments.legacy_contract(replacement_call)
    end)

    assert Rules.active_admission_contract("attest") == "replacement"
    assert %{code: "legacy_contract_retired"} = ctx.handlers["attest"].(replacement_call)

    replacement_verification =
      replacement_call
      |> update_in([:params], &Map.delete(&1, :commit_refs))
      |> put_in([:params, :mementos], [entry("references", "result")])

    assert %{attest: proof} =
             ctx.handlers["attest"].(replacement_verification)

    assert proof.commitRefs == nil

    completion =
      call(
        "attest",
        %{
          assignment_id: replacement_producer.id,
          kind: "completion",
          mementos: [entry("references", "other")]
        },
        nil,
        {:session, "holder"}
      )

    assert %{code: "rule_denied"} = ctx.handlers["attest"].(completion)

    assert %{assignment: %{state: "closed"}} =
             ctx.handlers["attest"].(
               put_in(completion, [:params, :mementos], [entry("references", "result")])
             )

    assert {:ok, [[nil], [nil]]} =
             DB.query(
               ctx.db,
               "SELECT commitRefs FROM attests WHERE assignmentId=?1 ORDER BY rowid",
               [replacement_producer.id]
             )
  end

  test "comparison input is bounded opaque membership, separate from exact set matching", ctx do
    producer = assign(ctx, "holder")
    review = assign(ctx, "reviewer", producer.id)

    assert %{attest: _} =
             attest(ctx, review.id, "reviewer", "verdict", "reviewed-clean", [
               "candidate",
               "other"
             ])

    assert %{attest: _} =
             attest(ctx, producer.id, "holder", "verdict", "opaque-judgment", [
               "candidate",
               "other"
             ])

    base = call("attest", %{assignment_id: producer.id}) |> Mementos.prepare_call!()
    fact = "assignment.latest_linked_review.memento_contains_comparison_value.example/references"
    assert Tightbeam.MementoFacts.type(fact) == :bool

    assert Tightbeam.MementoFacts.type(
             "assignment.latest_holder_verdict.memento_contains_comparison_value.example/references"
           ) == :bool

    for {operand, expected} <- [
          {nil, false},
          {"", false},
          {"candidate", true},
          {"other", true},
          {"Candidate", false},
          {"missing", false}
        ] do
      input = Mementos.with_comparison!(base, operand)

      for selector <- ["latest_linked_review", "latest_holder_verdict"] do
        assert Rules.condition_evidence(ctx.db, input, [
                 %{
                   fact:
                     "assignment.#{selector}.memento_contains_comparison_value.example/references",
                   op: "eq",
                   value: expected
                 }
               ]).matched
      end

      assert Rules.condition_evidence(ctx.db, input, [
               %{fact: "call.comparison_value", op: "eq", value: operand || ""},
               %{fact: "call.has_comparison_value", op: "eq", value: operand not in [nil, ""]},
               %{fact: "call.memento_names", op: "eq", value: []},
               %{
                 fact: "assignment.latest_linked_review.memento_matches_call.example/references",
                 op: "eq",
                 value: false
               }
             ]).matched

      assert input.memento_writes == []
    end

    missing =
      call("attest", %{assignment_id: assign(ctx, "holder").id})
      |> Mementos.prepare_call!()
      |> Mementos.with_comparison!("candidate")

    assert Rules.condition_evidence(ctx.db, missing, [%{fact: fact, op: "eq", value: false}]).matched

    unresolved = put_in(missing, [:params, :assignment_id], "absent-assignment")

    refute Rules.condition_evidence(ctx.db, unresolved, [%{fact: fact, op: "eq", value: false}]).matched

    assert Mementos.with_comparison!(base, String.duplicate("é", 512)).memento_comparison_value ==
             String.duplicate("é", 512)

    for invalid <- [String.duplicate("x", 1025), <<255>>, 12] do
      assert_raise Mementos.Refusal, fn -> Mementos.with_comparison!(base, invalid) end
    end

    one_member =
      call("attest", %{assignment_id: producer.id, mementos: [entry("references", "candidate")]})
      |> Mementos.prepare_call!()
      |> Mementos.with_comparison!("candidate")

    assert Rules.condition_evidence(ctx.db, one_member, [
             %{fact: fact, op: "eq", value: true},
             %{
               fact: "assignment.latest_linked_review.memento_matches_call.example/references",
               op: "eq",
               value: false
             }
           ]).matched

    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM memento_history")
  end

  test "positive requirements refuse unresolved contexts without changing deny-when conjunction",
       ctx do
    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "required-context"
    verb = "attest"
    text = "a holder judgment must resolve"
    deny_when = [{ fact = "attest.kind", op = "eq", value = "completion" }]
    require = [{ fact = "assignment.latest_holder_verdict.present", op = "eq", value = true }]
    """)

    assert [_] = Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")

    decide = fn kind ->
      input =
        call("attest", %{kind: kind})
        |> Mementos.prepare_call!()
        |> Map.put(:memento_admission, :host)

      DB.transaction(ctx.db, &Rules.decide(&1, input))
    end

    assert {:ok, {{:deny, %{rule: "required-context"}}, [], []}} = decide.("completion")
    assert {:ok, {:allow, [], []}} = decide.("progress")
  end

  test "transactional remedy fires after rollback and closes after the predicate clears", ctx do
    a = assign(ctx, "holder")

    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "outcome-remedy"
    verb = "memento-set"
    text = "resolve the blocked outcome"
    effect = "remedy"
    deny_when = [
      { fact = "call.memento.example/outcome", op = "in", value = ["blocked"] },
      { fact = "assignment.verdicts", op = "not_in", value = ["resolved"] }
    ]
    [rule.remedy]
    action = "wake"
    produces = "resolved"
    target_session = "{holder_key}"
    [rule.remedy.params]
    prompt = "resolve outcome"
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")

    input =
      call(
        "memento-set",
        %{record: "assignment:#{a.id}", name: "outcome", values: ["blocked"]},
        nil,
        {:session, "holder"}
      )

    assert {:error, %{rule: "outcome-remedy", reason: "remedy_fired"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, input)

    assert Mementos.current(ctx.db, "assignment", a.id) == %{}

    assert {:ok, [["live"]]} =
             DB.query(
               ctx.db,
               "SELECT status FROM rail_remedy_episodes WHERE statute='outcome-remedy'"
             )

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE origin='remedy:outcome-remedy'")

    assert {:ok, _} =
             Dispatch.dispatch(ctx.db, ctx.handlers, put_in(input, [:params, :values], ["done"]))

    await_query(
      ctx.db,
      "SELECT status FROM rail_remedy_episodes WHERE statute='outcome-remedy'",
      [["closed"]]
    )

    assert Mementos.current(ctx.db, "assignment", a.id) == %{"example/outcome" => ["done"]}
  end

  defp await_query(db, sql, expected, remaining \\ 100)
  defp await_query(_db, _sql, _expected, 0), do: flunk("committed actor work was not observed")

  defp await_query(db, sql, expected, remaining) do
    if DB.query(db, sql) == {:ok, expected} do
      :ok
    else
      Process.sleep(10)
      await_query(db, sql, expected, remaining - 1)
    end
  end

  test "transactional escalation survives rollback and spends authorization only on commit",
       ctx do
    a = assign(ctx, "holder")

    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "outcome-approval"
    verb = "memento-set"
    text = "approve this outcome"
    effect = "escalate"
    deny_when = [{ fact = "call.has_memento.example/outcome", op = "eq", value = true }]
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")

    input =
      call(
        "memento-set",
        %{record: "assignment:#{a.id}", name: "outcome", values: ["done"]},
        nil,
        {:session, "holder"}
      )

    assert {:decision_pending, request_id} = Dispatch.dispatch(ctx.db, ctx.handlers, input)
    assert Mementos.current(ctx.db, "assignment", a.id) == %{}
    assert %{status: "open"} = Tightbeam.Escalation.raw_by_id(ctx.db, request_id)

    assert %{status: "ruled"} =
             Tightbeam.Escalation.rule(
               ctx.db,
               call("rule", %{request_id: request_id, decision: "allow"}),
               authorized: true
             )

    assert {:error, %RuntimeError{message: "abort host write"}} =
             DB.transaction(ctx.db, fn txn ->
               Mementos.admit_in_txn!(txn, input)
               raise "abort host write"
             end)

    assert %{status: "ruled"} = Tightbeam.Escalation.raw_by_id(ctx.db, request_id)
    assert count(ctx, "memento_history") == 0

    assert {:ok, %{mementos: %{"example/outcome" => ["done"]}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, input)

    assert %{status: "consumed"} = Tightbeam.Escalation.raw_by_id(ctx.db, request_id)
    assert count(ctx, "memento_history") == 1
    assert {:decision_pending, next_id} = Dispatch.dispatch(ctx.db, ctx.handlers, input)
    refute next_id == request_id
    assert count(ctx, "memento_history") == 1
  end

  test "deferred host notice survives commit and an earlier notice survives later refusal", ctx do
    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "classified"
    verb = "assign"
    text = "classification supplied"
    effect = "notice"
    deny_when = [{ fact = "call.has_memento.example/classification", op = "eq", value = true }]
    [rule.notice]
    target_session = "reviewer"
    prompt = "classification observed"
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")

    input =
      call("assign", %{subject: "work", mementos: [entry("classification", "allowed")]}, "holder")

    assert {:ok, %{id: _}} = Dispatch.dispatch(ctx.db, ctx.handlers, input)
    await_notice(ctx, 1)

    File.write!(Path.join(ctx.base, "identity/rules/deny.toml"), """
    [[rule]]
    name = "reject-write"
    verb = "memento-set"
    text = "do not write"
    deny_when = [{ fact = "call.has_memento.example/classification", op = "eq", value = true }]
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")
    before = count(ctx, "assignments")

    assert {:error, %{rule: "reject-write"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, put_in(input, [:params, :subject], "second"))

    assert count(ctx, "assignments") == before
    await_notice(ctx, 2)
    assert count(ctx, "memento_history") == 1
  end

  test "memento write notices stay silent on open records and inline host calls", ctx do
    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "memento-advisory"
    verb = "memento-set"
    text = "metadata changed"
    effect = "notice"
    deny_when = [{ fact = "call.has_memento.example/classification", op = "eq", value = true }]
    [rule.notice]
    target_session = "reviewer"
    prompt = "metadata changed"
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")
    producer = assign(ctx, "holder")
    before = for table <- ~w(wakes messages pending_recognition), do: count(ctx, table)

    assert {:ok, %{mementos: %{"example/classification" => ["open-value"]}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call(
                 "memento-set",
                 %{
                   record: "assignment:#{producer.id}",
                   name: "classification",
                   values: ["open-value"]
                 }
               )
             )

    assert before == for(table <- ~w(wakes messages pending_recognition), do: count(ctx, table))

    ordinary_before = for table <- ~w(wakes messages pending_recognition), do: count(ctx, table)

    assert {:ok, %{id: _ordinary_id}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call("assign", %{subject: "ordinary assignment"}, "holder")
             )

    ordinary_after = for table <- ~w(wakes messages pending_recognition), do: count(ctx, table)

    ordinary_effects =
      Enum.zip(ordinary_after, ordinary_before)
      |> Enum.map(fn {after_count, before_count} -> after_count - before_count end)

    inline_before = ordinary_after

    assert {:ok, %{id: inline_id}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call(
                 "assign",
                 %{
                   subject: "inline memento",
                   mementos: [entry("classification", "inline-value")]
                 },
                 "holder"
               )
             )

    assert Mementos.current(ctx.db, "assignment", inline_id) == %{
             "example/classification" => ["inline-value"]
           }

    inline_after = for table <- ~w(wakes messages pending_recognition), do: count(ctx, table)

    inline_effects =
      Enum.zip(inline_after, inline_before)
      |> Enum.map(fn {after_count, before_count} -> after_count - before_count end)

    assert inline_effects == ordinary_effects
  end

  @tag :file_db
  test "a committed notice replays its admitted rule after policy reload and owner restart",
       ctx do
    rule_path = Path.join(ctx.base, "identity/rules/test.toml")

    File.write!(rule_path, """
    [[rule]]
    name = "classified"
    verb = "assign"
    text = "classification supplied"
    effect = "notice"
    deny_when = [{ fact = "call.has_memento.example/classification", op = "eq", value = true }]
    [rule.notice]
    target_session = "reviewer"
    prompt = "original classification observed"
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "admitted-revision")
    retry = :sys.get_state(ctx.db).retry
    :ok = :sys.suspend(retry)
    on_exit(fn -> if Process.alive?(retry), do: :sys.resume(retry) end)

    input =
      call(
        "assign",
        %{subject: "durable work", mementos: [entry("classification", "allowed")]},
        "holder"
      )

    assert {:ok, %{id: assignment_id}} = Dispatch.dispatch(ctx.db, ctx.handlers, input)
    # Hold the actual worker so the effect is committed but not yet delivered.
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM pending_recognition")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE origin='remedy:classified'")

    File.write!(rule_path, """
    [[rule]]
    name = "classified"
    verb = "assign"
    text = "new classification policy"
    effect = "notice"
    deny_when = [{ fact = "call.has_memento.example/classification", op = "eq", value = true }]
    [rule.notice]
    target_session = "holder"
    prompt = "replacement notice must not replace a committed effect"
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "later-revision")
    stop_supervised!(:memento_file_owner)
    reopened = start_supervised!(ctx.file_owner)
    refute reopened == ctx.db
    :ok = Tightbeam.Schema.ensure_all(reopened)
    :ok = Tightbeam.Recognition.activate(reopened)
    await_notice(%{ctx | db: reopened}, 1)

    assert {:ok, [["reviewer", "original classification observed"]]} =
             DB.query(
               reopened,
               "SELECT sessionKey,prompt FROM wakes WHERE origin='remedy:classified'"
             )

    assert Mementos.current(reopened, "assignment", assignment_id) == %{
             "example/classification" => ["allowed"]
           }

    await_query(reopened, "SELECT count(*) FROM pending_recognition", [[0]], 100)
    assert Rules.effective_snapshot().revision == "later-revision"
  end

  test "durable deferred actor work is removed with a rolled back mutation", ctx do
    parent = self()

    assert {:error, %RuntimeError{}} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.Recognition.defer_in_txn(txn, fn _db ->
                 send(parent, :rolled_back_work)
                 :ok
               end)

               raise "abort"
             end)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.Recognition.defer_in_txn(txn, fn _db ->
                 send(parent, :committed_work)
                 :ok
               end)
             end)

    assert_receive :committed_work, 2_000
    refute_received :rolled_back_work
  end

  defp await_notice(ctx, count, remaining \\ 100)
  defp await_notice(_ctx, _count, 0), do: flunk("committed notice was not delivered")

  defp await_notice(ctx, count, remaining) do
    {:ok, [[actual]]} =
      DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE origin='remedy:classified'")

    if actual == count do
      :ok
    else
      Process.sleep(10)
      await_notice(ctx, count, remaining - 1)
    end
  end

  test "shipped delivery rules require a work item before staffing", ctx do
    install_engineering_policy(ctx, "delivery.toml")

    for verb <- ["assign", "dispatch"] do
      decide = fn kind ->
        input =
          call(
            verb,
            %{
              subject: "work",
              effect_kind: kind,
              mementos: [%{name: "agentic-engineering/effect-kind", value: kind}]
            },
            "holder"
          )

        input = input |> Mementos.prepare_call!() |> Map.put(:memento_admission, :legacy)
        DB.transaction(ctx.db, &Rules.decide(&1, input))
      end

      assert {:ok, {{:deny, %{rule: rule}}, [], []}} = decide.("code")
      assert rule == "engineering-#{verb}-staffing-needs-work-item"
      assert {:ok, {{:deny, %{rule: ^rule}}, [], []}} = decide.("coordination")
    end
  end

  test "shipped fourth fix notice filters the current effect in kungfu", ctx do
    install_engineering_policy(ctx, "ac6a.toml")
    item = ctx.handlers["work-item-create"].(call("work-item-create", %{title: "rounds"}))

    open = fn kind ->
      ctx.handlers["assign"].(
        call(
          "assign",
          %{
            subject: "round",
            work_item_id: item.id,
            effect_kind: kind,
            mementos: [%{name: "agentic-engineering/effect-kind", value: kind}]
          },
          "holder"
        )
      )
    end

    for _ <- 1..3 do
      a = open.("code")
      assert %{assignment: %{state: "closed"}} = attest(ctx, a.id, "holder", "completion")
    end

    assert %{id: _} = open.("coordination")

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wakes WHERE origin='remedy:ac6a-fourth-fix-round'"
             )

    assert %{id: code_id} = open.("code")

    assert {:ok, [[^code_id]]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId FROM wakes WHERE origin='remedy:ac6a-fourth-fix-round'"
             )
  end

  test "the shipped legacy review rule requires an independent clean review", ctx do
    install_engineering_policy(ctx, "engineering.toml")

    for fault <- [
          :none,
          :missing_review,
          :review_no_kind,
          :review_adverse,
          :dependent,
          :unrelated,
          :latest_other_kind
        ] do
      producer = engineering_assignment(ctx)
      review_holder = if fault == :dependent, do: "holder", else: "reviewer"

      review =
        assign(
          ctx,
          review_holder,
          if(fault == :unrelated, do: assign(ctx, "holder").id, else: producer.id)
        )

      refs = ["one", "two"]

      unless fault == :missing_review do
        kind =
          case fault do
            :review_no_kind -> ""
            :review_adverse -> "changes-requested"
            _ -> "reviewed-clean"
          end

        policy_verdict(ctx, review.id, review_holder, kind, [])

        if fault == :latest_other_kind,
          do: policy_verdict(ctx, review.id, review_holder, "progress-judgment", refs)
      end

      input =
        engineering_completion(
          ctx,
          producer.id,
          refs,
          :legacy
        )

      assert {:ok, decision} = DB.transaction(ctx.db, &Rules.decide(&1, input))

      if fault in [:none, :latest_other_kind] do
        assert {:allow, [], []} = decision
      else
        assert {{:remedy, %{name: "completion-requires-review"}, _, _}, [], []} = decision,
               "qualification incorrectly allowed: #{fault}"
      end
    end
  end

  test "promotion policy requires the latest independent judgment and candidate membership",
       ctx do
    install_engineering_policy(ctx, "promotion.toml")

    for fault <- [
          :none,
          :missing,
          :no_kind,
          :adverse,
          :empty,
          :mismatch,
          :dependent,
          :unrelated,
          :latest_adverse,
          :absent_comparison
        ] do
      producer = engineering_assignment(ctx)
      reviewer = if fault == :dependent, do: "holder", else: "reviewer"

      review =
        assign(
          ctx,
          reviewer,
          if(fault == :unrelated, do: assign(ctx, "holder").id, else: producer.id)
        )

      unless fault == :missing do
        kind =
          case fault do
            :no_kind -> ""
            :adverse -> "changes-requested"
            _ -> "reviewed-clean"
          end

        values =
          case fault do
            :empty -> []
            :mismatch -> ["other"]
            _ -> ["other", "candidate"]
          end

        policy_verdict(ctx, review.id, reviewer, kind, values)

        if fault == :latest_adverse,
          do: policy_verdict(ctx, review.id, reviewer, "changes-requested", values)
      end

      input =
        call("harness-health-close-promotion", %{assignment_id: producer.id})
        |> Mementos.prepare_call!()
        |> Mementos.with_comparison!(if(fault == :absent_comparison, do: nil, else: "candidate"))
        |> Map.put(:memento_admission, :host)

      assert {:ok, decision} = DB.transaction(ctx.db, &Rules.decide(&1, input))

      if fault == :none do
        assert {:allow, [], []} = decision
      else
        assert {{:deny, %{rule: "promotion-requires-current-review"}}, [], []} = decision,
               "promotion incorrectly allowed: #{fault}"
      end
    end
  end

  test "shipped holder verification requires the selected kind and matching nonempty evidence",
       ctx do
    install_engineering_policy(ctx, "verification.toml")
    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET archetype='coder' WHERE sessionKey='holder'")

    item =
      ctx.handlers["work-item-create"].(call("work-item-create", %{title: "verification policy"}))

    Artifacts.record(ctx.db, %{
      principal: {:session, "holder"},
      session_key: "holder",
      params: %{
        kind: "report",
        title: "verification results",
        origin_path: "results/verification.txt",
        work_item_id: item.id
      }
    })

    producer = engineering_assignment(ctx, item.id)
    input = engineering_completion(ctx, producer.id, ["expected"], :host)
    decide = fn -> DB.transaction(ctx.db, &Rules.decide(&1, input)) end

    assert {:ok, {{:remedy, %{name: "completion-requires-verification"}, _, _}, [], []}} =
             decide.()

    policy_verdict(ctx, producer.id, "holder", "verified", ["other"])

    assert {:ok, {{:remedy, %{name: "completion-requires-verification"}, _, _}, [], []}} =
             decide.()

    policy_verdict(ctx, producer.id, "holder", "verified", ["expected"])
    assert {:ok, {:allow, [], []}} = decide.()
    policy_verdict(ctx, producer.id, "holder", "changes-requested", ["expected"])

    assert {:ok, {{:remedy, %{name: "completion-requires-verification"}, _, _}, [], []}} =
             decide.()
  end

  test "completion policy refuses unresolved positive requirements while other attests remain allowed",
       ctx do
    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "required-context"
    verb = "attest"
    text = "a holder judgment must resolve"
    deny_when = [{ fact = "attest.kind", op = "eq", value = "completion" }]
    require = [{ fact = "assignment.latest_holder_verdict.present", op = "eq", value = true }]
    """)

    assert [_] = Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")

    decide = fn kind ->
      input =
        call("attest", %{kind: kind})
        |> Mementos.prepare_call!()
        |> Map.put(:memento_admission, :host)

      DB.transaction(ctx.db, &Rules.decide(&1, input))
    end

    assert {:ok, {{:deny, %{rule: "required-context"}}, [], []}} = decide.("completion")
    assert {:ok, {:allow, [], []}} = decide.("progress")
  end

  defp engineering_assignment(ctx, work_item \\ nil) do
    ctx.handlers["assign"].(
      call(
        "assign",
        %{
          subject: "policy fixture",
          work_item_id: work_item,
          effect_kind: "code",
          mementos: [%{name: "agentic-engineering/effect-kind", value: "code"}]
        },
        "holder"
      )
    )
  end

  defp engineering_completion(ctx, id, values, admission) do
    call(
      "attest",
      %{
        assignment_id: id,
        kind: "completion",
        commit_refs: ctx.commit_refs,
        mementos: Enum.map(values, &%{name: "agentic-engineering/evidence-ref", value: &1})
      },
      nil,
      {:session, "holder"}
    )
    |> Mementos.prepare_call!()
    |> Map.put(:memento_admission, admission)
  end

  defp policy_verdict(ctx, assignment, holder, kind, values) do
    id = "att_" <> Tightbeam.Id.uuid4()

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "INSERT INTO attests(id,assignmentId,kind,verdictKind,bySession,commitRefs,ts) VALUES(?1,?2,'verdict',?3,?4,?5,?6)",
                 [
                   id,
                   assignment,
                   kind,
                   holder,
                   JSON.encode!(ctx.commit_refs),
                   System.system_time(:millisecond)
                 ]
               )

               Mementos.append_in_txn!(
                 txn,
                 "attest",
                 id,
                 if(values == [], do: [], else: [{"agentic-engineering/evidence-ref", values}]),
                 {:session, holder},
                 "test-revision"
               )

               :ok
             end)

    id
  end

  defp install_engineering_policy(ctx, filename) do
    bundle = Path.join(ctx.base, "identity/kungfu/agentic-engineering")
    File.mkdir_p!(bundle)
    File.cp!("priv/kungfu/agentic-engineering/manifest.toml", Path.join(bundle, "manifest.toml"))

    source =
      if filename == "promotion.toml",
        do: "test/fixtures/memento_promotion.toml",
        else: Path.join("priv/kungfu/agentic-engineering/rules", filename)

    File.cp!(source, Path.join(ctx.base, "identity/rules/" <> filename))

    previous = Rules.effective_snapshot()

    candidate = Rules.prepare!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")

    active_contract =
      Map.new(candidate.requested_admission_contract, fn {verb, contract} ->
        {verb, contract.classification}
      end)

    :persistent_term.put(Rules, %{candidate | active_admission_contract: active_contract})
    on_exit(fn -> :persistent_term.put(Rules, previous) end)
    assert candidate.rules != []
    candidate.rules
  end

  test "composed policy: transactional remedy fires after rollback and closes after the predicate clears",
       ctx do
    a = assign(ctx, "holder")

    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "outcome-remedy"
    verb = "memento-set"
    text = "resolve the blocked outcome"
    effect = "remedy"
    deny_when = [
      { fact = "call.memento.example/outcome", op = "in", value = ["blocked"] },
      { fact = "assignment.verdicts", op = "not_in", value = ["resolved"] }
    ]
    [rule.remedy]
    action = "wake"
    produces = "resolved"
    target_session = "{holder_key}"
    [rule.remedy.params]
    prompt = "resolve outcome"
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")

    input =
      call(
        "memento-set",
        %{record: "assignment:#{a.id}", name: "outcome", values: ["blocked"]},
        nil,
        {:session, "holder"}
      )

    assert {:error, %{rule: "outcome-remedy", reason: "remedy_fired"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, input)

    assert Mementos.current(ctx.db, "assignment", a.id) == %{}

    assert {:ok, [["live"]]} =
             DB.query(
               ctx.db,
               "SELECT status FROM rail_remedy_episodes WHERE statute='outcome-remedy'"
             )

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE origin='remedy:outcome-remedy'")

    assert {:ok, _} =
             Dispatch.dispatch(ctx.db, ctx.handlers, put_in(input, [:params, :values], ["done"]))

    await_query(
      ctx.db,
      "SELECT status FROM rail_remedy_episodes WHERE statute='outcome-remedy'",
      [["closed"]]
    )

    assert Mementos.current(ctx.db, "assignment", a.id) == %{"example/outcome" => ["done"]}
  end

  test "composed policy: transactional escalation survives rollback and spends authorization only on commit",
       ctx do
    a = assign(ctx, "holder")

    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "outcome-approval"
    verb = "memento-set"
    text = "approve this outcome"
    effect = "escalate"
    deny_when = [{ fact = "call.has_memento.example/outcome", op = "eq", value = true }]
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")

    input =
      call(
        "memento-set",
        %{record: "assignment:#{a.id}", name: "outcome", values: ["done"]},
        nil,
        {:session, "holder"}
      )

    assert {:decision_pending, request_id} = Dispatch.dispatch(ctx.db, ctx.handlers, input)
    assert Mementos.current(ctx.db, "assignment", a.id) == %{}
    assert %{status: "open"} = Tightbeam.Escalation.raw_by_id(ctx.db, request_id)

    assert %{status: "ruled"} =
             Tightbeam.Escalation.rule(
               ctx.db,
               call("rule", %{request_id: request_id, decision: "allow"}),
               authorized: true
             )

    assert {:error, %RuntimeError{message: "abort host write"}} =
             DB.transaction(ctx.db, fn txn ->
               Mementos.admit_in_txn!(txn, input)
               raise "abort host write"
             end)

    assert %{status: "ruled"} = Tightbeam.Escalation.raw_by_id(ctx.db, request_id)
    assert count(ctx, "memento_history") == 0

    assert {:ok, %{mementos: %{"example/outcome" => ["done"]}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, input)

    assert %{status: "consumed"} = Tightbeam.Escalation.raw_by_id(ctx.db, request_id)
    assert count(ctx, "memento_history") == 1
    assert {:decision_pending, next_id} = Dispatch.dispatch(ctx.db, ctx.handlers, input)
    refute next_id == request_id
    assert count(ctx, "memento_history") == 1
  end

  test "composed policy: deferred host notice survives commit and an earlier notice survives later refusal",
       ctx do
    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "classified"
    verb = "assign"
    text = "classification supplied"
    effect = "notice"
    deny_when = [{ fact = "call.has_memento.example/classification", op = "eq", value = true }]
    [rule.notice]
    target_session = "reviewer"
    prompt = "classification observed"
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")

    input =
      call("assign", %{subject: "work", mementos: [entry("classification", "allowed")]}, "holder")

    assert {:ok, %{id: _}} = Dispatch.dispatch(ctx.db, ctx.handlers, input)
    await_notice(ctx, 1)

    File.write!(Path.join(ctx.base, "identity/rules/deny.toml"), """
    [[rule]]
    name = "reject-write"
    verb = "memento-set"
    text = "do not write"
    deny_when = [{ fact = "call.has_memento.example/classification", op = "eq", value = true }]
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")
    before = count(ctx, "assignments")

    assert {:error, %{rule: "reject-write"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, put_in(input, [:params, :subject], "second"))

    assert count(ctx, "assignments") == before
    await_notice(ctx, 2)
    assert count(ctx, "memento_history") == 1
  end

  test "composed policy: durable deferred actor work is removed with a rolled back mutation",
       ctx do
    parent = self()

    assert {:error, %RuntimeError{}} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.Recognition.defer_in_txn(txn, fn _db ->
                 send(parent, :rolled_back_work)
                 :ok
               end)

               raise "abort"
             end)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.Recognition.defer_in_txn(txn, fn _db ->
                 send(parent, :committed_work)
                 :ok
               end)
             end)

    assert_receive :committed_work, 2_000
    refute_received :rolled_back_work
  end

  test "inline creation and per-name rule refusals commit atomically", ctx do
    rule(ctx, "classify", "memento-set", "call.memento.example/classification", "in", [
      "forbidden"
    ])

    before = count(ctx, "assignments")
    assert %{code: "rule_denied", rule: "classify"} = assign(ctx, "holder", nil, "forbidden")
    assert count(ctx, "assignments") == before
    assert count(ctx, "memento_history") == 0
    a = assign(ctx, "holder", nil, "allowed")
    assert a.mementos == %{"example/classification" => ["allowed"]}

    assert %{assignments: rows} =
             ctx.handlers["assignments"].(call("assignments", %{state: "all"}))

    assert Enum.find(rows, &(&1.id == a.id)).mementos == a.mementos
  end

  test "host rules see inline proposals before any assignment or dispatch delivery", ctx do
    rule(ctx, "inline-host", "dispatch", "call.has_memento.example/classification", "eq", false)
    before = for table <- ~w(assignments wakes messages), do: count(ctx, table)
    input = call("dispatch", %{subject: "work", brief: "act"}, "holder")
    assert {:error, %{rule: "inline-host"}} = Dispatch.dispatch(ctx.db, ctx.handlers, input)
    assert before == for(table <- ~w(assignments wakes messages), do: count(ctx, table))
  end

  test "work-item inline values are returned without history", ctx do
    {:ok, item} =
      Dispatch.dispatch(
        ctx.db,
        ctx.handlers,
        call("work-item-create", %{title: "work", mementos: [entry("target", "feature/opaque")]})
      )

    assert item.mementos == %{"example/target" => ["feature/opaque"]}
    detail = ctx.handlers["work-item-get"].(call("work-item-get", %{work_item_id: item.id}))
    assert detail.workItem.mementos == item.mementos
    refute Map.has_key?(detail.workItem, :history)
  end

  test "assignment target facts cannot borrow another holder's context", ctx do
    a = assign(ctx, "holder")
    b = assign(ctx, "reviewer")
    rule(ctx, "holder-only", "memento-set", "assignment.caller_is_holder", "eq", false)

    own =
      call(
        "memento-set",
        %{record: "assignment:#{a.id}", name: "example/outcome", values: ["done"]},
        nil,
        {:session, "holder"}
      )

    other = put_in(own, [:params, :record], "assignment:#{b.id}")

    assert %{mementos: %{"example/outcome" => ["done"]}} =
             Mementos.__handle__(ctx.db, "memento-set", own)

    assert %{rule: "holder-only"} = Mementos.__handle__(ctx.db, "memento-set", other)
    assert Mementos.current(ctx.db, "assignment", b.id) == %{}
  end

  test "serialized writes validate the immediately preceding current value", ctx do
    a = assign(ctx, "holder")
    rule(ctx, "write-once", "memento-set", "assignment.has_memento.example/outcome", "eq", true)

    write = fn value ->
      Mementos.__handle__(
        ctx.db,
        "memento-set",
        call(
          "memento-set",
          %{record: "assignment:#{a.id}", name: "example/outcome", values: [value]}
        )
      )
    end

    tasks = for value <- ["one", "two"], do: Task.async(fn -> write.(value) end)
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &Map.has_key?(&1, :mementos)) == 1
    assert Enum.count(results, &(&1[:rule] == "write-once")) == 1
    assert count(ctx, "memento_history") == 1
  end

  test "closed, iceboxed and failed work-item metadata stays silent under advisory rules", ctx do
    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "target-advisory"
    verb = "memento-set"
    text = "target changed"
    effect = "notice"
    deny_when = [{ fact = "call.has_memento.example/target", op = "eq", value = true }]
    [rule.notice]
    target_session = "reviewer"
    prompt = "target changed"
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")

    for state <- ["closed", "iceboxed", "failed"] do
      item = ctx.handlers["work-item-create"].(call("work-item-create", %{title: "finished"}))
      {:ok, _} = DB.query(ctx.db, "UPDATE work_items SET state=?2 WHERE id=?1", [item.id, state])
      before = for table <- ~w(attests wakes messages pending_recognition), do: count(ctx, table)

      assert {:ok, %{mementos: %{"example/target" => ["feature/result"]}}} =
               Dispatch.dispatch(
                 ctx.db,
                 ctx.handlers,
                 call("memento-set", %{
                   record: "work_item:#{item.id}",
                   name: "target",
                   values: ["feature/result"]
                 })
               )

      assert before ==
               for(table <- ~w(attests wakes messages pending_recognition), do: count(ctx, table))

      assert {:ok, [[^state]]} =
               DB.query(ctx.db, "SELECT state FROM work_items WHERE id=?1", [item.id])
    end
  end

  test "closed assignment metadata is silent and attest metadata is immutable", ctx do
    a = assign(ctx, "holder")
    result = attest(ctx, a.id, "holder", "completion")
    assert %{attest: %{kind: "completion"}, assignment: %{state: "closed"}} = result
    before = for table <- ~w(attests wakes messages), do: count(ctx, table)

    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "metadata-advisory"
    verb = "memento-set"
    text = "metadata changed"
    effect = "notice"
    deny_when = [{ fact = "call.has_memento.example/outcome", op = "eq", value = true }]
    [rule.notice]
    target_session = "reviewer"
    prompt = "metadata changed"
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")

    updated =
      Mementos.__handle__(
        ctx.db,
        "memento-set",
        call(
          "memento-set",
          %{record: "assignment:#{a.id}", name: "example/outcome", values: ["PR 12, merged"]}
        )
      )

    assert updated.mementos["example/outcome"] == ["PR 12, merged"]
    assert before == for(table <- ~w(attests wakes messages), do: count(ctx, table))
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM pending_recognition")

    assert {:ok, [["closed", "completed"]]} =
             DB.query(ctx.db, "SELECT state,outcome FROM assignments WHERE id=?1", [a.id])

    assert %{code: "memento_record_immutable"} =
             Mementos.__handle__(
               ctx.db,
               "memento-set",
               call("memento-set", %{
                 record: "attest:#{result.attest.id}",
                 name: "example/references",
                 values: ["x"]
               })
             )
  end

  test "selectors choose the newest eligible structural verdict and keep all facts on that row",
       ctx do
    producer = assign(ctx, "holder")
    review = assign(ctx, "reviewer", producer.id)
    clean = attest(ctx, review.id, "reviewer", "verdict", "reviewed-clean", ["a", "b"])

    assert %{id: id, independent: true} =
             MementoJudgments.latest(ctx.db, producer.id, "linked_review")

    assert id == clean.attest.id
    adverse = attest(ctx, review.id, "reviewer", "verdict", "changes-requested", ["b", "a"])
    _ineligible = attest(ctx, review.id, "holder", "verdict", "reviewed-clean", ["a", "b"])
    selected = MementoJudgments.latest(ctx.db, producer.id, "linked_review")
    assert selected.id == adverse.attest.id
    assert selected.judgment_kind == "changes-requested"
    proposed = [{"example/references", ["a", "b"]}]

    assert Tightbeam.MementoFacts.judgment_value(
             ctx.db,
             selected,
             "memento_matches_call.example/references",
             proposed
           )

    refute Tightbeam.MementoFacts.judgment_value(
             ctx.db,
             selected,
             "memento_matches_call.example/references",
             []
           )

    assert MementoJudgments.latest(ctx.db, producer.id, "holder") == nil
    own = attest(ctx, producer.id, "holder", "verdict", "checked", ["a"])
    assert MementoJudgments.latest(ctx.db, producer.id, "holder").id == own.attest.id
    assert MementoJudgments.latest(ctx.db, producer.id, "linked_review").id == adverse.attest.id

    assert Enum.find(Assignments.list_attests(ctx.db, review.id), &(&1.id == clean.attest.id)).mementos ==
             %{"example/references" => ["a", "b"]}
  end

  test "absent and cleared facts differ from unresolved contexts", ctx do
    a = assign(ctx, "holder")
    condition = [%{fact: "assignment.has_memento.example/outcome", op: "eq", value: false}]

    assert Rules.condition_evidence(ctx.db, call("attest", %{assignment_id: a.id}), condition).matched

    refute Rules.condition_evidence(
             ctx.db,
             call("attest", %{assignment_id: "missing"}),
             condition
           ).matched

    assert Tightbeam.MementoFacts.type("assignment.memento.example/target") == nil

    assert Tightbeam.MementoFacts.type(
             "assignment.latest_linked_review.memento.example/references"
           ) == {:list, :string}

    assert Tightbeam.MementoFacts.type("assignment.latest_holder_verdict.independent") == nil
  end

  test "latest selectors span review cards, include dependent judgments and break timestamp ties",
       ctx do
    producer = assign(ctx, "holder")
    independent = assign(ctx, "reviewer", producer.id)
    dependent = assign(ctx, "holder", producer.id)
    unrelated = assign(ctx, "reviewer")

    for {id, assignment, author, kind} <- [
          {"first", independent.id, "reviewer", "reviewed-clean"},
          {"later", dependent.id, "holder", "changes-requested"},
          {"unrelated", unrelated.id, "reviewer", "reviewed-clean"},
          {"non-holder", independent.id, "holder", "reviewed-clean"}
        ] do
      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 """
                 INSERT INTO attests(id,assignmentId,kind,verdictKind,note,bySession,ts)
                 VALUES (?1,?2,'verdict',?3,'fixture',?4,1234)
                 """,
                 [id, assignment, kind, author]
               )
    end

    assert %{id: "later", independent: false, judgment_kind: "changes-requested"} =
             MementoJudgments.latest(ctx.db, producer.id, "linked_review")

    assert MementoJudgments.latest(ctx.db, producer.id, "holder") == nil

    {:ok, plan} =
      DB.query(
        ctx.db,
        """
        EXPLAIN QUERY PLAN SELECT attestId FROM memento_judgments
        WHERE assignmentId=?1 AND selector='linked_review'
        ORDER BY ts DESC,attestRow DESC LIMIT 1
        """,
        [producer.id]
      )

    assert Enum.any?(plan, &String.contains?(List.last(&1), "SEARCH"))
    refute Enum.any?(plan, &String.contains?(List.last(&1), "SCAN"))
  end

  test "removal retains legacy bytes and supports distinct successor review and holder routes",
       ctx do
    refs = [%{"repo" => "historical:/repository", "commit" => String.duplicate("a", 40)}]
    open = assign(ctx, "holder")

    legacy_call =
      call(
        "attest",
        %{assignment_id: open.id, kind: "verdict", verdict_kind: "verified", commit_refs: refs},
        nil,
        {:session, "holder"}
      )

    assert %{code: "unverifiable_commit_ref"} = ctx.handlers["attest"].(legacy_call)
    assert count(ctx, "attests") == 0
    # Seed immutable predecessor data; removal must read it without reinterpretation.
    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO attests(id,assignmentId,kind,verdictKind,note,bySession,commitRefs,ts)
               VALUES ('legacy-verification',?1,'verdict','verified','legacy','holder',?2,1)
               """,
               [open.id, JSON.encode!(refs)]
             )

    legacy =
      Enum.find(Assignments.list_attests(ctx.db, open.id), &(&1.id == "legacy-verification"))

    assert legacy.commitRefs == refs
    assert legacy.mementos == %{}
    before = DB.query(ctx.db, "SELECT * FROM attests WHERE id=?1", [legacy.id])
    proposed = [{"example/references", ["opaque-reference"]}]
    selected = MementoJudgments.latest(ctx.db, open.id, "holder")

    refute Tightbeam.MementoFacts.judgment_value(
             ctx.db,
             selected,
             "memento_matches_call.example/references",
             proposed
           )

    fresh_call =
      legacy_call
      |> put_in([:params, :commit_refs], ctx.commit_refs)
      |> put_in([:params, :mementos], [entry("references", "opaque-reference")])

    assert %{attest: fresh} = ctx.handlers["attest"].(fresh_call)
    assert fresh.mementos == %{"example/references" => ["opaque-reference"]}
    assert MementoJudgments.latest(ctx.db, open.id, "holder").id == fresh.id
    assert MementoJudgments.latest(ctx.db, open.id, "linked_review") == nil
    assert DB.query(ctx.db, "SELECT * FROM attests WHERE id=?1", [legacy.id]) == before

    closed = assign(ctx, "holder")
    assert %{assignment: %{state: "closed"}} = attest(ctx, closed.id, "holder", "completion")
    successor = assign(ctx, "reviewer", closed.id)
    assert %{id: _} = successor

    assert %{attest: review} =
             attest(ctx, successor.id, "reviewer", "verdict", "reviewed-clean", [
               "opaque-reference"
             ])

    assert MementoJudgments.latest(ctx.db, closed.id, "linked_review").id == review.id
    assert MementoJudgments.latest(ctx.db, closed.id, "holder") == nil

    assert {:ok, [["closed"]]} =
             DB.query(ctx.db, "SELECT state FROM assignments WHERE id=?1", [closed.id])
  end

  test "declaration-aware fact typing rejects wrong operators and unknown names", ctx do
    for {fact, op, value} <- [
          {"assignment.memento.example/outcome", "eq", []},
          {"assignment.latest_linked_review.memento.example/unknown", "in", ["x"]},
          {"assignment.has_memento.example/target", "eq", true}
        ] do
      File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
      [[rule]]
      name = "invalid-fact"
      verb = "attest"
      text = "fixture"
      deny_when = [{ fact = "#{fact}", op = "#{op}", value = #{JSON.encode!(value)} }]
      """)

      assert [] = Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")
      assert {:deny, %{code: "rule_unavailable"}} = Rules.evaluate(ctx.db, call("attest", %{}))
    end
  end

  test "composed policy: comparison input is bounded opaque membership, separate from exact set matching",
       ctx do
    producer = assign(ctx, "holder")
    review = assign(ctx, "reviewer", producer.id)

    assert %{attest: _} =
             attest(ctx, review.id, "reviewer", "verdict", "reviewed-clean", [
               "candidate",
               "other"
             ])

    assert %{attest: _} =
             attest(ctx, producer.id, "holder", "verdict", "verified", ["candidate", "other"])

    base = call("attest", %{assignment_id: producer.id}) |> Mementos.prepare_call!()
    fact = "assignment.latest_linked_review.memento_contains_comparison_value.example/references"
    assert Tightbeam.MementoFacts.type(fact) == :bool

    assert Tightbeam.MementoFacts.type(
             "assignment.latest_holder_verdict.memento_contains_comparison_value.example/references"
           ) == :bool

    for {operand, expected} <- [
          {nil, false},
          {"", false},
          {"candidate", true},
          {"other", true},
          {"Candidate", false},
          {"missing", false}
        ] do
      input = Mementos.with_comparison!(base, operand)

      for selector <- ["latest_linked_review", "latest_holder_verdict"] do
        assert Rules.condition_evidence(ctx.db, input, [
                 %{
                   fact:
                     "assignment.#{selector}.memento_contains_comparison_value.example/references",
                   op: "eq",
                   value: expected
                 }
               ]).matched
      end

      assert Rules.condition_evidence(ctx.db, input, [
               %{fact: "call.comparison_value", op: "eq", value: operand || ""},
               %{fact: "call.has_comparison_value", op: "eq", value: operand not in [nil, ""]},
               %{fact: "call.memento_names", op: "eq", value: []},
               %{
                 fact: "assignment.latest_linked_review.memento_matches_call.example/references",
                 op: "eq",
                 value: false
               }
             ]).matched

      assert input.memento_writes == []
    end

    missing =
      call("attest", %{assignment_id: assign(ctx, "holder").id})
      |> Mementos.prepare_call!()
      |> Mementos.with_comparison!("candidate")

    assert Rules.condition_evidence(ctx.db, missing, [%{fact: fact, op: "eq", value: false}]).matched

    unresolved = put_in(missing, [:params, :assignment_id], "absent-assignment")

    refute Rules.condition_evidence(ctx.db, unresolved, [%{fact: fact, op: "eq", value: false}]).matched

    assert Mementos.with_comparison!(base, String.duplicate("é", 512)).memento_comparison_value ==
             String.duplicate("é", 512)

    for invalid <- [String.duplicate("x", 1025), <<255>>, 12] do
      assert_raise Mementos.Refusal, fn -> Mementos.with_comparison!(base, invalid) end
    end

    one_member =
      call("attest", %{assignment_id: producer.id, mementos: [entry("references", "candidate")]})
      |> Mementos.prepare_call!()
      |> Mementos.with_comparison!("candidate")

    assert Rules.condition_evidence(ctx.db, one_member, [
             %{fact: fact, op: "eq", value: true},
             %{
               fact: "assignment.latest_linked_review.memento_matches_call.example/references",
               op: "eq",
               value: false
             }
           ]).matched

    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM memento_history")
  end

  test "one fact evaluation reuses each selected judgment and current payload", ctx do
    producer = assign(ctx, "holder")
    review = assign(ctx, "reviewer", producer.id)

    assert %{attest: selected} =
             attest(ctx, review.id, "reviewer", "verdict", "reviewed-clean", ["a", "b"])

    input =
      call("attest", %{
        assignment_id: producer.id,
        mementos: [entry("references", "b"), entry("references", "a")]
      })
      |> Mementos.prepare_call!()
      |> Mementos.with_comparison!("a")

    prefix = "assignment.latest_linked_review."

    conditions = [
      %{fact: prefix <> "present", op: "eq", value: true},
      %{fact: prefix <> "independent", op: "eq", value: true},
      %{fact: prefix <> "judgment_kind", op: "eq", value: "reviewed-clean"},
      %{fact: prefix <> "has_memento.example/references", op: "eq", value: true},
      %{fact: prefix <> "memento.example/references", op: "in", value: ["a"]},
      %{fact: prefix <> "memento_matches_call.example/references", op: "eq", value: true},
      %{
        fact: prefix <> "memento_contains_comparison_value.example/references",
        op: "eq",
        value: true
      }
    ]

    observer = self()

    assert {:ok, %{matched: true}} =
             DB.transaction(ctx.db, fn txn ->
               Rules.condition_evidence(
                 Tightbeam.DB.Txn.observe_queries(txn, observer),
                 input,
                 conditions
               )
             end)

    queries = collect_queries([])

    assert Enum.count(queries, fn {sql, _} -> String.contains?(sql, "FROM memento_judgments") end) ==
             1

    assert Enum.filter(queries, fn {sql, _} -> String.contains?(sql, "FROM memento_current") end)
           |> Enum.map(&elem(&1, 1)) == [["attest", selected.id, "example/references"]]

    refute Enum.any?(queries, fn {sql, _} -> String.contains?(sql, "memento_history") end)
  end

  test "replacement admission retires legacy fields before writes but legacy mode keeps them",
       ctx do
    a = assign(ctx, "holder")
    assert a.effectKind == "code"
    assert count(ctx, "assignment_effects") == 1

    legacy_inputs = [
      call("assign", %{subject: "legacy", effect_kind: "code"}, "holder"),
      call("dispatch", %{subject: "legacy", brief: "act", effect_kind: "code"}, "holder"),
      call(
        "attest",
        %{assignment_id: a.id, kind: "progress", commit_refs: nil},
        nil,
        {:session, "holder"}
      ),
      call("assignment-commitref-correct", %{assignment_id: a.id})
    ]

    assert Enum.all?(legacy_inputs, &(Assignments.legacy_contract(&1) == :ok))

    assert {:ok, %{effectKind: "coordination"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call("assign", %{subject: "legacy effect", effect_kind: "coordination"}, "holder")
             )

    legacy = Rules.effective_snapshot()

    replacements =
      Map.new(~w(assign dispatch attest assignment-commitref-correct), &{&1, "replacement"})

    replacement_rules =
      Enum.map(replacements, fn {verb, _classification} ->
        %{
          name: "fixture-replacement-#{verb}",
          verb: verb,
          edges: [],
          identity_manifest_sha: legacy.revision
        }
      end)

    requested =
      Map.new(replacements, fn {verb, _classification} ->
        {verb,
         %{
           classification: "replacement",
           required_rules: ["fixture-replacement-#{verb}"]
         }}
      end)

    selected = %{
      legacy
      | active_admission_contract: replacements,
        requested_admission_contract: requested,
        rules: legacy.rules ++ replacement_rules
    }

    :persistent_term.put(Rules, selected)
    on_exit(fn -> :persistent_term.put(Rules, legacy) end)

    before =
      for table <-
            ~w(assignments attests wakes messages memento_history assignment_effects assignment_commit_ref_corrections),
          do: count(ctx, table)

    for input <- legacy_inputs do
      assert {:error, %{code: "legacy_contract_retired"}} =
               Dispatch.dispatch(ctx.db, ctx.handlers, input)

      assert before ==
               for(
                 table <-
                   ~w(assignments attests wakes messages memento_history assignment_effects assignment_commit_ref_corrections),
                 do: count(ctx, table)
               )
    end

    assert {:ok, replacement_assignment} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call(
                 "assign",
                 %{subject: "replacement effect", mementos: [entry("classification", "code")]},
                 "holder"
               )
             )

    assert replacement_assignment.effectKind == nil
    assert replacement_assignment.mementos["example/classification"] == ["code"]

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignment_effects WHERE assignmentId=?1", [
               replacement_assignment.id
             ])
  end

  test "qualified historical names remain readable after their bundle is unlearned", ctx do
    a = assign(ctx, "holder", nil, "opaque")
    File.rm!(Path.join(ctx.base, "identity/kungfu/example/manifest.toml"))
    Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "without-bundle")

    assert %{history: [%{name: "example/classification", values: ["opaque"]}]} =
             Mementos.__handle__(
               ctx.db,
               "mementos",
               call("mementos", %{
                 record: "assignment:#{a.id}",
                 history: true,
                 name: "example/classification"
               })
             )

    assert %{code: "unknown_memento"} =
             Mementos.__handle__(
               ctx.db,
               "memento-set",
               call("memento-set", %{
                 record: "assignment:#{a.id}",
                 name: "example/classification",
                 values: ["replacement"]
               })
             )
  end

  defp collect_queries(acc) do
    receive do
      {:core_detail_trace, {:sql_query, sql, params}} -> collect_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp rule(ctx, name, verb, fact, op, value) do
    File.write!(Path.join(ctx.base, "identity/rules/test.toml"), """
    [[rule]]
    name = "#{name}"
    verb = "#{verb}"
    text = "fixture refusal"
    deny_when = [{ fact = "#{fact}", op = "#{op}", value = #{JSON.encode!(value)} }]
    """)

    assert [_] = Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: "test-revision")
  end

  defp assign(ctx, holder, reviews \\ nil, classification \\ nil) do
    params = %{subject: "work", reviews_assignment_id: reviews}

    legacy_effect_kind =
      cond do
        reviews ->
          "review"

        classification in ~w(code policy release live_mutation evidence review coordination) ->
          classification

        true ->
          "code"
      end

    params =
      if classification,
        do: Map.put(params, :mementos, [entry("classification", classification)]),
        else: params

    if Rules.active_admission_contract("assign") == "legacy" do
      Map.put(params, :effect_kind, legacy_effect_kind)
    else
      params
    end
    |> then(&ctx.handlers["assign"].(call("assign", &1, holder)))
  end

  defp attest(ctx, assignment, holder, kind, judgment \\ nil, evidence \\ []) do
    params = %{
      assignment_id: assignment,
      kind: kind,
      verdict_kind: judgment,
      mementos: Enum.map(evidence, &entry("references", &1))
    }

    params =
      if kind == "verdict" and judgment in ["verified", "reviewed-clean"],
        do: Map.put(params, :commit_refs, ctx.commit_refs),
        else: params

    ctx.handlers["attest"].(call("attest", params, nil, {:session, holder}))
  end

  defp entry(name, value), do: %{"name" => "example/" <> name, "value" => value}

  defp count(ctx, table) do
    {:ok, [[n]]} = DB.query(ctx.db, "SELECT count(*) FROM #{table}")
    n
  end

  defp call(verb, params, target \\ nil, principal \\ {:user, "owner"}) do
    {kind, id} = principal

    %{
      verb: verb,
      params: params,
      principal: principal,
      origin: if(kind == :user, do: "user:#{id}", else: "agent:#{id}"),
      session_key: target,
      target_role: nil,
      role_fallback: false
    }
  end
end
