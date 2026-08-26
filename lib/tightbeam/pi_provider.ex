defmodule Tightbeam.PiProvider do
  @moduledoc false

  alias Tightbeam.LocalOpenAi.Providers
  alias Tightbeam.PiProvider.LocalOpenAi
  alias Tightbeam.PiProvider.OpenCodeGo

  @type credential_liveness :: :live | {:dead, term()} | {:unknown, term()}

  @callback id() :: atom()
  @callback wire_name() :: String.t()
  @callback model_prefix() :: String.t()
  @callback fetch_catalog(state :: map()) :: {:ok, [map()]} | {:error, term()}
  @callback credential_live?(target :: map(), home :: String.t(), opts :: keyword()) ::
              credential_liveness()

  @providers [
    OpenCodeGo
  ]

  @doc false
  def all, do: @providers

  @doc false
  def for_wire(wire_name) when is_binary(wire_name) do
    Enum.find(@providers, fn mod -> mod.wire_name() == wire_name end)
  end

  @doc false
  def for_id(id) when is_atom(id) do
    Enum.find(@providers, fn mod -> mod.id() == id end)
  end

  @doc false
  def fetch_pi_catalog(state) do
    {ocgo, ocgo_error} =
      case opencode_go_onboarded?(state) do
        true ->
          case OpenCodeGo.fetch_catalog(state) do
            {:ok, entries} -> {entries, nil}
            {:error, reason} -> {[], reason}
          end

        false ->
          {[], :not_onboarded}
      end

    {local_entries, local_errors} = fetch_named_local_catalogs(state)

    entries = ocgo ++ local_entries

    if entries == [] do
      errors =
        %{}
        |> maybe_put_catalog_error(:opencode_go, ocgo_error)
        |> Map.merge(local_errors)

      case map_size(errors) do
        0 -> {:error, {:no_pi_catalog, %{}}}
        1 -> {:error, errors |> Map.values() |> hd()}
        _ -> {:error, {:no_pi_catalog, errors}}
      end
    else
      {:ok, Enum.sort_by(entries, & &1.family)}
    end
  end

  defp maybe_put_catalog_error(errors, _key, nil), do: errors
  defp maybe_put_catalog_error(errors, _key, :not_onboarded), do: errors
  defp maybe_put_catalog_error(errors, key, reason), do: Map.put(errors, key, reason)

  @doc false
  def pi_catalog_ready?(state) do
    opencode_go_onboarded?(state) or local_openai_onboarded?(state)
  end

  @doc false
  def named_local_providers(base_dir) when is_binary(base_dir) do
    case Providers.read_all(base_dir) do
      {:ok, records} -> records
      {:error, _} -> []
    end
  end

  def named_local_providers(%{host_config: _} = target) do
    case Providers.read_all_target(target) do
      {:ok, records} -> records
      {:error, _} -> []
    end
  end

  @doc false
  def local_provider_live?(target, record, opts) do
    LocalOpenAi.credential_live?(target, record, opts)
  end

  @doc false
  def build_pi_models_json(%{host_config: _} = target) do
    {providers, key_files} =
      target
      |> named_local_providers()
      |> Enum.reduce({%{}, %{}}, fn record, {providers, key_files} ->
        case fetch_models_body_for_materialization(target, record) do
          {:ok, body} ->
            case LocalOpenAi.pi_models_json_entry(record, body) do
              {name, provider} when is_binary(name) ->
                key_files =
                  case Map.get(record, :api_key_file) do
                    path when is_binary(path) -> Map.put(key_files, name, path)
                    _ -> key_files
                  end

                {Map.put(providers, name, provider), key_files}

              _ ->
                {providers, key_files}
            end

          _ ->
            {providers, key_files}
        end
      end)

    %{bytes: JSON.encode!(%{"providers" => providers}), remote_api_key_files: key_files}
  end

  def build_pi_models_json(base_dir) when is_binary(base_dir) do
    build_pi_models_json(target_for(base_dir)).bytes
  end

  defp fetch_named_local_catalogs(state) do
    case Providers.read_all_target(state) do
      {:ok, records} ->
        Enum.reduce(records, {[], %{}}, fn record, {entries, errors} ->
          case LocalOpenAi.fetch_catalog(state, record) do
            {:ok, provider_entries} -> {entries ++ provider_entries, errors}
            {:error, reason} -> {entries, Map.put(errors, record.name, reason)}
          end
        end)

      {:error, reason} ->
        {[], %{local_openai_store: reason}}
    end
  end

  defp fetch_models_body_for_materialization(target, record) do
    LocalOpenAi.fetch_models_body(target, record)
  end

  defp target_for(base_dir) do
    %{
      base_dir: base_dir,
      host_config: %{ssh: nil},
      options: %{sh: &Tightbeam.Harness.Support.system_cmd_out/1}
    }
  end

  defp opencode_go_onboarded?(state) do
    credential_status(state, :opencode_go) == :onboarded
  end

  defp local_openai_onboarded?(state) do
    credential_status(state, :local_openai) == :onboarded
  end

  defp credential_status(state, provider) do
    host = Map.get(state, :host_name) || Map.get(state, :host_config, %{})[:host]

    cond do
      is_function(Map.get(state, :credential_status), 2) ->
        state.credential_status.(provider, host)

      is_function(Map.get(state.options, :credential_status), 2) ->
        state.options.credential_status.(provider, host)

      is_function(Map.get(state.options, :credential_status), 1) ->
        state.options.credential_status.(provider)

      true ->
        case provider do
          :local_openai ->
            if local_openai_onboarded_at?(state.base_dir),
              do: :onboarded,
              else: {:needs_onboarding, :missing}

          :opencode_go ->
            if OpenCodeGo.onboarded_at?(state.base_dir),
              do: :onboarded,
              else: {:needs_onboarding, :missing}

          _ ->
            {:needs_onboarding, :missing}
        end
    end
  end

  defp local_openai_onboarded_at?(base_dir) do
    Providers.list(base_dir) != [] and
      Enum.any?(Providers.list(base_dir), fn name ->
        match?({:ok, _}, Providers.read(base_dir, name))
      end)
  end
end
