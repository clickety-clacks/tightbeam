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
