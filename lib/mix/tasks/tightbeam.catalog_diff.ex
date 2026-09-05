defmodule Mix.Tasks.Tightbeam.Catalog.Diff do
  use Mix.Task

  alias Tightbeam.Model
  alias Tightbeam.ModelCatalog

  @shortdoc "Diff the live model catalog against the preferred-model working set"

  @poll_interval_ms 250
  @fetch_timeout_ms 20_000

  @impl Mix.Task
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [base_dir: :string, json: :boolean], aliases: [])

    if positional != [] or invalid != [] do
      Mix.raise("usage: mix tightbeam.catalog.diff [--base-dir DIR] [--json]")
    end

    base_dir = options[:base_dir] || base_dir()

    working_set_path = working_set_path(base_dir)

    working_set = read_working_set!(working_set_path)

    inventories =
      case fetch_live(base_dir) do
        {:ok, inventories} -> inventories
        {:ok, _inventories, degraded} -> Mix.raise(catalog_error(degraded))
        {:error, degraded} -> Mix.raise(catalog_error(degraded))
      end

    {status, diff} = evaluate_working_set(inventories, working_set)
    Mix.shell().info(format(diff, if(options[:json], do: :json, else: :human)))

    if status != 0 do
      Mix.raise("model catalog drift detected")
    end
  end

  @doc false
  def base_dir, do: Tightbeam.BaseDir.resolve()

  @doc false
  def working_set_path(base_dir) do
    Path.join([base_dir, "identity", "kungfu", "agentic-engineering", "preferred-models.md"])
  end

  @doc false
  def fetch_live(base_dir, timeout_ms \\ @fetch_timeout_ms, options \\ []) do
    name = Keyword.get(options, :name, :tightbeam_catalog_diff)

    # A bare mix task is a diagnostic of THIS machine and owns no DB to read
    # the host registry from (and must not create one), so the catalog gets the
    # local host as its whole world instead of the registry table.
    hosts =
      Keyword.get(options, :hosts, fn ->
        %{
          Tightbeam.Placement.local_host_name() => %{
            ssh: nil,
            base_dir: base_dir,
            cli_bin: nil
          }
        }
      end)

    options = Keyword.merge(options, base_dir: base_dir, name: name, hosts: hosts)

    case ModelCatalog.start_link(options) do
      {:ok, pid} ->
        try do
          await_fresh(name, timeout_ms)
        after
          GenServer.stop(pid)
        end

      {:error, reason} ->
        {:error, %{"catalog" => {:start_failed, reason}}}
    end
  end

  @doc false
  def evaluate(inventories, working_set_path) do
    evaluate_working_set(inventories, read_working_set!(working_set_path))
  end

  defp evaluate_working_set(inventories, working_set) do
    live =
      inventories
      |> Map.values()
      |> List.flatten()
      |> Enum.map(&Model.to_ref(Model.new(&1.family, context: &1.context)))
      |> Enum.uniq()
      |> Enum.sort()

    live_models = MapSet.new(live)
    working_set_models = MapSet.new(working_set)

    # Both sides name MODELS, not tiers: the catalog holds one entry per vendor
    # model (its efforts are a property of that entry) and the working set is a
    # list of model names. Nothing is stripped to compare them — stripping a
    # suffix is how a context variant got read as a reasoning level.
    diff = %{
      missing_from_catalog: Enum.reject(working_set, &MapSet.member?(live_models, &1)),
      new_arrivals: Enum.reject(live, &MapSet.member?(working_set_models, &1)),
      live: live,
      working_set: working_set
    }

    status = if diff.missing_from_catalog == [], do: 0, else: 1
    {status, diff}
  end

  @doc false
  def format(diff, :json), do: JSON.encode!(diff)

  def format(diff, :human) do
    [
      report_section("MISSING FROM CATALOG (drift)", diff.missing_from_catalog),
      report_section("NEW ARRIVALS (info)", diff.new_arrivals),
      "Live refs: #{length(diff.live)}",
      "Working-set models: #{length(diff.working_set)}"
    ]
    |> Enum.join("\n")
  end

  defp await_fresh(server, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_fresh(server, deadline)
  end

  # Scoped to the host this task runs on. Catalogs are per `{host, harness}`, but
  # a bare mix task is a diagnostic of THIS machine — the org-wide per-host view
  # belongs to the running gateway (readiness, and the refusals themselves).
  defp poll_fresh(server, deadline) do
    host = Tightbeam.Placement.local_host_name()

    health =
      Map.new(Tightbeam.Harness.all(), fn module ->
        {module.wire_name(), ModelCatalog.get(host, module.wire_name(), server)}
      end)

    if Enum.all?(health, fn {_harness, {_entries, state}} -> settled?(state) end) do
      inventories = ModelCatalog.host_inventories(host, server)

      degraded =
        health
        |> Map.reject(fn {_harness, {_entries, state}} -> state == :fresh end)
        |> Map.new(fn {harness, {_entries, state}} -> {harness, state} end)

      if map_size(degraded) == 0,
        do: {:ok, inventories},
        else: {:ok, inventories, degraded}
    else
      if System.monotonic_time(:millisecond) >= deadline do
        degraded =
          Map.new(health, fn {harness, {_entries, state}} -> {harness, state} end)
          |> Map.reject(fn {_harness, state} -> state == :fresh end)

        {:error, degraded}
      else
        Process.sleep(@poll_interval_ms)
        poll_fresh(server, deadline)
      end
    end
  end

  defp settled?(:fresh), do: true
  defp settled?({:unavailable, reason}), do: reason != :not_derived
  defp settled?(_state), do: false

  defp read_working_set!(working_set_path) do
    working_set_path
    |> read_working_set_source!()
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "## Working set (capsules)"))
    |> case do
      [] -> Mix.raise("preferred_models_parse_failed: Working set (capsules) section not found")
      [_heading | section] -> working_set_bullets(section)
    end
  end

  defp read_working_set_source!(working_set_path) do
    case File.read(working_set_path) do
      {:ok, contents} ->
        contents

      {:error, :enoent} ->
        Mix.raise(
          "working_set_not_installed: the agentic-engineering kungfu bundle and its " <>
            "preferred-model working set are not installed; run: tightbeam learn agentic-engineering"
        )

      {:error, reason} ->
        Mix.raise("preferred_models_read_failed: #{:file.format_error(reason)}")
    end
  end

  defp working_set_bullets(lines) do
    lines
    |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^- \*\*([^*]+)\*\*/, line) do
        [_, model_id] -> [model_id]
        nil -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp report_section(label, []), do: "#{label}: none"

  defp report_section(label, refs) do
    (["#{label}:"] ++ Enum.map(refs, &"  - #{&1}"))
    |> Enum.join("\n")
  end

  defp catalog_error(degraded) do
    detail =
      degraded
      |> Enum.sort()
      |> Enum.map_join(", ", fn {harness, reason} -> "#{harness}=#{inspect(reason)}" end)

    "catalog_unavailable: #{detail}"
  end
end
