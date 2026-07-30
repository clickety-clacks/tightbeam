defmodule Tightbeam.WakesTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{ConditionFacts, DB, EventLog, Wakes}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    scheduler = :"wake_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = ConditionFacts.ensure_schema(name)
    :ok = Wakes.ensure_schema(name)
    # The undeliverable/failed paths record best-effort, which SWALLOWS a missing
    # table — without this the lifecycle assertions below would pass vacuously.
    :ok = EventLog.ensure_schema(name)
    %{db: name, scheduler: scheduler}
  end

  test "schedule persists a pending wake and cancel requires its origin", %{db: db} do
    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "agent:a",
        prompt: "check the build",
        due_at: System.system_time(:millisecond)
      })

    assert wake.wake_id =~ ~r/^w_[0-9a-f-]{36}$/
    assert [^wake] = Wakes.list_pending(db)
    refute Wakes.cancel(db, wake.wake_id, "agent:b")
    assert Wakes.cancel(db, wake.wake_id, "agent:a")
    assert Wakes.get(db, wake.wake_id).state == "canceled"
    refute Wakes.cancel(db, wake.wake_id, "agent:a")
  end

  test "fire_due claims each due wake once across synchronous passes", %{
    db: db,
    scheduler: scheduler
  } do
    test_pid = self()

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake -> send(test_pid, {:delivered, wake}) end}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "system",
        prompt: "now",
        due_at: System.system_time(:millisecond)
      })

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:delivered, %{wake_id: wake_id, prompt: "now"}}
    assert wake_id == wake.wake_id
    assert Wakes.get(db, wake.wake_id).state == "fired"

    assert :ok = Wakes.fire_due(scheduler)
    refute_receive {:delivered, _}
  end

  test "failed delivery leaves the wake pending; it retries and then fires", %{
    db: db,
    scheduler: scheduler
  } do
    test_pid = self()
    fail_first = :counters.new(1, [])

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake ->
         if :counters.get(fail_first, 1) == 0 do
           :counters.add(fail_first, 1, 1)
           raise "delivery blew up"
         end

         send(test_pid, {:delivered, wake})
       end}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "system",
        prompt: "flaky",
        due_at: System.system_time(:millisecond)
      })

    assert :ok = Wakes.fire_due(scheduler)
    refute_receive {:delivered, _}
    assert Wakes.get(db, wake.wake_id).state == "pending"

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:delivered, %{wake_id: wake_id}}
    assert wake_id == wake.wake_id
    assert %{state: "fired", fired_at: fired_at} = Wakes.get(db, wake.wake_id)
    assert is_integer(fired_at)
  end

  test "unknown internal consumer is consumed as canceled, never claimed as fired", %{
    db: db,
    scheduler: scheduler
  } do
    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn _wake -> :ok end,
       internal_consumers: %{}}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        consumer: "missing_consumer",
        due_at: System.system_time(:millisecond)
      })

    log =
      capture_log(fn ->
        assert :ok = Wakes.fire_due(scheduler)
        assert :ok = Wakes.fire_due(scheduler)
      end)

    assert log =~ "undeliverable"
    assert log =~ "missing_consumer"
    assert length(Regex.scan(~r/missing_consumer/, log)) == 1

    # CONSUMED, so the sweep does not spin on a code bug — but never claimed as
    # delivered. `fired` is this substrate's word for delivered, and a wake nobody
    # could deliver must not wear it: this path carries owner decision
    # notifications, so a consumer-name typo would otherwise eat a decision
    # request while the row said it was delivered.
    assert %{state: "canceled", canceled_at: canceled_at, fired_at: nil} =
             Wakes.get(db, wake.wake_id)

    assert is_integer(canceled_at)

    # The durable record carries WHY, since `canceled` alone cannot distinguish a
    # deliberate cancel from an undeliverable wake.
    assert [%{kind: "wake_undeliverable", subject: subject, detail: detail}] =
             Enum.filter(EventLog.lifecycle_events(db), &(&1.kind == "wake_undeliverable"))

    assert subject == wake.wake_id
    assert detail =~ "missing_consumer"
  end

  test "exiting internal consumer leaves its wake pending and does not crash the scheduler", %{
    db: db,
    scheduler: scheduler
  } do
    scheduler_pid =
      start_supervised!(
        {Wakes,
         db: db,
         name: scheduler,
         tick_ms: 60_000,
         deliver: fn _wake -> :ok end,
         internal_consumers: %{"exiting" => fn _wake -> exit(:consumer_boom) end}}
      )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        consumer: "exiting",
        due_at: System.system_time(:millisecond)
      })

    log = capture_log(fn -> assert :ok = Wakes.fire_due(scheduler) end)

    assert Process.alive?(scheduler_pid)
    assert Wakes.get(db, wake.wake_id).state == "pending"

    # Retrying is correct — a consumer can fail transiently and succeed later.
    # Retrying SILENTLY was not: a consumer raising every tick was
    # indistinguishable from an idle scheduler, so each attempt is now recorded.
    assert log =~ "consumer_boom"

    assert [%{subject: subject, detail: detail}] =
             Enum.filter(EventLog.lifecycle_events(db), &(&1.kind == "wake_delivery_failed"))

    assert subject == wake.wake_id
    assert detail =~ "consumer_boom"

    # One row per attempt, so the repetition is itself visible.
    assert :ok = Wakes.fire_due(scheduler)

    assert length(
             Enum.filter(EventLog.lifecycle_events(db), &(&1.kind == "wake_delivery_failed"))
           ) ==
             2
  end

  test "fire_due called inside the scheduler queues another pass without self-calling", %{
    db: db,
    scheduler: scheduler
  } do
    test_pid = self()

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake -> send(test_pid, {:nested_fired, wake.wake_id}) end,
       internal_consumers: %{
         "self_fire" => fn wake ->
           nested =
             Wakes.schedule(db, %{
               session_key: "k2",
               origin: "system",
               prompt: "nested",
               due_at: System.system_time(:millisecond)
             })

           :ok = Wakes.fire_due(self())
           send(test_pid, {:self_fire_returned, wake.wake_id, nested.wake_id})
           Wakes.cancel(db, wake.wake_id, wake.origin)
         end
       }}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        consumer: "self_fire",
        due_at: System.system_time(:millisecond)
      })

    assert :ok = Wakes.fire_due(scheduler)
    assert_received {:self_fire_returned, wake_id, nested_wake_id}
    assert wake_id == wake.wake_id
    assert_receive {:nested_fired, ^nested_wake_id}
    assert Wakes.get(db, wake.wake_id).state == "canceled"
    assert Wakes.get(db, nested_wake_id).state == "fired"
  end

  test "future wakes are not claimed", %{db: db, scheduler: scheduler} do
    test_pid = self()

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake -> send(test_pid, {:delivered, wake}) end}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "system",
        prompt: "later",
        due_at: System.system_time(:millisecond) + 60_000
      })

    assert :ok = Wakes.fire_due(scheduler)
    refute_receive {:delivered, _}
    assert Wakes.get(db, wake.wake_id).state == "pending"
  end

  test "rumination markers count only after firing and are scoped by work-item and caller", %{
    db: db,
    scheduler: scheduler
  } do
    test_pid = self()

    start_supervised!(
      {Wakes,
       db: db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn wake -> send(test_pid, {:delivered, wake}) end}
    )

    wake =
      Wakes.schedule(db, %{
        session_key: "caller",
        origin: "agent:caller",
        creator_session_key: "caller",
        prompt: "digest: think first",
        due_at: System.system_time(:millisecond),
        rumination: true,
        work_item_id: "wi_one"
      })

    assert wake.rumination
    assert wake.work_item_id == "wi_one"
    refute Wakes.rumination_exists?(db, "wi_one", "caller")
    refute Wakes.rumination_exists?(db, "wi_other", "caller")
    refute Wakes.rumination_exists?(db, "wi_one", "other-caller")

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:delivered, %{wake_id: wake_id}}
    assert wake_id == wake.wake_id
    assert Wakes.rumination_exists?(db, "wi_one", "caller")
    refute Wakes.rumination_exists?(db, "wi_other", "caller")
    refute Wakes.rumination_exists?(db, "wi_one", "other-caller")
  end
end
