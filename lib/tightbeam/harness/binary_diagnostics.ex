defmodule Tightbeam.Harness.BinaryDiagnostics do
  @moduledoc false

  alias Tightbeam.{AdapterCoordinator, DB, Placement}
  alias Tightbeam.Harness.Support

  @probe_timeout_ms 3_000
  @target_timeout_ms 3_500
  @report_timeout_ms 8_000
  @gateway_timeout_ms 9_000
  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=2"]
  @boundary "A failed gateway read cannot establish which binary a running adapter selected."
  @running_boundary "This is a separate bounded selection/version probe; it does not inspect or fingerprint the vendor child started by the adapter."
  @running_query_boundary "This reports whether the adapter coordinator could return its ready-generation list."

  @doc "Read-only vendor CLI provenance for configured hosts and ready adapter generations."
  def report(base_dir, db \\ DB, coordinator \\ AdapterCoordinator, opts \\ []) do
    hosts = Placement.hosts(base_dir, db) |> Enum.sort_by(&elem(&1, 0))
    running_snapshot = running_snapshot(coordinator)
    launches = running_snapshot["launches"]
    config = %{base_dir: base_dir, cli_bin: Path.join(base_dir, "bin"), db: db}
    modules = diagnostic_harnesses()

    targets =
      for {host, host_config} <- hosts,
          module <- modules do
        path = Placement.toolchain_path_preview(config, host)

        target = %{
          base_dir: host_config.base_dir,
          host_config: host_config,
          host_name: host,
          adapter_path: path,
          sh: Keyword.get(opts, :run, &Support.system_cmd_out/1)
        }

        {host, module, target, configured_override(db, host, host_config, module)}
      end

    selections = collect_targets(targets, opts)

    rows =
      Enum.map(targets, fn {host, module, _target, _override} ->
        supported? = supported_module?(module)

        selection =
          Map.get(
            selections,
            {host, module.wire_name()},
            unknown("probe exceeded the bounded report window")
          )

        running = running_for(launches, host, module.wire_name(), supported?)

        %{
          "host" => host,
          "harness" => module.wire_name(),
          "adapter" => adapter_identity(module),
          "running_observation" => Map.drop(running_snapshot, ["launches"]),
          "running" => running,
          "next_launch" => if(supported?, do: selection, else: unsupported_selection()),
          "warnings" =>
            row_warnings(running, if(supported?, do: selection, else: unsupported_selection()))
        }
      end)
      |> add_version_warnings()

    {:ok, %{"status" => "observed", "rows" => rows}}
  rescue
    error -> {:ok, unavailable(safe_reason(error))}
  catch
    kind, reason -> {:ok, unavailable(safe_reason({kind, reason}))}
  end

  @doc "Capture one launch's effective selection without changing its environment or resolution."
  def launch_capture(module, target, overlay_env) do
    if supported_module?(module) do
      env_name = module.binary_cli_env_name()

      override =
        case Enum.find(overlay_env, fn {name, _value} -> name == env_name end) do
          {_name, value} -> {:known, nonempty(value)}
          nil when is_nil(target.host_config.ssh) -> {:known, nonempty(System.get_env(env_name))}
          nil -> {:remote_environment, env_name}
        end

      fn ->
        started_at_ms = System.system_time(:millisecond)
        selection = observe(module, target, override)
        completed_at_ms = System.system_time(:millisecond)

        %{
          "selection" => selection,
          "adapter" => adapter_identity(module),
          "observation_started_at_ms" => started_at_ms,
          "observation_completed_at_ms" => completed_at_ms,
          "evidence_boundary" => @running_boundary
        }
      end
    end
  rescue
    _ -> nil
  end

  @doc false
  def observe(module, target, override, opts \\ []) do
    if not supported_module?(module) do
      unsupported_selection()
    else
      {mode, pin, source, remote_env_name} = selection_request(override)

      outcome =
        case Keyword.get(opts, :probe) do
          probe when is_function(probe, 4) -> probe.(module, target, mode, pin)
          _ -> run_probe(module, target, mode, pin, remote_env_name, opts)
        end

      case outcome do
        {:ok, path, version, observed_source} ->
          selection(observed_source || source, path, version)

        {:ok, path, version} ->
          selection(source, path, version)

        {:error, status, reason, observed_source} ->
          selection_error(observed_source || source, status, pin, reason)

        {:error, status, reason} ->
          selection_error(source, status, pin, reason)
      end
    end
  rescue
    error ->
      unknown("selection could not be observed for #{module.wire_name()}: #{safe_reason(error)}")
  catch
    kind, reason ->
      unknown(
        "selection could not be observed for #{module.wire_name()}: #{safe_reason({kind, reason})}"
      )
  end

  @doc false
  def collect_targets(targets, opts \\ []) do
    target_timeout = Keyword.get(opts, :target_timeout_ms, @target_timeout_ms)
    report_timeout = Keyword.get(opts, :report_timeout_ms, @report_timeout_ms)

    task =
      Task.async(fn ->
        Task.async_stream(
          targets,
          fn {host, module, target, override} ->
            {{host, module.wire_name()}, observe(module, target, override, opts)}
          end,
          max_concurrency: Keyword.get(opts, :max_concurrency, 8),
          timeout: target_timeout,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Stream.zip(targets)
        |> Enum.reduce(%{}, fn
          {{:ok, {key, selection}}, _target}, acc ->
            Map.put(acc, key, selection)

          {{:exit, :timeout}, {host, module, _target, _override}}, acc ->
            key = {host, module.wire_name()}

            Map.put(
              acc,
              key,
              unknown("selection probe exceeded the per-host #{target_timeout}ms bound")
            )

          {{:exit, reason}, {host, module, _target, _override}}, acc ->
            key = {host, module.wire_name()}

            Map.put(acc, key, unknown("selection probe failed: #{safe_reason(reason)}"))
        end)
      end)

    case Task.yield(task, report_timeout) do
      {:ok, rows} ->
        rows

      _ ->
        Task.shutdown(task, :brutal_kill)

        Map.new(targets, fn {host, module, _target, _override} ->
          {{host, module.wire_name()},
           unknown("selection probe exceeded the global #{report_timeout}ms report bound")}
        end)
    end
  end

  @doc false
  def selection(source, path, version)
      when source in ["system", "pinned_override", "bundled_fallback"] and is_binary(path) and
             path != "" and is_binary(version) and version != "" do
    %{
      "status" => "observed",
      "source" => source,
      "path" => sanitize(path),
      "version" => sanitize(version)
    }
  end

  def selection(_source, _path, _version), do: unknown("selection evidence was incomplete")

  @doc false
  def selection_request({:remote_environment, env_name}) when is_binary(env_name),
    do: {"remote", nil, "unknown", env_name}

  def selection_request({:known, override}) do
    pin = nonempty(override)

    {if(pin, do: "pinned", else: "bundled"), pin,
     if(pin, do: "pinned_override", else: "bundled_fallback"), nil}
  end

  def selection_request(override) do
    selection_request({:known, override})
  end

  @doc false
  def warnings_for(selection), do: selection_warnings(selection, "selection probe")

  @doc false
  def warnings_for_row(running, next_launch), do: row_warnings(running, next_launch)

  @doc false
  def diagnostic_harnesses do
    Tightbeam.Harness.all() |> Enum.sort_by(& &1.wire_name())
  end

  @doc false
  def version_warnings(rows, field \\ "next_launch") do
    rows
    |> Enum.group_by(& &1["harness"])
    |> Enum.flat_map(fn {harness, harness_rows} ->
      host_versions =
        Enum.flat_map(harness_rows, fn row ->
          versions = field_versions(row, field) |> Enum.uniq() |> Enum.sort()
          if versions == [], do: [], else: [{row["host"], versions}]
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {host, version_sets} ->
          {host, version_sets |> List.flatten() |> Enum.uniq() |> Enum.sort()}
        end)

      if map_size(host_versions) > 1 and length(Enum.uniq(Map.values(host_versions))) > 1 do
        detail =
          host_versions
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map_join(", ", fn {host, versions} -> "#{host}=#{Enum.join(versions, "/")}" end)

        ["#{harness} #{String.replace(field, "_", " ")} versions differ across hosts: #{detail}"]
      else
        []
      end
    end)
  end

  @doc false
  def human(report) do
    case report do
      %{"status" => "unavailable"} ->
        [
          "harness binary diagnostics unavailable: #{report["reason"] || "unknown reason"}; " <>
            (report["boundary"] || @boundary)
        ]

      %{"rows" => rows} ->
        Enum.flat_map(rows, fn row ->
          adapter = row["adapter"] || %{}
          prefix = "harness binary #{row["harness"]} on #{row["host"]}"

          running = render_running(row, prefix)

          [
            "#{prefix}: adapter #{adapter["package"] || "unknown"} #{adapter["version"] || "unknown"}",
            "#{prefix}: next launch #{render_selection(row["next_launch"])}"
          ] ++ running ++ Enum.map(row["warnings"] || [], &"#{prefix}: warning: #{&1}")
        end)

      _ ->
        ["harness binary diagnostics unknown; #{@boundary}"]
    end
  end

  @doc false
  def running_snapshot(coordinator, opts \\ []) do
    fetch = Keyword.get(opts, :fetch, &AdapterCoordinator.binary_launches/1)

    try do
      case fetch.(coordinator) do
        launches when is_list(launches) ->
          %{
            "status" => "observed",
            "launches" => launches,
            "boundary" => @running_query_boundary
          }

        other ->
          %{
            "status" => "unavailable",
            "reason" =>
              "coordinator returned an invalid ready-generation result: #{safe_reason(other)}",
            "launches" => [],
            "boundary" => @running_query_boundary
          }
      end
    rescue
      error -> running_snapshot_failure(safe_reason(error))
    catch
      kind, reason -> running_snapshot_failure(safe_reason({kind, reason}))
    end
  end

  @doc false
  def unavailable(reason) do
    %{
      "status" => "unavailable",
      "reason" => sanitize(reason),
      "boundary" => @boundary,
      "rows" => []
    }
  end

  @doc "Fetch the gateway's doctor projection for Mix doctor; a fetch failure keeps its evidence boundary."
  def fetch_gateway(base_dir, opts \\ []) do
    timeout = Keyword.get(opts, :gateway_timeout_ms, @gateway_timeout_ms)

    with {:ok, port, token} <- local_gateway(Path.join(base_dir, "gateway.json")),
         :ok <- ensure_httpc() do
      request =
        :httpc.request(
          :get,
          {String.to_charlist("http://127.0.0.1:#{port}/harnesses?doctor=1"),
           [
             {~c"authorization", String.to_charlist("Bearer " <> token)},
             {~c"x-tightbeam-cli-version",
              String.to_charlist(Tightbeam.CliCompatibility.required_version())}
           ]},
          [connect_timeout: 1_000, timeout: timeout],
          body_format: :binary
        )

      case request do
        {:ok, {{_http, status, _reason}, _headers, body}} when status in 200..299 ->
          case JSON.decode(body) do
            {:ok, %{"binary_diagnostics" => report}} -> report
            _ -> unavailable("gateway diagnostics response was malformed")
          end

        {:ok, {{_http, status, _reason}, _headers, _body}} ->
          unavailable("gateway returned HTTP #{status}")

        {:error, reason} ->
          unavailable(safe_reason(reason))
      end
    else
      {:error, reason} -> unavailable(safe_reason(reason))
    end
  rescue
    error -> unavailable(safe_reason(error))
  catch
    kind, reason -> unavailable(safe_reason({kind, reason}))
  end

  defp run_probe(module, target, mode, pin, remote_env_name, opts) do
    args = [
      "node",
      "-e",
      module.binary_cli_probe_script(),
      Path.join(target.host_config.base_dir, "adapters"),
      mode,
      pin || ""
    ]

    command = probe_command(target, args, remote_env_name)
    runner = Keyword.get(opts, :run, target.sh)

    case Support.bounded_run(
           runner,
           command,
           Keyword.get(opts, :probe_timeout_ms, @probe_timeout_ms)
         ) do
      {:ok, {output, 0}} ->
        decode_probe(output)

      {:ok, {output, exit}} ->
        {:error, classify_exit(exit, output, target), failure_reason(exit, output)}

      {:error, {:timeout, timeout}} ->
        status = if is_nil(target.host_config.ssh), do: "unprobeable", else: "unknown"

        {:error, status,
         "version probe did not finish within #{timeout}ms; target reachability is not established"}

      {:error, reason} ->
        {:error, classify_failure(reason, target), safe_reason(reason)}

      other ->
        {:error, "unknown",
         "version probe returned an unrecognized result: #{safe_reason(other)}"}
    end
  end

  @doc false
  def probe_command(%{host_config: %{ssh: nil}, adapter_path: path}, args, _remote_env_name) do
    ["/usr/bin/env", "-i", "PATH=#{path}" | args]
  end

  def probe_command(
        %{host_config: %{ssh: destination}, adapter_path: path},
        args,
        remote_env_name
      ) do
    path_assignment =
      case String.split(path, "$PATH", parts: 2) do
        [prefix, suffix] ->
          Support.shell_quote(prefix) <> "\"$PATH\"" <> Support.shell_quote(suffix)

        _ ->
          Support.shell_quote(path)
      end

    remote_pin_assignment =
      case remote_env_name do
        name when is_binary(name) ->
          unless Regex.match?(~r/\A[A-Z][A-Z0-9_]*\z/, name),
            do: raise(ArgumentError, "invalid remote selection variable")

          "TIGHTBEAM_DIAGNOSTIC_PIN=\"${" <> name <> "-}\"; export TIGHTBEAM_DIAGNOSTIC_PIN; "

        nil ->
          ""
      end

    remote_pin_env =
      if is_binary(remote_env_name),
        do: " TIGHTBEAM_DIAGNOSTIC_PIN=\"$TIGHTBEAM_DIAGNOSTIC_PIN\"",
        else: ""

    script =
      "PATH=" <>
        path_assignment <>
        "; export PATH; " <>
        remote_pin_assignment <>
        "exec /usr/bin/env -i PATH=\"$PATH\"" <>
        remote_pin_env <>
        " " <>
        Enum.map_join(args, " ", &Support.shell_quote/1)

    ["ssh" | @ssh_opts] ++ [destination, "/bin/sh", "-c", Support.shell_quote(script)]
  end

  defp decode_probe(output) do
    case JSON.decode(String.trim(output)) do
      {:ok,
       %{
         "status" => "observed",
         "path" => path,
         "version" => version,
         "source" => source
       }}
      when is_binary(path) and path != "" and is_binary(version) and version != "" ->
        {:ok, path, version, source}

      {:ok, %{"status" => status, "reason" => reason} = result}
      when status in ["missing", "unprobeable"] ->
        {:error, status, reason, result["source"]}

      {:ok, _} ->
        {:error, "unknown", "version probe returned incomplete selection data"}

      {:error, reason} ->
        {:error, "unknown", "version probe output was not valid JSON: #{safe_reason(reason)}"}
    end
  end

  defp classify_exit(127, _output, _target), do: "missing"
  defp classify_exit(126, _output, _target), do: "unprobeable"

  defp classify_exit(255, output, %{host_config: %{ssh: destination}})
       when not is_nil(destination),
       do: if(unreachable?(output), do: "unreachable", else: "unknown")

  defp classify_exit(_exit, _output, _target), do: "unprobeable"

  defp classify_failure(reason, %{host_config: %{ssh: destination}})
       when not is_nil(destination) do
    if unreachable?(reason), do: "unreachable", else: "unknown"
  end

  defp classify_failure(_reason, _target), do: "unknown"

  defp failure_reason(exit, output) do
    detail = sanitize(output)

    if detail == "",
      do: "version command exited #{exit}",
      else: "version command failed: #{detail}"
  end

  defp configured_override(db, host, host_config, module) do
    if supported_module?(module) do
      name = module.binary_cli_env_name()

      case Enum.find(Placement.env_overlays(db, host, module.wire_name()), fn overlay ->
             overlay.name == name
           end) do
        %{value: value} -> {:known, nonempty(value)}
        nil when is_nil(host_config.ssh) -> {:known, nonempty(System.get_env(name))}
        nil -> {:remote_environment, name}
      end
    else
      :unsupported
    end
  end

  defp running_for(launches, host, harness, supported?) do
    launches
    |> Enum.filter(&(&1["host"] == host and &1["harness"] == harness and &1["ready"]))
    |> Enum.map(fn launch ->
      running_projection(launch, supported?)
    end)
  end

  @doc false
  def running_projection(launch, supported? \\ true) do
    capture = launch["capture"] || %{}

    %{
      "generation" => launch["generation"],
      "adapter_generation_started_at_ms" => launch["adapter_generation_started_at_ms"],
      "adapter" => capture["adapter"],
      "vendor_cli_child" => vendor_cli_child(supported?),
      "selection_observation" =>
        if(supported?, do: running_selection(launch), else: unsupported_selection()),
      "selection_observation_started_at_ms" => capture["observation_started_at_ms"],
      "selection_observation_completed_at_ms" => capture["observation_completed_at_ms"],
      "evidence_boundary" => capture["evidence_boundary"] || @running_boundary
    }
  end

  @doc false
  def running_selection(launch) do
    case {launch["capture"], launch["capture_pending"]} do
      {%{"selection" => %{} = selection}, _pending} -> selection
      {_capture, true} -> unknown("running adapter generation selection probe is pending")
      _ -> stale("running adapter generation predates selection capture")
    end
  end

  defp adapter_identity(module) do
    %{
      "package" => optional_module_value(module, :install_package),
      "version" => optional_module_value(module, :adapter_version)
    }
  end

  defp optional_module_value(module, function) do
    if function_exported?(module, function, 0), do: apply(module, function, []), else: "unknown"
  end

  defp selection_warnings(%{"source" => "bundled_fallback", "status" => "observed"}, label) do
    [
      "#{label} observed the bundled CLI; no automatic host-first resolver is configured"
    ]
  end

  defp selection_warnings(_selection, _label), do: []

  defp row_warnings(running, next_launch) do
    selection_warnings(next_launch, "next-launch selection probe") ++
      Enum.flat_map(running, fn launch ->
        selection_warnings(
          launch["selection_observation"],
          "running generation #{launch["generation"] || "?"} launch selection probe"
        )
      end)
  end

  defp add_version_warnings(rows) do
    (version_warnings(rows) ++ version_warnings(rows, "running_selection_probe"))
    |> Enum.reduce(rows, fn warning, acc ->
      harness = warning |> String.split(" ") |> hd()

      Enum.map(acc, fn row ->
        if row["harness"] == harness,
          do: %{row | "warnings" => Enum.uniq((row["warnings"] || []) ++ [warning])},
          else: row
      end)
    end)
  end

  defp field_versions(row, "running_selection_probe") do
    Enum.flat_map(row["running"] || [], fn launch ->
      case get_in(launch, ["selection_observation", "status"]) do
        "observed" -> [get_in(launch, ["selection_observation", "version"])]
        _ -> []
      end
    end)
  end

  defp field_versions(row, "next_launch") do
    case row["next_launch"] do
      %{"status" => "observed", "version" => version} -> [version]
      _ -> []
    end
  end

  defp render_selection(%{"status" => "observed"} = selection) do
    "#{selection["source"]} #{selection["path"]} version #{selection["version"]}"
  end

  defp render_selection(%{"status" => status, "source" => source, "reason" => reason}),
    do: "#{status} (#{source}; #{reason})"

  defp render_selection(%{"status" => status, "reason" => reason}), do: "#{status} (#{reason})"
  defp render_selection(_), do: "unknown"

  defp render_running(row, prefix) do
    observation = row["running_observation"] || %{}

    case observation["status"] do
      "unavailable" ->
        [
          "#{prefix}: running generation query unavailable (#{observation["reason"] || "unknown reason"}); " <>
            (observation["boundary"] || @running_query_boundary)
        ]

      _ ->
        case row["running"] || [] do
          [] -> ["#{prefix}: running adapter not observed"]
          launches -> Enum.map(launches, &render_running_launch(prefix, &1))
        end
    end
  end

  defp render_running_launch(prefix, launch) do
    generation = launch["generation"] || "?"
    adapter = launch["adapter"] || %{}

    adapter_text =
      case {adapter["package"], adapter["version"]} do
        {package, version} when is_binary(package) and is_binary(version) ->
          "#{package} #{version}; "

        _ ->
          ""
      end

    started = format_timestamp(launch["selection_observation_started_at_ms"])
    completed = format_timestamp(launch["selection_observation_completed_at_ms"])
    generation_started = format_timestamp(launch["adapter_generation_started_at_ms"])
    child_started = format_timestamp(get_in(launch, ["vendor_cli_child", "started_at_ms"]))

    child = render_selection(launch["vendor_cli_child"])

    "#{prefix}: running generation #{generation}: adapter #{adapter_text}vendor CLI child " <>
      "#{child} (start time #{child_started}); adapter generation started at #{generation_started}; " <>
      "launch selection probe observed #{render_selection(launch["selection_observation"])} " <>
      "from #{started} to #{completed}; " <>
      (launch["evidence_boundary"] || @running_boundary)
  end

  defp format_timestamp(value) when is_integer(value) do
    "#{value}ms since Unix epoch"
  end

  defp format_timestamp(_), do: "unknown time"

  defp supported_module?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :binary_cli_env_name, 0) and
      function_exported?(module, :binary_cli_probe_script, 0)
  end

  defp unsupported_selection do
    %{
      "status" => "unsupported",
      "source" => "unknown",
      "reason" => "this enabled harness adapter does not expose vendor CLI selection diagnostics"
    }
  end

  defp vendor_cli_child(true) do
    %{
      "status" => "unknown",
      "source" => "unknown",
      "started_at_ms" => nil,
      "reason" =>
        "the independent selection probe does not inspect the vendor child started by this generation"
    }
  end

  defp vendor_cli_child(false) do
    %{
      "status" => "unsupported",
      "source" => "unknown",
      "started_at_ms" => nil,
      "reason" => "this enabled harness adapter does not expose vendor CLI child diagnostics"
    }
  end

  defp selection_error(source, status, pin, reason) do
    %{
      "status" => status,
      "source" => source || "unknown",
      "path" => pin,
      "reason" => sanitize(reason)
    }
  end

  defp running_snapshot_failure(reason) do
    %{
      "status" => "unavailable",
      "reason" => sanitize(reason),
      "launches" => [],
      "boundary" => @running_query_boundary
    }
  end

  defp ensure_httpc do
    case :inets.start() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_gateway(path) do
    with {:ok, encoded} <- File.read(path),
         {:ok, %{"port" => port, "cliToken" => token}}
         when is_integer(port) and is_binary(token) and token != "" <- JSON.decode(encoded) do
      {:ok, port, token}
    else
      {:ok, _} -> {:error, "gateway configuration was malformed"}
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  defp nonempty(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp nonempty(_), do: nil

  defp unknown(reason),
    do: %{"status" => "unknown", "source" => "unknown", "reason" => sanitize(reason)}

  defp stale(reason),
    do: %{"status" => "stale", "source" => "unknown", "reason" => sanitize(reason)}

  defp unreachable?(reason) do
    reason
    |> safe_reason()
    |> String.downcase()
    |> String.contains?([
      "timed out",
      "connection refused",
      "could not resolve",
      "no route to host"
    ])
  end

  defp safe_reason(reason), do: reason |> inspect(limit: 5, printable_limit: 160) |> sanitize()

  defp sanitize(value) when is_binary(value),
    do: value |> String.replace(~r/[\r\n\t]+/, " ") |> String.slice(0, 180)

  defp sanitize(value), do: value |> to_string() |> sanitize()
end
