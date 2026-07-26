defmodule Tightbeam.AssetsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assets, DB}

  setup do
    db = :"assets_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Assets.ensure_schema(db)

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-assets-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{db: db, base_dir: base_dir}
  end

  test "put/get roundtrip records owner and writes bytes to disk", ctx do
    row = Assets.put(ctx.db, ctx.base_dir, "flynn", "image/png", "pic.png", "hello-bytes")

    assert row.asset_id =~ ~r/^a_[0-9a-f-]{36}$/
    assert row.owner_user_id == "flynn"
    assert row.mime_type == "image/png"
    assert row.filename == "pic.png"
    assert row.size == 11
    assert Assets.get(ctx.db, row.asset_id) == row
    assert File.read!(Assets.file_path(ctx.base_dir, row.asset_id)) == "hello-bytes"
  end

  test "get returns nil for an unknown asset", ctx do
    assert Assets.get(ctx.db, "a_nope") == nil
  end
end
