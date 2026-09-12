defmodule Tightbeam.SchemaShapeRuntimeFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias Tightbeam.{DB, Schema}
  @shape "session-reparent-v1-019"
  @row_driven_rules_shape "row-driven-rules-v1-019"
  @identity_render_stamp_previous_shape "effort-request-exit-v1-019"
  @effort_request_exit_previous_shape "notice-batching-v1-019"
  @notice_batching_pre_liveness_shape "notice-batching-pre-liveness-v1-019"
  @terminal_decision_shape "terminal-operator-decision-parity-v1"
  @operator_decision_shape "operator-decision-requests-v1"
  @model_identity_shape "model-identity-v1"
  @be61_shape "model-identity-message-envelope-v2"

  # Captured from Schema.ensure_all/1 at be61cfc98df6b18c0cc280adeca42cba3fbf14b5.
  # Keep the old table exact: its missing ruledViaSessionKey column is why this
  # build must refuse the old stamp before it serves a decision-request read.
  @be61_decision_requests_ddl """
  CREATE TABLE decision_requests (
    id                TEXT PRIMARY KEY,
    kind              TEXT NOT NULL DEFAULT 'statute' CHECK (kind IN ('statute','effort')),
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
    status            TEXT NOT NULL CHECK (status IN ('open','ruled','consumed','withdrawn','superseded')),
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
    )
  )
  """

  @model_identity_messages_ddl """
  CREATE TABLE messages (
    seq                    INTEGER PRIMARY KEY AUTOINCREMENT,
    id                     TEXT NOT NULL UNIQUE,
    sessionKey             TEXT NOT NULL,
    role                   TEXT NOT NULL CHECK (role IN ('user','assistant')),
    content                TEXT NOT NULL,
    timestamp              INTEGER NOT NULL,
    sender                 TEXT,
    deviceId               TEXT,
    clientMessageId        TEXT,
    replyToMessageId       TEXT,
    replyToClientMessageId TEXT,
    llmVisibleMessageId    TEXT NOT NULL,
    attachments            TEXT NOT NULL DEFAULT '[]',
    attentionTier          INTEGER NOT NULL DEFAULT 0
  )
  """

  # Exact pre-A-R4 tables. Migration fixtures begin from a current in-memory
  # database, so they must remove the current nullable columns before assigning
  # an older shape stamp. The stamp remains the production migration authority.
  @pre_row_driven_artifacts_ddl """
  CREATE TABLE artifacts (
    artifactId TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('spec','report','doc','data','other')),
    title TEXT NOT NULL,
    description TEXT,
    createdBySession TEXT NOT NULL REFERENCES sessions(sessionKey),
    workItemId TEXT NOT NULL REFERENCES work_items(id),
    parentSession TEXT REFERENCES sessions(sessionKey),
    originPath TEXT NOT NULL,
    contentSha256 TEXT,
    recordedMessageId TEXT REFERENCES messages(id),
    recordedTurnEvidence TEXT NOT NULL DEFAULT 'none'
      CHECK (recordedTurnEvidence IN ('tool-call-observed','session-concurrent','none')),
    state TEXT NOT NULL DEFAULT 'in-workspace'
      CHECK (state IN ('in-workspace','archived','released')),
    home TEXT,
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL,
    CHECK ((state = 'archived') = (home IS NOT NULL))
  )
  """

  @pre_row_driven_attests_ddl """
  CREATE TABLE attests (
    id TEXT PRIMARY KEY,
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    kind TEXT NOT NULL CHECK(kind IN ('progress', 'completion', 'surrender', 'verdict')),
    verdictKind TEXT NULL,
    note TEXT NULL CHECK(note IS NULL OR length(trim(note)) BETWEEN 1 AND 2000),
    bySession TEXT NULL REFERENCES sessions(sessionKey),
    byUser TEXT NULL REFERENCES users(userId),
    producer TEXT NULL,
    producerCommand TEXT NULL,
    byHarness TEXT NULL,
    byProvider TEXT NULL,
    commitRefs TEXT NULL,
    ts INTEGER NOT NULL,
    CHECK(
      (kind IN ('progress', 'completion', 'surrender') AND bySession IS NOT NULL AND
       byUser IS NULL AND verdictKind IS NULL)
      OR
      (kind = 'verdict' AND verdictKind IS NOT NULL AND
       ((bySession IS NOT NULL) != (byUser IS NOT NULL)))
    ),
    CHECK(producer IS NULL OR kind = 'verdict'),
    CHECK(producerCommand IS NULL OR producer IS NOT NULL),
    CHECK(byHarness IS NULL OR kind = 'verdict'),
    CHECK(byProvider IS NULL OR kind = 'verdict')
  )
  """

  # Historical tests start from captured pre-O2 bytes, not a relabeled current bootstrap.
  defp load_admission_fixture(db) do
    fixture = File.read!(Path.join(Path.expand("..", __DIR__), "fixtures/o2_admission_v1.sql"))

    assert Base.encode16(:crypto.hash(:sha256, fixture), case: :lower) ==
             "ad7de70a2a921045e5cb78075e3e87d08e821929b86b81b8ef5c479b3292af1e"

    :ok = DB.execute(db, fixture)
    :ok = DB.execute(db, "PRAGMA foreign_keys=ON")

    assert {:ok, [["row-driven-admission-v1-019"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    refute "noticeState" in table_columns(db, "rail_remedy_episodes")
    :ok
  end

  def run!(proof, opts) do
    tmp = Path.join(System.tmp_dir!(), "schema-shape-cold-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    tmp = Tightbeam.LiveBaseAdmission.canonical!(tmp)
    prepared = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "schema_shape_runtime.exs")

    try do
      {output, status} =
        System.cmd(prepared.executable, prepared.args ++ [proof, JSON.encode!(opts)],
          env: prepared.env,
          stderr_to_stdout: true
        )

      File.write!(Path.join(tmp, "runtime.log"), output)
      assert status == 0, output
      assert output =~ "schema-shape-cold: ok", output
    after
      :ok
    end
  end

  def proof!("activation", base, opts) do
    activated = opts.activated
    boundary = opts.boundary
    unique = System.unique_integer([:positive])
    path = Path.join(base, "state.db")
    first = :"activation_before_#{unique}"
    second = :"activation_after_#{unique}"

    {:ok, first_pid} = start_db!(path, first)
    assert :ok = load_admission_fixture(first)
    downgrade_row_driven_rules(first)
    unless activated, do: drop_liveness_activation(first)
    assert :ok = DB.execute(first, "ALTER TABLE sessions DROP COLUMN identityGuidanceDigest")
    assert :ok = DB.execute(first, "ALTER TABLE sessions DROP COLUMN identityRenderContract")

    predecessor =
      if activated,
        do: @identity_render_stamp_previous_shape,
        else: @notice_batching_pre_liveness_shape

    assert {:ok, _} = DB.query(first, "UPDATE schema_stamp SET shape=?1", [predecessor])

    {:ok, interposer} =
      Tightbeam.SchemaShapeTest.FailingDb.start_link(
        db: first,
        fragment: "SELECT shape FROM schema_stamp",
        skip: boundary
      )

    assert_raise CaseClauseError, fn -> Schema.ensure_all(interposer) end

    expected =
      Enum.at(
        if(activated,
          do: [
            "identity-universal-root-render-v1-019",
            "row-driven-rules-v1-019",
            "row-driven-waits-v1-019"
          ],
          else: [
            "identity-universal-root-render-pre-liveness-v1-019",
            "row-driven-rules-pre-liveness-v1-019",
            "row-driven-waits-pre-liveness-v1-019"
          ]
        ),
        boundary - 1
      )

    assert {:ok, [[^expected]]} = DB.query(first, "SELECT shape FROM schema_stamp")
    assert table?(first, "supervision_liveness_sidecar") == activated
    :ok = GenServer.stop(interposer)
    :ok = stop_db!(first_pid)

    {:ok, second_pid} = start_db!(path, second)
    assert :ok = Schema.ensure_all(second)
    assert {:ok, [[@shape]]} = DB.query(second, "SELECT shape FROM schema_stamp")
    assert table?(second, "supervision_liveness_sidecar")
    assert {:ok, []} = DB.query(second, "PRAGMA foreign_key_check")
    assert :ok = Schema.ensure_all(second)
    :ok = stop_db!(second_pid)
  end

  def proof!("operator", base, opts) do
    unique = System.unique_integer([:positive])
    path = Path.join(base, "state.db")
    first = :"terminal_parity_before_#{unique}"
    second = :"terminal_parity_after_#{unique}"

    {:ok, first_pid} = start_db!(path, first)
    assert :ok = load_admission_fixture(first)
    downgrade_row_driven_rules(first)

    :ok =
      DB.execute(first, """
      DROP TRIGGER decision_requests_terminal_insert_guard;
      DROP TRIGGER decision_requests_terminal_update_guard;
      DROP TABLE decision_request_integrity_evidence;
      DROP TABLE decision_request_terminal_epoch;
      ALTER TABLE decision_requests DROP COLUMN ruledViaPrincipal;
      ALTER TABLE decision_requests DROP COLUMN ruledViaSessionState;
      ALTER TABLE sessions DROP COLUMN identityGuidanceDigest;
      ALTER TABLE sessions DROP COLUMN identityRenderContract;
      UPDATE schema_stamp SET shape = '#{@operator_decision_shape}', stampedAt = 1;
      """)

    :ok = stop_db!(first_pid)

    {:ok, second_pid} = start_db!(path, second)
    assert :ok = Schema.ensure_all(second)
    assert {:ok, [[@shape]]} = DB.query(second, "SELECT shape FROM schema_stamp")

    assert {:ok, [[@terminal_decision_shape, 0]]} =
             DB.query(
               second,
               "SELECT schemaVersion, legacyRulingFactMaxId FROM decision_request_terminal_epoch WHERE id=0"
             )

    :ok = stop_db!(second_pid)
  end

  def proof!("d483", base, opts) do
    unique = System.unique_integer([:positive])
    path = Path.join(base, "state.db")
    first = :"d483_terminal_liveness_before_#{unique}"
    second = :"d483_terminal_liveness_after_#{unique}"

    fixture =
      Path.expand("..", __DIR__)
      |> Path.join("fixtures/d483a9c8_terminal_liveness.sqlite3.gz.b64")
      |> File.read!()
      |> String.replace(~r/\s+/u, "")
      |> Base.decode64!()
      |> :zlib.gunzip()

    assert Base.encode16(:crypto.hash(:sha256, fixture), case: :lower) ==
             "593308eb122ea1140a592b667afea41c501f99003949025ad29fea407d74eeb0"

    File.mkdir_p!(base)
    Process.put(:expected_schema, @terminal_decision_shape)
    File.write!(path, fixture)

    {:ok, first_pid} = start_db!(path, first)
    assert {:ok, [[@terminal_decision_shape]]} = DB.query(first, "SELECT shape FROM schema_stamp")
    assert table?(first, "wake_cancellations")

    {:ok, interposer} =
      Tightbeam.SchemaShapeTest.FailingDb.start_link(
        db: first,
        fragment: "SELECT shape FROM schema_stamp",
        skip: 1
      )

    assert_raise CaseClauseError, fn -> Schema.ensure_all(interposer) end

    assert {:ok, [[@effort_request_exit_previous_shape]]} =
             DB.query(first, "SELECT shape FROM schema_stamp")

    refute "waitMode" in table_columns(first, "wakes")

    assert {:ok, []} =
             DB.query(
               first,
               "SELECT name FROM sqlite_master WHERE name='supervision_liveness_sidecar_insert_coherent'"
             )

    :ok = GenServer.stop(interposer)
    :ok = stop_db!(first_pid)

    {:ok, second_pid} = start_db!(path, second)
    assert :ok = Schema.ensure_all(second)
    assert {:ok, [[@shape]]} = DB.query(second, "SELECT shape FROM schema_stamp")
    assert "identityGuidanceDigest" in table_columns(second, "sessions")
    assert "waitMode" in table_columns(second, "wakes")

    assert object_sql(second, "trigger", "supervision_liveness_sidecar_insert_coherent") =~
             "coherentpendingwake"

    assert object_sql(second, "trigger", "wakes_typed_cancellation_required") =~
             "pendingwakecancellationrequirestypedprovenance"

    :ok = stop_db!(second_pid)
  end

  def proof!("coverage", base, opts) do
    activated = opts.activated
    unique = System.unique_integer([:positive])
    path = Path.join(base, "state.db")
    first = :"admission_before_#{unique}"
    second = :"admission_after_#{unique}"
    {:ok, first_pid} = start_db!(path, first)
    assert :ok = load_admission_fixture(first)

    # Exact trigger SQL from accepted G-C 32911d0c; only heredoc indentation removed.
    prior =
      File.read!(
        Path.join(Path.expand("..", __DIR__), "fixtures/row_wakes/admission-trigger-32911d0c.sql")
      )

    assert Base.encode16(:crypto.hash(:sha256, prior), case: :lower) ==
             "1b87873ea6360d8954d27f1b6c7a79815a9e617d80b4e4ed62d4f6dfef68c6a0"

    assert :ok = DB.execute(first, "DROP TRIGGER supervision_liveness_sidecar_insert_coherent")
    assert :ok = DB.execute(first, prior)

    assert object_sql(first, "trigger", "supervision_liveness_sidecar_insert_coherent") =~
             "w.creatorsessionkey=a.holderkey"

    unless activated, do: drop_liveness_activation(first)

    predecessor =
      if activated,
        do: "row-driven-coverage-v1-019",
        else: "row-driven-coverage-pre-liveness-v1-019"

    assert {:ok, _} = DB.query(first, "UPDATE schema_stamp SET shape=?1", [predecessor])
    :ok = stop_db!(first_pid)

    {:ok, second_pid} = start_db!(path, second)
    assert :ok = Schema.ensure_all(second)
    assert {:ok, [[@shape]]} = DB.query(second, "SELECT shape FROM schema_stamp")
    trigger = object_sql(second, "trigger", "supervision_liveness_sidecar_insert_coherent")
    assert trigger =~ "withrecursivelineage"
    refute trigger =~ "w.creatorsessionkey=a.holderkey"
    assert trigger =~ "t.sessionkey=w.creatorsessionkey"
    assert :ok = Schema.ensure_all(second)

    assert object_sql(second, "trigger", "supervision_liveness_sidecar_insert_coherent") ==
             trigger

    :ok = stop_db!(second_pid)
  end

  defp start_db!(path, name) do
    locks = Process.get(:schema_locks)
    base = Path.dirname(path)

    lock_path =
      Path.join(locks, Base.encode16(:crypto.hash(:sha256, base), case: :lower) <> ".lock")

    await_lock!(lock_path, 200)
    inputs = [lock_dir: locks]

    inputs =
      if File.exists?(path) and not File.exists?(Path.join(base, "build-owner.json")) do
        manifest =
          File.read!(Path.join(Application.app_dir(:tightbeam), "build-manifest.json"))
          |> JSON.decode!()

        transition =
          JSON.encode!(%{
            "base" => base,
            "source" => "unmarked",
            "target" => manifest["buildIdentity"],
            "expectedSchema" => Process.get(:expected_schema)
          })

        Keyword.put(inputs, :transition, transition)
      else
        inputs
      end

    DB.start_link(path: path, name: name, guard_inputs: inputs)
  end

  defp stop_db!(pid) do
    {:ok, [[shape]]} = DB.query(pid, "SELECT shape FROM schema_stamp")
    Process.put(:expected_schema, shape)
    GenServer.stop(pid)
  end

  defp await_lock!(path, tries) do
    case Tightbeam.LiveBaseLock.acquire(path) do
      {:ok, lock} ->
        :ok = Tightbeam.LiveBaseLock.release(lock)

      {:error, :lock_busy} when tries > 0 ->
        Process.sleep(10)
        await_lock!(path, tries - 1)

      other ->
        raise "schema fixture lock: #{inspect(other)}"
    end
  end

  defp table?(db, name) do
    {:ok, rows} =
      DB.query(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1", [name])

    rows == [[1]]
  end

  defp downgrade_decision_requests_to_model_identity(db) do
    downgrade_row_driven_rules(db)

    :ok =
      DB.execute(db, """
      DROP INDEX decision_requests_owner;
      DROP INDEX decision_requests_key;
      DROP INDEX decision_requests_one_open;
      DROP INDEX decision_requests_effort_generation;
      DROP INDEX decision_requests_operator_open;
      DROP TABLE decision_requests;
      #{@be61_decision_requests_ddl};
      CREATE INDEX decision_requests_owner
        ON decision_requests (ownerUserId, status);
      CREATE INDEX decision_requests_key
        ON decision_requests (raiserId, statuteName, actionKey);
      CREATE UNIQUE INDEX decision_requests_one_open
        ON decision_requests (raiserId, statuteName, actionKey)
        WHERE kind = 'statute' AND status = 'open';
      CREATE UNIQUE INDEX decision_requests_effort_generation
        ON decision_requests (assignmentId, effortGeneration) WHERE kind = 'effort';
      DROP INDEX messages_session;
      DROP INDEX messages_client_dedupe;
      DROP TABLE messages;
      #{@model_identity_messages_ddl};
      CREATE INDEX messages_session ON messages (sessionKey, seq);
      CREATE UNIQUE INDEX messages_client_dedupe
        ON messages (sessionKey, deviceId, clientMessageId)
        WHERE clientMessageId IS NOT NULL AND deviceId IS NOT NULL;
      ALTER TABLE sessions DROP COLUMN identityGuidanceDigest;
      ALTER TABLE sessions DROP COLUMN identityRenderContract;
      UPDATE schema_stamp SET shape = '#{@model_identity_shape}', stampedAt = 1;
      """)

    :ok
  end

  defp downgrade_row_driven_rules(db) do
    downgrade_row_driven_waits(db)
    :ok = DB.execute(db, "PRAGMA foreign_keys = OFF")

    try do
      :ok =
        DB.execute(db, """
        DROP TABLE attests;
        DROP INDEX artifacts_producer;
        DROP INDEX artifacts_work_item;
        DROP INDEX artifacts_created_by_session;
        DROP INDEX artifacts_recorded_message;
        DROP TABLE artifacts;
        #{@pre_row_driven_artifacts_ddl};
        CREATE INDEX artifacts_work_item ON artifacts (workItemId);
        CREATE INDEX artifacts_created_by_session ON artifacts (createdBySession);
        CREATE INDEX artifacts_recorded_message ON artifacts (recordedMessageId);
        #{@pre_row_driven_attests_ddl};
        """)
    after
      :ok = DB.execute(db, "PRAGMA foreign_keys = ON")
    end
  end

  defp downgrade_row_driven_waits(db) do
    :ok = DB.execute(db, "PRAGMA foreign_keys = OFF")

    try do
      # Captured verbatim from the reviewed G-B source, schema.ex:292 and :688.
      prior_sidecar =
        File.read!(
          Path.join(Path.expand("..", __DIR__), "fixtures/row_wakes/sidecar-40bd6fc1.sql")
        )

      :ok =
        DB.execute(db, """
        CREATE TEMP TABLE gc_sidecar_rows AS SELECT * FROM supervision_liveness_sidecar;
        DROP TABLE supervision_liveness_sidecar;
        #{prior_sidecar}
        DROP TRIGGER supervision_liveness_sidecar_insert_coherent;
        INSERT INTO supervision_liveness_sidecar SELECT * FROM gc_sidecar_rows;
        DROP TABLE gc_sidecar_rows;
        """)

      :ok =
        DB.execute(db, """
        ALTER TABLE effort_checkin_generations DROP COLUMN reliefStartedAt;
        ALTER TABLE effort_checkin_generations DROP COLUMN reliefExcludedMs;
        DROP INDEX wakes_wait_recognition;
        DROP INDEX condition_facts_owner_match;
        ALTER TABLE condition_facts DROP COLUMN ownerUserId;
        ALTER TABLE wakes DROP COLUMN ownerUserId;
        ALTER TABLE wakes DROP COLUMN obligationRef;
        ALTER TABLE wakes DROP COLUMN waitMode;
        ALTER TABLE wakes DROP COLUMN predicate;
        ALTER TABLE wakes DROP COLUMN resolverKind;
        ALTER TABLE wakes DROP COLUMN resolverId;
        ALTER TABLE wakes DROP COLUMN resolverHolder;
        ALTER TABLE wakes DROP COLUMN resolverAddressee;
        ALTER TABLE wakes DROP COLUMN necessity;
        ALTER TABLE wakes DROP COLUMN verificationAssignmentId;
        ALTER TABLE wakes DROP COLUMN verificationHolderKey;
        ALTER TABLE wakes DROP COLUMN selectedPolicyName;
        ALTER TABLE wakes DROP COLUMN verificationState;
        ALTER TABLE wakes DROP COLUMN verificationAttestId;
        ALTER TABLE wakes DROP COLUMN verificationNoticeWakeId;
        ALTER TABLE wakes DROP COLUMN originatingTurnSeq;
        ALTER TABLE wakes DROP COLUMN recognitionAt;
        ALTER TABLE wakes DROP COLUMN recognitionPath;
        ALTER TABLE wakes DROP COLUMN recognitionReason;
        ALTER TABLE wakes DROP COLUMN recognitionEvidence;
        ALTER TABLE wakes DROP COLUMN recognitionDisposition;
        ALTER TABLE wakes DROP COLUMN recognitionTransition;
        ALTER TABLE attests DROP COLUMN waitId;
        UPDATE schema_stamp SET shape='#{@row_driven_rules_shape}', stampedAt=1;
        """)
    after
      :ok = DB.execute(db, "PRAGMA foreign_keys = ON")
    end
  end

  defp downgrade_wakes_to_terminal_decision(db) do
    :ok = DB.execute(db, "PRAGMA foreign_keys = OFF")

    try do
      :ok =
        DB.execute(db, """
        DROP TABLE notice_batch_members;
        DROP TABLE notice_batches;
        DROP TABLE notice_delivery_policies;
        DROP TABLE notice_batching_lane_policies;
        DROP TABLE admin_projection_versions;
        DROP INDEX wakes_due;
        DROP INDEX wakes_delivery;
        DROP INDEX wakes_condition;
        DROP TABLE wakes;
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
          CHECK (consumer != 'prompt' OR prompt IS NOT NULL)
        );
        CREATE INDEX wakes_due ON wakes (state, dueAt);
        CREATE INDEX wakes_condition ON wakes (state, conditionKind, conditionScope);
        ALTER TABLE sessions DROP COLUMN identityGuidanceDigest;
        ALTER TABLE sessions DROP COLUMN identityRenderContract;
        UPDATE schema_stamp SET shape = '#{@terminal_decision_shape}', stampedAt = 1;
        """)
    after
      :ok = DB.execute(db, "PRAGMA foreign_keys = ON")
    end
  end

  defp legacy_wake_columns do
    """
    wakeId, sessionKey, targetRole, origin, prompt, consumer, dueAt, state,
    createdAt, firedAt, reresolve, reresolveSeed, reresolveRung,
    conditionKind, conditionScope, conditionAfterId, firedBy,
    creatorSessionKey, rumination, work_item_id, assignmentId, canceledAt,
    targetGate
    """
  end

  defp model_identity_request_columns do
    """
    id, kind, raiserId, raiserSessionKey, ownerUserId, assignmentId,
    expecterSessionKey, expecterUserId, lineageRung, effortGeneration,
    deadlineWakeId, raisedAt, deadlineAt, statuteName, actionKey, question,
    options, context, status, decision, rationale, ruledBy, ruledAt,
    rulingFactId, consumedAt, parkWakeId, withdrawnBy, withdrawnReason, withdrawnAt
    """
  end

  defp model_identity_message_columns do
    """
    seq, id, sessionKey, role, content, timestamp, sender, deviceId,
    clientMessageId, replyToMessageId, replyToClientMessageId,
    llmVisibleMessageId, attachments, attentionTier
    """
  end

  defp table_names(db, name) do
    DB.query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name=?1", [name])
  end

  defp index_count(db, name) do
    DB.query(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?1", [name])
  end

  defp object_sql(db, type, name) do
    {:ok, [[sql]]} =
      DB.query(db, "SELECT sql FROM sqlite_master WHERE type=?1 AND name=?2", [type, name])

    sql
    |> String.downcase()
    |> String.replace("\"", "")
    |> String.replace(~r/\s+/u, "")
  end

  defp table_columns(db, name) do
    {:ok, rows} = DB.query(db, "PRAGMA table_info(#{name})")
    Enum.map(rows, fn [_cid, column | _] -> column end)
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
