defmodule Tightbeam.ModelCatalog do
  @moduledoc """
  Asynchronously derived model inventory, keyed by `{host, harness}`.

  Credentials are host-local by design, so entitlements are host-local, so a
  catalog is a fact about ONE host's account — and about the KIND of credential
  that host holds, since the two kinds read different routes with different
  entitlements. A satellite on an API key and a gateway on a subscription derive
  genuinely different catalogs, and neither is a stale copy of the other. It used to be derived once, on the
  gateway, from the gateway's credential, and then applied to every host — which
  validated a spawn against the gateway account while the turn ran under the
  target host's (#88). Facts about a host are established on that host.

  The keys are `Placement.hosts/1` x `Harness.all/0`, re-enumerated on every
  refresh pass, so a host assimilated after boot gets its entries without a
  restart. Freshness, TTL, and degraded reasons are per entry: an unreachable
  host degrades only its own.

  The server owns only cached data and freshness metadata. Provider I/O always
  runs in separate tasks, so readers return cached (or empty) state immediately.
  """

  use GenServer
  require Logger
  alias Tightbeam.{Harness, Model, Placement}

  @default_ttl_ms :timer.minutes(15)

  @type health :: :fresh | :stale | {:unavailable, term()}
  @type key :: {host :: String.t(), harness :: String.t()}
  @typedoc """
  One vendor model on one host, as fields. `family` and `context` are the
  vendor's (`claude-fable-5`, `1m`); `efforts` is what Tightbeam may ask of it.
  Capabilities live here rather than folded into an identity.
  """
  @type entry :: %{
          family: String.t(),
          context: String.t() | nil,
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

  @doc "Return every cached `{host, harness}` inventory without performing provider I/O."
  @spec get(GenServer.server()) :: %{key() => [entry()]}
  def get(server \\ __MODULE__) do
    case safe_call(server, :get) do
      {:ok, inventories} -> inventories
      :unavailable -> %{}
    end
  end

  @doc "Return one host's cached harness inventory and its freshness health."
  @spec get(String.t(), String.t(), GenServer.server()) :: {[entry()], health()}
  def get(host, harness, server) when is_binary(host) and is_binary(harness) do
    _ = Harness.parse!(harness)

    case safe_call(server, {:get, {host, harness}}) do
      {:ok, answer} -> answer
      :unavailable -> {[], {:unavailable, :catalog_not_started}}
    end
  end

  @doc "Return the cached `%{harness => entries}` inventories for one host."
  @spec host_inventories(String.t(), GenServer.server()) :: %{String.t() => [entry()]}
  def host_inventories(host, server \\ __MODULE__) when is_binary(host) do
    server
    |> get()
    |> Enum.reduce(Map.new(harness_names(), &{&1, []}), fn
      {{^host, harness}, entries}, acc -> Map.put(acc, harness, entries)
      _other, acc -> acc
    end)
  end

  @doc """
  Check membership on a host with the health of the inventory used.

  A selection is offered when the host lists that family and context AND the
  effort matches what the entry offers: an entry with effort tiers requires
  one, an entry with none refuses one.
  """
  @spec member?(String.t(), String.t(), Model.t(), GenServer.server()) ::
          %{present?: boolean(), health: health()}
  def member?(host, harness, %Model{} = model, server \\ __MODULE__)
      when is_binary(host) and is_binary(harness) do
    {entry, health} = entry(host, harness, model, server)
    %{present?: not is_nil(entry) and effort_offered?(entry, model.effort), health: health}
  end

  @doc """
  Return the catalog entry for a selection's family and context on a host, and
  the inventory health used. The effort is not consulted — the entry is what
  says which efforts exist.
  """
  @spec entry(String.t(), String.t(), Model.t(), GenServer.server()) ::
          {entry() | nil, health()}
  def entry(host, harness, %Model{} = model, server \\ __MODULE__)
      when is_binary(host) and is_binary(harness) do
    {entries, health} = get(host, harness, server)
    {Enum.find(entries, &names_same_model?(&1, model)), health}
  end

  @doc "Whether a catalog entry names the same vendor model as a selection."
  @spec names_same_model?(entry(), Model.t()) :: boolean()
  def names_same_model?(entry, %Model{} = model),
    do: entry.family == model.family and entry.context == model.context

  defp effort_offered?(%{efforts: []}, effort), do: is_nil(effort)
  defp effort_offered?(%{efforts: efforts}, effort), do: effort in efforts

  @impl true
  def init(opts) do
    state = %{
      base_dir: Keyword.fetch!(opts, :base_dir),
      db: Keyword.get(opts, :db, Tightbeam.DB),
      hosts: Keyword.get(opts, :hosts),
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
      options: Map.new(opts),
      credential_status: Keyword.get(opts, :credential_status, &default_credential_status/2),
      credential_kind: Keyword.get(opts, :credential_kind, &default_credential_kind/2),
      entries: %{}
    }

    send(self(), :refresh_due)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    state = refresh_due(state)
    {:reply, Map.new(state.entries, fn {key, cache} -> {key, cache.entries} end), state}
  end

  def handle_call({:get, key}, _from, state) do
    state = refresh_due(state)

    answer =
      case state.entries[key] do
        nil -> {[], {:unavailable, {:host_not_configured, elem(key, 0)}}}
        cache -> {cache.entries, health(cache, now_ms(state), state.ttl_ms)}
      end

    {:reply, answer, state}
  end

  @impl true
  def handle_info(:refresh_due, state), do: {:noreply, refresh_due(state)}

  def handle_info({:catalog_refresh, key, {:ok, entries}}, state) do
    now = now_ms(state)

    cache = %{
      entries: entries,
      derived_at: now,
      attempted_at: now,
      reason: nil,
      refreshing: false
    }

    {:noreply, put_in(state, [:entries, key], cache)}
  end

  def handle_info({:catalog_refresh, {host, harness} = key, {:error, reason}}, state) do
    Logger.warning("model catalog #{harness} on #{host} refresh degraded: #{inspect(reason)}")

    case state.entries[key] do
      nil ->
        {:noreply, state}

      cache ->
        cache = cache |> Map.put(:reason, reason) |> Map.put(:refreshing, false)
        {:noreply, put_in(state, [:entries, key], cache)}
    end
  end

  # Hosts are re-read every pass rather than captured at init: `assimilate`
  # writes the registry while the gateway runs, and a satellite registered at
  # 10am must not need a restart to acquire a catalog. A bare mix task has no
  # DB owner to read the registry from (and must not create one), so it hands
  # in its own hosts source via the `:hosts` option instead.
  defp refresh_due(state) do
    hosts = enumerate_hosts(state)

    state =
      Enum.reduce(hosts, state, fn {host, host_config}, acc ->
        Enum.reduce(harness_names(), acc, fn harness, acc ->
          refresh_key(acc, {host, harness}, host_config)
        end)
      end)

    drop_unconfigured(state, hosts)
  end

  defp enumerate_hosts(%{hosts: fun}) when is_function(fun, 0), do: fun.()
  defp enumerate_hosts(state), do: Placement.hosts(state.base_dir, state.db)

  defp refresh_key(state, key, host_config) do
    now = now_ms(state)
    cache = Map.get(state.entries, key) || new_cache()
    state = put_in(state, [:entries, key], cache)

    if not cache.refreshing and expired?(cache, now, state.ttl_ms) do
      owner = self()
      probe = probe_state(state, key, host_config)
      snapshot = state

      {:ok, _pid} =
        Task.start(fn ->
          send(owner, {:catalog_refresh, key, safely_derive(key, probe, snapshot)})
        end)

      state
      |> put_in([:entries, key, :refreshing], true)
      |> put_in([:entries, key, :attempted_at], now)
    else
      state
    end
  end

  defp drop_unconfigured(state, hosts) do
    entries =
      Map.filter(state.entries, fn {{host, _harness}, _cache} -> Map.has_key?(hosts, host) end)

    %{state | entries: entries}
  end

  defp new_cache do
    %{entries: [], derived_at: nil, attempted_at: nil, reason: :not_derived, refreshing: false}
  end

  # What the probe sees is the OWNING host: its base_dir (where its credential
  # and its harness home live) and its ssh destination, which is what decides
  # local read versus remote probe inside the harness module.
  defp probe_state(state, {host, _harness}, host_config) do
    %{
      base_dir: host_config.base_dir,
      host_name: host,
      host_config: host_config,
      options: state.options
    }
  end

  defp safely_derive({host, harness}, probe, state) do
    try do
      module = Harness.parse!(harness)
      provider = module.credential_provider()

      with :onboarded <- credential_status(state, provider, host),
           kind when kind in [:api_key, :subscription] <-
             credential_kind(state, provider, host) do
        module.fetch_catalog(Map.put(probe, :credential_kind, kind))
      else
        {:needs_onboarding, reason} ->
          {:error, {:needs_onboarding, reason}}

        # Onboarded, but the store records no kind. Refused rather than
        # defaulted: the two kinds read different routes, so a catalog derived
        # against a guessed kind would be a confident answer about the wrong
        # account. Production cannot reach this — `:onboarded` and a readable
        # kind have the same preconditions — but a half-migrated or
        # hand-assembled store can, and it deserves a refusal, not a guess.
        :none ->
          {:error, {:needs_onboarding, :missing}}
      end
    rescue
      error -> {:error, {:exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp credential_status(%{credential_status: status}, provider, _host)
       when is_function(status, 1),
       do: status.(provider)

  defp credential_status(%{credential_status: status}, provider, host)
       when is_function(status, 2),
       do: status.(provider, host)

  defp default_credential_status(provider, host) do
    server = Tightbeam.Credentials.server(host)

    case GenServer.whereis(server) do
      nil -> {:needs_onboarding, :credential_server_unavailable}
      _pid -> Tightbeam.Credentials.status(provider, server)
    end
  end

  defp credential_kind(%{credential_kind: kind}, _provider, _host)
       when is_atom(kind),
       do: kind

  defp credential_kind(%{credential_kind: kind}, provider, _host)
       when is_function(kind, 1),
       do: kind.(provider)

  defp credential_kind(%{credential_kind: kind}, provider, host)
       when is_function(kind, 2),
       do: kind.(provider, host)

  # `:subscription` when the lifecycle owner is unreachable, NOT `:none` — and
  # this is NOT #21's fail-open returning by another door. The credential GATE is
  # `credential_status/3`, checked one line above this in `safely_derive/3`, and
  # it already refuses `{:needs_onboarding, :credential_server_unavailable}` for
  # exactly this case; nothing derives a catalog past it. This value only decides
  # WHICH ROUTE an already-authorized derivation reads, and the pre-invariant
  # answer — the only kind that existed — is the right one when nobody can say
  # otherwise.
  defp default_credential_kind(provider, host) do
    server = Tightbeam.Credentials.server(host)

    case GenServer.whereis(server) do
      nil -> :subscription
      _pid -> Tightbeam.Credentials.kind(provider, server)
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

  defp safe_call(server, request) do
    try do
      {:ok, GenServer.call(server, request)}
    catch
      :exit, _ -> :unavailable
    end
  end

  defp harness_names, do: Enum.map(Harness.all(), & &1.wire_name())
end
