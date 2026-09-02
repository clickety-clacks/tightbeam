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

  alias Tightbeam.{Assignments, DB, Schema}

  @shape "identity-universal-root-render-v1-019-completion-escalation-v16"
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

  setup do
    name = :"schema_shape_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    %{db: name}
  end

  test "a fresh database is created and stamped", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    assert "executionId" in table_columns(db, "command_executions")

    assert {:ok, [[@shape]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    # Idempotent: booting twice is the ordinary case, not a shape change.
    assert :ok = Schema.ensure_all(db)

    assert {:ok, [[@shape]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, [[1, operator_index]]} =
             DB.query(
               db,
               "SELECT COUNT(*), MIN(sql) FROM sqlite_master WHERE type='index' AND name='decision_requests_operator_open'"
             )

    assert operator_index =~ "(ownerUserId, raiserId, actionKey)"
    assert operator_index =~ ~r/WHERE\s+kind\s*=\s*'operator'\s+AND\s+status\s*=\s*'open'/
  end

  test "the exact effort-request predecessor gains nullable identity render stamps", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    assert :ok = DB.execute(db, "ALTER TABLE sessions DROP COLUMN identityGuidanceDigest")
    assert :ok = DB.execute(db, "ALTER TABLE sessions DROP COLUMN identityRenderContract")

    assert {:ok, _rows} =
             DB.query(db, "UPDATE schema_stamp SET shape=?1", [
               @identity_render_stamp_previous_shape
             ])

    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[@shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    assert "identityRenderContract" in table_columns(db, "sessions")
    assert "identityGuidanceDigest" in table_columns(db, "sessions")
  end

  test "the exact pre-liveness notice stamp resumes without physical-shape inference", %{db: db} do
    assert :ok = Schema.ensure_all(db)
    drop_liveness_activation(db)
    assert :ok = DB.execute(db, "ALTER TABLE sessions DROP COLUMN identityGuidanceDigest")
    assert :ok = DB.execute(db, "ALTER TABLE sessions DROP COLUMN identityRenderContract")

    assert {:ok, _rows} =
             DB.query(db, "UPDATE schema_stamp SET shape=?1", [
               @notice_batching_pre_liveness_shape
             ])

    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[@shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    assert "identityRenderContract" in table_columns(db, "sessions")
    assert "identityGuidanceDigest" in table_columns(db, "sessions")
    assert table?(db, "wake_cancellations")
  end

  test "model-identity-v1 migrates exact requests, messages, and wakes", %{db: db} do
    :ok = Schema.ensure_all(db)
    downgrade_decision_requests_to_model_identity(db)

    :ok =
      DB.execute(db, """
      INSERT INTO decision_requests
        (id, kind, raiserId, ownerUserId, raisedAt, deadlineAt, statuteName,
         actionKey, question, context, status)
      VALUES
        ('dr_statute', 'statute', 'session:holder', 'mike', 1, 2, 'law-a',
         'action-a', 'allow?', '{}', 'open');

      INSERT INTO decision_requests
        (id, kind, raiserId, ownerUserId, assignmentId, expecterSessionKey,
         lineageRung, effortGeneration, deadlineWakeId, raisedAt, deadlineAt,
         question, context, status, decision, ruledBy, ruledAt)
      VALUES
        ('dr_effort', 'effort', 'process:tightbeam', 'mike', 'asg_a', 'holder',
         2, 3, 'w_deadline', 3, 4, 'continue?', '{}', 'ruled', 'continue',
         'user:mike', 5);

      INSERT INTO wakes
        (wakeId, sessionKey, origin, prompt, dueAt, state, createdAt, firedAt)
      VALUES
        ('w_pending', 'holder', 'process:test', 'resume', 10, 'pending', 6, NULL),
        ('w_fired', 'holder', 'process:test', 'done', 11, 'fired', 7, 12);

      INSERT INTO messages
        (seq, id, sessionKey, role, content, timestamp, sender, deviceId,
         clientMessageId, replyToMessageId, replyToClientMessageId,
         llmVisibleMessageId, attachments, attentionTier)
      VALUES
        (7, 'm_one', 'holder', 'user', 'hello', 13, 'user:mike', 'device-a',
         'client-a', NULL, NULL, 'm_one', '[{"kind":"text"}]', 1),
        (11, 'm_two', 'holder', 'assistant', 'world', 14, 'session:holder', NULL,
         NULL, 'm_one', NULL, 'm_two', '[]', 0);

      INSERT INTO users (userId, isAdmin, createdAt)
      VALUES ('mike', 1, 1);
      INSERT INTO sessions
        (sessionKey, displayName, ownerUserId, origin, archetype, harness,
         provider, model, createdAt, updatedAt)
      VALUES
        ('holder', 'holder', 'mike', 'user:mike', 'coder', 'codex', 'openai',
         'fixture-model', 1, 1);
      INSERT INTO work_items
        (id, title, ownerUserId, createdByUser, createdAt)
      VALUES ('wi_one', 'one', 'mike', 'mike', 1);
      INSERT INTO artifacts
        (artifactId, kind, title, createdBySession, workItemId, originPath,
         recordedMessageId, createdAt, updatedAt)
      VALUES
        ('art_one', 'report', 'one', 'holder', 'wi_one', '/tmp/one',
         'm_one', 1, 1);
      """)

    {:ok, decision_requests_before} =
      DB.query(
        db,
        "SELECT #{model_identity_request_columns()} FROM decision_requests ORDER BY id"
      )

    {:ok, wakes_before} =
      DB.query(db, "SELECT #{legacy_wake_columns()} FROM wakes ORDER BY wakeId")

    {:ok, messages_before} =
      DB.query(db, "SELECT #{model_identity_message_columns()} FROM messages ORDER BY seq")

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [[@shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, ^decision_requests_before} =
             DB.query(
               db,
               "SELECT #{model_identity_request_columns()} FROM decision_requests ORDER BY id"
             )

    assert {:ok, [[nil], [nil]]} =
             DB.query(db, "SELECT ruledViaSessionKey FROM decision_requests ORDER BY id")

    assert {:ok, ^wakes_before} =
             DB.query(db, "SELECT #{legacy_wake_columns()} FROM wakes ORDER BY wakeId")

    assert {:ok, [[nil, nil, nil, 0, 0], [nil, nil, nil, 0, 0]]} =
             DB.query(
               db,
               "SELECT class, classElection, deliveryRule, digest, summon FROM wakes ORDER BY wakeId"
             )

    assert {:ok, ^messages_before} =
             DB.query(db, "SELECT #{model_identity_message_columns()} FROM messages ORDER BY seq")

    assert {:ok, [[nil, nil, nil, nil], [nil, nil, nil, nil]]} =
             DB.query(
               db,
               "SELECT messageType, markerKind, markerFrom, markerTo FROM messages ORDER BY seq"
             )

    assert {:ok, []} = table_names(db, "decision_requests_model_identity_v1")
    assert {:ok, []} = table_names(db, "messages_new")
    assert {:ok, [[1]]} = index_count(db, "decision_requests_operator_open")
    assert {:ok, [["m_one"]]} = DB.query(db, "SELECT recordedMessageId FROM artifacts")
    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")

    # The rebuilt table is the same target shape a fresh 0.1.8 database gets.
    fresh = :"schema_shape_fresh_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: fresh}, id: fresh)
    assert :ok = Schema.ensure_all(fresh)

    assert object_sql(db, "table", "decision_requests") ==
             object_sql(fresh, "table", "decision_requests")

    for name <-
          ~w(decision_requests_owner decision_requests_key decision_requests_one_open decision_requests_effort_generation decision_requests_operator_open) do
      assert object_sql(db, "index", name) == object_sql(fresh, "index", name)
    end

    assert object_sql(db, "table", "messages") == object_sql(fresh, "table", "messages")

    for name <- ~w(messages_session messages_client_dedupe) do
      assert object_sql(db, "index", name) == object_sql(fresh, "index", name)
    end

    # A second boot is ordinary and leaves both commissioned populations exact.
    assert :ok = Schema.ensure_all(db)

    assert {:ok, ^decision_requests_before} =
             DB.query(
               db,
               "SELECT #{model_identity_request_columns()} FROM decision_requests ORDER BY id"
             )

    assert {:ok, ^wakes_before} =
             DB.query(db, "SELECT #{legacy_wake_columns()} FROM wakes ORDER BY wakeId")

    assert {:ok, ^messages_before} =
             DB.query(db, "SELECT #{model_identity_message_columns()} FROM messages ORDER BY seq")
  end

  test "operator-decision migration classifies the complete predecessor census once", %{db: db} do
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      DROP TRIGGER decision_requests_terminal_insert_guard;
      DROP TRIGGER decision_requests_terminal_update_guard;
      PRAGMA ignore_check_constraints=ON;
      INSERT INTO condition_facts (id,ts,kind,scope,origin) VALUES
        (41,10,'escalation-ruled','dr_00000000-0000-4000-8000-000000000006','process:tightbeam'),
        (42,11,'escalation-ruled','dr_00000000-0000-4000-8000-000000000007','process:tightbeam'),
        (43,12,'escalation-ruled','dr_00000000-0000-4000-8000-000000000002','process:tightbeam'),
        (44,13,'escalation-ruled','dr_00000000-0000-4000-8000-000000000004','process:tightbeam'),
        (45,14,'escalation-ruled','dr_00000000-0000-4000-8000-000000000001','process:tightbeam'),
        (46,15,'wrong-ruling-kind','dr_00000000-0000-4000-8000-000000000005','process:tightbeam');
      INSERT INTO lifecycle_events (ts,kind,subject,detail) VALUES
        (10,'decision_request_ruled','dr_00000000-0000-4000-8000-000000000006',NULL),
        (11,'decision_request_ruled','dr_00000000-0000-4000-8000-000000000007',NULL),
        (12,'decision_request_ruled','dr_00000000-0000-4000-8000-000000000002',NULL),
        (13,'decision_request_ruled','dr_00000000-0000-4000-8000-000000000004',NULL),
        (14,'decision_request_ruled','dr_00000000-0000-4000-8000-000000000001',NULL),
        (15,'decision_request_ruled','dr_00000000-0000-4000-8000-000000000003',NULL),
        (16,'decision_request_ruled','dr_00000000-0000-4000-8000-000000000005',NULL);
      INSERT INTO decision_requests
        (id,kind,raiserId,raiserSessionKey,ownerUserId,raisedAt,deadlineAt,
         actionKey,question,options,context,status,decision,rationale,ruledBy,
         ruledViaPrincipal,ruledViaSessionKey,ruledViaSessionState,ruledAt,
         rulingFactId,consumedAt)
      VALUES
        ('dr_00000000-0000-4000-8000-000000000006','operator','agent:legacy','agent:legacy:session','mike',1,86400001,
         'legacy-session','legacy session?','[{"label":"yes"}]','{}','ruled','yes',NULL,
         'user:mike','user:mike','agent:presenter:legacy','known',10,41,NULL),
        ('dr_00000000-0000-4000-8000-000000000007','operator','agent:legacy','agent:legacy:session','mike',2,86400002,
         'legacy-no-session','legacy no session?','[{"label":"yes"}]','{}','ruled','yes',NULL,
         'user:mike','user:mike',NULL,'none',11,42,NULL),
        ('dr_00000000-0000-4000-8000-000000000002','operator','agent:legacy','agent:legacy:session','mike',3,86400003,
         'missing-decision','missing decision?','[{"label":"yes"}]','{}','ruled',NULL,NULL,
         'user:mike',NULL,NULL,NULL,12,43,NULL),
        ('dr_00000000-0000-4000-8000-000000000004','operator','agent:legacy','agent:legacy:session','',4,86400004,
         'missing-owner','missing owner?','[{"label":"yes"}]','{}','ruled','yes',NULL,
         'user:',NULL,NULL,NULL,13,44,NULL),
        ('dr_00000000-0000-4000-8000-000000000001','operator','agent:legacy','agent:legacy:session','mike',5,86400005,
         'consumed','consumed?','[{"label":"yes"}]','{}','consumed','yes',NULL,
         'user:mike',NULL,NULL,NULL,14,45,14),
        ('dr_00000000-0000-4000-8000-000000000003','operator','agent:legacy','agent:legacy:session','mike',6,86400006,
         'missing-fact','missing fact?','[{"label":"yes"}]','{}','ruled','yes',NULL,
         'user:mike',NULL,NULL,NULL,15,999,NULL),
        ('dr_00000000-0000-4000-8000-000000000005','operator','agent:legacy','agent:legacy:session','mike',7,86400007,
         'wrong-fact','wrong fact?','[{"label":"yes"}]','{}','ruled','yes',NULL,
         'user:mike',NULL,NULL,NULL,16,46,NULL),
        ('dr_00000000-0000-4000-8000-000000000008','operator','agent:legacy','agent:legacy:session','mike',8,86400008,
         'future-open','future open?','[{"label":"yes"}]','{}','open',NULL,NULL,
         NULL,NULL,NULL,NULL,NULL,NULL,NULL);
      PRAGMA ignore_check_constraints=OFF;
      DROP TABLE decision_request_integrity_evidence;
      DROP TABLE decision_request_terminal_epoch;
      ALTER TABLE decision_requests DROP COLUMN ruledViaPrincipal;
      ALTER TABLE decision_requests DROP COLUMN ruledViaSessionState;
      ALTER TABLE sessions DROP COLUMN identityGuidanceDigest;
      ALTER TABLE sessions DROP COLUMN identityRenderContract;
      UPDATE schema_stamp SET shape = '#{@operator_decision_shape}', stampedAt = 1;
      """)

    predecessor_columns =
      "id, kind, raiserId, raiserSessionKey, ownerUserId, assignmentId, expecterSessionKey, expecterUserId, lineageRung, effortGeneration, deadlineWakeId, raisedAt, deadlineAt, statuteName, actionKey, question, options, context, status, decision, rationale, ruledBy, ruledViaSessionKey, ruledAt, rulingFactId, consumedAt, parkWakeId, withdrawnBy, withdrawnReason, withdrawnAt"

    assert {:ok, before} =
             DB.query(db, "SELECT #{predecessor_columns} FROM decision_requests ORDER BY id")

    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[@shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    assert {:ok, [[0]]} = DB.query(db, "PRAGMA ignore_check_constraints")

    assert {:ok, ^before} =
             DB.query(db, "SELECT #{predecessor_columns} FROM decision_requests ORDER BY id")

    assert {:ok, [[46, @terminal_decision_shape, @terminal_decision_shape, "process:tightbeam"]]} =
             DB.query(
               db,
               "SELECT legacyRulingFactMaxId,schemaVersion,cause,principal FROM decision_request_terminal_epoch WHERE id=0"
             )

    call = %{origin: "user:mike", principal: {:user, "mike"}, params: %{}}

    assert %{
             ruling_attribution: %{
               performer: %{
                 principal: %{state: "legacy-unknown"},
                 session: %{state: "known", key: "agent:presenter:legacy"}
               }
             }
           } = Tightbeam.Escalation.get(db, call, "dr_00000000-0000-4000-8000-000000000006")

    assert %{
             ruling_attribution: %{
               performer: %{
                 principal: %{state: "legacy-unknown"},
                 session: %{state: "legacy-unknown"}
               }
             }
           } = Tightbeam.Escalation.get(db, call, "dr_00000000-0000-4000-8000-000000000007")

    expected_invalid =
      ~w(dr_00000000-0000-4000-8000-000000000001 dr_00000000-0000-4000-8000-000000000002 dr_00000000-0000-4000-8000-000000000003 dr_00000000-0000-4000-8000-000000000004 dr_00000000-0000-4000-8000-000000000005)

    assert {:ok, evidence} =
             DB.query(
               db,
               "SELECT requestId,firstSurface,observerPrincipal FROM decision_request_integrity_evidence ORDER BY requestId"
             )

    assert Enum.map(evidence, &hd/1) == expected_invalid

    assert Enum.all?(evidence, fn [_id, surface, principal] ->
             surface == "migration-preflight" and principal == "process:tightbeam"
           end)

    for id <-
          ~w(dr_00000000-0000-4000-8000-000000000002 dr_00000000-0000-4000-8000-000000000003 dr_00000000-0000-4000-8000-000000000005 dr_00000000-0000-4000-8000-000000000001) do
      assert %{code: "decision_request_integrity_invalid", request_id: ^id} =
               Tightbeam.Escalation.get(db, call, id)
    end

    assert %{id: "dr_00000000-0000-4000-8000-000000000008", status: "open"} =
             Tightbeam.Escalation.get(
               db,
               call,
               "dr_00000000-0000-4000-8000-000000000008"
             )

    assert :ok = Schema.ensure_all(db)

    assert {:ok, [[1, 5, @shape]]} =
             DB.query(
               db,
               "SELECT (SELECT COUNT(*) FROM decision_request_terminal_epoch), (SELECT COUNT(*) FROM decision_request_integrity_evidence), (SELECT shape FROM schema_stamp)"
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO condition_facts (id,ts,kind,scope,origin) VALUES (47,17,'escalation-ruled','dr_00000000-0000-4000-8000-000000000008','process:tightbeam')"
             )

    assert {:error, future_error} =
             DB.query(
               db,
               "UPDATE decision_requests SET status='ruled',decision='yes',ruledBy='user:mike',ruledAt=17,rulingFactId=47 WHERE id='dr_00000000-0000-4000-8000-000000000008'"
             )

    assert Exception.message(future_error) =~ "decision_request_integrity_invalid"

    assert {:ok, [["open"]]} =
             DB.query(
               db,
               "SELECT status FROM decision_requests WHERE id='dr_00000000-0000-4000-8000-000000000008'"
             )
  end

  test "operator-decision migration survives a database-owner restart", %{db: _setup_db} do
    unique = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "terminal-parity-restart-#{unique}.sqlite3")
    first = :"terminal_parity_before_#{unique}"
    second = :"terminal_parity_after_#{unique}"

    on_exit(fn -> File.rm(path) end)

    {:ok, first_pid} = DB.start_link(path: path, name: first)
    assert :ok = Schema.ensure_all(first)

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

    :ok = GenServer.stop(first_pid)

    {:ok, second_pid} = DB.start_link(path: path, name: second)
    assert :ok = Schema.ensure_all(second)
    assert {:ok, [[@shape]]} = DB.query(second, "SELECT shape FROM schema_stamp")

    assert {:ok, [[@terminal_decision_shape, 0]]} =
             DB.query(
               second,
               "SELECT schemaVersion, legacyRulingFactMaxId FROM decision_request_terminal_epoch WHERE id=0"
             )

    :ok = GenServer.stop(second_pid)
  end

  test "a failed exact migration rolls back the rename and stamp", %{db: db} do
    :ok = Schema.ensure_all(db)
    downgrade_decision_requests_to_model_identity(db)

    :ok =
      DB.execute(db, """
      INSERT INTO decision_requests
        (id, kind, raiserId, ownerUserId, raisedAt, deadlineAt, statuteName,
         actionKey, question, context, status)
      VALUES
        ('dr_kept', 'statute', 'session:holder', 'mike', 1, 2, 'law-a',
         'action-a', 'allow?', '{}', 'open');
      DROP INDEX decision_requests_key;
      """)

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end
    assert error.message =~ "failed and was rolled back"
    assert {:ok, [[@model_identity_shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    assert {:ok, [["dr_kept"]]} = DB.query(db, "SELECT id FROM decision_requests")
    assert {:ok, []} = table_names(db, "decision_requests_model_identity_v1")
    refute "ruledViaSessionKey" in table_columns(db, "decision_requests")
  end

  test "a message rebuild failure rolls back requests, messages, and stamp", %{db: db} do
    :ok = Schema.ensure_all(db)
    downgrade_decision_requests_to_model_identity(db)

    :ok =
      DB.execute(db, """
      INSERT INTO decision_requests
        (id, kind, raiserId, ownerUserId, raisedAt, deadlineAt, statuteName,
         actionKey, question, context, status)
      VALUES
        ('dr_kept', 'statute', 'session:holder', 'mike', 1, 2, 'law-a',
         'action-a', 'allow?', '{}', 'open');
      INSERT INTO messages
        (seq, id, sessionKey, role, content, timestamp, llmVisibleMessageId)
      VALUES (9, 'm_kept', 'holder', 'user', 'hello', 3, 'm_kept');
      DROP INDEX messages_client_dedupe;
      """)

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end
    assert error.message =~ "failed and was rolled back"
    assert {:ok, [[@model_identity_shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    assert {:ok, [["dr_kept"]]} = DB.query(db, "SELECT id FROM decision_requests")
    assert {:ok, [[9, "m_kept"]]} = DB.query(db, "SELECT seq, id FROM messages")
    assert {:ok, []} = table_names(db, "decision_requests_model_identity_v1")
    assert {:ok, []} = table_names(db, "messages_new")
    refute "ruledViaSessionKey" in table_columns(db, "decision_requests")
    refute "messageType" in table_columns(db, "messages")
    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
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

  test "predecessor assignment file rows stay exact across ensure_all", %{db: db} do
    assert :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO users (userId, isAdmin, createdAt)
      VALUES ('flynn', 0, 1);
      INSERT INTO sessions
        (sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,
         model,createdAt,updatedAt)
      VALUES
        ('holder','holder','flynn','user:flynn','coder','claude','anthropic',
         'fixture-model',1,1);
      """)

    :ok =
      DB.execute(db, """
      INSERT INTO assignments
        (id,subject,holderKey,holderRole,holderFallback,openedByUser,
         openedBySession,openedAt,state,outcome,closedAt,closedByUser,
         closedBySession,closingAttestId)
      VALUES
        ('asg_predecessor','advisory files','holder',NULL,0,'flynn',
         NULL,1,'open',NULL,NULL,NULL,NULL,NULL)
      """)

    :ok =
      DB.execute(db, """
      INSERT INTO assignment_files (assignmentId, path)
      VALUES ('asg_predecessor','lib/a.ex'), ('asg_predecessor','test/a_test.exs')
      """)

    assert {:ok, before_rows} =
             DB.query(db, "SELECT * FROM assignment_files ORDER BY assignmentId, path")

    assert :ok = Schema.ensure_all(db)

    assert {:ok, ^before_rows} =
             DB.query(db, "SELECT * FROM assignment_files ORDER BY assignmentId, path")

    assert Assignments.declared_files(db, "asg_predecessor") ==
             ["lib/a.ex", "test/a_test.exs"]

    assert {:ok, [[@shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")
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

  test "terminal-decision stamp without the historical liveness carrier refuses before mutation",
       %{
         db: db
       } do
    assert :ok = Schema.ensure_all(db)
    drop_liveness_activation(db)
    downgrade_wakes_to_terminal_decision(db)

    :ok =
      DB.execute(db, """
      INSERT INTO wakes
        (wakeId,sessionKey,origin,prompt,dueAt,state,createdAt,firedAt,canceledAt)
      VALUES
        ('w_pending','session-a','process:tightbeam','pending',90,'pending',10,NULL,NULL),
        ('w_fired','session-a','process:tightbeam','fired',90,'fired',11,91,NULL),
        ('w_canceled','session-a','process:tightbeam','canceled',90,'canceled',12,NULL,92)
      """)

    {:ok, before_rows} =
      DB.query(db, "SELECT #{legacy_wake_columns()} FROM wakes ORDER BY wakeId")

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end

    assert error.message =~ "migration #{@terminal_decision_shape} failed and was rolled back"
    assert error.message =~ "wake_cancellations"

    assert {:ok, ^before_rows} =
             DB.query(db, "SELECT #{legacy_wake_columns()} FROM wakes ORDER BY wakeId")

    refute table?(db, "wake_cancellations")
    refute table?(db, "notice_batches")
    assert {:ok, [[@terminal_decision_shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")
  end

  test "the exact d483 terminal-liveness database migrates and survives restart", %{db: _db} do
    unique = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "d483-terminal-liveness-restart-#{unique}.sqlite3")
    first = :"d483_terminal_liveness_before_#{unique}"
    second = :"d483_terminal_liveness_after_#{unique}"

    fixture =
      __DIR__
      |> Path.join("fixtures/d483a9c8_terminal_liveness.sqlite3.gz.b64")
      |> File.read!()
      |> String.replace(~r/\s+/u, "")
      |> Base.decode64!()
      |> :zlib.gunzip()

    assert Base.encode16(:crypto.hash(:sha256, fixture), case: :lower) ==
             "593308eb122ea1140a592b667afea41c501f99003949025ad29fea407d74eeb0"

    File.write!(path, fixture)

    on_exit(fn ->
      File.rm(path)
      File.rm("#{path}-shm")
      File.rm("#{path}-wal")
    end)

    {:ok, first_pid} = DB.start_link(path: path, name: first)
    assert {:ok, [[@terminal_decision_shape]]} = DB.query(first, "SELECT shape FROM schema_stamp")
    assert table?(first, "wake_cancellations")
    assert :ok = Schema.ensure_all(first)
    assert {:ok, [[@shape]]} = DB.query(first, "SELECT shape FROM schema_stamp")
    :ok = GenServer.stop(first_pid)

    {:ok, second_pid} = DB.start_link(path: path, name: second)
    assert :ok = Schema.ensure_all(second)
    assert {:ok, [[@shape]]} = DB.query(second, "SELECT shape FROM schema_stamp")
    assert "identityGuidanceDigest" in table_columns(second, "sessions")

    assert object_sql(second, "trigger", "wakes_typed_cancellation_required") =~
             "pendingwakecancellationrequirestypedprovenance"

    :ok = GenServer.stop(second_pid)
  end

  test "the exact notice-batching predecessor widens effort cancellation and preserves the stamp",
       %{db: db} do
    assert :ok = Schema.ensure_all(db)

    {:ok, [[current_ddl]]} =
      DB.query(
        db,
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='wake_cancellations'"
      )

    effort_arm =
      ~r/\n\s+OR\n\s+\(workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NULL AND\n\s+livenessTriggerId IS NULL AND actionNeeded = 0 AND\n\s+requesterKind = 'process' AND requesterId = 'tightbeam:effort-checkin' AND\n\s+reasonKind = 'obligation_disposed' AND causalSourceKind = 'decision_request' AND\n\s+dispositionKind = 'decision_request_transition' AND\n\s+causalSourceId = dispositionId\)/

    predecessor_ddl = Regex.replace(effort_arm, current_ddl, "", global: false)
    refute predecessor_ddl == current_ddl

    refute predecessor_ddl =~
             "reasonKind = 'obligation_disposed' AND causalSourceKind = 'decision_request' AND\n" <>
               "      dispositionKind = 'decision_request_transition' AND\n" <>
               "      causalSourceId = dispositionId)"

    :ok =
      DB.execute(db, """
      DROP TRIGGER wakes_typed_cancellation_required;
      DROP TRIGGER wake_cancellations_pending_insert;
      ALTER TABLE wake_cancellations RENAME TO wake_cancellations_current;
      #{predecessor_ddl};
      DROP TABLE wake_cancellations_current;
      ALTER TABLE sessions DROP COLUMN identityGuidanceDigest;
      ALTER TABLE sessions DROP COLUMN identityRenderContract;
      UPDATE schema_stamp
        SET shape='#{@effort_request_exit_previous_shape}', stampedAt=1;
      """)

    assert {:ok, [[@effort_request_exit_previous_shape]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert :ok = Schema.ensure_all(db)
    assert {:ok, [[@shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    assert "identityRenderContract" in table_columns(db, "sessions")
    assert "identityGuidanceDigest" in table_columns(db, "sessions")

    {:ok, [[migrated_ddl]]} =
      DB.query(
        db,
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='wake_cancellations'"
      )

    assert migrated_ddl =~ "requesterId = 'tightbeam:effort-checkin'"

    assert object_sql(db, "trigger", "wakes_typed_cancellation_required") =~
             "pendingwakecancellationrequirestypedprovenance"
  end

  test "the real be61 decision-request shape is refused before it can be read", %{db: db} do
    :ok =
      DB.execute(db, """
      CREATE TABLE schema_stamp (
        shape     TEXT PRIMARY KEY,
        stampedAt INTEGER NOT NULL
      );
      INSERT INTO schema_stamp (shape, stampedAt) VALUES ('#{@be61_shape}', 1);
      #{@be61_decision_requests_ddl};
      """)

    refute "ruledViaSessionKey" in table_columns(db, "decision_requests")

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end

    assert error.message =~ @be61_shape
    assert error.message =~ @shape

    assert error.message =~ @model_identity_shape
    assert error.message =~ @operator_decision_shape
    assert error.message =~ @terminal_decision_shape
    assert error.message =~ @shape

    assert {:ok, [[@be61_shape]]} = DB.query(db, "SELECT shape FROM schema_stamp")
    refute "ruledViaSessionKey" in table_columns(db, "decision_requests")
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

  test "a database stamped with the nullable marker constraint is refused", %{db: db} do
    :ok = Schema.ensure_all(db)
    {:ok, _} = DB.query(db, "UPDATE schema_stamp SET shape='model-identity-message-envelope-v1'")

    error = assert_raise Schema.ShapeError, fn -> Schema.ensure_all(db) end

    assert error.message =~ "model-identity-message-envelope-v1"
    assert error.message =~ @shape
  end

  defp table?(db, name) do
    {:ok, rows} =
      DB.query(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1", [name])

    rows == [[1]]
  end

  defp downgrade_decision_requests_to_model_identity(db) do
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
