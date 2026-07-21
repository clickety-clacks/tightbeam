defmodule Tightbeam.ModelCatalog do
  @moduledoc """
  Derives and asynchronously caches the full model inventory advertised by each harness.

  Codex is sourced from its maintained `models_cache.json`; Claude is sourced from
  the Anthropic Models API using the org OAuth token. Failed refreshes retain the
  last inventory successfully derived for that harness.
  """

  use GenServer

  require Logger

  @default_ttl_ms :timer.minutes(15)
  @claude_models_url "https://api.anthropic.com/v1/models?limit=100"
  @effort_order ~w(low medium high xhigh max ultra)

  @type model :: %{
          ref: String.t(),
          name: String.t(),
          display_name: String.t(),
          efforts: [String.t()],
          max_input_tokens: non_neg_integer() | nil,
          capabilities: map()
        }
  @type catalog :: %{required(String.t()) => [model()]}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec get(GenServer.server()) :: catalog()
  def get(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> empty()
      _pid -> GenServer.call(server, :get)
    end
  catch
    :exit, _reason -> empty()
  end

  @spec valid_ref?(catalog(), String.t(), String.t()) :: boolean()
  def valid_ref?(catalog, harness, ref) do
    Enum.any?(Map.get(catalog, harness, []), &(&1.ref == ref))
  end

  @spec derive_codex(map()) :: [model()]
  def derive_codex(%{"models" => models}) when is_list(models) do
    Enum.flat_map(models, fn model ->
      slug = Map.fetch!(model, "slug")
      display_name = Map.fetch!(model, "display_name")
      reasoning_levels = Map.get(model, "supported_reasoning_levels", [])
      efforts = Enum.map(reasoning_levels, &Map.fetch!(&1, "effort"))

      capabilities =
        model
        |> Map.get("capabilities", %{})
        |> Map.put("supported_reasoning_levels", reasoning_levels)

      inventory_entries(
        slug,
        display_name,
        efforts,
        Map.get(model, "max_input_tokens") || Map.get(model, "context_window"),
        capabilities
      )
    end)
  end

  @spec derive_claude(map()) :: [model()]
  def derive_claude(%{"data" => models}) when is_list(models) do
    Enum.flat_map(models, fn model ->
      id = Map.fetch!(model, "id")
      display_name = Map.fetch!(model, "display_name")
      capabilities = Map.get(model, "capabilities", %{})

      efforts =
        capabilities
        |> Map.get("effort", %{})
        |> Enum.filter(fn {_effort, support} -> Map.get(support, "supported") == true end)
        |> Enum.map(&elem(&1, 0))
        |> sort_efforts()

      inventory_entries(
        id,
        display_name,
        efforts,
        Map.get(model, "max_input_tokens"),
        capabilities
      )
    end)
  end

  @impl true
  def init(opts) do
    request_fun = Keyword.get(opts, :request_fun, &request_claude/2)

    state = %{
      catalog: empty(),
      codex_home: Keyword.get(opts, :codex_home, Path.join(opts[:base_dir], "auth/codex")),
      claude_token_path:
        Keyword.get(
          opts,
          :claude_token_path,
          Path.join([opts[:base_dir], "auth", "claude", "oauth-token"])
        ),
      claude_fetch:
        Keyword.get(opts, :claude_fetch, fn token -> fetch_claude(token, request_fun) end),
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      refreshing: false,
      refresh_monitor: nil
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.catalog, state}

  @impl true
  def handle_info(:refresh, %{refreshing: false} = state) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        send(parent, {:refresh_result, derive_sources(state)})
      end)

    monitor = Process.monitor(pid)

    {:noreply, %{schedule_refresh(state) | refreshing: true, refresh_monitor: monitor}}
  end

  def handle_info(:refresh, state), do: {:noreply, schedule_refresh(state)}

  def handle_info({:refresh_result, results}, state) do
    Process.demonitor(state.refresh_monitor, [:flush])

    catalog =
      Enum.reduce(results, state.catalog, fn
        {harness, {:ok, models}}, catalog ->
          Map.put(catalog, harness, models)

        {harness, {:error, reason}}, catalog ->
          Logger.warning("model catalog refresh failed for #{harness}: #{inspect(reason)}")
          catalog
      end)

    {:noreply, %{state | catalog: catalog, refreshing: false, refresh_monitor: nil}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{refresh_monitor: monitor} = state)
      when reason != :normal do
    {:noreply, %{schedule_refresh(state) | refreshing: false, refresh_monitor: nil}}
  end

  defp empty, do: %{"claude" => [], "codex" => []}

  defp derive_sources(state) do
    [
      {"codex", load_codex(state.codex_home)},
      {"claude", load_claude(state)}
    ]
  rescue
    error -> [{"codex", {:error, error}}, {"claude", {:error, error}}]
  end

  defp load_codex(codex_home) do
    with {:ok, body} <- File.read(Path.join(codex_home, "models_cache.json")),
         {:ok, decoded} <- JSON.decode(body) do
      {:ok, derive_codex(decoded)}
    end
  rescue
    error -> {:error, error}
  end

  defp load_claude(state) do
    with {:ok, token} <- File.read(state.claude_token_path),
         token when token != "" <- String.trim(token),
         {:ok, body} <- state.claude_fetch.(token),
         {:ok, decoded} <- decode_body(body) do
      {:ok, derive_claude(decoded)}
    else
      "" -> {:error, :empty_oauth_token}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(body) when is_binary(body), do: JSON.decode(body)

  @doc false
  def fetch_claude(token) do
    fetch_claude(token, &request_claude/2)
  end

  @doc false
  def fetch_claude(token, request_fun) do
    with {:ok, body} <- request_fun.(@claude_models_url, token),
         {:ok, %{"data" => models} = response} when is_list(models) <- JSON.decode(body),
         {:ok, models} <- enrich_claude_models(models, token, request_fun) do
      {:ok, %{response | "data" => models}}
    else
      {:ok, _unexpected} -> {:error, :unexpected_models_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enrich_claude_models(models, token, request_fun) do
    Enum.reduce_while(models, {:ok, []}, fn model, {:ok, acc} ->
      if get_in(model, ["capabilities", "effort"]) do
        {:cont, {:ok, [model | acc]}}
      else
        id = Map.fetch!(model, "id")
        detail_url = "https://api.anthropic.com/v1/models/#{URI.encode(id)}"

        with {:ok, body} <- request_fun.(detail_url, token),
             {:ok, detail} when is_map(detail) <- JSON.decode(body) do
          {:cont, {:ok, [Map.merge(model, detail) | acc]}}
        else
          {:error, reason} -> {:halt, {:error, {:model_detail, id, reason}}}
        end
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  rescue
    error -> {:error, error}
  end

  defp request_claude(url, token) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer #{token}")},
      {~c"anthropic-version", ~c"2023-06-01"}
    ]

    ssl_options = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(
           :get,
           {String.to_charlist(url), headers},
           [connect_timeout: 5_000, timeout: 10_000, ssl: ssl_options],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inventory_entries(id, display_name, efforts, max_input_tokens, capabilities) do
    metadata = %{
      display_name: display_name,
      efforts: efforts,
      max_input_tokens: max_input_tokens,
      capabilities: capabilities
    }

    case efforts do
      [] ->
        [Map.merge(metadata, %{ref: id, name: display_name})]

      efforts ->
        Enum.map(efforts, fn effort ->
          Map.merge(metadata, %{ref: "#{id}[#{effort}]", name: "#{display_name} (#{effort})"})
        end)
    end
  end

  defp sort_efforts(efforts) do
    Enum.sort_by(efforts, fn effort ->
      {Enum.find_index(@effort_order, &(&1 == effort)) || length(@effort_order), effort}
    end)
  end

  defp schedule_refresh(state) do
    Process.send_after(self(), :refresh, state.ttl_ms)
    state
  end
end
