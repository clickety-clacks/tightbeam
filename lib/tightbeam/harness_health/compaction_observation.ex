defmodule Tightbeam.HarnessHealth.CompactionObservation do
  @moduledoc false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS harness_compaction_observations (
    attemptKey TEXT PRIMARY KEY,
    harness TEXT NOT NULL,
    host TEXT NOT NULL,
    model TEXT NOT NULL,
    failureClass TEXT NOT NULL,
    observedAt INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS harness_compaction_observations_route
    ON harness_compaction_observations(harness,host,observedAt DESC);
  """

  def ensure_schema(db), do: DB.execute(db, @ddl)

  def record(db, attempt, harness, host, model, failure, observed_at) do
    {:ok, status} =
      DB.transaction(db, fn txn ->
        case Txn.q(
               txn,
               """
               INSERT INTO harness_compaction_observations
                 (attemptKey,harness,host,model,failureClass,observedAt)
               VALUES (?1,?2,?3,?4,?5,?6)
               ON CONFLICT(attemptKey) DO NOTHING
               RETURNING attemptKey
               """,
               [attempt, harness, host, model, failure, observed_at]
             ) do
          [[^attempt]] -> "recorded"
          [] -> "duplicate"
        end
      end)

    %{status: status, attempt_key: attempt, failure_class: failure}
  end

  def recent(db, harness, host, earliest) do
    case DB.query(
           db,
           """
           SELECT attemptKey,model,failureClass,observedAt
           FROM harness_compaction_observations
           WHERE harness=?1 AND host=?2 AND observedAt>=?3
           ORDER BY observedAt DESC,attemptKey DESC LIMIT 1
           """,
           [harness, host, earliest]
         ) do
      {:ok, [[attempt, model, failure, observed_at]]} ->
        %{
          type: "recent_compactor_failure",
          attempt_key: attempt,
          model: model,
          failure_class: failure,
          since: observed_at
        }

      {:ok, []} ->
        nil
    end
  end
end
