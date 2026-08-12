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

    assert :deliver = RecurrenceSuppression.record_first(ctx.db, config, first)
    assert :deliver = RecurrenceSuppression.record_first(ctx.db, config, first)

    second = occurrence(ctx.target.session_key, "asg_one", "r2", 2)
    assert :suppressed = RecurrenceSuppression.repeat(ctx.db, config, second, false, true)
    assert :suppressed = RecurrenceSuppression.repeat(ctx.db, config, second, false, true)

    recovered = occurrence(ctx.target.session_key, "asg_one", "r3", 3)
    assert :suppressed = RecurrenceSuppression.repeat(ctx.db, config, recovered, true, false)

    same_sequence = occurrence(ctx.target.session_key, "asg_one", "r4", 3)
    assert :suppressed = RecurrenceSuppression.repeat(ctx.db, config, same_sequence, false, true)

    recurrence = occurrence(ctx.target.session_key, "asg_one", "r5", 4)

    assert {:rearmed, 2} =
             RecurrenceSuppression.repeat(ctx.db, config, recurrence, false, true)

    other_subject = occurrence(ctx.target.session_key, "asg_two", "r6", 5)
    assert :deliver = RecurrenceSuppression.record_first(ctx.db, config, other_subject)

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

  test "threshold escalates once to the parent without waking the target", ctx do
    config = config(2)
    first = occurrence(ctx.target.session_key, "asg_threshold", "r1", 1)
    assert :deliver = RecurrenceSuppression.record_first(ctx.db, config, first)

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               occurrence(ctx.target.session_key, "asg_threshold", "r2", 2),
               false,
               false
             )

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               occurrence(ctx.target.session_key, "asg_threshold", "r3", 3),
               false,
               false
             )

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               occurrence(ctx.target.session_key, "asg_threshold", "r4", 4),
               false,
               false
             )

    assert {:ok, [["parent", 1]]} =
             DB.query(ctx.db, "SELECT sessionKey,count(*) FROM wakes GROUP BY sessionKey")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE sessionKey='target'")

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM recurrence_suppression_events WHERE outcome='recurrence_escalated'"
             )
  end

  test "Main target and missing fingerprint stay audit-only and fail open", ctx do
    config = config(1)
    main_occurrence = occurrence(ctx.main.session_key, "asg_main", "r1", 1)
    assert :deliver = RecurrenceSuppression.record_first(ctx.db, config, main_occurrence)

    assert :suppressed =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               occurrence(ctx.main.session_key, "asg_main", "r2", 2),
               false,
               false
             )

    assert :unavailable =
             RecurrenceSuppression.repeat(
               ctx.db,
               config,
               Map.delete(
                 occurrence(ctx.target.session_key, "asg_missing", "r3", 3),
                 :failure_code
               ),
               false,
               false
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
      {String.replace(valid, "escalation_threshold = 3", "escalation_threshold = 0"),
       "escalation_threshold"},
      {String.replace(valid, "operational_parent_then_main", "drop"), "fallback"},
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
