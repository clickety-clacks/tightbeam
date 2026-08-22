defmodule Tightbeam.IdentityApply.RuntimeAdapterTest do
  use ExUnit.Case, async: true

  alias Tightbeam.IdentityApply.RuntimeAdapter

  test "capability refusal is injectable without invoking a runtime adapter" do
    session = %{harness: "codex"}

    assert RuntimeAdapter.capabilities(session, %{
             identity_apply_capabilities: fn ^session -> :unsupported end
           }) == :unsupported
  end

  test "known harness metadata admits the recoverable adapter contract" do
    assert RuntimeAdapter.capabilities(%{harness: "codex"}, %{}) == :supported
    assert RuntimeAdapter.capabilities(%{harness: "claude"}, %{}) == :supported
  end
end
