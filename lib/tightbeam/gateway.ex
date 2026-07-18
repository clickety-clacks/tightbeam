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
    fire; a wake MUST carry a prompt), spawn (idempotency, headcount cap,
    handle uniqueness, owner inherited from spawn tree), retire (idempotent,
    owner-only), tune (rename | set_model; live-session apply), cancel,
    inspect (owned sessions + owned pending wakes + admin: pending devices),
    approve-device/deny-device/revoke-device/promote-user (admin-gated via
    the origin's owning USER — user-scoped admin).
  - Caller resolution (gateway.ts `resolveCaller`): "user:x" → x;
    "agent:handle" → active session's owner; anything else → unknown_caller.
  """

  alias Tightbeam.{
    AdapterCoordinator,
    Archetypes,
    Placement,
    DB,
    Devices,
    Idempotency,
    LaneManager,
    Ledger,
    Org,
    Projection,
    Wakes
  }

  alias Tightbeam.Acp.Adapter
  alias Tightbeam.Wire.Payloads

  @model_catalog %{
    "claude" => [
      %{ref: "fable", name: "Fable 5"},
      %{ref: "opus[1m]", name: "Opus 4.8 (1M)"},
      %{ref: "sonnet", name: "Sonnet"},
      %{ref: "haiku", name: "Haiku"}
    ],
    "codex" => [
      %{ref: "gpt-5.6-sol[low]", name: "Sol (low)"},
      %{ref: "gpt-5.6-sol[medium]", name: "Sol (medium)"},
      %{ref: "gpt-5.6-sol[high]", name: "Sol (high)"},
      %{ref: "gpt-5.6-sol[xhigh]", name: "Sol (xhigh)"},
      %{ref: "gpt-5.6-luna[medium]", name: "Luna (medium)"}
    ]
  }

  @typedoc "Gateway config (gateway.ts GatewayConfig)."
  @type config :: %{
          base_dir: String.t(),
          cwd: String.t(),
          port: non_neg_integer(),
          default_harness: atom(),
          default_model: String.t(),
          max_live_sessions_per_user: pos_integer(),
          wake_tick_ms: pos_integer()
        }

  @doc """
  The wire/adapter children to append after Tightbeam.Application's base
  children (see moduledoc order). Also: ensure schemas for Devices/
  Idempotency/Wakes/Projection/Org, mint + persist the cliToken and
  gateway.json (mode 0600) in base_dir, install the CLI bin.
  """
  @spec children(config()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(config) do
    db = Map.get(config, :db, Tightbeam.DB)
    File.mkdir_p!(config.base_dir)

    for module <- [Tightbeam.Assets, Devices, Idempotency, Wakes, Projection, Org] do
      :ok = module.ensure_schema(db)
    end

    cli_token = "tbc_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
    gateway_path = Path.join(config.base_dir, "gateway.json")
    File.write!(gateway_path, JSON.encode!(%{port: config.port, cliToken: cli_token}))
    File.chmod!(gateway_path, 0o600)
    cli_bin = install_cli_bin(config.base_dir)
    defaults = defaults(config)
    handler_table = handlers(Map.put(config, :db, db))
    runner = turn_runner(Map.put(config, :db, db))

    # Identity is loaded at composition time; a malformed manifest fails the
    # boot (bad law stops the boot). Placement owns every host mechanic.
    Archetypes.load!(config.base_dir)

    adapter_opts = fn key -> Placement.adapter_opts(Map.put(config, :cli_bin, cli_bin), key) end

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
      case Org.get(db, wake.session_key) do
        %{state: "active"} ->
          deliver_prompt(wake.session_key, wake.origin, wake.prompt,
            db: db,
            wake_id: wake.wake_id,
            sender: wake.origin
          )

        _ ->
          :ok
      end
    end

    [
      {Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry},
      {Tightbeam.Wakes,
       db: db, deliver: deliver, tick_ms: config.wake_tick_ms, name: Tightbeam.WakeScheduler},
      {DynamicSupervisor, strategy: :one_for_one, name: Tightbeam.AdapterSupervisor},
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
       name: Tightbeam.LaneManager},
      {Bandit, plug: {Tightbeam.Wire.Router, router_deps}, port: config.port}
    ]
  end

  @doc "The immutable verb-handler table (see moduledoc list) — built once, passed to Dispatch."
  @spec handlers(config()) :: Tightbeam.Dispatch.handlers()
  def handlers(config) do
    db = Map.get(config, :db, Tightbeam.DB)

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

          is_nil(resolve_caller(db, call.origin)) ->
            %{code: "unknown_caller"}

          true ->
            case Org.get(db, call.session_key) do
              %{state: "active"} = target ->
                due_at = p[:at] || System.system_time(:millisecond) + (p[:after_ms] || 0)

                wake =
                  Wakes.schedule(db, %{
                    session_key: target.session_key,
                    origin: call.origin,
                    prompt: p.prompt,
                    due_at: due_at
                  })

                if due_at <= System.system_time(:millisecond),
                  do: Wakes.fire_due(Map.get(config, :wake_scheduler, Tightbeam.WakeScheduler))

                %{
                  wake_id: wake.wake_id,
                  due_at: due_at,
                  state: (Wakes.get(db, wake.wake_id) || wake).state
                }

              _ ->
                %{code: "not_found"}
            end
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
          # prepared the machine; this records the fact. Placement refuses
          # "local"; everything else is the operator's topology to declare.
          case Placement.register_host(config.base_dir, p.name, %{
                 ssh: p[:ssh] || p.name,
                 base_dir: Map.fetch!(p, :base_dir),
                 cli_bin: p[:cli_bin],
                 adapter_bin_dir: p[:adapter_bin_dir]
               }) do
            {:ok, entry} -> %{host: p.name, config: entry}
            {:error, denial} -> denial
          end
        end),
      "promote-user" =>
        admin_handler(db, fn p ->
          %{user: Devices.set_user_admin(db, p.user_id, Map.get(p, :is_admin, true))}
        end),
      "inspect" => fn call -> inspect_result(config, db, call) end,
      "cancel" => fn call -> cancel_result(db, call) end,
      "spawn" => fn call -> spawn_result(config, db, call) end,
      "tune" => fn call -> tune_result(config, db, call) end,
      "retire" => fn call -> retire_result(db, call) end
    }
  end

  @doc """
  Shared turn-bearing delivery (gateway.ts `deliverPrompt`): ONE transaction
  appends the echo (Projection) + enqueues the turn (Ledger.enqueue_in_txn),
  then broadcasts the echo and nudges the lane. Returns the dedupe outcome.
  """
  @spec deliver_prompt(String.t(), String.t(), String.t(), keyword()) ::
          :appended | :duplicate | :conflict
  def deliver_prompt(session_key, origin, prompt, opts \\ []) do
    db = Keyword.get(opts, :db, Tightbeam.DB)

    input = %{
      session_key: session_key,
      role: "user",
      content: prompt,
      device_id: opts[:device_id],
      client_message_id: opts[:client_message_id],
      attachments: opts[:attachments] || [],
      sender: opts[:sender]
    }

    result =
      DB.transaction(db, fn txn ->
        case Projection.append_in_txn(txn, input) do
          {:appended, message} ->
            _seq =
              Ledger.enqueue_in_txn(txn, %{
                session_key: session_key,
                message_id: message.id,
                wake_id: opts[:wake_id],
                origin: origin,
                prompt: prompt
              })

            {:appended, message}

          other ->
            other
        end
      end)

    case result do
      {:ok, {:appended, message}} ->
        registry = Keyword.get(opts, :conn_registry, Tightbeam.ConnRegistry)
        publish_message(db, session_key, message, registry)

        publish_turn_state(
          db,
          session_key,
          message.client_message_id || message.id,
          "accepted",
          nil,
          registry
        )

        LaneManager.ensure_lane(
          Keyword.get(opts, :lane_manager, Tightbeam.LaneManager),
          session_key
        )

        :appended

      {:ok, {:duplicate, _message}} ->
        :duplicate

      {:ok, {:conflict, _message}} ->
        :conflict

      {:error, %{message: message}} when is_binary(message) ->
        if String.contains?(message, "UNIQUE"),
          do: :duplicate,
          else: raise(DB.Error, message: message)

      {:error, error} ->
        raise error
    end
  end

  @doc """
  Org options for client creation/tuning pickers (device-authed via
  GET /api/org-options): harnesses, per-harness model catalog, assimilated
  hosts, archetypes with their WHERE. Same data inspect gives agents —
  discovery beats documentation, for humans too.
  """
  @spec org_options() :: map()
  def org_options do
    base_dir = Application.get_env(:tightbeam, :base_dir, Path.join(System.user_home!(), ".tightbeam"))

    %{
      harnesses: ["claude", "codex"],
      models:
        Map.new(@model_catalog, fn {harness, models} ->
          provider = if harness == "codex", do: "openai", else: "anthropic"
          {harness, Enum.map(models, &%{id: &1.ref, ref: &1.ref, name: &1.name, provider: provider})}
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
  @spec session_status(String.t()) :: map() | nil
  def session_status(session_key) do
    case Org.get(Tightbeam.DB, session_key) do
      nil ->
        nil

      session ->
        {:ok, [[depth]]} =
          DB.query(
            Tightbeam.DB,
            "SELECT COUNT(*) FROM turns WHERE sessionKey = ?1 AND status IN ('queued','running')",
            [session_key]
          )

        archetype = Archetypes.get(session.archetype) || Archetypes.builtin_default()

        fallback_models =
          case archetype.fallback_models do
            [] -> nil
            chain -> chain
          end

        {_model, effort} = Adapter.parse_model_ref(session.model)
        catalog = Map.fetch!(@model_catalog, session.harness)
        unsupported = fn reason -> %{supported: false, reason: reason} end

        %{
          # sessionKey is REQUIRED by the client's SessionStatus decoder — its
          # absence fails the whole decode and the model footer never
          # populates (found live; the TS reference omitted it too).
          sessionKey: session_key,
          display: %{
            model: session.model,
            fallbackModels: fallback_models,
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
              options: Enum.map(catalog, &%{title: &1.name, value: &1.ref, enabled: true})
            },
            setThinking: unsupported.("thinking control lands in a later milestone"),
            setReasoning: unsupported.("select an effort variant via the model picker"),
            setFastMode: unsupported.("not supported"),
            setMode: unsupported.("sessions run YOLO"),
            setVerbosity: unsupported.("not supported"),
            canCancelCurrentRun: true,
            canChangeModel: true,
            canChangeReasoning: false,
            canChangeFastMode: false,
            canChangeVerbosity: false,
            readOnlyStatus: false
          },
          modelCatalog: %{
            available: true,
            # Client Model decoder REQUIRES id + provider + ref (id is the
            # stable identity; ref doubles as it here).
            models:
              Enum.map(
                catalog,
                &%{id: &1.ref, ref: &1.ref, name: &1.name, provider: session.provider}
              )
          }
        }
    end
  end

  defp defaults(config) do
    harness = config.default_harness

    %{
      archetype: "default",
      harness: harness,
      provider: if(harness == :codex, do: :openai, else: :anthropic),
      model: config.default_model
    }
  end

  defp install_cli_bin(base_dir) do
    bin_dir = Path.join(base_dir, "bin")
    File.mkdir_p!(bin_dir)
    wrapper = Path.join(bin_dir, "tightbeam")
    entry = Path.expand("../tightbeam/dist/cli/main.js", File.cwd!())
    File.write!(wrapper, "#!/bin/sh\nexec node \"#{entry}\" \"$@\"\n")
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
               harness_session(db, adapter, generation, session, turn.seq),
             {:ok, result} <-
               Adapter.prompt(adapter, harness_session_id, turn.prompt, 600_000,
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

            {:error, %{reason: reason, terminal_publish: failure_publish}}
        end

      outcome
    end
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

          harness_cancel(session)
        end

        Ledger.mark_published(db, seq)
        %{ok: true}

      _ ->
        %{ok: false, code: "not_running", message: "no turn in flight"}
    end
  end

  # Best-effort: the model should stop burning tokens, but a failure here
  # changes nothing durable (the ledger row is already terminal).
  defp harness_cancel(session) do
    with %{harness_session_id: sid} <- Org.current_pointer(Tightbeam.DB, session.session_key),
         key = {String.to_existing_atom(session.harness), session.archetype, session.host},
         {:ok, adapter, _gen} <- AdapterCoordinator.adapter_for(Tightbeam.AdapterCoordinator, key) do
      Tightbeam.Acp.Conn.notify(Tightbeam.Acp.Adapter.conn(adapter), "session/cancel", %{sessionId: sid})
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp checkout_adapter(session) do
    key = {String.to_existing_atom(session.harness), session.archetype, session.host}

    case AdapterCoordinator.adapter_for(Tightbeam.AdapterCoordinator, key) do
      {:ok, adapter, generation} ->
        {:ok, adapter, generation}

      {:error, :degraded} ->
        {:error,
         "adapter for #{session.harness}/#{session.archetype} on host #{session.host} is degraded " <>
           "(host unreachable or adapter failing); see /version"}
    end
  end

  defp harness_session(db, adapter, generation, session, turn_seq) do
    result =
      case Org.current_pointer(db, session.session_key) do
        nil ->
          with {:ok, sid} <- Adapter.new_session(adapter, session.model) do
            Org.append_pointer(db, session.session_key, sid, "created")
            {:ok, sid}
          end

        pointer ->
          # The adapter PROCESS is the authority on residency: stamped
          # generations reset across boots and can spuriously match.
          if Adapter.knows_session?(adapter, pointer.harness_session_id) do
            {:ok, pointer.harness_session_id}
          else
            AdapterCoordinator.with_load_slot(Tightbeam.AdapterCoordinator, fn ->
              case Adapter.load_session(adapter, pointer.harness_session_id, session.model) do
                :ok ->
                  Org.append_pointer(db, session.session_key, pointer.harness_session_id, "loaded")
                  {:ok, pointer.harness_session_id}

                {:error, _lost} ->
                  # Spec §pointer chain: reason "fallback" — the harness lost
                  # the session; start fresh, on the record, model context
                  # forfeited but chat history substrate-side and intact.
                  with {:ok, sid} <- Adapter.new_session(adapter, session.model) do
                    Org.append_pointer(db, session.session_key, sid, "fallback")
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

  defp resolve_caller(_db, "user:" <> user_id), do: %{owner_user_id: user_id, caller_session: nil}

  defp resolve_caller(db, "agent:" <> handle) do
    case Org.get_by_handle(db, handle) do
      %{state: "active"} = caller ->
        %{owner_user_id: caller.owner_user_id, caller_session: caller}

      _ ->
        nil
    end
  end

  defp resolve_caller(_db, _origin), do: nil

  defp admin_origin?(db, origin) do
    case resolve_caller(db, origin) do
      %{owner_user_id: user_id} -> match?(%{is_admin: true}, Devices.user(db, user_id))
      _ -> false
    end
  end

  defp admin_handler(db, fun) do
    fn call ->
      if admin_origin?(db, call.origin),
        do: fun.(call.params),
        else: %{code: "forbidden", message: "admin required"}
    end
  end

  defp inspect_result(config, db, call) do
    case resolve_caller(db, call.origin) do
      nil ->
        %{code: "unknown_caller"}

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
              %{name: a.name, where: a.where, defaults: a.defaults, fallback_models: a.fallback_models}
            end),
          hosts: config.base_dir |> Placement.hosts() |> Map.keys() |> Enum.sort(),
          models: @model_catalog
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
                :harness,
                :model,
                :origin,
                :spawned_by,
                :state
              ])
            ),
          wakes: wakes,
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

  defp spawn_result(config, db, call) do
    p = call.params

    case resolve_caller(db, call.origin) do
      nil ->
        %{code: "unknown_caller"}

      caller ->
        prior = Idempotency.get(db, caller.owner_user_id, "spawn", p.idempotency_key)

        cond do
          prior ->
            %{stream: db |> Org.get(prior.session_key) |> Payloads.stream_session()}

          length(Org.list_for_user(db, caller.owner_user_id, false)) >=
              config.max_live_sessions_per_user ->
            %{
              code: "cap_exceeded",
              message:
                "live-session cap (#{config.max_live_sessions_per_user}) reached for #{caller.owner_user_id}"
            }

          p[:handle] && Org.get_by_handle(db, p.handle) ->
            %{code: "handle_taken", message: "handle already in use: #{p.handle}"}

          true ->
            create_spawn(config, db, call, caller)
        end
    end
  end

  defp create_spawn(config, db, call, caller) do
    p = call.params
    defaults = defaults(config)
    archetype_name = p[:archetype] || defaults.archetype

    # Identity must exist; placement is constitutional set membership
    # (spec §Placement) — Placement denies, we relay, nobody judges.
    case Archetypes.get(archetype_name) do
      nil ->
        %{code: "unknown_archetype", message: "no such archetype: #{archetype_name}"}

      archetype ->
        case Placement.resolve(archetype, p[:host], Placement.hosts(config.base_dir)) do
          {:error, denial} -> denial
          {:ok, host} -> create_spawn(config, db, call, caller, archetype, host)
        end
    end
  end

  defp create_spawn(config, db, call, caller, archetype, host) do
    p = call.params
    defaults = defaults(config)
    harness = p[:harness] || archetype.defaults[:harness] || defaults.harness
    harness_string = to_string(harness)
    sessions = Org.list_for_user(db, caller.owner_user_id, false)

    model =
      p[:model] || archetype.defaults[:model] ||
        if(harness == defaults.harness,
          do: defaults.model,
          else:
            if(harness == :codex or harness == "codex", do: "gpt-5.6-sol[medium]", else: "haiku")
        )

    session =
      Org.create(db, %{
        display_name: p.display_name,
        kind: "custom",
        owner_user_id: caller.owner_user_id,
        origin: call.origin,
        spawned_by: caller.caller_session && caller.caller_session.session_key,
        handle: p[:handle],
        order_index: length(sessions),
        archetype: archetype.name,
        host: host,
        harness: harness_string,
        provider: if(harness_string == "codex", do: "openai", else: "anthropic"),
        model: model
      })

    Idempotency.put(db, %{
      owner_user_id: caller.owner_user_id,
      operation: "spawn",
      idempotency_key: p.idempotency_key,
      session_key: session.session_key
    })

    stream = Payloads.stream_session(session)
    broadcast(db, caller.owner_user_id, Payloads.stream_created(stream))
    %{stream: stream, session_key: session.session_key, handle: session.handle}
  end

  defp tune_result(config, db, call) do
    p = call.params

    cond do
      p[:setting] == "rename" and is_binary(p[:display_name]) ->
        session = Org.rename(db, call.session_key, p.display_name)
        stream = Payloads.stream_session(session)
        broadcast(db, session.owner_user_id, Payloads.stream_updated(stream))
        %{stream: stream}

      p[:setting] == "set_harness" and p[:harness] in ["claude", "codex"] ->
        case Org.get(db, call.session_key) do
          nil ->
            %{ok: false, code: "not_found"}

          session ->
            harness = p.harness
            provider = if harness == "codex", do: "openai", else: "anthropic"

            model =
              p[:model] ||
                case Map.fetch!(@model_catalog, harness) do
                  [first | _] -> first.ref
                end

            Org.set_harness(db, call.session_key, harness, provider, model)

            # History barrier (product ruling): a new engine gets a fresh
            # visible slate. Rows are RETAINED (never deleted) but replay
            # stops at the barrier, and live clients are told to drop their
            # local view. No pointer surgery: the old harness session can't
            # load on the new engine → fallback pointer, fresh context.
            {:ok, [[max_seq]]} =
              DB.query(db, "SELECT COALESCE(MAX(seq), 0) FROM messages WHERE sessionKey = ?1", [
                call.session_key
              ])

            Org.set_cleared_through(db, call.session_key, max_seq)
            broadcast(db, session.owner_user_id, Payloads.stream_history_cleared(call.session_key))

            %{ok: true, harness: harness, model: model, note: "engine swapped; chat cleared (rows retained); model context starts fresh"}
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
                # Fresh-context move (this increment): record the host; the
                # next turn's checkout targets the new host's adapter, the
                # old harness session's load-failure falls back per the
                # existing pointer machinery. Transcript carry-over is a
                # journaled later step.
                Org.set_host(db, call.session_key, host)
                %{ok: true, host: host}
            end
        end

      p[:setting] != "set_model" or not is_binary(p[:model]) ->
        %{ok: false, code: "unsupported", message: "tune does not support #{p[:setting]} yet"}

      true ->
        case Org.get(db, call.session_key) do
          nil ->
            %{ok: false, code: "not_found"}

          session ->
            Org.set_model(db, call.session_key, p.model, session.provider)

            with pointer when not is_nil(pointer) <- Org.current_pointer(db, call.session_key),
                 coordinator when is_pid(coordinator) <-
                   Process.whereis(Tightbeam.AdapterCoordinator),
                 {:ok, adapter, _generation} <-
                   AdapterCoordinator.adapter_for(
                     coordinator,
                     {String.to_existing_atom(session.harness), session.archetype, session.host}
                   ) do
              AdapterCoordinator.with_load_slot(coordinator, fn ->
                Adapter.load_session(adapter, pointer.harness_session_id, p.model)
              end)
            else
              _ -> :ok
            end

            %{ok: true}
        end
    end
  end

  defp retire_result(db, call) do
    p = call.params
    owner = String.replace_prefix(call.origin, "user:", "")
    prior = if p[:idempotency_key], do: Idempotency.get(db, owner, "retire", p.idempotency_key)

    cond do
      prior && prior.session_key == call.session_key ->
        %{deleted_session_key: call.session_key}

      true ->
        case Org.get(db, call.session_key) do
          %{owner_user_id: ^owner} = session ->
            if session.state == "active" do
              Org.retire(db, session.session_key)
              broadcast(db, owner, Payloads.stream_deleted(session.session_key))
            end

            if p[:idempotency_key] do
              Idempotency.put(db, %{
                owner_user_id: owner,
                operation: "retire",
                idempotency_key: p.idempotency_key,
                session_key: session.session_key
              })
            end

            %{deleted_session_key: session.session_key}

          _ ->
            %{code: "not_found"}
        end
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

  defp deliver(pid, payload), do: send(pid, {:push, payload})
end
