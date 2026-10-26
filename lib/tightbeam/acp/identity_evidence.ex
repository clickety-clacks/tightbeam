defmodule Tightbeam.Acp.IdentityEvidence do
  @moduledoc false

  alias Tightbeam.ErrorDiagnostic

  @schema "acp-model-identity-v1"
  @hash ~r/\A[0-9a-f]{64}\z/
  @max_options 100
  @max_text 256

  def record(nil, _facts), do: :disabled

  def record(path, facts) when is_binary(path) and is_map(facts) do
    record = sanitize(facts)
    directory = Path.dirname(path)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(path, [JSON.encode!(record), ?\n], [:append]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, _reason} -> :error
    end
  rescue
    _ -> :error
  end

  def sanitize(facts) when is_map(facts) do
    %{
      "schemaVersion" => @schema,
      "observedAtMs" => integer(facts[:observed_at_ms]) || System.system_time(:millisecond),
      "event" => "acp_model_identity_observed",
      "correlation" => correlation(facts[:correlation] || %{}),
      "requested" => model(facts[:requested]),
      "joinedRequested" => model(facts[:joined_requested]),
      "writes" => writes(facts[:writes]),
      "resident" => resident(facts[:resident] || %{}),
      "acceptedReadback" => accepted(facts[:accepted] || %{}),
      "loadedIdentity" => loaded_identity(facts[:loaded_identity], facts[:correlation] || %{}),
      "outcome" => enum(facts[:outcome], ~w(verified mismatch refused unknown), "unknown"),
      "cleanup" => cleanup(facts[:cleanup])
    }
  end

  defp correlation(value) do
    %{
      "requestId" => text(value[:request_id]),
      "listenerGeneration" => scalar(value[:listener_generation]),
      "sessionId" => text(value[:session_id]),
      "acpRequestIds" =>
        value
        |> Map.get(:acp_request_ids, [])
        |> Enum.filter(&is_integer/1)
        |> Enum.take(@max_options),
      "adapterConnectionGeneration" => integer(value[:adapter_connection_generation]),
      "harnessLaunchId" => text(value[:harness_launch_id])
    }
  end

  defp model(%{family: family} = value) do
    %{
      "family" => text(family),
      "context" => text(Map.get(value, :context)),
      "effort" => text(Map.get(value, :effort))
    }
  end

  defp model(_), do: %{"family" => nil, "context" => nil, "effort" => nil}

  defp writes(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      %{config_id: id, value: value} = write when id in ["model", "effort"] ->
        [%{"requestId" => integer(write[:request_id]), "configId" => id, "value" => text(value)}]

      _ ->
        []
    end)
    |> Enum.take(@max_options)
  end

  defp writes(_), do: []

  defp resident(value) do
    %{
      "modelInfos" => nil,
      "modelInfosReason" =>
        text(value[:model_infos_reason]) || "not_exposed_by_acp_public_response",
      "modelOption" => config_option(value[:config_options], "model"),
      "effortOption" => config_option(value[:config_options], value[:effort_config])
    }
  end

  defp accepted(value) do
    %{
      "model" => model(value[:model]),
      "modelCurrentValue" => current_value(value[:config_options], "model"),
      "effortCurrentValue" => current_value(value[:config_options], value[:effort_config])
    }
  end

  defp config_option(options, id) when is_list(options) and is_binary(id) do
    case Enum.find(options, &((&1["id"] || &1["configId"]) == id)) do
      %{} = option ->
        %{
          "id" => id,
          "currentValue" => text(option["currentValue"] || option["value"]),
          "options" => sanitize_options(option["options"])
        }

      _ ->
        nil
    end
  end

  defp config_option(_, _), do: nil

  defp sanitize_options(options) when is_list(options) do
    options
    |> Enum.flat_map(fn
      %{} = option ->
        [
          %{
            "value" => text(option["value"]),
            "name" => text(option["name"] || option["displayName"]),
            "description" => text(option["description"]),
            "resolvedModel" => text(option["resolvedModel"])
          }
        ]

      value when is_binary(value) ->
        [%{"value" => text(value), "name" => nil, "description" => nil, "resolvedModel" => nil}]

      _ ->
        []
    end)
    |> Enum.take(@max_options)
  end

  defp sanitize_options(_), do: []

  defp current_value(options, id) do
    case config_option(options, id) do
      %{"currentValue" => value} -> value
      _ -> nil
    end
  end

  defp loaded_identity(%{source: "process_loader"} = identity, correlation) do
    %{
      "binding" => %{
        "harnessLaunchId" => text(correlation[:harness_launch_id]),
        "adapterConnectionGeneration" => integer(correlation[:adapter_connection_generation])
      },
      "acp" => loaded_hash(identity[:acp]),
      "sdk" => loaded_hash(identity[:sdk]),
      "native" => loaded_hash(identity[:native])
    }
  end

  defp loaded_identity(_identity, correlation) do
    unavailable = %{"sha256" => nil, "reason" => "process_loader_attestation_unavailable"}

    %{
      "binding" => %{
        "harnessLaunchId" => text(correlation[:harness_launch_id]),
        "adapterConnectionGeneration" => integer(correlation[:adapter_connection_generation])
      },
      "acp" => unavailable,
      "sdk" => unavailable,
      "native" => unavailable
    }
  end

  defp loaded_hash(%{sha256: hash}) when is_binary(hash) do
    hash = String.downcase(hash)
    if Regex.match?(@hash, hash), do: %{"sha256" => hash, "reason" => nil}, else: loaded_hash(nil)
  end

  defp loaded_hash(_), do: %{"sha256" => nil, "reason" => "loader_hash_unavailable"}

  defp cleanup(%{status: status} = value) do
    %{
      "status" => enum(status, ~w(verified unverified), "unverified"),
      "reason" => text(value[:reason])
    }
  end

  defp cleanup(_), do: nil

  defp enum(value, allowed, fallback) do
    value = if is_atom(value), do: Atom.to_string(value), else: value
    if value in allowed, do: value, else: fallback
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: nil

  defp scalar(value) when is_integer(value), do: value
  defp scalar(value), do: text(value)

  defp text(value) when is_binary(value) do
    value = String.slice(value, 0, @max_text)

    if String.match?(
         value,
         ~r/(?:token|secret|password|authorization|credential|cookie|private.?key)\s*[:=]/i
       ),
       do: nil,
       else: ErrorDiagnostic.redact_text(value)
  end

  defp text(_), do: nil
end
