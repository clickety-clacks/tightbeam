[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
import ExUnit.Assertions
alias Tightbeam.{ArtifactContent, Artifacts, DB, Schema}

opts = [path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks]]
{:ok, db} = DB.start_link(opts)
:ok = Schema.ensure_all(db)
:ok = DB.assert_base_admitted!(db, base)
workspace = Path.join(base, "workspace")
File.mkdir_p!(workspace)

:ok =
  DB.execute(db, """
  INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
  VALUES('content-fixture','content','fixture','user:fixture','coder','fixture','fixture_provider','fixture-model',1,1);
  INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt)
  VALUES('wi_content_fixture','Content fixture','fixture','fixture',1);
  """)

expected =
  try do
    recorded =
      for {filename, bytes} <- [{"binary.dat", <<0, 255, 128, 13, 10>>}, {"empty.dat", <<>>}] do
        File.write!(Path.join(workspace, filename), bytes)

        artifact =
          Artifacts.record(db, %{
            principal: {:session, "content-fixture"},
            session_key: "content-fixture",
            params: %{
              kind: "data",
              title: "Stored bytes",
              origin_path: filename,
              work_item_id: "wi_content_fixture"
            }
          })

        assert ArtifactContent.fetch(db, artifact.artifact_id) == nil
        {artifact, bytes}
      end

    assert :ok =
             Artifacts.archive_session(
               db,
               "content-fixture",
               workspace,
               Path.join(base, "archive")
             )

    refute File.exists?(workspace)

    for {artifact, bytes} <- recorded do
      archived = Artifacts.get(db, artifact.artifact_id)
      assert archived.state == "archived"
      assert File.read!(archived.home) == bytes

      fetched = %{
        artifact_id: artifact.artifact_id,
        content_sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        content_size: byte_size(bytes),
        content: bytes
      }

      assert ArtifactContent.fetch(db, artifact.artifact_id) == fetched
      File.rm!(archived.home)
      assert Artifacts.release(db, artifact.artifact_id).state == "released"
      assert ArtifactContent.fetch(db, artifact.artifact_id) == fetched
      fetched
    end
  after
    GenServer.stop(db)
  end

{:ok, reopened} = DB.start_link(opts)

try do
  :ok = Schema.ensure_all(reopened)
  :ok = DB.assert_base_admitted!(reopened, base)

  for fetched <- expected do
    assert ArtifactContent.fetch(reopened, fetched.artifact_id) == fetched
    assert Artifacts.get(reopened, fetched.artifact_id).state == "released"
  end

  IO.puts("artifact-content-fetch-restart: ok")
after
  GenServer.stop(reopened)
end
