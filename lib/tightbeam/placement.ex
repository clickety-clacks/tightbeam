defmodule Tightbeam.Placement do
  @moduledoc """
  Placement mechanics (spec §Placement) — the ONE module that knows hosts
  exist. Everything else addresses identity; this module turns a host NAME
  into an adapter command, a delivered home, and an allow/deny answer.

  Hosts are INSTANCE CONFIG, never DB rows: `Application.get_env(:tightbeam,
  :hosts)` maps name => %{ssh: destination-or-nil, base_dir: path, cli_bin:
  path-or-nil}. The name "local" is RESERVED: the gateway's own machine
  (ssh: nil); it always exists (merged in) and is the default WHERE of every
  archetype. Host names are what archetype `where` lists and session rows
  refer to; the ssh destination is how to reach one. WHY a host set contains
  what it does is the operator's statute — nothing here hardcodes a topology.

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

  @typedoc "A configured host. ssh: nil marks the reserved local host."
  @type host_config :: %{
          required(:ssh) => String.t() | nil,
          required(:base_dir) => String.t(),
          optional(:cli_bin) => String.t() | nil
        }

  @typedoc "Adapter key, widened for placement."
  @type adapter_key :: {harness :: atom(), archetype :: String.t(), host :: String.t()}

  @doc """
  The configured hosts map with "local" always present (ssh: nil, base_dir =
  the gateway's base_dir). Config hosts may not redefine "local" ssh.
  """
  @spec hosts(String.t()) :: %{optional(String.t()) => host_config()}
  def hosts(base_dir) do
    Tightbeam.Skeleton.todo!("TODO(sol): merge %{\"local\" => %{ssh: nil, base_dir: base_dir, cli_bin: nil}} under Application.get_env(:tightbeam, :hosts, %{}) — #{inspect(base_dir)}")
  end

  @doc """
  Resolve + constitutionally check a requested host for an archetype.
  nil → first of archetype.where. Denies (never raises) with
  %{code: "host_not_allowed", message: names the host and the allowed set}
  when host ∉ archetype.where, and %{code: "unknown_host", message: ...}
  when host has no config entry.
  """
  @spec resolve(Archetypes.t(), String.t() | nil, %{optional(String.t()) => host_config()}) ::
          {:ok, String.t()} | {:error, %{code: String.t(), message: String.t()}}
  def resolve(archetype, requested_host, hosts) do
    Tightbeam.Skeleton.todo!("TODO(sol): #{inspect({archetype, requested_host, hosts})}")
  end

  @doc """
  Build Acp.Adapter start opts for an adapter key per the moduledoc.
  `config` is the Gateway config map (base_dir, cwd, …). Local keys must
  produce exactly the pre-placement behavior. Calls deliver_home/3.
  """
  @spec adapter_opts(map(), adapter_key()) :: keyword()
  def adapter_opts(config, {_harness, _archetype, _host} = key) do
    Tightbeam.Skeleton.todo!("TODO(sol): #{inspect({config, key})}")
  end

  @doc """
  Materialize the home for an adapter key on its host per the moduledoc.
  Returns the home path AS SEEN BY THE ADAPTER PROCESS (local path for
  local, remote path for remote). opts: :sh (injectable runner,
  `(cmd :: [String.t()]) -> {output :: String.t(), exit :: integer()}`).
  """
  @spec deliver_home(map(), adapter_key(), keyword()) :: String.t()
  def deliver_home(config, {_harness, _archetype, _host} = key, opts \\ []) do
    _ = Homes
    Tightbeam.Skeleton.todo!("TODO(sol): #{inspect({config, key, opts})}")
  end
end
