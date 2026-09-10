defmodule Tightbeam.GuardGatewayFixture do
  @moduledoc false
  def run!(proof) do
    [payload, base, locks] = System.argv()
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
      DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [lock_dir: locks])

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
