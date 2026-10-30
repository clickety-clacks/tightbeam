defmodule Tightbeam.RemindersTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{Identity, Reminders}

  setup do
    root = Path.join(System.tmp_dir!(), "reminder-files-#{System.unique_integer([:positive])}")
    base = Path.join(root, "org")
    source = Path.join(root, "source")
    File.mkdir_p!(root)
    File.cp_r!(Application.app_dir(:tightbeam, "priv/kungfu/agentic-engineering"), source)
    prior = Application.get_env(:tightbeam, :identity_source_dir)
    Application.put_env(:tightbeam, :identity_source_dir, source)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:tightbeam, :identity_source_dir, prior),
        else: Application.delete_env(:tightbeam, :identity_source_dir)

      File.rm_rf!(root)
    end)

    Identity.init!(base)
    %{base: base, source: source, dir: Path.join(base, "identity")}
  end

  test "published files render immediately, unpublished changes do not, and substitution is single pass",
       ctx do
    assert {:ok, candidate} = Identity.learn!(ctx.base, "agentic-engineering", "test")
    assert {:ok, _} = Identity.publish_live!(ctx.base, candidate)

    values = %{
      assignment_id: "task-one",
      holder: "worker",
      subject: "fix {holder}",
      last_activity: "now"
    }

    before = Reminders.render(ctx.base, "holder-reminder", values)
    path = Path.join(ctx.dir, "reminders/holder-reminder.md")
    File.write!(path, "{assignment_id} / {assignment_id} / {subject} / {unknown}")
    commit(ctx.dir)
    assert Reminders.render(ctx.base, "holder-reminder", values) == before
    publish(ctx.base)

    assert Reminders.render(ctx.base, "holder-reminder", values) ==
             "task-one / task-one / fix {holder} / {unknown}"

    for {kind, values, expected} <- [
          {"climb-copy", %{holder: "worker"}, "worker"},
          {"terminal-action", %{child_session_state: "active"}, "active"},
          {"work-item-routing", %{title: "ready"}, "ready"},
          {"work-item-slate", %{work_item_id: "item"}, "item"},
          {"critical-lease-retire", %{reason: "cleanup"}, "cleanup"},
          {"identity-staleness", %{late_count: 2}, "2"},
          {"remedy-pending", %{rule: "finish"}, "finish"}
        ] do
      [{field, _}] = Map.to_list(values)
      File.write!(Path.join(ctx.dir, "reminders/#{kind}.md"), "edited {#{field}}")
      commit(ctx.dir)
      publish(ctx.base)
      assert Reminders.render(ctx.base, kind, values) == "edited " <> expected
    end
  end

  test "holder reminders read the published file through the persistent store at each creation",
       ctx do
    alias Tightbeam.{DB, Model, Org, Schema, Supervision, Wakes}

    prepared =
      Tightbeam.GuardRuntimeFixture.prepare!(ctx.base <> "-database", "schema_shape_runtime.exs")

    db =
      start_supervised!(
        {DB,
         path: Path.join(prepared.base, "state.db"),
         name: nil,
         guard_inputs: [],
         payload_root: prepared.payload}
      )

    :ok = Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('owner',1,1)")

    Org.create(db, %{
      session_key: "worker",
      display_name: "Worker",
      owner_user_id: "owner",
      origin: "user:owner",
      kind: "custom",
      is_built_in: false,
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "testhost"
    })

    Identity.init!(prepared.base)
    {:ok, candidate} = Identity.learn!(prepared.base, "agentic-engineering", "test")
    {:ok, _} = Identity.publish_live!(prepared.base, candidate)
    dir = Path.join(prepared.base, "identity")

    File.write!(
      Path.join(dir, "reminders/holder-reminder.md"),
      "Published reminder for {assignment_id}"
    )

    commit(dir)

    trigger = fn id ->
      activity = System.system_time(:millisecond) - 3_600_000

      {:ok, _} =
        DB.query(
          db,
          "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt) VALUES (?1,'quiet work','worker','owner',?2)",
          [id, activity]
        )

      {:ok, :ok} =
        DB.transaction(db, &Supervision.assignment_opened_in_txn(&1, id, activity, 1_800_000))

      {:ok, [[deadline]]} =
        DB.query(
          db,
          "SELECT wakeId FROM wakes WHERE assignmentId=?1 AND consumer='assignment_inactivity_deadline' AND state='pending'",
          [id]
        )

      assert {:ok, :ok} = Supervision.deadline(db, Wakes.get(db, deadline))

      {:ok, [[prompt]]} =
        DB.query(db, "SELECT prompt FROM wakes WHERE assignmentId=?1 AND consumer='prompt'", [id])

      prompt
    end

    assert trigger.("before-publication") =~ "Last recorded activity:"
    publish(prepared.base)
    assert trigger.("after-publication") == "Published reminder for after-publication"
  end

  test "missing, unreadable, blank and unlearned files use exactly the shipped default", ctx do
    values = %{assignment_id: "task", subject: "work", holder: "worker", last_activity: "now"}
    expected = Reminders.render(nil, "holder-reminder", values)
    assert Reminders.render(ctx.base, "holder-reminder", values) == expected
    assert Reminders.render(Path.join(ctx.base, "absent"), "holder-reminder", values) == expected
    assert {:ok, candidate} = Identity.learn!(ctx.base, "agentic-engineering", "test")
    assert {:ok, _} = Identity.publish_live!(ctx.base, candidate)
    path = Path.join(ctx.dir, "reminders/holder-reminder.md")

    for contents <- [nil, <<255, 254>>, " \n\t"] do
      if contents, do: File.write!(path, contents), else: File.rm!(path)
      commit(ctx.dir)
      publish(ctx.base)
      before = git(ctx.dir, ["rev-parse", "HEAD"])
      assert Reminders.render(ctx.base, "holder-reminder", values) == expected
      assert git(ctx.dir, ["rev-parse", "HEAD"]) == before
      assert git(ctx.dir, ["status", "--porcelain"]) == ""
    end
  end

  test "relearn merges reminder edits and uses existing conflict handling", ctx do
    original = Enum.map_join(1..20, "\n", &"line #{&1}") <> "\n"
    source_terminal = Path.join(ctx.source, "reminders/terminal-action.md")
    File.write!(source_terminal, original)
    assert {:ok, candidate} = Identity.learn!(ctx.base, "agentic-engineering", "test")
    assert {:ok, _} = Identity.publish_live!(ctx.base, candidate)
    path = Path.join(ctx.dir, "reminders/terminal-action.md")
    File.write!(path, String.replace(original, "line 1\n", "org choice\n"))
    commit(ctx.dir)
    publish(ctx.base)
    File.write!(source_terminal, String.replace(original, "line 20\n", "new default\n"))
    File.write!(Path.join(ctx.source, "reminders/holder-reminder.md"), "new holder wording")
    assert {:ok, candidate} = Identity.relearn!(ctx.base, "test")
    assert {:ok, _} = Identity.publish_live!(ctx.base, candidate)
    assert Reminders.render(ctx.base, "terminal-action", %{}) =~ "org choice"
    assert Reminders.render(ctx.base, "terminal-action", %{}) =~ "new default"
    assert Reminders.render(ctx.base, "holder-reminder", %{}) == "new holder wording"

    File.write!(
      source_terminal,
      original
      |> String.replace("line 1\n", "conflicting default\n")
      |> String.replace("line 20\n", "new default\n")
    )

    assert {:conflict, ["reminders/terminal-action.md"]} = Identity.relearn!(ctx.base, "test")
  end

  test "all assignment defaults contain the five actions and readable times" do
    for kind <- ~w(holder-reminder climb-copy terminal-action) do
      text = Reminders.default(kind)
      assert text =~ "act now"
      assert text =~ "complete the assignment"
      assert text =~ "wake on the record"
      assert text =~ "a decision is needed"
      assert text =~ "Do not file progress unless something materially changed"
      refute text =~ "record progress"
      refute text =~ "parked"
    end

    assert Reminders.activity(0, 120_000) == "1970-01-01 00:00 UTC (2 minutes ago)"
    assert Reminders.activity(nil, 1) == "none recorded"
  end

  defp publish(base) do
    revision = git(Path.join(base, "identity"), ["rev-parse", "HEAD"])

    assert {:ok, ^revision} =
             Identity.publish_live!(base, %{
               candidate_revision: revision,
               expected_prior: Identity.live_revision!(base)
             })
  end

  defp commit(dir),
    do: git(dir, ["add", "-A"]) && git(dir, ["commit", "-m", "Change reminder wording"])

  defp git(dir, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid" | args],
        cd: dir,
        stderr_to_stdout: true
      )

    String.trim(out)
  end
end
