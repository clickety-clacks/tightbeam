defmodule Tightbeam.Gateway do
  @moduledoc """
  The composition root (TS reference: src/gateway.ts — every verb handler and
  the turn pipeline port from there, behavior-for-behavior). Everything below
  this module is independently tested and knows nothing about the whole; this
  module wires stores, pipeline, wire, and adapters together and NOTHING
  else — no logic of its own beyond assembly and the verb handlers.

  Composition strategy (the Elixir-shape decision — binding): there is no
  object graph. Cross-component references are REGISTERED NAMES
  (Tightbeam.DB, Tightbeam.ConnRegistry, Tightbeam.WakeScheduler,
  Tightbeam.AdapterCoordinator, Tightbeam.LaneManager), so there is no
  startup-order circularity: the verb handler table and the turn runner are
  plain funs built here that call names, and every named process is up before
  Bandit accepts a first connection (children order in `children/1`).

  Children appended to Tightbeam.Application's tree, in order:
  ConnRegistry → WakeScheduler → AdapterSupervisor (DynamicSupervisor) →
  AdapterCoordinator → LaneManager (with the runner built here) → Bandit
  (Wire.Router; port + WS upgrade). All under the SAME rest_for_one root —
  a DB restart still restarts everything that could hold stale state.

  The turn pipeline (runner passed to lanes; gateway.ts `runTurn` +
  fifo wiring, adapted to the Ledger):
  1. Lane claims a turn (Ledger). Turn start already broadcast
     accepted/queued by the post/wake handler; the lane's TurnTask broadcasts
     running + typing(on) + activity(on).
  2. Resolve the session (Org); checkout adapter (AdapterCoordinator) — if
     the session's pointer generation is stale, session/load under the load
     semaphore, appending pointer reason "loaded".
  3. No pointer yet → Adapter.new_session, append pointer "created".
  4. Adapter.prompt; append each distinct ACP assistant message to Projection
     (sender "tightbeam", reply_to the echo) in one transaction, then publish
     each committed row via ConnRegistry in seq order.
  5. Terminal: Ledger.finish CAS in the lane; broadcast terminal
     prompt_turn_state + typing(off) + activity(off). Golden frame order for
     the canonical turn: echo → accepted → running → typing(on) →
     activity(on) → ack → assistant → terminal state → typing(off) →
     activity(off).

  Delivery parity (gateway.ts `deliverPrompt`): a user post and a wake are
  the SAME mechanism — append echo to Projection + enqueue exactly one turn
  (Ledger, in ONE transaction: message+turn commit together), broadcast the
  echo, nudge the lane. Wake delivery passes wake_id so the Ledger's UNIQUE
  dedupes at-least-once firing.

  Verb handlers (all built by `handlers/1`, dispatched via Tightbeam.Dispatch;
  port each from gateway.ts's dispatcher.register blocks, including):
  - post (echo+enqueue; dedupe contract), wake (schedule/cancel/immediate
    fire; a wake MUST carry a prompt), condition (file a literal wake fact),
    spawn (idempotency, headcount cap,
    role-name uniqueness, owner inherited from spawn tree), retire (idempotent,
    owner-only), tune (rename | set_model; live-session apply), cancel,
    inspect (owned sessions + owned pending wakes + admin: pending devices),
    approve-device/deny-device/revoke-device/promote-user (admin-gated via
    the origin's owning USER — user-scoped admin).
  - Caller resolution (gateway.ts `resolveCaller`): "user:x" → x;
    "agent:role" → the active role holder's owner; anything else → unknown_caller.
  """

  alias Tightbeam.{
    AdapterCoordinator,
    Archetypes,
    Artifacts,
    Assignments,
    ConditionFacts,
    CriticalLeases,
    Placement,
    DB,
    Devices,
    EffortCheckin,
    Escalation,
    EventLog,
    Harness,
    Homes,
    Identity,
    Idempotency,
    LaneManager,
    Ledger,
    ManagedProcesses,
    Model,
    ModelCatalog,
    Org,
    Projection,
    Rails,
    Rules,
    Roles,
    Schema,
    Spinup,
    SubagentMarkers,
    Supervision,
    Unroutable,
    Wakes,
    WorkItems,
    WorkState
  }

  alias Tightbeam.Acp.Adapter
  alias Tightbeam.DB.Txn
  alias Tightbeam.Wire.Payloads
  require Logger

  defmodule EffortRearmRace do
    @moduledoc false
    defexception message: "effort rearm snapshot changed"
  end

  @typedoc "Gateway config (gateway.ts GatewayConfig)."
  @type config :: %{
          base_dir: String.t(),
          cwd: String.t(),
          port: non_neg_integer(),
          default_harness: atom(),
          default_model: Model.t(),
          max_live_sessions_per_user: pos_integer() | nil,
          wake_tick_ms: pos_integer(),
          prod_limit: non_neg_integer(),
          escalation_decision_deadline_ms: pos_integer(),
          effort_checkin_horizon_ms: pos_integer(),
          critical_lease_hard_cap_ms: pos_integer(),
          onboarding_lease_ms: pos_integer()
        }

  @doc """
  The wire/adapter children to append after Tightbeam.Application's base
  children (see moduledoc order). Also: ensure the complete production schema,
  mint + persist the cliToken and gateway.json (mode 0600) in base_dir, and
  install the CLI bin.
  """
  @spec children(config()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(config) do
    preflight!(config)
    children_after_preflight(config)
  end

  @doc false
  @spec children_after_preflight(config()) :: [Supervisor.child_spec() | {module(), term()}]
  def children_after_preflight(config) do
    db = Map.get(config, :db, Tightbeam.DB)
    prod_limit = Map.get(config, :prod_limit, 3)

    unless is_integer(prod_limit) and prod_limit >= 0 do
      raise ArgumentError, "prod_limit must be an integer >= 0"
    end

    File.mkdir_p!(config.base_dir)

    :ok = Schema.ensure_all(db)

    :ok = Assignments.audit_review_item_conflicts(db)

    # Recover durable liveness before any runtime child can consume wakes or
    # accept traffic. The Supervision child skips its duplicate recovery below.
    :ok = Supervision.recover_liveness!(db, config.wake_tick_ms)

    gateway_path = Path.join(config.base_dir, "gateway.json")

    cli_token =
      with {:ok, encoded} <- File.read(gateway_path),
           {:ok, %{"cliToken" => token}} <- JSON.decode(encoded),
           true <- is_binary(token) and token != "" do
        token
      else
        _ -> "tbc_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
      end

    File.write!(gateway_path, JSON.encode!(%{port: config.port, cliToken: cli_token}))
    File.chmod!(gateway_path, 0o600)
    provision_host_endpoints(db, config, cli_token)
    cli_bin = install_cli_bin(config.base_dir)
    defaults = defaults(config, db)
    # Post-commit recognition: both consumers of a committed terminal are
    # FIRE-AND-FORGET casts into their own processes — the bubble sweeper and
    # the supervision shift. Neither may run inside the lane or the
    # LaneManager: recognition enqueues turns, enqueueing rings the
    # LaneManager, and a synchronous hook is then a call to self (review B1
    # found exactly that deadlock on the boot path).
    on_terminal = fn session_key, seq ->
      Tightbeam.Productions.BubbleSweeper.recognize(seq)
      Supervision.notify_terminal(session_key, seq)
    end

    on_retired = fn session_key ->
      Supervision.notify_retired(session_key)
    end

    handler_table =
      config
      |> Map.put(:db, db)
      |> Map.put(:on_retired, on_retired)
      |> handlers()

    runner = turn_runner(Map.put(config, :db, db))

    # Identity is loaded at composition time; a malformed manifest fails the
    # boot (bad law stops the boot). Placement owns every host mechanic.
    reload_law!(config, Map.keys(handler_table))
    Enum.each(Harness.all(), &Homes.sweep_auth(config.base_dir, &1.id()))

    adapter_config = config |> Map.put(:cli_bin, cli_bin) |> Map.put(:db, db)
    adapter_context = fn key -> Placement.adapter_context(adapter_config, key) end

    adapter_opts = fn key, context ->
      adapter_config
      |> Map.merge(Map.new(context))
      |> Placement.adapter_opts(key)
    end

    socket_deps = %{
      db: db,
      handlers: handler_table,
      conn_registry: Tightbeam.ConnRegistry,
      defaults: defaults
    }

    router_deps =
      Map.merge(socket_deps, %{
        base_dir: config.base_dir,
        cli_token: cli_token,
        session_status: fn session_key -> session_status(session_key, db, config) end,
        adapter_coordinator: Tightbeam.AdapterCoordinator
      })

    # EDGE half of the heal trigger. Off the coordinator's process: the sweep
    # opens transactions and broadcasts, and the coordinator must never block on
    # either (adapter checkouts queue behind it). Idempotence is durable — one
    # probe per (hold, token) — so an at-least-once, unordered invocation is safe.
    # The configured delivery dependencies, forwarded to every prompt wake: a
    # wake consumer never constructs or substitutes its own delivery config.
    delivery_config = [
      conn_registry: config[:conn_registry] || Tightbeam.ConnRegistry,
      lane_manager: config[:lane_manager] || Tightbeam.LaneManager
    ]

    deliver = fn wake ->
      case wake.target_role do
        role when is_binary(role) ->
          case Roles.resolve(db, role) do
            {:ok, session_key, fallback} ->
              deliver_prompt(
                session_key,
                wake.origin,
                wake.prompt,
                [
                  db: db,
                  wake_id: wake.wake_id,
                  sender: wake.origin,
                  role_ref: role,
                  role_fallback: fallback
                ] ++ delivery_config
              )

            {:error, %{code: "unknown_role"}} ->
              EventLog.lifecycle(
                db,
                "wake_unresolved",
                wake.wake_id,
                "role #{role} no longer exists"
              )
          end

        nil ->
          deliver_prompt(
            wake.session_key,
            wake.origin,
            wake.prompt,
            [
              db: db,
              wake_id: wake.wake_id,
              sender: wake.origin,
              # targetGate = 0 (decision notifications) delivers to the recorded
              # sessionKey unconditionally; every other wake keeps its gate.
              target_gate: if(wake.target_gate == 0, do: nil, else: wake),
              fire_wake_in_txn: wake.origin == "process:tightbeam"
            ] ++ delivery_config
          )
      end
    end

    credential_children(config, db) ++
      [
        {ModelCatalog, base_dir: config.base_dir, db: db},
        {Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry},
        # Ahead of Supervision and Bandit deliberately: both can reach a check-tier
        # statute, and the episode writer must already own the ordering before the first
        # evaluation runs. Explicitly a child rather than lazily started — a lazy start
        # would let a missing spec here go unnoticed in production forever.
        {Tightbeam.RailEpisodes, name: Tightbeam.RailEpisodes},
        # Ahead of Bandit for the same reason: the hook seam posts to the wire,
        # so the window's writer must own the ordering before the first
        # observation can arrive.
        {Tightbeam.TurnObservations, name: Tightbeam.TurnObservations},
        {Tightbeam.Wakes,
         db: db,
         deliver: deliver,
         internal_consumers: %{
           "effort_probe" => &EffortCheckin.probe(db, config, &1),
           "effort_deadline" => &EffortCheckin.deadline(db, config, &1)
         },
         tick_ms: config.wake_tick_ms,
         name: Tightbeam.WakeScheduler},
        {Tightbeam.Supervision,
         db: db,
         handlers: handler_table,
         prod_limit: prod_limit,
         recover: false,
         sweep_ms: config.wake_tick_ms,
         name: Tightbeam.Supervision},
        {Tightbeam.Spinup.Flight, name: Tightbeam.Spinup.Flight},
        {DynamicSupervisor, strategy: :one_for_one, name: Tightbeam.AdapterSupervisor},
        {Tightbeam.AdapterCoordinator,
         adapter_sup: Tightbeam.AdapterSupervisor,
         adapter_context: adapter_context,
         adapter_opts: adapter_opts,
         db: db,
         name: Tightbeam.AdapterCoordinator},
        {Tightbeam.Productions.BubbleSweeper, db: db},
        {Tightbeam.LaneManager,
         db: db,
         lane_sup: Tightbeam.LaneSupervisor,
         task_sup: Tightbeam.TurnTaskSupervisor,
         runner: runner,
         terminal_publisher: terminal_publisher(db),
         on_terminal: on_terminal,
         name: Tightbeam.LaneManager},
        {Bandit, plug: {Tightbeam.Wire.Router, router_deps}, port: config.port}
      ]
  end

  @doc """
  Check harness and identity readiness before the production store is created.

  Returns WHICH harnesses are installed, not merely that one is: the defaults a
  fresh org runs on are derived from what the box actually has, and throwing
  that away is why a codex-only machine defaulted to claude and claude-sonnet-5
  (Flynn, 2026-08-04).
  """
  @spec preflight(config()) :: {:ok, [atom()]} | {:error, {:no_harness_cli, String.t()}}
  def preflight(config) do
    with {:ok, installed} <- harness_binary_readiness(Path.join(config.base_dir, "bin")) do
      Identity.init!(config.base_dir)
      {:ok, installed}
    end
  end

  @doc "Raise for every preflight refusal; used by callers that require bang semantics."
  @spec preflight!(config()) :: [atom()]
  def preflight!(config) do
    case preflight(config) do
      {:ok, installed} -> installed
      {:error, {:no_harness_cli, message}} -> raise message
    end
  end

  defp credential_children(config, db) do
    Enum.map(Placement.hosts(config.base_dir, db), fn {machine, host} ->
      credential_child(config, db, machine, host)
    end)
  end

  defp credential_child(config, db, machine, host) do
    opts =
      [
        name: Tightbeam.Credentials.server(machine),
        base_dir: host.base_dir,
        staging_base_dir: config.base_dir,
        machine: machine,
        ssh: host.ssh,
        gate: fn _provider -> :ok end,
        stop: fn provider -> stop_provider_runtime(provider, machine) end,
        park_edge: Tightbeam.CommandEdge.request_to(Tightbeam.AdapterCoordinator),
        start: fn provider, kind -> start_provider_runtime(provider, kind, machine) end,
        resume: fn _provider -> :ok end,
        capture_sessions: fn provider ->
          capture_credential_sessions(db, provider, machine)
        end,
        publish_sessions: fn captured, transition ->
          publish_credential_sessions(db, captured, transition)
        end,
        on_credential_present: credential_present_hook(db, machine),
        onboarding_lease_ms: config.onboarding_lease_ms,
        log_event: fn kind, subject, detail ->
          Tightbeam.EventLog.lifecycle(db, kind, subject, detail)
        end
      ]
      |> maybe_put_credential_runner(config)

    %{
      id: {Tightbeam.Credentials, machine},
      start: {Tightbeam.Credentials, :start_link, [opts]}
    }
  end

  @doc """
  The `on_credential_present/1` hook wired into the credential lifecycle owner
  (`credential_child/4`), invoked by `credentials.ex` at onboarding-commit
  success with the committed provider. On a credential commit for
  `{machine, provider}` it files the substrate-observed `credential-present`
  condition-fact — the durable transition record (I5) — via a plain transaction
  (never `Wakes.fire_matching`, which targets sessions), then POST-COMMIT hands
  the fact to the `CatalogRederive` production, which recognizes it and
  re-derives the catalog. The credential code triggers the PRODUCTION, never
  `ModelCatalog` directly — that is the I5 line. Public and parameterized by the
  catalog server so the injector is exercisable without driving a full ceremony;
  the fact is best-effort (a dropped edge self-heals via the catalog's TTL
  sweep), so a filing error is logged, not raised into the commit.
  """
  @spec credential_present_hook(DB.server(), String.t(), GenServer.server()) :: (atom() -> :ok)
  def credential_present_hook(db, machine, catalog \\ ModelCatalog) do
    fn provider ->
      scope = "#{machine}:#{provider}"

      case DB.transaction(db, fn txn ->
             ConditionFacts.file_in_txn(txn, %{
               kind: "credential-present",
               scope: scope,
               origin: "process:tightbeam"
             })
           end) do
        {:ok, %{fact_id: fact_id}} ->
          Tightbeam.Productions.CatalogRederive.recognize(db, catalog, fact_id)

        other ->
          Logger.error("credential-present fact for #{scope} not filed: #{inspect(other)}")
      end

      :ok
    end
  end

  defp start_credential_child(config, db, machine, previous_host, host) do
    # The LOCAL credential server is boot-owned, and Placement.hosts/1 forces
    # the synthetic local entry regardless of the registry — re-registering the
    # gateway's own hostname must never replace it (a foreign base_dir plus a
    # non-nil ssh here wedges every local spawn until restart, fail-closed).
    if machine == Placement.local_host_name() do
      :ok
    else
      start_remote_credential_child(config, db, machine, previous_host, host)
    end
  end

  defp start_remote_credential_child(config, db, machine, previous_host, host) do
    supervisor = Map.get(config, :credential_supervisor, Tightbeam.Supervisor)
    child = credential_child(config, db, machine, host)

    case Supervisor.start_child(supervisor, child) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        if same_credential_host?(previous_host, host) do
          :ok
        else
          replace_credential_child(supervisor, child, machine)
        end

      {:error, :already_present} ->
        replace_credential_child(supervisor, child, machine)

      {:error, reason} ->
        raise "failed to start credential server for host #{machine}: #{inspect(reason)}"
    end
  end

  defp same_credential_host?(nil, _host), do: false

  defp same_credential_host?(previous, current),
    do: previous.base_dir == current.base_dir and previous.ssh == current.ssh

  defp replace_credential_child(supervisor, child, machine) do
    with :ok <- Supervisor.terminate_child(supervisor, child.id),
         :ok <- Supervisor.delete_child(supervisor, child.id),
         {:ok, _pid} <- Supervisor.start_child(supervisor, child) do
      :ok
    else
      {:error, reason} ->
        raise "failed to start credential server for host #{machine}: #{inspect(reason)}"
    end
  end

  defp maybe_put_credential_runner(opts, config) do
    opts = if config[:sh], do: Keyword.put(opts, :sh, config.sh), else: opts
    if config[:sh_out], do: Keyword.put(opts, :sh_out, config.sh_out), else: opts
  end

  defp provision_opts(config), do: if(config[:sh], do: [sh: config.sh], else: [])

  defp endpoint_failure_message(:advertised_url_missing, machine) do
    "#{machine} is registered, but this gateway has no advertised url, so nothing on #{machine} " <>
      "can reach it: set TIGHTBEAM_ADVERTISED_URL to an address #{machine} can dial, restart the " <>
      "gateway, and re-run assimilate"
  end

  defp endpoint_failure_message(:cli_token_missing, machine) do
    "#{machine} is registered, but this gateway's own gateway.json carries no cliToken, so no " <>
      "endpoint could be written for it"
  end

  # Satellites registered before this boot — including every host assimilated
  # before the endpoint file existed, and every host whose org token has since
  # been rotated — are re-provisioned here, so the operator shell heals without a
  # ceremony. Best effort by construction: an unreachable satellite is a logged
  # fact, never a failed boot.
  # The gateway resolves its DB owner once at boot (`Map.get(config, :db, ...)`);
  # handler-scoped functions that were only ever handed `config` resolve it the
  # same way rather than reaching for the global name directly.
  defp gateway_db(config), do: Map.get(config, :db, Tightbeam.DB)

  defp provision_host_endpoints(db, config, cli_token) do
    config.base_dir
    |> Placement.hosts(db)
    |> Enum.each(fn {name, host} ->
      opts = [token: cli_token] ++ provision_opts(config)

      result =
        try do
          Placement.provision_endpoint(config.base_dir, name, host, opts)
        rescue
          error -> {:error, Exception.message(error)}
        end

      with {:error, reason} <- result do
        EventLog.lifecycle(db, "endpoint_not_provisioned", name, to_string(reason))
      end
    end)
  end

  defp harness_binary_readiness(cli_bin) do
    results =
      Enum.map(Harness.all(), fn module ->
        {module.id(), Placement.harness_binary_probe(module.id(), cli_bin)}
      end)

    cond do
      Enum.any?(results, fn {_harness, result} -> match?({:ok, _}, result) end) ->
        # REPORT THE ONES THAT FAILED, even though another succeeded. This used
        # to return :ok the moment ANY harness probed, discarding the rest — so
        # a codex installed as a `.js` with a `#!/usr/bin/env node` shebang, on a
        # box where node is not on the default PATH, was INSTALLED and
        # UNRUNNABLE and boot said nothing. The org then reported it as merely
        # un-onboarded, and the truth surfaced during OAuth as
        # `{:provider_runtime_start_failed, %{failed: [%{reason: :degraded}]}}`
        # — a credential written to disk and a verification that could never
        # pass (Flynn, gibson, 2026-08-04). Present and runnable are two
        # different facts; probing both and reporting one is the house defect.
        for {harness, {:error, reason}} <- results do
          Logger.warning(
            "harness #{harness} is installed but CANNOT RUN: " <>
              describe_probe_failure(reason) <>
              " — no session will be placed on it until this is fixed."
          )
        end

        {:ok, for({harness, {:ok, _}} <- results, do: harness)}

      Enum.all?(results, fn {_harness, result} -> result == {:error, :not_found} end) ->
        binaries = Enum.map_join(Harness.all(), " or ", &"`#{&1.cli_binary()}`")

        {:error,
         {:no_harness_cli,
          "Tight Beam cannot start because no registered harness CLI is installed. " <>
            "That is expected on a fresh machine. Install #{binaries}, ensure it is on PATH, " <>
            "then start Tight Beam again. Run `tightbeam doctor` to check this machine."}}

      true ->
        detail =
          Enum.map_join(results, "; ", fn {harness, result} ->
            reason =
              case result do
                {:error, :not_found} -> "not found"
                {:error, {:exec_failed, exec_detail}} -> "exec failed: #{exec_detail}"
              end

            "#{harness}: #{reason}"
          end)

        raise "no usable harness CLI is installed (#{detail}). Install a registered harness CLI and ensure it is on PATH."
    end
  end

  defp describe_probe_failure(:not_found), do: "its CLI is not on PATH"

  defp describe_probe_failure({:exec_failed, detail}),
    do: "its CLI is on PATH but failed to execute (#{String.trim(detail)})"

  defp describe_probe_failure(other), do: inspect(other)

  @doc """
  Install the pinned ACP adapters for every registered harness on the local host.

  Called from the readiness task at boot (see application.ex for why this is not
  deferred to a session spawn). Never raises: a provisioning failure is logged and
  reported by the readiness summary, not fatal.
  """
  @spec install_local_adapters(config()) :: :ok
  def install_local_adapters(config) do
    local = Placement.local_host_name()

    for module <- Harness.all() do
      case Tightbeam.Spinup.ensure_ready(config, module.id(), local, db: gateway_db(config)) do
        :ok ->
          :ok

        {:error, denial} ->
          Logger.warning(
            "adapter provisioning for #{module.wire_name()} on #{local} did not complete: " <>
              denial.message
          )
      end
    end

    :ok
  end

  @doc "The immutable verb-handler table (see moduledoc list) — built once, passed to Dispatch."
  @spec handlers(config()) :: Tightbeam.Dispatch.handlers()
  def handlers(config) do
    db = Map.get(config, :db, Tightbeam.DB)

    assignment_change = fn assignment_id, from ->
      emit_assignment_change(db, assignment_id, from)
    end

    item_change = fn work_item_id, kind -> emit_item_change(db, work_item_id, kind) end

    %{
      "post" => fn call ->
        p = call.params

        outcome =
          deliver_prompt(call.session_key, call.origin, p.content,
            db: db,
            device_id: p.device_id,
            client_message_id: p.client_message_id,
            attachments: Map.get(p, :attachments, [])
          )

        if outcome == :appended,
          do: %{ack: p.client_message_id},
          else: %{dedupe: to_string(outcome)}
      end,
      "wake" => fn call ->
        p = call.params

        cond do
          is_binary(p[:cancel_wake_id]) ->
            cancel_wake_result(db, call, p.cancel_wake_id)

          not (is_binary(p[:prompt]) and p.prompt != "") ->
            %{code: "invalid", message: "a wake must carry a prompt"}

          not valid_reresolve?(p) ->
            %{code: "invalid", message: "reresolve lineage requires seed and rung"}

          is_binary(p[:condition_scope]) and not is_binary(p[:condition_kind]) ->
            %{code: "invalid", message: "--when-scope requires --when-fact"}

          is_binary(p[:condition_kind]) and is_nil(p[:after_ms]) and is_nil(p[:at]) ->
            %{
              code: "invalid",
              message: "a condition wake requires a fallback (--fallback-after / --at)"
            }

          not wake_principal_allowed?(db, call) ->
            %{code: "unknown_caller"}

          true ->
            wake_result(config, db, call)
        end
      end,
      "condition" => fn call ->
        p = call.params

        cond do
          not (is_binary(p[:kind]) and p.kind != "") ->
            %{code: "invalid", message: "a condition fact requires a kind"}

          # `work-blocked`/`work-unblocked` assert an authority's judgment
          # over a session (spec production-machine-v1 §Standing facts): the
          # scope must be a session, and the caller must sit ABOVE it in the
          # spawnedBy lineage, or be its owner (user or admin). ConditionFacts
          # itself refuses the substrate; this seam refuses the unauthorized.
          p.kind in ~w(work-blocked work-unblocked) and
              not work_block_authority?(db, call, p[:scope]) ->
            %{
              code: "not_authorized",
              message:
                "#{p.kind} may only be asserted by the scope session's lineage " <>
                  "above it or its owner, over an existing session scope"
            }

          true ->
            scheduler = Map.get(config, :wake_scheduler, Tightbeam.WakeScheduler)

            case ConditionFacts.file_idempotent(db, scheduler, %{
                   kind: p.kind,
                   scope: p[:scope],
                   origin: call.origin,
                   idempotency_key: p[:idempotency_key]
                 }) do
              {:error, error} -> error
              fact -> fact
            end
        end
      end,
      "facts-read" => fn call -> facts_read_result(db, call) end,
      "artifact-record" => fn call -> Artifacts.record(db, call) end,
      "artifact-get" => fn call ->
        Artifacts.get(db, call.params[:artifact_id]) || %{code: "not_found"}
      end,
      "artifacts" => fn call -> %{artifacts: Artifacts.list(db, call.params)} end,
      "rule" => fn call ->
        Escalation.rule(db, call,
          authorized: admin_origin?(db, call.origin),
          scheduler: Map.get(config, :wake_scheduler, Tightbeam.WakeScheduler)
        )
      end,
      "effort-rule" => fn call -> EffortCheckin.rule(db, config, call) end,
      "waive" => fn call ->
        Escalation.waive(db, call,
          authorized: admin_origin?(db, call.origin),
          scheduler: Map.get(config, :wake_scheduler, Tightbeam.WakeScheduler)
        )
      end,
      "revoke-waiver" => fn call ->
        Escalation.revoke_waiver(db, call, authorized: admin_origin?(db, call.origin))
      end,
      "withdraw" => fn call -> Escalation.withdraw(db, call) end,
      "operator-ask" => fn call -> Escalation.operator_ask(db, call) end,
      "operator-rule" => fn call -> Escalation.operator_rule(db, call) end,
      "operator-withdraw" => fn call -> Escalation.operator_withdraw(db, call) end,
      "decision-requests" => fn call ->
        case Escalation.list_status(call.params[:status]) do
          {:ok, status} ->
            caller = resolve_caller(db, call.origin)

            %{
              decision_requests:
                Escalation.list(db, call, status,
                  owner_user_id: caller && caller.owner_user_id,
                  admin: admin_origin?(db, call.origin)
                )
            }

          %{code: _} = err ->
            err
        end
      end,
      "decision-request" => fn call ->
        caller = resolve_caller(db, call.origin)
        id = call.params[:request_id] || call.params[:request]

        case Escalation.get(db, call, id,
               owner_user_id: caller && caller.owner_user_id,
               admin: admin_origin?(db, call.origin)
             ) do
          nil -> %{code: "not_found", message: "decision request not found"}
          request -> %{decision_request: request}
        end
      end,
      "approve-device" =>
        admin_handler(db, fn p ->
          d = Devices.approve(db, p.device_id, p[:user_id])
          %{approved: %{device_id: d.device_id, user_id: d.user_id, is_admin: d.is_admin}}
        end),
      "deny-device" =>
        admin_handler(db, fn p ->
          Devices.deny(db, p.device_id)
          %{denied: p.device_id}
        end),
      "revoke-device" =>
        admin_handler(db, fn p ->
          Devices.revoke(db, p.device_id)
          %{revoked: p.device_id}
        end),
      "host-env-set" =>
        admin_call_handler(db, fn call ->
          p = call.params

          case Placement.set_env_overlay(
                 db,
                 p.host,
                 p.harness,
                 p.name,
                 p.value,
                 call.origin
               ) do
            {:ok, row} ->
              Map.put(
                row,
                :effect,
                "takes effect on next #{p.harness} adapter start on #{p.host}"
              )

            {:error, denial} ->
              denial
          end
        end),
      "host-env-list" => fn call ->
        %{
          overlays: Placement.env_overlays(db, call.params[:host], call.params[:harness])
        }
      end,
      "host-env-unset" =>
        admin_call_handler(db, fn call ->
          p = call.params
          Placement.unset_env_overlay(db, p.host, p.harness, p.name)
        end),
      "host-toolchain-set" =>
        admin_call_handler(db, fn call ->
          p = call.params

          case Placement.set_toolchain_dirs(db, p.host, p.dirs, call.origin) do
            {:ok, row} when p.dirs == [] ->
              Map.put(
                row,
                :effect,
                "this host's adapter PATH now keeps the inherited value unchanged"
              )

            {:ok, row} ->
              preview = Placement.toolchain_path_preview(config, p.host)

              Map.put(
                row,
                :effect,
                "this host's adapter PATH is now fully constructed: #{preview}"
              )

            {:error, denial} ->
              denial
          end
        end),
      "register-host" =>
        admin_handler(db, fn p ->
          # The dumb half of assimilation (spec §Placement): the CLI ceremony
          # prepared the machine; this records the fact. The topology is the
          # operator's to declare.
          previous_entry = Placement.hosts(config.base_dir, db)[p.name]

          {:ok, entry} =
            Placement.register_host(db, p.name, %{
              ssh: p[:ssh] || p.name,
              base_dir: Map.fetch!(p, :base_dir),
              cli_bin: p[:cli_bin],
              adapter_bin_dir: p[:adapter_bin_dir]
            })

          :ok = start_credential_child(config, db, p.name, previous_entry, entry)

          # The operator who just assimilated this machine will run `onboard` ON
          # it, and that shell has no session token. Provisioning is the gateway's
          # because only the gateway knows its advertised url and the org token.
          case Placement.provision_endpoint(
                 config.base_dir,
                 p.name,
                 entry,
                 provision_opts(config)
               ) do
            :ok ->
              %{host: p.name, config: entry}

            {:error, reason} ->
              %{code: to_string(reason), message: endpoint_failure_message(reason, p.name)}
          end
        end),
      "update-clients" =>
        admin_handler(db, fn _params ->
          hosts =
            config.base_dir
            |> Placement.hosts(db)
            |> Enum.flat_map(fn
              {name, %{ssh: ssh} = host} when not is_nil(ssh) ->
                [%{name: name, ssh: ssh, cli_bin: host[:cli_bin]}]

              {_name, %{ssh: nil}} ->
                []
            end)
            |> Enum.sort_by(& &1.name)

          %{hosts: hosts}
        end),
      "identity-edit" =>
        admin_call_handler(db, fn call -> identity_edit_result(config, call) end),
      "identity-status" =>
        admin_call_handler(db, fn call -> identity_status_result(config, db, call) end),
      "identity-relearn" =>
        admin_call_handler(db, fn call -> identity_relearn_result(config, call) end),
      "identity-repoint" =>
        admin_call_handler(db, fn call -> identity_repoint_result(config, db, call) end),
      "learn" => admin_call_handler(db, fn call -> identity_learn_result(config, call) end),
      "unlearn" =>
        admin_call_handler(db, fn call -> identity_unlearn_result(config, db, call) end),
      "kungfu-list" => fn _call -> %{bundles: Identity.available_bundles()} end,
      "identity-apply" =>
        admin_call_handler(db, fn call -> identity_apply_result(config, db, call) end),
      "kungfu-scaffold" =>
        admin_call_handler(db, fn call ->
          paths =
            Archetypes.scaffold_kungfu!(
              config.base_dir,
              call.params.name,
              call.params.purpose,
              call.origin
            )

          %{kungfu: call.params.name, paths: paths}
        end),
      "onboard" => admin_call_handler(db, fn call -> onboard_result(config, call) end),
      "promote-user" =>
        admin_handler(db, fn p ->
          %{user: Devices.set_user_admin(db, p.user_id, Map.get(p, :is_admin, true))}
        end),
      "add-user" =>
        admin_handler(db, fn p ->
          %{user: Devices.add_user(db, p.user_id, Map.get(p, :is_admin, false))}
        end),
      "config" => admin_handler(db, fn p -> config_result(db, p) end),
      "harness-processes" =>
        admin_handler(db, fn _params ->
          coordinator = Map.get(config, :adapter_coordinator, Tightbeam.AdapterCoordinator)
          %{harness_processes: AdapterCoordinator.harness_processes(coordinator)}
        end),
      # Durable process custody, owner-reachable (spec art_6817803a rev6 §B4).
      # Every one of these must ALSO appear in the router's @agent_verbs
      # allowlist: 3fd9c97 landed because three verbs had a working
      # implementation, a CLI that sent them, and unit tests — but no allowlist
      # entry and no handler row, so the seam shipped dead and nothing noticed.
      # The router-seam test in router_test.exs drives these through
      # /agent/dispatch against this real table so both halves must exist.
      "processes" => fn call -> processes_result(db, call) end,
      "process-get" => custody_handler(db, &process_get_result/2),
      "process-extend" => custody_handler(db, &process_extend_result/2),
      "process-stop" => custody_handler(db, &process_stop_result/2),
      "process-reconcile" => custody_handler(db, &process_reconcile_result/2),
      "role-create" => fn call -> role_create_result(db, call) end,
      "role-bind" => fn call -> role_bind_result(db, call) end,
      "role-rm" => fn call -> role_rm_result(db, call) end,
      "role-list" => fn _call -> role_list_result(db) end,
      "work-item-create" => fn call ->
        WorkItems.__handle__(
          db,
          "work-item-create",
          Map.put(call, :on_work_item_change, item_change)
        )
      end,
      "work-item-get" => fn call -> WorkItems.__handle__(db, "work-item-get", call) end,
      "work-item-trace" => fn call -> WorkItems.__handle__(db, "work-item-trace", call) end,
      "transcript" => fn call -> Tightbeam.Transcript.read(db, call) end,
      "attend" => fn call -> attend_result(db, call) end,
      "toplines" => fn call -> Tightbeam.Toplines.roster(db, call) end,
      "topline" => fn call -> Tightbeam.Toplines.topline(db, call) end,
      "work-item-list" => fn call -> WorkItems.__handle__(db, "work-item-list", call) end,
      "work-item-update" => fn call ->
        WorkItems.__handle__(
          db,
          "work-item-update",
          Map.put(call, :on_work_item_change, item_change)
        )
      end,
      "work-item-icebox" => work_item_disposition(db, "work-item-icebox", item_change),
      "work-item-reopen" => work_item_disposition(db, "work-item-reopen", item_change),
      "work-item-close" => work_item_disposition(db, "work-item-close", item_change),
      "work-item-fail" => work_item_disposition(db, "work-item-fail", item_change),
      "assign" => fn call ->
        call =
          call
          |> Map.put(:supervision_interval_ms, Map.fetch!(config, :wake_tick_ms))
          |> Map.put(:on_assignment_change, assignment_change)
          |> Map.put(:on_work_item_change, item_change)

        Assignments.__handle__(db, "assign", call)
      end,
      "dispatch" => fn call ->
        call =
          call
          |> Map.put(:supervision_interval_ms, Map.fetch!(config, :wake_tick_ms))
          |> Map.put(:on_assignment_change, assignment_change)
          |> Map.put(:on_work_item_change, item_change)
          |> Map.put(:effort_config, config)
          |> Map.put(:on_dispatch_delivery, fn delivery, _ -> complete_delivery(db, delivery) end)

        Assignments.__handle__(db, "dispatch", call)
      end,
      "attest" => fn call ->
        Assignments.__handle__(
          db,
          "attest",
          call
          |> maybe_put_progress_interval(config)
          |> Map.put(:on_assignment_change, assignment_change)
          # Referent verification reaches hosts, so it needs the same placement
          # config (and the same injectable runner) the effort probe uses.
          |> Map.put(:effort_config, config)
        )
      end,
      "attests" => fn call -> Assignments.__handle__(db, "attests", call) end,
      "assignment-get" => fn call -> Assignments.__handle__(db, "assignment-get", call) end,
      "revoke-assignment" => fn call ->
        Assignments.__handle__(
          db,
          "revoke-assignment",
          Map.put(call, :on_assignment_change, assignment_change)
        )
      end,
      "assignments" => fn call -> Assignments.__handle__(db, "assignments", call) end,
      "inspect" => fn call -> inspect_result(config, db, call) end,
      "cancel" => fn call -> cancel_result(db, call) end,
      "critical" => fn call -> critical_result(config, db, call) end,
      "spawn" => fn call -> spawn_result(config, db, call) end,
      "tune" => fn call -> tune_result(config, db, call) end,
      "retire" => fn call -> retire_result(config, db, call) end
    }
  end

  # A terminal-disposition handler routes the owner doorbell through the same
  # work_item_events seam as create/update.
  defp work_item_disposition(db, verb, item_change) do
    fn call ->
      WorkItems.__handle__(db, verb, Map.put(call, :on_work_item_change, item_change))
    end
  end

  @doc """
  Shared turn-bearing delivery (gateway.ts `deliverPrompt`): ONE transaction
  appends the echo (Projection) + enqueues the turn (Ledger.enqueue_in_txn),
  then broadcasts the echo and nudges the lane. Returns the dedupe outcome.
  """
  @spec deliver_prompt(String.t(), String.t(), String.t(), keyword()) ::
          :appended | :duplicate | :conflict | :skipped
  def deliver_prompt(session_key, origin, prompt, opts \\ []) do
    db = Keyword.get(opts, :db, Tightbeam.DB)

    result =
      DB.transaction(db, fn txn ->
        deliver_prompt_in_txn(txn, session_key, origin, prompt, opts)
      end)

    case result do
      {:ok, delivery} ->
        complete_delivery(db, delivery)

      {:error, %{message: message}} when is_binary(message) ->
        if String.contains?(message, "UNIQUE"),
          do: :duplicate,
          else: raise(DB.Error, message: message)

      {:error, error} ->
        raise error
    end
  end

  @doc "Delivery's DB-only core for callers already inside the DB owner transaction."
  @spec deliver_prompt_in_txn(DB.Txn.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:appended, String.t(), map(), keyword()}
          | {:duplicate, map()}
          | {:conflict, map()}
          | :skipped
  def deliver_prompt_in_txn(%DB.Txn{} = txn, session_key, origin, prompt, opts \\ []) do
    stamped =
      case opts[:sender] do
        sender when is_binary(sender) -> "[from #{sender}]\n\n" <> prompt
        _ -> prompt
      end

    case delivery_target(txn, session_key, opts[:target_gate]) do
      nil ->
        cancel_unavailable_supervision_controller_in_txn(txn, opts, session_key)
        :skipped

      {target, role_ref, role_fallback} when not is_nil(target) ->
        if Ledger.enqueueable_in_txn?(txn, target) do
          case admit_supervision_controller_in_txn(txn, opts, target) do
            :canceled ->
              :skipped

            controller ->
              append_and_enqueue_in_txn(
                txn,
                target,
                role_ref,
                role_fallback,
                origin,
                stamped,
                Keyword.put(opts, :supervision_controller, controller)
              )
          end
        else
          case cancel_unavailable_supervision_controller_in_txn(txn, opts, target) do
            :canceled ->
              :skipped

            :ordinary ->
              # Asked BEFORE the echo, because the echo commits in this same
              # transaction and a raise is not available to take it back (it would
              # roll the caller's wake `fired` mark back with it). The ledger still
              # refuses independently — it is the single writer — but a message with
              # no turn is history nobody can answer, so nothing is written at all.
              refuse_undeliverable_turn(txn, target, origin, opts)
          end
        end
    end
  end

  defp append_and_enqueue_in_txn(txn, target, role_ref, role_fallback, origin, stamped, opts) do
    input = %{
      session_key: target,
      role: "user",
      content: stamped,
      device_id: opts[:device_id],
      client_message_id: opts[:client_message_id],
      attachments: opts[:attachments] || [],
      sender: opts[:sender]
    }

    case Projection.append_in_txn(txn, input) do
      {:appended, message} ->
        {assignment_id, job_ref} = turn_attribution(txn, opts)

        enqueued =
          Ledger.enqueue_in_txn(txn, %{
            session_key: target,
            message_id: message.id,
            wake_id: opts[:wake_id],
            origin: origin,
            prompt: stamped,
            role_ref: role_ref || opts[:role_ref],
            role_fallback: role_fallback || opts[:role_fallback] || false,
            assignment_id: assignment_id,
            job_ref: job_ref,
            request_ref: opts[:request_ref]
          })

        case enqueued do
          {:ok, seq} ->
            settle_supervision_controller_in_txn(txn, opts, target, seq)
            fire_wake_in_txn(txn, opts)

            # Nag-by-re-arm: a bracket wake that just fired re-arms its
            # replacement IN this transaction if the item is still holderless
            # and non-terminal (the lattice does not watch holderless work).
            # No-ops for every non-bracket wake (the discriminator is the item's
            # routing/slate wake-id matching this wake).
            WorkItems.rearm_on_fire_in_txn(txn, opts[:wake_id], opts[:target_gate])

            {:appended, target, message, opts}

          # The ledger is the single writer and refuses on its own authority, so
          # this stays reachable for any future caller even though the check
          # above already declined this one in the same transaction.
          {:error, :no_session} ->
            refuse_undeliverable_turn(txn, target, origin, opts)
        end

      other ->
        other
    end
  end

  # The wake is still CONSUMED — leaving it pending would redeliver the same
  # undeliverable notice every tick — and the loss is named rather than left as
  # a queued row nobody can claim.
  defp refuse_undeliverable_turn(txn, target, origin, opts) do
    fire_wake_in_txn(txn, opts)

    Logger.error(
      "refusing a turn addressed to #{target}: no session row exists for that key " <>
        "(origin=#{origin} wake=#{opts[:wake_id] || "none"} sender=#{opts[:sender] || "none"})"
    )

    :skipped
  end

  defp fire_wake_in_txn(txn, opts) do
    if opts[:fire_wake_in_txn] == true and is_binary(opts[:wake_id]) do
      DB.Txn.q(
        txn,
        "UPDATE wakes SET state = 'fired', firedAt = ?2 WHERE wakeId = ?1 AND state = 'pending'",
        [opts[:wake_id], System.system_time(:millisecond)]
      )
    end
  end

  defp admit_supervision_controller_in_txn(txn, opts, target) do
    case opts[:wake_id] do
      wake_id when is_binary(wake_id) ->
        case DB.Txn.q(
               txn,
               "SELECT assignmentId FROM supervision_liveness_sidecar WHERE wakeId=?1 AND controllerOrigin='scheduled' AND controllerState='pending'",
               [wake_id]
             ) do
          [[assignment_id]] ->
            case Supervision.transition_in_txn(txn, %{
                   kind: "controller_fire",
                   wake_id: wake_id,
                   assignment_id: assignment_id,
                   target_session_key: target
                 }) do
              {:admit, wake_kind} -> {assignment_id, wake_kind}
              :canceled -> :canceled
            end

          [] ->
            :ordinary
        end

      _ ->
        :ordinary
    end
  end

  defp settle_supervision_controller_in_txn(txn, opts, target, turn_seq) do
    case opts[:supervision_controller] do
      {assignment_id, wake_kind} ->
        case Supervision.transition_in_txn(txn, %{
               kind: "controller_fire",
               wake_id: opts[:wake_id],
               assignment_id: assignment_id,
               target_session_key: target,
               turn_seq: turn_seq
             }) do
          {:admit, ^wake_kind} ->
            :ok

          other ->
            raise "incompatible_supervision_liveness_v1: controller settlement #{inspect(other)}"
        end

      _ ->
        :ok
    end
  end

  defp cancel_unavailable_supervision_controller_in_txn(txn, opts, target) do
    case opts[:wake_id] do
      wake_id when is_binary(wake_id) ->
        case DB.Txn.q(
               txn,
               "SELECT assignmentId,wakeKind FROM supervision_liveness_sidecar WHERE wakeId=?1 AND controllerOrigin='scheduled' AND controllerState='pending'",
               [wake_id]
             ) do
          [[assignment_id, wake_kind]] ->
            {:ok, liveness_trigger} =
              Supervision.liveness_trigger_in_txn(txn, {:assignment, assignment_id})

            true =
              Wakes.cancel_in_txn(txn, %{
                wake_id: wake_id,
                requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
                reason_kind: "target_unresolvable",
                causal_source: %{kind: "scheduler_delivery", id: wake_id},
                outcome: %{kind: "no_replacement", liveness_trigger: liveness_trigger}
              })

            EventLog.lifecycle_in_txn(
              txn,
              "supervision_controller_unavailable",
              assignment_id,
              "wakeId=#{wake_id} kind=#{wake_kind} target=#{target}"
            )

            :canceled

          [] ->
            :ordinary
        end

      _ ->
        :ordinary
    end
  end

  defp turn_attribution(txn, opts) do
    case {opts[:assignment_id], opts[:job_ref]} do
      {assignment_id, job_ref} when is_binary(assignment_id) ->
        {assignment_id, job_ref}

      {nil, nil} ->
        case opts[:wake_id] do
          wake_id when is_binary(wake_id) -> wake_attribution(txn, wake_id)
          nil -> {nil, nil}
        end

      attribution ->
        attribution
    end
  end

  # A wake-delivered turn inherits its wake's carriers — the same rule every
  # other carrier follows. This is what CLOSES v1's prod-turn exclusion ("no
  # durable carrier"): supervision now stamps wakes.assignmentId, so the prod
  # turn is attributable, and jobRef follows from the assignment. A bracket wake
  # has no assignment and keeps resolving its jobRef from the work item.
  defp wake_attribution(txn, wake_id) do
    assignment_id =
      case DB.Txn.q(txn, "SELECT assignmentId FROM wakes WHERE wakeId = ?1", [wake_id]) do
        [[assignment_id]] -> assignment_id
        [] -> nil
      end

    cond do
      is_binary(assignment_id) ->
        case DB.Txn.q(txn, "SELECT workItemId FROM assignments WHERE id = ?1", [assignment_id]) do
          [[job_ref]] -> {assignment_id, job_ref}
          [] -> {assignment_id, nil}
        end

      true ->
        case DB.Txn.q(txn, "SELECT id FROM work_items WHERE routingWakeId = ?1", [wake_id]) do
          [[job_ref]] -> {nil, job_ref}
          [] -> {nil, nil}
        end
    end
  end

  @doc "Publish and lane-nudge a delivery after its transaction commits."
  @spec complete_delivery(DB.server(), term()) :: :appended | :duplicate | :conflict | :skipped
  def complete_delivery(db, {:appended, actual_session_key, message, opts}) do
    registry = Keyword.get(opts, :conn_registry, Tightbeam.ConnRegistry)
    publish_message(db, actual_session_key, message, registry)

    publish_turn_state(
      db,
      actual_session_key,
      message.client_message_id || message.id,
      "accepted",
      nil,
      registry
    )

    LaneManager.ensure_lane(
      Keyword.get(opts, :lane_manager, Tightbeam.LaneManager),
      actual_session_key
    )

    :appended
  end

  def complete_delivery(_db, :skipped), do: :skipped
  def complete_delivery(_db, {:duplicate, _message}), do: :duplicate
  def complete_delivery(_db, {:conflict, _message}), do: :conflict

  @doc false
  def delivery_target(_txn, session_key, nil), do: {session_key, nil, false}

  def delivery_target(txn, _session_key, %{target_role: role}) when is_binary(role) do
    case DB.Txn.q(txn, "SELECT boundSessionKey, ownerUserId FROM roles WHERE name = ?1", [role]) do
      [[bound, owner]] ->
        case active_session?(txn, bound) do
          true -> {bound, role, false}
          false -> active_personal_target(txn, owner, role)
        end

      [] ->
        nil
    end
  end

  def delivery_target(txn, session_key, gate) do
    case DB.Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey = ?1", [session_key]) do
      [["active"]] ->
        {session_key, nil, false}

      _ when gate.reresolve == "lineage" ->
        # Re-resolution answers "who owns this now", and NOBODY is one of the
        # answers. Until the ladder could say so, a notice whose recorded target
        # had gone was re-addressed to a composed personal key that named no
        # session, and the substrate queued it there forever.
        case Supervision.ladder_target(txn, gate.reresolve_seed, gate.reresolve_rung) do
          nil ->
            Logger.error(
              "substrate notice for #{session_key} is undeliverable: re-resolving the lineage " <>
                "from #{gate.reresolve_seed} rung #{gate.reresolve_rung} found no active " <>
                "session to own it"
            )

            nil

          target ->
            {target, nil, false}
        end

      _ ->
        nil
    end
  end

  defp active_session?(_txn, nil), do: false

  defp active_session?(txn, session_key) do
    DB.Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey = ?1", [session_key]) == [
      ["active"]
    ]
  end

  defp active_personal_target(txn, owner, role) do
    target = Org.personal_session_key(owner)
    if active_session?(txn, target), do: {target, role, true}, else: nil
  end

  @doc """
  Org options for client creation/tuning pickers (device-authed via
  GET /api/org-options): harnesses, the model catalog per host per harness,
  assimilated hosts, archetypes with their WHERE. Same data inspect gives
  agents — discovery beats documentation, for humans too.

  `models` is keyed by HOST first because entitlements are host-local: the
  picker must offer what the host the session will land on can actually run,
  not what the gateway's own account happens to hold.
  """
  @spec org_options() :: map()
  def org_options do
    base_dir =
      Application.get_env(:tightbeam, :base_dir, Path.join(System.user_home!(), ".tightbeam"))

    %{
      harnesses: Enum.map(Harness.all(), & &1.wire_name()),
      models: picker_models(base_dir, Tightbeam.DB),
      hosts: base_dir |> Placement.hosts() |> Map.keys() |> Enum.sort(),
      archetypes:
        Enum.map(Archetypes.names(), fn name ->
          a = Archetypes.get(name)
          %{name: a.name, where: a.where, defaults: wire_defaults(a.defaults)}
        end)
    }
  end

  # %{host => %{harness => [model]}} — the shape both pickers (org-options) and
  # inspect publish. Hosts come from the registry, so a host whose catalog is
  # still degraded appears with an empty list rather than vanishing.
  defp picker_models(base_dir, db) do
    catalog = ModelCatalog.get()

    base_dir
    |> Placement.hosts(db)
    |> Map.keys()
    |> Map.new(fn host ->
      {host,
       Map.new(Harness.all(), fn module ->
         wire = module.wire_name()

         {wire,
          catalog
          |> Map.get({host, wire}, [])
          |> Enum.map(fn entry ->
            # PROJECTED, not spread: the catalog entry's internal shape (its
            # `family` key) stays inside. What crosses is the identity's named
            # fields plus the catalog facts a caller picks a model on.
            Map.merge(wire_model(entry), %{
              name: entry.display_name,
              display_name: entry.display_name,
              provider: entry.provider,
              max_input_tokens: entry.max_input_tokens,
              capabilities: entry.capabilities
            })
          end)}
       end)}
    end)
  end

  @doc """
  SessionStatusPayload projection for the status route (gateway.ts
  `sessionStatus`): registry provenance + ledger run state (queue depth from
  pending turns) + per-harness capability advertisement from the model
  catalog. Nil for unknown sessions.
  """
  @spec session_status(String.t(), DB.server()) ::
          map() | nil | {:error, 503, String.t(), String.t()}
  def session_status(session_key, db \\ Tightbeam.DB), do: session_status(session_key, db, nil)

  defp session_status(session_key, db, config) do
    case Org.get(db, session_key) do
      nil ->
        nil

      session ->
        _ = ensure_status_residency(config, db, session)

        {:ok, [[depth]]} =
          DB.query(
            db,
            "SELECT COUNT(*) FROM turns WHERE sessionKey = ?1 AND status IN ('queued','running')",
            [session_key]
          )

        archetype = Archetypes.get(session.archetype) || Archetypes.builtin_default()

        model_preferences =
          case archetype.model_preferences do
            [] -> nil
            preferences -> Enum.map(preferences, &wire_preference/1)
          end

        {catalog, _health} = ModelCatalog.get(session.host, session.harness, ModelCatalog)
        unsupported = fn reason -> %{supported: false, reason: reason} end
        runtime_projection = live_runtime_projection(db, session)
        runtime_model = runtime_projection.model

        current_efforts =
          case runtime_model &&
                 Enum.find(catalog, &ModelCatalog.names_same_model?(&1, runtime_model)) do
            nil -> []
            entry -> entry.efforts
          end

        reasoning_capability =
          case current_efforts do
            [] ->
              reason =
                if is_nil(runtime_model),
                  do: "current model is unknown",
                  else: "current model has no effort tiers"

              unsupported.(reason)

            efforts ->
              %{
                supported: true,
                options: Enum.map(efforts, &%{title: &1, value: &1, enabled: true})
              }
          end

        credential_kind = credential_kind(session)
        fast_projection = live_fast_projection(db, session)

        fast_capability =
          case fast_projection.fast_status do
            "known" -> %{supported: true}
            "unsupported" -> unsupported.("resident adapter does not advertise Fast")
            "unknown" -> unsupported.("live runtime configuration is unavailable")
          end

        payload = %{
          # sessionKey is REQUIRED by the client's SessionStatus decoder — its
          # absence fails the whole decode and the model footer never
          # populates (found live; the TS reference omitted it too).
          sessionKey: session_key,
          display: %{
            # `model` is the row IDENTITY this seam issues (see `wire_model/1`):
            # the footer displays it verbatim when it cannot match a catalog row,
            # and matches it against the catalog rows for the current-model
            # checkmark. The identity's FIELDS travel beside it, named, and are
            # what a caller reads or sends back.
            model: (runtime_model && wire_identity(runtime_model)) || "unknown",
            modelFamily: runtime_model && runtime_model.family,
            modelContext: runtime_model && runtime_model.context,
            modelPreferences: model_preferences,
            provider: session.provider,
            harness: session.harness,
            host: session.host,
            credentialKind: credential_kind,
            authMode: nil,
            reasoningLevel: runtime_model && runtime_model.effort,
            thinkingLevel: nil,
            fastMode: fast_projection.fast,
            mode: nil,
            verbosity: nil
          },
          run: %{
            state: if(depth > 0, do: "running", else: "idle"),
            runId: nil,
            messageId: nil,
            startedAt: nil,
            queueDepth: depth
          },
          context: nil,
          approval: nil,
          capabilities: %{
            cancelCurrentRun: %{supported: true},
            setModel: %{
              supported: true,
              options:
                Enum.map(
                  catalog,
                  &Map.merge(
                    %{title: &1.name, value: wire_identity(&1), enabled: true},
                    wire_model(&1)
                  )
                )
            },
            setThinking: unsupported.("thinking control lands in a later milestone"),
            setReasoning: reasoning_capability,
            setFastMode: fast_capability,
            setMode: unsupported.("sessions run YOLO"),
            setHarness: %{
              supported: true,
              options:
                Enum.map(Harness.all(), fn module ->
                  harness = module.wire_name()
                  %{title: harness, value: harness, enabled: true}
                end)
            },
            setVerbosity: unsupported.("not supported"),
            canCancelCurrentRun: true,
            canChangeModel: true,
            canChangeReasoning: current_efforts != [],
            canChangeFastMode: fast_projection.fast_status == "known",
            canChangeVerbosity: false,
            readOnlyStatus: false
          },
          modelCatalog: %{
            available: true,
            # Client Model decoder REQUIRES id + provider + ref (id is the
            # stable identity; ref doubles as it here). One row per vendor
            # model — including each context variant, which is part of the
            # identity — with the effort tier owned by the reasoning picker.
            # `model`/`context`/`efforts` are the row's named fields.
            models:
              Enum.map(
                catalog,
                &Map.merge(%{name: &1.name, provider: session.provider}, wire_model(&1))
              )
          },
          runtimeStatus: runtime_projection.status,
          fastStatus: fast_projection.fast_status,
          fast: fast_projection.fast,
          fastPersistence: "ephemeral",
          configuredProjection: published_identity(session.model)
        }

        case credential_kind do
          {:error, reason} ->
            {:error, 503, "credential_store_unreadable", describe_error(reason)}

          _kind ->
            payload
        end
    end
  end

  defp live_runtime_projection(db, session) do
    with %{harness_session_id: sid} <- Org.current_pointer(db, session.session_key),
         {:ok, adapter, _generation} <- resident_adapter(session),
         true <- Adapter.knows_session?(adapter, sid),
         {:ok, %Model{} = model} <- Adapter.current_model(adapter, sid) do
      %{status: "known", model: model}
    else
      _ -> %{status: "unknown", model: nil}
    end
  end

  # Status is a live-runtime claim, so a cold adapter must enter through the
  # same create/load seam as the next turn before status can call anything
  # "known". A busy lane stays unknown: status never jumps ahead of a filed
  # turn, and the turn itself will perform the same residency work.
  defp ensure_status_residency(nil, _db, _session), do: :not_requested

  defp ensure_status_residency(config, db, session) do
    pointer = Org.current_pointer(db, session.session_key)

    with {:needs_residency, true} <-
           {:needs_residency, not resident_pointer?(session, pointer)},
         {:ok, result} <-
           at_session_turn_boundary(config, session.session_key, fn ->
             run_session_mutation(session.session_key, fn ->
               with {:ok, adapter, generation} <- checkout_adapter(session),
                    {:ok, sid} <- harness_session(config, db, adapter, generation, session, nil),
                    {:ok, %Model{}} <- Adapter.current_model(adapter, sid) do
                 :ok
               end
             end)
           end) do
      result
    else
      {:needs_residency, false} -> :already_resident
      _ -> :unknown
    end
  end

  defp resident_pointer?(_session, nil), do: false

  defp resident_pointer?(session, pointer) do
    with {:ok, adapter, _generation} <- resident_adapter(session) do
      Adapter.knows_session?(adapter, pointer.harness_session_id)
    else
      _ -> false
    end
  end

  # A catalog entry's wire/vendor identity. The entry holds the fields; this is
  # the one line of text a client needs to name the row back to us.
  @doc false
  # THE WIRE SEAM's projection of a model identity, both halves in one place.
  #
  # `model`/`context`/`efforts` are the named fields the ruling requires: they
  # are the payload's meaning, and `resolve_selection/3` reads them back.
  #
  # `id`/`ref` is one line of text because the client's decoder has ONE slot for
  # a model's stable identity and must tell two context variants of one family
  # apart. It is this seam's line format and nothing downstream parses it — a
  # value coming back is RESOLVED against the catalog that issued it, never
  # split with a regex. It is spelled the way the vendor spells the model
  # because that is what a human should see in a picker.
  # ASSUMED, and it is the vendor's to keep: a family name contains no literal
  # bracket. The `model` slot's two readings — a family, or a family carrying a
  # context variant — both depend on it. A vendor that broke it would have
  # broken its own identifiers first.
  def wire_model(entry) do
    identity = wire_identity(entry)

    %{
      id: identity,
      # DELETE `ref` once the client decoder stops requiring both: it is a
      # duplicate of `id` and exists for no other reason.
      ref: identity,
      model: entry.family,
      context: entry.context,
      efforts: entry.efforts
    }
  end

  # The inbound half of `wire_model/1`, and the one place a caller's named
  # fields become an identity.
  #
  # Two steps. RESOLVE: a client sends back the row identity this seam issued,
  # so it is looked up in the catalog that issued it — a lookup cannot invent a
  # context the host does not offer, and cannot mistake one of our effort
  # levels for the vendor's variant. An explicit `context` skips it.
  #
  # THE PROPERTY, because it is what to go looking for elsewhere: this function
  # CANNOT DISTINGUISH A MISS FROM A HIT. Both return fields, and no caller can
  # tell which happened. The disambiguation is downstream, and only there.
  #
  # RESOLUTION IS DELIBERATELY LENIENT: an id it cannot find passes through as
  # if it were a family, and NOTHING here refuses it. That is safe only because
  # resolve-then-validate is ONE PIPELINE — every caller hands the result to
  # `validate_catalog_model/4`, which is where an unknown selection is refused
  # by name against the host's live catalog. The gate lives there, once, at the
  # boundary that knows the host. A future caller that resolves without
  # validating reintroduces silent acceptance of an unknown model.
  #
  # COMPLETE: fields the caller omitted inherit the default, which is what the
  # CLI promises. `--effort high` alone is the default model at high effort,
  # not a flag accepted and dropped. Context and effort belong to a MODEL, so
  # neither carries across a change of model — when the family changes they are
  # left open for `compose_model_selection/4`, the one place that decides which
  # tier a newly chosen model runs at.
  defp resolve_selection(host, harness, params, base) do
    params |> Model.named_fields() |> resolve_issued(host, harness) |> complete(base)
  end

  defp resolve_issued(%{family: family} = fields, host, harness)
       when is_binary(family) and not is_map_key(fields, :context) do
    {catalog, _health} = ModelCatalog.get(host, harness, ModelCatalog)

    case Enum.find(catalog, &(wire_identity(&1) == family)) do
      nil ->
        fields

      entry ->
        # A resolved row states its context EXPLICITLY, `nil` included — the
        # row for the default window is a real selection, not a silence. The
        # key is put unconditionally so completion can tell the two apart.
        fields |> Map.put(:family, entry.family) |> Map.put(:context, entry.context)
    end
  end

  defp resolve_issued(fields, _host, _harness), do: fields

  # Inheritance fills only what the caller left ABSENT. A key that is present
  # — even holding nil — is the caller's answer and is taken as given.
  defp complete(fields, base) when map_size(fields) == 0, do: base

  defp complete(fields, base) when not is_map_key(fields, :family) do
    case base do
      %Model{} = base ->
        %{
          base
          | effort: named_or(fields, :effort, base.effort),
            context: named_or(fields, :context, base.context)
        }

      _ ->
        nil
    end
  end

  defp complete(%{family: family} = fields, base) do
    inherits? = match?(%Model{}, base) and base.family == family

    %Model{
      family: family,
      effort: named_or(fields, :effort, inherits? && base.effort),
      context: named_or(fields, :context, inherits? && base.context)
    }
  end

  defp named_or(fields, key, fallback) do
    case Map.fetch(fields, key) do
      {:ok, named} -> named
      :error -> fallback || nil
    end
  end

  # The one home for a published selection IN THIS MODULE — `model` the family,
  # `context` the vendor's window variant, `effort` ours. Five call sites:
  # `inspect_session/1`, the tune and adjudication responses,
  # `wire_preference/1`, `wire_defaults/1`.
  #
  # SCOPED DELIBERATELY, because a wider claim here has now been false three
  # times. Two other kinds of projection publish the same trio and do NOT come
  # through here:
  #
  #   - the catalog ROW (`wire_model/1`) names a model rather than a choice: it
  #     carries `efforts`, what MAY be asked, where a selection carries the one
  #     `effort` that WAS.
  #   - turn provenance (`Toplines.minds/1`, `Transcript`, `JobTrace`) reads
  #     three COLUMNS and never holds a `%Model{}` at all.
  #
  # Both would have to build a struct only to flatten it again. Narrowing the
  # claim costs nothing; leaving it wide invites the next reader to trust it
  # further than it goes.
  #
  # A packed value alone would make a consumer split the string to recover the
  # context, which is the parsing this refactor exists to end — the rendering
  # belongs only where one line of text is structurally required, and that is
  # the row's `id`.
  defp published_identity(nil), do: %{model: nil, context: nil, effort: nil}

  defp published_identity(%Model{} = model),
    do: %{model: model.family, context: model.context, effort: model.effort}

  # LOAD-BEARING: family and context ONLY. The whole dual representation rests
  # on effort never reaching this slot — a bracket here can then mean exactly
  # one thing, and the 1M collision needed two meanings competing for it.
  # Rendering effort into this would silently restore that collision.
  #
  # The guard is the round-trip test in gateway_test.exs, "an issued row
  # identity echoed back resolves to that row's fields", which asserts the
  # effort came from the session and never from the id. It looks redundant
  # beside the catalog tests; it is not. Do not delete it.
  defp wire_identity(%{family: family, context: context}),
    do: Model.to_ref(Model.new(family, context: context))

  # Archetype defaults cross the wire as named fields. A stored default is a
  # `%Model{}`, and publishing it raw would put `__struct__` and `family` — an
  # INTERNAL shape — into a client payload (and fail JSON encoding outright).
  defp wire_defaults(%{model: %Model{} = model} = defaults),
    do: Map.merge(defaults, published_identity(model))

  defp wire_defaults(defaults), do: defaults

  # A stored preference crosses as named fields, like every other identity on
  # this seam. It carries no `id`: a preference names a model the org prefers,
  # not a row in some host's catalog.
  defp wire_preference(%Model{} = model), do: published_identity(model)

  # An agent reading `inspect` sees the identity as FIELDS, the same way it
  # supplies them back on spawn.
  defp inspect_session(session) do
    session
    |> Map.take([
      :session_key,
      :display_name,
      :handle,
      :archetype,
      :host,
      :harness,
      :origin,
      :spawned_by,
      :state,
      :created_at
    ])
    |> Map.merge(published_identity(session.model))
  end

  # A catalog entry for a reader who has to pick one — an operator reading a
  # refusal, an adjudicator reading a brief. Fields are named, because what the
  # reader must produce next is flags, not a packed string.

  # Which KIND of credential this session's turns actually run on — an API key or
  # a subscription. A fact about {the session's host, its harness's provider},
  # read HERE rather than stored on the session row: a stored value would go
  # stale the moment the host is re-onboarded on the other kind, and a client
  # seeing that flip is the point.
  #
  # Absence is its own value, not a missing field: "none" says there is no
  # credential on that host for that provider, which is a different sentence from
  # "there is one and it stopped working" — and a client watching the field
  # simply vanish could not tell either from a decoder change.
  defp credential_kind(session) do
    provider = Harness.parse!(session.harness).credential_provider()
    server = Tightbeam.Credentials.server(session.host)

    case GenServer.whereis(server) do
      nil ->
        wire_credential_kind(:none)

      _pid ->
        case Tightbeam.Credentials.kind(provider, server) do
          {:error, reason} -> {:error, reason}
          kind -> wire_credential_kind(kind)
        end
    end
  end

  # DO NOT "simplify" this into an atom passthrough. `Router.wire_value/1` lower-
  # camelizes KEYS only; an atom VALUE encodes verbatim, so `:api_key` would
  # reach the client as "api_key" and its decoder would fall through to whatever
  # it does with an unknown kind. The camelizer is not doing this work and cannot
  # be made to. The wire vocabulary is stated once, here.
  defp wire_credential_kind(:api_key), do: "apiKey"
  defp wire_credential_kind(:subscription), do: "subscription"
  defp wire_credential_kind(:none), do: "none"

  defp defaults(config, db) do
    module = Harness.module!(config.default_harness)
    harness = module.id()
    model = config.default_model

    %{
      # Invariant: only omitted archetypes consult the org default; an explicit
      # spawn archetype is never replaced by organization policy.
      archetype: Org.get_setting(db, "default-archetype") || "default",
      harness: harness,
      provider: fn -> default_seed_provider(module, model) end,
      model: model
    }
  end

  defp install_cli_bin(base_dir) do
    bin_dir = Path.join(base_dir, "bin")
    File.mkdir_p!(bin_dir)
    wrapper = Path.join(bin_dir, "tightbeam")

    # TWO LAYOUTS SHIP A CLI, and this used to know only one of them. A release
    # install carries the compiled CLI as the npm package's own bin — a sibling
    # of the release root the running gateway can locate exactly — while a
    # source checkout builds it under cli/target. Knowing only the source path
    # meant every release install seeded a wrapper pointing at a directory that
    # does not exist there, telling a toolchain-free customer to run cargo:
    # found by BOTH first-install agents, macOS and linux, within minutes of
    # each other (2026-08-04). Not a fallback between implementations — both
    # candidates are the same binary, differing only in who compiled it.
    candidates =
      case System.get_env("RELEASE_ROOT") do
        nil -> []
        release_root -> [Path.expand("../bin/tightbeam", release_root)]
      end ++ [Path.expand("cli/target/release/tightbeam", File.cwd!())]

    case Enum.find(candidates, &File.exists?/1) do
      rust_cli when is_binary(rust_cli) ->
        # Removed first, not copied over. On macOS, writing into an existing Mach-O
        # invalidates its code signature and the kernel SIGKILLs it on exec -- exit 137,
        # no output, indistinguishable from a corrupt build. Observed while replacing
        # this very wrapper by hand.
        File.rm(wrapper)
        File.cp!(rust_cli, wrapper)

      nil ->
        # There is NO fallback to another implementation (a retired one used to
        # live here and only ever fired where nobody was watching). The refusal
        # names every place a CLI could have been.
        Logger.warning(
          "tightbeam CLI not found (looked for #{Enum.join(candidates, ", ")}), so " <>
            "#{wrapper} will refuse to run. On a source checkout, build it with: " <>
            "cargo build --release --manifest-path cli/Cargo.toml"
        )

        File.write!(wrapper, refusing_wrapper(candidates))
    end

    File.chmod!(wrapper, 0o755)
    Enum.each(Harness.all(), fn module -> :ok = module.install_cli_projection(bin_dir) end)

    bin_dir
  end

  # `bin/tightbeam` still EXISTS when the CLI was not built, because its absence
  # is itself confusing — but it does exactly one thing: say what is missing and
  # how to build it.
  defp refusing_wrapper(candidates) do
    # Paths ride inside SINGLE quotes with the only metacharacter a single-quoted
    # sh string has — the quote itself — escaped. Double quotes left `$()`,
    # backticks and `"` live: a hostile-or-merely-odd base_dir path would EXECUTE
    # on invocation instead of reliably reporting and exiting 127.
    quoted = fn path -> "'" <> String.replace(path, "'", "'\\''") <> "'" end

    """
    #!/bin/sh
    echo "tightbeam CLI is not installed: none of these existed when the gateway booted:" >&2
    #{Enum.map_join(candidates, "\n", fn c -> "echo \"  \"#{quoted.(c)} >&2" end)}
    echo "On a source checkout, build it with: cargo build --release --manifest-path cli/Cargo.toml" >&2
    exit 127
    """
  end

  defp turn_runner(config) do
    db = Map.get(config, :db, Tightbeam.DB)

    fn turn ->
      session = Org.get(db, turn.session_key)
      echo = Projection.get(db, turn.message_id)
      correlation = (echo && echo.client_message_id) || turn.message_id
      publish_turn_state(db, turn.session_key, correlation, "running", nil)
      publish_session_indicator(db, turn.session_key, session.owner_user_id)

      broadcast(
        db,
        session.owner_user_id,
        Payloads.activity_event(%{
          is_active: true,
          message_id: correlation,
          session_key: turn.session_key
        })
      )

      terminal_publish = fn terminal ->
        state = if terminal == "delivered", do: "delivered", else: "failed"
        publish_turn_state(db, turn.session_key, correlation, state, nil)
        publish_session_indicator(db, turn.session_key, session.owner_user_id)

        broadcast(
          db,
          session.owner_user_id,
          Payloads.activity_event(%{
            is_active: false,
            message_id: correlation,
            session_key: turn.session_key
          })
        )
      end

      outcome =
        with {:ok, adapter, generation} <-
               stage(:checkout, checkout_adapter(session)),
             {:ok, harness_session_id} <-
               stage(
                 :session,
                 with_session_mutation_lock(turn.session_key, fn ->
                   # Tune holds this same lock across adapter apply and record
                   # commit. Re-read inside it so the push cannot use the
                   # pre-checkout snapshot or interleave with that sequence.
                   current = Org.get(db, turn.session_key)

                   harness_session(
                     config,
                     db,
                     adapter,
                     generation,
                     %{session | model: current.model},
                     turn.seq
                   )
                 end)
               ),
             {:ok, result} <-
               stage(
                 :prompt,
                 Adapter.prompt(
                   adapter,
                   harness_session_id,
                   turn.prompt,
                   progress:
                     progress_fun(db, turn.session_key, session.owner_user_id, correlation)
                 )
               ) do
          append_assistant_messages(db, turn, echo, result)

          {:ok, %{terminal_publish: terminal_publish}}
        else
          {:error, {failed_stage, reason}} ->
            # A FAILED TURN FAILS. It does not freeze the session behind a
            # ruling. Adjudication — episodes, holds, an escalation ladder, a
            # `tightbeam adjudicate` verb — was deleted 2026-08-05 (Flynn: "why
            # is the substrate making a model selection?"), because model choice
            # is judgment and judgment belongs to inference, not to a substrate
            # mechanism. The pattern spec said exactly that in its first
            # paragraph and the implementation contradicted it anyway.
            #
            # The substrate owes three things here and owes nothing else: the
            # truth (a `failed` turn row), the named reason (`turns.error` and
            # the `[turn failed]` marker in chat), and the record (the lifecycle
            # event). An agent reading model-policy guidance decides what to do
            # about it — retry elsewhere, spawn something else, or refuse.
            #
            # What this replaced was not merely excess: the hold healed into
            # itself. Clearing it resumed the turn, the turn re-hit the same
            # condition, and it re-raised — gibson livelocked Flynn's session
            # behind a ruling whose only documented exit, `tightbeam adjudicate`,
            # was parsed in args.rs and never routed in dispatch.rs.
            # The refusal replaces the SENTENCE, never the evidence. `reason` is
            # what the user reads; `raw_reason` and `failed_stage` are what the
            # record keeps, because the sentence is a flattening and the next
            # misclassification will be diagnosed from what it flattened.
            raw_reason = reason

            reason =
              case turn_credential_refusal(session) do
                {:refused, message} -> message
                :not_applicable -> reason
              end

            failure_publish = fn _terminal ->
              # THE ERROR MUST REACH THE CHAT. Every failed turn gets the marker
              # now; the adjudication path used to skip it because the brief was
              # its message, and a failure that lost its brief showed Flynn
              # "agent progress interrupted" with no reason attached.
              append_turn_failed_marker(db, turn.session_key, error_sentence(reason))
              publish_turn_state(db, turn.session_key, correlation, "failed", inspect(reason))
              publish_session_indicator(db, turn.session_key, session.owner_user_id)

              broadcast(
                db,
                session.owner_user_id,
                Payloads.activity_event(%{
                  is_active: false,
                  message_id: correlation,
                  session_key: turn.session_key
                })
              )
            end

            # The RECORD half of the substrate's obligation. `Ledger.finish_in_txn`
            # writes the failed row and the sentence the user saw; this keeps
            # what that sentence flattened — WHICH STAGE died and the underlying
            # term — in the same transaction, so the record and the terminal
            # state cannot disagree. It runs only when the finish WON, which is
            # what stops a double-finish from double-recording.
            #
            # The stage is the load-bearing half. Gibson's first production
            # touch was misdiagnosed three times because "the turn failed" was
            # all the durable evidence there was: a checkout fault, a mid-engine
            # fault and a prompt-dispatch fault all read identically after the
            # fact.
            record_in_txn = fn txn ->
              detail =
                try do
                  JSON.encode!(%{stage: failed_stage, reason: raw_reason})
                rescue
                  _ ->
                    JSON.encode!(%{stage: inspect(failed_stage), term: inspect(raw_reason)})
                end

              EventLog.lifecycle_in_txn(txn, "harness_turn_error", turn.session_key, detail)
            end

            {:error,
             %{
               reason: reason,
               terminal_publish: failure_publish,
               record_in_txn: record_in_txn
             }}
        end

      outcome
    end
  end

  # The adapter groups chunks by ACP's public messageId. Commit the whole set
  # before publishing any row so a crash cannot expose half of one turn's
  # assistant messages. Legacy adapters and test doubles return only `text`;
  # they keep the historical one-row behavior through the fallback below.
  defp append_assistant_messages(db, turn, echo, result) do
    texts = assistant_message_texts(result)
    attention_tier = elected_attention(db, turn.seq)

    {:ok, replies} =
      DB.transaction(db, fn txn ->
        Enum.map(texts, fn text ->
          {:appended, reply} =
            Projection.append_in_txn(txn, %{
              session_key: turn.session_key,
              role: "assistant",
              content: text,
              sender: "tightbeam",
              reply_to_message_id: echo && echo.id,
              reply_to_client_message_id: echo && echo.client_message_id,
              attention_tier: attention_tier
            })

          reply
        end)
      end)

    Enum.each(replies, &publish_message(db, turn.session_key, &1))
  end

  defp assistant_message_texts(%{messages: messages}) when is_list(messages) and messages != [] do
    Enum.map(messages, &Map.fetch!(&1, :text))
  end

  defp assistant_message_texts(%{text: text}) when is_binary(text), do: [text]

  defp stage(stage, {:error, reason}), do: {:error, {stage, reason}}
  defp stage(_stage, result), do: result

  defp adapter_key(session), do: {Harness.parse!(session.harness).id(), "shared", session.host}

  # Wire publication for terminals that lost their runner closure: turns
  # recovered at boot (failed_unknown), task crashes, republished rows. The
  # client learns the truth it was owed — terminal turn-state with the
  # reason, typing/activity cleared, progress label cleared.
  @doc false
  # Test seam: the terminal publisher is otherwise only reachable through
  # children/1's wiring, and the crash-recovery marker is exactly the path
  # that has no runner closure to drive it from a test.
  def terminal_publisher_for_test(db), do: terminal_publisher(db)

  defp terminal_publisher(db) do
    fn %{session_key: session_key, message_id: message_id, status: status} = row ->
      echo = Projection.get(db, message_id)
      correlation = (echo && echo.client_message_id) || message_id

      {state, error} =
        case status do
          "delivered" -> {"delivered", nil}
          "canceled" -> {"canceled", nil}
          _ -> {"failed", Map.get(row, :error) || "interrupted: outcome unknown"}
        end

      # Crash-recovered failures get the in-chat marker too — this path IS
      # the "interrupted: outcome unknown" case, the one most likely to
      # otherwise read as a swallowed prompt. Exactly-once: callers invoke
      # this only on the ledger's CAS transition / unpublished-terminal scan.
      if state == "failed", do: append_turn_failed_marker(db, session_key, error)

      publish_turn_state(db, session_key, correlation, state, error)

      with %{} = session <- Org.get(db, session_key) do
        publish_session_indicator(db, session_key, session.owner_user_id)

        broadcast(
          db,
          session.owner_user_id,
          Payloads.activity_event(%{
            is_active: false,
            message_id: correlation,
            session_key: session_key
          })
        )

        progress_state = if state == "delivered", do: "completed", else: "failed"

        broadcast(
          db,
          session.owner_user_id,
          Payloads.agent_progress(session_key, correlation, 1_000_000, "", progress_state)
        )
      end

      :ok
    end
  end

  # Live progress for the typing indicator: relayed from ACP updates
  # (thoughts, tool calls) as agent_progress frames. Runs IN the adapter
  # process — an in-memory registry broadcast, bounded by contract.
  defp progress_fun(db, session_key, owner, correlation) do
    fn text, seq ->
      broadcast(db, owner, Payloads.agent_progress(session_key, correlation, seq, text))
    end
  end

  # Adapter checkout with a HUMAN-readable failure: :degraded is an atom
  # for machines; the chat bubble names the host.
  # Real cancel (gateway.ts cancelCurrent parity, upgraded): the lane owns
  # the CAS-then-kill; here we broadcast the terminal frames and best-effort
  # tell the harness to stop generating (ACP session/cancel notification —
  # fire-and-forget; the substrate's truth is the ledger row either way).
  defp cancel_result(db, call) do
    case Tightbeam.SessionLane.cancel_current(call.session_key) do
      {:ok, %{message_id: message_id, seq: seq}} ->
        echo = Projection.get(db, message_id)
        correlation = (echo && echo.client_message_id) || message_id
        publish_turn_state(db, call.session_key, correlation, "canceled", nil)

        with %{} = session <- Org.get(db, call.session_key) do
          publish_session_indicator(db, call.session_key, session.owner_user_id)

          broadcast(
            db,
            session.owner_user_id,
            Payloads.activity_event(%{
              is_active: false,
              message_id: correlation,
              session_key: call.session_key
            })
          )

          harness_cancel(db, session)
        end

        Ledger.mark_published(db, seq)
        %{ok: true}

      _ ->
        %{ok: false, code: "not_running", message: "no turn in flight"}
    end
  end

  defp harness_cancel(db, session) do
    with %{harness_session_id: sid} <- Org.current_pointer(db, session.session_key),
         key = {Harness.parse!(session.harness).id(), "shared", session.host},
         {:ok, adapter, _gen} <- AdapterCoordinator.adapter_for(Tightbeam.AdapterCoordinator, key) do
      Tightbeam.Acp.Conn.notify(Tightbeam.Acp.Adapter.conn(adapter), "session/cancel", %{
        sessionId: sid
      })
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp checkout_adapter(session) do
    key = {Harness.parse!(session.harness).id(), "shared", session.host}

    case AdapterCoordinator.adapter_for_turn(Tightbeam.AdapterCoordinator, key) do
      {:ok, adapter, generation} ->
        {:ok, adapter, generation}

      {:error, :degraded} ->
        {:error,
         "adapter for #{session.harness}/#{session.identity_name} on host #{session.host} is degraded " <>
           "(host unreachable or adapter failing); see /version"}

      {:error, {:parked, detail}} ->
        {:error,
         "adapter for #{session.harness} on host #{session.host} is being parked: #{detail}"}

      {:error, {:park_fenced, detail}} ->
        {:error,
         "adapter for #{session.harness} on host #{session.host} remains fenced by an incomplete park: #{inspect(detail)}"}

      {:error, reason} ->
        {:error,
         "adapter for #{session.harness}/#{session.identity_name} on host #{session.host} is unavailable: #{inspect(reason)}"}
    end
  end

  @doc false
  def mcp_servers_for_archetype(archetype_name, archetypes \\ Archetypes) do
    archetype_name
    |> archetypes.get()
    |> Kernel.||(archetypes.builtin_default())
    |> archetypes.acp_mcp_servers()
  end

  defp harness_session(config, db, adapter, generation, session, turn_seq) do
    cwd = Placement.holder_workdir(config, session)
    mcp_servers = mcp_servers_for_archetype(session.archetype)
    harness = Harness.parse!(session.harness).id()

    result =
      case Org.current_pointer(db, session.session_key) do
        nil ->
          revision = Identity.live_revision!(config.base_dir)
          snapshot = served_snapshot(config, session, harness, revision)

          with_home_pin_lock(harness, session.host, fn ->
            # Pin the shared home to THIS session's model, then session/new,
            # ATOMICALLY per adapter. The harness re-reads its projected home at
            # every session/new (proven live, wi_263814d3), so pinning the
            # selected model here is what makes the adapter offer and accept it —
            # acceptance tracks selection, killing accepted-then-dead for spawn.
            # The lock keeps a concurrent session's pin from clobbering ours in
            # the window before the adapter reads the file (asg_6508eff5).
            pin_home_to_session_model(config, session, harness)

            with {:ok, sid} <-
                   new_harness_session(
                     db,
                     adapter,
                     session,
                     cwd,
                     mcp_servers,
                     snapshot.guidance
                   ) do
              Org.append_pointer(db, session.session_key, sid, "created")
              Org.set_identity_revision(db, session.session_key, snapshot.revision)
              {:ok, sid}
            end
          end)

        pointer ->
          # The adapter PROCESS is the authority on residency: stamped
          # generations reset across boots and can spuriously match.
          case Adapter.knows_session_for_turn?(adapter, pointer.harness_session_id) do
            true ->
              case push_known_model_for_turn(adapter, pointer.harness_session_id, session.model) do
                :ok -> {:ok, pointer.harness_session_id}
                {:error, _reason} = error -> error
              end

            false ->
              revision = session.identity_revision || Identity.live_revision!(config.base_dir)

              snapshot = served_snapshot(config, session, harness, revision)

              with_home_pin_lock(harness, session.host, fn ->
                # Same atomic [pin -> provision] as the fresh-session branch;
                # session/load also re-reads the projected home, so the resumed
                # session's model is offered and accepted rather than dying on an
                # org-default pin. Held across the load (and its new-session
                # fallback) so no concurrent session re-pins the shared home mid
                # provision (asg_6508eff5).
                pin_home_to_session_model(config, session, harness)

                AdapterCoordinator.with_load_slot(
                  Tightbeam.AdapterCoordinator,
                  session.host,
                  fn ->
                    case Adapter.load_session_for_turn(
                           adapter,
                           pointer.harness_session_id,
                           session.model,
                           cwd,
                           mcp_servers,
                           snapshot.guidance
                         ) do
                      {:ok, _pushed_or_unknown} ->
                        Org.append_pointer(
                          db,
                          session.session_key,
                          pointer.harness_session_id,
                          "loaded"
                        )

                        Org.set_identity_revision(db, session.session_key, snapshot.revision)
                        {:ok, pointer.harness_session_id}

                      {:error, {:model_apply_failed, _reason}} = error ->
                        error

                      # An adapter that could not answer has NOT told us the harness
                      # lost the session; falling back would forfeit the model
                      # context over an adapter fault and record a false
                      # pointer_fallback.
                      {:error, {:adapter_unavailable, _reason}} = error ->
                        error

                      {:error, lost} ->
                        # Spec §pointer chain: reason "fallback" — the harness lost
                        # the session; start fresh, on the record, model context
                        # forfeited but chat history substrate-side and intact.
                        # A fallback is a memory loss: the WHY goes on the record.
                        Tightbeam.EventLog.lifecycle(
                          db,
                          "pointer_fallback",
                          session.session_key,
                          inspect(lost)
                        )

                        with {:ok, sid} <-
                               new_harness_session(
                                 db,
                                 adapter,
                                 session,
                                 cwd,
                                 mcp_servers,
                                 snapshot.guidance
                               ) do
                          Org.append_pointer(db, session.session_key, sid, "fallback")
                          Org.set_identity_revision(db, session.session_key, snapshot.revision)

                          append_session_restart_marker(
                            db,
                            session.session_key,
                            pointer.harness_session_id,
                            sid
                          )

                          {:ok, sid}
                        end
                    end
                  end
                )
              end)

            {:error, _reason} = error ->
              error
          end
      end

    case enrich_adapter_unavailable(config, result, adapter_key(session), generation) do
      {:ok, sid} ->
        if is_integer(turn_seq), do: :ok = Ledger.stamp_adapter(db, turn_seq, generation)
        {:ok, sid}

      error ->
        error
    end
  end

  # Re-pin the shared {harness, host} home to the session's resolved model so the
  # harness adapter offers and accepts it at the next session/new or session/load
  # (both re-read the projected home — proven live, wi_263814d3). Called only on
  # the two branches that push a fresh model to the adapter (create,
  # resume-after-adapter-loss), never the resident-turn common path, so most
  # turns pay nothing. Idempotent when the model is unchanged: the home reconcile
  # is manifest-gated, so an unchanged pin writes nothing, and a change rewrites
  # only the home's owned projection (sessions and history are preserved
  # byte-for-byte). A nil session model falls back to the org default, matching
  # adapter cold-boot. WHICH file the pin lands in and how the model is spelled
  # there stays the harness's business (Harness.reconcile_home/3).
  defp pin_home_to_session_model(config, session, harness) do
    deliver_opts = if config[:sh], do: [sh: config.sh], else: []

    Placement.deliver_home(
      config,
      {harness, "shared", session.host},
      Keyword.put(deliver_opts, :model, session.model)
    )
  end

  # `:noproc` means the adapter died before this call went out, so the call
  # itself carries no reason — the coordinator's record of that death does.
  # Without this, a fast-failing boot reaches the turn as an unactionable
  # ":noproc" (spec s4-operability-v1 §Defect 1: the reason must name the
  # spawn error).
  defp enrich_adapter_unavailable(
         config,
         {:error, {:adapter_unavailable, :noproc}},
         key,
         generation
       ) do
    coordinator = Map.get(config, :adapter_coordinator, Tightbeam.AdapterCoordinator)

    # ATTEMPT-SCOPED: ask only for the death of the generation this turn checked
    # out. If the coordinator has not yet processed that :DOWN — or the record
    # belongs to a PREVIOUS attempt — we get nil and report the generic reason.
    # Mislabelling a new death with its predecessor's reason would be worse than
    # saying less (cross-review F4).
    reason =
      case AdapterCoordinator.last_failure(coordinator, key, generation) do
        nil -> "adapter is not running"
        failure -> Adapter.failure_text(failure)
      end

    {:error, {:adapter_unavailable, reason}}
  rescue
    _ -> {:error, {:adapter_unavailable, "adapter is not running"}}
  catch
    :exit, _ -> {:error, {:adapter_unavailable, "adapter is not running"}}
  end

  defp enrich_adapter_unavailable(_config, result, _key, _generation), do: result

  defp new_harness_session(db, adapter, session, cwd, mcp_servers, guidance) do
    with {:ok, sid} <-
           Adapter.new_session_for_turn(adapter, session.model, cwd, mcp_servers, guidance),
         :ok <- capture_created_model(db, adapter, session, sid) do
      {:ok, sid}
    end
  end

  defp capture_created_model(_db, _adapter, %{model: %Model{}}, _sid),
    do: :ok

  defp capture_created_model(db, adapter, session, sid) do
    case Adapter.current_model_for_turn(adapter, sid) do
      {:ok, %Model{} = reported_model} ->
        _ = Org.set_model(db, session.session_key, reported_model, session.provider)
        :ok

      {:error, :model_readback_unavailable} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp served_snapshot(config, session, harness, revision) do
    snapshot =
      Identity.snapshot_at!(config.base_dir, revision, session.archetype, harness)
      |> Map.update!(:guidance, &append_transcript_self_inspection(&1, session.session_key))

    Placement.materialize_identity(config, session, snapshot)
  end

  defp append_transcript_self_inspection(guidance, session_key) do
    transcript_command =
      "tightbeam transcript --session #{inspect(session_key)} --limit 50"

    guidance <>
      "\n\n## Inspect recent Tightbeam transcript\n\n" <>
      "Before continuing, inspect this session's recent Tightbeam transcript. " <>
      "Run `#{transcript_command}` and read only the bounded result you need. " <>
      "Do not replay or inject earlier messages, and do not assume another " <>
      "harness's private memory transferred."
  end

  defp role_create_result(db, call) do
    case resolve_caller(db, call.origin) do
      nil ->
        %{code: "unknown_caller"}

      %{owner_user_id: nil} ->
        %{code: "denied", message: "processes cannot create roles"}

      caller ->
        with :ok <-
               creation_binding_allowed(
                 db,
                 call.origin,
                 caller.owner_user_id,
                 call.params[:bind]
               ) do
          case Roles.create!(db, call.params[:name], caller.owner_user_id, call.params[:bind]) do
            {:error, error} -> error
            role -> %{role: role}
          end
        else
          {:error, error} -> error
        end
    end
  end

  defp identity_edit_result(config, call) do
    p = call.params
    target = identity_edit_target(p)

    revision =
      Identity.edit!(
        config.base_dir,
        p.archetype,
        target,
        p[:content],
        call.origin
      )

    Archetypes.load!(config.base_dir)
    %{live_revision: revision}
  end

  defp identity_edit_target(%{skill: name, remove: remove}) when is_binary(name),
    do: {:skill, name, remove}

  defp identity_edit_target(%{manifest: true}), do: :manifest
  defp identity_edit_target(_params), do: :guidance

  defp identity_relearn_result(config, %{params: %{action: "abort"}}) do
    :ok = Identity.abort_relearn!(config.base_dir)
    %{state: "aborted", live_revision: Identity.live_revision!(config.base_dir)}
  end

  defp identity_relearn_result(config, %{params: %{action: "resolve"}} = call) do
    revision = Identity.resolve_relearn!(config.base_dir, call.origin)
    reload_law!(config)
    %{state: "published", live_revision: revision}
  end

  defp identity_relearn_result(config, call) do
    case Identity.relearn!(config.base_dir, call.origin) do
      {:ok, revision} ->
        reload_law!(config)
        %{state: "published", live_revision: revision}

      {:conflict, paths} ->
        %{
          state: "relearn-conflicted",
          conflicting_paths: paths,
          live_revision: Identity.live_revision!(config.base_dir)
        }

      {:error, message} ->
        %{
          state: "relearn-failed",
          code: "relearn_failed",
          message: message,
          live_revision: Identity.live_revision!(config.base_dir)
        }
    end
  end

  defp identity_learn_result(config, call) do
    case Identity.learn!(config.base_dir, call.params.name, call.origin) do
      {:ok, revision} ->
        reload_law!(config)
        %{state: "published", kungfu: call.params.name, live_revision: revision}

      {:noop, revision} ->
        reload_law!(config)
        %{state: "already-learned", kungfu: call.params.name, live_revision: revision}

      {:conflict, paths} ->
        %{
          state: "relearn-conflicted",
          kungfu: call.params.name,
          conflicting_paths: paths,
          live_revision: Identity.live_revision!(config.base_dir)
        }

      {:error, message} ->
        %{
          state: "learn-failed",
          code: "learn_failed",
          message: message,
          live_revision: Identity.live_revision!(config.base_dir)
        }
    end
  end

  defp identity_unlearn_result(config, db, call) do
    name = call.params.name
    archetypes = Identity.bundle_archetype_names!(config.base_dir, name)

    case Org.release_archetypes(db, archetypes, fn ->
           revision = Identity.unlearn!(config.base_dir, name, call.origin)
           # Reload before releasing the DB owner. Every reference writer rechecks
           # the archetype inside that same owner, so a writer queued behind this
           # publication cannot commit from a pre-unlearn validation snapshot.
           reload_law!(config)
           revision
         end) do
      {:referenced, references} ->
        unlearn_referenced_result(name, references)

      {:released, revision} ->
        %{state: "published", kungfu: name, live_revision: revision}
    end
  end

  defp unlearn_referenced_result(name, references) do
    sessions = Enum.filter(references, &(&1.kind == "session"))
    setting = Enum.find(references, &(&1.kind == "setting"))
    session_names = Enum.map(sessions, & &1.session_key)

    descriptions =
      [
        if(session_names != [], do: "sessions: #{Enum.join(session_names, ", ")}"),
        if(setting, do: "default-archetype setting: #{setting.archetype}")
      ]
      |> Enum.reject(&is_nil/1)

    %{
      state: "referenced",
      code: "kungfu_referenced",
      message: "cannot unlearn #{name}; #{Enum.join(descriptions, "; ")}",
      sessions:
        Enum.map(
          sessions,
          &%{session_key: &1.session_key, state: &1.state, archetype: &1.archetype}
        ),
      setting: setting && setting.archetype,
      references: references
    }
  end

  defp identity_repoint_result(config, db, call) do
    archetype = call.params.archetype

    result =
      case Org.get(db, call.session_key) do
        nil ->
          {:error, :not_found}

        %{state: "retired"} ->
          repoint_session_record(db, call.session_key, archetype)

        %{kind: "main"} = session ->
          repoint_main_session(config, db, session, archetype)

        %{is_built_in: true} = session ->
          repoint_main_session(config, db, session, archetype)

        _session ->
          {:error, :not_repointable}
      end

    case result do
      {:ok, session} ->
        %{
          state: "repointed",
          session_key: session.session_key,
          archetype: session.archetype
        }

      {:error, :unknown_archetype} ->
        %{code: "unknown_archetype", message: "unknown archetype: #{archetype}"}

      {:error, :not_found} ->
        %{code: "not_found", message: "unknown session: #{call.session_key}"}

      {:error, :not_repointable} ->
        %{
          code: "session_not_retired",
          message: "session #{call.session_key} must be retired before archetype repoint"
        }

      {:error, :turn_in_progress} ->
        turn_in_progress([call.session_key])

      {:error, reason} ->
        %{
          code: "identity_repoint_failed",
          message: "session #{call.session_key} could not change archetype: #{inspect(reason)}"
        }
    end
  end

  defp repoint_main_session(config, db, session, archetype) do
    lane_manager = config[:lane_manager] || LaneManager
    LaneManager.ensure_lane_quiet(lane_manager, session.session_key)

    case Tightbeam.SessionLane.at_turn_boundary(session.session_key, fn ->
           run_session_mutation(session.session_key, fn ->
             current = Org.get(db, session.session_key)

             with :ok <- close_repointed_main_session(config, db, current) do
               repoint_session_record(db, session.session_key, archetype)
             end
           end)
         end) do
      {:ok, result} -> result
      :busy -> {:error, :turn_in_progress}
      :no_lane -> {:error, :turn_in_progress}
    end
  end

  defp close_repointed_main_session(config, db, session) do
    pointer = Org.current_pointer(db, session.session_key)

    if pointer do
      close_resident_main_session(config, session, pointer)
    else
      :ok
    end
  end

  defp close_resident_main_session(config, session, pointer) do
    coordinator = config[:adapter_coordinator] || AdapterCoordinator
    harness = Harness.parse!(session.harness).id()

    with {:ok, adapter, _generation} <-
           AdapterCoordinator.adapter_for(coordinator, {harness, "shared", session.host}) do
      case Adapter.knows_session?(adapter, pointer.harness_session_id) do
        true -> Adapter.close_session(adapter, pointer.harness_session_id)
        false -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp repoint_session_record(db, session_key, archetype) do
    case DB.transaction(db, fn txn ->
           if Archetypes.get(archetype) do
             Org.repoint_archetype_in_txn(txn, session_key, archetype)
           else
             {:error, :unknown_archetype}
           end
         end) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp reload_law!(config, verbs \\ nil) do
    verbs = verbs || config |> handlers() |> Map.keys()
    Archetypes.load!(config.base_dir)
    Rails.load!(config.base_dir)
    Rules.load!(config.base_dir, verbs)
  end

  defp identity_status_result(config, db, call) do
    identity = Identity.status(config.base_dir)
    live = identity.live_revision

    sessions =
      db
      |> Org.list_for_user("", true)
      |> Enum.map(fn session ->
        %{
          session_key: session.session_key,
          identity_revision: session.identity_revision,
          identity_stale: session.identity_revision != live
        }
      end)

    guidance =
      case call.params[:archetype] do
        archetype when is_binary(archetype) ->
          Map.new(Harness.all(), fn module ->
            snapshot = Identity.snapshot_at!(config.base_dir, live, archetype, module.id())
            {module.id(), module.session_config(%{}, snapshot.guidance).guidance}
          end)

        nil ->
          nil
      end

    identity
    |> Map.put(:sessions, sessions)
    |> maybe_put_guidance(guidance)
  end

  defp maybe_put_guidance(status, nil), do: status
  defp maybe_put_guidance(status, guidance), do: Map.put(status, :guidance, guidance)

  defp identity_apply_result(config, db, %{params: %{all: true}}) do
    sessions = Org.list_for_user(db, "", true)
    identity_apply_sessions(config, db, sessions)
  end

  defp identity_apply_result(config, db, %{params: %{session_key: session_key}}) do
    sessions =
      case Org.get(db, session_key) do
        nil -> []
        session -> [session]
      end

    identity_apply_sessions(config, db, sessions)
  end

  defp identity_apply_sessions(_config, _db, []),
    do: %{code: "not_found", message: "no matching session"}

  defp identity_apply_sessions(config, db, sessions) do
    # Busy means RUNNING, never merely queued (tenet T-CONCURRENCY). The hazard
    # this guard exists for is work IN FLIGHT: instructions must not change under
    # a turn whose world is already composed. A queued turn has composed nothing
    # and reads live identity when it starts, which is indistinguishable from any
    # turn started after the apply.
    busy =
      sessions
      |> Enum.filter(&Ledger.running?(db, &1.session_key))
      |> Enum.map(& &1.session_key)

    identity_apply_at_boundary(config, db, sessions, busy)
  end

  defp identity_apply_at_boundary(_config, _db, _sessions, [_ | _] = busy),
    do: turn_in_progress(busy)

  defp identity_apply_at_boundary(config, db, sessions, []) do
    live = Identity.live_revision!(config.base_dir)

    sessions
    |> Enum.reduce_while([], fn session, applied ->
      case identity_apply_session(config, db, session, live) do
        :applied ->
          best_effort(fn ->
            stream = db |> Org.get(session.session_key) |> Payloads.stream_session()
            broadcast(db, session.owner_user_id, Payloads.stream_updated(stream))
          end)

          {:cont, [session.session_key | applied]}

        :noop ->
          {:cont, [session.session_key | applied]}

        {:error, refusal} ->
          {:halt, refusal}
      end
    end)
    |> case do
      applied when is_list(applied) ->
        %{applied: Enum.reverse(applied), identity_revision: live}

      refusal ->
        refusal
    end
  end

  defp identity_apply_session(config, db, session, revision) do
    case Org.current_pointer(db, session.session_key) do
      # A session that has never started has no harness session to bounce AND no
      # stamp to correct: it materializes from `tightbeam/live` at its first
      # start (§Sessions stamp the revision they materialized from), so it is
      # already on the applied revision by construction. Nothing to do is the
      # true answer here, and the only place it is.
      nil -> :noop
      pointer -> identity_apply_at_lane(config, db, session, revision, pointer)
    end
  end

  defp turn_in_progress(sessions) do
    %{
      code: "turn_in_progress",
      message: "identity apply requires a turn boundary",
      sessions: sessions
    }
  end

  # The busy check and this bounce are separated by adapter work, and the lane can
  # claim a queued turn in that window — so sampling status in the gateway would
  # leave apply reloading a session whose turn had just started. Claiming is
  # serialized in the LANE, so the decision belongs in its mailbox: while it runs
  # this call it cannot claim, and a nudge that arrives waits behind it.
  #
  # There is no direct path for a session that has no lane. "No lane exists" is a
  # sample of a mutable fact, and a lane can be BORN inside the window — a
  # delivery calls ensure_lane and the newborn claims on its own init nudge — so
  # ensuring first leaves ONE path to keep correct. Either ordering then resolves
  # inside the lane: if the init nudge claims first we get :busy and defer; if
  # this call lands first, the nudge waits behind it.
  #
  # QUIET, deliberately: ensure_lane/2 also nudges, which would make an idle lane
  # claim a queued turn and hand back the very refusal the queued/running boundary
  # exists to remove. Apply must never manufacture the turn it then defers to.
  defp identity_apply_at_lane(config, db, session, revision, pointer) do
    bounce = fn -> identity_apply_started_session(config, db, session, revision, pointer) end
    LaneManager.ensure_lane_quiet(config[:lane_manager] || LaneManager, session.session_key)

    case Tightbeam.SessionLane.at_turn_boundary(session.session_key, bounce) do
      {:ok, result} ->
        result

      :busy ->
        {:error, turn_in_progress([session.session_key])}

      # Unreachable once the lane is ensured — this is the lane dying in the gap,
      # not a state to design around. Defer rather than bounce outside a lane:
      # the point of the seam is that no bounce happens unowned.
      :no_lane ->
        {:error, turn_in_progress([session.session_key])}
    end
  end

  defp identity_apply_started_session(config, db, session, revision, pointer) do
    harness = Harness.parse!(session.harness).id()
    key = {harness, "shared", session.host}
    cwd = Placement.holder_workdir(config, session)
    snapshot = served_snapshot(config, session, harness, revision)
    mcp_servers = mcp_servers_for_archetype(session.archetype)

    with {:ok, adapter, _generation} <-
           AdapterCoordinator.adapter_for(Tightbeam.AdapterCoordinator, key),
         # The adapter PROCESS is the authority on residency, the same way the
         # start and tune paths ask it. A pointer row only records that a harness
         # session once existed; after a gateway restart every pointer names a
         # session no adapter holds, and bouncing it asks the harness to close
         # something it has never heard of.
         true <- Adapter.knows_session?(adapter, pointer.harness_session_id),
         :ok <- Adapter.close_session(adapter, pointer.harness_session_id),
         {:ok, _pushed_or_unknown} <-
           Adapter.load_session(
             adapter,
             pointer.harness_session_id,
             session.model,
             cwd,
             mcp_servers,
             snapshot.guidance
           ) do
      Org.append_pointer(db, session.session_key, pointer.harness_session_id, "loaded")
      Org.set_identity_revision(db, session.session_key, snapshot.revision)
      :applied
    else
      # No resident session to bounce, so the stamp IS the application. The next
      # start reloads from `session.identity_revision`, not from `live`, so
      # leaving the stamp behind would mean this session materialized stale
      # forever while `identity status` kept calling it stale and apply kept
      # reporting it applied. No pointer event is appended: nothing was loaded,
      # and the pointer chain does not record things that did not happen.
      false ->
        Org.set_identity_revision(db, session.session_key, snapshot.revision)
        :applied

      {:error, reason} ->
        {:error,
         %{
           code: "apply_failed",
           message:
             "identity apply could not reach #{session.session_key}: #{apply_failure(reason)}",
           sessions: [session.session_key]
         }}
    end
  end

  # A live adapter that fails for its own reasons still surfaces, but as this
  # verb's named refusal rather than as a raw JSON-RPC envelope from three layers
  # down. The general error-boundary seam is its own ticket; this is one call
  # site's error made legible.
  defp apply_failure(%{"message" => message}) when is_binary(message), do: message
  defp apply_failure(reason), do: inspect(reason)

  @onboarding_providers ["openai", "anthropic"] ++
                          if(Application.compile_env(:tightbeam, :fixture_harness, false),
                            do: ["fixture-provider"],
                            else: []
                          )

  defp onboard_result(config, %{params: %{provider: provider, phase: phase} = params})
       when provider in @onboarding_providers and phase in ["begin", "finish", "cancel"] do
    machine = params[:machine] || Placement.local_host_name()

    with true <- Map.has_key?(Placement.hosts(config.base_dir, gateway_db(config)), machine),
         {:ok, kind} <- onboarding_kind(params[:kind]) do
      onboard_phase(
        config,
        provider_atom(provider),
        phase,
        machine,
        kind,
        params[:lease_id],
        params[:reason]
      )
    else
      false ->
        %{code: "unknown_host", message: "unknown onboarding machine #{machine}"}

      :error ->
        %{
          code: "invalid_message",
          message:
            "unknown credential kind #{inspect(params[:kind])}; expected apiKey or subscription"
        }
    end
  end

  defp onboard_result(_config, %{params: %{provider: provider}}) do
    %{
      code: "interactive_required",
      message: "run tightbeam onboard #{provider} from a terminal on this machine"
    }
  end

  defp onboard_phase(config, provider, "begin", machine, kind, _lease_id, _reason) do
    case Tightbeam.Credentials.begin_onboard(provider, Tightbeam.Credentials.server(machine)) do
      {:ok, path, lease_id} ->
        # The lease TTL rides the reply so the CLI's ceremony watchdog and the
        # server's lease are one fact with one home. A matching constant in the
        # Rust CLI would drift from `production_config` the first time either is
        # tuned, and the CLI cannot read `production_config` itself.
        #
        # `kind` is echoed, not consumed: a LEASE carries no opinion about what
        # will be banked into it (`Credentials.finish_onboard/4`). It is here so
        # a gateway log shows which ceremony an operator started — in the WIRE
        # spelling (`wire_credential_kind/1`), like every other surface: the
        # camelizer rewrites keys, not atom values, so a bare `kind` put the
        # store's "api_key" on a wire whose contract says "apiKey".
        %{
          provider: provider,
          kind: wire_credential_kind(kind),
          status: "ready",
          staging_path: path,
          lease_id: lease_id,
          lease_ttl_ms: config.onboarding_lease_ms
        }

      {:error, reason} ->
        %{code: "needs_onboarding", message: inspect(reason)}
    end
  end

  defp onboard_phase(_config, provider, "finish", machine, kind, lease_id, _reason) do
    case Tightbeam.Credentials.finish_onboard(
           provider,
           kind,
           lease_id,
           Tightbeam.Credentials.server(machine)
         ) do
      :ok ->
        # The result the CLI prints. It names the kind that was banked, so a
        # successful ceremony says which of the two it installed rather than
        # leaving the operator to go read the store — in the WIRE spelling
        # (`wire_credential_kind/1`), like every other surface: the camelizer
        # rewrites keys, not atom values, so a bare `kind` here put the store's
        # "api_key" on a wire whose contract says "apiKey".
        %{provider: provider, credential_kind: wire_credential_kind(kind), status: "onboarded"}

      {:error, reason} ->
        %{
          code: "needs_onboarding",
          message: "#{provider} #{kind} credential on #{machine}: #{inspect(reason)}"
        }
    end
  end

  defp onboard_phase(_config, provider, "cancel", machine, _kind, lease_id, reason) do
    case Tightbeam.Credentials.cancel_onboard(
           provider,
           lease_id,
           onboarding_failure(reason),
           Tightbeam.Credentials.server(machine)
         ) do
      :ok ->
        %{provider: provider, status: "canceled"}

      {:error, reason} ->
        %{code: "needs_onboarding", message: inspect(reason)}
    end
  end

  defp onboarding_failure("unsupported_no_subscription"), do: :unsupported_no_subscription
  defp onboarding_failure(_reason), do: nil

  # The wire says `apiKey`; the store says `api_key`. This is the one place the
  # translation happens on the way in, mirroring `wire_credential_kind/1` on the
  # way out.
  #
  # An absent kind is a subscription: every ceremony that predates the API-key
  # path is one, and a client that does not send the field is such a ceremony.
  defp onboarding_kind(nil), do: {:ok, :subscription}
  defp onboarding_kind("subscription"), do: {:ok, :subscription}
  defp onboarding_kind("apiKey"), do: {:ok, :api_key}
  defp onboarding_kind(_unknown), do: :error

  defp provider_atom("openai"), do: :openai
  defp provider_atom("anthropic"), do: :anthropic
  defp provider_atom("fixture-provider"), do: :fixture_provider

  defp role_bind_result(db, call) do
    name = call.params[:name]
    session_key = call.params[:session_key]

    with role when not is_nil(role) <- Roles.get(db, name),
         {:ok, caller} <- caller_for_role_mutation(db, call.origin),
         :ok <- role_mutation_allowed(db, caller, call.origin, role),
         :ok <- binding_owner_allowed(db, call.origin, role, session_key),
         :ok <- Roles.bind(db, name, session_key) do
      %{role: Roles.get(db, name)}
    else
      nil -> %{code: "unknown_role", message: "unknown role: #{name}"}
      {:error, error} -> error
    end
  end

  defp role_rm_result(db, call) do
    name = call.params[:name]

    with role when not is_nil(role) <- Roles.get(db, name),
         {:ok, caller} <- caller_for_role_mutation(db, call.origin),
         :ok <- role_mutation_allowed(db, caller, call.origin, role),
         :ok <- Roles.rm(db, name) do
      %{removed: name}
    else
      nil -> %{code: "unknown_role", message: "unknown role: #{name}"}
      {:error, error} -> error
    end
  end

  defp role_list_result(db) do
    roles =
      Enum.map(Roles.list(db), fn role ->
        Map.put(role, :fallback_target, Org.personal_session_key(role.owner_user_id))
      end)

    %{roles: roles}
  end

  defp role_mutation_allowed(_db, %{owner_user_id: nil}, _origin, _role),
    do: {:error, %{code: "denied", message: "processes cannot mutate roles"}}

  defp role_mutation_allowed(db, caller, origin, role) do
    if caller.owner_user_id == role.owner_user_id or admin_origin?(db, origin),
      do: :ok,
      else: {:error, %{code: "denied", message: "role owner or admin required"}}
  end

  defp caller_for_role_mutation(db, origin) do
    case resolve_caller(db, origin) do
      nil -> {:error, %{code: "unknown_caller", message: "unknown caller"}}
      caller -> {:ok, caller}
    end
  end

  defp binding_owner_allowed(db, origin, role, session_key) do
    case Org.get(db, session_key) do
      %{state: "active"} = session ->
        if session.owner_user_id == role.owner_user_id or admin_origin?(db, origin),
          do: :ok,
          else:
            {:error, %{code: "denied", message: "binding target must be owned by the role owner"}}

      _ ->
        {:error, %{code: "unknown_session", message: "unknown active session: #{session_key}"}}
    end
  end

  defp creation_binding_allowed(_db, _origin, _owner_user_id, nil), do: :ok

  defp creation_binding_allowed(db, origin, owner_user_id, session_key) do
    binding_owner_allowed(db, origin, %{owner_user_id: owner_user_id}, session_key)
  end

  # Processes (cron/CI/automation) resolve as callers with NO owner and NO
  # session: enough standing to wake, cancel their own wakes, and file
  # org-owned condition facts; every
  # owner- or admin-gated path falls through to denial naturally.
  defp resolve_caller(_db, "user:" <> user_id), do: %{owner_user_id: user_id, caller_session: nil}

  defp resolve_caller(_db, "process:" <> name) when name != "",
    do: %{owner_user_id: nil, caller_session: nil}

  defp resolve_caller(db, "agent:" <> role) do
    with {:ok, session_key, false} <- Roles.resolve(db, role),
         %{state: "active"} = caller <- Org.get(db, session_key) do
      %{owner_user_id: caller.owner_user_id, caller_session: caller}
    else
      _ -> nil
    end
  end

  defp resolve_caller(_db, _origin), do: nil

  # Authority for asserting `work-blocked`/`work-unblocked` over a session
  # (spec production-machine-v1 §Standing facts): the scope names an existing
  # session, and the caller is above it in the spawnedBy lineage, or is the
  # scope session's owner (as a user principal), or is an admin. A session
  # asserting over ITSELF is refused — the judgment "stop treating this
  # session as stalled" belongs to whoever supervises it, not to it.
  defp work_block_authority?(db, call, scope) do
    with true <- is_binary(scope) and scope != "",
         %{owner_user_id: owner} <- Org.get(db, scope) do
      case call[:principal] do
        {:user, user_id} ->
          user_id == owner or match?(%{is_admin: true}, Devices.user(db, user_id))

        {:session, caller_key} ->
          caller_key != scope and caller_in_lineage_above?(db, scope, caller_key)

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  defp caller_in_lineage_above?(db, scope, caller_key, hops \\ 0)
  defp caller_in_lineage_above?(_db, _scope, _caller_key, hops) when hops > 32, do: false

  defp caller_in_lineage_above?(db, scope, caller_key, hops) do
    case DB.query(db, "SELECT spawnedBy FROM sessions WHERE sessionKey = ?1", [scope]) do
      {:ok, [[parent]]} when is_binary(parent) ->
        parent == caller_key or caller_in_lineage_above?(db, parent, caller_key, hops + 1)

      _ ->
        false
    end
  end

  defp admin_origin?(db, origin) do
    case resolve_caller(db, origin) do
      %{owner_user_id: user_id} -> match?(%{is_admin: true}, Devices.user(db, user_id))
      _ -> false
    end
  end

  defp config_result(db, %{action: "get", setting: "default-archetype"}) do
    %{
      setting: "default-archetype",
      value: Org.get_setting(db, "default-archetype") || "default"
    }
  end

  defp config_result(db, %{
         action: "set",
         setting: "default-archetype",
         value: archetype_name
       }) do
    case DB.transaction(db, fn txn ->
           if Archetypes.get(archetype_name) do
             Org.put_setting_in_txn(txn, "default-archetype", archetype_name)
           else
             {:error, :unknown_archetype}
           end
         end) do
      {:ok, :ok} ->
        %{setting: "default-archetype", value: archetype_name}

      {:ok, {:error, :unknown_archetype}} ->
        %{code: "unknown_archetype", message: "no such archetype: #{archetype_name}"}

      {:error, error} ->
        raise error
    end
  end

  defp config_result(_db, _params) do
    %{code: "invalid", message: "config supports get/set default-archetype"}
  end

  defp admin_handler(db, fun) do
    fn call ->
      if admin_origin?(db, call.origin),
        do: fun.(call.params),
        else: %{code: "forbidden", message: "admin required"}
    end
  end

  defp admin_call_handler(db, fun) do
    fn call ->
      if admin_origin?(db, call.origin),
        do: fun.(call),
        else: %{code: "forbidden", message: "admin required"}
    end
  end

  defp notify_session(config, db, session_key, prompt) do
    deliver_prompt(session_key, "process:tightbeam", prompt,
      db: db,
      sender: "process:tightbeam",
      conn_registry: config[:conn_registry] || Tightbeam.ConnRegistry,
      lane_manager: config[:lane_manager] || Tightbeam.LaneManager
    )
  end

  defp override_skill_names(nil), do: []
  defp override_skill_names(overrides), do: Map.get(overrides, "skills_add", [])

  defp carry_pinned_overrides(_base_dir, identity_name, identity_name, _overrides), do: :ok
  defp carry_pinned_overrides(_base_dir, _old_identity, _new_identity, nil), do: :ok

  defp carry_pinned_overrides(base_dir, old_identity, new_identity, overrides) do
    Enum.each(override_skill_names(overrides), fn skill ->
      source = Path.join([base_dir, "identity", "pinned", old_identity, skill])

      if File.exists?(source) do
        destination = Path.join([base_dir, "identity", "pinned", new_identity, skill])
        File.rm_rf!(destination)
        File.mkdir_p!(Path.dirname(destination))
        File.cp_r!(source, destination)
      end
    end)

    :ok
  end

  defp session_mutation_allowed(db, origin, session) do
    case resolve_caller(db, origin) do
      %{owner_user_id: owner} when owner == session.owner_user_id ->
        :ok

      %{} ->
        if admin_origin?(db, origin),
          do: :ok,
          else: {:error, %{code: "denied", message: "session owner or admin required"}}

      nil ->
        {:error, %{code: "unknown_caller", message: "unknown caller"}}
    end
  end

  defp inspect_result(config, db, call) do
    case resolve_caller(db, call.origin) do
      nil ->
        %{code: "unknown_caller"}

      %{owner_user_id: nil} ->
        wakes =
          Wakes.list_pending(db)
          |> Enum.filter(&(&1.origin == call.origin))
          |> Enum.map(&Map.take(&1, [:wake_id, :session_key, :due_at, :prompt]))

        Map.put(%{wakes: wakes}, :roles, role_list_result(db).roles)

      caller ->
        sessions = Org.list_for_user(db, caller.owner_user_id, false)
        keys = MapSet.new(sessions, & &1.session_key)
        wakes = Wakes.list_pending(db) |> Enum.filter(&MapSet.member?(keys, &1.session_key))

        # Discovery beats documentation: the org's SHAPE — what archetypes
        # exist (and their WHERE), what hosts are known, what model refs are
        # valid — is not a secret from its members. Without this, agents
        # guess (and guess model names wrong).
        org_shape = %{
          archetypes:
            Enum.map(Archetypes.names(), fn name ->
              a = Archetypes.get(name)

              %{
                name: a.name,
                where: a.where,
                defaults: wire_defaults(a.defaults),
                modelPreferences: Enum.map(a.model_preferences, &wire_preference/1)
              }
            end),
          hosts:
            config.base_dir |> Placement.hosts(gateway_db(config)) |> Map.keys() |> Enum.sort(),
          models: picker_models(config.base_dir, gateway_db(config))
        }

        result = %{
          sessions: Enum.map(sessions, &inspect_session/1),
          wakes: wakes,
          roles: role_list_result(db).roles,
          archetypes: org_shape.archetypes,
          hosts: org_shape.hosts,
          models: org_shape.models
        }

        if admin_origin?(db, call.origin) do
          pending =
            Devices.list_pending(db)
            |> Enum.map(&Map.take(&1, [:device_id, :claimed_name, :user_id, :platform, :model]))

          Map.put(result, :pending_devices, pending)
        else
          result
        end
    end
  end

  defp facts_read_result(db, call) do
    p = call.params

    cond do
      not (is_binary(p[:kind]) and p.kind != "") ->
        %{code: "invalid", message: "facts-read requires a kind"}

      not (is_nil(p[:scope]) or (is_binary(p.scope) and p.scope != "")) ->
        %{code: "invalid", message: "facts-read scope must be a non-empty string"}

      true ->
        fact = ConditionFacts.latest(db, p.kind, p[:scope])
        %{exists: not is_nil(fact), fact: fact}
    end
  end

  defp maybe_put_progress_interval(%{params: %{kind: "progress"}} = call, config) do
    Map.put(call, :supervision_interval_ms, Map.fetch!(config, :wake_tick_ms))
  end

  defp maybe_put_progress_interval(call, _config), do: call

  defp cancel_wake_result(db, call, wake_id) do
    with {:ok, requester} <- cancellation_requester(call[:principal]) do
      command = %{
        wake_id: wake_id,
        expected_origin: call.origin,
        requester: requester,
        reason_kind: "requester_withdrew",
        causal_source: %{
          kind: "verb_call",
          accepted_event: %{
            origin: call.origin,
            session_key: call.session_key,
            principal: call.principal
          }
        },
        outcome: %{kind: "no_replacement"}
      }

      case DB.transaction(db, fn txn -> Wakes.cancel_in_txn(txn, command) end) do
        {:ok, {:accepted_in_txn, event_id, %{canceled: true}}}
        when is_integer(event_id) and event_id > 0 ->
          {:accepted_in_txn, event_id, %{canceled: true}}

        {:ok, false} ->
          %{canceled: false}

        {:ok, other} ->
          raise "invalid public wake cancellation result: #{inspect(other)}"

        {:error, error} ->
          raise error
      end
    else
      :error -> %{canceled: false}
    end
  end

  defp cancellation_requester({:user, id}) when is_binary(id) and id != "",
    do: {:ok, %{kind: "user", id: id}}

  defp cancellation_requester({:session, id}) when is_binary(id) and id != "",
    do: {:ok, %{kind: "session", id: id}}

  defp cancellation_requester({:process, id}) when is_binary(id) and id != "",
    do: {:ok, %{kind: "process", id: id}}

  defp cancellation_requester(_principal), do: :error

  defp wake_result(config, db, call) do
    p = call.params

    case call.session_key do
      session_key when is_binary(session_key) ->
        due_at = p[:at] || System.system_time(:millisecond) + (p[:after_ms] || 0)

        result =
          DB.transaction(db, fn txn ->
            prior =
              if p[:idempotency_key],
                do: Idempotency.get_in_txn(txn, call.origin, "wake", p.idempotency_key)

            if prior do
              case DB.Txn.q(txn, select_wake_in_txn_sql(), [prior.session_key]) do
                [row] -> wake_from_in_txn_row(row)
                [] -> nil
              end
            else
              wake = schedule_wake_in_txn(txn, call, session_key, due_at)

              if p[:idempotency_key] && is_binary(wake[:wake_id]) do
                Idempotency.put_in_txn(txn, %{
                  owner_user_id: call.origin,
                  operation: "wake",
                  idempotency_key: p.idempotency_key,
                  session_key: wake.wake_id
                })
              end

              wake
            end
          end)

        wake =
          case result do
            {:ok, wake} -> wake
            {:error, error} -> raise error
          end

        if is_binary(wake[:wake_id]) do
          if due_at <= System.system_time(:millisecond) and p[:nudge] != false,
            do: Wakes.fire_due(Map.get(config, :wake_scheduler, Tightbeam.WakeScheduler))

          wake_response(wake)
        else
          wake
        end

      _ ->
        %{code: "not_found"}
    end
  end

  defp schedule_wake_in_txn(txn, call, session_key, due_at) do
    p = call.params

    if p[:condition_kind] == "subagent_stop" do
      caller_session = creator_session_key(call[:principal])

      case SubagentMarkers.resolve_subagent_in_txn(txn, caller_session, p[:condition_scope]) do
        nil ->
          %{
            code: "subagent_not_found",
            message: "no subagent for this session and tool call"
          }

        subagent_ref ->
          if SubagentMarkers.stopped_in_txn?(txn, subagent_ref) do
            %{
              code: "subagent_already_stopped",
              subagent_ref: subagent_ref
            }
          else
            schedule_wake_row_in_txn(
              txn,
              call,
              session_key,
              due_at,
              "subagent_stop",
              subagent_ref
            )
          end
      end
    else
      schedule_wake_row_in_txn(
        txn,
        call,
        session_key,
        due_at,
        p[:condition_kind],
        p[:condition_scope]
      )
    end
  end

  defp schedule_wake_row_in_txn(
         txn,
         call,
         session_key,
         due_at,
         condition_kind,
         condition_scope
       ) do
    p = call.params

    wake =
      Wakes.schedule_in_txn(txn, %{
        session_key: session_key,
        target_role: Map.get(call, :target_role),
        origin: call.origin,
        prompt: p.prompt,
        due_at: due_at,
        condition_kind: condition_kind,
        condition_scope: condition_scope,
        creator_session_key: creator_session_key(call[:principal]),
        reresolve: p[:reresolve],
        reresolve_seed: p[:reresolve_seed],
        reresolve_rung: p[:reresolve_rung],
        # SUBSTRATE-ONLY carrier. `wake` is an agent-callable verb, so an arbitrary
        # params value here would let an agent stamp a conversational wake with any
        # assignment and have delivery promote that forged carrier into the turn and
        # the trace — agent-authored attribution, which Law 0 forbids (F6). Only the
        # substrate's own principal may set it; the router reserves
        # process:tightbeam, so it cannot be claimed over the wire. Conversational
        # and owner wakes stay NULL, as the spec requires.
        assignment_id: substrate_assignment_id(call)
      })

    bind_liveness_checkpoint_in_txn(txn, call, wake)
    schedule_supervision_controller_in_txn(txn, call, wake)
    wake
  end

  defp bind_liveness_checkpoint_in_txn(
         txn,
         %{principal: {:session, creator_session_key}},
         %{session_key: creator_session_key, wake_id: wake_id}
       ) do
    Supervision.transition_in_txn(txn, %{
      kind: "checkpoint_scheduled",
      wake_id: wake_id,
      creator_session_key: creator_session_key
    })
  end

  defp bind_liveness_checkpoint_in_txn(_txn, _call, _wake), do: :duplicate

  # The controller row is part of the supervision wake, not follow-up
  # bookkeeping. Keeping both writes under the wake handler's transaction means
  # a crash can commit both rows or neither, never a lineage wake that boot later
  # has to guess about. The kind is trusted only from Tightbeam's reserved process
  # principal, just like the assignment carrier above.
  defp schedule_supervision_controller_in_txn(
         txn,
         %{principal: {:process, "tightbeam"}, params: %{supervision_wake_kind: wake_kind}},
         wake
       )
       when wake_kind in ["prod", "escalation"] do
    case Supervision.transition_in_txn(txn, %{
           kind: "controller_scheduled",
           wake_id: wake.wake_id,
           assignment_id: wake.assignment_id,
           wake_kind: wake_kind
         }) do
      {:armed, _generation} ->
        :ok

      :duplicate ->
        # An internal supervision marker is a claim that this wake is a typed
        # controller. If no entitlement can arm its sidecar, committing the wake
        # would strand an unfireable controller. Roll the handler transaction
        # back so wake and sidecar remain all-or-nothing.
        raise "incompatible_supervision_liveness_v1: controller schedule :duplicate"
    end
  end

  defp schedule_supervision_controller_in_txn(
         _txn,
         %{principal: {:process, "tightbeam"}, params: %{supervision_wake_kind: wake_kind}},
         _wake
       ) do
    raise "incompatible_supervision_liveness_v1: unknown controller kind #{inspect(wake_kind)}"
  end

  defp schedule_supervision_controller_in_txn(_txn, _call, _wake), do: :ok

  defp substrate_assignment_id(%{principal: {:process, "tightbeam"}} = call),
    do: call.params[:assignment_id]

  defp substrate_assignment_id(_call), do: nil

  defp creator_session_key({:session, key}), do: key
  defp creator_session_key(_principal), do: nil

  defp select_wake_in_txn_sql do
    "SELECT wakeId, dueAt, state FROM wakes WHERE wakeId = ?1"
  end

  defp wake_from_in_txn_row([wake_id, due_at, state]),
    do: %{wake_id: wake_id, due_at: due_at, state: state}

  defp wake_response(wake) do
    %{wake_id: wake.wake_id, due_at: wake.due_at, state: wake.state}
  end

  defp valid_reresolve?(p) do
    case {p[:reresolve], p[:reresolve_seed], p[:reresolve_rung]} do
      {nil, nil, nil} -> true
      {"lineage", seed, rung} -> not is_nil(seed) and not is_nil(rung)
      _ -> false
    end
  end

  defp spawn_result(config, db, call) do
    p = call.params
    max_live_sessions = Map.get(config, :max_live_sessions_per_user)

    case spawn_caller(db, call) do
      nil ->
        %{code: "unknown_caller"}

      %{owner_user_id: nil} ->
        %{code: "forbidden", message: "processes cannot spawn sessions"}

      caller ->
        prior = Idempotency.get(db, caller.owner_user_id, "spawn", p.idempotency_key)

        cond do
          prior ->
            spawn_replay(db, prior.session_key)

          is_integer(max_live_sessions) and max_live_sessions > 0 and
              length(Org.list_for_user(db, caller.owner_user_id, false)) >= max_live_sessions ->
            spawn_cap_exceeded(max_live_sessions, caller.owner_user_id)

          true ->
            create_spawn(config, db, call, caller)
        end
    end
  end

  defp spawn_caller(_db, %{principal: {:remedy, %{action: "spawn", owner: owner}}})
       when is_binary(owner),
       do: %{owner_user_id: owner, caller_session: nil}

  defp spawn_caller(db, call), do: resolve_caller(db, call.origin)

  defp wake_principal_allowed?(_db, %{principal: {:remedy, %{action: "wake"}}}), do: true
  defp wake_principal_allowed?(db, call), do: not is_nil(resolve_caller(db, call.origin))

  defp create_spawn(config, db, call, caller) do
    p = call.params
    defaults = defaults(config, db)
    archetype_name = p[:archetype] || defaults.archetype

    # Identity must exist; placement is constitutional set membership
    # (spec §Placement) — Placement denies, we relay, nobody judges.
    case Archetypes.get(archetype_name) do
      nil ->
        %{code: "unknown_archetype", message: "no such archetype: #{archetype_name}"}

      archetype ->
        override_result =
          if Map.has_key?(p, :overrides) do
            Archetypes.normalize_overrides(config.base_dir, archetype, p.overrides)
          else
            {:ok, nil}
          end

        case override_result do
          {:ok, overrides} ->
            harness = p[:harness] || archetype.defaults[:harness] || defaults.harness

            module =
              if is_atom(harness), do: Harness.module!(harness), else: Harness.parse!(harness)

            default_model = archetype.defaults[:model] || defaults.model

            with {:ok, placement} <-
                   resolve_spawn_host(config, db, archetype, p, module, default_model) do
              create_spawn(config, db, call, caller, archetype, placement, overrides)
            else
              {:error, denial} ->
                classified_spawn_denial(denial, "config_denied", "placement_denied")
            end

          {:error, denial} ->
            classified_spawn_denial(denial, "config_denied", "placement_denied")
        end
    end
  end

  defp resolve_spawn_host(config, db, archetype, %{host: host}, _module, _default_model)
       when is_binary(host) do
    with {:ok, resolved} <-
           Placement.resolve(archetype, host, Placement.hosts(config.base_dir, db)),
         do: {:ok, %{host: resolved}}
  end

  defp resolve_spawn_host(
         config,
         db,
         %{where: ["*"]} = archetype,
         _p,
         _module,
         _default_model
       ) do
    with {:ok, resolved} <-
           Placement.resolve(archetype, nil, Placement.hosts(config.base_dir, db)),
         do: {:ok, %{host: resolved}}
  end

  defp resolve_spawn_host(config, db, archetype, p, module, default_model) do
    hosts = Placement.hosts(config.base_dir, db)
    harness = module.wire_name()

    case archetype.where do
      [host] when is_map_key(hosts, host) ->
        {:ok, %{host: host}}

      _multiple_or_missing ->
        resolve_spawn_host_candidates(
          config,
          db,
          archetype,
          p,
          module,
          default_model,
          hosts,
          harness
        )
    end
  end

  defp resolve_spawn_host_candidates(
         config,
         db,
         archetype,
         p,
         module,
         default_model,
         hosts,
         harness
       ) do
    result =
      Enum.reduce_while(archetype.where, [], fn host, failures ->
        candidate =
          with {:ok, ^host} <- Placement.resolve(archetype, host, hosts),
               :ok <- validate_credential(config, harness, host),
               model = spawn_model_selection(host, harness, p, default_model),
               {:ok, routed} <- route_spawn_candidate(host, harness, model),
               :ok <- Spinup.ensure_ready(config, module.id(), host, spinup_opts(config, db)) do
            {:ok, %{host: host, model: model, routed: routed}}
          end

        case candidate do
          {:ok, placement} ->
            {:halt, {:ok, placement}}

          {:error, %Unroutable{} = unroutable} ->
            {:cont, [{host, {:error, routing_error(unroutable)}} | failures]}

          {:error, denial} ->
            {:cont, [{host, {:error, denial}} | failures]}
        end
      end)

    case result do
      {:ok, placement} ->
        {:ok, placement}

      failures when is_list(failures) ->
        causes =
          failures
          |> Enum.reverse()
          |> Enum.map_join("\n", fn {host, {:error, denial}} ->
            "  #{host}: #{denial.message}"
          end)

        {:error,
         %{
           code: "host_unready",
           message:
             "no host in archetype #{archetype.name}'s where can run #{harness}:\n#{causes}"
         }}
    end
  end

  defp route_spawn_candidate(host, harness, %Model{} = model),
    do: ModelCatalog.route(host, harness, model, ModelCatalog)

  defp route_spawn_candidate(_host, _harness, _model),
    do: {:error, %{code: "model_unavailable", message: "model must be specified"}}

  defp create_spawn(config, db, call, caller, archetype, placement, overrides) do
    p = call.params
    max_live_sessions = Map.get(config, :max_live_sessions_per_user)
    host = placement.host
    defaults = defaults(config, db)
    harness = p[:harness] || archetype.defaults[:harness] || defaults.harness
    module = if is_atom(harness), do: Harness.module!(harness), else: Harness.parse!(harness)
    harness_string = module.wire_name()
    harness_atom = module.id()
    sessions = Org.list_for_user(db, caller.owner_user_id, false)

    # One mechanism decides the tier, here as at tune: an effort the caller did
    # not name is composed against what the chosen model actually offers.
    default_model = archetype.defaults[:model] || defaults.model

    identity_name = Placement.identity_name(config, archetype, overrides, harness_atom)

    prepared =
      case placement do
        %{model: %Model{} = model, routed: routed} ->
          {:ok, {model, routed}}

        %{host: ^host} ->
          model = spawn_model_selection(host, harness_string, p, default_model)

          with :ok <- validate_credential(config, harness_string, host),
               {:ok, routed} <-
                 validate_catalog_model(host, harness_string, model, from_default?(p)),
               :ok <- Spinup.ensure_ready(config, harness_atom, host, spinup_opts(config, db)),
               do: {:ok, {model, routed}}
      end

    # Placement resolved the host FIRST, so the ref is judged against the account
    # that will actually run the turn (#88) — not the gateway's.
    with {:ok, {model, routed}} <- prepared do
      input = %{
        display_name: p.display_name,
        kind: "custom",
        owner_user_id: caller.owner_user_id,
        origin: call.origin,
        spawned_by: caller.caller_session && caller.caller_session.session_key,
        handle: p[:handle],
        order_index: length(sessions),
        archetype: archetype.name,
        overrides: overrides,
        identity_name: identity_name,
        host: host,
        harness: harness_string,
        provider: routed.provider,
        model: model
      }

      session_result =
        DB.transaction(db, fn txn ->
          case Idempotency.get_in_txn(
                 txn,
                 caller.owner_user_id,
                 "spawn",
                 p.idempotency_key
               ) do
            nil ->
              if Archetypes.get(archetype.name) do
                if spawn_cap_reached_in_txn?(
                     txn,
                     caller.owner_user_id,
                     max_live_sessions
                   ) do
                  {:cap_exceeded, max_live_sessions}
                else
                  session = Org.create_in_txn(txn, input)

                  if p[:handle] do
                    Roles.create_in_txn!(
                      txn,
                      p.handle,
                      caller.owner_user_id,
                      session.session_key
                    )
                  end

                  Idempotency.put_in_txn(txn, %{
                    owner_user_id: caller.owner_user_id,
                    operation: "spawn",
                    idempotency_key: p.idempotency_key,
                    session_key: session.session_key
                  })

                  {:created, session}
                end
              else
                {:error, :unknown_archetype}
              end

            prior ->
              {:replayed, prior.session_key}
          end
        end)

      case session_result do
        {:ok, {:cap_exceeded, cap}} ->
          spawn_cap_exceeded(cap, caller.owner_user_id)

        {:ok, {:error, :unknown_archetype}} ->
          %{code: "unknown_archetype", message: "no such archetype: #{archetype.name}"}

        {:error, %Roles.TransactionError{error: error}} ->
          classified_denial("config_denied", error)

        {:error, error} ->
          raise error

        {:ok, {:created, session}} ->
          finish_spawn(db, call, caller, session)

        {:ok, {:replayed, session_key}} ->
          spawn_replay(db, session_key)
      end
    else
      {:error, denial} ->
        classified_denial("placement_denied", denial)
    end
  end

  defp spawn_cap_reached_in_txn?(_txn, _owner_user_id, cap)
       when not is_integer(cap) or cap <= 0,
       do: false

  defp spawn_cap_reached_in_txn?(txn, owner_user_id, cap) do
    [[active]] =
      Txn.q(
        txn,
        "SELECT COUNT(*) FROM sessions WHERE ownerUserId = ?1 AND state = 'active'",
        [owner_user_id]
      )

    active >= cap
  end

  defp spawn_cap_exceeded(cap, owner_user_id) do
    %{
      code: "cap_exceeded",
      message: "live-session cap (#{cap}) reached for #{owner_user_id}"
    }
  end

  defp spawn_model_selection(host, harness, params, default_model) do
    compose_model_selection(
      host,
      harness,
      default_model,
      resolve_selection(host, harness, params, default_model)
    )
  end

  defp classified_spawn_denial(denial, config_code, placement_code) do
    if denial[:code] in ["host_not_allowed", "unknown_host", "host_unready"],
      do: classified_denial(placement_code, denial),
      else: classified_denial(config_code, denial)
  end

  # A routability refusal keeps its OWN code and sentence. The list is asked of
  # the routability owner rather than spelled here, because a hand-kept list held
  # only the two codes the old mechanism produced — so a needs-an-effort refusal
  # (composition and validation read the catalog separately, and an async refresh
  # can land between them) came back re-labelled a PLACEMENT denial.
  defp classified_denial(code, denial) do
    if denial[:code] in Unroutable.codes() do
      Map.put(denial, :detail, denial)
    else
      %{code: code, message: denial[:message] || inspect(denial), detail: denial}
    end
  end

  defp finish_spawn(db, _call, caller, session) do
    stream = Payloads.stream_session(session)
    broadcast(db, caller.owner_user_id, Payloads.stream_created(stream))
    %{stream: stream, session_key: session.session_key, handle: session.handle}
  end

  defp spawn_replay(db, session_key) do
    %{stream: db |> Org.get(session_key) |> Payloads.stream_session(), session_key: session_key}
  end

  defp tune_result(config, db, call) do
    p = call.params

    cond do
      p[:setting] == "rename" and is_binary(p[:display_name]) ->
        session = Org.rename(db, call.session_key, p.display_name)
        stream = Payloads.stream_session(session)
        broadcast(db, session.owner_user_id, Payloads.stream_updated(stream))
        %{stream: stream}

      p[:setting] == "adopt" and is_boolean(p[:adopted]) ->
        session = Org.set_adopted(db, call.session_key, p.adopted)
        stream = Payloads.stream_session(session)
        broadcast(db, session.owner_user_id, Payloads.stream_updated(stream))
        %{ok: true}

      p[:setting] == "set_harness" and is_binary(p[:harness]) ->
        case runtime_tune_session(db, call) do
          {:error, denial} ->
            denial

          {:ok, session} ->
            harness = p.harness
            module = Enum.find(Harness.all(), &(&1.wire_name() == harness))

            cond do
              is_nil(module) ->
                tune_error("unknown_harness", "unknown harness: #{harness}")

              harness == session.harness ->
                tune_error(
                  "same_harness",
                  "#{harness} is already the resident harness; omit --harness for a model change"
                )

              true ->
                harness_atom = module.id()

                # A harness boundary never inherits the source model or effort.
                # The target catalog composes its own supported default effort.

                named = Model.named_fields(p)

                selection_base =
                  if Map.has_key?(named, :family),
                    do: nil,
                    else: %{module.default_model() | effort: nil}

                model =
                  compose_model_selection(
                    session.host,
                    harness,
                    nil,
                    resolve_selection(session.host, harness, p, selection_base)
                  )

                with :ok <- validate_credential(config, harness, session.host),
                     {:ok, routed} <-
                       validate_catalog_model(
                         session.host,
                         harness,
                         model,
                         from_default?(p)
                       ),
                     :ok <-
                       Spinup.ensure_ready(
                         config,
                         harness_atom,
                         session.host,
                         spinup_opts(config, db)
                       ) do
                  case at_tune_boundary(config, db, session.session_key, fn ->
                         run_session_mutation(session.session_key, fn ->
                           apply_harness_change(
                             config,
                             db,
                             call,
                             session,
                             harness,
                             harness_atom,
                             model,
                             routed.provider
                           )
                         end)
                       end) do
                    {:ok, result} -> result
                    {:error, :turn_in_progress} -> turn_in_progress_error()
                  end
                else
                  {:error, denial} -> normalize_tune_denial(denial)
                end
            end
        end

      p[:setting] == "set_host" and is_binary(p[:host]) ->
        case Org.get(db, call.session_key) do
          nil ->
            %{ok: false, code: "not_found"}

          session ->
            archetype = Archetypes.get(session.archetype) || Archetypes.builtin_default()

            case Placement.resolve(archetype, p.host, Placement.hosts(config.base_dir, db)) do
              {:error, denial} ->
                Map.put(denial, :ok, false)

              {:ok, host} ->
                harness = Harness.parse!(session.harness).id()

                case Spinup.ensure_ready(config, harness, host, spinup_opts(config, db)) do
                  {:error, denial} ->
                    denial

                  :ok ->
                    case Placement.move_workdir(config, call.session_key, session.host, host) do
                      :ok ->
                        case commit_host_rearm(config, db, session, host, 8) do
                          :ok -> %{ok: true, host: host}
                          {:error, message} -> %{code: "workspace_move_race", message: message}
                        end

                      {:error, message} ->
                        %{code: "workdir_move_failed", message: message}
                    end
                end
            end
        end

      p[:setting] == "remove_override" ->
        remove_override_result(config, db, call)

      p[:setting] == "set_model" and is_binary(p[:model]) ->
        case runtime_tune_session(db, call) do
          {:error, denial} ->
            denial

          {:ok, session} ->
            new_ref =
              compose_model_selection(
                session.host,
                session.harness,
                session.model,
                resolve_selection(session.host, session.harness, p, session.model)
              )

            apply_model_change(config, db, call, session, new_ref)
        end

      p[:setting] == "set_reasoning" and is_binary(p[:reasoningLevel]) ->
        case runtime_tune_session(db, call) do
          {:error, denial} ->
            denial

          {:ok, %{model: nil}} ->
            %{
              ok: false,
              code: "model_unknown",
              message: "reasoning cannot be changed while the current model is unknown"
            }

          {:ok, session} ->
            new_ref = %{session.model | effort: p.reasoningLevel}
            apply_model_change(config, db, call, session, new_ref)
        end

      p[:setting] == "set_fast_mode" and p[:fastMode] in ["on", "off"] ->
        case runtime_tune_session(db, call) do
          {:error, denial} ->
            denial

          {:ok, session} ->
            apply_fast_change(config, db, session, p.fastMode)
        end

      true ->
        %{ok: false, code: "unsupported", message: "tune does not support #{p[:setting]} yet"}
    end
  end

  defp runtime_tune_session(db, call) do
    session = Org.get(db, call.session_key)
    caller = resolve_caller(db, call.origin)

    case {session, caller} do
      {%{state: "active"} = active, %{owner_user_id: caller_owner}}
      when not is_nil(caller_owner) ->
        if caller_owner == active.owner_user_id or admin_origin?(db, call.origin),
          do: {:ok, active},
          else: {:error, tune_error("not_found", "session not found")}

      _ ->
        {:error, tune_error("not_found", "session not found")}
    end
  end

  defp tune_error(code, message), do: %{ok: false, code: code, message: message}

  defp turn_in_progress_error do
    tune_error(
      "turn_in_progress",
      "this session has a queued or running turn. Try again once the current turn finishes."
    )
  end

  defp normalize_tune_denial(%{code: code} = denial) do
    stable =
      case code do
        value
        when value in [
               "host_unready",
               "credential_unavailable",
               "catalog_unavailable",
               "model_unavailable"
             ] ->
          value

        "credential_invalid" ->
          "credential_unavailable"

        "model_catalog_unavailable" ->
          "catalog_unavailable"

        _ ->
          code
      end

    denial |> Map.put(:ok, false) |> Map.put(:code, stable)
  end

  defp runtime_success(db, session_key, engine_context, projection_committed, cleanup_status) do
    session = Org.get(db, session_key)

    %{
      ok: true,
      session_key: session_key,
      harness: session.harness,
      model: session.model && session.model.family,
      effort: session.model && session.model.effort,
      context: session.model && session.model.context,
      fast: nil,
      fast_status: "unknown",
      fast_persistence: "ephemeral",
      projection_committed: projection_committed,
      engine_context: engine_context,
      cleanup_status: cleanup_status
    }
    |> Map.merge(live_fast_projection(db, session))
  end

  defp live_fast_projection(db, session) do
    with %{harness_session_id: sid} <- Org.current_pointer(db, session.session_key),
         {:ok, adapter, _generation} <- resident_adapter(session),
         true <- Adapter.knows_session?(adapter, sid) do
      case Adapter.fast_status(adapter, sid) do
        {:ok, %{fast: fast}} -> %{fast: fast, fast_status: "known"}
        {:error, :fast_unsupported} -> %{fast: nil, fast_status: "unsupported"}
        _ -> %{fast: nil, fast_status: "unknown"}
      end
    else
      _ -> %{fast: nil, fast_status: "unknown"}
    end
  end

  defp resident_adapter(session) do
    coordinator = Process.whereis(Tightbeam.AdapterCoordinator)

    if is_pid(coordinator) do
      AdapterCoordinator.adapter_for(
        coordinator,
        {Harness.parse!(session.harness).id(), "shared", session.host}
      )
    else
      {:error, :adapter_unavailable}
    end
  end

  defp apply_fast_change(config, db, session, requested) do
    case at_tune_boundary(config, db, session.session_key, fn ->
           run_session_mutation(session.session_key, fn ->
             with %{harness_session_id: sid} <- Org.current_pointer(db, session.session_key),
                  {:ok, adapter, _generation} <- resident_adapter(session),
                  true <- Adapter.knows_session?(adapter, sid) do
               case Adapter.apply_fast(adapter, sid, requested) do
                 {:ok, %{fast: fast}} -> {:ok, adapter, sid, fast}
                 {:error, reason} -> {:error, adapter, sid, reason}
               end
             else
               _ -> {:error, nil, nil, :runtime_config_unknown}
             end
           end)
         end) do
      {:ok, {:ok, _adapter, _sid, fast}} ->
        runtime_success(db, session.session_key, "preserved", nil, "not_applicable")
        |> Map.merge(%{fast: fast, fast_status: "known"})

      {:ok, {:error, _adapter, _sid, :fast_unsupported}} ->
        tune_error("fast_unsupported", "the resident adapter did not advertise Fast")

      {:ok, {:error, _adapter, _sid, {:runtime_config_mismatch, actual}}} ->
        tune_error("runtime_config_mismatch", "the live Fast value differs from the request")
        |> Map.merge(%{fast: actual, fast_status: "known"})

      {:ok, {:error, adapter, sid, _reason}} ->
        if is_pid(adapter) and is_binary(sid), do: Adapter.forget_model_residency(adapter, sid)

        tune_error(
          "runtime_config_unknown",
          "Fast may have changed, but exact live readback failed"
        )
        |> Map.merge(%{fast: nil, fast_status: "unknown"})

      {:error, :turn_in_progress} ->
        turn_in_progress_error()
    end
  end

  # A selection that names a model but no effort (the ordinary case from
  # `setModel.options`, which offers models rather than tiers) takes the
  # session's current effort, falling back to "medium" or the first available
  # tier when the current one doesn't apply to the newly selected model. An
  # explicit effort is honoured as given.
  defp compose_model_selection(host, harness, current, %Model{effort: nil} = selected) do
    case efforts_for(host, harness, selected) do
      [] -> selected
      efforts -> %{selected | effort: pick_effort(efforts, current && current.effort)}
    end
  end

  defp compose_model_selection(_host, _harness, _current, %Model{} = selected), do: selected

  defp pick_effort(efforts, current_effort) do
    cond do
      current_effort in efforts -> current_effort
      "medium" in efforts -> "medium"
      true -> List.first(efforts)
    end
  end

  defp efforts_for(host, harness, %Model{} = selected) do
    case ModelCatalog.entry(host, harness, selected, ModelCatalog) do
      {nil, _health} -> []
      {entry, _health} -> entry.efforts
    end
  end

  # Model changes, adjudication rulings, and adapter heals for one session share
  # this high-tier lock. The supervised worker survives its wire caller, while
  # the lock keeps each DB phase and Adapter phase ordered without nesting them.
  defp run_session_mutation(session_key, fun) do
    result =
      Tightbeam.TurnTaskSupervisor
      |> Task.Supervisor.async_nolink(fn ->
        try do
          {:returned, with_session_mutation_lock(session_key, fun)}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end
      end)
      |> Task.await(:infinity)

    case result do
      {:returned, value} -> value
      {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp with_session_mutation_lock(session_key, fun) do
    :global.trans({{__MODULE__, :session_mutation, session_key}, self()}, fun)
  end

  # Serialize the [re-pin the shared home -> session/new|load] window per ADAPTER
  # ({harness, host}). The adapter binds its offered model set by re-reading the
  # shared home at session/new|load, and the pin is now session-varying, so
  # without this lock two sessions with different models provisioning on one host
  # clobber each other's pin before the adapter reads it — reintroducing
  # accepted-then-dead as a race (asg_6508eff5). Session mutation locks are keyed
  # by session_key and lanes are one-per-session, so they do NOT cover this
  # cross-session shared resource. Only the create/resume-after-loss branches
  # take this lock; the resident-turn common path holds no pin and never blocks.
  defp with_home_pin_lock(harness, host, fun) do
    :global.trans({{__MODULE__, :home_pin, harness, host}, self()}, fun)
  end

  defp at_session_turn_boundary(config, session_key, fun) do
    LaneManager.ensure_lane_quiet(config[:lane_manager] || LaneManager, session_key)

    case Tightbeam.SessionLane.at_turn_boundary(session_key, fun) do
      {:ok, result} -> {:ok, result}
      boundary when boundary in [:busy, :no_lane] -> {:error, :turn_in_progress}
    end
  end

  defp at_tune_boundary(config, db, session_key, fun) do
    at_session_turn_boundary(config, session_key, fn ->
      case config[:on_tune_fence] do
        callback when is_function(callback, 0) -> callback.()
        _ -> :ok
      end

      if Ledger.pending_count(db, session_key) > 0,
        do: {:tune_refused, :turn_in_progress},
        else: fun.()
    end)
    |> case do
      {:ok, {:tune_refused, :turn_in_progress}} -> {:error, :turn_in_progress}
      result -> result
    end
  end

  defp apply_harness_change(
         config,
         db,
         call,
         session,
         harness,
         harness_atom,
         model,
         provider
       ) do
    deliver_opts = if config[:sh], do: [sh: config.sh], else: []
    destination = %{session | harness: harness, model: model, provider: provider}

    prepared =
      with_home_pin_lock(harness_atom, session.host, fn ->
        Placement.deliver_home(
          config,
          {harness_atom, "shared", session.host},
          Keyword.put(deliver_opts, :model, model)
        )

        with {:ok, adapter, _generation} <- resident_adapter(destination),
             revision = session.identity_revision || Identity.live_revision!(config.base_dir),
             snapshot = served_snapshot(config, destination, harness_atom, revision),
             cwd = Placement.holder_workdir(config, session) do
          case Adapter.new_candidate_session(
                 adapter,
                 model,
                 cwd,
                 mcp_servers_for_archetype(session.archetype),
                 snapshot.guidance
               ) do
            {:ok, sid} ->
              {:ok, adapter, sid}

            {:error, {:session_prepare_failed, reason, sid, cleanup}} ->
              {:candidate_prepare_failed, reason, sid, cleanup}

            {:error, reason} ->
              {:error, reason}
          end
        end
      end)

    case prepared do
      {:ok, destination_adapter, destination_sid} ->
        source_pointer = Org.current_pointer(db, session.session_key)

        committed =
          DB.transaction(db, fn txn ->
            {record_model, record_harness} = read_recorded_model(txn, session.session_key)

            case Org.swap_model_in_txn(
                   txn,
                   session.session_key,
                   {record_model, record_harness},
                   {model, harness, provider}
                 ) do
              {:ok, _} -> :ok
              {:duplicate, _} -> raise "harness changed before staged swap commit"
              :stale -> raise "harness mutation race inside serialized tune"
            end

            [[max_seq]] =
              Txn.q(
                txn,
                "SELECT COALESCE(MAX(seq), 0) FROM messages WHERE sessionKey = ?1",
                [call.session_key]
              )

            Org.set_cleared_through_in_txn(txn, call.session_key, max_seq)

            case Map.get(call, :on_swap_interlock) do
              fun when is_function(fun, 1) -> fun.(txn)
              _ -> :ok
            end

            {:appended, marker} =
              Projection.append_marker_in_txn(txn, call.session_key, %{
                kind: "harness-switch",
                from: describe_engine(session.harness, session.model),
                to: describe_engine(harness, model)
              })

            Org.append_pointer_in_txn(txn, call.session_key, destination_sid, "created")
            marker
          end)

        case committed do
          {:ok, marker} ->
            broadcast(
              db,
              session.owner_user_id,
              Payloads.stream_history_cleared(call.session_key)
            )

            publish_stored_message(db, call.session_key, marker)

            cleanup =
              close_source_runtime(db, session, source_pointer, call[:principal] || call.origin)

            runtime_success(db, call.session_key, "reset", true, cleanup.status)
            |> Map.merge(Map.drop(cleanup, [:status]))

          {:error, error} ->
            cleanup =
              close_runtime(
                db,
                destination_adapter,
                destination_sid,
                error,
                call[:principal] || call.origin
              )

            tune_error(
              "session_config_commit_failed",
              "the verified destination was not committed; the source runtime remains active"
            )
            |> Map.merge(%{cleanup_status: cleanup.status, source_active: true})
            |> Map.merge(Map.drop(cleanup, [:status]))
        end

      {:candidate_prepare_failed, reason, sid, cleanup} ->
        cleanup =
          report_candidate_cleanup(
            db,
            sid,
            reason,
            call[:principal] || call.origin,
            cleanup
          )

        tune_error(
          "model_apply_failed",
          "the destination harness did not accept and verify the requested runtime: #{apply_failure(reason)}"
        )
        |> Map.put(:cleanup_status, cleanup.status)
        |> Map.merge(Map.drop(cleanup, [:status]))

      {:error, reason} ->
        tune_error(
          "model_apply_failed",
          "the destination harness did not accept and verify the requested runtime: #{apply_failure(reason)}"
        )
    end
  end

  defp report_candidate_cleanup(_db, _sid, _cause, _principal, %{status: "verified"}),
    do: %{status: "verified"}

  defp report_candidate_cleanup(db, sid, cause, principal, %{
         status: "unverified",
         reason: close_reason
       }) do
    cleanup_unverified(db, sid, {cause, close_reason}, principal)
  end

  defp close_source_runtime(_db, _session, nil, _principal), do: %{status: "verified"}

  defp close_source_runtime(db, session, pointer, principal) do
    case resident_adapter(session) do
      {:ok, adapter, _generation} ->
        close_runtime(db, adapter, pointer.harness_session_id, :superseded, principal)

      {:error, reason} ->
        cleanup_unverified(db, pointer.harness_session_id, reason, principal)
    end
  end

  defp close_runtime(db, adapter, sid, cause, principal) do
    case Adapter.close_session(adapter, sid) do
      :ok -> %{status: "verified"}
      {:error, reason} -> cleanup_unverified(db, sid, {cause, reason}, principal)
    end
  end

  defp cleanup_unverified(db, sid, cause, principal) do
    detail =
      JSON.encode!(%{
        runtimeId: sid,
        cause: apply_failure(cause),
        principal: inspect(principal)
      })

    event =
      case DB.transaction(db, fn txn ->
             EventLog.lifecycle_in_txn(txn, "runtime_cleanup_unverified", sid, detail)
             [[id]] = Txn.q(txn, "SELECT last_insert_rowid()")
             id
           end) do
        {:ok, event_id} ->
          %{lifecycle_event_id: event_id}

        {:error, error} ->
          Logger.error(
            "runtime cleanup for #{sid} was unverified and its lifecycle event failed: #{inspect(error)}"
          )

          %{}
      end

    %{
      status: "unverified",
      warning: "runtime close could not be verified"
    }
    |> Map.merge(event)
  end

  # A live model-switch on a RESIDENT session used to hit set_config_option, which
  # cannot re-read the projected home, so the harness refused any model its offered set
  # did not already hold (mike's opus-5 picker-pain) and the raw refusal reached the
  # client as `inspect(reason)` term soup. The fix (apply_tuned_model's resident
  # branch) forks the conversation, resolves the requested canonical model
  # through that fork's offered alias vocabulary, and verifies the readback
  # before projection -- but that move must never land mid-turn, so it runs at
  # the turn boundary. Ordering is
  # `at_turn_boundary` OUTER, `run_session_mutation` INNER: the lane IS the
  # serialization, and this is the only deadlock-safe nesting -- mutation-outer would
  # wedge a reload that waits on the lane while the lane's bounce waits on the mutation
  # lock (see repoint_main_session, the same shape). `ensure_lane_quiet` first so
  # :no_lane can only mean the lane died in the gap, which we treat as busy: retry.
  defp apply_model_change(config, db, call, session, new_ref) do
    with {:ok, routed} <- validate_catalog_model(session.host, session.harness, new_ref, false) do
      boundary =
        at_tune_boundary(config, db, session.session_key, fn ->
          run_session_mutation(session.session_key, fn ->
            apply_tuned_model(
              config,
              db,
              session,
              new_ref,
              routed.provider,
              call[:principal] || call.origin
            )
          end)
        end)

      case boundary do
        {:ok, :ok} ->
          runtime_success(db, session.session_key, "preserved", true, "not_applicable")

        {:ok, {:runtime_projection_failed, %Model{} = actual}} ->
          tune_error(
            "runtime_projection_failed",
            "the verified runtime is active, but Tightbeam could not store its projection"
          )
          |> Map.merge(runtime_actual(actual))
          |> Map.put(:projection_committed, false)

        {:ok, {:error, {:runtime_config_mismatch, %Model{} = actual}}} ->
          case project_verified_mismatch(db, session, actual, routed.provider) do
            :ok ->
              tune_error(
                "runtime_config_mismatch",
                "the verified active runtime differs from the requested configuration"
              )
              |> Map.merge(runtime_actual(actual))
              |> Map.put(:projection_committed, true)

            {:error, _reason} ->
              tune_error(
                "runtime_projection_failed",
                "the verified active runtime differs from the request and its projection could not be stored"
              )
              |> Map.merge(runtime_actual(actual))
              |> Map.put(:projection_committed, false)
          end

        {:ok, {:error, {:runtime_config_unknown, _reason}}} ->
          tune_error(
            "runtime_config_unknown",
            "the runtime may have changed, but exact live readback failed"
          )

        {:ok, {:error, {:session_config_commit_failed, _reason}}} ->
          tune_error(
            "session_config_commit_failed",
            "the verified replacement could not be committed; the prior runtime remains active"
          )

        # A real fault from the switch (adapter down, context move could not complete) -- NOT
        # the old frozen-offered-set refusal, which no longer exists. `apply_failure`
        # prefers the harness's own message and never emits a raw term as a sentence.
        {:ok, {:error, reason}} ->
          %{
            ok: false,
            code: "model_apply_failed",
            message:
              "could not switch this session to #{Model.describe(new_ref)}: " <>
                "#{apply_failure(reason)} (the session could not prepare the new model " <>
                "for its next turn)"
          }

        # Busy = a turn is in flight; the switch cannot land mid-turn, so the change
        # was NOT applied. The honest remedy after this fix is to retry at the
        # boundary -- never "start a new session" (the live switch replaces that old escape),
        # and never a false intake/validation claim (the intake gate is a different axis).
        {:error, :turn_in_progress} ->
          turn_in_progress_error()
      end
    else
      {:error, denial} -> normalize_tune_denial(denial)
    end
  end

  defp runtime_actual(%Model{} = model) do
    %{
      model: model.family,
      effort: model.effort,
      context: model.context,
      engine_context: "preserved"
    }
  end

  defp project_verified_mismatch(db, session, actual, provider) do
    try do
      _ = Org.set_model(db, session.session_key, actual, provider)
      :ok
    rescue
      error -> {:error, error}
    end
  end

  defp apply_tuned_model(config, db, session, new_ref, provider, principal) do
    case Org.current_pointer(db, session.session_key) do
      nil ->
        prepare_initial_tuned_model(config, db, session, new_ref, provider, principal)

      pointer ->
        coordinator = Process.whereis(Tightbeam.AdapterCoordinator)
        harness = Harness.parse!(session.harness).id()

        with true <- is_pid(coordinator),
             {:ok, adapter, _generation} <-
               AdapterCoordinator.adapter_for(
                 coordinator,
                 {harness, "shared", session.host}
               ) do
          case Adapter.knows_session?(adapter, pointer.harness_session_id) do
            # RESIDENT: Claude bound its offered-model set when it created this
            # session. The adapter moves the conversation to a fresh fork,
            # chooses only an alias that fork actually advertises, and returns
            # success only after the harness reads that alias back. Harnesses
            # with a live model set update in place. The caller holds the turn
            # boundary, so no switch can land mid-turn. The old Claude session
            # remains resident until the verified model and replacement
            # pointer commit together below.
            true ->
              case Adapter.current_model(adapter, pointer.harness_session_id) do
                {:ok, ^new_ref} ->
                  project_tuned_model(
                    db,
                    session,
                    adapter,
                    pointer.harness_session_id,
                    pointer.harness_session_id,
                    new_ref,
                    provider
                  )

                _not_exact ->
                  cwd = Placement.holder_workdir(config, session)
                  revision = session.identity_revision || Identity.live_revision!(config.base_dir)
                  snapshot = served_snapshot(config, session, harness, revision)

                  with_home_pin_lock(harness, session.host, fn ->
                    pin_home_to_session_model(config, Map.put(session, :model, new_ref), harness)

                    with {:ok, switched_sid} <-
                           AdapterCoordinator.with_load_slot(coordinator, session.host, fn ->
                             Adapter.switch_model_session(
                               adapter,
                               pointer.harness_session_id,
                               new_ref,
                               cwd,
                               mcp_servers_for_archetype(session.archetype),
                               snapshot.guidance
                             )
                           end) do
                      project_tuned_model(
                        db,
                        session,
                        adapter,
                        pointer.harness_session_id,
                        switched_sid,
                        new_ref,
                        provider
                      )
                    end
                  end)
              end

            false ->
              cwd = Placement.holder_workdir(config, session)
              revision = session.identity_revision || Identity.live_revision!(config.base_dir)
              snapshot = served_snapshot(config, session, harness, revision)

              with_home_pin_lock(harness, session.host, fn ->
                pin_home_to_session_model(config, Map.put(session, :model, new_ref), harness)

                with {:ok, ^new_ref} <-
                       AdapterCoordinator.with_load_slot(coordinator, session.host, fn ->
                         Adapter.load_session(
                           adapter,
                           pointer.harness_session_id,
                           new_ref,
                           cwd,
                           mcp_servers_for_archetype(session.archetype),
                           snapshot.guidance
                         )
                       end) do
                  project_tuned_model(
                    db,
                    session,
                    adapter,
                    pointer.harness_session_id,
                    pointer.harness_session_id,
                    new_ref,
                    provider
                  )
                end
              end)

            {:error, _reason} = error ->
              error
          end
        else
          false -> {:error, :adapter_unavailable}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # A session with no harness pointer has no live runtime whose acceptance can
  # be inferred from the stored projection. Prepare and verify the first
  # runtime before committing the model and pointer together.
  defp prepare_initial_tuned_model(config, db, session, new_ref, provider, principal) do
    harness = Harness.parse!(session.harness).id()
    destination = %{session | model: new_ref, provider: provider}

    prepared =
      with_home_pin_lock(harness, session.host, fn ->
        pin_home_to_session_model(config, destination, harness)

        with {:ok, adapter, _generation} <- resident_adapter(destination),
             revision = session.identity_revision || Identity.live_revision!(config.base_dir),
             snapshot = served_snapshot(config, destination, harness, revision),
             cwd = Placement.holder_workdir(config, session) do
          case Adapter.new_candidate_session(
                 adapter,
                 new_ref,
                 cwd,
                 mcp_servers_for_archetype(session.archetype),
                 snapshot.guidance
               ) do
            {:ok, sid} ->
              {:ok, adapter, sid}

            {:error, {:session_prepare_failed, reason, sid, cleanup}} ->
              {:candidate_prepare_failed, reason, sid, cleanup}

            {:error, reason} ->
              {:error, reason}
          end
        end
      end)

    case prepared do
      {:ok, adapter, sid} ->
        case project_initial_tuned_model(db, session, sid, new_ref, provider) do
          {:ok, marker} ->
            publish_stored_message(db, session.session_key, marker)
            :ok

          :duplicate ->
            :ok

          {:error, error} ->
            _cleanup = close_runtime(db, adapter, sid, error, principal)
            {:error, {:session_config_commit_failed, error}}
        end

      {:candidate_prepare_failed, reason, sid, cleanup} ->
        _cleanup = report_candidate_cleanup(db, sid, reason, principal, cleanup)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp project_initial_tuned_model(db, session, sid, new_ref, provider) do
    case DB.transaction(db, fn txn ->
           {record_model, record_harness} = read_recorded_model(txn, session.session_key)

           case Org.swap_model_in_txn(
                  txn,
                  session.session_key,
                  {record_model, record_harness},
                  {new_ref, record_harness, provider}
                ) do
             {:ok, _updated} ->
               Org.append_pointer_in_txn(txn, session.session_key, sid, "created")

               {:appended, marker} =
                 Projection.append_marker_in_txn(txn, session.session_key, %{
                   kind: "model-retune",
                   from: Model.describe(session.model),
                   to: Model.describe(new_ref)
                 })

               {:changed, marker}

             {:duplicate, _current} ->
               Org.append_pointer_in_txn(txn, session.session_key, sid, "created")
               :duplicate

             :stale ->
               raise("model mutation race inside serialized tune")
           end
         end) do
      {:ok, {:changed, marker}} -> {:ok, marker}
      {:ok, :duplicate} -> :duplicate
      {:error, error} -> {:error, error}
    end
  end

  # The recorded selection, read back inside the serialized mutation. The row
  # holds FIELDS, so this is where they become an identity again — never a
  # packed column read straight into a comparison.
  defp read_recorded_model(txn, session_key) do
    [[family, effort, context, harness]] =
      Txn.q(
        txn,
        """
        SELECT model, thinkingLevel, modelContext, harness
        FROM sessions WHERE sessionKey=?1
        """,
        [session_key]
      )

    {family && %Model{family: family, effort: effort, context: context}, harness}
  end

  defp project_tuned_model(
         db,
         session,
         adapter,
         prior_sid,
         switched_sid,
         new_ref,
         provider
       ) do
    result =
      DB.transaction(db, fn txn ->
        {record_model, record_harness} = read_recorded_model(txn, session.session_key)

        case Org.swap_model_in_txn(
               txn,
               session.session_key,
               {record_model, record_harness},
               {new_ref, record_harness, provider}
             ) do
          {:ok, _updated} ->
            if switched_sid != prior_sid do
              Org.append_pointer_in_txn(txn, session.session_key, switched_sid, "loaded")
            end

            {:appended, marker} =
              Projection.append_marker_in_txn(txn, session.session_key, %{
                kind: "model-retune",
                from: Model.describe(session.model),
                to: Model.describe(new_ref)
              })

            {:changed, marker}

          {:duplicate, _current} ->
            if switched_sid != prior_sid do
              Org.append_pointer_in_txn(txn, session.session_key, switched_sid, "loaded")
            end

            :duplicate

          :stale ->
            raise("model mutation race inside serialized tune")
        end
      end)

    case result do
      {:ok, {:changed, marker}} ->
        close_superseded_model_session(adapter, session.session_key, prior_sid, switched_sid)
        publish_stored_message(db, session.session_key, marker)
        :ok

      {:ok, :duplicate} ->
        close_superseded_model_session(adapter, session.session_key, prior_sid, switched_sid)
        :ok

      {:error, error} ->
        if switched_sid == prior_sid do
          {:runtime_projection_failed, new_ref}
        else
          reject_tuned_session(adapter, prior_sid, switched_sid)
          {:error, {:session_config_commit_failed, error}}
        end
    end
  end

  defp close_superseded_model_session(_adapter, _session_key, sid, sid), do: :ok

  defp close_superseded_model_session(adapter, session_key, prior_sid, _switched_sid) do
    case Adapter.close_session(adapter, prior_sid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "model switch committed for #{session_key}, but superseded session #{prior_sid} " <>
            "could not close: #{inspect(reason)}"
        )
    end
  end

  defp reject_tuned_session(adapter, sid, sid),
    do: :ok = Adapter.forget_model_residency(adapter, sid)

  defp reject_tuned_session(adapter, _prior_sid, switched_sid) do
    case Adapter.close_session(adapter, switched_sid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "model switch database projection failed, and replacement session #{switched_sid} " <>
            "could not close: #{inspect(reason)}"
        )
    end
  end

  # A RELAY, not a second opinion. `ModelCatalog.route/3` owns which selections
  # are routable and why, so every refusal here names the harness, the HOST that
  # owns the catalog, and the repair on that host — including the lessons this
  # copy used to hold alone (the client_version filter) and the one it used to
  # get wrong (a missing tier reported as a missing model).
  #
  # It returns the ROUTED answer, so its callers no longer look the entry up a
  # second time to learn the provider.
  defp validate_catalog_model(host, harness, model, configured_default?) do
    with %Model{} <- model,
         {:ok, routed} <- ModelCatalog.route(host, harness, model, ModelCatalog) do
      {:ok, routed}
    else
      {:error, %Unroutable{} = unroutable} ->
        warn_dead_default(host, harness, model, configured_default?)
        {:error, routing_error(unroutable)}

      _not_a_model ->
        warn_dead_default(host, harness, model, configured_default?)
        {:error, %{code: "model_unavailable", message: "model must be specified"}}
    end
  end

  defp routing_error(%Unroutable{} = unroutable) do
    %{code: Unroutable.code(unroutable), message: Unroutable.message(unroutable)}
  end

  defp validate_credential(config, harness, machine) do
    provider = Harness.parse!(harness).credential_provider()
    status = credential_status(config, provider, machine)

    case status do
      :onboarded ->
        :ok

      {:needs_onboarding, reason} ->
        {:error,
         %{
           code: "needs_onboarding",
           message: credential_remedy(reason, provider, machine)
         }}
    end
  end

  # Single source of truth: a credential-failure `reason` -> the actionable remedy
  # sentence. Every credential-refusal seam (spawn `validate_credential`, the turn
  # `unonboarded_refusal`, and `error_sentence` flattening) names through this one
  # function, so the r4.2 discipline lives in exactly one place: onboarding is named
  # ONLY for reasons onboarding can actually fix (missing/expired/revoked). A transient
  # server outage says retry (NOT onboard), an unsupported plan says onboarding won't help.
  # This replaces the two divergent seams the incident exposed: the spawn seam OVER-named
  # (every reason -> "run onboard") and the turn seam UNDER-named (only `:missing`), so an
  # expired/transient turn got a raw error or a misdirect instead of an actionable remedy.
  #
  # `:in_progress` has NO bespoke remedy here (it flattens via the catch-all). The PO's
  # refinement — NAME the live ceremony (origin session + started-at), consistent with
  # outcome 2 — needs the lease's `origin_session`/`started_at`, which do NOT exist at this
  # base (the lease is `%{id, path, expires_at}`); those fields are outcome 2's deliverable.
  # So the bespoke `:in_progress` remedy is DEFERRED to outcome 2, which owns that data; the
  # interim flatten still removes the old false "run onboard" (the r4.2 fix). This mirrors the
  # :prompt-401 deferral to Card 2 — defer the precise naming to the card that owns the signal.
  defp credential_remedy(reason, provider, host) do
    onboard = "Run on #{host}: tightbeam onboard #{provider} --as-user <userId>"

    case reason do
      :missing ->
        "Tightbeam has no credential for #{provider} on #{host}. It does not use or " <>
          "import your normal CLI login; Tightbeam keeps its own. #{onboard}"

      :expired ->
        "Tightbeam's credential for #{provider} on #{host} has expired. #{onboard}"

      :revoked ->
        "Tightbeam's credential for #{provider} on #{host} is no longer valid " <>
          "(revoked, or rejected in flight). #{onboard}"

      :credential_server_unavailable ->
        "Tightbeam could not reach the credential server for #{provider} on #{host}. " <>
          "This is transient — retry shortly. Do not re-onboard; the credential may be fine."

      :unsupported ->
        unsupported_credential_message(provider, host)

      {:unsupported, _detail} ->
        unsupported_credential_message(provider, host)

      other ->
        "Tightbeam cannot use the credential for #{provider} on #{host}: " <>
          "#{credential_reason_phrase(other)}."
    end
  end

  defp unsupported_credential_message(provider, host) do
    "The #{provider} account on #{host} is not usable here (no supported subscription). " <>
      "Onboarding will not help; the account needs a supported plan."
  end

  # A bounded, human phrase for an unexpected reason — never a raw `inspect` of a large
  # ACP error map in an operator's chat (G3). Atoms and short tuples read plainly.
  defp credential_reason_phrase(reason) when is_atom(reason), do: to_string(reason)

  defp credential_reason_phrase(reason) do
    reason |> inspect() |> String.slice(0, 200)
  end

  # A credential failure at the turn seam, named through the one shared remedy function.
  # Read the credential health for {host, harness}; when it AFFIRMATIVELY reports a
  # needs-onboarding reason (missing/expired/revoked/unsupported/in_progress), name the
  # per-reason remedy — at every stage, including :prompt. We do NOT name
  # `:credential_server_unavailable`: it means "could not ASK" (a transient), and at a turn
  # failure the real fault is usually the adapter/host; overriding it with a bogus credential
  # sentence is the could-not-ask misroute this codebase keeps punishing (29 adapter-heal
  # arenas run without a Credentials server). The transient IS named at the spawn seam, where
  # the check is deliberate — that seam policy difference is intentional; the wording is shared.
  #
  # HELD (pending the PO's a-vs-b scope ruling): a credential that expires and 401s IN FLIGHT
  # fails at :prompt with catalog health still `:fresh` — real expiry is storage-blind, so no
  # health signal names it; only the :prompt ACP auth-error SHAPE does. That own-detection
  # (Card-1 fragile string-match vs Card-2 401-observed health) is deferred; it lands on top of
  # this seam without changing it (preserved on branch o6-prompt401-naming-built). Until then,
  # G3 flatten (error_sentence) still ensures such a turn renders human prose, never a raw
  # inspected map.
  defp turn_credential_refusal(session) do
    health =
      try do
        {_entries, health} =
          Tightbeam.ModelCatalog.get(session.host, session.harness, Tightbeam.ModelCatalog)

        health
      catch
        # No catalog server is a boot shape, not evidence of anything.
        :exit, _ -> :unavailable_server
      end

    case health do
      {:unavailable, {:needs_onboarding, reason}} ->
        if affirmative_credential_reason?(reason) do
          provider = Harness.parse!(session.harness).credential_provider()
          {:refused, credential_remedy(reason, provider, session.host)}
        else
          :not_applicable
        end

      _ ->
        :not_applicable
    end
  end

  # Reasons that affirmatively say "act on the credential" (vs `:credential_server_unavailable`,
  # a couldn't-ask transient that must not override an adapter/host fault).
  defp affirmative_credential_reason?(:missing), do: true
  defp affirmative_credential_reason?(:expired), do: true
  defp affirmative_credential_reason?(:revoked), do: true
  defp affirmative_credential_reason?(:unsupported), do: true
  defp affirmative_credential_reason?({:unsupported, _}), do: true
  defp affirmative_credential_reason?(_), do: false

  # Extract an error map's human-readable text (message + details) for G3 flattening — never a
  # raw `inspect` of a large ACP error map in an operator's chat.
  defp error_map_text(reason) when is_binary(reason), do: reason

  defp error_map_text(reason) when is_map(reason) do
    message = map_get_any(reason, ["message", :message]) || ""
    data = map_get_any(reason, ["data", :data]) || %{}

    details =
      if is_map(data), do: map_get_any(data, ["details", :details]) || "", else: to_string(data)

    String.trim("#{message} #{details}")
  end

  defp error_map_text(reason), do: inspect(reason)

  defp map_get_any(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp credential_status(%{credential_status: status}, provider, _machine)
       when is_function(status, 1),
       do: status.(provider)

  defp credential_status(%{credential_status: status}, provider, machine)
       when is_function(status, 2),
       do: status.(provider, machine)

  defp credential_status(_config, provider, machine) do
    server = Tightbeam.Credentials.server(machine)

    case GenServer.whereis(server) do
      nil -> {:needs_onboarding, :credential_server_unavailable}
      _pid -> Tightbeam.Credentials.status(provider, server)
    end
  end

  defp stop_provider_runtime(provider, machine) do
    provider
    |> harnesses_for_provider()
    |> Enum.reduce(:ok, fn module, result ->
      close_result =
        AdapterCoordinator.close_adapter(
          Tightbeam.AdapterCoordinator,
          {module.id(), "shared", machine}
        )

      case {result, close_result} do
        {:ok, :ok} -> :ok
        {:ok, {:error, _reason} = error} -> error
        {{:error, _reason} = error, _later_result} -> error
      end
    end)
  end

  defp capture_credential_sessions(db, provider, machine) do
    harnesses = provider |> harnesses_for_provider() |> MapSet.new(& &1.wire_name())

    %{
      provider: provider,
      machine: machine,
      sessions:
        db
        |> Org.list_for_user("", true)
        |> Enum.filter(&(MapSet.member?(harnesses, &1.harness) and &1.host == machine))
    }
  end

  defp publish_credential_sessions(
         db,
         %{provider: provider, machine: machine, sessions: sessions},
         transition
       ) do
    Enum.each(sessions, fn session ->
      best_effort(fn ->
        case Projection.append(db, %{
               session_key: session.session_key,
               role: "user",
               content: credential_transition_message(provider, machine, transition),
               sender: "process:tightbeam"
             }) do
          {:appended, message} -> publish_message(db, session.session_key, message)
          _ -> :ok
        end
      end)

      best_effort(fn ->
        stream = session |> Payloads.stream_session()
        broadcast(db, session.owner_user_id, Payloads.stream_updated(stream))
      end)
    end)
  end

  defp credential_transition_message(provider, machine, :terminal) do
    "#{provider} credential on #{machine} is terminal; this session is parked pending re-onboarding."
  end

  defp credential_transition_message(provider, machine, :onboarded) do
    "#{provider} credential on #{machine} was re-onboarded; this session may resume."
  end

  defp start_provider_runtime(provider, kind, machine) do
    {started, failed} =
      Enum.reduce(harnesses_for_provider(provider), {[], []}, fn module, {started, failed} ->
        key = {module.id(), "shared", machine}

        case AdapterCoordinator.adapter_for(
               Tightbeam.AdapterCoordinator,
               key,
               credential_kind: kind
             ) do
          {:ok, _pid, _generation} ->
            {[module.wire_name() | started], failed}

          {:error, reason} ->
            {started, [%{harness: module.wire_name(), reason: reason} | failed]}
        end
      end)

    case Enum.reverse(failed) do
      [] ->
        :ok

      failed ->
        {:error,
         {:provider_runtime_start_failed, %{started: Enum.reverse(started), failed: failed}}}
    end
  end

  defp harnesses_for_provider(provider),
    do: Enum.filter(Harness.all(), &(&1.credential_provider() == provider))

  # "The selection came ENTIRELY from configured policy" — which is the only
  # case where blaming the configured default is true. Keyed on `p[:model]`
  # alone, an effort-only selection with a bad effort was reported as a broken
  # default: a refusal naming the wrong cause, and the operator sent to change
  # a setting that was never the problem.
  defp from_default?(params), do: Model.named_fields(params) == %{}

  defp warn_dead_default(_host, _harness, _model, false), do: :ok

  defp warn_dead_default(host, harness, model, true) do
    Logger.warning(
      "configured default model #{inspect(Model.describe(model))} is not currently offered by " <>
        "#{harness} on host #{host}"
    )
  end

  defp remove_override_result(config, db, call) do
    p = call.params

    with %{} = session <- Org.get(db, call.session_key),
         :ok <- session_mutation_allowed(db, call.origin, session),
         {:ok, overrides, removed} <- remove_override_value(session.overrides, p) do
      base = Archetypes.get(session.archetype) || Archetypes.builtin_default()
      harness = Harness.parse!(session.harness).id()

      identity_name =
        Placement.identity_name(
          config,
          base,
          overrides,
          harness,
          session.identity_name
        )

      carry_pinned_overrides(config.base_dir, session.identity_name, identity_name, overrides)
      updated = Org.set_identity(db, session.session_key, overrides, identity_name)

      if identity_name != session.identity_name and
           not Org.identity_name_exists?(db, session.identity_name) do
        File.rm_rf!(Path.join([config.base_dir, "identity", "pinned", session.identity_name]))
      end

      append_session_restart_marker(
        db,
        updated.session_key,
        session.identity_name,
        updated.identity_name
      )

      prompt = "Your override \"#{removed}\" was removed by the operator; disregard it."
      notify_session(config, db, session.session_key, prompt)

      %{ok: true, identity_name: identity_name, overrides: overrides}
    else
      nil -> %{ok: false, code: "not_found"}
      {:error, error} -> error
    end
  end

  defp remove_override_value(nil, _params) do
    {:error, %{code: "invalid_overrides", message: "session has no overrides"}}
  end

  defp remove_override_value(overrides, %{skill: skill}) when is_binary(skill) do
    skills = Map.get(overrides, "skills_add", [])

    if skill in skills do
      updated = put_or_drop(overrides, "skills_add", List.delete(skills, skill))
      {:ok, empty_override_to_nil(updated), skill}
    else
      {:error,
       %{code: "invalid_overrides", message: "session override does not elect skill #{skill}"}}
    end
  end

  defp remove_override_value(overrides, %{guidance: true}) do
    if Map.has_key?(overrides, "guidance_extra") do
      {:ok, overrides |> Map.delete("guidance_extra") |> empty_override_to_nil(), "guidance"}
    else
      {:error, %{code: "invalid_overrides", message: "session override has no guidance_extra"}}
    end
  end

  defp remove_override_value(_overrides, _params) do
    {:error,
     %{
       code: "invalid_overrides",
       message: "remove_override requires skill: <name> or guidance: true"
     }}
  end

  defp put_or_drop(map, key, []), do: Map.delete(map, key)
  defp put_or_drop(map, key, value), do: Map.put(map, key, value)
  defp empty_override_to_nil(map) when map_size(map) == 0, do: nil
  defp empty_override_to_nil(map), do: map

  defp spinup_opts(config, db) do
    [db: db]
    |> maybe_put_opt(:sh, config[:sh])
    |> maybe_put_opt(:patch_adapter, config[:patch_adapter])
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # The agent ELECTS its reply's attention tier, during its own turn. An agent
  # elects between normal (0, what electing nothing gets) and high (1); `low`
  # (-1) exists in the same vocabulary but is the substrate's own election over
  # its ambient notices, not something a reply asks for. The substrate derives
  # nothing here — there is no kind-to-tier mapping and no anti-inflation rule —
  # and what a client DOES with the tier is the client's business.
  #
  # The target turn is never named by the caller: it is the caller session's
  # running turn, which the lane serializes to exactly one.
  defp attend_result(db, call) do
    case call[:principal] do
      {:session, session_key} ->
        tier = if call.params[:high] == true, do: 1, else: 0

        {:ok, result} =
          DB.transaction(db, fn txn ->
            case running_turn_seq_in_txn(txn, session_key) do
              nil ->
                %{code: "no_running_turn", message: "attend elects during your own turn"}

              seq ->
                DB.Txn.q(txn, "UPDATE turns SET replyAttention = ?2 WHERE seq = ?1", [seq, tier])
                %{turn_seq: seq, attention: Projection.attention_name(tier)}
            end
          end)

        result

      _ ->
        %{code: "invalid", message: "attend requires a session caller"}
    end
  end

  defp running_turn_seq_in_txn(txn, session_key) do
    case DB.Txn.q(
           txn,
           "SELECT seq FROM turns WHERE sessionKey = ?1 AND status = 'running' LIMIT 1",
           [session_key]
         ) do
      [[seq]] -> seq
      [] -> nil
    end
  end

  defp elected_attention(db, turn_seq) do
    {:ok, [[tier]]} =
      DB.query(db, "SELECT replyAttention FROM turns WHERE seq = ?1", [turn_seq])

    tier
  end

  defp retire_result(config, db, call) do
    p = call.params
    # Resolve the caller's owner, do not string-strip the origin: an agent's
    # origin is `agent:<role>`, which stripping leaves intact, so it matched no
    # ownerUserId and every agent got `not_found` — including for sessions its own
    # owner controls, which the guidance we ship tells agents to retire.
    # `resolve_caller/2` handles all three origin classes and yields a nil owner
    # for a process, which cannot match a NOT NULL ownerUserId, so unknown and
    # process callers keep getting `not_found`.
    owner = resolve_caller(db, call.origin)[:owner_user_id]
    prior = if p[:idempotency_key], do: Idempotency.get(db, owner, "retire", p.idempotency_key)

    cond do
      prior && prior.session_key == call.session_key ->
        %{
          deleted_session_key: call.session_key,
          retired_session_keys: retired_subtree_keys(db, call.session_key),
          deferred: []
        }

      true ->
        case Org.get(db, call.session_key) do
          # A Main is every role's fallback and every user reference's
          # resolution target: retiring one would open the void invariant 1
          # forbids. Mains are permanent by construction, not by vigilance.
          %{owner_user_id: ^owner, is_built_in: true} ->
            %{
              code: "denied",
              message:
                "main sessions are permanent — they are the fallback for roles and user references"
            }

          %{owner_user_id: ^owner} = session ->
            if session.state == "active" do
              {:ok, result} =
                DB.transaction(db, fn txn ->
                  result =
                    retire_cascade_in_txn(
                      txn,
                      session.session_key,
                      owner,
                      call.origin,
                      Map.fetch!(config, :wake_tick_ms),
                      "retired: session retired before execution"
                    )

                  if result.retired != [] and p[:idempotency_key] do
                    Idempotency.put_in_txn(txn, %{
                      owner_user_id: owner,
                      operation: "retire",
                      idempotency_key: p.idempotency_key,
                      session_key: session.session_key
                    })
                  end

                  result
                end)

              Enum.each(result.retired, fn retired ->
                broadcast(db, owner, Payloads.stream_deleted(retired.session_key))
                Map.get(config, :on_retired, fn _ -> :ok end).(retired.session_key)

                Enum.each(retired.assignments, fn assignment ->
                  emit_assignment_change(db, assignment.assignment_id, assignment.from_state)
                end)
              end)

              reap_retired_sessions(config, db, Enum.map(result.retired, & &1.session_key))

              %{
                deleted_session_key: session.session_key,
                retired_session_keys: Enum.map(result.retired, & &1.session_key),
                deferred: result.deferred
              }
            else
              %{deleted_session_key: session.session_key, retired_session_keys: [], deferred: []}
            end

          _ ->
            %{code: "not_found"}
        end
    end
  end

  defp critical_result(config, db, call) do
    with {:session, session_key} <- call[:principal],
         %{state: "active"} <- Org.get(db, session_key),
         duration when is_integer(duration) and duration > 0 <- call.params[:for_ms],
         reason when is_binary(reason) and reason != "" <- call.params[:reason] do
      hard_cap = Map.get(config, :critical_lease_hard_cap_ms, 14_400_000)
      lease = CriticalLeases.declare(db, session_key, duration, reason, hard_cap)

      %{
        session_key: session_key,
        reason: lease.reason,
        expires_at: lease.expires_at,
        hard_deadline: lease.hard_deadline
      }
    else
      nil -> %{code: "not_found"}
      _ -> %{code: "invalid", message: "critical requires a session caller, --for, and --reason"}
    end
  end

  defp retire_subtree_in_txn(txn, root_key) do
    rows =
      Txn.q(
        txn,
        "SELECT sessionKey, spawnedBy FROM sessions WHERE state='active' ORDER BY createdAt, sessionKey"
      )

    children = Enum.group_by(rows, &Enum.at(&1, 1))

    walk = fn walk, key ->
      descendants =
        children
        |> Map.get(key, [])
        |> Enum.flat_map(fn [child_key, _parent] -> walk.(walk, child_key) end)

      descendants ++ [%{session_key: key}]
    end

    walk.(walk, root_key)
  end

  defp retired_subtree_keys(db, root_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT sessionKey, spawnedBy, state FROM sessions ORDER BY createdAt, sessionKey"
      )

    children = Enum.group_by(rows, &Enum.at(&1, 1))

    walk = fn walk, key ->
      descendants =
        children
        |> Map.get(key, [])
        |> Enum.flat_map(fn [child_key, _parent, _state] -> walk.(walk, child_key) end)

      state =
        Enum.find_value(rows, fn
          [^key, _parent, row_state] -> row_state
          _ -> nil
        end)

      if state == "retired", do: descendants ++ [key], else: descendants
    end

    walk.(walk, root_key)
  end

  defp retire_cascade_in_txn(
         txn,
         root_key,
         owner,
         principal,
         supervision_interval_ms,
         drain_reason
       ) do
    # Invariant: this spawnedBy walk visits each active member of the target's
    # transitive subtree exactly once, parent-last. This is the lifecycle
    # seam's canonical subtree ordering; do not duplicate it.
    subtree = retire_subtree_in_txn(txn, root_key)
    now = System.system_time(:millisecond)

    leased =
      Enum.flat_map(subtree, fn member ->
        case CriticalLeases.active_in_txn(txn, member.session_key, now) do
          nil -> []
          lease -> [lease]
        end
      end)

    if leased == [] do
      retired =
        Enum.map(subtree, fn member ->
          assignments =
            retire_session_in_txn(
              txn,
              member.session_key,
              owner,
              principal,
              supervision_interval_ms,
              drain_reason
            )

          %{session_key: member.session_key, assignments: assignments}
        end)

      %{retired: retired, deferred: []}
    else
      deadline = Enum.max_by(leased, & &1.hard_deadline).hard_deadline

      deferred =
        Enum.map(subtree, fn member ->
          direct = Enum.find(leased, &(&1.session_key == member.session_key))

          if direct do
            schedule_retire_intent_in_txn(txn, root_key, member.session_key, owner, direct)
          end

          %{
            session_key: member.session_key,
            until: (direct && direct.hard_deadline) || deadline,
            reason: (direct && direct.reason) || "deferred by leased subtree"
          }
        end)

      %{retired: [], deferred: deferred}
    end
  end

  defp schedule_retire_intent_in_txn(txn, root_key, session_key, owner, lease) do
    wake_id = retire_intent_wake_id(root_key, session_key)

    case Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [wake_id]) do
      [] ->
        Wakes.schedule_in_txn(txn, %{
          wake_id: wake_id,
          session_key: session_key,
          origin: "user:#{owner}",
          prompt:
            "FINAL RETIRE INSTRUCTION: clean up critical section '#{lease.reason}'; retirement is deferred only until hard deadline #{lease.hard_deadline}.",
          due_at: lease.hard_deadline
        })

      [[1]] ->
        :ok
    end
  end

  defp retire_intent_wake_id(root_key, session_key) do
    digest = :crypto.hash(:sha256, root_key <> "\0" <> session_key) |> Base.encode16(case: :lower)
    "w_retire_" <> digest
  end

  defp retire_session_in_txn(
         txn,
         session_key,
         owner,
         principal,
         supervision_interval_ms,
         drain_reason
       ) do
    assignments = Assignments.interrupt_for_retire_in_txn(txn, session_key, owner, principal)
    Org.retire_in_txn(txn, session_key, principal, supervision_interval_ms)
    Ledger.drain_queued_for_retire_in_txn(txn, session_key, drain_reason)
    assignments
  end

  # Retire durability owns the ordering: every DB transition commits before
  # this seam touches a harness. Adapters are shared by key, so each retired
  # harness SID is closed independently and the adapter itself is closed only
  # when no active session still shares that key. Every operation is guarded:
  # an absent/dead adapter can never turn a committed retire into a failure.
  defp reap_retired_sessions(_config, _db, []), do: :ok

  defp reap_retired_sessions(config, db, session_keys) do
    coordinator = Map.get(config, :adapter_coordinator, Tightbeam.AdapterCoordinator)

    # Reap only what actually retired. Before durable process custody this was
    # a tautology — everything on this list had just flipped to `retired` in the
    # committed transaction — but a session whose managed process is unresolved
    # now stays `active` behind an open retirement fence (spec rev6 §B5). Its
    # workspace is exactly where `process-reconcile` looks for the evidence that
    # would resolve it, so archiving here would destroy the repair path for the
    # blocked row and leave the process unresolvable by construction.
    #
    # Read the durable state rather than trusting the caller's list: the list is
    # assembled before commit and the block is decided during it.
    session_keys = Enum.filter(session_keys, &retired?(db, &1))

    Enum.each(session_keys, &archive_retired_workspace(config, db, &1))

    session_keys
    |> Enum.flat_map(fn session_key ->
      with session when not is_nil(session) <- Org.get(db, session_key),
           %{harness_session_id: sid} <- Org.current_pointer(db, session_key) do
        [
          %{
            session_key: session_key,
            sid: sid,
            key: {Harness.parse!(session.harness).id(), "shared", session.host}
          }
        ]
      else
        _ -> []
      end
    end)
    |> Enum.group_by(& &1.key)
    |> Enum.each(fn {key, retired} -> reap_adapter_sessions(db, coordinator, key, retired) end)

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp retired?(db, session_key) do
    match?(%{state: "retired"}, Org.get(db, session_key))
  end

  defp archive_retired_workspace(config, db, session_key) do
    with session when not is_nil(session) <- Org.get(db, session_key) do
      host = Placement.hosts(config.base_dir, db)[session.host]

      # Remote workspaces are derivable but not locally accessible. Reap has
      # no remote workspace-removal mechanism, so v1 flips their rows only.
      workspace_path =
        if host && host.ssh == nil,
          do: Placement.workdir_path(config, session),
          else: nil

      Artifacts.archive_session(
        db,
        session_key,
        workspace_path,
        Path.join(config.base_dir, "archive")
      )
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp reap_adapter_sessions(db, coordinator, key, retired) do
    with {:ok, adapter, _generation} <- AdapterCoordinator.adapter_for(coordinator, key) do
      Enum.each(retired, fn %{sid: sid} -> _ = Adapter.close_session(adapter, sid) end)

      if live_session_on_adapter?(db, key) do
        Enum.each(retired, fn %{session_key: session_key} ->
          EventLog.lifecycle(
            db,
            "harness_context_resident",
            session_key,
            "harness context resident until adapter recycle"
          )
        end)
      else
        case AdapterCoordinator.close_adapter(coordinator, key) do
          :ok ->
            :ok

          {:error, reason} = error ->
            EventLog.lifecycle(db, "adapter_park_failed", inspect(key), inspect(reason))
            error
        end
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp live_session_on_adapter?(db, {harness, "shared", host}) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM sessions WHERE state='active' AND harness=?1 AND host=?2",
        [Atom.to_string(harness), host]
      )

    count > 0
  end

  defp describe_error(error) when is_exception(error), do: Exception.message(error)
  defp describe_error(error), do: inspect(error)

  defp describe_engine(harness, nil), do: "#{harness}"
  defp describe_engine(harness, model), do: "#{harness} (#{Model.describe(model)})"

  defp commit_host_rearm(_config, _db, _session, _host, 0),
    do: {:error, "holder assignments kept changing while the workspace moved"}

  defp commit_host_rearm(config, db, session, host, attempts) do
    prepared =
      EffortCheckin.prepare_holder_rearms(
        db,
        config,
        %{session | host: host}
      )

    case DB.transaction(db, fn txn ->
           [[current_host]] =
             Txn.q(txn, "SELECT host FROM sessions WHERE sessionKey=?1", [
               session.session_key
             ])

           cond do
             current_host != session.host ->
               :placement_changed

             not EffortCheckin.prepared_rearms_current?(
               txn,
               session.session_key,
               prepared
             ) ->
               :retry

             true ->
               Org.set_host_in_txn(txn, session.session_key, host)

               EffortCheckin.apply_prepared_rearms_in_txn(
                 txn,
                 config,
                 session.session_key,
                 prepared
               )

               :ok
           end
         end) do
      {:ok, :ok} ->
        :ok

      {:ok, :retry} ->
        commit_host_rearm(config, db, session, host, attempts - 1)

      {:ok, :placement_changed} ->
        {:error, "holder placement changed concurrently"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  # The built-in Main stream is seeded on the gateway's own host (see
  # `Wire.Socket.seed_main_stream/2`), so that is the catalog to read.
  defp default_seed_provider(module, ref) do
    case ModelCatalog.entry(Placement.local_host_name(), module.wire_name(), ref) do
      {%{provider: provider}, _health} -> Atom.to_string(provider)
      {nil, _health} -> Atom.to_string(module.credential_provider())
    end
  end

  defp push_known_model_for_turn(_adapter, _sid, nil), do: :ok

  defp push_known_model_for_turn(adapter, sid, model) do
    case Adapter.apply_model_for_turn(adapter, sid, model) do
      :ok -> :ok
      {:error, reason} -> {:error, {:model_apply_failed, reason}}
    end
  end

  # A fallback is a structural boundary a reader of the CHAT must see: the
  # model's working memory ended here while the visible history did not.
  # Position is the truth: fallback is discovered lazily at turn start, AFTER
  # this turn's echo committed, so the marker lands between echo and reply.
  defp append_session_restart_marker(db, session_key, from, to) do
    case Projection.append_marker(db, session_key, %{
           kind: "session-restart",
           from: from,
           to: to
         }) do
      {:appended, marker} -> publish_stored_message(db, session_key, marker)
      _ -> :ok
    end
  end

  # A failed turn with no marker is a prompt that silently vanishes: the
  # echo shows, the indicator clears, and no reply ever comes. The WHY
  # belongs in the chat where the reply would have been.
  # Same shape as SessionLane.error_text/1: a reason that is already a sentence
  # is one, anything else is inspected rather than guessed at.
  defp error_sentence(reason) when is_binary(reason), do: reason

  # G3: never render a raw inspected ACP error map to the operator. A credential auth fault
  # is already reclassified to a named remedy upstream (turn_credential_refusal); any OTHER
  # error map is flattened to the human message/details it carries, falling back to a bounded
  # inspect only when it has no readable text.
  defp error_sentence(reason) when is_map(reason) do
    case error_map_text(reason) do
      "" -> reason |> inspect() |> String.slice(0, 300)
      text -> text
    end
  end

  defp error_sentence(reason), do: inspect(reason)

  defp append_turn_failed_marker(db, session_key, reason) do
    append_substrate(
      db,
      session_key,
      "[turn failed]\n\nThe agent could not answer the message above: #{reason}" <>
        unknown_outcome_warning(reason)
    )
  end

  # An interrupted turn's SIDE EFFECTS are unknown, not undone. Tightbeam's
  # idempotency keys cover tightbeam's own verbs; they say nothing about a
  # shell command the agent had already issued — a `git push`, a deploy, a
  # message send may have completed before the process died. Re-running is
  # correct for `mix test` and dangerous for anything that is not idempotent,
  # so the marker tells the agent to VERIFY rather than assume either way.
  # Only the unknown-outcome case gets this: an ordinary failure with a real
  # reason already knows what happened.
  defp unknown_outcome_warning("interrupted: outcome unknown") do
    "\n\nThat turn's side effects are UNKNOWN, not undone: any command it had already " <>
      "started may have completed. Before repeating anything non-idempotent (pushes, " <>
      "deploys, sends, migrations), check the world for whether it already happened."
  end

  defp unknown_outcome_warning(_reason), do: ""

  # Substrate notices ride replay and live push as ordinary records. They
  # are not structural markers; only Projection.append_marker stamps one of
  # the three structured boundary kinds.
  defp append_substrate(db, session_key, content) do
    case Projection.append(db, %{
           session_key: session_key,
           role: "assistant",
           content: content,
           sender: "process:tightbeam",
           message_type: "substrate"
         }) do
      {:appended, notice} -> publish_message(db, session_key, notice)
      _ -> :ok
    end
  end

  # The record is already committed. A missing connection registry delays
  # delivery until replay; it must not undo or fail the tune that produced it.
  defp publish_stored_message(db, session_key, message) do
    publish_message(db, session_key, message)
  catch
    :exit, reason ->
      Logger.warning(
        "live push of #{session_key} seq #{message.seq} failed (#{inspect(reason)}); " <>
          "the message is stored and replays on the next connect"
      )

      :ok
  end

  defp publish_message(db, session_key, message, registry \\ Tightbeam.ConnRegistry) do
    case Org.get(db, session_key) do
      nil ->
        :ok

      session ->
        seq = message.seq

        Tightbeam.ConnRegistry.publish_message(
          registry,
          session_key,
          session.owner_user_id,
          seq,
          Payloads.server_message(message),
          # Message pushes carry (key, seq) so the socket's replay drain can
          # recognise literal re-sends of its own replay (set membership, not a
          # watermark — see Wire.Socket moduledoc).
          fn pid, payload -> send(pid, {:push_message, session_key, seq, payload}) end
        )
    end
  end

  # THE INDICATOR IS DERIVED, NEVER NARRATED (Flynn's rule, 2026-08-04: "once a
  # message of any type is delivered and there are no more pending messages, that
  # typing indicator should be cleared"). One deterministic fact decides it — does
  # this session have a turn in 'queued' or 'running'? — read from the ledger, the
  # single-writer table every transition already funnels through. Every emission
  # recomputes from that truth; no site asserts its own opinion, so no site can
  # disagree. This replaced three hand-emitted variants: typing-on at turn start,
  # unconditional typing-off per terminal path, and an `agent_progress
  # state=failed` label whose comment asserted "client treats state failed as
  # terminal" — a claim about another system that did not hold (the label
  # outlived a 58ms failure by many seconds on the second production touch).
  defp publish_session_indicator(db, session_key, owner_user_id) do
    broadcast(
      db,
      owner_user_id,
      Payloads.assistant_typing(session_key, session_pending?(db, session_key))
    )
  end

  defp session_pending?(db, session_key) do
    case DB.query(
           db,
           "SELECT COUNT(*) FROM turns WHERE sessionKey = ?1 AND status IN ('queued','running')",
           [session_key]
         ) do
      {:ok, [[n]]} -> n > 0
      _ -> false
    end
  end

  defp publish_turn_state(
         db,
         session_key,
         correlation,
         state,
         error,
         registry \\ Tightbeam.ConnRegistry
       ) do
    case Org.get(db, session_key) do
      nil ->
        :ok

      session ->
        Tightbeam.ConnRegistry.broadcast(
          registry,
          session.owner_user_id,
          Payloads.prompt_turn_state_event(%{
            client_message_id: correlation,
            session_key: session_key,
            state: state,
            error: error
          }),
          &deliver/2
        )
    end
  end

  defp broadcast(_db, owner, payload),
    do: Tightbeam.ConnRegistry.broadcast(Tightbeam.ConnRegistry, owner, payload, &deliver/2)

  defp emit_assignment_change(db, assignment_id, from) do
    best_effort(fn ->
      case WorkState.emit(db, assignment_id, from) do
        nil ->
          :ok

        event ->
          %{owner_user_id: owner} = Org.get(db, event.sessionKey)

          Tightbeam.ConnRegistry.publish_work_state(
            Tightbeam.ConnRegistry,
            owner,
            Payloads.work_state_event(event),
            &deliver/2
          )
      end
    end)
  end

  defp emit_item_change(db, work_item_id, kind) do
    best_effort(fn ->
      event = WorkState.emit_item(db, work_item_id, kind)

      {:ok, rows} =
        DB.query(
          db,
          "SELECT DISTINCT s.ownerUserId FROM assignments a JOIN sessions s ON s.sessionKey = a.holderKey WHERE a.workItemId = ?1",
          [work_item_id]
        )

      # The item's own owner always receives the doorbell (work-item-brackets
      # observability amendment: an item is visible to its ownerUserId
      # regardless of assignments). An unassigned item has no holders, so
      # without this union its create/disposition doorbell would publish to an
      # empty recipient set and the owner's board would never update.
      item_owner =
        case DB.query(db, "SELECT ownerUserId FROM work_items WHERE id = ?1", [work_item_id]) do
          {:ok, [[owner]]} when is_binary(owner) -> [owner]
          _ -> []
        end

      owners = MapSet.new(Enum.map(rows, &hd/1) ++ item_owner)

      Tightbeam.ConnRegistry.publish_work_item(
        Tightbeam.ConnRegistry,
        owners,
        Payloads.work_item_event(event),
        &deliver/2
      )
    end)
  end

  defp best_effort(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp deliver(pid, payload), do: send(pid, {:push, payload})
  ## Durable process custody (spec art_6817803a rev6 §B4)
  ##
  ## The owner can read, extend, stop and reconcile its own processes. There is
  ## deliberately NO generic `process-start -- <command>` on this line: §B4 says
  ## the maintenance line routes the existing typed onboarding ceremony through
  ## this record and keeps arbitrary commands off the surface entirely.

  # AUTHORIZATION FOR PER-PROCESS VERBS (review att_8017ebe7 F4).
  #
  # These shipped ungated. Any authenticated caller could read another user's
  # process row and — worse — STOP it: a cross-user read plus a destructive
  # action. The reviewer reproduced it, foreign user `mike` stopping a process
  # owned by `flynn`.
  #
  # The gate runs BEFORE the verb sees the id, and its refusal is the same
  # `not_found` an absent row gets. That is deliberate: a distinct "forbidden"
  # would confirm the row exists to a caller with no business knowing it, and
  # turn these verbs into an existence oracle over other users' processes.
  #
  # Who may act: the owning user, a session owned by that user, or an admin.
  # `processes` needs no gate here because it lists only the caller's own
  # session and cannot name someone else's.
  defp custody_handler(db, fun) do
    fn call ->
      with {:ok, id} <- required_process_id(call) do
        case ManagedProcesses.get(db, id) do
          nil ->
            %{code: "not_found", message: "unknown processId: #{id}"}

          row ->
            if custody_authorized?(db, call, row),
              do: fun.(db, call),
              else: %{code: "not_found", message: "unknown processId: #{id}"}
        end
      end
    end
  end

  defp caller_session_owner(db, session_key) do
    case Org.get(db, session_key) do
      %{owner_user_id: owner} -> owner
      _ -> nil
    end
  end

  defp custody_authorized?(db, call, row) do
    case call[:principal] do
      {:user, user_id} ->
        user_id == row.ownerUserId or match?(%{is_admin: true}, Devices.user(db, user_id))

      {:session, caller_key} ->
        caller_key == row.ownerSessionKey or
          caller_session_owner(db, caller_key) == row.ownerUserId or
          admin_origin?(db, call.origin)

      _ ->
        false
    end
  end

  defp processes_result(db, call) do
    session_key = call.session_key || caller_session(call)

    if is_binary(session_key) do
      %{
        processes:
          Enum.map(
            ManagedProcesses.list_for_session(db, session_key),
            &Payloads.managed_process/1
          )
      }
    else
      %{code: "missing_target", message: "processes needs a session to list"}
    end
  end

  defp process_get_result(db, call) do
    with {:ok, id} <- required_process_id(call) do
      case ManagedProcesses.get(db, id) do
        nil -> %{code: "not_found", message: "unknown processId: #{id}"}
        row -> %{process: Payloads.managed_process(row)}
      end
    end
  end

  defp process_extend_result(db, call) do
    with {:ok, id} <- required_process_id(call) do
      now = System.system_time(:millisecond)
      for_ms = call.params[:for_ms] || 0

      result =
        DB.transaction(db, fn txn ->
          ManagedProcesses.extend_lease_in_txn(txn, id, now: now, lease_expires_at: now + for_ms)
        end)

      case result do
        {:ok, {:ok, row}} ->
          %{process: Payloads.managed_process(row)}

        {:ok, {:error, :unknown_process}} ->
          %{code: "not_found", message: "unknown processId: #{id}"}

        {:ok, {reason, row}} ->
          # `expired`, `session_retiring` and `not_running` are refusals with a
          # durable row behind them, so the caller is told WHICH row refused and
          # what would move it, rather than a bare code.
          %{
            code: to_string(reason),
            message: extend_refusal_message(reason),
            process: Payloads.managed_process(row)
          }

        {:error, error} ->
          %{code: "server_error", message: error_map_text(error)}
      end
    end
  end

  defp extend_refusal_message(:expired),
    do:
      "the lease already expired; the stop is the winning outcome and reviving it is not extension"

  defp extend_refusal_message(:session_retiring),
    do:
      "the owner session is retiring; extend requires an active session at the captured generation"

  defp extend_refusal_message(:not_running),
    do: "only a running process holds a lease that can be extended"

  defp extend_refusal_message(:lost),
    do: "another transition won; the durable row is returned"

  defp process_stop_result(db, call) do
    with {:ok, id} <- required_process_id(call) do
      now = System.system_time(:millisecond)

      case DB.transaction(db, &ManagedProcesses.request_stop_in_txn(&1, id, now: now)) do
        {:ok, {:ok, row}} ->
          %{process: Payloads.managed_process(row)}

        {:ok, {:blocked, row}} ->
          Payloads.process_blocked("process_retirement_blocked", [row])

        {:ok, {:error, :unknown_process}} ->
          %{code: "not_found", message: "unknown processId: #{id}"}

        {:ok, {:lost, row}} ->
          %{process: Payloads.managed_process(row)}

        {:error, error} ->
          %{code: "server_error", message: error_map_text(error)}
      end
    end
  end

  defp process_reconcile_result(db, call) do
    with {:ok, id} <- required_process_id(call) do
      now = System.system_time(:millisecond)

      # Evidence is supplied, never inferred. This line ships no OS probe, so
      # the honest evidence for a row is `:not_probed`: reconcile still settles
      # the lease and reports the durable state and deadline, but it will not
      # fabricate an absence proof it does not have. Anything stronger would be
      # a guess wearing a proof's clothes (§B4).
      result =
        DB.transaction(db, fn txn ->
          ManagedProcesses.reconcile_in_txn(txn, id, now: now, evidence: :not_probed)
        end)

      case result do
        {:ok, {:ok, row}} ->
          %{process: Payloads.managed_process(row)}

        {:ok, {:blocked, row}} ->
          Payloads.process_blocked("process_unresolved", [row])

        {:ok, {:error, :unknown_process}} ->
          %{code: "not_found", message: "unknown processId: #{id}"}

        {:error, error} ->
          %{code: "server_error", message: error_map_text(error)}
      end
    end
  end

  defp required_process_id(call) do
    case call.params[:process_id] do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        %{code: "invalid_message", message: "processId required"}
    end
  end

  defp caller_session(%{principal: {:session, key}}), do: key
  defp caller_session(_call), do: nil
end
