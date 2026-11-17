defmodule Tightbeam.HarnessRecoveryMainWakeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    DB,
    EventLog,
    Gateway,
    HarnessHealth,
    HarnessRecoveryNotice,
    Identity,
    LaneManager,
    Ledger,
    Model,
    Org,
    Projection,
    Rules,
    Wakes
  }

  alias Tightbeam.RowReactions.{Notice, Store}
  alias Tightbeam.HarnessHealth.{RecoveryCheck, RecoverySchedule}

  @fixtures [
    {"main-wake-c1-codex.json", "C1", "codex", "hho_bd254f96-37f5-4105-b9e2-32cf95b4436d",
     "2026-11-05T05:05:40Z"},
    {"main-wake-c2-claude.json", "C2", "claude", "hho_4d9d4b68-0388-4705-8142-9356ac553dd4",
     "2026-11-06T16:52:57Z"}
  ]

  @route %{
    "harness" => "codex",
    "host" => "testhost",
    "sharedAccount" => "account-a",
    "model" => "gpt-5"
  }

  setup do
    db = :"harness_recovery_notice_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)
    main = ensure_main_session(db, "owner-a")

    %{db: db, main: main}
  end

  test "captured outage fixtures preserve provenance and classify through the existing detector" do
    for {file, specimen, harness, source_id, observed_at} <- @fixtures do
      path = Path.join([__DIR__, "fixtures", "harness_recovery", file])
      capture = path |> File.read!() |> JSON.decode!()
      provenance = capture["provenance"]

      assert provenance["captureArtifactId"] == "art_c67b8748"

      assert provenance["captureArtifactSha256"] ==
               "bceb0218b28055164dfc34ba04e92c202a861c3f9dc05c36f64237631fdcbaca"

      assert provenance["specimen"] == specimen
      assert provenance["sourceRecordId"] == source_id
      assert provenance["observedAt"] == observed_at
      assert provenance["harness"] == harness
      assert provenance["failureClass"] == "rate-limit-dead"

      assert provenance["boundary"] ==
               "captured terminal-failure observation reason projection"

      assert HarnessHealth.classify_turn_failure(capture["reason"]) == "rate-limit-dead"
    end
  end

  test "release creates one due-now owner Main wake and ignores a duplicate episode", ctx do
    at = System.system_time(:millisecond)
    prompt = "Recovered harness prompt"

    release!(ctx.db, "hold-1", "owner-a", prompt, [@route], at)
    release!(ctx.db, "hold-1", "owner-a", prompt, [@route], at + 1)

    notice = notice!(ctx.db, "hold-1", "owner-a")
    assert notice.state == "attempting"
    assert notice.attempts == 1
    assert notice.failed_routes_json == JSON.encode!([@route])

    assert {:ok, [[wake_id, session_key, origin, wake_prompt, due_at, class, owner_id, state]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId,sessionKey,origin,prompt,dueAt,class,ownerUserId,state FROM wakes WHERE wakeId=?1",
               [notice.wake_id]
             )

    assert wake_id == notice.wake_id
    assert session_key == ctx.main.session_key
    assert origin == "process:tightbeam"
    assert wake_prompt == prompt
    assert due_at == at
    assert class == "blocker"
    assert owner_id == "owner-a"
    assert state == "pending"

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM harness_recovery_notices WHERE holdId='hold-1' AND ownerUserId='owner-a'"
             )

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE wakeId=?1", [notice.wake_id])

    assert Enum.map(EventLog.lifecycle_events(ctx.db), & &1.kind) |> Enum.take(-2) ==
             ["harness_recovery_notice_created", "harness_recovery_notice_attempt_started"]
  end

  test "selected release effect creates one notice per affected owner", ctx do
    owner_b_main = ensure_main_session(ctx.db, "owner-b")
    _unrelated_main = ensure_main_session(ctx.db, "owner-c")
    member_a1 = recovery_member!(ctx.db, "agent:wi3:owner-a-1", "owner-a")
    member_a2 = recovery_member!(ctx.db, "agent:wi3:owner-a-2", "owner-a")
    member_b1 = recovery_member!(ctx.db, "agent:wi3:owner-b-1", "owner-b")

    capture =
      Path.join([__DIR__, "fixtures", "harness_recovery", "main-wake-c1-codex.json"])
      |> File.read!()
      |> JSON.decode!()

    source_provenance = capture["provenance"]
    {:ok, captured_at, _offset} = DateTime.from_iso8601(source_provenance["observedAt"])
    captured_at = DateTime.to_unix(captured_at, :millisecond)
    failure_class = HarnessHealth.classify_turn_failure(capture["reason"])
    assert failure_class == "rate-limit-dead"

    assert {:pending, _observation} =
             HarnessHealth.observe(ctx.db, %{
               correlation_id: "captured:#{source_provenance["sourceRecordId"]}",
               harness: "codex",
               host: "testhost",
               failure_class: failure_class,
               evidence_kind: "terminal-failure",
               session_key: member_a1,
               observed_at: captured_at,
               cause: JSON.encode!(capture["reason"]),
               principal: "process:tightbeam"
             })

    release_at = captured_at + 1

    assert {:opened, hold} =
             HarnessHealth.observe(ctx.db, %{
               correlation_id: "synthetic:second-route-failure",
               harness: "codex",
               host: "testhost",
               failure_class: failure_class,
               evidence_kind: "terminal-failure",
               session_key: member_b1,
               observed_at: release_at - 1,
               cause: "synthetic second route failure for the captured hold fixture",
               principal: "process:tightbeam"
             })

    held = HarnessHealth.get(ctx.db, hold.id)
    assert held.affectedSessions == Enum.sort([member_a1, member_a2, member_b1])

    facts = %{}

    {loaded, _base} = load_seed_reactions!()

    assert [
             %{
               name: "harness-recovery-main-wake",
               family: "harness-recovery",
               english: english,
               provenance: rule_provenance
             }
           ] =
             Enum.filter(loaded, fn
               %{name: "harness-recovery-main-wake"} -> true
               _ -> false
             end)

    assert rule_provenance["bundle"] == "seed"
    assert rule_provenance["source"] == "rules/harness-recovery-main-wake.toml"
    assert english =~ "cycle release (`cycleRelease` true)"
    assert english =~ "ordinary-turn resolution"
    assert english =~ "the \"other\" resolve command"
    assert english =~ "For each owner whose sessions were held"
    assert english =~ "gateway starts"
    assert english =~ "one prompt to that owner"
    assert english =~ "No other agent or person receives anything"
    assert english =~ "that owner's Main becomes active"
    assert english =~ "completes another turn"
    assert english =~ "Stops when delivered or deliberately canceled"
    assert english =~ "No timer."
    assert english =~ "on by default"
    assert english =~ "Previously no prompt went to any Main"

    event = %{
      "org" => "owner-a",
      "id" => "release-event-#{hold.id}",
      "kind" => "harness_health_hold",
      "transition" => "resolved",
      "source" => %{"kind" => "harness_health_incident", "id" => hold.id},
      "at" => release_at,
      "cycleRelease" => true,
      "resolutionCorrelation" => "opaque-test-release-correlation",
      "after" => %{
        "id" => hold.id,
        "state" => "resolved",
        "harness" => held.harness,
        "host" => held.host,
        "failureClass" => held.failureClass,
        "openedAt" => held.openedAt,
        "resolvedAt" => release_at,
        "routes" => [@route],
        "resolutionCorrelation" => "opaque-test-release-correlation"
      }
    }

    [plan] = Rules.reaction_plans(event, facts)
    assert plan.selected
    assert plan.identity == ["owner-a", "harness-recovery", event["id"], "notice"]
    assert plan.value["hold_id"] == hold.id
    assert plan.value["resolved_at"] == release_at
    assert plan.value["failed_routes"] == [@route]
    assert plan.value["prompt_template"] =~ "@@member_count@@ of your sessions were held."
    assert plan.value["prompt_template"] =~ "Do not wake or resume unrelated agents."
    assert plan.value["prompt_template"] =~ "was released at @@released_at@@"

    normal_resolution =
      event
      |> Map.put("cycleRelease", false)
      |> Map.put("id", event["id"] <> "-normal")
      |> Map.update!("after", &Map.put(&1, "failureClass", "rate-limit-dead"))

    [normal_plan] = Rules.reaction_plans(normal_resolution, facts)
    assert normal_plan.selected
    assert normal_plan.value["prompt_template"] =~ "Work resumed on the @@harness@@ harness"
    assert normal_plan.value["prompt_template"] =~ "resolved at @@resolved_at@@"
    assert normal_plan.value["prompt_template"] =~ "This does not mean every model route"

    other_resolution =
      normal_resolution
      |> Map.put("id", event["id"] <> "-other")
      |> Map.update!("after", &Map.put(&1, "failureClass", "other"))

    [other_plan] = Rules.reaction_plans(other_resolution, facts)
    assert other_plan.selected
    assert other_plan.value["prompt_template"] =~ "was cleared of an unclassified (other) outage"
    assert other_plan.value["prompt_template"] =~ "does not mean a turn has succeeded"

    opened_event =
      event
      |> Map.put("cycleRelease", false)
      |> Map.put("id", event["id"] <> "-opened")
      |> Map.put("transition", "opened")
      |> Map.update!("after", &Map.put(&1, "state", "open"))

    refute hd(Rules.reaction_plans(opened_event, facts)).selected
    assert Rules.reaction_plans(Map.put(event, "kind", "wake_delivery"), facts) == []

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Store.adopt(txn, event, facts, plan, "pending", nil, release_at)
               [action] = Store.actions(txn, event["org"], event["id"])

               :ok = Notice.execute(txn, action, release_at)

               [accepted] = Store.actions(txn, event["org"], event["id"])
               assert accepted["status"] == "accepted"

               assert accepted["result"]["notice_episodes"] == [
                        %{"hold_id" => hold.id, "owner_user_id" => "owner-a"},
                        %{"hold_id" => hold.id, "owner_user_id" => "owner-b"}
                      ]

               :ok
             end)

    notice_a = notice!(ctx.db, hold.id, "owner-a")
    notice_b = notice!(ctx.db, hold.id, "owner-b")

    assert notice_a.attempts == 1
    assert notice_b.attempts == 1
    assert notice_a.state == "attempting"
    assert notice_b.state == "attempting"

    assert {:ok, [[owner_a, session_a, prompt_a, due_a]]} =
             DB.query(
               ctx.db,
               "SELECT ownerUserId,sessionKey,prompt,dueAt FROM wakes WHERE wakeId=?1",
               [notice_a.wake_id]
             )

    assert owner_a == "owner-a"
    assert session_a == ctx.main.session_key
    assert prompt_a == expected_recovery_prompt(held, hold.id, release_at, [@route], 2)
    assert due_a == release_at
    assert prompt_a =~ "The codex harness on testhost recovered from a rate-limit-dead outage."

    assert prompt_a =~
             "Hold #{hold.id} opened at #{held.openedAt} and was released at #{release_at}"

    assert {:ok, [[owner_b, session_b, prompt_b, due_b]]} =
             DB.query(
               ctx.db,
               "SELECT ownerUserId,sessionKey,prompt,dueAt FROM wakes WHERE wakeId=?1",
               [notice_b.wake_id]
             )

    assert owner_b == "owner-b"
    assert session_b == owner_b_main.session_key
    assert prompt_b == expected_recovery_prompt(held, hold.id, release_at, [@route], 1)
    assert due_b == release_at

    for {prompt, member_count} <- [{prompt_a, 2}, {prompt_b, 1}] do
      assert prompt =~ "The codex harness on testhost recovered from a rate-limit-dead outage."

      assert prompt =~
               "Hold #{hold.id} opened at #{held.openedAt} and was released at #{release_at}"

      assert prompt =~ "after every affected model route ("
      assert prompt =~ ") answered in one check. #{member_count} of your sessions were held."

      assert prompt =~
               "Use your installed and learned Kung Fu to find live agents whose work stalled on this harness and host, and resume only those agent graphs."

      assert prompt =~ "Do not wake or resume unrelated agents."
    end

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM harness_recovery_notices WHERE holdId=?1 AND ownerUserId='owner-c'",
               [hold.id]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wakes WHERE sessionKey IN (?1,?2,?3)",
               [member_a1, member_a2, member_b1]
             )

    no_reaction_base =
      Path.join(
        System.tmp_dir!(),
        "wi3bb2-no-recovery-reaction-#{System.unique_integer([:positive])}"
      )

    assert [] = Rules.load!(no_reaction_base, [])
    assert Rules.effective_snapshot().reactions == []
    unconfigured_release = Map.put(event, "id", event["id"] <> "-without-reaction")
    assert Rules.reaction_plans(unconfigured_release, facts) == []

    assert {:ok, []} =
             DB.transaction(ctx.db, fn txn ->
               Store.admit(txn, unconfigured_release, facts)
             end)
  end

  test "ordinary delivered turn preserves its assistant reply when notice creation fails", ctx do
    {loaded, _base} = load_seed_reactions!()
    assert Enum.any?(loaded, &(&1.name == "harness-recovery-main-wake"))

    failed_member = recovery_member!(ctx.db, "agent:wi3:normal-owner-a", "owner-a")
    second_failed_member = recovery_member!(ctx.db, "agent:wi3:normal-owner-a-second", "owner-a")
    successful_member = recovery_member!(ctx.db, "agent:wi3:normal-owner-b", "owner-b")

    capture =
      Path.join([__DIR__, "fixtures", "harness_recovery", "main-wake-c1-codex.json"])
      |> File.read!()
      |> JSON.decode!()

    assert capture["provenance"]["captureArtifactId"] == "art_c67b8748"

    assert capture["provenance"]["captureArtifactSha256"] ==
             "bceb0218b28055164dfc34ba04e92c202a861c3f9dc05c36f64237631fdcbaca"

    assert HarnessHealth.classify_turn_failure(capture["reason"]) == "rate-limit-dead"

    %{manager: manager, conn_registry: conn_registry} = start_normal_turn_path!(ctx.db, self())

    assert :appended =
             Gateway.deliver_prompt(
               successful_member,
               "user:owner-b",
               "Confirm the harness is working again.",
               db: ctx.db,
               lane_manager: manager,
               conn_registry: conn_registry,
               device_id: "wi3-normal-turn-device",
               client_message_id: "wi3-normal-turn-message",
               sender: "user:owner-b"
             )

    assert_receive {:wi3_normal_turn_started, successful_seq, runner}, 5_000

    _failed_turn =
      fail_health_turn!(
        ctx.db,
        failed_member,
        "captured-normal-owner-a",
        "Captured outage failure for normal-turn resolution",
        capture["reason"]
      )

    _second_failed_turn =
      fail_health_turn!(
        ctx.db,
        second_failed_member,
        "captured-normal-owner-a-second",
        "Second captured outage failure for normal-turn resolution",
        capture["reason"]
      )

    [hold] = HarnessHealth.active(ctx.db)
    held = HarnessHealth.get(ctx.db, hold.id)

    assert held.affectedSessions ==
             Enum.sort([failed_member, second_failed_member, successful_member])

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM row_reaction_actions WHERE eventId=?1",
               ["harness-health-hold:#{hold.id}:opened"]
             )

    install_notice_failure_trigger!(ctx.db)
    send(runner, {:wi3_normal_turn_complete, successful_seq})
    assert_receive {:wi3_normal_turn_committed, ^successful_seq, assistant_reply_id}, 5_000

    assert HarnessHealth.get(ctx.db, hold.id).state == "resolved"
    assert HarnessHealth.active(ctx.db) == []

    assert {:ok, [[event_json]]} =
             DB.query(
               ctx.db,
               "SELECT event FROM row_reaction_events WHERE eventId=?1",
               ["harness-health-hold:#{hold.id}:resolved"]
             )

    event = JSON.decode!(event_json)
    assert event["kind"] == "harness_health_hold"
    assert event["after"]["state"] == "resolved"
    assert event["after"]["failureClass"] == "rate-limit-dead"
    assert event["cycleRelease"] == false
    assert is_binary(event["resolutionCorrelation"])
    assert event["after"]["routes"] != []

    assert {:ok, [action]} =
             DB.transaction(ctx.db, fn txn ->
               Store.actions(txn, event["org"], event["id"])
             end)

    assert action["status"] == "pending"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM harness_recovery_notices WHERE holdId=?1",
               [hold.id]
             )

    assert {:ok, [["delivered"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [successful_seq])

    assert {:ok, [["assistant", "The ordinary turn reply survives notice failure.", echo_id]]} =
             DB.query(
               ctx.db,
               "SELECT role,content,replyToMessageId FROM messages WHERE id=?1",
               [assistant_reply_id]
             )

    assert is_binary(echo_id)

    remove_notice_failure_trigger!(ctx.db)
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)

    notice = notice!(ctx.db, hold.id, "owner-a")
    assert notice.state == "attempting"
    assert notice.attempts == 1
    assert notice.failed_routes_json == JSON.encode!(event["after"]["routes"])

    assert {:ok, [[session_key, prompt, due_at, class, owner_id]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,prompt,dueAt,class,ownerUserId FROM wakes WHERE wakeId=?1",
               [notice.wake_id]
             )

    assert session_key == ctx.main.session_key
    assert prompt == expected_work_resumed_prompt(held, hold.id, event["at"], 2)
    assert prompt =~ "Work resumed on the codex harness on testhost"
    assert prompt =~ "This does not mean every model route on this harness is back."
    refute prompt =~ "answered in one check"
    assert due_at == notice.updated_at
    assert due_at >= event["at"]
    assert class == "blocker"
    assert owner_id == "owner-a"

    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert notice!(ctx.db, hold.id, "owner-a").attempts == 1

    owner_b_notice = notice!(ctx.db, hold.id, "owner-b")
    assert owner_b_notice.state == "awaiting_main"
    assert owner_b_notice.attempts == 0
    assert owner_b_notice.last_outcome == "no_owner_main"
    assert owner_b_notice.failed_routes_json == JSON.encode!(event["after"]["routes"])
    assert owner_b_notice.prompt == expected_work_resumed_prompt(held, hold.id, event["at"], 1)

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM harness_recovery_notices WHERE holdId=?1",
               [hold.id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wakes WHERE wakeId=?1",
               [notice.wake_id]
             )
  end

  test "expiry of an other hold creates no recovery notice", ctx do
    {loaded, _base} = load_seed_reactions!()
    assert Enum.any?(loaded, &(&1.name == "harness-recovery-main-wake"))

    member = recovery_member!(ctx.db, "agent:wi3:expired-owner-a", "owner-a")
    at = System.system_time(:millisecond)
    {hold, _recovery_condition} = open_other_hold!(ctx.db, member, "expiry-no-wake", at)

    assert {:ok, :available} =
             DB.transaction(ctx.db, fn txn ->
               HarnessHealth.prod_shape_gate_in_txn(txn, "codex", "testhost", at + 501)
             end)

    assert HarnessHealth.get(ctx.db, hold.id).state == "expired"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM row_reaction_events WHERE eventId=?1",
               ["harness-health-hold:#{hold.id}:resolved"]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM harness_recovery_notices WHERE holdId=?1",
               [hold.id]
             )

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE wakeId LIKE ?1", [
               "harness-recovery:#{hold.id}:%"
             ])
  end

  test "one ordinary turn resolves two holds across routes while their hourly checks are due",
       ctx do
    {loaded, _base} = load_seed_reactions!()
    assert Enum.any?(loaded, &(&1.name == "harness-recovery-main-wake"))

    rate_limit_member = recovery_member!(ctx.db, "agent:wi3:multi-rate", "owner-a", "gpt-5")

    second_rate_member =
      recovery_member!(ctx.db, "agent:wi3:multi-rate-second", "owner-a", "gpt-5")

    auth_member = recovery_member!(ctx.db, "agent:wi3:multi-auth", "owner-a", "gpt-5")

    successful_member =
      recovery_member!(ctx.db, "agent:wi3:multi-success", "owner-a", "gpt-5.6-sol")

    capture = captured_fixture!("main-wake-c1-codex.json")
    assert capture["provenance"]["captureArtifactId"] == "art_c67b8748"

    %{manager: manager, conn_registry: conn_registry} = start_normal_turn_path!(ctx.db, self())

    assert :appended =
             Gateway.deliver_prompt(
               successful_member,
               "user:owner-a",
               "Complete successfully on the alternate model route.",
               db: ctx.db,
               lane_manager: manager,
               conn_registry: conn_registry,
               device_id: "wi3-multi-hold-device",
               client_message_id: "wi3-multi-hold-message",
               sender: "user:owner-a"
             )

    assert_receive {:wi3_normal_turn_started, successful_seq, runner}, 5_000

    _failed_turn =
      fail_health_turn!(
        ctx.db,
        rate_limit_member,
        "captured-multi-route-rate-limit",
        "Captured rate limit failure for multi-hold recovery",
        capture["reason"]
      )

    _second_failed_turn =
      fail_health_turn!(
        ctx.db,
        second_rate_member,
        "captured-multi-route-rate-limit-second",
        "Second captured rate limit failure for multi-hold recovery",
        capture["reason"]
      )

    assert {:opened, auth_hold} =
             HarnessHealth.observe(ctx.db, %{
               correlation_id: "provider-auth:wi3-multi-hold",
               harness: "codex",
               host: "testhost",
               failure_class: "auth-dead",
               evidence_kind: "authoritative-provider",
               session_key: auth_member,
               assignment_id: nil,
               observed_at: System.system_time(:millisecond),
               cause: "provider-authoritative credential invalidation",
               principal: "process:tightbeam"
             })

    [rate_hold] =
      Enum.filter(HarnessHealth.active(ctx.db), &(&1.failureClass == "rate-limit-dead"))

    assert Enum.any?(HarnessHealth.active(ctx.db), &(&1.id == auth_hold.id))

    assert {:ok, 1} =
             DB.transaction(ctx.db, fn txn ->
               DB.Txn.q(
                 txn,
                 "UPDATE harness_health_recovery_schedules SET dueAt=?1 WHERE status='pending'",
                 [System.system_time(:millisecond) - 1]
               )

               [[count]] =
                 DB.Txn.q(
                   txn,
                   "SELECT COUNT(*) FROM harness_health_recovery_schedules WHERE status='pending' AND dueAt<?1",
                   [System.system_time(:millisecond)]
                 )

               count
             end)

    send(runner, {:wi3_normal_turn_complete, successful_seq})
    assert_receive {:wi3_normal_turn_committed, ^successful_seq, _assistant_reply_id}, 5_000

    assert HarnessHealth.get(ctx.db, rate_hold.id).state == "resolved"
    assert HarnessHealth.get(ctx.db, auth_hold.id).state == "resolved"
    assert RecoverySchedule.fire_due(ctx.db, System.system_time(:millisecond) + 1_000) == []

    for hold <- [rate_hold, auth_hold] do
      event_id = "harness-health-hold:#{hold.id}:resolved"

      assert {:ok, [[event_json]]} =
               DB.query(ctx.db, "SELECT event FROM row_reaction_events WHERE eventId=?1", [
                 event_id
               ])

      event = JSON.decode!(event_json)
      assert event["cycleRelease"] == false
      assert event["after"]["state"] == "resolved"
      assert notice!(ctx.db, hold.id, "owner-a").state == "attempting"
      assert notice!(ctx.db, hold.id, "owner-a").prompt =~ "Work resumed on the codex harness"
    end

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM harness_recovery_notices WHERE ownerUserId='owner-a'"
             )

    assert {:ok, [[2]]} =
             DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE wakeId LIKE 'harness-recovery:%'")

    assert {:ok, [["gpt-5.6-sol"]]} =
             DB.query(ctx.db, "SELECT model FROM sessions WHERE sessionKey=?1", [
               successful_member
             ])

    assert {:ok, [[rate_event_json]]} =
             DB.query(ctx.db, "SELECT event FROM row_reaction_events WHERE eventId=?1", [
               "harness-health-hold:#{rate_hold.id}:resolved"
             ])

    rate_event = JSON.decode!(rate_event_json)
    assert Enum.any?(rate_event["after"]["routes"], &(&1["model"] == "gpt-5"))
    refute Enum.any?(rate_event["after"]["routes"], &(&1["model"] == "gpt-5.6-sol"))
  end

  test "missing tables and changed notice schema leave other-resolution actions pending", ctx do
    {loaded, _base} = load_seed_reactions!()
    assert Enum.any?(loaded, &(&1.name == "harness-recovery-main-wake"))

    at = System.system_time(:millisecond)
    member = recovery_member!(ctx.db, "agent:wi3:shape-owner-a", "owner-a")
    {missing_table_hold, condition} = open_other_hold!(ctx.db, member, "missing-table", at)

    assert {:ok, []} = DB.query(ctx.db, "DROP TABLE harness_recovery_notices")
    resolve_other_hold!(ctx.db, missing_table_hold, member, condition, at + 1, "missing-table")
    assert HarnessHealth.get(ctx.db, missing_table_hold.id).state == "resolved"
    assert_recovery_action_pending!(ctx.db, missing_table_hold.id)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='harness_recovery_notices'"
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "DELETE FROM supervision_liveness_migrations WHERE migrationId='harness-recovery-notices/v1'"
             )

    assert :ok = HarnessRecoveryNotice.ensure_schema(ctx.db)
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert notice!(ctx.db, missing_table_hold.id, "owner-a").state == "attempting"

    {changed_column_hold, condition} =
      open_other_hold!(ctx.db, member, "changed-column", at + 2)

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "ALTER TABLE harness_recovery_notices RENAME COLUMN prompt TO prompt_missing_for_test"
             )

    resolve_other_hold!(ctx.db, changed_column_hold, member, condition, at + 3, "changed-column")
    assert HarnessHealth.get(ctx.db, changed_column_hold.id).state == "resolved"
    assert_recovery_action_pending!(ctx.db, changed_column_hold.id)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM harness_recovery_notices WHERE holdId=?1", [
               changed_column_hold.id
             ])

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "ALTER TABLE harness_recovery_notices RENAME COLUMN prompt_missing_for_test TO prompt"
             )

    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert notice!(ctx.db, changed_column_hold.id, "owner-a").state == "attempting"
  end

  test "prompt identity conflicts stay retryable after the other-resolution command", ctx do
    {loaded, _base} = load_seed_reactions!()
    assert Enum.any?(loaded, &(&1.name == "harness-recovery-main-wake"))

    at = System.system_time(:millisecond)
    member = recovery_member!(ctx.db, "agent:wi3:prompt-conflict-owner-a", "owner-a")
    {hold, condition} = open_other_hold!(ctx.db, member, "prompt-conflict", at)

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               INSERT INTO harness_recovery_notices
                 (holdId,ownerUserId,state,attempts,wakeId,turnSeq,lastOutcome,canceledBy,
                  prompt,failedRoutesJson,createdAt,updatedAt)
               VALUES (?1,'owner-a','awaiting_main',0,NULL,NULL,NULL,NULL,'wrong saved prompt','[]',?2,?2)
               """,
               [hold.id, at]
             )

    resolve_other_hold!(ctx.db, hold, member, condition, at + 1, "prompt-conflict")
    assert HarnessHealth.get(ctx.db, hold.id).state == "resolved"
    assert_recovery_action_pending!(ctx.db, hold.id)

    assert {:ok, [["awaiting_main", "wrong saved prompt"]]} =
             DB.query(
               ctx.db,
               "SELECT state,prompt FROM harness_recovery_notices WHERE holdId=?1 AND ownerUserId='owner-a'",
               [hold.id]
             )

    assert {:ok, []} =
             DB.query(ctx.db, "DELETE FROM harness_recovery_notices WHERE holdId=?1", [hold.id])

    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert notice!(ctx.db, hold.id, "owner-a").state == "attempting"
  end

  test "notice argument guard failures outside the effect body leave the action pending", ctx do
    {loaded, base} = load_seed_reactions!()
    assert Enum.any?(loaded, &(&1.name == "harness-recovery-main-wake"))

    rule_path = Path.join([base, "identity", "rules", "harness-recovery-main-wake.toml"])
    original_rule = File.read!(rule_path)

    broken_rule =
      String.replace(
        original_rule,
        "value.hold_id = { ref = \"event.source.id\" }",
        "value.hold_id = { ref = \"event.after.missing_id\" }"
      )

    assert broken_rule != original_rule
    File.write!(rule_path, broken_rule)
    reload_identity_rules!(base)

    at = System.system_time(:millisecond)
    member = recovery_member!(ctx.db, "agent:wi3:guard-owner-a", "owner-a")
    {hold, condition} = open_other_hold!(ctx.db, member, "guard-failure", at)
    resolve_other_hold!(ctx.db, hold, member, condition, at + 1, "guard-failure")

    assert HarnessHealth.get(ctx.db, hold.id).state == "resolved"
    assert_recovery_action_pending!(ctx.db, hold.id)

    File.write!(rule_path, original_rule)
    reload_identity_rules!(base)
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert notice!(ctx.db, hold.id, "owner-a").state == "attempting"
  end

  test "other resolution delivers its distinct text without claiming a successful turn", ctx do
    {loaded, _base} = load_seed_reactions!()
    assert Enum.any?(loaded, &(&1.name == "harness-recovery-main-wake"))

    member = recovery_member!(ctx.db, "agent:wi3:other-owner-a", "owner-a")
    at = System.system_time(:millisecond)
    recovery_condition = "a provider health probe succeeds"

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "codex",
               host: "testhost",
               source_session_key: member,
               principal: {:session, member},
               description: "provider returned an unclassified transport failure",
               evidence_mode: "exact_error",
               observed_state: "the provider connection was unavailable",
               exact_observed_error: "transport reset by peer",
               exact_probe: "GET provider health endpoint",
               recovery_condition: recovery_condition,
               not_known_class_reason: "the response is outside the named failure classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "wi3-other-opening"
             })

    assert opened.failureClass == "other"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM row_reaction_actions WHERE eventId=?1",
               ["harness-health-hold:#{opened.id}:opened"]
             )

    assert {:ok, %{state: "closed", outcome: "confirmed_other"}} =
             HarnessHealth.review_other(ctx.db, %{
               incident_id: opened.id,
               outcome: "confirmed_other",
               cause: "the provider evidence remains outside the named classes",
               principal: {:session, member},
               idempotency_key: "wi3-other-review"
             })

    probe = "provider health probe returned a successful response"
    resolved_at = at + 1

    assert {:resolved, resolved} =
             HarnessHealth.resolve_other(ctx.db, %{
               harness: "codex",
               host: "testhost",
               incident_id: opened.id,
               session_key: member,
               principal: {:session, member},
               observed_state: probe,
               exact_probe: "GET provider health endpoint",
               output_digest: :crypto.hash(:sha256, probe) |> Base.encode16(case: :lower),
               recovery_condition_digest:
                 :crypto.hash(:sha256, recovery_condition) |> Base.encode16(case: :lower),
               recovery_satisfied: true,
               world_status: "PROVEN",
               redaction_confirmed: true,
               cause: "the recorded provider health probe now succeeds",
               observed_at: resolved_at,
               accepted_at: resolved_at,
               idempotency_key: "wi3-other-resolution"
             })

    assert resolved.state == "resolved"
    hold = HarnessHealth.get(ctx.db, opened.id)

    assert {:ok, [[event_json]]} =
             DB.query(
               ctx.db,
               "SELECT event FROM row_reaction_events WHERE eventId=?1",
               ["harness-health-hold:#{opened.id}:resolved"]
             )

    event = JSON.decode!(event_json)
    assert event["after"]["state"] == "resolved"
    assert event["after"]["failureClass"] == "other"
    assert event["cycleRelease"] == false

    notice = notice!(ctx.db, opened.id, "owner-a")
    assert notice.state == "attempting"
    assert notice.attempts == 1
    assert notice.failed_routes_json == JSON.encode!(event["after"]["routes"])

    assert {:ok, [[session_key, prompt, due_at, class]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,prompt,dueAt,class FROM wakes WHERE wakeId=?1",
               [notice.wake_id]
             )

    assert session_key == ctx.main.session_key
    assert prompt == expected_other_resolution_prompt(hold, opened.id, event["at"], 1)
    assert prompt =~ "was cleared of an unclassified (other) outage."
    assert prompt =~ "evidence that its recorded recovery condition is now met."
    assert prompt =~ "This does not mean a turn has succeeded on this harness"
    refute prompt =~ "Work resumed"
    refute prompt =~ "answered in one check"
    assert due_at == event["at"]
    assert class == "blocker"
  end

  test "WI932 R7 release event admits one due-now Main notice per held owner", ctx do
    {loaded, _base} = load_seed_reactions!()
    assert Enum.any?(loaded, &(&1.name == "harness-recovery-main-wake"))

    owner_b_main = ensure_main_session(ctx.db, "owner-b")
    _owner_c_main = ensure_main_session(ctx.db, "owner-c")
    member_a1 = recovery_member!(ctx.db, "agent:wi3:r7-owner-a-1", "owner-a")
    member_a2 = recovery_member!(ctx.db, "agent:wi3:r7-owner-a-2", "owner-a")
    member_b1 = recovery_member!(ctx.db, "agent:wi3:r7-owner-b-1", "owner-b")

    capture =
      Path.join([__DIR__, "fixtures", "harness_recovery", "main-wake-c1-codex.json"])
      |> File.read!()
      |> JSON.decode!()

    provenance = capture["provenance"]
    assert provenance["captureArtifactId"] == "art_c67b8748"

    assert provenance["captureArtifactSha256"] ==
             "bceb0218b28055164dfc34ba04e92c202a861c3f9dc05c36f64237631fdcbaca"

    assert HarnessHealth.classify_turn_failure(capture["reason"]) == "rate-limit-dead"

    _failed_turn_a =
      fail_health_turn!(
        ctx.db,
        member_a1,
        "captured-r7-owner-a",
        "Captured outage failure for WI3 R7 integration",
        capture["reason"]
      )

    _failed_turn_b =
      fail_health_turn!(
        ctx.db,
        member_b1,
        "captured-r7-owner-b",
        "Captured outage failure for WI3 R7 integration",
        capture["reason"]
      )

    [hold] = HarnessHealth.active(ctx.db)
    held = HarnessHealth.get(ctx.db, hold.id)
    assert held.state == "open"
    assert held.failureClass == "rate-limit-dead"
    assert held.affectedSessions == Enum.sort([member_a1, member_a2, member_b1])

    assert {:ok, %{"routesComplete" => true, "routes" => routes}} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.RowReactions.Snapshot.harness_health_hold(txn, hold.id)
             end)

    assert routes != []

    assert {:ok, [[cycle_id]]} =
             DB.query(
               ctx.db,
               "SELECT cycleId FROM harness_health_recovery_schedules WHERE holdId=?1 AND status='pending'",
               [hold.id]
             )

    started_at = System.system_time(:millisecond) + 1

    assert {:ok, 1} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "UPDATE harness_health_recovery_schedules SET dueAt=?2 WHERE holdId=?1 AND cycleId=?3 AND status='pending'",
                 [hold.id, started_at, cycle_id]
               )

               Tightbeam.DB.Txn.changes(txn)
             end)

    assert [%{"cycle_id" => ^cycle_id}] = RecoverySchedule.fire_due(ctx.db, started_at)
    seed_running_recovery_checks!(ctx.db, hold.id, cycle_id, routes, started_at, "owner-a")

    last_route = List.last(routes)

    for route <- Enum.drop(routes, -1) do
      assert {:ok, :ok} =
               DB.transaction(ctx.db, fn txn ->
                 RecoveryCheck.record_result_in_txn(
                   txn,
                   hold.id,
                   cycle_id,
                   RecoveryCheck.route_key(route),
                   "succeeded",
                   nil,
                   started_at + 2
                 )
               end)
    end

    install_notice_failure_trigger!(ctx.db)

    assert {:error, _error} =
             DB.transaction(ctx.db, fn txn ->
               RecoveryCheck.record_result_in_txn(
                 txn,
                 hold.id,
                 cycle_id,
                 RecoveryCheck.route_key(last_route),
                 "succeeded",
                 nil,
                 started_at + 2
               )
             end)

    assert HarnessHealth.get(ctx.db, hold.id).state == "open"
    assert HarnessHealth.unavailable?(ctx.db, "codex", "testhost")

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM harness_recovery_notices WHERE holdId=?1",
               [hold.id]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wakes WHERE wakeId LIKE ?1",
               ["harness-recovery:#{hold.id}:%"]
             )

    remove_notice_failure_trigger!(ctx.db)

    assert {:ok, {:released, release}} =
             DB.transaction(ctx.db, fn txn ->
               RecoveryCheck.record_result_in_txn(
                 txn,
                 hold.id,
                 cycle_id,
                 RecoveryCheck.route_key(last_route),
                 "succeeded",
                 nil,
                 started_at + 2
               )
             end)

    assert release.correlation == "harness-health-check-cycle:#{hold.id}:#{cycle_id}"
    assert HarnessHealth.get(ctx.db, hold.id).state == "resolved"

    event_id = "harness-health-hold:#{hold.id}:resolved"

    assert {:ok, [[event_json, facts_json]]} =
             DB.query(
               ctx.db,
               "SELECT event,facts FROM row_reaction_events WHERE eventId=?1",
               [event_id]
             )

    event = JSON.decode!(event_json)
    facts = JSON.decode!(facts_json)
    assert event["kind"] == "harness_health_hold"
    assert event["transition"] == "resolved"
    assert event["source"] == %{"kind" => "harness_health_incident", "id" => hold.id}
    assert event["cycleRelease"] == true
    assert event["resolutionCorrelation"] == release.correlation
    assert event["after"]["routes"] == routes
    assert event["after"]["resolutionCorrelation"] == release.correlation
    assert facts["hold"]["state"] == "resolved"
    assert facts["hold"]["ownerUserId"] == "owner-a"

    assert {:ok, [action]} =
             DB.transaction(ctx.db, fn txn ->
               Store.actions(txn, event["org"], event_id)
             end)

    assert action["status"] == "accepted"

    assert action["result"]["notice_episodes"] == [
             %{"hold_id" => hold.id, "owner_user_id" => "owner-a"},
             %{"hold_id" => hold.id, "owner_user_id" => "owner-b"}
           ]

    notice_a = notice!(ctx.db, hold.id, "owner-a")
    notice_b = notice!(ctx.db, hold.id, "owner-b")

    assert notice_a.state == "attempting"
    assert notice_a.attempts == 1
    assert notice_a.failed_routes_json == JSON.encode!(routes)
    assert notice_b.state == "attempting"
    assert notice_b.attempts == 1
    assert notice_b.failed_routes_json == JSON.encode!(routes)

    assert {:ok, [[owner_a, session_a, prompt_a, due_a]]} =
             DB.query(
               ctx.db,
               "SELECT ownerUserId,sessionKey,prompt,dueAt FROM wakes WHERE wakeId=?1",
               [notice_a.wake_id]
             )

    assert owner_a == "owner-a"
    assert session_a == ctx.main.session_key
    assert prompt_a == expected_recovery_prompt(held, hold.id, event["at"], routes, 2)
    assert due_a == event["at"]

    assert {:ok, [[owner_b, session_b, prompt_b, due_b]]} =
             DB.query(
               ctx.db,
               "SELECT ownerUserId,sessionKey,prompt,dueAt FROM wakes WHERE wakeId=?1",
               [notice_b.wake_id]
             )

    assert owner_b == "owner-b"
    assert session_b == owner_b_main.session_key
    assert prompt_b == expected_recovery_prompt(held, hold.id, event["at"], routes, 1)
    assert due_b == event["at"]

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM harness_recovery_notices WHERE holdId=?1 AND ownerUserId='owner-c'",
               [hold.id]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wakes WHERE sessionKey IN (?1,?2,?3)",
               [member_a1, member_a2, member_b1]
             )
  end

  test "a missing Main leaves the notice retryable until the owner Main activates", ctx do
    at = System.system_time(:millisecond)
    release!(ctx.db, "hold-no-main", "owner-late", "Recovery prompt", [@route], at)

    waiting = notice!(ctx.db, "hold-no-main", "owner-late")
    assert waiting.state == "awaiting_main"
    assert waiting.attempts == 0
    assert waiting.wake_id == nil
    assert waiting.last_outcome == "no_owner_main"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wakes WHERE wakeId LIKE 'harness-recovery:hold-no-main:%'"
             )

    _main = ensure_main_session(ctx.db, "owner-late")

    retried = notice!(ctx.db, "hold-no-main", "owner-late")
    assert retried.state == "attempting"
    assert retried.attempts == 1
    assert retried.wake_id == "harness-recovery:hold-no-main:owner-late:1"
  end

  test "non-delivery retries only on a later Main signal; deliberate cancellation is terminal",
       ctx do
    at = System.system_time(:millisecond)
    release!(ctx.db, "hold-retry", "owner-a", "Recovery prompt", [@route], at)
    first = notice!(ctx.db, "hold-retry", "owner-a")
    first_prompt = first.prompt

    assert {:ok, [[first_wake_prompt]]} =
             DB.query(ctx.db, "SELECT prompt FROM wakes WHERE wakeId=?1", [first.wake_id])

    assert first_wake_prompt == first_prompt

    assert {:ok, {:canceled, {wake_id, _sender_notice}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.undeliverable_delivery_in_txn(
                 txn,
                 first.wake_id,
                 "owner Main became unavailable before delivery",
                 at + 1
               )
             end)

    assert wake_id == first.wake_id

    waiting = notice!(ctx.db, "hold-retry", "owner-a")
    assert waiting.state == "awaiting_main"
    assert waiting.attempts == 1
    assert waiting.last_outcome == "target_unresolvable"

    assert :ok = HarnessRecoveryNotice.retry_owner(ctx.db, "owner-a", at + 2)
    second = notice!(ctx.db, "hold-retry", "owner-a")
    assert second.state == "attempting"
    assert second.attempts == 2
    assert second.wake_id == "harness-recovery:hold-retry:owner-a:2"
    assert second.prompt == first_prompt

    assert {:ok, [[second_wake_prompt]]} =
             DB.query(ctx.db, "SELECT prompt FROM wakes WHERE wakeId=?1", [second.wake_id])

    assert second_wake_prompt == first_wake_prompt

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               HarnessRecoveryNotice.settle_wake_cancellation_in_txn(
                 txn,
                 second.wake_id,
                 %{"kind" => "user", "id" => "owner-a"},
                 "requester_withdrew",
                 at + 3
               )
             end)

    canceled = notice!(ctx.db, "hold-retry", "owner-a")
    assert canceled.state == "canceled"
    assert canceled.last_outcome == "requester_withdrew"
    assert canceled.canceled_by == JSON.encode!(%{"kind" => "user", "id" => "owner-a"})

    assert :ok = HarnessRecoveryNotice.retry_all(ctx.db, at + 4)
    assert notice!(ctx.db, "hold-retry", "owner-a").attempts == 2

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "harness_recovery_notice_canceled" and
               event.subject == "hold-retry" and
               event.detail =~ "requester_withdrew" and
               event.detail =~ "\"canceled_by\":{\"id\":\"owner-a\",\"kind\":\"user\"}"
           end)
  end

  test "notice is delivered only after its linked Main turn is terminal delivered", ctx do
    at = System.system_time(:millisecond)
    prompt = "Recovery prompt"
    release!(ctx.db, "hold-delivered", "owner-a", prompt, [@route], at)
    notice = notice!(ctx.db, "hold-delivered", "owner-a")

    assert {:ok, {:appended, _session_key, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               DB.Txn.q(
                 txn,
                 "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending'",
                 [notice.wake_id, at]
               )

               Gateway.deliver_prompt_in_txn(
                 txn,
                 ctx.main.session_key,
                 "process:tightbeam",
                 prompt,
                 wake_id: notice.wake_id,
                 sender: "process:tightbeam"
               )
             end)

    assert notice!(ctx.db, "hold-delivered", "owner-a").state == "attempting"

    assert {:ok, [[turn_seq]]} =
             DB.query(
               ctx.db,
               "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1",
               [notice.wake_id]
             )

    assert is_integer(turn_seq)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               HarnessRecoveryNotice.sync_attempt_turn_in_txn(txn, notice.wake_id)
             end)

    assert notice!(ctx.db, "hold-delivered", "owner-a").turn_seq == turn_seq

    assert {:ok, turn} = Ledger.claim_next(ctx.db, ctx.main.session_key, "main-lane")

    assert {:ok, true} =
             DB.transaction(ctx.db, fn txn ->
               Ledger.finish_in_txn(
                 txn,
                 turn.seq,
                 "delivered",
                 nil,
                 owner_lease: turn.owner_lease
               )
             end)

    delivered = notice!(ctx.db, "hold-delivered", "owner-a")
    assert delivered.state == "delivered"
    assert delivered.turn_seq == turn.seq
    assert delivered.attempts == 1
  end

  test "batched notice settles through its source wake delivery turn", ctx do
    at = System.system_time(:millisecond)
    prompt = "Recovery prompt through a batch"
    release!(ctx.db, "hold-batch", "owner-a", prompt, [@route], at)
    notice = notice!(ctx.db, "hold-batch", "owner-a")
    envelope = "[from process:tightbeam]\n\n[batched notices: 1]\n#{prompt}"

    assert {:ok, {:appended, _session_key, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               carrier =
                 Wakes.schedule_in_txn(txn, %{
                   wake_id: "harness-recovery-batch-carrier",
                   session_key: ctx.main.session_key,
                   owner_user_id: "owner-a",
                   origin: "process:tightbeam",
                   prompt: envelope,
                   due_at: at,
                   class: "fyi"
                 })

               DB.Txn.q(
                 txn,
                 "INSERT INTO notice_batches(batchId,recipientAddress,sessionKey,visibilityScope,policyRevision,state,dueAt,openedAt,sealedAt,releaseCause,deliveryToken,envelope,envelopeSha256,deliveryWakeId,memberCount,renderedBytes) VALUES(?1,?2,?3,'owner','test','delivery_pending',?4,?4,?4,'turn-boundary','delivery-token',?5,?6,?7,1,?8)",
                 [
                   "harness-recovery-batch",
                   "owner-a",
                   ctx.main.session_key,
                   at,
                   envelope,
                   Base.encode16(:crypto.hash(:sha256, envelope), case: :lower),
                   carrier.wake_id,
                   byte_size(envelope)
                 ]
               )

               DB.Txn.q(
                 txn,
                 "INSERT INTO notice_batch_members(memberId,batchId,sourceWakeId,policyRef,recipientAddress,visibilityScope,publicationSeq,policyRevision,senderPrincipal,cause,class,payload,renderedBytes,state,addedAt) VALUES('harness-recovery-batch-member','harness-recovery-batch',?1,'test','owner-a','owner',1,'test','process:tightbeam','wake','fyi',?2,?3,'included',?4)",
                 [notice.wake_id, JSON.encode!(%{"prompt" => prompt}), byte_size(prompt), at]
               )

               Gateway.deliver_prompt_in_txn(
                 txn,
                 ctx.main.session_key,
                 "process:tightbeam",
                 envelope,
                 wake_id: carrier.wake_id,
                 fire_wake_in_txn: true
               )
             end)

    assert {:ok, [[turn_seq]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [
               notice.wake_id
             ])

    assert is_integer(turn_seq)
    assert notice!(ctx.db, "hold-batch", "owner-a").turn_seq == turn_seq

    assert {:ok, turn} = Ledger.claim_next(ctx.db, ctx.main.session_key, "main-lane")
    assert turn.seq == turn_seq

    assert {:ok, true} =
             DB.transaction(ctx.db, fn txn ->
               Ledger.finish_in_txn(
                 txn,
                 turn.seq,
                 "delivered",
                 nil,
                 owner_lease: turn.owner_lease
               )
             end)

    delivered = notice!(ctx.db, "hold-batch", "owner-a")
    assert delivered.state == "delivered"
    assert delivered.turn_seq == turn.seq
    assert delivered.attempts == 1

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "harness_recovery_notice_delivered" and event.subject == "hold-batch" and
               event.detail =~ "\"turn_seq\":#{turn.seq}"
           end)
  end

  test "a sealed canceled prompt stays canceled and logs late delivery at terminal delivery",
       ctx do
    at = System.system_time(:millisecond)
    prompt = "Recovery prompt"
    release!(ctx.db, "hold-late", "owner-a", prompt, [@route], at)
    notice = notice!(ctx.db, "hold-late", "owner-a")

    assert {:ok, {:appended, _session_key, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               DB.Txn.q(
                 txn,
                 "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending'",
                 [notice.wake_id, at]
               )

               Gateway.deliver_prompt_in_txn(
                 txn,
                 ctx.main.session_key,
                 "process:tightbeam",
                 prompt,
                 wake_id: notice.wake_id,
                 sender: "process:tightbeam"
               )
             end)

    assert {:ok, [[turn_seq]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [
               notice.wake_id
             ])

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               HarnessRecoveryNotice.settle_wake_cancellation_in_txn(
                 txn,
                 notice.wake_id,
                 %{"kind" => "user", "id" => "owner-a"},
                 "requester_withdrew",
                 at + 1
               )
             end)

    assert notice!(ctx.db, "hold-late", "owner-a").state == "canceled"

    refute Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "harness_recovery_notice_late_delivery" and
               event.subject == "hold-late"
           end)

    assert {:ok, turn} = Ledger.claim_next(ctx.db, ctx.main.session_key, "main-lane")
    assert turn.seq == turn_seq

    assert {:ok, true} =
             DB.transaction(ctx.db, fn txn ->
               Ledger.finish_in_txn(
                 txn,
                 turn.seq,
                 "delivered",
                 nil,
                 owner_lease: turn.owner_lease
               )
             end)

    canceled = notice!(ctx.db, "hold-late", "owner-a")
    assert canceled.state == "canceled"
    assert canceled.turn_seq == turn.seq

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "harness_recovery_notice_late_delivery" and
               event.subject == "hold-late" and
               event.detail =~ "\"turn_seq\":#{turn.seq}"
           end)

    assert :ok = HarnessRecoveryNotice.retry_all(ctx.db, at + 3)
    assert notice!(ctx.db, "hold-late", "owner-a").attempts == 1
  end

  test "gateway startup settles an interrupted attempt and retries through LaneManager", ctx do
    at = System.system_time(:millisecond)
    prompt = "Recovery prompt"
    release!(ctx.db, "hold-restart", "owner-a", prompt, [@route], at)
    first = notice!(ctx.db, "hold-restart", "owner-a")

    assert {:ok, {:appended, _session_key, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               DB.Txn.q(
                 txn,
                 "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending'",
                 [first.wake_id, at]
               )

               Gateway.deliver_prompt_in_txn(
                 txn,
                 ctx.main.session_key,
                 "process:tightbeam",
                 prompt,
                 wake_id: first.wake_id,
                 sender: "process:tightbeam"
               )
             end)

    assert {:ok, running} = Ledger.claim_next(ctx.db, ctx.main.session_key, "main-lane")
    assert notice!(ctx.db, "hold-restart", "owner-a").turn_seq == running.seq

    task_sup = String.to_atom("harness_recovery_tasks_#{System.unique_integer([:positive])}")
    lane_sup = String.to_atom("harness_recovery_lanes_#{System.unique_integer([:positive])}")
    manager = String.to_atom("harness_recovery_manager_#{System.unique_integer([:positive])}")

    start_supervised!({Task.Supervisor, name: task_sup})

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: lane_sup})

    start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})

    start_supervised!(
      {LaneManager,
       name: manager,
       db: ctx.db,
       lane_sup: lane_sup,
       task_sup: task_sup,
       runner: fn _turn -> :ok end,
       terminal_publisher: fn _row -> :ok end,
       on_terminal: fn _session_key, _seq -> :ok end,
       interval: 60_000}
    )

    assert notice!(ctx.db, "hold-restart", "owner-a").state == "attempting"
    retried = notice!(ctx.db, "hold-restart", "owner-a")
    assert retried.attempts == 2
    assert retried.wake_id == "harness-recovery:hold-restart:owner-a:2"
    assert retried.turn_seq == nil

    assert {:ok, [["failed_unknown"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [running.seq])
  end

  defp load_seed_reactions! do
    base =
      Path.join(
        System.tmp_dir!(),
        "wi3bb2-recovery-seed-#{System.unique_integer([:positive])}"
      )

    assert :initialized = Identity.init!(base)

    loaded =
      Identity.with_recovery_law!(base, fn law_base, revision ->
        Rules.load!(base, [], law_base: law_base, revision: revision)
        Rules.effective_snapshot().reactions
      end)

    on_exit(fn ->
      File.rm_rf!(base)

      empty_base =
        Path.join(
          System.tmp_dir!(),
          "wi3bb2-empty-rule-base-#{System.unique_integer([:positive])}"
        )

      Rules.load!(empty_base, [])
    end)

    {loaded, base}
  end

  defp seed_running_recovery_checks!(db, hold_id, cycle_id, routes, started_at, org) do
    routes
    |> Enum.sort_by(&RecoveryCheck.route_key/1)
    |> Enum.with_index()
    |> Enum.each(fn {route, index} ->
      route_key = RecoveryCheck.route_key(route)
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

  defp start_normal_turn_path!(db, parent) do
    task_sup = String.to_atom("wi3_turn_tasks_#{System.unique_integer([:positive])}")
    lane_sup = String.to_atom("wi3_turn_lanes_#{System.unique_integer([:positive])}")
    manager_name = String.to_atom("wi3_turn_manager_#{System.unique_integer([:positive])}")

    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})
    start_supervised!({Task.Supervisor, name: task_sup})

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: lane_sup})

    runner = fn turn ->
      send(parent, {:wi3_normal_turn_started, turn.seq, self()})
      seq = turn.seq

      receive do
        {:wi3_normal_turn_complete, ^seq} -> :ok
      after
        30_000 -> raise "ordinary turn fixture was not released to complete"
      end

      session = Org.get(db, turn.session_key)

      {:ok,
       %{
         terminal_publish: fn terminal ->
           send(parent, {:wi3_normal_turn_terminal, turn.seq, terminal})
         end,
         record_in_txn: fn txn ->
           {:appended, reply} =
             Projection.append_in_txn(txn, %{
               session_key: turn.session_key,
               role: "assistant",
               content: "The ordinary turn reply survives notice failure.",
               sender: "tightbeam",
               reply_to_message_id: turn.message_id
             })

           HarnessHealth.resolve_normal_turn_in_txn(txn, session, turn)

           fn -> send(parent, {:wi3_normal_turn_committed, turn.seq, reply.id}) end
         end
       }}
    end

    manager =
      start_supervised!(
        {LaneManager,
         db: db,
         lane_sup: lane_sup,
         task_sup: task_sup,
         name: manager_name,
         runner: runner,
         terminal_publisher: fn _row -> :ok end,
         on_terminal: fn _session_key, _seq -> :ok end,
         interval: 60_000}
      )

    %{manager: manager, conn_registry: Tightbeam.ConnRegistry}
  end

  defp captured_fixture!(file) do
    Path.join([__DIR__, "fixtures", "harness_recovery", file])
    |> File.read!()
    |> JSON.decode!()
  end

  defp open_other_hold!(db, member, key, at) do
    recovery_condition = "a provider health probe succeeds"

    assert {:opened, hold} =
             HarnessHealth.observe_other(db, %{
               harness: "codex",
               host: "testhost",
               source_session_key: member,
               principal: {:session, member},
               description: "WI3bb2 test other outage #{key}",
               evidence_mode: "exact_error",
               observed_state: "the provider connection was unavailable",
               exact_observed_error: "transport reset by peer",
               exact_probe: "GET provider health endpoint",
               recovery_condition: recovery_condition,
               not_known_class_reason: "the response is outside the named failure classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 500,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "wi3-other-opening-#{key}"
             })

    assert {:ok, %{state: "closed"}} =
             HarnessHealth.review_other(db, %{
               incident_id: hold.id,
               outcome: "confirmed_other",
               cause: "the provider evidence remains outside the named classes",
               principal: {:session, member},
               idempotency_key: "wi3-other-review-#{key}"
             })

    {hold, recovery_condition}
  end

  defp resolve_other_hold!(db, hold, member, recovery_condition, at, key) do
    probe = "provider health probe returned a successful response"

    assert {:resolved, resolved} =
             HarnessHealth.resolve_other(db, %{
               harness: "codex",
               host: "testhost",
               incident_id: hold.id,
               session_key: member,
               principal: {:session, member},
               observed_state: probe,
               exact_probe: "GET provider health endpoint",
               output_digest: :crypto.hash(:sha256, probe) |> Base.encode16(case: :lower),
               recovery_condition_digest:
                 :crypto.hash(:sha256, recovery_condition) |> Base.encode16(case: :lower),
               recovery_satisfied: true,
               world_status: "PROVEN",
               redaction_confirmed: true,
               cause: "the recorded provider health probe now succeeds",
               observed_at: at,
               accepted_at: at,
               idempotency_key: "wi3-other-resolution-#{key}"
             })

    resolved
  end

  defp assert_recovery_action_pending!(db, hold_id) do
    event_id = "harness-health-hold:#{hold_id}:resolved"

    assert {:ok, [["pending"]]} =
             DB.query(
               db,
               "SELECT status FROM row_reaction_actions WHERE eventId=?1 AND family='harness-recovery' AND slot='notice'",
               [event_id]
             )
  end

  defp reload_identity_rules!(base) do
    Identity.with_recovery_law!(base, fn law_base, revision ->
      Rules.load!(base, [], law_base: law_base, revision: revision)
    end)
  end

  defp fail_health_turn!(db, session_key, message_id, prompt, reason) do
    {:ok, source_seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: message_id,
        origin: "agent:health-redelivery",
        prompt: prompt
      })

    {:ok, turn} = Ledger.claim_next(db, session_key, "health-redelivery-test")
    turn = Map.put(turn, :session_key, session_key)
    session = Org.get(db, session_key)

    assert {:ok, post_commit} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(
                        txn,
                        source_seq,
                        "failed",
                        "captured harness health failure",
                        owner_lease: turn.owner_lease
                      )

               HarnessHealth.observe_turn_failure_in_txn(
                 txn,
                 session,
                 turn,
                 :prompt,
                 reason
               )
             end)

    if is_function(post_commit, 0), do: post_commit.()
    turn
  end

  defp recovery_member!(db, session_key, owner_user_id, model \\ "gpt-5") do
    session =
      Org.create(db, %{
        session_key: session_key,
        display_name: session_key,
        owner_user_id: owner_user_id,
        origin: "user:#{owner_user_id}",
        archetype: "coder",
        harness: "codex",
        provider: "openai",
        model: Model.new(model),
        host: "testhost"
      })

    session.session_key
  end

  defp expected_recovery_prompt(hold, hold_id, released_at, routes, member_count) do
    """
    The #{hold.harness} harness on #{hold.host} recovered from a #{hold.failureClass} outage.
    Hold #{hold_id} opened at #{hold.openedAt} and was released at #{released_at} after every affected model route (#{JSON.encode!(routes)}) answered in one check. #{member_count} of your sessions were held.
    Use your installed and learned Kung Fu to find live agents whose work stalled on this harness and host, and resume only those agent graphs. Do not wake or resume unrelated agents.
    """
    |> String.trim()
  end

  defp expected_work_resumed_prompt(hold, hold_id, resolved_at, member_count) do
    """
    Work resumed on the #{hold.harness} harness on #{hold.host} after a #{hold.failureClass} outage. Hold #{hold_id} opened at #{hold.openedAt} and was resolved at #{resolved_at}. This does not mean every model route on this harness is back. #{member_count} of your sessions were held.
    Use your installed and learned Kung Fu to find live agents whose work stalled on this harness and host, and resume only those agent graphs. Do not wake or resume unrelated agents.
    """
    |> String.trim()
  end

  defp expected_other_resolution_prompt(hold, hold_id, resolved_at, member_count) do
    """
    The #{hold.harness} harness on #{hold.host} was cleared of an unclassified (other) outage.
    Hold #{hold_id} opened at #{hold.openedAt} and was resolved at #{resolved_at} on evidence that its recorded recovery condition is now met. This does not mean a turn has succeeded on this harness or that every model route on it is back. #{member_count} of your sessions were held.
    Use your installed and learned Kung Fu to find live agents whose work stalled on this harness and host, and resume only those agent graphs. Do not wake or resume unrelated agents.
    """
    |> String.trim()
  end

  defp install_notice_failure_trigger!(db) do
    assert {:ok, []} =
             DB.query(db, """
             CREATE TRIGGER fail_harness_recovery_notice_insert
             BEFORE INSERT ON harness_recovery_notices
             BEGIN SELECT RAISE(ABORT, 'injected recovery notice failure'); END
             """)
  end

  defp remove_notice_failure_trigger!(db) do
    assert {:ok, []} = DB.query(db, "DROP TRIGGER fail_harness_recovery_notice_insert")
  end

  defp release!(db, hold_id, owner_id, prompt, routes, at) do
    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               HarnessRecoveryNotice.create_notice_in_txn(
                 txn,
                 hold_id,
                 owner_id,
                 prompt,
                 routes,
                 at
               )
             end)
  end

  defp notice!(db, hold_id, owner_id) do
    {:ok, notice} =
      DB.transaction(db, fn txn ->
        HarnessRecoveryNotice.notice_in_txn(txn, hold_id, owner_id)
      end)

    assert is_map(notice)
    notice
  end
end
