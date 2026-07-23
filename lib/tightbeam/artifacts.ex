defmodule Tightbeam.Artifacts do
  @moduledoc "Artifact pointers and provenance."

  alias Tightbeam.DB

  @ddl """
  CREATE TABLE IF NOT EXISTS artifacts (
    artifactId        TEXT PRIMARY KEY,
    kind              TEXT NOT NULL CHECK (kind IN ('spec','report','doc','data','other')),
    title             TEXT NOT NULL,
    description       TEXT,
    createdBySession  TEXT NOT NULL,
    workItemId        TEXT,
    parentSession     TEXT,
    originPath        TEXT NOT NULL,
    contentSha256     TEXT,
    recordedMessageId INTEGER,
    state             TEXT NOT NULL DEFAULT 'in-workspace'
                      CHECK (state IN ('in-workspace','archived','released')),
    home              TEXT,
    createdAt         INTEGER NOT NULL,
    updatedAt         INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS artifacts_work_item ON artifacts (workItemId);
  CREATE INDEX IF NOT EXISTS artifacts_created_by_session ON artifacts (createdBySession);
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
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, NULL,
                    'in-workspace', NULL, ?10, ?10)
            """,
            [
              artifact_id,
              call.params.kind,
              call.params.title,
              call.params[:description],
              session_key,
              call.params[:work_item_id],
              parent_session,
              call.params.origin_path,
              call.params[:content_sha256],
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
        {"workItemId", filters[:work_item_id]},
        {"createdBySession", filters[:session_key]},
        {"kind", filters[:kind]}
      ]
      |> Enum.reject(fn {_column, value} -> is_nil(value) end)
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {{column, value}, index}, values ->
        {"#{column} = ?#{index}", values ++ [value]}
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

    if live != [] do
      archived_path = archive_workspace(workspace_path, archive_root, session_key)
      updated_at = now()

      Enum.each(live, fn row ->
        home =
          if archived_path do
            archived_home(row.origin_path, workspace_path, archived_path)
          else
            row.origin_path
          end

        {:ok, _} =
          DB.query(
            db,
            """
            UPDATE artifacts
            SET state = 'archived', home = ?2, updatedAt = ?3
            WHERE artifactId = ?1 AND state = 'in-workspace'
            """,
            [row.artifact_id, home, updated_at]
          )
      end)
    end

    :ok
  end

  defp archive_workspace(nil, _archive_root, _session_key), do: nil

  defp archive_workspace(workspace_path, archive_root, session_key) do
    if File.dir?(workspace_path) do
      archive_dir =
        Path.join(
          archive_root,
          "#{sanitize(session_key)}-#{System.system_time(:second)}"
        )

      File.mkdir_p!(archive_root)

      case File.rename(workspace_path, archive_dir) do
        :ok ->
          archive_dir

        {:error, _reason} ->
          case File.cp_r(workspace_path, archive_dir) do
            {:ok, _paths} ->
              _ = File.rm_rf(workspace_path)
              archive_dir

            {:error, _reason, _file} ->
              nil
          end
      end
    end
  rescue
    _ -> nil
  end

  defp archived_home(origin_path, workspace_path, archive_dir) do
    absolute_origin =
      if Path.type(origin_path) == :absolute,
        do: Path.expand(origin_path),
        else: Path.expand(origin_path, workspace_path)

    relative = Path.relative_to(absolute_origin, Path.expand(workspace_path))

    if Path.type(relative) == :absolute or relative == ".." or
         String.starts_with?(relative, "../"),
       do: archive_dir,
       else: Path.join(archive_dir, relative)
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
