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
    Producers,
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
          critical_lease_hard_cap_ms: pos_integer()
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
          RailRemedy,
          Producers,
          Supervision,
          WorkState
        ] do
      :ok = module.ensure_schema(db)
    end

    :ok = Adjudication.reconcile(db)

    :ok =
      Adjudication.escalate_due(
        db,
        Map.get(config, :adjudication_response_window_ms, 86_400_000)
      )

    migrate_handle_roles(db)

    # Sessions created before real-hostname registration stored the retired
    # "local" indexical; rewrite once so rows speak the org's vocabulary.
    {:ok, _} =
      DB.query(db, "UPDATE sessions SET host = ?1 WHERE host = 'local'", [
        Placement.local_host_name()
      ])

    {:ok, rows} =
      DB.query(db, "SELECT sessionKey FROM sessions WHERE state = 'active' AND cliToken IS NULL")

    Enum.each(rows, fn [session_key] ->
      token = "tbs_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      {:ok, _} =
        DB.query(db, "UPDATE sessions SET cliToken = ?2 WHERE sessionKey = ?1", [
          session_key,
          token
        ])
    end)

    warn_cli_target_mismatches(db, config.base_dir)

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
    cli_bin = install_cli_bin(config.base_dir)
    defaults = defaults(config, db)
    on_terminal = fn session_key, seq -> Supervision.notify_terminal(session_key, seq) end
    producer_config = Producers.load!(config.base_dir)
    producer_runner = Map.get(config, :producer_runner, Tightbeam.ProducerRunner)

    on_retired = fn session_key ->
      Supervision.notify_retired(session_key)
      Producers.cancel_for_holder(db, session_key, runner: producer_runner)
    end

    handler_table =
      config
      |> Map.put(:db, db)
      |> Map.put(:on_retired, on_retired)
      |> Map.put(:producer_config, producer_config)
      |> Map.put(:producer_runner, producer_runner)
      |> handlers()

    Rules.load!(config.base_dir, Map.keys(handler_table), producer_config)
    runner = turn_runner(Map.put(config, :db, db))

    # Identity is loaded at composition time; a malformed manifest fails the
    # boot (bad law stops the boot). Placement owns every host mechanic.
    Archetypes.load!(config.base_dir)
    Rails.load!(config.base_dir)
    Enum.each(Harness.all(), &Homes.sweep_auth(config.base_dir, &1.id()))

    adapter_config = config |> Map.put(:cli_bin, cli_bin) |> Map.put(:db, db)
    adapter_opts = fn key -> Placement.adapter_opts(adapter_config, key) end

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

    deliver = fn wake ->
      case wake.target_role do
        role when is_binary(role) ->
          case Roles.resolve(db, role) do
            {:ok, session_key, fallback} ->
              deliver_prompt(session_key, wake.origin, wake.prompt,
                db: db,
                wake_id: wake.wake_id,
                sender: wake.origin,
                role_ref: role,
                role_fallback: fallback
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
          deliver_prompt(wake.session_key, wake.origin, wake.prompt,
            db: db,
            wake_id: wake.wake_id,
            sender: wake.origin,
            target_gate: wake,
            fire_wake_in_txn: wake.origin == "process:tightbeam"
          )
      end
    end

    credential_children(config, db) ++
      [
        {ModelCatalog, base_dir: config.base_dir},
        {Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry},
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
         db: db, handlers: handler_table, prod_limit: prod_limit, name: Tightbeam.Supervision},
        {DynamicSupervisor, strategy: :one_for_one, name: Tightbeam.AdapterSupervisor},
        %{
          id: Tightbeam.ProducerSupervisor,
          start:
            {DynamicSupervisor, :start_link,
             [[strategy: :one_for_one, name: Tightbeam.ProducerSupervisor]]}
        },
        {Tightbeam.ProducerRunner,
         db: db, config: config, supervisor: Tightbeam.ProducerSupervisor, name: producer_runner},
        {Tightbeam.AdapterCoordinator,
         adapter_sup: Tightbeam.AdapterSupervisor,
         adapter_opts: adapter_opts,
         db: db,
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
    assert_harness_binary_ready!(config, Path.join(config.base_dir, "bin"))
    Identity.init!(config.base_dir)
    :ok
  end

  defp credential_children(config, db) do
    Enum.map(Placement.hosts(config.base_dir), fn {machine, host} ->
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
        park: fn provider -> stop_provider_runtime(provider, machine) end,
        start: fn provider -> start_provider_runtime(provider, machine) end,
        resume: fn _provider -> :ok end,
        capture_sessions: fn provider ->
          capture_credential_sessions(db, provider, machine)
        end,
        publish_sessions: fn captured, transition ->
          publish_credential_sessions(db, captured, transition)
        end
      ]
      |> maybe_put_credential_runner(config)

    %{
      id: {Tightbeam.Credentials, machine},
      start: {Tightbeam.Credentials, :start_link, [opts]}
    }
  end

  defp start_credential_child(config, db, machine, host) do
    supervisor = Map.get(config, :credential_supervisor, Tightbeam.Supervisor)

    case Supervisor.start_child(supervisor, credential_child(config, db, machine, host)) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> :ok
    end
  end

  defp maybe_put_credential_runner(opts, %{sh: sh}), do: Keyword.put(opts, :sh, sh)
  defp maybe_put_credential_runner(opts, _config), do: opts

  defp assert_harness_binary_ready!(config, cli_bin) do
    probe = Map.get(config, :harness_binary_probe, &Placement.harness_binary_probe/2)

    results =
      Enum.map(Harness.all(), fn module ->
        {module.id(), probe.(module.id(), cli_bin)}
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
              owner_user_id: caller && caller.owner_user_id
            )
        }
      end,
      "decision-request" => fn call ->
        caller = resolve_caller(db, call.origin)
        id = call.params[:request_id] || call.params[:request]

        case Escalation.get(db, call, id, owner_user_id: caller && caller.owner_user_id) do
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
          {:ok, entry} =
            Placement.register_host(config.base_dir, p.name, %{
              ssh: p[:ssh] || p.name,
              base_dir: Map.fetch!(p, :base_dir),
              cli_bin: p[:cli_bin],
              adapter_bin_dir: p[:adapter_bin_dir]
            })

          :ok = start_credential_child(config, db, p.name, entry)
          %{host: p.name, config: entry}
        end),
      "identity-edit" =>
        admin_call_handler(db, fn call -> identity_edit_result(config, call) end),
      "identity-status" =>
        admin_call_handler(db, fn call -> identity_status_result(config, db, call) end),
      "identity-relearn" =>
        admin_call_handler(db, fn call -> identity_relearn_result(config, call) end),
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
          Map.put(call, :on_assignment_change, assignment_change)
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
      "run-tests" => fn call ->
        Producers.__handle__(db, "run-tests", call,
          config: Map.get(config, :producer_config, Producers.config()),
          runner: Map.get(config, :producer_runner)
        )
      end,
      "run-smoke" => fn call ->
        Producers.__handle__(db, "run-smoke", call,
          config: Map.get(config, :producer_config, Producers.config()),
          runner: Map.get(config, :producer_runner)
        )
      end,
      "cancel-producer-job" => fn call ->
        Producers.__handle__(db, "cancel-producer-job", call,
          runner: Map.get(config, :producer_runner)
        )
      end,
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

  @doc "Attach the post-commit owner delivery used by `Escalation.escalate/4`."
  @spec escalation_context(config(), DB.server(), map()) :: map()
  def escalation_context(config, db, ctx) do
    Map.put(ctx, :deliver_owner, fn owner_user_id, request ->
      options = if request.options, do: "\nOptions: #{JSON.encode!(request.options)}", else: ""

      prompt =
        "Decision #{request.id} pending on #{request.statute_name}.\n" <>
          request.question <>
          options <>
          "\nContext: #{JSON.encode!(request.context)}"

      notify_session(config, db, Org.personal_session_key(owner_user_id), prompt)
    end)
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
          wake_id when is_binary(wake_id) ->
            case DB.Txn.q(
                   txn,
                   "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'work_items'",
                   []
                 ) do
              [[1]] ->
                case DB.Txn.q(
                       txn,
                       "SELECT id FROM work_items WHERE routingWakeId = ?1",
                       [wake_id]
                     ) do
                  [[job_ref]] -> {nil, job_ref}
                  [] -> {nil, nil}
                end

              [] ->
                {nil, nil}
            end

          nil ->
            {nil, nil}
        end

      attribution ->
        attribution
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
  GET /api/org-options): harnesses, per-harness model catalog, assimilated
  hosts, archetypes with their WHERE. Same data inspect gives agents —
  discovery beats documentation, for humans too.
  """
  @spec org_options() :: map()
  def org_options do
    base_dir =
      Application.get_env(:tightbeam, :base_dir, Path.join(System.user_home!(), ".tightbeam"))

    %{
      harnesses: Enum.map(Harness.all(), & &1.wire_name()),
      models:
        Map.new(ModelCatalog.get(), fn {harness, models} ->
          {harness,
           Enum.map(models, fn model ->
             model
             |> Map.put(:id, model.ref)
             |> Map.put(:name, model.display_name)
             |> Map.put(:provider, model.provider)
           end)}
        end),
      hosts: base_dir |> Placement.hosts() |> Map.keys() |> Enum.sort(),
      archetypes:
        Enum.map(Archetypes.names(), fn name ->
          a = Archetypes.get(name)
          %{name: a.name, where: a.where, defaults: a.defaults}
        end)
    }
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

        {base_model, effort} = Adapter.parse_model_ref(session.model)
        {catalog, _health} = ModelCatalog.get(session.harness, ModelCatalog)
        unsupported = fn reason -> %{supported: false, reason: reason} end

        models_once = Enum.uniq_by(catalog, &base_ref(&1.ref))

        current_efforts =
          case Enum.find(catalog, &(base_ref(&1.ref) == base_model)) do
            nil -> []
            entry -> entry.efforts
          end

        reasoning_capability =
          case current_efforts do
            [] ->
              unsupported.("current model has no effort tiers")

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
            model: base_model,
            modelPreferences: model_preferences,
            provider: session.provider,
            harness: session.harness,
            host: session.host,
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

  defp base_ref(ref), do: elem(Adapter.parse_model_ref(ref), 0)

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
      entry = Path.expand("../tightbeam/dist/cli/main.js", File.cwd!())
      File.write!(wrapper, "#!/bin/sh\nexec node \"#{entry}\" \"$@\"\n")
    end

    File.chmod!(wrapper, 0o755)

    bin_dir
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

      outcome =
        with {:ok, adapter, generation} <-
               checkout_adapter(session),
             {:ok, harness_session_id} <-
               harness_session(config, db, adapter, generation, session, turn.seq),
             {:ok, result} <-
               Adapter.prompt(
                 adapter,
                 harness_session_id,
                 turn.prompt,
                 600_000,
                 progress: progress_fun(db, turn.session_key, session.owner_user_id, correlation)
               ) do
          case Projection.append(db, %{
                 session_key: turn.session_key,
                 role: "assistant",
                 content: result.text,
                 sender: "tightbeam",
                 reply_to_message_id: echo && echo.id,
                 reply_to_client_message_id: echo && echo.client_message_id
               }) do
            {:appended, reply} -> publish_message(db, turn.session_key, reply)
            _ -> :ok
          end

          {:ok, %{terminal_publish: terminal_publish}}
        else
          {:error, reason} ->
            condition = Adjudication.classify(reason)
            adjudication_prompt = adjudication_brief(session, condition)

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
                reresolve_rung: 1
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
                 Wakes.fire_due(config[:wake_scheduler] || Tightbeam.WakeScheduler)
               end
             }}
        end

      outcome
    end
  end

  defp adjudication_brief(session, condition) do
    archetype = Archetypes.get(session.archetype) || Archetypes.builtin_default()

    inventories =
      Map.new(Harness.all(), fn module ->
        {models, health} = ModelCatalog.get(module.wire_name(), ModelCatalog)
        {module.wire_name(), %{health: inspect(health), models: Enum.map(models, & &1.ref)}}
      end)

    """
    Model adjudication required.
    affected_session=#{session.session_key}
    condition=#{condition}
    current_model=#{session.model}
    current_harness=#{session.harness}
    model_preferences=#{JSON.encode!(archetype.model_preferences)}
    live_catalog=#{JSON.encode!(inventories)}

    Reply with: tightbeam adjudicate --episode <correlationKey> --action park|swap|respawn|stop [--model <ref>] [--reason <text>]
    """
  end

  # Wire publication for terminals that lost their runner closure: turns
  # recovered at boot (failed_unknown), task crashes, republished rows. The
  # client learns the truth it was owed — terminal turn-state with the
  # reason, typing/activity cleared, progress label cleared.
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

  defp warn_cli_target_mismatches(db, base_dir) do
    warn_cli_target_mismatches(db, base_dir, local_target_triple())
  end

  @doc false
  def warn_cli_target_mismatches(db, _base_dir, nil) do
    EventLog.lifecycle(
      db,
      "cli_target_mismatch",
      Placement.local_host_name(),
      "gateway target unknown; remote CLI compatibility not checked"
    )

    :ok
  end

  def warn_cli_target_mismatches(db, base_dir, local) do
    base_dir
    |> Placement.hosts()
    |> Enum.each(fn
      {_name, %{ssh: nil}} ->
        :ok

      {name, %{ssh: dest}} ->
        case System.cmd(
               "ssh",
               ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", dest, "uname", "-sm"],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            case target_from_probe(output) do
              target when is_binary(target) and target != local ->
                EventLog.lifecycle(
                  db,
                  "cli_target_mismatch",
                  name,
                  "gateway #{local}; host #{target}"
                )

              _ ->
                :ok
            end

          _ ->
            :ok
        end
    end)
  end

  defp local_target_triple do
    local_target_triple(:os.type(), :erlang.system_info(:system_architecture) |> to_string())
  end

  @doc false
  def local_target_triple(os_type, architecture) do
    case {os_type, architecture} do
      {{:unix, :darwin}, "aarch64" <> _} -> "aarch64-apple-darwin"
      {{:unix, :darwin}, "x86_64" <> _} -> "x86_64-apple-darwin"
      {{:unix, :linux}, "aarch64" <> _} -> "aarch64-unknown-linux-gnu"
      {{:unix, :linux}, "x86_64" <> _} -> "x86_64-unknown-linux-gnu"
      _ -> nil
    end
  end

  defp target_from_probe(output) do
    case String.split(String.trim(output)) do
      ["Darwin", arch] when arch in ["arm64", "aarch64"] -> "aarch64-apple-darwin"
      ["Darwin", "x86_64"] -> "x86_64-apple-darwin"
      ["Linux", arch] when arch in ["arm64", "aarch64"] -> "aarch64-unknown-linux-gnu"
      ["Linux", arch] when arch in ["x86_64", "amd64"] -> "x86_64-unknown-linux-gnu"
      _ -> nil
    end
  end

  defp harness_session(config, db, adapter, generation, session, turn_seq) do
    cwd = Placement.holder_workdir(config, session)
    mcp_servers = session.archetype |> Archetypes.get() |> Archetypes.acp_mcp_servers()
    harness = Harness.parse!(session.harness).id()

    result =
      case Org.current_pointer(db, session.session_key) do
        nil ->
          revision = Identity.live_revision!(config.base_dir)
          snapshot = served_snapshot(config, session, harness, revision)

          with {:ok, sid} <-
                 Adapter.new_session(
                   adapter,
                   session.model,
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
          if Adapter.knows_session?(adapter, pointer.harness_session_id) do
            {:ok, pointer.harness_session_id}
          else
            revision = session.identity_revision || Identity.live_revision!(config.base_dir)

            snapshot = served_snapshot(config, session, harness, revision)

            AdapterCoordinator.with_load_slot(Tightbeam.AdapterCoordinator, fn ->
              case Adapter.load_session(
                     adapter,
                     pointer.harness_session_id,
                     session.model,
                     cwd,
                     mcp_servers,
                     snapshot.guidance
                   ) do
                :ok ->
                  Org.append_pointer(
                    db,
                    session.session_key,
                    pointer.harness_session_id,
                    "loaded"
                  )

                  Org.set_identity_revision(db, session.session_key, snapshot.revision)
                  {:ok, pointer.harness_session_id}

                {:error, :contained_sandbox_disable_failed} = error ->
                  error

                {:error, {:model_apply_failed, _reason}} = error ->
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
                         Adapter.new_session(
                           adapter,
                           session.model,
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
          end
      end

    with {:ok, sid} <- result do
      :ok = Ledger.stamp_adapter(db, turn_seq, generation)
      {:ok, sid}
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
    Archetypes.load!(config.base_dir)
    %{state: "published", live_revision: revision}
  end

  defp identity_relearn_result(config, _call) do
    case Identity.relearn!(config.base_dir) do
      {:ok, revision} ->
        Archetypes.load!(config.base_dir)
        %{state: "published", live_revision: revision}

      {:conflict, paths} ->
        %{
          state: "relearn-conflicted",
          conflicting_paths: paths,
          live_revision: Identity.live_revision!(config.base_dir)
        }
    end
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
    busy =
      sessions
      |> Enum.filter(&(Ledger.pending_count(db, &1.session_key) > 0))
      |> Enum.map(& &1.session_key)

    identity_apply_at_boundary(config, db, sessions, busy)
  end

  defp identity_apply_at_boundary(_config, _db, _sessions, [_ | _] = busy) do
    %{
      code: "turn_in_progress",
      message: "identity apply requires a turn boundary",
      sessions: busy
    }
  end

  defp identity_apply_at_boundary(config, db, sessions, []) do
    live = Identity.live_revision!(config.base_dir)

    applied =
      Enum.map(sessions, fn session ->
        case identity_apply_session(config, db, session, live) do
          :applied ->
            best_effort(fn ->
              stream = db |> Org.get(session.session_key) |> Payloads.stream_session()
              broadcast(db, session.owner_user_id, Payloads.stream_updated(stream))
            end)

          :noop ->
            :ok
        end

        session.session_key
      end)

    %{applied: applied, identity_revision: live}
  end

  defp identity_apply_session(config, db, session, revision) do
    case Org.current_pointer(db, session.session_key) do
      nil -> :noop
      pointer -> identity_apply_started_session(config, db, session, revision, pointer)
    end
  end

  # A session that has never started has no harness session to bounce. It materializes
  # from `tightbeam/live` at its first start (§Sessions stamp the revision they
  # materialized from), so it is already on the applied revision by construction.
  defp identity_apply_started_session(config, db, session, revision, pointer) do
    harness = Harness.parse!(session.harness).id()
    key = {harness, "shared", session.host}
    cwd = Placement.holder_workdir(config, session)
    snapshot = served_snapshot(config, session, harness, revision)
    mcp_servers = session.archetype |> Archetypes.get() |> Archetypes.acp_mcp_servers()

    with {:ok, adapter, _generation} <-
           AdapterCoordinator.adapter_for(Tightbeam.AdapterCoordinator, key),
         :ok <- Adapter.close_session(adapter, pointer.harness_session_id),
         :ok <-
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
      {:error, reason} ->
        raise "identity apply failed for #{session.session_key}: #{inspect(reason)}"
    end
  end

  @onboarding_providers ["openai", "anthropic"] ++
                          if(Application.compile_env(:tightbeam, :fixture_harness, false),
                            do: ["fixture-provider"],
                            else: []
                          )

  defp onboard_result(config, %{params: %{provider: provider, phase: phase} = params})
       when provider in @onboarding_providers and phase in ["begin", "finish", "cancel"] do
    machine = params[:machine] || Placement.local_host_name()

    case Map.has_key?(Placement.hosts(config.base_dir), machine) do
      true -> onboard_phase(provider_atom(provider), phase, machine, params[:reason])
      false -> %{code: "unknown_host", message: "unknown onboarding machine #{machine}"}
    end
  end

  defp onboard_result(_config, %{params: %{provider: provider}}) do
    %{
      code: "interactive_required",
      message: "run tightbeam onboard #{provider} from a terminal on this machine"
    }
  end

  defp onboard_phase(provider, "begin", machine, _reason) do
    case Tightbeam.Credentials.begin_onboard(provider, Tightbeam.Credentials.server(machine)) do
      {:ok, path} -> %{provider: provider, status: "ready", staging_path: path}
      {:error, reason} -> %{code: "needs_onboarding", message: inspect(reason)}
    end
  end

  defp onboard_phase(provider, "finish", machine, _reason) do
    case Tightbeam.Credentials.finish_onboard(provider, Tightbeam.Credentials.server(machine)) do
      :ok -> %{provider: provider, status: "onboarded"}
      {:error, reason} -> %{code: "needs_onboarding", message: inspect(reason)}
    end
  end

  defp onboard_phase(provider, "cancel", machine, reason) do
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

  defp migrate_handle_roles(db) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT handle, sessionKey, ownerUserId
        FROM sessions WHERE handle IS NOT NULL ORDER BY createdAt, sessionKey
        """
      )

    Enum.each(rows, fn [handle, session_key, owner_user_id] ->
      if is_nil(Roles.get(db, handle)) do
        case Roles.migrate_handle(db, handle, owner_user_id, session_key) do
          {:error, error} -> raise error.message
          _role -> :ok
        end
      end
    end)
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
    case Archetypes.get(archetype_name) do
      nil ->
        %{code: "unknown_archetype", message: "no such archetype: #{archetype_name}"}

      _archetype ->
        :ok = Org.put_setting(db, "default-archetype", archetype_name)
        %{setting: "default-archetype", value: archetype_name}
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
          hosts: config.base_dir |> Placement.hosts() |> Map.keys() |> Enum.sort(),
          models: ModelCatalog.get()
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
      reresolve_rung: p[:reresolve_rung]
    })
  end

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
               Placement.resolve(archetype, p[:host], Placement.hosts(config.base_dir)) do
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

    with :ok <- validate_credential(config, harness_string, host),
         :ok <- validate_catalog_model(harness_string, model, is_nil(p[:model])),
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
        provider: catalog_provider!(harness_string, model),
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

            prior ->
              {:replayed, prior.session_key}
          end
        end)

      case session_result do
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

      p[:setting] == "set_harness" and is_binary(p[:harness]) ->
        case Org.get(db, call.session_key) do
          nil ->
            %{ok: false, code: "not_found"}

          session ->
            harness = p.harness
            module = Harness.parse!(harness)
            harness_atom = module.id()

            model = p[:model] || config.default_model

            with :ok <- validate_credential(config, harness, session.host),
                 :ok <- validate_catalog_model(harness, model, is_nil(p[:model])),
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
                catalog_provider!(harness, model),
                model
              )

              # History barrier (product ruling): a new engine gets a fresh
              # visible slate. Rows are RETAINED (never deleted) but replay
              # stops at the barrier, and live clients are told to drop their
              # local view. No pointer surgery: the old harness session can't
              # load on the new engine → fallback pointer, fresh context.
              {:ok, [[max_seq]]} =
                DB.query(
                  db,
                  "SELECT COALESCE(MAX(seq), 0) FROM messages WHERE sessionKey = ?1",
                  [call.session_key]
                )

              Org.set_cleared_through(db, call.session_key, max_seq)

              broadcast(
                db,
                session.owner_user_id,
                Payloads.stream_history_cleared(call.session_key)
              )

              %{
                ok: true,
                harness: harness,
                model: model,
                note: "engine swapped; chat cleared (rows retained); model context starts fresh"
              }
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

            case Placement.resolve(archetype, p.host, Placement.hosts(config.base_dir)) do
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
            new_ref = compose_model_selection(session.harness, session.model, p.model)
            apply_model_change(config, db, call, session, new_ref)
        end

      p[:setting] == "set_reasoning" and is_binary(p[:reasoningLevel]) ->
        case Org.get(db, call.session_key) do
          nil ->
            %{ok: false, code: "not_found"}

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
  defp compose_model_selection(harness, current_ref, selected) do
    if String.contains?(selected, "[") do
      selected
    else
      {_current_base, current_effort} = Adapter.parse_model_ref(current_ref)

      case efforts_for(harness, selected) do
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

  defp efforts_for(harness, base_model) do
    {catalog, _health} = ModelCatalog.get(harness, ModelCatalog)

    case Enum.find(catalog, &(base_ref(&1.ref) == base_model)) do
      nil -> []
      entry -> entry.efforts
    end
  end

  defp apply_model_change(config, db, call, session, new_ref) do
    with :ok <- validate_catalog_model(session.harness, new_ref, false),
         {%{provider: provider}, _health} <-
           ModelCatalog.entry(session.harness, new_ref, ModelCatalog) do
      case apply_tuned_model(config, db, session, new_ref) do
        :ok ->
          Org.set_model(db, call.session_key, new_ref, Atom.to_string(provider))
          %{ok: true}

        {:error, reason} ->
          %{ok: false, reason: reason}
      end
    else
      {:error, denial} -> denial
    end
  end

  defp apply_tuned_model(config, db, session, new_ref) do
    case Org.current_pointer(db, session.session_key) do
      nil ->
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
          if Adapter.knows_session?(adapter, pointer.harness_session_id) do
            Adapter.apply_model(adapter, pointer.harness_session_id, new_ref)
          else
            cwd = Placement.holder_workdir(config, session)
            revision = session.identity_revision || Identity.live_revision!(config.base_dir)
            snapshot = served_snapshot(config, session, harness, revision)

            AdapterCoordinator.with_load_slot(coordinator, fn ->
              Adapter.load_session(
                adapter,
                pointer.harness_session_id,
                new_ref,
                cwd,
                session.archetype |> Archetypes.get() |> Archetypes.acp_mcp_servers(),
                snapshot.guidance
              )
            end)
          end
        else
          false -> {:error, :adapter_unavailable}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp validate_catalog_model(harness, model, configured_default?) do
    case is_binary(model) && ModelCatalog.member?(harness, model) do
      %{present?: true, health: :fresh} ->
        :ok

      %{health: :fresh} ->
        warn_dead_default(harness, model, configured_default?)

        {:error,
         %{
           code: "model_unavailable",
           message: "model #{inspect(model)} is not offered by #{harness}"
         }}

      %{health: health} ->
        warn_dead_default(harness, model, configured_default?)

        {:error,
         %{
           code: "catalog_unavailable",
           message: "cannot validate model #{inspect(model)} for #{harness}: #{inspect(health)}"
         }}

      false ->
        warn_dead_default(harness, model, configured_default?)
        {:error, %{code: "model_unavailable", message: "model must be specified"}}
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

  defp start_provider_runtime(provider, machine) do
    {started, failed} =
      Enum.reduce(harnesses_for_provider(provider), {[], []}, fn module, {started, failed} ->
        key = {module.id(), "shared", machine}

        case AdapterCoordinator.adapter_for(Tightbeam.AdapterCoordinator, key) do
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

  defp warn_dead_default(_harness, _model, false), do: :ok

  defp warn_dead_default(harness, model, true) do
    Logger.warning(
      "configured default model #{inspect(model)} is not currently offered by #{harness}"
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

  defp retire_result(config, db, call) do
    p = call.params
    owner = String.replace_prefix(call.origin, "user:", "")
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
    case call.params.action do
      "park" -> adjudicate_park(config, db, call, episode)
      "swap" -> adjudicate_swap(config, db, call, episode)
      "respawn" -> adjudicate_respawn(config, db, call, episode)
      "stop" -> adjudicate_stop(config, db, call, episode)
    end
  end

  defp adjudicate_stop(config, db, call, episode) do
    session = Org.get(db, episode.session_key)

    {:ok, result} =
      DB.transaction(db, fn txn ->
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
          raise "stale adjudication episode"
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
      DB.transaction(db, fn txn ->
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
              Txn.q(
                txn,
                "UPDATE wakes SET state='canceled' WHERE wakeId=?1 AND state='pending'",
                [wake.wake_id]
              )

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
          raise "stale adjudication episode"
        end
      end)

    if delivery, do: complete_delivery(db, delivery)
    %{ok: true, action: "park", recovery_wake_id: wake_id}
  end

  defp adjudicate_swap(_config, db, call, episode) do
    with {:ok, harness, provider} <- harness_for_ref(call.params.model) do
      session = Org.get(db, episode.session_key)

      if harness != session.harness do
        %{
          code: "cross_harness_requires_respawn",
          message: "use --action respawn for a cross-harness model"
        }
      else
        case strict_apply_current_model(db, session, call.params.model) do
          :ok ->
            {:ok, {delivery, wake_id}} =
              DB.transaction(db, fn txn ->
                current = Adjudication.get_by_correlation_in_txn(txn, episode.correlation_key)

                recovery_prompt =
                  "Your previous turn failed: #{current.condition}. You now run on #{call.params.model}. Re-derive state from the facts and continue."

                wake_id =
                  Adjudication.deterministic_wake_in_txn(
                    txn,
                    current,
                    "recovery",
                    current.session_key,
                    recovery_prompt
                  )

                case Org.swap_model_in_txn(
                       txn,
                       current.session_key,
                       {session.model, session.harness},
                       {call.params.model, harness, provider}
                     ) do
                  {:ok, _} -> :ok
                  {:duplicate, _} -> :ok
                  :stale -> raise("model mutation race")
                end

                unless Adjudication.resolve_in_txn(txn, current, wake_id),
                  do: raise("stale adjudication episode")

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
                    from_model: session.model,
                    to_model: call.params.model,
                    from_harness: session.harness,
                    to_harness: harness,
                    trigger: current.condition,
                    adjudicated_by: current.owner_target,
                    correlationKey: current.correlation_key,
                    harness_crossed: false,
                    context_discarded: false
                  })
                )

                {delivery, wake_id}
              end)

            complete_delivery(db, delivery)
            %{ok: true, action: "swap", model: call.params.model, recovery_wake_id: wake_id}

          {:error, reason} ->
            %{code: to_string(reason), message: "strict model apply failed: #{reason}"}
        end
      end
    else
      {:error, error} -> error
    end
  end

  defp adjudicate_respawn(config, db, call, episode),
    do: adjudicate_respawn(config, db, call, episode, 8)

  defp adjudicate_respawn(_config, _db, _call, _episode, 0),
    do: %{code: "workspace_move_race", message: "assignments kept changing during respawn"}

  defp adjudicate_respawn(config, db, call, episode, attempts) do
    with {:ok, harness, provider} <- harness_for_ref(call.params.model) do
      old = Org.get(db, episode.session_key)
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

          new_session =
            Org.create_in_txn(txn, %{
              session_key: new_session_key,
              display_name: old.display_name,
              kind: old.kind,
              owner_user_id: old.owner_user_id,
              origin: old.origin,
              spawned_by: old.spawned_by,
              archetype: old.archetype,
              overrides: old.overrides,
              identity_name: old.identity_name,
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
            do: raise("stale adjudication episode")

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
      host = Placement.hosts(config.base_dir)[session.host]

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

  defp harness_for_ref(ref) do
    matches =
      Enum.flat_map(Harness.all(), fn module ->
        case ModelCatalog.entry(module.wire_name(), ref) do
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

  defp catalog_provider!(harness, ref) do
    case ModelCatalog.entry(harness, ref) do
      {%{provider: provider}, _health} -> Atom.to_string(provider)
      {nil, _health} -> raise "catalog entry missing after validation: #{harness}/#{ref}"
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

  defp default_seed_provider(module, ref) do
    case ModelCatalog.entry(module.wire_name(), ref) do
      {%{provider: provider}, _health} -> Atom.to_string(provider)
      {nil, _health} -> Atom.to_string(module.credential_provider())
    end
  end

  defp strict_apply_current_model(db, session, model) do
    with %{harness_session_id: sid} <- Org.current_pointer(db, session.session_key),
         coordinator when is_pid(coordinator) <- Process.whereis(Tightbeam.AdapterCoordinator),
         {:ok, adapter, _generation} <-
           AdapterCoordinator.adapter_for(
             coordinator,
             {Harness.parse!(session.harness).id(), "shared", session.host}
           ) do
      Adapter.apply_model_strict(adapter, sid, model, session.model)
    else
      _ -> :ok
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
      "[turn failed]\n\nThe agent could not answer the message above: #{reason}"
    )
  end

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
