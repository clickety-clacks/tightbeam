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

    before =
      Enum.map(actor_schema(db), fn
        ["attests", sql] -> ["attests", Schema.attest_lifecycle_actor_sql(sql)]
        row -> row
      end)

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [["holder-role-provenance-v1-0118"]]} =
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

  # Captured by Schema.ensure_all/1 from published v0.1.16+4283,
  # commit 78b32ec7f3e501d843c4216ae786a3e1e5abd8e4, using its pinned toolchain, then
  # given synthetic rows in the tables and columns 0.1.16 added: record-event ids on
  # a message and a wake, a turn event, a runtime change, a process-attributed
  # artifact, a decision briefing and a harness recovery notice. This is a synthetic
  # database, never an installation snapshot.
  @fixture_0_1_16 Path.join(__DIR__, "fixtures/published_0_1_16_4283.sql.gz.b64")

  test "published 0.1.16 database upgrades to the combined stamp and keeps its 0.1.16 rows" do
    bytes =
      @fixture_0_1_16 |> File.read!() |> String.trim() |> Base.decode64!() |> :zlib.gunzip()

    db = start_supervised!({DB, path: ":memory:", name: :published_0_1_16_compatibility})

    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
             "87c94a39c84f25b7c9039f51ee135640e1dad0092fda229c509f98043df82eff"

    # In-memory owners create these empty retry tables before schema activation.
    assert :ok = DB.execute(db, "DROP TABLE pending_recognition_waits")
    assert :ok = DB.execute(db, "DROP TABLE pending_recognition")
    assert :ok = DB.execute(db, bytes)
    assert :ok = DB.execute(db, "PRAGMA foreign_keys=ON")

    assert {:ok, [["artifact-process-attribution-v1-015"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    refute "currentOpenerSessionKey" in columns(db, "assignments")
    running_model_columns = ~w(runningModelId runningModelLabel runningModelHarness)
    assert running_model_columns -- columns(db, "sessions") == running_model_columns
    {:ok, sessions_before} = DB.query(db, "SELECT sessionKey, harness, model FROM sessions")
    assert sessions_before != []
    rows_before = release_rows(db)

    assert rows_before == %{
             messages_with_record_event_ids: [["[\"evt_seed_1\"]"]],
             wakes_with_record_event_ids: [["[\"evt_seed_2\"]"]],
             turn_events: [["assistant.segment", "agent:seed-one", 1]],
             runtime_changes: [["agent:seed-one", "pending"]],
             artifacts: [
               ["art_seedproc", nil, "process:ci"],
               ["art_seedsess", "agent:seed-one", nil]
             ],
             briefings: [["dr_seed_briefing", "fixture-owner", "staged"]],
             recovery_notices: [["hh_seed", "fixture-owner", "awaiting_main"]]
           }

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [["holder-role-provenance-v1-0118"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert release_rows(db) == rows_before
    assert "currentOpenerSessionKey" in columns(db, "assignments")
    assert ["recordEventIds", "submitter"] -- columns(db, "messages") == []

    # The running model is additive: the 0.1.16 sessions keep every value, gain the
    # three nullable columns with nothing reported, and the stamp is unchanged.
    assert running_model_columns -- columns(db, "sessions") == []

    assert {:ok, ^sessions_before} =
             DB.query(db, "SELECT sessionKey, harness, model FROM sessions")

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM sessions WHERE runningModelId IS NOT NULL OR runningModelLabel IS NOT NULL OR runningModelHarness IS NOT NULL"
             )

    schema_after = full_schema(db)
    assert :ok = Schema.ensure_all(db)
    assert full_schema(db) == schema_after
    assert release_rows(db) == rows_before
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
    assert {:ok, [["ok"]]} = DB.query(db, "PRAGMA integrity_check")
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

    for kind <- ["progress", "completion", "cannot-proceed"],
        {actor, by_session, by_user} <- [
          {"session", session.session_key, nil},
          {"user", nil, "fixture-owner"},
          {"process", nil, nil}
        ] do
      lifecycle_sql =
        "INSERT INTO attests(id,assignmentId,kind,bySession,byUser,ts) VALUES (?1,'actor-fixture',?2,?3,?4,1)"

      assert {:ok, _} = DB.query(db, lifecycle_sql, [kind <> actor, kind, by_session, by_user])

      assert {:error, _} =
               DB.query(db, lifecycle_sql, [
                 kind <> actor <> "both",
                 kind,
                 session.session_key,
                 "fixture-owner"
               ])
    end

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

  defp release_rows(db) do
    q = fn sql ->
      {:ok, rows} = DB.query(db, sql)
      rows
    end

    %{
      messages_with_record_event_ids:
        q.("SELECT recordEventIds FROM messages WHERE recordEventIds IS NOT NULL ORDER BY seq"),
      wakes_with_record_event_ids:
        q.("SELECT recordEventIds FROM wakes WHERE recordEventIds IS NOT NULL ORDER BY rowid"),
      turn_events: q.("SELECT kind,sessionKey,turnEventSeq FROM turn_events ORDER BY id"),
      runtime_changes: q.("SELECT sessionKey,state FROM runtime_changes ORDER BY seq"),
      artifacts:
        q.(
          "SELECT artifactId,createdBySession,createdByProcess FROM artifacts ORDER BY artifactId"
        ),
      briefings: q.("SELECT requestId,ownerUserId,state FROM harklight_decision_briefings"),
      recovery_notices: q.("SELECT holdId,ownerUserId,state FROM harness_recovery_notices")
    }
  end

  defp columns(db, table) do
    {:ok, rows} = DB.query(db, "PRAGMA table_info(#{table})")
    Enum.map(rows, fn [_cid, name | _] -> name end)
  end

  defp full_schema(db) do
    {:ok, rows} =
      DB.query(db, "SELECT type,name,sql FROM sqlite_master ORDER BY type,name")

    rows
  end
end
