defmodule Tightbeam.Application do
  @moduledoc """
  The supervision tree — the reliability posture in structure (port spec §
  Process architecture). Ordering is `rest_for_one`: the DB is first and
  everything depends on it, so a DB restart deliberately restarts its
  dependents rather than leaving them holding a dead connection.

  Restart intensities are explicit and deliberate: the root tolerates few
  restarts before escalating; the lane DynamicSupervisor tolerates many
  (individual session lanes are cheap and independent). Adapter processes are
  coordinator-managed (a later child), so their restart/backoff policy lives
  in the coordinator, not here.

  Skeleton note: this IS the production tree, not a prototype. The wire
  (Bandit) and AdapterCoordinator are added as their modules land; the shape
  and ownership do not change.
  """

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:tightbeam, :autostart, true) do
      with {:ok, supervisor} <- Supervisor.start_link(children(), root_opts()) do
        base_dir = Application.get_env(:tightbeam, :base_dir, default_base_dir())

        config = %{
          base_dir: base_dir,
          cwd: Application.get_env(:tightbeam, :cwd, File.cwd!()),
          port: Application.get_env(:tightbeam, :port, 4_321),
          default_harness: Application.get_env(:tightbeam, :default_harness, :claude),
          default_model: Application.get_env(:tightbeam, :default_model, "fable"),
          max_live_sessions_per_user: Application.get_env(:tightbeam, :max_live_sessions_per_user, 50),
          wake_tick_ms: Application.get_env(:tightbeam, :wake_tick_ms, 1_000)
        }

        Enum.each(Tightbeam.Gateway.children(config), fn child ->
          {:ok, _pid} = Supervisor.start_child(supervisor, child)
        end)

        {:ok, supervisor}
      end
    else
      # Test env: unit tests own their supervision; boot the tree explicitly.
      Supervisor.start_link([], strategy: :one_for_one, name: Tightbeam.Supervisor)
    end
  end

  @doc "The production child list (also started manually by the app test)."
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    base_dir = Application.get_env(:tightbeam, :base_dir, default_base_dir())
    File.mkdir_p!(base_dir)
    db_path = Path.join(base_dir, "state.db")

    [
      # DB owner first — the serialization seam everything writes through.
      {Tightbeam.DB, path: db_path, name: Tightbeam.DB},
      # Schema + boot epoch as a transient one-shot after the DB is up.
      Tightbeam.Boot,
      # Lane naming registry and the task supervisor for turn work.
      {Registry, keys: :unique, name: Tightbeam.LaneRegistry},
      {Task.Supervisor, name: Tightbeam.TurnTaskSupervisor},
      # Lanes: many cheap independent children -> generous restart intensity.
      {DynamicSupervisor, strategy: :one_for_one, name: Tightbeam.LaneSupervisor, max_restarts: 50, max_seconds: 10}
      # LaneManager (reconciler) is started once a runner is composed by the
      # gateway composition root; see Tightbeam.Gateway (E2).
    ]
  end

  @doc "Root supervisor options — rest_for_one with a tight restart budget."
  @spec root_opts() :: keyword()
  def root_opts, do: [strategy: :rest_for_one, name: Tightbeam.Supervisor, max_restarts: 3, max_seconds: 30]

  @impl true
  def prep_stop(state) do
    # Clean-shutdown stamp MUST happen in prep_stop: stop/1 runs after the
    # supervision tree (and the DB) is already down, so stamping there would
    # silently fail and every shutdown would be inferred dirty at next boot.
    with epoch when is_integer(epoch) <- Application.get_env(:tightbeam, :boot_epoch) do
      try do
        Tightbeam.EventLog.clean_shutdown(Tightbeam.DB, epoch)
      catch
        _, _ -> :ok
      end
    end

    state
  end

  defp default_base_dir, do: Path.join(System.user_home!(), ".tightbeam")
end
