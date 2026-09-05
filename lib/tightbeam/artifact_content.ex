defmodule Tightbeam.ArtifactContent do
  @moduledoc "Durable artifact bytes captured before an artifact is released."

  alias Tightbeam.DB

  defmodule RetirementBlockedError do
    @moduledoc false
    defexception [:artifact_ids, message: "artifact content is not durably captured"]
  end

  @ddl """
  CREATE TABLE IF NOT EXISTS artifact_contents (
    artifactId    TEXT PRIMARY KEY REFERENCES artifacts(artifactId) ON DELETE CASCADE,
    contentSha256 TEXT NOT NULL,
    contentSize   INTEGER NOT NULL CHECK (contentSize >= 0),
    content       BLOB NOT NULL,
    storedAt      INTEGER NOT NULL,
    CHECK (contentSize = length(content))
  );

  CREATE TRIGGER IF NOT EXISTS artifacts_release_requires_content
  BEFORE UPDATE OF state ON artifacts
  WHEN NEW.state = 'released' AND OLD.state != 'released'
  BEGIN
    SELECT CASE WHEN NEW.contentSha256 IS NULL OR NOT EXISTS (
      SELECT 1 FROM artifact_contents
      WHERE artifactId = NEW.artifactId
        AND contentSha256 = NEW.contentSha256
        AND contentSize = length(content)
    ) THEN RAISE(ABORT, 'artifact_content_not_durable') END;
  END;

  CREATE TRIGGER IF NOT EXISTS released_artifact_content_immutable_update
  BEFORE UPDATE ON artifact_contents
  WHEN EXISTS (
    SELECT 1 FROM artifacts
    WHERE artifactId = OLD.artifactId AND state = 'released'
  )
  BEGIN
    SELECT RAISE(ABORT, 'released_artifact_content_immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS released_artifact_content_immutable_delete
  BEFORE DELETE ON artifact_contents
  WHEN EXISTS (
    SELECT 1 FROM artifacts
    WHERE artifactId = OLD.artifactId AND state = 'released'
  )
  BEGIN
    SELECT RAISE(ABORT, 'released_artifact_content_immutable');
  END;
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc false
  @spec create_in_txn(DB.Txn.t()) :: :ok
  def create_in_txn(txn), do: DB.Txn.exec(txn, @ddl)

  @spec prepare(binary(), String.t() | nil) :: {:ok, map()} | {:error, map()}
  def prepare(content, expected_sha256) when is_binary(content) do
    sha256 = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    if is_nil(expected_sha256) or String.downcase(expected_sha256) == sha256 do
      {:ok, %{content: content, sha256: sha256, size: byte_size(content)}}
    else
      {:error,
       %{
         code: "artifact_content_hash_mismatch",
         message: "artifact content does not match contentSha256"
       }}
    end
  end

  @spec store_in_txn(DB.Txn.t(), String.t(), map(), integer()) :: :ok
  def store_in_txn(txn, artifact_id, prepared, stored_at) do
    DB.Txn.q(
      txn,
      """
      INSERT INTO artifact_contents
        (artifactId, contentSha256, contentSize, content, storedAt)
      VALUES (?1, ?2, ?3, ?4, ?5)
      """,
      [
        artifact_id,
        prepared.sha256,
        prepared.size,
        {:blob, prepared.content},
        stored_at
      ]
    )

    :ok
  end

  @spec fetch(DB.server(), String.t()) ::
          {:ok, %{content: binary(), sha256: String.t(), size: non_neg_integer()}}
          | :not_found
          | {:error, :not_released | :integrity_invalid}
  def fetch(db \\ Tightbeam.DB, artifact_id) do
    case DB.query(
           db,
           """
           SELECT a.state, a.contentSha256,
                  c.contentSha256, c.contentSize, c.content
           FROM artifacts a
           LEFT JOIN artifact_contents c ON c.artifactId = a.artifactId
           WHERE a.artifactId = ?1
           """,
           [artifact_id]
         ) do
      {:ok, []} ->
        :not_found

      {:ok, [[state, _artifact_sha, _stored_sha, _size, _content]]}
      when state != "released" ->
        {:error, :not_released}

      {:ok, [["released", artifact_sha, stored_sha, size, content]]}
      when is_binary(artifact_sha) and is_binary(stored_sha) and is_integer(size) and
             is_binary(content) ->
        actual_sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

        if artifact_sha == stored_sha and stored_sha == actual_sha and size == byte_size(content) do
          {:ok, %{content: content, sha256: stored_sha, size: size}}
        else
          {:error, :integrity_invalid}
        end

      {:ok, [_row]} ->
        {:error, :integrity_invalid}
    end
  end

  @spec ensure_retirement_ready_in_txn!(DB.Txn.t(), [String.t()]) :: :ok
  def ensure_retirement_ready_in_txn!(txn, session_keys) do
    blockers =
      session_keys
      |> Enum.flat_map(fn session_key ->
        DB.Txn.q(
          txn,
          """
          SELECT a.artifactId, a.state, a.contentSha256,
                 c.contentSha256, c.contentSize, c.content
          FROM artifacts a
          LEFT JOIN artifact_contents c ON c.artifactId = a.artifactId
          WHERE a.createdBySession = ?1
          ORDER BY a.artifactId
          """,
          [session_key]
        )
      end)
      |> Enum.reject(&durable_released_row?/1)
      |> Enum.map(&hd/1)
      |> Enum.uniq()
      |> Enum.sort()

    if blockers == [] do
      :ok
    else
      raise RetirementBlockedError,
        artifact_ids: blockers,
        message: "artifact content is not durably captured: #{Enum.join(blockers, ", ")}"
    end
  end

  defp durable_released_row?([
         _artifact_id,
         "released",
         artifact_sha,
         stored_sha,
         size,
         content
       ])
       when is_binary(artifact_sha) and is_binary(stored_sha) and is_integer(size) and
              is_binary(content) do
    actual_sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    artifact_sha == stored_sha and stored_sha == actual_sha and size == byte_size(content)
  end

  defp durable_released_row?(_row), do: false
end
