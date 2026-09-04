defmodule Tightbeam.ToplinesSchemaTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.DB
  alias Tightbeam.Toplines.Schema, as: ToplinesSchema

  test "first activation commits the exact manifest and stamp, then replays without writes" do
    db = base_db!()

    assert :ok = ToplinesSchema.activate(db, 123)

    assert {:ok, [[1, "standalone-toplines-v5", 123]]} =
             DB.query(db, "SELECT singleton, shape, stampedAt FROM topline_schema_stamp")

    expected =
      ToplinesSchema.manifest()
      |> Enum.map(&[&1.type, &1.name, &1.sql])
      |> Enum.sort_by(&Enum.at(&1, 1))

    names = Enum.map(ToplinesSchema.manifest(), & &1.name)
    placeholders = Enum.map_join(1..length(names), ",", &"?#{&1}")

    assert {:ok, ^expected} =
             DB.query(
               db,
               "SELECT type, name, sql FROM sqlite_schema WHERE name IN (#{placeholders}) ORDER BY name",
               names
             )

    before = snapshot(db)
    assert :ok = ToplinesSchema.activate(db, 999)
    assert snapshot(db) == before
  end

  test "the connection registers deterministic title functions before schema activation" do
    db = base_db!()

    assert {:ok, [["Café", 2, nil, nil]]} =
             DB.query(
               db,
               """
               SELECT tightbeam_canonical_title(?1),
                      tightbeam_unicode_scalar_length(?2),
                      tightbeam_canonical_title(1),
                      tightbeam_unicode_scalar_length(1)
               """,
               ["\u00a0Cafe\u0301\u3000", "é💩"]
             )

    assert :ok = ToplinesSchema.activate(db, 1)
    insert_topline!(db, "Café")

    for invalid <- [" Cafe", "Cafe\u0301", "", String.duplicate("a", 2_001), 1] do
      assert {:error, %DB.Error{}} = insert_topline(db, invalid)
    end
  end

  test "an empty, unknown, or altered stamp refuses before any write" do
    stamp = Enum.find(ToplinesSchema.manifest(), &(&1.name == "topline_schema_stamp"))

    empty = base_db!()
    :ok = DB.execute(empty, stamp.sql)
    before = snapshot(empty)

    assert {:error, %{code: "unregistered_toplines_core_shape"}} =
             ToplinesSchema.activate(empty, 2)

    assert snapshot(empty) == before

    unknown = base_db!()
    :ok = DB.execute(unknown, stamp.sql)

    {:ok, _} =
      DB.query(
        unknown,
        "INSERT INTO topline_schema_stamp (singleton, shape, stampedAt) VALUES (1, 'other', 1)"
      )

    before = snapshot(unknown)

    assert {:error, %{code: "unknown_toplines_schema_stamp"}} =
             ToplinesSchema.activate(unknown, 2)

    assert snapshot(unknown) == before

    altered = base_db!()

    :ok =
      DB.execute(
        altered,
        "CREATE TABLE topline_schema_stamp (singleton INTEGER PRIMARY KEY, shape TEXT, stampedAt INTEGER)"
      )

    before = snapshot(altered)
    assert {:error, %{code: "schema_shape_mismatch"}} = ToplinesSchema.activate(altered, 2)
    assert snapshot(altered) == before
  end

  test "every manifest object without a production stamp is an unregistered core refusal" do
    objects = Enum.reject(ToplinesSchema.manifest(), &(&1.name == "topline_schema_stamp"))

    Enum.with_index(objects, 1)
    |> Enum.each(fn {_target, count} ->
      db = base_db!()

      objects
      |> Enum.take(count)
      |> Enum.each(fn object -> :ok = DB.execute(db, object.sql) end)

      before = snapshot(db)

      assert {:error, %{code: "unregistered_toplines_core_shape"}} =
               ToplinesSchema.activate(db, 10)

      assert snapshot(db) == before
    end)
  end

  test "each missing or altered stamped object refuses without repair" do
    Enum.each(ToplinesSchema.manifest(), fn object ->
      missing = activated_db!()
      :ok = DB.execute(missing, "DROP #{String.upcase(object.type)} #{object.name}")
      before = snapshot(missing)

      expected =
        if object.name == "topline_schema_stamp",
          do: "unregistered_toplines_core_shape",
          else: "schema_shape_mismatch"

      assert {:error, %{code: ^expected}} = ToplinesSchema.activate(missing, 10)
      assert snapshot(missing) == before

      altered = activated_db!()
      alter_object!(altered, object)
      before = snapshot(altered)
      assert {:error, %{code: "schema_shape_mismatch"}} = ToplinesSchema.activate(altered, 10)
      assert snapshot(altered) == before
    end)
  end

  test "activation interruption rolls back on both sides of stamp insertion" do
    for point <- [1, :after_stamp] do
      db = base_db!()

      assert_raise RuntimeError, ~r/activation interrupted/, fn ->
        ToplinesSchema.activate(db, 123, interrupt_after: point)
      end

      assert {:ok, []} =
               DB.query(
                 db,
                 "SELECT name FROM sqlite_schema WHERE name LIKE 'topline%' ORDER BY name"
               )

      assert :ok = ToplinesSchema.activate(db, 124)
    end
  end

  test "an after-commit database crash restarts with the exact stamped shape and rows" do
    unique = System.unique_integer([:positive])
    db = :"toplines_schema_restart_#{unique}"
    path = Path.join(System.tmp_dir!(), "toplines-schema-restart-#{unique}.db")

    on_exit(fn ->
      if pid = Process.whereis(db), do: GenServer.stop(pid)
      Enum.each([path, path <> "-shm", path <> "-wal"], &File.rm/1)
    end)

    {:ok, first} = DB.start_link(path: path, name: db)
    Process.unlink(first)
    seed_base_schema!(db)
    assert :ok = ToplinesSchema.activate(db, 123)
    insert_topline!(db, "Durable")
    before = snapshot(db)

    monitor = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^first, :killed}, 1_000

    {:ok, second} = DB.start_link(path: path, name: db)
    Process.unlink(second)
    assert :ok = ToplinesSchema.activate(db, 999)
    assert snapshot(db) == before
  end

  test "the exact prior Concern shape refuses without changing schema or rows" do
    db = activated_db!()

    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO toplines
                 (id, ownerUserId, title, state, createdActorKind, createdActorRef,
                  createdAt, updatedAt, closedAt)
               VALUES ('tl_migrate', 'mike', 'Intent', 'open', 'user', 'mike', 1, 1, NULL)
               """
             )

    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO topline_work_memberships
                 (id, toplineId, workItemId, ownerUserId, linkReason,
                  linkedActorKind, linkedActorRef, linkedAt)
               VALUES ('tlm_migrate', 'tl_migrate', 'wi_one', 'mike', 'member',
                       'user', 'mike', 2)
               """
             )

    install_legacy_concern_shape!(db)

    before = snapshot(db)

    assert {:error, %{code: "schema_shape_mismatch"}} = ToplinesSchema.activate(db, 2)
    assert snapshot(db) == before
  end

  defp base_db! do
    db = :"toplines_schema_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db}, id: db)

    seed_base_schema!(db)
    db
  end

  defp legacy_concern_objects do
    [
      %{
        type: "table",
        name: "topline_concerns",
        sql:
          String.trim("""
          CREATE TABLE topline_concerns (
            id                TEXT PRIMARY KEY CHECK (substr(id, 1, 4) = 'tlc_'),
            toplineId         TEXT NOT NULL REFERENCES toplines(id),
            title             ANY NOT NULL,
            state             TEXT NOT NULL CHECK (state IN ('open','resolved')),
            createdActorKind  TEXT NOT NULL CHECK (createdActorKind IN ('user','session')),
            createdActorRef   TEXT NOT NULL CHECK (length(trim(createdActorRef)) > 0),
            createdAt         INTEGER NOT NULL,
            updatedAt         INTEGER NOT NULL,
            resolveReason     TEXT,
            resolvedActorKind TEXT,
            resolvedActorRef  TEXT,
            resolvedAt        INTEGER,
            CHECK (typeof(title) = 'text'),
            CHECK (tightbeam_canonical_title(title) IS NOT NULL),
            CHECK (title = tightbeam_canonical_title(title)),
            CHECK (tightbeam_unicode_scalar_length(title) BETWEEN 1 AND 2000),
            CHECK (typeof(createdAt) = 'integer'),
            CHECK (typeof(updatedAt) = 'integer' AND updatedAt >= createdAt),
            CHECK (
              (state = 'open' AND resolveReason IS NULL AND resolvedActorKind IS NULL AND
               resolvedActorRef IS NULL AND resolvedAt IS NULL) OR
              (state = 'resolved' AND resolveReason IS NOT NULL AND
               length(trim(resolveReason)) BETWEEN 1 AND 4000 AND
               resolvedActorKind IS NOT NULL AND resolvedActorKind IN ('user','session') AND
               resolvedActorRef IS NOT NULL AND length(trim(resolvedActorRef)) > 0 AND
               typeof(resolvedAt) = 'integer' AND resolvedAt >= createdAt)
            )
          )
          """)
      },
      %{
        type: "index",
        name: "topline_concerns_id_topline",
        sql: "CREATE UNIQUE INDEX topline_concerns_id_topline ON topline_concerns (id, toplineId)"
      },
      %{
        type: "table",
        name: "topline_concern_refs",
        sql:
          String.trim("""
          CREATE TABLE topline_concern_refs (
            id                TEXT PRIMARY KEY CHECK (substr(id, 1, 5) = 'tlcr_'),
            toplineId         TEXT NOT NULL,
            concernId         TEXT NOT NULL,
            membershipId      TEXT NOT NULL,
            linkReason        TEXT NOT NULL CHECK (length(trim(linkReason)) BETWEEN 1 AND 4000),
            linkedActorKind   TEXT NOT NULL CHECK (linkedActorKind IN ('user','session')),
            linkedActorRef    TEXT NOT NULL CHECK (length(trim(linkedActorRef)) > 0),
            linkedAt          INTEGER NOT NULL CHECK (typeof(linkedAt) = 'integer'),
            unlinkReason      TEXT,
            unlinkedActorKind TEXT,
            unlinkedActorRef  TEXT,
            unlinkedAt        INTEGER,
            FOREIGN KEY (concernId, toplineId) REFERENCES topline_concerns(id, toplineId),
            FOREIGN KEY (membershipId, toplineId)
              REFERENCES topline_work_memberships(id, toplineId),
            CHECK (
              (unlinkedAt IS NULL AND unlinkReason IS NULL AND
               unlinkedActorKind IS NULL AND unlinkedActorRef IS NULL) OR
              (typeof(unlinkedAt) = 'integer' AND unlinkedAt >= linkedAt AND
               unlinkReason IS NOT NULL AND
               length(trim(unlinkReason)) BETWEEN 1 AND 4000 AND
               unlinkedActorKind IS NOT NULL AND unlinkedActorKind IN ('user','session') AND
               unlinkedActorRef IS NOT NULL AND length(trim(unlinkedActorRef)) > 0)
            )
          )
          """)
      },
      %{
        type: "index",
        name: "topline_concern_refs_active_pair",
        sql:
          "CREATE UNIQUE INDEX topline_concern_refs_active_pair ON topline_concern_refs (concernId, membershipId) WHERE unlinkedAt IS NULL"
      },
      %{
        type: "index",
        name: "topline_concern_refs_id_tuple",
        sql:
          "CREATE UNIQUE INDEX topline_concern_refs_id_tuple ON topline_concern_refs (id, toplineId, concernId, membershipId)"
      },
      %{
        type: "table",
        name: "topline_events",
        sql:
          String.trim("""
          CREATE TABLE topline_events (
            toplineId          TEXT NOT NULL REFERENCES toplines(id),
            seq                 INTEGER NOT NULL CHECK (typeof(seq) = 'integer' AND seq >= 1),
            kind                TEXT NOT NULL CHECK (kind IN (
              'topline_created','topline_renamed','topline_closed','topline_reopened',
              'work_linked','work_unlinked','concern_created','concern_renamed',
              'concern_resolved','concern_reopened','concern_work_linked',
              'concern_work_unlinked'
            )),
            membershipId       TEXT,
            concernId          TEXT,
            concernReferenceId TEXT,
            actorKind           TEXT NOT NULL CHECK (actorKind IN ('user','session')),
            actorRef            TEXT NOT NULL CHECK (length(trim(actorRef)) > 0),
            reason              TEXT,
            eventAt             INTEGER NOT NULL CHECK (typeof(eventAt) = 'integer'),
            detail              TEXT NOT NULL CHECK (json_valid(detail) AND json_type(detail) = 'object'),
            PRIMARY KEY (toplineId, seq),
            FOREIGN KEY (membershipId, toplineId)
              REFERENCES topline_work_memberships(id, toplineId),
            FOREIGN KEY (concernId, toplineId) REFERENCES topline_concerns(id, toplineId),
            FOREIGN KEY (concernReferenceId, toplineId, concernId, membershipId)
              REFERENCES topline_concern_refs(id, toplineId, concernId, membershipId),
            CHECK (
              (kind IN ('topline_created','topline_renamed','topline_closed','topline_reopened') AND
               membershipId IS NULL AND concernId IS NULL AND concernReferenceId IS NULL) OR
              (kind IN ('work_linked','work_unlinked') AND membershipId IS NOT NULL AND
               concernId IS NULL AND concernReferenceId IS NULL) OR
              (kind IN ('concern_created','concern_renamed','concern_resolved','concern_reopened') AND
               membershipId IS NULL AND concernId IS NOT NULL AND concernReferenceId IS NULL) OR
              (kind IN ('concern_work_linked','concern_work_unlinked') AND
               membershipId IS NOT NULL AND concernId IS NOT NULL AND concernReferenceId IS NOT NULL)
            ),
            CHECK (
              (kind IN ('topline_created','concern_created') AND reason IS NULL) OR
              (kind NOT IN ('topline_created','concern_created') AND
               reason IS NOT NULL AND
               length(trim(reason)) BETWEEN 1 AND 4000)
            ),
            CHECK (
              COALESCE((kind IN ('topline_created','concern_created') AND
               json_type(detail, '$.title') = 'text' AND json_remove(detail, '$.title') = '{}') OR
              (kind IN ('topline_renamed','concern_renamed') AND
               json_type(detail, '$.fromTitle') = 'text' AND
               json_type(detail, '$.toTitle') = 'text' AND
               json_remove(detail, '$.fromTitle', '$.toTitle') = '{}') OR
              (kind IN ('topline_closed','topline_reopened','concern_resolved','concern_reopened') AND
               json_type(detail, '$.fromState') = 'text' AND
               json_type(detail, '$.toState') = 'text' AND
               json_remove(detail, '$.fromState', '$.toState') = '{}') OR
              (kind = 'work_linked' AND json_type(detail, '$.workItemId') = 'text' AND
               json_type(detail, '$.linkReason') = 'text' AND
               json_remove(detail, '$.workItemId', '$.linkReason') = '{}') OR
              (kind = 'work_unlinked' AND json_type(detail, '$.workItemId') = 'text' AND
               json_type(detail, '$.unlinkReason') = 'text' AND
               json_remove(detail, '$.workItemId', '$.unlinkReason') = '{}') OR
              (kind = 'concern_work_linked' AND json_type(detail, '$.membershipId') = 'text' AND
               json_type(detail, '$.linkReason') = 'text' AND
               json_remove(detail, '$.membershipId', '$.linkReason') = '{}') OR
              (kind = 'concern_work_unlinked' AND
               json_type(detail, '$.membershipId') = 'text' AND
               json_type(detail, '$.unlinkReason') = 'text' AND
               json_extract(detail, '$.cause') IN ('explicit','membership_unlinked') AND
               json_remove(detail, '$.membershipId', '$.unlinkReason', '$.cause') = '{}'), 0)
            )
          )
          """)
      },
      %{
        type: "table",
        name: "topline_idempotency",
        sql:
          String.trim("""
          CREATE TABLE topline_idempotency (
            callerUserId       TEXT NOT NULL REFERENCES users(userId),
            operation          TEXT NOT NULL CHECK (operation IN (
              'topline-create','topline-update','topline-close','topline-reopen',
              'topline-link-work','topline-unlink-work','topline-concern-create',
              'topline-concern-update','topline-concern-resolve','topline-concern-reopen',
              'topline-concern-link-work','topline-concern-unlink-work',
              'topline-work-leave-unlinked'
            )),
            idempotencyKey     TEXT NOT NULL CHECK (length(trim(idempotencyKey)) BETWEEN 1 AND 200),
            requestFingerprint TEXT NOT NULL CHECK (
              length(requestFingerprint) = 64 AND requestFingerprint NOT GLOB '*[^0-9a-f]*'
            ),
            canonicalResponse  TEXT NOT NULL CHECK (
              json_valid(canonicalResponse) AND json_type(canonicalResponse) = 'object'
            ),
            PRIMARY KEY (callerUserId, operation, idempotencyKey)
          )
          """)
      }
    ]
  end

  defp install_legacy_concern_shape!(db) do
    :ok =
      DB.execute(
        db,
        """
        DROP TABLE topline_events;
        DROP TABLE topline_concern_refs;
        DROP TABLE topline_concerns;
        DROP TABLE topline_idempotency;
        """
      )

    Enum.each(legacy_concern_objects(), fn object ->
      :ok = DB.execute(db, object.sql)
    end)

    :ok =
      DB.execute(
        db,
        """
        INSERT INTO topline_concerns VALUES
          ('tlc_migrate','tl_migrate','Risk','resolved','user','mike',3,5,
           'old lifecycle','user','mike',5);
        INSERT INTO topline_concern_refs VALUES
          ('tlcr_migrate','tl_migrate','tlc_migrate','tlm_migrate','risk',
           'user','mike',4,NULL,NULL,NULL,NULL);
        INSERT INTO topline_events VALUES
          ('tl_migrate',1,'concern_created',NULL,'tlc_migrate',NULL,
           'user','mike',NULL,3,'{"title":"Risk"}');
        INSERT INTO topline_events VALUES
          ('tl_migrate',2,'concern_work_linked','tlm_migrate','tlc_migrate','tlcr_migrate',
           'user','mike','risk',4,'{"membershipId":"tlm_migrate","linkReason":"risk"}');
        """
      )
  end

  defp seed_base_schema!(db) do
    :ok =
      DB.execute(
        db,
        """
        CREATE TABLE users (userId TEXT PRIMARY KEY);
        CREATE TABLE work_items (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          ownerUserId TEXT NOT NULL,
          state TEXT NOT NULL
        );
        CREATE TABLE wakes (wakeId TEXT PRIMARY KEY, state TEXT NOT NULL);
        CREATE TABLE causal_events (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          kind TEXT NOT NULL,
          jobRef TEXT,
          detail TEXT NOT NULL
        );
        INSERT INTO users (userId) VALUES ('mike');
        INSERT INTO work_items (id, title, ownerUserId, state)
          VALUES ('wi_one', 'Work', 'mike', 'open');
        """
      )
  end

  defp activated_db! do
    db = base_db!()
    :ok = ToplinesSchema.activate(db, 1)
    db
  end

  defp insert_topline(db, title) do
    DB.query(
      db,
      """
      INSERT INTO toplines
        (id, ownerUserId, title, state, createdActorKind, createdActorRef,
         createdAt, updatedAt, closedAt)
      VALUES (?1, 'mike', ?2, 'open', 'user', 'mike', 1, 1, NULL)
      """,
      ["tl_#{System.unique_integer([:positive])}", title]
    )
  end

  defp insert_topline!(db, title) do
    assert {:ok, []} = insert_topline(db, title)
  end

  defp alter_object!(db, %{type: "table", name: name}) do
    :ok = DB.execute(db, "ALTER TABLE #{name} ADD COLUMN altered_shape TEXT")
  end

  defp alter_object!(db, %{type: "index", name: name, sql: sql}) do
    :ok = DB.execute(db, "DROP INDEX #{name}")
    altered = String.replace(sql, ")", " DESC)", global: false)
    :ok = DB.execute(db, altered)
  end

  defp alter_object!(db, %{type: "trigger", name: name, sql: sql}) do
    :ok = DB.execute(db, "DROP TRIGGER #{name}")
    altered = String.replace(sql, "BEFORE INSERT", "BEFORE UPDATE", global: false)
    :ok = DB.execute(db, altered)
  end

  defp snapshot(db) do
    {:ok, schema} =
      DB.query(
        db,
        "SELECT type, name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
      )

    rows =
      for table <- ~w(
            toplines topline_work_memberships topline_concerns topline_concern_refs
            topline_events topline_idempotency topline_placement_obligations
            topline_schema_stamp
          ),
          {:ok, [[1]]} <- [
            DB.query(
              db,
              "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?1)",
              [table]
            )
          ],
          into: %{} do
        {:ok, values} = DB.query(db, "SELECT * FROM #{table} ORDER BY rowid")
        {table, values}
      end

    {schema, rows}
  end
end
