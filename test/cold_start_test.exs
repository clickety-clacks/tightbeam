defmodule Tightbeam.ColdStartTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{Boot, ColdStart, DB, Devices, Model, Org, Schema}

  @defaults %{
    host: "testhost",
    harness: :claude,
    provider: :anthropic,
    model: Model.new("fable")
  }

  setup do
    db = :"cold_start_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    %{db: db}
  end

  test "pair-first commits the whole identity graph and one secret-free event", %{db: db} do
    assert {:paired, device} = ColdStart.pair(db, pair_input("d1", "Alice"), @defaults)
    assert device.status == "allowlisted"
    assert device.user_id == "alice"
    assert device.is_admin
    assert is_binary(device.token)

    root = Org.get(db, Org.personal_session_key("alice"))
    assert root.kind == "main"
    assert root.is_built_in
    assert root.operational_parent == root.session_key
    assert root.origin == "process:tightbeam"

    assert %{
             "state" => "claimed",
             "userId" => "alice",
             "deviceId" => "d1",
             "activated" => false
           } = ColdStart.state(db)

    assert {:ok, [[payload]]} =
             DB.query(db, "SELECT payload FROM events WHERE verb='cold-start'")

    refute payload =~ "tbt_"
    refute payload =~ "claimedName"
    refute payload =~ "replaySecret"

    assert payload =~ ~s("operationalParent" => "#{root.session_key}")
  end

  test "each pair-first write fence rolls the transaction back", %{db: db} do
    for step <- 1..5 do
      input = pair_input("d#{step}", "Alice") |> Map.put(:fail_after, step)
      assert {:error, "bootstrap_failed"} = ColdStart.pair(db, input, @defaults)
      assert identity_census(db) == [0, 0, 0, 0, 0]
    end

    assert {:paired, _device} = ColdStart.pair(db, pair_input("winner", "Alice"), @defaults)
  end

  test "concurrent different-device claims serialize to one claim and one pending device", %{
    db: db
  } do
    results =
      concurrent([
        fn -> ColdStart.pair(db, pair_input("d1", "Alice"), @defaults) end,
        fn -> ColdStart.pair(db, pair_input("d2", "Bob"), @defaults) end
      ])

    assert Enum.count(results, &match?({:paired, _}, &1)) == 1
    assert Enum.count(results, &match?({:pending, _}, &1)) == 1
    assert identity_census(db) == [2, 2, 1, 1, 1]

    assert {:ok, [[1, 1]]} =
             DB.query(db, """
             SELECT
               SUM(CASE WHEN status='allowlisted' AND token IS NOT NULL THEN 1 ELSE 0 END),
               SUM(CASE WHEN status='pending' AND token IS NULL THEN 1 ELSE 0 END)
             FROM devices
             """)
  end

  test "concurrent identical replay-safe claims return the same committed token", %{db: db} do
    secret = :crypto.strong_rand_bytes(32)
    input = pair_input("d1", "Alice") |> Map.put(:replay_secret, secret)

    results =
      concurrent([
        fn -> ColdStart.pair(db, input, @defaults) end,
        fn -> ColdStart.pair(db, input, @defaults) end
      ])

    assert [{:paired, first}, {:paired, second}] = results
    assert first.token == second.token
    assert identity_census(db) == [1, 1, 1, 1, 1]
  end

  test "host-local bootstrap and pair-first race converges through transaction order", %{db: db} do
    results =
      concurrent([
        fn -> ColdStart.bootstrap_user(db, "alice", @defaults) end,
        fn -> ColdStart.pair(db, pair_input("d1", "Alice"), @defaults) end
      ])

    assert Enum.any?(results, &match?({:paired, _}, &1))

    assert Enum.any?(results, fn
             {:ok, %{phase: "reserved"}} -> true
             {:error, "bootstrap_closed"} -> true
             _ -> false
           end)

    assert identity_census(db) in [[1, 1, 1, 1, 1], [1, 1, 1, 1, 2]]
    assert ColdStart.state(db)["state"] == "claimed"
  end

  test "dynamic Main defaults resolve before the database transaction", %{db: db} do
    defaults =
      Map.put(@defaults, :provider, fn ->
        assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM users")
        :anthropic
      end)

    assert {:paired, _device} = ColdStart.pair(db, pair_input("d1", "Alice"), defaults)
  end

  test "a replay secret returns the committed token only before activation", %{db: db} do
    secret = :crypto.strong_rand_bytes(32)
    input = pair_input("d1", "Alice") |> Map.put(:replay_secret, secret)

    assert {:paired, first} = ColdStart.pair(db, input, @defaults)
    assert {:paired, replay} = ColdStart.pair(db, input, @defaults)
    assert replay.token == first.token

    assert {:error, "bootstrap_closed"} =
             ColdStart.pair(
               db,
               %{input | replay_secret: :crypto.strong_rand_bytes(32)},
               @defaults
             )

    assert ColdStart.activate(db, first.token).device_id == "d1"
    assert {:paired, rotated} = ColdStart.pair(db, input, @defaults)
    refute rotated.token == first.token
  end

  test "an unactivated claim refuses a changed fingerprint without mutation", %{db: db} do
    secret = :crypto.strong_rand_bytes(32)
    input = pair_input("d1", "Alice") |> Map.put(:replay_secret, secret)

    assert {:paired, first} = ColdStart.pair(db, input, @defaults)

    assert {:ok, [before]} =
             DB.query(
               db,
               "SELECT userId,status,token FROM devices WHERE deviceId='d1'"
             )

    assert {:error, "bootstrap_closed"} =
             ColdStart.pair(db, %{input | claimed_name: "Bob"}, @defaults)

    assert {:ok, [^before]} =
             DB.query(
               db,
               "SELECT userId,status,token FROM devices WHERE deviceId='d1'"
             )

    assert Devices.by_id(db, "d1").token == first.token
    assert Devices.user(db, "bob") == nil
    assert identity_census(db) == [1, 1, 1, 1, 1]
  end

  test "a denied receipt device takes precedence over a changed fingerprint", %{db: db} do
    secret = :crypto.strong_rand_bytes(32)
    input = pair_input("d1", "Alice") |> Map.put(:replay_secret, secret)

    assert {:paired, _device} = ColdStart.pair(db, input, @defaults)
    :ok = DB.execute(db, "UPDATE devices SET status='denied',token=NULL WHERE deviceId='d1'")

    assert {:ok, [before]} =
             DB.query(db, "SELECT userId,status,token FROM devices WHERE deviceId='d1'")

    assert :denied = ColdStart.pair(db, %{input | claimed_name: "Bob"}, @defaults)

    assert {:ok, [^before]} =
             DB.query(db, "SELECT userId,status,token FROM devices WHERE deviceId='d1'")

    assert Devices.user(db, "bob") == nil
    assert identity_census(db) == [1, 1, 1, 1, 1]
  end

  test "host-local reservation is idempotent and only the same normalized user completes it", %{
    db: db
  } do
    assert {:ok, first} = ColdStart.bootstrap_user(db, "alice", @defaults)
    assert first.phase == "reserved"
    assert first.isAdmin
    assert {:ok, ^first} = ColdStart.bootstrap_user(db, "alice", @defaults)
    assert {:error, "bootstrap_closed"} = ColdStart.bootstrap_user(db, "bob", @defaults)

    assert {:error, "bootstrap_closed"} =
             ColdStart.pair(db, pair_input("wrong", "Bob"), @defaults)

    assert Devices.by_id(db, "wrong") == nil
    assert {:paired, device} = ColdStart.pair(db, pair_input("d1", "Alice"), @defaults)
    assert device.user_id == "alice"
    assert ColdStart.state(db)["state"] == "claimed"
    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM events")
  end

  test "host-local reservation rolls back when its Main referent is malformed", %{db: db} do
    :ok =
      DB.execute(db, """
      CREATE TRIGGER corrupt_reserved_main
      AFTER INSERT ON sessions
      WHEN NEW.kind = 'main'
      BEGIN
        UPDATE sessions SET isBuiltIn = 0 WHERE sessionKey = NEW.sessionKey;
      END;
      """)

    assert {:error, "bootstrap_failed"} = ColdStart.bootstrap_user(db, "alice", @defaults)
    assert identity_census(db) == [0, 0, 0, 0, 0]
  end

  test "host-local reservation rolls back when its Main origin is corrupted after reservation", %{
    db: db
  } do
    :ok =
      DB.execute(db, """
      CREATE TRIGGER corrupt_reserved_main_origin
      AFTER INSERT ON events
      WHEN NEW.verb = 'cold-start'
      BEGIN
        UPDATE sessions SET origin = 'agent:corrupt' WHERE kind = 'main';
      END;
      """)

    assert {:error, "bootstrap_failed"} = ColdStart.bootstrap_user(db, "alice", @defaults)
    assert identity_census(db) == [0, 0, 0, 0, 0]
  end

  test "host-local reservation rolls back when its Main spawnedBy is corrupted after reservation",
       %{
         db: db
       } do
    :ok =
      DB.execute(db, """
      CREATE TRIGGER corrupt_reserved_main_spawner
      AFTER INSERT ON events
      WHEN NEW.verb = 'cold-start'
      BEGIN
        UPDATE sessions SET spawnedBy = sessionKey WHERE kind = 'main';
      END;
      """)

    assert {:error, "bootstrap_failed"} = ColdStart.bootstrap_user(db, "alice", @defaults)
    assert identity_census(db) == [0, 0, 0, 0, 0]
  end

  test "boot logs reset guidance only for the closed cold-start shape family", %{db: db} do
    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('alice',1,'cold_start',1)"
             )

    log =
      capture_log([metadata: [:code, :invariant, :recoverySection]], fn ->
        error = assert_raise Schema.ShapeError, fn -> Boot.ensure_schema!(db) end

        assert error.message ==
                 "incompatible_cold_start_v1: receiptless_nonempty_users; recovery: Recover an unusable fresh database"
      end)

    assert log =~ "cold-start schema is incompatible"
    assert log =~ "code=incompatible_cold_start_v1"
    assert log =~ "invariant=receiptless_nonempty_users"
    assert log =~ "recoverySection=Recover an unusable fresh database"
  end

  test "boot does not label an unrelated shape error as a cold-start reset", %{db: db} do
    :ok = DB.execute(db, "UPDATE schema_stamp SET shape='coordination-fabric-v1-phase1-v3'")

    log =
      capture_log(fn ->
        error = assert_raise Schema.ShapeError, fn -> Boot.ensure_schema!(db) end
        assert error.message =~ "written by a different build"
      end)

    refute log =~ "cold-start schema is incompatible"
    refute log =~ "incompatible_cold_start_v1"
    refute log =~ "Recover an unusable fresh database"
  end

  test "a different device after claim remains an ordinary pending pair", %{db: db} do
    assert {:paired, _} = ColdStart.pair(db, pair_input("d1", "Alice"), @defaults)
    assert {:pending, pending} = ColdStart.pair(db, pair_input("d2", "Bob"), @defaults)
    assert pending.token == nil
    assert pending.status == "pending"
    assert Devices.user(db, "bob").creation_kind == "device_pair"
  end

  test "the schema guard names an omitted creation kind and leaves users unchanged", %{db: db} do
    assert {:error, error} =
             DB.query(db, "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('old-cli',1,1)")

    assert Exception.message(error) =~ "bootstrap_owned_by_gateway"
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM users")
  end

  test "captured empty v5 migrates to open v6", _ctx do
    db = captured_db!("v5-empty")
    assert :ok = Schema.ensure_all(db)

    assert ColdStart.state(db) == %{
             "state" => "open",
             "action" => "choose pair-first or host-local bootstrap"
           }

    assert {:ok, [["coordination-fabric-v1-phase1-v6"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")
  end

  test "captured healthy v5 migrates to one activated legacy receipt", _ctx do
    db = captured_db!("v5-healthy")
    assert {:ok, [[token]]} = DB.query(db, "SELECT token FROM devices")
    assert :ok = Schema.ensure_all(db)

    assert %{"state" => "claimed", "cause" => "v5_observed", "activated" => true} =
             ColdStart.state(db)

    assert {:ok, [["legacy"]]} = DB.query(db, "SELECT creationKind FROM users")
    assert Devices.by_token(db, token).device_id == "captured-device"
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM events")
  end

  test "ordinary lifecycle changes do not erase a historical claim", %{db: db} do
    assert {:paired, device} = ColdStart.pair(db, pair_input("d1", "Alice"), @defaults)
    root = Org.personal_session_key("alice")

    :ok = DB.execute(db, "UPDATE users SET isAdmin=0 WHERE userId='alice'")
    :ok = DB.execute(db, "UPDATE devices SET status='denied',token=NULL WHERE deviceId='d1'")
    :ok = DB.execute(db, "UPDATE sessions SET state='retired' WHERE sessionKey='#{root}'")
    device_id = device.device_id

    assert %{
             "state" => "claimed",
             "userId" => "alice",
             "deviceId" => ^device_id
           } = ColdStart.state(db)
  end

  test "boot rejects corrupted accepted-event referents", %{db: db} do
    assert {:paired, _device} = ColdStart.pair(db, pair_input("d1", "Alice"), @defaults)

    assert {:ok, [[claim_event_id]]} =
             DB.query(db, "SELECT claimEventId FROM cold_start_receipts")

    assert_event_corruptions_refuse(db, claim_event_id)

    other = :"cold_start_event_db_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: other,
      start: {DB, :start_link, [[path: ":memory:", name: other]]}
    })

    :ok = Schema.ensure_all(other)
    assert {:ok, %{phase: "reserved"}} = ColdStart.bootstrap_user(other, "alice", @defaults)
    assert {:paired, _device} = ColdStart.pair(other, pair_input("d1", "Alice"), @defaults)

    assert {:ok, [[reserved_event_id, device_event_id]]} =
             DB.query(other, "SELECT claimEventId,deviceEventId FROM cold_start_receipts")

    assert_event_corruptions_refuse(other, reserved_event_id)
    assert_event_corruptions_refuse(other, device_event_id)
  end

  test "each interrupted healthy-v5 migration rolls back and a retry converges", _ctx do
    for point <- [:after_copy, :after_drop, :after_schema, :after_receipt, :after_stamp] do
      db = captured_db!("v5-healthy")
      before = migration_snapshot(db)

      assert_raise Schema.ShapeError, fn -> Schema.upgrade_cold_start_v1(db, fail_at: point) end
      assert migration_snapshot(db) == before

      assert :ok = Schema.upgrade_cold_start_v1(db)
      assert %{"state" => "claimed", "cause" => "v5_observed"} = ColdStart.state(db)
    end
  end

  test "captured incomplete v5 stopping points refuse and roll back byte-logical shape", _ctx do
    for fixture <- [
          "v5-user-only",
          "v5-admin-pending",
          "v5-allowlisted-no-main",
          "v5-missing-main-parent"
        ] do
      db = captured_db!(fixture)

      error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end

      assert error.message ==
               "incompatible_cold_start_v1: legacy_witness_missing; recovery: Recover an unusable fresh database"

      assert {:ok, [["coordination-fabric-v1-phase1-v5"]]} =
               DB.query(db, "SELECT shape FROM schema_stamp")

      refute table?(db, "cold_start_receipts")
      refute "creationKind" in table_columns(db, "users")
    end
  end

  defp captured_db!(fixture) do
    source = Path.join([__DIR__, "fixtures", "cold_start", fixture, "state.db"])
    target = Path.join(System.tmp_dir!(), "#{fixture}-#{System.unique_integer([:positive])}.db")
    File.cp!(source, target)
    name = :"#{fixture}_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {DB, :start_link, [[path: target, name: name]]}
    })

    name
  end

  defp pair_input(device_id, claimed_name) do
    %{
      device_id: device_id,
      claimed_name: claimed_name,
      platform: nil,
      model: nil,
      replay_secret: nil
    }
  end

  defp identity_census(db) do
    {:ok, [row]} =
      DB.query(db, """
      SELECT (SELECT COUNT(*) FROM users), (SELECT COUNT(*) FROM devices),
             (SELECT COUNT(*) FROM sessions), (SELECT COUNT(*) FROM cold_start_receipts),
             (SELECT COUNT(*) FROM events WHERE verb IN ('cold-start','cold-start-device'))
      """)

    row
  end

  defp table?(db, name) do
    {:ok, rows} =
      DB.query(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1", [name])

    rows == [[1]]
  end

  defp table_columns(db, name) do
    {:ok, rows} = DB.query(db, "PRAGMA table_info(#{name})")
    Enum.map(rows, fn [_cid, column | _] -> column end)
  end

  defp migration_snapshot(db) do
    {:ok, stamp} = DB.query(db, "SELECT shape,stampedAt FROM schema_stamp")

    {:ok, objects} =
      DB.query(
        db,
        "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name"
      )

    {:ok, census} =
      DB.query(db, """
      SELECT (SELECT COUNT(*) FROM users), (SELECT COUNT(*) FROM devices),
             (SELECT COUNT(*) FROM sessions), (SELECT COUNT(*) FROM events)
      """)

    {stamp, objects, census}
  end

  defp assert_event_corruptions_refuse(db, event_id) do
    assert {:ok, [original]} =
             DB.query(
               db,
               "SELECT id,ts,kind,verb,origin,principal,sessionKey,payload FROM events WHERE id=?1",
               [event_id]
             )

    for {column, corrupt} <- [
          {"kind", "denied"},
          {"verb", "wrong"},
          {"origin", "user:wrong"},
          {"principal", "user:wrong"},
          {"sessionKey", "agent:missing"},
          {"payload", "%{}"}
        ] do
      assert {:ok, _} =
               DB.query(db, "UPDATE events SET #{column}=?1 WHERE id=?2", [corrupt, event_id])

      error = assert_raise Tightbeam.Schema.ShapeError, fn -> ColdStart.validate!(db) end

      assert error.message ==
               "incompatible_cold_start_v1: receipt_event_shape_invalid; recovery: Recover an unusable fresh database"

      restore_event!(db, original)
      assert :ok = ColdStart.validate!(db)
    end
  end

  defp restore_event!(db, [id, ts, kind, verb, origin, principal, session_key, payload]) do
    assert {:ok, _} =
             DB.query(
               db,
               """
               UPDATE events SET ts=?1,kind=?2,verb=?3,origin=?4,principal=?5,sessionKey=?6,payload=?7
               WHERE id=?8
               """,
               [ts, kind, verb, origin, principal, session_key, payload, id]
             )
  end

  defp concurrent(functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn function ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> function.()
          end
        end)
      end)

    Enum.each(tasks, fn task ->
      pid = task.pid
      assert_receive {:ready, ^pid}
    end)

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 5_000))
  end
end
