defmodule Tightbeam.LiveBaseDBAdmissionTest do
  use Tightbeam.TestCase, async: false

  defp refused_start(opts) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        result = Tightbeam.DB.start_link(opts)
        send(parent, {self(), :start_result, result})
      end)

    assert_receive {^pid, :start_result, result}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    result
  end

  alias Tightbeam.{DB, Schema}
  @moduletag :tmp_dir

  @tag :runtime_payload
  test "cold loaded payload admits persistent DB, refreshes stamp and hands off ownership", %{
    tmp_dir: tmp
  } do
    run_cold_runtime(tmp, "live_base_runtime.exs", "persistent-owner-refresh-handoff: ok")
  end

  @tag :boot_ordering
  test "Boot and direct Gateway reject foreign bases before startup writes", %{tmp_dir: tmp} do
    run_cold_runtime(tmp, "live_base_boot_runtime.exs", "boot-admission-ordering: ok")
  end

  @tag :boot_business_recovery
  test "guarded Boot loads row recognition before retired-decision recovery", %{tmp_dir: tmp} do
    run_cold_runtime(tmp, "live_base_recovery_runtime.exs", "guarded-business-recovery: ok")
  end

  @tag :application_runtime
  test "ordinary Application starts only inside the prepared guarded arena", %{tmp_dir: tmp} do
    run_cold_runtime(tmp, "live_base_application_runtime.exs", "guarded-application-startup: ok")
  end

  defp run_cold_runtime(tmp, script, expected),
    do: Tightbeam.GuardRuntimeFixture.run!(tmp, script, expected)

  @tag :marker_publication
  test "Application child construction does not create or initialize the base", %{tmp_dir: tmp} do
    base = Path.join(tmp, "children-only")
    config = %{base_dir: base, guard_inputs: [lock_dir: tmp]}
    children = Tightbeam.Application.children(config)
    assert [{DB, options}, {Tightbeam.Boot, ^config} | _] = children
    assert options[:guard_inputs] == config.guard_inputs
    refute File.exists?(base)
  end

  @tag :db_refusal
  test "persistent DB refuses missing guard inputs before creating its base", %{tmp_dir: tmp} do
    base = Path.join(tmp, "missing-inputs")

    assert {:error, {%KeyError{key: :guard_inputs}, _}} =
             refused_start(path: Path.join(base, "state.db"), name: nil)

    refute File.exists?(base)
  end

  @tag :db_refusal
  test "a public true handoff cannot admit a persistent database", %{tmp_dir: tmp} do
    base = Path.join(tmp, "boolean-handoff")

    assert {:error, {%ArgumentError{message: message}, _}} =
             refused_start(path: Path.join(base, "state.db"), name: nil, guard_context: true)

    assert message =~ "owned native capability"
    refute File.exists?(base)
  end

  @tag :db_refusal
  test "raw inputs cannot substitute an arbitrary running payload", %{tmp_dir: tmp} do
    base = Path.join(tmp, "fake-payload")

    assert {:error, {%ArgumentError{message: message}, _}} =
             refused_start(
               path: Path.join(base, "state.db"),
               name: nil,
               guard_inputs: [lock_dir: tmp, payload_root: tmp]
             )

    assert message =~ "only lock_dir and exact transition"
    refute File.exists?(base)
  end

  test "explicit memory database retains normal fresh schema and repeat checks" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[stamp]]} = DB.query(db, "SELECT shape FROM schema_stamp", [])
    assert stamp == hd(Schema.guard_compatible_stamps())
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[^stamp]]} = DB.query(db, "SELECT shape FROM schema_stamp", [])
  end
end
