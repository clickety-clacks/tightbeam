defmodule Tightbeam.EphemeralTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    DB,
    Dispatch,
    Ephemeral,
    Ledger,
    Model,
    Org,
    Placement,
    Schema,
    Supervision,
    Wakes
  }

  @tag tmp_dir: true, timeout: 180_000
  test "R2.2-R2.5 real gateway completion retires without a workdir and returns the final message",
       %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(tmp, "live_base_ephemeral.exs", "ephemeral-runtime: ok")
  end

  setup do
    db =
      start_supervised!(
        {DB, path: ":memory:", name: :"ephemeral_#{System.unique_integer([:positive])}"}
      )

    :ok = ensure_all_schemas(db)
    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',1,1)")

    for key <- ["caller", "helper", "ordinary"] do
      Org.create(db, %{
        session_key: key,
        display_name: key,
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })
    end

    assert {:ok, _} = DB.transaction(db, &Ephemeral.stamp_in_txn(&1, "helper", "caller"))
    %{db: db}
  end

  test "R2.2 accepts one turn and retires at every terminal outcome", %{db: db} do
    for terminal <- ~w(delivered failed canceled failed_unknown) do
      key = "helper-#{terminal}"

      :ok =
        DB.execute(db, """
        INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,createdAt,updatedAt)
        VALUES('#{key}','helper','owner','user:owner','default','claude','anthropic',1,1)
        """)

      assert {:ok, _} = DB.transaction(db, &Ephemeral.stamp_in_txn(&1, key, "caller"))
      assert {:ok, seq} = enqueue(db, key)
      assert {:error, :ephemeral_turn_used} = enqueue(db, key)
      assert {:ok, _} = Ledger.claim_next(db, key, "test")
      assert :ok = Ledger.finish(db, seq, terminal)
      assert Org.get(db, key).state == "retired"
      assert :already_terminal = Ledger.finish(db, seq, terminal)
      assert {:error, :ephemeral_turn_used} = enqueue(db, key)
    end

    assert {:ok, _} = enqueue(db, "ordinary")
    assert {:ok, _} = enqueue(db, "ordinary")
  end

  test "R2.3 rejects assignment and card ownership through insert and update", %{db: db} do
    assignment = """
    INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
    VALUES('assignment','inspect',?1,'caller',1,'open','claude','anthropic')
    """

    assert {:error, error} = DB.query(db, assignment, ["helper"])
    assert error.message =~ "ephemeral sessions cannot hold assignments"
    assert {:ok, []} = DB.query(db, assignment, ["ordinary"])
    assert {:error, error} = DB.query(db, "UPDATE assignments SET holderKey='helper'")
    assert error.message =~ "ephemeral sessions cannot hold assignments"

    card = """
    INSERT INTO work_items(id,title,ownerUserId,deliveryOwnerSessionKey,state,createdByUser,createdAt)
    VALUES('card','inspect','owner',?1,'open','owner',1)
    """

    assert {:error, error} = DB.query(db, card, ["helper"])
    assert error.message =~ "ephemeral sessions cannot own work items"
    assert {:ok, []} = DB.query(db, card, ["ordinary"])

    assert {:error, error} =
             DB.query(db, "UPDATE work_items SET deliveryOwnerSessionKey='helper'")

    assert error.message =~ "ephemeral sessions cannot own work items"
  end

  test "R2.3 never runs supervision for an ephemeral helper", %{db: db} do
    assert Supervision.evaluate(db, %{}, 1, "helper", nil) == :idle
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM decision_requests")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
  end

  test "R2.3 inspection-only helpers cannot write records or spawn helpers", %{db: db} do
    parent = self()

    handler = fn _ ->
      send(parent, :handler_ran)
      %{ok: true}
    end

    for verb <- ~w(spawn assign dispatch work-item-create artifact-record wake post attest ask) do
      call = %{
        verb: verb,
        origin: "session:helper",
        principal: {:session, "helper"},
        session_key: nil,
        params: %{}
      }

      assert {:error, %{code: "ephemeral_read_only"}} =
               Dispatch.dispatch(db, %{verb => handler}, call)
    end

    refute_received :handler_ran

    call = %{
      verb: "inspect",
      origin: "session:helper",
      principal: {:session, "helper"},
      session_key: nil,
      params: %{}
    }

    assert {:ok, %{ok: true}} = Dispatch.dispatch(db, %{"inspect" => handler}, call)
    assert_received :handler_ran
  end

  test "R2.4 no owned workdir is created", %{db: db} do
    helper = Org.get(db, "helper") |> Map.put(:ephemeral, true)
    assert Placement.holder_workdir(%{}, helper) == "/"
  end

  test "R2.5 final result targets the exact spawning agent", %{db: db} do
    assert {:ok, :ok} = DB.transaction(db, &Ephemeral.return_in_txn(&1, "helper", "No blockers."))
    wake = Wakes.get(db, "ephemeral-result:helper")
    assert wake.session_key == "caller"
    assert wake.prompt == "Ephemeral spawn result from helper:\n\nNo blockers."
    assert wake.state == "pending"
    assert wake.assignment_id == nil

    assert {:ok, :ok} =
             DB.transaction(db, &Ephemeral.return_in_txn(&1, "ordinary", "ordinary reply"))

    assert Wakes.get(db, "ephemeral-result:ordinary") == nil
  end

  test "R2.1-R2.5 migration and stamped elections survive restart", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    assert :ok = Schema.ensure_all(db)
    assert Ephemeral.session?(db, "helper")
    refute Ephemeral.session?(db, "ordinary")
    assert Ephemeral.caller(db, "helper") == "caller"
    assert {:ok, [[0]]} = DB.query(db, "SELECT id FROM ephemeral_migration")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  @tag :tmp_dir
  test "R2.1-R2.5 additive migration follows the 0.1.8 predecessor upgrade", %{tmp_dir: tmp} do
    path = Path.join(tmp, "predecessor/state.db")
    Tightbeam.SchemaShapeRuntimeFixture.seed_operator_predecessor!(path)

    db =
      start_supervised!(
        {DB, path: path, name: :"ephemeral_upgrade_#{System.unique_integer([:positive])}"}
      )

    assert {:ok, [["operator-decision-requests-v1"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert :ok = Schema.ensure_all(db)
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[0]]} = DB.query(db, "SELECT id FROM ephemeral_migration")
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  defp enqueue(db, key) do
    Ledger.enqueue(db, %{
      session_key: key,
      message_id: "message-#{System.unique_integer([:positive])}",
      origin: "user:owner",
      prompt: "Inspect and report"
    })
  end
end
