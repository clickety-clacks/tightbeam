defmodule Tightbeam.Spinup do
  @moduledoc """
  Live host readiness at placement time.

  Each call asks the target machine directly, idempotently ensures the
  org-owned directories and remote adapters, detects credentials without
  changing them, and records the result as lifecycle history.
  """

  alias Tightbeam.{EventLog, Harness, Homes, Placement}
  alias Tightbeam.Harness.Support

  @type denial :: %{code: String.t(), message: String.t()}

  @spec ensure_ready(map(), atom(), String.t(), keyword()) ::
          :ok | {:error, denial()}
  def ensure_ready(config, harness, host_name, opts \\ []) do
    db = Keyword.get(opts, :db, Tightbeam.DB)
    sh = Keyword.get(opts, :sh, &system_cmd/1)
    module = Harness.module!(harness)

    {result, detail} =
      case Map.fetch(Placement.hosts(config.base_dir), host_name) do
        :error ->
          denial = %{code: "unknown_host", message: "host #{host_name} is not configured"}
          {{:error, denial}, "DENIED: #{denial.message}"}

        {:ok, host} ->
          target = %{
            base_dir: config.base_dir,
            host_config: host,
            host_name: host_name,
            sh: sh
          }

          target =
            case Keyword.fetch(opts, :patch_adapter) do
              {:ok, patch} -> Map.put(target, :patch_adapter, &patch.(module.id(), &1))
              :error -> target
            end

          ensure_host(target, module)
      end

    :ok = EventLog.lifecycle(db, "spinup", "#{harness}@#{host_name}", detail)
    result
  end

  @doc false
  def ensure_adapter(target, module, path) do
    if Support.local?(target) do
      if File.exists?(path) do
        target.patch_adapter.(path)
        {:ok, "adapters present"}
      else
        # STOPPED SHORT OF SELF-PROVISIONING (#46): priv/harness_bundle.json
        # declares vector_contract.ensure_adapter with the oracle "local absence
        # refusal" and a required `local_absent` case, so installing here would
        # contradict a manifest-declared parity contract. That needs an amendment,
        # not a lane decision. What IS fixed is the path: the adapter is looked for
        # under this host's OWN base_dir, not a sibling checkout of the retired
        # TypeScript project, and the remedy now names the directory that matters.
        message =
          "host #{target.host_name} is not ready for #{module.wire_name()}: adapter missing at #{path} " <>
            "(install the ACP adapters into #{Path.join(target.host_config.base_dir, "adapters")} " <>
            "on #{target.host_name})"

        {:error, host_unready(message)}
      end
    else
      check = remote_command(target.host_config.ssh, "test -x #{shell_quote(path)}")

      case target.sh.(check) do
        {_output, 0} ->
          target.remote_patch.(path, "adapters present")

        {_output, _exit} ->
          install_dir = Path.join(target.host_config.base_dir, "adapters")

          # `name@version`, not a bare name: npm resolves a bare name to LATEST, so
          # every provision pulled whatever was published that day while
          # @adapter_version documented a pin nothing enforced. Measured before this
          # change, BOTH adapters had drifted past their pins. The patch anchors and
          # the local patcher's exact-version assertion are written against the
          # pinned release, so the install has to land that release — an unpinned
          # tree makes the patcher raise. Versions stay in the harness modules; this
          # seam only asks each of them for its own.
          packages =
            Enum.map_join(Harness.all(), " ", &"#{&1.install_package()}@#{&1.adapter_version()}")

          install =
            "npm install --prefix #{shell_quote(install_dir)} " <> packages

          case target.sh.(remote_command(target.host_config.ssh, install)) do
            {_output, 0} ->
              case target.sh.(check) do
                {_output, 0} ->
                  target.remote_patch.(path, "deployed adapters")

                {output, _exit} ->
                  {:error,
                   host_unready(
                     "host #{target.host_name} is not ready for #{module.wire_name()}: adapter still missing at #{path} after deployment: #{String.trim(output)}" <>
                       " (reinstall the ACP adapters on #{target.host_name}, then verify the ACP adapter installation on #{target.host_name} produced an executable at #{path})"
                   )}
              end

            {output, _exit} ->
              {:error,
               host_unready(
                 "host #{target.host_name} is not ready for #{module.wire_name()}: adapter deployment failed: #{String.trim(output)}" <>
                   " " <>
                   adapter_deployment_remedy(
                     output,
                     install_dir,
                     target.host_name
                   )
               )}
          end
      end
    end
  end

  defp ensure_host(target, module) do
    host = target.host_config

    reachability =
      if Support.local?(target) do
        {:ok, ""}
      else
        case target.sh.(["ssh" | Support.ssh_opts()] ++ [host.ssh, "true"]) do
          {_output, 0} -> {:ok, ""}
          {output, _exit} -> {:error, String.trim(output)}
        end
      end

    case reachability do
      {:ok, _} ->
        dirs = [
          Tightbeam.Credentials.store_dir(host.base_dir, module.credential_provider()),
          Path.join(host.base_dir, "work"),
          Path.join(host.base_dir, "homes")
        ]

        dirs_result =
          if Support.local?(target) do
            Enum.reduce_while(dirs, :ok, fn path, :ok ->
              case File.mkdir_p(path) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, path, reason}}
              end
            end)
          else
            script = "mkdir -p " <> Enum.map_join(dirs, " ", &shell_quote/1)

            case target.sh.(remote_command(host.ssh, script)) do
              {_output, 0} -> :ok
              {output, _exit} -> {:error, nil, String.trim(output)}
            end
          end

        case dirs_result do
          {:error, path, reason} when is_binary(path) ->
            location = if path, do: " at #{path}", else: ""

            message =
              "host #{target.host_name} is not ready for #{module.wire_name()}: directory setup failed#{location}: #{:file.format_error(reason)} " <>
                local_directory_remedy(reason, path, target.host_name)

            {{:error, host_unready(message)}, "reached; DENIED: #{message}"}

          {:error, nil, reason} ->
            message =
              "host #{target.host_name} is not ready for #{module.wire_name()}: directory setup failed: #{reason} " <>
                remote_directory_remedy(reason, host.base_dir, target.host_name)

            {{:error, host_unready(message)}, "reached; DENIED: #{message}"}

          :ok ->
            home = Homes.home_path(host.base_dir, target.host_name, module.id())

            case module.ensure_adapter(target) do
              {:error, denial} ->
                {{:error, denial}, "reached; directories ensured; DENIED: #{denial.message}"}

              {:ok, adapter_detail} ->
                if module.credential_ready?(target, home) do
                  {:ok, "reached; directories ensured; #{adapter_detail}; credentials present"}
                else
                  auth_dir =
                    Tightbeam.Credentials.store_dir(
                      host.base_dir,
                      module.credential_provider()
                    )

                  message =
                    "host #{target.host_name} is not ready for #{module.wire_name()}: no #{module.wire_name()} credentials in #{auth_dir} " <>
                      "(run the setup ceremony on #{target.host_name})"

                  {{:error, host_unready(message)},
                   "reached; directories ensured; #{adapter_detail}; DENIED: #{message}"}
                end
            end
        end

      {:error, output} ->
        message =
          "host #{target.host_name} is unreachable: #{output} " <>
            ssh_remedy(output, target.host_name)

        {{:error, host_unready(message)}, "DENIED: #{message}"}
    end
  end

  defp remote_command(destination, script) do
    ["ssh" | Support.ssh_opts()] ++ [destination, "sh", "-c", shell_quote(script)]
  end

  defp ssh_remedy(output, host_name) do
    output = String.downcase(output)

    cond do
      String.contains?(output, "connection refused") ->
        "(start or restore the SSH service for #{host_name}, then check SSH access to #{host_name})"

      String.contains?(output, "permission denied") or String.contains?(output, "publickey") ->
        "(authorize the gateway's SSH key on #{host_name}, then check SSH access to #{host_name})"

      String.contains?(output, "could not resolve") or
          String.contains?(output, "name or service not known") ->
        "(correct the SSH destination or DNS for #{host_name}, then check SSH access to #{host_name})"

      String.contains?(output, "no route to host") or String.contains?(output, "timed out") or
          String.contains?(output, "timeout") ->
        "(restore network reachability to #{host_name}, then check SSH access to #{host_name})"

      true ->
        "(restore non-interactive SSH access to #{host_name}, then check SSH access to #{host_name})"
    end
  end

  defp local_directory_remedy(reason, path, host_name) when reason in [:eacces, :eperm] do
    "(grant the Tightbeam process search and write permission for #{path} on #{host_name})"
  end

  defp local_directory_remedy(:enospc, path, host_name) do
    "(free disk space on #{host_name}, then retry creating #{path})"
  end

  defp local_directory_remedy(:enotdir, path, host_name) do
    "(remove or rename the non-directory component blocking #{path} on #{host_name}; fix directory permissions on #{host_name} only if the replacement still lacks write access)"
  end

  defp local_directory_remedy(reason, path, host_name) do
    "(resolve the #{:file.format_error(reason)} filesystem condition at #{path} on #{host_name}, then retry placement)"
  end

  defp remote_directory_remedy(output, base_dir, host_name) do
    output = String.downcase(output)

    cond do
      String.contains?(output, "permission denied") ->
        "(fix directory permissions on #{host_name} so Tightbeam can create directories under #{base_dir}, then retry placement)"

      String.contains?(output, "not a directory") ->
        "(remove or rename the non-directory component blocking #{base_dir} on #{host_name}, then retry placement)"

      String.contains?(output, "no space left") ->
        "(free disk space on #{host_name}, then retry creating directories under #{base_dir})"

      String.contains?(output, "read-only file system") ->
        "(make the filesystem containing #{base_dir} writable on #{host_name}, then retry placement)"

      true ->
        "(correct the reported mkdir failure under #{base_dir} on #{host_name}, then retry placement)"
    end
  end

  defp adapter_deployment_remedy(output, install_dir, host_name) do
    output = String.downcase(output)

    cond do
      String.contains?(output, "command not found") ->
        "(install Node.js/npm and the ACP adapters on #{host_name})"

      String.contains?(output, "permission denied") or String.contains?(output, "eacces") ->
        "(grant npm write access to #{install_dir} on #{host_name}, then rerun the ACP adapter installation)"

      String.contains?(output, "no space left") or String.contains?(output, "enospc") ->
        "(free disk space on #{host_name}, then rerun the ACP adapter installation)"

      String.contains?(output, "network") or String.contains?(output, "econn") or
          String.contains?(output, "enotfound") ->
        "(restore npm registry access on #{host_name}, then rerun the ACP adapter installation)"

      true ->
        "(correct the reported npm failure in #{install_dir} on #{host_name}, then rerun the ACP adapter installation)"
    end
  end

  defp host_unready(message), do: %{code: "host_unready", message: message}

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp system_cmd([command | args]), do: System.cmd(command, args, stderr_to_stdout: true)
end
