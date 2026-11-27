defmodule Tightbeam.ReleaseFixtureUpgradeTest do
  use ExUnit.Case, async: false

  @fixtures Path.join(__DIR__, "fixtures/releases")
  @boot Path.join(__DIR__, "support/release_upgrade_boot.exs")
  @predecessor "0.1.17+5505.sql"
  # Add a filename here when direct skip-release upgrades are supported.
  @direct_upgrades []
  @preserved_tables ~w(sessions assignments attests artifacts wakes decision_requests work_items)

  @tag timeout: 120_000
  test "killing first startup during the provider-account migration rolls back and can restart" do
    filename =
      if File.exists?(Path.join(@fixtures, @predecessor)) do
        @predecessor
      else
        # Continue exercising startup interruption when the initial fixture ages out.
        @fixtures |> Path.join("*.sql") |> Path.wildcard() |> Enum.min() |> Path.basename()
      end

    {base, db} = restore(filename)
    original = preserved_rows(db)
    schema_existed? = provider_schema?(db)
    if filename == @predecessor, do: refute(schema_existed?)

    port = boot(base, true)
    pid = await_checkpoint(port)
    assert {_, 0} = System.cmd("kill", ["-KILL", pid])
    assert await_exit(port) == {137, false}

    assert provider_schema?(db) == schema_existed?
    assert intact?(db)
    assert preserved_rows(db) == original

    assert_upgrade(base, db, original)
  end

  for filename <- @direct_upgrades do
    @tag timeout: 120_000
    test "can upgrade #{filename} directly" do
      {base, db} = restore(unquote(filename))
      assert_upgrade(base, db, preserved_rows(db))
    end
  end

  defp restore(filename) do
    base = Path.join(System.tmp_dir!(), "release-upgrade-#{Tightbeam.Id.uuid4()}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    db = Path.join(base, "state.db")
    assert {"", 0} = System.cmd("sqlite3", ["-batch", "-bail", db, ".read \"#{Path.join(@fixtures, filename)}\""])
    assert intact?(db)
    {base, db}
  end

  defp boot(base, interrupt?) do
    executable = System.find_executable("mix")
    stamp = base |> Path.join("state.db") |> sqlite("SELECT shape FROM schema_stamp") |> String.trim()

    Port.open({:spawn_executable, executable}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 8192},
      {:args, ["run", "--no-start", "--no-compile", @boot, base, stamp]},
      {:env, [
        {~c"MIX_ENV", ~c"test"},
        {~c"npm_config_offline", ~c"true"},
        {~c"TB_UPGRADE_INTERRUPT", if(interrupt?, do: ~c"1", else: ~c"0")}
      ]}
    ])
  end

  defp await_checkpoint(port) do
    receive do
      {^port, {:data, {:eol, "UPGRADE_TRANSACTION_OPEN " <> pid}}} -> pid
      {^port, {:data, _}} -> await_checkpoint(port)
      {^port, {:exit_status, status}} -> flunk("first boot exited with #{status} before migration checkpoint")
    after
      30_000 -> flunk("first boot did not enter the migration transaction")
    end
  end

  defp await_exit(port, ready? \\ false) do
    receive do
      {^port, {:data, {:eol, "UPGRADE_READY"}}} -> await_exit(port, true)
      {^port, {:data, _}} -> await_exit(port, ready?)
      {^port, {:exit_status, status}} -> {status, ready?}
    after
      30_000 -> flunk("upgrade subprocess did not exit")
    end
  end

  defp assert_upgrade(base, db, original) do
    assert await_exit(boot(base, false)) == {0, true}
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
