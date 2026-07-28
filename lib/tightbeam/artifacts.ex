defmodule Tightbeam.Artifacts do
  @moduledoc "Artifact pointers and provenance."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @outside_workspace "artifact origin is outside its session workspace"

  @table_definition """
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
  """

  @index_ddl [
    "CREATE INDEX IF NOT EXISTS artifacts_work_item ON artifacts (workItemId)",
    "CREATE INDEX IF NOT EXISTS artifacts_created_by_session ON artifacts (createdBySession)",
    "CREATE INDEX IF NOT EXISTS artifacts_recorded_message ON artifacts (recordedMessageId)"
  ]

  @ddl """
  CREATE TABLE IF NOT EXISTS artifacts (
  #{@table_definition}
  );
  #{Enum.join(@index_ddl, ";\n")};
  """

  @rebuild_ddl """
  CREATE TABLE artifacts_new (
  #{@table_definition}
  )
  """

  @doc "Create the artifact registry schema."
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    with :ok <- DB.execute(db, @ddl),
         :ok <- ensure_table_shape(db) do
      :ok
    end
  end

  @doc "Record a deliberate artifact pointer for the authenticated calling session."
  @spec record(DB.server(), map()) :: map()
  def record(db \\ Tightbeam.DB, call) do
    case {
      call[:principal],
      call[:session_key],
      call[:recorded_message_id],
      call[:params][:work_item_id]
    } do
      {{:session, session_key}, session_key, recorded_message_id, work_item_id}
      when is_binary(session_key) and is_binary(recorded_message_id) and is_binary(work_item_id) ->
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
              work_item_id,
              parent_session,
              call.params.origin_path,
              call.params[:content_sha256],
              recorded_message_id,
              now
            ]
          )

        get(db, artifact_id)

      {{:session, session_key}, session_key, _recorded_message_id, _work_item_id}
      when is_binary(session_key) ->
        %{code: "invalid", message: "artifact-record requires provenance edges"}

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

  @doc """
  Archive in-workspace rows after a session workspace has been reaped.

  An origin that does not resolve inside the session workspace is an EXTERNAL
  artifact — work that legitimately happened somewhere else (another machine, a
  service) and was declared by recording it. There is nothing to take into
  custody, so the row is RELEASED rather than archived: the row is the record.

  Classification comes FIRST, before the workspace is touched at all. An origin
  that names a machine (`host:/absolute/path`, the form the operating manual
  teaches for remote work) is external by inspection — resolving it against a
  workspace would turn the machine name into a missing directory, and a session
  whose only artifact is remote could then never be archived. It also means a
  session whose workspace is not reachable from here — every remote holder — can
  still release what it declared: the workspace is required only when some row
  actually needs custody.
  """
  @spec archive_session(DB.server(), String.t(), String.t() | nil, String.t()) :: :ok
  def archive_session(db \\ Tightbeam.DB, session_key, workspace_path, archive_root) do
    rows = list(db, %{session_key: session_key})
    live = Enum.filter(rows, &(&1.state == "in-workspace"))

    if live == [] do
      remove_workspace(workspace_path)
    else
      {relative_paths, external, errors} = archive_candidates(live, workspace_path)

      # An origin that is inside the workspace and unreadable is not external —
      # nothing was released, the bytes are simply gone. That still refuses to
      # invent custody.
      if map_size(relative_paths) == 0 and errors != [] do
        raise hd(errors)
      end

      archived_path =
        if map_size(relative_paths) == 0 do
          remove_workspace(workspace_path)
          nil
        else
          ensure_workspace_available!(workspace_path)
          archive_workspace!(workspace_path, archive_root, session_key)
        end

      updated_at = now()

      {:ok, :ok} =
        DB.transaction(db, fn txn ->
          Enum.each(relative_paths, fn {artifact_id, relative_path} ->
            DB.Txn.q(
              txn,
              """
              UPDATE artifacts
              SET state = 'archived', home = ?2, updatedAt = ?3
              WHERE artifactId = ?1 AND state = 'in-workspace'
              """,
              [
                artifact_id,
                Path.join(archived_path, relative_path),
                updated_at
              ]
            )
          end)

          Enum.each(external, fn artifact_id ->
            DB.Txn.q(
              txn,
              """
              UPDATE artifacts
              SET state = 'released', home = NULL, updatedAt = ?2
              WHERE artifactId = ?1 AND state = 'in-workspace'
              """,
              [artifact_id, updated_at]
            )
          end)

          :ok
        end)
    end

    :ok
  end

  defp archive_candidates(live, workspace_path) do
    Enum.reduce(live, {%{}, [], []}, fn row, acc ->
      if names_a_machine?(row.origin_path),
        do: external(acc, row),
        else: resolved_candidate(row, workspace_path, acc)
    end)
  end

  # `host:/absolute/path` — the origin names a machine, so it is external by
  # inspection. Which machines exist is Placement's knowledge, and this module
  # does not need it: whatever that host is, the bytes are not in this workspace.
  defp names_a_machine?(origin_path) when is_binary(origin_path),
    do: Regex.match?(~r{^[^/:]+:/}, origin_path)

  defp names_a_machine?(_origin_path), do: false

  defp external({paths, external, errors}, row),
    do: {paths, external ++ [row.artifact_id], errors}

  defp resolved_candidate(row, workspace_path, {paths, external, errors} = acc) do
    # Only a row that might need custody needs the workspace, and a workspace
    # that is not there says THAT rather than blaming the origin for it.
    ensure_workspace_available!(workspace_path)
    relative_path = archived_relative_path!(row.origin_path, workspace_path)
    {Map.put(paths, row.artifact_id, relative_path), external, errors}
  rescue
    error in ArgumentError ->
      if error.message == @outside_workspace do
        external(acc, row)
      else
        {paths, external, errors ++ [error]}
      end
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

  defp ensure_table_shape(db) do
    {:ok, columns} = DB.query(db, "PRAGMA table_info(artifacts)")
    {:ok, foreign_keys} = DB.query(db, "PRAGMA foreign_key_list(artifacts)")

    {:ok, [[table_sql]]} =
      DB.query(
        db,
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'artifacts'"
      )

    if target_shape?(columns, foreign_keys, table_sql),
      do: :ok,
      else: rebuild_table(db)
  end

  defp target_shape?(columns, foreign_keys, table_sql) do
    column_shape =
      Map.new(columns, fn row ->
        {Enum.at(row, 1), {Enum.at(row, 2), Enum.at(row, 3)}}
      end)

    expected_foreign_keys =
      MapSet.new([
        {"createdBySession", "sessions", "sessionKey"},
        {"workItemId", "work_items", "id"},
        {"parentSession", "sessions", "sessionKey"},
        {"recordedMessageId", "messages", "id"}
      ])

    actual_foreign_keys =
      MapSet.new(foreign_keys, fn row ->
        {Enum.at(row, 3), Enum.at(row, 2), Enum.at(row, 4)}
      end)

    normalized_sql = String.replace(table_sql, ~r/\s+/, "")

    column_shape["createdBySession"] == {"TEXT", 1} and
      column_shape["workItemId"] == {"TEXT", 1} and
      column_shape["parentSession"] == {"TEXT", 0} and
      column_shape["recordedMessageId"] == {"TEXT", 1} and
      actual_foreign_keys == expected_foreign_keys and
      String.contains?(
        normalized_sql,
        "CHECK((state='archived')=(homeISNOTNULL))"
      )
  end

  defp rebuild_table(db) do
    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")

    try do
      case DB.transaction(db, fn txn ->
             Txn.exec(txn, @rebuild_ddl)

             Txn.q(
               txn,
               """
               INSERT INTO artifacts_new
                 (artifactId, kind, title, description, createdBySession, workItemId,
                  parentSession, originPath, contentSha256, recordedMessageId,
                  state, home, createdAt, updatedAt)
               SELECT
                 artifactId, kind, title, description, createdBySession, workItemId,
                 parentSession, originPath, contentSha256, recordedMessageId,
                 state, home, createdAt, updatedAt
               FROM artifacts
               """
             )

             Txn.exec(txn, "DROP TABLE artifacts")
             Txn.exec(txn, "ALTER TABLE artifacts_new RENAME TO artifacts")
             Enum.each(@index_ddl, &Txn.exec(txn, &1))

             case Txn.q(txn, "PRAGMA foreign_key_check(artifacts)") do
               [] ->
                 :ok

               rows ->
                 raise DB.Error, message: "artifact foreign key check failed: #{inspect(rows)}"
             end
           end) do
        {:ok, :ok} -> :ok
        {:error, error} -> {:error, error}
      end
    after
      :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    end
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
    case is_binary(workspace_path) && File.lstat(workspace_path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      _ ->
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

    canonical_workspace = canonical_path!(expanded_workspace)
    canonical_origin = canonical_path!(absolute_origin)
    relative = Path.relative_to(canonical_origin, canonical_workspace)

    if Path.type(relative) == :absolute or relative == ".." or
         String.starts_with?(relative, "../") do
      raise ArgumentError, @outside_workspace
    end

    relative
  end

  defp canonical_path!(path, symlink_hops \\ 0)

  defp canonical_path!(_path, symlink_hops) when symlink_hops > 40 do
    raise ArgumentError, "artifact origin has too many symbolic links"
  end

  defp canonical_path!(path, symlink_hops) do
    [root | components] = Path.expand(path) |> Path.split()
    canonical_components!(root, components, symlink_hops)
  end

  defp canonical_components!(canonical, [], _symlink_hops), do: canonical

  defp canonical_components!(canonical, [component | rest], symlink_hops) do
    candidate = Path.join(canonical, component)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        target = File.read_link!(candidate)

        target_path =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, Path.dirname(candidate))

        canonical_path!(Enum.reduce(rest, target_path, &Path.join(&2, &1)), symlink_hops + 1)

      {:ok, _stat} ->
        canonical_components!(candidate, rest, symlink_hops)

      {:error, _reason} ->
        raise ArgumentError, "artifact origin is missing from its session workspace"
    end
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
