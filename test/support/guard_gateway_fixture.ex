defmodule Tightbeam.GuardGatewayFixture do
  @moduledoc false
  # Seed synthetic inventories only after asynchronous startup has settled.
  def seed_catalog!(catalog, update) do
    await_catalog_idle!(catalog, 2_000)

    :sys.replace_state(catalog, fn state ->
      updated = update.(state)

      Enum.reduce(updated.entries, updated, fn {key, cache}, acc ->
        if cache == state.entries[key],
          do: acc,
          else: update_in(acc.versions[key], &((&1 || 0) + 1))
      end)
    end)
  end

  defp await_catalog_idle!(_catalog, 0), do: raise("catalog startup did not settle")

  defp await_catalog_idle!(catalog, attempts) do
    if :sys.get_state(catalog).background == nil do
      :ok
    else
      Process.sleep(5)
      await_catalog_idle!(catalog, attempts - 1)
    end
  end

  def make_model_unknown(db, session_key) do
    {:ok, [[sidecar_trigger]]} =
      Tightbeam.DB.query(
        db,
        "SELECT sql FROM sqlite_master WHERE name='supervision_liveness_sidecar_insert_coherent'"
      )

    # Some current triggers read sessions by key. Suspend them during the
    # deliberately incomplete table replacement and restore them afterwards.
    {:ok, revision_triggers} =
      Tightbeam.DB.query(db, """
      SELECT name, sql FROM sqlite_schema
      WHERE type='trigger' AND name GLOB 'execution_map_revision_*'
        AND tbl_name IN ('sessions', 'turns', 'wakes', 'decision_requests')
      ORDER BY name
      """)

    drop_revisions =
      Enum.map_join(revision_triggers, "\n", fn [name, _] -> "DROP TRIGGER #{name};" end)

    restore_revisions = Enum.map_join(revision_triggers, ";\n", fn [_, sql] -> sql end)

    :ok = Tightbeam.DB.execute(db, "PRAGMA foreign_keys=OFF")

    try do
      :ok =
        Tightbeam.DB.execute(
          db,
          """
          DROP TRIGGER supervision_liveness_sidecar_insert_coherent;
          #{drop_revisions}
          CREATE TABLE sessions_with_unknown AS SELECT * FROM sessions;
          DROP TABLE sessions;
          ALTER TABLE sessions_with_unknown RENAME TO sessions;
          CREATE UNIQUE INDEX sessions_unknown_key ON sessions(sessionKey);
          UPDATE sessions SET model=NULL WHERE sessionKey='#{session_key}';
          #{sidecar_trigger};
          #{restore_revisions};
          """
        )
    after
      :ok = Tightbeam.DB.execute(db, "PRAGMA foreign_keys=ON")
    end
  end

  def run!(proof) do
    [payload, base] = System.argv()
    true = Path.expand(Application.app_dir(:tightbeam)) == Path.expand(payload)
    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, _} = Application.ensure_all_started(:crypto)
    Application.put_env(:tightbeam, :base_dir, base)
    Application.put_env(:tightbeam, :autostart, false)
    Application.put_env(:tightbeam, :fixture_harness, true)
    Application.put_env(:tightbeam, :local_host_name, "testhost")
    alias Tightbeam.{Boot, DB, Gateway, Model}
    import ExUnit.Assertions

    {:ok, db} =
      DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [])

    :ignore = Boot.start_link(%{base_dir: base})
    marker = File.read!(Path.join(base, "build-owner.json"))
    bin = Path.join(base, "fixture-bin")
    File.mkdir_p!(bin)
    tripwire = Path.join(base, "forbidden-execution.log")
    System.put_env("GUARD_TRIPWIRE", tripwire)

    for name <- ["claude", "codex", "fixture"] do
      path = Path.join(bin, name)

      File.write!(
        path,
        "#!/bin/sh\nif [ \"#{name}\" = codex ] && [ \"$#\" = 2 ] && [ \"$1\" = --dangerously-bypass-hook-trust ] && [ \"$2\" = --version ]; then echo fixture-only; exit 0; fi\nif [ \"$#\" = 1 ] && [ \"$1\" = --version ]; then echo fixture-only; exit 0; fi\necho forbidden >> \"$GUARD_TRIPWIRE\"\nexit 64\n"
      )

      File.chmod!(path, 0o755)
    end

    for name <- ["npm", "ssh"] do
      path = Path.join(bin, name)
      File.write!(path, "#!/bin/sh\necho forbidden >> \"$GUARD_TRIPWIRE\"\nexit 64\n")
      File.chmod!(path, 0o755)
    end

    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

    for name <- ["claude", "codex", "fixture", "npm", "ssh"],
        do: assert(System.find_executable(name) == Path.join(bin, name))

    {:ok, registry} = Tightbeam.ConnRegistry.start_link(name: Tightbeam.ConnRegistry)

    config = %{
      base_dir: base,
      cwd: base,
      db: db,
      port: 4_321,
      default_harness: :fixture,
      default_model: Model.new("fixture-model"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000
    }

    try do
      proof.(%{db: db, config: config, base: base})
      assert File.read!(Path.join(base, "build-owner.json")) == marker
      assert :ok = DB.assert_base_admitted!(db, base)
      refute File.exists?(tripwire)
    after
      :ok = GenServer.stop(registry)
      :ok = GenServer.stop(db)
    end
  end
end
