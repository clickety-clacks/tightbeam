defmodule Tightbeam.ToplinesSchemaTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.DB
  alias Tightbeam.Toplines.Schema, as: ToplinesSchema

  test "first activation commits the exact manifest and stamp, then replays without writes" do
    db = base_db!()

    assert :ok = ToplinesSchema.activate(db, 123)

    assert {:ok, [[1, "standalone-toplines-v6", 123]]} =
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

  test "legacy V5 title constraints remain supported until the portable migration" do
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

    :ok = DB.execute(db, File.read!("test/fixtures/toplines_v5.sql"))
    insert_topline!(db, "Café")

    for invalid <- [" Cafe", "Cafe\u0301", "", String.duplicate("a", 2_001), 1] do
      assert {:error, %DB.Error{}} = insert_topline(db, invalid)
    end

    assert :ok = ToplinesSchema.activate(db, 124)
    assert {:ok, [["Café"]]} = DB.query(db, "SELECT title FROM toplines")
    assert {:error, %DB.Error{}} = insert_topline(db, 1)
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

  @tag :tmp_dir
  test "an after-commit database crash restarts with the exact stamped shape and rows", %{
    tmp_dir: tmp
  } do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "guard_toplines_runtime.exs",
      "guarded-toplines-crash: ok"
    )
  end

  @tag :tmp_dir
  test "populated V5 migration is atomic, portable to bare SQLite, and reopens", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "guard_toplines_portable_runtime.exs",
      "guarded-toplines-portable: ok"
    )
  end

  test "V5 drift, extensions, and unknown incoming relationships refuse without writes" do
    for sql <- [
          "ALTER TABLE toplines ADD COLUMN unexpected TEXT",
          "DROP INDEX toplines_id_owner",
          "CREATE INDEX extra_title ON toplines(title)",
          "CREATE TRIGGER extra_title AFTER INSERT ON toplines BEGIN SELECT 1; END",
          "CREATE TABLE extra_child (id TEXT REFERENCES toplines(id) ON DELETE CASCADE)"
        ] do
      db = base_db!()
      :ok = DB.execute(db, File.read!("test/fixtures/toplines_v5.sql"))
      :ok = DB.execute(db, sql)
      before = snapshot(db)
      assert {:error, %{code: "schema_shape_mismatch"}} = ToplinesSchema.activate(db, 124)
      assert snapshot(db) == before
      assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
    end
  end

  test "invalid V5 title data refuses migration rather than legitimizing it" do
    db = base_db!()
    :ok = DB.execute(db, File.read!("test/fixtures/toplines_v5.sql"))
    :ok = DB.execute(db, "PRAGMA ignore_check_constraints=ON")
    insert_topline!(db, " Cafe ")
    :ok = DB.execute(db, "PRAGMA ignore_check_constraints=OFF")
    before = snapshot(db)
    assert_raise RuntimeError, ~r/invalid titles/, fn -> ToplinesSchema.activate(db, 124) end
    assert snapshot(db) == before
  end

  test "a copied row constraint failure restores the entire V5 schema and data" do
    db = base_db!()
    :ok = DB.execute(db, File.read!("test/fixtures/toplines_v5.sql"))
    insert_topline!(db, "Valid")
    :ok = DB.execute(db, "PRAGMA ignore_check_constraints=ON")
    :ok = DB.execute(db, "UPDATE toplines SET state='invalid'")
    :ok = DB.execute(db, "PRAGMA ignore_check_constraints=OFF")
    before = snapshot(db)

    assert_raise MatchError, ~r/CHECK constraint failed/, fn ->
      ToplinesSchema.activate(db, 124)
    end

    assert snapshot(db) == before
    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
    assert {:ok, [[0]]} = DB.query(db, "PRAGMA defer_foreign_keys")
    assert {:ok, []} = DB.query(db, "SELECT name FROM sqlite_temp_schema")
  end

  test "a pre-existing relationship violation cannot acquire a V6 success stamp" do
    db = base_db!()
    :ok = DB.execute(db, File.read!("test/fixtures/toplines_v5.sql"))
    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")

    :ok =
      DB.execute(db, """
      INSERT INTO topline_concerns VALUES('tlc_orphan','tl_missing','Concern','user','mike',1)
      """)

    :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    before = snapshot(db)

    assert_raise RuntimeError, ~r/invalid foreign keys/, fn ->
      ToplinesSchema.activate(db, 124)
    end

    assert snapshot(db) == before
    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
    assert {:ok, [[0]]} = DB.query(db, "PRAGMA defer_foreign_keys")
  end

  defp base_db! do
    db = :"toplines_schema_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db}, id: db)

    seed_base_schema!(db)
    db
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
