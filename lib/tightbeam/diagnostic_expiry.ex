defmodule Tightbeam.DiagnosticExpiry do
  @moduledoc """
  Expires a small allowlist of diagnostic lifecycle events. The scan uses
  the existing row ID order and snapshots an upper bound for each pass.
  """

  use GenServer
  require Logger

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @day_ms 86_400_000
  @retention_ms 30 * @day_ms
  @batch_size 50
  @yield_ms 100
  @retry_ms 30_000
  @deadline_ms 50

  def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :db))

  def enabled?, do: Application.get_env(:tightbeam, :diagnostic_expiry, false)

  @impl true
  def init(db) do
    Process.send_after(self(), :expire, @retry_ms)
    {:ok, %{db: db, pass: nil}}
  end

  @impl true
  def handle_info(:expire, state) do
    {cursor, ceiling, cutoff} =
      state.pass || {0, nil, System.system_time(:millisecond) - @retention_ms}

    case expire_batch(state.db, cursor, ceiling, cutoff) do
      {:ok, {:done, _removed}} ->
        Process.send_after(self(), :expire, @day_ms)
        {:noreply, %{state | pass: nil}}

      {:ok, {:more, last, upper, _removed}} ->
        Process.send_after(self(), :expire, @yield_ms)
        {:noreply, %{state | pass: {last, upper, cutoff}}}

      {:error, error} ->
        Logger.warning("diagnostic expiry batch deferred: #{inspect(error)}")
        Process.send_after(self(), :expire, @retry_ms)
        {:noreply, %{state | pass: {cursor, ceiling, cutoff}}}
    end
  end

  @doc false
  def expire_batch(db, cursor, ceiling, cutoff) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms

    DB.transaction_until(
      db,
      fn txn ->
        [[upper]] =
          if ceiling == nil do
            Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM lifecycle_events")
          else
            [[ceiling]]
          end

        rows =
          Txn.q(
            txn,
            "SELECT id FROM lifecycle_events WHERE id > ?1 AND id <= ?2 ORDER BY id LIMIT ?3",
            [cursor, upper, @batch_size]
          )

        case List.last(rows) do
          nil ->
            {:done, 0}

          [last] ->
            Txn.q(
              txn,
              """
              DELETE FROM lifecycle_events
              WHERE id > ?1 AND id <= ?2 AND ts < ?3
                AND kind IN ('rule_effect_failed', 'rule_notice_failed', 'rail_episode_writer_unavailable')
              """,
              [cursor, last, cutoff]
            )

            removed = Txn.changes(txn)
            if last == upper, do: {:done, removed}, else: {:more, last, upper, removed}
        end
      end,
      deadline
    )
  end
end
