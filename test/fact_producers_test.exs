defmodule Tightbeam.FactProducersTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, FactProducers, Schema}

  setup do
    db = :"fact_producers_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    %{db: db}
  end

  test "demand is distinct, global and restricted to pending condition waits", %{db: db} do
    for {id, kind, scope, state} <- [
          {"one", "acme.done", "job-7", "pending"},
          {"two", "acme.done", "job-7", "pending"},
          {"three", "acme.done", nil, "pending"},
          {"four", "other.x", "a", "pending"},
          {"five", "acme.done", "job-9", "fired"},
          {"six", nil, nil, "pending"}
        ] do
      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO wakes(wakeId, sessionKey, origin, prompt, dueAt, state, createdAt, conditionKind, conditionScope)
          VALUES(?1, 'any-session', 'process:test', 'x', 100, ?2, 1, ?3, ?4)
          """,
          [id, state, kind, scope]
        )
    end

    assert %{demand: [%{kind: "acme.done", scope: nil}, %{kind: "acme.done", scope: "job-7"}]} =
             FactProducers.demand(db, ["acme."])

    assert length(FactProducers.demand(db).demand) == 3
    assert FactProducers.demand(db, ["Acme."]).demand == []
    {:ok, _} = DB.query(db, "UPDATE wakes SET state='canceled' WHERE conditionScope='job-7'")
    assert FactProducers.demand(db, ["acme."]).demand == [%{kind: "acme.done", scope: nil}]
  end

  test "renewal replaces kinds, and lapsed claims no longer serve waits", %{db: db} do
    assert %{producer: "feed", kinds: ["acme.done"], liveUntil: first} =
             FactProducers.claim(db, "feed", ["acme.done"], 1_000)

    assert %{producer: "feed", kinds: ["acme.failed"], liveUntil: second} =
             FactProducers.claim(db, "feed", ["acme.failed"], 2_000)

    assert second > first

    assert FactProducers.list(db).producers == [
             %{producer: "feed", kinds: ["acme.failed"], liveUntil: second, live: true}
           ]

    {:ok, served} = DB.transaction(db, &FactProducers.served_in_txn?(&1, "acme.failed"))
    assert served
    {:ok, _} = DB.query(db, "UPDATE fact_producer_claims SET liveUntil=0 WHERE producer='feed'")
    {:ok, served} = DB.transaction(db, &FactProducers.served_in_txn?(&1, "acme.failed"))
    refute served
    assert [%{live: false}] = FactProducers.list(db).producers
    assert %{code: "invalid"} = FactProducers.claim(db, "feed", ["x"], 3_600_001)
  end
end
