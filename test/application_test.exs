defmodule Tightbeam.ApplicationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, RuleRuntime}

  @tag guard_compat_remaining: true, tmp_dir: true
  test "boot on a fresh database creates every schema before recovery", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "live_base_fresh_runtime.exs",
      "guarded-fresh-application: ok"
    )
  end

  @tag guard_compat_remaining: true, tmp_dir: true
  test "production child sequence installs row recognition before Boot recovery", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "live_base_recovery_runtime.exs",
      "guarded-business-recovery: ok"
    )
  end

  @tag :guard_compat_remaining
  test "row commits refuse when recognition has not been installed" do
    :persistent_term.erase(RuleRuntime)

    assert_raise RuntimeError, "row rule recognition is not loaded", fn ->
      RuleRuntime.row_commit_effects_in_txn(%DB.Txn{conn: nil}, [])
    end
  end

  @tag :guard_compat_remaining
  test "harness projection publication never exposes truncated bytes" do
    base =
      Path.join(System.tmp_dir!(), "tb_boot_atomic_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    first = JSON.encode!([%{"id" => "first", "padding" => String.duplicate("a", 1_000_000)}])
    second = JSON.encode!([%{"id" => "second", "padding" => String.duplicate("b", 1_000_000)}])
    Tightbeam.Boot.write_harnesses!(base, first)

    writer =
      Task.async(fn ->
        for encoded <- List.duplicate([second, first], 25) |> List.flatten() do
          Tightbeam.Boot.write_harnesses!(base, encoded)
        end
      end)

    path = Path.join(base, "harnesses.json")

    Stream.repeatedly(fn -> File.read!(path) end)
    |> Enum.reduce_while(:ok, fn observed, :ok ->
      assert observed in [first, second]

      case Task.yield(writer, 0) do
        nil -> {:cont, :ok}
        {:ok, _writes} -> {:halt, :ok}
      end
    end)
  end

  @tag cold_admission: true, tmp_dir: true
  test "production entry refuses a broken harness on PATH without creating any org artifact", %{
    tmp_dir: tmp
  } do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "live_base_harness_refusal.exs",
      "no usable harness CLI is installed",
      exit: 1
    )

    refute File.exists?(Path.join(tmp, "base"))
  end

  # Actual production halt is confined to the cold subprocess above; the
  # dedicated application_refusal_test retains broader process-exit assertions.

  @tag cold_admission: true, tmp_dir: true
  test "production entry refuses a broken identity before business recovery", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "live_base_identity_refusal.exs",
      "guarded-identity-refusal: ok"
    )
  end
end
