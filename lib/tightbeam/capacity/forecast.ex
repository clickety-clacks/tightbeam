defmodule Tightbeam.Capacity.Forecast do
  @moduledoc """
  Estimates quota burn from retained samples. All times are epoch milliseconds.
  Requests for forecasts never read credentials or call providers.
  """

  alias Tightbeam.Capacity.History

  @hour :timer.hours(1)
  @stale_after :timer.minutes(30)
  @max_gap :timer.hours(2)
  @max_estimate_ms div(9_223_372_036_854_775_807, 1_000_000)
  @estimated ~w(steady exhausted resets_before_exhaustion)
  @qualified_diagnostics ~w(USAGE_CAPPED_DEMAND_CENSORED USAGE_UNKNOWN_RESET)
  @plan_change %{
    code: "USAGE_PLAN_CHANGED",
    message: "Older observations use a different plan and were excluded from the rate."
  }

  def account(id, provider, account_status, samples, now, opts \\ []) do
    latest = List.last(samples)
    history_error = Keyword.get(opts, :history_error)

    base = %{
      account_id: id,
      provider: provider,
      plan: latest && latest.plan,
      generated_at: now,
      status: initial_status(account_status, latest, now),
      account_status: account_status,
      history_sample_count: length(samples),
      coverage_hours: 0,
      lookback_hours: 0,
      latest_observed_at: latest && latest.observed_at,
      current_sample_age_seconds: Keyword.get(opts, :current_sample_age_seconds),
      history_error: history_error,
      exhaustion_at: nil,
      limiting_window_id: nil,
      limiting_window_name: nil,
      qualification: nil,
      windows: [],
      diagnostics: []
    }

    case latest do
      nil when not is_nil(history_error) and base.status != "reauth_required" ->
        %{base | status: "history_persistence_error"}

      nil ->
        base

      latest ->
        plan_changed? = Enum.any?(samples, &(&1.plan != latest.plan))
        windows = Enum.map(latest.windows, &window(samples, latest, &1, now, plan_changed?))

        base
        |> Map.merge(%{
          windows: windows,
          coverage_hours: Enum.reduce(windows, 0, &max(&1.coverage_48h_hours, &2)),
          lookback_hours: Enum.reduce(windows, 0, &max(&1.lookback_48h_hours, &2)),
          diagnostics: if(plan_changed?, do: [@plan_change], else: [])
        })
        |> account_estimate()
    end
  end

  defp initial_status("reauth_required", _, _), do: "reauth_required"

  defp initial_status(_, %{observed_at: observed}, now) when now - observed > @stale_after,
    do: "stale"

  defp initial_status(_, _, _), do: "insufficient_history"

  defp account_estimate(base) do
    %{windows: windows, generated_at: now} = base

    limiting =
      windows
      |> Enum.flat_map(fn
        %{status: "exhausted"} = window -> [{now, window}]
        %{status: "steady", exhaustion_at: at} = window -> [{at, window}]
        _ -> []
      end)
      |> Enum.min_by(&elem(&1, 0), fn -> nil end)

    qualified? =
      limiting != nil and
        Enum.any?(windows, fn window ->
          window.status not in ~w(steady exhausted zero_burn) or
            Enum.any?(window.diagnostics, &(&1.code in @qualified_diagnostics))
        end)

    status =
      cond do
        base.status == "reauth_required" -> "reauth_required"
        base.status == "stale" or Enum.any?(windows, &(&1.status == "stale")) -> "stale"
        base.history_error != nil -> "history_persistence_error"
        windows == [] -> "windows_missing"
        Enum.all?(windows, &(&1.status == "zero_burn")) -> "zero_burn"
        qualified? -> "estimated_qualified"
        Enum.any?(windows, &(&1.status in @estimated)) -> "estimated"
        true -> "insufficient_history"
      end

    case limiting do
      {at, window} ->
        %{
          base
          | status: status,
            exhaustion_at: at,
            limiting_window_id: window.id,
            limiting_window_name: window.name,
            qualification:
              if(status == "estimated_qualified",
                do: "At least one other usage window has no finite estimate."
              )
        }

      nil ->
        %{base | status: status}
    end
  end

  defp window(samples, latest, window, now, plan_changed?) do
    points =
      samples
      |> Enum.reverse()
      |> Enum.reduce_while([], fn sample, points ->
        point = Enum.find(sample.windows, &(&1.id == window.id))

        if (sample.plan == latest.plan and point) && point.window_seconds == window.window_seconds do
          {:cont, [Map.put(point, :at, sample.observed_at) | points]}
        else
          {:halt, points}
        end
      end)

    segments = segments(points)
    decline? = Enum.any?(segments, & &1.decline?)
    unknown_decline? = decline? and is_nil(window.resets_at)

    measured =
      if unknown_decline?,
        do: [List.last(segments)],
        else: Enum.reject(segments, & &1.suspect?)

    anchor = latest.observed_at
    short = rate(measured, anchor, 24)
    long = rate(measured, anchor, 48)
    selected_rate = long.value || short.value
    remaining = max(0, 100 - window.used_percent)

    {status, exhaustion_at} =
      estimate(window, now, anchor, remaining, selected_rate, short, long, unknown_decline?)

    %{
      id: window.id,
      name: window.name,
      window_seconds: window.window_seconds,
      used_percent: window.used_percent,
      remaining_percent: remaining,
      resets_at: window.resets_at,
      status:
        if(plan_changed? and status == "insufficient_history", do: "plan_changed", else: status),
      generation:
        if(window.resets_at, do: "reset:#{div(window.resets_at, 1000)}", else: "unknown-reset"),
      rate_percent_per_hour: selected_rate,
      rate_24h_percent_per_hour: short.value,
      rate_48h_percent_per_hour: long.value,
      coverage_24h_hours: short.coverage / @hour,
      coverage_48h_hours: long.coverage / @hour,
      lookback_24h_hours: lookback(short),
      lookback_48h_hours: lookback(long),
      sample_count_24h: short.samples,
      sample_count_48h: long.samples,
      estimate_lookback_hours: if(exhaustion_at, do: if(long.value, do: 48, else: 24)),
      exhaustion_at: exhaustion_at,
      diagnostics:
        window_diagnostics(
          decline?,
          unknown_decline?,
          short.censored? or long.censored?,
          status,
          plan_changed?
        )
    }
  end

  defp segments([first | points]) do
    initial = segment(first)

    points
    |> Enum.reduce([initial], fn point, [current | done] ->
      [previous | _] = current.points
      changed? = not History.same_reset?(previous, point)
      declined? = History.declined?(previous, point)

      if changed? or declined? do
        closed = %{current | decline?: declined?, suspect?: declined? and not changed?}
        [segment(point), closed | done]
      else
        [%{current | points: [point | current.points]} | done]
      end
    end)
    |> Enum.reverse()
  end

  defp segment(point), do: %{points: [point], decline?: false, suspect?: false}

  defp rate(segments, at, hours) do
    initial = %{
      samples: 0,
      coverage: 0,
      delta: 0,
      first: nil,
      last: nil,
      gapped?: false,
      censored?: false
    }

    cutoff = at - hours * @hour

    totals =
      Enum.reduce(segments, initial, fn segment, acc ->
        points = Enum.take_while(segment.points, &(&1.at >= cutoff))
        acc = %{acc | samples: acc.samples + length(points)}

        points
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.reduce(acc, fn [newer, older], rate ->
          measure(rate, older, newer)
        end)
      end)

    Map.merge(totals, %{
      value:
        if(totals.coverage >= @hour and totals.delta > 0,
          do: totals.delta / (totals.coverage / @hour)
        ),
      zero?: totals.coverage >= @hour and totals.delta == 0
    })
  end

  defp measure(rate, older, newer) do
    elapsed = newer.at - older.at

    cond do
      elapsed <= 0 ->
        rate

      elapsed > @max_gap ->
        %{rate | gapped?: true}

      older.used_percent >= 100 and newer.used_percent >= 100 ->
        %{rate | censored?: true}

      true ->
        %{
          rate
          | coverage: rate.coverage + elapsed,
            delta: rate.delta + max(0, newer.used_percent - older.used_percent),
            first: min(rate.first || older.at, older.at),
            last: max(rate.last || newer.at, newer.at)
        }
    end
  end

  defp lookback(%{first: nil}), do: 0
  defp lookback(rate), do: (rate.last - rate.first) / @hour

  defp estimate(window, now, anchor, remaining, rate, short, long, unknown_decline?) do
    cond do
      window.resets_at != nil and window.resets_at <= now -> {"stale", nil}
      window.used_percent >= 100 -> {"exhausted", nil}
      rate != nil -> project(anchor, remaining, rate, window.resets_at)
      unknown_decline? -> {"unknown_reset", nil}
      short.gapped? or long.gapped? -> {"gapped_history", nil}
      short.zero? or long.zero? -> {"zero_burn", nil}
      true -> {"insufficient_history", nil}
    end
  end

  def project(anchor, remaining, rate, reset) do
    # Compare before division so an extremely small positive rate cannot overflow.
    cond do
      reset != nil and remaining >= rate * ((reset - anchor) / @hour) ->
        {"resets_before_exhaustion", nil}

      remaining >= rate * (@max_estimate_ms / @hour) ->
        {"estimate_out_of_range", nil}

      true ->
        {"steady", anchor + trunc(remaining / rate * @hour)}
    end
  end

  defp window_diagnostics(decline?, unknown_decline?, censored?, status, plan_changed?) do
    [
      {decline?,
       %{
         code: "USAGE_RESET_OR_DECLINE",
         message: "A decrease was observed, so rates do not cross that interval."
       }},
      {unknown_decline?,
       %{
         code: "USAGE_UNKNOWN_RESET",
         message:
           "The decrease has no reset marker, so only post-decrease observations support a qualified rate."
       }},
      {censored?,
       %{
         code: "USAGE_CAPPED_DEMAND_CENSORED",
         message: "Flat observations at 100% are capped demand, not evidence of zero burn."
       }},
      {status == "estimate_out_of_range",
       %{
         code: "USAGE_ESTIMATE_OUT_OF_RANGE",
         message: "The measured burn is too small for a representable exhaustion time."
       }},
      {plan_changed?, @plan_change}
    ]
    |> Enum.flat_map(fn
      {true, diagnostic} -> [diagnostic]
      {false, _} -> []
    end)
  end
end
