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
            sonnet: "claude-sonnet-5-5"
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
    fail_turn!(ctx.db, ctx.sessions.fable_1, @weekly_limit)
    fail_turn!(ctx.db, ctx.sessions.sonnet, @weekly_limit)

    assert [["rate-limit-dead"]] = open_incidents(ctx.db)
    assert HarnessProcess.parked?(ctx.db, @adapter_key)
    assert ModelRateLimit.held(ctx.db, "claude", "testhost") == []
  end

  test "a 429 that reaches a second model inside the window is account-wide", ctx do
    fable = fail_turn!(ctx.db, ctx.sessions.fable_1, @model_429)
    assert open_incidents(ctx.db) == []

    sonnet = fail_turn!(ctx.db, ctx.sessions.sonnet, @model_429)

    assert [["rate-limit-dead"]] = open_incidents(ctx.db)
    assert HarnessProcess.parked?(ctx.db, @adapter_key)

    {:ok, rows} =
      DB.query(
        ctx.db,
        """
        SELECT o.correlationId FROM harness_health_observations o
        JOIN harness_health_incidents i ON i.id=o.incidentId
        WHERE i.state='open' ORDER BY o.correlationId
        """
      )

    assert Enum.sort(List.flatten(rows)) ==
             Enum.sort([
               "harness-turn:#{fable}:rate-limit-dead",
               "harness-turn:#{sonnet}:rate-limit-dead"
             ])

    assert ModelRateLimit.held(ctx.db, "claude", "testhost") == []
    assert %{release_cause: "escalated"} = ModelRateLimit.for_turn(ctx.db, fable)
    assert %{release_cause: "escalated"} = ModelRateLimit.for_turn(ctx.db, sonnet)
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
      model: Model.new(model)
    })
  end
end
