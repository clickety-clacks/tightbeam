defmodule Tightbeam.O2SchemaMigrationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Schema}
  alias Tightbeam.DB.Txn

  # Captured from ac0b966c:lib/tightbeam/schema.ex (SHA256 a9d3130f9242bedecfabc7d83afa1425b2882a6eac5e90dc618252f9c1427400).
  # Generated without Application startup, using the accepted pre-O2 modules.
  @fixture Path.expand("fixtures/o2_admission_v1.sql", __DIR__)

  setup do
    name = String.to_atom("o2_schema_#{System.unique_integer([:positive])}")
    db = start_supervised!({DB, name: name, path: ":memory:"})
    %{db: db}
  end

  test "fresh O2 bootstrap and restart preserve nullable notice state", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    assert stamp(db) == "stale-turn-settlement-v1-019"
    seed_episode(db)
    assert rows(db, "SELECT noticeState FROM rail_remedy_episodes") == [[nil]]
    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT noticeState FROM rail_remedy_episodes") == [[nil]]
    assert rows(db, "PRAGMA foreign_key_check") == []
    assert rows(db, "PRAGMA foreign_keys") == [[1]]
    assert_two_shapes(db)
  end

  test "exact old predecessor copies all cancellation columns and preserves triggers and rows", %{
    db: db
  } do
    load_old(db)
    seed_episode(db)
    seed_historical_surrender(db)
    wake(db, "legacy")

    assert {:ok, :ok} =
             cancel(
               db,
               "legacy",
               "user",
               "fixture",
               "requester_withdrew",
               "verb_call",
               "no_replacement",
               false
             )

    before_rows = rows(db, "SELECT * FROM wake_cancellations")
    before_wakes = rows(db, "SELECT * FROM wakes ORDER BY wakeId")
    before_episode = rows(db, "SELECT * FROM rail_remedy_episodes")
    before_triggers = triggers(db)
    assert :ok = Schema.ensure_all(db)
    assert stamp(db) == "stale-turn-settlement-v1-019"
    assert rows(db, "SELECT * FROM wake_cancellations") == before_rows
    assert rows(db, "SELECT * FROM wakes ORDER BY wakeId") == before_wakes

    assert rows(
             db,
             "SELECT a.state,a.outcome,t.kind,t.note FROM assignments a JOIN attests t ON t.id=a.closingAttestId WHERE a.id='asg_historical_surrender'"
           ) == [["closed", "surrendered", "surrender", "historical surrender"]]

    assert rows(
             db,
             "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('assignment_cannot_proceed','assignment_cannot_proceed_release_observations') ORDER BY name"
           ) ==
             [["assignment_cannot_proceed"]]

    assert rows(db, "SELECT * FROM rail_remedy_episodes") ==
             Enum.map(before_episode, &(&1 ++ [nil]))

    # Only the explicit rowVersion and current-lineage trigger upgrades change old SQL.
    before_names =
      before_triggers
      |> Enum.reject(fn [name, _sql] -> String.starts_with?(name, "harness_health_") end)
      |> Enum.map(&hd/1)

    assert Enum.filter(triggers(db), &(hd(&1) in before_names)) ==
             before_triggers
             |> Enum.filter(fn [name, _sql] -> name in before_names end)
             |> Enum.map(fn [name, sql] -> [name, successor_guard(name, sql)] end)

    assert rows(
             db,
             "SELECT name FROM sqlite_master WHERE type='trigger' AND name GLOB 'harness_health_*' ORDER BY name"
           ) ==
             Enum.map(
               ~w(
                 harness_health_assignment_holder harness_health_assignment_immutable_delete
                 harness_health_assignment_immutable_update
                 harness_health_class_promotion_close_once harness_health_incident_identity_immutable
                 harness_health_incident_no_delete harness_health_incident_resolution_once
                 harness_health_member_immutable_delete harness_health_member_immutable_update
                 harness_health_observation_assignment_holder harness_health_observation_attachment_once
                 harness_health_observation_evidence_immutable
                 harness_health_observation_identity_immutable harness_health_observation_no_delete
                 harness_health_other_review_event_append_only_delete
                 harness_health_other_review_event_append_only_update
                 harness_health_other_route_identity_immutable harness_health_other_route_no_delete
                 harness_health_other_route_pending_terminal harness_health_other_route_terminal_once
               ),
               &[&1]
             )

    assert rows(
             db,
             "SELECT sql FROM sqlite_master WHERE name='harness_health_incident_resolution_once'"
           )
           |> hd()
           |> hd() =~
             "OLD.failureClass = 'other'"

    assert rows(db, "PRAGMA foreign_key_check") == []
    assert rows(db, "PRAGMA foreign_keys") == [[1]]
    assert :ok = Schema.ensure_all(db)
    assert rows(db, "SELECT * FROM wake_cancellations") == before_rows
    assert stamp(db) == "stale-turn-settlement-v1-019"

    assert rows(db, "SELECT kind FROM attests WHERE id='att_historical_surrender'") == [
             ["surrender"]
           ]

    assert_two_shapes(db)
  end

  test "stamp-write failure rolls back column, table rebuild, rows and triggers", %{db: db} do
    load_old(db)
    seed_episode(db)
    wake(db, "legacy")

    assert {:ok, :ok} =
             cancel(
               db,
               "legacy",
               "user",
               "fixture",
               "requester_withdrew",
               "verb_call",
               "no_replacement",
               false
             )

    :ok =
      DB.execute(
        db,
        "CREATE TRIGGER o2_test_refuse_stamp BEFORE UPDATE ON schema_stamp BEGIN SELECT RAISE(ABORT, 'fixture stamp failure'); END"
      )

    before = snapshot(db)
    assert_raise DB.Error, fn -> Schema.ensure_all(db) end
    assert snapshot(db) == before
    assert rows(db, "PRAGMA foreign_keys") == [[1]]
    assert rows(db, "PRAGMA foreign_key_check") == []
    :ok = DB.execute(db, "DROP TRIGGER o2_test_refuse_stamp")
    assert :ok = Schema.ensure_all(db)
  end

  test "unknown predecessor refuses without electing an O2 shape", %{db: db} do
    load_old(db)
    :ok = DB.execute(db, "UPDATE schema_stamp SET shape='unapproved-o2-shape'")
    before = snapshot(db)
    assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end
    assert snapshot(db) == before
  end

  defp assert_two_shapes(db) do
    wake(db, "replacement")
    wake(db, "replace-me")
    wake(db, "satisfied")

    assert {:ok, :ok} =
             cancel(
               db,
               "replace-me",
               "process",
               "tightbeam:rail-remedy",
               "target_unresolvable",
               "scheduler_delivery",
               "replacement",
               true
             )

    assert {:ok, :ok} =
             cancel(
               db,
               "satisfied",
               "process",
               "tightbeam:rail-remedy",
               "superseded",
               "wake",
               "no_replacement",
               true
             )

    for {id, requester, reason, source, outcome} <- [
          {"wrong-requester", "tightbeam:other", "superseded", "wake", "no_replacement"},
          {"wrong-source", "tightbeam:rail-remedy", "superseded", "scheduler_delivery",
           "no_replacement"},
          {"wrong-reason", "tightbeam:rail-remedy", "obligation_disposed", "wake",
           "no_replacement"},
          {"wrong-outcome", "tightbeam:rail-remedy", "target_unresolvable", "scheduler_delivery",
           "no_replacement"}
        ] do
      wake(db, id)
      assert {:error, _} = cancel(db, id, "process", requester, reason, source, outcome, true)
      assert rows(db, "SELECT state FROM wakes WHERE wakeId=?1", [id]) == [["pending"]]
      assert rows(db, "SELECT wakeId FROM wake_cancellations WHERE wakeId=?1", [id]) == []
    end

    wake(db, "untyped")

    assert {:error, _} =
             DB.query(
               db,
               "UPDATE wakes SET state='canceled',canceledAt=10 WHERE wakeId='untyped'"
             )

    assert rows(db, "PRAGMA foreign_key_check") == []
  end

  test "retained pre-liveness upgrade resumes after interrupted O2 activation", %{db: db} do
    load_old(db)
    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")

    for name <-
          ~w(supervision_liveness_retirement_immutable_delete
      supervision_liveness_retirement_immutable_update
      supervision_pending_controller_wake_identity_immutable
      supervision_pending_controller_sidecar_delete supervision_pending_controller_sidecar_update
      supervision_liveness_sidecar_insert_coherent supervision_checkpoint_binding_insert_coherent
      supervision_fired_lineage_turn_immutable_delete supervision_fired_lineage_turn_immutable_update
      supervision_fired_lineage_sidecar_identity_immutable supervision_fired_lineage_sidecar_required_delete
      supervision_lineage_fire_requires_sidecar wakes_typed_cancellation_required wake_cancellations_pending_insert) do
      :ok = DB.execute(db, "DROP TRIGGER IF EXISTS #{name}")
    end

    for name <-
          ~w(wake_cancellations supervision_liveness_sidecar supervision_progress_absorptions
      supervision_liveness_receipt_state supervision_liveness_receipts supervision_liveness_checkpoint_bindings
      supervision_entitlements supervision_liveness_epoch supervision_liveness_migrations) do
      :ok = DB.execute(db, "DROP TABLE #{name}")
    end

    :ok = DB.execute(db, "DROP INDEX wakes_cancellation_state")

    :ok =
      DB.execute(db, "UPDATE schema_stamp SET shape='row-driven-admission-pre-liveness-v1-019'")

    :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    seed_episode(db)

    :ok =
      DB.execute(db, """
      CREATE TRIGGER o2_test_refuse_activation BEFORE UPDATE ON schema_stamp
      WHEN NEW.shape='row-driven-o2-v1-019'
      BEGIN SELECT RAISE(ABORT, 'fixture activation failure'); END
      """)

    assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end
    assert stamp(db) == "row-driven-o2-pre-liveness-v1-019"
    assert rows(db, "SELECT noticeState FROM rail_remedy_episodes") == [[nil]]
    assert rows(db, "SELECT name FROM sqlite_master WHERE name='wake_cancellations'") == []
    :ok = DB.execute(db, "DROP TRIGGER o2_test_refuse_activation")
    assert :ok = Schema.ensure_all(db)
    assert stamp(db) == "stale-turn-settlement-v1-019"
    assert rows(db, "SELECT noticeState FROM rail_remedy_episodes") == [[nil]]
    assert_two_shapes(db)
  end

  defp load_old(db) do
    :ok = DB.execute(db, File.read!(@fixture))
    :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    assert stamp(db) == "row-driven-admission-v1-019"
  end

  defp seed_episode(db) do
    :ok =
      DB.execute(
        db,
        "INSERT INTO rail_remedy_episodes (statute,subject,status,occurrence,rewakeCount,claimToken,openedAt) VALUES ('fixture','subject','closed',1,0,'claim',1)"
      )
  end

  defp seed_historical_surrender(db) do
    :ok =
      DB.execute(db, """
      INSERT INTO users(userId,isAdmin,createdAt) VALUES ('historical-owner',0,1);
      INSERT INTO sessions(
        sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,host,createdAt,updatedAt
      ) VALUES (
        'historical-holder','Historical holder','historical-owner','user:historical-owner',
        'default','fixture','fixture_provider','fixture','local',1,1
      );
      INSERT INTO assignments(
        id,subject,holderKey,openedByUser,openedAt
      ) VALUES (
        'asg_historical_surrender','historical surrender','historical-holder',
        'historical-owner',1
      );
      INSERT INTO attests(id,assignmentId,kind,note,bySession,ts)
      VALUES (
        'att_historical_surrender','asg_historical_surrender','surrender',
        'historical surrender','historical-holder',2
      );
      UPDATE assignments
      SET state='closed',outcome='surrendered',closedAt=2,
          closedBySession='historical-holder',closingAttestId='att_historical_surrender'
      WHERE id='asg_historical_surrender';
      """)
  end

  defp wake(db, id) do
    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt) VALUES (?1,'fixture','process:fixture','fixture',1,1)",
               [id]
             )
  end

  defp cancel(db, id, kind, requester, reason, source, outcome, linked) do
    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        """
        INSERT INTO wake_cancellations
          (wakeId,canceledAt,requesterKind,requesterId,reasonKind,causalSourceKind,causalSourceId,
           outcomeKind,replacementWakeId,primaryWorkKind,primaryWorkId,workImpactKind,actionNeeded)
        VALUES (?1,10,?2,?3,?4,?5,?1,?6,?7,?8,?9,?10,0)
        """,
        [
          id,
          kind,
          requester,
          reason,
          source,
          outcome,
          if(outcome == "replacement", do: "replacement", else: nil),
          if(linked, do: "assignment", else: nil),
          if(linked, do: "fixture-assignment", else: nil),
          if(linked, do: "linked_work_open", else: "no_linked_work")
        ]
      )

      Txn.q(txn, "UPDATE wakes SET state='canceled',canceledAt=10 WHERE wakeId=?1", [id])
      :ok
    end)
  end

  defp rows(db, sql, args \\ []) do
    {:ok, result} = DB.query(db, sql, args)
    result
  end

  defp stamp(db), do: rows(db, "SELECT shape FROM schema_stamp") |> hd() |> hd()

  # Preserve terminal-principal predicates while adding the explicit rowVersion checks.
  defp successor_guard(name, sql)
       when name in ~w(decision_requests_terminal_insert_guard decision_requests_terminal_update_guard) do
    assert String.contains?(sql, "\nWHEN ")
    assert String.contains?(sql, "))\nBEGIN\n")

    sql
    |> String.replace("BEFORE UPDATE OF status ON", "BEFORE UPDATE ON")
    |> String.replace(
      "\nWHEN ",
      "\nWHEN typeof(NEW.rowVersion) <> 'integer' OR NEW.rowVersion < 1 OR\n  ("
    )
    |> String.replace("))\nBEGIN\n", ")))\nBEGIN\n")
  end

  defp successor_guard("supervision_liveness_sidecar_insert_coherent", sql) do
    # Event-derived ancestry is the only change to this historical trigger;
    # admission behavior is exercised separately in SessionReparentTest.
    sql
    |> String.replace(
      "SELECT sessionKey,spawnedBy FROM sessions",
      "SELECT sessionKey,#{Tightbeam.Org.current_parent_sql("sessions")} FROM sessions"
    )
    |> String.replace(
      "SELECT ancestor.sessionKey,ancestor.spawnedBy",
      "SELECT ancestor.sessionKey,#{Tightbeam.Org.current_parent_sql("ancestor")}"
    )
  end

  defp successor_guard(_name, sql), do: sql

  defp triggers(db),
    do: rows(db, "SELECT name,sql FROM sqlite_master WHERE type='trigger' ORDER BY name")

  defp snapshot(db) do
    {rows(db, "SELECT type,name,sql FROM sqlite_master ORDER BY type,name"),
     rows(db, "SELECT * FROM schema_stamp"), rows(db, "SELECT * FROM rail_remedy_episodes"),
     rows(db, "SELECT * FROM wake_cancellations"), rows(db, "SELECT * FROM wakes")}
  end
end
