defmodule Tightbeam.SessionLifecycleTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, HarnessHealth, Ledger, Model, Org, Schema, SessionLifecycle, Wakes}

  setup do
    db = :"session_lifecycle_db_#{System.unique_integer([:positive])}"

    db_path =
      Path.join(
        System.tmp_dir!(),
        "session-lifecycle-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({DB, path: db_path, name: db})
    :ok = Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('owner',0,'admin_add',1),('other',0,'admin_add',1),('admin',1,'admin_add',1)"
      )

    main = ensure_main_session(db, "owner")

    session =
      Org.create(db, %{
        session_key: "park-target",
        display_name: "Park target",
        owner_user_id: "owner",
        origin: "user:owner",
        spawned_by: main.session_key,
        operational_parent: main.session_key,
        archetype: "default",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable"),
        host: "gibson"
      })

    workdir = Path.join(System.tmp_dir!(), "park-custody-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, "dirty.txt"), "preserve me")

    on_exit(fn ->
      File.rm_rf!(workdir)
      File.rm(db_path)
    end)

    %{db: db, db_path: db_path, session: session, workdir: workdir}
  end

  test "accepted PARK closes once, replays idempotently, and relaunches the same session", ctx do
    :ok =
      DB.execute(
        ctx.db,
        """
        INSERT INTO roles (name,boundSessionKey,ownerUserId,createdAt,updatedAt)
        VALUES ('park-owner-role','park-target','owner',1,1);
        INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdAt)
        VALUES ('wi_park_continuity','Park continuity','owner','open','owner',1);
        INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,workItemId)
        VALUES ('asg_park_continuity','Preserve me','park-target','owner',1,'wi_park_continuity');
        """
      )

    {:ok, turn_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.session.session_key,
        message_id: "queued-before-park",
        origin: "user:owner",
        prompt: "preserve this turn"
      })

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.session.session_key,
        origin: "user:owner",
        prompt: "preserve this wake",
        due_at: System.system_time(:millisecond) + 60_000
      })

    attrs = %{
      session_key: ctx.session.session_key,
      principal: {:user, "owner"},
      idempotency_key: "park-once",
      workspace_path: ctx.workdir,
      cause_kind: "manual",
      cause_id: "park-once"
    }

    accepted = SessionLifecycle.request(ctx.db, attrs)
    assert accepted.outcome.status == "open"
    assert Org.get(ctx.db, ctx.session.session_key).state == "parking"
    assert Ledger.claim_next(ctx.db, ctx.session.session_key, "test") == :none

    parked = SessionLifecycle.settle(ctx.db, accepted.request_id, fn _ -> :ok end)
    assert parked.outcome.status == "parked"
    assert parked.outcome.resulting_lifecycle_state == "parked"
    assert parked.outcome.queued_turn_seqs == [turn_seq]
    assert parked.outcome.pending_wake_ids == [wake.wake_id]
    assert parked.outcome.workspace_path == ctx.workdir
    assert parked.outcome.role_bindings == ["park-owner-role"]

    assert parked.outcome.assignment_links == [
             %{"assignmentId" => "asg_park_continuity", "workItemId" => "wi_park_continuity"}
           ]

    assert parked.outcome.work_item_links == ["wi_park_continuity"]
    assert File.read!(Path.join(ctx.workdir, "dirty.txt")) == "preserve me"

    assert SessionLifecycle.read(ctx.db, accepted.request_id, {:user, "owner"}).request_id ==
             accepted.request_id

    assert SessionLifecycle.read(ctx.db, accepted.request_id, {:user, "other"}) == %{
             code: "not_found"
           }

    assert {:ok, [[2, 1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*),sum(admitted) FROM park_read_audits WHERE requestId=?1",
               [accepted.request_id]
             )

    old_db = Process.whereis(ctx.db)
    Process.exit(old_db, :kill)

    assert eventually(fn ->
             case Process.whereis(ctx.db) do
               pid when is_pid(pid) -> pid != old_db
               nil -> false
             end
           end)

    replay = SessionLifecycle.request(ctx.db, attrs)
    assert replay.request_id == accepted.request_id
    assert replay.replay
    assert replay.outcome.status == "parked"

    assert %{ok: true, sessionKey: "park-target", state: "active"} =
             SessionLifecycle.relaunch(ctx.db, "park-target", {:user, "owner"})

    assert Org.get(ctx.db, "park-target").session_key == accepted.session_key
    assert Org.get(ctx.db, "park-target").state == "active"

    assert {:ok, [["park-target", "open"]]} =
             DB.query(
               ctx.db,
               "SELECT holderKey,state FROM assignments WHERE id='asg_park_continuity'"
             )

    assert {:ok, [["park-target"]]} =
             DB.query(
               ctx.db,
               "SELECT boundSessionKey FROM roles WHERE name='park-owner-role'"
             )

    assert {:error, %{message: message}} =
             DB.query(ctx.db, "UPDATE park_outcomes SET status='open' WHERE requestId=?1", [
               accepted.request_id
             ])

    assert message =~ "closed park outcome is immutable"
  end

  test "refusal is durable without an outcome and a failed request retries causally", ctx do
    assert %{code: "not_authorized", refusal_id: refusal_id} =
             SessionLifecycle.request(ctx.db, %{
               session_key: ctx.session.session_key,
               principal: {:user, "other"},
               idempotency_key: "not-yours",
               workspace_path: ctx.workdir
             })

    assert is_binary(refusal_id)
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM park_outcomes")

    first =
      SessionLifecycle.request(ctx.db, %{
        session_key: ctx.session.session_key,
        principal: {:user, "owner"},
        idempotency_key: "fails",
        workspace_path: ctx.workdir
      })

    failed = SessionLifecycle.settle(ctx.db, first.request_id, fn _ -> {:error, :adapter} end)
    assert failed.outcome.status == "park_failed"
    assert failed.outcome.resulting_lifecycle_state == "active"

    retry =
      SessionLifecycle.request(ctx.db, %{
        session_key: ctx.session.session_key,
        principal: {:user, "owner"},
        idempotency_key: "retry",
        cause_kind: "retry",
        cause_id: first.request_id,
        retry_of_request_id: first.request_id,
        workspace_path: ctx.workdir
      })

    refute retry.request_id == first.request_id

    assert SessionLifecycle.settle(ctx.db, retry.request_id, fn _ -> :ok end).outcome.status ==
             "parked"

    assert SessionLifecycle.get(ctx.db, first.request_id).retry_request_ids == [retry.request_id]
  end

  test "an owner causally retries the exact unknown-liveness fence before relaunch", ctx do
    first =
      SessionLifecycle.request(ctx.db, %{
        session_key: ctx.session.session_key,
        principal: {:user, "owner"},
        idempotency_key: "unknown-runtime",
        workspace_path: ctx.workdir
      })

    failed =
      SessionLifecycle.settle(ctx.db, first.request_id, fn _ ->
        {:error, :runtime_liveness_unknown}
      end)

    assert failed.outcome.status == "park_failed"
    assert failed.outcome.resulting_lifecycle_state == "parking"
    assert failed.outcome.recovery_state == "fenced_unknown_liveness"

    retry =
      SessionLifecycle.request(ctx.db, %{
        session_key: ctx.session.session_key,
        principal: {:user, "owner"},
        idempotency_key: "runtime-resolved",
        cause_kind: "retry",
        cause_id: first.request_id,
        retry_of_request_id: first.request_id,
        workspace_path: ctx.workdir
      })

    refute retry.request_id == first.request_id
    assert retry.outcome.status == "open"
    assert retry.cause.retry_of_request_id == first.request_id

    parked = SessionLifecycle.settle(ctx.db, retry.request_id, fn _ -> :ok end)
    assert parked.outcome.status == "parked"

    assert %{ok: true, sessionKey: session_key, state: "active"} =
             SessionLifecycle.relaunch(ctx.db, ctx.session.session_key, {:user, "owner"})

    assert session_key == ctx.session.session_key
    assert SessionLifecycle.get(ctx.db, first.request_id).retry_request_ids == [retry.request_id]
  end

  test "a fenced unknown-liveness retry requires its exact request and an outside owner", ctx do
    first =
      SessionLifecycle.request(ctx.db, %{
        session_key: ctx.session.session_key,
        principal: {:user, "owner"},
        idempotency_key: "unknown-runtime-refusals",
        workspace_path: ctx.workdir
      })

    SessionLifecycle.settle(ctx.db, first.request_id, fn _ ->
      {:error, :runtime_liveness_unknown}
    end)

    assert %{code: "lifecycle_contended"} =
             SessionLifecycle.request(ctx.db, %{
               session_key: ctx.session.session_key,
               principal: {:session, ctx.session.session_key},
               idempotency_key: "self-cannot-recover",
               cause_kind: "retry",
               cause_id: first.request_id,
               retry_of_request_id: first.request_id,
               workspace_path: ctx.workdir
             })

    assert %{code: "invalid_retry"} =
             SessionLifecycle.request(ctx.db, %{
               session_key: ctx.session.session_key,
               principal: {:user, "owner"},
               idempotency_key: "wrong-fence",
               cause_kind: "retry",
               cause_id: "pr_not_the_fence",
               retry_of_request_id: "pr_not_the_fence",
               workspace_path: ctx.workdir
             })

    assert SessionLifecycle.get(ctx.db, first.request_id).outcome.recovery_state ==
             "fenced_unknown_liveness"
  end

  test "retirement wins one accepted PARK race through its existing outcome", ctx do
    request =
      SessionLifecycle.request(ctx.db, %{
        session_key: ctx.session.session_key,
        principal: {:user, "owner"},
        idempotency_key: "retire-race",
        workspace_path: ctx.workdir
      })

    Org.retire(ctx.db, ctx.session.session_key, "user:owner", 1_000)
    closed = SessionLifecycle.get(ctx.db, request.request_id)
    assert closed.outcome.status == "park_failed"
    assert closed.outcome.resulting_lifecycle_state == "retired"
    assert closed.outcome.failure_code == "superseded_by_retire"
    assert Org.get(ctx.db, ctx.session.session_key).state == "retired"
  end

  test "retirement after PARK is terminal without rewriting the immutable outcome", ctx do
    request =
      SessionLifecycle.request(ctx.db, %{
        session_key: ctx.session.session_key,
        principal: {:user, "owner"},
        idempotency_key: "retire-after-park",
        workspace_path: ctx.workdir
      })

    assert SessionLifecycle.settle(ctx.db, request.request_id, fn _ -> :ok end).outcome.status ==
             "parked"

    Org.retire(ctx.db, ctx.session.session_key, "user:owner", 1_000)

    assert {:ok, [["retired"]]} =
             DB.query(
               ctx.db,
               "SELECT state FROM session_lifecycle_states WHERE sessionKey=?1",
               [ctx.session.session_key]
             )

    assert SessionLifecycle.get(ctx.db, request.request_id).outcome.status == "parked"

    assert SessionLifecycle.relaunch(ctx.db, ctx.session.session_key, {:user, "owner"}) == %{
             code: "session_not_parked"
           }
  end

  test "harness health PARK copies one exact durable decision into one request", ctx do
    assert {:opened, incident} =
             HarnessHealth.observe(ctx.db, %{
               harness: "claude",
               host: "gibson",
               failure_class: "adapter_unavailable",
               evidence_kind: "authoritative-provider",
               session_key: ctx.session.session_key,
               assignment_id: nil,
               observed_at: 10,
               correlation_id: "park-health-decision",
               cause: "adapter transport is unavailable",
               principal: "process:tightbeam"
             })

    assert %{code: "not_authorized"} =
             SessionLifecycle.request(ctx.db, %{
               session_key: ctx.session.session_key,
               principal: {:process, "tightbeam:harness-health"},
               authority_basis: "harness_health_recovery",
               idempotency_key: "forged-health-park",
               cause_kind: "harness_health_recovery",
               cause_id: "not-a-decision",
               workspace_path: ctx.workdir
             })

    assert %{code: "not_authorized"} =
             HarnessHealth.request_session_park(ctx.db, %{
               incident_id: incident.id,
               session_key: ctx.session.session_key,
               idempotency_key: "unbound-immediate-health-park",
               mode: "immediate",
               workspace_path: ctx.workdir
             })

    accepted =
      HarnessHealth.request_session_park(ctx.db, %{
        incident_id: incident.id,
        session_key: ctx.session.session_key,
        idempotency_key: "bound-health-park",
        workspace_path: ctx.workdir
      })

    assert accepted.authority_basis == "harness_health_recovery"
    assert accepted.policy_basis == "harness_health_incident"
    assert accepted.evidence.kind == "harness_health_observation"
    assert accepted.mode == "graceful"
    assert accepted.outcome.status == "open"

    assert {:ok, [[decision_id, "session", "park", "graceful", "shared_harness_incident_hold"]]} =
             DB.query(
               ctx.db,
               "SELECT decisionId,targetKind,action,mode,policyBasis FROM harness_health_recovery_decisions WHERE incidentId=?1 AND sessionKey=?2",
               [incident.id, ctx.session.session_key]
             )

    assert accepted.cause.id == decision_id

    replay =
      HarnessHealth.request_session_park(ctx.db, %{
        incident_id: incident.id,
        session_key: ctx.session.session_key,
        idempotency_key: "bound-health-park",
        workspace_path: ctx.workdir
      })

    assert replay.request_id == accepted.request_id
    assert replay.replay
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM park_requests")
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(fun, 0), do: fun.()
end
