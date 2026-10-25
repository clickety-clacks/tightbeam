defmodule Tightbeam.FileEffectValidationPortTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    ArtifactContent,
    AttestEvidence,
    DB,
    FileEffectEvidence,
    Gateway,
    Mementos,
    Model,
    OperationalEvidence,
    Org,
    Placement,
    Rules,
    Schema
  }

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    :ok = ArtifactContent.ensure_schema(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1)"
      )

    main =
      Org.create(db, %{
        session_key: Org.personal_session_key("owner"),
        display_name: "Main",
        kind: "main",
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })

    holder =
      Org.create(db, %{
        session_key: "agent:file-holder",
        display_name: "Holder",
        owner_user_id: "owner",
        origin: "user:owner",
        spawned_by: main.session_key,
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })

    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})

    item =
      handlers["work-item-create"].(%{
        principal: {:user, "owner"},
        origin: "user:owner",
        params: %{title: "Captured file result"}
      })

    assignment_id = "asg_file_result"

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,workItemId) VALUES(?1,'Record file result',?2,?3,1,?4)",
        [assignment_id, holder.session_key, main.session_key, item.id]
      )

    %{
      db: db,
      handlers: handlers,
      item_id: item.id,
      assignment_id: assignment_id,
      holder: holder.session_key
    }
  end

  test "captured public artifacts validate one exact file pointer", ctx do
    before = capture(ctx, "old bytes")
    after_file = capture(ctx, "new bytes")
    observation = capture(ctx, "observed new bytes")
    manifest = capture(ctx, manifest(ctx, before, after_file, observation) |> JSON.encode!())
    pointer = "file-evidence/v1:#{manifest.id}:#{manifest.hash}"

    assert {:ok, result} =
             DB.transaction(ctx.db, fn txn ->
               FileEffectEvidence.validate!(
                 txn,
                 proof_call(ctx, manifest, pointer),
                 "example/evidence",
                 "revision"
               )
             end)

    assert result.assignment_id == ctx.assignment_id
    assert result.comparison_value == pointer
    assert result.after.sha256 == after_file.hash
    assert [%{scope: "disk-bytes", author: author}] = result.observation_authors
    assert author == ctx.holder
  end

  test "wrong supporting hash and uncaptured bytes refuse with the failed relation", ctx do
    before = capture(ctx, "old bytes")
    after_file = capture(ctx, "new bytes")
    observation = capture(ctx, "observed new bytes")

    changed =
      manifest(ctx, before, after_file, observation)
      |> put_in(["after", "sha256"], String.duplicate("0", 64))
      |> JSON.encode!()
      |> then(&capture(ctx, &1))

    changed_pointer = "file-evidence/v1:#{changed.id}:#{changed.hash}"

    assert {:error, %Mementos.Refusal{code: "file_effect_evidence_invalid", message: message}} =
             DB.transaction(ctx.db, fn txn ->
               FileEffectEvidence.validate!(
                 txn,
                 proof_call(ctx, changed, changed_pointer),
                 "example/evidence",
                 "revision"
               )
             end)

    assert message =~ "after"

    metadata = capture(ctx, nil)

    uncaptured_manifest =
      manifest(ctx, %{before | id: metadata.id}, after_file, observation)
      |> JSON.encode!()
      |> then(&capture(ctx, &1))

    uncaptured_pointer = "file-evidence/v1:#{uncaptured_manifest.id}:#{uncaptured_manifest.hash}"

    assert {:error, %Mementos.Refusal{code: "file_effect_evidence_unavailable", message: message}} =
             DB.transaction(ctx.db, fn txn ->
               FileEffectEvidence.validate!(
                 txn,
                 proof_call(ctx, uncaptured_manifest, uncaptured_pointer),
                 "example/evidence",
                 "revision"
               )
             end)

    assert message =~ metadata.id
  end

  test "operational evidence requires captured bytes from the original holder", ctx do
    captured = capture(ctx, "operation and observed result")

    call = %{
      principal: {:session, ctx.holder},
      params: %{
        assignment_id: ctx.assignment_id,
        artifact_id: captured.id,
        content_sha256: captured.hash
      }
    }

    assert {:ok, %{artifact_id: artifact_id, sha256: digest}} =
             DB.transaction(ctx.db, fn txn -> OperationalEvidence.validate!(txn, call) end)

    assert artifact_id == captured.id
    assert digest == captured.hash

    wrong = put_in(call, [:params, :content_sha256], String.duplicate("0", 64))

    assert {:error, %Mementos.Refusal{code: "operational_evidence_invalid"}} =
             DB.transaction(ctx.db, fn txn -> OperationalEvidence.validate!(txn, wrong) end)

    metadata = capture(ctx, nil)
    uncaptured = put_in(call, [:params, :artifact_id], metadata.id)

    assert {:error, %Mementos.Refusal{code: "content_not_captured"}} =
             DB.transaction(ctx.db, fn txn -> OperationalEvidence.validate!(txn, uncaptured) end)

    another = put_in(call, [:params, :assignment_id], "another-assignment")

    assert {:error, %Mementos.Refusal{code: "operational_evidence_invalid"}} =
             DB.transaction(ctx.db, fn txn -> OperationalEvidence.validate!(txn, another) end)
  end

  test "attest policy selects captured operational evidence from stored assignment scope", ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES(?1,'live_mutation')",
        [ctx.assignment_id]
      )

    captured = capture(ctx, "operation and observed result")

    call = %{
      verb: "attest",
      principal: {:session, ctx.holder},
      origin: ctx.holder,
      params: %{
        assignment_id: ctx.assignment_id,
        kind: "verdict",
        verdict_kind: "verified",
        artifact_id: captured.id,
        content_sha256: captured.hash
      }
    }

    policy = %{
      name: "operation-evidence",
      purpose: "attest-operational-evidence",
      source: "test-policy",
      conditions: [
        %{fact: "assignment.effect_kind", op: "eq", value: "live_mutation"},
        %{fact: "assignment.declared_files_present", op: "eq", value: false}
      ]
    }

    snapshot = Rules.effective_snapshot() |> Map.put(:policies, [policy])

    prepare = fn candidate ->
      DB.transaction(ctx.db, fn txn ->
        Rules.with_snapshot(snapshot, fn -> AttestEvidence.prepare_in_txn!(txn, candidate) end)
      end)
    end

    assert {:ok, %{validated_operational_evidence: %{artifact_id: artifact_id}}} = prepare.(call)
    assert artifact_id == captured.id

    missing = put_in(call, [:params, :artifact_id], nil)
    assert {:error, %Mementos.Refusal{code: "operational_evidence_invalid"}} = prepare.(missing)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignment_files(assignmentId,path) VALUES(?1,'notes/result.md')",
        [ctx.assignment_id]
      )

    overbroad_policy = %{
      policy
      | conditions: [%{fact: "assignment.effect_kind", op: "eq", value: "live_mutation"}]
    }

    overbroad = Map.put(snapshot, :policies, [overbroad_policy])

    assert {:error, %Mementos.Refusal{code: "non_file_operational_evidence_policy_inactive"}} =
             DB.transaction(ctx.db, fn txn ->
               Rules.with_snapshot(overbroad, fn -> AttestEvidence.prepare_in_txn!(txn, call) end)
             end)

    replacement = Map.put(overbroad, :active_admission_contract, %{"attest" => "replacement"})

    assert {:error, %Mementos.Refusal{code: "non_file_operational_evidence_policy_inactive"}} =
             DB.transaction(ctx.db, fn txn ->
               Rules.with_snapshot(replacement, fn ->
                 AttestEvidence.prepare_in_txn!(txn, call)
               end)
             end)

    file_policy = %{
      name: "file-evidence",
      purpose: "attest-file-effect-evidence",
      source: "test-policy",
      evidence_memento: "example/evidence",
      conditions: [%{fact: "assignment.declared_files_present", op: "eq", value: true}]
    }

    legacy_with_file_policy =
      overbroad
      |> Map.put(:revision, "revision")
      |> Map.put(:policies, [overbroad_policy, file_policy])
      |> Map.put(:declarations, %{
        revision: "revision",
        names: %{
          "example/evidence" => %{
            name: "evidence",
            qualified: "example/evidence",
            records: ["attest"],
            many: true
          }
        }
      })

    manifest_call =
      put_in(call, [:params, :mementos], [
        {"example/evidence", ["file-evidence/v1:#{captured.id}:#{captured.hash}"]}
      ])

    assert {:error, %Mementos.Refusal{code: "file_effect_evidence_policy_inactive"}} =
             DB.transaction(ctx.db, fn txn ->
               Rules.with_snapshot(legacy_with_file_policy, fn ->
                 AttestEvidence.prepare_in_txn!(txn, manifest_call)
               end)
             end)
  end

  test "replacement file selection derives the comparison from captured manifest bytes", ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignment_files(assignmentId,path) VALUES(?1,'notes/result.md')",
        [ctx.assignment_id]
      )

    before = capture(ctx, "old bytes")
    after_file = capture(ctx, "new bytes")
    observation = capture(ctx, "observed new bytes")
    manifest = capture(ctx, manifest(ctx, before, after_file, observation) |> JSON.encode!())
    pointer = "file-evidence/v1:#{manifest.id}:#{manifest.hash}"

    policy = %{
      name: "a-file",
      purpose: "attest-file-effect-evidence",
      source: "test-policy",
      evidence_memento: "example/evidence",
      conditions: [%{fact: "assignment.declared_files_present", op: "eq", value: true}]
    }

    other_policy = %{policy | name: "b-file", evidence_memento: "example/other"}

    snapshot =
      Rules.effective_snapshot()
      |> Map.put(:revision, "revision")
      |> Map.put(:policies, [other_policy, policy])
      |> Map.put(:active_admission_contract, %{"attest" => "replacement"})
      |> Map.put(:declarations, %{
        revision: "revision",
        names: %{
          "example/evidence" => %{
            name: "evidence",
            qualified: "example/evidence",
            records: ["attest"],
            many: true
          },
          "example/other" => %{
            name: "other",
            qualified: "example/other",
            records: ["attest"],
            many: true
          }
        }
      })

    call = %{
      verb: "attest",
      principal: {:session, ctx.holder},
      origin: ctx.holder,
      params: %{
        assignment_id: ctx.assignment_id,
        kind: "verdict",
        verdict_kind: "verified",
        artifact_id: manifest.id,
        content_sha256: manifest.hash,
        mementos: [{"example/evidence", [pointer, "observation:disk-only"]}]
      }
    }

    prepare = fn candidate, selected ->
      DB.transaction(ctx.db, fn txn ->
        Rules.with_snapshot(selected, fn -> AttestEvidence.prepare_in_txn!(txn, candidate) end)
      end)
    end

    assert {:ok, prepared} = prepare.(call, snapshot)
    assert prepared.file_effect_manifest.valid
    assert prepared.memento_comparison_value == pointer
    assert prepared.validated_file_effect.after.sha256 == after_file.hash

    wrong_name = put_in(call, [:params, :mementos], [{"example/other", [pointer]}])

    assert {:error, %Mementos.Refusal{code: "file_effect_evidence_invalid"}} =
             prepare.(wrong_name, snapshot)

    legacy = put_in(snapshot, [:active_admission_contract, "attest"], "legacy")

    assert {:error, %Mementos.Refusal{code: "file_effect_evidence_policy_inactive"}} =
             prepare.(call, legacy)
  end

  test "artifact presence alone cannot select operational evidence", ctx do
    assert Rules.active_admission_contract("attest") == "legacy"

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES(?1,'live_mutation')",
        [ctx.assignment_id]
      )

    captured = capture(ctx, "operation and observed result")

    call = %{
      verb: "attest",
      principal: {:session, ctx.holder},
      origin: ctx.holder,
      params: %{
        assignment_id: ctx.assignment_id,
        kind: "verdict",
        verdict_kind: "verified",
        artifact_id: captured.id,
        content_sha256: captured.hash
      }
    }

    assert {:error, %Mementos.Refusal{code: "non_file_operational_evidence_policy_inactive"}} =
             DB.transaction(ctx.db, fn txn -> AttestEvidence.prepare_in_txn!(txn, call) end)
  end

  test "legacy code remains outside operational evidence under an overbroad policy", ctx do
    captured = capture(ctx, "code operation and observed result")

    policy = %{
      name: "overbroad-operational",
      purpose: "attest-operational-evidence",
      source: "test-policy",
      conditions: [%{fact: "assignment.effect_kind", op: "eq", value: "code"}]
    }

    snapshot = Rules.effective_snapshot() |> Map.put(:policies, [policy])

    call = %{
      verb: "attest",
      principal: {:session, ctx.holder},
      origin: ctx.holder,
      params: %{
        assignment_id: ctx.assignment_id,
        kind: "verdict",
        verdict_kind: "verified",
        artifact_id: captured.id,
        content_sha256: captured.hash
      }
    }

    assert {:error, %Mementos.Refusal{code: "non_file_operational_evidence_policy_inactive"}} =
             DB.transaction(ctx.db, fn txn ->
               Rules.with_snapshot(snapshot, fn -> AttestEvidence.prepare_in_txn!(txn, call) end)
             end)
  end

  test "a lifecycle attest writes declared metadata with its attest row", ctx do
    snapshot =
      Rules.effective_snapshot()
      |> Map.put(:revision, "revision")
      |> Map.put(:declarations, %{
        revision: "revision",
        names: %{
          "example/progress" => %{
            name: "progress",
            qualified: "example/progress",
            records: ["attest"],
            many: false
          }
        }
      })

    call = %{
      verb: "attest",
      principal: {:session, ctx.holder},
      session_key: ctx.holder,
      origin: ctx.holder,
      rules_prechecked: true,
      params: %{
        assignment_id: ctx.assignment_id,
        kind: "progress",
        note: "Observed progress",
        mementos: [{"example/progress", ["observed"]}]
      }
    }

    file = fn candidate ->
      Rules.with_snapshot(snapshot, fn -> ctx.handlers["attest"].(candidate) end)
    end

    assert %{code: "unknown_memento"} =
             file.(put_in(call, [:params, :mementos], [{"example/missing", ["observed"]}]))

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM attests")

    assert %{attest: %{id: attest_id}} = file.(call)
    assert Mementos.current(ctx.db, "attest", attest_id, "example/progress") == ["observed"]
  end

  test "verified filing binds captured evidence and inline metadata in one transaction", ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES(?1,'live_mutation')",
        [ctx.assignment_id]
      )

    captured = capture(ctx, "original operation and result")

    policy = %{
      name: "operation-evidence",
      purpose: "attest-operational-evidence",
      source: "test-policy",
      conditions: [
        %{fact: "assignment.effect_kind", op: "eq", value: "live_mutation"},
        %{fact: "assignment.declared_files_present", op: "eq", value: false}
      ]
    }

    snapshot =
      Rules.effective_snapshot()
      |> Map.put(:revision, "revision")
      |> Map.put(:policies, [policy])
      |> Map.put(:declarations, %{
        revision: "revision",
        names: %{
          "example/evidence" => %{
            name: "evidence",
            qualified: "example/evidence",
            records: ["attest"],
            many: false
          }
        }
      })

    call = %{
      verb: "attest",
      principal: {:session, ctx.holder},
      session_key: ctx.holder,
      origin: ctx.holder,
      rules_prechecked: true,
      params: %{
        assignment_id: ctx.assignment_id,
        kind: "verdict",
        verdict_kind: "verified",
        note: "Captured operation verified",
        artifact_id: captured.id,
        content_sha256: captured.hash,
        mementos: [{"example/evidence", ["receipt:one"]}]
      }
    }

    file = fn candidate ->
      Rules.with_snapshot(snapshot, fn -> ctx.handlers["attest"].(candidate) end)
    end

    invalid = put_in(call, [:params, :content_sha256], String.duplicate("0", 64))
    assert %{code: "operational_evidence_invalid"} = file.(invalid)
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM attests")
    assert Mementos.current(ctx.db, "attest", "missing", "example/evidence") == []

    assert %{attest: filed} = file.(call)
    assert filed.artifactId == captured.id
    assert filed.contentSha256 == captured.hash

    assert {:ok, [[artifact_id, digest]]} =
             DB.query(ctx.db, "SELECT artifactId, contentSha256 FROM attests WHERE id=?1", [
               filed.id
             ])

    assert {artifact_id, digest} == {captured.id, captured.hash}

    assert [%{artifactId: ^artifact_id, contentSha256: ^digest}] =
             Tightbeam.Assignments.list_attests(ctx.db, ctx.assignment_id)

    assert Mementos.current(ctx.db, "attest", filed.id, "example/evidence") == ["receipt:one"]

    reviewer =
      Org.create(ctx.db, %{
        session_key: "agent:independent-reviewer",
        display_name: "Independent reviewer",
        owner_user_id: "owner",
        origin: "user:owner",
        spawned_by: Org.personal_session_key("owner"),
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })

    review_id = "asg_evidence_review"

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,workItemId,reviewsAssignmentId) VALUES(?1,'Review captured operation',?2,?3,1,?4,?5)",
        [
          review_id,
          reviewer.session_key,
          Org.personal_session_key("owner"),
          ctx.item_id,
          ctx.assignment_id
        ]
      )

    review_call = %{
      call
      | principal: {:session, reviewer.session_key},
        session_key: reviewer.session_key,
        origin: reviewer.session_key,
        params: %{
          assignment_id: review_id,
          kind: "verdict",
          verdict_kind: "reviewed-clean",
          note: "Read the captured result only",
          artifact_id: captured.id,
          content_sha256: captured.hash
        }
    }

    wrong_review = put_in(review_call, [:params, :content_sha256], String.duplicate("0", 64))
    assert %{code: "operational_evidence_invalid"} = file.(wrong_review)
    assert Tightbeam.Assignments.list_attests(ctx.db, review_id) == []
    assert %{attest: review} = file.(review_call)
    assert {review.artifactId, review.contentSha256} == {captured.id, captured.hash}
  end

  test "create, assign, and dispatch attach declared metadata only on creation", ctx do
    :ok = Mementos.ensure_schema(ctx.db)

    snapshot =
      Rules.effective_snapshot()
      |> Map.put(:revision, "revision")
      |> Map.put(:declarations, %{
        revision: "revision",
        names: %{
          "example/label" => %{
            name: "label",
            qualified: "example/label",
            records: ["work_item", "assignment"],
            many: false
          }
        }
      })

    handlers = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 1_000})
    execute = fn verb, call -> Rules.with_snapshot(snapshot, fn -> handlers[verb].(call) end) end

    item_call = %{
      principal: {:user, "owner"},
      origin: "user:owner",
      params: %{
        title: "Declared result",
        idempotency_key: "declared-result",
        mementos: [{"example/label", ["item-value"]}]
      }
    }

    item = execute.("work-item-create", item_call)
    assert Mementos.current(ctx.db, "work_item", item.id, "example/label") == ["item-value"]

    replay = put_in(item_call, [:params, :mementos], [{"example/label", ["different"]}])
    assert execute.("work-item-create", replay).id == item.id
    assert Mementos.current(ctx.db, "work_item", item.id, "example/label") == ["item-value"]

    common = %{
      principal: {:user, "owner"},
      origin: "user:owner",
      session_key: ctx.holder,
      target_role: nil,
      role_fallback: false
    }

    assign_call =
      Map.merge(common, %{
        params: %{
          subject: "Check recorded operation",
          work_item_id: item.id,
          idempotency_key: "declared-assignment",
          mementos: [{"example/label", ["assignment-value"]}]
        }
      })

    assignment = execute.("assign", assign_call)

    assert Mementos.current(ctx.db, "assignment", assignment.id, "example/label") == [
             "assignment-value"
           ]

    changed_assign = put_in(assign_call, [:params, :mementos], [{"example/label", ["new-value"]}])
    assert execute.("assign", changed_assign).id == assignment.id

    assert Mementos.current(ctx.db, "assignment", assignment.id, "example/label") == [
             "assignment-value"
           ]

    dispatched =
      execute.(
        "dispatch",
        Map.merge(common, %{
          params: %{
            subject: "Check dispatched operation",
            brief: "Inspect the recorded operation.",
            work_item_id: item.id,
            mementos: [{"example/label", ["dispatch-value"]}]
          }
        })
      )

    assert Mementos.current(ctx.db, "assignment", dispatched.id, "example/label") == [
             "dispatch-value"
           ]
  end

  defp capture(ctx, bytes) do
    params = %{
      kind: "report",
      title: "Captured evidence",
      origin_path: "/unavailable/evidence",
      work_item_id: ctx.item_id,
      produced_by_assignment_id: ctx.assignment_id
    }

    params =
      if is_binary(bytes),
        do: Map.put(params, :content_base64, Base.encode64(bytes)),
        else: params

    artifact =
      ctx.handlers["artifact-record"].(%{
        verb: "artifact-record",
        principal: {:session, ctx.holder},
        session_key: ctx.holder,
        origin: ctx.holder,
        params: params
      })

    refute Map.has_key?(artifact, :code)
    %{id: artifact.artifact_id, hash: artifact.content_sha256}
  end

  defp manifest(ctx, before, after_file, observation) do
    target = "device:/example/file"

    %{
      "schema" => "file-effect-evidence/v1",
      "assignmentId" => ctx.assignment_id,
      "target" => target,
      "before" => %{"target" => target, "artifactId" => before.id, "sha256" => before.hash},
      "after" => %{"target" => target, "artifactId" => after_file.id, "sha256" => after_file.hash},
      "observations" => [
        %{
          "scope" => "disk-bytes",
          "target" => target,
          "subject" => target,
          "resultIdentity" => after_file.hash,
          "artifactId" => observation.id,
          "sha256" => observation.hash
        }
      ]
    }
  end

  defp proof_call(ctx, manifest, pointer) do
    %{
      principal: {:session, ctx.holder},
      params: %{
        assignment_id: ctx.assignment_id,
        artifact_id: manifest.id,
        content_sha256: manifest.hash
      },
      memento_writes: [{"example/evidence", [pointer]}]
    }
  end
end
