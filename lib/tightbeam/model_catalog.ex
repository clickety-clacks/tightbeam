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
  alias Tightbeam.{Harness, Model, PiProvider, Placement, Unroutable}

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

  @typedoc "A routed selection: which harness runs it, on whose grant, and the entry that says so."
  @type routed :: %{
          harness: String.t(),
          provider: String.t(),
          entry: entry(),
          health: :fresh | :stale
        }

  @doc """
  THE ONE ANSWER to "can this selection be routed on this host, and if not why".

  Routability is a question about the WHOLE fleet on a host — one harness tiering
  a model says nothing while another offers it untiered — so this gathers every
  usable cached entry naming the model BEFORE anything is refused. A second gate
  deciding the same thing from a narrower view is what refused a valid untiered
  ruling on the strength of the first tiered entry it happened to find.

  This is a READ of the already-cached catalog. It starts nothing, waits on
  nothing, and does no provider I/O, so it can sit on the prompt path.
  """
  @spec route(String.t(), Model.t()) :: {:ok, routed()} | {:error, Unroutable.t()}
  def route(host, %Model{} = selection) when is_binary(host),
    do: route(host, selection, __MODULE__)

  @doc """
  The same answer for ONE harness: what that harness's catalog on that host says
  about this selection. `route/2` is a fold over this — one derivation, two
  quantifiers.

  A populated inventory can route while stale: those cached entitlements remain
  usable during a refresh outage, and the routed answer carries `health: :stale`
  so its caller can surface the degradation. Only an empty or unavailable
  inventory refuses as `:no_catalog`.
  """
  @spec route(String.t(), String.t(), Model.t()) :: {:ok, routed()} | {:error, Unroutable.t()}
  @spec route(String.t(), Model.t(), GenServer.server()) ::
          {:ok, routed()} | {:error, Unroutable.t()}
  # Two shapes at one arity, told apart by what the second argument IS: a harness
  # is a name, a selection is a struct. No default arguments, because a defaulted
  # server on the fold would collide with the per-harness form and leave one of
  # the two spellings raising instead of routing.
  def route(host, %Model{} = selection, server) when is_binary(host) do
    answers = Enum.map(harness_names(), &{&1, route(host, &1, selection, server)})
    routable = for {_harness, {:ok, routed}} <- answers, do: routed

    case routable do
      [routed] -> {:ok, routed}
      [] -> {:error, fold_refusals(host, selection, answers)}
      _many -> {:error, ambiguous(host, selection, answers)}
    end
  end

  def route(host, harness, %Model{} = selection) when is_binary(host) and is_binary(harness),
    do: route(host, harness, selection, __MODULE__)

  @doc "One harness's answer, against a named catalog server."
  @spec route(String.t(), String.t(), Model.t(), GenServer.server()) ::
          {:ok, routed()} | {:error, Unroutable.t()}
  def route(host, harness, %Model{} = selection, server)
      when is_binary(host) and is_binary(harness) do
    {entries, health} = get(host, harness, server)
    entry = Enum.find(entries, &names_same_model?(&1, selection))

    refuse = fn cause, offered ->
      {:error,
       %Unroutable{
         cause: cause,
         host: host,
         harness: harness,
         selection: selection,
         health: [{harness, health}],
         offered: offered
       }}
    end

    cond do
      entries == [] or match?({:unavailable, _reason}, health) ->
        refuse.(:no_catalog, [])

      is_nil(entry) ->
        refuse.(:family_absent, offers(harness, entries))

      offers_effort?(entry, selection.effort) ->
        {:ok,
         %{
           harness: harness,
           provider: Atom.to_string(entry.provider),
           entry: entry,
           health: health
         }}

      is_nil(selection.effort) ->
        refuse.(:needs_effort, offers(harness, [entry]))

      true ->
        refuse.(:effort_not_offered, offers(harness, [entry]))
    end
  end

  # Which refusal the fleet gives when nothing routed. A cause that names the
  # model as PRESENT wins: one harness having it and only tiering it wrong is
  # the true story, and "not in any inventory" would be a lie about a model the
  # reader can see in the catalog.
  defp fold_refusals(host, selection, answers) do
    refusals = for {_harness, {:error, unroutable}} <- answers, do: unroutable
    health = Enum.flat_map(refusals, & &1.health)
    named = Enum.filter(refusals, &(&1.cause in [:needs_effort, :effort_not_offered]))

    {cause, offered} =
      cond do
        # Named refusals cannot disagree about WHICH effort cause they are:
        # `route/3` decides that from the selection, which is the same on every
        # harness. So folding them is a union of what they offer, not a vote.
        named != [] ->
          {if(is_nil(selection.effort), do: :needs_effort, else: :effort_not_offered),
           Enum.flat_map(named, & &1.offered)}

        Enum.all?(refusals, &(&1.cause == :no_catalog)) ->
          {:no_catalog, []}

        true ->
          {:family_absent, Enum.flat_map(refusals, & &1.offered)}
      end

    %Unroutable{
      cause: cause,
      host: host,
      harness: nil,
      selection: selection,
      health: health,
      offered: offered
    }
  end

  defp ambiguous(host, selection, answers) do
    %Unroutable{
      cause: :ambiguous,
      host: host,
      harness: nil,
      selection: selection,
      health: consulted_health(answers),
      offered:
        for(
          {_harness, {:ok, routed}} <- answers,
          do: %{harness: routed.harness, entry: routed.entry}
        )
    }
  end

  # A routed answer carries the health it used; a refused one carries that same
  # health on the refusal.
  defp consulted_health(answers) do
    Enum.flat_map(answers, fn
      {harness, {:ok, routed}} -> [{harness, routed.health}]
      {_harness, {:error, unroutable}} -> unroutable.health
    end)
  end

  defp offers(harness, entries), do: Enum.map(entries, &%{harness: harness, entry: &1})

  @doc """
  A catalog entry as prose, for a refusal that has to say what IS available.
  Harness-agnostic, and for claude it reflects the selectable filter rather than
  the raw API list.
  """
  @spec describe_entry(entry()) :: String.t()
  def describe_entry(entry) do
    qualifiers =
      [
        entry.context && "context #{entry.context}",
        entry.efforts != [] && "efforts: #{Enum.join(entry.efforts, "|")}"
      ]
      |> Enum.filter(&is_binary/1)

    case qualifiers do
      [] -> entry.family
      parts -> "#{entry.family} (#{Enum.join(parts, ", ")})"
    end
  end

  @doc "Whether a catalog entry names the same vendor model as a selection."
  @spec names_same_model?(entry(), Model.t()) :: boolean()
  def names_same_model?(entry, %Model{} = model),
    do: entry.family == model.family and entry.context == model.context

  @doc """
  Whether an entry offers a reasoning level. The ENTRY is the authority on what
  may be asked of a model: one with tiers requires a level, one with none
  refuses one. Every caller that completes a selection asks here, so no second
  copy of the rule can drift.
  """
  @spec offers_effort?(entry(), String.t() | nil) :: boolean()
  def offers_effort?(%{efforts: []}, effort), do: is_nil(effort)
  def offers_effort?(%{efforts: efforts}, effort), do: effort in efforts

  @doc """
  The wired edge from a credential commit (O4/I5): re-recognize NOW that a
  credential became present for `{host, provider}`, re-deriving the catalog for
  every harness that spends `provider` on `host` without waiting for the TTL.
  World-state stays the authority the re-derivation re-reads; this fact is only
  the injector that says "re-recognize now."
  """
  @spec credential_present(String.t(), atom(), GenServer.server()) :: :ok
  def credential_present(host, provider, server \\ __MODULE__)
      when is_binary(host) and is_atom(provider) do
    GenServer.cast(server, {:credential_present, host, provider})
  end

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

  # The RHS of the credential-present recognition (O4/I5): re-derive the catalog
  # for every harness that spends `provider` on `host`, NOW, reading current
  # world-state. Provider-scoped by the same rule the runtime uses — a harness
  # spends exactly one provider's credential — so a claude re-derivation is never
  # gated on codex, and vice-versa.
  @impl true
  def handle_cast({:credential_present, host, provider}, state) do
    keys =
      for harness <- harness_names(),
          Harness.parse!(harness).credential_provider() == provider,
          do: {host, harness}

    {:noreply, Enum.reduce(keys, state, &force_rederive(&2, &1))}
  end

  @impl true
  def handle_info(:refresh_due, state), do: {:noreply, refresh_due(state)}

  def handle_info({:catalog_refresh, key, {:ok, entries}}, state) do
    now = now_ms(state)
    recheck? = match?(%{recheck: true}, state.entries[key])

    cache = %{
      entries: entries,
      derived_at: now,
      attempted_at: now,
      reason: nil,
      refreshing: false,
      recheck: false
    }

    state = put_in(state, [:entries, key], cache)
    {:noreply, maybe_recheck(state, key, recheck?)}
  end

  def handle_info({:catalog_refresh, {host, harness} = key, {:error, reason}}, state) do
    Logger.warning("model catalog #{harness} on #{host} refresh degraded: #{inspect(reason)}")

    case state.entries[key] do
      nil ->
        {:noreply, state}

      cache ->
        recheck? = Map.get(cache, :recheck, false)

        cache =
          cache
          |> Map.put(:reason, reason)
          |> Map.put(:refreshing, false)
          |> Map.put(:recheck, false)

        state = put_in(state, [:entries, key], cache)
        {:noreply, maybe_recheck(state, key, recheck?)}
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

  # `force?` re-derives regardless of freshness (a credential-present arrived);
  # it is gated at the derivation, not by mutating `derived_at`, so an entry
  # that still holds fresh models keeps serving them (and `health/3` never reads
  # a nil `derived_at`) while the fresh derive runs.
  defp refresh_key(state, key, host_config, force? \\ false) do
    now = now_ms(state)
    cache = Map.get(state.entries, key) || new_cache()
    state = put_in(state, [:entries, key], cache)

    if not cache.refreshing and (force? or expired?(cache, now, state.ttl_ms)) do
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

  # A credential-present recognition re-derives one {host, harness} now,
  # forced (freshness is irrelevant — the world just changed). If a derive is
  # already in flight it may have read PRE-commit world-state (the credential
  # had not landed when it started), so rather than race a second task past it,
  # the entry is flagged to re-check when that derive completes — honored on
  # BOTH the success and error completion paths (`maybe_recheck`), because the
  # wired edge has no periodic sweep to fall back on and must not drop the
  # re-recognition on either outcome.
  defp force_rederive(state, {host, _harness} = key) do
    case Map.get(enumerate_hosts(state), host) do
      nil ->
        state

      host_config ->
        case state.entries[key] do
          %{refreshing: true} = cache ->
            put_in(state, [:entries, key], Map.put(cache, :recheck, true))

          _ ->
            refresh_key(state, key, host_config, true)
        end
    end
  end

  defp maybe_recheck(state, _key, false), do: state

  defp maybe_recheck(state, {host, _harness} = key, true) do
    case Map.get(enumerate_hosts(state), host) do
      nil -> state
      host_config -> refresh_key(state, key, host_config, true)
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

      catalog_state =
        probe
        |> Map.put(:host_name, host)
        |> Map.put(:options, state.options)
        |> Map.put(:credential_status, fn provider, machine ->
          credential_status(state, provider, machine)
        end)

      with :onboarded <- catalog_onboarding_status(module, catalog_state, state, host),
           kind when kind in [:api_key, :subscription] <-
             catalog_credential_kind(module, catalog_state, state, host) do
        probe = Map.put(probe, :credential_kind, kind)

        probe
        |> module.fetch_catalog()
        |> retry_after_rotation_harvest(kind, probe, module)
      else
        {:needs_onboarding, reason} ->
          {:error, {:needs_onboarding, reason}}

        :none ->
          {:error, {:needs_onboarding, :missing}}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error -> {:error, {:exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp catalog_onboarding_status(Tightbeam.Harness.Pi, catalog_state, _state, _host) do
    if PiProvider.pi_catalog_ready?(catalog_state),
      do: :onboarded,
      else: {:needs_onboarding, :missing}
  end

  defp catalog_onboarding_status(module, _catalog_state, state, host) do
    credential_status(state, module.credential_provider(), host)
  end

  defp catalog_credential_kind(Tightbeam.Harness.Pi, _catalog_state, state, host) do
    cond do
      credential_status(state, :opencode_go, host) == :onboarded ->
        credential_kind(state, :opencode_go, host)

      credential_status(state, :local_openai, host) == :onboarded ->
        :api_key

      true ->
        :api_key
    end
  end

  defp catalog_credential_kind(module, _catalog_state, state, host) do
    credential_kind(state, module.credential_provider(), host)
  end

  # A subscription bearer 401 on the STORE copy can mean the credential is
  # genuinely revoked, or it can mean Claude Code rotated it inside the
  # harness home: the vendor's write-temp-then-rename severs the store's
  # symlink, the store copy freezes on the pre-rotation token, and the
  # provider revokes the superseded one (issue #9). `Homes.sweep_auth/2`
  # already knows how to harvest a severed home's regular file back into the
  # store and is a no-op when nothing is severed, so trying it here costs
  # nothing against a truly revoked credential and turns the staleness
  # window into its own repair trigger — instead of waiting on the next boot
  # sweep or a session spawn's home reconciliation to close it.
  #
  # `sweep_auth/2` reads the LOCAL filesystem only (gateway.ex's boot call
  # does the same), so this is scoped to a local probe; a remote host's
  # credential lives on that host and this cannot reach it.
  defp retry_after_rotation_harvest(
         {:error, {:http_status, 401, _} = initial_401} = error,
         :subscription,
         %{host_config: %{ssh: nil}} = probe,
         module
       ) do
    Tightbeam.Homes.sweep_auth(probe.base_dir, module.id())

    case module.fetch_catalog(probe) do
      {:ok, _entries} = success ->
        success

      {:error, retry_failure} ->
        {:error,
         {:rotation_retry_failed,
          %{
            initial_401: initial_401,
            initial_guidance: "sign in again to repair the original 401",
            retry_failure: retry_failure
          }}}
    end
  rescue
    _ -> error
  end

  defp retry_after_rotation_harvest(result, _kind, _probe, _module), do: result

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

  # A needs_onboarding outcome is world-state that can change at any instant (a
  # credential lands mid-TTL), so it is NEVER cached as durable truth: it stays
  # eligible to re-derive, so the next refresh pass — a read, or the
  # credential-present recognition — reaches the new world-state rather than
  # waiting a full TTL later (O4/I5, the DELETE). The `refreshing` guard still
  # bounds this to one in-flight derive per key.
  defp expired?(%{reason: {:needs_onboarding, _}}, _now, _ttl), do: true

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
