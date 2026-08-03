defmodule Tightbeam.Soak do
  @moduledoc false

  alias Exqlite.Sqlite3

  @marker ".soak-arena"
  @owner "soak-driver"
  @stall_threshold_ms 180_000
  @recovery_threshold_ms 60_000
  @audit_interval_ms 10 * 60_000
  @kill_kinds [:adapter_sigkill, :gateway_sigterm, :gateway_sigkill, :cancel_turn]

  def main(argv) do
    options = parse_options(argv)

    # `mix run` starts the project application before evaluating a script.
    # The soak owns a separate gateway subprocess, so the implicit in-process
    # application must not remain as a second gateway during the run.
    _ = Application.stop(:tightbeam)
    {:ok, _} = Application.ensure_all_started(:inets)

    prepare_arena!(options.base_dir)

    try do
      state =
        options
        |> initial_state()
        |> start_gateway!()
        |> spawn_sessions!()
        |> run_schedule()

      {passed?, state} = audit(state, "final")
      stop_gateway(state.gateway, 10_000)
      Process.delete(:tightbeam_soak_gateway)
      if passed?, do: 0, else: 1
    after
      cleanup_gateway()
    end
  end

  defp parse_options(argv) do
    # `mix run script -- --flags` can deliver a LEADING literal "--" in
    # argv, and OptionParser treats it as the end-of-flags marker, demoting
    # every real flag to positional. Strip only that leading delimiter — a
    # later "--" is the CALLER'S end-of-options marker and must keep its
    # meaning (codex review finding: rejecting all of them silently
    # legalized flag-shaped positionals).
    argv =
      case argv do
        ["--" | rest] -> rest
        other -> other
      end

    {parsed, positional} =
      OptionParser.parse!(argv,
        strict: [
          minutes: :integer,
          port: :integer,
          base_dir: :string,
          kill_every: :integer,
          load_every: :integer,
          sessions: :integer,
          self_check: :boolean
        ]
      )

    if positional != [] do
      raise ArgumentError, "unexpected arguments: #{Enum.join(positional, " ")}"
    end

    self_check? = Keyword.get(parsed, :self_check, false)

    defaults = %{
      minutes: 60,
      port: 11_999,
      base_dir: Path.join(System.user_home!(), ".tightbeam-soak"),
      kill_every: 120,
      load_every: 20,
      sessions: 3,
      self_check: self_check?
    }

    options = Map.merge(defaults, Map.new(parsed))

    options =
      if self_check? do
        %{options | minutes: 2, sessions: 1, kill_every: 20, load_every: 5}
      else
        options
      end

    %{options | base_dir: Path.expand(options.base_dir)}
  end

  defp prepare_arena!(base_dir) do
    marker = Path.join(base_dir, @marker)

    case File.lstat(base_dir) do
      {:ok, %File.Stat{type: :directory}} ->
        unless File.regular?(marker) do
          raise "refusing base_dir #{base_dir}: existing directory lacks #{@marker}"
        end

        File.rm_rf!(base_dir)

      {:ok, _} ->
        raise "refusing base_dir #{base_dir}: path exists and is not a marked soak arena"

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise "cannot inspect base_dir #{base_dir}: #{:file.format_error(reason)}"
    end

    File.mkdir_p!(base_dir)
    File.write!(marker, "tightbeam soak arena v1\n")
    File.mkdir_p!(Path.join(base_dir, "auth"))
    File.mkdir_p!(Path.join(base_dir, "work"))

    auth_source = Path.join(System.user_home!(), ".tightbeam-beam/auth/claude")
    auth_target = Path.join([base_dir, "auth", "claude"])

    unless File.dir?(auth_source) do
      raise "Claude auth directory not found: #{auth_source}"
    end

    File.ln_s!(auth_source, auth_target)
  end

  defp initial_state(options) do
    now = monotonic_ms()

    %{
      options: options,
      gateway: nil,
      token: nil,
      sessions: [],
      next_session: 0,
      load_tick: 0,
      scheduled_wake_ids: [],
      load_errors: [],
      kill_events: [],
      kill_index: 0,
      started_at: now,
      deadline: now + options.minutes * 60_000,
      next_load: now,
      next_kill: now + options.kill_every * 1_000,
      next_audit: now + @audit_interval_ms
    }
  end

  defp start_gateway!(state) do
    case start_gateway(state) do
      {:ok, state} ->
        state

      {:error, reason, state} ->
        raise "gateway failed to boot on port #{state.options.port}: #{reason}"
    end
  end

  defp start_gateway(state) do
    mix = System.find_executable("mix") || raise "mix executable not found in PATH"
    base_dir = state.options.base_dir

    env = [
      {~c"TIGHTBEAM_BASE_DIR", String.to_charlist(base_dir)},
      {~c"TIGHTBEAM_PORT", Integer.to_charlist(state.options.port)},
      {~c"TIGHTBEAM_CWD", String.to_charlist(Path.join(base_dir, "work"))},
      {~c"TIGHTBEAM_DEFAULT_HARNESS", ~c"claude"},
      {~c"TIGHTBEAM_DEFAULT_MODEL", ~c"haiku"}
    ]

    port =
      Port.open({:spawn_executable, String.to_charlist(mix)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [~c"run", ~c"--no-halt"],
        cd: String.to_charlist(File.cwd!()),
        env: env
      ])

    Process.put(:tightbeam_soak_gateway, port)
    state = %{state | gateway: port, token: nil}

    case wait_for_version(state, @recovery_threshold_ms) do
      {:ok, _latency_ms, state} ->
        gateway_path = Path.join(base_dir, "gateway.json")
        %{"cliToken" => token} = gateway_path |> File.read!() |> JSON.decode!()
        {:ok, %{state | token: token}}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp spawn_sessions!(state) do
    Enum.reduce(1..state.options.sessions, state, fn index, state ->
      body = %{
        "verb" => "spawn",
        "asUser" => @owner,
        "params" => %{
          "displayName" => "Soak #{index}",
          "idempotencyKey" => "soak-session-#{index}",
          "archetype" => "default",
          "harness" => "claude",
          "model" => "haiku"
        }
      }

      case dispatch(state, body, 30_000) do
        {:ok, %{"result" => result}, state} ->
          session_key = result["sessionKey"] || get_in(result, ["stream", "sessionKey"])

          if is_binary(session_key) do
            log_event(state, "load session_spawn index=#{index} session=#{session_key}")
            %{state | sessions: state.sessions ++ [session_key]}
          else
            raise "spawn response omitted sessionKey: #{inspect(result)}"
          end

        {:error, reason, _state} ->
          raise "failed to spawn soak session #{index}: #{reason}"
      end
    end)
  end

  defp run_schedule(state) do
    cond do
      monotonic_ms() >= state.deadline ->
        state

      true ->
        state = drain_gateway_output(state)
        now = monotonic_ms()

        state =
          if now >= state.next_load do
            state
            |> send_load()
            |> Map.update!(:next_load, &(&1 + state.options.load_every * 1_000))
          else
            state
          end

        state =
          if kill_due?(state, now) do
            state
            |> perform_kill()
            |> Map.update!(:next_kill, &(&1 + state.options.kill_every * 1_000))
          else
            state
          end

        state =
          if now >= state.next_audit do
            {_passed?, state} = audit(state, "periodic")
            Map.update!(state, :next_audit, &(&1 + @audit_interval_ms))
          else
            state
          end

        Process.sleep(100)
        run_schedule(state)
    end
  end

  defp kill_due?(state, now) do
    now >= state.next_kill and
      (not state.options.self_check or state.kill_index < length(@kill_kinds))
  end

  defp send_load(state) do
    burst = if state.load_tick > 0 and rem(state.load_tick, 5) == 0, do: 3, else: 1
    mode = if rem(state.load_tick, 2) == 0, do: :direct, else: :scheduled_wake

    state =
      Enum.reduce(1..burst, state, fn _ordinal, state ->
        session_key = Enum.at(state.sessions, rem(state.next_session, length(state.sessions)))
        params = %{"prompt" => "Reply with one word."}
        params = if mode == :scheduled_wake, do: Map.put(params, "afterMs", 1_000), else: params

        body = %{
          "verb" => "wake",
          "sessionKey" => session_key,
          "asUser" => @owner,
          "params" => params
        }

        state = %{state | next_session: state.next_session + 1}
        track_wake_dispatch(state, body, "#{mode} session=#{session_key}")
      end)

    %{state | load_tick: state.load_tick + 1}
  end

  defp track_wake_dispatch(state, body, detail) do
    case dispatch(state, body, 10_000) do
      {:ok, %{"result" => %{"wakeId" => wake_id}}, state} ->
        log_event(state, "load #{detail} wake=#{wake_id}")
        %{state | scheduled_wake_ids: [wake_id | state.scheduled_wake_ids]}

      {:ok, response, state} ->
        error = "wake response omitted wakeId: #{inspect(response)}"
        log_event(state, "load_error #{detail} error=#{inspect(error)}")
        %{state | load_errors: [error | state.load_errors]}

      {:error, reason, state} ->
        error = "#{detail}: #{reason}"
        log_event(state, "load_error #{error}")
        %{state | load_errors: [error | state.load_errors]}
    end
  end

  defp perform_kill(state) do
    kind = Enum.at(@kill_kinds, rem(state.kill_index, length(@kill_kinds)))
    event_number = state.kill_index + 1
    started_wall = wall_ms()
    started_mono = monotonic_ms()
    log_event(state, "kill ##{event_number} kind=#{kind} start")

    {action_ok?, detail, state} = execute_kill(kind, state)

    {recovered?, recovery_ms, state, recovery_detail} =
      case wait_for_version(state, @recovery_threshold_ms) do
        {:ok, latency, state} ->
          {true, monotonic_ms() - started_mono, state, "version_ok poll=#{latency}ms"}

        {:error, reason, state} ->
          {false, monotonic_ms() - started_mono, state, reason}
      end

    event = %{
      number: event_number,
      kind: kind,
      timestamp_ms: started_wall,
      action_ok: action_ok?,
      detail: detail,
      recovered: recovered?,
      recovery_ms: recovery_ms,
      recovery_detail: recovery_detail
    }

    log_event(
      state,
      "kill ##{event_number} kind=#{kind} action_ok=#{action_ok?} recovered=#{recovered?} " <>
        "recovery_ms=#{recovery_ms} detail=#{inspect(detail)} recovery=#{inspect(recovery_detail)}"
    )

    %{state | kill_events: state.kill_events ++ [event], kill_index: state.kill_index + 1}
  end

  defp execute_kill(:adapter_sigkill, state) do
    with {:ok, gateway_pid} <- gateway_os_pid(state.gateway),
         [_ | _] = pids <- adapter_descendants(gateway_pid),
         pid <- Enum.random(pids),
         {_output, 0} <-
           System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true) do
      {true, "SIGKILL adapter pid=#{pid}", state}
    else
      [] -> {false, "no claude adapter subprocess found", state}
      {:error, reason} -> {false, inspect(reason), state}
      {output, status} -> {false, "kill exited #{status}: #{String.trim(output)}", state}
    end
  end

  defp execute_kill(:gateway_sigterm, state) do
    kill_and_restart_gateway(state, "-TERM")
  end

  defp execute_kill(:gateway_sigkill, state) do
    kill_and_restart_gateway(state, "-KILL")
  end

  defp execute_kill(:cancel_turn, state) do
    session_key = Enum.at(state.sessions, rem(state.next_session, length(state.sessions)))

    wake = %{
      "verb" => "wake",
      "sessionKey" => session_key,
      "asUser" => @owner,
      "params" => %{"prompt" => "Count from one to one hundred slowly, one number per line."}
    }

    state = track_wake_dispatch(state, wake, "cancel_probe session=#{session_key}")

    if wait_for_running_turn(state, session_key, 15_000) do
      cancel = %{
        "verb" => "cancel",
        "sessionKey" => session_key,
        "asUser" => @owner,
        "params" => %{}
      }

      case dispatch(state, cancel, 10_000) do
        {:ok, %{"result" => %{"ok" => true}}, state} ->
          {true, "canceled running turn session=#{session_key}", state}

        {:ok, response, state} ->
          {false, "cancel did not report success: #{inspect(response)}", state}

        {:error, reason, state} ->
          {false, "cancel failed: #{reason}", state}
      end
    else
      {false, "no running turn observed for cancel session=#{session_key}", state}
    end
  end

  defp kill_and_restart_gateway(state, signal) do
    with {:ok, pid} <- gateway_os_pid(state.gateway),
         {_output, 0} <-
           System.cmd("kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true),
         {:ok, status, state} <- await_gateway_exit(state, @recovery_threshold_ms) do
      Process.delete(:tightbeam_soak_gateway)
      state = %{state | gateway: nil, token: nil}

      case start_gateway(state) do
        {:ok, state} ->
          {true, "#{signal} gateway pid=#{pid} exit=#{status}", state}

        {:error, reason, state} ->
          {true, "#{signal} gateway pid=#{pid} exit=#{status}; restart pending: #{reason}", state}
      end
    else
      {:error, reason, state} -> {false, reason, state}
      {:error, reason} -> {false, inspect(reason), state}
      {output, status} -> {false, "kill exited #{status}: #{String.trim(output)}", state}
    end
  end

  defp wait_for_running_turn(state, session_key, timeout_ms) do
    deadline = monotonic_ms() + timeout_ms
    db_path = Path.join(state.options.base_dir, "state.db")

    wait_until(deadline, fn ->
      case readonly_query(
             db_path,
             "SELECT seq FROM turns WHERE sessionKey = ?1 AND status = 'running' LIMIT 1",
             [session_key]
           ) do
        [_row] -> true
        _ -> false
      end
    end)
  end

  defp wait_until(deadline, fun) do
    cond do
      fun.() ->
        true

      monotonic_ms() >= deadline ->
        false

      true ->
        Process.sleep(100)
        wait_until(deadline, fun)
    end
  end

  defp wait_for_version(state, timeout_ms) do
    started = monotonic_ms()
    deadline = started + timeout_ms
    do_wait_for_version(state, started, deadline, nil)
  end

  defp do_wait_for_version(state, started, deadline, last_error) do
    state = drain_gateway_output(state)

    case http(:get, state, "/version", nil, 2_000, false) do
      {:ok, 200, %{"protocolVersion" => 1}} ->
        {:ok, monotonic_ms() - started, state}

      result ->
        if monotonic_ms() < deadline do
          Process.sleep(250)
          do_wait_for_version(state, started, deadline, inspect(result))
        else
          {:error, "recovery threshold exceeded; last response #{last_error || inspect(result)}",
           state}
        end
    end
  end

  defp dispatch(state, body, timeout_ms) do
    case http(:post, state, "/agent/dispatch", body, timeout_ms, true) do
      {:ok, status, decoded} when status in 200..299 ->
        {:ok, decoded, drain_gateway_output(state)}

      {:ok, status, decoded} ->
        {:error, "HTTP #{status}: #{inspect(decoded)}", drain_gateway_output(state)}

      {:error, reason} ->
        {:error, inspect(reason), drain_gateway_output(state)}
    end
  end

  # curl instead of :httpc — this Erlang build's inets cannot load
  # :http_util, and curl is the transport every other tool in this repo
  # already trusts. -sS keeps errors on stderr; write-out isolates the
  # status code after the body.
  defp http(method, state, path, body, timeout_ms, authenticated?) do
    url = "http://127.0.0.1:#{state.options.port}#{path}"
    timeout_s = max(div(timeout_ms, 1000), 1)

    args =
      ["-sS", "--max-time", Integer.to_string(timeout_s), "-o", "-", "-w", "\n%{http_code}"] ++
        if(authenticated?, do: ["-H", "Authorization: Bearer #{state.token}"], else: []) ++
        # Unconditional, unlike the bearer: the wire refuses an unversioned caller before it
        # looks at authentication (42f7bd5), so an unauthenticated probe needs it too.
        ["-H", "x-tightbeam-cli-version: #{Tightbeam.CliCompatibility.required_version()}"] ++
        case method do
          :get -> [url]
          :post -> ["-X", "POST", "-H", "Content-Type: application/json", "-d", JSON.encode!(body), url]
        end

    case System.cmd("curl", args, stderr_to_stdout: true) do
      {output, 0} ->
        {payload, status_line} =
          case String.split(output, "\n") |> Enum.split(-1) do
            {head, [last]} -> {Enum.join(head, "\n"), last}
          end

        case Integer.parse(String.trim(status_line)) do
          {status, ""} ->
            decoded =
              case JSON.decode(payload) do
                {:ok, value} -> value
                _ -> payload
              end

            {:ok, status, decoded}

          _ ->
            {:error, "curl produced no status: #{String.slice(output, 0, 200)}"}
        end

      {output, _exit} ->
        {:error, String.trim(output)}
    end
  end

  defp await_gateway_exit(state, timeout_ms) do
    port = state.gateway
    deadline = monotonic_ms() + timeout_ms
    do_await_gateway_exit(state, port, deadline)
  end

  defp do_await_gateway_exit(state, port, deadline) do
    remaining = max(deadline - monotonic_ms(), 0)

    receive do
      {^port, {:data, data}} ->
        append_gateway_log(state, data)
        do_await_gateway_exit(state, port, deadline)

      {^port, {:exit_status, status}} ->
        {:ok, status, %{state | gateway: nil}}
    after
      min(remaining, 250) ->
        if monotonic_ms() >= deadline do
          {:error, "gateway did not exit within #{@recovery_threshold_ms}ms", state}
        else
          do_await_gateway_exit(state, port, deadline)
        end
    end
  end

  defp drain_gateway_output(%{gateway: nil} = state), do: state

  defp drain_gateway_output(state) do
    port = state.gateway

    receive do
      {^port, {:data, data}} ->
        append_gateway_log(state, data)
        drain_gateway_output(state)

      {^port, {:exit_status, status}} ->
        log_event(state, "gateway unexpected_exit status=#{status}")
        Process.delete(:tightbeam_soak_gateway)
        %{state | gateway: nil, token: nil}
    after
      0 -> state
    end
  end

  defp append_gateway_log(state, data) do
    File.write!(Path.join(state.options.base_dir, "gateway.log"), data, [:append, :binary])
  end

  defp gateway_os_pid(nil), do: {:error, "gateway is not running"}

  defp gateway_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> {:ok, pid}
      nil -> {:error, "gateway port has exited"}
    end
  end

  defp adapter_descendants(gateway_pid) do
    {output, 0} = System.cmd("ps", ["-axo", "pid=,ppid=,command="])

    processes =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(.*)$/, line) do
          [_, pid, parent, command] ->
            [{String.to_integer(pid), String.to_integer(parent), command}]

          _ ->
            []
        end
      end)

    descendants = descendant_ids(processes, MapSet.new([gateway_pid]))

    processes
    |> Enum.filter(fn {pid, _parent, command} ->
      MapSet.member?(descendants, pid) and String.contains?(command, "claude-agent-acp")
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp descendant_ids(processes, ids) do
    expanded =
      Enum.reduce(processes, ids, fn {pid, parent, _command}, acc ->
        if MapSet.member?(ids, parent), do: MapSet.put(acc, pid), else: acc
      end)

    if MapSet.size(expanded) == MapSet.size(ids),
      do: expanded,
      else: descendant_ids(processes, expanded)
  end

  defp audit(state, label) do
    db_path = Path.join(state.options.base_dir, "state.db")

    checks =
      try do
        {:ok, conn} = Sqlite3.open(db_path, mode: :readonly)

        try do
          [
            audit_a1(conn),
            audit_a2(conn),
            audit_a3(conn, state),
            audit_a4(conn, state),
            audit_a5(state)
          ]
        after
          :ok = Sqlite3.close(conn)
        end
      rescue
        exception ->
          detail = Exception.format(:error, exception, __STACKTRACE__)

          for id <- ~w(A1 A2 A3 A4 A5) do
            {id, false, ["audit unavailable: #{detail}"]}
          end
      end

    IO.puts("\nSOAK SCORECARD #{label} #{timestamp()}")

    Enum.each(checks, fn {id, passed?, offenders} ->
      IO.puts("#{id} #{if passed?, do: "PASS", else: "FAIL"}")
      Enum.each(offenders, &IO.puts("  #{inspect(&1, pretty: true, limit: :infinity)}"))
    end)

    passed? = Enum.all?(checks, &elem(&1, 1))
    IO.puts("VERDICT #{if passed?, do: "PASS", else: "FAIL"}\n")
    log_event(state, "audit label=#{label} verdict=#{if passed?, do: "PASS", else: "FAIL"}")
    {passed?, state}
  end

  defp audit_a1(conn) do
    cutoff = wall_ms() - @stall_threshold_ms

    offenders =
      query(
        conn,
        """
        SELECT seq, sessionKey, status, createdAt, startedAt
        FROM turns
        WHERE status IN ('queued','running') AND createdAt < ?1
        ORDER BY seq
        """,
        [cutoff]
      )

    {"A1", offenders == [], offenders}
  end

  defp audit_a2(conn) do
    missing_or_bad_echo =
      query(conn, """
      SELECT t.seq, t.messageId, COUNT(m.id) AS echoCount
      FROM turns t
      LEFT JOIN messages m ON m.id = t.messageId AND m.role = 'user'
      GROUP BY t.seq, t.messageId
      HAVING echoCount != 1
      ORDER BY t.seq
      """)

    delivered_without_one_assistant =
      query(conn, """
      SELECT t.seq, t.messageId, COUNT(m.id) AS assistantCount
      FROM turns t
      LEFT JOIN messages m
        ON m.replyToMessageId = t.messageId AND m.role = 'assistant'
      WHERE t.status = 'delivered'
      GROUP BY t.seq, t.messageId
      HAVING assistantCount != 1
      ORDER BY t.seq
      """)

    orphan_replies =
      query(conn, """
      SELECT m.id, m.replyToMessageId
      FROM messages m
      LEFT JOIN turns t ON t.messageId = m.replyToMessageId
      WHERE m.role = 'assistant'
        AND m.replyToMessageId IS NOT NULL
        AND t.seq IS NULL
      ORDER BY m.seq
      """)

    duplicate_wakes =
      query(conn, """
      SELECT wakeId, COUNT(*)
      FROM turns
      WHERE wakeId IS NOT NULL
      GROUP BY wakeId
      HAVING COUNT(*) > 1
      """)

    offenders =
      Enum.map(missing_or_bad_echo, &{:echo, &1}) ++
        Enum.map(delivered_without_one_assistant, &{:assistant, &1}) ++
        Enum.map(orphan_replies, &{:orphan_reply, &1}) ++
        Enum.map(duplicate_wakes, &{:duplicate_wake, &1})

    {"A2", offenders == [], offenders}
  end

  defp audit_a3(conn, state) do
    failed_without_reason =
      query(conn, """
      SELECT seq, sessionKey, status, error
      FROM turns
      WHERE status IN ('failed','failed_unknown')
        AND (error IS NULL OR trim(error) = '')
      ORDER BY seq
      """)

    adapter_kills = Enum.count(state.kill_events, &(&1.kind == :adapter_sigkill and &1.action_ok))

    adapter_deaths =
      query(conn, """
      SELECT id, ts, kind, subject, detail
      FROM lifecycle_events
      WHERE kind = 'adapter_down'
      ORDER BY id
      """)

    lifecycle_offenders =
      if length(adapter_deaths) >= adapter_kills do
        []
      else
        [{:adapter_deaths, %{expected: adapter_kills, observed: adapter_deaths}}]
      end

    offenders =
      Enum.map(failed_without_reason, &{:failure_without_reason, &1}) ++ lifecycle_offenders

    {"A3", offenders == [], offenders}
  end

  defp audit_a4(conn, state) do
    wake_offenders =
      state.scheduled_wake_ids
      |> Enum.uniq()
      |> Enum.flat_map(fn wake_id ->
        rows =
          query(
            conn,
            """
            SELECT w.wakeId, w.state, t.seq,
                   EXISTS(
                     SELECT 1 FROM lifecycle_events l
                     WHERE l.kind = 'wake_unresolved' AND l.subject = w.wakeId
                   ) AS unresolved
            FROM wakes w
            LEFT JOIN turns t ON t.wakeId = w.wakeId
            WHERE w.wakeId = ?1
            """,
            [wake_id]
          )

        case rows do
          [[^wake_id, "pending", _seq, _unresolved]] -> []
          [[^wake_id, "fired", seq, _unresolved]] when not is_nil(seq) -> []
          [[^wake_id, _state, _seq, unresolved]] when unresolved == 1 -> []
          [row] -> [{:wake_unaccounted, row}]
          [] -> [{:wake_missing, wake_id}]
        end
      end)

    offenders = wake_offenders ++ Enum.map(state.load_errors, &{:load_error, &1})
    {"A4", offenders == [], offenders}
  end

  defp audit_a5(state) do
    event_offenders =
      Enum.flat_map(state.kill_events, fn event ->
        if event.action_ok and event.recovered and event.recovery_ms <= @recovery_threshold_ms do
          []
        else
          [event]
        end
      end)

    missing_kinds =
      if state.options.self_check do
        observed = MapSet.new(state.kill_events, & &1.kind)

        @kill_kinds
        |> Enum.reject(&MapSet.member?(observed, &1))
        |> Enum.map(&{:missing_self_check_kill, &1})
      else
        []
      end

    offenders = event_offenders ++ missing_kinds
    {"A5", offenders == [], offenders}
  end

  defp readonly_query(path, sql, params) do
    case Sqlite3.open(path, mode: :readonly) do
      {:ok, conn} ->
        try do
          query(conn, sql, params)
        after
          :ok = Sqlite3.close(conn)
        end

      {:error, _reason} ->
        []
    end
  end

  defp query(conn, sql, params \\ []) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      collect_rows(conn, statement, [])
    after
      :ok = Sqlite3.release(conn, statement)
    end
  end

  defp collect_rows(conn, statement, rows) do
    case Sqlite3.step(conn, statement) do
      {:row, row} -> collect_rows(conn, statement, [row | rows])
      :done -> Enum.reverse(rows)
      {:error, reason} -> raise "sqlite query failed: #{inspect(reason)}"
    end
  end

  defp stop_gateway(nil, _timeout_ms), do: :ok

  defp stop_gateway(port, timeout_ms) do
    case gateway_os_pid(port) do
      {:ok, pid} ->
        _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
        deadline = monotonic_ms() + timeout_ms

        unless wait_for_port_exit(port, deadline) do
          _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
          _ = wait_for_port_exit(port, monotonic_ms() + 5_000)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp wait_for_port_exit(port, deadline) do
    receive do
      {^port, {:data, _data}} -> wait_for_port_exit(port, deadline)
      {^port, {:exit_status, _status}} -> true
    after
      100 ->
        if monotonic_ms() >= deadline, do: false, else: wait_for_port_exit(port, deadline)
    end
  end

  defp cleanup_gateway do
    case Process.get(:tightbeam_soak_gateway) do
      port when is_port(port) -> stop_gateway(port, 2_000)
      _ -> :ok
    end

    Process.delete(:tightbeam_soak_gateway)
  end

  defp log_event(state, message) do
    line = "#{timestamp()} #{message}"
    IO.puts(line)
    File.write!(Path.join(state.options.base_dir, "soak-events.log"), line <> "\n", [:append])
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp wall_ms, do: System.system_time(:millisecond)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end

exit_status =
  try do
    Tightbeam.Soak.main(System.argv())
  rescue
    exception ->
      IO.puts(:stderr, Exception.format(:error, exception, __STACKTRACE__))
      1
  end

System.halt(exit_status)