defmodule Tightbeam.Firehose.SessionRegistryA6Test do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Ledger, Model, Org, Projection, Schema, StateResources}
  alias Tightbeam.Firehose.Hub

  setup do
    db = :firehose_session_registry_a6_db
    start_supervised!({DB, path: ":memory:", name: db}, id: :a6_migration_db)
    start_supervised!({Hub, name: Hub})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('flynn',1,1)"
      )

    register_hosts(db, %{
      "testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}
    })

    main = create_session(db, Org.personal_session_key("flynn"), "Main", kind: "main")
    worker = create_session(db, "a6-worker", "A6 worker", spawned_by: main.session_key)

    :ok =
      Hub.register(Hub, self(), %{
        mode: :subscribed,
        db: db,
        user_id: "flynn",
        is_admin: false
      })

    :ok =
      Hub.subscribe(Hub, self(), "session", %{
        "classes" => ["session."],
        "sessionKey" => worker.session_key
      })

    %{db: db, worker: worker}
  end

  test "real session mutations emit one canonical monotonic update and duplicates emit none",
       ctx do
    before = canonical_session(ctx.db, ctx.worker.session_key)

    renamed = Org.rename(ctx.db, ctx.worker.session_key, "Renamed worker")
    notice = receive_notice()

    assert %{
             "class" => "session.updated",
             "resource" => "sessions",
             "op" => "upsert",
             "refs" => %{"sessionKey" => "a6-worker"},
             "payload" => payload
           } = notice

    assert payload == canonical_session(ctx.db, ctx.worker.session_key)
    assert payload == StateResources.session(renamed)
    assert payload["rowVersion"] > before["rowVersion"]
    refute Map.has_key?(payload, "cliToken")
    refute inspect(payload) =~ "tbs_"

    duplicate = Org.rename(ctx.db, ctx.worker.session_key, "Renamed worker")
    assert duplicate.updated_at == renamed.updated_at
    sync_hub()
    refute_receive {:firehose_notice, _notice}, 50

    adopted = Org.set_adopted(ctx.db, ctx.worker.session_key, false)
    newer = receive_notice()
    assert newer["payload"] == StateResources.session(adopted)
    assert newer["payload"]["rowVersion"] > payload["rowVersion"]

    model =
      nil
      |> apply_last_version(payload)
      |> apply_last_version(newer["payload"])
      |> apply_last_version(payload)
      |> apply_last_version(newer["payload"])

    assert model == newer["payload"]
    assert model == canonical_session(ctx.db, ctx.worker.session_key)
  end

  test "visibility and exact session filtering run before delivery", ctx do
    other = create_session(ctx.db, "a6-other", "Other worker")
    _ = Org.rename(ctx.db, other.session_key, "Filtered worker")
    sync_hub()
    refute_receive {:firehose_notice, _notice}, 50

    :ok =
      Hub.register(Hub, self(), %{
        mode: :subscribed,
        db: ctx.db,
        user_id: "mallory",
        is_admin: false
      })

    _ = Org.rename(ctx.db, ctx.worker.session_key, "Hidden worker")
    sync_hub()
    refute_receive {:firehose_notice, _notice}, 50

    :ok =
      Hub.register(Hub, self(), %{
        mode: :subscribed,
        db: ctx.db,
        user_id: "flynn",
        is_admin: false
      })

    _ = Org.rename(ctx.db, ctx.worker.session_key, "Visible worker")
    assert %{"class" => "session.updated", "subscriptionId" => "session"} = receive_notice()
  end

  test "hub restart replays nothing and a fresh rebuild converges before later updates", ctx do
    _ = Org.rename(ctx.db, ctx.worker.session_key, "Before restart")
    before_restart = receive_notice()["payload"]

    assert :ok = stop_supervised(Hub)
    start_supervised!({Hub, name: Hub})

    :ok =
      Hub.register(Hub, self(), %{
        mode: :subscribed,
        db: ctx.db,
        user_id: "flynn",
        is_admin: false
      })

    :ok = Hub.subscribe(Hub, self(), "session", %{"classes" => ["session."]})
    sync_hub()
    refute_receive {:firehose_notice, _notice}, 50

    rebuilt = canonical_session(ctx.db, ctx.worker.session_key)
    assert rebuilt == before_restart

    _ = Org.rename(ctx.db, ctx.worker.session_key, "After restart")
    after_restart = receive_notice()["payload"]
    assert after_restart["rowVersion"] > rebuilt["rowVersion"]
    assert after_restart == canonical_session(ctx.db, ctx.worker.session_key)
  end

  test "mechanical status changes only when the qualifying turn count crosses zero", ctx do
    assert canonical_session(ctx.db, ctx.worker.session_key)["mechanicalStatus"] == "idle"

    {:ok, first} = enqueue(ctx.db, ctx.worker.session_key, "first")
    running = receive_notice()["payload"]
    assert running["mechanicalStatus"] == "running"

    {:ok, second} = enqueue(ctx.db, ctx.worker.session_key, "second")
    sync_hub()
    refute_receive {:firehose_notice, _notice}, 50

    {:ok, first_turn} = Ledger.claim_next(ctx.db, ctx.worker.session_key, "lane")
    assert first_turn.seq == first
    sync_hub()
    refute_receive {:firehose_notice, _notice}, 50

    :ok = Ledger.finish(ctx.db, first, "delivered", nil)
    sync_hub()
    refute_receive {:firehose_notice, _notice}, 50

    {:ok, second_turn} = Ledger.claim_next(ctx.db, ctx.worker.session_key, "lane")
    assert second_turn.seq == second
    sync_hub()
    refute_receive {:firehose_notice, _notice}, 50

    :ok = Ledger.finish(ctx.db, second, "delivered", nil)
    idle = receive_notice()["payload"]
    assert idle["mechanicalStatus"] == "idle"
    assert idle["rowVersion"] > running["rowVersion"]
    assert idle == canonical_session(ctx.db, ctx.worker.session_key)
  end

  test "one compound harness-switch commit emits only its final canonical session", ctx do
    for content <- ["before one", "before two"] do
      {:appended, _message} =
        Projection.append(ctx.db, %{
          session_key: ctx.worker.session_key,
          role: "user",
          sender: "user:flynn",
          content: content
        })
    end

    before = Org.get(ctx.db, ctx.worker.session_key)

    assert {:ok, {:ok, updated}} =
             DB.transaction(ctx.db, fn txn ->
               [[max_seq]] =
                 Tightbeam.DB.Txn.q(
                   txn,
                   "SELECT MAX(seq) FROM messages WHERE sessionKey = ?1",
                   [ctx.worker.session_key]
                 )

               Org.swap_model_in_txn(
                 txn,
                 ctx.worker.session_key,
                 {before.model, before.harness},
                 {Model.new("gpt-5.6-sol"), "codex", "openai"},
                 cleared_through: max_seq
               )
             end)

    notice = receive_notice()
    assert notice["class"] == "session.updated"
    assert notice["payload"] == StateResources.session(updated)
    assert notice["payload"] == canonical_session(ctx.db, ctx.worker.session_key)
    assert notice["payload"]["harness"] == "codex"
    assert notice["payload"]["clearedThroughSeq"] == 2
    assert notice["payload"]["rowVersion"] > before.updated_at

    sync_hub()
    refute_receive {:firehose_notice, _notice}, 50
  end

  test "exact R1 carrier migration materializes status and advances every changed public item version" do
    db = :firehose_session_registry_a6_migration_db
    start_supervised!({DB, path: ":memory:", name: db})
    sql = File.read!(Path.join(__DIR__, "fixtures/r1_o2_v1.sql"))

    assert Base.encode16(:crypto.hash(:sha256, sql), case: :lower) ==
             "065102fc0394262f6a7f3e71f0a8bc021fe02833875e840739c743f6837797bc"

    :ok = DB.execute(db, sql)
    # Exact additive R1 predecessor, not current DDL relabeled as historical.
    :ok =
      DB.execute(db, """
      ALTER TABLE assignments ADD COLUMN reminderState TEXT NULL;
      ALTER TABLE condition_facts ADD COLUMN payload TEXT NULL;
      UPDATE schema_stamp SET shape='row-driven-r1-v1-019';
      INSERT INTO users(userId,createdAt) VALUES ('fixture',1);
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
        VALUES ('idle-session','idle','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,10),
               ('running-session','running','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,20);
      INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt)
        VALUES ('running-session','queued-message','user:fixture','synthetic','queued',1);
      INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,reminderState)
        VALUES ('retained','synthetic','idle-session','fixture',1,'{"phase":"pending"}');
      """)

    assert :ok = Schema.upgrade_firehose_r1(db)

    assert {:ok,
            [
              ["idle-session", "idle", idle_version],
              ["running-session", "running", running_version]
            ]} =
             DB.query(
               db,
               "SELECT sessionKey,mechanicalStatus,updatedAt FROM sessions ORDER BY sessionKey"
             )

    assert idle_version > 10
    assert running_version > 20
    assert {:ok, [["session-reparent-v1-019"]]} = DB.query(db, "SELECT shape FROM schema_stamp")

    assert {:ok, [[~s({"phase":"pending"})]]} =
             DB.query(db, "SELECT reminderState FROM assignments WHERE id='retained'")

    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
    assert :ok = Schema.ensure_all(db)

    assert {:ok,
            [
              ["idle-session", "idle", ^idle_version],
              ["running-session", "running", ^running_version]
            ]} =
             DB.query(
               db,
               "SELECT sessionKey,mechanicalStatus,updatedAt FROM sessions ORDER BY sessionKey"
             )
  end

  defp create_session(db, session_key, display_name, opts \\ []) do
    Org.create(db, %{
      session_key: session_key,
      display_name: display_name,
      kind: Keyword.get(opts, :kind, "custom"),
      is_built_in: Keyword.get(opts, :kind) == "main",
      adopted: true,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: Keyword.get(opts, :spawned_by),
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp canonical_session(db, session_key) do
    db
    |> StateResources.query_session(session_key)
    |> StateResources.session()
  end

  defp enqueue(db, session_key, suffix) do
    Ledger.enqueue(db, %{
      session_key: session_key,
      message_id: "message-#{suffix}",
      origin: "agent:test",
      prompt: suffix
    })
  end

  defp apply_last_version(nil, candidate), do: candidate

  defp apply_last_version(current, candidate) do
    if candidate["rowVersion"] > current["rowVersion"], do: candidate, else: current
  end

  defp receive_notice do
    assert_receive {:firehose_notice, notice}
    Hub.delivered(Hub, self())
    notice
  end

  defp sync_hub, do: :sys.get_state(Hub)
end
