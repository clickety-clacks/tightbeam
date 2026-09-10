defmodule Tightbeam.TestSupport.PreF9Assignments do
  @moduledoc false
  import ExUnit.Assertions
  alias Tightbeam.DB

  def restore!(db) do
    # Restore only the pre-F9 assignment shape plus retained R1 reminder state.
    # This helper does not certify other tables or assign a historical stamp.
    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM assignments WHERE closedByProcess IS NOT NULL")

    assert "reminderState" in table_columns(db, "assignments")
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM assignment_revocations")
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM assignment_reopenings")
    :ok = DB.execute(db, "PRAGMA foreign_keys = OFF; PRAGMA legacy_alter_table = ON")

    try do
      assert {:ok, :ok} =
               DB.transaction(db, fn txn ->
                 :ok =
                   DB.Txn.exec(txn, """
                   DROP TRIGGER assignments_revocation_reason_required;
                   DROP TRIGGER assignments_revocation_reason_required_insert;
                   DROP TABLE assignment_revocation_generations;
                   DROP TABLE assignment_revocations;
                   ALTER TABLE assignment_reopenings DROP COLUMN priorClosedByProcess;
                   """)

                 objects =
                   DB.Txn.q(
                     txn,
                     "SELECT sql FROM sqlite_schema WHERE tbl_name='assignments' AND type IN ('index','trigger') AND sql IS NOT NULL ORDER BY type,name"
                   )

                 :ok =
                   DB.Txn.exec(
                     txn,
                     "ALTER TABLE assignments RENAME TO assignments_fixture_current"
                   )

                 :ok =
                   DB.Txn.exec(
                     txn,
                     File.read!(Path.join(__DIR__, "../fixtures/f6e78ae0_assignments.sql"))
                   )

                 :ok =
                   DB.Txn.exec(txn, "ALTER TABLE assignments ADD COLUMN reminderState TEXT NULL")

                 columns =
                   "id,subject,holderKey,holderRole,holderFallback,openedByUser,openedBySession,openedAt,state,outcome,closedAt,closedByUser,closedBySession,closingAttestId,workItemId,reviewsAssignmentId,holderHarness,holderProvider,reminderState"

                 :ok =
                   DB.Txn.exec(
                     txn,
                     "INSERT INTO assignments (#{columns}) SELECT #{columns} FROM assignments_fixture_current"
                   )

                 :ok = DB.Txn.exec(txn, "DROP TABLE assignments_fixture_current")
                 Enum.each(objects, fn [sql] -> :ok = DB.Txn.exec(txn, sql) end)
                 assert [] = DB.Txn.q(txn, "PRAGMA foreign_key_check")
                 :ok
               end)
    after
      :ok = DB.execute(db, "PRAGMA legacy_alter_table = OFF; PRAGMA foreign_keys = ON")
    end

    refute "closedByProcess" in table_columns(db, "assignments")
    refute "priorClosedByProcess" in table_columns(db, "assignment_reopenings")
  end

  defp table_columns(db, table) do
    {:ok, rows} = DB.query(db, "PRAGMA table_info(#{table})")
    Enum.map(rows, &Enum.at(&1, 1))
  end
end
