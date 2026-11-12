defmodule Tightbeam.EffortCheckin do
  @moduledoc """
  Compatibility for decision requests and wake rows created by older releases.

  The historical generation table remains available for upgrades, but current
  code does not arm, inspect, expire, or otherwise act on its rows.
  """

  alias Tightbeam.{DB, Wakes}
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS effort_checkin_generations (
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    generation INTEGER NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('armed','probed','canceled')),
    baseHorizonMs INTEGER NOT NULL,
    multiplier INTEGER NOT NULL CHECK (multiplier IN (1,2,4)),
    armedAt INTEGER NOT NULL,
    terminalSeqWatermark INTEGER NOT NULL,
    holderKey TEXT NOT NULL,
    host TEXT NOT NULL,
    root TEXT NOT NULL,
    baseline TEXT NOT NULL,
    wakeId TEXT NOT NULL,
    evidence TEXT,
    agentProdded INTEGER NOT NULL DEFAULT 0,
    artifactWatermark INTEGER NOT NULL DEFAULT 0,
    attestWatermark INTEGER NOT NULL DEFAULT 0,
    workItemWatermark INTEGER NOT NULL DEFAULT 0,
    reliefStartedAt INTEGER,
    reliefExcludedMs INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (assignmentId, generation)
  );
  CREATE INDEX IF NOT EXISTS effort_checkin_wake
    ON effort_checkin_generations (wakeId, state);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    # Keep historical rows intact for upgrade compatibility.
    DB.execute(db, @ddl)
  end

  @doc false
  @spec ignore_retired_wake(DB.server(), Wakes.wake()) :: {:ok, atom()}
  def ignore_retired_wake(db, wake) do
    command = %{
      requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
      reason_kind: "consumer_unavailable",
      causal_source: %{kind: "scheduler_delivery", id: wake.wake_id},
      outcome: %{kind: "no_replacement"},
      wake_id: wake.wake_id
    }

    case DB.transaction(db, fn txn ->
           if Wakes.cancel_in_txn(txn, command) do
             :canceled
           else
             case Txn.q(txn, "SELECT state FROM wakes WHERE wakeId=?1", [wake.wake_id]) do
               [["pending"]] -> raise "retired effort wake could not be canceled"
               _ -> :already_settled
             end
           end
         end) do
      {:ok, outcome} -> {:ok, outcome}
      {:error, error} -> raise error
    end
  end
end
