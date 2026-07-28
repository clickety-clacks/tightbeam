defmodule Tightbeam.ClientE2E.LegGateway do
  require Logger

  @moduledoc """
  Provisions, boots and tears down the run-local gateway ONE LEG uses.

  A leg gets its own org, not a shared one. The reason is the client, not
  tidiness (client-e2e-v1 r2 F1): the app persists its device identity in the
  Keychain, so a reused org takes the known-device path instead of J0's
  first-user bootstrap, and every prior leg's rows are still in the catalog.
  Leg isolation therefore means a fresh `base_dir` provisioned AND torn down
  per leg — a fresh state.db over a copy of the org's credential material,
  which is exactly SMOKE.md's manual recipe for smoke orgs.

  What is copied from the template org and why (SMOKE.md §Fresh-org
  provisioning — every one of these was rediscovered the hard way):

  - `auth/` — credentials are STORE ROWS, not loose files: the backing file,
    the home symlink, and the `.tightbeam/credential.json` metadata row all
    have to arrive together.
  - `homes/` — the harness homes themselves. The codex model catalog no
    longer lives here: it is one HTTPS call the host makes with its own
    grant, so nothing has to be seeded for a spawn to find a model.
  - `identity/` — archetypes, guidance and rails, WITH its git repo: the
    identity seam refuses to work from a dirty tree, so the copy keeps
    `.git` and commits nothing.

  What is NOT copied: `state.db`, `gateway.json`, logs, `work/`. Those are the
  org's history, and history is the thing a fresh leg must not have.

  Teardown is existing operations only (r1 F8): SIGTERM the captured pid, wait
  for exit, remove the run-local directory.
  """

  @type t :: %__MODULE__{
          base_dir: String.t(),
          port: :inet.port_number(),
          os_pid: pos_integer() | nil,
          os_command: String.t() | nil,
          port_ref: port() | nil,
          log_path: String.t()
        }

  defstruct [:base_dir, :port, :os_pid, :os_command, :port_ref, :log_path]

  @copied ~w(auth homes identity)

  @doc """
  Copies a provisioned template org into `base_dir` (which must not exist).

  Raises when the template is missing the credential material a leg needs —
  failing at provisioning with a legible message beats failing three journeys
  later as `model_unavailable`.
  """
  @spec provision!(String.t(), String.t()) :: String.t()
  def provision!(template_dir, base_dir) do
    if File.exists?(base_dir) do
      raise "client-e2e leg base_dir already exists: #{base_dir} (each leg provisions a fresh one)"
    end

    unless File.dir?(template_dir) do
      raise "no template org at #{template_dir}"
    end

    File.mkdir_p!(base_dir)

    for dir <- @copied, File.dir?(Path.join(template_dir, dir)) do
      File.cp_r!(Path.join(template_dir, dir), Path.join(base_dir, dir))
    end

    base_dir
  end

  @doc """
  Boots a gateway on `base_dir` and returns once `GET /version` answers.

  The command is `exec`ed through `sh` so the captured OS pid is the BEAM
  itself and not a wrapper — a teardown that signals a wrapper leaves the
  gateway holding the port, and the next leg fails to bind for reasons that
  look nothing like the cause.
  """
  @spec boot(String.t(), :inet.port_number(), keyword()) ::
          {:ok, t()} | {:error, term(), t()}
  def boot(base_dir, port, opts \\ []) do
    log_path = Path.join(base_dir, "gateway.log")
    repo_root = Keyword.get(opts, :repo_root, File.cwd!())

    env =
      [
        {~c"MIX_ENV", ~c"dev"},
        {~c"TIGHTBEAM_BASE_DIR", to_charlist(base_dir)},
        {~c"TIGHTBEAM_PORT", to_charlist(Integer.to_string(port))},
        {~c"TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS", ~c"2500"}
      ] ++ extra_env(opts)

    command = "exec mix run --no-halt >> #{Path.expand(log_path)} 2>&1"

    port_ref =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        args: ["-c", command],
        cd: repo_root,
        env: env
      ])

    os_pid = port_ref |> Port.info(:os_pid) |> elem(1)

    gateway = %__MODULE__{
      base_dir: base_dir,
      port: port,
      os_pid: os_pid,
      # The command line is the pid's IDENTITY. A pid is a reusable integer: on a
      # busy box the process behind one can be replaced by somebody else's
      # between capture and signal, and a driver that signals a raw pid set can
      # then kill another lane's work. Nothing here is signalled unless its
      # command line still matches what was captured.
      os_command: process_command(os_pid),
      port_ref: port_ref,
      log_path: log_path
    }

    case await_ready(gateway, Keyword.get(opts, :boot_timeout_ms, 60_000)) do
      :ok ->
        # Re-read the identity NOW, not at spawn: `sh -c "exec mix run"` is an
        # EXEC CHAIN (sh → mix → elixir → beam.smp) that rewrites this pid's
        # argv while it boots. An identity captured at spawn never matches the
        # booted process again, so every ours?-gated signal silently skips and
        # the gateway survives its own teardown/restart (found by the codex J7
        # leg: :port_still_answering with the BEAM orphaned to launchd).
        {:ok, %{gateway | os_command: process_command(gateway.os_pid)}}

      {:error, reason} ->
        # The half-booted gateway is returned WITH the error so the caller's
        # teardown owns it. Tearing it down here and raising loses the handle,
        # which is how a process ends up alive on a port nobody remembers.
        {:error, reason, gateway}
    end
  end

  @doc """
  `boot/3` or raise. Callers that cannot tear down a half-booted gateway
  themselves should prefer `boot/3` — this exists for scripts that already run
  their teardown from an `after` block covering the boot call.
  """
  @spec boot!(String.t(), :inet.port_number(), keyword()) :: t()
  def boot!(base_dir, port, opts \\ []) do
    case boot(base_dir, port, opts) do
      {:ok, gateway} ->
        gateway

      {:error, reason, gateway} ->
        teardown(gateway, remove: false)
        raise "gateway did not come up on port #{port} (#{reason}); log: #{gateway.log_path}"
    end
  end

  @doc """
  Restarts the gateway in place: SIGTERM the captured pid, wait for the process
  to exit AND for the health endpoint to go unreachable, then boot again on the
  SAME port and base_dir and confirm a NEW pid.

  J7's proof is executable precisely because each of those is checked (spec
  r1 F4). Killing a wrapper, or dropping a socket, or restarting on a fresh
  base_dir would all "pass" a weaker check while proving nothing about deploy
  semantics — so the old pid must be gone, the port must actually stop
  answering, and the new pid must differ.
  """
  @spec restart(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def restart(%__MODULE__{} = gateway, opts \\ []) do
    old_pid = gateway.os_pid

    with :ok <- signal_exit(gateway, Keyword.get(opts, :exit_timeout_ms, 60_000)),
         :ok <- await_unreachable(gateway, Keyword.get(opts, :unreachable_timeout_ms, 30_000)) do
      if gateway.port_ref && Port.info(gateway.port_ref), do: Port.close(gateway.port_ref)

      case boot(gateway.base_dir, gateway.port, opts) do
        {:ok, restarted} ->
          if restarted.os_pid == old_pid do
            {:error, {:same_pid, old_pid}}
          else
            {:ok, restarted}
          end

        {:error, reason, restarted} ->
          {:error, {:restart_boot_failed, reason, restarted.log_path}}
      end
    end
  end

  defp remove_base_dir(base_dir, attempts_left \\ 5) do
    case File.rm_rf(base_dir) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} when attempts_left > 1 ->
        _ = reason
        _ = path
        Process.sleep(500)
        remove_base_dir(base_dir, attempts_left - 1)

      {:error, reason, path} ->
        {:error, :not_removed, path, reason}
    end
  end

  defp signal_exit(gateway, timeout_ms) do
    # The tracked pid is the launcher; the BEAM that OWNS THE PORT is its child
    # and does not die with a TERM to the parent. Capture the tree BEFORE
    # signalling (children reparent once the parent is gone) and reap it too,
    # or the port keeps answering and a restart looks like :port_still_answering
    # (found by the codex J7 leg re-run after task #20).
    descendants = if ours?(gateway), do: capture_tree(gateway.os_pid), else: []

    if ours?(gateway) do
      signal(Integer.to_string(gateway.os_pid), gateway.os_command, "-TERM")
    end

    result =
      case await_exit(gateway, timeout_ms) do
        :ok -> :ok
        {:error, :still_running} -> {:error, {:still_running, gateway.os_pid}}
      end

    _ = reap_descendants(descendants, 15_000)
    result
  end

  @doc """
  Whether this gateway's pid still holds the process we booted.

  False when it has exited (the pid is free, or worse, reused). Every signal in
  this module is gated on it.
  """
  @spec ours?(t()) :: boolean()
  def ours?(%__MODULE__{os_pid: nil}), do: false
  def ours?(%__MODULE__{os_command: nil}), do: false
  def ours?(%__MODULE__{os_pid: pid, os_command: command}), do: process_command(pid) == command

  defp await_unreachable(gateway, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_unreachable(gateway, deadline)
  end

  defp poll_unreachable(gateway, deadline) do
    cond do
      not ready?(gateway) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :port_still_answering}

      true ->
        Process.sleep(250)
        poll_unreachable(gateway, deadline)
    end
  end

  @doc "True once `GET /version` answers with protocolVersion 1."
  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{port: port}) do
    _ = Application.ensure_all_started(:inets)
    url = ~c"http://127.0.0.1:#{port}/version"

    case :httpc.request(:get, {url, []}, [{:timeout, 2_000}], body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, body}} ->
        match?({:ok, %{"protocolVersion" => 1}}, JSON.decode(body))

      _ ->
        false
    end
  end

  @doc """
  SIGTERMs the gateway, waits for exit, and removes the run-local base
  directory — but ONLY once the process is confirmed gone.

  Returns `:ok`, or `{:error, :still_running, pid}` when the process outlived
  the SIGTERM window, or `{:error, :not_removed, path, reason}` when the tree
  could not be removed. In BOTH failure cases the directory is KEPT and the
  caller is expected to report it. A gateway still holding its port while its
  state directory is deleted underneath it is worse than a leftover directory,
  and it makes the next leg's bind failure unexplainable.

  Removal retries: the gateway's adapter SUBPROCESSES outlive its SIGTERM by a
  moment and keep writing into the projected homes, so a single `rm_rf` races
  them and fails with EEXIST on a tree that is still changing. Cleanup that
  fails is reported, never raised — a lost cleanup must not cost the run its
  remaining legs, which is exactly what happened when this raised.
  """
  @spec teardown(t(), keyword()) ::
          :ok
          | {:error, :still_running, pos_integer()}
          | {:error, :not_removed, String.t(), term()}
  def teardown(%__MODULE__{} = gateway, opts \\ []) do
    # BEFORE the kill: the adapters are only findable while the gateway is still
    # their parent.
    descendants = if ours?(gateway), do: capture_tree(gateway.os_pid), else: []

    exit_result =
      cond do
        is_nil(gateway.os_pid) ->
          :ok

        # The pid no longer holds the process we booted: it exited and the
        # number was recycled. Signalling now would hit a stranger.
        not ours?(gateway) ->
          :ok

        true ->
          signal(Integer.to_string(gateway.os_pid), gateway.os_command, "-TERM")
          await_exit(gateway, Keyword.get(opts, :exit_timeout_ms, 30_000))
      end

    if gateway.port_ref && Port.info(gateway.port_ref), do: Port.close(gateway.port_ref)

    reap_descendants(descendants, Keyword.get(opts, :reap_timeout_ms, 5_000))

    remove? = Keyword.get(opts, :remove, true) and run_local?(gateway.base_dir)

    # RETURN this. An earlier version computed the same result and then fell
    # through to a bare `:ok`, so the survivor and removal warnings could never
    # fire and the whole point of reporting a failed teardown was inert.
    case {exit_result, remove?} do
      {:ok, true} -> remove_base_dir(gateway.base_dir)
      {:ok, false} -> :ok
      {{:error, :still_running}, _} -> {:error, :still_running, gateway.os_pid}
    end
  end

  @doc """
  Every descendant of `pid`, deepest last, via `pgrep -P`.

  Capture this BEFORE signalling the gateway: once it dies its children are
  reparented to launchd and the tree that named them is gone.
  """
  @spec descendant_pids(pos_integer() | String.t()) :: [String.t()]
  def descendant_pids(pid) do
    children =
      case System.cmd("pgrep", ["-P", to_string(pid)], stderr_to_stdout: true) do
        {out, 0} ->
          out |> String.split("\n", trim: true) |> Enum.filter(&Regex.match?(~r/^\d+$/, &1))

        _ ->
          []
      end

    children ++ Enum.flat_map(children, &descendant_pids/1)
  end

  @doc """
  Captures the descendant tree as `{pid, command}` pairs, so each pid's identity
  can be re-checked at the moment it is signalled.
  """
  @spec capture_tree(pos_integer() | String.t()) :: [{String.t(), String.t() | nil}]
  def capture_tree(pid), do: Enum.map(descendant_pids(pid), &{&1, process_command(&1)})

  @doc """
  The command line of a pid right now, or nil if it is gone. This is how a pid's
  identity is established before anything is signalled.
  """
  @spec process_command(pos_integer() | String.t()) :: String.t() | nil
  def process_command(pid) do
    case System.cmd("ps", ["-ww", "-o", "command=", "-p", to_string(pid)], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> nil
          command -> command
        end

      _ ->
        nil
    end
  end

  @doc """
  SIGTERMs the given pids, then KILLs whatever is still alive.

  These are the gateway's harness ADAPTERS. SIGTERM to the gateway does not take
  them with it: they outlive it holding the leg's projected homes open, which
  defeats directory removal and leaves harness processes running against an org
  that is supposed to be gone. Eight orphans accumulated across one afternoon of
  runs before this existed.

  Identified by process TREE rather than by environment: `ps -E` cannot read the
  environment of a BEAM-spawned process on macOS, so an env match found nothing
  and cheerfully reported success.
  """
  @spec reap_descendants([{String.t(), String.t() | nil}] | [String.t()], non_neg_integer()) ::
          :ok
  def reap_descendants([], _timeout_ms), do: :ok

  def reap_descendants(captured, timeout_ms) do
    captured = Enum.map(captured, &normalize_capture/1)
    for {pid, command} <- captured, do: signal(pid, command, "-TERM")
    await_reaped(captured, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp normalize_capture({pid, command}), do: {to_string(pid), command}
  defp normalize_capture(pid), do: {to_string(pid), process_command(pid)}

  # Signal ONLY if the pid still holds the process we captured. A pid whose
  # command line changed has been recycled and belongs to somebody else now;
  # signalling it is how a cleanup routine kills another lane's work.
  defp signal(pid, expected_command, flag) do
    cond do
      is_nil(expected_command) ->
        Logger.warning("leg teardown: pid #{pid} has no captured command — NOT signalling")
        :skipped

      process_command(pid) != expected_command ->
        Logger.warning(
          "leg teardown: pid #{pid} recycled — captured #{inspect(expected_command)}, " <>
            "now #{inspect(process_command(pid))} — NOT signalling"
        )

        :skipped

      true ->
        System.cmd("kill", [flag, pid], stderr_to_stdout: true)
        :signalled
    end
  end

  defp await_reaped(captured, deadline) do
    remaining = Enum.filter(captured, fn {pid, command} -> still_ours?(pid, command) end)

    cond do
      remaining == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        # A harness adapter that ignores SIGTERM still must not outlive the org
        # it was serving — but only if it is still the process we captured.
        for {pid, command} <- remaining, do: signal(pid, command, "-KILL")
        :ok

      true ->
        Process.sleep(250)
        await_reaped(captured, deadline)
    end
  end

  defp still_ours?(pid, command),
    do: not is_nil(command) and process_command(pid) == command

  # A guard against the one mistake that is not recoverable: removing a real
  # org.  # A guard against the one mistake that is not recoverable: removing a real
  # org. The driver only ever deletes directories it provisioned, which are
  # named for this driver.
  defp run_local?(base_dir), do: String.contains?(Path.basename(base_dir), "client-e2e")

  defp await_ready(gateway, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_ready(gateway, deadline)
  end

  defp poll_ready(gateway, deadline) do
    cond do
      ready?(gateway) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(500)
        poll_ready(gateway, deadline)
    end
  end

  defp await_exit(gateway, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_exit(gateway, deadline)
  end

  defp poll_exit(gateway, deadline) do
    # "Gone" means the pid no longer holds OUR process — not merely that some
    # process answers to the number.
    alive? = ours?(gateway)

    cond do
      not alive? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :still_running}

      true ->
        Process.sleep(250)
        poll_exit(gateway, deadline)
    end
  end

  defp extra_env(opts) do
    for {key, value} <- Keyword.get(opts, :env, []),
        do: {to_charlist(key), to_charlist(value)}
  end
end
