defmodule Tightbeam.ArtifactContent do
  @moduledoc """
  Durable content schema for artifacts Tightbeam took into custody.

  ## What these triggers do and do not claim

  They protect CUSTODY BYTES, not the released state. `released` means the
  artifact has left its session workspace. Whether Tightbeam holds its bytes is
  answered by the presence of an `artifact_contents` row, not by the state word,
  and that is exactly what these triggers ask.

  An artifact whose origin names a machine, or that otherwise resolves outside
  its session workspace, is EXTERNAL: `Tightbeam.Artifacts` releases it without
  ever touching the workspace, because there is nothing to take into custody and
  the row is the record. Retirement of such a session proceeds unconditionally,
  the terminal state stays `released`, and the origin stays intact and readable.
  No custody is claimed for it, so no durable content is required of it.

  ## Why custody is keyed on the content row and not on `OLD.state`

  `archived` looks like it should mean custody: the table's own
  `CHECK ((state = 'archived') = (home IS NOT NULL))` makes "was archived" and
  "had a custody location" the same statement. But a custody location is where
  the bytes went, not proof they were readable. `archive_session/4` moves the
  workspace wholesale and declines custody of anything it cannot read as bytes,
  so an `archived` row with no stored content is reachable, and keying on
  `OLD.state = 'archived'` would abort its release forever. An artifact
  Tightbeam never captured must never block a transition.

  So the question asked here is the narrow one that is always answerable from
  rows: IF content was stored for this artifact, the accounting must agree with
  it. A row we never captured is not refused; it simply never claims to hold
  content.

  A stored content row is itself custody evidence, which covers the row that is
  already `released`: its accounting cannot later be repointed away from the
  bytes, and the bytes cannot be mutated or dropped.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS artifact_contents (
    artifactId TEXT PRIMARY KEY REFERENCES artifacts(artifactId),
    contentSha256 TEXT NOT NULL,
    contentSize INTEGER NOT NULL CHECK (contentSize >= 0),
    content BLOB NOT NULL,
    storedAt INTEGER NOT NULL,
    CHECK (length(content) = contentSize),
    CHECK (length(contentSha256) = 64 AND contentSha256 = lower(contentSha256))
  );

  CREATE TRIGGER IF NOT EXISTS artifacts_released_requires_content_insert
  BEFORE INSERT ON artifacts
  WHEN NEW.state = 'released'
   AND EXISTS (
     SELECT 1 FROM artifact_contents c WHERE c.artifactId = NEW.artifactId
   )
   AND NOT EXISTS (
     SELECT 1 FROM artifact_contents c
     WHERE c.artifactId = NEW.artifactId AND c.contentSha256 = NEW.contentSha256
   )
  BEGIN
    SELECT RAISE(ABORT, 'released artifact requires durable content');
  END;

  CREATE TRIGGER IF NOT EXISTS artifacts_released_requires_content_update
  BEFORE UPDATE OF state, contentSha256 ON artifacts
  WHEN NEW.state = 'released'
   AND EXISTS (
     SELECT 1 FROM artifact_contents c WHERE c.artifactId = NEW.artifactId
   )
   AND NOT EXISTS (
     SELECT 1 FROM artifact_contents c
     WHERE c.artifactId = NEW.artifactId AND c.contentSha256 = NEW.contentSha256
   )
  BEGIN
    SELECT RAISE(ABORT, 'released artifact requires durable content');
  END;

  CREATE TRIGGER IF NOT EXISTS artifact_contents_released_immutable
  BEFORE UPDATE ON artifact_contents
  WHEN EXISTS (
    SELECT 1 FROM artifacts a
    WHERE a.artifactId = OLD.artifactId AND a.state = 'released'
  )
  BEGIN
    SELECT RAISE(ABORT, 'released artifact content is immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS artifact_contents_released_retained
  BEFORE DELETE ON artifact_contents
  WHEN EXISTS (
    SELECT 1 FROM artifacts a
    WHERE a.artifactId = OLD.artifactId AND a.state = 'released'
  )
  BEGIN
    SELECT RAISE(ABORT, 'released artifact content is retained');
  END;
  """

  def ensure_schema(db), do: DB.execute(db, @ddl)
  def schema_in_txn(%Txn{} = txn), do: Txn.exec(txn, @ddl)

  @doc """
  Store the exact bytes Tightbeam is taking into custody, in the caller's
  transaction, before the row reaches a terminal state.

  The upsert is for re-archival of a row that returned to the workspace, which
  is why it is an upsert and not an insert. It cannot launder a released row's
  accounting: `artifact_contents_released_immutable` refuses the UPDATE branch
  while the artifact is `released`.
  """
  @spec store_in_txn(Txn.t(), String.t(), String.t(), binary(), integer()) :: :ok
  def store_in_txn(%Txn{} = txn, artifact_id, digest, bytes, stored_at) do
    Txn.q(
      txn,
      """
      INSERT INTO artifact_contents (artifactId, contentSha256, contentSize, content, storedAt)
      VALUES (?1, ?2, ?3, ?4, ?5)
      ON CONFLICT(artifactId) DO UPDATE SET
        contentSha256 = excluded.contentSha256,
        contentSize = excluded.contentSize,
        content = excluded.content,
        storedAt = excluded.storedAt
      """,
      [artifact_id, digest, byte_size(bytes), {:blob, bytes}, stored_at]
    )

    :ok
  end
end
