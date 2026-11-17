defmodule Tightbeam.AttestFileCheck do
  @moduledoc false

  alias Tightbeam.{ArtifactOrigins, Artifacts, DB, PathNotes, Placement}

  def check(db, config, %{params: %{attest_id: attest_id}}) do
    case DB.query(
           db,
           """
           SELECT a.assignmentId, a.artifactId, a.note, s.host
           FROM attests a LEFT JOIN sessions s ON s.sessionKey=a.bySession
           WHERE a.id=?1
           """,
           [attest_id]
         ) do
      {:ok, [[assignment_id, attached_id, note, filer_host]]} ->
        {:ok, rows} =
          DB.query(
            db,
            """
            SELECT artifactId FROM artifacts
            WHERE producedByAssignmentId=?1 OR artifactId=?2
            ORDER BY artifactId
            """,
            [assignment_id, attached_id]
          )

        files =
          Enum.map(rows, fn [id] ->
            artifact = Artifacts.get(db, id)
            check_artifact(config, artifact)
          end) ++ check_note_paths(db, config, note, filer_host)

        %{attestId: attest_id, files: files, summary: summary(files)}

      {:ok, []} ->
        %{code: "unknown_attest", message: "unknown attest: #{attest_id}"}
    end
  end

  # Absolute paths written in the note: a plain path on the filing session's
  # host, a `host:/path` on that host. Relative and `~/` paths are not checked.
  defp check_note_paths(_db, _config, nil, _filer_host), do: []

  defp check_note_paths(db, config, note, filer_host) do
    hosts = Placement.hosts(config.base_dir, db)

    note
    |> PathNotes.handed_on_paths(Map.keys(hosts), home: false)
    |> Enum.map(fn %{display: display, host: host, path: path} ->
      base = %{notePath: display}

      case host || filer_host do
        nil ->
          Map.merge(base, %{
            checkedPath: path,
            status: "could_not_access",
            error: "this attest was not filed by a session, so it has no host to check on"
          })

        host_name ->
          base
          |> Map.merge(%{checkedHost: host_name, checkedPath: path})
          |> Map.merge(stat_on(hosts, host_name, path, config))
      end
    end)
  end

  defp check_artifact(config, artifact) do
    base = %{artifactId: artifact.artifact_id, originPath: artifact.origin_path}

    case location(artifact, config) do
      {:ok, host_name, path} ->
        base = Map.merge(base, %{checkedHost: host_name, checkedPath: path})

        hosts = Placement.hosts(config.base_dir, config.db)
        Map.merge(base, stat_on(hosts, host_name, path, config))

      {:error, reason} ->
        Map.merge(base, %{status: "could_not_access", error: Atom.to_string(reason)})
    end
  end

  # Archival moves the bytes into the gateway's artifact home. The recorded
  # origin stays as provenance, but is no longer the path to check.
  defp location(%{state: "archived", home: home}, _config) when is_binary(home),
    do: {:ok, Placement.local_host_name(), home}

  defp location(artifact, _config), do: ArtifactOrigins.resolve(artifact)

  defp stat_on(hosts, host_name, path, config) do
    case hosts[host_name] do
      nil -> %{status: "could_not_access", error: "unknown host: #{host_name}"}
      route -> stat(route, path, config)
    end
  end

  @doc """
  Stat one path on a placement host: `%{status: "present" | "absent"}`, or
  `%{status: "could_not_access", error: reason}` with the system error as
  reported. Only ENOENT and ENOTDIR are absence. A `~/` path is the home of the
  user the host is reached as.
  """
  def stat(%{ssh: nil}, path, config),
    do: local_file_result(expand_home(path), Map.get(config, :file_stat, &File.stat/1))

  def stat(%{ssh: destination}, path, config), do: remote_file_result(destination, path, config)

  defp expand_home("~/" <> _ = path), do: Path.expand(path)
  defp expand_home(path), do: path

  defp local_file_result(path, stat) do
    case stat.(path) do
      {:ok, _info} -> %{status: "present"}
      {:error, reason} when reason in [:enoent, :enotdir] -> %{status: "absent"}
      {:error, reason} -> %{status: "could_not_access", error: Atom.to_string(reason)}
    end
  end

  defp remote_file_result(destination, path, config) do
    script = """
    import errno, json, os, sys
    try:
        os.stat(os.path.expanduser(sys.argv[1]))
        print(json.dumps({"status": "present"}))
    except OSError as error:
        status = "absent" if error.errno in (errno.ENOENT, errno.ENOTDIR) else "could_not_access"
        print(json.dumps({"status": status, "error": error.strerror, "errno": error.errno}))
    """

    command = "python3 -c #{quote_shell(script)} #{quote_shell(path)}"
    runner = Map.get(config, :sh, &system_cmd/1)

    case runner.(["ssh", "-o", "BatchMode=yes", destination, command]) do
      {output, 0} ->
        case JSON.decode(output) do
          {:ok, %{"status" => "present"}} ->
            %{status: "present"}

          {:ok, %{"status" => "absent"}} ->
            %{status: "absent"}

          {:ok, %{"status" => "could_not_access", "error" => error}} ->
            %{status: "could_not_access", error: error}

          _ ->
            %{status: "could_not_access", error: output}
        end

      {output, _status} ->
        %{status: "could_not_access", error: output}
    end
  rescue
    error in ErlangError -> %{status: "could_not_access", error: Exception.message(error)}
  end

  defp system_cmd([command | args]), do: System.cmd(command, args, stderr_to_stdout: true)
  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp summary([]), do: "No files recorded on this attest or assignment."

  defp summary(files) do
    absent = Enum.filter(files, &(&1.status == "absent"))
    unreachable = Enum.filter(files, &(&1.status == "could_not_access"))

    if absent == [] and unreachable == [] do
      "All #{length(files)} files are present on disk."
    else
      parts =
        [
          if(absent != [], do: "absent: #{paths(absent)}"),
          if(unreachable != [], do: "could not access: #{paths(unreachable)}")
        ]
        |> Enum.reject(&is_nil/1)

      Enum.join(parts, "; ")
    end
  end

  defp paths(files) do
    Enum.map_join(files, ", ", fn file ->
      case file do
        %{checkedHost: host, checkedPath: path} -> "#{host}:#{path}"
        %{notePath: path} -> path
        _ -> file.originPath
      end
    end)
  end
end
