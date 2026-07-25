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

  alias Tightbeam.{Archetypes, Containment, Homes, Identity, Org, Rails}
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

  defp materialize_identity(_config, %{ssh: nil}, session, snapshot, cwd, _opts) do
    Identity.materialize!(snapshot, String.to_existing_atom(session.harness), cwd)
  end

  defp materialize_identity(config, %{ssh: destination}, session, snapshot, cwd, opts) do
    harness = String.to_existing_atom(session.harness)
    sh = Keyword.get(opts, :sh, Map.get(config, :sh, &system_cmd/1))

    stage_cwd =
      Path.join([
        config.base_dir,
        "staging",
        session.host,
        "session-identity",
        session.session_key
      ])

    try do
      Identity.materialize!(snapshot, harness, stage_cwd)
      relative_skills = harness_skills_path(harness)
      staged_skills = Path.join(stage_cwd, relative_skills)
      remote_skills = Path.join(cwd, relative_skills)
      exclude_pattern = Path.join(relative_skills, "tightbeam__*")

      reconcile_script =
        "mkdir -p #{shell_quote(remote_skills)}; " <>
          "find #{shell_quote(remote_skills)} -mindepth 1 -maxdepth 1 -name 'tightbeam__*' -exec rm -rf {} +; " <>
          "root=$(git -C #{shell_quote(cwd)} rev-parse --show-toplevel 2>/dev/null || true); " <>
          "if [ \"$root\" = #{shell_quote(cwd)} ]; then " <>
          "exclude=$(git -C #{shell_quote(cwd)} rev-parse --git-path info/exclude); " <>
          "mkdir -p \"$(dirname \"$exclude\")\"; " <>
          "grep -qxF #{shell_quote(exclude_pattern)} \"$exclude\" 2>/dev/null || " <>
          "printf '%s\\n' #{shell_quote(exclude_pattern)} >> \"$exclude\"; fi"

      run!(
        sh,
        ["ssh" | @ssh_opts] ++ [destination, "sh", "-c", shell_quote(reconcile_script)]
      )

      run!(sh, [
        "rsync",
        "-a",
        "-e",
        Enum.join(["ssh" | @ssh_opts], " "),
        staged_skills <> "/",
        "#{destination}:#{remote_skills}/"
      ])

      snapshot
    after
      File.rm_rf(stage_cwd)
    end
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
    lineage =
      "tb1-" <> Base.url_encode64("#{harness}@#{host}", padding: false)

    host_config = Map.fetch!(hosts(config.base_dir), host)
    contained? = contained_runtime?(config, identity_name)

    if contained? and host_config.ssh != nil do
      containment_refused!(config, key, "contained_remote_unsupported")
    end

    deliver_opts = if config[:sh], do: [sh: config.sh], else: []
    home = deliver_home(config, key, deliver_opts)
    binary = adapter_binary_path(harness, host_config)
    rails? = harness == :codex and Rails.hook_settings() != nil

    probe_opts =
      if rails? do
        probe_cwd = Path.join(host_config.base_dir, "work/gate-probe")
        sh = Map.get(config, :sh, &system_cmd/1)

        if host_config.ssh == nil do
          File.rm_rf!(probe_cwd)
        else
          run!(sh, ["ssh" | @ssh_opts] ++ [host_config.ssh, "rm", "-rf", probe_cwd])
        end

        ensure_opts = [base_dir: config.base_dir]

        ensure_opts =
          if config[:sh], do: Keyword.put(ensure_opts, :sh, config.sh), else: ensure_opts

        ensure_opts =
          cond do
            config[:sh_out] -> Keyword.put(ensure_opts, :sh_out, config.sh_out)
            config[:sh] -> Keyword.put(ensure_opts, :sh_out, config.sh)
            true -> ensure_opts
          end

        ensure_workdir(host_config, probe_cwd, "", ensure_opts)
        [probe_cwd: probe_cwd, probe_model: "gpt-5.6-sol[medium]"]
      else
        []
      end

    stderr_path =
      Path.join(config.base_dir, "adapter-#{harness}:#{identity_name}@#{host}.stderr.log")

    if host_config.ssh == nil do
      # Invariant: codex hooks are TRUST-gated under app-server; `bypass_hook_trust`
      # is a thread/start request override only. codex-acp reads CODEX_CONFIG JSON
      # from its environment and spreads it into every thread/start and thread/resume
      # config map. The app-server emits the bypass warning both on stderr and as a
      # per-thread config-warning session update; both are benign harness noise,
      # contribute zero model-context bytes, and are never a boot or turn failure.
      # Config.toml and `-c` cannot seed hook trust, app-server rejects the
      # `--dangerously-bypass-hook-trust` flag, and the persisted trust store has no
      # writable automation seam. CODEX_CONFIG is therefore the sole production seed.
      codex_config_env =
        if rails?,
          do: [{"CODEX_CONFIG", codex_bypass_hook_trust_json()}],
          else: []

      opts = [
        harness: harness,
        cmd: [binary],
        home: home,
        cwd: config.cwd,
        stderr_path: stderr_path,
        on_auth_event: auth_event_handler(host, harness),
        env:
          [
            {"TIGHTBEAM_HOME", config.base_dir},
            {"TIGHTBEAM_MACHINE", host},
            {"PATH", config.cli_bin <> ":" <> (System.get_env("PATH") || "")},
            {"TIGHTBEAM_LINEAGE", lineage}
          ] ++
            harness_token_env(config.base_dir, harness) ++ codex_config_env
      ]

      if contained? do
        write_roots = [
          Path.join(host_config.base_dir, "work"),
          home,
          Path.join([host_config.base_dir, "auth", Atom.to_string(harness)])
        ]

        sh = Map.get(config, :sh, &system_cmd/1)
        wrapper = Path.join(config.cli_bin, "tightbeam")

        probe_result =
          try do
            sh.([wrapper, "contain-exec", "--check"])
          rescue
            error -> {:raised, error}
          end

        case probe_result do
          {:raised, error} ->
            containment_refused!(
              config,
              key,
              "contain-exec probe failed: #{Exception.message(error)}"
            )

          {_output, 0} ->
            :ok

          {_output, exit} ->
            containment_refused!(config, key, "contain-exec probe failed with exit #{exit}")
        end

        profile =
          try do
            Containment.profile(write_roots)
          rescue
            error in [ArgumentError] ->
              containment_refused!(config, key, Exception.message(error))
          end

        Tightbeam.EventLog.lifecycle(
          config.db,
          "containment",
          adapter_key_name(key),
          "assembled; fs=workdir network=open; write-roots=#{Enum.join(write_roots, ",")}"
        )

        opts
        |> Keyword.merge(probe_opts)
        |> Keyword.put(:cmd, [wrapper, "contain-exec", "--profile", profile, "--", binary])
        |> Keyword.put(:contained, true)
      else
        Keyword.merge(opts, probe_opts)
      end
    else
      cli_bin = host_config[:cli_bin] || ""
      home_env = if harness == :codex, do: "CODEX_HOME", else: "CLAUDE_CONFIG_DIR"

      # The org token env, satellite edition: the token file lives on the
      # SATELLITE (its auth store), unreadable at env-assembly time — so the
      # value is a shell expansion evaluated remotely, the same
      # remote-expansion trick as PATH=$PATH below. A missing file expands
      # empty and the harness falls back to the auth store's credential
      # file, exactly like the local branch.
      token_env =
        if harness == :claude do
          token_path = Path.join([host_config.base_dir, "auth", "claude", "oauth-token"])
          ["CLAUDE_CODE_OAUTH_TOKEN=$(cat #{token_path} 2>/dev/null)"]
        else
          []
        end

      # Same sole production trust-bypass seed as the local branch; single-quoted so
      # the JSON survives the remote shell's second parse. codex-acp spreads it into
      # thread/start and thread/resume; the stderr and per-thread config-warning
      # notifications are benign, zero-context harness noise. Config.toml, `-c`, the
      # rejected app-server flag, and the persisted trust store cannot seed this path.
      codex_config_env =
        if rails?,
          do: ["CODEX_CONFIG='#{codex_bypass_hook_trust_json()}'"],
          else: []

      remote_env =
        (token_env ++
           [
             "#{home_env}=#{home}",
             "TIGHTBEAM_HOME=#{host_config.base_dir}",
             "TIGHTBEAM_MACHINE=#{host}",
             "TIGHTBEAM_URL=#{Application.fetch_env!(:tightbeam, :advertised_url)}",
             "PATH=#{cli_bin}:$PATH",
             "TIGHTBEAM_LINEAGE=#{lineage}"
           ] ++ codex_config_env)
        |> Enum.reject(&is_nil/1)

      Keyword.merge(
        [
          harness: harness,
          cmd:
            ["ssh" | @ssh_opts] ++
              [host_config.ssh, "exec", "env" | remote_env] ++ [binary],
          home: home,
          cwd: config.cwd,
          stderr_path: stderr_path,
          on_auth_event: auth_event_handler(host, harness),
          env: [{"TIGHTBEAM_LINEAGE", lineage}]
        ],
        probe_opts
      )
    end
  end

  @doc "Derive the stored name for a normalized overridden identity."
  @spec identity_name(map(), Archetypes.t(), map() | nil, :claude | :codex) :: String.t()
  def identity_name(_config, archetype, nil, _harness), do: archetype.name

  def identity_name(config, archetype, overrides, harness) do
    identity_name(config, archetype, overrides, harness, archetype.name)
  end

  @doc false
  @spec identity_name(map(), Archetypes.t(), map(), :claude | :codex, String.t()) :: String.t()
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
  Where a harness's ACP adapter lives on a host. Remote hosts have exactly
  ONE answer — `<base_dir>/adapters/node_modules/.bin` — because adapters
  are org-owned artifacts deployed by spinup to the org's lease; the old
  per-host `adapter_bin_dir` hint was a drift-capable record of the kind
  the topology ruling outlaws, and is no longer consulted (field removal
  rides the assimilate-reduction follow-up). Local resolution is the
  operator's repo checkout, unchanged.
  """
  @spec adapter_binary_path(:claude | :codex, host_config()) :: String.t()
  def adapter_binary_path(harness, host_config) do
    adapter = if harness == :codex, do: "codex-acp", else: "claude-agent-acp"

    if host_config.ssh == nil do
      Path.expand("../tightbeam/node_modules/.bin/#{adapter}", File.cwd!())
    else
      Path.join([host_config.base_dir, "adapters", "node_modules", ".bin", adapter])
    end
  end

  @doc """
  Resolve and execute a harness CLI's version command without contacting the
  harness service. Codex prefers the projected operator-controlled shim.
  """
  @spec harness_binary_probe(:claude | :codex, String.t(), keyword()) ::
          {:ok, %{bin: String.t(), version: String.t()}}
          | {:error, :not_found}
          | {:error, {:exec_failed, String.t()}}
  def harness_binary_probe(harness, cli_bin, opts \\ []) do
    find_executable = Keyword.get(opts, :find_executable, &System.find_executable/1)
    timeout = Keyword.get(opts, :timeout, 2_000)
    run = Keyword.get(opts, :run, &system_cmd/1)

    with bin when is_binary(bin) <- harness_binary_path(harness, cli_bin, find_executable),
         {:ok, {output, 0}} <- bounded_run(run, [bin, "--version"], timeout) do
      {:ok, %{bin: bin, version: String.trim(output)}}
    else
      nil ->
        {:error, :not_found}

      {:ok, {output, status}} ->
        {:error,
         {:exec_failed, "exit=#{status} output=#{inspect(String.trim(to_string(output)))}"}}

      {:error, detail} ->
        {:error, {:exec_failed, detail}}
    end
  end

  defp harness_binary_path(:codex, cli_bin, find_executable) do
    shim = Path.join(cli_bin, "codex")
    if File.exists?(shim), do: shim, else: find_executable.("codex")
  end

  defp harness_binary_path(:claude, _cli_bin, find_executable),
    do: find_executable.("claude")

  defp bounded_run(run, command, timeout) do
    task =
      Task.async(fn ->
        try do
          {:ok, run.(command)}
        rescue
          error -> {:error, Exception.message(error)}
        catch
          kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "runner exited: #{inspect(reason)}"}
      nil -> {:error, "timed out after #{timeout}ms"}
    end
  end

  # The thread/start and thread/resume trust-bypass override, as the one JSON object
  # codex-acp expects in CODEX_CONFIG. Future CODEX_CONFIG values must merge here,
  # never create a second exporter.
  defp codex_bypass_hook_trust_json, do: ~s({"bypass_hook_trust":true})

  # The org's own long-lived grant, injected as the harness's token env —
  # the strongest form of the credential doctrine: an env token never
  # refreshes, so there is no rotation and nothing to race. The file is
  # written by the operator from `tightbeam setup`'s output (0600); absent
  # file → the harness falls back to the auth store's credential file.
  defp harness_token_env(base_dir, :claude) do
    case File.read(Path.join([base_dir, "auth", "claude", "oauth-token"])) do
      {:ok, token} -> [{"CLAUDE_CODE_OAUTH_TOKEN", String.trim(token)}]
      _ -> []
    end
  end

  defp harness_token_env(_base_dir, _harness), do: []

  defp auth_event_handler(host, harness) do
    provider = provider_for_harness(harness)

    fn params ->
      Tightbeam.Credentials.mark_terminal(
        provider,
        %{
          "method" => "account/updated",
          "params" => params
        },
        Tightbeam.Credentials.server(host)
      )
    end
  end

  defp provider_for_harness(:codex), do: :openai
  defp provider_for_harness(:claude), do: :anthropic

  defp harness_skills_path(:codex), do: Path.join([".codex", "skills"])
  defp harness_skills_path(:claude), do: Path.join([".claude", "skills"])

  @doc """
  Materialize the home for an adapter key on its host per the moduledoc.
  Returns the home path AS SEEN BY THE ADAPTER PROCESS (local path for
  local, remote path for remote). opts: :sh (injectable runner,
  `(cmd :: [String.t()]) -> {output :: String.t(), exit :: integer()}`).
  """
  @spec deliver_home(map(), adapter_key(), keyword()) :: String.t()
  def deliver_home(config, {harness, _identity_name, host}, opts \\ []) do
    host_config = Map.fetch!(hosts(config.base_dir), host)
    spec = shared_projection_spec(config, harness, host)

    if host_config.ssh == nil do
      Homes.project(config.base_dir, spec).home_path
    else
      stage_base = Path.join([config.base_dir, "staging", host])
      staged_home = Homes.project(stage_base, spec).home_path
      remote_home = Homes.home_path(host_config.base_dir, host, harness)

      sh = Keyword.get(opts, :sh, &system_cmd/1)
      remote_manifest = Path.join([remote_home, ".tightbeam", "manifest"])

      {remote_stamp, stamp_exit} =
        sh.(
          ["ssh" | @ssh_opts] ++
            [host_config.ssh, "cat", remote_manifest]
        )

      if stamp_exit not in [0, 1], do: raise("remote stamp check failed with exit #{stamp_exit}")

      staged_stamp = File.read!(Path.join([staged_home, ".tightbeam", "manifest"]))

      if remote_stamp != staged_stamp do
        regenerate_remote_owned!(sh, host_config, harness, remote_home)
      end

      run!(sh, [
        "rsync",
        "-a",
        "-e",
        Enum.join(["ssh" | @ssh_opts], " "),
        staged_home <> "/",
        "#{host_config.ssh}:#{remote_home}/"
      ])

      auth_dir = Path.join([host_config.base_dir, "auth", Atom.to_string(harness)])
      credential = credential_filename(harness)

      link_script =
        "source=\"#{Path.join(auth_dir, credential)}\"; " <>
          "target=\"#{Path.join(remote_home, credential)}\"; " <>
          "[ ! -e \"$source\" ] || [ -e \"$target\" ] || [ -L \"$target\" ] || ln -s \"$source\" \"$target\""

      # ssh JOINS its argv into one remote command line and the remote
      # shell RE-PARSES it — an unquoted compound script arrives as loose
      # words and `sh -c` gets only the first. Quote for the second parse.
      # (Caught live by the loopback satellite; invisible to injected-sh
      # tests, which capture argv without executing it.)
      run!(
        sh,
        ["ssh" | @ssh_opts] ++ [host_config.ssh, "sh", "-c", shell_quote(link_script)]
      )

      remote_home
    end
  end

  defp regenerate_remote_owned!(sh, host_config, harness, remote_home) do
    auth_dir = Path.join([host_config.base_dir, "auth", Atom.to_string(harness)])
    credential = credential_filename(harness)
    entry = Path.join(remote_home, credential)
    store = Path.join(auth_dir, credential)
    rails = Path.join(remote_home, rails_filename(harness))
    manifest_dir = Path.join(remote_home, ".tightbeam")

    script =
      "mkdir -p \"#{auth_dir}\" \"#{remote_home}\"; " <>
        "if [ -f \"#{entry}\" ] && [ ! -L \"#{entry}\" ]; then " <>
        "cp \"#{entry}\" \"#{store}\" && chmod 600 \"#{store}\"; fi; " <>
        "rm -f \"#{entry}\" \"#{rails}\"; rm -rf \"#{manifest_dir}\""

    run!(
      sh,
      ["ssh" | @ssh_opts] ++ [host_config.ssh, "sh", "-c", shell_quote(script)]
    )
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

  defp shared_projection_spec(_config, :claude, host) do
    %{
      harness: :claude,
      machine: host,
      rails: encode_settings(Rails.hook_settings())
    }
  end

  defp shared_projection_spec(_config, :codex, host) do
    settings =
      case Rails.hook_settings() do
        nil -> nil
        hooks -> update_in(hooks, ["hooks", "PreToolUse"], &(&1 ++ [Rails.probe_entry()]))
      end

    %{harness: :codex, machine: host, rails: encode_settings(settings)}
  end

  defp encode_settings(nil), do: nil
  defp encode_settings(settings), do: JSON.encode!(settings)

  defp contained_runtime?(_config, "shared"), do: false

  defp contained_runtime?(config, identity_name) do
    config
    |> resolve_identity!(identity_name)
    |> elem(0)
    |> then(&(&1.containment.fs == :workdir))
  end

  defp credential_filename(:codex), do: "auth.json"
  defp credential_filename(:claude), do: "oauth-token"

  defp rails_filename(:codex), do: "hooks.json"
  defp rails_filename(:claude), do: "settings.json"

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
