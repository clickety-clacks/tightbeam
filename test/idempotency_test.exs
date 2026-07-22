defmodule Tightbeam.IdempotencyTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{DB, Idempotency}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Idempotency.ensure_schema(name)
    %{db: name}
  end

  test "stores and resolves a result in owner-operation-key scope", %{db: db} do
    row = %{
      owner_user_id: "flynn",
      operation: "spawn",
      idempotency_key: "request-1",
      session_key: "session-1"
    }

    assert Idempotency.get(db, "flynn", "spawn", "request-1") == nil
    assert :ok = Idempotency.put(db, row)
    assert Idempotency.get(db, "flynn", "spawn", "request-1") == row
    assert Idempotency.get(db, "flynn", "retire", "request-1") == nil
    assert Idempotency.get(db, "other", "spawn", "request-1") == nil
  end

  test "duplicate scope is rejected and operation is constrained", %{db: db} do
    row = %{
      owner_user_id: "flynn",
      operation: "retire",
      idempotency_key: "request-1",
      session_key: "session-1"
    }

    assert :ok = Idempotency.put(db, row)

    assert_raise Tightbeam.DB.Error, ~r/UNIQUE constraint/, fn -> Idempotency.put(db, row) end

    assert_raise Tightbeam.DB.Error, ~r/CHECK constraint/, fn ->
      Idempotency.put(db, %{row | operation: "other", idempotency_key: "request-2"})
    end
  end

  test "fresh DDL accepts condition and a pre-condition database is rename-rebuilt", %{db: db} do
    assert :ok =
             Idempotency.put(db, %{
               owner_user_id: "user:flynn",
               operation: "condition",
               idempotency_key: "new",
               session_key: "1"
             })

    legacy = :"legacy_idempotency_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: legacy}, id: legacy)

    :ok =
      DB.execute(legacy, """
      CREATE TABLE wire_idempotency (
        ownerUserId TEXT NOT NULL,
        operation TEXT NOT NULL CHECK (operation IN ('spawn','retire','wake')),
        idempotencyKey TEXT NOT NULL,
        sessionKey TEXT NOT NULL,
        PRIMARY KEY (ownerUserId, operation, idempotencyKey)
      );
      INSERT INTO wire_idempotency VALUES ('flynn','spawn','old','session-old');
      """)

    assert :ok = Idempotency.ensure_schema(legacy)
    assert Idempotency.get(legacy, "flynn", "spawn", "old").session_key == "session-old"

    assert :ok =
             Idempotency.put(legacy, %{
               owner_user_id: "session:holder",
               operation: "condition",
               idempotency_key: "new",
               session_key: "1"
             })
  end
end
