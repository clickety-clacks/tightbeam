defmodule Tightbeam.HarnessLaunchRecoveryTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true
  alias Tightbeam.{DB, EventLog, HarnessProcess}
  alias Tightbeam.Acp.Conn
  @helper Path.expand("../cli/target/release/tightbeam", __DIR__)
  @key {:claude, "shared", "fixture-host"}
  @key_name "claude:shared@fixture-host"

  setup %{tmp_dir: tmp} do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = HarnessProcess.ensure_schema(db)
    :ok = EventLog.ensure_schema(db)
    %{db: db, tmp: tmp}
  end

  defp prepare(ctx, opts \\ []) do
    options = HarnessProcess.prepare_launch(Keyword.merge([
      cmd: ["/bin/true"], process_helper: @helper, process_identity_dir: ctx.tmp
    ], opts), ctx.db, @key)
    row = Enum.find(HarnessProcess.list(ctx.db), &(&1.launch_id == options[:harness_process_launch_id]))
    {row, options}
  end

  defp terminal(row, status \\ 1) do
    File.write!(row.identity_path <> ".failed", "tightbeam-launch-failed-v1\t#{row.launch_id}\tboot\t#{status}\n")
  end

  defp settle(ctx, row, receipt \\ nil),
    do: HarnessProcess.settle(ctx.db, row.launch_id, row.adapter_key, "fixture-operator", receipt)

  test "empty partial and invalid identities fail within a finite deadline and retain attribution", ctx do
    {row, _} = prepare(ctx)
    for bytes <- ["", "12\t12", "x\tx\tboot\t#{row.launch_id}\n", "12\t12\t\t#{row.launch_id}\n"] do
      File.write!(row.identity_path, bytes)
      before = System.monotonic_time(:millisecond)
      assert {:error, {:launch_identity_failed, id, :identity_file_invalid} = reason} =
        HarnessProcess.capture_identity(ctx.db, row.launch_id, 30)
      assert System.monotonic_time(:millisecond) - before < 2_000
      assert id == row.launch_id
      assert [%{last_error: error, resolved_at: nil}] = HarnessProcess.list(ctx.db)
      assert error == inspect(reason)
      assert HarnessProcess.fenced?(ctx.db, @key)
    end
    assert_raise FunctionClauseError, fn -> HarnessProcess.capture_identity(ctx.db, row.launch_id, :infinity) end
  end

  test "exact connection exit is attributed before the identity deadline", ctx do
    {row, _} = prepare(ctx)
    File.write!(row.identity_path, "")
    conn = start_supervised!({Conn, cmd: ["/bin/sh", "-c", "exit 17"], subscriber: self(),
      harness_process_launch_id: row.launch_id, harness_process_direct_launcher: false})
    assert_receive {:acp_exit, 17}, 2_000
    before = System.monotonic_time(:millisecond)
    assert {:error, {:launch_identity_failed, _, {:launcher_exited, 17, _}}} =
      HarnessProcess.capture_identity(ctx.db, row.launch_id, 5_000, conn)
    assert System.monotonic_time(:millisecond) - before < 2_000
    assert {:error, _} = settle(ctx, row, Conn.launch_exit(conn, 100))
    assert HarnessProcess.fenced?(ctx.db, @key)
  end

  test "terminal record settles exactly once and preserves the prior error", ctx do
    {row, _} = prepare(ctx)
    File.write!(row.identity_path, "")
    terminal(row)
    assert {:error, failure} = HarnessProcess.capture_identity(ctx.db, row.launch_id, 30)
    assert {:ok, %{proof: :terminal_pre_identity}} = settle(ctx, row)
    assert [%{resolved_at: at, last_error: error}] = HarnessProcess.list(ctx.db)
    assert is_integer(at)
    assert error == inspect(failure)
    assert :already_resolved = settle(ctx, row)
    refute File.exists?(row.identity_path)
    refute HarnessProcess.fenced?(ctx.db, @key)
    assert {:ok, [[detail]]} = DB.query(ctx.db, "SELECT detail FROM lifecycle_events WHERE kind='harness_launch_settled'")
    assert detail =~ row.launch_id
    assert detail =~ "fixture-operator"
  end

  test "contradictory exit or wrong key refuses without any change", ctx do
    {row, _} = prepare(ctx)
    terminal(row)
    before = HarnessProcess.list(ctx.db)
    assert {:error, :launcher_exit_mismatch} = settle(ctx, row, %{launch_id: row.launch_id, status: 2})
    assert {:error, :adapter_key_mismatch} = HarnessProcess.settle(ctx.db, row.launch_id, "other", "fixture")
    assert HarnessProcess.list(ctx.db) == before
    assert File.exists?(row.identity_path <> ".failed")
  end

  test "missing identity without observed launcher exit stays fenced and can still launch", ctx do
    {row, options} = prepare(ctx)
    assert {:error, _} = settle(ctx, row)
    refute File.exists?(row.identity_path)
    [exe | args] = options[:cmd]
    assert {_, 0} = System.cmd(exe, args)
    assert {:ok, %{proof: :process_group_absent}} = settle(ctx, row)
  end

  test "only direct local launcher exit plus absence of both files proves never started", ctx do
    {row, _} = prepare(ctx)
    receipt = %{launch_id: row.launch_id, status: 1, direct_launcher: true}
    File.write!(row.identity_path <> ".authority", "retained")
    assert {:error, _} = settle(ctx, row, receipt)
    assert File.read!(row.identity_path <> ".authority") == "retained"
    File.rm!(row.identity_path <> ".authority")
    assert {:error, _} = settle(ctx, row, %{receipt | direct_launcher: false})
    assert {:ok, %{proof: :launcher_exited_without_start}} = settle(ctx, row, receipt)
  end

  test "boot identity is inserted before spawn and failure refuses before a row or fence", ctx do
    assert_raise RuntimeError, ~r/preparation failed.*fixture-host.*boot_identity/, fn ->
      prepare(ctx, process_helper: "/bin/false")
    end
    assert HarnessProcess.list(ctx.db) == []
    refute HarnessProcess.fenced?(ctx.db, @key)
    {row, _} = prepare(ctx)
    assert {:ok, boot} = HarnessProcess.local_boot_identity(row)
    assert row.preparation_boot_identity == boot
    refute File.exists?(row.identity_path)
  end

  test "local reboot proof handles absent and empty identity through both recovery routes", ctx do
    for content <- [:absent, ""] do
      {row, _} = prepare(ctx)
      if is_binary(content), do: File.write!(row.identity_path, content)
      assert {:error, _} = settle(ctx, row)
      {:ok, _} = DB.query(ctx.db, "UPDATE harness_processes SET preparationBootIdentity='previous-boot' WHERE launchId=?1", [row.launch_id])
      if content == :absent do
        assert {:ok, %{proof: :reboot_since_preparation}} = settle(ctx, row)
      else
        assert :ok = HarnessProcess.reconcile(ctx.db)
      end
      refute HarnessProcess.fenced?(ctx.db, @key)
    end
  end

  test "legacy null preparation identity is not reboot proof", ctx do
    {row, _} = prepare(ctx)
    {:ok, _} = DB.query(ctx.db, "UPDATE harness_processes SET preparationBootIdentity=NULL WHERE launchId=?1", [row.launch_id])
    assert {:error, _} = settle(ctx, row)
    assert HarnessProcess.fenced?(ctx.db, @key)
  end

  test "a persistence fault rolls the row fence and lifecycle event back together", ctx do
    {row, _} = prepare(ctx)
    terminal(row)
    HarnessProcess.begin_park(ctx.db, @key)
    before = HarnessProcess.list(ctx.db)
    :ok = DB.execute(ctx.db, "CREATE TRIGGER fail_settlement BEFORE INSERT ON lifecycle_events WHEN NEW.kind='harness_launch_settled' BEGIN SELECT RAISE(ABORT,'injected persistence fault'); END")
    assert {:error, {:settlement_persistence_failed, _}} = settle(ctx, row)
    assert HarnessProcess.list(ctx.db) == before
    assert HarnessProcess.parked?(ctx.db, @key)
    assert File.exists?(row.identity_path <> ".failed")
  end

  test "successor blocks stale recovery and concurrent ordinary launches admit one row", ctx do
    {row, _} = prepare(ctx)
    terminal(row)
    assert {:ok, _} = settle(ctx, row)
    results = 1..2 |> Enum.map(fn _ -> Task.async(fn ->
      try do prepare(ctx); :created rescue RuntimeError -> :fenced end
    end) end) |> Enum.map(&Task.await/1)
    assert Enum.sort(results) == [:created, :fenced]
    assert :already_resolved = settle(ctx, row)
    assert length(HarnessProcess.list(ctx.db)) == 2
    assert HarnessProcess.fenced?(ctx.db, @key)
  end
  test "fence replacement and new fence writes wait for settlement then survive", ctx do
    for existing? <- [true, false] do
      {row, _} = prepare(ctx)
      File.write!(row.identity_path, "")
      if existing?, do: HarnessProcess.begin_park(ctx.db, @key)
      {:ok, old_fence} = DB.query(ctx.db, "SELECT requestedAt FROM harness_park_fences WHERE adapterKey=?1", [@key_name])
      at = case old_fence do [[at]] -> at; [] -> 123 end
      signal = Path.join(ctx.tmp, "proof-#{row.launch_id}")
      release = signal <> ".release"
      {_, 0} = System.cmd("mkfifo", [signal, release])
      helper = signal <> ".sh"
      File.write!(helper, "#!/bin/sh\necho observed > '#{signal}'\nread token < '#{release}'\necho after-reboot\n")
      File.chmod!(helper, 0o755)
      {:ok, _} = DB.query(ctx.db, "UPDATE harness_processes SET helperPath=?2,preparationBootIdentity='before-reboot' WHERE launchId=?1", [row.launch_id, helper])
      recovery = Task.async(fn -> settle(ctx, row) end)
      assert File.read!(signal) == "observed\n"
      parent = self()
      competing = Task.async(fn ->
        send(parent, :fence_write_attempted)
        result = DB.transaction(ctx.db, fn txn ->
          DB.Txn.q(txn, "DELETE FROM harness_park_fences WHERE adapterKey=?1", [@key_name])
          DB.Txn.q(txn, "INSERT INTO harness_park_fences(adapterKey,requestedAt) VALUES(?1,?2)", [@key_name, at])
        end)
        send(parent, :fence_write_committed)
        result
      end)
      assert_receive :fence_write_attempted
      refute_receive :fence_write_committed, 50
      File.write!(release, "continue\n")
      assert {:ok, %{proof: :reboot_since_preparation}} = Task.await(recovery)
      assert {:ok, _} = Task.await(competing)
      assert_receive :fence_write_committed
      assert {:ok, [[^at]]} = DB.query(ctx.db, "SELECT requestedAt FROM harness_park_fences WHERE adapterKey=?1", [@key_name])
      HarnessProcess.complete_park(ctx.db, @key)
    end
  end

  test "unproved crash cleanup never calls the signal helper or touches an unrelated process", ctx do
    helper = Path.join(ctx.tmp, "observed-helper")
    calls = helper <> ".calls"
    File.write!(helper, "#!/bin/sh\necho \"$1\" >> '#{calls}'\n[ \"$1\" = boot-identity ] && echo fixture-boot\nexit 0\n")
    File.chmod!(helper, 0o755)
    {row, _} = prepare(ctx, process_helper: helper)
    File.write!(row.identity_path, "")
    unrelated = Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, :exit_status,
      {:args, ["-c", "read value", row.launch_id]}])
    Application.put_env(:tightbeam, :harness_process_identity_wait_ms, 0)
    assert {:error, _} = HarnessProcess.settle_proven_dead(ctx.db, @key)
    assert {:error, _} = HarnessProcess.park(ctx.db, row)
    assert {:error, _} = settle(ctx, row)
    assert [%{resolved_at: nil}] = HarnessProcess.list(ctx.db)
    assert HarnessProcess.fenced?(ctx.db, @key)
    refute File.read!(calls) =~ "harness-group"
    assert Port.info(unrelated, :os_pid) != nil
    Port.command(unrelated, "done\n")
    assert_receive {^unrelated, {:exit_status, 0}}, 2_000
  end

end
