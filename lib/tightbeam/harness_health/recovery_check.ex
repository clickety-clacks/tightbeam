defmodule Tightbeam.HarnessHealth.RecoveryCheck do
  @moduledoc false

  alias Tightbeam.{DB, ErrorDiagnostic, EventLog, Homes, Placement, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Harness.Support
  alias Tightbeam.HarnessHealth.{RecoverySchedule, RecoveryScheduler}
  alias Tightbeam.RowReactions.Snapshot

  @checks_ddl """
  CREATE TABLE IF NOT EXISTS harness_health_recovery_checks (
    holdId TEXT NOT NULL REFERENCES harness_health_incidents(id),
    cycleId TEXT NOT NULL,
    routeKey TEXT NOT NULL,
    routeJson TEXT NOT NULL,
    harness TEXT NOT NULL,
    host TEXT NOT NULL,
    sharedAccount TEXT NOT NULL,
    model TEXT NOT NULL,
    startedAt INTEGER NOT NULL CHECK(startedAt >= 0),
    finishedAt INTEGER,
    outcome TEXT NOT NULL CHECK(outcome IN ('running','succeeded','failed','inconclusive','uncheckable')),
    errorExcerpt TEXT,
    eventId TEXT NOT NULL UNIQUE,
    org TEXT NOT NULL,
    PRIMARY KEY(holdId,cycleId,routeKey),
    CHECK((outcome='running' AND finishedAt IS NULL) OR
          (outcome!='running' AND finishedAt IS NOT NULL)),
    CHECK(errorExcerpt IS NULL OR length(errorExcerpt) <= 512)
  );
  CREATE INDEX IF NOT EXISTS harness_health_recovery_check_cycle
    ON harness_health_recovery_checks(holdId,cycleId,outcome,routeKey);

  CREATE TABLE IF NOT EXISTS harness_health_recovery_warnings (
    holdId TEXT PRIMARY KEY REFERENCES harness_health_incidents(id),
    reason TEXT NOT NULL,
    eventId TEXT NOT NULL UNIQUE,
    createdAt INTEGER NOT NULL CHECK(createdAt >= 0)
  );
  """

  @checks_columns ~w(
    holdId cycleId routeKey routeJson harness host sharedAccount model startedAt finishedAt
    outcome errorExcerpt eventId org
  )
  @warnings_columns ~w(holdId reason eventId createdAt)
  @error_limit 512
  @help_output_limit 65_536
  @selection_output_limit 4_096
  @schema_text """
              {"type":"object",
               "properties":{"ok":{"type":"boolean","enum":[true]}},
               "required":["ok"],
               "additionalProperties":false}
              """
  @prompt ~s(Reply with exactly {"ok":true}.)
  @codex_features ~w(
    shell_tool unified_exec code_mode_host multi_agent apps plugins hooks browser_use
    browser_use_external computer_use in_app_browser image_generation view_image sleep_tool
    goals tool_suggest skill_search memories workspace_dependencies skill_mcp_dependency_install
  )
  @codex_disable_args Enum.flat_map(@codex_features, & ["--disable", &1])

  def ensure_schema(db) do
    case DB.transaction(db, fn txn ->
           Txn.exec(txn, @checks_ddl)
           validate_schema!(txn)
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  def start_cycle(db, base_dir, task_sup, hold_id, cycle_id) do
    now = System.system_time(:millisecond)

    case DB.transaction(db, fn txn ->
             case RecoverySchedule.due_cycle_for_delivery_in_txn(txn, hold_id, cycle_id, now) do
             {:ok, schedule, hold} ->
               if hold["routesComplete"] and hold["routes"] != [] do
                 checks =
                   hold["routes"]
                   |> Enum.sort_by(&route_key/1)
                   |> Enum.flat_map(fn route ->
                     case insert_running_in_txn(txn, schedule, hold, route) do
                       {:inserted, check} -> [check]
                       :already_recorded -> []
                     end
                   end)

                 {checks, :running}
               else
                 warn_uncheckable_in_txn(txn, hold_id, "constituent routes are incomplete", now)
                 RecoverySchedule.finish_cycle_in_txn(txn, hold_id, cycle_id, now)
                 {[], :finished}
               end

             :withdrawn ->
               {[], :withdrawn}
           end
         end) do
      {:ok, {checks, _status}} ->
        Enum.each(checks, &start_check(task_sup, db, base_dir, &1))
        RecoveryScheduler.refresh()
        :ok

      {:error, error} ->
        raise error
    end
  end

  def recover_running(db) do
    now = System.system_time(:millisecond)

    case DB.transaction(db, fn txn ->
           rows =
             Txn.q(
               txn,
               "SELECT holdId,cycleId,routeKey FROM harness_health_recovery_checks WHERE outcome='running' ORDER BY holdId,cycleId,routeKey"
             )

           cycles =
             rows
             |> Enum.map(fn [hold_id, cycle_id, _route_key] -> {hold_id, cycle_id} end)
             |> Enum.uniq()

           Enum.each(rows, fn [hold_id, cycle_id, route_key] ->
             record_result_in_txn(txn, hold_id, cycle_id, route_key, "inconclusive", nil, now)
           end)

           Enum.each(cycles, fn {hold_id, cycle_id} ->
             finalize_cycle_in_txn(txn, hold_id, cycle_id, now)
           end)

           :ok
         end) do
      {:ok, :ok} ->
        RecoveryScheduler.refresh()
        :ok

      {:error, error} ->
        raise error
    end
  end

  def resume_due(db, base_dir, task_sup) do
    Wakes.resume_cycle_release_redeliveries(db)
    RecoverySchedule.fire_due(db, System.system_time(:millisecond))

    RecoverySchedule.due_cycles(db)
    |> Enum.each(fn cycle ->
      start_cycle(db, base_dir, task_sup, cycle["hold_id"], cycle["cycle_id"])
    end)

    :ok
  end

  @doc false
  def route_key(route) do
    route
    |> Map.take(~w(harness host sharedAccount model))
    |> JSON.encode!()
  end

  defp insert_running_in_txn(txn, schedule, hold, route) do
    key = route_key(route)
    event_id = check_event_id(hold["id"], schedule.cycle_id, key)
    route_json = JSON.encode!(Map.take(route, ~w(harness host sharedAccount model)))

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO harness_health_recovery_checks
        (holdId,cycleId,routeKey,routeJson,harness,host,sharedAccount,model,startedAt,
         finishedAt,outcome,errorExcerpt,eventId,org)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,NULL,'running',NULL,?10,?11)
      """,
      [
        hold["id"],
        schedule.cycle_id,
        key,
        route_json,
        route["harness"],
        route["host"],
        route["sharedAccount"],
        route["model"],
        schedule.started_at,
        event_id,
        hold["ownerUserId"] || "system"
      ]
    )

    if Txn.changes(txn) == 1 do
      {:inserted,
       %{
         hold_id: hold["id"],
         cycle_id: schedule.cycle_id,
         route_key: key,
         route: Map.take(route, ~w(harness host sharedAccount model)),
         started_at: schedule.started_at,
         timeout_ms: schedule.timeout_ms,
         org: hold["ownerUserId"] || "system"
       }}
    else
      :already_recorded
    end
  end

  defp start_check(task_sup, db, base_dir, check) do
    case Task.Supervisor.start_child(task_sup, fn ->
           result = run_route(base_dir, db, check.route, check.timeout_ms)
           record_result(db, check, result)
         end) do
      {:ok, _pid} -> :ok
      {:error, reason} ->
        record_result(db, check, {:inconclusive, diagnostic(reason)})
    end
  end

  defp run_route(base_dir, db, route, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case route_context(base_dir, db, route) do
      {:ok, host_config, path, home, pin, harness, credential_kind} ->
        case select_binary(host_config, path, home, harness, pin, deadline) do
          {:ok, command} ->
            case preflight(harness, command, host_config, path, home, deadline) do
              {:ok, true} ->
                case remaining(deadline) do
                  timeout when timeout > 0 ->
                    execute_route(
                      harness,
                      command,
                      host_config,
                      path,
                      home,
                      credential_kind,
                      route["model"],
                      timeout
                    )

                  _ ->
                    {:inconclusive, "recovery check timed out before the route request"}
                end

              {:uncheckable, reason} ->
                {:uncheckable, reason}

              {:inconclusive, reason} ->
                {:inconclusive, reason}

              {:ok, false} ->
                {:uncheckable, "required harness options are unavailable"}
            end

          {:uncheckable, reason} ->
            {:uncheckable, reason}

          {:inconclusive, reason} ->
            {:inconclusive, reason}
        end

      {:uncheckable, reason} ->
        {:uncheckable, reason}
    end
  rescue
    error -> {:inconclusive, diagnostic(error)}
  catch
    kind, reason -> {:inconclusive, diagnostic({kind, reason})}
  end

  defp route_context(base_dir, db, route) do
    with harness when harness in ["claude", "codex"] <- route["harness"],
         host when is_binary(host) and host != "" <- route["host"],
         model when is_binary(model) and model != "" <- route["model"],
         "shared" <- route["sharedAccount"],
         {:ok, host_config} <- Map.fetch(Placement.hosts(base_dir, db), host),
         path when is_binary(path) and path != "" <-
           Placement.toolchain_path_preview(%{base_dir: base_dir, db: db}, host),
         {:ok, credential_kind} <- selected_credential_kind(harness, host) do
      home = Homes.home_path(host_config.base_dir, host, harness_atom(harness))

      pin_name = if harness == "codex", do: "CODEX_PATH", else: "CLAUDE_CODE_EXECUTABLE"

      pin =
        case Enum.find(Placement.env_overlays(db, host, harness), &(&1.name == pin_name)) do
          %{value: value} when is_binary(value) and value != "" -> value
          _ -> nil
        end

      {:ok, host_config, path, home, pin, harness, credential_kind}
    else
      _ -> {:uncheckable, "the constituent route cannot be resolved"}
    end
  end

  defp select_binary(host_config, path, home, harness, pin, deadline) do
    timeout_ms = remaining(deadline)

    if timeout_ms <= 0 do
      {:inconclusive, "recovery check timed out during binary selection"}
    else
      root = Path.join(host_config.base_dir, "adapters")
      script = binary_selection_program(harness)
      pin = pin || ""
      vendor = if harness == "codex", do: "codex", else: "claude"

      command =
        "env -i PATH=#{shell_path_assignment(path)} HOME=#{Support.shell_quote(home)} " <>
          "node -e #{Support.shell_quote(script)} #{Support.shell_quote(root)} " <>
          "#{Support.shell_quote(vendor)} #{Support.shell_quote(pin)}"

      case port_command(host_config, command, timeout_ms, @selection_output_limit) do
        {:exit, 0, output} -> decode_selected_binary(output)
        {:ok, output} -> decode_selected_binary(output)
        {:exit, _status, _output} -> {:uncheckable, "the selected harness CLI is unavailable"}
        {:timeout, output} -> {:inconclusive, diagnostic(output)}
        {:transport_error, output} -> {:inconclusive, diagnostic(output)}
        {:error, reason} -> {:uncheckable, diagnostic(reason)}
      end
    end
  end

  defp decode_selected_binary(output) do
    case JSON.decode(String.trim(output)) do
      {:ok, %{"command" => command, "source" => source}}
      when is_list(command) and source in ["pin", "path", "bundle"] ->
        if command != [] and Enum.all?(command, &(is_binary(&1) and &1 != "")) do
          {:ok, command}
        else
          {:uncheckable, "the selected harness CLI is unavailable"}
        end

      _ ->
        {:uncheckable, "the selected harness CLI is unavailable"}
    end
  end

  @doc false
  def binary_selection_program(harness) when harness in ["claude", "codex"] do
    bundle =
      if harness == "codex" do
        """
        function bundle() {
          const adapter = createRequire(path.join(root, 'package.json'));
          const entry = adapter.resolve('@agentclientprotocol/codex-acp');
          return createRequire(entry).resolve('@openai/codex/bin/codex.js');
        }
        """
      else
        """
        function bundle() {
          const adapter = createRequire(path.join(root, 'package.json'));
          const entry = adapter.resolve('@agentclientprotocol/claude-agent-acp');
          const sdk = createRequire(entry).resolve('@anthropic-ai/claude-agent-sdk');
          const resolve = createRequire(sdk);
          const extension = process.platform === 'win32' ? '.exe' : '';
          const isMusl = !process.report?.getReport()?.header?.glibcVersionRuntime;
          const names = process.platform === 'linux'
            ? (isMusl
              ? [`@anthropic-ai/claude-agent-sdk-linux-${process.arch}-musl`, `@anthropic-ai/claude-agent-sdk-linux-${process.arch}`]
              : [`@anthropic-ai/claude-agent-sdk-linux-${process.arch}`, `@anthropic-ai/claude-agent-sdk-linux-${process.arch}-musl`])
            : [`@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}`];
          for (const name of names) {
            try { return resolve.resolve(`${name}/claude${extension}`); } catch {}
          }
          throw new Error('bundled CLI package is missing');
        }
        """
      end

    """
    const fs = require('node:fs');
    const path = require('node:path');
    const {createRequire} = require('node:module');
    const {spawnSync} = require('node:child_process');
    const [root, vendor, pin] = process.argv.slice(1);
    #{bundle}
    function lookup(name) {
      if (name.includes(path.sep)) return path.resolve(name);
      for (const directory of (process.env.PATH || '').split(path.delimiter)) {
        const candidate = path.resolve(directory, name);
        try {
          fs.accessSync(candidate, fs.constants.X_OK);
          if (!fs.statSync(candidate).isDirectory()) return candidate;
        } catch {}
      }
      return null;
    }
    function answersVersion(file, bundled) {
      const nodeBundle = bundled && vendor === 'codex';
      const result = spawnSync(nodeBundle ? process.execPath : file,
        nodeBundle ? [file, '--version'] : ['--version'],
        {encoding: 'utf8', timeout: 1200, env: process.env});
      return !result.error && result.status === 0;
    }
    let selected = pin || null;
    let source = pin ? 'pin' : 'bundle';
    let isBundle = false;
    if (!pin) {
      const candidate = lookup(vendor);
      if (candidate && answersVersion(candidate, false)) {
        selected = candidate;
        source = 'path';
      }
    }
    if (!selected) {
      try {
        selected = bundle();
        isBundle = true;
      } catch {}
    }
    if (!selected) {
      process.stdout.write(JSON.stringify({error: 'selected CLI is unavailable'}));
    } else {
      const command = isBundle && vendor === 'codex'
        ? [process.execPath, selected]
        : [selected];
      process.stdout.write(JSON.stringify({command, source}));
    }
    """
  end

  def binary_selection_program(_harness), do: raise(ArgumentError, "unsupported recovery harness")

  defp harness_atom("claude"), do: :claude
  defp harness_atom("codex"), do: :codex

  defp selected_credential_kind("codex", _host), do: {:ok, :subscription}

  defp selected_credential_kind("claude", host) do
    server = Tightbeam.Credentials.server(host)

    case GenServer.whereis(server) do
      nil ->
        # This is Placement's established fallback when the credential lifecycle
        # owner is absent: subscription is the only pre-existing credential kind.
        {:ok, :subscription}

      _pid ->
        case Tightbeam.Credentials.kind(:anthropic, server) do
          :api_key -> {:ok, :api_key}
          :subscription -> {:ok, :subscription}
          :none -> {:ok, :subscription}
          reason -> {:error, reason}
        end
    end
  rescue
    error -> {:error, error}
  end

  defp remaining(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp preflight(harness, binary, host_config, path, home, deadline) do
    timeout_ms = remaining(deadline)

    if timeout_ms <= 0 do
      {:inconclusive, "recovery check timed out during capability inspection"}
    else
      preflight_with_deadline(harness, binary, host_config, path, home, timeout_ms, deadline)
    end
  end

  defp preflight_with_deadline(harness, binary, host_config, path, home, timeout_ms, deadline) do
    help_args = if harness == "codex", do: ["exec", "--help"], else: ["--help"]

    with {:ok, help} <-
           run_cli(binary, help_args, harness, host_config, path, home, @help_output_limit,
             timeout_ms: timeout_ms,
             capture_stdout: true
           ),
         true <- options_present?(harness, help),
         :ok <-
           preflight_features(
             harness,
             binary,
             host_config,
             path,
             home,
             remaining(deadline)
           ) do
      {:ok, true}
    else
      false -> {:ok, false}
      {:timeout, output} -> {:inconclusive, diagnostic(output)}
      {:transport_error, output} -> {:inconclusive, diagnostic(output)}
      {:exit, status, output} -> {:uncheckable, diagnostic({:help_exit, status, output})}
      {:error, reason} -> {:uncheckable, diagnostic(reason)}
      {:uncheckable, reason} -> {:uncheckable, reason}
      {:inconclusive, reason} -> {:inconclusive, reason}
    end
  end

  defp preflight_features("claude", _binary, _host_config, _path, _home, _timeout_ms), do: :ok

  defp preflight_features("codex", binary, host_config, path, home, timeout_ms) do
    if timeout_ms <= 0 do
      {:inconclusive, "recovery check timed out during Codex capability inspection"}
    else
      case run_cli(
             binary,
             ["features", "list"],
             "codex",
             host_config,
             path,
             home,
             @help_output_limit,
             timeout_ms: timeout_ms,
             capture_stdout: true
           ) do
        {:ok, output} ->
          if Enum.all?(@codex_features, &listed_feature?(output, &1)),
            do: :ok,
            else: {:error, :missing_feature}

        {:error, reason} ->
          {:error, reason}

        {:transport_error, output} ->
          {:inconclusive, diagnostic(output)}

        {:exit, status, output} ->
          {:error, {:features_exit, status, output}}

        {:timeout, output} ->
          {:inconclusive, diagnostic(output)}
      end
    end
  end

  defp options_present?("claude", help) do
    options_present?(help, [
      "-p",
      "--tools",
      "--model",
      "--safe-mode",
      "--strict-mcp-config",
      "--no-session-persistence",
      "--output-format"
    ])
  end

  defp options_present?("codex", help) do
    options_present?(help, [
      "--ephemeral",
      "--ignore-user-config",
      "--ignore-rules",
      "--skip-git-repo-check",
      "-C",
      "-m",
      "-s",
      "-c",
      "--disable",
      "--output-schema",
      "--json"
    ])
  end

  defp options_present?(help, required) do
    listed =
      Regex.scan(~r/(?<![A-Za-z0-9_-])--?[A-Za-z0-9][A-Za-z0-9-]*/, help)
      |> List.flatten()
      |> MapSet.new()

    Enum.all?(required, &MapSet.member?(listed, &1))
  end

  defp listed_feature?(output, feature) do
    Regex.match?(~r/(?<![A-Za-z0-9_])#{Regex.escape(feature)}(?![A-Za-z0-9_])/, output)
  end

  defp execute_route("claude", binary, host_config, path, home, credential_kind, model, timeout_ms) do
    args = [
      "-p",
      "--tools",
      "",
      "--model",
      model,
      "--safe-mode",
      "--strict-mcp-config",
      "--no-session-persistence",
      "--output-format",
      "json",
      @prompt
    ]

    case run_cli(binary, args, "claude", host_config, path, home, @error_limit,
           timeout_ms: timeout_ms,
           credential_kind: credential_kind
         ) do
      {:ok, _bounded_stderr} -> {:succeeded, nil}
      {:exit, status, error} when status != 0 -> {:failed, error}
      {:timeout, error} -> {:inconclusive, error}
      {:transport_error, output} -> {:inconclusive, diagnostic(output)}
      {:error, reason} -> {:failed, diagnostic(reason)}
    end
  end

  defp execute_route("codex", binary, host_config, path, home, _credential_kind, model, timeout_ms) do
    args = [
      "exec",
      "--ephemeral",
      "--ignore-user-config",
      "--ignore-rules",
      "--skip-git-repo-check",
      "-C",
      :scratch,
      "-m",
      model,
      "-s",
      "read-only",
      "-c",
      "approval_policy=\"never\"",
      "-c",
      "web_search=\"disabled\"",
      "-c",
      "features.daemon_auto_start=false",
      @codex_disable_args,
      "--output-schema",
      :schema,
      "--json",
      @prompt
    ]

    case run_cli(binary, binary_args(args), "codex", host_config, path, home, @error_limit,
           timeout_ms: timeout_ms,
           schema: @schema_text
         ) do
      {:ok, _bounded_stderr} -> {:succeeded, nil}
      {:exit, status, error} when status != 0 -> {:failed, error}
      {:timeout, error} -> {:inconclusive, error}
      {:transport_error, output} -> {:inconclusive, diagnostic(output)}
      {:error, reason} -> {:failed, diagnostic(reason)}
    end
  end

  defp binary_args(args), do: List.flatten(args)

  defp run_cli(binary, args, harness, host_config, path, home, capture_limit, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    schema = Keyword.get(opts, :schema)
    capture_stdout? = Keyword.get(opts, :capture_stdout, false)
    credential_kind = Keyword.get(opts, :credential_kind, :subscription)

    script =
      cli_script(
        binary,
        args,
        harness,
        path,
        home,
        capture_limit,
        schema,
        capture_stdout?,
        credential_kind
      )

    case port_command(host_config, script, timeout_ms, capture_limit) do
      {:ok, output} -> {:ok, output}
      {:exit, status, output} when status == 0 -> {:ok, output}
      {:exit, status, output} -> {:exit, status, output}
      {:timeout, output} -> {:timeout, output}
      {:transport_error, output} -> {:transport_error, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cli_script(binary, args, harness, path, home, _capture_limit, schema, capture_stdout?, credential_kind) do
    schema_setup =
      if schema do
        "schema=$(mktemp \"${TMPDIR:-/tmp}/tightbeam-hhrc-schema.XXXXXX\") || exit 70\n" <>
          "printf %s #{Support.shell_quote(schema)} > \"$schema\" || exit 70\n"
      else
        ""
      end

    args =
      Enum.map_join(args, " ", fn
        :scratch -> "\"$scratch\""
        :schema -> "\"$schema\""
        value -> Support.shell_quote(value)
      end)

    codex_env = if harness == "codex", do: " CODEX_HOME=#{Support.shell_quote(home)}", else: ""

    claude_env =
      if harness == "claude",
        do: " CLAUDE_CONFIG_DIR=#{Support.shell_quote(home)}",
        else: ""

    credential_env =
      if harness == "claude" and credential_kind == :api_key do
        credential_path = Path.join(home, ".credentials.json")
        " ANTHROPIC_API_KEY=\"$(cat #{Support.shell_quote(credential_path)} 2>/dev/null)\""
      else
        ""
      end

    path_assignment = shell_path_assignment(path)
    executable =
      binary
      |> List.wrap()
      |> Enum.map_join(" ", &Support.shell_quote/1)

    command =
      "env -i PATH=#{path_assignment} HOME=#{Support.shell_quote(home)}#{codex_env}#{claude_env}#{credential_env} " <>
        executable <> " " <> args

    stdout_redirect = if capture_stdout?, do: "", else: " >/dev/null"

    "set -f\nscratch=$(mktemp -d \"${TMPDIR:-/tmp}/tightbeam-hhrc.XXXXXX\") || exit 70\n" <>
      "trap 'rm -rf \"$scratch\" >/dev/null 2>&1 || :; " <>
      "if [ -n \"${schema:-}\" ]; then rm -f \"$schema\"; fi' EXIT HUP INT TERM\n" <>
      schema_setup <>
      "cd \"$scratch\" || exit 70\n" <>
      command <> stdout_redirect <> "\n"
  end

  defp shell_path_assignment(path) do
    if String.ends_with?(path, ":$PATH") do
      prefix = String.trim_trailing(path, ":$PATH")
      Support.shell_quote(prefix) <> ":\"$PATH\""
    else
      Support.shell_quote(path)
    end
  end

  defp port_command(host_config, script, timeout_ms, capture_limit) do
    local? = is_nil(host_config.ssh)

    {executable, args} =
      if local? do
        {"/bin/sh", ["-c", script]}
      else
        ssh = System.find_executable("ssh") || "ssh"
        {ssh, Support.ssh_opts() ++ [host_config.ssh, "sh", "-c", Support.shell_quote(script)]}
      end

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, args}
      ])

    result = collect_port(port, System.monotonic_time(:millisecond) + timeout_ms, capture_limit, "")

    case result do
      {:exit, 255, output} when not local? -> {:transport_error, output}
      other -> other
    end
  rescue
    error -> {:error, error}
  end

  defp collect_port(port, deadline, limit, captured) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        captured = append_bounded(captured, data, limit)
        collect_port(port, deadline, limit, captured)

      {^port, {:exit_status, status}} ->
        {:exit, status, captured}
    after
      remaining ->
        close_port(port)
        {:timeout, captured}
    end
  end

  defp append_bounded(existing, data, limit) do
    remaining = max(limit - byte_size(existing), 0)
    if remaining == 0, do: existing, else: existing <> binary_part(data, 0, min(remaining, byte_size(data)))
  end

  defp close_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp record_result(db, check, {outcome, excerpt}) do
    now = System.system_time(:millisecond)
    excerpt = sanitize_excerpt(excerpt)

    case DB.transaction(db, fn txn ->
           record_result_in_txn(
             txn,
             check.hold_id,
             check.cycle_id,
             check.route_key,
             Atom.to_string(outcome),
             excerpt,
             now
           )
         end) do
      {:ok, {:released, release}} ->
        Wakes.redeliver_cycle_release(
          db,
          release.correlation,
          release.harness,
          release.host
        )

        RecoveryScheduler.refresh()
        :ok

      {:ok, _} ->
        RecoveryScheduler.refresh()
        :ok

      {:error, error} ->
        raise error
    end
  end

  @doc false
  @spec record_result_in_txn(
          Txn.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          integer()
        ) :: :ok | {:released, map()}
  def record_result_in_txn(txn, hold_id, cycle_id, route_key, outcome, excerpt, finished_at)
       when outcome in ["succeeded", "failed", "inconclusive", "uncheckable"] do
    case Txn.q(
           txn,
           "SELECT routeJson,startedAt,eventId,org,outcome FROM harness_health_recovery_checks WHERE holdId=?1 AND cycleId=?2 AND routeKey=?3",
           [hold_id, cycle_id, route_key]
         ) do
      [[route_json, started_at, event_id, org, "running"]] ->
        Txn.q(
          txn,
          "UPDATE harness_health_recovery_checks SET finishedAt=?4,outcome=?5,errorExcerpt=?6 WHERE holdId=?1 AND cycleId=?2 AND routeKey=?3 AND outcome='running'",
          [hold_id, cycle_id, route_key, finished_at, outcome, excerpt]
        )

        if Txn.changes(txn) == 1 do
          check = %{
            event_id: event_id,
            org: org,
            hold_id: hold_id,
            cycle_id: cycle_id,
            route: JSON.decode!(route_json),
            started_at: started_at,
            finished_at: finished_at,
            outcome: outcome,
            error_excerpt: excerpt
          }

          Tightbeam.RowReactions.remember_harness_health_recovery_check_in_txn(txn, check)
          if outcome == "uncheckable", do: warn_uncheckable_in_txn(txn, hold_id, "route capability unavailable", finished_at)
          finalize_cycle_in_txn(txn, hold_id, cycle_id, finished_at)
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp finalize_cycle_in_txn(txn, hold_id, cycle_id, now) do
    running =
      Txn.q(
        txn,
        "SELECT 1 FROM harness_health_recovery_checks WHERE holdId=?1 AND cycleId=?2 AND outcome='running' LIMIT 1",
        [hold_id, cycle_id]
      )

    if running == [] do
      case RecoverySchedule.due_cycle_for_delivery_in_txn(txn, hold_id, cycle_id, now) do
        {:ok, _schedule, hold} ->
          if all_current_routes_succeeded?(txn, hold_id, hold, cycle_id) do
            case Tightbeam.HarnessHealth.resolve_recovery_cycle_in_txn(txn, hold_id, cycle_id, now) do
              {:resolved, incident, correlation} ->
                RecoverySchedule.complete_cycle_in_txn(txn, hold_id, cycle_id, now)

                {:released,
                 %{
                   correlation: correlation,
                   harness: incident.harness,
                   host: incident.host
                 }}

              _ ->
                RecoverySchedule.finish_cycle_in_txn(txn, hold_id, cycle_id, now)
                :ok
            end
          else
            RecoverySchedule.finish_cycle_in_txn(txn, hold_id, cycle_id, now)
            :ok
          end

        :withdrawn ->
          :ok
      end
    else
      :ok
    end
  end

  defp all_current_routes_succeeded?(
         txn,
         hold_id,
         %{"routesComplete" => true, "routes" => routes},
         cycle_id
       )
       when is_list(routes) and routes != [] do
    Enum.all?(routes, fn route ->
      case Txn.q(
             txn,
             "SELECT outcome FROM harness_health_recovery_checks WHERE holdId=?1 AND cycleId=?2 AND routeKey=?3",
             [hold_id, cycle_id, route_key(route)]
           ) do
        [["succeeded"]] -> true
        _ -> false
      end
    end)
  end

  defp all_current_routes_succeeded?(_txn, _hold_id, _hold, _cycle_id), do: false

  defp warn_uncheckable_in_txn(txn, hold_id, reason, at) do
    event_id = "harness-health-recovery-uncheckable:" <> hold_id

    Txn.q(
      txn,
      "INSERT OR IGNORE INTO harness_health_recovery_warnings(holdId,reason,eventId,createdAt) VALUES(?1,?2,?3,?4)",
      [hold_id, reason, event_id, at]
    )

    if Txn.changes(txn) == 1 do
      EventLog.lifecycle_in_txn(
        txn,
        "harness_health_recovery_uncheckable",
        hold_id,
        JSON.encode!(%{holdId: hold_id, reason: reason, eventId: event_id})
      )
    end

    :ok
  end

  defp check_event_id(hold_id, cycle_id, route_key) do
    digest = :crypto.hash(:sha256, JSON.encode!([hold_id, cycle_id, route_key])) |> Base.url_encode64(padding: false)
    "harness-health-recovery-check:" <> digest
  end

  defp sanitize_excerpt(nil), do: nil

  defp sanitize_excerpt(value) do
    value
    |> to_string()
    |> ErrorDiagnostic.redact_text()
    |> String.slice(0, @error_limit)
  end

  defp diagnostic(reason), do: reason |> inspect() |> sanitize_excerpt()

  defp validate_schema!(txn) do
    checks =
      Txn.q(txn, "PRAGMA table_info(harness_health_recovery_checks)")
      |> Enum.map(fn [_cid, name | _rest] -> name end)

    warnings =
      Txn.q(txn, "PRAGMA table_info(harness_health_recovery_warnings)")
      |> Enum.map(fn [_cid, name | _rest] -> name end)

    unless checks == @checks_columns and warnings == @warnings_columns do
      raise ArgumentError, "incompatible harness health recovery check schema"
    end

    case Txn.q(
           txn,
           "SELECT 1 FROM sqlite_schema WHERE type='index' AND name='harness_health_recovery_check_cycle'"
         ) do
      [[1]] -> :ok
      _ -> raise ArgumentError, "harness health recovery check index is missing"
    end
  end
end
