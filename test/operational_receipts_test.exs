defmodule Tightbeam.OperationalReceiptsTest do
  # operational-receipt-verification r3 §8.3 on the 0.1.14 line. The shipped
  # engineering law is learned into a real identity tree, so completion runs the
  # same rules an org receives; receipts are the only thing this suite adds.
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Archetypes,
    Assignments,
    AttestEvidence,
    DB,
    Dispatch,
    Gateway,
    Identity,
    Model,
    Org,
    Roles,
    Rules,
    Wakes,
    WorkItems
  }

  setup do
    db = :"operational_receipts_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    holder = session(db, "or-coder", "coder", "claude", "anthropic")
    reviewer = session(db, "or-reviewer", "reviewer-code", "codex", "openai")
    Roles.create!(db, "reviewer-code", "flynn", reviewer.session_key)

    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})

    start_supervised!({
      Wakes,
      db: db,
      deliver: fn _wake -> flunk("normal remedy used legacy callback") end,
      delivery_opts: [conn_registry: Tightbeam.ConnRegistry, lane_manager: Tightbeam.LaneManager],
      tick_ms: 60_000,
      name: Tightbeam.WakeScheduler
    })

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-receipts-#{System.unique_integer([:positive])}")

    assert :initialized = Archetypes.init_identity!(base_dir)
    Archetypes.load!(base_dir)
    handlers = Gateway.handlers(%{db: db})

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Rules)
      :persistent_term.erase(Archetypes)
    end)

    assert {:ok, _revision} = Identity.learn!(base_dir, "agentic-engineering", "flynn")
    Rules.load!(base_dir, Map.keys(handlers))

    %{
      db: db,
      base_dir: base_dir,
      handlers: handlers,
      holder: holder.session_key,
      reviewer: reviewer.session_key
    }
  end

  @replacement %{"attest" => "replacement"}

  describe "receipt verification" do
    test "1: an unreviewed evidence card verifies from a receipt and completes", ctx do
      evidence_card_completes(ctx)
    end

    test "2: a receipt-verified live_mutation card is refused by the review rule until reviewed",
         ctx do
      item = item(ctx)
      card = card(ctx, item.id, "live_mutation")
      receipt = receipt(ctx, item.id)

      assert {:ok, %{attest: %{verdictKind: "verified"} = verified}} =
               verify(ctx, card, [receipt])

      assert {:error, refusal} = complete(ctx, card)
      assert %{reason: "remedy_fired", rule: "completion-requires-review"} = refusal
      refute inspect(refusal) =~ "operational_receipt"
      assert rule_text("completion-requires-review") =~ "review"

      assert [%{id: verified_id, receipts: [_]}] = attests(ctx, card)
      assert verified_id == verified.id

      review = card(ctx, item.id, "review", holder: ctx.reviewer, reviews: card.id)

      assert {:ok, %{attest: clean}} =
               attest(ctx, ctx.reviewer, %{
                 assignment_id: review.id,
                 kind: "verdict",
                 verdict_kind: "reviewed-clean"
               })

      assert {:ok, %{operationalVerification: shown}} = complete(ctx, card)

      assert shown == %{
               verifiedAttestId: verified.id,
               receipts: [%{artifactId: receipt.id, sha256: receipt.hash}],
               review: %{
                 attestId: clean.id,
                 assignmentId: review.id,
                 holderKey: ctx.reviewer,
                 linked: true
               }
             }
    end

    test "3: receipts are recorded and shown in submission order; a duplicate is refused", ctx do
      item = item(ctx)
      card = card(ctx, item.id, "evidence")
      second = receipt(ctx, item.id)
      first = receipt(ctx, item.id)

      assert %{code: "operational_receipt_malformed", message: message} =
               refused(verify(ctx, card, [first, second, first]))

      assert message =~ "duplicate receipt"
      assert attests(ctx, card) == []

      assert {:ok, %{attest: %{receipts: filed}}} = verify(ctx, card, [second, first])

      expected = [
        %{artifactId: second.id, sha256: second.hash},
        %{artifactId: first.id, sha256: first.hash}
      ]

      assert filed == expected
      assert [%{receipts: ^expected}] = attests(ctx, card)
    end

    test "4: every failing receipt is named and nothing is written", ctx do
      receipt_failures_refuse(ctx)
    end
  end

  describe "receipts are producer evidence for operational cards only" do
    test "5: code, non-holders, progress and review cards are not applicable", ctx do
      item = item(ctx)
      code = card(ctx, item.id, "code")
      operational = card(ctx, item.id, "live_mutation")
      review = card(ctx, item.id, "review", holder: ctx.reviewer, reviews: operational.id)
      receipt = receipt(ctx, item.id)

      assert %{code: "operational_receipts_not_applicable", message: message} =
               refused(verify(ctx, code, [receipt]))

      assert message =~ "code"
      assert message =~ "commitRefs"

      for {who, params} <- [
            {ctx.reviewer, verified_params(operational, [receipt])},
            {ctx.holder,
             %{assignment_id: operational.id, kind: "progress", receipts: [cite(receipt)]}},
            {ctx.reviewer,
             %{
               assignment_id: review.id,
               kind: "verdict",
               verdict_kind: "reviewed-clean",
               receipts: [cite(receipt)]
             }}
          ] do
        assert %{code: "operational_receipts_not_applicable"} = refused(attest(ctx, who, params))
      end

      assert attests(ctx, code) == []
      assert attests(ctx, operational) == []
      assert attests(ctx, review) == []

      # Code keeps its commit evidence in both admission phases, with or without
      # the revision-binding pair, and commitRefs are still accepted.
      for contract <- [nil, @replacement] do
        with_contract(contract, fn ->
          assert %{code: "invalid_commit_refs"} = refused(verify(ctx, code, []))

          assert %{code: "invalid_commit_refs"} =
                   refused(attest(ctx, ctx.holder, artifact_pair(code, receipt)))
        end)
      end

      assert {:ok, %{attest: %{verdictKind: "verified"}}} =
               attest(ctx, ctx.holder, Map.put(verified_params(code, []), :commit_refs, refs()))
    end

    test "6: operational cards need commits or receipts; declared files keep their outcomes",
         ctx do
      item = item(ctx)
      card = card(ctx, item.id, "live_mutation")
      receipt = receipt(ctx, item.id)

      assert %{code: "operational_receipts_required", message: message} =
               refused(verify(ctx, card, []))

      assert message =~ "--receipt"
      assert message =~ "--commit-refs"
      refute message =~ "policy"

      assert %{code: "operational_receipts_required", message: hinted} =
               refused(attest(ctx, ctx.holder, artifact_pair(card, receipt)))

      assert hinted =~ "--receipt #{receipt.id}:#{receipt.hash}"
      assert attests(ctx, card) == []

      assert {:ok, %{attest: %{commitRefs: [_]} = committed}} =
               attest(ctx, ctx.holder, Map.put(verified_params(card, []), :commit_refs, refs()))

      refute Map.has_key?(committed, :receipts)

      assert {:ok, %{attest: %{commitRefs: [_], receipts: [_]}}} =
               attest(
                 ctx,
                 ctx.holder,
                 Map.put(verified_params(card, [receipt]), :commit_refs, refs())
               )

      filed = card(ctx, item.id, "live_mutation", files: ["notes/result.md"])

      for contract <- [nil, @replacement] do
        with_contract(contract, fn ->
          assert %{code: without_receipts} = refused(verify(ctx, filed, []))

          assert without_receipts ==
                   if(contract,
                     do: "file_effect_evidence_policy_inactive",
                     else: "invalid_commit_refs"
                   )

          assert %{code: "file_effect_evidence_policy_inactive"} =
                   refused(attest(ctx, ctx.holder, artifact_pair(filed, receipt)))
        end)
      end

      assert {:ok, %{attest: %{receipts: [_]}}} = verify(ctx, filed, [receipt])
    end
  end

  describe "no policy dependence" do
    # 0.1.14 refuses every attest at admission while the replacement session
    # contract is unactivated (policy_revision_unavailable). Receipts are
    # validated before that, so refusals run end to end in that phase and the
    # accepted path is shown where evidence is prepared.
    test "7: tests 1 and 4 hold in the replacement admission phase", ctx do
      with_contract(@replacement, fn ->
        receipts_prepare(ctx)
        receipt_failures_refuse(ctx)
      end)
    end

    test "7: an identity declaring attest-operational-evidence loads and changes nothing", ctx do
      rules = Path.join([ctx.base_dir, "identity", "rules", "engineering.toml"])
      shipped = File.read!(rules)
      refute shipped =~ "attest-operational-evidence"

      File.write!(rules, """
      [[policy]]
      name = "operational-evidence-for-unfiled-live-effects"
      purpose = "attest-operational-evidence"
      when = [
        { fact = "assignment.effect_kind", op = "eq", value = "live_mutation" },
        { fact = "assignment.declared_files_present", op = "eq", value = false },
      ]

      #{shipped}
      """)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          loaded = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
          assert Enum.any?(loaded, &(&1.name == "completion-requires-review"))
        end)

      assert log =~
               "policy \"operational-evidence-for-unfiled-live-effects\" skipped: " <>
                 "purpose attest-operational-evidence is retired"

      evidence_card_completes(ctx)
      receipt_failures_refuse(ctx)

      with_contract(@replacement, fn ->
        receipts_prepare(ctx)
        receipt_failures_refuse(ctx)
      end)
    end
  end

  describe "review is shown, never required by receipts" do
    test "8: a review alone is not producer verification; same-item reviews show unlinked",
         ctx do
      item = item(ctx)
      card = card(ctx, item.id, "live_mutation")
      review = card(ctx, item.id, "review", holder: ctx.reviewer, reviews: card.id)

      assert {:ok, _} =
               attest(ctx, ctx.reviewer, %{
                 assignment_id: review.id,
                 kind: "verdict",
                 verdict_kind: "reviewed-clean"
               })

      assert {:error, %{reason: "remedy_fired", rule: "completion-requires-verification"}} =
               complete(ctx, card)

      assert Enum.all?(attests(ctx, card), &(&1.verdictKind != "verified"))

      evidence = card(ctx, item.id, "evidence")
      same_item = card(ctx, item.id, "review", holder: ctx.reviewer)

      assert {:ok, %{attest: clean}} =
               attest(ctx, ctx.reviewer, %{
                 assignment_id: same_item.id,
                 kind: "verdict",
                 verdict_kind: "reviewed-clean"
               })

      assert {:ok, %{attest: verified}} = verify(ctx, evidence, [receipt(ctx, item.id)])

      expected_review = %{
        attestId: clean.id,
        assignmentId: same_item.id,
        holderKey: ctx.reviewer,
        linked: false
      }

      assert %{operationalVerification: %{verifiedAttestId: verified_id, review: shown}} =
               get(ctx, evidence)

      assert {verified_id, shown} == {verified.id, expected_review}

      assert {:ok, %{operationalVerification: %{review: ^expected_review}}} =
               complete(ctx, evidence)
    end
  end

  # Test 1, reused by test 7 under each policy and phase variant.
  defp evidence_card_completes(ctx) do
    item = item(ctx)
    card = card(ctx, item.id, "evidence")
    receipt = receipt(ctx, item.id)

    assert {:error, %{reason: "remedy_fired", rule: "completion-requires-verification"}} =
             complete(ctx, card)

    refute Map.has_key?(get(ctx, card), :operationalVerification)

    assert {:ok, %{attest: %{verdictKind: "verified", commitRefs: nil} = verified}} =
             verify(ctx, card, [receipt])

    shown = %{
      verifiedAttestId: verified.id,
      receipts: [%{artifactId: receipt.id, sha256: receipt.hash}],
      review: nil
    }

    assert %{operationalVerification: ^shown} = get(ctx, card)
    assert {:ok, %{operationalVerification: ^shown}} = complete(ctx, card)
  end

  defp receipts_prepare(ctx) do
    item = item(ctx)
    card = card(ctx, item.id, "evidence")
    receipt = receipt(ctx, item.id)

    call = %{
      verb: "attest",
      principal: {:session, ctx.holder},
      origin: ctx.holder,
      params: verified_params(card, [receipt])
    }

    assert {:ok, %{validated_receipts: [%{artifactId: id, sha256: hash}]}} =
             DB.transaction(ctx.db, fn txn -> AttestEvidence.prepare_in_txn!(txn, call) end)

    assert {id, hash} == {receipt.id, receipt.hash}
  end

  # Test 4, reused by test 7 under each policy and phase variant.
  defp receipt_failures_refuse(ctx) do
    item = item(ctx)
    other_item = item(ctx)
    card = card(ctx, item.id, "live_mutation")
    good = receipt(ctx, item.id)
    other = receipt(ctx, other_item.id)

    missing = %{id: "art_missing_#{System.unique_integer([:positive])}", hash: good.hash}

    assert %{code: "operational_receipt_missing", message: message} =
             refused(verify(ctx, card, [good, missing, other]))

    assert message =~ "#{missing.id}: operational_receipt_missing"
    assert message =~ "#{other.id}: operational_receipt_unlinked"
    assert message =~ other_item.id
    assert message =~ item.id
    refute message =~ "#{good.id}:"

    released = receipt(ctx, item.id)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE artifacts SET state='released' WHERE artifactId=?1", [released.id])

    assert %{code: "operational_receipt_missing", message: message} =
             refused(verify(ctx, card, [released]))

    assert message =~ "released"

    assert %{code: "operational_receipt_hash_mismatch", message: message} =
             refused(verify(ctx, card, [%{good | hash: String.duplicate("0", 64)}]))

    assert message =~ "recorded hash is #{good.hash}"

    unhashed = receipt(ctx, item.id, hash: nil)

    assert %{code: "operational_receipt_hash_mismatch", message: message} =
             refused(verify(ctx, card, [%{unhashed | hash: good.hash}]))

    assert message =~ "records no hash"

    tampered = receipt(ctx, item.id, bytes: "captured operation result")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE artifact_contents SET content=?2 WHERE artifactId=?1",
        [tampered.id, "captured operation resulX"]
      )

    assert %{code: "operational_receipt_hash_mismatch", message: message} =
             refused(verify(ctx, card, [tampered]))

    assert message =~ "captured bytes"

    for malformed <- ["#{good.id}:#{String.upcase(good.hash)}", good.id, ":#{good.hash}"] do
      assert %{code: "operational_receipt_malformed"} =
               refused(
                 attest(ctx, ctx.holder, %{verified_params(card, []) | receipts: [malformed]})
               )
    end

    unlinked_card = card(ctx, nil, "live_mutation")

    assert %{code: "operational_receipt_unlinked", message: message} =
             refused(verify(ctx, unlinked_card, [good]))

    assert message =~ "none"

    assert attests(ctx, card) == []
    assert attests(ctx, unlinked_card) == []
  end

  defp item(ctx) do
    WorkItems.__handle__(ctx.db, "work-item-create", %{
      principal: {:user, "flynn"},
      params: %{title: "receipts #{System.unique_integer([:positive])}", is_bug: false}
    })
  end

  defp card(ctx, work_item_id, effect_kind, opts \\ []) do
    card =
      Assignments.__handle__(ctx.db, "assign", %{
        verb: "assign",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: opts[:holder] || ctx.holder,
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{
          subject: "#{effect_kind} work",
          work_item_id: work_item_id,
          reviews_assignment_id: opts[:reviews],
          effect_kind: effect_kind
        }
      })

    refute Map.has_key?(card, :code), inspect(card)

    for path <- opts[:files] || [] do
      {:ok, _} =
        DB.query(ctx.db, "INSERT INTO assignment_files(assignmentId,path) VALUES(?1,?2)", [
          card.id,
          path
        ])
    end

    card
  end

  # A pointer receipt carries only a recorded hash, like the ACC receipt; a
  # captured one also stores its bytes.
  defp receipt(ctx, work_item_id, opts \\ []) do
    bytes = opts[:bytes] || "receipt #{System.unique_integer([:positive])}"
    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    content =
      cond do
        opts[:bytes] -> %{content_base64: Base.encode64(bytes)}
        Keyword.has_key?(opts, :hash) -> %{}
        true -> %{content_sha256: digest}
      end

    artifact =
      ctx.handlers["artifact-record"].(%{
        verb: "artifact-record",
        principal: {:session, ctx.holder},
        session_key: ctx.holder,
        origin: ctx.holder,
        params:
          Map.merge(content, %{
            kind: "report",
            title: "operation receipt",
            origin_path: "/unavailable/receipt",
            work_item_id: work_item_id
          })
      })

    refute Map.has_key?(artifact, :code), inspect(artifact)
    %{id: artifact.artifact_id, hash: artifact.content_sha256 || digest}
  end

  defp cite(%{id: id, hash: hash}), do: "#{id}:#{hash}"

  defp verified_params(card, receipts) do
    cited = if receipts == [], do: nil, else: Enum.map(receipts, &cite/1)
    %{assignment_id: card.id, kind: "verdict", verdict_kind: "verified", receipts: cited}
  end

  defp artifact_pair(card, receipt) do
    card
    |> verified_params([])
    |> Map.merge(%{artifact_id: receipt.id, content_sha256: receipt.hash})
  end

  defp verify(ctx, card, receipts), do: attest(ctx, ctx.holder, verified_params(card, receipts))

  defp complete(ctx, card),
    do: attest(ctx, ctx.holder, %{assignment_id: card.id, kind: "completion"})

  defp attest(ctx, session_key, params) do
    params = params |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

    Dispatch.dispatch(ctx.db, ctx.handlers, %{
      verb: "attest",
      origin: "agent:#{session_key}",
      principal: {:session, session_key},
      session_key: nil,
      params: params
    })
  end

  defp refused({:ok, %{code: _} = refusal}), do: refusal
  defp refused({:error, %{code: _} = refusal}), do: refusal
  defp refused(other), do: flunk("expected a refusal, got #{inspect(other)}")

  defp attests(ctx, card), do: Assignments.list_attests(ctx.db, card.id)

  defp get(ctx, card) do
    ctx.handlers["assignment-get"].(%{
      verb: "assignment-get",
      principal: {:user, "flynn"},
      origin: "user:flynn",
      params: %{assignment_id: card.id}
    })
  end

  defp rule_text(name), do: Enum.find(Rules.effective_snapshot().rules, &(&1.name == name)).text

  defp with_contract(nil, fun), do: fun.()

  defp with_contract(contract, fun) do
    Rules.effective_snapshot()
    |> Map.put(:active_admission_contract, contract)
    |> Rules.with_snapshot(fun)
  end

  defp refs do
    repo = Path.expand("..", __DIR__)
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)

    [
      %{
        "repo" => "#{Tightbeam.Placement.local_host_name()}:#{repo}",
        "commit" => String.trim(commit)
      }
    ]
  end

  defp session(db, key, archetype, harness, provider) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: archetype,
      host: "lab1",
      harness: harness,
      provider: provider,
      model: Model.new("test")
    })
  end
end
