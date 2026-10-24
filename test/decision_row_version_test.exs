defmodule Tightbeam.DecisionRowVersionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Escalation, Schema, StateResources}

  @v21 "coordination-fabric-v1-phase1-v21"
  @v22 "coordination-fabric-v1-phase1-v22"

  @canonical_changes [
    {"id", "row-version-canonical-fields-next"},
    {"kind", "agent"},
    {"raiserId", "session:other-raiser"},
    {"raiserSessionKey", "other-raiser"},
    {"ownerUserId", "other-owner"},
    {"assignmentId", "asg-next"},
    {"expecterSessionKey", "asked-next"},
    {"expecterUserId", "asked-owner-next"},
    {"lineageRung", 2},
    {"effortGeneration", 3},
    {"deadlineWakeId", "wake-next"},
    {"raisedAt", 11},
    {"deadlineAt", 21},
    {"statuteName", "statute-next"},
    {"question", "question next"},
    {"options", "[{\"label\":\"next\"}]"},
    {"context", "{\"scope\":\"next\"}"},
    {"status", "withdrawn"},
    {"decision", "allow"},
    {"rationale", "rationale next"},
    {"ruledBy", "ruler-next"},
    {"ruledAt", 31},
    {"consumedAt", 32},
    {"withdrawnBy", "withdrawer-next"},
    {"withdrawnReason", "reason next"},
    {"withdrawnAt", 33},
    {"askedOfRole", "role-next"},
    {"answer", "answer next"},
    {"answeredBy", "answerer-next"},
    {"answeredAt", 34},
    {"returnedBy", "returner-next"},
    {"returnReason", "return reason next"},
    {"returnedAt", 35}
  ]

  setup do
    db = :"decision_row_version_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    %{db: db}
  end

  test "fresh and upgraded rows have the same stored positive version shape", %{db: fresh} do
    insert_operator(fresh, "fresh-decision")
    assert row_version(fresh, "fresh-decision") == 1

    upgraded = :"decision_row_version_upgraded_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: upgraded}, id: upgraded)
    :ok = Schema.ensure_all(upgraded)
    insert_operator(upgraded, "existing-decision")
    downgrade_to_v21(upgraded)

    assert {:ok, []} = DB.query(upgraded, "UPDATE schema_stamp SET shape=?1", [@v21])
    :ok = Schema.ensure_all(upgraded)

    assert {:ok, [[@v22]]} = DB.query(upgraded, "SELECT shape FROM schema_stamp")
    assert row_version(upgraded, "existing-decision") == 1

    insert_operator(upgraded, "new-decision")
    assert row_version(upgraded, "new-decision") == 1

    assert version_column(fresh) == version_column(upgraded)

    for {db, id} <- [{fresh, "fresh-decision"}, {upgraded, "existing-decision"}] do
      assert StateResources.decision_request(Escalation.raw_by_id(db, id))["rowVersion"] == 1

      assert {:ok, []} =
               DB.query(db, "UPDATE decision_requests SET question='changed' WHERE id=?1", [id])

      assert row_version(db, id) == 2
      assert StateResources.decision_request(Escalation.raw_by_id(db, id))["rowVersion"] == 2
    end
  end

  test "each canonical decision field increments the stored version once", %{db: db} do
    id = insert_operator(db, "row-version-canonical-fields")
    assert row_version(db, id) == 1
    assert :ok = DB.execute(db, "PRAGMA ignore_check_constraints = ON")

    {_id, final_version} =
      Enum.reduce(@canonical_changes, {id, 1}, fn {column, value}, {current_id, version} ->
        assert {:ok, []} =
                 DB.query(
                   db,
                   "UPDATE decision_requests SET #{column}=?1 WHERE id=?2",
                   [value, current_id]
                 )

        next_id = if column == "id", do: value, else: current_id
        assert row_version(db, next_id) == version + 1
        {next_id, version + 1}
      end)

    assert final_version == length(@canonical_changes) + 1
  end

  test "status and the return triplet increment once, while no-op retries stay unchanged", %{
    db: db
  } do
    id = insert_agent(db, "row-version-return-triplet")
    assert row_version(db, id) == 1

    update_return_triplet(db, id)
    assert row_version(db, id) == 2

    update_return_triplet(db, id)
    assert row_version(db, id) == 2

    assert {:ok, []} =
             DB.query(db, "UPDATE decision_requests SET question=question WHERE id=?1", [id])

    assert row_version(db, id) == 2
  end

  test "multiple changes with fixed timestamps each advance the version", %{db: db} do
    id = insert_operator(db, "row-version-fixed-timestamps")

    assert {:ok, [[10, 20]]} =
             DB.query(db, "SELECT raisedAt, deadlineAt FROM decision_requests WHERE id=?1", [id])

    assert {:ok, []} =
             DB.query(db, "UPDATE decision_requests SET question='second' WHERE id=?1", [id])

    assert row_version(db, id) == 2

    assert {:ok, []} =
             DB.query(db, "UPDATE decision_requests SET question='third' WHERE id=?1", [id])

    assert row_version(db, id) == 3

    assert {:ok, [[10, 20]]} =
             DB.query(db, "SELECT raisedAt, deadlineAt FROM decision_requests WHERE id=?1", [id])
  end

  test "projection rejects missing and invalid stored versions", %{db: db} do
    id = insert_operator(db, "row-version-invalid-projection")
    assert :ok = DB.execute(db, "DROP TRIGGER decision_request_operator_terminal_update")

    for value <- [0, -1, 1.5, "invalid"] do
      assert {:ok, []} =
               DB.query(db, "UPDATE decision_requests SET rowVersion=?1 WHERE id=?2", [value, id])

      row = Escalation.raw_by_id(db, id)
      assert row.row_version === value

      error =
        assert_raise ArgumentError, fn ->
          StateResources.decision_request(row)
        end

      assert error.message =~ "rowVersion is projection_invalid"
    end

    row = Escalation.raw_by_id(db, id) |> Map.delete(:row_version)

    error =
      assert_raise ArgumentError, fn ->
        StateResources.decision_request(row)
      end

    assert error.message =~ "rowVersion is projection_invalid"
  end

  test "v20 artifact migration still stops at v21 before the decision version step", %{db: db} do
    insert_operator(db, "row-version-v20-upgrade")
    downgrade_to_v21(db)
    assert :ok = DB.execute(db, "ALTER TABLE artifacts DROP COLUMN contentSha256Verified")

    assert {:ok, []} =
             DB.query(db, "UPDATE schema_stamp SET shape=?1", [
               "coordination-fabric-v1-phase1-v20"
             ])

    assert :ok = Schema.upgrade_artifact_digest_integrity_v1(db)
    assert {:ok, [[@v21]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    refute "rowVersion" in column_names(db, "decision_requests")

    :ok = Schema.ensure_all(db)
    assert {:ok, [[@v22]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    assert row_version(db, "row-version-v20-upgrade") == 1
  end

  defp insert_operator(db, id) do
    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO decision_requests
                 (id, kind, raiserId, raiserSessionKey, ownerUserId, actionKey,
                  raisedAt, deadlineAt, question, options, context, status)
               VALUES (?1, 'operator', 'session:raiser', 'raiser', 'owner', 'action',
                       10, 20, 'question', '[]', '{}', 'open')
               """,
               [id]
             )

    id
  end

  defp insert_agent(db, id) do
    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO decision_requests
                 (id, kind, raiserId, raiserSessionKey, ownerUserId, expecterSessionKey,
                  expecterUserId, raisedAt, question, context, status)
               VALUES (?1, 'agent', 'session:raiser', 'raiser', 'owner', 'asked',
                       'asked-owner', 10, 'question', '{}', 'open')
               """,
               [id]
             )

    id
  end

  defp update_return_triplet(db, id) do
    assert {:ok, []} =
             DB.query(
               db,
               """
               UPDATE decision_requests
                  SET status='returned', returnedBy='asked', returnReason='needs detail', returnedAt=30
                WHERE id=?1
               """,
               [id]
             )
  end

  defp row_version(db, id) do
    assert {:ok, [[version]]} =
             DB.query(db, "SELECT rowVersion FROM decision_requests WHERE id=?1", [id])

    version
  end

  defp version_column(db) do
    table_info(db, "decision_requests")
    |> Enum.find_value(fn
      [_cid, "rowVersion", type, not_null, default, _primary_key] ->
        {type, not_null, default}

      _other ->
        nil
    end)
  end

  defp column_names(db, table) do
    table_info(db, table) |> Enum.map(fn [_cid, name | _rest] -> name end)
  end

  defp table_info(db, table) do
    assert {:ok, columns} = DB.query(db, "PRAGMA table_info(#{table})")
    columns
  end

  defp downgrade_to_v21(db) do
    assert :ok = DB.execute(db, "DROP TRIGGER decision_requests_row_version")
    assert :ok = DB.execute(db, "DROP TRIGGER decision_request_operator_terminal_insert")
    assert :ok = DB.execute(db, "DROP TRIGGER decision_request_operator_terminal_update")
    assert :ok = DB.execute(db, "ALTER TABLE decision_requests DROP COLUMN rowVersion")

    assert :ok =
             DB.execute(db, """
             CREATE TRIGGER decision_request_operator_terminal_insert
             BEFORE INSERT ON decision_requests
             WHEN NEW.kind = 'operator' AND NEW.status = 'ruled' AND
                  (NEW.ruledViaPrincipal IS NULL OR
                   NEW.ruledViaSessionState IS NULL OR
                   NEW.ruledViaSessionState NOT IN ('known','none') OR
                   (NEW.ruledViaSessionState = 'known' AND NEW.ruledViaSessionKey IS NULL) OR
                   (NEW.ruledViaSessionState = 'none' AND NEW.ruledViaSessionKey IS NOT NULL))
             BEGIN
               SELECT RAISE(ABORT, 'decision_request_integrity_invalid');
             END;

             CREATE TRIGGER decision_request_operator_terminal_update
             BEFORE UPDATE OF status ON decision_requests
             WHEN NEW.kind = 'operator' AND NEW.status = 'ruled' AND OLD.status <> 'ruled' AND
                  (NEW.ruledViaPrincipal IS NULL OR
                   NEW.ruledViaSessionState IS NULL OR
                   NEW.ruledViaSessionState NOT IN ('known','none') OR
                   (NEW.ruledViaSessionState = 'known' AND NEW.ruledViaSessionKey IS NULL) OR
                   (NEW.ruledViaSessionState = 'none' AND NEW.ruledViaSessionKey IS NOT NULL))
             BEGIN
               SELECT RAISE(ABORT, 'decision_request_integrity_invalid');
             END;
             """)
  end
end
