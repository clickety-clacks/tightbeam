defmodule Tightbeam.SchemaShapeTest.FailingDb do
  @moduledoc """
  A `Tightbeam.DB` interposer that forwards everything to the real server and
  fails ONE statement — the first whose SQL contains `fragment`.

  It exists because an interrupted bootstrap cannot be simulated by building
  its end state: the whole question is WHEN the stamp is written relative to
  the tables, and that is only observable by stopping a real run in the middle.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @impl true
  def init(opts), do: {:ok, Map.put(opts, :armed, true)}

  @impl true
  def handle_call(message, _from, state) do
    if state.armed and holds?(message, state.fragment) do
      {:reply, {:error, "interrupted"}, %{state | armed: false}}
    else
      {:reply, GenServer.call(state.db, message), state}
    end
  end

  defp holds?(message, fragment) do
    message |> Tuple.to_list() |> Enum.any?(&(is_binary(&1) and String.contains?(&1, fragment)))
  end
end

defmodule Tightbeam.SchemaShapeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Model, Org, Schema}

  @shape "coordination-fabric-v1-phase1-v6"

  setup do
    name = :"schema_shape_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    %{db: name}
  end

  test "a fresh database is created and stamped", %{db: db} do
    assert :ok = Schema.ensure_all(db)

    assert {:ok, [["coordination-fabric-v1-phase1-v6"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    # Idempotent: booting twice is the ordinary case, not a shape change.
    assert :ok = Schema.ensure_all(db)

    assert {:ok, [["coordination-fabric-v1-phase1-v6"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")
  end

  test "the harness health foundation is additive and exact", %{db: db} do
    assert :ok = Schema.ensure_all(db)

    assert table_columns(db, "harness_health_observations") ==
             ~w(id correlationId harness host failureClass evidenceKind sessionKey assignmentId observedAt cause principal incidentId)

    assert table_columns(db, "harness_health_incidents") ==
             ~w(id harness host failureClass state openedAt openObservationId openedFactId resolvedAt resolutionObservationId resolvedFactId)

    assert table_columns(db, "harness_health_members") == ~w(incidentId sessionKey)

    assert table_columns(db, "harness_health_assignments") ==
             ~w(incidentId assignmentId sessionKey)

    assert table_columns(db, "turn_repair_attempts") ==
             ~w(id repairKey sourceSeq attemptSeq assignmentId principal createdAt)

    assert table_columns(db, "assignment_repair_attempts") ==
             ~w(id assignmentId repairKey requestFingerprint action principal state resultJson createdAt completedAt)

    assert {:ok, [[@shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM harness_health_incidents")
  end

  test "the shared liveness activation creates one exact additive shape", %{db: db} do
    assert :ok = Schema.ensure_all(db)

    assert table_columns(db, "supervision_entitlements") ==
             ~w(assignmentId generation dueAt state lastAttemptGeneration claimClock basisKind basisId terminusAt cause principal supervisionIntervalMs)

    assert table_columns(db, "supervision_progress_absorptions") ==
             ~w(attestId assignmentId attestTs generation recoveryBaseline cause principal)

    assert table_columns(db, "supervision_liveness_sidecar") ==
             ~w(wakeId assignmentId controllerOrigin wakeKind controllerState chargedGeneration transferEvidenceId retirementEpoch retiringSessionKey retirementOutcomeKind retirementOutcomeId retirementTargetSessionKey retirementCause retirementPrincipal retirementActionNeeded)

    assert table_columns(db, "wake_cancellations") ==
             ~w(wakeId wakeState canceledAt requesterKind requesterId reasonKind causalSourceKind causalSourceId outcomeKind replacementWakeId dispositionKind dispositionId primaryWorkKind primaryWorkId workImpactKind livenessTriggerKind livenessTriggerId actionNeeded)

    assert table_columns(db, "supervision_liveness_epoch") ==
             ~w(id activatedAt cause principal)

    assert table_columns(db, "supervision_liveness_migrations") ==
             ~w(migrationId appliedAt affectedRows cause principal)

    assert table_columns(db, "supervision_liveness_receipt_state") ==
             ~w(assignmentId artifactCursor attestCursor workItemEventCursor wakeCursor baselineCause baselinePrincipal)

    assert table_columns(db, "supervision_liveness_receipts") ==
             ~w(receiptId assignmentId sourceKind sourceId sourceAt acceptedAt generation expiresAt)

    assert table_columns(db, "supervision_liveness_checkpoint_bindings") ==
             ~w(wakeId assignmentId holderSessionKey sourceTurnSeq boundAt principal)

    assert length(owned_activation_objects(db)) == 29

    assert {:ok, [[0, activated_at, "schema_activation", "process:tightbeam"]]} =
             DB.query(
               db,
               "SELECT id,activatedAt,cause,principal FROM supervision_liveness_epoch"
             )

    assert is_integer(activated_at) and activated_at >= 0
    refute table?(db, "wake_cancellation_legacy")
    refute table?(db, "wake_cancellation_epoch")

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [[1, ^activated_at]]} =
             DB.query(db, "SELECT COUNT(*),MIN(activatedAt) FROM supervision_liveness_epoch")
  end

  test "a malformed additive object refuses without partial activation", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    drop_liveness_activation(db)

    :ok =
      DB.execute(db, "CREATE TABLE supervision_liveness_sidecar (wakeId TEXT PRIMARY KEY)")

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end
    assert error.message =~ "incompatible_supervision_liveness_v1"
    assert error.message =~ "supervision_liveness_sidecar"
    assert table_columns(db, "supervision_liveness_sidecar") == ["wakeId"]
    refute table?(db, "supervision_entitlements")
    refute table?(db, "wake_cancellations")
    refute table?(db, "supervision_liveness_epoch")
  end

  test "an existing liveness activation gains the lineage firing invariant", %{db: db} do
    assert :ok = Schema.ensure_all(db)

    :ok = DB.execute(db, "DROP TRIGGER supervision_lineage_fire_requires_sidecar")
    refute "supervision_lineage_fire_requires_sidecar" in owned_activation_objects(db)

    assert :ok = Schema.ensure_all(db)
    assert "supervision_lineage_fire_requires_sidecar" in owned_activation_objects(db)
  end

  test "only Tightbeam supervision lineage firing requires a sidecar", %{db: db} do
    assert :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO wakes
        (wakeId,sessionKey,origin,prompt,consumer,dueAt,state,createdAt,
         reresolve,reresolveSeed,reresolveRung,assignmentId)
      VALUES
        ('w_supervision','target','process:tightbeam','escalate','prompt',0,'pending',1,
         'lineage','holder',1,'asg_1'),
        ('w_other','target','process:ci','route','prompt',0,'pending',1,
         'lineage','holder',1,'asg_1')
      """)

    assert {:error, %DB.Error{message: message}} =
             DB.query(
               db,
               "UPDATE wakes SET state='fired', firedAt=2 WHERE wakeId='w_supervision'"
             )

    assert message =~ "supervision lineage wake requires controller sidecar"

    assert {:ok, [["pending"]]} =
             DB.query(db, "SELECT state FROM wakes WHERE wakeId='w_supervision'")

    assert {:ok, []} =
             DB.query(db, "UPDATE wakes SET state='fired', firedAt=2 WHERE wakeId='w_other'")

    assert {:ok, [["fired"]]} = DB.query(db, "SELECT state FROM wakes WHERE wakeId='w_other'")
  end

  test "every interrupted activation statement rolls back and retries once", %{db: db} do
    assert :ok = Schema.ensure_all(db)

    for statement <- 1..15 do
      drop_liveness_activation(db)

      assert {:error, %RuntimeError{message: "forced activation interruption"}} =
               DB.transaction(db, fn txn ->
                 Schema.ensure_supervision_liveness_v1_in_txn(txn, 40_000,
                   fail_after_statement: statement
                 )
               end)

      assert owned_activation_objects(db) == []

      assert {:ok, :ok} =
               DB.transaction(db, fn txn ->
                 Schema.ensure_supervision_liveness_v1_in_txn(txn, 40_000 + statement)
               end)

      assert {:ok, [[activated_at]]} =
               DB.query(db, "SELECT activatedAt FROM supervision_liveness_epoch")

      assert activated_at == 40_000 + statement
    end
  end

  test "an incomplete activation and an empty epoch refuse without repair", %{db: db} do
    assert :ok = Schema.ensure_all(db)

    :ok = DB.execute(db, "DROP INDEX supervision_liveness_assignment")
    objects_before = owned_activation_objects(db)

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end
    assert error.message =~ "incompatible_supervision_liveness_v1"
    assert error.message =~ "supervision_liveness_assignment"
    assert owned_activation_objects(db) == objects_before

    :ok =
      DB.execute(
        db,
        "CREATE INDEX supervision_liveness_assignment ON supervision_liveness_sidecar(assignmentId, wakeId)"
      )

    :ok = DB.execute(db, "DELETE FROM supervision_liveness_epoch")

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end
    assert error.message =~ "incompatible_supervision_liveness_v1"
    assert error.message =~ "supervision_liveness_epoch row"
    assert {:ok, []} = DB.query(db, "SELECT id FROM supervision_liveness_epoch")
  end

  test "upgraded historical wake rows stay byte-stable and gain no inferred carrier", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    drop_liveness_activation(db)

    :ok =
      DB.execute(db, """
      INSERT INTO wakes
        (wakeId,sessionKey,origin,prompt,dueAt,state,createdAt,firedAt,canceledAt)
      VALUES
        ('w_pending','session-a','process:tightbeam','pending',90,'pending',10,NULL,NULL),
        ('w_fired','session-a','process:tightbeam','fired',90,'fired',11,91,NULL),
        ('w_canceled','session-a','process:tightbeam','canceled',90,'canceled',12,NULL,92)
      """)

    {:ok, before_rows} = DB.query(db, "SELECT * FROM wakes ORDER BY wakeId")

    assert :ok = Schema.ensure_all(db)

    assert {:ok, ^before_rows} = DB.query(db, "SELECT * FROM wakes ORDER BY wakeId")
    assert {:ok, []} = DB.query(db, "SELECT wakeId FROM wake_cancellations")

    assert {:ok, [["coordination-fabric-v1-phase1-v6"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")
  end

  test "the exact predecessor upgrades roots to Main and preserves spawn provenance", %{db: db} do
    assert :ok = Schema.ensure_all(db)

    assert {:paired, _device} =
             claim_org(db, %{
               device_id: "legacy-device",
               claimed_name: "Flynn",
               platform: nil,
               model: nil
             })

    main = Org.get(db, Org.personal_session_key("flynn"))
    root = session(db, "root", "flynn")
    child = session(db, "child", "flynn", spawned_by: root.session_key)
    main_key = main.session_key
    root_key = root.session_key
    child_key = child.session_key

    :ok =
      DB.execute(
        db,
        "INSERT INTO harness_pointers (sessionKey,harnessSessionId,sourceSessionRef,harness,machine,reason,createdAt) VALUES ('child','hs-child','source-child','claude','testhost','created',1)"
      )

    downgrade_to_previous_shape(db)

    assert {:ok, [["coordination-fabric-v1-phase1-v4"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    refute "operationalParent" in table_columns(db, "sessions")

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [["coordination-fabric-v1-phase1-v6"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok,
            [
              [^main_key, nil, ^main_key],
              [^child_key, ^root_key, ^root_key],
              [^root_key, nil, ^main_key]
            ]} =
             DB.query(
               db,
               "SELECT sessionKey,spawnedBy,operationalParent FROM sessions ORDER BY sessionKey"
             )

    assert {:ok, [[^child_key, "hs-child"]]} =
             DB.query(db, "SELECT sessionKey,harnessSessionId FROM harness_pointers")

    column =
      Enum.find(table_info(db, "sessions"), fn [_cid, name | _] ->
        name == "operationalParent"
      end)

    assert Enum.at(column, 3) == 1
  end

  test "an interrupted operational-parent upgrade rolls back and retries exactly", %{db: db} do
    assert :ok = Schema.ensure_all(db)

    assert {:paired, _device} =
             claim_org(db, %{
               device_id: "legacy-device",
               claimed_name: "Flynn",
               platform: nil,
               model: nil
             })

    main = Org.get(db, Org.personal_session_key("flynn"))
    main_key = main.session_key
    _root = session(db, "root", "flynn")
    downgrade_to_previous_shape(db)

    error =
      assert_raise Schema.ShapeError, fn ->
        Schema.upgrade_operational_parent_v1(db, fail_at: :after_drop)
      end

    assert error.message =~ "forced operational-parent migration interruption"

    assert {:ok, [["coordination-fabric-v1-phase1-v4"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    refute "operationalParent" in table_columns(db, "sessions")
    refute table?(db, "sessions_operational_parent_v1")

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [[^main_key]]} =
             DB.query(db, "SELECT operationalParent FROM sessions WHERE kind='main'")
  end

  # The defect this refuses: `CREATE TABLE IF NOT EXISTS` is SILENT about a
  # table that already exists in an older shape. It adds no column, so the
  # first query naming `modelContext` dies as an accidental `no such column` —
  # and a column added by hand would be worse, because `sessions.model` from
  # before this change holds `claude-fable-5[1m]`, which this build reads as a
  # family. A wrong answer from data that was right when it was written.
  test "a database predating the structured identity is refused by name", %{db: db} do
    :ok =
      DB.execute(db, """
      CREATE TABLE sessions (
        sessionKey TEXT PRIMARY KEY,
        model      TEXT NOT NULL,
        harness    TEXT NOT NULL
      );
      INSERT INTO sessions (sessionKey, model, harness)
      VALUES ('k1', 'claude-fable-5[1m]', 'claude');
      """)

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end

    assert error.message =~ "predates the structured model identity"
    assert error.message =~ "claude-fable-5[1m]"
    assert error.message =~ "no migration"

    # It REFUSED — it did not repair, and it did not leave the row reinterpreted.
    assert {:ok, [["claude-fable-5[1m]"]]} =
             DB.query(db, "SELECT model FROM sessions WHERE sessionKey='k1'")
  end

  # A FRESH DATABASE MUST NEVER BE REFUSED — including one whose creation was
  # interrupted. Stamped last, a bootstrap that died between `sessions` and the
  # stamp left a database indistinguishable from a genuinely old one, and the
  # next boot refused what this build had just created.
  test "a fresh bootstrap interrupted midway is resumed, not refused", %{db: db} do
    # A GENUINE interruption stopped mid-run, not its end state rebuilt by hand
    # — the question is WHEN the stamp lands relative to the tables, and only a
    # real run can answer it. `work_state_events` is near the END of the module list
    # and executes its DDL directly (the stub matches SQL text, so a module that
    # wraps its DDL in a transaction closure cannot be interrupted this way), so
    # this fails well AFTER `sessions` exists: exactly the window. Stamped last, what
    # that leaves is indistinguishable from a database written before this
    # build, and the next boot refused one this build had just created.
    failing =
      start_supervised!({Tightbeam.SchemaShapeTest.FailingDb, db: db, fragment: "work_state"})

    assert catch_error(Schema.ensure_all(failing))

    assert {:ok, [["sessions"]]} =
             DB.query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='sessions'"),
           "the interruption must land AFTER sessions, or this proves nothing"

    # Boot again against the real server: this must RESUME, not refuse.
    assert :ok = Schema.ensure_all(db)

    assert {:ok, [["work_state_events"]]} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE type='table' AND name='work_state_events'"
             )
  end

  test "more than one stamp is refused rather than crashing", %{db: db} do
    :ok = Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO schema_stamp (shape, stampedAt) VALUES ('other-shape', 1)")

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end
    assert error.message =~ "MORE THAN ONE shape stamp"
    assert error.message =~ "other-shape"
  end

  test "a database stamped by a different build is refused, naming both shapes", %{db: db} do
    :ok = Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "UPDATE schema_stamp SET shape='some-later-shape'")

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end

    assert error.message =~ "some-later-shape"
    assert error.message =~ "coordination-fabric-v1-phase1-v6"
  end

  # Sol xhigh review round 2, finding 2 (wave 1): `classElection`'s CHECK
  # constraint gained `'batcher'` (round-1 finding 7), but `CREATE TABLE IF
  # NOT EXISTS` does not widen an existing table's CHECK any more than it
  # adds a column. A `coordination-fabric-classes-v1` database's `wakes`
  # table — reconstructed here byte-for-byte from cafe321's DDL — still
  # enforces the OLD two-value CHECK. Without the shape bump, this database
  # would boot silently (its stamp used to match `@shape`) and the first
  # digest-carrier insert would die on a raw, unnamed `CHECK constraint
  # failed` deep inside the batcher. This proves the boot gate now refuses it
  # BY NAME first, before any DDL or insert ever reaches the stale
  # constraint. Kept working across the wave-1/wave-2 merge (Sol xhigh review
  # round 3, item 2): the oldest vintage on EITHER line must still refuse.
  test "a coordination-fabric-classes-v1 database is refused by name, never a raw CHECK violation",
       %{db: db} do
    :ok =
      DB.execute(db, """
      CREATE TABLE schema_stamp (
        shape     TEXT PRIMARY KEY,
        stampedAt INTEGER NOT NULL
      );
      INSERT INTO schema_stamp (shape, stampedAt) VALUES ('coordination-fabric-classes-v1', 1);
      CREATE TABLE wakes (
        wakeId     TEXT PRIMARY KEY,
        sessionKey TEXT NOT NULL,
        targetRole TEXT,
        origin     TEXT NOT NULL,
        prompt     TEXT,
        consumer   TEXT NOT NULL DEFAULT 'prompt',
        dueAt      INTEGER NOT NULL,
        state      TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','fired','canceled')),
        createdAt  INTEGER NOT NULL,
        firedAt    INTEGER,
        reresolve  TEXT NULL CHECK (reresolve IN ('lineage')),
        reresolveSeed TEXT NULL,
        reresolveRung INTEGER NULL,
        conditionKind TEXT NULL,
        conditionScope TEXT NULL,
        conditionAfterId INTEGER NULL,
        firedBy TEXT NULL CHECK (firedBy IN ('condition','fallback')),
        creatorSessionKey TEXT NULL,
        rumination INTEGER NOT NULL DEFAULT 0,
        work_item_id TEXT,
        assignmentId TEXT,
        canceledAt INTEGER,
        targetGate INTEGER NOT NULL DEFAULT 1,
        class TEXT,
        classElection TEXT CHECK (classElection IN ('sender','classifier')),
        deliveryRule TEXT,
        digest INTEGER NOT NULL DEFAULT 0 CHECK (digest IN (0,1)),
        summon INTEGER NOT NULL DEFAULT 0 CHECK (summon IN (0,1)),
        CHECK (consumer != 'prompt' OR prompt IS NOT NULL),
        CHECK ((class IS NULL) = (classElection IS NULL)),
        CHECK (digest = 0 OR class IS NOT NULL)
      );
      """)

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end

    assert error.message =~ "coordination-fabric-classes-v1"
    assert error.message =~ "coordination-fabric-v1-phase1-v6"
    assert error.message =~ "no migration"

    # It REFUSED — it did not repair or widen the constraint in place.
    assert {:ok, [[ddl]]} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='wakes'"
             )

    assert ddl =~ "classElection IN ('sender','classifier')"
    refute ddl =~ "batcher"
  end

  # Sol xhigh review round 2, finding 2 (wave 2): `decision_requests.deadlineAt`
  # went from `NOT NULL` to nullable (round-1 finding 1's fix), and the
  # per-kind CHECK arm grew explicit `deadlineAt IS NOT NULL`/`IS NULL`
  # clauses — a real DDL change that landed in `2a3b24a` without bumping
  # `@shape`, so `coordination-fabric-v1-phase1` named two different table
  # shapes at once. `CREATE TABLE IF NOT EXISTS` does not relax an existing
  # table's `NOT NULL` any more than it widens a `CHECK`: a
  # `coordination-fabric-v1-phase1` database's `decision_requests` table —
  # reconstructed here byte-exact from `git show
  # f65c996:lib/tightbeam/escalation.ex` — still enforces `deadlineAt INTEGER
  # NOT NULL`. Without the bump this database would boot silently (its stamp
  # used to match `@shape`) and the first agent `ask` would die on a raw,
  # unnamed `NOT NULL constraint failed` deep inside `file_agent_request/2`.
  # This proves the boot gate now refuses it BY NAME first, before any DDL or
  # insert ever reaches the stale constraint. Kept working across the
  # wave-1/wave-2 merge (Sol xhigh review round 3, item 2).
  test "a coordination-fabric-v1-phase1 database is refused by name, never a raw NOT NULL violation",
       %{db: db} do
    :ok =
      DB.execute(db, """
      CREATE TABLE schema_stamp (
        shape     TEXT PRIMARY KEY,
        stampedAt INTEGER NOT NULL
      );
      INSERT INTO schema_stamp (shape, stampedAt) VALUES ('coordination-fabric-v1-phase1', 1);
      CREATE TABLE IF NOT EXISTS decision_requests (
        id                TEXT PRIMARY KEY,
        kind              TEXT NOT NULL DEFAULT 'statute' CHECK (kind IN ('statute','effort','agent')),
        raiserId          TEXT NOT NULL,
        raiserSessionKey  TEXT,
        ownerUserId       TEXT NOT NULL,
        assignmentId      TEXT,
        expecterSessionKey TEXT,
        expecterUserId    TEXT,
        lineageRung       INTEGER,
        effortGeneration  INTEGER,
        deadlineWakeId    TEXT,
        raisedAt          INTEGER NOT NULL,
        deadlineAt        INTEGER NOT NULL,
        statuteName       TEXT,
        actionKey         TEXT,
        question          TEXT NOT NULL,
        options           TEXT,
        context           TEXT NOT NULL,
        status            TEXT NOT NULL CHECK (status IN ('open','ruled','consumed','withdrawn','superseded','answered')),
        decision          TEXT,
        rationale         TEXT,
        ruledBy           TEXT,
        ruledAt           INTEGER,
        rulingFactId      INTEGER,
        consumedAt        INTEGER,
        parkWakeId        TEXT,
        withdrawnBy       TEXT,
        withdrawnReason   TEXT,
        withdrawnAt       INTEGER,
        askedOfRole       TEXT,
        answer            TEXT,
        answeredBy        TEXT,
        answeredAt        INTEGER,
        CHECK (
          (kind = 'statute' AND statuteName IS NOT NULL AND actionKey IS NOT NULL
           AND expecterSessionKey IS NULL AND expecterUserId IS NULL
           AND lineageRung IS NULL AND effortGeneration IS NULL AND deadlineWakeId IS NULL
           AND (decision IS NULL OR decision IN ('allow','deny','waived')))
          OR
          (kind = 'effort' AND raiserId = 'process:tightbeam'
           AND raiserSessionKey IS NULL
           AND statuteName IS NULL AND actionKey IS NULL AND assignmentId IS NOT NULL
           AND ((expecterSessionKey IS NOT NULL) != (expecterUserId IS NOT NULL))
           AND lineageRung IS NOT NULL AND effortGeneration IS NOT NULL AND deadlineWakeId IS NOT NULL
           AND (decision IS NULL OR decision IN ('continue','dismiss')))
          OR
          (kind = 'agent'
           AND raiserSessionKey IS NOT NULL AND raiserId = 'session:' || raiserSessionKey
           AND expecterSessionKey IS NOT NULL AND expecterUserId IS NOT NULL
           AND statuteName IS NULL AND actionKey IS NULL
           AND decision IS NULL AND rationale IS NULL
           AND ruledBy IS NULL AND ruledAt IS NULL AND rulingFactId IS NULL
           AND consumedAt IS NULL AND parkWakeId IS NULL
           AND lineageRung IS NULL AND effortGeneration IS NULL AND deadlineWakeId IS NULL
           AND options IS NULL
           AND status IN ('open','answered','withdrawn')
           AND (status = 'answered') = (answer IS NOT NULL)
           AND (answer IS NULL) = (answeredBy IS NULL)
           AND (answer IS NULL) = (answeredAt IS NULL))
        ),
        CHECK (kind = 'agent' OR (askedOfRole IS NULL AND answer IS NULL AND
                                  answeredBy IS NULL AND answeredAt IS NULL AND
                                  status <> 'answered'))
      );
      CREATE INDEX IF NOT EXISTS decision_requests_owner
        ON decision_requests (ownerUserId, status);
      CREATE INDEX IF NOT EXISTS decision_requests_key
        ON decision_requests (raiserId, statuteName, actionKey);
      CREATE UNIQUE INDEX IF NOT EXISTS decision_requests_one_open
        ON decision_requests (raiserId, statuteName, actionKey)
        WHERE kind = 'statute' AND status = 'open';
      CREATE UNIQUE INDEX IF NOT EXISTS decision_requests_effort_generation
        ON decision_requests (assignmentId, effortGeneration) WHERE kind = 'effort';
      CREATE INDEX IF NOT EXISTS decision_requests_asked
        ON decision_requests (expecterSessionKey, status) WHERE kind = 'agent';
      """)

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end

    assert error.message =~ "coordination-fabric-v1-phase1"
    assert error.message =~ "coordination-fabric-v1-phase1-v6"
    assert error.message =~ "no migration"

    # It REFUSED — it did not repair or relax the constraint in place.
    assert {:ok, [[ddl]]} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='decision_requests'"
             )

    assert ddl =~ "deadlineAt        INTEGER NOT NULL,"
    refute ddl =~ "deadlineAt IS NOT NULL"
    refute ddl =~ "deadlineAt IS NULL"
  end

  # Sol xhigh review round 3, item 2: the rebase merges wave 1 (main,
  # `coordination-fabric-classes-v2` as of `eeb5be4`) and wave 2 (this branch,
  # `coordination-fabric-v1-phase1-v2` as of `c555dda`) onto one line under a
  # brand-new stamp. Both parents' LATEST pre-merge vintage — not just the
  # oldest — must refuse by name too, or a database someone actually ran
  # between the two rounds of review boots silently against the merged build.
  # `wakes` reconstructed byte-for-byte from `git show
  # eeb5be4:lib/tightbeam/wakes.ex` (already carrying `'batcher'`, so this is
  # NOT the same shape the classes-v1 test above proves).
  test "a coordination-fabric-classes-v2 database is refused by name, never a raw error",
       %{db: db} do
    :ok =
      DB.execute(db, """
      CREATE TABLE schema_stamp (
        shape     TEXT PRIMARY KEY,
        stampedAt INTEGER NOT NULL
      );
      INSERT INTO schema_stamp (shape, stampedAt) VALUES ('coordination-fabric-classes-v2', 1);
      CREATE TABLE wakes (
        wakeId     TEXT PRIMARY KEY,
        sessionKey TEXT NOT NULL,
        targetRole TEXT,
        origin     TEXT NOT NULL,
        prompt     TEXT,
        consumer   TEXT NOT NULL DEFAULT 'prompt',
        dueAt      INTEGER NOT NULL,
        state      TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','fired','canceled')),
        createdAt  INTEGER NOT NULL,
        firedAt    INTEGER,
        reresolve  TEXT NULL CHECK (reresolve IN ('lineage')),
        reresolveSeed TEXT NULL,
        reresolveRung INTEGER NULL,
        conditionKind TEXT NULL,
        conditionScope TEXT NULL,
        conditionAfterId INTEGER NULL,
        firedBy TEXT NULL CHECK (firedBy IN ('condition','fallback')),
        creatorSessionKey TEXT NULL,
        rumination INTEGER NOT NULL DEFAULT 0,
        work_item_id TEXT,
        assignmentId TEXT,
        canceledAt INTEGER,
        targetGate INTEGER NOT NULL DEFAULT 1,
        class TEXT,
        classElection TEXT CHECK (classElection IN ('sender','classifier','batcher')),
        deliveryRule TEXT,
        digest INTEGER NOT NULL DEFAULT 0 CHECK (digest IN (0,1)),
        summon INTEGER NOT NULL DEFAULT 0 CHECK (summon IN (0,1)),
        CHECK (consumer != 'prompt' OR prompt IS NOT NULL),
        CHECK ((class IS NULL) = (classElection IS NULL)),
        CHECK (digest = 0 OR class IS NOT NULL)
      );
      """)

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end

    assert error.message =~ "coordination-fabric-classes-v2"
    assert error.message =~ "coordination-fabric-v1-phase1-v6"
    assert error.message =~ "no migration"

    # It REFUSED — the merged build's decision_requests columns were never
    # even attempted against this database.
    refute table?(db, "decision_requests")

    assert {:ok, [[ddl]]} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='wakes'"
             )

    assert ddl =~ "classElection IN ('sender','classifier','batcher')"
  end

  # The branch's LATEST pre-merge vintage. `decision_requests` reconstructed
  # byte-for-byte from `git show b2b81df:lib/tightbeam/escalation.ex`
  # (`c555dda`'s content post-rebase) — nullable `deadlineAt`, with the
  # explicit per-arm `IS NOT NULL`/`IS NULL` clauses round 2 added.
  test "a coordination-fabric-v1-phase1-v2 database is refused by name, never a raw error",
       %{db: db} do
    :ok =
      DB.execute(db, """
      CREATE TABLE schema_stamp (
        shape     TEXT PRIMARY KEY,
        stampedAt INTEGER NOT NULL
      );
      INSERT INTO schema_stamp (shape, stampedAt) VALUES ('coordination-fabric-v1-phase1-v2', 1);
      CREATE TABLE IF NOT EXISTS decision_requests (
        id                TEXT PRIMARY KEY,
        kind              TEXT NOT NULL DEFAULT 'statute' CHECK (kind IN ('statute','effort','agent')),
        raiserId          TEXT NOT NULL,
        raiserSessionKey  TEXT,
        ownerUserId       TEXT NOT NULL,
        assignmentId      TEXT,
        expecterSessionKey TEXT,
        expecterUserId    TEXT,
        lineageRung       INTEGER,
        effortGeneration  INTEGER,
        deadlineWakeId    TEXT,
        raisedAt          INTEGER NOT NULL,
        deadlineAt        INTEGER,
        statuteName       TEXT,
        actionKey         TEXT,
        question          TEXT NOT NULL,
        options           TEXT,
        context           TEXT NOT NULL,
        status            TEXT NOT NULL CHECK (status IN ('open','ruled','consumed','withdrawn','superseded','answered')),
        decision          TEXT,
        rationale         TEXT,
        ruledBy           TEXT,
        ruledAt           INTEGER,
        rulingFactId      INTEGER,
        consumedAt        INTEGER,
        parkWakeId        TEXT,
        withdrawnBy       TEXT,
        withdrawnReason   TEXT,
        withdrawnAt       INTEGER,
        askedOfRole       TEXT,
        answer            TEXT,
        answeredBy        TEXT,
        answeredAt        INTEGER,
        CHECK (
          (kind = 'statute' AND statuteName IS NOT NULL AND actionKey IS NOT NULL
           AND expecterSessionKey IS NULL AND expecterUserId IS NULL
           AND lineageRung IS NULL AND effortGeneration IS NULL AND deadlineWakeId IS NULL
           AND deadlineAt IS NOT NULL
           AND (decision IS NULL OR decision IN ('allow','deny','waived')))
          OR
          (kind = 'effort' AND raiserId = 'process:tightbeam'
           AND raiserSessionKey IS NULL
           AND statuteName IS NULL AND actionKey IS NULL AND assignmentId IS NOT NULL
           AND ((expecterSessionKey IS NOT NULL) != (expecterUserId IS NOT NULL))
           AND lineageRung IS NOT NULL AND effortGeneration IS NOT NULL AND deadlineWakeId IS NOT NULL
           AND deadlineAt IS NOT NULL
           AND (decision IS NULL OR decision IN ('continue','dismiss')))
          OR
          (kind = 'agent'
           AND raiserSessionKey IS NOT NULL AND raiserId = 'session:' || raiserSessionKey
           AND expecterSessionKey IS NOT NULL AND expecterUserId IS NOT NULL
           AND statuteName IS NULL AND actionKey IS NULL
           AND decision IS NULL AND rationale IS NULL
           AND ruledBy IS NULL AND ruledAt IS NULL AND rulingFactId IS NULL
           AND consumedAt IS NULL AND parkWakeId IS NULL
           AND lineageRung IS NULL AND effortGeneration IS NULL AND deadlineWakeId IS NULL
           AND deadlineAt IS NULL
           AND options IS NULL
           AND status IN ('open','answered','withdrawn')
           AND (status = 'answered') = (answer IS NOT NULL)
           AND (answer IS NULL) = (answeredBy IS NULL)
           AND (answer IS NULL) = (answeredAt IS NULL))
        ),
        CHECK (kind = 'agent' OR (askedOfRole IS NULL AND answer IS NULL AND
                                  answeredBy IS NULL AND answeredAt IS NULL AND
                                  status <> 'answered'))
      );
      CREATE INDEX IF NOT EXISTS decision_requests_owner
        ON decision_requests (ownerUserId, status);
      CREATE INDEX IF NOT EXISTS decision_requests_key
        ON decision_requests (raiserId, statuteName, actionKey);
      CREATE UNIQUE INDEX IF NOT EXISTS decision_requests_one_open
        ON decision_requests (raiserId, statuteName, actionKey)
        WHERE kind = 'statute' AND status = 'open';
      CREATE UNIQUE INDEX IF NOT EXISTS decision_requests_effort_generation
        ON decision_requests (assignmentId, effortGeneration) WHERE kind = 'effort';
      CREATE INDEX IF NOT EXISTS decision_requests_asked
        ON decision_requests (expecterSessionKey, status) WHERE kind = 'agent';
      """)

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end

    assert error.message =~ "coordination-fabric-v1-phase1-v2"
    assert error.message =~ "coordination-fabric-v1-phase1-v6"
    assert error.message =~ "no migration"

    # It REFUSED — the merged build's wakes class/delivery columns were never
    # even attempted against this database.
    refute table?(db, "wakes")

    assert {:ok, [[ddl]]} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='decision_requests'"
             )

    assert ddl =~ "deadlineAt        INTEGER,"
    assert ddl =~ "deadlineAt IS NOT NULL"
    assert ddl =~ "deadlineAt IS NULL"
  end

  test "a phase1-v3 database is refused before return columns or status are used", %{db: db} do
    :ok =
      DB.execute(db, """
      CREATE TABLE schema_stamp (
        shape TEXT PRIMARY KEY,
        stampedAt INTEGER NOT NULL
      );
      INSERT INTO schema_stamp (shape, stampedAt)
      VALUES ('coordination-fabric-v1-phase1-v3', 1);
      CREATE TABLE decision_requests (
        id TEXT PRIMARY KEY,
        status TEXT NOT NULL CHECK (
          status IN ('open','ruled','consumed','withdrawn','superseded','answered')
        ),
        answeredAt INTEGER
      );
      """)

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end

    assert error.message =~ "coordination-fabric-v1-phase1-v3"
    assert error.message =~ "coordination-fabric-v1-phase1-v6"
    assert error.message =~ "no migration"

    assert {:ok, [[ddl]]} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='decision_requests'"
             )

    refute ddl =~ "returned"
    assert table_columns(db, "decision_requests") == ~w(id status answeredAt)
  end

  defp session(db, key, owner, opts \\ []) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: Keyword.get(opts, :kind, "custom"),
      is_built_in: Keyword.get(opts, :kind) == "main",
      owner_user_id: owner,
      origin: "user:#{owner}",
      spawned_by: Keyword.get(opts, :spawned_by),
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp downgrade_to_previous_shape(db) do
    :ok = DB.execute(db, "DROP TRIGGER users_gateway_owned_insert")
    :ok = DB.execute(db, "DROP TABLE cold_start_receipts")
    :ok = DB.execute(db, "ALTER TABLE users DROP COLUMN creationKind")
    :ok = DB.execute(db, "ALTER TABLE sessions DROP COLUMN operationalParent")

    {:ok, _} =
      DB.query(
        db,
        "UPDATE schema_stamp SET shape='coordination-fabric-v1-phase1-v4', stampedAt=1"
      )

    :ok
  end

  defp table?(db, name) do
    {:ok, rows} =
      DB.query(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1", [name])

    rows == [[1]]
  end

  defp table_columns(db, name) do
    Enum.map(table_info(db, name), fn [_cid, column | _] -> column end)
  end

  defp table_info(db, name) do
    {:ok, rows} = DB.query(db, "PRAGMA table_info(#{name})")
    rows
  end

  defp owned_activation_objects(db) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT name FROM sqlite_master
        WHERE name IN (
          'supervision_entitlements',
          'supervision_progress_absorptions',
          'supervision_liveness_sidecar',
          'wake_cancellations',
          'supervision_liveness_epoch',
          'supervision_progress_assignment',
          'supervision_liveness_assignment',
          'supervision_liveness_pending_controller',
          'supervision_liveness_retirement_dedupe',
          'wakes_cancellation_state',
          'wake_cancellations_pending_insert',
          'wakes_typed_cancellation_required',
          'supervision_liveness_retirement_immutable_update',
          'supervision_liveness_retirement_immutable_delete',
          'supervision_liveness_migrations',
          'supervision_liveness_receipt_state',
          'supervision_liveness_receipts',
          'supervision_liveness_receipts_assignment',
          'supervision_liveness_checkpoint_bindings',
          'supervision_checkpoint_binding_insert_coherent',
          'supervision_liveness_sidecar_insert_coherent',
          'supervision_pending_controller_sidecar_update',
          'supervision_pending_controller_sidecar_delete',
          'supervision_pending_controller_wake_identity_immutable',
          'supervision_lineage_fire_requires_sidecar',
          'supervision_fired_lineage_sidecar_required_delete',
          'supervision_fired_lineage_sidecar_identity_immutable',
          'supervision_fired_lineage_turn_immutable_update',
          'supervision_fired_lineage_turn_immutable_delete'
        )
        ORDER BY name
        """
      )

    List.flatten(rows)
  end

  defp drop_liveness_activation(db) do
    :ok =
      DB.execute(db, """
      DROP TRIGGER IF EXISTS supervision_liveness_retirement_immutable_delete;
      DROP TRIGGER IF EXISTS supervision_liveness_retirement_immutable_update;
      DROP TRIGGER IF EXISTS supervision_pending_controller_wake_identity_immutable;
      DROP TRIGGER IF EXISTS supervision_pending_controller_sidecar_delete;
      DROP TRIGGER IF EXISTS supervision_pending_controller_sidecar_update;
      DROP TRIGGER IF EXISTS supervision_liveness_sidecar_insert_coherent;
      DROP TRIGGER IF EXISTS supervision_checkpoint_binding_insert_coherent;
      DROP TRIGGER IF EXISTS supervision_fired_lineage_turn_immutable_delete;
      DROP TRIGGER IF EXISTS supervision_fired_lineage_turn_immutable_update;
      DROP TRIGGER IF EXISTS supervision_fired_lineage_sidecar_identity_immutable;
      DROP TRIGGER IF EXISTS supervision_fired_lineage_sidecar_required_delete;
      DROP TRIGGER IF EXISTS supervision_lineage_fire_requires_sidecar;
      DROP TRIGGER IF EXISTS wakes_typed_cancellation_required;
      DROP TRIGGER IF EXISTS wake_cancellations_pending_insert;
      DROP TABLE IF EXISTS wake_cancellations;
      DROP TABLE IF EXISTS supervision_liveness_sidecar;
      DROP TABLE IF EXISTS supervision_progress_absorptions;
      DROP TABLE IF EXISTS supervision_liveness_receipt_state;
      DROP TABLE IF EXISTS supervision_liveness_receipts;
      DROP TABLE IF EXISTS supervision_liveness_checkpoint_bindings;
      DROP TABLE IF EXISTS supervision_entitlements;
      DROP TABLE IF EXISTS supervision_liveness_epoch;
      DROP TABLE IF EXISTS supervision_liveness_migrations;
      DROP INDEX IF EXISTS wakes_cancellation_state;
      """)
  end
end
