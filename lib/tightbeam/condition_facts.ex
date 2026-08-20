defmodule Tightbeam.ConditionFacts do
  @moduledoc """
  The append-only stream matched by condition wakes, and the WORKING MEMORY of
  the production machine (spec production-machine-v1). Facts are literal
  `{kind, scope}` occurrences; STANDING state is derived from the stream —
  latest of an assert/retract pair — never stored as a mutable flag, so the
  provenance of every assertion and retraction survives by construction.

  The kind rule runs in both directions, enforced here rather than at the
  verb seam because the substrate does not file facts through a verb:
  reserved substrate kinds can only be filed by `process:tightbeam`, and
  agent-only kinds can be filed by anyone EXCEPT `process:tightbeam` — the
  substrate is forbidden to assert an agent's judgment.
  """

  alias Tightbeam.{DB, EventLog, Idempotency, PatrolResponse, Wakes}
  alias Tightbeam.DB.Txn

  @reserved_kinds ~w(quota-recovered escalation-ruled user-alerted user-alert-cleared credential-present)
  @agent_only_kinds ~w(work-blocked work-unblocked)

  @standing_pairs %{
    "work-blocked" => "work-unblocked",
    "user-alerted" => "user-alert-cleared"
  }

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

    case kind_authority(kind, origin) do
      :ok -> file_admitted_in_txn(txn, kind, origin, input)
      {:error, _} = error -> error
    end
  end

  defp file_admitted_in_txn(txn, kind, origin, input) do
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

    fact = %{fact_id: fact_id, ts: ts, kind: kind, scope: scope, origin: origin}
    :ok = PatrolResponse.recognize_block_in_txn(txn, fact)
    fact
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

  @doc """
  Whether the assert kind of a standing pair currently STANDS for `scope`:
  the latest fact of either kind in the pair is the assert. Derived, never
  stored — the stream keeps every assertion and retraction, and this is the
  one honest way to ask "is it true right now" (spec production-machine-v1).

  Raises on a kind with no declared retract pair: standing-ness is only
  defined for kinds designed as pairs, and asking it of an occurrence kind
  is a category error, not an empty answer.
  """
  @spec standing?(DB.server(), String.t(), String.t()) :: boolean()
  def standing?(db, assert_kind, scope) do
    retract_kind = Map.fetch!(@standing_pairs, assert_kind)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT kind FROM condition_facts INDEXED BY condition_facts_match
        WHERE kind IN (?1, ?2) AND scope = ?3
        ORDER BY id DESC LIMIT 1
        """,
        [assert_kind, retract_kind, scope]
      )

    match?([[^assert_kind]], rows)
  end

  @doc "standing?/3 inside the caller's transaction — for act-time recognition."
  @spec standing_in_txn?(Txn.t(), String.t(), String.t()) :: boolean()
  def standing_in_txn?(%Txn{} = txn, assert_kind, scope) do
    retract_kind = Map.fetch!(@standing_pairs, assert_kind)

    rows =
      Txn.q(
        txn,
        """
        SELECT kind FROM condition_facts
        WHERE kind IN (?1, ?2) AND scope = ?3
        ORDER BY id DESC LIMIT 1
        """,
        [assert_kind, retract_kind, scope]
      )

    match?([[^assert_kind]], rows)
  end

  @doc """
  Whether ANY fact of `kind` has ever been filed. The cheap existence guard
  in front of per-row standing checks on hot paths (every delivered turn asks
  about `user-alerted`; almost every database has never filed one).
  """
  @spec any?(DB.server(), String.t()) :: boolean()
  def any?(db, kind) do
    {:ok, rows} = DB.query(db, "SELECT 1 FROM condition_facts WHERE kind = ?1 LIMIT 1", [kind])
    rows != []
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

  # Both directions of the kind rule (spec production-machine-v1 §Standing
  # facts). Reserved kinds are the substrate's own observations; agent-only
  # kinds are an agent's judgment, which the substrate is forbidden to assert
  # — a substrate that files `work-blocked` has decided something.
  defp kind_authority(kind, origin) do
    reserved? = kind in @reserved_kinds or String.starts_with?(kind, "subagent_")

    cond do
      reserved? and origin != "process:tightbeam" ->
        {:error, %{code: "reserved_kind", message: "condition kind is reserved: #{kind}"}}

      kind in @agent_only_kinds and origin == "process:tightbeam" ->
        {:error,
         %{
           code: "agent_only_kind",
           message: "condition kind is an agent judgment the substrate may not assert: #{kind}"
         }}

      true ->
        :ok
    end
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
