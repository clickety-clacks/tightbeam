defmodule Tightbeam.ManagedProcessesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, ManagedProcesses}

  setup do
    db = :"managed_processes_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    # The whole production schema, not just this table: the retirement tests
    # below drive `Org.retire_in_txn`, which touches sessions, supervision and
    # wakes in the same transaction. A fixture carrying only `managed_processes`
    # would pass the unit cases and prove nothing about the seam that matters.
    :ok = Tightbeam.Schema.ensure_all(db)
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

  ## The retirement fence (§B5, additive per att_54f4348d)

  defp open_fence(db, session_key, epoch \\ 5_000) do
    tx!(db, fn txn ->
      ManagedProcesses.open_fence_in_txn(txn, session_key,
        retirement_epoch: epoch,
        principal: "user:flynn"
      )
    end)
  end

  test "opening the fence marks the session retiring at generation 1", ctx do
    assert {:ok, fence} = open_fence(ctx.db, "agent:owner")

    assert fence.state == "retiring"
    assert fence.generation == 1
    assert fence.finalizedAt == nil
    assert fence.retirementEpoch == 5_000
  end

  # An exact retirement retry must reach the same durable answer. Opening a
  # second fence, or bumping the generation on a retry, would make a late
  # identity bind from the SAME retirement look stale.
  test "reopening an open fence is idempotent and does not move the generation", ctx do
    assert {:ok, first} = open_fence(ctx.db, "agent:owner")
    assert {:already_open, again} = open_fence(ctx.db, "agent:owner", 9_999)

    assert again.generation == first.generation
    assert again.retirementEpoch == 5_000
  end

  test "a session that finalized and retires again opens at the next generation", ctx do
    assert {:ok, _} = open_fence(ctx.db, "agent:owner")

    assert {:ok, final} =
             tx!(ctx.db, fn txn ->
               ManagedProcesses.finalize_fence_in_txn(txn, "agent:owner",
                 generation: 1,
                 now: 6_000
               )
             end)

    assert final.state == "retired"
    assert final.finalizedAt == 6_000

    assert {:ok, second} = open_fence(ctx.db, "agent:owner", 7_000)
    assert second.generation == 2
    assert second.state == "retiring"
    assert second.finalizedAt == nil
  end

  test "finalizing is refused while any row still blocks, and names the blockers", ctx do
    row = preparing(ctx.db, %{owner_session_key: "agent:blocked"})
    assert {:ok, _} = open_fence(ctx.db, "agent:blocked")

    assert {:blocked, blockers} =
             tx!(ctx.db, fn txn ->
               ManagedProcesses.finalize_fence_in_txn(txn, "agent:blocked",
                 generation: 1,
                 now: 6_000
               )
             end)

    assert Enum.map(blockers, & &1.processId) == [row.processId]
    assert ManagedProcesses.fence(ctx.db, "agent:blocked").state == "retiring"
  end

  test "finalizing twice at the same generation is idempotent success", ctx do
    assert {:ok, _} = open_fence(ctx.db, "agent:owner")

    finalize = fn ->
      tx!(ctx.db, fn txn ->
        ManagedProcesses.finalize_fence_in_txn(txn, "agent:owner", generation: 1, now: 6_000)
      end)
    end

    assert {:ok, _} = finalize.()
    assert {:already_final, fence} = finalize.()
    assert fence.state == "retired"
    assert fence.finalizedAt == 6_000
  end

  test "the fence table refuses a retired row with no finalization timestamp", ctx do
    assert {:error, _} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 """
                 INSERT INTO session_retirement_fence
                   (sessionKey, generation, state, retirementEpoch, principal, openedAt, revision)
                 VALUES ('agent:liar', 1, 'retired', 1, 'user:flynn', 1, 1)
                 """
               )
             end)
  end

  # SPEC B5: the census is asymmetric on purpose. preparing and running are
  # DRIVEN to a new state; identity_unknown is not, because retirement orders a
  # stop, it does not prove the process is gone.
  test "the census drives preparing and running but leaves identity_unknown unresolved", ctx do
    prep = preparing(ctx.db, %{owner_session_key: "agent:census"})
    run = preparing(ctx.db, %{owner_session_key: "agent:census"})
    unknown = preparing(ctx.db, %{owner_session_key: "agent:census"})

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        run.processId,
        [state: "preparing", revision: 1],
        identity_bind()
      )

      ManagedProcesses.transition(
        txn,
        unknown.processId,
        [state: "preparing", revision: 1],
        %{state: "identity_unknown", uncertainty_cause: "launch_handoff_unknown", now: 2_000}
      )
    end)

    tx!(ctx.db, fn txn ->
      ManagedProcesses.retirement_census_in_txn(txn, "agent:census", now: 5_000)
    end)

    assert %{state: "launch_cancel_requested", stopCause: "session_retired"} =
             ManagedProcesses.get(ctx.db, prep.processId)

    assert %{state: "stop_requested", stopCause: "session_retired"} =
             ManagedProcesses.get(ctx.db, run.processId)

    still_unknown = ManagedProcesses.get(ctx.db, unknown.processId)
    assert still_unknown.state == "identity_unknown"
    assert still_unknown.stopCause == "session_retired"
    assert still_unknown.uncertaintyCause == "launch_handoff_unknown"
  end

  # Whoever asked first owns the reason. Overwriting it would erase why the
  # process is stopping in favour of the most recent bystander.
  test "the census never overwrites a stop cause that was already there", ctx do
    row = preparing(ctx.db, %{owner_session_key: "agent:first"})

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        row.processId,
        [state: "preparing", revision: 1],
        %{state: "launch_cancel_requested", stop_cause: "owner_stop", now: 2_000}
      )
    end)

    tx!(ctx.db, fn txn ->
      ManagedProcesses.retirement_census_in_txn(txn, "agent:first", now: 5_000)
    end)

    assert ManagedProcesses.get(ctx.db, row.processId).stopCause == "owner_stop"
  end

  test "the census skips terminal rows and other sessions", ctx do
    mine = preparing(ctx.db, %{owner_session_key: "agent:mine"})
    theirs = preparing(ctx.db, %{owner_session_key: "agent:theirs"})

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        mine.processId,
        [state: "preparing", revision: 1],
        %{state: "launch_failed", last_error: "spawn refused", resolved_at: 2_000, now: 2_000}
      )
    end)

    tx!(ctx.db, fn txn ->
      ManagedProcesses.retirement_census_in_txn(txn, "agent:mine", now: 5_000)
    end)

    assert ManagedProcesses.get(ctx.db, mine.processId).stopCause == nil
    assert ManagedProcesses.get(ctx.db, theirs.processId).state == "preparing"
    assert ManagedProcesses.get(ctx.db, theirs.processId).stopCause == nil
  end

  ## Retirement wiring (§B5) — Org.retire_in_txn through the fence

  defp session_row(db, key) do
    Tightbeam.Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })
  end

  defp retire(db, key) do
    tx!(db, fn txn -> Tightbeam.Org.retire_in_txn(txn, key, "user:flynn", 1_000) end)
  end

  # The ordinary case, and the one that must not change: a session owning no
  # managed process retires exactly as it did before durable custody existed.
  test "a session with no managed process still retires outright", ctx do
    session_row(ctx.db, "agent:plain")

    assert %{state: "retired"} = retire(ctx.db, "agent:plain")
    assert ManagedProcesses.fence(ctx.db, "agent:plain").state == "retired"
  end

  # SPEC B5 / acceptance 8 and 19: an unresolved process BLOCKS finalization.
  # Reporting this session retired is the exact lie the fence exists to prevent.
  test "an unresolved process defers retirement and the session stays active", ctx do
    session_row(ctx.db, "agent:busy")
    row = preparing(ctx.db, %{owner_session_key: "agent:busy"})

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        row.processId,
        [state: "preparing", revision: 1],
        %{state: "identity_unknown", uncertainty_cause: "launch_handoff_unknown", now: 2_000}
      )
    end)

    assert %{state: "active"} = retire(ctx.db, "agent:busy")

    fence = ManagedProcesses.fence(ctx.db, "agent:busy")
    assert fence.state == "retiring"
    assert fence.finalizedAt == nil

    # The census still installed retirement as the reason of record, without
    # claiming the process is gone.
    settled = ManagedProcesses.get(ctx.db, row.processId)
    assert settled.state == "identity_unknown"
    assert settled.stopCause == "session_retired"
    assert settled.uncertaintyCause == "launch_handoff_unknown"
  end

  # SPEC B5 / acceptance 23 and 24: once the last row terminalizes, an EXACT
  # retry finalizes, and it is idempotent rather than a second retirement.
  test "an exact retry retires once the blocking row resolves", ctx do
    session_row(ctx.db, "agent:later")
    row = preparing(ctx.db, %{owner_session_key: "agent:later"})

    assert %{state: "active"} = retire(ctx.db, "agent:later")
    assert ManagedProcesses.fence(ctx.db, "agent:later").state == "retiring"

    blocked = ManagedProcesses.get(ctx.db, row.processId)
    assert blocked.state == "launch_cancel_requested"
    assert blocked.stopCause == "session_retired"

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        row.processId,
        [state: "launch_cancel_requested", revision: blocked.revision],
        %{state: "launch_canceled", resolved_at: 7_000, now: 7_000}
      )
    end)

    assert %{state: "retired"} = retire(ctx.db, "agent:later")

    fence = ManagedProcesses.fence(ctx.db, "agent:later")
    assert fence.state == "retired"
    assert fence.generation == 1, "an exact retry must not open a second retirement"

    # Already retired: idempotent, and it does not reopen the fence.
    assert %{state: "retired"} = retire(ctx.db, "agent:later")
    assert ManagedProcesses.fence(ctx.db, "agent:later").generation == 1
  end
end
