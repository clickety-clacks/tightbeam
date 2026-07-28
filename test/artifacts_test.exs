defmodule Tightbeam.ArtifactsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Artifacts, DB, Gateway, Org, Projection, WorkItems}

  setup do
    db = :"artifacts_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Org.ensure_schema(db)
    :ok = Projection.ensure_schema(db)
    :ok = WorkItems.ensure_schema(db)
    :ok = Artifacts.ensure_schema(db)

    parent = session(db, "parent", nil)
    child = session(db, "child", parent.session_key)
    seed_work_items(db)
    seed_message(db, parent.session_key)
    seed_message(db, child.session_key)

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
      recorded_message_id: "msg_child",
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

    assert handlers["artifact-record"].(%{
             principal: {:session, ctx.child.session_key},
             session_key: ctx.child.session_key,
             params: call.params
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
             originPath contentSha256 recordedMessageId state home createdAt updatedAt
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

  test "persistent compatible legacy rows migrate with all provenance foreign keys", _ctx do
    path = persistent_db_path("compatible")
    first_db = :"legacy_compatible_first_#{System.unique_integer([:positive])}"
    first_id = {:legacy_compatible_first, first_db}

    on_exit(fn -> File.rm(path) end)

    start_db(first_id, first_db, path)
    seed_legacy_database(first_db)

    {:ok, _} =
      DB.query(
        first_db,
        """
        INSERT INTO artifacts
          (artifactId, kind, title, createdBySession, workItemId, parentSession,
           originPath, recordedMessageId, state, home, createdAt, updatedAt)
        VALUES ('art_legacy', 'spec', 'Legacy spec', 'child', 'wi_banana', 'parent',
                'specs/legacy.md', 'msg_child', 'archived', '/archive/specs/legacy.md', 1, 2)
        """
      )

    stop_supervised!(first_id)

    second_db = :"legacy_compatible_second_#{System.unique_integer([:positive])}"
    second_id = {:legacy_compatible_second, second_db}
    start_db(second_id, second_db, path)

    assert :ok = Artifacts.ensure_schema(second_db)

    assert Artifacts.get(second_db, "art_legacy") == %{
             artifact_id: "art_legacy",
             kind: "spec",
             title: "Legacy spec",
             description: nil,
             created_by_session: "child",
             work_item_id: "wi_banana",
             parent_session: "parent",
             origin_path: "specs/legacy.md",
             content_sha256: nil,
             recorded_message_id: "msg_child",
             state: "archived",
             home: "/archive/specs/legacy.md",
             created_at: 1,
             updated_at: 2
           }

    assert {:ok, foreign_keys} = DB.query(second_db, "PRAGMA foreign_key_list(artifacts)")

    assert MapSet.new(Enum.map(foreign_keys, fn row -> {Enum.at(row, 3), Enum.at(row, 2)} end)) ==
             MapSet.new([
               {"createdBySession", "sessions"},
               {"workItemId", "work_items"},
               {"parentSession", "sessions"},
               {"recordedMessageId", "messages"}
             ])

    assert {:error, _} =
             DB.query(
               second_db,
               """
               INSERT INTO artifacts
                 (artifactId, kind, title, createdBySession, workItemId, originPath,
                  recordedMessageId, state, createdAt, updatedAt)
               VALUES ('art_invalid_edge', 'other', 'Invalid', 'child', 'wi_missing',
                       'invalid', 'msg_child', 'in-workspace', 3, 3)
               """
             )
  end

  test "persistent main-written null provenance row rolls migration back intact", _ctx do
    path = persistent_db_path("rollback")
    first_db = :"legacy_rollback_first_#{System.unique_integer([:positive])}"
    first_id = {:legacy_rollback_first, first_db}

    on_exit(fn -> File.rm(path) end)

    start_db(first_id, first_db, path)
    seed_legacy_database(first_db)

    {:ok, _} =
      DB.query(
        first_db,
        """
        INSERT INTO artifacts
          (artifactId, kind, title, createdBySession, workItemId, parentSession,
           originPath, recordedMessageId, state, home, createdAt, updatedAt)
        VALUES ('art_main_writer', 'report', 'Main writer row', 'child', 'wi_banana',
                'parent', 'reports/main.md', NULL, 'in-workspace', NULL, 1, 1)
        """
      )

    stop_supervised!(first_id)

    second_db = :"legacy_rollback_second_#{System.unique_integer([:positive])}"
    second_id = {:legacy_rollback_second, second_db}
    start_db(second_id, second_db, path)

    assert {:error, %DB.Error{message: message}} = Artifacts.ensure_schema(second_db)
    assert message =~ "NOT NULL constraint failed: artifacts_new.recordedMessageId"

    assert {:ok, [["art_main_writer", nil]]} =
             DB.query(
               second_db,
               "SELECT artifactId, recordedMessageId FROM artifacts"
             )

    assert {:ok, []} = DB.query(second_db, "PRAGMA foreign_key_list(artifacts)")

    assert {:ok, []} =
             DB.query(
               second_db,
               "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'artifacts_new'"
             )

    assert {:ok, [[1]]} = DB.query(second_db, "PRAGMA foreign_keys")
  end

  test "archives the exact artifact home and release clears custody location", ctx do
    workspace =
      Path.join(System.tmp_dir!(), "artifact-workspace-#{System.unique_integer([:positive])}")

    archive_root =
      Path.join(System.tmp_dir!(), "artifact-archive-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "reports"))
    File.write!(Path.join(workspace, "reports/result.md"), "durable result")

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(archive_root)
    end)

    row =
      record(ctx.db, ctx.child.session_key, %{
        kind: "report",
        title: "Result",
        origin_path: "reports/result.md",
        work_item_id: "wi_banana"
      })

    assert :ok =
             Artifacts.archive_session(
               ctx.db,
               ctx.child.session_key,
               workspace,
               archive_root
             )

    archived = Artifacts.get(ctx.db, row.artifact_id)
    [archive_dir_name] = File.ls!(archive_root)

    assert archived.state == "archived"
    assert archived.home == Path.join([archive_root, archive_dir_name, "reports/result.md"])
    assert File.read!(archived.home) == "durable result"
    refute File.exists?(workspace)

    released = Artifacts.release(ctx.db, row.artifact_id)
    assert released.state == "released"
    assert released.home == nil
    assert released.artifact_id == row.artifact_id
  end

  test "archive failure preserves in-workspace truth instead of inventing custody", ctx do
    row =
      record(ctx.db, ctx.child.session_key, %{
        kind: "data",
        title: "Dataset",
        origin_path: "/missing/data.json"
      })

    archive_root =
      Path.join(System.tmp_dir!(), "missing-artifacts-#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, "workspace is unavailable for artifact archival", fn ->
      Artifacts.archive_session(
        ctx.db,
        ctx.child.session_key,
        "/missing/workspace",
        archive_root
      )
    end

    unchanged = Artifacts.get(ctx.db, row.artifact_id)
    assert unchanged.state == "in-workspace"
    assert unchanged.home == nil
    refute File.exists?(archive_root)
  end

  test "acceptance 7: an origin outside the workspace is external — released, and nothing raises",
       ctx do
    workspace =
      Path.join(System.tmp_dir!(), "artifact-workspace-#{System.unique_integer([:positive])}")

    outside =
      Path.join(System.tmp_dir!(), "outside-artifact-#{System.unique_integer([:positive])}.md")

    archive_root =
      Path.join(System.tmp_dir!(), "artifact-archive-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(outside, "not in workspace")

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm(outside)
      File.rm_rf(archive_root)
    end)

    row =
      record(ctx.db, ctx.child.session_key, %{
        kind: "doc",
        title: "Outside",
        origin_path: outside
      })

    # The work happened somewhere Tightbeam does not hold. The ROW is the
    # record; there is nothing to take into custody, and nothing raises.
    assert :ok = Artifacts.archive_session(ctx.db, ctx.child.session_key, workspace, archive_root)

    external = Artifacts.get(ctx.db, row.artifact_id)
    assert external.state == "released"
    assert external.home == nil
    assert external.origin_path == outside
    assert File.read!(outside) == "not in workspace"
    refute File.exists?(workspace)
    refute File.exists?(archive_root)
  end

  test "canonical custody accepts an internal symlink and records the archived target", ctx do
    workspace =
      Path.join(System.tmp_dir!(), "artifact-workspace-#{System.unique_integer([:positive])}")

    archive_root =
      Path.join(System.tmp_dir!(), "artifact-archive-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "data"))
    File.write!(Path.join(workspace, "data/inside.md"), "inside")
    File.ln_s!("data/inside.md", Path.join(workspace, "inside-link.md"))

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(archive_root)
    end)

    row =
      record(ctx.db, ctx.child.session_key, %{
        kind: "doc",
        title: "Internal symlink",
        origin_path: "inside-link.md"
      })

    assert :ok =
             Artifacts.archive_session(
               ctx.db,
               ctx.child.session_key,
               workspace,
               archive_root
             )

    [archive_dir_name] = File.ls!(archive_root)
    archived = Artifacts.get(ctx.db, row.artifact_id)

    assert archived.state == "archived"
    assert archived.home == Path.join([archive_root, archive_dir_name, "data/inside.md"])
    assert File.read!(archived.home) == "inside"
    refute File.exists?(workspace)
  end

  test "a symlink to bytes outside the workspace is external, not custody", ctx do
    workspace =
      Path.join(System.tmp_dir!(), "artifact-workspace-#{System.unique_integer([:positive])}")

    outside =
      Path.join(System.tmp_dir!(), "outside-artifact-#{System.unique_integer([:positive])}.md")

    archive_root =
      Path.join(System.tmp_dir!(), "artifact-archive-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(workspace, "outside-link.md"))

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm(outside)
      File.rm_rf(archive_root)
    end)

    row =
      record(ctx.db, ctx.child.session_key, %{
        kind: "doc",
        title: "External symlink",
        origin_path: "outside-link.md"
      })

    # The bytes live outside the workspace, so the link is a pointer at external
    # work — released, never claimed as custody Tightbeam does not have.
    assert :ok = Artifacts.archive_session(ctx.db, ctx.child.session_key, workspace, archive_root)

    external = Artifacts.get(ctx.db, row.artifact_id)
    assert external.state == "released"
    assert external.home == nil
    assert File.read!(outside) == "outside"
    refute File.exists?(workspace)
    refute File.exists?(archive_root)
  end

  test "valid artifacts archive beside each external and unreadable mixed-row class", ctx do
    for invalid_kind <- [:outside, :missing, :external_symlink] do
      suffix = "#{invalid_kind}-#{System.unique_integer([:positive])}"
      session_key = "mixed-#{suffix}"
      workspace = Path.join(System.tmp_dir!(), "artifact-workspace-#{suffix}")
      archive_root = Path.join(System.tmp_dir!(), "artifact-archive-#{suffix}")
      outside = Path.join(System.tmp_dir!(), "outside-artifact-#{suffix}.md")

      session(ctx.db, session_key, nil)
      seed_message(ctx.db, session_key)
      File.mkdir_p!(Path.join(workspace, "reports"))
      File.write!(Path.join(workspace, "reports/valid.md"), "valid #{invalid_kind}")
      File.write!(outside, "outside #{invalid_kind}")

      invalid_origin =
        case invalid_kind do
          :outside ->
            outside

          :missing ->
            "reports/missing.md"

          :external_symlink ->
            File.ln_s!(outside, Path.join(workspace, "reports/escape.md"))
            "reports/escape.md"
        end

      valid =
        record(ctx.db, session_key, %{
          kind: "report",
          title: "Valid #{invalid_kind}",
          origin_path: "reports/valid.md"
        })

      invalid =
        record(ctx.db, session_key, %{
          kind: "report",
          title: "Invalid #{invalid_kind}",
          origin_path: invalid_origin
        })

      assert :ok =
               Artifacts.archive_session(
                 ctx.db,
                 session_key,
                 workspace,
                 archive_root
               )

      [archive_dir_name] = File.ls!(archive_root)
      archived = Artifacts.get(ctx.db, valid.artifact_id)
      other = Artifacts.get(ctx.db, invalid.artifact_id)

      assert archived.state == "archived"

      assert archived.home ==
               Path.join([archive_root, archive_dir_name, "reports/valid.md"])

      assert File.read!(archived.home) == "valid #{invalid_kind}"

      # An origin OUTSIDE the workspace (directly or through a link) is external
      # work, released. An origin inside the workspace that is not there at all
      # is neither: nothing was released, so the row stays as recorded.
      case invalid_kind do
        :missing ->
          assert other.state == "in-workspace"
          assert other.home == nil

        _external ->
          assert other.state == "released"
          assert other.home == nil
      end

      refute File.exists?(workspace)

      File.rm_rf!(archive_root)
      File.rm!(outside)
    end
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

  defp record(db, session_key, params) do
    Artifacts.record(db, %{
      principal: {:session, session_key},
      session_key: session_key,
      recorded_message_id: Map.get(params, :recorded_message_id, "msg_#{session_key}"),
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

  defp start_db(id, name, path) do
    start_supervised!(%{
      id: id,
      start: {DB, :start_link, [[path: path, name: name]]}
    })
  end

  defp seed_legacy_database(db) do
    :ok = Org.ensure_schema(db)
    :ok = Projection.ensure_schema(db)
    :ok = WorkItems.ensure_schema(db)
    parent = session(db, "parent", nil)
    _child = session(db, "child", parent.session_key)
    seed_work_items(db)
    seed_message(db, parent.session_key)
    seed_message(db, "child")
    :ok = DB.execute(db, legacy_artifacts_ddl())
  end

  defp legacy_artifacts_ddl do
    """
    CREATE TABLE artifacts (
      artifactId        TEXT PRIMARY KEY,
      kind              TEXT NOT NULL CHECK (kind IN ('spec','report','doc','data','other')),
      title             TEXT NOT NULL,
      description       TEXT,
      createdBySession  TEXT NOT NULL,
      workItemId        TEXT,
      parentSession     TEXT,
      originPath        TEXT NOT NULL,
      contentSha256     TEXT,
      recordedMessageId INTEGER,
      state             TEXT NOT NULL DEFAULT 'in-workspace'
                        CHECK (state IN ('in-workspace','archived','released')),
      home              TEXT,
      createdAt         INTEGER NOT NULL,
      updatedAt         INTEGER NOT NULL
    );
    CREATE INDEX artifacts_work_item ON artifacts (workItemId);
    CREATE INDEX artifacts_created_by_session ON artifacts (createdBySession);
    """
  end

  defp persistent_db_path(suffix) do
    Path.join(
      System.tmp_dir!(),
      "artifacts-legacy-#{suffix}-#{System.unique_integer([:positive])}.sqlite3"
    )
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
      model: "fable"
    })
  end
end
