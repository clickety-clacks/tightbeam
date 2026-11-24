defmodule Tightbeam.Capacity.ViewTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Capacity.{Observation, View}

  @now 1_800_000_000_000
  @account %{
    "id" => "acct_fixture",
    "provider" => "anthropic",
    "label" => "Configured label",
    "loginState" => "signed_in",
    "identityKey" => "private-fixture"
  }

  test "usage and forecast remain separate and usage exposes the current serving state" do
    sample = %{
      plan: "max",
      observed_at: @now - 1_000,
      windows: [%{id: "five_hour", used_percent: 42}],
      diagnostics: [],
      subscription: %{status: "active", observed_at: @now},
      raw: %{"provider_account_id" => "sensitive-fixture"}
    }

    result = %{status: "cache", sample: sample, error: nil}

    assert %{sample: %{age_seconds: 1, serving: true, label: "Configured label"}} =
             usage = View.usage(@account, result, nil, true, @now)

    assert usage.summary.subscription_status == "active"
    refute inspect(usage) =~ "sensitive-fixture"
    refute inspect(usage) =~ "private-fixture"

    assert %{counts: %{"cache" => 1, "error" => 0, "stale" => 0, "live" => 0}} =
             View.aggregate_usage([usage], @now)

    assert %{status: "history_persistence_error"} =
             View.forecast(@account, %{Observation.empty() | sample: sample}, @now,
               history_error: "HISTORY_PERSISTENCE_ERROR"
             )
  end

  test "an empty snapshot and an account with missing usage are honest" do
    assert %{results: [], counts: %{"error" => 0}} = View.aggregate_usage([], @now)

    account = Map.put(@account, "loginState", "unknown")
    result = %{status: "error", sample: nil, error: nil}

    assert %{
             sample: nil,
             summary: %{
               usage_freshness: "none",
               account_state: "unknown",
               plan_unknown_reason: "not_yet_observed"
             }
           } =
             View.usage(account, result, nil, false, @now)

    assert %{samples: [], earliest_observed_at: nil, latest_observed_at: nil} =
             View.history(account, [], @now)
  end
end
