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
    "CREATE INDEX IF NOT EXISTS artifacts_created_by_session ON artifacts (createdBySession)",
    "CREATE INDEX IF NOT EXISTS artifacts_recorded_message ON artifacts (recordedMessageId)"
  ]

  @ddl """
  CREATE TABLE IF NOT EXISTS artifacts (
  #{@table_definition}
  );
  #{Enum.join(@index_ddl, ";\n")};
  """

  @doc "Create the artifact registry schema."
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

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

        {:ok, _} =
          DB.query(
            db,
            """
            INSERT INTO artifacts
              (artifactId, kind, title, description, createdBySession, workItemId,
               parentSession, originPath, contentSha256, recordedMessageId,
               recordedTurnEvidence, state, home, createdAt, updatedAt)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
                    'in-workspace', NULL, ?12, ?12)
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
              evidence,
              now
            ]
          )

        get(db, artifact_id)

      {{:session, session_key}, session_key, _work_item_id} when is_binary(session_key) ->
        %{code: "invalid", message: "artifact-record requires provenance edges"}

      _ ->
        %{code: "invalid", message: "artifact-record requires a session caller"}
    end
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
  Take a retired session's workspace into custody, then archive its rows.

  THE WORKSPACE IS ALWAYS PRESERVED. Artifact rows say what a row is; they have
  never said whether the bytes may be deleted. Work exists before anyone files a
  row for it, so "this session recorded no artifact" is a statement about
  paperwork, not about an empty workspace. Reading it as a deletion oracle is
  what let an ordinary revoke-and-retire remove a session workspace that held
  uncommitted work, and report success (wi_38df6905, specimen 2026-08-07).

  Nothing here consults Git. A workspace goes into the archive whole — tracked,
  staged, untracked, ignored, nested repositories, and files no repository ever
  knew about — because every narrower rule is a rule about what someone
  remembered to commit, and the bytes worth keeping are usually the ones nobody
  did.

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

    {relative_paths, external, errors} = archive_candidates(live, workspace_path)

    # An origin that is inside the workspace and unreadable is not external —
    # nothing was released, the bytes are simply gone. That still refuses to
    # invent custody.
    if map_size(relative_paths) == 0 and errors != [] do
      raise hd(errors)
    end

    archived_path = preserve_workspace!(workspace_path, archive_root, session_key)

    # A row claimed custody, so the workspace was there when we classified it.
    # If it is not there now, say that instead of recording a home under an
    # archive directory nothing ever wrote.
    if map_size(relative_paths) > 0 and is_nil(archived_path) do
      raise ArgumentError, "workspace is unavailable for artifact archival"
    end

    if relative_paths != %{} or external != [] do
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

  # Nothing on this machine to preserve: a remote holder's workspace, which this
  # host can neither read nor remove, or a session whose workspace was never
  # created here. Either way there are no bytes to lose and nothing to delete.
  defp preserve_workspace!(nil, _archive_root, _session_key), do: nil

  defp preserve_workspace!(workspace_path, archive_root, session_key) do
    case File.lstat(workspace_path) do
      {:ok, %File.Stat{type: :directory}} ->
        archive_workspace!(workspace_path, archive_root, session_key)

      _absent ->
        nil
    end
  end

  # The recovery location is STABLE: one session always archives to one
  # directory, so an operator finds a retired workspace by session key and a
  # retry lands on its own earlier attempt instead of scattering copies. The
  # digest keeps that name faithful — `sanitize/1` maps ':' and ' ' to the same
  # character, so two different session keys can otherwise produce one directory
  # name, and merging two workspaces into one archive is its own kind of loss.
  defp archive_workspace!(workspace_path, archive_root, session_key) do
    archive_dir = Path.join(archive_root, archive_name(session_key))
    inventory = inventory!(workspace_path)

    File.mkdir_p!(archive_root)

    # A rename into a free location is the whole preservation in one atomic
    # step: there is no instant when the bytes are in neither place. Every other
    # case — a workspace on another filesystem, a retry landing on what an
    # earlier attempt left — copies, PROVES the copy, and only then removes the
    # source.
    moved? =
      match?({:error, :enoent}, File.lstat(archive_dir)) and
        File.rename(workspace_path, archive_dir) == :ok

    unless moved?, do: copy_into!(workspace_path, archive_dir)

    verify_archived!(inventory, archive_dir, workspace_path, moved?)

    unless moved?, do: File.rm_rf!(workspace_path)

    archive_dir
  end

  defp archive_name(session_key) do
    digest =
      :crypto.hash(:sha256, session_key)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "#{sanitize(session_key)}-#{digest}"
  end

  # `File.cp_r/2` merges into a destination that already exists, which is what a
  # retry landing on an earlier attempt's archive needs, and it preserves a
  # symlink as the symlink it was.
  #
  # A failed copy leaves the archive standing, unlike the version this replaced:
  # what is already in there may be the only copy of something, and the source is
  # still in place to try again from.
  defp copy_into!(workspace_path, archive_dir) do
    case File.cp_r(workspace_path, archive_dir) do
      {:ok, _paths} ->
        :ok

      {:error, reason, file} ->
        raise File.CopyError,
          reason: reason,
          action: "copy",
          source: file,
          destination: archive_dir
    end
  end

  # What we set out to preserve, read BEFORE anything moves: every path under the
  # workspace with the type and size that must still be there afterwards.
  defp inventory!(workspace_path), do: entries!(workspace_path, [], %{})

  defp entries!(path, segments, acc) do
    stat = File.lstat!(path)

    acc =
      case segments do
        [] -> acc
        _named -> Map.put(acc, Path.join(Enum.reverse(segments)), signature(stat))
      end

    case stat.type do
      :directory ->
        Enum.reduce(File.ls!(path), acc, fn entry, inner ->
          entries!(Path.join(path, entry), [entry | segments], inner)
        end)

      _leaf ->
        acc
    end
  end

  # A directory's own size says nothing about what is in it; its children carry
  # that, and each of them is inventoried in its own right.
  defp signature(%File.Stat{type: :directory}), do: :directory
  defp signature(%File.Stat{type: type, size: size}), do: {type, size}

  # A copy that reported success is not a copy that happened. The source is
  # removed only after the archive answers for every path the workspace had, and
  # a refusal names where the bytes are so the operator does not have to guess.
  defp verify_archived!(inventory, archive_dir, workspace_path, moved?) do
    unproven =
      Enum.reject(inventory, fn {relative, signature} ->
        archived?(File.lstat(Path.join(archive_dir, relative)), signature)
      end)

    if unproven != [] do
      {first, _signature} = Enum.min(unproven)

      raise "workspace archive is incomplete: #{length(unproven)} of #{map_size(inventory)} " <>
              "entries are missing or altered under #{archive_dir} (first: #{first}). " <>
              recovery(workspace_path, moved?)
    end

    :ok
  end

  defp archived?({:ok, %File.Stat{type: :directory}}, :directory), do: true
  defp archived?({:ok, %File.Stat{type: type, size: size}}, {type, size}), do: true
  defp archived?(_stat, _signature), do: false

  defp recovery(workspace_path, false),
    do: "The workspace was NOT removed and is still at #{workspace_path}."

  defp recovery(workspace_path, true),
    do:
      "The workspace was moved out of #{workspace_path} in one step, so its bytes are " <>
        "in that archive directory and nothing was deleted."

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
    parentSession, originPath, contentSha256, recordedMessageId,
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

  defp now, do: System.system_time(:millisecond)
end
