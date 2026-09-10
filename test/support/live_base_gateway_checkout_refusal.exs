defmodule GuardCheckoutDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

defmodule GuardCheckoutRefusal do
  import ExUnit.Assertions

  alias Tightbeam.{
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    Ledger,
    Model,
    ModelCatalog,
    Org,
    Projection
  }

  alias Tightbeam.GatewayTurnFixture.CoordinatorStub

  def run do
    Tightbeam.GuardGatewayFixture.run!(fn %{base: base, db: db, config: config} ->
      mode = Path.join(Path.dirname(base), "checkout-case.txt") |> File.read!()
      assert mode in ["missing", "fresh", "transient", "cursor"]

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

      {:ok, lane} = GenServer.start_link(GuardCheckoutDoorbell, self())
      # Checkout refuses before any adapter exists. No engine can receive a request.
      checkout =
        if mode == "cursor" do
          refusal = %{
            code: "DIV-CURSOR-API-KEY-ONLY",
            message: "Cursor requires a banked API key"
          }

          fn _key -> {:error, {:launch_refused, refusal}} end
        else
          fn _key -> {:error, :degraded} end
        end

      {:ok, coordinator} = CoordinatorStub.start_link({checkout, self()})

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

        for device <- [
              Map.fetch!(
                %{
                  "missing" => "o6-refuse",
                  "fresh" => "o6-pbu",
                  "transient" => "o6-transient",
                  "cursor" => "cursor-refusal-wire"
                },
                mode
              )
            ] do
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
        prove(mode, db, lane, exact_registry, runner)
        refute_received {:new_session_mcp_servers, _}
        refute_received {:prompt_started, _}
      after
        GenServer.stop(catalog)
        GenServer.stop(coordinator)
        GenServer.stop(lane)
      end
    end)
  end

  defp prove("cursor", db, lane, exact_registry, runner) do
    refusal = %{
      code: "DIV-CURSOR-API-KEY-ONLY",
      message: "Cursor requires a banked API key"
    }

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "cursor refusal",
               db: db,
               conn_registry: exact_registry,
               lane_manager: lane,
               device_id: "cursor-refusal-wire",
               client_message_id: "c_cursor_refusal"
             )

    assert_receive {:ensure_lane, "k1"}
    assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")

    assert {:error, %{reason: ^refusal, terminal_publish: publish}} =
             runner.(Map.put(turn, :session_key, "k1"))

    publish.("failed")

    assert_receive {:push,
                    %{
                      "event" => "prompt_turn_state",
                      "payload" => %{
                        "state" => "failed",
                        "error" => %{
                          code: "DIV-CURSOR-API-KEY-ONLY",
                          message: "Cursor requires a banked API key"
                        }
                      }
                    }},
                   2_000

    IO.puts("guarded-gateway-cursor-refusal: ok")
  end

  defp prove("missing", db, lane, exact_registry, runner) do
    # testhost/claude has NO credential: the catalog affirmatively answers "missing"
    # (`:missing`, not the `:credential_server_unavailable` transient — see the guard test).
    degrade_host_catalog("testhost", "claude", {:needs_onboarding, :missing})

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "hi",
               db: db,
               conn_registry: exact_registry,
               lane_manager: lane,
               device_id: "o6-refuse",
               client_message_id: "c_o6_refuse"
             )

    assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")

    # FAILS (not parks): the runner returns an error with a terminal publish + record,
    # never a hold/episode/queue.
    assert {:error, %{reason: reason, terminal_publish: publish, record_in_txn: record}} =
             runner.(Map.put(turn, :session_key, "k1"))

    # TELLS: the EXACT remedy, on the host, naming the provider — NOT the raw
    # "adapter is degraded" checkout fault (that fault is kept in the record instead).
    assert reason =~ "tightbeam onboard anthropic --as-user <userId>"
    assert reason =~ "on testhost"
    refute reason =~ "is degraded"

    # RECORDS: the failed row and the lifecycle event, one transaction. The record keeps
    # the STAGE (:checkout — pre-engine) and the raw fault the user-facing sentence flattened.
    assert {:ok, true} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", reason)
               record.(txn)
               true
             end)

    publish.("failed")

    lifecycle =
      Enum.find(EventLog.lifecycle_events(db), fn event ->
        event.kind == "harness_turn_error" and event.subject == "k1"
      end)

    assert lifecycle, "the refusal must record a harness_turn_error lifecycle event"
    assert lifecycle.detail =~ "checkout"

    # TELLS (chat channel): the remedy reaches the user durably as the `[turn failed]`
    # marker, read from the projection rather than a brittle push count.
    marker =
      db
      |> Projection.list_after("k1", nil, 100)
      |> Enum.find(&String.starts_with?(&1.content || "", "[turn failed]"))

    assert marker, "a refused turn must speak its reason in chat"
    assert marker.content =~ "tightbeam onboard anthropic --as-user <userId>"

    # NEVER LAUNCHES A DEAD ENGINE: checkout failed pre-engine, so the session/prompt
    # stages never ran — no engine was asked to serve (belt-and-suspenders to the
    # :checkout stage recorded above).
    refute_received {:new_session_mcp_servers, _}
    refute_received {:prompt_started, _}
  end

  defp prove("fresh", db, lane, exact_registry, runner) do
    # The synthetic catalog reports FRESH; only checkout is broken.
    # No credential bytes are read or created.
    assert {_entries, :fresh} = ModelCatalog.get("testhost", "claude", ModelCatalog)

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "hi",
               db: db,
               conn_registry: exact_registry,
               lane_manager: lane,
               device_id: "o6-pbu",
               client_message_id: "c_o6_pbu"
             )

    assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")

    assert {:error, %{reason: reason}} = runner.(Map.put(turn, :session_key, "k1"))

    # The refusal names the REAL gap (executability/adapter degraded), never the
    # onboarding remedy — the credential is present, so "run onboard" would be false.
    assert reason =~ "is degraded"
    refute reason =~ "tightbeam onboard"
    refute reason =~ "--as-user"
  end

  defp prove("transient", db, lane, exact_registry, runner) do
    # The transient: "could not ASK" (credential server unreachable), NOT an affirmative
    # "absent". Health becomes {:unavailable, {:needs_onboarding, :credential_server_unavailable}},
    # which is NOT :missing, so unonboarded_refusal returns :not_applicable.
    degrade_host_catalog(
      "testhost",
      "claude",
      {:needs_onboarding, :credential_server_unavailable}
    )

    assert :appended =
             Gateway.deliver_prompt("k1", "user:flynn", "hi",
               db: db,
               conn_registry: exact_registry,
               lane_manager: lane,
               device_id: "o6-transient",
               client_message_id: "c_o6_transient"
             )

    assert {:ok, turn} = Ledger.claim_next(db, "k1", "test")

    assert {:error, %{reason: reason}} = runner.(Map.put(turn, :session_key, "k1"))

    # Refused by its real (executability/adapter) gap, never the onboarding remedy —
    # a "could not ask" transient is not a "you have no credential" verdict.
    assert reason =~ "is degraded"
    refute reason =~ "tightbeam onboard"
    refute reason =~ "--as-user"
  end

  defp degrade_host_catalog(host, harness, reason) do
    :sys.replace_state(ModelCatalog, fn state ->
      put_in(state.entries[{host, harness}], %{
        entries: [],
        derived_at: nil,
        attempted_at: state.now.(),
        reason: reason,
        refreshing: true
      })
    end)
  end
end

GuardCheckoutRefusal.run()
IO.puts("guarded-gateway-checkout-refusal: ok")
