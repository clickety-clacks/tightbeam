defmodule Tightbeam.RecurrenceSuppressionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Model, Org, RecurrenceSuppression, Rules}

  setup do
    db = :"recurrence_suppression_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('mike',1,1)")

    main = session(db, "agent:main:clawline:mike:main", nil, "main")
    parent = session(db, "parent", main.session_key, "custom")
    target = session(db, "target", parent.session_key, "custom")

    %{db: db, main: main, parent: parent, target: target}
  end

  test "first delivery, receipt replay, recovery order, rearm, and scope are durable", ctx do
    config = config(9)
    first = occurrence(ctx.target.session_key, "asg_one", "r1", 1)

    assert :dispatch = RecurrenceSuppression.prepare_first(ctx.db, first, "dispatch-one")

    assert :deliver =
             RecurrenceSuppression.record_first(
               ctx.db,
               config,
               first,
               "dispatch-one",
               evidence(true, "recovered")
             )

    assert :delivered = RecurrenceSuppression.prepare_first(ctx.db, first, "dispatch-one")

    second = occurrence(ctx.target.session_key, "asg_one", "r2", 2)

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               second,
               evidence(true, "recovered"),
               evidence(false, "recurred")
             )

    # The recovery fact already matched when generation one opened, so it is stale.
    assert {:ok, [[nil]]} =
             DB.query(
               ctx.db,
               "SELECT recoveredSequence FROM recurrence_suppression_episodes WHERE subject='asg_one'"
             )

    changed_away = occurrence(ctx.target.session_key, "asg_one", "r3", 3)

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               changed_away,
               evidence(false, "recovered"),
               evidence(false, "recurred")
             )

    recovered = occurrence(ctx.target.session_key, "asg_one", "r4", 4)

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               recovered,
               evidence(true, "recovered"),
               evidence(false, "recurred")
             )

    same_sequence = occurrence(ctx.target.session_key, "asg_one", "r5", 4)

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               same_sequence,
               evidence(true, "recovered"),
               evidence(true, "recurred")
             )

    recurrence = occurrence(ctx.target.session_key, "asg_one", "r6", 5)

    assert {:rearmed, 2} =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               recurrence,
               evidence(true, "recovered"),
               evidence(true, "recurred")
             )

    # A receipt is the same durable occurrence across every generation.
    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               second,
               evidence(false, "recovered"),
               evidence(false, "recurred")
             )

    assert {:rearmed, 2} =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               recurrence,
               evidence(false, "recovered"),
               evidence(false, "recurred")
             )

    other_subject = occurrence(ctx.target.session_key, "asg_two", "r7", 6)
    assert :dispatch = RecurrenceSuppression.prepare_first(ctx.db, other_subject, "dispatch-two")

    assert :deliver =
             RecurrenceSuppression.record_first(
               ctx.db,
               config,
               other_subject,
               "dispatch-two",
               evidence(false, "recovered")
             )

    assert {:ok, [[2, 0, nil, 0]]} =
             DB.query(
               ctx.db,
               "SELECT generation,suppressedCount,recoveredSequence,escalated FROM recurrence_suppression_episodes WHERE subject='asg_one'"
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM recurrence_suppression_events WHERE outcome='recurrence_first_delivered' AND subject='asg_one'"
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM recurrence_suppression_events WHERE cause LIKE '%SECRET%' OR principal LIKE '%SECRET%'"
             )
  end

  test "threshold audits unavailable operational parent and falls back to Main", ctx do
    config = config(2)
    first = occurrence(ctx.target.session_key, "asg_threshold", "r1", 1)
    assert :dispatch = RecurrenceSuppression.prepare_first(ctx.db, first, "dispatch-threshold")

    assert :deliver =
             RecurrenceSuppression.record_first(
               ctx.db,
               config,
               first,
               "dispatch-threshold",
               evidence(false, "recovered")
             )

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               occurrence(ctx.target.session_key, "asg_threshold", "r2", 2),
               evidence(false, "recovered"),
               evidence(false, "recurred")
             )

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               occurrence(ctx.target.session_key, "asg_threshold", "r3", 3),
               evidence(false, "recovered"),
               evidence(false, "recurred")
             )

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               occurrence(ctx.target.session_key, "asg_threshold", "r4", 4),
               evidence(false, "recovered"),
               evidence(false, "recurred")
             )

    assert {:ok, [[main, 1]]} =
             DB.query(ctx.db, "SELECT sessionKey,count(*) FROM wakes GROUP BY sessionKey")

    assert main == ctx.main.session_key

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE sessionKey='target'")

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM recurrence_suppression_events WHERE outcome='recurrence_escalated' AND cause='operational-parent-unavailable'"
             )
  end

  test "concurrent matching recurrences open exactly one next generation", ctx do
    config = config(99)
    first = occurrence(ctx.target.session_key, "asg_race", "race-first", 1)
    assert :dispatch = RecurrenceSuppression.prepare_first(ctx.db, first, "dispatch-race")

    assert :deliver =
             RecurrenceSuppression.record_first(
               ctx.db,
               config,
               first,
               "dispatch-race",
               evidence(false, "recovered")
             )

    recovery = occurrence(ctx.target.session_key, "asg_race", "race-recovery", 2)

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               recovery,
               evidence(true, "recovered"),
               evidence(false, "recurred")
             )

    results =
      1..8
      |> Enum.map(fn n ->
        Task.async(fn ->
          RecurrenceSuppression.repeat(
            ctx.db,
            config,
            occurrence(ctx.target.session_key, "asg_race", "race-#{n}", 3),
            evidence(true, "recovered"),
            evidence(true, "recurred")
          )
        end)
      end)
      |> Task.await_many()

    assert Enum.all?(results, &match?({:rearmed, 2}, &1))

    assert {:ok, [[2, 0, nil, nil, 3]]} =
             DB.query(
               ctx.db,
               "SELECT generation,suppressedCount,recoveredSequence,recoveredOccurrenceSequence,openedOccurrenceSequence FROM recurrence_suppression_episodes WHERE subject='asg_race'"
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM recurrence_suppression_events WHERE subject='asg_race' AND outcome='recurrence_rearmed'"
             )

    assert {:ok, [[8]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM recurrence_suppression_receipts WHERE subject='asg_race' AND generation=2 AND outcome='rearmed'"
             )

    unchanged_recovery = occurrence(ctx.target.session_key, "asg_race", "race-9", 4)

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               unchanged_recovery,
               evidence(true, "recovered"),
               evidence(true, "recurred")
             )

    assert {:ok, [[2, 1, nil]]} =
             DB.query(
               ctx.db,
               "SELECT generation,suppressedCount,recoveredSequence FROM recurrence_suppression_episodes WHERE subject='asg_race'"
             )

    changed_away = occurrence(ctx.target.session_key, "asg_race", "race-10", 5)

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               changed_away,
               evidence(false, "recovered"),
               evidence(true, "recurred")
             )

    recovered = occurrence(ctx.target.session_key, "asg_race", "race-11", 6)

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               recovered,
               evidence(true, "recovered"),
               evidence(true, "recurred")
             )

    later_recurrence = occurrence(ctx.target.session_key, "asg_race", "race-12", 7)

    assert {:rearmed, 3} =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               later_recurrence,
               evidence(true, "recovered"),
               evidence(true, "recurred")
             )

    assert {:ok, [[3, 0, nil, 7]]} =
             DB.query(
               ctx.db,
               "SELECT generation,suppressedCount,recoveredSequence,openedOccurrenceSequence FROM recurrence_suppression_episodes WHERE subject='asg_race'"
             )
  end

  test "Main target and missing fingerprint stay audit-only and fail open", ctx do
    config = config(1)
    main_occurrence = occurrence(ctx.main.session_key, "asg_main", "r1", 1)

    assert :dispatch =
             RecurrenceSuppression.prepare_first(ctx.db, main_occurrence, "dispatch-main")

    assert :deliver =
             RecurrenceSuppression.record_first(
               ctx.db,
               config,
               main_occurrence,
               "dispatch-main",
               evidence(false, "recovered")
             )

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               occurrence(ctx.main.session_key, "asg_main", "r2", 2),
               evidence(false, "recovered"),
               evidence(false, "recurred")
             )

    assert :unavailable =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               Map.delete(
                 occurrence(ctx.target.session_key, "asg_missing", "r3", 3),
                 :failure_code
               ),
               evidence(false, "recovered"),
               evidence(false, "recurred")
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM recurrence_suppression_events WHERE outcome='recurrence_fallback_audit_only'"
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM recurrence_suppression_events WHERE outcome='recurrence_suppression_unavailable'"
             )

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM wakes")
  end

  test "loader requires the complete deterministic declaration and keeps legacy rules valid",
       _ctx do
    base = Path.join(System.tmp_dir!(), "recurrence-loader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "identity/rules"))
    on_exit(fn -> File.rm_rf!(base) end)

    legacy = """
    [[rule]]
    name = "legacy"
    verb = "post"
    text = "deny"
    deny_when = [{ fact = "assignment.artifact_kinds", op = "not_in", value = ["report"] }]
    """

    File.write!(Path.join([base, "identity/rules/rule.toml"]), legacy)
    assert [%{recurrence_suppression: nil}] = Rules.load!(base, ["post"])

    remedy = """
    effect = "remedy"
    [rule.remedy]
    action = "wake"
    target_session = "target"
    [rule.remedy.params]
    prompt = "inspect"
    """

    valid = legacy <> remedy <> declaration()
    File.write!(Path.join([base, "identity/rules/rule.toml"]), valid)

    assert [%{recurrence_suppression: %{escalation_threshold: 3}}] =
             Rules.load!(base, ["post", "wake"])

    malformed = [
      {String.replace(valid, "target_session_subject", "global"), "scope"},
      {String.replace(valid, "\n  \"failure_code\",", ""), "fingerprint"},
      {String.replace(valid, "\"failure_code\",", "\"failure_class\","), "fingerprint"},
      {String.replace(valid, "fingerprint = [", "unknown = true\nfingerprint = ["),
       "unknown keys"},
      {String.replace(valid, "escalation_threshold = 3", "escalation_threshold = 0"),
       "escalation_threshold"},
      {String.replace(valid, "escalation_threshold = 3", "escalation_threshold = \"3\""),
       "escalation_threshold"},
      {String.replace(valid, "operational_parent_then_main", "drop"), "fallback"},
      {Regex.replace(
         ~r/\n\[rule\.recurrence_suppression\.rearm\][\s\S]*\z/,
         valid,
         ""
       ), "rearm"},
      {String.replace(valid, "recovered_when = [", "unknown = true\nrecovered_when = ["),
       "unknown keys"},
      {String.replace(
         valid,
         ~s(recovered_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]),
         "recovered_when = []"
       ), "recovered_when"},
      {String.replace(
         valid,
         ~s(recurred_when = [{ fact = "assignment.state", op = "eq", value = "open" }]),
         "recurred_when = []"
       ), "recurred_when"},
      {String.replace(valid, "caller.origin_class", "unknown.fact", global: false),
       "unknown fact"}
    ]

    for {contents, message} <- malformed do
      File.write!(Path.join([base, "identity/rules/rule.toml"]), contents)
      assert_raise ArgumentError, ~r/#{message}/, fn -> Rules.load!(base, ["post", "wake"]) end
    end
  end

  defp config(threshold) do
    %{
      escalation_threshold: threshold,
      fallback: "operational_parent_then_main",
      rearm: %{recovered_when: [], recurred_when: []}
    }
  end

  defp occurrence(target, subject, receipt, sequence) do
    %{
      statute: "same-failure",
      target_session: target,
      subject: subject,
      failure_class: "adapter",
      failure_code: "missing-binary",
      receipt_id: receipt,
      sequence: sequence,
      cause: "rail-remedy",
      principal: "process:tightbeam",
      raw_failure_text: "SECRET must never be stored"
    }
  end

  defp evidence(matched, value), do: %{matched: matched, facts: [{"fact", value}]}

  defp declaration do
    """

    [rule.recurrence_suppression]
    scope = "target_session_subject"
    fingerprint = [
      "statute",
      "target_session",
      "subject",
      "failure_class",
      "failure_code",
    ]
    escalation_threshold = 3
    fallback = "operational_parent_then_main"

    [rule.recurrence_suppression.rearm]
    recovered_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    recurred_when = [{ fact = "assignment.state", op = "eq", value = "open" }]
    """
  end

  defp session(db, key, spawned_by, kind) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: kind,
      owner_user_id: "mike",
      origin: "user:mike",
      spawned_by: spawned_by,
      archetype: "coder",
      host: Tightbeam.Placement.local_host_name(),
      harness: "codex",
      provider: "openai",
      model: Model.new("test")
    })
  end
end
