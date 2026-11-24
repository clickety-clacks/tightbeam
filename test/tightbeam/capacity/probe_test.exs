defmodule Tightbeam.Harness.CapacityProbeTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.CapacityProbe

  test "only the normalized projection crosses the harness boundary" do
    response = %{
      sample: %{
        observedAt: 1000,
        accountId: "opaque-to-probe",
        raw: %{providerAccountId: "sensitive-fixture"},
        plan: "max",
        windows: [
          %{
            id: "five_hour",
            scope: "account",
            name: "Five hour",
            usedPercent: 0.25,
            resetsAt: nil,
            windowSeconds: 18_000
          }
        ],
        diagnostics: [],
        subscription: %{status: "active", observedAt: 1000, email: "sensitive-fixture"}
      }
    }

    assert {:ok, sample} = CapacityProbe.decode(JSON.encode!(response))

    assert Map.keys(sample) |> Enum.sort() == [
             :diagnostics,
             :observed_at,
             :plan,
             :subscription,
             :windows
           ]

    assert sample.plan == "max"
    assert [%{used_percent: 0.25, model: nil, resets_at: nil}] = sample.windows
    refute inspect(sample) =~ "sensitive-fixture"
  end

  test "profile hold survives the closed projection and blocks all provider reads" do
    alias Tightbeam.Capacity.ReadPolicy

    observed_at = 1_800_000_000_000

    assert {:ok, %{profile_hold: profile_hold, windows: [%{used_percent: 42}]}} =
             CapacityProbe.decode("""
             {"sample":{"observedAt":1800000000000,"windows":[{"id":"five_hour","name":"Five hour","scope":"account","usedPercent":42}],"diagnostics":[],"profileHold":{"code":"UPSTREAM_RATE_LIMITED","retryAfterSeconds":3600,"discarded":"private"}}}
             """)

    assert profile_hold == %{code: "UPSTREAM_RATE_LIMITED", retry_after_seconds: 3600}
    retry_at = ReadPolicy.retry_at(profile_hold, observed_at)
    entry = %{attempted_at: observed_at, retry_at: retry_at}
    assert ReadPolicy.action(entry, :background, observed_at + :timer.minutes(15)) == :held
    assert ReadPolicy.action(entry, :wait, observed_at + :timer.minutes(15)) == :held
    assert ReadPolicy.due_at(entry, observed_at) == observed_at + :timer.hours(1)
    assert ReadPolicy.action(entry, :wait, retry_at) == :wait
  end

  test "known rate limits preserve the delay and unknown output gets a fixed error" do
    assert {:error, %{code: "UPSTREAM_RATE_LIMITED", retry_after_seconds: 89}} =
             CapacityProbe.decode(
               ~s({"error":{"code":"UPSTREAM_RATE_LIMITED","retryAfterSeconds":89}})
             )

    assert {:error, %{code: "UPSTREAM_CONTRACT_CHANGED"}} =
             CapacityProbe.decode(~s({"error":{"code":"provider-private-output"}}))
  end
end
