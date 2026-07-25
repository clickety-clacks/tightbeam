defmodule Tightbeam.Placement do
  @moduledoc """
  Placement mechanics (spec §Placement) — the ONE module that knows hosts
  exist. Everything else addresses identity; this module turns a host NAME
  into an adapter command, a delivered shared home, and an allow/deny answer.

  Hosts are INSTANCE CONFIG, never DB rows: `Application.get_env(:tightbeam,
  :hosts)` maps name => %{ssh: destination-or-nil, base_dir: path, cli_bin:
  path-or-nil}. The gateway's own machine is always registered under its
  REAL hostname (`local_host_name/0`; ssh: nil) — never under an indexical
  like "local", because the org's vocabulary must match the operator's
  ("spawn on eezo" has to resolve on eezo, including on eezo itself). Which
  machine is local is carried by `ssh: nil`, not by a special name. Host
  names are what archetype `where` lists and session rows refer to; the ssh
  destination is how to reach one. WHY a host set contains what it does is
  the operator's statute — nothing here hardcodes a topology.

  Four responsibilities, each a pure-ish function:

  1. `resolve/2` — the CONSTITUTIONAL check (set membership of data against
     data, no rule engine): a spawn/tune host must be a member of the
     archetype's `where` AND a configured host. Nil host resolves to the
     FIRST element of `where` (deterministic; richer choice — least-loaded,
     failover — is a resolver rail, later). Denials return the map Dispatch
     expects (%{code: ...}), citing what was denied and the allowed set, so
     agents learn the law by hitting it.

  2. `adapter_opts/2` — build the Acp.Adapter start opts for an adapter key
     {harness, "shared", host}:
     - local: exactly the previous behavior (local binary path, local home
       from Homes.project, env in the local Port).
     - remote: cmd is SSH-WRAPPED — ["ssh", dest, "exec", "env", "K=V"...,
       binary] — because a remote process ignores the local Port env, ALL
       agent env (harness home var, TIGHTBEAM_URL, PATH with the
       remote cli_bin) is embedded in the remote command line. The home var
       points at the REMOTE home path (remote base_dir). stderr_path stays
       LOCAL and unchanged: the Conn's `sh -c '... 2>>log'` wraps the ssh
       client, so remote stderr rides the ssh connection into the local log.
       The advertised URL (config :tightbeam, :advertised_url) is used for
       TIGHTBEAM_URL — never 127.0.0.1 — so the session-file-aware CLI reaches
       the gateway over the network; the org token is never placed in remote env.

  3. `deliver_home/3` — materialize the generic `{harness, machine}` home on
     the session's host. Regeneration owns only the credential entry, rails
     artifact, and `.tightbeam/`; every other harness-owned byte survives.
     Remote regeneration follows the same stop, harvest, replace, and relink
     order without ever deleting the home. Credentials remain host-local.

     `materialize_identity/4` separately projects elected skills into the
     exact session cwd and writes the reserved git exclusion only when that
     cwd is itself a repository checkout.
     Shell execution goes through an injectable runner (`:sh` opt, default
     System.cmd) so tests capture command lines instead of running ssh —
     same pattern as ConnRegistry's injected deliver.

  4. `move_workdir/4` — carry a session's durable scratch when placement
     changes. Local copies use File.cp_r!; remote legs use gateway-originated
     rsync, and remote→remote stages through the gateway because rsync's
     source-host hop is unsupported. Missing source means a fresh session;
     every other failure is returned so the caller can refuse the host write
     rather than silently strand memory.

  Failure posture: deliver_home raising fails the adapter start, which the
  AdapterCoordinator already treats as a failed start (backoff, circuit) —
  an unreachable host degrades exactly like a dead adapter, per spec.
  """

  alias Tightbeam.{Archetypes, Containment, Harness, Homes, Identity, Org, Rails}
  import Bitwise

  # Non-interactive, bounded ssh everywhere placement reaches out: a dead or
  # misconfigured host must fail in seconds with a reason, never hang on TCP
  # timeouts or an invisible password prompt.
  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]

  @typedoc "A configured host. ssh: nil marks the reserved local host."
  @type host_config :: %{
          required(:ssh) => String.t() | nil,
          required(:base_dir) => String.t(),
          optional(:cli_bin) => String.t() | nil
        }

  @typedoc "Adapter key. The reserved identity `shared` is the one runtime per harness+host."
  @type adapter_key :: {harness :: atom(), archetype :: String.t(), host :: String.t()}

  @doc """
  The known hosts map with the gateway's own machine always present under
  `local_host_name/0` (ssh: nil, base_dir = the gateway's base_dir). Merge
  order, weakest first: the instance registry (`<base_dir>/hosts.json`,
  written only by `register_host/3` — the register-host verb's recorder),
  then env config (:tightbeam, :hosts — a deploy-time override), then the
  gateway's own entry. Nothing may redefine the gateway's own entry.
  """
  @spec hosts(String.t()) :: %{optional(String.t()) => host_config()}
  def hosts(base_dir) do
    registry_hosts(base_dir)
    |> Map.merge(Application.get_env(:tightbeam, :hosts, %{}))
    |> Map.put(local_host_name(), %{ssh: nil, base_dir: base_dir, cli_bin: nil})
  end

  @doc """
  The gateway machine's registered name — its real hostname (override:
  :local_host_name config / TIGHTBEAM_LOCAL_HOST_NAME). This is a NAME, not
  a role: it participates in `where` sets, session rows, and displays like
  any other host's.
  """
  @spec local_host_name() :: String.t()
  def local_host_name do
    Application.get_env(:tightbeam, :local_host_name) ||
      (
        {:ok, name} = :inet.gethostname()
        List.to_string(name)
      )
  end

  @doc """
  Resolve and ensure a holder session's workdir on its configured host.

  Every session works in its own directory on its host, never the operator's
  home and never a shared directory. The workdir also carries the session's
  durable scratch across engine swaps.
  """
  @spec holder_workdir(map(), map()) :: String.t()
  def holder_workdir(config, holder_session) do
    host = hosts(config.base_dir)[holder_session.host] || %{ssh: nil, base_dir: config.base_dir}
    path = workdir_path(config, holder_session)

    url =
      if host.ssh == nil,
        do: "http://127.0.0.1:#{config.port}",
        else: Application.fetch_env!(:tightbeam, :advertised_url)

    content =
      JSON.encode!(%{
        url: url,
        token: holder_session.cli_token,
        sessionKey: holder_session.session_key
      })

    ensure_opts = [base_dir: config.base_dir]
    ensure_opts = if config[:sh], do: Keyword.put(ensure_opts, :sh, config.sh), else: ensure_opts

    ensure_opts =
      if config[:sh_out], do: Keyword.put(ensure_opts, :sh_out, config.sh_out), else: ensure_opts

    ensure_workdir(host, path, content, ensure_opts)
    path
  end

  @doc "Materialize one already-resolved identity snapshot at the session's exact cwd."
  @spec materialize_identity(map(), map(), Identity.snapshot(), keyword()) :: Identity.snapshot()
  def materialize_identity(config, session, snapshot, opts \\ []) do
    host = Map.fetch!(hosts(config.base_dir), session.host)
    cwd = holder_workdir(config, session)
    materialize_identity(config, host, session, snapshot, cwd, opts)
  end

  defp materialize_identity(config, host, session, snapshot, cwd, opts) do
    module = Harness.parse!(session.harness)
    sh = Keyword.get(opts, :sh, Map.get(config, :sh, &system_cmd/1))

    module.materialize_skills(
      %{
        base_dir: config.base_dir,
        host_config: host,
        host_name: session.host,
        session_key: session.session_key,
        sh: sh
      },
      cwd,
      snapshot
    )
  end

  @doc "Derive a session's durable workspace path without creating it."
  @spec workdir_path(map(), map()) :: String.t()
  def workdir_path(config, session) do
    host = hosts(config.base_dir)[session.host] || %{base_dir: config.base_dir}

    digest =
      :crypto.hash(:sha256, session.session_key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    Path.join([host.base_dir, "work", digest])
  end

  @doc """
  Read the observable git state for an assignment root without creating it.

  Local and satellite holders use the same bounded shell probe. The returned
  manifest is repository-scoped and retains the sorted untracked name list.
  """
  @spec effort_manifest(map(), map(), String.t(), term()) ::
          {:ok, map()} | {:error, String.t()}
  def effort_manifest(config, session, root, baseline \\ nil) do
    case Map.get(config, :effort_probe) do
      fun when is_function(fun, 3) ->
        fun.(session, root, config)

      _ ->
        host = Map.fetch!(hosts(config.base_dir), session.host)
        command = effort_manifest_command(root, baseline)
        runner = Map.get(config, :sh, &system_cmd/1)

        invocation =
          if host.ssh == nil do
            ["sh", "-lc", command]
          else
            ["ssh" | @ssh_opts] ++ [host.ssh, "sh", "-lc", shell_quote(command)]
          end

        result =
          if host.ssh == nil do
            run_probe(runner, invocation)
          else
            run_bounded(
              runner,
              invocation,
              Map.get(config, :effort_probe_timeout_ms, 8_000)
            )
          end

        case result do
          {:ok, output} -> parse_effort_manifest(output)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Record (or update) a host in the instance registry — the DUMB half of
  assimilation: the CLI ceremony prepares the machine; this writes the fact.
  Admin gating happens in the verb handler, not here. Returns the stored
  config.
  """
  @spec register_host(String.t(), String.t(), host_config()) :: {:ok, host_config()}
  def register_host(base_dir, name, config) do
    entry = %{
      ssh: Map.fetch!(config, :ssh),
      base_dir: Map.fetch!(config, :base_dir),
      cli_bin: Map.get(config, :cli_bin),
      adapter_bin_dir: Map.get(config, :adapter_bin_dir)
    }

    path = registry_path(base_dir)
    updated = Map.put(read_registry(path), name, entry)
    File.write!(path, JSON.encode!(updated))
    {:ok, entry}
  end

  defp registry_path(base_dir), do: Path.join(base_dir, "hosts.json")

  defp effort_manifest_command(root, baseline) do
    quoted_root = shell_quote(root)

    baseline_cases =
      case baseline do
        {:ok, %{repos: repos}} ->
          Enum.map_join(repos, "\n", fn repo ->
            "        #{shell_quote(repo.path)}) baseline=#{shell_quote(repo.head)} ;;"
          end)

        _ ->
          ""
      end

    """
    set -eu
    root=#{quoted_root}
    test -d "$root"
    dotgits=$(find "$root" -name .git -print -prune)
    test -n "$dotgits"
    printf '%s\\n' "$dotgits" | while IFS= read -r dotgit; do
      repo=${dotgit%/.git}
      rel=${repo#"$root"}
      rel=${rel#/}
      test -n "$rel" || rel=.
      head=$(git -C "$repo" rev-parse HEAD)
      effort_index=$(mktemp)
      trap 'rm -f "$effort_index"' EXIT HUP INT TERM
      source_index=$(git -C "$repo" rev-parse --git-path index)
      case "$source_index" in
        /*) ;;
        *) source_index="$repo/$source_index" ;;
      esac
      cp "$source_index" "$effort_index"
      GIT_INDEX_FILE="$effort_index" git -C "$repo" add -u -- .
      tracked=$(GIT_INDEX_FILE="$effort_index" git -C "$repo" write-tree)
      rm -f "$effort_index"
      baseline=
      case "$rel" in
    #{baseline_cases}
        *) ;;
      esac
      new_commit=0
      if test -n "$baseline" && test "$head" != "$baseline"; then
        if ! git -C "$repo" merge-base --is-ancestor "$head" "$baseline"; then
          new_commit=1
        fi
      fi
      printf 'R\\t%s\\t%s\\t%s\\t%s\\n' "$rel" "$head" "$tracked" "$new_commit"
      untracked=$(git -C "$repo" ls-files --others)
      test -z "$untracked" || printf '%s\\n' "$untracked" | while IFS= read -r name; do
        if test "$rel" = .; then full="$name"; else full="$rel/$name"; fi
        printf 'U\\t%s\\n' "$full"
      done
    done
    """
  end

  defp parse_effort_manifest(output) do
    {repos, untracked} =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce({[], []}, fn line, {repos, untracked} ->
        case String.split(line, "\t") do
          ["R", path, head, tracked, new_commit] ->
            {[
               %{
                 path: path,
                 head: head,
                 tracked: tracked,
                 new_commit: new_commit == "1"
               }
               | repos
             ], untracked}

          ["R", path, head, tracked] ->
            {[
               %{path: path, head: head, tracked: tracked, new_commit: false}
               | repos
             ], untracked}

          ["U", name] ->
            {repos, [name | untracked]}

          _ ->
            {repos, untracked}
        end
      end)

    if repos == [] do
      {:error, "no git repository under effort root"}
    else
      {:ok,
       %{
         repos: Enum.sort_by(repos, & &1.path),
         untracked: Enum.sort(Enum.uniq(untracked))
       }}
    end
  end

  defp run_bounded(runner, invocation, timeout_ms) do
    caller = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            case runner.(invocation) do
              {output, 0} -> {:ok, output}
              {output, status} -> {:error, "probe exited #{status}: #{String.trim(output)}"}
            end
          rescue
            error -> {:error, "probe failed: #{Exception.message(error)}"}
          catch
            kind, reason -> {:error, "probe failed: #{kind}: #{inspect(reason)}"}
          end

        send(caller, {tag, result})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, "probe failed: #{Exception.format_exit(reason)}"}
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end

        {:error, "probe timed out"}
    end
  end

  defp run_probe(runner, invocation) do
    try do
      case runner.(invocation) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, "probe exited #{status}: #{String.trim(output)}"}
      end
    rescue
      error -> {:error, "probe failed: #{Exception.message(error)}"}
    catch
      kind, reason -> {:error, "probe failed: #{kind}: #{inspect(reason)}"}
    end
  end

  defp registry_hosts(base_dir) do
    base_dir |> registry_path() |> read_registry()
  end

  defp read_registry(path) do
    case File.read(path) do
      {:ok, raw} ->
        for {name, h} <- JSON.decode!(raw), into: %{} do
          {name,
           %{
             ssh: h["ssh"],
             base_dir: h["base_dir"],
             cli_bin: h["cli_bin"],
             adapter_bin_dir: h["adapter_bin_dir"]
           }}
        end

      {:error, :enoent} ->
        %{}
    end
  end

  @doc "Ensure a session workdir and its converged credential file."
  @spec ensure_workdir(host_config(), String.t(), String.t(), keyword()) :: :ok
  def ensure_workdir(%{ssh: nil}, path, content, _opts) do
    File.mkdir_p!(path)
    file = Path.join(path, ".tightbeam-session")

    current = if File.exists?(file), do: File.read!(file), else: nil
    mode = if File.exists?(file), do: File.stat!(file).mode &&& 0o777, else: nil

    if current != content or mode != 0o600 do
      File.write!(file, content)
      File.chmod!(file, 0o600)
    end

    heal_git_exclude(path)
    :ok
  end

  def ensure_workdir(%{ssh: dest}, path, content, opts) do
    sh = Keyword.get(opts, :sh, &system_cmd/1)
    sh_out = Keyword.get(opts, :sh_out, &system_cmd_out/1)
    file = Path.join(path, ".tightbeam-session")

    script =
      "mkdir -p #{path} && " <>
        "{ find #{file} -maxdepth 0 -perm 600 -print 2>/dev/null | grep -q . && cat #{file} 2>/dev/null; true; } && " <>
        "if [ -d #{path}/.git/info ]; then " <>
        "grep -qxF .tightbeam-session #{path}/.git/info/exclude 2>/dev/null || " <>
        ~s(printf "\\n%s\\n" .tightbeam-session >> #{path}/.git/info/exclude; fi)

    {current, code} =
      sh_out.(["ssh" | @ssh_opts] ++ [dest, "sh", "-c", shell_quote(script)])

    if code != 0, do: raise("remote workdir ensure failed (#{dest}): #{path}")

    if current != content do
      digest = Path.basename(path)
      stage = Path.join([Keyword.fetch!(opts, :base_dir), "staging", "session-files", digest])
      stage_file = Path.join(stage, ".tightbeam-session")
      File.mkdir_p!(stage)

      try do
        File.write!(stage_file, content)
        File.chmod!(stage_file, 0o600)

        run!(sh, [
          "rsync",
          "-a",
          "-e",
          Enum.join(["ssh" | @ssh_opts], " "),
          stage_file,
          "#{dest}:#{path}/"
        ])
      after
        File.rm_rf!(stage)
      end
    end

    :ok
  end

  defp heal_git_exclude(path) do
    info = Path.join([path, ".git", "info"])

    if File.dir?(info) do
      exclude = Path.join(info, "exclude")
      existing = if File.exists?(exclude), do: File.read!(exclude), else: ""
      lines = String.split(existing, "\n")

      if ".tightbeam-session" not in lines do
        separator = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
        File.write!(exclude, existing <> separator <> ".tightbeam-session\n")
      end
    end
  end

  @doc """
  Move a session workdir between configured hosts. The host names are
  resolved from `config.base_dir`; `config.sh` may inject the same argv
  runner used by home delivery. Returns `{:error, message}` on every copy or
  command failure so `tune set_host` can fail closed before changing Org.
  """
  @spec move_workdir(map(), String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def move_workdir(config, session_key, old_host_name, new_host_name) do
    try do
      configured_hosts = hosts(config.base_dir)
      old_host = Map.fetch!(configured_hosts, old_host_name)
      new_host = Map.fetch!(configured_hosts, new_host_name)
      source = host_workdir_path(old_host, session_key)
      destination = host_workdir_path(new_host, session_key)
      sh = Map.get(config, :sh) || (&system_cmd/1)

      if source != destination do
        move_workdir(sh, config.base_dir, old_host, source, new_host, destination)
      end

      :ok
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  defp move_workdir(_sh, _base_dir, %{ssh: nil}, source, %{ssh: nil}, destination) do
    if File.dir?(source) do
      File.mkdir_p!(Path.dirname(destination))
      File.cp_r!(source, destination)
    end

    ensure_local_token_absent!(source)
  end

  defp move_workdir(sh, _base_dir, %{ssh: nil}, source, %{ssh: destination_host}, destination) do
    if File.dir?(source) do
      run!(sh, ["ssh" | @ssh_opts] ++ [destination_host, "mkdir", "-p", destination])

      run!(sh, [
        "rsync",
        "-a",
        "-e",
        Enum.join(["ssh" | @ssh_opts], " "),
        source <> "/",
        "#{destination_host}:#{destination}/"
      ])
    end

    ensure_local_token_absent!(source)
  end

  defp move_workdir(sh, _base_dir, %{ssh: source_host}, source, %{ssh: nil}, destination) do
    if remote_dir?(sh, source_host, source) do
      File.mkdir_p!(destination)

      run!(sh, [
        "rsync",
        "-a",
        "-e",
        Enum.join(["ssh" | @ssh_opts], " "),
        "#{source_host}:#{source}/",
        destination <> "/"
      ])
    end

    ensure_remote_token_absent!(sh, source_host, source)
  end

  defp move_workdir(
         sh,
         base_dir,
         %{ssh: source_host},
         source,
         %{ssh: destination_host},
         destination
       ) do
    if remote_dir?(sh, source_host, source) do
      digest = Path.basename(source)
      stage = Path.join([base_dir, "staging", "workdir-moves", digest])
      File.mkdir_p!(stage)

      try do
        run!(sh, [
          "rsync",
          "-a",
          "-e",
          Enum.join(["ssh" | @ssh_opts], " "),
          "#{source_host}:#{source}/",
          stage <> "/"
        ])

        run!(sh, ["ssh" | @ssh_opts] ++ [destination_host, "mkdir", "-p", destination])

        run!(sh, [
          "rsync",
          "-a",
          "-e",
          Enum.join(["ssh" | @ssh_opts], " "),
          stage <> "/",
          "#{destination_host}:#{destination}/"
        ])
      after
        File.rm_rf!(stage)
      end
    end

    ensure_remote_token_absent!(sh, source_host, source)
  end

  defp ensure_local_token_absent!(source) do
    case File.rm(Path.join(source, ".tightbeam-session")) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise "source session token removal failed: #{inspect(reason)}"
    end
  end

  defp ensure_remote_token_absent!(sh, host, source) do
    run!(sh, ["ssh" | @ssh_opts] ++ [host, "rm", "-f", Path.join(source, ".tightbeam-session")])
  end

  defp remote_dir?(sh, host, path) do
    case sh.(["ssh" | @ssh_opts] ++ [host, "test", "-d", path]) do
      {_output, 0} -> true
      {_output, 1} -> false
      {_output, exit} -> raise "remote workdir check failed with exit #{exit}: #{host}:#{path}"
    end
  end

  defp host_workdir_path(host, session_key) do
    digest =
      :crypto.hash(:sha256, session_key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    Path.join([host.base_dir, "work", digest])
  end

  @doc """
  Resolve + constitutionally check a requested host for an archetype.
  nil → first of archetype.where. `where = ["*"]` grants ANYWHERE: any
  configured host is allowed and nil resolves to the gateway's own host (an
  explicit grant only — an empty where is an error at load, never a grant;
  law fails closed). Denies (never raises) with %{code: "host_not_allowed", message:
  names the host and the allowed set} when host ∉ archetype.where, and
  %{code: "unknown_host", message: ...} when host has no config entry.
  """
  @spec resolve(Archetypes.t(), String.t() | nil, %{optional(String.t()) => host_config()}) ::
          {:ok, String.t()} | {:error, %{code: String.t(), message: String.t()}}
  def resolve(archetype, requested_host, hosts) do
    anywhere? = archetype.where == ["*"]

    host =
      requested_host || if(anywhere?, do: local_host_name(), else: hd(archetype.where))

    cond do
      not anywhere? and host not in archetype.where ->
        {:error,
         %{
           code: "host_not_allowed",
           message:
             "host #{host} is not allowed; allowed hosts: #{Enum.join(archetype.where, ", ")}"
         }}

      not Map.has_key?(hosts, host) ->
        {:error, %{code: "unknown_host", message: "host #{host} is not configured"}}

      true ->
        {:ok, host}
    end
  end

  @doc """
  Build Acp.Adapter start opts for an adapter key per the moduledoc.
  `config` is the Gateway config map (base_dir, cwd, …). Local keys must
  produce exactly the pre-placement behavior. Calls deliver_home/3.
  """
  @spec adapter_opts(map(), adapter_key()) :: keyword()
  def adapter_opts(config, {harness, identity_name, host} = key) do
    module = Harness.module!(harness)

    lineage =
      "tb1-" <> Base.url_encode64("#{harness}@#{host}", padding: false)

    host_config = Map.fetch!(hosts(config.base_dir), host)
    sh = Map.get(config, :sh, &system_cmd/1)

    target = %{
      base_dir: config.base_dir,
      host_config: host_config,
      host_name: host,
      sh: sh,
      cli_bin: config.cli_bin
    }

    contained? = contained_runtime?(config, identity_name)

    if contained? and host_config.ssh != nil do
      containment_refused!(config, key, "contained_remote_unsupported")
    end

    deliver_opts = if config[:sh], do: [sh: config.sh], else: []
    home = deliver_home(config, key, deliver_opts)

    stderr_path =
      Path.join(config.base_dir, "adapter-#{harness}:#{identity_name}@#{host}.stderr.log")

    common_env = [
      {"TIGHTBEAM_HOME", config.base_dir},
      {"TIGHTBEAM_MACHINE", host},
      {"PATH", config.cli_bin <> ":" <> (System.get_env("PATH") || "")},
      {"TIGHTBEAM_LINEAGE", lineage}
    ]

    remote_env =
      if host_config.ssh do
        [
          "TIGHTBEAM_HOME=#{host_config.base_dir}",
          "TIGHTBEAM_MACHINE=#{host}",
          "TIGHTBEAM_URL=#{Application.fetch_env!(:tightbeam, :advertised_url)}",
          "PATH=#{host_config[:cli_bin] || ""}:$PATH",
          "TIGHTBEAM_LINEAGE=#{lineage}"
        ]
      else
        []
      end

    plan =
      module.prepare_launch(target, home,
        common_env: common_env,
        remote_env: remote_env,
        lineage: lineage,
        rails: Rails.hook_settings(),
        ensure_workdir: &ensure_workdir/4,
        sh_out: Map.get(config, :sh_out)
      )

    opts =
      [
        harness: harness,
        home: home,
        cwd: config.cwd,
        stderr_path: stderr_path,
        on_auth_event: auth_event_handler(host, module),
        on_subagent_event: subagent_event_handler(config, host, module),
        env: []
      ]
      |> Keyword.merge(plan)

    if contained? do
      write_roots = [
        Path.join(host_config.base_dir, "work"),
        home,
        Tightbeam.Credentials.store_dir(
          host_config.base_dir,
          module.credential_provider()
        )
      ]

      probe_result =
        try do
          sh.(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true"])
        rescue
          error -> {:raised, error}
        end

      case probe_result do
        {:raised, error} ->
          containment_refused!(
            config,
            key,
            "sandbox-exec probe failed: #{Exception.message(error)}"
          )

        {_output, 0} ->
          :ok

        {_output, exit} ->
          containment_refused!(config, key, "sandbox-exec probe failed with exit #{exit}")
      end

      profile =
        try do
          Containment.profile(write_roots)
        rescue
          error in [ArgumentError] ->
            containment_refused!(config, key, Exception.message(error))
        end

      [binary] = Keyword.fetch!(opts, :cmd)

      Tightbeam.EventLog.lifecycle(
        config.db,
        "containment",
        adapter_key_name(key),
        "assembled; fs=workdir network=open; write-roots=#{Enum.join(write_roots, ",")}"
      )

      opts
      |> Keyword.put(:cmd, ["/usr/bin/sandbox-exec", "-p", profile, binary])
      |> Keyword.put(:contained, true)
    else
      opts
    end
  end

  @doc "Derive the stored name for a normalized overridden identity."
  @spec identity_name(map(), Archetypes.t(), map() | nil, atom()) :: String.t()
  def identity_name(_config, archetype, nil, _harness), do: archetype.name

  def identity_name(config, archetype, overrides, harness) do
    identity_name(config, archetype, overrides, harness, archetype.name)
  end

  @doc false
  @spec identity_name(map(), Archetypes.t(), map(), atom(), String.t()) :: String.t()
  def identity_name(_config, archetype, nil, _harness, _source_identity_name), do: archetype.name

  def identity_name(config, archetype, overrides, _harness, source_identity_name) do
    effective =
      Archetypes.effective(archetype, overrides,
        base_dir: config.base_dir,
        identity_name: source_identity_name
      )

    digest = effective_identity_fingerprint(effective)
    archetype.name <> "--" <> binary_part(digest, 0, 16)
  end

  @doc "Resolve an adapter identity name back to its base and effective archetypes."
  @spec resolve_identity!(map(), String.t()) :: {Archetypes.t(), Archetypes.t(), map() | nil}
  def resolve_identity!(config, identity_name) do
    if String.contains?(identity_name, "--") do
      db = Map.get(config, :db, Tightbeam.DB)

      case Org.all_by_identity_name(db, identity_name) do
        [] ->
          raise ArgumentError, "no session carries identity #{identity_name}"

        sessions ->
          resolved =
            Enum.map(sessions, fn session ->
              base =
                Archetypes.get(session.archetype) ||
                  raise "unknown archetype: #{session.archetype}"

              effective =
                Archetypes.effective(base, session.overrides,
                  base_dir: config.base_dir,
                  db: db,
                  identity_name: identity_name
                )

              {effective_identity_fingerprint(effective), base, effective, session.overrides}
            end)

          case resolved |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
            [_fingerprint] ->
              [{_fingerprint, base, effective, overrides} | _] = resolved
              {base, effective, overrides}

            _fingerprints ->
              raise ArgumentError,
                    "identity name collision: sessions carry distinct effective content for #{identity_name}"
          end
      end
    else
      base = Archetypes.get(identity_name) || raise "unknown archetype: #{identity_name}"
      {base, base, nil}
    end
  end

  @doc """
  Resolve and execute a harness CLI's version command without contacting the
  harness service. Codex prefers the projected operator-controlled shim.
  """
  @spec harness_binary_probe(atom(), String.t(), keyword()) ::
          {:ok, %{bin: String.t(), version: String.t()}}
          | {:error, :not_found}
          | {:error, {:exec_failed, String.t()}}
  def harness_binary_probe(harness, cli_bin, opts \\ []) do
    Harness.module!(harness).probe_cli(%{
      cli_bin: cli_bin,
      find_executable: Keyword.get(opts, :find_executable, &System.find_executable/1),
      timeout: Keyword.get(opts, :timeout, 2_000),
      run: Keyword.get(opts, :run, &system_cmd/1)
    })
  end

  defp auth_event_handler(host, module) do
    fn classification ->
      if classification == :terminal do
        Tightbeam.Credentials.mark_terminal(
          module.credential_provider(),
          %{"classification" => "terminal"},
          Tightbeam.Credentials.server(host)
        )
      end
    end
  end

  defp subagent_event_handler(config, host, module) do
    db = Map.get(config, :db, Tightbeam.DB)

    fn harness_session_id, update ->
      Tightbeam.SubagentMarkers.consume_update(
        db,
        Tightbeam.WakeScheduler,
        module.id(),
        host,
        harness_session_id,
        update
      )
    end
  end

  @doc """
  Materialize the home for an adapter key on its host per the moduledoc.
  Returns the home path AS SEEN BY THE ADAPTER PROCESS (local path for
  local, remote path for remote). opts: :sh (injectable runner,
  `(cmd :: [String.t()]) -> {output :: String.t(), exit :: integer()}`).
  """
  @spec deliver_home(map(), adapter_key(), keyword()) :: String.t()
  def deliver_home(config, {harness, _identity_name, host}, opts \\ []) do
    host_config = Map.fetch!(hosts(config.base_dir), host)
    module = Harness.module!(harness)
    home = Homes.home_path(host_config.base_dir, host, harness)
    sh = Keyword.get(opts, :sh, &system_cmd/1)

    module.reconcile_home(
      %{
        base_dir: config.base_dir,
        host_config: host_config,
        host_name: host,
        sh: sh
      },
      home,
      %{
        harness: harness,
        machine: host,
        rails: Rails.hook_settings(),
        auth_dir:
          Tightbeam.Credentials.store_dir(
            host_config.base_dir,
            module.credential_provider()
          )
      }
    )
    |> Map.fetch!(:home_path)
  end

  defp containment_refused!(config, key, reason) do
    Tightbeam.EventLog.lifecycle(
      config.db,
      "containment",
      adapter_key_name(key),
      "DENIED: #{reason}"
    )

    raise ArgumentError,
          "containment refused for host #{elem(key, 2)} adapter #{adapter_key_name(key)}: #{reason}"
  end

  defp adapter_key_name({harness, identity_name, host}),
    do: "#{harness}:#{identity_name}@#{host}"

  defp effective_identity_fingerprint(effective) do
    skill_names = effective.skills |> Enum.sort() |> Enum.intersperse(<<0>>)

    :crypto.hash(:sha256, [Archetypes.guidance(effective), <<0>>, skill_names])
    |> Base.encode16(case: :lower)
  end

  defp contained_runtime?(_config, "shared"), do: false

  defp contained_runtime?(config, identity_name) do
    config
    |> resolve_identity!(identity_name)
    |> elem(0)
    |> then(&(&1.containment.fs == :workdir))
  end

  defp shell_quote(script), do: "'" <> String.replace(script, "'", "'\\''") <> "'"

  defp system_cmd([command | args]), do: System.cmd(command, args, stderr_to_stdout: true)
  defp system_cmd_out([command | args]), do: System.cmd(command, args)

  defp run!(sh, command) do
    case sh.(command) do
      {_output, 0} -> :ok
      {_output, exit} -> raise "command failed with exit #{exit}: #{Enum.join(command, " ")}"
    end
  end
end
