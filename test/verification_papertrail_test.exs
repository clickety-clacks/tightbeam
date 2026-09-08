defmodule Tightbeam.VerificationPapertrailTest do
  # verification-papertrail-v1 acceptance: A1 (remedy wakes name each missing
  # record), A2 (the papertrail stands), A3 (rewakes and escalation on the
  # ladder's terms), A5 (a non-engineering org is never prodded). The shipped
  # statutes live in priv/kungfu/agentic-engineering/rules/verification.toml and
  # are exercised here exactly as relearn delivers them.
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Artifacts,
    Archetypes,
    Assignments,
    DB,
    Dispatch,
    EventLog,
    Gateway,
    Identity,
    Org,
    RailRemedy,
    Roles,
    Rules,
    Wakes,
    WorkItems
  }

  @verification_rule "completion-requires-verification"
  @artifact_rule "completion-requires-results-artifact"

  setup do
    db = :"verification_papertrail_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    holder = session(db, "vp-coder", "coder", "claude", "anthropic")
    reviewer = session(db, "vp-reviewer", "reviewer-code", "codex", "openai")
    Roles.create!(db, "reviewer-code", "flynn", reviewer.session_key)

    test_pid = self()

    start_supervised!(
      {Wakes,
       db: db,
       deliver: fn wake ->
         send(test_pid, {:wake_delivered, wake})
         true
       end,
       tick_ms: 60_000,
       name: Tightbeam.WakeScheduler}
    )

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-verification-papertrail-#{System.unique_integer([:positive])}"
      )

    assert :initialized = Archetypes.init_identity!(base_dir)
    Archetypes.load!(base_dir)

    handlers = Gateway.handlers(%{db: db})

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Rules)
      :persistent_term.erase(Archetypes)
    end)

    %{db: db, base_dir: base_dir, handlers: handlers, holder: holder, reviewer: reviewer}
  end

  # The statutes are NOT copied in: `learn!` performs the real shipped-bundle
  # import, so loading the org's own identity tree is what arrives on learn
  # (§7). Copying them here would pass even if learn stopped delivering
  # `rules/`.
  defp learn_engineering_rules!(ctx) do
    assert {:ok, _revision} =
             Identity.learn!(ctx.base_dir, "agentic-engineering", "flynn")

    for file <- ["engineering.toml", "verification.toml"] do
      assert File.exists?(Path.join([ctx.base_dir, "identity", "rules", file])),
             "learn did not deliver rules/#{file} into the org's identity tree"
    end

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
  end

  defp reviewed_clean_assignment(ctx) do
    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        principal: {:user, "flynn"},
        params: %{title: "papertrail #{System.unique_integer([:positive])}", is_bug: false}
      })

    work = assign(ctx, ctx.holder.session_key, item.id, "implement the feature")

    review =
      assign(ctx, ctx.reviewer.session_key, item.id, "review of the feature",
        reviews_assignment_id: work.id
      )

    assert {:ok, %{attest: %{verdictKind: "reviewed-clean"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               attest_call(ctx.reviewer.session_key, review.id, "verdict", "reviewed-clean")
             )

    # The review's own document. A verdict row carries the DECISION; the note
    # field caps at 2000 characters, so the clause table and evidence — the
    # reasoning that makes the decision reviewable — live in an artifact. The
    # school requires it of reviewers exactly as it does of coders, so the
    # papertrail fixture records one rather than modelling a reviewer that
    # drops its own analysis.
    Artifacts.record(ctx.db, %{
      principal: {:session, ctx.reviewer.session_key},
      session_key: ctx.reviewer.session_key,
      recorded_message_id: "msg_papertrail_review",
      params: %{
        kind: "report",
        title: "review clause table",
        origin_path: Path.join(System.tmp_dir!(), "papertrail-review.md"),
        work_item_id: item.id
      }
    })

    %{item: item, work: work, review: review}
  end

  test "A1: each remedy wake names its own missing record, in sequence", ctx do
    learn_engineering_rules!(ctx)
    %{work: work} = reviewed_clean_assignment(ctx)
    completion = attest_call(ctx.holder.session_key, work.id, "completion")

    # First denial: the verification verdict is missing.
    assert {:error, %{reason: "remedy_fired", rule: @verification_rule, producer: producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert producer == ctx.holder.session_key
    assert_receive {:wake_delivered, wake}
    assert wake.session_key == ctx.holder.session_key
    assert wake.prompt =~ "no verification verdict is filed"
    assert wake.prompt =~ work.id
    assert %{status: "live"} = RailRemedy.episode(ctx.db, @verification_rule, work.id)

    # The holder files its own verification verdict — never blocked (the
    # statute gates attest.kind "completion", and this is a "verdict").
    assert {:ok, %{attest: %{verdictKind: "verified"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               attest_call(ctx.holder.session_key, work.id, "verdict", "verified")
             )

    # Second denial: the results artifact is missing, and the sentence says so.
    assert {:error, %{reason: "remedy_fired", rule: @artifact_rule}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert_receive {:wake_delivered, artifact_wake}
    assert artifact_wake.session_key == ctx.holder.session_key
    assert artifact_wake.prompt =~ "no artifact is recorded on its work item"
    assert %{status: "live"} = RailRemedy.episode(ctx.db, @artifact_rule, work.id)
    # The satisfied verification statute's episode closed through maybe_close.
    assert %{status: "closed"} = RailRemedy.episode(ctx.db, @verification_rule, work.id)
  end

  test "A2: the complete papertrail passes and the episodes close", ctx do
    learn_engineering_rules!(ctx)
    %{item: item, work: work, review: review} = reviewed_clean_assignment(ctx)
    completion = attest_call(ctx.holder.session_key, work.id, "completion")

    assert {:error, %{rule: @verification_rule}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert {:ok, _} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               attest_call(ctx.holder.session_key, work.id, "verdict", "verified")
             )

    assert {:error, %{rule: @artifact_rule}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    record_report_artifact(ctx, item.id, ctx.holder.session_key)

    assert {:ok, %{assignment: %{state: "closed"}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert {:ok, [["closed", "completed"]]} =
             DB.query(ctx.db, "SELECT state, outcome FROM assignments WHERE id = ?1", [work.id])

    assert %{status: "closed"} = RailRemedy.episode(ctx.db, @verification_rule, work.id)
    assert %{status: "closed"} = RailRemedy.episode(ctx.db, @artifact_rule, work.id)

    # A review card is non-producing by construction, so its holder can close
    # it without a review-of-the-review. The implementation-only verification
    # and artifact statutes also stay out of scope.
    assert {:ok, %{assignment: %{state: "closed"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               attest_call(ctx.reviewer.session_key, review.id, "completion")
             )

    assert RailRemedy.episode(ctx.db, @verification_rule, review.id) == nil
    assert RailRemedy.episode(ctx.db, @artifact_rule, review.id) == nil
  end

  test "A3: back-to-back re-attempts rewake the live episode with no new episode", ctx do
    learn_engineering_rules!(ctx)
    %{work: work} = reviewed_clean_assignment(ctx)
    completion = attest_call(ctx.holder.session_key, work.id, "completion")

    assert {:error, %{rule: @verification_rule}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert %{status: "live", occurrence: 1, rewake_count: 0} =
             RailRemedy.episode(ctx.db, @verification_rule, work.id)

    # No intervening attest: a denied completion writes no attest row, so the
    # statute keeps matching and the live episode rewakes, occurrence unchanged.
    assert {:error, %{rule: @verification_rule}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert {:error, %{rule: @verification_rule}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert %{status: "live", occurrence: 1, rewake_count: 2} =
             RailRemedy.episode(ctx.db, @verification_rule, work.id)
  end

  test "A3: an escalate statute on the same gate opens a decision request", ctx do
    escalate_dir =
      Path.join(System.tmp_dir!(), "tightbeam-vp-escalate-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(escalate_dir, "identity/rules"))
    on_exit(fn -> File.rm_rf!(escalate_dir) end)

    File.write!(
      Path.join([escalate_dir, "identity", "rules", "escalate.toml"]),
      """
      [[rule]]
      name = "verification-escalates"
      verb = "attest"
      external_producer = true
      effect = "escalate"
      text = "completion without verification escalates to the owning human"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" },
        { fact = "assignment.holder_archetype", op = "in", value = ["coder"] },
        { fact = "assignment.verdicts", op = "not_in", value = ["verified"] },
      ]
      """
    )

    Rules.load!(escalate_dir, Map.keys(ctx.handlers))

    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        principal: {:user, "flynn"},
        params: %{title: "escalation gate", is_bug: false}
      })

    work = assign(ctx, ctx.holder.session_key, item.id, "escalated work")

    assert {:decision_pending, dr_id} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               attest_call(ctx.holder.session_key, work.id, "completion")
             )

    assert {:ok, [["open", "flynn"]]} =
             DB.query(
               ctx.db,
               "SELECT status, ownerUserId FROM decision_requests WHERE id = ?1",
               [dr_id]
             )
  end

  test "A5: a neutral-seeded org is never prodded", ctx do
    # An org that never learned the engineering bundle: its identity tree has
    # no statute files at all, so nothing verification-shaped exists anywhere.
    neutral_dir =
      Path.join(System.tmp_dir!(), "tightbeam-vp-neutral-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(neutral_dir, "identity/rules"))
    on_exit(fn -> File.rm_rf!(neutral_dir) end)

    assert Path.wildcard(Path.join(neutral_dir, "identity/**/*.toml")) == []

    Rules.load!(neutral_dir, Map.keys(ctx.handlers))

    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        principal: {:user, "flynn"},
        params: %{title: "neutral work", is_bug: false}
      })

    work = assign(ctx, ctx.holder.session_key, item.id, "neutral bare completion")

    assert {:ok, %{assignment: %{state: "closed"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               attest_call(ctx.holder.session_key, work.id, "completion")
             )

    # The org's own work-item routing/slate wakes are ordinary product
    # machinery; what must not exist is any remedy prod or any wake that speaks
    # verification vocabulary.
    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wakes WHERE origin LIKE 'remedy:%' OR prompt LIKE '%verification%' OR prompt LIKE '%verified%' OR prompt LIKE '%results artifact%'",
               []
             )

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM rail_remedy_episodes", [])

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM events WHERE kind = 'denied'", [])

    refute Enum.any?(
             EventLog.lifecycle_events(ctx.db),
             &(&1.detail =~ "verification" or &1.kind =~ "verification")
           )
  end

  test "learn delivers the verification statutes and they load beside engineering's (§7)", ctx do
    shipped = File.read!("priv/kungfu/agentic-engineering/rules/verification.toml")
    delivered = Path.join([ctx.base_dir, "identity", "rules", "verification.toml"])

    learn_engineering_rules!(ctx)

    assert File.read!(delivered) == shipped

    loaded = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert Enum.map(loaded, & &1.name) == [
             "completion-requires-review",
             "refix-requires-diagnosis",
             "code-review-requires-passing-tests",
             "spec-dispatch-requires-spirit",
             "implementation-requires-posture",
             "implementation-dispatch-requires-posture",
             @verification_rule,
             @artifact_rule,
             "wake-obligation-registration-authority"
           ]

    # F1/F2 accept the shipped pair: the verdict gate is remedy-covered, and the
    # artifact gate loads with no `produces` at all (D2).
    verification = Enum.find(loaded, &(&1.name == @verification_rule))
    artifact = Enum.find(loaded, &(&1.name == @artifact_rule))
    assert verification.remedy.produces == "verified"
    assert artifact.remedy.produces == nil
  end

  defp assign(ctx, holder_key, work_item_id, subject, opts \\ []) do
    Assignments.__handle__(ctx.db, "assign", %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder_key,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{
        subject: subject,
        work_item_id: work_item_id,
        reviews_assignment_id: opts[:reviews_assignment_id]
      }
    })
  end

  defp attest_call(session_key, assignment_id, kind, verdict_kind \\ nil) do
    params =
      case verdict_kind do
        nil -> %{assignment_id: assignment_id, kind: kind}
        verdict -> %{assignment_id: assignment_id, kind: kind, verdict_kind: verdict}
      end

    %{
      verb: "attest",
      origin: "agent:#{session_key}",
      principal: {:session, session_key},
      session_key: nil,
      params: params
    }
  end

  defp record_report_artifact(ctx, work_item_id, session_key) do
    message_id = "msg_#{System.unique_integer([:positive])}"

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO messages (id, sessionKey, role, content, timestamp, llmVisibleMessageId) VALUES (?1, ?2, 'assistant', 'verification results', 1, ?1)",
        [message_id, session_key]
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO artifacts
          (artifactId, kind, title, createdBySession, workItemId, originPath,
           recordedMessageId, state, createdAt, updatedAt)
        VALUES (?1, 'report', 'verification results', ?2, ?3, '/tmp/results.txt', ?4,
                'in-workspace', 1, 1)
        """,
        ["art_#{System.unique_integer([:positive])}", session_key, work_item_id, message_id]
      )
  end

  defp session(db, key, archetype, harness, provider) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: archetype,
      host: "eezo",
      harness: harness,
      provider: provider,
      model: Model.new("test")
    })
  end
end
