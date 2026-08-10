defmodule Tightbeam.Assets do
  @moduledoc """
  DB-backed attachment metadata and request-process blob storage (TS reference:
  `src/wire/assets.ts`).

  Metadata uses the reference's camelCase SQLite schema for adopt-in-place
  compatibility. Blob bytes live at `<base_dir>/assets/<asset_id>`. This module
  has no process: callers perform file I/O in the request process, while only
  bounded metadata statements pass through `Tightbeam.DB`.
  """

  alias Tightbeam.DB

  @type db :: GenServer.server()

  @max_attachments 10
  @max_inline_image_bytes 256 * 1024
  @max_asset_bytes 32 * 1024 * 1024

  @typedoc "An asset metadata row."
  @type asset :: %{
          asset_id: String.t(),
          owner_user_id: String.t(),
          mime_type: String.t(),
          size: non_neg_integer(),
          filename: String.t() | nil,
          created_at: integer()
        }

  @ddl """
  CREATE TABLE IF NOT EXISTS assets (
    assetId     TEXT PRIMARY KEY,
    ownerUserId TEXT NOT NULL,
    mimeType    TEXT NOT NULL,
    size        INTEGER NOT NULL,
    filename    TEXT,
    createdAt   INTEGER NOT NULL
  );
  """

  @doc "Ensure the adopt-in-place-compatible assets metadata table exists."
  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc """
  Write asset bytes under `<base_dir>/assets/`, then record their metadata.

  The file write deliberately runs in the caller, never in a shared serializer.
  IDs use the reference's `a_` plus UUIDv4 shape.
  """
  @spec put(db(), String.t(), String.t(), String.t(), String.t() | nil, binary()) :: asset()
  def put(db \\ Tightbeam.DB, base_dir, owner_user_id, mime_type, filename, data) do
    asset_id = "a_" <> Tightbeam.Id.uuid4()
    path = file_path(base_dir, asset_id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
    size = File.stat!(path).size

    row = %{
      asset_id: asset_id,
      owner_user_id: owner_user_id,
      mime_type: mime_type,
      size: size,
      filename: filename,
      created_at: System.system_time(:millisecond)
    }

    {:ok, []} =
      DB.query(
        db,
        """
        INSERT INTO assets (assetId, ownerUserId, mimeType, size, filename, createdAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """,
        [asset_id, owner_user_id, mime_type, size, filename, row.created_at]
      )

    row
  end

  @doc "Return an asset metadata row by id, or nil when it is unknown."
  @spec get(db(), String.t()) :: asset() | nil
  def get(db \\ Tightbeam.DB, asset_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT assetId, ownerUserId, mimeType, size, filename, createdAt
        FROM assets WHERE assetId = ?1
        """,
        [asset_id]
      )

    case rows do
      [row] -> to_asset(row)
      [] -> nil
    end
  end

  @doc "Return the reference-compatible on-disk path for an asset id."
  @spec file_path(String.t(), String.t()) :: String.t()
  def file_path(base_dir, asset_id), do: Path.join([base_dir, "assets", asset_id])

  @doc """
  Validate the closed wire attachment union for one authenticated owner and
  return its canonical durable representation.

  Inline images are canonicalized to lower-case MIME plus padded base64, so
  equivalent encodings compare equal. Asset references are replaced with the
  immutable display fields from the owner-scoped metadata row. Unknown and
  foreign ids deliberately share one non-identifying refusal.
  """
  @spec normalize_attachments(db(), String.t(), term()) ::
          {:ok, [map()]} | {:error, %{code: String.t(), message: String.t()}}
  def normalize_attachments(db \\ Tightbeam.DB, owner_user_id, attachments)

  def normalize_attachments(_db, _owner_user_id, attachments) when not is_list(attachments),
    do: invalid_attachment("attachments must be a list")

  def normalize_attachments(_db, _owner_user_id, attachments)
      when length(attachments) > @max_attachments,
      do: payload_too_large("a message may contain at most #{@max_attachments} attachments")

  def normalize_attachments(db, owner_user_id, attachments) do
    attachments
    |> Enum.reduce_while({:ok, [], 0, 0}, fn attachment,
                                             {:ok, normalized, inline_bytes, asset_bytes} ->
      case normalize_attachment(db, owner_user_id, attachment) do
        {:ok, descriptor, {:inline, size}} ->
          next_inline = inline_bytes + size
          next_total = next_inline + asset_bytes

          cond do
            next_inline > @max_inline_image_bytes ->
              {:halt, payload_too_large("inline images exceed 256 KiB")}

            next_total > @max_asset_bytes ->
              {:halt, payload_too_large("attachments exceed 32 MiB")}

            true ->
              {:cont, {:ok, [descriptor | normalized], next_inline, asset_bytes}}
          end

        {:ok, descriptor, {:asset, size}} ->
          next_assets = asset_bytes + size
          next_total = inline_bytes + next_assets

          if next_total <= @max_asset_bytes,
            do: {:cont, {:ok, [descriptor | normalized], inline_bytes, next_assets}},
            else: {:halt, payload_too_large("attachments exceed 32 MiB")}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized, _inline_bytes, _asset_bytes} -> {:ok, Enum.reverse(normalized)}
      {:error, _error} = error -> error
    end
  end

  @doc "The equality identity of one validated descriptor."
  @spec attachment_identity(map()) :: {:ok, term()} | :error
  def attachment_identity(%{"type" => "image", "mimeType" => mime_type, "data" => data})
      when is_binary(mime_type) and is_binary(data) do
    with {:ok, bytes} <- decode_base64(data),
         {:ok, mime_type} <- image_mime(mime_type) do
      {:ok, {:image, mime_type, bytes}}
    else
      _ -> :error
    end
  end

  def attachment_identity(%{"type" => "asset", "assetId" => asset_id})
      when is_binary(asset_id) and asset_id != "",
      do: {:ok, {:asset, asset_id}}

  def attachment_identity(_attachment), do: :error

  @doc """
  Resolve a complete prompt before delivery. Text stays first and images retain
  source order. Non-image assets remain explicitly unsupported in this slice.
  """
  @spec content_blocks(String.t(), String.t(), [map()]) ::
          {:ok, [map()]} | {:error, %{code: String.t(), message: String.t()}}
  def content_blocks(base_dir, text, attachments) when is_binary(text) and is_list(attachments) do
    attachments
    |> Enum.reduce_while({:ok, []}, fn attachment, {:ok, image_blocks} ->
      case image_block(base_dir, attachment) do
        {:ok, block} -> {:cont, {:ok, [block | image_blocks]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reverse_images} ->
        {:ok, [%{type: "text", text: text} | Enum.reverse(reverse_images)]}

      {:error, _error} = error ->
        error
    end
  end

  defp normalize_attachment(
         _db,
         _owner_user_id,
         %{"type" => "image", "mimeType" => mime_type, "data" => data}
       )
       when is_binary(mime_type) and is_binary(data) do
    with {:ok, mime_type} <- image_mime(mime_type),
         {:ok, bytes} <- decode_base64(data) do
      {:ok, %{"type" => "image", "mimeType" => mime_type, "data" => Base.encode64(bytes)},
       {:inline, byte_size(bytes)}}
    else
      _ -> invalid_attachment("inline image is malformed")
    end
  end

  defp normalize_attachment(
         db,
         owner_user_id,
         %{"type" => "asset", "assetId" => asset_id}
       )
       when is_binary(asset_id) and asset_id != "" do
    case get(db, asset_id) do
      %{owner_user_id: ^owner_user_id} = asset ->
        {:ok,
         %{
           "type" => "asset",
           "assetId" => asset.asset_id,
           "mimeType" => normalize_mime(asset.mime_type),
           "filename" => asset.filename,
           "size" => asset.size
         }, {:asset, asset.size}}

      _ ->
        invalid_attachment("attachment is unknown")
    end
  end

  defp normalize_attachment(_db, _owner_user_id, _attachment),
    do: invalid_attachment("attachment descriptor is malformed")

  defp image_block(
         _base_dir,
         %{"type" => "image", "mimeType" => mime_type, "data" => data}
       ) do
    {:ok, %{type: "image", mimeType: mime_type, data: data}}
  end

  defp image_block(
         base_dir,
         %{
           "type" => "asset",
           "assetId" => asset_id,
           "mimeType" => "image/" <> _ = mime_type,
           "size" => expected_size
         }
       ) do
    case File.read(file_path(base_dir, asset_id)) do
      {:ok, bytes} when byte_size(bytes) == expected_size ->
        {:ok, %{type: "image", mimeType: mime_type, data: Base.encode64(bytes)}}

      _ ->
        {:error, %{code: "attachment_read_failed", message: "attachment bytes could not be read"}}
    end
  end

  defp image_block(_base_dir, %{"type" => "asset"}),
    do:
      {:error,
       %{
         code: "unsupported_attachment",
         message: "this attachment type is not supported"
       }}

  defp image_block(_base_dir, _attachment),
    do: invalid_attachment("attachment descriptor is malformed")

  defp image_mime(mime_type) do
    mime_type = normalize_mime(mime_type)

    if Regex.match?(~r/^image\/[a-z0-9][a-z0-9.+-]*$/, mime_type),
      do: {:ok, mime_type},
      else: :error
  end

  defp normalize_mime(mime_type), do: mime_type |> String.trim() |> String.downcase()

  defp decode_base64(data) do
    compact = String.replace(data, ~r/\s+/, "")

    case Base.decode64(compact) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> Base.decode64(compact, padding: false)
    end
  end

  defp invalid_attachment(message),
    do: {:error, %{code: "invalid_message", message: message}}

  defp payload_too_large(message),
    do: {:error, %{code: "payload_too_large", message: message}}

  defp to_asset([asset_id, owner_user_id, mime_type, size, filename, created_at]) do
    %{
      asset_id: asset_id,
      owner_user_id: owner_user_id,
      mime_type: mime_type,
      size: size,
      filename: filename,
      created_at: created_at
    }
  end
end
