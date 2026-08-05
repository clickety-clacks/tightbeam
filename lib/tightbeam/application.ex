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

  require Logger

  @impl true
  def start(_type, _args) do
    if Application.get_env(:tightbeam, :autostart, true) do
      config = production_config()

      # ONE refusal is quiet here, and it is the one that was asked for: a first run
      # with no registered harness CLI on PATH (task #23 — measured on shrdlu from the
      # npm tarball, the most ordinary first-run state there is).
      #
      # This used to also wrap `start_tree/1` in a try/rescue naming two more refusals,
      # a stale database (Schema.ShapeError) and an identity tree missing its refs.
      # NEITHER ARM COULD EVER FIRE, so neither changed any behaviour:
      #
      #   * the identity refusal raises inside `Gateway.preflight/1`, which is called
      #     BEFORE the try — measured, from this repo's own boot:
      #       (ArgumentError) identity repository is missing required refs: ...
      #         gateway.ex:356: Tightbeam.Gateway.preflight/1
      #         application.ex:28: Tightbeam.Application.start/2
      #   * `Schema.ShapeError` is raised by `Schema.ensure_all/1` inside
      #     `Boot.start_link/1`, a SUPERVISED CHILD. A child's raise never reaches the
      #     caller as an exception; `Supervisor.start_link/2` RETURNS
      #     {:error, {:shutdown, {:failed_to_start_child, Tightbeam.Boot, ...}}}.
      #
      # So both states still produced the crash dump the guard existed to prevent, while
      # the code asserted they did not. Making them work would be a new behaviour change
      # with nothing requiring it, so the dead arms are deleted instead: neither state
      # arises on the fresh install this refusal is for. If a quiet refusal is ever
      # wanted for them, it needs its own authority and its own test.
      case Tightbeam.Gateway.preflight(config) do
        {:ok, installed} -> config |> apply_installed_defaults(installed) |> start_tree()
        {:error, {:no_harness_cli, message}} -> refuse(message)
      end
    else
      # Test env: unit tests own their supervision; boot the tree explicitly.
      Supervisor.start_link([], strategy: :one_for_one, name: Tightbeam.Supervisor)
    end
  end

  defp start_tree(config) do
    with {:ok, supervisor} <- Supervisor.start_link(children(), root_opts()) do
      Enum.each(Tightbeam.Gateway.children_after_preflight(config), fn child ->
        {:ok, _pid} = Supervisor.start_child(supervisor, child)
      end)

      # LAST, deliberately: Bandit's "Running ... (http)" has already been
      # logged by now, and that line reads as a verdict. On an org that cannot
      # run a single turn it was the wrong one, so the real verdict goes after
      # it. Assembled from what boot already knows; it starts nothing and
      # cannot fail the boot.
      report_readiness(config)

      {:ok, supervisor}
    end
  end

  # AN EXPECTED REFUSAL IS NOT A CRASH.
  #
  # Returning `{:error, _}` from `start/2` is correct OTP, and under `mix run` it reads
  # fine. In a RELEASE it does not: the app is permanent, so application_controller
  # escalates the failed start into "Kernel pid terminated", an {exit,terminating,...}
  # stacktrace, and an `erl_crash.dump` in the install directory. Measured on shrdlu from
  # the npm tarball with no harness CLI on PATH — the most ordinary first-run state there
  # is ("I installed tightbeam before I installed claude") presented as a kernel panic.
  #
  # So: say the sentence, exit non-zero, write no dump. `System.halt/1` with an integer
  # status does not dump. Nothing has started at this point — preflight refuses before
  # the supervisor exists — so there is nothing to shut down in order.
  #
  # ONLY NAMED, EXPECTED refusals come here. An unexpected exception must still crash
  # loudly with its dump: a real defect that exits quietly is the silence this codebase
  # spent a night removing.
  # NO TEST SEAM. This path had a public `refuse_for_test/1` and a `:refusal_exit`
  # config hook so a unit test could reach the decision without halting the VM. That put
  # a switch in a production-trusted path which, if ever set or leaked, would let a
  # release keep booting past a refusal it had just printed — silence wearing a message,
  # arranged for the convenience of a test. The refusal is now proven the only way it
  # can honestly be proven: by booting the application in a subprocess with no harness
  # CLI on PATH and reading its exit status and stderr (application_refusal_test.exs).
  defp refuse(message) do
    # STDERR FIRST, SYNCHRONOUSLY. `Logger.error/1` is asynchronous and `System.halt/1`
    # does not flush it — measured: the first version of this fix exited 1 with a
    # ZERO-BYTE log, trading a crash dump for silence, which is the worse of the two.
    # The refusal is a sentence for a person, so it goes to stderr like any CLI's would;
    # the Logger call stays for anything capturing structured logs.
    IO.puts(:stderr, message)
    Logger.error(message)
    System.halt(1)
  end

  # Never allowed to break a boot that would otherwise have succeeded: this is a
  # message, and a message that crashes the thing it describes is worse than no
  # message. Failing to SAY the gateway is unready must not itself make it so.
  defp report_readiness(config) do
    # ASYNC on purpose. The catalog refresh boot kicked off is still in flight at
    # this instant, so reading now would report `unknown` on every healthy start.
    # Waiting for a refresh already running is not a new probe, and boot does not
    # wait for us: start/2 has already returned.
    Task.Supervisor.start_child(Tightbeam.TurnTaskSupervisor, fn ->
      # THE GATEWAY INSTALLS ITS OWN ADAPTERS, before it judges readiness.
      #
      # This used to be deferred to "the next session spawn", which on a fresh
      # org is a moment that never arrives: you cannot spawn until you have
      # onboarded, onboarding VERIFIES by starting a runtime, and that runtime
      # needs the adapter only a spawn would have installed. Circular, and every
      # fresh install hit it — gibson twice, on both providers, surfacing as
      # `harness command could not be executed: No such file or directory`
      # (Flynn, 2026-08-04). Boot printed the npm command as a "manual
      # fallback"; the only change is that we run it instead of describing it.
      #
      # In the readiness task, not inline: a cold npm install is minutes and boot
      # must not block on the network. Failures log and never stop the gateway —
      # one that serves beats one that refuses to start, and readiness already
      # names a missing adapter.
      Tightbeam.Gateway.install_local_adapters(config)
      Tightbeam.Readiness.await_settled()

      config
      |> Tightbeam.Readiness.summary(Tightbeam.ModelCatalog, Tightbeam.Archetypes.all())
      |> Tightbeam.Readiness.render(config)
      |> Enum.each(&Logger.info/1)
    end)
  rescue
    error -> Logger.warning("readiness summary unavailable: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("readiness summary unavailable: #{inspect({kind, reason})}")
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
      {Tightbeam.Boot, base_dir},
      # Lane naming registry and the task supervisor for turn work.
      {Registry, keys: :unique, name: Tightbeam.LaneRegistry},
      {Task.Supervisor, name: Tightbeam.TurnTaskSupervisor},
      # Lanes: many cheap independent children -> generous restart intensity.
      {DynamicSupervisor,
       strategy: :one_for_one, name: Tightbeam.LaneSupervisor, max_restarts: 50, max_seconds: 10}
      # LaneManager (reconciler) is started once a runner is composed by the
      # gateway composition root; see Tightbeam.Gateway (E2).
    ]
  end

  @doc "Root supervisor options — rest_for_one with a tight restart budget."
  @spec root_opts() :: keyword()
  def root_opts,
    do: [strategy: :rest_for_one, name: Tightbeam.Supervisor, max_restarts: 3, max_seconds: 30]

  @doc "True while the gateway is shutting down — lanes refuse new claims."
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get({__MODULE__, :draining}, false)

  # THE DEFAULTS COME FROM WHAT THE BOX HAS, not from a constant.
  #
  # `default_harness` was `hd(Harness.all())` — registry order — and
  # `default_model` was the literal claude-sonnet-5, whatever harness that
  # implied. A codex-only machine therefore placed its first turn on a harness
  # it had never installed, with a model it cannot run, and refused naming a
  # vendor the operator never chose (Flynn, 2026-08-04: "what if i'm a codex
  # only user"). An operator's explicit choice still wins; this only decides
  # what "no preference" means, and it now means "the harness you installed".
  #
  # With BOTH installed and no preference, registry order still decides — but
  # that is a real choice between two working harnesses, not a broken install.
  defp apply_installed_defaults(config, installed) do
    chosen =
      cond do
        Application.get_env(:tightbeam, :default_harness) -> Tightbeam.Harness.default()
        match?([_only], installed) -> Tightbeam.Harness.module!(hd(installed))
        true -> Tightbeam.Harness.default()
      end

    model =
      Application.get_env(:tightbeam, :default_model) || chosen.default_model()

    %{config | default_harness: chosen.id(), default_model: model}
  end

  defp production_config do
    %{
      base_dir: Application.get_env(:tightbeam, :base_dir, default_base_dir()),
      cwd: Application.get_env(:tightbeam, :cwd, File.cwd!()),
      # 11373: the Expanse's 1373 colonized worlds, plus one for Earth (Flynn's
      # port, agreed at project start). The code defaulted to 4321 long after the
      # convention settled, so a bare `tightbeam-gateway` boot landed on a port no
      # client dials — Flynn's first clawline connect to a fresh production install
      # failed exactly there (2026-08-04). The default IS the convention now.
      port: Application.get_env(:tightbeam, :port, 11_373),
      default_harness: Tightbeam.Harness.default().id(),
      default_model:
        Application.get_env(
          :tightbeam,
          :default_model,
          Tightbeam.Model.new("claude-sonnet-5", effort: "medium")
        ),
      max_live_sessions_per_user:
        Application.get_env(:tightbeam, :max_live_sessions_per_user, 50),
      wake_tick_ms: Application.get_env(:tightbeam, :wake_tick_ms, 1_000),
      prod_limit: Application.get_env(:tightbeam, :prod_limit, 3),
      escalation_decision_deadline_ms:
        Application.get_env(:tightbeam, :escalation_decision_deadline_ms, 86_400_000),
      effort_checkin_horizon_ms:
        Application.get_env(:tightbeam, :effort_checkin_horizon_ms, 900_000),
      critical_lease_hard_cap_ms:
        Application.get_env(:tightbeam, :critical_lease_hard_cap_ms, 14_400_000),
      onboarding_lease_ms: Application.get_env(:tightbeam, :onboarding_lease_ms, 1_800_000)
    }
  end

  @impl true
  def prep_stop(state) do
    # Graceful drain (deploys must not eat turns): flip the draining flag so
    # lanes claim nothing new, then wait — bounded — for in-flight turns to
    # finish. Whatever is still running after the deadline dies exactly as a
    # crash would (failed_unknown, published with a reason at next boot);
    # queued turns are durable and simply run after the restart.
    :persistent_term.put({__MODULE__, :draining}, true)

    deadline =
      System.monotonic_time(:millisecond) +
        Application.get_env(:tightbeam, :drain_timeout_ms, 90_000)

    drain_until(deadline)

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

  defp drain_until(deadline) do
    running =
      try do
        {:ok, [[n]]} =
          Tightbeam.DB.query(Tightbeam.DB, "SELECT COUNT(*) FROM turns WHERE status = 'running'")

        n
      catch
        _, _ -> 0
      end

    cond do
      running == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(250)
        drain_until(deadline)
    end
  end

  # The app config is already set from TIGHTBEAM_BASE_DIR by config/runtime.exs,
  # so this is only the fallback — but it shares the one definition of the default
  # so a change cannot land in three places and miss one.
  defp default_base_dir, do: Tightbeam.BaseDir.default()
end
