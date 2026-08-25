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
      {:error, {:no_pi_catalog, %{opencode_go: ocgo_error, local_openai: local_errors}}}
    else
      {:ok, Enum.sort_by(entries, & &1.family)}
    end
  end

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

  @doc false
  def local_provider_live?(target, record, opts) do
    LocalOpenAi.credential_live?(target, record, opts)
  end

  @doc false
  def build_pi_models_json(base_dir) do
    providers =
      base_dir
      |> named_local_providers()
      |> Enum.reduce(%{}, fn record, acc ->
        case fetch_models_body_for_materialization(target_for(base_dir), record) do
          {:ok, body} ->
            case LocalOpenAi.pi_models_json_entry(record, body) do
              {name, provider} when is_binary(name) -> Map.put(acc, name, provider)
              _ -> acc
            end

          _ ->
            acc
        end
      end)

    JSON.encode!(%{"providers" => providers})
  end

  defp fetch_named_local_catalogs(state) do
    base_dir = Map.fetch!(state, :base_dir)

    Providers.list(base_dir)
    |> Enum.reduce({[], %{}}, fn name, {entries, errors} ->
      case Providers.read(base_dir, name) do
        {:ok, record} ->
          case LocalOpenAi.fetch_catalog(state, record) do
            {:ok, provider_entries} -> {entries ++ provider_entries, errors}
            {:error, reason} -> {entries, Map.put(errors, name, reason)}
          end

        {:error, reason} ->
          {entries, Map.put(errors, name, reason)}
      end
    end)
  end

  defp fetch_models_body_for_materialization(target, record) do
    url = LocalOpenAi.models_url(record.endpoint)

    headers =
      if is_binary(record.api_key) and record.api_key != "" do
        ["Authorization: Bearer #{record.api_key}"]
      else
        []
      end

    with {:ok, paths} <- catalog_executables(target) do
      script = Tightbeam.Harness.Support.catalog_curl(url, headers, "", paths.curl)

      case Tightbeam.Harness.Support.catalog_probe(
             &Tightbeam.Harness.Support.system_cmd_out/1,
             Tightbeam.Harness.Support.catalog_probe_argv(nil, script, paths)
           ) do
        {:ok, body, _trailer} -> {:ok, body}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp catalog_executables(_target) do
    with sh when is_binary(sh) <- absolute_path("sh"),
         curl when is_binary(curl) <- absolute_path("curl") do
      {:ok, %{sh: sh, curl: curl}}
    else
      _ -> {:error, :executable_not_found}
    end
  end

  defp absolute_path(name) do
    case System.find_executable(name) do
      path when is_binary(path) ->
        if Path.type(path) == :absolute, do: path, else: nil

      _ ->
        nil
    end
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
            auth = Path.join([state.base_dir, "auth", "pi", "auth.json"])

            if File.regular?(auth),
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
