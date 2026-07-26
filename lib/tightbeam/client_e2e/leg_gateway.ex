defmodule Tightbeam.ClientE2E.LegGateway do
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
  - `homes/` — the codex model catalog reads `models_cache.json` from the
    projected home; without it every spawn dies `catalog_unavailable`.
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
          port_ref: port() | nil,
          log_path: String.t()
        }

  defstruct [:base_dir, :port, :os_pid, :port_ref, :log_path]

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
  @spec boot!(String.t(), :inet.port_number(), keyword()) :: t()
  def boot!(base_dir, port, opts \\ []) do
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
    gateway = %__MODULE__{base_dir: base_dir, port: port, os_pid: os_pid, port_ref: port_ref, log_path: log_path}

    case await_ready(gateway, Keyword.get(opts, :boot_timeout_ms, 60_000)) do
      :ok ->
        gateway

      {:error, reason} ->
        teardown(gateway, remove: false)
        raise "gateway did not come up on port #{port} (#{reason}); log: #{log_path}"
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
  SIGTERMs the gateway, waits for the process to exit, and (by default)
  removes the run-local base directory.
  """
  @spec teardown(t(), keyword()) :: :ok
  def teardown(%__MODULE__{} = gateway, opts \\ []) do
    if gateway.os_pid do
      _ = System.cmd("kill", ["-TERM", Integer.to_string(gateway.os_pid)], stderr_to_stdout: true)
      await_exit(gateway, Keyword.get(opts, :exit_timeout_ms, 30_000))
    end

    if gateway.port_ref && Port.info(gateway.port_ref), do: Port.close(gateway.port_ref)

    if Keyword.get(opts, :remove, true) and run_local?(gateway.base_dir) do
      File.rm_rf!(gateway.base_dir)
    end

    :ok
  end

  # A guard against the one mistake that is not recoverable: removing a real
  # org. The driver only ever deletes directories it provisioned, which are
  # named for this driver.
  defp run_local?(base_dir), do: String.contains?(Path.basename(base_dir), "client-e2e")

  defp await_ready(gateway, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_ready(gateway, deadline)
  end

  defp poll_ready(gateway, deadline) do
    cond do
      ready?(gateway) -> :ok
      System.monotonic_time(:millisecond) >= deadline -> {:error, :timeout}
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
    alive? = match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(gateway.os_pid)], stderr_to_stdout: true))

    cond do
      not alive? -> :ok
      System.monotonic_time(:millisecond) >= deadline -> {:error, :still_running}
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
