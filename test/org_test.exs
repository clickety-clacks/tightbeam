defmodule Tightbeam.OrgTest do
  use Tightbeam.TestCase, async: false

  doctest Tightbeam.Org

  alias Tightbeam.{DB, EventLog, Gateway, Ledger, Org}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Org.ensure_schema(name)
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
        model: "fable"
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
      |> then(&Org.retire(db, &1.session_key))

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

    Org.retire(db, first.session_key)
    assert Org.by_cli_token(db, first.cli_token) == nil

    {:ok, [[index_sql]]} =
      DB.query(
        db,
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'sessions_cli_token'"
      )

    assert index_sql =~ "UNIQUE INDEX"
  end

  test "gateway boot migrates and backfills a pre-existing session schema" do
    db = :"old_org_db_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({DB, path: ":memory:", name: db}, id: db))

    :ok =
      DB.execute(db, """
      CREATE TABLE sessions (
        sessionKey TEXT PRIMARY KEY, displayName TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'custom',
        orderIndex INTEGER NOT NULL DEFAULT 0, isBuiltIn INTEGER NOT NULL DEFAULT 0,
        adopted INTEGER NOT NULL DEFAULT 0, ownerUserId TEXT NOT NULL, origin TEXT NOT NULL,
        spawnedBy TEXT, handle TEXT UNIQUE, archetype TEXT NOT NULL, harness TEXT NOT NULL,
        provider TEXT NOT NULL, model TEXT NOT NULL, thinkingLevel TEXT, state TEXT NOT NULL DEFAULT 'active',
        createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL
      )
      """)

    :ok = Ledger.ensure_schema(db)
    :ok = EventLog.ensure_schema(db)

    now = System.system_time(:millisecond)

    for {session_key, state} <- [{"old-active", "active"}, {"old-retired", "retired"}] do
      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO sessions (
            sessionKey, displayName, ownerUserId, origin, archetype, harness,
            provider, model, state, createdAt, updatedAt
          ) VALUES (?1, ?2, 'flynn', 'user:flynn', 'default', 'claude',
                    'anthropic', 'fable', ?3, ?4, ?4)
          """,
          [session_key, session_key, state, now]
        )
    end

    base_dir =
      Path.join(System.tmp_dir!(), "old_org_boot_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base_dir) end)

    assert is_list(
             Gateway.children(%{
               base_dir: base_dir,
               cwd: "/tmp",
               port: 0,
               default_harness: :claude,
               default_model: "claude-fable-5",
               max_live_sessions_per_user: 50,
               wake_tick_ms: 1_000,
               onboarding_lease_ms: 1_800_000,
               db: db,
               harness_binary_probe: fn harness, _cli_bin ->
                 {:ok, %{bin: "/fake/#{harness}", version: "#{harness} 1.0"}}
               end
             })
           )

    {:ok, columns} = DB.query(db, "PRAGMA table_info(sessions)")
    assert Enum.any?(columns, fn [_cid, name | _] -> name == "cliToken" end)

    active_token = Org.get(db, "old-active").cli_token
    assert active_token =~ ~r/^tbs_[A-Za-z0-9_-]{32}$/
    assert Org.by_cli_token(db, active_token).session_key == "old-active"
    assert Org.get(db, "old-retired").cli_token == nil

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

    retired = Org.retire(db, "k1")
    assert retired.state == "retired"
    assert Enum.map(Org.list_for_user(db, "flynn", false), & &1.session_key) == ["k2"]

    {:ok, [["retired"]]} = DB.query(db, "SELECT state FROM sessions WHERE sessionKey = 'k1'")
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
          model: "gpt-5.6-sol[high]"
        })
      )

    assert child.spawned_by == "root"
    assert child.provider == "openai"
  end

  test "rename and set_model update the row", %{db: db} do
    original = Org.create(db, base(%{session_key: "k1"}))
    renamed = Org.rename(db, "k1", "Renamed")
    updated = Org.set_model(db, "k1", "gpt-5.6-sol[high]", "openai")

    assert renamed.display_name == "Renamed"
    assert updated.model == "gpt-5.6-sol[high]"
    assert updated.provider == "openai"
    assert updated.updated_at >= original.updated_at

    {:ok, rows} =
      DB.query(db, "SELECT displayName, model, provider FROM sessions WHERE sessionKey = 'k1'")

    assert rows == [["Renamed", "gpt-5.6-sol[high]", "openai"]]
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
end
