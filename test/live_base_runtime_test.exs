defmodule Tightbeam.LiveBaseRuntimeTest do
  # The guard decides admission in DB.init, before the base exists, so these
  # cannot be demonstrated inside a suite whose DB is already running against a
  # shared base. Each test assembles an immutable payload the guard can
  # identify, then starts a separate BEAM on it with its own temporary base.
  use ExUnit.Case, async: false
  alias Tightbeam.GuardRuntimeFixture, as: Fixture
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  test "a fresh install admits, creates its base, and starts", %{tmp_dir: tmp} do
    Fixture.run!(tmp, "live_base_fresh_runtime.exs", "guarded-fresh-application: ok")
  end

  test "2026-09-01 boot and gateway refuse a foreign base before any base write", %{tmp_dir: tmp} do
    Fixture.run!(tmp, "live_base_boot_runtime.exs", "boot-admission-ordering: ok")
    assert File.regular?(Path.join(tmp, "base/build-owner.json"))
    refute File.exists?(Path.join(tmp, "foreign-base"))
  end
end
