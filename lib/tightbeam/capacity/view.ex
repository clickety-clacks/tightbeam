defmodule Tightbeam.Capacity.View do
  @moduledoc false

  alias Tightbeam.Capacity.{Forecast, History, Pools, Summary}

  @reauth_codes ~w(CREDENTIAL_MISSING CREDENTIAL_REJECTED TOKEN_SCOPE_INSUFFICIENT REFRESH_REJECTED)
  @statuses ~w(live cache stale error)

  def usage(account, result, previous, serving?, now) do
    summary =
      Summary.build(account_state(account, result.sample, result.error), result, previous, now)

    %{
      account_id: account["id"],
      status: result.status,
      sample: result.sample && sample(account, result.sample, serving?, now),
      error: result.error,
      summary: summary
    }
  end

  def aggregate_usage(results, now) do
    counts =
      Enum.reduce(
        results,
        Map.new(@statuses, &{&1, 0}),
        &Map.update!(&2, &1.status, fn n -> n + 1 end)
      )

    %{generated_at: now, results: results, counts: counts}
  end

  def history(account, observations, now) do
    retained =
      observations
      |> History.retain(now)
      |> Enum.map(fn observation ->
        Map.merge(observation, %{account_id: account["id"], provider: account["provider"]})
      end)

    %{
      account_id: account["id"],
      provider: account["provider"],
      samples: retained,
      earliest_observed_at: timestamp(List.first(retained)),
      latest_observed_at: timestamp(List.last(retained))
    }
  end

  def forecast(account, entry, now, opts \\ []) do
    account_status = account_state(account, entry.sample, entry.error).status
    samples = History.retain(entry.history, now)
    opts = Keyword.put(opts, :current_sample_age_seconds, age(entry.sample, now))

    Forecast.account(account["id"], account["provider"], account_status, samples, now, opts)
  end

  def aggregate_forecast(accounts_with_entries, now) do
    accounts_with_entries
    |> Enum.map(fn {account, entry} ->
      {forecast(account, entry, now), account["label"], account["identityKey"]}
    end)
    |> Pools.aggregate(now)
  end

  def health(accounts_with_entries, cli_by_provider) do
    providers =
      Map.new(cli_by_provider, fn {provider, available?} ->
        counts = %{
          "total" => 0,
          "ready" => 0,
          "degraded" => 0,
          "reauthRequired" => 0,
          "unknown" => 0
        }

        counts =
          accounts_with_entries
          |> Enum.filter(fn {account, _} -> account["provider"] == provider end)
          |> Enum.reduce(counts, fn {account, entry}, acc ->
            state = account_state(account, entry.sample, entry.error).status
            key = if state == "reauth_required", do: "reauthRequired", else: state
            acc |> Map.update!("total", &(&1 + 1)) |> Map.update!(key, &(&1 + 1))
          end)

        {provider, %{cli_available: available?, accounts: counts}}
      end)

    status =
      if Enum.any?(providers, fn {_, view} -> view.accounts["total"] != view.accounts["ready"] end),
         do: "degraded",
         else: "ready"

    %{status: status, providers: providers}
  end

  defp sample(account, sample, serving?, now) do
    %{
      account_id: account["id"],
      provider: account["provider"],
      label: account["label"],
      plan: sample.plan,
      observed_at: sample.observed_at,
      age_seconds: age(sample, now),
      serving: serving?,
      windows: sample.windows,
      diagnostics: sample.diagnostics
    }
  end

  defp account_state(account, sample, error) do
    state =
      cond do
        account["loginState"] == "needs_sign_in" -> "reauth_required"
        error != nil and error.code in @reauth_codes -> "reauth_required"
        error != nil -> "degraded"
        sample != nil or account["loginState"] == "signed_in" -> "ready"
        true -> "unknown"
      end

    %{provider: account["provider"], label: account["label"], status: state, error: error}
  end

  defp timestamp(nil), do: nil
  defp timestamp(sample), do: sample.observed_at

  defp age(nil, _), do: nil
  defp age(sample, now), do: max(0, div(now - sample.observed_at, 1000))
end
