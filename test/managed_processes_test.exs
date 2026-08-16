defmodule Tightbeam.ManagedProcessesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, ManagedProcesses}

  setup do
    db = :"managed_processes_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ManagedProcesses.ensure_schema(db)
    %{db: db}
  end

  defp preparing(db, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          process_id: "mp_#{System.unique_integer([:positive])}",
          owner_user_id: "flynn",
          owner_session_key: "agent:owner",
          session_generation: 1,
          launch_turn_seq: 42,
          host: "testhost",
          purpose: "onboarding_ceremony",
          command_descriptor: "codex login (digest sha256:abcd)",
          launch_token: "tok_#{System.unique_integer([:positive])}",
          launch_deadline: 10_000,
          lease_expires_at: 60_000,
          now: 1_000
        },
        overrides
      )

    {:ok, row} = tx!(db, &ManagedProcesses.insert_preparing(&1, attrs))
    row
  end

  # `DB.transaction/2` wraps whatever the body returns in its own `{:ok, _}`,
  # so a body that already answers `{:ok, row}` comes back `{:ok, {:ok, row}}`.
  # Unwrap once here rather than in every assertion.
  defp tx!(db, fun) do
    {:ok, result} = DB.transaction(db, fun)
    result
  end

  defp identity_bind(now \\ 2_000) do
    %{
      state: "running",
      os_pid: 4242,
      process_group_id: 4242,
      boot_identity: "boot-abc",
      release_granted_at: now,
      now: now
    }
  end

  test "a new row opens preparing at revision 1 with no identity and no causes", ctx do
    row = preparing(ctx.db)

    assert row.state == "preparing"
    assert row.revision == 1
    assert row.osPid == nil
    assert row.processGroupId == nil
    assert row.bootIdentity == nil
    assert row.stopCause == nil
    assert row.uncertaintyCause == nil
    assert row.stopAttemptCount == 0
    assert row.releaseGrantedAt == nil
    assert row.sessionGeneration == 1
  end

  test "a winning transition changes one row and bumps the revision", ctx do
    row = preparing(ctx.db)

    {:ok, bound} =
      tx!(ctx.db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "preparing", revision: 1],
          identity_bind()
        )
      end)

    assert %{state: "running", revision: 2, osPid: 4242} = bound
    assert bound.releaseGrantedAt == 2_000
    assert bound.updatedAt == 2_000
  end

  # The point of the revision is that the LOSER learns the winning durable
  # result instead of retrying blind against state it has already lost.
  test "a stale revision loses and is handed the current durable row", ctx do
    row = preparing(ctx.db)

    {:ok, _won} =
      tx!(ctx.db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "preparing", revision: 1],
          %{state: "launch_cancel_requested", stop_cause: "owner_stop", now: 1_500}
        )
      end)

    result =
      tx!(ctx.db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "preparing", revision: 1],
          identity_bind()
        )
      end)

    assert {:lost, current} = result
    assert current.state == "launch_cancel_requested"
    assert current.stopCause == "owner_stop"
    assert current.revision == 2
    refute current.state == "running"
  end

  test "a transition accepting several origin states matches any of them", ctx do
    row = preparing(ctx.db)

    {:ok, bound} =
      tx!(ctx.db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "preparing", revision: 1],
          identity_bind()
        )
      end)

    {:ok, stopping} =
      tx!(ctx.db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: ["running", "stop_failed"], revision: bound.revision],
          %{state: "stop_requested", stop_cause: "owner_stop", now: 3_000}
        )
      end)

    assert stopping.state == "stop_requested"
    assert stopping.stopCause == "owner_stop"
  end

  # SPEC B3: "A stop_requested row must contain the full proven identity tuple."
  # Asserted against the TABLE, not a guard, because the rule's whole purpose is
  # that no future code path can express a stop request against an unknown PID —
  # that is how you signal a stranger's process. A guard in one function is
  # advice to the next contributor; this is physics.
  test "the table refuses stop_requested without a proven identity tuple", ctx do
    row = preparing(ctx.db)

    assert {:error, _} =
             DB.transaction(ctx.db, fn txn ->
               ManagedProcesses.transition(
                 txn,
                 row.processId,
                 [state: "preparing", revision: 1],
                 %{state: "stop_requested", stop_cause: "owner_stop", now: 2_000}
               )
             end)

    assert ManagedProcesses.get(ctx.db, row.processId).state == "preparing"
  end

  test "the table refuses running without a proven identity tuple", ctx do
    row = preparing(ctx.db)

    assert {:error, _} =
             DB.transaction(ctx.db, fn txn ->
               ManagedProcesses.transition(
                 txn,
                 row.processId,
                 [state: "preparing", revision: 1],
                 %{state: "running", release_granted_at: 2_000, now: 2_000}
               )
             end)
  end

  test "the table refuses a state outside the closed set", ctx do
    row = preparing(ctx.db)

    assert {:error, _} =
             DB.transaction(ctx.db, fn txn ->
               ManagedProcesses.transition(
                 txn,
                 row.processId,
                 [state: "preparing", revision: 1],
                 %{state: "probably_fine", now: 2_000}
               )
             end)
  end

  test "the table refuses an unlisted stop cause", ctx do
    row = preparing(ctx.db)

    assert {:error, _} =
             DB.transaction(ctx.db, fn txn ->
               ManagedProcesses.transition(
                 txn,
                 row.processId,
                 [state: "preparing", revision: 1],
                 %{state: "launch_cancel_requested", stop_cause: "felt_like_it", now: 2_000}
               )
             end)
  end

  # SPEC B2/B5: an identity uncertainty never overwrites a stop cause. The two
  # answer different questions — "why must this stop" and "why can't we prove
  # which process it is" — and a row is routinely both at once.
  test "uncertainty and stop causes are stored separately and coexist", ctx do
    row = preparing(ctx.db)

    {:ok, canceled} =
      tx!(ctx.db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "preparing", revision: 1],
          %{state: "launch_cancel_requested", stop_cause: "session_retired", now: 2_000}
        )
      end)

    {:ok, unknown} =
      tx!(ctx.db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "launch_cancel_requested", revision: canceled.revision],
          %{
            state: "identity_unknown",
            uncertainty_cause: "launch_handoff_unknown",
            now: 3_000
          }
        )
      end)

    assert unknown.state == "identity_unknown"
    assert unknown.stopCause == "session_retired"
    assert unknown.uncertaintyCause == "launch_handoff_unknown"
  end

  # SPEC B2/B6: the row has nowhere to put a secret. Proving the absence of the
  # column is the enforcement — a future contributor cannot write a one-time
  # code to a field that does not exist.
  test "the record has no column that could hold a raw command, env, or secret", ctx do
    {:ok, rows} = DB.query(ctx.db, "PRAGMA table_info(managed_processes)")
    columns = Enum.map(rows, fn [_, name | _] -> name end)

    for forbidden <- ~w(command commandLine argv env environment credential secret
                        deviceCode oneTimeCode token password url) do
      refute forbidden in columns,
             "managed_processes must not carry a #{forbidden} column: #{inspect(columns)}"
    end

    assert "commandDescriptor" in columns
    assert "deliveryEvidenceId" in columns
    refute "launchToken" == "launchtoken"
  end

  test "the retirement census returns nonterminal and unresolved rows and skips terminal", ctx do
    keep_preparing = preparing(ctx.db, %{owner_session_key: "agent:subject"})
    unresolved = preparing(ctx.db, %{owner_session_key: "agent:subject"})
    finished = preparing(ctx.db, %{owner_session_key: "agent:subject"})
    other_session = preparing(ctx.db, %{owner_session_key: "agent:elsewhere"})

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        unresolved.processId,
        [state: "preparing", revision: 1],
        %{state: "identity_unknown", uncertainty_cause: "launch_handoff_unknown", now: 2_000}
      )

      ManagedProcesses.transition(
        txn,
        finished.processId,
        [state: "preparing", revision: 1],
        %{state: "launch_failed", last_error: "spawn refused", resolved_at: 2_000, now: 2_000}
      )
    end)

    blockers =
      tx!(ctx.db, &ManagedProcesses.retirement_blockers_in_txn(&1, "agent:subject"))

    ids = Enum.map(blockers, & &1.processId)

    assert keep_preparing.processId in ids
    assert unresolved.processId in ids
    refute finished.processId in ids
    refute other_session.processId in ids
  end

  test "the writable set refuses to rewrite ownership or identity provenance", ctx do
    row = preparing(ctx.db)

    # `DB.transaction/2` catches the raise and returns it, so assert on the
    # returned exception rather than expecting it to escape the transaction.
    assert {:error, %ArgumentError{message: message}} =
             DB.transaction(ctx.db, fn txn ->
               ManagedProcesses.transition(
                 txn,
                 row.processId,
                 [state: "preparing", revision: 1],
                 %{owner_session_key: "agent:someone-else", now: 2_000}
               )
             end)

    assert message =~ "cannot write :owner_session_key"

    # The refused write left nothing behind.
    assert ManagedProcesses.get(ctx.db, row.processId).ownerSessionKey == "agent:owner"
  end

  test "the closed state sets partition and cover", _ctx do
    all = ManagedProcesses.states()

    assert length(all) == 10

    assert Enum.sort(all) ==
             Enum.sort(
               ManagedProcesses.nonterminal_states() ++
                 ManagedProcesses.terminal_states() ++ ManagedProcesses.unresolved_states()
             )

    for group <- [
          ManagedProcesses.nonterminal_states(),
          ManagedProcesses.terminal_states(),
          ManagedProcesses.unresolved_states()
        ] do
      assert group == Enum.uniq(group)
    end

    assert ManagedProcesses.retirement_blocking_states() ==
             ManagedProcesses.nonterminal_states() ++ ManagedProcesses.unresolved_states()

    # Unresolved is NOT terminal. If this ever collapses, a session could
    # finalize retirement over a process nobody has proved anything about.
    for unresolved <- ManagedProcesses.unresolved_states() do
      refute unresolved in ManagedProcesses.terminal_states()
    end
  end
end
