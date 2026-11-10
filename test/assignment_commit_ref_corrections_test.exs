defmodule Tightbeam.AssignmentCommitRefCorrectionsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    AssignmentCommitRefCorrections,
    Assignments,
    ConditionFacts,
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

    listed = Map.new(Assignments.list(ctx.db, %{state: "all"}), &{&1.id, &1})
    assert listed["asg_closed"].commitRefCorrections == [correction]
    assert listed["asg_open"].commitRefCorrections == []
    assert AssignmentCommitRefCorrections.list_many(ctx.db, []) == %{}
    assert AssignmentCommitRefCorrections.list(ctx.db, "absent") == []

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

  test "the declared remote may be origin while the configured URL still proves it", ctx do
    origin_ref = Map.put(ref(ctx), "remote", "origin")
    call = with_param(ctx, :commit_refs, [origin_ref])

    assert %{correction: correction} = correct(call, {:session, "po-owner"})
    assert is_integer(correction.verifiedAt)
    assert [%{"remote" => "origin", "verifiedRefCommit" => verified}] = correction.commitRefs
    assert verified == ctx.commit
  end

  test "a correction replaces an assignment's attest refs in the work-item summary", ctx do
    original_refs = [
      %{"repo" => "old-host:/old/repository", "commit" => String.duplicate("a", 40)},
      %{"repo" => "old-host:/old/repository", "commit" => String.duplicate("b", 40)}
    ]

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO attests (id, assignmentId, kind, bySession, commitRefs, ts) VALUES ('att_old_refs', 'asg_closed', 'completion', 'holder-owner', ?1, 4)",
               [JSON.encode!(original_refs)]
             )

    before =
      WorkItems.__handle__(ctx.db, "work-item-get", %{
        principal: {:user, "owner"},
        params: %{work_item_id: "wi_history"}
      }).workItem

    assert before.attestCounts == %{"completion" => 1}
    assert before.effectiveCommitRefs == original_refs

    assert %{correction: correction} = correct(ctx, {:session, "po-owner"})
    [%{"repo" => corrected_repo, "commit" => corrected_commit} | _] = correction.commitRefs

    after_correction =
      WorkItems.__handle__(ctx.db, "work-item-get", %{
        principal: {:user, "owner"},
        params: %{work_item_id: "wi_history"}
      }).workItem

    assert after_correction.attestCounts == before.attestCounts
    assert after_correction.verdictCounts == %{}

    assert after_correction.effectiveCommitRefs == [
             %{"repo" => corrected_repo, "commit" => corrected_commit}
           ]

    assert after_correction.rowVersion > before.rowVersion
  end

  test "a correction publishes the complete updated work-item summary", ctx do
    alias Tightbeam.Firehose.Hub

    hub = start_supervised!({Hub, name: nil})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "owner", is_admin: false})

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO attests (id, assignmentId, kind, bySession, commitRefs, ts) VALUES ('att_notice_refs', 'asg_closed', 'completion', 'holder-owner', ?1, 4)",
               [
                 JSON.encode!([
                   %{"repo" => "old-repository", "commit" => String.duplicate("a", 40)}
                 ])
               ]
             )

    before =
      WorkItems.__handle__(ctx.db, "work-item-get", %{
        principal: {:user, "owner"},
        params: %{work_item_id: "wi_history"}
      }).workItem

    handler = Gateway.handlers(%{db: ctx.db})["assignment-commitref-correct"]

    assert %{correction: %{assignmentId: "asg_closed"}} =
             handler.(%{
               principal: {:session, "po-owner"},
               params: params(ctx),
               firehose_hub: hub
             })

    assert_receive {:firehose_notice, %{"class" => "work_item.updated", "payload" => payload}}
    refute_receive {:firehose_notice, %{"class" => "work_item.updated"}}

    after_correction =
      WorkItems.__handle__(ctx.db, "work-item-get", %{
        principal: {:user, "owner"},
        params: %{work_item_id: "wi_history"}
      }).workItem

    assert payload["id"] == "wi_history"
    assert payload["holders"] == after_correction.holders
    assert payload["started"] == after_correction.started
    assert payload["attestCounts"] == after_correction.attestCounts
    assert payload["verdictCounts"] == after_correction.verdictCounts
    assert payload["effectiveCommitRefs"] == after_correction.effectiveCommitRefs
    assert payload["landings"] == after_correction.landings
    assert payload["rowVersion"] > before.rowVersion
    assert payload["rowVersion"] == after_correction.rowVersion
  end

  if Code.ensure_loaded?(ConditionFacts) and
       function_exported?(ConditionFacts, :landings_for_commits, 2) do
    test "a correction removes a landing association without deleting its observed record", ctx do
      alias Tightbeam.Firehose.Hub

      merge_commit = String.duplicate("a", 40)
      head_commit = String.duplicate("b", 40)

      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 "INSERT INTO attests (id, assignmentId, kind, bySession, commitRefs, ts) VALUES ('att_landing_refs', 'asg_closed', 'completion', 'holder-owner', ?1, 4)",
                 [
                   JSON.encode!([
                     %{"repo" => "unrelated/repository", "commit" => merge_commit}
                   ])
                 ]
               )

      assert %{kind: "landing.observed-merge"} =
               ConditionFacts.file_idempotent(
                 ctx.db,
                 :work_item_summary_test_scheduler,
                 %{
                   kind: "landing.observed-merge",
                   scope: "Example/Repo#12",
                   origin: "process:landing-watch",
                   payload: %{
                     "branch" => "main",
                     "commit" => merge_commit,
                     "headCommit" => head_commit
                   },
                   idempotency_key: "landing-record:Example/Repo#12:merged:#{merge_commit}"
                 }
               )

      before =
        WorkItems.__handle__(ctx.db, "work-item-get", %{
          principal: {:user, "owner"},
          params: %{work_item_id: "wi_history"}
        }).workItem

      assert [%{"commit" => ^merge_commit}] = before.landings

      hub = start_supervised!({Hub, name: nil})

      :ok =
        Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "owner", is_admin: false})

      handler = Gateway.handlers(%{db: ctx.db})["assignment-commitref-correct"]

      assert %{correction: %{assignmentId: "asg_closed"}} =
               handler.(%{
                 principal: {:session, "po-owner"},
                 params: params(ctx),
                 firehose_hub: hub
               })

      assert_receive {:firehose_notice, %{"class" => "work_item.updated", "payload" => payload}}

      after_correction =
        WorkItems.__handle__(ctx.db, "work-item-get", %{
          principal: {:user, "owner"},
          params: %{work_item_id: "wi_history"}
        }).workItem

      assert after_correction.landings == []
      assert payload["landings"] == after_correction.landings
      assert payload["rowVersion"] > before.rowVersion
      assert payload["rowVersion"] == after_correction.rowVersion

      assert [%{"commit" => ^merge_commit}] =
               apply(ConditionFacts, :landings_for_commits, [ctx.db, [merge_commit]])

      on_exit(fn -> Hub.unregister(hub, self()) end)
    end
  end

  test "schema upgrade makes verification time nullable without changing prior corrections",
       ctx do
    assert %{correction: correction} = correct(ctx, {:session, "po-owner"})
    assert is_integer(correction.verifiedAt)

    recreate_legacy_correction_table!(ctx.db)

    assert {:ok, columns} =
             DB.query(ctx.db, "PRAGMA table_info(assignment_commit_ref_corrections)")

    assert [_cid, "verifiedAt", "INTEGER", 1, nil, 0] =
             Enum.find(columns, &(&1 |> Enum.at(1) == "verifiedAt"))

    assert :ok = AssignmentCommitRefCorrections.ensure_schema(ctx.db)
    assert [^correction] = AssignmentCommitRefCorrections.list(ctx.db, "asg_closed")

    assert {:ok, columns} =
             DB.query(ctx.db, "PRAGMA table_info(assignment_commit_ref_corrections)")

    assert [_cid, "verifiedAt", "INTEGER", 0, nil, 0] =
             Enum.find(columns, &(&1 |> Enum.at(1) == "verifiedAt"))
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

  test "a closed review assignment can be corrected by its opener without a shared lane", ctx do
    session(ctx.db, "review-lineage-root", "owner", "default", Org.personal_session_key("owner"))
    session(ctx.db, "review-opener", "owner", "default", "review-lineage-root")
    session(ctx.db, "review-holder", "owner", "default", "review-lineage-root")

    :ok =
      DB.execute(ctx.db, """
      INSERT INTO assignments
        (id, subject, holderKey, openedBySession, openedAt, state, outcome,
         closedAt, closedBySession, workItemId)
      VALUES
        ('asg_review', 'closed review', 'review-holder', 'review-opener', 5,
         'open', NULL, NULL, NULL, 'wi_history');

      INSERT INTO attests (id, assignmentId, kind, bySession, ts)
      VALUES ('att_review_close', 'asg_review', 'completion', 'holder-other', 6);

      UPDATE assignments
      SET state='closed', outcome='completed', closedAt=6,
          closedBySession='holder-other', closingAttestId='att_review_close'
      WHERE id='asg_review';
      """)

    assert %{id: "asg_review", state: "closed"} =
             Assignments.__handle__(ctx.db, "assignment-get", %{
               principal: {:session, "review-opener"},
               params: %{assignment_id: "asg_review"}
             })

    review = with_param(ctx, :assignment_id, "asg_review")

    assert %{
             correction: %{
               assignmentId: "asg_review",
               commitRefs: [%{"verifiedRefCommit" => verified}]
             }
           } = correct(review, {:session, "review-opener"})

    assert verified == ctx.commit
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

  test "failed canonical checks are recorded by name with no verification time", ctx do
    tree = git_output!(ctx.repo, ["rev-parse", "#{ctx.commit}^{tree}"])

    local_ahead =
      git_output!(ctx.repo, ["commit-tree", tree, "-p", ctx.commit, "-m", "local ahead"])

    unrelated = git_output!(ctx.repo, ["commit-tree", tree, "-m", "unrelated"])

    git!(ctx.repo, ["update-ref", "refs/heads/main", local_ahead])
    git!(ctx.repo, ["update-ref", "refs/heads/local-only", ctx.commit])
    git!(ctx.repo, ["update-ref", "refs/heads/unrelated", unrelated])
    git!(ctx.repo, ["push", "origin", "refs/heads/unrelated"])

    bad_refs = [
      {"asg_bad_remote", Map.put(ref(ctx), "remote", "missing"),
       "declared_remote_matches_origin"},
      {"asg_bad_ref", Map.put(ref(ctx), "ref", "refs/heads/missing"),
       "declared_local_ref_resolution"},
      {"asg_bad_commit", Map.put(ref(ctx), "commit", String.duplicate("f", 40)),
       "declared_commit_resolution"},
      {"asg_origin_bad_ref",
       Map.merge(ref(ctx), %{"remote" => "origin", "ref" => "refs/heads/missing"}),
       "declared_local_ref_resolution"},
      {"asg_missing_remote_ref", Map.put(ref(ctx), "ref", "refs/heads/local-only"),
       "declared_remote_ref_resolution"},
      {"asg_remote_ref_mismatch", ref(ctx), "remote_ref_matches_declared_local_ref"},
      {"asg_non_ancestor", Map.put(ref(ctx), "ref", "refs/heads/unrelated"),
       "commit_is_ancestor_of_declared_local_ref"}
    ]

    for {assignment_id, requested_ref, failed_check} <- bad_refs do
      insert_closed_assignment!(ctx.db, assignment_id)

      correction_call =
        ctx
        |> with_param(:assignment_id, assignment_id)
        |> with_param(:commit_refs, [requested_ref])
        |> with_param(:idempotency_key, "history-#{assignment_id}")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{warning: warning, verificationFailure: ^failed_check, correction: correction} =
                   correct(correction_call, {:session, "po-owner"})

          assert warning =~ "canonical Git check failed: #{failed_check}"
          assert correction.assignmentId == assignment_id
          assert is_nil(correction.verifiedAt)
          assert correction.commitRefs == [requested_ref]
        end)

      assert log =~
               "commit_ref_correction_unverified assignmentId=#{assignment_id} failedCheck=#{failed_check}"

      assert [%{verifiedAt: nil, commitRefs: [^requested_ref]}] =
               AssignmentCommitRefCorrections.list(ctx.db, assignment_id)
    end
  end

  test "an exact replay verifies an existing correction without changing its contents or history",
       ctx do
    assignment_id = "asg_review_reverify_valid"
    insert_closed_review_assignment!(ctx.db, assignment_id)

    requested_ref = Map.put(ref(ctx), "ref", "refs/heads/reverify-valid")

    call =
      ctx
      |> with_param(:assignment_id, assignment_id)
      |> with_param(:commit_refs, [requested_ref])
      |> with_param(:idempotency_key, "review-reverify-valid")

    assert %{
             correction: original,
             verificationFailure: "declared_local_ref_resolution"
           } = correct(call, {:session, "po-owner"})

    assert is_nil(original.verifiedAt)
    assert [original_history] = correction_history(ctx.db, assignment_id)
    original_lifecycle = lifecycle(ctx.db, assignment_id)
    assert [original] = AssignmentCommitRefCorrections.list(ctx.db, assignment_id)

    git!(ctx.repo, ["update-ref", "refs/heads/reverify-valid", ctx.commit])
    git!(ctx.repo, ["push", "origin", "refs/heads/reverify-valid"])

    assert %{correction: verified} = correct(call, {:session, "po-owner"})
    assert is_integer(verified.verifiedAt)
    assert Map.delete(verified, :verifiedAt) == Map.delete(original, :verifiedAt)
    assert verified.commitRefs == original.commitRefs
    refute Map.has_key?(hd(verified.commitRefs), "verifiedRefCommit")

    assert [verified] = AssignmentCommitRefCorrections.list(ctx.db, assignment_id)
    assert [verified_history] = correction_history(ctx.db, assignment_id)
    assert verified_history == Map.put(original_history, :verifiedAt, verified.verifiedAt)
    assert lifecycle(ctx.db, assignment_id) == original_lifecycle

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM attests WHERE assignmentId=?1",
               [assignment_id]
             )
  end

  test "an invalid correction replay preserves its named failure and history",
       ctx do
    assignment_id = "asg_review_reverify_invalid"
    insert_closed_review_assignment!(ctx.db, assignment_id)

    requested_ref = Map.put(ref(ctx), "remote", "missing")

    call =
      ctx
      |> with_param(:assignment_id, assignment_id)
      |> with_param(:commit_refs, [requested_ref])
      |> with_param(:idempotency_key, "review-reverify-invalid")

    assert %{correction: original, verificationFailure: "declared_remote_matches_origin"} =
             correct(call, {:session, "po-owner"})

    assert is_nil(original.verifiedAt)
    assert [original_history] = correction_history(ctx.db, assignment_id)
    original_lifecycle = lifecycle(ctx.db, assignment_id)

    assert %{
             correction: ^original,
             warning: warning,
             verificationFailure: "declared_remote_matches_origin"
           } = correct(call, {:session, "po-owner"})

    assert warning =~ "canonical Git check failed: declared_remote_matches_origin"
    assert [^original] = AssignmentCommitRefCorrections.list(ctx.db, assignment_id)
    assert [^original_history] = correction_history(ctx.db, assignment_id)
    assert lifecycle(ctx.db, assignment_id) == original_lifecycle

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignment_commit_ref_corrections WHERE assignmentId=?1",
               [assignment_id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM attests WHERE assignmentId=?1",
               [assignment_id]
             )
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

  @tag :tmp_dir
  test "the append-only row and exact replay survive a database restart", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "assignment_commit_ref_restart.exs",
      "commitref-restart: ok"
    )
  end

  test "process corrections retain their actor and malformed requests cannot enter the ledger",
       ctx do
    assert %{correction: %{actorKind: "process", actorRef: "automation"}} =
             correct(ctx, {:process, "automation"})

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

  defp insert_closed_assignment!(db, assignment_id) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        revocation_id = "history-revocation-#{assignment_id}"

        Tightbeam.DB.Txn.q(
          txn,
          """
          INSERT INTO assignments
            (id, subject, holderKey, openedBySession, openedAt, state, outcome,
             closedAt, closedBySession, workItemId)
          VALUES (?1, 'unverified correction', 'holder-owner', 'po-owner', 2,
                  'open', NULL, NULL, NULL, 'wi_history')
          """,
          [assignment_id]
        )

        Tightbeam.DB.Txn.q(
          txn,
          """
          INSERT INTO assignment_revocations
            (id, assignmentId, revokedAt, revokedBySession, reason)
          VALUES (?1, ?2, 3, 'po-owner', 'historical correction fixture')
          """,
          [revocation_id, assignment_id]
        )

        Tightbeam.DB.Txn.q(
          txn,
          """
          INSERT INTO assignment_revocation_generations
            (revocationId, assignmentId, reopeningId)
          VALUES (?1, ?2, NULL)
          """,
          [revocation_id, assignment_id]
        )

        Tightbeam.DB.Txn.q(
          txn,
          """
          UPDATE assignments
          SET state='closed', outcome='revoked', closedAt=3, closedBySession='po-owner'
          WHERE id=?1
          """,
          [assignment_id]
        )

        if Tightbeam.DB.Txn.changes(txn) != 1, do: raise("fixture assignment missing")
        :ok
      end)
  end

  defp insert_closed_review_assignment!(db, assignment_id) do
    closing_attest_id = "att_review_close_#{assignment_id}"

    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Tightbeam.DB.Txn.q(
          txn,
          """
          INSERT INTO assignments
            (id, subject, holderKey, openedBySession, openedAt, state, outcome,
             closedAt, closedBySession, closingAttestId, workItemId)
          VALUES (?1, 'closed review', 'holder-owner', 'po-owner', 5,
                  'open', NULL, NULL, NULL, NULL, 'wi_history')
          """,
          [assignment_id]
        )

        Tightbeam.DB.Txn.q(
          txn,
          "INSERT INTO attests (id, assignmentId, kind, bySession, ts) " <>
            "VALUES (?1, ?2, 'completion', 'holder-owner', 6)",
          [closing_attest_id, assignment_id]
        )

        Tightbeam.DB.Txn.q(
          txn,
          "UPDATE assignments SET state='closed', outcome='completed', closedAt=6, " <>
            "closedBySession='holder-owner', closingAttestId=?1 WHERE id=?2",
          [closing_attest_id, assignment_id]
        )

        :ok
      end)
  end

  defp correction_history(db, assignment_id) do
    trace =
      WorkItems.__handle__(db, "work-item-trace", %{
        principal: {:user, "owner"},
        params: %{work_item_id: "wi_history"}
      })

    Enum.filter(
      trace.timeline,
      &(&1.type == "commit_ref_correction" and &1.assignmentId == assignment_id)
    )
  end

  defp recreate_legacy_correction_table!(db) do
    :ok = DB.execute(db, "DROP INDEX IF EXISTS assignment_commit_ref_corrections_assignment")

    :ok =
      DB.execute(
        db,
        "ALTER TABLE assignment_commit_ref_corrections RENAME TO correction_before_nullable_test"
      )

    :ok =
      DB.execute(db, """
      CREATE TABLE assignment_commit_ref_corrections (
        id                 TEXT PRIMARY KEY,
        assignmentId       TEXT NOT NULL UNIQUE REFERENCES assignments(id),
        commitRefs         TEXT NOT NULL CHECK (json_valid(commitRefs) AND json_type(commitRefs) = 'array'),
        reason             TEXT NOT NULL CHECK (length(trim(reason)) BETWEEN 1 AND 4000),
        evidenceArtifactId TEXT NOT NULL REFERENCES artifacts(artifactId),
        actorKind          TEXT NOT NULL CHECK (actorKind IN ('user','session')),
        actorRef           TEXT NOT NULL,
        cause              TEXT NOT NULL CHECK (cause = 'historical_canonical_commitref_correction'),
        idempotencyKey     TEXT NOT NULL CHECK (length(trim(idempotencyKey)) BETWEEN 1 AND 200),
        requestFingerprint TEXT NOT NULL CHECK (length(requestFingerprint) = 64),
        verifiedAt         INTEGER NOT NULL,
        createdAt          INTEGER NOT NULL,
        UNIQUE (actorKind, actorRef, idempotencyKey)
      );

      INSERT INTO assignment_commit_ref_corrections
      SELECT * FROM correction_before_nullable_test;

      DROP TABLE correction_before_nullable_test;
      CREATE INDEX assignment_commit_ref_corrections_assignment
        ON assignment_commit_ref_corrections (assignmentId, createdAt, id);
      """)
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

    :ok =
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
      ('asg_closed', 'closed history', 'holder-owner', 'po-owner', 2, 'open',
       NULL, NULL, NULL, 'wi_history'),
      ('asg_open', 'open history', 'holder-owner', 'po-owner', 2, 'open',
       NULL, NULL, NULL, 'wi_history'),
      ('asg_hidden', 'other lane', 'holder-other', 'po-other', 2, 'open',
       NULL, NULL, NULL, 'wi_other');

      INSERT INTO assignment_revocations
        (id, assignmentId, revokedAt, revokedBySession, reason)
      VALUES
        ('rev_closed', 'asg_closed', 3, 'po-owner', 'historical revocation'),
        ('rev_hidden', 'asg_hidden', 3, 'po-other', 'historical revocation');

      INSERT INTO assignment_revocation_generations
        (revocationId, assignmentId, reopeningId)
      VALUES
        ('rev_closed', 'asg_closed', NULL),
        ('rev_hidden', 'asg_hidden', NULL);

      UPDATE assignments
      SET state='closed', outcome='revoked', closedAt=3, closedBySession='po-owner'
      WHERE id='asg_closed';

      UPDATE assignments
      SET state='closed', outcome='revoked', closedAt=3, closedBySession='po-other'
      WHERE id='asg_hidden';

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
