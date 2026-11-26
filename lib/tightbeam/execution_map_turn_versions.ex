defmodule Tightbeam.ExecutionMapTurnVersions do
  @moduledoc false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  # A source group has a single visibility outcome. Fingerprint its revision
  # rather than reading every turn in the group for every execution-map page.
  # Keep empty groups so reusing a source group cannot reuse a prior revision.
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

  INSERT INTO execution_map_turn_versions (jobRef, assignmentId, sessionKey, turnCount, revision)
  SELECT COALESCE(jobRef, ''), COALESCE(assignmentId, ''), sessionKey, COUNT(*), 1
  FROM turns
  WHERE COALESCE(jobRef, '') <> '' OR COALESCE(assignmentId, '') <> ''
  GROUP BY COALESCE(jobRef, ''), COALESCE(assignmentId, ''), sessionKey;
  """

  @add """
  INSERT INTO execution_map_turn_versions (jobRef, assignmentId, sessionKey, turnCount, revision)
  SELECT COALESCE(NEW.jobRef, ''), COALESCE(NEW.assignmentId, ''), NEW.sessionKey, 1, 1
  WHERE COALESCE(NEW.jobRef, '') <> '' OR COALESCE(NEW.assignmentId, '') <> ''
  ON CONFLICT(jobRef, assignmentId, sessionKey) DO UPDATE
  SET turnCount = turnCount + 1, revision = revision + 1;
  """

  @remove """
  UPDATE execution_map_turn_versions
  SET turnCount = turnCount - 1, revision = revision + 1
  WHERE jobRef = COALESCE(OLD.jobRef, '')
    AND assignmentId = COALESCE(OLD.assignmentId, '')
    AND sessionKey = OLD.sessionKey;
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
             id INTEGER PRIMARY KEY CHECK(id = 1)
           );
           INSERT INTO execution_map_turn_version_activation VALUES (1) ON CONFLICT DO NOTHING;
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
end
