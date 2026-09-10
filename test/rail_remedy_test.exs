defmodule Tightbeam.RailRemedyTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Archetypes,
    Assignments,
    ConnRegistry,
    DB,
    Dispatch,
    EventLog,
    Gateway,
    Idempotency,
    ModelCatalog,
    Org,
    RailRemedy,
    Roles,
    Rules,
    Wakes,
    WorkItems
  }

  setup do
    db = :"rail_remedy_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1)"
      )

    holder = session(db, "holder", "flynn", "claude", "coder")
    reviewer = session(db, "reviewer-session", "flynn", "claude", "reviewer")
    Roles.create!(db, "reviewer", "flynn", reviewer.session_key)

    # Canonicalize the tmp base: Darwin's System.tmp_dir!/0 sits under the /var
    # symlink (/var -> /private/var), and Containment.rail_profile/1 (the rail scratch
    # write-root) refuses uncanonical components, which fails the contained script
    # launch (error:1) instead of letting it return a clean deny.
    tmp_base = to_string(:string.trim(:os.cmd(~c(realpath #{System.tmp_dir!()}))))

    base_dir =
      Path.join(tmp_base, "tightbeam-remedy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base_dir, "identity/rules"))

    # Spawn readiness checks for an adapter under this base_dir. It used to resolve
    # to a sibling checkout that happened to exist on the developer's machine (#46),
    # so these spawn-remedy tests passed without ever staging one.
    for bin <- ["claude-agent-acp", "codex-acp"] do
      adapter = Path.join([base_dir, "adapters", "node_modules", ".bin", bin])
      File.mkdir_p!(Path.dirname(adapter))
      File.write!(adapter, "#!/bin/sh\nexit 0\n")
      File.chmod!(adapter, 0o755)
    end

    handlers =
      Gateway.handlers(%{
        db: db,
        wake_tick_ms: 1_000,
        credential_status: fn _provider -> :onboarded end,
        credential_kind: fn _provider -> :subscription end,
        patch_adapter: fn _harness, _path -> :ok end
      })

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Rules)
    end)

    %{db: db, base_dir: base_dir, handlers: handlers, holder: holder, reviewer: reviewer}
  end

  test "review notice retargets one pending unroutable attempt", ctx do
    assignment = notice_assignment(ctx, "retarget pending notice")

    assert %{outcome: "claimed-dispatched", producer_id: root_id} =
             fire_review_notice(ctx, assignment)

    first = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    reassessment = Wakes.get(ctx.db, first.notice_state["reassessment"]["wakeId"])
    assert Wakes.get(ctx.db, root_id).session_key == ctx.holder.session_key

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        ctx.holder.session_key
      ])

    main =
      session(
        ctx.db,
        Org.personal_session_key("flynn"),
        "flynn",
        "claude",
        "orchestrator"
      )

    assert :ok =
             RailRemedy.reconcile_notice(ctx.db, %{supervision_interval_ms: 1_000}, reassessment)

    episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

    assert [%{"wakeId" => recovery_id, "parentWakeId" => ^root_id} = recovery] =
             episode.notice_state["recoveries"]

    assert recovery["purpose"] == "routing-reconcile"
    assert recovery["cause"] == "target-unresolvable"
    assert Wakes.get(ctx.db, root_id).state == "canceled"
    assert %{state: "pending", session_key: target} = Wakes.get(ctx.db, recovery_id)
    assert target == main.session_key
  end

  test "rail remedy cancellation rejects unreserved tuples and episode mismatches", ctx do
    assignment = notice_assignment(ctx, "typed cancellation guards")
    %{producer_id: root_id} = fire_review_notice(ctx, assignment)
    first = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    first_reassessment_id = first.notice_state["reassessment"]["wakeId"]

    other_assignment = notice_assignment(ctx, "other cancellation episode")
    %{producer_id: other_root_id} = fire_review_notice(ctx, other_assignment)

    unreserved = %{
      wake_id: root_id,
      requester: %{kind: "process", id: "tightbeam:rail-remedy"},
      reason_kind: "target_unresolvable",
      causal_source: %{kind: "scheduler_delivery", id: root_id},
      outcome: %{kind: "no_replacement"}
    }

    assert {:ok, false} =
             DB.transaction(ctx.db, fn txn -> Wakes.cancel_in_txn(txn, unreserved) end)

    obligation_disposed = %{
      wake_id: root_id,
      requester: %{kind: "process", id: "tightbeam:rail-remedy"},
      reason_kind: "obligation_disposed",
      causal_source: %{kind: "assignment_transition", id: assignment.id},
      outcome: %{
        kind: "disposition",
        disposition_kind: "assignment_transition",
        disposition_id: assignment.id
      }
    }

    assert {:ok, false} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.cancel_in_txn(txn, obligation_disposed)
             end)

    superseded_with_replacement = %{
      wake_id: root_id,
      requester: %{kind: "process", id: "tightbeam:rail-remedy"},
      reason_kind: "superseded",
      causal_source: %{kind: "wake", id: root_id},
      outcome: %{
        kind: "replacement",
        replacement_wake_id: first_reassessment_id
      }
    }

    assert {:ok, false} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.cancel_in_txn(txn, superseded_with_replacement)
             end)

    cross_episode =
      put_in(unreserved, [:outcome], %{
        kind: "replacement",
        replacement_wake_id: other_root_id
      })

    assert {:ok, false} =
             DB.transaction(ctx.db, fn txn -> Wakes.cancel_in_txn(txn, cross_episode) end)

    satisfied_state = put_in(first.notice_state, ["need", "state"], "satisfied")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE rail_remedy_episodes SET noticeState=?3 WHERE statute=?1 AND subject=?2",
        ["completion-requires-review", assignment.id, JSON.encode!(satisfied_state)]
      )

    nonrequested =
      put_in(cross_episode, [:outcome, :replacement_wake_id], first_reassessment_id)

    assert {:ok, false} =
             DB.transaction(ctx.db, fn txn -> Wakes.cancel_in_txn(txn, nonrequested) end)

    assert Wakes.get(ctx.db, root_id).state == "pending"
    assert Wakes.get(ctx.db, other_root_id).state == "pending"
    assert Wakes.get(ctx.db, first_reassessment_id).state == "pending"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1",
               [root_id]
             )
  end

  test "failed-unknown notice creates one effects recovery without replay", ctx do
    assignment = notice_assignment(ctx, "unknown notice effect")

    assert %{producer_id: root_id} = fire_review_notice(ctx, assignment)
    episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    reassessment = Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])

    source_seq = mark_notice_turn(ctx.db, assignment.id, root_id, "failed_unknown")
    insert_repair_branch(ctx.db, assignment.id, source_seq, "delivered")
    insert_repair_branch(ctx.db, assignment.id, source_seq, "running")

    assert :ok =
             RailRemedy.reconcile_notice(ctx.db, %{supervision_interval_ms: 1_000}, reassessment)

    episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

    assert [%{"parentWakeId" => ^root_id, "wakeId" => recovery_id} = recovery] =
             episode.notice_state["recoveries"]

    assert recovery["purpose"] == "effects-reconcile"
    assert recovery["cause"] == "delivery-effect-unknown"
    assert Wakes.get(ctx.db, recovery_id).state == "pending"

    next_reassessment = Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               next_reassessment
             )

    final = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    assert length(final.notice_state["recoveries"]) == 1

    sibling_observations =
      Enum.filter(final.notice_state["observations"], fn observation ->
        observation["attemptId"] == root_id
      end)

    assert MapSet.new(sibling_observations, & &1["outcome"]) ==
             MapSet.new(~w(delivered outstanding terminal))

    assert Enum.all?(sibling_observations, fn observation ->
             Enum.all?(~w(delivered failed_unknown running), &(&1 in observation["states"]))
           end)
  end

  test "pending notice exposes cancellation and retry evidence without recovery", ctx do
    assignment = notice_assignment(ctx, "bounded retry review notice")
    %{producer_id: root_id} = fire_review_notice(ctx, assignment)
    episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    reassessment = Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])

    {:ok, outcomes} =
      DB.transaction(ctx.db, fn txn ->
        Wakes.delivery_outcomes_in_txn(txn, %{
          root_wake_id: root_id,
          recovery_wake_ids: [],
          assignment_id: assignment.id
        })
      end)

    assert [%{wake_id: ^root_id, cancellations: [], pending_retry?: false}] =
             outcomes.outstanding

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               reassessment
             )

    state = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state
    assert state["recoveries"] == []
    assert Enum.all?(state["observations"], &(&1["cancellations"] == []))
  end

  test "known failed notice creates one routing recovery", ctx do
    assignment = notice_assignment(ctx, "failed review notice")
    %{producer_id: root_id} = fire_review_notice(ctx, assignment)
    episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    reassessment = Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])
    mark_notice_turn(ctx.db, assignment.id, root_id, "failed")

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               reassessment
             )

    state = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state

    assert [%{"parentWakeId" => ^root_id, "wakeId" => recovery_id} = recovery] =
             state["recoveries"]

    assert recovery["purpose"] == "routing-reconcile"
    assert recovery["cause"] == "delivery-terminal"
    assert Wakes.get(ctx.db, recovery_id).state == "pending"

    mark_notice_turn(ctx.db, assignment.id, recovery_id, "failed")
    next_reassessment = Wakes.get(ctx.db, state["reassessment"]["wakeId"])

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               next_reassessment
             )

    next_state =
      RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state

    assert [%{"wakeId" => ^recovery_id}] = next_state["recoveries"]
    assert next_state["blocked"] == "accountable_owner_chain_exhausted"
    assert next_state["reassessment"] == nil
    assert {:ok, [[before_count]]} = DB.query(ctx.db, "SELECT count(*) FROM wakes")
    for _ <- 1..5, do: assert({:ok, :ok} = RailRemedy.reconcile_pending_episodes(ctx.db, 1_000))
    assert {:ok, [[^before_count]]} = DB.query(ctx.db, "SELECT count(*) FROM wakes")
  end

  test "failed recovery advances once to an active ancestor and never cycles", ctx do
    parent = session(ctx.db, "accountable-parent", "flynn", "claude", "orchestrator")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
        ctx.holder.session_key,
        parent.session_key
      ])

    assignment = notice_assignment(ctx, "ancestor recovery")
    %{producer_id: root} = fire_review_notice(ctx, assignment)
    mark_notice_turn(ctx.db, assignment.id, root, "failed")

    for recipient <- [ctx.holder.session_key, parent.session_key] do
      episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

      assert :ok =
               RailRemedy.reconcile_notice(
                 ctx.db,
                 %{supervision_interval_ms: 1_000},
                 Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])
               )

      state = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state
      recovery = List.last(state["recoveries"])
      assert recovery["recipient"] == recipient

      for _ <- 1..3 do
        pending = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

        assert :ok =
                 RailRemedy.reconcile_notice(
                   ctx.db,
                   %{supervision_interval_ms: 1_000},
                   Wakes.get(ctx.db, pending.notice_state["reassessment"]["wakeId"])
                 )

        next =
          RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state

        assert next["recoveries"] == state["recoveries"]
        assert Wakes.get(ctx.db, recovery["wakeId"]).state == "pending"
        refute next["blocked"] == "accountable_owner_chain_exhausted"
      end

      mark_notice_turn(ctx.db, assignment.id, recovery["wakeId"], "failed")
    end

    episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])
             )

    state = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state
    assert length(state["recoveries"]) == 2
    assert state["blocked"] == "accountable_owner_chain_exhausted"
    assert state["reassessment"] == nil
  end

  test "satisfied and terminal ancestor effects stay pending without competing successors", ctx do
    parent = session(ctx.db, "effects-parent", "flynn", "claude", "orchestrator")
    main = session(ctx.db, Org.personal_session_key("flynn"), "flynn", "claude", "orchestrator")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
        ctx.holder.session_key,
        parent.session_key
      ])

    for cause <- ~w(satisfied terminal) do
      {:ok, _} =
        DB.query(ctx.db, "UPDATE sessions SET state='active' WHERE sessionKey=?1", [
          parent.session_key
        ])

      assignment = notice_assignment(ctx, "pending effects #{cause}")
      %{producer_id: root} = fire_review_notice(ctx, assignment)
      mark_notice_turn(ctx.db, assignment.id, root, "failed_unknown")

      if cause == "satisfied" do
        insert_clean_review(ctx, assignment)
      else
        :ok = persist_terminal_race!(ctx.db, assignment.id, 2)
      end

      first = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

      assert :ok =
               RailRemedy.reconcile_notice(
                 ctx.db,
                 %{supervision_interval_ms: 1_000},
                 Wakes.get(ctx.db, first.notice_state["reassessment"]["wakeId"])
               )

      state = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state
      first_recovery = hd(state["recoveries"])["wakeId"]
      mark_notice_turn(ctx.db, nil, first_recovery, "failed")

      assert :ok =
               RailRemedy.reconcile_notice(
                 ctx.db,
                 %{supervision_interval_ms: 1_000},
                 Wakes.get(ctx.db, state["reassessment"]["wakeId"])
               )

      state = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state
      assert [_, ancestor] = state["recoveries"]
      assert ancestor["recipient"] == parent.session_key

      for _ <- 1..3 do
        current = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

        assert :ok =
                 RailRemedy.reconcile_notice(
                   ctx.db,
                   %{supervision_interval_ms: 1_000},
                   Wakes.get(ctx.db, current.notice_state["reassessment"]["wakeId"])
                 )

        next = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
        assert next.status == "live"
        assert next.notice_state["recoveries"] == state["recoveries"]
        assert Wakes.get(ctx.db, ancestor["wakeId"]).state == "pending"
      end

      {:ok, _} =
        DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
          parent.session_key
        ])

      current = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
      assert_effects_replacement_guards(ctx, assignment, current, ancestor, main)

      assert :ok =
               RailRemedy.reconcile_notice(
                 ctx.db,
                 %{supervision_interval_ms: 1_000},
                 Wakes.get(ctx.db, current.notice_state["reassessment"]["wakeId"])
               )

      next = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state
      assert [_, _, replacement] = next["recoveries"]
      assert replacement["parentWakeId"] == ancestor["wakeId"]
      assert replacement["recipient"] == main.session_key
      assert next["need"]["state"] == cause
      assert Wakes.get(ctx.db, ancestor["wakeId"]).state == "canceled"
      assert Wakes.get(ctx.db, replacement["wakeId"]).assignment_id == nil

      assert {:ok, [["target_unresolvable", "replacement"]]} =
               DB.query(
                 ctx.db,
                 "SELECT reasonKind,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
                 [ancestor["wakeId"]]
               )

      for _ <- 1..2 do
        current = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

        assert :ok =
                 RailRemedy.reconcile_notice(
                   ctx.db,
                   %{supervision_interval_ms: 1_000},
                   Wakes.get(ctx.db, current.notice_state["reassessment"]["wakeId"])
                 )

        assert RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state[
                 "recoveries"
               ] == next["recoveries"]
      end
    end
  end

  defp assert_effects_replacement_guards(ctx, assignment, episode, ancestor, main) do
    {:ok, before_count} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes", [])

    for variant <-
          ~w(healthy withdrawn wrong_purpose wrong_parent exhausted closed delivered queued running competing retry_pending retry_running wrong_tenant wrong_primary losing_transaction) do
      assert {:error, %RuntimeError{message: "discard isolated cancellation probe"}} =
               DB.transaction(ctx.db, fn txn ->
                 replacement =
                   Wakes.schedule_in_txn(txn, %{
                     session_key: main.session_key,
                     origin: "remedy:completion-requires-review",
                     prompt: "effects replacement guard probe",
                     due_at: System.system_time(:millisecond)
                   })

                 edge = %{
                   "wakeId" => replacement.wake_id,
                   "parentWakeId" => ancestor["wakeId"],
                   "purpose" => "effects-reconcile",
                   "recipient" => main.session_key
                 }

                 edge =
                   case variant do
                     "wrong_purpose" ->
                       Map.put(edge, "purpose", "routing-reconcile")

                     "wrong_parent" ->
                       Map.put(edge, "parentWakeId", episode.notice_state["root"]["wakeId"])

                     _ ->
                       edge
                   end

                 state =
                   Map.put(
                     episode.notice_state,
                     "recoveries",
                     episode.notice_state["recoveries"] ++ [edge]
                   )

                 state =
                   case variant do
                     "withdrawn" -> put_in(state, ["need", "state"], "withdrawn")
                     "exhausted" -> Map.put(state, "blocked", "accountable_owner_chain_exhausted")
                     _ -> state
                   end

                 DB.Txn.q(
                   txn,
                   "UPDATE rail_remedy_episodes SET noticeState=?2 WHERE subject=?1",
                   [assignment.id, JSON.encode!(state)]
                 )

                 if variant == "healthy",
                   do:
                     DB.Txn.q(txn, "UPDATE sessions SET state='active' WHERE sessionKey=?1", [
                       ancestor["recipient"]
                     ])

                 if variant == "closed",
                   do:
                     DB.Txn.q(
                       txn,
                       "UPDATE rail_remedy_episodes SET status='closed' WHERE subject=?1",
                       [assignment.id]
                     )

                 if variant in ~w(delivered queued running competing retry_pending retry_running) do
                   status =
                     if variant in ~w(retry_pending retry_running), do: "failed", else: variant

                   status = if status == "competing", do: "failed_unknown", else: status
                   seq = mark_notice_turn(txn, nil, ancestor["wakeId"], status)

                   if variant in ~w(retry_pending retry_running competing) do
                     Enum.reduce(
                       if(variant == "competing", do: [1, 2], else: [1]),
                       {seq, ancestor["wakeId"]},
                       fn attempt, {source_seq, predecessor} ->
                         retry =
                           Wakes.schedule_in_txn(txn, %{
                             session_key: main.session_key,
                             origin: "remedy:completion-requires-review",
                             prompt: "existing bounded effects retry",
                             due_at: System.system_time(:millisecond)
                           })

                         DB.Txn.q(
                           txn,
                           """
                           INSERT INTO wake_retry_attempts(wakeId,rootWakeId,predecessorWakeId,attempt,sourceTurnSeq,outcome,observedAt)
                           VALUES (?1,?2,?5,?4,?3,'pending',1)
                           """,
                           [retry.wake_id, ancestor["wakeId"], source_seq, attempt, predecessor]
                         )

                         if variant == "retry_running",
                           do: mark_notice_turn(txn, nil, retry.wake_id, "running")

                         child_seq =
                           if variant == "competing",
                             do:
                               mark_notice_turn(
                                 txn,
                                 nil,
                                 retry.wake_id,
                                 if(attempt == 1, do: "delivered", else: "running")
                               ),
                             else: source_seq

                         {child_seq, retry.wake_id}
                       end
                     )
                   end
                 end

                 if variant == "wrong_tenant" do
                   DB.Txn.q(
                     txn,
                     "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('other-effects-owner',0,1)",
                     []
                   )

                   DB.Txn.q(
                     txn,
                     "UPDATE sessions SET ownerUserId='other-effects-owner' WHERE sessionKey=?1",
                     [main.session_key]
                   )
                 end

                 if variant == "wrong_primary",
                   do:
                     DB.Txn.q(txn, "UPDATE wakes SET assignmentId=?2 WHERE wakeId=?1", [
                       replacement.wake_id,
                       assignment.id
                     ])

                 result =
                   Wakes.cancel_in_txn(txn, %{
                     wake_id: ancestor["wakeId"],
                     requester: %{kind: "process", id: "tightbeam:rail-remedy"},
                     reason_kind: "target_unresolvable",
                     causal_source: %{kind: "scheduler_delivery", id: ancestor["wakeId"]},
                     outcome: %{kind: "replacement", replacement_wake_id: replacement.wake_id}
                   })

                 if variant == "losing_transaction" do
                   assert result == true
                 else
                   assert result == false, variant
                 end

                 raise "discard isolated cancellation probe"
               end)

      assert {:ok, ^before_count} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes", [])
      assert Wakes.get(ctx.db, ancestor["wakeId"]).state == "pending"

      assert RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state ==
               episode.notice_state

      assert {:ok, [[0]]} =
               DB.query(ctx.db, "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1", [
                 ancestor["wakeId"]
               ])
    end
  end

  test "stale effects reassessment occurrence cannot replace a pending notice", ctx do
    assignment = notice_assignment(ctx, "stale effects occurrence")
    %{producer_id: root} = fire_review_notice(ctx, assignment)
    mark_notice_turn(ctx.db, assignment.id, root, "failed_unknown")
    insert_clean_review(ctx, assignment)
    initial = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               Wakes.get(ctx.db, initial.notice_state["reassessment"]["wakeId"])
             )

    current = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    stale = Wakes.get(ctx.db, current.notice_state["reassessment"]["wakeId"])

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE rail_remedy_episodes SET occurrence=occurrence+1 WHERE subject=?1",
        [assignment.id]
      )

    {:ok, before_wakes} = DB.query(ctx.db, "SELECT wakeId,state FROM wakes ORDER BY wakeId", [])

    assert_raise ArgumentError, "review remedy episode is not live", fn ->
      RailRemedy.reconcile_notice(ctx.db, %{supervision_interval_ms: 1_000}, stale)
    end

    assert {:ok, ^before_wakes} =
             DB.query(ctx.db, "SELECT wakeId,state FROM wakes ORDER BY wakeId", [])

    assert RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state ==
             current.notice_state
  end

  test "live bounded retry prevents a competing O2 recovery", ctx do
    assignment = notice_assignment(ctx, "existing rate limit retry")
    %{producer_id: root} = fire_review_notice(ctx, assignment)
    seq = mark_notice_turn(ctx.db, assignment.id, root, "failed")

    retry =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        origin: "remedy:completion-requires-review",
        prompt: "existing bounded retry",
        due_at: System.system_time(:millisecond),
        assignment_id: assignment.id
      })

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO wake_retry_attempts(wakeId,rootWakeId,predecessorWakeId,attempt,sourceTurnSeq,outcome,observedAt)
        VALUES (?1,?2,?2,1,?3,'pending',1)
        """,
        [retry.wake_id, root, seq]
      )

    episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])
             )

    final = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    assert final.notice_state["recoveries"] == []
    assert Wakes.get(ctx.db, retry.wake_id).state == "pending"
    retry_seq = mark_notice_turn(ctx.db, assignment.id, retry.wake_id, "queued")

    for status <- ~w(queued running delivered) do
      {:ok, _} = DB.query(ctx.db, "UPDATE turns SET status=?2 WHERE seq=?1", [retry_seq, status])
      episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

      assert :ok =
               RailRemedy.reconcile_notice(
                 ctx.db,
                 %{supervision_interval_ms: 1_000},
                 Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])
               )

      state = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state
      assert state["recoveries"] == []
    end

    final = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state

    assert Enum.any?(
             final["observations"],
             &(&1["attemptId"] == retry.wake_id and &1["outcome"] == "delivered")
           )
  end

  test "terminal retry recovery names the failed child and preserves unknown semantics", ctx do
    for status <- ~w(failed failed_unknown) do
      assignment = notice_assignment(ctx, "terminal retry #{status}")
      %{producer_id: root} = fire_review_notice(ctx, assignment)
      root_seq = mark_notice_turn(ctx.db, assignment.id, root, "failed")

      retry =
        Wakes.schedule(ctx.db, %{
          session_key: ctx.holder.session_key,
          origin: "remedy:completion-requires-review",
          prompt: "bounded retry",
          due_at: System.system_time(:millisecond),
          assignment_id: assignment.id
        })

      {:ok, _} =
        DB.query(
          ctx.db,
          """
          INSERT INTO wake_retry_attempts(wakeId,rootWakeId,predecessorWakeId,attempt,sourceTurnSeq,outcome,observedAt)
          VALUES (?1,?2,?2,1,?3,'failed',1)
          """,
          [retry.wake_id, root, root_seq]
        )

      mark_notice_turn(ctx.db, assignment.id, retry.wake_id, status)
      episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

      assert :ok =
               RailRemedy.reconcile_notice(
                 ctx.db,
                 %{supervision_interval_ms: 1_000},
                 Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])
               )

      state = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state
      assert [recovery] = state["recoveries"]
      assert recovery["parentWakeId"] == retry.wake_id

      assert recovery["purpose"] ==
               if(status == "failed_unknown", do: "effects-reconcile", else: "routing-reconcile")

      assert Enum.any?(state["observations"], &(&1["attemptId"] == root))
    end
  end

  test "withdrawal remains stopped through bootstrap and repeated refusal", ctx do
    assignment = notice_assignment(ctx, "explicit withdrawal")
    %{producer_id: root} = fire_review_notice(ctx, assignment)
    wake = Wakes.get(ctx.db, root)
    current = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

    assert {:ok, {:accepted_in_txn, _event, %{canceled: true}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.cancel_in_txn(txn, %{
                 wake_id: root,
                 expected_origin: wake.origin,
                 requester: %{kind: "session", id: ctx.holder.session_key},
                 reason_kind: "requester_withdrew",
                 causal_source: %{
                   kind: "verb_call",
                   accepted_event: %{
                     origin: wake.origin,
                     session_key: ctx.holder.session_key,
                     principal: {:session, ctx.holder.session_key}
                   }
                 },
                 outcome: %{
                   kind: "no_replacement",
                   liveness_trigger: %{
                     kind: "pending_wake",
                     id: current.notice_state["reassessment"]["wakeId"]
                   }
                 }
               })
             end)

    episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])
             )

    final = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    assert final.status == "closed"
    assert final.notice_state["need"]["state"] == "withdrawn"
    assert {:ok, :ok} = RailRemedy.reconcile_pending_episodes(ctx.db, 1_000)
    assert %{outcome: "notification-stopped"} = fire_review_notice(ctx, assignment)
    assert RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).occurrence == 1
  end

  test "satisfied occurrence closes and a later actual refusal opens the next occurrence", ctx do
    assignment = notice_assignment(ctx, "new result after satisfaction")
    fire_review_notice(ctx, assignment)
    episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    insert_clean_review(ctx, assignment)

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])
             )

    assert RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).status ==
             "closed"

    new_refs = [%{"repo" => "racter:/tmp/o2", "commit" => String.duplicate("b", 40)}]
    assert %{outcome: "claimed-dispatched"} = fire_review_notice(ctx, assignment, new_refs)
    next = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    assert next.occurrence == 2
    assert next.notice_state["need"]["resultRefs"] == new_refs
  end

  test "missing owner becomes routable without another refusal and bootstrap is idempotent",
       ctx do
    assignment = notice_assignment(ctx, "owner returns")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        ctx.holder.session_key
      ])

    assert %{outcome: "missing-owner"} = fire_review_notice(ctx, assignment)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='active' WHERE sessionKey=?1", [
        ctx.holder.session_key
      ])

    assert {:ok, :ok} = RailRemedy.reconcile_pending_episodes(ctx.db, 1_000)
    first = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    assert is_binary(first.notice_state["reassessment"]["wakeId"])
    assert {:ok, :ok} = RailRemedy.reconcile_pending_episodes(ctx.db, 1_000)
    assert RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id) == first
  end

  test "legacy producer is preserved as reconciliation context rather than replayed", ctx do
    assignment = notice_assignment(ctx, "legacy review custody")
    fire_review_notice(ctx, assignment)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE rail_remedy_episodes SET noticeState=NULL,producerKey=?2 WHERE subject=?1",
        [assignment.id, "asg_preserved_legacy"]
      )

    assert {:ok, :ok} = RailRemedy.reconcile_pending_episodes(ctx.db, 1_000)
    state = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state
    assert state["legacyProducer"] == "asg_preserved_legacy"
    assert state["root"]["purpose"] == "legacy-reconcile"
    assert {:ok, :ok} = RailRemedy.reconcile_pending_episodes(ctx.db, 1_000)

    assert RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state ==
             state
  end

  test "satisfied unknown effects keep an owner-scoped check until recovery delivery", ctx do
    assignment = notice_assignment(ctx, "satisfied with unknown effect")
    %{producer_id: root} = fire_review_notice(ctx, assignment)
    mark_notice_turn(ctx.db, assignment.id, root, "failed_unknown")
    insert_clean_review(ctx, assignment)
    original = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               Wakes.get(ctx.db, original.notice_state["reassessment"]["wakeId"])
             )

    tracking = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    assert tracking.status == "live"
    assert tracking.notice_state["need"]["state"] == "satisfied"
    assert [%{"wakeId" => recovery}] = tracking.notice_state["recoveries"]
    assert Wakes.get(ctx.db, recovery).assignment_id == nil
    check = Wakes.get(ctx.db, tracking.notice_state["reassessment"]["wakeId"])
    assert check.assignment_id == nil
    mark_notice_turn(ctx.db, nil, recovery, "delivered")
    assert :ok = RailRemedy.reconcile_notice(ctx.db, %{supervision_interval_ms: 1_000}, check)
    final = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    assert final.status == "closed"
    assert final.notice_state["reassessment"] == nil
    assert final.notice_state["recoveries"] == tracking.notice_state["recoveries"]
    assert Enum.any?(final.notice_state["observations"], &("failed_unknown" in &1["states"]))
  end

  test "bootstrap uses the configured supervision interval rather than scheduler tick", ctx do
    assignment = notice_assignment(ctx, "interval configuration")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        ctx.holder.session_key
      ])

    assert %{outcome: "missing-owner"} = fire_review_notice(ctx, assignment)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='active' WHERE sessionKey=?1", [
        ctx.holder.session_key
      ])

    name = :"o2_interval_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Wakes,
       [
         name: name,
         db: ctx.db,
         tick_ms: 60_000,
         review_remedy_interval_ms: 4_321,
         deliver: fn _ -> :ok end,
         internal_consumers: %{"review_remedy_reconcile" => fn _ -> flunk("not due") end}
       ]}
    )

    before = System.system_time(:millisecond)
    assert :ok = Wakes.fire_due(name)
    state = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id).notice_state
    assert state["intervalMs"] == 4_321
    assert state["reassessment"]["dueAt"] >= before + 4_321
    assert state["reassessment"]["dueAt"] <= System.system_time(:millisecond) + 4_321
  end

  test "scheduler restart retains one exact pending reassessment and no duplicate notice", ctx do
    assignment = notice_assignment(ctx, "restart protocol")
    fire_review_notice(ctx, assignment)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET dueAt=dueAt+60000 WHERE assignmentId=?1", [assignment.id])

    episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    before = Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])
    name = :"o2_restart_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      db: ctx.db,
      tick_ms: 60_000,
      deliver: fn _ -> flunk("no prompt is due") end,
      internal_consumers: %{
        "review_remedy_reconcile" => fn wake ->
          RailRemedy.reconcile_notice(ctx.db, %{supervision_interval_ms: 1_000}, wake)
        end
      }
    ]

    for _ <- 1..2 do
      start_supervised!({Wakes, opts})
      assert :ok = Wakes.fire_due(name)
      assert Wakes.get(ctx.db, before.wake_id) == before
      assert RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id) == episode
      stop_supervised!(Wakes)
    end

    assert {:ok, [[2]]} =
             DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE assignmentId=?1", [assignment.id])
  end

  test "terminal producer tracks failed effects recovery to visible exhaustion", ctx do
    assignment = notice_assignment(ctx, "terminal unknown recovery")
    %{producer_id: root} = fire_review_notice(ctx, assignment)
    mark_notice_turn(ctx.db, assignment.id, root, "failed_unknown")

    :ok = persist_terminal_race!(ctx.db, assignment.id, 2)

    episode = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               Wakes.get(ctx.db, episode.notice_state["reassessment"]["wakeId"])
             )

    tracking = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    assert tracking.notice_state["need"]["state"] == "terminal"
    assert [%{"wakeId" => recovery}] = tracking.notice_state["recoveries"]
    mark_notice_turn(ctx.db, nil, recovery, "failed")

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               Wakes.get(ctx.db, tracking.notice_state["reassessment"]["wakeId"])
             )

    final = RailRemedy.episode(ctx.db, "completion-requires-review", assignment.id)
    assert final.status == "closed"
    assert final.notice_state["blocked"] == "accountable_owner_chain_exhausted"
    assert final.notice_state["reassessment"] == nil
    assert length(final.notice_state["recoveries"]) == 1
  end

  test "satisfied and terminal races dispose pending review work", ctx do
    satisfied = notice_assignment(ctx, "review wins before reassessment")
    %{producer_id: satisfied_root} = fire_review_notice(ctx, satisfied)
    satisfied_episode = RailRemedy.episode(ctx.db, "completion-requires-review", satisfied.id)

    satisfied_reassessment =
      Wakes.get(ctx.db, satisfied_episode.notice_state["reassessment"]["wakeId"])

    review_attest_id = insert_clean_review(ctx, satisfied)

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               satisfied_reassessment
             )

    satisfied_state =
      RailRemedy.episode(ctx.db, "completion-requires-review", satisfied.id).notice_state

    assert satisfied_state["need"]["state"] == "satisfied"
    assert satisfied_state["need"]["reviewAttestId"] == review_attest_id
    assert satisfied_state["reassessment"] == nil
    assert Wakes.get(ctx.db, satisfied_root).state == "canceled"

    terminal = notice_assignment(ctx, "terminal wins after first reassessment")
    %{producer_id: terminal_root} = fire_review_notice(ctx, terminal)
    first = RailRemedy.episode(ctx.db, "completion-requires-review", terminal.id)
    first_reassessment = Wakes.get(ctx.db, first.notice_state["reassessment"]["wakeId"])

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               first_reassessment
             )

    second = RailRemedy.episode(ctx.db, "completion-requires-review", terminal.id)
    second_reassessment = Wakes.get(ctx.db, second.notice_state["reassessment"]["wakeId"])

    :ok = persist_terminal_race!(ctx.db, terminal.id, System.system_time(:millisecond))

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               second_reassessment
             )

    terminal_state =
      RailRemedy.episode(ctx.db, "completion-requires-review", terminal.id).notice_state

    assert terminal_state["need"]["state"] == "terminal"
    assert terminal_state["reassessment"] == nil
    assert Wakes.get(ctx.db, terminal_root).state == "canceled"
  end

  test "non-code notice follows the latest independent ref-free conclusion", ctx do
    satisfied = notice_assignment(ctx, "non-code clean conclusion", "policy")
    %{producer_id: satisfied_root} = fire_review_notice(ctx, satisfied, :absent)
    satisfied_episode = RailRemedy.episode(ctx.db, "completion-requires-review", satisfied.id)

    satisfied_reassessment =
      Wakes.get(ctx.db, satisfied_episode.notice_state["reassessment"]["wakeId"])

    assert satisfied_episode.notice_state["need"]["resultRefs"] == nil
    mark_notice_turn(ctx.db, satisfied.id, satisfied_root, "delivered")
    clean_id = insert_review_conclusion(ctx, satisfied, "reviewed-clean", nil)

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               satisfied_reassessment
             )

    satisfied_state =
      RailRemedy.episode(ctx.db, "completion-requires-review", satisfied.id).notice_state

    assert satisfied_state["need"]["state"] == "satisfied"
    assert satisfied_state["need"]["reviewAttestId"] == clean_id

    contrary = notice_assignment(ctx, "non-code contrary conclusion", "policy")
    %{producer_id: contrary_root} = fire_review_notice(ctx, contrary, :absent)
    contrary_episode = RailRemedy.episode(ctx.db, "completion-requires-review", contrary.id)

    contrary_reassessment =
      Wakes.get(ctx.db, contrary_episode.notice_state["reassessment"]["wakeId"])

    mark_notice_turn(ctx.db, contrary.id, contrary_root, "delivered")
    insert_review_conclusion(ctx, contrary, "reviewed-clean", nil)
    insert_review_conclusion(ctx, contrary, "changes-requested", nil)

    assert :ok =
             RailRemedy.reconcile_notice(
               ctx.db,
               %{supervision_interval_ms: 1_000},
               contrary_reassessment
             )

    contrary_state =
      RailRemedy.episode(ctx.db, "completion-requires-review", contrary.id).notice_state

    assert contrary_state["need"]["state"] == "requested"
    assert contrary_state["need"]["reviewAttestId"] == nil
  end

  test "absent fact assigns under the remedy principal and actor closes after linked review",
       ctx do
    assignment = assignment(ctx, "original", "policy")
    load_review_gate(ctx)
    completion = completion_call(assignment.id)

    assert {:error,
            %{
              reason: "remedy_fired",
              producer: review_id,
              rule: "completion-needs-review"
            }} = Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert %{
             status: "live",
             producer_key: ^review_id,
             occurrence: 1,
             rewake_count: 0
           } = RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    review = assignment_row(ctx.db, review_id)
    assert review.reviewsAssignmentId == assignment.id
    assert review.openedByUser == "flynn"
    assert review.openedBySession == nil

    assert {:ok, [[principal]]} =
             DB.query(
               ctx.db,
               "SELECT principal FROM events WHERE verb = 'assign' AND kind = 'verb' ORDER BY id DESC LIMIT 1"
             )

    assert principal == "remedy:assign:completion-needs-review"

    verdict(ctx, review_id, "reviewed-clean")

    assert {:ok, %{assignment: %{state: "closed"}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert %{status: "closed"} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)
  end

  test "assign remedy preserves declared file metadata", ctx do
    assignment = assignment(ctx, "declared files")

    put_rules(
      ctx,
      String.replace(
        review_gate(),
        ~s(reviews = "{assignment_id}"),
        ~s(reviews = "{assignment_id}"\nfiles = ["lib/a.ex", "{assignment_id}"])
      )
    )

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error, %{reason: "remedy_fired", producer: review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert Enum.sort(Assignments.declared_files(ctx.db, review_id)) ==
             Enum.sort(["lib/a.ex", assignment.id])
  end

  test "declared recurrence suppression stops a repeat before another producer turn", ctx do
    assignment = assignment(ctx, "recurring")
    put_rules(ctx, review_gate() <> recurrence_declaration())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    first =
      completion_call(assignment.id)
      |> put_in([:params, :recurrence_receipt_id], "receipt-1")
      |> put_in([:params, :recurrence_sequence], 1)
      |> put_in([:params, :failure_class], "review-gate")
      |> put_in([:params, :failure_code], "missing-review")

    dispatch_key = "rail-dispatch:completion-needs-review:#{assignment.id}:1"

    # Crash specimen: persist the recurrence boundary, deliver the producer, then
    # simulate a crash before RailRemedy records the delivered target. The normal
    # retry must replay the same producer and finish the boundary without a second.
    assert :dispatch =
             Tightbeam.RecurrenceSuppression.prepare_first(
               ctx.db,
               %{
                 statute: "completion-needs-review",
                 subject: assignment.id,
                 receipt_id: "receipt-1"
               },
               dispatch_key
             )

    producer_call = %{
      verb: "assign",
      origin: "remedy:completion-needs-review",
      principal:
        {:remedy, %{statute: "completion-needs-review", action: "assign", owner: "flynn"}},
      session_key: ctx.reviewer.session_key,
      target_role: "reviewer",
      role_fallback: false,
      params: %{
        subject: "review #{assignment.id}",
        reviews_assignment_id: assignment.id,
        idempotency_key: dispatch_key
      }
    }

    assert {:ok, delivered_review} = Dispatch.dispatch(ctx.db, ctx.handlers, producer_call)

    assert {:error, %{producer: review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, first)

    assert review_id == delivered_review.id

    assert {:error, %{producer: ^review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, first)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wakes WHERE COALESCE(consumer, '') != 'effort_probe'"
             )

    assert %{rewake_count: 0} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    second =
      first
      |> put_in([:params, :recurrence_receipt_id], "receipt-2")
      |> put_in([:params, :recurrence_sequence], 2)

    assert {:error, %{producer: ^review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, second)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignments WHERE reviewsAssignmentId=?1",
               [assignment.id]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wakes WHERE COALESCE(consumer, '') != 'effort_probe'"
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM recurrence_suppression_events WHERE outcome='recurrence_repeat_suppressed'"
             )

    assert {:ok, [[target_session, "delivered", dispatch_key]]} =
             DB.query(
               ctx.db,
               "SELECT targetSession,state,dispatchKey FROM recurrence_suppression_deliveries"
             )

    assert target_session == ctx.reviewer.session_key
    assert dispatch_key == "rail-dispatch:completion-needs-review:#{assignment.id}:1"

    assert {:ok, [[^target_session]]} =
             DB.query(
               ctx.db,
               "SELECT targetSession FROM recurrence_suppression_episodes"
             )
  end

  test "replaying a first occurrence close leaves the second occurrence live", ctx do
    assignment = assignment(ctx, "reentered", "policy")
    [rule] = load_review_gate(ctx)
    completion = completion_call(assignment.id)

    assert {:error, %{producer: review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    verdict(ctx, review_id, "reviewed-clean")

    assert {:allow, [{"completion-needs-review", subject, occurrence}], []} =
             Rules.decide(ctx.db, completion)

    assert subject == assignment.id
    assert occurrence == 1
    assert RailRemedy.close(ctx.db, "completion-needs-review", subject, occurrence)

    assert %{outcome: "reopened-dispatched"} =
             RailRemedy.fire(ctx.db, ctx.handlers, rule, subject, completion)

    assert %{status: "live", occurrence: 2} =
             RailRemedy.episode(ctx.db, "completion-needs-review", subject)

    refute RailRemedy.close(ctx.db, "completion-needs-review", subject, occurrence)

    assert %{status: "live", occurrence: 2} =
             RailRemedy.episode(ctx.db, "completion-needs-review", subject)
  end

  test "remedy producer assign traverses dispatch and is denied by a script statute", ctx do
    assignment = assignment(ctx, "script-gated-producer")
    install_script_assign_gate!(ctx)
    put_rules(ctx, review_gate() <> script_assign_gate())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error,
            %{
              reason: "remedy_fired",
              producer: nil,
              rule: "completion-needs-review"
            }} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id) == nil

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = ?1",
               [assignment.id]
             )

    assert %{
             rule: "script-block-remedy-assign",
             edge: "verb",
             reason: "rule_denied",
             script_exit_class: "returned",
             origin: "remedy:completion-needs-review",
             principal: "remedy:assign:completion-needs-review"
           } =
             Enum.find(
               EventLog.rail_denials(ctx.db, 0, 10),
               &(&1.rule == "script-block-remedy-assign")
             )

    assert %{
             "verb" => "assign",
             "origin" => "remedy:completion-needs-review",
             "return" => "block",
             "exit_class" => "returned"
           } =
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.find(
               &(&1.kind == "rail_script" and &1.subject == "script-block-remedy-assign")
             )
             |> Map.fetch!(:detail)
             |> JSON.decode!()

    assert [%{"outcome" => "blocked", "producer_id" => nil}] = remedy_events(ctx.db)
  end

  test "surface policy returns a differently named nested rule denial without a producer", ctx do
    assignment = assignment(ctx, "surfaced-producer")
    put_rules(ctx, surfaced_review_gate() <> conditional_blocker())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error,
            %{
              reason: "remedy_blocked",
              producer: nil,
              rule: "conditional-remedy-blocker",
              ref: producer_id,
              message: message
            }} = Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert producer_id == assignment.id
    assert message == "conditional-remedy-blocker: runtime quota"
    assert RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id) == nil
    assert [%{"outcome" => "blocked", "producer_id" => nil}] = remedy_events(ctx.db)
  end

  test "TTL reclaim racing a live original dispatch produces exactly one external effect", ctx do
    assignment = assignment(ctx, "ttl")
    load_review_gate(ctx)
    parent = self()
    assign = ctx.handlers["assign"]

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    handlers =
      Map.put(ctx.handlers, "assign", fn call ->
        first? = Agent.get_and_update(counter, &{&1 == 0, &1 + 1})

        if first? do
          send(parent, {:original_dispatch_running, self()})
          receive do: (:release_original_dispatch -> :ok)
        end

        assign.(call)
      end)

    original =
      Task.async(fn ->
        Dispatch.dispatch(ctx.db, handlers, completion_call(assignment.id))
      end)

    # The handler only reaches this send after the remedy fires and dispatch has
    # written the episode, so the wait spans real DB work. Measured over 732 runs
    # on 12 concurrent BEAMs at `+S 2:2`: p50 3ms, p99 82ms, max 191ms -- the
    # 100ms assert_receive default sits inside that spread, which is why it flaked.
    assert_receive {:original_dispatch_running, original_pid}, 5_000

    stale = System.system_time(:millisecond) - 60_001

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE rail_remedy_episodes
        SET openedAt = ?2
        WHERE statute = 'completion-needs-review' AND subject = ?1 AND status = 'dispatched'
        """,
        [assignment.id, stale]
      )

    reclaimed =
      Task.async(fn ->
        Dispatch.dispatch(ctx.db, handlers, completion_call(assignment.id))
      end)

    assert {:error, %{producer: producer}} = Task.await(reclaimed)
    send(original_pid, :release_original_dispatch)
    assert {:error, %{producer: nil}} = Task.await(original)

    assert %{occurrence: 1, producer_key: ^producer, status: "live"} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = ?1",
               [assignment.id]
             )
  end

  test "spawn remedy TTL replay restores the original producer session", ctx do
    assignment = assignment(ctx, "spawn-replay")
    put_rules(ctx, spawn_remedy())
    handlers = spawn_handlers(ctx)
    Rules.load!(ctx.base_dir, Map.keys(handlers))

    assert {:error, %{producer: producer}} =
             Dispatch.dispatch(ctx.db, handlers, completion_call(assignment.id))

    stale = System.system_time(:millisecond) - 60_001

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE rail_remedy_episodes
        SET status = 'dispatched', producerKey = NULL, claimToken = 'crashed', openedAt = ?2
        WHERE statute = 'spawn-remedy' AND subject = ?1
        """,
        [assignment.id, stale]
      )

    assert {:error, %{producer: ^producer}} =
             Dispatch.dispatch(ctx.db, handlers, completion_call(assignment.id))

    assert %{status: "live", producer_key: ^producer, occurrence: 1} =
             RailRemedy.episode(ctx.db, "spawn-remedy", assignment.id)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM sessions WHERE handle = 'reviewer-new'", [])

    assert %{session_key: ^producer} =
             Idempotency.get(
               ctx.db,
               "flynn",
               "spawn",
               "rail-dispatch:spawn-remedy:#{assignment.id}:1"
             )
  end

  test "spawn reserve-then-act collapses racing remedy calls without handle uniqueness", ctx do
    handlers = spawn_handlers(ctx)
    spawn = handlers["spawn"]
    key = "rail-dispatch:spawn-race:subject:1"

    calls =
      for _ <- 1..8 do
        Task.async(fn ->
          spawn.(%{
            verb: "spawn",
            origin: "remedy:spawn-race",
            principal: {:remedy, %{statute: "spawn-race", action: "spawn", owner: "flynn"}},
            session_key: nil,
            params: %{
              display_name: "Unconstrained Racer",
              harness: "codex",
              model: "test",
              idempotency_key: key
            }
          })
        end)
      end

    session_keys = calls |> Enum.map(&Task.await(&1, 5_000).session_key) |> Enum.uniq()
    assert [_session_key] = session_keys

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM sessions WHERE displayName = 'Unconstrained Racer'",
               []
             )
  end

  test "wake remedy reclaims a retired target through its wake ledger row", ctx do
    assignment = assignment(ctx, "wake-reclaim")
    put_rules(ctx, wake_gate())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error, %{producer: producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    first_wake_id = producer
    first_key = "rail-dispatch:wake-remedy:#{assignment.id}:1"

    assert %{session_key: ^first_wake_id} =
             Idempotency.get(ctx.db, "remedy:wake-remedy", "wake", first_key)

    assert %{session_key: target_session} = Wakes.get(ctx.db, first_wake_id)
    assert target_session == ctx.reviewer.session_key

    Org.retire(ctx.db, target_session, "user:flynn", 1_000)

    assert {:error, %{producer: second_wake_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert %{status: "live", producer_key: ^second_wake_id, occurrence: 2} =
             RailRemedy.episode(ctx.db, "wake-remedy", assignment.id)

    second_key = "rail-dispatch:wake-remedy:#{assignment.id}:2"

    assert %{session_key: ^second_wake_id} =
             Idempotency.get(ctx.db, "remedy:wake-remedy", "wake", second_key)

    refute second_wake_id == first_wake_id
    assert %{session_key: second_target} = Wakes.get(ctx.db, second_wake_id)
    assert second_target == target_session
  end

  test "closed reopen and dead-live replacement bump occurrence and wire key", ctx do
    assignment = assignment(ctx, "terminal")
    load_review_gate(ctx)

    assert {:error, %{producer: first}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert RailRemedy.close(ctx.db, "completion-needs-review", assignment.id, 1)

    assert {:error, %{producer: second}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    refute second == first

    assert %{occurrence: 2} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    revoke(ctx, second)

    assert {:error, %{producer: third}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    refute third in [first, second]

    assert %{occurrence: 3} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    assert {:ok, [[3]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wire_idempotency WHERE operation = 'assign' AND idempotencyKey LIKE 'rail-dispatch:completion-needs-review:%'",
               []
             )
  end

  test "superseded claimant loses its fenced lease and does not add a producer", ctx do
    assignment = assignment(ctx, "fenced")
    load_review_gate(ctx)
    stale = System.system_time(:millisecond) - 60_001

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO rail_remedy_episodes
          (statute, subject, status, occurrence, rewakeCount, claimToken, openedAt)
        VALUES ('completion-needs-review', ?1, 'claimed', 1, 0, 'superseded', ?2)
        """,
        [assignment.id, stale]
      )

    assert {:error, %{producer: producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert {:ok, 0} =
             DB.transaction(ctx.db, fn txn ->
               DB.Txn.q(
                 txn,
                 """
                 UPDATE rail_remedy_episodes SET status = 'dispatched'
                 WHERE statute = 'completion-needs-review' AND subject = ?1
                   AND status = 'claimed' AND claimToken = 'superseded'
                 """,
                 [assignment.id]
               )

               DB.Txn.changes(txn)
             end)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = ?1 AND id = ?2",
               [assignment.id, producer]
             )
  end

  test "post-dispatch CAS loser returns quietly without reporting its producer", ctx do
    assignment = assignment(ctx, "post-dispatch-cas-loser")
    [rule] = load_review_gate(ctx)
    winner = "winner-producer"

    handlers =
      Map.put(ctx.handlers, "assign", fn _call ->
        assert {:ok, 1} =
                 DB.transaction(ctx.db, fn txn ->
                   DB.Txn.q(
                     txn,
                     """
                     UPDATE rail_remedy_episodes
                     SET status = 'live', producerKey = ?3
                     WHERE statute = ?1 AND subject = ?2 AND status = 'dispatched'
                     """,
                     [rule.name, assignment.id, winner]
                   )

                   DB.Txn.changes(txn)
                 end)

        %{id: "losing-producer"}
      end)

    assert %{outcome: "claimed-dispatched", producer_id: nil} =
             RailRemedy.fire(
               ctx.db,
               handlers,
               rule,
               assignment.id,
               completion_call(assignment.id)
             )

    assert %{status: "live", producer_key: ^winner, occurrence: 1} =
             RailRemedy.episode(ctx.db, rule.name, assignment.id)
  end

  test "denied producer dispatch releases the lease and the next edge retries", ctx do
    assignment = assignment(ctx, "retry")
    load_review_gate(ctx)
    parent = self()

    denied_handlers =
      Map.put(ctx.handlers, "assign", fn call ->
        send(parent, {:assign_attempt, call.params.idempotency_key})
        %{code: "runtime_blocker"}
      end)

    assert {:error, %{reason: "remedy_fired"}} =
             Dispatch.dispatch(ctx.db, denied_handlers, completion_call(assignment.id))

    assert RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id) == nil
    assert_received {:assign_attempt, _}

    assert {:error, %{reason: "remedy_fired"}} =
             Dispatch.dispatch(ctx.db, denied_handlers, completion_call(assignment.id))

    assert_received {:assign_attempt, _}

    assert Enum.count(remedy_events(ctx.db), &(&1["outcome"] == "blocked")) == 2
  end

  test "multi-statute actor closure closes only the statute that passed", ctx do
    assignment = assignment(ctx, "multi")
    put_rules(ctx, two_external_gates())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    now = System.system_time(:millisecond)

    for statute <- ["s1", "s2"] do
      {:ok, _} =
        DB.query(
          ctx.db,
          """
          INSERT INTO rail_remedy_episodes
            (statute, subject, status, producerKey, occurrence, rewakeCount, claimToken, openedAt)
          VALUES (?1, ?2, 'live', 'reviewer-session', 1, 0, ?1, ?3)
          """,
          [statute, assignment.id, now]
        )
    end

    assert %{attest: %{verdictKind: "s1-clean"}} = verdict(ctx, assignment.id, "s1-clean")
    assert {"s1-clean"} = {hd(Assignments.verdict_kinds(ctx.db, assignment.id))}

    assert {:error, %{rule: "s2"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert %{status: "closed"} = RailRemedy.episode(ctx.db, "s1", assignment.id)
    assert %{status: "live"} = RailRemedy.episode(ctx.db, "s2", assignment.id)
  end

  test "live episode re-wakes with a fresh occurrence-plus-counter key", ctx do
    assignment = assignment(ctx, "rewake")
    load_review_gate(ctx)
    reviewer_key = ctx.reviewer.session_key

    assert {:error, %{producer: producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert {:error, %{producer: ^producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert {:error, %{producer: ^producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert %{producer_key: ^producer, rewake_count: 2} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wire_idempotency WHERE operation = 'wake' AND idempotencyKey LIKE 'rail-rewake:completion-needs-review:%'",
               []
             )

    assert {:ok, [[^reviewer_key]]} =
             DB.query(
               ctx.db,
               """
               SELECT DISTINCT w.sessionKey
               FROM wire_idempotency i
               JOIN wakes w ON w.wakeId = i.sessionKey
               WHERE i.operation = 'wake'
                 AND i.idempotencyKey LIKE 'rail-rewake:completion-needs-review:%'
               """,
               []
             )
  end

  test "foreign linked verdict keeps the re-wake on the pending review holder", ctx do
    assignment = assignment(ctx, "foreign verdict")
    load_review_gate(ctx)

    assert {:error, %{producer: review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    verdict_from(ctx, ctx.holder.session_key, review_id, "reviewed-clean")

    assert {:error, %{producer: ^review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert latest_rewake_target(ctx, assignment.id) == ctx.reviewer.session_key
  end

  test "clean verdict on the latest linked card satisfies a stale review episode", ctx do
    assignment = assignment(ctx, "extra linked card", "policy")
    load_review_gate(ctx)

    assert {:error, %{producer: _review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    extra_review = linked_review(ctx, assignment.id, "extra review")
    verdict(ctx, extra_review.id, "reviewed-clean")

    assert {:ok, %{assignment: %{state: "closed", outcome: "completed"}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))
  end

  test "sole linked card holder verdict redirects the re-wake to the producer holder", ctx do
    assignment = assignment(ctx, "holder verdict")
    load_review_gate(ctx)

    assert {:error, %{producer: review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    verdict(ctx, review_id, "changes-requested")

    assert {:error, %{producer: ^review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert latest_rewake_target(ctx, assignment.id) == ctx.holder.session_key
  end

  test "unbound role and token fail closed without dispatch", ctx do
    assignment = assignment(ctx, "unbound")
    :ok = Roles.rm(ctx.db, "reviewer")
    load_review_gate(ctx)

    assert {:error, %{reason: "remedy_fired", producer: nil}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id) == nil
    assert List.last(remedy_events(ctx.db))["outcome"] == "unbound"

    put_rules(
      ctx,
      String.replace(review_gate(), "review {assignment_id}", "review {work_item_id}")
    )

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error, %{reason: "remedy_fired", producer: nil}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert List.last(remedy_events(ctx.db))["outcome"] == "unbound"
  end

  test "assign remedy principal is rejected by every non-assign assignment verb", ctx do
    principal =
      {:remedy, %{statute: "completion-needs-review", action: "assign", owner: "flynn"}}

    expected = %{
      code: "process_denied",
      message: "process principals cannot use assignment verbs"
    }

    calls = [
      {"attest", %{principal: principal, params: %{assignment_id: "missing"}}},
      {"revoke-assignment", %{principal: principal, params: %{assignment_id: "missing"}}},
      {"assignments", %{principal: principal, session_key: ctx.holder.session_key, params: %{}}},
      {"assignment-get", %{principal: principal, params: %{assignment_id: "missing"}}},
      {"attests", %{principal: principal, params: %{assignment_id: "missing"}}}
    ]

    Enum.each(calls, fn {verb, call} ->
      assert Assignments.__handle__(ctx.db, verb, call) == expected
    end)
  end

  test "remedy grammar and F1/F2 reject dead rail sets while conditional blockers load", ctx do
    put_rules(
      ctx,
      String.replace(review_gate(), ~s(produces = "reviewed-clean"), ~s(produces = "other"))
    )

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "completion-needs-review"
    assert error.message =~ "does not require"

    # D2: an artifact-gated remedy loads WITHOUT produces — the requirement is
    # statically satisfiable (artifact-record is constitutional) — and escapes
    # the F2 chain walk even where a verdict-gated shape would cycle.
    put_rules(ctx, artifact_gate())
    assert [_] = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    # produces stays verdict-only: an artifact-only gate must omit it.
    put_rules(
      ctx,
      String.replace(
        artifact_gate(),
        "action = \"wake\"",
        ~s(action = "wake"\nproduces = "verified")
      )
    )

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "valid only on a verdict-fact gate"

    # A verdict-gated remedy still requires produces.
    put_rules(
      ctx,
      String.replace(review_gate(), ~s(produces = "reviewed-clean"\n), "")
    )

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "must be a verdictKind required by the gate"

    put_rules(ctx, external_missing_gate())

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "F1"
    assert error.message =~ "missing-producer"

    put_rules(ctx, review_gate())
    error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["attest"]) end
    assert error.message =~ "F2"
    assert error.message =~ "completion-needs-review"
    assert error.message =~ "assign"

    put_rules(ctx, review_gate() <> pure_blocker())

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "completion-needs-review"
    assert error.message =~ "block-remedy-assign"

    put_rules(ctx, cycle_rules())

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "F2 producer cycle"
    assert error.message =~ "cycle-assign"
    assert error.message =~ "cycle-wake"

    put_rules(ctx, review_gate() <> conditional_blocker())
    assert [_gate, _blocker] = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assignment = assignment(ctx, "conditional")

    assert {:error, %{reason: "remedy_fired"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert List.last(remedy_events(ctx.db))["outcome"] == "blocked"
  end

  test "per-action remedy schema and interpolation typing fail at load", ctx do
    cases = [
      {String.replace(review_gate(), ~s(subject = "review {assignment_id}"\n), ""),
       "params are missing subject"},
      {wake_remedy(), "exactly one of target_role or target_session"},
      {String.replace(spawn_remedy(), ~s(model = "test"\n), ""), "missing model"},
      {String.replace(
         review_gate(),
         ~s(reviews = "{assignment_id}"),
         ~s(reviews = "review-{assignment_id}")
       ), "whole token or literal"},
      {String.replace(
         review_gate(),
         ~s(subject = "review {assignment_id}"),
         ~s(subject = "review {unknown}")
       ), "unknown binding token"},
      {String.replace(
         review_gate(),
         ~s(action = "assign"),
         ~s(action = "assign"\non_rule_denied = "retry")
       ), "on_rule_denied must be block or surface"},
      {"""
       [[rule]]
       name = "bad-external"
       verb = "attest"
       text = "bad"
       external_producer = true
       deny_when = [{ fact = "attest.kind", op = "eq", value = "completion" }]
       """, "valid only on a verdict-fact gate"}
    ]

    Enum.each(cases, fn {law, message} ->
      put_rules(ctx, law)

      error =
        assert_raise ArgumentError, fn ->
          Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
        end

      assert error.message =~ message
    end)
  end

  test "remedy rule-denial policy defaults to block and accepts explicit block", ctx do
    put_rules(ctx, review_gate())

    assert [%{remedy: %{on_rule_denied: "block"}}] =
             Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    put_rules(ctx, explicit_block_review_gate())

    assert [%{remedy: %{on_rule_denied: "block"}}] =
             Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
  end

  defp load_review_gate(ctx) do
    put_rules(ctx, review_gate())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
  end

  defp put_rules(ctx, contents) do
    File.write!(Path.join(ctx.base_dir, "identity/rules/remedy.toml"), contents)
  end

  defp review_gate do
    """
    [[rule]]
    name = "completion-needs-review"
    verb = "attest"
    text = "completion requires review"
    effect = "remedy"
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.effect_kind", op = "in", value = ["code", "policy", "release", "live_mutation"] },
      { fact = "assignment.qualifying_review_verdict_kinds", op = "not_in", value = ["reviewed-clean"] }
    ]
    [rule.remedy]
    action = "assign"
    produces = "reviewed-clean"
    target_role = "reviewer"
    [rule.remedy.params]
    subject = "review {assignment_id}"
    reviews = "{assignment_id}"
    """
  end

  defp recurrence_declaration do
    """

    [rule.recurrence_suppression]
    scope = "target_session_subject"
    fingerprint = ["statute", "target_session", "subject", "failure_class", "failure_code"]
    escalation_threshold = 3
    fallback = "operational_parent_then_main"

    [rule.recurrence_suppression.rearm]
    recovered_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    recurred_when = [{ fact = "caller.origin_class", op = "eq", value = "agent" }]
    """
  end

  defp explicit_block_review_gate do
    String.replace(
      review_gate(),
      ~s(action = "assign"),
      ~s(action = "assign"\non_rule_denied = "block")
    )
  end

  defp surfaced_review_gate do
    String.replace(
      review_gate(),
      ~s(action = "assign"),
      ~s(action = "assign"\non_rule_denied = "surface")
    )
  end

  defp script_assign_gate do
    """

    [[rule]]
    name = "script-block-remedy-assign"
    verb = "assign"
    text = "script blocks remedy assignment"
    [rule.check]
    script = "block-remedy-assign"
    returns = ["block"]
    [rule.check.effects]
    block = "deny"
    """
  end

  defp install_script_assign_gate!(ctx) do
    scripts = Path.join([ctx.base_dir, "identity", "rails", "scripts"])
    bin = Path.join(ctx.base_dir, "bin")
    File.mkdir_p!(scripts)
    File.mkdir_p!(bin)

    script = Path.join(scripts, "block-remedy-assign")

    File.write!(
      script,
      """
      #!/bin/sh
      IFS= read -r input
      case "$input" in
        *'"verb":"assign"'*) ;;
        *) exit 7 ;;
      esac
      case "$input" in
        *'"origin":"remedy:completion-needs-review"'*) ;;
        *) exit 8 ;;
      esac
      case "$input" in
        *'"principal":"remedy:assign:completion-needs-review"'*) printf block ;;
        *) exit 9 ;;
      esac
      """
    )

    File.chmod!(script, 0o755)

    wrapper = Path.join(bin, "tightbeam")
    File.cp!(Path.expand("fixtures/rail_exec/tightbeam", __DIR__), wrapper)
    File.chmod!(wrapper, 0o755)
  end

  defp artifact_gate do
    # verb "wake" with action "wake" would self-cycle in the F2 walk if the
    # artifact requirement did not make the statute escaping.
    """
    [[rule]]
    name = "artifact-gate"
    verb = "wake"
    text = "a results artifact is required"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.artifact_kinds", op = "not_in", value = ["report"] }
    ]
    [rule.remedy]
    action = "wake"
    target_session = "{holder_key}"
    [rule.remedy.params]
    prompt = "record the results artifact for {assignment_id}"
    """
  end

  defp external_missing_gate do
    """
    [[rule]]
    name = "missing-producer"
    verb = "attest"
    text = "review required"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    """
  end

  defp pure_blocker do
    """
    [[rule]]
    name = "block-remedy-assign"
    verb = "assign"
    text = "no remedies"
    deny_when = [
      { fact = "caller.origin_class", op = "eq", value = "remedy" }
    ]
    """
  end

  defp conditional_blocker do
    """
    [[rule]]
    name = "conditional-remedy-blocker"
    verb = "assign"
    text = "runtime quota"
    deny_when = [
      { fact = "caller.origin_class", op = "eq", value = "remedy" },
      { fact = "caller.verb_count_24h", op = "gte", value = 0 }
    ]
    """
  end

  defp cycle_rules do
    """
    [[rule]]
    name = "cycle-assign"
    verb = "assign"
    text = "assign gate"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    [rule.remedy]
    action = "wake"
    produces = "reviewed-clean"
    target_session = "holder"
    [rule.remedy.params]
    prompt = "review"
    after = 1

    [[rule]]
    name = "cycle-wake"
    verb = "wake"
    text = "wake gate"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    [rule.remedy]
    action = "assign"
    produces = "reviewed-clean"
    target_role = "reviewer"
    [rule.remedy.params]
    subject = "review"
    """
  end

  defp wake_remedy do
    """
    [[rule]]
    name = "wake-remedy"
    verb = "attest"
    text = "wake"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    [rule.remedy]
    action = "wake"
    produces = "reviewed-clean"
    target_role = "reviewer"
    target_session = "holder"
    [rule.remedy.params]
    prompt = "review {assignment_id}"
    """
  end

  defp wake_gate do
    """
    [[rule]]
    name = "wake-remedy"
    verb = "attest"
    text = "wake"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    [rule.remedy]
    action = "wake"
    produces = "reviewed-clean"
    target_session = "reviewer-session"
    [rule.remedy.params]
    prompt = "review {assignment_id}"
    after = 60000
    """
  end

  defp spawn_remedy do
    """
    [[rule]]
    name = "spawn-remedy"
    verb = "attest"
    text = "spawn"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    effect = "remedy"
    [rule.remedy]
    action = "spawn"
    produces = "reviewed-clean"
    name = "reviewer-new"
    harness = "codex"
    model = "test"
    [rule.remedy.params]
    display = "Reviewer {assignment_id}"
    """
  end

  defp two_external_gates do
    """
    [[rule]]
    name = "s1"
    verb = "attest"
    text = "s1"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["s1-clean"] }
    ]
    [rule.remedy]
    action = "assign"
    produces = "s1-clean"
    target_role = "reviewer"
    [rule.remedy.params]
    subject = "s1 review"

    [[rule]]
    name = "s2"
    verb = "attest"
    text = "s2"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["s2-clean"] }
    ]
    [rule.remedy]
    action = "assign"
    produces = "s2-clean"
    target_role = "reviewer"
    [rule.remedy.params]
    subject = "s2 review"
    """
  end

  defp notice_assignment(ctx, subject, effect_kind \\ "code") do
    work_item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        params: %{title: "notice recovery #{subject}"}
      })

    assignment_id = "asg_notice_#{System.unique_integer([:positive])}"

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO assignments
          (id,subject,holderKey,holderFallback,openedBySession,openedAt,workItemId,
           holderHarness,holderProvider)
        VALUES (?1,?2,?3,0,?3,?4,?5,'claude','anthropic')
        """,
        [
          assignment_id,
          subject,
          ctx.holder.session_key,
          System.system_time(:millisecond),
          work_item.id
        ]
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES (?1,?2)",
        [assignment_id, effect_kind]
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO assignment_priorities(assignmentId,priority) VALUES (?1,0)",
        [assignment_id]
      )

    assignment_row(ctx.db, assignment_id)
  end

  defp fire_review_notice(
         ctx,
         assignment,
         refs \\ notice_refs(),
         statute \\ "completion-requires-review"
       ) do
    params = if refs == :absent, do: %{}, else: %{commit_refs: refs}

    RailRemedy.fire(
      ctx.db,
      ctx.handlers,
      %{name: statute, remedy: %{action: "wake"}},
      assignment.id,
      %{
        verb: "attest",
        origin: "agent:#{ctx.holder.session_key}",
        params: params
      }
    )
  end

  defp notice_refs do
    [%{"repo" => "racter:/tmp/o2", "commit" => String.duplicate("a", 40)}]
  end

  defp mark_notice_turn(db, assignment_id, wake_id, status) do
    message_id = "msg_#{System.unique_integer([:positive])}"

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state='fired',firedAt=2 WHERE wakeId=?1", [
        wake_id
      ])

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO turns
          (sessionKey,messageId,wakeId,origin,prompt,assignmentId,status,createdAt,endedAt)
        SELECT sessionKey,?2,wakeId,origin,prompt,assignmentId,?3,1,2
        FROM wakes WHERE wakeId=?1 AND assignmentId IS ?4
        """,
        [wake_id, message_id, status, assignment_id]
      )

    {:ok, [[seq]]} = DB.query(db, "SELECT seq FROM turns WHERE messageId=?1", [message_id])
    seq
  end

  defp insert_repair_branch(db, assignment_id, source_seq, status) do
    message_id = "msg_#{System.unique_integer([:positive])}"
    ended_at = if status in ~w(delivered failed failed_unknown canceled), do: 4, else: nil

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO turns
          (sessionKey,messageId,origin,prompt,assignmentId,status,createdAt,endedAt)
        SELECT sessionKey,?2,origin,prompt,?3,?4,3,?5
        FROM turns WHERE seq=?1
        """,
        [source_seq, message_id, assignment_id, status, ended_at]
      )

    {:ok, [[attempt_seq]]} =
      DB.query(db, "SELECT seq FROM turns WHERE messageId=?1", [message_id])

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO turn_repair_attempts
          (id,repairKey,sourceSeq,attemptSeq,assignmentId,principal,createdAt)
        VALUES (?1,?2,?3,?4,?5,'agent:test',?6)
        """,
        [
          "tra_test_#{System.unique_integer([:positive])}",
          "repair_#{System.unique_integer([:positive])}",
          source_seq,
          attempt_seq,
          assignment_id,
          System.unique_integer([:positive])
        ]
      )
  end

  defp insert_clean_review(ctx, assignment) do
    insert_review_conclusion(ctx, assignment, "reviewed-clean", notice_refs())
  end

  defp insert_review_conclusion(ctx, assignment, kind, refs) do
    review = linked_review(ctx, assignment.id, "exact notice review")
    attest_id = "att_test_#{System.unique_integer([:positive])}"
    encoded_refs = if is_nil(refs), do: nil, else: JSON.encode!(refs)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO attests
          (id,assignmentId,kind,verdictKind,bySession,commitRefs,ts)
        VALUES (?1,?2,'verdict',?3,?4,?5,?6)
        """,
        [
          attest_id,
          review.id,
          kind,
          ctx.reviewer.session_key,
          encoded_refs,
          System.system_time(:millisecond)
        ]
      )

    attest_id
  end

  defp assignment(ctx, subject, effect_kind \\ "code") do
    Assignments.__handle__(ctx.db, "assign", %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: ctx.holder.session_key,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{subject: subject, idempotency_key: nil, effect_kind: effect_kind}
    })
  end

  defp linked_review(ctx, assignment_id, subject) do
    Assignments.__handle__(ctx.db, "assign", %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: ctx.reviewer.session_key,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{
        subject: subject,
        reviews_assignment_id: assignment_id,
        idempotency_key: nil
      }
    })
  end

  defp verdict(ctx, assignment_id, kind) do
    verdict_from(ctx, ctx.reviewer.session_key, assignment_id, kind)
  end

  defp verdict_from(ctx, session_key, assignment_id, kind) do
    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "agent:#{session_key}",
      principal: {:session, session_key},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: "verdict", verdict_kind: kind}
    })
  end

  defp latest_rewake_target(ctx, assignment_id) do
    {:ok, [[session_key]]} =
      DB.query(
        ctx.db,
        """
        SELECT w.sessionKey
        FROM wire_idempotency i
        JOIN wakes w ON w.wakeId = i.sessionKey
        WHERE i.operation = 'wake'
          AND i.idempotencyKey LIKE ?1
        ORDER BY w.createdAt DESC, w.wakeId DESC
        LIMIT 1
        """,
        ["rail-rewake:completion-needs-review:#{assignment_id}:%"]
      )

    session_key
  end

  defp revoke(ctx, assignment_id) do
    Assignments.__handle__(ctx.db, "revoke-assignment", %{
      verb: "revoke-assignment",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{assignment_id: assignment_id, reason: "test disposition"}
    })
  end

  defp completion_call(assignment_id) do
    %{
      verb: "attest",
      origin: "agent:holder",
      principal: {:session, "holder"},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: "completion"}
    }
  end

  defp assignment_row(db, id) do
    Assignments.__handle__(db, "assignment-get", %{
      principal: {:user, "flynn"},
      params: %{assignment_id: id}
    })
  end

  # Model a committed terminal row before its downstream reconciliation. Keep the
  # real audit and generation constraints; using the full revoke handler here
  # would consume the callback race that these three tests exercise.
  defp persist_terminal_race!(db, assignment_id, at) do
    revocation_id = "rev_race_#{System.unique_integer([:positive])}"

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               DB.Txn.q(
                 txn,
                 """
                 INSERT INTO assignment_revocations
                   (id, assignmentId, revokedAt, revokedByUser, reason)
                 VALUES (?1, ?2, ?3, 'flynn', 'synthetic terminal race')
                 """,
                 [revocation_id, assignment_id, at]
               )

               DB.Txn.q(
                 txn,
                 """
                 INSERT INTO assignment_revocation_generations
                   (revocationId, assignmentId, reopeningId)
                 VALUES (?1, ?2, NULL)
                 """,
                 [revocation_id, assignment_id]
               )

               DB.Txn.q(
                 txn,
                 """
                 UPDATE assignments SET state='closed', outcome='revoked',
                   closedAt=?2, closedByUser='flynn'
                 WHERE id=?1 AND state='open'
                 """,
                 [assignment_id, at]
               )

               assert DB.Txn.changes(txn) == 1
               :ok
             end)

    :ok
  end

  defp spawn_handlers(ctx) do
    auth_dir =
      Tightbeam.Homes.home_path(ctx.base_dir, Tightbeam.Placement.local_host_name(), :codex)

    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "auth.json"), "{}")
    Archetypes.load!(ctx.base_dir)
    start_model_catalog(ctx)
    start_conn_registry()

    Gateway.handlers(%{
      base_dir: ctx.base_dir,
      cwd: "/tmp",
      port: 0,
      default_harness: :codex,
      default_model: Model.new("test"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db,
      credential_status: fn _provider -> :onboarded end,
      credential_kind: fn _provider -> :subscription end,
      patch_adapter: fn _harness, _path -> :ok end
    })
  end

  defp start_conn_registry do
    if is_nil(Process.whereis(ConnRegistry)) do
      start_supervised!({ConnRegistry, name: ConnRegistry})
    end
  end

  defp start_model_catalog(ctx) do
    case Process.whereis(ModelCatalog) do
      nil ->
        start_supervised!(
          {ModelCatalog,
           base_dir: ctx.base_dir,
           db: ctx.db,
           credential_status: fn _provider -> :onboarded end,
           credential_kind: fn _provider -> :subscription end,
           credential_kind: fn _provider -> :subscription end,
           credential_kind: fn _provider -> :subscription end,
           claude_fetch: fn _, _ -> {:error, :unused} end,
           sh: fn _command ->
             catalog_reply(
               JSON.encode!(%{
                 models: [
                   %{
                     slug: "test",
                     display_name: "Test",
                     supported_reasoning_levels: []
                   }
                 ]
               })
             )
           end}
        )

        await_catalog()

      _pid ->
        :ok
    end
  end

  defp await_catalog(tries \\ 100)

  defp await_catalog(tries) when tries > 0 do
    case ModelCatalog.get(Tightbeam.Placement.local_host_name(), "codex", ModelCatalog) do
      {_, :fresh} -> :ok
      _ -> Process.sleep(5) && await_catalog(tries - 1)
    end
  end

  defp await_catalog(0), do: flunk("model catalog did not become fresh")

  defp remedy_events(db) do
    EventLog.lifecycle_events(db)
    |> Enum.filter(&(&1.kind == "rail_remedy"))
    |> Enum.map(&JSON.decode!(&1.detail))
  end

  defp session(db, key, owner, harness, archetype) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: archetype,
      host: Tightbeam.Placement.local_host_name(),
      harness: harness,
      provider: if(harness == "codex", do: "openai", else: "anthropic"),
      model: Model.new("test")
    })
  end
end
