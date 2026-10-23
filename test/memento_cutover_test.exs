defmodule Tightbeam.MementoCutoverTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Gateway, MementoCutover, Mementos, Model, Org, Placement, Rules}
  alias Tightbeam.DB.Txn

  setup do
    base = Path.join(System.tmp_dir!(), "cutover-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "identity/rules"))
    File.mkdir_p!(Path.join(base, "identity/kungfu/example"))

    File.write!(Path.join(base, "identity/kungfu/example/manifest.toml"), """
    [[mementos]]
    name = "effect"
    records = ["assignment"]
    """)

    File.write!(Path.join(base, "identity/rules/selectors.toml"), """
    [[rule]]
    name = "effects"
    verb = "post"
    text = "select an assignment population"
    deny_when = [{fact = "assignment.state", op = "eq", value = "open"}]
    [[rule]]
    name = "judgments"
    verb = "post"
    text = "select a legacy judgment population"
    deny_when = [{fact = "attest.kind", op = "eq", value = "verdict"}]
    [[rule]]
    name = "successor"
    verb = "post"
    text = "inspect the selected successor"
    deny_when = [{fact = "assignment.latest_linked_review.present", op = "eq", value = true}]
    """)

    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, path: Path.join(base, "identity/rules/cutover.toml")}
  end

  test "legacy snapshots need no cutover declaration and staging does not activate it", ctx do
    before = Rules.effective_snapshot()
    assert Rules.prepare!(ctx.base, ["post"], revision: "legacy").memento_cutover == nil
    File.write!(ctx.path, declaration())
    candidate = Rules.prepare!(ctx.base, ["post"], revision: "candidate")
    assert candidate.active_admission_contract == %{}
    assert candidate.memento_cutover.identity_revision == "candidate"

    assert candidate.memento_cutover.effects == %{
             selector: "effects",
             mapping: [%{legacy_value: "old", name: "example/effect", value: "opaque"}]
           }

    assert candidate.memento_cutover.judgments == [
             %{selector: "judgments", route: "linked_review", successor_rule: "successor"}
           ]

    assert Rules.effective_snapshot() == before

    File.write!(ctx.path, String.replace(declaration(), "opaque", "changed"))
    changed = Rules.prepare!(ctx.base, ["post"], revision: "new-candidate")
    assert changed.memento_cutover.identity_revision == "new-candidate"
    assert hd(changed.memento_cutover.effects.mapping).value == "changed"
    assert hd(candidate.memento_cutover.effects.mapping).value == "opaque"
    assert Rules.effective_snapshot() == before
  end

  test "malformed, ambiguous and unresolved declaration inputs refuse without active mutation",
       ctx do
    before = Rules.effective_snapshot()
    original = declaration()

    for bytes <- [
          String.replace(original, "version = 1", "version = 2"),
          String.replace(original, "version = 1", "version = 1.0"),
          String.replace(original, "version = 1", "version = 1\nready = true"),
          String.replace(original, ~s(selector = "effects"), ~s(selector = "unknown")),
          String.replace(original, "example/effect", "example/unknown"),
          String.replace(original, ~s(route = "linked_review"), ~s(route = "other")),
          String.replace(original, ~s(route = "linked_review"), ~s(route = "none")),
          String.replace(
            original,
            ~s(successor_rule = "successor"),
            ~s(successor_rule = "missing")
          ),
          String.replace(original, ~s(value = "opaque"), ~s(value = "")),
          String.replace(
            original,
            "judgments = [",
            "judgments = [{selector = \"judgments\", route = \"none\"}, "
          ),
          String.replace(
            original,
            "mapping = [",
            "mapping = [{legacy_value = \"old\", name = \"example/effect\", value = \"other\"}, "
          )
        ] do
      File.write!(ctx.path, bytes)

      error =
        assert_raise Mementos.Refusal, fn ->
          Rules.prepare!(ctx.base, ["post"], revision: "candidate")
        end

      assert error.code == "policy_revision_unavailable"
      assert Rules.effective_snapshot() == before
    end
  end

  test "duplicate declarations across files and unavailable selector rules refuse", ctx do
    File.write!(ctx.path, declaration())
    other = Path.join(ctx.base, "identity/rules/duplicate.toml")
    File.write!(other, declaration())

    assert_raise Mementos.Refusal, ~r/duplicate memento_cutover/, fn ->
      Rules.prepare!(ctx.base, ["post"], revision: "candidate")
    end

    File.rm!(other)
    selector_path = Path.join(ctx.base, "identity/rules/selectors.toml")

    File.write!(
      selector_path,
      File.read!(selector_path) |> String.replace("assignment.state", "missing.fact")
    )

    assert_raise Mementos.Refusal, ~r/selector rule/, fn ->
      Rules.prepare!(ctx.base, ["post"], revision: "candidate")
    end
  end

  test "loaded policy assessment rejects retired facts across the whole rule and policy set",
       ctx do
    File.write!(
      ctx.path,
      declaration() <>
        """

        [[admission_contract]]
        verb = "post"
        classification = "replacement"
        required_rules = ["effects"]
        """
    )

    candidate = prepare(ctx)
    before = Rules.effective_snapshot()
    assert %{rules: rules, policies: []} = MementoCutover.policy_inventory!(candidate)
    assert Enum.map(rules, & &1.name) == ["effects", "judgments", "successor"]

    replacement_rule = Enum.find(candidate.rules, &(&1.verb == "post"))
    assert replacement_rule

    for fact <- ~w(assign.effect_kind assignment.effect_kind
                    assignment.qualifying_review_verdict_kinds
                    assignment.qualifying_verification_verdict_kinds) do
      rule = %{replacement_rule | required: [%{fact: fact, op: "eq", value: "old"}]}

      assert_raise Mementos.Refusal, ~r/retired fact/, fn ->
        MementoCutover.policy_inventory!(%{candidate | rules: [rule]})
      end
    end

    policy = %{
      name: "policy-table",
      identity_manifest_sha: candidate.revision,
      conditions: [%{fact: "assignment.effect_kind", op: "eq", value: "old"}]
    }

    assert_raise Mementos.Refusal, ~r/policy-table.*retired fact/, fn ->
      MementoCutover.policy_inventory!(%{candidate | policies: [policy]})
    end

    wrong = %{hd(candidate.rules) | identity_manifest_sha: "other"}

    assert_raise Mementos.Refusal, ~r/different identity revision/, fn ->
      MementoCutover.policy_inventory!(%{candidate | rules: [wrong]})
    end

    for invalid <- [
          %{candidate | unavailable_verbs: %{"post" => "bad.toml"}},
          %{candidate | declarations: %{candidate.declarations | revision: "other"}}
        ] do
      assert_raise Mementos.Refusal, fn -> MementoCutover.policy_inventory!(invalid) end
    end

    assert Rules.effective_snapshot() == before
  end

  test "cutover predicates inspect the census without acting on ordinary calls", ctx do
    ctx = census_fixture(ctx)
    selectors = Path.join(ctx.base, "identity/rules/selectors.toml")

    File.write!(
      selectors,
      File.read!(selectors)
      |> String.replace(~s(verb = "post"), ~s(verb = "post"\nedges = ["cutover"]))
    )

    ctx = %{ctx | candidate: prepare(ctx)}
    Rules.install_legacy!(ctx.candidate)
    opened = historical_assignment(ctx, "cutover-only population")
    put_effect(ctx, opened.id, "opaque")

    call = %{
      verb: "post",
      origin: "user:owner",
      principal: {:user, "owner"},
      params: %{assignment_id: opened.id}
    }

    for edge <- [:verb, :turn_end, :row_commit, :cutover] do
      assert {:allow, [], []} = Rules.decide(ctx.db, Map.put(call, :edge, edge))
    end

    assert {:ok, checked} = census(ctx)
    assert checked.assignment_count == 1
    assert checked.selected_effect_count == 1
    assert hd(checked.effects).id == opened.id
    assert hd(checked.effects).head.values == ["opaque"]

    assert {:ok, [["open"]]} =
             DB.query(ctx.db, "SELECT state FROM assignments WHERE id=?1", [opened.id])

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM memento_history")
  end

  test "cutover predicates cannot provide replacement admission coverage", ctx do
    selectors = Path.join(ctx.base, "identity/rules/selectors.toml")

    File.write!(selectors, """
    [[rule]]
    name = "only-cutover"
    verb = "post"
    edges = ["cutover"]
    text = "Inspect a population, not an admission gate"
    deny_when = [{fact = "caller.origin_class", op = "eq", value = "user"}]
    """)

    before = Rules.effective_snapshot()
    candidate = prepare(ctx)

    requested = %{"post" => %{classification: "replacement", required_rules: ["only-cutover"]}}

    selected = %{
      candidate
      | requested_admission_contract: requested,
        active_admission_contract: %{"post" => "replacement"}
    }

    assert_raise Mementos.Refusal, ~r/incomplete/, fn ->
      Tightbeam.RuleRuntime.with_policy_snapshot(selected, fn ->
        Rules.active_admission_contract("post")
      end)
    end

    File.write!(ctx.path, """
    [[admission_contract]]
    verb = "post"
    classification = "replacement"
    required_rules = ["only-cutover"]
    """)

    assert_raise Mementos.Refusal, ~r/incomplete replacement/, fn -> prepare(ctx) end
    assert Rules.effective_snapshot() == before
  end

  test "cutover-only predicates reject actor effects, scripts and mixed edges", ctx do
    path = Path.join(ctx.base, "identity/rules/bad.toml")
    script = Path.join(ctx.base, "identity/rails/scripts/never-run")
    File.mkdir_p!(Path.dirname(script))
    File.write!(script, "#!/bin/sh\nexit 1\n")
    File.chmod!(script, 0o755)
    before = Rules.effective_snapshot()

    for extra <- [
          ~s(edges = ["cutover", "verb"]),
          ~s(edges = ["cutover"]\neffect = "escalate"),
          ~s(edges = ["cutover"]\neffect = "notice"\nnotice = {target_role = "owner", prompt = "do not emit"}),
          ~s(edges = ["cutover"]\nremedy = {action = "assign", target_role = "owner", params = {subject = "do not assign"}}),
          """
          edges = ["cutover"]
          [rule.check]
          script = "never-run"
          returns = ["pass"]
          effects = {pass = "allow"}
          """
        ] do
      File.write!(path, """
      [[rule]]
      name = "bad"
      verb = "post"
      text = "invalid cutover predicate"
      deny_when = [{fact = "caller.origin_class", op = "eq", value = "user"}]
      #{extra}
      """)

      candidate = prepare(ctx)
      assert Map.has_key?(candidate.unavailable_verbs, "post")
      refute Enum.any?(candidate.rules, &(&1.name == "bad"))
      assert Rules.effective_snapshot() == before
    end
  end

  test "cutover predicates neither require producers nor block ordinary remedy admission", ctx do
    path = Path.join(ctx.base, "identity/rules/separate.toml")

    contents = """
    [[rule]]
    name = "inspect-kind"
    verb = "post"
    edges = ["cutover"]
    text = "Inspect a selected kind without opening work"
    require = [{fact = "assignment.latest_holder_verdict.judgment_kind", op = "eq", value = "accepted"}]

    [[rule]]
    name = "ordinary-gate"
    verb = "post"
    text = "An ordinary admission gate retains its producer"
    deny_when = [{fact = "assignment.verdicts", op = "not_in", value = ["accepted"]}]
    effect = "remedy"
    [rule.remedy]
    action = "assign"
    target_role = "owner"
    produces = "accepted"
    params = {subject = "supply judgment"}

    [[rule]]
    name = "inspect-origin"
    verb = "assign"
    edges = ["cutover"]
    text = "Inspect source origin without blocking a remedy"
    deny_when = [{fact = "caller.origin_class", op = "eq", value = "remedy"}]
    """

    File.write!(path, contents)
    candidate = Rules.prepare!(ctx.base, ["post", "assign"], revision: "candidate")
    assert candidate.unavailable_verbs == %{}
    assert Enum.any?(candidate.rules, &(&1.name == "inspect-kind"))
    assert Enum.any?(candidate.rules, &(&1.name == "ordinary-gate"))

    # The same predicates on ordinary edges keep both existing producer checks.
    File.write!(path, String.replace(contents, ~s(edges = ["cutover"]), ~s(edges = ["verb"])))
    ordinary = Rules.prepare!(ctx.base, ["post", "assign"], revision: "ordinary")
    assert Map.has_key?(ordinary.unavailable_verbs, "post")
    refute Enum.any?(ordinary.rules, &(&1.name in ["inspect-kind", "ordinary-gate"]))
  end

  test "census enumerates open and closed source records without changing active policy", ctx do
    ctx = census_fixture(ctx)
    first = historical_assignment(ctx, "first")
    second = historical_assignment(ctx, "second")
    put_effect(ctx, first.id, "opaque")

    assert %{state: "closed"} =
             ctx.handlers["revoke-assignment"].(%{
               verb: "revoke-assignment",
               params: %{assignment_id: second.id, reason: "closed census fixture"},
               principal: {:user, "owner"},
               origin: "user:owner",
               session_key: nil,
               target_role: nil,
               role_fallback: false
             })

    active = Rules.effective_snapshot()
    assert {:ok, census} = census(ctx)
    assert census.phase == :census
    assert census.assignment_count == 2
    assert census.selected_effect_count == 1
    assert census.judgment_count == 0
    assert census.successors_checked == true
    assert census.identity_revision == "candidate"
    refute census.inventory_reconciled
    assert Enum.map(census.effects, & &1.id) |> Enum.sort() == Enum.sort([first.id, second.id])
    assert Enum.find(census.effects, &(&1.id == first.id)).head.values == ["opaque"]
    refute Enum.find(census.effects, &(&1.id == second.id)).selected
    assert Rules.effective_snapshot() == active
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM memento_history")

    DB.query(ctx.db, "UPDATE assignments SET subject='changed' WHERE id=?1", [second.id])
    assert {:ok, changed} = census(ctx)

    refute Enum.find(changed.effects, &(&1.id == second.id)).source_revision ==
             Enum.find(census.effects, &(&1.id == second.id)).source_revision
  end

  test "an unprepared authoritative assignment blocks the entire census", ctx do
    ctx = census_fixture(ctx)
    first = historical_assignment(ctx, "prepared")
    second = historical_assignment(ctx, "omitted")
    put_effect(ctx, first.id, "opaque")
    assert {:error, error} = census(ctx)
    assert error.code == "policy_revision_unavailable"
    assert error.message =~ second.id
    assert error.message =~ "missing or stale current memento head"
    put_effect(ctx, second.id, "wrong")
    assert {:error, error} = census(ctx)
    assert error.message =~ second.id
    assert error.message =~ "value mismatch"
    put_effect(ctx, second.id, "opaque")
    assert {:ok, %{assignment_count: 2, selected_effect_count: 2}} = census(ctx)

    DB.query(
      ctx.db,
      "UPDATE assignment_effects SET effectKind='evidence' WHERE assignmentId=?1",
      [second.id]
    )

    assert {:error, error} = census(ctx)
    assert error.message =~ second.id
    assert error.message =~ "missing or ambiguous effect mapping"
  end

  test "an older matching current head is stale even when its value matches", ctx do
    ctx = census_fixture(ctx)
    assignment = historical_assignment(ctx, "head")
    put_effect(ctx, assignment.id, "opaque")

    assert {:ok, [[old]]} =
             DB.query(ctx.db, "SELECT historyId FROM memento_current WHERE recordId=?1", [
               assignment.id
             ])

    put_effect(ctx, assignment.id, "opaque")

    DB.query(ctx.db, "UPDATE memento_current SET historyId=?1 WHERE recordId=?2", [
      old,
      assignment.id
    ])

    assert {:error, error} = census(ctx)
    assert error.message =~ assignment.id
    assert error.message =~ "stale current memento head"
  end

  test "every judgment resolves to exactly one route, including empty legacy evidence", ctx do
    ctx = census_fixture(ctx)
    assignment = historical_assignment(ctx, "judgments")
    put_effect(ctx, assignment.id, "opaque")

    for {id, refs} <- [{"legacy-one", "[]"}, {"legacy-two", nil}] do
      DB.query(
        ctx.db,
        "INSERT INTO attests(id,assignmentId,kind,verdictKind,bySession,commitRefs,ts) VALUES (?1,?2,'verdict','verified','holder',?3,1)",
        [id, assignment.id, refs]
      )
    end

    assert {:ok, census} = census(ctx)
    assert census.judgment_count == 2
    assert Enum.map(census.judgments, & &1.id) == ["legacy-one", "legacy-two"]
    assert Enum.all?(census.judgments, &(&1.route == "none"))
    assert census.successors_checked == true

    selector_path = Path.join(ctx.base, "identity/rules/selectors.toml")
    original = File.read!(selector_path)

    File.write!(
      selector_path,
      String.replace(original, ~s(value = "verdict"), ~s(value = "progress"))
    )

    assert {:error, error} = census(%{ctx | candidate: prepare(ctx)})
    assert error.message =~ "legacy-one"
    assert error.message =~ "no cutover selector matched"

    duplicate =
      original
      |> String.split("[[rule]]")
      |> Enum.at(2)
      |> String.replace(~s(name = "judgments"), ~s(name = "duplicate"))

    File.write!(selector_path, original <> "\n[[rule]]\n" <> duplicate)
    bytes = File.read!(ctx.path)

    File.write!(
      ctx.path,
      String.replace(
        bytes,
        "judgments = [",
        ~s(judgments = [{selector = "duplicate", route = "none"}, )
      )
    )

    assert {:error, error} = census(%{ctx | candidate: prepare(ctx)})
    assert error.message =~ "legacy-one"
    assert error.message =~ "ambiguous cutover selector outcomes"
  end

  test "missing declarations and unresolved selector facts refuse without notices", ctx do
    ctx = census_fixture(ctx)
    assignment = historical_assignment(ctx, "unresolved")
    put_effect(ctx, assignment.id, "opaque")

    assert {:error, error} =
             census(%{ctx | candidate: Map.put(ctx.candidate, :memento_cutover, nil)})

    assert error.message =~ "requires the candidate"
    path = Path.join(ctx.base, "identity/rules/selectors.toml")
    File.write!(path, String.replace(File.read!(path), "assignment.state", "work_item.state"))
    assert {:error, error} = census(%{ctx | candidate: prepare(ctx)})
    assert error.message =~ assignment.id
    assert error.message =~ "unresolved cutover selector"
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM attests")
  end

  test "independent successor on a new review satisfies a closed producer without rewriting history",
       ctx do
    ctx = successor_fixture(ctx, "linked_review")
    producer = historical_assignment(ctx, "producer")
    review = create_review(ctx, producer.id, "reviewer")
    file_judgment(ctx, "old", review.id, "reviewer", "reviewed-clean", [])
    ctx = require_evidence(ctx, review.id, "old")
    close_assignment(ctx, review.id)
    close_assignment(ctx, producer.id)
    assert {:ok, legacy_before} = DB.query(ctx.db, "SELECT * FROM attests WHERE id='old'")
    assert {:error, error} = census(ctx)
    assert error.message =~ "old"
    assert error.message =~ "fresh holder judgment"
    successor = create_review(ctx, producer.id, "reviewer")
    file_judgment(ctx, "successor", successor.id, "reviewer", "reviewed-clean", ["opaque-ref"])
    assert {:ok, result} = census(ctx)
    checked = Enum.find(result.judgments, &(&1.id == "old")).successor
    assert checked.id == "successor"
    assert checked.assignment_id == successor.id
    assert checked.producer_id == producer.id
    assert checked.selector == "linked_review"
    assert checked.independent
    assert checked.evidence["example/references"].values == ["opaque-ref"]
    assert result.successors_checked
    assert {:ok, ^legacy_before} = DB.query(ctx.db, "SELECT * FROM attests WHERE id='old'")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM memento_history WHERE recordId='old'")

    assert {:ok, [["closed"]]} =
             DB.query(ctx.db, "SELECT state FROM assignments WHERE id=?1", [producer.id])
  end

  test "holder verification requires the same open producer and cannot use a linked review",
       ctx do
    ctx = successor_fixture(ctx, "holder_verification")
    producer = historical_assignment(ctx, "producer")
    put_effect(ctx, producer.id, "opaque")
    file_judgment(ctx, "old", producer.id, "holder", "verified", [])
    ctx = require_evidence(ctx, producer.id, "old")
    review = create_review(ctx, producer.id, "reviewer")
    file_judgment(ctx, "review", review.id, "reviewer", "reviewed-clean", ["opaque-ref"])
    assert {:error, error} = census(ctx)
    assert error.message =~ "old"
    assert error.message =~ "fresh holder judgment"
    file_judgment(ctx, "verified", producer.id, "holder", "verified", ["opaque-ref"])
    assert {:ok, result} = census(ctx)
    checked = Enum.find(result.judgments, &(&1.id == "old")).successor
    assert checked.id == "verified"
    assert checked.assignment_id == producer.id
    assert checked.selector == "holder"
    close_assignment(ctx, producer.id)
    assert {:error, error} = census(ctx)
    assert error.message =~ "old"
    assert error.message =~ "same open producer"
  end

  test "latest adverse, dependent, empty and nonmatching review judgments block", ctx do
    for {label, holder, kind, values, message} <- [
          {"adverse", "reviewer", "changes-requested", ["opaque-ref"], "not satisfied"},
          {"dependent", "holder", "reviewed-clean", ["opaque-ref"],
           "not an independent linked review"},
          {"empty", "reviewer", "reviewed-clean", [], "not satisfied"},
          {"nonmatching", "reviewer", "reviewed-clean", ["other"], "not satisfied"}
        ] do
      ctx = successor_fixture(ctx, "linked_review", label)
      producer = historical_assignment(ctx, label)
      put_effect(ctx, producer.id, "opaque")
      old_review = create_review(ctx, producer.id, "reviewer")
      file_judgment(ctx, "ancestor", old_review.id, "reviewer", "reviewed-clean", [])
      ctx = require_evidence(ctx, old_review.id, "ancestor")
      good_review = create_review(ctx, producer.id, "reviewer")
      file_judgment(ctx, "good", good_review.id, "reviewer", "reviewed-clean", ["opaque-ref"])
      assert {:ok, _} = census(ctx)
      latest = create_review(ctx, producer.id, holder)
      file_judgment(ctx, "latest", latest.id, holder, kind, values)
      assert {:error, error} = census(ctx)
      assert error.message =~ "ancestor"
      assert error.message =~ message
    end
  end

  test "successor policy must apply and check the selected kind and nonempty evidence matcher",
       ctx do
    ctx = successor_fixture(ctx, "linked_review")
    producer = historical_assignment(ctx, "producer")
    put_effect(ctx, producer.id, "opaque")
    review = create_review(ctx, producer.id, "reviewer")
    file_judgment(ctx, "old", review.id, "reviewer", "reviewed-clean", [])
    ctx = require_evidence(ctx, review.id, "old")
    file_judgment(ctx, "successor", review.id, "reviewer", "reviewed-clean", ["opaque-ref"])
    path = Path.join(ctx.base, "identity/rules/selectors.toml")
    original = File.read!(path)

    for {bytes, message} <- [
          {String.replace(original, ~s(value = ["open", "closed"]), ~s(value = ["closed"])),
           "not satisfied"},
          {String.replace(
             original,
             ~s(fact = "assignment.latest_linked_review.judgment_kind", op = "eq", value = "reviewed-clean"),
             ~s(fact = "assignment.latest_linked_review.has_judgment_kind", op = "eq", value = true)
           ), "must check the selected linked_review kind"},
          {String.replace(
             original,
             ~s(fact = "assignment.latest_linked_review.memento_matches_cutover_requirement.example/references", op = "eq", value = true),
             ~s(fact = "assignment.latest_linked_review.has_memento.example/references", op = "eq", value = true)
           ), "no evidence matcher"},
          {String.replace(
             original,
             ~s(fact = "assignment.latest_linked_review.memento_matches_cutover_requirement.example/references", op = "eq", value = true),
             ~s(fact = "assignment.latest_linked_review.memento_matches_call.example/references", op = "eq", value = true)
           ), "not satisfied"},
          {String.replace(
             original,
             ~s(fact = "assignment.latest_linked_review.memento_matches_cutover_requirement.example/references", op = "eq", value = true),
             ~s(fact = "assignment.latest_linked_review.memento_matches_call.example/references", op = "eq", value = false)
           ), "no evidence matcher"}
        ] do
      bytes =
        if message == "must check the selected linked_review kind",
          do: String.replace(bytes, "external_producer = true", ""),
          else: bytes

      File.write!(path, bytes)
      assert {:error, error} = census(%{ctx | candidate: prepare(ctx)})
      assert error.message =~ "old"
      assert error.message =~ message
    end
  end

  test "a review for another producer cannot satisfy the selected successor route", ctx do
    ctx = successor_fixture(ctx, "linked_review")
    producer = historical_assignment(ctx, "producer")
    other = historical_assignment(ctx, "other producer")
    for id <- [producer.id, other.id], do: put_effect(ctx, id, "opaque")
    file_judgment(ctx, "ancestor", producer.id, "holder", "verified", [])
    ctx = require_evidence(ctx, producer.id, "ancestor")
    review = create_review(ctx, other.id, "reviewer")
    file_judgment(ctx, "review", review.id, "reviewer", "reviewed-clean", ["opaque-ref"])
    assert {:error, error} = census(ctx)
    assert error.message =~ "ancestor"
    assert error.message =~ "missing linked_review successor"
  end

  test "cutover requirements are independent source-bound sets, not successor or call values",
       ctx do
    ctx = successor_fixture(ctx, "linked_review")
    producer = historical_assignment(ctx, "producer")
    put_effect(ctx, producer.id, "opaque")
    review = create_review(ctx, producer.id, "reviewer")
    file_judgment(ctx, "old", review.id, "reviewer", "reviewed-clean", [])

    file_judgment(ctx, "successor", review.id, "reviewer", "reviewed-clean", [
      "second",
      "opaque-ref"
    ])

    assert {:error, missing} = census(ctx)
    assert missing.message =~ "old: missing evidence requirement"
    ctx = require_evidence(ctx, review.id, "old", ["opaque-ref", "second"])
    assert {:ok, checked} = census(ctx)
    old = Enum.find(checked.judgments, &(&1.id == "old"))
    assert old.requirement.values == ["opaque-ref", "second"]
    assert old.successor.evidence["example/references"].values == ["second", "opaque-ref"]
    # A call field cannot stand in for the census's independent operand,
    # even when every other positive requirement holds.
    call = %{
      verb: "post",
      params: %{assignment_id: producer.id},
      principal: {:user, "owner"},
      origin: "user:owner",
      memento_cutover_requirement: old.requirement
    }

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.RuleRuntime.with_policy_snapshot(ctx.candidate, fn ->
                 assert_raise ArgumentError, ~r/not satisfied/, fn ->
                   Rules.cutover_successor_in_txn!(txn, "successor", call)
                 end

                 :ok
               end)
             end)

    assert {:ok, _} = census(ctx)
    selector_path = Path.join(ctx.base, "identity/rules/selectors.toml")
    selector_bytes = File.read!(selector_path)

    File.write!(
      selector_path,
      String.replace(selector_bytes, ~s(edges = ["cutover"]), ~s(edges = ["verb"]))
    )

    assert_raise Mementos.Refusal, ~r/selector rule/, fn -> prepare(ctx) end
    File.write!(selector_path, selector_bytes)
    original = File.read!(ctx.path)

    for {bytes, message} <- [
          {String.replace(
             original,
             ~s(values = ["opaque-ref","second"]),
             ~s(values = ["opaque-ref"])
           ), "not satisfied"},
          {String.replace(
             original,
             ~s(values = ["opaque-ref","second"]),
             ~s(values = ["opaque-ref","second","extra"])
           ), "not satisfied"},
          {String.replace(original, ~s(attest_id = "old"), ~s(attest_id = "unknown")),
           "missing evidence requirement"},
          {String.replace(
             original,
             ~s(assignment_id = "#{review.id}"),
             ~s(assignment_id = "#{producer.id}")
           ), "missing evidence requirement"},
          {String.replace(
             original,
             ~s(route = "independent-review"),
             ~s(route = "open-producer-holder-verification")
           ), "wrong-route"},
          {String.replace(
             original,
             ~s(entries = [),
             ~s(entries = [{assignment_id = "unknown", attest_id = "extra", route = "independent-review", name = "example/references", values = ["x"]}, )
           ), "extra or wrong-source"},
          {String.replace(
             original,
             ~s(entries = [),
             ~s(entries = [{assignment_id = "#{review.id}", attest_id = "successor", route = "independent-review", name = "example/references", values = ["x"]}, )
           ), "no-successor route"}
        ] do
      File.write!(ctx.path, bytes)
      assert {:error, error} = census(%{ctx | candidate: prepare(ctx)})
      assert error.message =~ message
    end

    for bytes <- [
          String.replace(original, ~s(values = ["opaque-ref","second"]), ~s(values = [])),
          String.replace(original, ~s(values = ["opaque-ref","second"]), ~s(values = ["x","x"])),
          String.replace(original, ~s(name = "example/references"), ~s(name = "example/effect")),
          String.replace(original, ~s(name = "example/references"), ~s(name = "example/missing")),
          String.replace(
            original,
            ~s(entries = [),
            ~s(entries = [{assignment_id = "#{review.id}", attest_id = "old", route = "independent-review", name = "example/references", values = ["x"]}, )
          ),
          String.replace(
            original,
            ~s(values = ["opaque-ref","second"]),
            "values = [" <> JSON.encode!(String.duplicate("x", 1025)) <> "]"
          )
        ] do
      File.write!(ctx.path, bytes)
      assert_raise Mementos.Refusal, fn -> prepare(ctx) end
    end
  end

  test "optional complete inventories reconcile exact all and selected populations", ctx do
    ctx = census_fixture(ctx)
    first = historical_assignment(ctx, "prepared")
    closed = historical_assignment(ctx, "closed")
    put_effect(ctx, first.id, "opaque")
    close_assignment(ctx, closed.id)
    assert {:ok, observed} = census(ctx)
    refute observed.inventory_reconciled
    before = Rules.effective_snapshot()

    for scope <- ["all", "selected"] do
      inventory = inventory(observed, scope)
      assert {:ok, checked} = census(ctx, inventory)
      assert checked.inventory_reconciled
      assert checked.assignment_count == 2
      assert checked.selected_effect_count == 1
      assert checked.effects == observed.effects
      assert checked.judgments == observed.judgments
      assert Rules.effective_snapshot() == before
    end

    # A real source row outside the selected population is still an extra.
    selected = inventory(observed, "selected")
    all = inventory(observed, "all")

    supplied =
      put_in(selected, ["assignments", "rows"], all["assignments"]["rows"])
      |> put_in(["assignments", "count"], 2)

    assert {:error, error} = census(ctx, supplied)
    assert error.message =~ closed.id
    assert error.message =~ "extra row in selected inventory"
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM memento_history")
  end

  test "inventories cannot omit, add, duplicate or override selected assignment state", ctx do
    ctx = census_fixture(ctx)
    assignment = historical_assignment(ctx, "prepared")
    put_effect(ctx, assignment.id, "opaque")
    assert {:ok, observed} = census(ctx)
    inventory = inventory(observed, "all")
    [row] = inventory["assignments"]["rows"]

    for {rows, message} <- [
          {[], "omitted"},
          {[row, Map.put(row, "id", "extra-assignment")], "extra row"},
          {[row, row], "duplicate"},
          {[Map.put(row, "legacy_value", "other")], "stale or mismatched"},
          {[Map.put(row, "selected", false)], "stale or mismatched"},
          {[Map.put(row, "ready", true)], "stale or mismatched"}
        ] do
      supplied =
        put_in(inventory, ["assignments"], %{
          "scope" => "all",
          "count" => length(rows),
          "rows" => rows
        })

      assert {:error, error} = census(ctx, supplied)
      assert error.code == "policy_revision_unavailable"
      assert error.message =~ message

      assert error.message =~
               if(message == "extra row", do: "extra-assignment", else: assignment.id)
    end

    # Omitting an unprepared row cannot prevent the runtime from finding it.
    omitted = historical_assignment(ctx, "unprepared")
    assert {:error, error} = census(ctx, inventory)
    assert error.message =~ omitted.id
    assert error.message =~ "missing or stale current memento head"
  end

  test "fresh source and same-value head changes invalidate old inventory rows", ctx do
    ctx = census_fixture(ctx)
    assignment = historical_assignment(ctx, "prepared")
    put_effect(ctx, assignment.id, "opaque")
    assert {:ok, before} = census(ctx)

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE assignments SET subject='changed' WHERE id=?1", [
               assignment.id
             ])

    assert {:error, error} = census(ctx, inventory(before, "all"))
    assert error.message =~ assignment.id
    assert error.message =~ "stale or mismatched"

    assert {:ok, new_source} = census(ctx)
    put_effect(ctx, assignment.id, "opaque")
    assert {:ok, new_head} = census(ctx)
    # The source fingerprint alone is not a claim about the mapped head.
    assert hd(new_source.effects).source_revision == hd(new_head.effects).source_revision
    refute hd(new_source.effects).head == hd(new_head.effects).head
    assert {:error, error} = census(ctx, inventory(new_source, "selected"))
    assert error.message =~ assignment.id
    assert error.message =~ "stale or mismatched"
  end

  test "judgment inventories reconcile selected successors and reject stale checked rows", ctx do
    ctx = successor_fixture(ctx, "linked_review")
    producer = historical_assignment(ctx, "producer")
    put_effect(ctx, producer.id, "opaque")
    review = create_review(ctx, producer.id, "reviewer")
    file_judgment(ctx, "ancestor", review.id, "reviewer", "reviewed-clean", [])
    ctx = require_evidence(ctx, review.id, "ancestor")
    file_judgment(ctx, "successor", review.id, "reviewer", "reviewed-clean", ["opaque-ref"])
    assert {:ok, observed} = census(ctx)
    all = inventory(observed, "all")
    selected = inventory(observed, "selected")
    assert all["judgments"]["count"] == 2
    assert selected["judgments"]["count"] == 1
    assert {:ok, _} = census(ctx, all)
    assert {:ok, _} = census(ctx, selected)

    for {rows, message} <- [
          {[], "omitted"},
          {selected["judgments"]["rows"] ++ selected["judgments"]["rows"], "duplicate"},
          {Enum.map(selected["judgments"]["rows"], &Map.put(&1, "route", "none")),
           "stale or mismatched"},
          {Enum.map(selected["judgments"]["rows"], &put_in(&1, ["successor", "id"], "other")),
           "stale or mismatched"}
        ] do
      supplied =
        put_in(selected, ["judgments"], %{
          "scope" => "selected",
          "count" => length(rows),
          "rows" => rows
        })

      assert {:error, error} = census(ctx, supplied)
      assert error.message =~ "ancestor"
      assert error.message =~ message
    end

    file_judgment(ctx, "new-successor", review.id, "reviewer", "reviewed-clean", ["opaque-ref"])
    assert {:ok, current} = census(ctx)
    assert current.judgment_count == 3
    # Selected-set equality alone cannot hide a changed successor.
    assert {:error, error} = census(ctx, selected)
    assert error.message =~ "ancestor"
    assert error.message =~ "stale or mismatched"
  end

  test "inventory authority, count, shape and scope are validated without ready flags", ctx do
    ctx = census_fixture(ctx)
    assert {:ok, observed} = census(ctx)
    original = inventory(observed, "all")

    for inventory <- [
          Map.put(original, "identity_revision", "stale"),
          Map.put(original, "version", 1.0),
          Map.put(original, "ready", true),
          Map.delete(original, "judgments"),
          put_in(original, ["assignments", "count"], 1),
          put_in(original, ["assignments", "scope"], "partial"),
          put_in(original, ["assignments", "rows"], [%{"id" => ""}])
          |> put_in(["assignments", "count"], 1)
        ] do
      assert {:error, error} = census(ctx, inventory)
      assert error.code == "policy_revision_unavailable"
    end
  end

  defp inventory(census, scope) do
    effects =
      if scope == "all", do: census.effects, else: Enum.filter(census.effects, & &1.selected)

    judgments =
      if scope == "all",
        do: census.judgments,
        else: Enum.reject(census.judgments, &(&1.route == "none"))

    %{
      version: 1,
      identity_revision: census.identity_revision,
      assignments: %{scope: scope, count: length(effects), rows: effects},
      judgments: %{scope: scope, count: length(judgments), rows: judgments}
    }
    |> JSON.encode!()
    |> JSON.decode!()
  end

  test "shipped cutover policy declares metadata while its admission remains legacy",
       ctx do
    ctx = shipped_fixture(ctx)
    names = ctx.candidate.declarations.names

    assert Map.keys(names) |> Enum.sort() ==
             ~w(agentic-engineering/effect-kind agentic-engineering/evidence-ref agentic-engineering/integration-target agentic-engineering/landing-outcome)

    assert names["agentic-engineering/evidence-ref"].many
    assert names["agentic-engineering/integration-target"].records == ["work_item"]
    assert names["agentic-engineering/landing-outcome"].records == ["assignment"]
    assert Rules.active_admission_contract("attest") == "legacy"
    assert Rules.active_admission_contract("assign") == "legacy"

    producer = historical_assignment(ctx, "legacy typed assignment")
    assert producer.effectKind == "code"
    put_shipped_effect(ctx, producer.id, "code")

    call = %{
      verb: "attest",
      params: %{assignment_id: producer.id, kind: "completion"},
      principal: {:session, "holder"}
    }

    assert Rules.condition_evidence(ctx.db, call, [
             %{fact: "assignment.effect_kind", op: "eq", value: "code"}
           ]).matched

    assert Rules.condition_evidence(ctx.db, call, [
             %{fact: "assignment.effect_kind", op: "eq", value: "code"},
             %{
               fact: "assignment.memento.agentic-engineering/effect-kind",
               op: "in",
               value: ["code"]
             }
           ]).matched

    assert Enum.any?(ctx.candidate.rules, &(&1.name == "completion-requires-review"))

    assert Rules.condition_evidence(ctx.db, call, [
             %{
               fact: "assignment.memento.agentic-engineering/effect-kind",
               op: "in",
               value: ["code"]
             }
           ]).matched

    assert %{rules: [_ | _]} = MementoCutover.policy_inventory!(ctx.candidate)
    assert ctx.candidate.requested_admission_contract == %{}

    assert {:ok, result} = census(ctx)
    assert result.phase == :census
    assert result.effects |> Enum.map(& &1.id) == [producer.id]
    assert Rules.active_admission_contract("attest") == "legacy"
  end

  test "an explicit test replacement policy composes with census without activating", ctx do
    ctx = shipped_fixture(ctx)
    add_test_replacement_policies!(ctx)
    active = Rules.effective_snapshot()
    producer = historical_assignment(ctx, "prepared producer")
    put_shipped_effect(ctx, producer.id, "code")

    revision = commit_candidate(ctx.base)
    law = Gateway.prepare_law!(%{base_dir: ctx.base}, revision, Map.keys(ctx.handlers))
    candidate = law.policy

    assert candidate.memento_cutover.identity_revision == candidate.revision
    assert candidate.memento_cutover.legacy_evidence_requirements.entries == []

    assert Map.keys(candidate.declarations.names) |> Enum.sort() ==
             Map.keys(active.declarations.names) |> Enum.sort()

    assert candidate.active_admission_contract["attest"] == "legacy"
    assert candidate.requested_admission_contract["attest"].classification == "replacement"

    assert candidate.requested_admission_contract["harness-health-close-promotion"].classification ==
             "replacement"

    inventory = MementoCutover.policy_inventory!(candidate)
    assert Enum.any?(inventory.rules, &(&1.name == "memento-completion-requires-current-review"))
    assert Enum.any?(inventory.rules, &(&1.name == "promotion-requires-current-review"))
    assert Enum.any?(inventory.rules, &(&1.name == "engineering-cutover-effects"))
    assert {:ok, census} = census(%{ctx | candidate: candidate})
    assert Enum.map(census.effects, & &1.id) == [producer.id]
    assert census.successors_checked
    assert Rules.effective_snapshot() == active

    loaded = Rules.load!(ctx.base, Map.keys(ctx.handlers), revision: candidate.revision)
    assert Enum.any?(loaded, &(&1.name == "memento-completion-requires-current-review"))
    assert Rules.effective_snapshot().revision == candidate.revision

    assert Rules.effective_snapshot().requested_admission_contract["attest"].classification ==
             "replacement"

    assert Rules.active_admission_contract("attest") == "legacy"

    File.rm!(Path.join(ctx.base, "identity/rules/promotion.toml"))
    restaged = Gateway.prepare_law!(%{base_dir: ctx.base}, revision, Map.keys(ctx.handlers))
    assert restaged.revision == revision
    assert restaged.policy.memento_cutover == candidate.memento_cutover
    assert restaged.policy.requested_admission_contract == candidate.requested_admission_contract

    assert Enum.map(restaged.policy.rules, &Map.delete(&1, :source)) ==
             Enum.map(candidate.rules, &Map.delete(&1, :source))

    assert restaged.policy.law_components == candidate.law_components

    File.rm!(Path.join(ctx.base, "identity/rules/memento-admission-test.toml"))

    legacy_candidate =
      Rules.prepare!(ctx.base, Map.keys(ctx.handlers), revision: "incomplete-candidate")

    assert legacy_candidate.requested_admission_contract == %{}

    assert Map.drop(legacy_candidate.memento_cutover, [:identity_revision]) ==
             Map.drop(candidate.memento_cutover, [:identity_revision])

    assert legacy_candidate.memento_cutover.identity_revision == legacy_candidate.revision
    assert candidate.memento_cutover.identity_revision == candidate.revision
    assert Rules.active_admission_contract("attest") == "legacy"

    assert Rules.effective_snapshot().revision == candidate.revision
    assert Rules.active_admission_contract("attest") == "legacy"
  end

  test "an explicit test replacement requires matching verification and review", ctx do
    ctx = shipped_fixture(ctx)
    add_test_replacement_policies!(ctx)
    producer = historical_assignment(ctx, "producer with opaque evidence")
    review = create_review(ctx, producer.id, "reviewer")
    put_shipped_effect(ctx, producer.id, "code")
    put_shipped_effect(ctx, review.id, "review")
    legacy = Rules.effective_snapshot()

    candidate =
      Rules.prepare!(ctx.base, Map.keys(ctx.handlers), revision: "replacement-candidate")

    # This fixture isolates host admission with the validated candidate. It does
    # not exercise or authorize a production readiness/activation transition.
    selected = %{
      candidate
      | active_admission_contract: %{
          "attest" => "replacement",
          "harness-health-close-promotion" => "replacement"
        }
    }

    :persistent_term.put(Rules, selected)
    on_exit(fn -> :persistent_term.put(Rules, legacy) end)

    attest = fn assignment, principal, kind, verdict, values ->
      Tightbeam.Dispatch.dispatch(ctx.db, ctx.handlers, %{
        verb: "attest",
        params: %{
          assignment_id: assignment,
          kind: kind,
          verdict_kind: verdict,
          mementos:
            Enum.map(values, &%{"name" => "agentic-engineering/evidence-ref", "value" => &1})
        },
        principal: {:session, principal},
        origin: "session:" <> principal,
        session_key: nil,
        target_role: nil,
        role_fallback: false
      })
    end

    assert {:ok, %{attest: verified}} =
             attest.(producer.id, "holder", "verdict", "verified", ["result-A", "result-B"])

    assert verified.commitRefs == nil

    assert {:ok, %{attest: clean}} =
             attest.(review.id, "reviewer", "verdict", "reviewed-clean", ["result-B", "result-A"])

    assert clean.commitRefs == nil

    assert {:error, %{rule: "memento-completion-requires-current-review"}} =
             attest.(producer.id, "holder", "completion", nil, ["different"])

    assert {:ok, %{attest: _}} =
             attest.(review.id, "reviewer", "verdict", "changes-requested", [
               "result-A",
               "result-B"
             ])

    assert {:error, %{rule: "memento-completion-requires-current-review"}} =
             attest.(producer.id, "holder", "completion", nil, ["result-A", "result-B"])

    assert {:ok, %{attest: _}} =
             attest.(review.id, "reviewer", "verdict", "reviewed-clean", ["result-A", "result-B"])

    assert {:ok, %{assignment: %{state: "closed"}}} =
             attest.(producer.id, "holder", "completion", nil, ["result-A", "result-B"])

    Tightbeam.RuleRuntime.with_policy_snapshot(legacy, fn ->
      assert Rules.active_admission_contract("attest") == "legacy"
    end)
  end

  test "shipped mapping covers every legacy effect and preserves closed assignment metadata",
       ctx do
    ctx = shipped_fixture(ctx)

    producers =
      for kind <- ~w(code policy release live_mutation evidence review coordination) do
        producer = historical_assignment(ctx, kind, kind)

        put_shipped_effect(ctx, producer.id, kind)
        producer
      end

    close_assignment(ctx, hd(producers).id)
    assert {:ok, result} = census(ctx)
    assert length(result.effects) == 7
    assert Enum.all?(result.effects, & &1.selected)

    assert Enum.map(result.effects, & &1.legacy_value) |> Enum.sort() ==
             ~w(code coordination evidence live_mutation policy release review)

    put_shipped_effect(ctx, hd(producers).id, "different")
    assert {:error, %Mementos.Refusal{message: message}} = census(ctx)
    assert message =~ hd(producers).id
  end

  test "shipped selectors partition source judgments without becoming operational gates", ctx do
    ctx = shipped_fixture(ctx)
    producer = historical_assignment(ctx, "open producer")
    review = create_review(ctx, producer.id, "reviewer")
    closed = historical_assignment(ctx, "closed producer")
    close_assignment(ctx, closed.id)
    routes = ctx.candidate.memento_cutover.judgments

    assert Enum.all?(
             ctx.candidate.rules
             |> Enum.filter(&String.starts_with?(&1.name, "engineering-cutover-")),
             &(&1.edges == ["cutover"])
           )

    for {assignment, author, kind, values, expected} <- [
          {producer, "holder", "verified", ["prepared"], "none"},
          {producer, "reviewer", "verified", [], "none"},
          {producer, "holder", "posture-light", [], "none"},
          {review, "reviewer", "reviewed-clean", [], "linked_review"},
          {review, "reviewer", "changes-requested", [], "linked_review"},
          {producer, "holder", "reviewed-clean", [], "none"},
          {review, "reviewer", "verified", [], "none"},
          {closed, "holder", "verified", [], "none"},
          {producer, "holder", "verified", [], "holder_verification"}
        ] do
      call = %{
        verb: "attest",
        params: %{assignment_id: assignment.id, kind: "verdict", verdict_kind: kind},
        principal: {:session, author},
        session_key: author,
        memento_writes: [{"agentic-engineering/evidence-ref", values}]
      }

      assert {:ok, [^expected]} =
               DB.transaction(ctx.db, fn txn ->
                 Tightbeam.RuleRuntime.with_policy_snapshot(ctx.candidate, fn ->
                   routes
                   |> Enum.filter(&Rules.cutover_selector_in_txn!(txn, &1.selector, call))
                   |> Enum.map(& &1.route)
                 end)
               end)
    end
  end

  test "composed successor predicates require independent explicit expectations for both routes",
       ctx do
    ctx = shipped_fixture(ctx)
    producer = historical_assignment(ctx, "producer")
    review = create_review(ctx, producer.id, "reviewer")

    for assignment <- [producer, review],
        do: put_shipped_effect(ctx, assignment.id, assignment.effectKind)

    name = "agentic-engineering/evidence-ref"
    file_judgment(ctx, "old-verified", producer.id, "holder", "verified", [], name)
    file_judgment(ctx, "old-review", review.id, "reviewer", "reviewed-clean", [], name)
    assert {:error, %Mementos.Refusal{message: missing}} = census(ctx)
    assert missing =~ "missing evidence requirement"
    assert {:ok, old_rows} = DB.query(ctx.db, "SELECT * FROM attests ORDER BY id")

    requirements = [
      %{
        assignment_id: producer.id,
        attest_id: "old-verified",
        route: "open-producer-holder-verification",
        name: name,
        values: ["document-A", "document-B"]
      },
      %{
        assignment_id: review.id,
        attest_id: "old-review",
        route: "independent-review",
        name: name,
        values: ["document-A", "document-B"]
      }
    ]

    entries =
      Enum.map_join(requirements, ", ", fn row ->
        "{" <>
          Enum.map_join(row, ", ", fn {key, value} ->
            Atom.to_string(key) <> " = " <> JSON.encode!(value)
          end) <> "}"
      end)

    File.write!(
      ctx.path,
      String.replace(File.read!(ctx.path), "entries = []", "entries = [" <> entries <> "]")
    )

    revision = commit_candidate(ctx.base)

    candidate =
      Gateway.prepare_law!(%{base_dir: ctx.base}, revision, Map.keys(ctx.handlers)).policy

    assert %{rules: [_ | _]} = MementoCutover.policy_inventory!(candidate)
    ctx = %{ctx | candidate: candidate}

    file_judgment(
      ctx,
      "new-verified",
      producer.id,
      "holder",
      "verified",
      ["document-B", "document-A"],
      name
    )

    file_judgment(
      ctx,
      "new-review",
      review.id,
      "reviewer",
      "reviewed-clean",
      ["document-A", "document-B"],
      name
    )

    assert {:ok, result} = census(ctx)
    assert result.successors_checked
    assert Enum.find(result.judgments, &(&1.id == "old-review")).successor.id == "new-review"
    assert Enum.find(result.judgments, &(&1.id == "old-verified")).successor.id == "new-verified"

    assert {:ok, ^old_rows} =
             DB.query(
               ctx.db,
               "SELECT * FROM attests WHERE id IN ('old-verified','old-review') ORDER BY id"
             )

    file_judgment(
      ctx,
      "adverse-latest",
      review.id,
      "reviewer",
      "changes-requested",
      ["document-A", "document-B"],
      name
    )

    assert {:error, %Mementos.Refusal{}} = census(ctx)
    assert Rules.active_admission_contract("attest") == "legacy"
  end

  test "runtime activation preserves history and remains legacy without a replacement policy",
       ctx do
    ctx = shipped_fixture(ctx)
    config = %{base_dir: ctx.base, db: ctx.db, wake_tick_ms: 1000}
    ctx = %{ctx | handlers: Gateway.handlers(config)}
    dir = Path.join(ctx.base, "identity")
    File.mkdir_p!(Path.join(dir, "archetypes"))
    File.mkdir_p!(Path.join(dir, "guidance"))
    File.write!(Path.join(dir, "archetypes/default.toml"), "name = \"default\"\nskills = []\n")

    File.cp!(
      "priv/seed/guidance/operating-model.md",
      Path.join(dir, "guidance/operating-model.md")
    )

    candidate_rules =
      for path <- Path.wildcard(Path.join(dir, "rules/*.toml")), do: {path, File.read!(path)}

    for {path, _} <- candidate_rules, do: File.rm!(path)
    prior = commit_candidate(ctx.base)

    for args <- [
          ["branch", "-M", "main"],
          ["branch", "tightbeam/live"],
          ["branch", "tightbeam/upstream"]
        ] do
      {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
      assert status == 0, output
    end

    Gateway.load_law!(config, Map.keys(ctx.handlers))
    for {path, bytes} <- candidate_rules, do: File.write!(path, bytes)

    producer = historical_assignment(ctx, "prepared producer")
    review = create_review(ctx, producer.id, "reviewer")

    for assignment <- [producer, review],
        do: put_shipped_effect(ctx, assignment.id, assignment.effectKind)

    user_call = fn verb, params ->
      %{
        verb: verb,
        params: params,
        principal: {:user, "owner"},
        origin: "user:owner",
        session_key: nil,
        target_role: nil,
        role_fallback: false
      }
    end

    assert {:ok, item} =
             Tightbeam.Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               user_call.("work-item-create", %{
                 title: "prepared target",
                 mementos: [
                   %{
                     "name" => "agentic-engineering/integration-target",
                     "value" => "feature/prepared"
                   }
                 ]
               })
             )

    for value <- ["pending", "prepared"] do
      assert %{mementos: _} =
               ctx.handlers["memento-set"].(
                 user_call.("memento-set", %{
                   record: "assignment:" <> producer.id,
                   name: "agentic-engineering/landing-outcome",
                   values: [value]
                 })
               )
    end

    refs = [%{"repo" => Placement.local_host_name() <> ":" <> dir, "commit" => prior}]

    attest = fn assignment, principal, kind, verdict, values, extra ->
      Tightbeam.Dispatch.dispatch(ctx.db, ctx.handlers, %{
        verb: "attest",
        params:
          Map.merge(
            %{
              assignment_id: assignment,
              kind: kind,
              verdict_kind: verdict,
              mementos:
                Enum.map(values, &%{"name" => "agentic-engineering/evidence-ref", "value" => &1})
            },
            extra
          ),
        principal: {:session, principal},
        transport_session_key: principal,
        origin: "session:" <> principal,
        session_key: nil,
        target_role: nil,
        role_fallback: false
      })
    end

    assert Rules.active_admission_contract("attest") == "legacy"

    assert {:ok, %{attest: old_verified}} =
             attest.(producer.id, "holder", "verdict", "verified", [], %{commit_refs: refs})

    assert old_verified.commitRefs == refs
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM attests")
    old_review = %{id: "historical-review"}
    file_judgment(ctx, old_review.id, review.id, "reviewer", "reviewed-clean", [])

    assert {:ok, legacy_rows} = DB.query(ctx.db, "SELECT * FROM attests ORDER BY id")

    # These independent expectations belong to the candidate policy. They are
    # not derived from either the old Git references or the selected successors.
    requirements =
      for {assignment, source, route} <- [
            {producer, old_verified, "open-producer-holder-verification"},
            {review, old_review, "independent-review"}
          ] do
        %{
          assignment_id: assignment.id,
          attest_id: source.id,
          route: route,
          name: "agentic-engineering/evidence-ref",
          values: ["document-A", "document-B"]
        }
      end

    entries =
      Enum.map_join(requirements, ", ", fn row ->
        "{" <>
          Enum.map_join(row, ", ", fn {key, value} ->
            Atom.to_string(key) <> " = " <> JSON.encode!(value)
          end) <> "}"
      end)

    File.write!(
      ctx.path,
      String.replace(File.read!(ctx.path), "entries = []", "entries = [" <> entries <> "]")
    )

    revision = commit_candidate(ctx.base)
    publication = %{expected_prior: prior, candidate_revision: revision}

    assert {:ok, %{attest: fresh_verified}} =
             attest.(
               producer.id,
               "holder",
               "verdict",
               "verified",
               ["document-B", "document-A"],
               %{commit_refs: refs}
             )

    assert {:ok, %{attest: fresh_review}} =
             attest.(
               review.id,
               "reviewer",
               "verdict",
               "reviewed-clean",
               ["document-A", "document-B"],
               %{}
             )

    assert {:ok, history} = DB.query(ctx.db, "SELECT * FROM memento_history ORDER BY id")

    assert {:ok, heads} =
             DB.query(ctx.db, "SELECT * FROM memento_current ORDER BY recordKind,recordId,name")

    if is_nil(Tightbeam.BuildStamp.build()) or is_nil(Tightbeam.BuildStamp.sha()) do
      assert {:error, %Mementos.Refusal{code: "policy_revision_unavailable"}} =
               Gateway.preflight_candidate_law!(
                 config,
                 publication,
                 "test",
                 Map.keys(ctx.handlers)
               )

      assert Tightbeam.Identity.live_revision!(ctx.base) == prior
    else
      assert {:ok, preflight} =
               Gateway.preflight_candidate_law!(
                 config,
                 publication,
                 "test",
                 Map.keys(ctx.handlers)
               )

      assert preflight.phase == :candidate_preflight
      assert Rules.active_admission_contract("attest") == "legacy"
      assert {:ok, _} = Tightbeam.Identity.publish_live!(ctx.base, publication)
      Gateway.stage_published_law!(config, Map.keys(ctx.handlers))

      assert {:error, %Mementos.Refusal{details: %{sessions: callers}}} =
               Gateway.staged_cutover_state!(config)

      assert length(callers) == 3

      for caller <- callers do
        Org.set_identity_stamp(ctx.db, caller.session_key, revision, nil, nil)
      end

      retained = retained_policy_record!(ctx.base)
      core = retained.record["core"]

      assert core == %{
               "build" => Tightbeam.BuildStamp.build(),
               "sha" => Tightbeam.BuildStamp.sha()
             }

      rewrite_memento_policy_record!(
        ctx.base,
        retained,
        Map.put(retained.record, "core", %{"build" => 0, "sha" => "different-core"})
      )

      error =
        assert_raise Mementos.Refusal, fn ->
          Tightbeam.Identity.commit_policy_activation!(ctx.base, publication, %{})
        end

      assert error.code == "policy_revision_unavailable"

      tampered = retained_policy_record!(ctx.base)
      rewrite_memento_policy_record!(ctx.base, tampered, Map.put(tampered.record, "core", core))

      assert {:ok, active} = Gateway.activate_staged_law!(config)
      assert active.identity_revision == revision
      assert active.assessment.core == core
      assert active.assessment.caller_inventory.stale_session_keys == []
      assert active.assessment.census.assignment_count == 2
      assert active.assessment.census.judgment_count == 4
      assert active.assessment.census.current_head_count == length(heads)
      checked = Map.new(active.assessment.census.judgments, &{&1.id, &1})
      assert checked[old_verified.id].successor.id == fresh_verified.id
      assert checked[old_review.id].successor.id == fresh_review.id
      assert checked[fresh_verified.id].route == "none"
      assert checked[fresh_review.id].route == "none"
      assert Rules.active_admission_contract("attest") == "legacy"
      assert Rules.active_admission_contract("harness-health-close-promotion") == "legacy"
      assert Rules.effective_snapshot().activation_generation == active.activation_generation
      assert {:ok, ^history} = DB.query(ctx.db, "SELECT * FROM memento_history ORDER BY id")

      assert {:ok, [["open"]]} =
               DB.query(ctx.db, "SELECT state FROM assignments WHERE id=?1", [producer.id])

      assert {:ok, ^heads} =
               DB.query(ctx.db, "SELECT * FROM memento_current ORDER BY recordKind,recordId,name")

      assert {:ok, ^legacy_rows} =
               DB.query(ctx.db, "SELECT * FROM attests WHERE id IN (?1,?2) ORDER BY id", [
                 old_verified.id,
                 old_review.id
               ])

      assert fresh_verified.id != old_verified.id
      assert fresh_review.id != old_review.id

      assert %{
               workItem: %{
                 mementos: %{"agentic-engineering/integration-target" => ["feature/prepared"]}
               }
             } =
               ctx.handlers["work-item-get"].(
                 user_call.("work-item-get", %{work_item_id: item.id})
               )

      assert {:ok, ^legacy_rows} =
               DB.query(ctx.db, "SELECT * FROM attests WHERE id IN (?1,?2) ORDER BY id", [
                 old_verified.id,
                 old_review.id
               ])
    end
  end

  defp commit_candidate(base) do
    dir = Path.join(base, "identity")

    for args <- [
          ["init"],
          ["add", "."],
          [
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "-m",
            "candidate policy"
          ]
        ] do
      {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
      assert status == 0, output
    end

    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    String.trim(revision)
  end

  defp retained_policy_record!(base) do
    dir = Path.join(base, "identity")

    {revision, 0} =
      System.cmd("git", ["rev-parse", "refs/tightbeam/memento-policy"],
        cd: dir,
        stderr_to_stdout: true
      )

    revision = String.trim(revision)
    {message, 0} = System.cmd("git", ["show", "-s", "--format=%B", revision], cd: dir)
    %{revision: revision, record: JSON.decode!(message)}
  end

  defp rewrite_memento_policy_record!(base, decision, record) do
    dir = Path.join(base, "identity")
    tree = Tightbeam.Identity.live_revision!(base)

    {revision, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.invalid",
          "commit-tree",
          "#{tree}^{tree}",
          "-m",
          JSON.encode!(record)
        ],
        cd: dir,
        stderr_to_stdout: true
      )

    {output, 0} =
      System.cmd(
        "git",
        [
          "update-ref",
          "refs/tightbeam/memento-policy",
          String.trim(revision),
          decision.revision
        ],
        cd: dir,
        stderr_to_stdout: true
      )

    assert output == ""
  end

  defp shipped_fixture(ctx) do
    ctx = census_fixture(ctx)
    File.rm!(ctx.path)
    File.rm!(Path.join(ctx.base, "identity/rules/selectors.toml"))
    File.rm_rf!(Path.join(ctx.base, "identity/kungfu/example"))
    source = Path.expand("priv/kungfu/agentic-engineering")
    target = Path.join(ctx.base, "identity/kungfu/agentic-engineering")
    File.mkdir_p!(target)
    File.cp!(Path.join(source, "manifest.toml"), Path.join(target, "manifest.toml"))

    for path <- Path.wildcard(Path.join(source, "rules/*.toml")) do
      File.cp!(path, Path.join(ctx.base, "identity/rules/" <> Path.basename(path)))
    end

    # Isolated preparation scope declares the names but has no operational
    # candidate rules. Preparing the full shipped replacement must not install
    # it or erase its admission metadata just to make fixture writes possible.
    preparation = Path.join(ctx.base, "preparation")
    manifest = Path.join(preparation, "identity/kungfu/agentic-engineering/manifest.toml")
    File.mkdir_p!(Path.dirname(manifest))
    File.cp!(Path.join(source, "manifest.toml"), manifest)

    Rules.install_legacy!(
      Rules.prepare!(preparation, Map.keys(ctx.handlers), revision: "preparation")
    )

    %{
      ctx
      | candidate:
          Rules.prepare!(ctx.base, Map.keys(ctx.handlers), revision: "replacement-candidate"),
        path: Path.join(ctx.base, "identity/rules/memento-cutover.toml")
    }
  end

  defp add_test_replacement_policies!(ctx) do
    File.rm!(Path.join(ctx.base, "identity/rules/engineering.toml"))

    File.write!(Path.join(ctx.base, "identity/rules/memento-admission-test.toml"), """
    [[rule]]
    name = "memento-completion-requires-current-review"
    verb = "attest"
    external_producer = true
    text = "Completion requires matching holder verification and independent review evidence."
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.memento.agentic-engineering/effect-kind", op = "in", value = ["code"] }
    ]
    require = [
      { fact = "assignment.latest_holder_verdict.present", op = "eq", value = true },
      { fact = "assignment.latest_holder_verdict.has_judgment_kind", op = "eq", value = true },
      { fact = "assignment.latest_holder_verdict.judgment_kind", op = "eq", value = "verified" },
      { fact = "assignment.latest_holder_verdict.memento_matches_call.agentic-engineering/evidence-ref", op = "eq", value = true },
      { fact = "assignment.latest_linked_review.present", op = "eq", value = true },
      { fact = "assignment.latest_linked_review.has_judgment_kind", op = "eq", value = true },
      { fact = "assignment.latest_linked_review.judgment_kind", op = "eq", value = "reviewed-clean" },
      { fact = "assignment.latest_linked_review.independent", op = "eq", value = true },
      { fact = "assignment.latest_linked_review.memento_matches_call.agentic-engineering/evidence-ref", op = "eq", value = true }
    ]

    [[admission_contract]]
    verb = "attest"
    classification = "replacement"
    required_rules = ["memento-completion-requires-current-review"]
    """)

    File.cp!(
      "test/fixtures/memento_promotion.toml",
      Path.join(ctx.base, "identity/rules/promotion.toml")
    )

    ctx
  end

  defp put_shipped_effect(ctx, id, value) do
    call = %{
      verb: "memento-set",
      params: %{
        record: "assignment:" <> id,
        name: "agentic-engineering/effect-kind",
        values: [value]
      },
      principal: {:user, "owner"},
      origin: "user:owner",
      session_key: nil,
      target_role: nil,
      role_fallback: false
    }

    assert %{mementos: mementos} = Mementos.__handle__(ctx.db, "memento-set", call)
    assert mementos["agentic-engineering/effect-kind"] == [value]
  end

  defp successor_fixture(ctx, route, suffix \\ "one") do
    # Separate stores for the latest-row cases; all production schemas and the
    # actual judgment index are used. No runtime replacement activation occurs.
    ctx = Map.put(ctx, :db_name, String.to_atom("census_" <> suffix)) |> census_fixture()

    File.write!(Path.join(ctx.base, "identity/kungfu/example/manifest.toml"), """
    [[mementos]]
    name = "effect"
    records = ["assignment"]
    [[mementos]]
    name = "references"
    records = ["attest"]
    many = true
    """)

    selector =
      if route == "linked_review", do: "latest_linked_review", else: "latest_holder_verdict"

    kind = if route == "linked_review", do: "reviewed-clean", else: "verified"

    File.write!(Path.join(ctx.base, "identity/rules/selectors.toml"), """
    [[rule]]
    name = "effects"
    verb = "post"
    text = "Select open producers"
    deny_when = [{fact = "assignment.state", op = "eq", value = "open"}, {fact = "assignment.is_producing_card", op = "eq", value = true}]
    [[rule]]
    name = "judgments"
    verb = "post"
    text = "Select legacy-only judgments"
    deny_when = [{fact = "call.has_memento.example/references", op = "eq", value = false}]
    [[rule]]
    name = "prepared"
    verb = "post"
    text = "Prepared judgments require no successor"
    deny_when = [{fact = "call.has_memento.example/references", op = "eq", value = true}]
    [[rule]]
    name = "successor"
    verb = "post"
    edges = ["cutover"]
    text = "Require the selected judgment and matching opaque evidence"
    external_producer = true
    deny_when = [{fact = "assignment.state", op = "in", value = ["open", "closed"]}]
    require = [
      {fact = "call.has_comparison_value", op = "eq", value = false},
      {fact = "assignment.#{selector}.memento_matches_call.example/references", op = "eq", value = false},
      {fact = "assignment.#{selector}.memento_contains_comparison_value.example/references", op = "eq", value = false},
      #{if route == "linked_review", do: ~s({fact = "assignment.latest_linked_review.independent", op = "eq", value = true},), else: ""}
      {fact = "assignment.#{selector}.present", op = "eq", value = true},
      {fact = "assignment.#{selector}.has_judgment_kind", op = "eq", value = true},
      {fact = "assignment.#{selector}.has_memento.example/references", op = "eq", value = true},
      {fact = "assignment.#{selector}.judgment_kind", op = "eq", value = "#{kind}"},
      {fact = "assignment.#{selector}.memento_matches_cutover_requirement.example/references", op = "eq", value = true}
    ]
    """)

    File.write!(
      ctx.path,
      declaration()
      |> String.replace("old", "code")
      |> String.replace("linked_review", route)
      |> String.replace(
        "judgments = [",
        ~s(judgments = [{selector = "prepared", route = "none"}, )
      )
    )

    Map.merge(ctx, %{candidate: prepare(ctx), successor_route: route})
  end

  defp require_evidence(ctx, assignment, attest, values \\ ["opaque-ref"]) do
    route =
      if ctx.successor_route == "linked_review",
        do: "independent-review",
        else: "open-producer-holder-verification"

    File.write!(
      ctx.path,
      File.read!(ctx.path) <>
        """

        [memento_cutover.legacy_evidence_requirements]
        version = 1
        entries = [{assignment_id = "#{assignment}", attest_id = "#{attest}", route = "#{route}", name = "example/references", values = #{JSON.encode!(values)}}]
        """
    )

    %{ctx | candidate: prepare(ctx)}
  end

  defp create_review(ctx, producer, holder) do
    assignment =
      ctx.handlers["assign"].(%{
        verb: "assign",
        params: %{subject: "review", reviews_assignment_id: producer},
        principal: {:user, "owner"},
        origin: "user:owner",
        session_key: holder,
        target_role: nil,
        role_fallback: false
      })

    historical_effect(ctx, assignment, "review")
  end

  defp close_assignment(ctx, id) do
    assert %{state: "closed"} =
             ctx.handlers["revoke-assignment"].(%{
               verb: "revoke-assignment",
               params: %{assignment_id: id, reason: "closed fixture"},
               principal: {:user, "owner"},
               origin: "user:owner",
               session_key: nil,
               target_role: nil,
               role_fallback: false
             })
  end

  defp file_judgment(ctx, id, assignment, holder, kind, values, name \\ "example/references") do
    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Txn.q(
                 txn,
                 "INSERT INTO attests(id,assignmentId,kind,verdictKind,bySession,commitRefs,ts) VALUES (?1,?2,'verdict',?3,?4,'[]',1)",
                 [id, assignment, kind, holder]
               )

               if values != [],
                 do:
                   Mementos.append_in_txn!(
                     txn,
                     "attest",
                     id,
                     [{name, values}],
                     {:session, holder},
                     "candidate"
                   )

               :ok
             end)
  end

  defp census_fixture(ctx) do
    db =
      start_supervised!(
        Supervisor.child_spec({DB, path: ":memory:", name: nil}, id: Map.get(ctx, :db_name, DB))
      )

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

    File.write!(
      ctx.path,
      declaration()
      |> String.replace("old", "code")
      |> String.replace(
        ~s(route = "linked_review", successor_rule = "successor"),
        ~s(route = "none")
      )
    )

    Map.merge(ctx, %{
      db: db,
      candidate: prepare(ctx),
      handlers: Gateway.handlers(%{db: db, wake_tick_ms: 1000})
    })
  end

  defp prepare(ctx), do: Rules.prepare!(ctx.base, ["post"], revision: "candidate")

  defp census(ctx, inventory \\ nil) do
    candidate =
      case Map.get(ctx.candidate, :memento_cutover) do
        declaration when is_map(declaration) ->
          Map.put(ctx.candidate, :memento_cutover, Map.put(declaration, :inventory, inventory))

        nil ->
          ctx.candidate
      end

    DB.transaction(ctx.db, &MementoCutover.census_in_txn!(&1, candidate))
  end

  defp historical_assignment(ctx, subject, effect \\ "code") do
    assignment =
      ctx.handlers["assign"].(%{
        verb: "assign",
        params: %{subject: subject},
        principal: {:user, "owner"},
        origin: "user:owner",
        session_key: "holder",
        target_role: nil,
        role_fallback: false
      })

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "DELETE FROM assignment_effects WHERE assignmentId=?1",
               [assignment.id]
             )

    historical_effect(ctx, %{assignment | effectKind: nil}, effect)
  end

  # The removal runtime reads these immutable pre-existing source rows during
  # cutover. Actual compatible API preparation across binaries is exercised by
  # policy_core_handoff_test; this helper isolates historical census behavior.
  defp historical_effect(ctx, assignment, effect) do
    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES (?1,?2) " <>
                 "ON CONFLICT(assignmentId) DO UPDATE SET effectKind=excluded.effectKind",
               [assignment.id, effect]
             )

    Map.put(assignment, :effectKind, effect)
  end

  defp put_effect(ctx, id, value) do
    assert {:ok, [_]} =
             DB.transaction(ctx.db, fn txn ->
               Mementos.append_in_txn!(
                 txn,
                 "assignment",
                 id,
                 [{"example/effect", [value]}],
                 {:session, "holder"},
                 "candidate"
               )
             end)
  end

  defp declaration do
    """
    [memento_cutover]
    version = 1
    judgments = [{selector = "judgments", route = "linked_review", successor_rule = "successor"}]
    [memento_cutover.effects]
    selector = "effects"
    mapping = [{legacy_value = "old", name = "example/effect", value = "opaque"}]
    """
  end
end
