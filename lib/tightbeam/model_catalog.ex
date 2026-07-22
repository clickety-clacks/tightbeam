defmodule Tightbeam.ModelCatalog do
  @moduledoc """
  Asynchronously derived, per-harness model inventory.

  The server owns only cached data and freshness metadata. Provider I/O always
  runs in separate tasks, so readers return cached (or empty) state immediately.
  """

  use GenServer
  require Logger

  @default_ttl_ms :timer.minutes(15)
  @harnesses ["claude", "codex"]

  @type health :: :fresh | :stale | {:unavailable, term()}
  @type entry :: %{
          ref: String.t(),
          display_name: String.t(),
          efforts: [String.t()],
          max_input_tokens: non_neg_integer() | nil,
          capabilities: map()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Return the cached inventory for both harnesses without performing provider I/O."
  @spec get(GenServer.server()) :: %{String.t() => [entry()]}
  def get(server \\ __MODULE__) do
    case safe_call(server, :get) do
      {:ok, inventories} -> inventories
      :unavailable -> Map.new(@harnesses, &{&1, []})
    end
  end

  @doc "Return one cached harness inventory and its freshness health."
  @spec get(String.t(), GenServer.server()) :: {[entry()], health()}
  def get(harness, server) when harness in @harnesses do
    case safe_call(server, {:get, harness}) do
      {:ok, answer} -> answer
      :unavailable -> {[], {:unavailable, :catalog_not_started}}
    end
  end

  @doc "Check membership with the health of the harness inventory used."
  @spec member?(String.t(), String.t(), GenServer.server()) ::
          %{present?: boolean(), health: health()}
  def member?(harness, ref, server \\ __MODULE__)
      when harness in @harnesses and is_binary(ref) do
    {entries, health} = get(harness, server)
    %{present?: Enum.any?(entries, &(&1.ref == ref)), health: health}
  end

  @impl true
  def init(opts) do
    now = now_ms(opts)

    state = %{
      base_dir: Keyword.fetch!(opts, :base_dir),
      codex_home: Keyword.get(opts, :codex_home, default_codex_home()),
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
      claude_fetch: Keyword.get(opts, :claude_fetch, &http_get/2),
      codex_read: Keyword.get(opts, :codex_read, &File.read/1),
      harnesses:
        Map.new(@harnesses, fn harness ->
          {harness,
           %{
             entries: [],
             derived_at: nil,
             attempted_at: nil,
             reason: :not_derived,
             refreshing: false,
             now: now
           }}
        end)
    }

    send(self(), :refresh_due)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    state = refresh_due(state)
    inventories = Map.new(@harnesses, &{&1, state.harnesses[&1].entries})
    {:reply, inventories, state}
  end

  def handle_call({:get, harness}, _from, state) do
    state = refresh_due(state)
    cache = state.harnesses[harness]
    {:reply, {cache.entries, health(cache, now_ms(state), state.ttl_ms)}, state}
  end

  @impl true
  def handle_info(:refresh_due, state), do: {:noreply, refresh_due(state)}

  def handle_info({:catalog_refresh, harness, {:ok, entries}}, state) do
    now = now_ms(state)

    cache = %{
      entries: entries,
      derived_at: now,
      attempted_at: now,
      reason: nil,
      refreshing: false
    }

    {:noreply, put_in(state, [:harnesses, harness], cache)}
  end

  def handle_info({:catalog_refresh, harness, {:error, reason}}, state) do
    Logger.warning("model catalog #{harness} refresh degraded: #{inspect(reason)}")
    cache = state.harnesses[harness] |> Map.put(:reason, reason) |> Map.put(:refreshing, false)
    {:noreply, put_in(state, [:harnesses, harness], cache)}
  end

  defp refresh_due(state) do
    Enum.reduce(@harnesses, state, fn harness, acc ->
      cache = acc.harnesses[harness]

      if not cache.refreshing and expired?(cache, now_ms(acc), acc.ttl_ms) do
        owner = self()
        snapshot = acc

        {:ok, _pid} =
          Task.start(fn ->
            result = safely_derive(harness, snapshot)
            send(owner, {:catalog_refresh, harness, result})
          end)

        acc
        |> put_in([:harnesses, harness, :refreshing], true)
        |> put_in([:harnesses, harness, :attempted_at], now_ms(acc))
      else
        acc
      end
    end)
  end

  defp safely_derive(harness, state) do
    try do
      derive(harness, state)
    rescue
      error -> {:error, {:exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp derive("claude", state) do
    token_path = Path.join([state.base_dir, "auth", "claude", "oauth-token"])

    with {:ok, token} <- read_token(token_path),
         token <- String.trim(token),
         true <- token != "",
         headers = [
           {~c"authorization", String.to_charlist("Bearer " <> token)},
           {~c"anthropic-version", ~c"2023-06-01"}
         ],
         {:ok, body} <- state.claude_fetch.("/v1/models?limit=100", headers),
         {:ok, models} <- decode_models(body),
         {:ok, models} <- fill_claude_capabilities(models, headers, state.claude_fetch),
         entries when entries != [] <- derive_claude_entries(models) do
      {:ok, entries}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :missing_token}
      [] -> {:error, :empty_inventory}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  defp derive("codex", state) do
    path = Path.join(state.codex_home, "models_cache.json")

    with {:ok, body} <- state.codex_read.(path),
         {:ok, models} <- decode_models(body),
         entries when entries != [] <- derive_codex_entries(models) do
      {:ok, entries}
    else
      {:error, :enoent} -> {:error, :missing_cache}
      {:error, reason} -> {:error, reason}
      [] -> {:error, :empty_inventory}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  defp read_token(path) do
    case File.read(path) do
      {:ok, token} -> {:ok, token}
      {:error, :enoent} -> {:error, :missing_token}
      {:error, reason} -> {:error, {:token_read_failed, reason}}
    end
  end

  defp decode_models(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"data" => models}} when is_list(models) -> {:ok, models}
      {:ok, %{"models" => models}} when is_list(models) -> {:ok, models}
      {:ok, _} -> {:error, :malformed_catalog}
      {:error, _} -> {:error, :malformed_json}
    end
  end

  defp decode_models(_), do: {:error, :malformed_catalog}

  defp fill_claude_capabilities(models, headers, fetch) do
    Enum.reduce_while(models, {:ok, []}, fn model, {:ok, acc} ->
      if is_map(get_in(model, ["capabilities", "effort"])) do
        {:cont, {:ok, [model | acc]}}
      else
        case model["id"] do
          id when is_binary(id) ->
            path = "/v1/models/" <> URI.encode(id, &URI.char_unreserved?/1)

            with {:ok, body} <- fetch.(path, headers),
                 {:ok, detail} <- JSON.decode(body),
                 true <- is_map(detail) do
              {:cont, {:ok, [Map.merge(model, detail) | acc]}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
              _ -> {:halt, {:error, :malformed_catalog}}
            end

          _ ->
            {:halt, {:error, :malformed_catalog}}
        end
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp derive_claude_entries(models) do
    Enum.flat_map(models, fn
      %{"id" => id} = model when is_binary(id) ->
        capabilities = model["capabilities"] || %{}

        efforts =
          capabilities
          |> Map.get("effort", %{})
          |> Enum.filter(fn {_effort, detail} ->
            is_map(detail) and detail["supported"] == true
          end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()

        entries_for(model, id, efforts, capabilities)

      _ ->
        []
    end)
  end

  defp derive_codex_entries(models) do
    Enum.flat_map(models, fn
      %{"slug" => slug} = model when is_binary(slug) ->
        levels = model["supported_reasoning_levels"] || []

        efforts =
          for %{"effort" => effort} <- levels, is_binary(effort), do: effort

        capabilities =
          Map.put(model["capabilities"] || %{}, "supported_reasoning_levels", levels)

        entries_for(model, slug, efforts, capabilities)

      _ ->
        []
    end)
  end

  defp entries_for(model, id, efforts, capabilities) do
    display_name = model["display_name"] || id

    targets =
      if efforts == [],
        do: [{id, display_name}],
        else: Enum.map(efforts, &{"#{id}[#{&1}]", "#{display_name} [#{&1}]"})

    Enum.map(targets, fn {ref, title} ->
      %{
        ref: ref,
        display_name: title,
        name: title,
        efforts: efforts,
        max_input_tokens: model["max_input_tokens"] || model["context_window"],
        capabilities: capabilities
      }
    end)
  end

  defp health(%{entries: []} = cache, _now, _ttl),
    do: {:unavailable, cache.reason || :empty_inventory}

  defp health(cache, now, ttl) do
    if now - cache.derived_at < ttl, do: :fresh, else: :stale
  end

  defp expired?(%{derived_at: nil, attempted_at: nil}, _now, _ttl), do: true

  defp expired?(%{derived_at: nil, attempted_at: attempted_at}, now, ttl),
    do: now - attempted_at >= ttl

  defp expired?(cache, now, ttl), do: now - cache.derived_at >= ttl

  defp now_ms(%{now: now}), do: now.()
  defp now_ms(opts) when is_list(opts), do: Keyword.get(opts, :now, fn -> 0 end).()

  defp default_codex_home do
    System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")
  end

  defp safe_call(server, request) do
    try do
      {:ok, GenServer.call(server, request)}
    catch
      :exit, _ -> :unavailable
    end
  end

  defp http_get(path, headers) do
    url = String.to_charlist("https://api.anthropic.com" <> path)

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, {url, headers}, [ssl: ssl, timeout: 10_000], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _response_headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_version, status, _reason}, _response_headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end
end
