defmodule Tightbeam.R1SchemaMigrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema}
  @fixture Path.expand("fixtures/r1_o2_v1.sql", __DIR__)
  @fixture_sha "065102fc0394262f6a7f3e71f0a8bc021fe02833875e840739c743f6837797bc"
  setup do
    db = start_supervised!({DB, name: :r1_schema_db, path: ":memory:"})
    %{db: db}
  end

  test "fresh bootstrap writes nullable R1 shape and restarts without duplicate columns", %{
    db: db
  } do
    assert :ok = Schema.ensure_all(db)
    assert shape(db) == [["cursor-provider-v1-020"]]
    assert_columns(db)
    seed(db)
    assert rows(db, "SELECT reminderState FROM assignments") == [[nil]]
    assert rows(db, "SELECT payload FROM condition_facts") == [[nil]]
    assert :ok = Schema.ensure_all(db)
    assert_columns(db)
    assert rows(db, "PRAGMA foreign_key_check") == []
  end

  test "exact O2 upgrade preserves old rows, nulls, O2 objects and stored payload on restart", %{
    db: db
  } do
    load_o2(db)
    seed(db)
    assignment_columns = columns(db, "assignments")
    assignments = rows(db, "SELECT * FROM assignments")
    facts = rows(db, "SELECT * FROM condition_facts")
    objects = guards(db)
    assert :ok = Schema.ensure_all(db)
    assert shape(db) == [["cursor-provider-v1-020"]]
    # Preserve every historical value despite Firehose's explicit table rebuild.
    assert rows(db, "SELECT #{Enum.join(assignment_columns, ",")} FROM assignments") ==
             assignments

    assert rows(db, "SELECT reminderState,closedByProcess FROM assignments") == [[nil, nil]]
    assert rows(db, "SELECT * FROM condition_facts") == Enum.map(facts, &(&1 ++ [nil]))
    object_names = Enum.map(objects, &Enum.at(&1, 1))

    assert Enum.filter(guards(db), &(Enum.at(&1, 1) in object_names)) ==
             Enum.map(objects, fn [type, name, sql] -> [type, name, firehose_guard(name, sql)] end)

    assert_columns(db)
    :ok = DB.execute(db, ~s(UPDATE assignments SET reminderState='{"version":1}'))
    :ok = DB.execute(db, ~s(UPDATE condition_facts SET payload='{"version":1}'))
    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT reminderState FROM assignments") == [[~s({"version":1})]]
    assert rows(db, "SELECT payload FROM condition_facts") == [[~s({"version":1})]]
    assert rows(db, "PRAGMA foreign_keys") == [[1]]
    assert rows(db, "PRAGMA foreign_key_check") == []
  end

  test "R1 stamp refusal rolls back both columns and preserves exact old rows and guards", %{
    db: db
  } do
    load_o2(db)
    seed(db)

    :ok =
      DB.execute(
        db,
        "CREATE TRIGGER refuse_r1 BEFORE UPDATE ON schema_stamp WHEN NEW.shape='row-driven-r1-v1-019' BEGIN SELECT RAISE(ABORT, 'R1 fixture refusal'); END"
      )

    before = snapshot(db)
    assert_raise DB.Error, fn -> Schema.ensure_all(db) end
    assert snapshot(db) == before
    assert shape(db) == [["row-driven-o2-v1-019"]]
    :ok = DB.execute(db, "DROP TRIGGER refuse_r1")
    assert :ok = Schema.ensure_all(db)
    assert_columns(db)
  end

  test "unknown shape refuses without changing rows or adopting R1", %{db: db} do
    load_o2(db)
    seed(db)
    :ok = DB.execute(db, "UPDATE schema_stamp SET shape='unknown-r1-predecessor'")
    before = snapshot(db)
    assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end
    assert snapshot(db) == before
  end

  defp load_o2(db) do
    sql = File.read!(@fixture)
    # Exact generated DDL from eff3da0a, not a relabeled successor database.
    assert Base.encode16(:crypto.hash(:sha256, sql), case: :lower) == @fixture_sha
    :ok = DB.execute(db, sql)
    assert shape(db) == [["row-driven-o2-v1-019"]]
  end

  defp seed(db) do
    :ok =
      DB.execute(
        db,
        "INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt) VALUES ('r1-fixture','r1','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt) VALUES ('r1-old','old row','r1-fixture','fixture',1)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO condition_facts(ts,kind,scope,origin,ownerUserId) VALUES (1,'fixture','r1-old','user:fixture','fixture')"
      )
  end

  defp assert_columns(db) do
    for {table, column} <- [{"assignments", "reminderState"}, {"condition_facts", "payload"}] do
      assert [[_, ^column, "TEXT", 0, nil, 0]] =
               Enum.filter(rows(db, "PRAGMA table_info(#{table})"), &(Enum.at(&1, 1) == column))
    end
  end

  defp columns(db, table), do: Enum.map(rows(db, "PRAGMA table_info(#{table})"), &Enum.at(&1, 1))

  defp shape(db), do: rows(db, "SELECT shape FROM schema_stamp")

  # Only these two historical guards change: Firehose adds rowVersion checks.
  # Preserve their terminal-principal predicate and every other object's SQL.
  defp firehose_guard(name, sql)
       when name in ~w(decision_requests_terminal_insert_guard decision_requests_terminal_update_guard) do
    assert String.contains?(sql, "\nWHEN ")
    assert String.contains?(sql, "))\nBEGIN\n")

    sql
    |> String.replace("BEFORE UPDATE OF status ON", "BEFORE UPDATE ON")
    |> String.replace(
      "\nWHEN ",
      "\nWHEN typeof(NEW.rowVersion) <> 'integer' OR NEW.rowVersion < 1 OR\n  ("
    )
    |> String.replace("))\nBEGIN\n", ")))\nBEGIN\n")
  end

  defp firehose_guard(_name, sql), do: sql

  defp guards(db),
    do:
      rows(
        db,
        "SELECT type,name,sql FROM sqlite_master WHERE type IN ('index','trigger') AND sql IS NOT NULL ORDER BY name"
      )

  defp snapshot(db),
    do:
      {rows(db, "SELECT * FROM assignments"), rows(db, "SELECT * FROM condition_facts"),
       rows(db, "SELECT * FROM schema_stamp"), rows(db, "PRAGMA table_info(assignments)"),
       rows(db, "PRAGMA table_info(condition_facts)"), guards(db)}

  defp rows(db, sql) do
    {:ok, rows} = DB.query(db, sql)
    rows
  end
end
