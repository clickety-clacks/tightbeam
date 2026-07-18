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

  Three responsibilities, each a pure-ish function:

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
       agent env (harness home var, TIGHTBEAM_URL/TOKEN, PATH with the
       remote cli_bin) is embedded in the remote command line. The home var
       points at the REMOTE home path (remote base_dir). stderr_path stays
       LOCAL and unchanged: the Conn's `sh -c '... 2>>log'` wraps the ssh
       client, so remote stderr rides the ssh connection into the local log.
       The advertised URL (config :tightbeam, :advertised_url) is used for
       TIGHTBEAM_URL — never 127.0.0.1 — so the remote agent's CLI reaches
       the gateway over the network.

  3. `deliver_home/3` — materialize the projected home on the session's host:
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

  Failure posture: deliver_home raising fails the adapter start, which the
  AdapterCoordinator already treats as a failed start (backoff, circuit) —
  an unreachable host degrades exactly like a dead adapter, per spec.
  """

  alias Tightbeam.{Archetypes, Homes}

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

  @doc """
  Ensure a directory exists on a host (local mkdir_p; remote ssh mkdir -p).
  Used for per-session workdirs. Raises on failure — an unmakeable workdir
  fails the turn visibly, same posture as home delivery.
  """
  @spec ensure_dir(host_config(), String.t()) :: :ok
  def ensure_dir(%{ssh: nil}, path) do
    File.mkdir_p!(path)
    :ok
  end

  def ensure_dir(%{ssh: dest}, path) do
    {_out, code} =
      System.cmd("ssh", @ssh_opts ++ [dest, "mkdir", "-p", path], stderr_to_stdout: true)

    if code != 0, do: raise("remote workdir mkdir failed (#{dest}): #{path}")
    :ok
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
  def adapter_opts(config, {harness, archetype, host} = key) do
    deliver_opts = if config[:sh], do: [sh: config.sh], else: []
    home = deliver_home(config, key, deliver_opts)
    host_config = Map.fetch!(hosts(config.base_dir), host)
    adapter = if harness == :codex, do: "codex-acp", else: "claude-agent-acp"

    binary =
      if host_config.ssh == nil do
        Path.expand("../tightbeam/node_modules/.bin/#{adapter}", File.cwd!())
      else
        case Map.get(host_config, :adapter_bin_dir) do
          nil -> Path.expand("../tightbeam/node_modules/.bin/#{adapter}", host_config.base_dir)
          adapter_bin_dir -> Path.join(adapter_bin_dir, adapter)
        end
      end

    stderr_path = Path.join(config.base_dir, "adapter-#{harness}:#{archetype}.stderr.log")

    if host_config.ssh == nil do
      [
        harness: harness,
        cmd: [binary],
        home: home,
        cwd: config.cwd,
        stderr_path: stderr_path,
        env:
          [
            {"TIGHTBEAM_HOME", config.base_dir},
            {"PATH", config.cli_bin <> ":" <> (System.get_env("PATH") || "")}
          ] ++ harness_token_env(config.base_dir, harness)
      ]
    else
      gateway = config.base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()
      cli_bin = host_config[:cli_bin] || ""
      home_env = if harness == :codex, do: "CODEX_HOME", else: "CLAUDE_CONFIG_DIR"

      remote_env = [
        "#{home_env}=#{home}",
        "TIGHTBEAM_HOME=#{host_config.base_dir}",
        "TIGHTBEAM_URL=#{Application.fetch_env!(:tightbeam, :advertised_url)}",
        "TIGHTBEAM_TOKEN=#{Map.fetch!(gateway, "cliToken")}",
        "PATH=#{cli_bin}:$PATH"
      ]

      [
        harness: harness,
        cmd: ["ssh" | @ssh_opts] ++ [host_config.ssh, "exec", "env" | remote_env] ++ [binary],
        home: home,
        cwd: config.cwd,
        stderr_path: stderr_path,
        env: []
      ]
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
  Materialize the home for an adapter key on its host per the moduledoc.
  Returns the home path AS SEEN BY THE ADAPTER PROCESS (local path for
  local, remote path for remote). opts: :sh (injectable runner,
  `(cmd :: [String.t()]) -> {output :: String.t(), exit :: integer()}`).
  """
  @spec deliver_home(map(), adapter_key(), keyword()) :: String.t()
  def deliver_home(config, {harness, archetype_name, host}, opts \\ []) do
    archetype = Archetypes.get(archetype_name)

    spec = %{
      harness: harness,
      archetype: archetype_name,
      guidance: Archetypes.guidance(archetype)
    }

    host_config = Map.fetch!(hosts(config.base_dir), host)

    if host_config.ssh == nil do
      Homes.project(config.base_dir, spec).home_path
    else
      stage_base = Path.join([config.base_dir, "staging", host])
      staged_home = Homes.project(stage_base, spec).home_path

      remote_home =
        Path.join([host_config.base_dir, "homes", archetype_name, Atom.to_string(harness)])

      sh = Keyword.get(opts, :sh, &system_cmd/1)

      {remote_stamp, stamp_exit} =
        sh.(["ssh" | @ssh_opts] ++ [host_config.ssh, "cat", Path.join(remote_home, ".tightbeam-manifest")])

      if stamp_exit not in [0, 1], do: raise("remote stamp check failed with exit #{stamp_exit}")

      staged_stamp = File.read!(Path.join(staged_home, ".tightbeam-manifest"))

      if remote_stamp != staged_stamp do
        run!(sh, ["ssh" | @ssh_opts] ++ [
          host_config.ssh,
          "rm",
          "-rf",
          remote_home,
          "&&",
          "mkdir",
          "-p",
          remote_home
        ])
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

      link_script =
        "for source in \"#{auth_dir}\"/*; do " <>
          "[ -e \"$source\" ] || continue; " <>
          "target=\"#{remote_home}/$(basename \"$source\")\"; " <>
          "[ -e \"$target\" ] || [ -L \"$target\" ] || ln -s \"$source\" \"$target\"; " <>
          "done"

      run!(sh, ["ssh" | @ssh_opts] ++ [host_config.ssh, "sh", "-c", link_script])
      remote_home
    end
  end

  defp system_cmd([command | args]), do: System.cmd(command, args, stderr_to_stdout: true)

  defp run!(sh, command) do
    case sh.(command) do
      {_output, 0} -> :ok
      {_output, exit} -> raise "command failed with exit #{exit}: #{Enum.join(command, " ")}"
    end
  end
end
