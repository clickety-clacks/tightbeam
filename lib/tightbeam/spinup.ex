defmodule Tightbeam.Spinup do
  @moduledoc """
  Live host readiness at placement time.

  Each call asks the target machine directly, idempotently ensures the
  org-owned directories and remote adapters, detects credentials without
  changing them, and records the result as lifecycle history.
  """

  require Logger

  alias Tightbeam.{EventLog, Harness, Homes, Placement}
  alias Tightbeam.Harness.Support
  alias Tightbeam.LocalOpenAi.Providers

  @type denial :: %{code: String.t(), message: String.t()}

  @spec ensure_ready(map(), atom(), String.t(), keyword()) ::
          :ok | {:error, denial()}
  def ensure_ready(config, harness, host_name, opts \\ []) do
    db = Keyword.get(opts, :db, Tightbeam.DB)
    sh = Keyword.get(opts, :sh, &system_cmd/1)
    module = Harness.module!(harness)
    credential_provider = Keyword.get(opts, :credential_provider, module.credential_provider())
    credential_names = Keyword.get(opts, :credential_names)

    {result, detail} =
      case Map.fetch(Placement.hosts(config.base_dir, db), host_name) do
        :error ->
          denial = Placement.unknown_host_denial(host_name, module.wire_name())
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

          ensure_host(target, module, credential_provider, credential_names)
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
        provision_adapter(target, module, path, :local)
      end
    else
      check = remote_command(target.host_config.ssh, "test -x #{shell_quote(path)}")

      case target.sh.(check) do
        {_output, 0} ->
          target.remote_patch.(path, "adapters present")

        {_output, _exit} ->
          provision_adapter(target, module, path, {:remote, check})
      end
    end
  end

  # One provisioning mechanism for both localities. The gateway host used to be the only
  # machine that could not supply its own adapters — it refused and told the operator to
  # go install them by hand, on the host tightbeam is standing on. The asymmetry made
  # sense while "local" meant a developer's clone, whose node_modules belong to the
  # developer; it stopped making sense the moment tightbeam became something installed
  # on a machine with a bare base_dir, which is every production host.
  #
  # The two localities differ in exactly two places: how a command reaches the host, and
  # how presence is observed. Everything downstream — the pinned package set, the
  # re-check after installing, the failure remedies — is shared, so a fix to either one
  # cannot drift to only one side.
  defp provision_adapter(target, module, path, locality) do
    # SINGLE-FLIGHT PER HOST (Tightbeam.Spinup.Flight): the adapters dir is
    # shared across harnesses and npm rewrites node_modules while it works —
    # two concurrent provisions interleave in one directory, and either can
    # momentarily unlink a binary the other harness already installed
    # (SMOKE §11 step 43 caught a launch exec'ing into that window).
    Tightbeam.Spinup.Flight.run(target.host_name, fn ->
      provision_adapter_in_flight(target, module, path, locality)
    end)
  end

  defp provision_adapter_in_flight(target, module, path, locality) do
    install_dir = Path.join(target.host_config.base_dir, "adapters")
    command = install_command(target, install_dir, locality)

    # A start line AND a closing line, deliberately: a cold-cache npm install is
    # minutes of silence, and a gateway that says nothing while it runs reads
    # exactly like a broken one (#102). The client-e2e driver's readiness wait
    # also names an open install by these lines.
    Logger.info(
      "installing ACP adapters into #{install_dir} on #{target.host_name} — " <>
        "npm can take minutes on a cold cache"
    )

    case target.sh.(command) do
      {_output, 0} ->
        Logger.info("ACP adapter install into #{install_dir} on #{target.host_name} complete")
        confirm_adapter(target, module, path, locality)

      {output, _exit} ->
        Logger.warning("ACP adapter install into #{install_dir} on #{target.host_name} failed")

        {:error,
         host_unready(
           "host #{target.host_name} is not ready for #{module.wire_name()}: adapter deployment failed: #{String.trim(output)}" <>
             " " <> adapter_deployment_remedy(output, install_dir, target.host_name)
         )}
    end
  end

  # `name@version`, not a bare name: npm resolves a bare name to LATEST, so every
  # provision pulled whatever was published that day while @adapter_version documented a
  # pin nothing enforced. Measured before that change, BOTH adapters had drifted past
  # their pins. The patch anchors and the local patcher's exact-version assertion are
  # written against the pinned release, so the install has to land that release — an
  # unpinned tree makes the patcher raise. Versions stay in the harness modules; this
  # seam only asks each of them for its own.
  defp install_command(target, install_dir, locality) do
    packages =
      Enum.map_join(Harness.all(), " ", &"#{&1.install_package()}@#{&1.adapter_version()}")

    # `--no-save`, because npm records a CARET RANGE for a version it installed
    # exactly: `npm install pkg@1.1.4` writes `"^1.1.4"` into package.json, so the
    # pin held only until the next bare `npm install` in that directory floated it
    # forward. The directory is ours and nothing else installs there, so there is
    # no manifest worth writing — the pin lives in the harness module, and the only
    # record that matters is what is on disk.
    script = "npm install --prefix #{shell_quote(install_dir)} --no-save " <> packages

    case locality do
      :local -> ["sh", "-c", script]
      {:remote, _check} -> remote_command(target.host_config.ssh, script)
    end
  end

  defp confirm_adapter(target, module, path, :local) do
    if File.exists?(path) do
      target.patch_adapter.(path)
      {:ok, "deployed adapters"}
    else
      {:error, host_unready(still_missing(target, module, path, ""))}
    end
  end

  defp confirm_adapter(target, module, path, {:remote, check}) do
    case target.sh.(check) do
      {_output, 0} ->
        target.remote_patch.(path, "deployed adapters")

      {output, _exit} ->
        {:error, host_unready(still_missing(target, module, path, String.trim(output)))}
    end
  end

  defp still_missing(target, module, path, output) do
    "host #{target.host_name} is not ready for #{module.wire_name()}: adapter still missing at #{path} after deployment: #{output}" <>
      " (reinstall the ACP adapters on #{target.host_name}, then verify the ACP adapter installation on #{target.host_name} produced an executable at #{path})"
  end

  defp ensure_host(target, module, credential_provider, credential_names) do
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
          credential_store(host.base_dir, credential_provider),
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
                if credential_ready?(
                     target,
                     module,
                     home,
                     credential_provider,
                     credential_names
                   ) do
                  {:ok, "reached; directories ensured; #{adapter_detail}; credentials present"}
                else
                  auth_dir = credential_store(host.base_dir, credential_provider)

                  message =
                    "host #{target.host_name} is not ready for #{module.wire_name()}: " <>
                      "Tightbeam has no credential for #{credential_provider} on " <>
                      "#{target.host_name}. It does not use or import your normal " <>
                      "#{module.wire_name()} CLI login; Tightbeam keeps its own credential " <>
                      "under #{Path.dirname(auth_dir)}. Run on #{target.host_name}: " <>
                      "tightbeam onboard #{credential_provider} --as-user <userId>"

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

  defp credential_store(base_dir, :local_openai), do: Providers.providers_dir(base_dir)

  defp credential_store(base_dir, provider),
    do: Tightbeam.Credentials.store_dir(base_dir, provider)

  defp credential_ready?(target, _module, _home, provider, names)
       when provider == :local_openai and is_list(names),
       do:
         Homes.credential_ready?(
           target,
           credential_store(target.host_config.base_dir, provider),
           names
         )

  defp credential_ready?(target, module, home, _provider, _names),
    do: module.credential_ready?(target, home)

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
