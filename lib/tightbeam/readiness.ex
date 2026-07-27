defmodule Tightbeam.Readiness do
  @moduledoc """
  The last thing boot says: can this instance run a turn, and if not, what is
  missing and what fixes it.

  Boot used to end on `Running Tightbeam.Wire.Router ... (http)` — a success
  line — even on an org with no credentials, no adapters and no models, where
  not one turn could run. The two `model catalog ... degraded` warnings scrolled
  past ABOVE that line, so the closing statement was the only one that read like
  a verdict and it was the wrong one.

  Serving with nothing configured stays correct (Flynn: "if it can run at all").
  This does not refuse a boot, gate anything, or return a status. It only makes
  the closing statement true.

  ASSEMBLED, NOT PROBED. Every fact here is one boot already has:

  - the model catalog's per-harness `{entries, health}`, already cached by the
    refresh that runs during boot — a GenServer read, no network;
  - one `File.exists?` per harness on the adapter path.

  Nothing here starts a process, opens a socket, or runs a turn. In particular
  it must never grow anything shaped like the gate probe, which costs ~9.5s
  because it is a real inference turn.

  AND IT DOES NOT GUESS. `credential_server_unavailable` is the diagnostic being
  unable to look, not a dead credential — the same trap `mix tightbeam.doctor`
  fell into, where a healthy org and an empty one produced identical output. A
  fact boot cannot establish is reported as unknown, never as a failure of the
  thing it names.
  """

  alias Tightbeam.{Harness, ModelCatalog}

  @type harness_row :: %{
          harness: String.t(),
          adapter: :present | {:missing, String.t()},
          credential: :live | {:absent, atom()} | {:unknown, term()} | {:degraded, term()},
          model: :selectable | {:absent, String.t()} | :unknown,
          runnable?: boolean()
        }

  @doc """
  Wait, briefly and asynchronously, for the catalog refresh that boot ALREADY
  started to land, then summarise.

  This adds nothing to boot: `Application.start/2` has returned before this runs.
  It exists because the refresh is async, so at the instant boot finishes the
  credential facts are genuinely not yet established — and reporting them then
  would print `unknown` on every healthy start, which is noise, or `degraded`,
  which is a lie. Bounded, because a catalog that never settles must not hold the
  summary forever; if the bound expires the row says unknown, truthfully.
  """
  @spec await_settled(GenServer.server(), non_neg_integer(), non_neg_integer()) :: :ok
  def await_settled(catalog \\ ModelCatalog, timeout_ms \\ 10_000, step_ms \\ 250) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_settled(catalog, deadline, step_ms)
  end

  defp poll_settled(catalog, deadline, step_ms) do
    unsettled? =
      Enum.any?(Harness.all(), fn module ->
        match?(
          {[], {:unavailable, reason}} when reason in [:not_derived, :catalog_not_started],
          ModelCatalog.get(module.wire_name(), catalog)
        )
      end)

    cond do
      not unsettled? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(step_ms)
        poll_settled(catalog, deadline, step_ms)
    end
  end

  @doc """
  Assemble the readiness of every registered harness from what boot already
  knows. `catalog` is the `ModelCatalog` server; it is read, never started.
  """
  @spec summary(map(), GenServer.server()) :: %{harnesses: [harness_row()], runnable?: boolean()}
  def summary(config, catalog \\ ModelCatalog) do
    rows = Enum.map(Harness.all(), &harness_row(&1, config, catalog))
    %{harnesses: rows, runnable?: Enum.any?(rows, & &1.runnable?)}
  end

  defp harness_row(module, config, catalog) do
    wire = module.wire_name()
    {entries, health} = ModelCatalog.get(wire, catalog)

    adapter = adapter_state(module, config)
    credential = credential_state(entries, health)
    model = model_state(entries, credential, config)

    %{
      harness: wire,
      adapter: adapter,
      credential: credential,
      model: model,
      runnable?: adapter == :present and credential == :live and model == :selectable
    }
  end

  # Post-#46 the adapter lives under the host's own base_dir for every locality,
  # so one path serves both. The bin name is the package's basename — pinned by
  # a test over every registered harness, so a harness that breaks the
  # convention fails loudly instead of being reported permanently missing.
  defp adapter_state(module, config) do
    path =
      Path.join([
        config.base_dir,
        "adapters",
        "node_modules",
        ".bin",
        Path.basename(module.install_package())
      ])

    if File.exists?(path), do: :present, else: {:missing, path}
  end

  # A non-empty inventory IS the credential working: the catalog was fetched
  # with it. Everything else is classified by WHY it is empty.
  defp credential_state([_ | _], _health), do: :live

  defp credential_state([], {:unavailable, reason}), do: classify(reason)
  defp credential_state([], :fresh), do: {:degraded, :empty_inventory}
  defp credential_state([], :stale), do: {:degraded, :empty_inventory}
  defp credential_state([], other), do: {:degraded, other}

  defp classify({:needs_onboarding, :credential_server_unavailable}),
    do: {:unknown, :credential_server_unavailable}

  defp classify({:needs_onboarding, reason}), do: {:absent, reason}
  defp classify(:catalog_not_started), do: {:unknown, :catalog_not_started}
  # The first refresh has not landed yet. Boot has not established anything about
  # this credential, so saying "degraded, turns will fail" would assert a failure
  # of the thing named on no evidence — doctor's exact mistake.
  defp classify(:not_derived), do: {:unknown, :catalog_not_derived_yet}
  defp classify(reason), do: {:degraded, reason}

  # Selectability is only meaningful once the catalog is real; with no credential
  # the empty inventory says nothing about the model.
  defp model_state(_entries, credential, _config) when credential != :live, do: :unknown

  defp model_state(entries, _credential, config) do
    model = Map.get(config, :default_model)

    cond do
      not (is_binary(model) and model != "") -> {:absent, "(unset)"}
      Enum.any?(entries, &(&1.ref == model)) -> :selectable
      true -> {:absent, model}
    end
  end

  @doc """
  Render the summary as the closing lines of boot.

  The verdict comes FIRST and is unambiguous, because it is the sentence an
  operator will act on. A working install says so in one line and stops — a
  readiness summary that nags on every healthy boot trains people to skip it.
  """
  @spec render(%{harnesses: [harness_row()], runnable?: boolean()}, map()) :: [String.t()]
  def render(%{runnable?: true, harnesses: rows}, _config) do
    ready = rows |> Enum.filter(& &1.runnable?) |> Enum.map_join(", ", & &1.harness)
    blocked = Enum.reject(rows, & &1.runnable?)

    ["READY: #{ready} can run turns."] ++
      Enum.flat_map(blocked, &harness_lines/1)
  end

  def render(%{runnable?: false, harnesses: rows}, config) do
    [
      "NOT READY: no harness on this instance can run a turn. The gateway is",
      "serving, so clients can connect, but every turn will fail until the",
      "gaps below are closed."
    ] ++
      Enum.flat_map(rows, &harness_lines/1) ++
      ["", "Diagnose further with: mix tightbeam.doctor (base_dir #{config.base_dir})"]
  end

  defp harness_lines(row) do
    gaps =
      [adapter_line(row), credential_line(row), model_line(row)]
      |> Enum.reject(&is_nil/1)

    case gaps do
      # A row that is NOT runnable must never render silently. `model_state/3`
      # currently makes `credential: :live` with `model: :unknown` unreachable, so
      # this is defensive — but the invariant lives in two functions that do not
      # know about each other, and a blocked harness that explains nothing is the
      # precise failure this whole summary exists to end.
      [] when not row.runnable? ->
        [
          "",
          "  #{row.harness}:",
          "    cannot run turns, and boot could not say why " <>
            "(adapter=#{inspect(row.adapter)} credential=#{inspect(row.credential)} " <>
            "model=#{inspect(row.model)}) — please report this, it is a gap in the summary itself"
        ]

      [] ->
        []

      lines ->
        ["", "  #{row.harness}:"] ++ Enum.map(lines, &("    " <> &1))
    end
  end

  defp adapter_line(%{adapter: :present}), do: nil

  defp adapter_line(%{harness: wire, adapter: {:missing, path}}) do
    "ACP adapter missing at #{path} — no turn can start. " <>
      "Install it with: tightbeam assimilate --harness #{wire} (or npm install " <>
      "--prefix #{path |> Path.dirname() |> Path.dirname() |> Path.dirname()} " <>
      "#{package_for(wire)})"
  end

  defp credential_line(%{credential: :live}), do: nil

  defp credential_line(%{harness: wire, credential: {:absent, reason}}) do
    "no credential (#{inspect(reason)}) — the model catalog is empty, so no " <>
      "model can be selected. Onboard it with: tightbeam onboard #{wire} --as-user <userId>"
  end

  defp credential_line(%{harness: wire, credential: {:unknown, reason}}) do
    "credential state UNKNOWN (#{inspect(reason)}) — boot has not established " <>
      "this, so it is NOT a claim that #{wire}'s credential is bad. " <>
      "Check with: mix tightbeam.doctor, or watch the first turn."
  end

  defp credential_line(%{harness: wire, credential: {:degraded, reason}}) do
    "catalog degraded (#{inspect(reason)}) — #{wire} fetched no models. " <>
      "Turns will fail model selection until it recovers."
  end

  defp model_line(%{model: :selectable}), do: nil
  defp model_line(%{model: :unknown}), do: nil

  defp model_line(%{harness: wire, model: {:absent, "(unset)"}}) do
    "no default model set — set TIGHTBEAM_DEFAULT_MODEL to a live #{wire} ref " <>
      "(see mix tightbeam.catalog.diff)"
  end

  defp model_line(%{harness: wire, model: {:absent, model}}) do
    "default model #{model} is not in #{wire}'s live catalog — set " <>
      "TIGHTBEAM_DEFAULT_MODEL to a listed ref (see mix tightbeam.catalog.diff)"
  end

  defp package_for(wire) do
    Enum.find_value(Harness.all(), wire, fn module ->
      if module.wire_name() == wire, do: module.install_package()
    end)
  end
end
