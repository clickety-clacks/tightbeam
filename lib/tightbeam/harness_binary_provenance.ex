defmodule Tightbeam.HarnessBinaryProvenance do
  @moduledoc """
  Read-only evidence about the vendor CLI selected by each harness adapter.

  This module reports the adapter's existing selection rule. It does not change
  launch resolution. Only the two documented explicit path overrides are read;
  credential overlays and general process environments are never copied into
  the report or passed to a version probe.
  """

  alias Tightbeam.{AdapterCoordinator, DB, Harness, Placement}

  @version_timeout_ms 3_000
  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
  @override_names %{codex: "CODEX_PATH", claude: "CLAUDE_CODE_EXECUTABLE"}

  @doc false
  def capture(harness, host, base_dir, path, overlays, opts \\ []) do
    module = Harness.module!(harness)
    harness = module.id()
    override_name = Map.get(@override_names, harness)
    overlay_values = Map.new(overlays)

    override =
      if override_name do
        case Map.fetch(overlay_values, override_name) do
          {:ok, value} -> if(value == "", do: nil, else: value)
          :error -> Keyword.get(opts, :process_env, %{})[override_name]
        end
      end

    without_override_evidence? =
      Keyword.get(opts, :without_override_evidence?, false) and is_nil(override)

    selection =
      cond do
        is_binary(override) and String.trim(override) != "" -> "explicit_pinned_override"
        without_override_evidence? -> "unknown"
        harness in [:codex, :claude] -> "bundled_fallback"
        harness in [:pi, :cursor] -> "system"
        true -> "unsupported"
      end

    %{
      "host" => host,
      "harness" => module.wire_name(),
      "base_dir" => base_dir,
      "path_env" => path,
      "selection" => selection,
      "override_name" => override_name,
      "override_path" => if(selection == "explicit_pinned_override", do: override),
      "binary_name" => module.cli_binary(),
      "bundle_kind" => if(harness in [:codex, :claude], do: Atom.to_string(harness)),
      "adapter" => %{
        "package" => module.install_package(),
        "version" => adapter_version(module)
      },
      "captured_at_ms" => System.system_time(:millisecond),
      "selection_evidence" =>
        cond do
          selection == "unknown" ->
            "explicit override environment was not captured at adapter launch"

          selection == "unsupported" ->
            "the registered harness has no vendor CLI provenance rule"

          selection == "explicit_pinned_override" ->
            override_name

          true ->
            "adapter selection rule"
        end
    }
  end

  @doc false
  def project(rows) when is_list(rows) do
    running_versions = versions_by_harness_and_host(rows, :running)
    next_versions = versions_by_harness_and_host(rows, :next_launch)

    Enum.map(rows, fn row ->
      running = Map.get(row, "running", [])
      next_launch = Map.get(row, "next_launch", %{})
      warnings = []

      warnings =
        if Enum.any?(running, &(&1["source"] == "bundled_fallback")) or
             next_launch["source"] == "bundled_fallback" do
          ["bundled_fallback_selected" | warnings]
        else
          warnings
        end

      warnings =
        if versions_differ_across_hosts?(Map.get(running_versions, row["harness"], %{})) or
             versions_differ_across_hosts?(Map.get(next_versions, row["harness"], %{})) do
          ["observed_version_differs_across_hosts" | warnings]
        else
          warnings
        end

      Map.put(row, "warnings", Enum.reverse(warnings))
    end)
  end

  defp versions_by_harness_and_host(rows, :running) do
    Enum.reduce(rows, %{}, fn row, acc ->
      versions =
        row
        |> Map.get("running", [])
        |> Enum.filter(&(&1["status"] == "observed" and is_binary(&1["version"])))
        |> Enum.map(& &1["version"])

      put_host_versions(acc, row, versions)
    end)
  end

  defp versions_by_harness_and_host(rows, :next_launch) do
    Enum.reduce(rows, %{}, fn row, acc ->
      observation = Map.get(row, "next_launch", %{})

      versions =
        if observation["status"] == "observed" and is_binary(observation["version"]),
          do: [observation["version"]],
          else: []

      put_host_versions(acc, row, versions)
    end)
  end

  defp put_host_versions(acc, row, versions) do
    Map.update(acc, row["harness"], %{row["host"] => versions}, fn hosts ->
      Map.update(hosts, row["host"], versions, &Enum.uniq(&1 ++ versions))
    end)
  end

  defp versions_differ_across_hosts?(host_versions) do
    observed_sets =
      host_versions
      |> Map.values()
      |> Enum.reject(&(&1 == []))
      |> Enum.map(&(&1 |> Enum.uniq() |> Enum.sort()))
      |> Enum.uniq()

    length(observed_sets) > 1
  end

  @doc "Collect host-scoped next-launch and running-generation evidence."
  def report(base_dir, db \\ DB, coordinator \\ AdapterCoordinator, opts \\ []) do
    with {:ok, hosts} <- read_hosts(base_dir, db) do
      harnesses = Keyword.get(opts, :harnesses, Harness.all())

      overrides =
        Map.new(
          for {host, _} <- hosts, module <- harnesses do
            harness = module.wire_name()
            {{host, harness}, selection_overlays(db, host, harness)}
          end
        )

      report_for_inputs(base_dir, hosts, overrides, coordinator_launches(coordinator), opts)
    end
  rescue
    error ->
      {:error, %{"status" => "unavailable", "reason" => safe_reason(error)}}
  catch
    kind, reason ->
      {:error, %{"status" => "unavailable", "reason" => safe_reason({kind, reason})}}
  end

  @doc false
  def report_for_inputs(base_dir, hosts, overlays, launches \\ [], opts \\ []) do
    config = %{base_dir: base_dir, cli_bin: Path.join(base_dir, "bin")}
    harnesses = Keyword.get(opts, :harnesses, Harness.all())
    probe = Keyword.get(opts, :probe, &probe_capture/2)

    rows =
      for {host, host_config} <- Enum.sort(hosts), module <- harnesses do
        harness = module.wire_name()
        path = Placement.toolchain_path_preview_for(config, host_config)
        overlay = Map.get(overlays, {host, harness}, [])
        remote? = not is_nil(host_config.ssh)

        next_capture =
          capture(module, host, host_config.base_dir, path, overlay,
            process_env:
              Keyword.get(
                opts,
                :process_env,
                if(remote?, do: %{}, else: selection_process_env(module))
              ),
            without_override_evidence?: Keyword.get(opts, :without_override_evidence?, false)
          )

        next_capture =
          resolve_remote_selection(host_config, path, module, next_capture, overlay, opts)

        running =
          launches
          |> Enum.filter(fn launch ->
            launch["host"] == host and launch["harness"] == harness and launch["ready"]
          end)
          |> Enum.map(fn launch ->
            run_capture = launch["capture"] || %{"selection" => "unknown"}
            probed = probe.(host_config, run_capture)

            Map.merge(probed, %{
              "generation" => launch["generation"],
              "captured_at_ms" => run_capture["captured_at_ms"],
              "observation" => "adapter_launch_selection"
            })
          end)

        next_launch = probe.(host_config, next_capture)

        %{
          "host" => host,
          "harness" => harness,
          "adapter" => next_capture["adapter"],
          "running" => running,
          "next_launch" => next_launch
        }
      end

    {:ok, %{"schema_version" => 1, "rows" => project(rows)}}
  rescue
    error -> {:error, %{"status" => "unavailable", "reason" => safe_reason(error)}}
  catch
    kind, reason ->
      {:error, %{"status" => "unavailable", "reason" => safe_reason({kind, reason})}}
  end

  @doc "A read-only per-row formatter shared by `mix tightbeam.doctor`."
  def format_human(%{"rows" => rows}) when is_list(rows) do
    rows
    |> Enum.flat_map(fn row ->
      prefix = "harness binary #{row["host"]}/#{row["harness"]}"
      adapter = Map.get(row, "adapter", %{})
      package = Map.get(adapter, "package", "unknown")
      version = Map.get(adapter, "version", "unknown")
      adapter_line = "  harness adapter #{row["host"]}/#{row["harness"]}: #{package} #{version}"

      running =
        case row["running"] do
          [] -> ["  #{prefix} running: not observed"]
          values -> Enum.map(values, &format_observation(prefix, "running", &1))
        end

      [adapter_line] ++
        running ++
        [format_observation(prefix, "next launch", row["next_launch"])] ++
        Enum.map(row["warnings"], &"  #{prefix} warning: #{&1}")
    end)
    |> Enum.join("\n")
  end

  def format_human(%{"status" => status, "reason" => reason}),
    do: "  #{status}: #{reason}"

  def format_human(_), do: "  unavailable"

  @doc "Fetch the same protected, live report used by the Rust doctor command."
  def fetch_gateway(base_dir) do
    path = Path.join(base_dir, "gateway.json")

    with {:ok, encoded} <- File.read(path),
         {:ok, %{"port" => port, "cliToken" => token}} <- JSON.decode(encoded),
         true <- is_integer(port) and is_binary(token) and token != "",
         :ok <- ensure_httpc(),
         {:ok, {{_http, status, _reason}, _headers, body}} <-
           :httpc.request(
             :get,
             {String.to_charlist("http://127.0.0.1:#{port}/doctor/harness-binary-provenance"),
              [
                {~c"authorization", String.to_charlist("Bearer " <> token)},
                {~c"x-tightbeam-cli-version",
                 Tightbeam.CliCompatibility.required_version()
                 |> to_string()
                 |> String.to_charlist()}
              ]},
             [connect_timeout: 1_000, timeout: 5_000],
             body_format: :binary
           ),
         true <- status in 200..299,
         {:ok, report} <- JSON.decode(body) do
      {:ok, report}
    else
      {:ok, {{_http, status, _reason}, _headers, _body}} ->
        {:error, %{"status" => "unavailable", "reason" => "gateway returned HTTP #{status}"}}

      {:error, reason} ->
        {:error, %{"status" => "unavailable", "reason" => safe_reason(reason)}}

      _ ->
        {:error, %{"status" => "unavailable", "reason" => "gateway report was not available"}}
    end
  rescue
    error -> {:error, %{"status" => "unavailable", "reason" => safe_reason(error)}}
  catch
    kind, reason ->
      {:error, %{"status" => "unavailable", "reason" => safe_reason({kind, reason})}}
  end

  @doc false
  def report_unavailable(reason),
    do: %{"status" => "unavailable", "reason" => to_string(reason), "rows" => []}

  @doc false
  def probe_capture(host_config, capture) do
    source = capture["selection"]

    case {source, executable(host_config, capture)} do
      {"unknown", _} ->
        %{"status" => "unknown", "source" => "unknown", "reason" => capture["selection_evidence"]}

      {_, {:ok, command}} ->
        args = command ++ ["--version"]

        case run_host(host_config, capture["path_env"], args) do
          {:ok, output} ->
            %{
              "status" => "observed",
              "source" => source,
              "path" => List.last(command),
              "version" => output |> String.trim() |> String.slice(0, 240),
              "version_observed_at_ms" => System.system_time(:millisecond)
            }

          {:error, {:exit, code, output}} ->
            %{
              "status" => "unprobeable",
              "source" => source,
              "path" => List.last(command),
              "reason" =>
                "version command exited #{code}: #{output |> String.trim() |> String.slice(0, 160)}"
            }

          {:error, reason} ->
            %{"status" => "unavailable", "source" => source, "reason" => safe_reason(reason)}
        end

      {_, {:error, :not_found}} ->
        %{"status" => "missing", "source" => source, "reason" => "selected binary was not found"}

      {_, {:error, :unsupported}} ->
        %{
          "status" => "unsupported",
          "source" => source,
          "reason" => "no vendor CLI resolver for this harness"
        }

      {_, {:error, :relative_override}} ->
        %{
          "status" => "unavailable",
          "source" => source,
          "reason" =>
            "relative CLI override cannot be resolved without the adapter working directory"
        }

      {_, {:error, reason}} ->
        %{"status" => "unavailable", "source" => source, "reason" => safe_reason(reason)}
    end
  rescue
    error ->
      %{
        "status" => "unavailable",
        "source" => Map.get(capture, "selection", "unknown"),
        "reason" => safe_reason(error)
      }
  end

  defp read_hosts(base_dir, db) do
    try do
      {:ok, Placement.hosts(base_dir, db)}
    rescue
      error -> {:error, %{"status" => "unavailable", "reason" => safe_reason(error)}}
    end
  end

  defp resolve_remote_selection(%{ssh: nil}, _path, _module, capture, _overlay, _opts),
    do: capture

  defp resolve_remote_selection(host_config, path, module, snapshot, overlay, opts) do
    if snapshot["selection"] in ["bundled_fallback", "unknown"] do
      case remote_override(host_config, path, module.id(), opts) do
        {:ok, value} when is_binary(value) and value != "" ->
          capture(
            module,
            snapshot["host"],
            snapshot["base_dir"],
            path,
            [{snapshot["override_name"], value}],
            without_override_evidence?: false
          )

        {:ok, _empty} ->
          capture(module, snapshot["host"], snapshot["base_dir"], path, overlay,
            without_override_evidence?: false
          )

        _ ->
          capture(module, snapshot["host"], snapshot["base_dir"], path, overlay,
            without_override_evidence?: true
          )
      end
    else
      snapshot
    end
  end

  defp selection_overlays(db, host, harness) do
    case Map.get(@override_names, Harness.parse!(harness).id()) do
      nil ->
        []

      name ->
        case DB.query(
               db,
               "SELECT value FROM harness_env_overlays WHERE host = ?1 AND harness = ?2 AND name = ?3",
               [host, harness, name]
             ) do
          {:ok, [[value]]} ->
            [{name, value}]

          {:ok, []} ->
            []

          {:error, reason} ->
            raise "could not read #{name} override for #{host}/#{harness}: #{inspect(reason)}"
        end
    end
  end

  defp coordinator_launches(coordinator) do
    if Process.whereis(coordinator) do
      AdapterCoordinator.binary_launches(coordinator)
    else
      []
    end
  end

  defp executable(_host_config, %{"selection" => "unknown"}), do: {:error, :unknown}
  defp executable(_host_config, %{"selection" => "unsupported"}), do: {:error, :unsupported}

  defp executable(
         host_config,
         %{
           "selection" => "explicit_pinned_override",
           "override_path" => path
         } = capture
       )
       when is_binary(path) and path != "" do
    cond do
      Path.type(path) == :absolute ->
        {:ok, [path]}

      String.contains?(path, "/") or String.contains?(path, "\\") ->
        {:error, :relative_override}

      true ->
        script = "command -v " <> Tightbeam.Harness.Support.shell_quote(path)

        case resolve_on_host(host_config, capture["path_env"], ["sh", "-c", script]) do
          {:ok, resolved} when resolved != "" -> {:ok, [resolved]}
          {:ok, _} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp executable(host_config, %{"selection" => "system", "binary_name" => name} = capture) do
    script = "command -v " <> Tightbeam.Harness.Support.shell_quote(name)

    case resolve_on_host(host_config, capture["path_env"], ["sh", "-c", script]) do
      {:ok, path} when path != "" -> {:ok, [path]}
      {:ok, _} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp executable(
         host_config,
         %{"selection" => "bundled_fallback", "bundle_kind" => "codex"} = capture
       ) do
    node_bundle(host_config, capture, :codex)
  end

  defp executable(
         host_config,
         %{"selection" => "bundled_fallback", "bundle_kind" => "claude"} = capture
       ) do
    node_bundle(host_config, capture, :claude)
  end

  defp executable(_host_config, _capture), do: {:error, :unsupported}

  defp node_bundle(host_config, capture, kind) do
    root = Path.join(capture["base_dir"], "adapters/node_modules")
    script = resolver_script(kind)

    case run_host(host_config, capture["path_env"], ["node", "-e", script, root]) do
      {:ok, path} when path != "" -> {:ok, ["node", String.trim(path)]}
      {:ok, _} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolver_script(:codex) do
    "const {createRequire}=require('node:module');" <>
      "const r=createRequire(process.argv[1]+'/package.json');" <>
      "const entry=r.resolve('@agentclientprotocol/codex-acp');" <>
      "process.stdout.write(createRequire(entry).resolve('@openai/codex/bin/codex.js'));"
  end

  defp resolver_script(:claude) do
    "const {createRequire}=require('node:module');" <>
      "const r=createRequire(process.argv[1]+'/package.json');" <>
      "const entry=r.resolve('@agentclientprotocol/claude-agent-acp');" <>
      "const sdk=createRequire(entry).resolve('@anthropic-ai/claude-agent-sdk');" <>
      "const s=createRequire(sdk),p=process.platform,a=process.arch,e=p==='win32'?'.exe':'';" <>
      "const names=p==='linux'?[`@anthropic-ai/claude-agent-sdk-linux-${a}-musl`,`@anthropic-ai/claude-agent-sdk-linux-${a}`]:[`@anthropic-ai/claude-agent-sdk-${p}-${a}`];" <>
      "for(const n of names){try{process.stdout.write(s.resolve(`${n}/claude${e}`));process.exit(0)}catch{}}" <>
      "process.exit(2);"
  end

  defp resolve_on_host(host_config, path, command) do
    case run_host(host_config, path, command) do
      {:ok, output} -> {:ok, String.trim(output)}
      other -> other
    end
  end

  defp run_host(%{ssh: nil}, path, command) do
    runner = fn argv ->
      System.cmd("/usr/bin/env", ["-i", "PATH=#{local_path(path)}"] ++ argv,
        stderr_to_stdout: true
      )
    end

    bounded_run(runner, command)
  end

  defp run_host(%{ssh: ssh}, path, command) do
    remote_script =
      "PATH=#{remote_path(path)}; export PATH; exec /usr/bin/env -i PATH=\"$PATH\" " <>
        Enum.map_join(command, " ", &Tightbeam.Harness.Support.shell_quote/1)

    runner = fn argv -> System.cmd("ssh", argv, stderr_to_stdout: true) end

    bounded_run(runner, [
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=5",
      ssh,
      "sh",
      "-c",
      Tightbeam.Harness.Support.shell_quote(remote_script)
    ])
  end

  defp bounded_run(runner, argv) do
    case Tightbeam.Harness.Support.bounded_run(runner, argv, @version_timeout_ms) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {:exit, code, to_string(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_override(%{ssh: ssh}, path, harness, opts) do
    name = Map.get(@override_names, harness)

    runner =
      Keyword.get(opts, :remote_runner, fn command, args, run_opts ->
        System.cmd(command, args, run_opts)
      end)

    if is_nil(name) do
      {:ok, nil}
    else
      script = "PATH=#{remote_path(path)}; export PATH; printf '%s' \"${#{name}-}\""

      command =
        ["ssh" | @ssh_opts] ++ [ssh, "sh", "-c", Tightbeam.Harness.Support.shell_quote(script)]

      case Tightbeam.Harness.Support.bounded_run(
             fn argv -> runner.(hd(argv), tl(argv), stderr_to_stdout: false) end,
             command,
             @version_timeout_ms
           ) do
        {:ok, {value, 0}} -> {:ok, String.trim(to_string(value))}
        _ -> {:error, :unavailable}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp local_path(path), do: String.replace(path || "", "$PATH", System.get_env("PATH") || "")

  defp remote_path(path) do
    case String.split(path || "", "$PATH", parts: 2) do
      [prefix, ""] -> Tightbeam.Harness.Support.shell_quote(prefix) <> "\"$PATH\""
      [prefix] -> Tightbeam.Harness.Support.shell_quote(prefix)
      _ -> Tightbeam.Harness.Support.shell_quote(path)
    end
  end

  defp adapter_version(module) do
    if function_exported?(module, :adapter_version, 0),
      do: module.adapter_version(),
      else: "unknown"
  end

  defp selection_process_env(module) do
    case Map.get(@override_names, module.id()) do
      nil -> %{}
      name -> %{name => System.get_env(name)}
    end
  end

  defp format_observation(prefix, label, observation) do
    status = observation["status"] || "unknown"
    source = observation["source"] || "unknown"

    detail =
      [observation["path"], observation["version"], observation["reason"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    "  #{prefix} #{label}: #{status} (#{source})" <>
      if(detail == "", do: "", else: " — #{detail}")
  end

  defp safe_reason(error) do
    error
    |> inspect(limit: 3, printable_limit: 160)
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.slice(0, 200)
  end

  defp ensure_httpc do
    case Application.ensure_all_started(:inets) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
