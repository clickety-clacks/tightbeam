defmodule Tightbeam.Firehose.PublisherTest do
  use Tightbeam.TestCase, async: false
  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    ConnRegistry,
    DB,
    Devices,
    Dispatch,
    Escalation,
    Gateway,
    Ledger,
    Org,
    Projection,
    StateResources,
    Wakes
  }

  alias Tightbeam.NoticeBatcher
  alias Tightbeam.Firehose.{Hub, Publisher}
  alias Tightbeam.Wire.Router

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

    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneStub, name: Tightbeam.LaneManager})

    assert {:ok, _} =
             Ledger.enqueue(db, %{
               session_key: target,
               message_id: "firehose-busy-boundary",
               origin: "user:flynn",
               prompt: "hold recipient busy"
             })

    assert {:ok, busy_turn} = Ledger.claim_next(db, target, "lane:firehose-boundary")
    _claim_notices = observed_classes()

    wake =
      Wakes.schedule(db, %{
        session_key: target,
        origin: "process:tightbeam",
        prompt: "synthetic winning fire",
        due_at: 1
      })

    assert_receive {:firehose_notice,
                    %{
                      "class" => "wake.scheduled",
                      "refs" => %{"wakeId" => wake_id}
                    }}

    assert wake_id == wake.wake_id
    Hub.delivered(Hub, self())
    opts = [wake_id: wake.wake_id, fire_wake_in_txn: true]

    assert {:error, %RuntimeError{message: "rollback winning fire"}} =
             DB.transaction(db, fn txn ->
               assert {:staged, _source} =
                        Gateway.deliver_prompt_in_txn(txn, target, wake.origin, wake.prompt, opts)

               assert [["pending"]] =
                        DB.Txn.q(txn, "SELECT state FROM wakes WHERE wakeId=?1", [wake.wake_id])

               raise "rollback winning fire"
             end)

    assert Wakes.get(db, wake.wake_id).state == "pending"

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM turns WHERE wakeId=?1", [wake.wake_id])

    refute Enum.any?(observed_notices(), fn notice ->
             get_in(notice, ["refs", "wakeId"]) == wake.wake_id
           end)

    assert {:ok, {:staged, _source}} =
             DB.transaction(
               db,
               &Gateway.deliver_prompt_in_txn(&1, target, wake.origin, wake.prompt, opts)
             )

    assert NoticeBatcher.source_refs(db, wake.wake_id) == []
    assert Wakes.get(db, wake.wake_id).state == "pending"

    assert_receive {:firehose_notice,
                    %{
                      "class" => "wake.scheduled",
                      "refs" => %{"wakeId" => wake_id},
                      "payload" => %{"state" => "pending", "firedAt" => fired_at}
                    }}

    assert wake_id == wake.wake_id
    assert is_integer(fired_at)
    Hub.delivered(Hub, self())

    assert :ok =
             Ledger.finish(db, busy_turn.seq, "delivered", nil,
               owner_lease: busy_turn.owner_lease
             )

    _busy_terminal_notices = observed_classes()
    assert [carrier_id] = Wakes.materialize_digests(db)
    scheduler = start_delivery_scheduler(db)
    assert :ok = Wakes.fire_due(scheduler)

    assert [%{delivery_wake_id: ^carrier_id, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(db, wake.wake_id)

    notices = observed_classes()
    assert "session.updated" in notices
    assert "wake.fired" in notices
    assert "message.created" in notices
    assert Wakes.get(db, wake.wake_id).state == "fired"

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM turns WHERE wakeId=?1", [wake.wake_id])

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

    assert {:ok, carrier_turn} = Ledger.claim_next(db, target, "lane:firehose-boundary")
    assert carrier_turn.wake_id == carrier_id
    _claim_notices = observed_classes()

    external =
      Wakes.schedule(db, %{
        session_key: target,
        origin: "process:tightbeam",
        prompt: "caller-owned fire",
        due_at: 2
      })

    _seed_notices = observed_classes()

    assert {:ok, {:staged, _source}} =
             DB.transaction(
               db,
               &Gateway.deliver_prompt_in_txn(&1, target, external.origin, external.prompt,
                 wake_id: external.wake_id,
                 fire_wake_in_txn: false
               )
             )

    assert Wakes.get(db, external.wake_id).state == "pending"

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM turns WHERE wakeId=?1", [external.wake_id])

    external_wake_notices = observed_notices()
    assert Enum.map(external_wake_notices, & &1["class"]) == ["wake.scheduled"]
    external_wake_notice = hd(external_wake_notices)
    external_wake_row = db |> StateResources.query_wake(external.wake_id) |> StateResources.wake()
    assert external_wake_notice["refs"]["wakeId"] == external.wake_id
    assert external_wake_notice["payload"] == external_wake_row
    assert external_wake_row["state"] == "pending"
    assert is_integer(external_wake_row["firedAt"])
  end

  test "transactional wake creation publishes its canonical scheduled row" do
    db = :firehose_wake_creation_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})

    wake =
      Wakes.schedule(db, %{
        session_key: "wake-target",
        origin: "process:tightbeam",
        prompt: "inspect this scheduled row",
        due_at: 1
      })

    assert %{
             "class" => "wake.scheduled",
             "resource" => "wakes",
             "op" => "upsert",
             "refs" => %{"wakeId" => wake_id, "sessionKey" => "wake-target"},
             "payload" => payload
           } = receive_notice()

    assert wake_id == wake.wake_id
    assert payload["wakeId"] == wake.wake_id
    assert payload["prompt"] == "inspect this scheduled row"
    assert payload["state"] == "pending"
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

    post_notices = Enum.map(1..3, fn _ -> receive_notice() end)

    assert Enum.sort(Enum.map(post_notices, & &1["class"])) ==
             Enum.sort(["turn.queued", "session.updated", "message.created"])

    assert %{"payload" => %{"mechanicalStatus" => "running", "sessionKey" => "post-target"}} =
             Enum.find(post_notices, &(&1["class"] == "session.updated"))

    assert %{"payload" => %{"status" => "queued", "sessionKey" => "post-target"}} =
             Enum.find(post_notices, &(&1["class"] == "turn.queued"))

    assert %{
             "payload" => %{
               "content" => "[from user:flynn]\n\nexact A1 post reproduction"
             }
           } = Enum.find(post_notices, &(&1["class"] == "message.created"))

    declared = Gateway.handler_effects(%{db: db})["post"]
    observed = Enum.map(post_notices, & &1["class"])
    assert_effects_match!(declared, observed)

    assert_raise ArgumentError, ~r/missing=/, fn ->
      assert_effects_match!([], observed)
    end
  end

  test "per-verb effects match real wake, condition, dispatch, and attest outcomes" do
    db = :firehose_per_verb_effect_db
    scheduler = :firehose_per_verb_effect_scheduler
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})

    {:paired, completion_device} =
      Devices.pair(db, %{
        device_id: "firehose-completion-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    :ok = DB.execute(db, "UPDATE users SET isAdmin=1 WHERE userId='flynn'")
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

    router_opts = [
      db: db,
      base_dir: System.tmp_dir!(),
      handlers: handlers,
      cli_token: "unused-completion-test-token",
      firehose_hub: Hub,
      model_catalog: %{},
      session_status: fn _ -> nil end
    ]

    immediate_wake = %{
      verb: "wake",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: "effect-target",
      params: %{prompt: "immediate effect", after_ms: 0, idempotency_key: "effect-immediate"}
    }

    assert {:ok, %{wake_id: immediate_id}} = Dispatch.dispatch(db, handlers, immediate_wake)
    assert :ok = Wakes.fire_due(scheduler)
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
      Ledger.finish(db, wake_turn.seq, "delivered", nil, owner_lease: wake_turn.owner_lease)

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
    # Wait for the delivery pass the condition nudge queued.
    :sys.get_state(scheduler)
    assert_per_verb_effects!(config, "condition", observed_state_classes())

    {:ok, condition_turn} = Ledger.claim_next(db, "effect-target", "lane:effects")
    _ = observed_classes()

    :ok =
      Ledger.finish(db, condition_turn.seq, "delivered", nil,
        owner_lease: condition_turn.owner_lease
      )

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

    _dispatched_turn = finish_next_turn!(db, "effect-target", "lane:effects")

    work_item_create = %{
      verb: "work-item-create",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{title: "Exercise the rumination dispatch effect"}
    }

    assert {:ok, work_item} = Dispatch.dispatch(db, handlers, work_item_create)
    _ = observed_classes()

    work_item_dispatch = %{
      dispatch
      | params:
          Map.merge(dispatch.params, %{
            subject: "Effect work-item dispatch",
            brief: "Exercise work-item assignment publication.",
            work_item_id: work_item.id
          })
    }

    assert {:ok, _work_item_assignment} = Dispatch.dispatch(db, handlers, work_item_dispatch)
    work_item_dispatch_observed = observed_state_classes()
    _work_item_dispatched_turn = finish_next_turn!(db, "effect-target", "lane:effects")

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

    assert :ok = Wakes.fire_due(scheduler)
    dispatch_delivery_effects = observed_state_classes()

    dispatch_events =
      dispatch_observed ++
        work_item_dispatch_observed ++
        state_classes(rumination_classes) ++
        dispatch_delivery_effects

    # The rumination's asynchronous wake delivery has its own wake.fired event;
    # the dispatch handler's declared effects describe its direct commit effects.
    assert "wake.fired" in dispatch_events

    assert_per_verb_effects!(
      config,
      "dispatch",
      Enum.reject(dispatch_events, &(&1 == "wake.fired"))
    )

    _rumination_turn = finish_next_turn!(db, "effect-dispatcher", "lane:effects")

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

    assert {:ok, [[initial_deadline]]} =
             DB.query(
               db,
               "SELECT wakeId FROM wakes WHERE assignmentId=?1 AND consumer='assignment_inactivity_deadline' AND state='pending'",
               [assignment.id]
             )

    assignment_before_attest =
      db
      |> StateResources.query_assignment(assignment.id, %{principal: {:session, "effect-target"}})
      |> StateResources.assignment()

    assert {:ok, %{attest: %{verdictKind: "tests-passed"}}} =
             Dispatch.dispatch(db, handlers, tests_passed)

    # The holder's attest and its holder-authored opener notice each count as
    # holder activity. Activity in the millisecond of the pending deadline
    # reuses it, so zero to two replacements follow the initial deadline.
    verdict_notices = drain_notices()
    assert Enum.count(verdict_notices, &(&1["class"] == "verb.accepted")) == 1

    %{"wake.canceled" => cancellations, "message.created" => [opener_notice]} =
      published =
      verdict_notices
      |> Enum.filter(&match?({:ok, _}, Tightbeam.Firehose.Registry.fetch(&1["class"])))
      |> Enum.group_by(& &1["class"])
      |> Map.put_new("wake.canceled", [])

    assert %{"attest.filed" => [_attest_notice]} = published
    assert map_size(published) == 3

    assert opener_notice["payload"]["content"] ==
             "[verdict filed: tests-passed on #{assignment.id}: effect matrix tests passed]"

    chain =
      Stream.unfold(initial_deadline, fn wake_id ->
        case DB.query(
               db,
               "SELECT c.replacementWakeId FROM wake_cancellations c JOIN wakes w ON w.wakeId=c.wakeId WHERE c.wakeId=?1 AND w.assignmentId=?2 AND w.consumer='assignment_inactivity_deadline' AND c.reasonKind='superseded' AND c.causalSourceKind='wake' AND c.causalSourceId=c.replacementWakeId AND c.outcomeKind='replacement'",
               [wake_id, assignment.id]
             ) do
          {:ok, [[replacement]]} -> {{wake_id, replacement}, replacement}
          {:ok, []} -> nil
        end
      end)
      |> Enum.to_list()

    assert length(chain) in 0..2

    assert Enum.sort(Enum.map(cancellations, & &1["refs"]["wakeId"])) ==
             Enum.sort(Enum.map(chain, &elem(&1, 0)))

    for cancellation <- cancellations do
      assert cancellation["payload"]["state"] == "canceled"
    end

    {_, final_deadline} = List.last(chain, {nil, initial_deadline})
    assert %{state: "pending"} = Wakes.get(db, final_deadline)
    assert observed_state_classes() == []

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

    # The refused completion must not publish a transition or reset inactivity.
    assert observed_state_classes() == []
    assert %{state: "pending"} = Wakes.get(db, final_deadline)

    {verdict_notices, _message_ids} = verdict_publications
    assignment_notice = Enum.find(verdict_notices, &(&1["class"] == "assignment.opened"))

    assignment_after_attest =
      db
      |> StateResources.query_assignment(assignment.id, %{principal: {:session, "effect-target"}})
      |> StateResources.assignment()

    assert assignment_notice["payload"] == assignment_after_attest
    assert assignment_after_attest["rowVersion"] > assignment_before_attest["rowVersion"]

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

    # The reviewer's opened notice is a stored message beside the transition.
    review_notices = observed_state_notices()
    assert map_size(review_notices) == 2

    assert %{"assignment.opened" => [_opened], "message.created" => [review_notice]} =
             review_notices

    assert review_notice["payload"]["sessionKey"] == review.holderKey
    assert review_notice["payload"]["content"] == "[assignment opened: #{review.id}]"

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

    completion_publications =
      assert_substrate_messages_created!(
        db,
        [
          {"effect-dispatcher",
           "[verdict filed: reviewed-clean on #{review.id}: Synthetic review fixture]"},
          {"effect-target",
           "[verdict filed: verified on #{assignment.id}: effect matrix tests passed]"},
          {"effect-target", "[completion filed on #{assignment.id}: effect matrix complete]"},
          {"effect-target", "[assignment closed: #{assignment.id} — completed]"}
        ],
        [assignment.id, review.id]
      )

    {completion_notices, _completion_message_ids} = completion_publications
    closed_notices = Enum.filter(completion_notices, &(&1["class"] == "assignment.closed"))

    assert [closed_notice] = closed_notices

    closed_response =
      rest_get("/api/assignments/#{assignment.id}", completion_device.token, router_opts)

    assert closed_response.status == 200, closed_response.resp_body
    closed_row = JSON.decode!(closed_response.resp_body)["item"]
    assert closed_notice["payload"] == closed_row

    completion_effects = notice_state_classes(completion_publications)
    asynchronous_delivery = ~w(session.updated wake.fired)

    assert Enum.all?(asynchronous_delivery, &(&1 in completion_effects))

    direct_completion_effects =
      Enum.reject(completion_effects, &(&1 in asynchronous_delivery))

    declared_attest_effects = Gateway.handler_effects(config)["attest"]
    assert Enum.all?(direct_completion_effects, &(&1 in declared_attest_effects))
    assert "attest.filed" in direct_completion_effects
    assert "assignment.closed" in direct_completion_effects
    assert "turn.queued" in direct_completion_effects

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

    reopen_publications =
      assert_substrate_messages_created!(
        db,
        [
          {
            "effect-target",
            "[assignment reopened: #{assignment.id} by session:effect-target — continue the real assignment]"
          }
        ],
        [assignment.id, review.id]
      )

    {reopen_notices, _reopen_message_ids} = reopen_publications
    assert [reopen_notice] = Enum.filter(reopen_notices, &(&1["class"] == "assignment.reopened"))

    reopened_response =
      rest_get("/api/assignments/#{assignment.id}", completion_device.token, router_opts)

    assert reopened_response.status == 200, reopened_response.resp_body
    reopened_row = JSON.decode!(reopened_response.resp_body)["item"]
    assert reopen_notice["payload"] == reopened_row
    assert reopened_row["rowVersion"] > closed_row["rowVersion"]

    reopen_effects = notice_state_classes(reopen_publications)
    declared_reopen_effects = Gateway.handler_effects(config)["reopen-assignment"]
    assert Enum.all?(reopen_effects, &(&1 in declared_reopen_effects))
    assert "assignment.reopened" in reopen_effects
    history = Tightbeam.Assignments.list_reopenings(db, assignment.id)
    assert [%{priorOutcome: "completed", reason: "continue the real assignment"}] = history

    :ok = Wakes.fire_due(scheduler)

    pending_publications =
      assert_substrate_messages_created!(db, [], [assignment.id, review.id])

    assert Enum.all?(notice_state_classes(pending_publications), &(&1 in asynchronous_delivery))

    assert {:error, %{code: "assignment_open"}} = Dispatch.dispatch(db, handlers, reopen)
    assert Tightbeam.Assignments.list_reopenings(db, assignment.id) == history

    replay_publications = assert_substrate_messages_created!(db, [], [])

    assert elem(replay_publications, 1) == []
    assert notice_state_classes(replay_publications) == []
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

  test "a substrate append publishes one canonical message.created after commit" do
    db = :firehose_substrate_append_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      Hub.register(Hub, self(), %{mode: :subscribed, db: db, user_id: "flynn", is_admin: false})

    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")
    register_testhost(db)

    session_key = "firehose-substrate-target"

    Org.create(db, %{
      session_key: session_key,
      display_name: "Substrate target",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })

    :ok =
      Hub.subscribe(Hub, self(), "substrate-appends", %{
        "classes" => ["message.created"],
        "sessionKey" => session_key
      })

    assert {:ok, {:appended, message}} =
             DB.transaction(db, fn txn ->
               Projection.append_substrate_in_txn(txn, session_key, "A substrate notice")
             end)

    notice = receive_notice()
    assert notice["class"] == "message.created"
    assert notice["refs"]["messageId"] == message.id

    item =
      db
      |> StateResources.query_message(message.id)
      |> StateResources.message()

    assert notice["payload"] == item
    item_bytes = StateResources.encode_item("transcript messages", item)
    wire_notice = Publisher.encode_wire_notice(notice)
    assert String.contains?(wire_notice, "\"payload\":" <> item_bytes)

    :sys.get_state(Hub)
    refute_receive {:firehose_notice, %{"class" => "message.created"}}, 0
  end

  test "a committed session-restart marker publishes one canonical message.created" do
    db = :firehose_session_restart_marker_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      Hub.register(Hub, self(), %{mode: :subscribed, db: db, user_id: "flynn", is_admin: false})

    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn', 1, 1)")
    register_testhost(db)

    session_key = "firehose-session-restart-target"

    Org.create(db, %{
      session_key: session_key,
      display_name: "Session restart target",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })

    :ok =
      Hub.subscribe(Hub, self(), "session-restart-markers", %{
        "classes" => ["message.created"],
        "sessionKey" => session_key
      })

    assert {:ok, {:appended, marker}} =
             DB.transaction(db, fn txn ->
               assert {:appended, marker} =
                        Projection.append_marker_in_txn(txn, session_key, %{
                          kind: "session-restart",
                          from: "old-session",
                          to: "new-session"
                        })

               refute_receive {:firehose_notice, %{"class" => "message.created"}}, 0
               {:appended, marker}
             end)

    notice = receive_notice()
    assert notice["class"] == "message.created"
    assert notice["refs"]["messageId"] == marker.id
    assert notice["refs"]["sessionKey"] == session_key
    assert notice["refs"]["ownerUserId"] == "flynn"

    canonical =
      db
      |> StateResources.query_message(marker.id)
      |> StateResources.message()

    assert notice["payload"] == canonical

    assert notice["payload"]["marker"] == %{
             "kind" => "session-restart",
             "from" => "old-session",
             "to" => "new-session"
           }

    item_bytes = StateResources.encode_item("transcript messages", canonical)
    assert String.contains?(Publisher.encode_wire_notice(notice), "\"payload\":" <> item_bytes)

    refute_receive {:firehose_notice, %{"class" => "message.created"}}, 0
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

    assert {:appended, marker} =
             Tightbeam.Projection.append_marker(db, message.session_key, %{
               kind: "harness-switch",
               from: "claude",
               to: "codex"
             })

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Publisher.message_in_txn(txn, marker.session_key, marker, "flynn")
             end)

    marker_notice = receive_notice()

    marker_canonical =
      db
      |> Tightbeam.StateResources.query_message(marker.id)
      |> Tightbeam.StateResources.message()

    assert marker_notice["class"] == "message.created"
    assert marker_notice["payload"] == marker_canonical

    assert marker_notice["payload"]["marker"] == %{
             "kind" => "harness-switch",
             "from" => "claude",
             "to" => "codex"
           }

    assert JSON.decode!(Publisher.encode_wire_notice(marker_notice))["payload"] ==
             marker_canonical

    assert JSON.decode!(
             Tightbeam.StateResources.encode_item("transcript messages", marker_canonical, %{})
           ) == marker_canonical

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
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})

    start_supervised!(
      Supervisor.child_spec({LaneStub, name: Tightbeam.LaneManager},
        id: :operator_decisions_delivery_lane
      )
    )

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

    delivery_scheduler = :firehose_operator_decisions_delivery_scheduler

    start_supervised!(
      {Wakes,
       db: db,
       name: delivery_scheduler,
       tick_ms: 60_000,
       deliver: fn wake ->
         {:ok, delivery} =
           DB.transaction(db, fn txn ->
             Gateway.deliver_prompt_in_txn(
               txn,
               wake.session_key,
               wake.origin,
               wake.prompt,
               wake_id: wake.wake_id,
               sender: wake.origin,
               target_gate: wake
             )
           end)

         delivery
       end}
    )

    :sys.get_state(delivery_scheduler)

    ask = %{
      verb: "operator-ask",
      origin: "agent:operator-raiser",
      principal: {:session, "operator-raiser"},
      transport_session_key: "operator-raiser",
      session_key: nil,
      params: %{question: "Ship the candidate?", options: [%{label: "ship"}, %{label: "hold"}]}
    }

    assert {:ok, %{status: "open"} = request} = Dispatch.dispatch(db, handlers, ask)
    assert observed_state_classes() == ["wake.scheduled", "decision_request.opened"]

    assert Gateway.handler_effects(%{db: db})["operator-ask"] ==
             ["decision_request.opened", "wake.scheduled"]

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

    ruling_effects = observed_state_classes()
    assert "decision_request.ruled" in ruling_effects
    refute "session.updated" in ruling_effects
    refute "message.created" in ruling_effects

    assert {:ok, [[source_wake_id]]} =
             DB.query(
               db,
               "SELECT wakeId FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1",
               [request.id]
             )

    assert {:ok, []} = DB.query(db, "SELECT seq FROM turns WHERE wakeId=?1", [source_wake_id])

    assert :ok = Wakes.fire_due(delivery_scheduler)

    assert [%{delivery_wake_id: carrier_id, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(db, source_wake_id)

    assert Wakes.get(db, source_wake_id).state == "fired"
    assert Wakes.get(db, carrier_id).state == "fired"

    assert {:ok, [["operator-raiser"]]} =
             DB.query(db, "SELECT sessionKey FROM turns WHERE wakeId=?1", [carrier_id])

    delivered_effects = observed_state_classes()
    assert "session.updated" in delivered_effects
    assert "message.created" in delivered_effects
    assert Enum.any?(ruling_effects ++ delivered_effects, &(&1 == "wake.fired"))

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

    assert observed_state_classes() == ["wake.scheduled", "decision_request.opened"]

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
          {"answer", %{answer: "Ready"}, "answered", "decision_request.answered"},
          {"return", %{reason: "Need evidence"}, "returned", "decision_request.returned"}
        ] do
      assert {:ok, request} = Dispatch.dispatch(db, handlers, ask)
      assert observed_state_classes() == ["wake.scheduled", "decision_request.opened"]

      response = %{
        ask
        | verb: verb,
          session_key: nil,
          principal: {:session, "agent-reader"},
          origin: "agent:agent-reader",
          transport_session_key: "agent-reader",
          params: Map.put(payload, :request, request.id)
      }

      notice_wake = pending_decision_notice!(db, request.id)
      assert {:ok, %{status: ^status}} = Dispatch.dispatch(db, handlers, response)
      response_notices = Enum.map(1..3, fn _ -> receive_notice() end)

      assert Enum.sort(Enum.map(response_notices, & &1["class"])) ==
               Enum.sort(["verb.accepted", "wake.scheduled", class])
      assert_decision_notice_cleared!(db, request.id, notice_wake)
      notice = Enum.find(response_notices, &(&1["class"] == class))
      assert notice["class"] == class
      assert notice["schemaVersion"] == 2
      assert notice["resource"] == "decision requests"
      assert notice["op"] == "upsert"
      assert notice["refs"] == %{"decisionRequestId" => request.id}

      canonical =
        db
        |> Tightbeam.StateResources.query_decision_request(request.id)
        |> Tightbeam.StateResources.decision_request()

      assert notice["payload"] == canonical
      assert JSON.decode!(Publisher.encode_wire_notice(notice))["payload"] == canonical
      assert Escalation.raw_by_id(db, request.id).row_schema_revision == 2

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

    assert {:ok, request} = Dispatch.dispatch(db, handlers, ask)
    assert observed_state_classes() == ["wake.scheduled", "decision_request.opened"]

    withdraw = %{
      ask
      | verb: "withdraw",
        session_key: nil,
        params: %{request: request.id, reason: "No longer needed"}
    }

    notice_wake = pending_decision_notice!(db, request.id)
    assert {:ok, %{status: "withdrawn"}} = Dispatch.dispatch(db, handlers, withdraw)
    assert %{"class" => "verb.accepted"} = receive_notice()
    assert_decision_notice_cleared!(db, request.id, notice_wake)
    notice = receive_notice()
    assert notice["class"] == "decision_request.withdrawn"
    assert notice["schemaVersion"] == 2
    assert notice["resource"] == "decision requests"
    assert notice["op"] == "upsert"
    assert notice["refs"] == %{"decisionRequestId" => request.id}
    assert notice["payload"]["status"] == "withdrawn"
    assert Escalation.raw_by_id(db, request.id).row_schema_revision == 2
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

    wake =
      Wakes.schedule(db, %{
        session_key: "turn-target",
        origin: "user:flynn",
        prompt: "run",
        due_at: System.system_time(:millisecond) + 60_000
      })

    assert %{"class" => "wake.scheduled", "payload" => %{"state" => "pending"}} =
             receive_notice()

    assert {:ok, seq} =
             Ledger.enqueue(db, %{
               session_key: "turn-target",
               wake_id: wake.wake_id,
               message_id: "turn-message",
               origin: "user:flynn",
               prompt: "run"
             })

    enqueue_notices = Enum.map(1..3, fn _ -> receive_notice() end)

    assert Enum.sort(Enum.map(enqueue_notices, & &1["class"])) ==
             Enum.sort(["session.updated", "turn.queued", "wake.scheduled"])

    queued = Enum.find(enqueue_notices, &(&1["class"] == "turn.queued"))
    queued_row = db |> StateResources.query_turn_by_seq(seq) |> StateResources.turn()
    assert queued["refs"] == %{"turnSeq" => seq, "sessionKey" => "turn-target"}
    assert queued["payload"] == queued_row
    assert queued_row["status"] == "queued"
    queued_version = queued_row["rowVersion"]
    session_notice = Enum.find(enqueue_notices, &(&1["class"] == "session.updated"))
    assert session_notice["payload"]["mechanicalStatus"] == "running"
    queued_wake = Enum.find(enqueue_notices, &(&1["class"] == "wake.scheduled"))
    assert queued_wake["payload"]["wakeId"] == wake.wake_id
    assert queued_wake["payload"]["deliveryStatus"] == "queued"
    queued_wake_version = queued_wake["payload"]["rowVersion"]

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending'",
                 [wake.wake_id, System.system_time(:millisecond)]
               )

               Wakes.publish_change_in_txn(txn, "wake.fired", wake.wake_id)
             end)

    assert %{
             "class" => "wake.fired",
             "payload" => %{
               "state" => "fired",
               "deliveryStatus" => "queued",
               "rowVersion" => fired_wake_version
             }
           } = receive_notice()

    assert fired_wake_version > queued_wake_version

    assert {:ok, %{seq: ^seq, owner_lease: seq_lease}} =
             Ledger.claim_next(db, "turn-target", "lane:test")

    assert %{
             "class" => "turn.started",
             "refs" => %{"turnSeq" => ^seq},
             "payload" => started_payload
           } = receive_notice()

    started = db |> StateResources.query_turn_by_seq(seq) |> StateResources.turn()
    assert started_payload == started
    assert started["rowVersion"] > queued_version

    assert %{
             "class" => "wake.fired",
             "payload" => %{
               "state" => "fired",
               "deliveryStatus" => "running",
               "rowVersion" => started_wake_version
             }
           } = receive_notice()

    assert started_wake_version > fired_wake_version

    assert :ok = Ledger.stamp_adapter(db, seq, 7)

    assert %{
             "class" => "turn.started",
             "refs" => %{"turnSeq" => ^seq},
             "payload" => %{"adapterGen" => 7, "seq" => ^seq, "rowVersion" => adapter_version}
           } = receive_notice()

    assert adapter_version > started["rowVersion"]

    assert :ok = Ledger.finish(db, seq, "delivered", nil, owner_lease: seq_lease)

    assert %{
             "class" => "turn.ended",
             "refs" => %{"turnSeq" => ^seq},
             "payload" => ended_payload
           } = receive_notice()

    ended = db |> StateResources.query_turn_by_seq(seq) |> StateResources.turn()
    assert ended_payload == ended
    assert ended["rowVersion"] > adapter_version

    assert %{
             "class" => "wake.fired",
             "payload" => %{
               "state" => "fired",
               "deliveryStatus" => "delivered",
               "rowVersion" => ended_wake_version
             }
           } = receive_notice()

    assert ended_wake_version > started_wake_version

    assert %{
             "class" => "session.updated",
             "payload" => %{"mechanicalStatus" => "idle", "sessionKey" => "turn-target"}
           } = receive_notice()

    assert :ok = Ledger.mark_published(db, seq)

    assert %{
             "class" => "turn.ended",
             "refs" => %{"turnSeq" => ^seq},
             "payload" => %{
               "publishedAt" => published_at,
               "seq" => ^seq,
               "rowVersion" => published_version
             }
           } = receive_notice()

    assert is_integer(published_at)
    assert published_version > ended["rowVersion"]

    assert db
           |> StateResources.query_turn_by_seq(seq)
           |> StateResources.turn()
           |> Map.fetch!("rowVersion") == published_version
  end

  test "a pending wake prompt mutation publishes the canonical wake row" do
    db = :firehose_pending_wake_update_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',1,1)")
    register_testhost(db)

    Org.create(db, %{
      session_key: "wake-target",
      display_name: "Wake target",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })

    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})
    :ok = Hub.subscribe(Hub, self(), "wake-prompt-update", %{"classes" => ["wake.scheduled"]})

    wake =
      Wakes.schedule(db, %{
        wake_id: "ephemeral-result:firehose-test",
        session_key: "wake-target",
        origin: "user:flynn",
        prompt: "original prompt",
        due_at: System.system_time(:millisecond) + 60_000
      })

    assert_receive {:firehose_notice, %{"class" => "wake.scheduled"}}
    Hub.delivered(Hub, self())

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.Ephemeral.final_message_in_txn(txn, "firehose-test", "updated result")
             end)

    assert_receive {:firehose_notice,
                    %{
                      "class" => "wake.scheduled",
                      "refs" => %{"wakeId" => "ephemeral-result:firehose-test"},
                      "payload" => payload
                    }}

    assert payload["wakeId"] == wake.wake_id
    assert payload["prompt"] =~ "updated result"
  end

  test "wake versions advance for same-millisecond writes and survive a gateway restart" do
    db = String.to_atom("firehose_wake_version_#{System.unique_integer([:positive])}")

    base =
      Path.join(System.tmp_dir!(), "firehose-wake-version-#{System.unique_integer([:positive])}")

    path = Path.join(base, "state.db")
    payload = Path.join(base, "payload")

    on_exit(fn -> File.rm_rf!(base) end)
    File.mkdir_p!(base)
    File.mkdir_p!(Path.join(payload, "ebin"))
    File.mkdir_p!(Path.join(payload, "priv"))
    File.write!(Path.join(payload, "ebin/fixture.beam"), "fixture")
    File.write!(Path.join(payload, "priv/fixture.rule"), "fixture")

    {:ok, manifest} =
      Tightbeam.LiveBaseGuard.generate_manifest(Tightbeam.LiveBasePayload.files!(payload))

    File.write!(Path.join(payload, "build-manifest.json"), JSON.encode!(manifest))

    start_supervised!(
      {DB, path: path, name: db, guard_inputs: [], payload_root: payload},
      id: db
    )

    :ok = Tightbeam.Schema.ensure_all(db)

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt) VALUES('versioned-wake','target','process:tightbeam','prompt',100,10)"
             )

    version = fn ->
      db
      |> Tightbeam.StateResources.query_wake("versioned-wake")
      |> Tightbeam.StateResources.wake()
      |> Map.fetch!("rowVersion")
    end

    initial = version.()

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(txn, "UPDATE wakes SET dueAt=101 WHERE wakeId='versioned-wake'")
               Wakes.publish_change_in_txn(txn, "wake.scheduled", "versioned-wake")
               :ok
             end)

    first = version.()
    assert first > initial

    assert %{"class" => "wake.scheduled", "payload" => first_payload} = receive_notice()
    assert first_payload["rowVersion"] == first

    assert first_payload ==
             db
             |> Tightbeam.StateResources.query_wake("versioned-wake")
             |> Tightbeam.StateResources.wake()

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(txn, "UPDATE wakes SET dueAt=102 WHERE wakeId='versioned-wake'")
               Wakes.publish_change_in_txn(txn, "wake.scheduled", "versioned-wake")
               :ok
             end)

    second = version.()
    assert second > first

    assert %{"class" => "wake.scheduled", "payload" => second_payload} = receive_notice()
    assert second_payload["rowVersion"] == second

    assert second_payload ==
             db
             |> Tightbeam.StateResources.query_wake("versioned-wake")
             |> Tightbeam.StateResources.wake()

    assert :ok = stop_supervised!(db)

    start_supervised!(
      {DB, path: path, name: db, guard_inputs: [], payload_root: payload},
      id: db
    )

    :ok = Tightbeam.Schema.ensure_all(db)

    assert version.() == second

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(txn, "UPDATE wakes SET dueAt=103 WHERE wakeId='versioned-wake'")
               Wakes.publish_change_in_txn(txn, "wake.scheduled", "versioned-wake")
               :ok
             end)

    assert %{"class" => "wake.scheduled", "payload" => restarted_payload} = receive_notice()
    assert version.() > second
    assert restarted_payload["rowVersion"] == version.()

    assert restarted_payload ==
             db
             |> Tightbeam.StateResources.query_wake("versioned-wake")
             |> Tightbeam.StateResources.wake()
  end

  test "assignment versions advance through same-millisecond close and reopen and survive restart" do
    db = String.to_atom("firehose_assignment_version_#{System.unique_integer([:positive])}")

    base =
      Path.join(
        System.tmp_dir!(),
        "firehose-assignment-version-#{System.unique_integer([:positive])}"
      )

    path = Path.join(base, "state.db")
    payload = Path.join(base, "payload")

    on_exit(fn -> File.rm_rf!(base) end)
    File.mkdir_p!(Path.join(payload, "ebin"))
    File.mkdir_p!(Path.join(payload, "priv"))
    File.write!(Path.join(payload, "ebin/fixture.beam"), "fixture")
    File.write!(Path.join(payload, "priv/fixture.rule"), "fixture")

    {:ok, manifest} =
      Tightbeam.LiveBaseGuard.generate_manifest(Tightbeam.LiveBasePayload.files!(payload))

    File.write!(Path.join(payload, "build-manifest.json"), JSON.encode!(manifest))

    start_supervised!({DB, path: path, name: db, guard_inputs: [], payload_root: payload}, id: db)
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('owner',1,1)")
    register_hosts(db, %{"testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}})

    Org.create(db, %{
      session_key: "holder-session",
      display_name: "Version holder",
      owner_user_id: "owner",
      origin: "user:owner",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })

    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "owner", is_admin: true})

    assignment_id = "versioned-assignment"
    attest_id = "versioned-close-attest"
    holder = "holder-session"
    principal = %{rest_principal: %{kind: "user", id: "owner", is_admin: true}}

    canonical = fn source ->
      source
      |> StateResources.query_assignment(assignment_id, principal)
      |> StateResources.assignment()
    end

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,holderHarness,holderProvider) VALUES(?1,?2,?3,'owner',1000,'claude','anthropic')",
                 [assignment_id, "version before close", holder]
               )

               row = StateResources.query_assignment(txn, assignment_id, principal)

               Publisher.committed_in_txn(txn, "assignment.opened", row, %{
                 "assignmentId" => assignment_id,
                 "sessionKey" => holder
               })

               :ok
             end)

    opened_notice = receive_notice()
    assert opened_notice["payload"] == canonical.(db)
    opened_version = opened_notice["payload"]["rowVersion"]

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "INSERT INTO attests(id,assignmentId,kind,bySession,ts) VALUES(?1,?2,'completion',?3,1000)",
                 [attest_id, assignment_id, holder]
               )

               Tightbeam.DB.Txn.q(
                 txn,
                 "UPDATE assignments SET state='closed',outcome='completed',closedAt=1000,closedBySession=?2,closingAttestId=?3 WHERE id=?1 AND state='open'",
                 [assignment_id, holder, attest_id]
               )

               row = StateResources.query_assignment(txn, assignment_id, principal)

               Publisher.committed_in_txn(txn, "assignment.closed", row, %{
                 "assignmentId" => assignment_id,
                 "sessionKey" => holder
               })

               :ok
             end)

    closed_notice = receive_notice()
    assert closed_notice["class"] == "assignment.closed"
    assert closed_notice["payload"] == canonical.(db)
    closed_version = closed_notice["payload"]["rowVersion"]
    assert closed_version > opened_version

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "INSERT INTO assignment_reopenings(assignmentId,ts,reopenedBySession,reason,priorOutcome,priorClosedAt,priorClosedBySession,priorClosingAttestId) VALUES(?1,1000,?2,'continue work','completed',1000,?2,?3)",
                 [assignment_id, holder, attest_id]
               )

               Tightbeam.DB.Txn.q(
                 txn,
                 "UPDATE assignments SET state='open',outcome=NULL,closedAt=NULL,closedByUser=NULL,closedBySession=NULL,closedByProcess=NULL,closingAttestId=NULL WHERE id=?1 AND state='closed'",
                 [assignment_id]
               )

               row = StateResources.query_assignment(txn, assignment_id, principal)

               Publisher.committed_in_txn(txn, "assignment.reopened", row, %{
                 "assignmentId" => assignment_id,
                 "sessionKey" => holder
               })

               :ok
             end)

    reopened_notice = receive_notice()
    assert reopened_notice["class"] == "assignment.reopened"
    assert reopened_notice["payload"] == canonical.(db)
    reopened_version = reopened_notice["payload"]["rowVersion"]
    assert reopened_version > closed_version
    closed_attest = StateResources.query_attest(db, attest_id) |> StateResources.attest()

    assert :ok = stop_supervised!(db)
    start_supervised!({DB, path: path, name: db, guard_inputs: [], payload_root: payload}, id: db)
    :ok = Tightbeam.Schema.ensure_all(db)
    assert canonical.(db)["rowVersion"] == reopened_version
    assert StateResources.query_attest(db, attest_id) |> StateResources.attest() == closed_attest

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "UPDATE assignments SET subject='version after restart' WHERE id=?1",
                 [assignment_id]
               )

               row = StateResources.query_assignment(txn, assignment_id, principal)

               Publisher.committed_in_txn(txn, "assignment.opened", row, %{
                 "assignmentId" => assignment_id,
                 "sessionKey" => holder
               })

               :ok
             end)

    restarted_notice = receive_notice()
    assert restarted_notice["payload"] == canonical.(db)
    assert restarted_notice["payload"]["rowVersion"] > reopened_version
  end

  @tag :tmp_dir
  test "work-item row versions survive restart and advance after a later mutation", %{
    tmp_dir: tmp
  } do
    db = String.to_atom("firehose_work_item_version_#{System.unique_integer([:positive])}")
    base = Path.join(tmp, "base")
    path = Path.join(base, "state.db")
    payload = Path.join(tmp, "payload")

    File.mkdir_p!(Path.join(payload, "ebin"))
    File.mkdir_p!(Path.join(payload, "priv"))
    File.write!(Path.join(payload, "ebin/fixture.beam"), "fixture")
    File.write!(Path.join(payload, "priv/fixture.rule"), "fixture")

    {:ok, manifest} =
      Tightbeam.LiveBaseGuard.generate_manifest(Tightbeam.LiveBasePayload.files!(payload))

    File.write!(Path.join(payload, "build-manifest.json"), JSON.encode!(manifest))

    start_supervised!({DB, path: path, name: db, guard_inputs: [], payload_root: payload}, id: db)
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('owner',0,1)")

    create_call = %{
      verb: "work-item-create",
      origin: "user:owner",
      principal: {:user, "owner"},
      session_key: nil,
      params: %{title: "Version survives restart"}
    }

    item = Tightbeam.WorkItems.__handle__(db, "work-item-create", create_call)
    principal = %{principal: {:user, "owner"}}

    canonical = fn source ->
      source
      |> StateResources.query_work_item(item.id, principal)
      |> StateResources.work_item()
    end

    before_restart = canonical.(db)

    assert :ok = stop_supervised!(db)
    start_supervised!({DB, path: path, name: db, guard_inputs: [], payload_root: payload}, id: db)
    :ok = Tightbeam.Schema.ensure_all(db)
    assert canonical.(db) == before_restart

    update_call = %{
      create_call
      | verb: "work-item-update",
        params: %{work_item_id: item.id, title: "Version advances after restart"}
    }

    updated = Tightbeam.WorkItems.__handle__(db, "work-item-update", update_call)
    after_restart = canonical.(db)
    assert updated.title == after_restart["title"]
    assert after_restart["title"] == "Version advances after restart"
    assert after_restart["rowVersion"] > before_restart["rowVersion"]
  end

  @tag :tmp_dir
  test "turn row versions survive restart and advance on a later lifecycle notice", %{
    tmp_dir: tmp
  } do
    db = String.to_atom("firehose_turn_version_#{System.unique_integer([:positive])}")
    base = Path.join(tmp, "base")
    path = Path.join(base, "state.db")
    payload = Path.join(tmp, "payload")

    File.mkdir_p!(Path.join(payload, "ebin"))
    File.mkdir_p!(Path.join(payload, "priv"))
    File.write!(Path.join(payload, "ebin/fixture.beam"), "fixture")
    File.write!(Path.join(payload, "priv/fixture.rule"), "fixture")

    {:ok, manifest} =
      Tightbeam.LiveBaseGuard.generate_manifest(Tightbeam.LiveBasePayload.files!(payload))

    File.write!(Path.join(payload, "build-manifest.json"), JSON.encode!(manifest))

    start_supervised!({DB, path: path, name: db, guard_inputs: [], payload_root: payload}, id: db)
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('owner',0,1)")
    register_hosts(db, %{"testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}})

    Org.create(db, %{
      session_key: "turn-version-owner",
      display_name: "Turn version owner",
      owner_user_id: "owner",
      origin: "user:owner",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })

    :ok =
      Hub.register(Hub, self(), %{mode: :subscribed, db: db, user_id: "owner", is_admin: false})

    :ok =
      Hub.subscribe(Hub, self(), "turn-version", %{"classes" => ["turn.queued", "turn.ended"]})

    session_key = "turn-version-owner"

    assert {:ok, seq} =
             Ledger.enqueue(db, %{
               session_key: session_key,
               message_id: "turn-version-message",
               origin: "user:owner",
               prompt: "verify durable turn version"
             })

    queued = receive_notice()
    assert queued["class"] == "turn.queued"
    queued_row = StateResources.query_turn_by_seq(db, seq) |> StateResources.turn()
    assert queued["payload"] == queued_row

    assert :ok = stop_supervised!(db)
    start_supervised!({DB, path: path, name: db, guard_inputs: [], payload_root: payload}, id: db)
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      Hub.register(Hub, self(), %{mode: :subscribed, db: db, user_id: "owner", is_admin: false})

    :ok =
      Hub.subscribe(Hub, self(), "turn-version", %{"classes" => ["turn.queued", "turn.ended"]})

    assert StateResources.query_turn_by_seq(db, seq) |> StateResources.turn() == queued_row

    assert {:ok, true} =
             DB.transaction(db, fn txn ->
               Ledger.cancel_queued_in_txn(txn, seq, "version restart fixture")
             end)

    ended = receive_notice()
    ended_row = StateResources.query_turn_by_seq(db, seq) |> StateResources.turn()
    assert ended["class"] == "turn.ended"
    assert ended["payload"] == ended_row
    assert ended_row["rowVersion"] > queued_row["rowVersion"]
  end

  test "wake row-version migration backfills the last timestamp projection" do
    db = :firehose_legacy_wake_version_db
    start_supervised!({DB, path: ":memory:", name: db})

    assert :ok =
             DB.execute(db, """
             CREATE TABLE wakes (
               wakeId TEXT PRIMARY KEY, sessionKey TEXT NOT NULL, targetRole TEXT,
               origin TEXT NOT NULL, prompt TEXT, consumer TEXT NOT NULL, dueAt INTEGER NOT NULL,
               state TEXT NOT NULL, createdAt INTEGER NOT NULL, firedAt INTEGER,
               reresolve TEXT, reresolveSeed TEXT, reresolveRung INTEGER,
               conditionKind TEXT, conditionScope TEXT, conditionAfterId INTEGER,
               firedBy TEXT, creatorSessionKey TEXT, rumination INTEGER NOT NULL DEFAULT 0,
               work_item_id TEXT, assignmentId TEXT, canceledAt INTEGER,
               targetGate INTEGER NOT NULL DEFAULT 1, class TEXT, classElection TEXT,
               deliveryRule TEXT, digest INTEGER NOT NULL DEFAULT 0, summon INTEGER NOT NULL DEFAULT 0
             );
             CREATE TABLE turns (wakeId TEXT, createdAt INTEGER, startedAt INTEGER, endedAt INTEGER);
             INSERT INTO wakes(wakeId,sessionKey,origin,consumer,dueAt,state,createdAt,firedAt)
               VALUES('legacy-wake','target','process:tightbeam','prompt',20,'fired',10,12);
             INSERT INTO turns(wakeId,createdAt,startedAt,endedAt)
               VALUES('legacy-wake',18,25,30);
             """)

    :ok = Tightbeam.Schema.ensure_wake_row_version(db)
    assert {:ok, [[30]]} = DB.query(db, "SELECT rowVersion FROM wakes WHERE wakeId='legacy-wake'")

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(txn, "UPDATE wakes SET dueAt=21 WHERE wakeId='legacy-wake'")
               :ok
             end)

    assert {:ok, [[31]]} = DB.query(db, "SELECT rowVersion FROM wakes WHERE wakeId='legacy-wake'")
  end

  test "assignment and turn row-version migration backfills once and tracks projected writes" do
    db = :firehose_legacy_direct_apply_versions_db
    start_supervised!({DB, path: ":memory:", name: db})

    assert :ok =
             DB.execute(db, """
             CREATE TABLE assignments (
               id TEXT PRIMARY KEY, subject TEXT, holderKey TEXT, holderRole TEXT,
               holderFallback INTEGER, openedByUser TEXT, openedBySession TEXT,
               openedAt INTEGER, state TEXT, outcome TEXT, closedAt INTEGER,
               closedByUser TEXT, closedBySession TEXT, closedByProcess TEXT,
               closingAttestId TEXT, workItemId TEXT, reviewsAssignmentId TEXT,
               holderHarness TEXT, holderProvider TEXT
             );
             CREATE TABLE assignment_reopenings (assignmentId TEXT, ts INTEGER);
             CREATE TABLE attests (assignmentId TEXT, ts INTEGER);
             CREATE TABLE assignment_commit_ref_corrections (assignmentId TEXT, createdAt INTEGER);
             CREATE TABLE turns (
               seq INTEGER PRIMARY KEY, sessionKey TEXT, messageId TEXT, wakeId TEXT,
               origin TEXT, prompt TEXT, roleRef TEXT, roleFallback INTEGER,
               assignmentId TEXT, jobRef TEXT, model TEXT, thinkingLevel TEXT,
               modelContext TEXT, harness TEXT, replyAttention INTEGER, status TEXT,
               owner TEXT, adapterGen INTEGER, requestRef TEXT, error TEXT,
               createdAt INTEGER, startedAt INTEGER, endedAt INTEGER, publishedAt INTEGER
             );
             INSERT INTO assignments(id,subject,holderKey,openedAt,state)
               VALUES('legacy-assignment','before','holder',10,'open');
             INSERT INTO assignment_reopenings(assignmentId,ts) VALUES('legacy-assignment',30);
             INSERT INTO attests(assignmentId,ts) VALUES('legacy-assignment',40);
             INSERT INTO assignment_commit_ref_corrections(assignmentId,createdAt)
               VALUES('legacy-assignment',50);
             INSERT INTO turns(seq,sessionKey,messageId,origin,prompt,status,createdAt,publishedAt)
               VALUES(5,'holder','message','user:fixture','prompt','delivered',60,80);
             """)

    assert :ok = Tightbeam.Schema.ensure_direct_apply_row_versions(db)

    assert {:ok, [[51]]} =
             DB.query(db, "SELECT rowVersion FROM assignments WHERE id='legacy-assignment'")

    assert {:ok, [[81]]} = DB.query(db, "SELECT rowVersion FROM turns WHERE seq=5")

    assert :ok = Tightbeam.Schema.ensure_direct_apply_row_versions(db)

    assert {:ok, [[51]]} =
             DB.query(db, "SELECT rowVersion FROM assignments WHERE id='legacy-assignment'")

    assert {:ok, [[81]]} = DB.query(db, "SELECT rowVersion FROM turns WHERE seq=5")

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "UPDATE assignments SET subject='after' WHERE id='legacy-assignment'"
               )

               Tightbeam.DB.Txn.q(txn, "UPDATE turns SET publishedAt=81 WHERE seq=5")
               :ok
             end)

    assert {:ok, [[52]]} =
             DB.query(db, "SELECT rowVersion FROM assignments WHERE id='legacy-assignment'")

    assert {:ok, [[82]]} = DB.query(db, "SELECT rowVersion FROM turns WHERE seq=5")
  end

  test "wake retargeting publishes the replacement row" do
    db = :firehose_wake_retarget_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',1,1)")
    register_testhost(db)

    Org.create(db, %{
      session_key: "replacement-target",
      display_name: "Replacement target",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable")
    })

    :ok = Hub.register(Hub, self(), %{mode: :all, db: db, user_id: "flynn", is_admin: true})

    source =
      Wakes.schedule(db, %{
        session_key: "previous-target",
        origin: "user:flynn",
        prompt: "keep this prompt",
        due_at: System.system_time(:millisecond) + 60_000
      })

    assert %{"class" => "wake.scheduled"} = receive_notice()

    assert {:ok, replacement} =
             DB.transaction(db, fn txn ->
               Wakes.retarget_in_txn(txn, source.wake_id, "replacement-target")
             end)

    assert %{
             "class" => "wake.scheduled",
             "resource" => "wakes",
             "op" => "upsert",
             "refs" => %{"wakeId" => wake_id},
             "payload" => %{"sessionKey" => "replacement-target", "prompt" => "keep this prompt"}
           } = receive_notice()

    assert wake_id == replacement.wake_id
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
    expected_item = captured.firehose_before |> Tightbeam.StateResources.role()
    :ok = Tightbeam.Roles.rm(db, "worker")
    :ok = Publisher.accepted(db, captured, %{removed: "worker"})

    assert %{"class" => "verb.accepted"} = receive_notice()

    notice = receive_notice()
    assert notice["class"] == "role.removed"
    assert notice["op"] == "delete"
    assert notice["refs"]["role"] == "worker"
    assert notice["payload"] == expected_item
    assert notice["payload"]["name"] == "worker"
    assert notice["payload"]["rowVersion"] > notice["payload"]["updatedAt"]
    refute Map.has_key?(notice["payload"], "role")
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
    fact = %{id: 4, ts: 100, kind: "ready", scope: "synthetic", origin: "process:fixture"}
    older_fact = Tightbeam.StateResources.condition_fact(fact)
    newer_fact = Tightbeam.StateResources.condition_fact(%{fact | id: 5, ts: 90})

    assert Enum.sort(Map.keys(older_fact)) ==
             Enum.sort(~w(id ts kind scope origin rowVersion))

    assert older_fact["scope"] == "synthetic"
    assert older_fact["origin"] == "process:fixture"
    assert older_fact["id"] == 4
    refute Map.has_key?(older_fact, "factId")

    filed_fact =
      Tightbeam.StateResources.condition_fact(%{
        fact_id: 4,
        ts: 100,
        kind: "ready",
        scope: "synthetic",
        origin: "process:fixture"
      })

    assert filed_fact == older_fact

    assert_raise ArgumentError, ~r/extra or missing field/, fn ->
      Tightbeam.StateResources.condition_fact(Map.delete(fact, :scope))
    end

    assert_raise ArgumentError, ~r/extra or missing field/, fn ->
      Tightbeam.StateResources.condition_fact(Map.put(older_fact, "unexpected", true))
    end

    assert older_fact["id"] == older_fact["rowVersion"]
    assert newer_fact["id"] == newer_fact["rowVersion"]
    assert lww(older_fact, newer_fact) == newer_fact
    assert lww(newer_fact, older_fact) == newer_fact
    assert lww(newer_fact, newer_fact) == newer_fact

    older_assignment = %{"id" => "assignment-a", "rowVersion" => 39, "state" => "closed"}
    held_assignment = %{"id" => "assignment-a", "rowVersion" => 40, "state" => "open"}
    newer_assignment = %{"id" => "assignment-a", "rowVersion" => 41, "state" => "closed"}

    assert lww(held_assignment, older_assignment) == held_assignment
    assert lww(held_assignment, newer_assignment) == newer_assignment
    assert lww(held_assignment, held_assignment) == held_assignment

    db = :firehose_condition_fact_identity_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    assert {:ok, _rows} =
             DB.query(
               db,
               "INSERT INTO condition_facts (id, ts, kind, scope, origin) VALUES (4, 100, 'ready', 'synthetic', 'process:fixture')"
             )

    queried_fact = Tightbeam.StateResources.query_condition_fact(db, 4)
    assert queried_fact == fact

    notice =
      Tightbeam.Firehose.Publisher.committed_notice("condition_fact.filed", queried_fact, %{})

    assert notice["refs"] == %{"factId" => 4}
    assert notice["payload"] == older_fact

    encoded_notice = Tightbeam.Firehose.Publisher.encode_wire_notice(notice, %{})

    assert encoded_notice =~
             ~s("payload":{"id":4,"ts":100,"kind":"ready","scope":"synthetic","origin":"process:fixture","rowVersion":4})

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

    previous_version = canonical.()["rowVersion"]

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.WorkItems.arm_slate_in_txn(txn, item.id)
             end)

    assert %{"class" => "wake.scheduled"} = receive_notice()

    assert %{
             "class" => "work_item.updated",
             "payload" =>
               %{
                 "id" => id,
                 "slateWakeId" => slate_wake_id,
                 "rowVersion" => slate_version
               } = slate_payload
           } = receive_notice()

    assert id == item.id
    assert is_binary(slate_wake_id)
    assert slate_version > previous_version
    assert slate_payload == canonical.()
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
    if candidate["rowVersion"] > current["rowVersion"], do: candidate, else: current
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

  defp observed_classes do
    observed_notices()
    |> Enum.map(& &1["class"])
  end

  defp observed_notices, do: drain_notices()

  defp drain_notices(acc \\ []) do
    _ = :sys.get_state(Hub)

    receive do
      {:firehose_notice, notice} ->
        Hub.delivered(Hub, self())
        drain_notices([notice | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp observed_state_classes do
    observed_classes()
    |> state_classes()
  end

  defp observed_state_notices do
    drain_notices()
    |> Enum.filter(&match?({:ok, _row}, Tightbeam.Firehose.Registry.fetch(&1["class"])))
    |> Enum.group_by(& &1["class"])
  end

  defp assert_substrate_messages_created!(db, expected_messages, expected_batch_assignment_ids) do
    expected_rows =
      Enum.map(expected_messages, fn {session_key, content} ->
        rows =
          db
          |> StateResources.query_messages_for_session(session_key)
          |> Enum.filter(fn row ->
            row.role == "assistant" and row.message_type == "substrate" and
              row.sender == "process:tightbeam" and row.content == content
          end)

        assert [message] = rows
        canonical = StateResources.message(message)

        assert canonical["sessionKey"] == session_key
        assert canonical["messageType"] == "substrate"
        assert canonical["content"] == content
        refute Map.has_key?(canonical, "marker")

        {message, canonical, session_key}
      end)

    notices = drain_notices()
    message_notices = Enum.filter(notices, &(&1["class"] == "message.created"))
    expected_ids = expected_rows |> Enum.map(fn {message, _, _} -> message.id end) |> Enum.sort()
    actual_ids = Enum.map(message_notices, & &1["payload"]["id"])
    extra_ids = actual_ids -- expected_ids

    assert length(actual_ids) == length(Enum.uniq(actual_ids)),
           "duplicate message.created rows: #{inspect(actual_ids)}"

    assert Enum.all?(expected_ids, &(&1 in actual_ids))

    Enum.each(message_notices, fn notice ->
      message_id = notice["payload"]["id"]
      row = StateResources.query_message(db, message_id)
      assert row
      canonical = StateResources.message(row)

      assert notice["refs"]["messageId"] == message_id
      assert notice["refs"]["sessionKey"] == row.session_key
      assert notice["refs"]["ownerUserId"] == "flynn"
      assert notice["payload"] == canonical
      assert JSON.decode!(Publisher.encode_wire_notice(notice))["payload"] == canonical

      if message_id in extra_ids do
        assert_batched_attest_message!(db, row, expected_batch_assignment_ids)
      end

      item_bytes = StateResources.encode_item("transcript messages", canonical)

      assert String.contains?(
               Publisher.encode_wire_notice(notice),
               "\"payload\":" <> item_bytes
             )
    end)

    {notices, actual_ids}
  end

  defp assert_batched_attest_message!(db, row, expected_assignment_ids) do
    assert row.session_key == Org.personal_session_key("flynn")
    assert row.role == "user"
    assert row.message_type == "substrate"
    assert row.sender == "process:tightbeam"

    prefix = "[from process:tightbeam]\n\n"
    assert String.starts_with?(row.content, prefix)
    envelope = String.replace_prefix(row.content, prefix, "")

    assert [batch_id] =
             Regex.run(~r/^\[batched notices: \d+\]\nbatchId=(nb_[0-9a-f-]+) /, envelope,
               capture: :all_but_first
             )

    batch = NoticeBatcher.batch(db, batch_id)
    assert batch
    assert batch.session_key == row.session_key
    assert batch.envelope == envelope

    members = NoticeBatcher.members(db, batch_id)
    assert length(members) == batch.member_count
    assert members != []

    Enum.each(members, fn member ->
      wake = Wakes.get(db, member.source_wake_id)
      assert wake
      assert wake.session_key == row.session_key
      assert wake.origin == member.sender_principal
      assert wake.prompt == member.payload
      assert wake.assignment_id in expected_assignment_ids
      assert member.class == "fyi"
      assert member.state == "included"

      assert [attest_id, kind, assignment_id] =
               Regex.run(
                 ~r/^Attest (att_[A-Za-z0-9-]+) \(([^)]+)\) was filed on assignment (asg_[A-Za-z0-9-]+)\.$/,
                 member.payload,
                 capture: :all_but_first
               )

      assert assignment_id == wake.assignment_id

      assert Enum.any?(Tightbeam.Assignments.list_attests(db, assignment_id), fn attest ->
               attest.id == attest_id and attest.kind == kind
             end)
    end)
  end

  defp notice_state_classes({notices, message_ids}) do
    notices
    |> Enum.reject(fn notice ->
      notice["class"] == "message.created" and notice["payload"]["id"] in message_ids
    end)
    |> Enum.map(& &1["class"])
    |> state_classes()
  end

  defp state_classes(classes) do
    Enum.filter(classes, &match?({:ok, _row}, Tightbeam.Firehose.Registry.fetch(&1)))
  end

  defp finish_next_turn!(db, session_key, lane) do
    {:ok, turn} = Ledger.claim_next(db, session_key, lane)

    :ok =
      Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

    # Turn lifecycle effects belong to the test's explicit queue drain, not
    # to the handler effect set asserted by the surrounding matrix case.
    _ = observed_state_classes()

    turn
  end

  defp start_delivery_scheduler(db) do
    name = String.to_atom("firehose_batch_delivery_#{System.unique_integer([:positive])}")

    start_supervised!(
      Supervisor.child_spec(
        {Wakes,
         db: db,
         name: name,
         tick_ms: 60_000,
         deliver: fn wake ->
           {:ok, delivery} =
             DB.transaction(db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 wake.session_key,
                 wake.origin,
                 wake.prompt,
                 wake_id: wake.wake_id,
                 sender: wake.origin,
                 target_gate: wake,
                 fire_wake_in_txn: true
               )
             end)

           Gateway.complete_delivery(db, delivery)
         end},
        id: name
      )
    )

    name
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

  defp pending_decision_notice!(db, request_id) do
    assert {:ok, [[wake_id]]} =
             DB.query(
               db,
               "SELECT wakeId FROM wakes WHERE consumer='prompt' AND state='pending' AND obligationRef=?1",
               [Wakes.decision_request_notice_ref(request_id)]
             )

    wake_id
  end

  defp assert_decision_notice_cleared!(db, request_id, wake_id) do
    cancellation = receive_notice()
    assert cancellation["class"] == "wake.canceled"
    assert cancellation["refs"]["wakeId"] == wake_id
    assert cancellation["payload"]["state"] == "canceled"
    assert %{state: "canceled", fired_at: nil} = Wakes.get(db, wake_id)

    assert {:ok,
            [
              [
                "process",
                "tightbeam:escalation",
                "obligation_disposed",
                "decision_request",
                ^request_id,
                "disposition",
                "decision_request_transition",
                ^request_id
              ]
            ]} =
             DB.query(
               db,
               "SELECT requesterKind,requesterId,reasonKind,causalSourceKind,causalSourceId,outcomeKind,dispositionKind,dispositionId FROM wake_cancellations WHERE wakeId=?1",
               [wake_id]
             )
  end

  defp receive_notice do
    assert_receive {:firehose_notice, notice}
    Hub.delivered(Hub, self())
    notice
  end

  defp rest_get(path, token, opts) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(Router.init(opts))
  end
end
