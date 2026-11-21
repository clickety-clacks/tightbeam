defmodule Tightbeam.HarnessHealth.ModelRateLimitTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConditionFacts, DB, HarnessHealth, HarnessProcess, Ledger, Model, Org}
  alias Tightbeam.HarnessHealth.ModelRateLimit

  # The shape the Claude adapter reports: the same typed kind carries both a
  # model's request-rate 429 and an account's plan limit.
  @model_429 %{
    "code" => -32_603,
    "data" => %{"errorKind" => "rate_limit"},
    "message" =>
      "Internal error: API error: 429 This request would exceed your account's rate limit. " <>
        "Please try again later · model not changed"
  }
  @weekly_limit %{
    "code" => -32_603,
    "data" => %{"errorKind" => "rate_limit"},
    "message" => "Internal error: You've hit your weekly limit · resets Aug 15, 12am (UTC)"
  }
  @adapter_key {:claude, "shared", "testhost"}

  setup do
    db = :"model_rate_limit_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    main = Org.personal_session_key("flynn")
    session(db, main, "codex", "gpt-5", "main")

    sessions =
      for {name, model} <- [
            fable_1: "claude-fable-5-2",
            fable_2: "claude-fable-5-2",
            sonnet: "claude-sonnet-5-5",
            opus: "claude-opus-5-5"
          ],
          into: %{} do
        key = "agent:model-limit:#{name}"
        session(db, key, "claude", model)
        {name, key}
      end

    %{db: db, sessions: sessions}
  end

  test "a model-scoped 429 from two sessions inside the window does not fence other models",
       ctx do
    first = fail_turn!(ctx.db, ctx.sessions.fable_1, @model_429)
    second = fail_turn!(ctx.db, ctx.sessions.fable_2, @model_429)

    assert open_incidents(ctx.db) == []
    refute HarnessProcess.parked?(ctx.db, @adapter_key)
    refute ConditionFacts.harness_unavailable?(ctx.db, "claude", "testhost")

    assert [
             %{model: "claude-fable-5-2", turn_seq: ^first, released_at: nil},
             %{model: "claude-fable-5-2", turn_seq: ^second, released_at: nil}
           ] = ModelRateLimit.held(ctx.db, "claude", "testhost")

    # Another model answering neither releases Fable's records nor sends
    # Fable's failed prompts back into the same limit.
    succeed_turn!(ctx.db, ctx.sessions.sonnet)
    assert length(ModelRateLimit.held(ctx.db, "claude", "testhost")) == 2
    assert queued(ctx.db, ctx.sessions.fable_1) == 0
    assert queued(ctx.db, ctx.sessions.fable_2) == 0

    # Fable answering again releases them, and the held prompts are redelivered.
    fable_turn = succeed_turn!(ctx.db, ctx.sessions.fable_1)
    assert ModelRateLimit.held(ctx.db, "claude", "testhost") == []

    assert %{release_cause: "normal-turn", release_turn_seq: ^fable_turn} =
             ModelRateLimit.for_turn(ctx.db, first)

    assert queued(ctx.db, ctx.sessions.fable_2) == 1
  end

  test "an account-wide limit from two sessions still fences the harness", ctx do
    failure = fn model ->
      put_in(@weekly_limit["data"]["model"], model)
    end

    fail_turn!(ctx.db, ctx.sessions.fable_1, failure.("claude-fable-5-2"))
    fail_turn!(ctx.db, ctx.sessions.sonnet, failure.("claude-sonnet-5-5"))

    assert [["rate-limit-dead"]] = open_incidents(ctx.db)
    assert HarnessProcess.parked?(ctx.db, @adapter_key)
    assert ModelRateLimit.held(ctx.db, "claude", "testhost") == []
  end

  test "explicit quotas on different models leave a third model running", ctx do
    fable = put_in(@model_429["message"], "You've hit your Fable weekly limit")

    sonnet =
      @model_429
      |> put_in(["message"], "Internal error")
      |> put_in(["data", "message"], "You've hit your Sonnet weekly limit")

    first = fail_turn!(ctx.db, ctx.sessions.fable_1, fable)
    second = fail_turn!(ctx.db, ctx.sessions.sonnet, sonnet)

    assert open_incidents(ctx.db) == []
    refute HarnessProcess.parked?(ctx.db, @adapter_key)
    refute ConditionFacts.harness_unavailable?(ctx.db, "claude", "testhost")
    succeed_turn!(ctx.db, ctx.sessions.opus)

    assert [
             %{model: "claude-fable-5-2", turn_seq: ^first, released_at: nil},
             %{model: "claude-sonnet-5-5", turn_seq: ^second, released_at: nil}
           ] = ModelRateLimit.held(ctx.db, "claude", "testhost")
  end

  test "scope separates request-rate limits from plan limits" do
    model = "claude-fable-5-2"
    assert {:model, ^model} = ModelRateLimit.scope(@model_429["message"], model)
    assert {:model, ^model} = ModelRateLimit.scope("HTTP 429 Too Many Requests", model)
    assert :account = ModelRateLimit.scope(@weekly_limit["message"], model)
    assert :account = ModelRateLimit.scope("You've hit your usage limit.", model)
    assert :account = ModelRateLimit.scope("You've hit your 5-hour limit", model)
    assert :account = ModelRateLimit.scope("Limit reached · resets 4:00pm UTC", model)
    assert :account = ModelRateLimit.scope("rate limit · resets Oct 23, 5pm (UTC)", model)
    # A limit that names the turn's model family is that model's.
    assert {:model, "claude-opus-5-5"} =
             ModelRateLimit.scope("You've hit your Opus weekly limit", "claude-opus-5-5")

    assert :account = ModelRateLimit.scope("You've hit your Opus weekly limit", model)
    # No known model keeps today's harness-wide behaviour.
    assert :account = ModelRateLimit.scope(@model_429["message"], nil)
  end

  test "compactor model evidence requires an explicit model name and a replay-safe attempt key",
       ctx do
    model = "claude-haiku-5-5"
    identity = Model.new(model, context: "1m")
    assert ModelRateLimit.model_named?("You've hit your Haiku weekly limit", identity)
    assert ModelRateLimit.model_named?("Rate limit for claude-haiku-5-5.", identity)
    assert ModelRateLimit.model_named?("Rate limit for claude-haiku-5-5[1m].", identity)
    refute ModelRateLimit.model_named?("Rate limit for claude-haiku-5-5-preview", identity)
    refute ModelRateLimit.model_named?("Rate limit for claude-haiku-5-5[2m]", identity)
    refute ModelRateLimit.model_named?("You've hit your other-haiku weekly limit", identity)

    refute ModelRateLimit.model_named?(
             "You've hit your weekly limit. Model was not changed.",
             identity
           )

    refute ModelRateLimit.model_named?("HTTP 429 Too Many Requests", identity)

    input = %{
      harness: "claude",
      host: "testhost",
      model: model,
      compaction_attempt_key: "attempt-1",
      observed_at: System.system_time(:millisecond),
      cause: "compaction model limit",
      principal: "process:tightbeam"
    }

    assert %{status: "recorded", attempt_key: "attempt-1"} =
             ModelRateLimit.record_compactor_attempt(ctx.db, input)

    assert %{status: "duplicate", attempt_key: "attempt-1"} =
             ModelRateLimit.record_compactor_attempt(ctx.db, input)

    assert {:ok, [["claude", "testhost", ^model, nil, nil, "attempt-1"]]} =
             DB.query(
               ctx.db,
               """
               SELECT harness,host,model,sessionKey,turnSeq,compactionAttemptKey
               FROM harness_model_rate_limits WHERE compactionAttemptKey=?1
               """,
               ["attempt-1"]
             )

    assert_raise MatchError, fn ->
      ModelRateLimit.record_compactor_attempt(ctx.db, Map.delete(input, :host))
    end
  end

  test "a normal success releases a compactor hold recorded with a context variant", ctx do
    model = "claude-haiku-5-5"
    context = "1m"
    ref = Model.to_ref(Model.new(model, context: context))
    reason = put_in(@model_429["message"], "Rate limit for #{ref}")

    assert %{model_rate_limit: %{status: "recorded", attempt_key: attempt}} =
             HarnessHealth.observe_compactor_failure(ctx.db, %{
               context_id: "context-qualified-compaction",
               harness: "claude",
               host: "testhost",
               model: ref,
               reason: reason,
               observed_at: System.system_time(:millisecond)
             })

    assert {:ok, [[^model, ^context, nil]]} =
             DB.query(
               ctx.db,
               """
               SELECT model,modelContext,releasedAt FROM harness_model_rate_limits
               WHERE compactionAttemptKey=?1
               """,
               [attempt]
             )

    session_key = "agent:compactor-rate-limit-release"
    session(ctx.db, session_key, "claude", ref)
    release_turn = succeed_turn!(ctx.db, session_key)

    assert {:ok, [[^model, ^context]]} =
             DB.query(ctx.db, "SELECT model,modelContext FROM turns WHERE seq=?1", [release_turn])

    assert {:ok, [[^release_turn, "normal-turn"]]} =
             DB.query(
               ctx.db,
               """
               SELECT releaseTurnSeq,releaseCause FROM harness_model_rate_limits
               WHERE compactionAttemptKey=?1
               """,
               [attempt]
             )
  end

  test "the source-identity migration preserves existing turn records", ctx do
    :ok =
      DB.execute(ctx.db, """
      DROP INDEX harness_model_rate_limits_held;
      DROP TABLE harness_model_rate_limits;
      CREATE TABLE harness_model_rate_limits (
        id TEXT PRIMARY KEY,
        harness TEXT NOT NULL,
        host TEXT NOT NULL,
        model TEXT NOT NULL,
        sessionKey TEXT NOT NULL,
        assignmentId TEXT,
        turnSeq INTEGER NOT NULL UNIQUE,
        observedAt INTEGER NOT NULL,
        cause TEXT NOT NULL,
        principal TEXT NOT NULL,
        releasedAt INTEGER,
        releaseCause TEXT CHECK(releaseCause IN ('normal-turn','escalated')),
        releaseTurnSeq INTEGER,
        CHECK((releasedAt IS NULL AND releaseCause IS NULL) OR
              (releasedAt IS NOT NULL AND releaseCause IS NOT NULL))
      );
      CREATE INDEX harness_model_rate_limits_held
        ON harness_model_rate_limits(harness,host,model,releasedAt);
      INSERT INTO harness_model_rate_limits
        (id,harness,host,model,sessionKey,assignmentId,turnSeq,observedAt,cause,principal)
      VALUES ('legacy-row','claude','testhost','claude-haiku-5-5','agent:model-limit:opus',NULL,
              901,10,'legacy limit','process:tightbeam');
      """)

    :ok = Tightbeam.Schema.ensure_all(ctx.db)

    assert {:ok, [["legacy-row", "agent:model-limit:opus", 901, nil]]} =
             DB.query(
               ctx.db,
               "SELECT id,sessionKey,turnSeq,compactionAttemptKey FROM harness_model_rate_limits WHERE id='legacy-row'"
             )
  end

  defp queued(db, key) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(*) FROM turns WHERE sessionKey=?1 AND status='queued'", [key])

    count
  end

  defp open_incidents(db) do
    {:ok, rows} =
      DB.query(db, "SELECT failureClass FROM harness_health_incidents WHERE state='open'")

    rows
  end

  defp fail_turn!(db, key, reason) do
    {seq, turn} = claim!(db, key)
    session = Org.get(db, key)

    {:ok, callback} =
      DB.transaction(db, fn txn ->
        assert Ledger.finish_in_txn(txn, seq, "failed", reason["message"],
                 owner_lease: turn.owner_lease
               )

        HarnessHealth.observe_turn_failure_in_txn(txn, session, turn, :prompt, reason)
      end)

    if is_function(callback, 0), do: callback.()
    seq
  end

  defp succeed_turn!(db, key) do
    {seq, turn} = claim!(db, key)
    session = Org.get(db, key)

    {:ok, _} =
      DB.transaction(db, fn txn ->
        assert Ledger.finish_in_txn(txn, seq, "delivered", nil, owner_lease: turn.owner_lease)
        HarnessHealth.resolve_normal_turn_in_txn(txn, session, turn)
      end)

    seq
  end

  defp claim!(db, key) do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: key,
        message_id: "m-#{System.unique_integer([:positive])}",
        origin: "process:tightbeam",
        prompt: "work"
      })

    {:ok, turn} = Ledger.claim_next(db, key, "model-limit-test")
    assert turn.seq == seq
    {seq, Map.put(turn, :session_key, key)}
  end

  defp session(db, key, harness, model, kind \\ "custom") do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: kind,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: harness,
      provider: if(harness == "codex", do: "openai", else: "anthropic"),
      model: Model.parse_ref(model)
    })
  end
end
