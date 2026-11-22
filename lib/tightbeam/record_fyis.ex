defmodule Tightbeam.RecordFyis do
  @moduledoc """
  FYI lines recorded with an accepted write.

  A substrate check that finds a factual mismatch accepts the write and states
  the mismatch as one plain line, leaving the judgment to the agent. The lines
  are stored beside the record they describe, returned in the write's result
  under `fyi`, and returned again whenever that record is read back.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @suffix "; decide for yourself whether that is acceptable"

  @kinds ~w(attest assignment session decision_request harness_health_promotion harness_health_review)

  @table_sql """
  CREATE TABLE record_fyis (
    recordKind TEXT NOT NULL CHECK (recordKind IN (#{Enum.map_join(@kinds, ",", &"'#{&1}'")})),
    recordId   TEXT NOT NULL,
    fyi        TEXT NOT NULL CHECK (json_valid(fyi) AND json_type(fyi) = 'array'),
    createdAt  INTEGER NOT NULL,
    PRIMARY KEY (recordKind, recordId)
  )
  """

  # The first shape of this table accepted attest FYIs only. It is its one
  # exact predecessor: a database carrying it is rebuilt to the current shape
  # with every row kept; any other stored shape is refused.
  @attest_only_table_sql """
  CREATE TABLE record_fyis (
    recordKind TEXT NOT NULL CHECK (recordKind IN ('attest')),
    recordId   TEXT NOT NULL,
    fyi        TEXT NOT NULL CHECK (json_valid(fyi) AND json_type(fyi) = 'array'),
    createdAt  INTEGER NOT NULL,
    PRIMARY KEY (recordKind, recordId)
  )
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    case DB.transaction(db, &ensure_schema_in_txn/1) do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_schema_in_txn(txn) do
    :ok =
      Txn.exec(
        txn,
        String.replace(@table_sql, "CREATE TABLE ", "CREATE TABLE IF NOT EXISTS ", global: false)
      )

    [[stored]] =
      Txn.q(txn, "SELECT sql FROM sqlite_master WHERE type='table' AND name='record_fyis'")

    cond do
      sql_tokens(stored) == sql_tokens(@table_sql) ->
        :ok

      sql_tokens(stored) == sql_tokens(@attest_only_table_sql) ->
        rebuild_in_txn(txn)

      true ->
        raise Tightbeam.Schema.ShapeError,
          message: "record_fyis_incompatible_shape: #{inspect(stored)}"
    end
  end

  defp rebuild_in_txn(txn) do
    [[count]] = Txn.q(txn, "SELECT COUNT(*) FROM record_fyis")

    holding =
      String.replace(
        @table_sql,
        "CREATE TABLE record_fyis (",
        "CREATE TABLE record_fyis_rebuild (",
        global: false
      )

    :ok = Txn.exec(txn, holding)
    :ok = Txn.exec(txn, "INSERT INTO record_fyis_rebuild SELECT * FROM record_fyis")
    :ok = Txn.exec(txn, "DROP TABLE record_fyis")
    :ok = Txn.exec(txn, @table_sql)
    :ok = Txn.exec(txn, "INSERT INTO record_fyis SELECT * FROM record_fyis_rebuild")
    [[^count]] = Txn.q(txn, "SELECT COUNT(*) FROM record_fyis")
    :ok = Txn.exec(txn, "DROP TABLE record_fyis_rebuild")
    :ok
  end

  defp sql_tokens(sql),
    do: sql |> String.trim() |> String.trim_trailing(";") |> String.replace(~r/\s+/, "")

  @doc false
  def attest_only_table_sql, do: @attest_only_table_sql

  @doc "Format one FYI line from the plain statement of the observed fact."
  @spec line(String.t()) :: String.t()
  def line(fact) when is_binary(fact), do: "FYI: " <> fact <> @suffix

  @doc "Add one FYI line, stated as a plain fact, to a call being admitted."
  @spec note(map(), String.t()) :: map()
  def note(call, fact), do: Map.update(call, :fyi, [line(fact)], &(&1 ++ [line(fact)]))

  @doc "Store the FYI lines for a record in the write's transaction."
  @spec put_in_txn(Txn.t(), String.t(), String.t(), [String.t()] | nil) :: :ok
  def put_in_txn(_txn, _kind, _id, lines) when lines in [nil, []], do: :ok

  def put_in_txn(%Txn{} = txn, kind, id, lines) when is_list(lines) do
    Txn.q(
      txn,
      "INSERT INTO record_fyis (recordKind, recordId, fyi, createdAt) VALUES (?1, ?2, ?3, ?4)",
      [kind, id, JSON.encode!(Enum.uniq(lines)), System.system_time(:millisecond)]
    )

    :ok
  end

  @doc "Read the FYI lines stored for each of the given records of one kind."
  @spec list_many(DB.server() | Txn.t(), String.t(), [String.t()]) :: %{
          String.t() => [String.t()]
        }
  def list_many(_db, _kind, []), do: %{}

  def list_many(%Txn{} = txn, kind, ids) do
    txn
    |> Txn.q(sql(), [kind, JSON.encode!(ids)])
    |> decode()
  end

  def list_many(db, kind, ids) do
    {:ok, rows} = DB.query(db, sql(), [kind, JSON.encode!(ids)])
    decode(rows)
  end

  @doc "Attach stored FYI lines to a record map under `fyi`, when it has any."
  @spec attach(DB.server() | Txn.t(), String.t(), map()) :: map()
  def attach(db, kind, %{id: id} = record) do
    case Map.get(list_many(db, kind, [id]), id) do
      nil -> record
      lines -> Map.put(record, :fyi, lines)
    end
  end

  defp sql,
    do:
      "SELECT recordId, fyi FROM record_fyis " <>
        "WHERE recordKind = ?1 AND recordId IN (SELECT value FROM json_each(?2))"

  defp decode(rows), do: Map.new(rows, fn [id, fyi] -> {id, JSON.decode!(fyi)} end)
end
