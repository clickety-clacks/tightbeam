defmodule Tightbeam.HarnessHealthTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    ConditionFacts,
    DB,
    EventLog,
    Gateway,
    HarnessHealth,
    Ledger,
    Model,
    Org,
    Projection,
    HarnessHealth.RecoveryCheck,
    Wakes
  }

  # Captured, not invented: immutable process-failure provenance report
  # process-failure-provenance-recon-frozen-214ac797f19e-2026-08-09.md,
  # specimens S1/lifecycle row 221422 and S9/lifecycle row 219529.
  @captured_codex_rate_limit %{
    "code" => -32_603,
    "data" => %{
      "codexErrorInfo" => "usageLimitExceeded",
      "message" =>
        "You've hit your usage limit. Visit the account usage page or try again at Aug 15th, 2026 8:29 PM."
    },
    "message" => "Internal error"
  }
  @captured_claude_rate_limit %{
    "code" => -32_603,
    "data" => %{"errorKind" => "rate_limit"},
    "message" => "Internal error: You've hit your weekly limit · resets Aug 15, 12am (UTC)"
  }

  defmodule RecoveryLane do
    use GenServer
    def start_link(args), do: GenServer.start_link(__MODULE__, args, name: Tightbeam.LaneManager)
    def init(args), do: {:ok, args}

    def handle_cast({:ensure_lane, key}, {db, parent} = state) do
      {:ok, rows} =
        DB.query(db, "SELECT seq FROM turns WHERE sessionKey=?1 AND status='queued'", [key])

      send(parent, {:recovery_lane, key, rows})
      {:noreply, state}
    end
  end

  setup do
    db = :"harness_health_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    main_session = Org.personal_session_key("flynn")

    Org.create(db, %{
      session_key: main_session,
      display_name: "Main",
      kind: "main",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "codex",
      provider: "openai",
      model: Model.new("gpt-5")
    })

    sessions =
      for index <- 1..3 do
        session_key = "agent:harness-health:#{index}"

        Org.create(db, %{
          session_key: session_key,
          display_name: "Harness health #{index}",
          owner_user_id: "flynn",
          origin: "user:flynn",
          archetype: "coder",
          host: "testhost",
          harness: "claude",
          provider: "anthropic",
          model: Model.new("claude-fable-5")
        })

        assignment_id = "asg_health_#{index}"

        assert {:ok, []} =
                 DB.query(
                   db,
                   """
                   INSERT INTO assignments
                     (id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
                   VALUES (?1,?2,?3,?3,?4,'open','claude','anthropic')
                   """,
                   [assignment_id, "health assignment #{index}", session_key, index]
                 )

        %{session: session_key, assignment: assignment_id}
      end

    outside_session = "agent:harness-health:outside"

    Org.create(db, %{
      session_key: outside_session,
      display_name: "Healthy harness member",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "coder",
      host: "lab1",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })

    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO assignments
                 (id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
               VALUES ('asg_health_outside','healthy work',?1,?1,4,'open','claude','anthropic')
               """,
               [outside_session]
             )

    %{db: db, main_session: main_session, sessions: sessions, outside_session: outside_session}
  end

  test "inference needs two distinct sessions in the bounded window", ctx do
    [first, second, third] = ctx.sessions

    assert {:pending, %{distinctSessions: 1, requiredSessions: 2}} =
             HarnessHealth.observe(ctx.db, failure(first, "auth-dead", 1_000, "failure-1"))

    assert {:duplicate, %{distinctSessions: 1}} =
             HarnessHealth.observe(ctx.db, failure(first, "auth-dead", 1_000, "failure-1"))

    assert HarnessHealth.active(ctx.db) == []
    refute ConditionFacts.harness_unavailable?(ctx.db, "claude", "testhost")

    assert {:pending, %{distinctSessions: 1}} =
             HarnessHealth.observe(
               ctx.db,
               failure(
                 second,
                 "auth-dead",
                 1_000 + HarnessHealth.evidence_window_ms() + 1,
                 "late"
               )
             )

    assert {:opened, opened} =
             HarnessHealth.observe(
               ctx.db,
               failure(
                 third,
                 "auth-dead",
                 1_000 + HarnessHealth.evidence_window_ms() + 2,
                 "failure-3"
               )
             )

    assert opened.failureClass == "auth-dead"
    assert ConditionFacts.harness_failure_standing?(ctx.db, "claude", "testhost", "auth-dead")

    incident = HarnessHealth.get(ctx.db, opened.id)
    assert incident.affectedSessions == Enum.sort(Enum.map(ctx.sessions, & &1.session))
    assert incident.affectedAssignments == Enum.sort(Enum.map(ctx.sessions, & &1.assignment))
    refute ctx.outside_session in incident.affectedSessions
    refute "asg_health_outside" in incident.affectedAssignments
    assert Enum.map(incident.observations, & &1.correlation_id) == ["late", "failure-3"]
  end

  test "authoritative evidence opens at one and the two classes never collapse", ctx do
    [first, second | _] = ctx.sessions

    assert {:opened, auth} =
             HarnessHealth.observe(
               ctx.db,
               authoritative(first, "auth-dead", 10, "provider-auth")
             )

    assert {:opened, rate} =
             HarnessHealth.observe(
               ctx.db,
               authoritative(second, "rate-limit-dead", 11, "provider-rate")
             )

    assert auth.id != rate.id

    assert Enum.map(HarnessHealth.active(ctx.db), & &1.failureClass) ==
             ["auth-dead", "rate-limit-dead"]

    assert ConditionFacts.harness_failure_standing?(ctx.db, "claude", "testhost", "auth-dead")

    assert ConditionFacts.harness_failure_standing?(
             ctx.db,
             "claude",
             "testhost",
             "rate-limit-dead"
           )
  end

  test "other admission carries evidence, review, idempotency, and matching recovery", ctx do
    [member | _] = ctx.sessions
    at = System.system_time(:millisecond)

    input = %{
      harness: "claude",
      host: "testhost",
      source_session_key: member.session,
      principal: {:session, member.session},
      description: "provider returned an unclassified transport failure",
      evidence_mode: "exact_error",
      observed_state: "the provider connection was unavailable",
      exact_observed_error: "transport reset by peer",
      exact_probe: "GET provider health endpoint",
      recovery_condition: "a normal provider turn completes",
      not_known_class_reason:
        "the response is neither an auth, quota, adapter, model, task, nor interruption signal",
      observed_at: at,
      accepted_at: at,
      valid_until: at + 500,
      world_status: "UNKNOWN",
      redaction_confirmed: true,
      idempotency_key: "other-admission-1",
      correlation_id: "other-admission-correlation"
    }

    assert {:opened, opened} = HarnessHealth.observe_other(ctx.db, input)
    assert opened.failureClass == "other"
    assert HarnessHealth.get(ctx.db, opened.id).repair.action == "review"
    assert ConditionFacts.harness_failure_standing?(ctx.db, "claude", "testhost", "other")

    assert {:duplicate, duplicate} = HarnessHealth.observe_other(ctx.db, input)
    assert duplicate["id"] == opened.id

    assert {:ok, %{state: "closed", outcome: "confirmed_other"}} =
             HarnessHealth.review_other(ctx.db, %{
               incident_id: opened.id,
               outcome: "confirmed_other",
               cause: "the provider evidence remains outside the named classes",
               principal: {:session, member.session},
               idempotency_key: "other-review-1"
             })

    probe = "normal turn #{at + 1} delivered"
    recovery_at = at + 1

    recovery = %{
      harness: "claude",
      host: "testhost",
      incident_id: opened.id,
      session_key: member.session,
      principal: {:session, member.session},
      observed_state: "normal turn delivered",
      exact_probe: probe,
      output_digest: :crypto.hash(:sha256, probe) |> Base.encode16(case: :lower),
      recovery_condition_digest:
        :crypto.hash(:sha256, "a normal provider turn completes")
        |> Base.encode16(case: :lower),
      recovery_satisfied: true,
      world_status: "PROVEN",
      redaction_confirmed: true,
      cause: "normal turn 101 delivered",
      observed_at: recovery_at,
      accepted_at: recovery_at,
      idempotency_key: "other-recovery-1"
    }

    assert {:resolved, resolved} = HarnessHealth.resolve_other(ctx.db, recovery)
    assert resolved.state == "resolved"

    assert {:ok, [[event_json]]} =
             DB.query(
               ctx.db,
               "SELECT event FROM row_reaction_events WHERE eventId=?1",
               ["harness-health-hold:#{opened.id}:resolved"]
             )

    event = JSON.decode!(event_json)
    assert event["cycleRelease"] == false

    assert {:ok, [[resolution_correlation]]} =
             DB.query(
               ctx.db,
               "SELECT correlationId FROM harness_health_observations WHERE id=?1",
               [resolved.resolutionObservationId]
             )

    assert event["resolutionCorrelation"] == resolution_correlation
    assert event["after"]["resolutionCorrelation"] == resolution_correlation

    refute ConditionFacts.harness_failure_standing?(ctx.db, "claude", "testhost", "other")
  end

  test "other evidence validity accepts the 15-minute boundary and explains excess validity",
       ctx do
    at = System.system_time(:millisecond)
    source_session = "agent:harness-health:validity-boundary"

    Org.create(ctx.db, %{
      session_key: source_session,
      display_name: "Validity boundary",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "coder",
      host: "test-host",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })

    input = %{
      harness: "claude",
      host: "test-host",
      source_session_key: source_session,
      principal: {:session, source_session},
      description: "bounded unclassified transport evidence",
      evidence_mode: "exact_error",
      observed_state: "the provider connection was unavailable",
      exact_observed_error: "transport reset by peer",
      exact_probe: "GET provider health endpoint",
      recovery_condition: "a normal provider turn completes",
      not_known_class_reason: "not one of the named failure classes",
      observed_at: at,
      accepted_at: at,
      valid_until: at + 900_000,
      world_status: "UNKNOWN",
      redaction_confirmed: true,
      idempotency_key: "other-validity-boundary"
    }

    assert {:opened, _opened} = HarnessHealth.observe_other(ctx.db, input)

    assert {:error,
            %{
              code: "invalid_other_evidence",
              message:
                "invalid --valid-until: must be no more than 15 minutes after --observed-at (defaults to server acceptance time)"
            }} =
             HarnessHealth.observe_other(ctx.db, %{
               input
               | description: "unclassified evidence beyond validity limit",
                 valid_until: at + 900_001,
                 idempotency_key: "other-validity-over-limit"
             })
  end

  test "public other opening deduplicates an owner main already present as an ancestor", ctx do
    [child, parent | _] = ctx.sessions
    at = System.system_time(:millisecond)

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
               child.session,
               parent.session
             ])

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
               parent.session,
               ctx.main_session
             ])

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: child.session,
               principal: {:session, child.session},
               description: "owner main appears as ancestor",
               evidence_mode: "exact_error",
               observed_state: "provider route failed",
               exact_observed_error: "ancestor duplicate",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "owner-main-dedupe"
             })

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM harness_health_other_routes WHERE incidentId=?1 AND targetRef=?2 AND state != 'skipped'",
               [opened.id, ctx.main_session]
             )
  end

  test "an idle health route binds its actual turn, not an unrelated message sequence", ctx do
    [child, parent | _] = ctx.sessions
    parent_session = parent.session
    at = System.system_time(:millisecond)

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
               child.session,
               parent_session
             ])

    # Assistant messages advance this session's message counter without turns.
    for index <- 1..2 do
      assert {:appended, _} =
               Projection.append(ctx.db, %{
                 session_key: parent_session,
                 role: "assistant",
                 content: "prior reply #{index}",
                 sender: "agent:#{parent_session}"
               })
    end

    # Completed unrelated turns skew the independently allocated counters.
    for index <- 1..3 do
      assert {:appended, message} =
               Projection.append(ctx.db, %{
                 session_key: ctx.outside_session,
                 role: "user",
                 content: "other work #{index}",
                 sender: "user:flynn"
               })

      assert {:ok, seq} =
               Ledger.enqueue(ctx.db, %{
                 session_key: ctx.outside_session,
                 message_id: message.id,
                 origin: "user:flynn",
                 prompt: message.content
               })

      assert {:ok, turn} = Ledger.claim_next(ctx.db, ctx.outside_session, "sequence-skew")
      assert turn.seq == seq
      assert :ok = Ledger.finish(ctx.db, seq, "delivered", nil, owner_lease: turn.owner_lease)
    end

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: child.session,
               principal: {:session, child.session},
               description: "idle route identity evidence",
               evidence_mode: "exact_error",
               observed_state: "provider route failed",
               exact_observed_error: "route reset",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "idle-route-identity"
             })

    expected_wake = "other-review:#{opened.id}:#{parent_session}"

    assert {:ok, [[turn_seq, message_seq]]} =
             DB.query(
               ctx.db,
               """
               SELECT t.seq,m.seq FROM turns t JOIN messages m ON m.id=t.messageId
               WHERE t.sessionKey=?1 AND t.wakeId=?2
               """,
               [parent_session, expected_wake]
             )

    assert message_seq > turn_seq

    # Make the wrong message sequence name a real, unrelated terminal turn.
    for expected_seq <- (turn_seq + 1)..message_seq do
      assert {:appended, message} =
               Projection.append(ctx.db, %{
                 session_key: ctx.outside_session,
                 role: "user",
                 content: "false witness #{expected_seq}",
                 sender: "user:flynn"
               })

      assert {:ok, seq} =
               Ledger.enqueue(ctx.db, %{
                 session_key: ctx.outside_session,
                 message_id: message.id,
                 origin: "user:flynn",
                 prompt: message.content
               })

      assert seq == expected_seq
      assert {:ok, unrelated} = Ledger.claim_next(ctx.db, ctx.outside_session, "false-witness")
      assert unrelated.seq == seq

      assert :ok =
               Ledger.finish(ctx.db, seq, "delivered", nil, owner_lease: unrelated.owner_lease)
    end

    assert {:ok, [["delivered", outside]]} =
             DB.query(ctx.db, "SELECT status,sessionKey FROM turns WHERE seq=?1", [message_seq])

    assert outside == ctx.outside_session

    assert {:ok, [["pending", ^turn_seq, ^expected_wake]]} =
             DB.query(
               ctx.db,
               "SELECT state,turnSeq,noticeWakeId FROM harness_health_other_routes WHERE incidentId=?1 AND recipient=?2 ORDER BY ordinal LIMIT 1",
               [opened.id, parent_session]
             )

    # Restart reconciliation must not settle against the unrelated delivered turn
    # or publish a later rung while the actual recipient still has queued work.
    assert {:ok, queued_turns} = DB.query(ctx.db, "SELECT * FROM turns ORDER BY seq")
    assert :ok = HarnessHealth.resume_other_routes(ctx.db)
    assert :ok = HarnessHealth.resume_other_routes(ctx.db)
    assert {:ok, ^queued_turns} = DB.query(ctx.db, "SELECT * FROM turns ORDER BY seq")

    assert {:ok, [["pending", ^turn_seq]]} =
             DB.query(
               ctx.db,
               "SELECT state,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND recipient=?2 ORDER BY ordinal LIMIT 1",
               [opened.id, parent_session]
             )

    assert {:ok, turn} = Ledger.claim_next(ctx.db, parent_session, "idle-health-route")
    assert turn.seq == turn_seq
    assert :ok = Ledger.finish(ctx.db, turn.seq, "failed", nil, owner_lease: turn.owner_lease)
    assert :ok = HarnessHealth.resume_other_routes(ctx.db)

    assert {:ok, [["non_delivered", "failed"]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason FROM harness_health_other_routes WHERE incidentId=?1 AND recipient=?2 ORDER BY ordinal LIMIT 1",
               [opened.id, parent_session]
             )
  end

  test "a busy other-route recipient keeps the recovery notice as a source until ready", ctx do
    registry = :"health_batch_registry_#{System.unique_integer([:positive])}"
    lane = :"health_batch_lane_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.ConnRegistry, name: registry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, lane})

    [child, parent | _] = ctx.sessions
    parent_session = parent.session
    at = System.system_time(:millisecond)

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
               child.session,
               parent.session
             ])

    {:appended, current_message} =
      Projection.append(ctx.db, %{
        session_key: parent.session,
        role: "user",
        content: "current bounded work",
        sender: "session:#{parent.session}"
      })

    {:ok, current_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: parent.session,
        message_id: current_message.id,
        origin: "session:#{parent.session}",
        prompt: "current bounded work"
      })

    assert {:ok, %{seq: ^current_seq, owner_lease: lease}} =
             Ledger.claim_next(ctx.db, parent.session, "other-route-batching")

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: child.session,
               principal: {:session, child.session},
               description: "busy route batching evidence",
               evidence_mode: "exact_error",
               observed_state: "provider route failed",
               exact_observed_error: "busy route reset",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "busy-route-batching"
             })

    expected_wake_id = "other-review:#{opened.id}:#{parent_session}"

    assert {:ok, [["pending", nil, ^expected_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT state,turnSeq,noticeWakeId FROM harness_health_other_routes WHERE incidentId=?1 AND recipient=?2 ORDER BY ordinal LIMIT 1",
               [opened.id, parent_session]
             )

    assert {:ok, [["pending", "fyi", "notice-batching-v1 r2"]]} =
             DB.query(
               ctx.db,
               "SELECT state,class,deliveryRule FROM wakes WHERE wakeId=?1",
               [expected_wake_id]
             )

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [expected_wake_id])

    assert :ok = Ledger.finish(ctx.db, current_seq, "delivered", nil, owner_lease: lease)
    original_prompt = Wakes.get(ctx.db, expected_wake_id).prompt

    [carrier_id] =
      Tightbeam.NoticeBatcher.recover(ctx.db, at + 1_000,
        conn_registry: registry,
        lane_manager: lane
      )

    carrier = Wakes.get(ctx.db, carrier_id)

    assert carrier.state == "fired"
    assert carrier_id != expected_wake_id
    assert Wakes.get(ctx.db, expected_wake_id).state == "fired"
    assert Wakes.get(ctx.db, expected_wake_id).prompt == original_prompt

    assert [%{delivery_wake_id: ^carrier_id, member_state: "included", batch_state: "delivered"}] =
             Tightbeam.NoticeBatcher.source_refs(ctx.db, expected_wake_id)

    assert {:ok, [[turn_seq, "queued", ^parent_session, content]]} =
             DB.query(
               ctx.db,
               "SELECT t.seq,t.status,t.sessionKey,m.content FROM turns t JOIN messages m ON m.id=t.messageId WHERE t.wakeId=?1",
               [carrier_id]
             )

    assert content =~ original_prompt

    # Delivery persists the receipt but does not mutate the source owner's route.
    # The boot recovery path must bind it even if no delivery callback survived.
    assert Wakes.get(ctx.db, expected_wake_id).delivered_turn_seq == turn_seq

    assert {:ok, [[nil]]} =
             DB.query(
               ctx.db,
               "SELECT turnSeq FROM harness_health_other_routes WHERE noticeWakeId=?1",
               [expected_wake_id]
             )

    assert {:ok, before_turns} = DB.query(ctx.db, "SELECT * FROM turns ORDER BY seq")
    assert {:ok, before_messages} = DB.query(ctx.db, "SELECT * FROM messages ORDER BY seq")

    assert :ok = HarnessHealth.resume_other_routes(ctx.db)
    assert :ok = HarnessHealth.resume_other_routes(ctx.db)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [expected_wake_id])

    assert {:ok, {:duplicate, %{wake_id: ^carrier_id, turn_seq: ^turn_seq}}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 carrier.session_key,
                 carrier.origin,
                 carrier.prompt,
                 wake_id: carrier.wake_id,
                 sender: carrier.origin,
                 target_gate: carrier,
                 fire_wake_in_txn: true
               )
             end)

    assert {:ok, ^before_turns} = DB.query(ctx.db, "SELECT * FROM turns ORDER BY seq")
    assert {:ok, ^before_messages} = DB.query(ctx.db, "SELECT * FROM messages ORDER BY seq")

    assert {:ok, [["pending", ^turn_seq, ^expected_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT state,turnSeq,noticeWakeId FROM harness_health_other_routes WHERE incidentId=?1 AND recipient=?2 ORDER BY ordinal LIMIT 1",
               [opened.id, parent.session]
             )
  end

  for clearing <- [:resolved, :expired] do
    test "a #{clearing} incident retracts its undelivered review notice", ctx do
      registry = :"health_clear_registry_#{System.unique_integer([:positive])}"
      lane = :"health_clear_lane_#{System.unique_integer([:positive])}"
      start_supervised!({Tightbeam.ConnRegistry, name: registry})
      start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, lane})

      [child, parent | _] = ctx.sessions
      parent_session = parent.session
      at = System.system_time(:millisecond)

      assert {:ok, []} =
               DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
                 child.session,
                 parent.session
               ])

      {:appended, current_message} =
        Projection.append(ctx.db, %{
          session_key: parent.session,
          role: "user",
          content: "current bounded work",
          sender: "session:#{parent.session}"
        })

      {:ok, current_seq} =
        Ledger.enqueue(ctx.db, %{
          session_key: parent.session,
          message_id: current_message.id,
          origin: "session:#{parent.session}",
          prompt: "current bounded work"
        })

      assert {:ok, %{seq: ^current_seq, owner_lease: lease}} =
               Ledger.claim_next(ctx.db, parent.session, "other-route-clearing")

      assert {:opened, opened} =
               HarnessHealth.observe_other(ctx.db, %{
                 harness: "claude",
                 host: "testhost",
                 source_session_key: child.session,
                 principal: {:session, child.session},
                 description: "clearing route evidence",
                 evidence_mode: "exact_error",
                 observed_state: "provider route failed",
                 exact_observed_error: "clearing route reset",
                 exact_probe: "provider health probe",
                 recovery_condition: "a normal provider turn completes",
                 not_known_class_reason: "not one of the named classes",
                 observed_at: at,
                 accepted_at: at,
                 valid_until: at + 500,
                 world_status: "UNKNOWN",
                 redaction_confirmed: true,
                 idempotency_key: "clearing-route"
               })

      wake_id = "other-review:#{opened.id}:#{parent_session}"
      assert Wakes.get(ctx.db, wake_id).state == "pending"

      case unquote(clearing) do
        :resolved ->
          probe = "normal turn #{at + 1} delivered"

          assert {:resolved, _} =
                   HarnessHealth.resolve_other(ctx.db, %{
                     harness: "claude",
                     host: "testhost",
                     incident_id: opened.id,
                     session_key: child.session,
                     principal: {:session, child.session},
                     observed_state: "normal turn delivered",
                     exact_probe: probe,
                     output_digest: :crypto.hash(:sha256, probe) |> Base.encode16(case: :lower),
                     recovery_condition_digest:
                       :crypto.hash(:sha256, "a normal provider turn completes")
                       |> Base.encode16(case: :lower),
                     recovery_satisfied: true,
                     world_status: "PROVEN",
                     redaction_confirmed: true,
                     cause: "normal turn delivered",
                     observed_at: at + 1,
                     accepted_at: at + 1,
                     idempotency_key: "clearing-route-recovery"
                   })

        :expired ->
          assert {:ok, :available} =
                   DB.transaction(ctx.db, fn txn ->
                     HarnessHealth.prod_shape_gate_in_txn(txn, "claude", "testhost", at + 1_000)
                   end)
      end

      assert Wakes.get(ctx.db, wake_id).state == "canceled"

      assert {:ok,
              [
                [
                  "tightbeam:harness-health",
                  "condition_cleared",
                  "harness_health_transition",
                  causal_id
                ]
              ]} =
               DB.query(
                 ctx.db,
                 "SELECT requesterId,reasonKind,causalSourceKind,causalSourceId FROM wake_cancellations WHERE wakeId=?1",
                 [wake_id]
               )

      assert causal_id == opened.id

      assert :ok = Ledger.finish(ctx.db, current_seq, "delivered", nil, owner_lease: lease)

      Tightbeam.NoticeBatcher.recover(ctx.db, at + 2_000,
        conn_registry: registry,
        lane_manager: lane
      )

      refute Enum.any?(
               Tightbeam.NoticeBatcher.source_refs(ctx.db, wake_id),
               &(&1.member_state == "included")
             )

      assert {:ok, [[0]]} =
               DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake_id])
    end
  end

  test "non-delivered route settlement publishes the next rung once", ctx do
    [child, parent | _] = ctx.sessions
    at = System.system_time(:millisecond)

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
               child.session,
               parent.session
             ])

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: child.session,
               principal: {:session, child.session},
               description: "route settlement evidence",
               evidence_mode: "exact_error",
               observed_state: "provider route failed",
               exact_observed_error: "route reset",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "route-settlement"
             })

    assert {:ok, [[first_recipient, first_ordinal, "pending", first_turn_seq, first_wake]]} =
             DB.query(
               ctx.db,
               "SELECT recipient,ordinal,state,turnSeq,noticeWakeId FROM harness_health_other_routes WHERE incidentId=?1 AND state='pending' ORDER BY ordinal LIMIT 1",
               [opened.id]
             )

    assert is_binary(first_recipient)
    assert is_integer(first_turn_seq)
    assert is_binary(first_wake)
    expected_request_ref = "other-review:#{opened.id}"
    expected_wake_id = "other-review:#{opened.id}:#{first_recipient}"

    assert {:ok, [[^expected_request_ref, ^expected_wake_id]]} =
             DB.query(ctx.db, "SELECT requestRef,wakeId FROM turns WHERE seq=?1", [first_turn_seq])

    assert {:ok, %{seq: ^first_turn_seq, owner_lease: first_turn_seq_lease}} =
             Ledger.claim_next(ctx.db, first_recipient, "route-settlement")

    assert :ok =
             Ledger.finish(ctx.db, first_turn_seq, "failed", nil,
               owner_lease: first_turn_seq_lease
             )

    assert :ok = HarnessHealth.resume_other_routes(ctx.db)

    assert {:ok, [["non_delivered", "failed"]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=?2",
               [opened.id, first_ordinal]
             )

    assert {:ok, [[second_recipient, second_ordinal, "pending", second_wake, second_turn]]} =
             DB.query(
               ctx.db,
               "SELECT recipient,ordinal,state,noticeWakeId,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND state='pending' AND ordinal>?2 ORDER BY ordinal LIMIT 1",
               [opened.id, first_ordinal]
             )

    assert second_ordinal > first_ordinal
    assert is_binary(second_wake)
    assert is_integer(second_turn)
    expected_second_wake = "other-review:#{opened.id}:#{second_recipient}"

    assert {:ok, [[^expected_request_ref, ^expected_second_wake]]} =
             DB.query(ctx.db, "SELECT requestRef,wakeId FROM turns WHERE seq=?1", [second_turn])

    assert :ok = HarnessHealth.resume_other_routes(ctx.db)

    assert {:ok, [["pending", ^second_wake, ^second_turn]]} =
             DB.query(
               ctx.db,
               "SELECT state,noticeWakeId,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=?2",
               [opened.id, second_ordinal]
             )
  end

  test "restart resume publishes an unmarked rung once and does not replay it", ctx do
    [child, parent | _] = ctx.sessions
    at = System.system_time(:millisecond)

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
               child.session,
               parent.session
             ])

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: child.session,
               principal: {:session, child.session},
               description: "restart route evidence",
               evidence_mode: "exact_error",
               observed_state: "provider route failed",
               exact_observed_error: "restart reset",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "restart-route"
             })

    request_ref = "other-review:#{opened.id}"

    assert {:ok, [[route_recipient, first_state, first_wake, first_turn]]} =
             DB.query(
               ctx.db,
               "SELECT recipient,state,noticeWakeId,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=0",
               [opened.id]
             )

    assert is_binary(route_recipient)
    assert first_state == "pending"
    assert is_binary(first_wake)
    assert is_integer(first_turn)

    assert {:ok, %{seq: ^first_turn, owner_lease: first_turn_lease}} =
             Ledger.claim_next(ctx.db, route_recipient, "restart-recovery")

    assert :ok = Ledger.finish(ctx.db, first_turn, "failed", nil, owner_lease: first_turn_lease)
    assert first_wake == "other-review:#{opened.id}:#{route_recipient}"

    assert {:ok, [[^request_ref, ^first_wake]]} =
             DB.query(ctx.db, "SELECT requestRef,wakeId FROM turns WHERE seq=?1", [first_turn])

    assert :ok = HarnessHealth.resume_other_routes(ctx.db)

    assert {:ok, [["non_delivered", "failed", next_wake, next_turn]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason,noticeWakeId,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=0",
               [opened.id]
             )

    assert next_wake == first_wake
    assert next_turn == first_turn

    assert {:ok, [[second_recipient, "pending", second_wake, second_turn]]} =
             DB.query(
               ctx.db,
               "SELECT recipient,state,noticeWakeId,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=2",
               [opened.id]
             )

    assert is_binary(second_wake)
    assert is_integer(second_turn)
    assert is_binary(second_recipient)
    assert second_wake == "other-review:#{opened.id}:#{second_recipient}"

    assert {:ok, [[^request_ref, ^second_wake]]} =
             DB.query(ctx.db, "SELECT requestRef,wakeId FROM turns WHERE seq=?1", [second_turn])

    assert :ok = HarnessHealth.resume_other_routes(ctx.db)

    assert {:ok, [["pending", ^second_wake, ^second_turn]]} =
             DB.query(
               ctx.db,
               "SELECT state,noticeWakeId,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=2",
               [opened.id]
             )
  end

  test "record-only fallback settles without a wake or turn token", ctx do
    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
               ctx.main_session
             ])

    [member | _] = ctx.sessions
    at = System.system_time(:millisecond)

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: member.session,
               principal: {:session, member.session},
               description: "record-only route evidence",
               evidence_mode: "exact_error",
               observed_state: "provider route failed",
               exact_observed_error: "no owner turn",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "record-only-route"
             })

    assert {:ok, [["alerted", "no_active_main", nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason,noticeWakeId,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND targetKind='owner_user'",
               [opened.id]
             )

    assert ConditionFacts.standing?(ctx.db, "user-alerted", "flynn")

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='user-alerted' AND scope='flynn'"
             )

    assert {:duplicate, _} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: member.session,
               principal: {:session, member.session},
               description: "record-only route evidence",
               evidence_mode: "exact_error",
               observed_state: "provider route failed",
               exact_observed_error: "no owner turn",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "record-only-route"
             })

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='user-alerted' AND scope='flynn'"
             )
  end

  test "other route rows reject deletion, skipped transition, and terminal timestamp mutation",
       ctx do
    [member | _] = ctx.sessions
    at = System.system_time(:millisecond)

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: member.session,
               principal: {:session, member.session},
               description: "route guard evidence",
               evidence_mode: "exact_error",
               observed_state: "provider route failed",
               exact_observed_error: "route guard",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "route-guards"
             })

    assert {:ok, [[ordinal, recipient, "pending", turn_seq]]} =
             DB.query(
               ctx.db,
               "SELECT ordinal,recipient,state,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND state='pending' LIMIT 1",
               [opened.id]
             )

    assert {:error, _} =
             DB.query(ctx.db, "DELETE FROM harness_health_other_routes WHERE incidentId=?1", [
               opened.id
             ])

    assert {:error, _} =
             DB.query(
               ctx.db,
               "UPDATE harness_health_other_routes SET state='skipped',closedReason='manual' WHERE incidentId=?1 AND ordinal=?2",
               [opened.id, ordinal]
             )

    assert {:ok, %{seq: ^turn_seq, owner_lease: turn_seq_lease}} =
             Ledger.claim_next(ctx.db, recipient, "route-guards")

    assert :ok = Ledger.finish(ctx.db, turn_seq, "delivered", nil, owner_lease: turn_seq_lease)
    assert :ok = HarnessHealth.resume_other_routes(ctx.db)

    assert {:error, _} =
             DB.query(
               ctx.db,
               "UPDATE harness_health_other_routes SET settledAt=settledAt+1 WHERE incidentId=?1 AND ordinal=?2",
               [opened.id, ordinal]
             )
  end

  test "promotion review cannot be selected for a first occurrence", ctx do
    [member | _] = ctx.sessions
    at = System.system_time(:millisecond)

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: member.session,
               principal: {:session, member.session},
               description: "promotion requires recurrence",
               evidence_mode: "exact_error",
               observed_state: "provider failed",
               exact_observed_error: "transport reset",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "promotion-first-occurrence"
             })

    assert {:error, %{code: "promotion_required"}} =
             HarnessHealth.review_other(ctx.db, %{
               incident_id: opened.id,
               outcome: "promotion_required",
               cause: "promotion requires a second occurrence",
               principal: {:session, member.session},
               idempotency_key: "promotion-first-review"
             })
  end

  test "first reclassification accepts known classes but rejects new promotion classes", ctx do
    [member | _] = ctx.sessions
    at = System.system_time(:millisecond)

    assert {:opened, known_incident} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: member.session,
               principal: {:session, member.session},
               description: "known-class first reclassification",
               evidence_mode: "exact_error",
               observed_state: "provider failed",
               exact_observed_error: "known class",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "review found a named class",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "known-class-first-reclassification"
             })

    assert {:ok, %{outcome: "reclassified"}} =
             HarnessHealth.review_other(ctx.db, %{
               incident_id: known_incident.id,
               outcome: "reclassified",
               named_class: "auth-dead",
               cause: "known class confirmed",
               principal: {:session, member.session},
               idempotency_key: "known-class-first-review"
             })

    assert {:opened, new_incident} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: member.session,
               principal: {:session, member.session},
               description: "new-class first reclassification",
               evidence_mode: "exact_error",
               observed_state: "provider failed",
               exact_observed_error: "new class",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at + 1,
               accepted_at: at + 1,
               valid_until: at + 501,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "new-class-first-reclassification"
             })

    assert {:error, %{code: "invalid_review_outcome"}} =
             HarnessHealth.review_other(ctx.db, %{
               incident_id: new_incident.id,
               outcome: "reclassified",
               named_class: "provider-network-drift",
               cause: "new class requires recurrence promotion",
               principal: {:session, member.session},
               idempotency_key: "new-class-first-review"
             })
  end

  test "public recurrence promotion closes a new class only from bound review bytes", ctx do
    [member | _] = ctx.sessions
    at = System.system_time(:millisecond)
    description = "recurring public promotion evidence"

    common = %{
      harness: "claude",
      host: "testhost",
      source_session_key: member.session,
      principal: {:session, member.session},
      description: description,
      evidence_mode: "exact_error",
      observed_state: "provider route failed",
      exact_observed_error: "recurring reset",
      exact_probe: "provider health probe",
      recovery_condition: "a normal provider turn completes",
      not_known_class_reason: "not one of the named classes",
      world_status: "UNKNOWN",
      redaction_confirmed: true
    }

    assert {:opened, first} =
             HarnessHealth.observe_other(
               ctx.db,
               Map.merge(common, %{
                 observed_at: at - 100,
                 accepted_at: at - 100,
                 valid_until: at - 1,
                 idempotency_key: "public-promotion-first"
               })
             )

    handlers = Gateway.handlers(%{db: ctx.db})

    assert %{ok: true, status: :opened, incident: second} =
             handlers["harness-health-observe-other"].(%{
               principal: {:session, member.session},
               session_key: member.session,
               params:
                 Map.merge(common, %{
                   observed_at: at,
                   accepted_at: at,
                   valid_until: at + 500,
                   idempotency_key: "public-promotion-second"
                 })
             })

    assert first.id != second.id

    assert {:ok, [[promotion_id]]} =
             DB.query(
               ctx.db,
               "SELECT promotionCaseId FROM harness_health_other_reviews WHERE incidentId=?1",
               [second.id]
             )

    assert is_binary(promotion_id)

    assert %{ok: true, review: %{state: "closed", outcome: "promotion_required"}} =
             handlers["harness-health-review-other"].(%{
               principal: {:session, member.session},
               params: %{
                 incident_id: second.id,
                 outcome: "promotion_required",
                 cause: "recurrence requires a named-class promotion",
                 idempotency_key: "public-promotion-review"
               }
             })

    work_item_id = "wi_public_promotion"
    candidate_id = "asg_public_promotion_candidate"
    review_id = "asg_public_promotion_review"
    spec_id = "art_public_promotion_spec"
    report_id = "art_public_promotion_report"
    attest_id = "att_public_promotion_clean"
    spec_sha = String.duplicate("a", 64)
    report_sha = String.duplicate("b", 64)
    candidate_commit = String.duplicate("c", 40)
    second_candidate_commit = String.duplicate("d", 40)

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO work_items(id,title,specRefName,specRefSha256,ownerUserId,createdByUser,createdAt) VALUES(?1,'public promotion','tightbeam-specs/public-promotion.md',?2,'flynn','flynn',?3)",
               [work_item_id, spec_sha, at]
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state,workItemId) VALUES(?1,'candidate',?2,'flynn',?3,'open',?4)",
               [candidate_id, member.session, at, work_item_id]
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,state,workItemId,reviewsAssignmentId) VALUES(?1,'independent review',?2,'flynn',?3,'open',?4,?5)",
               [review_id, ctx.outside_session, at, work_item_id, candidate_id]
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO artifacts(artifactId,kind,title,createdBySession,workItemId,originPath,contentSha256,state,createdAt,updatedAt) VALUES(?1,'spec','reviewed spec',?2,?3,'tightbeam-specs/public-promotion.md',?4,'in-workspace',?5,?5)",
               [spec_id, member.session, work_item_id, spec_sha, at]
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO artifacts(artifactId,kind,title,createdBySession,workItemId,originPath,contentSha256,state,createdAt,updatedAt) VALUES(?1,'report','reviewed report',?2,?3,'reports/public-promotion.md',?4,'in-workspace',?5,?5)",
               [report_id, ctx.outside_session, work_item_id, report_sha, at]
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO attests(id,assignmentId,kind,verdictKind,bySession,commitRefs,artifactId,contentSha256,ts) VALUES(?1,?2,'verdict','reviewed-clean',?3,?4,?5,?6,?7)",
               [
                 attest_id,
                 review_id,
                 ctx.outside_session,
                 JSON.encode!([
                   %{"repo" => "node-b", "commit" => candidate_commit},
                   %{"repo" => "node-b", "commit" => second_candidate_commit}
                 ]),
                 report_id,
                 report_sha,
                 at
               ]
             )

    unrelated_spec_id = "art_public_promotion_unrelated_spec"

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO artifacts(artifactId,kind,title,createdBySession,workItemId,originPath,contentSha256,state,createdAt,updatedAt) VALUES(?1,'spec','unrelated spec',?2,?3,'tightbeam-specs/unrelated.md',?4,'in-workspace',?5,?5)",
               [unrelated_spec_id, member.session, work_item_id, String.duplicate("d", 64), at]
             )

    close_params = %{
      promotion_id: promotion_id,
      named_class: "provider-network-drift",
      spec_artifact_id: spec_id,
      review_artifact_id: report_id,
      review_attest_id: attest_id,
      review_assignment_id: review_id,
      candidate_commit: candidate_commit,
      idempotency_key: "public-promotion-close"
    }

    assert %{code: "invalid_promotion_close", message: "invalid_promotion_close"} =
             handlers["harness-health-close-promotion"].(%{
               principal: {:user, "flynn"},
               params:
                 Map.merge(close_params, %{
                   named_class: "auth-dead",
                   idempotency_key: "public-promotion-existing-class"
                 })
             })

    assert %{code: "invalid_promotion_close", message: "invalid_promotion_close"} =
             handlers["harness-health-close-promotion"].(%{
               principal: {:user, "flynn"},
               params:
                 Map.merge(close_params, %{
                   spec_artifact_id: unrelated_spec_id,
                   idempotency_key: "public-promotion-unrelated-spec"
                 })
             })

    assert %{code: "not_authorized", message: "not_authorized"} =
             handlers["harness-health-close-promotion"].(%{
               principal: "process:tightbeam",
               params: close_params
             })

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE assignments SET holderKey=?1 WHERE id=?2", [
               member.session,
               review_id
             ])

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE attests SET bySession=?1 WHERE id=?2", [
               member.session,
               attest_id
             ])

    assert %{code: "invalid_promotion_close", message: "invalid_promotion_close"} =
             handlers["harness-health-close-promotion"].(%{
               principal: {:user, "flynn"},
               params: %{close_params | idempotency_key: "public-promotion-same-holder"}
             })

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE assignments SET holderKey=?1 WHERE id=?2", [
               ctx.outside_session,
               review_id
             ])

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE attests SET bySession=?1 WHERE id=?2", [
               ctx.outside_session,
               attest_id
             ])

    assert %{
             ok: true,
             promotion: %{
               state: "closed",
               namedClass: "provider-network-drift",
               reviewAttestId: ^attest_id
             }
           } =
             handlers["harness-health-close-promotion"].(%{
               principal: {:user, "flynn"},
               params: close_params
             })

    assert %{ok: true, promotion: duplicate} =
             handlers["harness-health-close-promotion"].(%{
               principal: {:user, "flynn"},
               params: close_params
             })

    assert duplicate["promotionId"] == promotion_id
    assert duplicate["state"] == "closed"
    assert duplicate["namedClass"] == "provider-network-drift"
    assert duplicate["reviewAttestId"] == attest_id

    assert %{code: "idempotency_conflict", message: "idempotency_conflict"} =
             handlers["harness-health-close-promotion"].(%{
               principal: {:user, "flynn"},
               params: %{close_params | candidate_commit: second_candidate_commit}
             })

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "UPDATE artifacts SET contentSha256=?1 WHERE artifactId=?2",
               [String.duplicate("e", 64), report_id]
             )

    assert %{code: "invalid_promotion_close", message: "invalid_promotion_close"} =
             handlers["harness-health-close-promotion"].(%{
               principal: {:user, "flynn"},
               params: %{close_params | idempotency_key: "public-promotion-mutated-report"}
             })
  end

  test "captured terminal errors preserve auth, rate-limit, and unrelated classes" do
    assert HarnessHealth.classify_turn_failure(@captured_codex_rate_limit) == "rate-limit-dead"
    assert HarnessHealth.classify_turn_failure(@captured_claude_rate_limit) == "rate-limit-dead"

    assert HarnessHealth.classify_turn_failure(%{
             "message" => "Internal error",
             "data" => %{"details" => "auth expired"}
           }) == "auth-dead"

    assert HarnessHealth.classify_turn_failure(%{
             "status" => 429,
             "message" => "too many requests"
           }) ==
             "rate-limit-dead"

    assert HarnessHealth.classify_turn_failure({:acp_exit, 137}) == nil
    assert HarnessHealth.classify_turn_failure(%{"message" => "model not found"}) == nil
  end

  test "captured terminal errors preserve every typed repair class" do
    assert HarnessHealth.classify_turn_failure(%{"message" => "model unavailable"}) ==
             "model_unavailable"

    assert HarnessHealth.classify_turn_failure(%{code: "adapter_unavailable"}) ==
             "adapter_unavailable"

    assert HarnessHealth.classify_turn_failure(:task_crash) == "task_crash"

    assert HarnessHealth.classify_turn_failure("interrupted: outcome unknown") ==
             "interrupted-outcome-unknown"
  end

  test "each incident exposes its sanctioned repair route", ctx do
    [member | _] = ctx.sessions

    expected = %{
      "adapter_unavailable" => "restart",
      "model_unavailable" => "tune",
      "task_crash" => "restart",
      "interrupted-outcome-unknown" => "rerun"
    }

    Enum.each(expected, fn {failure_class, action} ->
      assert {:opened, opened} =
               HarnessHealth.observe(
                 ctx.db,
                 authoritative(member, failure_class, 50, "route-#{failure_class}")
               )

      assert HarnessHealth.get(ctx.db, opened.id).repair.action == action
    end)
  end

  test "provider invalidation emits one consolidated auth blocker while rate limiting emits none",
       ctx do
    main_key = ctx.main_session
    second_main_key = Org.personal_session_key("zoe")
    second_worker_key = "agent:harness-health:zoe"

    Org.create(ctx.db, %{
      session_key: second_main_key,
      display_name: "Second main",
      kind: "main",
      owner_user_id: "zoe",
      origin: "user:zoe",
      archetype: "default",
      host: "testhost",
      harness: "codex",
      provider: "openai",
      model: Model.new("gpt-5")
    })

    Org.create(ctx.db, %{
      session_key: second_worker_key,
      display_name: "Second affected worker",
      owner_user_id: "zoe",
      origin: "user:zoe",
      archetype: "coder",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               INSERT INTO assignments
                 (id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
               VALUES ('asg_health_zoe','second affected work',?1,?1,5,'open','claude','anthropic')
               """,
               [second_worker_key]
             )

    assert {:opened, auth} =
             HarnessHealth.observe_provider_invalidation(
               ctx.db,
               "claude",
               "testhost",
               %{"authMode" => nil, "planType" => nil},
               conn_registry: :missing_harness_health_registry
             )

    assert {:attached, attached} =
             HarnessHealth.observe_provider_invalidation(
               ctx.db,
               "claude",
               "testhost",
               %{"authMode" => nil, "planType" => nil},
               conn_registry: :missing_harness_health_registry
             )

    assert attached.id == auth.id
    assert [marker] = Projection.list_after(ctx.db, main_key, nil, 10)
    assert marker.attention_tier == 1
    assert marker.content =~ auth.id
    assert marker.content =~ "A human must restore this credential"
    assert Projection.list_after(ctx.db, second_main_key, nil, 10) == []

    for session_key <- [second_worker_key | Enum.map(ctx.sessions, & &1.session)] do
      assert Projection.list_after(ctx.db, session_key, nil, 10) == []
    end

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harness_health_auth_blocker")
           ) ==
             1

    assert {:opened, _rate} =
             HarnessHealth.observe(
               ctx.db,
               authoritative(hd(ctx.sessions), "rate-limit-dead", 20, "provider-rate-only")
             )

    assert [_marker] = Projection.list_after(ctx.db, main_key, nil, 10)

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harness_health_auth_blocker")
           ) ==
             1
  end

  test "memberless provider invalidation alerts an ambient owner before late work attaches",
       ctx do
    quiet_host = "quiet-host"

    assert {:opened, opened} =
             HarnessHealth.observe_provider_invalidation(
               ctx.db,
               "claude",
               quiet_host,
               %{"authMode" => nil, "planType" => nil},
               conn_registry: :missing_harness_health_registry
             )

    assert [marker] = Projection.list_after(ctx.db, ctx.main_session, nil, 10)
    assert marker.content =~ opened.id
    assert HarnessHealth.get(ctx.db, opened.id).affectedSessions == []

    late_session = "agent:harness-health:late"
    late_assignment = "asg_health_late"

    Org.create(ctx.db, %{
      session_key: late_session,
      display_name: "Late affected worker",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "coder",
      host: quiet_host,
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               INSERT INTO assignments
                 (id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
               VALUES (?1,'late affected work',?2,?2,12,'open','claude','anthropic')
               """,
               [late_assignment, late_session]
             )

    assert {:attached, attached} =
             HarnessHealth.observe(ctx.db, %{
               harness: "claude",
               host: quiet_host,
               failure_class: "auth-dead",
               evidence_kind: "authoritative-provider",
               session_key: late_session,
               assignment_id: late_assignment,
               observed_at: 13,
               correlation_id: "late-member-auth",
               cause: "terminal recovery-chain failure",
               principal: "process:tightbeam"
             })

    assert attached.id == opened.id
    assert [^late_session] = HarnessHealth.get(ctx.db, opened.id).affectedSessions
    assert [^late_assignment] = HarnessHealth.get(ctx.db, opened.id).affectedAssignments
    assert [_marker] = Projection.list_after(ctx.db, ctx.main_session, nil, 10)

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harness_health_auth_blocker")
           ) == 1
  end

  test "boot recovery commits the batch when an owner turn carries a child assignment", ctx do
    [child, other | _] = ctx.sessions
    owner = ctx.main_session

    running =
      for {key, assignment} <- [{owner, child.assignment}, {other.session, other.assignment}] do
        {:ok, seq} =
          Ledger.enqueue(ctx.db, %{
            session_key: key,
            message_id: "boot-running-#{key}",
            origin: "process:tightbeam",
            prompt: "interrupted",
            assignment_id: assignment
          })

        {:ok, turn} = Ledger.claim_next(ctx.db, key, "old-lane")
        assert turn.seq == seq

        {:ok, queued} =
          Ledger.enqueue(ctx.db, %{
            session_key: key,
            message_id: "boot-queued-#{key}",
            origin: "process:tightbeam",
            prompt: "later"
          })

        {key, assignment, seq, queued}
      end

    alias Tightbeam.Firehose.Hub
    :ok = DB.execute(ctx.db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('flynn',0,1)")
    hub = start_supervised!({Hub, name: Hub})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: false})

    before_sessions = Map.new(running, fn {key, _, _, _} -> {key, Org.get(ctx.db, key)} end)

    assert Enum.all?(before_sessions, fn {_, session} ->
             session.mechanical_status == "running"
           end)

    recovered = Ledger.recover_running(ctx.db)
    assert Enum.sort(recovered) == Enum.sort(Enum.map(running, &elem(&1, 2)))

    notices =
      for _ <- 1..2 do
        assert_receive {:firehose_notice, notice}
        Hub.delivered(hub, self())
        notice
      end

    terminal_notices = Enum.filter(notices, &(&1["class"] == "turn.ended"))
    assert length(terminal_notices) == 2
    assert Enum.sort(Enum.map(terminal_notices, & &1["refs"]["turnSeq"])) == Enum.sort(recovered)

    for {key, assignment, seq, _queued} <- running do
      notice = Enum.find(terminal_notices, &(&1["refs"]["turnSeq"] == seq))
      assert notice["refs"]["sessionKey"] == key
      assert notice["refs"]["assignmentId"] == assignment
      assert notice["payload"]["status"] == "failed_unknown"
      assert Org.get(ctx.db, key).mechanical_status == "running"
    end

    # Queued successors keep both sessions running: no public state or version changes.
    assert Enum.all?(notices, &(&1["class"] == "turn.ended"))

    assert Map.new(running, fn {key, _, _, _} -> {key, Org.get(ctx.db, key)} end) ==
             before_sessions

    refute_receive {:firehose_notice, _}
    assert Ledger.recover_running(ctx.db) == []
    refute_receive {:firehose_notice, _}

    for {key, assignment, seq, queued} <- running do
      assert {:ok, [["failed_unknown", ^assignment, ended_at, error]]} =
               DB.query(
                 ctx.db,
                 "SELECT status,assignmentId,endedAt,error FROM turns WHERE seq=?1",
                 [seq]
               )

      assert is_integer(ended_at)
      assert error == "interrupted: outcome unknown"
      expected_assignment = if key == owner, do: nil, else: assignment

      assert {:ok, [[^key, ^expected_assignment, nil]]} =
               DB.query(
                 ctx.db,
                 "SELECT sessionKey,assignmentId,incidentId FROM harness_health_observations WHERE correlationId=?1",
                 ["harness-turn:#{seq}:interrupted-outcome-unknown"]
               )

      {:ok, next} = Ledger.claim_next(ctx.db, key, "recovered-lane")
      assert next.seq == queued

      assert {:ok, true} =
               DB.transaction(ctx.db, fn txn ->
                 Ledger.finish_in_txn(txn, queued, "delivered", nil,
                   owner_lease: next.owner_lease
                 )
               end)

      assert Ledger.claim_next(ctx.db, key, "recovered-lane") == :none
    end

    assert {:ok, [[0]]} =
             DB.query(ctx.db, """
             SELECT count(*) FROM harness_health_observations h JOIN assignments a ON a.id=h.assignmentId
             WHERE a.holderKey != h.sessionKey
             """)
  end

  test "owner notification failure retains child cause without child health attribution", ctx do
    [child | _] = ctx.sessions
    owner = ctx.main_session
    session = Org.get(ctx.db, owner)

    for {suffix, reason} <- [
          {"quota", @captured_codex_rate_limit},
          {"provider", %{"data" => %{"details" => "auth expired"}}}
        ] do
      {:ok, seq} =
        Ledger.enqueue(ctx.db, %{
          session_key: owner,
          message_id: "owner-#{suffix}",
          origin: "process:tightbeam",
          prompt: "child result",
          assignment_id: child.assignment
        })

      {:ok, later} =
        Ledger.enqueue(ctx.db, %{
          session_key: owner,
          message_id: "later-#{suffix}",
          origin: "process:tightbeam",
          prompt: "later delivery"
        })

      {:ok, turn} = Ledger.claim_next(ctx.db, owner, "owner-lane")
      assert turn.seq == seq
      turn = Map.put(turn, :session_key, owner)

      assert {:ok, callback} =
               DB.transaction(ctx.db, fn txn ->
                 assert Ledger.finish_in_txn(txn, seq, "failed", "provider failure",
                          owner_lease: turn.owner_lease
                        )

                 HarnessHealth.observe_turn_failure_in_txn(txn, session, turn, :prompt, reason)
               end)

      if is_function(callback, 0), do: callback.()

      assert {:ok, [["failed", child_assignment]]} =
               DB.query(ctx.db, "SELECT status,assignmentId FROM turns WHERE seq=?1", [seq])

      assert child_assignment == child.assignment

      assert {:ok, [[^owner, nil]]} =
               DB.query(
                 ctx.db,
                 "SELECT sessionKey,assignmentId FROM harness_health_observations WHERE correlationId=?1",
                 ["harness-turn:#{seq}:#{HarnessHealth.classify_turn_failure(reason)}"]
               )

      {:ok, next} = Ledger.claim_next(ctx.db, owner, "owner-lane")
      assert next.seq == later

      assert {:ok, true} =
               DB.transaction(ctx.db, fn txn ->
                 Ledger.finish_in_txn(txn, later, "delivered", nil, owner_lease: next.owner_lease)
               end)
    end
  end

  test "failed-turn evidence and normal-turn recovery share their terminal CAS", ctx do
    [first, second, third] = ctx.sessions

    for {ref, message_id} <- [{first, "failed-1"}, {second, "failed-2"}] do
      {:ok, _seq} =
        Ledger.enqueue(ctx.db, %{
          session_key: ref.session,
          message_id: message_id,
          origin: "agent:test",
          prompt: "run",
          assignment_id: ref.assignment
        })

      {:ok, turn} = Ledger.claim_next(ctx.db, ref.session, "test-lane")
      turn = Map.put(turn, :session_key, ref.session)
      session = Org.get(ctx.db, ref.session)

      assert {:ok, post_commit} =
               DB.transaction(ctx.db, fn txn ->
                 assert Ledger.finish_in_txn(txn, turn.seq, "failed", "auth expired",
                          owner_lease: turn.owner_lease
                        )

                 HarnessHealth.observe_turn_failure_in_txn(
                   txn,
                   session,
                   turn,
                   :prompt,
                   %{
                     "message" => "Internal error",
                     "data" => %{"details" => "auth expired"}
                   }
                 )
               end)

      if is_function(post_commit, 0), do: post_commit.()
    end

    assert [incident] = HarnessHealth.active(ctx.db)
    assert incident.failureClass == "auth-dead"
    evidence = HarnessHealth.get(ctx.db, incident.id).observations

    assert evidence |> Enum.map(& &1.assignment_id) |> MapSet.new() ==
             MapSet.new([first.assignment, second.assignment])

    {:ok, queued_before_restore} =
      Ledger.enqueue(ctx.db, %{
        session_key: first.session,
        message_id: "queued-before-restoration",
        origin: "agent:queued",
        prompt: "already queued",
        assignment_id: first.assignment
      })

    {:ok, _seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: third.session,
        message_id: "healthy-turn",
        origin: "agent:test",
        prompt: "run",
        assignment_id: third.assignment
      })

    {:ok, turn} = Ledger.claim_next(ctx.db, third.session, "test-lane")
    turn = Map.put(turn, :session_key, third.session)
    session = Org.get(ctx.db, third.session)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "delivered", nil,
                        owner_lease: turn.owner_lease
                      )

               HarnessHealth.resolve_normal_turn_in_txn(txn, session, turn)
             end)

    assert HarnessHealth.active(ctx.db) == []
    assert HarnessHealth.get(ctx.db, incident.id).state == "resolved"
    refute HarnessHealth.unavailable?(ctx.db, "claude", "testhost")

    assert {:ok, [[first_source_seq]]} =
             DB.query(
               ctx.db,
               "SELECT seq FROM turns WHERE sessionKey=?1 AND messageId='failed-1' " <>
                 "AND status='failed'",
               [first.session]
             )

    assert {:ok, [[second_source_seq]]} =
             DB.query(
               ctx.db,
               "SELECT seq FROM turns WHERE sessionKey=?1 AND messageId='failed-2' " <>
                 "AND status='failed'",
               [second.session]
             )

    first_assignment = first.assignment
    second_assignment = second.assignment

    assert {:ok,
            [
              [
                ^queued_before_restore,
                "queued-before-restoration",
                nil,
                "agent:queued",
                "already queued",
                ^first_assignment
              ],
              [first_redelivery_seq, "failed-1", nil, "agent:test", "run", ^first_assignment]
            ]} =
             DB.query(
               ctx.db,
               """
               SELECT seq,messageId,wakeId,origin,prompt,assignmentId FROM turns
               WHERE sessionKey=?1 AND status='queued' ORDER BY seq
               """,
               [first.session]
             )

    assert {:ok,
            [[second_redelivery_seq, "failed-2", nil, "agent:test", "run", ^second_assignment]]} =
             DB.query(
               ctx.db,
               """
               SELECT seq,messageId,wakeId,origin,prompt,assignmentId FROM turns
               WHERE sessionKey=?1 AND status='queued' ORDER BY seq
               """,
               [second.session]
             )

    restoration_seq = turn.seq
    first_session_key = first.session
    second_session_key = second.session
    first_key = "health-redelivery:" <> JSON.encode!([first.session, first_source_seq])
    second_key = "health-redelivery:" <> JSON.encode!([second.session, second_source_seq])

    assert {:ok,
            [
              [
                ^first_key,
                first_session_key,
                ^first_source_seq,
                "failed-1",
                nil,
                "auth-dead",
                ^restoration_seq,
                ^first_redelivery_seq
              ],
              [
                ^second_key,
                second_session_key,
                ^second_source_seq,
                "failed-2",
                nil,
                "auth-dead",
                ^restoration_seq,
                ^second_redelivery_seq
              ]
            ]} =
             DB.query(
               ctx.db,
               """
               SELECT idempotencyKey,sessionKey,sourceTurnSeq,sourceMessageId,sourceWakeId,
                      failureClass,restorationTurnSeq,redeliveryTurnSeq
               FROM health_redelivery_attempts ORDER BY sessionKey
               """,
               []
             )

    assert {:ok, 0} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.redeliver_failed_intent_in_txn(txn, incident.id, "auth-dead", turn)
             end)

    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM health_redelivery_attempts")
  end

  @tag :tmp_dir
  test "once-only health redelivery survives restart and a second typed incident", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "harness_health_redelivery_restart.exs",
      "health-redelivery-restart: ok"
    )
  end

  test "text-classified auth failure without a typed carrier redelivers once as unclassified",
       ctx do
    [first, _second, healthy] = ctx.sessions
    first_session_key = first.session

    source =
      fail_health_turn!(
        ctx.db,
        first.session,
        "text-source-1",
        "original prompt 1",
        %{"code" => -32000, "message" => "Authentication required"}
      )

    assert {:ok, [["auth-dead"]]} =
             DB.query(
               ctx.db,
               "SELECT failureClass FROM harness_health_observations WHERE correlationId=?1",
               ["harness-turn:#{source.seq}:auth-dead"]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM health_redelivery_attempts " <>
                 "WHERE failureClass='unclassified' AND redeliveryTurnSeq IS NULL"
             )

    restoration = restore_health_turn!(ctx.db, healthy.session, "text-restoration")

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM health_redelivery_attempts " <>
                 "WHERE failureClass='unclassified' AND restorationTurnSeq=?1 " <>
                 "AND redeliveryTurnSeq IS NOT NULL",
               [restoration.seq]
             )

    assert {:ok,
            [
              [
                "text-source-1",
                ^first_session_key,
                "agent:health-redelivery",
                "original prompt 1"
              ]
            ]} =
             DB.query(
               ctx.db,
               "SELECT messageId,sessionKey,origin,prompt FROM turns " <>
                 "WHERE messageId=?1 AND status='queued'",
               ["text-source-1"]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE messageId=?1 AND status='failed'",
               ["text-source-1"]
             )
  end

  test "unclassified and compaction failures redeliver once on same-harness success", ctx do
    [first, second, healthy | _] = ctx.sessions

    fail_health_turn!(
      ctx.db,
      first.session,
      "unclassified-source",
      "original unclassified prompt",
      %{"code" => -32000, "message" => "internal protocol failure"}
    )

    fail_health_turn!(
      ctx.db,
      second.session,
      "compaction-source",
      "original compaction prompt",
      %{"code" => -32001, "message" => "compaction failed"}
    )

    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM health_redelivery_attempts")

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM health_redelivery_attempts " <>
                 "WHERE failureClass='unclassified' AND redeliveryTurnSeq IS NULL"
             )

    restoration = restore_health_turn!(ctx.db, healthy.session, "unclassified-restoration")

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE messageId='unclassified-source' AND status='queued'"
             )

    second_session_key = second.session

    assert {:ok, [[^second_session_key, "compaction-source", "original compaction prompt"]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,messageId,prompt FROM turns WHERE messageId='compaction-source' " <>
                 "AND status='queued' AND sessionKey=?1",
               [second_session_key]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE messageId='compaction-source' AND status='queued'"
             )

    healthy_session = Org.get(ctx.db, healthy.session)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               HarnessHealth.resolve_normal_turn_in_txn(
                 txn,
                 healthy_session,
                 restoration
               )
             end)

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE messageId IN " <>
                 "('unclassified-source','compaction-source') AND status='queued'"
             )
  end

  test "interrupted outcome without a parent redelivers once after same-harness success", ctx do
    [failed, _, healthy | _] = ctx.sessions

    source =
      fail_health_turn!(
        ctx.db,
        failed.session,
        "interrupted-parentless-source",
        "original interrupted prompt",
        :interrupted_outcome_unknown,
        terminal: "failed_unknown"
      )

    assert {:ok, [["failed_unknown"]]} =
             DB.query(
               ctx.db,
               "SELECT status FROM turns WHERE seq=?1",
               [source.seq]
             )

    assert {:ok, [["interrupted-outcome-unknown", nil]]} =
             DB.query(
               ctx.db,
               "SELECT failureClass,parentSessionKey FROM health_redelivery_attempts " <>
                 "WHERE sourceTurnSeq=?1",
               [source.seq]
             )

    _restoration = restore_health_turn!(ctx.db, healthy.session, "interrupted-restoration")

    assert {:ok,
            [
              [
                "interrupted-parentless-source",
                "agent:health-redelivery",
                "original interrupted prompt"
              ]
            ]} =
             DB.query(
               ctx.db,
               "SELECT messageId,origin,prompt FROM turns " <>
                 "WHERE sessionKey=?1 AND status='queued'",
               [failed.session]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM health_redelivery_attempts " <>
                 "WHERE sourceTurnSeq=?1 AND restorationTurnSeq IS NOT NULL " <>
                 "AND redeliveryTurnSeq IS NOT NULL",
               [source.seq]
             )

    _second_restoration =
      restore_health_turn!(ctx.db, healthy.session, "interrupted-restoration-second")

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE sessionKey=?1 " <>
                 "AND messageId='interrupted-parentless-source' AND status='queued'",
               [failed.session]
             )
  end

  test "interrupted outcome asks its active dispatcher or session parent", ctx do
    [dispatched, parented, healthy | _] = ctx.sessions

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "UPDATE assignments SET openedBySession=?1 WHERE id=?2",
               [ctx.main_session, dispatched.assignment]
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET spawnedBy=?1 WHERE sessionKey=?2",
               [ctx.main_session, parented.session]
             )

    dispatched_source =
      fail_health_turn!(
        ctx.db,
        dispatched.session,
        "interrupted-dispatched-source",
        "original dispatched prompt",
        :interrupted_outcome_unknown,
        assignment_id: dispatched.assignment
      )

    parented_source =
      fail_health_turn!(
        ctx.db,
        parented.session,
        "interrupted-parented-source",
        "original parented prompt",
        :interrupted_outcome_unknown,
        assignment_id: parented.assignment
      )

    main_session = ctx.main_session

    assert {:ok, [[^main_session], [^main_session]]} =
             DB.query(
               ctx.db,
               "SELECT parentSessionKey FROM health_redelivery_attempts " <>
                 "WHERE sourceTurnSeq IN (?1,?2) ORDER BY sourceTurnSeq",
               [dispatched_source.seq, parented_source.seq]
             )

    assert {:ok, wake_rows} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,prompt FROM wakes " <>
                 "WHERE origin='health-redelivery-parent' ORDER BY wakeId"
             )

    assert length(wake_rows) == 2

    assert Enum.all?(wake_rows, fn [session_key, prompt] ->
             session_key == ctx.main_session and
               String.contains?(prompt, "Should the original message be redelivered?")
           end)

    assert Enum.any?(wake_rows, fn [_session_key, prompt] ->
             String.contains?(prompt, "interrupted-dispatched-source") and
               String.contains?(prompt, "original dispatched prompt")
           end)

    assert Enum.any?(wake_rows, fn [_session_key, prompt] ->
             String.contains?(prompt, "interrupted-parented-source") and
               String.contains?(prompt, "original parented prompt")
           end)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.record_health_redelivery_source_in_txn(
                 txn,
                 dispatched_source.seq,
                 "interrupted-outcome-unknown"
               )
             end)

    _restoration = restore_health_turn!(ctx.db, healthy.session, "interrupted-parent-restoration")

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE origin='health-redelivery-parent' " <>
                 "AND sessionKey=?1",
               [ctx.main_session]
             )

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM health_redelivery_attempts " <>
                 "WHERE sourceTurnSeq IN (?1,?2) AND parentSessionKey=?3 " <>
                 "AND redeliveryTurnSeq IS NULL",
               [dispatched_source.seq, parented_source.seq, ctx.main_session]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE messageId IN " <>
                 "('interrupted-dispatched-source','interrupted-parented-source') " <>
                 "AND status='queued'"
             )
  end

  test "single-session typed failure redelivers on next successful same-harness turn", ctx do
    [failed, _, healthy | _] = ctx.sessions

    fail_health_turn!(
      ctx.db,
      failed.session,
      "single-session-source",
      "original single-session prompt",
      %{"status" => 401, "error" => "unauthorized"}
    )

    assert HarnessHealth.active(ctx.db) == []

    assert {:ok, [[1, nil]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*),MAX(redeliveryTurnSeq) FROM health_redelivery_attempts " <>
                 "WHERE sourceMessageId='single-session-source'"
             )

    start_supervised!({RecoveryLane, {ctx.db, self()}})
    restoration = restore_health_turn!(ctx.db, healthy.session, "single-session-restoration")
    assert_receive {:recovery_lane, key, [[redelivery_seq]]}
    assert key == failed.session
    assert is_integer(redelivery_seq)

    assert {:ok,
            [
              [
                "single-session-source",
                "agent:health-redelivery",
                "original single-session prompt"
              ]
            ]} =
             DB.query(
               ctx.db,
               "SELECT messageId,origin,prompt FROM turns " <>
                 "WHERE sessionKey=?1 AND status='queued'",
               [failed.session]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM health_redelivery_attempts " <>
                 "WHERE sourceMessageId='single-session-source' AND restorationTurnSeq=?1 " <>
                 "AND redeliveryTurnSeq IS NOT NULL",
               [restoration.seq]
             )

    healthy_session = Org.get(ctx.db, healthy.session)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               HarnessHealth.resolve_normal_turn_in_txn(
                 txn,
                 healthy_session,
                 restoration
               )
             end)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE sessionKey=?1 " <>
                 "AND messageId='single-session-source' AND status='queued'",
               [failed.session]
             )
  end

  @tag :adapter_unavailable_redelivery
  test "a repeated direct-assignment refusal preserves a pending message recovery row", ctx do
    [failed | _] = ctx.sessions
    message_id = "same-message-pending-refusal"
    prompt = "continue the direct assignment"
    adapter_unavailable = %{"code" => "adapter_unavailable"}

    first_refusal =
      fail_health_turn!(
        ctx.db,
        failed.session,
        message_id,
        prompt,
        adapter_unavailable,
        assignment_id: failed.assignment
      )

    repeated_refusal =
      fail_health_turn!(
        ctx.db,
        failed.session,
        message_id,
        prompt,
        adapter_unavailable,
        assignment_id: failed.assignment
      )

    assert repeated_refusal.seq != first_refusal.seq

    first_source_seq = first_refusal.seq
    assignment_id = failed.assignment

    assert {:ok, [[^first_source_seq, nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT sourceTurnSeq,restorationTurnSeq,redeliveryTurnSeq " <>
                 "FROM health_redelivery_attempts WHERE sessionKey=?1 AND sourceMessageId=?2",
               [failed.session, message_id]
             )

    restoration = restore_health_turn!(ctx.db, failed.session, "restore-pending-refusal")

    assert {:ok, [[restoration_seq, redelivery_seq, ^prompt, ^assignment_id]]} =
             DB.query(
               ctx.db,
               "SELECT a.restorationTurnSeq,a.redeliveryTurnSeq,t.prompt,t.assignmentId " <>
                 "FROM health_redelivery_attempts a JOIN turns t ON t.seq=a.redeliveryTurnSeq " <>
                 "WHERE a.sessionKey=?1 AND a.sourceMessageId=?2",
               [failed.session, message_id]
             )

    assert restoration_seq == restoration.seq
    assert redelivery_seq > restoration.seq
  end

  @tag :adapter_unavailable_redelivery
  test "a repeated refusal keeps an already queued health redelivery", ctx do
    [failed | _] = ctx.sessions
    message_id = "same-message-queued-redelivery"
    prompt = "continue the queued assignment"
    reason = %{"code" => "adapter_unavailable"}

    first_refusal =
      fail_health_turn!(ctx.db, failed.session, message_id, prompt, reason,
        assignment_id: failed.assignment
      )

    restoration = restore_health_turn!(ctx.db, failed.session, "restore-queued-redelivery")

    assert {:ok, [[redelivery_seq, "queued", ^prompt]]} =
             DB.query(
               ctx.db,
               "SELECT a.redeliveryTurnSeq,t.status,t.prompt FROM health_redelivery_attempts a " <>
                 "JOIN turns t ON t.seq=a.redeliveryTurnSeq " <>
                 "WHERE a.sessionKey=?1 AND a.sourceMessageId=?2",
               [failed.session, message_id]
             )

    # The normal lane claims the queued redelivery first. Stage a failed retry
    # directly to exercise INSERT OR IGNORE against this otherwise unreachable
    # intermediate row state.
    {:ok, retry_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: failed.session,
        message_id: message_id,
        origin: "agent:health-redelivery",
        prompt: prompt,
        assignment_id: failed.assignment
      })

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE turns SET status='failed' WHERE seq=?1", [retry_seq])

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.record_health_redelivery_source_in_txn(txn, retry_seq, "adapter_unavailable")
             end)

    assert retry_seq > redelivery_seq
    first_source_seq = first_refusal.seq
    restoration_seq = restoration.seq

    assert {:ok, [[^first_source_seq, ^restoration_seq, ^redelivery_seq]]} =
             DB.query(
               ctx.db,
               "SELECT sourceTurnSeq,restorationTurnSeq,redeliveryTurnSeq " <>
                 "FROM health_redelivery_attempts WHERE sessionKey=?1 AND sourceMessageId=?2",
               [failed.session, message_id]
             )

    {:ok, claimed_redelivery} =
      Ledger.claim_next(ctx.db, failed.session, "health-redelivery-test")

    assert claimed_redelivery.seq == redelivery_seq
    assert claimed_redelivery.message_id == message_id
    assert claimed_redelivery.prompt == prompt
  end

  @tag :adapter_unavailable_redelivery
  test "a repeated direct-assignment refusal preserves an already redelivered message", ctx do
    [failed | _] = ctx.sessions
    message_id = "same-message-redelivered-refusal"
    prompt = "continue the redelivered assignment"
    adapter_unavailable = %{"code" => "adapter_unavailable"}
    assignment_id = failed.assignment

    first_refusal =
      fail_health_turn!(
        ctx.db,
        failed.session,
        message_id,
        prompt,
        adapter_unavailable,
        assignment_id: assignment_id
      )

    restoration = restore_health_turn!(ctx.db, failed.session, "restore-redelivered-refusal")
    restoration_seq = restoration.seq

    assert {:ok, [[^restoration_seq, redelivery_seq]]} =
             DB.query(
               ctx.db,
               "SELECT restorationTurnSeq,redeliveryTurnSeq FROM health_redelivery_attempts " <>
                 "WHERE sessionKey=?1 AND sourceMessageId=?2",
               [failed.session, message_id]
             )

    {:ok, claimed_redelivery} =
      Ledger.claim_next(ctx.db, failed.session, "health-redelivery-test")

    redelivered = Map.put(claimed_redelivery, :session_key, failed.session)
    assert redelivered.seq == redelivery_seq
    assert redelivered.message_id == message_id
    assert redelivered.prompt == prompt

    redelivery_session = Org.get(ctx.db, failed.session)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(txn, redelivered.seq, "delivered", nil,
                        owner_lease: redelivered.owner_lease
                      )

               HarnessHealth.resolve_normal_turn_in_txn(txn, redelivery_session, redelivered)
             end)

    repeated_refusal =
      fail_health_turn!(
        ctx.db,
        failed.session,
        message_id,
        prompt,
        adapter_unavailable,
        assignment_id: assignment_id
      )

    assert repeated_refusal.seq > redelivery_seq

    first_source_seq = first_refusal.seq

    assert {:ok, [[^first_source_seq, ^restoration_seq, ^redelivery_seq]]} =
             DB.query(
               ctx.db,
               "SELECT sourceTurnSeq,restorationTurnSeq,redeliveryTurnSeq " <>
                 "FROM health_redelivery_attempts WHERE sessionKey=?1 AND sourceMessageId=?2",
               [failed.session, message_id]
             )

    assert {:ok, [["delivered"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [redelivery_seq])
  end

  @tag :adapter_unavailable_redelivery
  test "an adapter refusal of a health redelivery re-arms its prompt", ctx do
    [failed | _] = ctx.sessions
    message_id = "refused-health-redelivery"
    prompt = "continue after the refused redelivery"
    adapter_unavailable = %{"code" => "adapter_unavailable"}
    assignment_id = failed.assignment

    first_refusal =
      fail_health_turn!(
        ctx.db,
        failed.session,
        message_id,
        prompt,
        adapter_unavailable,
        assignment_id: assignment_id
      )

    first_restoration =
      restore_health_turn!(ctx.db, failed.session, "restore-before-refused-redelivery")

    first_source_seq = first_refusal.seq

    assert {:ok, [[^first_source_seq, first_redelivery_seq]]} =
             DB.query(
               ctx.db,
               "SELECT sourceTurnSeq,redeliveryTurnSeq FROM health_redelivery_attempts " <>
                 "WHERE sessionKey=?1 AND sourceMessageId=?2",
               [failed.session, message_id]
             )

    {:ok, claimed_redelivery} =
      Ledger.claim_next(ctx.db, failed.session, "health-redelivery-test")

    refused_redelivery = Map.put(claimed_redelivery, :session_key, failed.session)
    assert refused_redelivery.seq == first_redelivery_seq
    assert refused_redelivery.message_id == message_id

    failed_session = Org.get(ctx.db, failed.session)

    assert {:ok, post_commit} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(
                        txn,
                        refused_redelivery.seq,
                        "failed",
                        "adapter unavailable",
                        owner_lease: refused_redelivery.owner_lease
                      )

               HarnessHealth.observe_turn_failure_in_txn(
                 txn,
                 failed_session,
                 refused_redelivery,
                 :prompt,
                 adapter_unavailable
               )
             end)

    if is_function(post_commit, 0), do: post_commit.()

    assert {:ok, [[^first_source_seq, nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT sourceTurnSeq,restorationTurnSeq,redeliveryTurnSeq " <>
                 "FROM health_redelivery_attempts WHERE sessionKey=?1 AND sourceMessageId=?2",
               [failed.session, message_id]
             )

    next_restoration =
      restore_health_turn!(ctx.db, failed.session, "restore-after-refused-redelivery")

    assert {:ok, [[^first_source_seq, next_restoration_seq, next_redelivery_seq]]} =
             DB.query(
               ctx.db,
               "SELECT a.sourceTurnSeq,a.restorationTurnSeq,a.redeliveryTurnSeq " <>
                 "FROM health_redelivery_attempts a " <>
                 "WHERE a.sessionKey=?1 AND a.sourceMessageId=?2",
               [failed.session, message_id]
             )

    assert next_restoration_seq == next_restoration.seq
    assert next_redelivery_seq > next_restoration.seq

    {:ok, claimed_next_redelivery} =
      Ledger.claim_next(ctx.db, failed.session, "health-redelivery-test")

    next_redelivery = Map.put(claimed_next_redelivery, :session_key, failed.session)
    assert next_redelivery.seq == next_redelivery_seq
    assert next_redelivery.message_id == message_id
    assert next_redelivery.prompt == prompt

    next_session = Org.get(ctx.db, failed.session)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(txn, next_redelivery.seq, "delivered", nil,
                        owner_lease: next_redelivery.owner_lease
                      )

               HarnessHealth.resolve_normal_turn_in_txn(txn, next_session, next_redelivery)
             end)

    assert {:ok, [["delivered"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [next_redelivery.seq])
  end

  @tag :adapter_unavailable_redelivery
  test "a fired wake is redelivered on its session's next turn after a route switch", ctx do
    [source, other | _] = ctx.sessions
    message_id = "fired-wake-route-switch"
    prompt = "resume the fired wake"
    adapter_unavailable = %{"code" => "adapter_unavailable"}

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET host='source-host' WHERE sessionKey IN (?1,?2)",
               [source.session, other.session]
             )

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: source.session,
        origin: "system",
        prompt: prompt,
        due_at: System.system_time(:millisecond)
      })

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending'",
               [wake.wake_id, System.system_time(:millisecond)]
             )

    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"

    source_refusal =
      fail_health_turn!(
        ctx.db,
        source.session,
        message_id,
        prompt,
        adapter_unavailable,
        wake_id: wake.wake_id
      )

    # Keep the source route unhealthy while the affected session changes route;
    # no session succeeds on claude@source-host to trigger ordinary route recovery.
    _other_route_failure =
      fail_health_turn!(
        ctx.db,
        other.session,
        "route-still-unhealthy",
        "another refused prompt",
        adapter_unavailable
      )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM harness_health_incidents " <>
                 "WHERE harness='claude' AND host='source-host' " <>
                 "AND failureClass='adapter_unavailable' AND state='open'"
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET harness='codex',provider='openai',host='alternate-host' " <>
                 "WHERE sessionKey=?1",
               [source.session]
             )

    restoration = restore_health_turn!(ctx.db, source.session, "restore-after-route-switch")
    restoration_seq = restoration.seq
    source_wake_id = wake.wake_id
    restored_session = Org.get(ctx.db, source.session)

    assert restored_session.harness == "codex"
    assert restored_session.host == "alternate-host"

    assert {:ok, [[^source_wake_id, ^restoration_seq, redelivery_seq, ^prompt]]} =
             DB.query(
               ctx.db,
               "SELECT a.sourceWakeId,a.restorationTurnSeq,a.redeliveryTurnSeq,t.prompt " <>
                 "FROM health_redelivery_attempts a JOIN turns t ON t.seq=a.redeliveryTurnSeq " <>
                 "WHERE a.sourceTurnSeq=?1",
               [source_refusal.seq]
             )

    assert redelivery_seq > restoration.seq

    assert {:ok, [["queued", source_message_id]]} =
             DB.query(
               ctx.db,
               "SELECT status,messageId FROM turns WHERE seq=?1",
               [redelivery_seq]
             )

    assert source_message_id == message_id

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM harness_health_incidents " <>
                 "WHERE harness='claude' AND host='source-host' " <>
                 "AND failureClass='adapter_unavailable' AND state='open'"
             )

    assert {:ok, [[nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT restorationTurnSeq,redeliveryTurnSeq FROM health_redelivery_attempts " <>
                 "WHERE sessionKey=?1 AND sourceMessageId='route-still-unhealthy'",
               [other.session]
             )
  end

  test "no active main preserves failed turns while incident promotion refuses", ctx do
    assert {:ok, []} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET state='retired' WHERE sessionKey=?1",
               [ctx.main_session]
             )

    [first, second | _] = ctx.sessions

    for {ref, message_id} <- [{first, "refused-1"}, {second, "refused-2"}] do
      {:ok, _seq} =
        Ledger.enqueue(ctx.db, %{
          session_key: ref.session,
          message_id: message_id,
          origin: "agent:test",
          prompt: "run",
          assignment_id: ref.assignment
        })

      {:ok, turn} = Ledger.claim_next(ctx.db, ref.session, "test-lane")
      turn = Map.put(turn, :session_key, ref.session)
      session = Org.get(ctx.db, ref.session)

      assert {:ok, nil} =
               DB.transaction(ctx.db, fn txn ->
                 assert Ledger.finish_in_txn(txn, turn.seq, "failed", "auth expired",
                          owner_lease: turn.owner_lease
                        )

                 HarnessHealth.observe_turn_failure_in_txn(
                   txn,
                   session,
                   turn,
                   :prompt,
                   %{"data" => %{"details" => "auth expired"}}
                 )
               end)
    end

    assert {:ok, [["failed"], ["failed"]]} =
             DB.query(ctx.db, "SELECT status FROM turns ORDER BY seq")

    assert HarnessHealth.active(ctx.db) == []

    assert {:ok, [[2]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM harness_health_observations")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM condition_facts")

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harness_health_incident_refused")
           ) == 1

    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: second.session,
               message_id: "after-refusal",
               origin: "agent:test",
               prompt: "continue",
               assignment_id: second.assignment
             })

    assert {:ok, turn} = Ledger.claim_next(ctx.db, second.session, "test-lane")
    turn = Map.put(turn, :session_key, second.session)
    session = Org.get(ctx.db, second.session)

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET state='active' WHERE sessionKey=?1",
               [ctx.main_session]
             )

    assert {:ok, post_commit} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", "auth expired",
                        owner_lease: turn.owner_lease
                      )

               HarnessHealth.observe_turn_failure_in_txn(
                 txn,
                 session,
                 turn,
                 :prompt,
                 %{"data" => %{"details" => "auth expired"}}
               )
             end)

    assert is_function(post_commit, 0)
    post_commit.()

    assert [incident] = HarnessHealth.active(ctx.db)
    assert length(HarnessHealth.get(ctx.db, incident.id).observations) == 3

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harness_health_auth_blocker")
           ) == 1
  end

  test "one open incident absorbs later evidence and preserves its first evidence", ctx do
    [first, second, third] = ctx.sessions

    assert {:pending, _} =
             HarnessHealth.observe(ctx.db, failure(first, "rate-limit-dead", 100, "rate-1"))

    assert {:opened, opened} =
             HarnessHealth.observe(ctx.db, failure(second, "rate-limit-dead", 101, "rate-2"))

    assert {:attached, attached} =
             HarnessHealth.observe(ctx.db, failure(third, "rate-limit-dead", 500_000, "rate-3"))

    assert attached.id == opened.id
    assert [active] = HarnessHealth.active(ctx.db)
    assert active.id == opened.id

    incident = HarnessHealth.get(ctx.db, opened.id)
    assert length(incident.observations) == 3
    assert incident.openObservationId == opened.observationId
    assert incident.affectedSessions == Enum.sort(Enum.map(ctx.sessions, & &1.session))
  end

  test "successful normal-turn evidence resolves without deleting history", ctx do
    [first | _] = ctx.sessions

    assert {:opened, opened} =
             HarnessHealth.observe(ctx.db, authoritative(first, "auth-dead", 10, "auth-open"))

    resolution = %{
      harness: "claude",
      host: "testhost",
      failure_class: "auth-dead",
      session_key: first.session,
      assignment_id: first.assignment,
      observed_at: 20,
      correlation_id: "normal-turn-20",
      cause: "normal turn delivered",
      principal: "process:tightbeam",
      cycle_release: true
    }

    assert {:resolved, resolved} = HarnessHealth.resolve(ctx.db, resolution)
    assert resolved.id == opened.id
    assert resolved.state == "resolved"

    assert {:ok, [[event_json]]} =
             DB.query(
               ctx.db,
               "SELECT event FROM row_reaction_events WHERE eventId=?1",
               ["harness-health-hold:#{opened.id}:resolved"]
             )

    event = JSON.decode!(event_json)
    assert event["resolutionCorrelation"] == "normal-turn-20"
    assert event["cycleRelease"] == false

    refute ConditionFacts.harness_failure_standing?(ctx.db, "claude", "testhost", "auth-dead")

    assert {:duplicate, duplicate} = HarnessHealth.resolve(ctx.db, resolution)
    assert duplicate.id == opened.id
    assert HarnessHealth.active(ctx.db) == []

    incident = HarnessHealth.get(ctx.db, opened.id)
    assert incident.state == "resolved"

    assert Enum.map(incident.observations, & &1.evidence_kind) ==
             ["authoritative-provider", "normal-turn-success"]

    assert {:error, %DB.Error{message: message}} =
             DB.query(ctx.db, "DELETE FROM harness_health_incidents WHERE id=?1", [opened.id])

    assert message =~ "incident history is immutable"
    assert HarnessHealth.get(ctx.db, opened.id).state == "resolved"

    assert {:error, %DB.Error{message: message}} =
             DB.query(
               ctx.db,
               "UPDATE harness_health_incidents SET resolvedAt=resolvedAt+1 WHERE id=?1",
               [opened.id]
             )

    assert message =~ "may resolve exactly once"
  end

  test "other evidence is immutable and ordinary reads omit sensitive detail", ctx do
    [member | _] = ctx.sessions
    description = "captured provider transport detail"
    digest = :crypto.hash(:sha256, description) |> Base.encode16(case: :lower)
    at = System.system_time(:millisecond)

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: member.session,
               principal: {:session, member.session},
               description: description,
               evidence_mode: "exact_error",
               observed_state: "provider transport failed",
               exact_observed_error: "transport reset",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "immutable-evidence"
             })

    ordinary = HarnessHealth.get(ctx.db, opened.id)
    refute Map.has_key?(ordinary, :descriptionDigest)

    assert Enum.all?(ordinary.observations, fn observation ->
             Enum.all?(
               ~w(cause description description_digest exact_observed_error exact_probe),
               fn key ->
                 not Map.has_key?(observation, String.to_existing_atom(key))
               end
             )
           end)

    assert Enum.all?(EventLog.lifecycle_events(ctx.db), fn event ->
             not String.contains?(event.detail, description) and
               not String.contains?(event.detail, digest)
           end)

    assert {:ok, exact} =
             HarnessHealth.read_other_evidence(ctx.db, opened.id, {:session, member.session})

    assert exact.incident.descriptionDigest == digest
    assert hd(exact.observations).description == description
    assert exact.reviewNotice.digest == digest
    assert exact.reviewNotice.pointer.incidentId == opened.id
    assert is_integer(exact.reviewNotice.pointer.routeOrdinal)
    refute Map.has_key?(ordinary, :reviewNotice)
    assert {:ok, _} = HarnessHealth.read_other_evidence(ctx.db, opened.id, {:user, "flynn"})

    assert {:ok, same_owner_evidence} =
             HarnessHealth.read_other_evidence(ctx.db, opened.id, {:session, ctx.outside_session})

    assert same_owner_evidence == exact

    assert {:error, %{code: "not_authorized"}} =
             HarnessHealth.read_other_evidence(ctx.db, opened.id, "process:tightbeam")

    assert {:error, %DB.Error{message: message}} =
             DB.query(
               ctx.db,
               "UPDATE harness_health_observations SET description=?2 WHERE id=?1",
               [opened.observationId, "changed"]
             )

    assert message =~ "evidence is immutable"

    assert {:error, %DB.Error{message: message}} =
             DB.query(
               ctx.db,
               "UPDATE harness_health_incidents SET descriptionDigest=?2 WHERE id=?1",
               [opened.id, "changed"]
             )

    assert message =~ "incident identity is immutable"
  end

  test "correlation idempotency refuses a different event", ctx do
    [first | _] = ctx.sessions
    input = authoritative(first, "auth-dead", 10, "same-correlation")

    assert {:opened, opened} = HarnessHealth.observe(ctx.db, input)
    assert {:duplicate, duplicate} = HarnessHealth.observe(ctx.db, input)
    assert duplicate.id == opened.id

    error =
      assert_raise ArgumentError, fn ->
        HarnessHealth.observe(ctx.db, %{input | cause: "different evidence"})
      end

    assert error.message =~ "already used for different evidence"
    assert [active] = HarnessHealth.active(ctx.db)
    assert active.id == opened.id
  end

  test "evidence cannot claim a different shared harness membership", ctx do
    input = %{
      harness: "claude",
      host: "testhost",
      failure_class: "auth-dead",
      evidence_kind: "terminal-failure",
      session_key: ctx.outside_session,
      assignment_id: "asg_health_outside",
      observed_at: 10,
      correlation_id: "wrong-membership",
      cause: "terminal recovery-chain failure",
      principal: "process:tightbeam"
    }

    assert_raise ArgumentError,
                 "harness health evidence session must use the affected harness",
                 fn ->
                   HarnessHealth.observe(ctx.db, input)
                 end

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM harness_health_observations")
  end

  test "an interrupted caller transaction leaves no partial observation or fact", ctx do
    [first | _] = ctx.sessions
    input = authoritative(first, "auth-dead", 10, "crash-before-commit")

    assert {:error, %RuntimeError{message: "forced interruption"}} =
             DB.transaction(ctx.db, fn txn ->
               assert {:opened, _} = HarnessHealth.observe_in_txn(txn, input)
               raise "forced interruption"
             end)

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM harness_health_observations")
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM harness_health_incidents")

    refute ConditionFacts.harness_failure_standing?(ctx.db, "claude", "testhost", "auth-dead")

    refute Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "harness_health_incident_opened"
           end)
  end

  test "hold row events snapshot routes and carry the recorded resolution correlation", ctx do
    [first | _] = ctx.sessions

    failed_turn =
      fail_health_turn!(
        ctx.db,
        first.session,
        "hold-row-event-failure",
        "bounded health failure",
        @captured_claude_rate_limit
      )

    [second | _] = Enum.reject(ctx.sessions, &(&1.session == first.session))

    fail_health_turn!(
      ctx.db,
      second.session,
      "hold-row-event-second-failure",
      "bounded health failure",
      @captured_claude_rate_limit
    )

    [incident] = HarnessHealth.active(ctx.db)
    opened_id = "harness-health-hold:#{incident.id}:opened"

    assert {:ok, [[opened_json, opened_facts_json]]} =
             DB.query(
               ctx.db,
               "SELECT event,facts FROM row_reaction_events WHERE eventId=?1",
               [opened_id]
             )

    opened = JSON.decode!(opened_json)
    opened_facts = JSON.decode!(opened_facts_json)

    assert {:ok, [[failed_model]]} =
             DB.query(ctx.db, "SELECT model FROM turns WHERE seq=?1", [failed_turn.seq])

    assert opened["kind"] == "harness_health_hold"
    assert opened["transition"] == "opened"
    assert opened["cycleRelease"] == false
    assert opened["after"]["state"] == "open"
    assert opened["after"]["failureClass"] == "rate-limit-dead"
    assert opened["after"]["routesComplete"]

    assert opened["after"]["routes"] == [
             %{
               "harness" => "claude",
               "host" => "testhost",
               "sharedAccount" => "shared",
               "model" => failed_model
             }
           ]

    assert opened["after"]["fencePresent"]
    assert opened_facts["hold"]["state"] == "open"
    assert opened_facts["hold"]["routes"] == opened["after"]["routes"]
    assert opened_facts["hold"]["fencePresent"]

    restored_turn = restore_health_turn!(ctx.db, first.session, "hold-row-event-restored")
    resolved_id = "harness-health-hold:#{incident.id}:resolved"

    assert {:ok, [[resolved_json, resolved_facts_json]]} =
             DB.query(
               ctx.db,
               "SELECT event,facts FROM row_reaction_events WHERE eventId=?1",
               [resolved_id]
             )

    resolved = JSON.decode!(resolved_json)
    resolved_facts = JSON.decode!(resolved_facts_json)

    assert {:ok, [[correlation]]} =
             DB.query(
               ctx.db,
               """
               SELECT o.correlationId FROM harness_health_incidents i
               JOIN harness_health_observations o ON o.id=i.resolutionObservationId
               WHERE i.id=?1
               """,
               [incident.id]
             )

    assert correlation == "harness-turn:#{restored_turn.seq}:normal-success:rate-limit-dead"
    assert resolved["transition"] == "resolved"
    assert resolved["resolutionCorrelation"] == correlation
    assert resolved["cycleRelease"] == false
    assert resolved["after"]["resolutionCorrelation"] == correlation
    assert resolved["after"]["state"] == "resolved"
    refute resolved["after"]["fencePresent"]
    assert resolved_facts["hold"]["state"] == "resolved"
    assert resolved_facts["hold"]["resolutionCorrelation"] == correlation
  end

  test "Codex usage-limit hold releases on its first successful recovery probe", ctx do
    failure_turn =
      fail_health_turn!(
        ctx.db,
        ctx.main_session,
        "codex-rate-limit-recovery",
        "Codex rate limit",
        @captured_codex_rate_limit
      )

    assert {:ok, [[incident_id, "authoritative-provider"]]} =
             DB.query(
               ctx.db,
               "SELECT incidentId,evidenceKind FROM harness_health_observations WHERE correlationId=?1",
               ["harness-turn:#{failure_turn.seq}:rate-limit-dead"]
             )

    assert is_binary(incident_id)
    incident = HarnessHealth.get(ctx.db, incident_id)
    assert incident.state == "open"

    assert incident.harness == "codex"
    assert incident.failureClass == "rate-limit-dead"
    assert Tightbeam.HarnessProcess.parked?(ctx.db, {:codex, "shared", "testhost"})

    assert {:ok,
            %{
              "ownerUserId" => owner_user_id,
              "routesComplete" => true,
              "routes" => [route]
            }} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.RowReactions.Snapshot.harness_health_hold(txn, incident.id)
             end)

    assert route["harness"] == "codex"

    assert {:ok, [[cycle_one, _due_at]]} =
             DB.query(
               ctx.db,
               "SELECT cycleId,dueAt FROM harness_health_recovery_schedules WHERE holdId=?1",
               [incident.id]
             )

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE consumer='rate_limit_reset'")

    started_one = System.system_time(:millisecond)

    assert {:ok, 1} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "UPDATE harness_health_recovery_schedules SET dueAt=?2 WHERE holdId=?1 AND cycleId=?3 AND status='pending'",
                 [incident.id, started_one, cycle_one]
               )

               Tightbeam.DB.Txn.changes(txn)
             end)

    assert [%{"cycle_id" => ^cycle_one}] =
             Tightbeam.HarnessHealth.RecoverySchedule.fire_due(ctx.db, started_one)

    seed_running_recovery_checks!(
      ctx.db,
      incident.id,
      cycle_one,
      [route],
      started_one,
      owner_user_id || "system"
    )

    assert {:ok, {:released, release}} =
             DB.transaction(ctx.db, fn txn ->
               RecoveryCheck.record_result_in_txn(
                 txn,
                 incident.id,
                 cycle_one,
                 Tightbeam.HarnessHealth.RecoveryCheck.route_key(route),
                 "succeeded",
                 nil,
                 started_one + 1
               )
             end)

    assert release.harness == "codex"
    assert release.host == "testhost"
    assert HarnessHealth.get(ctx.db, incident.id).state == "resolved"
    refute Tightbeam.HarnessProcess.parked?(ctx.db, {:codex, "shared", "testhost"})

    {:ok, resumed_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.main_session,
        message_id: "codex-after-rate-limit-recovery",
        origin: "user:flynn",
        prompt: "continue after the provider limit clears"
      })

    assert {:ok, resumed_turn} =
             Ledger.claim_next(ctx.db, ctx.main_session, "codex-after-rate-limit-recovery")

    assert resumed_turn.seq == resumed_seq
    assert resumed_turn.message_id == "codex-after-rate-limit-recovery"

    resumed_turn = Map.put(resumed_turn, :session_key, ctx.main_session)
    resumed_session = Org.get(ctx.db, ctx.main_session)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(
                        txn,
                        resumed_turn.seq,
                        "delivered",
                        nil,
                        owner_lease: resumed_turn.owner_lease
                      )

               HarnessHealth.resolve_normal_turn_in_txn(txn, resumed_session, resumed_turn)
             end)
  end

  test "recovery cycle records each route and releases only after all current routes succeed",
       ctx do
    [first | _] = ctx.sessions

    assert {:ok, [[owner_user_id]]} =
             DB.query(ctx.db, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [
               first.session
             ])

    second_session = "agent:harness-health:recovery-route-two"
    second_assignment = "asg_health_recovery_route_two"

    Org.create(ctx.db, %{
      session_key: second_session,
      display_name: "Recovery route two",
      owner_user_id: owner_user_id,
      origin: "user:" <> owner_user_id,
      archetype: "coder",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5-alt")
    })

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               INSERT INTO assignments
                 (id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
               VALUES (?1,'recovery route two',?2,?2,5,'open','claude','anthropic')
               """,
               [second_assignment, second_session]
             )

    _first_failure =
      fail_health_turn!(
        ctx.db,
        first.session,
        "recovery-cycle-route-one",
        "bounded health failure",
        @captured_claude_rate_limit
      )

    _second_failure =
      fail_health_turn!(
        ctx.db,
        second_session,
        "recovery-cycle-route-two",
        "bounded health failure",
        @captured_claude_rate_limit,
        assignment_id: second_assignment
      )

    [incident] = HarnessHealth.active(ctx.db)

    assert {:ok, %{"routesComplete" => true, "routes" => routes}} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.RowReactions.Snapshot.harness_health_hold(txn, incident.id)
             end)

    assert length(routes) == 2

    assert {:ok, [[cycle_one, _due_at]]} =
             DB.query(
               ctx.db,
               "SELECT cycleId,dueAt FROM harness_health_recovery_schedules WHERE holdId=?1",
               [incident.id]
             )

    started_one = System.system_time(:millisecond)

    assert {:ok, 1} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "UPDATE harness_health_recovery_schedules SET dueAt=?2 WHERE holdId=?1 AND cycleId=?3 AND status='pending'",
                 [incident.id, started_one, cycle_one]
               )

               Tightbeam.DB.Txn.changes(txn)
             end)

    assert [%{"cycle_id" => ^cycle_one}] =
             Tightbeam.HarnessHealth.RecoverySchedule.fire_due(ctx.db, started_one)

    assert {:ok, [[wake_count_before_cycle]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")

    seed_running_recovery_checks!(
      ctx.db,
      incident.id,
      cycle_one,
      routes,
      started_one,
      owner_user_id
    )

    [route_one, route_two] =
      Enum.sort_by(routes, &Tightbeam.HarnessHealth.RecoveryCheck.route_key/1)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.HarnessHealth.RecoveryCheck.record_result_in_txn(
                 txn,
                 incident.id,
                 cycle_one,
                 Tightbeam.HarnessHealth.RecoveryCheck.route_key(route_one),
                 "succeeded",
                 nil,
                 started_one + 1
               )
             end)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.HarnessHealth.RecoveryCheck.record_result_in_txn(
                 txn,
                 incident.id,
                 cycle_one,
                 Tightbeam.HarnessHealth.RecoveryCheck.route_key(route_one),
                 "failed",
                 "duplicate result must not replace the first observation",
                 started_one + 3
               )
             end)

    assert {:ok, [["succeeded", nil, 1]]} =
             DB.query(
               ctx.db,
               "SELECT outcome,errorExcerpt,(SELECT COUNT(*) FROM row_reaction_events WHERE eventId=(SELECT eventId FROM harness_health_recovery_checks WHERE holdId=?1 AND cycleId=?2 AND routeKey=?3)) FROM harness_health_recovery_checks WHERE holdId=?1 AND cycleId=?2 AND routeKey=?3",
               [
                 incident.id,
                 cycle_one,
                 Tightbeam.HarnessHealth.RecoveryCheck.route_key(route_one)
               ]
             )

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.HarnessHealth.RecoveryCheck.record_result_in_txn(
                 txn,
                 incident.id,
                 cycle_one,
                 Tightbeam.HarnessHealth.RecoveryCheck.route_key(route_two),
                 "failed",
                 "bounded provider error",
                 started_one + 3_600_100
               )
             end)

    assert HarnessHealth.get(ctx.db, incident.id).state == "open"
    assert {:ok, [[^wake_count_before_cycle]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")

    assert {:ok, [["pending", next_due_at]]} =
             DB.query(
               ctx.db,
               "SELECT status,dueAt FROM harness_health_recovery_schedules WHERE holdId=?1",
               [incident.id]
             )

    assert next_due_at == started_one + 3_600_000
    assert next_due_at < started_one + 3_600_100

    assert {:ok, [[cycle_two]]} =
             DB.query(
               ctx.db,
               "SELECT cycleId FROM harness_health_recovery_schedules WHERE holdId=?1",
               [incident.id]
             )

    started_two = max(next_due_at, started_one + 3_600_101)

    assert [%{"cycle_id" => ^cycle_two}] =
             Tightbeam.HarnessHealth.RecoverySchedule.fire_due(ctx.db, started_two)

    seed_running_recovery_checks!(
      ctx.db,
      incident.id,
      cycle_two,
      routes,
      started_two,
      owner_user_id
    )

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.HarnessHealth.RecoveryCheck.record_result_in_txn(
                 txn,
                 incident.id,
                 cycle_two,
                 Tightbeam.HarnessHealth.RecoveryCheck.route_key(route_one),
                 "succeeded",
                 nil,
                 started_two + 1
               )
             end)

    assert {:ok, {:released, release}} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.HarnessHealth.RecoveryCheck.record_result_in_txn(
                 txn,
                 incident.id,
                 cycle_two,
                 Tightbeam.HarnessHealth.RecoveryCheck.route_key(route_two),
                 "succeeded",
                 nil,
                 started_two + 2
               )
             end)

    assert release.correlation == "harness-health-check-cycle:#{incident.id}:#{cycle_two}"
    assert HarnessHealth.get(ctx.db, incident.id).state == "resolved"

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM health_redelivery_attempts WHERE cycleReleaseCorrelation=?1 AND cycleReleaseTurnSeq IS NULL",
               [release.correlation]
             )

    start_supervised!({RecoveryLane, {ctx.db, self()}})
    assert :ok = Wakes.redeliver_cycle_release(ctx.db, release.correlation, "claude", "testhost")

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM health_redelivery_attempts WHERE cycleReleaseCorrelation=?1 AND cycleReleaseTurnSeq IS NOT NULL",
               [release.correlation]
             )

    assert :ok = Wakes.redeliver_cycle_release(ctx.db, release.correlation, "claude", "testhost")

    assert {:ok, [[4]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE messageId IN ('recovery-cycle-route-one','recovery-cycle-route-two')"
             )

    assert {:ok, [[resolved_json]]} =
             DB.query(
               ctx.db,
               "SELECT event FROM row_reaction_events WHERE eventId=?1",
               ["harness-health-hold:#{incident.id}:resolved"]
             )

    resolved = JSON.decode!(resolved_json)
    assert resolved["resolutionCorrelation"] == release.correlation
    assert resolved["cycleRelease"] == true
    assert resolved["after"]["resolutionCorrelation"] == release.correlation

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM harness_health_recovery_checks WHERE holdId=?1 AND cycleId=?2 AND outcome='succeeded'",
               [incident.id, cycle_two]
             )
  end

  test "eligible hold owns one durable due cycle without delivering an agent wake", ctx do
    [first | _] = ctx.sessions

    assert {:opened, opened} =
             HarnessHealth.observe(
               ctx.db,
               authoritative(first, "rate-limit-dead", 100, "recovery-schedule-open")
             )

    assert {:ok, [[cycle_id, due_at, "pending", 3_600_000, hold_id]]} =
             DB.query(
               ctx.db,
               "SELECT cycleId,dueAt,status,intervalMs,holdId FROM harness_health_recovery_schedules WHERE holdId=?1",
               [opened.id]
             )

    assert hold_id == opened.id
    assert due_at == 3_600_100
    assert {:ok, [[wake_count_before]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")

    assert [cycle] =
             Tightbeam.HarnessHealth.RecoverySchedule.fire_due(ctx.db, due_at)

    assert cycle == %{
             "hold_id" => opened.id,
             "cycle_id" => cycle_id,
             "routes" => []
           }

    assert [%{"hold_id" => id, "cycle_id" => ^cycle_id}] =
             Tightbeam.HarnessHealth.RecoverySchedule.due_cycles(ctx.db)

    assert id == opened.id

    assert {:ok, [[^due_at]]} =
             DB.query(
               ctx.db,
               "SELECT previousStartedAt FROM harness_health_recovery_schedules WHERE holdId=?1",
               [opened.id]
             )

    assert {:ok, [[wake_count_after]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")
    assert wake_count_after == wake_count_before
  end

  test "recovery rail changes move one cycle and preserve the last cycle start", ctx do
    [first | _] = ctx.sessions

    assert {:opened, opened} =
             HarnessHealth.observe(
               ctx.db,
               authoritative(first, "rate-limit-dead", 100, "recovery-schedule-policy-change")
             )

    assert {:ok, [[cycle_id, initial_due_at]]} =
             DB.query(
               ctx.db,
               "SELECT cycleId,dueAt FROM harness_health_recovery_schedules WHERE holdId=?1",
               [opened.id]
             )

    load_recovery_policy!(["rate-limit-dead"], 1_800_000)
    assert :ok = Tightbeam.HarnessHealth.RecoverySchedule.reconcile_open_holds(ctx.db, 500)

    assert {:ok, [[^cycle_id, revised_due_at, "pending", 1_800_000]]} =
             DB.query(
               ctx.db,
               "SELECT cycleId,dueAt,status,intervalMs FROM harness_health_recovery_schedules WHERE holdId=?1",
               [opened.id]
             )

    assert initial_due_at == 3_600_100
    assert revised_due_at == 1_800_100

    assert [%{"cycle_id" => ^cycle_id}] =
             Tightbeam.HarnessHealth.RecoverySchedule.fire_due(ctx.db, revised_due_at)

    load_recovery_policy!([], 1_800_000)

    assert :ok =
             Tightbeam.HarnessHealth.RecoverySchedule.reconcile_open_holds(
               ctx.db,
               revised_due_at + 1
             )

    assert {:ok, [["withdrawn", ^revised_due_at]]} =
             DB.query(
               ctx.db,
               "SELECT status,previousStartedAt FROM harness_health_recovery_schedules WHERE holdId=?1",
               [opened.id]
             )

    load_recovery_policy!(["rate-limit-dead"], 600_000)

    assert :ok =
             Tightbeam.HarnessHealth.RecoverySchedule.reconcile_open_holds(
               ctx.db,
               revised_due_at + 1_000
             )

    assert {:ok, [[next_cycle_id, next_due_at, "pending", 600_000, ^revised_due_at]]} =
             DB.query(
               ctx.db,
               "SELECT cycleId,dueAt,status,intervalMs,previousStartedAt FROM harness_health_recovery_schedules WHERE holdId=?1",
               [opened.id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM harness_health_recovery_schedules WHERE holdId=?1",
               [opened.id]
             )

    refute next_cycle_id == cycle_id
    assert next_due_at == revised_due_at + 600_000
    assert next_due_at > revised_due_at + 1_000
  end

  test "missing recovery rail leaves an eligible hold on its existing path", ctx do
    no_rules =
      Path.join(
        System.tmp_dir!(),
        "harness-health-no-recovery-rail-#{System.unique_integer([:positive])}"
      )

    assert [] = Tightbeam.Rules.load!(no_rules, [])
    [first | _] = ctx.sessions

    assert {:opened, opened} =
             HarnessHealth.observe(
               ctx.db,
               authoritative(first, "rate-limit-dead", 200, "recovery-schedule-no-rail")
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM harness_health_recovery_schedules WHERE holdId=?1",
               [opened.id]
             )
  end

  test "recovery scheduler delivers the persisted hold cycle without an agent wake", ctx do
    [first, second | _] = ctx.sessions
    route_host = "recovery-unregistered-fixture"
    Org.set_host(ctx.db, first.session, route_host)
    Org.set_host(ctx.db, second.session, route_host)
    Org.set_model(ctx.db, second.session, Model.new("claude-fable-5-alt"), "anthropic")

    fail_health_turn!(
      ctx.db,
      first.session,
      "recovery-scheduler-timer-route-one",
      "bounded health failure",
      @captured_claude_rate_limit
    )

    fail_health_turn!(
      ctx.db,
      second.session,
      "recovery-scheduler-timer-route-two",
      "bounded health failure",
      @captured_claude_rate_limit
    )

    [opened] = HarnessHealth.active(ctx.db)

    assert {:ok, %{"routesComplete" => true, "routes" => routes}} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.RowReactions.Snapshot.harness_health_hold(txn, opened.id)
             end)

    assert length(routes) == 2

    assert {:ok, [[wake_count_before]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")

    now = System.system_time(:millisecond)

    assert {:ok, 1} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "UPDATE harness_health_recovery_schedules SET dueAt=?2 WHERE holdId=?1 AND status='pending'",
                 [opened.id, now]
               )

               Tightbeam.DB.Txn.changes(txn)
             end)

    scheduler_name = {:global, {:harness_health_recovery_test, make_ref()}}
    task_sup = start_supervised!(Task.Supervisor)

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "harness-health-scheduler-no-route-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    start_supervised!(
      {Tightbeam.HarnessHealth.RecoveryScheduler,
       db: ctx.db, base_dir: base_dir, task_sup: task_sup, name: scheduler_name}
    )

    assert eventually(fn ->
             case DB.query(
                    ctx.db,
                    "SELECT COUNT(*),MIN(outcome),MAX(outcome) FROM harness_health_recovery_checks WHERE holdId=?1",
                    [opened.id]
                  ) do
               {:ok, [[2, "uncheckable", "uncheckable"]]} ->
                 case DB.query(
                        ctx.db,
                        "SELECT status,dueAt,previousStartedAt FROM harness_health_recovery_schedules WHERE holdId=?1",
                        [opened.id]
                      ) do
                   {:ok, [["pending", due_at, started_at]]} -> due_at > started_at
                   _ -> false
                 end

               _ ->
                 false
             end
           end)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM harness_health_recovery_warnings WHERE holdId=?1",
               [opened.id]
             )

    assert {:ok, [[^wake_count_before]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")
  end

  test "recovery CLI selection follows pin, validated PATH, then adapter bundle" do
    node = System.find_executable("node")
    assert is_binary(node)

    root =
      Path.join(
        System.tmp_dir!(),
        "harness-health-binary-selection-#{System.unique_integer([:positive])}"
      )

    adapter_root = Path.join(root, "adapters")
    path_dir = Path.join(root, "path")
    bad_path_dir = Path.join(root, "bad-path")
    File.mkdir_p!(adapter_root)
    File.mkdir_p!(path_dir)
    File.mkdir_p!(bad_path_dir)
    File.write!(Path.join(adapter_root, "package.json"), "{}")

    on_exit(fn -> File.rm_rf!(root) end)

    Enum.each(["claude", "codex"], fn harness ->
      bundles = create_recovery_adapter_bundle!(node, adapter_root, harness)
      cli = Path.join(path_dir, harness)
      bad_cli = Path.join(bad_path_dir, harness)
      File.write!(cli, "#!/bin/sh\necho 'fixture 1.0.0'\n")
      File.chmod!(cli, 0o755)
      File.write!(bad_cli, "#!/bin/sh\nexit 1\n")
      File.chmod!(bad_cli, 0o755)

      pin = Path.join(root, "pinned-#{harness}")

      assert %{"command" => [^pin], "source" => "pin"} =
               recovery_binary_selection!(node, adapter_root, harness, path_dir, pin)

      assert %{"command" => [^cli], "source" => "path"} =
               recovery_binary_selection!(node, adapter_root, harness, path_dir, "")

      selected = recovery_binary_selection!(node, adapter_root, harness, bad_path_dir, "")

      if harness == "codex" do
        bundle = bundles
        assert %{"command" => [selected_node, selected_bundle], "source" => "bundle"} = selected
        assert same_file?(node, selected_node)
        assert same_file?(bundle, selected_bundle)
      else
        assert %{"command" => [bundle], "source" => "bundle"} = selected
        assert Enum.any?(bundles, &same_file?(&1, bundle))
      end
    end)
  end

  test "resolution withdraws the hold cycle before its deadline", ctx do
    [first | _] = ctx.sessions

    assert {:opened, opened} =
             HarnessHealth.observe(
               ctx.db,
               authoritative(first, "rate-limit-dead", 100, "recovery-schedule-withdraw")
             )

    assert {:ok, [[due_at]]} =
             DB.query(
               ctx.db,
               "SELECT dueAt FROM harness_health_recovery_schedules WHERE holdId=?1 AND status='pending'",
               [opened.id]
             )

    _restored_turn = restore_health_turn!(ctx.db, first.session, "recovery-schedule-resolved")

    assert {:ok, [["withdrawn"]]} =
             DB.query(
               ctx.db,
               "SELECT status FROM harness_health_recovery_schedules WHERE holdId=?1",
               [opened.id]
             )

    assert [] = Tightbeam.HarnessHealth.RecoverySchedule.fire_due(ctx.db, due_at)
  end

  test "serialized concurrent observations open exactly one incident", ctx do
    [first, second | _] = ctx.sessions

    tasks = [
      Task.async(fn ->
        HarnessHealth.observe(ctx.db, failure(first, "rate-limit-dead", 100, "concurrent-1"))
      end),
      Task.async(fn ->
        HarnessHealth.observe(ctx.db, failure(second, "rate-limit-dead", 100, "concurrent-2"))
      end)
    ]

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:opened, _}, &1)) == 1
    assert Enum.count(results, &match?({:pending, _}, &1)) == 1
    assert length(HarnessHealth.active(ctx.db)) == 1

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='harness-rate-limit-dead'"
             )
  end

  defp seed_running_recovery_checks!(db, hold_id, cycle_id, routes, started_at, org) do
    routes
    |> Enum.sort_by(&Tightbeam.HarnessHealth.RecoveryCheck.route_key/1)
    |> Enum.with_index()
    |> Enum.each(fn {route, index} ->
      route_key = Tightbeam.HarnessHealth.RecoveryCheck.route_key(route)
      event_id = "test-harness-health-recovery-check:#{hold_id}:#{cycle_id}:#{index}"

      assert {:ok, []} =
               DB.query(
                 db,
                 """
                 INSERT INTO harness_health_recovery_checks
                   (holdId,cycleId,routeKey,routeJson,harness,host,sharedAccount,model,startedAt,
                    finishedAt,outcome,errorExcerpt,eventId,org)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,NULL,'running',NULL,?10,?11)
                 """,
                 [
                   hold_id,
                   cycle_id,
                   route_key,
                   JSON.encode!(route),
                   route["harness"],
                   route["host"],
                   route["sharedAccount"],
                   route["model"],
                   started_at,
                   event_id,
                   org
                 ]
               )
    end)
  end

  defp recovery_binary_selection!(node, adapter_root, harness, path, pin) do
    script = RecoveryCheck.binary_selection_program(harness)

    {output, 0} =
      System.cmd(
        node,
        ["-e", script, adapter_root, harness, pin],
        env: [{"PATH", path}],
        stderr_to_stdout: true
      )

    JSON.decode!(output)
  end

  defp create_recovery_adapter_bundle!(_node, adapter_root, "codex") do
    adapter = Path.join(adapter_root, "node_modules/@agentclientprotocol/codex-acp")
    codex = Path.join(adapter_root, "node_modules/@openai/codex/bin/codex.js")
    File.mkdir_p!(adapter)
    File.mkdir_p!(Path.dirname(codex))

    File.write!(
      Path.join(adapter, "package.json"),
      ~s|{"name":"@agentclientprotocol/codex-acp","main":"index.js"}|
    )

    File.write!(Path.join(adapter, "index.js"), "")

    File.write!(
      Path.join(adapter_root, "node_modules/@openai/codex/package.json"),
      ~s|{"name":"@openai/codex"}|
    )

    File.write!(codex, "process.stdout.write('fixture 1.0.0')\n")
    codex
  end

  defp create_recovery_adapter_bundle!(node, adapter_root, "claude") do
    adapter = Path.join(adapter_root, "node_modules/@agentclientprotocol/claude-agent-acp")
    sdk = Path.join(adapter_root, "node_modules/@anthropic-ai/claude-agent-sdk")
    File.mkdir_p!(adapter)
    File.mkdir_p!(sdk)

    File.write!(
      Path.join(adapter, "package.json"),
      ~s|{"name":"@agentclientprotocol/claude-agent-acp","main":"index.js"}|
    )

    entry = Path.join(adapter, "index.js")
    File.write!(entry, "")

    File.write!(
      Path.join(sdk, "package.json"),
      ~s|{"name":"@anthropic-ai/claude-agent-sdk","main":"index.js"}|
    )

    File.write!(Path.join(sdk, "index.js"), "")
    {runtime, 0} = System.cmd(node, ["-p", "process.platform + ' ' + process.arch"])
    [platform, arch] = String.split(String.trim(runtime))

    packages =
      if platform == "linux" do
        ["claude-agent-sdk-linux-#{arch}", "claude-agent-sdk-linux-#{arch}-musl"]
      else
        ["claude-agent-sdk-#{platform}-#{arch}"]
      end

    Enum.map(packages, fn package ->
      binary = Path.join([adapter_root, "node_modules/@anthropic-ai", package, "claude"])
      File.mkdir_p!(Path.dirname(binary))
      File.write!(binary, "")
      File.chmod!(binary, 0o755)
      binary
    end)
  end

  defp same_file?(left, right) do
    with {:ok, left_stat} <- File.stat(left),
         {:ok, right_stat} <- File.stat(right) do
      left_stat.inode == right_stat.inode and
        left_stat.major_device == right_stat.major_device and
        left_stat.minor_device == right_stat.minor_device
    else
      _ -> false
    end
  end

  defp fail_health_turn!(db, session_key, message_id, prompt, reason, opts \\ []) do
    terminal = Keyword.get(opts, :terminal, "failed")

    {:ok, source_seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: message_id,
        wake_id: Keyword.get(opts, :wake_id),
        origin: "agent:health-redelivery",
        prompt: prompt,
        assignment_id: Keyword.get(opts, :assignment_id)
      })

    {:ok, turn} = Ledger.claim_next(db, session_key, "health-redelivery-test")
    turn = Map.put(turn, :session_key, session_key)
    session = Org.get(db, session_key)

    assert {:ok, post_commit} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(
                        txn,
                        source_seq,
                        terminal,
                        if(terminal == "failed_unknown",
                          do: "interrupted: outcome unknown",
                          else: "HTTP 401"
                        ),
                        owner_lease: turn.owner_lease
                      )

               if terminal == "failed_unknown" do
                 HarnessHealth.observe_terminal_in_txn(
                   txn,
                   source_seq,
                   "interrupted-outcome-unknown",
                   "test terminal was interrupted; outcome unknown",
                   "process:test"
                 )
               else
                 HarnessHealth.observe_turn_failure_in_txn(
                   txn,
                   session,
                   turn,
                   :prompt,
                   reason
                 )
               end
             end)

    if is_function(post_commit, 0), do: post_commit.()
    turn
  end

  defp restore_health_turn!(db, session_key, message_id) do
    {:ok, _seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: message_id,
        origin: "agent:health-redelivery",
        prompt: "restored provider turn"
      })

    {:ok, turn} = Ledger.claim_next(db, session_key, "health-redelivery-test")
    turn = Map.put(turn, :session_key, session_key)
    session = Org.get(db, session_key)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "delivered", nil,
                        owner_lease: turn.owner_lease
                      )

               HarnessHealth.resolve_normal_turn_in_txn(txn, session, turn)
             end)

    turn
  end

  defp failure(ref, failure_class, observed_at, correlation_id) do
    %{
      harness: "claude",
      host: "testhost",
      failure_class: failure_class,
      evidence_kind: "terminal-failure",
      session_key: ref.session,
      assignment_id: ref.assignment,
      observed_at: observed_at,
      correlation_id: correlation_id,
      cause: "terminal recovery-chain failure",
      principal: "process:tightbeam"
    }
  end

  defp authoritative(ref, failure_class, observed_at, correlation_id) do
    ref
    |> failure(failure_class, observed_at, correlation_id)
    |> Map.put(:evidence_kind, "authoritative-provider")
  end

  defp load_recovery_policy!(eligible_classes, interval_ms) do
    root =
      Path.join(
        System.tmp_dir!(),
        "harness-health-recovery-policy-#{System.unique_integer([:positive])}"
      )

    rules_dir = Path.join(root, "identity/rules")
    File.mkdir_p!(rules_dir)

    seed =
      File.read!(Path.join(:code.priv_dir(:tightbeam), "seed/rules/harness-health-recovery.toml"))

    changed =
      seed
      |> String.replace(
        "eligible_failure_classes = [\"rate-limit-dead\"]",
        "eligible_failure_classes = #{JSON.encode!(eligible_classes)}"
      )
      |> String.replace("interval_ms = 3600000", "interval_ms = #{interval_ms}")

    if changed == seed do
      raise "recovery policy fixture did not change the shipped seed"
    end

    File.write!(Path.join(rules_dir, "harness-health-recovery.toml"), changed)
    on_exit(fn -> File.rm_rf!(root) end)
    Tightbeam.Rules.load!(root, [])

    assert %{settings: settings} = Tightbeam.Rules.reaction_policy("harness-health-recovery")
    assert settings["eligible_failure_classes"] == eligible_classes
    assert settings["interval_ms"] == interval_ms
  end

  defp eventually(fun, attempts \\ 500)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
