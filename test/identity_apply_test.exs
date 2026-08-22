defmodule Tightbeam.IdentityApplyTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Identity, IdentityApply, Ledger, Model, Org, Projection}

  defmodule RuntimeStub do
    alias Tightbeam.{IdentityApply, Org}

    def snapshot(_config, db, session_key) do
      session = Org.get(db, session_key)
      pointer = Org.current_pointer(db, session_key)

      {:ok,
       %{
         "contextId" => pointer && pointer.harness_session_id,
         "identityRevision" => session.identity_revision,
         "sessionIncarnation" =>
           if(pointer,
             do: "pointer:#{pointer.source_session_ref}",
             else: "unstarted:#{session.created_at}"
           ),
         "adapterGeneration" => 1,
         "resident" => not is_nil(pointer),
         "runnable" => true
       }}
    end

    def status(_config, db, effect_id) do
      case IdentityApply.effect(db, effect_id) do
        %{state: "not-started"} -> :not_started
        %{state: "in-progress"} -> :in_progress
        %{state: "succeeded", receipt: receipt} -> {:succeeded, receipt}
        %{state: "failed", receipt: receipt} -> {:failed, receipt}
      end
    end

    def invoke(_config, db, effect_id) do
      :started = IdentityApply.start_effect(db, effect_id)
      effect = IdentityApply.effect(db, effect_id)

      receipt = %{
        "state" => "succeeded",
        "targetContextId" => "ctx-#{effect.session_key}",
        "targetRevision" => effect.request["targetRevision"],
        "pointerReason" => "created",
        "runnable" => true
      }

      {:succeeded, IdentityApply.finish_effect(db, effect_id, receipt)}
    end
  end

  defmodule SnapshotSequenceStub do
    def snapshot(config, _db, _session_key) do
      Agent.get_and_update(config.snapshot_sequence, fn [next | rest] -> {{:ok, next}, rest} end)
    end

    defdelegate status(config, db, effect_id), to: RuntimeStub
    defdelegate invoke(config, db, effect_id), to: RuntimeStub
  end

  defmodule SafeFailureRuntimeStub do
    defdelegate snapshot(config, db, session_key), to: RuntimeStub
    defdelegate status(config, db, effect_id), to: RuntimeStub

    def invoke(_config, db, effect_id) do
      :started = Tightbeam.IdentityApply.start_effect(db, effect_id)
      effect = Tightbeam.IdentityApply.effect(db, effect_id)

      receipt =
        case effect.phase do
          "runner-stop" ->
            %{"state" => "succeeded", "result" => "stopped"}

          "reload" ->
            prior = effect.request["priorContext"] || effect.request["prior_context"]

            %{
              "state" => "failed",
              "class" => %{"effectDisposition" => "terminal", "name" => "controlled"},
              "priorContextId" => prior["contextId"],
              "priorRevision" => prior["identityRevision"],
              "runnable" => true
            }
        end

      receipt = Tightbeam.IdentityApply.finish_effect(db, effect_id, receipt)

      case receipt["state"] do
        "succeeded" -> {:succeeded, receipt}
        "failed" -> {:failed, receipt}
      end
    end
  end

  defmodule StatusOnlyRecoveryRuntimeStub do
    defdelegate snapshot(config, db, session_key), to: RuntimeStub

    def status(config, db, effect_id) do
      if Agent.get(config.recovery_control, & &1.force_not_started) do
        :not_started
      else
        RuntimeStub.status(config, db, effect_id)
      end
    end

    def invoke(config, db, effect_id) do
      Agent.update(
        config.recovery_control,
        &Map.update!(&1, :invocations, fn count -> count + 1 end)
      )

      :started = Tightbeam.IdentityApply.start_effect(db, effect_id)

      receipt = %{
        "state" => "failed",
        "class" => %{"effectDisposition" => "retryable", "name" => "transport"},
        "priorContextId" => "wrong-context",
        "priorRevision" => "wrong-revision",
        "runnable" => false
      }

      {:failed, Tightbeam.IdentityApply.finish_effect(db, effect_id, receipt)}
    end
  end

  defmodule NoopLaneManager do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
    def init(nil), do: {:ok, nil}
    def handle_call({:ensure_lane, _session_key}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    db = :"identity_apply_db_#{System.unique_integer([:positive])}"
    task_sup = :"identity_apply_tasks_#{System.unique_integer([:positive])}"
    conn_registry = :"identity_apply_conn_#{System.unique_integer([:positive])}"
    lane_manager = :"identity_apply_lane_manager_#{System.unique_integer([:positive])}"

    base_dir =
      Path.join(System.tmp_dir!(), "identity-apply-#{System.unique_integer([:positive])}")

    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)
    start_supervised!({Task.Supervisor, name: task_sup})

    start_supervised!(%{
      id: Tightbeam.IdentityApply.FenceNotifications,
      start: {:pg, :start_link, [Tightbeam.IdentityApply.FenceNotifications]}
    })

    start_supervised!({Tightbeam.ConnRegistry, name: conn_registry})
    start_supervised!({NoopLaneManager, lane_manager})
    :initialized = Identity.init!(base_dir)
    revision = Identity.live_revision!(base_dir)

    session =
      Org.create(db, %{
        session_key: "agent:identity-apply:test",
        display_name: "Identity apply test",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        identity_name: "default",
        identity_revision: revision,
        host: "local",
        harness: "codex",
        provider: "openai",
        model: Model.new("gpt-5.6-sol", effort: "medium")
      })

    next =
      Identity.edit!(
        base_dir,
        "default",
        :guidance,
        "Identity apply target guidance.",
        "test"
      )

    config = %{
      base_dir: base_dir,
      db: db,
      identity_apply_runtime_adapter: RuntimeStub,
      turn_task_sup: task_sup,
      conn_registry: conn_registry,
      lane_manager: lane_manager
    }

    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{db: db, base_dir: base_dir, prior: revision, target: next, session: session, config: config}
  end

  test "keyed acceptance fences claims, applies one frozen revision, and replays", ctx do
    selector = %{kind: "session", session_key: ctx.session.session_key}

    assert {:ok, operation_id, :new} =
             IdentityApply.accept(
               ctx.db,
               ctx.base_dir,
               selector,
               "user:flynn",
               idempotency_key: "stable-key"
             )

    assert IdentityApply.fenced?(ctx.db, ctx.session.session_key)

    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: ctx.session.session_key,
               message_id: "queued-before-apply",
               origin: "user:flynn",
               prompt: "wait behind the fence"
             })

    assert :none = Ledger.claim_next(ctx.db, ctx.session.session_key, "lane")

    result =
      Tightbeam.IdentityApply.Executor.start_operation(ctx.config, ctx.db, operation_id)

    assert result.state == "completed"
    assert result.outcome == "succeeded"
    assert result.operation_id == operation_id
    assert result.idempotency_key == "stable-key"
    assert result.identity_revision == ctx.target
    assert result.applied == [ctx.session.session_key]
    assert result.failed == []
    refute IdentityApply.fenced?(ctx.db, ctx.session.session_key)
    assert Org.get(ctx.db, ctx.session.session_key).identity_revision == ctx.target

    messages = Projection.list_after(ctx.db, ctx.session.session_key, nil, 10)
    assert [continuation] = messages
    assert continuation.sender == "process:tightbeam"
    assert continuation.content == IdentityApply.continuation_prompt(operation_id)

    assert {:ok, ^operation_id, :replay} =
             IdentityApply.accept(
               ctx.db,
               ctx.base_dir,
               selector,
               "user:flynn",
               idempotency_key: "stable-key"
             )

    assert length(Projection.list_after(ctx.db, ctx.session.session_key, nil, 10)) == 1

    assert {:error, %{code: "idempotency_conflict"}} =
             IdentityApply.accept(
               ctx.db,
               ctx.base_dir,
               %{kind: "all", session_key: nil},
               "user:flynn",
               idempotency_key: "stable-key"
             )
  end

  test "boot adoption transfers operation, outcome, and fence to one epoch", ctx do
    assert {:ok, operation_id, :new} =
             IdentityApply.accept(
               ctx.db,
               ctx.base_dir,
               %{kind: "session", session_key: ctx.session.session_key},
               "user:flynn",
               idempotency_key: "adopt-key"
             )

    assert [^operation_id] = IdentityApply.adopt_all!(ctx.db)

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT executionOwnerEpoch FROM identity_apply_operations WHERE operationId=?1",
               [operation_id]
             )

    {:ok, [[outcome_epoch]]} =
      DB.query(
        ctx.db,
        "SELECT executionOwnerEpoch FROM identity_apply_outcomes WHERE operationId=?1",
        [operation_id]
      )

    {:ok, [[fence_epoch]]} =
      DB.query(
        ctx.db,
        "SELECT executionOwnerEpoch FROM identity_apply_fences WHERE operationId=?1",
        [operation_id]
      )

    assert outcome_epoch == 2
    assert fence_epoch == 2
  end

  test "a blocked operation appends a new outcome only after the prior fence releases", ctx do
    selector = %{kind: "session", session_key: ctx.session.session_key}

    assert {:ok, first_id, :new} =
             IdentityApply.accept(
               ctx.db,
               ctx.base_dir,
               selector,
               "user:flynn",
               idempotency_key: "first-owner"
             )

    assert {:ok, second_id, :new} =
             IdentityApply.accept(
               ctx.db,
               ctx.base_dir,
               selector,
               "user:flynn",
               idempotency_key: "blocked-owner"
             )

    blocked = IdentityApply.operation(ctx.db, second_id)
    assert blocked.state == "completed"
    assert blocked.outcome == "failed"
    assert hd(blocked.sessions).error.code == "apply_in_progress"

    first = Tightbeam.IdentityApply.Executor.start_operation(ctx.config, ctx.db, first_id)
    assert first.outcome == "succeeded"

    assert {:ok, ^second_id, :retry} =
             IdentityApply.accept(
               ctx.db,
               ctx.base_dir,
               selector,
               "user:flynn",
               idempotency_key: "blocked-owner"
             )

    retried = Tightbeam.IdentityApply.Executor.start_operation(ctx.config, ctx.db, second_id)
    assert retried.outcome == "succeeded"
    assert hd(retried.sessions).attempts == 2

    {:ok, rows} =
      DB.query(
        ctx.db,
        "SELECT attempt, phase, errorCode FROM identity_apply_outcomes WHERE operationId=?1 ORDER BY attempt",
        [second_id]
      )

    assert rows == [[1, "failed", "apply_in_progress"], [2, "succeeded", nil]]
  end

  test "one stale snapshot is discarded before any effect and the second snapshot applies", ctx do
    current = "unstarted:#{ctx.session.created_at}"

    {:ok, sequence} =
      Agent.start_link(fn ->
        [
          snapshot(ctx, "unstarted:stale", 4),
          snapshot(ctx, current, 4)
        ]
      end)

    config =
      ctx.config
      |> Map.put(:identity_apply_runtime_adapter, SnapshotSequenceStub)
      |> Map.put(:snapshot_sequence, sequence)

    {:ok, operation_id, :new} =
      IdentityApply.accept(
        ctx.db,
        ctx.base_dir,
        %{kind: "session", session_key: ctx.session.session_key},
        "user:flynn",
        idempotency_key: "snapshot-retry"
      )

    assert %{outcome: "succeeded"} =
             Tightbeam.IdentityApply.Executor.start_operation(config, ctx.db, operation_id)

    assert {:ok, [[2, 1, 4]]} =
             DB.query(
               ctx.db,
               "SELECT snapshotAttempt, generationRetryCount, expectedAdapterGeneration FROM identity_apply_outcomes WHERE operationId=?1",
               [operation_id]
             )
  end

  test "a second snapshot generation mismatch fails without recording an effect", ctx do
    current = "unstarted:#{ctx.session.created_at}"

    {:ok, sequence} =
      Agent.start_link(fn ->
        [
          snapshot(ctx, "unstarted:stale", 4),
          snapshot(ctx, current, 5)
        ]
      end)

    config =
      ctx.config
      |> Map.put(:identity_apply_runtime_adapter, SnapshotSequenceStub)
      |> Map.put(:snapshot_sequence, sequence)

    {:ok, operation_id, :new} =
      IdentityApply.accept(
        ctx.db,
        ctx.base_dir,
        %{kind: "session", session_key: ctx.session.session_key},
        "user:flynn",
        idempotency_key: "snapshot-terminal"
      )

    assert %{outcome: "failed", sessions: [%{error: %{code: "internal_apply_failure"}}]} =
             Tightbeam.IdentityApply.Executor.start_operation(config, ctx.db, operation_id)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM identity_apply_adapter_effects WHERE operationId=?1",
               [operation_id]
             )

    assert {:ok, [[deadline, 65_536, nil, envelope]]} =
             DB.query(
               ctx.db,
               "SELECT o.normalizationDeadline, o.normalizationNodeBudget, o.normalizationState, f.unclassifiedEnvelope FROM identity_apply_outcomes o JOIN identity_apply_failure_materials f ON f.failureMaterialId=o.failureMaterialId WHERE o.operationId=?1",
               [operation_id]
             )

    assert is_integer(deadline)
    assert envelope == ~s({"kind":"unsupported","type":"inspection-failure"})

    refute IdentityApply.fenced?(ctx.db, ctx.session.session_key)
  end

  test "selected caller intent exists before interruption and materializes once on success",
       ctx do
    assert {:ok, seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: ctx.session.session_key,
               message_id: "self-running",
               origin: ctx.session.session_key,
               prompt: "apply to myself"
             })

    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(ctx.db, ctx.session.session_key, "caller")

    {:ok, operation_id, :new} =
      IdentityApply.accept(
        ctx.db,
        ctx.base_dir,
        %{kind: "session", session_key: ctx.session.session_key},
        ctx.session.session_key,
        idempotency_key: "self-success"
      )

    assert {:ok, [[prompt, message_id, 0]]} =
             DB.query(
               ctx.db,
               "SELECT continuationPrompt, continuationMessageId, continuationMaterialized FROM identity_apply_outcomes WHERE operationId=?1",
               [operation_id]
             )

    assert prompt == IdentityApply.continuation_prompt(operation_id)

    assert message_id ==
             IdentityApply.continuation_message_id(operation_id, ctx.session.session_key)

    assert %{outcome: "succeeded", sessions: [%{turn_outcome: "canceled"}]} =
             Tightbeam.IdentityApply.Executor.start_operation(ctx.config, ctx.db, operation_id)

    assert length(Projection.list_after(ctx.db, ctx.session.session_key, nil, 10)) == 1
  end

  test "selected caller safe failure restores one continuation and blocks same-operation retry",
       ctx do
    assert {:ok, seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: ctx.session.session_key,
               message_id: "self-failing",
               origin: ctx.session.session_key,
               prompt: "apply to myself"
             })

    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(ctx.db, ctx.session.session_key, "caller")

    selector = %{kind: "session", session_key: ctx.session.session_key}

    {:ok, operation_id, :new} =
      IdentityApply.accept(
        ctx.db,
        ctx.base_dir,
        selector,
        ctx.session.session_key,
        idempotency_key: "self-failure"
      )

    config = Map.put(ctx.config, :identity_apply_runtime_adapter, SafeFailureRuntimeStub)

    assert %{
             outcome: "failed",
             sessions: [
               %{error: %{code: "self_apply_retry_requires_new_operation", retryable: false}}
             ]
           } = Tightbeam.IdentityApply.Executor.start_operation(config, ctx.db, operation_id)

    assert length(Projection.list_after(ctx.db, ctx.session.session_key, nil, 10)) == 1

    assert {:ok, ^operation_id, :replay} =
             IdentityApply.accept(
               ctx.db,
               ctx.base_dir,
               selector,
               ctx.session.session_key,
               idempotency_key: "self-failure"
             )

    assert %{sessions: [%{error: %{code: "self_apply_retry_requires_new_operation"}}]} =
             IdentityApply.operation(ctx.db, operation_id)
  end

  test "retirement waits on the durable fence and commits after apply releases it", ctx do
    {:ok, operation_id, :new} =
      IdentityApply.accept(
        ctx.db,
        ctx.base_dir,
        %{kind: "session", session_key: ctx.session.session_key},
        "user:flynn",
        idempotency_key: "retirement-race"
      )

    retirement =
      Task.async(fn -> Org.retire(ctx.db, ctx.session.session_key, "user:flynn", 60_000) end)

    Process.sleep(20)
    assert Task.yield(retirement, 0) == nil
    assert Org.get(ctx.db, ctx.session.session_key).state == "active"

    assert %{outcome: "succeeded"} =
             Tightbeam.IdentityApply.Executor.start_operation(ctx.config, ctx.db, operation_id)

    assert %{state: "retired"} = Task.await(retirement, 5_000)
    refute IdentityApply.fenced?(ctx.db, ctx.session.session_key)
  end

  test "an invalid retryable receipt enters status-only recovery and never reinvokes", ctx do
    recovery_control =
      start_supervised!({Agent, fn -> %{force_not_started: false, invocations: 0} end})

    executor = :"identity_apply_executor_#{System.unique_integer([:positive])}"

    config =
      ctx.config
      |> Map.put(:identity_apply_runtime_adapter, StatusOnlyRecoveryRuntimeStub)
      |> Map.put(:recovery_control, recovery_control)

    start_supervised!(
      {Tightbeam.IdentityApply.Executor, db: ctx.db, config: config, name: executor, adopt: false}
    )

    {:ok, operation_id, :new} =
      IdentityApply.accept(
        ctx.db,
        ctx.base_dir,
        %{kind: "session", session_key: ctx.session.session_key},
        "user:flynn",
        idempotency_key: "status-only-recovery"
      )

    :ok = Tightbeam.IdentityApply.Executor.kick(executor, operation_id)

    assert eventually(fn ->
             case recovery_row(ctx.db, operation_id) do
               [[1, attempt, effect_id]] when attempt >= 1 and is_binary(effect_id) -> true
               _ -> false
             end
           end)

    [[1, first_attempt, effect_id]] = recovery_row(ctx.db, operation_id)
    assert first_attempt >= 1
    assert Agent.get(recovery_control, & &1.invocations) == 1

    Agent.update(recovery_control, &%{&1 | force_not_started: true})

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE identity_apply_adapter_effects SET state='not-started', receipt=NULL WHERE effectId=?1",
        [effect_id]
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE identity_apply_outcomes SET nextAttemptAt=0 WHERE operationId=?1",
        [operation_id]
      )

    :ok = Tightbeam.IdentityApply.Executor.kick(executor, operation_id)

    assert eventually(fn ->
             case recovery_row(ctx.db, operation_id) do
               [[1, attempt, ^effect_id]] -> attempt >= first_attempt + 1
               _ -> false
             end
           end)

    assert Agent.get(recovery_control, & &1.invocations) == 1
    assert %{state: "running"} = IdentityApply.operation(ctx.db, operation_id)

    assert {:error,
            %{
              code: "adapter_effect_recovery_unsupported",
              retryable: false
            }} =
             IdentityApply.accept(
               ctx.db,
               ctx.base_dir,
               %{kind: "session", session_key: ctx.session.session_key},
               "user:flynn",
               idempotency_key: "blocked-after-invalid-evidence"
             )
  end

  defp snapshot(ctx, incarnation, generation) do
    %{
      "contextId" => nil,
      "identityRevision" => ctx.prior,
      "sessionIncarnation" => incarnation,
      "adapterGeneration" => generation,
      "resident" => false,
      "runnable" => true
    }
  end

  defp recovery_row(db, operation_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT statusOnlyRecovery, recoveryAttempt, effectId FROM identity_apply_outcomes WHERE operationId=?1",
        [operation_id]
      )

    rows
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
