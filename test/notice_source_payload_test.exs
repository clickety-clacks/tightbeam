defmodule Tightbeam.NoticeSourcePayloadTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    ConditionFacts,
    DB,
    Ledger,
    Model,
    NoticeBatcher,
    Org,
    Projection,
    Schema,
    Wakes
  }

  alias Tightbeam.DB.Txn

  setup do
    db = :"notice_source_payload_#{System.unique_integer([:positive])}"
    base = Path.join(System.tmp_dir!(), "#{db}")
    prepared = Tightbeam.GuardRuntimeFixture.prepare!(base, "schema_shape_runtime.exs")

    db_opts = [
      path: Path.join(prepared.base, "state.db"),
      name: db,
      guard_inputs: [],
      payload_root: prepared.payload
    ]

    start_supervised!(Supervisor.child_spec({DB, db_opts}, id: db))
    on_exit(fn -> File.rm_rf!(base) end)
    :ok = Schema.ensure_all(db)
    %{db: db, db_opts: db_opts}
  end

  test "populated predecessor payloads move exactly onto their source and survive restart", %{
    db: db,
    db_opts: db_opts
  } do
    source =
      Wakes.schedule(db, %{
        session_key: "payload-recipient",
        origin: "user:owner",
        prompt: "original editable source",
        due_at: 0
      })

    predecessor!(db, db_opts)
    before = source_snapshot(db, source.wake_id)
    encoded = "[ {\"name\": \"original.png\", \"url\": \"attachment://original\"} ]"
    hash = :crypto.hash(:sha256, source.prompt) |> Base.encode16(case: :lower)

    assert {:ok, _} =
             DB.query(db, "INSERT INTO notice_batch_source_attachments VALUES (?1,?2)", [
               source.wake_id,
               encoded
             ])

    assert {:ok, _} =
             DB.query(db, "INSERT INTO staged_message_dedupes VALUES (?1,?2,?3,?4,?5,?6)", [
               "payload-recipient",
               "original-device",
               "original-client",
               source.wake_id,
               hash,
               source.created_at
             ])

    policy = [
      "notice-policy:" <> source.wake_id,
      source.wake_id,
      "role:original",
      "payload-recipient",
      "original",
      "original-private",
      "original-revision",
      123,
      0,
      source.created_at
    ]

    lane = [
      "role:original",
      "original-private",
      0,
      "original-revision",
      "original-lane",
      "user:owner",
      "original-cause",
      17
    ]

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO notice_delivery_policies VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
               policy
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO notice_batching_lane_policies VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
               lane
             )

    assert :ok =
             DB.execute(db, """
             INSERT INTO notice_batches(batchId,recipientAddress,sessionKey,visibilityScope,policyRevision,state,dueAt,openedAt,sealedAt,deliveryToken,envelope,envelopeSha256,deliveredAt)
             VALUES('historical-batch','role:original','payload-recipient','original-private','original-revision','delivered',123,1,2,'original-token','original immutable envelope','original-hash',3);
             """)

    assert {:ok, _} =
             DB.query(
               db,
               """
               INSERT INTO notice_batch_members(rowid,memberId,batchId,sourceWakeId,policyRef,recipientAddress,visibilityScope,publicationSeq,policyRevision,senderPrincipal,cause,class,payload,renderedBytes,state,addedAt)
               VALUES(42,'historical-member','historical-batch',?1,?2,'role:original','original-private',7,'original-revision','user:owner','original-cause','fyi','historical raw payload',22,'included',17)
               """,
               [source.wake_id, hd(policy)]
             )

    assert {:ok, history_before} = DB.query(db, "SELECT rowid,* FROM notice_batch_members")
    assert {:ok, batch_before} = DB.query(db, "SELECT rowid,* FROM notice_batches")

    assert :ok = Schema.ensure_all(db)
    assert source_snapshot(db, source.wake_id) == before
    assert {:ok, ^history_before} = DB.query(db, "SELECT rowid,* FROM notice_batch_members")
    assert {:ok, ^batch_before} = DB.query(db, "SELECT rowid,* FROM notice_batches")

    assert {:ok, [["original-private", "role:original"]]} =
             DB.query(
               db,
               "SELECT sourceVisibilityScope,sourceAddress FROM wakes WHERE wakeId=?1",
               [source.wake_id]
             )

    assert {:ok, [[archived_policy]]} =
             DB.query(
               db,
               "SELECT detail FROM lifecycle_events WHERE kind='notice_source_policy_retired' AND subject=?1",
               [hd(policy)]
             )

    assert JSON.decode!(archived_policy) ==
             Map.new(
               Enum.zip(
                 ~w(policyRef sourceWakeId recipientAddress sessionKey targetRole visibilityScope policyRevision deadlineAt enabled createdAt),
                 policy
               )
             )

    assert {:ok, [[archived_lane]]} =
             DB.query(
               db,
               "SELECT detail FROM lifecycle_events WHERE kind='notice_lane_policy_retired' AND subject='original-lane'"
             )

    assert JSON.decode!(archived_lane) ==
             Map.new(
               Enum.zip(
                 ~w(recipientAddress visibilityScope enabled policyRevision policyRef selectedBy cause selectedAt),
                 lane
               )
             )

    assert {:ok, [[^encoded, identity]]} =
             DB.query(
               db,
               "SELECT sourceAttachments,sourceClientIdentity FROM wakes WHERE wakeId=?1",
               [source.wake_id]
             )

    assert JSON.decode!(identity) == %{
             "targetSessionKey" => "payload-recipient",
             "deviceId" => "original-device",
             "clientMessageId" => "original-client",
             "sourceWakeId" => source.wake_id,
             "payloadSha256" => hash,
             "createdAt" => source.created_at
           }

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE name IN ('notice_batch_source_attachments','staged_message_dedupes','notice_delivery_policies','notice_batching_lane_policies')"
             )

    assert {:ok, [["notice-source-storage-v1-019"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")

    input = %{
      session_key: "payload-recipient",
      device_id: "original-device",
      client_message_id: "original-client",
      content: source.prompt,
      raw_content: source.prompt
    }

    assert {:ok, {:duplicate, %{wake_id: wake_id}}} =
             DB.transaction(db, &Projection.prompt_message_result_in_txn(&1, input))

    assert wake_id == source.wake_id

    assert {:ok, {:conflict, %{code: "client_message_conflict"}}} =
             DB.transaction(
               db,
               &Projection.prompt_message_result_in_txn(
                 &1,
                 Map.put(input, :raw_content, "changed")
               )
             )

    assert {:ok, attachments} =
             DB.transaction(db, &NoticeBatcher.delivery_attachments_in_txn(&1, source.wake_id))

    assert attachments == JSON.decode!(encoded)
    stop_supervised!(db)
    start_supervised!(Supervisor.child_spec({DB, db_opts}, id: db))
    assert :ok = Schema.ensure_all(db)

    assert {:ok, [[^encoded, ^identity]]} =
             DB.query(
               db,
               "SELECT sourceAttachments,sourceClientIdentity FROM wakes WHERE wakeId=?1",
               [source.wake_id]
             )

    assert source_snapshot(db, source.wake_id) == before
    assert {:ok, ^history_before} = DB.query(db, "SELECT rowid,* FROM notice_batch_members")
    assert {:ok, ^batch_before} = DB.query(db, "SELECT rowid,* FROM notice_batches")

    assert {:ok, [[1], [1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM lifecycle_events WHERE kind='notice_source_policy_retired' UNION ALL SELECT COUNT(*) FROM lifecycle_events WHERE kind='notice_lane_policy_retired'"
             )
  end

  for requested_scope <- ["actual-recipient", nil] do
    @legacy_requested_scope requested_scope
    test "recognized predecessor condition with scope #{inspect(@legacy_requested_scope)} refuses atomically without rewriting authored markers",
         %{db: db, db_opts: db_opts} do
      authored = "[woke: fact authored/marker-looking-prefix]\n\nkeep this authored text"

      condition =
        Wakes.schedule(db, %{
          session_key: "payload-recipient",
          origin: "user:owner",
          prompt: authored,
          due_at: 9_999_999_999_999,
          condition_kind: "queue-ready",
          condition_scope: @legacy_requested_scope
        })

      ordinary =
        Wakes.schedule(db, %{
          session_key: "payload-recipient",
          origin: "user:owner",
          prompt: "ordinary sibling",
          due_at: 0
        })

      predecessor!(db, db_opts)
      stamped = "[woke: fact queue-ready/actual-recipient]\n\n" <> authored

      assert {:ok, _} =
               DB.query(
                 db,
                 "UPDATE wakes SET prompt=?2,firedAt=17,firedBy='condition',recognitionEvidence=NULL WHERE wakeId=?1",
                 [condition.wake_id, stamped]
               )

      assert {:ok, sources_before} = DB.query(db, "SELECT rowid,* FROM wakes ORDER BY rowid")
      objects_before = payload_snapshot(db)

      assert {:ok, ddl_before} =
               DB.query(db, "SELECT type,name,sql FROM sqlite_master ORDER BY type,name")

      assert_raise Schema.ShapeError,
                   ~r/incompatible_notice_source_payload: unsupported_pending_condition_recognition/,
                   fn -> Schema.ensure_all(db) end

      assert {:ok, ^sources_before} = DB.query(db, "SELECT rowid,* FROM wakes ORDER BY rowid")
      assert payload_snapshot(db) == objects_before

      assert {:ok, ^ddl_before} =
               DB.query(db, "SELECT type,name,sql FROM sqlite_master ORDER BY type,name")

      assert %{
               state: "pending",
               prompt: ^stamped,
               recognition_evidence: nil,
               fired_by: "condition",
               fired_at: 17
             } = Wakes.get(db, condition.wake_id)

      assert Wakes.get(db, ordinary.wake_id).state == "pending"

      assert {:ok, [["assignment-source-replacement-v1-019"]]} =
               DB.query(db, "SELECT shape FROM schema_stamp")

      assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM turns")
      assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
      stop_supervised!(db)
      start_supervised!(Supervisor.child_spec({DB, db_opts}, id: db))

      assert_raise Schema.ShapeError, ~r/unsupported_pending_condition_recognition/, fn ->
        Schema.ensure_all(db)
      end

      assert {:ok, ^sources_before} = DB.query(db, "SELECT rowid,* FROM wakes ORDER BY rowid")
      assert payload_snapshot(db) == objects_before

      assert {:ok, ^ddl_before} =
               DB.query(db, "SELECT type,name,sql FROM sqlite_master ORDER BY type,name")
    end
  end

  for requested_scope <- ["actual-recipient", nil] do
    @carried_requested_scope requested_scope
    test "current stamp refuses preserved legacy recognition with scope #{inspect(@carried_requested_scope)} on persistent reopen",
         %{db: db, db_opts: db_opts} do
      authored = "[woke: fact authored/marker-looking-prefix]\n\nkeep this authored text"

      condition =
        Wakes.schedule(db, %{
          session_key: "payload-recipient",
          origin: "user:owner",
          prompt: authored,
          due_at: 9_999_999_999_999,
          condition_kind: "queue-ready",
          condition_scope: @carried_requested_scope
        })

      ordinary =
        Wakes.schedule(db, %{
          session_key: "payload-recipient",
          origin: "user:owner",
          prompt: "ordinary sibling",
          due_at: 0
        })

      # Model the exact preservation transition accepted by parent 8dbc: it
      # added source columns, copied the selected address/visibility, and retained
      # the legacy prompt, condition state and nil evidence at the current stamp.
      # No stamp is changed here; this is the actual current table layout.
      stamped = "[woke: fact queue-ready/actual-recipient]\n\n" <> authored

      assert {:ok, _} =
               DB.query(
                 db,
                 "UPDATE wakes SET prompt=?2,firedAt=17,firedBy='condition',recognitionEvidence=NULL WHERE wakeId=?1",
                 [condition.wake_id, stamped]
               )

      assert {:ok,
              [
                [nil, nil, "session:payload-recipient:recipient", "session:payload-recipient"]
              ]} =
               DB.query(
                 db,
                 "SELECT sourceClientIdentity,sourceAttachments,sourceVisibilityScope,sourceAddress FROM wakes WHERE wakeId=?1",
                 [condition.wake_id]
               )

      assert {:ok, [["notice-source-storage-v1-019"]]} =
               DB.query(db, "SELECT shape FROM schema_stamp")

      before = current_storage_snapshot(db)

      assert_raise Schema.ShapeError, ~r/unsupported_pending_condition_recognition/, fn ->
        Schema.ensure_all(db)
      end

      assert current_storage_snapshot(db) == before
      stop_supervised!(db)
      start_supervised!(Supervisor.child_spec({DB, db_opts}, id: db))

      assert_raise Schema.ShapeError, ~r/unsupported_pending_condition_recognition/, fn ->
        Schema.ensure_all(db)
      end

      assert current_storage_snapshot(db) == before

      assert %{state: "pending", prompt: ^stamped, recognition_evidence: nil} =
               Wakes.get(db, condition.wake_id)

      assert Wakes.get(db, ordinary.wake_id).state == "pending"
      assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM turns")
      assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
    end
  end

  test "current stamp admits an actual recognized fact and preserves its scope on reopen", %{
    db: db,
    db_opts: db_opts
  } do
    assert {:ok, _} =
             DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1)")

    session =
      Org.create(db, %{
        session_key: "payload-recipient",
        display_name: "Payload recipient",
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    assert {:appended, current} =
             Projection.append(db, %{
               session_key: session.session_key,
               role: "user",
               content: "already queued work"
             })

    assert {:ok, _} =
             Ledger.enqueue(db, %{
               session_key: session.session_key,
               message_id: current.id,
               origin: "user:owner",
               prompt: "already queued work"
             })

    authored = "[woke: fact authored/prefix]\n\nraw condition source"

    source =
      Wakes.schedule(db, %{
        session_key: "payload-recipient",
        origin: "user:owner",
        owner_user_id: "owner",
        prompt: authored,
        due_at: 9_999_999_999_999,
        condition_kind: "queue-ready",
        condition_scope: nil
      })

    scheduler =
      start_supervised!(
        {Wakes,
         db: db,
         name: :current_payload_condition_scheduler,
         tick_ms: 60_000,
         deliver: fn _ -> flunk("busy fixture recipient must not admit another turn") end}
      )

    fact =
      ConditionFacts.file(db, scheduler, %{
        kind: "queue-ready",
        scope: "actual-recipient",
        origin: "user:owner",
        owner_user_id: "owner"
      })

    assert fact.scope == "actual-recipient"

    assert %{state: "pending", fired_by: "condition", prompt: ^authored} =
             recognized = Wakes.get(db, source.wake_id)

    assert %{"condition_fact" => %{"kind" => "queue-ready", "scope" => "actual-recipient"}} =
             recognized.recognition_evidence

    before = current_storage_snapshot(db)
    assert :ok = Schema.ensure_all(db)
    assert current_storage_snapshot(db) == before
    stop_supervised!(Wakes)
    stop_supervised!(db)
    start_supervised!(Supervisor.child_spec({DB, db_opts}, id: db))
    assert :ok = Schema.ensure_all(db)
    assert current_storage_snapshot(db) == before

    assert {:ok, rendered} =
             DB.transaction(db, &Wakes.delivery_prompt_in_txn(&1, source.wake_id))

    assert rendered == "[woke: fact queue-ready/actual-recipient]\n\n" <> authored
    assert Wakes.get(db, source.wake_id) == recognized
  end

  test "unknown predecessor columns refuse without copying or dropping payload data", %{
    db: db,
    db_opts: db_opts
  } do
    source =
      Wakes.schedule(db, %{
        session_key: "payload-recipient",
        origin: "user:owner",
        prompt: "preserve on refusal",
        due_at: 0
      })

    predecessor!(db, db_opts)

    assert {:ok, _} =
             DB.query(db, "INSERT INTO notice_batch_source_attachments VALUES (?1,'[]')", [
               source.wake_id
             ])

    assert :ok = DB.execute(db, "ALTER TABLE staged_message_dedupes ADD COLUMN unrecognized TEXT")
    before = payload_snapshot(db)

    assert_raise Schema.ShapeError,
                 ~r/incompatible_notice_source_payload: malformed staged_message_dedupes/,
                 fn -> Schema.ensure_all(db) end

    assert payload_snapshot(db) == before

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM pragma_table_info('wakes') WHERE name IN ('sourceAttachments','sourceClientIdentity')"
             )
  end

  test "a copy failure rolls back columns, index, tables and the predecessor stamp", %{
    db: db,
    db_opts: db_opts
  } do
    source =
      Wakes.schedule(db, %{
        session_key: "payload-recipient",
        origin: "user:owner",
        prompt: "preserve on failed copy",
        due_at: 0
      })

    predecessor!(db, db_opts)

    assert {:ok, _} =
             DB.query(db, "INSERT INTO notice_batch_source_attachments VALUES (?1,'[]')", [
               source.wake_id
             ])

    assert :ok =
             DB.execute(
               db,
               "CREATE TRIGGER refuse_payload_copy BEFORE UPDATE ON wakes BEGIN SELECT RAISE(ABORT,'forced source payload copy failure'); END"
             )

    before = payload_snapshot(db)

    assert_raise Schema.ShapeError, ~r/notice source payload migration rolled back/, fn ->
      Schema.ensure_all(db)
    end

    assert payload_snapshot(db) == before

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE name='notice_source_client_identity'"
             )

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM pragma_table_info('wakes') WHERE name IN ('sourceAttachments','sourceClientIdentity')"
             )
  end

  defp predecessor!(db, db_opts) do
    :ok =
      DB.execute(
        db,
        "DROP INDEX notice_source_client_identity; ALTER TABLE wakes DROP COLUMN sourceClientIdentity; ALTER TABLE wakes DROP COLUMN sourceAttachments; ALTER TABLE wakes DROP COLUMN sourceVisibilityScope; ALTER TABLE wakes DROP COLUMN sourceAddress;"
      )

    for {_name, sql} <- NoticeBatcher.previous_source_payload_objects(),
        do: :ok = DB.execute(db, sql)

    assert {:ok, :ok} =
             DB.migration_transaction(
               db,
               :source_payload_test_predecessor,
               ["PRAGMA foreign_keys=OFF", "PRAGMA legacy_alter_table=ON"],
               ["PRAGMA legacy_alter_table=OFF", "PRAGMA foreign_keys=ON"],
               fn txn ->
                 :ok = Txn.exec(txn, "DROP TABLE notice_batch_members")
                 :ok = Txn.exec(txn, NoticeBatcher.previous_source_member_ddl())

                 :ok =
                   Txn.exec(
                     txn,
                     "CREATE INDEX notice_batch_members_batch ON notice_batch_members(batchId,publicationSeq)"
                   )
               end
             )

    {:ok, _} =
      DB.query(
        db,
        "UPDATE schema_stamp SET shape='assignment-source-replacement-v1-019',stampedAt=1"
      )

    # Admit the completed predecessor from disk, rather than mutating a stamp
    # after this connection's guarded inspection.
    stop_supervised!(db)
    start_supervised!(Supervisor.child_spec({DB, db_opts}, id: db))
  end

  defp source_snapshot(db, id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT wakeId,prompt,state,class,classElection,dueAt,createdAt,sessionKey,targetRole,creatorSessionKey FROM wakes WHERE wakeId=?1",
        [id]
      )

    rows
  end

  defp current_storage_snapshot(db) do
    for sql <- [
          "SELECT rowid,* FROM wakes ORDER BY rowid",
          "SELECT * FROM schema_stamp",
          "SELECT type,name,sql FROM sqlite_master ORDER BY type,name",
          "SELECT rowid,* FROM notice_batch_members ORDER BY rowid",
          "SELECT * FROM turns ORDER BY seq",
          "SELECT * FROM lifecycle_events ORDER BY id",
          "PRAGMA foreign_key_check"
        ] do
      assert {:ok, rows} = DB.query(db, sql)
      rows
    end
  end

  defp payload_snapshot(db) do
    for sql <- [
          "SELECT * FROM schema_stamp",
          "SELECT * FROM staged_message_dedupes",
          "SELECT * FROM notice_batch_source_attachments",
          "SELECT * FROM notice_delivery_policies",
          "SELECT * FROM notice_batching_lane_policies",
          "SELECT rowid,* FROM notice_batch_members",
          "SELECT * FROM lifecycle_events WHERE kind IN ('notice_source_policy_retired','notice_lane_policy_retired')",
          "SELECT type,name,sql FROM sqlite_master WHERE name IN ('staged_message_dedupes','notice_batch_source_attachments','notice_source_client_identity') ORDER BY name"
        ] do
      {:ok, rows} = DB.query(db, sql)
      rows
    end
  end
end
