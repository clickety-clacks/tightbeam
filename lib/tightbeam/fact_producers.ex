defmodule Tightbeam.FactProducers do
  @moduledoc "Demand for condition facts and renewable producer claims."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS fact_producer_claims (
    producer TEXT PRIMARY KEY,
    kinds TEXT NOT NULL,
    liveUntil INTEGER NOT NULL
  );
  """

  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  def demand(db \\ DB, prefixes \\ []) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT DISTINCT conditionKind, conditionScope FROM wakes WHERE state='pending' AND conditionKind IS NOT NULL ORDER BY conditionKind, conditionScope"
      )

    demand =
      for [kind, scope] <- rows,
          prefixes == [] or Enum.any?(prefixes, &String.starts_with?(kind, &1)),
          do: %{kind: kind, scope: scope}

    %{demand: demand}
  end

  def claim(db \\ DB, producer, kinds, live_for_ms) do
    cond do
      not is_binary(producer) or String.trim(producer) == "" ->
        %{code: "invalid", message: "--producer requires a nonblank name"}

      not is_list(kinds) or kinds == [] or
          Enum.any?(kinds, &(not is_binary(&1) or String.trim(&1) == "")) ->
        %{code: "invalid", message: "--kind requires one or more nonblank kinds"}

      not is_integer(live_for_ms) or live_for_ms < 1_000 or live_for_ms > 3_600_000 ->
        %{code: "invalid", message: "--live-for must be from 1s to 1h"}

      true ->
        {:ok, result} =
          DB.transaction(db, fn txn ->
            until = System.system_time(:millisecond) + live_for_ms
            kinds = Enum.uniq(kinds)

            Txn.q(
              txn,
              """
              INSERT INTO fact_producer_claims(producer, kinds, liveUntil) VALUES(?1, ?2, ?3)
              ON CONFLICT(producer) DO UPDATE SET kinds=excluded.kinds, liveUntil=excluded.liveUntil
              """,
              [producer, JSON.encode!(kinds), until]
            )

            %{producer: producer, kinds: kinds, liveUntil: until}
          end)

        result
    end
  end

  def list(db \\ DB) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT producer, kinds, liveUntil FROM fact_producer_claims ORDER BY producer"
      )

    now = System.system_time(:millisecond)

    producers =
      for [producer, kinds, until] <- rows,
          do: %{
            producer: producer,
            kinds: JSON.decode!(kinds),
            liveUntil: until,
            live: until > now
          }

    %{producers: producers}
  end

  def served_in_txn?(%Txn{} = txn, kind) do
    now = System.system_time(:millisecond)

    Txn.q(txn, "SELECT kinds FROM fact_producer_claims WHERE liveUntil > ?1", [now])
    |> Enum.any?(fn [encoded] -> kind in JSON.decode!(encoded) end)
  end
end
