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
    {:ok, %{config: config, db: Map.get(config, :db, DB), timer: timer, relocation_failures: %{}}}
  end

  def handle_info(:drain, state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    delay =
      try do
        now = System.system_time(:millisecond)

        {:ok, rows} =
          DB.query(
            state.db,
            "SELECT sessionKey,nextAt FROM retired_workspace_cleanup WHERE completed=0 ORDER BY nextAt,sessionKey LIMIT 1"
          )

        case rows do
          [[key, at]] when at <= now ->
            process_session(state.config, state.db, key)
            1_000

          [[_, at]] ->
            max(at - now, 1_000)

          [] ->
            nil
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

    {relocation_delay, relocation_failures} =
      relocate_archive(state.config, state.db, state.relocation_failures)

    delay = if relocation_delay, do: min(delay || relocation_delay, relocation_delay), else: delay
    timer = if delay, do: Process.send_after(self(), :drain, delay)
    {:noreply, %{state | timer: timer, relocation_failures: relocation_failures}}
  end

  def archive_root(%{ssh: nil} = host),
    do: Application.get_env(:tightbeam, :archive_dir) || Path.join(host.base_dir, "archive")

  def archive_root(host), do: Path.join(host.base_dir, "archive")

  defp relocate_archive(config, db, failures) do
    source = Path.join(config.base_dir, "archive")
    destination = archive_root(%{ssh: nil, base_dir: config.base_dir})

    if Path.expand(source) != Path.expand(destination) do
      if relative_inside(destination, source) != nil or
           relative_inside(source, destination) != nil,
         do: raise(ArgumentError, "archive relocation directories overlap")

      # Old database prefixes also recover a move that finished before its transaction.
      {:ok, rows} =
        DB.query(
          db,
          "SELECT home FROM artifacts WHERE state='archived' AND (originHost=?2 OR originHost IS NULL) AND substr(home,1,length(?1)+1)=?1 || '/' UNION SELECT archivePath FROM retired_workspace_cleanup WHERE substr(archivePath,1,length(?1)+1)=?1 || '/' AND sessionKey IN (SELECT sessionKey FROM sessions WHERE host=?2)",
          [source, Tightbeam.Placement.local_host_name()]
        )

      recorded =
        Enum.map(rows, fn [path] -> path |> Path.relative_to(source) |> Path.split() |> hd() end)

      entries =
        case File.ls(source) do
          {:ok, entries} ->
            entries

          {:error, :enoent} ->
            []

          {:error, reason} ->
            raise File.Error, reason: reason, action: "list archive", path: source
        end

      entries = Enum.sort(Enum.uniq(entries ++ recorded))
      failures = Map.take(failures, entries)
      now = System.monotonic_time(:millisecond)

      entry =
        Enum.find(entries, &(not Map.has_key?(failures, &1))) ||
          Enum.find(entries, &(Map.fetch!(failures, &1) <= now))

      if entry do
        case relocate_entry(config, db, source, destination, entry) do
          :ok ->
            {1_000, Map.delete(failures, entry)}

          :retry ->
            {1_000, Map.put(failures, entry, System.monotonic_time(:millisecond) + 300_000)}
        end
      else
        delay = failures |> Map.values() |> Enum.min(fn -> nil end)
        {if(delay, do: max(delay - now, 1_000)), failures}
      end
    else
      {nil, failures}
    end
  rescue
    error ->
      Logger.warning("archive relocation deferred: #{Exception.message(error)}")
      {300_000, failures}
  catch
    kind, error ->
      Logger.warning("archive relocation deferred: #{kind}: #{inspect(error)}")
      {300_000, failures}
  end

  defp relocate_entry(config, db, source, destination, entry) do
    old = Path.join(source, entry)
    target = Path.join(destination, entry)

    script =
      move_script() <> "\nmove_workspace " <> shell_quote(old) <> " " <> shell_quote(target)

    runner = Map.get(config, :workspace_cleanup_runner) || (&system_runner/3)

    {_output, 0} =
      run_bounded(runner, ["sh", "-c", script], script, "", @default_runner_timeout_ms)

    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "SELECT artifactId,home FROM artifacts WHERE state='archived' AND (originHost=?2 OR originHost IS NULL) AND (home=?1 OR substr(home,1,length(?1)+1)=?1 || '/')",
          [old, Tightbeam.Placement.local_host_name()]
        )
        |> Enum.each(fn [id, home] ->
          Tightbeam.Artifacts.repoint_archive_in_txn(
            txn,
            id,
            target <> String.replace_prefix(home, old, "")
          )
        end)

        Txn.q(
          txn,
          "UPDATE retired_workspace_cleanup SET archivePath=?2 WHERE archivePath=?1 AND sessionKey IN (SELECT sessionKey FROM sessions WHERE host=?3)",
          [old, target, Tightbeam.Placement.local_host_name()]
        )

        :ok
      end)

    :ok
  rescue
    error ->
      Logger.warning("archive relocation deferred for #{entry}: #{Exception.message(error)}")
      :retry
  catch
    kind, error ->
      Logger.warning("archive relocation deferred for #{entry}: #{kind}: #{inspect(error)}")
      :retry
  end

  defp archive_name(key), do: Base.url_encode64(key, padding: false)

  defp move_script(timeout_ms \\ @default_runner_timeout_ms) do
    """
    cleanup_deadline=$(($(date +%s) + #{max(div(timeout_ms, 1000) - 1, 1)}))
    device_id() {
      stat -c '%d' "$1" 2>/dev/null || stat -f '%d' "$1" 2>/dev/null
    }

    move_workspace() (
      source=$1
      target=$2
      [ ! -L "$source" ] && [ ! -L "$target" ] || exit 1
      if [ -d "$source" ]; then
        mkdir -p "$(dirname "$target")" || exit 1
        if [ ! -e "$target" ] && [ "$(device_id "$source")" = "$(device_id "$(dirname "$target")")" ]; then
          mv "$source" "$target"
        else
          mkdir -p "$target" || exit 1
          remaining=$((cleanup_deadline - $(date +%s)))
          [ "$remaining" -gt 0 ] || exit 1
          cp -a "$source/." "$target/" &
          copy_pid=$!
          (
            trap 'kill "$alarm" 2>/dev/null; wait "$alarm"; exit' TERM
            sleep "$remaining" &
            alarm=$!
            wait "$alarm"
            kill "$copy_pid" 2>/dev/null
          ) </dev/null >/dev/null 2>&1 &
          watchdog=$!
          wait "$copy_pid"
          result=$?
          kill "$watchdog" 2>/dev/null || :
          wait "$watchdog" 2>/dev/null || :
          [ "$result" -eq 0 ] && rm -rf "$source"
        fi
      elif [ ! -e "$source" ] && [ -d "$target" ]; then
        :
      else
        exit 1
      fi
    )
    """
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

        {:ok, [[destination]]} =
          DB.query(
            db,
            "UPDATE retired_workspace_cleanup SET archivePath=COALESCE(archivePath,?2) WHERE sessionKey=?1 RETURNING archivePath",
            [key, destination]
          )

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

    {:ok, [[attempts]]} =
      DB.query(db, "SELECT attempts FROM retired_workspace_cleanup WHERE sessionKey=?1", [key])

    summary = report_summary(report)

    reason =
      report.blockers |> Enum.map(& &1.reason) |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")

    {:ok, _} =
      DB.query(
        db,
        "UPDATE retired_workspace_cleanup SET completed=?2, nextAt=?3, report=?4, reason=?5, attempts=attempts+1 WHERE sessionKey=?1",
        [
          key,
          if(report.status == "completed", do: 1, else: 0),
          System.system_time(:millisecond) +
            min(300_000 * Integer.pow(2, min(attempts, 8)), 86_400_000),
          JSON.encode!(summary),
          if(reason == "", do: nil, else: reason)
        ]
      )

    if report.status != "completed",
      do: Logger.warning("workspace cleanup incomplete #{key}: #{inspect(report.blockers)}")

    report
  end

  def health(db \\ DB, owner \\ nil) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT completed,COALESCE(reason,'cleanup pending'),COUNT(*) FROM retired_workspace_cleanup c LEFT JOIN sessions s ON s.sessionKey=c.sessionKey WHERE (completed=0 OR reason IS NOT NULL) AND (?1 IS NULL OR s.ownerUserId=?1) GROUP BY completed,reason ORDER BY completed,reason",
        [owner]
      )

    %{
      count:
        Enum.reduce(rows, 0, fn [done, _, n], count ->
          if done == 0, do: count + n, else: count
        end),
      reasons:
        Enum.map(rows, fn [done, reason, count] ->
          %{completed: done == 1, reason: reason, count: count}
        end)
    }
  rescue
    error -> %{unavailable: Exception.message(error)}
  catch
    kind, error -> %{unavailable: "#{kind}: #{inspect(error)}"}
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
                unless Enum.any?(
                         execution.blockers,
                         &(&1.reason == "artifact_missing" and &1.path == artifact.relative_path)
                       ) do
                  home = Path.join(destination, artifact.relative_path)
                  Tightbeam.Artifacts.archive_cleaned_in_txn(txn, artifact.artifact_id, home)
                end
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
      removed_count: 0,
      removed_count_complete: true,
      result_confirmed: true,
      preserved_artifacts: [],
      blockers: [blocker]
    }
  end

  defp failed_report(opts, reason, detail) do
    blocked_report(opts, %{reason: reason, detail: detail})
    |> Map.merge(%{removed_count_complete: false, result_confirmed: false})
  end

  defp report_summary(report),
    do: %{
      removed_count: report.removed_count,
      blockers: report.blockers |> Enum.map(& &1.reason) |> Enum.uniq()
    }

  defp record_report(db, report) do
    kind =
      if report.status == "completed",
        do: "retired_workspace_cleanup_completed",
        else: "retired_workspace_cleanup_incomplete"

    EventLog.lifecycle(
      db,
      kind,
      report.session_key,
      JSON.encode!(report_summary(report))
    )

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
        script = cleanup_script(Path.expand(workspace), archive_path, timeout_ms)
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

    completed? =
      status == 0 and done == 0 and Enum.all?(errors, &(&1.reason == "artifact_missing"))

    %{
      status: if(completed?, do: "completed", else: "incomplete"),
      removed_count: removed,
      removed_count_complete: done in [0, 1],
      blockers: blockers,
      diagnostics: diagnostics,
      command_exit: status,
      result_confirmed: done in [0, 1]
    }
  end

  defp execution_report({:runner_exception, detail}),
    do: failed_report([], "cleanup_runner_failed", detail)

  defp execution_report({:runner_timeout, timeout_ms}),
    do: failed_report([], "cleanup_runner_timeout", timeout_ms)

  defp execution_report(other),
    do: failed_report([], "cleanup_runner_result_invalid", inspect(other))

  defp parse_output(output) do
    Enum.reduce(String.split(output, "\n", trim: true), {0, [], nil, []}, fn line,
                                                                             {removed, errors,
                                                                              done, diagnostics} ->
      case String.split(line, "\t") do
        ["R"] ->
          {removed + 1, errors, done, diagnostics}

        ["E", reason, hex] ->
          path =
            case decode_path(hex) do
              {:ok, decoded} -> decoded
              :error -> nil
            end

          {removed, [%{reason: reason, path: path} | errors], done, diagnostics}

        ["DONE", "0"] ->
          {removed, errors, 0, diagnostics}

        ["DONE", "1"] ->
          {removed, errors, 1, diagnostics}

        _ ->
          {removed, errors, done, [line | diagnostics]}
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

  defp cleanup_script(root, archive_path, timeout_ms) do
    """
    #{move_script(timeout_ms)}
    umask 077
    root=#{shell_quote(root)}
    workspace_root=$root
    archive=#{shell_quote(archive_path || "")}
    keep_list=$(cat)
    had_error=0
    unsafe_route=0
    present_keep_list=

    emit_path() {
      printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
    }

    emit_removed() {
      printf 'R\\n'
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

    if [ ! -e "$root" ] && [ ! -L "$root" ] && [ -n "$archive" ] && [ -d "$archive" ]; then
      root=$archive
    fi

    if [ ! -e "$root" ] && [ ! -L "$root" ]; then
      saved_ifs=$IFS
      IFS='
    '
      set -f
      for keep in $keep_list; do emit_error artifact_missing "$keep"; done
      set +f
      IFS=$saved_ifs
      printf 'DONE\\t0\\n'
      exit 0
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
          else
            present_keep_list="${present_keep_list:+$present_keep_list$newline}$keep"
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
        keep_list=$present_keep_list

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
      printf 'DONE\\t0\\n'
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
