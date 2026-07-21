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

  defmodule UnknownReviewTarget do
    @moduledoc false
    defexception [:assignment_id]

    @impl true
    def message(%__MODULE__{assignment_id: id}), do: "unknown review target: #{id}"
  end

  @assignments_ddl """
  CREATE TABLE IF NOT EXISTS assignments (
    id TEXT PRIMARY KEY,
    subject TEXT NOT NULL,
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
    reviewsAssignmentId TEXT NULL REFERENCES assignments(id),
    holderHarness TEXT NULL,
    holderProvider TEXT NULL,
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
    note TEXT NULL,
    bySession TEXT NULL REFERENCES sessions(sessionKey),
    byUser TEXT NULL REFERENCES users(userId),
    producer TEXT NULL,
    producerCommand TEXT NULL,
    byHarness TEXT NULL,
    byProvider TEXT NULL,
    ts INTEGER NOT NULL,
    CHECK(
      (kind IN ('progress', 'completion', 'surrender') AND bySession IS NOT NULL AND
       byUser IS NULL AND verdictKind IS NULL)
      OR
      (kind = 'verdict' AND verdictKind IS NOT NULL AND
       ((bySession IS NOT NULL) != (byUser IS NOT NULL)))
    ),
    CHECK(producer IS NULL OR kind = 'verdict'),
    CHECK(producerCommand IS NULL OR producer IS NOT NULL),
    CHECK(byHarness IS NULL OR kind = 'verdict'),
    CHECK(byProvider IS NULL OR kind = 'verdict')
  )
  """

  @attests_rebuild_ddl String.replace(@attests_ddl, "IF NOT EXISTS attests", "attests_new")

  @assignment_files_ddl """
  CREATE TABLE IF NOT EXISTS assignment_files (
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    path TEXT NOT NULL,
    PRIMARY KEY (assignmentId, path)
  );
  CREATE INDEX IF NOT EXISTS assignment_files_path ON assignment_files(path)
  """

  @doc "Create the assignment/attest schema."
  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ Tightbeam.DB) do
    # The circular terminal reference requires creating assignments first;
    # SQLite permits the referenced table to arrive in the following DDL.
    :ok = DB.execute(db, @assignments_ddl)
    :ok = DB.execute(db, @attests_ddl)
    ensure_attests_shape(db)
    ensure_work_item_column(db)
    ensure_assignment_columns(db)
    :ok = DB.execute(db, @assignment_files_ddl)
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

  @doc "Return commissioned independent review verdict authors for an assignment."
  @spec commissioned_review_authors(DB.server(), String.t(), String.t()) :: [map()]
  def commissioned_review_authors(db, assignment_id, a_holder_key) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT v.verdictKind, v.byHarness, v.byProvider
        FROM attests AS v
        JOIN assignments AS r ON r.id = v.assignmentId
        WHERE r.reviewsAssignmentId = ?1
          AND v.kind = 'verdict'
          AND v.bySession = r.holderKey
          AND (r.openedBySession IS NULL OR r.openedBySession != ?2)
          AND v.bySession != ?2
        ORDER BY v.ts ASC, v.id ASC
        """,
        [assignment_id, a_holder_key]
      )

    Enum.map(rows, fn [verdict_kind, by_harness, by_provider] ->
      %{verdict_kind: verdict_kind, by_harness: by_harness, by_provider: by_provider}
    end)
  end

  @doc "Return distinct producer-stamped verdict kinds filed directly on an assignment."
  @spec produced_verdict_kinds(DB.server(), String.t()) :: [String.t()]
  def produced_verdict_kinds(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT DISTINCT verdictKind FROM attests WHERE assignmentId = ?1 AND kind = 'verdict' AND producer IS NOT NULL ORDER BY verdictKind",
        [assignment_id]
      )

    Enum.map(rows, &hd/1)
  end

  @doc "Return the declared file paths for an assignment."
  @spec declared_files(DB.server(), String.t()) :: [String.t()]
  def declared_files(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT path FROM assignment_files WHERE assignmentId = ?1 ORDER BY path",
        [assignment_id]
      )

    Enum.map(rows, &hd/1)
  end

  @doc "Return open assignment ids declaring any of the given paths."
  @spec open_assignments_touching(DB.server(), [String.t()], String.t() | nil) :: [String.t()]
  def open_assignments_touching(db, paths, exclude_id \\ nil)
  def open_assignments_touching(_db, [], _exclude_id), do: []

  def open_assignments_touching(db, paths, exclude_id) do
    {sql, params} = open_assignments_touching_query(paths, exclude_id)
    {:ok, rows} = DB.query(db, sql, params)
    Enum.map(rows, &hd/1)
  end

  @doc "Insert a producer-stamped verdict inside the caller's open transaction."
  @spec insert_producer_verdict_in_txn(Txn.t(), map()) :: {:ok, map()} | {:error, map()}
  def insert_producer_verdict_in_txn(%Txn{} = txn, input) do
    assignment_id = input.assignment_id

    case fetch_assignment(txn, assignment_id) do
      nil ->
        {:error, error("unknown_assignment", "unknown assignment: #{assignment_id}")}

      %{state: state} when state != "open" ->
        {:error, assignment_closed()}

      _assignment ->
        with :ok <- valid_verdict_kind(input.verdict_kind),
             :ok <- valid_producer(input.producer) do
          attest =
            insert_attest_row(txn, %{
              assignment_id: assignment_id,
              kind: "verdict",
              verdict_kind: input.verdict_kind,
              note: nil,
              by_session: input.by_session,
              by_user: input.by_user,
              producer: input.producer,
              producer_command: input.producer_command,
              by_harness: input.by_harness,
              by_provider: input.by_provider
            })

          {:ok, attest}
        else
          %{code: _} = failure -> {:error, failure}
        end
    end
  end

  @doc "List every attest filed against an assignment in deterministic order."
  @spec list_attests(DB.server(), String.t()) :: [map()]
  def list_attests(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT id, assignmentId, kind, verdictKind, note, bySession, byUser, producer, producerCommand, byHarness, byProvider, ts FROM attests WHERE assignmentId = ?1 ORDER BY ts ASC, id ASC",
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
         :ok <- valid_idempotency_key(call.params[:idempotency_key]),
         {:ok, files} <- valid_files(call.params[:files]) do
      owner = principal_id(call.principal)
      key = call.params[:idempotency_key]

      result =
        transaction(db, fn txn ->
          case key && idempotency_assignment(txn, owner, key) do
            nil ->
              case create_assignment(txn, call, owner, key, files) do
                %{code: _} = error -> error
                assignment -> {:created, assignment}
              end

            id ->
              {:replayed, fetch_assignment!(txn, id)}
          end
        end)

      case result do
        {:created, assignment} ->
          best_effort(fn -> notify(call, :on_assignment_change, assignment.id, nil) end)

          if assignment.workItemId do
            best_effort(fn ->
              notify(call, :on_work_item_change, assignment.workItemId, "composition")
            end)
          end

          assignment

        {:replayed, assignment} ->
          assignment

        error ->
          error
      end
    end
  rescue
    error in UnknownWorkItem -> error("unknown_work_item", Exception.message(error))
    error in UnknownReviewTarget -> error("unknown_review_target", Exception.message(error))
  end

  defp attest_result(db, call) do
    with :ok <- principal_allowed(call.principal) do
      assignment_id = call.params[:assignment_id]
      from = best_effort_value(fn -> Tightbeam.WorkState.status(db, assignment_id) end)
      result = transaction(db, fn txn -> attest_in_txn(txn, call) end)

      if not Map.has_key?(result, :code) and match?({:ok, _}, from) do
        {:ok, from} = from
        best_effort(fn -> notify(call, :on_assignment_change, assignment_id, from) end)
      end

      result
    end
  rescue
    TransitionRace -> assignment_closed()
  end

  defp revoke_result(db, call) do
    with :ok <- principal_allowed(call.principal) do
      assignment_id = call.params[:assignment_id]
      from = best_effort_value(fn -> Tightbeam.WorkState.status(db, assignment_id) end)
      result = transaction(db, fn txn -> revoke_in_txn(txn, call) end)

      if not Map.has_key?(result, :code) and match?({:ok, _}, from) do
        {:ok, from} = from
        best_effort(fn -> notify(call, :on_assignment_change, assignment_id, from) end)
      end

      result
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

  defp create_assignment(txn, call, owner, key, files) do
    case Txn.q(txn, "SELECT state, harness, provider FROM sessions WHERE sessionKey = ?1", [
           call.session_key
         ]) do
      [["retired", _harness, _provider]] ->
        error("session_retired", "assignments require an active holder session")

      [["active", harness, provider]] ->
        case call.params[:work_item_id] do
          nil ->
            :ok

          work_item_id ->
            if Txn.q(txn, "SELECT 1 FROM work_items WHERE id = ?1", [work_item_id]) == [],
              do: raise(UnknownWorkItem, work_item_id: work_item_id)
        end

        reviews_assignment_id = call.params[:reviews_assignment_id]

        if reviews_assignment_id &&
             Txn.q(txn, "SELECT 1 FROM assignments WHERE id = ?1", [reviews_assignment_id]) == [],
           do: raise(UnknownReviewTarget, assignment_id: reviews_assignment_id)

        case open_assignments_touching_in_txn(txn, files, nil) do
          [] -> :ok
          [colliding_id | _] -> throw({:files_overlap, colliding_id})
        end

        id = id("asg_")
        now = now()
        {opened_user, opened_session} = opener(call.principal)

        Txn.q(
          txn,
          """
          INSERT INTO assignments
            (id, subject, holderKey, holderRole, holderFallback, openedByUser,
             openedBySession, openedAt, workItemId, reviewsAssignmentId,
             holderHarness, holderProvider)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
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
            call.params[:work_item_id],
            reviews_assignment_id,
            harness,
            provider
          ]
        )

        Enum.each(files, fn path ->
          Txn.q(
            txn,
            "INSERT INTO assignment_files (assignmentId, path) VALUES (?1, ?2)",
            [id, path]
          )
        end)

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
  catch
    {:files_overlap, colliding_id} ->
      error(
        "files_overlap",
        "declared files overlap open assignment #{colliding_id}"
      )
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
    {by_user, by_session} = opener(call.principal)
    {by_harness, by_provider} = verdict_author_family(txn, call.params.kind, by_session)

    insert_attest_row(txn, %{
      assignment_id: assignment_id,
      kind: call.params.kind,
      verdict_kind: call.params[:verdict_kind],
      note: call.params[:note],
      by_session: by_session,
      by_user: by_user,
      producer: nil,
      producer_command: nil,
      by_harness: by_harness,
      by_provider: by_provider
    })
  end

  defp insert_attest_row(txn, attrs) do
    id = id("att_")
    ts = now()

    Txn.q(
      txn,
      """
      INSERT INTO attests
        (id, assignmentId, kind, verdictKind, note, bySession, byUser, producer,
         producerCommand, byHarness, byProvider, ts)
      SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12
      WHERE EXISTS (SELECT 1 FROM assignments WHERE id = ?2 AND state = 'open')
      """,
      [
        id,
        attrs.assignment_id,
        attrs.kind,
        attrs.verdict_kind,
        attrs.note,
        attrs.by_session,
        attrs.by_user,
        attrs.producer,
        attrs.producer_command,
        attrs.by_harness,
        attrs.by_provider,
        ts
      ]
    )

    if Txn.changes(txn) != 1, do: raise(TransitionRace)

    attest([
      id,
      attrs.assignment_id,
      attrs.kind,
      attrs.verdict_kind,
      attrs.note,
      attrs.by_session,
      attrs.by_user,
      attrs.producer,
      attrs.producer_command,
      attrs.by_harness,
      attrs.by_provider,
      ts
    ])
  end

  defp verdict_author_family(_txn, kind, _by_session) when kind != "verdict", do: {nil, nil}
  defp verdict_author_family(_txn, "verdict", nil), do: {nil, nil}

  defp verdict_author_family(txn, "verdict", by_session) do
    case Txn.q(txn, "SELECT harness, provider FROM sessions WHERE sessionKey = ?1", [by_session]) do
      [[harness, provider]] -> {harness, provider}
    end
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
    max = Application.get_env(:tightbeam, :max_subject_len, 2000)

    if String.length(String.trim(subject)) in 1..max,
      do: :ok,
      else: error("invalid_subject", "subject must be 1..#{max} non-blank characters")
  end

  defp valid_subject(_) do
    max = Application.get_env(:tightbeam, :max_subject_len, 2000)
    error("invalid_subject", "subject must be 1..#{max} non-blank characters")
  end

  defp valid_note(nil), do: :ok

  defp valid_note(note) when is_binary(note) do
    max = Application.get_env(:tightbeam, :max_note_len, 2000)

    if String.length(String.trim(note)) in 1..max,
      do: :ok,
      else: error("invalid_note", "note must be 1..#{max} non-blank characters")
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
    max = Application.get_env(:tightbeam, :max_verdict_kind_len, 64)

    if String.length(kind) in 1..max and Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, kind),
      do: :ok,
      else:
        error(
          "invalid_verdict_kind",
          "verdictKind must be 1..#{max} lowercase letters, digits, or hyphens"
        )
  end

  defp valid_verdict_kind(_),
    do: error("invalid_verdict_kind", "verdictKind must be text")

  defp valid_state(nil), do: :ok
  defp valid_state(state) when state in ["open", "closed", "all"], do: :ok
  defp valid_state(_), do: error("invalid_state_filter", "state must be open, closed, or all")

  defp valid_idempotency_key(nil), do: :ok

  defp valid_idempotency_key(key) when is_binary(key) do
    max = Application.get_env(:tightbeam, :max_idem_key_len, 200)

    if String.trim(key) == "" or String.length(key) > max,
      do:
        error(
          "invalid_idempotency_key",
          "idempotencyKey must be non-blank and at most #{max} characters"
        ),
      else: :ok
  end

  defp valid_idempotency_key(_),
    do: error("invalid_idempotency_key", "idempotencyKey must be text")

  defp valid_files(nil), do: {:ok, []}

  defp valid_files(files) when is_list(files) do
    if Enum.all?(files, fn
         path when is_binary(path) -> String.length(String.trim(path)) in 1..2000
         _ -> false
       end) do
      {:ok, Enum.uniq(files)}
    else
      error("invalid_files", "files must contain non-blank paths of at most 2000 characters")
    end
  end

  defp valid_files(_),
    do: error("invalid_files", "files must be an array of paths")

  defp valid_producer(producer) when is_binary(producer) do
    if String.length(producer) in 1..64 and
         Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, producer),
       do: :ok,
       else:
         error(
           "invalid_producer",
           "producer must be 1..64 lowercase letters, digits, or hyphens"
         )
  end

  defp valid_producer(_), do: error("invalid_producer", "producer must be text")

  defp open_assignments_touching_in_txn(_txn, [], _exclude_id), do: []

  defp open_assignments_touching_in_txn(txn, paths, exclude_id) do
    {sql, params} = open_assignments_touching_query(paths, exclude_id)
    Txn.q(txn, sql, params) |> Enum.map(&hd/1)
  end

  defp open_assignments_touching_query(paths, exclude_id) do
    placeholders =
      paths
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_path, index} -> "?#{index}" end)

    exclude_clause =
      if exclude_id do
        " AND a.id != ?#{length(paths) + 1}"
      else
        ""
      end

    params = if exclude_id, do: paths ++ [exclude_id], else: paths

    {
      "SELECT DISTINCT a.id FROM assignments AS a JOIN assignment_files AS f ON f.assignmentId = a.id WHERE a.state = 'open' AND f.path IN (#{placeholders})#{exclude_clause} ORDER BY a.id",
      params
    }
  end

  defp principal_id({:user, user}), do: "user:" <> user
  defp principal_id({:session, session}), do: "session:" <> session
  defp opener({:user, user}), do: {user, nil}
  defp opener({:session, session}), do: {nil, session}

  defp assignment_closed, do: error("assignment_closed", "assignment is already closed")
  defp error(code, message), do: %{code: code, message: message}

  defp notify(call, key, first, second) do
    Map.get(call, key, fn _, _ -> :ok end).(first, second)
  end

  defp best_effort(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp best_effort_value(fun) do
    try do
      {:ok, fun.()}
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

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
      ", workItemId, reviewsAssignmentId, holderHarness, holderProvider"
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
         work_item_id,
         reviews_assignment_id,
         holder_harness,
         holder_provider
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
      workItemId: work_item_id,
      reviewsAssignmentId: reviews_assignment_id,
      holderHarness: holder_harness,
      holderProvider: holder_provider
    }
  end

  defp attest([
         id,
         assignment_id,
         kind,
         verdict_kind,
         note,
         by_session,
         by_user,
         producer,
         producer_command,
         by_harness,
         by_provider,
         ts
       ]) do
    %{
      id: id,
      assignmentId: assignment_id,
      kind: kind,
      verdictKind: verdict_kind,
      note: note,
      bySession: by_session,
      byUser: by_user,
      producer: producer,
      producerCommand: producer_command,
      byHarness: by_harness,
      byProvider: by_provider,
      ts: ts
    }
  end

  defp ensure_attests_shape(db) do
    {:ok, [[sql]]} =
      DB.query(db, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'attests'")

    target_fragments = [
      "producer TEXT NULL",
      "producerCommand TEXT NULL",
      "byHarness TEXT NULL",
      "byProvider TEXT NULL",
      "CHECK(producer IS NULL OR kind = 'verdict')",
      "CHECK(producerCommand IS NULL OR producer IS NOT NULL)",
      "CHECK(byHarness IS NULL OR kind = 'verdict')",
      "CHECK(byProvider IS NULL OR kind = 'verdict')"
    ]

    unless Enum.all?(target_fragments, &String.contains?(sql, &1)) do
      {:ok, table_info} = DB.query(db, "PRAGMA table_info(attests)")
      existing = MapSet.new(table_info, &Enum.at(&1, 1))

      final_columns = [
        "id",
        "assignmentId",
        "kind",
        "verdictKind",
        "note",
        "bySession",
        "byUser",
        "producer",
        "producerCommand",
        "byHarness",
        "byProvider",
        "ts"
      ]

      copied_columns = Enum.filter(final_columns, &MapSet.member?(existing, &1))
      copied = Enum.join(copied_columns, ", ")

      :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")

      try do
        {:ok, :ok} =
          DB.transaction(db, fn txn ->
            Txn.exec(txn, @attests_rebuild_ddl)

            Txn.q(
              txn,
              "INSERT INTO attests_new (#{copied}) SELECT #{copied} FROM attests"
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

  defp ensure_assignment_columns(db) do
    for ddl <- [
          "ALTER TABLE assignments ADD COLUMN reviewsAssignmentId TEXT REFERENCES assignments(id)",
          "ALTER TABLE assignments ADD COLUMN holderHarness TEXT",
          "ALTER TABLE assignments ADD COLUMN holderProvider TEXT"
        ] do
      case DB.query(db, ddl) do
        {:ok, _} -> :ok
        {:error, reason} -> if inspect(reason) =~ "duplicate column", do: :ok, else: raise(reason)
      end
    end

    :ok
  end
end
