defmodule Tightbeam.EvidenceSchemaReleaseTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Schema}

  @successor "launch-preparation-evidence-v1-0112"

  test "fresh and repeated boot retain the exact release successor and evidence objects" do
    db = start_supervised!({DB, path: ":memory:", name: nil})

    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[@successor]]} = DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, [["producedByAssignmentId"]]} =
             DB.query(
               db,
               "SELECT name FROM pragma_table_info('artifacts') WHERE name='producedByAssignmentId'"
             )

    assert {:ok, [["artifactId"], ["contentSha256"]]} =
             DB.query(
               db,
               "SELECT name FROM pragma_table_info('attests') WHERE name IN ('artifactId','contentSha256') ORDER BY name"
             )

    assert {:ok,
            [
              ["artifact_contents"],
              ["memento_current"],
              ["memento_history"],
              ["memento_judgment_index_version"],
              ["memento_judgments"]
            ]} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('artifact_contents','memento_current','memento_history','memento_judgment_index_version','memento_judgments') ORDER BY name"
             )

    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[@successor]]} = DB.query(db, "SELECT shape FROM schema_stamp")
  end
end
