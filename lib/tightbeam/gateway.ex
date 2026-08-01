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
  4. Adapter.prompt; on {:ok, %{text: _}} append the assistant message to
     Projection (sender "tightbeam", reply_to the echo) and publish via
     ConnRegistry (seq-ordered, from the commit path).
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
    Adjudication,
    Archetypes,
    Artifacts,
    Assignments,
    CausalEvents,
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
    ModelCatalog,
    Org,
    Projection,
    RailRemedy,
    Rails,
    Rules,
    Roles,
    Spinup,
    SubagentMarkers,
    Supervision,
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

  defmodule HealLost do
    @moduledoc false
    defexception message: "a human ruling already owns this adjudication episode"
  end

  defmodule AdjudicationSuperseded do
    @moduledoc false
    defexception message: "an adapter heal already resolved this adjudication episode"
  end

  @typedoc "Gateway config (gateway.ts GatewayConfig)."
  @type config :: %{
          base_dir: String.t(),
          cwd: String.t(),
          port: non_neg_integer(),
          default_harness: atom(),
          default_model: String.t(),
          max_live_sessions_per_user: pos_integer(),
          wake_tick_ms: pos_integer(),
          prod_limit: non_neg_integer(),
          escalation_decision_deadline_ms: pos_integer(),
          effort_checkin_horizon_ms: pos_integer(),
          adjudication_claim_window_ms: pos_integer(),
          adjudication_response_window_ms: pos_integer(),
          adjudication_park_fallback_ms: pos_integer(),
          critical_lease_hard_cap_ms: pos_integer(),
          onboarding_lease_ms: pos_integer()
        }

  @doc """
  The wire/adapter children to append after Tightbeam.Application's base
  children (see moduledoc order). Also: ensure schemas for Devices/
  Idempotency/Wakes/Projection/Org, mint + persist the cliToken and
  gateway.json (mode 0600) in base_dir, install the CLI bin.
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

    for module <- [
          Tightbeam.Assets,
          Artifacts,
          CausalEvents,
          Adjudication,
          Devices,
          Idempotency,
          ConditionFacts,
          SubagentMarkers,
          Escalation,
          Wakes,
          Projection,
          Org,
          CriticalLeases,
          Roles,
          WorkItems,
          Assignments,
          EffortCheckin,
          Placement,
          RailRemedy,
          Supervision,
          WorkState
        ] do
      :ok = module.ensure_schema(db)
    end

    :ok = Assignments.audit_review_item_conflicts(db)

    :ok = Adjudication.reconcile(db)

    :ok =
      Adjudication.escalate_due(
        db,
        Map.get(config, :adjudication_response_window_ms, 86_400_000)
      )

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
    on_terminal = fn session_key, seq -> Supervision.notify_terminal(session_key, seq) end

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
        session_status: &session_status/1,
        adapter_coordinator: Tightbeam.AdapterCoordinator
      })

    # EDGE half of the heal trigger. Off the coordinator's process: the sweep
    # opens transactions and broadcasts, and the coordinator must never block on
    # either (adapter checkouts queue behind it). Idempotence is durable — one
    # probe per (hold, token) — so an at-least-once, unordered invocation is safe.
    heal_config = Map.put(config, :db, db)

    on_adapter_ready = fn key_name, token ->
      Task.Supervisor.start_child(Tightbeam.TurnTaskSupervisor, fn ->
        adapter_healed(
          heal_config,
          db,
          Adjudication.adapter_fault_cause_for_name(key_name),
          token
        )
      end)

      :ok
    end

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
           "effort_deadline" => &EffortCheckin.deadline(db, config, &1),
           Adjudication.probe_retry_consumer() => &adapter_heal_retry(heal_config, db, &1)
         },
         tick_ms: config.wake_tick_ms,
         name: Tightbeam.WakeScheduler},
        {Tightbeam.Supervision,
         db: db,
         handlers: handler_table,
         prod_limit: prod_limit,
         sweep_ms: config.wake_tick_ms,
         name: Tightbeam.Supervision},
        {DynamicSupervisor, strategy: :one_for_one, name: Tightbeam.AdapterSupervisor},
        {Tightbeam.AdapterCoordinator,
         adapter_sup: Tightbeam.AdapterSupervisor,
         adapter_context: adapter_context,
         adapter_opts: adapter_opts,
         db: db,
         on_adapter_ready: on_adapter_ready,
         name: Tightbeam.AdapterCoordinator},
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

  @doc "Refuse an unusable harness or identity before the production store is created."
  @spec preflight!(config()) :: :ok
  def preflight!(config) do
    assert_harness_binary_ready!(Path.join(config.base_dir, "bin"))
    Identity.init!(config.base_dir)
    :ok
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
        park: fn provider -> park_provider_runtime(provider, machine) end,
        start: fn provider, kind -> start_provider_runtime(provider, kind, machine) end,
        resume: fn _provider -> :ok end,
        capture_sessions: fn provider ->
          capture_credential_sessions(db, provider, machine)
        end,
        publish_sessions: fn captured, transition ->
          publish_credential_sessions(db, captured, transition)
        end,
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

  defp maybe_put_credential_runner(opts, %{sh: sh}), do: Keyword.put(opts, :sh, sh)
  defp maybe_put_credential_runner(opts, _config), do: opts

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

  defp assert_harness_binary_ready!(cli_bin) do
    results =
      Enum.map(Harness.all(), fn module ->
        {module.id(), Placement.harness_binary_probe(module.id(), cli_bin)}
      end)

    unless Enum.any?(results, fn {_harness, result} -> match?({:ok, _}, result) end) do
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
            %{canceled: Wakes.cancel(db, p.cancel_wake_id, call.origin)}

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

        if is_binary(p[:kind]) and p.kind != "" do
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
        else
          %{code: "invalid", message: "a condition fact requires a kind"}
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
      "decision-requests" => fn call ->
        caller = resolve_caller(db, call.origin)

        %{
          decision_requests:
            Escalation.list(db, call, call.params[:status] || "open",
              owner_user_id: caller && caller.owner_user_id,
              admin: admin_origin?(db, call.origin)
            )
        }
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
      "update-clients" => fn _call ->
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
      end,
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
      "identity-apply" =>
        admin_call_handler(db, fn call -> identity_apply_result(config, db, call) end),
      "kungfu-scaffold" =>
        admin_call_handler(db, fn call ->
          paths =
            Archetypes.scaffold_kungfu!(
              config.base_dir,
              call.params.name,
              call.origin
            )

          %{kungfu: call.params.name, paths: paths}
        end),
      "onboard" => admin_call_handler(db, fn call -> onboard_result(config, call) end),
      "promote-user" =>
        admin_handler(db, fn p ->
          %{user: Devices.set_user_admin(db, p.user_id, Map.get(p, :is_admin, true))}
        end),
      "config" => admin_handler(db, fn p -> config_result(db, p) end),
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
          |> Map.put(:on_assignment_change, assignment_change)
          |> Map.put(:on_work_item_change, item_change)

        Assignments.__handle__(db, "assign", call)
      end,
      "dispatch" => fn call ->
        call =
          call
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
      "adjudicate" => fn call -> adjudicate_result(config, db, call) end,
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
        :skipped

      {target, role_ref, role_fallback} ->
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

            Ledger.enqueue_in_txn(txn, %{
              session_key: target,
              message_id: message.id,
              wake_id: opts[:wake_id],
              origin: origin,
              prompt: stamped,
              role_ref: role_ref || opts[:role_ref],
              role_fallback: role_fallback || opts[:role_fallback] || false,
              assignment_id: assignment_id,
              job_ref: job_ref
            })

            if opts[:fire_wake_in_txn] == true and is_binary(opts[:wake_id]) do
              DB.Txn.q(
                txn,
                "UPDATE wakes SET state = 'fired', firedAt = ?2 WHERE wakeId = ?1 AND state = 'pending'",
                [opts[:wake_id], System.system_time(:millisecond)]
              )
            end

            # Nag-by-re-arm: a bracket wake that just fired re-arms its
            # replacement IN this transaction if the item is still holderless
            # and non-terminal (the lattice does not watch holderless work).
            # No-ops for every non-bracket wake (the discriminator is the item's
            # routing/slate wake-id matching this wake).
            WorkItems.rearm_on_fire_in_txn(txn, opts[:wake_id], opts[:target_gate])

            {:appended, target, message, opts}

          other ->
            other
        end
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
        case Supervision.ladder_target(txn, gate.reresolve_seed, gate.reresolve_rung) do
          nil -> nil
          target -> {target, nil, false}
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
          %{name: a.name, where: a.where, defaults: a.defaults}
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
          |> Enum.map(fn model ->
            model
            |> Map.put(:id, model.ref)
            |> Map.put(:name, model.display_name)
            |> Map.put(:provider, model.provider)
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
  @spec session_status(String.t(), DB.server()) :: map() | nil
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
            preferences -> preferences
          end

        {base_model, effort} = current_model_parts(session.model)
        {catalog, _health} = ModelCatalog.get(session.host, session.harness, ModelCatalog)
        unsupported = fn reason -> %{supported: false, reason: reason} end

        models_once = Enum.uniq_by(catalog, &base_ref(&1.ref))

        current_efforts =
          case Enum.find(catalog, &(not is_nil(base_model) and base_ref(&1.ref) == base_model)) do
            nil -> []
            entry -> entry.efforts
          end

        reasoning_capability =
          case current_efforts do
            [] ->
              reason =
                if is_nil(base_model),
                  do: "current model is unknown",
                  else: "current model has no effort tiers"

              unsupported.(reason)

            efforts ->
              %{
                supported: true,
                options: Enum.map(efforts, &%{title: &1, value: &1, enabled: true})
              }
          end

        %{
          # sessionKey is REQUIRED by the client's SessionStatus decoder — its
          # absence fails the whole decode and the model footer never
          # populates (found live; the TS reference omitted it too).
          sessionKey: session_key,
          display: %{
            # Base ref only: the footer both displays this text verbatim when
            # it can't match a catalog row and matches it against the (now
            # base-ref) catalog rows for the current-model checkmark. The
            # effort qualifier is carried separately in reasoningLevel.
            model: base_model || "unknown",
            modelPreferences: model_preferences,
            provider: session.provider,
            harness: session.harness,
            host: session.host,
            credentialKind: credential_kind(session),
            authMode: nil,
            reasoningLevel: effort,
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
                Enum.map(models_once, &%{title: &1.name, value: base_ref(&1.ref), enabled: true})
            },
            setThinking: unsupported.("thinking control lands in a later milestone"),
            setReasoning: reasoning_capability,
            setFastMode: unsupported.("not supported"),
            setMode: unsupported.("sessions run YOLO"),
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
            # stable identity; ref doubles as it here). The client's model
            # picker reads THIS list (falling back to setModel.options only
            # when unavailable) and sends ref back as the set_model value, so
            # rows are one-per-model with base refs — tune_result composes
            # the effort qualifier from the reasoning selection.
            models:
              Enum.map(
                models_once,
                &%{
                  id: base_ref(&1.ref),
                  ref: base_ref(&1.ref),
                  name: &1.name,
                  provider: session.provider
                }
              )
          }
        }
    end
  end

  defp current_model_parts(ref) when is_binary(ref), do: Adapter.parse_model_ref(ref)
  defp current_model_parts(_unknown), do: {nil, nil}

  defp base_ref(nil), do: nil
  defp base_ref(ref), do: elem(Adapter.parse_model_ref(ref), 0)

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
      nil -> wire_credential_kind(:none)
      _pid -> wire_credential_kind(Tightbeam.Credentials.kind(provider, server))
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
    rust_cli = Path.expand("cli/target/release/tightbeam", File.cwd!())

    if File.exists?(rust_cli) do
      File.cp!(rust_cli, wrapper)
    else
      # There is NO fallback. There used to be one, to the retired TypeScript CLI
      # in a sibling checkout: on a machine that had that checkout the operator
      # silently got a different implementation than the gateway that installed
      # it, and on a machine without it an executable that died on a path they
      # never chose. A fallback to a retired implementation only ever fires where
      # nobody is watching, so it is gone.
      Logger.warning(
        "tightbeam CLI not built: #{rust_cli} is missing, so #{wrapper} will refuse " <>
          "to run. Build it with: cargo build --release --manifest-path cli/Cargo.toml"
      )

      File.write!(wrapper, refusing_wrapper(rust_cli))
    end

    File.chmod!(wrapper, 0o755)
    Enum.each(Harness.all(), fn module -> :ok = module.install_cli_projection(bin_dir) end)

    bin_dir
  end

  # `bin/tightbeam` still EXISTS when the CLI was not built, because its absence
  # is itself confusing — but it does exactly one thing: say what is missing and
  # how to build it.
  defp refusing_wrapper(rust_cli) do
    """
    #!/bin/sh
    echo "tightbeam CLI is not installed: #{rust_cli} was missing when the gateway booted." >&2
    echo "Build it with: cargo build --release --manifest-path cli/Cargo.toml" >&2
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
      broadcast(db, session.owner_user_id, Payloads.assistant_typing(turn.session_key, true))

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
        broadcast(db, session.owner_user_id, Payloads.assistant_typing(turn.session_key, false))

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

      # The failure's STAGE is what classifies its cause; the reason itself is
      # passed through byte-for-byte (it is the chat bubble and the turn row).
      adapter_key = adapter_key(session)

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
                   600_000,
                   progress:
                     progress_fun(db, turn.session_key, session.owner_user_id, correlation)
                 )
               ) do
          # THE reply seam. The agent elected an attention tier for this turn (or
          # elected nothing, which is normal); the substrate copies the election
          # onto the reply it is appending. Marker and credential-transition
          # appends are not this seam and stay normal.
          case Projection.append(db, %{
                 session_key: turn.session_key,
                 role: "assistant",
                 content: result.text,
                 sender: "tightbeam",
                 reply_to_message_id: echo && echo.id,
                 reply_to_client_message_id: echo && echo.client_message_id,
                 attention_tier: elected_attention(db, turn.seq)
               }) do
            {:appended, reply} -> publish_message(db, turn.session_key, reply)
            _ -> :ok
          end

          {:ok, %{terminal_publish: terminal_publish}}
        else
          {:error, {failed_stage, reason}} ->
            condition = Adjudication.classify(reason)
            cause = adjudication_cause(failed_stage, reason, adapter_key)
            brief_inventories = adjudication_model_inventories(session)
            current_model = session_model_display(Org.get(db, turn.session_key).model)

            failure_publish = fn _terminal ->
              # No assistant final will arrive to clear the indicator label —
              # clear it explicitly (client treats state "failed" as terminal).
              broadcast(
                db,
                session.owner_user_id,
                Payloads.agent_progress(turn.session_key, correlation, 1_000_000, "", "failed")
              )

              publish_turn_state(db, turn.session_key, correlation, "failed", inspect(reason))

              broadcast(
                db,
                session.owner_user_id,
                Payloads.assistant_typing(turn.session_key, false)
              )

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

            adjudicate_in_txn = fn txn ->
              DB.Txn.q(
                txn,
                "UPDATE sessions SET adjudicationHold='*', updatedAt=?2 WHERE sessionKey=?1",
                [turn.session_key, System.system_time(:millisecond)]
              )

              if condition == "other" do
                Adjudication.record_unclassified_in_txn(txn, turn.session_key, reason)
              end

              episode_opts = [
                claim_window_ms: Map.get(config, :adjudication_claim_window_ms, 300_000),
                reresolve_seed: turn.session_key,
                reresolve_rung: 1,
                cause: cause,
                failing_wake_id: turn.wake_id,
                failing_seq: turn.seq
              ]

              episode =
                Adjudication.claim_in_txn(
                  txn,
                  turn.session_key,
                  condition,
                  episode_opts
                ) ||
                  Adjudication.reopen_in_txn(
                    txn,
                    turn.session_key,
                    condition,
                    episode_opts
                  )

              if episode do
                adjudication_prompt =
                  adjudication_brief(
                    session,
                    condition,
                    cause,
                    current_model,
                    brief_inventories
                  )

                Adjudication.notify_in_txn(
                  txn,
                  episode,
                  adjudication_prompt,
                  Map.get(config, :adjudication_response_window_ms, 86_400_000)
                )
              end
            end

            {:error,
             %{
               reason: reason,
               terminal_publish: failure_publish,
               adjudicate_in_txn: adjudicate_in_txn,
               post_commit: fn ->
                 # LEVEL half of the heal trigger. Reading readiness AFTER the
                 # hold commits is what closes the lost-edge window: a ready
                 # that fired before the hold existed (so the edge sweep saw
                 # nothing to sweep) is still observed here. It runs post-commit
                 # rather than in the transaction because the coordinator writes
                 # to the DB, and the txn body executes inside the DB owner.
                 heal_level_check(config, db, turn.session_key, cause, adapter_key)
                 Wakes.fire_due(config[:wake_scheduler] || Tightbeam.WakeScheduler)
               end
             }}
        end

      outcome
    end
  end

  defp stage(stage, {:error, reason}), do: {:error, {stage, reason}}
  defp stage(_stage, result), do: result

  # Which failures the adapter's own recovery can release, and which are genuine
  # decisions a human owns (spec s4-operability-v1 §2.1). A cause outside these
  # two classes stays NULL — indistinguishable from a legacy hold, and equally
  # never swept.
  defp adjudication_cause(:checkout, _reason, key), do: Adjudication.adapter_fault_cause(key)

  defp adjudication_cause(:session, {:adapter_unavailable, _reason}, key),
    do: Adjudication.adapter_fault_cause(key)

  defp adjudication_cause(:session, {:model_apply_failed, _reason}, _key), do: "model_decision"

  defp adjudication_cause(:prompt, reason, key) when reason in [:closed, :prompt_dispatch_failed],
    do: Adjudication.adapter_fault_cause(key)

  # The adapter died mid-turn (or stopped answering). A runtime adapter fault,
  # and heal-eligible: the replacement adapter's ready event releases the hold.
  defp adjudication_cause(:prompt, {:adapter_unavailable, _reason}, key),
    do: Adjudication.adapter_fault_cause(key)

  defp adjudication_cause(_stage, _reason, _key), do: nil

  defp session_model_display(model) when is_binary(model), do: model
  defp session_model_display(_unknown), do: "unknown"

  defp adapter_key(session), do: {Harness.parse!(session.harness).id(), "shared", session.host}

  # `condition` is the coarse classification bucket the episode is keyed on;
  # `cause` is the precise reason the record already carries. The human reading
  # this decides from the cause, so it is the line that must be here — a brief
  # that only says `condition=other` tells them nothing they can act on.
  defp adjudication_brief(session, condition, cause, current_model, inventories) do
    archetype = Archetypes.get(session.archetype) || Archetypes.builtin_default()

    """
    Model adjudication required.
    affected_session=#{session.session_key}
    condition=#{condition}
    cause=#{cause || "unclassified"}
    current_model=#{current_model}
    current_harness=#{session.harness}
    model_preferences=#{JSON.encode!(archetype.model_preferences)}
    live_catalog_host=#{session.host}
    live_catalog=#{JSON.encode!(inventories)}

    Reply with: tightbeam adjudicate --episode <correlationKey> --action park|swap|respawn|stop [--model <ref>] [--reason <text>]
    """
  end

  # The affected session's OWN host: an adjudicator choosing a replacement model
  # needs what that host can run, not what the gateway can. Read this outside the
  # ruling transaction; catalog refresh may consult the DB owner.
  defp adjudication_model_inventories(session) do
    Map.new(Harness.all(), fn module ->
      {models, health} = ModelCatalog.get(session.host, module.wire_name(), ModelCatalog)
      {module.wire_name(), %{health: inspect(health), models: Enum.map(models, & &1.ref)}}
    end)
  end

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
        broadcast(db, session.owner_user_id, Payloads.assistant_typing(session_key, false))

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
          broadcast(db, session.owner_user_id, Payloads.assistant_typing(call.session_key, false))

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

    case AdapterCoordinator.adapter_for(Tightbeam.AdapterCoordinator, key) do
      {:ok, adapter, generation} ->
        {:ok, adapter, generation}

      {:error, :degraded} ->
        {:error,
         "adapter for #{session.harness}/#{session.identity_name} on host #{session.host} is degraded " <>
           "(host unreachable or adapter failing); see /version"}
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

        pointer ->
          # The adapter PROCESS is the authority on residency: stamped
          # generations reset across boots and can spuriously match.
          case Adapter.knows_session?(adapter, pointer.harness_session_id) do
            true ->
              case push_known_model(adapter, pointer.harness_session_id, session.model) do
                :ok -> {:ok, pointer.harness_session_id}
                {:error, _reason} = error -> error
              end

            false ->
              revision = session.identity_revision || Identity.live_revision!(config.base_dir)

              snapshot = served_snapshot(config, session, harness, revision)

              AdapterCoordinator.with_load_slot(Tightbeam.AdapterCoordinator, session.host, fn ->
                case Adapter.load_session(
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
                      append_context_reset_marker(db, session)
                      {:ok, sid}
                    end
                end
              end)

            {:error, _reason} = error ->
              error
          end
      end

    case enrich_adapter_unavailable(config, result, adapter_key(session), generation) do
      {:ok, sid} ->
        :ok = Ledger.stamp_adapter(db, turn_seq, generation)
        {:ok, sid}

      error ->
        error
    end
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
           Adapter.new_session(adapter, session.model, cwd, mcp_servers, guidance),
         :ok <- capture_created_model(db, adapter, session, sid) do
      {:ok, sid}
    end
  end

  defp capture_created_model(_db, _adapter, %{model: model}, _sid) when is_binary(model),
    do: :ok

  defp capture_created_model(db, adapter, session, sid) do
    case Adapter.current_model(adapter, sid) do
      {:ok, reported_model} when is_binary(reported_model) ->
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
      onboard_phase(config, provider_atom(provider), phase, machine, kind, params[:reason])
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

  defp onboard_phase(config, provider, "begin", machine, kind, _reason) do
    case Tightbeam.Credentials.begin_onboard(provider, Tightbeam.Credentials.server(machine)) do
      {:ok, path} ->
        # The lease TTL rides the reply so the CLI's ceremony watchdog and the
        # server's lease are one fact with one home. A matching constant in the
        # Rust CLI would drift from `production_config` the first time either is
        # tuned, and the CLI cannot read `production_config` itself.
        #
        # `kind` is echoed, not consumed: a LEASE carries no opinion about what
        # will be banked into it (`Credentials.finish_onboard/3`). It is here so
        # a gateway log shows which ceremony an operator started — in the WIRE
        # spelling (`wire_credential_kind/1`), like every other surface: the
        # camelizer rewrites keys, not atom values, so a bare `kind` put the
        # store's "api_key" on a wire whose contract says "apiKey".
        %{
          provider: provider,
          kind: wire_credential_kind(kind),
          status: "ready",
          staging_path: path,
          lease_ttl_ms: config.onboarding_lease_ms
        }

      {:error, reason} ->
        %{code: "needs_onboarding", message: inspect(reason)}
    end
  end

  defp onboard_phase(_config, provider, "finish", machine, kind, _reason) do
    case Tightbeam.Credentials.finish_onboard(
           provider,
           kind,
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

  defp onboard_phase(_config, provider, "cancel", machine, _kind, reason) do
    :ok =
      Tightbeam.Credentials.cancel_onboard(
        provider,
        onboarding_failure(reason),
        Tightbeam.Credentials.server(machine)
      )

    %{provider: provider, status: "canceled"}
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
                defaults: a.defaults,
                modelPreferences: a.model_preferences
              }
            end),
          hosts:
            config.base_dir |> Placement.hosts(gateway_db(config)) |> Map.keys() |> Enum.sort(),
          models: picker_models(config.base_dir, gateway_db(config))
        }

        result = %{
          sessions:
            Enum.map(
              sessions,
              &Map.take(&1, [
                :session_key,
                :display_name,
                :handle,
                :archetype,
                :host,
                :harness,
                :model,
                :origin,
                :spawned_by,
                :state,
                :created_at
              ])
            ),
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
  end

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

          length(Org.list_for_user(db, caller.owner_user_id, false)) >=
              config.max_live_sessions_per_user ->
            %{
              code: "cap_exceeded",
              message:
                "live-session cap (#{config.max_live_sessions_per_user}) reached for #{caller.owner_user_id}"
            }

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

        with {:ok, overrides} <- override_result,
             {:ok, host} <-
               Placement.resolve(archetype, p[:host], Placement.hosts(config.base_dir, db)) do
          create_spawn(config, db, call, caller, archetype, host, overrides)
        else
          {:error, denial} -> classified_spawn_denial(denial, "config_denied", "placement_denied")
        end
    end
  end

  defp create_spawn(config, db, call, caller, archetype, host, overrides) do
    p = call.params
    defaults = defaults(config, db)
    harness = p[:harness] || archetype.defaults[:harness] || defaults.harness
    module = if is_atom(harness), do: Harness.module!(harness), else: Harness.parse!(harness)
    harness_string = module.wire_name()
    harness_atom = module.id()
    sessions = Org.list_for_user(db, caller.owner_user_id, false)

    model =
      p[:model] || archetype.defaults[:model] ||
        defaults.model

    identity_name = Placement.identity_name(config, archetype, overrides, harness_atom)

    # Placement resolved the host FIRST, so the ref is judged against the account
    # that will actually run the turn (#88) — not the gateway's.
    with :ok <- validate_credential(config, harness_string, host),
         :ok <- validate_catalog_model(host, harness_string, model, is_nil(p[:model])),
         :ok <- Spinup.ensure_ready(config, harness_atom, host, spinup_opts(config, db)) do
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
        provider: catalog_provider!(host, harness_string, model),
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
              else
                {:error, :unknown_archetype}
              end

            prior ->
              {:replayed, prior.session_key}
          end
        end)

      case session_result do
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

  defp classified_spawn_denial(denial, config_code, placement_code) do
    if denial[:code] in ["host_not_allowed", "unknown_host"],
      do: classified_denial(placement_code, denial),
      else: classified_denial(config_code, denial)
  end

  defp classified_denial(code, denial) do
    if denial[:code] in ["model_unavailable", "catalog_unavailable"] do
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
        case Org.get(db, call.session_key) do
          nil ->
            %{ok: false, code: "not_found"}

          session ->
            harness = p.harness
            module = Harness.parse!(harness)
            harness_atom = module.id()

            # Composed against the NEW harness, exactly as `set_model` composes against
            # the current one. A picker offers base refs -- `setModel.options` and
            # `modelCatalog.models` both advertise one row per model, deliberately, with
            # the effort tier owned by the reasoning picker -- but the catalog only ever
            # holds an effort-bearing model as `id[effort]`. So the value a client is
            # told to send was refused here as "not offered by <harness> on <host>",
            # while the same value through `set_model` was accepted. The advertised
            # shape was never wrong; this path just never learned to compose (#69).
            model =
              compose_model_selection(
                session.host,
                harness,
                session.model,
                p[:model] || config.default_model
              )

            with :ok <- validate_credential(config, harness, session.host),
                 :ok <-
                   validate_catalog_model(session.host, harness, model, is_nil(p[:model])),
                 :ok <-
                   Spinup.ensure_ready(
                     config,
                     harness_atom,
                     session.host,
                     spinup_opts(config, db)
                   ) do
              deliver_opts = if config[:sh], do: [sh: config.sh], else: []

              Placement.deliver_home(
                config,
                {harness_atom, "shared", session.host},
                deliver_opts
              )

              Org.set_harness(
                db,
                call.session_key,
                harness,
                catalog_provider!(session.host, harness, model),
                model
              )

              # History barrier (product ruling): a new engine gets a fresh
              # visible slate. Rows are RETAINED (never deleted) but replay
              # stops at the barrier, and live clients are told to drop their
              # local view. No pointer surgery: the old harness session can't
              # load on the new engine → fallback pointer, fresh context.
              #
              # ONE TRANSACTION, both writes. The barrier and its tombstone are a
              # single fact: history stopped being shown, and here is why. Split
              # across two transactions, a crash between them left the barrier
              # moved with no marker — which is precisely the silent burial the
              # tombstone exists to prevent, just rarer. The MAX(seq) read moved
              # inside too, so a message landing between the read and the barrier
              # cannot be buried without being counted.
              # DB.transaction CATCHES a raise and RETURNS {:error, exception}. A
              # hard {:ok, _} match here is a MatchError that crashes the wire
              # call instead of denying it — the trap already documented at
              # `ruling_transaction/2`, and one this very test caught.
              barrier =
                DB.transaction(db, fn txn ->
                  [[max_seq]] =
                    Txn.q(
                      txn,
                      "SELECT COALESCE(MAX(seq), 0) FROM messages WHERE sessionKey = ?1",
                      [call.session_key]
                    )

                  Org.set_cleared_through_in_txn(txn, call.session_key, max_seq)

                  # Probe seam (same idiom as `on_work_item_interlock`): lets a
                  # test fail the transaction BETWEEN the two writes and prove the
                  # barrier rolls back with them. Absent in production.
                  case Map.get(call, :on_swap_interlock) do
                    fun when is_function(fun, 1) -> fun.(txn)
                    _ -> :ok
                  end

                  Projection.append_marker_in_txn(
                    txn,
                    call.session_key,
                    swap_tombstone(session, harness, model)
                  )
                end)

              case barrier do
                {:error, error} ->
                  # Rolled back: the barrier did NOT move and the history is
                  # still shown. The session is already on the new engine, which
                  # is the safe direction to fail in — an operator sees their
                  # conversation and a refused swap, never an empty chat with no
                  # account of why. No broadcast either: there is nothing to tell
                  # clients to drop.
                  %{
                    ok: false,
                    code: "swap_barrier_failed",
                    message: describe_error(error)
                  }

                {:ok, _} ->
                  broadcast(
                    db,
                    session.owner_user_id,
                    Payloads.stream_history_cleared(call.session_key)
                  )

                  %{
                    ok: true,
                    harness: harness,
                    model: model,
                    # The swap may have crossed providers, and the new provider's
                    # credential on this host may be a different kind. This is
                    # the one moment the value changes without the client polling
                    # status. The router camelizes the key to `credentialKind`,
                    # matching the session-status shape.
                    credential_kind: credential_kind(Map.put(session, :harness, harness)),
                    note:
                      "engine swapped; chat cleared (rows retained); model context starts fresh"
                  }
              end
            else
              {:error, denial} ->
                denial
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
        case Org.get(db, call.session_key) do
          nil ->
            %{ok: false, code: "not_found"}

          session ->
            new_ref =
              compose_model_selection(session.host, session.harness, session.model, p.model)

            apply_model_change(config, db, call, session, new_ref)
        end

      p[:setting] == "set_reasoning" and is_binary(p[:reasoningLevel]) ->
        case Org.get(db, call.session_key) do
          nil ->
            %{ok: false, code: "not_found"}

          %{model: model} when not is_binary(model) ->
            %{
              ok: false,
              code: "model_unknown",
              message: "reasoning cannot be changed while the current model is unknown"
            }

          session ->
            new_ref = "#{base_ref(session.model)}[#{p.reasoningLevel}]"
            apply_model_change(config, db, call, session, new_ref)
        end

      true ->
        %{ok: false, code: "unsupported", message: "tune does not support #{p[:setting]} yet"}
    end
  end

  # A bare model id (no "[effort]" suffix, e.g. from setModel.options) is
  # composed with the session's current effort, falling back to "medium" or
  # the first available tier when the current effort doesn't apply to the
  # newly selected model. A ref already carrying "[effort]" is passed through
  # unchanged (back-compat with callers that send a full ref directly).
  defp compose_model_selection(host, harness, current_ref, selected) do
    if String.contains?(selected, "[") do
      selected
    else
      {_current_base, current_effort} = current_model_parts(current_ref)

      case efforts_for(host, harness, selected) do
        [] ->
          selected

        efforts ->
          "#{selected}[#{pick_effort(efforts, current_effort)}]"
      end
    end
  end

  defp pick_effort(efforts, current_effort) do
    cond do
      current_effort in efforts -> current_effort
      "medium" in efforts -> "medium"
      true -> List.first(efforts)
    end
  end

  defp efforts_for(host, harness, base_model) do
    {catalog, _health} = ModelCatalog.get(host, harness, ModelCatalog)

    case Enum.find(catalog, &(base_ref(&1.ref) == base_model)) do
      nil -> []
      entry -> entry.efforts
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

  defp apply_model_change(config, db, _call, session, new_ref) do
    with :ok <- validate_catalog_model(session.host, session.harness, new_ref, false),
         {%{provider: provider}, _health} <-
           ModelCatalog.entry(session.host, session.harness, new_ref, ModelCatalog) do
      result =
        run_session_mutation(session.session_key, fn ->
          apply_tuned_model(
            config,
            db,
            session,
            new_ref,
            Atom.to_string(provider)
          )
        end)

      case result do
        :ok ->
          %{ok: true}

        {:error, reason} ->
          # `reason:` is not a key the wire carries. `control_json` emits only `code`
          # and `message`, so this returned `ok: false` with NEITHER -- and dropped
          # the reason on the floor on the way out. A client saw a bare false and
          # could not tell a refusal from a fault, which is the one thing a control
          # response exists to say.
          %{
            ok: false,
            code: "model_apply_failed",
            message: "the live session did not accept #{new_ref}: #{inspect(reason)}"
          }
      end
    else
      {:error, denial} -> denial
    end
  end

  defp apply_tuned_model(config, db, session, new_ref, provider) do
    case Org.current_pointer(db, session.session_key) do
      nil ->
        Org.set_model(db, session.session_key, new_ref, provider)
        :ok

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
            true ->
              apply_and_project_tuned_model(
                db,
                session,
                adapter,
                pointer.harness_session_id,
                new_ref,
                provider
              )

            false ->
              cwd = Placement.holder_workdir(config, session)
              revision = session.identity_revision || Identity.live_revision!(config.base_dir)
              snapshot = served_snapshot(config, session, harness, revision)

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
                  new_ref,
                  provider
                )
              end

            {:error, _reason} = error ->
              error
          end
        else
          false -> {:error, :adapter_unavailable}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp apply_and_project_tuned_model(db, session, adapter, sid, new_ref, provider) do
    # The per-session mutation lock is held by the caller. Adapter work finishes
    # before the DB transaction begins; the DB owner never calls upward.
    case Adapter.apply_model(adapter, sid, new_ref) do
      :ok ->
        project_tuned_model(db, session, adapter, sid, new_ref, provider)

      {:error, _reason} = error ->
        error
    end
  end

  defp project_tuned_model(db, session, adapter, sid, new_ref, provider) do
    result =
      DB.transaction(db, fn txn ->
        [[record_model, record_harness]] =
          Txn.q(
            txn,
            "SELECT model, harness FROM sessions WHERE sessionKey=?1",
            [session.session_key]
          )

        case Org.swap_model_in_txn(
               txn,
               session.session_key,
               {record_model, record_harness},
               {new_ref, record_harness, provider}
             ) do
          {:ok, _} -> :ok
          {:duplicate, _} -> :ok
          :stale -> raise("model mutation race inside serialized tune")
        end
      end)

    case result do
      {:ok, :ok} ->
        :ok

      {:error, error} ->
        :ok = Adapter.forget_model_residency(adapter, sid)
        raise error
    end
  end

  # Every refusal names the harness, the HOST that owns the catalog, and the
  # repair ON THAT HOST. The catalog belongs to the account that will run the
  # turn, so sending an operator to the gateway to fix a satellite's grant — as
  # this did before per-host catalogs — sent them to the wrong machine.
  defp validate_catalog_model(host, harness, model, configured_default?) do
    case is_binary(model) && ModelCatalog.member?(host, harness, model) do
      %{present?: true, health: :fresh} ->
        :ok

      %{health: :fresh} ->
        warn_dead_default(host, harness, model, configured_default?)

        {:error,
         %{
           code: "model_unavailable",
           message:
             "model #{inspect(model)} is not offered by #{harness} on host #{host}" <>
               offered_models_hint(host, harness)
         }}

      %{health: {:unavailable, {:needs_onboarding, reason}}} ->
        warn_dead_default(host, harness, model, configured_default?)
        provider = Harness.parse!(harness).credential_provider()

        {:error,
         %{
           code: "catalog_unavailable",
           message:
             "cannot validate model #{inspect(model)} for #{harness} on host #{host}: no " <>
               "#{harness} model catalog there, because #{provider} has no usable credential " <>
               "on #{host} (#{inspect(reason)}). A catalog is derived on the host that runs " <>
               "the turn, so this is #{host}'s grant to fix; run tightbeam onboard " <>
               "#{provider} on #{host}"
         }}

      # The codex models endpoint filters by the caller's client_version and says
      # nothing about it: too old a binary and every model is dropped, with a 200.
      # Blaming the account here would send the operator to re-onboard a grant
      # that was never the problem.
      %{health: {:unavailable, {:empty_catalog_for_client_version, version}}} ->
        warn_dead_default(host, harness, model, configured_default?)

        {:error,
         %{
           code: "catalog_unavailable",
           message:
             "cannot validate model #{inspect(model)} for #{harness} on host #{host}: the " <>
               "provider returned an EMPTY model list for client_version #{inspect(version)}, " <>
               "which is the #{harness} binary's own version on #{host}. The credential is " <>
               "not implicated; upgrade #{harness} on #{host}"
         }}

      %{health: health} ->
        warn_dead_default(host, harness, model, configured_default?)

        {:error,
         %{
           code: "catalog_unavailable",
           message:
             "cannot validate model #{inspect(model)} for #{harness} on host #{host}: " <>
               "#{inspect(health)}"
         }}

      false ->
        warn_dead_default(host, harness, model, configured_default?)
        {:error, %{code: "model_unavailable", message: "model must be specified"}}
    end
  end

  # A refusal that names only the rejected value makes the operator guess. The
  # catalog is already in hand, so say what IS offered — harness-agnostic, and for
  # claude it reflects the selectable filter rather than the raw API list.
  defp offered_models_hint(host, harness) do
    case ModelCatalog.get(host, harness, ModelCatalog) do
      {[_ | _] = entries, _health} ->
        "; offered: " <> (entries |> Enum.map(& &1.ref) |> Enum.sort() |> Enum.join(", "))

      _ ->
        ""
    end
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
           message:
             "#{harness} on #{machine} needs onboarding: " <>
               "#{inspect(reason)}; run tightbeam onboard #{provider} on #{machine}"
         }}
    end
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
    |> Enum.each(fn module ->
      AdapterCoordinator.close_adapter(
        Tightbeam.AdapterCoordinator,
        {module.id(), "shared", machine}
      )
    end)

    :ok
  end

  defp park_provider_runtime(provider, machine) do
    provider
    |> harnesses_for_provider()
    |> Enum.each(fn module ->
      AdapterCoordinator.request_close_adapter(
        Tightbeam.AdapterCoordinator,
        {module.id(), "shared", machine}
      )
    end)

    :ok
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

  defp warn_dead_default(_host, _harness, _model, false), do: :ok

  defp warn_dead_default(host, harness, model, true) do
    Logger.warning(
      "configured default model #{inspect(model)} is not currently offered by " <>
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

  # The agent ELECTS its reply's attention tier, during its own turn. Two tiers:
  # normal (0, the default an agent that elects nothing gets) and high (1). The
  # substrate derives nothing — there is no kind-to-tier mapping and no anti-
  # inflation rule — and what a client DOES with the tier is the client's business.
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
                %{turn_seq: seq, attention: attention_name(tier)}
            end
          end)

        result

      _ ->
        %{code: "invalid", message: "attend requires a session caller"}
    end
  end

  defp attention_name(1), do: "high"
  defp attention_name(_), do: "normal"

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

  defp retire_cascade_in_txn(txn, root_key, owner, drain_reason) do
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
            retire_session_in_txn(txn, member.session_key, owner, drain_reason)

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

  defp retire_session_in_txn(txn, session_key, owner, drain_reason) do
    assignments = Assignments.interrupt_for_retire_in_txn(txn, session_key, owner)
    Org.retire_in_txn(txn, session_key)
    Ledger.drain_queued_for_retire_in_txn(txn, session_key, drain_reason)
    assignments
  end

  defp adjudicate_result(config, db, call) do
    p = call.params
    episode = Adjudication.get_by_correlation(db, p[:episode])

    caller_key =
      case call[:principal] do
        {:session, key} -> key
        _ -> nil
      end

    cond do
      is_nil(episode) or episode.status != "notified" ->
        # The other direction of the heal-vs-ruling race: this ruling lost to an
        # adapter heal that already resolved the episode. It is an acknowledged
        # no-op, not a silent one.
        if episode && episode.heal_token,
          do: log_superseded(db, episode, call.params[:action])

        %{code: "denied", message: "stale or unknown adjudication episode"}

      caller_key != episode.owner_target ->
        %{code: "denied", message: "current adjudication owner required"}

      p[:action] not in ~w(park swap respawn stop) ->
        %{code: "invalid", message: "action must be park, swap, respawn, or stop"}

      p[:action] in ~w(swap respawn) and not is_binary(p[:model]) ->
        %{code: "invalid", message: "--model is required for #{p.action}"}

      true ->
        adjudicate_action(config, db, call, episode)
    end
  end

  defp adjudicate_action(config, db, call, episode) do
    action = fn ->
      case call.params.action do
        "park" -> adjudicate_park(config, db, call, episode)
        "swap" -> adjudicate_swap(config, db, call, episode)
        "respawn" -> adjudicate_respawn(config, db, call, episode)
        "stop" -> adjudicate_stop(config, db, call, episode)
      end
    end

    # A ruling validated as `notified` can still lose to an adapter heal before
    # its action transaction commits (the inverse TOCTOU of the heal's own CAS).
    # That is an acknowledged no-op, not a crash: the transaction rolled back, so
    # nothing the RULING decides survives, and the caller gets the same denial it
    # would have got a millisecond earlier. Swap closes this window separately by
    # rechecking the episode before touching the harness inside its one ruling
    # transaction.
    case run_session_mutation(episode.session_key, fn ->
           try do
             {:ok, action.()}
           rescue
             AdjudicationSuperseded -> :superseded
           end
         end) do
      {:ok, result} ->
        result

      :superseded ->
        log_superseded(db, episode, call.params[:action])
        %{code: "denied", message: "stale or unknown adjudication episode"}
    end
  end

  # DB.transaction CATCHES a raise and RETURNS {:error, exception} — it does not
  # propagate. A superseded ruling therefore arrives here as a RETURN VALUE, and a
  # hard {:ok, _} match on it is a MatchError that crashes the wire call instead of
  # denying the ruling (cross-review round 2, F3). Re-raising OUTSIDE the
  # transaction is what puts it in reach of adjudicate_action's rescue; the
  # transaction has already rolled back, so nothing the ruling decided survives.
  defp ruling_transaction(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> {:ok, result}
      {:error, %AdjudicationSuperseded{} = superseded} -> raise superseded
      {:error, error} -> raise error
    end
  end

  # `resolved` with a healToken means a heal won; anything else is the ordinary
  # stale-correlation case the ruling paths have always raised on.
  defp superseded_or_stale(%{status: "resolved", heal_token: token}) when not is_nil(token),
    do: %AdjudicationSuperseded{}

  defp superseded_or_stale(_episode), do: RuntimeError.exception("stale adjudication episode")

  defp log_superseded(db, episode, action) do
    EventLog.lifecycle(
      db,
      "adjudication_ruling_superseded",
      episode.session_key,
      JSON.encode!(%{
        episodeId: episode.episode_id,
        cause: episode.cause,
        healToken: episode.heal_token,
        action: action
      })
    )
  end

  defp adjudicate_stop(config, db, call, episode) do
    session = Org.get(db, episode.session_key)

    {:ok, result} =
      ruling_transaction(db, fn txn ->
        current = Adjudication.get_by_correlation_in_txn(txn, episode.correlation_key)

        if current && Adjudication.resolve_in_txn(txn, current) do
          result =
            retire_cascade_in_txn(
              txn,
              current.session_key,
              session.owner_user_id,
              "retired: adjudication stopped session before execution"
            )

          EventLog.lifecycle_in_txn(
            txn,
            "model_adjudication_stop",
            current.session_key,
            JSON.encode!(%{
              reason: call.params[:reason],
              condition: current.condition,
              correlationKey: current.correlation_key
            })
          )

          result
        else
          raise superseded_or_stale(current)
        end
      end)

    Enum.each(result.retired, fn retired ->
      broadcast(db, session.owner_user_id, Payloads.stream_deleted(retired.session_key))
      Map.get(config, :on_retired, fn _ -> :ok end).(retired.session_key)

      Enum.each(retired.assignments, fn assignment ->
        emit_assignment_change(db, assignment.assignment_id, assignment.from_state)
      end)
    end)

    reap_retired_sessions(config, db, Enum.map(result.retired, & &1.session_key))

    %{
      ok: true,
      action: "stop",
      session_key: episode.session_key,
      retired_session_keys: Enum.map(result.retired, & &1.session_key),
      deferred: result.deferred
    }
  end

  defp adjudicate_park(config, db, call, episode) do
    session = Org.get(db, episode.session_key)

    due_at =
      System.system_time(:millisecond) +
        Map.get(config, :adjudication_park_fallback_ms, 14_400_000)

    scope = session.harness <> ":" <> session.identity_name

    {:ok, {wake_id, delivery}} =
      ruling_transaction(db, fn txn ->
        current = Adjudication.get_by_correlation_in_txn(txn, episode.correlation_key)

        wake =
          Wakes.schedule_in_txn(txn, %{
            session_key: current.session_key,
            origin: "process:tightbeam",
            creator_session_key: current.owner_target,
            prompt:
              "Quota recovery check: re-derive the model block and re-adjudicate from current facts.",
            due_at: due_at,
            condition_kind: "quota-recovered",
            condition_scope: scope
          })

        if Adjudication.resolve_in_txn(txn, current, wake.wake_id) do
          EventLog.lifecycle_in_txn(
            txn,
            "adjudication_block",
            current.session_key,
            JSON.encode!(%{
              reason: call.params[:reason],
              condition: current.condition,
              correlationKey: current.correlation_key,
              by: current.owner_target
            })
          )

          already_recovered =
            Txn.q(
              txn,
              "SELECT 1 FROM condition_facts WHERE kind='quota-recovered' AND scope=?1 ORDER BY id DESC LIMIT 1",
              [scope]
            ) != []

          delivery =
            if already_recovered do
              Wakes.cancel_pending_in_txn(txn, wake.wake_id)

              delivered =
                deliver_prompt_in_txn(
                  txn,
                  current.session_key,
                  "process:tightbeam",
                  "Quota is already recorded recovered. Re-derive the block and re-adjudicate.",
                  wake_id: wake.wake_id,
                  sender: "process:tightbeam"
                )

              arm_hold_in_txn(txn, current.session_key, wake.wake_id)
              delivered
            end

          {wake.wake_id, delivery}
        else
          raise superseded_or_stale(current)
        end
      end)

    if delivery, do: complete_delivery(db, delivery)
    %{ok: true, action: "park", recovery_wake_id: wake_id}
  end

  defp adjudicate_swap(_config, db, call, episode) do
    session = Org.get(db, episode.session_key)

    with {:ok, harness, provider} <- harness_for_ref(session.host, call.params.model) do
      if harness != session.harness do
        %{
          code: "cross_harness_requires_respawn",
          message: "use --action respawn for a cross-harness model"
        }
      else
        case strict_model_adapter(db, session) do
          {:ok, adapter, sid} ->
            adjudicate_model_swap(
              db,
              call,
              episode,
              harness,
              provider,
              adapter,
              sid
            )

          {:error, reason} ->
            strict_apply_error(reason)
        end
      end
    else
      {:error, error} -> error
    end
  end

  # The session-mutation worker owns this prepare → apply → commit sequence, so
  # it survives the wire caller and excludes tune, competing rulings, and heal.
  # Each DB transaction closes before the Adapter call begins.
  defp adjudicate_model_swap(db, call, episode, harness, provider, adapter, sid) do
    with {:ok, {:prepared, prepared}} <- prepare_adjudicated_model_swap(db, episode),
         {:ok, applied_model} <-
           Adapter.apply_model_strict(
             adapter,
             sid,
             call.params.model,
             prepared.record_model
           ) do
      case commit_adjudicated_model_swap(
             db,
             prepared,
             applied_model,
             harness,
             provider
           ) do
        {:ok, {:applied, delivery, wake_id}} ->
          complete_delivery(db, delivery)
          %{ok: true, action: "swap", model: applied_model, recovery_wake_id: wake_id}

        {:ok, {:denied, current}} ->
          :ok = Adapter.forget_model_residency(adapter, sid)

          if current && current.heal_token,
            do: log_superseded(db, current, call.params[:action])

          %{code: "denied", message: "stale or unknown adjudication episode"}

        {:ok, :model_commit_race} ->
          :ok = Adapter.forget_model_residency(adapter, sid)
          strict_apply_error(:model_readback_unavailable)

        {:error, error} ->
          :ok = Adapter.forget_model_residency(adapter, sid)
          raise error
      end
    else
      {:ok, {:denied, current}} ->
        if current && current.heal_token,
          do: log_superseded(db, current, call.params[:action])

        %{code: "denied", message: "stale or unknown adjudication episode"}

      {:error, reason} when is_atom(reason) ->
        strict_apply_error(reason)

      {:error, error} ->
        raise error
    end
  end

  defp prepare_adjudicated_model_swap(db, episode) do
    DB.transaction(db, fn txn ->
      current = Adjudication.get_by_correlation_in_txn(txn, episode.correlation_key)

      if is_nil(current) or current.status != "notified" do
        {:denied, current}
      else
        [[record_model, record_harness]] =
          Txn.q(
            txn,
            "SELECT model, harness FROM sessions WHERE sessionKey=?1",
            [current.session_key]
          )

        {:prepared,
         %{
           current: current,
           record_model: record_model,
           record_harness: record_harness
         }}
      end
    end)
  end

  defp commit_adjudicated_model_swap(db, prepared, applied_model, harness, provider) do
    DB.transaction(db, fn txn ->
      current =
        Adjudication.get_by_correlation_in_txn(
          txn,
          prepared.current.correlation_key
        )

      cond do
        is_nil(current) or current.status != "notified" ->
          {:denied, current}

        true ->
          [[record_model, record_harness]] =
            Txn.q(
              txn,
              "SELECT model, harness FROM sessions WHERE sessionKey=?1",
              [current.session_key]
            )

          if {record_model, record_harness} !=
               {prepared.record_model, prepared.record_harness} do
            :model_commit_race
          else
            case Org.swap_model_in_txn(
                   txn,
                   current.session_key,
                   {record_model, record_harness},
                   {applied_model, harness, provider}
                 ) do
              {:ok, _} -> :ok
              {:duplicate, _} -> :ok
              :stale -> raise("model mutation race inside serialized ruling")
            end

            recovery_prompt =
              "Your previous turn failed: #{current.condition}. You now run on #{applied_model}. Re-derive state from the facts and continue."

            wake_id =
              Adjudication.deterministic_wake_in_txn(
                txn,
                current,
                "recovery",
                current.session_key,
                recovery_prompt
              )

            unless Adjudication.resolve_in_txn(txn, current, wake_id),
              do: raise("adjudication changed inside serialized ruling")

            delivery =
              deliver_prompt_in_txn(
                txn,
                current.session_key,
                "process:tightbeam",
                recovery_prompt,
                wake_id: wake_id,
                sender: "process:tightbeam",
                fire_wake_in_txn: true
              )

            arm_hold_in_txn(txn, current.session_key, wake_id)

            EventLog.lifecycle_in_txn(
              txn,
              "model_adjudication",
              current.session_key,
              JSON.encode!(%{
                from_model: record_model,
                to_model: applied_model,
                from_harness: record_harness,
                to_harness: harness,
                trigger: current.condition,
                adjudicated_by: current.owner_target,
                correlationKey: current.correlation_key,
                harness_crossed: false,
                context_discarded: false
              })
            )

            {:applied, delivery, wake_id}
          end
      end
    end)
  end

  defp strict_apply_error(reason) do
    code =
      case reason do
        atom when is_atom(atom) -> Atom.to_string(atom)
        _ -> "model_apply_failed"
      end

    %{code: code, message: "strict model apply failed: #{inspect(reason)}"}
  end

  defp adjudicate_respawn(config, db, call, episode),
    do: adjudicate_respawn(config, db, call, episode, 8)

  defp adjudicate_respawn(_config, _db, _call, _episode, 0),
    do: %{code: "workspace_move_race", message: "assignments kept changing during respawn"}

  defp adjudicate_respawn(config, db, call, episode, attempts) do
    old = Org.get(db, episode.session_key)

    with {:ok, harness, provider} <- harness_for_ref(old.host, call.params.model) do
      new_session_key = "agent:" <> Tightbeam.Id.uuid4()

      {:ok, transferred_rows} =
        DB.query(
          db,
          "SELECT id FROM assignments WHERE holderKey=?1 AND state='open' ORDER BY openedAt,id",
          [old.session_key]
        )

      transferred_assignment_ids = Enum.map(transferred_rows, &hd/1)

      prepared_rearms =
        EffortCheckin.prepare_transferred_rearms(
          db,
          config,
          %{old | session_key: new_session_key},
          transferred_assignment_ids
        )

      transaction_result =
        DB.transaction(db, fn txn ->
          current_assignment_ids =
            Txn.q(
              txn,
              "SELECT id FROM assignments WHERE holderKey=?1 AND state='open' ORDER BY openedAt,id",
              [old.session_key]
            )
            |> Enum.map(&hd/1)

          unless current_assignment_ids == transferred_assignment_ids and
                   EffortCheckin.prepared_rearms_current?(
                     txn,
                     old.session_key,
                     prepared_rearms
                   ) do
            raise EffortRearmRace
          end

          current = Adjudication.get_by_correlation_in_txn(txn, episode.correlation_key)

          {archetype, overrides, identity_name} =
            if Archetypes.get(old.archetype) do
              {old.archetype, old.overrides, old.identity_name}
            else
              # Unlearn may have published while this respawn was queued after
              # snapshotting `old`. Resolve at the DB-owner boundary exactly as
              # repoint does, leaving no reference to the removed identity.
              {"default", nil, "default"}
            end

          new_session =
            Org.create_in_txn(txn, %{
              session_key: new_session_key,
              display_name: old.display_name,
              kind: old.kind,
              owner_user_id: old.owner_user_id,
              origin: old.origin,
              spawned_by: old.spawned_by,
              archetype: archetype,
              overrides: overrides,
              identity_name: identity_name,
              host: old.host,
              harness: harness,
              provider: provider,
              model: call.params.model
            })

          recovery_prompt =
            "Your predecessor's turn failed: #{current.condition}. Continue on #{call.params.model}; re-derive state from durable facts."

          wake_id =
            Adjudication.deterministic_wake_in_txn(
              txn,
              current,
              "recovery",
              new_session.session_key,
              recovery_prompt
            )

          [[failed_prompt_seq]] =
            Txn.q(
              txn,
              """
              SELECT COALESCE(m.seq, 0) FROM turns AS t
              JOIN messages AS m ON m.id=t.messageId
              WHERE t.sessionKey=?1 AND t.status='failed'
              ORDER BY t.seq DESC LIMIT 1
              """,
              [old.session_key]
            )

          Txn.q(
            txn,
            "UPDATE sessions SET clearedThroughSeq=?2 WHERE sessionKey=?1",
            [old.session_key, failed_prompt_seq]
          )

          {:appended, marker} =
            Projection.append_in_txn(txn, %{
              session_key: old.session_key,
              role: "assistant",
              content:
                "[model recovery]\n\nThis session continues as #{new_session.session_key} on #{call.params.model}.",
              sender: "process:tightbeam"
            })

          Txn.q(
            txn,
            "UPDATE roles SET boundSessionKey=?2, updatedAt=?3 WHERE boundSessionKey=?1",
            [old.session_key, new_session.session_key, System.system_time(:millisecond)]
          )

          Txn.q(txn, "UPDATE assignments SET holderKey=?2 WHERE holderKey=?1 AND state='open'", [
            old.session_key,
            new_session.session_key
          ])

          EffortCheckin.apply_prepared_rearms_in_txn(
            txn,
            config,
            new_session.session_key,
            prepared_rearms
          )

          retire_session_in_txn(
            txn,
            old.session_key,
            old.owner_user_id,
            "retired: adjudication respawned session before execution"
          )

          unless Adjudication.resolve_in_txn(txn, current, wake_id),
            do: raise(superseded_or_stale(current))

          delivery =
            deliver_prompt_in_txn(
              txn,
              new_session.session_key,
              "process:tightbeam",
              recovery_prompt,
              wake_id: wake_id,
              sender: "process:tightbeam",
              fire_wake_in_txn: true
            )

          arm_hold_in_txn(txn, new_session.session_key, wake_id)

          EventLog.lifecycle_in_txn(
            txn,
            "model_adjudication",
            old.session_key,
            JSON.encode!(%{
              from_model: old.model,
              to_model: call.params.model,
              from_harness: old.harness,
              to_harness: harness,
              trigger: current.condition,
              adjudicated_by: current.owner_target,
              correlationKey: current.correlation_key,
              harness_crossed: old.harness != harness,
              context_discarded: true
            })
          )

          {new_session, delivery, wake_id, marker}
        end)

      case transaction_result do
        {:error, %EffortRearmRace{}} ->
          adjudicate_respawn(config, db, call, episode, attempts - 1)

        {:error, %AdjudicationSuperseded{} = superseded} ->
          raise superseded

        {:error, error} ->
          raise error

        {:ok, {new_session, delivery, wake_id, marker}} ->
          publish_message(db, old.session_key, marker)

          broadcast(
            db,
            old.owner_user_id,
            Payloads.stream_history_cleared(old.session_key)
          )

          complete_delivery(db, delivery)

          broadcast(db, old.owner_user_id, Payloads.stream_deleted(old.session_key))

          broadcast(
            db,
            new_session.owner_user_id,
            Payloads.stream_created(Payloads.stream_session(new_session))
          )

          reap_retired_sessions(config, db, [old.session_key])

          %{
            ok: true,
            action: "respawn",
            retired_session_key: old.session_key,
            session_key: new_session.session_key,
            recovery_wake_id: wake_id
          }
      end
    else
      {:error, error} -> error
    end
  end

  @doc """
  Auto-release every session held on an adapter fault for `cause`, because that
  adapter is ready again at `token` (spec s4-operability-v1 §2 — dark factory: no
  operator verb exists for this). Idempotent: one probe per (hold, token), so a
  replayed ready event does nothing.

  The EDGE trigger (a ready event) calls this for all held sessions; the LEVEL
  trigger (a hold committing while the adapter is already ready) calls it for
  one; the probe RETRY calls it for one with `include_equal: true` — a re-hold
  is a new hold, and its one probe may re-use the token that probed its
  predecessor (spec §2, ruled 2026-07-28).
  """
  @spec adapter_healed(map(), DB.server(), String.t(), AdapterCoordinator.heal_token(), keyword()) ::
          [{String.t(), String.t(), :released | :lost | {:error, term()}}]
  def adapter_healed(config, db, cause, token, opts \\ []) do
    encoded = AdapterCoordinator.encode_token(token)
    only = Keyword.get(opts, :session_key)
    only_condition = Keyword.get(opts, :condition)

    Adjudication.heal_candidates(db, cause, token, Keyword.take(opts, [:include_equal]))
    |> Enum.filter(fn {session_key, condition} ->
      (is_nil(only) or session_key == only) and
        (is_nil(only_condition) or condition == only_condition)
    end)
    |> Enum.map(fn {session_key, condition} ->
      {session_key, condition, release_hold(config, db, session_key, condition, cause, encoded)}
    end)
  end

  # ONE atomic transition per held session: resolve the episode, dispose the
  # owner wake, create the probe wake AND its turn, and narrow the hold
  # '*' → probeWakeId. The hold narrowing is the CAS that decides every race —
  # a human ruling that got there first armed its own recovery hold, so '*' no
  # longer matches and this transition loses cleanly.
  defp release_hold(config, db, session_key, condition, cause, encoded_token) do
    result =
      with_session_mutation_lock(session_key, fn ->
        DB.transaction(db, fn txn ->
          # The DB is one serialized writer under BEGIN IMMEDIATE, so reading and
          # then writing in the same transaction IS the compare-and-swap. BOTH
          # guards are read before any write, so a loser leaves nothing behind:
          # the session must still be held WIDE, and the episode must still be in a
          # state a heal may take. A human ruling that resolved the episode is NOT
          # such a state, and a delayed park leaves the hold wide while doing
          # exactly that — so the hold alone is not a sufficient guard (F3).
          held? =
            Txn.q(txn, "SELECT adjudicationHold FROM sessions WHERE sessionKey=?1", [
              session_key
            ])

          episode = Adjudication.get_in_txn(txn, session_key, condition)

          if held? == [["*"]] and is_map(episode) and Adjudication.heal_eligible?(episode) do
            probe_wake_id = Adjudication.probe_wake_in_txn(txn, episode, encoded_token)

            unless Adjudication.heal_resolve_in_txn(txn, episode, probe_wake_id, encoded_token),
              do: raise(HealLost)

            disposition = Adjudication.dispose_owner_wake_in_txn(txn, episode)

            delivery =
              deliver_prompt_in_txn(
                txn,
                session_key,
                "process:tightbeam",
                Adjudication.probe_prompt(),
                wake_id: probe_wake_id,
                sender: "process:tightbeam",
                fire_wake_in_txn: true
              )

            # No probe TURN means no probe terminal to clear the hold; refuse to
            # narrow the hold rather than wedge the session on a wake that will
            # never be answered.
            unless match?({:appended, _target, _message, _opts}, delivery),
              do: raise("heal probe was not enqueued: #{inspect(delivery)}")

            arm_hold_in_txn(txn, session_key, probe_wake_id)

            EventLog.lifecycle_in_txn(
              txn,
              "adjudication_hold_healed",
              session_key,
              JSON.encode!(%{
                cause: cause,
                condition: condition,
                episodeId: episode.episode_id,
                healToken: encoded_token,
                probeWakeId: probe_wake_id,
                ownerWake: to_string(disposition)
              })
            )

            {:released, delivery}
          else
            :lost
          end
        end)
      end)

    case result do
      {:ok, {:released, delivery}} ->
        complete_delivery(db, delivery)
        Wakes.fire_due(config[:wake_scheduler] || Tightbeam.WakeScheduler)
        :released

      {:ok, :lost} ->
        heal_lost(db, session_key, cause, condition, encoded_token)
        :lost

      {:error, %HealLost{}} ->
        # The episode-state CAS lost mid-transaction; the raise rolled the
        # attempt back. A legitimate no-op, same as losing the hold CAS.
        heal_lost(db, session_key, cause, condition, encoded_token)
        :lost

      {:error, error} ->
        # NOT a lost race — the transaction itself failed (probe not enqueued,
        # DB error). A retry consumer must keep its wake pending on this arm:
        # consuming it would eat the hold's only feeder.
        Logger.error(
          "adjudication heal errored for #{session_key} (#{condition}): #{inspect(error)}"
        )

        EventLog.lifecycle(
          db,
          "adjudication_heal_error",
          session_key,
          JSON.encode!(%{
            cause: cause,
            condition: condition,
            healToken: encoded_token,
            error: inspect(error)
          })
        )

        {:error, error}
    end
  end

  # Dark != silent: the decision NOT to probe is recorded (a human ruling owns
  # this hold, or another episode's release narrowed it first).
  defp heal_lost(db, session_key, cause, condition, encoded_token) do
    EventLog.lifecycle(
      db,
      "adjudication_heal_lost",
      session_key,
      JSON.encode!(%{cause: cause, condition: condition, healToken: encoded_token})
    )
  end

  defp heal_level_check(config, db, session_key, cause, adapter_key) do
    coordinator = Map.get(config, :adapter_coordinator, Tightbeam.AdapterCoordinator)

    with true <- Adjudication.adapter_fault?(cause),
         {:ok, token} <- AdapterCoordinator.ready_token(coordinator, adapter_key) do
      adapter_healed(config, db, cause, token, session_key: session_key)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Probe RETRY (spec s4-operability-v1 §2, ruled 2026-07-28): the wake a
  # non-delivered probe terminal armed, fired after its backoff. BOUND: the
  # payload names the episode, cause, and the failed probe it retries, and the
  # consumer acts only while that episode's re-hold is still current — a
  # superseding probe or re-hold makes this wake a consumed no-op. Readiness is
  # re-read NOW; an equal token is permitted because this is a new hold's one
  # probe, not a replayed ready event. A not-ready adapter probes nothing: the
  # next genuine ready edge (strictly newer — teardown bumps the generation)
  # owns the wake-up. A heal transaction ERROR keeps the wake PENDING with its
  # dueAt pushed one backoff out, and a malformed payload raises (loud, still
  # pending) — only a completed attempt or a legitimate lost race consumes the
  # hold's feeder.
  defp adapter_heal_retry(config, db, wake) do
    coordinator = Map.get(config, :adapter_coordinator, Tightbeam.AdapterCoordinator)

    %{
      "episodeId" => episode_id,
      "sessionKey" => session_key,
      "condition" => condition,
      "cause" => cause,
      "after" => after_wake
    } = JSON.decode!(wake.prompt)

    episode = Adjudication.get(db, session_key, condition)

    # Still-current: same episode incarnation, and no newer probe has replaced
    # the failed one this wake retries (a reopen NULLs recoveryWakeId, which is
    # this same failure re-briefed, not a successor).
    current? =
      is_map(episode) and episode.episode_id == episode_id and
        (is_nil(episode.recovery_wake_id) or episode.recovery_wake_id == after_wake)

    outcomes =
      with true <- current?,
           {:ok, token} <-
             AdapterCoordinator.ready_token(coordinator, parse_adapter_fault_key!(cause)) do
        adapter_healed(config, db, cause, token,
          session_key: session_key,
          condition: condition,
          include_equal: true
        )
      else
        _ -> []
      end

    case Enum.find(outcomes, &match?({_, _, {:error, _}}, &1)) do
      nil ->
        {:ok, _} =
          DB.transaction(db, fn txn ->
            Txn.q(
              txn,
              "UPDATE wakes SET state = 'fired', firedAt = ?2 WHERE wakeId = ?1 AND state = 'pending'",
              [wake.wake_id, System.system_time(:millisecond)]
            )

            :ok
          end)

        :ok

      {_session_key, _condition, {:error, error}} ->
        # release_hold already logged the error loudly; keep the feeder alive.
        {:ok, _} =
          DB.transaction(db, fn txn ->
            Txn.q(
              txn,
              "UPDATE wakes SET dueAt = ?2 WHERE wakeId = ?1 AND state = 'pending'",
              [wake.wake_id, System.system_time(:millisecond) + Adjudication.probe_retry_ms()]
            )

            :ok
          end)

        {:error, error}
    end
  end

  # Inverse of AdapterCoordinator.key_name/1, from the cause encoding: the
  # episode names the adapter it is waiting on, and the retry asks about THAT
  # adapter — not whatever the session points at today. §2.1 pins the canonical
  # key encoding, so a shape this cannot parse is an invariant failure: raise
  # where it is diagnosable rather than consume the hold's only feeder.
  defp parse_adapter_fault_key!("adapter_fault:" <> key_name) do
    [harness, rest] = String.split(key_name, ":", parts: 2)
    [archetype, host] = String.split(rest, "@", parts: 2)
    {Harness.parse!(harness).id(), archetype, host}
  end

  defp arm_hold_in_txn(txn, session_key, wake_id) do
    Txn.q(txn, "UPDATE sessions SET adjudicationHold=?2, updatedAt=?3 WHERE sessionKey=?1", [
      session_key,
      wake_id,
      System.system_time(:millisecond)
    ])
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
        AdapterCoordinator.close_adapter(coordinator, key)
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

  defp harness_for_ref(host, ref) do
    matches =
      Enum.flat_map(Harness.all(), fn module ->
        case ModelCatalog.entry(host, module.wire_name(), ref) do
          {%{} = entry, :fresh} -> [{module, entry}]
          _ -> []
        end
      end)

    case matches do
      [{module, entry}] ->
        {:ok, module.wire_name(), Atom.to_string(entry.provider)}

      [] ->
        {:error,
         %{code: "model_unavailable", message: "model is not in a fresh harness inventory"}}

      _ ->
        {:error,
         %{code: "ambiguous_ref", message: "model appears in multiple harness inventories"}}
    end
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
  defp describe_engine(harness, model), do: "#{harness} (#{model})"

  defp catalog_provider!(host, harness, ref) do
    case ModelCatalog.entry(host, harness, ref) do
      {%{provider: provider}, _health} ->
        Atom.to_string(provider)

      {nil, _health} ->
        raise "catalog entry missing after validation: #{harness}/#{ref} on #{host}"
    end
  end

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

  defp strict_model_adapter(db, session) do
    with %{harness_session_id: sid} <- Org.current_pointer(db, session.session_key),
         coordinator when is_pid(coordinator) <- Process.whereis(Tightbeam.AdapterCoordinator),
         {:ok, adapter, _generation} <-
           AdapterCoordinator.adapter_for(
             coordinator,
             {Harness.parse!(session.harness).id(), "shared", session.host}
           ) do
      {:ok, adapter, sid}
    else
      _ -> {:error, :adapter_unavailable}
    end
  end

  defp push_known_model(_adapter, _sid, model) when not is_binary(model), do: :ok

  defp push_known_model(adapter, sid, model) do
    case Adapter.apply_model(adapter, sid, model) do
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
    append_marker(
      db,
      session.session_key,
      "[context reset]\n\n" <>
        "The agent's working memory was reset while handling the message above. " <>
        "Earlier messages stay visible here, but the agent no longer remembers them."
    )
  end

  # A failed turn with no marker is a prompt that silently vanishes: the
  # echo shows, the indicator clears, and no reply ever comes. The WHY
  # belongs in the chat where the reply would have been.
  defp append_turn_failed_marker(db, session_key, reason) do
    append_marker(
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

  # MARKER MESSAGES (the normative convention lives in Payloads — the seam
  # clients render from): an ordinary appended message so it rides replay
  # and live push with no new frame type. sender "process:tightbeam" is the
  # anti-forgery — real model output always commits with sender
  # "tightbeam", so no session can emit a marker by typing one.
  defp append_marker(db, session_key, content) do
    case Projection.append(db, %{
           session_key: session_key,
           role: "assistant",
           content: content,
           sender: "process:tightbeam"
         }) do
      {:appended, marker} -> publish_message(db, session_key, marker)
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
          # filter them against its watermark (see Wire.Socket moduledoc).
          fn pid, payload -> send(pid, {:push_message, session_key, seq, payload}) end
        )
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
