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

    ensure_main_session(db, "flynn")

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

  test "operator ruling is Mike-only, transport-stamped, Main-refused, and replay-safe", ctx do
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
      Escalation.operator_rule(ctx.db, owner_operator_rule(direct.id, %{decision: "accept"}))

    assert ruled.status == "ruled"
    assert ruled.decision == "accept"
    assert ruled.ruled_by == "user:flynn"
    assert ruled.ruled_via_session_key == nil
    assert is_integer(ruled.ruling_fact_id)
    refute Escalation.consume(ctx.db, direct.id)

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

    relayed =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "relay?"}))

    relay_call =
      owner_operator_rule(relayed.id, %{response: "  yes, after 013  ", rationale: "  ordered  "})
      |> Map.put(:transport_session_key, ctx.raiser.session_key)

    assert %{
             decision: "yes, after 013",
             rationale: "ordered",
             ruled_via_session_key: relay_key
           } = Escalation.operator_rule(ctx.db, relay_call)

    assert relay_key == ctx.raiser.session_key

    assert %{code: "invalid"} =
             Escalation.rule(ctx.db, owner_operator_rule(relayed.id, %{decision: "accept"}),
               authorized: true
             )

    assert %{code: "invalid"} =
             Escalation.waive(ctx.db, owner_operator_rule(relayed.id, %{decision: "accept"}),
               authorized: true
             )
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

  test "operator rows survive retirement, stay owner-visible, and enforce their CHECK arm", ctx do
    request =
      Escalation.operator_ask(ctx.db, operator_call(ctx.raiser, %{question: "survive?"}))

    same_owner = session(ctx.db, "same-owner", "flynn")
    foreign = session(ctx.db, "foreign-reader", "other")

    assert [%{id: id, context: %{"note" => nil, "supersedes" => nil}}] =
             Escalation.list(ctx.db, operator_call(same_owner, %{}), "open")

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
