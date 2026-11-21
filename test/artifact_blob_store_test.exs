defmodule Tightbeam.ArtifactBlobStoreTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.ArtifactBlobStore, as: Store

  setup do
    root = Path.join(System.tmp_dir!(), "artifact-blobs-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    store =
      start_supervised!(
        {Store,
         root: root,
         budget_bytes: 4,
         floor_bytes: 100,
         floor_percent: 10,
         disk_space: fn _ -> {:ok, 2_000, 1_000} end}
      )

    %{store: store, root: root}
  end

  test "one digest occupies the store once and can be reused at capacity", ctx do
    {:ok, first} = Store.begin_upload(ctx.store)
    assert :ok = Store.append(ctx.store, first, "fo")

    assert {:ok, %{staged_bytes: 2, used_bytes: 0, free_floor_bytes: 200}} =
             Store.capacity(ctx.store)

    assert :ok = Store.append(ctx.store, first, "ur")
    assert {:ok, %{custody: "pinned", sha256: sha, size: 4}} = Store.finish(ctx.store, first)
    assert {:ok, "four"} = Store.read(ctx.root, sha)

    {:ok, duplicate} = Store.begin_upload(ctx.store)
    assert :ok = Store.append(ctx.store, duplicate, "four")
    assert {:ok, %{custody: "pinned", sha256: ^sha}} = Store.finish(ctx.store, duplicate)

    assert {:ok, %{used_bytes: 4, staged_bytes: 0, effective_limit_bytes: 4}} =
             Store.capacity(ctx.store)
  end

  test "capacity refuses by default and only an opted-in recording can become unpinned", ctx do
    {:ok, refused} = Store.begin_upload(ctx.store)
    assert :ok = Store.append(ctx.store, refused, "larger")

    assert {:error, {:capacity, %{effective_limit_bytes: 4, free_bytes: 1_000}}} =
             Store.finish(ctx.store, refused)

    {:ok, fallback} = Store.begin_upload(ctx.store, allow_unpinned: true)
    assert :ok = Store.append(ctx.store, fallback, "larger")
    assert {:ok, %{custody: "unpinned", sha256: sha}} = Store.finish(ctx.store, fallback)
    assert {:error, :enoent} = Store.read(ctx.root, sha)
  end

  test "an expected hash mismatch refuses even if the caller allowed an unpinned row", ctx do
    expected = String.duplicate("a", 64)
    {:ok, upload} = Store.begin_upload(ctx.store, expected_sha: expected, allow_unpinned: true)
    assert :ok = Store.append(ctx.store, upload, "larger")
    assert {:error, {:sha_mismatch, ^expected, observed}} = Store.finish(ctx.store, upload)
    assert observed != expected
    assert {:ok, %{used_bytes: 0, staged_bytes: 0}} = Store.capacity(ctx.store)
  end
end
