defmodule Tightbeam.DomainRuleExtractionTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{Assignments, DB, Gateway, Model, Org, Rules, WorkState}

  setup do
    db = :"domain_rules_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1)")
    for {key, archetype} <- [{"author", "coder"}, {"reviewer", "reviewer-code"}] do
      Org.create(db, %{session_key: key, display_name: key, kind: "custom", owner_user_id: "owner",
        origin: "user:owner", archetype: archetype, host: "testhost", harness: "codex",
        provider: "openai", model: Model.new("fable")})
    end
    root = Path.join(System.tmp_dir!(), "domain-rules-#{System.unique_integer([:positive])}")
    handlers = Gateway.handlers(%{db: db})
    law = Tightbeam.TerminalReactionFixture.load!(root, Map.keys(handlers))
    on_exit(fn -> File.rm_rf!(root); :persistent_term.erase(Rules) end)
    %{db: db, law: law, handlers: handlers}
  end

  test "effect labels use the neutral shipped default and permit arbitrary or absent labels without that policy", ctx do
    assert %{effectKind: "evidence"} = assign(ctx)
    assert %{code: "invalid_effect_kind"} = assign(ctx, %{effect_kind: "custom"})
    source = assign(ctx, %{effect_kind: "evidence"})
    assert %{effectKind: "review"} = assign(ctx, %{reviews_assignment_id: source.id}, "reviewer")
    assert %{code: "invalid_effect_kind"} =
      assign(ctx, %{reviews_assignment_id: source.id, effect_kind: "custom"}, "reviewer")

    File.rm!(Path.join(ctx.law, "identity/rules/assignment-labels.toml"))
    Rules.load!(ctx.law, Map.keys(ctx.handlers))
    assert %{effectKind: nil} = assign(ctx)
    assert %{effectKind: "custom"} = assign(ctx, %{effect_kind: "custom"})
    assert %{effectKind: "custom"} =
      assign(ctx, %{reviews_assignment_id: source.id, effect_kind: "custom"}, "reviewer")
  end

  test "invalid and ambiguous label families make no choice and keep assignment reads usable", ctx do
    stored = assign(ctx, %{effect_kind: "evidence"})
    path = Path.join(ctx.law, "identity/rules/assignment-labels.toml")
    original = File.read!(path)

    invalid_entries = [
      String.replace(original, ~s(default = "evidence"), "default = 42"),
      String.replace(original, ~s(linked = "review"), "linked = false"),
      String.replace(original, ~r/^allowed = .*$/m, ~s(allowed = "code")),
      String.replace(original, ~s(default = "evidence"), ~s(default = "outside")),
      String.replace(original, ~s(linked = "review"), "")
    ]

    ambiguous = original <> "\n" <> String.replace(original, "engineering-assignment-", "other-assignment-")

    for {contents, reason} <- Enum.map(invalid_entries, &{&1, "invalid"}) ++ [{ambiguous, "ambiguous"}] do
      File.write!(path, contents)
      Rules.load!(ctx.law, Map.keys(ctx.handlers))

      log = ExUnit.CaptureLog.capture_log(fn ->
        assert %{effectKind: nil} = assign(ctx)
        assert %{effectKind: "custom"} = assign(ctx, %{effect_kind: "custom"})
        assert %{effectKind: nil} = assign(ctx, %{reviews_assignment_id: stored.id}, "reviewer")
        assert Enum.any?(Assignments.list(ctx.db, %{}), &(&1.id == stored.id and &1.effectKind == "evidence"))
      end)

      assert log =~ "assignment-effect-labels is #{reason}"
    end
  end

  test "invalid and ambiguous verdict mappings leave ordinary completion status readable", ctx do
    card = assign(ctx)
    assert %{attest: _} = attest(ctx, card.id, %{kind: "verdict", verdict_kind: "verified"})
    assert %{assignment: %{state: "closed"}} = attest(ctx, card.id, %{kind: "completion"})
    path = Path.join(ctx.law, "identity/rules/assignment-labels.toml")
    original = File.read!(path)

    invalid_entries = [
      String.replace(original, ~s(statuses = ["verified"]), ~s(statuses = ["unknown"])),
      String.replace(original, ~s(statuses = ["verified"]), "statuses = []"),
      String.replace(original, ~s(verdicts = ["verified"]), "verdicts = [42]"),
      String.replace(original, ~s(statuses = ["verified"]), "statuses = false"),
      String.replace(original, ~s(statuses = ["verified"]), "")
    ]

    ambiguous = original <> "\n" <> String.replace(original, "engineering-assignment-", "other-assignment-")

    for {contents, reason} <- Enum.map(invalid_entries, &{&1, "invalid"}) ++ [{ambiguous, "ambiguous"}] do
      File.write!(path, contents)
      Rules.load!(ctx.law, Map.keys(ctx.handlers))

      log = ExUnit.CaptureLog.capture_log(fn ->
        assert WorkState.status(ctx.db, card.id) == "claims-done"
        assert Enum.any?(Assignments.list(ctx.db, %{state: "all"}), &(&1.id == card.id))
      end)

      assert log =~ "assignment-verdict-status is #{reason}"
    end
  end

  test "label schema upgrade preserves rows and reruns without changing stored labels", ctx do
    card = assign(ctx, %{effect_kind: "policy"})
    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
    assert {:ok, [["policy"]]} = DB.query(ctx.db,
      "SELECT effectKind FROM assignment_effects WHERE assignmentId=?1", [card.id])
    assert {:ok, _} = DB.query(ctx.db,
      "UPDATE assignment_effects SET effectKind=NULL WHERE assignmentId=?1", [card.id])
    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
    assert {:ok, [[nil]]} = DB.query(ctx.db,
      "SELECT effectKind FROM assignment_effects WHERE assignmentId=?1", [card.id])
  end

  test "the exact predecessor upgrades without moving rows or changing indexes", ctx do
    card = assign(ctx, %{effect_kind: "policy"})
    restore_legacy_effects(ctx.db, [{card.id, "policy"}])
    assert {:ok, [[rootpage]]} = DB.query(ctx.db,
      "SELECT rootpage FROM sqlite_master WHERE name='assignment_effects'")
    assert {:ok, indexes} = DB.query(ctx.db,
      "SELECT name,sql,rootpage FROM sqlite_master WHERE type='index' AND tbl_name='assignment_effects'")
    assert :ok = Tightbeam.Schema.upgrade_assignment_effect_labels(ctx.db)
    assert {:ok, [[^rootpage]]} = DB.query(ctx.db,
      "SELECT rootpage FROM sqlite_master WHERE name='assignment_effects'")
    assert {:ok, ^indexes} = DB.query(ctx.db,
      "SELECT name,sql,rootpage FROM sqlite_master WHERE type='index' AND tbl_name='assignment_effects'")
    assert {:ok, [["policy"]]} = DB.query(ctx.db,
      "SELECT effectKind FROM assignment_effects WHERE assignmentId=?1", [card.id])
    assert {:ok, _} = DB.query(ctx.db,
      "UPDATE assignment_effects SET effectKind='new-domain' WHERE assignmentId=?1", [card.id])
    assert :ok = Tightbeam.Schema.upgrade_assignment_effect_labels(ctx.db)
    assert {:ok, [["new-domain"]]} = DB.query(ctx.db,
      "SELECT effectKind FROM assignment_effects WHERE assignmentId=?1", [card.id])
    assert {:ok, []} = DB.query(ctx.db, "PRAGMA foreign_key_check")
  end

  test "an altered predecessor refuses without a migration marker or row changes", ctx do
    card = assign(ctx, %{effect_kind: "policy"})
    restore_legacy_effects(ctx.db, [{card.id, "policy"}])
    assert {:ok, _} = DB.query(ctx.db, "ALTER TABLE assignment_effects ADD COLUMN unexpected TEXT")
    assert {:ok, before_schema} = DB.query(ctx.db,
      "SELECT sql,rootpage FROM sqlite_master WHERE name='assignment_effects'")
    assert_raise Tightbeam.Schema.ShapeError, ~r/malformed owned object assignment_effects/, fn ->
      Tightbeam.Schema.upgrade_assignment_effect_labels(ctx.db)
    end
    assert {:ok, ^before_schema} = DB.query(ctx.db,
      "SELECT sql,rootpage FROM sqlite_master WHERE name='assignment_effects'")
    assert {:ok, [[card_id, "policy", nil]]} = DB.query(ctx.db, "SELECT * FROM assignment_effects")
    assert card_id == card.id
    assert {:ok, []} = DB.query(ctx.db,
      "SELECT 1 FROM supervision_liveness_migrations WHERE migrationId='assignment-effect-labels/v1'")
  end

  test "producer verification needs no refs on every shipped effect", ctx do
    for effect <- ~w(code policy release live_mutation evidence review coordination) do
      card = assign(ctx, %{effect_kind: effect})
      for refs <- [nil, []] do
        assert %{attest: %{verdictKind: "verified"}} =
          attest(ctx, card.id, %{kind: "verdict", verdict_kind: "verified", commit_refs: refs})
      end
    end
  end

  test "a later linked review finding cannot reopen a completed producer", ctx do
    producer = assign(ctx)
    review = assign(ctx, %{reviews_assignment_id: producer.id}, "reviewer")
    assert %{assignment: %{state: "closed"}} = attest(ctx, producer.id, %{kind: "completion"})
    for kind <- ["reviewed-clean", "changes-requested"] do
      assert %{attest: %{verdictKind: ^kind}} =
        attest(ctx, review.id, %{kind: "verdict", verdict_kind: kind}, "reviewer")
      assert {:ok, [["closed", "completed"]]} = DB.query(ctx.db,
        "SELECT state,outcome FROM assignments WHERE id=?1", [producer.id])
    end
  end

  test "presentation mapping is declared and removing it leaves completion claims", ctx do
    card = assign(ctx)
    assert %{attest: _} = attest(ctx, card.id, %{kind: "verdict", verdict_kind: "verified"})
    assert %{assignment: %{state: "closed"}} = attest(ctx, card.id, %{kind: "completion"})
    assert WorkState.status(ctx.db, card.id) == "verified"
    File.rm!(Path.join(ctx.law, "identity/rules/assignment-labels.toml"))
    Rules.load!(ctx.law, Map.keys(ctx.handlers))
    assert WorkState.status(ctx.db, card.id) == "claims-done"
  end

  test "the shipped completion predicate uses historical verdicts and only linked independent review", ctx do
    source = File.read!(Path.join(:code.priv_dir(:tightbeam), "kungfu/agentic-engineering/rules/verification.toml"))
    [rules_before_results_artifact | _] =
      String.split(
        source,
        "\n[[rule]]\nname = \"completion-requires-results-artifact\"",
        parts: 2
      )

    File.write!(
      Path.join(ctx.law, "identity/rules/verification.toml"),
      rules_before_results_artifact
    )
    Rules.load!(ctx.law, Map.keys(ctx.handlers))
    item = ctx.handlers["work-item-create"].(%{principal: {:user, "owner"}, origin: "user:owner", params: %{title: "Historical review"}})
    producer = assign(ctx, %{work_item_id: item.id, effect_kind: "code"})
    completion = call("attest", "author", %{assignment_id: producer.id, kind: "completion"})
    assert {{:remedy, %{name: "completion-requires-verification"}, _, _}, _, _} = Rules.decide(ctx.db, completion)
    assert %{attest: _} = attest(ctx, producer.id, %{kind: "verdict", verdict_kind: "reviewed-clean"})
    assert {{:remedy, _, _, _}, _, _} = Rules.decide(ctx.db, completion)
    unlinked = assign(ctx, %{work_item_id: item.id, effect_kind: "review"}, "reviewer")
    assert %{attest: _} = attest(ctx, unlinked.id, %{kind: "verdict", verdict_kind: "reviewed-clean"}, "reviewer")
    same_holder = assign(ctx, %{reviews_assignment_id: producer.id})
    assert %{attest: _} = attest(ctx, same_holder.id, %{kind: "verdict", verdict_kind: "reviewed-clean"})
    assert {{:remedy, _, _, _}, _, _} = Rules.decide(ctx.db, completion)
    review = assign(ctx, %{reviews_assignment_id: producer.id}, "reviewer")
    assert %{attest: _} = attest(ctx, review.id, %{kind: "verdict", verdict_kind: "reviewed-clean"}, "reviewer")
    assert :ok = Rules.evaluate(ctx.db, completion)
    assert %{attest: _} = attest(ctx, review.id, %{kind: "verdict", verdict_kind: "changes-requested"}, "reviewer")
    assert :ok = Rules.evaluate(ctx.db, completion)
    assert %{assignment: %{state: "closed"}} = attest(ctx, review.id, %{kind: "completion"}, "reviewer")
    assert :ok = Rules.evaluate(ctx.db, completion)

    own = assign(ctx, %{effect_kind: "code"})
    assert %{attest: _} = attest(ctx, own.id, %{kind: "verdict", verdict_kind: "verified"}, "reviewer")
    assert %{attest: _} = attest(ctx, own.id, %{kind: "verdict", verdict_kind: "verification-failed"})
    assert :ok = Rules.evaluate(ctx.db, call("attest", "author", %{assignment_id: own.id, kind: "completion"}))
  end

  test "commit-ref placement remains compiled while the attest-kind rule stays declared", ctx do
    path = Path.join(ctx.law, "identity/rules/placement.toml")
    File.write!(path, Tightbeam.TerminalReactionFixture.attest_placement())
    Rules.load!(ctx.law, Map.keys(ctx.handlers))

    for refs <- [[], [%{"repo" => "fixture:/result", "commit" => String.duplicate("a", 40)}]],
        {card_type, kind, verdict, allowed} <- [
          {:producer, "completion", nil, true}, {:linked, "completion", nil, false},
          {:producer, "verdict", "verified", true},
          {:producer, "verdict", "verification-failed", true},
          {:producer, "verdict", "reviewed-clean", false},
          {:review_effect, "verdict", "reviewed-clean", true},
          {:review_effect, "verdict", "changes-requested", true},
          {:linked, "verdict", "custom-judgment", true}
        ] do
      producer = assign(ctx)
      {card, holder} = case card_type do
        :producer -> {producer, "author"}
        :linked -> {assign(ctx, %{reviews_assignment_id: producer.id}, "reviewer"), "reviewer"}
        :review_effect -> {assign(ctx, %{effect_kind: "review"}), "author"}
      end
      candidate = call("attest", holder, %{assignment_id: card.id, kind: kind,
        verdict_kind: verdict, commit_refs: refs})
      assert :ok = Rules.evaluate(ctx.db, candidate)
      result = Tightbeam.Dispatch.dispatch(ctx.db, ctx.handlers, candidate)
      if allowed do
        assert {:ok, %{attest: _}} = result
      else
        assert {:error, %{code: "invalid_commit_refs"}} = result
      end
    end

    producer = assign(ctx)
    progress = call("attest", "author", %{assignment_id: producer.id, kind: "progress", commit_refs: []})
    assert {:deny, %{rule: "commit-refs-require-result-attest"}} = Rules.evaluate(ctx.db, progress)

    receipt = call("attest", "author", %{assignment_id: producer.id, kind: "verdict",
      verdict_kind: "ruling-consumed:dr_00000000-0000-4000-8000-000000000000", commit_refs: []})
    assert :ok = Rules.evaluate(ctx.db, receipt)
    assert %{code: "not_found", message: "decision request not found"} =
      Assignments.__handle__(ctx.db, "attest", receipt)

    File.rm!(path)
    Rules.load!(ctx.law, Map.keys(ctx.handlers))
    linked = assign(ctx, %{reviews_assignment_id: producer.id}, "reviewer")
    assert %{code: "invalid_commit_refs"} = attest(ctx, linked.id,
      %{kind: "completion", commit_refs: []}, "reviewer")
  end

  test "compiled completion hold keeps earlier validation and principal refusals", ctx do
    card = assign(ctx)
    assert %{attest: _} = attest(ctx, card.id, %{kind: "verdict", verdict_kind: "blocked"})
    valid_ref = %{"repo" => "fixture:/result", "commit" => String.duplicate("a", 40)}

    for {extra, code} <- [
      {%{commit_refs: [Map.put(valid_ref, "extra", true)]}, "invalid_commit_refs"},
      {%{commit_refs: [valid_ref, %{valid_ref | "commit" => "short"}]}, "invalid_commit_refs"},
      {%{commit_refs: [valid_ref, valid_ref]}, "invalid_commit_refs"},
      {%{commit_refs: "not an array"}, "invalid_commit_refs"},
      {%{note: String.duplicate("x", 2001)}, "invalid_note"},
      {%{note: "   "}, "invalid_note"},
      {%{note: 42}, "invalid_note"},
      {%{artifact_id: "artifact", content_sha256: String.duplicate("a", 64)}, "invalid_revision_binding"},
      {%{verdict_kind: "cleared"}, "invalid_verdict_kind"},
      {%{release_fact_kind: "released"}, "invalid_release_tuple"}
    ] do
      assert %{code: ^code} = attest(ctx, card.id, Map.put(extra, :kind, "completion"))
    end

    for refs <- [nil, [], [valid_ref]] do
      assert %{code: "completion_blocked", message: message} =
        attest(ctx, card.id, %{kind: "completion", commit_refs: refs})
      assert message == "assignment completion is blocked by its latest blocked verdict; " <>
        "file cannot-proceed to route the dependency to the parent as a decision, or, " <>
        "after it actually clears, file verdictKind=cleared on this assignment before completing"
    end

    for {principal, code} <- [
      {nil, "principal_required"}, {{:remedy, %{}}, "process_denied"},
      {{:user, "owner"}, "not_holder"}, {{:process, "fixture"}, "not_holder"}
    ] do
      candidate = %{call("attest", "author", %{assignment_id: card.id, kind: "completion"}) |
        principal: principal}
      assert %{code: ^code} = Assignments.__handle__(ctx.db, "attest", candidate)
    end

    assert %{state: "closed"} = Assignments.__handle__(ctx.db, "revoke-assignment",
      call("revoke-assignment", "author", %{assignment_id: card.id, reason: "fixture closed"}))
    assert %{code: "assignment_closed", message: "assignment is already closed"} =
      attest(ctx, card.id, %{kind: "completion"})
  end

  test "compiled placement keeps closed and principal order including review-effect verdicts", ctx do
    producer = assign(ctx)
    linked = assign(ctx, %{reviews_assignment_id: producer.id}, "reviewer")
    for card <- [producer, linked] do
      assert %{state: "closed"} = Assignments.__handle__(ctx.db, "revoke-assignment",
        call("revoke-assignment", "author", %{assignment_id: card.id, reason: "fixture closed"}))
    end
    assert %{code: "assignment_closed"} = attest(ctx, linked.id,
      %{kind: "completion", commit_refs: []}, "reviewer")
    assert %{code: "invalid_commit_refs"} = attest(ctx, producer.id,
      %{kind: "verdict", verdict_kind: "reviewed-clean", commit_refs: []})
    assert %{code: "assignment_closed"} = attest(ctx, producer.id,
      %{kind: "verdict", verdict_kind: "verified", commit_refs: []})

    review = assign(ctx, %{effect_kind: "review"})
    assert %{state: "closed"} = Assignments.__handle__(ctx.db, "revoke-assignment",
      call("revoke-assignment", "author", %{assignment_id: review.id, reason: "fixture closed"}))
    assert %{code: "assignment_closed"} = attest(ctx, review.id,
      %{kind: "verdict", verdict_kind: "reviewed-clean", commit_refs: []})

    for {principal, code} <- [
      {nil, "principal_required"}, {{:remedy, %{}}, "process_denied"},
      {{:user, "owner"}, "not_holder"}, {{:process, "fixture"}, "not_holder"}
    ] do
      candidate = %{call("attest", "reviewer", %{assignment_id: linked.id,
        kind: "completion", commit_refs: []}) | principal: principal}
      assert %{code: ^code} = Assignments.__handle__(ctx.db, "attest", candidate)
    end
  end

  test "receipt laws preserve raw count, prefix, Unicode whitespace and length boundaries", ctx do
    File.write!(
      Path.join(ctx.law, "identity/rules/receipts.toml"),
      Tightbeam.TerminalReactionFixture.ruling_receipts()
    )
    Rules.load!(ctx.law, Map.keys(ctx.handlers))
    receipt = %{kind: "verdict", verdict_kind: "ruling-consumed:dr_00000000-0000-4000-8000-000000000000"}
    ref = %{"repo" => "fixture:/result", "commit" => String.duplicate("A", 40)}
    evaluate = fn extra -> Rules.evaluate(ctx.db, call("attest", "author", Map.merge(receipt, extra))) end
    assert :ok = evaluate.(%{commit_refs: [ref]})
    assert :ok = evaluate.(%{note: "operational-action: changed"})
    assert :ok = evaluate.(%{note: "operational-action: changed", commit_refs: []})
    assert :ok = evaluate.(%{note: "operational-action: " <> String.duplicate("é", 1980)})
    for params <- [%{}, %{commit_refs: []}, %{commit_refs: [ref, ref]},
                   %{note: "operational-action: changed", commit_refs: [ref]},
                   %{note: "changed"}, %{note: ""},
                   %{note: "operational-action: " <> String.duplicate("é", 1981)},
                   %{note: "operational-action: " <> String.duplicate("x", 1980) <> "\n"},
                   %{commit_refs: [%{ref | "commit" => "bad"}]}] do
      assert {:deny, %{code: "rule_denied"}} = evaluate.(params)
    end
    whitespace = Enum.to_list(0x9..0xD) ++ [0x20, 0x85, 0xA0, 0x1680] ++
      Enum.to_list(0x2000..0x200A) ++ [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
    for point <- whitespace do
      text = <<point::utf8>>
      assert String.trim(text) == ""
      assert {:deny, %{rule: "receipt-note-requires-operational-action"}} =
        evaluate.(%{note: "operational-action: " <> text})
      assert :ok = evaluate.(%{note: "operational-action: " <> text <> "x" <> text})
    end
    # The nontext shape arm remains in the handler; the raw string fact is absent.
    assert :ok = evaluate.(%{note: 42})
    assert :ok = evaluate.(%{verdict_kind: "reviewed-clean"})
    File.rm!(Path.join(ctx.law, "identity/rules/receipts.toml"))
    Rules.load!(ctx.law, Map.keys(ctx.handlers))
    assert :ok = evaluate.(%{})
    assert :ok = evaluate.(%{note: "any text", commit_refs: [ref, ref]})
  end

  defp restore_legacy_effects(db, rows) do
    assert {:ok, :ok} = DB.migration_transaction(db, :test_legacy_labels, [], [], fn txn ->
      Tightbeam.DB.Txn.exec(txn, "DROP TABLE assignment_effects")
      Tightbeam.DB.Txn.exec(txn, Assignments.legacy_effects_ddl())
      for {id, label} <- rows do
        Tightbeam.DB.Txn.q(txn, "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES(?1,?2)", [id, label])
      end
      Tightbeam.DB.Txn.q(txn,
        "DELETE FROM supervision_liveness_migrations WHERE migrationId='assignment-effect-labels/v1'")
      :ok
    end)
  end

  defp assign(ctx, extra \\ %{}, holder \\ "author") do
    params = Map.merge(%{subject: "result", idempotency_key: nil, work_item_id: nil,
      reviews_assignment_id: nil, effect_kind: nil, files: nil}, extra)
    Assignments.__handle__(ctx.db, "assign", %{call("assign", "author", params) | session_key: holder})
  end

  defp attest(ctx, id, params, holder \\ "author"),
    do: Assignments.__handle__(ctx.db, "attest", call("attest", holder, Map.put(params, :assignment_id, id)))

  defp call(verb, holder, params),
    do: %{verb: verb, principal: {:session, holder}, origin: "agent:#{holder}", session_key: nil, params: params, target_role: nil, role_fallback: false, supervision_interval_ms: 1_000}
end
