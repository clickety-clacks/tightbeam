defmodule Tightbeam.EscalationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    ConditionFacts,
    ConnRegistry,
    DB,
    Devices,
    Escalation,
    EventLog,
    Gateway,
    Org,
    Wakes
  }

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, session_key}, _from, parent) do
      send(parent, {:lane_nudged, session_key})
      {:reply, :ok, parent}
    end
  end

  setup do
    db = :"escalation_db_#{System.unique_integer([:positive])}"
    scheduler = :"escalation_scheduler_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = ensure_all_schemas(db)

    raiser = session(db, "raiser", "flynn")

    _admin_device =
      Devices.pair(db, %{
        device_id: "admin-device",
        claimed_name: "flynn",
        platform: nil,
        model: nil
      })

    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    start_supervised!(
      {Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: fn _wake -> :ok end}
    )

    %{db: db, scheduler: scheduler, raiser: raiser}
  end

  test "resolve exposes all four shapes without mutating, and consume wins once", ctx do
    call = call(ctx.raiser, %{assignment_id: "a1", kind: "completion"})
    statute = statute()

    assert {:needs_request, nil} = Escalation.resolve(ctx.db, call, statute)
    {:decision_pending, id} = open(ctx, call, statute)
    assert {:needs_request, ^id} = Escalation.resolve(ctx.db, call, statute)

    assert %{status: "ruled"} =
             Escalation.rule(ctx.db, rule_call(id, "allow"),
               authorized: true,
               scheduler: ctx.scheduler
             )

    assert {:allow, ^id} = Escalation.resolve(ctx.db, call, statute)
    assert request(ctx, id).status == "ruled"
    assert Escalation.consume(ctx.db, id)
    refute Escalation.consume(ctx.db, id)
    assert {:needs_request, nil} = Escalation.resolve(ctx.db, call, statute)

    reruled =
      Escalation.rule(ctx.db, rule_call(id, "allow"),
        authorized: true,
        scheduler: ctx.scheduler
      )

    assert reruled.status == "consumed"
    assert reruled.decision == "allow"

    assert Enum.count(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "decision_request_ruled" and event.subject == id
           end) == 1

    {:decision_pending, denied_id} = open(ctx, call, statute)
    Escalation.rule(ctx.db, rule_call(denied_id, "deny"), authorized: true)
    assert {:deny, %{code: "escalation_denied"}} = Escalation.resolve(ctx.db, call, statute)
  end

  test "concurrent nil-branch racers return the one partial-index winner", ctx do
    call = call(ctx.raiser, %{assignment_id: "a-race", kind: "completion"})
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, :started)
          Escalation.escalate(ctx.db, call, statute(), escalation_ctx())
        end)
      end

    for _ <- 1..8, do: assert_receive(:started)
    ids = tasks |> Task.await_many() |> Enum.map(fn {:decision_pending, id} -> id end)
    assert [_] = Enum.uniq(ids)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE status = 'open'")

    assert Enum.count(EventLog.lifecycle_events(ctx.db), &(&1.kind == "decision_request_opened")) ==
             1

    id = hd(ids)

    assert {:decision_pending, ^id} =
             Escalation.escalate(ctx.db, call, statute(), Map.put(escalation_ctx(), :dr_id, id))
  end

  test "owner delivery is one durable wake armed with the open transaction", ctx do
    parent = self()
    call = call(ctx.raiser, %{assignment_id: "a-delivery", kind: "completion"})
    owner_session = Org.personal_session_key("flynn")

    {:decision_pending, id} = Escalation.escalate(ctx.db, call, statute(), escalation_ctx())

    # The notification is committed WITH the request: pending, ungated, carrying
    # the owner prompt — and nothing has been delivered yet.
    assert [%{session_key: ^owner_session, target_gate: 0, state: "pending"} = wake] =
             notification_wakes(ctx)

    assert wake.prompt =~ "Decision #{id} pending on review."
    assert wake.prompt =~ "Allow this action?"
    assert request(ctx, id).status == "open"
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")

    # Delivery is the ordinary prompt consumer, strictly after the commit.
    deliverer = :"escalation_deliverer_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Wakes,
       db: ctx.db,
       name: deliverer,
       tick_ms: 60_000,
       deliver: fn fired ->
         send(parent, {:delivered, fired.session_key, id, request(ctx, id).status})
       end},
      id: deliverer
    )

    :ok = Wakes.fire_due(deliverer)
    assert_receive {:delivered, ^owner_session, ^id, "open"}
    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"

    # A decision-pending replay arms nothing and redelivers nothing.
    assert {:decision_pending, ^id} =
             Escalation.escalate(
               ctx.db,
               call,
               statute(),
               Map.put(escalation_ctx(), :dr_id, id)
             )

    assert Enum.map(notification_wakes(ctx), & &1.wake_id) == [wake.wake_id]
    :ok = Wakes.fire_due(deliverer)
    refute_receive {:delivered, _, _, _}
  end

  test "digest drops note and idempotency key but changes for effect-bearing params", ctx do
    base = call(ctx.raiser, %{assignment_id: "a2", kind: "completion"})

    reissue =
      call(ctx.raiser, %{
        assignment_id: "a2",
        kind: "completion",
        note: "annotation",
        idempotency_key: "wire-2"
      })

    assert Escalation.digest(base) == Escalation.digest(reissue)

    refute Escalation.digest(base) ==
             Escalation.digest(call(ctx.raiser, %{assignment_id: "a2", kind: "progress"}))
  end

  test "request deadlines use the configured escalation decision interval", ctx do
    previous = Application.get_env(:tightbeam, :escalation_decision_deadline_ms)
    Application.put_env(:tightbeam, :escalation_decision_deadline_ms, 12_345)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :escalation_decision_deadline_ms),
        else: Application.put_env(:tightbeam, :escalation_decision_deadline_ms, previous)
    end)

    before_open = System.system_time(:millisecond)
    {:decision_pending, id} = open(ctx, call(ctx.raiser, %{assignment_id: "deadline"}), statute())
    after_open = System.system_time(:millisecond)

    deadline_at = request(ctx, id).deadline_at
    assert deadline_at >= before_open + 12_345
    assert deadline_at <= after_open + 12_345
  end

  test "rule uses admin axis, closed decisions, idempotent re-rule, and wakes on its reserved fact",
       ctx do
    call = call(ctx.raiser, %{assignment_id: "a3", kind: "completion"})
    {:decision_pending, id} = open(ctx, call, statute())

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.raiser.session_key,
        origin: "agent:raiser",
        prompt: "re-adjudicate",
        due_at: System.system_time(:millisecond) + 60_000,
        condition_kind: "escalation-ruled",
        condition_scope: id,
        creator_session_key: ctx.raiser.session_key
      })

    handlers = Gateway.handlers(%{db: ctx.db, wake_scheduler: ctx.scheduler})

    assert %{code: "not_owner"} =
             handlers["rule"].(%{
               origin: "process:cron",
               principal: {:process, "cron"},
               params: %{request_id: id, decision: "allow"}
             })

    assert %{code: "invalid_decision"} =
             handlers["rule"].(%{
               origin: "user:flynn",
               principal: {:user, "flynn"},
               params: %{request_id: id, decision: "later"}
             })

    ruled = handlers["rule"].(rule_call(id, "allow"))
    assert ruled.status == "ruled"
    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"
    assert_receive {:lane_nudged, _}

    assert handlers["rule"].(rule_call(id, "allow")).ruling_fact_id == ruled.ruling_fact_id
    assert %{code: "not_open"} = handlers["rule"].(rule_call(id, "deny"))

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind = 'escalation-ruled' AND scope = ?1 AND origin = 'process:tightbeam'",
               [id]
             )

    assert Enum.count(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "decision_request_ruled" and event.subject == id
           end) == 1
  end

  test "request waiver resolves all opens, live waiver allows, and revoke is prospective", ctx do
    statute = statute()
    first_call = call(ctx.raiser, %{assignment_id: "a4", kind: "completion"})
    second_call = call(ctx.raiser, %{assignment_id: "a4", kind: "progress"})
    {:decision_pending, first} = open(ctx, first_call, statute)
    {:decision_pending, second} = open(ctx, second_call, statute)

    first_wake = ruling_wake(ctx, first)
    second_wake = ruling_wake(ctx, second)

    waiver =
      Escalation.waive(
        ctx.db,
        %{origin: "user:flynn", principal: {:user, "flynn"}, params: %{request_id: first}},
        authorized: true,
        scheduler: ctx.scheduler
      )

    assert request(ctx, first).decision == "waived"
    assert request(ctx, second).decision == "waived"
    # The eager path fires per filed fact (wake-on-fact-v1 §candidate query:
    # `f.id = :factId`), and waive nudges once per ruling fact — so BOTH
    # ruling wakes fire eagerly. (The old latest-fact-only pending state was
    # an artifact of the broadcast MAX(id) approximation.)
    assert Wakes.get(ctx.db, second_wake.wake_id).state == "fired"
    assert Wakes.get(ctx.db, first_wake.wake_id).state == "fired"

    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, first_wake.wake_id).state == "fired"
    assert :allow = Escalation.resolve(ctx.db, first_call, statute)

    assert %{revoked_at: revoked_at} =
             Escalation.revoke_waiver(
               ctx.db,
               %{
                 origin: "user:flynn",
                 principal: {:user, "flynn"},
                 params: %{waiver_id: waiver.id}
               },
               authorized: true
             )

    assert is_integer(revoked_at)
    assert {:needs_request, nil} = Escalation.resolve(ctx.db, first_call, statute)
    assert request(ctx, first).decision == "waived"

    {:decision_pending, fresh} = open(ctx, first_call, statute)
    refute fresh in [first, second]
  end

  test "a retired session raiser's unswept waiver is not consulted", ctx do
    call = call(ctx.raiser, %{assignment_id: "a-retired-waiver", kind: "completion"})
    {:decision_pending, id} = open(ctx, call, statute())

    Escalation.waive(
      ctx.db,
      %{origin: "user:flynn", principal: {:user, "flynn"}, params: %{request_id: id}},
      authorized: true
    )

    assert :allow = Escalation.resolve(ctx.db, call, statute())

    Org.retire(ctx.db, ctx.raiser.session_key, "user:flynn", 1_000)

    assert {:needs_request, nil} = Escalation.resolve(ctx.db, call, statute())

    assert {:ok, [[nil]]} =
             DB.query(
               ctx.db,
               "SELECT revokedAt FROM escalation_waivers WHERE raiserId = ?1",
               ["session:" <> ctx.raiser.session_key]
             )
  end

  test "withdrawal is raiser-only and retirement sweeps requests and waivers", ctx do
    call = call(ctx.raiser, %{assignment_id: "a5", kind: "completion"})
    {:decision_pending, id} = open(ctx, call, statute())

    assert %{code: "not_raiser"} =
             Escalation.withdraw(ctx.db, %{
               origin: "user:flynn",
               principal: {:user, "flynn"},
               params: %{request_id: id, reason: "no"}
             })

    assert %{status: "withdrawn", withdrawn_reason: "changed course"} =
             Escalation.withdraw(ctx.db, %{
               origin: "agent:raiser",
               principal: {:session, ctx.raiser.session_key},
               params: %{request_id: id, reason: "changed course"}
             })

    {:decision_pending, fresh} = open(ctx, call, statute())

    waiver =
      Escalation.waive(
        ctx.db,
        %{
          origin: "user:flynn",
          principal: {:user, "flynn"},
          params: %{session_key: ctx.raiser.session_key, statute_name: "review"}
        },
        authorized: true
      )

    :ok = Escalation.withdraw_for_retired(ctx.db, ctx.raiser.session_key)
    assert request(ctx, fresh).withdrawn_reason == "raiser-retired"

    assert {:ok, [["process:tightbeam"]]} =
             DB.query(ctx.db, "SELECT revokedBy FROM escalation_waivers WHERE id = ?1", [
               waiver.id
             ])
  end

  test "boot recovery catches a retired session and read surfaces enforce owner or raiser", ctx do
    call = call(ctx.raiser, %{assignment_id: "a6", kind: "completion"})
    {:decision_pending, id} = open(ctx, call, statute())

    unrelated = %{origin: "user:other", principal: {:user, "other"}, params: %{}}
    assert [] = Escalation.list(ctx.db, unrelated, nil, owner_user_id: "other")
    assert nil == Escalation.get(ctx.db, unrelated, id, owner_user_id: "other")

    assert [%{id: ^id}] = Escalation.list(ctx.db, call, "open")
    assert %{id: ^id, context: %{"verb" => "attest"}} = Escalation.get(ctx.db, call, id)

    Org.retire(ctx.db, ctx.raiser.session_key, "user:flynn", 1_000)
    :ok = Escalation.recover_retired(ctx.db)
    assert request(ctx, id).status == "withdrawn"
  end

  test "list status filter: 'all' returns every status, each legal status filters to its own",
       ctx do
    {:decision_pending, open_id} =
      open(ctx, call(ctx.raiser, %{assignment_id: "s-open", kind: "completion"}), statute())

    {:decision_pending, ruled_id} =
      open(ctx, call(ctx.raiser, %{assignment_id: "s-ruled", kind: "completion"}), statute())

    Escalation.rule(ctx.db, rule_call(ruled_id, "allow"), authorized: true)

    {:decision_pending, consumed_id} =
      open(ctx, call(ctx.raiser, %{assignment_id: "s-consumed", kind: "completion"}), statute())

    Escalation.rule(ctx.db, rule_call(consumed_id, "allow"), authorized: true)
    assert Escalation.consume(ctx.db, consumed_id)

    all_call = call(ctx.raiser, %{})

    # "all" and nil both mean no status filter — every one of the three rows is visible.
    ids = fn status ->
      ctx.db |> Escalation.list(all_call, status) |> Enum.map(& &1.id) |> Enum.sort()
    end

    assert ids.("all") == Enum.sort([open_id, ruled_id, consumed_id])
    assert ids.(nil) == Enum.sort([open_id, ruled_id, consumed_id])

    # Each concrete status filters to exactly the rows in that status — the regression:
    # before the fix, "all" filtered on the literal 'all' and returned nothing.
    assert ids.("open") == [open_id]
    assert ids.("ruled") == [ruled_id]
    assert ids.("consumed") == [consumed_id]

    # Legal statuses with no matching rows return empty, not an error.
    assert ids.("withdrawn") == []
    assert ids.("superseded") == []
  end

  test "list_status validates the filter: defaults, passthrough, and a named refusal", _ctx do
    assert {:ok, "open"} = Escalation.list_status(nil)
    assert {:ok, "all"} = Escalation.list_status("all")

    for status <- ~w(open ruled consumed withdrawn superseded) do
      assert {:ok, ^status} = Escalation.list_status(status)
    end

    assert %{code: "invalid", message: message} = Escalation.list_status("bogus")
    assert message =~ "bogus"
    assert message =~ "open, ruled, consumed, withdrawn, superseded, all"
  end

  test "non-session raisers use the origin domain and option labels resolve to effects", ctx do
    call = %{
      verb: "attest",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{assignment_id: "a-origin", kind: "completion"}
    }

    {:decision_pending, id} =
      Escalation.escalate(ctx.db, call, statute(), %{
        question: "Choose",
        options: [%{"label" => "ship", "effect" => "allow"}]
      })

    assert %{raiser_id: "user:flynn", raiser_session_key: nil} =
             Escalation.get(ctx.db, call, id)

    assert %{decision: "allow"} =
             Escalation.rule(
               ctx.db,
               %{
                 origin: "user:other-admin",
                 principal: {:user, "other-admin"},
                 params: %{request_id: id, decision: "ship"}
               },
               authorized: true
             )

    assert {:allow, ^id} = Escalation.resolve(ctx.db, call, statute())

    withdraw_call = put_in(call, [:params, :kind], "progress")
    {:decision_pending, withdraw_id} = open(ctx, withdraw_call, statute())

    assert %{code: "not_raiser"} =
             Escalation.withdraw(ctx.db, %{
               origin: "user:other",
               principal: {:user, "other"},
               params: %{request_id: withdraw_id, reason: "wrong raiser"}
             })

    assert %{status: "withdrawn"} =
             Escalation.withdraw(ctx.db, %{
               origin: "user:flynn",
               principal: {:user, "flynn"},
               params: %{request_id: withdraw_id, reason: "changed course"}
             })

    waiver_call = put_in(call, [:params, :kind], "verdict")
    {:decision_pending, waiver_request_id} = open(ctx, waiver_call, statute())

    waiver =
      Escalation.waive(
        ctx.db,
        %{
          origin: "user:other-admin",
          principal: {:user, "other-admin"},
          params: %{request_id: waiver_request_id}
        },
        authorized: true
      )

    :ok = Escalation.withdraw_for_retired(ctx.db, ctx.raiser.session_key)
    assert Escalation.get(ctx.db, call, id).status == "ruled"
    assert :allow = Escalation.resolve(ctx.db, waiver_call, statute())

    assert %{revoked_at: revoked_at} =
             Escalation.revoke_waiver(
               ctx.db,
               %{
                 origin: "user:other-admin",
                 principal: {:user, "other-admin"},
                 params: %{waiver_id: waiver.id}
               },
               authorized: true
             )

    assert is_integer(revoked_at)
  end

  test "decision request options require labels with allow or deny effects", ctx do
    call = call(ctx.raiser, %{assignment_id: "a-options", kind: "completion"})

    assert_raise ArgumentError, "options must contain label and allow|deny effect", fn ->
      Escalation.escalate(ctx.db, call, statute(), %{
        question: "Choose",
        options: [%{"label" => "later", "effect" => "defer"}]
      })
    end

    assert_raise ArgumentError, "options must contain label and allow|deny effect", fn ->
      Escalation.escalate(ctx.db, call, statute(), %{
        question: "Choose",
        options: [%{"effect" => "allow"}]
      })
    end

    {:decision_pending, id} =
      Escalation.escalate(ctx.db, call, statute(), %{
        question: "Choose",
        options: [%{label: "ship", effect: "allow"}, %{label: "stop", effect: "deny"}]
      })

    assert request(ctx, id).options == [
             %{"label" => "ship", "effect" => "allow"},
             %{"label" => "stop", "effect" => "deny"}
           ]
  end

  test "operator ask normalizes, owner-scopes, structurally dedupes, and arms one opportunity",
       ctx do
    before_open = System.system_time(:millisecond)

    call =
      operator_call(ctx.raiser, %{
        question: "  ship window?  ",
        note: "  release train  ",
        options: [%{label: " accept "}, %{"label" => "wait"}],
        deadline: 12_345
      })

    request = Escalation.operator_ask(ctx.db, call)

    assert %{
             kind: "operator",
             status: "open",
             owner_user_id: "flynn",
             raiser_id: "agent:raiser",
             raiser_session_key: raiser_key,
             question: "ship window?",
             options: [%{"label" => "accept"}, %{"label" => "wait"}],
             context: %{"note" => "release train", "supersedes" => nil},
             deadline_wake_id: nil,
             ruled_via_session_key: nil
           } = request

    assert raiser_key == ctx.raiser.session_key
    assert request.deadline_at >= before_open + 12_345

    assert [%{session_key: main_key, target_gate: 0, state: "pending"} = wake] =
             notification_wakes(ctx)

    assert main_key == Org.personal_session_key("flynn")
    assert wake.prompt =~ request.id
    assert wake.prompt =~ "ship window?"

    replay =
      operator_call(ctx.raiser, %{
        question: "ship window?",
        note: "release train",
        options: [%{"label" => "accept"}, %{"label" => "wait"}],
        deadline: 99_999
      })

    assert %{id: id, deadline_at: deadline_at} = Escalation.operator_ask(ctx.db, replay)
    assert id == request.id
    assert deadline_at == request.deadline_at
    assert length(notification_wakes(ctx)) == 1

    defaulted =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "defaults?"}))

    explicit_defaults =
      Escalation.operator_ask(
        ctx.db,
        operator_call(ctx.raiser, %{
          question: "defaults?",
          options: [%{label: "accept"}, %{label: "dismiss"}]
        })
      )

    assert explicit_defaults.id == defaulted.id

    assert %{code: "invalid"} =
             Escalation.operator_ask(ctx.db, %{
               origin: "user:flynn",
               principal: {:user, "flynn"},
               params: %{question: "not session-filed"}
             })

    assert %{code: "invalid"} =
             Escalation.operator_ask(
               ctx.db,
               operator_call(ctx.raiser, %{question: " ", options: []})
             )

    assert %{code: "invalid"} =
             Escalation.operator_ask(
               ctx.db,
               operator_call(ctx.raiser, %{
                 question: "no statute effects",
                 options: [%{label: "accept", effect: "allow"}]
               })
             )

    assert Enum.count(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "decision_request_opened" and event.subject == request.id
           end) == 1
  end

  test "operator ask validates linked assignment ownership in the winning transaction", ctx do
    other = session(ctx.db, "other-holder", "other")
    insert_assignment!(ctx.db, "a-owned", ctx.raiser.session_key, "open")
    insert_assignment!(ctx.db, "a-foreign", other.session_key, "open")
    insert_assignment!(ctx.db, "a-closed", ctx.raiser.session_key, "closed")

    assert %{assignment_id: "a-owned"} =
             Escalation.operator_ask(
               ctx.db,
               operator_call(ctx.raiser, %{question: "owned?", assignment: "a-owned"})
             )

    assert %{code: "not_owner"} =
             Escalation.operator_ask(
               ctx.db,
               operator_call(ctx.raiser, %{question: "foreign?", assignment: "a-foreign"})
             )

    assert %{code: "not_open"} =
             Escalation.operator_ask(
               ctx.db,
               operator_call(ctx.raiser, %{question: "closed?", assignment: "a-closed"})
             )

    assert %{code: "not_found"} =
             Escalation.operator_ask(
               ctx.db,
               operator_call(ctx.raiser, %{question: "missing?", assignment: "a-missing"})
             )

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM decision_requests WHERE kind='operator'")
  end

  test "ruled operator list and exact reads share the complete terminal projection", ctx do
    {:decision_pending, statute_id} =
      open(ctx, call(ctx.raiser, %{assignment_id: "operator-wrong-kind"}), statute())

    assert %{code: "invalid"} =
             Escalation.operator_rule(
               ctx.db,
               owner_operator_rule(statute_id, %{decision: "allow"})
             )

    direct =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "ship?"}))

    main_rule =
      owner_operator_rule(direct.id, %{decision: "accept"})
      |> Map.put(:transport_session_key, Org.personal_session_key("flynn"))

    assert %{code: "proxy_only"} = Escalation.operator_rule(ctx.db, main_rule)

    assert %{code: "not_owner"} =
             Escalation.operator_rule(ctx.db, %{
               origin: "user:flynn",
               principal: {:session, Org.personal_session_key("flynn")},
               transport_session_key: Org.personal_session_key("flynn"),
               params: %{request: direct.id, decision: "accept"}
             })

    assert %{code: "not_owner"} =
             Escalation.operator_rule(ctx.db, %{
               origin: "user:other",
               principal: {:user, "other"},
               transport_session_key: nil,
               params: %{request: direct.id, decision: "accept"}
             })

    assert %{code: "invalid_decision"} =
             Escalation.operator_rule(
               ctx.db,
               owner_operator_rule(direct.id, %{decision: "later"})
             )

    assert %{code: "invalid"} =
             Escalation.operator_rule(
               ctx.db,
               owner_operator_rule(direct.id, %{decision: "accept", response: "yes"})
             )

    ruled =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(direct.id, %{decision: "accept"}),
        scheduler: ctx.scheduler
      )

    assert ruled.status == "ruled"
    assert ruled.decision == "accept"
    assert ruled.ruled_by == "user:flynn"
    assert ruled.ruled_via_session_key == nil
    assert ruled.rationale == nil
    assert ruled.consumed_at == nil

    assert ruled.ruling_attribution == %{
             on_behalf_of: "user:flynn",
             performer: %{
               principal: %{state: "known", value: "user:flynn"},
               session: %{state: "none"}
             }
           }

    assert is_integer(ruled.ruling_fact_id)
    refute Escalation.consume(ctx.db, direct.id)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE id=?1 AND kind='escalation-ruled' AND scope=?2",
               [ruled.ruling_fact_id, direct.id]
             )

    expected_prompt =
      "Decision request #{direct.id} was ruled. Read it with tightbeam decision-request --request #{direct.id}."

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE sessionKey=?1 AND origin='process:tightbeam' AND prompt=?2 AND conditionKind='escalation-ruled' AND conditionScope=?3 AND conditionAfterId < ?4 AND targetGate=0",
               [ctx.raiser.session_key, expected_prompt, direct.id, ruled.ruling_fact_id]
             )

    assert {:ok, [[wake_id, "fired", "condition"]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId, state, firedBy FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1",
               [direct.id]
             )

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake_id])

    [listed] = Escalation.list(ctx.db, operator_call(ctx.raiser, %{}), "ruled")
    detailed = Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), direct.id)

    parity_fields = [
      :id,
      :kind,
      :status,
      :question,
      :options,
      :raiser_id,
      :raiser_session_key,
      :owner_user_id,
      :assignment_id,
      :raised_at,
      :deadline_at,
      :decision,
      :rationale,
      :ruled_by,
      :ruled_via_session_key,
      :ruled_at,
      :ruling_fact_id,
      :consumed_at,
      :ruling_attribution
    ]

    assert Map.take(listed, parity_fields) == Map.take(detailed, parity_fields)
    assert Map.keys(Map.take(listed, parity_fields)) |> Enum.sort() == Enum.sort(parity_fields)
    assert detailed.context == %{"note" => nil, "supersedes" => nil}
    assert is_binary(detailed.action_key)

    refiled =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "ship?"}))

    refute refiled.id == direct.id

    replay =
      Escalation.operator_rule(ctx.db, owner_operator_rule(direct.id, %{response: "accept"}))

    assert replay.id == ruled.id
    assert replay.ruling_fact_id == ruled.ruling_fact_id

    assert %{code: "not_open"} =
             Escalation.operator_rule(
               ctx.db,
               owner_operator_rule(direct.id, %{response: "different"})
             )

    assert %{code: "invalid"} =
             Escalation.rule(ctx.db, owner_operator_rule(direct.id, %{decision: "accept"}),
               authorized: true
             )

    assert %{code: "invalid"} =
             Escalation.waive(ctx.db, owner_operator_rule(direct.id, %{decision: "accept"}),
               authorized: true
             )
  end

  test "presenting session is preserved beside the performing principal", ctx do
    request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "relay?"}))

    relay_call =
      owner_operator_rule(request.id, %{
        response: "  yes, after 013  ",
        rationale: "  ordered  "
      })
      |> Map.put(:transport_session_key, ctx.raiser.session_key)

    assert %{
             decision: "yes, after 013",
             rationale: "ordered",
             ruled_via_session_key: relay_key
           } = Escalation.operator_rule(ctx.db, relay_call)

    assert relay_key == ctx.raiser.session_key

    assert Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), request.id).ruling_attribution ==
             %{
               on_behalf_of: "user:flynn",
               performer: %{
                 principal: %{state: "known", value: "user:flynn"},
                 session: %{state: "known", key: ctx.raiser.session_key}
               }
             }
  end

  test "visible impossible terminal shape refuses and records privacy-safe evidence", ctx do
    request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "integrity?"}))

    ruled =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(request.id, %{decision: "accept"}),
        scheduler: ctx.scheduler
      )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (?1, 'decision_request_ruled', ?2, NULL)",
               [System.system_time(:millisecond), request.id]
             )

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE decision_requests SET options='not-json' WHERE id=?1", [
               request.id
             ])

    foreign = session(ctx.db, "integrity-foreign", "other")
    assert [] = Escalation.list(ctx.db, operator_call(foreign, %{}), "ruled")
    assert nil == Escalation.get(ctx.db, operator_call(foreign, %{}), request.id)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM decision_request_integrity_evidence WHERE requestId=?1",
               [request.id]
             )

    assert %{
             code: "decision_request_integrity_invalid",
             message: "decision request integrity check failed",
             request_id: request_id
           } = Escalation.list(ctx.db, operator_call(ctx.raiser, %{}), "ruled")

    assert request_id == request.id

    assert {:ok, [[1, shape_digest, fields, cause, surface, observer]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*), MIN(shapeDigest), MIN(failingFields), MIN(causeCode), MIN(firstSurface), MIN(observerPrincipal) FROM decision_request_integrity_evidence WHERE requestId=?1",
               [request.id]
             )

    assert shape_digest =~ ~r/^[0-9a-f]{64}$/
    assert {:ok, failures} = JSON.decode(fields)
    assert "rulingLifecycleEvent" in failures
    assert "options" in failures
    assert cause == "terminal-shape-invalid"
    assert surface == "list"
    assert observer == "session:#{ctx.raiser.session_key}"
    refute fields =~ "integrity?"

    assert shape_digest == "efa9964d4e3857fc094f9b699b19ac1feb91a30b439236e05572b483cb886403"
    assert ruled.ruling_fact_id > 0
  end

  test "integrity descriptor and digest are stable across private values and surfaces", ctx do
    requests =
      for question <- ["private alpha?", "private beta?"] do
        request =
          Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: question}))

        _ruled =
          Escalation.operator_rule(
            ctx.db,
            owner_operator_rule(request.id, %{decision: "accept"})
          )

        assert {:ok, _} =
                 DB.query(
                   ctx.db,
                   "DELETE FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject=?1",
                   [request.id]
                 )

        assert %{code: "decision_request_integrity_invalid"} =
                 Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), request.id)

        request
      end

    assert %{code: "decision_request_integrity_invalid"} =
             Escalation.list(ctx.db, operator_call(ctx.raiser, %{}), "ruled")

    assert {:ok, [[shared_digest, fields], [shared_digest, fields]]} =
             DB.query(
               ctx.db,
               "SELECT shapeDigest,failingFields FROM decision_request_integrity_evidence WHERE requestId IN (?1,?2) ORDER BY requestId",
               Enum.map(requests, & &1.id)
             )

    assert JSON.decode!(fields) == ["rulingLifecycleEvent"]
    assert String.match?(shared_digest, ~r/^[0-9a-f]{64}$/)
  end

  test "integrity descriptor covers member shape equalities states and relation cardinalities",
       ctx do
    options_request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "options shape?"}))

    _ruled =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(options_request.id, %{decision: "accept"})
      )

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE decision_requests SET options='not-json' WHERE id=?1", [
               options_request.id
             ])

    assert %{code: "decision_request_integrity_invalid"} =
             Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), options_request.id)

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE decision_requests SET options='[]' WHERE id=?1", [
               options_request.id
             ])

    assert %{code: "decision_request_integrity_invalid"} =
             Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), options_request.id)

    assert {:ok, [[2, 2, 1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*), COUNT(DISTINCT shapeDigest), COUNT(DISTINCT failingFields) FROM decision_request_integrity_evidence WHERE requestId=?1",
               [options_request.id]
             )

    fact_request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "fact shape?"}))

    ruled =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(fact_request.id, %{decision: "accept"})
      )

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE condition_facts SET kind='wrong-kind' WHERE id=?1", [
               ruled.ruling_fact_id
             ])

    assert %{code: "decision_request_integrity_invalid"} =
             Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), fact_request.id)

    assert {:ok, _} =
             DB.query(ctx.db, "DELETE FROM condition_facts WHERE id=?1", [ruled.ruling_fact_id])

    assert %{code: "decision_request_integrity_invalid"} =
             Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), fact_request.id)

    assert {:ok, [[2, 2, 1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*), COUNT(DISTINCT shapeDigest), COUNT(DISTINCT failingFields) FROM decision_request_integrity_evidence WHERE requestId=?1",
               [fact_request.id]
             )
  end

  test "distinct structural terminal failures produce distinct canonical digests", ctx do
    empty_decision =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "empty decision?"}))

    blank_decision =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "blank decision?"}))

    for request <- [empty_decision, blank_decision] do
      _ruled =
        Escalation.operator_rule(
          ctx.db,
          owner_operator_rule(request.id, %{decision: "accept"})
        )
    end

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE decision_requests SET decision='' WHERE id=?1", [
               empty_decision.id
             ])

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE decision_requests SET decision='   ' WHERE id=?1", [
               blank_decision.id
             ])

    for request <- [empty_decision, blank_decision] do
      assert %{code: "decision_request_integrity_invalid"} =
               Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), request.id)
    end

    assert {:ok, [[first_digest, fields], [second_digest, fields]]} =
             DB.query(
               ctx.db,
               "SELECT shapeDigest,failingFields FROM decision_request_integrity_evidence WHERE requestId IN (?1,?2) ORDER BY requestId",
               [empty_decision.id, blank_decision.id]
             )

    assert JSON.decode!(fields) == ["decision"]
    refute first_digest == second_digest
  end

  test "owner attribution requires the stored raiser session", ctx do
    request =
      Escalation.operator_ask(
        ctx.db,
        operator_call(ctx.raiser, %{question: "owner attribution?"})
      )

    _ruled =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(request.id, %{decision: "accept"})
      )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE decision_requests SET raiserSessionKey='' WHERE id=?1",
               [request.id]
             )

    owner_call = %{origin: "user:flynn", principal: {:user, "flynn"}, params: %{}}

    assert %{code: "decision_request_integrity_invalid"} =
             Escalation.get(ctx.db, owner_call, request.id)

    assert {:ok, [[fields]]} =
             DB.query(
               ctx.db,
               "SELECT failingFields FROM decision_request_integrity_evidence WHERE requestId=?1",
               [request.id]
             )

    assert JSON.decode!(fields) == [
             "ownerOnBehalfOf",
             "raiserNotificationWake",
             "requestIdentity"
           ]
  end

  test "an unrelated sibling session cannot borrow owner visibility", ctx do
    request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "private?"}))

    sibling = session(ctx.db, "same-owner-sibling", "flynn")
    sibling_call = operator_call(sibling, %{})

    owner_call = %{
      origin: "user:flynn",
      principal: {:user, "flynn"},
      params: %{}
    }

    assert [] = Escalation.list(ctx.db, sibling_call, "open")
    assert nil == Escalation.get(ctx.db, sibling_call, request.id)
    assert [%{id: request_id}] = Escalation.list(ctx.db, owner_call, "open")
    assert request_id == request.id
    assert %{id: ^request_id} = Escalation.get(ctx.db, owner_call, request.id)
    assert [%{id: ^request_id}] = Escalation.list(ctx.db, operator_call(ctx.raiser, %{}), "open")

    _ruled =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(request.id, %{decision: "accept"})
      )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (?1, 'decision_request_ruled', ?2, NULL)",
               [System.system_time(:millisecond), request.id]
             )

    assert [] = Escalation.list(ctx.db, sibling_call, "ruled")
    assert nil == Escalation.get(ctx.db, sibling_call, request.id)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM decision_request_integrity_evidence WHERE requestId=?1",
               [request.id]
             )

    assert %{code: "decision_request_integrity_invalid", request_id: ^request_id} =
             Escalation.get(ctx.db, owner_call, request.id)
  end

  test "visibility precedes validation and hidden dirt writes no evidence", ctx do
    request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "hidden dirt?"}))

    _ruled =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(request.id, %{decision: "accept"})
      )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (?1, 'decision_request_ruled', ?2, NULL)",
               [System.system_time(:millisecond), request.id]
             )

    foreign = session(ctx.db, "hidden-reader", "other")
    foreign_call = operator_call(foreign, %{})
    assert [] = Escalation.list(ctx.db, foreign_call, "ruled")
    assert nil == Escalation.get(ctx.db, foreign_call, request.id)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM decision_request_integrity_evidence WHERE requestId=?1",
               [request.id]
             )
  end

  test "one automatic condition wake is committed and exact replay creates nothing", ctx do
    request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "race?"}))

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          Escalation.operator_rule(
            ctx.db,
            owner_operator_rule(request.id, %{decision: "accept", rationale: "one"})
          )
        end)
      end

    results = Task.await_many(tasks)
    assert Enum.all?(results, &(&1.status == "ruled" and &1.decision == "accept"))
    assert results |> Enum.map(& &1.ruling_fact_id) |> Enum.uniq() |> length() == 1

    replay =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(request.id, %{decision: "accept", rationale: "one"})
      )

    assert replay.ruling_fact_id == hd(results).ruling_fact_id

    assert {:ok, [[1, 1, 1]]} =
             DB.query(
               ctx.db,
               """
               SELECT
                 (SELECT COUNT(*) FROM condition_facts WHERE kind='escalation-ruled' AND scope=?1),
                 (SELECT COUNT(*) FROM lifecycle_events WHERE kind='decision_request_ruled' AND subject=?1),
                 (SELECT COUNT(*) FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1)
               """,
               [request.id]
             )
  end

  test "ruling wake preserves the request's stored decision duration", ctx do
    request =
      Escalation.operator_ask(
        ctx.db,
        operator_call(ctx.raiser, %{question: "custom deadline?", deadline: 12_345})
      )

    ruled =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(request.id, %{decision: "accept"})
      )

    assert {:ok, [[due_at]]} =
             DB.query(
               ctx.db,
               "SELECT dueAt FROM wakes WHERE conditionKind='escalation-ruled' AND conditionScope=?1",
               [request.id]
             )

    assert due_at == ruled.ruled_at + 12_345
  end

  test "list validates every admitted invalid row and refuses the lexical first id", ctx do
    requests =
      for question <- ["bad one?", "bad two?"] do
        request =
          Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: question}))

        _ruled =
          Escalation.operator_rule(
            ctx.db,
            owner_operator_rule(request.id, %{decision: "accept"})
          )

        assert {:ok, _} =
                 DB.query(
                   ctx.db,
                   "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (?1, 'decision_request_ruled', ?2, NULL)",
                   [System.system_time(:millisecond), request.id]
                 )

        request
      end

    expected = requests |> Enum.map(& &1.id) |> Enum.min()

    assert %{code: "decision_request_integrity_invalid", request_id: ^expected} =
             Escalation.list(ctx.db, operator_call(ctx.raiser, %{}), "ruled")

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(DISTINCT requestId) FROM decision_request_integrity_evidence"
             )
  end

  test "evidence conflicts and write failures are typed and prohibit serialization", ctx do
    request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "evidence rail?"}))

    _ruled =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(request.id, %{decision: "accept"})
      )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (?1, 'decision_request_ruled', ?2, NULL)",
               [System.system_time(:millisecond), request.id]
             )

    assert %{code: "decision_request_integrity_invalid"} =
             Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), request.id)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE decision_request_integrity_evidence SET causeCode='tampered' WHERE requestId=?1",
               [request.id]
             )

    assert %{
             code: "decision_request_integrity_evidence_conflict",
             message: "decision request integrity evidence conflict"
           } = Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), request.id)

    assert :ok = DB.execute(ctx.db, "DROP TABLE decision_request_integrity_evidence")

    assert %{
             code: "decision_request_integrity_evidence_unavailable",
             message: "decision request integrity evidence unavailable"
           } = Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), request.id)
  end

  test "legacy attribution remains unknown without inferred owner provenance", ctx do
    direct =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "legacy direct?"}))

    via =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "legacy via?"}))

    direct_ruled =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(direct.id, %{decision: "accept"})
      )

    via_call =
      owner_operator_rule(via.id, %{decision: "accept"})
      |> Map.put(:transport_session_key, ctx.raiser.session_key)

    via_ruled = Escalation.operator_rule(ctx.db, via_call)
    cutoff = max(direct_ruled.ruling_fact_id, via_ruled.ruling_fact_id)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE decision_request_terminal_epoch SET legacyRulingFactMaxId=?1 WHERE id=0",
               [cutoff]
             )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE decision_requests SET ruledViaPrincipal=NULL,ruledViaSessionState=NULL WHERE id IN (?1,?2)",
               [direct.id, via.id]
             )

    assert %{
             ruling_attribution: %{
               performer: %{
                 principal: %{state: "legacy-unknown"},
                 session: %{state: "legacy-unknown"}
               }
             }
           } = Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), direct.id)

    assert %{
             ruled_via_session_key: session_key,
             ruling_attribution: %{
               performer: %{
                 principal: %{state: "legacy-unknown"},
                 session: %{state: "known", key: session_key}
               }
             }
           } = Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), via.id)

    assert session_key == ctx.raiser.session_key
  end

  test "impossible consumed operator refuses before generic consumption", ctx do
    request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "consume?"}))

    _ruled =
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(request.id, %{decision: "accept"})
      )

    assert :ok = DB.execute(ctx.db, "PRAGMA ignore_check_constraints=ON")

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE decision_requests SET status='consumed',consumedAt=1 WHERE id=?1",
               [request.id]
             )

    assert :ok = DB.execute(ctx.db, "PRAGMA ignore_check_constraints=OFF")

    assert %{code: "decision_request_integrity_invalid", request_id: request_id} =
             Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), request.id)

    assert request_id == request.id
    refute Escalation.consume(ctx.db, request.id)

    assert {:ok, [["consumed", 1]]} =
             DB.query(ctx.db, "SELECT status,consumedAt FROM decision_requests WHERE id=?1", [
               request.id
             ])
  end

  test "a failure after wake and fact creation rolls the full ruling back", ctx do
    request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "rollback?"}))

    assert {:ok, [[wake_count, fact_count, event_count]]} =
             DB.query(
               ctx.db,
               "SELECT (SELECT COUNT(*) FROM wakes), (SELECT COUNT(*) FROM condition_facts), (SELECT COUNT(*) FROM lifecycle_events)"
             )

    assert :ok =
             DB.execute(
               ctx.db,
               "CREATE TRIGGER refuse_operator_ruling_fixture BEFORE UPDATE OF status ON decision_requests WHEN NEW.kind='operator' AND NEW.status='ruled' BEGIN SELECT RAISE(ABORT, 'fixture rollback'); END;"
             )

    assert_raise DB.Error, ~r/fixture rollback/, fn ->
      Escalation.operator_rule(
        ctx.db,
        owner_operator_rule(request.id, %{decision: "accept"})
      )
    end

    assert {:ok, [["open", nil, nil, nil, ^wake_count, ^fact_count, ^event_count]]} =
             DB.query(
               ctx.db,
               "SELECT status,decision,ruledAt,rulingFactId, (SELECT COUNT(*) FROM wakes), (SELECT COUNT(*) FROM condition_facts), (SELECT COUNT(*) FROM lifecycle_events) FROM decision_requests WHERE id=?1",
               [request.id]
             )
  end

  test "future incomplete terminal transition is refused by the database trigger", ctx do
    assert {:error, insert_error} =
             DB.query(
               ctx.db,
               """
               INSERT INTO decision_requests
                 (id, kind, raiserId, raiserSessionKey, ownerUserId, raisedAt,
                  deadlineAt, actionKey, question, options, context, status,
                  decision, ruledBy, ruledAt, rulingFactId)
               VALUES
                 ('dr_bad_insert', 'operator', 'agent:raiser', ?1, 'flynn', 1,
                  2, 'bad-insert', 'bad?', '[{"label":"yes"}]', '{}', 'ruled',
                  'yes', 'user:flynn', 2, 1)
               """,
               [ctx.raiser.session_key]
             )

    assert Exception.message(insert_error) =~ "decision_request_integrity_invalid"

    open = Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "guard?"}))

    assert {:error, update_error} =
             DB.query(
               ctx.db,
               "UPDATE decision_requests SET status='ruled', decision='accept', ruledBy='user:flynn', ruledAt=2, rulingFactId=1 WHERE id=?1",
               [open.id]
             )

    assert Exception.message(update_error) =~ "decision_request_integrity_invalid"
    assert Escalation.get(ctx.db, operator_call(ctx.raiser, %{}), open.id).status == "open"
  end

  test "operator supersede and withdraw are atomic, same-raiser, owner-scoped, and replay-safe",
       ctx do
    old = Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "old?"}))
    successor = session(ctx.db, "successor", "flynn")

    replacement_call =
      operator_call(successor, %{question: "new?", supersedes: old.id})
      |> Map.put(:origin, "agent:raiser")

    replacement = Escalation.operator_ask(ctx.db, replacement_call)
    assert replacement.context["supersedes"] == old.id
    assert operator_request(ctx, old.id).status == "superseded"
    assert Escalation.operator_ask(ctx.db, replacement_call).id == replacement.id

    other_origin =
      operator_call(successor, %{question: "steal?", supersedes: replacement.id})
      |> Map.put(:origin, "agent:other")

    assert %{code: "not_owner"} = Escalation.operator_ask(ctx.db, other_origin)

    raiser_withdraw = %{
      origin: "agent:raiser",
      principal: {:session, successor.session_key},
      params: %{request: replacement.id, reason: "  replaced elsewhere  "}
    }

    withdrawn = Escalation.operator_withdraw(ctx.db, raiser_withdraw)
    assert withdrawn.status == "withdrawn"
    assert withdrawn.withdrawn_reason == "replaced elsewhere"
    assert Escalation.operator_withdraw(ctx.db, raiser_withdraw).id == replacement.id

    owner_request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "owner withdraw?"}))

    owner_withdraw = %{
      origin: "user:flynn",
      principal: {:user, "flynn"},
      params: %{request: owner_request.id, reason: "moot"}
    }

    assert %{code: "invalid"} =
             Escalation.withdraw(ctx.db, %{
               origin: "agent:raiser",
               principal: {:session, ctx.raiser.session_key},
               params: %{request: owner_request.id, reason: "wrong verb"}
             })

    assert %{withdrawn_by: "user:flynn"} =
             Escalation.operator_withdraw(ctx.db, owner_withdraw)

    foreign = session(ctx.db, "foreign", "other")

    assert %{code: "not_owner"} =
             Escalation.operator_withdraw(ctx.db, %{
               origin: "agent:raiser",
               principal: {:session, foreign.session_key},
               params: %{request: old.id, reason: "cross-owner"}
             })
  end

  test "operator rows survive retirement, stay user-owner-visible, and enforce their CHECK arm",
       ctx do
    request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "survive?"}))

    foreign = session(ctx.db, "foreign-reader", "other")

    owner_call = %{
      origin: "user:flynn",
      principal: {:user, "flynn"},
      params: %{}
    }

    assert [%{id: id, context: %{"note" => nil, "supersedes" => nil}}] =
             Escalation.list(ctx.db, owner_call, "open")

    assert id == request.id

    rebound = operator_call(foreign, %{}) |> Map.put(:origin, "agent:raiser")
    assert [] = Escalation.list(ctx.db, rebound, "open")
    assert nil == Escalation.get(ctx.db, rebound, request.id)

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
               ctx.raiser.session_key
             ])

    :ok = Escalation.withdraw_for_retired(ctx.db, ctx.raiser.session_key)
    :ok = Escalation.recover_retired(ctx.db)
    assert operator_request(ctx, request.id).status == "open"

    assert {:error, %DB.Error{}} =
             DB.query(
               ctx.db,
               "UPDATE decision_requests SET status='consumed' WHERE id=?1",
               [request.id]
             )

    assert {:error, %DB.Error{}} =
             DB.query(
               ctx.db,
               "UPDATE decision_requests SET status='ruled', decision='accept' WHERE id=?1",
               [request.id]
             )
  end

  test "escalation-ruled remains substrate-reserved", ctx do
    assert {:error, %{code: "reserved_kind"}} =
             ConditionFacts.file(ctx.db, ctx.scheduler, %{
               kind: "escalation-ruled",
               scope: "dr_fake",
               origin: "agent:raiser"
             })
  end

  defp session(db, name, owner) do
    Org.create(db, %{
      session_key: "agent:#{name}:app",
      display_name: name,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp call(session, params) do
    %{
      verb: "attest",
      origin: "agent:raiser",
      principal: {:session, session.session_key},
      session_key: nil,
      params: params
    }
  end

  defp statute, do: %{name: "review", text: "owner denied review"}

  defp escalation_ctx, do: %{question: "Allow this action?", options: nil}

  defp open(ctx, call, statute) do
    Escalation.escalate(ctx.db, call, statute, escalation_ctx())
  end

  defp rule_call(id, decision) do
    %{
      origin: "user:flynn",
      principal: {:user, "flynn"},
      params: %{request_id: id, decision: decision}
    }
  end

  defp operator_call(session, params) do
    %{
      verb: "operator-ask",
      origin: "agent:raiser",
      principal: {:session, session.session_key},
      transport_session_key: session.session_key,
      params: params
    }
  end

  defp owner_operator_rule(id, params) do
    %{
      verb: "operator-rule",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      transport_session_key: nil,
      params: Map.put(params, :request, id)
    }
  end

  defp operator_request(ctx, id) do
    Escalation.get(ctx.db, owner_operator_rule(id, %{}), id)
  end

  defp insert_assignment!(db, id, holder_key, state) do
    terminal = if state == "closed", do: ",'revoked',2,'flynn'", else: ",NULL,NULL,NULL"

    :ok =
      DB.execute(
        db,
        "INSERT INTO assignments (id,subject,holderKey,holderFallback,openedBySession,openedAt,state,outcome,closedAt,closedByUser) VALUES ('#{id}','linked','#{holder_key}',0,'#{holder_key}',1,'#{state}'#{terminal})"
      )
  end

  defp request(ctx, id) do
    Escalation.get(ctx.db, rule_call(id, "allow"), id, owner_user_id: "flynn")
  end

  # Decision notification wakes are the only ungated (targetGate = 0) wakes.
  defp notification_wakes(ctx) do
    {:ok, rows} =
      DB.query(ctx.db, "SELECT wakeId FROM wakes WHERE targetGate = 0 ORDER BY rowid")

    Enum.map(rows, fn [wake_id] -> Wakes.get(ctx.db, wake_id) end)
  end

  defp ruling_wake(ctx, id) do
    Wakes.schedule(ctx.db, %{
      session_key: ctx.raiser.session_key,
      origin: "agent:raiser",
      prompt: "re-adjudicate",
      due_at: System.system_time(:millisecond) + 60_000,
      condition_kind: "escalation-ruled",
      condition_scope: id,
      creator_session_key: ctx.raiser.session_key
    })
  end
end
