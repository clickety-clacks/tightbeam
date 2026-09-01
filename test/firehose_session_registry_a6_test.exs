defmodule Tightbeam.Firehose.SessionRegistryA6Test do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Escalation, Ledger, Model, Org, Projection, Schema, StateResources}
  alias Tightbeam.Firehose.{Hub, Publisher}

  @session_fields ~w(sessionKey displayName kind orderIndex isBuiltIn adopted ownerUserId origin spawnedBy handle archetype overrides identityName identityRevision harness provider model thinkingLevel modelContext host clearedThroughSeq state createdAt updatedAt mechanicalStatus rowVersion)
  @catalog %{
    {"testhost", "claude"} => [
      %{family: "fable", context: nil, efforts: [], provider: :anthropic}
    ]
  }

  setup do
    db = :firehose_session_registry_a6_db
    start_supervised!({DB, path: ":memory:", name: db}, id: :a6_migration_db)
    start_supervised!({Hub, name: Hub})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('flynn',1,'admin_add',1)"
      )

    register_hosts(db, %{
      "testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}
    })

    main = create_session(db, Org.personal_session_key("flynn"), "Main", kind: "main")
    worker = create_session(db, "a6-worker", "A6 worker", operational_parent: main.session_key)

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
    assert payload["overrides"] == nil
    assert is_boolean(payload["isBuiltIn"])
    assert is_boolean(payload["adopted"])
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

  test "the shared query selects one closed scalar R7 item through the AU4 detail seam", ctx do
    query_row = StateResources.query_session(ctx.db, ctx.worker.session_key)
    item = StateResources.session(query_row)

    assert MapSet.new(Map.keys(item)) == MapSet.new(@session_fields)
    assert item["model"] == "fable"
    assert item["thinkingLevel"] == nil
    assert item["modelContext"] == nil
    assert is_integer(item["rowVersion"])

    for forbidden <- [
          "cliToken",
          "operationalParent",
          "effectiveParent",
          "effectiveParentSource",
          "identityGuidanceDigest",
          "identityRenderContract"
        ] do
      refute Map.has_key?(item, forbidden)
    end

    expected_bytes = StateResources.encode_item("sessions", item, @catalog)
    :rand.seed(:exsss, {7, 17, 71})

    for _iteration <- 1..1_000 do
      randomized = item |> Map.to_list() |> Enum.shuffle() |> Map.new()
      assert StateResources.session(randomized) == item
      assert StateResources.encode_item("sessions", randomized, @catalog) == expected_bytes
    end

    owner = %{kind: "user", id: "flynn", is_admin: false}
    target = %{kind: "session", id: ctx.worker.session_key, is_admin: false}
    denied_user = %{kind: "user", id: "mallory", is_admin: false}
    denied_session = %{kind: "session", id: "other-session", is_admin: false}
    admin = %{kind: "user", id: "admin", is_admin: true}

    assert StateResources.query_session(ctx.db, %{key: ctx.worker.session_key, principal: owner}) ==
             query_row

    assert StateResources.query_session(ctx.db, %{key: ctx.worker.session_key, principal: target}) ==
             query_row

    assert StateResources.query_session(ctx.db, %{key: ctx.worker.session_key, principal: admin}) ==
             query_row

    assert StateResources.query_session(ctx.db, %{
             key: ctx.worker.session_key,
             principal: denied_user
           }) == nil

    assert StateResources.query_session(ctx.db, %{
             key: ctx.worker.session_key,
             principal: denied_session
           }) == nil

    assert StateResources.query_session(ctx.db, %{key: "unknown", principal: denied_user}) == nil

    assert_raise ArgumentError, ~r/normative enum domain/, fn ->
      query_row |> Map.put(:state, "unknown") |> StateResources.session()
    end

    assert_raise ArgumentError, ~r/extra or missing field/, fn ->
      item |> Map.put("effectiveParent", "secret-storage-shape") |> StateResources.session()
    end

    assert_raise ArgumentError, ~r/extra or missing field/, fn ->
      item
      |> Map.put("overrides", %{"skills_add" => ["review"]})
      |> StateResources.session()
    end

    overridden =
      create_session(ctx.db, "a6-overridden", "Overridden worker",
        overrides: %{"skills_add" => ["review"]}
      )

    assert overridden.overrides == %{"skills_add" => ["review"]}

    assert canonical_session(ctx.db, overridden.session_key)["overrides"] == %{
             "skillsAdd" => ["review"],
             "guidanceExtra" => nil
           }
  end

  test "real Publisher paths emit byte-identical spawned updated and retired R7 items", ctx do
    session = create_session(ctx.db, "a6-lifecycle", "Lifecycle worker")

    :ok =
      Hub.subscribe(Hub, self(), "session-lifecycle", %{
        "classes" => ["session."],
        "sessionKey" => session.session_key
      })

    spawned =
      Publisher.state_notice(
        ctx.db,
        %{
          verb: "spawn",
          origin: "user:flynn",
          principal: {:user, "flynn"},
          session_key: session.session_key,
          params: %{}
        },
        session
      )

    spawned_item = canonical_session(ctx.db, session.session_key)

    _updated = Org.rename(ctx.db, session.session_key, "Updated lifecycle worker")
    updated = receive_notice()
    updated_item = canonical_session(ctx.db, session.session_key)

    retired_row = Org.retire(ctx.db, session.session_key, "user:flynn", 1_000)

    retired =
      Publisher.committed_notice("session.retired", retired_row, %{
        "sessionKey" => session.session_key
      })

    retired_item = canonical_session(ctx.db, session.session_key)

    assert Enum.map([spawned, updated, retired], & &1["class"]) == [
             "session.spawned",
             "session.updated",
             "session.retired"
           ]

    for {notice, query_item} <-
          Enum.zip([spawned, updated, retired], [spawned_item, updated_item, retired_item]) do
      payload = notice["payload"]

      assert MapSet.new(Map.keys(payload)) == MapSet.new(@session_fields)
      assert payload["sessionKey"] == notice["refs"]["sessionKey"]
      assert payload == query_item

      item_bytes = StateResources.encode_item("sessions", payload, @catalog)
      wire = Publisher.encode_wire_notice(notice, @catalog)
      assert wire =~ "\"payload\":" <> item_bytes
    end
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

    :ok = Ledger.finish(ctx.db, first, "delivered", nil, owner_lease: first_turn.owner_lease)
    sync_hub()
    refute_receive {:firehose_notice, _notice}, 50

    {:ok, second_turn} = Ledger.claim_next(ctx.db, ctx.worker.session_key, "lane")
    assert second_turn.seq == second
    sync_hub()
    refute_receive {:firehose_notice, _notice}, 50

    :ok = Ledger.finish(ctx.db, second, "delivered", nil, owner_lease: second_turn.owner_lease)
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

  test "v11 migration materializes status and advances every changed public item version" do
    db = :firehose_session_registry_a6_migration_db
    start_supervised!({DB, path: ":memory:", name: db})

    :ok =
      DB.execute(
        db,
        """
        CREATE TABLE schema_stamp (shape TEXT PRIMARY KEY, stampedAt INTEGER NOT NULL);
        INSERT INTO schema_stamp VALUES ('coordination-fabric-v1-phase1-v11', 1);
        CREATE TABLE sessions (sessionKey TEXT PRIMARY KEY, updatedAt INTEGER NOT NULL);
        INSERT INTO sessions VALUES ('idle-session', 10), ('running-session', 20);
        CREATE TABLE turns (sessionKey TEXT NOT NULL, status TEXT NOT NULL);
        INSERT INTO turns VALUES ('running-session', 'queued');
        """
      )

    # v11's full schema includes decision requests. The mechanical-status
    # migration now continues through the ruled-decision rebuild, so this
    # isolated fixture must carry that predecessor table as well.
    :ok = Escalation.ensure_schema(db)

    :ok = Schema.upgrade_session_mechanical_status_v1(db)

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

    assert {:ok, [["coordination-fabric-v1-phase1-v15"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")
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
      operational_parent: Keyword.get(opts, :operational_parent),
      archetype: "default",
      overrides: Keyword.get(opts, :overrides),
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
