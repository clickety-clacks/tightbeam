defmodule Tightbeam.AssignmentHolds do
  @moduledoc "Durable held and standing dispositions for open assignments."

  alias Tightbeam.{DB, EventLog, Projection, Supervision}
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS assignment_holds (
    id TEXT PRIMARY KEY,
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    kind TEXT NOT NULL CHECK(kind IN ('held','standing')),
    reason TEXT NOT NULL CHECK(length(trim(reason)) BETWEEN 1 AND 2000),
    releaseCondition TEXT NOT NULL CHECK(length(trim(releaseCondition)) BETWEEN 1 AND 2000),
    releaseFactKind TEXT NULL,
    releaseFactScope TEXT NULL,
    releaseFactPrincipalRef TEXT NULL,
    imposedByRef TEXT NOT NULL,
    imposedAt INTEGER NOT NULL,
    releasedAt INTEGER NULL,
    releasedByRef TEXT NULL,
    releaseKind TEXT NULL CHECK(releaseKind IN ('released','release-fact','assignment-closed')),
    releaseNote TEXT NULL,
    releaseFactId INTEGER NULL REFERENCES condition_facts(id),
    imposeKey TEXT NULL,
    releaseKey TEXT NULL,
    CHECK(
      (releaseFactKind IS NULL AND releaseFactScope IS NULL AND releaseFactPrincipalRef IS NULL)
      OR
      (releaseFactKind IS NOT NULL AND releaseFactScope IS NOT NULL AND releaseFactPrincipalRef IS NOT NULL)
    ),
    CHECK(kind != 'standing' OR releaseFactKind IS NULL),
    CHECK(
      (releasedAt IS NULL AND releasedByRef IS NULL AND releaseKind IS NULL AND
       releaseNote IS NULL AND releaseFactId IS NULL)
      OR
      (releasedAt IS NOT NULL AND releasedByRef IS NOT NULL AND releaseKind IS NOT NULL)
    ),
    CHECK(releaseKind != 'released' OR length(trim(releaseNote)) BETWEEN 1 AND 2000),
    CHECK(releaseKind != 'release-fact' OR releaseFactId IS NOT NULL),
    CHECK(releaseKind != 'assignment-closed' OR releasedByRef = 'process:tightbeam')
  );
  CREATE UNIQUE INDEX IF NOT EXISTS assignment_holds_active
    ON assignment_holds(assignmentId) WHERE releasedAt IS NULL;
  CREATE INDEX IF NOT EXISTS assignment_holds_history
    ON assignment_holds(assignmentId, imposedAt DESC, id DESC);
  CREATE INDEX IF NOT EXISTS assignment_holds_release_fact
    ON assignment_holds(releaseFactKind, releaseFactScope, releaseFactPrincipalRef)
    WHERE releasedAt IS NULL AND releaseFactKind IS NOT NULL;
  CREATE UNIQUE INDEX IF NOT EXISTS assignment_holds_impose_key
    ON assignment_holds(imposedByRef, imposeKey) WHERE imposeKey IS NOT NULL;
  CREATE UNIQUE INDEX IF NOT EXISTS assignment_holds_release_key
    ON assignment_holds(releasedByRef, releaseKey) WHERE releaseKey IS NOT NULL;
  """

  @columns "id,assignmentId,kind,reason,releaseCondition,releaseFactKind,releaseFactScope," <>
             "releaseFactPrincipalRef,imposedByRef,imposedAt,releasedAt,releasedByRef," <>
             "releaseKind,releaseNote,releaseFactId"

  def ensure_schema(db), do: DB.execute(db, @ddl)
  def ensure_schema_in_txn(%Txn{} = txn), do: Txn.exec(txn, @ddl)

  @doc false
  def migrate_schema_in_txn(%Txn{} = txn) do
    :ok = ensure_schema_in_txn(txn)

    expected = ~w(id assignmentId kind reason releaseCondition releaseFactKind releaseFactScope
                  releaseFactPrincipalRef imposedByRef imposedAt releasedAt releasedByRef
                  releaseKind releaseNote releaseFactId imposeKey releaseKey)

    actual = Enum.map(Txn.q(txn, "PRAGMA table_info(assignment_holds)"), &Enum.at(&1, 1))

    indexes =
      Txn.q(
        txn,
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='assignment_holds' ORDER BY name"
      )
      |> Enum.map(&hd/1)
      |> Enum.reject(&String.starts_with?(&1, "sqlite_autoindex_"))

    required = ~w(assignment_holds_active assignment_holds_history assignment_holds_impose_key
                  assignment_holds_release_fact assignment_holds_release_key)

    unless actual == expected and Enum.sort(indexes) == Enum.sort(required) do
      raise DB.Error,
        message:
          "incompatible assignment_hold schema: columns=#{inspect(actual)} indexes=#{inspect(indexes)}"
    end

    :ok
  end

  def active_in_txn?(%Txn{} = txn, assignment_id) do
    Txn.q(txn, "SELECT 1 FROM assignment_holds WHERE assignmentId=?1 AND releasedAt IS NULL", [
      assignment_id
    ]) != []
  end

  def active(db, assignment_id) do
    case DB.query(
           db,
           "SELECT #{@columns} FROM assignment_holds WHERE assignmentId=?1 AND releasedAt IS NULL",
           [assignment_id]
         ) do
      {:ok, [row]} -> hold(row)
      {:ok, []} -> nil
    end
  end

  def history(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{@columns} FROM assignment_holds WHERE assignmentId=?1 ORDER BY imposedAt DESC,id DESC",
        [assignment_id]
      )

    Enum.map(rows, &hold/1)
  end

  def attach(db, assignment) do
    Map.put(assignment, :hold, active(db, assignment.id))
  end

  def attach_many(assignments, db) do
    ids = Enum.map(assignments, & &1.id)

    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{@columns} FROM assignment_holds WHERE releasedAt IS NULL AND assignmentId IN (SELECT value FROM json_each(?1))",
        [JSON.encode!(ids)]
      )

    active = Map.new(rows, fn row -> {Enum.at(row, 1), hold(row)} end)
    Enum.map(assignments, &Map.put(&1, :hold, Map.get(active, &1.id)))
  end

  def impose(db, call) do
    params = call.params
    assignment_id = params[:assignment_id]

    with :ok <- validate_imposition(params) do
      transaction(db, fn txn -> impose_in_txn(txn, call, assignment_id) end)
    end
  end

  def release(db, call) do
    with :ok <- nonblank(call.params[:reason], "reason") do
      transaction(db, fn txn -> release_explicit_in_txn(txn, call) end)
    end
  end

  def release_by_fact_in_txn(%Txn{} = txn, fact) do
    Txn.q(
      txn,
      """
      SELECT id,assignmentId FROM assignment_holds
      WHERE releasedAt IS NULL AND releaseFactKind=?1 AND releaseFactScope=?2
        AND releaseFactPrincipalRef=?3 ORDER BY imposedAt,id
      """,
      [fact.kind, fact.scope, fact.origin]
    )
    |> Enum.each(fn [hold_id, assignment_id] ->
      release_in_txn(
        txn,
        hold_id,
        assignment_id,
        fact.ts,
        fact.origin,
        "release-fact",
        nil,
        fact.fact_id,
        nil
      )
    end)

    :ok
  end

  def release_for_closure_in_txn(%Txn{} = txn, assignment_id) do
    case active_row_in_txn(txn, assignment_id) do
      nil ->
        :ok

      row ->
        release_in_txn(
          txn,
          row.id,
          assignment_id,
          now(),
          "process:tightbeam",
          "assignment-closed",
          nil,
          nil,
          nil
        )

        :ok
    end
  end

  defp impose_in_txn(txn, call, assignment_id) do
    principal = principal_ref(call.principal)
    key = call.params[:idempotency_key]

    with {:ok, assignment} <- open_assignment(txn, assignment_id),
         :ok <- authorized(assignment, call.principal) do
      case impose_replay_in_txn(txn, principal, key, call.params) do
        {:replay, existing} ->
          existing

        :new ->
          if active_in_txn?(txn, assignment_id) do
            error(
              "hold_active",
              "assignment already has an active hold; release it before imposing another"
            )
          else
            hold_id = "hold_" <> Tightbeam.Id.uuid4()
            at = now()

            Txn.q(
              txn,
              """
              INSERT INTO assignment_holds
                (id,assignmentId,kind,reason,releaseCondition,releaseFactKind,
                 releaseFactScope,releaseFactPrincipalRef,imposedByRef,imposedAt,imposeKey)
              VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
              """,
              [
                hold_id,
                assignment_id,
                call.params[:kind],
                String.trim(call.params[:reason]),
                String.trim(call.params[:release]),
                call.params[:release_fact_kind],
                call.params[:release_fact_scope],
                call.params[:release_fact_principal_ref],
                principal,
                at,
                key
              ]
            )

            Supervision.assignment_hold_imposed_in_txn(txn, assignment_id, hold_id)
            lifecycle(txn, "assignment_hold_imposed", hold_id, assignment_id, principal)

            marker(
              txn,
              assignment.holderKey,
              "[assignment held: #{assignment_id} #{hold_id} #{call.params[:kind]} by #{principal}]"
            )

            active_row_in_txn(txn, assignment_id)
          end

        error when is_map(error) ->
          error
      end
    else
      {:error, error} -> error
      error when is_map(error) -> error
    end
  end

  defp release_explicit_in_txn(txn, call) do
    assignment_id = call.params[:assignment_id]
    principal = principal_ref(call.principal)
    key = call.params[:idempotency_key]

    case release_replay_in_txn(txn, principal, key, call.params[:reason]) do
      {:replay, existing} ->
        existing

      :new ->
        case assignment_row_in_txn(txn, assignment_id) do
          nil ->
            error("not_found", "unknown assignment: #{assignment_id}")

          assignment ->
            with :ok <- authorized(assignment, call.principal) do
              case active_row_in_txn(txn, assignment_id) do
                nil ->
                  error("no_active_hold", "assignment has no active hold to release")

                row ->
                  release_in_txn(
                    txn,
                    row.id,
                    assignment_id,
                    now(),
                    principal,
                    "released",
                    String.trim(call.params[:reason]),
                    nil,
                    key
                  )
              end
            end
        end

      error when is_map(error) ->
        error
    end
  end

  defp release_in_txn(txn, hold_id, assignment_id, at, principal, kind, note, fact_id, key) do
    Txn.q(
      txn,
      """
      UPDATE assignment_holds SET releasedAt=?2,releasedByRef=?3,releaseKind=?4,
        releaseNote=?5,releaseFactId=?6,releaseKey=?7
      WHERE id=?1 AND releasedAt IS NULL
      """,
      [hold_id, at, principal, kind, note, fact_id, key]
    )

    if Txn.changes(txn) == 1 do
      assignment = assignment_row_in_txn(txn, assignment_id)
      lifecycle(txn, "assignment_hold_released", hold_id, assignment_id, principal)
      suffix = if kind == "release-fact", do: " fact #{fact_id}", else: ""

      marker(
        txn,
        assignment.holderKey,
        "[assignment hold released: #{assignment_id} #{hold_id} #{kind} by #{principal}#{suffix}]"
      )

      if assignment.state == "open" do
        Supervision.assignment_hold_released_in_txn(txn, assignment_id, at)
      end
    end

    hold_row_in_txn(txn, hold_id)
  end

  defp validate_imposition(params) do
    tuple = [
      params[:release_fact_kind],
      params[:release_fact_scope],
      params[:release_fact_principal_ref]
    ]

    with :ok <-
           if(params[:kind] in ["held", "standing"],
             do: :ok,
             else: error("invalid_hold", "kind must be held or standing")
           ),
         :ok <- nonblank(params[:reason], "reason"),
         :ok <- nonblank(params[:release], "release condition"),
         :ok <- validate_tuple(tuple),
         :ok <-
           if(params[:kind] == "standing" and Enum.any?(tuple, &(not is_nil(&1))),
             do: error("invalid_hold", "standing holds forbid release-fact fields"),
             else: :ok
           ) do
      :ok
    end
  end

  defp validate_tuple([nil, nil, nil]), do: :ok

  defp validate_tuple(values) when length(values) == 3 do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else:
        error(
          "invalid_hold",
          "release-fact-kind, release-fact-scope and release-fact-principal-ref must be supplied together"
        )
  end

  defp nonblank(value, field) when is_binary(value) do
    if String.length(value) in 1..2000 and String.trim(value) != "",
      do: :ok,
      else: error("invalid_hold", "#{field} must be 1..2000 non-blank characters")
  end

  defp nonblank(_, field), do: error("invalid_hold", "#{field} is required")

  defp open_assignment(txn, id) do
    case assignment_row_in_txn(txn, id) do
      nil ->
        {:error, error("not_found", "unknown assignment: #{id}")}

      %{state: "open"} = assignment ->
        {:ok, assignment}

      _ ->
        {:error,
         error("assignment_not_open", "assignment is not open; reopen it before imposing a hold")}
    end
  end

  defp assignment_row_in_txn(txn, id) do
    case Txn.q(
           txn,
           "SELECT holderKey,openedBySession,openedByUser,state FROM assignments WHERE id=?1",
           [id]
         ) do
      [[holder, session, user, state]] ->
        %{holderKey: holder, openedBySession: session, openedByUser: user, state: state}

      [] ->
        nil
    end
  end

  defp authorized(_assignment, {:user, _}), do: :ok
  defp authorized(%{holderKey: key}, {:session, key}), do: :ok
  defp authorized(%{openedBySession: key}, {:session, key}) when is_binary(key), do: :ok

  defp authorized(_assignment, _),
    do:
      error(
        "hold_not_authorized",
        "hold changes require the assignment holder, its opener, or an organization user"
      )

  defp impose_replay_in_txn(_txn, _principal, nil, _params), do: :new

  defp impose_replay_in_txn(txn, principal, key, params) do
    case Txn.q(
           txn,
           "SELECT #{@columns} FROM assignment_holds WHERE imposedByRef=?1 AND imposeKey=?2",
           [principal, key]
         ) do
      [] ->
        :new

      [row] ->
        existing = hold(row)

        if existing.assignmentId == params[:assignment_id] and existing.kind == params[:kind] and
             existing.reason == String.trim(params[:reason]) and
             existing.releaseCondition == String.trim(params[:release]) and
             existing.releaseFactKind == params[:release_fact_kind] and
             existing.releaseFactScope == params[:release_fact_scope] and
             existing.releaseFactPrincipalRef == params[:release_fact_principal_ref],
           do: {:replay, existing},
           else: error("conflict", "hold idempotency key already has different immutable content")
    end
  end

  defp release_replay_in_txn(_txn, _principal, nil, _reason), do: :new

  defp release_replay_in_txn(txn, principal, key, reason) do
    case Txn.q(
           txn,
           "SELECT #{@columns} FROM assignment_holds WHERE releasedByRef=?1 AND releaseKey=?2",
           [principal, key]
         ) do
      [] ->
        :new

      [row] ->
        existing = hold(row)

        if existing.releaseKind == "released" and existing.releaseNote == String.trim(reason),
          do: {:replay, existing},
          else:
            error("conflict", "release idempotency key already has different immutable content")
    end
  end

  defp active_row_in_txn(txn, assignment_id) do
    case Txn.q(
           txn,
           "SELECT #{@columns} FROM assignment_holds WHERE assignmentId=?1 AND releasedAt IS NULL",
           [assignment_id]
         ) do
      [row] -> hold(row)
      [] -> nil
    end
  end

  defp hold_row_in_txn(txn, id) do
    [row] = Txn.q(txn, "SELECT #{@columns} FROM assignment_holds WHERE id=?1", [id])
    hold(row)
  end

  defp hold([
         id,
         assignment_id,
         kind,
         reason,
         condition,
         fact_kind,
         fact_scope,
         fact_principal,
         imposed_by,
         imposed_at,
         released_at,
         released_by,
         release_kind,
         release_note,
         fact_id
       ]) do
    %{
      id: id,
      assignmentId: assignment_id,
      kind: kind,
      reason: reason,
      releaseCondition: condition,
      releaseFactKind: fact_kind,
      releaseFactScope: fact_scope,
      releaseFactPrincipalRef: fact_principal,
      imposedByRef: imposed_by,
      imposedAt: imposed_at,
      releasedAt: released_at,
      releasedByRef: released_by,
      releaseKind: release_kind,
      releaseNote: release_note,
      releaseFactId: fact_id,
      heldForMs: (released_at || now()) - imposed_at
    }
  end

  defp lifecycle(txn, kind, hold_id, assignment_id, principal),
    do:
      EventLog.lifecycle_in_txn(
        txn,
        kind,
        hold_id,
        "assignment=#{assignment_id} principal=#{principal}"
      )

  defp marker(txn, holder, text) do
    Projection.append_substrate_in_txn(txn, holder, text)
    :ok
  end

  defp principal_ref({:session, key}), do: "session:" <> key
  defp principal_ref({:user, id}), do: "user:" <> id
  defp principal_ref({:process, name}), do: "process:" <> name
  defp principal_ref(_), do: "unknown"

  defp transaction(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp error(code, message), do: %{code: code, message: message}
  defp now, do: System.system_time(:millisecond)
end
