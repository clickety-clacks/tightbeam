defmodule Tightbeam.PublishedSchemaCompatibilityTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Schema}

  # Captured by Schema.ensure_all/1 from published v0.1.14+3678,
  # commit 4d73025cbc0e6f2e1e33dc0e100d83034dd00cb7, using its pinned toolchain.
  # This is a synthetic database, never an installation snapshot.
  @fixture Path.join(__DIR__, "fixtures/published_0_1_14_3678.sql.gz.b64")

  test "published v7 database upgrades through ordinary startup and preserves actor constraints" do
    bytes = @fixture |> File.read!() |> String.trim() |> Base.decode64!() |> :zlib.gunzip()
    db = start_supervised!({DB, path: ":memory:", name: :published_schema_compatibility})

    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
             "33a26706bf263febe16a70dfda48c2f8a7ee076d6f7ec18c4cf8d192f3bc0032"

    # In-memory owners create this empty retry table before schema activation.
    assert :ok = DB.execute(db, "DROP TABLE pending_recognition")
    assert :ok = DB.execute(db, bytes)
    assert :ok = DB.execute(db, "PRAGMA foreign_keys=ON")

    assert {:ok, [["session-identity-v1-0114"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, [["standalone-toplines-v7"]]} =
             DB.query(db, "SELECT shape FROM topline_schema_stamp")

    before = actor_schema(db)
    assert :ok = Schema.ensure_all(db)

    assert {:ok, [["closed-assignment-cannot-proceed-reconciliation-v1-015"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert actor_schema(db) == before

    assert {:ok, [["Published fixture", "user", "fixture-owner"]]} =
             DB.query(db, "SELECT title,createdActorKind,createdActorRef FROM toplines")

    assert_check_failure(db, "UPDATE toplines SET createdActorKind='unknown'")
    assert :ok = Schema.ensure_all(db)
    assert actor_schema(db) == before
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
    assert {:ok, [["ok"]]} = DB.query(db, "PRAGMA integrity_check")
    assert_attest_actors(db)
    assert_topline_cause_actors(db)
  end

  test "new database migration permits single or process verdict actors but never both typed actors" do
    db = start_supervised!({DB, path: ":memory:", name: :fresh_actor_compatibility})
    assert :ok = Schema.ensure_all(db)

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('fixture-owner',1,1)"
             )

    assert_attest_actors(db)
    assert_topline_cause_actors(db)
  end

  defp assert_attest_actors(db) do
    session = ensure_main_session(db, "fixture-owner")

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt) VALUES ('actor-fixture','Actor fixture',?1,'fixture-owner',1)",
               [session.session_key]
             )

    sql = """
    INSERT INTO attests(id,assignmentId,kind,verdictKind,bySession,byUser,ts)
    VALUES (?1,'actor-fixture','verdict','verified',?2,?3,1)
    """

    for {id, by_session, by_user} <- [
          {"session-verdict", session.session_key, nil},
          {"user-verdict", nil, "fixture-owner"},
          {"process-verdict", nil, nil}
        ] do
      assert {:ok, _} = DB.query(db, sql, [id, by_session, by_user])
    end

    assert {:error, error} =
             DB.query(db, sql, ["both-verdict", session.session_key, "fixture-owner"])

    assert Exception.message(error) =~ "CHECK constraint failed"

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM attests WHERE bySession IS NOT NULL AND byUser IS NOT NULL"
             )
  end

  defp assert_topline_cause_actors(db) do
    assert :ok =
             DB.execute(db, """
             INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt)
             VALUES ('work-fixture','Fixture work','fixture-owner','fixture-owner',1);
             INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt)
             VALUES ('wake-fixture','fixture-session','process:test','Fixture wake',1,1);
             INSERT INTO topline_placement_obligations
               (id,workItemId,ownerUserId,cause,causeRef,historyCausalSeq,
                openedActorKind,openedActorRef,state,openedAt,dueAt,promptWakeId)
             VALUES ('tlp_fixture','work-fixture','fixture-owner','migration','fixture',0,
                     'process','tightbeam','pending',1,1,'wake-fixture');
             """)

    assert_check_failure(
      db,
      "UPDATE topline_placement_obligations SET openedActorKind='user',openedActorRef='fixture-owner'"
    )

    assert_check_failure(
      db,
      "UPDATE topline_placement_obligations SET openedActorRef='other-process'"
    )

    assert {:ok, [["process", "tightbeam"]]} =
             DB.query(
               db,
               "SELECT openedActorKind,openedActorRef FROM topline_placement_obligations"
             )
  end

  defp actor_schema(db) do
    {:ok, rows} =
      DB.query(db, """
      SELECT name,sql FROM sqlite_schema
      WHERE type='table' AND (name='attests' OR name LIKE 'topline%')
      ORDER BY name
      """)

    rows
  end

  defp assert_check_failure(db, sql) do
    assert {:error, error} = DB.query(db, sql)
    assert Exception.message(error) =~ "CHECK constraint failed"
  end
end
