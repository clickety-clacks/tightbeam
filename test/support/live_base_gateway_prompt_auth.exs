defmodule GuardPromptAuthDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardPromptAuth do
  import ExUnit.Assertions

  alias Tightbeam.{
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    HarnessHealth,
    Ledger,
    Model,
    ModelCatalog,
    Org,
    Projection
  }

  alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{base: base, db: db, config: config} ->
      Org.create(db, %{
        session_key: "k1",
        display_name: "Main",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

      {:ok, lane} = GenServer.start_link(GuardPromptAuthDoorbell, self())
      # Existing synthetic adapter reaches session and returns the captured prompt auth error.
      {:ok, adapter} = AdapterStub.start_link(self())
      {:ok, coordinator} = CoordinatorStub.start_link({adapter, self()})

      {:ok, catalog} =
        ModelCatalog.start_link(
          base_dir: base,
          db: db,
          hosts: fn -> %{} end,
          credential_status: fn _ -> flunk("unexpected credential probe") end,
          credential_kind: fn _ -> flunk("unexpected credential-kind probe") end,
          sh: fn _ -> flunk("unexpected catalog shell") end,
          claude_fetch: fn _, _ -> flunk("unexpected catalog fetch") end
        )

      try do
        # Synthetic catalog truth only; no credentials or provider are consulted.
        :sys.replace_state(catalog, fn state ->
          now = state.now.()

          cache = %{
            entries: [
              %{
                family: "claude-fable-5",
                context: nil,
                display_name: "Claude Fable 5",
                name: "Claude Fable 5",
                efforts: [],
                max_input_tokens: 200_000,
                capabilities: %{},
                provider: :anthropic
              }
            ],
            derived_at: now,
            attempted_at: now,
            reason: nil,
            refreshing: true
          }

          %{
            state
            | hosts: fn -> %{"testhost" => %{base_dir: base, ssh: nil}} end,
              entries: %{{"testhost", "claude"} => cache}
          }
        end)

        exact_registry = Tightbeam.ConnRegistry

        for device <- ["o6-prompt401"] do
          {:ok, _ref, nil} =
            ConnRegistry.register(exact_registry, %{
              pid: self(),
              user_id: "flynn",
              device_id: device,
              is_admin: false,
              subscriptions: MapSet.new(["chat"])
            })
        end

        config = %{
          config
          | default_harness: :claude,
            default_model: Model.new("claude-fable-5"),
            port: 0
        }

        {Tightbeam.LaneManager, lane_opts} =
          Gateway.children(config) |> Enum.find(&match?({Tightbeam.LaneManager, _}, &1))

        runner = Keyword.fetch!(lane_opts, :runner)
        prove(db, lane, exact_registry, runner)
      after
        GenServer.stop(catalog)
        GenServer.stop(coordinator)
        GenServer.stop(adapter)
        GenServer.stop(lane)
      end
    end)
  end

  defp prove(db, lane, exact_registry, runner) do
    # Incident-faithful: catalog LEFT FRESH — real expiry is storage-blind, so health gives
    # NO signal. The only signal is the :prompt auth-fault shape.
    assert {_entries, :fresh} = ModelCatalog.get("testhost", "claude", ModelCatalog)

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "fail this turn",
               db: db,
               conn_registry: exact_registry,
               lane_manager: lane,
               device_id: "o6-prompt401",
               client_message_id: "c_o6_prompt401"
             )

    assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")

    assert {:error, %{reason: _reason, terminal_publish: publish, record_in_txn: record}} =
             runner.(Map.put(turn, :session_key, "k1"))

    # It genuinely failed at :prompt — checkout + session succeeded (the incident path, not a
    # pre-engine refusal). The record keeps the stage.
    # reason is the raw ACP map here (health :fresh -> :not_applicable, no reclassify); the lane
    # stringifies it via error_text before the ledger, and the OPERATOR-facing marker flattens
    # it via error_sentence (asserted below). Finish with a stand-in string, as SessionLane's
    # error_text would produce one.
    assert {:ok, true} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", "prompt auth 401")
               record.(txn)
               true
             end)

    publish.("failed")

    lifecycle =
      Enum.find(EventLog.lifecycle_events(db), fn event ->
        event.kind == "harness_turn_error" and event.subject == "k1"
      end)

    assert lifecycle, "the :prompt turn failure must record a harness_turn_error"
    assert lifecycle.detail =~ "prompt"

    assert HarnessHealth.active(db) == []

    assert {:ok, [["auth-dead", "terminal-failure", "k1", cause]]} =
             DB.query(
               db,
               """
               SELECT failureClass,evidenceKind,sessionKey,cause
               FROM harness_health_observations
               WHERE correlationId=?1
               """,
               ["harness-turn:#{turn.seq}:auth-dead"]
             )

    assert cause =~ "stage=prompt"
    assert cause =~ "auth expired"

    # G3: the operator reads the human message/details as PROSE, never a raw inspected ACP
    # error map. The auth detail survives as text; the map's inspect markers (`=>`, `%{`) do
    # NOT. (The precise re-onboard NAMING for this health-blind :prompt 401 is the held
    # option-a piece, pending the PO's a-vs-b ruling; the common path guarantees only that no
    # raw map reaches chat.)
    marker =
      db
      |> Projection.list_after("k1", nil, 100)
      |> Enum.find(&String.starts_with?(&1.content || "", "[turn failed]"))

    assert marker, "a :prompt failure must speak in chat"
    assert marker.content =~ "auth expired"
    refute marker.content =~ "=>"
    refute marker.content =~ "%{"
  end
end

GuardPromptAuth.run()
IO.puts("guarded-gateway-prompt-auth: ok")
