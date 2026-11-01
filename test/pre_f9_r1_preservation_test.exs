defmodule Tightbeam.PreF9R1PreservationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.DB

  test "assignment-only historical helper preserves R1 bytes and schema stamp" do
    db = start_supervised!({DB, path: ":memory:", name: nil})

    Tightbeam.HistoricalSchemaFixture.load!(
      db,
      "settlement_predecessor_9f47967f",
      "6a3bfab2fd5ef2ba8a132a19537f4f124c67d2018c64c0486ae37c1866f7085d"
    )

    assert {:ok, [["stale-turn-settlement-v1-019"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    :ok =
      DB.execute(db, """
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
        VALUES ('holder','holder','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1);
      INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,reminderState)
        VALUES ('null','null','holder','fixture',1,NULL),
               ('empty','empty','holder','fixture',1,''),
               ('pending','pending','holder','fixture',1,'{ "phase": "pending" }');
      """)

    assert {:ok, before} = DB.query(db, "SELECT id,reminderState FROM assignments ORDER BY id")
    assert {:ok, stamp} = DB.query(db, "SELECT * FROM schema_stamp")
    Tightbeam.TestSupport.PreF9Assignments.restore!(db)
    assert {:ok, ^before} = DB.query(db, "SELECT id,reminderState FROM assignments ORDER BY id")
    assert {:ok, ^stamp} = DB.query(db, "SELECT * FROM schema_stamp")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
    assert {:ok, [[0]]} = DB.query(db, "PRAGMA legacy_alter_table")
  end
end
