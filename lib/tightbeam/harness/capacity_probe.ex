defmodule Tightbeam.Harness.CapacityProbe do
  @moduledoc false

  alias Tightbeam.Harness.Support

  @error_codes ~w(
    CREDENTIAL_MISSING CREDENTIAL_REJECTED CREDENTIAL_UNREADABLE
    CREDENTIAL_EXPIRED CREDENTIAL_EXPIRY_UNKNOWN TOKEN_SCOPE_INSUFFICIENT REFRESH_REJECTED
    UPSTREAM_CONTRACT_CHANGED UPSTREAM_RATE_LIMITED UPSTREAM_TIMEOUT UPSTREAM_UNAVAILABLE
  )

  def provider_atom("openai"), do: :openai
  def provider_atom("anthropic"), do: :anthropic

  def local_cli_availability do
    Map.new([Tightbeam.Harness.Codex, Tightbeam.Harness.Claude], fn harness ->
      {to_string(harness.credential_provider()),
       System.find_executable(harness.cli_binary()) != nil}
    end)
  end

  @doc false
  def idle_argv(executable, vendor_binary, provider, home) do
    [executable, "capacity-probe", "--idle-native", to_string(provider), home, vendor_binary]
  end

  def read(target, executable, provider, credential_path) do
    command = [executable, "capacity-probe", to_string(provider), credential_path]
    script = "exec " <> Enum.map_join(command, " ", &Support.shell_quote/1) <> " 2>/dev/null"

    case target.sh.(Support.catalog_probe_argv(target.host_config.ssh, script)) do
      {output, 0} ->
        decode(output)

      {_, 255} ->
        {:error, %{code: "HOST_UNREACHABLE"}}

      {_, 127} ->
        {:error, %{code: "CLI_MISSING"}}

      {_, _exit} ->
        {:error, %{code: "UPSTREAM_UNAVAILABLE"}}
    end
  end

  def decode(output) do
    case JSON.decode(output) do
      {:ok, %{"sample" => sample}} when is_map(sample) ->
        sample(sample)

      {:ok, %{"error" => %{"code" => code, "retryAfterSeconds" => delay}}}
      when code == "UPSTREAM_RATE_LIMITED" and is_integer(delay) and delay > 0 ->
        {:error, %{code: code, retry_after_seconds: delay}}

      {:ok, %{"error" => %{"code" => code}}} when code in @error_codes ->
        {:error, %{code: code}}

      _ ->
        invalid_contract()
    end
  end

  defp sample(%{"observedAt" => observed, "windows" => [_ | _] = windows} = sample)
       when is_integer(observed) do
    with {:ok, windows} <- decode_windows(windows),
         {:ok, diagnostics} <- diagnostics(sample["diagnostics"]) do
      plan = string(sample["plan"])

      hold = profile_hold(sample["profileHold"])

      {:ok,
       %{
         observed_at: observed,
         plan: plan && String.trim(plan),
         windows: windows,
         diagnostics: diagnostics,
         subscription: subscription(sample["subscription"])
       }
       |> then(fn decoded ->
         if hold, do: Map.put(decoded, :profile_hold, hold), else: decoded
       end)}
    else
      :error -> invalid_contract()
    end
  end

  defp sample(_), do: invalid_contract()

  defp profile_hold(%{"code" => "UPSTREAM_RATE_LIMITED", "retryAfterSeconds" => delay})
       when is_integer(delay) and delay > 0,
       do: %{code: "UPSTREAM_RATE_LIMITED", retry_after_seconds: delay}

  defp profile_hold(_), do: nil

  defp decode_windows(windows) do
    if Enum.all?(windows, &valid_window?/1) do
      {:ok,
       Enum.map(windows, fn window ->
         %{
           id: window["id"],
           name: window["name"],
           used_percent: window["usedPercent"],
           resets_at: integer(window["resetsAt"]),
           reset_after_seconds: integer(window["resetAfterSeconds"]),
           window_seconds: positive(window["windowSeconds"]),
           scope: window["scope"],
           model: string(window["model"])
         }
       end)}
    else
      :error
    end
  end

  defp valid_window?(%{"id" => id, "name" => name, "usedPercent" => percent, "scope" => scope}) do
    is_binary(id) and id != "" and is_binary(name) and is_number(percent) and percent >= 0 and
      percent <= 100 and scope in ["account", "model"]
  end

  defp valid_window?(_), do: false

  defp diagnostics(diagnostics) when is_list(diagnostics) do
    Enum.reduce_while(diagnostics, {:ok, []}, fn diagnostic, {:ok, acc} ->
      case diagnostic do
        %{"code" => code, "message" => message} when is_binary(code) and is_binary(message) ->
          {:cont, {:ok, [%{code: code, message: message} | acc]}}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      :error -> :error
    end
  end

  defp diagnostics(_), do: :error

  defp subscription(subscription) when is_map(subscription) do
    %{
      status: string(subscription["status"]),
      status_reason: string(subscription["statusReason"]),
      observed_at: integer(subscription["observedAt"]),
      plan_unknown_reason: string(subscription["planUnknownReason"]),
      period_end_at: integer(subscription["periodEndAt"]),
      period_end_kind: string(subscription["periodEndKind"]),
      period_end_unknown_reason: string(subscription["periodEndUnknownReason"])
    }
  end

  defp subscription(_), do: %{}
  defp invalid_contract, do: {:error, %{code: "UPSTREAM_CONTRACT_CHANGED"}}

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil
  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: nil
  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_), do: nil
end
