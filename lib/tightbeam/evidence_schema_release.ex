defmodule Tightbeam.EvidenceSchemaRelease do
  @moduledoc false

  alias Tightbeam.{MementoJudgments, Mementos, Schema}
  alias Tightbeam.DB.Txn

  @required_columns [
    {"artifacts", "producedByAssignmentId"},
    {"attests", "artifactId"},
    {"attests", "contentSha256"}
  ]

  @triggers """
  CREATE TRIGGER IF NOT EXISTS attests_evidence_insert BEFORE INSERT ON attests
  WHEN (NEW.artifactId IS NULL) != (NEW.contentSha256 IS NULL)
    OR (NEW.artifactId IS NOT NULL AND NEW.kind != 'verdict')
    OR (NEW.contentSha256 IS NOT NULL AND
        (length(NEW.contentSha256) != 64 OR
         NEW.contentSha256 != lower(NEW.contentSha256) OR
         NEW.contentSha256 GLOB '*[^0-9a-f]*'))
  BEGIN SELECT RAISE(ABORT, 'invalid attest evidence binding'); END;

  CREATE TRIGGER IF NOT EXISTS attests_evidence_immutable BEFORE UPDATE OF artifactId,contentSha256 ON attests
  BEGIN SELECT RAISE(ABORT, 'attest evidence binding is immutable'); END;
  """

  @doc "Add evidence objects after the release line's existing schema migrations."
  def stage_in_txn!(%Txn{} = txn) do
    Enum.each(@required_columns, fn {table, column} ->
      unless Txn.q(txn, "SELECT name FROM pragma_table_info('#{table}') WHERE name=?1", [column]) ==
               [[column]] do
        raise Schema.ShapeError,
          message: "evidence migration requires existing #{table}.#{column}"
      end
    end)

    unless Txn.q(
             txn,
             "SELECT name FROM sqlite_master WHERE type='table' AND name='artifact_contents'"
           ) ==
             [["artifact_contents"]] do
      raise Schema.ShapeError, message: "evidence migration requires existing artifact_contents"
    end

    Txn.exec(txn, @triggers)
    Mementos.schema_in_txn(txn)
    MementoJudgments.schema_in_txn(txn)
    :ok
  end

  @doc "Confirm the successor's required objects on later boots."
  def validate_in_txn!(%Txn{} = txn) do
    required =
      ~w(memento_history memento_current memento_judgments memento_judgment_index_version)

    Enum.each(required, fn name ->
      unless Txn.q(txn, "SELECT name FROM sqlite_master WHERE type='table' AND name=?1", [name]) ==
               [[name]] do
        raise Schema.ShapeError, message: "evidence schema missing #{name}"
      end
    end)

    Enum.each(
      ~w(attests_evidence_insert attests_evidence_immutable memento_judgment_insert),
      fn name ->
        unless Txn.q(txn, "SELECT name FROM sqlite_master WHERE type='trigger' AND name=?1", [
                 name
               ]) ==
                 [[name]] do
          raise Schema.ShapeError, message: "evidence schema missing #{name}"
        end
      end
    )

    :ok
  end
end
