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

  ASSEMBLED FROM CHEAP LOCAL FACTS, NEVER FROM AN INFERENCE TURN. Every fact
  here is one boot already establishes for itself:

  - the model catalog's per-harness `{entries, health}`, already cached by the
    refresh that runs during boot — a GenServer read, no network;
  - one `File.exists?` per harness on the adapter path;
  - one harness-CLI version probe per LOCAL harness — the executability axis
    (O5/I6). It reuses `Placement.harness_binary_probe`, the SAME probe boot's
    own preflight already runs, so readiness reads the executability taxonomy
    `doctor` surfaces as `harness_binary:*` rather than forking a parallel one.
    A bounded `--version` call is not free, but it is nothing like the gate
    probe: no inference turn, no socket, no network. It is run only for the
    local host; a satellite's executability is unknowable from here and stays
    unknown, never reported as a failure.

  It must never grow anything shaped like the gate probe, which costs ~9.5s
  because it is a real inference turn. A live model turn, a socket, a network
  round-trip are all out; the local, bounded facts above — which boot already
  pays for — are in.

  AND IT DOES NOT GUESS. `credential_server_unavailable` is the diagnostic being
  unable to look, not a dead credential — the same trap `mix tightbeam.doctor`
  fell into, where a healthy org and an empty one produced identical output. A
  fact boot cannot establish is reported as unknown, never as a failure of the
  thing it names.
  """

  alias Tightbeam.{Harness, Model, ModelCatalog, Placement, Unroutable}

  @type harness_row :: %{
          host: String.t(),
          base_dir: String.t(),
          harness: String.t(),
          adapter: :present | {:missing, String.t()} | {:unknown, atom()},
          binary: :runnable | {:broken, term()} | {:unknown, atom()},
          credential: :live | {:absent, atom()} | {:unknown, term()} | {:degraded, term()},
          model: :selectable | :unset | {:unroutable, Unroutable.t()} | :unknown,
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
    keys = catalog |> ModelCatalog.get() |> Map.keys()

    unsettled? =
      keys == [] or
        Enum.any?(keys, fn {host, harness} ->
          match?(
            {[], {:unavailable, reason}} when reason in [:not_derived, :catalog_not_started],
            ModelCatalog.get(host, harness, catalog)
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
  `archetypes` is the loaded manifest map (`Archetypes.all/0` in production).
  """
  @spec summary(map(), GenServer.server(), %{optional(String.t()) => map()}) :: %{
          harnesses: [harness_row()],
          runnable?: boolean(),
          unplaceable_archetypes: [%{name: String.t(), where: [String.t()]}]
        }
  def summary(config, catalog \\ ModelCatalog, archetypes \\ %{}) do
    local = Placement.local_host_name()

    hosts =
      config.base_dir
      |> Placement.hosts(Map.get(config, :db, Tightbeam.DB))
      |> Enum.sort()

    rows =
      for {host, host_config} <- hosts, module <- Harness.all() do
        harness_row(module, host, host_config, host == local, config, catalog)
      end

    %{
      harnesses: rows,
      runnable?: Enum.any?(rows, & &1.runnable?),
      unplaceable_archetypes: unplaceable_archetypes(archetypes, Enum.map(hosts, &elem(&1, 0)))
    }
  end

  # An archetype whose where names ONLY unregistered hosts can place nothing, and
  # today it fails silently at spawn time instead of being named here (#95). A
  # partial intersection is NOT flagged — the registered subset still places —
  # and ["*"] places anywhere by definition.
  defp unplaceable_archetypes(archetypes, hosts) do
    for {name, archetype} <- Enum.sort(archetypes),
        archetype.where != ["*"],
        Enum.all?(archetype.where, &(&1 not in hosts)) do
      %{name: name, where: archetype.where}
    end
  end

  defp harness_row(module, host, host_config, local?, config, catalog) do
    wire = module.wire_name()
    {entries, health} = ModelCatalog.get(host, wire, catalog)

    adapter = adapter_state(module, local?, config)
    binary = binary_state(module, local?, config)
    credential = credential_state(entries, health)
    model = model_state(host, wire, credential, config, catalog)

    %{
      host: host,
      base_dir: host_config.base_dir,
      harness: wire,
      # `onboard` takes the CREDENTIAL PROVIDER, not the harness: a credential
      # belongs to anthropic or openai, and claude/codex are the harnesses that
      # spend it. Interpolating the harness name here printed a command the CLI
      # rejects ("provider must be openai or anthropic") on the one surface the
      # operator is told to act on. The harness already knows its own provider.
      provider: module.credential_provider(),
      adapter: adapter,
      binary: binary,
      credential: credential,
      model: model,
      # An UNKNOWN adapter or an UNKNOWN binary does not veto. Boot establishes
      # both with local checks that cannot see a satellite, and this module's rule
      # is that a fact it cannot establish is never reported as a failure of the
      # thing it names — vetoing on it would print that failure on every healthy
      # satellite, on every boot. A binary that is KNOWN broken does veto: a
      # harness whose vendor CLI cannot run is not runnable regardless of a live
      # credential or a fresh catalog (O5/I6) — this is what makes a
      # present-but-unverified host (credential live, catalog fresh, runtime dead)
      # render as an executability gap rather than as READY.
      runnable?:
        not match?({:missing, _}, adapter) and not match?({:broken, _}, binary) and
          credential == :live and model == :selectable
    }
  end

  # Post-#46 the adapter lives under the host's own base_dir for every locality,
  # so one path serves both. The bin name is the package's basename — pinned by
  # a test over every registered harness, so a harness that breaks the
  # convention fails loudly instead of being reported permanently missing.
  defp adapter_state(_module, false, _config), do: {:unknown, :not_probed_on_satellite}

  defp adapter_state(module, true, config) do
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

  # The executability axis (O5/I6): can this harness actually RUN here? The vendor
  # CLI must be runnable, checked with the SAME probe boot's preflight already
  # runs (`Placement.harness_binary_probe`) and `doctor` surfaces as
  # `harness_binary:*` — readiness reads that taxonomy, it does not fork one. Like
  # the adapter, the CLI is probed only on the local host; a satellite's
  # executability is unknowable from boot and reported unknown, never as a
  # failure. Injectable via `config.harness_binary_probe`, exactly as `doctor`
  # injects it, so the summary stays hermetic in tests.
  defp binary_state(_module, false, _config), do: {:unknown, :not_probed_on_satellite}

  defp binary_state(module, true, config) do
    probe = Map.get(config, :harness_binary_probe, &Placement.harness_binary_probe/2)

    case probe.(module.id(), Path.join(config.base_dir, "bin")) do
      # The version string is doctor's to display; readiness needs only the
      # runnable/broken verdict, so it keeps the axis a plain three-state fact.
      {:ok, %{version: _version}} -> :runnable
      {:error, reason} -> {:broken, reason}
    end
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

  # THE MODEL ROW DEFERS ONLY WHERE ANOTHER ROW ALREADY SPEAKS. An ABSENT or
  # UNKNOWN credential is the credential column's story — it names the grant, the
  # host and the onboard command — and repeating it here would be noise, so the
  # model is reported unknown (this is also where the not-yet-derived policy
  # lives: nothing is established, so nothing is asserted).
  #
  # A DEGRADED catalog is a different fact. The credential is not implicated: the
  # inventory came back empty for the catalog's own reason — a client_version
  # filter, a malformed body — and NO other row says so. Deferring there is how
  # the centralized "upgrade the binary" diagnosis failed to reach boot at all.
  defp model_state(_host, _harness, {:absent, _reason}, _config, _catalog), do: :unknown
  defp model_state(_host, _harness, {:unknown, _reason}, _config, _catalog), do: :unknown

  # Asked of the one routability owner rather than derived here. Boot used to
  # decide this itself, with a narrower rule that could not tell "no such model"
  # from "model present, no tier named" — and reported the second as the first.
  defp model_state(host, harness, _credential, config, catalog) do
    case Map.get(config, :default_model) do
      %Model{} = model ->
        case ModelCatalog.route(host, harness, model, catalog) do
          {:ok, _routed} -> :selectable
          {:error, unroutable} -> {:unroutable, unroutable}
        end

      _ ->
        :unset
    end
  end

  @doc """
  Render the summary as the closing lines of boot.

  The verdict comes FIRST and is unambiguous, because it is the sentence an
  operator will act on. A working install says so in one line and stops — a
  readiness summary that nags on every healthy boot trains people to skip it.
  """
  @spec render(%{harnesses: [harness_row()], runnable?: boolean()}, map()) :: [String.t()]
  def render(%{runnable?: true, harnesses: rows} = summary, _config) do
    ready =
      rows
      |> Enum.filter(& &1.runnable?)
      |> Enum.map_join(", ", &"#{&1.harness} on #{&1.host}")

    blocked = Enum.reject(rows, & &1.runnable?)

    ["READY: #{ready} can run turns."] ++
      Enum.flat_map(blocked, &harness_lines/1) ++
      pre_expiry_lines(rows) ++
      archetype_lines(summary) ++
      supervision_lines()
  end

  def render(%{runnable?: false, harnesses: rows} = summary, config) do
    [
      "NOT READY: no harness on any host can run a turn. The gateway is",
      "serving, so clients can connect, but every turn will fail until the",
      "gaps below are closed."
    ] ++
      Enum.flat_map(rows, &harness_lines/1) ++
      pre_expiry_lines(rows) ++
      archetype_lines(summary) ++
      ["", "Diagnose further with: mix tightbeam.doctor (base_dir #{config.base_dir})"]
  end

  # O7/I8 (PO ruling 2026-08-06): no credential kind carries a readable expiry, so
  # there is NO pre-expiry wake — and this module is where that subtraction is made
  # HONEST rather than silent. For every credential that is present and working (a
  # live inventory), readiness states plainly that no pre-expiry warning is
  # available: the credential self-rotates or never expires, so an observed 401 in
  # flight is its only failure signal, not an advance courtesy. It builds no wake
  # and no horizon, reads no expiry value, and asserts nothing about current health
  # (which stays 401-observed, I3/I8) — it only names the absence so the operator
  # learns the credential's one real failure signal.
  defp pre_expiry_lines(rows) do
    case Enum.filter(rows, &(&1.credential == :live)) do
      [] ->
        []

      live ->
        [""] ++
          Enum.map(live, fn row ->
            "#{row.harness} on #{row.host}: no pre-expiry warning is available for this " <>
              "credential kind — it self-rotates or never expires, so Tightbeam reads no " <>
              "expiry and an observed 401 in flight is its only failure signal, not an " <>
              "advance warning."
          end)
    end
  end

  # `Map.get`, not a pattern: tests build summary maps by hand and a summary
  # without the key must render as one without unplaceable archetypes.
  defp archetype_lines(summary) do
    case Map.get(summary, :unplaceable_archetypes, []) do
      [] ->
        []

      unplaceable ->
        [""] ++
          Enum.map(unplaceable, fn %{name: name, where: where} ->
            "archetype #{name}: no host in its where (#{Enum.join(where, ", ")}) is " <>
              "registered — sessions cannot be placed with it"
          end)
    end
  end

  # THE INSTALL IS NOT FINISHED UNTIL A SERVICE MANAGER OWNS THE GATEWAY, and the
  # gateway can tell: a service manager sets these in the environment it starts
  # us with (systemd exports INVOCATION_ID; launchd is reached through
  # XPC_SERVICE_NAME). Foreground means no restart after a reboot and, worse, no
  # log — a foreground launcher usually redirects with `tee`, which truncates on
  # restart, so the run you need after a crash is destroyed by the restart.
  # Measured on gibson 2026-08-05: the host rebooted, the gateway stayed down
  # until noticed by hand, and the crash log had already been overwritten.
  #
  # A line, not a refusal: running in the foreground is exactly right while
  # installing or debugging. The gateway states the fact and lets the operator
  # decide, which is the same rule as every other readiness gap.
  defp supervision_lines do
    if supervised?() do
      []
    else
      [
        "",
        "Running in the FOREGROUND: no service manager owns this gateway, so it " <>
          "will not survive a logout or a reboot, and its log is whatever the " <>
          "launcher redirected (a `tee` without -a truncates on restart). Fine " <>
          "while installing; finish the install with the service step in the " <>
          "README before relying on this host."
      ]
    end
  end

  defp supervised? do
    System.get_env("INVOCATION_ID") != nil or System.get_env("XPC_SERVICE_NAME") != nil
  end

  defp harness_lines(row) do
    # PRECEDENCE (O5/I6): when a harness cannot EXECUTE, the actionable gap is
    # executability, not the credential — onboarding a credential cannot start a
    # binary that will not run. So the executability gap leads (binary_line is
    # first) and the ONBOARDING remedy is suppressed; the onboarding remedy is
    # named only when the harness CAN execute but has no working credential. Only
    # the onboarding remedy (an ABSENT credential) is suppressed — a degraded or
    # unknown-credential DIAGNOSIS is not a "no credential" claim and stays, since
    # it never misdirects the operator to onboard.
    credential =
      if executability_broken?(row) and match?({:absent, _}, row.credential),
        do: nil,
        else: credential_line(row)

    gaps =
      [binary_line(row), adapter_line(row), credential, model_line(row)]
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
          "  #{row.harness} on #{row.host}:",
          "    cannot run turns, and boot could not say why " <>
            "(adapter=#{inspect(row.adapter)} binary=#{inspect(row.binary)} " <>
            "credential=#{inspect(row.credential)} model=#{inspect(row.model)}) — please " <>
            "report this, it is a gap in the summary itself"
        ]

      [] ->
        []

      lines ->
        ["", "  #{row.harness} on #{row.host}:"] ++ Enum.map(lines, &("    " <> &1))
    end
  end

  # Executability is broken when a fact boot CAN establish says the harness cannot
  # run: its vendor CLI is known-broken, or its ACP adapter is missing. An UNKNOWN
  # binary (a satellite boot cannot probe) is not "broken" — the standing rule
  # forbids reporting an un-establishable fact as a failure — so it does not
  # suppress the credential remedy or veto runnability.
  defp executability_broken?(row) do
    match?({:broken, _}, row.binary) or match?({:missing, _}, row.adapter)
  end

  # The executability gap the vendor CLI cannot cover. `:not_found` (not on PATH)
  # and `{:exec_failed, _}` (on PATH but will not run — the gibson
  # codex-as-`.js`-without-node incident) are both executability failures a
  # credential cannot fix; naming them here is O5's whole point.
  defp binary_line(%{binary: :runnable}), do: nil
  defp binary_line(%{binary: {:unknown, _reason}}), do: nil

  defp binary_line(%{harness: wire, host: host, binary: {:broken, reason}}) do
    "#{wire} CLI on #{host} CANNOT RUN (#{describe_binary_failure(reason)}). No turn can " <>
      "be placed on it, and onboarding a credential cannot help until the binary runs — the " <>
      "credential remedy is not the fix here. Repair the #{wire} CLI (ensure it is on PATH " <>
      "and its interpreter is available), then re-check with: mix tightbeam.doctor"
  end

  # Mirrors `gateway.ex`'s boot-time `describe_probe_failure` so the executability
  # story reads the same whether it surfaces at preflight or in this summary.
  defp describe_binary_failure(:not_found), do: "its CLI is not on PATH"

  defp describe_binary_failure({:exec_failed, detail}),
    do: "its CLI is on PATH but failed to execute: #{String.trim(to_string(detail))}"

  defp describe_binary_failure(other), do: inspect(other)

  defp adapter_line(%{adapter: :present}), do: nil
  defp adapter_line(%{adapter: {:unknown, _reason}}), do: nil

  # The fallback command is PINNED and `--no-save`. An operator who follows a remedy
  # verbatim gets whatever it says, so a bare package name here installs npm's latest
  # and floats the adapter off its pin — the drift the install site was fixed to prevent,
  # reintroduced by the sentence that tells someone how to do it by hand (#47).
  defp adapter_line(%{harness: wire, adapter: {:missing, path}}) do
    install_dir = path |> Path.dirname() |> Path.dirname() |> Path.dirname()

    "ACP adapter missing at #{path}. Boot only checks readiness; it does not install " <>
      "adapters. Tightbeam will install its pinned adapters automatically when the next " <>
      "session is spawned. Manual fallback: npm install --prefix " <>
      "#{Tightbeam.Harness.Support.shell_quote(install_dir)} --no-save " <>
      "#{package_for(wire)}@#{version_for(wire)}"
  end

  defp credential_line(%{credential: :live}), do: nil

  defp credential_line(%{
         provider: provider,
         harness: harness,
         host: host,
         base_dir: base_dir,
         credential: {:absent, :missing}
       }) do
    "Tightbeam has no credential for #{provider} on #{host}. It does not use or import " <>
      "your normal #{harness} CLI login; Tightbeam keeps its own credential under " <>
      "#{Path.join(base_dir, "auth")}. Run on #{host}: " <>
      "#{Tightbeam.Credentials.onboard_command(provider)} " <>
      "--as-user <userId>"
  end

  defp credential_line(%{provider: provider, host: host, credential: {:absent, reason}}) do
    "no credential on #{host} (#{inspect(reason)}) — this host's model catalog is " <>
      "empty, so no model can be selected here. Onboard it with: " <>
      "#{Tightbeam.Credentials.onboard_command(provider)} --as-user <userId> on #{host}"
  end

  defp credential_line(%{harness: wire, host: host, credential: {:unknown, reason}}) do
    "credential state UNKNOWN (#{inspect(reason)}) — boot has not established " <>
      "this, so it is NOT a claim that #{wire}'s credential on #{host} is bad. " <>
      "Check with: mix tightbeam.doctor, or watch the first turn."
  end

  defp credential_line(%{harness: wire, host: host, credential: {:degraded, reason}}) do
    "catalog degraded (#{inspect(reason)}) — #{wire} fetched no models on #{host}. " <>
      "Turns placed there will fail model selection until it recovers."
  end

  defp model_line(%{model: :selectable}), do: nil
  defp model_line(%{model: :unknown}), do: nil

  defp model_line(%{harness: wire, model: :unset}) do
    "no default model set — set TIGHTBEAM_DEFAULT_MODEL to a live #{wire} model " <>
      "and TIGHTBEAM_DEFAULT_EFFORT to one of its levels (see mix tightbeam.catalog.diff)"
  end

  # The FACT is the routability owner's; boot no longer derives a narrower one of
  # its own. The REMEDY is boot's, because it is the environment that sets this
  # default — and a tier gap is fixed by naming a tier, not by re-picking a model
  # that was never the problem.
  defp model_line(%{model: {:unroutable, unroutable}}) do
    case default_model_remedy(unroutable) do
      nil -> "default model " <> Unroutable.message(unroutable)
      remedy -> "default model " <> Unroutable.message(unroutable) <> " — " <> remedy
    end
  end

  # A REMEDY THAT CANNOT WORK IS A FALSE STATEMENT. Naming a tier fixes a model
  # that HAS tiers; a model with none is fixed by unsetting the level; and a
  # catalog that could not be derived is not fixed by re-picking a model at all —
  # its repair is in the refusal itself (onboard the grant, upgrade the binary),
  # so boot adds nothing.
  defp default_model_remedy(%Unroutable{cause: :no_catalog}), do: nil

  defp default_model_remedy(%Unroutable{cause: :effort_not_offered, offered: offered})
       when offered != [] do
    if Enum.all?(offered, &(&1.entry.efforts == [])) do
      "unset TIGHTBEAM_DEFAULT_EFFORT (see mix tightbeam.catalog.diff)"
    else
      effort_remedy()
    end
  end

  defp default_model_remedy(%Unroutable{cause: :needs_effort}), do: effort_remedy()

  defp default_model_remedy(_unroutable) do
    "set TIGHTBEAM_DEFAULT_MODEL/_EFFORT to something that host offers " <>
      "(see mix tightbeam.catalog.diff)"
  end

  defp effort_remedy do
    "set TIGHTBEAM_DEFAULT_EFFORT to one of the tiers it offers " <>
      "(see mix tightbeam.catalog.diff)"
  end

  defp package_for(wire) do
    Enum.find_value(Harness.all(), wire, fn module ->
      if module.wire_name() == wire, do: module.install_package()
    end)
  end

  # Asked of the harness module, like the package name and like `Spinup` asks it, so
  # the remedy cannot drift from the version assimilate would actually install.
  defp version_for(wire) do
    Enum.find_value(Harness.all(), "latest", fn module ->
      if module.wire_name() == wire, do: module.adapter_version()
    end)
  end
end
