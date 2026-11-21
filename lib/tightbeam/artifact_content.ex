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

  alias Tightbeam.{ArtifactArchive, ArtifactBlobStore, ArtifactCapture, Artifacts, DB}
  alias Tightbeam.DB.Txn

  @table_ddl """
  CREATE TABLE IF NOT EXISTS artifact_contents (
    artifactId TEXT PRIMARY KEY REFERENCES artifacts(artifactId),
    contentSha256 TEXT NOT NULL,
    contentSize INTEGER NOT NULL CHECK (contentSize >= 0),
    content BLOB NOT NULL,
    storedAt INTEGER NOT NULL,
    CHECK (length(content) = contentSize),
    CHECK (length(contentSha256) = 64 AND contentSha256 = lower(contentSha256))
  );
  """

  @insert_ddl """
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
  """

  @update_ddl """
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
  """

  @immutable_ddl """
  CREATE TRIGGER IF NOT EXISTS artifact_contents_released_immutable
  BEFORE UPDATE ON artifact_contents
  WHEN EXISTS (
    SELECT 1 FROM artifacts a
    WHERE a.artifactId = OLD.artifactId AND a.state = 'released'
  )
  BEGIN
    SELECT RAISE(ABORT, 'released artifact content is immutable');
  END;
  """

  @retained_ddl """
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

  @schema_objects [
    {"table", "artifact_contents", @table_ddl},
    {"trigger", "artifacts_released_requires_content_insert", @insert_ddl},
    {"trigger", "artifacts_released_requires_content_update", @update_ddl},
    {"trigger", "artifact_contents_released_immutable", @immutable_ddl},
    {"trigger", "artifact_contents_released_retained", @retained_ddl}
  ]
  @ddl Enum.map_join(@schema_objects, "\n", fn {_, _, sql} -> sql end)

  @doc false
  def schema_objects, do: @schema_objects

  def ensure_schema(db), do: DB.execute(db, @ddl)
  def schema_in_txn(%Txn{} = txn), do: Txn.exec(txn, @ddl)

  @doc "Read archived or captured bytes for an authenticated artifact reader."
  def fetch_call(db, call, config \\ %{})

  def fetch_call(
        db,
        %{
          principal: {kind, id},
          rest_principal: %{kind: visibility_kind, id: id, is_admin: is_admin} = principal,
          params: %{artifact_id: artifact_id} = params
        },
        config
      )
      when ((kind == :user and visibility_kind == "user") or
              (kind == :session and visibility_kind == "session") or
              (kind == :process and visibility_kind == "process")) and
             is_binary(id) and is_boolean(is_admin) and is_binary(artifact_id) and
             artifact_id != "" and map_size(params) == 1 do
    case DB.transaction(db, fn txn ->
           row = Tightbeam.Artifacts.get_in_txn(txn, artifact_id)

           if row != nil and
                Tightbeam.StateVisibility.core_detail_visible?(txn, "artifacts", row, principal) do
             {:visible, row}
           else
             %{code: "not_found"}
           end
         end) do
      {:ok, {:visible, row}} ->
        result = fetch_visible(db, row, config)
        if row[:custody], do: Map.put(result, :custody, row.custody), else: result

      {:ok, result} ->
        result

      {:error, error} ->
        raise error
    end
  end

  def fetch_call(_db, %{principal: {kind, _}}, _config) when kind in [:user, :session, :process],
    do: %{code: "invalid", message: "artifact-content-fetch requires only artifactId"}

  def fetch_call(_db, _call, _config), do: %{code: "forbidden"}

  defp fetch_visible(_db, %{custody: "pinned"} = row, config) do
    case ArtifactBlobStore.read(config.artifact_blob_root, row.content_sha256) do
      {:ok, bytes} ->
        digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        content_result(row, digest, byte_size(bytes), bytes, "pinned_copy")

      {:error, reason} ->
        %{
          code: "artifact_pin_unavailable",
          message: "could not read pinned copy: #{inspect(reason)}"
        }
    end
  end

  defp fetch_visible(db, %{state: "archived"} = row, config) do
    case fetch(db, row.artifact_id) do
      nil ->
        fetch_archive(db, row, config)

      captured ->
        status =
          case ArtifactArchive.read(
                 db,
                 row,
                 Map.put(config, :artifact_archive_inline_limit_bytes, 0)
               ) do
            {:ok, archive} ->
              row
              |> content_result(archive.sha256, archive.size, nil, "archived_home")
              |> Map.drop([:artifact_id, :code])
              |> Map.put(:archived_home, archive.home)

            {:error, reason} ->
              row
              |> unavailable_archive(reason)
              |> Map.delete(:code)
              |> Map.put(:verification_status, "unavailable")
          end

        row
        |> verified_capture(captured)
        |> Map.put(:archive_verification, status)
    end
  end

  defp fetch_visible(db, row, _config) do
    case fetch(db, row.artifact_id) do
      nil ->
        message =
          if row[:custody] == "unpinned",
            do: "artifact was recorded unpinned",
            else: "artifact has no stored content"

        %{code: "content_not_captured", message: message}

      captured ->
        captured
        |> Map.delete(:content)
        |> Map.put(:content_base64, Base.encode64(captured.content))
    end
  end

  def capacity(%{artifact_blob_store: store}) do
    case ArtifactBlobStore.capacity(store) do
      {:ok, result} -> result
      {:error, reason} -> %{code: "artifact_capacity_unavailable", message: inspect(reason)}
    end
  end

  def capacity(_config), do: %{code: "artifact_store_unavailable"}

  def promote_call(db, %{rest_principal: principal, params: %{artifact_id: id}}, %{
        artifact_blob_store: store
      }) do
    {:ok, selected} =
      DB.transaction(db, fn txn ->
        row = Artifacts.get_in_txn(txn, id)

        if row && Tightbeam.StateVisibility.core_detail_visible?(txn, "artifacts", row, principal) do
          captured = if row[:custody] != "pinned", do: fetch(txn, id)
          {row, captured}
        end
      end)

    case selected do
      {%{custody: "pinned"} = row, _} ->
        row

      {%{content_sha256: digest}, %{content_sha256: digest} = captured} ->
        case ArtifactCapture.promote(store, captured) do
          %{custody: "pinned"} -> Artifacts.promote_capture(db, id, digest)
          error -> error
        end

      {_row, _capture} ->
        %{
          code: "content_not_captured",
          message: "promotion requires a stored capture matching the recorded SHA-256"
        }

      nil ->
        %{code: "not_found"}
    end
  end

  def promote_call(_db, _call, _config), do: %{code: "artifact_store_unavailable"}

  defp fetch_archive(db, row, config) do
    case ArtifactArchive.read(db, row, config) do
      {:ok, archive} ->
        result = content_result(row, archive.sha256, archive.size, archive.bytes, "archived_home")

        if is_nil(archive.bytes) do
          Map.merge(result, %{
            archived_home: archive.home,
            content_size: archive.size,
            content_unavailable_reason: "archived artifact is too large to return inline"
          })
        else
          result
        end

      {:error, reason} ->
        unavailable_archive(row, reason)
    end
  end

  defp unavailable_archive(row, reason) do
    %{
      code: "archived_content_unavailable",
      message: "could not read archived home #{row.home}: #{inspect(reason)}",
      archived_home: row.home,
      source: "archived_home"
    }
  end

  defp verified_capture(row, captured) do
    bytes = captured.content
    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    content_result(row, digest, byte_size(bytes), bytes, "stored_content")
  end

  defp content_result(row, observed, size, bytes, source) do
    expected = row.content_sha256

    if expected && String.downcase(expected) != observed do
      %{
        code: "artifact_sha_mismatch",
        message:
          "recorded sha does not match current bytes (expected #{expected}, observed #{observed})",
        expected_sha256: expected,
        observed_sha256: observed,
        source: source,
        verification_status: "mismatch"
      }
    else
      result = %{
        artifact_id: row.artifact_id,
        content_sha256: observed,
        content_size: size,
        expected_sha256: expected,
        source: source,
        verification_status: if(expected, do: "match", else: "unverified")
      }

      if is_nil(bytes), do: result, else: Map.put(result, :content_base64, Base.encode64(bytes))
    end
  end

  @doc """
  Read captured bytes by artifact ID, or nil when no content was captured.

  This storage read never opens originPath or home. Callers exposing it outside
  the storage layer must authorize the artifact before returning its content.
  """
  @spec fetch(DB.server(), String.t()) :: map() | nil
  def fetch(db \\ Tightbeam.DB, artifact_id) do
    case DB.query(
           db,
           "SELECT contentSha256, contentSize, content FROM artifact_contents WHERE artifactId=?1",
           [artifact_id]
         ) do
      {:ok, [[digest, size, bytes]]} ->
        %{artifact_id: artifact_id, content_sha256: digest, content_size: size, content: bytes}

      {:ok, []} ->
        fetch_pinned(db, artifact_id)

      {:error, error} ->
        raise error
    end
  end

  defp fetch_pinned(db, artifact_id) do
    case DB.query(
           db,
           """
           SELECT a.contentSha256 FROM artifacts a
           JOIN artifact_custody c ON c.artifactId=a.artifactId
           WHERE a.artifactId=?1 AND c.status='pinned'
           """,
           [artifact_id]
         ) do
      {:ok, [[digest]]} ->
        base_dir =
          Application.get_env(:tightbeam, :base_dir, Path.join(System.user_home!(), ".tightbeam"))

        root = ArtifactBlobStore.options(base_dir)[:root]

        case ArtifactBlobStore.read(root, digest) do
          {:ok, bytes} ->
            %{
              artifact_id: artifact_id,
              content_sha256: digest,
              content_size: byte_size(bytes),
              content: bytes
            }

          {:error, _reason} ->
            nil
        end

      {:ok, []} ->
        nil

      {:error, error} ->
        raise error
    end
  end

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
