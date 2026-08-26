defmodule Tightbeam.HarnessHealth do
  @moduledoc """
  Reader-facing health for one host and harness.

  Model inventory and credential health are separate facts. An empty, freshly
  derived inventory is healthy capability data. A failed derivation is degraded,
  and a credential refusal names onboarding only when the refusal says that
  onboarding can repair it.
  """

  alias Tightbeam.{Harness, ModelCatalog}

  @spec report(String.t(), String.t(), GenServer.server(), keyword()) :: map()
  def report(host, harness, catalog \\ ModelCatalog, options \\ []) do
    provider = Harness.parse!(harness).credential_provider()
    {entries, health} = ModelCatalog.get(host, harness, catalog)
    credential_override = Keyword.get(options, :credential_status)

    {credential_health, catalog_health, failure_reason, remediation} =
      classify(host, harness, provider, entries, health, credential_override)

    %{
      host: host,
      harness: harness,
      provider: Atom.to_string(provider),
      credentialHealth: credential_health,
      catalogHealth: catalog_health,
      modelCount: length(entries),
      failureReason: failure_reason,
      remediation: remediation
    }
  end

  defp classify(_host, _harness, _provider, entries, :fresh, _override) do
    catalog_health = if entries == [], do: "healthyEmpty", else: "healthy"
    {"healthy", catalog_health, nil, nil}
  end

  defp classify(host, harness, _provider, _entries, health, :onboarded) do
    {"healthy", catalog_health(health), reason_code(health),
     catalog_remedy(host, harness, health)}
  end

  defp classify(
         host,
         _harness,
         provider,
         _entries,
         {:unavailable, {:needs_onboarding, reason}},
         _
       ) do
    {"needsOnboarding", "unavailable", reason_code(reason),
     credential_remedy(reason, provider, host)}
  end

  defp classify(host, harness, _provider, _entries, health, _override) do
    {"unknown", catalog_health(health), reason_code(health),
     catalog_remedy(host, harness, health)}
  end

  defp catalog_health(:stale), do: "stale"
  defp catalog_health({:unavailable, :not_derived}), do: "pending"
  defp catalog_health({:unavailable, _reason}), do: "unavailable"

  defp credential_remedy(reason, provider, host) do
    onboard = "Run on #{host}: tightbeam onboard #{provider} --as-user <userId>."

    case reason do
      reason when reason in [:missing, :expired, :revoked] -> onboard
      :credential_server_unavailable -> "Retry shortly. Do not re-onboard from this result."
      :unsupported -> "Use an account with a supported plan. Onboarding will not help."
      {:unsupported, _detail} -> "Use an account with a supported plan. Onboarding will not help."
      _other -> "Run tightbeam doctor on #{host} before changing its credential."
    end
  end

  defp catalog_remedy(
         host,
         harness,
         {:unavailable, {:empty_catalog_for_client_version, _version}}
       ),
       do: "Upgrade #{harness} on #{host}, then refresh the catalog."

  defp catalog_remedy(host, _harness, {:unavailable, :not_derived}),
    do: "Wait for the catalog refresh on #{host}, then read tightbeam list again."

  defp catalog_remedy(host, _harness, _health),
    do: "Retry the catalog refresh on #{host}; run tightbeam doctor there if it stays degraded."

  defp reason_code(:fresh), do: nil
  defp reason_code(:stale), do: "stale"
  defp reason_code({:unavailable, reason}), do: reason_code(reason)
  defp reason_code({:needs_onboarding, reason}), do: reason_code(reason)

  defp reason_code({:empty_catalog_for_client_version, _version}),
    do: "empty_catalog_for_client_version"

  defp reason_code({:http_status, status, _body}), do: "http_status_#{status}"
  defp reason_code({:network, _detail}), do: "network"
  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(_reason), do: "catalog_error"
end
