defmodule Tightbeam.ProcessCustodySweeperTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, ManagedProcesses, Placement, ProcessCustodySweeper}

  setup do
    db = :"custody_sweeper_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-custody-sweep-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{base_dir: base_dir, config: %{base_dir: base_dir, db: db}, db: db}
  end

  defp preparing(db, attrs) do
    now = System.system_time(:millisecond)

    values = %{
      process_id: "mp_sweep_#{System.unique_integer([:positive])}",
      owner_user_id: "flynn",
      owner_session_key: "agent:sweep",
      session_generation: 0,
      launch_turn_seq: nil,
      host: Placement.local_host_name(),
      purpose: "onboarding_ceremony",
      command_descriptor: "typed onboarding ceremony",
      launch_token: "tok_#{System.unique_integer([:positive])}",
      launch_deadline: now + 60_000,
      lease_expires_at: now + 120_000,
      now: now
    }

    {:ok, {:ok, row}} =
      DB.transaction(db, &ManagedProcesses.insert_preparing(&1, Map.merge(values, attrs)))

    row
  end

  test "the periodic pass waits for a launch deadline, then records honest uncertainty", ctx do
    now = System.system_time(:millisecond)
    waiting = preparing(ctx.db, %{launch_deadline: now + 60_000})
    overdue = preparing(ctx.db, %{launch_deadline: now - 1})

    summary = Gateway.sweep_process_custody(ctx.config)

    assert summary.reconciled == 2
    assert ManagedProcesses.get(ctx.db, waiting.processId).state == "preparing"

    unresolved = ManagedProcesses.get(ctx.db, overdue.processId)
    assert unresolved.state == "identity_unknown"
    assert unresolved.uncertaintyCause == "launch_handoff_unknown"
    assert unresolved.stopCause == nil

    Gateway.recover_process_custody(ctx.config)
    assert ManagedProcesses.get(ctx.db, waiting.processId).state == "preparing"
    assert ManagedProcesses.get(ctx.db, waiting.processId).revision == waiting.revision
  end

  test "an expired remote row is excluded before reconciliation", ctx do
    now = System.system_time(:millisecond)

    row =
      preparing(ctx.db, %{
        host: "remote-custody-host",
        launch_deadline: now + 60_000,
        lease_expires_at: now + 120_000
      })

    identity = %{
      os_pid: 4242,
      process_group_id: 4242,
      boot_identity: "remote-boot",
      launch_token: row.launchToken,
      broker_identity: "/remote/process-custody/#{row.processId}.identity"
    }

    {:ok, {:running, running}} =
      DB.transaction(
        ctx.db,
        &ManagedProcesses.bind_identity_in_txn(&1, row.processId, identity, now: now)
      )

    expired_at = now - 1

    {:ok, {:ok, _expired}} =
      DB.transaction(ctx.db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "running", revision: running.revision],
          %{state: "running", lease_expires_at: expired_at, now: now}
        )
      end)

    before = ManagedProcesses.get(ctx.db, row.processId)
    assert before.leaseExpiresAt == expired_at

    assert %{reconciled: 0} = Gateway.sweep_process_custody(ctx.config)
    assert ManagedProcesses.get(ctx.db, row.processId) == before
  end

  test "boot records helper absence as unknown and repeating it is idempotent", ctx do
    row = preparing(ctx.db, %{})

    identity = %{
      os_pid: 999_999,
      process_group_id: 999_999,
      boot_identity: "boot-fixture",
      launch_token: row.launchToken,
      broker_identity: Path.join(ctx.base_dir, "missing.identity")
    }

    {:ok, {:running, _}} =
      DB.transaction(
        ctx.db,
        &ManagedProcesses.bind_identity_in_txn(&1, row.processId, identity,
          now: System.system_time(:millisecond)
        )
      )

    first = Gateway.recover_process_custody(ctx.config)
    assert first.reconciled == 1

    unknown = ManagedProcesses.get(ctx.db, row.processId)
    assert unknown.state == "identity_unknown"
    assert unknown.uncertaintyCause == "launch_handoff_unknown"

    second = Gateway.recover_process_custody(ctx.config)
    repeated = ManagedProcesses.get(ctx.db, row.processId)

    assert second.reconciled == 1
    assert repeated.revision == unknown.revision
    assert repeated.state == "identity_unknown"
  end

  test "the supervised worker runs the same bounded sweep on demand", ctx do
    now = System.system_time(:millisecond)
    row = preparing(ctx.db, %{lease_expires_at: now - 1})

    sweeper =
      start_supervised!(
        {ProcessCustodySweeper,
         config: ctx.config,
         interval: 60_000,
         name: :"custody_sweeper_#{System.unique_integer([:positive])}"}
      )

    assert %{reconciled: 1, still_blocked: 1} = ProcessCustodySweeper.sweep(sweeper)

    stopped = ManagedProcesses.get(ctx.db, row.processId)
    assert stopped.state == "identity_unknown"
    assert stopped.stopCause == "lease_expired"
    refute stopped.state == "preparing"
  end
end
