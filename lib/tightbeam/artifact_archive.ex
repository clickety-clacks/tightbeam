defmodule Tightbeam.ArtifactArchive do
  @moduledoc false

  alias Tightbeam.{Placement, WorkspaceCleanup}
  alias Tightbeam.Harness.Support

  def read(db, row, config) do
    base_dir = config[:base_dir] || Application.get_env(:tightbeam, :base_dir)
    hosts = Placement.hosts(base_dir, db)

    with true <- Path.type(row.home) == :absolute and not String.contains?(row.home, <<0>>),
         {:ok, host} <- holding_host(hosts, row) do
      read_home(host, row.home, config)
    else
      false -> {:error, :invalid_archive_home}
      error -> error
    end
  end

  defp holding_host(hosts, %{origin_host: name}) when is_binary(name) do
    case hosts[name] || Enum.find_value(hosts, fn {_, h} -> h.ssh == name && h end) do
      nil -> {:error, :archive_host_unknown}
      host -> {:ok, host}
    end
  end

  defp holding_host(hosts, row) do
    # Legacy rows have no origin stamp. An archive prefix can identify the
    # host independently of the recording session's current placement.
    routes =
      for {_, host} <- hosts,
          host.base_dir,
          root <- Enum.uniq([archive_root(host), default_root(host)]),
          String.starts_with?(row.home, root <> "/"),
          do: {byte_size(root), host}

    case Enum.sort_by(routes, &elem(&1, 0), :desc) do
      [{length, _}, {length, _} | _] -> {:error, :archive_host_ambiguous}
      [{_, host} | _] -> {:ok, host}
      [] -> {:error, :archive_host_unknown}
    end
  end

  defp read_home(%{ssh: nil} = host, home, _config) do
    case read_local(home) do
      {:error, :enoent} when is_binary(host.base_dir) ->
        source = default_root(host)
        destination = archive_root(host)

        if destination != source and String.starts_with?(home, source <> "/") do
          read_local(String.replace_prefix(home, source, destination))
        else
          {:error, :enoent}
        end

      result ->
        result
    end
  end

  defp read_home(%{ssh: ssh}, home, config) do
    quoted = Support.shell_quote(home)
    script = "[ -f #{quoted} ] && [ ! -L #{quoted} ] && exec cat #{quoted}"
    command = Support.catalog_probe_argv(ssh, script)
    runner = config[:artifact_archive_runner] || (&Support.system_cmd_out/1)

    case Support.bounded_run(runner, command, 30_000) do
      {:ok, {bytes, 0}} -> {:ok, bytes}
      {:ok, {_, status}} -> {:error, {:remote_archive_read_failed, status}}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_local(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> File.read(path)
      {:ok, _} -> {:error, :archive_home_not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp archive_root(host), do: host |> WorkspaceCleanup.archive_root() |> Path.expand()
  defp default_root(host), do: host.base_dir |> Path.join("archive") |> Path.expand()
end
