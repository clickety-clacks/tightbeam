defmodule Tightbeam.AssignmentCommitRefCorrectionsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    AssignmentCommitRefCorrections,
    Assignments,
    DB,
    Gateway,
    Model,
    Org,
    WorkItems
  }

  setup do
    db = :"commitref_correction_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    seed_database!(db)

    {repo, remote, commit} = canonical_repo!()
    on_exit(fn -> File.rm_rf!(Path.dirname(repo)) end)

    %{db: db, repo: repo, remote: remote, commit: commit}
  end

  test "an accountable product owner appends one exact, visible, lifecycle-neutral correction",
       ctx do
    before = lifecycle(ctx.db, "asg_closed")

    assert %{correction: correction} = correct(ctx, {:session, "po-owner"})
    assert correction.assignmentId == "asg_closed"
    assert correction.actorKind == "session"
    assert correction.actorRef == "po-owner"
    assert correction.cause == "historical_canonical_commitref_correction"
    assert correction.evidenceArtifactId == "art_evidence"
    assert correction.idempotencyKey == "history-1"
    assert is_integer(correction.verifiedAt)
    assert correction.verifiedAt <= correction.createdAt
    assert [%{"verifiedRefCommit" => verified}] = correction.commitRefs
    assert verified == ctx.commit

    assert lifecycle(ctx.db, "asg_closed") == before

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM attests WHERE assignmentId='asg_closed'")

    assert %{commitRefCorrections: [^correction]} = assignment_get(ctx.db, "asg_closed")

    assert %{assignments: [%{id: "asg_closed", commitRefCorrections: [^correction]} | _]} =
             WorkItems.__handle__(ctx.db, "work-item-trace", %{
               principal: {:user, "owner"},
               params: %{work_item_id: "wi_history"}
             })

    trace =
      WorkItems.__handle__(ctx.db, "work-item-trace", %{
        principal: {:user, "owner"},
        params: %{work_item_id: "wi_history"}
      })

    assert [entry] = Enum.filter(trace.timeline, &(&1.type == "commit_ref_correction"))
    assert entry.id == correction.id
    assert entry.assignmentId == "asg_closed"
    assert entry.commitRefs == correction.commitRefs
    assert entry.evidenceArtifactId == "art_evidence"
    assert entry.actorKind == "session"
    assert entry.actorRef == "po-owner"
    assert entry.cause == "historical_canonical_commitref_correction"
    assert entry.verifiedAt == correction.verifiedAt
  end

  test "only the accountability owner or matching product owner is authorized", ctx do
    assert %{correction: %{actorKind: "user", actorRef: "owner"}} =
             correct(ctx, {:user, "owner"})

    for principal <- [{:user, "other"}, {:user, "admin"}] do
      assert %{code: "unknown_assignment"} = correct(ctx, principal)
    end
  end

  test "the Gateway exposes the same typed handler result", ctx do
    handler = Gateway.handlers(%{db: ctx.db})["assignment-commitref-correct"]

    assert %{correction: %{assignmentId: "asg_closed", actorRef: "po-owner"}} =
             handler.(%{
               principal: {:session, "po-owner"},
               params: params(ctx)
             })
  end

  test "one SHA-bound backfill artifact can support a target on another work item", ctx do
    call = with_param(ctx, :evidence_artifact_id, "art_wrong_item")

    assert %{correction: correction} = correct(call, {:session, "po-owner"})
    assert correction.assignmentId == "asg_closed"
    assert correction.evidenceArtifactId == "art_wrong_item"

    assert {:ok, [["wi_other", sha]]} =
             DB.query(
               ctx.db,
               "SELECT workItemId, contentSha256 FROM artifacts WHERE artifactId='art_wrong_item'"
             )

    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, sha)
    assert %{commitRefCorrections: [^correction]} = assignment_get(ctx.db, "asg_closed")
  end

  test "wrong product lane and hidden target fail identically before git proof", ctx do
    parent = self()
    old_runner = Application.get_env(:tightbeam, :commit_ref_command)
    on_exit(fn -> restore_env(:commit_ref_command, old_runner) end)

    Application.put_env(:tightbeam, :commit_ref_command, fn executable, args, opts ->
      send(parent, {:git_ran, executable, args, opts})
      System.cmd(executable, args, opts)
    end)

    assert %{code: "unknown_assignment"} = correct(ctx, {:session, "po-other"})

    abbreviated = with_param(ctx, :assignment_id, "asg_clos")
    assert %{code: "unknown_assignment"} = correct(abbreviated, {:session, "po-owner"})

    missing = with_param(ctx, :assignment_id, "asg_missing")
    assert %{code: "unknown_assignment"} = correct(missing, {:session, "po-other"})
    refute_received {:git_ran, _, _, _}
  end

  test "open, absent, and unbound evidence refuse before git proof", ctx do
    parent = self()
    old_runner = Application.get_env(:tightbeam, :commit_ref_command)
    on_exit(fn -> restore_env(:commit_ref_command, old_runner) end)

    Application.put_env(:tightbeam, :commit_ref_command, fn executable, args, opts ->
      send(parent, {:git_ran, executable, args, opts})
      System.cmd(executable, args, opts)
    end)

    open = with_param(ctx, :assignment_id, "asg_open")
    assert %{code: "assignment_open"} = correct(open, {:session, "po-owner"})

    unsigned = with_param(ctx, :evidence_artifact_id, "art_unsigned")
    assert %{code: "invalid_evidence"} = correct(unsigned, {:session, "po-owner"})

    absent = with_param(ctx, :evidence_artifact_id, "art_missing")
    assert %{code: "invalid_evidence"} = correct(absent, {:session, "po-owner"})
    refute_received {:git_ran, _, _, _}
  end

  test "canonical remote, ref, and commit proof is mandatory", ctx do
    bad_remote = with_param(ctx, :commit_refs, [Map.put(ref(ctx), "remote", "missing")])
    assert %{code: "unverifiable_commit_ref"} = correct(bad_remote, {:session, "po-owner"})

    bad_ref = with_param(ctx, :commit_refs, [Map.put(ref(ctx), "ref", "refs/heads/missing")])
    assert %{code: "unverifiable_commit_ref"} = correct(bad_ref, {:session, "po-owner"})

    bad_commit =
      with_param(ctx, :commit_refs, [Map.put(ref(ctx), "commit", String.duplicate("f", 40))])

    assert %{code: "unverifiable_commit_ref"} = correct(bad_commit, {:session, "po-owner"})
    assert AssignmentCommitRefCorrections.list(ctx.db, "asg_closed") == []
  end

  test "same request replays, changed replay conflicts, and a second correction is denied", ctx do
    assert %{correction: first} = correct(ctx, {:session, "po-owner"})
    assert %{correction: ^first} = correct(ctx, {:session, "po-owner"})

    changed = with_param(ctx, :reason, "different reason")
    assert %{code: "idempotency_conflict"} = correct(changed, {:session, "po-owner"})

    second = with_param(ctx, :idempotency_key, "history-2")
    assert %{code: "correction_exists"} = correct(second, {:session, "po-owner"})
    assert [_one] = AssignmentCommitRefCorrections.list(ctx.db, "asg_closed")
  end

  test "a concurrent exact replay commits once and remains stable after schema reensure", ctx do
    tasks = for _ <- 1..2, do: Task.async(fn -> correct(ctx, {:session, "po-owner"}) end)

    assert [%{correction: first}, %{correction: second}] =
             Enum.map(tasks, &Task.await(&1, 10_000))

    assert first == second
    assert [_one] = AssignmentCommitRefCorrections.list(ctx.db, "asg_closed")

    :ok = AssignmentCommitRefCorrections.ensure_schema(ctx.db)
    assert %{correction: ^first} = correct(ctx, {:session, "po-owner"})
  end

  test "authorization and target state are rechecked after external proof", ctx do
    call = %{
      principal: {:session, "po-owner"},
      params: params(ctx),
      on_refs_verified: fn db ->
        :ok =
          DB.execute(
            db,
            "UPDATE assignments SET state='open', outcome=NULL, closedAt=NULL, " <>
              "closedBySession=NULL WHERE id='asg_closed'"
          )
      end
    }

    assert %{code: "assignment_open"} =
             AssignmentCommitRefCorrections.__handle__(
               ctx.db,
               "assignment-commitref-correct",
               call
             )

    assert AssignmentCommitRefCorrections.list(ctx.db, "asg_closed") == []
  end

  test "the append-only row and exact replay survive a database restart", ctx do
    path =
      Path.join(System.tmp_dir!(), "commitref-restart-#{System.unique_integer([:positive])}.db")

    db = :"commitref_restart_#{System.unique_integer([:positive])}"
    {:ok, first_pid} = DB.start_link(path: path, name: db)
    seed_database!(db)

    restarted_ctx = %{ctx | db: db}
    assert %{correction: first} = correct(restarted_ctx, {:session, "po-owner"})
    GenServer.stop(first_pid)

    {:ok, second_pid} = DB.start_link(path: path, name: db)

    on_exit(fn ->
      if Process.alive?(second_pid), do: GenServer.stop(second_pid)
      File.rm(path)
    end)

    assert [^first] = AssignmentCommitRefCorrections.list(db, "asg_closed")
    assert %{correction: ^first} = correct(restarted_ctx, {:session, "po-owner"})
  end

  test "process principals and malformed requests cannot enter the correction ledger", ctx do
    assert %{code: "process_denied"} = correct(ctx, {:process, "tightbeam"})

    for {field, value, code} <- [
          {:idempotency_key, "", "invalid_idempotency_key"},
          {:reason, "", "invalid_reason"},
          {:evidence_artifact_id, nil, "invalid_evidence"},
          {:commit_refs, [], "invalid_commit_refs"}
        ] do
      malformed = with_param(ctx, field, value)
      assert %{code: ^code} = correct(malformed, {:session, "po-owner"})
    end
  end

  defp correct(ctx, principal) do
    params = params(ctx)

    AssignmentCommitRefCorrections.__handle__(ctx.db, "assignment-commitref-correct", %{
      principal: principal,
      params: params
    })
  end

  defp with_param(ctx, key, value), do: Map.put(ctx, :params, Map.put(params(ctx), key, value))

  defp params(ctx) do
    Map.get(ctx, :params, %{
      assignment_id: "asg_closed",
      commit_refs: [ref(ctx)],
      evidence_artifact_id: "art_evidence",
      reason: "canonical historical backfill",
      idempotency_key: "history-1"
    })
  end

  defp ref(ctx) do
    %{
      "repo" => "#{Tightbeam.Placement.local_host_name()}:#{ctx.repo}",
      "remote" => ctx.remote,
      "ref" => "refs/heads/main",
      "commit" => ctx.commit
    }
  end

  defp assignment_get(db, id) do
    Assignments.__handle__(db, "assignment-get", %{
      principal: {:user, "owner"},
      params: %{assignment_id: id}
    })
  end

  defp seed_database!(db) do
    :ok = ensure_all_schemas(db)

    :ok =
      DB.execute(db, """
      INSERT INTO users (userId, isAdmin, createdAt)
      VALUES ('owner', 0, 1), ('other', 0, 1), ('admin', 1, 1);
      """)

    Enum.each(~w(owner other admin), &ensure_main_session(db, &1))
    session(db, "po-owner", "owner", "product-owner", Org.personal_session_key("owner"))
    session(db, "holder-owner", "owner", "coder", "po-owner")
    session(db, "po-other", "other", "product-owner", Org.personal_session_key("other"))
    session(db, "holder-other", "other", "coder", "po-other")

    DB.execute(db, """
    INSERT INTO work_items
      (id, title, ownerUserId, state, createdByUser, createdAt)
    VALUES
      ('wi_history', 'Historical correction', 'owner', 'open', 'owner', 1),
      ('wi_other', 'Other evidence', 'other', 'open', 'other', 1);

    INSERT INTO assignments
      (id, subject, holderKey, openedBySession, openedAt, state, outcome,
       closedAt, closedBySession, workItemId)
    VALUES
      ('asg_closed', 'closed history', 'holder-owner', 'po-owner', 2, 'closed',
       'revoked', 3, 'po-owner', 'wi_history'),
      ('asg_open', 'open history', 'holder-owner', 'po-owner', 2, 'open',
       NULL, NULL, NULL, 'wi_history'),
      ('asg_hidden', 'other lane', 'holder-other', 'po-other', 2, 'closed',
       'revoked', 3, 'po-other', 'wi_other');

    INSERT INTO artifacts
      (artifactId, kind, title, createdBySession, workItemId, originPath,
       contentSha256, state, createdAt, updatedAt)
    VALUES
      ('art_evidence', 'report', 'canonical proof', 'po-owner', 'wi_history',
       '/proof/history.md', '#{String.duplicate("a", 64)}', 'in-workspace', 4, 4),
      ('art_wrong_item', 'report', 'wrong proof', 'po-other', 'wi_other',
       '/proof/other.md', '#{String.duplicate("b", 64)}', 'in-workspace', 4, 4),
      ('art_unsigned', 'report', 'unsigned proof', 'po-owner', 'wi_history',
       '/proof/unsigned.md', NULL, 'in-workspace', 4, 4);
    """)
  end

  defp lifecycle(db, id) do
    {:ok, [row]} =
      DB.query(
        db,
        "SELECT state, outcome, closedAt, closedByUser, closedBySession, closingAttestId " <>
          "FROM assignments WHERE id=?1",
        [id]
      )

    row
  end

  defp session(db, key, owner, archetype, spawned_by) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      spawned_by: spawned_by,
      archetype: archetype,
      harness: "codex",
      provider: "openai",
      model: Model.new("test"),
      host: "testhost"
    })
  end

  defp canonical_repo! do
    root =
      Path.join(System.tmp_dir!(), "commitref-correction-#{System.unique_integer([:positive])}")

    repo = Path.join(root, "repo")
    remote = Path.join(root, "remote.git")
    File.mkdir_p!(root)
    git!(root, ["init", "--bare", remote])
    git!(root, ["init", "-b", "main", repo])
    git!(repo, ["config", "user.email", "test@example.invalid"])
    git!(repo, ["config", "user.name", "Test"])
    File.write!(Path.join(repo, "proof.txt"), "canonical\n")
    git!(repo, ["add", "proof.txt"])
    git!(repo, ["commit", "-m", "canonical"])
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "-u", "origin", "main"])
    {repo, remote, git_output!(repo, ["rev-parse", "HEAD"])}
  end

  defp git!(cwd, args) do
    {_output, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
    :ok
  end

  defp git_output!(cwd, args) do
    {output, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp restore_env(key, nil), do: Application.delete_env(:tightbeam, key)
  defp restore_env(key, value), do: Application.put_env(:tightbeam, key, value)
end
