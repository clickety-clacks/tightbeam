defmodule Tightbeam.SubtreeRulesFactsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Rules, RowReactions, SubtreeRules}
  alias Tightbeam.RowReactions.{Expression, Snapshot}

  @owner "sample-owner"
  @hour 3_600_000

  setup do
    previous = Application.fetch_env(:tightbeam, :subtree_rules)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tightbeam, :subtree_rules, value)
        :error -> Application.delete_env(:tightbeam, :subtree_rules)
      end
    end)

    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)
    base = Path.join(System.tmp_dir!(), "subtree-facts-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    seed!(db)
    %{db: db, base: base}
  end

  describe "contains" do
    test "matches text case-insensitively over scalars and lists on either side" do
      assert SubtreeRules.contains?("E2E: ran the flow", "e2e:")
      assert SubtreeRules.contains?("ran it", ["missing", "RAN"])
      assert SubtreeRules.contains?(["first", "e2e not needed: docs only"], ["E2E NOT NEEDED:"])
      assert SubtreeRules.contains?(["a", "b"], "B")
      refute SubtreeRules.contains?(["first", "second"], ["third"])
      refute SubtreeRules.contains?([], ["x"])
      refute SubtreeRules.contains?("text", [])
    end

    test "treats pattern characters as plain text and never matches non-text or empty needles" do
      assert SubtreeRules.contains?("cost: $5.00 (est.)", "$5.00 (est.)")
      refute SubtreeRules.contains?("abc", ".*")
      refute SubtreeRules.contains?("abc", "")
      refute SubtreeRules.contains?(nil, "a")
      refute SubtreeRules.contains?([nil, 1, true], "1")
      refute SubtreeRules.contains?("1", 1)
    end

    test "reaction expressions accept contains only with the switch on" do
      expression = %{"op" => "contains", "args" => [%{"ref" => "facts.notes"}, ["E2E:"]]}

      Application.put_env(:tightbeam, :subtree_rules, false)

      assert_raise ArgumentError, ~r/unsupported reaction operation/, fn ->
        Expression.validate!(expression)
      end

      Application.put_env(:tightbeam, :subtree_rules, true)
      assert Expression.validate!(expression) == :ok
      assert Expression.evaluate(expression, %{"facts" => %{"notes" => ["e2e: passed"]}})
      refute Expression.evaluate(expression, %{"facts" => %{"notes" => ["no check"]}})
      refute Expression.evaluate(expression, %{"facts" => %{}})

      assert_raise ArgumentError, fn ->
        Expression.validate!(%{"op" => "contains", "args" => ["only one"]})
      end
    end

    test "statutes accept contains on text facts only with the switch on", ctx do
      write_rules!(ctx.base, "statute.toml", """
      [[rule]]
      name = "origin-marker"
      archetypes = ["*"]
      verb = "work-item-close"
      text = "denied by origin-marker"
      deny_when = [{ fact = "caller.origin_class", op = "contains", value = ["nothing", "USE"] }]
      """)

      Application.put_env(:tightbeam, :subtree_rules, false)
      Rules.load!(ctx.base, ~w(work-item-close))
      assert Enum.any?(Rules.status().unavailable_verbs, &(&1.reason =~ "unknown op"))

      Application.put_env(:tightbeam, :subtree_rules, true)
      Rules.load!(ctx.base, ~w(work-item-close))
      assert Rules.status().unavailable_verbs == []

      assert {:deny, %{message: message}} = Rules.evaluate(ctx.db, close_call("user:#{@owner}"))
      assert message =~ "origin-marker"
      assert :ok = Rules.evaluate(ctx.db, close_call("process:tightbeam"))
    end

    test "statute contains rejects non-text facts and empty values", ctx do
      Application.put_env(:tightbeam, :subtree_rules, true)

      for condition <- [
            ~s({ fact = "work_item.is_bug", op = "contains", value = "x" }),
            ~s({ fact = "caller.origin_class", op = "contains", value = "" }),
            ~s({ fact = "caller.origin_class", op = "contains", value = [] })
          ] do
        write_rules!(ctx.base, "statute.toml", """
        [[rule]]
        name = "bad-contains"
        archetypes = ["*"]
        verb = "work-item-close"
        text = "denied"
        deny_when = [#{condition}]
        """)

        Rules.load!(ctx.base, ~w(work-item-close))
        assert [%{verb: "work-item-close"} | _] = Rules.status().unavailable_verbs
      end
    end
  end

  describe "facts" do
    test "with the switch off the reaction facts are exactly as before", ctx do
      Application.put_env(:tightbeam, :subtree_rules, false)

      for event <- events() do
        {:ok, {base, extended}} =
          DB.transaction(ctx.db, fn txn ->
            base = Snapshot.current(txn, event, %{})
            {base, Snapshot.subtree_facts(txn, event, base)}
          end)

        assert extended == base
      end
    end

    test "assignment and work-item events expose the work's facts and people", ctx do
      Application.put_env(:tightbeam, :subtree_rules, true)

      for event <- Enum.reject(events(), &(&1["kind"] == "work_item_observation")) do
        facts = facts!(ctx.db, event)

        assert %{
                 "id" => "asg-code",
                 "effect_kind" => "code",
                 "is_review" => false,
                 "notes" => ["started the work", "done; e2e: ran the full flow"],
                 "verdicts" => []
               } = facts["assignment"]

        assert %{
                 "title" => "Sample work",
                 "state" => "open",
                 "artifact_titles" => ["design notes"],
                 "artifact_kinds" => ["doc"]
               } = facts["work_item"]

        assert facts["people"] == %{
                 "holder" => %{"session_key" => "sample-holder", "name" => "Holder Name"},
                 "opener" => %{"session_key" => "sample-opener", "name" => "Opener Name"},
                 "delivery_owner" => %{
                   "session_key" => "sample-delivery",
                   "name" => "Delivery Name"
                 }
               }

        assert facts["names"] == %{
                 "holder" => "Holder Name",
                 "opener" => "Opener Name",
                 "delivery_owner" => "Delivery Name",
                 "anchor" => nil
               }
      end

      observation = facts!(ctx.db, work_item_event())
      refute Map.has_key?(observation, "assignment")
      assert observation["work_item"]["artifact_titles"] == ["design notes"]
      assert observation["names"]["delivery_owner"] == "Delivery Name"
      assert observation["names"]["holder"] == nil

      assert observation["people"] == %{
               "delivery_owner" => %{
                 "session_key" => "sample-delivery",
                 "name" => "Delivery Name"
               },
               "holder" => nil,
               "opener" => nil
             }
    end

    test "review work reports its kind and verdicts", ctx do
      Application.put_env(:tightbeam, :subtree_rules, true)

      facts = facts!(ctx.db, attest_event("asg-review"))
      assert facts["assignment"]["effect_kind"] == "review"
      assert facts["assignment"]["is_review"] == true
      assert facts["assignment"]["verdicts"] == ["changes-requested", "reviewed-clean"]
    end

    test "long histories are bounded to the most recent entries", ctx do
      Application.put_env(:tightbeam, :subtree_rules, true)

      for n <- 1..40 do
        insert_attest!(ctx.db, "att-bulk-#{n}", "asg-code", "progress", "note #{n}", 100 + n)
      end

      for n <- 1..70 do
        insert_artifact!(ctx.db, "art-bulk-#{n}", "report", "file #{n}", 100 + n)
      end

      facts = facts!(ctx.db, attest_event("asg-code"))
      notes = facts["assignment"]["notes"]
      assert length(notes) == 32
      assert List.last(notes) == "note 40"
      assert hd(notes) == "note 9"

      titles = facts["work_item"]["artifact_titles"]
      assert length(titles) == 64
      assert List.last(titles) == "file 70"
    end
  end

  describe "re-check before delivery" do
    test "a later answer withdraws a delayed notice; with the switch off nothing loads", ctx do
      write_rules!(ctx.base, "reminder.toml", """
      [[reaction]]
      name = "marker-reminder"
      archetypes = ["*"]
      family = "marker-reminder"
      events = ["assignment_attest"]
      when = { op = "and", args = [
        { op = "eq", args = [{ ref = "facts.assignment.effect_kind" }, "code"] },
        { op = "not", args = [{ op = "contains", args = [{ ref = "facts.work_item.artifact_titles" }, ["check:", "check not needed:"]] }] },
        { op = "not", args = [{ op = "contains", args = [{ ref = "facts.assignment.notes" }, ["check:", "check not needed:"]] }] }
      ] }

      [[reaction.effects]]
      slot = "opener"
      kind = "notice"
      when = true
      value = { wake_id = { op = "concat", args = ["w_marker_", { op = "sha256", args = [{ ref = "event.id" }] }] }, session_key = { ref = "facts.people.opener.session_key" }, owner_user_id = "#{@owner}", origin = "process:tightbeam", creator_session_key = { ref = "facts.assignment.holderKey" }, assignment_id = { ref = "facts.assignment.id" }, work_item_id = { ref = "facts.assignment.workItemId" }, prompt = { op = "concat", args = [{ ref = "facts.people.holder.name" }, " finished without a check on record."] }, due_at = { op = "add", args = [{ ref = "event.at" }, #{3 * @hour}] }, on_unavailable = "schedule" }
      """)

      Application.put_env(:tightbeam, :subtree_rules, false)
      Rules.load!(ctx.base, [])
      assert Rules.reaction_plans(attest_event("asg-code"), %{}) == []

      Application.put_env(:tightbeam, :subtree_rules, true)
      Rules.load!(ctx.base, [])
      event = attest_event("asg-code", "att-done-no-marker")

      # No note or file carries the marker yet, so the reminder is scheduled.
      {:ok, [action]} = DB.transaction(ctx.db, fn txn -> RowReactions.admit(txn, event) end)
      assert action["status"] == "pending"
      wake_id = action["result"]["wake_id"]

      assert {:ok, [["pending", prompt]]} =
               DB.query(ctx.db, "SELECT state,prompt FROM wakes WHERE wakeId=?1", [wake_id])

      assert prompt =~ "Holder Name finished without a check on record."

      # The answer arrives later, as a file on the work item.
      insert_artifact!(ctx.db, "art-answer", "report", "Check: ran the full flow", 500)

      {:ok, :ok} = DB.transaction(ctx.db, fn txn -> RowReactions.reconcile(txn, event) end)

      assert {:ok, [["canceled"]]} =
               DB.query(ctx.db, "SELECT status FROM row_reaction_actions WHERE id=?1", [
                 action["id"]
               ])

      assert {:ok, [["canceled"]]} =
               DB.query(ctx.db, "SELECT state FROM wakes WHERE wakeId=?1", [wake_id])
    end
  end

  defp facts!(db, event) do
    {:ok, facts} =
      DB.transaction(db, fn txn ->
        Snapshot.subtree_facts(txn, event, Snapshot.current(txn, event, %{}))
      end)

    facts
  end

  defp events do
    [
      attest_event("asg-code"),
      start_event("asg-code"),
      terminal_event("asg-code"),
      work_item_event()
    ]
  end

  defp attest_event(assignment_id, attest_id \\ nil) do
    attest_id = attest_id || "att-#{assignment_id}-event"

    %{
      "id" => "attest:" <> attest_id,
      "org" => @owner,
      "kind" => "assignment_attest",
      "at" => 1_000,
      "generation" => attest_id,
      "principal" => %{"kind" => "session", "id" => "sample-holder"},
      "source" => %{"kind" => "attest", "id" => attest_id},
      "before" => %{"attest" => nil, "assignment" => %{"id" => assignment_id}},
      "after" => %{
        "attest" => %{"id" => attest_id, "assignmentId" => assignment_id},
        "assignment" => %{"id" => assignment_id},
        "inserted" => true,
        "lateRequestId" => nil
      }
    }
  end

  defp start_event(assignment_id) do
    %{
      "id" => "start:#{assignment_id}",
      "org" => @owner,
      "kind" => "assignment_start",
      "at" => 1_000,
      "principal" => %{"kind" => "session", "id" => "sample-holder"},
      "after" => %{"assignment" => %{"id" => assignment_id}}
    }
  end

  defp terminal_event(assignment_id) do
    %{
      "id" => "assignment:attest:#{assignment_id}",
      "org" => @owner,
      "kind" => "assignment",
      "at" => 1_000,
      "principal" => %{"kind" => "session", "id" => "sample-holder"},
      "terminal" => %{
        "owner_user_id" => @owner,
        "opened_by_id" => "sample-opener",
        "child_session_key" => "sample-holder",
        "assignment_id" => assignment_id,
        "work_item_id" => "wi-sample"
      }
    }
  end

  defp work_item_event do
    %{
      "id" => "work-item:wi-sample:created",
      "org" => @owner,
      "kind" => "work_item_observation",
      "workItemId" => "wi-sample",
      "at" => 1_000,
      "principal" => %{"kind" => "session", "id" => "sample-delivery"}
    }
  end

  defp close_call(origin) do
    principal =
      case origin do
        "user:" <> user -> {:user, user}
        "process:" <> process -> {:process, process}
      end

    %{
      verb: "work-item-close",
      origin: origin,
      principal: principal,
      params: %{work_item_id: "wi-sample"}
    }
  end

  defp write_rules!(base, name, contents) do
    path = Path.join([base, "identity", "rules", name])
    File.mkdir_p!(Path.dirname(path))
    File.rm_rf!(Path.join([base, "identity", "rules"]))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp seed!(db) do
    for {key, name} <- [
          {"sample-holder", "Holder Name"},
          {"sample-opener", "Opener Name"},
          {"sample-delivery", "Delivery Name"},
          {"sample-reviewer", "Reviewer Name"}
        ] do
      {:ok, _} =
        DB.query(
          db,
          "INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt) VALUES(?1,?2,?3,?4,'sample-agent','claude','anthropic','fixture-model',1,1)",
          [key, name, @owner, "user:#{@owner}"]
        )
    end

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_items(id,title,ownerUserId,state,createdBySession,createdAt,deliveryOwnerSessionKey) VALUES('wi-sample','Sample work',?1,'open','sample-delivery',1,'sample-delivery')",
        [@owner]
      )

    for {id, holder, reviews} <- [
          {"asg-code", "sample-holder", nil},
          {"asg-review", "sample-reviewer", "asg-code"}
        ] do
      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO assignments
            (id, subject, holderKey, openedBySession, currentOpenerSessionKey, openedAt, state,
             workItemId, reviewsAssignmentId)
          VALUES (?1, ?1, ?2, 'sample-opener', 'sample-opener', 1, 'open', 'wi-sample', ?3)
          """,
          [id, holder, reviews]
        )
    end

    insert_attest!(db, "att-start", "asg-code", "progress", "started the work", 10)
    insert_attest!(db, "att-quiet", "asg-code", "progress", nil, 11)

    insert_attest!(
      db,
      "att-done-no-marker",
      "asg-code",
      "completion",
      "done; e2e: ran the full flow",
      12
    )

    insert_verdict!(db, "att-v1", "asg-review", "changes-requested", 13)
    insert_verdict!(db, "att-v2", "asg-review", "reviewed-clean", 14)
    insert_artifact!(db, "art-notes", "doc", "design notes", 5)
  end

  defp insert_attest!(db, id, assignment_id, kind, note, ts) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO attests (id, assignmentId, kind, note, bySession, ts) VALUES (?1, ?2, ?3, ?4, 'sample-holder', ?5)",
        [id, assignment_id, kind, note, ts]
      )
  end

  defp insert_verdict!(db, id, assignment_id, verdict, ts) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, bySession, ts) VALUES (?1, ?2, 'verdict', ?3, 'sample-reviewer', ?4)",
        [id, assignment_id, verdict, ts]
      )
  end

  defp insert_artifact!(db, id, kind, title, at) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO artifacts
          (artifactId, kind, title, createdBySession, workItemId, originPath, state, createdAt, updatedAt)
        VALUES (?1, ?2, ?3, 'sample-holder', 'wi-sample', ?4, 'in-workspace', ?5, ?5)
        """,
        [id, kind, title, "/scratch/#{id}.md", at]
      )
  end
end
