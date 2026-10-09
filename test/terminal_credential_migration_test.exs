defmodule Tightbeam.TerminalCredentialMigrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Schema}

  @predecessor "stale-turn-settlement-v1-019"
  @terminal_shape "terminal-credential-failure-v1-019"
  @artifact_origin_shape "artifact-origin-v1-019"
  @agent_reparent_shape "delivery-owner-reparent-v1-019"
  @successor "notice-source-storage-v1-019"
  @identity_publication_denial_diagnostic_shape "identity-publication-denial-diagnostic-v1-019"

  @terminal_objects ~w(
    terminal_credential_deliveries
    terminal_credential_delivery_identity_immutable
    terminal_credential_delivery_incident
    terminal_credential_delivery_no_delete
    terminal_credential_incident_identity_immutable
    terminal_credential_incident_no_delete
    terminal_credential_incidents
    terminal_credential_observation_immutable
    terminal_credential_observation_incident
    terminal_credential_observation_no_delete
    terminal_credential_observations
    terminal_credential_one_open_key
    terminal_credential_open_provider
    terminal_credential_redirect_destinations
    terminal_credential_redirect_immutable
    terminal_credential_redirect_no_delete
    terminal_credential_redirects
    terminal_credential_resolution_immutable
  )

  setup do
    db = :"terminal_credential_migration_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    Tightbeam.SchemaShapeRuntimeFixture.downgrade_assignment_source_replacement_cancellation!(db)

    # The credential successor is additive, so removing exactly its owned objects
    # recreates the landed settlement predecessor without rewriting any historical
    # table or pretending a different stored shape has the same schema.
    :ok =
      DB.execute(db, """
      DROP TRIGGER artifacts_origin_immutable;
      ALTER TABLE artifacts DROP COLUMN originHost;
      ALTER TABLE artifacts DROP COLUMN originWorkspace;
      DROP TABLE terminal_credential_deliveries;
      DROP TABLE terminal_credential_redirects;
      DROP TABLE terminal_credential_observations;
      DROP TABLE terminal_credential_incidents;
      ALTER TABLE work_items DROP COLUMN deliveryOwnerSessionKey;
      ALTER TABLE identity_publication_markers DROP COLUMN denialDiagnostic;
      UPDATE schema_stamp SET shape='#{@predecessor}';
      """)

    assert stamp(db) == @predecessor
    assert terminal_objects(db) == []
    %{db: db}
  end

  test "exact settlement successor is additive, replay-safe, and infers no incident", %{db: db} do
    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO condition_facts(ts,kind,scope,origin) VALUES (1,'credential-present','racter:openai','process:tightbeam')"
             )

    preserved_sql =
      "SELECT type,name,sql FROM sqlite_master WHERE name IN ('assignment_cannot_proceed','turn_lifecycle_epoch','turn_lifecycle_events','wire_idempotency') ORDER BY type,name"

    assert {:ok, preserved_before} = DB.query(db, preserved_sql)
    assert length(preserved_before) == 4

    assert :ok = Schema.ensure_all(db)
    assert stamp(db) == @successor
    assert terminal_objects(db) == @terminal_objects
    assert {:ok, ^preserved_before} = DB.query(db, preserved_sql)
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM condition_facts")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM terminal_credential_incidents")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")

    assert :ok = Schema.ensure_all(db)
    assert stamp(db) == @successor
    assert terminal_objects(db) == @terminal_objects
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM terminal_credential_incidents")

    assert [
             @successor,
             "assignment-source-replacement-v1-019",
             "work-item-delivery-owner-v1-019",
             @identity_publication_denial_diagnostic_shape,
             @artifact_origin_shape,
             @agent_reparent_shape,
             @terminal_shape,
             @predecessor | _
           ] =
             Schema.guard_compatible_stamps()
  end

  test "stamp refusal rolls back every terminal object and preserves settlement", %{db: db} do
    :ok =
      DB.execute(db, """
      CREATE TRIGGER reject_terminal_credential_stamp BEFORE UPDATE ON schema_stamp
      WHEN NEW.shape='#{@terminal_shape}'
      BEGIN SELECT RAISE(ABORT,'forced terminal credential rollback'); END;
      """)

    assert_raise Tightbeam.DB.Error, fn -> Schema.ensure_all(db) end

    assert stamp(db) == @predecessor
    assert terminal_objects(db) == []

    assert {:ok, [["turn_lifecycle_events"], ["wire_idempotency"]]} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('turn_lifecycle_events','wire_idempotency') ORDER BY name"
             )

    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  defp stamp(db) do
    assert {:ok, [[shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    shape
  end

  defp terminal_objects(db) do
    assert {:ok, rows} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE name GLOB 'terminal_credential_*' ORDER BY name"
             )

    List.flatten(rows)
  end
end
