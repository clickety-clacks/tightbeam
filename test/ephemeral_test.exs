defmodule Tightbeam.EphemeralTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    WorkItems,
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
        INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
        VALUES('#{key}','helper','owner','user:owner','default','claude','anthropic','fable',1,1)
        """)

      assert {:ok, _} = DB.transaction(db, &Ephemeral.stamp_in_txn(&1, key, "caller"))
      assert {:ok, seq} = enqueue(db, key)
      assert {:error, :ephemeral_turn_used} = enqueue(db, key)
      assert {:ok, turn} = Ledger.claim_next(db, key, "test")
      assert :ok = Ledger.finish(db, seq, terminal, nil, owner_lease: turn.owner_lease)
      assert Org.get(db, key).state == "retired"
      wake = Wakes.get(db, "ephemeral-result:" <> key)
      assert wake.session_key == "caller"
      assert is_binary(wake.prompt)

      summary =
        case terminal do
          "delivered" -> "completed"
          "canceled" -> "canceled"
          "failed_unknown" -> "recovered"
          "failed" -> "failed"
        end

      assert wake.prompt =~ summary

      assert :already_terminal = Ledger.finish(db, seq, terminal)
      assert Wakes.get(db, "ephemeral-result:" <> key) == wake

      assert {:ok, [[1]]} =
               DB.query(db, "SELECT COUNT(*) FROM wakes WHERE wakeId=?1", [wake.wake_id])

      assert {:error, :ephemeral_turn_used} = enqueue(db, key)
    end

    assert {:ok, _} = enqueue(db, "ordinary")
    assert {:ok, _} = enqueue(db, "ordinary")
  end

  test "R2.2 recovery retires an interrupted helper instead of rerunning it", %{db: db} do
    assert {:ok, seq} = enqueue(db, "helper")
    assert {:ok, _turn} = Ledger.claim_next(db, "helper", "interrupted")
    assert [^seq] = Ledger.recover_running(db)
    assert Org.get(db, "helper").state == "retired"
    assert Wakes.get(db, "ephemeral-result:helper").prompt =~ "recovered"
    assert [] = Ledger.recover_running(db)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM wakes WHERE wakeId='ephemeral-result:helper'")

    assert {:error, :ephemeral_turn_used} = enqueue(db, "helper")
  end

  test "R2.3 rejects assignment and card ownership at their write paths", %{db: db} do
    call = %{
      verb: "assign",
      principal: {:user, "owner"},
      origin: "user:owner",
      session_key: "helper",
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{subject: "inspect"}
    }

    assert %{code: "ephemeral_obligation"} = Assignments.__handle__(db, "assign", call)
    card = WorkItems.__handle__(db, "work-item-create", %{call | params: %{title: "inspect"}})

    assert %{code: "ephemeral_obligation"} =
             WorkItems.__handle__(db, "work-item-update", %{
               call
               | params: %{work_item_id: card.id, delivery_owner_session_key: "helper"}
             })

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT COUNT(*) FROM assignments WHERE holderKey='helper'")

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM work_items WHERE deliveryOwnerSessionKey='helper'"
             )
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

  test "R2.3 read rules still deny without escalating the helper", %{db: db} do
    rule = %{
      name: "read-approval",
      verb: "inspect",
      verbs: ["inspect"],
      text: "approval required",
      conditions: [],
      edges: ["verb"],
      effect: "escalate",
      check: nil,
      identity_manifest_sha: "test-identity"
    }

    :persistent_term.put(Tightbeam.Rules, [rule])

    call = %{
      verb: "inspect",
      origin: "session:helper",
      principal: {:session, "helper"},
      session_key: nil,
      params: %{}
    }

    assert {:error, %{code: "rule_denied", reason: "rule_denied"}} =
             Dispatch.dispatch(db, %{"inspect" => fn _ -> flunk("must deny") end}, call)

    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM decision_requests")
  end

  @tag :tmp_dir
  test "R2.4 tools use a fresh empty temporary directory removed after the turn", %{
    db: db,
    tmp_dir: tmp
  } do
    assert {:ok, _} = Placement.register_host(db, "testhost", %{ssh: nil, base_dir: tmp})
    owner = self()

    sh = fn [command | args] ->
      result = System.cmd(command, args, stderr_to_stdout: true)
      if command == "rm", do: send(owner, {:directory_removed, List.last(args)})
      result
    end

    config = %{db: db, base_dir: tmp, sh: sh}
    helper = Org.get(db, "helper")

    path =
      Placement.with_turn_directory(config, helper, fn ->
        path = Placement.holder_workdir(config, helper)
        assert path != "/"
        assert File.ls!(path) == []
        File.write!(Path.join(path, "scratch"), "discard")
        path
      end)

    assert_receive {:directory_removed, ^path}, 1_000
    refute File.exists?(path)

    next =
      Placement.with_turn_directory(config, helper, fn ->
        next = Placement.holder_workdir(config, helper)
        refute next == path
        assert File.ls!(next) == []
        next
      end)

    assert_receive {:directory_removed, ^next}, 1_000
    refute File.exists?(next)
  end

  @tag :tmp_dir
  test "cleanup failure preserves the runner result and exception", %{db: db, tmp_dir: tmp} do
    assert {:ok, _} = Placement.register_host(db, "testhost", %{ssh: nil, base_dir: tmp})
    helper = Org.get(db, "helper")
    owner = self()

    sh = fn
      ["mktemp" | _] ->
        {"/tmp/helper-cleanup-fixture\n", 0}

      ["rm", "-rf", "--", "/tmp/helper-cleanup-fixture"] ->
        send(owner, {:cleanup_attempted, self()})
        {"removal failed", 1}
    end

    config = %{db: db, base_dir: tmp, sh: sh}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :runner_result} ==
                 Placement.with_turn_directory(config, helper, fn -> {:ok, :runner_result} end)

        assert_receive {:cleanup_attempted, cleaner}, 1_000
        ref = Process.monitor(cleaner)
        assert_receive {:DOWN, ^ref, :process, ^cleaner, reason}, 1_000
        assert reason in [:normal, :noproc]

        assert_raise RuntimeError, "runner failure", fn ->
          Placement.with_turn_directory(config, helper, fn -> raise "runner failure" end)
        end

        assert_receive {:cleanup_attempted, failed_cleaner}, 1_000
        failed_ref = Process.monitor(failed_cleaner)
        assert_receive {:DOWN, ^failed_ref, :process, ^failed_cleaner, failed_reason}, 1_000
        assert failed_reason in [:normal, :noproc]
      end)

    assert log =~ "Ephemeral temporary directory cleanup failed for helper"
    assert log =~ "/tmp/helper-cleanup-fixture"
    assert log =~ "removal failed"
  end

  @tag :tmp_dir
  test "the cleaner retains ownership when the runner process dies", %{db: db, tmp_dir: tmp} do
    assert {:ok, _} = Placement.register_host(db, "testhost", %{ssh: nil, base_dir: tmp})
    helper = Org.get(db, "helper")
    owner = self()

    sh = fn
      ["mktemp" | _] ->
        {"/tmp/helper-owner-death-fixture\n", 0}

      ["rm", "-rf", "--", "/tmp/helper-owner-death-fixture"] ->
        send(owner, :owner_death_cleanup)
        {"", 0}
    end

    config = %{db: db, base_dir: tmp, sh: sh}

    runner =
      spawn(fn ->
        Placement.with_turn_directory(config, helper, fn ->
          send(owner, :runner_started)

          receive do
            :finish -> :ok
          end
        end)
      end)

    ref = Process.monitor(runner)
    assert_receive :runner_started, 1_000
    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^runner, :killed}, 1_000
    assert_receive :owner_death_cleanup, 1_000
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

  test "R2.5 retired callers return to their parent, with no further routing", %{db: db} do
    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE sessions SET spawnedBy='ordinary',state='retired' WHERE sessionKey='caller'"
             )

    assert {:ok, :ok} = DB.transaction(db, &Ephemeral.return_in_txn(&1, "helper", "result"))
    assert Wakes.get(db, "ephemeral-result:helper").session_key == "ordinary"
    assert {:ok, :ok} = DB.transaction(db, &Ephemeral.return_in_txn(&1, "helper", "duplicate"))
    assert Wakes.get(db, "ephemeral-result:helper").prompt =~ "result"
  end

  test "R2.5 drops and logs a result if the caller and parent are retired", %{db: db} do
    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE sessions SET spawnedBy='ordinary',state='retired' WHERE sessionKey='caller'"
             )

    assert {:ok, _} =
             DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey='ordinary'")

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert {:ok, :ok} =
                      DB.transaction(db, &Ephemeral.return_in_txn(&1, "helper", "result"))
           end) =~ "Dropping ephemeral result"

    assert Wakes.get(db, "ephemeral-result:helper") == nil
  end

  test "R2.5 drops a result when its retired caller has no parent", %{db: db} do
    assert {:ok, _} =
             DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey='caller'")

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, :ok} = DB.transaction(db, &Ephemeral.return_in_txn(&1, "helper", "result"))
    end)

    assert Wakes.get(db, "ephemeral-result:helper") == nil
  end

  test "migration failure keeps boot available, rolls back the marker and disables helpers", %{
    db: db
  } do
    Tightbeam.SchemaShapeRuntimeFixture.downgrade_ephemeral!(db)
    assert :ok = DB.execute(db, "CREATE TABLE ephemeral_sessions(conflict TEXT)")
    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Schema.ensure_all(db) end)
    assert log =~ "Ephemeral migration failed; feature unavailable"
    refute Ephemeral.available?(db)
    refute Ephemeral.session?(db, "ordinary")

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT COUNT(*) FROM sqlite_schema WHERE name='ephemeral_migration'")

    assert {:ok, _} = enqueue(db, "ordinary")
    assert {:error, _} = DB.transaction(db, &Ephemeral.stamp_in_txn(&1, "ordinary", "caller"))
    assert :ok = DB.execute(db, "DROP TABLE ephemeral_sessions")
    assert :ok = Schema.ensure_all(db)
    assert Ephemeral.available?(db)
    assert {:ok, [[0]]} = DB.query(db, "SELECT id FROM ephemeral_migration")
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

  test "R2.1-R2.5 additive migration preserves existing 0.1.9 sessions", %{db: db} do
    Tightbeam.SchemaShapeRuntimeFixture.downgrade_ephemeral!(db)
    assert {:ok, before_rows} = DB.query(db, "SELECT * FROM sessions ORDER BY sessionKey")
    assert :ok = Schema.ensure_all(db)
    assert :ok = Schema.ensure_all(db)
    assert {:ok, ^before_rows} = DB.query(db, "SELECT * FROM sessions ORDER BY sessionKey")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM ephemeral_sessions")
    assert {:ok, [[0]]} = DB.query(db, "SELECT id FROM ephemeral_migration")
  end

  @tag :tmp_dir
  test "R2.1-R2.5 additive migration follows the 0.1.8 predecessor upgrade", %{tmp_dir: tmp} do
    prepared =
      Tightbeam.GuardRuntimeFixture.prepare!(
        Path.join(tmp, "payload"),
        "schema_shape_runtime.exs"
      )

    path = Path.join(tmp, "predecessor/state.db")
    Tightbeam.SchemaShapeRuntimeFixture.seed_operator_predecessor!(path, prepared.payload)
    manifest = File.read!(Path.join(prepared.payload, "build-manifest.json")) |> JSON.decode!()

    transition =
      JSON.encode!(%{
        "base" => Path.dirname(path),
        "source" => "unmarked",
        "target" => manifest["buildIdentity"],
        "expectedSchema" => "operator-decision-requests-v1"
      })

    name = :"ephemeral_upgrade_#{System.unique_integer([:positive])}"

    db =
      start_supervised!(
        Supervisor.child_spec(
          {DB,
           path: path,
           name: name,
           payload_root: prepared.payload,
           guard_inputs: [transition: transition]},
          id: name
        )
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
