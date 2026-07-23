defmodule Tightbeam.ArtifactsTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{Artifacts, DB, Gateway, Org}

  setup do
    db = :"artifacts_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Org.ensure_schema(db)
    :ok = Artifacts.ensure_schema(db)

    parent = session(db, "parent", nil)
    child = session(db, "child", parent.session_key)

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
    assert first.recorded_message_id == nil
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
      params: %{kind: "doc", title: "Guide", origin_path: "guide.md"}
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
  end

  test "schema is idempotent and enforces the closed kind/state sets", ctx do
    assert :ok = Artifacts.ensure_schema(ctx.db)

    assert {:ok, columns} = DB.query(ctx.db, "PRAGMA table_info(artifacts)")

    assert Enum.map(columns, &Enum.at(&1, 1)) == ~w(
             artifactId kind title description createdBySession workItemId parentSession
             originPath contentSha256 recordedMessageId state home createdAt updatedAt
           )

    assert {:error, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO artifacts
                 (artifactId, kind, title, createdBySession, originPath, state, createdAt, updatedAt)
               VALUES ('art_badkind', 'video', 'Bad', 'child', 'bad', 'in-workspace', 1, 1)
               """
             )

    assert {:error, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO artifacts
                 (artifactId, kind, title, createdBySession, originPath, state, createdAt, updatedAt)
               VALUES ('art_badstate', 'other', 'Bad', 'child', 'bad', 'lost', 1, 1)
               """
             )
  end

  test "missing workspaces still archive rows at their origin pointer", ctx do
    row =
      record(ctx.db, ctx.child.session_key, %{
        kind: "data",
        title: "Dataset",
        origin_path: "/missing/data.json"
      })

    archive_root =
      Path.join(System.tmp_dir!(), "missing-artifacts-#{System.unique_integer([:positive])}")

    assert :ok =
             Artifacts.archive_session(
               ctx.db,
               ctx.child.session_key,
               "/missing/workspace",
               archive_root
             )

    archived = Artifacts.get(ctx.db, row.artifact_id)
    assert archived.state == "archived"
    assert archived.home == "/missing/data.json"
    refute File.exists?(archive_root)
  end

  defp record(db, session_key, params) do
    Artifacts.record(db, %{
      principal: {:session, session_key},
      session_key: session_key,
      params: params
    })
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
