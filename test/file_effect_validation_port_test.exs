defmodule Tightbeam.FileEffectValidationPortTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    ArtifactContent,
    DB,
    Gateway,
    Mementos,
    Model,
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

  test "verified accepts no refs while supplied artifact hashes remain binding", ctx do
    call = %{
      verb: "attest", principal: {:session, ctx.holder}, session_key: ctx.holder,
      origin: ctx.holder,
      params: %{assignment_id: ctx.assignment_id, kind: "verdict", verdict_kind: "verified"}
    }
    assert %{attest: %{commitRefs: nil}} = ctx.handlers["attest"].(call)
    assert %{attest: %{commitRefs: []}} = ctx.handlers["attest"].(put_in(call, [:params, :commit_refs], []))

    captured = capture(ctx, "captured result")
    cited = call |> put_in([:params, :artifact_id], captured.id)
      |> put_in([:params, :content_sha256], captured.hash)
    assert %{attest: %{artifactId: id, contentSha256: hash}} = ctx.handlers["attest"].(cited)
    assert {id, hash} == {captured.id, captured.hash}
    assert %{code: "invalid_revision_binding"} =
      ctx.handlers["attest"].(put_in(cited, [:params, :content_sha256], String.duplicate("f", 64)))
    assert {:ok, [[3]]} = DB.query(ctx.db, "SELECT count(*) FROM attests")
  end

  test "verified filing binds captured evidence and inline metadata in one transaction", ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES(?1,'live_mutation')",
        [ctx.assignment_id]
      )

    captured = capture(ctx, "original operation and result")

    snapshot =
      Rules.effective_snapshot()
      |> Map.put(:revision, "revision")
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

    assert is_nil(call.params[:commit_refs])

    file = fn candidate ->
      Rules.with_snapshot(snapshot, fn -> ctx.handlers["attest"].(candidate) end)
    end

    invalid = put_in(call, [:params, :content_sha256], String.duplicate("0", 64))
    assert %{code: "invalid_revision_binding"} = file.(invalid)
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM attests")
    assert Mementos.current(ctx.db, "attest", "missing", "example/evidence") == []

    assert %{attest: filed} = file.(call)
    assert filed.artifactId == captured.id
    assert filed.contentSha256 == captured.hash
    assert filed.commitRefs == nil

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
    assert %{code: "invalid_revision_binding"} = file.(wrong_review)
    assert Tightbeam.Assignments.list_attests(ctx.db, review_id) == []
    assert %{attest: review} = file.(review_call)
    assert {review.artifactId, review.contentSha256} == {captured.id, captured.hash}
  end

  test "artifact producer policy can be removed while owner visibility remains", ctx do
    root = Path.join(System.tmp_dir!(), "artifact-policy-#{System.unique_integer([:positive])}")
    dir = Path.join(root, "identity/rules")
    File.mkdir_p!(dir)
    File.write!(
      Path.join(dir, "placement.toml"),
      Tightbeam.TerminalReactionFixture.attest_placement()
    )
    Rules.load!(root, Map.keys(ctx.handlers))
    on_exit(fn -> File.rm_rf!(root); :persistent_term.erase(Rules) end)

    unproduced = capture(%{ctx | assignment_id: nil}, "same-item artifact without producer")
    call = %{
      verb: "attest", principal: {:session, ctx.holder}, session_key: ctx.holder, origin: ctx.holder,
      params: %{assignment_id: ctx.assignment_id, kind: "verdict", verdict_kind: "topology-decided",
        artifact_id: unproduced.id, content_sha256: unproduced.hash}
    }
    assert {:error, %{code: "rule_denied", rule: "artifact-citation-requires-own-producer"}} =
      Tightbeam.Dispatch.dispatch(ctx.db, ctx.handlers, call)
    File.rm!(Path.join(dir, "placement.toml"))
    Rules.load!(root, Map.keys(ctx.handlers))
    assert {:ok, %{attest: %{verdictKind: "topology-decided"}}} =
      Tightbeam.Dispatch.dispatch(ctx.db, ctx.handlers, call)

    other_item = ctx.handlers["work-item-create"].(%{principal: {:user, "owner"}, origin: "user:owner",
      params: %{title: "Other item"}})
    foreign = capture(%{ctx | item_id: other_item.id, assignment_id: nil}, "other item artifact")
    foreign_call =
      call
      |> put_in([:params, :artifact_id], foreign.id)
      |> put_in([:params, :content_sha256], foreign.hash)

    assert {:ok, %{attest: %{verdictKind: "topology-decided"}}} =
             Tightbeam.Dispatch.dispatch(ctx.db, ctx.handlers, foreign_call)
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

end
