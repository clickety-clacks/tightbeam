defmodule Tightbeam.IdentityApply.Executor do
  @moduledoc """
  Supervised owner of durable identity-apply obligations.

  Request processes only accept an operation and wait for its durable result.
  This process owns adapter effects, so caller disconnect and self-interruption
  cannot cancel fleet progress.
  """

  use GenServer

  alias Tightbeam.{Gateway, IdentityApply}
  alias Tightbeam.IdentityApply.{FailureNormalizer, RuntimeAdapter}

  @call_timeout 30_000
  @scan_ms 1_000

  defstruct [:db, :config, :worker_id, timers: %{}, waiters: %{}]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec kick(GenServer.server(), String.t()) :: :ok
  def kick(server \\ __MODULE__, operation_id) do
    GenServer.cast(server, {:kick, operation_id})
  catch
    :exit, _ -> :executor_unavailable
  end

  @spec await(GenServer.server(), GenServer.server(), String.t()) :: map()
  def await(server \\ __MODULE__, db, operation_id) do
    case IdentityApply.operation(db, operation_id) do
      %{state: "completed"} = result -> result
      nil -> nil
      _ -> GenServer.call(server, {:await, operation_id}, :infinity)
    end
  end

  @doc "Start an accepted operation on the production executor, or a test-local supervised worker."
  @spec start_operation(map(), GenServer.server(), String.t()) :: map()
  def start_operation(config, db, operation_id) do
    server = Map.get(config, :identity_apply_executor, __MODULE__)

    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        :ok = kick(server, operation_id)
        await(server, db, operation_id)

      nil ->
        task_sup = Map.get(config, :turn_task_sup, Tightbeam.TurnTaskSupervisor)

        {:ok, _pid} =
          Task.Supervisor.start_child(task_sup, fn ->
            run_detached(config, db, operation_id)
          end)

        await_detached(db, operation_id)
    end
  end

  @doc false
  def run_detached(config, db, operation_id) do
    state = %__MODULE__{
      db: db,
      config: Map.put(config, :db, db),
      worker_id: "identity-apply-detached:" <> random_id()
    }

    run_detached_loop(state, operation_id)
  end

  @impl true
  def init(opts) do
    db = Keyword.get(opts, :db, Tightbeam.DB)
    config = opts |> Keyword.fetch!(:config) |> Map.put(:db, db)
    worker_id = "identity-apply-executor:" <> random_id()
    _adopted = if Keyword.get(opts, :adopt, true), do: IdentityApply.adopt_all!(db), else: []
    send(self(), :recover)
    {:ok, %__MODULE__{db: db, config: config, worker_id: worker_id}}
  end

  @impl true
  def handle_cast({:kick, operation_id}, state) do
    send(self(), {:execute, operation_id})
    {:noreply, state}
  end

  @impl true
  def handle_call({:await, operation_id}, from, state) do
    case IdentityApply.operation(state.db, operation_id) do
      %{state: "completed"} = result ->
        {:reply, result, state}

      nil ->
        {:reply, nil, state}

      _ ->
        waiters = Map.update(state.waiters, operation_id, [from], &[from | &1])
        {:noreply, %{state | waiters: waiters}}
    end
  end

  @impl true
  def handle_info(:recover, state) do
    Enum.each(IdentityApply.pending_operation_ids(state.db), &send(self(), {:execute, &1}))
    Process.send_after(self(), :recover, @scan_ms)
    {:noreply, state}
  end

  def handle_info({:execute, operation_id}, state) do
    state = cancel_timer(state, operation_id)
    execute_operation(state, operation_id)

    case IdentityApply.operation(state.db, operation_id) do
      %{state: "completed"} = result ->
        {:noreply, reply_waiters(state, operation_id, result)}

      %{state: "running"} ->
        {:noreply, schedule_next(state, operation_id)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:identity_apply_result, operation_id, result}, state) do
    state = reply_waiters(state, operation_id, result)
    {:noreply, cancel_timer(state, operation_id)}
  end

  defp execute_operation(state, operation_id) do
    operation = IdentityApply.operation(state.db, operation_id)

    state.db
    |> IdentityApply.claim_outcomes(operation_id, state.worker_id)
    |> Enum.each(fn outcome -> execute_outcome(state, operation, outcome) end)
  end

  defp run_detached_loop(state, operation_id) do
    execute_operation(state, operation_id)

    case IdentityApply.operation(state.db, operation_id) do
      %{state: "completed"} = result ->
        result

      %{state: "running"} ->
        receive do
        after
          @scan_ms -> run_detached_loop(state, operation_id)
        end

      nil ->
        nil
    end
  end

  defp await_detached(db, operation_id) do
    case IdentityApply.operation(db, operation_id) do
      %{state: "completed"} = result ->
        result

      nil ->
        nil

      _ ->
        receive do
        after
          10 -> await_detached(db, operation_id)
        end
    end
  end

  defp execute_outcome(state, operation, %{next_attempt_at: next_at} = outcome)
       when is_integer(next_at) and next_at > 0 do
    if next_at <= now(), do: execute_outcome_now(state, operation, outcome)
  end

  defp execute_outcome(state, operation, outcome),
    do: execute_outcome_now(state, operation, outcome)

  defp execute_outcome_now(_state, _operation, nil), do: :ok

  defp execute_outcome_now(state, operation, %{state: "pending"} = outcome) do
    started = now()

    case IdentityApply.mark_snapshot_call(
           state.db,
           outcome,
           state.worker_id,
           started,
           started + @call_timeout
         ) do
      :ok ->
        case supervised_call(state, fn ->
               runtime(state).snapshot(state.config, state.db, outcome.session_key)
             end) do
          {:ok, {:ok, snapshot}} ->
            effect_request = effect_request(operation, outcome)

            case IdentityApply.store_snapshot_and_begin(
                   state.db,
                   outcome,
                   state.worker_id,
                   snapshot,
                   effect_request
                 ) do
              {:ok, _effect} ->
                resume_effect(
                  state,
                  operation,
                  refresh_outcome(state, operation, outcome.session_key)
                )

              {:error, :incarnation_mismatch} ->
                fail_internal(state, outcome, "snapshot-revalidation", :incarnation_mismatch)

              {:retry, :snapshot_revalidation_mismatch} ->
                :ok

              {:error, :snapshot_revalidation_mismatch} ->
                fail_internal(
                  state,
                  outcome,
                  "snapshot-revalidation",
                  :snapshot_revalidation_mismatch
                )

              {:error, _} ->
                :ok
            end

          {:ok, {:error, _reason}} ->
            IdentityApply.schedule_recovery(
              state.db,
              outcome,
              state.worker_id,
              "prior_context_snapshot_unavailable",
              now()
            )

          :timeout ->
            IdentityApply.schedule_recovery(
              state.db,
              outcome,
              state.worker_id,
              "prior_context_snapshot_unavailable",
              now()
            )

          {:exit, _reason} ->
            IdentityApply.schedule_recovery(
              state.db,
              outcome,
              state.worker_id,
              "prior_context_snapshot_unavailable",
              now()
            )
        end

      :stale ->
        :ok
    end
  end

  defp execute_outcome_now(state, operation, %{state: state_name} = outcome)
       when state_name in ["interrupting", "reloading"] do
    resume_effect(state, operation, outcome)
  end

  defp execute_outcome_now(state, operation, %{state: "continuation-pending"} = outcome) do
    if is_nil(outcome.next_attempt_at) do
      IdentityApply.schedule_recovery(
        state.db,
        outcome,
        state.worker_id,
        "post_reload_commit_unavailable",
        now()
      )
    else
      commit_success(state, operation, outcome)
    end
  end

  defp resume_effect(state, operation, outcome) do
    started = now()
    recovery = IdentityApply.effect_recovery_state(state.db, outcome.outcome_id)

    :ok =
      IdentityApply.record_effect_call(
        state.db,
        outcome,
        state.worker_id,
        "status",
        started,
        started + @call_timeout
      )

    status =
      supervised_call(state, fn ->
        runtime(state).status(state.config, state.db, outcome.effect_id)
      end)

    result = status_result(state, outcome, recovery, status)

    handle_effect_result(state, operation, outcome, result)
  end

  defp status_result(_state, _outcome, _recovery, :timeout), do: {:timeout, :status}
  defp status_result(_state, _outcome, _recovery, {:exit, reason}), do: {:error, reason}
  defp status_result(_state, _outcome, _recovery, {:ok, {:error, reason}}), do: {:error, reason}

  defp status_result(_state, _outcome, %{status_only: true}, {:ok, :not_started}),
    do: {:error, :status_only_not_started}

  defp status_result(state, outcome, _recovery, {:ok, :not_started}) do
    started = now()

    :ok =
      IdentityApply.record_effect_call(
        state.db,
        outcome,
        state.worker_id,
        "invoke",
        started,
        started + @call_timeout
      )

    case supervised_call(state, fn ->
           runtime(state).invoke(state.config, state.db, outcome.effect_id)
         end) do
      {:ok, result} -> result
      :timeout -> {:timeout, :invoke}
      {:exit, reason} -> {:error, reason}
    end
  end

  defp status_result(_state, _outcome, _recovery, {:ok, :in_progress}),
    do: {:error, :in_progress}

  defp status_result(_state, _outcome, _recovery, {:ok, {:succeeded, receipt}}),
    do: {:succeeded, receipt}

  defp status_result(_state, _outcome, _recovery, {:ok, {:failed, receipt}}),
    do: {:failed, receipt}

  defp handle_effect_result(state, operation, outcome, {:succeeded, receipt}) do
    :ok = IdentityApply.record_effect_receipt(state.db, outcome, state.worker_id, receipt)

    case outcome.effect_phase do
      "runner-stop" ->
        case IdentityApply.begin_reload_after_stop(
               state.db,
               outcome,
               state.worker_id,
               effect_request(operation, outcome)
             ) do
          {:ok, _effect_id} ->
            resume_effect(
              state,
              operation,
              refresh_outcome(state, operation, outcome.session_key)
            )

          :stale ->
            :ok
        end

      "reload" ->
        if valid_target_receipt?(receipt, operation.identity_revision) do
          :ok =
            IdentityApply.mark_continuation_pending(state.db, outcome, state.worker_id, receipt)

          commit_success(state, operation, refresh_outcome(state, operation, outcome.session_key))
        else
          schedule_adapter_recovery(state, outcome)
        end
    end
  end

  defp handle_effect_result(state, operation, outcome, {:failed, receipt}) do
    :ok = IdentityApply.record_effect_receipt(state.db, outcome, state.worker_id, receipt)
    recovery = IdentityApply.effect_recovery_state(state.db, outcome.outcome_id)
    disposition = get_in(receipt, ["class", "effectDisposition"])

    cond do
      disposition == "terminal" and safe_prior_receipt?(outcome, recovery, receipt) ->
        code =
          if outcome.effect_phase == "runner-stop",
            do: "turn_interruption_failed",
            else: "harness_reload_failed"

        terminal_failure(state, operation, outcome, code, outcome.effect_phase, receipt)

      disposition == "retryable" and retryable_receipt_valid?(outcome, recovery, receipt) and
          recovery.call_kind == "status" ->
        case IdentityApply.reset_retryable_effect(
               state.db,
               outcome,
               state.worker_id
             ) do
          :ok ->
            resume_effect(
              state,
              operation,
              refresh_outcome(state, operation, outcome.session_key)
            )

          :stale ->
            :ok
        end

      disposition == "retryable" and retryable_receipt_valid?(outcome, recovery, receipt) ->
        schedule_adapter_recovery(state, outcome)

      true ->
        cause = invalid_receipt_cause(recovery, receipt)
        :ok = IdentityApply.mark_status_only_recovery(state.db, outcome, state.worker_id, cause)
        schedule_adapter_recovery(state, outcome)
    end
  end

  defp handle_effect_result(state, _operation, outcome, {:error, _reason}) do
    schedule_adapter_recovery(state, outcome)
  end

  defp handle_effect_result(state, _operation, outcome, {:timeout, _call_kind}) do
    IdentityApply.schedule_recovery(
      state.db,
      outcome,
      state.worker_id,
      "timed_out",
      now()
    )
  end

  defp commit_success(state, operation, outcome) do
    case IdentityApply.commit_success(
           state.db,
           outcome,
           state.worker_id,
           operation: operation,
           delivery_opts: [
             db: state.db,
             conn_registry: state.config[:conn_registry] || Tightbeam.ConnRegistry,
             lane_manager: state.config[:lane_manager] || Tightbeam.LaneManager
           ]
         ) do
      {:ok, delivery} ->
        Gateway.complete_delivery(state.db, delivery)
        IdentityApply.notify_fence_released(outcome.session_key)

      {:error, _reason} ->
        current = refresh_outcome(state, operation, outcome.session_key)

        IdentityApply.schedule_recovery(
          state.db,
          current,
          state.worker_id,
          "post_reload_commit_unavailable",
          now()
        )

      :stale ->
        :ok
    end
  end

  defp terminal_failure(state, operation, outcome, code, stage, raw) do
    interrupted_caller =
      operation.requested_by == outcome.session_key and
        is_integer(outcome.interrupted_turn_seq)

    failure_opts =
      [
        source: source(state.db, outcome),
        interrupted_caller: interrupted_caller,
        operation: operation,
        delivery_opts: [
          db: state.db,
          conn_registry: state.config[:conn_registry] || Tightbeam.ConnRegistry,
          lane_manager: state.config[:lane_manager] || Tightbeam.LaneManager
        ]
      ]
      |> maybe_put_envelope(raw)

    case IdentityApply.fail_outcome(
           state.db,
           outcome,
           state.worker_id,
           code,
           stage,
           raw,
           failure_opts
         ) do
      {:ok, %{delivery: delivery}} ->
        if delivery, do: Gateway.complete_delivery(state.db, delivery)
        IdentityApply.notify_fence_released(outcome.session_key)

      :stale ->
        :ok
    end
  end

  defp fail_internal(state, outcome, stage, reason) do
    operation = IdentityApply.operation(state.db, outcome.operation_id)

    :ok =
      IdentityApply.begin_failure_normalization(
        state.db,
        outcome,
        state.worker_id,
        "#{state.worker_id}:failure-normalizer"
      )

    envelope = JSON.decode!(FailureNormalizer.inspection_failure())

    terminal_failure(
      state,
      operation,
      outcome,
      "internal_apply_failure",
      stage,
      %{controlled_cause: reason, envelope: envelope}
    )
  end

  defp schedule_adapter_recovery(state, outcome) do
    IdentityApply.schedule_recovery(
      state.db,
      outcome,
      state.worker_id,
      "adapter_unavailable",
      now()
    )
  end

  defp retryable_receipt_valid?(%{effect_phase: "runner-stop"}, _recovery, _receipt), do: true

  defp retryable_receipt_valid?(%{effect_phase: "reload"} = outcome, recovery, receipt),
    do: safe_prior_receipt?(outcome, recovery, receipt)

  defp safe_prior_receipt?(_outcome, %{prior_context: nil}, _receipt), do: false

  defp safe_prior_receipt?(_outcome, %{prior_context: prior}, receipt) do
    Map.has_key?(receipt, "priorContextId") and Map.has_key?(receipt, "priorRevision") and
      receipt["priorContextId"] == prior["contextId"] and
      receipt["priorRevision"] == prior["identityRevision"] and receipt["runnable"] == true
  end

  defp invalid_receipt_cause(%{prior_context: prior}, receipt) when is_map(prior) do
    identifiers_match =
      Map.has_key?(receipt, "priorContextId") and Map.has_key?(receipt, "priorRevision") and
        receipt["priorContextId"] == prior["contextId"] and
        receipt["priorRevision"] == prior["identityRevision"]

    if identifiers_match, do: "nonrunnable", else: "context_mismatch"
  end

  defp invalid_receipt_cause(_recovery, _receipt), do: "context_mismatch"

  defp valid_target_receipt?(receipt, target_revision) do
    receipt["state"] == "succeeded" and receipt["targetRevision"] == target_revision and
      receipt["runnable"] == true and is_binary(receipt["targetContextId"])
  end

  defp effect_request(operation, outcome) do
    %{
      operationId: operation.operation_id,
      sessionKey: outcome.session_key,
      targetRevision: operation.identity_revision,
      interruptedTurnSeq: outcome.interrupted_turn_seq,
      requestedBy: operation.requested_by
    }
  end

  defp refresh_outcome(state, operation, session_key) do
    state.db
    |> IdentityApply.claim_outcomes(operation.operation_id, state.worker_id)
    |> Enum.find(&(&1.session_key == session_key))
  end

  defp source(db, outcome) do
    case Tightbeam.Org.get(db, outcome.session_key) do
      %{harness: harness} when is_binary(harness) -> harness
      _ -> "gateway"
    end
  end

  defp maybe_put_envelope(opts, %{envelope: envelope}), do: Keyword.put(opts, :envelope, envelope)
  defp maybe_put_envelope(opts, _raw), do: opts

  defp runtime(state), do: Map.get(state.config, :identity_apply_runtime_adapter, RuntimeAdapter)

  defp supervised_call(state, fun) do
    supervisor = Map.get(state.config, :turn_task_sup, Tightbeam.TurnTaskSupervisor)
    task = Task.Supervisor.async_nolink(supervisor, fun)

    case Task.yield(task, @call_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:exit, reason}
      nil -> :timeout
    end
  end

  defp schedule_next(state, operation_id) do
    ref = Process.send_after(self(), {:execute, operation_id}, @scan_ms)
    put_in(state.timers[operation_id], ref)
  end

  defp cancel_timer(state, operation_id) do
    case Map.pop(state.timers, operation_id) do
      {nil, timers} ->
        %{state | timers: timers}

      {ref, timers} ->
        Process.cancel_timer(ref)
        %{state | timers: timers}
    end
  end

  defp reply_waiters(state, operation_id, result) do
    {waiters, remaining} = Map.pop(state.waiters, operation_id, [])
    Enum.each(waiters, &GenServer.reply(&1, result))
    %{state | waiters: remaining}
  end

  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  defp now, do: System.system_time(:millisecond)
end
