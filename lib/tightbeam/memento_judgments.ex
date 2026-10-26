defmodule Tightbeam.MementoJudgments do
  @moduledoc """
  Structural indexes for the latest holder-authored judgment and the latest
  linked-review judgment. Eligibility never depends on judgment kind, evidence,
  effect classification, or reviewer independence.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS memento_judgments (
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    selector TEXT NOT NULL CHECK(selector IN ('holder','linked_review')),
    ts INTEGER NOT NULL,
    attestRow INTEGER NOT NULL,
    attestId TEXT NOT NULL REFERENCES attests(id),
    judgmentKind TEXT,
    independent INTEGER NOT NULL CHECK(independent IN (0,1)),
    PRIMARY KEY(assignmentId,selector,ts,attestRow)
  ) WITHOUT ROWID;
  CREATE TABLE IF NOT EXISTS memento_judgment_index_version (
    version INTEGER PRIMARY KEY CHECK(version=1)
  );
  CREATE TRIGGER IF NOT EXISTS memento_judgment_insert AFTER INSERT ON attests
  WHEN NEW.kind='verdict'
  BEGIN
    INSERT INTO memento_judgments
      (assignmentId,selector,ts,attestRow,attestId,judgmentKind,independent)
    SELECT a.id,'holder',NEW.ts,NEW.rowid,NEW.id,NEW.verdictKind,0
    FROM assignments a
    WHERE a.id=NEW.assignmentId AND NEW.bySession=a.holderKey AND NEW.byUser IS NULL;

    INSERT INTO memento_judgments
      (assignmentId,selector,ts,attestRow,attestId,judgmentKind,independent)
    SELECT p.id,'linked_review',NEW.ts,NEW.rowid,NEW.id,NEW.verdictKind,
           CASE WHEN r.holderKey!=p.holderKey THEN 1 ELSE 0 END
    FROM assignments r JOIN assignments p ON p.id=r.reviewsAssignmentId
    WHERE r.id=NEW.assignmentId AND NEW.bySession=r.holderKey AND NEW.byUser IS NULL;
  END;
  """

  @doc "Create and initialize the structural index once, without modifying legacy judgments."
  def ensure_schema(db) do
    case DB.transaction(db, &schema_in_txn/1) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  @doc false
  def schema_in_txn(%Txn{} = txn) do
    Txn.exec(txn, @ddl)

    # One-time index construction, not normal-operation history reconstruction.
    case Txn.q(txn, "SELECT version FROM memento_judgment_index_version") do
      [] ->
        Txn.q(txn, """
        INSERT INTO memento_judgments
          (assignmentId,selector,ts,attestRow,attestId,judgmentKind,independent)
        SELECT a.id,'holder',v.ts,v.rowid,v.id,v.verdictKind,0
        FROM attests v JOIN assignments a ON a.id=v.assignmentId
        WHERE v.kind='verdict' AND v.bySession=a.holderKey AND v.byUser IS NULL
        """)

        Txn.q(txn, """
        INSERT INTO memento_judgments
          (assignmentId,selector,ts,attestRow,attestId,judgmentKind,independent)
        SELECT p.id,'linked_review',v.ts,v.rowid,v.id,v.verdictKind,
               CASE WHEN r.holderKey!=p.holderKey THEN 1 ELSE 0 END
        FROM attests v JOIN assignments r ON r.id=v.assignmentId
        JOIN assignments p ON p.id=r.reviewsAssignmentId
        WHERE v.kind='verdict' AND v.bySession=r.holderKey AND v.byUser IS NULL
        """)

        Txn.q(txn, "INSERT INTO memento_judgment_index_version(version) VALUES (1)")

      [[1]] ->
        :ok
    end

    :ok
  end

  @doc "Select one eligible judgment by committed timestamp and immutable row id."
  def latest(%Txn{} = txn, assignment_id, selector)
      when selector in ["holder", "linked_review"] do
    case Txn.q(
           txn,
           """
           SELECT attestId,judgmentKind,independent FROM memento_judgments
           WHERE assignmentId=?1 AND selector=?2
           ORDER BY ts DESC,attestRow DESC LIMIT 1
           """,
           [assignment_id, selector]
         ) do
      [] -> nil
      [[id, kind, independent]] -> %{id: id, judgment_kind: kind, independent: independent == 1}
    end
  end

  def latest(db, assignment_id, selector) when selector in ["holder", "linked_review"] do
    case DB.query(
           db,
           """
           SELECT attestId,judgmentKind,independent FROM memento_judgments
           WHERE assignmentId=?1 AND selector=?2
           ORDER BY ts DESC,attestRow DESC LIMIT 1
           """,
           [assignment_id, selector]
         ) do
      {:ok, []} ->
        nil

      {:ok, [[id, kind, independent]]} ->
        %{id: id, judgment_kind: kind, independent: independent == 1}
    end
  end
end
