defmodule Tightbeam.RowReactionsReminderTest do
  @moduledoc """
  The `[[reminder]]` rule form: loading behind the `subtree_rules` switch,
  load-time validation, and its compilation to an ordinary reaction whose
  notices are re-checked and dropped by the existing engine.
  """
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Roles, RowReactions, Rules}
  alias Tightbeam.RowReactions.Reminder

  # The two worked examples from the subtree-rules design, verbatim. They are
  # what an org might write, so they live here and nowhere in core.
  @code_check """
  [[reminder]]
  name = "e2e-check"
  english = \"\"\"
  When code work finishes with no end-to-end result and no reason it isn't needed,
  remind whoever did it. If still unanswered three hours later, remind whoever
  opened the work. Silent once either is on record.
  \"\"\"
  on = "assignment-completed"

  # Which work this is about. Re-checked when each reminder is due.
  when = [
    { fact = "assignment.effect_kind", op = "eq", value = "code" },
    { fact = "assignment.is_review",   op = "eq", value = false },
  ]

  # Any one of these answers it: no reminder is sent, and any not yet delivered is dropped.
  satisfied_when_any = [
    { fact = "assignment.notes",          op = "contains", value = ["e2e:", "e2e not needed:"] },
    { fact = "work_item.artifact_titles", op = "contains", value = ["e2e:", "e2e not needed:"] },
  ]

  [[reminder.notify]]
  to = "holder"
  after = "0m"
  text = \"\"\"
  You completed {assignment_id} ({work_item_title}) without an end-to-end check on
  record. Run one and record what you saw:
    tightbeam artifact-record --work-item {work_item_id} --kind report \\
      --title "e2e: <what you checked>" --path <result file>
  If it doesn't need one, record a one-line file titled "e2e not needed: <reason>".
  (Next time, a line starting "e2e:" or "e2e not needed:" in your completion note is enough.)
  \"\"\"

  [[reminder.notify]]
  to = "opener"
  after = "3h"
  text = \"\"\"
  {holder_name} completed {assignment_id} ({work_item_title}) three hours ago with no
  end-to-end result and no reason on record. Decide whether it needs an end-to-end check.
  \"\"\"
  """

  @matter_check """
  [[reminder]]
  name = "conflict-check"
  english = "Every new matter needs a conflict check on file within a day of opening."
  on = "work-item-created"
  when = [
    { fact = "work_item.state", op = "eq", value = "open" },
  ]
  satisfied_when_any = [
    { fact = "work_item.artifact_titles", op = "contains", value = ["conflict check:"] },
  ]

  [[reminder.notify]]
  to = "delivery_owner"
  after = "24h"
  text = \"\"\"
  Matter "{work_item_title}" ({work_item_id}) has been open a day with no conflict
  check on file. Run it and record the result titled "conflict check: <result>".
  \"\"\"

  [[reminder.notify]]
  to = "anchor"
  after = "48h"
  text = \"\"\"
  Matter "{work_item_title}" ({work_item_id}) is two days old with no conflict check
  on file. The lead associate was reminded yesterday.
  \"\"\"
  """

  # A reminder that uses only operators present before subtree rules.
  @plain """
  [[reminder]]
  archetypes = ["*"]
  name = "plain"
  on = "assignment-completed"
  when = [{ fact = "assignment.effect_kind", op = "eq", value = "code" }]
  satisfied_when_any = [{ fact = "work_item.state", op = "in", value = ["closed"] }]

  [[reminder.notify]]
  to = "holder"
  after = "0m"
  text = "Finished {assignment_id} on {work_item_id}."

  [[reminder.notify]]
  to = "opener"
  after = "90s"
  text = "{holder_name} finished {assignment_id}."
  """

  @hour 3_600_000

  setup do
    base = Path.join(System.tmp_dir!(), "reminder-rules-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "identity/rules"))
    previous = Application.get_env(:tightbeam, :subtree_rules)

    on_exit(fn ->
      restore_flag(previous)
      File.rm_rf!(base)
      Rules.load!(System.tmp_dir!() <> "/missing-reminder-rules-reset", [])
    end)

    %{base: base}
  end

  describe "with subtree rules switched off" do
    setup do
      Application.put_env(:tightbeam, :subtree_rules, false)
      :ok
    end

    test "a [[reminder]] table is refused exactly as any unknown root table", ctx do
      reminder = put_file(ctx, "reminder.toml", @plain)
      unknown = put_file(ctx, "unknown.toml", String.replace(@plain, "reminder", "bogus"))

      log = ExUnit.CaptureLog.capture_log(fn -> assert [] = load(ctx) end)

      assert log =~ "rule file #{reminder} unavailable: #{reminder}: unknown root keys: reminder"
      assert log =~ "rule file #{unknown} unavailable: #{unknown}: unknown root keys: bogus"
      assert Rules.reaction_plans(completed_event(), facts()) == []
    end

    test "a file mixing a reaction and a reminder is refused, not half-loaded", ctx do
      put_file(ctx, "mixed.toml", @plain <> "\n" <> plain_reaction())
      log = ExUnit.CaptureLog.capture_log(fn -> assert [] = load(ctx) end)
      assert log =~ "unknown root keys: reminder"
    end

    test "an ordinary reaction file loads and plans as before", ctx do
      put_file(ctx, "reaction.toml", plain_reaction())
      assert [%{name: "plain-reaction", mode: :event}] = load(ctx)
    end
  end

  describe "with subtree rules switched on" do
    setup do
      Application.put_env(:tightbeam, :subtree_rules, true)
      :ok
    end

    test "a reminder loads as an ordinary event reaction", ctx do
      put_file(ctx, "plain.toml", @plain)

      assert [
               %{
                 mode: :event,
                 name: "plain",
                 family: "reminder:plain",
                 events: ["assignment"],
                 archetypes: ["*"],
                 effects: [%{"slot" => "notify-1"}, %{"slot" => "notify-2"}]
               }
             ] = load(ctx)
    end

    test "on completion each notice is planned at its delay to its own recipient", _ctx do
      load_plain()
      plans = Rules.reaction_plans(completed_event(), facts())

      assert [
               %{slot: "notify-1", selected: true, value: holder},
               %{slot: "notify-2", selected: true, value: opener}
             ] = Enum.sort_by(plans, & &1.slot)

      assert holder["session_key"] == "s-holder"
      assert holder["due_at"] == 1_000
      assert holder["on_unavailable"] == "skip"
      assert holder["origin"] == "process:tightbeam"
      assert holder["owner_user_id"] == "owner"
      assert holder["prompt"] == "Finished asg_1 on wi_1."
      assert holder["wake_id"] =~ ~r/\Aw_rem_[0-9a-f]{64}\z/

      assert opener["session_key"] == "s-opener"
      assert opener["due_at"] == 1_000 + 90_000
      assert opener["prompt"] == "Holder finished asg_1."
      refute opener["wake_id"] == holder["wake_id"]
    end

    test "nothing is planned for another outcome or when `when` does not hold", _ctx do
      load_plain()

      surrendered = put_in(completed_event(), ["terminal", "outcome"], "surrendered")
      refute Enum.any?(Rules.reaction_plans(surrendered, facts()), & &1.selected)

      docs = put_in(facts(), ["assignment", "effect_kind"], "docs")
      refute Enum.any?(Rules.reaction_plans(completed_event(), docs), & &1.selected)
    end

    test "an answer on record selects nothing, which the engine withdraws at re-check", _ctx do
      load_plain()
      answered = put_in(facts(), ["work_item", "state"], "closed")
      plans = Rules.reaction_plans(completed_event(), answered)
      assert length(plans) == 2
      refute Enum.any?(plans, & &1.selected)
    end

    test "list membership matches an overlapping item and ignores missing facts", ctx do
      for {operation, matching, nonmatching} <- [
            {"in", ["other", "accepted"], ["other"]},
            {"not_in", ["other"], ["other", "accepted"]}
          ] do
        rule =
          String.replace(
            @plain,
            ~s(fact = "assignment.effect_kind", op = "eq", value = "code"),
            ~s(fact = "assignment.verdicts", op = "#{operation}", value = ["accepted"])
          )

        put_file(ctx, "membership.toml", rule)
        assert [%{name: "plain"}] = load(ctx)

        for {snapshot, expected} <- [
              {put_in(facts(), ["assignment", "verdicts"], matching), true},
              {put_in(facts(), ["assignment", "verdicts"], nonmatching), false},
              {facts(), false}
            ] do
          assert Enum.map(Rules.reaction_plans(completed_event(), snapshot), & &1.selected) ==
                   [expected, expected]
        end
      end
    end

    test "a missing placeholder value is shown as unknown rather than failing", _ctx do
      load_plain()
      facts = put_in(facts(), ["names", "holder"], nil)

      assert %{value: %{"prompt" => "(unknown) finished asg_1."}} =
               Rules.reaction_plans(completed_event(), facts)
               |> Enum.find(&(&1.slot == "notify-2"))
    end

    test "the readable form compiles to the reaction the engine already runs" do
      reaction = Reminder.to_reaction!(Toml.decode!(@plain)["reminder"] |> hd())

      assert reaction["events"] == ["assignment"]
      assert reaction["archetypes"] == ["*"]

      assert %{"op" => "and", "args" => [guard, condition, unanswered]} = reaction["when"]

      assert guard == %{
               "op" => "eq",
               "args" => [%{"ref" => "event.terminal.outcome"}, "completed"]
             }

      assert condition == %{
               "op" => "eq",
               "args" => [%{"ref" => "facts.assignment.effect_kind"}, "code"]
             }

      assert %{"op" => "not", "args" => [%{"op" => "or", "args" => [_]}]} = unanswered
      refute Map.has_key?(reaction, "scope")
      refute Map.has_key?(reaction, "roles")
    end

    test "scope, roles and archetypes pass through unchanged" do
      reminder =
        Toml.decode!(@plain)["reminder"]
        |> hd()
        |> Map.put("scope", %{"subtree_of" => "role:team:alpha"})
        |> Map.put("roles", ["review:*"])

      reaction = Reminder.to_reaction!(reminder)
      assert reaction["scope"] == %{"subtree_of" => "role:team:alpha"}
      assert reaction["roles"] == ["review:*"]
      assert reaction["archetypes"] == ["*"]
    end

    test "a work-item event reminder reads the item's own ids" do
      reaction = Reminder.to_reaction!(hd(Toml.decode!(@matter_check)["reminder"]))
      assert reaction["events"] == ["work_item_observation"]

      assert %{"op" => "and", "args" => [guard | _]} = reaction["when"]
      assert guard == %{"op" => "eq", "args" => [%{"ref" => "event.operation"}, "created"]}

      [delivery_owner, anchor] = reaction["effects"]
      assert %{"op" => "concat", "args" => prompt_parts} = delivery_owner["value"]["prompt"]

      assert %{"op" => "coalesce", "args" => [%{"ref" => "event.workItemId"}, "(unknown)"]} in prompt_parts

      assert anchor["value"]["session_key"] == %{"ref" => "anchor.session_key"}

      assert anchor["value"]["due_at"] == %{
               "op" => "add",
               "args" => [%{"ref" => "event.at"}, 48 * @hour]
             }
    end

    test "the design's examples translate as written" do
      for toml <- [@code_check, @matter_check] do
        assert [reminder] = Toml.decode!(toml)["reminder"]
        assert %{"effects" => [_, _]} = Reminder.to_reaction!(reminder)
      end
    end

    test "the assignment example uses completion notes and late artifacts as answers", ctx do
      put_file(ctx, "code.toml", @code_check)
      assert [%{name: "e2e-check"}] = load(ctx)

      event = completed_event()
      snapshot = facts()

      assert [
               %{value: %{"session_key" => "s-holder", "due_at" => 1_000}},
               %{value: %{"session_key" => "s-opener", "due_at" => later, "prompt" => prompt}}
             ] = selected(event, snapshot)

      assert later == 1_000 + 3 * @hour
      assert prompt =~ "Holder completed asg_1 (Widget)"

      for answered <- [
            put_in(snapshot, ["assignment", "notes"], ["E2E: ran the full flow, passed"]),
            put_in(snapshot, ["work_item", "artifact_titles"], ["e2e not needed: copy change"]),
            put_in(snapshot, ["assignment", "is_review"], true)
          ] do
        assert [] = selected(event, answered)
      end
    end

    test "an unscoped anchor notice addresses Main and renders its display name", ctx do
      put_file(
        ctx,
        "matter.toml",
        String.replace(@matter_check, "Matter", "{anchor_name}: Matter")
      )

      assert [%{name: "conflict-check"}] = load(ctx)

      event = %{
        "id" => "work-item:wi_1:created",
        "org" => "owner",
        "kind" => "work_item_observation",
        "workItemId" => "wi_1",
        "operation" => "created",
        "at" => 1_000
      }

      snapshot =
        facts()
        |> Map.update!("sessions", &[%{"sessionKey" => "s-main", "archetype" => "lead"} | &1])
        |> Map.put(Tightbeam.RowReactions.Plan.subtree_facts_key(), %{
          "anchors" => %{nil => %{"session_key" => "s-main", "name" => "Main"}}
        })

      assert %{value: %{"session_key" => "s-main", "prompt" => prompt}} =
               Enum.find(selected(event, snapshot), &(&1.slot == "notify-2"))

      assert prompt =~ ~s|Main: Matter "Widget" (wi_1)|
    end

    for cause <- [:answer, :retirement] do
      test "the completion example cancels the opener notice after #{cause}", ctx do
        db = reminder_db()
        put_file(ctx, "code.toml", @code_check)
        assert [%{name: "e2e-check"}] = load(ctx)
        at = System.system_time(:millisecond)

        assert {:ok, _} =
                 DB.query(
                   db,
                   """
                   INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdAt)
                   VALUES ('wi-code','Code','owner','open','owner',?1)
                   """,
                   [at]
                 )

        assert {:ok, _} =
                 DB.query(
                   db,
                   """
                   INSERT INTO assignments
                     (id,subject,holderKey,openedBySession,openedAt,state,workItemId)
                   VALUES ('asg-code','Code','member','lead',?1,'open','wi-code')
                   """,
                   [at]
                 )

        assert {:ok, _} =
                 DB.query(
                   db,
                   """
                   INSERT INTO attests (id,assignmentId,kind,note,bySession,ts)
                   VALUES ('completion-fixture','asg-code','completion','Finished','member',?1)
                   """,
                   [at]
                 )

        assert {:ok, _} =
                 DB.query(
                   db,
                   """
                   UPDATE assignments SET state='closed',outcome='completed',closedAt=?1,
                     closedBySession='member',closingAttestId='completion-fixture'
                   WHERE id='asg-code'
                   """,
                   [at]
                 )

        terminal = %{
          source_kind: "attest",
          source_token: "completion-fixture",
          owner_user_id: "owner",
          terminal_at: at,
          assignment_id: "asg-code",
          work_item_id: "wi-code",
          child_session_key: "member",
          opened_by_id: "lead",
          outcome: "completed"
        }

        assert {:ok, {:ok, _}} =
                 DB.transaction(db, fn txn ->
                   RowReactions.terminal_in_txn(txn, terminal, %{"state" => "open"})
                 end)

        assert {:ok, [[first, "member", ^at], [second, "lead", later]]} =
                 DB.query(
                   db,
                   """
                   SELECT w.wakeId,w.sessionKey,w.dueAt FROM row_reaction_actions a
                   JOIN wakes w ON w.wakeId=json_extract(a.result,'$.wake_id')
                   WHERE a.family='reminder:e2e-check' ORDER BY w.dueAt
                   """
                 )

        assert later == at + 3 * @hour
        assert {:ok, :ready} = DB.transaction(db, &RowReactions.prepare_in_txn(&1, first))

        case unquote(cause) do
          :retirement ->
            assert {:ok, _} =
                     DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey='lead'")

          :answer ->
            assert {:ok, _} =
                     DB.query(
                       db,
                       """
                       INSERT INTO artifacts
                         (artifactId,kind,title,createdBySession,workItemId,originPath,state,createdAt,updatedAt)
                       VALUES ('art-e2e','report','E2E: full flow passed','member','wi-code',
                               '/scratch/answer.md','in-workspace',?1,?1)
                       """,
                       [at + @hour]
                     )
        end

        assert {:ok, :held} = DB.transaction(db, &RowReactions.prepare_in_txn(&1, second))

        assert {:ok, [["lead", "canceled"]]} =
                 DB.query(db, "SELECT sessionKey,state FROM wakes WHERE wakeId=?1", [second])
      end
    end

    test "the work-item example schedules both notices and withdraws the second after an answer",
         ctx do
      db = reminder_db()

      assert %{name: "partner:litigation"} =
               Roles.create!(db, "partner:litigation", "owner", "lead")

      scoped_fixture =
        String.replace(
          @matter_check,
          ~s(name = "conflict-check"),
          ~s(name = "conflict-check"
scope = { subtree_of = "role:partner:litigation" })
        )

      put_file(ctx, "matter.toml", scoped_fixture)
      assert [%{name: "conflict-check"}] = load(ctx)

      at = System.system_time(:millisecond)

      for {id, owner} <- [{"wi-member", "member"}, {"wi-outsider", "outsider"}] do
        assert {:ok, _} =
                 DB.query(
                   db,
                   """
                   INSERT INTO work_items
                     (id,title,ownerUserId,state,createdByUser,createdAt,deliveryOwnerSessionKey)
                   VALUES (?1,'Matter','owner','open','owner',?2,?3)
                   """,
                   [id, at, owner]
                 )

        assert {:ok, _} =
                 DB.transaction(db, fn txn ->
                   RowReactions.observe_work_item_in_txn(
                     txn,
                     id,
                     "created",
                     %{kind: "fixture", id: id, at: at, principal: {:user, "owner"}},
                     %{}
                   )
                 end)
      end

      assert {:ok,
              [[first, "member", "wi-member", first_at], [second, "lead", "wi-member", second_at]]} =
               DB.query(
                 db,
                 """
                 SELECT w.wakeId,w.sessionKey,json_extract(e.event,'$.workItemId'),w.dueAt
                 FROM row_reaction_actions a
                 JOIN wakes w ON w.wakeId=json_extract(a.result,'$.wake_id')
                 JOIN row_reaction_events e ON e.org=a.org AND e.eventId=a.eventId
                 WHERE a.family='reminder:conflict-check'
                 ORDER BY w.dueAt
                 """
               )

      assert first_at == at + 24 * @hour
      assert second_at == at + 48 * @hour
      assert {:ok, :ready} = DB.transaction(db, &RowReactions.prepare_in_txn(&1, first))

      assert {:ok, _} =
               DB.query(
                 db,
                 """
                 INSERT INTO artifacts
                   (artifactId,kind,title,createdBySession,workItemId,originPath,state,createdAt,updatedAt)
                 VALUES ('art-answer','report','Conflict Check: clear','member','wi-member',
                         '/scratch/answer.md','in-workspace',?1,?1)
                 """,
                 [at + 25 * @hour]
               )

      assert {:ok, :held} = DB.transaction(db, &RowReactions.prepare_in_txn(&1, second))

      assert {:ok, [["canceled"]]} =
               DB.query(db, "SELECT state FROM wakes WHERE wakeId=?1", [second])
    end

    test "durations" do
      assert Reminder.duration_ms("0m") == {:ok, 0}
      assert Reminder.duration_ms("90s") == {:ok, 90_000}
      assert Reminder.duration_ms("3h") == {:ok, 3 * @hour}
      assert Reminder.duration_ms("2d") == {:ok, 48 * @hour}

      for bad <- ["", "3", "h", "1.5h", "-1h", "3 h", "3H", 3] do
        assert Reminder.duration_ms(bad) == :error
      end
    end

    test "validation errors are clear and name the file and reminder", ctx do
      cases = [
        {String.replace(@plain, ~s(name = "plain"\n), ""), "reminder requires a nonempty name"},
        {String.replace(@plain, ~s(on = "assignment-completed"), ~s(on = "assignment-finished")),
         ~s(reminder "plain": unknown on "assignment-finished"; known events: )},
        {String.replace(@plain, "assignment.effect_kind", "assignment.kind"),
         ~s(when #1 has unknown fact "assignment.kind" for this event; known facts: )},
        {String.replace(@plain, ~s(op = "eq"), ~s(op = "matches")),
         ~s(when #1 has unknown op "matches"; known ops: )},
        {String.replace(
           @plain,
           ~s(op = "in", value = ["closed"]),
           ~s(op = "in", value = "closed")
         ), "satisfied_when_any #1 op in needs a list value"},
        {String.replace(@plain, ~s(value = "code"), ~s(value = "code", extra = 1)),
         "when #1: unknown keys extra"},
        {String.replace(@plain, ~s(to = "opener"), ~s(to = "partner")),
         ~s(notify #2 has unknown to "partner" for this event; known recipients: holder, opener, delivery_owner, anchor)},
        {String.replace(@plain, ~s(after = "90s"), ~s(after = "soon")),
         ~s(notify #2 after "soon" is not a duration)},
        {String.replace(@plain, "{holder_name}", "{holdr_name}"),
         "notify #2 text uses unknown placeholder {holdr_name} for this event"},
        {String.replace(@plain, ~s(text = "Finished {assignment_id} on {work_item_id}."), ""),
         "notify #1: missing text"},
        {String.replace(@plain, "\non = ", "\ncolour = \"red\"\non = "),
         ~s(reminder "plain": unknown keys colour)},
        {@plain |> String.split("[[reminder.notify]]") |> hd(),
         ~s(reminder "plain": missing notify)},
        {"reminder = 1\n", "reminder must be a nonempty array of tables"}
      ]

      for {contents, reason} <- cases do
        path = put_file(ctx, "invalid.toml", contents)
        log = ExUnit.CaptureLog.capture_log(fn -> assert [] = load(ctx) end)
        assert log =~ "#{path}: ", "#{reason}: #{log}"
        assert log =~ reason, "expected #{inspect(reason)} in #{log}"
      end
    end

    test "events without an assignment refuse assignment facts, people and placeholders", ctx do
      base =
        String.replace(
          @matter_check,
          "op = \"contains\", value = [\"conflict check:\"]",
          "op = \"eq\", value = \"x\""
        )

      cases = [
        {String.replace(base, "work_item.state", "assignment.effect_kind"),
         ~s(unknown fact "assignment.effect_kind" for this event)},
        {String.replace(base, ~s(to = "anchor"), ~s(to = "holder")),
         ~s(unknown to "holder" for this event; known recipients: delivery_owner, anchor)},
        {String.replace(base, "({work_item_id}) is two", "({assignment_id}) is two"),
         "unknown placeholder {assignment_id} for this event"}
      ]

      for {contents, reason} <- cases do
        put_file(ctx, "invalid.toml", contents)
        log = ExUnit.CaptureLog.capture_log(fn -> assert [] = load(ctx) end)
        assert log =~ reason, "expected #{inspect(reason)} in #{log}"
      end
    end

    test "one invalid reminder does not disturb a valid sibling file", ctx do
      put_file(ctx, "valid.toml", @plain)

      put_file(
        ctx,
        "broken.toml",
        String.replace(@plain, ~s(name = "plain"), ~s(name = "broken"))
        |> String.replace("90s", "later")
      )

      ExUnit.CaptureLog.capture_log(fn ->
        assert [%{name: "plain"}] = load(ctx)
      end)
    end
  end

  defp load_plain do
    base = Path.join(System.tmp_dir!(), "reminder-plain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "identity/rules"))
    File.write!(Path.join(base, "identity/rules/plain.toml"), @plain)
    Rules.load!(base, [])
    File.rm_rf!(base)
    [_] = Map.get(Rules.effective_snapshot(), :reactions, [])
  end

  # Rule loading returns statutes; reactions are read from the live snapshot.
  defp load(ctx) do
    Rules.load!(ctx.base, [])
    Map.get(Rules.effective_snapshot(), :reactions, [])
  end

  defp put_file(ctx, name, contents) do
    path = Path.join([ctx.base, "identity/rules", name])
    File.write!(path, contents)
    path
  end

  defp plain_reaction do
    """
    [[reaction]]
    archetypes = ["*"]
    name = "plain-reaction"
    family = "plain-reaction"
    events = ["assignment"]
    when = true

    [[reaction.effects]]
    slot = "notice"
    kind = "notice"
    when = true
    value = { wake_id = "w_plain", session_key = "s-holder", owner_user_id = "owner", origin = "process:tightbeam", prompt = "done", due_at = { ref = "event.at" }, on_unavailable = "skip" }
    """
  end

  defp completed_event do
    %{
      "id" => "assignment:attest:tok-1",
      "org" => "owner",
      "kind" => "assignment",
      "at" => 1_000,
      "principal" => %{"kind" => "session", "id" => "s-holder"},
      "terminal" => %{
        "assignment_id" => "asg_1",
        "work_item_id" => "wi_1",
        "outcome" => "completed",
        "child_session_key" => "s-holder"
      }
    }
  end

  # The snapshot an assignment event reads, at the spec's fact names.
  defp facts do
    %{
      "assignment" => %{"effect_kind" => "code", "is_review" => false, "notes" => ["done"]},
      "work_item" => %{"title" => "Widget", "state" => "open", "artifact_titles" => []},
      "people" => %{
        "holder" => %{"session_key" => "s-holder"},
        "opener" => %{"session_key" => "s-opener"}
      },
      "sessions" => [
        %{"sessionKey" => "s-holder", "archetype" => "worker", "state" => "active"},
        %{"sessionKey" => "s-opener", "archetype" => "lead", "state" => "active"}
      ],
      "names" => %{"holder" => "Holder", "opener" => "Opener"},
      "scope_participant_archetypes" => ["worker"],
      "scope_record_session_groups" => [["s-opener", "s-holder"]]
    }
  end

  defp reminder_db do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)

    for {key, parent} <- [{"lead", nil}, {"member", "lead"}, {"outsider", nil}] do
      assert {:ok, _} =
               DB.query(
                 db,
                 """
                 INSERT INTO sessions
                   (sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,
                    createdAt,updatedAt,spawnedBy)
                 VALUES (?1,?1,'owner','user:owner','default','claude','anthropic','fixture',1,1,?2)
                 """,
                 [key, parent]
               )
    end

    db
  end

  defp selected(event, snapshot) do
    event
    |> Rules.reaction_plans(snapshot)
    |> Enum.filter(& &1.selected)
    |> Enum.sort_by(& &1.slot)
  end

  defp restore_flag(nil), do: Application.delete_env(:tightbeam, :subtree_rules)
  defp restore_flag(value), do: Application.put_env(:tightbeam, :subtree_rules, value)
end
