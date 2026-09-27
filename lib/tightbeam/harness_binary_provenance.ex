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

  @doc false
  def capture(harness, host, base_dir, path, overlays, opts \\ []) do
    module = Harness.module!(harness)
    override_name = module_override_env(module)
    default_source = module_default_source(module)
    bundle_probe_script = bundle_probe_script(module)
    overlay_values = Map.new(overlays)

    override =
      if override_name do
        case Map.fetch(overlay_values, override_name) do
          {:ok, value} -> if(value == "", do: nil, else: value)
          :error -> Keyword.get(opts, :process_env, %{})[override_name]
        end
      end

    without_override_evidence? =
      Keyword.get(opts, :without_override_evidence?, false) and is_nil(override) and
        is_binary(override_name)

    selection_rule =
      cond do
        is_binary(override) and String.trim(override) != "" -> "pinned_override"
        without_override_evidence? -> "unknown"
        is_binary(default_source) -> default_source
        true -> "unsupported"
      end

    %{
      "host" => host,
      "harness" => module.wire_name(),
      "base_dir" => base_dir,
      "path_env" => path,
      "selection_rule" => selection_rule,
      "override_name" => override_name,
      "override_path" => if(selection_rule == "pinned_override", do: override),
      "binary_name" => module.cli_binary(),
      "bundle_probe_script" => bundle_probe_script,
      "adapter" => %{
        "package" => module.install_package(),
        "version" => adapter_version(module)
      },
      "captured_at_ms" => System.system_time(:millisecond),
      "selection_evidence" =>
        cond do
          selection_rule == "unknown" ->
            "explicit override environment was not captured at adapter launch"

          selection_rule == "unsupported" ->
            "the registered harness has no vendor CLI provenance rule"

          selection_rule == "pinned_override" ->
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
            without_override_evidence?:
              remote? and Keyword.get(opts, :without_override_evidence?, false)
          )

        next_capture =
          resolve_remote_selection(host_config, path, module, next_capture, overlay, opts)

        running =
          launches
          |> Enum.filter(fn launch ->
            launch["host"] == host and launch["harness"] == harness and launch["ready"]
          end)
          |> Enum.map(fn launch ->
            run_capture = launch["capture"] || %{}

            probed =
              case run_capture["launch_observation"] do
                %{} = observation -> observation
                _ -> stale_launch_observation(run_capture)
              end

            Map.merge(probed, %{
              "generation" => launch["generation"],
              "captured_at_ms" => run_capture["captured_at_ms"],
              "observation" => "adapter_launch_selection",
              "adapter" =>
                run_capture["adapter"] || %{"package" => "unknown", "version" => "unknown"}
            })
          end)

        next_launch = observe_selection(host_config, next_capture, opts)

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

  @doc false
  def capture_launch_observation(host_config, capture, opts \\ []) do
    capture = resolve_remote_launch_selection(host_config, capture, opts)

    observation =
      if capture["selection_rule"] == "system" do
        observe_effective_system_launch(host_config, capture, Keyword.get(opts, :launch_plan))
      else
        observe_selection(host_config, capture, opts)
      end

    Map.put(capture, "launch_observation", observation)
  end

  defp resolve_remote_launch_selection(
         %{ssh: ssh} = host_config,
         %{"selection_rule" => "unknown", "override_name" => name} = capture,
         opts
       )
       when is_binary(ssh) and is_binary(name) do
    case remote_override(host_config, capture["path_env"], name, opts) do
      {:ok, value} when is_binary(value) and value != "" ->
        recapture_remote_launch(capture, [{name, value}])

      {:ok, _empty} ->
        recapture_remote_launch(capture, [])

      _ ->
        capture
    end
  end

  defp resolve_remote_launch_selection(_host_config, capture, _opts), do: capture

  defp recapture_remote_launch(capture, overlays) do
    capture(
      Harness.parse!(capture["harness"]),
      capture["host"],
      capture["base_dir"],
      capture["path_env"],
      overlays
    )
  end

  @doc false
  def observe_selection(host_config, capture, opts \\ []) do
    case capture["selection_rule"] do
      "unknown" ->
        %{"status" => "unknown", "source" => "unknown", "reason" => capture["selection_evidence"]}

      "unsupported" ->
        %{
          "status" => "unsupported",
          "source" => "unsupported",
          "reason" => capture["selection_evidence"]
        }

      "system" ->
        %{
          "status" => "unknown",
          "source" => "unknown",
          "reason" => "no effective vendor CLI launch has been observed"
        }

      _ ->
        probe = Keyword.get(opts, :probe, &probe_capture/2)
        probe.(host_config, capture)
    end
  rescue
    error ->
      %{
        "status" => "unavailable",
        "source" => "unknown",
        "reason" => safe_reason(error)
      }
  catch
    kind, reason ->
      %{
        "status" => "unavailable",
        "source" => "unknown",
        "reason" => safe_reason({kind, reason})
      }
  end

  defp stale_launch_observation(%{"captured_at_ms" => _captured_at_ms}) do
    %{
      "status" => "stale",
      "source" => "unknown",
      "reason" => "adapter generation has no captured binary-selection observation"
    }
  end

  defp stale_launch_observation(_) do
    %{
      "status" => "unknown",
      "source" => "unknown",
      "reason" => "adapter generation has no binary-selection capture"
    }
  end

  defp observe_effective_system_launch(host_config, capture, launch_plan) do
    case selected_vendor_executable(capture, launch_plan) do
      {:ok, path} ->
        case run_host(host_config, capture["path_env"], [path, "--version"]) do
          {:ok, output} ->
            %{
              "status" => "observed",
              "source" => "system",
              "path" => path,
              "version" => String.slice(String.trim(output), 0, 240),
              "version_observed_at_ms" => System.system_time(:millisecond),
              "selection_evidence" => "prepared adapter launch names this exact vendor CLI"
            }

          {:error, {:exit, code, output}} ->
            %{
              "status" => "unprobeable",
              "source" => "system",
              "path" => path,
              "reason" =>
                "version command exited #{code}: #{output |> String.trim() |> String.slice(0, 160)}"
            }

          {:error, reason} ->
            %{
              "status" => "unavailable",
              "source" => "system",
              "path" => path,
              "reason" => safe_reason(reason)
            }
        end

      :unknown ->
        %{
          "status" => "unknown",
          "source" => "unknown",
          "reason" => "prepared adapter launch does not expose the exact vendor CLI executable"
        }
    end
  rescue
    error -> %{"status" => "unavailable", "source" => "unknown", "reason" => safe_reason(error)}
  catch
    kind, reason ->
      %{"status" => "unavailable", "source" => "unknown", "reason" => safe_reason({kind, reason})}
  end

  defp selected_vendor_executable(capture, launch_plan) when is_list(launch_plan) do
    case Keyword.get(launch_plan, :cmd) do
      [path | _] when is_binary(path) ->
        if Path.type(path) == :absolute and Path.basename(path) == capture["binary_name"] do
          {:ok, path}
        else
          :unknown
        end

      _ ->
        :unknown
    end
  end

  defp selected_vendor_executable(_capture, _launch_plan), do: :unknown

  @doc "A read-only per-row formatter shared by `mix tightbeam.doctor`."
  def format_human(%{"rows" => rows}) when is_list(rows) do
    rows
    |> Enum.flat_map(fn row ->
      prefix = "harness binary #{row["host"]}/#{row["harness"]}"
      adapter_prefix = "harness adapter #{row["host"]}/#{row["harness"]}"
      adapter = Map.get(row, "adapter", %{})

      running =
        case row["running"] do
          [] ->
            ["  #{prefix} running: not observed"]

          values ->
            Enum.flat_map(values, fn observation ->
              [
                format_adapter(
                  adapter_prefix,
                  "running",
                  observation["adapter"],
                  observation["generation"]
                ),
                format_observation(prefix, "running", observation)
              ]
            end)
        end

      [format_adapter(adapter_prefix, "next launch", adapter)] ++
        running ++
        [format_observation(prefix, "next launch", row["next_launch"])] ++
        Enum.map(row["warnings"], &"  #{prefix} warning: #{&1}")
    end)
    |> Enum.join("\n")
  end

  def format_human(%{"status" => status, "reason" => reason}),
    do: "  #{status}: #{reason}"

  def format_human(_), do: "  unavailable"

  defp format_adapter(prefix, label, adapter, generation \\ nil) do
    adapter = adapter || %{}
    package = Map.get(adapter, "package", "unknown")
    version = Map.get(adapter, "version", "unknown")
    generation = if is_integer(generation), do: " generation #{generation}", else: ""
    "  #{prefix} #{label}#{generation}: #{package} #{version}"
  end

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
    source = capture["selection_rule"]

    case {source, executable(host_config, capture)} do
      {"unknown", _} ->
        %{"status" => "unknown", "source" => "unknown", "reason" => capture["selection_evidence"]}

      {"system", _} ->
        %{
          "status" => "unknown",
          "source" => "unknown",
          "reason" => "adapter-specific system selection was not observed"
        }

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
        "source" => Map.get(capture, "selection_rule", "unknown"),
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
    if snapshot["selection_rule"] in ["bundled_fallback", "unknown"] do
      case remote_override(host_config, path, snapshot["override_name"], opts) do
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
    case module_override_env(Harness.parse!(harness)) do
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

  defp executable(_host_config, %{"selection_rule" => "unknown"}), do: {:error, :unknown}
  defp executable(_host_config, %{"selection_rule" => "unsupported"}), do: {:error, :unsupported}

  defp executable(
         host_config,
         %{
           "selection_rule" => "pinned_override",
           "override_path" => path
         } = capture
       )
       when is_binary(path) and path != "" do
    cond do
      Path.type(path) == :absolute ->
        executable_file(host_config, capture["path_env"], path)

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

  defp executable(
         host_config,
         %{"selection_rule" => "bundled_fallback", "bundle_probe_script" => script} = capture
       ) do
    node_bundle(host_config, capture, script)
  end

  defp executable(_host_config, _capture), do: {:error, :unsupported}

  defp executable_file(host_config, path_env, path) do
    command = "test -x " <> Tightbeam.Harness.Support.shell_quote(path)

    case run_host(host_config, path_env, ["sh", "-c", command]) do
      {:ok, _output} -> {:ok, [path]}
      {:error, {:exit, _code, _output}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp node_bundle(host_config, capture, script) do
    root = Path.join(capture["base_dir"], "adapters/node_modules")

    case run_host(host_config, capture["path_env"], ["node", "-e", script, root]) do
      {:ok, path} when path != "" -> {:ok, ["node", String.trim(path)]}
      {:ok, _} -> {:error, :not_found}
      {:error, {:exit, 2, _output}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
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

  defp remote_override(%{ssh: ssh}, path, name, opts) do
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
    case module_override_env(module) do
      nil -> %{}
      name -> %{name => System.get_env(name)}
    end
  end

  defp module_override_env(module) do
    if function_exported?(module, :binary_provenance_override_env, 0),
      do: module.binary_provenance_override_env(),
      else: nil
  end

  defp bundle_probe_script(module) do
    if function_exported?(module, :binary_provenance_bundle_probe_script, 0),
      do: module.binary_provenance_bundle_probe_script(),
      else: nil
  end

  defp module_default_source(module) do
    if function_exported?(module, :binary_provenance_default_source, 0),
      do: module.binary_provenance_default_source(),
      else: nil
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
