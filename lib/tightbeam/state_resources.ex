defmodule Tightbeam.StateResources do
  @moduledoc """
  Canonical public item serializers shared by state reads and the firehose.

  Every resource enters the public wire through one named function here.
  Storage-secret field names are impossible to emit from this seam.
  """

  @secret_keys MapSet.new(["cliToken", "token", "identityToken"])

  alias Tightbeam.{
    Artifacts,
    Assignments,
    Devices,
    Escalation,
    Org,
    Projection,
    ReadMarkers,
    Wakes,
    WorkItems
  }

  @doc "Fetch one canonical resource row before public serialization."
  def query(db, resource, id, context \\ %{})

  def query(db, "work-items", id, %{call: call}), do: query_work_item(db, id, call)
  def query(db, "assignments", id, %{call: call}), do: query_assignment(db, id, call)

  def query(db, "attests", id, _context) do
    with {:ok, [[assignment_id]]} <-
           Tightbeam.DB.query(db, "SELECT assignmentId FROM attests WHERE id = ?1", [id]) do
      Enum.find(Assignments.list_attests(db, assignment_id), &(&1.id == id))
    else
      {:ok, []} -> nil
    end
  end

  def query(db, "wakes", id, _context), do: Wakes.get(db, id)
  def query(db, "productions", id, _context), do: query_production(db, id)
  def query(db, "turns", id, _context), do: query_turn(db, id)

  def query(db, "decision-requests", id, %{call: call} = context) do
    Escalation.get(db, call, id, owner_user_id: context[:owner_user_id])
  end

  def query(db, "sessions", id, _context), do: Org.get(db, id)
  def query(db, "roles", id, _context), do: query_role(db, id)
  def query(db, "users", id, _context), do: Devices.user(db, id)
  def query(db, "devices", id, _context), do: query_device(db, id)
  def query(db, "artifacts", id, _context), do: Artifacts.get(db, id)

  def query(db, "read-markers", id, %{user_id: user_id}),
    do: ReadMarkers.get(db, user_id, id)

  def query(db, "messages", id, _context), do: Projection.get(db, id)
  def query(db, "condition-facts", id, _context), do: query_condition_fact(db, id)
  def query(db, "critical-state", id, _context), do: Tightbeam.CriticalLeases.get(db, id)

  def query_work_item(db, id, call) do
    case WorkItems.__handle__(db, "work-item-get", %{call | params: %{work_item_id: id}}) do
      %{workItem: row} -> row
      %{"workItem" => row} -> row
      _ -> nil
    end
  end

  def query_assignment(db, id, call) do
    case Assignments.__handle__(db, "assignment-get", %{call | params: %{assignment_id: id}}) do
      %{assignment: row} -> row
      %{"assignment" => row} -> row
      %{code: _code} -> nil
      %{} = row -> row
      _ -> nil
    end
  end

  def query_wake(db, id), do: Wakes.get(db, id)
  def query_session(db, id), do: Org.get(db, id)

  def query_role(db, id) do
    case Tightbeam.DB.query(
           db,
           "SELECT name, boundSessionKey, ownerUserId, createdAt, updatedAt FROM roles WHERE name = ?1",
           [id]
         ) do
      {:ok, [[name, bound_session_key, owner_user_id, created_at, updated_at]]} ->
        %{
          name: name,
          bound_session_key: bound_session_key,
          owner_user_id: owner_user_id,
          created_at: created_at,
          updated_at: updated_at
        }

      {:ok, []} ->
        nil
    end
  end

  def query_artifact(db, id), do: Artifacts.get(db, id)

  def query_device(db, id) do
    case Devices.by_id(db, id) do
      nil -> nil
      device -> Map.put(device, :row_version, Devices.version(db, id) || device.created_at)
    end
  end

  def query_user(db, id), do: Devices.user(db, id)
  def query_read_marker(db, user_id, scope_key), do: ReadMarkers.get(db, user_id, scope_key)
  def query_critical_state(db, session_key), do: Tightbeam.CriticalLeases.get(db, session_key)

  def query_production(db, seq) do
    {:ok, rows} =
      Tightbeam.DB.query(
        db,
        """
        SELECT seq, at, jobRef, assignmentId, sessionKey, kind, detail
        FROM causal_events WHERE seq = ?1 AND kind = 'prod_fired'
        """,
        [seq]
      )

    case rows do
      [[event_seq, at, job_ref, assignment_id, session_key, kind, detail]] ->
        %{
          seq: event_seq,
          at: at,
          job_ref: job_ref,
          assignment_id: assignment_id,
          session_key: session_key,
          kind: kind,
          detail: JSON.decode!(detail)
        }

      [] ->
        nil
    end
  end

  def query_turn(db, session_key, message_id) do
    {:ok, rows} =
      Tightbeam.DB.query(
        db,
        """
        SELECT t.seq, t.sessionKey, t.messageId, t.wakeId, t.origin, t.roleRef,
               t.roleFallback, t.assignmentId, t.jobRef, t.model, t.thinkingLevel,
               t.modelContext, t.harness, t.replyAttention, t.status, t.owner,
               t.adapterGen, t.requestRef, t.error, t.createdAt, t.startedAt,
               t.endedAt, t.publishedAt
        FROM turns AS t
        LEFT JOIN messages AS m ON m.id = t.messageId
        WHERE t.sessionKey = ?1 AND (t.messageId = ?2 OR m.clientMessageId = ?2)
        ORDER BY t.seq DESC LIMIT 1
        """,
        [session_key, message_id]
      )

    case rows do
      [row] -> turn_row(row)
      [] -> nil
    end
  end

  def query_turn(db, seq) do
    {:ok, rows} =
      Tightbeam.DB.query(
        db,
        """
        SELECT seq, sessionKey, messageId, wakeId, origin, roleRef,
               roleFallback, assignmentId, jobRef, model, thinkingLevel,
               modelContext, harness, replyAttention, status, owner,
               adapterGen, requestRef, error, createdAt, startedAt,
               endedAt, publishedAt
        FROM turns WHERE seq = ?1
        """,
        [seq]
      )

    case rows do
      [row] -> turn_row(row)
      [] -> nil
    end
  end

  defp query_condition_fact(db, id) do
    case Tightbeam.DB.query(
           db,
           "SELECT id, ts, kind, scope, origin FROM condition_facts WHERE id = ?1",
           [id]
         ) do
      {:ok, [[fact_id, ts, kind, scope, origin]]} ->
        %{fact_id: fact_id, ts: ts, kind: kind, scope: scope, origin: origin}

      {:ok, []} ->
        nil
    end
  end

  def work_item(row), do: public(row)
  def assignment(row), do: public(row)
  def attest(row), do: public(row)
  def wake(row), do: public(row)
  def production(row), do: row |> public() |> correlate("eventId", "seq")
  def turn(row), do: row |> public() |> correlate("turnSeq", "seq")
  def decision_request(row), do: public(row)
  def session(row), do: public(row)
  def role(row), do: row |> public() |> correlate("role", "name")
  def artifact(row), do: public(row)
  def message(row), do: public(row)

  def condition_fact(row) do
    row = public(row)
    fact_id = row["factId"] || row["id"]

    row
    |> Map.put_new("factId", fact_id)
    |> Map.put("rowVersion", fact_id)
  end

  def critical_state(row), do: public(row)
  def device(row), do: row |> public() |> correlate("deviceId", "id")
  def user(row), do: row |> public() |> correlate("userId", "id")
  def read_marker(row), do: public(row)
  def observation(row), do: public(row)

  defp turn_row([
         seq,
         session_key,
         message_id,
         wake_id,
         origin,
         role_ref,
         role_fallback,
         assignment_id,
         job_ref,
         model,
         thinking_level,
         model_context,
         harness,
         reply_attention,
         status,
         owner,
         adapter_gen,
         request_ref,
         error,
         created_at,
         started_at,
         ended_at,
         published_at
       ]) do
    %{
      seq: seq,
      session_key: session_key,
      message_id: message_id,
      wake_id: wake_id,
      origin: origin,
      role_ref: role_ref,
      role_fallback: role_fallback == 1,
      assignment_id: assignment_id,
      job_ref: job_ref,
      model: model,
      thinking_level: thinking_level,
      model_context: model_context,
      harness: harness,
      reply_attention: reply_attention == 1,
      status: status,
      owner: owner,
      adapter_gen: adapter_gen,
      request_ref: request_ref,
      error: error,
      created_at: created_at,
      started_at: started_at,
      ended_at: ended_at,
      published_at: published_at
    }
  end

  defp correlate(row, primary, source) do
    case row[source] do
      nil -> row
      value -> Map.put_new(row, primary, value)
    end
  end

  defp public(row) when is_struct(row), do: row |> Map.from_struct() |> public()

  defp public(row) when is_map(row) do
    Map.new(row, fn {key, value} -> {wire_key(key), public(value)} end)
    |> Map.reject(fn {key, _value} -> MapSet.member?(@secret_keys, key) end)
    |> ensure_row_version()
  end

  defp public(rows) when is_list(rows), do: Enum.map(rows, &public/1)
  defp public(value) when is_atom(value), do: Atom.to_string(value)
  defp public(value), do: value

  defp ensure_row_version(row) do
    version = row["rowVersion"] || natural_version(row)

    if is_integer(version), do: Map.put_new(row, "rowVersion", version), else: row
  end

  defp natural_version(row) do
    ~w(updatedAt endedAt firedAt canceledAt closedAt retiredAt ruledAt answeredAt withdrawnAt consumedAt startedAt createdAt openedAt raisedAt ts seq id)
    |> Enum.map(&row[&1])
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp wire_key(key) when is_binary(key), do: key

  defp wire_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.split("_")
    |> case do
      [head | tail] -> head <> Enum.map_join(tail, &String.capitalize/1)
      [] -> ""
    end
  end

  defp wire_key(key), do: to_string(key)
end
