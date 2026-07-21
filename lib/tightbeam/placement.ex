defmodule Tightbeam.Placement do
  @moduledoc """
  Placement mechanics (spec §Placement) — the ONE module that knows hosts
  exist. Everything else addresses identity; this module turns a host NAME
  into an adapter command, a delivered home, and an allow/deny answer.

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
     {harness, archetype_name, host}:
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

  3. `deliver_home/3` — materialize the projected home on the session's host:
     Claude homes pin their session-facing default model in settings.json;
     that pin participates in the projected identity, so the first deploy
     regenerates each Claude home once and the expected context-reset
     markers make that identity change visible.
     - local: `Homes.project(base_dir, spec)` directly (unchanged path).
     - remote: STAGE the projection on the gateway machine under
       `<base_dir>/staging/<host>/` — the staging tree has NO auth/ dir, so
       projection stages zero auth symlinks (credentials never transit; a
       staged symlink would point at a gateway-local path anyway) — then:
       (a) read the remote stamp (`ssh dest cat <remote_home>/.tightbeam-
           manifest`, missing → ""),
       (b) if it differs from the staged stamp: `ssh dest rm -rf <remote_
           home> && mkdir -p` (identity change wipes, same rule as local),
       (c) `rsync -a <staged>/ dest:<remote_home>/` WITHOUT --delete (an
           unchanged identity must never destroy nested harness session
           state — same invariant as Homes' hash gate, extended over the
           wire),
       (d) link auth remotely: one ssh sh-loop symlinking every file of
           `<remote_base>/auth/<harness>/` into the home (ln -s, existing
           links left alone).
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

  alias Tightbeam.{Archetypes, Containment, Homes, Org, Rails}
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

  @typedoc "Adapter key, widened for placement."
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
      source = workdir_path(old_host, session_key)
      destination = workdir_path(new_host, session_key)
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

  defp workdir_path(host, session_key) do
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
      "tb1-" <> Base.url_encode64("#{identity_name}@#{host}", padding: false)

    resolved = resolve_identity!(config, identity_name)
    host_config = Map.fetch!(hosts(config.base_dir), host)
    contained? = elem(resolved, 0).containment.fs == :workdir

    if contained? and host_config.ssh == nil and host != local_host_name() do
      containment_refused!(config, key, "contained_noncanonical_local_host")
    end

    deliver_opts = if config[:sh], do: [sh: config.sh], else: []
    home = deliver_home_resolved(config, key, resolved, deliver_opts)
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
      opts = [
        harness: harness,
        cmd: [binary],
        home: home,
        cwd: config.cwd,
        stderr_path: stderr_path,
        env:
          [
            {"TIGHTBEAM_HOME", config.base_dir},
            {"PATH", config.cli_bin <> ":" <> (System.get_env("PATH") || "")},
            {"TIGHTBEAM_LINEAGE", lineage}
          ] ++
            harness_token_env(config.base_dir, harness) ++
            if(rails?, do: [{"CODEX_CONFIG", ~s({"bypass_hook_trust":true})}], else: [])
      ]

      if contained? do
        write_roots = [
          Path.join(host_config.base_dir, "work"),
          home,
          Path.join([host_config.base_dir, "auth", Atom.to_string(harness)])
        ]

        try do
          :ok = Containment.validate_roots!(write_roots)
        rescue
          error in [ArgumentError] ->
            containment_refused!(config, key, Exception.message(error))
        end

        sh = Map.get(config, :sh, &system_cmd/1)

        probe_result =
          try do
            sh.([
              "/usr/bin/sandbox-exec",
              "-p",
              "(version 1)(allow default)",
              "/usr/bin/true"
            ])
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

        Tightbeam.EventLog.lifecycle(
          config.db,
          "containment",
          adapter_key_name(key),
          "assembled; fs=workdir network=open; write-roots=#{Enum.join(write_roots, ",")}"
        )

        opts
        |> Keyword.merge(probe_opts)
        |> Keyword.put(:cmd, ["/usr/bin/sandbox-exec", "-p", profile, binary])
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

      remote_env =
        (token_env ++
           [
             "#{home_env}=#{home}",
             if(rails?, do: ~s(CODEX_CONFIG='{"bypass_hook_trust":true}')),
             "TIGHTBEAM_HOME=#{host_config.base_dir}",
             "TIGHTBEAM_URL=#{Application.fetch_env!(:tightbeam, :advertised_url)}",
             "PATH=#{cli_bin}:$PATH",
             "TIGHTBEAM_LINEAGE=#{lineage}"
           ])
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

  # The org's own long-lived grant, injected as the harness's token env —
  # the strongest form of the credential doctrine: an env token never
  # refreshes, so there is no rotation and nothing to race. The file is
  # written by the operator from `tightbeam setup`'s output (0600); absent
  # file → the harness falls back to the auth store's credential file.
  # Remote hosts are NOT covered here yet: the satellite's token file lives
  # on the satellite, and the ssh env assembly can't read it locally —
  # that's the remote-placement live-fire milestone's work.
  defp harness_token_env(base_dir, :claude) do
    case File.read(Path.join([base_dir, "auth", "claude", "oauth-token"])) do
      {:ok, token} -> [{"CLAUDE_CODE_OAUTH_TOKEN", String.trim(token)}]
      _ -> []
    end
  end

  defp harness_token_env(_base_dir, _harness), do: []

  @doc """
  Push one library root (a one-shot skill or a whole subject tree) to every
  REMOTE host's replica — the propagation half of the skill verbs. Per-host
  results, never a raise: an unreachable host is a visible degradation
  ("error: ..."), healed by the catch-up sync at its next home delivery.
  For a removal the push is an rm -rf of the replica path.
  """
  @spec push_skill(map(), String.t(), :put | :rm, keyword()) :: %{
          optional(String.t()) => String.t()
        }
  def push_skill(config, root, action, opts \\ []) do
    sh = Keyword.get(opts, :sh, &system_cmd/1)

    for {name, host_config} <- hosts(config.base_dir), host_config.ssh != nil, into: %{} do
      remote_library = Archetypes.skills_dir(host_config.base_dir)

      result =
        try do
          case action do
            :put ->
              run!(sh, ["ssh" | @ssh_opts] ++ [host_config.ssh, "mkdir", "-p", remote_library])

              run!(sh, [
                "rsync",
                "-a",
                "--delete",
                "-e",
                Enum.join(["ssh" | @ssh_opts], " "),
                Path.join(Archetypes.skills_dir(config.base_dir), root),
                "#{host_config.ssh}:#{remote_library}/"
              ])

            :rm ->
              run!(
                sh,
                ["ssh" | @ssh_opts] ++
                  [
                    host_config.ssh,
                    "rm",
                    "-rf",
                    Path.join(remote_library, root)
                  ]
              )
          end

          "ok"
        rescue
          e -> "error: #{Exception.message(e)}"
        end

      {name, result}
    end
  end

  @doc """
  Materialize the home for an adapter key on its host per the moduledoc.
  Returns the home path AS SEEN BY THE ADAPTER PROCESS (local path for
  local, remote path for remote). opts: :sh (injectable runner,
  `(cmd :: [String.t()]) -> {output :: String.t(), exit :: integer()}`).
  """
  @spec deliver_home(map(), adapter_key(), keyword()) :: String.t()
  def deliver_home(config, {harness, identity_name, host}, opts \\ []) do
    resolved = resolve_identity!(config, identity_name)
    deliver_home_resolved(config, {harness, identity_name, host}, resolved, opts)
  end

  defp deliver_home_resolved(
         config,
         {harness, identity_name, host} = key,
         {base_archetype, effective_archetype, overrides},
         opts
       ) do
    host_config = Map.fetch!(hosts(config.base_dir), host)

    if base_archetype.containment.fs == :workdir and host_config.ssh != nil do
      containment_refused!(config, key, "contained_remote_unsupported")
    end

    if host_config.ssh == nil do
      refs =
        skill_refs(config.base_dir, base_archetype, effective_archetype, overrides, identity_name)

      spec =
        projection_spec(
          config,
          harness,
          identity_name,
          base_archetype,
          effective_archetype,
          refs
        )
        |> with_identity_fingerprint(overrides)

      Homes.project(config.base_dir, spec).home_path
    else
      stage_base = Path.join([config.base_dir, "staging", host])
      remote_library = Archetypes.skills_dir(host_config.base_dir)
      remote_pinned = Path.join([host_config.base_dir, "identity", "pinned", identity_name])

      refs =
        skill_refs(
          config.base_dir,
          base_archetype,
          effective_archetype,
          overrides,
          identity_name,
          remote_library,
          remote_pinned
        )

      spec =
        projection_spec(
          config,
          harness,
          identity_name,
          base_archetype,
          effective_archetype,
          refs
        )
        |> with_identity_fingerprint(overrides)

      staged_home =
        Homes.project(stage_base, spec).home_path

      remote_home =
        Path.join([host_config.base_dir, "homes", identity_name, Atom.to_string(harness)])

      sh = Keyword.get(opts, :sh, &system_cmd/1)

      {remote_stamp, stamp_exit} =
        sh.(
          ["ssh" | @ssh_opts] ++
            [host_config.ssh, "cat", Path.join(remote_home, ".tightbeam-manifest")]
        )

      if stamp_exit not in [0, 1], do: raise("remote stamp check failed with exit #{stamp_exit}")

      staged_stamp = File.read!(Path.join(staged_home, ".tightbeam-manifest"))

      if remote_stamp != staged_stamp do
        run!(
          sh,
          ["ssh" | @ssh_opts] ++
            [
              host_config.ssh,
              "rm",
              "-rf",
              remote_home,
              "&&",
              "mkdir",
              "-p",
              remote_home
            ]
        )
      end

      run!(sh, [
        "rsync",
        "-a",
        "-e",
        Enum.join(["ssh" | @ssh_opts], " "),
        staged_home <> "/",
        "#{host_config.ssh}:#{remote_home}/"
      ])

      # Library replica catch-up: the staged home's skill links point into
      # the satellite's replica; delivery makes them resolve even for a
      # host that missed a skill-put push (degrade heals at next delivery).
      linked = Enum.filter(refs, &(&1.linkage == "linked"))
      pinned = Enum.filter(refs, &(&1.linkage == "pinned"))

      if linked != [] do
        run!(sh, ["ssh" | @ssh_opts] ++ [host_config.ssh, "mkdir", "-p", remote_library])

        for skill <- linked do
          run!(sh, [
            "rsync",
            "-a",
            "-e",
            Enum.join(["ssh" | @ssh_opts], " "),
            Path.join(Archetypes.skills_dir(config.base_dir), skill.name),
            "#{host_config.ssh}:#{remote_library}/"
          ])
        end
      end

      if pinned != [] do
        run!(sh, ["ssh" | @ssh_opts] ++ [host_config.ssh, "mkdir", "-p", remote_pinned])

        for skill <- pinned do
          run!(sh, [
            "rsync",
            "-a",
            "-e",
            Enum.join(["ssh" | @ssh_opts], " "),
            Path.join([config.base_dir, "identity", "pinned", identity_name, skill.name]),
            "#{host_config.ssh}:#{remote_pinned}/"
          ])
        end
      end

      auth_dir = Path.join([host_config.base_dir, "auth", Atom.to_string(harness)])

      link_script =
        "for source in \"#{auth_dir}\"/*; do " <>
          "[ -e \"$source\" ] || continue; " <>
          "target=\"#{remote_home}/$(basename \"$source\")\"; " <>
          "[ -e \"$target\" ] || [ -L \"$target\" ] || ln -s \"$source\" \"$target\"; " <>
          "done"

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

  defp projection_spec(config, harness, identity_name, base, effective, refs) do
    spec = %{
      harness: harness,
      archetype: identity_name,
      base_archetype: base.name,
      parent_source: base.source,
      guidance: Archetypes.guidance(effective),
      skills: refs
    }

    rails_settings = Rails.hook_settings()

    settings =
      case harness do
        :claude ->
          merge_settings(rails_settings, model_settings(harness, base, config))

        :codex when not is_nil(rails_settings) ->
          update_in(rails_settings, ["hooks", "PreToolUse"], &(&1 ++ [Rails.probe_entry()]))

        :codex ->
          nil
      end

    filename = if harness == :claude, do: "settings.json", else: "hooks.json"

    if settings,
      do: Map.put(spec, :extra_files, %{filename => JSON.encode!(settings)}),
      else: spec
  end

  defp with_identity_fingerprint(spec, nil), do: spec

  defp with_identity_fingerprint(spec, _overrides),
    do: Map.put(spec, :identity_sha256, Homes.identity_fingerprint(spec))

  defp effective_identity_fingerprint(effective) do
    Homes.identity_fingerprint(%{
      guidance: Archetypes.guidance(effective),
      skills: Enum.map(effective.skills, &%{name: &1})
    })
  end

  defp skill_refs(base_dir, base, effective, overrides, identity_name) do
    skill_refs(
      base_dir,
      base,
      effective,
      overrides,
      identity_name,
      Archetypes.skills_dir(base_dir),
      Path.join([base_dir, "identity", "pinned", identity_name])
    )
  end

  defp skill_refs(
         base_dir,
         _base,
         effective,
         overrides,
         identity_name,
         library_dir,
         pinned_dir
       ) do
    override_names = if overrides, do: Map.get(overrides, "skills_add", []), else: []

    Enum.map(effective.skills, fn name ->
      provenance = if name in override_names, do: "override", else: "template"
      local_pinned = Path.join([base_dir, "identity", "pinned", identity_name, name])

      {linkage, link_to} =
        if provenance == "override" and File.exists?(local_pinned) do
          {"pinned", Path.join(pinned_dir, name)}
        else
          {"linked", Path.join(library_dir, name)}
        end

      %{name: name, link_to: link_to, provenance: provenance, linkage: linkage}
    end)
  end

  defp merge_settings(nil, nil), do: nil
  defp merge_settings(settings, nil), do: settings
  defp merge_settings(nil, additions), do: additions
  defp merge_settings(settings, additions), do: Map.merge(settings, additions)

  defp model_settings(:claude, archetype, config) do
    default_ref = archetype.defaults[:model] || config.default_model

    pinned_model =
      Application.get_env(:tightbeam, :model_pins, %{"fable" => "claude-fable-5[1m]"})
      |> Map.get(default_ref, default_ref)

    %{"model" => pinned_model}
  end

  defp model_settings(_harness, _archetype, _config), do: nil

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
