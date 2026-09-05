defmodule Tightbeam.ArtifactsTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{ArtifactContent, Artifacts, DB, Gateway, Ledger, Org, Projection, WorkItems}

  setup do
    db = :"artifacts_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Org.ensure_schema(db)
    :ok = Projection.ensure_schema(db)
    :ok = WorkItems.ensure_schema(db)
    :ok = Ledger.ensure_schema(db)
    :ok = Artifacts.ensure_schema(db)
    :ok = ArtifactContent.ensure_schema(db)

    parent = session(db, "parent", nil)
    child = session(db, "child", parent.session_key)
    seed_work_items(db)
    seed_running_turn(db, parent.session_key)
    seed_running_turn(db, child.session_key)

    %{db: db, parent: parent, child: child}
  end

  test "records pointer provenance and supports exact AND filters newest first", ctx do
    first =
      record(ctx.db, ctx.child.session_key, %{
        kind: "spec",
        title: "Banana spec",
        description: "Ratified",
        origin_path: "specs/banana.md",
        work_item_id: "wi_banana",
        content_sha256: "abc123"
      })

    second =
      record(ctx.db, ctx.child.session_key, %{
        kind: "report",
        title: "Banana report",
        origin_path: "reports/banana.md",
        work_item_id: "wi_banana"
      })

    third =
      record(ctx.db, ctx.parent.session_key, %{
        kind: "spec",
        title: "Other spec",
        origin_path: "other.md",
        work_item_id: "wi_other"
      })

    for {row, created_at} <- [{first, 1}, {second, 2}, {third, 3}] do
      {:ok, _} =
        DB.query(ctx.db, "UPDATE artifacts SET createdAt = ?2 WHERE artifactId = ?1", [
          row.artifact_id,
          created_at
        ])
    end

    first = Artifacts.get(ctx.db, first.artifact_id)
    second = Artifacts.get(ctx.db, second.artifact_id)
    third = Artifacts.get(ctx.db, third.artifact_id)

    assert first.artifact_id =~ ~r/^art_[0-9a-f]{8}$/
    assert first.created_by_session == ctx.child.session_key
    assert first.parent_session == ctx.parent.session_key
    assert first.recorded_message_id == "msg_child"
    assert first.recorded_turn_evidence == "session-concurrent"
    assert first.state == "in-workspace"
    assert first.home == nil
    assert first.origin_path == "specs/banana.md"
    assert first.content_sha256 == "abc123"

    assert Artifacts.get(ctx.db, first.artifact_id) == first

    assert Enum.map(Artifacts.list(ctx.db), & &1.artifact_id) == [
             third.artifact_id,
             second.artifact_id,
             first.artifact_id
           ]

    assert Enum.map(Artifacts.list(ctx.db, %{work_item_id: "wi_banana"}), & &1.artifact_id) ==
             [second.artifact_id, first.artifact_id]

    assert Enum.map(
             Artifacts.list(ctx.db, %{
               work_item_id: "wi_banana",
               session_key: ctx.child.session_key,
               kind: "spec"
             }),
             & &1.artifact_id
           ) == [first.artifact_id]
  end

  test "gateway verbs return rows, filtered lists, not-found, and the session-caller error",
       ctx do
    handlers = Gateway.handlers(%{db: ctx.db})

    call = %{
      principal: {:session, ctx.child.session_key},
      session_key: ctx.child.session_key,
      params: %{
        kind: "doc",
        title: "Guide",
        origin_path: "guide.md",
        work_item_id: "wi_banana"
      }
    }

    row = handlers["artifact-record"].(call)
    assert handlers["artifact-get"].(%{params: %{artifact_id: row.artifact_id}}) == row

    assert handlers["artifacts"].(%{
             params: %{session_key: ctx.child.session_key, kind: "doc"}
           }) == %{artifacts: [row]}

    assert handlers["artifact-get"].(%{params: %{artifact_id: "art_missing"}}) == %{
             code: "not_found"
           }

    assert handlers["artifact-record"].(%{
             principal: {:user, "flynn"},
             session_key: nil,
             params: call.params
           }) == %{
             code: "invalid",
             message: "artifact-record requires a session caller"
           }

    # The turn edge no longer gates the verb — clause 12's work-item edge, which
    # this ruling leaves open, is the only thing left that can refuse here.
    assert handlers["artifact-record"].(%{
             principal: {:session, ctx.child.session_key},
             session_key: ctx.child.session_key,
             params: Map.delete(call.params, :work_item_id)
           }) == %{
             code: "invalid",
             message: "artifact-record requires provenance edges"
           }

    assert Artifacts.list(ctx.db, %{session_key: ctx.child.session_key}) == [row]
  end

  test "schema is idempotent and enforces the closed kind/state sets", ctx do
    assert :ok = Artifacts.ensure_schema(ctx.db)

    assert {:ok, columns} = DB.query(ctx.db, "PRAGMA table_info(artifacts)")

    assert Enum.map(columns, &Enum.at(&1, 1)) == ~w(
             artifactId kind title description createdBySession workItemId parentSession
             originPath contentSha256 recordedMessageId recordedTurnEvidence state home
             createdAt updatedAt
           )

    # NULLABLE now, and paired with a closed evidence domain.
    assert Enum.find(columns, &(Enum.at(&1, 1) == "recordedMessageId")) |> Enum.at(3) == 0
    assert Enum.find(columns, &(Enum.at(&1, 1) == "recordedTurnEvidence")) |> Enum.at(3) == 1

    for class <- ~w(tool-call-observed session-concurrent none) do
      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 """
                 INSERT INTO artifacts
                   (artifactId, kind, title, createdBySession, workItemId, originPath,
                    recordedMessageId, recordedTurnEvidence, state, createdAt, updatedAt)
                 VALUES (?1, 'other', 'Class', 'child', 'wi_banana', 'ok',
                         NULL, ?2, 'in-workspace', 1, 1)
                 """,
                 ["art_class_#{class}", class]
               )
    end

    assert {:error, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO artifacts
                 (artifactId, kind, title, createdBySession, workItemId, originPath,
                  recordedMessageId, recordedTurnEvidence, state, createdAt, updatedAt)
               VALUES ('art_badevidence', 'other', 'Bad', 'child', 'wi_banana', 'bad',
                       NULL, 'hook-proven', 'in-workspace', 1, 1)
               """
             )

    assert {:ok, foreign_keys} = DB.query(ctx.db, "PRAGMA foreign_key_list(artifacts)")

    assert MapSet.new(Enum.map(foreign_keys, fn row -> {Enum.at(row, 3), Enum.at(row, 2)} end)) ==
             MapSet.new([
               {"createdBySession", "sessions"},
               {"workItemId", "work_items"},
               {"parentSession", "sessions"},
               {"recordedMessageId", "messages"}
             ])

    assert {:error, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO artifacts
                 (artifactId, kind, title, createdBySession, workItemId, originPath,
                  recordedMessageId, state, createdAt, updatedAt)
               VALUES ('art_badkind', 'video', 'Bad', 'child', 'wi_banana', 'bad',
                       'msg_child', 'in-workspace', 1, 1)
               """
             )

    assert {:error, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO artifacts
                 (artifactId, kind, title, createdBySession, workItemId, originPath,
                  recordedMessageId, state, createdAt, updatedAt)
               VALUES ('art_badstate', 'other', 'Bad', 'child', 'wi_banana', 'bad',
                       'msg_child', 'lost', 1, 1)
               """
             )

    for {artifact_id, work_item_id, message_id} <- [
          {"art_badwork", "wi_missing", "msg_child"},
          {"art_badmessage", "wi_banana", "msg_missing"}
        ] do
      assert {:error, _} =
               DB.query(
                 ctx.db,
                 """
                 INSERT INTO artifacts
                   (artifactId, kind, title, createdBySession, workItemId, originPath,
                    recordedMessageId, state, createdAt, updatedAt)
                 VALUES (?1, 'other', 'Bad', 'child', ?2, 'bad', ?3, 'in-workspace', 1, 1)
                 """,
                 [artifact_id, work_item_id, message_id]
               )
    end

    assert {:error, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO artifacts
                 (artifactId, kind, title, createdBySession, workItemId, originPath,
                  recordedMessageId, state, home, createdAt, updatedAt)
               VALUES ('art_released_home', 'other', 'Bad', 'child', 'wi_banana', 'bad',
                       'msg_child', 'released', '/claimed/home', 1, 1)
               """
             )
  end

  test "capture stores exact binary content and releases with the gateway hash", ctx do
    content = <<0, 255, 10, 65, 0, 66>>
    expected = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    row =
      Artifacts.record(ctx.db, %{
        principal: {:session, ctx.child.session_key},
        session_key: ctx.child.session_key,
        artifact_content: content,
        params: %{
          kind: "data",
          title: "Exact bytes",
          origin_path: "result.bin",
          work_item_id: "wi_banana",
          content_sha256: expected
        }
      })

    assert row.state == "released"
    assert row.content_sha256 == expected

    assert {:ok, %{content: ^content, sha256: ^expected, size: 6}} =
             ArtifactContent.fetch(ctx.db, row.artifact_id)
  end

  test "a caller hash mismatch refuses atomically", ctx do
    before_count = artifact_count(ctx.db)

    assert Artifacts.record(ctx.db, %{
             principal: {:session, ctx.child.session_key},
             session_key: ctx.child.session_key,
             artifact_content: "actual",
             params: %{
               kind: "report",
               title: "Mismatch",
               origin_path: "result.md",
               work_item_id: "wi_banana",
               content_sha256: String.duplicate("0", 64)
             }
           }) == %{
             code: "artifact_content_hash_mismatch",
             message: "artifact content does not match contentSha256"
           }

    assert artifact_count(ctx.db) == before_count
  end

  test "released state is refused without matching durable content", ctx do
    row =
      record(ctx.db, ctx.child.session_key, %{
        kind: "report",
        title: "Pointer only",
        origin_path: "result.md"
      })

    assert {:error, error} =
             DB.query(ctx.db, "UPDATE artifacts SET state='released' WHERE artifactId=?1", [
               row.artifact_id
             ])

    assert Exception.message(error) =~ "artifact_content_not_durable"
    assert Artifacts.get(ctx.db, row.artifact_id).state == "in-workspace"
  end

  test "retirement cleanup removes the origin workspace but keeps fetchable content", ctx do
    workspace =
      Path.join(System.tmp_dir!(), "artifact-workspace-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "result.md"), "durable result")
    on_exit(fn -> File.rm_rf(workspace) end)

    row =
      Artifacts.record(ctx.db, %{
        principal: {:session, ctx.child.session_key},
        session_key: ctx.child.session_key,
        artifact_content: "durable result",
        params: %{
          kind: "report",
          title: "Result",
          origin_path: "result.md",
          work_item_id: "wi_banana"
        }
      })

    assert :ok = Artifacts.archive_session(ctx.db, ctx.child.session_key, workspace, "/unused")
    refute File.exists?(workspace)
    assert {:ok, %{content: "durable result"}} = ArtifactContent.fetch(ctx.db, row.artifact_id)
  end

  test "released content survives author workspace removal and a database-owner restart" do
    unique = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "artifact-content-restart-#{unique}.sqlite3")
    first = :"artifact_content_before_#{unique}"
    second = :"artifact_content_after_#{unique}"
    workspace = Path.join(System.tmp_dir!(), "artifact-origin-#{unique}")

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm(path)
      File.rm("#{path}-shm")
      File.rm("#{path}-wal")
    end)

    {:ok, first_pid} = DB.start_link(path: path, name: first)
    :ok = Org.ensure_schema(first)
    :ok = Projection.ensure_schema(first)
    :ok = WorkItems.ensure_schema(first)
    :ok = Ledger.ensure_schema(first)
    :ok = Artifacts.ensure_schema(first)
    :ok = ArtifactContent.ensure_schema(first)
    author = session(first, "restart-author", nil)
    seed_work_items(first)
    seed_running_turn(first, author.session_key)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "result.bin"), <<1, 2, 3, 255>>)

    row =
      Artifacts.record(first, %{
        principal: {:session, author.session_key},
        session_key: author.session_key,
        artifact_content: <<1, 2, 3, 255>>,
        params: %{
          kind: "data",
          title: "Restart proof",
          origin_path: Path.join(workspace, "result.bin"),
          work_item_id: "wi_banana"
        }
      })

    File.rm_rf!(workspace)
    :ok = GenServer.stop(first_pid)

    {:ok, second_pid} = DB.start_link(path: path, name: second)

    assert {:ok, %{content: <<1, 2, 3, 255>>}} =
             ArtifactContent.fetch(second, row.artifact_id)

    :ok = GenServer.stop(second_pid)
  end

  test "retirement cleanup refuses uncaptured metadata and preserves the workspace", ctx do
    workspace =
      Path.join(System.tmp_dir!(), "artifact-workspace-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "result.md"), "only copy")
    on_exit(fn -> File.rm_rf(workspace) end)

    row =
      record(ctx.db, ctx.child.session_key, %{
        kind: "report",
        title: "Pointer only",
        origin_path: "result.md"
      })

    error =
      assert_raise ArtifactContent.RetirementBlockedError, fn ->
        Artifacts.archive_session(ctx.db, ctx.child.session_key, workspace, "/unused")
      end

    assert error.artifact_ids == [row.artifact_id]
    assert File.read!(Path.join(workspace, "result.md")) == "only copy"
    assert Artifacts.get(ctx.db, row.artifact_id).state == "in-workspace"
  end

  test "removes an artifact-free workspace", ctx do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "empty-artifact-workspace-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "scratch.txt"), "discard me")

    assert :ok =
             Artifacts.archive_session(ctx.db, ctx.parent.session_key, workspace, "/unused")

    refute File.exists?(workspace)
  end

  defp artifact_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM artifacts")
    count
  end

  # No `recorded_message_id`: the caller cannot supply one, so the fixture cannot
  # either. The edge these rows carry comes from the running turn `setup` started
  # for the session, which is what a real record has to go through.
  defp record(db, session_key, params) do
    Artifacts.record(db, %{
      principal: {:session, session_key},
      session_key: session_key,
      params: Map.put_new(params, :work_item_id, "wi_banana")
    })
  end

  defp seed_work_items(db) do
    for id <- ~w(wi_banana wi_other) do
      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO work_items
            (id, title, ownerUserId, createdByUser, createdBySession, createdAt)
          VALUES (?1, ?1, 'flynn', 'flynn', NULL, 1)
          """,
          [id]
        )
    end
  end

  defp seed_message(db, session_key) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO messages
          (id, sessionKey, role, content, timestamp, llmVisibleMessageId)
        VALUES (?1, ?2, 'assistant', 'artifact-record', 1, ?1)
        """,
        ["msg_#{session_key}", session_key]
      )
  end

  # A record's turn edge is now derived, so a session that is supposed to end up
  # with one needs a turn actually running — `session-concurrent`, the class an
  # unobserved record gets.
  defp seed_running_turn(db, session_key) do
    seed_message(db, session_key)

    {:ok, _seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "msg_#{session_key}",
        origin: "user:flynn",
        prompt: "record the artifact"
      })

    {:ok, _turn} = Ledger.claim_next(db, session_key, "owner")
    :ok
  end

  defp session(db, key, spawned_by) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: spawned_by,
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end
end
