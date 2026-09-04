defmodule Tightbeam.ArtifactContentTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ArtifactContent, Artifacts, DB, EventLog, Gateway, Model, Org, Schema}

  setup do
    db = :artifact_content_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    session =
      Org.create(db, %{
        session_key: "holder",
        display_name: "holder",
        owner_user_id: "flynn",
        origin: "user:flynn",
        spawned_by: nil,
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO work_items
          (id, title, ownerUserId, createdByUser, createdAt)
        VALUES ('wi_content', 'content', 'flynn', 'flynn', 1)
        """
      )

    base_dir =
      Path.join(System.tmp_dir!(), "artifact-content-#{System.unique_integer([:positive])}")

    source_root = Path.join(base_dir, "workspace")
    File.mkdir_p!(Path.join(source_root, "reports"))
    install_cli!(base_dir)

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{db: db, session: session, base_dir: base_dir, source_root: source_root}
  end

  test "captures helper-opened binary bytes into immutable CAS and releases once", ctx do
    bytes = <<0, 1, 2, 255, "durable", 0, 10>>
    source = Path.join(ctx.source_root, "reports/result.bin")
    File.write!(source, bytes)
    artifact = record(ctx, "reports/result.bin")
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    assert {:ok, released} =
             ArtifactContent.capture(ctx.db, %{
               artifact_id: artifact.artifact_id,
               base_dir: ctx.base_dir,
               source_root: ctx.source_root,
               relative_path: "reports/result.bin",
               expected_digest: digest,
               declared_length: byte_size(bytes),
               quota_bytes: byte_size(bytes),
               reserved_free_bytes: 0,
               principal: "session:holder",
               request: %{
                 principal_kind: "session",
                 principal_id: "holder",
                 operation: "record",
                 idempotency_key: "record-1",
                 request_hash: digest
               }
             })

    assert released.state == "released"
    assert released.content_sha256 == digest
    assert released.content_size == byte_size(bytes)
    assert released.home == nil

    cas = ArtifactContent.cas_path(ctx.base_dir, digest)
    assert File.read!(cas) == bytes
    assert {:ok, %File.Stat{mode: mode}} = File.stat(cas)
    assert Bitwise.band(mode, 0o777) == 0o400

    assert {:ok, [[^digest, size, "verified"]]} =
             DB.query(ctx.db, "SELECT digest, size, status FROM artifact_blobs")

    assert size == byte_size(bytes)

    assert {:ok, replayed} =
             ArtifactContent.capture(ctx.db, %{
               artifact_id: artifact.artifact_id,
               base_dir: ctx.base_dir,
               source_root: ctx.source_root,
               relative_path: "reports/result.bin",
               quota_bytes: byte_size(bytes),
               reserved_free_bytes: 0,
               principal: "session:holder",
               request: %{
                 principal_kind: "session",
                 principal_id: "holder",
                 operation: "record",
                 idempotency_key: "record-1",
                 request_hash: digest
               }
             })

    assert replayed == released

    File.rm!(source)

    assert {:ok, fetched} =
             ArtifactContent.fetch(ctx.db, ctx.base_dir, artifact.artifact_id, "session:holder")

    assert fetched.digest == digest
    assert fetched.size == byte_size(bytes)
    assert fetched.fetch_id =~ ~r/^fetch_[0-9a-f]{32}$/
    assert IO.binread(fetched.descriptor, :eof) == bytes
    File.close(fetched.descriptor)

    completion_call = %{
      principal: {:session, "holder"},
      params: %{
        artifact_id: artifact.artifact_id,
        fetch_id: fetched.fetch_id,
        content_sha256: digest,
        content_size: byte_size(bytes)
      }
    }

    receipt = ArtifactContent.complete_fetch(ctx.db, completion_call)
    assert receipt.completed
    assert ArtifactContent.complete_fetch(ctx.db, completion_call) == receipt
  end

  test "missing exact installed helper fails closed without a release or request", ctx do
    File.rm!(Path.join([ctx.base_dir, "bin", "tightbeam"]))
    File.write!(Path.join(ctx.source_root, "result.txt"), "bytes")
    artifact = record(ctx, "result.txt")

    assert {:error, %{code: "source_unavailable"}} =
             ArtifactContent.capture(ctx.db, capture_opts(ctx, artifact, "result.txt"))

    assert Artifacts.get(ctx.db, artifact.artifact_id).state == "in-workspace"
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM artifact_blobs")
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM artifact_content_requests")
  end

  test "helper refusal for a symlink fails closed and preserves the pointer", ctx do
    File.write!(Path.join(ctx.source_root, "outside.txt"), "outside")
    File.ln_s!("outside.txt", Path.join(ctx.source_root, "link.txt"))
    artifact = record(ctx, "link.txt")

    assert {:error, %{code: "source_unavailable"}} =
             ArtifactContent.capture(ctx.db, capture_opts(ctx, artifact, "link.txt"))

    assert Artifacts.get(ctx.db, artifact.artifact_id).state == "in-workspace"
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM artifact_blobs")
  end

  test "digest mismatch and invalid quota configuration never release", ctx do
    File.write!(Path.join(ctx.source_root, "result.txt"), "bytes")
    artifact = record(ctx, "result.txt")

    assert {:error, %{code: "content_digest_mismatch"}} =
             ArtifactContent.capture(
               ctx.db,
               Map.put(
                 capture_opts(ctx, artifact, "result.txt"),
                 :expected_digest,
                 String.duplicate("0", 64)
               )
             )

    assert Artifacts.get(ctx.db, artifact.artifact_id).state == "in-workspace"

    assert {:error, %{code: "capture_preflight", message: message}} =
             ArtifactContent.capture(
               ctx.db,
               capture_opts(ctx, artifact, "result.txt")
               |> Map.delete(:quota_bytes)
               |> Map.delete(:reserved_free_bytes)
             )

    assert message =~ "TIGHTBEAM_ARTIFACT_CONTENT_QUOTA_BYTES"
    assert Artifacts.get(ctx.db, artifact.artifact_id).state == "in-workspace"
  end

  test "native free-space preflight accepts a satisfied floor and refuses exhaustion", ctx do
    File.write!(Path.join(ctx.source_root, "floor.txt"), "floor")
    accepted = record(ctx, "floor.txt")

    assert {:ok, %{state: "released"}} =
             ArtifactContent.capture(
               ctx.db,
               capture_opts(ctx, accepted, "floor.txt")
               |> Map.put(:reserved_free_bytes, 1)
             )

    refused = record(ctx, "floor.txt")

    assert {:error, %{code: "capture_preflight"}} =
             ArtifactContent.capture(
               ctx.db,
               capture_opts(ctx, refused, "floor.txt")
               |> Map.put(:reserved_free_bytes, 9_223_372_036_854_775_807)
             )

    assert Artifacts.get(ctx.db, refused.artifact_id).state == "in-workspace"
  end

  test "unique quota refusals publish no unaccounted CAS objects", ctx do
    captures = ["one1", "two2", "tri3"]

    [first | refused] =
      Enum.map(captures, fn bytes ->
        path = "#{bytes}.txt"
        File.write!(Path.join(ctx.source_root, path), bytes)
        {record(ctx, path), path, bytes}
      end)

    {first_artifact, first_path, _bytes} = first

    assert {:ok, %{state: "released"}} =
             ArtifactContent.capture(
               ctx.db,
               capture_opts(ctx, first_artifact, first_path) |> Map.put(:quota_bytes, 4)
             )

    for {artifact, path, _bytes} <- refused do
      assert {:error, %{code: "content_quota_exceeded"}} =
               ArtifactContent.capture(
                 ctx.db,
                 capture_opts(ctx, artifact, path) |> Map.put(:quota_bytes, 4)
               )

      assert Artifacts.get(ctx.db, artifact.artifact_id).state == "in-workspace"
    end

    objects =
      Path.wildcard(Path.join([ctx.base_dir, "artifact-content", "sha256", "*", "*"]))

    assert length(objects) == 1
    assert Enum.sum(Enum.map(objects, &File.stat!(&1).size)) == 4
    assert {:ok, [[1, 4]]} = DB.query(ctx.db, "SELECT COUNT(*), SUM(size) FROM artifact_blobs")
  end

  test "capture reuse corruption closes every trusted row and leaves the new row unreleased",
       ctx do
    bytes = "reuse bytes"
    File.write!(Path.join(ctx.source_root, "reuse.txt"), bytes)
    first = record(ctx, "reuse.txt")
    second = record(ctx, "reuse.txt")
    third = record(ctx, "reuse.txt")

    for artifact <- [first, second] do
      assert {:ok, %{state: "released"}} =
               ArtifactContent.capture(ctx.db, capture_opts(ctx, artifact, "reuse.txt"))
    end

    digest = sha256(bytes)
    cas = ArtifactContent.cas_path(ctx.base_dir, digest)
    File.chmod!(cas, 0o600)
    File.write!(cas, "corrupt")

    assert {:error, %{code: "content_corrupt"}} =
             ArtifactContent.capture(ctx.db, capture_opts(ctx, third, "reuse.txt"))

    for artifact <- [first, second] do
      row = Artifacts.get(ctx.db, artifact.artifact_id)
      assert row.state == "corrupt-unavailable"
      assert row.content_sha256 == nil
      assert row.content_size == nil
      assert row.content_recovery_sha256 == digest
      assert row.unavailable_reason == "cas-size"
    end

    assert Artifacts.get(ctx.db, third.artifact_id).state == "in-workspace"

    assert {:ok, [["corrupt", "cas-size"]]} =
             DB.query(
               ctx.db,
               "SELECT status, corruptReason FROM artifact_blobs WHERE digest=?1",
               [digest]
             )

    assert [event] =
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.filter(&(&1.kind == "artifact_content_corrupt"))

    assert event.detail =~ "operation=capture-reuse"
  end

  test "missing shared CAS closes every trusting row before returning content_corrupt", ctx do
    bytes = "shared bytes"
    File.write!(Path.join(ctx.source_root, "shared.txt"), bytes)
    first = record(ctx, "shared.txt")
    second = record(ctx, "shared.txt")

    for artifact <- [first, second] do
      assert {:ok, %{state: "released"}} =
               ArtifactContent.capture(ctx.db, capture_opts(ctx, artifact, "shared.txt"))
    end

    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    File.rm!(ArtifactContent.cas_path(ctx.base_dir, digest))

    assert {:error, %{code: "content_corrupt"}} =
             ArtifactContent.fetch(ctx.db, ctx.base_dir, first.artifact_id, "session:holder")

    for artifact <- [first, second] do
      row = Artifacts.get(ctx.db, artifact.artifact_id)
      assert row.state == "corrupt-unavailable"
      assert row.content_sha256 == nil
      assert row.content_size == nil
      assert row.content_recovery_sha256 == digest
      assert row.unavailable_reason == "cas-missing"
    end

    assert {:ok, [["corrupt", "cas-missing"]]} =
             DB.query(
               ctx.db,
               "SELECT status, corruptReason FROM artifact_blobs WHERE digest = ?1",
               [digest]
             )

    assert {:error, %{code: "content_corrupt"}} =
             ArtifactContent.fetch(ctx.db, ctx.base_dir, second.artifact_id, "session:holder")
  end

  test "boot cleanup removes all incomplete staging and scrub closes a damaged release", ctx do
    File.write!(Path.join(ctx.source_root, "boot.txt"), "boot bytes")
    artifact = record(ctx, "boot.txt")

    assert {:ok, released} =
             ArtifactContent.capture(ctx.db, capture_opts(ctx, artifact, "boot.txt"))

    temp_dir = Path.join([ctx.base_dir, "artifact-content", "tmp"])
    temp = Path.join(temp_dir, "interrupted")
    File.write!(temp, "partial")

    import =
      Path.join([
        ctx.base_dir,
        "artifact-content",
        "import",
        "session",
        "holder",
        "upload",
        "content"
      ])

    File.mkdir_p!(Path.dirname(import))
    File.write!(import, "authenticated partial")

    orphan =
      Path.join([ctx.base_dir, "artifact-content", "sha256", "ff", String.duplicate("f", 64)])

    File.mkdir_p!(Path.dirname(orphan))
    File.write!(orphan, "orphan evidence")

    assert :ok = ArtifactContent.cleanup_temps(ctx.base_dir)
    refute File.exists?(temp)
    refute File.exists?(import)
    assert File.read!(orphan) == "orphan evidence"

    cas = ArtifactContent.cas_path(ctx.base_dir, released.content_sha256)
    File.chmod!(cas, 0o600)
    File.write!(cas, "tampered")

    assert_raise RuntimeError, ~r/artifact content boot scrub refused/, fn ->
      ArtifactContent.boot_scrub!(ctx.db, ctx.base_dir)
    end

    assert Artifacts.get(ctx.db, artifact.artifact_id).state == "corrupt-unavailable"
  end

  test "scratch snapshot and CAS restore verify installed bytes before boot fetch" do
    root =
      Path.join(System.tmp_dir!(), "artifact-restore-#{System.unique_integer([:positive])}")

    original_base = Path.join(root, "original")
    backup_dir = Path.join(root, "backup")
    restored_base = Path.join(root, "restored")
    original_db_path = Path.join(original_base, "state.db")
    snapshot = Path.join(backup_dir, "state.db")
    File.mkdir_p!(original_base)
    File.mkdir_p!(backup_dir)
    on_exit(fn -> File.rm_rf!(root) end)

    original_db = :artifact_restore_original
    start_supervised!({DB, path: original_db_path, name: original_db}, id: original_db)
    :ok = Schema.ensure_all(original_db)

    {:ok, _} =
      DB.query(
        original_db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('restore-owner', 1, 1)"
      )

    session =
      Org.create(original_db, %{
        session_key: "restore-holder",
        display_name: "restore-holder",
        owner_user_id: "restore-owner",
        origin: "user:restore-owner",
        spawned_by: nil,
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    {:ok, _} =
      DB.query(
        original_db,
        """
        INSERT INTO work_items
          (id, title, ownerUserId, createdByUser, createdAt)
        VALUES ('wi_restore', 'restore', 'restore-owner', 'restore-owner', 1)
        """
      )

    source_root = Path.join(original_base, "workspace")
    File.mkdir_p!(source_root)
    bytes = <<0, 255, "restored bytes", 0>>
    File.write!(Path.join(source_root, "content.bin"), bytes)
    install_cli!(original_base)

    artifact =
      Artifacts.record(original_db, %{
        principal: {:session, session.session_key},
        session_key: session.session_key,
        params: %{
          kind: "report",
          title: "restore fixture",
          origin_path: "content.bin",
          work_item_id: "wi_restore"
        }
      })

    assert {:ok, released} =
             ArtifactContent.capture(original_db, %{
               artifact_id: artifact.artifact_id,
               base_dir: original_base,
               source_root: source_root,
               relative_path: "content.bin",
               quota_bytes: 1024,
               reserved_free_bytes: 0,
               principal: "session:restore-holder"
             })

    backup_command = ".backup '#{snapshot}'"
    assert {"", 0} = System.cmd("sqlite3", [original_db_path, backup_command])

    snapshot_digest = sha256(File.read!(snapshot))
    File.write!(Path.join(backup_dir, "state.sha256"), snapshot_digest <> "\n")

    manifest_query =
      "SELECT DISTINCT contentSha256 || ' ' || contentSize " <>
        "FROM artifacts WHERE state='released' ORDER BY contentSha256;"

    assert {manifest, 0} = System.cmd("sqlite3", [snapshot, manifest_query])
    assert manifest == "#{released.content_sha256} #{released.content_size}\n"
    File.write!(Path.join(backup_dir, "artifact-content.manifest"), manifest)

    backup_blob =
      Path.join([
        backup_dir,
        "artifact-content",
        "sha256",
        binary_part(released.content_sha256, 0, 2),
        released.content_sha256
      ])

    File.mkdir_p!(Path.dirname(backup_blob))

    File.cp!(
      ArtifactContent.cas_path(original_base, released.content_sha256),
      backup_blob
    )

    assert File.stat!(backup_blob).size == released.content_size
    assert sha256(File.read!(backup_blob)) == released.content_sha256

    restored_db_path = Path.join(restored_base, "state.db")
    File.mkdir_p!(restored_base)
    File.cp!(snapshot, restored_db_path)
    assert sha256(File.read!(restored_db_path)) == snapshot_digest

    restored_blob = ArtifactContent.cas_path(restored_base, released.content_sha256)
    File.mkdir_p!(Path.dirname(restored_blob))
    File.cp!(backup_blob, restored_blob)
    assert File.stat!(restored_blob).size == released.content_size
    assert sha256(File.read!(restored_blob)) == released.content_sha256

    restored_db = :artifact_restore_installed
    start_supervised!({DB, path: restored_db_path, name: restored_db}, id: restored_db)
    assert {:ok, [["ok"]]} = DB.query(restored_db, "PRAGMA integrity_check")
    assert {:ok, []} = DB.query(restored_db, "PRAGMA foreign_key_check")
    :ok = Schema.ensure_all(restored_db)
    :ok = ArtifactContent.cleanup_temps(restored_base)
    :ok = ArtifactContent.boot_scrub!(restored_db, restored_base)

    assert {:ok, fetched} =
             ArtifactContent.fetch(
               restored_db,
               restored_base,
               released.artifact_id,
               "user:restore-owner"
             )

    assert IO.binread(fetched.descriptor, :eof) == bytes
    File.close(fetched.descriptor)

    File.rm!(restored_blob)

    assert_raise RuntimeError, ~r/artifact content boot scrub refused/, fn ->
      ArtifactContent.boot_scrub!(restored_db, restored_base)
    end

    assert Artifacts.get(restored_db, released.artifact_id).state == "corrupt-unavailable"
  end

  test "recovery permits the active creator or administrator and pins corrupt bytes", ctx do
    previous_quota = Application.get_env(:tightbeam, :artifact_content_quota_bytes)
    previous_floor = Application.get_env(:tightbeam, :artifact_content_reserved_free_bytes)
    Application.put_env(:tightbeam, :artifact_content_quota_bytes, 1024)
    Application.put_env(:tightbeam, :artifact_content_reserved_free_bytes, 0)

    on_exit(fn ->
      restore_env(:artifact_content_quota_bytes, previous_quota)
      restore_env(:artifact_content_reserved_free_bytes, previous_floor)
    end)

    {:ok, _} =
      DB.query(ctx.db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('casey', 0, 2)")

    creator =
      Org.create(ctx.db, %{
        session_key: "creator",
        display_name: "creator",
        owner_user_id: "casey",
        origin: "user:casey",
        spawned_by: nil,
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    legacy = record_for(ctx, creator, "legacy.bin")
    set_unavailable!(ctx.db, legacy.artifact_id, "legacy-unavailable", nil)
    legacy_bytes = <<0, 255, "legacy">>
    legacy_root = stage_import!(ctx.base_dir, "legacy", legacy_bytes)
    recover = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})["artifact-content-recover"]

    legacy_call = recovery_call(legacy, legacy_root, legacy_bytes, {:user, "casey"}, "user:casey")

    assert %{code: "not_authorized"} = recover.(legacy_call)
    assert Artifacts.get(ctx.db, legacy.artifact_id).state == "legacy-unavailable"

    creator_call = %{legacy_call | principal: {:session, "creator"}, origin: "agent:creator"}
    assert %{state: "released"} = released = recover.(creator_call)
    assert released.content_sha256 == sha256(legacy_bytes)

    File.rm_rf!(legacy_root)
    assert recover.(creator_call) == released

    corrupt = record_for(ctx, creator, "corrupt.bin")
    recovery_bytes = "exact recovery bytes"
    recovery_digest = sha256(recovery_bytes)
    set_unavailable!(ctx.db, corrupt.artifact_id, "corrupt-unavailable", recovery_digest)

    wrong_bytes = "wrong bytes"
    wrong_root = stage_import!(ctx.base_dir, "wrong", wrong_bytes)

    wrong_call =
      recovery_call(corrupt, wrong_root, wrong_bytes, {:user, "flynn"}, "user:flynn")

    assert %{code: "content_digest_mismatch"} = recover.(wrong_call)
    assert Artifacts.get(ctx.db, corrupt.artifact_id).state == "corrupt-unavailable"

    exact_root = stage_import!(ctx.base_dir, "exact", recovery_bytes)

    exact_call =
      recovery_call(corrupt, exact_root, recovery_bytes, {:user, "flynn"}, "user:flynn")
      |> put_in([:params, :idempotency_key], "recover-exact")

    assert %{state: "released", content_sha256: ^recovery_digest} = recover.(exact_call)
    assert Artifacts.get(ctx.db, corrupt.artifact_id).created_by_session == "creator"
  end

  defp capture_opts(ctx, artifact, relative_path) do
    %{
      artifact_id: artifact.artifact_id,
      base_dir: ctx.base_dir,
      source_root: ctx.source_root,
      relative_path: relative_path,
      quota_bytes: 1024,
      reserved_free_bytes: 0,
      principal: "session:holder"
    }
  end

  defp record(ctx, origin_path) do
    record_for(ctx, ctx.session, origin_path)
  end

  defp record_for(ctx, session, origin_path) do
    Artifacts.record(ctx.db, %{
      principal: {:session, session.session_key},
      session_key: session.session_key,
      params: %{
        kind: "report",
        title: origin_path,
        origin_path: origin_path,
        work_item_id: "wi_content"
      }
    })
  end

  defp set_unavailable!(db, artifact_id, "legacy-unavailable", nil) do
    {:ok, _} =
      DB.query(
        db,
        "UPDATE artifacts SET state='legacy-unavailable', unavailableReason='migration-pending' WHERE artifactId=?1",
        [artifact_id]
      )
  end

  defp set_unavailable!(db, artifact_id, "corrupt-unavailable", digest) do
    {:ok, _} =
      DB.query(
        db,
        "UPDATE artifacts SET state='corrupt-unavailable', contentRecoverySha256=?2, unavailableReason='cas-missing' WHERE artifactId=?1",
        [artifact_id, digest]
      )
  end

  defp stage_import!(base_dir, name, bytes) do
    root = Path.join([base_dir, "artifact-content", "import-test", name])
    File.mkdir_p!(root)
    File.write!(Path.join(root, "content"), bytes)
    root
  end

  defp recovery_call(artifact, root, bytes, principal, origin) do
    %{
      verb: "artifact-content-recover",
      origin: origin,
      principal: principal,
      session_key: nil,
      params: %{
        artifact_id: artifact.artifact_id,
        idempotency_key: "recover-1",
        import_root: root,
        import_relative_path: "content",
        declared_length: byte_size(bytes)
      }
    }
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp restore_env(key, nil), do: Application.delete_env(:tightbeam, key)
  defp restore_env(key, value), do: Application.put_env(:tightbeam, key, value)

  defp install_cli!(base_dir) do
    source = Path.expand("../cli/target/release/tightbeam", __DIR__)
    destination = Path.join([base_dir, "bin", "tightbeam"])
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(source, destination)
    File.chmod!(destination, 0o755)
  end
end
