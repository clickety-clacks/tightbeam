defmodule Tightbeam.ReleaseFixtureUpgradeTest do
  use Tightbeam.TestCase, async: false

  @fixtures Path.join(__DIR__, "fixtures/releases")
  @boot "release_upgrade_boot.exs"
  @predecessor "0.1.17+5505.sql"
  # Add a filename here when direct skip-release upgrades are supported.
  @direct_upgrades []
  @preserved_tables ~w(sessions assignments attests artifacts wakes decision_requests work_items)

  @tag timeout: 120_000
  test "default boot preserves the predecessor without creating optional storage" do
    {runtime, db} = restore(@predecessor)
    original = preserved_rows(db)

    {status, ready?, output} = await_exit(boot(runtime, db, false, false))
    assert {status, ready?} == {0, true}, "default boot did not complete:\n#{output}"
    assert intact?(db)
    assert preserved_rows(db) == original
    assert_default_schema(db)
  end

  @tag timeout: 120_000
  test "fresh default boot leaves optional storage absent" do
    runtime = fixture_runtime()
    db = Path.join(runtime.base, "state.db")
    refute File.exists?(db)

    {status, ready?, output} = await_exit(boot(runtime, db, false, false))
    assert {status, ready?} == {0, true}, "fresh boot did not complete:\n#{output}"
    assert intact?(db)
    assert_default_schema(db)
  end

  defp assert_default_schema(db) do
    assert sqlite(db, """
           SELECT name FROM sqlite_schema
           WHERE name IN (
             'account_writer_leases', 'provider_accounts', 'provider_account_schema_stamp',
             'account_serving', 'account_limits', 'capacity_windows',
             'execution_map_turn_versions', 'execution_map_turn_version_activation',
             'execution_map_revisions', 'harklight_pending_opens', 'harklight_item_ids',
             'harklight_outage_recoveries', 'people_conversations'
           )
              OR name GLOB 'execution_map_revision_*'
              OR name GLOB 'execution_map_turn_versions_*';
           SELECT name FROM pragma_table_info('turns') WHERE name = 'accountId';
           """) == ""
  end

  @tag timeout: 120_000
  test "killing first startup during the provider-account migration rolls back and can restart" do
    filename =
      if File.exists?(Path.join(@fixtures, @predecessor)) do
        @predecessor
      else
        # Continue exercising startup interruption when the initial fixture ages out.
        @fixtures |> Path.join("*.sql") |> Path.wildcard() |> Enum.min() |> Path.basename()
      end

    {runtime, db} = restore(filename)
    original = preserved_rows(db)
    schema_existed? = provider_schema?(db)
    if filename == @predecessor, do: refute(schema_existed?)

    port = boot(runtime, db, true)
    pid = await_checkpoint(port)
    assert {_, 0} = System.cmd("kill", ["-KILL", pid])
    assert {137, false, _output} = await_exit(port)

    assert provider_schema?(db) == schema_existed?
    assert intact?(db)
    assert preserved_rows(db) == original

    assert_upgrade(runtime, db, original)
  end

  for filename <- @direct_upgrades do
    @tag timeout: 120_000
    test "can upgrade #{filename} directly" do
      {runtime, db} = restore(unquote(filename))
      assert_upgrade(runtime, db, preserved_rows(db))
    end
  end

  defp fixture_runtime do
    tmp = Path.join(System.tmp_dir!(), "release-upgrade-#{Tightbeam.Id.uuid4()}")
    on_exit(fn -> File.rm_rf!(tmp) end)
    runtime = Tightbeam.GuardRuntimeFixture.prepare!(tmp, @boot)
    File.mkdir_p!(runtime.base)
    File.write!(Path.join(runtime.base, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
    Tightbeam.RecoveryFixture.place_adapter!(runtime.base, seed_credential: false)
    runtime
  end

  defp restore(filename) do
    runtime = fixture_runtime()
    db = Path.join(runtime.base, "state.db")
    dump = Path.join(@fixtures, filename)
    assert {"", 0} = System.cmd("sqlite3", ["-batch", "-bail", db, ".read \"#{dump}\""])
    assert intact?(db)
    {runtime, db}
  end

  defp boot(runtime, db, interrupt?, accounts? \\ true) do
    stamp = if File.exists?(db), do: db |> sqlite("SELECT shape FROM schema_stamp") |> String.trim(), else: ""

    env =
      runtime.env ++
        [
          {"npm_config_offline", "true"},
          {"TB_UPGRADE_INTERRUPT", if(interrupt?, do: "1", else: "0")},
          {"TB_UPGRADE_ACCOUNTS", if(accounts?, do: "1", else: "0")}
        ]

    Port.open({:spawn_executable, runtime.executable}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 8192},
      {:args, runtime.args ++ [stamp]},
      {:env, Enum.map(env, fn
        {key, nil} -> {String.to_charlist(key), false}
        {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
      end)}
    ])
  end

  defp await_checkpoint(port, output \\ []) do
    receive do
      {^port, {:data, {:eol, "UPGRADE_TRANSACTION_OPEN " <> pid}}} -> pid
      {^port, {:data, {_, line}}} ->
        await_checkpoint(port, [line | output])

      {^port, {:exit_status, status}} ->
        flunk("first boot exited with #{status} before migration checkpoint:\n#{boot_log(output)}")
    after
      30_000 -> flunk("first boot did not enter the migration transaction:\n#{boot_log(output)}")
    end
  end

  defp await_exit(port, ready? \\ false, output \\ []) do
    receive do
      {^port, {:data, {:eol, "UPGRADE_READY"}}} -> await_exit(port, true, output)
      {^port, {:data, {_, line}}} -> await_exit(port, ready?, [line | output])
      {^port, {:exit_status, status}} -> {status, ready?, boot_log(output)}
    after
      30_000 -> flunk("upgrade subprocess did not exit:\n#{boot_log(output)}")
    end
  end

  defp boot_log(output), do: output |> Enum.take(30) |> Enum.reverse() |> Enum.join("\n")

  defp assert_upgrade(runtime, db, original) do
    {status, ready?, output} = await_exit(boot(runtime, db, false))
    assert {status, ready?} == {0, true}, "restart did not complete:\n#{output}"
    assert provider_schema?(db)
    assert intact?(db)
    assert preserved_rows(db) == original
  end

  defp intact?(db), do: sqlite(db, "PRAGMA integrity_check; PRAGMA foreign_key_check;") == "ok\n"

  defp provider_schema?(db) do
    sqlite(db, "SELECT name FROM sqlite_schema WHERE name = 'provider_account_schema_stamp'") != ""
  end

  defp preserved_rows(db) do
    # The provider migration adds schema without rewriting these seeded tables.
    Map.new(@preserved_tables, fn table -> {table, sqlite(db, "SELECT * FROM #{table}")} end)
  end

  defp sqlite(db, statement) do
    assert {result, 0} = System.cmd("sqlite3", ["-batch", "-bail", db, statement])
    result
  end
end
