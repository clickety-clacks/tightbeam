defmodule Tightbeam.PiReconciliationSchemaTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema}

  setup do
    name = :"pi_schema_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    %{db: name}
  end

  test "fresh schema admits both Pi providers and survives a second boot", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    assert :ok = Schema.ensure_all(db)

    assert {:ok, [["pi-providers-artifact-content-v1-019"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert :ok =
             DB.execute(db, """
             INSERT INTO users(userId,isAdmin,createdAt) VALUES ('owner',1,1);
             INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,
               provider,model,host,createdAt,updatedAt)
             VALUES ('pi-go','Pi Go','owner','user:owner','default','pi','opencode_go',
               'opencode-go/gpt-5.6-luna','testhost',1,1),
               ('pi-spark','Pi Spark','owner','user:owner','default','pi','local_openai',
               'spark/qwen3.5-35b','testhost',1,1);
             """)

    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM sessions")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "the recorded admission predecessor advances through current migrations before Pi", %{
    db: db
  } do
    fixture = File.read!(Path.join(__DIR__, "fixtures/o2_admission_v1.sql"))

    assert Base.encode16(:crypto.hash(:sha256, fixture), case: :lower) ==
             "ad7de70a2a921045e5cb78075e3e87d08e821929b86b81b8ef5c479b3292af1e"

    assert :ok = DB.execute(db, fixture)
    assert :ok = DB.execute(db, "PRAGMA foreign_keys=ON")

    assert :ok =
             DB.execute(db, """
             INSERT INTO users(userId,isAdmin,createdAt) VALUES ('owner',1,1);
             INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,
               provider,model,host,createdAt,updatedAt)
             VALUES ('kept','Kept','owner','user:owner','default','claude','anthropic',
               'fable','remote-a',1,2);
             INSERT INTO harness_pointers(sessionKey,harnessSessionId,sourceSessionRef,harness,
               machine,reason,createdAt)
             VALUES ('kept','h-kept','source','claude','remote-a','created',3);
             """)

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [["pi-providers-artifact-content-v1-019"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, columns} = DB.query(db, "PRAGMA table_info(sessions)")
    assert Enum.any?(columns, &(Enum.at(&1, 1) == "mechanicalStatus"))

    assert {:ok, [["kept", "remote-a", "fable"]]} =
             DB.query(db, "SELECT sessionKey,host,model FROM sessions")

    assert {:ok, [["kept"]]} = DB.query(db, "SELECT sessionKey FROM harness_pointers")

    for name <- ["sessions_owner", "sessions_cli_token"] do
      assert {:ok, [[1]]} =
               DB.query(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?1", [
                 name
               ])
    end

    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
    assert :ok = Schema.ensure_all(db)
  end
end
