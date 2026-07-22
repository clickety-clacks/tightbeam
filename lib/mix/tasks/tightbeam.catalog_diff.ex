defmodule Mix.Tasks.Tightbeam.Catalog.Diff do
  use Mix.Task

  alias Tightbeam.Acp.Adapter
  alias Tightbeam.ModelCatalog

  @shortdoc "Diff the live model catalog against the preferred-model working set"

  @harnesses ["claude", "codex"]
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
    guidance_path = Path.join([base_dir, "identity", "guidance", "preferred-models.md"])

    inventories =
      case fetch_live(base_dir) do
        {:ok, inventories} -> inventories
        {:error, degraded} -> Mix.raise(catalog_error(degraded))
      end

    {status, diff} = evaluate(inventories, guidance_path)
    Mix.shell().info(format(diff, if(options[:json], do: :json, else: :human)))

    if status != 0 do
      Mix.raise("model catalog drift detected")
    end
  end

  @doc false
  def base_dir do
    System.get_env("TIGHTBEAM_BASE_DIR") ||
      System.get_env("TIGHTBEAM_HOME") ||
      Path.join(System.user_home!(), ".tightbeam")
  end

  @doc false
  def fetch_live(base_dir, timeout_ms \\ @fetch_timeout_ms) do
    name = :tightbeam_catalog_diff

    case ModelCatalog.start_link(base_dir: base_dir, name: name) do
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
  def evaluate(inventories, guidance_path) do
    working_set = read_working_set!(guidance_path)

    live =
      inventories
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.ref)
      |> Enum.uniq()
      |> Enum.sort()

    live_models = MapSet.new(live, &base_ref/1)
    working_set_models = MapSet.new(working_set, &base_ref/1)

    # Working-set membership covers the catalog's base model identity regardless of
    # whether either side spells the ref with an effort qualifier. Reports retain
    # the source refs; only set membership is normalized through the shared parser.
    diff = %{
      missing_from_catalog: Enum.reject(working_set, &MapSet.member?(live_models, base_ref(&1))),
      new_arrivals: Enum.reject(live, &MapSet.member?(working_set_models, base_ref(&1))),
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

  defp poll_fresh(server, deadline) do
    health = Map.new(@harnesses, fn harness -> {harness, ModelCatalog.get(harness, server)} end)

    if Enum.all?(health, fn {_harness, {_entries, state}} -> state == :fresh end) do
      {:ok, ModelCatalog.get(server)}
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

  defp read_working_set!(guidance_path) do
    guidance_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "## Working set (capsules)"))
    |> case do
      [] -> Mix.raise("preferred_models_parse_failed: Working set (capsules) section not found")
      [_heading | section] -> working_set_bullets(section)
    end
  end

  defp working_set_bullets(lines) do
    lines
    |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^- \*\*([^*]+)\*\* —/, line) do
        [_, model_id] -> [model_id]
        nil -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp base_ref(ref), do: elem(Adapter.parse_model_ref(ref), 0)

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
