defmodule Tightbeam.ConditionFactsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    ConditionFacts,
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Projection,
    Roles,
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

  defmodule FactNudgeSpy do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    def init(parent), do: {:ok, parent}

    def handle_call({:fire_matching, fact_id}, _from, parent) do
      send(parent, {:fire_matching, fact_id})
      {:reply, :ok, parent}
    end
  end

  setup do
    db = :"condition_db_#{System.unique_integer([:positive])}"
    scheduler = :"condition_scheduler_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [EventLog, Idempotency, Ledger, Projection, Org, Roles, ConditionFacts, Wakes],
        do: :ok = module.ensure_schema(db)

    session =
      Org.create(db, %{
        session_key: "agent:condition:app",
        display_name: "Condition target",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: "fable"
      })

    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    start_supervised!(
      {Wakes, db: db, name: scheduler, tick_ms: 60_000, batch: 2, deliver: fn _wake -> :ok end}
    )

    %{db: db, scheduler: scheduler, session: session}
  end

  test "condition wake uses an id cursor, fires once on a literal fact, and stays count-visible",
       ctx do
    preexisting =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "deploy-succeeded",
        scope: "prod",
        origin: "process:ci"
      })

    wake = condition_wake(ctx, "deploy-succeeded", "prod")
    assert wake.condition_after_id == preexisting.fact_id
    assert Wakes.pending_count(ctx.db, ctx.session.session_key) == 1
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"

    mismatch =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "deploy-succeeded",
        scope: "staging",
        origin: "process:ci"
      })

    assert mismatch.fact_id > preexisting.fact_id
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"
    assert turn_count(ctx.db, wake.wake_id) == 0

    matching =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "deploy-succeeded",
        scope: "prod",
        origin: "process:ci"
      })

    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, wake.wake_id)
    assert turn_count(ctx.db, wake.wake_id) == 1

    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "deploy-succeeded",
      scope: "prod",
      origin: "process:ci"
    })

    assert turn_count(ctx.db, wake.wake_id) == 1

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "wake_condition_fired" and event.subject == wake.wake_id and
               String.contains?(event.detail, "matchedFactId=#{matching.fact_id}")
           end)
  end

  test "each filer eagerly evaluates the specific fact it committed", ctx do
    {:ok, nudge_spy} = FactNudgeSpy.start_link(self())

    filed =
      ConditionFacts.file(ctx.db, nudge_spy, %{
        kind: "first-kind",
        scope: "prod",
        origin: "process:ci"
      })

    assert_receive {:fire_matching, fact_id}
    assert fact_id == filed.fact_id

    idempotent =
      ConditionFacts.file_idempotent(ctx.db, nudge_spy, %{
        kind: "second-kind",
        scope: "prod",
        origin: "process:ci",
        idempotency_key: "specific-fact"
      })

    assert_receive {:fire_matching, idempotent_fact_id}
    assert idempotent_fact_id == idempotent.fact_id

    assert idempotent ==
             ConditionFacts.file_idempotent(ctx.db, nudge_spy, %{
               kind: "second-kind",
               scope: "prod",
               origin: "process:ci",
               idempotency_key: "specific-fact"
             })

    refute_receive {:fire_matching, _}
  end

  test "eager evaluation cannot skip an older committed fact when a newer fact exists", ctx do
    older_wake = condition_wake(ctx, "older-kind", "prod")
    newer_wake = condition_wake(ctx, "newer-kind", "prod")

    {:ok, {older_fact, newer_fact}} =
      DB.transaction(ctx.db, fn txn ->
        older =
          ConditionFacts.file_in_txn(txn, %{
            kind: "older-kind",
            scope: "prod",
            origin: "process:ci"
          })

        newer =
          ConditionFacts.file_in_txn(txn, %{
            kind: "newer-kind",
            scope: "prod",
            origin: "process:ci"
          })

        {older, newer}
      end)

    assert older_fact.fact_id < newer_fact.fact_id
    assert :ok = Wakes.fire_matching(ctx.scheduler, older_fact.fact_id)
    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, older_wake.wake_id)
    assert Wakes.get(ctx.db, newer_wake.wake_id).state == "pending"

    assert :ok = Wakes.fire_matching(ctx.scheduler, newer_fact.fact_id)
    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, newer_wake.wake_id)
  end

  test "fallback consumes a condition wake and an unresolved fire records its cause", ctx do
    fallback = condition_wake(ctx, "build-green", nil, 0)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert %{state: "fired", fired_by: "fallback"} = Wakes.get(ctx.db, fallback.wake_id)
    assert turn_count(ctx.db, fallback.wake_id) == 1

    unresolved =
      Wakes.schedule(ctx.db, %{
        session_key: "agent:retired:app",
        origin: "agent:owner",
        prompt: "recheck",
        due_at: System.system_time(:millisecond) + 60_000,
        condition_kind: "deploy-succeeded",
        condition_scope: "prod"
      })

    fact =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "deploy-succeeded",
        scope: "prod",
        origin: "process:ci"
      })

    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, unresolved.wake_id)
    assert turn_count(ctx.db, unresolved.wake_id) == 0

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "wake_unresolved" and event.subject == unresolved.wake_id and
               String.contains?(event.detail, "firedBy=condition") and
               String.contains?(event.detail, "matchedFactId=#{fact.fact_id}")
           end)
  end

  test "reserved kinds are substrate-only and condition filing is idempotent", ctx do
    assert {:error, %{code: "reserved_kind"}} =
             ConditionFacts.file(ctx.db, ctx.scheduler, %{
               kind: "quota-recovered",
               scope: "codex:sol",
               origin: "process:ci"
             })

    allowed =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "quota-recovered",
        scope: "codex:sol",
        origin: "process:tightbeam"
      })

    assert allowed.kind == "quota-recovered"

    input = %{
      kind: "deploy-succeeded",
      scope: "prod",
      origin: "process:ci",
      idempotency_key: "deploy-1"
    }

    first = ConditionFacts.file_idempotent(ctx.db, ctx.scheduler, input)
    assert first == ConditionFacts.file_idempotent(ctx.db, ctx.scheduler, input)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM condition_facts WHERE id = ?1", [
               first.fact_id
             ])

    condition_handler =
      Gateway.handlers(%{db: ctx.db, wake_scheduler: ctx.scheduler})["condition"]

    call = %{
      origin: "process:deploy",
      params: %{kind: "release-ready", scope: "prod", idempotency_key: "release-1"}
    }

    filed = condition_handler.(call)
    assert filed == condition_handler.(call)

    assert condition_handler.(%{
             origin: "user:flynn",
             params: %{kind: "escalation-ruled"}
           }).code == "reserved_kind"
  end

  test "facts-read returns the latest fact by kind and optional scope", ctx do
    first =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "tour-given",
        scope: "agent:first:app",
        origin: "user:flynn"
      })

    second =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "tour-given",
        scope: ctx.session.session_key,
        origin: "agent:guide"
      })

    facts_read = Gateway.handlers(%{db: ctx.db})["facts-read"]

    assert facts_read.(%{params: %{kind: "tour-given", scope: "agent:first:app"}}) == %{
             exists: true,
             fact: %{
               id: first.fact_id,
               ts: first.ts,
               kind: "tour-given",
               scope: "agent:first:app",
               origin: "user:flynn"
             }
           }

    assert facts_read.(%{params: %{kind: "tour-given"}}).fact.id == second.fact_id

    assert facts_read.(%{params: %{kind: "missing", scope: ctx.session.session_key}}) == %{
             exists: false,
             fact: nil
           }

    assert facts_read.(%{params: %{kind: ""}}).code == "invalid"
    assert facts_read.(%{params: %{kind: "tour-given", scope: 42}}).code == "invalid"
  end

  test "a wildcard subscription matches a scoped fact", ctx do
    wake = condition_wake(ctx, "build-green", nil)

    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "build-green",
      scope: "staging",
      origin: "user:flynn"
    })

    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, wake.wake_id)
    assert turn_count(ctx.db, wake.wake_id) == 1
  end

  test "one fact fires independent waiters and cancellation wins before firing", ctx do
    first = condition_wake(ctx, "release-ready", "prod")
    second = condition_wake(ctx, "release-ready", "prod")
    canceled = condition_wake(ctx, "release-ready", "prod")
    assert Wakes.cancel(ctx.db, canceled.wake_id, canceled.origin)

    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "release-ready",
      scope: "prod",
      origin: "user:flynn"
    })

    assert Wakes.get(ctx.db, first.wake_id).state == "fired"
    assert Wakes.get(ctx.db, second.wake_id).state == "fired"
    assert Wakes.get(ctx.db, canceled.wake_id).state == "canceled"
    assert turn_count(ctx.db, first.wake_id) == 1
    assert turn_count(ctx.db, second.wake_id) == 1
    assert turn_count(ctx.db, canceled.wake_id) == 0
  end

  test "gateway validates the condition form and schedules idempotently in one transaction",
       ctx do
    wake_handler = Gateway.handlers(%{db: ctx.db, wake_scheduler: ctx.scheduler})["wake"]

    base_call = %{
      origin: "process:owner",
      principal: {:session, "agent:creator:app"},
      session_key: ctx.session.session_key,
      params: %{
        prompt: "re-adjudicate",
        after_ms: 60_000,
        condition_kind: "deploy-succeeded",
        condition_scope: "prod",
        idempotency_key: "wake-1"
      }
    }

    first = wake_handler.(base_call)
    assert first == wake_handler.(base_call)
    assert Wakes.get(ctx.db, first.wake_id).creator_session_key == "agent:creator:app"

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE wakeId = ?1", [first.wake_id])

    assert wake_handler.(put_in(base_call, [:params], %{prompt: "x", condition_scope: "prod"})) ==
             %{
               code: "invalid",
               message: "--when-scope requires --when-fact"
             }

    assert wake_handler.(
             put_in(base_call, [:params], %{prompt: "x", condition_kind: "deploy-succeeded"})
           ) == %{
             code: "invalid",
             message: "a condition wake requires a fallback (--fallback-after / --at)"
           }
  end

  test "ordered multi-fact eager nudge: a later fact never overtakes an unserved earlier fact",
       ctx do
    # Fan-out (5) > 2×batch (2) forces at least two saturation continuations
    # for fact A — the window where a separately-queued fact-B call could
    # overtake A's remaining fan-out under per-fact nudging. Fire order is
    # observed as turn-enqueue order (turns rowid).
    a_wakes = for _ <- 1..5, do: condition_wake(ctx, "seq-kind", "a").wake_id
    b_wake = condition_wake(ctx, "seq-kind", "b").wake_id

    {:ok, fact_a} =
      DB.transaction(ctx.db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{kind: "seq-kind", scope: "a", origin: "process:ci"})
      end)

    {:ok, fact_b} =
      DB.transaction(ctx.db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{kind: "seq-kind", scope: "b", origin: "process:ci"})
      end)

    :ok = Wakes.fire_matching(ctx.scheduler, [fact_a.fact_id, fact_b.fact_id])

    all = MapSet.new([b_wake | a_wakes])

    fired_order =
      Enum.reduce_while(1..50, [], fn _, _ ->
        {:ok, rows} =
          DB.query(
            ctx.db,
            "SELECT wakeId FROM turns WHERE wakeId IS NOT NULL ORDER BY rowid",
            []
          )

        ids = for [id] <- rows, MapSet.member?(all, id), do: id
        if length(ids) == 6, do: {:halt, ids}, else: Process.sleep(50) && {:cont, ids}
      end)

    assert length(fired_order) == 6, "expected all 6 wakes to fire, got #{inspect(fired_order)}"

    assert Enum.sort(Enum.take(fired_order, 5)) == Enum.sort(a_wakes),
           "all of fact A's fan-out must be served before fact B's"

    assert List.last(fired_order) == b_wake
  end

  defp condition_wake(ctx, kind, scope, due_at \\ nil) do
    Wakes.schedule(ctx.db, %{
      session_key: ctx.session.session_key,
      origin: "agent:owner",
      prompt: "re-adjudicate",
      due_at: due_at || System.system_time(:millisecond) + 60_000,
      condition_kind: kind,
      condition_scope: scope,
      creator_session_key: "agent:owner:app"
    })
  end

  defp turn_count(db, wake_id) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [wake_id])
    count
  end
end
