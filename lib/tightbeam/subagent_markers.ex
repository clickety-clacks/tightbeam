defmodule Tightbeam.SubagentMarkers do
  @moduledoc """
  Durable parent-attributed observations of harness-internal subagent starts
  and stops.
  """

  alias Tightbeam.{ConditionFacts, DB, Org, Wakes}
  alias Tightbeam.DB.Txn

  @type marker :: %{
          kind: String.t(),
          principal: String.t(),
          subagent_ref: String.t(),
          source_event_ref: String.t(),
          harness: String.t(),
          at: integer()
        }

  @ddl """
  CREATE TABLE IF NOT EXISTS subagent_markers (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    kind           TEXT NOT NULL CHECK (kind IN ('subagent_start','subagent_stop')),
    principal      TEXT NOT NULL REFERENCES sessions(sessionKey),
    subagentRef    TEXT NOT NULL,
    sourceEventRef TEXT NOT NULL,
    harness        TEXT NOT NULL CHECK (harness IN (__TIGHTBEAM_HARNESSES__)),
    at             INTEGER NOT NULL,
    assignmentId   TEXT,
    UNIQUE (kind, sourceEventRef)
  );
  CREATE UNIQUE INDEX IF NOT EXISTS subagent_markers_one_stop
    ON subagent_markers (subagentRef) WHERE kind = 'subagent_stop';
  CREATE INDEX IF NOT EXISTS subagent_markers_principal
    ON subagent_markers (principal, id);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    harnesses = Enum.map_join(Tightbeam.Harness.all(), ",", &"'#{&1.wire_name()}'")
    DB.execute(db, String.replace(@ddl, "__TIGHTBEAM_HARNESSES__", harnesses))
  end

  @doc "Append one canonical marker and nudge a matching wake after commit."
  @spec append(DB.server(), GenServer.server(), map()) :: map()
  def append(db \\ DB, scheduler \\ Tightbeam.WakeScheduler, input) do
    {result, fact_id} =
      transaction!(db, fn txn ->
        result = append_in_txn(txn, input)
        {result, result[:fact_id]}
      end)

    if is_integer(fact_id), do: Wakes.fire_matching(scheduler, fact_id)
    result
  end

  @doc "Append one canonical marker inside the caller's transaction."
  @spec append_in_txn(Txn.t(), map()) :: map()
  def append_in_txn(%Txn{} = txn, input) do
    kind = Map.fetch!(input, :kind)
    principal = Map.fetch!(input, :principal)
    subagent_ref = Map.fetch!(input, :subagent_ref)
    source_event_ref = Map.fetch!(input, :source_event_ref)
    harness = input |> Map.fetch!(:harness) |> to_string()
    at = Map.fetch!(input, :at)

    # A captured assignment (including captured nil) is event-time truth. Direct
    # append callers have no earlier event boundary, so they resolve the running
    # carrier in this transaction as before.
    assignment_id =
      case Map.fetch(input, :assignment_id) do
        {:ok, assignment_id} -> assignment_id
        :error -> running_turn_assignment_in_txn(txn, principal)
      end

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO subagent_markers
        (kind, principal, subagentRef, sourceEventRef, harness, at, assignmentId)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      """,
      [kind, principal, subagent_ref, source_event_ref, harness, at, assignment_id]
    )

    if Txn.changes(txn) == 1 do
      marker = %{
        kind: kind,
        principal: principal,
        subagent_ref: subagent_ref,
        source_event_ref: source_event_ref,
        harness: harness,
        at: at,
        assignment_id: assignment_id
      }

      if kind == "subagent_stop" do
        fact =
          ConditionFacts.file_in_txn(txn, %{
            kind: "subagent_stop",
            scope: subagent_ref,
            origin: "process:tightbeam"
          })

        Map.merge(marker, %{appended: true, fact_id: fact.fact_id})
      else
        Map.merge(marker, %{appended: true, fact_id: nil})
      end
    else
      existing =
        if kind == "subagent_stop" do
          marker_by_subagent_in_txn(txn, "subagent_stop", subagent_ref)
        else
          marker_by_source_in_txn(txn, kind, source_event_ref)
        end

      existing
      |> Map.merge(%{appended: false, fact_id: nil})
    end
  end

  @doc "Consume one pinned ACP update after resolving its persisted parent mapping."
  @spec consume_update(
          DB.server(),
          GenServer.server(),
          atom(),
          String.t(),
          String.t(),
          map()
        ) :: map() | :skip | {:error, map()}
  def consume_update(db, scheduler, harness, machine, harness_session_id, update) do
    db
    |> capture_update(harness, machine, harness_session_id, update)
    |> consume_captured(db, scheduler)
  end

  @doc """
  Capture the marker's parent and running-turn carrier at ACP event receipt.

  The returned value contains every mutable fact whose later re-read could
  cross a prompt boundary. Durable insertion and wake delivery may happen
  later without changing that attribution.
  """
  @spec capture_update(DB.server(), atom(), String.t(), String.t(), map()) ::
          :skip | {:ok, map()} | {:error, map()}
  def capture_update(db, harness, machine, harness_session_id, update) do
    case classify(harness, update) do
      :skip ->
        :skip

      {:marker, kind, tool_call_id, child_id} ->
        source_session_ref = Org.source_session_ref(harness, machine, harness_session_id)

        transaction!(db, fn txn ->
          case parent_for_source_in_txn(txn, source_session_ref) do
            nil ->
              {:error,
               %{
                 code: "unknown_source_session",
                 message: "no parent mapping for harness session"
               }}

            principal ->
              {:ok,
               %{
                 kind: kind,
                 principal: principal,
                 subagent_ref: subagent_ref(source_session_ref, child_id),
                 source_event_ref: source_event_ref(source_session_ref, tool_call_id),
                 harness: harness,
                 at: System.system_time(:millisecond),
                 assignment_id: running_turn_assignment_in_txn(txn, principal)
               }}
          end
        end)
    end
  end

  @doc "Persist a previously captured ACP marker and fire its matching wake."
  @spec consume_captured(:skip | {:ok, map()} | {:error, map()}, DB.server(), GenServer.server()) ::
          map() | :skip | {:error, map()}
  def consume_captured(:skip, _db, _scheduler), do: :skip
  def consume_captured({:error, _error} = error, _db, _scheduler), do: error

  def consume_captured({:ok, input}, db, scheduler) do
    result = transaction!(db, &append_in_txn(&1, input))

    case result do
      %{fact_id: fact_id} = marker when is_integer(fact_id) ->
        Wakes.fire_matching(scheduler, fact_id)
        marker

      value ->
        value
    end
  end

  @doc "Resolve a parent-visible tool-call handle to its canonical subagent ref."
  @spec resolve_subagent_in_txn(Txn.t(), String.t(), String.t()) :: String.t() | nil
  def resolve_subagent_in_txn(%Txn{} = txn, parent_session, tool_call_id) do
    txn
    |> Txn.q(
      """
      SELECT sourceSessionRef FROM harness_pointers
      WHERE sessionKey = ?1 AND sourceSessionRef IS NOT NULL
      ORDER BY id DESC
      """,
      [parent_session]
    )
    |> Enum.find_value(fn [source_session_ref] ->
      case marker_by_source_in_txn(
             txn,
             "subagent_start",
             source_event_ref(source_session_ref, tool_call_id)
           ) do
        nil -> nil
        marker -> marker.subagent_ref
      end
    end)
  end

  @doc "Whether a canonical subagent stop already exists in this transaction."
  @spec stopped_in_txn?(Txn.t(), String.t()) :: boolean()
  def stopped_in_txn?(%Txn{} = txn, subagent_ref) do
    marker_by_subagent_in_txn(txn, "subagent_stop", subagent_ref) != nil
  end

  @doc "All markers, oldest first."
  @spec list(DB.server()) :: [marker()]
  def list(db \\ DB) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT kind, principal, subagentRef, sourceEventRef, harness, at, assignmentId
        FROM subagent_markers ORDER BY id
        """
      )

    Enum.map(rows, &to_marker/1)
  end

  @doc "Canonical protocol-event reference."
  @spec source_event_ref(String.t(), String.t()) :: String.t()
  def source_event_ref(source_session_ref, tool_call_id),
    do: encoded_ref("event", [source_session_ref, tool_call_id])

  @doc "Canonical globally unique subagent reference."
  @spec subagent_ref(String.t(), String.t()) :: String.t()
  def subagent_ref(source_session_ref, child_id),
    do: encoded_ref("subagent", [source_session_ref, child_id])

  @doc false
  def classify(harness, update) do
    case Tightbeam.Harness.module!(harness).classify_subagent_event(update) do
      {:subagent_start, refs} ->
        {:marker, "subagent_start", refs.source_event_ref, refs.subagent_ref}

      {:subagent_stop, refs} ->
        {:marker, "subagent_stop", refs.source_event_ref, refs.subagent_ref}

      :skip ->
        :skip
    end
  end

  defp parent_for_source_in_txn(txn, source_session_ref) do
    case Txn.q(
           txn,
           """
           SELECT sessionKey FROM harness_pointers
           WHERE sourceSessionRef = ?1 ORDER BY id DESC LIMIT 1
           """,
           [source_session_ref]
         ) do
      [[session_key]] -> session_key
      [] -> nil
    end
  end

  defp marker_by_source_in_txn(txn, kind, source_event_ref) do
    case Txn.q(
           txn,
           """
           SELECT kind, principal, subagentRef, sourceEventRef, harness, at, assignmentId
           FROM subagent_markers WHERE kind = ?1 AND sourceEventRef = ?2
           LIMIT 1
           """,
           [kind, source_event_ref]
         ) do
      [row] -> to_marker(row)
      [] -> nil
    end
  end

  defp marker_by_subagent_in_txn(txn, kind, subagent_ref) do
    case Txn.q(
           txn,
           """
           SELECT kind, principal, subagentRef, sourceEventRef, harness, at, assignmentId
           FROM subagent_markers WHERE kind = ?1 AND subagentRef = ?2
           LIMIT 1
           """,
           [kind, subagent_ref]
         ) do
      [row] -> to_marker(row)
      [] -> nil
    end
  end

  defp to_marker([kind, principal, subagent_ref, source_event_ref, harness, at, assignment_id]) do
    %{
      kind: kind,
      principal: principal,
      subagent_ref: subagent_ref,
      source_event_ref: source_event_ref,
      harness: harness,
      at: at,
      assignment_id: assignment_id
    }
  end

  # The parent's RUNNING turn is the unique durable carrier at emission time.
  defp running_turn_assignment_in_txn(txn, principal) do
    case Txn.q(
           txn,
           "SELECT assignmentId FROM turns WHERE sessionKey = ?1 AND status = 'running' LIMIT 1",
           [principal]
         ) do
      [[assignment_id]] -> assignment_id
      [] -> nil
    end
  end

  defp encoded_ref(namespace, parts) do
    encoded = parts |> JSON.encode!() |> Base.url_encode64(padding: false)
    namespace <> ":" <> encoded
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
