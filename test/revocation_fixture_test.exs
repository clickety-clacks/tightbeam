defmodule Tightbeam.RevocationFixtureTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema, RevocationFixture}

  test "fixture close binds provenance and refuses a second close without partial rows" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO users(userId,createdAt) VALUES ('flynn',1);
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
        VALUES ('holder','holder','flynn','user:flynn','coder','fixture','fixture_provider','fixture-model',1,1);
      INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,reminderState)
        VALUES ('a','synthetic','holder','flynn',1,'{ "phase": "pending" }');
      """)

    assert :ok = RevocationFixture.close!(db, "a", 700, "synthetic closure")

    assert {:ok, [["closed", "revoked", 700, "flynn", nil, "{ \"phase\": \"pending\" }"]]} =
             DB.query(
               db,
               "SELECT state,outcome,closedAt,closedByUser,closedByProcess,reminderState FROM assignments WHERE id='a'"
             )

    assert {:ok, [["synthetic closure", nil]]} =
             DB.query(
               db,
               "SELECT r.reason,g.reopeningId FROM assignment_revocations r JOIN assignment_revocation_generations g ON g.revocationId=r.id"
             )

    assert_raise MatchError, fn -> RevocationFixture.close!(db, "a", 701, "second") end
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM assignment_revocations")
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM assignment_revocation_generations")

    assert {:error, %DB.Error{}} =
             DB.query(db, "UPDATE assignments SET closedAt=702 WHERE id='a'")

    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end
end
