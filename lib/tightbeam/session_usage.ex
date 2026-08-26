defmodule Tightbeam.SessionUsage do
  @moduledoc """
  Durable, per-turn token observations and their truthful per-session projection.

  ACP prompt usage is already normalized by each harness adapter. This module
  keeps only the six public numeric counters from that response. It never
  derives a missing counter from the counters that happened to be present.

  One row per turn makes replay idempotent. A replay with different counters is
  an invariant violation rather than a second observation for work that ran
  once.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @fields [
    {:totalTokens, "totalTokens", "totalTokens"},
    {:inputTokens, "inputTokens", "inputTokens"},
    {:outputTokens, "outputTokens", "outputTokens"},
    {:thoughtTokens, "thoughtTokens", "thoughtTokens"},
    {:cachedReadTokens, "cachedReadTokens", "cachedReadTokens"},
    {:cachedWriteTokens, "cachedWriteTokens", "cachedWriteTokens"}
  ]

  @table_ddl """
  CREATE TABLE IF NOT EXISTS session_usage_observations (
    turnSeq           INTEGER PRIMARY KEY REFERENCES turns(seq),
    sessionKey        TEXT NOT NULL REFERENCES sessions(sessionKey),
    totalTokens       INTEGER CHECK (totalTokens IS NULL OR totalTokens >= 0),
    inputTokens       INTEGER CHECK (inputTokens IS NULL OR inputTokens >= 0),
    outputTokens      INTEGER CHECK (outputTokens IS NULL OR outputTokens >= 0),
    thoughtTokens     INTEGER CHECK (thoughtTokens IS NULL OR thoughtTokens >= 0),
    cachedReadTokens  INTEGER CHECK (cachedReadTokens IS NULL OR cachedReadTokens >= 0),
    cachedWriteTokens INTEGER CHECK (cachedWriteTokens IS NULL OR cachedWriteTokens >= 0),
    CHECK (
      totalTokens IS NOT NULL OR inputTokens IS NOT NULL OR outputTokens IS NOT NULL OR
      thoughtTokens IS NOT NULL OR cachedReadTokens IS NOT NULL OR
      cachedWriteTokens IS NOT NULL
    )
  );
  """

  @index_ddl """
  CREATE INDEX IF NOT EXISTS session_usage_by_session
  ON session_usage_observations (sessionKey, turnSeq);
  """

  defmodule ShapeError do
    @moduledoc false
    defexception [:message]
  end

  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ Tightbeam.DB) do
    :ok = ensure_object(db, "table", "session_usage_observations", @table_ddl)
    :ok = ensure_object(db, "index", "session_usage_by_session", @index_ddl)
  end

  @doc "Keep only nonnegative integer counters whose provider value is present."
  @spec normalize(term()) :: map()
  def normalize(usage) when is_map(usage) do
    Enum.reduce(@fields, %{}, fn {wire_key, string_key, _column}, normalized ->
      value = Map.get(usage, string_key, Map.get(usage, wire_key))

      if is_integer(value) and value >= 0,
        do: Map.put(normalized, wire_key, value),
        else: normalized
    end)
  end

  def normalize(_usage), do: %{}

  @doc "Record one normalized observation outside an existing transaction."
  @spec record(DB.server(), pos_integer(), String.t(), term()) :: :ok | {:error, Exception.t()}
  def record(db \\ Tightbeam.DB, turn_seq, session_key, usage) do
    case DB.transaction(db, fn txn -> record_in_txn(txn, turn_seq, session_key, usage) end) do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc "Record one observation in the assistant-commit transaction."
  @spec record_in_txn(Txn.t(), pos_integer(), String.t(), term()) :: :ok
  def record_in_txn(%Txn{} = txn, turn_seq, session_key, usage) do
    normalized = normalize(usage)

    if map_size(normalized) == 0 do
      :ok
    else
      values = Enum.map(@fields, fn {key, _string_key, _atom_key} -> Map.get(normalized, key) end)

      Txn.q(
        txn,
        """
        INSERT INTO session_usage_observations
          (turnSeq, sessionKey, totalTokens, inputTokens, outputTokens,
           thoughtTokens, cachedReadTokens, cachedWriteTokens)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ON CONFLICT(turnSeq) DO NOTHING
        """,
        [turn_seq, session_key | values]
      )

      expected = [session_key | values]

      case Txn.q(
             txn,
             """
             SELECT sessionKey, totalTokens, inputTokens, outputTokens,
                    thoughtTokens, cachedReadTokens, cachedWriteTokens
             FROM session_usage_observations
             WHERE turnSeq = ?1
             """,
             [turn_seq]
           ) do
        [^expected] ->
          :ok

        [found] ->
          raise "session usage replay conflict for turn #{turn_seq}: #{inspect(found)}"

        [] ->
          raise "session usage observation missing after insert for turn #{turn_seq}"
      end
    end
  end

  @doc """
  Aggregate observations for one session.

  A counter is emitted only when every observed turn supplied it. This keeps a
  partial provider response from turning an unknown component into a smaller,
  apparently complete total.
  """
  @spec project(DB.server(), String.t()) :: map() | nil
  def project(db \\ Tightbeam.DB, session_key) do
    select_fields =
      Enum.map_join(@fields, ",\n", fn {_key, _string_key, column} ->
        "COUNT(#{column}), SUM(#{column})"
      end)

    {:ok, [[observed_turns | aggregates]]} =
      DB.query(
        db,
        "SELECT COUNT(*), #{select_fields} FROM session_usage_observations WHERE sessionKey = ?1",
        [session_key]
      )

    if observed_turns == 0 do
      nil
    else
      @fields
      |> Enum.zip(Enum.chunk_every(aggregates, 2))
      |> Enum.reduce(%{observedTurns: observed_turns}, fn
        {{wire_key, _string_key, _column}, [^observed_turns, sum]}, projection ->
          Map.put(projection, wire_key, sum)

        {_field, [_coverage, _sum]}, projection ->
          projection
      end)
    end
  end

  defp ensure_object(db, type, name, ddl) do
    case DB.query(db, "SELECT sql FROM sqlite_master WHERE type=?1 AND name=?2", [type, name]) do
      {:ok, []} ->
        :ok = DB.execute(db, ddl)

      {:ok, [[actual]]} when is_binary(actual) ->
        if normalize_sql(actual) != normalize_sql(ddl) do
          raise ShapeError, message: "incompatible session usage #{type}: malformed #{name}"
        end

        :ok

      {:ok, rows} ->
        raise ShapeError,
          message: "incompatible session usage #{type}: duplicate #{name} #{inspect(rows)}"
    end
  end

  defp normalize_sql(sql) do
    sql
    |> String.downcase()
    |> String.replace(~r/\bif\s+not\s+exists\b/u, "")
    |> String.replace(~r/\s+/u, "")
    |> String.trim_trailing(";")
  end
end
