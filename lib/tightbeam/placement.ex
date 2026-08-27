defmodule Tightbeam.Placement do
  @moduledoc """
  Placement mechanics (spec §Placement) — the ONE module that knows hosts
  exist. Everything else addresses identity; this module turns a host NAME
  into an adapter command, a delivered shared home, and an allow/deny answer.

  Hosts are DB ROWS behind the org's DB owner — the serialization seam — written
  by `assimilate` through `register_host/3` and read back as name =>
  %{ssh: destination-or-nil, base_dir: path, cli_bin: path-or-nil,
  toolchain_dirs: ordered-paths-when-configured}
  (host-registry-v1). `gateway.json` stays a FILE — the CLI reads it
  before any DB exists. The gateway's own machine is under its
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

  require Logger

  alias Tightbeam.{Archetypes, DB, Harness, HarnessHealth, Homes, Identity, Org, Rails}
  import Bitwise

  defmodule Refusal do
    @moduledoc "A placement refusal that synchronous and turn boundaries can relay by name."
    @enforce_keys [:code, :host, :harness, :message]
    defexception [:code, :host, :harness, :message]
  end

  # Non-interactive, bounded ssh everywhere placement reaches out: a dead or
  # misconfigured host must fail in seconds with a reason, never hang on TCP
  # timeouts or an invisible password prompt.
  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]

  # Effort stamps sit in the session's own workdir, so they are reaped with the
  # workspace and never outlive it.
  @effort_stamp_dir ".tightbeam-effort"

  @typedoc "A configured host. ssh: nil marks the reserved local host."
  @type host_config :: %{
          required(:ssh) => String.t() | nil,
          required(:base_dir) => String.t(),
          optional(:cli_bin) => String.t() | nil,
          optional(:toolchain_dirs) => [String.t()]
        }

  @typedoc "Adapter key. The reserved identity `shared` is the one runtime per harness+host."
  @type adapter_key :: {harness :: atom(), archetype :: String.t(), host :: String.t()}

  @hosts_ddl """
  CREATE TABLE IF NOT EXISTS hosts (
    name          TEXT PRIMARY KEY,
    ssh           TEXT,
    baseDir       TEXT NOT NULL,
    cliBin        TEXT,
    adapterBinDir TEXT
  )
  """

  @harness_env_overlays_ddl """
  CREATE TABLE IF NOT EXISTS harness_env_overlays (
    host    TEXT NOT NULL,
    harness TEXT NOT NULL,
    name    TEXT NOT NULL,
    value   TEXT NOT NULL,
    setBy   TEXT NOT NULL,
    setAt   INTEGER NOT NULL,
    PRIMARY KEY (host, harness, name)
  )
  """

  @host_toolchain_dirs_ddl """
  CREATE TABLE IF NOT EXISTS host_toolchain_dirs (
    host     TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    dir      TEXT NOT NULL,
    setBy    TEXT NOT NULL,
    setAt    INTEGER NOT NULL,
    PRIMARY KEY (host, position)
  )
  """

  @posix_path ["/usr/local/bin", "/usr/bin", "/bin"]

  @env_name ~r/^[A-Z_][A-Z0-9_]*$/

  @doc "Create the placement schema."
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    with :ok <- DB.execute(db, @hosts_ddl),
         :ok <- DB.execute(db, @harness_env_overlays_ddl),
         do: DB.execute(db, @host_toolchain_dirs_ddl)
  end

  @doc """
  The known hosts map with the gateway's own machine always present under
  `local_host_name/0` (ssh: nil, base_dir = the gateway's base_dir).

  ONE source: the `hosts` table, written only by `register_host/3` — what
  `assimilate` records through. Then the gateway's own entry, which nothing may
  redefine. `base_dir` is still an argument because that own entry IS the
  gateway's base_dir; it no longer says where the registry lives.

  There was a second source until 2026-07-28: a `TIGHTBEAM_HOSTS` env var merged
  in ON TOP of the registry, so a stale env entry silently won over what
  assimilate had just written for the same name, and the gateway then dialled a
  different ssh destination than the one it had reported installing. Removed —
  two stores for one fact is the same defect as the four base_dir resolvers.
  """
  @spec hosts(String.t(), DB.server()) :: %{optional(String.t()) => host_config()}
  def hosts(base_dir, db \\ DB) do
    configured =
      db
      |> registered_hosts()
      |> Map.put(local_host_name(), %{ssh: nil, base_dir: base_dir, cli_bin: nil})

    Enum.reduce(registered_toolchain_dirs(db), configured, fn {host, dirs}, acc ->
      case Map.fetch(acc, host) do
        {:ok, host_config} ->
          Map.put(acc, host, Map.put(host_config, :toolchain_dirs, dirs))

        :error ->
          raise "host toolchain registry contains rows for unknown host: #{host}"
      end
    end)
  end

  # Placement's own callers hand it the gateway config, which carries both the
  # DB owner and the base_dir the local entry is built from.
  defp hosts_for(config), do: hosts(config.base_dir, Map.get(config, :db, DB))

  @doc "The named denial for a host absent from the configured host registry."
  @spec unknown_host_denial(String.t(), String.t() | nil) :: %{
          code: String.t(),
          message: String.t()
        }
  def unknown_host_denial(host, harness \\ nil) do
    harness_scope = if harness, do: " for #{harness}", else: ""

    %{
      code: "unknown_host",
      message:
        "host #{host} is not configured#{harness_scope}; run tightbeam assimilate " <>
          "<ssh-dest> --name #{host} --as-user <adminUserId>"
    }
  end

  @doc "Set one host- and harness-scoped environment overlay after write-time validation."
  @spec set_env_overlay(
          DB.server(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, map()}
  def set_env_overlay(db, host, harness, name, value, set_by) do
    with :ok <- valid_env_name(name),
         {:ok, _module} <- known_harness(harness),
         :ok <- unreserved_env_name(name) do
      set_at = System.system_time(:millisecond)

      case DB.transaction(db, fn txn ->
             if known_host_in_txn?(txn, host) do
               DB.Txn.q(
                 txn,
                 """
                 INSERT INTO harness_env_overlays (host, harness, name, value, setBy, setAt)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(host, harness, name) DO UPDATE SET
                   value = excluded.value,
                   setBy = excluded.setBy,
                   setAt = excluded.setAt
                 """,
                 [host, harness, name, value, set_by, set_at]
               )

               {:ok,
                %{
                  host: host,
                  harness: harness,
                  name: name,
                  value: value,
                  set_by: set_by,
                  set_at: set_at
                }}
             else
               denial = unknown_host_denial(host, harness)

               {:error, %{denial | message: "unknown_host rule: " <> denial.message}}
             end
           end) do
        {:ok, result} -> result
        {:error, error} -> raise error
      end
    end
  end

  @doc "List stored overlay rows, optionally filtered by exact host and harness."
  @spec env_overlays(DB.server(), String.t() | nil, String.t() | nil) :: [map()]
  def env_overlays(db, host \\ nil, harness \\ nil) do
    {where, params} =
      case {host, harness} do
        {nil, nil} -> {"", []}
        {host, nil} -> {" WHERE host = ?1", [host]}
        {nil, harness} -> {" WHERE harness = ?1", [harness]}
        {host, harness} -> {" WHERE host = ?1 AND harness = ?2", [host, harness]}
      end

    {:ok, rows} =
      DB.query(
        db,
        "SELECT host, harness, name, value, setBy, setAt FROM harness_env_overlays" <>
          where <> " ORDER BY host, harness, name",
        params
      )

    Enum.map(rows, fn [row_host, row_harness, name, value, set_by, set_at] ->
      %{
        host: row_host,
        harness: row_harness,
        name: name,
        value: value,
        set_by: set_by,
        set_at: set_at
      }
    end)
  end

  @doc "Remove one exact overlay row."
  @spec unset_env_overlay(DB.server(), String.t(), String.t(), String.t()) :: map()
  def unset_env_overlay(db, host, harness, name) do
    {:ok, removed} =
      DB.transaction(db, fn txn ->
        DB.Txn.q(
          txn,
          "DELETE FROM harness_env_overlays WHERE host = ?1 AND harness = ?2 AND name = ?3",
          [host, harness, name]
        )

        DB.Txn.changes(txn) == 1
      end)

    %{host: host, harness: harness, name: name, removed: removed}
  end

  @doc "Replace one host's ordered toolchain directories in the host registry."
  @spec set_toolchain_dirs(DB.server(), String.t(), [String.t()], String.t()) ::
          {:ok, map()} | {:error, map()}
  def set_toolchain_dirs(db, host, dirs, set_by) when is_list(dirs) do
    set_at = System.system_time(:millisecond)

    case DB.transaction(db, fn txn ->
           if known_host_in_txn?(txn, host) do
             DB.Txn.q(txn, "DELETE FROM host_toolchain_dirs WHERE host = ?1", [host])

             dirs
             |> Enum.with_index()
             |> Enum.each(fn {dir, position} ->
               DB.Txn.q(
                 txn,
                 """
                 INSERT INTO host_toolchain_dirs (host, position, dir, setBy, setAt)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 """,
                 [host, position, dir, set_by, set_at]
               )
             end)

             {:ok, %{host: host, dirs: dirs, set_by: set_by, set_at: set_at}}
           else
             denial = unknown_host_denial(host)
             {:error, %{denial | message: "unknown_host rule: " <> denial.message}}
           end
         end) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
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
    host = fetch_session_host!(config, holder_session)
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
    host = fetch_session_host!(config, session)
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
    host = fetch_session_host!(config, session)

    digest =
      :crypto.hash(:sha256, session.session_key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    Path.join([host.base_dir, "work", digest])
  end

  @doc """
  Observe writes under an assignment root without creating it: what was written
  since the prior stamp, plus the current listing.

  No git anywhere. Arming lays an empty stamp file; a later observation asks
  `find -newer` what has been written since and diffs the listing for created
  and deleted paths, then lays the NEXT stamp — so a stamp lives as long as the
  generation that owns it and dies with the workspace it sits in. The stamp
  directory is pruned from the walk, so a stamp can never perturb its own probe.

  ONE mechanism. Local and satellite holders run the same bounded shell probe,
  and nothing may substitute a different observation for it: a caller that could
  replace this wholesale is a pluggable probe framework, which the spec's
  Non-goals refuse. Tests inject at the SHELL (`:sh`), so the command is always
  the one production builds, runs and parses.
  """
  @spec effort_observation(map(), map(), String.t(), term()) ::
          {:ok, map()} | {:error, String.t()}
  def effort_observation(config, session, root, baseline \\ nil) do
    host = fetch_session_host!(config, session)
    stamp_dir = Path.join(workdir_path(config, session), @effort_stamp_dir)
    stamp = Path.join(stamp_dir, "#{Tightbeam.Id.uuid4()}.stamp")
    command = effort_observation_command(root, stamp_dir, stamp, prior_stamp(baseline))
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
        run_bounded(runner, invocation, Map.get(config, :effort_probe_timeout_ms, 8_000))
      end

    case result do
      {:ok, output} -> parse_effort_observation(output, stamp)
      {:error, reason} -> {:error, reason}
    end
  end

  defp prior_stamp({:ok, observation}), do: prior_stamp(observation)
  defp prior_stamp(%{stamp: stamp}) when is_binary(stamp), do: stamp
  defp prior_stamp(_baseline), do: nil

  @doc """
  Stat paths on the host that holds them — the write-detection half of referent
  verification, and the same shape as the effort probe: one bounded invocation
  per host, local or over ssh.

  A present path returns its mtime, so the answer is evidence of a write and not
  merely of existence. `stat` spells its format differently on BSD and GNU, so
  the command tries both; a host with neither reports the path unverifiable
  rather than guessing.

  A host that cannot be reached reports THAT. The answer is about the check, so
  a caller can never turn it into a statement about the claim that named the
  path, or about the credential that failed to reach the host.
  """
  @spec check_origins(map(), String.t(), [String.t()]) ::
          %{String.t() => {:present, integer()} | :absent | {:error, String.t()}}
  def check_origins(_config, _host_name, []), do: %{}

  def check_origins(config, host_name, paths) do
    case hosts_for(config)[host_name] do
      nil ->
        Map.new(paths, &{&1, {:error, "no host named #{host_name} is registered"}})

      host ->
        command = check_origins_command(paths)
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
            run_bounded(runner, invocation, Map.get(config, :effort_probe_timeout_ms, 8_000))
          end

        case result do
          {:ok, output} -> parse_origin_checks(output, paths)
          {:error, reason} -> Map.new(paths, &{&1, {:error, reason}})
        end
    end
  end

  defp check_origins_command(paths) do
    """
    set -u
    for p in #{Enum.map_join(paths, " ", &shell_quote/1)}; do
      if test ! -e "$p"; then
        printf 'A\\t0\\t%s\\n' "$p"
      elif m=$(stat -f %m "$p" 2>/dev/null) || m=$(stat -c %Y "$p" 2>/dev/null); then
        printf 'P\\t%s\\t%s\\n' "$m" "$p"
      else
        printf 'U\\t0\\t%s\\n' "$p"
      fi
    done
    """
  end

  defp parse_origin_checks(output, paths) do
    seen =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "\t", parts: 3) do
          ["P", mtime, path] -> Map.put(acc, path, {:present, String.to_integer(mtime)})
          ["A", _mtime, path] -> Map.put(acc, path, :absent)
          ["U", _mtime, path] -> Map.put(acc, path, {:error, "this host has no usable stat"})
          _ -> acc
        end
      end)

    Map.new(paths, fn path ->
      {path, Map.get(seen, path, {:error, "the check returned no answer for this path"})}
    end)
  end

  @doc """
  Record (or update) a host in the instance registry — the DUMB half of
  assimilation: the CLI ceremony prepares the machine; this writes the fact.
  Admin gating happens in the verb handler, not here. Returns the stored
  config.
  """
  @spec register_host(DB.server(), String.t(), host_config()) :: {:ok, host_config()}
  def register_host(db \\ DB, name, config) do
    entry = %{
      ssh: Map.fetch!(config, :ssh),
      base_dir: Map.fetch!(config, :base_dir),
      cli_bin: Map.get(config, :cli_bin),
      adapter_bin_dir: Map.get(config, :adapter_bin_dir)
    }

    # One row upsert, inside the DB owner's transaction. There is nothing to read
    # first, so there is no window to lose a concurrent registration in.
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        upsert_host_in_txn(txn, name, entry)
        :ok
      end)

    {:ok, entry}
  end

  @doc """
  Write the OPERATOR endpoint file on a satellite: `gateway.json` in the host's
  remote base_dir, mode 0600, naming the gateway's advertised url, the org
  token, and this host's registered name.

  Every agent the gateway launches on a satellite is handed a per-SESSION token
  in its workdir's `.tightbeam-session`. An operator shell has no session and no
  workdir, so `tightbeam onboard` — a three-phase conversation with the gateway,
  which must run ON the host whose credentials it banks — had no url and no
  token at all and died reading a file assimilation never wrote. This is that
  file. It names the ADVERTISED url: the gateway host's own gateway.json carries
  a port, and 127.0.0.1 is correct there and nowhere else.

  Content is staged locally at 0600 and rsynced, never interpolated into an ssh
  command line, so the org token never appears in a remote process table. The
  local host is skipped — `hosts/1` shadows its registry entry, and the gateway
  writes its own gateway.json at boot.
  """
  @spec provision_endpoint(String.t(), String.t(), host_config(), keyword()) ::
          :ok | {:error, :advertised_url_missing | :cli_token_missing}
  def provision_endpoint(base_dir, name, host, opts \\ [])

  def provision_endpoint(_base_dir, _name, %{ssh: nil}, _opts), do: :ok

  def provision_endpoint(base_dir, name, %{ssh: dest} = host, opts) do
    url = Keyword.get(opts, :url) || Application.get_env(:tightbeam, :advertised_url)
    token = Keyword.get(opts, :token) || org_cli_token(base_dir)

    cond do
      name == local_host_name() -> :ok
      url in [nil, ""] -> {:error, :advertised_url_missing}
      token in [nil, ""] -> {:error, :cli_token_missing}
      true -> write_endpoint(base_dir, name, dest, host.base_dir, url, token, opts)
    end
  end

  defp org_cli_token(base_dir) do
    with {:ok, encoded} <- File.read(Path.join(base_dir, "gateway.json")),
         {:ok, %{"cliToken" => token}} <- JSON.decode(encoded),
         true <- is_binary(token) do
      token
    else
      _ -> nil
    end
  end

  defp write_endpoint(base_dir, name, dest, remote_base_dir, url, token, opts) do
    sh = Keyword.get(opts, :sh, &system_cmd/1)
    stage = Path.join([base_dir, "staging", "gateway-files", name])
    stage_file = Path.join(stage, "gateway.json")
    File.mkdir_p!(stage)

    try do
      # `machine` is this host's REGISTERED name. An operator ceremony run here
      # acts on this machine, and the gateway defaults an unnamed one to its own
      # hostname — so onboarding a satellite without it stages credentials into
      # the gateway's directories while the provider CLI writes them here.
      File.write!(stage_file, JSON.encode!(%{url: url, cliToken: token, machine: name}))
      File.chmod!(stage_file, 0o600)
      run!(sh, ["ssh" | @ssh_opts] ++ [dest, "mkdir", "-p", remote_base_dir])

      run!(sh, [
        "rsync",
        "-a",
        "-e",
        Enum.join(["ssh" | @ssh_opts], " "),
        stage_file,
        "#{dest}:#{remote_base_dir}/"
      ])
    after
      File.rm_rf!(stage)
    end

    :ok
  end

  # Portable shell: no git, no mktemp, no GNU-only find predicates. A vanished
  # file mid-walk is not a probe failure, so the walk's own stderr is dropped and
  # only the explicit preconditions (a readable root, a writable stamp) fail.
  #
  # ORDER IS LOAD-BEARING. The next stamp is laid BEFORE the walk, so a write
  # that lands between the two is newer than the new stamp and is caught by the
  # next probe — at worst counted twice, never missed. And the prior stamp is
  # never removed: two observers can read the same armed generation (observation
  # runs before the CAS that picks a winner), and a loser deleting the stamp the
  # winner's row points at would silently blind the next bracket. A stamp per
  # generation accumulates in the workdir and dies with the workspace.
  defp effort_observation_command(root, stamp_dir, stamp, prior) do
    """
    set -u
    root=#{shell_quote(root)}
    stampdir=#{shell_quote(stamp_dir)}
    stamp=#{shell_quote(stamp)}
    prior=#{shell_quote(prior || "")}
    test -d "$root" || { echo "workdir root is unavailable" >&2; exit 1; }
    mkdir -p "$stampdir" || exit 1
    priorState=none
    writes=0
    : > "$stamp" || exit 1
    if test -n "$prior"; then
      if test -e "$prior"; then
        priorState=observed
        writes=$(find "$root" -path "$stampdir" -prune -o -newer "$prior" -print 2>/dev/null | wc -l)
      else
        priorState=missing
      fi
    fi
    printf 'B\\t%s\\t%s\\n' "$priorState" "$writes"
    find "$root" -path "$stampdir" -prune -o -print 2>/dev/null
    """
  end

  defp parse_effort_observation(output, stamp) do
    {header, paths} =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce({nil, []}, fn line, {header, paths} ->
        case String.split(line, "\t") do
          ["B", prior_state, writes] -> {{prior_state, writes}, paths}
          _ -> {header, [line | paths]}
        end
      end)

    case header do
      nil ->
        {:error, "effort observation was unreadable"}

      {prior_state, writes} ->
        sorted = paths |> Enum.uniq() |> Enum.sort()

        {:ok,
         %{
           stamp: stamp,
           prior: prior_state,
           writes: writes |> String.trim() |> String.to_integer(),
           entries: length(sorted),
           digest: :crypto.hash(:sha256, Enum.join(sorted, "\n")) |> Base.encode16(case: :lower)
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

  defp upsert_host_in_txn(txn, name, entry) do
    DB.Txn.q(
      txn,
      """
      INSERT INTO hosts (name, ssh, baseDir, cliBin, adapterBinDir)
      VALUES (?1, ?2, ?3, ?4, ?5)
      ON CONFLICT(name) DO UPDATE SET
        ssh = excluded.ssh, baseDir = excluded.baseDir, cliBin = excluded.cliBin,
        adapterBinDir = excluded.adapterBinDir
      """,
      [
        name,
        entry.ssh,
        entry.base_dir,
        Map.get(entry, :cli_bin),
        Map.get(entry, :adapter_bin_dir)
      ]
    )
  end

  defp valid_env_name(name) when is_binary(name) do
    if Regex.match?(@env_name, name) do
      :ok
    else
      {:error,
       %{
         code: "invalid_env_name",
         message: "invalid_env_name rule: #{inspect(name)} must match [A-Z_][A-Z0-9_]*"
       }}
    end
  end

  defp valid_env_name(name) do
    {:error,
     %{
       code: "invalid_env_name",
       message: "invalid_env_name rule: #{inspect(name)} must match [A-Z_][A-Z0-9_]*"
     }}
  end

  defp known_harness(wire_name) do
    case Enum.find(Harness.all(), &(&1.wire_name() == wire_name)) do
      nil ->
        {:error,
         %{
           code: "unknown_harness",
           message:
             "unknown_harness rule: #{inspect(wire_name)} is not registered; expected one of: " <>
               Enum.map_join(Harness.all(), ", ", & &1.wire_name())
         }}

      module ->
        {:ok, module}
    end
  end

  defp unreserved_env_name(name) do
    credential_env_names = Enum.flat_map(Harness.all(), & &1.credential_env_vars())

    if String.starts_with?(name, "TIGHTBEAM_") or
         name in Tightbeam.Harness.Support.reserved_overlay_env_vars() or
         name in credential_env_names do
      {:error,
       %{
         code: "reserved_env_name",
         message: "reserved_env_name rule: Tightbeam owns #{name}; it cannot be an overlay"
       }}
    else
      :ok
    end
  end

  defp known_host_in_txn?(txn, host) do
    host == local_host_name() or
      DB.Txn.q(txn, "SELECT 1 FROM hosts WHERE name = ?1", [host]) != []
  end

  # No missing-table fallback. A registry table that is not there is a broken
  # substrate, and reading it as "no hosts registered" would deny every spawn
  # while looking like an empty fleet.
  defp registered_hosts(db) do
    {:ok, rows} = DB.query(db, "SELECT name, ssh, baseDir, cliBin, adapterBinDir FROM hosts")

    Map.new(rows, fn [name, ssh, base_dir, cli_bin, adapter_bin_dir] ->
      {name, %{ssh: ssh, base_dir: base_dir, cli_bin: cli_bin, adapter_bin_dir: adapter_bin_dir}}
    end)
  end

  defp registered_toolchain_dirs(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT host, dir FROM host_toolchain_dirs ORDER BY host, position"
      )

    Enum.group_by(rows, fn [host, _dir] -> host end, fn [_host, dir] -> dir end)
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
      configured_hosts = hosts_for(config)
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
        {:error, unknown_host_denial(host)}

      true ->
        {:ok, host}
    end
  end

  defp fetch_session_host!(config, session) do
    case Map.fetch(hosts_for(config), session.host) do
      {:ok, host} ->
        host

      :error ->
        denial = unknown_host_denial(session.host, Map.get(session, :harness))

        raise Refusal,
          code: denial.code,
          host: session.host,
          harness: Map.get(session, :harness),
          message: denial.message
    end
  end

  @doc """
  Build Acp.Adapter start opts for an adapter key per the moduledoc.
  `config` is the Gateway config map (base_dir, cwd, …). Local keys must
  produce exactly the pre-placement behavior. Calls deliver_home/3.
  """
  @spec adapter_opts(map(), adapter_key()) ::
          {:ok, keyword()} | {:error, Harness.launch_refusal()}
  def adapter_opts(config, {harness, identity_name, host} = key) do
    module = Harness.module!(harness)
    host_config = Map.fetch!(hosts_for(config), host)
    sh = Map.get(config, :sh, &system_cmd/1)

    target =
      Map.merge(
        %{
          base_dir: config.base_dir,
          host_config: host_config,
          host_name: host,
          sh: sh,
          cli_bin: config.cli_bin
        },
        Map.get(config, :harness_target_overrides, %{})
      )

    projected_home = Homes.home_path(host_config.base_dir, host, module.id())

    with {:ok, _} <- cursor_locality_before_kind(module, target, projected_home),
         kind = credential_kind(config, module.credential_provider(), host, module.wire_name()),
         {:ok, checked_opts} <-
           Harness.preflight_launch(module, target, projected_home, credential_kind: kind) do
      build_adapter_opts(
        config,
        key,
        module,
        target,
        checked_opts,
        identity_name,
        host,
        host_config,
        sh
      )
    end
  end

  defp build_adapter_opts(
         config,
         {harness, _identity_name, _host} = key,
         module,
         target,
         checked_opts,
         identity_name,
         host,
         host_config,
         sh
       ) do
    ensure_toolchain_dirs!(host, host_config, sh)
    lineage = "tb1-" <> Base.url_encode64("#{harness}@#{host}", padding: false)

    deliver_opts =
      []
      |> then(&if(config[:sh], do: Keyword.put(&1, :sh, config.sh), else: &1))
      |> then(&if(config[:sh_out], do: Keyword.put(&1, :sh_out, config.sh_out), else: &1))

    home = deliver_home(config, key, deliver_opts)

    stderr_path =
      Path.join(config.base_dir, "adapter-#{harness}:#{identity_name}@#{host}.stderr.log")

    overlay_env =
      config
      |> Map.get(:db, DB)
      |> env_overlays(host, module.wire_name())
      |> Enum.map(&{&1.name, &1.value})

    path = adapter_path(config, host_config)

    common_env =
      [
        {"TIGHTBEAM_HOME", config.base_dir},
        {"TIGHTBEAM_MACHINE", host},
        {"PATH", path},
        {"TIGHTBEAM_LINEAGE", lineage}
      ] ++ github_env(config.base_dir) ++ overlay_env

    remote_env =
      if host_config.ssh do
        [
          "TIGHTBEAM_HOME=#{host_config.base_dir}",
          "TIGHTBEAM_MACHINE=#{host}",
          "TIGHTBEAM_URL=#{Application.fetch_env!(:tightbeam, :advertised_url)}",
          "PATH=#{path}",
          "TIGHTBEAM_LINEAGE=#{lineage}",
          # Unconditional on satellites: existence of the banked dir cannot be
          # checked cheaply over ssh, and pointing gh at an absent dir yields
          # the correct answer anyway (needs_onboarding on the satellite's own
          # store), where inheriting the remote user's keyring would repeat the
          # local trap: live from a terminal, unreadable from project work.
          "GH_CONFIG_DIR=#{Tightbeam.Harness.Support.shell_quote(Tightbeam.GithubAuth.config_dir(host_config.base_dir))}"
        ] ++
          Enum.map(overlay_env, fn {name, value} ->
            "#{name}=#{Tightbeam.Harness.Support.shell_quote(value)}"
          end)
      else
        []
      end

    launch_opts =
      [
        common_env: common_env,
        remote_env: remote_env,
        lineage: lineage,
        rails: Rails.hook_settings(),
        statutes: Rails.statutes?(),
        ensure_workdir: &ensure_workdir/4,
        sh_out: Map.get(config, :sh_out)
      ] ++ checked_opts

    base = [
      harness: harness,
      home: home,
      cwd: config.cwd,
      stderr_path: stderr_path,
      process_ssh: host_config.ssh,
      process_identity_dir: host_config.base_dir,
      process_helper: Path.join(host_config[:cli_bin] || config.cli_bin, "tightbeam"),
      on_auth_event: auth_event_handler(config, host, module),
      on_subagent_event: subagent_event_handler(config, host, module),
      env: []
    ]

    with {:ok, plan} <- Harness.prepare_launch(module, target, home, launch_opts) do
      {:ok, Keyword.merge(base, plan)}
    end
  end

  @doc false
  def adapter_opts!(config, key) do
    {:ok, opts} = adapter_opts(config, key)
    opts
  end

  @doc "Preview the exact PATH an adapter on a configured host will receive."
  @spec toolchain_path_preview(map(), String.t()) :: String.t()
  def toolchain_path_preview(config, host) do
    config
    |> hosts_for()
    |> Map.fetch!(host)
    |> then(&adapter_path(config, &1))
  end

  defp adapter_path(config, %{ssh: ssh} = host_config) do
    case Map.fetch(host_config, :toolchain_dirs) do
      {:ok, dirs} ->
        cli_bin = if ssh, do: host_config[:cli_bin], else: config.cli_bin

        [cli_bin | dirs ++ @posix_path]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(":")

      :error when is_nil(ssh) ->
        config.cli_bin <> ":" <> (System.get_env("PATH") || "")

      :error ->
        "#{host_config[:cli_bin] || ""}:$PATH"
    end
  end

  defp ensure_toolchain_dirs!(_host, host_config, _sh)
       when not is_map_key(host_config, :toolchain_dirs), do: :ok

  defp ensure_toolchain_dirs!(host, %{ssh: nil, toolchain_dirs: dirs}, _sh) do
    Enum.each(dirs, fn dir ->
      unless File.dir?(dir) do
        raise "host #{host} toolchain directory is unavailable at adapter start: #{dir}"
      end
    end)
  end

  defp ensure_toolchain_dirs!(host, %{ssh: destination, toolchain_dirs: dirs}, sh) do
    Enum.each(dirs, fn dir ->
      case sh.(["ssh" | @ssh_opts] ++ [destination, "test", "-d", dir]) do
        {_output, 0} ->
          :ok

        {_output, exit} ->
          raise "host #{host} toolchain directory is unavailable at adapter start (exit #{exit}): #{dir}"
      end
    end)
  end

  # The GitHub host capability reaches agents as a path, never as token bytes:
  # `tightbeam onboard github` banks a file-backed gh credential under the base
  # dir, and GH_CONFIG_DIR points gh (and git, through gh's credential helper)
  # at it. The OS login keychain is not an alternative here — agent processes
  # descend from the gateway daemon, and that context cannot read it
  # (errSecInteractionNotAllowed), so a keyring credential probes live from an
  # operator terminal while failing everywhere project work actually runs.
  # Unconditional, banked or not: pointing gh at an absent dir yields the
  # honest answer (needs_onboarding) where ambient fallback would let a store
  # agents cannot reach answer "live".
  defp github_env(base_dir), do: Tightbeam.GithubAuth.env(base_dir)

  @doc """
  Capture same-tier adapter boot inputs in the higher-tier coordinator.

  Adapter opts remain lazy because host delivery may block, but the credential
  lifecycle read must complete before the Adapter process is started.
  """
  @spec adapter_context(map(), adapter_key()) :: keyword()
  def adapter_context(config, {harness, _identity_name, host}) do
    module = Harness.module!(harness)

    [
      credential_kind:
        credential_kind(config, module.credential_provider(), host, module.wire_name())
    ]
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
          | {:error, Harness.launch_refusal()}
  def harness_binary_probe(harness, cli_bin, opts \\ []) do
    module = Harness.module!(harness)

    Harness.probe_cli(module, %{
      cli_bin: cli_bin,
      find_executable: Keyword.get(opts, :find_executable, &System.find_executable/1),
      timeout: Keyword.get(opts, :timeout, 2_000),
      run: Keyword.get(opts, :run, &system_cmd/1)
    })
  end

  defp auth_event_handler(config, host, module) do
    db = Map.get(config, :db, DB)

    fn classification, event ->
      if classification == :terminal do
        Task.Supervisor.start_child(Tightbeam.TurnTaskSupervisor, fn ->
          try do
            HarnessHealth.observe_provider_invalidation(db, module.id(), host, event,
              principal: "process:tightbeam/provider:#{module.credential_provider()}"
            )
          rescue
            error ->
              Logger.error(
                "harness auth incident record failed for #{module.id()} on #{host}: " <>
                  Exception.format(:error, error, __STACKTRACE__)
              )
          end

          mark_result =
            try do
              Tightbeam.Credentials.mark_terminal(
                module.credential_provider(),
                event,
                Tightbeam.Credentials.server(host)
              )
            catch
              :exit, reason -> {:error, {:credential_owner_exit, reason}}
            end

          case mark_result do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.error(
                "credential park failed for #{module.credential_provider()} on #{host}: #{inspect(reason)}"
              )
          end
        end)

        :ok
      end
    end
  end

  defp subagent_event_handler(config, host, module) do
    db = Map.get(config, :db, Tightbeam.DB)

    fn harness_session_id, update ->
      context = %{
        harness: module.id(),
        machine: host,
        harness_session_id: harness_session_id
      }

      captured =
        try do
          Tightbeam.SubagentMarkers.capture_update(
            db,
            module.id(),
            host,
            harness_session_id,
            update
          )
        rescue
          error -> {:capture_failed, {:error, error, __STACKTRACE__}}
        catch
          kind, reason -> {:capture_failed, {kind, reason, __STACKTRACE__}}
        end

      case captured do
        :skip ->
          :ok

        {:capture_failed, failure} ->
          {:error, context, failure}

        captured ->
          event_ref = make_ref()

          case Task.Supervisor.start_child(Tightbeam.TurnTaskSupervisor, fn ->
                 receive do
                   {:consume_subagent_event, ^event_ref, adapter} ->
                     result =
                       try do
                         case Tightbeam.SubagentMarkers.consume_captured(
                                captured,
                                db,
                                Tightbeam.WakeScheduler
                              ) do
                           {:error, reason} -> {:error, {:refused, reason}}
                           marker -> {:ok, marker}
                         end
                       rescue
                         error -> {:error, {:error, error, __STACKTRACE__}}
                       catch
                         kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
                       end

                     send(adapter, {:subagent_event_ingested, event_ref, result})
                 end
               end) do
            {:ok, pid} -> {:async, event_ref, pid, context}
            {:error, reason} -> {:error, context, {:task_start_failed, reason}}
          end
      end
    end
  end

  @doc """
  Materialize the home for an adapter key on its host per the moduledoc.
  Returns the home path AS SEEN BY THE ADAPTER PROCESS (local path for
  local, remote path for remote). opts: :sh (injectable runner,
  `(cmd :: [String.t()]) -> {output :: String.t(), exit :: integer()}`);
  :sh_out (the corresponding stdout-only runner for credential bytes);
  :model (a `Model.t()` to pin instead of the org default — the caller passes
  the provisioning session's resolved model so adapter acceptance tracks
  selection).
  """
  @spec deliver_home(map(), adapter_key(), keyword()) :: String.t()
  def deliver_home(config, {harness, _identity_name, host}, opts \\ []) do
    host_config = Map.fetch!(hosts_for(config), host)
    module = Harness.module!(harness)
    home = Homes.home_path(host_config.base_dir, host, harness)
    sh = Keyword.get(opts, :sh, &system_cmd/1)

    sh_out =
      Keyword.get_lazy(opts, :sh_out, fn ->
        if Keyword.has_key?(opts, :sh), do: sh, else: &system_cmd_out/1
      end)

    module.reconcile_home(
      %{
        base_dir: config.base_dir,
        host_config: host_config,
        host_name: host,
        sh: sh,
        sh_out: sh_out
      },
      home,
      %{
        harness: harness,
        machine: host,
        rails: Rails.hook_settings(),
        # The pinned model tracks the SESSION'S resolved selection when the caller
        # supplies one (`:model`), falling back to the org default only when there
        # is no session context (adapter cold-boot). The claude adapter's offered
        # /accepted model set follows this home pin (wi_263814d3), so pinning the
        # selected model is what makes the adapter accept it at session/new — the
        # cure for the accepted-then-dead class.
        default_model: Keyword.get(opts, :model) || Map.get(config, :default_model),
        auth_dir:
          Tightbeam.Credentials.store_dir(
            host_config.base_dir,
            module.credential_provider()
          )
      }
    )
    |> Map.fetch!(:home_path)
  end

  defp effective_identity_fingerprint(effective) do
    skill_names = effective.skills |> Enum.sort() |> Enum.intersperse(<<0>>)

    :crypto.hash(:sha256, [Archetypes.guidance(effective), <<0>>, skill_names])
    |> Base.encode16(case: :lower)
  end

  defp shell_quote(script), do: "'" <> String.replace(script, "'", "'\\''") <> "'"

  # Remote Cursor is local-only; refuse through harness preflight before any
  # credential-store kind read (Placement.adapter_opts product entry point).
  defp cursor_locality_before_kind(Tightbeam.Harness.Cursor, target, projected_home) do
    if get_in(target, [:host_config, :ssh]) != nil do
      Tightbeam.Harness.Cursor.preflight_launch(target, projected_home, [])
    else
      {:ok, []}
    end
  end

  defp cursor_locality_before_kind(_module, _target, _projected_home), do: {:ok, []}

  defp credential_kind(config, provider, host, harness) do
    case read_credential_kind(config, provider, host) do
      {:error, reason} ->
        code =
          case reason do
            {name, _detail} when is_atom(name) -> Atom.to_string(name)
            _other -> "host_unready"
          end

        raise Refusal,
          code: code,
          host: host,
          harness: harness,
          message:
            "credential kind for #{harness} on host #{host} is unreadable: #{inspect(reason)}"

      kind ->
        kind
    end
  end

  defp read_credential_kind(%{credential_kind: kind}, _provider, _host)
       when is_atom(kind),
       do: kind

  defp read_credential_kind(%{credential_kind: kind}, provider, _host)
       when is_function(kind, 1),
       do: kind.(provider)

  defp read_credential_kind(%{credential_kind: kind}, provider, host)
       when is_function(kind, 2),
       do: kind.(provider, host)

  # Same seam shape as the gateway's and the catalog's credential reads: an
  # injected value or fun wins, otherwise the machine's own lifecycle owner is
  # asked.
  #
  # An unreachable lifecycle owner falls back to `:subscription` — the ONLY kind
  # that existed before this invariant. An owner that answers with an unreadable
  # store is different: it supplied a cause, so placement refuses the host with
  # that cause instead of passing an error tuple as a launch kind.
  defp read_credential_kind(_config, provider, host) do
    server = Tightbeam.Credentials.server(host)

    case GenServer.whereis(server) do
      nil ->
        :subscription

      _pid ->
        case Tightbeam.Credentials.kind(provider, server) do
          :none -> :subscription
          kind -> kind
        end
    end
  end

  defp system_cmd([command | args]), do: System.cmd(command, args, stderr_to_stdout: true)
  defp system_cmd_out([command | args]), do: System.cmd(command, args)

  defp run!(sh, command) do
    case sh.(command) do
      {_output, 0} -> :ok
      {_output, exit} -> raise "command failed with exit #{exit}: #{Enum.join(command, " ")}"
    end
  end
end
