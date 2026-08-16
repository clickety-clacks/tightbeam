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
          session_generation: 0,
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
    assert row.sessionGeneration == 0, "a session that never retired is at generation 0"
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

  ## Identity bind (§B5 steps 3-7) — the one decision the barrier protects

  defp identity(token \\ nil),
    do: %{
      os_pid: 4242,
      process_group_id: 4242,
      boot_identity: "boot-abc",
      launch_token: token
    }

  # A real broker is HANDED the launch token; the tests read it off the row for
  # the same reason (review att_8017ebe7 F5).
  defp bind(db, process_id, now \\ 3_000) do
    token = ManagedProcesses.get(db, process_id).launchToken

    tx!(db, fn txn ->
      ManagedProcesses.bind_identity_in_txn(txn, process_id, identity(token), now: now)
    end)
  end

  test "a clean bind reaches running and records the release grant", ctx do
    row = preparing(ctx.db)

    assert {:running, bound} = bind(ctx.db, row.processId)
    assert bound.state == "running"
    assert bound.releaseGrantedAt == 3_000
    assert bound.osPid == 4242
    assert bound.stopCause == nil
  end

  # §B5: if a stop won first, the bind goes only to stop_requested. It binds the
  # identity — the stop worker needs it to signal the right group — but it must
  # never release, and never claim a grant that did not happen.
  test "a bind that loses to an earlier stop reaches stop_requested and never grants release",
       ctx do
    row = preparing(ctx.db)

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        row.processId,
        [state: "preparing", revision: 1],
        %{state: "launch_cancel_requested", stop_cause: "owner_stop", now: 2_000}
      )
    end)

    assert {:stop, bound} = bind(ctx.db, row.processId)
    assert bound.state == "stop_requested"
    assert bound.stopCause == "owner_stop", "the first cause must survive the bind"
    assert bound.releaseGrantedAt == nil
    assert bound.osPid == 4242, "identity is still bound so the stop can find the group"
  end

  # §B5, acceptance 22: identity discovered AFTER lease expiry installs
  # lease_expired, reaches stop_requested, and never records a release grant.
  test "a bind after lease expiry stops instead of running", ctx do
    row = preparing(ctx.db, %{lease_expires_at: 2_500})

    assert {:stop, bound} = bind(ctx.db, row.processId, 3_000)
    assert bound.state == "stop_requested"
    assert bound.stopCause == "lease_expired"
    assert bound.releaseGrantedAt == nil
  end

  # A bind belonging to a previous life of the session must not expose running.
  # The generation captured at insert is what makes that detectable.
  test "a bind whose session generation moved on stops instead of running", ctx do
    row = preparing(ctx.db, %{owner_session_key: "agent:moved", session_generation: 0})

    tx!(ctx.db, fn txn ->
      ManagedProcesses.open_fence_in_txn(txn, "agent:moved",
        retirement_epoch: 2_000,
        principal: "user:flynn"
      )
    end)

    assert {:stop, bound} = bind(ctx.db, row.processId)
    assert bound.state == "stop_requested"
    assert bound.stopCause == "session_retired"
    assert bound.releaseGrantedAt == nil
  end

  test "a bind against an already-terminal row loses and reports the durable state", ctx do
    row = preparing(ctx.db)

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        row.processId,
        [state: "preparing", revision: 1],
        %{state: "launch_failed", last_error: "spawn refused", resolved_at: 2_000, now: 2_000}
      )
    end)

    assert {:lost, current} = bind(ctx.db, row.processId)
    assert current.state == "launch_failed"
    assert current.osPid == nil
  end

  test "the captured generation is the fence generation at insert", ctx do
    assert tx!(ctx.db, &ManagedProcesses.current_generation_in_txn(&1, "agent:fresh")) == 0

    tx!(ctx.db, fn txn ->
      ManagedProcesses.open_fence_in_txn(txn, "agent:fresh",
        retirement_epoch: 1_000,
        principal: "user:flynn"
      )
    end)

    assert tx!(ctx.db, &ManagedProcesses.current_generation_in_txn(&1, "agent:fresh")) == 1
  end

  ## process-reconcile (§B4) — the repair every blocked answer must name

  defp reconcile(db, process_id, evidence, now) do
    tx!(db, fn txn ->
      ManagedProcesses.reconcile_in_txn(txn, process_id, evidence: evidence, now: now)
    end)
  end

  # §B4: reconcile settles the lease itself and "never waits for a separate
  # sweeper to make this decision".
  test "reconcile settles an expired lease in its own transaction", ctx do
    row = preparing(ctx.db, %{lease_expires_at: 2_000})

    assert {:blocked, settled} = reconcile(ctx.db, row.processId, :not_probed, 5_000)
    assert settled.state == "launch_cancel_requested"
    assert settled.stopCause == "lease_expired"
  end

  test "reconcile leaves a live lease alone and reports the deadline to look again", ctx do
    row = preparing(ctx.db, %{lease_expires_at: 60_000})

    assert {:blocked, still} = reconcile(ctx.db, row.processId, :not_probed, 5_000)
    assert still.state == "preparing"
    assert still.stopCause == nil
    assert still.launchDeadline == 10_000
  end

  # §B4/§B5: only PROVEN absence terminalizes a launch. A deadline alone never
  # fabricates it — that is the difference between detecting the event and
  # guessing from a timeout.
  test "proven absence terminalizes a launch, and a deadline alone does not", ctx do
    timed_out = preparing(ctx.db)
    assert {:blocked, _} = reconcile(ctx.db, timed_out.processId, :not_probed, 50_000)
    assert ManagedProcesses.get(ctx.db, timed_out.processId).state == "preparing"

    assert {:ok, failed} = reconcile(ctx.db, timed_out.processId, :absent, 50_000)
    assert failed.state == "launch_failed"
    # launch_timeout is a typed LAST ERROR, not a stop cause: a launch that
    # never started has nothing to stop. The table's CHECK refuses the confusion.
    assert failed.lastError == "launch_timeout"
    assert failed.stopCause == nil
    assert failed.resolvedAt == 50_000
  end

  test "proven absence on a cancelled launch records launch_canceled with its cause", ctx do
    row = preparing(ctx.db)

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        row.processId,
        [state: "preparing", revision: 1],
        %{state: "launch_cancel_requested", stop_cause: "owner_stop", now: 2_000}
      )
    end)

    assert {:ok, canceled} = reconcile(ctx.db, row.processId, :absent, 6_000)
    assert canceled.state == "launch_canceled"
    assert canceled.stopCause == "owner_stop"
  end

  # §B3: identity_unknown may remain unresolved indefinitely. It is a
  # fail-closed RESULT, not a failure, and repeating the repair must not
  # invent progress.
  test "unknown evidence stays unresolved however often it is reconciled", ctx do
    row = preparing(ctx.db)

    for _ <- 1..3 do
      assert {:blocked, unresolved} = reconcile(ctx.db, row.processId, :unknown, 50_000)
      assert unresolved.state == "identity_unknown"
      assert unresolved.uncertaintyCause == "launch_handoff_unknown"
    end

    final = ManagedProcesses.get(ctx.db, row.processId)
    assert final.state == "identity_unknown"
    refute final.state in ManagedProcesses.terminal_states()
    assert ManagedProcesses.blocks_retirement?(final)
  end

  test "unknown evidence preserves a stop cause it already carried", ctx do
    row = preparing(ctx.db)

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        row.processId,
        [state: "preparing", revision: 1],
        %{state: "launch_cancel_requested", stop_cause: "session_retired", now: 2_000}
      )
    end)

    assert {:blocked, unresolved} = reconcile(ctx.db, row.processId, :unknown, 6_000)
    assert unresolved.state == "identity_unknown"
    assert unresolved.stopCause == "session_retired"
  end

  # Verified identity routes back through the atomic bind, so the lease and
  # generation checks cannot be bypassed by arriving via reconcile.
  test "verified identity reconciles through the same atomic bind", ctx do
    live = preparing(ctx.db)
    live_token = ManagedProcesses.get(ctx.db, live.processId).launchToken

    assert {:ok, running} =
             reconcile(ctx.db, live.processId, {:identity, identity(live_token)}, 3_000)

    assert running.state == "running"
    assert running.releaseGrantedAt == 3_000

    expired = preparing(ctx.db, %{lease_expires_at: 2_000})

    expired_token = ManagedProcesses.get(ctx.db, expired.processId).launchToken

    assert {:blocked, stopped} =
             reconcile(ctx.db, expired.processId, {:identity, identity(expired_token)}, 5_000)

    assert stopped.state == "stop_requested"
    assert stopped.stopCause == "lease_expired"
    assert stopped.releaseGrantedAt == nil
  end

  test "reconciling a terminal row is a no-op that reports it", ctx do
    row = preparing(ctx.db)

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        row.processId,
        [state: "preparing", revision: 1],
        %{state: "exited", resolved_at: 2_000, now: 2_000}
      )
    end)

    assert {:ok, terminal} = reconcile(ctx.db, row.processId, :absent, 9_000)
    assert terminal.state == "exited"
    assert terminal.resolvedAt == 2_000
  end

  test "reconciling an unknown process id is refused, not invented", ctx do
    assert {:error, :unknown_process} = reconcile(ctx.db, "mp_nope", :absent, 1_000)
  end

  ## process-stop and the stop worker's outcome (§B4, §B5)

  defp request_stop(db, process_id, now, opts \\ []) do
    tx!(db, fn txn ->
      ManagedProcesses.request_stop_in_txn(txn, process_id, [now: now] ++ opts)
    end)
  end

  defp record_outcome(db, process_id, outcome, now, opts \\ []) do
    tx!(db, fn txn ->
      ManagedProcesses.record_stop_outcome_in_txn(txn, process_id, outcome, [now: now] ++ opts)
    end)
  end

  defp running_row(db) do
    row = preparing(db)
    assert {:running, bound} = bind(db, row.processId)
    bound
  end

  test "stopping a preparing row cancels the launch rather than pretending to signal", ctx do
    row = preparing(ctx.db)

    assert {:ok, stopped} = request_stop(ctx.db, row.processId, 4_000)
    assert stopped.state == "launch_cancel_requested"
    assert stopped.stopCause == "owner_stop"
    assert stopped.cancelRequestedAt == 4_000
  end

  test "stopping a running row requests a stop against its proven identity", ctx do
    bound = running_row(ctx.db)

    assert {:ok, stopping} = request_stop(ctx.db, bound.processId, 4_000)
    assert stopping.state == "stop_requested"
    assert stopping.stopCause == "owner_stop"
    assert stopping.osPid == 4242
  end

  # §B4: without a proven identity there is nothing safe to signal, so the
  # request becomes a durable cause on a row that STAYS unresolved.
  test "stopping an identity_unknown row records the cause and stays blocked", ctx do
    row = preparing(ctx.db)

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        row.processId,
        [state: "preparing", revision: 1],
        %{state: "identity_unknown", uncertainty_cause: "launch_handoff_unknown", now: 2_000}
      )
    end)

    assert {:blocked, blocked} = request_stop(ctx.db, row.processId, 4_000)
    assert blocked.state == "identity_unknown"
    assert blocked.stopCause == "owner_stop"
    assert blocked.uncertaintyCause == "launch_handoff_unknown"
    assert ManagedProcesses.blocks_retirement?(blocked)
  end

  # §B4: a second stop must not create a second logical request.
  test "stopping twice returns the existing request and issues no second one", ctx do
    bound = running_row(ctx.db)

    assert {:ok, first} = request_stop(ctx.db, bound.processId, 4_000)
    assert {:ok, again} = request_stop(ctx.db, bound.processId, 5_000)

    assert again.state == "stop_requested"
    assert again.revision == first.revision, "a second stop must not mutate the row again"
    assert again.stopAttemptCount == 0
  end

  # §B4: a retry from stop_failed increments a durable attempt count — how "we
  # tried again" is recorded WITHOUT duplicating the obligation.
  test "a retry from stop_failed increments the attempt count", ctx do
    bound = running_row(ctx.db)
    assert {:ok, _} = request_stop(ctx.db, bound.processId, 4_000)

    assert {:ok, failed} = record_outcome(ctx.db, bound.processId, :stop_failed, 5_000)
    assert failed.state == "stop_failed"
    assert failed.lastError == "signal_failed"
    assert failed.stopCause == "owner_stop"

    assert {:ok, retried} = request_stop(ctx.db, bound.processId, 6_000)
    assert retried.state == "stop_requested"
    assert retried.stopAttemptCount == 1
    assert retried.stopCause == "owner_stop", "the original cause survives the retry"
  end

  test "the worker's kill and exit outcomes are terminal and stop blocking retirement", ctx do
    for {outcome, expected} <- [killed: "killed", exited: "exited"] do
      bound = running_row(ctx.db)
      assert {:ok, _} = request_stop(ctx.db, bound.processId, 4_000)

      assert {:ok, done} = record_outcome(ctx.db, bound.processId, outcome, 5_000)
      assert done.state == expected
      assert done.resolvedAt == 5_000
      assert done.stopCause == "owner_stop"
      refute ManagedProcesses.blocks_retirement?(done)
    end
  end

  # §B5: identity_unknown from the worker preserves the request's stopCause and
  # records the identity problem SEPARATELY. Both facts are true at once.
  test "an unproven signal keeps the stop cause and records uncertainty apart", ctx do
    bound = running_row(ctx.db)
    assert {:ok, _} = request_stop(ctx.db, bound.processId, 4_000)

    assert {:ok, unknown} = record_outcome(ctx.db, bound.processId, :identity_unknown, 5_000)
    assert unknown.state == "identity_unknown"
    assert unknown.stopCause == "owner_stop"
    assert unknown.uncertaintyCause == "stop_signal_unproven"
    assert ManagedProcesses.blocks_retirement?(unknown)
  end

  # §B5's natural-exit-versus-stop row: the monitor may terminalize first, and a
  # later worker result must not reopen or overwrite that.
  test "a worker result against an already-terminal row loses", ctx do
    bound = running_row(ctx.db)
    assert {:ok, _} = request_stop(ctx.db, bound.processId, 4_000)

    assert {:ok, exited} = record_outcome(ctx.db, bound.processId, :exited, 5_000)
    assert exited.state == "exited"

    assert {:lost, current} = record_outcome(ctx.db, bound.processId, :killed, 6_000)
    assert current.state == "exited"
    assert current.resolvedAt == 5_000
  end

  test "stopping a terminal row reports it rather than reopening the obligation", ctx do
    bound = running_row(ctx.db)
    assert {:ok, _} = request_stop(ctx.db, bound.processId, 4_000)
    assert {:ok, _} = record_outcome(ctx.db, bound.processId, :killed, 5_000)

    assert {:ok, terminal} = request_stop(ctx.db, bound.processId, 7_000)
    assert terminal.state == "killed"
    assert terminal.resolvedAt == 5_000
  end

  ## Delivery evidence and the canary scan (§B6, acceptance 14/15/16/17)

  @canary_code "CANARY-ONE-TIME-CODE-8Q4Z"
  @canary_url "https://canary.example/device/CANARY-URL-7X2"

  defp consume(db, process_id, receipt, now \\ 4_000) do
    tx!(db, fn txn ->
      ManagedProcesses.consume_delivery_receipt_in_txn(txn, process_id, receipt, now: now)
    end)
  end

  test "a success receipt is recorded as a pointer and custody continues", ctx do
    bound = running_row(ctx.db)

    assert {:ok, row} =
             consume(ctx.db, bound.processId, %{
               result: :succeeded,
               delivery_evidence_id: "dlv_12345",
               provider_kind: "anthropic",
               event_kind: "device_code_emitted"
             })

    assert row.deliveryEvidenceId == "dlv_12345"
    assert row.deliveryResult == "succeeded"
    assert row.deliveryProviderKind == "anthropic"
    assert row.deliveryEventKind == "device_code_emitted"

    # A successful handoff is not a reason to stop a ceremony that is running.
    assert row.state == "running"
    assert row.stopCause == nil
  end

  # §B6: on failure custody KEEPS the process managed. "The delivery failed" and
  # "the process has stopped" are different facts, and only the second ends
  # custody — terminalizing here would end it on the strength of the wrong one.
  test "a failed or timed-out receipt does not terminalize the process", ctx do
    for result <- [:failed, :timed_out] do
      bound = running_row(ctx.db)

      assert {:ok, row} =
               consume(ctx.db, bound.processId, %{
                 result: result,
                 delivery_evidence_id: "dlv_#{result}",
                 provider_kind: "openai",
                 event_kind: "device_code_emitted"
               })

      assert row.deliveryResult == to_string(result)
      assert row.state == "running", "custody must survive a failed delivery"
      assert row.resolvedAt == nil
      assert ManagedProcesses.blocks_retirement?(row)
    end
  end

  test "the record refuses a delivery result outside the closed set", ctx do
    bound = running_row(ctx.db)

    # DB.transaction catches the raise and returns it, so assert on the value.
    assert {:error, %CaseClauseError{term: :probably_fine}} =
             DB.transaction(ctx.db, fn txn ->
               ManagedProcesses.consume_delivery_receipt_in_txn(
                 txn,
                 bound.processId,
                 %{result: :probably_fine, delivery_evidence_id: "dlv_x"},
                 now: 4_000
               )
             end)
  end

  # ACCEPTANCE 14 AND 17. Push canary values at every field a caller can reach,
  # then scan EVERY text column of the record for them. The columns are
  # enumerated from the table rather than hand-listed, so a column added later
  # is scanned automatically instead of quietly escaping this check.
  test "no canary value can reach any text column of the record", ctx do
    bound = running_row(ctx.db)

    # Everything a caller controls, carrying canaries.
    assert {:ok, _} =
             consume(ctx.db, bound.processId, %{
               result: :succeeded,
               delivery_evidence_id: "dlv_pointer_only",
               provider_kind: "anthropic",
               event_kind: "device_code_emitted"
             })

    # Read the revision BEFORE opening the transaction: calling `get/2` inside
    # one makes the DB GenServer call itself.
    current = ManagedProcesses.get(ctx.db, bound.processId)

    tx!(ctx.db, fn txn ->
      ManagedProcesses.transition(
        txn,
        bound.processId,
        [state: "running", revision: current.revision],
        %{last_error: "provider refused the request", now: 5_000}
      )
    end)

    columns = ManagedProcesses.text_columns(ctx.db)
    assert "commandDescriptor" in columns, "the scan must cover the descriptor"
    assert "lastError" in columns, "the scan must cover errors"

    for column <- columns do
      {:ok, rows} =
        DB.query(
          ctx.db,
          "SELECT COUNT(*) FROM managed_processes WHERE #{column} LIKE ?1 OR #{column} LIKE ?2",
          ["%" <> @canary_code <> "%", "%" <> @canary_url <> "%"]
        )

      assert rows == [[0]], "canary value reached managed_processes.#{column}"
    end
  end

  # The stronger half of the same rule: there is nowhere to PUT a secret, so it
  # cannot arrive by a route nobody thought to scan. A caller that tries is
  # refused by the writable set rather than silently accepted.
  test "the record has no field a secret could be written to", ctx do
    bound = running_row(ctx.db)

    for field <- [:one_time_code, :device_code, :url, :command, :env, :credential] do
      assert {:error, %ArgumentError{}} =
               DB.transaction(ctx.db, fn txn ->
                 ManagedProcesses.transition(
                   txn,
                   bound.processId,
                   [state: "running", revision: bound.revision],
                   %{field => @canary_code, now: 6_000}
                 )
               end)
    end

    refute Map.has_key?(ManagedProcesses.writable_fields(), :one_time_code)
    refute Map.has_key?(ManagedProcesses.writable_fields(), :command)
  end

  # REVIEW att_8017ebe7 F5. Binding pid/group/boot without the stored launch
  # token accepts any broker that can name a live process. Those three prove
  # "this process exists"; only the token proves "we launched it".
  test "a bind without the stored launch token proves nothing and is refused", ctx do
    row = preparing(ctx.db)

    assert {:unproven, unchanged} =
             tx!(ctx.db, fn txn ->
               ManagedProcesses.bind_identity_in_txn(
                 txn,
                 row.processId,
                 identity("tok_not_the_stored_one"),
                 now: 3_000
               )
             end)

    assert unchanged.state == "preparing"
    assert unchanged.osPid == nil, "an unproven identity must not be written"
    assert unchanged.releaseGrantedAt == nil
    assert ManagedProcesses.get(ctx.db, row.processId).revision == row.revision
  end

  test "a bind with a missing launch token is refused too", ctx do
    row = preparing(ctx.db)

    assert {:unproven, _} =
             tx!(ctx.db, fn txn ->
               ManagedProcesses.bind_identity_in_txn(txn, row.processId, identity(), now: 3_000)
             end)

    assert ManagedProcesses.get(ctx.db, row.processId).osPid == nil
  end

  # An identity that cannot prove it is ours is not evidence of anything: it
  # becomes uncertainty, never a bind and never an absence proof.
  test "reconcile treats an unproven identity as uncertainty, not proof", ctx do
    row = preparing(ctx.db)

    assert {:blocked, unresolved} =
             reconcile(ctx.db, row.processId, {:identity, identity("tok_wrong")}, 5_000)

    assert unresolved.state == "identity_unknown"
    assert unresolved.uncertaintyCause == "launch_handoff_unknown"
    assert unresolved.osPid == nil
    refute unresolved.state in ManagedProcesses.terminal_states()
  end
end
