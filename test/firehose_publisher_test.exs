defmodule Tightbeam.Firehose.PublisherTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, DB, Dispatch, Gateway, Ledger, Org, Rules, Wakes}
  alias Tightbeam.Firehose.{Hub, Publisher}

  defmodule LaneStub do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

    def init(:ok), do: {:ok, :ok}
    def handle_call({:ensure_lane, _session_key}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    :persistent_term.erase(Rules)
    start_supervised!({Hub, name: Hub})
    :ok = Hub.register(Hub, self())
    on_exit(fn -> :persistent_term.erase(Rules) end)
    :ok
  end

  test "work-item-create emits its committed routing wake once, never on keyed replay" do
    db = :firehose_work_item_create_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users VALUES ('flynn', 1, 1)")
    register_testhost(db)

    handlers = Gateway.handlers(%{db: db})

    call = %{
      verb: "work-item-create",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{title: "Route this", idempotency_key: "firehose-create"}
    }

    assert {:ok, item} = Dispatch.dispatch(db, handlers, call)

    assert %{
             "class" => "wake.scheduled",
             "refs" => %{"wakeId" => wake_id, "workItemId" => work_item_id}
           } = receive_notice()

    assert work_item_id == item.id
    assert Wakes.get(db, wake_id).work_item_id == item.id
    assert %{"class" => "verb.accepted"} = receive_notice()
    assert %{"class" => "work_item.created"} = receive_notice()

    declared = Gateway.handler_effects(%{db: db})["work-item-create"]
    observed = ["wake.scheduled", "work_item.created"]
    assert_effects_match!(declared, observed)

    assert_raise ArgumentError, ~r/missing=\["wake.scheduled"\]/, fn ->
      assert_effects_match!(List.delete(declared, "wake.scheduled"), observed)
    end

    assert {:ok, replay} = Dispatch.dispatch(db, handlers, call)
    assert replay.id == item.id
    assert %{"class" => "verb.accepted"} = receive_notice()
    assert %{"class" => "work_item.created"} = receive_notice()
    refute_receive {:firehose_notice, %{"class" => "wake.scheduled"}}
  end

  test "post declares the message effect its committed delivery actually emits" do
    db = :firehose_post_effect_db
    registry = :firehose_post_effect_registry
    lane = :firehose_post_effect_lane
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users VALUES ('flynn', 1, 1)")
    register_testhost(db)
    start_supervised!({ConnRegistry, name: registry})
    start_supervised!({LaneStub, name: lane})

    Org.create(db, %{
      session_key: "post-target",
      display_name: "Post target",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })

    assert :appended =
             Gateway.deliver_prompt(
               "post-target",
               "user:flynn",
               "exact A1 post reproduction",
               db: db,
               conn_registry: registry,
               lane_manager: lane,
               sender: "user:flynn",
               device_id: "device-1",
               client_message_id: "client-message-1",
               authenticated_device_message: true
             )

    assert %{
             "class" => "message.created",
             "payload" => %{"content" => "exact A1 post reproduction"}
           } = receive_notice()

    declared = Gateway.handler_effects(%{db: db})["post"]
    observed = ["message.created"]
    assert_effects_match!(declared, observed)

    assert_raise ArgumentError, ~r/missing=\["message.created"\]/, fn ->
      assert_effects_match!([], observed)
    end
  end

  test "per-verb effects match real wake, condition, dispatch, and attest outcomes" do
    db = :firehose_per_verb_effect_db
    scheduler = :firehose_per_verb_effect_scheduler
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users VALUES ('flynn', 1, 1)")
    register_testhost(db)
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneStub, name: Tightbeam.LaneManager})

    Org.create(db, %{
      session_key: "effect-target",
      display_name: "Effect target",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })

    Org.create(db, %{
      session_key: "effect-dispatcher",
      display_name: "Effect dispatcher",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake ->
         Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
           db: db,
           wake_id: wake.wake_id,
           sender: wake.origin,
           target_gate: wake
         )
       end}
    )

    config = %{
      db: db,
      wake_scheduler: scheduler,
      wake_tick_ms: 1_000,
      effort_checkin_horizon_ms: 60_000,
      base_dir: System.tmp_dir!()
    }

    handlers = Gateway.handlers(config)

    immediate_wake = %{
      verb: "wake",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: "effect-target",
      params: %{prompt: "immediate effect", after_ms: 0, idempotency_key: "effect-immediate"}
    }

    assert {:ok, %{wake_id: immediate_id}} = Dispatch.dispatch(db, handlers, immediate_wake)
    assert %{state: "fired"} = Wakes.get(db, immediate_id)
    wake_observed = observed_state_classes()

    pending =
      Wakes.schedule(db, %{
        session_key: "effect-target",
        origin: "user:flynn",
        prompt: "cancel effect",
        due_at: System.system_time(:millisecond) + 60_000
      })

    cancel_wake = %{
      verb: "wake",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{cancel_wake_id: pending.wake_id}
    }

    assert {:ok, %{canceled: true}} = Dispatch.dispatch(db, handlers, cancel_wake)

    assert_per_verb_effects!(
      config,
      "wake",
      wake_observed ++ observed_state_classes()
    )

    cancel_miss = put_in(cancel_wake, [:params, :cancel_wake_id], "w_missing_effect")
    assert {:ok, %{canceled: false}} = Dispatch.dispatch(db, handlers, cancel_miss)
    assert observed_classes() == ["verb.accepted"]

    _condition_wake =
      Wakes.schedule(db, %{
        session_key: "effect-target",
        origin: "user:flynn",
        prompt: "condition effect",
        due_at: System.system_time(:millisecond) + 60_000,
        condition_kind: "effect-ready",
        condition_scope: "matrix"
      })

    condition = %{
      verb: "condition",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{kind: "effect-ready", scope: "matrix", idempotency_key: "effect-fact"}
    }

    assert {:ok, %{kind: "effect-ready"}} = Dispatch.dispatch(db, handlers, condition)
    assert_per_verb_effects!(config, "condition", observed_state_classes())

    dispatch = %{
      verb: "dispatch",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: "effect-target",
      target_role: nil,
      role_fallback: false,
      params: %{subject: "Effect dispatch", brief: "Exercise every dispatch effect."}
    }

    assert {:ok, assignment} = Dispatch.dispatch(db, handlers, dispatch)
    dispatch_observed = observed_state_classes()

    work_item_create = %{
      verb: "work-item-create",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{title: "Exercise the rumination dispatch effect"}
    }

    assert {:ok, work_item} = Dispatch.dispatch(db, handlers, work_item_create)
    _ = observed_classes()

    rumination_dispatch = %{
      verb: "dispatch",
      origin: "agent:effect-dispatcher",
      principal: {:session, "effect-dispatcher"},
      session_key: "effect-target",
      target_role: nil,
      role_fallback: false,
      params: %{
        subject: "Effect rumination dispatch",
        brief: "Exercise the committed internal wake path.",
        work_item_id: work_item.id
      }
    }

    assert {:ok, %{rumination_required: true, work_item_id: work_item_id}} =
             Dispatch.dispatch(db, handlers, rumination_dispatch)

    assert work_item_id == work_item.id
    rumination_classes = observed_classes()
    assert rumination_classes == ["verb.accepted", "wake.scheduled"]

    assert_per_verb_effects!(
      config,
      "dispatch",
      dispatch_observed ++ state_classes(rumination_classes)
    )

    tests_passed = %{
      verb: "attest",
      origin: "agent:effect-target",
      principal: {:session, "effect-target"},
      session_key: nil,
      params: %{
        assignment_id: assignment.id,
        kind: "verdict",
        verdict_kind: "tests-passed",
        note: "effect matrix tests passed"
      }
    }

    assert {:ok, %{attest: %{verdictKind: "tests-passed"}}} =
             Dispatch.dispatch(db, handlers, tests_passed)

    completion = %{
      verb: "attest",
      origin: "agent:effect-target",
      principal: {:session, "effect-target"},
      session_key: nil,
      params: %{assignment_id: assignment.id, kind: "completion", note: "effect matrix complete"}
    }

    assert {:ok, %{assignment: %{state: "closed", outcome: "completed"}}} =
             Dispatch.dispatch(db, handlers, completion)

    assert_per_verb_effects!(config, "attest", observed_state_classes())
  end

  test "a raised state handler emits denied and never accepted state effects" do
    db = :firehose_raised_handler_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    call = %{
      verb: "work-item-create",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{title: "Will raise"}
    }

    assert {:error, %{code: "server_error", message: "review boom"}} =
             Dispatch.dispatch(db, %{"work-item-create" => fn _ -> raise "review boom" end}, call)

    assert %{
             "class" => "verb.denied",
             "payload" => %{"code" => "server_error", "verb" => "work-item-create"}
           } = receive_notice()

    _ = :sys.get_state(Hub)

    refute_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    refute_receive {:firehose_notice, %{"class" => "work_item.created"}}
  end

  test "an accepted state verb emits its observation and canonical state notice" do
    call = %{
      verb: "work-item-update",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{work_item_id: "wi_1"}
    }

    result = %{
      id: "wi_1",
      title: "Firehose",
      owner_user_id: "flynn",
      updated_at: 123,
      cli_token: "must-not-leak"
    }

    assert :ok = Publisher.accepted(call, result)

    assert %{"class" => "verb.accepted", "op" => "observe", "refs" => refs} =
             receive_notice()

    assert refs["origin"] == "user:flynn"

    assert %{
             "class" => "work_item.updated",
             "resource" => "work-items",
             "op" => "upsert",
             "refs" => %{"workItemId" => "wi_1"},
             "payload" => payload
           } = receive_notice()

    assert payload["id"] == "wi_1"
    assert payload["rowVersion"] == 123
    refute Map.has_key?(payload, "cliToken")
  end

  test "unmapped reads emit only the observational verb notice" do
    assert :ok =
             Publisher.accepted(
               %{verb: "assignments", origin: "user:flynn", params: %{}},
               %{assignments: []}
             )

    assert %{"class" => "verb.accepted"} = receive_notice()
    refute_receive {:firehose_notice, _notice}
  end

  test "a committed row uses the registry serializer and primary ref" do
    assert :ok =
             Publisher.committed(
               "message.created",
               %{id: "s_1", seq: 9, session_key: "agent:one", content: "hello"},
               %{"ownerUserId" => "flynn", "sessionKey" => "agent:one"}
             )

    assert %{
             "class" => "message.created",
             "refs" => %{"messageId" => "s_1"},
             "payload" => %{"id" => "s_1", "rowVersion" => 9}
           } = ordinary_notice = receive_notice()

    refute Map.has_key?(ordinary_notice["payload"], "displayLabel")

    assert :ok =
             Publisher.committed(
               "message.created",
               %{
                 id: "s_marker",
                 seq: 10,
                 session_key: "agent:one",
                 role: "assistant",
                 sender: "process:tightbeam",
                 content: "[adapter down]\n\nThe engine stopped."
               },
               %{"ownerUserId" => "flynn", "sessionKey" => "agent:one"}
             )

    assert %{
             "class" => "message.created",
             "payload" => %{"id" => "s_marker", "displayLabel" => "[marker]"}
           } = receive_notice()
  end

  test "return emits the ruled decision_request.returned class" do
    db = :firehose_decision_returned_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users VALUES ('flynn', 1, 1)")
    register_testhost(db)

    Enum.each(["return-asker", "return-reader"], fn session_key ->
      Org.create(db, %{
        session_key: session_key,
        display_name: session_key,
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Tightbeam.Model.new("fable")
      })
    end)

    handlers = Gateway.handlers(%{db: db})

    ask = %{
      verb: "ask",
      origin: "agent:return-asker",
      principal: {:session, "return-asker"},
      session_key: "return-reader",
      params: %{question: "Which authority applies?"}
    }

    assert {:ok, %{decision_request: request}} = Dispatch.dispatch(db, handlers, ask)
    _ = observed_classes()

    returned = %{
      verb: "return",
      origin: "agent:return-reader",
      principal: {:session, "return-reader"},
      session_key: nil,
      params: %{request: request.id, reason: "The governing authority is absent."}
    }

    assert {:ok, %{decision_request: %{status: "returned"}}} =
             Dispatch.dispatch(db, handlers, returned)

    assert "decision_request.returned" in observed_state_classes()

    assert {:ok, %{decision_request: %{status: "returned"}}} =
             Dispatch.dispatch(db, handlers, returned)

    assert observed_classes() == ["verb.accepted"]
    assert Gateway.handler_effects(%{db: db})["return"] == ["decision_request.returned"]
  end

  test "ledger transitions hand off turn notices only after their commits" do
    db = :firehose_turn_transition_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users VALUES ('flynn', 1, 1)")
    register_testhost(db)

    Org.create(db, %{
      session_key: "turn-target",
      display_name: "Turn target",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })

    assert {:ok, seq} =
             Ledger.enqueue(db, %{
               session_key: "turn-target",
               message_id: "turn-message",
               origin: "user:flynn",
               prompt: "run"
             })

    assert {:ok, %{seq: ^seq, owner_lease: owner_lease}} =
             Ledger.claim_next(db, "turn-target", "lane:test")

    assert %{
             "class" => "turn.started",
             "payload" => %{"status" => "running", "turnSeq" => ^seq}
           } = receive_notice()

    assert :ok = Ledger.finish(db, seq, "delivered", nil, owner_lease: owner_lease)

    assert %{
             "class" => "turn.ended",
             "payload" => %{"status" => "delivered", "turnSeq" => ^seq}
           } = receive_notice()
  end

  test "concurrent transaction handoffs reach the firehose in database commit order" do
    db = :firehose_commit_order_db
    parent = self()
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = DB.execute(db, "CREATE TABLE committed_messages (id TEXT PRIMARY KEY, body TEXT)")

    first =
      Task.async(fn ->
        DB.transaction(db, fn txn ->
          DB.Txn.q(txn, "INSERT INTO committed_messages VALUES ('first', 'one')")

          Publisher.committed_in_txn(
            txn,
            "message.created",
            %{id: "first", seq: 1, session_key: "agent:first", content: "one"},
            %{"sessionKey" => "agent:first"}
          )

          send(parent, :first_commit_held)

          receive do
            :release_first_commit -> :ok
          end
        end)
      end)

    assert_receive :first_commit_held
    db_pid = Process.whereis(db)
    :erlang.trace(db_pid, true, [:receive])

    second =
      Task.async(fn ->
        DB.transaction(db, fn txn ->
          DB.Txn.q(txn, "INSERT INTO committed_messages VALUES ('second', 'two')")

          Publisher.committed_in_txn(
            txn,
            "message.created",
            %{id: "second", seq: 2, session_key: "agent:second", content: "two"},
            %{"sessionKey" => "agent:second"}
          )
        end)
      end)

    assert_receive {:trace, ^db_pid, :receive, {:"$gen_call", _from, {:transaction, _fun}}}
    :erlang.trace(db_pid, false, [:receive])
    send(db_pid, :release_first_commit)

    assert {:ok, :ok} = Task.await(first)
    assert {:ok, :ok} = Task.await(second)

    assert %{"class" => "message.created", "payload" => %{"id" => "first"}} =
             receive_notice()

    assert %{"class" => "message.created", "payload" => %{"id" => "second"}} =
             receive_notice()
  end

  test "a rolled-back transaction emits no firehose notice" do
    db = :firehose_rollback_db
    start_supervised!({DB, path: ":memory:", name: db})

    assert {:error, %RuntimeError{message: "forced rollback"}} =
             DB.transaction(db, fn txn ->
               Publisher.committed_in_txn(
                 txn,
                 "message.created",
                 %{id: "rolled-back", seq: 1, session_key: "agent:none", content: "none"},
                 %{"sessionKey" => "agent:none"}
               )

               raise "forced rollback"
             end)

    _ = :sys.get_state(Hub)
    refute_receive {:firehose_notice, %{"payload" => %{"id" => "rolled-back"}}}
  end

  test "a role delete carries its last visible pre-delete row" do
    db = :firehose_role_delete_db
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = Tightbeam.DB.query(db, "INSERT INTO users VALUES ('flynn', 1, 1)")
    %{name: "worker"} = Tightbeam.Roles.create!(db, "worker", "flynn", nil)

    call = %{
      verb: "role-rm",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      params: %{name: "worker"}
    }

    captured = Publisher.capture_before(db, call)
    :ok = Tightbeam.Roles.rm(db, "worker")
    :ok = Publisher.accepted(db, captured, %{removed: "worker"})

    assert %{"class" => "verb.accepted"} = receive_notice()

    assert %{
             "class" => "role.removed",
             "op" => "delete",
             "refs" => %{"role" => "worker"},
             "payload" => %{"role" => "worker", "ownerUserId" => "flynn"}
           } = receive_notice()
  end

  test "a rail denial emits both observational classes" do
    call = %{
      verb: "attest",
      origin: "agent:worker",
      principal: {:session, "agent:worker"},
      session_key: "agent:worker",
      params: %{}
    }

    :ok = Publisher.denied(call, %{code: "rule_denied", rule: "tests-before-success"})

    assert %{"class" => "verb.denied"} = receive_notice()

    assert %{
             "class" => "rail.denied",
             "payload" => %{"rule" => "tests-before-success", "verb" => "attest"}
           } = receive_notice()
  end

  test "condition and critical projections carry stable ids and last-version-wins" do
    older_fact = Tightbeam.StateResources.condition_fact(%{fact_id: 4, ts: 100, kind: "ready"})
    newer_fact = Tightbeam.StateResources.condition_fact(%{fact_id: 5, ts: 90, kind: "ready"})
    assert older_fact["factId"] == older_fact["rowVersion"]
    assert newer_fact["factId"] == newer_fact["rowVersion"]
    assert lww(older_fact, newer_fact) == newer_fact
    assert lww(newer_fact, older_fact) == newer_fact
    assert lww(newer_fact, newer_fact) == newer_fact

    older_lease =
      Tightbeam.StateResources.critical_state(%{session_key: "agent:one", updated_at: 10})

    newer_lease =
      Tightbeam.StateResources.critical_state(%{session_key: "agent:one", updated_at: 11})

    assert lww(older_lease, newer_lease) == newer_lease
    assert lww(newer_lease, older_lease) == newer_lease
    assert lww(newer_lease, newer_lease) == newer_lease
  end

  defp lww(current, candidate) do
    if candidate["rowVersion"] >= current["rowVersion"], do: candidate, else: current
  end

  defp assert_effects_match!(declared, observed) do
    extra = declared -- observed
    missing = observed -- declared

    if extra != [] or missing != [] do
      raise ArgumentError,
            "handler effect mismatch: extra=#{inspect(extra)} missing=#{inspect(missing)}"
    end

    :ok
  end

  defp assert_per_verb_effects!(config, verb, observed) do
    declared = Gateway.handler_effects(config)[verb]
    observed = observed |> Enum.uniq() |> Enum.sort()
    assert_effects_match!(declared, observed)

    for effect <- declared do
      error =
        assert_raise ArgumentError, fn ->
          assert_effects_match!(List.delete(declared, effect), observed)
        end

      assert Exception.message(error) =~ effect
    end
  end

  defp observed_classes(acc \\ []) do
    _ = :sys.get_state(Hub)

    receive do
      {:firehose_notice, %{"class" => class}} ->
        Hub.delivered(Hub, self())
        observed_classes([class | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp observed_state_classes do
    observed_classes()
    |> state_classes()
  end

  defp state_classes(classes) do
    Enum.filter(classes, &match?({:ok, _row}, Tightbeam.Firehose.Registry.fetch(&1)))
  end

  defp register_testhost(db) do
    register_hosts(db, %{
      "testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}
    })

    Org.create(db, %{
      session_key: Org.personal_session_key("flynn"),
      display_name: "Main",
      kind: "main",
      is_built_in: true,
      adopted: true,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })
  end

  defp receive_notice do
    assert_receive {:firehose_notice, notice}
    Hub.delivered(Hub, self())
    notice
  end
end
