defmodule Tightbeam.ModelManifest do
  @moduledoc """
  The validated, refreshable source of hosted-model metadata.

  Remote I/O always runs outside the reader path. A successful refresh replaces
  the on-disk last-good copy atomically; a failed refresh leaves the prior
  in-memory and on-disk document intact.
  """

  use GenServer
  require Logger

  @default_url "https://tightbeam.ing/model-manifest.json"
  @default_ttl_ms :timer.hours(1)
  @default_retry_ms :timer.minutes(5)
  @default_timeout_ms :timer.seconds(10)

  @type health :: :fresh | :stale | {:unavailable, term()}
  @type snapshot :: %{
          document: map(),
          source: :remote | :disk | :bundled,
          health: health()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec get(GenServer.server()) :: snapshot()
  def get(server \\ __MODULE__) do
    case safe_call(server, :get) do
      {:ok, snapshot} -> snapshot
      :unavailable -> bundled_snapshot()
    end
  end

  @spec provider(String.t(), GenServer.server()) :: {:ok, map(), health()} | {:error, term()}
  def provider(name, server \\ __MODULE__) when is_binary(name) do
    snapshot = get(server)

    case get_in(snapshot.document, ["providers", name]) do
      provider when is_map(provider) -> {:ok, provider, snapshot.health}
      _ -> {:error, {:manifest_provider_absent, name}}
    end
  end

  @doc "Return a provider's bundled/last-good default as a structured model identity."
  @spec default_model(String.t(), GenServer.server()) :: Tightbeam.Model.t()
  def default_model(provider_name, server \\ __MODULE__) do
    {:ok, provider, _health} = provider(provider_name, server)
    slug = get_in(provider, ["defaults", "chat"])
    model = Enum.find(provider["models"], &(&1["slug"] == slug))
    profile = Map.get(provider["profiles"], model["profile"], %{})

    Tightbeam.Model.new(slug,
      effort: Map.get(profile, "defaultEffort"),
      context: nil
    )
  end

  @doc "Return a provider's alias-to-canonical rendering map from the current manifest."
  @spec aliases(String.t(), GenServer.server()) :: %{String.t() => String.t()}
  def aliases(provider_name, server \\ __MODULE__) do
    {:ok, provider, _health} = provider(provider_name, server)
    profiles = Map.get(provider, "profiles", %{})

    Enum.reduce(provider["models"], %{}, fn model, aliases ->
      profile = Map.get(profiles, model["profile"], %{})
      suffixes = get_in(profile, ["adapter", "claudeCode", "contextSuffix"]) || %{}

      Enum.reduce(Map.get(model, "aliases", []), aliases, fn alias_name, acc ->
        acc = Map.put(acc, alias_name, model["slug"])

        Enum.reduce(suffixes, acc, fn {context, suffix}, nested ->
          Map.put(nested, alias_name <> suffix, model["slug"] <> suffix_for(profile, context))
        end)
      end)
    end)
  end

  @doc "Return canonical family prefixes represented by a provider manifest."
  @spec prefixes(String.t(), GenServer.server()) :: [String.t()]
  def prefixes(provider_name, server \\ __MODULE__) do
    {:ok, provider, _health} = provider(provider_name, server)

    provider["models"]
    |> Enum.map(&(&1["slug"] |> String.split("-", parts: 2) |> hd() |> Kernel.<>("-")))
    |> Enum.uniq()
  end

  @doc "Render a structured identity with one provider's adapter rules."
  @spec render(String.t(), Tightbeam.Model.t(), GenServer.server()) :: String.t()
  def render(
        provider_name,
        %Tightbeam.Model{family: family, context: context},
        server \\ __MODULE__
      ) do
    {:ok, provider, _health} = provider(provider_name, server)
    models = provider["models"]

    case Enum.find(models, fn model ->
           family == model["slug"] or family in Map.get(model, "aliases", [])
         end) do
      nil ->
        Tightbeam.Model.to_ref(Tightbeam.Model.new(family, context: context))

      model ->
        profile = Map.get(provider["profiles"], model["profile"], %{})
        model["slug"] <> suffix_for(profile, context)
    end
  end

  defp suffix_for(_profile, nil), do: ""

  defp suffix_for(profile, context) do
    get_in(profile, ["adapter", "claudeCode", "contextSuffix", context]) || ""
  end

  @spec validate(binary() | map()) :: {:ok, map()} | {:error, term()}
  def validate(bytes) when is_binary(bytes) do
    case JSON.decode(bytes) do
      {:ok, document} -> validate(document)
      {:error, _} -> invalid("$", :malformed_json)
    end
  end

  def validate(%{"version" => 1, "providers" => providers} = document)
      when is_map(providers) do
    with :ok <- validate_providers(providers), do: {:ok, document}
  end

  def validate(%{"version" => version}), do: invalid("version", version)
  def validate(_document), do: invalid("$", :wrong_shape)

  @impl true
  def init(opts) do
    base_dir = Keyword.fetch!(opts, :base_dir)
    bundled_path = Keyword.get(opts, :bundled_path, bundled_path())
    cache_path = Keyword.get(opts, :cache_path, Path.join(base_dir, "model-manifest.json"))
    {document, source} = load_last_good(cache_path, bundled_path)

    state = %{
      document: document,
      source: source,
      health: if(source == :disk, do: :stale, else: {:unavailable, :not_refreshed}),
      cache_path: cache_path,
      url: Keyword.get(opts, :url, @default_url),
      fetch: Keyword.get(opts, :fetch, &http_fetch/2),
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      refreshing: false,
      timer: nil
    }

    send(self(), :refresh_due)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, snapshot(state), state}

  @impl true
  def handle_info(:refresh_due, %{refreshing: true} = state), do: {:noreply, state}

  def handle_info(:refresh_due, state) do
    owner = self()
    fetch = state.fetch
    url = state.url
    timeout = state.timeout_ms

    {:ok, _pid} =
      Task.start(fn -> send(owner, {:manifest_refresh, safely_fetch(fetch, url, timeout)}) end)

    {:noreply, %{state | refreshing: true, timer: nil}}
  end

  def handle_info({:manifest_refresh, {:ok, bytes}}, state) do
    case validate(bytes) do
      {:ok, document} ->
        case atomic_write(state.cache_path, JSON.encode!(document)) do
          :ok ->
            state =
              state
              |> Map.merge(%{
                document: document,
                source: :remote,
                health: :fresh,
                refreshing: false
              })
              |> schedule(state.ttl_ms)

            {:noreply, state}

          {:error, reason} ->
            {:noreply, refresh_failed(state, {:cache_write_failed, reason})}
        end

      {:error, reason} ->
        {:noreply, refresh_failed(state, reason)}
    end
  end

  def handle_info({:manifest_refresh, {:error, reason}}, state),
    do: {:noreply, refresh_failed(state, reason)}

  defp safely_fetch(fetch, url, timeout) do
    try do
      fetch.(url, timeout)
    rescue
      error -> {:error, {:exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp refresh_failed(state, reason) do
    Logger.warning("hosted model manifest refresh degraded: #{inspect(reason)}")
    health = if state.source in [:disk, :remote], do: :stale, else: {:unavailable, reason}

    state
    |> Map.merge(%{health: health, refreshing: false})
    |> schedule(state.retry_ms)
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :refresh_due, delay)}
  end

  defp snapshot(state), do: Map.take(state, [:document, :source, :health])

  defp load_last_good(cache_path, bundled_path) do
    case read_valid(cache_path) do
      {:ok, document} -> {document, :disk}
      {:error, _reason} -> {read_valid!(bundled_path), :bundled}
    end
  end

  defp read_valid(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, document} <- validate(bytes),
         do: {:ok, document}
  end

  defp read_valid!(path) do
    case read_valid(path) do
      {:ok, document} -> document
      {:error, reason} -> raise "invalid bundled model manifest #{path}: #{inspect(reason)}"
    end
  end

  defp atomic_write(path, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      temp = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

      case File.write(temp, bytes, [:binary, :exclusive]) do
        :ok -> rename_or_remove(temp, path)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp rename_or_remove(temp, path) do
    case File.rename(temp, path) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(temp)
        {:error, reason}
    end
  end

  defp validate_providers(providers) do
    Enum.reduce_while(providers, :ok, fn
      {name, provider}, :ok when is_binary(name) ->
        continue_if_ok(validate_provider(name, provider))

      {_name, _provider}, :ok ->
        {:halt, invalid("providers", :non_string_name)}
    end)
  end

  defp validate_provider(name, %{"models" => models} = provider) when is_list(models) do
    profiles = Map.get(provider, "profiles", %{})

    with :ok <- validate_profiles(profiles, name),
         :ok <- validate_model_rows(models, name),
         :ok <- unique_values(models, "slug", "providers.#{name}.models[].slug"),
         :ok <- validate_aliases(models, name),
         :ok <- validate_models(models, profiles, name),
         :ok <- validate_defaults(provider, models, name) do
      :ok
    end
  end

  defp validate_provider(name, _provider),
    do: invalid_reason("providers.#{name}", :wrong_shape)

  defp validate_profiles(profiles, name) when is_map(profiles) do
    Enum.reduce_while(profiles, :ok, fn
      {_key, profile}, :ok when is_map(profile) ->
        {:cont, :ok}

      {key, _profile}, :ok ->
        {:halt, invalid_reason("providers.#{name}.profiles.#{key}", :wrong_shape)}
    end)
  end

  defp validate_profiles(_profiles, name),
    do: invalid_reason("providers.#{name}.profiles", :wrong_shape)

  defp validate_model_rows(models, name) do
    if Enum.all?(models, &is_map/1),
      do: :ok,
      else: invalid_reason("providers.#{name}.models[]", :wrong_shape)
  end

  defp unique_values(rows, key, path) do
    values = Enum.map(rows, &Map.get(&1, key))

    if Enum.all?(values, &(is_binary(&1) and &1 != "")) and
         length(values) == length(Enum.uniq(values)),
       do: :ok,
       else: invalid_reason(path, :duplicate_or_non_string)
  end

  defp validate_aliases(models, name) do
    aliases = Enum.map(models, &Map.get(&1, "aliases", []))

    cond do
      not Enum.all?(aliases, &is_list/1) ->
        invalid_reason("providers.#{name}.models[].aliases", :wrong_shape)

      true ->
        aliases = List.flatten(aliases)
        slugs = Enum.map(models, & &1["slug"])

        if Enum.all?(aliases, &(is_binary(&1) and &1 != "")) and
             length(aliases) == length(Enum.uniq(aliases)) and
             Enum.all?(aliases, &(&1 not in slugs)),
           do: :ok,
           else: invalid_reason("providers.#{name}.models[].aliases", :duplicate_or_conflicting)
    end
  end

  defp validate_models(models, profiles, name) do
    Enum.reduce_while(models, :ok, fn model, :ok ->
      path = "providers.#{name}.models[#{inspect(model["slug"])}]"

      with :ok <- valid_profile(model, profiles, path),
           :ok <- valid_status(model, path),
           :ok <- valid_model_adapter(model, path) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_profile(%{"profile" => profile}, profiles, path) when is_binary(profile) do
    if Map.has_key?(profiles, profile),
      do: :ok,
      else: invalid_reason(path <> ".profile", :missing_profile)
  end

  defp valid_profile(_model, _profiles, _path), do: :ok

  defp valid_status(%{"status" => status}, _path) when status in ["current", "legacy"], do: :ok
  defp valid_status(_model, path), do: invalid_reason(path <> ".status", :invalid)

  defp valid_model_adapter(model, path) do
    case Map.fetch(model, "adapter") do
      :error ->
        :ok

      {:ok, adapter} when is_map(adapter) ->
        valid_version_gate(Map.get(adapter, "claudeCode"), path)

      {:ok, _adapter} ->
        invalid_reason(path <> ".adapter", :wrong_shape)
    end
  end

  defp valid_version_gate(nil, _path), do: :ok

  defp valid_version_gate(gate, path) when is_map(gate) do
    min = Map.get(gate, "minVersion")
    max = Map.get(gate, "maxVersionExclusive")

    with :ok <- parse_optional_version(min, path <> ".adapter.claudeCode.minVersion"),
         :ok <- parse_optional_version(max, path <> ".adapter.claudeCode.maxVersionExclusive"),
         :ok <- ordered_versions(min, max, path) do
      :ok
    end
  end

  defp valid_version_gate(_gate, path),
    do: invalid_reason(path <> ".adapter.claudeCode", :wrong_shape)

  defp parse_optional_version(nil, _path), do: :ok

  defp parse_optional_version(value, path) when is_binary(value) do
    case Version.parse(value) do
      {:ok, _version} -> :ok
      :error -> invalid_reason(path, value)
    end
  end

  defp parse_optional_version(value, path), do: invalid_reason(path, value)

  defp ordered_versions(nil, _max, _path), do: :ok
  defp ordered_versions(_min, nil, _path), do: :ok

  defp ordered_versions(min, max, path) do
    if Version.compare(min, max) == :lt,
      do: :ok,
      else: invalid_reason(path <> ".adapter.claudeCode", :empty_version_range)
  end

  defp validate_defaults(provider, models, name) do
    slugs = MapSet.new(models, & &1["slug"])

    case get_in(provider, ["defaults", "chat"]) do
      nil ->
        :ok

      slug when is_binary(slug) ->
        if MapSet.member?(slugs, slug),
          do: :ok,
          else: invalid_reason("providers.#{name}.defaults.chat", :unknown_slug)

      value ->
        invalid_reason("providers.#{name}.defaults.chat", value)
    end
  end

  defp continue_if_ok(:ok), do: {:cont, :ok}
  defp continue_if_ok({:error, _reason} = error), do: {:halt, error}

  defp invalid(path, reason), do: {:error, {:invalid_field, path, reason}}
  defp invalid_reason(path, reason), do: {:error, {:invalid_field, path, reason}}

  defp bundled_path, do: Application.app_dir(:tightbeam, "priv/model-manifest.json")

  defp bundled_snapshot do
    %{
      document: read_valid!(bundled_path()),
      source: :bundled,
      health: {:unavailable, :loader_not_started}
    }
  end

  defp safe_call(server, request) do
    try do
      {:ok, GenServer.call(server, request)}
    catch
      :exit, _reason -> :unavailable
    end
  end

  defp http_fetch(url, timeout) do
    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [ssl: ssl, timeout: timeout, connect_timeout: timeout],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end
end
