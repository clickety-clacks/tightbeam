defmodule Tightbeam.StateResources do
  @moduledoc """
  Canonical public item serializers shared by state reads and the firehose.

  Every resource enters the public wire through one named function here.
  Storage-secret field names are impossible to emit from this seam.
  """

  @secret_keys MapSet.new(["cliToken", "token", "identityToken"])

  @turn_select """
  SELECT t.seq, t.sessionKey, t.messageId, t.wakeId, t.origin, t.roleRef,
         t.roleFallback, t.assignmentId, t.jobRef, t.model, t.thinkingLevel,
         t.modelContext, t.harness, t.replyAttention, t.status, t.owner,
         t.adapterGen, t.requestRef, t.error, t.createdAt, t.startedAt,
         t.endedAt, t.publishedAt
  FROM turns AS t
  """

  alias Tightbeam.{Artifacts, Assignments, Devices, Org, ReadMarkers, Wakes, WorkItems}

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
        @turn_select <>
          """
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

  def query_turn_in_txn(txn, seq) do
    case Tightbeam.DB.Txn.q(txn, @turn_select <> " WHERE t.seq = ?1", [seq]) do
      [row] -> turn_row(row)
      [] -> nil
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
    ~w(updatedAt endedAt firedAt canceledAt closedAt retiredAt ruledAt withdrawnAt startedAt createdAt openedAt ts seq id)
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
