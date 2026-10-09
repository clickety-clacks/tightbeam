defmodule Tightbeam.ConditionFactsTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    ConditionFacts,
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    Ledger,
    Org,
    Projection,
    Rules,
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

    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1)"
      )

    Rules.load!(
      Path.join(System.tmp_dir!(), "condition-rules-#{System.unique_integer([:positive])}"),
      []
    )

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
        model: Model.new("fable")
      })

    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    deliver = fn wake ->
      Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
        db: db,
        wake_id: wake.wake_id,
        sender: wake.origin,
        target_gate: if(wake.target_gate == 0, do: nil, else: wake),
        fire_wake_in_txn: wake.origin == "process:tightbeam",
        conn_registry: ConnRegistry,
        lane_manager: Tightbeam.LaneManager,
        wake_scheduler: scheduler
      )
    end

    start_supervised!(
      {Wakes, db: db, name: scheduler, tick_ms: 60_000, batch: 2, deliver: deliver}
    )

    %{db: db, scheduler: scheduler, session: session}
  end

  test "Firehose condition Dispatch files once and replays observation only", ctx do
    alias Tightbeam.{Dispatch, Firehose.Hub}
    hub = start_supervised!({Hub, name: Hub})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: false})
    handlers = Gateway.handlers(%{db: ctx.db, wake_scheduler: ctx.scheduler})

    call = %{
      verb: "condition",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{
        kind: "fixture-ready",
        scope: "synthetic",
        idempotency_key: "condition-publication"
      }
    }

    assert {:ok, fact} = Dispatch.dispatch(ctx.db, handlers, call)
    assert fact.kind == "fixture-ready"
    assert fact.scope == "synthetic"
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "condition_fact.filed", "payload" => payload}}
    assert payload["factId"] == fact.fact_id
    assert payload["rowVersion"] == fact.fact_id
    Hub.delivered(hub, self())
    assert {:ok, ^fact} = Dispatch.dispatch(ctx.db, handlers, call)
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, _}

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM condition_facts WHERE kind='fixture-ready'")

    assert {:ok, [["flynn"]]} =
             DB.query(ctx.db, "SELECT ownerUserId FROM condition_facts WHERE id=?1", [
               fact.fact_id
             ])

    assert {:ok, []} = DB.query(ctx.db, "PRAGMA foreign_key_check")
  end

  test "Firehose cancellation emits once and preserves rollback and authorization", ctx do
    alias Tightbeam.Firehose.Hub
    hub = start_supervised!({Hub, name: Hub})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: false})

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.session.session_key,
        origin: "user:flynn",
        prompt: "Cancel fixture",
        due_at: System.system_time(:millisecond) + 60_000
      })

    command = %{
      wake_id: wake.wake_id,
      expected_origin: "user:flynn",
      requester: %{kind: "user", id: "flynn"},
      reason_kind: "requester_withdrew",
      causal_source: %{
        kind: "verb_call",
        accepted_event: %{origin: "user:flynn", session_key: nil, principal: {:user, "flynn"}}
      },
      outcome: %{kind: "no_replacement"}
    }

    assert {:ok, false} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.cancel_in_txn(txn, %{command | expected_origin: "user:other"})
             end)

    refute_receive {:firehose_notice, _}

    assert {:error, %RuntimeError{message: "rollback cancel"}} =
             DB.transaction(ctx.db, fn txn ->
               assert {:accepted_in_txn, _, %{canceled: true}} = Wakes.cancel_in_txn(txn, command)
               raise "rollback cancel"
             end)

    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1", [
               wake.wake_id
             ])

    refute_receive {:firehose_notice, _}

    assert {:ok, {:accepted_in_txn, event_id, %{canceled: true}}} =
             DB.transaction(ctx.db, fn txn -> Wakes.cancel_in_txn(txn, command) end)

    assert event_id > 0
    assert_receive {:firehose_notice, %{"class" => "wake.canceled", "payload" => payload}}
    assert payload["wakeId"] == wake.wake_id
    assert payload["state"] == "canceled"
    Hub.delivered(hub, self())
    assert {:ok, false} = DB.transaction(ctx.db, fn txn -> Wakes.cancel_in_txn(txn, command) end)
    refute_receive {:firehose_notice, _}

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1", [
               wake.wake_id
             ])

    assert turn_count(ctx.db, wake.wake_id) == 0
    assert {:ok, []} = DB.query(ctx.db, "PRAGMA foreign_key_check")
  end

  test "Firehose condition publication keeps tenant matching and one queued delivery", ctx do
    alias Tightbeam.Firehose.Hub
    hub = start_supervised!({Hub, name: Hub})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: false})

    assert {:ok, _} =
             DB.query(ctx.db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('other',0,1)")

    wake = condition_wake(ctx, "deployment-ready", "fixture")

    wrong =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "deployment-ready",
        scope: "fixture",
        origin: "user:other",
        owner_user_id: "other"
      })

    assert is_integer(wrong.fact_id)
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"
    assert turn_count(ctx.db, wake.wake_id) == 0
    refute_receive {:firehose_notice, _}

    matched =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "deployment-ready",
        scope: "fixture",
        origin: "user:flynn",
        owner_user_id: "flynn"
      })

    assert is_integer(matched.fact_id)

    assert_receive {:firehose_notice, %{"class" => "wake.fired", "payload" => fired_payload}}
    assert fired_payload["wakeId"] == wake.wake_id
    assert fired_payload["state"] == "pending"
    assert fired_payload["firedBy"] == "condition"
    Hub.delivered(hub, self())

    assert_receive {:firehose_notice,
                    %{"class" => "session.updated", "payload" => session_payload}}

    assert session_payload["sessionKey"] == ctx.session.session_key
    assert session_payload["mechanicalStatus"] == "running"
    Hub.delivered(hub, self())

    assert_receive {:firehose_notice, %{"class" => "wake.fired", "payload" => payload}}
    assert payload["wakeId"] == wake.wake_id
    assert payload["state"] == "fired"
    assert payload["firedBy"] == "condition"
    Hub.delivered(hub, self())

    assert_receive {:firehose_notice, %{"class" => "wake.fired", "payload" => carrier_payload}}
    assert carrier_payload["digest"] == true
    assert carrier_payload["deliveryStatus"] == "queued"
    Hub.delivered(hub, self())

    assert_receive {:firehose_notice,
                    %{"class" => "message.created", "payload" => message_payload}}

    assert message_payload["sessionKey"] == ctx.session.session_key
    assert message_payload["sender"] == "process:tightbeam"
    assert message_payload["content"] =~ "re-adjudicate"
    assert message_payload["content"] =~ "sender=agent:owner"
    Hub.delivered(hub, self())
    assert_receive {:lane_nudged, key}
    assert key == ctx.session.session_key

    assert [
             %{
               member_state: "included",
               batch_state: "delivered",
               delivery_wake_id: carrier_id
             }
           ] = Tightbeam.NoticeBatcher.source_refs(ctx.db, wake.wake_id)

    assert turn_count(ctx.db, wake.wake_id) == 0

    assert {:ok, [[seq, "queued", ^key]]} =
             DB.query(ctx.db, "SELECT seq,status,sessionKey FROM turns WHERE wakeId=?1", [
               carrier_id
             ])

    assert :ok = Wakes.fire_matching(ctx.scheduler, matched.fact_id)
    refute_receive {:firehose_notice, _}
    refute_receive {:lane_nudged, _}

    assert [
             %{
               member_state: "included",
               batch_state: "delivered",
               delivery_wake_id: ^carrier_id
             }
           ] = Tightbeam.NoticeBatcher.source_refs(ctx.db, wake.wake_id)

    assert turn_count(ctx.db, wake.wake_id) == 0

    assert {:ok, [[^seq, "queued", ^key]]} =
             DB.query(ctx.db, "SELECT seq,status,sessionKey FROM turns WHERE wakeId=?1", [
               carrier_id
             ])

    assert {:ok, []} = DB.query(ctx.db, "PRAGMA foreign_key_check")
  end

  test "condition wake uses an id cursor, fires once on a literal fact, and stays count-visible",
       ctx do
    preexisting =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "deploy-succeeded",
        scope: "prod",
        origin: "process:ci",
        owner_user_id: "flynn"
      })

    wake = condition_wake(ctx, "deploy-succeeded", "prod")
    assert wake.condition_after_id == preexisting.fact_id
    assert Wakes.pending_count(ctx.db, ctx.session.session_key) == 1
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"

    mismatch =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "deploy-succeeded",
        scope: "staging",
        origin: "process:ci",
        owner_user_id: "flynn"
      })

    assert mismatch.fact_id > preexisting.fact_id
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"
    assert turn_count(ctx.db, wake.wake_id) == 0

    matching =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "deploy-succeeded",
        scope: "prod",
        origin: "process:ci",
        owner_user_id: "flynn"
      })

    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, wake.wake_id)

    assert [
             %{
               member_state: "included",
               batch_id: batch_id,
               batch_state: "delivered",
               delivery_wake_id: carrier_id
             }
           ] = Tightbeam.NoticeBatcher.source_refs(ctx.db, wake.wake_id)

    assert %{state: "delivered", delivery_wake_id: ^carrier_id} =
             Tightbeam.NoticeBatcher.batch(ctx.db, batch_id)

    assert turn_count(ctx.db, wake.wake_id) == 0

    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "deploy-succeeded",
      scope: "prod",
      origin: "process:ci",
      owner_user_id: "flynn"
    })

    assert [
             %{
               member_state: "included",
               batch_id: ^batch_id,
               batch_state: "delivered",
               delivery_wake_id: ^carrier_id
             }
           ] = Tightbeam.NoticeBatcher.source_refs(ctx.db, wake.wake_id)

    assert turn_count(ctx.db, wake.wake_id) == 0

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
            origin: "process:ci",
            owner_user_id: "flynn"
          })

        newer =
          ConditionFacts.file_in_txn(txn, %{
            kind: "newer-kind",
            scope: "prod",
            origin: "process:ci",
            owner_user_id: "flynn"
          })

        {older, newer}
      end)

    assert older_fact.fact_id < newer_fact.fact_id
    assert :ok = Wakes.fire_matching(ctx.scheduler, older_fact.fact_id)
    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, older_wake.wake_id)

    assert %{state: "fired", fired_by: "condition"} =
             Wakes.get(ctx.db, newer_wake.wake_id)

    [older_ref] = Tightbeam.NoticeBatcher.source_refs(ctx.db, older_wake.wake_id)
    [newer_ref] = Tightbeam.NoticeBatcher.source_refs(ctx.db, newer_wake.wake_id)
    assert older_ref.batch_id == newer_ref.batch_id

    assert Enum.map(
             Tightbeam.NoticeBatcher.members(ctx.db, older_ref.batch_id),
             & &1.source_wake_id
           ) ==
             [older_wake.wake_id, newer_wake.wake_id]

    assert :ok = Wakes.fire_matching(ctx.scheduler, newer_fact.fact_id)
    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, newer_wake.wake_id)
  end

  test "fallback consumes a condition wake and an unresolved fire records its cause", ctx do
    fallback = condition_wake(ctx, "build-green", nil, 0)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert %{state: "fired", fired_by: "fallback"} = Wakes.get(ctx.db, fallback.wake_id)
    assert Wakes.get(ctx.db, fallback.wake_id).prompt == fallback.prompt

    assert {:ok, [[fallback_envelope]]} =
             DB.query(
               ctx.db,
               "SELECT t.prompt FROM turns t JOIN notice_batches b ON b.deliveryWakeId=t.wakeId JOIN notice_batch_members m ON m.batchId=b.batchId WHERE m.sourceWakeId=?1",
               [fallback.wake_id]
             )

    assert fallback_envelope =~ "[woke: fallback deadline]\n\n" <> fallback.prompt
    assert delivery_turn_count(ctx.db, fallback.wake_id) == 1

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

    for kind <- ["assignment-landed", "assignment-reviewed", "assignment-blocked"] do
      assert {:error, %{code: "reserved_kind"}} =
               ConditionFacts.file(ctx.db, ctx.scheduler, %{
                 kind: kind,
                 scope: "asg_fixture",
                 origin: "user:flynn"
               })
    end

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
    assert filed.condition_wake_hint.kind == filed.kind
    assert filed.condition_wake_hint.scope == filed.scope
    assert filed.condition_wake_hint.fallback_after == "2h"
    assert filed.condition_wake_hint.example =~ "--when-fact release-ready"
    assert filed.condition_wake_hint.example =~ "--when-scope 'prod'"

    scoped_hint = ConditionFacts.wake_hint("release-ready", "prod east")
    assert scoped_hint.example =~ "--when-scope 'prod east'"

    assert condition_handler.(%{
             origin: "user:flynn",
             params: %{kind: "escalation-ruled"}
           }).code == "reserved_kind"
  end

  test "credential-present is a substrate-only transition fact scoped host:provider (O4/I5)",
       ctx do
    # It marks the credential-commit transition, so only the substrate may file
    # it — an agent forging it would fake a re-derivation trigger.
    assert {:error, %{code: "reserved_kind"}} =
             ConditionFacts.file(ctx.db, ctx.scheduler, %{
               kind: "credential-present",
               scope: "gibson:anthropic",
               origin: "agent:someone"
             })

    filed =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "credential-present",
        scope: "gibson:anthropic",
        origin: "process:tightbeam"
      })

    assert filed.kind == "credential-present"
    assert filed.scope == "gibson:anthropic"

    # It is an occurrence, not a standing pair: asking standing?/3 of it is a
    # category error, so it must not have been mistaken for a retractable flag.
    assert_raise KeyError, fn ->
      ConditionFacts.standing?(ctx.db, "credential-present", "gibson:anthropic")
    end
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
    assert delivery_turn_count(ctx.db, wake.wake_id) == 1
  end

  test "one fact fires independent waiters and cancellation wins before firing", ctx do
    first = condition_wake(ctx, "release-ready", "prod")
    second = condition_wake(ctx, "release-ready", "prod")
    canceled = condition_wake(ctx, "release-ready", "prod")
    assert {:accepted_in_txn, _event_id, %{canceled: true}} = cancel_wake(ctx.db, canceled)

    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "release-ready",
      scope: "prod",
      origin: "user:flynn"
    })

    assert Wakes.get(ctx.db, first.wake_id).state == "fired"
    assert Wakes.get(ctx.db, second.wake_id).state == "fired"
    assert Wakes.get(ctx.db, canceled.wake_id).state == "canceled"
    assert delivery_turn_count(ctx.db, first.wake_id) == 1
    assert delivery_turn_count(ctx.db, second.wake_id) == 1
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
    # overtake A's remaining fan-out under per-fact nudging. Recognition order
    # is durable even when the recipient queue holds later sources editable.
    a_wakes = for _ <- 1..5, do: condition_wake(ctx, "seq-kind", "a").wake_id
    b_wake = condition_wake(ctx, "seq-kind", "b").wake_id

    {:ok, fact_a} =
      DB.transaction(ctx.db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{
          kind: "seq-kind",
          scope: "a",
          origin: "process:ci",
          owner_user_id: "flynn"
        })
      end)

    {:ok, fact_b} =
      DB.transaction(ctx.db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{
          kind: "seq-kind",
          scope: "b",
          origin: "process:ci",
          owner_user_id: "flynn"
        })
      end)

    :ok = Wakes.fire_matching(ctx.scheduler, [fact_a.fact_id, fact_b.fact_id])

    all = MapSet.new([b_wake | a_wakes])

    fired_order =
      EventLog.lifecycle_events(ctx.db)
      |> Enum.filter(&(&1.kind == "wake_condition_fired" and MapSet.member?(all, &1.subject)))
      |> Enum.map(& &1.subject)

    assert length(fired_order) == 6, "expected all 6 wakes to fire, got #{inspect(fired_order)}"

    assert Enum.sort(Enum.take(fired_order, 5)) == Enum.sort(a_wakes),
           "all of fact A's fan-out must be served before fact B's"

    assert List.last(fired_order) == b_wake
    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, b_wake)

    [first_ref] = Tightbeam.NoticeBatcher.source_refs(ctx.db, hd(a_wakes))

    assert Enum.all?(a_wakes ++ [b_wake], fn wake_id ->
             case Tightbeam.NoticeBatcher.source_refs(ctx.db, wake_id) do
               [%{batch_id: batch_id}] -> batch_id == first_ref.batch_id
               _ -> false
             end
           end)

    assert Enum.map(
             Tightbeam.NoticeBatcher.members(ctx.db, first_ref.batch_id),
             & &1.source_wake_id
           ) ==
             a_wakes ++ [b_wake]

    assert Wakes.get(ctx.db, b_wake).fired_by == "condition"
  end

  test "scope nonmatches cannot starve a later matching wake at the batch boundary", ctx do
    nonmatches =
      for scope <- ["older-a", "older-b"] do
        condition_wake(ctx, "batch-scope", scope).wake_id
      end

    matching = condition_wake(ctx, "batch-scope", "wanted").wake_id

    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "batch-scope",
      scope: "wanted",
      origin: "process:ci",
      owner_user_id: "flynn"
    })

    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, matching)
    assert Enum.all?(nonmatches, &(Wakes.get(ctx.db, &1).state == "pending"))
  end

  test "an identical fact from another owner cannot satisfy a legacy condition wake", ctx do
    assert :ok =
             DB.execute(
               ctx.db,
               "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('other-owner', 0, 1)"
             )

    wake = condition_wake(ctx, "tenant-scoped", "same-scope")

    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "tenant-scoped",
      scope: "same-scope",
      origin: "user:other-owner"
    })

    assert %{state: "pending"} = Wakes.get(ctx.db, wake.wake_id)

    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "tenant-scoped",
      scope: "same-scope",
      origin: "user:flynn"
    })

    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, wake.wake_id)
  end

  for path <- [:eager, :scheduler, :dependency] do
    @tag matching_path: path
    test "nullable fact ownership preserves recipient and kind/scope matching via #{path}", ctx do
      assert :ok =
               DB.execute(
                 ctx.db,
                 "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('fixture-owner-b', 0, 1)"
               )

      other =
        Org.create(
          ctx.db,
          ctx.session
          |> Map.take([:archetype, :host, :harness, :provider, :model])
          |> Map.merge(%{
            session_key: "agent:condition:other",
            display_name: "Other condition target",
            owner_user_id: "fixture-owner-b",
            origin: "user:fixture-owner-b"
          })
        )

      other_ctx = %{ctx | session: other}
      spy = start_supervised!({FactNudgeSpy, self()})

      arm =
        if ctx.matching_path == :dependency do
          base =
            Path.join(
              System.tmp_dir!(),
              "nullable-fact-rules-#{System.unique_integer([:positive])}"
            )

          File.mkdir_p!(Path.join(base, "identity/rules"))

          File.write!(Path.join(base, "identity/rules/verification.toml"), """
          [[policy]]
          name = "synthetic-condition-verification"
          purpose = "wait-verification-admission"
          when = [
            { fact = "verifier.open", op = "eq", value = true },
            { fact = "verifier.holder_is_other", op = "eq", value = true },
          ]
          verification = { trigger = "registration", terminal = "bound-verdict-or-obligation-terminal", fallback = "wake-due-at" }
          """)

          Rules.load!(base, [])

          for target <- [ctx.session, other] do
            verifier_key = target.session_key <> ":verifier"

            Org.create(
              ctx.db,
              target
              |> Map.take([:archetype, :host, :harness, :provider, :model, :owner_user_id])
              |> Map.merge(%{
                session_key: verifier_key,
                display_name: "Condition verifier",
                origin: "user:" <> target.owner_user_id
              })
            )

            for holder <- [target.session_key, verifier_key] do
              assert {:ok, _} =
                       DB.query(
                         ctx.db,
                         "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt) VALUES(?1,?1,?1,?2,1)",
                         [holder, target.owner_user_id]
                       )

              assert {:ok, _} =
                       DB.query(
                         ctx.db,
                         "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES(?1,'coordination')",
                         [holder]
                       )
            end
          end

          fn target_ctx, kind, scope ->
            target = target_ctx.session
            verifier_id = target.session_key <> ":verifier"

            assert {:ok, %{wake_id: _} = wake} =
                     DB.transaction(ctx.db, fn txn ->
                       Wakes.register_wait_in_txn(txn, %{
                         session_key: target.session_key,
                         origin: "session:" <> target.session_key,
                         prompt: "Continue from the synthetic condition.",
                         due_at: System.system_time(:millisecond) + 60_000,
                         assignment_id: target.session_key,
                         registrant_session_key: target.session_key,
                         owner_user_id: target.owner_user_id,
                         predicate: %{
                           "conditions" => [
                             %{"fact" => "condition_fact.matches", "op" => "eq", "value" => true}
                           ],
                           "bindings" => %{
                             "conditionKind" => kind,
                             "conditionScope" => scope,
                             "conditionAfterId" => 0
                           },
                           "resolverRef" => %{"kind" => "assignment", "id" => verifier_id},
                           "verificationRef" => %{"kind" => "assignment", "id" => verifier_id},
                           "necessity" => "The synthetic fact is required."
                         }
                       })
                     end)

            wake
          end
        else
          &condition_wake/3
        end

      file = fn input ->
        case ctx.matching_path do
          :eager ->
            # The spy cannot deliver: this proves transactional eager recognition.
            ConditionFacts.file(ctx.db, spy, input)

          :scheduler ->
            {:ok, fact} = DB.transaction(ctx.db, &ConditionFacts.file_in_txn(&1, input))
            assert :ok = Wakes.fire_due(ctx.scheduler)
            fact

          :dependency ->
            fact = ConditionFacts.file(ctx.db, ctx.scheduler, input)
            # Row commits recognize dependency waits; the due pass delivers them.
            assert :ok = Wakes.fire_due(ctx.scheduler)
            fact
        end
      end

      owned_a = arm.(ctx, "fixture-nullable-owner", "owned")
      owned_b = arm.(other_ctx, "fixture-nullable-owner", "owned")

      owned_fact =
        file.(%{
          kind: "fixture-nullable-owner",
          scope: "owned",
          origin: "user:flynn"
        })

      assert {:ok, [["flynn", "user:flynn"]]} =
               DB.query(ctx.db, "SELECT ownerUserId, origin FROM condition_facts WHERE id=?1", [
                 owned_fact.fact_id
               ])

      process_a = arm.(ctx, "fixture-nullable-owner", "process")
      process_b = arm.(other_ctx, "fixture-nullable-owner", "process")
      wrong_kind = arm.(ctx, "fixture-other-kind", "process")
      wrong_scope = arm.(other_ctx, "fixture-nullable-owner", "other-scope")

      process_fact =
        file.(%{
          kind: "fixture-nullable-owner",
          scope: "process",
          origin: "process:fixture"
        })

      assert {:ok, [[nil, "process:fixture"]]} =
               DB.query(ctx.db, "SELECT ownerUserId, origin FROM condition_facts WHERE id=?1", [
                 process_fact.fact_id
               ])

      if ctx.matching_path != :eager, do: finish_source_turns(ctx.db, owned_a.wake_id)

      for {wake, target} <- [
            {owned_a, ctx.session.session_key},
            {process_a, ctx.session.session_key},
            {process_b, other.session_key}
          ] do
        recognized = Wakes.get(ctx.db, wake.wake_id)

        if ctx.matching_path == :dependency do
          assert recognized.recognition_path == "success"
          assert recognized.recognition_evidence["label"] == "row-transition"
          expected_fact = if wake.wake_id == owned_a.wake_id, do: owned_fact, else: process_fact
          assert recognized.recognition_transition["row_id"] == expected_fact.fact_id
        else
          assert recognized.fired_by == "condition"
        end

        case recognized.state do
          "fired" ->
            assert [[^target, status]] = turn_rows_for_source(ctx.db, wake.wake_id)
            assert status in ["queued", "delivered"]

          "pending" ->
            assert Tightbeam.NoticeBatcher.source_refs(ctx.db, wake.wake_id) == []
            assert turn_rows_for_source(ctx.db, wake.wake_id) == []
        end
      end

      for wake <- [owned_b, wrong_kind, wrong_scope] do
        assert %{state: "pending"} = Wakes.get(ctx.db, wake.wake_id)
        assert Wakes.get(ctx.db, wake.wake_id).recognition_path == nil
        assert turn_count(ctx.db, wake.wake_id) == 0
      end
    end
  end

  test "recovery advances its fact watermark after a full batch of scope nonmatches", ctx do
    for scope <- ["older-a", "older-b"] do
      condition_wake(ctx, "recovery-scope", scope)
    end

    matching = condition_wake(ctx, "recovery-scope", "wanted").wake_id

    {:ok, fact} =
      DB.transaction(ctx.db, fn txn ->
        ConditionFacts.file_in_txn(txn, %{
          kind: "recovery-scope",
          scope: "wanted",
          origin: "process:ci",
          owner_user_id: "flynn"
        })
      end)

    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert %{state: "fired", fired_by: "condition"} = Wakes.get(ctx.db, matching)
    assert {:ok, [[after_fact]]} = DB.query(ctx.db, "SELECT afterFact FROM scheduler_state")
    assert after_fact >= fact.fact_id
  end

  test "shared harness health keeps auth and rate-limit standing states distinct", ctx do
    scope = ConditionFacts.harness_scope("claude", "gibson")
    assert scope == JSON.encode!(["claude", "gibson"])

    assert {:ok, %{kind: "harness-auth-dead", scope: ^scope}} =
             DB.transaction(ctx.db, fn txn ->
               ConditionFacts.file_harness_health_in_txn(
                 txn,
                 "claude",
                 "gibson",
                 "auth-dead",
                 :assert
               )
             end)

    assert ConditionFacts.harness_unavailable?(ctx.db, "claude", "gibson")
    assert ConditionFacts.harness_failure_standing?(ctx.db, "claude", "gibson", "auth-dead")

    refute ConditionFacts.harness_failure_standing?(
             ctx.db,
             "claude",
             "gibson",
             "rate-limit-dead"
           )

    assert {:ok, %{kind: "harness-rate-limit-dead"}} =
             DB.transaction(ctx.db, fn txn ->
               ConditionFacts.file_harness_health_in_txn(
                 txn,
                 "claude",
                 "gibson",
                 "rate-limit-dead",
                 :assert
               )
             end)

    assert {:ok, %{kind: "harness-auth-restored"}} =
             DB.transaction(ctx.db, fn txn ->
               ConditionFacts.file_harness_health_in_txn(
                 txn,
                 "claude",
                 "gibson",
                 "auth-dead",
                 :retract
               )
             end)

    refute ConditionFacts.harness_failure_standing?(ctx.db, "claude", "gibson", "auth-dead")
    assert ConditionFacts.harness_unavailable?(ctx.db, "claude", "gibson")
  end

  test "only the substrate may file reserved harness health facts", ctx do
    assert {:error, %{code: "reserved_kind"}} =
             ConditionFacts.file(ctx.db, ctx.scheduler, %{
               kind: "harness-auth-dead",
               scope: ConditionFacts.harness_scope("claude", "gibson"),
               origin: "agent:observer"
             })
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

  defp cancel_wake(db, wake) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        Wakes.cancel_in_txn(txn, %{
          wake_id: wake.wake_id,
          expected_origin: wake.origin,
          requester: %{kind: "session", id: "agent:owner:app"},
          reason_kind: "requester_withdrew",
          causal_source: %{
            kind: "verb_call",
            accepted_event: %{
              origin: wake.origin,
              session_key: "agent:owner:app",
              principal: {:session, "agent:owner:app"}
            }
          },
          outcome: %{kind: "no_replacement"}
        })
      end)

    result
  end

  defp turn_count(db, wake_id) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake_id])

    count
  end

  defp delivery_turn_count(db, wake_id) do
    {:ok, [[count]]} =
      DB.query(
        db,
        """
        SELECT COUNT(*) FROM turns t
        WHERE t.wakeId=?1 OR t.wakeId IN (
          SELECT b.deliveryWakeId
          FROM notice_batch_members m
          JOIN notice_batches b ON b.batchId=m.batchId
          WHERE m.sourceWakeId=?1 AND b.deliveryWakeId IS NOT NULL
        )
        """,
        [wake_id]
      )

    count
  end

  defp turn_rows_for_source(db, wake_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT sessionKey, status FROM turns WHERE wakeId=?1
        UNION ALL
        SELECT t.sessionKey, t.status
        FROM notice_batch_members m
        JOIN notice_batches b ON b.batchId=m.batchId
        JOIN turns t ON t.wakeId=b.deliveryWakeId
        WHERE m.sourceWakeId=?1
        """,
        [wake_id]
      )

    rows
  end

  defp finish_source_turns(db, wake_id) do
    carrier_ids =
      case Tightbeam.NoticeBatcher.source_refs(db, wake_id) do
        [] -> [wake_id]
        refs -> refs |> Enum.map(& &1.delivery_wake_id) |> Enum.reject(&is_nil/1)
      end

    ended_at = System.system_time(:millisecond)

    Enum.each(carrier_ids, fn carrier_id ->
      assert {:ok, _} =
               DB.query(
                 db,
                 "UPDATE turns SET status='delivered',endedAt=?2 WHERE wakeId=?1 AND status IN ('queued','running')",
                 [carrier_id, ended_at]
               )
    end)
  end

  test "a fired immediate condition source joins the existing busy recipient batch once", ctx do
    {:appended, current_message} =
      Projection.append(ctx.db, %{
        session_key: ctx.session.session_key,
        role: "user",
        content: "current running turn",
        sender: "session:" <> ctx.session.session_key
      })

    {:ok, current_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.session.session_key,
        message_id: current_message.id,
        origin: "session:" <> ctx.session.session_key,
        prompt: "current running turn"
      })

    assert {:ok, %{seq: ^current_seq} = current_turn} =
             Ledger.claim_next(ctx.db, ctx.session.session_key, "condition-batch-test")

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.session.session_key,
        origin: "agent:owner",
        prompt: "[woke: fallback deadline]\n\nauthored literal marker; urgent condition notice",
        due_at: System.system_time(:millisecond) + 60_000,
        condition_kind: "urgent-condition",
        condition_scope: nil,
        owner_user_id: "flynn",
        creator_session_key: "agent:owner:app",
        class: "algedonic"
      })

    # Represent a persisted immediate-rule condition wake from before every
    # prompt was admitted to the editable batch.
    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET deliveryRule=?2 WHERE wakeId=?1", [
               wake.wake_id,
               "algedonic-bypass r1"
             ])

    wake = Wakes.get(ctx.db, wake.wake_id)
    assert wake.delivery_rule == "algedonic-bypass r1"

    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "urgent-condition",
      scope: "prod",
      origin: "process:ci",
      owner_user_id: "flynn"
    })

    staged = Wakes.get(ctx.db, wake.wake_id)
    assert staged.state == "pending"
    assert staged.fired_by == "condition"
    assert is_integer(staged.fired_at)
    assert staged.delivery_rule == wake.delivery_rule
    assert staged.prompt == wake.prompt

    assert %{"condition_fact" => %{"kind" => "urgent-condition", "scope" => "prod"}} =
             staged.recognition_evidence

    # A later match must not replace the exact fact scope already recognized.
    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "urgent-condition",
      scope: "later",
      origin: "process:ci",
      owner_user_id: "flynn"
    })

    assert Wakes.get(ctx.db, wake.wake_id).prompt == wake.prompt
    assert Tightbeam.NoticeBatcher.source_refs(ctx.db, wake.wake_id) == []

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM notice_delivery_policies WHERE sourceWakeId=?1 AND enabled=1",
               [wake.wake_id]
             )

    assert :ok =
             Ledger.finish(ctx.db, current_seq, "delivered", nil,
               owner_lease: current_turn.owner_lease
             )

    assert :ok = Wakes.fire_due(ctx.scheduler)

    assert [
             %{
               member_state: "included",
               batch_state: "delivered",
               delivery_wake_id: carrier_id
             }
           ] = Tightbeam.NoticeBatcher.source_refs(ctx.db, wake.wake_id)

    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"
    assert Wakes.get(ctx.db, wake.wake_id).prompt == wake.prompt

    assert {:ok, [[raw_payload]]} =
             DB.query(ctx.db, "SELECT payload FROM notice_batch_members WHERE sourceWakeId=?1", [
               wake.wake_id
             ])

    assert raw_payload == wake.prompt

    assert {:ok, [[envelope]]} =
             DB.query(ctx.db, "SELECT prompt FROM turns WHERE wakeId=?1", [carrier_id])

    assert envelope =~ "[woke: fact urgent-condition/prod]\n\n" <> wake.prompt
    refute envelope =~ "[woke: fact urgent-condition/later]"
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, wake.wake_id) == 0
    assert delivery_turn_count(ctx.db, wake.wake_id) == 1

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE wakeId=?1", [wake.wake_id])

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [carrier_id])
  end
end
