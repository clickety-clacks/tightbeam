defmodule Tightbeam.OrgTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  doctest Tightbeam.Org

  alias Tightbeam.{DB, NoticeBatcher, Org, Roles, Wakes}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Tightbeam.Schema.ensure_all(name)

    main_key = Org.personal_session_key("flynn")

    main =
      Org.create(
        name,
        base(%{session_key: main_key, kind: "main", is_built_in: true, adopted: true})
      )

    %{db: name, main: main}
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

  test "create persists provenance, wire metadata, and boolean flags", %{db: db, main: session} do
    key = session.session_key

    assert session.session_key == "agent:main:clawline:flynn:main"

    assert %{
             archetype: "default",
             identity_name: "default",
             overrides: nil,
             host: "testhost",
             provider: "anthropic",
             state: "active",
             is_built_in: true,
             adopted: true,
             operational_parent: ^key
           } = session

    assert Org.get(db, key).display_name == "Main"

    {:ok, rows} =
      DB.query(db, "SELECT isBuiltIn, adopted, state FROM sessions WHERE sessionKey = ?1", [key])

    assert rows == [[1, 1, "active"]]
  end

  test "operational parent is total, mutable, and independent of spawn provenance", %{
    db: db,
    main: main
  } do
    main_key = main.session_key
    first = Org.create(db, base(%{session_key: "first"}))

    child =
      Org.create(
        db,
        base(%{session_key: "child", spawned_by: first.session_key})
      )

    assert main.operational_parent == main_key
    assert first.operational_parent == main_key
    assert child.spawned_by == first.session_key
    assert child.operational_parent == first.session_key

    assert_raise ArgumentError, ~r/create a cycle/, fn ->
      Org.set_operational_parent(db, first.session_key, child.session_key)
    end

    reparented = Org.set_operational_parent(db, child.session_key, main_key)
    assert reparented.operational_parent == main_key
    assert reparented.spawned_by == first.session_key

    assert_raise ArgumentError, ~r/non-empty session key/, fn ->
      Org.set_operational_parent(db, child.session_key, nil)
    end

    assert_raise ArgumentError, ~r/Main's operational parent/, fn ->
      Org.set_operational_parent(db, main_key, first.session_key)
    end

    derived =
      Org.create(db, base(%{session_key: "derived", operational_parent: "derived"}))

    assert derived.operational_parent == main_key

    {:ok, foreign_keys} = DB.query(db, "PRAGMA foreign_key_list(sessions)")

    assert Enum.any?(foreign_keys, fn
             [_id, _seq, "sessions", "operationalParent", "sessionKey" | _rest] -> true
             _row -> false
           end)
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
    main_key = Org.personal_session_key("flynn")
    Org.create(db, base(%{session_key: "k2", order_index: 2}))
    Org.create(db, base(%{session_key: "k1", order_index: 1}))
    ensure_main_session(db, "sam")

    Org.create(
      db,
      base(%{
        session_key: "sam",
        owner_user_id: "sam",
        origin: "user:sam"
      })
    )

    assert Enum.map(Org.list_for_user(db, "flynn", false), & &1.session_key) == [
             main_key,
             "k1",
             "k2"
           ]

    assert length(Org.list_for_user(db, "flynn", true)) == 5

    retired = Org.retire(db, "k1", "user:flynn", 1_000)
    assert retired.state == "retired"

    assert Enum.map(Org.list_for_user(db, "flynn", false), & &1.session_key) == [
             main_key,
             "k2"
           ]

    {:ok, [["retired"]]} = DB.query(db, "SELECT state FROM sessions WHERE sessionKey = 'k1'")
  end

  test "retirement cancels gated direct and role targets, replaces the role, and preserves ungated delivery",
       %{db: db} do
    main_key = Org.personal_session_key("flynn")
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

  test "retirement transaction preserves one selected V1 delivery path on the replacement", %{
    db: db
  } do
    main_key = Org.personal_session_key("flynn")
    Org.create(db, base(%{session_key: "retiring"}))
    Roles.create!(db, "reviewer", "flynn", "retiring")

    lane = %{session_key: "retiring", target_role: "reviewer"}

    {:ok, _policy} =
      DB.transaction(db, fn txn ->
        Org.apply_notice_batching_lane_policy_in_txn(
          txn,
          lane,
          true,
          "notice-batching-org-retirement-test",
          "agent:test-policy",
          "retirement-fixture",
          1_000
        )
      end)

    original =
      Wakes.schedule(db, %{
        session_key: "retiring",
        target_role: "reviewer",
        origin: "process:tightbeam",
        creator_session_key: "agent:sender",
        prompt: "selected source survives retirement",
        due_at: 0,
        class: "fyi"
      })

    assert original.delivery_rule == NoticeBatcher.rule()

    assert [%{member_state: "active", batch_id: batch_id}] =
             NoticeBatcher.source_refs(db, original.wake_id)

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)
    assert %{replacement_wake_id: replacement_wake_id} = cancellation(db, original.wake_id)

    replacement = Wakes.get(db, replacement_wake_id)
    assert replacement.session_key == main_key
    assert replacement.target_role == "reviewer"
    assert replacement.delivery_rule == NoticeBatcher.rule()
    assert replacement.due_at == original.due_at

    assert [%{member_state: "canceled", batch_id: ^batch_id}] =
             NoticeBatcher.source_refs(db, original.wake_id)

    assert [%{member_state: "active", batch_id: ^batch_id}] =
             NoticeBatcher.source_refs(db, replacement_wake_id)

    assert [carrier_id] = Wakes.materialize_digests(db, replacement.due_at)
    assert Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id) == [replacement_wake_id]

    {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [carrier_id])
    scheduler = :"org_retirement_batch_scheduler_#{System.unique_integer([:positive])}"
    test_pid = self()

    start_supervised!(
      {Wakes,
       name: scheduler,
       db: db,
       tick_ms: 60_000,
       deliver: fn wake ->
         send(test_pid, {:delivered, wake.wake_id})
         true
       end},
      id: scheduler
    )

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:delivered, ^carrier_id}
    refute_receive {:delivered, ^replacement_wake_id}
    assert Wakes.get(db, carrier_id).state == "fired"
    assert Wakes.get(db, replacement_wake_id).state == "pending"
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM wakes WHERE digest=1")
  end

  test "retirement after seal preserves the immutable carrier and closes the replacement", %{
    db: db
  } do
    %{original: original, batch_id: batch_id} = selected_retirement_source(db, "after seal")

    assert {:ok, :sealed} =
             DB.transaction(db, fn txn ->
               NoticeBatcher.enqueue_or_recover_in_txn(
                 txn,
                 {:seal_if_due, batch_id, original.due_at}
               )
             end)

    sealed = NoticeBatcher.batch(db, batch_id)
    assert sealed.state == "sealed"
    assert is_binary(sealed.envelope)
    assert is_binary(sealed.envelope_sha256)
    assert sealed.delivery_wake_id == nil

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)
    assert_immutable_retirement_chain(db, original, sealed)
  end

  test "retirement after arm preserves the one carrier and closes the replacement", %{db: db} do
    %{original: original, batch_id: batch_id} = selected_retirement_source(db, "after arm")
    assert [carrier_id] = Wakes.materialize_digests(db, original.due_at)

    armed = NoticeBatcher.batch(db, batch_id)
    assert armed.state == "delivery_pending"
    assert armed.delivery_wake_id == carrier_id

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)
    assert_immutable_retirement_chain(db, original, armed)
  end

  test "retirement after terminal carrier preserves the one fired delivery path", %{db: db} do
    %{original: original, batch_id: batch_id} =
      selected_retirement_source(db, "after terminal carrier")

    assert [carrier_id] = Wakes.materialize_digests(db, original.due_at)
    NoticeBatcher.delivery_terminal_failure(db, carrier_id, :skipped, 1_000)

    terminal = NoticeBatcher.batch(db, batch_id)
    assert terminal.state == "delivery_failed"
    assert Wakes.get(db, carrier_id).state == "fired"

    assert %{state: "retired"} = Org.retire(db, "retiring", "user:flynn", 1_000)
    assert NoticeBatcher.batch(db, batch_id).state == "delivery_failed"
    assert Wakes.get(db, carrier_id).state == "fired"
    assert Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id) == [original.wake_id]

    assert %{state: "canceled"} = Wakes.get(db, original.wake_id)

    assert %{outcome: "replacement", replacement_wake_id: replacement_wake_id} =
             cancellation(db, original.wake_id)

    assert %{state: "canceled"} = Wakes.get(db, replacement_wake_id)
    assert NoticeBatcher.source_refs(db, replacement_wake_id) == []
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM wakes WHERE digest=1")
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

  defp selected_retirement_source(db, prompt) do
    Org.create(db, base(%{session_key: "retiring"}))
    Roles.create!(db, "reviewer", "flynn", "retiring")

    {:ok, _policy} =
      DB.transaction(db, fn txn ->
        Org.apply_notice_batching_lane_policy_in_txn(
          txn,
          %{session_key: "retiring", target_role: "reviewer"},
          true,
          "notice-batching-org-immutable-retirement-test:#{prompt}",
          "agent:test-policy",
          "retirement-immutable-fixture",
          1_000
        )
      end)

    original =
      Wakes.schedule(db, %{
        session_key: "retiring",
        target_role: "reviewer",
        origin: "process:tightbeam",
        creator_session_key: "agent:sender",
        prompt: prompt,
        due_at: 0,
        class: "fyi"
      })

    assert [%{member_state: "active", batch_id: batch_id}] =
             NoticeBatcher.source_refs(db, original.wake_id)

    %{original: original, batch_id: batch_id}
  end

  defp assert_immutable_retirement_chain(db, original, immutable_batch) do
    final_batch = NoticeBatcher.batch(db, immutable_batch.batch_id)
    carrier_id = final_batch.delivery_wake_id

    assert final_batch.state == "delivery_pending"
    assert final_batch.envelope == immutable_batch.envelope
    assert final_batch.envelope_sha256 == immutable_batch.envelope_sha256
    assert is_binary(carrier_id)
    assert Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id) == [original.wake_id]
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM wakes WHERE digest=1")

    assert %{state: "canceled"} = Wakes.get(db, original.wake_id)

    assert %{outcome: "replacement", replacement_wake_id: replacement_wake_id} =
             cancellation(db, original.wake_id)

    assert %{state: "canceled"} = Wakes.get(db, replacement_wake_id)

    assert %{
             requester: "tightbeam:batcher",
             reason: "superseded",
             source_kind: "wake",
             source_id: ^carrier_id,
             outcome: "replacement",
             replacement_wake_id: ^carrier_id
           } = cancellation(db, replacement_wake_id)

    assert [%{member_state: "included", delivery_wake_id: ^carrier_id}] =
             NoticeBatcher.source_refs(db, original.wake_id)

    assert NoticeBatcher.source_refs(db, replacement_wake_id) == []

    assert {:ok, [[2]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId IN (?1, ?2)",
               [original.wake_id, replacement_wake_id]
             )
  end
end
