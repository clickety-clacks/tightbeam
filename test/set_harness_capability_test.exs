defmodule Tightbeam.SetHarnessCapabilityTest do
  use ExUnit.Case, async: true

  alias Tightbeam.StateResources

  @registry ["claude", "codex"]

  test "active sessions expose ordered choices and disable only their resident harness" do
    row = %{state: "active", harness: "claude"}

    assert StateResources.set_harness_capability(row, @registry) == %{
             "supported" => true,
             "options" => [
               %{"title" => "claude", "value" => "claude", "enabled" => false},
               %{"title" => "codex", "value" => "codex", "enabled" => true}
             ]
           }
  end

  test "inactive sessions use the exact unsupported shape before alternate availability" do
    assert StateResources.set_harness_capability(
             %{state: "retired", harness: "claude"},
             ["claude"]
           ) == %{"supported" => false, "reason" => "session is not active"}
  end

  test "active sessions with no alternate have the exact unsupported shape" do
    assert StateResources.set_harness_capability(
             %{state: "active", harness: "claude"},
             ["claude"]
           ) == %{"supported" => false, "reason" => "no alternate harness is registered"}
  end

  test "a resident harness outside the ordered registry refuses the complete capability" do
    assert_raise ArgumentError, "sessions.harness is not registered", fn ->
      StateResources.set_harness_capability(
        %{state: "active", harness: "private-harness"},
        @registry
      )
    end
  end

  test "empty, duplicate, or invalid registries refuse rather than inventing options" do
    row = %{state: "active", harness: "claude"}

    assert_raise ArgumentError, fn -> StateResources.set_harness_capability(row, []) end

    assert_raise ArgumentError, fn ->
      StateResources.set_harness_capability(row, ["claude", ""])
    end

    assert_raise ArgumentError, fn ->
      StateResources.set_harness_capability(row, ["claude", "claude"])
    end

    assert_raise ArgumentError, fn ->
      StateResources.set_harness_capability(row, %{"claude" => 1})
    end
  end

  test "derivation depends only on session state, resident harness, and the registry" do
    minimal = %{state: "active", harness: "claude"}

    private_row =
      Map.merge(minimal, %{
        provider: "private-provider",
        model: "private-model",
        cli_token: "never-public",
        identity_name: "private-identity",
        host: "private-host",
        readiness: :unknown,
        runtime_state: :busy
      })

    expected = StateResources.set_harness_capability(minimal, @registry)
    assert StateResources.set_harness_capability(private_row, @registry) == expected
    refute inspect(expected) =~ "private"
  end
end
