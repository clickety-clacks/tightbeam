defmodule Tightbeam.ArtifactDurabilityMigrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{Artifacts, DB, Schema}
  alias Tightbeam.DB.Txn

  @fixture Path.expand("fixtures/artifact_durability_reparent_9082cb14.sql", __DIR__)
  @fixture_sha "d8039e7a3584ab26a77aae6214c8927dfc077ab1234ba452ae61ba5731597508"
  @predecessor "session-reparent-v1-019"
  @successor "stale-turn-settlement-v1-019"

  @content_objects [
    "artifact_contents",
    "artifact_contents_released_immutable",
    "artifact_contents_released_retained",
    "artifacts_released_requires_content_insert",
    "artifacts_released_requires_content_update"
  ]

  @clear_attempt_objects ["turn_clear_attempts", "turn_clear_attempts_turn"]

  setup do
    db = start_supervised!({DB, name: :artifact_durability_migration, path: ":memory:"})
    sql = File.read!(@fixture)
    assert Base.encode16(:crypto.hash(:sha256, sql), case: :lower) == @fixture_sha
    :ok = DB.execute(db, sql)
    :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    assert rows(db, "SELECT shape FROM schema_stamp") == [[@predecessor]]
    assert content_objects(db) == []
    seed(db)
    %{db: db}
  end

  test "AD1 accepted predecessor boots to the terminal stamp with usable durability storage",
       %{db: db} do
    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT shape FROM schema_stamp") == [[@successor]]
    assert content_objects(db) == @content_objects
    assert clear_attempt_objects(db) == @clear_attempt_objects
    assert rows(db, "PRAGMA foreign_key_check") == []

    seed_artifact(db, "art_use_1", "in-workspace")

    # Archive carries a home. That records where the workspace went, not that the
    # bytes were readable, so `archived` is NOT the custody fact: see AD6. Custody
    # is the stored content row itself.
    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE artifacts SET state='archived',home='/w/art_use_1' WHERE artifactId='art_use_1'"
             )

    bytes = <<0, 255, 1, 2, 3>> <> "durability"
    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Txn.q(
                 txn,
                 "INSERT INTO artifact_contents(artifactId,contentSha256,contentSize,content,storedAt) VALUES(?1,?2,?3,?4,?5)",
                 ["art_use_1", digest, byte_size(bytes), {:blob, bytes}, 30]
               )

               Artifacts.reserve_version_in_txn(txn, "art_use_1")

               Txn.q(
                 txn,
                 "UPDATE artifacts SET contentSha256=?1,state='released',home=NULL WHERE artifactId='art_use_1'",
                 [digest]
               )

               :ok
             end)

    # The exact bytes, embedded NUL and high byte included, survive as a blob
    # rather than being coerced through text.
    assert rows(db, "SELECT content FROM artifact_contents") == [[bytes]]
    assert rows(db, "SELECT state FROM artifacts WHERE artifactId='art_use_1'") == [["released"]]

    # B2: retained and immutable while released.
    assert {:error, %DB.Error{}} = DB.query(db, "DELETE FROM artifact_contents")

    assert {:error, %DB.Error{}} =
             DB.query(db, "UPDATE artifact_contents SET content=zeroblob(contentSize)")
  end

  test "AD2 a database already at the new stamp boots unchanged on the current module path",
       %{db: db} do
    seed_artifact(db, "art_stable_1", "in-workspace")
    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT shape FROM schema_stamp") == [[@successor]]

    objects = objects(db)
    stamp = rows(db, "SELECT * FROM schema_stamp")
    artifacts = rows(db, "SELECT * FROM artifacts ORDER BY artifactId")
    floors = rows(db, "SELECT * FROM artifact_version_floors ORDER BY artifactId")

    # The trap: a missed predecessor membership sends modules down the historical
    # R1 bootstrap and rebuilds the predecessor shape. Full object equality catches it.
    assert :ok = Schema.ensure_all(db)
    assert objects(db) == objects
    assert rows(db, "SELECT * FROM schema_stamp") == stamp
    assert rows(db, "SELECT * FROM artifacts ORDER BY artifactId") == artifacts
    assert rows(db, "SELECT * FROM artifact_version_floors ORDER BY artifactId") == floors
    assert rows(db, "PRAGMA foreign_key_check") == []
  end

  for object <- @content_objects, mutation <- [:missing, :mismatched] do
    @object object
    @mutation mutation
    test "current stamp refuses #{@mutation} #{@object} without repair or row mutation", %{db: db} do
      assert :ok = Schema.ensure_all(db)
      seed_artifact(db, "art_validation", "in-workspace")
      bytes = <<0, 255, 1>>
      digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      assert {:ok, :ok} =
               DB.transaction(db, fn txn ->
                 Tightbeam.ArtifactContent.store_in_txn(txn, "art_validation", digest, bytes, 42)
                 :ok
               end)

      [[type, sql]] = rows(db, "SELECT type,sql FROM sqlite_master WHERE name='#{@object}'")

      case {@mutation, type} do
        {:missing, _} ->
          assert :ok = DB.execute(db, "DROP #{type} #{@object}")

        {:mismatched, "table"} ->
          assert :ok = DB.execute(db, "ALTER TABLE artifact_contents ADD COLUMN unexpected TEXT")

        {:mismatched, "trigger"} ->
          assert :ok = DB.execute(db, "DROP TRIGGER #{@object}")
          changed = String.replace(sql, "released artifact", "changed artifact")
          refute changed == sql
          assert :ok = DB.execute(db, changed)
      end

      before = validation_snapshot(db)

      assert_raise Schema.ShapeError, "incompatible artifact durability object: #{@object}", fn ->
        Schema.ensure_all(db)
      end

      assert validation_snapshot(db) == before
    end
  end

  test "AD3 ensure_all is idempotent across repeated boots", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    first = objects(db)

    for _ <- 1..3 do
      assert :ok = Schema.ensure_all(db)
      assert rows(db, "SELECT shape FROM schema_stamp") == [[@successor]]
      assert objects(db) == first
      assert content_objects(db) == @content_objects
      assert rows(db, "PRAGMA foreign_key_check") == []
    end
  end

  test "AD4 legacy released rows keep the released claim, their origin and their version",
       %{db: db} do
    seed_artifact(db, "art_legacy_1", "released")
    seed_artifact(db, "art_legacy_2", "released")

    before = rows(db, "SELECT * FROM artifacts ORDER BY artifactId")
    floors_before = rows(db, "SELECT * FROM artifact_version_floors ORDER BY artifactId")

    assert :ok = Schema.ensure_all(db)

    # A released row with no stored content is the external case: bytes that
    # were never taken into custody. The migration claims no custody over it,
    # so the terminal state, the origin and the projection version all stand.
    assert rows(db, "SELECT * FROM artifacts ORDER BY artifactId") == before
    assert rows(db, "SELECT * FROM artifact_version_floors ORDER BY artifactId") == floors_before
    assert rows(db, "SELECT COUNT(*) FROM artifact_contents") == [[0]]
    assert rows(db, "PRAGMA foreign_key_check") == []

    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT * FROM artifacts ORDER BY artifactId") == before
    assert rows(db, "SELECT * FROM artifact_version_floors ORDER BY artifactId") == floors_before
  end

  test "AD6 a row Tightbeam never captured never blocks its session's retirement", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    seed_artifact(db, "art_external_1", "in-workspace")
    seed_artifact(db, "art_unread_1", "in-workspace")

    # Two shapes of uncaptured row. Retirement must be able to release both
    # (att_7669b55f §6, B1 and B3).
    #
    # The external shape: `Artifacts.archive_session/4` releases an artifact whose
    # bytes lie outside the workspace straight from `in-workspace`, home NULL,
    # never touching the workspace.
    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE artifacts SET state='released' WHERE artifactId='art_external_1'"
             )

    # The archived-but-uncaptured shape, which is the hazard §6 names outright.
    # `custody_bytes/3` declines custody on a directory origin, an unreadable one,
    # or bytes that contradict a digest declared at filing, and returns nil. The
    # workspace still moves and `home` is still set, so an `archived` row exists
    # that Tightbeam holds no bytes for. Custody is keyed on the stored content
    # row and NOT on `archived`: a predicate reading `OLD.state = 'archived'`
    # would abort this release forever and strand the session that owns it.
    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE artifacts SET state='archived',home='/w/art_unread_1' WHERE artifactId='art_unread_1'"
             )

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE artifacts SET state='released',home=NULL WHERE artifactId='art_unread_1'"
             )

    assert rows(db, "SELECT state,home FROM artifacts ORDER BY artifactId") ==
             [["released", nil], ["released", nil]]

    # B3: neither claims content it does not hold, and neither origin is rewritten.
    assert rows(db, "SELECT originPath FROM artifacts ORDER BY artifactId") ==
             [["art_external_1"], ["art_unread_1"]]

    assert rows(db, "SELECT contentSha256 FROM artifacts ORDER BY artifactId") == [[nil], [nil]]
    assert rows(db, "SELECT COUNT(*) FROM artifact_contents") == [[0]]
    assert rows(db, "PRAGMA foreign_key_check") == []
  end

  test "AD7 captured bytes may not be released or repointed unaccounted", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    seed_artifact(db, "art_captured_1", "in-workspace")

    bytes = "captured"
    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE artifacts SET state='archived',home='/w/art_captured_1' WHERE artifactId='art_captured_1'"
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO artifact_contents(artifactId,contentSha256,contentSize,content,storedAt) VALUES(?1,?2,?3,?4,30)",
               ["art_captured_1", digest, byte_size(bytes), {:blob, bytes}]
             )

    # Custody taken, and the row does not account for it: the terminal transition
    # is refused. This is the test that fails if the trigger is made a no-op.
    assert {:error, %DB.Error{message: message}} =
             DB.query(
               db,
               "UPDATE artifacts SET state='released',home=NULL WHERE artifactId='art_captured_1'"
             )

    assert message =~ "released artifact requires durable content"

    assert rows(db, "SELECT state FROM artifacts WHERE artifactId='art_captured_1'") ==
             [["archived"]]

    # Accounting for the wrong bytes is refused for the same reason: a released
    # row's declared digest must name the bytes actually held.
    assert {:error, %DB.Error{}} =
             DB.query(
               db,
               "UPDATE artifacts SET contentSha256='" <>
                 String.duplicate("0", 64) <>
                 "',state='released',home=NULL WHERE artifactId='art_captured_1'"
             )

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE artifacts SET contentSha256=?1,state='released',home=NULL WHERE artifactId='art_captured_1'",
               [digest]
             )

    # B2: a released row that DOES hold custody bytes cannot later be repointed
    # away from them, so the guard is not spent once the state is set.
    assert {:error, %DB.Error{}} =
             DB.query(
               db,
               "UPDATE artifacts SET contentSha256='" <>
                 String.duplicate("0", 64) <> "' WHERE artifactId='art_captured_1'"
             )

    assert rows(db, "SELECT contentSha256 FROM artifacts WHERE artifactId='art_captured_1'") ==
             [[digest]]
  end

  test "AD8 the terminal stamp still refuses a pre-reparent liveness carrier", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT shape FROM schema_stamp") == [[@successor]]

    [[reparented]] =
      rows(
        db,
        "SELECT sql FROM sqlite_master WHERE name='supervision_liveness_sidecar_insert_coherent'"
      )

    # Reverse the reparent substitution to recover the literal pre-reparent form.
    # Pasting a copy of that DDL here would let the two drift apart silently.
    pre_reparent =
      reparented
      |> String.replace(
        "SELECT sessionKey,#{Tightbeam.Org.current_parent_sql("sessions")} FROM sessions",
        "SELECT sessionKey,spawnedBy FROM sessions"
      )
      |> String.replace(
        "SELECT ancestor.sessionKey,#{Tightbeam.Org.current_parent_sql("ancestor")}",
        "SELECT ancestor.sessionKey,ancestor.spawnedBy"
      )

    # Without this the test would pass vacuously if the reversal matched nothing.
    refute pre_reparent == reparented

    :ok = DB.execute(db, "DROP TRIGGER supervision_liveness_sidecar_insert_coherent")
    :ok = DB.execute(db, pre_reparent)

    # `ensure_supervision_liveness_v1_in_txn` resolves the EXPECTED carrier from
    # the stamp. The new stamp was added to that branch, so the reparented form
    # is still what this database owes. Drop the successor from the branch and
    # the historical objects become the expectation, this stale carrier
    # validates, and the refusal below does not happen. Skip the validation call
    # and it does not happen either.
    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end
    assert error.message =~ "incompatible_supervision_liveness_v1"
    assert error.message =~ "supervision_liveness_sidecar_insert_coherent"

    # Refused before mutating anything: the stamp and the stale carrier stand.
    assert rows(db, "SELECT shape FROM schema_stamp") == [[@successor]]

    assert rows(
             db,
             "SELECT sql FROM sqlite_master WHERE name='supervision_liveness_sidecar_insert_coherent'"
           ) == [[pre_reparent]]
  end

  test "AD5 a contradictory existing content object refuses without adopting it", %{db: db} do
    :ok = DB.execute(db, "CREATE TABLE artifact_contents (wrong TEXT)")
    before = snapshot(db)

    assert_raise Schema.ShapeError, ~r/artifact durability objects/, fn ->
      Schema.ensure_all(db)
    end

    assert snapshot(db) == before
    assert clear_attempt_objects(db) == []
  end

  defp seed(db) do
    :ok =
      DB.execute(
        db,
        "INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt) VALUES('durability-fixture','durability','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt) VALUES('wi_durability_fixture','Durability fixture','fixture','fixture',1)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt) VALUES('asg_durability_fixture','Durability fixture','durability-fixture','fixture',1)"
      )
  end

  defp seed_artifact(db, id, state) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO artifacts(artifactId,kind,title,createdBySession,workItemId,producedByAssignmentId,originPath,contentSha256,state,createdAt,updatedAt) VALUES(?1,'report','fixture','durability-fixture','wi_durability_fixture','asg_durability_fixture',?1,NULL,?2,10,20)",
        [id, state]
      )

    {:ok, _} = DB.query(db, "INSERT INTO artifact_version_floors VALUES(?1,50)", [id])

    :ok
  end

  defp rows(db, sql) do
    {:ok, rows} = DB.query(db, sql)
    rows
  end

  defp objects(db),
    do:
      rows(
        db,
        "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name"
      )

  defp content_objects(db) do
    rows(
      db,
      "SELECT name FROM sqlite_master WHERE name IN ('artifact_contents','artifacts_released_requires_content_insert','artifacts_released_requires_content_update','artifact_contents_released_immutable','artifact_contents_released_retained') ORDER BY name"
    )
    |> List.flatten()
  end

  defp clear_attempt_objects(db) do
    rows(
      db,
      "SELECT name FROM sqlite_master WHERE name IN ('turn_clear_attempts','turn_clear_attempts_turn') ORDER BY name"
    )
    |> List.flatten()
  end

  defp validation_snapshot(db) do
    contents =
      if "artifact_contents" in content_objects(db),
        do: rows(db, "SELECT * FROM artifact_contents ORDER BY artifactId"),
        else: :missing

    {snapshot(db), rows(db, "SELECT * FROM artifact_version_floors ORDER BY artifactId"),
     contents}
  end

  defp snapshot(db),
    do:
      {objects(db), rows(db, "SELECT * FROM schema_stamp"),
       rows(db, "SELECT * FROM artifacts ORDER BY artifactId")}
end
