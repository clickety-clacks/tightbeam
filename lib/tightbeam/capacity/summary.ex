defmodule Tightbeam.Capacity.Summary do
  @moduledoc false

  def build(account, result, previous, now) do
    %{label: label, provider: provider, status: status} = account
    %{sample: sample, error: error} = result

    source = if sample, do: Map.get(sample, :subscription) || %{}, else: %{}
    plan = if sample, do: sample.plan, else: previous && previous.plan
    observed_at = sample && sample.observed_at
    age = sample && max(0, div(now - observed_at, 1000))
    reason = unknown_reason(sample != nil, error)
    period_end = source[:period_end_at]
    {subscription_status, subscription_reason} = subscription_status(plan, source, reason, now)

    %{
      label: label,
      provider: provider,
      account_state: status,
      account_state_reason:
        if(status != "ready", do: error_code(Map.get(account, :error)) || "not_yet_checked"),
      usage_freshness: freshness(result),
      usage_freshness_reason: freshness_reason(result),
      usage_observed_at: observed_at,
      usage_age_seconds: age,
      plan: plan,
      plan_unknown_reason:
        if(is_nil(plan),
          do:
            source[:plan_unknown_reason] ||
              unknown_reason(sample != nil or previous != nil, error)
        ),
      subscription_status: subscription_status,
      subscription_status_reason: subscription_reason,
      subscription_period_end_at: period_end,
      subscription_period_end_kind: if(period_end, do: source[:period_end_kind] || "unstated"),
      subscription_period_end_unknown_reason:
        if(is_nil(period_end) and subscription_status != "free",
          do: source[:period_end_unknown_reason] || reason
        ),
      subscription_observed_at:
        source[:observed_at] || if(plan, do: observed_at || previous.observed_at)
    }
  end

  defp freshness(%{sample: nil}), do: "none"
  defp freshness(%{status: "stale"}), do: "stale"
  defp freshness(%{error: nil}), do: "current"
  defp freshness(_), do: "stale"

  defp freshness_reason(result) do
    case freshness(result) do
      "none" -> error_code(result.error) || "not_yet_observed"
      "stale" -> error_code(result.error) || "read_due"
      "current" -> nil
    end
  end

  defp error_code(nil), do: nil
  defp error_code(%{code: code}), do: code

  defp unknown_reason(true, _), do: "not_exposed_by_provider"
  defp unknown_reason(false, nil), do: "not_yet_observed"
  defp unknown_reason(false, _), do: "read_failed"

  defp subscription_status(_, %{status: "lapsed"}, _, _), do: {"lapsed", nil}

  defp subscription_status(_, %{period_end_at: period_end} = source, _, now)
       when is_integer(period_end) do
    case source[:observed_at] do
      nil -> {"unknown", "unrecognized_value"}
      statement_at when period_end == statement_at -> {"unknown", "unrecognized_value"}
      statement_at when period_end < statement_at -> {"lapsed", nil}
      _ when period_end < now -> {"unknown", "period_end_passed"}
      _ -> {"active", nil}
    end
  end

  defp subscription_status(_, %{status: status}, _, _) when status in ["active", "free"],
    do: {status, nil}

  defp subscription_status("free", _, _, _), do: {"free", nil}

  defp subscription_status(_, source, reason, _),
    do: {"unknown", source[:status_reason] || reason}
end
