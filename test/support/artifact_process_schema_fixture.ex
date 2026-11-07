defmodule Tightbeam.ArtifactProcessSchemaFixture do
  @moduledoc false

  alias Tightbeam.{Artifacts, DB}
  alias Tightbeam.DB.Txn

  @predecessor_columns "artifactId,kind,title,description,createdBySession,workItemId," <>
                         "parentSession,originPath,contentSha256,contentSha256Verified," <>
                         "recordedMessageId,recordedTurnEvidence,state,home,createdAt,updatedAt"

  def rebuild_artifacts_table_to_v22!(db) do
    {:ok, :ok} =
      DB.foreign_key_rebuild(db, fn txn ->
        :ok = Txn.exec(txn, "PRAGMA legacy_alter_table=ON")

        try do
          :ok = Txn.exec(txn, "ALTER TABLE artifacts RENAME TO artifacts_process_test_source")

          :ok =
            Txn.exec(txn, "CREATE TABLE artifacts (#{Artifacts.previous_table_definition()})")

          :ok =
            Txn.exec(
              txn,
              "INSERT INTO artifacts (#{@predecessor_columns}) " <>
                "SELECT #{@predecessor_columns} FROM artifacts_process_test_source"
            )

          :ok = Txn.exec(txn, "DROP TABLE artifacts_process_test_source")

          Enum.each(Artifacts.previous_index_ddl(), &Txn.exec(txn, &1))
          :ok
        after
          :ok = Txn.exec(txn, "PRAGMA legacy_alter_table=OFF")
        end
      end)

    :ok
  end
end
