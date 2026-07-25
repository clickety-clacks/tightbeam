defmodule Tightbeam.ModelCatalog do
  @moduledoc """
  Asynchronously derived, per-harness model inventory.

  The server owns only cached data and freshness metadata. Provider I/O always
  runs in separate tasks, so readers return cached (or empty) state immediately.
  """

  use GenServer
  require Logger
  alias Tightbeam.Harness

  @default_ttl_ms :timer.minutes(15)

  @type health :: :fresh | :stale | {:unavailable, term()}
  @type entry :: %{
          ref: String.t(),
          display_name: String.t(),
          efforts: [String.t()],
          max_input_tokens: non_neg_integer() | nil,
          capabilities: map(),
          provider: atom()
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
      :unavailable -> Map.new(harness_names(), &{&1, []})
    end
  end

  @doc "Return one cached harness inventory and its freshness health."
  @spec get(String.t(), GenServer.server()) :: {[entry()], health()}
  def get(harness, server) when is_binary(harness) do
    _ = Harness.parse!(harness)

    case safe_call(server, {:get, harness}) do
      {:ok, answer} -> answer
      :unavailable -> {[], {:unavailable, :catalog_not_started}}
    end
  end

  @doc "Check membership with the health of the harness inventory used."
  @spec member?(String.t(), String.t(), GenServer.server()) ::
          %{present?: boolean(), health: health()}
  def member?(harness, ref, server \\ __MODULE__)
      when is_binary(harness) and is_binary(ref) do
    _ = Harness.parse!(harness)
    {entries, health} = get(harness, server)
    %{present?: Enum.any?(entries, &(&1.ref == ref)), health: health}
  end

  @doc "Return the selected catalog entry and the inventory health used."
  def entry(harness, ref, server \\ __MODULE__) when is_binary(harness) and is_binary(ref) do
    {entries, health} = get(harness, server)
    {Enum.find(entries, &(&1.ref == ref)), health}
  end

  @impl true
  def init(opts) do
    now = now_ms(opts)

    state = %{
      base_dir: Keyword.fetch!(opts, :base_dir),
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
      options: Map.new(opts),
      credential_status: Keyword.get(opts, :credential_status, &default_credential_status/1),
      harnesses:
        Map.new(harness_names(), fn harness ->
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
    inventories = Map.new(harness_names(), &{&1, state.harnesses[&1].entries})
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
    Enum.reduce(harness_names(), state, fn harness, acc ->
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
      module = Harness.parse!(harness)

      with :onboarded <- state.credential_status.(module.credential_provider()) do
        module.fetch_catalog(state)
      else
        {:needs_onboarding, reason} -> {:error, {:needs_onboarding, reason}}
      end
    rescue
      error -> {:error, {:exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp default_credential_status(provider) do
    case Process.whereis(Tightbeam.Credentials) do
      nil -> :onboarded
      _pid -> Tightbeam.Credentials.status(provider)
    end
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

  defp safe_call(server, request) do
    try do
      {:ok, GenServer.call(server, request)}
    catch
      :exit, _ -> :unavailable
    end
  end

  defp harness_names, do: Enum.map(Harness.all(), & &1.wire_name())
end
