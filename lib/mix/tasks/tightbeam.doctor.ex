defmodule Mix.Tasks.Tightbeam.Doctor do
  use Mix.Task

  alias Mix.Tasks.Tightbeam.Catalog.Diff
  alias Tightbeam.Acp.Adapter
  alias Tightbeam.Placement

  @shortdoc "Check inference-free Tightbeam bootstrap readiness"

  @default_model "claude-sonnet-5[medium]"

  @impl Mix.Task
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [base_dir: :string, json: :boolean], aliases: [])

    if positional != [] or invalid != [] do
      Mix.raise("usage: mix tightbeam.doctor [--base-dir DIR] [--json]")
    end

    base_dir = options[:base_dir] || Diff.base_dir()
    catalog = Diff.fetch_live(base_dir)

    # Invariant: resolve bootstrap config from ENV first (mirroring runtime.exs)
    # because a standalone mix task does not evaluate runtime.exs.
    inputs = [
      base_dir: base_dir,
      default_model:
        System.get_env("TIGHTBEAM_DEFAULT_MODEL") ||
          Application.get_env(:tightbeam, :default_model) || @default_model,
      default_harness:
        System.get_env("TIGHTBEAM_DEFAULT_HARNESS") ||
          Tightbeam.Harness.default().wire_name(),
      advertised_url:
        System.get_env("TIGHTBEAM_ADVERTISED_URL") ||
          Application.get_env(:tightbeam, :advertised_url),
      hosts: Placement.hosts(base_dir),
      local_host_name: Placement.local_host_name(),
      cli_bin: Path.join(base_dir, "bin")
    ]

    {status, report} = evaluate(catalog, inputs)
    Mix.shell().info(format(report, if(options[:json], do: :json, else: :human)))

    if status != 0 do
      Mix.raise("bootstrap_not_ready")
    end
  end

  @doc false
  def evaluate(catalog, inputs) do
    base_dir = Keyword.fetch!(inputs, :base_dir)
    default_harness = inputs |> Keyword.fetch!(:default_harness) |> to_string()
    default_model = Keyword.get(inputs, :default_model)
    advertised_url = Keyword.get(inputs, :advertised_url)
    hosts = Keyword.fetch!(inputs, :hosts)
    local_host_name = Keyword.fetch!(inputs, :local_host_name)
    cli_bin = Keyword.get(inputs, :cli_bin, Path.join(base_dir, "bin"))
    binary_probe = Keyword.get(inputs, :harness_binary_probe, &Placement.harness_binary_probe/2)
    harnesses = Enum.map(Tightbeam.Harness.all(), & &1.wire_name())

    harness_checks =
      Map.new(harnesses, fn harness ->
        {harness,
         [
           harness_binary_check(
             binary_probe.(Tightbeam.Harness.parse!(harness).id(), cli_bin),
             harness
           ),
           harness_auth_check(catalog, harness)
         ]}
      end)

    ready_harnesses =
      Enum.filter(harnesses, fn harness ->
        Enum.all?(Map.fetch!(harness_checks, harness), & &1.ok)
      end)

    harness_checks =
      Enum.flat_map(harnesses, fn harness ->
        Enum.map(Map.fetch!(harness_checks, harness), fn check ->
          cond do
            check.ok -> check
            ready_harnesses != [] -> %{check | level: :warn}
            harness != default_harness -> %{check | level: :warn}
            true -> check
          end
        end)
      end)

    non_harness_checks = [
      default_model_check(catalog, default_harness, default_model),
      identity_check(base_dir),
      advertised_url_check(advertised_url),
      hosts_check(hosts, local_host_name)
    ]

    checks = [hd(non_harness_checks)] ++ harness_checks ++ tl(non_harness_checks)
    ready = ready_harnesses != [] and Enum.all?(non_harness_checks, & &1.ok)
    {if(ready, do: 0, else: 1), %{checks: checks, ready: ready}}
  end

  @doc false
  def format(report, :json), do: JSON.encode!(report)

  def format(report, :human) do
    rows =
      Enum.map(report.checks, fn check ->
        [check.name, check.level |> Atom.to_string() |> String.upcase(), check.detail, check.fix]
      end)

    headings = ["check", "status", "detail", "fix-if-failed"]
    widths = column_widths([headings | rows])
    divider = Enum.map_join(widths, "-+-", &String.duplicate("-", &1))

    ([format_row(headings, widths), divider] ++ Enum.map(rows, &format_row(&1, widths)))
    |> Enum.join("\n")
  end

  defp default_model_check(catalog, harness, model) do
    fix =
      "Set TIGHTBEAM_DEFAULT_MODEL to a live id[effort] ref; see mix tightbeam.catalog.diff."

    cond do
      not (is_binary(model) and String.trim(model) != "") ->
        check("default_model", false, "default model is not set", fix)

      not effort_qualified?(model) ->
        check("default_model", false, "#{inspect(model)} is not an effort-qualified ref", fix)

      true ->
        case catalog do
          {:ok, inventories} ->
            default_model_inventory_check(inventories, harness, model, fix)

          {:ok, inventories, _degraded} ->
            default_model_inventory_check(inventories, harness, model, fix)

          {:error, degraded} ->
            check(
              "default_model",
              false,
              "catalog_unavailable: #{catalog_error(degraded)}",
              fix
            )
        end
    end
  end

  defp default_model_inventory_check(inventories, harness, model, fix) do
    live? = Enum.any?(Map.get(inventories, harness, []), &(&1.ref == model))

    detail =
      if live?,
        do: "#{model} is live for #{harness}",
        else: "#{model} is not live for #{harness}"

    check("default_model", live?, detail, fix)
  end

  defp harness_auth_check({:ok, inventories}, harness) do
    harness_auth_inventory_check(inventories, %{}, harness)
  end

  defp harness_auth_check({:ok, inventories, degraded}, harness) do
    harness_auth_inventory_check(inventories, degraded, harness)
  end

  defp harness_auth_check({:error, degraded}, harness) do
    reason = Map.get(degraded, harness, {:catalog_fetch_aborted, degraded})

    check(
      "harness_auth:#{harness}",
      false,
      "dead_sign_in: harness=#{harness} reason=#{inspect(reason)}",
      "Re-onboard the #{harness} harness credential."
    )
  end

  defp harness_auth_inventory_check(inventories, degraded, harness) do
    entries = Map.get(inventories, harness, [])
    ok = entries != []

    detail =
      if ok,
        do: "#{harness} fetched #{length(entries)} live refs",
        else:
          "dead_sign_in: harness=#{harness} reason=#{inspect(Map.get(degraded, harness, :empty_inventory))}"

    check("harness_auth:#{harness}", ok, detail, "Re-onboard the #{harness} harness credential.")
  end

  defp harness_binary_check({:ok, %{version: version}}, harness) do
    check("harness_binary:#{harness}", true, version, "")
  end

  defp harness_binary_check({:error, reason}, harness) do
    check(
      "harness_binary:#{harness}",
      false,
      inspect(reason),
      "Install the #{harness} CLI and ensure it is on PATH."
    )
  end

  defp identity_check(base_dir) do
    identity_dir = Path.join(base_dir, "identity")

    populated? =
      File.dir?(base_dir) and File.dir?(identity_dir) and
        File.dir?(Path.join(identity_dir, ".git")) and populated_identity?(identity_dir)

    detail =
      if populated?,
        do: "#{identity_dir} is a populated identity repo",
        else: "#{base_dir} or its populated identity repo is missing"

    check("base_dir_identity", populated?, detail, "Run mix tightbeam.init.")
  end

  defp advertised_url_check(url) when is_binary(url) do
    ok = String.trim(url) != ""
    detail = if ok, do: url, else: "advertised URL is empty"
    check("advertised_url", ok, detail, "Set TIGHTBEAM_ADVERTISED_URL.")
  end

  defp advertised_url_check(_missing) do
    check(
      "advertised_url",
      false,
      "advertised URL is not set",
      "Set TIGHTBEAM_ADVERTISED_URL."
    )
  end

  defp hosts_check(hosts, local_host_name) do
    ok = Map.has_key?(hosts, local_host_name)

    detail =
      if ok,
        do: "local host #{local_host_name} resolves",
        else: "local host #{local_host_name} is not registered"

    check("hosts_registered", ok, detail, "Register a host.")
  end

  defp effort_qualified?(ref) do
    {_model, effort} = Adapter.parse_model_ref(ref)
    is_binary(effort) and effort != ""
  end

  defp populated_identity?(identity_dir) do
    case File.ls(identity_dir) do
      {:ok, entries} ->
        File.regular?(Path.join([identity_dir, ".git", "HEAD"])) and
          Enum.any?(entries, &(&1 != ".git"))

      {:error, _reason} ->
        false
    end
  end

  defp check(name, ok, detail, fix) do
    level = if(ok, do: :pass, else: :fail)
    %{name: name, ok: ok, level: level, detail: detail, fix: if(ok, do: "", else: fix)}
  end

  defp catalog_error(degraded) do
    degraded
    |> Enum.sort()
    |> Enum.map_join(", ", fn {harness, reason} -> "#{harness}=#{inspect(reason)}" end)
  end

  defp column_widths(rows) do
    rows
    |> Enum.zip()
    |> Enum.map(fn column ->
      column |> Tuple.to_list() |> Enum.map(&String.length/1) |> Enum.max()
    end)
  end

  defp format_row(values, widths) do
    values
    |> Enum.zip(widths)
    |> Enum.map_join(" | ", fn {value, width} -> String.pad_trailing(value, width) end)
  end
end
