defmodule Tightbeam.ArtifactContentTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ArtifactContent, Artifacts, DB, Gateway, Model, Org}

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

  test "boot cleanup removes only temps and scrub closes a damaged release", ctx do
    File.write!(Path.join(ctx.source_root, "boot.txt"), "boot bytes")
    artifact = record(ctx, "boot.txt")

    assert {:ok, released} =
             ArtifactContent.capture(ctx.db, capture_opts(ctx, artifact, "boot.txt"))

    temp_dir = Path.join([ctx.base_dir, "artifact-content", "tmp"])
    temp = Path.join(temp_dir, "interrupted")
    File.write!(temp, "partial")

    orphan =
      Path.join([ctx.base_dir, "artifact-content", "sha256", "ff", String.duplicate("f", 64)])

    File.mkdir_p!(Path.dirname(orphan))
    File.write!(orphan, "orphan evidence")

    assert :ok = ArtifactContent.cleanup_temps(ctx.base_dir)
    refute File.exists?(temp)
    assert File.read!(orphan) == "orphan evidence"

    cas = ArtifactContent.cas_path(ctx.base_dir, released.content_sha256)
    File.chmod!(cas, 0o600)
    File.write!(cas, "tampered")

    assert_raise RuntimeError, ~r/artifact content boot scrub refused/, fn ->
      ArtifactContent.boot_scrub!(ctx.db, ctx.base_dir)
    end

    assert Artifacts.get(ctx.db, artifact.artifact_id).state == "corrupt-unavailable"
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
    source = Path.expand("../cli/target/debug/tightbeam", __DIR__)
    destination = Path.join([base_dir, "bin", "tightbeam"])
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(source, destination)
    File.chmod!(destination, 0o755)
  end
end
