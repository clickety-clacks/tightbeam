defmodule Tightbeam.Artifacts do
  @moduledoc """
  Artifact pointers and provenance.

  ## The turn edge and its evidence class

  `recordedMessageId` is NULLABLE and paired with `recordedTurnEvidence`, whose
  domain is closed at three values (artifact-carrier-proposal-v1 §2,
  conformance-handoff-ledger clauses 8 and 11 as amended):

  - `tool-call-observed` — the substrate-reserved `PreToolUse` hook saw this
    session about to run a `tightbeam artifact-record` command, and
    `Tightbeam.TurnObservations` captured the turn's `messages.id` at that
    moment. An OBSERVATION-QUALITY claim only: see `record/2`.
  - `session-concurrent` — no hook observation, but a turn was running on the
    caller's session when the request arrived. This is §C1's concurrency claim,
    labelled as such.
  - `none` — neither. `recordedMessageId` is NULL.

  NO CONSUMER MAY TREAT `session-concurrent` OR `none` AS EXACT TURN PROOF. A
  reader that needs the strongest available edge filters on
  `recordedTurnEvidence = 'tool-call-observed'` and reads even that as an
  observation. The only gate over artifacts, `assignment.artifact_kinds`, goes
  through `recorded_kinds/3`, which reads neither column.
  """

  alias Tightbeam.{DB, TurnObservations}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher

  @outside_workspace "artifact origin is outside its session workspace"
  @maximum_version 9_223_372_036_854_775_807
  @floor_definition """
  artifactId TEXT NOT NULL PRIMARY KEY,
  rowVersion INTEGER NOT NULL
    CHECK (typeof(rowVersion) = 'integer' AND rowVersion > 0)
  """

  @table_definition """
    artifactId        TEXT PRIMARY KEY,
    kind              TEXT NOT NULL CHECK (kind IN ('spec','report','doc','data','other')),
    title             TEXT NOT NULL,
    description       TEXT,
    createdBySession  TEXT NOT NULL REFERENCES sessions(sessionKey),
    workItemId        TEXT NOT NULL REFERENCES work_items(id),
    producedByAssignmentId TEXT NULL REFERENCES assignments(id),
    parentSession     TEXT REFERENCES sessions(sessionKey),
    originPath        TEXT NOT NULL,
    contentSha256     TEXT,
    recordedMessageId TEXT REFERENCES messages(id),
    recordedTurnEvidence TEXT NOT NULL DEFAULT 'none'
                      CHECK (recordedTurnEvidence IN
                             ('tool-call-observed','session-concurrent','none')),
    state             TEXT NOT NULL DEFAULT 'in-workspace'
                      CHECK (state IN ('in-workspace','archived','released')),
    home              TEXT,
    createdAt         INTEGER NOT NULL,
    updatedAt         INTEGER NOT NULL,
    CHECK ((state = 'archived') = (home IS NOT NULL))
  """

  @index_ddl [
    "CREATE INDEX IF NOT EXISTS artifacts_work_item ON artifacts (workItemId)",
    "CREATE INDEX IF NOT EXISTS artifacts_producer ON artifacts (producedByAssignmentId)",
    "CREATE INDEX IF NOT EXISTS artifacts_created_by_session ON artifacts (createdBySession)",
    "CREATE INDEX IF NOT EXISTS artifacts_recorded_message ON artifacts (recordedMessageId)"
  ]

  @ddl """
  CREATE TABLE IF NOT EXISTS artifacts (
  #{@table_definition}
  );
  #{Enum.join(@index_ddl, ";\n")};
  """

  @doc false
  def ensure_r1_schema(db), do: DB.execute(db, @ddl)

  @doc "Create the artifact registry schema."
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    :ok = DB.execute(db, @ddl)
    DB.execute(db, "CREATE TABLE IF NOT EXISTS artifact_version_floors (#{@floor_definition})")
  end

  @doc false
  def migrate_version_floors_in_txn(%Txn{} = txn) do
    # The stamped predecessor owns eligibility; this is not a history detector.
    invalid =
      Txn.q(txn, """
      SELECT artifactId FROM artifacts
      WHERE typeof(createdAt) <> 'integer' OR createdAt <= 0
         OR createdAt >= #{@maximum_version}
      """)

    if invalid != [], do: raise(ArgumentError, "artifact_version_seed_invalid")

    Txn.q(txn, "CREATE TABLE artifact_version_floors (#{@floor_definition})")

    Txn.q(txn, """
    INSERT INTO artifact_version_floors (artifactId, rowVersion)
    SELECT artifactId, createdAt + 1 FROM artifacts
    """)

    :ok
  end

  @doc false
  def reserve_version_in_txn(%Txn{} = txn, artifact_id) do
    case Txn.q(txn, "SELECT rowVersion FROM artifact_version_floors WHERE artifactId=?1", [
           artifact_id
         ]) do
      [] ->
        if get_in_txn(txn, artifact_id) != nil,
          do: raise(ArgumentError, "artifact_projection_invalid: missing floor")

        Txn.q(txn, "INSERT INTO artifact_version_floors (artifactId,rowVersion) VALUES (?1,1)", [
          artifact_id
        ])

        1

      [[version]] when is_integer(version) and version > 0 and version < @maximum_version ->
        Txn.q(
          txn,
          """
          UPDATE artifact_version_floors SET rowVersion=rowVersion+1
          WHERE artifactId=?1 AND rowVersion=?2 AND rowVersion<#{@maximum_version}
          """,
          [artifact_id, version]
        )

        if Txn.changes(txn) != 1, do: raise(ArgumentError, "artifact_version_compare_failed")
        version + 1

      _ ->
        raise ArgumentError, "artifact_version_invalid_or_exhausted"
    end
  end

  @doc false
  def canonical_in_txn(%Txn{} = txn, artifact_id) do
    selected = columns() |> String.split(",") |> Enum.map_join(",", &("a." <> String.trim(&1)))

    case Txn.q(
           txn,
           """
           SELECT #{selected}, f.rowVersion FROM artifacts a
           LEFT JOIN artifact_version_floors f ON f.artifactId=a.artifactId
           WHERE a.artifactId=?1
           """,
           [artifact_id]
         ) do
      [] ->
        nil

      [row] ->
        {fields, [version]} = Enum.split(row, -1)
        Map.put(artifact(fields), :row_version, version)
    end
  end

  @doc """
  Record a deliberate artifact pointer for the authenticated calling session.

  FAILS OPEN on the turn edge. Whatever the substrate can establish about the
  firing turn, the row lands — it is never refused for want of provenance. The
  refusal it replaces was not cosmetic: `completion-requires-results-artifact`
  denies a coder's completion until a report artifact exists and wakes them to
  record one, so a verb that refuses held a correct agent in a loop it could not
  exit and no operator could see. Recording the weaker edge under a label that
  names it is strictly more truth than recording nothing.
  """
  @spec record(DB.server(), map()) :: map()
  def record(db \\ Tightbeam.DB, call) do
    case {call[:principal], call[:session_key], call[:params][:work_item_id]} do
      {{:session, session_key}, session_key, work_item_id}
      when is_binary(session_key) and is_binary(work_item_id) ->
        artifact_id = "art_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
        parent_session = parent_session(db, session_key)
        {recorded_message_id, evidence} = turn_evidence(db, session_key)
        now = now()
        producer_id = call.params[:produced_by_assignment_id]

        case DB.transaction_then(
               db,
               fn txn ->
                 case validate_producer_in_txn(txn, producer_id, session_key, work_item_id) do
                   :ok ->
                     reserve_version_in_txn(txn, artifact_id)

                     Txn.q(
                       txn,
                       """
                       INSERT INTO artifacts
                         (artifactId, kind, title, description, createdBySession, workItemId,
                          producedByAssignmentId, parentSession, originPath, contentSha256,
                          recordedMessageId, recordedTurnEvidence, state, home, createdAt, updatedAt)
                       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                               'in-workspace', NULL, ?13, ?13)
                       """,
                       [
                         artifact_id,
                         call.params.kind,
                         call.params.title,
                         call.params[:description],
                         session_key,
                         work_item_id,
                         producer_id,
                         parent_session,
                         call.params.origin_path,
                         call.params[:content_sha256],
                         recorded_message_id,
                         evidence,
                         now
                       ]
                     )

                     Publisher.maybe_observed_accepted_in_txn(txn, call)
                     publish_in_txn(txn, "artifact.recorded", artifact_id, call)
                     {:created, artifact_in_txn(txn, artifact_id)}

                   error ->
                     error
                 end
               end,
               fn txn, result ->
                 case result do
                   {:created, artifact} ->
                     [[owner]] =
                       Txn.q(txn, "SELECT ownerUserId FROM work_items WHERE id=?1", [work_item_id])

                     Tightbeam.Wakes.row_commit_in_txn(txn, %{
                       verb: "artifact-record",
                       domain: "artifact",
                       row_id: artifact_id,
                       owner_user_id: owner,
                       principal: "session:#{session_key}",
                       bindings: %{
                         artifact: %{
                           artifactId: artifact_id,
                           contentSha256: artifact.content_sha256
                         }
                       },
                       fields: %{present: %{old: false, new: true}}
                     })

                     artifact

                   error ->
                     error
                 end
               end
             ) do
          {:ok, result} -> result
          {:error, error} -> raise error
        end

      {{:session, session_key}, session_key, _work_item_id} when is_binary(session_key) ->
        %{code: "invalid", message: "artifact-record requires provenance edges"}

      _ ->
        %{code: "invalid", message: "artifact-record requires a session caller"}
    end
  end

  defp validate_producer_in_txn(_txn, nil, _session_key, _work_item_id), do: :ok

  defp validate_producer_in_txn(txn, producer_id, session_key, work_item_id)
       when is_binary(producer_id) and producer_id != "" do
    case Txn.q(
           txn,
           """
           SELECT 1
           FROM assignments a
           JOIN sessions s ON s.sessionKey=a.holderKey
           JOIN work_items wi ON wi.id=a.workItemId
           WHERE a.id=?1 AND a.holderKey=?2 AND a.workItemId=?3
             AND s.ownerUserId=wi.ownerUserId
           """,
           [producer_id, session_key, work_item_id]
         ) do
      [[1]] ->
        :ok

      [] ->
        %{
          code: "invalid_producer",
          message: "artifact producer must be a held assignment on the artifact work item"
        }
    end
  end

  defp validate_producer_in_txn(_txn, _producer_id, _session_key, _work_item_id),
    do: %{code: "invalid_producer", message: "producedByAssignmentId must be nonblank text"}

  defp publish_in_txn(txn, class, artifact_id, call \\ %{}) do
    snapshot = canonical_in_txn(txn, artifact_id)
    Publisher.artifact_in_txn(txn, class, snapshot, call)
  end

  # The best edge the substrate OBSERVED, with the observation method named.
  #
  # `tool-call-observed` is a claim about OBSERVATION QUALITY and nothing more:
  # the reserved PreToolUse hook saw this session about to run an
  # `artifact-record` command and captured the running turn's `messages.id` at
  # that moment. The captured window is joined to this request by SESSION AND
  # TIME — not by a nonce, not by matching command text — so it is neither
  # unforgeable nor a statement of exact causality. Read it as "the substrate
  # observed this turn invoking this verb". Nonce injection is the only join that
  # would be genuine proof, and it cannot exist on Codex, whose PreToolUse
  # protocol is allow/deny with no input mutation (harness-support CAP-008).
  #
  # `session-concurrent` is weaker still and says so: §C1's concurrency claim,
  # true in the normal case and wrong in both directions at the edges (a separate
  # request on the same session token binds a turn that did not fire it; a
  # request arriving after a cancel binds none).
  #
  # The caller never supplies either value. `recorded_message_id` and
  # `recorded_turn_evidence` are stripped from params at the wire boundary
  # (`Tightbeam.Wire.Router`), which is the whole reason a caller-selected id
  # could not have been proof in the first place.
  #
  # It is ONE operation and not two reads in two processes, which is what the
  # first version got wrong: the window came back from the writer, this process
  # then queried the ledger, and a turn terminalizing in the scheduling gap
  # between them made the row describe an instant neither read had seen.
  defp turn_evidence(db, session_key), do: TurnObservations.evidence(db, session_key)

  @doc "Fetch one artifact row, or nil."
  @spec get(DB.server(), String.t()) :: map() | nil
  def get(db \\ Tightbeam.DB, artifact_id) do
    case DB.query(db, "SELECT #{columns()} FROM artifacts WHERE artifactId = ?1", [artifact_id]) do
      {:ok, [row]} -> artifact(row)
      {:ok, []} -> nil
    end
  end

  defp artifact_in_txn(txn, artifact_id) do
    case Txn.q(txn, "SELECT #{columns()} FROM artifacts WHERE artifactId=?1", [artifact_id]) do
      [row] -> artifact(row)
    end
  end

  @doc false
  @spec get_in_txn(Txn.t(), String.t() | nil) :: map() | nil
  def get_in_txn(%Txn{} = txn, artifact_id) do
    case Txn.q(txn, "SELECT #{columns()} FROM artifacts WHERE artifactId = ?1", [artifact_id]) do
      [row] -> artifact(row)
      [] -> nil
    end
  end

  @doc """
  Distinct artifact kinds a session recorded on a work item.

  State-blind by design: in-workspace, archived, and released rows all count —
  a record counts in every state.
  """
  @spec recorded_kinds(DB.server(), String.t(), String.t()) :: [String.t()]
  def recorded_kinds(db \\ Tightbeam.DB, work_item_id, created_by_session) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT DISTINCT kind FROM artifacts WHERE workItemId = ?1 AND createdBySession = ?2 ORDER BY kind",
        [work_item_id, created_by_session]
      )

    Enum.map(rows, &hd/1)
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
    # Filesystem custody has no fixed upper duration. Wait for the actual
    # serialized transaction result; unrelated DB calls retain their budgets.
    case GenServer.call(
           db,
           {:transaction, &archive_session_in_txn(&1, session_key, workspace_path, archive_root)},
           :infinity
         ) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  defp archive_session_in_txn(txn, session_key, workspace_path, archive_root) do
    # Serialize the eligibility read and filesystem custody operation together.
    # A contender must see the winner's committed state before inspecting a moved workspace.
    rows =
      Txn.q(
        txn,
        "SELECT #{columns()} FROM artifacts WHERE createdBySession=?1 ORDER BY createdAt DESC, artifactId DESC",
        [session_key]
      )
      |> Enum.map(&artifact/1)

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

      transitions =
        Enum.map(relative_paths, fn {id, relative} ->
          {id, "archived", Path.join(archived_path, relative)}
        end) ++ Enum.map(external, &{&1, "released", nil})

      transitions
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.each(fn {id, state, home} ->
        transition_in_txn(txn, id, "in-workspace", state, home, updated_at)
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
    case DB.transaction(db, fn txn ->
           transition_in_txn(txn, artifact_id, "archived", "released", nil, now())
           get_in_txn(txn, artifact_id)
         end) do
      {:ok, row} -> row
      {:error, error} -> raise error
    end
  end

  defp transition_in_txn(txn, id, prior, state, home, updated_at) do
    case get_in_txn(txn, id) do
      %{state: ^prior} ->
        reserve_version_in_txn(txn, id)

        Txn.q(
          txn,
          """
          UPDATE artifacts SET state=?2, home=?3, updatedAt=?4
          WHERE artifactId=?1 AND state=?5
          """,
          [id, state, home, updated_at, prior]
        )

        if Txn.changes(txn) != 1, do: raise(ArgumentError, "artifact_transition_race")
        publish_in_txn(txn, "artifact." <> state, id)

      _ ->
        :ok
    end
  end

  defp remove_workspace(nil), do: :ok

  defp remove_workspace(workspace_path) do
    custody_test_boundary()
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
    case DB.query(db, "SELECT #{Tightbeam.Org.current_parent_sql("sessions")} FROM sessions WHERE sessionKey = ?1", [session_key]) do
      {:ok, [[parent]]} -> parent
      {:ok, []} -> nil
    end
  end

  defp sanitize(session_key), do: String.replace(session_key, ~r/[^A-Za-z0-9._-]/, "_")

  defp columns do
    """
    artifactId, kind, title, description, createdBySession, workItemId,
    producedByAssignmentId, parentSession, originPath, contentSha256, recordedMessageId,
    recordedTurnEvidence, state, home, createdAt, updatedAt
    """
  end

  defp artifact([
         artifact_id,
         kind,
         title,
         description,
         created_by_session,
         work_item_id,
         produced_by_assignment_id,
         parent_session,
         origin_path,
         content_sha256,
         recorded_message_id,
         recorded_turn_evidence,
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
      produced_by_assignment_id: produced_by_assignment_id,
      parent_session: parent_session,
      origin_path: origin_path,
      content_sha256: content_sha256,
      recorded_message_id: recorded_message_id,
      recorded_turn_evidence: recorded_turn_evidence,
      state: state,
      home: home,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  if Mix.env() == :test do
    defp custody_test_boundary do
      case Process.get({__MODULE__, :test_custody_boundary}) do
        nil -> :ok
        callback when is_function(callback, 0) -> callback.()
      end
    end

    defp now do
      case Process.get({__MODULE__, :test_clock}) do
        value when is_integer(value) -> value
        nil -> System.system_time(:millisecond)
      end
    end
  else
    defp custody_test_boundary, do: :ok
    defp now, do: System.system_time(:millisecond)
  end
end
