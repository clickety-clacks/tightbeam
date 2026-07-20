defmodule Tightbeam.Assignments do
  @moduledoc "Assignments and their attests."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  defmodule TransitionRace do
    @moduledoc false
    defexception message: "assignment closed"
  end

  defmodule UnknownWorkItem do
    @moduledoc false
    defexception [:work_item_id]

    @impl true
    def message(%__MODULE__{work_item_id: id}), do: "unknown work item: #{id}"
  end

  @assignments_ddl """
  CREATE TABLE IF NOT EXISTS assignments (
    id TEXT PRIMARY KEY,
    subject TEXT NOT NULL CHECK(length(trim(subject)) BETWEEN 1 AND 2000),
    holderKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    holderRole TEXT NULL,
    holderFallback INTEGER NOT NULL DEFAULT 0 CHECK(holderFallback IN (0, 1)),
    openedByUser TEXT NULL,
    openedBySession TEXT NULL,
    openedAt INTEGER NOT NULL,
    state TEXT NOT NULL DEFAULT 'open' CHECK(state IN ('open', 'closed')),
    outcome TEXT NULL CHECK(outcome IN ('completed', 'surrendered', 'revoked')),
    closedAt INTEGER NULL,
    closedByUser TEXT NULL,
    closedBySession TEXT NULL,
    closingAttestId TEXT NULL REFERENCES attests(id),
    workItemId TEXT NULL REFERENCES work_items(id),
    CHECK(holderRole IS NOT NULL OR holderFallback = 0),
    CHECK((openedByUser IS NOT NULL) != (openedBySession IS NOT NULL)),
    CHECK(
      (state = 'open' AND outcome IS NULL AND closedAt IS NULL AND
       closedByUser IS NULL AND closedBySession IS NULL AND closingAttestId IS NULL)
      OR
      (state = 'closed' AND outcome IS NOT NULL AND closedAt IS NOT NULL AND
       ((closedByUser IS NOT NULL) != (closedBySession IS NOT NULL)))
    ),
    CHECK(outcome NOT IN ('completed', 'surrendered') OR closingAttestId IS NOT NULL),
    CHECK(outcome != 'revoked' OR closingAttestId IS NULL)
  )
  """

  @attests_ddl """
  CREATE TABLE IF NOT EXISTS attests (
    id TEXT PRIMARY KEY,
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    kind TEXT NOT NULL CHECK(kind IN ('progress', 'completion', 'surrender', 'verdict')),
    verdictKind TEXT NULL,
    note TEXT NULL CHECK(note IS NULL OR length(trim(note)) BETWEEN 1 AND 2000),
    bySession TEXT NULL REFERENCES sessions(sessionKey),
    byUser TEXT NULL REFERENCES users(userId),
    ts INTEGER NOT NULL,
    CHECK(
      (kind IN ('progress', 'completion', 'surrender') AND bySession IS NOT NULL AND
       byUser IS NULL AND verdictKind IS NULL)
      OR
      (kind = 'verdict' AND verdictKind IS NOT NULL AND
       ((bySession IS NOT NULL) != (byUser IS NOT NULL)))
    )
  )
  """

  @attests_rebuild_ddl String.replace(@attests_ddl, "IF NOT EXISTS attests", "attests_new")

  @doc "Create the assignment/attest schema."
  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ Tightbeam.DB) do
    # The circular terminal reference requires creating assignments first;
    # SQLite permits the referenced table to arrive in the following DDL.
    :ok = DB.execute(db, @assignments_ddl)
    :ok = DB.execute(db, @attests_ddl)
    ensure_attests_shape(db)
    ensure_work_item_column(db)
  end

  @doc "Count open assignments pinned to a holder session."
  @spec open_count(DB.server(), String.t()) :: non_neg_integer()
  def open_count(db, session_key) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT count(*) FROM assignments WHERE holderKey = ?1 AND state = 'open'", [
        session_key
      ])

    count
  end

  @doc "Return the oldest open assignment held by a session."
  @spec oldest_open(DB.server(), String.t()) :: map() | nil
  def oldest_open(db, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{columns()} FROM assignments WHERE holderKey = ?1 AND state = 'open' ORDER BY openedAt ASC, id ASC LIMIT 1",
        [session_key]
      )

    case rows do
      [row] -> assignment(row)
      [] -> nil
    end
  end

  @doc "Count attest rows for an assignment."
  @spec attest_count(DB.server(), String.t()) :: non_neg_integer()
  def attest_count(db, assignment_id) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT count(*) FROM attests WHERE assignmentId = ?1", [assignment_id])

    count
  end

  @doc "List assignments using optional holder_key and state filters."
  @spec list(DB.server(), map()) :: [map()]
  def list(db, filters) do
    state = Map.get(filters, :state, "open")
    holder = Map.get(filters, :holder_key)

    {clauses, params} =
      [{state != "all", "state", state}, {not is_nil(holder), "holderKey", holder}]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {{_present, column, value}, index}, values ->
        {"#{column} = ?#{index}", values ++ [value]}
      end)

    where = if clauses == [], do: "1 = 1", else: Enum.join(clauses, " AND ")

    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{columns()} FROM assignments WHERE #{where} ORDER BY openedAt DESC, id DESC",
        params
      )

    Enum.map(rows, &assignment/1)
  end

  @doc "Return distinct verdict kinds filed against an assignment."
  @spec verdict_kinds(DB.server(), String.t()) :: [String.t()]
  def verdict_kinds(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT DISTINCT verdictKind FROM attests WHERE assignmentId = ?1 AND kind = 'verdict' ORDER BY verdictKind",
        [assignment_id]
      )

    Enum.map(rows, &hd/1)
  end

  @doc "List every attest filed against an assignment in deterministic order."
  @spec list_attests(DB.server(), String.t()) :: [map()]
  def list_attests(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT id, assignmentId, kind, verdictKind, note, bySession, byUser, ts FROM attests WHERE assignmentId = ?1 ORDER BY ts ASC, id ASC",
        [assignment_id]
      )

    Enum.map(rows, &attest/1)
  end

  @doc false
  def __for_work_item__(db, work_item_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{columns()} FROM assignments WHERE workItemId = ?1 ORDER BY openedAt DESC, id DESC",
        [work_item_id]
      )

    Enum.map(rows, &assignment/1)
  end

  @doc false
  def __handle__(db, "assign", call), do: assign_result(db, call)
  def __handle__(db, "attest", call), do: attest_result(db, call)
  def __handle__(db, "attests", call), do: attests_result(db, call)
  def __handle__(db, "revoke-assignment", call), do: revoke_result(db, call)
  def __handle__(db, "assignments", call), do: assignments_result(db, call)

  defp assign_result(db, call) do
    with :ok <- principal_allowed(call.principal),
         :ok <- valid_subject(call.params[:subject]),
         :ok <- valid_idempotency_key(call.params[:idempotency_key]) do
      owner = principal_id(call.principal)
      key = call.params[:idempotency_key]

      transaction(db, fn txn ->
        case key && idempotency_assignment(txn, owner, key) do
          nil -> create_assignment(txn, call, owner, key)
          id -> fetch_assignment!(txn, id)
        end
      end)
    end
  rescue
    error in UnknownWorkItem -> error("unknown_work_item", Exception.message(error))
  end

  defp attest_result(db, call) do
    with :ok <- principal_allowed(call.principal) do
      transaction(db, fn txn -> attest_in_txn(txn, call) end)
    end
  rescue
    TransitionRace -> assignment_closed()
  end

  defp revoke_result(db, call) do
    with :ok <- principal_allowed(call.principal) do
      transaction(db, fn txn -> revoke_in_txn(txn, call) end)
    end
  rescue
    TransitionRace -> assignment_closed()
  end

  defp assignments_result(db, call) do
    with :ok <- principal_allowed(call.principal),
         :ok <- valid_state(call.params[:state]) do
      %{
        assignments:
          list(db, %{holder_key: call.session_key, state: call.params[:state] || "open"})
      }
    end
  end

  defp attests_result(db, call) do
    assignment_id = call.params[:assignment_id]

    with :ok <- principal_allowed(call.principal) do
      case DB.query(db, "SELECT 1 FROM assignments WHERE id = ?1", [assignment_id]) do
        {:ok, [[1]]} -> %{attests: list_attests(db, assignment_id)}
        {:ok, []} -> error("unknown_assignment", "unknown assignment: #{assignment_id}")
      end
    end
  end

  defp create_assignment(txn, call, owner, key) do
    case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey = ?1", [call.session_key]) do
      [["retired"]] ->
        error("session_retired", "assignments require an active holder session")

      [["active"]] ->
        case call.params[:work_item_id] do
          nil ->
            :ok

          work_item_id ->
            if Txn.q(txn, "SELECT 1 FROM work_items WHERE id = ?1", [work_item_id]) == [],
              do: raise(UnknownWorkItem, work_item_id: work_item_id)
        end

        id = id("asg_")
        now = now()
        {opened_user, opened_session} = opener(call.principal)

        Txn.q(
          txn,
          """
          INSERT INTO assignments
            (id, subject, holderKey, holderRole, holderFallback, openedByUser,
             openedBySession, openedAt, workItemId)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
          """,
          [
            id,
            call.params.subject,
            call.session_key,
            call.target_role,
            if(call.role_fallback, do: 1, else: 0),
            opened_user,
            opened_session,
            now,
            call.params[:work_item_id]
          ]
        )

        if key do
          # ownerUserId and sessionKey are historical column names: for assign
          # they store the prefixed principal id and assignment id respectively.
          Txn.q(
            txn,
            "INSERT INTO wire_idempotency (ownerUserId, operation, idempotencyKey, sessionKey) VALUES (?1, 'assign', ?2, ?3)",
            [owner, key, id]
          )
        end

        fetch_assignment!(txn, id)

      [] ->
        error("not_found", "unknown sessionKey: #{call.session_key}")
    end
  end

  defp attest_in_txn(txn, call) do
    if call.params[:kind] == "verdict",
      do: verdict_in_txn(txn, call),
      else: lifecycle_attest_in_txn(txn, call)
  end

  defp lifecycle_attest_in_txn(txn, call) do
    assignment_id = call.params[:assignment_id]

    case fetch_assignment(txn, assignment_id) do
      nil ->
        error("unknown_assignment", "unknown assignment: #{assignment_id}")

      %{holderKey: holder} = assignment ->
        cond do
          not match?({:session, ^holder}, call.principal) ->
            error("not_holder", "assignment is held by session #{holder}")

          assignment.state != "open" ->
            assignment_closed()

          true ->
            with :ok <- valid_kind(call.params[:kind]),
                 :ok <- valid_note(call.params[:note]),
                 :ok <- absent_verdict_kind(call.params[:verdict_kind]) do
              if Txn.q(txn, "SELECT 1 FROM assignments WHERE id = ?1 AND state = 'open'", [
                   assignment_id
                 ]) != [[1]],
                 do: raise(TransitionRace)

              attest = insert_attest(txn, call, assignment_id)

              if call.params.kind == "progress" do
                %{assignment: assignment, attest: attest}
              else
                outcome =
                  if call.params.kind == "completion", do: "completed", else: "surrendered"

                Txn.q(
                  txn,
                  """
                  UPDATE assignments SET state = 'closed', outcome = ?2, closedAt = ?3,
                    closedBySession = ?4, closingAttestId = ?5
                  WHERE id = ?1 AND state = 'open'
                  """,
                  [assignment_id, outcome, attest.ts, holder, attest.id]
                )

                if Txn.changes(txn) != 1, do: raise(TransitionRace)
                %{assignment: fetch_assignment!(txn, assignment_id), attest: attest}
              end
            end
        end
    end
  end

  defp verdict_in_txn(txn, call) do
    assignment_id = call.params[:assignment_id]

    case fetch_assignment(txn, assignment_id) do
      nil ->
        error("unknown_assignment", "unknown assignment: #{assignment_id}")

      assignment ->
        cond do
          assignment.state != "open" ->
            assignment_closed()

          true ->
            with :ok <- valid_verdict_kind(call.params[:verdict_kind]),
                 :ok <- valid_note(call.params[:note]) do
              if Txn.q(txn, "SELECT 1 FROM assignments WHERE id = ?1 AND state = 'open'", [
                   assignment_id
                 ]) != [[1]],
                 do: raise(TransitionRace)

              attest = insert_attest(txn, call, assignment_id)
              %{assignment: assignment, attest: attest}
            end
        end
    end
  end

  defp revoke_in_txn(txn, call) do
    assignment_id = call.params[:assignment_id]

    case fetch_assignment(txn, assignment_id) do
      nil ->
        error("unknown_assignment", "unknown assignment: #{assignment_id}")

      assignment ->
        cond do
          not revoke_allowed?(txn, call.principal, assignment) ->
            error("not_authorized", "assignment revocation requires its opener or an admin")

          assignment.state != "open" ->
            assignment_closed()

          true ->
            {closed_user, closed_session} = opener(call.principal)

            Txn.q(
              txn,
              """
              UPDATE assignments SET state = 'closed', outcome = 'revoked', closedAt = ?2,
                closedByUser = ?3, closedBySession = ?4
              WHERE id = ?1 AND state = 'open'
              """,
              [assignment_id, now(), closed_user, closed_session]
            )

            if Txn.changes(txn) != 1, do: raise(TransitionRace)
            fetch_assignment!(txn, assignment_id)
        end
    end
  end

  defp revoke_allowed?(txn, {:user, user}, assignment) do
    assignment.openedByUser == user or
      match?([[1]], Txn.q(txn, "SELECT isAdmin FROM users WHERE userId = ?1", [user]))
  end

  defp revoke_allowed?(_txn, {:session, session}, assignment),
    do: assignment.openedBySession == session

  defp insert_attest(txn, call, assignment_id) do
    id = id("att_")
    ts = now()
    {by_user, by_session} = opener(call.principal)

    Txn.q(
      txn,
      "INSERT INTO attests (id, assignmentId, kind, verdictKind, note, bySession, byUser, ts) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
      [
        id,
        assignment_id,
        call.params.kind,
        call.params[:verdict_kind],
        call.params[:note],
        by_session,
        by_user,
        ts
      ]
    )

    attest([
      id,
      assignment_id,
      call.params.kind,
      call.params[:verdict_kind],
      call.params[:note],
      by_session,
      by_user,
      ts
    ])
  end

  defp idempotency_assignment(txn, owner, key) do
    case Txn.q(
           txn,
           "SELECT sessionKey FROM wire_idempotency WHERE ownerUserId = ?1 AND operation = 'assign' AND idempotencyKey = ?2",
           [owner, key]
         ) do
      [[assignment_id]] -> assignment_id
      [] -> nil
    end
  end

  defp fetch_assignment(txn, id) do
    case Txn.q(txn, "SELECT #{columns()} FROM assignments WHERE id = ?1", [id]) do
      [row] -> assignment(row)
      [] -> nil
    end
  end

  defp fetch_assignment!(txn, id), do: fetch_assignment(txn, id) || raise("missing assignment")

  defp principal_allowed({:process, _}),
    do: error("process_denied", "process principals cannot use assignment verbs")

  defp principal_allowed(nil),
    do:
      error(
        "principal_required",
        "assignment verbs require a user credential or a session token"
      )

  defp principal_allowed({kind, _}) when kind in [:session, :user], do: :ok

  defp valid_subject(subject) when is_binary(subject) do
    if String.length(String.trim(subject)) in 1..2000,
      do: :ok,
      else: error("invalid_subject", "subject must be 1..2000 non-blank characters")
  end

  defp valid_subject(_),
    do: error("invalid_subject", "subject must be 1..2000 non-blank characters")

  defp valid_note(nil), do: :ok

  defp valid_note(note) when is_binary(note) do
    if String.length(String.trim(note)) in 1..2000,
      do: :ok,
      else: error("invalid_note", "note must be 1..2000 non-blank characters")
  end

  defp valid_note(_), do: error("invalid_note", "note must be text")

  defp valid_kind(kind) when kind in ["progress", "completion", "surrender"], do: :ok
  defp valid_kind(_), do: error("invalid_kind", "kind must be progress, completion, or surrender")

  defp absent_verdict_kind(nil), do: :ok

  defp absent_verdict_kind(_),
    do: error("invalid_verdict_kind", "verdictKind is only valid when kind is verdict")

  defp valid_verdict_kind(nil),
    do: error("missing_verdict_kind", "verdictKind is required when kind is verdict")

  defp valid_verdict_kind(kind) when is_binary(kind) do
    if String.length(kind) in 1..64 and Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, kind),
      do: :ok,
      else:
        error(
          "invalid_verdict_kind",
          "verdictKind must be 1..64 lowercase letters, digits, or hyphens"
        )
  end

  defp valid_verdict_kind(_),
    do: error("invalid_verdict_kind", "verdictKind must be text")

  defp valid_state(nil), do: :ok
  defp valid_state(state) when state in ["open", "closed", "all"], do: :ok
  defp valid_state(_), do: error("invalid_state_filter", "state must be open, closed, or all")

  defp valid_idempotency_key(nil), do: :ok

  defp valid_idempotency_key(key) when is_binary(key) do
    if String.trim(key) == "" or String.length(key) > 200,
      do:
        error(
          "invalid_idempotency_key",
          "idempotencyKey must be non-blank and at most 200 characters"
        ),
      else: :ok
  end

  defp valid_idempotency_key(_),
    do: error("invalid_idempotency_key", "idempotencyKey must be text")

  defp principal_id({:user, user}), do: "user:" <> user
  defp principal_id({:session, session}), do: "session:" <> session
  defp opener({:user, user}), do: {user, nil}
  defp opener({:session, session}), do: {nil, session}

  defp assignment_closed, do: error("assignment_closed", "assignment is already closed")
  defp error(code, message), do: %{code: code, message: message}

  defp transaction(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp id(prefix), do: prefix <> Tightbeam.Id.uuid4()

  defp now, do: System.system_time(:millisecond)

  defp columns do
    "id, subject, holderKey, holderRole, holderFallback, openedByUser, openedBySession, " <>
      "openedAt, state, outcome, closedAt, closedByUser, closedBySession, closingAttestId" <>
      ", workItemId"
  end

  defp assignment([
         id,
         subject,
         holder_key,
         holder_role,
         holder_fallback,
         opened_by_user,
         opened_by_session,
         opened_at,
         state,
         outcome,
         closed_at,
         closed_by_user,
         closed_by_session,
         closing_attest_id,
         work_item_id
       ]) do
    %{
      id: id,
      subject: subject,
      holderKey: holder_key,
      holderRole: holder_role,
      holderFallback: holder_fallback == 1,
      openedByUser: opened_by_user,
      openedBySession: opened_by_session,
      openedAt: opened_at,
      state: state,
      outcome: outcome,
      closedAt: closed_at,
      closedByUser: closed_by_user,
      closedBySession: closed_by_session,
      closingAttestId: closing_attest_id,
      workItemId: work_item_id
    }
  end

  defp attest([id, assignment_id, kind, verdict_kind, note, by_session, by_user, ts]) do
    %{
      id: id,
      assignmentId: assignment_id,
      kind: kind,
      verdictKind: verdict_kind,
      note: note,
      bySession: by_session,
      byUser: by_user,
      ts: ts
    }
  end

  defp ensure_attests_shape(db) do
    {:ok, [[sql]]} =
      DB.query(db, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'attests'")

    unless String.contains?(sql, "'verdict'") do
      :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")

      try do
        {:ok, :ok} =
          DB.transaction(db, fn txn ->
            Txn.exec(txn, @attests_rebuild_ddl)

            Txn.q(
              txn,
              "INSERT INTO attests_new (id, assignmentId, kind, note, bySession, ts) SELECT id, assignmentId, kind, note, bySession, ts FROM attests"
            )

            Txn.exec(txn, "DROP TABLE attests")
            Txn.exec(txn, "ALTER TABLE attests_new RENAME TO attests")

            case Txn.q(txn, "PRAGMA foreign_key_check") do
              [] -> :ok
              rows -> raise DB.Error, message: "foreign key check failed: #{inspect(rows)}"
            end
          end)
      after
        :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
      end
    end

    :ok
  end

  defp ensure_work_item_column(db) do
    case DB.query(
           db,
           "ALTER TABLE assignments ADD COLUMN workItemId TEXT REFERENCES work_items(id)"
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        if inspect(reason) =~ "duplicate column",
          do: :ok,
          else: raise(reason)
    end
  end
end
