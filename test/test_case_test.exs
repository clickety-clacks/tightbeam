defmodule Tightbeam.TestCaseTest do
  use Tightbeam.TestCase, async: false

  @app_existing :test_case_existing
  @app_added :test_case_added
  @system_existing "TIGHTBEAM_TEST_CASE_EXISTING"
  @system_added "TIGHTBEAM_TEST_CASE_ADDED"

  test "restore preserves presence and removes newly introduced environment values" do
    Application.put_env(:tightbeam, @app_existing, false)
    Application.delete_env(:tightbeam, @app_added)
    System.put_env(@system_existing, "")
    System.delete_env(@system_added)
    :persistent_term.put(Tightbeam.Rules, [:baseline])

    snapshot = Tightbeam.TestCase.snapshot()

    Application.delete_env(:tightbeam, @app_existing)
    Application.put_env(:tightbeam, @app_added, :added)
    System.delete_env(@system_existing)
    System.put_env(@system_added, "added")
    :persistent_term.erase(Tightbeam.Rules)

    Tightbeam.TestCase.restore(snapshot)

    assert Application.fetch_env(:tightbeam, @app_existing) == {:ok, false}
    assert Application.fetch_env(:tightbeam, @app_added) == :error
    assert System.fetch_env(@system_existing) == {:ok, ""}
    assert System.fetch_env(@system_added) == :error
    assert :persistent_term.get(Tightbeam.Rules) == [:baseline]
  end

  # Scoped to restore/1 itself: an aborted body leaves behind keys it introduced,
  # and restoring over them has to take them back out. That the template's own
  # on_exit fires after a genuinely failing ExUnit test is ExUnit's guarantee, and
  # no sibling test can observe it — on_exit callbacks run in reverse registration
  # order, so anything registered from a test body runs before the template's.
  test "restore/1 removes a key the raising body introduced" do
    :persistent_term.erase(Tightbeam.Rails)
    snapshot = Tightbeam.TestCase.snapshot()

    assert_raise RuntimeError, "failed body", fn ->
      try do
        :persistent_term.put(Tightbeam.Rails, [:leaked])
        raise "failed body"
      after
        Tightbeam.TestCase.restore(snapshot)
      end
    end

    sentinel = make_ref()
    assert :persistent_term.get(Tightbeam.Rails, sentinel) == sentinel
  end

  test "all synchronous test modules use the global-state case template" do
    offenders =
      __DIR__
      |> Path.join("**/*_test.exs")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        source = File.read!(path)

        Regex.match?(~r/use ExUnit\.Case(?!,\s*async:\s*true)/, source)
      end)

    assert offenders == []
  end
end
