defmodule Tightbeam.ArtifactContentFetchTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ArtifactContent, Artifacts, DB, Schema}

  setup do
    root = Path.join(System.tmp_dir!(), "artifact-fetch-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "state.db")
    db = start_supervised!({DB, name: :artifact_content_fetch_test, path: ":memory:"})
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
      VALUES('content-fixture','content','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1);
      INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt)
      VALUES('wi_content_fixture','Content fixture','fixture','fixture',1);
      """)

    %{db: db, path: path, root: root, workspace: workspace}
  end

  test "captured binary and empty content remain fetchable without either filesystem copy after restart",
       ctx do
    Tightbeam.GuardRuntimeFixture.run!(
      Path.join(ctx.root, "runtime"),
      "artifact_content_fetch_runtime.exs",
      "artifact-content-fetch-restart: ok"
    )
  end

  test "uncaptured external and missing IDs return no content without following origins", ctx do
    artifact = record(ctx.db, "unreachable-fixture-host:/not/a/local/content/source")

    assert :ok =
             Artifacts.archive_session(
               ctx.db,
               "content-fixture",
               nil,
               Path.join(ctx.root, "unused")
             )

    assert Artifacts.get(ctx.db, artifact.artifact_id).state == "released"
    assert ArtifactContent.fetch(ctx.db, artifact.artifact_id) == nil
    assert ArtifactContent.fetch(ctx.db, "art_missing") == nil
    handler = Tightbeam.Gateway.handlers(%{db: ctx.db})["artifact-content-fetch"]

    call = %{
      principal: {:session, "content-fixture"},
      params: %{artifact_id: artifact.artifact_id}
    }

    assert handler.(call).code == "content_not_captured"
    assert handler.(%{call | principal: {:session, "unrelated"}}) == %{code: "not_found"}
    assert handler.(%{call | principal: {:process, "fixture"}}) == %{code: "forbidden"}
    assert handler.(%{params: call.params}) == %{code: "forbidden"}
  end

  defp record(db, origin) do
    Artifacts.record(db, %{
      principal: {:session, "content-fixture"},
      session_key: "content-fixture",
      params: %{
        kind: "data",
        title: "Stored bytes",
        origin_path: origin,
        work_item_id: "wi_content_fixture"
      }
    })
  end
end
