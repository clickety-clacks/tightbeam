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

  alias Tightbeam.{ArtifactContent, DB, TurnObservations}

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
    with {:ok, prepared} <- prepare_content(call) do
      record_with_content(db, call, prepared)
    else
      {:error, error} -> error
    end
  end

  defp record_with_content(db, call, prepared) do
    case {call[:principal], call[:session_key], call[:params][:work_item_id]} do
      {{:session, session_key}, session_key, work_item_id}
      when is_binary(session_key) and is_binary(work_item_id) ->
        artifact_id = "art_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
        parent_session = parent_session(db, session_key)
        {recorded_message_id, evidence} = turn_evidence(db, session_key)
        now = now()

        content_sha256 = if prepared, do: prepared.sha256, else: call.params[:content_sha256]

        {:ok, :ok} =
          DB.transaction(db, fn txn ->
            DB.Txn.q(
              txn,
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
                content_sha256,
                recorded_message_id,
                evidence,
                now
              ]
            )

            if prepared do
              :ok = ArtifactContent.store_in_txn(txn, artifact_id, prepared, now)

              DB.Txn.q(
                txn,
                """
                UPDATE artifacts
                SET state = 'released', updatedAt = ?2
                WHERE artifactId = ?1 AND state = 'in-workspace'
                """,
                [artifact_id, now]
              )
            end

            :ok
          end)

        get(db, artifact_id)

      {{:session, session_key}, session_key, _work_item_id} when is_binary(session_key) ->
        %{code: "invalid", message: "artifact-record requires provenance edges"}

      _ ->
        %{code: "invalid", message: "artifact-record requires a session caller"}
    end
  end

  defp prepare_content(%{artifact_content: content, params: params}) when is_binary(content),
    do: ArtifactContent.prepare(content, params[:content_sha256])

  defp prepare_content(_call), do: {:ok, nil}

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

  @doc "Remove a retired session workspace after durable content was verified."
  @spec archive_session(DB.server(), String.t(), String.t() | nil, String.t()) :: :ok
  def archive_session(db \\ Tightbeam.DB, session_key, workspace_path, _archive_root) do
    case DB.transaction(db, fn txn ->
           ArtifactContent.ensure_retirement_ready_in_txn!(txn, [session_key])
         end) do
      {:ok, :ok} -> remove_workspace(workspace_path)
      {:error, error} -> raise error
    end
  end

  defp remove_workspace(workspace_path) do
    if File.exists?(workspace_path), do: File.rm_rf!(workspace_path)
    :ok
  end

  defp parent_session(db, session_key) do
    case DB.query(db, "SELECT spawnedBy FROM sessions WHERE sessionKey = ?1", [session_key]) do
      {:ok, [[parent]]} -> parent
      {:ok, []} -> nil
    end
  end

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
