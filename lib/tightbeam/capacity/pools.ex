defmodule Tightbeam.Capacity.Pools do
  @moduledoc false
  alias Tightbeam.Capacity.Forecast

  @hour :timer.hours(1)
  @complete ~w(estimated zero_burn resets_before_exhaustion)
  @unmeasurable ~w(stale reauth_required history_persistence_error account_degraded)
  @incomplete ~w(stale unknown_reset gapped_history plan_changed insufficient_history estimate_out_of_range history_persistence_error account_degraded)
  @assumptions [
    "Pool rates assume recent demand continues at the measured current-workload rate.",
    "Pool estimates assume work can be redistributed among accounts in the same comparable pool.",
    "Multiple windows can overlap or constrain the same account, so pooled ETA is optimistic redistribution arithmetic, not a routing guarantee.",
    "Providers, plans, window IDs, and window durations remain separate quotas."
  ]

  def aggregate(accounts_with_labels, now) do
    accounts_with_labels =
      Enum.sort_by(accounts_with_labels, fn {account, _} -> account.account_id end)

    accounts = Enum.map(accounts_with_labels, &elem(&1, 0))

    pools =
      accounts_with_labels
      |> Enum.flat_map(fn {account, label} ->
        Enum.map(account.windows, fn window ->
          {pool_key(account, window), account, label, window}
        end)
      end)
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {key, entries} -> pool(key, entries, now) end)
      |> Enum.sort_by(& &1.key)

    comparable? = Enum.any?(pools, & &1.comparable)
    providers = accounts |> Enum.map(& &1.provider) |> Enum.uniq()

    status =
      cond do
        not comparable? ->
          "unavailable"

        Enum.any?(pools, &(&1.status not in @complete)) ->
          "incomplete"

        Enum.any?(
          accounts,
          &(&1.status not in @complete or &1.account_status != "ready" or &1.windows == [])
        ) ->
          "incomplete"

        true ->
          "estimated"
      end

    diagnostics =
      cond do
        accounts == [] ->
          [%{code: "NO_ACCOUNTS", message: "No registered accounts have forecast capacity."}]

        true ->
          []
          |> add_diagnostic(
            length(providers) > 1,
            "SEPARATE_PROVIDERS",
            "Codex and Claude quotas are shown in separate pools and are never added together."
          )
          |> add_diagnostic(
            not comparable?,
            "NO_COMPARABLE_POOL",
            "No pool has a known common plan and window duration. Account forecasts remain available separately."
          )
      end

    %{
      generated_at: now,
      status: status,
      accounts: accounts,
      pools: pools,
      diagnostics: diagnostics,
      assumptions: @assumptions
    }
  end

  defp pool_key(account, window) do
    %{provider: provider, account_id: id, plan: plan} = account

    cond do
      plan in [nil, ""] ->
        {"#{provider}:unknown-plan:#{id}:#{window.id}", "singleton_unknown_plan"}

      is_nil(window.window_seconds) or window.window_seconds <= 0 ->
        {"#{provider}:#{plan}:#{window.id}:unknown-duration:#{id}",
         "singleton_unknown_window_duration"}

      true ->
        {"#{provider}:#{plan}:#{window.id}:#{window.window_seconds}", "same_capacity"}
    end
  end

  defp pool({key, compatibility}, [{_, first, _, first_window} | _] = entries, now) do
    members =
      Enum.map(entries, fn {_, account, label, window} -> member(account, label, window) end)

    {measured, missing} = Enum.split_with(members, &measured?/1)
    remaining = Enum.sum(Enum.map(members, & &1.remaining_percent))
    rate = sum_rate(measured, :rate_percent_per_hour)

    pool = %{
      key: key,
      provider: first.provider,
      plan: first.plan,
      plan_known: first.plan not in [nil, ""],
      window_id: first_window.id,
      window_name: first_window.name,
      window_seconds: first_window.window_seconds,
      compatibility: compatibility,
      comparable: compatibility == "same_capacity",
      members: members,
      remaining_percent_points: remaining,
      effective_remaining_percent_points: 0,
      current_workload_rate_percent_points_per_hour: rate,
      rate_24h_percent_points_per_hour: sum_rate(measured, :rate_24h_percent_per_hour),
      rate_48h_percent_points_per_hour: sum_rate(measured, :rate_48h_percent_per_hour),
      coverage_hours: Enum.min(Enum.map(members, & &1.coverage_hours)),
      lookback_hours:
        entries |> Enum.map(fn {_, _, _, window} -> window.lookback_48h_hours end) |> Enum.min(),
      measured_member_count: length(measured),
      capacity_member_count: length(members),
      missing_rate_member_count: length(missing),
      exhaustion_at: nil,
      diagnostics: member_diagnostics(entries)
    }

    cond do
      Enum.any?(members, &(&1.status == "reauth_required")) ->
        finish_without_estimate(pool, "reauth_required", missing)

      missing != [] or Enum.any?(members, &(&1.status in @incomplete)) ->
        finish_without_estimate(pool, "incomplete", missing)

      is_nil(rate) or rate <= 0 ->
        Map.put(pool, :status, "zero_burn")

      true ->
        estimate(pool, now, rate)
    end
  end

  defp estimate(pool, now, rate) do
    remaining =
      pool.members
      |> Enum.map(fn member ->
        rate = member.rate_percent_per_hour || 0
        age = max(0, now - (member.observed_at || now)) / @hour
        max(0, member.remaining_percent - rate * age)
      end)
      |> Enum.sum()

    next_reset =
      pool.members
      |> Enum.map(& &1.resets_at)
      |> Enum.filter(&(is_integer(&1) and &1 > now))
      |> Enum.min(fn -> nil end)

    pool = %{pool | effective_remaining_percent_points: remaining}

    {status, at, diagnostics} =
      case Forecast.project(now, remaining, rate, next_reset) do
        {"steady", at} ->
          diagnostics =
            add_diagnostic(
              pool.diagnostics,
              not pool.comparable,
              "POOL_COMPATIBILITY_UNKNOWN",
              "This account is shown alone because plan or window capacity is unknown."
            )

          {"estimated", at, diagnostics}

        {"resets_before_exhaustion", nil} ->
          diagnostics =
            add_diagnostic(
              pool.diagnostics,
              true,
              "POOL_RESET_BEFORE_EXHAUSTION",
              "The earliest member reset occurs before the pooled estimate."
            )

          {"resets_before_exhaustion", nil, diagnostics}

        {"estimate_out_of_range", nil} ->
          diagnostics =
            add_diagnostic(
              pool.diagnostics,
              true,
              "POOL_ESTIMATE_OUT_OF_RANGE",
              "The pooled burn is too small for a representable exhaustion time."
            )

          {"incomplete", nil, diagnostics}
      end

    Map.merge(pool, %{status: status, exhaustion_at: at, diagnostics: diagnostics})
  end

  defp finish_without_estimate(pool, status, missing) do
    diagnostics =
      add_diagnostic(
        pool.diagnostics,
        missing != [],
        "POOL_MISSING_BURN",
        "At least one member has no finite recent burn estimate, so the pool ETA is qualified."
      )

    Map.merge(pool, %{status: status, diagnostics: diagnostics})
  end

  defp member(account, label, window) do
    status =
      cond do
        account.status in ~w(reauth_required stale history_persistence_error) -> account.status
        account.history_error != nil -> "history_persistence_error"
        account.account_status != "ready" -> "account_degraded"
        true -> window.status
      end

    window
    |> Map.take(
      ~w(remaining_percent resets_at exhaustion_at rate_percent_per_hour rate_24h_percent_per_hour rate_48h_percent_per_hour)a
    )
    |> Map.merge(%{
      account_id: account.account_id,
      label: label,
      status: status,
      observed_at: account.latest_observed_at,
      coverage_hours: window.coverage_48h_hours,
      sample_count: window.sample_count_48h
    })
  end

  defp measured?(member) do
    member.status == "zero_burn" or
      (member.rate_percent_per_hour != nil and member.status not in @unmeasurable)
  end

  defp sum_rate(measured, key) do
    case Enum.flat_map(measured, fn member -> List.wrap(Map.fetch!(member, key)) end) do
      [] -> nil
      rates -> Enum.sum(rates)
    end
  end

  defp member_diagnostics(entries) do
    Enum.reduce(entries, [], fn {_, account, _, window}, diagnostics ->
      diagnostics
      |> add_diagnostic(
        account.status == "estimated_qualified",
        "POOL_ACCOUNT_QUALIFIED",
        "The account has another usage window without a finite estimate; this pool remains usable on its own."
      )
      |> add_diagnostic(
        Enum.any?(window.diagnostics, &(&1.code == "USAGE_CAPPED_DEMAND_CENSORED")),
        "POOL_CAPPED_DEMAND_CENSORED",
        "A member reached 100%; flat capped intervals do not measure demand."
      )
    end)
  end

  defp add_diagnostic(existing, false, _, _), do: existing

  defp add_diagnostic(existing, true, code, message),
    do: existing ++ [%{code: code, message: message}]
end
