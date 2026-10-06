defmodule Tightbeam.OperatorRulingLegacyFixtureTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, DB, Escalation, Model, Org, Wakes}

  @fixture_path "test/fixtures/operator_ruling_legacy_f4e5e6a1.json"
  @settlement_fixture_path "test/fixtures/operator_ruling_settlement_8dcb742c.json"
  @source_commit "f4e5e6a197abd0e75da70d2b7a0a2e316cbc3252"
  @source_tree "9efdfea554bbd8010f76d4d261a0fcaf2c48d4b2"
  @source_lock "38984dd5bf62caf36299f920a7347ba2bcb3f11de8f574ebf35d25967abf0e13"
  @tables ~w(decision_requests condition_facts lifecycle_events wakes turns)

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, session_key}, _from, parent) do
      send(parent, {:lane_nudged, session_key})
      {:reply, :ok, parent}
    end
  end

  setup do
    db = :"operator_ruling_legacy_fixture_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)

    Org.create(db, %{
      session_key: "agent:raiser:app",
      display_name: "raiser",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    fixture = @fixture_path |> File.read!() |> JSON.decode!()
    import_fixture!(db, fixture)
    %{db: db, fixture: fixture}
  end

  test "0.1.8 deadline-relative pending and fired rulings remain readable and replayable", ctx do
    assert ctx.fixture["sourceCommit"] == @source_commit
    assert ctx.fixture["sourceTree"] == @source_tree
    assert ctx.fixture["mixLockSha256"] == @source_lock

    pending = ctx.fixture["pending"]
    fired = ctx.fixture["fired"]

    assert pending["dueAt"] == pending["ruledAt"] + pending["duration"]
    assert fired["dueAt"] == fired["ruledAt"] + fired["duration"]

    call = owner_operator_rule(pending["requestId"], %{decision: "accept"})

    assert MapSet.new(
             Enum.map(Escalation.list(ctx.db, call, "ruled", owner_user_id: "flynn"), & &1.id)
           ) ==
             MapSet.new([pending["requestId"], fired["requestId"]])

    for legacy <- [pending, fired] do
      replay_call = owner_operator_rule(legacy["requestId"], %{decision: "accept"})

      assert %{id: request_id, status: "ruled", decision: "accept"} =
               Escalation.get(ctx.db, replay_call, legacy["requestId"], owner_user_id: "flynn")

      assert request_id == legacy["requestId"]

      assert Escalation.operator_rule(ctx.db, replay_call).ruling_fact_id ==
               legacy["rulingFactId"]
    end

    assert {:ok, [["pending"], ["fired"]]} =
             DB.query(
               ctx.db,
               "SELECT state FROM wakes WHERE wakeId IN (?1,?2) ORDER BY state DESC",
               [pending["wakeId"], fired["wakeId"]]
             )

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM decision_request_integrity_evidence")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1", [
               pending["wakeId"],
               pending["dueAt"] + 1
             ])

    assert %{code: "decision_request_integrity_invalid", request_id: request_id} =
             Escalation.get(ctx.db, call, pending["requestId"], owner_user_id: "flynn")

    assert request_id == pending["requestId"]

    assert {:ok, [[~s(["raiserNotificationWake"])]]} =
             DB.query(
               ctx.db,
               "SELECT failingFields FROM decision_request_integrity_evidence WHERE requestId=?1",
               [pending["requestId"]]
             )
  end

  test "an immediately-due committed wake recovers a lost nudge exactly once" do
    suffix = System.unique_integer([:positive])
    db = :"operator_ruling_settlement_fixture_db_#{suffix}"
    scheduler = :"operator_ruling_settlement_fixture_scheduler_#{suffix}"

    start_supervised!(
      Supervisor.child_spec({DB, path: ":memory:", name: db},
        id: {:settlement_fixture_db, suffix}
      )
    )

    :ok = ensure_all_schemas(db)

    Org.create(db, %{
      session_key: "agent:raiser:app",
      display_name: "raiser",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    start_supervised!(
      {Wakes, db: db, name: scheduler, tick_ms: 60_000, deliver: fn _wake -> :ok end}
    )

    fixture = @settlement_fixture_path |> File.read!() |> JSON.decode!()
    import_fixture!(db, fixture)
    pending = fixture["pending"]

    assert fixture["sourceCommit"] == "8dcb742ca00a1d70ad28ca6e4a734ae552ff184a"
    assert fixture["sourceTree"] == "740a2034082e75deb24c6c44f482ebef38d6dc71"

    assert fixture["mixLockSha256"] ==
             "d9b2daa3d7e0f24ca795323887f02b370a252fd0f7d0e19205a42ec555e49eb8"

    assert pending["dueAt"] == pending["ruledAt"]
    assert {:ok, [["pending", 0]]} = wake_state_and_turn_count(db, pending["wakeId"])

    assert :ok = Wakes.fire_due(scheduler)
    assert {:ok, [["fired", 1]]} = wake_state_and_turn_count(db, pending["wakeId"])

    assert :ok = Wakes.fire_due(scheduler)
    assert {:ok, [["fired", 1]]} = wake_state_and_turn_count(db, pending["wakeId"])
  end

  defp import_fixture!(db, %{"tables" => tables}) do
    Enum.each(@tables, fn table ->
      %{"columns" => columns, "rows" => rows} = Map.fetch!(tables, table)
      assert Enum.all?(columns, &Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, &1))

      placeholders =
        columns
        |> Enum.with_index(1)
        |> Enum.map_join(",", fn {_column, index} -> "?#{index}" end)

      sql = "INSERT INTO #{table} (#{Enum.join(columns, ",")}) VALUES (#{placeholders})"

      Enum.each(rows, fn row ->
        assert {:ok, _} = DB.query(db, sql, row)
      end)
    end)
  end

  defp owner_operator_rule(id, params) do
    %{
      verb: "operator-rule",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      transport_session_key: nil,
      params: Map.put(params, :request, id)
    }
  end

  defp wake_state_and_turn_count(db, wake_id) do
    DB.query(
      db,
      "SELECT state,(SELECT COUNT(*) FROM turns WHERE wakeId=?1) FROM wakes WHERE wakeId=?1",
      [wake_id]
    )
  end
end
