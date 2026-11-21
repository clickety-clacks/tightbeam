defmodule Tightbeam.HarnessHealth.Hold do
  @moduledoc """
  Reads why a queued turn is not being started: a standing park fence for the
  turn's harness and host.

  A session lane declines to claim a queued turn while the fence stands
  (`HarnessProcess.parked?/2`). The turn stays durable and starts when the fence
  lifts. Nothing is written here: the hold is derived from the fence and from
  the open incident on the same harness and host, so it cannot drift from them.

  The fence can be set by more than one path (a harness-health rate-limit
  incident, the rate-limit reset, an adapter close). The hold therefore does
  not require an incident: with a standing fence and no open incident it still
  reports the fence, with a null incident.
  """

  alias Tightbeam.{DB, Harness}

  @retry_command "tightbeam harness-health-retry"

  @type t :: %{
          incident_id: String.t() | nil,
          failure_class: String.t() | nil,
          since: integer(),
          opened_by_assignment_id: String.t() | nil,
          release: String.t()
        }

  # Columns for a turn read. They need `sessions` aliased `hs` and
  # `harness_park_fences` aliased `hf` (a LEFT JOIN that only matches a queued
  # turn); the order of the incident subselects is the same as `for_host/3`.
  @doc false
  def turn_join_sql do
    """
    LEFT JOIN sessions AS hs ON hs.sessionKey = t.sessionKey
    LEFT JOIN harness_park_fences AS hf
      ON t.status = 'queued' AND hf.adapterKey = hs.harness || ':shared@' || hs.host
    """
  end

  @doc false
  def turn_columns_sql do
    """
    hf.requestedAt,
    (SELECT i.id FROM harness_health_incidents AS i
     WHERE hf.requestedAt IS NOT NULL AND i.harness = hs.harness AND i.host = hs.host
       AND i.state = 'open'
     ORDER BY (i.failureClass = 'rate-limit-dead') DESC, i.openedAt DESC, i.id DESC LIMIT 1),
    (SELECT i.failureClass FROM harness_health_incidents AS i
     WHERE hf.requestedAt IS NOT NULL AND i.harness = hs.harness AND i.host = hs.host
       AND i.state = 'open'
     ORDER BY (i.failureClass = 'rate-limit-dead') DESC, i.openedAt DESC, i.id DESC LIMIT 1)
    """
  end

  @doc "The hold on a harness and host, or nil when no fence stands."
  @spec for_host(DB.server(), String.t(), String.t()) :: t() | nil
  def for_host(db, harness, host) when is_binary(harness) and is_binary(host) do
    key = "#{Harness.parse!(harness).id()}:shared@#{host}"

    with {:ok, [[since]]} <-
           DB.query(db, "SELECT requestedAt FROM harness_park_fences WHERE adapterKey=?1", [key]) do
      {incident_id, failure_class} = open_incident(db, harness, host)

      %{
        incident_id: incident_id,
        failure_class: failure_class,
        since: since,
        opened_by_assignment_id: opened_by(db, incident_id),
        release: release_text(incident_id, failure_class)
      }
    else
      _ -> nil
    end
  end

  @doc """
  The hold on an open assignment whose turn is queued behind a fence and that
  has no failed turn to repair and no running turn (a running assignment is
  executing, not held), or nil.
  """
  @spec for_assignment(DB.server(), String.t()) :: t() | nil
  def for_assignment(db, assignment_id) do
    with {:ok, [[holder_key]]} <-
           DB.query(db, "SELECT holderKey FROM assignments WHERE id=?1 AND state='open'", [
             assignment_id
           ]),
         {:ok, [[1]]} <-
           DB.query(
             db,
             """
             SELECT EXISTS(SELECT 1 FROM turns WHERE assignmentId=?1 AND status='queued'
                             AND startedAt IS NULL)
                AND NOT EXISTS(SELECT 1 FROM turns WHERE assignmentId=?1
                                 AND status IN ('failed','failed_unknown','running'))
             """,
             [assignment_id]
           ),
         {:ok, [[harness, host]]} <-
           DB.query(db, "SELECT harness,host FROM sessions WHERE sessionKey=?1", [holder_key]) do
      for_host(db, harness, host)
    else
      _ -> nil
    end
  end

  @doc "What releases the hold, in words. Pure: the turn read and the refusal share it."
  @spec release_text(String.t() | nil, String.t() | nil) :: String.t()
  def release_text(nil, _class) do
    "Held by a standing park fence on this harness and host that no open harness-health " <>
      "incident names. The turn starts by itself when that fence lifts."
  end

  def release_text(incident_id, "rate-limit-dead") do
    "Held behind rate-limit incident #{incident_id}. The turn starts by itself when the " <>
      "incident resolves. Recovery is probed on a schedule; an admin can probe now with " <>
      "`#{@retry_command} #{incident_id}`."
  end

  def release_text(incident_id, failure_class) do
    "Held behind #{failure_class} incident #{incident_id}. The turn starts by itself when " <>
      "the incident resolves and the fence lifts."
  end

  defp open_incident(db, harness, host) do
    case DB.query(
           db,
           """
           SELECT id,failureClass FROM harness_health_incidents
           WHERE harness=?1 AND host=?2 AND state='open'
           ORDER BY (failureClass='rate-limit-dead') DESC, openedAt DESC, id DESC LIMIT 1
           """,
           [harness, host]
         ) do
      {:ok, [[id, failure_class]]} -> {id, failure_class}
      _ -> {nil, nil}
    end
  end

  defp opened_by(_db, nil), do: nil

  defp opened_by(db, incident_id) do
    case DB.query(
           db,
           """
           SELECT assignmentId FROM harness_health_observations
           WHERE incidentId=?1 AND assignmentId IS NOT NULL ORDER BY observedAt,id LIMIT 1
           """,
           [incident_id]
         ) do
      {:ok, [[assignment_id]]} -> assignment_id
      _ -> nil
    end
  end
end
