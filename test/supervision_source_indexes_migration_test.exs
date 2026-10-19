defmodule Tightbeam.SupervisionSourceIndexesMigrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Schema}

  @indexes ~w(
    wakes_assignment_consumer_created_order
    wakes_assignment_consumer_pending_created
    wakes_assignment_pending_created_order
    wakes_activity_source_order
    attests_activity_source_order
    attests_terminal_action_note
    artifacts_activity_source_order
    decision_requests_activity_source_order
    assignment_reopenings_activity_source_order
    wakes_pending_session_obligation
  )

  setup do
    db = :"supervision_source_indexes_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    assert :ok = Schema.ensure_all(db)
    %{db: db}
  end

  test "a fresh database has the source indexes and their record after boot", %{db: db} do
    assert present(db) == Enum.sort(@indexes)
    assert {:ok, [[0, _applied_at]]} = record(db)
    assert :done = Schema.build_supervision_source_index(db)
  end

  test "an upgraded database boots without them, then builds each once and records it",
       %{db: db} do
    assert :ok = DB.execute(db, "DROP TABLE supervision_source_indexes_migration")
    for name <- @indexes, do: assert(:ok = DB.execute(db, "DROP INDEX #{name}"))

    assert :ok = Schema.ensure_all(db)
    assert present(db) == []

    passes = for _ <- @indexes ++ [:record], do: Schema.build_supervision_source_index(db)

    assert passes == List.duplicate(:more, length(@indexes)) ++ [:done]
    assert present(db) == Enum.sort(@indexes)
    assert {:ok, [[0, applied_at]]} = record(db)

    assert :done = Schema.build_supervision_source_index(db)
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[0, ^applied_at]]} = record(db)
  end

  defp present(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT name FROM sqlite_master WHERE type='index' AND name IN (SELECT value FROM json_each(?1)) ORDER BY name",
        [JSON.encode!(@indexes)]
      )

    List.flatten(rows)
  end

  defp record(db),
    do: DB.query(db, "SELECT id,appliedAt FROM supervision_source_indexes_migration", [])
end
