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
