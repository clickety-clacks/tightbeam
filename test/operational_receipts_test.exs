defmodule Tightbeam.OperationalReceiptsTest do
  # operational-receipt-verification r3 §8.2/§8.3 on main: tests 1, 2, 3, 4,
  # 5 (main), 8 and 9. The shipped engineering law is learned into a real
  # identity tree, so completion runs the same rules an org receives. Main asks
  # producers for no verified evidence, so receipts are optional here; this line
  # stores no captured bytes and selects linked reviews only.
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Archetypes,
    Assignments,
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
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('sample-user', 1, 'admin_add', 1)"
      )

    ensure_main_session(db, "sample-user")
    holder = session(db, "or-coder", "coder", "claude", "anthropic")
    reviewer = session(db, "or-reviewer", "reviewer-code", "codex", "openai")
    Roles.create!(db, "reviewer-code", "sample-user", reviewer.session_key)

    start_supervised!(
      {Wakes,
       db: db, deliver: fn _wake -> true end, tick_ms: 60_000, name: Tightbeam.WakeScheduler}
    )

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-receipts-#{System.unique_integer([:positive])}")

    assert :initialized = Archetypes.init_identity!(base_dir)
    Archetypes.load!(base_dir)
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Rules)
      :persistent_term.erase(Archetypes)
    end)

    assert {:ok, _revision} = Identity.learn!(base_dir, "agentic-engineering", "sample-user")
    rules = Rules.load!(base_dir, Map.keys(handlers))

    %{
      db: db,
      handlers: handlers,
      rules: rules,
      holder: holder.session_key,
      reviewer: reviewer.session_key
    }
  end

  describe "receipt verification" do
    test "1: an unreviewed evidence card verifies from a receipt and completes", ctx do
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
      assert rule_text(ctx, "completion-requires-review") =~ "review"

      assert [%{id: verified_id, receipts: [_]}] = attests(ctx, card)
      assert verified_id == verified.id

      review = card(ctx, item.id, "review", holder: ctx.reviewer, reviews: card.id)

      assert {:ok, %{attest: clean}} =
               attest(ctx, ctx.reviewer, %{
                 assignment_id: review.id,
                 kind: "verdict",
                 verdict_kind: "reviewed-clean"
               })

      # A keyed completion shows the same verification as an unkeyed one.
      assert {:ok, %{operationalVerification: shown}} =
               attest(ctx, ctx.holder, %{
                 assignment_id: card.id,
                 kind: "completion",
                 idempotency_key: "receipt-completion"
               })

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

      assert %{attests: [%{receipts: ^expected}]} =
               ctx.handlers["attests"].(%{
                 verb: "attests",
                 principal: {:user, "sample-user"},
                 origin: "user:sample-user",
                 params: %{assignment_id: card.id}
               })

      # After close, receipts on anything but a verified verdict are still
      # refused as not applicable, never silently dropped.
      assert {:ok, %{assignment: %{state: "closed"}}} = complete(ctx, card)

      assert %{code: "operational_receipts_not_applicable"} =
               refused(
                 attest(ctx, ctx.holder, %{
                   assignment_id: card.id,
                   kind: "verdict",
                   verdict_kind: "approved",
                   receipts: [cite(first)]
                 })
               )
    end

    test "4: every failing receipt is named and nothing is written", ctx do
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
        DB.query(ctx.db, "UPDATE artifacts SET state='released' WHERE artifactId=?1", [
          released.id
        ])

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
  end

  describe "receipts are producer evidence for operational cards only" do
    test "5: code, non-holders, progress and review cards are not applicable; bare verified stays accepted",
         ctx do
      item = item(ctx)
      code = card(ctx, item.id, "code")
      operational = card(ctx, item.id, "live_mutation")
      review = card(ctx, item.id, "review", holder: ctx.reviewer, reviews: operational.id)
      receipt = receipt(ctx, item.id)

      assert %{code: "operational_receipts_not_applicable", message: message} =
               refused(verify(ctx, code, [receipt]))

      assert message =~ "code"

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

      # Main asks producers for no verified evidence, on code or operational
      # cards alike, and that stays so (review M4).
      for card <- [code, operational] do
        assert {:ok, %{attest: %{verdictKind: "verified"} = bare}} = verify(ctx, card, [])
        refute Map.has_key?(bare, :receipts)
      end

      assert is_nil(get(ctx, operational)[:operationalVerification])
    end
  end

  describe "review is shown, never required by receipts" do
    test "8: a review alone is not producer verification", ctx do
      item = item(ctx)
      card = card(ctx, item.id, "live_mutation")
      review = card(ctx, item.id, "review", holder: ctx.reviewer, reviews: card.id)

      assert {:ok, %{attest: clean}} =
               attest(ctx, ctx.reviewer, %{
                 assignment_id: review.id,
                 kind: "verdict",
                 verdict_kind: "reviewed-clean"
               })

      assert {:error, %{reason: "remedy_fired", rule: "completion-requires-verification"}} =
               complete(ctx, card)

      assert Enum.all?(attests(ctx, card), &(&1.verdictKind != "verified"))

      assert {:ok, %{attest: verified}} = verify(ctx, card, [receipt(ctx, item.id)])

      expected_review = %{
        attestId: clean.id,
        assignmentId: review.id,
        holderKey: ctx.reviewer,
        linked: true
      }

      assert %{operationalVerification: %{verifiedAttestId: verified_id, review: shown}} =
               get(ctx, card)

      assert {verified_id, shown} == {verified.id, expected_review}

      assert {:ok, %{operationalVerification: %{review: ^expected_review}}} =
               complete(ctx, card)
    end
  end

  defp item(ctx) do
    WorkItems.__handle__(ctx.db, "work-item-create", %{
      principal: {:user, "sample-user"},
      params: %{title: "receipts #{System.unique_integer([:positive])}", is_bug: false}
    })
  end

  defp card(ctx, work_item_id, effect_kind, opts \\ []) do
    card =
      Assignments.__handle__(ctx.db, "assign", %{
        verb: "assign",
        origin: "user:sample-user",
        principal: {:user, "sample-user"},
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

  # A pointer receipt carries only a recorded hash, like the ACC receipt.
  defp receipt(ctx, work_item_id, opts \\ []) do
    bytes = "receipt #{System.unique_integer([:positive])}"
    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    content =
      if Keyword.has_key?(opts, :hash), do: %{}, else: %{content_sha256: digest}

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
      principal: {:user, "sample-user"},
      origin: "user:sample-user",
      params: %{assignment_id: card.id}
    })
  end

  defp rule_text(ctx, name), do: Enum.find(ctx.rules, &(&1.name == name)).text

  defp session(db, key, archetype, harness, provider) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: "sample-user",
      origin: "user:sample-user",
      archetype: archetype,
      host: "lab1",
      harness: harness,
      provider: provider,
      model: Model.new("test")
    })
  end
end
