defmodule Tightbeam.IdempotencyTest do
  use Tightbeam.TestCase, async: false

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

  test "fresh DDL accepts condition", %{db: db} do
    assert :ok =
             Idempotency.put(db, %{
               owner_user_id: "user:flynn",
               operation: "condition",
               idempotency_key: "new",
               session_key: "1"
             })
  end

  test "onboarding mutation identity is stable and structurally excludes response bytes" do
    identity =
      Idempotency.onboarding_identity(
        "user:mike",
        "oc_1",
        "respond",
        "code",
        "phone-response-1"
      )

    assert identity ==
             Idempotency.onboarding_identity(
               "user:mike",
               "oc_1",
               "respond",
               "code",
               "phone-response-1"
             )

    refute identity ==
             Idempotency.onboarding_identity(
               "user:mike",
               "oc_1",
               "respond",
               "approved",
               "phone-response-1"
             )

    refute inspect(identity) =~ "response-secret-sentinel"
    refute Map.has_key?(identity, :response)
    refute Map.has_key?(identity, :response_value)

    assert %{ceremony_id: nil, phase: "begin", response_kind: nil} =
             Idempotency.onboarding_identity("user:mike", nil, "begin", nil, "begin-1")
  end

  test "onboarding mutation identity rejects open or contradictory shapes" do
    invalid = [
      {"user:mike", nil, "respond", "code", "response-1"},
      {"user:mike", "oc_1", "respond", "apiKey", "response-1"},
      {"user:mike", "oc_1", "approved", nil, "response-1"},
      {"user:mike", "oc_1", "cancel", "code", "cancel-1"},
      {"", "oc_1", "cancel", nil, "cancel-1"},
      {"user:mike", "oc_1", "cancel", nil, ""}
    ]

    Enum.each(invalid, fn args ->
      assert_raise ArgumentError, ~r/invalid onboarding idempotency identity/, fn ->
        apply(Idempotency, :onboarding_identity, Tuple.to_list(args))
      end
    end)
  end
end
