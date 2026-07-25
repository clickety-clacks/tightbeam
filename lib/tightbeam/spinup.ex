defmodule Tightbeam.Spinup do
  @moduledoc """
  Live host readiness at placement time.

  Each call asks the target machine directly, idempotently ensures the
  org-owned directories and remote adapters, detects credentials without
  changing them, and records the result as lifecycle history.
  """

  alias Tightbeam.{CodexAcpPatch, EventLog, Placement}

  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]

  @type denial :: %{code: String.t(), message: String.t()}

  @spec ensure_ready(map(), :claude | :codex, String.t(), keyword()) ::
          :ok | {:error, denial()}
  def ensure_ready(config, harness, host_name, opts \\ []) do
    db = Keyword.get(opts, :db, Tightbeam.DB)
    sh = Keyword.get(opts, :sh, &system_cmd/1)

    {result, detail} =
      case Map.fetch(Placement.hosts(config.base_dir), host_name) do
        :error ->
          denial = %{code: "unknown_host", message: "host #{host_name} is not configured"}
          {{:error, denial}, "DENIED: #{denial.message}"}

        {:ok, host} ->
          ensure_host(host, harness, host_name, sh)
      end

    :ok = EventLog.lifecycle(db, "spinup", "#{harness}@#{host_name}", detail)
    result
  end

  defp ensure_host(%{ssh: nil} = host, harness, host_name, _sh) do
    with :ok <- ensure_local_dirs(host, harness, host_name),
         :ok <- ensure_local_adapter(host, harness, host_name),
         :ok <- ensure_local_credentials(host, harness, host_name) do
      {:ok, "reached; directories ensured; adapters present; credentials present"}
    else
      {:error, denial, detail} -> {{:error, denial}, detail}
    end
  end

  defp ensure_host(%{ssh: destination} = host, harness, host_name, sh) do
    case sh.(["ssh" | @ssh_opts] ++ [destination, "true"]) do
      {_output, 0} ->
        ensure_remote_host(host, harness, host_name, sh)

      {output, _exit} ->
        message =
          "host #{host_name} is unreachable: #{String.trim(output)} " <>
            ssh_remedy(output, host_name)

        {{:error, host_unready(message)}, "DENIED: #{message}"}
    end
  end

  defp ensure_remote_host(host, harness, host_name, sh) do
    dirs = directories(host.base_dir, harness)
    mkdir_script = "mkdir -p " <> Enum.map_join(dirs, " ", &shell_quote/1)

    case sh.(remote_command(host.ssh, mkdir_script)) do
      {_output, 0} ->
        case ensure_remote_adapter(host, harness, host_name, sh) do
          {:ok, adapter_detail} ->
            case ensure_remote_credentials(host, harness, host_name, sh) do
              :ok ->
                {:ok, "reached; directories ensured; #{adapter_detail}; credentials present"}

              {:error, denial, _detail} ->
                {{:error, denial},
                 "reached; directories ensured; #{adapter_detail}; DENIED: #{denial.message}"}
            end

          {:error, denial, detail} ->
            {{:error, denial}, detail}
        end

      {output, _exit} ->
        message =
          "host #{host_name} is not ready for #{harness}: directory setup failed: #{String.trim(output)} " <>
            remote_directory_remedy(output, host.base_dir, host_name)

        {{:error, host_unready(message)}, "reached; DENIED: #{message}"}
    end
  end

  defp ensure_local_dirs(host, harness, host_name) do
    Enum.reduce_while(directories(host.base_dir, harness), :ok, fn path, :ok ->
      case File.mkdir_p(path) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          message =
            "host #{host_name} is not ready for #{harness}: directory setup failed at #{path}: #{:file.format_error(reason)} " <>
              local_directory_remedy(reason, path, host_name)

          {:halt, {:error, host_unready(message), "reached; DENIED: #{message}"}}
      end
    end)
  end

  defp ensure_local_adapter(host, harness, host_name) do
    path = Placement.adapter_binary_path(harness, host)

    if File.exists?(path) do
      patch_local_adapter(harness, path)
    else
      message =
        "host #{host_name} is not ready for #{harness}: adapter missing at #{path} " <>
          "(install the ACP adapters in the local Tightbeam checkout)"

      {:error, host_unready(message), "reached; directories ensured; DENIED: #{message}"}
    end
  end

  defp ensure_remote_adapter(host, harness, host_name, sh) do
    path = Placement.adapter_binary_path(harness, host)

    case sh.(remote_command(host.ssh, "test -x #{shell_quote(path)}")) do
      {_output, 0} ->
        patch_remote_adapter(host, harness, path, sh, "adapters present")

      {_output, _exit} ->
        install_dir = Path.join(host.base_dir, "adapters")

        install_script =
          "npm install --prefix #{shell_quote(install_dir)} " <>
            "@agentclientprotocol/claude-agent-acp @agentclientprotocol/codex-acp"

        case sh.(remote_command(host.ssh, install_script)) do
          {_output, 0} ->
            case sh.(remote_command(host.ssh, "test -x #{shell_quote(path)}")) do
              {_output, 0} ->
                patch_remote_adapter(host, harness, path, sh, "deployed adapters")

              {output, _exit} ->
                message =
                  "host #{host_name} is not ready for #{harness}: adapter still missing at #{path} after deployment: #{String.trim(output)} " <>
                    "(reinstall the ACP adapters on #{host_name}, then verify the ACP adapter installation on #{host_name} produced an executable at #{path})"

                {:error, host_unready(message),
                 "reached; directories ensured; deployed adapters; DENIED: #{message}"}
            end

          {output, _exit} ->
            message =
              "host #{host_name} is not ready for #{harness}: adapter deployment failed: #{String.trim(output)} " <>
                adapter_deployment_remedy(output, install_dir, host_name)

            {:error, host_unready(message), "reached; directories ensured; DENIED: #{message}"}
        end
    end
  end

  defp patch_local_adapter(:codex, path), do: CodexAcpPatch.ensure!(path)
  defp patch_local_adapter(:claude, _path), do: :ok

  defp patch_remote_adapter(host, :codex, path, sh, detail) do
    script = "node -e #{shell_quote(CodexAcpPatch.remote_script(path))}"

    case sh.(remote_command(host.ssh, script)) do
      {_output, 0} -> {:ok, detail <> "; codex passthrough patched"}
      {output, _exit} -> {:error, host_unready(String.trim(output)), "DENIED: #{output}"}
    end
  end

  defp patch_remote_adapter(_host, :claude, _path, _sh, detail), do: {:ok, detail}

  defp ensure_local_credentials(host, harness, host_name) do
    paths = credential_paths(host.base_dir, harness)

    if Enum.any?(paths, &File.exists?/1) do
      :ok
    else
      missing_credentials(harness, host_name, hd(paths))
    end
  end

  defp ensure_remote_credentials(host, harness, host_name, sh) do
    paths = credential_paths(host.base_dir, harness)
    check_script = Enum.map_join(paths, " || ", &"test -f #{shell_quote(&1)}")

    case sh.(remote_command(host.ssh, check_script)) do
      {_output, 0} -> :ok
      {_output, _exit} -> missing_credentials(harness, host_name, hd(paths))
    end
  end

  defp missing_credentials(harness, host_name, path) do
    message =
      "host #{host_name} is not ready for #{harness}: no #{harness} credentials in #{Path.dirname(path)} " <>
        "(run the setup ceremony on #{host_name})"

    {:error, host_unready(message),
     "reached; directories ensured; adapters present; DENIED: #{message}"}
  end

  defp directories(base_dir, harness) do
    [
      Path.join([base_dir, "auth", Atom.to_string(harness)]),
      Path.join(base_dir, "work"),
      Path.join([base_dir, "homes"])
    ]
  end

  defp credential_paths(base_dir, :claude) do
    [Path.join([base_dir, "auth", "claude", "oauth-token"])]
  end

  defp credential_paths(base_dir, :codex) do
    [Path.join([base_dir, "auth", "codex", "auth.json"])]
  end

  defp remote_command(destination, script) do
    ["ssh" | @ssh_opts] ++ [destination, "sh", "-c", shell_quote(script)]
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
