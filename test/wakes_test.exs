defmodule Tightbeam.WakesTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{ConditionFacts, DB, Wakes}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    scheduler = :"wake_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = ConditionFacts.ensure_schema(name)
    :ok = Wakes.ensure_schema(name)
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
end
