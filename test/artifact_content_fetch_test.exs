defmodule Tightbeam.ArtifactContentFetchTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ArtifactContent, Artifacts, DB, Placement, Schema}

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
      VALUES
        ('content-fixture','content','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1),
        ('unrelated','unrelated','other','user:other','coder','fixture','fixture_provider','fixture-model',1,1);
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
      rest_principal: %{kind: "session", id: "content-fixture", is_admin: false},
      params: %{artifact_id: artifact.artifact_id}
    }

    assert handler.(call).code == "content_not_captured"

    assert handler.(%{
             call
             | principal: {:session, "unrelated"},
               rest_principal: %{kind: "session", id: "unrelated", is_admin: false}
           }).code == "content_not_captured"

    assert handler.(%{
             call
             | principal: {:process, "fixture"},
               rest_principal: %{kind: "process", id: "fixture", is_admin: true}
           }).code == "content_not_captured"

    assert handler.(%{params: call.params}) == %{code: "forbidden"}
  end

  test "an archived home is hashed and returned with its verification status", ctx do
    bytes = <<0, 255, 128, 10>>
    home = Path.join(ctx.workspace, "report.bin")
    File.write!(home, bytes)
    digest = sha256(bytes)

    checked = archived(ctx, home, Placement.local_host_name(), digest)
    unchecked = archived(ctx, home, Placement.local_host_name(), nil)

    assert fetch(ctx, checked) == %{
             artifact_id: checked,
             content_base64: Base.encode64(bytes),
             content_size: byte_size(bytes),
             content_sha256: digest,
             expected_sha256: digest,
             source: "archived_home",
             verification_status: "match"
           }

    assert %{
             content_sha256: ^digest,
             expected_sha256: nil,
             source: "archived_home",
             verification_status: "unverified"
           } = fetch(ctx, unchecked)

    File.write!(home, "later bytes")
    observed = sha256("later bytes")
    result = fetch(ctx, checked)

    assert %{
             code: "artifact_sha_mismatch",
             expected_sha256: ^digest,
             observed_sha256: ^observed,
             verification_status: "mismatch"
           } = result

    assert result.message =~ "recorded sha does not match current bytes"
    refute Map.has_key?(result, :content_base64)
    assert Artifacts.get(ctx.db, checked).content_sha256 == digest
    assert ArtifactContent.fetch(ctx.db, unchecked) == nil
  end

  test "a legacy local pointer resolves after the archive moved and before its row is repointed",
       ctx do
    new_root = Path.join(ctx.root, "relocated")
    Application.put_env(:tightbeam, :archive_dir, new_root)
    on_exit(fn -> Application.delete_env(:tightbeam, :archive_dir) end)
    File.mkdir_p!(Path.join(new_root, "session"))
    File.write!(Path.join(new_root, "session/file"), "archived")
    old_home = Path.join(ctx.root, "archive/session/file")
    id = archived(ctx, old_home, nil, sha256("archived"))

    assert %{source: "archived_home", verification_status: "match"} = fetch(ctx, id)
    assert Artifacts.get(ctx.db, id).home == old_home
    assert ArtifactContent.fetch(ctx.db, id) == nil
  end

  test "a remote home is read via its registered host without consulting the origin", ctx do
    host = "archive-fixture"
    destination = "fixture@archive-fixture"
    base = "/fixture/base"
    assert {:ok, _} = Placement.register_host(ctx.db, host, %{base_dir: base, ssh: destination})
    home = base <> "/archive/session/file with spaces"
    id = archived(ctx, home, host, sha256("remote bytes"))
    caller = self()

    runner = fn argv, collector ->
      send(caller, {:remote_read, argv})
      System.cmd("sh", ["-c", "printf %s 'remote bytes'"], into: collector)
    end

    assert %{source: "archived_home", verification_status: "match"} =
             fetch(ctx, id, %{artifact_archive_runner: runner})

    assert_received {:remote_read, ["ssh" | args]}
    assert destination in args
    assert List.last(args) =~ home
  end

  test "an archived file just over the inline cap returns its complete digest and home", ctx do
    home = Path.join(ctx.workspace, "large.bin")
    limit = 64 * 1024
    bytes = :binary.copy(<<63>>, limit + 1)
    File.write!(home, bytes)
    digest = sha256(bytes)
    id = archived(ctx, home, Placement.local_host_name(), digest)

    result = fetch(ctx, id, %{artifact_archive_inline_limit_bytes: limit})

    assert result.verification_status == "match"
    assert result.archived_home == home
    assert result.content_sha256 == digest
    assert result.content_size == limit + 1
    assert result.content_unavailable_reason =~ "too large to return inline"
    refute Map.has_key?(result, :content_base64)
  end

  defp fetch(ctx, id, config \\ %{}) do
    handler = Tightbeam.Gateway.handlers(Map.merge(%{db: ctx.db, base_dir: ctx.root}, config))

    handler["artifact-content-fetch"].(%{
      principal: {:session, "content-fixture"},
      rest_principal: %{kind: "session", id: "content-fixture", is_admin: false},
      params: %{artifact_id: id}
    })
  end

  defp archived(ctx, home, host, sha) do
    id = "art_archive_fixture_#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO artifacts(artifactId, kind, title, createdBySession, workItemId,
                 originPath, contentSha256, state, home, createdAt, updatedAt, originHost)
               VALUES(?1, 'data', 'Archived fixture', 'content-fixture', 'wi_content_fixture',
                 'workspace-only-origin.bin', ?4, 'archived', ?2, 1, 1, ?3)
               """,
               [id, home, host, sha]
             )

    id
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

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
