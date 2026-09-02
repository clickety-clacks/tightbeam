defmodule Tightbeam.ReadMarkers do
  @moduledoc "User-scoped, uninterpreted read positions for multi-instance clients."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher

  @ddl """
  CREATE TABLE IF NOT EXISTS read_markers (
    userId    TEXT NOT NULL,
    scopeKey  TEXT NOT NULL,
    marker,
    updatedAt INTEGER NOT NULL,
    PRIMARY KEY (userId, scopeKey)
  );
  """

  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  def get(db \\ DB, user_id, scope_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT userId, scopeKey, marker, updatedAt FROM read_markers WHERE userId = ?1 AND scopeKey = ?2",
        [user_id, scope_key]
      )

    case rows do
      [[user, scope, marker, updated_at]] -> row(user, scope, marker, updated_at)
      [] -> nil
    end
  end

  @doc false
  def get_in_txn(%Txn{} = txn, user_id, scope_key),
    do: current_in_txn(txn, user_id, scope_key)

  def set(db \\ DB, user_id, scope_key, marker, opts \\ []) do
    expected? = Keyword.get(opts, :expected?, false)
    expected = Keyword.get(opts, :expected)

    case DB.transaction(db, fn txn ->
           current = current_in_txn(txn, user_id, scope_key)

           result =
             cond do
               expected? and current_marker(current) != expected ->
                 {:error,
                  %{
                    code: "read_marker_conflict",
                    message: "read marker no longer matches expected-current"
                  }}

               current_marker(current) == marker ->
                 {:ok, false, current}

               true ->
                 updated_at = max(System.system_time(:millisecond), current_version(current) + 1)

                 Txn.q(
                   txn,
                   """
                   INSERT INTO read_markers (userId, scopeKey, marker, updatedAt)
                   VALUES (?1, ?2, ?3, ?4)
                   ON CONFLICT(userId, scopeKey) DO UPDATE
                   SET marker = excluded.marker, updatedAt = excluded.updatedAt
                   """,
                   [user_id, scope_key, marker, updated_at]
                 )

                 {:ok, true, row(user_id, scope_key, marker, updated_at)}
             end

           case {result, opts[:firehose_call]} do
             {{:ok, changed?, row}, %{firehose_in_txn: true} = call} ->
               Publisher.maybe_accepted_in_txn(txn, call, %{
                 changed: changed?,
                 read_marker: row,
                 user_id: user_id
               })

             _ ->
               :ok
           end

           result
         end) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp current_in_txn(txn, user_id, scope_key) do
    case Txn.q(
           txn,
           "SELECT userId, scopeKey, marker, updatedAt FROM read_markers WHERE userId = ?1 AND scopeKey = ?2",
           [user_id, scope_key]
         ) do
      [[user, scope, marker, updated_at]] -> row(user, scope, marker, updated_at)
      [] -> nil
    end
  end

  defp current_marker(nil), do: nil
  defp current_marker(row), do: row.marker
  defp current_version(nil), do: 0
  defp current_version(row), do: row.updated_at

  defp row(user_id, scope_key, marker, updated_at) do
    %{user_id: user_id, scope_key: scope_key, marker: marker, updated_at: updated_at}
  end
end
