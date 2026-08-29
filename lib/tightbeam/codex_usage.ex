defmodule Tightbeam.CodexUsage do
  @moduledoc false

  use GenServer

  require Logger

  alias Tightbeam.Acp.Adapter
  alias Tightbeam.Harness

  @read_method "_codex/account/rate_limits/read"

  ## Client

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc false
  def project(server, key, credential_kind, now_ms \\ System.system_time(:millisecond)) do
    GenServer.call(server, {:project, key, credential_kind, now_ms})
  end

  @doc false
  def adapter_ready(server, key, adapter, credential_kind) do
    GenServer.cast(server, {:adapter_ready, key, adapter, credential_kind})
  end

  @doc false
  def adapter_down(server, key, adapter) do
    GenServer.cast(server, {:adapter_down, key, adapter})
  end

  @doc false
  def binding_changed(server, provider, host) do
    case GenServer.whereis(server) do
      nil -> :ok
      _pid -> GenServer.call(server, {:binding_changed, provider, host})
    end
  end

  @doc false
  def adapter_event(server, key, adapter, event) do
    GenServer.cast(server, {:adapter_event, key, adapter, event})
  end

  @doc false
  def read_method, do: @read_method

  @doc false
  def normalize_full(raw) when is_map(raw) do
    snapshot = Harness.Codex.usage_snapshot(raw)
    baseline = sanitize_snapshot(snapshot, :full)
    projection(baseline)
  end

  def normalize_full(_raw), do: projection(%{})

  @doc false
  def normalize_sparse(%{"rateLimits" => snapshot}) when is_map(snapshot),
    do: sanitize_snapshot(snapshot, :sparse)

  def normalize_sparse(_raw), do: %{}

  @doc false
  def map_read_result({:ok, raw}, fetched_at) do
    %{baseline: baseline, windows: windows, invalid?: invalid?} = normalize_full(raw)

    if windows == [] do
      {:invalid_usage, baseline, fetched_at, invalid?}
    else
      {:accepted, baseline, windows, fetched_at, invalid?}
    end
  end

  def map_read_result({:error, :timeout}, _fetched_at), do: {:error, :timeout}
  def map_read_result({:error, _reason}, _fetched_at), do: {:error, :provider_unavailable}
  def map_read_result(_other, _fetched_at), do: {:error, :provider_unavailable}

  @doc false
  def merge_status(payload, nil), do: payload

  def merge_status(payload, %{generation: generation, usage: usage}) do
    payload
    |> Map.put(:metadataContextGeneration, generation)
    |> update_in([:display], &Map.put(&1, :codexUsage, usage))
  end

  ## Server

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       sequence: 0,
       request: Keyword.get(opts, :request, &Adapter.request_codex_usage/2)
     }}
  end

  @impl true
  def handle_call({:project, key, kind, now_ms}, _from, state) do
    {entry, state} = ensure_binding(state, key, kind)

    if eligible?(key, kind) do
      {entry, state} = refresh_if_needed(state, key, entry, now_ms)

      {:reply, %{generation: entry.generation, usage: wire_usage(entry)},
       put_entry(state, key, entry)}
    else
      {:reply, nil, state}
    end
  end

  def handle_call({:binding_changed, provider, host}, _from, state) do
    {entries, state} = transition_provider_entries(state, provider, host)
    {:reply, :ok, %{state | entries: entries}}
  end

  @impl true
  def handle_cast({:adapter_ready, key, adapter, kind}, state) do
    {entry, state} = ensure_binding(state, key, kind)
    entry = %{entry | adapter: adapter, incarnation: make_ref()}
    {entry, state} = maybe_start_refresh(state, key, entry, :read)
    {:noreply, put_entry(state, key, entry)}
  end

  def handle_cast({:adapter_down, key, adapter}, state) do
    case state.entries[key] do
      %{adapter: ^adapter} = entry ->
        entry =
          entry
          |> Map.put(:adapter, nil)
          |> Map.put(:incarnation, nil)
          |> Map.put(:claim, nil)
          |> mark_unavailable(:provider_unavailable)

        log_event(key, entry, :read, :provider_unavailable)
        {:noreply, put_entry(next_sequence(state), key, entry)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:adapter_event, key, adapter, {:auth, :terminal}}, state) do
    case state.entries[key] do
      %{adapter: ^adapter} = entry ->
        entry = transition(entry, entry.binding_kind, :account_binding_unavailable)
        log_event(key, entry, :read, :account_binding_unavailable)
        {:noreply, put_entry(next_sequence(state), key, entry)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:adapter_event, key, adapter, {:full, claim, result}}, state) do
    case state.entries[key] do
      %{adapter: ^adapter, incarnation: incarnation, claim: current} = entry
      when current == claim and claim.incarnation == incarnation and
             claim.generation == entry.generation ->
        {entry, outcome} = settle_full(entry, result, state.sequence + 1)
        log_event(key, entry, :read, outcome)
        {:noreply, put_entry(next_sequence(state), key, entry)}

      entry when is_map(entry) ->
        log_event(key, entry, :read, :superseded)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:adapter_event, key, adapter, {:sparse, sparse, fetched_at}}, state) do
    case state.entries[key] do
      %{adapter: ^adapter, incarnation: incarnation} = entry when not is_nil(incarnation) ->
        {entry, state, outcome} = accept_sparse(state, key, entry, sparse, fetched_at)
        log_event(key, entry, :update, outcome)
        {:noreply, put_entry(state, key, entry)}

      entry when is_map(entry) ->
        log_event(key, entry, :update, :superseded)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:adapter_event, _key, _adapter, {:auth, _classification}}, state),
    do: {:noreply, state}

  @impl GenServer
  def format_status(status) do
    entries =
      Map.new(status.state.entries, fn {key, entry} ->
        {key,
         %{
           generation: entry.generation,
           freshness: freshness(entry),
           windows: window_labels(entry),
           source: entry.accepted && entry.accepted.source
         }}
      end)

    status |> Map.put(:state, %{entries: entries}) |> Map.put(:message, :redacted)
  end

  defp transition_provider_entries(state, provider, host) do
    {entries, state} =
      Enum.reduce(state.entries, {%{}, state}, fn {key = {harness, _identity, key_host}, entry},
                                                  {entries, acc} ->
        if key_host == host and Harness.module!(harness).credential_provider() == provider do
          transitioned = transition(entry, entry.binding_kind, :account_binding_unavailable)
          log_event(key, transitioned, :read, :account_binding_unavailable)
          {Map.put(entries, key, transitioned), next_sequence(acc)}
        else
          {Map.put(entries, key, entry), acc}
        end
      end)

    {entries, state}
  end

  defp ensure_binding(state, key, kind) do
    case state.entries[key] do
      nil ->
        entry = fresh_entry(kind, :provider_unavailable)
        {entry, put_entry(next_sequence(state), key, entry)}

      %{binding_kind: ^kind} = entry ->
        {entry, state}

      entry ->
        entry = transition(entry, kind, binding_reason(kind))
        {entry, put_entry(next_sequence(state), key, entry)}
    end
  end

  defp fresh_entry(kind, reason) do
    %{
      binding_kind: kind,
      generation: generation(),
      adapter: nil,
      incarnation: nil,
      claim: nil,
      baseline: nil,
      accepted: nil,
      reason: reason,
      stale: false
    }
  end

  defp transition(_entry, kind, reason), do: fresh_entry(kind, reason)

  defp binding_reason(:subscription), do: :account_binding_unavailable
  defp binding_reason(_kind), do: :provider_unavailable

  defp eligible?({harness, _identity, _host}, :subscription),
    do: Harness.usage_capture?(harness)

  defp eligible?(_key, _kind), do: false

  defp refresh_if_needed(state, key, entry, now_ms) do
    elapsed? =
      entry.accepted &&
        Enum.any?(entry.accepted.windows, fn
          %{reset_at: reset_at} when is_integer(reset_at) -> reset_at <= now_ms
          _ -> false
        end)

    entry = if elapsed?, do: %{entry | stale: true}, else: entry

    if entry.claim || (entry.accepted && not entry.stale) do
      {entry, state}
    else
      maybe_start_refresh(state, key, entry, :read)
    end
  end

  defp maybe_start_refresh(state, key, entry, source) do
    cond do
      not eligible?(key, entry.binding_kind) ->
        {entry, state}

      entry.claim ->
        log_event(key, entry, source, :coalesced)
        {entry, state}

      not is_pid(entry.adapter) ->
        reason = entry.reason || :provider_unavailable
        {mark_unavailable(entry, reason), state}

      true ->
        claim = %{
          generation: entry.generation,
          incarnation: entry.incarnation,
          refresh: make_ref()
        }

        state.request.(entry.adapter, claim)
        {%{entry | claim: claim, stale: not is_nil(entry.accepted), reason: nil}, state}
    end
  end

  defp settle_full(entry, {:accepted, baseline, windows, fetched_at, invalid?}, sequence) do
    accepted = %{
      source: :read,
      fetched_at: fetched_at,
      windows: windows,
      mutation_sequence: sequence
    }

    {%{entry | claim: nil, baseline: baseline, accepted: accepted, stale: false, reason: nil},
     if(invalid?, do: :invalid, else: :accepted)}
  end

  defp settle_full(entry, {:invalid_usage, baseline, fetched_at, _invalid?}, _sequence) do
    if entry.accepted do
      {%{entry | claim: nil, baseline: baseline, stale: true, reason: nil}, :invalid}
    else
      {%{
         entry
         | claim: nil,
           baseline: baseline,
           stale: false,
           reason: :invalid_usage,
           invalid_fetched_at: fetched_at
       }, :invalid}
    end
  end

  defp settle_full(entry, {:error, reason}, _sequence)
       when reason in [:timeout, :provider_unavailable] do
    {entry |> Map.put(:claim, nil) |> mark_unavailable(reason), reason}
  end

  defp settle_full(entry, _result, _sequence) do
    {entry |> Map.put(:claim, nil) |> mark_unavailable(:provider_unavailable),
     :provider_unavailable}
  end

  defp accept_sparse(state, key, %{baseline: nil} = entry, _sparse, _fetched_at) do
    {entry, state} = maybe_start_refresh(state, key, entry, :update)
    {entry, state, if(entry.claim, do: :coalesced, else: :provider_unavailable)}
  end

  defp accept_sparse(state, _key, entry, sparse, fetched_at) do
    baseline = merge_sparse(entry.baseline, sparse)
    %{windows: windows, invalid?: invalid?} = projection(baseline)

    cond do
      windows == [] ->
        {mark_unavailable(%{entry | baseline: baseline}, :invalid_usage), next_sequence(state),
         :invalid}

      entry.accepted && entry.accepted.windows == windows ->
        {%{entry | baseline: baseline}, state, if(invalid?, do: :invalid, else: :accepted)}

      true ->
        accepted = %{
          source: :update,
          fetched_at: fetched_at,
          windows: windows,
          mutation_sequence: state.sequence + 1
        }

        {%{entry | baseline: baseline, accepted: accepted, stale: false, reason: nil},
         next_sequence(state), if(invalid?, do: :invalid, else: :accepted)}
    end
  end

  defp mark_unavailable(%{accepted: accepted} = entry, _reason) when not is_nil(accepted),
    do: %{entry | stale: true, reason: nil}

  defp mark_unavailable(entry, reason), do: %{entry | stale: false, reason: reason}

  defp wire_usage(%{claim: claim, accepted: nil}) when not is_nil(claim),
    do: %{freshness: "loading", windows: []}

  defp wire_usage(%{accepted: nil} = entry) do
    usage = %{
      freshness: "unavailable",
      windows: [],
      unavailableReason: Atom.to_string(entry.reason || :provider_unavailable)
    }

    case Map.get(entry, :invalid_fetched_at) do
      value when is_integer(value) -> Map.put(usage, :fetchedAt, value)
      _ -> usage
    end
  end

  defp wire_usage(%{accepted: accepted} = entry) do
    %{
      freshness: if(entry.stale || entry.claim, do: "stale", else: "fresh"),
      fetchedAt: accepted.fetched_at,
      windows: accepted.windows
    }
  end

  defp sanitize_snapshot(snapshot, mode) when is_map(snapshot) do
    [:primary, :secondary]
    |> Enum.reduce(%{}, fn field, acc ->
      value = Map.get(snapshot, Atom.to_string(field))

      case sanitize_window(value, mode) do
        :preserve -> acc
        sanitized -> Map.put(acc, field, sanitized)
      end
    end)
  end

  defp sanitize_snapshot(_snapshot, _mode), do: %{}

  defp sanitize_window(nil, :sparse), do: :preserve
  defp sanitize_window(value, _mode) when not is_map(value), do: %{}

  defp sanitize_window(value, mode) do
    [
      {:used_percent, "usedPercent"},
      {:duration, "windowDurationMins"},
      {:resets_at, "resetsAt"}
    ]
    |> Enum.reduce(%{}, fn {target, source}, acc ->
      case Map.fetch(value, source) do
        {:ok, nil} when mode == :sparse -> acc
        {:ok, nil} when target == :resets_at -> Map.put(acc, target, nil)
        {:ok, integer} when is_integer(integer) -> Map.put(acc, target, integer)
        {:ok, _invalid} -> Map.put(acc, target, :invalid)
        :error -> acc
      end
    end)
  end

  defp projection(baseline) do
    {windows, invalid?} =
      [:primary, :secondary]
      |> Enum.reduce({%{}, false}, fn field, {windows, invalid?} ->
        case project_window(Map.get(baseline, field)) do
          {:ok, %{label: label} = window} ->
            if Map.has_key?(windows, label) do
              {windows, true}
            else
              {Map.put(windows, label, window), invalid?}
            end

          :empty ->
            {windows, invalid?}

          :invalid ->
            {windows, true}
        end
      end)

    ordered = Enum.flat_map(["5h", "Week"], &List.wrap(Map.get(windows, &1)))
    %{baseline: baseline, windows: ordered, invalid?: invalid?}
  end

  defp project_window(nil), do: :empty
  defp project_window(window) when map_size(window) == 0, do: :empty

  defp project_window(%{used_percent: used, duration: duration} = window)
       when is_integer(used) and used in 0..100 and duration in [300, 10_080] do
    case Map.get(window, :resets_at) do
      reset when is_integer(reset) or is_nil(reset) ->
        {:ok,
         %{
           label: if(duration == 300, do: "5h", else: "Week"),
           remaining_percent: 100 - used,
           reset_at: if(is_integer(reset), do: reset * 1_000, else: nil)
         }}

      _ ->
        :invalid
    end
  end

  defp project_window(_window), do: :invalid

  defp merge_sparse(baseline, sparse) do
    Enum.reduce([:primary, :secondary], baseline, fn field, acc ->
      case Map.fetch(sparse, field) do
        {:ok, values} -> Map.update(acc, field, values, &Map.merge(&1, values))
        :error -> acc
      end
    end)
  end

  defp generation do
    "mcg-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
  end

  defp next_sequence(state), do: %{state | sequence: state.sequence + 1}
  defp put_entry(state, key, entry), do: %{state | entries: Map.put(state.entries, key, entry)}

  defp freshness(%{accepted: nil, claim: claim}) when not is_nil(claim), do: "loading"
  defp freshness(%{accepted: nil}), do: "unavailable"
  defp freshness(%{stale: true}), do: "stale"
  defp freshness(%{claim: claim}) when not is_nil(claim), do: "stale"
  defp freshness(_entry), do: "fresh"

  defp window_labels(%{accepted: %{windows: windows}}), do: Enum.map(windows, & &1.label)
  defp window_labels(_entry), do: []

  defp log_event({harness, _identity, host}, entry, source, outcome) do
    Logger.info("codex_usage_capture",
      event: "codex_usage_capture",
      harness: harness,
      host: host,
      binding_generation: entry.generation,
      source: source,
      outcome: outcome,
      freshness: freshness(entry),
      windows: window_labels(entry)
    )
  end
end
