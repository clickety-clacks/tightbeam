defmodule Tightbeam.AdminProjection do
  @moduledoc "Durable row-version floors for branch-local administrative projections."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS admin_projection_versions (
    resource    TEXT NOT NULL,
    primaryKey  TEXT NOT NULL,
    rowVersion  INTEGER NOT NULL CHECK (rowVersion > 0),
    updatedAt   INTEGER NOT NULL,
    fingerprint TEXT,
    item        TEXT,
    PRIMARY KEY (resource, primaryKey)
  );
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @spec key(String.t() | [String.t()]) :: String.t()
  def key(value) when is_binary(value), do: value
  def key(parts) when is_list(parts), do: JSON.encode!(parts)

  @spec version(DB.server() | Txn.t(), String.t(), String.t() | [String.t()]) ::
          pos_integer() | nil
  def version(source, resource, primary_key) do
    rows =
      case source do
        %Txn{} = txn ->
          Txn.q(
            txn,
            "SELECT rowVersion FROM admin_projection_versions WHERE resource=?1 AND primaryKey=?2",
            [resource, key(primary_key)]
          )

        db ->
          {:ok, result} =
            DB.query(
              db,
              "SELECT rowVersion FROM admin_projection_versions WHERE resource=?1 AND primaryKey=?2",
              [resource, key(primary_key)]
            )

          result
      end

    case rows do
      [[row_version]] -> row_version
      [] -> nil
    end
  end

  @spec allocate_in_txn(Txn.t(), String.t(), String.t() | [String.t()], integer(), keyword()) ::
          pos_integer()
  def allocate_in_txn(%Txn{} = txn, resource, primary_key, updated_at, opts \\ [])
      when is_integer(updated_at) do
    encoded_key = key(primary_key)
    fingerprint = Keyword.get(opts, :fingerprint)
    item = Keyword.get(opts, :item)

    Txn.q(
      txn,
      """
      INSERT INTO admin_projection_versions
        (resource, primaryKey, rowVersion, updatedAt, fingerprint, item)
      VALUES (?1, ?2, 1, ?3, ?4, ?5)
      ON CONFLICT(resource, primaryKey) DO UPDATE SET
        rowVersion=admin_projection_versions.rowVersion + 1,
        updatedAt=excluded.updatedAt,
        fingerprint=excluded.fingerprint,
        item=excluded.item
      """,
      [resource, encoded_key, updated_at, fingerprint, item]
    )

    [[row_version]] =
      Txn.q(
        txn,
        "SELECT rowVersion FROM admin_projection_versions WHERE resource=?1 AND primaryKey=?2",
        [resource, encoded_key]
      )

    row_version
  end
end
