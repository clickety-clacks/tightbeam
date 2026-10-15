defmodule Tightbeam.WorkspaceCleanup do
  @moduledoc false
  use GenServer
  require Logger

  alias Tightbeam.{ArtifactOrigins, DB, EventLog}
  alias Tightbeam.DB.Txn

  @ssh_opts [
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=5",
    "-o",
    "ServerAliveInterval=5",
    "-o",
    "ServerAliveCountMax=2"
  ]
  @default_runner_timeout_ms 900_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def kick do
    if pid = Process.whereis(__MODULE__), do: send(pid, :drain)
    :ok
  end

  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    timer = Process.send_after(self(), :drain, 30_000)
    {:ok, %{config: config, db: Map.get(config, :db, DB), timer: timer, relocation_done: false}}
  end

  def handle_info(:drain, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    relocation_done = state.relocation_done or relocate_archives(state.config, state.db)

    delay =
      try do
        case DB.query(
               state.db,
               "SELECT sessionKey FROM retired_workspace_cleanup WHERE completed=0 AND nextAt<=?1 ORDER BY nextAt,sessionKey LIMIT 1",
               [System.system_time(:millisecond)]
             ) do
          {:ok, [[key]]} ->
            process_session(state.config, state.db, key)
            1_000

          {:ok, []} ->
            case DB.query(
                   state.db,
                   "SELECT MIN(nextAt) FROM retired_workspace_cleanup WHERE completed=0"
                 ) do
              {:ok, [[at]]} when is_integer(at) ->
                max(at - System.system_time(:millisecond), 1_000)

              _ ->
                nil
            end

          {:error, error} ->
            Logger.warning("workspace cleanup queue unavailable: #{inspect(error)}")
            60_000
        end
      rescue
        error ->
          Logger.warning("workspace cleanup deferred: #{Exception.message(error)}")
          60_000
      catch
        kind, error ->
          Logger.warning("workspace cleanup deferred: #{kind}: #{inspect(error)}")
          60_000
      end

    delay = if relocation_done, do: delay, else: min(delay || 300_000, 300_000)
    timer = if delay, do: Process.send_after(self(), :drain, delay)
    {:noreply, %{state | timer: timer, relocation_done: relocation_done}}
  end

  def archive_root(host),
    do: Application.get_env(:tightbeam, :archive_dir) || Path.join(host.base_dir, "archive")

  defp relocate_archives(config, db) do
    Tightbeam.Placement.hosts(config.base_dir, db)
    |> Enum.map(fn {name, host} ->
      source = Path.join(host.base_dir, "archive")
      destination = archive_root(host)

      if Path.expand(source) == Path.expand(destination) do
        true
      else
        try do
          {:ok, _} =
            DB.query(
              db,
              "INSERT OR IGNORE INTO retired_archive_relocation(host,destination,archivePath) VALUES(?1,?2,?3)",
              [name, destination, Path.join(destination, "previous-" <> archive_name(name))]
            )

          case DB.query(
                 db,
                 "SELECT completed FROM retired_archive_relocation WHERE host=?1 AND destination=?2",
                 [name, destination]
               ) do
            {:ok, [[1]]} -> true
            _ -> relocate_archive(db, name, host, source, destination, config)
          end
        rescue
          error ->
            detail = Exception.message(error)
            Logger.warning("archive relocation deferred #{name}: #{detail}")

            _ =
              DB.query(
                db,
                "UPDATE retired_archive_relocation SET report=?3 WHERE host=?1 AND destination=?2",
                [name, destination, detail]
              )

            false
        catch
          kind, error ->
            detail = "#{kind}: #{inspect(error)}"
            Logger.warning("archive relocation deferred #{name}: #{detail}")

            _ =
              DB.query(
                db,
                "UPDATE retired_archive_relocation SET report=?3 WHERE host=?1 AND destination=?2",
                [name, destination, detail]
              )

            false
        end
      end
    end)
    |> Enum.all?()
  rescue
    error ->
      Logger.warning("archive relocation deferred: #{Exception.message(error)}")
      false
  catch
    _, _ -> false
  end

  defp relocate_archive(db, name, host, source, destination, config) do
    if relative_inside(destination, source) != nil or relative_inside(source, destination) != nil,
      do: raise(ArgumentError, "archive relocation directories overlap")

    {:ok, [[target]]} =
      DB.query(
        db,
        "SELECT archivePath FROM retired_archive_relocation WHERE host=?1 AND destination=?2",
        [name, destination]
      )

    script =
      move_script() <> "\nmove_workspace " <> shell_quote(source) <> " " <> shell_quote(target)

    invocation = invocation(host, script)
    runner = Map.get(config, :workspace_cleanup_runner) || (&system_runner/3)
    response = run_bounded(runner, invocation, script, "", @default_runner_timeout_ms)

    if match?({_, 0}, response) do
      {:ok, :ok} =
        DB.transaction(db, fn txn ->
          Txn.q(
            txn,
            "SELECT artifactId,home,originHost FROM artifacts WHERE state='archived' AND substr(home,1,length(?1)+1)=?1 || '/'",
            [source]
          )
          |> Enum.each(fn [id, home, origin_host] ->
            if origin_host == name or (is_nil(origin_host) and is_nil(host.ssh)) do
              Tightbeam.Artifacts.repoint_archive_in_txn(
                txn,
                id,
                target <> String.replace_prefix(home, source, "")
              )
            end
          end)

          Txn.q(
            txn,
            "UPDATE retired_workspace_cleanup SET archivePath=?2 || substr(archivePath,length(?1)+1) WHERE substr(archivePath,1,length(?1)+1)=?1 || '/' AND sessionKey IN (SELECT sessionKey FROM sessions WHERE host=?3)",
            [source, target, name]
          )

          Txn.q(
            txn,
            "UPDATE retired_archive_relocation SET completed=1,report=NULL WHERE host=?1 AND destination=?2",
            [name, destination]
          )

          :ok
        end)

      true
    else
      Logger.warning("archive relocation incomplete #{name}: #{inspect(response)}")

      {:ok, _} =
        DB.query(
          db,
          "UPDATE retired_archive_relocation SET report=?3 WHERE host=?1 AND destination=?2",
          [name, destination, inspect(response)]
        )

      false
    end
  end

  defp archive_name(key),
    do:
      Base.url_encode64(key, padding: false) <>
        "-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp move_script do
    """
    device_id() {
      stat -c '%d' "$1" 2>/dev/null || stat -f '%d' "$1" 2>/dev/null
    }

    move_workspace() (
      source=$1
      target=$2
      [ ! -L "$source" ] && [ ! -L "$target" ] || exit 1
      if [ -d "$target" ]; then
        # The reserved destination appears only after a complete copy or rename.
        [ ! -e "$source" ] || rm -rf "$source"
      elif [ -d "$source" ]; then
        mkdir -p "$(dirname "$target")" || exit 1
        if [ "$(device_id "$source")" = "$(device_id "$(dirname "$target")")" ]; then
          mv "$source" "$target"
        else
          mkdir -p "$target.partial" &&
            cp -a "$source/." "$target.partial/" &&
            mv "$target.partial" "$target" &&
            rm -rf "$source"
        fi
      elif [ -e "$source" ] || [ -L "$source" ] || [ -e "$target" ]; then
        exit 1
      fi
    )
    """
  end

  defp invocation(host, script) do
    case host.ssh do
      nil ->
        ["sh", "-c", script]

      ssh when is_binary(ssh) and ssh != "" ->
        ["ssh" | @ssh_opts] ++ [ssh, "sh", "-lc", shell_quote(script)]
    end
  end

  def process_session(config, db, key) do
    report =
      try do
        session = Tightbeam.Org.get(db, key)
        hosts = Tightbeam.Placement.hosts(config.base_dir, db)
        host = Map.fetch!(hosts, session.host)
        workspace = Tightbeam.Placement.workdir_path(config, session)
        root = Path.expand(archive_root(host))

        if relative_inside(root, workspace) != nil or relative_inside(workspace, root) != nil,
          do: raise(ArgumentError, "archive directory overlaps workspace")

        destination = Path.join(root, archive_name(key))

        {:ok, _} =
          DB.query(
            db,
            "UPDATE retired_workspace_cleanup SET archivePath=COALESCE(archivePath,?2) WHERE sessionKey=?1",
            [key, destination]
          )

        {:ok, [[destination]]} =
          DB.query(db, "SELECT archivePath FROM retired_workspace_cleanup WHERE sessionKey=?1", [
            key
          ])

        reap(db,
          session_key: key,
          host_name: session.host,
          host: host,
          hosts: hosts,
          workspace: workspace,
          archive_path: destination,
          runner: Map.get(config, :workspace_cleanup_runner),
          runner_timeout_ms:
            Map.get(config, :workspace_cleanup_timeout_ms, @default_runner_timeout_ms)
        )
      rescue
        error -> failed_report([session_key: key], "cleanup_failed", Exception.message(error))
      catch
        kind, error ->
          failed_report([session_key: key], "cleanup_failed", "#{kind}: #{inspect(error)}")
      end

    {:ok, _} =
      DB.query(
        db,
        "UPDATE retired_workspace_cleanup SET completed=?2, nextAt=?3, report=?4 WHERE sessionKey=?1",
        [
          key,
          if(report.status == "completed", do: 1, else: 0),
          System.system_time(:millisecond) + 300_000,
          JSON.encode!(report)
        ]
      )

    if report.status != "completed",
      do: Logger.warning("workspace cleanup incomplete #{key}: #{inspect(report.blockers)}")

    report
  end

  def health(db \\ DB, owner \\ nil) do
    case DB.query(
           db,
           "SELECT c.sessionKey,c.report FROM retired_workspace_cleanup c LEFT JOIN sessions s ON s.sessionKey=c.sessionKey WHERE c.completed=0 AND (?1 IS NULL OR s.ownerUserId=?1) ORDER BY c.sessionKey",
           [owner]
         ) do
      {:ok, rows} ->
        {:ok, relocation} =
          DB.query(
            db,
            "SELECT host,report FROM retired_archive_relocation WHERE completed=0 AND ?1 IS NULL",
            [owner]
          )

        unfinished =
          Enum.map(rows, fn [key, report] ->
            %{workspace: key, reason: cleanup_reason(report)}
          end) ++
            Enum.map(relocation, fn [host, report] ->
              %{workspace: "archive on " <> host, reason: report || "archive relocation pending"}
            end)

        %{count: length(unfinished), unfinished: unfinished}

      {:error, error} ->
        %{unavailable: inspect(error)}
    end
  rescue
    error -> %{unavailable: Exception.message(error)}
  catch
    kind, error -> %{unavailable: "#{kind}: #{inspect(error)}"}
  end

  defp cleanup_reason(nil), do: "cleanup pending"

  defp cleanup_reason(report) do
    case JSON.decode(report) do
      {:ok, %{"blockers" => blockers}} when is_list(blockers) ->
        Enum.map_join(blockers, "; ", fn
          %{"reason" => reason} = blocker when is_binary(reason) ->
            [reason, blocker["detail"], blocker["path"]]
            |> Enum.filter(&is_binary/1)
            |> Enum.join(": ")

          _ ->
            "invalid cleanup blocker"
        end)

      _ ->
        "invalid cleanup report"
    end
  end

  @doc false
  def reap(db, opts) do
    session_key = Keyword.fetch!(opts, :session_key)

    report =
      try do
        case DB.transaction(db, fn txn -> cleanup_plan_in_txn(txn, opts) end) do
          {:ok, {:ok, plan}} ->
            run_cleanup_plan(db, plan, opts)

          {:ok, {:error, blocker}} ->
            blocked_report(opts, blocker)

          {:error, reason} ->
            failed_report(opts, "cleanup_plan_failed", inspect(reason))
        end
      rescue
        error ->
          failed_report(opts, "cleanup_plan_failed", Exception.message(error))
      catch
        kind, reason ->
          failed_report(opts, "cleanup_plan_failed", "#{kind}: #{inspect(reason)}")
      end
      |> Map.put_new(:session_key, session_key)

    record_report(db, report)
  end

  @doc false
  def default_runner_timeout_ms, do: @default_runner_timeout_ms

  @doc false
  def system_runner(invocation, _script, input) do
    manifest =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-cleanup-#{:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)}"
      )

    try do
      {:ok, :ok} =
        File.open(manifest, [:write, :binary, :exclusive], fn file ->
          :ok = File.chmod(manifest, 0o600)
          IO.binwrite(file, input)
        end)

      command =
        "exec " <>
          Enum.map_join(invocation, " ", &shell_quote/1) <>
          " < " <> shell_quote(manifest)

      System.cmd("sh", ["-c", command], stderr_to_stdout: true)
    after
      File.rm(manifest)
    end
  end

  defp cleanup_plan_in_txn(txn, opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    host_name = Keyword.fetch!(opts, :host_name)
    requested_workspace = Keyword.fetch!(opts, :workspace)

    with {:ok, host, hosts, workspace} <-
           current_route(txn, session_key, host_name, requested_workspace, opts),
         {:ok, keep} <- protection_plan(txn, host_name, host, hosts, workspace) do
      {:ok,
       %{
         session_key: session_key,
         host_name: host_name,
         host: host,
         hosts: hosts,
         workspace: workspace,
         keep: keep
       }}
    end
  end

  defp run_cleanup_plan(db, plan, opts) do
    case execute(
           plan.host,
           plan.workspace,
           plan.keep,
           Keyword.get(opts, :archive_path),
           Keyword.get(opts, :runner),
           Keyword.get(opts, :runner_timeout_ms, @default_runner_timeout_ms)
         ) do
      {:ok, execution} ->
        if execution.status == "completed" and Keyword.get(opts, :archive_path) do
          destination = Keyword.fetch!(opts, :archive_path)

          {:ok, :ok} =
            DB.transaction(db, fn txn ->
              Enum.each(plan.keep.artifacts, fn artifact ->
                home = Path.join(destination, artifact.relative_path)
                Tightbeam.Artifacts.archive_cleaned_in_txn(txn, artifact.artifact_id, home)
              end)
            end)
        end

        Map.merge(execution, %{
          session_key: plan.session_key,
          host: plan.host_name,
          workspace: plan.workspace,
          preserved_artifacts: plan.keep.artifacts
        })

      {:error, blocker} ->
        blocked_report(opts, blocker)
    end
  rescue
    error ->
      failed_report(opts, "cleanup_failed", Exception.message(error))
  catch
    kind, reason ->
      failed_report(opts, "cleanup_failed", "#{kind}: #{inspect(reason)}")
  end

  defp blocked_report(opts, blocker) do
    %{
      status: "incomplete",
      session_key: Keyword.get(opts, :session_key),
      host: Keyword.get(opts, :host_name),
      workspace: Keyword.get(opts, :workspace),
      removed_paths: [],
      removed_paths_complete: true,
      result_confirmed: true,
      preserved_artifacts: [],
      blockers: [blocker]
    }
  end

  defp failed_report(opts, reason, detail) do
    %{
      status: "incomplete",
      session_key: Keyword.get(opts, :session_key),
      host: Keyword.get(opts, :host_name),
      workspace: Keyword.get(opts, :workspace),
      removed_paths: [],
      removed_paths_complete: false,
      result_confirmed: false,
      preserved_artifacts: [],
      blockers: [%{reason: reason, detail: detail}]
    }
  end

  defp record_report(db, report) do
    kind =
      if report.status == "completed",
        do: "retired_workspace_cleanup_completed",
        else: "retired_workspace_cleanup_incomplete"

    EventLog.lifecycle(db, kind, report.session_key, JSON.encode!(report))
    report
  rescue
    error ->
      Logger.warning("workspace cleanup audit failed: #{Exception.message(error)}")
      report
  catch
    kind, reason ->
      Logger.warning("workspace cleanup audit failed: #{kind}: #{inspect(reason)}")
      report
  end

  defp current_route(txn, session_key, host_name, requested_workspace, opts) do
    {session_host, session_state} =
      case Txn.q(txn, "SELECT host, state FROM sessions WHERE sessionKey=?1", [session_key]) do
        [[host, state]] -> {host, state}
        [] -> {nil, nil}
      end

    local_host_name = Tightbeam.Placement.local_host_name()

    registered_hosts =
      Txn.q(txn, "SELECT name, ssh, baseDir, cliBin FROM hosts")
      |> Map.new(fn [name, ssh, base_dir, cli_bin] ->
        {name, %{ssh: ssh, base_dir: base_dir, cli_bin: cli_bin}}
      end)

    local_host =
      Keyword.fetch!(opts, :hosts)
      |> Map.fetch!(local_host_name)

    hosts = Map.put(registered_hosts, local_host_name, local_host)

    host =
      if host_name == local_host_name do
        local_host
      else
        Map.get(registered_hosts, host_name)
      end

    with true <- session_host == host_name,
         true <- session_state == "retired",
         true <- is_map(host),
         expected <- Keyword.fetch!(opts, :host),
         true <- host.ssh == expected.ssh and host.base_dir == expected.base_dir,
         workspace <- Tightbeam.Placement.host_workdir_path(host, session_key),
         true <- Path.expand(workspace) == Path.expand(requested_workspace) do
      {:ok, host, hosts, workspace}
    else
      _ ->
        {:error,
         %{
           reason: "retirement_route_changed",
           session_host: session_host,
           session_state: session_state,
           requested_host: host_name
         }}
    end
  end

  defp protection_plan(txn, host_name, host, hosts, workspace) do
    with true <- Path.type(workspace) == :absolute,
         false <- contains_line_break?(workspace) do
      root = Path.expand(workspace)

      rows =
        Txn.q(
          txn,
          """
          SELECT artifactId, originPath, originHost, originWorkspace
          FROM artifacts WHERE state='in-workspace'
            AND (originWorkspace=?1 OR originPath=?1
                 OR substr(originPath,1,length(?1)+1)=?1 || '/'
                 OR instr(originPath,':' || ?1)>0)
          ORDER BY artifactId
          """,
          [root]
        )
        |> Enum.map(fn [artifact_id, origin_path, origin_host, origin_workspace] ->
          %{
            artifact_id: artifact_id,
            origin_path: origin_path,
            origin_host: origin_host,
            origin_workspace: origin_workspace
          }
        end)

      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
        case ArtifactOrigins.possible_location(row) do
          :non_filesystem ->
            {:cont, {:ok, acc}}

          {:ok, origin_host, origin_path} ->
            protect_or_skip(row, origin_host, origin_path, host_name, host, hosts, root, acc)

          {:error, _reason} ->
            {:cont, {:ok, acc}}
        end
      end)
      |> case do
        {:ok, artifacts} ->
          {:ok,
           %{
             artifacts: artifacts,
             paths: artifacts |> Enum.map(& &1.relative_path) |> Enum.uniq() |> Enum.sort()
           }}

        error ->
          error
      end
    else
      _ -> {:error, %{reason: "workspace_path_invalid"}}
    end
  end

  defp protect_or_skip(row, origin_host, origin_path, host_name, host, hosts, root, acc) do
    case relative_inside(origin_path, root) do
      nil ->
        {:cont, {:ok, acc}}

      relative ->
        if is_nil(origin_host) or same_route?(origin_host, host_name, host, hosts) do
          if contains_line_break?(relative) do
            {:halt,
             {:error,
              %{
                reason: "artifact_path_unrepresentable",
                artifact_id: row.artifact_id,
                relative_path: relative
              }}}
          else
            artifact = %{
              artifact_id: row.artifact_id,
              origin_path: row.origin_path,
              relative_path: relative
            }

            {:cont, {:ok, [artifact | acc]}}
          end
        else
          {:cont, {:ok, acc}}
        end
    end
  end

  defp same_route?(origin_host, host_name, target_host, hosts) do
    cond do
      origin_host == host_name ->
        true

      is_binary(target_host.ssh) and origin_host == target_host.ssh ->
        true

      match?(%{ssh: ssh} when is_binary(ssh), Map.get(hosts, origin_host)) ->
        Map.fetch!(hosts, origin_host).ssh == target_host.ssh

      true ->
        false
    end
  end

  defp relative_inside(path, root) do
    expanded = Path.expand(path)
    relative = Path.relative_to(expanded, root)

    if Path.type(relative) == :absolute or relative == ".." or
         String.starts_with?(relative, "../") do
      nil
    else
      relative
    end
  end

  defp execute(host, workspace, keep, archive_path, runner, timeout_ms) do
    cond do
      contains_line_break?(workspace) ->
        {:error, %{reason: "workspace_path_unrepresentable"}}

      not (is_integer(timeout_ms) and timeout_ms > 0) ->
        {:error, %{reason: "cleanup_runner_timeout_invalid"}}

      true ->
        script = cleanup_script(Path.expand(workspace), archive_path)
        manifest = if keep.paths == [], do: "", else: Enum.join(keep.paths, "\n") <> "\n"

        invocation =
          case host.ssh do
            nil ->
              ["sh", "-c", script]

            ssh when is_binary(ssh) and ssh != "" ->
              ["ssh" | @ssh_opts] ++ [ssh, "sh", "-lc", shell_quote(script)]

            _ ->
              nil
          end

        if is_nil(invocation) do
          {:error, %{reason: "retirement_host_unavailable"}}
        else
          runner =
            runner ||
              Application.get_env(:tightbeam, :workspace_cleanup_runner, &system_runner/3)

          response = run_bounded(runner, invocation, script, manifest, timeout_ms)

          {:ok, execution_report(response)}
        end
    end
  end

  defp run_bounded(runner, invocation, script, manifest, timeout_ms) do
    task =
      Task.Supervisor.async_nolink(Tightbeam.TurnTaskSupervisor, fn ->
        try do
          {:runner_result, runner.(invocation, script, manifest)}
        rescue
          error -> {:runner_exception, Exception.message(error)}
        catch
          kind, reason -> {:runner_exception, "#{kind}: #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:runner_result, response}} ->
        response

      {:ok, {:runner_exception, detail}} ->
        {:runner_exception, detail}

      {:exit, reason} ->
        {:runner_exception, inspect(reason)}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:runner_timeout, timeout_ms}
    end
  end

  defp execution_report({output, status}) when is_binary(output) and is_integer(status) do
    {removed, errors, done, diagnostics} = parse_output(output)

    command_errors =
      if status == 0, do: [], else: [%{reason: "cleanup_command_failed", exit: status}]

    confirmation_errors =
      if done in [0, 1], do: [], else: [%{reason: "cleanup_result_unconfirmed"}]

    incomplete_errors =
      if done == 1 and errors == [], do: [%{reason: "cleanup_incomplete"}], else: []

    blockers = errors ++ command_errors ++ confirmation_errors ++ incomplete_errors

    completed? = status == 0 and done == 0 and errors == []

    %{
      status: if(completed?, do: "completed", else: "incomplete"),
      removed_paths: removed,
      removed_paths_complete: done in [0, 1],
      blockers: blockers,
      diagnostics: diagnostics,
      command_exit: status,
      result_confirmed: done in [0, 1]
    }
  end

  defp execution_report({:runner_exception, detail}) do
    %{
      status: "incomplete",
      removed_paths: [],
      removed_paths_complete: false,
      blockers: [%{reason: "cleanup_runner_failed", detail: detail}],
      result_confirmed: false
    }
  end

  defp execution_report({:runner_timeout, timeout_ms}) do
    %{
      status: "incomplete",
      removed_paths: [],
      removed_paths_complete: false,
      blockers: [%{reason: "cleanup_runner_timeout", timeout_ms: timeout_ms}],
      diagnostics: [],
      result_confirmed: false
    }
  end

  defp execution_report(other) do
    %{
      status: "incomplete",
      removed_paths: [],
      removed_paths_complete: false,
      blockers: [%{reason: "cleanup_runner_result_invalid", detail: inspect(other)}],
      result_confirmed: false
    }
  end

  defp parse_output(output) do
    Enum.reduce(String.split(output, "\n", trim: true), {[], [], nil, []}, fn line,
                                                                              {removed, errors,
                                                                               done, diagnostics} ->
      case String.split(line, "\t") do
        ["R", hex] ->
          case decode_path(hex) do
            {:ok, path} ->
              {removed ++ [path], errors, done, diagnostics}

            :error ->
              {removed, errors ++ [%{reason: "cleanup_report_invalid"}], done, diagnostics}
          end

        ["E", reason, hex] ->
          path =
            case decode_path(hex) do
              {:ok, decoded} -> decoded
              :error -> nil
            end

          {removed, errors ++ [%{reason: reason, path: path}], done, diagnostics}

        ["DONE", "0"] ->
          {removed, errors, 0, diagnostics}

        ["DONE", "1"] ->
          {removed, errors, 1, diagnostics}

        _ ->
          {removed, errors, done, diagnostics ++ [line]}
      end
    end)
  end

  defp decode_path(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, path} ->
        if String.valid?(path),
          do: {:ok, path},
          else: {:ok, "hex:" <> Base.encode16(path, case: :lower)}

      :error ->
        :error
    end
  end

  defp cleanup_script(root, archive_path) do
    """
    #{move_script()}
    umask 077
    root=#{shell_quote(root)}
    workspace_root=$root
    archive=#{shell_quote(archive_path || "")}
    keep_list=$(cat)
    had_error=0
    unsafe_route=0

    emit_path() {
      printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
    }

    emit_removed() {
      encoded=$(emit_path "$1")
      printf 'R\t%s\n' "$encoded"
    }

    emit_error() {
      encoded=$(emit_path "$2")
      printf 'E\t%s\t%s\n' "$1" "$encoded"
    }

    stat_identity() {
      stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null
    }

    is_protected() {
      case "\n$keep_list\n" in
        *"\n$1\n"*) return 0 ;;
        *) return 1 ;;
      esac
    }

    has_protected_descendant() {
      case "\n$keep_list\n" in
        *"\n$1"/*) return 0 ;;
        *) return 1 ;;
      esac
    }

    exact_keep_path() (
      set +f
      keep_path=$1
      [ "$keep_path" = . ] && return 0
      parent_rel=
      rest=$keep_path
      while [ -n "$rest" ]; do
        case "$rest" in
          */*) component=\${rest%%/*}; rest=\${rest#*/}; has_more=1 ;;
          *) component=$rest; rest=; has_more=0 ;;
        esac
        [ -n "$component" ] || return 1
        parent="$root\${parent_rel:+/$parent_rel}"
        [ ! -L "$parent" ] || return 2
        [ -d "$parent" ] || return 1
        found=0
        for entry in "$parent"/* "$parent"/.[!.]* "$parent"/..?*; do
          [ -e "$entry" ] || [ -L "$entry" ] || continue
          if [ "\${entry##*/}" = "$component" ]; then
            found=1
            break
          fi
        done
        [ "$found" -eq 1 ] || return 1
        parent_rel=\${parent_rel:+$parent_rel/}$component
        if [ "$has_more" -eq 1 ]; then
          [ ! -L "$root/$parent_rel" ] || return 2
          [ -d "$root/$parent_rel" ] || return 1
        fi
      done
      return 0
    )

    verify_route() {
      [ ! -L "$root" ] || return 1
      [ "$(stat_identity "$root")" = "$root_id" ] || return 1
      [ "$(pwd -P)" = "$expected_dir" ]
    }

    cleanup_dir() (
      dir_rel=$1
      if [ -n "$dir_rel" ]; then
        [ ! -L "$root/$dir_rel" ] || { emit_error symlink_route "$dir_rel"; exit 1; }
        cd -P "$root/$dir_rel" 2>/dev/null || { emit_error directory_unavailable "$dir_rel"; exit 1; }
        expected_dir="$root_real/$dir_rel"
      else
        cd -P "$root" 2>/dev/null || { emit_error workspace_unavailable .; exit 1; }
        expected_dir=$root_real
      fi

      [ "$(pwd -P)" = "$expected_dir" ] || { emit_error route_changed "$dir_rel"; exit 1; }
      current_id=$(stat_identity .) || { emit_error directory_unavailable "$dir_rel"; exit 1; }
      [ "${current_id%%:*}" = "$root_device" ] || { emit_error mount_boundary "$dir_rel"; exit 1; }
      local_failed=0

      for name in * .[!.]* ..?*; do
        [ -e "$name" ] || [ -L "$name" ] || continue
        child_rel=${dir_rel:+$dir_rel/}$name
        newline='
    '
        case "$name" in
          *"$newline"*)
            emit_error unsupported_newline_path "path contains a newline"
            local_failed=1
            continue
            ;;
        esac

        if is_protected "$child_rel"; then
          continue
        elif has_protected_descendant "$child_rel"; then
          if [ -L "$name" ]; then
            emit_error symlink_route "$child_rel"
            local_failed=1
          elif [ -d "$name" ]; then
            if cleanup_dir "$child_rel"; then :; else local_failed=1; fi
          else
            emit_error artifact_parent_not_directory "$child_rel"
            local_failed=1
          fi
        elif [ -L "$name" ]; then
          if verify_route && rm -f "./$name"; then
            emit_removed "$child_rel"
          else
            emit_error entry_remove_failed "$child_rel"
            local_failed=1
          fi
        elif [ -d "$name" ]; then
          child_id=$(stat_identity "$name") || child_id=
          if [ -z "$child_id" ] || [ "${child_id%%:*}" != "$root_device" ]; then
            emit_error mount_boundary "$child_rel"
            local_failed=1
          elif cleanup_dir "$child_rel"; then
            if verify_route && [ ! -L "$name" ] &&
                 [ "$(stat_identity "$name")" = "$child_id" ] && rmdir "./$name" 2>/dev/null; then
              emit_removed "$child_rel"
            else
              emit_error directory_remove_failed "$child_rel"
              local_failed=1
            fi
          else
            local_failed=1
          fi
        elif [ -e "$name" ]; then
          if verify_route && rm -f "./$name"; then
            emit_removed "$child_rel"
          else
            emit_error entry_remove_failed "$child_rel"
            local_failed=1
          fi
        else
          emit_error entry_changed "$child_rel"
          local_failed=1
        fi
      done

      [ "$local_failed" -eq 0 ]
    )

    if [ -n "$archive" ] && [ -d "$archive" ]; then
      root=$archive
    fi

    if [ ! -e "$root" ] && [ ! -L "$root" ]; then
      if [ -n "$keep_list" ]; then
        [ -n "$archive" ] && [ -d "$archive" ] || { emit_error workspace_unavailable .; printf 'DONE\t1\n'; exit 2; }
        root=$archive
      else
        printf 'DONE\t0\n'
        exit 0
      fi
    fi

    if [ ! -d "$root" ] || [ -L "$root" ]; then
      emit_error workspace_unavailable .
      had_error=1
    else
      root_real=$(CDPATH= cd -P "$root" 2>/dev/null && pwd -P)
      root_id=$(stat_identity "$root") || root_id=
      if [ -z "$root_real" ] || [ -z "$root_id" ] || [ "$root_real" = / ]; then
        emit_error workspace_unavailable .
        had_error=1
      else
        root_device=${root_id%%:*}
        saved_ifs=$IFS
        newline='
    '
        IFS=$newline
        set -f
        for keep in $keep_list; do
          if [ ! -e "$root/$keep" ] && [ ! -L "$root/$keep" ]; then
            emit_error artifact_missing "$keep"
            had_error=1
          else
            exact_keep_path "$keep"
            keep_status=$?
            case "$keep_status" in
              0) ;;
              2) emit_error symlink_route "$keep"; had_error=1; unsafe_route=1 ;;
              *) emit_error artifact_path_spelling_mismatch "$keep"; had_error=1; unsafe_route=1 ;;
            esac
          fi
        done
        set +f
        IFS=$saved_ifs

        if [ "$unsafe_route" -eq 0 ] && ! is_protected .; then
          if cleanup_dir ""; then :; else had_error=1; fi
        fi

        if [ -z "$keep_list" ] && [ "$had_error" -eq 0 ]; then
          if [ ! -L "$root" ] && [ "$(stat_identity "$root")" = "$root_id" ] &&
             rmdir "$root" 2>/dev/null; then
            emit_removed .
          else
            emit_error workspace_remove_failed .
            had_error=1
          fi
        fi
      fi
    fi

    if [ "$had_error" -eq 0 ] && [ -n "$keep_list" ] && [ -n "$archive" ]; then
      if move_workspace "$workspace_root" "$archive"; then
        :
      else
        emit_error archive_move_failed "$archive"
        had_error=1
      fi
    fi

    if [ "$had_error" -eq 0 ]; then
      printf 'DONE\t0\n'
      exit 0
    else
      printf 'DONE\t1\n'
      exit 2
    fi
    """
  end

  defp contains_line_break?(value),
    do: String.contains?(value, "\n") or String.contains?(value, "\r")

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
