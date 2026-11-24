defmodule Tightbeam.Capacity.ForecastTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Capacity.{Forecast, History, Pools, ReadPolicy, Summary}

  @hour :timer.hours(1)
  @now 1_800_000_000_000

  test "retention keeps the decline boundary even at high refresh frequency" do
    sample = fn offset, percent -> sample(@now + offset, percent) end

    history =
      History.retain(
        [
          sample.(-8 * 24 * @hour, 80),
          sample.(0, 10),
          sample.(1_000, 30),
          sample.(2_000, 20),
          sample.(3_000, 25),
          sample.(4_000, 26)
        ],
        @now + 4_000
      )

    assert Enum.map(history, &hd(&1.windows).used_percent) == [30, 20, 26]
  end

  test "capped intervals do not mask observed burn" do
    history = [
      sample(@now - 3 * @hour, 60),
      sample(@now - 2 * @hour, 80),
      sample(@now - @hour, 100),
      sample(@now, 100)
    ]

    forecast = Forecast.account("acct_one", "openai", "ready", history, @now)

    assert forecast.status == "estimated_qualified"
    assert forecast.exhaustion_at == @now
    assert [window] = forecast.windows
    assert window.status == "exhausted"
    assert window.rate_percent_per_hour == 20
    assert window.coverage_48h_hours == 2
    assert Enum.map(window.diagnostics, & &1.code) == ["USAGE_CAPPED_DEMAND_CENSORED"]
  end

  test "rate anchors to the latest observation and never crosses a plan break" do
    last = @now - :timer.minutes(15)

    history = [
      sample(last - 3 * @hour, 0),
      %{sample(last - 2 * @hour, 10) | plan: "pro"},
      sample(last - @hour, 20),
      sample(last, 30)
    ]

    forecast = Forecast.account("acct_one", "openai", "ready", history, @now)
    assert forecast.exhaustion_at == last + 7 * @hour

    assert [%{rate_percent_per_hour: 10.0, coverage_48h_hours: 1.0, sample_count_48h: 2}] =
             forecast.windows

    assert [%{code: "USAGE_PLAN_CHANGED"}] = forecast.diagnostics
  end

  test "past resets are stale and stale or reauth pool members cannot supply rates" do
    history = [sample(@now - @hour, 0, @now - 1), sample(@now, 10, @now - 1)]
    stale = Forecast.account("acct_stale", "openai", "ready", history, @now)
    reauth = Forecast.account("acct_reauth", "openai", "reauth_required", history, @now)

    assert stale.status == "stale"
    assert reauth.status == "reauth_required"

    assert %{status: "incomplete", pools: [pool]} =
             Pools.aggregate([{stale, "One", nil}, {reauth, "Two", nil}], @now)

    assert pool.status == "reauth_required"
    assert pool.exhaustion_at == nil
    assert pool.missing_rate_member_count == 2
  end

  test "pool exhaustion respects the earliest reset, including an idle member" do
    idle_history = [sample(@now - @hour, 0, @now + 2 * @hour), sample(@now, 0, @now + 2 * @hour)]

    busy_history = [
      sample(@now - @hour, 10, @now + 20 * @hour),
      sample(@now, 20, @now + 20 * @hour)
    ]

    idle = Forecast.account("acct_idle", "openai", "ready", idle_history, @now)
    busy = Forecast.account("acct_busy", "openai", "ready", busy_history, @now)

    assert %{status: "estimated", pools: [pool]} =
             Pools.aggregate([{idle, "Idle", nil}, {busy, "Busy", nil}], @now)

    assert pool.status == "resets_before_exhaustion"
    assert pool.current_workload_rate_percent_points_per_hour == 10
    assert pool.remaining_percent_points == 180
    assert pool.measured_member_count == 2
  end

  test "a stale reading retains last usage and an elapsed subscription period is unknown" do
    prior = sample(@now - @hour, 80)
    sample = Map.put(prior, :subscription, %{observed_at: @now - @hour, period_end_at: @now - 1})
    result = %{sample: sample, status: "stale", error: %{code: "UPSTREAM_RATE_LIMITED"}}
    account = %{provider: "openai", label: "One", status: "ready"}

    assert %{
             plan: "plus",
             usage_freshness: "stale",
             usage_freshness_reason: "UPSTREAM_RATE_LIMITED",
             usage_age_seconds: 3600,
             subscription_status: "unknown",
             subscription_status_reason: "period_end_passed"
           } = Summary.build(account, result, nil, @now)
  end

  test "a distant estimate is suppressed when there is a known intervening reset" do
    assert {"estimate_out_of_range", nil} = Forecast.project(@now, 90, 0.00000001, nil)

    assert {"resets_before_exhaustion", nil} =
             Forecast.project(@now, 90, 0.00000001, @now + 24 * @hour)
  end

  test "operator refresh respects a provider hold and uses the retained sample" do
    sample = sample(@now - 1000, 43)
    entry = %{sample: sample, retry_at: @now + @hour, attempted_at: @now}
    error = %{code: "UPSTREAM_RATE_LIMITED"}

    assert ReadPolicy.action(entry, :wait, @now) == :held
    assert ReadPolicy.action(entry, :background, @now) == :held
    assert ReadPolicy.action(entry, :wait, @now + @hour) == :wait
    assert ReadPolicy.due_at(entry, @now) == @now + @hour

    assert %{status: "stale", sample: ^sample, error: ^error} =
             ReadPolicy.result("acct_one", sample, error, :retained)
  end

  test "a known identity contributes capacity once while each login remains visible" do
    build = fn id, latest, percent ->
      Forecast.account(
        id,
        "openai",
        "ready",
        [sample(latest - @hour, percent - 10), sample(latest, percent)],
        @now
      )
    end

    stale = build.("acct_stale", @now - @hour, 20)
    fresh = build.("acct_fresh", @now, 25)
    tied = build.("acct_tied", @now, 40)
    unknown = build.("acct_unknown", @now, 10)

    aggregate =
      Pools.aggregate(
        [
          {stale, "Stale", "identity"},
          {tied, "Tied", "identity"},
          {fresh, "Fresh", "identity"},
          {unknown, "Unknown", nil}
        ],
        @now
      )

    assert Enum.map(aggregate.accounts, & &1.account_id) ==
             ~w(acct_fresh acct_stale acct_tied acct_unknown)

    assert [pool] = aggregate.pools
    assert Enum.map(pool.members, & &1.account_id) == ~w(acct_fresh acct_unknown)
    assert pool.remaining_percent_points == 165
    refute inspect(aggregate) =~ "identity"
  end

  defp sample(at, percent, reset \\ nil) do
    %{
      observed_at: at,
      plan: "plus",
      windows: [
        %{
          id: "primary",
          name: "Primary",
          used_percent: percent,
          window_seconds: 18_000,
          resets_at: reset
        }
      ]
    }
  end
end
