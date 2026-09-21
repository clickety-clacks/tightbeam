defmodule Tightbeam.Firehose.PublisherTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, DB, Dispatch, Gateway, Ledger, Org, Wakes}
  alias Tightbeam.Firehose.{Hub, Publisher}

  defmodule LaneStub do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

    def init(:ok), do: {:ok, :ok}
    def handle_call({:ensure_lane, _session_key}, _from, state), do: {:reply, :ok, state}
    def handle_call({:fire_matching, _fact_id}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    start_supervised!({Hub, name: Hub})
    :ok = Hub.register(Hub, self(), %{mode: :all, user_id: "flynn", is_admin: true})
    :ok
  end

  test "Gateway winning fire publishes once and rollback or caller ownership excludes it" do
    db = :firehose_gateway_winning_fire_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',1,1)")
    register_testhost(db)
    target = Org.personal_session_key("flynn")

    wake =
      Wakes.schedule(db, %{
        session_key: target,
        origin: "process:tightbeam",
        prompt: "synthetic winning fire",
        due_at: 1
      })

    _seed_notices = observed_classes()
    opts = [wake_id: wake.wake_id, fire_wake_in_txn: true]

    assert {:error, %RuntimeError{message: "rollback winning fire"}} =
             DB.transaction(db, fn txn ->
               assert {:appended, ^target, _, _} =
                        Gateway.deliver_prompt_in_txn(txn, target, wake.origin, wake.prompt, opts)

               assert [["fired"]] =
                        DB.Txn.q(txn, "SELECT state FROM wakes WHERE wakeId=?1", [wake.wake_id])

               raise "rollback winning fire"
             end)

    assert Wakes.get(db, wake.wake_id).state == "pending"

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM turns WHERE wakeId=?1", [wake.wake_id])

    assert observed_classes() == []

    assert {:ok, {:appended, ^target, _, _}} =
             DB.transaction(
               db,
               &Gateway.deliver_prompt_in_txn(&1, target, wake.origin, wake.prompt, opts)
             )

    notices = for _ <- 1..3, do: receive_notice()

    assert Enum.map(notices, & &1["class"]) == [
             "session.updated",
             "wake.fired",
             "message.created"
           ]

    fired = Enum.at(notices, 1)
    assert fired["refs"]["wakeId"] == wake.wake_id
    assert fired["payload"]["state"] == "fired"
    assert Wakes.get(db, wake.wake_id).state == "fired"
    assert {:ok, before_turns} = DB.query(db, "SELECT * FROM turns ORDER BY seq")
    assert {:ok, before_wakes} = DB.query(db, "SELECT * FROM wakes ORDER BY wakeId")

    assert {:ok, {:duplicate, _}} =
             DB.transaction(
               db,
               &Gateway.deliver_prompt_in_txn(&1, target, wake.origin, wake.prompt, opts)
             )

    assert observed_classes() == []
    assert {:ok, ^before_turns} = DB.query(db, "SELECT * FROM turns ORDER BY seq")
    assert {:ok, ^before_wakes} = DB.query(db, "SELECT * FROM wakes ORDER BY wakeId")

    external =
      Wakes.schedule(db, %{
        session_key: target,
        origin: "process:tightbeam",
        prompt: "caller-owned fire",
        due_at: 2
      })

    _seed_notices = observed_classes()

    assert {:ok, {:appended, ^target, _, _}} =
             DB.transaction(
               db,
               &Gateway.deliver_prompt_in_txn(&1, target, external.origin, external.prompt,
                 wake_id: external.wake_id,
                 fire_wake_in_txn: false
               )
             )

    assert Wakes.get(db, external.wake_id).state == "pending"
    # A second queued turn leaves mechanical status unchanged.
    assert observed_classes() == ["message.created"]
  end

  test "work-item-create emits its committed routing wake once, never on keyed replay" do
    db = :firehose_work_item_create_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")
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
    refute_receive {:firehose_notice, %{"class" => "work_item.created"}}
    refute_receive {:firehose_notice, %{"class" => "wake.scheduled"}}
  end

  test "post declares the message effect its committed delivery actually emits" do
    db = :firehose_post_effect_db
    registry = :firehose_post_effect_registry
    lane = :firehose_post_effect_lane
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")
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
             "class" => "session.updated",
             "payload" => %{"mechanicalStatus" => "running", "sessionKey" => "post-target"}
           } = receive_notice()

    assert %{
             "class" => "message.created",
             "payload" => %{
               "content" => "[from user:flynn]\n\nexact A1 post reproduction"
             }
           } = receive_notice()

    declared = Gateway.handler_effects(%{db: db})["post"]
    observed = ["message.created", "session.updated"]
    assert_effects_match!(declared, observed)

    assert_raise ArgumentError, ~r/missing=\["message.created", "session.updated"\]/, fn ->
      assert_effects_match!([], observed)
    end
  end

  test "per-verb effects match real wake, condition, dispatch, and attest outcomes" do
    db = :firehose_per_verb_effect_db
    scheduler = :firehose_per_verb_effect_scheduler
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")
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

    {:ok, wake_turn} = Ledger.claim_next(db, "effect-target", "lane:effects")
    _ = observed_classes()

    :ok =
      Ledger.finish(db, wake_turn.seq, "delivered", nil)

    _ = observed_classes()

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

    {:ok, condition_turn} = Ledger.claim_next(db, "effect-target", "lane:effects")
    _ = observed_classes()

    :ok =
      Ledger.finish(db, condition_turn.seq, "delivered", nil)

    _ = observed_classes()

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

    assert {:error, %{code: "inapplicable_code_evidence"}} =
             Dispatch.dispatch(db, handlers, completion)

    assert {:ok, [["open", nil]]} =
             DB.query(db, "SELECT state,closingAttestId FROM assignments WHERE id=?1", [
               assignment.id
             ])

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM attests WHERE assignmentId=?1 AND kind='completion'",
               [assignment.id]
             )

    # Discard only the already asserted tests-passed verdict and denied observation.
    assert observed_state_classes() == ["attest.filed"]

    previous_runner = Application.get_env(:tightbeam, :commit_ref_command)

    on_exit(fn ->
      if previous_runner,
        do: Application.put_env(:tightbeam, :commit_ref_command, previous_runner),
        else: Application.delete_env(:tightbeam, :commit_ref_command)
    end)

    commit = String.duplicate("a", 40)
    refs = [%{"repo" => "testhost:/synthetic/publisher-code", "commit" => commit}]
    test_pid = self()

    Application.put_env(:tightbeam, :commit_ref_command, fn executable, args, opts ->
      assert executable == "git"
      assert args == ["-C", "/synthetic/publisher-code", "cat-file", "-e", "#{commit}^{commit}"]
      assert opts == [stderr_to_stdout: true]
      send(test_pid, :synthetic_commit_ref_checked)
      {"", 0}
    end)

    review_call = %{
      dispatch
      | verb: "assign",
        session_key: "effect-dispatcher",
        params: %{
          subject: "Independent synthetic publisher review",
          reviews_assignment_id: assignment.id
        }
    }

    assert {:ok, review} = Dispatch.dispatch(db, handlers, review_call)
    assert review.holderKey != assignment.holderKey
    assert review.reviewsAssignmentId == assignment.id
    assert observed_state_classes() == ["assignment.opened"]

    clean = %{
      tests_passed
      | origin: "agent:effect-dispatcher",
        principal: {:session, "effect-dispatcher"},
        params: %{
          assignment_id: review.id,
          kind: "verdict",
          verdict_kind: "reviewed-clean",
          commit_refs: refs,
          note: "Synthetic review fixture"
        }
    }

    assert {:ok, %{attest: %{verdictKind: "reviewed-clean"}}} =
             Dispatch.dispatch(db, handlers, clean)

    verified =
      tests_passed
      |> put_in([:params, :verdict_kind], "verified")
      |> put_in([:params, :commit_refs], refs)

    assert {:ok, %{attest: %{verdictKind: "verified"}}} =
             Dispatch.dispatch(db, handlers, verified)

    completion = put_in(completion, [:params, :commit_refs], refs)

    assert {:ok, %{assignment: %{state: "closed", outcome: "completed"}}} =
             Dispatch.dispatch(db, handlers, completion)

    assert_per_verb_effects!(config, "attest", observed_state_classes())

    reopen = %{
      verb: "reopen-assignment",
      origin: "agent:effect-target",
      principal: {:session, "effect-target"},
      session_key: nil,
      params: %{assignment_id: assignment.id, reason: "continue the real assignment"}
    }

    assert {:ok, %{id: reopened_id, state: "open", closedAt: nil}} =
             Dispatch.dispatch(db, handlers, reopen)

    assert reopened_id == assignment.id
    assert_per_verb_effects!(config, "reopen-assignment", observed_state_classes())
    history = Tightbeam.Assignments.list_reopenings(db, assignment.id)
    assert [%{priorOutcome: "completed", reason: "continue the real assignment"}] = history
    assert {:error, %{code: "assignment_open"}} = Dispatch.dispatch(db, handlers, reopen)
    assert Tightbeam.Assignments.list_reopenings(db, assignment.id) == history
    assert observed_state_classes() == []
  end

  test "a raised state handler emits denied and never accepted state effects" do
    db = :firehose_raised_handler_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})

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
               message_fixture("s_1", 9, "agent:one", "hello"),
               %{"ownerUserId" => "flynn", "sessionKey" => "agent:one"}
             )

    assert %{
             "class" => "message.created",
             "refs" => %{"messageId" => "s_1"},
             "payload" => %{"id" => "s_1", "rowVersion" => 9}
           } = receive_notice()
  end

  @tag rest_r7_closure: true
  test "transactional message refs equal the payload and detect missing or mismatched keys" do
    db = :firehose_message_ref_equality_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})

    assert {:appended, message} =
             Tightbeam.Projection.append(db, %{
               session_key: "session-ref-proof",
               role: "user",
               content: "hello",
               timestamp: 9,
               attachments: []
             })

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Publisher.message_in_txn(
                 txn,
                 message.session_key,
                 %{message | content: "untrusted supplied content"},
                 "flynn"
               )
             end)

    notice = receive_notice()
    assert notice["class"] == "message.created"
    assert notice["refs"]["ownerUserId"] == "flynn"

    assert {:ok, %{primary_refs: ["messageId", "sessionKey"]}} =
             Tightbeam.Firehose.Registry.fetch("message.created")

    equality = fn candidate ->
      assert candidate["refs"]["messageId"] == candidate["payload"]["id"]
      assert candidate["refs"]["sessionKey"] == candidate["payload"]["sessionKey"]
    end

    equality.(notice)
    assert notice["payload"]["content"] == "hello"

    canonical =
      db
      |> Tightbeam.StateResources.query_message(message.id)
      |> Tightbeam.StateResources.message()

    assert notice["payload"] == canonical
    assert JSON.decode!(Publisher.encode_wire_notice(notice))["payload"] == canonical

    for key <- ["messageId", "sessionKey"] do
      assert_raise ExUnit.AssertionError, fn ->
        equality.(update_in(notice, ["refs"], &Map.delete(&1, key)))
      end

      assert_raise ExUnit.AssertionError, fn ->
        equality.(put_in(notice, ["refs", key], "mismatched"))
      end
    end

    for {user, session_filter, allowed} <- [
          {"flynn", message.session_key, true},
          {"other", message.session_key, false},
          {"flynn", "different-session", false}
        ] do
      :ok = Hub.register(Hub, self(), %{mode: :filtered, db: db, user_id: user, is_admin: false})

      :ok =
        Hub.subscribe(Hub, self(), "message-ref-control", %{
          "classes" => ["message.created"],
          "sessionKey" => session_filter
        })

      Hub.publish(Hub, notice)
      _barrier = Hub.sequence(Hub, self())

      if allowed do
        assert_received {:firehose_notice, frame}
        equality.(frame)
        assert frame["payload"]["id"] == message.id
        assert frame["payload"]["rowVersion"] == message.seq
        Hub.delivered(Hub, self())
      else
        refute_received {:firehose_notice, _frame}
      end

      :ok = Hub.unsubscribe(Hub, self(), "message-ref-control")
    end
  end

  test "0.1.9 operator decisions emit opened, ruled, and withdrawn classes" do
    db = :firehose_operator_decisions_db
    scheduler = :firehose_operator_decisions_scheduler
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({LaneStub, name: scheduler})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")
    register_testhost(db)

    Org.create(db, %{
      session_key: "operator-raiser",
      display_name: "Operator raiser",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })

    handlers = Gateway.handlers(%{db: db, wake_scheduler: scheduler})

    ask = %{
      verb: "operator-ask",
      origin: "agent:operator-raiser",
      principal: {:session, "operator-raiser"},
      transport_session_key: "operator-raiser",
      session_key: nil,
      params: %{question: "Ship the candidate?", options: [%{label: "ship"}, %{label: "hold"}]}
    }

    assert {:ok, %{status: "open"} = request} = Dispatch.dispatch(db, handlers, ask)
    assert observed_state_classes() == ["decision_request.opened"]
    assert Gateway.handler_effects(%{db: db})["operator-ask"] == ["decision_request.opened"]

    assert {:ok, %{id: replay_id}} = Dispatch.dispatch(db, handlers, ask)
    assert replay_id == request.id
    assert observed_classes() == ["verb.accepted"]

    rule = %{
      verb: "operator-rule",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      transport_session_key: nil,
      session_key: nil,
      params: %{request: request.id, decision: "ship"}
    }

    assert {:ok, %{status: "ruled"}} = Dispatch.dispatch(db, handlers, rule)

    assert observed_state_classes() == [
             "decision_request.ruled",
             "session.updated",
             "message.created",
             "wake.fired"
           ]

    assert {:ok, [["operator-raiser"]]} = DB.query(db, "SELECT sessionKey FROM turns")
    assert {:ok, committed_turns} = DB.query(db, "SELECT * FROM turns ORDER BY seq")
    assert {:ok, committed_wakes} = DB.query(db, "SELECT * FROM wakes ORDER BY wakeId")
    # The declared direct decision effect remains distinct from the normal
    # row-recognition callback's committed notification delivery.
    assert Gateway.handler_effects(%{db: db})["operator-rule"] == ["decision_request.ruled"]

    assert {:ok, %{status: "ruled"}} = Dispatch.dispatch(db, handlers, rule)
    assert observed_classes() == ["verb.accepted"]
    assert {:ok, ^committed_turns} = DB.query(db, "SELECT * FROM turns ORDER BY seq")
    assert {:ok, ^committed_wakes} = DB.query(db, "SELECT * FROM wakes ORDER BY wakeId")

    ask_withdraw = put_in(ask.params.question, "Withdraw the candidate?")

    assert {:ok, %{status: "open"} = withdraw_request} =
             Dispatch.dispatch(db, handlers, ask_withdraw)

    assert observed_state_classes() == ["decision_request.opened"]

    withdraw = %{
      verb: "operator-withdraw",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      transport_session_key: nil,
      session_key: nil,
      params: %{request: withdraw_request.id, reason: "Candidate was superseded"}
    }

    assert {:ok, %{status: "withdrawn"}} = Dispatch.dispatch(db, handlers, withdraw)
    assert observed_state_classes() == ["decision_request.withdrawn"]

    assert Gateway.handler_effects(%{db: db})["operator-withdraw"] == [
             "decision_request.withdrawn"
           ]

    assert {:ok, %{status: "withdrawn"}} = Dispatch.dispatch(db, handlers, withdraw)
    assert observed_classes() == ["verb.accepted"]
  end

  @tag rest_r7_followup: true
  test "agent responses emit one state transition and accepted-only retries" do
    db = :firehose_agent_decisions_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")
    register_testhost(db)

    for key <- ["agent-asker", "agent-reader"] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Tightbeam.Model.new("fable")
      })
    end

    handlers = Gateway.handlers(%{db: db})

    ask = %{
      verb: "ask",
      origin: "agent:agent-asker",
      principal: {:session, "agent-asker"},
      transport_session_key: "agent-asker",
      session_key: "agent-reader",
      params: %{question: "What is missing?"}
    }

    for {verb, payload, status, class} <- [
          {"answer", %{answer: "Ready"}, "answered", "decision_request.ruled"},
          {"return", %{reason: "Need evidence"}, "returned", "decision_request.returned"}
        ] do
      assert {:ok, request} = Dispatch.dispatch(db, handlers, ask)
      assert observed_state_classes() == ["decision_request.opened"]

      response = %{
        ask
        | verb: verb,
          session_key: nil,
          principal: {:session, "agent-reader"},
          origin: "agent:agent-reader",
          transport_session_key: "agent-reader",
          params: Map.put(payload, :request, request.id)
      }

      assert {:ok, %{status: ^status}} = Dispatch.dispatch(db, handlers, response)
      assert %{"class" => "verb.accepted"} = receive_notice()
      notice = receive_notice()
      assert notice["class"] == class

      canonical =
        db
        |> Tightbeam.StateResources.query_decision_request(request.id)
        |> Tightbeam.StateResources.decision_request()

      assert notice["payload"] == canonical
      assert JSON.decode!(Publisher.encode_wire_notice(notice))["payload"] == canonical

      if status == "returned" do
        assert canonical["returnedBy"] == "session:agent-reader"
        assert canonical["returnReason"] == "Need evidence"
        assert is_integer(canonical["returnedAt"]) and canonical["returnedAt"] > 0
      end

      assert {:ok, %{status: ^status}} = Dispatch.dispatch(db, handlers, response)

      assert db
             |> Tightbeam.StateResources.query_decision_request(request.id)
             |> Tightbeam.StateResources.decision_request() == canonical

      assert observed_classes() == ["verb.accepted"]
    end
  end

  test "ledger transitions hand off turn notices only after their commits" do
    db = :firehose_turn_transition_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")
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

    assert %{
             "class" => "session.updated",
             "payload" => %{"mechanicalStatus" => "running", "sessionKey" => "turn-target"}
           } = receive_notice()

    assert {:ok, %{seq: ^seq}} =
             Ledger.claim_next(db, "turn-target", "lane:test")

    assert %{
             "class" => "turn.started",
             "refs" => %{"turnSeq" => ^seq},
             "payload" => %{"status" => "running", "seq" => ^seq}
           } = receive_notice()

    assert :ok = Ledger.finish(db, seq, "delivered")

    assert %{
             "class" => "turn.ended",
             "refs" => %{"turnSeq" => ^seq},
             "payload" => %{"status" => "delivered", "seq" => ^seq}
           } = receive_notice()

    assert %{
             "class" => "session.updated",
             "payload" => %{"mechanicalStatus" => "idle", "sessionKey" => "turn-target"}
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
            message_fixture("first", 1, "agent:first", "one"),
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
            message_fixture("second", 2, "agent:second", "two"),
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
                 message_fixture("rolled-back", 1, "agent:none", "none"),
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
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})

    {:ok, _} =
      Tightbeam.DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")

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

  @tag firehose_full_projection: true
  test "condition and critical projections carry stable ids and last-version-wins" do
    fact = %{fact_id: 4, ts: 100, kind: "ready", scope: "synthetic", origin: "process:fixture"}
    older_fact = Tightbeam.StateResources.condition_fact(fact)
    newer_fact = Tightbeam.StateResources.condition_fact(%{fact | fact_id: 5, ts: 90})

    assert Enum.sort(Map.keys(older_fact)) ==
             Enum.sort(~w(factId ts kind scope origin rowVersion))

    assert older_fact["scope"] == "synthetic"
    assert older_fact["origin"] == "process:fixture"

    assert_raise ArgumentError, ~r/extra or missing field/, fn ->
      Tightbeam.StateResources.condition_fact(Map.delete(fact, :scope))
    end

    assert_raise ArgumentError, ~r/extra or missing field/, fn ->
      Tightbeam.StateResources.condition_fact(Map.put(older_fact, "unexpected", true))
    end

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

  @tag rest_r7_followup: true
  test "B2 Dispatch notices share canonical priority and suppress no-op state" do
    db = :rest_b2_dispatch_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',1,1)")
    register_testhost(db)
    handlers = Gateway.handlers(%{db: db})

    call = %{
      verb: "work-item-create",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{title: "B2 notice", priority: 2}
    }

    assert {:ok, item} = Dispatch.dispatch(db, handlers, call)
    assert %{"class" => "wake.scheduled"} = receive_notice()
    assert %{"class" => "verb.accepted"} = receive_notice()
    created = receive_notice()
    assert created["class"] == "work_item.created"

    canonical = fn ->
      db
      |> Tightbeam.StateResources.query_work_item(item.id, call)
      |> Tightbeam.StateResources.work_item()
    end

    assert created["payload"] == canonical.()
    assert created["payload"]["priority"] == 2
    update = %{call | verb: "work-item-update", params: %{work_item_id: item.id, priority: 7}}
    assert {:ok, _} = Dispatch.dispatch(db, handlers, update)
    assert %{"class" => "verb.accepted"} = receive_notice()
    updated = receive_notice()
    assert updated["class"] == "work_item.updated"
    assert updated["payload"] == canonical.()
    assert updated["payload"]["priority"] == 7
    assert updated["payload"]["rowVersion"] > created["payload"]["rowVersion"]
    assert JSON.decode!(Publisher.encode_wire_notice(updated))["payload"] == canonical.()
    before = canonical.()
    assert {:ok, _} = Dispatch.dispatch(db, handlers, update)
    assert observed_classes() == ["verb.accepted"]
    assert canonical.() == before
  end

  defp message_fixture(id, seq, session_key, content) do
    %{
      id: id,
      seq: seq,
      session_key: session_key,
      role: "user",
      message_type: nil,
      content: content,
      timestamp: seq,
      sender: nil,
      device_id: nil,
      client_message_id: nil,
      reply_to_message_id: nil,
      reply_to_client_message_id: nil,
      llm_visible_message_id: id,
      attachments: [],
      attention_tier: 1
    }
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
