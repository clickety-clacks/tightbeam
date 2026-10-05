defmodule Tightbeam.PublicWireFourVerbsTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    DB,
    Devices,
    Gateway,
    HarnessHealth,
    Model,
    Org,
    Roles,
    Schema
  }

  alias Tightbeam.Wire.Router

  @verbs [
    "assignment-commitref-correct",
    "harness-health-observe-other",
    "harness-health-resolve-other",
    "harness-health-close-promotion"
  ]

  setup do
    db = String.to_atom("public_wire_four_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    {:paired, device} =
      Devices.pair(db, %{
        device_id: "public-wire-device",
        claimed_name: "Public wire",
        platform: nil,
        model: nil
      })

    base_dir =
      Path.join(System.tmp_dir!(), "public-wire-four-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      device: device,
      base_dir: base_dir,
      opts: [
        db: db,
        base_dir: base_dir,
        cli_token: "tbc_public_wire",
        session_status: fn _ -> nil end
      ]
    }
  end

  test "the four documented verbs are admitted while unrelated internal handlers remain closed",
       ctx do
    handlers = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})

    agent_verbs =
      Router.__info__(:attributes)
      |> Keyword.fetch!(:agent_verbs)
      |> List.flatten()

    assert Enum.all?(@verbs, &(&1 in agent_verbs))
    assert Enum.all?(@verbs, &Map.has_key?(handlers, &1))
    assert "repair-assignment" in agent_verbs
    refute "post" in agent_verbs

    for verb <- @verbs do
      response =
        dispatch_cli(
          %{ctx | opts: real_opts(ctx)},
          "tbc_public_wire",
          %{verb: verb, asUser: ctx.device.user_id, sessionKey: "forbidden-target", params: %{}}
        )

      assert response.status == 400
      assert JSON.decode!(response.resp_body)["error"]["code"] == "invalid_message"
    end
  end

  test "assignment commit correction crosses the real wire with auth, target, and replay protection",
       ctx do
    owner = ctx.device.user_id
    caller = wire_session(ctx.db, "wire-commit-owner", owner, "product-owner")
    holder = wire_session(ctx.db, "wire-commit-holder", owner, "coder", caller.session_key)
    stranger = wire_session(ctx.db, "wire-commit-stranger", owner, "product-owner")
    caller_role = "coder:wire-commit-owner"
    stranger_role = "coder:wire-commit-stranger"
    Roles.create!(ctx.db, caller_role, owner, caller.session_key)
    Roles.create!(ctx.db, stranger_role, owner, stranger.session_key)

    {repo, remote, commit} = canonical_repo_fixture!()
    on_exit(fn -> File.rm_rf!(Path.dirname(repo)) end)

    :ok =
      DB.execute(ctx.db, """
      INSERT INTO work_items
        (id,title,ownerUserId,state,createdByUser,createdAt)
      VALUES ('wi_wire_commit','wire commit','#{owner}','open','#{owner}',1);

      INSERT INTO assignments
        (id,subject,holderKey,openedBySession,openedAt,state,outcome,closedAt,closedBySession,workItemId)
      VALUES ('asg_wire_commit','wire commit','#{holder.session_key}','#{caller.session_key}',2,
              'open',NULL,NULL,NULL,'wi_wire_commit');

      INSERT INTO attests (id,assignmentId,kind,bySession,ts)
      VALUES ('att_wire_commit_close','asg_wire_commit','completion','#{holder.session_key}',3);

      UPDATE assignments
      SET state='closed',outcome='completed',closedAt=3,
          closedBySession='#{holder.session_key}',closingAttestId='att_wire_commit_close'
      WHERE id='asg_wire_commit';

      INSERT INTO artifacts
        (artifactId,kind,title,createdBySession,workItemId,originPath,contentSha256,state,createdAt,updatedAt)
      VALUES ('art_wire_commit','report','wire proof','#{caller.session_key}','wi_wire_commit',
              '/proof/wire-commit.md','#{String.duplicate("a", 64)}','in-workspace',4,4);
      """)

    ctx = %{ctx | opts: real_opts(ctx)}

    params = %{
      assignmentId: "asg_wire_commit",
      commitRefs: [
        %{
          repo: "#{Tightbeam.Placement.local_host_name()}:#{repo}",
          remote: remote,
          ref: "refs/heads/main",
          commit: commit
        }
      ],
      evidenceArtifactId: "art_wire_commit",
      reason: "wire canonical correction",
      idempotencyKey: "wire-commit-1"
    }

    body = %{verb: "assignment-commitref-correct", as: caller_role, params: params}
    before = correction_count(ctx.db)

    unauthorized =
      dispatch_cli(ctx, stranger.cli_token, %{
        body
        | as: stranger_role,
          params: %{params | idempotencyKey: "wire-commit-stranger"}
      })

    assert unauthorized.status == 404
    assert JSON.decode!(unauthorized.resp_body)["error"]["code"] == "unknown_assignment"
    assert correction_count(ctx.db) == before

    wrong_target =
      dispatch_cli(ctx, caller.cli_token, %{
        body
        | params: %{
            params
            | assignmentId: "asg_wire_missing",
              idempotencyKey: "wire-commit-missing"
          }
      })

    assert wrong_target.status == 404
    assert JSON.decode!(wrong_target.resp_body)["error"]["code"] == "unknown_assignment"
    assert correction_count(ctx.db) == before

    accepted = dispatch_cli(ctx, caller.cli_token, body)
    assert accepted.status == 200, accepted.resp_body
    accepted_json = JSON.decode!(accepted.resp_body)
    assert accepted_json["result"]["correction"]["assignmentId"] == "asg_wire_commit"
    assert correction_count(ctx.db) == before + 1

    replay = dispatch_cli(ctx, caller.cli_token, body)
    assert replay.status == 200, replay.resp_body
    assert JSON.decode!(replay.resp_body)["result"] == accepted_json["result"]
    assert correction_count(ctx.db) == before + 1
  end

  test "observe and resolve other cross the real wire with target and idempotency boundaries",
       ctx do
    owner = ctx.device.user_id
    source = wire_session(ctx.db, "wire-health-source", owner, "coder")
    stranger = wire_session(ctx.db, "wire-health-stranger", owner, "coder")
    source_role = "coder:wire-health-source"
    stranger_role = "coder:wire-health-stranger"
    Roles.create!(ctx.db, source_role, owner, source.session_key)
    Roles.create!(ctx.db, stranger_role, owner, stranger.session_key)
    ctx = %{ctx | opts: real_opts(ctx)}

    at = System.system_time(:millisecond)

    observe_params = %{
      harness: "claude",
      host: "testhost",
      sourceSessionKey: source.session_key,
      description: "wire observed unclassified transport failure",
      evidenceMode: "exact_error",
      observedState: "provider connection unavailable",
      exactObservedError: "transport reset by peer",
      exactProbe: "provider health probe",
      recoveryCondition: "a normal provider turn completes",
      notKnownClassReason: "not authentication or quota",
      observedAt: at,
      validUntil: at + 60_000,
      worldStatus: "UNKNOWN",
      redactionConfirmed: true,
      idempotencyKey: "wire-health-observe-1"
    }

    observe_body = %{
      verb: "harness-health-observe-other",
      as: source_role,
      params: observe_params
    }

    opened = dispatch_cli(ctx, source.cli_token, observe_body)
    assert opened.status == 200, opened.resp_body
    opened_json = JSON.decode!(opened.resp_body)
    assert opened_json["result"]["status"] == "opened"
    incident_id = opened_json["result"]["incident"]["id"]
    assert other_incident_count(ctx.db) == 1

    repeated = dispatch_cli(ctx, source.cli_token, observe_body)
    assert repeated.status == 200, repeated.resp_body
    assert JSON.decode!(repeated.resp_body)["result"]["status"] == "duplicate"
    assert other_incident_count(ctx.db) == 1

    unauthorized =
      dispatch_cli(ctx, stranger.cli_token, %{
        observe_body
        | as: stranger_role,
          params: %{
            observe_params
            | sourceSessionKey: source.session_key,
              idempotencyKey: "wire-health-stranger"
          }
      })

    assert unauthorized.status == 403
    assert JSON.decode!(unauthorized.resp_body)["error"]["code"] == "not_authorized"
    assert other_incident_count(ctx.db) == 1

    wrong_target =
      dispatch_cli(ctx, source.cli_token, %{
        observe_body
        | params: %{
            observe_params
            | sourceSessionKey: stranger.session_key,
              idempotencyKey: "wire-health-target"
          }
      })

    assert wrong_target.status == 403
    assert JSON.decode!(wrong_target.resp_body)["error"]["code"] == "not_authorized"
    assert other_incident_count(ctx.db) == 1

    recovery_condition = "a normal provider turn completes"

    resolve_params = %{
      harness: "claude",
      host: "testhost",
      incidentId: incident_id,
      observedState: "normal provider turn completed",
      exactProbe: "provider health probe",
      outputDigest: String.duplicate("b", 64),
      recoveryConditionDigest: sha256(recovery_condition),
      cause: "wire recovery proof",
      recoverySatisfied: true,
      worldStatus: "PROVEN",
      redactionConfirmed: true,
      idempotencyKey: "wire-health-resolve-1"
    }

    resolve_body = %{
      verb: "harness-health-resolve-other",
      as: source_role,
      params: resolve_params
    }

    missing =
      dispatch_cli(ctx, source.cli_token, %{
        resolve_body
        | params: %{
            resolve_params
            | incidentId: "missing-incident",
              idempotencyKey: "wire-health-missing"
          }
      })

    assert missing.status == 403
    assert JSON.decode!(missing.resp_body)["error"]["code"] == "not_authorized"

    refused =
      dispatch_cli(ctx, stranger.cli_token, %{
        resolve_body
        | as: stranger_role,
          params: %{resolve_params | idempotencyKey: "wire-health-refused"}
      })

    assert refused.status == 403
    assert JSON.decode!(refused.resp_body)["error"]["code"] == "not_authorized"
    assert incident_state(ctx.db, incident_id) == "open"

    resolved = dispatch_cli(ctx, source.cli_token, resolve_body)
    assert resolved.status == 200, resolved.resp_body
    assert JSON.decode!(resolved.resp_body)["result"]["status"] == "resolved"
    assert incident_state(ctx.db, incident_id) == "resolved"

    resolve_replay = dispatch_cli(ctx, source.cli_token, resolve_body)
    assert resolve_replay.status == 403
    assert JSON.decode!(resolve_replay.resp_body)["error"]["code"] == "not_authorized"
    assert incident_state(ctx.db, incident_id) == "resolved"
  end

  test "promotion close crosses the real wire with provenance, auth, and replay protection",
       ctx do
    owner = ctx.device.user_id
    source = wire_session(ctx.db, "wire-promotion-source", owner, "coder")
    stranger = wire_session(ctx.db, "wire-promotion-stranger", owner, "coder")
    reviewer = wire_session(ctx.db, "wire-promotion-reviewer", owner, "coder")
    candidate_holder = wire_session(ctx.db, "wire-promotion-candidate", owner, "coder")
    source_role = "coder:wire-promotion-source"
    stranger_role = "coder:wire-promotion-stranger"
    Roles.create!(ctx.db, source_role, owner, source.session_key)
    Roles.create!(ctx.db, stranger_role, owner, stranger.session_key)

    at = System.system_time(:millisecond)

    common = %{
      harness: "claude",
      host: "testhost",
      source_session_key: source.session_key,
      principal: {:session, source.session_key},
      description: "wire recurring unclassified failure",
      evidence_mode: "exact_error",
      observed_state: "provider connection unavailable",
      exact_observed_error: "transport reset by peer",
      exact_probe: "provider health probe",
      recovery_condition: "a normal provider turn completes",
      not_known_class_reason: "not authentication or quota",
      world_status: "UNKNOWN",
      redaction_confirmed: true
    }

    assert {:opened, _first} =
             HarnessHealth.observe_other(
               ctx.db,
               Map.merge(common, %{
                 observed_at: at - 100,
                 accepted_at: at - 100,
                 valid_until: at - 1,
                 idempotency_key: "wire-promotion-first"
               })
             )

    assert {:opened, second} =
             HarnessHealth.observe_other(
               ctx.db,
               Map.merge(common, %{
                 observed_at: at,
                 accepted_at: at,
                 valid_until: at + 60_000,
                 idempotency_key: "wire-promotion-second"
               })
             )

    {:ok, [[promotion_id]]} =
      DB.query(
        ctx.db,
        "SELECT promotionCaseId FROM harness_health_other_reviews WHERE incidentId=?1",
        [second.id]
      )

    assert is_binary(promotion_id)

    assert {:ok, %{state: "closed", outcome: "promotion_required"}} =
             HarnessHealth.review_other(ctx.db, %{
               incident_id: second.id,
               outcome: "promotion_required",
               cause: "wire recurrence requires a named class",
               principal: {:session, source.session_key},
               idempotency_key: "wire-promotion-review"
             })

    work_item_id = "wi_wire_promotion"
    candidate_id = "asg_wire_promotion_candidate"
    review_id = "asg_wire_promotion_review"
    spec_id = "art_wire_promotion_spec"
    report_id = "art_wire_promotion_report"
    attest_id = "att_wire_promotion_review"
    spec_ref = "tightbeam-specs/wire-promotion.md"
    spec_sha = String.duplicate("c", 64)
    report_sha = String.duplicate("d", 64)
    candidate_commit = String.duplicate("e", 40)

    :ok =
      DB.execute(ctx.db, """
      INSERT INTO work_items
        (id,title,ownerUserId,state,createdByUser,createdAt,specRefName,specRefSha256)
      VALUES ('#{work_item_id}','wire promotion','#{owner}','open','#{owner}',1,'#{spec_ref}','#{spec_sha}');

      INSERT INTO assignments
        (id,subject,holderKey,openedBySession,openedAt,state,workItemId,reviewsAssignmentId)
      VALUES ('#{candidate_id}','candidate','#{candidate_holder.session_key}','#{source.session_key}',2,
              'open','#{work_item_id}',NULL);

      INSERT INTO assignments
        (id,subject,holderKey,openedBySession,openedAt,state,workItemId,reviewsAssignmentId)
      VALUES ('#{review_id}','review','#{reviewer.session_key}','#{source.session_key}',3,
              'open','#{work_item_id}','#{candidate_id}');

      INSERT INTO attests (id,assignmentId,kind,bySession,ts)
      VALUES ('att_wire_promotion_close','#{review_id}','completion','#{reviewer.session_key}',4);

      UPDATE assignments
      SET state='closed',outcome='completed',closedAt=4,
          closedBySession='#{reviewer.session_key}',closingAttestId='att_wire_promotion_close'
      WHERE id='#{review_id}';

      INSERT INTO artifacts
        (artifactId,kind,title,createdBySession,workItemId,originPath,contentSha256,state,createdAt,updatedAt)
      VALUES ('#{spec_id}','spec','wire spec','#{source.session_key}','#{work_item_id}',
              '#{spec_ref}','#{spec_sha}','in-workspace',4,4);

      INSERT INTO artifacts
        (artifactId,kind,title,createdBySession,workItemId,originPath,contentSha256,state,createdAt,updatedAt)
      VALUES ('#{report_id}','report','wire report','#{reviewer.session_key}','#{work_item_id}',
              '/reports/wire-promotion.md','#{report_sha}','in-workspace',4,4);
      """)

    commit_refs =
      JSON.encode!([%{"repo" => "testhost:/wire-promotion", "commit" => candidate_commit}])

    {:ok, []} =
      DB.query(
        ctx.db,
        """
        INSERT INTO attests
          (id,assignmentId,kind,verdictKind,bySession,byUser,commitRefs,artifactId,contentSha256,ts)
        VALUES (?1,?2,'verdict','reviewed-clean',?3,NULL,?4,?5,?6,?7)
        """,
        [attest_id, review_id, reviewer.session_key, commit_refs, report_id, report_sha, at]
      )

    ctx = %{ctx | opts: real_opts(ctx)}

    params = %{
      promotionId: promotion_id,
      namedClass: "provider-network-drift",
      specArtifactId: spec_id,
      reviewArtifactId: report_id,
      reviewAttestId: attest_id,
      reviewAssignmentId: review_id,
      candidateCommit: candidate_commit,
      idempotencyKey: "wire-promotion-close-1"
    }

    body = %{verb: "harness-health-close-promotion", as: source_role, params: params}

    unauthorized =
      dispatch_cli(ctx, stranger.cli_token, %{
        body
        | as: stranger_role,
          params: %{params | idempotencyKey: "wire-promotion-stranger"}
      })

    assert unauthorized.status == 403
    assert JSON.decode!(unauthorized.resp_body)["error"]["code"] == "not_authorized"
    assert promotion_state(ctx.db, promotion_id) == "open"

    missing =
      dispatch_cli(ctx, source.cli_token, %{
        body
        | params: %{
            params
            | promotionId: "promotion-missing",
              idempotencyKey: "wire-promotion-missing"
          }
      })

    assert missing.status == 400
    assert JSON.decode!(missing.resp_body)["error"]["code"] == "promotion_not_found"
    assert promotion_state(ctx.db, promotion_id) == "open"

    closed = dispatch_cli(ctx, source.cli_token, body)
    assert closed.status == 200, closed.resp_body
    assert JSON.decode!(closed.resp_body)["result"]["promotion"]["state"] == "closed"

    replay = dispatch_cli(ctx, source.cli_token, body)
    assert replay.status == 200, replay.resp_body
    assert JSON.decode!(replay.resp_body)["result"]["promotion"]["state"] == "closed"
    assert promotion_state(ctx.db, promotion_id) == "closed"
  end

  defp real_opts(ctx),
    do: Keyword.put(ctx.opts, :handlers, Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir}))

  defp dispatch_cli(ctx, bearer, body) do
    conn(:post, "/agent/dispatch", JSON.encode!(Map.put_new(body, :params, %{})))
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Router.call(Router.init(ctx.opts))
  end

  defp wire_session(db, key, owner, archetype, spawned_by \\ nil) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      spawned_by: spawned_by,
      archetype: archetype,
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5"),
      kind: "custom"
    })
  end

  defp canonical_repo_fixture! do
    root =
      Path.join(System.tmp_dir!(), "public-wire-commitref-#{System.unique_integer([:positive])}")

    repo = Path.join(root, "repo")
    remote = Path.join(root, "remote.git")
    File.mkdir_p!(root)
    git!(root, ["init", "--bare", remote])
    git!(root, ["init", "-b", "main", repo])
    git!(repo, ["config", "user.email", "test@example.invalid"])
    git!(repo, ["config", "user.name", "Public wire test"])
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

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp correction_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM assignment_commit_ref_corrections")
    count
  end

  defp other_incident_count(db) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(*) FROM harness_health_incidents WHERE failureClass='other'")

    count
  end

  defp incident_state(db, id) do
    {:ok, [[state]]} =
      DB.query(db, "SELECT state FROM harness_health_incidents WHERE id=?1", [id])

    state
  end

  defp promotion_state(db, id) do
    {:ok, [[state]]} =
      DB.query(db, "SELECT state FROM harness_health_class_promotions WHERE id=?1", [id])

    state
  end
end
