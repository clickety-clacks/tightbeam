defmodule Tightbeam.AssignmentSourceReplacementMigrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Schema}

  @predecessor "work-item-delivery-owner-v1-019"
  @successor "closed-assignment-cannot-proceed-reconciliation-v1-015"
  @replacement_route ~r/\(requesterId = 'tightbeam:assignments' AND reasonKind = 'superseded' AND\s+causalSourceKind = 'wake' AND outcomeKind = 'replacement'\)\s+OR/

  setup do
    db = :"assignment_source_replacement_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    Tightbeam.HistoricalSchemaFixture.load!(
      db,
      "delivery_predecessor_940ac483",
      "3b6e52b240291a125c87449c203fe5b32a1bc5c8c6e79efb2f5415681e06a3a9"
    )

    assert rows(db, "SELECT shape FROM schema_stamp") == [[@predecessor]]

    assert :ok =
             DB.execute(
               db,
               "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('flynn',1,1)"
             )

    # Current Org readers require retirement tables absent in this predecessor.
    assert :ok =
             DB.execute(db, """
             INSERT INTO sessions
               (sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,
                host,createdAt,updatedAt)
             VALUES ('assignment-replacement-holder','Replacement holder','flynn',
               'agent:assignment-replacement-holder','default','claude','anthropic','fable',
               'testhost',1,1);
             """)

    # Seed through the historical columns and typed cancellation guards.
    # Current wake APIs require source columns added after this predecessor.
    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Tightbeam.DB.Txn.exec(txn, """
               INSERT INTO events(id,ts,kind,verb,origin,principal,sessionKey,payload)
               VALUES (1,2,'verb','cancel-wake','agent:assignment-replacement-holder',
                 'session:assignment-replacement-holder','assignment-replacement-holder','{}');
               INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt,creatorSessionKey)
               VALUES ('historical-wake','assignment-replacement-holder','agent:assignment-replacement-holder',
                 'withdraw this wake',60000,1,'assignment-replacement-holder');
               INSERT INTO wake_cancellations(wakeId,canceledAt,requesterKind,requesterId,reasonKind,
                 causalSourceKind,causalSourceId,outcomeKind,workImpactKind,actionNeeded)
               VALUES ('historical-wake',2,'session','assignment-replacement-holder','requester_withdrew',
                 'verb_call','1','no_replacement','no_linked_work',0);
               UPDATE wakes SET state='canceled',canceledAt=2 WHERE wakeId='historical-wake';
               """)
             end)

    before_rows = rows(db, "SELECT * FROM wake_cancellations ORDER BY wakeId")
    assert length(before_rows) == 1

    assert rows(db, "SELECT shape FROM schema_stamp") == [[@predecessor]]
    %{db: db, before_rows: before_rows}
  end

  test "the exact predecessor widens only sender replacement and preserves cancellation rows",
       %{db: db, before_rows: before_rows} do
    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT shape FROM schema_stamp") == [[@successor]]
    assert rows(db, "SELECT * FROM wake_cancellations ORDER BY wakeId") == before_rows
    assert rows(db, "PRAGMA foreign_key_check") == []

    assert [[table_sql]] =
             rows(
               db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='wake_cancellations'"
             )

    assert Regex.match?(@replacement_route, table_sql)
    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT * FROM wake_cancellations ORDER BY wakeId") == before_rows
  end

  defp rows(db, sql) do
    assert {:ok, rows} = DB.query(db, sql)
    rows
  end
end
