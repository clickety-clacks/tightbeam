defmodule Tightbeam.ModelSelectionRingDownTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Acp.Adapter,
    Archetypes,
    ConnRegistry,
    DB,
    Devices,
    ErrorDiagnostic,
    EventLog,
    HarnessHealth,
    Gateway,
    Identity,
    Ledger,
    Model,
    Org,
    Schema,
    Wakes
  }

  alias Tightbeam.GatewayTurnFixture.CoordinatorStub

  @default_preferences [
    {"synthetic-first", "low", nil},
    {"synthetic-second", "high", nil}
  ]

  @production_carrier_harness ~S"""
  const readline = require("node:readline");
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  let nextSession = 0;
  const models = {};
  const efforts = {};
  const effortConfig = process.argv[2] === "codex"
    ? "reasoning_effort"
    : process.argv[2] === "pi"
      ? "thought_level"
      : "effort";
  const configOptions = (sid) => ({ configOptions: [
    { id: "model", currentValue: models[sid] || "default" },
    { id: effortConfig, currentValue: efforts[sid] || "default" }
  ] });

  readline.createInterface({ input: process.stdin }).on("line", (line) => {
    if (!line.trim()) return;
    const request = JSON.parse(line);
    if (request.method === undefined) return;

    switch (request.method) {
      case "initialize":
        return send({ id: request.id, result: { protocolVersion: 1 } });

      case "session/new": {
        const sid = "carrier-" + (++nextSession);
        models[sid] = "default";
        efforts[sid] = "default";
        return send({ id: request.id, result: { sessionId: sid, ...configOptions(sid) } });
      }

      case "session/set_config_option": {
        const sid = request.params.sessionId;
        const id = request.params.configId;
        const value = request.params.value;

        if (id === "model" &&
            (value.includes("not-selectable") ||
              value.includes("synthetic-first") ||
              value.includes("cross-harness-failure"))) {
          return send({
            id: request.id,
            error: {
              code: -32602,
              message: "Invalid params",
              data: { model: value, detail: "not selectable" }
            }
          });
        }

        if (id === effortConfig && value === "medium") {
          return send({
            id: request.id,
            error: {
              code: -32602,
              message: "Invalid params"
            }
          });
        }

        if (id === effortConfig && models[sid] === "synthetic-invalid-effort") {
          // Recorded codex-acp carrier: an effort refusal can be JSON-RPC
          // -32602 Invalid params without an effort-specific message.
          return send({
            id: request.id,
            error: { code: -32602, message: "Invalid params" }
          });
        }

        if (id === "model") models[sid] = value;
        if (id === effortConfig) efforts[sid] = value;
        return send({ id: request.id, result: configOptions(sid) });
      }

      case "session/set_mode":
      case "session/close":
        return send({ id: request.id, result: {} });

      default:
        return send({ id: request.id, result: {} });
    }
  });
  """

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:register_lane, session_key}, _from, parent) do
      {:ok, _} = Registry.register(Tightbeam.LaneRegistry, session_key, nil)
      {:reply, :ok, parent}
    end

    def handle_call({:at_turn_boundary, fun}, _from, parent),
      do: {:reply, {:ok, fun.()}, parent}

    def handle_call(_message, _from, parent), do: {:reply, :ok, parent}
  end

  defmodule CatalogStub do
    use GenServer

    def start_link(entries), do: GenServer.start_link(__MODULE__, entries)

    def init(entries), do: {:ok, entries}

    def handle_call({:get, {host, harness}}, _from, entries) do
      {:reply, {Map.get(entries, {host, harness}, []), :fresh}, entries}
    end

    def handle_call(:get, _from, entries) do
      {:reply, entries, entries}
    end
  end

  defmodule RingDownAdapter do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    def init(state) do
      state = Map.put_new(state, :attempts, [])

      {:ok,
       Map.put_new(
         state,
         :prompt_outcome,
         {:ok,
          %{
            text: "synthetic reply",
            messages: [%{message_id: "synthetic-reply", text: "synthetic reply"}],
            stop_reason: "end_turn"
          }}
       )}
    end

    def handle_call({:knows_session?, _sid}, _from, state), do: {:reply, false, state}

    def handle_call({:new_session, model, _cwd, _mcp, _guidance}, _from, state),
      do: new_session_reply(model, state)

    def handle_call({:new_candidate_session, model, _cwd, _mcp, _guidance}, _from, state),
      do: new_session_reply(model, state)

    def handle_call(
          {:new_session, model, _cwd, _mcp, _guidance, _request_timeout},
          from,
          state
        ),
        do: handle_call({:new_session, model, nil, nil, nil}, from, state)

    def handle_call({:current_model, sid}, _from, state) do
      readback = Map.fetch!(state.readback, sid)
      reply = if match?({:error, _reason}, readback), do: readback, else: {:ok, readback}
      {:reply, reply, state}
    end

    def handle_call({:load_session, _sid, _model, _cwd, _mcp, _guidance}, _from, state),
      do: {:reply, {:error, :model_unavailable}, state}

    def handle_call(
          {:load_session, sid, model, cwd, mcp, guidance, _request_timeout},
          from,
          state
        ),
        do: handle_call({:load_session, sid, model, cwd, mcp, guidance}, from, state)

    def handle_call({:apply_model, _sid, _model}, _from, state), do: {:reply, :ok, state}

    def handle_call({:apply_model, sid, model, _request_timeout}, from, state),
      do: handle_call({:apply_model, sid, model}, from, state)

    def handle_call({:prompt, _sid, _prompt, _opts}, _from, state) do
      {:reply, state.prompt_outcome, state}
    end

    def handle_call({:close_session, _sid}, _from, state), do: {:reply, :ok, state}
    def handle_call(:conn, _from, state), do: {:reply, self(), state}

    defp new_session_reply(model, state) do
      send(state.parent, {:model_attempt, model})
      attempts = state.attempts ++ [model]
      model_key = if match?(%Model{}, model), do: model.family, else: nil
      outcome = Map.get(state.outcomes, model_key, {:error, :model_unavailable})

      case outcome do
        {:ok, sid} ->
          {:reply, {:ok, sid}, %{state | attempts: attempts}}

        {:error, reason} ->
          {:reply, {:error, reason}, %{state | attempts: attempts}}
      end
    end
  end

  test "turn keeps the first model refusal and does not advance the role list" do
    with_gateway(fn %{db: db, config: config, lane: lane} ->
      first = Model.new("synthetic-first", effort: "low")
      second = Model.new("synthetic-second", effort: "high")

      Org.create(db, %{
        session_key: "ring-success",
        display_name: "Synthetic ring success",
        owner_user_id: "synthetic-owner",
        origin: "user:synthetic-owner",
        archetype: "synthetic-ring",
        host: "testhost",
        harness: "fixture",
        provider: "fixture_provider",
        model: first
      })

      [first_reason] = production_model_use_failures([first])

      {:ok, adapter} =
        RingDownAdapter.start_link(
          parent: self(),
          outcomes: %{
            first.family => {:error, first_reason},
            second.family => {:ok, "synthetic-session"}
          },
          readback: %{"synthetic-session" => second}
        )

      {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})
      runner = runner(config)

      assert :appended =
               Gateway.deliver_prompt("ring-success", "user:synthetic-owner", "select",
                 db: db,
                 lane_manager: lane,
                 conn_registry: ConnRegistry,
                 client_message_id: "ring-success-client"
               )

      assert {:ok, turn} = Ledger.claim_next(db, "ring-success", "ring-test")

      assert {:error, %{reason: reason, terminal_publish: publish}} =
               runner.(Map.put(turn, :session_key, "ring-success"))

      assert reason =~ "Invalid params"
      assert_receive {:model_attempt, ^first}
      refute_receive {:model_attempt, ^second}
      assert Org.get(db, "ring-success").model == first

      attempts =
        EventLog.lifecycle_events(db)
        |> Enum.filter(&(&1.kind == "model_selection_attempt"))

      assert Enum.map(attempts, & &1.detail) |> Enum.join("\n") =~ "synthetic-first"
      assert Enum.map(attempts, & &1.detail) |> Enum.join("\n") =~ "not selectable"
      assert Enum.map(attempts, & &1.detail) |> Enum.join("\n") =~ "diagnostic"
      refute Enum.map(attempts, & &1.detail) |> Enum.join("\n") =~ "synthetic-second"

      assert :ok = Ledger.finish(db, turn.seq, "failed", reason, owner_lease: turn.owner_lease)

      publish.("failed")
    end)
  end

  test "raw harness refusal never selects an unlisted role preference" do
    with_gateway(fn %{db: db, config: config, lane: lane} ->
      first = Model.new("synthetic-first", effort: "low")
      second = Model.new("synthetic-second", effort: "high")

      {:ok, catalog} =
        CatalogStub.start_link(%{
          {"testhost", "fixture"} => [
            %{family: first.family, context: nil, efforts: ["low"], provider: :fixture_provider}
          ]
        })

      refusal = %{"code" => -32603, "message" => "Requested model was refused"}

      first_reason =
        ErrorDiagnostic.diagnosed(
          refusal,
          ErrorDiagnostic.new("jsonrpc_error",
            phase: "model",
            config_id: "model",
            reason: refusal
          )
        )

      {:ok, adapter} =
        RingDownAdapter.start_link(
          parent: self(),
          outcomes: %{
            first.family => {:error, first_reason},
            second.family => {:ok, "unlisted-session"}
          },
          readback: %{"unlisted-session" => second}
        )

      {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})
      config = Map.put(config, :model_catalog, catalog)

      Org.create(db, %{
        session_key: "ring-unlisted",
        display_name: "Unlisted ring entry",
        owner_user_id: "synthetic-owner",
        origin: "user:synthetic-owner",
        archetype: "synthetic-ring",
        host: "testhost",
        harness: "fixture",
        provider: "fixture_provider",
        model: first
      })

      assert :appended =
               Gateway.deliver_prompt("ring-unlisted", "user:synthetic-owner", "select",
                 db: db,
                 lane_manager: lane,
                 conn_registry: ConnRegistry,
                 client_message_id: "ring-unlisted-client"
               )

      assert {:ok, turn} = Ledger.claim_next(db, "ring-unlisted", "ring-test")

      assert {:error, %{reason: %{"code" => -32603, "message" => "Requested model was refused"}}} =
               runner(config).(Map.put(turn, :session_key, "ring-unlisted"))

      assert_receive {:model_attempt, ^first}
      refute_receive {:model_attempt, ^second}
      assert Org.get(db, "ring-unlisted").model == first

      details =
        EventLog.lifecycle_events(db)
        |> Enum.filter(&(&1.kind == "model_selection_attempt"))
        |> Enum.map(& &1.detail)
        |> Enum.join("\n")

      assert details =~ "Requested model was refused"
      refute details =~ "synthetic-second"
    end)
  end

  test "unavailable first model stops after one harness attempt" do
    with_gateway(fn %{db: db, config: config, lane: lane} ->
      first = Model.new("synthetic-first", effort: "low")
      second = Model.new("synthetic-second", effort: "high")

      Org.create(db, %{
        session_key: "ring-exhausted",
        display_name: "Synthetic ring exhausted",
        owner_user_id: "synthetic-owner",
        origin: "user:synthetic-owner",
        archetype: "synthetic-ring",
        host: "testhost",
        harness: "fixture",
        provider: "fixture_provider",
        model: first
      })

      {:ok, adapter} =
        RingDownAdapter.start_link(
          parent: self(),
          outcomes: %{
            first.family => {:error, :model_unavailable},
            second.family => {:error, :model_unavailable}
          },
          readback: %{}
        )

      {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})
      runner = runner(config)

      assert :appended =
               Gateway.deliver_prompt("ring-exhausted", "user:synthetic-owner", "exhaust",
                 db: db,
                 lane_manager: lane,
                 conn_registry: ConnRegistry,
                 client_message_id: "ring-exhausted-client"
               )

      assert {:ok, turn} = Ledger.claim_next(db, "ring-exhausted", "ring-test")

      assert {:error, %{reason: :model_unavailable}} =
               runner.(Map.put(turn, :session_key, "ring-exhausted"))

      assert_receive {:model_attempt, ^first}
      refute_receive {:model_attempt, ^second}
      refute_receive {:model_attempt, _}

      attempts =
        EventLog.lifecycle_events(db)
        |> Enum.filter(&(&1.kind == "model_selection_attempt"))

      assert length(attempts) == 1
    end)
  end

  test "user-started first-turn refusal keeps the harness text and lists literal role choices" do
    preferences = [
      {"synthetic-first", "low", nil, "fixture"},
      {"synthetic-second", "high", "wide", "codex"}
    ]

    with_gateway(
      fn %{db: db, config: config, lane: lane} ->
        first = Model.new("synthetic-first", effort: "low")
        second = Model.new("synthetic-second", effort: "high", context: "wide")
        corrected = Model.new("synthetic-corrected")
        [refusal] = production_model_use_failures([first])

        spawn = Gateway.handlers(config)["spawn"]

        assert %{session_key: session_key} =
                 spawn.(%{
                   origin: "user:synthetic-owner",
                   session_key: nil,
                   params: %{
                     archetype: "synthetic-ring",
                     display_name: "Role choice",
                     idempotency_key: "role-choice"
                   }
                 })

        {:ok, adapter} =
          RingDownAdapter.start_link(
            parent: self(),
            outcomes: %{
              first.family => {:error, refusal},
              corrected.family => {:ok, "chosen-session"}
            },
            readback: %{"chosen-session" => corrected}
          )

        {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})

        {:ok, _ref, nil} =
          ConnRegistry.register(ConnRegistry, %{
            pid: self(),
            user_id: "synthetic-owner",
            device_id: "role-choice",
            is_admin: false,
            subscriptions: MapSet.new(["chat"])
          })

        assert :appended =
                 Gateway.deliver_prompt(session_key, "user:synthetic-owner", "select",
                   db: db,
                   lane_manager: lane,
                   conn_registry: ConnRegistry,
                   client_message_id: "role-choice-client"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, session_key, "ring-test")

        assert {:error,
                %{reason: reason, terminal_publish: publish, record_in_txn: record_in_txn}} =
                 runner(config).(Map.put(turn, :session_key, session_key))

        assert reason =~ "Invalid params"
        assert_receive {:model_attempt, ^first}
        refute_receive {:model_attempt, ^second}

        assert {:ok, _} =
                 DB.transaction(db, fn txn ->
                   assert Ledger.finish_in_txn(txn, turn.seq, "failed", reason,
                            owner_lease: turn.owner_lease
                          )

                   record_in_txn.(txn)
                 end)

        publish.("failed")

        assert_receive {:push,
                        %{
                          "event" => "prompt_turn_state",
                          "payload" => %{
                            "state" => "failed",
                            "error" => ^reason,
                            "roleModelChoices" => [
                              %{
                                "model" => "synthetic-second",
                                "harness" => "codex",
                                "context" => "wide",
                                "effort" => "high"
                              }
                            ]
                          }
                        }}

        assert %{lastTurnError: ^reason, roleModelChoices: choices} =
                 Gateway.session_status(session_key, db)

        assert choices == [
                 %{
                   "model" => "synthetic-second",
                   "harness" => "codex",
                   "context" => "wide",
                   "effort" => "high"
                 }
               ]

        assert :ok =
                 GenServer.call(Tightbeam.LaneManager, {:register_lane, session_key})

        assert %{ok: true, requested: %{model: "synthetic-corrected"}} =
                 Gateway.handlers(config)["tune"].(%{
                   origin: "user:synthetic-owner",
                   session_key: session_key,
                   params: %{setting: "set_model", model: "synthetic-corrected"}
                 })

        assert_receive {:model_attempt, ^corrected}
        assert Org.get(db, session_key).model == corrected

        assert {:ok, [["failed"]]} =
                 DB.query(db, "SELECT status FROM turns WHERE seq = ?1", [turn.seq])
      end,
      preferences
    )
  end

  test "a refused role entry does not infer another harness from the catalog" do
    preferences = [
      {"synthetic-first", "low", nil},
      {"gpt-cross-harness-success", "medium", nil}
    ]

    with_gateway(
      fn %{db: db, config: config, lane: lane} ->
        first = Model.new("synthetic-first", effort: "low")
        second = Model.new("gpt-cross-harness-success", effort: "medium")

        {:ok, catalog} =
          CatalogStub.start_link(%{
            {"testhost", "codex"} => [
              %{family: second.family, context: nil, efforts: ["medium"], provider: :openai}
            ]
          })

        {:ok, fixture_adapter} =
          RingDownAdapter.start_link(
            parent: self(),
            outcomes: %{first.family => {:error, :model_unavailable}},
            readback: %{}
          )

        {:ok, codex_adapter} =
          RingDownAdapter.start_link(
            parent: self(),
            outcomes: %{second.family => {:ok, "must-not-run"}},
            readback: %{"must-not-run" => second}
          )

        coordinator = fn
          {:fixture, "shared", "testhost"} -> {:ok, fixture_adapter, 1}
          {:codex, "shared", "testhost"} -> {:ok, codex_adapter, 2}
        end

        {:ok, _coordinator} = CoordinatorStub.start_link({coordinator, self()})
        config = Map.put(config, :model_catalog, catalog)

        Org.create(db, %{
          session_key: "no-cross-harness",
          display_name: "No inferred harness",
          owner_user_id: "synthetic-owner",
          origin: "agent:creator",
          archetype: "synthetic-ring",
          host: "testhost",
          harness: "fixture",
          provider: "fixture_provider",
          model: first
        })

        assert :appended =
                 Gateway.deliver_prompt("no-cross-harness", "user:synthetic-owner", "select",
                   db: db,
                   lane_manager: lane,
                   conn_registry: ConnRegistry,
                   client_message_id: "no-cross-harness-client"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, "no-cross-harness", "ring-test")

        assert {:error, %{reason: :model_unavailable}} =
                 runner(config).(Map.put(turn, :session_key, "no-cross-harness"))

        assert_receive {:adapter_key, {:fixture, "shared", "testhost"}}
        refute_receive {:adapter_key, {:codex, "shared", "testhost"}}
        assert_receive {:model_attempt, ^first}
        refute_receive {:model_attempt, ^second}
        assert %{harness: "fixture", model: ^first} = Org.get(db, "no-cross-harness")
      end,
      preferences
    )
  end

  test "prompt failure is charged to the selected harness without a role retry" do
    with_gateway(fn %{db: db, config: config, lane: lane} ->
      first = Model.new("synthetic-first", effort: "low")
      second = Model.new("synthetic-second", effort: "high")
      rate_limit = %{"data" => %{"codexErrorInfo" => "usageLimitExceeded"}}

      Org.create(db, %{
        session_key: "same-harness-prompt-failure",
        display_name: "Selected harness prompt failure",
        owner_user_id: "synthetic-owner",
        origin: "user:synthetic-owner",
        archetype: "synthetic-ring",
        host: "testhost",
        harness: "fixture",
        provider: "fixture_provider",
        model: first
      })

      {:ok, adapter} =
        RingDownAdapter.start_link(
          parent: self(),
          outcomes: %{
            first.family => {:ok, "selected-session"},
            second.family => {:ok, "must-not-run"}
          },
          prompt_outcome: {:error, rate_limit},
          readback: %{"selected-session" => first}
        )

      {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})

      assert :appended =
               Gateway.deliver_prompt(
                 "same-harness-prompt-failure",
                 "user:synthetic-owner",
                 "prompt",
                 db: db,
                 lane_manager: lane,
                 conn_registry: ConnRegistry,
                 client_message_id: "same-harness-prompt-failure-client"
               )

      assert {:ok, turn} = Ledger.claim_next(db, "same-harness-prompt-failure", "ring-test")

      assert {:error, %{record_in_txn: record_in_txn}} =
               runner(config).(Map.put(turn, :session_key, "same-harness-prompt-failure"))

      assert_receive {:model_attempt, ^first}
      refute_receive {:model_attempt, ^second}
      assert Org.get(db, "same-harness-prompt-failure").harness == "fixture"
      assert {:ok, _publication} = DB.transaction(db, record_in_txn)
    end)
  end

  test "a Pi typed prompt failure fails the turn without resolving or replaying anything" do
    Application.put_env(:tightbeam, :pi_typed_turn_failures_enabled, true)

    with_gateway(fn %{db: db, config: config, lane: lane} ->
      config = Map.put(config, :model_catalog, route_catalog("pi"))
      first = Model.new("synthetic-first", effort: "low")
      session_key = "pi-typed-prompt-failure"

      # The JSON-RPC error the patched pi-acp 0.0.34 sends after retry exhaustion.
      exhausted = %{
        "code" => -32_603,
        "message" => "Internal error: pi retry exhausted after 4 attempts: Request timed out.",
        "data" => %{
          "errorKind" => "pi_retry_exhausted",
          "piAttempts" => 4,
          "transportAttempts" => "unobserved",
          "finalError" => "Request timed out."
        }
      }

      {:ok, adapter} =
        RingDownAdapter.start_link(
          parent: self(),
          outcomes: %{first.family => {:ok, "pi-typed-session"}},
          prompt_outcome: {:error, exhausted},
          readback: %{"pi-typed-session" => first}
        )

      {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})

      Org.create(db, %{
        session_key: session_key,
        display_name: "Synthetic Pi typed failure",
        owner_user_id: "synthetic-owner",
        origin: "user:synthetic-owner",
        archetype: "synthetic-ring",
        host: "testhost",
        harness: "pi",
        provider: "opencode_go",
        model: first
      })

      assert {:opened, %{id: incident_id}} =
               HarnessHealth.observe(db, health_incident_input("pi-typed-open", "pi"))

      run_turn = fn message_id, prompt ->
        assert :appended =
                 Gateway.deliver_prompt(session_key, "user:synthetic-owner", prompt,
                   db: db,
                   lane_manager: lane,
                   conn_registry: ConnRegistry,
                   client_message_id: message_id
                 )

        assert {:ok, turn} = Ledger.claim_next(db, session_key, "pi-typed-test")
        {turn, runner(config).(Map.put(turn, :session_key, session_key))}
      end

      {failed_turn, outcome} = run_turn.("pi-typed-failed", "fails after Pi retries")

      assert {:error, %{reason: ^exhausted, record_in_txn: record, terminal_publish: publish}} =
               outcome

      assert {:ok, publication} =
               DB.transaction(db, fn txn ->
                 assert true =
                          Ledger.finish_in_txn(
                            txn,
                            failed_turn.seq,
                            "failed",
                            "Internal error: pi retry exhausted after 4 attempts: Request timed out.",
                            owner_lease: failed_turn.owner_lease
                          )

                 record.(txn)
               end)

      if is_function(publication, 0), do: publication.()
      publish.("failed")

      assert {:ok, [[notice]]} =
               DB.query(
                 db,
                 "SELECT content FROM messages WHERE sessionKey=?1 AND content LIKE ?2",
                 [
                   session_key,
                   "[turn failed]%"
                 ]
               )

      assert notice =~ "pi retry exhausted after 4 attempts: Request timed out."

      assert {:ok, [["open"]]} =
               DB.query(db, "SELECT state FROM harness_health_incidents WHERE id=?1", [
                 incident_id
               ])

      assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM health_redelivery_attempts")

      assert [error_event] =
               EventLog.lifecycle_events(db)
               |> Enum.filter(&(&1.kind == "harness_turn_error"))

      assert error_event.detail =~ "pi_retry_exhausted"
      assert error_event.detail =~ "piAttempts"

      :sys.replace_state(adapter, fn state ->
        Map.put(
          state,
          :prompt_outcome,
          {:ok,
           %{
             text: "synthetic reply",
             messages: [%{message_id: "synthetic-reply", text: "synthetic reply"}],
             stop_reason: "end_turn"
           }}
        )
      end)

      {delivered_turn, outcome} = run_turn.("pi-typed-delivered", "succeeds on the route")
      assert {:ok, %{record_in_txn: record, terminal_publish: publish}} = outcome

      assert {:ok, publication} =
               DB.transaction(db, fn txn ->
                 assert true =
                          Ledger.finish_in_txn(txn, delivered_turn.seq, "delivered", nil,
                            owner_lease: delivered_turn.owner_lease
                          )

                 record.(txn)
               end)

      if is_function(publication, 0), do: publication.()
      publish.("delivered")

      # A real success on the route resolves the incident; the failed prompt
      # is not queued again.
      assert {:ok, [["resolved"]]} =
               DB.query(db, "SELECT state FROM harness_health_incidents WHERE id=?1", [
                 incident_id
               ])

      assert {:ok, [["failed"]]} =
               DB.query(db, "SELECT status FROM turns WHERE seq=?1", [failed_turn.seq])

      queued = "SELECT COUNT(*) FROM turns WHERE sessionKey=?1 AND status='queued'"
      assert {:ok, [[0]]} = DB.query(db, queued, [session_key])
    end)
  end

  for {label, harness, typed?, enabled?} <- [
        {"a Pi typed", "pi", true, true},
        {"a non-Pi typed", "fixture", true, true},
        {"an untyped Pi", "pi", false, true},
        {"a Pi typed with the flag off", "pi", true, false}
      ] do
    @tag harness: harness, typed: typed?, enabled: enabled?
    test "#{label} rate-limit failure of a wake-delivered prompt and its wake retry", ctx do
      Application.put_env(:tightbeam, :pi_typed_turn_failures_enabled, ctx.enabled)

      with_gateway(fn %{db: db, config: config} ->
        config = Map.put(config, :model_catalog, route_catalog(ctx.harness))
        first = Model.new("synthetic-first", effort: "low")
        session_key = "pi-typed-wake-failure"
        final_error = "429 rate limit exceeded: usage limit reached"

        failure = %{
          "code" => -32_603,
          "message" => "Internal error: pi retry exhausted after 4 attempts: " <> final_error,
          "data" => %{
            "errorKind" => "pi_retry_exhausted",
            "piAttempts" => 4,
            "transportAttempts" => "unobserved",
            "finalError" => final_error
          }
        }

        failure =
          if ctx.typed,
            do: failure,
            else: update_in(failure, ["data"], &Map.delete(&1, "errorKind"))

        {:ok, adapter} =
          RingDownAdapter.start_link(
            parent: self(),
            outcomes: %{first.family => {:ok, "pi-typed-wake-session"}},
            prompt_outcome: {:error, failure},
            readback: %{"pi-typed-wake-session" => first}
          )

        {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})

        Org.create(db, %{
          session_key: session_key,
          display_name: "Synthetic Pi wake failure",
          owner_user_id: "synthetic-owner",
          origin: "user:synthetic-owner",
          archetype: "synthetic-ring",
          host: "testhost",
          harness: ctx.harness,
          provider: route_provider(ctx.harness),
          model: first
        })

        wake =
          Wakes.schedule(db, %{
            session_key: session_key,
            origin: "agent:sender",
            prompt: "continue the work",
            due_at: 1
          })

        {:ok, _} =
          DB.query(db, "UPDATE wakes SET state='fired', firedAt=10 WHERE wakeId=?1", [
            wake.wake_id
          ])

        {:ok, _seq} =
          Ledger.enqueue(db, %{
            session_key: session_key,
            message_id: "pi-typed-wake-turn",
            wake_id: wake.wake_id,
            origin: "agent:sender",
            prompt: "continue the work"
          })

        assert {:ok, turn} = Ledger.claim_next(db, session_key, "pi-typed-wake-test")
        assert turn.wake_id == wake.wake_id

        assert {:error, %{reason: ^failure, record_in_txn: record, terminal_publish: publish}} =
                 runner(config).(Map.put(turn, :session_key, session_key))

        # turns.error as SessionLane writes it for a JSON-RPC error map.
        assert {:ok, publication} =
                 DB.transaction(db, fn txn ->
                   assert true =
                            Ledger.finish_in_txn(txn, turn.seq, "failed", inspect(failure),
                              owner_lease: turn.owner_lease
                            )

                   record.(txn)
                 end)

        if is_function(publication, 0), do: publication.()
        publish.("failed")

        # Rate-limit observation evidence is kept either way.
        assert {:ok, [[1]]} =
                 DB.query(
                   db,
                   "SELECT COUNT(*) FROM harness_health_observations WHERE correlationId=?1",
                   ["harness-turn:#{turn.seq}:rate-limit-dead"]
                 )

        {:ok, [[wake_retries]]} = DB.query(db, "SELECT COUNT(*) FROM wake_retry_attempts")

        {:ok, [[health_redeliveries]]} =
          DB.query(db, "SELECT COUNT(*) FROM health_redelivery_attempts")

        {:ok, [[successors]]} =
          DB.query(
            db,
            "SELECT COUNT(*) FROM wakes WHERE sessionKey=?1 AND wakeId!=?2 AND state='pending'",
            [session_key, wake.wake_id]
          )

        {:ok, [[queued]]} =
          DB.query(db, "SELECT COUNT(*) FROM turns WHERE sessionKey=?1 AND status='queued'", [
            session_key
          ])

        if ctx.enabled and ctx.typed and ctx.harness == "pi" do
          assert {wake_retries, health_redeliveries, successors, queued} == {0, 0, 0, 0}
        else
          # Controls: another harness's typed failure, or a Pi failure without the
          # Pi kind, keeps the existing rate-limit wake retry, one row for the
          # failed source and one for its pending successor.
          assert {wake_retries, successors} == {2, 1}
        end
      end)
    end
  end

  test "production model refusal preserves evidence without trying later entries" do
    preferences = [
      {"synthetic-not-selectable", "low", nil},
      {"synthetic-unsupported-effort", "medium", nil},
      {"synthetic-success", "max", "wide"}
    ]

    with_gateway(
      fn %{db: db, config: config, lane: lane} ->
        not_selectable = Model.new("synthetic-not-selectable", effort: "low")
        unsupported_effort = Model.new("synthetic-unsupported-effort", effort: "medium")
        selected = Model.new("synthetic-success", effort: "max", context: "wide")
        session_key = "ring-typed"

        [not_selectable_reason, effort_reason] =
          production_model_use_failures([not_selectable, unsupported_effort])

        assert %{"code" => -32602, "message" => "Invalid params"} =
                 ErrorDiagnostic.classified(not_selectable_reason)

        assert %{"phase" => "model"} = ErrorDiagnostic.of(not_selectable_reason)

        assert %{"code" => -32602, "message" => "Invalid params"} =
                 ErrorDiagnostic.classified(effort_reason)

        assert %{"phase" => "effort", "configId" => "effort"} = ErrorDiagnostic.of(effort_reason)

        Org.create(db, %{
          session_key: session_key,
          display_name: "Synthetic typed ring",
          owner_user_id: "synthetic-owner",
          origin: "user:synthetic-owner",
          archetype: "synthetic-ring",
          host: "testhost",
          harness: "fixture",
          provider: "fixture_provider",
          model: not_selectable
        })

        {:ok, adapter} =
          RingDownAdapter.start_link(
            parent: self(),
            outcomes: %{
              not_selectable.family => {:error, not_selectable_reason},
              unsupported_effort.family => {:error, effort_reason},
              selected.family => {:ok, "synthetic-typed-session"}
            },
            readback: %{"synthetic-typed-session" => selected}
          )

        {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})
        runner = runner(config)

        assert :appended =
                 Gateway.deliver_prompt(session_key, "user:synthetic-owner", "select",
                   db: db,
                   lane_manager: lane,
                   conn_registry: ConnRegistry,
                   client_message_id: "ring-typed-client"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, session_key, "ring-test")

        assert {:error, %{reason: reason, terminal_publish: publish}} =
                 runner.(Map.put(turn, :session_key, session_key))

        assert reason =~ "Invalid params"
        assert_receive {:model_attempt, ^not_selectable}
        refute_receive {:model_attempt, ^unsupported_effort}
        refute_receive {:model_attempt, ^selected}
        refute_receive {:model_attempt, _}
        assert Org.get(db, session_key).model == not_selectable

        details =
          EventLog.lifecycle_events(db)
          |> Enum.filter(&(&1.kind == "model_selection_attempt"))
          |> Enum.map(& &1.detail)
          |> Enum.join("\n")

        assert details =~ "not selectable"
        assert details =~ "Invalid params"
        assert details =~ "classification"
        assert details =~ "original_reason"
        assert details =~ "\"$type\":\"tuple\""
        assert details =~ "diagnostic"

        assert :ok = Ledger.finish(db, turn.seq, "failed", reason, owner_lease: turn.owner_lease)

        publish.("failed")
      end,
      preferences
    )
  end

  test "production effort carriers use each harness option identifier" do
    for {harness, family, config_id} <- [
          {:codex, "gpt-5.6-sol", "reasoning_effort"},
          {:pi, "opencode-go/gpt-5.6-sol", "thought_level"}
        ] do
      [reason] =
        production_model_use_failures(
          [Model.new(family, effort: "medium")],
          harness
        )

      assert %{"code" => -32602, "message" => "Invalid params"} =
               ErrorDiagnostic.classified(reason)

      assert %{"phase" => "effort", "configId" => ^config_id} = ErrorDiagnostic.of(reason)
    end
  end

  test "successful setup is accepted without an extra model readback gate" do
    with_gateway(fn %{db: db, config: config, lane: lane} ->
      first = Model.new("synthetic-first", effort: "low")
      second = Model.new("synthetic-second", effort: "high")
      session_key = "ring-no-readback"

      Org.create(db, %{
        session_key: session_key,
        display_name: "Synthetic missing readback",
        owner_user_id: "synthetic-owner",
        origin: "user:synthetic-owner",
        archetype: "synthetic-ring",
        host: "testhost",
        harness: "fixture",
        provider: "fixture_provider",
        model: first
      })

      {:ok, adapter} =
        RingDownAdapter.start_link(
          parent: self(),
          outcomes: %{
            first.family => {:ok, "synthetic-no-readback"},
            second.family => {:ok, "must-not-run"}
          },
          readback: %{"synthetic-no-readback" => {:error, :model_readback_unavailable}}
        )

      {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})
      runner = runner(config)

      assert :appended =
               Gateway.deliver_prompt(session_key, "user:synthetic-owner", "readback",
                 db: db,
                 lane_manager: lane,
                 conn_registry: ConnRegistry,
                 client_message_id: "ring-no-readback-client"
               )

      assert {:ok, turn} = Ledger.claim_next(db, session_key, "ring-test")

      assert {:ok, %{terminal_publish: publish}} =
               runner.(Map.put(turn, :session_key, session_key))

      assert_receive {:model_attempt, ^first}
      refute_receive {:model_attempt, ^second}
      assert Org.get(db, session_key).model == first

      assert :ok = Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

      publish.("delivered")
    end)
  end

  test "recorded invalid-params effort carrier does not advance the role list" do
    preferences = [
      {"synthetic-invalid-effort", "max", nil},
      {"synthetic-success", "high", "wide"}
    ]

    with_gateway(
      fn %{db: db, config: config, lane: lane} ->
        effort_model = Model.new("synthetic-invalid-effort", effort: "max")
        selected = Model.new("synthetic-success", effort: "high", context: "wide")
        session_key = "ring-recorded-effort"

        [effort_reason] = production_model_use_failures([effort_model])

        assert %{"code" => -32602, "message" => "Invalid params"} =
                 ErrorDiagnostic.classified(effort_reason)

        assert %{"phase" => "effort"} = ErrorDiagnostic.of(effort_reason)

        Org.create(db, %{
          session_key: session_key,
          display_name: "Synthetic recorded effort ring",
          owner_user_id: "synthetic-owner",
          origin: "user:synthetic-owner",
          archetype: "synthetic-ring",
          host: "testhost",
          harness: "fixture",
          provider: "fixture_provider",
          model: effort_model
        })

        {:ok, adapter} =
          RingDownAdapter.start_link(
            parent: self(),
            outcomes: %{
              effort_model.family => {:error, effort_reason},
              selected.family => {:ok, "synthetic-recorded-effort-session"}
            },
            readback: %{"synthetic-recorded-effort-session" => selected}
          )

        {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})
        runner = runner(config)

        assert :appended =
                 Gateway.deliver_prompt(session_key, "user:synthetic-owner", "select",
                   db: db,
                   lane_manager: lane,
                   conn_registry: ConnRegistry,
                   client_message_id: "ring-recorded-effort-client"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, session_key, "ring-test")

        assert {:error, %{reason: reason, terminal_publish: publish}} =
                 runner.(Map.put(turn, :session_key, session_key))

        assert reason =~ "Invalid params"
        assert_receive {:model_attempt, ^effort_model}
        refute_receive {:model_attempt, ^selected}
        refute_receive {:model_attempt, _}
        assert Org.get(db, session_key).model == effort_model

        details =
          EventLog.lifecycle_events(db)
          |> Enum.filter(&(&1.kind == "model_selection_attempt"))
          |> Enum.map(& &1.detail)
          |> Enum.join("\n")

        assert details =~ "Invalid params"
        assert details =~ "effort"
        assert details =~ "original_reason"
        assert details =~ "diagnostic"

        assert :ok = Ledger.finish(db, turn.seq, "failed", reason, owner_lease: turn.owner_lease)

        publish.("failed")
      end,
      preferences
    )
  end

  test "successful setup is not gated by cached model readback" do
    with_gateway(fn %{db: db, config: config, lane: lane} ->
      first = Model.new("synthetic-first", effort: "low")
      second = Model.new("synthetic-second", effort: "high")
      actual = Model.new("synthetic-first", effort: "high")
      session_key = "ring-mismatch"

      Org.create(db, %{
        session_key: session_key,
        display_name: "Synthetic mismatched readback",
        owner_user_id: "synthetic-owner",
        origin: "user:synthetic-owner",
        archetype: "synthetic-ring",
        host: "testhost",
        harness: "fixture",
        provider: "fixture_provider",
        model: first
      })

      {:ok, adapter} =
        RingDownAdapter.start_link(
          parent: self(),
          outcomes: %{
            first.family => {:ok, "synthetic-mismatch"},
            second.family => {:ok, "must-not-run"}
          },
          readback: %{"synthetic-mismatch" => actual}
        )

      {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})
      runner = runner(config)

      assert :appended =
               Gateway.deliver_prompt(session_key, "user:synthetic-owner", "mismatch",
                 db: db,
                 lane_manager: lane,
                 conn_registry: ConnRegistry,
                 client_message_id: "ring-mismatch-client"
               )

      assert {:ok, turn} = Ledger.claim_next(db, session_key, "ring-test")

      assert {:ok, %{terminal_publish: publish}} =
               runner.(Map.put(turn, :session_key, session_key))

      assert_receive {:model_attempt, ^first}
      refute_receive {:model_attempt, ^second}
      assert Org.get(db, session_key).model == first

      assert :ok = Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

      publish.("delivered")
    end)
  end

  for {label, failure} <- [
        {"credential", {:credential, :invalid}},
        {"transport", {:transport, :unavailable}},
        {"quota", {:quota, :exhausted}},
        {"cancel", :cancelled},
        {"timeout", :timeout},
        {
          "closed-effort",
          ErrorDiagnostic.diagnosed(
            :closed,
            ErrorDiagnostic.new("closed", phase: "effort", config_id: "effort")
          )
        },
        {
          "timeout-effort",
          ErrorDiagnostic.diagnosed(
            :timeout,
            ErrorDiagnostic.new("timeout", phase: "effort", config_id: "effort")
          )
        },
        {"trace", {:trace, :failed}},
        {"degraded", {:degraded, :provider}}
      ] do
    test "#{label} failures remain terminal and do not ring down" do
      failure = unquote(Macro.escape(failure))
      expected = ErrorDiagnostic.classified(failure)
      session_key = unquote(Macro.escape("ring-terminal-#{label}"))

      with_gateway(fn %{db: db, config: config, lane: lane} ->
        first = Model.new("synthetic-first", effort: "low")
        second = Model.new("synthetic-second", effort: "high")

        Org.create(db, %{
          session_key: session_key,
          display_name: "Synthetic terminal ring",
          owner_user_id: "synthetic-owner",
          origin: "user:synthetic-owner",
          archetype: "synthetic-ring",
          host: "testhost",
          harness: "fixture",
          provider: "fixture_provider",
          model: first
        })

        {:ok, adapter} =
          RingDownAdapter.start_link(
            parent: self(),
            outcomes: %{
              first.family => {:error, failure},
              second.family => {:ok, "must-not-run"}
            },
            readback: %{}
          )

        {:ok, _coordinator} = CoordinatorStub.start_link({adapter, self()})
        runner = runner(config)

        assert :appended =
                 Gateway.deliver_prompt(session_key, "user:synthetic-owner", "terminal",
                   db: db,
                   lane_manager: lane,
                   conn_registry: ConnRegistry,
                   client_message_id: session_key <> "-client"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, session_key, "ring-test")
        assert {:error, %{reason: ^expected}} = runner.(Map.put(turn, :session_key, session_key))

        assert_receive {:model_attempt, ^first}
        refute_receive {:model_attempt, ^second}

        if ErrorDiagnostic.of(failure) do
          details =
            EventLog.lifecycle_events(db)
            |> Enum.filter(&(&1.kind == "model_selection_attempt"))
            |> Enum.map(& &1.detail)
            |> Enum.join("\n")

          assert details =~ "original_reason"
          assert details =~ "diagnostic"
          assert details =~ "phase"
          assert details =~ "configId"
        end
      end)
    end
  end

  test "spawn uses the first configured preference and persists its routed harness" do
    preferences = [
      {"synthetic-second", "high", nil},
      {"synthetic-first", "low", nil}
    ]

    with_gateway(
      fn %{db: db, config: config} ->
        spawn = Gateway.handlers(config)["spawn"]

        assert %{session_key: session_key} =
                 spawn.(%{
                   origin: "user:synthetic-owner",
                   session_key: nil,
                   params: %{
                     archetype: "synthetic-ring",
                     display_name: "Preference spawn",
                     idempotency_key: "preference-spawn"
                   }
                 })

        assert %{
                 harness: "fixture",
                 provider: "fixture_provider",
                 model: %Model{family: "synthetic-second", effort: "high"}
               } = Org.get(db, session_key)
      end,
      preferences
    )
  end

  test "spawn keeps the first named preference when the catalog omits it" do
    preferences = [
      {"synthetic-missing", "low", nil},
      {"synthetic-available", "high", nil}
    ]

    with_gateway(
      fn %{db: db, config: config} ->
        {:ok, catalog} =
          CatalogStub.start_link(%{
            {"testhost", "fixture"} => [
              %{
                family: "synthetic-available",
                context: nil,
                efforts: ["high"],
                provider: :fixture_provider
              }
            ]
          })

        spawn = Gateway.handlers(Map.put(config, :model_catalog, catalog))["spawn"]

        assert %{session_key: session_key} =
                 spawn.(%{
                   origin: "user:synthetic-owner",
                   session_key: nil,
                   params: %{
                     archetype: "synthetic-ring",
                     display_name: "Unlisted preference",
                     idempotency_key: "unlisted-preference"
                   }
                 })

        assert %Model{family: "synthetic-missing"} = Org.get(db, session_key).model
      end,
      preferences
    )
  end

  test "spawn preserves the first preference when the catalog has no entries" do
    preferences = [
      {"synthetic-missing-one", "low", nil},
      {"synthetic-missing-two", "high", nil}
    ]

    with_gateway(
      fn %{db: db, config: config} ->
        {:ok, catalog} = CatalogStub.start_link(%{})
        spawn = Gateway.handlers(Map.put(config, :model_catalog, catalog))["spawn"]

        assert %{session_key: session_key} =
                 spawn.(%{
                   origin: "user:synthetic-owner",
                   session_key: nil,
                   params: %{
                     archetype: "synthetic-ring",
                     display_name: "Unlisted preferences",
                     idempotency_key: "unlisted-preferences"
                   }
                 })

        assert %Model{family: "synthetic-missing-one"} = Org.get(db, session_key).model
      end,
      preferences
    )
  end

  defp runner(config) do
    {Tightbeam.LaneManager, lane_opts} =
      config
      |> Gateway.children()
      |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

    Keyword.fetch!(lane_opts, :runner)
  end

  defp with_gateway(fun, preferences \\ @default_preferences) do
    scratch =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-model-ring-#{System.unique_integer([:positive])}"
      )

    runtime = Tightbeam.GuardRuntimeFixture.prepare!(scratch, "model_ring_unused.exs")
    base = runtime.base
    db_name = :"model_ring_db_#{System.unique_integer([:positive])}"

    db =
      start_supervised!(
        {DB,
         path: Path.join(base, "state.db"),
         payload_root: runtime.payload,
         name: db_name,
         guard_inputs: []},
        id: db_name
      )

    :ok = DB.assert_base_admitted!(db, base)
    :initialized = Identity.init!(base)
    write_archetype!(base, preferences)
    publish_identity!(base)
    :ok = Schema.ensure_all(db)
    :ok = Archetypes.load!(base) |> then(fn _ -> :ok end)
    Devices.add_user(db, "synthetic-owner", false)
    write_fixture_binaries!(base)

    {:ok, catalog} =
      CatalogStub.start_link(%{
        {"testhost", "fixture"} =>
          Enum.map(preferences, fn preference ->
            {family, effort, context, _harness} = preference_fields(preference)
            %{family: family, context: context, efforts: [effort], provider: :fixture_provider}
          end)
      })

    Application.put_env(:tightbeam, :base_dir, base)
    Application.put_env(:tightbeam, :autostart, false)
    Application.put_env(:tightbeam, :local_host_name, "testhost")

    _registry = start_supervised!({ConnRegistry, name: ConnRegistry}, id: :model_ring_registry)

    _lane_registry =
      start_supervised!(
        {Registry, keys: :unique, name: Tightbeam.LaneRegistry},
        id: :model_ring_lane_registry
      )

    _turn_tasks =
      start_supervised!(
        {Task.Supervisor, name: Tightbeam.TurnTaskSupervisor},
        id: :model_ring_turn_tasks
      )

    lane = start_supervised!({LaneDoorbell, self()}, id: :model_ring_lane)

    config = %{
      base_dir: base,
      cwd: base,
      db: db,
      port: 0,
      default_harness: :fixture,
      default_model: Model.new("synthetic-first", effort: "low"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      model_catalog: catalog,
      credential_status: fn _provider, _machine -> :onboarded end,
      patch_adapter: fn _harness, _path -> :ok end
    }

    fun.(%{base: base, db: db, config: config, lane: lane})
  end

  defp write_archetype!(base, preferences) do
    path = Path.join([base, "identity", "archetypes", "synthetic-ring.toml"])

    entries =
      Enum.map_join(preferences, <<10>>, fn preference ->
        {family, effort, context, harness} = preference_fields(preference)

        context_line =
          if is_binary(context), do: "context = " <> inspect(context) <> <<10>>, else: ""

        harness_line =
          if is_binary(harness), do: "harness = " <> inspect(harness) <> <<10>>, else: ""

        """
        [[model_preferences]]
        model = "#{family}"
        effort = "#{effort}"
        #{context_line}
        #{harness_line}
        """
      end)

    File.write!(path, """
    name = "synthetic-ring"
    where = ["testhost"]

    #{entries}
    """)
  end

  defp preference_fields({family, effort, context}),
    do: {family, effort, context, nil}

  defp preference_fields({family, effort, context, harness}),
    do: {family, effort, context, harness}

  defp write_fixture_binaries!(base) do
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)

    for name <- ["claude", "codex", "cursor", "pi", "fixture"] do
      path = Path.join(bin, name)
      File.write!(path, "#!/bin/sh\necho fixture-only\n")
      File.chmod!(path, 0o755)
    end

    for {harness, credential, adapter} <- [
          {:fixture, "fixture.json", "fixture-acp"},
          {:codex, "auth.json", "codex-acp"}
        ] do
      home = Tightbeam.Homes.home_path(base, "testhost", harness)
      File.mkdir_p!(home)
      File.write!(Path.join(home, credential), "synthetic-credential")

      adapter_path = Path.join([base, "adapters", "node_modules", ".bin", adapter])
      File.mkdir_p!(Path.dirname(adapter_path))
      File.write!(adapter_path, "#!/bin/sh\n")
      File.chmod!(adapter_path, 0o755)
    end
  end

  defp route_provider("pi"), do: "opencode_go"
  defp route_provider("fixture"), do: "fixture_provider"

  defp route_catalog(harness) do
    {:ok, catalog} =
      CatalogStub.start_link(%{
        {"testhost", harness} =>
          Enum.map(@default_preferences, fn {family, effort, context} ->
            %{
              family: family,
              context: context,
              efforts: [effort],
              provider: String.to_existing_atom(route_provider(harness))
            }
          end)
      })

    catalog
  end

  defp health_incident_input(correlation_id, harness) do
    %{
      correlation_id: correlation_id,
      harness: harness,
      host: "testhost",
      failure_class: "adapter_unavailable",
      evidence_kind: "authoritative-provider",
      session_key: nil,
      assignment_id: nil,
      observed_at: System.system_time(:millisecond),
      cause: "ring-down health attribution",
      principal: "test:model-selection-ring-down"
    }
  end

  defp production_model_use_failures(models, harness \\ :claude) do
    run_dir =
      Path.join(
        System.tmp_dir!(),
        "tb-ring-carriers-#{:os.getpid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(run_dir)
    script = Path.join(run_dir, "carrier_harness.js")
    stderr = Path.join(run_dir, "stderr.log")
    File.write!(script, @production_carrier_harness)

    on_exit(fn -> File.rm_rf(run_dir) end)

    node = System.find_executable("node") || flunk("node is required for production carriers")

    adapter =
      start_supervised!(%{
        id: {:production_carrier_adapter, System.unique_integer([:positive])},
        start:
          {Adapter, :start_link,
           [
             [
               harness: harness,
               cmd: [node, script, Atom.to_string(harness)],
               home: "/tmp",
               cwd: "/tmp",
               stderr_path: stderr
             ]
           ]},
        restart: :temporary
      })

    Enum.map(models, fn model ->
      case Adapter.new_session_for_turn(adapter, model, "/tmp", [], "fixture") do
        {:error, reason} -> reason
        other -> flunk("carrier harness accepted #{inspect(model)}: #{inspect(other)}")
      end
    end)
  end

  defp publish_identity!(base) do
    identity = Path.join(base, "identity")
    git!(identity, ["add", "-A"])
    git!(identity, ["commit", "-m", "test: synthetic model ring"])
    candidate = git!(identity, ["rev-parse", "main"])
    expected_prior = git!(identity, ["rev-parse", "tightbeam/live"])

    {:ok, _revision} =
      Identity.publish_live!(base, %{
        expected_prior: expected_prior,
        candidate_revision: candidate,
        tree_fingerprint: String.duplicate("0", 64)
      })

    :ok
  end

  defp git!(dir, args) do
    env = [
      {"GIT_AUTHOR_NAME", "model-selection-test"},
      {"GIT_AUTHOR_EMAIL", "model-selection-test@tightbeam.invalid"},
      {"GIT_COMMITTER_NAME", "model-selection-test"},
      {"GIT_COMMITTER_EMAIL", "model-selection-test@tightbeam.invalid"}
    ]

    case System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true) do
      {output, 0} -> String.trim_trailing(output)
      {output, status} -> raise "git failed #{status}: #{output}"
    end
  end
end
