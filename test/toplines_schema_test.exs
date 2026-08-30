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
