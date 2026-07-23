defmodule Tightbeam.Artifacts do
  @moduledoc "Artifact pointers and provenance."

  alias Tightbeam.DB

  @ddl """
  CREATE TABLE IF NOT EXISTS artifacts (
    artifactId        TEXT PRIMARY KEY,
    kind              TEXT NOT NULL CHECK (kind IN ('spec','report','doc','data','other')),
    title             TEXT NOT NULL,
    description       TEXT,
    createdBySession  TEXT NOT NULL REFERENCES sessions(sessionKey),
    workItemId        TEXT NOT NULL REFERENCES work_items(id),
    parentSession     TEXT REFERENCES sessions(sessionKey),
    originPath        TEXT NOT NULL,
    contentSha256     TEXT,
    recordedMessageId TEXT NOT NULL REFERENCES messages(id),
    state             TEXT NOT NULL DEFAULT 'in-workspace'
                      CHECK (state IN ('in-workspace','archived','released')),
    home              TEXT,
    createdAt         INTEGER NOT NULL,
    updatedAt         INTEGER NOT NULL,
    CHECK ((state = 'archived') = (home IS NOT NULL))
  );
  CREATE INDEX IF NOT EXISTS artifacts_work_item ON artifacts (workItemId);
  CREATE INDEX IF NOT EXISTS artifacts_created_by_session ON artifacts (createdBySession);
  CREATE INDEX IF NOT EXISTS artifacts_recorded_message ON artifacts (recordedMessageId);
  """

  @doc "Create the artifact registry schema."
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc "Record a deliberate artifact pointer for the authenticated calling session."
  @spec record(DB.server(), map()) :: map()
  def record(db \\ Tightbeam.DB, call) do
    case {call[:principal], call[:session_key]} do
      {{:session, session_key}, session_key} when is_binary(session_key) ->
        artifact_id = "art_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
        parent_session = parent_session(db, session_key)
        now = now()

        {:ok, _} =
          DB.query(
            db,
            """
            INSERT INTO artifacts
              (artifactId, kind, title, description, createdBySession, workItemId,
               parentSession, originPath, contentSha256, recordedMessageId,
               state, home, createdAt, updatedAt)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
                    'in-workspace', NULL, ?11, ?11)
            """,
            [
              artifact_id,
              call.params.kind,
              call.params.title,
              call.params[:description],
              session_key,
              call.params.work_item_id,
              parent_session,
              call.params.origin_path,
              call.params[:content_sha256],
              call.recorded_message_id,
              now
            ]
          )

        get(db, artifact_id)

      _ ->
        %{code: "invalid", message: "artifact-record requires a session caller"}
    end
  end

  @doc "Fetch one artifact row, or nil."
  @spec get(DB.server(), String.t()) :: map() | nil
  def get(db \\ Tightbeam.DB, artifact_id) do
    case DB.query(db, "SELECT #{columns()} FROM artifacts WHERE artifactId = ?1", [artifact_id]) do
      {:ok, [row]} -> artifact(row)
      {:ok, []} -> nil
    end
  end

  @doc "List artifacts matching exact optional provenance filters, newest first."
  @spec list(DB.server(), map()) :: [map()]
  def list(db \\ Tightbeam.DB, filters \\ %{}) do
    {clauses, params} =
      [
        {"workItemId", "=", filters[:work_item_id]},
        {"createdBySession", "=", filters[:session_key]},
        {"kind", "=", filters[:kind]},
        {"createdAt", ">=", filters[:created_after]},
        {"createdAt", "<=", filters[:created_before]}
      ]
      |> Enum.reject(fn {_column, _operator, value} -> is_nil(value) end)
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {{column, operator, value}, index}, values ->
        {"#{column} #{operator} ?#{index}", values ++ [value]}
      end)

    where = if clauses == [], do: "", else: " WHERE " <> Enum.join(clauses, " AND ")

    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{columns()} FROM artifacts#{where} ORDER BY createdAt DESC, artifactId DESC",
        params
      )

    Enum.map(rows, &artifact/1)
  end

  @doc "Archive in-workspace rows after a session workspace has been reaped."
  @spec archive_session(DB.server(), String.t(), String.t() | nil, String.t()) :: :ok
  def archive_session(db \\ Tightbeam.DB, session_key, workspace_path, archive_root) do
    rows = list(db, %{session_key: session_key})
    live = Enum.filter(rows, &(&1.state == "in-workspace"))

    if live == [] do
      remove_workspace(workspace_path)
    else
      ensure_workspace_available!(workspace_path)

      relative_paths =
        Map.new(live, fn row ->
          {row.artifact_id, archived_relative_path!(row.origin_path, workspace_path)}
        end)

      archived_path = archive_workspace!(workspace_path, archive_root, session_key)
      updated_at = now()

      {:ok, :ok} =
        DB.transaction(db, fn txn ->
          Enum.each(live, fn row ->
            DB.Txn.q(
              txn,
              """
              UPDATE artifacts
              SET state = 'archived', home = ?2, updatedAt = ?3
              WHERE artifactId = ?1 AND state = 'in-workspace'
              """,
              [
                row.artifact_id,
                Path.join(archived_path, Map.fetch!(relative_paths, row.artifact_id)),
                updated_at
              ]
            )
          end)

          :ok
        end)
    end

    :ok
  end

  @doc "Mark an archived artifact as released from Tightbeam custody."
  @spec release(DB.server(), String.t()) :: map() | nil
  def release(db \\ Tightbeam.DB, artifact_id) do
    {:ok, _} =
      DB.query(
        db,
        """
        UPDATE artifacts
        SET state = 'released', home = NULL, updatedAt = ?2
        WHERE artifactId = ?1 AND state = 'archived'
        """,
        [artifact_id, now()]
      )

    get(db, artifact_id)
  end

  defp remove_workspace(nil), do: :ok

  defp remove_workspace(workspace_path) do
    if File.exists?(workspace_path), do: File.rm_rf!(workspace_path)
    :ok
  end

  defp archive_workspace!(workspace_path, archive_root, session_key) do
    ensure_workspace_available!(workspace_path)

    archive_dir =
      Path.join(
        archive_root,
        "#{sanitize(session_key)}-#{System.system_time(:millisecond)}"
      )

    File.mkdir_p!(archive_root)

    case File.rename(workspace_path, archive_dir) do
      :ok ->
        archive_dir

      {:error, _reason} ->
        case File.cp_r(workspace_path, archive_dir) do
          {:ok, _paths} ->
            File.rm_rf!(workspace_path)
            archive_dir

          {:error, reason, file} ->
            _ = File.rm_rf(archive_dir)

            raise File.CopyError,
              reason: reason,
              action: "copy",
              source: file,
              destination: archive_dir
        end
    end
  end

  defp ensure_workspace_available!(workspace_path) do
    unless is_binary(workspace_path) and File.dir?(workspace_path) do
      raise ArgumentError, "workspace is unavailable for artifact archival"
    end
  end

  defp archived_relative_path!(origin_path, nil) do
    _ = origin_path
    raise ArgumentError, "workspace is unavailable for artifact archival"
  end

  defp archived_relative_path!(origin_path, workspace_path) do
    expanded_workspace = Path.expand(workspace_path)

    absolute_origin =
      if Path.type(origin_path) == :absolute,
        do: Path.expand(origin_path),
        else: Path.expand(origin_path, expanded_workspace)

    relative = Path.relative_to(absolute_origin, expanded_workspace)

    if Path.type(relative) == :absolute or relative == ".." or
         String.starts_with?(relative, "../") do
      raise ArgumentError, "artifact origin is outside its session workspace"
    end

    unless File.exists?(absolute_origin) do
      raise ArgumentError, "artifact origin is missing from its session workspace"
    end

    relative
  end

  defp parent_session(db, session_key) do
    case DB.query(db, "SELECT spawnedBy FROM sessions WHERE sessionKey = ?1", [session_key]) do
      {:ok, [[parent]]} -> parent
      {:ok, []} -> nil
    end
  end

  defp sanitize(session_key), do: String.replace(session_key, ~r/[^A-Za-z0-9._-]/, "_")

  defp columns do
    """
    artifactId, kind, title, description, createdBySession, workItemId,
    parentSession, originPath, contentSha256, recordedMessageId, state, home,
    createdAt, updatedAt
    """
  end

  defp artifact([
         artifact_id,
         kind,
         title,
         description,
         created_by_session,
         work_item_id,
         parent_session,
         origin_path,
         content_sha256,
         recorded_message_id,
         state,
         home,
         created_at,
         updated_at
       ]) do
    %{
      artifact_id: artifact_id,
      kind: kind,
      title: title,
      description: description,
      created_by_session: created_by_session,
      work_item_id: work_item_id,
      parent_session: parent_session,
      origin_path: origin_path,
      content_sha256: content_sha256,
      recorded_message_id: recorded_message_id,
      state: state,
      home: home,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp now, do: System.system_time(:millisecond)
end
