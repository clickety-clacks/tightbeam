defmodule Tightbeam.Capacity.Store do
  @moduledoc false

  alias Tightbeam.Capacity.{History, Observation}
  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Schema.ShapeError

  @shape "capacity-observations-v1"
  @schema """
  CREATE TABLE capacity_observations (
    accountId TEXT PRIMARY KEY NOT NULL REFERENCES provider_accounts(id),
    attemptedAt INTEGER NOT NULL,
    completedAt INTEGER NOT NULL,
    retryAt INTEGER,
    sample TEXT,
    error TEXT,
    history TEXT NOT NULL,
    CHECK (completedAt >= attemptedAt),
    CHECK (sample IS NOT NULL OR error IS NOT NULL)
  );
  """

  # SQLite stores only normalized projections. Enumerating fields prevents a
  # stored string from becoming an atom and makes the shape independent of the
  # keys present in an upstream response.
  @sample ~w(plan observed_at windows diagnostics subscription)a
  @window ~w(id name used_percent resets_at window_seconds scope model)a
  @subscription ~w(status status_reason observed_at plan_unknown_reason period_end_at
                    period_end_kind period_end_unknown_reason)a
  @diagnostic ~w(code message)a
  @error ~w(code retry_after_seconds)a

  def ensure_schema(db) do
    case DB.transaction(db, &ensure_schema_in_txn/1) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  defp ensure_schema_in_txn(txn) do
    :ok =
      Txn.exec(txn, """
      CREATE TABLE IF NOT EXISTS capacity_schema_stamp (
        id INTEGER PRIMARY KEY CHECK (id = 0),
        shape TEXT NOT NULL
      )
      """)

    case Txn.q(txn, "SELECT shape FROM capacity_schema_stamp") do
      [] ->
        :ok = Txn.exec(txn, @schema)
        Txn.q(txn, "INSERT INTO capacity_schema_stamp VALUES (0, ?1)", [@shape])
        :ok

      [[@shape]] ->
        :ok

      rows ->
        raise ShapeError, message: "incompatible capacity schema stamp: #{inspect(rows)}"
    end
  end

  def entry(db, account_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT attemptedAt, completedAt, retryAt, sample, error, history
        FROM capacity_observations WHERE accountId = ?1
        """,
        [account_id]
      )

    decode_entry(rows)
  end

  def history(db, account_id, now) do
    db
    |> entry(account_id)
    |> Map.fetch!(:history)
    |> History.retain(now)
  end

  @doc """
  Update the capacity observation inside the caller's account transaction.

  The caller verifies the login generation and publishes the selection windows
  in this same transaction. Return the old and new projections for change detection.
  """
  def record_in_txn(%Txn{} = txn, account_id, outcome, attempted_at, completed_at) do
    current = entry(txn, account_id)

    case Observation.record(current, outcome, attempted_at, completed_at) do
      :superseded ->
        :superseded

      next ->
        put_in_txn(txn, account_id, next)
        {:ok, current, next}
    end
  end

  def delete_in_txn(%Txn{} = txn, account_id) do
    Txn.q(txn, "DELETE FROM capacity_observations WHERE accountId = ?1", [account_id])
    :ok
  end

  defp put_in_txn(txn, account_id, entry) do
    Txn.q(
      txn,
      """
      INSERT INTO capacity_observations
        (accountId, attemptedAt, completedAt, retryAt, sample, error, history)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      ON CONFLICT(accountId) DO UPDATE SET
        attemptedAt = excluded.attemptedAt,
        completedAt = excluded.completedAt,
        retryAt = excluded.retryAt,
        sample = excluded.sample,
        error = excluded.error,
        history = excluded.history
      """,
      [
        account_id,
        entry.attempted_at,
        entry.completed_at,
        entry.retry_at,
        encode_optional(entry.sample),
        encode_optional(entry.error),
        JSON.encode!(entry.history)
      ]
    )
  end

  defp decode_entry([]), do: Observation.empty()

  defp decode_entry([[attempted, completed, retry_at, sample, error, history]]) do
    %{
      attempted_at: attempted,
      completed_at: completed,
      retry_at: retry_at,
      sample: sample && decode_sample(JSON.decode!(sample)),
      error: error && fields(JSON.decode!(error), @error),
      history: Enum.map(JSON.decode!(history), &decode_history/1)
    }
  end

  defp decode_sample(raw) do
    raw
    |> fields(@sample)
    |> Map.update!(:windows, &Enum.map(&1, fn window -> fields(window, @window) end))
    |> Map.update!(
      :diagnostics,
      &Enum.map(&1, fn diagnostic -> fields(diagnostic, @diagnostic) end)
    )
    |> Map.update!(:subscription, &fields(&1, @subscription))
  end

  defp decode_history(%{"windows" => windows} = raw) when is_list(windows) do
    raw
    |> fields([:plan, :observed_at, :windows])
    |> Map.put(:windows, Enum.map(windows, &fields(&1, @window)))
  end

  defp fields(raw, keys) when is_map(raw) do
    for key <- keys, {:ok, value} <- [Map.fetch(raw, Atom.to_string(key))], into: %{} do
      {key, value}
    end
  end

  defp encode_optional(nil), do: nil
  defp encode_optional(value), do: JSON.encode!(value)
end
