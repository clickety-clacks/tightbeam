defmodule Tightbeam.JobTraceTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    DB,
    Org,
    WorkItems
  }

  setup do
    db = :"job_trace_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('owner',0,1),('admin',1,1),('other',0,1)"
      )

    session(db, "holder", "owner")
    session(db, "reviewer", "other")
    session(db, "owner-session", "owner")
    session(db, "admin-session", "admin")
    session(db, "other-session", "other")

    :ok =
      DB.execute(db, """
      INSERT INTO work_items
        (id, title, ownerUserId, state, createdByUser, createdAt)
      VALUES ('wi_trace', 'Trace me', 'owner', 'open', 'owner', 1);

      INSERT INTO assignments
        (id, subject, holderKey, openedByUser, openedAt, state, workItemId)
      VALUES
        ('asg_direct', 'direct', 'holder', 'owner', 2, 'open', 'wi_trace'),
        ('asg_bad', 'invalid ref', 'holder', 'owner', 3, 'open', 'wi_trace');

      INSERT INTO assignments
        (id, subject, holderKey, openedBySession, openedAt, state, reviewsAssignmentId)
      VALUES ('asg_review', 'review', 'reviewer', 'reviewer', 4, 'open', 'asg_direct');

      INSERT INTO supervision_entitlements
        (assignmentId, generation, dueAt, state, lastAttemptGeneration, claimClock,
         basisKind, basisId, terminusAt, cause, principal, supervisionIntervalMs)
      VALUES
        ('asg_direct', 1, 1000, 'armed', NULL, NULL, 'assignment_open',
         'asg_direct', NULL, 'assignment_open', 'user:owner', 1000),
        ('asg_bad', 1, 1000, 'armed', NULL, NULL, 'assignment_open',
         'asg_bad', NULL, 'assignment_open', 'user:owner', 1000);

      INSERT INTO assignment_files (assignmentId, path)
      VALUES ('asg_direct', 'z.ex'), ('asg_direct', 'a.ex');

      INSERT INTO turns
        (sessionKey, messageId, origin, prompt, assignmentId, jobRef, model, thinkingLevel,
         modelContext, harness, status, createdAt, endedAt)
      VALUES
        ('holder', 'm_direct', 'process:tightbeam', 'brief', 'asg_direct', 'wi_trace',
         'gpt-5.6-sol', 'high', '1m', 'codex', 'delivered', 100, 100),
        ('owner-session', 'm_nag', 'process:tightbeam', 'nag', NULL, 'wi_trace',
         NULL, NULL, NULL, NULL, 'queued', 100, NULL);

      INSERT INTO condition_facts (id, ts, kind, scope, origin)
      VALUES (1, 90, 'quota-recovered', 'asg_direct', 'user:owner');

      INSERT INTO wakes
        (wakeId, sessionKey, origin, prompt, dueAt, state, createdAt, firedAt,
         conditionKind, conditionScope, conditionAfterId, firedBy)
      VALUES
        ('w_condition', 'holder', 'user:owner', 'condition', 500, 'fired', 100, 100,
         'quota-recovered', 'asg_direct', 0, 'condition');

      INSERT INTO wakes
        (wakeId, sessionKey, origin, prompt, dueAt, state, createdAt, firedAt,
         firedBy, work_item_id)
      VALUES
        ('w_timed', 'owner-session', 'process:tightbeam', 'timed', 101, 'fired',
         101, 101, NULL, 'wi_trace');

      INSERT INTO effort_checkin_generations
        (assignmentId, generation, state, baseHorizonMs, multiplier, armedAt,
         terminalSeqWatermark, holderKey, host, root, baseline, wakeId, evidence)
      VALUES
        ('asg_direct', 1, 'probed', 10, 1, 100, 0, 'holder', 'eezo', '/tmp',
         '{"status":"available","observation":{"stamp":"/tmp/effort.stamp","prior":"observed","writes":0,"entries":1,"digest":"same"}}',
         'w_condition', '{"outcome":"zero_effect"}');

      INSERT INTO decision_requests
        (id, kind, raiserId, ownerUserId, assignmentId, raisedAt, deadlineAt,
         statuteName, actionKey, question, context, status, decision)
      VALUES
        ('dr_trace', 'statute', 'user:owner', 'owner', 'asg_direct', 100, 500,
         'trace-rule', 'trace-action', 'Choose', '{}', 'ruled', 'allow');
      """)

    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Tightbeam.DeliverableContract.create_work_item_in_txn(txn, "wi_trace", "Trace me", 1)

        for {id, subject, holder, opened_at, work_item_id} <- [
              {"asg_direct", "direct", "holder", 2, "wi_trace"},
              {"asg_bad", "invalid ref", "holder", 3, "wi_trace"},
              {"asg_review", "review", "reviewer", 4, nil}
            ] do
          :ok =
            Tightbeam.DeliverableContract.bind_assignment_in_txn(
              txn,
              %{
                id: id,
                subject: subject,
                holderKey: holder,
                openedAt: opened_at,
                workItemId: work_item_id
              },
              false
            )
        end

        :ok
      end)

    %{db: db}
  end

  test "proofs 3-5: exact trace schema, review join, wake fact, authorization, and commit refs",
       %{db: db} do
    repo = init_repo()
    on_exit(fn -> File.rm_rf!(repo) end)
    commit = git_output!(repo, ["rev-parse", "HEAD"])

    commit_refs = [
      %{"repo" => "#{Tightbeam.Placement.local_host_name()}:#{repo}", "commit" => commit}
    ]

    assert %{attest: %{commitRefs: ^commit_refs}} =
             attest(db, {:session, "holder"}, "asg_direct", "completion", %{
               commit_refs: commit_refs
             })

    assert %{attest: %{verdictKind: "reviewed-clean", commitRefs: ^commit_refs}} =
             attest(db, {:session, "reviewer"}, "asg_review", "verdict", %{
               verdict_kind: "reviewed-clean",
               commit_refs: commit_refs
             })

    assert %{code: "invalid_commit_refs"} =
             attest(db, {:session, "holder"}, "asg_bad", "verdict", %{
               verdict_kind: "reviewed-clean",
               commit_refs: commit_refs
             })

    assert %{code: "invalid_commit_refs"} =
             attest(db, {:session, "reviewer"}, "asg_review", "completion", %{
               commit_refs: commit_refs
             })

    assert %{attest: %{verdictKind: "changes-requested"}} =
             attest(db, {:session, "reviewer"}, "asg_review", "verdict", %{
               verdict_kind: "changes-requested"
             })

    :ok = DB.execute(db, "UPDATE attests SET ts = 100")

    assert %{code: "unverifiable_commit_ref"} =
             attest(db, {:session, "holder"}, "asg_bad", "completion", %{
               commit_refs: [
                 %{
                   "repo" => "#{Tightbeam.Placement.local_host_name()}:#{repo}",
                   "commit" => String.duplicate("0", 40)
                 }
               ]
             })

    trace = trace(db, {:user, "owner"}, "wi_trace")
    assert trace == trace(db, {:session, "owner-session"}, "wi_trace")
    assert trace == trace(db, {:user, "admin"}, "wi_trace")
    assert trace == trace(db, {:session, "admin-session"}, "wi_trace")

    assert %{code: "not_found"} = trace(db, {:user, "other"}, "wi_trace")
    assert %{code: "not_found"} = trace(db, {:session, "other-session"}, "wi_trace")
    assert %{code: "not_found"} = trace(db, {:process, "cron"}, "wi_trace")
    assert %{code: "not_found"} = trace(db, {:user, "owner"}, "wi_missing")

    assert_keys(trace, ~w(assignments timeline workItem)a)

    assert_keys(
      trace.workItem,
      ~w(cardProductOwner closure deliverable deliverableContract failReason id ownerUserId state title)a
    )

    assert Enum.map(trace.assignments, & &1.id) == ["asg_bad", "asg_direct", "asg_review"]

    Enum.each(trace.assignments, fn assignment ->
      assert_keys(
        assignment,
        ~w(deliverable deliverableContract files holderKey id openerRef productLineage reviewsAssignmentId state)a
      )
    end)

    direct = Enum.find(trace.assignments, &(&1.id == "asg_direct"))
    review = Enum.find(trace.assignments, &(&1.id == "asg_review"))
    assert direct.files == ["a.ex", "z.ex"]
    assert direct.openerRef == "user:owner"
    assert review.openerRef == "session:reviewer"
    assert review.reviewsAssignmentId == "asg_direct"

    Enum.each(trace.timeline, &assert_entry_schema/1)

    # The stamp must arrive as FIELDS with their real values. Asserting only
    # that the keys exist stays green if a consumer hardcodes or drops them.
    stamped = Enum.find(trace.timeline, &(&1.type == "turn_start" and &1.id == 1))
    assert {stamped.model, stamped.context, stamped.effort} == {"gpt-5.6-sol", "1m", "high"}
    assert stamped.harness == "codex"

    assert Enum.any?(trace.timeline, fn
             %{type: "attest", assignmentId: "asg_review", verdict: "changes-requested"} -> true
             _ -> false
           end)

    assert Enum.any?(trace.timeline, fn
             %{type: "attest", assignmentId: "asg_direct", commitRefs: ^commit_refs} -> true
             _ -> false
           end)

    assert Enum.any?(trace.timeline, fn
             %{
               type: "attest",
               assignmentId: "asg_review",
               verdict: "reviewed-clean",
               commitRefs: ^commit_refs
             } ->
               true

             _ ->
               false
           end)

    assert Enum.any?(trace.timeline, fn
             %{type: "wake_fired", id: "w_condition", matchedFactAt: 90} -> true
             _ -> false
           end)

    assert Enum.any?(trace.timeline, fn
             %{type: "wake_fired", id: "w_timed", firedBy: nil, matchedFactAt: nil} -> true
             _ -> false
           end)

    refute Enum.any?(
             trace.timeline,
             &(&1.type in ["wake_canceled", "marker", "disposition"])
           )

    at_100_types =
      trace.timeline
      |> Enum.filter(&(&1.at == 100))
      |> Enum.map(& &1.type)

    assert at_100_types == [
             "turn_start",
             "turn_start",
             "wake_scheduled",
             "wake_fired",
             "decision_request",
             "effort_generation",
             "attest",
             "attest",
             "attest",
             "turn_end"
           ]
  end

  test "commit refs verify on the named host only after holder authorization", %{db: db} do
    parent = self()
    old_runner = Application.get_env(:tightbeam, :commit_ref_command)

    on_exit(fn ->
      restore_env(:commit_ref_command, old_runner)
    end)

    # Hosts are rows in the handler's DB now; :base_dir still names the dir the
    # gateway's own registry entry is built from, so the test pins it.
    base_dir = Path.join(System.tmp_dir!(), "tb-job-trace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base_dir)
    Application.put_env(:tightbeam, :base_dir, base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    register_hosts(db, %{
      "remote-test" => %{ssh: "git@remote-test", base_dir: "/srv/tightbeam", cli_bin: nil}
    })

    Application.put_env(:tightbeam, :commit_ref_command, fn executable, args, opts ->
      send(parent, {:commit_ref_command, executable, args, opts})
      {"", 0}
    end)

    remote_refs = [
      %{"repo" => "remote-test:/srv/repo", "commit" => "0123456789abcdef"}
    ]

    assert %{code: "not_holder"} =
             attest(db, {:session, "other-session"}, "asg_bad", "completion", %{
               commit_refs: remote_refs
             })

    refute_received {:commit_ref_command, _, _, _}

    assert %{attest: %{commitRefs: ^remote_refs}} =
             attest(db, {:session, "holder"}, "asg_bad", "completion", %{
               commit_refs: remote_refs
             })

    assert_received {:commit_ref_command, "ssh", args, [stderr_to_stdout: true]}
    assert "git@remote-test" in args
    assert List.last(args) =~ "/srv/repo"
    assert List.last(args) =~ "0123456789abcdef^{commit}"
  end

  test "equal-time numeric turn ids sort numerically", %{db: db} do
    for suffix <- 3..10 do
      assert {:ok, []} =
               DB.query(
                 db,
                 """
                 INSERT INTO turns
                   (sessionKey, messageId, origin, prompt, jobRef, status, createdAt)
                 VALUES ('holder', ?1, 'process:tightbeam', 'same time', 'wi_trace', 'queued', 100)
                 """,
                 ["m_#{suffix}"]
               )
    end

    starts =
      db
      |> trace({:user, "owner"}, "wi_trace")
      |> Map.fetch!(:timeline)
      |> Enum.filter(&(&1.type == "turn_start" and &1.at == 100))
      |> Enum.map(& &1.id)

    assert starts == Enum.to_list(1..10)
  end

  defp assert_entry_schema(%{type: type} = entry) do
    keys =
      case type do
        type when type in ["turn_start", "turn_end"] ->
          ~w(assignmentId at context effort harness id jobRef model status type)a

        "attest" ->
          ~w(assignmentId at commitRefs deliverableClaim id kind type verdict)a

        "wake_scheduled" ->
          ~w(assignmentId at dueAt id type)a

        "wake_fired" ->
          ~w(assignmentId at firedBy id matchedFactAt type)a

        "decision_request" ->
          ~w(assignmentId at id ruling state type)a

        "effort_generation" ->
          ~w(assignmentId at evidence id state type)a

        # job-forensics-v2 §3 — pinned EXACTLY: every key always present,
        # nullable where the spec marks it, so a consumer never has to
        # distinguish absent from null.
        "causal_event" ->
          ~w(assignmentId at detail id jobRef kind seqTiebreak sessionKey type)a

        "wake_canceled" ->
          ~w(assignmentId at id reason seqTiebreak type)a
      end

    assert_keys(entry, keys)
  end

  defp assert_keys(map, keys), do: assert(Map.keys(map) |> Enum.sort() == Enum.sort(keys))

  defp trace(db, principal, id) do
    WorkItems.__handle__(db, "work-item-trace", %{
      verb: "work-item-trace",
      principal: principal,
      origin: origin(principal),
      session_key: nil,
      params: %{work_item_id: id}
    })
  end

  defp attest(db, principal, assignment_id, kind, extra) do
    Assignments.__handle__(db, "attest", %{
      verb: "attest",
      principal: principal,
      origin: origin(principal),
      session_key: nil,
      params: Map.merge(%{assignment_id: assignment_id, kind: kind}, extra)
    })
  end

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "eezo"
    })
  end

  defp init_repo do
    path =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-commit-ref-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    git!(path, ["init"])
    git!(path, ["config", "user.email", "test@example.invalid"])
    git!(path, ["config", "user.name", "Test"])
    File.write!(Path.join(path, "tracked.txt"), "trace\n")
    git!(path, ["add", "tracked.txt"])
    git!(path, ["commit", "-m", "trace"])
    path
  end

  defp git!(path, args) do
    {_output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    :ok
  end

  defp git_output!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp origin({:user, user}), do: "user:#{user}"
  defp origin({:session, session}), do: "agent:#{session}"
  defp origin({:process, process}), do: "process:#{process}"

  defp restore_env(key, nil), do: Application.delete_env(:tightbeam, key)
  defp restore_env(key, value), do: Application.put_env(:tightbeam, key, value)
end
