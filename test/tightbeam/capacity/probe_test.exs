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

  test "known rate limits preserve the delay and unknown output gets a fixed error" do
    assert {:error, %{code: "UPSTREAM_RATE_LIMITED", retry_after_seconds: 89}} =
             CapacityProbe.decode(
               ~s({"error":{"code":"UPSTREAM_RATE_LIMITED","retryAfterSeconds":89}})
             )

    assert {:error, %{code: "UPSTREAM_CONTRACT_CHANGED"}} =
             CapacityProbe.decode(~s({"error":{"code":"provider-private-output"}}))
  end
end
