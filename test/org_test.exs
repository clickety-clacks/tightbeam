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

  test "normalize_spawn_display_name prefixes product-owner spawn inputs and preserves an already-normalized one" do
    assert Org.normalize_spawn_display_name("product-owner", "Outpost") == "PO — Outpost"

    assert Org.normalize_spawn_display_name("product-owner", "Product Owner — Outpost") ==
             "PO — Outpost"

    assert Org.normalize_spawn_display_name("product-owner", "PO — Outpost") == "PO — Outpost"
  end

  test "normalize_spawn_display_name leaves another archetype's display name untouched" do
    assert Org.normalize_spawn_display_name("coder", "Product Owner — Outpost") ==
             "Product Owner — Outpost"

    assert Org.normalize_spawn_display_name("coder", "Coder — auth fix") == "Coder — auth fix"
  end

  test "po display migration renames only active product-owner sessions with the exact old prefix, preserves the suffix, and is idempotent",
       %{db: db} do
    target =
      Org.create(
        db,
        base(%{
          session_key: "po-1",
          archetype: "product-owner",
          display_name: "Product Owner — Outpost"
        })
      )

    already_normalized =
      Org.create(
        db,
        base(%{session_key: "po-2", archetype: "product-owner", display_name: "PO — Weather"})
      )

    other_archetype =
      Org.create(
        db,
        base(%{
          session_key: "coder-1",
          archetype: "coder",
          display_name: "Product Owner — Impostor"
        })
      )

    retired_target =
      db
      |> Org.create(
        base(%{
          session_key: "po-retired",
          archetype: "product-owner",
          display_name: "Product Owner — Retired"
        })
      )
      |> then(&Org.retire(db, &1.session_key, "test:org", 1_000))

    plan = Org.po_display_migration_plan(db)
    assert plan == [%{session_key: "po-1", from: "Product Owner — Outpost", to: "PO — Outpost"}]

    seed_history_rows(db, "po-1")
    history_before = history_snapshot(db)

    applied = Org.migrate_po_display_names(db)
    assert Enum.map(applied, & &1.session_key) == ["po-1"]
    assert Enum.map(applied, & &1.display_name) == ["PO — Outpost"]

    assert Org.get(db, "po-1").display_name == "PO — Outpost"
    assert Org.get(db, "po-2").display_name == already_normalized.display_name
    assert Org.get(db, "coder-1").display_name == other_archetype.display_name
    assert Org.get(db, "po-retired").display_name == retired_target.display_name

    # Only displayName moved on the migrated row — every other column, including
    # updatedAt's neighbors, is untouched by the migration.
    migrated = Org.get(db, "po-1")
    assert migrated.archetype == target.archetype
    assert migrated.state == target.state
    assert migrated.owner_user_id == target.owner_user_id

    # No historical row anywhere moved OR was rewritten — full row content
    # (not just a count) is byte-identical, including the seeded rows
    # attached to the very session that got renamed. A migration that
    # somehow UPDATEd rather than left these tables alone (same row count,
    # different content) would fail this where a count-only check could not.
    assert history_snapshot(db) == history_before

    # Idempotent: the prefix no longer matches, so a second run selects nothing.
    assert Org.po_display_migration_plan(db) == []
    assert Org.migrate_po_display_names(db) == []
    assert Org.get(db, "po-1").display_name == "PO — Outpost"
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

  defp seed_history_rows(db, session_key) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO events (ts, kind, verb, origin, principal, sessionKey, payload) VALUES (1, 'verb', 'seed', 'user:flynn', NULL, ?1, 'null')",
        [session_key]
      )

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (1, 'seed', ?1, 'untouched')",
        [session_key]
      )

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO messages (id, sessionKey, role, content, timestamp, llmVisibleMessageId)
        VALUES ('seed-msg-1', ?1, 'user', 'seed content', 1, 'seed-msg-1')
        """,
        [session_key]
      )

    :ok
  end

  defp history_snapshot(db) do
    for table <- ~w(events lifecycle_events messages) do
      {:ok, rows} = DB.query(db, "SELECT * FROM #{table} ORDER BY 1")
      {table, rows}
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
end
