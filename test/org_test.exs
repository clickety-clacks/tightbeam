defmodule Tightbeam.OrgTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  doctest Tightbeam.Org

  alias Tightbeam.{DB, Org, Roles, Wakes}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Tightbeam.Schema.ensure_all(name)
    %{db: name}
  end

  defp base(overrides \\ %{}) do
    Map.merge(
      %{
        display_name: "Main",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      },
      overrides
    )
  end

  test "create persists provenance, wire metadata, and boolean flags", %{db: db} do
    key = Org.personal_session_key("flynn")

    session =
      Org.create(db, base(%{session_key: key, kind: "main", is_built_in: true, adopted: true}))

    assert session.session_key == "agent:main:clawline:flynn:main"

    assert %{
             archetype: "default",
             identity_name: "default",
             overrides: nil,
             host: "testhost",
             provider: "anthropic",
             state: "active",
             is_built_in: true,
             adopted: true
           } = session

    assert Org.get(db, key).display_name == "Main"

    {:ok, rows} =
      DB.query(db, "SELECT isBuiltIn, adopted, state FROM sessions WHERE sessionKey = ?1", [key])

    assert rows == [[1, 1, "active"]]
  end

  test "overrides and derived identity names round-trip and active reconstruction ignores retired rows",
       %{
         db: db
       } do
    overrides = %{"skills_add" => ["review"], "guidance_extra" => "Be concise."}

    session =
      Org.create(
        db,
        base(%{
          session_key: "overridden",
          overrides: overrides,
          identity_name: "default--0123456789abcdef"
        })
      )

    assert session.overrides == overrides
    assert session.identity_name == "default--0123456789abcdef"
    assert Org.active_by_identity_name(db, session.identity_name).session_key == "overridden"

    {:ok, [[stored]]} =
      DB.query(db, "SELECT overrides FROM sessions WHERE sessionKey = 'overridden'")

    assert JSON.decode!(stored) == overrides

    updated = Org.set_identity(db, "overridden", nil, "default")
    assert updated.overrides == nil
    assert updated.identity_name == "default"
    refute Org.identity_name_exists?(db, "default--0123456789abcdef")

    retired =
      Org.create(
        db,
        base(%{session_key: "retired-id", identity_name: "default--fedcba9876543210"})
      )
      |> then(&Org.retire(db, &1.session_key, "user:flynn", 1_000))

    assert retired.state == "retired"
    assert Org.active_by_identity_name(db, retired.identity_name) == nil
    assert Org.identity_name_exists?(db, retired.identity_name)
  end

  test "custom keys use the TypeScript s_ suffix format", %{db: db} do
    session = Org.create(db, base())
    assert session.session_key =~ ~r/^agent:main:clawline:flynn:main s_[0-9a-f]{8}$/
  end

  test "organization settings put and get through the KV seam", %{db: db} do
    assert Org.get_setting(db, "default-archetype") == nil
    assert :ok = Org.put_setting(db, "default-archetype", "coder")
    assert Org.get_setting(db, "default-archetype") == "coder"

    assert :ok = Org.put_setting(db, "default-archetype", "reviewer")
    assert Org.get_setting(db, "default-archetype") == "reviewer"

    assert {:ok, [["default-archetype", "reviewer", updated_at]]} =
             DB.query(db, "SELECT key, value, updatedAt FROM org_settings")

    assert is_integer(updated_at)
  end

  test "session CLI tokens are unique, active-only, and indexed", %{db: db} do
    first = Org.create(db, base(%{session_key: "token-1"}))
    second = Org.create(db, base(%{session_key: "token-2"}))

    assert first.cli_token =~ ~r/^tbs_[A-Za-z0-9_-]{32}$/
    assert second.cli_token =~ ~r/^tbs_[A-Za-z0-9_-]{32}$/
    refute first.cli_token == second.cli_token
    assert Org.by_cli_token(db, first.cli_token).session_key == first.session_key
    assert Org.by_cli_token(db, "tbs_unknown") == nil

    Org.retire(db, first.session_key, "user:flynn", 1_000)
    assert Org.by_cli_token(db, first.cli_token) == nil

    {:ok, [[index_sql]]} =
      DB.query(
        db,
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'sessions_cli_token'"
      )

    assert index_sql =~ "UNIQUE INDEX"
  end

  test "list scopes active sessions by owner unless admin and preserves ordering", %{db: db} do
    Org.create(db, base(%{session_key: "k2", order_index: 2}))
    Org.create(db, base(%{session_key: "k1", order_index: 1}))
    Org.create(db, base(%{session_key: "sam", owner_user_id: "sam", origin: "user:sam"}))

    assert Enum.map(Org.list_for_user(db, "flynn", false), & &1.session_key) == ["k1", "k2"]
    assert length(Org.list_for_user(db, "flynn", true)) == 3

    retired = Org.retire(db, "k1", "user:flynn", 1_000)
    assert retired.state == "retired"
    assert Enum.map(Org.list_for_user(db, "flynn", false), & &1.session_key) == ["k2"]

    {:ok, [["retired"]]} = DB.query(db, "SELECT state FROM sessions WHERE sessionKey = 'k1'")
  end

  test "retirement cancels gated direct and role targets, replaces the role, and preserves ungated delivery",
       %{db: db} do
    main_key = Org.personal_session_key("flynn")
    Org.create(db, base(%{session_key: main_key, kind: "main", is_built_in: true}))
    Org.create(db, base(%{session_key: "retiring"}))
    Roles.create!(db, "reviewer", "flynn", "retiring")

    direct =
      Wakes.schedule(db, %{
        session_key: "retiring",
        origin: "user:flynn",
        prompt: "direct",
        due_at: 9_000
      })

    role =
      Wakes.schedule(db, %{
        session_key: "retiring",
        target_role: "reviewer",
        origin: "user:flynn",
        prompt: "role",
        due_at: 9_001
      })

    ungated =
      Wakes.schedule(db, %{
        session_key: "retiring",
        origin: "user:flynn",
        prompt: "ungated",
        due_at: 9_002,
        target_gate: 0
      })

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)
    assert %{state: "canceled"} = Wakes.get(db, direct.wake_id)

    assert %{
             requester: "tightbeam:retirement",
             reason: "target_retired",
             source_kind: "session_transition",
             source_id: "retiring",
             outcome: "no_replacement",
             replacement_wake_id: nil,
             work_impact: "no_linked_work",
             action_needed: 0
           } = cancellation(db, direct.wake_id)

    assert %{state: "canceled"} = Wakes.get(db, role.wake_id)

    assert %{
             requester: "tightbeam:retirement",
             reason: "target_retired",
             outcome: "replacement",
             replacement_wake_id: replacement_wake_id
           } = cancellation(db, role.wake_id)

    assert %{
             state: "pending",
             session_key: ^main_key,
             target_role: "reviewer",
             prompt: "role",
             due_at: 9_001
           } = Wakes.get(db, replacement_wake_id)

    assert %{state: "pending"} = Wakes.get(db, ungated.wake_id)
    assert cancellation(db, ungated.wake_id) == nil

    {:ok, [[wake_count]]} = DB.query(db, "SELECT count(*) FROM wakes")
    {:ok, [[cancellation_count]]} = DB.query(db, "SELECT count(*) FROM wake_cancellations")

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)
    assert {:ok, [[^wake_count]]} = DB.query(db, "SELECT count(*) FROM wakes")

    assert {:ok, [[^cancellation_count]]} =
             DB.query(db, "SELECT count(*) FROM wake_cancellations")
  end

  test "retirement validates its explicit caller context before state or wake mutation", %{db: db} do
    session = Org.create(db, base(%{session_key: "retiring"}))

    wake =
      Wakes.schedule(db, %{
        session_key: "retiring",
        origin: "user:flynn",
        prompt: "still pending",
        due_at: 9_000
      })

    for {principal, interval} <- [
          {"", 1_000},
          {nil, 1_000},
          {"user:flynn", 0},
          {"user:flynn", -1}
        ] do
      assert_raise ArgumentError, ~r/non-empty principal and positive supervision interval/, fn ->
        Org.retire(db, "retiring", principal, interval)
      end

      assert %{state: "active", updated_at: updated_at} = Org.get(db, "retiring")
      assert updated_at == session.updated_at
      assert Wakes.get(db, wake.wake_id).state == "pending"
      assert cancellation(db, wake.wake_id) == nil
    end
  end

  test "concurrent retirement commits one state transition and one cancellation carrier", %{
    db: db
  } do
    Org.create(db, base(%{session_key: "retiring"}))

    wake =
      Wakes.schedule(db, %{
        session_key: "retiring",
        origin: "user:flynn",
        prompt: "cancel once",
        due_at: 9_000
      })

    results =
      for _ <- 1..2 do
        Task.async(fn -> Org.retire(db, "retiring", "user:flynn", 1_000) end)
      end
      |> Task.await_many()

    assert Enum.all?(results, &(&1.state == "retired"))
    assert Wakes.get(db, wake.wake_id).state == "canceled"

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1", [
               wake.wake_id
             ])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM sessions WHERE sessionKey='retiring'")
  end

  test "retirement refuses and rolls back when linked open work has no surviving liveness", %{
    db: db
  } do
    Org.create(db, base(%{session_key: "retiring"}))

    :ok =
      DB.execute(
        db,
        "INSERT INTO work_items (id,title,ownerUserId,state,createdByUser,createdContextKnown,createdAt) VALUES ('orphan','orphan','flynn','open','flynn',0,1)"
      )

    wake =
      Wakes.schedule(db, %{
        session_key: "retiring",
        origin: "user:flynn",
        prompt: "linked",
        due_at: 9_000,
        work_item_id: "orphan"
      })

    assert_raise RuntimeError, ~r/no liveness trigger/, fn ->
      Org.retire(db, "retiring", "user:flynn", 1_000)
    end

    assert Org.get(db, "retiring").state == "active"
    assert Wakes.get(db, wake.wake_id).state == "pending"
    assert cancellation(db, wake.wake_id) == nil
  end

  test "spawned-by provenance is retained", %{db: db} do
    Org.create(db, base(%{session_key: "root", handle: "orchestrator:news"}))

    child =
      Org.create(
        db,
        base(%{
          session_key: "child",
          origin: "agent:orchestrator:news",
          spawned_by: "root",
          archetype: "reviewer",
          harness: "codex",
          provider: "openai",
          model: Model.new("gpt-5.6-sol", effort: "high")
        })
      )

    assert child.spawned_by == "root"
    assert child.provider == "openai"
  end

  test "rename and set_model update the row", %{db: db} do
    original = Org.create(db, base(%{session_key: "k1"}))
    renamed = Org.rename(db, "k1", "Renamed")
    selection = Model.new("claude-fable-5", effort: "high", context: "1m")
    updated = Org.set_model(db, "k1", selection, "anthropic")

    assert renamed.display_name == "Renamed"
    assert updated.model == selection
    assert updated.provider == "anthropic"
    assert updated.updated_at >= original.updated_at

    # The row holds the identity in COLUMNS. A context variant and a reasoning
    # level are different questions and never share a slot: stored packed, the
    # `1m` here would be indistinguishable from an effort named `1m`.
    {:ok, rows} =
      DB.query(db, """
      SELECT displayName, model, thinkingLevel, modelContext, provider
      FROM sessions WHERE sessionKey = 'k1'
      """)

    assert rows == [["Renamed", "claude-fable-5", "high", "1m", "anthropic"]]
  end

  test "pointer chain is append-only and current is latest", %{db: db} do
    Org.create(db, base(%{session_key: "k1"}))
    Org.append_pointer(db, "k1", "uuid-1", "created")
    Org.append_pointer(db, "k1", "uuid-2", "loaded")
    latest = Org.append_pointer(db, "k1", "uuid-3", "fallback")

    assert Org.current_pointer(db, "k1") == latest
    assert Enum.map(Org.pointer_chain(db, "k1"), & &1.reason) == ["created", "loaded", "fallback"]

    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(*) FROM harness_pointers WHERE sessionKey = 'k1'")

    assert count == 3
  end

  test "pointer persists canonical source session identity with reverse uniqueness", %{db: db} do
    Org.create(db, base(%{session_key: "k1"}))
    pointer = Org.append_pointer(db, "k1", "shared-harness-id", "created")

    assert pointer.harness == "claude"
    assert pointer.machine == "testhost"

    assert pointer.source_session_ref ==
             Org.source_session_ref("claude", "testhost", "shared-harness-id")

    Org.append_pointer(db, "k1", "shared-harness-id", "loaded")
    Org.create(db, base(%{session_key: "k2"}))

    assert_raise Tightbeam.DB.Error, ~r/already belongs to another parent/, fn ->
      Org.append_pointer(db, "k2", "shared-harness-id", "created")
    end
  end

  test "schema constraints reject invalid enums and duplicate handles", %{db: db} do
    assert_raise Tightbeam.DB.Error, ~r/CHECK constraint/, fn ->
      Org.create(db, base(%{session_key: "bad", harness: "other"}))
    end

    Org.create(db, base(%{session_key: "one", handle: "agent"}))

    assert_raise Tightbeam.DB.Error, ~r/UNIQUE constraint/, fn ->
      Org.create(db, base(%{session_key: "two", handle: "agent"}))
    end

    assert_raise ArgumentError, "unknown session: missing", fn ->
      Org.rename(db, "missing", "Nope")
    end
  end

  defp cancellation(db, wake_id) do
    case DB.query(
           db,
           """
           SELECT requesterId,reasonKind,causalSourceKind,causalSourceId,outcomeKind,
                  replacementWakeId,workImpactKind,actionNeeded
           FROM wake_cancellations WHERE wakeId=?1
           """,
           [wake_id]
         ) do
      {:ok, []} ->
        nil

      {:ok,
       [
         [
           requester,
           reason,
           source_kind,
           source_id,
           outcome,
           replacement_wake_id,
           work_impact,
           action_needed
         ]
       ]} ->
        %{
          requester: requester,
          reason: reason,
          source_kind: source_kind,
          source_id: source_id,
          outcome: outcome,
          replacement_wake_id: replacement_wake_id,
          work_impact: work_impact,
          action_needed: action_needed
        }
    end
  end

  ## Durable process custody (spec art_6817803a rev6 §B5, additive per att_4e52a5be)
  ##
  ## These live here rather than beside the fence module because the SUBJECT is
  ## retirement's observable behaviour. A reader asking "what does retiring a
  ## session do now" must find the answer in Org's own tests.

  alias Tightbeam.ManagedProcesses

  defp custody_session(db, key) do
    Org.create(db, base(%{session_key: key, display_name: key}))
  end

  defp retire_in_txn!(db, key) do
    {:ok, session} =
      DB.transaction(db, fn txn -> Org.retire_in_txn(txn, key, "user:flynn", 1_000) end)

    session
  end

  defp preparing_process(db, session_key) do
    attrs = %{
      process_id: "mp_#{System.unique_integer([:positive])}",
      owner_user_id: "flynn",
      owner_session_key: session_key,
      session_generation: 1,
      launch_turn_seq: nil,
      host: "testhost",
      purpose: "onboarding_ceremony",
      command_descriptor: "codex login (digest sha256:abcd)",
      launch_token: "tok_#{System.unique_integer([:positive])}",
      launch_deadline: 10_000,
      lease_expires_at: 60_000,
      now: 1_000
    }

    {:ok, {:ok, row}} = DB.transaction(db, &ManagedProcesses.insert_preparing(&1, attrs))
    row
  end

  # The ordinary case, and the one that must not change: a session owning no
  # managed process retires exactly as it did before durable custody existed.
  test "a session with no managed process still retires outright", %{db: db} do
    custody_session(db, "agent:plain")

    assert %{state: "retired"} = retire_in_txn!(db, "agent:plain")
    assert ManagedProcesses.fence(db, "agent:plain").state == "retired"
  end

  # §B5, acceptance 8 and 19. Reporting this session retired is the exact lie the
  # fence exists to prevent: a process nobody has proved anything about is still
  # out there, and `process-reconcile` is the repair.
  test "an unresolved process defers retirement and the session stays active", %{db: db} do
    custody_session(db, "agent:busy")
    row = preparing_process(db, "agent:busy")

    {:ok, _} =
      DB.transaction(db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "preparing", revision: 1],
          %{state: "identity_unknown", uncertainty_cause: "launch_handoff_unknown", now: 2_000}
        )
      end)

    assert %{state: "active"} = retire_in_txn!(db, "agent:busy")

    fence = ManagedProcesses.fence(db, "agent:busy")
    assert fence.state == "retiring"
    assert fence.finalizedAt == nil

    # The census installed retirement as the reason of record WITHOUT claiming
    # the process is gone: the uncertainty survives beside the stop cause.
    settled = ManagedProcesses.get(db, row.processId)
    assert settled.state == "identity_unknown"
    assert settled.stopCause == "session_retired"
    assert settled.uncertaintyCause == "launch_handoff_unknown"
  end

  # §B5, acceptance 23 and 24: once the last row terminalizes, an EXACT retry
  # finalizes, and a further retry is idempotent rather than a second retirement.
  test "an exact retry retires once the blocking row resolves", %{db: db} do
    custody_session(db, "agent:later")
    row = preparing_process(db, "agent:later")

    assert %{state: "active"} = retire_in_txn!(db, "agent:later")

    blocked = ManagedProcesses.get(db, row.processId)
    assert blocked.state == "launch_cancel_requested"
    assert blocked.stopCause == "session_retired"

    {:ok, _} =
      DB.transaction(db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "launch_cancel_requested", revision: blocked.revision],
          %{state: "launch_canceled", resolved_at: 7_000, now: 7_000}
        )
      end)

    assert %{state: "retired"} = retire_in_txn!(db, "agent:later")

    fence = ManagedProcesses.fence(db, "agent:later")
    assert fence.state == "retired"
    assert fence.generation == 1, "an exact retry must not open a second retirement"

    assert %{state: "retired"} = retire_in_txn!(db, "agent:later")
    assert ManagedProcesses.fence(db, "agent:later").generation == 1
  end

  # A deferred retirement leaves wakes ALONE. They still belong to a session that
  # is still running, and cancelling them would strand work the owner can still
  # reach after `process-reconcile` clears the block.
  test "a deferred retirement does not cancel the session's wakes", %{db: db} do
    custody_session(db, "agent:wakes")
    preparing_process(db, "agent:wakes")

    {:ok, _} =
      DB.transaction(db, fn txn ->
        Wakes.schedule_in_txn(txn, %{
          wake_id: "w_custody_defer",
          session_key: "agent:wakes",
          origin: "user:flynn",
          prompt: "still yours",
          due_at: 9_000_000
        })
      end)

    assert %{state: "active"} = retire_in_txn!(db, "agent:wakes")

    assert {:ok, [["pending"]]} =
             DB.query(db, "SELECT state FROM wakes WHERE wakeId = ?1", ["w_custody_defer"])
  end

  ## The reconcile that unblocks a retirement (§B5) — one transaction, not two
  ##
  ## Boot recovery below repairs a session whose last process settled while nothing
  ## finalized it. These prove the ordinary path never opens that window in the first
  ## place: the resolution and the retirement it releases commit together.

  test "resolving the last blocker retires its session in the same transaction", %{db: db} do
    custody_session(db, "agent:unblocks")
    row = preparing_process(db, "agent:unblocks")

    assert %{state: "active"} = retire_in_txn!(db, "agent:unblocks")
    assert ManagedProcesses.fence(db, "agent:unblocks").state == "retiring"

    blocked = ManagedProcesses.get(db, row.processId)

    Tightbeam.Gateway.reconcile_settled_for_test(
      db,
      row.processId,
      9_000,
      :absent,
      blocked.revision
    )

    assert ManagedProcesses.get(db, row.processId).state == "launch_canceled"

    # No second pass, no later boot: the fence closed with the row.
    assert ManagedProcesses.fence(db, "agent:unblocks").state == "retired"
    assert %{state: "retired"} = Org.get(db, "agent:unblocks")
  end

  # The other half of the compare-and-set, and the reason it is worth having: a
  # verdict computed before another transition must not release a retirement fence.
  # The row here MOVED after the probe — the session started retiring — so the stale
  # `absent` loses, and a session whose process nobody has proved anything about
  # stays exactly where it was.
  test "a reconcile that loses the compare-and-set releases no retirement fence", %{db: db} do
    custody_session(db, "agent:stale")
    row = preparing_process(db, "agent:stale")

    # Probe time: the evidence is gathered against this revision.
    probed_revision = ManagedProcesses.get(db, row.processId).revision

    # ...and then the row moves, because the session began retiring.
    assert %{state: "active"} = retire_in_txn!(db, "agent:stale")
    moved = ManagedProcesses.get(db, row.processId)
    assert moved.revision != probed_revision

    Tightbeam.Gateway.reconcile_settled_for_test(
      db,
      row.processId,
      9_000,
      :absent,
      probed_revision
    )

    # No outcome written...
    current = ManagedProcesses.get(db, row.processId)
    assert current.state == moved.state
    assert current.revision == moved.revision
    assert current.resolvedAt == nil

    # ...and no finalizer run.
    assert ManagedProcesses.fence(db, "agent:stale").state == "retiring"
    assert ManagedProcesses.fence(db, "agent:stale").finalizedAt == nil
    assert %{state: "active"} = Org.get(db, "agent:stale")
  end

  ## Boot recovery (§B5) — the restart pass that finishes what a crash left open

  # §B5, acceptance 24: an interrupted or legacy fixture whose session is
  # retiring and whose process rows are ALREADY terminal. Nothing further will
  # ever happen to those rows, so without this pass the session stays `retiring`
  # forever with no trigger left to finish it.
  test "boot recovery finalizes a session whose last process already terminalized", %{db: db} do
    custody_session(db, "agent:stranded")
    row = preparing_process(db, "agent:stranded")

    assert %{state: "active"} = retire_in_txn!(db, "agent:stranded")

    blocked = ManagedProcesses.get(db, row.processId)

    {:ok, _} =
      DB.transaction(db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "launch_cancel_requested", revision: blocked.revision],
          %{state: "launch_canceled", resolved_at: 7_000, now: 7_000}
        )
      end)

    # The crash: the process settled but nothing finalized the session.
    assert ManagedProcesses.fence(db, "agent:stranded").state == "retiring"
    assert %{state: "active"} = Org.get(db, "agent:stranded")

    {:ok, result} =
      DB.transaction(db, &Org.finalize_open_retirements_in_txn(&1, 9_000))

    assert result.retired == ["agent:stranded"]
    assert result.blocked == []
    assert %{state: "retired"} = Org.get(db, "agent:stranded")
    assert ManagedProcesses.fence(db, "agent:stranded").state == "retired"
  end

  # Running it twice must not retire anything twice, and must not raise. A
  # duplicate boot scan is ordinary, not an incident.
  test "boot recovery is idempotent across repeated scans", %{db: db} do
    custody_session(db, "agent:twice")
    row = preparing_process(db, "agent:twice")
    assert %{state: "active"} = retire_in_txn!(db, "agent:twice")

    blocked = ManagedProcesses.get(db, row.processId)

    {:ok, _} =
      DB.transaction(db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "launch_cancel_requested", revision: blocked.revision],
          %{state: "launch_canceled", resolved_at: 7_000, now: 7_000}
        )
      end)

    {:ok, first} = DB.transaction(db, &Org.finalize_open_retirements_in_txn(&1, 9_000))
    assert first.retired == ["agent:twice"]

    # Second scan: the fence is closed, so there is nothing left to visit.
    {:ok, second} = DB.transaction(db, &Org.finalize_open_retirements_in_txn(&1, 9_500))
    assert second.retired == []
    assert second.blocked == []
    assert %{state: "retired"} = Org.get(db, "agent:twice")
  end

  # §B3/§B5: an unresolved row keeps blocking across restarts. Boot recovery
  # must not "clean up" what it cannot prove.
  test "boot recovery leaves a session blocked while a row stays unresolved", %{db: db} do
    custody_session(db, "agent:unproven")
    row = preparing_process(db, "agent:unproven")

    {:ok, _} =
      DB.transaction(db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "preparing", revision: 1],
          %{state: "identity_unknown", uncertainty_cause: "launch_handoff_unknown", now: 2_000}
        )
      end)

    assert %{state: "active"} = retire_in_txn!(db, "agent:unproven")

    for now <- [9_000, 10_000, 11_000] do
      {:ok, result} = DB.transaction(db, &Org.finalize_open_retirements_in_txn(&1, now))
      assert result.blocked == ["agent:unproven"]
      assert result.retired == []
    end

    assert %{state: "active"} = Org.get(db, "agent:unproven")
    assert ManagedProcesses.fence(db, "agent:unproven").state == "retiring"

    still = ManagedProcesses.get(db, row.processId)
    assert still.state == "identity_unknown"
    assert still.stopCause == "session_retired"
  end

  test "the recovery scan returns every blocking row and no terminal one", %{db: db} do
    custody_session(db, "agent:scan-a")
    custody_session(db, "agent:scan-b")
    blocking_a = preparing_process(db, "agent:scan-a")
    blocking_b = preparing_process(db, "agent:scan-b")
    finished = preparing_process(db, "agent:scan-a")

    {:ok, _} =
      DB.transaction(db, fn txn ->
        ManagedProcesses.transition(
          txn,
          finished.processId,
          [state: "preparing", revision: 1],
          %{state: "exited", resolved_at: 2_000, now: 2_000}
        )
      end)

    {:ok, rows} = DB.transaction(db, &ManagedProcesses.recovery_rows_in_txn/1)
    ids = Enum.map(rows, & &1.processId)

    assert blocking_a.processId in ids
    assert blocking_b.processId in ids, "the scan must cross session boundaries"
    refute finished.processId in ids
  end

  test "finalizing a session that never retired reports no fence", %{db: db} do
    custody_session(db, "agent:never")

    assert {:ok, :no_fence} =
             DB.transaction(db, &Org.finalize_retiring_session_in_txn(&1, "agent:never", 1_000))
  end

  # REVIEW att_8017ebe7 F3. `retire_cascade_in_txn` reported every subtree
  # member as retired regardless of what Org actually did. Harmless until
  # custody made retirement deferrable — after which a session blocked on an
  # unresolved process was ANNOUNCED retired while its own row said active.
  # Everything downstream reads that list: the idempotency marker, the
  # stream_deleted broadcast telling clients the session is gone, the on_retired
  # callback, assignment-change events, and the workspace reap.
  test "a blocked session is not reported retired, and its parent is not retired either",
       %{db: db} do
    parent = custody_session(db, "agent:cascade-parent")

    child =
      Org.create(
        db,
        base(%{
          session_key: "agent:cascade-child",
          display_name: "agent:cascade-child",
          spawned_by: parent.session_key
        })
      )

    # The child owns an unresolved process, so its retirement must defer.
    row = preparing_process(db, child.session_key)

    {:ok, _} =
      DB.transaction(db, fn txn ->
        ManagedProcesses.transition(
          txn,
          row.processId,
          [state: "preparing", revision: 1],
          %{state: "identity_unknown", uncertainty_cause: "launch_handoff_unknown", now: 2_000}
        )
      end)

    {:ok, result} =
      DB.transaction(db, fn txn ->
        Tightbeam.Gateway.retire_cascade_for_test(
          txn,
          parent.session_key,
          "flynn",
          "user:flynn",
          1_000,
          "retired: test"
        )
      end)

    reported = Enum.map(result.retired, & &1.session_key)

    refute child.session_key in reported,
           "a session blocked on an unresolved process was announced retired"

    refute parent.session_key in reported,
           "an ancestor of a blocked session was retired, stranding the child"

    assert result.blocked == [child.session_key, parent.session_key]

    # And the durable rows agree with the report.
    assert %{state: "active"} = Org.get(db, child.session_key)
    assert %{state: "active"} = Org.get(db, parent.session_key)
  end

  test "an unblocked subtree still retires parent-last and reports every member", %{db: db} do
    parent = custody_session(db, "agent:clean-parent")

    child =
      Org.create(
        db,
        base(%{
          session_key: "agent:clean-child",
          display_name: "agent:clean-child",
          spawned_by: parent.session_key
        })
      )

    {:ok, result} =
      DB.transaction(db, fn txn ->
        Tightbeam.Gateway.retire_cascade_for_test(
          txn,
          parent.session_key,
          "flynn",
          "user:flynn",
          1_000,
          "retired: test"
        )
      end)

    reported = Enum.map(result.retired, & &1.session_key)

    assert child.session_key in reported
    assert parent.session_key in reported
    assert result.blocked == []
    assert %{state: "retired"} = Org.get(db, child.session_key)
    assert %{state: "retired"} = Org.get(db, parent.session_key)
  end

  # REVIEW att_8017ebe7 F2, boot half. Boot recovery had no production entry
  # point at all; this is the callable one. The remaining gap is its call site
  # in lib/tightbeam/boot.ex, which is outside this assignment's declared
  # custody and requested.
  test "boot recovery settles expired leases and finalizes what became finishable", %{db: db} do
    custody_session(db, "agent:boot-finishable")
    custody_session(db, "agent:boot-stuck")

    finishable = preparing_process(db, "agent:boot-finishable")
    stuck = preparing_process(db, "agent:boot-stuck")

    # Both sessions retire and defer; then one process terminalizes and the
    # other becomes genuinely unknown — the shape a crash leaves behind.
    assert %{state: "active"} = retire_in_txn!(db, "agent:boot-finishable")
    assert %{state: "active"} = retire_in_txn!(db, "agent:boot-stuck")

    blocked = ManagedProcesses.get(db, finishable.processId)

    {:ok, _} =
      DB.transaction(db, fn txn ->
        ManagedProcesses.transition(
          txn,
          blocked.processId,
          [state: "launch_cancel_requested", revision: blocked.revision],
          %{state: "launch_canceled", resolved_at: 7_000, now: 7_000}
        )

        stuck_row = ManagedProcesses.get_in_txn(txn, stuck.processId)

        ManagedProcesses.transition(
          txn,
          stuck.processId,
          [state: stuck_row.state, revision: stuck_row.revision],
          %{state: "identity_unknown", uncertainty_cause: "launch_handoff_unknown", now: 7_000}
        )
      end)

    summary = Tightbeam.Gateway.recover_process_custody(db)

    assert "agent:boot-finishable" in summary.retired
    assert "agent:boot-stuck" in summary.blocked_sessions

    assert %{state: "retired"} = Org.get(db, "agent:boot-finishable")

    # The unknown one is NOT cleaned up by a restart. No broker proof exists, so
    # recovery reports the uncertainty and never fabricates absence.
    assert %{state: "active"} = Org.get(db, "agent:boot-stuck")
    still = ManagedProcesses.get(db, stuck.processId)
    assert still.state == "identity_unknown"
    assert still.stopCause == "session_retired"
    refute still.state in ManagedProcesses.terminal_states()
  end

  test "boot recovery is idempotent and terminalizes nothing on a repeat", %{db: db} do
    custody_session(db, "agent:boot-repeat")
    row = preparing_process(db, "agent:boot-repeat")
    assert %{state: "active"} = retire_in_txn!(db, "agent:boot-repeat")

    first = Tightbeam.Gateway.recover_process_custody(db)
    assert first.blocked_sessions == ["agent:boot-repeat"]

    before = ManagedProcesses.get(db, row.processId)
    second = Tightbeam.Gateway.recover_process_custody(db)
    assert second.blocked_sessions == ["agent:boot-repeat"]

    after_row = ManagedProcesses.get(db, row.processId)
    assert after_row.state == before.state
    refute after_row.state in ManagedProcesses.terminal_states()
  end
end
