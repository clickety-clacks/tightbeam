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
    Activations,
    AdminProjection,
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
    HarnessHealth,
    HarnessProcess,
    Homes,
    Identity,
    IdPrefix,
    Idempotency,
    LaneManager,
    Ledger,
    Model,
    ModelCatalog,
    NoticeBatcher,
    Org,
    Projection,
    Rails,
    Rules,
    Roles,
    Schema,
    Spinup,
    StaleTurnSettlement,
    StateResources,
    SubagentMarkers,
    Supervision,
    TurnLifecycle,
    Unroutable,
    Wakes,
    WorkItems,
    WorkState
  }

  alias Tightbeam.Acp.Adapter
  alias Tightbeam.DB.Txn
  alias Tightbeam.Productions.CompletionEscalation
  alias Tightbeam.Wire.Payloads
  require Logger

  @direct_state_classes ~w(message.created wake.fired turn.started turn.ended)

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
    :ok = AdminProjection.bootstrap_served(db, config.base_dir)

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
      firehose_hub: Tightbeam.Firehose.Hub,
      defaults: defaults
    }

    router_deps =
      Map.merge(socket_deps, %{
        base_dir: config.base_dir,
        cli_token: cli_token,
        session_status: &session_status/1,
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
                  principal: wake_delivery_principal(wake),
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
              principal: wake_delivery_principal(wake),
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
        {Tightbeam.Firehose.Hub, name: Tightbeam.Firehose.Hub},
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
           "effort_deadline" => &EffortCheckin.deadline(db, config, &1),
           "completion_disposition_deadline" => &CompletionEscalation.reissue(db, &1)
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
          "Tightbeam cannot start because no registered harness CLI is installed. " <>
            "That is expected on a fresh machine. Install #{binaries}, ensure it is on PATH, " <>
            "then start Tightbeam again. Run `tightbeam doctor` to check this machine."}}

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

  defp handler_specs(config) do
    db = Map.get(config, :db, Tightbeam.DB)

    assignment_change = fn assignment_id, from ->
      emit_assignment_change(db, assignment_id, from)
    end

    item_change = fn work_item_id, kind -> emit_item_change(db, work_item_id, kind) end

    %{
      {"post", ["message.created", "session.updated"]} => fn call ->
        p = call.params

        if p[:invalid_reply_reference] == true do
          %{code: "invalid_message", message: nil}
        else
          outcome =
            deliver_prompt(call.session_key, call.origin, p.content,
              db: db,
              sender: call.origin,
              authenticated_device_message: true,
              device_id: p.device_id,
              client_message_id: p.client_message_id,
              attachments: Map.get(p, :attachments, []),
              reply_to_llm_visible_message_id: Map.get(p, :reply_to_llm_visible_message_id)
            )

          case outcome do
            :appended ->
              %{ack: p.client_message_id}

            :invalid_reply_reference ->
              %{code: "invalid_message", message: nil}

            dedupe ->
              %{dedupe: to_string(dedupe)}
          end
        end
      end,
      {"wake",
       ["wake.scheduled", "wake.canceled", "wake.fired", "message.created", "session.updated"]} =>
        fn call ->
          p = call.params

          cond do
            is_binary(p[:cancel_wake_id]) ->
              cancel_wake_result(db, call, p.cancel_wake_id)

            not (is_binary(p[:prompt]) and p.prompt != "") ->
              %{code: "invalid", message: "a wake must carry a prompt"}

            # A class must be a NAME. Note what is deliberately NOT checked here:
            # membership in the five seed classes. A kungfu extends the vocabulary
            # freely (fabric §7), so refusing an unrecognized name would make an
            # org's own extension a substrate error; an extension this build has
            # no mapping for is delivered as `fyi` with a named skew row instead
            # (§5 policy-skew rule) — never dropped, never promoted.
            Map.has_key?(p, :class) and not (is_binary(p[:class]) and p[:class] != "") ->
              %{code: "invalid", message: "--class requires a class name"}

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
      {"condition", ["condition_fact.filed", "wake.fired", "message.created", "session.updated"]} =>
        fn call ->
          p = call.params

          cond do
            not (is_binary(p[:kind]) and p.kind != "") ->
              %{code: "invalid", message: "a condition fact requires a kind"}

            # `work-blocked`/`work-unblocked` assert an authority's judgment
            # over a session (spec production-machine-v1 §Standing facts): the
            # scope must be a session, and the caller must sit ABOVE it in the
            # operational-parent lineage, or be its owner (user or admin). ConditionFacts
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

              case ConditionFacts.file_idempotent_with_effect(
                     db,
                     scheduler,
                     %{
                       kind: p.kind,
                       scope: p[:scope],
                       origin: call.origin,
                       idempotency_key: p[:idempotency_key]
                     },
                     call
                   ) do
                {{:error, error}, _filed?} ->
                  error

                {fact, filed?} ->
                  if call[:firehose_effect_requested],
                    do: {:firehose_effect, fact, filed?},
                    else: fact
              end
          end
        end,
      {"facts-read", []} => fn call -> facts_read_result(db, call) end,
      {"artifact-record", ["artifact.recorded"]} => fn call -> Artifacts.record(db, call) end,
      {"artifact-get", []} => fn call ->
        Artifacts.get(db, call.params[:artifact_id]) || %{code: "not_found"}
      end,
      {"artifacts", []} => fn call -> Artifacts.list_result(db, call.params) end,
      {"activation-declare", []} => fn call -> Activations.handle(db, call.verb, call) end,
      {"activation-authority", []} => fn call -> Activations.handle(db, call.verb, call) end,
      {"activation-attempt", []} => fn call -> Activations.handle(db, call.verb, call) end,
      {"activation-observe", []} => fn call -> Activations.handle(db, call.verb, call) end,
      {"activation-reconcile", []} => fn call -> Activations.handle(db, call.verb, call) end,
      {"activation-withdraw", []} => fn call -> Activations.handle(db, call.verb, call) end,
      {"activation-renotify", []} => fn call -> Activations.handle(db, call.verb, call) end,
      {"activation-ack", []} => fn call -> Activations.handle(db, call.verb, call) end,
      {"activation-status", []} => fn call -> Activations.handle(db, call.verb, call) end,
      {"activations", []} => fn call -> Activations.handle(db, call.verb, call) end,
      {"rule", ["decision_request.ruled"]} => fn call ->
        Escalation.rule(db, call,
          authorized: admin_origin?(db, call.origin),
          scheduler: Map.get(config, :wake_scheduler, Tightbeam.WakeScheduler)
        )
      end,
      {"effort-rule", ["decision_request.ruled"]} => fn call ->
        EffortCheckin.rule(db, config, call)
      end,
      {"waive", []} => fn call ->
        Escalation.waive(db, call,
          authorized: admin_origin?(db, call.origin),
          scheduler: Map.get(config, :wake_scheduler, Tightbeam.WakeScheduler)
        )
      end,
      {"revoke-waiver", []} => fn call ->
        Escalation.revoke_waiver(db, call, authorized: admin_origin?(db, call.origin))
      end,
      {"withdraw", ["decision_request.withdrawn"]} => fn call -> Escalation.withdraw(db, call) end,
      # The `input-needed` carrier (fabric §7, GitHub #11). Both verbs are
      # ordinary routed verbs and nothing more: `Rules.decide` sees them at the
      # Dispatch chokepoint like every other, the target is resolved by the same
      # typed-target machinery `wake` uses, and neither one blocks anything.
      {"ask", ["decision_request.opened"]} => fn call ->
        decision_request_result(Escalation.ask(db, call))
      end,
      {"answer", ["decision_request.ruled"]} => fn call ->
        decision_request_result(Escalation.answer(db, call))
      end,
      {"return", ["decision_request.returned"]} => fn call ->
        decision_request_result(Escalation.return_request(db, call))
      end,
      {"operator-ask", ["decision_request.opened"]} => fn call ->
        decision_request_result(Escalation.operator_ask(db, call))
      end,
      {"operator-rule", ["decision_request.ruled"]} => fn call ->
        decision_request_result(
          Escalation.operator_rule(db, call,
            scheduler: Map.get(config, :wake_scheduler, Tightbeam.WakeScheduler),
            firehose_call: call
          )
        )
      end,
      {"operator-withdraw", ["decision_request.withdrawn"]} => fn call ->
        decision_request_result(Escalation.operator_withdraw(db, call))
      end,
      {"decision-requests", []} => fn call ->
        case Escalation.list_status(call.params[:status]) do
          {:ok, status} ->
            caller = resolve_caller(db, call.origin)

            case Escalation.list(db, call, status,
                   owner_user_id: caller && caller.owner_user_id,
                   admin: admin_origin?(db, call.origin)
                 ) do
              %{code: _} = err -> err
              requests -> %{decision_requests: requests}
            end

          %{code: _} = err ->
            err
        end
      end,
      {"decision-request", []} => fn call ->
        caller = resolve_caller(db, call.origin)
        id = call.params[:request_id] || call.params[:request]

        request =
          case call.principal do
            {:session, _key} ->
              case Escalation.raw_by_id(db, id) do
                %{kind: kind} = exact when kind in ["agent", "effort"] ->
                  exact

                _ ->
                  Escalation.get(db, call, id,
                    owner_user_id: caller && caller.owner_user_id,
                    admin: admin_origin?(db, call.origin)
                  )
              end

            _ ->
              Escalation.get(db, call, id,
                owner_user_id: caller && caller.owner_user_id,
                admin: admin_origin?(db, call.origin)
              )
          end

        case request do
          nil -> %{code: "not_found", message: "decision request not found"}
          %{code: _} = err -> err
          request -> %{decision_request: request}
        end
      end,
      {"approve-device", ["device.approved"]} =>
        admin_call_handler(db, fn call ->
          p = call.params
          d = Devices.approve_with_firehose(db, p.device_id, p[:user_id], call)
          %{approved: %{device_id: d.device_id, user_id: d.user_id, is_admin: d.is_admin}}
        end),
      {"deny-device", ["device.denied"]} =>
        admin_call_handler(db, fn call ->
          p = call.params
          Devices.deny_with_firehose(db, p.device_id, call)
          %{denied: p.device_id}
        end),
      {"revoke-device", ["device.revoked"]} =>
        admin_call_handler(db, fn call ->
          p = call.params
          Devices.revoke_with_firehose(db, p.device_id, call)
          %{revoked: p.device_id}
        end),
      {"host-env-set", ["host_env.updated"]} =>
        admin_call_handler(db, fn call ->
          p = call.params

          case Placement.set_env_overlay_with_firehose(
                 db,
                 p.host,
                 p.harness,
                 p.name,
                 p.value,
                 call.origin,
                 call
               ) do
            %{projection: projection, changed: changed} ->
              %{
                host_environment: StateResources.host_environment(projection),
                changed: changed,
                effect: "takes effect on next #{p.harness} adapter start on #{p.host}"
              }

            {:error, denial} ->
              denial
          end
        end),
      {"host-env-list", []} =>
        admin_call_handler(db, fn call ->
          %{
            overlays:
              db
              |> StateResources.query_host_environment(call.params)
              |> Enum.map(&StateResources.host_environment/1)
          }
        end),
      {"host-env-unset", ["host_env.updated"]} =>
        admin_call_handler(db, fn call ->
          p = call.params

          result =
            Placement.unset_env_overlay_with_firehose(db, p.host, p.harness, p.name, call)

          %{
            host_environment:
              result.projection && StateResources.host_environment(result.projection),
            changed: result.changed,
            removed: result.changed
          }
        end),
      {"register-host", ["host.registered"]} =>
        admin_call_handler(db, fn call ->
          p = call.params
          # The dumb half of assimilation (spec §Placement): the CLI ceremony
          # prepared the machine; this records the fact. The topology is the
          # operator's to declare.
          previous_entry = Placement.hosts(config.base_dir, db)[p.name]

          {:ok, registration} =
            Placement.register_host_with_firehose(
              db,
              p.name,
              %{
                ssh: p[:ssh] || p.name,
                base_dir: Map.fetch!(p, :base_dir),
                cli_bin: p[:cli_bin],
                adapter_bin_dir: p[:adapter_bin_dir]
              },
              call
            )

          entry = registration.entry

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
              %{
                host: StateResources.host(registration.projection),
                changed: registration.changed
              }

            {:error, reason} ->
              %{code: to_string(reason), message: endpoint_failure_message(reason, p.name)}
          end
        end),
      {"update-clients", []} =>
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
      {"identity-edit", ["identity.updated"]} =>
        identity_mutation_handler(config, db, fn call ->
          identity_edit_result(config, db, call)
        end),
      {"identity-status", []} =>
        admin_call_handler(db, fn call -> identity_status_result(config, db, call) end),
      {"identity-relearn", ["identity.updated", "kungfu.updated"]} =>
        identity_mutation_handler(config, db, fn call ->
          identity_relearn_result(config, db, call)
        end),
      {"identity-repoint", []} =>
        admin_call_handler(db, fn call -> identity_repoint_result(config, db, call) end),
      {"learn", ["identity.updated", "kungfu.updated"]} =>
        identity_mutation_handler(config, db, fn call ->
          identity_learn_result(config, db, call)
        end),
      {"unlearn", ["identity.updated", "kungfu.updated"]} =>
        identity_mutation_handler(config, db, fn call ->
          identity_unlearn_result(config, db, call)
        end),
      {"kungfu-list", []} =>
        admin_call_handler(db, fn _call ->
          bundles =
            config.base_dir
            |> StateResources.kungfu_names()
            |> Enum.flat_map(fn name ->
              case StateResources.query_kungfu(db, name) do
                nil -> []
                item -> [StateResources.kungfu(item)]
              end
            end)

          %{bundles: bundles}
        end),
      {"identity-apply", []} =>
        admin_call_handler(db, fn call -> identity_apply_result(config, db, call) end),
      {"kungfu-scaffold", ["identity.updated", "kungfu.updated"]} =>
        identity_mutation_handler(config, db, fn call ->
          candidate =
            Archetypes.scaffold_kungfu!(
              config.base_dir,
              call.params.name,
              call.params.purpose,
              call.origin
            )

          publish_identity_candidate(
            config,
            db,
            call,
            candidate,
            %{kungfu: call.params.name, paths: candidate.paths}
          )
        end),
      {"onboard", []} => admin_call_handler(db, fn call -> onboard_result(config, call) end),
      {"promote-user", ["user.promoted"]} =>
        admin_call_handler(db, fn call ->
          result = Devices.promote_user_with_firehose(db, call.params.user_id, call)
          %{user: StateResources.user(result.user), changed: result.changed}
        end),
      {"add-user", ["user.added"]} =>
        admin_call_handler(db, fn call ->
          p = call.params

          %{
            user:
              db
              |> Devices.add_user_with_firehose(
                p.user_id,
                Map.get(p, :is_admin, false),
                call
              )
              |> StateResources.user()
          }
        end),
      {"read-marker-set", ["read_marker.updated"]} => fn call ->
        read_marker_result(db, call, :set)
      end,
      {"read-marker-clear", ["read_marker.updated"]} => fn call ->
        read_marker_result(db, call, :clear)
      end,
      {"config", ["config.updated"]} =>
        admin_call_handler(db, fn call -> config_result(db, call) end),
      {"harness-processes", []} =>
        admin_handler(db, fn _params ->
          coordinator = Map.get(config, :adapter_coordinator, Tightbeam.AdapterCoordinator)
          %{harness_processes: AdapterCoordinator.harness_processes(coordinator)}
        end),
      {"role-create", ["role.created"]} => fn call -> role_create_result(db, call) end,
      {"role-bind", ["role.bound"]} => fn call -> role_bind_result(db, call) end,
      {"role-rm", ["role.removed"]} => fn call -> role_rm_result(db, call) end,
      {"role-list", []} => fn _call -> role_list_result(db) end,
      {"work-item-create", ["work_item.created", "wake.scheduled"]} => fn call ->
        WorkItems.__handle__(
          db,
          "work-item-create",
          call
          |> Map.put(:on_work_item_change, item_change)
          |> Map.put(:on_routing_wake_scheduled_in_txn, fn txn, wake ->
            Tightbeam.Firehose.Publisher.committed_in_txn(
              txn,
              "wake.scheduled",
              wake,
              %{"workItemId" => wake.work_item_id}
            )
          end)
        )
      end,
      {"work-item-get", []} => fn call -> WorkItems.__handle__(db, "work-item-get", call) end,
      {"work-item-trace", []} => fn call -> WorkItems.__handle__(db, "work-item-trace", call) end,
      {"transcript", []} => fn call -> Tightbeam.Transcript.read(db, call) end,
      {"turn-trace", []} => fn call -> TurnLifecycle.read(db, call) end,
      {"attend", []} => fn call -> attend_result(db, call) end,
      {"toplines", []} => fn call -> Tightbeam.Toplines.roster(db, call) end,
      {"topline", []} => fn call -> Tightbeam.Toplines.topline(db, call) end,
      {"coordination-share", []} => fn call -> coordination_share_result(db, call) end,
      {"digest-members", []} => fn call -> digest_members_result(db, call) end,
      {"work-item-list", []} => fn call -> WorkItems.__handle__(db, "work-item-list", call) end,
      {"work-item-update", ["work_item.updated"]} => fn call ->
        WorkItems.__handle__(
          db,
          "work-item-update",
          call
          |> Map.put(:on_work_item_change, item_change)
          |> Map.put(:effort_config, config)
        )
      end,
      {"work-item-icebox", ["work_item.iceboxed"]} =>
        work_item_disposition(db, "work-item-icebox", item_change),
      {"work-item-reopen", ["work_item.reopened"]} =>
        work_item_disposition(db, "work-item-reopen", item_change),
      {"work-item-close", ["work_item.closed"]} =>
        work_item_disposition(db, "work-item-close", item_change),
      {"work-item-fail", ["work_item.failed"]} =>
        work_item_disposition(db, "work-item-fail", item_change),
      {"assign", ["assignment.opened"]} => fn call ->
        call =
          call
          |> Map.put(:supervision_interval_ms, Map.fetch!(config, :wake_tick_ms))
          |> Map.put(:on_assignment_change, assignment_change)
          |> Map.put(:on_work_item_change, item_change)
          |> Map.put(:effort_config, config)

        Assignments.__handle__(db, "assign", call)
      end,
      {"dispatch", ["assignment.opened", "message.created", "wake.scheduled", "session.updated"]} =>
        fn call ->
          call =
            call
            |> Map.put(:supervision_interval_ms, Map.fetch!(config, :wake_tick_ms))
            |> Map.put(:on_assignment_change, assignment_change)
            |> Map.put(:on_work_item_change, item_change)
            |> Map.put(:effort_config, config)
            |> Map.put(:on_dispatch_delivery, fn delivery, _ ->
              complete_delivery(db, delivery)
            end)

          Assignments.__handle__(db, "dispatch", call)
        end,
      {"attest", ["attest.filed", "assignment.closed"]} => fn call ->
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
      {"attests", []} => fn call -> Assignments.__handle__(db, "attests", call) end,
      {"assignment-get", []} => fn call -> Assignments.__handle__(db, "assignment-get", call) end,
      {"revoke-assignment", ["assignment.closed"]} => fn call ->
        Assignments.__handle__(
          db,
          "revoke-assignment",
          Map.put(call, :on_assignment_change, assignment_change)
        )
      end,
      {"reopen-assignment", ["assignment.reopened"]} => fn call ->
        Assignments.__handle__(
          db,
          "reopen-assignment",
          call
          |> Map.put(:on_assignment_change, assignment_change)
          # A reopened card is armed exactly like a freshly assigned one, so it
          # needs the same supervision and effort configuration `assign` and
          # `dispatch` get.
          |> Map.put(:supervision_interval_ms, Map.fetch!(config, :wake_tick_ms))
          |> Map.put(:effort_config, config)
        )
      end,
      {"repair-assignment", ["message.created", "session.updated"]} => fn call ->
        repair_assignment_result(config, db, call)
      end,
      {"assignments", []} => fn call -> Assignments.__handle__(db, "assignments", call) end,
      {"completion-notices", []} => fn call -> CompletionEscalation.notices(db, call) end,
      {"completion-disposition", []} => fn call ->
        completion_disposition_result(config, db, call)
      end,
      {"inspect", []} => fn call -> inspect_result(config, db, call) end,
      {"cancel", ["turn.ended", "session.updated"]} => fn call -> cancel_result(db, call) end,
      {"settle-turn", ["turn.ended", "session.updated"]} => fn call ->
        settle_turn_result(db, call)
      end,
      {"critical", ["critical_lease.updated"]} => fn call -> critical_result(config, db, call) end,
      {"spawn", ["session.spawned"]} => fn call -> spawn_result(config, db, call) end,
      {"tune", ["message.created", "session.updated"]} => fn call ->
        tune_result(config, db, call)
      end,
      {"retire", ["session.retired", "wake.scheduled"]} => fn call ->
        retire_result(config, db, call)
      end
    }
    |> compile_handler_specs!()
  end

  @doc false
  @spec compile_handler_specs!(map()) ::
          %{String.t() => %{handler: (map() -> term()), effects: [String.t()]}}
  def compile_handler_specs!(raw_specs) when is_map(raw_specs) do
    specs =
      Enum.map(raw_specs, fn
        {{verb, effects}, handler}
        when is_binary(verb) and is_list(effects) and is_function(handler, 1) ->
          if Enum.all?(effects, &is_binary/1) and Enum.uniq(effects) == effects do
            {verb, %{handler: handler, effects: effects}}
          else
            raise ArgumentError,
                  "invalid gateway handler spec for #{inspect(verb)}: effects must be unique class names"
          end

        {key, _handler} ->
          raise ArgumentError,
                "invalid gateway handler spec entry #{inspect(key)}: " <>
                  "every executable handler must bind its accepted-result effects"
      end)

    duplicates =
      specs
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.filter(fn {_verb, entries} -> length(entries) > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates != [] do
      raise ArgumentError, "duplicate gateway handler specs: #{inspect(duplicates)}"
    end

    Map.new(specs)
  end

  @doc "The immutable verb-handler table (see moduledoc list) — built once, passed to Dispatch."
  @spec handlers(config()) :: Tightbeam.Dispatch.handlers()
  def handlers(config) do
    Map.new(handler_specs(config), fn {verb, spec} -> {verb, spec.handler} end)
  end

  @doc "Accepted-result state effects from the same entries as the immutable handler table."
  @spec handler_effects(config()) :: %{String.t() => [String.t()]}
  def handler_effects(config) do
    Map.new(handler_specs(config), fn {verb, spec} -> {verb, spec.effects} end)
  end

  @spec emitted_state_classes(%{String.t() => [String.t()]}) :: [String.t()]
  def emitted_state_classes(handler_effects) do
    handler_effects
    |> Map.values()
    |> List.flatten()
    |> Kernel.++(@direct_state_classes)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A terminal-disposition handler routes the owner doorbell through the same
  # work_item_events seam as create/update.
  defp work_item_disposition(db, verb, item_change) do
    fn call ->
      WorkItems.__handle__(db, verb, Map.put(call, :on_work_item_change, item_change))
    end
  end

  defp repair_assignment_result(config, db, call) do
    p = call.params
    assignment_id = p[:assignment_id]

    with {:ok, assignment} <- repair_assignment(db, assignment_id),
         :ok <- repair_authorized(db, call, assignment),
         {:ok, repair_key, fingerprint} <- repair_request(p),
         principal = TurnLifecycle.principal(call.principal),
         {:ok, claim} <-
           Ledger.begin_assignment_repair(
             db,
             assignment.id,
             repair_key,
             fingerprint,
             p[:action],
             principal
           ) do
      case claim do
        {:replay, result} ->
          result

        {:in_progress, attempt_id} ->
          %{
            ok: false,
            code: "repair_in_progress",
            message:
              "repair attempt #{attempt_id} is already claimed; its outcome must be reconciled before another effect"
          }

        {:claimed, attempt_id} ->
          execute_claimed_assignment_repair(
            config,
            db,
            call,
            assignment,
            attempt_id
          )
      end
    else
      {:error, :repair_key_conflict} ->
        %{
          ok: false,
          code: "repair_key_conflict",
          message: "repair key is already bound to a different request for this assignment"
        }

      {:error, error} ->
        %{ok: false, code: "repair_state_failed", message: inspect(error)}

      {:error, code, message} ->
        %{ok: false, code: code, message: message}
    end
  end

  defp repair_request(p) do
    repair_key = p[:idempotency_key]
    action = p[:action]

    cond do
      not is_binary(repair_key) or repair_key == "" ->
        {:error, "idempotency_key_required", "repair requires --key"}

      action not in ["tune", "restart", "rerun", "resume", "relaunch"] ->
        {:error, "invalid_request", "repair requires a sanctioned --action"}

      true ->
        fingerprint =
          JSON.encode!([
            action,
            p[:model],
            p[:effort],
            p[:context],
            p[:outcome],
            p[:turn_seq]
          ])

        {:ok, repair_key, fingerprint}
    end
  end

  defp execute_claimed_assignment_repair(config, db, call, assignment, attempt_id) do
    {result, incident} =
      with {:ok, session} <- repair_holder(db, assignment),
           {:ok, incident} <- repair_incident(db, assignment, session, call.params[:action]) do
        {execute_assignment_repair(config, db, call, assignment, session, incident), incident}
      else
        {:error, code, message} -> {%{ok: false, code: code, message: message}, nil}
      end

    case Ledger.finish_assignment_repair(db, attempt_id, result) do
      :ok ->
        if incident, do: record_repair_result(db, call, assignment, incident, result)
        result

      {:error, reason} ->
        %{
          ok: false,
          code: "repair_state_failed",
          message:
            "repair effect outcome could not be persisted; attempt #{attempt_id} remains claimed: #{inspect(reason)}"
        }
    end
  end

  defp repair_assignment(db, assignment_id) when is_binary(assignment_id) do
    case DB.query(
           db,
           """
           SELECT id,subject,holderKey,openedByUser,openedBySession,workItemId,state
           FROM assignments WHERE id=?1
           """,
           [assignment_id]
         ) do
      {:ok, [[id, subject, holder, by_user, by_session, work_item, "open"]]} ->
        {:ok,
         %{
           id: id,
           subject: subject,
           holder: holder,
           opened_by_user: by_user,
           opened_by_session: by_session,
           work_item_id: work_item
         }}

      _ ->
        {:error, "unknown_assignment", "unknown open assignment: #{assignment_id}"}
    end
  end

  defp repair_assignment(_db, _assignment_id),
    do: {:error, "invalid_request", "repair-assignment requires assignmentId"}

  defp repair_authorized(db, call, assignment) do
    allowed =
      case call.principal do
        {:user, user} -> assignment.opened_by_user == user or admin_caller?(db, call)
        {:session, session} -> assignment.opened_by_session == session or admin_caller?(db, call)
        _ -> false
      end

    if allowed,
      do: :ok,
      else: {:error, "not_authorized", "assignment repair requires its opener or an admin"}
  end

  defp repair_holder(db, assignment) do
    case Org.get(db, assignment.holder) do
      %{state: "active"} = session -> {:ok, session}
      _ -> {:error, "holder_unavailable", "assignment holder is not an active session"}
    end
  end

  defp repair_incident(db, assignment, session, action) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT i.id,i.failureClass
        FROM harness_health_incidents i
        JOIN harness_health_assignments a ON a.incidentId=i.id
        WHERE a.assignmentId=?1 AND i.harness=?2 AND i.host=?3 AND i.state='open'
        ORDER BY i.openedAt DESC,i.id DESC
        """,
        [assignment.id, session.harness, session.host]
      )

    case rows do
      [[id, failure_class] | _] ->
        guidance = HarnessHealth.get(db, id).repair

        if action == guidance.action do
          {:ok, %{id: id, failure_class: failure_class, action: action}}
        else
          {:error, "wrong_repair",
           "#{failure_class} requires repair action #{guidance.action}, not #{inspect(action)}"}
        end

      [] when action == "relaunch" ->
        {:ok, %{id: nil, failure_class: "never-launched", action: action}}

      [] ->
        {:error, "no_open_incident",
         "no open harness incident covers this assignment; use relaunch only for a holder with no turn"}
    end
  end

  defp execute_assignment_repair(
         config,
         db,
         call,
         assignment,
         session,
         %{action: "tune"} = incident
       ) do
    model = call.params[:model]

    if is_binary(model) and model != "" do
      tuned =
        tune_result(
          config,
          db,
          call
          |> Map.put(:session_key, session.session_key)
          |> Map.put(
            :params,
            %{setting: "set_model", model: model}
            |> maybe_put(:effort, call.params[:effort])
            |> maybe_put(:context, call.params[:context])
          )
          |> Map.put(:repair_assignment_id, assignment.id)
        )

      if Map.has_key?(tuned, :code), do: tuned, else: rerun_latest(db, call, assignment, incident)
    else
      %{ok: false, code: "model_required", message: "model_unavailable repair requires --model"}
    end
  end

  defp execute_assignment_repair(
         config,
         db,
         call,
         assignment,
         session,
         %{action: action} = incident
       )
       when action in ["restart", "resume"] do
    coordinator = Map.get(config, :adapter_coordinator, AdapterCoordinator)
    key = {Harness.parse!(session.harness).id(), "shared", session.host}

    case AdapterCoordinator.close_adapter(coordinator, key) do
      :ok ->
        if incident.failure_class == "rate-limit-dead" do
          :ok = HarnessProcess.complete_park(db, key)
        end

        rerun_latest(db, call, assignment, incident)

      {:error, reason} ->
        %{ok: false, code: "repair_failed", message: inspect(reason)}
    end
  end

  defp execute_assignment_repair(
         _config,
         db,
         call,
         assignment,
         _session,
         %{action: "rerun"} = incident
       ) do
    if call.params[:outcome] == "not-completed" do
      rerun_latest(db, call, assignment, incident)
    else
      %{
        ok: false,
        code: "outcome_reconciliation_required",
        message: "rerun requires --outcome not-completed; unknown outcomes are never replayed"
      }
    end
  end

  defp execute_assignment_repair(_config, db, call, assignment, _session, %{action: "relaunch"}) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT count(*) FROM turns WHERE assignmentId=?1", [assignment.id])

    if count == 0 do
      case deliver_prompt(assignment.holder, call.origin, assignment.subject,
             db: db,
             assignment_id: assignment.id,
             job_ref: assignment.work_item_id,
             sender: "assignment repair",
             conn_registry: Map.get(call, :conn_registry, Tightbeam.ConnRegistry),
             lane_manager: Map.get(call, :lane_manager, Tightbeam.LaneManager)
           ) do
        :appended -> %{ok: true, action: "relaunch", assignmentId: assignment.id}
        result -> %{ok: false, code: "repair_failed", message: inspect(result)}
      end
    else
      %{
        ok: false,
        code: "holder_launched",
        message: "relaunch is only sanctioned when this assignment has produced no turn"
      }
    end
  end

  defp rerun_latest(db, call, assignment, incident) do
    source_seq = call.params[:turn_seq]

    source_seq =
      if is_integer(source_seq) do
        source_seq
      else
        case DB.query(
               db,
               """
               SELECT seq FROM turns
               WHERE assignmentId=?1 AND status IN ('failed','failed_unknown')
               ORDER BY seq DESC LIMIT 1
               """,
               [assignment.id]
             ) do
          {:ok, [[seq]]} -> seq
          _ -> nil
        end
      end

    repair_key = call.params[:idempotency_key]

    cond do
      not is_integer(source_seq) ->
        %{ok: false, code: "no_failed_turn", message: "assignment has no terminal failed turn"}

      not is_binary(repair_key) or repair_key == "" ->
        %{ok: false, code: "idempotency_key_required", message: "repair requires --key"}

      true ->
        principal = TurnLifecycle.principal(call.principal)

        case Ledger.repair_terminal(db, source_seq, assignment.id, repair_key, principal) do
          {:ok, {status, attempt_seq, attempt_id}} ->
            LaneManager.ensure_lane(
              Map.get(call, :lane_manager, Tightbeam.LaneManager),
              assignment.holder
            )

            %{
              ok: true,
              action: incident.action,
              incidentId: incident.id,
              assignmentId: assignment.id,
              sourceTurnSeq: source_seq,
              attemptTurnSeq: attempt_seq,
              attemptId: attempt_id,
              dedupe: to_string(status)
            }

          {:error, reason} ->
            %{ok: false, code: "repair_failed", message: inspect(reason)}
        end
    end
  end

  defp record_repair_result(db, call, assignment, incident, result) do
    detail =
      JSON.encode!(%{
        assignmentId: assignment.id,
        incidentId: incident.id,
        action: incident.action,
        principal: TurnLifecycle.principal(call.principal),
        result: result
      })

    kind =
      if result[:ok] == true,
        do: "harness_health_repair_started",
        else: "harness_health_repair_failed"

    EventLog.lifecycle(db, kind, assignment.id, detail)
    :ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Shared turn-bearing delivery (gateway.ts `deliverPrompt`): ONE transaction
  appends the echo (Projection) + enqueues the turn (Ledger.enqueue_in_txn),
  then broadcasts the echo and nudges the lane. Returns the dedupe outcome.
  """
  @spec deliver_prompt(String.t(), String.t(), String.t(), keyword()) ::
          :appended | :duplicate | :conflict | :invalid_reply_reference | :skipped
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
          | :invalid_reply_reference
          | :skipped
  def deliver_prompt_in_txn(%DB.Txn{} = txn, session_key, origin, prompt, opts \\ []) do
    case completion_delivery_admission(txn, session_key, opts) do
      :skip ->
        :skipped

      :continue ->
        case existing_wake_turn_in_txn(txn, opts[:wake_id]) do
          nil -> deliver_prompt_once_in_txn(txn, session_key, origin, prompt, opts)
          duplicate -> duplicate
        end
    end
  end

  defp completion_delivery_admission(txn, session_key, opts) do
    case opts[:wake_id] do
      wake_id when is_binary(wake_id) ->
        case CompletionEscalation.admit_delivery_in_txn(txn, wake_id, session_key) do
          :skip -> :skip
          result when result in [:ordinary, :deliver] -> :continue
        end

      _ ->
        :continue
    end
  end

  defp existing_wake_turn_in_txn(_txn, wake_id) when not is_binary(wake_id), do: nil

  defp existing_wake_turn_in_txn(txn, wake_id) do
    case DB.Txn.q(txn, "SELECT seq FROM turns WHERE wakeId=?1 LIMIT 1", [wake_id]) do
      [[seq]] -> {:duplicate, %{wake_id: wake_id, turn_seq: seq}}
      [] -> nil
    end
  end

  defp deliver_prompt_once_in_txn(txn, session_key, origin, prompt, opts) do
    # The authenticated post handler is the provenance boundary. Device/client
    # identifiers alone are not evidence: process deliveries also use them for dedupe.
    authenticated_device_message? =
      opts[:authenticated_device_message] == true and is_binary(opts[:device_id]) and
        is_binary(opts[:client_message_id])

    stamped =
      case {opts[:sender], authenticated_device_message?} do
        {sender, false} when is_binary(sender) -> "[from #{sender}]\n\n" <> prompt
        _ -> prompt
      end

    case delivery_target(txn, session_key, opts[:target_gate]) do
      nil ->
        cancel_unavailable_supervision_controller_in_txn(txn, opts, session_key)
        :skipped

      {target, role_ref, role_fallback} when not is_nil(target) ->
        case resolve_reply_target(txn, target, opts) do
          {:ok, reply_target} ->
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
                    opts
                    |> Keyword.put(:reply_target, reply_target)
                    |> Keyword.put(:supervision_controller, controller)
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

          :error ->
            :invalid_reply_reference
        end
    end
  end

  defp append_and_enqueue_in_txn(
         txn,
         target,
         role_ref,
         role_fallback,
         origin,
         stamped,
         opts
       ) do
    reply_target = opts[:reply_target]

    with input <- %{
           session_key: target,
           role: "user",
           content: stamped,
           device_id: opts[:device_id],
           client_message_id: opts[:client_message_id],
           attachments: opts[:attachments] || [],
           sender: opts[:sender],
           reply_to_message_id: reply_target && reply_target.id,
           reply_to_client_message_id: reply_target && reply_target.client_message_id
         },
         outcome <- Projection.append_in_txn(txn, input) do
      case outcome do
        {:appended, message} ->
          {assignment_id, job_ref} = turn_attribution(txn, opts)

          enqueued =
            Ledger.enqueue_in_txn(txn, %{
              session_key: target,
              message_id: message.id,
              client_message_id: message.client_message_id,
              principal: opts[:principal] || origin,
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
              Tightbeam.Firehose.Publisher.message_in_txn(txn, target, message)

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
  end

  defp resolve_reply_target(txn, session_key, opts) do
    case opts[:reply_to_llm_visible_message_id] do
      nil ->
        {:ok, nil}

      llm_visible_message_id when is_binary(llm_visible_message_id) ->
        case DB.Txn.q(
               txn,
               "SELECT id, clientMessageId FROM messages WHERE sessionKey = ?1 AND llmVisibleMessageId = ?2 LIMIT 2",
               [session_key, llm_visible_message_id]
             ) do
          [[id, client_message_id]] -> {:ok, %{id: id, client_message_id: client_message_id}}
          _ -> :error
        end
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

      if DB.Txn.changes(txn) == 1,
        do: Wakes.publish_change_in_txn(txn, "wake.fired", opts[:wake_id])
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
  @spec complete_delivery(DB.server(), term()) ::
          :appended | :duplicate | :conflict | :invalid_reply_reference | :skipped
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
  def complete_delivery(_db, :invalid_reply_reference), do: :invalid_reply_reference
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
  def session_status(session_key, db \\ Tightbeam.DB) do
    case Org.get(db, session_key) do
      nil ->
        nil

      session ->
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

        current_efforts =
          case session.model &&
                 Enum.find(catalog, &ModelCatalog.names_same_model?(&1, session.model)) do
            nil -> []
            entry -> entry.efforts
          end

        reasoning_capability =
          case current_efforts do
            [] ->
              reason =
                if is_nil(session.model),
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

        payload = %{
          # sessionKey is REQUIRED by the client's SessionStatus decoder — its
          # absence fails the whole decode and the model footer never
          # populates (found live; the TS reference omitted it too).
          sessionKey: session_key,
          operationalParent: session.operational_parent,
          effectiveParent: session.effective_parent,
          effectiveParentSource: Atom.to_string(session.effective_parent_source),
          display: %{
            # `model` is the row IDENTITY this seam issues (see `wire_model/1`):
            # the footer displays it verbatim when it cannot match a catalog row,
            # and matches it against the catalog rows for the current-model
            # checkmark. The identity's FIELDS travel beside it, named, and are
            # what a caller reads or sends back.
            model: (session.model && wire_identity(session.model)) || "unknown",
            modelFamily: session.model && session.model.family,
            modelContext: session.model && session.model.context,
            modelPreferences: model_preferences,
            provider: session.provider,
            harness: session.harness,
            host: session.host,
            credentialKind: credential_kind,
            authMode: nil,
            reasoningLevel: session.model && session.model.effort,
            thinkingLevel: nil,
            fastMode: nil,
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
            setFastMode: unsupported.("not supported"),
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
            canChangeFastMode: false,
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
          }
        }

        case credential_kind do
          {:error, reason} ->
            {:error, 503, "credential_store_unreadable", describe_error(reason)}

          _kind ->
            payload
        end
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
      :operational_parent,
      :effective_parent,
      :effective_parent_source,
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
        with {:ok, adapter, generation} <- traced_checkout(db, turn, session),
             {:ok, harness_session} <-
               traced_stage(db, turn, :session, fn ->
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
               end),
             {:ok, result} <-
               traced_prompt(
                 db,
                 turn,
                 adapter,
                 harness_session.id,
                 progress_fun(db, turn.session_key, session.owner_user_id, correlation)
               ),
             :ok <- append_assistant_messages(db, turn, echo, result) do
          record_in_txn = fn txn ->
            HarnessHealth.resolve_normal_turn_in_txn(txn, session, turn)
          end

          {:ok, %{terminal_publish: terminal_publish, record_in_txn: record_in_txn}}
        else
          {:error, {:assistant_commit, reason}} ->
            {:error, {:prompt, {:lifecycle_trace_failed_after_prompt, :assistant_commit, reason}}}

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
            # event). An agent reading the applicable activity table decides what to do
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
            safe_failure = safe_process_failure(failed_stage, raw_reason)

            {reason, credential_refused?} =
              case turn_credential_refusal(session) do
                {:refused, message} -> {message, true}
                :not_applicable -> {reason, false}
              end

            # A reviewed concrete cause is the whole public reason. The raw ACP
            # term remains only in `harness_turn_error`, the existing internal
            # diagnostic below; arbitrary provider prose must not ride the
            # target marker, terminal state, or stored turn error.
            public_reason =
              cond do
                match?({:lifecycle_trace_failed_after_prompt, _, _}, raw_reason) ->
                  "turn lifecycle trace failed after prompt dispatch; outcome unknown"

                not is_nil(safe_failure) and not credential_refused? ->
                  safe_failure.message

                true ->
                  reason
              end

            public_state_error =
              if not is_nil(safe_failure) and not credential_refused?,
                do: safe_failure.message,
                else: inspect(reason)

            failure_publish = fn _terminal ->
              # THE ERROR MUST REACH THE CHAT. Every failed turn gets the marker
              # now; the adjudication path used to skip it because the brief was
              # its message, and a failure that lost its brief showed Flynn
              # "agent progress interrupted" with no reason attached.
              append_turn_failed_marker(db, turn.session_key, error_sentence(public_reason))

              publish_turn_state(
                db,
                turn.session_key,
                correlation,
                "failed",
                public_state_error
              )

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

              notice =
                assignment_process_failure_notice_in_txn(
                  txn,
                  turn.seq,
                  safe_failure
                )

              health =
                HarnessHealth.observe_turn_failure_in_txn(
                  txn,
                  session,
                  turn,
                  failed_stage,
                  raw_reason
                )

              %{notice: notice, health: health}
            end

            terminal =
              if match?({:lifecycle_trace_failed_after_prompt, _, _}, raw_reason),
                do: "failed_unknown",
                else: "failed"

            {:error,
             %{
               reason: public_reason,
               terminal: terminal,
               terminal_publish: failure_publish,
               record_in_txn: record_in_txn,
               after_commit: fn recorded ->
                 EventLog.complete_notice(recorded.notice,
                   conn_registry: Map.get(config, :conn_registry, ConnRegistry)
                 )

                 if is_function(recorded.health, 0), do: recorded.health.()
               end
             }}
        end

      outcome
    end
  end

  defp assignment_process_failure_notice_in_txn(txn, turn_seq, safe_failure) do
    with %{code: code, message: message, reported_at_layer: layer} <- safe_failure,
         [[assignment_id, owner_user_id]] <-
           Txn.q(
             txn,
             """
             SELECT t.assignmentId, COALESCE(w.ownerUserId, s.ownerUserId)
             FROM turns t
             JOIN assignments a ON a.id = t.assignmentId
             JOIN sessions s ON s.sessionKey = a.holderKey
             LEFT JOIN work_items w ON w.id = a.workItemId
             WHERE t.seq = ?1
             """,
             [turn_seq]
           ) do
      detail =
        JSON.encode!(%{
          schemaVersion: 1,
          turnSeq: turn_seq,
          actionNeeded: true,
          reportedAtLayer: layer,
          causeSpecificity: "concrete",
          safeCause: %{code: code, message: message}
        })

      EventLog.notice_in_txn(
        txn,
        "assignment_process_failure",
        assignment_id,
        detail,
        audience: {:ambient, owner_user_id},
        message: "[assignment action needed]\n\nReview assignment #{assignment_id}: #{message}.",
        attention: :high
      )
    else
      _ -> nil
    end
  end

  defp safe_process_failure(:prompt, reason) when is_map(reason) do
    data = map_get_any(reason, ["data", :data])

    cond do
      is_map(data) and
          map_get_any(data, ["codexErrorInfo", :codexErrorInfo]) == "usageLimitExceeded" ->
        %{
          code: "codex_usage_limit",
          message: "Codex usage limit reached",
          reported_at_layer: "acp"
        }

      is_map(data) and map_get_any(data, ["errorKind", :errorKind]) == "rate_limit" ->
        %{
          code: "claude_rate_limit",
          message: "Claude rate limit reached",
          reported_at_layer: "acp"
        }

      true ->
        nil
    end
  end

  defp safe_process_failure(_failed_stage, _reason), do: nil

  defp traced_checkout(db, turn, session) do
    with :ok <- trace_stage_started(db, turn, :checkout) do
      case traced_call(db, turn, :checkout, fn -> checkout_adapter(session) end) do
        {:ok, adapter, generation} ->
          case trace_call(fn ->
                 Ledger.stamp_adapter(db, turn.seq, generation, turn.owner_lease)
               end) do
            :ok -> {:ok, adapter, generation}
            {:error, reason} -> {:error, {:checkout, {:lifecycle_trace_failed, reason}}}
          end

        {:error, reason} ->
          with :ok <- trace_stage_failed(db, turn, :checkout, reason) do
            {:error, {:checkout, reason}}
          end
      end
    else
      {:error, reason} -> {:error, {:checkout, {:lifecycle_trace_failed, reason}}}
    end
  end

  defp traced_stage(db, turn, stage, fun) when stage in [:session] and is_function(fun, 0) do
    with :ok <- trace_stage_started(db, turn, stage) do
      case traced_call(db, turn, stage, fun) do
        {:ok, value} ->
          detail = %{v: 1, mode: value.mode}

          with :ok <-
                 trace_event(db, turn.seq, %{
                   event_key: "#{stage}:succeeded",
                   producer_event_id: "gateway:#{stage}:succeeded",
                   kind: "stage_succeeded",
                   stage: Atom.to_string(stage),
                   outcome: "succeeded",
                   cause: "turn:#{turn.seq}",
                   principal: "process:tightbeam",
                   owner_lease: turn.owner_lease,
                   detail: detail
                 }) do
            {:ok, value}
          else
            {:error, reason} -> {:error, {stage, {:lifecycle_trace_failed, reason}}}
          end

        {:error, reason} ->
          with :ok <- trace_stage_failed(db, turn, stage, reason) do
            {:error, {stage, reason}}
          end
      end
    else
      {:error, reason} -> {:error, {stage, {:lifecycle_trace_failed, reason}}}
    end
  end

  defp traced_prompt(db, turn, adapter, harness_session_id, live_progress) do
    with :ok <- trace_stage_started(db, turn, :prompt) do
      result =
        traced_call(db, turn, :prompt, fn ->
          Adapter.prompt(adapter, harness_session_id, turn.prompt,
            progress: live_progress,
            trace_dispatch: fn request_id -> trace_prompt_dispatch(db, turn, request_id) end,
            trace_progress: fn observation, seq ->
              trace_progress_observation(db, turn, observation, seq)
            end
          )
        end)

      trace_prompt_result(db, turn, result)
    else
      {:error, reason} -> {:error, {:prompt, {:lifecycle_trace_failed, reason}}}
    end
  end

  defp trace_prompt_result(db, turn, {:ok, value}) do
    with :ok <-
           trace_event(db, turn.seq, %{
             event_key: "prompt:resolved",
             producer_event_id: "gateway:prompt:resolved",
             kind: "prompt_resolved",
             stage: "prompt",
             outcome: "delivered",
             cause: "acp:response",
             principal: "process:tightbeam",
             owner_lease: turn.owner_lease,
             detail: %{v: 1, result: "delivered"}
           }),
         :ok <-
           trace_event(db, turn.seq, %{
             event_key: "prompt:succeeded",
             producer_event_id: "gateway:prompt:succeeded",
             kind: "stage_succeeded",
             stage: "prompt",
             outcome: "succeeded",
             cause: "turn:#{turn.seq}",
             principal: "process:tightbeam",
             owner_lease: turn.owner_lease,
             detail: %{v: 1}
           }) do
      {:ok, value}
    else
      {:error, reason} ->
        {:error, {:prompt, {:lifecycle_trace_failed_after_prompt, :resolution, reason}}}
    end
  end

  defp trace_prompt_result(db, turn, {:error, {:acp_request_not_dispatched, reason}}) do
    case trace_stage_failed(db, turn, :prompt, reason) do
      :ok ->
        {:error, {:prompt, reason}}

      {:error, trace_reason} ->
        {:error, {:prompt, {:lifecycle_trace_failed_after_prompt, :resolution, trace_reason}}}
    end
  end

  defp trace_prompt_result(db, turn, {:error, reason}) do
    trace_result =
      with :ok <-
             trace_event(db, turn.seq, %{
               event_key: "prompt:resolved",
               producer_event_id: "gateway:prompt:resolved",
               kind: "prompt_resolved",
               stage: "prompt",
               outcome: "failed",
               cause: "acp:response",
               principal: "process:tightbeam",
               owner_lease: turn.owner_lease,
               detail: %{v: 1, result: "failed"}
             }),
           :ok <- trace_stage_failed(db, turn, :prompt, reason) do
        :ok
      end

    cond do
      match?({:lifecycle_trace_failed_after_prompt, _, _}, reason) ->
        {:error, {:prompt, reason}}

      trace_result == :ok ->
        {:error, {:prompt, reason}}

      true ->
        {:error, {:prompt, {:lifecycle_trace_failed_after_prompt, :resolution, trace_result}}}
    end
  end

  defp trace_stage_started(db, turn, stage) do
    trace_event(db, turn.seq, %{
      event_key: "#{stage}:started",
      producer_event_id: "gateway:#{stage}:started",
      kind: "stage_started",
      stage: Atom.to_string(stage),
      outcome: "started",
      cause: "turn:#{turn.seq}",
      principal: "process:tightbeam",
      owner_lease: turn.owner_lease,
      detail: %{v: 1}
    })
  end

  defp trace_stage_failed(db, turn, stage, reason) do
    trace_event(db, turn.seq, %{
      event_key: "#{stage}:failed",
      producer_event_id: "gateway:#{stage}:failed",
      kind: "stage_failed",
      stage: Atom.to_string(stage),
      outcome: "failed",
      cause: "turn:#{turn.seq}",
      principal: "process:tightbeam",
      owner_lease: turn.owner_lease,
      detail: Map.put(TurnLifecycle.failure_detail(reason), :v, 1)
    })
  end

  defp trace_prompt_dispatch(db, turn, request_id) do
    trace_event(db, turn.seq, %{
      event_key: "prompt:dispatched",
      producer_event_id: "acp:#{turn.owner_lease}:request:#{request_id}:prompt-dispatched",
      kind: "prompt_dispatched",
      stage: "prompt",
      outcome: "dispatched",
      cause: "acp:port-write",
      principal: "process:tightbeam",
      owner_lease: turn.owner_lease,
      acp_request_id: request_id,
      detail: %{v: 1}
    })
  end

  defp trace_progress_observation(db, turn, observation, seq) do
    trace_event(db, turn.seq, %{
      event_key: "progress:#{seq}",
      producer_event_id: "adapter:#{turn.owner_lease}:progress:#{seq}",
      kind: "progress_observed",
      stage: "prompt",
      outcome: "observed",
      cause: "acp:session-update",
      principal: "process:tightbeam",
      owner_lease: turn.owner_lease,
      detail: %{v: 1, class: observation.class, label: observation.label}
    })
  end

  defp trace_event(db, turn_seq, event) do
    case TurnLifecycle.append(db, turn_seq, event) do
      result when result in [:ok, :duplicate, :legacy] -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp trace_call(fun) do
    case fun.() do
      result when result in [:ok, :duplicate, :legacy] -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_trace_result, other}}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp traced_call(db, turn, stage, fun) do
    fun.()
  rescue
    error ->
      _ = trace_stage_failed(db, turn, stage, error)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      _ = trace_stage_failed(db, turn, stage, {kind, reason})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # The adapter groups chunks by ACP's public messageId. Commit the whole set
  # before publishing any row so a crash cannot expose half of one turn's
  # assistant messages. Legacy adapters and test doubles return only `text`;
  # they keep the historical one-row behavior through the fallback below.
  defp append_assistant_messages(db, turn, echo, result) do
    texts = assistant_message_texts(result)
    attention_tier = elected_attention(db, turn.seq)

    case DB.transaction(db, fn txn ->
           replies =
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

               Tightbeam.Firehose.Publisher.message_in_txn(txn, turn.session_key, reply)
               reply
             end)

           TurnLifecycle.append_in_txn(txn, turn.seq, %{
             event_key: "assistant:committed",
             producer_event_id: "projection:assistant:committed",
             kind: "assistant_committed",
             outcome: "committed",
             cause: "projection:append",
             principal: "process:tightbeam",
             owner_lease: turn.owner_lease,
             detail: %{v: 1, messageCount: length(replies)}
           })

           replies
         end) do
      {:ok, replies} ->
        Enum.each(replies, &publish_message(db, turn.session_key, &1))
        :ok

      {:error, reason} ->
        {:error, {:assistant_commit, reason}}
    end
  end

  defp assistant_message_texts(%{messages: messages}) when is_list(messages) and messages != [] do
    Enum.map(messages, &Map.fetch!(&1, :text))
  end

  defp assistant_message_texts(%{text: text}) when is_binary(text), do: [text]

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
    case Tightbeam.SessionLane.cancel_current(call.session_key,
           cause: "cancel-request",
           principal: TurnLifecycle.principal(Map.get(call, :principal, call.origin))
         ) do
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

  defp settle_turn_result(db, call) do
    with {:user, user_id} <- Map.get(call, :principal),
         %{is_admin: true} <- Devices.user(db, user_id),
         {:ok, request} <- StaleTurnSettlement.request(call.params, {:user, user_id}) do
      case StaleTurnSettlement.replay_precheck(db, request) do
        {:ok, result} ->
          public_settlement_result(result)

        {:error, refusal} ->
          refusal

        :continue ->
          case Org.get(db, request.session_key) do
            nil ->
              %{code: "session_not_found", message: "session not found"}

            %{state: state} when state != "active" ->
              %{code: "session_retired", message: "session is not active"}

            _active ->
              case LaneManager.ensure_settlement_lane(
                     Tightbeam.LaneManager,
                     request.session_key
                   ) do
                {:ok, lane_pid, reservation_token} ->
                  case Tightbeam.SessionLane.settle_stale(
                         lane_pid,
                         reservation_token,
                         request
                       ) do
                    {:ok, result} -> public_settlement_result(result)
                    {:error, refusal} -> refusal
                  end

                {:error, _reason} ->
                  %{code: "turn_status_ambiguous", message: "turn liveness is ambiguous"}
              end
          end
      end
    else
      {:error, refusal} -> refusal
      _ -> %{code: "not_authorized", message: "admin user required"}
    end
  end

  defp public_settlement_result(result),
    do: Map.drop(result, [:message_id, :stored_error])

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

  defp harness_session(config, db, adapter, generation, session, _turn_seq) do
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
              stamp_session_identity(db, session.session_key, snapshot)
              {:ok, %{id: sid, mode: "new"}}
            end
          end)

        pointer ->
          # The adapter PROCESS is the authority on residency: stamped
          # generations reset across boots and can spuriously match.
          case Adapter.knows_session_for_turn?(adapter, pointer.harness_session_id) do
            true ->
              case push_known_model_for_turn(adapter, pointer.harness_session_id, session.model) do
                :ok -> {:ok, %{id: pointer.harness_session_id, mode: "reuse"}}
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

                        stamp_session_identity(db, session.session_key, snapshot)
                        {:ok, %{id: pointer.harness_session_id, mode: "load"}}

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
                          stamp_session_identity(db, session.session_key, snapshot)
                          append_context_reset_marker(db, session)
                          {:ok, %{id: sid, mode: "new"}}
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
      {:ok, %{id: _sid, mode: _mode}} = success ->
        success

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

    Placement.materialize_identity(config, session, snapshot)
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
          case Roles.create_with_firehose!(
                 db,
                 call.params[:name],
                 caller.owner_user_id,
                 call.params[:bind],
                 call
               ) do
            {:error, error} -> error
            role -> %{role: role}
          end
        else
          {:error, error} -> error
        end
    end
  end

  defp identity_edit_result(config, db, call) do
    p = call.params
    target = identity_edit_target(p)

    candidate =
      Identity.edit!(
        config.base_dir,
        p.archetype,
        target,
        p[:content],
        call.origin
      )

    publish_identity_candidate(config, db, call, candidate, %{})
  end

  defp identity_edit_target(%{skill: name, remove: remove}) when is_binary(name),
    do: {:skill, name, remove}

  defp identity_edit_target(%{manifest: true}), do: :manifest
  defp identity_edit_target(_params), do: :guidance

  defp identity_relearn_result(config, db, %{params: %{action: "abort"}} = call) do
    :ok = Identity.abort_relearn!(config.base_dir)
    accepted_without_state(db, call)
    %{state: "aborted", live_revision: Identity.live_revision!(config.base_dir)}
  end

  defp identity_relearn_result(config, db, %{params: %{action: "resolve"}} = call) do
    candidate = Identity.resolve_relearn!(config.base_dir, call.origin)
    publish_identity_candidate(config, db, call, candidate, %{state: "published"})
  end

  defp identity_relearn_result(config, db, call) do
    case Identity.relearn!(config.base_dir, call.origin) do
      {:ok, candidate} ->
        publish_identity_candidate(config, db, call, candidate, %{state: "published"})

      {:conflict, paths} ->
        accepted_without_state(db, call)

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

  defp identity_learn_result(config, db, call) do
    case Identity.learn!(config.base_dir, call.params.name, call.origin) do
      {:ok, candidate} ->
        publish_identity_candidate(config, db, call, candidate, %{
          state: "published",
          kungfu: call.params.name
        })

      {:noop, revision} ->
        reload_law!(config)

        stamp_served_publication(
          config,
          db,
          call,
          %{state: "already-learned", kungfu: call.params.name, live_revision: revision}
        )

      {:conflict, paths} ->
        accepted_without_state(db, call)

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
    invocation_id = Map.fetch!(call, :invocation_id)

    case Org.release_archetypes(
           db,
           archetypes,
           fn txn ->
             candidate = Identity.unlearn!(config.base_dir, name, call.origin)

             marker =
               AdminProjection.begin_identity_publication_in_txn(
                 txn,
                 invocation_id,
                 candidate,
                 call.origin
               )

             {candidate, marker}
           end,
           fn {candidate, marker} ->
             case Identity.publish_live!(config.base_dir, candidate) do
               {:ok, revision} ->
                 # The pending marker committed before this ref move. The DB
                 # owner still fences reference writers until law reloads.
                 reload_law!(config)
                 {:published, marker, revision}

               {:error, error} ->
                 {:denied, marker, error}
             end
           end
         ) do
      {:referenced, references} ->
        unlearn_referenced_result(name, references)

      {:released, {:published, marker, revision}} ->
        stamp_served_publication(
          config,
          db,
          call,
          %{state: "published", kungfu: name, live_revision: revision},
          before_stamp: fn txn ->
            AdminProjection.finish_identity_publication_in_txn(txn, marker, "accepted")
          end
        )

      {:released, {:denied, marker, error}} ->
        {:ok, :ok} =
          DB.transaction(db, fn txn ->
            AdminProjection.finish_identity_publication_in_txn(
              txn,
              marker,
              "denied",
              error.code,
              error
            )
          end)

        error
    end
  end

  defp publish_identity_candidate(config, db, call, candidate, result) do
    invocation_id = Map.get(call, :invocation_id, "identity-" <> Tightbeam.Id.uuid4())

    with {:ok, marker} <-
           AdminProjection.begin_identity_publication(
             db,
             invocation_id,
             candidate,
             call.origin
           ) do
      case marker.state do
        "accepted" ->
          Map.put(result, :live_revision, marker.candidate_revision)

        "denied" ->
          identity_denial_result(marker)

        "pending" ->
          case Identity.publish_live!(config.base_dir, candidate) do
            {:ok, revision} ->
              reload_law!(config)

              stamp_served_publication(
                config,
                db,
                call,
                Map.put(result, :live_revision, revision),
                before_stamp: fn txn ->
                  AdminProjection.finish_identity_publication_in_txn(txn, marker, "accepted")
                end
              )

            {:error, error} ->
              {:ok, _marker} =
                DB.transaction(db, fn txn ->
                  AdminProjection.finish_identity_publication_in_txn(
                    txn,
                    marker,
                    "denied",
                    error.code,
                    error
                  )

                  AdminProjection.identity_publication_marker(
                    txn,
                    marker.invocation_id,
                    marker.expected_prior
                  )
                end)

              error
          end
      end
    else
      {:error, error} -> %{code: "identity_marker_failed", message: Exception.message(error)}
    end
  end

  defp stamp_served_publication(config, db, call, result, opts \\ []) do
    case AdminProjection.stamp_publication(
           db,
           call,
           AdminProjection.served_entries(db, config.base_dir),
           opts
         ) do
      {:ok, _changed} -> result
      {:error, error} -> error
    end
  end

  defp accepted_without_state(db, call) do
    case DB.transaction(db, fn txn ->
           Tightbeam.Firehose.Publisher.maybe_observed_accepted_in_txn(txn, call)
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
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
        harness = Harness.parse!(session.harness).id()
        expected = Identity.snapshot_at!(config.base_dir, live, session.archetype, harness)

        reasons =
          [
            if(
              is_nil(session.identity_render_contract) or is_nil(session.identity_guidance_digest),
              do: "missing_render_stamp"
            ),
            if(session.identity_revision != live, do: "revision_mismatch"),
            if(
              not is_nil(session.identity_render_contract) and
                session.identity_render_contract != expected.render_contract,
              do: "contract_mismatch"
            ),
            if(
              not is_nil(session.identity_guidance_digest) and
                session.identity_guidance_digest != expected.guidance_digest,
              do: "guidance_digest_mismatch"
            )
          ]
          |> Enum.reject(&is_nil/1)

        %{
          session_key: session.session_key,
          identity_revision: session.identity_revision,
          identity_render_contract: session.identity_render_contract,
          identity_guidance_digest: session.identity_guidance_digest,
          expected_identity_revision: live,
          expected_render_contract: expected.render_contract,
          expected_guidance_digest: expected.guidance_digest,
          identity_stale: reasons != [],
          identity_stale_reasons: reasons
        }
      end)

    guidance =
      case call.params[:archetype] do
        archetype when is_binary(archetype) ->
          Map.new(Harness.all(), fn module ->
            snapshot = Identity.snapshot_at!(config.base_dir, live, archetype, module.id())
            {module.id(), snapshot.guidance}
          end)

        nil ->
          nil
      end

    public_identity = public_served_identity(db, call)

    identity
    |> Map.put(:identity, public_identity)
    |> Map.put(:sessions, sessions)
    |> maybe_put_guidance(guidance)
  end

  defp maybe_put_guidance(status, nil), do: status
  defp maybe_put_guidance(status, guidance), do: Map.put(status, :guidance, guidance)

  defp public_served_identity(db, call) do
    request_binding = make_ref()
    principal_binding = identity_query_principal(db, call)

    try do
      with {:ok, descriptor} <-
             StateResources.query_identity(
               db,
               {:metadata, "served", request_binding, principal_binding}
             ),
           true <- identity_principal_visible?(db, principal_binding),
           {:ok, hydrated} <-
             hydrate_served_identity(
               db,
               descriptor,
               request_binding,
               principal_binding
             ) do
        StateResources.identity(hydrated)
      else
        false -> nil
        :not_found -> nil
        :stale -> nil
        {:error, :invalid_identity_descriptor} -> nil
      end
    after
      :ok = StateResources.query_identity(db, {:close, request_binding})
    end
  end

  defp hydrate_served_identity(db, descriptor, request_binding, principal_binding) do
    case StateResources.query_identity(
           db,
           {:hydrate, descriptor, request_binding, principal_binding}
         ) do
      :stale ->
        with {:ok, retry_descriptor} <-
               StateResources.query_identity(
                 db,
                 {:metadata, "served", request_binding, principal_binding}
               ),
             true <- identity_principal_visible?(db, principal_binding) do
          case StateResources.query_identity(
                 db,
                 {:hydrate, retry_descriptor, request_binding, principal_binding}
               ) do
            :stale -> :not_found
            other -> other
          end
        else
          false -> :not_found
        end

      other ->
        other
    end
  end

  defp identity_query_principal(_db, %{auth_principal: principal}) when not is_nil(principal),
    do: principal

  defp identity_query_principal(_db, %{principal: principal}) when not is_nil(principal) do
    normalize_identity_principal(principal)
  end

  defp identity_query_principal(db, call) do
    case principal_caller(db, call) do
      %{caller_session: %{session_key: session_key}} when is_binary(session_key) ->
        {:session, session_key}

      %{owner_user_id: user_id} when is_binary(user_id) ->
        {:user, user_id}

      _ ->
        nil
    end
  end

  defp normalize_identity_principal({:session, session_key}) when is_binary(session_key),
    do: {:session, session_key}

  defp normalize_identity_principal({:user, user_id}) when is_binary(user_id),
    do: {:user, user_id}

  defp normalize_identity_principal({:process, name}) when is_binary(name),
    do: {:process, name}

  defp normalize_identity_principal("user:" <> user_id), do: {:user, user_id}
  defp normalize_identity_principal("process:" <> name), do: {:process, name}
  defp normalize_identity_principal(_principal), do: nil

  defp identity_principal_visible?(db, principal_binding) do
    Tightbeam.StateVisibility.identity_visible?(principal_binding_admin?(db, principal_binding))
  end

  defp principal_binding_admin?(db, {:session, session_key}) do
    case Org.get(db, session_key) do
      %{owner_user_id: user_id} ->
        match?(%{is_admin: true}, Devices.user(db, user_id))

      _ ->
        false
    end
  end

  defp principal_binding_admin?(db, {:user, user_id}) do
    match?(%{is_admin: true}, Devices.user(db, user_id))
  end

  defp principal_binding_admin?(_db, _principal_binding), do: false

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
      nil ->
        harness = Harness.parse!(session.harness).id()
        snapshot = served_snapshot(config, session, harness, revision)
        stamp_session_identity(db, session.session_key, snapshot)
        :applied

      pointer ->
        identity_apply_at_lane(config, db, session, revision, pointer)
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
      stamp_session_identity(db, session.session_key, snapshot)
      :applied
    else
      # No resident session to bounce, so the stamp IS the application. The next
      # start reloads from `session.identity_revision`, not from `live`, so
      # leaving the stamp behind would mean this session materialized stale
      # forever while `identity status` kept calling it stale and apply kept
      # reporting it applied. No pointer event is appended: nothing was loaded,
      # and the pointer chain does not record things that did not happen.
      false ->
        stamp_session_identity(db, session.session_key, snapshot)
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

  defp stamp_session_identity(db, session_key, snapshot) do
    Org.set_identity_stamp(
      db,
      session_key,
      snapshot.revision,
      snapshot.render_contract,
      snapshot.guidance_digest
    )
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

  defp onboard_result(config, %{params: %{provider: provider, phase: phase} = params} = call)
       when provider in @onboarding_providers and phase in ["begin", "finish", "cancel"] do
    machine = params[:machine] || Placement.local_host_name()

    with true <- Map.has_key?(Placement.hosts(config.base_dir, gateway_db(config)), machine),
         {:ok, kind} <- onboarding_kind(params[:kind]) do
      config
      |> onboard_phase(
        provider_atom(provider),
        phase,
        machine,
        kind,
        params[:lease_id],
        params[:reason],
        onboarding_caller(gateway_db(config), call)
      )
      |> with_owner_user_id(phase, gateway_db(config), call.origin)
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

  defp onboard_phase(config, provider, "begin", machine, kind, _lease_id, _reason, _caller) do
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

  defp onboard_phase(config, provider, "finish", machine, kind, lease_id, _reason, caller) do
    case Tightbeam.Credentials.finish_onboard(
           provider,
           kind,
           lease_id,
           Tightbeam.Credentials.server(machine)
         ) do
      :ok ->
        finish_onboard_result(config, caller, provider, machine, kind)

      {:error, reason} ->
        %{
          code: "needs_onboarding",
          message: "#{provider} #{kind} credential on #{machine}: #{inspect(reason)}"
        }
    end
  end

  defp onboard_phase(_config, provider, "cancel", machine, _kind, lease_id, reason, _caller) do
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

  defp finish_onboard_result(config, caller, provider, machine, :subscription)
       when provider in [:openai, :anthropic] do
    case schedule_oauth_recovery_wake(config, caller, provider, machine) do
      :ok ->
        onboarded_result(provider, :subscription)

      {:error, reason} ->
        %{
          code: "credential_recovered_wake_failed",
          message:
            "#{provider} subscription credential on #{machine} recovered, but its Main " <>
              "recovery wake could not be scheduled: #{describe_error(reason)}",
          provider: provider,
          host: machine,
          credential_recovered: true,
          wake_scheduled: false
        }
    end
  end

  defp finish_onboard_result(_config, _caller, provider, _machine, :subscription),
    do: onboarded_result(provider, :subscription)

  defp finish_onboard_result(_config, _caller, provider, _machine, :api_key),
    do: onboarded_result(provider, :api_key)

  # The result the CLI prints names the kind that was banked in the wire
  # vocabulary. `wire_credential_kind/1` is the single translation boundary.
  defp onboarded_result(provider, kind),
    do: %{provider: provider, credential_kind: wire_credential_kind(kind), status: "onboarded"}

  # OAuth recovery is one neutral event instruction to the authenticated
  # operator's native Main. Main, not the credential substrate, reads Kung Fu
  # manifests and selects live agents. API-key completion never reaches here.
  defp schedule_oauth_recovery_wake(
         config,
         %{owner_user_id: owner},
         provider,
         machine
       )
       when is_binary(owner) do
    prompt =
      "The OAuth token for #{provider} on #{machine} was refreshed. " <>
        "Read the manifests for every installed or learned Kung Fu. " <>
        "Read each manifest's declared main archetype. " <>
        "Find live agents with those archetypes. " <>
        "Notify each that the OAuth token was refreshed, and require each to inspect and " <>
        "resume any stalled agent graph."

    case DB.transaction(gateway_db(config), fn txn ->
           Wakes.schedule_in_txn(txn, %{
             session_key: Org.personal_session_key(owner),
             origin: "process:tightbeam",
             prompt: prompt,
             consumer: "prompt",
             due_at: System.system_time(:millisecond),
             target_gate: 1
           })
         end) do
      {:ok, _wake} ->
        Wakes.fire_due(Map.get(config, :wake_scheduler, Tightbeam.WakeScheduler))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_oauth_recovery_wake(_config, _caller, _provider, _machine),
    do: {:error, :authenticated_operator_unavailable}

  defp onboarding_caller(_db, %{principal: {:user, owner}}) when is_binary(owner),
    do: %{owner_user_id: owner, caller_session: nil}

  defp onboarding_caller(db, %{principal: {:session, session_key}}) do
    case Org.get(db, session_key) do
      %{owner_user_id: owner} = session -> %{owner_user_id: owner, caller_session: session}
      nil -> nil
    end
  end

  defp onboarding_caller(db, call), do: resolve_caller(db, call.origin)

  # The begin reply carries the OWNER user id so the CLI can wake THAT user with the
  # sign-in URL+code the ceremony is about to surface (wi_0535922b). An onboarding run
  # in a session no operator watches must deliver its URL+code out of band, and the
  # gateway is the only party that knows whose org this is. Added ONLY to the begin
  # "ready" reply; finish/cancel and every error map pass through untouched. An origin
  # with no owner (a process principal) leaves the field absent, and the CLI degrades
  # loudly rather than waking no one.
  defp with_owner_user_id(%{status: "ready"} = reply, "begin", db, origin) do
    case resolve_caller(db, origin) do
      %{owner_user_id: owner} when is_binary(owner) ->
        Map.put(reply, :owner_user_id, owner)

      _ ->
        reply
    end
  end

  defp with_owner_user_id(reply, _phase, _db, _origin), do: reply

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
         :ok <- Roles.bind_with_firehose(db, name, session_key, call) do
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
         :ok <- Roles.rm_with_firehose(db, name, call) do
      %{removed: name}
    else
      nil -> %{code: "unknown_role", message: "unknown role: #{name}"}
      {:error, error} -> error
    end
  end

  defp read_marker_result(db, call, operation) do
    scope_key = call.params[:scope_key]
    marker = if operation == :clear, do: nil, else: call.params[:marker]

    with true <- is_binary(scope_key) and scope_key != "",
         true <- operation == :clear or valid_read_marker?(marker),
         %{owner_user_id: user_id} when is_binary(user_id) <- resolve_caller(db, call.origin) do
      case Tightbeam.ReadMarkers.set(db, user_id, scope_key, marker,
             expected?: Map.has_key?(call.params, :expected_current),
             expected: call.params[:expected_current],
             firehose_call: call
           ) do
        {:error, error} ->
          error

        {:ok, changed, row} ->
          %{changed: changed, read_marker: row, user_id: user_id}
      end
    else
      false ->
        %{code: "invalid", message: "scopeKey and a row-id or timestamp marker are required"}

      _ ->
        %{code: "unknown_caller"}
    end
  end

  defp valid_read_marker?(marker) when is_integer(marker), do: marker >= 0
  defp valid_read_marker?(marker) when is_binary(marker), do: marker != ""
  defp valid_read_marker?(_marker), do: false

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
  # session, and the caller is above it in the operational-parent lineage, or is the
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

  defp caller_in_lineage_above?(_db_or_txn, _scope, _caller_key, hops) when hops > 32,
    do: false

  defp caller_in_lineage_above?(%Txn{} = txn, scope, caller_key, hops) do
    parent = Org.effective_parent_in_txn(txn, scope).session_key

    cond do
      parent == caller_key -> true
      parent == scope -> false
      true -> caller_in_lineage_above?(txn, parent, caller_key, hops + 1)
    end
  rescue
    ArgumentError -> false
  end

  defp caller_in_lineage_above?(db, scope, caller_key, hops) do
    case DB.transaction(db, fn txn -> caller_in_lineage_above?(txn, scope, caller_key, hops) end) do
      {:ok, authorized?} -> authorized?
      {:error, _error} -> false
    end
  end

  defp admin_origin?(db, origin) do
    case resolve_caller(db, origin) do
      %{owner_user_id: user_id} -> match?(%{is_admin: true}, Devices.user(db, user_id))
      _ -> false
    end
  end

  defp config_result(db, %{params: %{action: "get", setting: "default-archetype"}}) do
    item = StateResources.query_config(db, "default-archetype")

    %{
      setting: "default-archetype",
      value: Org.get_setting(db, "default-archetype") || "default",
      config: item && StateResources.config(item)
    }
  end

  defp config_result(db, %{params: %{action: "get", setting: "default-priority"}}) do
    item = StateResources.query_config(db, "default-priority")

    %{
      setting: "default-priority",
      value: parse_default_priority(Org.get_setting(db, "default-priority")),
      config: item && StateResources.config(item)
    }
  end

  defp config_result(
         db,
         %{
           params: %{
             action: "set",
             setting: "default-archetype",
             value: archetype_name
           }
         } = call
       ) do
    case DB.transaction(db, fn txn ->
           if Archetypes.get(archetype_name) do
             result =
               put_setting_projected_in_txn(txn, "default-archetype", archetype_name)

             Tightbeam.Firehose.Publisher.maybe_observed_accepted_in_txn(txn, call)

             if result.changed do
               Tightbeam.Firehose.Publisher.committed_in_txn(
                 txn,
                 "config.updated",
                 result.projection,
                 %{"key" => "default-archetype"}
               )
             end

             {:ok, result}
           else
             {:error, :unknown_archetype}
           end
         end) do
      {:ok, {:ok, result}} ->
        %{
          setting: "default-archetype",
          value: archetype_name,
          config: StateResources.config(result.projection),
          changed: result.changed
        }

      {:ok, {:error, :unknown_archetype}} ->
        %{code: "unknown_archetype", message: "no such archetype: #{archetype_name}"}

      {:error, error} ->
        raise error
    end
  end

  defp config_result(
         db,
         %{params: %{action: "set", setting: "default-priority", value: priority}} = call
       ) do
    if is_integer(priority) and priority in 0..8 do
      value = Integer.to_string(priority)

      case DB.transaction(db, fn txn ->
             result = put_setting_projected_in_txn(txn, "default-priority", value)
             Tightbeam.Firehose.Publisher.maybe_observed_accepted_in_txn(txn, call)

             if result.changed do
               Tightbeam.Firehose.Publisher.committed_in_txn(
                 txn,
                 "config.updated",
                 result.projection,
                 %{"key" => "default-priority"}
               )
             end

             result
           end) do
        {:ok, result} ->
          %{
            setting: "default-priority",
            value: priority,
            config: StateResources.config(result.projection),
            changed: result.changed
          }

        {:error, error} ->
          raise error
      end
    else
      %{code: "invalid_priority", message: "priority must be an integer from 0 through 8"}
    end
  end

  defp config_result(_db, _call) do
    %{
      code: "invalid",
      message: "config supports get/set default-archetype or default-priority"
    }
  end

  defp parse_default_priority(nil), do: 4
  defp parse_default_priority(value), do: String.to_integer(value)

  defp put_setting_projected_in_txn(txn, key, value),
    do: Org.put_setting_projected_in_txn(txn, key, value)

  defp admin_handler(db, fun) do
    fn call ->
      if admin_origin?(db, call.origin),
        do: fun.(call.params),
        else: %{code: "forbidden", message: "admin required"}
    end
  end

  defp admin_call_handler(db, fun) do
    fn call ->
      principal_binding = identity_query_principal(db, call)

      if principal_binding_admin?(db, principal_binding) do
        fun.(Map.put(call, :auth_principal, principal_binding))
      else
        %{code: "forbidden", message: "admin required"}
      end
    end
  end

  defp identity_mutation_handler(config, db, fun) do
    admin_call_handler(db, fn call ->
      invocation_id = Map.get(call, :invocation_id, "identity-" <> Tightbeam.Id.uuid4())
      call = Map.put(call, :invocation_id, invocation_id)

      case AdminProjection.identity_publication_marker_by_invocation(db, invocation_id) do
        nil ->
          try do
            fun.(call)
          rescue
            error in Tightbeam.Identity.IncludeError ->
              denial = %{code: "identity_include_invalid", message: Exception.message(error)}

              {:ok, _marker} =
                AdminProjection.deny_identity_validation(
                  db,
                  invocation_id,
                  error.expected_prior || "none",
                  error.tree_fingerprint || String.duplicate("0", 64),
                  call.origin,
                  Atom.to_string(error.cause),
                  denial
                )

              denial
          end

        %{state: "accepted"} = marker ->
          %{state: "published", live_revision: marker.candidate_revision}

        %{state: "denied"} = marker ->
          identity_denial_result(marker)

        %{state: "pending"} = marker ->
          candidate = %{
            expected_prior: marker.expected_prior,
            candidate_revision: marker.candidate_revision,
            tree_fingerprint: marker.tree_fingerprint
          }

          publish_identity_candidate(config, db, call, candidate, %{state: "published"})
      end
    end)
  end

  defp identity_denial_result(marker) do
    %{code: marker.denial_code || marker.cause || "identity_publication_denied"}
    |> put_present(:message, marker.denial_message)
    |> put_present(:expected, marker.denial_expected)
    |> put_present(:actual, marker.denial_actual)
  end

  defp put_present(result, _key, nil), do: result
  defp put_present(result, key, value), do: Map.put(result, key, value)

  defp notify_session(config, db, session_key, prompt) do
    deliver_prompt(session_key, "process:tightbeam", prompt,
      db: db,
      sender: "process:tightbeam",
      conn_registry: config[:conn_registry] || Tightbeam.ConnRegistry,
      lane_manager: config[:lane_manager] || Tightbeam.LaneManager
    )
  end

  defp wake_delivery_principal(%{creator_session_key: key}) when is_binary(key) and key != "",
    do: {:session, key}

  defp wake_delivery_principal(%{origin: origin}), do: origin

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

      %{owner_user_id: nil} = caller ->
        principal = inspect_principal(call, caller)

        wakes =
          Wakes.list_pending(db)
          |> Enum.filter(&(&1.origin == call.origin))
          |> Enum.map(&Map.take(&1, [:wake_id, :session_key, :due_at, :prompt]))
          |> Enum.map(&inspect_wake(db, &1, principal))

        %{wakes: wakes, roles: role_list_result(db).roles}
        |> maybe_put_inspected_batch(db, call, caller)

      caller ->
        sessions = Org.list_for_user(db, caller.owner_user_id, false)
        keys = MapSet.new(sessions, & &1.session_key)
        principal = inspect_principal(call, caller)

        wakes =
          Wakes.list_pending(db)
          |> Enum.filter(&MapSet.member?(keys, &1.session_key))
          |> Enum.map(&inspect_wake(db, &1, principal))

        # F9 (Sol xhigh review): the sanctioned discovery path for a digest
        # carrier's OWN wake id, surviving a cross-harness barrier that hides
        # the delivered digest message which would ordinarily carry it.
        # `wakes` above is scoped to PENDING work and a delivered carrier is
        # not that, so it needs its own read here rather than a filter over
        # the same list.
        digest_carriers =
          sessions
          |> Enum.flat_map(&Wakes.list_digest_carriers(db, &1.session_key))
          |> Enum.map(&Map.take(&1, [:wake_id, :session_key, :class, :created_at, :fired_at]))

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
          digest_carriers: digest_carriers,
          roles: role_list_result(db).roles,
          archetypes: org_shape.archetypes,
          hosts: org_shape.hosts,
          models: org_shape.models
        }

        result =
          if admin_origin?(db, call.origin) do
            pending =
              Devices.list_pending(db)
              |> Enum.map(&Map.take(&1, [:device_id, :claimed_name, :user_id, :platform, :model]))

            Map.put(result, :pending_devices, pending)
          else
            result
          end

        maybe_put_inspected_batch(result, db, call, caller)
    end
  end

  defp inspect_wake(db, wake, principal) do
    refs =
      db
      |> NoticeBatcher.source_refs(wake.wake_id)
      |> Enum.filter(fn ref ->
        NoticeBatcher.read_batch(db, ref.batch_id, principal) != nil
      end)

    case refs do
      [] -> wake
      refs -> Map.put(wake, :batch_refs, refs)
    end
  end

  defp maybe_put_inspected_batch(result, db, call, caller) do
    case call.params[:batch_id] do
      batch_id when is_binary(batch_id) and batch_id != "" ->
        principal = inspect_principal(call, caller)
        Map.put(result, :batch, NoticeBatcher.read_batch(db, batch_id, principal))

      _ ->
        result
    end
  end

  defp inspect_principal(%{principal: {kind, id} = principal}, _caller)
       when kind in [:user, :session, :process] and is_binary(id) and id != "",
       do: principal

  defp inspect_principal(%{origin: "user:" <> user_id}, _caller), do: {:user, user_id}

  defp inspect_principal(%{origin: "process:" <> process_id}, _caller),
    do: {:process, process_id}

  defp inspect_principal(_call, %{caller_session: %{session_key: session_key}}),
    do: {:session, session_key}

  defp inspect_principal(_call, _caller), do: nil

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
      result =
        DB.transaction(db, fn txn ->
          visible? = fn candidate ->
            Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId = ?1 AND origin = ?2", [
              candidate,
              call.origin
            ]) == [[1]]
          end

          result =
            case IdPrefix.resolve_in_txn(txn, :wake, wake_id, visible?) do
              {:ok, resolved} ->
                id_resolved(call, txn, :wake, resolved)

                result =
                  Wakes.cancel_in_txn(txn, %{
                    wake_id: resolved,
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
                  })

                if match?({:accepted_in_txn, _event_id, %{canceled: true}}, result) do
                  Tightbeam.Firehose.Publisher.observed_accepted_in_txn(txn, call)
                  Wakes.publish_change_in_txn(txn, "wake.canceled", resolved)
                end

                result

              :unknown ->
                Tightbeam.Firehose.Publisher.maybe_observed_accepted_in_txn(txn, call)
                false

              {:ambiguous, error} ->
                error
            end

          result
        end)

      case result do
        {:ok, {:accepted_in_txn, event_id, %{canceled: true}}}
        when is_integer(event_id) and event_id > 0 ->
          {:accepted_in_txn, event_id, %{canceled: true}}

        {:ok, false} ->
          %{canceled: false}

        {:ok, %{code: _} = error} ->
          error

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

  defp id_resolved(call, txn, type, id) do
    case Map.get(call, :on_id_resolved_in_txn) do
      fun when is_function(fun, 3) -> fun.(txn, type, id)
      _ -> :ok
    end
  end

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

            wake =
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

            if is_map(wake) and not Map.has_key?(wake, :code),
              do: Tightbeam.Firehose.Publisher.maybe_accepted_in_txn(txn, call, wake)

            wake
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

    case revalidate_supervision_delivery_in_txn(txn, call) do
      :ready ->
        schedule_validated_wake_row_in_txn(
          txn,
          call,
          session_key,
          due_at,
          condition_kind,
          condition_scope
        )

      reason when reason in [:suppressed, :stale] ->
        %{suppressed: true, reason: reason, assignment_id: p[:assignment_id]}
    end
  end

  defp schedule_validated_wake_row_in_txn(
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
        # THE SENDER ELECTS (fabric §7), and election is how traffic ENTERS the
        # fabric on this line. A wake with no `--class` carries no class and is
        # delivered exactly as it was before Phase 1 — the substrate does not
        # decide on the sender's behalf that an existing message "was really an
        # fyi" and hold it for four hours (gate Q1/Q2). The classifier's default
        # stamps traffic routed INTO the fabric that declined to elect; Phase 3's
        # desk is where the receiving boundary starts doing that.
        #
        # `sender_scheduled` is the batcher's named inhibition seam: a caller
        # that said WHEN keeps its own when, class or no class.
        class: p[:class],
        sender_scheduled: not is_nil(p[:at]) or not is_nil(p[:after_ms]),
        reresolve: p[:reresolve],
        reresolve_seed: p[:reresolve_seed],
        reresolve_rung: p[:reresolve_rung],
        # `wake` is agent-callable, so an agent-supplied assignment param is never
        # trusted. An agent wake inherits only the caller's exact RUNNING turn in
        # this transaction. Reserved process calls keep their explicit carrier;
        # RailRemedy keeps the canonical assignment it already bound. A free-choice
        # turn has no running carrier and stays honestly NULL.
        assignment_id: wake_assignment_id_in_txn(txn, call)
      })

    bind_liveness_checkpoint_in_txn(txn, call, wake)
    schedule_supervision_controller_in_txn(txn, call, wake)
    wake
  end

  defp revalidate_supervision_delivery_in_txn(
         txn,
         %{
           principal: {:process, "tightbeam"},
           params: %{
             supervision_wake_kind: branch,
             supervision_session_key: session_key,
             supervision_terminal_seq: terminal_seq,
             supervision_k: k,
             supervision_n: n,
             assignment_id: assignment_id
           }
         }
       )
       when branch in ["prod", "escalation"] do
    Supervision.revalidate_delivery_in_txn(txn, %{
      sessionKey: session_key,
      lastEvaluatedTerminal: terminal_seq,
      pendingBranch: branch,
      pendingAssignment: assignment_id,
      pendingK: k,
      pendingN: n
    })
  end

  defp revalidate_supervision_delivery_in_txn(_txn, _call), do: :ready

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
         %{
           principal: {:process, "tightbeam"},
           params: %{
             supervision_wake_kind: wake_kind,
             supervision_terminal_seq: root_turn_seq
           }
         },
         wake
       )
       when wake_kind in ["prod", "escalation"] and is_integer(root_turn_seq) and
              root_turn_seq > 0 do
    case Supervision.transition_in_txn(txn, %{
           kind: "controller_scheduled",
           wake_id: wake.wake_id,
           assignment_id: wake.assignment_id,
           wake_kind: wake_kind,
           root_turn_seq: root_turn_seq
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
    if wake_kind in ["prod", "escalation"] do
      raise "incompatible_supervision_liveness_v1: controller root turn is required"
    else
      raise "incompatible_supervision_liveness_v1: unknown controller kind #{inspect(wake_kind)}"
    end
  end

  defp schedule_supervision_controller_in_txn(_txn, _call, _wake), do: :ok

  defp wake_assignment_id_in_txn(_txn, %{principal: {:process, "tightbeam"}} = call),
    do: call.params[:assignment_id]

  defp wake_assignment_id_in_txn(
         _txn,
         %{
           principal: {:remedy, %{action: "wake"}},
           bound_assignment_id: assignment_id
         }
       )
       when is_binary(assignment_id),
       do: assignment_id

  defp wake_assignment_id_in_txn(txn, %{principal: {:session, session_key}}) do
    case DB.Txn.q(
           txn,
           "SELECT assignmentId FROM turns WHERE sessionKey = ?1 AND status = 'running' LIMIT 1",
           [session_key]
         ) do
      [[assignment_id]] -> assignment_id
      [] -> nil
    end
  end

  defp wake_assignment_id_in_txn(_txn, _call), do: nil

  defp creator_session_key({:session, key}), do: key
  defp creator_session_key(_principal), do: nil

  defp select_wake_in_txn_sql do
    "SELECT wakeId, dueAt, state, class, deliveryRule FROM wakes WHERE wakeId = ?1"
  end

  defp wake_from_in_txn_row([wake_id, due_at, state, class, delivery_rule]),
    do: %{
      wake_id: wake_id,
      due_at: due_at,
      state: state,
      class: class,
      delivery_rule: delivery_rule
    }

  # The response names the rule that decided delivery (fabric §8: an
  # unattributable reflex is a bug), so a sender can see it was batched and
  # knows which reflex to inhibit. Unclassed wakes answer exactly as before.
  defp wake_response(%{class: class} = wake) when is_binary(class) do
    %{
      wake_id: wake.wake_id,
      due_at: wake.due_at,
      state: wake.state,
      class: class,
      delivery_rule: wake[:delivery_rule]
    }
  end

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
            result = spawn_replay(db, prior.session_key)

            {:ok, :ok} =
              DB.transaction(db, fn txn ->
                Tightbeam.Firehose.Publisher.maybe_accepted_in_txn(
                  txn,
                  call,
                  Org.get_in_txn(txn, prior.session_key)
                )
              end)

            result

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

                  Tightbeam.Firehose.Publisher.maybe_accepted_in_txn(txn, call, session)
                  {:created, session}
                end
              else
                {:error, :unknown_archetype}
              end

            prior ->
              session = Org.get_in_txn(txn, prior.session_key)
              Tightbeam.Firehose.Publisher.maybe_accepted_in_txn(txn, call, session)
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

  # THE CLOSED PARAMETER SURFACE FOR TUNE (F6, Sol xhigh review). The CLI's own
  # `tune` flag set is closed (cli/src/args.rs `ALLOWED`) so a caller who
  # mistypes `--modle` learns immediately rather than switching a session to a
  # destination default it never asked for. Raw `/agent/dispatch` has no such
  # gate — `Router.atomize_params/2` forwards whatever the caller sent — and
  # neither does the device mapper's `model_params/1`, which used to DROP a
  # malformed field rather than carry it here to be named. "The server is the
  # contract, the CLI is convenience": the same closed set has to live here,
  # once, for every setting, keyed on the setting the caller named.
  @tune_params_by_setting %{
    "rename" => ~w(setting display_name)a,
    "adopt" => ~w(setting adopted)a,
    "set_harness" => ~w(setting harness model effort context)a,
    "set_host" => ~w(setting host)a,
    "remove_override" => ~w(setting skill guidance)a,
    "set_model" => ~w(setting model effort context)a,
    "set_reasoning" => ~w(setting reasoningLevel)a
  }

  defp tune_result(config, db, call) do
    p = call.params

    case validate_tune_params(p) do
      {:error, denial} -> denial
      :ok -> tune_dispatch(config, db, call, p)
    end
  end

  defp validate_tune_params(p) do
    case Map.get(@tune_params_by_setting, p[:setting]) do
      # An unrecognised setting falls through to `tune_dispatch/4`'s own
      # catch-all ("unsupported"), which already names the actual cause; this
      # gate only judges params against a setting it recognises.
      nil ->
        :ok

      allowed ->
        case Map.keys(p) -- allowed do
          [] -> :ok
          unknown -> {:error, unknown_param_error(unknown)}
        end
    end
  end

  defp unknown_param_error(keys) do
    %{
      ok: false,
      code: "unknown_param",
      message: "tune does not accept #{Enum.map_join(keys, ", ", &to_string/1)} for this setting"
    }
  end

  defp tune_dispatch(config, db, call, p) do
    cond do
      p[:setting] == "rename" and is_binary(p[:display_name]) ->
        # F3 (Sol xhigh review): every tune mutation passes the same
        # owner-or-admin gate `set_harness`/`set_model` already do. This was
        # the pre-existing hole a role-token caller could drive with its own
        # `sessionKey` swapped for a victim's — legacy since before this
        # card, but this card is what made `tune` agent-reachable, so it
        # closes here.
        case tunable_session(db, call) do
          {:error, denial} ->
            denial

          {:ok, session} ->
            updated = Org.rename(db, session.session_key, p.display_name)
            stream = Payloads.stream_session(updated)
            broadcast(db, updated.owner_user_id, Payloads.stream_updated(stream))
            %{stream: stream}
        end

      p[:setting] == "adopt" and is_boolean(p[:adopted]) ->
        case tunable_session(db, call) do
          {:error, denial} ->
            denial

          {:ok, session} ->
            updated = Org.set_adopted(db, session.session_key, p.adopted)
            stream = Payloads.stream_session(updated)
            broadcast(db, updated.owner_user_id, Payloads.stream_updated(stream))
            %{ok: true}
        end

      p[:setting] == "set_harness" and is_binary(p[:harness]) ->
        set_harness_result(config, db, call, p)

      p[:setting] == "set_host" and is_binary(p[:host]) ->
        case tunable_session(db, call) do
          {:error, denial} ->
            denial

          {:ok, session} ->
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
                    case Placement.move_workdir(config, session.session_key, session.host, host) do
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
        # Already gated (`session_mutation_allowed/3`, inside
        # `remove_override_result/3`) — not one of F3's holes, left as-is.
        remove_override_result(config, db, call)

      p[:setting] == "set_model" ->
        # SAME harness, new model: the engine stays, and so does its
        # conversation. Same election, same owner gate, same catalog answer.
        case tunable_session(db, call) do
          {:error, denial} ->
            denial

          {:ok, session} ->
            with :ok <- validate_model_election(p),
                 {:ok, new_ref} <-
                   compose_tune_model_selection(
                     session.host,
                     session.harness,
                     resolve_selection(session.host, session.harness, p, session.model)
                   ) do
              apply_model_change(config, db, call, session, new_ref)
            else
              {:error, denial} -> denial
            end
        end

      p[:setting] == "set_reasoning" and is_binary(p[:reasoningLevel]) ->
        case tunable_session(db, call) do
          {:error, denial} ->
            denial

          {:ok, %{model: nil}} ->
            %{
              ok: false,
              code: "model_unknown",
              message: "reasoning cannot be changed while the current model is unknown"
            }

          {:ok, session} ->
            # A RELATIVE election: new_ref is DERIVED from the snapshot's
            # model, so the snapshot model is part of the election and must
            # still hold at commit (Sol round 4, blocking). set_model is
            # absolute -- the caller named their target -- so it passes no
            # basis and tolerates concurrent effort tweaks.
            new_ref = %{session.model | effort: p.reasoningLevel}
            apply_model_change(config, db, call, session, new_ref, session.model)
        end

      true ->
        %{ok: false, code: "unsupported", message: "tune does not support #{p[:setting]} yet"}
    end
  end

  # THE LIVE ENGINE SWITCH.
  #
  # ADJUDICATION BOUNDARY (v0.2 program §4): this runs because a CALLER named a
  # harness on this request, and for no other reason. The substrate never
  # initiates a switch, never walks a preference list looking for a better
  # engine, and never holds a session pending someone's model decision. A
  # switch is an ELECTION by the agent or user who asked for it; everything
  # below is validation of that election, and every way it can fail is NAMED.
  #
  # The model is named by FIELDS — `--harness`, `--model`, `--effort`,
  # `--context` — never one packed string, and every field is answered by the
  # destination host's catalog. Inventing a harness or a model is refused by
  # name (`unknown_harness`, `model_unavailable`), never guessed at and never
  # silently substituted.
  defp set_harness_result(config, db, call, p) do
    harness = p.harness

    with {:ok, session} <- tunable_session(db, call),
         {:ok, module} <- known_harness(harness),
         :ok <- distinct_harness(session, harness),
         :ok <- validate_model_election(p),
         :ok <- refuse_packed_model(p),
         {:ok, model} <-
           compose_tune_model_selection(
             session.host,
             harness,
             destination_model(session, harness, p)
           ),
         :ok <- validate_credential(config, harness, session.host),
         {:ok, routed} <-
           validate_catalog_model(session.host, harness, model, from_default?(p)),
         :ok <-
           Spinup.ensure_ready(config, module.id(), session.host, spinup_opts(config, db)) do
      # Probe seam (same idiom as `on_swap_interlock`, one window earlier):
      # lets a test PAUSE this request with its ELECTION fully decided —
      # preflight, catalog, credential, readiness — before the boundary below
      # is taken, and commit a competing write in the pause. That is the exact
      # window the stale-election preconditions exist for; without the seam
      # the interleaving cannot be built deterministically from outside (Sol
      # round 2, important 4). BEFORE the boundary, necessarily: inside it the
      # pause would hold the per-session lock the competing request needs.
      # Absent in production.
      case Map.get(call, :on_tune_elected) do
        fun when is_function(fun, 0) -> fun.()
        _ -> :ok
      end

      case at_tune_boundary(config, db, session.session_key, fn ->
             run_session_mutation(session.session_key, fn ->
               apply_harness_change(
                 config,
                 db,
                 call,
                 session,
                 harness,
                 module.id(),
                 model,
                 routed.provider
               )
             end)
           end) do
        {:ok, result} -> result
        {:error, :turn_in_progress} -> turn_in_progress_error()
      end
    else
      {:error, denial} -> denial
    end
  end

  # WHO MAY RE-ENGINE A SESSION: its owner, or an admin. Nobody else, and a
  # `process:` caller never (it resolves with no owner and falls through).
  #
  # This gate exists because a live switch is the one tune setting that
  # replaces the mind answering for a session. It is keyed on `call.origin`,
  # not `call.principal`, because the device path (`/api/session-control`)
  # builds its call without a principal — a principal-keyed gate would deny
  # the chat client its own picker.
  #
  # ONE refusal for unknown, retired, and foreign: which of the three it was
  # is not this caller's business to learn by probing.
  defp tunable_session(db, call) do
    session = Org.get(db, call.session_key)
    caller = principal_caller(db, call)

    case {session, caller} do
      {%{state: "active"} = active, %{owner_user_id: owner}} when is_binary(owner) ->
        if owner == active.owner_user_id or admin_caller?(db, call) or
             repair_tune_authorized?(db, call, active),
           do: {:ok, active},
           else: {:error, tune_not_found()}

      _ ->
        {:error, tune_not_found()}
    end
  end

  defp repair_tune_authorized?(db, %{repair_assignment_id: assignment_id} = call, session) do
    with {:ok, assignment} <- repair_assignment(db, assignment_id),
         true <- assignment.holder == session.session_key,
         :ok <- repair_authorized(db, call, assignment) do
      true
    else
      _ -> false
    end
  end

  defp repair_tune_authorized?(_db, _call, _session), do: false

  # THE CALLER'S IDENTITY IS WHAT THE ROUTER ALREADY PROVED, not a fresh
  # re-resolution of `call.origin`'s role name (F8, Sol xhigh review). A role
  # can be REBOUND to a different session between the router's authentication
  # and this check; `resolve_caller/2` re-reading `"agent:<role>"` at THIS
  # moment would authorize whoever holds the role NOW for a request the
  # router authenticated for whoever held it THEN — a TOCTOU an admin
  # rebinding a role mid-flight could open. The router already resolved that
  # question once, immutably, into `call.principal` (`{:session, key}`) at
  # authentication time; using it here instead closes the gap.
  #
  # Device calls and `--as-user` CLI calls carry NO session principal (they
  # were never role-mediated) and are sound as `call.origin` already reads
  # them — those fall back to the existing resolution, unchanged.
  defp principal_caller(db, %{principal: {:session, session_key}}) do
    case Org.get(db, session_key) do
      %{state: "active"} = caller ->
        %{owner_user_id: caller.owner_user_id, caller_session: caller}

      _ ->
        nil
    end
  end

  defp principal_caller(db, call), do: resolve_caller(db, call.origin)

  # `admin_origin?/2`'s TOCTOU counterpart: the admin bypass must ask the same
  # immutable-principal question `principal_caller/2` does, not re-derive "who
  # holds this role right now" a second time by a different route.
  defp admin_caller?(db, %{principal: {:session, session_key}}) do
    case Org.get(db, session_key) do
      %{owner_user_id: user_id} -> match?(%{is_admin: true}, Devices.user(db, user_id))
      _ -> false
    end
  end

  defp admin_caller?(db, call), do: admin_origin?(db, call.origin)

  defp tune_not_found, do: %{ok: false, code: "not_found", message: "session not found"}

  # `Harness.parse!/1` RAISES on a name this build does not carry, and a raise
  # inside a handler is translated to `server_error` — the substrate reporting
  # its own bug for what is only a caller naming an engine that does not
  # exist. An invented harness is a REFUSAL, named, listing what this build
  # actually offers, exactly as an invented model is refused against the
  # catalog.
  defp known_harness(harness) do
    case Enum.find(Harness.all(), &(&1.wire_name() == harness)) do
      nil ->
        {:error,
         %{
           ok: false,
           code: "unknown_harness",
           message:
             "unknown harness: #{harness}; this build offers " <>
               Enum.map_join(Harness.all(), ", ", & &1.wire_name())
         }}

      module ->
        {:ok, module}
    end
  end

  # Naming the RESIDENT harness is not a switch, and running it as one is
  # destructive: `apply_harness_change` moves the history barrier to MAX(seq)
  # unconditionally, so "switch claude to claude" buries every message in the
  # visible transcript in order to swap an engine for itself. No recorded fact
  # may be hidden to satisfy a request that changes nothing, so this is
  # refused by name. A same-harness model change is `--model` with no
  # `--harness`.
  defp distinct_harness(%{harness: resident}, resident),
    do: {:error, distinct_harness_error(resident)}

  defp distinct_harness(_session, _harness), do: :ok

  defp distinct_harness_error(resident) do
    %{
      ok: false,
      code: "same_harness",
      message:
        "#{resident} is already this session's harness; " <>
          "omit --harness for a same-harness model change"
    }
  end

  # A HARNESS BOUNDARY NEVER INHERITS THE SOURCE'S EFFORT, and never invents a
  # model the caller did not name (v0.2 program §4 — Sol xhigh review,
  # live-switch finding 2: `set_harness_result/4` refuses `model_required`
  # before this is ever called, so `p` always names one here). Effort is a
  # tier in the DESTINATION catalog's vocabulary and the source's tier may
  # simply not exist there; carrying it across produced a bogus
  # `effort_not_offered` for a model the destination offers perfectly well.
  # There is no fallback base: a family is always present in `p`, so
  # `resolve_selection/4` always takes its "caller named a family" branch,
  # which never inherits from a base anyway.
  defp destination_model(session, harness, p) do
    resolve_selection(session.host, harness, p, nil)
  end

  # THE IN-FLIGHT ANSWER: a live switch never interrupts a turn and is never
  # queued behind one. It is REFUSED, by name, and the caller re-elects when
  # the turn ends. The wait therefore ends on the caller's own choice, never
  # on the substrate's.
  #
  # Two guards, because the lane alone is not enough. `at_session_turn_boundary`
  # proves no turn is RUNNING — the check and the act are atomic in the lane's
  # mailbox. But an idle lane can sit above durable work still QUEUED in the
  # ledger, and switching there would re-engine the session out from under a
  # turn that was already accepted and recorded: the row survives (nothing is
  # lost) but it would run on an engine its author never chose. `pending_count`
  # closes that window from INSIDE the held boundary, so no turn can be
  # enqueued between the count and the swap.
  defp at_tune_boundary(config, db, session_key, fun, opts \\ []) do
    at_session_turn_boundary(config, session_key, fn ->
      # Probe seam (same idiom as `on_swap_interlock`): lets a test enqueue
      # durable work inside the boundary and prove the count still refuses.
      # Absent in production.
      case config[:on_tune_fence] do
        callback when is_function(callback, 0) -> callback.()
        _ -> :ok
      end

      # An opener-authorized model-unavailable repair deliberately elects the
      # model that already-queued work will use; the ordinary tune path still
      # refuses that substitution. The shared lane boundary continues to bar
      # a running turn in both cases.
      if opts[:allow_queued] != true and Ledger.pending_count(db, session_key) > 0,
        do: {:tune_refused, :turn_in_progress},
        else: fun.()
    end)
    |> case do
      {:ok, {:tune_refused, :turn_in_progress}} -> {:error, :turn_in_progress}
      result -> result
    end
  end

  defp turn_in_progress_error do
    %{
      ok: false,
      code: "turn_in_progress",
      message:
        "this session has a queued or running turn, so the change was not applied. " <>
          "Try again once the current turn finishes."
    }
  end

  # The session changed under the election — its harness or host moved between
  # this request's validation and its commit (a concurrent tune or set_host won
  # the race). Nothing was applied and nothing was re-derived on the caller's
  # behalf: re-run the command so the election happens against the session as
  # it now is (Sol round 2, blocking 1/3).
  defp stale_election_error do
    %{
      ok: false,
      code: "stale_election",
      message:
        "the session's harness or host changed while this change was being " <>
          "prepared, so it was not applied. Re-run the command to elect " <>
          "against the session as it now is."
    }
  end

  # SPAWN's composition: a selection that names a model but no effort takes
  # the session's current (or configured-default) effort, falling back to
  # "medium" or the first available tier when the current one doesn't apply
  # to the newly selected model. A brand-new session carries no risk of
  # silently discarding a caller's OWN prior election, which is the harm
  # `compose_tune_model_selection/3` below exists to prevent — that function,
  # not this one, is TUNE's (Sol xhigh review, live-switch finding 2; scoped
  # here to the verb the finding's scenarios and diff actually cover).
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

  # TUNE's composition (v0.2 program §4 — the substrate never elects; Sol
  # xhigh review, live-switch finding 2). A model that offers reasoning tiers
  # and gets no `--effort` is REFUSED, naming the tiers on offer — never the
  # session's outgoing effort, never "medium", never the catalog's first
  # entry. Those were three different elections `compose_model_selection/4`
  # (spawn's, above) wore as one function; a live switch gets none of them,
  # mid-session, on the substrate's own initiative. A model with no tiers
  # needs no effort at all — `nil` stands.
  defp compose_tune_model_selection(host, harness, %Model{effort: nil} = selected) do
    case efforts_for(host, harness, selected) do
      [] -> {:ok, selected}
      efforts -> {:error, effort_required_error(selected, efforts)}
    end
  end

  defp compose_tune_model_selection(_host, _harness, %Model{} = selected), do: {:ok, selected}

  defp effort_required_error(selected, efforts) do
    %{
      ok: false,
      code: "effort_required",
      message:
        "#{selected.family} offers reasoning tiers (#{Enum.join(efforts, ", ")}); " <>
          "pass --effort to choose one"
    }
  end

  # THE SUBSTRATE NEVER ELECTS A MODEL (v0.2 program §4 — Sol xhigh review,
  # live-switch finding 2). A harness swap or a same-harness model change
  # that names no model used to complete itself from the destination's
  # configured default; that is the substrate choosing, not validating a
  # caller's choice, and it is refused here BY NAME instead of silently
  # substituted. `--context` qualifies a model, so a context with no model to
  # qualify gets the more specific refusal — it names the actual mistake
  # (a stray `--context`) rather than the generic "you must name a model".
  # FIELDS ARE NEVER PACKED ACROSS THE ENGINE BOUNDARY, and the server owns
  # that contract — not the CLI (Sol round 2, important 5). Raw-dispatch and
  # device callers reach the gateway directly, and a packed ref like
  # "model[effort]" or the vendor "[1m]" would smuggle an effort or context
  # election past the typed fields on a cross-harness switch. Scoped to
  # `set_harness` DELIBERATELY: same-harness `set_model` accepts the row's own
  # PUBLISHED identity echoed back (the issued-row contract pinned by test
  # "an issued row identity echoed back resolves to that row's fields") —
  # resolving your own issued name against the resident harness elects
  # nothing, while carrying one across a boundary would.
  defp refuse_packed_model(%{model: model}) when is_binary(model) do
    if String.contains?(model, "[") or String.contains?(model, "]") do
      {:error, invalid_model_field_error()}
    else
      :ok
    end
  end

  defp refuse_packed_model(_p), do: :ok

  defp validate_model_election(p) do
    case Map.fetch(p, :model) do
      {:ok, model} when is_binary(model) and model != "" ->
        :ok

      {:ok, model} when is_nil(model) or model == "" ->
        model_election_error(p)

      :error ->
        model_election_error(p)

      {:ok, _malformed} ->
        {:error, invalid_model_field_error()}
    end
  end

  defp model_election_error(p) do
    if Map.has_key?(p, :context) do
      {:error,
       %{
         ok: false,
         code: "context_requires_model",
         message: "--context qualifies a --model; name one, or drop --context"
       }}
    else
      {:error,
       %{
         ok: false,
         code: "model_required",
         message: "this switch requires an explicit --model; the substrate does not choose one"
       }}
    end
  end

  # F6 (Sol xhigh review): a malformed field is a DIFFERENT fact than an
  # absent one, and must be named as what it is rather than falling through
  # to `model_required`/`context_requires_model` and reading as a caller who
  # simply named nothing.
  defp invalid_model_field_error do
    %{
      ok: false,
      code: "invalid_model_field",
      message: "model must be a string naming a catalog entry"
    }
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

    # THE SERIALIZATION DOMAIN (Sol xhigh review, live-switch findings 1/4/5).
    # The fresh same-harness check, the pending-turn count, the engine swap,
    # the history barrier, and its tombstone are ONE transaction — not five
    # separate calls to the single-writer `DB` owner. `DB` processes one
    # `transaction/2` at a time in the owner process, so no other write
    # (`deliver_prompt`'s echo+enqueue included) can land between any two of
    # these: a prompt either committed before this transaction opens (the
    # count below sees it and refuses) or it cannot commit until after this
    # one ends, landing on whichever engine this decision leaves resident.
    # `Org.get_in_txn/2` — read HERE, not trusted from the snapshot
    # `tunable_session` returned before the lane was ever taken — is what
    # lets a second, concurrent, identical swap see the FIRST swap's result
    # and refuse `same_harness` instead of performing a same-harness no-op
    # that still moves the barrier and appends a false tombstone (finding 5).
    #
    # History barrier (product ruling): a new engine gets a fresh visible
    # slate. Rows are RETAINED (never deleted) but replay stops at the
    # barrier, and live clients are told to drop their local view. No
    # pointer surgery: the old harness session can't load on the new engine
    # -> fallback pointer, fresh context. The MAX(seq) read lives inside
    # this same transaction too, so a message landing between the read and
    # the barrier cannot be buried without being counted.
    #
    # DB.transaction CATCHES a raise and RETURNS {:error, exception}. A hard
    # {:ok, _} match here is a MatchError that crashes the wire call instead
    # of denying it — the trap already documented at `ruling_transaction/2`,
    # and one this very test caught.
    barrier =
      DB.transaction(db, fn txn ->
        fresh = Org.get_in_txn(txn, call.session_key)

        cond do
          is_nil(fresh) or fresh.state != "active" ->
            {:refused, :not_found}

          fresh.harness == harness ->
            {:refused, :same_harness}

          # THE ELECTION'S SNAPSHOT MUST STILL HOLD (Sol round 2, blocking 3).
          # Everything decided before this transaction — credential preflight,
          # catalog resolution, Spinup.ensure_ready, the home pin — was decided
          # against `session.host`. The transaction serializes WRITES, but it
          # cannot retroactively serialize that election: a concurrent
          # `set_host` landing between preflight and here would otherwise
          # commit a harness/model/provider validated and activated on host A
          # into a session now living on host B. A stale election is refused
          # BY NAME, never silently committed and never silently re-derived —
          # the caller re-runs `tune` and the election happens against the
          # session as it now is.
          fresh.host != session.host ->
            {:refused, :stale_election}

          Ledger.pending_count_in_txn(txn, call.session_key) > 0 ->
            {:refused, :turn_in_progress}

          true ->
            [[max_seq]] =
              Txn.q(
                txn,
                "SELECT COALESCE(MAX(seq), 0) FROM messages WHERE sessionKey = ?1",
                [call.session_key]
              )

            case Org.swap_model_in_txn(
                   txn,
                   call.session_key,
                   {fresh.model, fresh.harness},
                   {model, harness, provider},
                   cleared_through: max_seq
                 ) do
              {:ok, _updated} ->
                :ok

              other ->
                # UNREACHABLE BY CONSTRUCTION: `fresh` was read as the FIRST
                # statement of this very transaction, and nothing else can
                # write to this row before the UPDATE below runs (single
                # writer, one transaction at a time). `:duplicate` requires
                # `fresh.harness == harness`, already refused above;
                # `:stale` requires a write this transaction did not make.
                raise "swap_model_in_txn saw #{inspect(other)} inside its " <>
                        "own serializing transaction — the fresh read above " <>
                        "did not describe the row this UPDATE just saw"
            end

            # Probe seam (same idiom as `on_work_item_interlock`): lets a
            # test fail the transaction BETWEEN the two writes and prove the
            # barrier rolls back with them, or race a concurrent write into
            # this window and prove it cannot land inside it. Absent in
            # production.
            case Map.get(call, :on_swap_interlock) do
              fun when is_function(fun, 1) -> fun.(txn)
              _ -> :ok
            end

            Projection.append_marker_in_txn(
              txn,
              call.session_key,
              swap_tombstone(session, harness, model)
            )

            :swapped
        end
      end)

    case barrier do
      {:error, error} ->
        # Rolled back: the barrier did NOT move and the history is still
        # shown, and the session is STILL on its prior engine (the swap
        # write rolled back with everything else in this transaction) — the
        # safe direction to fail in. An operator sees their conversation
        # and a refused swap, never an empty chat with no account of why,
        # and never a session silently re-engined with no marker. No
        # broadcast either: there is nothing to tell clients to drop.
        %{
          ok: false,
          code: "swap_barrier_failed",
          message: describe_error(error)
        }

      {:ok, {:refused, :turn_in_progress}} ->
        turn_in_progress_error()

      {:ok, {:refused, :same_harness}} ->
        # The FIRST of two racing identical requests already won this swap
        # inside ITS transaction; this one's fresh read (not the stale
        # pre-lane snapshot) sees that and refuses by the same name a
        # sequential same-harness request gets, rather than performing a
        # same-harness no-op that still moves the barrier and appends a
        # false tombstone (finding 5).
        distinct_harness_error(harness)

      {:ok, {:refused, :not_found}} ->
        tune_not_found()

      {:ok, {:refused, :stale_election}} ->
        stale_election_error()

      {:ok, :swapped} ->
        # Pin the shared home to the model this session now runs on the new
        # harness, not the org default, so the next turn's session/new offers
        # and accepts it (wi_263814d3). AFTER the commit, deliberately (Sol
        # round 2, blocking 2): the pin used to run ahead of the transaction
        # on the theory that a refused swap made it "wasted work, never a
        # wrong result" — false for two RACING swaps electing DIFFERENT
        # models. The loser re-pinned the shared home to its model and was
        # then refused, leaving the resident engine and the home disagreeing.
        # Pinning only on the committed branch means the home always reflects
        # a swap that actually happened; the pending-turn refusal inside the
        # transaction guarantees no turn can consume the home between this
        # commit and this pin.
        with_home_pin_lock(harness_atom, session.host, fn ->
          Placement.deliver_home(
            config,
            {harness_atom, "shared", session.host},
            Keyword.put(deliver_opts, :model, model)
          )
        end)

        broadcast(
          db,
          session.owner_user_id,
          Payloads.stream_history_cleared(call.session_key)
        )

        published_identity(model)
        |> Map.merge(%{
          ok: true,
          harness: harness,
          # The swap may have crossed providers, and the new provider's
          # credential on this host may be a different kind. This is
          # the one moment the value changes without the client polling
          # status. The router camelizes the key to `credentialKind`,
          # matching the session-status shape.
          credential_kind: credential_kind(Map.put(session, :harness, harness)),
          note: "engine swapped; chat cleared (rows retained); model context starts fresh"
        })
    end
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
  defp apply_model_change(config, db, call, session, new_ref, basis \\ nil) do
    with {:ok, routed} <- validate_catalog_model(session.host, session.harness, new_ref, false) do
      # Probe seam, same contract and same placement rule as the harness
      # path's `on_tune_elected`: election decided, boundary not yet taken.
      case Map.get(call, :on_tune_elected) do
        fun when is_function(fun, 0) -> fun.()
        _ -> :ok
      end

      allow_queued = repair_tune_authorized?(db, call, session)

      boundary =
        at_tune_boundary(
          config,
          db,
          session.session_key,
          fn ->
            run_session_mutation(session.session_key, fn ->
              apply_tuned_model(config, db, call, session, new_ref, routed.provider, basis)
            end)
          end,
          allow_queued: allow_queued
        )

      case boundary do
        {:ok, :ok} ->
          %{ok: true}

        {:ok, {:error, :stale_election}} ->
          stale_election_error()

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

        # Busy = a turn is in flight (running on the lane, or durably queued in
        # the ledger); the switch cannot land mid-turn, so the change was NOT
        # applied. The honest remedy is to retry at the boundary -- never
        # "start a new session" (the live switch replaces that old escape),
        # and never a false intake/validation claim (the intake gate is a
        # different axis).
        {:error, :turn_in_progress} ->
          turn_in_progress_error()
      end
    else
      {:error, denial} -> denial
    end
  end

  defp apply_tuned_model(config, db, _call, session, new_ref, provider, basis) do
    case Org.current_pointer(db, session.session_key) do
      # No pointer: nothing is resident, so there is no runtime to move — only
      # the record to correct. It still earns its marker, on the same rule as
      # the resident path: the session's model changed, and the transcript is
      # where an agent reads that it did. ONE transaction for both, same as
      # the resident branch (Sol round 2, important 6): a set_model that
      # commits without its marker is the silent substitution the marker
      # exists to prevent, and a crash between two separate writes produced
      # exactly that. The same transaction also holds the stale-election
      # precondition — this election was validated against `session.harness`.
      nil ->
        result =
          DB.transaction(db, fn txn ->
            {record_model, record_harness, record_host} =
              read_recorded_model(txn, session.session_key)

            cond do
              record_harness != session.harness or record_host != session.host or
                  stale_basis?(basis, record_model) ->
                :stale_election

              record_model == new_ref ->
                :duplicate

              true ->
                {:ok, _} =
                  Org.swap_model_in_txn(
                    txn,
                    session.session_key,
                    {record_model, record_harness},
                    {new_ref, record_harness, provider}
                  )

                {:appended, marker} =
                  Projection.append_marker_in_txn(
                    txn,
                    session.session_key,
                    retune_marker(record_model, new_ref)
                  )

                Tightbeam.Firehose.Publisher.message_in_txn(
                  txn,
                  session.session_key,
                  marker,
                  session.owner_user_id
                )

                {:changed, marker}
            end
          end)

        case result do
          {:ok, :stale_election} ->
            {:error, :stale_election}

          {:ok, {:changed, marker}} ->
            publish_stored_message(db, session.session_key, marker)
            :ok

          {:ok, :duplicate} ->
            :ok

          {:error, error} ->
            raise error
        end

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
                    provider,
                    basis
                  )
                end
              end)

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
                    provider,
                    basis
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

  # The recorded selection, read back inside the serialized mutation. The row
  # holds FIELDS, so this is where they become an identity again — never a
  # packed column read straight into a comparison.
  # A RELATIVE election (set_reasoning derives its target from the snapshot's
  # model) carries that model as its BASIS: if the recorded family or context
  # no longer matches it at commit, the derivation is stale and committing it
  # would silently revert a concurrent set_model (Sol round 4, blocking).
  # Effort is excluded on purpose -- concurrent effort-only changes are
  # last-writer-wins, and comparing it would refuse legitimate races.
  defp stale_basis?(nil, _record_model), do: false
  defp stale_basis?(_basis, nil), do: true

  defp stale_basis?(%Model{} = basis, %Model{} = record),
    do: basis.family != record.family or basis.context != record.context

  defp read_recorded_model(txn, session_key) do
    [[family, effort, context, harness, host]] =
      Txn.q(
        txn,
        """
        SELECT model, thinkingLevel, modelContext, harness, host
        FROM sessions WHERE sessionKey=?1
        """,
        [session_key]
      )

    {family && %Model{family: family, effort: effort, context: context}, harness, host}
  end

  defp project_tuned_model(
         db,
         session,
         adapter,
         prior_sid,
         switched_sid,
         new_ref,
         provider,
         basis
       ) do
    result =
      DB.transaction(db, fn txn ->
        {record_model, record_harness, record_host} =
          read_recorded_model(txn, session.session_key)

        # THE ELECTION'S SNAPSHOT MUST STILL HOLD (Sol rounds 2-3). BOTH axes:
        # this model was validated against `session.harness`'s catalog ON
        # `session.host`, and the fork was built with that host's placement,
        # guidance and cwd. A harness switch OR a set_host committing in
        # between leaves this row somewhere the election never saw — the old
        # code would have committed a claude model onto a codex session, or a
        # host-A-validated model onto a session now living on host B, all
        # calls reporting success. The fresh in-txn read is a PRECONDITION,
        # never a substitute target: a stale election is refused by name, and
        # the caller re-elects against the session as it now is.
        outcome =
          if record_harness != session.harness or record_host != session.host or
               stale_basis?(basis, record_model) do
            :stale_election
          else
            project_tuned_swap(txn, session, record_model, record_harness, new_ref, provider)
          end

        if outcome != :stale_election and switched_sid != prior_sid do
          Org.append_pointer_in_txn(txn, session.session_key, switched_sid, "loaded")
        end

        outcome
      end)

    case result do
      {:ok, :stale_election} ->
        # The fork the adapter prepared was for an election that no longer
        # describes this session; hand it back rather than leaving it
        # resident beside the pointer that never moved.
        reject_tuned_session(adapter, prior_sid, switched_sid)
        {:error, :stale_election}

      {:ok, outcome} ->
        close_superseded_model_session(adapter, session.session_key, prior_sid, switched_sid)

        # AFTER COMMIT, never before: the row is durable by the time it is
        # pushed, so a fan-out that cannot run is a DELIVERY delay that replay
        # settles, never a lost fact.
        case outcome do
          {:changed, marker} -> publish_stored_message(db, session.session_key, marker)
          :duplicate -> :ok
        end

        :ok

      {:error, error} ->
        reject_tuned_session(adapter, prior_sid, switched_sid)
        raise error
    end
  end

  defp project_tuned_swap(txn, session, record_model, record_harness, new_ref, provider) do
    case Org.swap_model_in_txn(
           txn,
           session.session_key,
           {record_model, record_harness},
           {new_ref, record_harness, provider}
         ) do
      # A model change is a recorded fact ABOUT this session, so it earns
      # a transcript row: an agent reading its own history must be able
      # to see that the mind answering changed, and where. The marker
      # rides the SAME transaction as the swap it describes — a swap
      # committed without its marker is the silent substitution the
      # marker exists to prevent, just rarer.
      {:ok, _} ->
        {:appended, marker} =
          Projection.append_marker_in_txn(
            txn,
            session.session_key,
            retune_marker(record_model, new_ref)
          )

        Tightbeam.Firehose.Publisher.message_in_txn(
          txn,
          session.session_key,
          marker,
          session.owner_user_id
        )

        {:changed, marker}

      # The recorded row ALREADY names this model. The caller's election
      # is satisfied, so this is not a failure — and it must not mint a
      # "changed from X to X" row for a change that did not happen.
      {:duplicate, _} ->
        :duplicate

      :stale ->
        raise("model mutation race inside serialized tune")
    end
  end

  # `[model retune]` — the model changed; the ENGINE and its conversation did
  # not. Deliberately a different marker from `[engine swap]`, which also moves
  # the history barrier: a retune hides nothing, so its marker must promise
  # nothing about the transcript.
  defp retune_marker(from, to) do
    "[model retune]\n\nThis session's model changed from #{Model.describe(from)} " <>
      "to #{Model.describe(to)}. The engine and its conversation are unchanged."
  end

  # The record is already committed by the time this runs. A registry that
  # cannot be reached delays delivery until the next replay; it must never
  # undo, or fail, the change that produced the row.
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
        {:ok, outcome} =
          DB.transaction(db, fn txn ->
            outcome =
              Projection.append_in_txn(txn, %{
                session_key: session.session_key,
                role: "user",
                content: credential_transition_message(provider, machine, transition),
                sender: "process:tightbeam"
              })

            case outcome do
              {:appended, message} ->
                Tightbeam.Firehose.Publisher.message_in_txn(
                  txn,
                  session.session_key,
                  message,
                  session.owner_user_id
                )

              _ ->
                :ok
            end

            outcome
          end)

        case outcome do
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

      append_context_reset_marker(db, updated)

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
  # The acceptance-№1 read (fabric §12 Q5). A pure count over classed rows:
  # it files nothing, rules nothing, and names no threshold. Visibility follows
  # `transcript`'s rule — the session's owner or an admin — because the same
  # rows are readable there, and a coordination share over a session you cannot
  # read would be a status oracle.
  defp coordination_share_result(db, call) do
    p = call.params
    session_key = p[:session_key] || p[:session]

    cond do
      not (is_binary(session_key) and session_key != "") ->
        %{code: "invalid", message: "coordination-share requires --session"}

      not (is_integer(p[:from]) and is_integer(p[:to])) ->
        %{code: "invalid", message: "coordination-share requires --from and --to in epoch ms"}

      p[:to] <= p[:from] ->
        %{code: "invalid", message: "--to must be after --from"}

      true ->
        case Org.get(db, session_key) do
          nil ->
            %{code: "not_found", message: "session not found"}

          session ->
            if coordination_share_readable?(db, call, session),
              do: Wakes.coordination_share(db, session_key, p.from, p.to),
              else: %{code: "not_found", message: "session not found"}
        end
    end
  end

  # A refusal travels BARE so Dispatch turns it into a denial; a row travels
  # wrapped, in the same envelope `decision-request` already uses.
  defp decision_request_result(%{code: _} = error), do: error
  defp decision_request_result(request), do: %{decision_request: request}

  defp coordination_share_readable?(_db, %{principal: {:session, key}}, %{session_key: key}),
    do: true

  defp coordination_share_readable?(db, call, session),
    do: owner_readable?(db, call, session.owner_user_id)

  # OWNER-OR-ADMIN over a raw owner id, shared by every read whose visibility
  # is "the thing's owner, or an admin" — `coordination-share` over a
  # session's owner, `digest-members` over a role-addressed carrier's role's
  # owner (below). A `{:session, key}` principal is never the target's OWN
  # session here (that shortcut is `coordination_share_readable?`'s own
  # first clause, which has no role analogue — a role is not a session
  # identity); it must resolve to the same owner some other way.
  defp owner_readable?(db, call, owner_user_id) do
    case call[:principal] do
      {:user, id} -> owner_user_id == id or admin_origin?(db, call.origin)
      {:session, _key} -> owner_of?(db, call.origin, owner_user_id)
      _ -> false
    end
  end

  defp owner_of?(db, origin, owner_user_id) do
    case resolve_caller(db, origin) do
      %{owner_user_id: owner} when is_binary(owner) -> owner == owner_user_id
      _ -> false
    end
  end

  # O5: `digest_members/2` (the C4/acceptance-2 audit — every source wake a
  # digest carries) had no sanctioned surface, a status question answerable
  # from rows that no agent could ask (philosophy gate Q9). Visibility
  # follows `coordination-share`'s exact rule: the carrier's own target's
  # owner, or an admin. An id that is not a pending digest CARRIER —
  # unknown, a member, an ordinary wake, or a carrier this caller cannot see
  # — answers identically: `not_found`, never an existence oracle.
  defp digest_members_result(db, call) do
    supplied = call.params[:wake_id]

    cond do
      not (is_binary(supplied) and supplied != "") ->
        %{code: "invalid", message: "digest-members requires a wakeId"}

      true ->
        visible? = fn id ->
          case Wakes.get(db, id) do
            %{digest: true} = wake -> digest_members_readable?(db, call, wake)
            _ -> false
          end
        end

        case IdPrefix.resolve(db, :wake, supplied, visible?) do
          {:ok, wake_id} ->
            case Wakes.get(db, wake_id) do
              %{digest: true} = wake ->
                if digest_members_readable?(db, call, wake),
                  do: %{digest_members: Wakes.digest_members(db, wake_id)},
                  else: digest_members_not_found()

              _ ->
                digest_members_not_found()
            end

          :unknown ->
            digest_members_not_found()

          {:ambiguous, error} ->
            error
        end
    end
  end

  # PIN THE PAST, NEVER READ THE PRESENT (specs roles-registry-v1.md:31 —
  # Sol xhigh review round 2, finding: a LIVE `Roles.get/2` at read time
  # bound audit authority to a deletable, name-reusable row. After
  # `role-rm`, `Roles.get/2` returns nil and denied EVERYONE, admin
  # included; after delete-then-recreate under a different owner, the same
  # live lookup silently handed the NEW owner read access to the OLD
  # carrier's members — a fact that was never true).
  #
  # A carrier whose `sessionKey` resolves through `Org.get/2` was pinned to
  # a REAL session at materialization (O2's `carrier_shape/2` puts it there
  # directly, for a role that resolved at that moment) — sessions are never
  # hard-deleted, so this resolves for the life of the row, and reading it
  # needs no role lookup at all: the pinned session's owner already answers
  # the question. Only a carrier built while its role had NO active
  # resolution — the synthetic `role:<name>` placeholder, which never
  # resolves through `Org.get/2` — falls through to the fact
  # `materialize_members/4` pinned into the SAME transaction's
  # `wake_digest_materialized` lifecycle event: the role's owner AT THAT
  # MOMENT, durable regardless of anything that happens to the role
  # afterward.
  defp digest_members_readable?(db, call, wake) do
    case Org.get(db, wake.session_key) do
      nil -> owner_readable?(db, call, pinned_carrier_owner(db, wake.wake_id))
      session -> coordination_share_readable?(db, call, session)
    end
  end

  # `owner_readable?/3`'s `{:user, id}` clause always falls through to
  # `admin_origin?/2` regardless of whether `owner_user_id` matched — so
  # this reads correctly even when no pinned fact exists at all (a `nil`
  # owner never matches a real user id, and the admin path is still
  # reached): the deny-on-nil case never precedes the admin check.
  #
  # `URI.decode_www_form/1` reverses `Wakes`'s `pinned_owner_field/1`
  # (Sol xhigh review round 3): the raw text was LOSSY for a user id
  # containing a space — "alice bob" pinned and captured back by `\S+` as
  # bare "alice" would transfer the OLD carrier's audit to a real user named
  # "alice." Decoding here is what makes the round trip exact regardless of
  # what the id contains.
  defp pinned_carrier_owner(db, wake_id) do
    case DB.query(
           db,
           "SELECT detail FROM lifecycle_events WHERE kind = 'wake_digest_materialized' AND subject = ?1",
           [wake_id]
         ) do
      {:ok, [[detail]]} ->
        case Regex.run(~r/ ownerUserId=(\S+)/, detail) do
          [_, encoded] -> URI.decode_www_form(encoded)
          nil -> nil
        end

      _ ->
        nil
    end
  end

  defp digest_members_not_found, do: %{code: "not_found", message: "wake not found"}

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

  defp completion_disposition_result(config, db, call) do
    completion_id = call.params[:completion_id]
    decision = call.params[:decision]
    principal = call[:principal]

    {:ok, result} =
      DB.transaction(db, fn txn ->
        case CompletionEscalation.preflight_disposition_in_txn(
               txn,
               completion_id,
               decision,
               principal
             ) do
          {:error, error} ->
            {:response, error}

          {:replay, _row} ->
            {:completion, completion_id}

          {:action, row} ->
            case pending_retire_intents_in_txn(txn, row.child_session_key, row.owner_user_id) do
              [] ->
                completion_action_in_txn(config, txn, row, decision, principal)

              deferred ->
                {:response,
                 %{
                   code: "retire_deferred",
                   completionId: row.id,
                   requestStatus: "open",
                   deferred: deferred
                 }}
            end
        end
      end)

    case result do
      {:response, response} -> response
      {:completion, id} -> CompletionEscalation.get(db, id)
      {:retired, owner, retired} -> complete_completion_retire(config, db, owner, retired)
    end
  end

  defp completion_action_in_txn(_config, txn, row, "retain", principal) do
    CompletionEscalation.retain_in_txn(txn, row.id, principal)
    {:completion, row.id}
  end

  defp completion_action_in_txn(_config, txn, row, "park", principal) do
    {:response, CompletionEscalation.park_unavailable_in_txn(txn, row.id, principal)}
  end

  defp completion_action_in_txn(config, txn, row, "retire", principal),
    do: completion_retire_in_txn(config, txn, row, principal)

  defp pending_retire_intents_in_txn(txn, root_key, owner) do
    rows =
      Txn.q(txn, "SELECT sessionKey,ownerUserId FROM sessions WHERE state='active'")
      |> Enum.map(fn [session_key, row_owner] ->
        [session_key, Org.effective_parent_in_txn(txn, session_key).session_key, row_owner]
      end)

    by_key = Map.new(rows, fn [key, parent, row_owner] -> {key, {parent, row_owner}} end)
    children = Enum.group_by(rows, &Enum.at(&1, 1))

    members =
      walk_owned_subtree(children, root_key, owner)
      |> Enum.uniq()

    candidates =
      Enum.flat_map(members, fn member ->
        owned_ancestors(by_key, member, owner)
        |> Enum.map(&{retire_intent_wake_id(&1, member), member})
      end)

    Enum.flat_map(candidates, fn {wake_id, member} ->
      case Txn.q(
             txn,
             "SELECT dueAt FROM wakes WHERE wakeId=?1 AND state='pending'",
             [wake_id]
           ) do
        [[due_at]] ->
          [%{session_key: member, until: due_at, reason: "pending generic-retire intent"}]

        [] ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.session_key)
    |> Enum.sort_by(& &1.session_key)
  end

  defp walk_owned_subtree(children, root_key, owner) do
    case Enum.find(Map.get(children, parent_of(children, root_key), []), &(hd(&1) == root_key)) do
      [^root_key, _parent, ^owner] ->
        descendants =
          children
          |> Map.get(root_key, [])
          |> Enum.flat_map(fn
            [^root_key, _parent, _row_owner] -> []
            [child, _parent, ^owner] -> walk_owned_subtree(children, child, owner)
            _foreign -> []
          end)

        [root_key | descendants]

      _ ->
        []
    end
  end

  defp parent_of(children, key) do
    Enum.find_value(children, fn {parent, rows} ->
      if Enum.any?(rows, &(hd(&1) == key)), do: parent
    end)
  end

  defp owned_ancestors(by_key, key, owner), do: owned_ancestors(by_key, key, owner, MapSet.new())

  defp owned_ancestors(by_key, key, owner, seen) do
    if MapSet.member?(seen, key) do
      []
    else
      case Map.get(by_key, key) do
        {_parent, row_owner} when row_owner != owner ->
          []

        {parent, ^owner} ->
          [key | owned_ancestors(by_key, parent, owner, MapSet.put(seen, key))]

        nil ->
          []
      end
    end
  end

  defp completion_retire_in_txn(config, txn, row, principal) do
    case retirement_actor_in_txn(txn, principal) do
      nil ->
        {:response, %{code: "principal_not_allowed"}}

      %{owner: owner, serialized: serialized} ->
        case Txn.q(txn, "SELECT isBuiltIn FROM sessions WHERE sessionKey=?1", [
               row.child_session_key
             ]) do
          [[1]] ->
            {:response,
             %{
               code: "denied",
               message:
                 "main sessions are permanent — they are the fallback for roles and user references"
             }}

          [[0]] ->
            result =
              retire_cascade_in_txn(
                txn,
                row.child_session_key,
                owner,
                serialized,
                principal,
                Map.fetch!(config, :wake_tick_ms),
                "retired: session retired before execution",
                schedule_intents: false
              )

            if result.deferred == [] do
              {:retired, owner, result}
            else
              {:response,
               CompletionEscalation.retire_deferred_in_txn(
                 txn,
                 row.id,
                 principal,
                 result.deferred
               )}
            end

          _ ->
            {:response, %{code: "child_not_active"}}
        end
    end
  end

  defp complete_completion_retire(config, db, owner, result) do
    Enum.each(result.retired, fn retired ->
      broadcast(db, owner, Payloads.stream_deleted(retired.session_key))
      Map.get(config, :on_retired, fn _ -> :ok end).(retired.session_key)

      Enum.each(retired.assignments, fn assignment ->
        emit_assignment_change(db, assignment.assignment_id, assignment.from_state)
      end)
    end)

    reap_retired_sessions(config, db, Enum.map(result.retired, & &1.session_key))

    completion_id =
      result.retired
      |> List.last()
      |> Map.fetch!(:session_key)

    case DB.query(
           db,
           "SELECT id FROM completion_escalations WHERE childSessionKey=?1 AND decision='retire' ORDER BY actedAt DESC LIMIT 1",
           [completion_id]
         ) do
      {:ok, [[id]]} -> CompletionEscalation.get(db, id)
      _ -> %{code: "unknown_completion"}
    end
  end

  defp retirement_actor_in_txn(txn, {:user, user}) when is_binary(user) and user != "" do
    case Txn.q(txn, "SELECT 1 FROM users WHERE userId=?1", [user]) do
      [[1]] -> %{owner: user, serialized: "user:#{user}"}
      _ -> nil
    end
  end

  defp retirement_actor_in_txn(txn, {:session, session_key})
       when is_binary(session_key) and session_key != "" do
    case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [session_key]) do
      [[owner]] -> %{owner: owner, serialized: "session:#{session_key}"}
      _ -> nil
    end
  end

  defp retirement_actor_in_txn(_txn, _principal), do: nil

  defp retire_result(config, db, call) do
    p = call.params

    case retirement_actor(db, call[:principal]) do
      nil ->
        %{code: "not_found"}

      %{owner: owner, principal: principal, serialized: serialized} ->
        prior =
          if p[:idempotency_key], do: Idempotency.get(db, owner, "retire", p.idempotency_key)

        if prior && prior.session_key == call.session_key do
          retire_replay_observation(db, call, %{
            deleted_session_key: call.session_key,
            retired_session_keys: retired_subtree_keys(db, call.session_key),
            deferred: []
          })
        else
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
                    Tightbeam.Firehose.Publisher.maybe_observed_accepted_in_txn(txn, call)

                    result =
                      retire_cascade_in_txn(
                        txn,
                        session.session_key,
                        owner,
                        serialized,
                        principal,
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
                retire_replay_observation(db, call, %{
                  deleted_session_key: session.session_key,
                  retired_session_keys: [],
                  deferred: []
                })
              end

            _ ->
              %{code: "not_found"}
          end
        end
    end
  end

  defp retirement_actor(db, {:user, user}) when is_binary(user) and user != "" do
    case DB.query(db, "SELECT 1 FROM users WHERE userId=?1", [user]) do
      {:ok, [[1]]} -> %{owner: user, principal: {:user, user}, serialized: "user:#{user}"}
      _ -> nil
    end
  end

  defp retirement_actor(db, {:session, session_key})
       when is_binary(session_key) and session_key != "" do
    case DB.query(db, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [session_key]) do
      {:ok, [[owner]]} ->
        %{
          owner: owner,
          principal: {:session, session_key},
          serialized: "session:#{session_key}"
        }

      _ ->
        nil
    end
  end

  defp retirement_actor(_db, _principal), do: nil

  defp retire_replay_observation(db, call, result) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Tightbeam.Firehose.Publisher.maybe_observed_accepted_in_txn(txn, call)
      end)

    result
  end

  defp critical_result(config, db, call) do
    with {:session, session_key} <- call[:principal],
         %{state: "active"} <- Org.get(db, session_key),
         duration when is_integer(duration) and duration > 0 <- call.params[:for_ms],
         reason when is_binary(reason) and reason != "" <- call.params[:reason] do
      hard_cap = Map.get(config, :critical_lease_hard_cap_ms, 14_400_000)
      lease = CriticalLeases.declare(db, session_key, duration, reason, hard_cap, call)

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
        "SELECT sessionKey FROM sessions WHERE state='active' ORDER BY createdAt, sessionKey"
      )

    children =
      Enum.group_by(rows, fn [session_key] ->
        Org.effective_parent_in_txn(txn, session_key).session_key
      end)

    walk = fn walk, key ->
      descendants =
        children
        |> Map.get(key, [])
        |> Enum.reject(fn [child_key] -> child_key == key end)
        |> Enum.flat_map(fn [child_key] -> walk.(walk, child_key) end)

      descendants ++ [%{session_key: key}]
    end

    walk.(walk, root_key)
  end

  defp retired_subtree_keys(db, root_key) do
    {:ok, rows} =
      DB.transaction(db, fn txn ->
        Txn.q(txn, "SELECT sessionKey, state FROM sessions ORDER BY createdAt, sessionKey")
        |> Enum.map(fn [session_key, state] ->
          [session_key, Org.effective_parent_in_txn(txn, session_key).session_key, state]
        end)
      end)

    children = Enum.group_by(rows, &Enum.at(&1, 1))

    walk = fn walk, key ->
      descendants =
        children
        |> Map.get(key, [])
        |> Enum.reject(fn [child_key, _parent, _state] -> child_key == key end)
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
         serialized_principal,
         typed_principal,
         supervision_interval_ms,
         drain_reason,
         opts \\ []
       ) do
    # Invariant: this operational-parent walk visits each active member of the target's
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
          {assignments, session} =
            retire_session_in_txn(
              txn,
              member.session_key,
              owner,
              serialized_principal,
              typed_principal,
              supervision_interval_ms,
              drain_reason
            )

          %{session_key: member.session_key, assignments: assignments, session: session}
        end)

      %{retired: retired, deferred: []}
    else
      deadline = Enum.max_by(leased, & &1.hard_deadline).hard_deadline

      deferred =
        Enum.map(subtree, fn member ->
          direct = Enum.find(leased, &(&1.session_key == member.session_key))

          if not is_nil(direct) and Keyword.get(opts, :schedule_intents, true) do
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
        wake =
          Wakes.schedule_in_txn(txn, %{
            wake_id: wake_id,
            session_key: session_key,
            origin: "user:#{owner}",
            prompt:
              "FINAL RETIRE INSTRUCTION: clean up critical section '#{lease.reason}'; retirement is deferred only until hard deadline #{lease.hard_deadline}.",
            due_at: lease.hard_deadline
          })

        Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)

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
         serialized_principal,
         typed_principal,
         supervision_interval_ms,
         drain_reason
       ) do
    assignments =
      Assignments.interrupt_for_retire_in_txn(txn, session_key, owner, serialized_principal)

    CompletionEscalation.acknowledge_retire_in_txn(txn, session_key, typed_principal)
    session = Org.retire_in_txn(txn, session_key, serialized_principal, supervision_interval_ms)

    Ledger.drain_queued_for_retire_in_txn(txn, session_key, drain_reason,
      cause: "session-retired",
      principal: TurnLifecycle.principal(serialized_principal)
    )

    {assignments, session}
  end

  # Retire durability owns the ordering: every DB transition commits before
  # this seam touches a harness. Adapters are shared by key, so each retired
  # harness SID is closed independently and the adapter itself is closed only
  # when no active session still shares that key. Every operation is guarded:
  # an absent/dead adapter can never turn a committed retire into a failure.
  defp reap_retired_sessions(_config, _db, []), do: :ok

  defp reap_retired_sessions(config, db, session_keys) do
    coordinator = Map.get(config, :adapter_coordinator, Tightbeam.AdapterCoordinator)

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

  # Says four things and nothing more: the engine changed, from what to what,
  # that earlier history is RETAINED rather than deleted, and that this is
  # expected. `Projection.list_after/5` floors at the barrier — it never deletes
  # — so "retained but not shown" is literally what happened.
  defp swap_tombstone(session, harness, model) do
    from = describe_engine(session.harness, session.model)
    to = describe_engine(harness, model)

    "[engine swap]\n\n" <>
      "This session's engine changed from #{from} to #{to}.\n\n" <>
      "Earlier messages are RETAINED and are not deleted, but they are no longer " <>
      "shown here: a new engine cannot load the previous engine's session, so the " <>
      "visible transcript starts fresh from this point. This is expected after a " <>
      "harness swap, not a fault."
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

  # Cold start creates the built-in Main on the gateway's own host, so that is
  # the catalog to read when its provider default is resolved.
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

  # A fallback is a substrate event a reader of the CHAT must see: the
  # model's working memory ended here while the visible history did not —
  # without a line, the boundary is invisible and the next reply reads as a
  # bug. Position is the truth: fallback is discovered lazily at turn
  # start, AFTER this turn's echo committed, so the marker lands between
  # echo and reply — the message directly above IS delivered to the fresh
  # context, everything before it is not.
  defp append_context_reset_marker(db, session) do
    append_stored_notice(
      db,
      session.session_key,
      "[context reset]\n\n" <>
        "The agent's working memory was reset while handling the message above. " <>
        "Earlier messages stay visible here, but the agent no longer remembers them.",
      "marker"
    )
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
    append_stored_notice(
      db,
      session_key,
      "[turn failed]\n\nThe agent could not answer the message above: #{reason}" <>
        unknown_outcome_warning(reason),
      "substrate"
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

  # STORED NOTICES: ordinary appended messages so structural boundaries and
  # failure notices ride replay and live push with no new frame type. The
  # stored discriminator keeps those two meanings distinct. sender
  # "process:tightbeam" is the anti-forgery — real model output always commits
  # with sender "tightbeam", so no session can emit either by typing one.
  defp append_stored_notice(db, session_key, content, message_type)
       when message_type in ["marker", "substrate"] do
    {:ok, outcome} =
      DB.transaction(db, fn txn ->
        outcome =
          Projection.append_in_txn(txn, %{
            session_key: session_key,
            role: "assistant",
            message_type: message_type,
            content: content,
            sender: "process:tightbeam"
          })

        case outcome do
          {:appended, marker} ->
            Tightbeam.Firehose.Publisher.message_in_txn(txn, session_key, marker)

          _ ->
            :ok
        end

        outcome
      end)

    case outcome do
      # The row is committed. Pushing it is delivery, and delivery that cannot
      # run is a delay replay settles — so it never fails the change that
      # produced the marker.
      {:appended, marker} -> publish_stored_message(db, session_key, marker)
      _ -> :ok
    end
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
end
