defmodule Tightbeam.AssetsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assets, DB}

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z2S8AAAAASUVORK5CYII="

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

  test "normalization closes the union, canonicalizes inline bytes, and resolves owner metadata",
       ctx do
    image = Base.decode64!(@png_base64)
    asset = Assets.put(ctx.db, ctx.base_dir, "flynn", "IMAGE/PNG", "fixture.png", image)

    assert {:ok, normalized} =
             Assets.normalize_attachments(ctx.db, "flynn", [
               %{
                 "type" => "image",
                 "mimeType" => " Image/PNG ",
                 "data" => String.trim_trailing(@png_base64, "=")
               },
               %{"type" => "asset", "assetId" => asset.asset_id}
             ])

    assert normalized == [
             %{"type" => "image", "mimeType" => "image/png", "data" => @png_base64},
             %{
               "type" => "asset",
               "assetId" => asset.asset_id,
               "mimeType" => "image/png",
               "filename" => "fixture.png",
               "size" => byte_size(image)
             }
           ]
  end

  test "unknown and foreign assets share one refusal", ctx do
    foreign = Assets.put(ctx.db, ctx.base_dir, "other", "image/png", "foreign.png", "bytes")

    assert {:error, %{code: "invalid_message", message: "attachment is unknown"}} =
             Assets.normalize_attachments(ctx.db, "flynn", [
               %{"type" => "asset", "assetId" => foreign.asset_id}
             ])

    assert {:error, %{code: "invalid_message", message: "attachment is unknown"}} =
             Assets.normalize_attachments(ctx.db, "flynn", [
               %{"type" => "asset", "assetId" => "a_missing"}
             ])
  end

  test "count and byte caps refuse before normalization succeeds", ctx do
    inline = %{"type" => "image", "mimeType" => "image/png", "data" => @png_base64}

    assert {:error, %{code: "payload_too_large"}} =
             Assets.normalize_attachments(ctx.db, "flynn", List.duplicate(inline, 11))

    large = String.duplicate("x", 256 * 1024 + 1) |> Base.encode64()

    assert {:error, %{code: "payload_too_large"}} =
             Assets.normalize_attachments(ctx.db, "flynn", [
               %{"type" => "image", "mimeType" => "image/png", "data" => large}
             ])

    :ok =
      DB.execute(
        ctx.db,
        "INSERT INTO assets (assetId, ownerUserId, mimeType, size, createdAt) VALUES ('a_large', 'flynn', 'image/png', 33554433, 1)"
      )

    assert {:error, %{code: "payload_too_large"}} =
             Assets.normalize_attachments(ctx.db, "flynn", [
               %{"type" => "asset", "assetId" => "a_large"}
             ])

    :ok =
      DB.execute(
        ctx.db,
        "INSERT INTO assets (assetId, ownerUserId, mimeType, size, createdAt) VALUES ('a_limit', 'flynn', 'image/png', 33554432, 1)"
      )

    assert {:error, %{code: "payload_too_large"}} =
             Assets.normalize_attachments(ctx.db, "flynn", [
               %{"type" => "asset", "assetId" => "a_limit"},
               inline
             ])
  end

  test "content blocks are complete and ordered, while non-images remain unsupported", ctx do
    image = Base.decode64!(@png_base64)
    asset = Assets.put(ctx.db, ctx.base_dir, "flynn", "image/png", "fixture.png", image)

    assert {:ok, [descriptor]} =
             Assets.normalize_attachments(ctx.db, "flynn", [
               %{"type" => "asset", "assetId" => asset.asset_id}
             ])

    inline = %{"type" => "image", "mimeType" => "image/png", "data" => @png_base64}

    assert {:ok, blocks} = Assets.content_blocks(ctx.base_dir, "inspect", [inline, descriptor])

    assert blocks == [
             %{type: "text", text: "inspect"},
             %{type: "image", mimeType: "image/png", data: @png_base64},
             %{type: "image", mimeType: "image/png", data: @png_base64}
           ]

    text_asset = Assets.put(ctx.db, ctx.base_dir, "flynn", "text/plain", "notes.txt", "hi")

    assert {:ok, [text_descriptor]} =
             Assets.normalize_attachments(ctx.db, "flynn", [
               %{"type" => "asset", "assetId" => text_asset.asset_id}
             ])

    assert {:error, %{code: "unsupported_attachment"}} =
             Assets.content_blocks(ctx.base_dir, "inspect", [text_descriptor])
  end
end
