defmodule Tightbeam.IdentityPredecessorFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias Tightbeam.{DB, Schema}

  # Rebuild the identity migration's input from the frozen admission predecessor.
  # Copy its table definitions, never a current definition with an older stamp.
  # Existing fixture rows must satisfy those historical constraints.
  def restore!(db) do
    {:ok, source} = DB.start_link(path: ":memory:", name: nil)

    try do
      sql = File.read!(Path.expand("../fixtures/o2_admission_v1.sql", __DIR__))

      assert Base.encode16(:crypto.hash(:sha256, sql), case: :lower) ==
               "ad7de70a2a921045e5cb78075e3e87d08e821929b86b81b8ef5c479b3292af1e"

      :ok = DB.execute(source, sql)
      :ok = DB.execute(source, "PRAGMA foreign_keys=ON")

      :ok =
        DB.execute(source, """
        CREATE TRIGGER fixture_identity_boundary BEFORE UPDATE ON schema_stamp
        WHEN NEW.shape='session-identity-v1-0114'
        BEGIN SELECT RAISE(ABORT, 'fixture identity boundary'); END;
        """)

      assert_raise Schema.ShapeError, ~r/session identity migration rolled back/, fn ->
        Schema.ensure_all(source)
      end

      assert {:ok, [["launch-preparation-evidence-v1-0112"]]} =
               DB.query(source, "SELECT shape FROM schema_stamp")

      tables =
        ~w(decision_requests work_items work_item_bodies assignments attests assignment_reopenings assignment_revocations assignment_cannot_proceed assignment_commit_ref_corrections memento_history session_reparent_events) ++
          for object <- Tightbeam.Toplines.Schema.manifest(),
              object.type == "table",
              do: object.name

      definitions =
        Enum.map(tables, fn table ->
          assert {:ok, [[ddl]]} =
                   DB.query(
                     source,
                     "SELECT sql FROM sqlite_master WHERE type='table' AND name=?1",
                     [table]
                   )

          {table, ddl}
        end)

      assert {:ok, [[topline_stamp]]} = DB.query(source, "SELECT shape FROM topline_schema_stamp")

      assert {:ok, :ok} =
               DB.migration_transaction(
                 db,
                 :identity_predecessor_fixture,
                 [],
                 ["PRAGMA writable_schema=OFF"],
                 fn txn ->
                   [[version]] = DB.Txn.q(txn, "PRAGMA schema_version")
                   :ok = DB.Txn.exec(txn, "PRAGMA writable_schema=ON")

                   for {table, ddl} <- definitions do
                     DB.Txn.q(
                       txn,
                       "UPDATE sqlite_master SET sql=?2 WHERE type='table' AND name=?1",
                       [table, ddl]
                     )
                   end

                   DB.Txn.q(txn, "UPDATE topline_schema_stamp SET shape=?1", [topline_stamp])
                   :ok = DB.Txn.exec(txn, "DROP INDEX events_process_assignment")
                   :ok = DB.Txn.exec(txn, "PRAGMA schema_version=#{version + 1}")
                   :ok = DB.Txn.exec(txn, "PRAGMA writable_schema=RESET")
                 end
               )

      for {table, ddl} <- definitions do
        assert {:ok, [[^ddl]]} =
                 DB.query(db, "SELECT sql FROM sqlite_master WHERE type='table' AND name=?1", [
                   table
                 ])
      end

      assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
      assert {:ok, [["ok"]]} = DB.query(db, "PRAGMA integrity_check")
      :ok
    after
      GenServer.stop(source)
    end
  end
end
