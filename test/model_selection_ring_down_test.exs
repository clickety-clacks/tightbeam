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
    Schema
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

  test "turn advances from a refused configured entry to the next exact model and readback" do
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

      assert {:ok, %{terminal_publish: publish}} =
               runner.(Map.put(turn, :session_key, "ring-success"))

      assert_receive {:model_attempt, ^first}
      assert_receive {:model_attempt, ^second}
      assert Org.get(db, "ring-success").model == second

      attempts =
        EventLog.lifecycle_events(db)
        |> Enum.filter(&(&1.kind == "model_selection_attempt"))

      assert Enum.map(attempts, & &1.detail) |> Enum.join("\n") =~ "synthetic-first"
      assert Enum.map(attempts, & &1.detail) |> Enum.join("\n") =~ "not selectable"
      assert Enum.map(attempts, & &1.detail) |> Enum.join("\n") =~ "diagnostic"
      assert Enum.map(attempts, & &1.detail) |> Enum.join("\n") =~ "synthetic-second"

      assert :ok = Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

      publish.("delivered")
    end)
  end

  test "turn exhaustion stops at the configured entries and keeps the typed refusal" do
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

      assert {:error, %{reason: %{code: "model_selection_exhausted", message: message}}} =
               runner.(Map.put(turn, :session_key, "ring-exhausted"))

      assert message =~ "all configured model preferences were exhausted"
      assert message =~ "synthetic-second"

      assert_receive {:model_attempt, ^first}
      assert_receive {:model_attempt, ^second}
      refute_receive {:model_attempt, _}

      attempts =
        EventLog.lifecycle_events(db)
        |> Enum.filter(&(&1.kind == "model_selection_attempt"))

      assert length(attempts) == 2
    end)
  end

  test "cross-harness configured candidates are tried before clear exhaustion" do
    preferences = [
      {"synthetic-first", "low", nil},
      {"gpt-cross-harness-failure", "medium", nil}
    ]

    with_gateway(
      fn %{db: db, config: config, lane: lane} ->
        first = Model.new("synthetic-first", effort: "low")
        cross_harness = Model.new("gpt-cross-harness-failure", effort: "medium")
        session_key = "ring-cross-harness"

        [cross_harness_reason] = production_model_use_failures([cross_harness], :codex)

        {:ok, catalog} =
          CatalogStub.start_link(%{
            {"testhost", "codex"} => [
              %{
                family: cross_harness.family,
                context: nil,
                efforts: ["medium"],
                provider: :openai
              }
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
            outcomes: %{cross_harness.family => {:error, cross_harness_reason}},
            readback: %{}
          )

        coordinator = fn
          {:fixture, "shared", "testhost"} -> {:ok, fixture_adapter, 1}
          {:codex, "shared", "testhost"} -> {:ok, codex_adapter, 2}
        end

        {:ok, _coordinator} = CoordinatorStub.start_link({coordinator, self()})
        config = Map.put(config, :model_catalog, catalog)

        Org.create(db, %{
          session_key: session_key,
          display_name: "Synthetic cross-harness exhaustion",
          owner_user_id: "synthetic-owner",
          origin: "user:synthetic-owner",
          archetype: "synthetic-ring",
          host: "testhost",
          harness: "fixture",
          provider: "fixture_provider",
          model: first
        })

        runner = runner(config)

        assert :appended =
                 Gateway.deliver_prompt(session_key, "user:synthetic-owner", "cross-harness",
                   db: db,
                   lane_manager: lane,
                   conn_registry: ConnRegistry,
                   client_message_id: "ring-cross-harness-client"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, session_key, "ring-test")

        assert {:error, %{reason: %{code: "model_selection_exhausted", message: message}}} =
                 runner.(Map.put(turn, :session_key, session_key))

        assert message =~ "all configured model preferences were exhausted"
        assert message =~ "gpt-cross-harness-failure"

        assert_receive {:adapter_key, {:fixture, "shared", "testhost"}}
        assert_receive {:adapter_key, {:codex, "shared", "testhost"}}
        assert_receive {:model_attempt, ^first}
        assert_receive {:model_attempt, ^cross_harness}
        refute_receive {:model_attempt, _}

        details =
          EventLog.lifecycle_events(db)
          |> Enum.filter(&(&1.kind == "model_selection_attempt"))
          |> Enum.map(& &1.detail)
          |> Enum.join("\n")

        assert details =~ "gpt-cross-harness-failure"
        assert details =~ "Invalid params"
        assert details =~ "original_reason"
        assert Org.get(db, session_key).harness == "fixture"
      end,
      preferences
    )
  end

  test "cross-harness configured success moves the durable session before prompt" do
    preferences = [
      {"synthetic-first", "low", nil},
      {"gpt-cross-harness-success", "medium", nil}
    ]

    with_gateway(
      fn %{db: db, config: config, lane: lane} ->
        first = Model.new("synthetic-first", effort: "low")
        cross_harness = Model.new("gpt-cross-harness-success", effort: "medium")
        session_key = "ring-cross-harness-success"

        {:ok, catalog} =
          CatalogStub.start_link(%{
            {"testhost", "codex"} => [
              %{
                family: cross_harness.family,
                context: nil,
                efforts: ["medium"],
                provider: :openai
              }
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
            outcomes: %{cross_harness.family => {:ok, "cross-harness-session"}},
            readback: %{}
          )

        coordinator = fn
          {:fixture, "shared", "testhost"} -> {:ok, fixture_adapter, 1}
          {:codex, "shared", "testhost"} -> {:ok, codex_adapter, 2}
        end

        {:ok, _coordinator} = CoordinatorStub.start_link({coordinator, self()})
        config = Map.put(config, :model_catalog, catalog)

        Org.create(db, %{
          session_key: session_key,
          display_name: "Synthetic cross-harness success",
          owner_user_id: "synthetic-owner",
          origin: "user:synthetic-owner",
          archetype: "synthetic-ring",
          host: "testhost",
          harness: "fixture",
          provider: "fixture_provider",
          model: first
        })

        assert :appended =
                 Gateway.deliver_prompt(session_key, "user:synthetic-owner", "cross-harness",
                   db: db,
                   lane_manager: lane,
                   conn_registry: ConnRegistry,
                   client_message_id: "ring-cross-harness-success-client"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, session_key, "ring-test")

        assert {:opened, _} =
                 HarnessHealth.observe(
                   db,
                   health_incident_input("ring-cross-harness-success-old", "fixture")
                 )

        assert {:opened, _} =
                 HarnessHealth.observe(
                   db,
                   health_incident_input("ring-cross-harness-success-new", "codex")
                 )

        assert {:ok, %{terminal_publish: publish, record_in_txn: record_in_txn}} =
                 runner(config).(Map.put(turn, :session_key, session_key))

        assert_receive {:adapter_key, {:fixture, "shared", "testhost"}}
        assert_receive {:adapter_key, {:codex, "shared", "testhost"}}
        assert_receive {:model_attempt, ^first}
        assert_receive {:model_attempt, ^cross_harness}

        assert %{harness: "codex", provider: "openai", model: ^cross_harness} =
                 Org.get(db, session_key)

        assert {:ok, publication} = DB.transaction(db, record_in_txn)
        if is_function(publication, 0), do: publication.()

        assert {:ok, incidents} =
                 DB.query(
                   db,
                   "SELECT harness,host,failureClass,state FROM harness_health_incidents ORDER BY harness"
                 )

        assert ["fixture", "testhost", "adapter_unavailable", "open"] in incidents
        assert ["codex", "testhost", "adapter_unavailable", "resolved"] in incidents

        assert :ok = Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)
        publish.("delivered")
      end,
      preferences
    )
  end

  test "cross-harness prompt failure records health against the moved session" do
    preferences = [
      {"synthetic-first", "low", nil},
      {"gpt-cross-harness-health-failure", "medium", nil}
    ]

    with_gateway(
      fn %{db: db, config: config, lane: lane} ->
        first = Model.new("synthetic-first", effort: "low")
        cross_harness = Model.new("gpt-cross-harness-health-failure", effort: "medium")
        session_key = "ring-cross-harness-health-failure"

        {:ok, catalog} =
          CatalogStub.start_link(%{
            {"testhost", "codex"} => [
              %{
                family: cross_harness.family,
                context: nil,
                efforts: ["medium"],
                provider: :openai
              }
            ]
          })

        {:ok, fixture_adapter} =
          RingDownAdapter.start_link(
            parent: self(),
            outcomes: %{first.family => {:error, :model_unavailable}},
            readback: %{}
          )

        rate_limit = %{"data" => %{"codexErrorInfo" => "usageLimitExceeded"}}

        {:ok, codex_adapter} =
          RingDownAdapter.start_link(
            parent: self(),
            outcomes: %{cross_harness.family => {:ok, "cross-harness-health-session"}},
            prompt_outcome: {:error, rate_limit},
            readback: %{}
          )

        coordinator = fn
          {:fixture, "shared", "testhost"} -> {:ok, fixture_adapter, 1}
          {:codex, "shared", "testhost"} -> {:ok, codex_adapter, 2}
        end

        {:ok, _coordinator} = CoordinatorStub.start_link({coordinator, self()})
        config = Map.put(config, :model_catalog, catalog)

        Org.create(db, %{
          session_key: session_key,
          display_name: "Synthetic cross-harness health failure",
          owner_user_id: "synthetic-owner",
          origin: "user:synthetic-owner",
          archetype: "synthetic-ring",
          host: "testhost",
          harness: "fixture",
          provider: "fixture_provider",
          model: first
        })

        assert :appended =
                 Gateway.deliver_prompt(session_key, "user:synthetic-owner", "health failure",
                   db: db,
                   lane_manager: lane,
                   conn_registry: ConnRegistry,
                   client_message_id: "ring-cross-harness-health-failure-client"
                 )

        assert {:ok, turn} = Ledger.claim_next(db, session_key, "ring-test")

        assert {:error, %{record_in_txn: record_in_txn, terminal_publish: publish}} =
                 runner(config).(Map.put(turn, :session_key, session_key))

        assert_receive {:adapter_key, {:fixture, "shared", "testhost"}}
        assert_receive {:adapter_key, {:codex, "shared", "testhost"}}
        assert_receive {:model_attempt, ^first}
        assert_receive {:model_attempt, ^cross_harness}

        assert {:ok, publication} =
                 DB.transaction(db, fn txn ->
                   assert true =
                            Ledger.finish_in_txn(
                              txn,
                              turn.seq,
                              "failed",
                              "synthetic rate limit",
                              owner_lease: turn.owner_lease
                            )

                   record_in_txn.(txn)
                 end)

        if is_function(publication, 0), do: publication.()
        publish.("failed")

        assert {:ok, [["codex", "testhost"]]} =
                 DB.query(
                   db,
                   "SELECT harness,host FROM harness_health_observations WHERE correlationId=?1",
                   ["harness-turn:#{turn.seq}:rate-limit-dead"]
                 )

        assert {:ok, []} =
                 DB.query(
                   db,
                   "SELECT harness,host FROM harness_health_observations WHERE correlationId=?1 AND harness=?2",
                   ["harness-turn:#{turn.seq}:rate-limit-dead", "fixture"]
                 )
      end,
      preferences
    )
  end

  test "turn advances through production model and effort carriers and preserves evidence" do
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

        assert :model_unavailable == ErrorDiagnostic.classified(not_selectable_reason)
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

        assert {:ok, %{terminal_publish: publish}} =
                 runner.(Map.put(turn, :session_key, session_key))

        assert_receive {:model_attempt, ^not_selectable}
        assert_receive {:model_attempt, ^unsupported_effort}
        assert_receive {:model_attempt, ^selected}
        refute_receive {:model_attempt, _}
        assert Org.get(db, session_key).model == selected

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

        assert :ok = Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

        publish.("delivered")
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

  test "turn advances through recorded invalid-params effort carrier" do
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

        assert {:ok, %{terminal_publish: publish}} =
                 runner.(Map.put(turn, :session_key, session_key))

        assert_receive {:model_attempt, ^effort_model}
        assert_receive {:model_attempt, ^selected}
        refute_receive {:model_attempt, _}
        assert Org.get(db, session_key).model == selected

        details =
          EventLog.lifecycle_events(db)
          |> Enum.filter(&(&1.kind == "model_selection_attempt"))
          |> Enum.map(& &1.detail)
          |> Enum.join("\n")

        assert details =~ "Invalid params"
        assert details =~ "effort"
        assert details =~ "original_reason"
        assert details =~ "diagnostic"

        assert :ok = Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

        publish.("delivered")
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

  test "spawn skips an unavailable named preference and uses the next routed entry" do
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
                     display_name: "Skip unavailable preference",
                     idempotency_key: "skip-unavailable-preference"
                   }
                 })

        assert %Model{family: "synthetic-available"} = Org.get(db, session_key).model
      end,
      preferences
    )
  end

  test "spawn exhaustion names every configured unavailable preference" do
    preferences = [
      {"synthetic-missing-one", "low", nil},
      {"synthetic-missing-two", "high", nil}
    ]

    with_gateway(
      fn %{config: config} ->
        {:ok, catalog} = CatalogStub.start_link(%{})
        spawn = Gateway.handlers(Map.put(config, :model_catalog, catalog))["spawn"]

        assert %{code: "config_denied", message: message} =
                 spawn.(%{
                   origin: "user:synthetic-owner",
                   session_key: nil,
                   params: %{
                     archetype: "synthetic-ring",
                     display_name: "Exhausted preferences",
                     idempotency_key: "exhausted-preferences"
                   }
                 })

        assert message =~ "synthetic-missing-one"
        assert message =~ "synthetic-missing-two"
        assert message =~ "no configured model preference can run"
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
          Enum.map(preferences, fn {family, effort, context} ->
            %{family: family, context: context, efforts: [effort], provider: :fixture_provider}
          end)
      })

    Application.put_env(:tightbeam, :base_dir, base)
    Application.put_env(:tightbeam, :autostart, false)
    Application.put_env(:tightbeam, :local_host_name, "testhost")

    _registry = start_supervised!({ConnRegistry, name: ConnRegistry}, id: :model_ring_registry)
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
      Enum.map_join(preferences, <<10>>, fn {family, effort, context} ->
        context_line =
          if is_binary(context), do: "context = " <> inspect(context) <> <<10>>, else: ""

        """
        [[model_preferences]]
        model = "#{family}"
        effort = "#{effort}"
        #{context_line}
        """
      end)

    File.write!(path, """
    name = "synthetic-ring"
    where = ["testhost"]

    #{entries}
    """)
  end

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
