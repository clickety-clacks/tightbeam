defmodule Tightbeam.ConditionFacts do
  @moduledoc """
  The append-only stream matched by condition wakes. Facts are literal
  `{kind, scope}` observations; reserved substrate kinds can only be filed by
  `process:tightbeam`.
  """

  alias Tightbeam.{DB, EventLog, Idempotency, Wakes}
  alias Tightbeam.DB.Txn

  @reserved_kinds ~w(quota-recovered escalation-ruled)

  @ddl """
  CREATE TABLE IF NOT EXISTS condition_facts (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    ts     INTEGER NOT NULL,
    kind   TEXT    NOT NULL,
    scope  TEXT,
    origin TEXT    NOT NULL
  );
  CREATE INDEX IF NOT EXISTS condition_facts_match
    ON condition_facts (kind, scope, id);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @spec file(DB.server(), GenServer.server(), map()) :: map() | {:error, map()}
  def file(db, scheduler, input) do
    result = transaction!(db, &file_in_txn(&1, input))

    case result do
      %{fact_id: fact_id} -> Wakes.fire_matching(scheduler, fact_id)
      _ -> :ok
    end

    result
  end

  @spec file_in_txn(Txn.t(), map()) :: map() | {:error, map()}
  def file_in_txn(%Txn{} = txn, input) do
    kind = Map.fetch!(input, :kind)
    origin = Map.fetch!(input, :origin)

    if reserved_ok?(kind, origin) do
      ts = System.system_time(:millisecond)
      scope = Map.get(input, :scope)

      Txn.q(
        txn,
        "INSERT INTO condition_facts (ts, kind, scope, origin) VALUES (?1, ?2, ?3, ?4)",
        [ts, kind, scope, origin]
      )

      [[fact_id]] = Txn.q(txn, "SELECT last_insert_rowid()")

      EventLog.lifecycle_in_txn(
        txn,
        "condition_fact_filed",
        to_string(fact_id),
        "kind=#{kind} scope=#{scope || "nil"} by=#{origin}"
      )

      %{fact_id: fact_id, ts: ts, kind: kind, scope: scope, origin: origin}
    else
      {:error, %{code: "reserved_kind", message: "condition kind is reserved: #{kind}"}}
    end
  end

  @spec file_idempotent(DB.server(), GenServer.server(), map()) :: map() | {:error, map()}
  def file_idempotent(db, scheduler, input) do
    {result, filed?} =
      transaction!(db, fn txn ->
        key = Map.get(input, :idempotency_key)
        origin = Map.fetch!(input, :origin)

        prior =
          if is_binary(key), do: Idempotency.get_in_txn(txn, origin, "condition", key)

        if prior do
          {fact_in_txn(txn, prior.session_key), false}
        else
          case file_in_txn(txn, input) do
            %{fact_id: fact_id} = fact ->
              if is_binary(key) do
                Idempotency.put_in_txn(txn, %{
                  owner_user_id: origin,
                  operation: "condition",
                  idempotency_key: key,
                  session_key: to_string(fact_id)
                })
              end

              {fact, true}

            error ->
              {error, false}
          end
        end
      end)

    if filed?, do: Wakes.fire_matching(scheduler, result.fact_id)
    result
  end

  @spec latest(DB.server(), String.t(), String.t() | nil) :: map() | nil
  def latest(db, kind, scope \\ nil) do
    {sql, params} =
      if is_nil(scope) do
        {"SELECT id, ts, kind, scope, origin FROM condition_facts WHERE kind = ?1 ORDER BY id DESC LIMIT 1",
         [kind]}
      else
        {"SELECT id, ts, kind, scope, origin FROM condition_facts INDEXED BY condition_facts_match WHERE kind = ?1 AND scope = ?2 ORDER BY id DESC LIMIT 1",
         [kind, scope]}
      end

    case DB.query(db, sql, params) do
      {:ok, [[id, ts, fact_kind, fact_scope, origin]]} ->
        %{id: id, ts: ts, kind: fact_kind, scope: fact_scope, origin: origin}

      {:ok, []} ->
        nil
    end
  end

  defp fact_in_txn(txn, fact_id) do
    case Txn.q(txn, "SELECT id, ts, kind, scope, origin FROM condition_facts WHERE id = ?1", [
           fact_id
         ]) do
      [[id, ts, kind, scope, origin]] ->
        %{fact_id: id, ts: ts, kind: kind, scope: scope, origin: origin}

      [] ->
        nil
    end
  end

  defp reserved_ok?(kind, origin),
    do: kind not in @reserved_kinds or origin == "process:tightbeam"

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
