defmodule Tightbeam.ExecutionMapTurnVersions do
  @moduledoc false

  require Logger

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  # A source group has a single visibility outcome. Fingerprint its revision
  # rather than reading every turn in the group for every execution-map page.
  # Keep empty groups so reusing a source group cannot reuse a prior revision.
  @batch_size 1_024

  @ddl """
  CREATE TABLE execution_map_turn_versions (
    jobRef TEXT NOT NULL,
    assignmentId TEXT NOT NULL,
    sessionKey TEXT NOT NULL,
    turnCount INTEGER NOT NULL CHECK(turnCount >= 0),
    revision INTEGER NOT NULL CHECK(revision > 0),
    PRIMARY KEY (jobRef, assignmentId, sessionKey)
  ) WITHOUT ROWID;

  CREATE INDEX execution_map_turn_versions_assignment
    ON execution_map_turn_versions (assignmentId) WHERE turnCount > 0;
  CREATE INDEX execution_map_turn_versions_job
    ON execution_map_turn_versions (jobRef) WHERE turnCount > 0;
  """

  # The boot snapshot's sequence fence divides indexed from unindexed rows.
  # Writes above the fence are indexed immediately. Within the historical
  # range, only rows at or below the committed cursor are maintained by triggers.
  @indexed_new """
  EXISTS (
    SELECT 1 FROM execution_map_turn_version_activation
    WHERE NEW.seq <= lastSeq OR NEW.seq > throughSeq
  )
  """
  @indexed_old String.replace(@indexed_new, "NEW.", "OLD.")

  @add """
  INSERT INTO execution_map_turn_versions (jobRef, assignmentId, sessionKey, turnCount, revision)
  SELECT COALESCE(NEW.jobRef, ''), COALESCE(NEW.assignmentId, ''), NEW.sessionKey, 1, 1
  WHERE (COALESCE(NEW.jobRef, '') <> '' OR COALESCE(NEW.assignmentId, '') <> '')
    AND #{@indexed_new}
  ON CONFLICT(jobRef, assignmentId, sessionKey) DO UPDATE
  SET turnCount = turnCount + 1, revision = revision + 1;
  """

  @remove """
  UPDATE execution_map_turn_versions
  SET turnCount = turnCount - 1, revision = revision + 1
  WHERE jobRef = COALESCE(OLD.jobRef, '')
    AND assignmentId = COALESCE(OLD.assignmentId, '')
    AND sessionKey = OLD.sessionKey
    AND #{@indexed_old};
  """

  @triggers """
  CREATE TRIGGER execution_map_turn_versions_insert
  AFTER INSERT ON turns
  BEGIN
    #{@add}
  END;

  CREATE TRIGGER execution_map_turn_versions_delete
  AFTER DELETE ON turns
  BEGIN
    #{@remove}
  END;

  CREATE TRIGGER execution_map_turn_versions_update
  AFTER UPDATE OF seq, jobRef, assignmentId, sessionKey, createdAt, startedAt, endedAt ON turns
  WHEN NEW.seq IS NOT OLD.seq
    OR NEW.jobRef IS NOT OLD.jobRef
    OR NEW.assignmentId IS NOT OLD.assignmentId
    OR NEW.sessionKey IS NOT OLD.sessionKey
    OR MAX(COALESCE(NEW.endedAt, 0), COALESCE(NEW.startedAt, 0), NEW.createdAt, NEW.seq)
       <> MAX(COALESCE(OLD.endedAt, 0), COALESCE(OLD.startedAt, 0), OLD.createdAt, OLD.seq)
  BEGIN
    #{@remove}
    #{@add}
  END;
  """

  def ensure_schema(db) do
    case DB.transaction(db, fn txn ->
           Txn.exec(txn, """
           CREATE TABLE IF NOT EXISTS execution_map_turn_version_activation (
             id INTEGER PRIMARY KEY CHECK(id = 1),
             lastSeq INTEGER NOT NULL,
             throughSeq INTEGER NOT NULL
           );
           INSERT INTO execution_map_turn_version_activation (id, lastSeq, throughSeq)
           VALUES (1, 0, COALESCE((SELECT MAX(seq) FROM turns), 0))
           ON CONFLICT DO NOTHING;
           """)

           if Txn.changes(txn) == 1 do
             Txn.exec(txn, @ddl)
             Txn.exec(txn, @triggers)
           end

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  def ready?(txn) do
    [[ready]] =
      Txn.q(txn, "SELECT lastSeq >= throughSeq FROM execution_map_turn_version_activation")

    ready == 1
  end

  def child_spec(db) do
    Supervisor.child_spec({Task, fn -> backfill(db) end},
      id: __MODULE__,
      restart: :temporary
    )
  end

  def backfill(db), do: backfill(db, 250, MapSet.new())

  defp backfill(db, delay_ms, warned) do
    case run_batch(db) do
      :more ->
        backfill(db, 250, warned)

      :done ->
        :ok

      :overloaded ->
        retry(db, delay_ms, warned)

      {:error, kind} ->
        unless MapSet.member?(warned, kind) do
          Logger.warning("execution-map turn backfill batch failed; retrying (#{inspect(kind)})")
        end

        retry(db, delay_ms, MapSet.put(warned, kind))
    end
  end

  defp retry(db, delay_ms, warned) do
    Process.sleep(delay_ms)
    backfill(db, min(delay_ms * 2, 5_000), warned)
  end

  defp run_batch(db) do
    case DB.background_pass(fn -> backfill_batch(db) end, :overloaded) do
      {:error, reason} -> {:error, error_kind(reason)}
      status -> status
    end
  rescue
    error -> {:error, error.__struct__}
  catch
    :exit, reason -> {:error, {:exit, error_kind(reason)}}
  end

  defp error_kind(%{__struct__: kind}), do: kind
  defp error_kind({kind, _}) when is_atom(kind), do: kind
  defp error_kind(kind) when is_atom(kind), do: kind
  defp error_kind(_reason), do: :unknown

  @doc false
  def backfill_batch(db) do
    case DB.transaction(db, &backfill_batch_in_txn/1) do
      {:ok, status} -> status
      {:error, _} = error -> error
    end
  end

  defp backfill_batch_in_txn(txn) do
    [[last_seq, through_seq]] =
      Txn.q(txn, "SELECT lastSeq, throughSeq FROM execution_map_turn_version_activation")

    if last_seq >= through_seq do
      :done
    else
      [[batch_end]] =
        Txn.q(
          txn,
          """
          SELECT COALESCE(MAX(seq), ?2)
          FROM (
            SELECT seq FROM turns WHERE seq > ?1 AND seq <= ?2 ORDER BY seq LIMIT ?3
          )
          """,
          [last_seq, through_seq, @batch_size]
        )

      Txn.q(
        txn,
        """
        INSERT INTO execution_map_turn_versions (jobRef, assignmentId, sessionKey, turnCount, revision)
        SELECT COALESCE(jobRef, ''), COALESCE(assignmentId, ''), sessionKey, COUNT(*), 1
        FROM turns
        WHERE seq > ?1 AND seq <= ?2
          AND (COALESCE(jobRef, '') <> '' OR COALESCE(assignmentId, '') <> '')
        GROUP BY COALESCE(jobRef, ''), COALESCE(assignmentId, ''), sessionKey
        ON CONFLICT(jobRef, assignmentId, sessionKey) DO UPDATE
        SET turnCount = turnCount + excluded.turnCount, revision = revision + 1
        """,
        [last_seq, batch_end]
      )

      Txn.q(txn, "UPDATE execution_map_turn_version_activation SET lastSeq = ?1", [batch_end])
      if batch_end >= through_seq, do: :done, else: :more
    end
  end
end
