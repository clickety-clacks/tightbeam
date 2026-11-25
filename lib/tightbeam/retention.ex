defmodule Tightbeam.Retention do
  @moduledoc """
  Performs the one-time cleanup of the historical rail_sweep flood.

  All other lifecycle history, including newer rail_sweep events, is retained.

  The walk is paced so other writers keep the database: after each batch it
  waits `pace_factor` times as long as that batch took (at least `min_yield_ms`,
  at most a minute), and batches are small.
  """
  use GenServer

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  require Logger

  @batch 200
  @boot_delay 30_000
  @yield_ms 100
  @pace_factor 4
  @max_pause_ms 60_000
  @retry_ms 3_600_000
  @first_ts DateTime.to_unix(~U[2026-09-19 00:00:00Z], :millisecond)
  @after_last_ts DateTime.to_unix(~U[2026-10-15 00:00:00Z], :millisecond)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :trim, @boot_delay)

    {:ok,
     %{
       db: Keyword.get(opts, :db, DB),
       cursor: 0,
       complete: false,
       batch: Keyword.get(opts, :batch, @batch),
       pace_factor: Keyword.get(opts, :pace_factor, @pace_factor),
       min_yield_ms: Keyword.get(opts, :min_yield_ms, @yield_ms),
       last_pause_ms: nil
     }}
  end

  @impl true
  def handle_info(:trim, %{complete: true} = state), do: {:noreply, state}

  def handle_info(:trim, state) do
    started = System.monotonic_time(:millisecond)

    case trim_batch(state.db, state.cursor, state.batch) do
      {:ok, :complete} ->
        {:noreply, %{state | cursor: 0, complete: true}}

      {:ok, cursor} ->
        elapsed = System.monotonic_time(:millisecond) - started
        pause = pause_ms(elapsed, state.pace_factor, state.min_yield_ms)
        Process.send_after(self(), :trim, pause)
        {:noreply, %{state | cursor: cursor, last_pause_ms: pause}}

      {:error, %DB.Overloaded{}} ->
        Logger.debug("database overloaded; historical cleanup deferred")
        Process.send_after(self(), :trim, 5_000)
        {:noreply, state}

      {:error, error} ->
        Logger.error("historical rail_sweep cleanup failed: #{inspect(error)}")
        Process.send_after(self(), :trim, @retry_ms)
        {:noreply, state}
    end
  end

  @doc false
  # The wait after a batch that held the writer for `elapsed` ms.
  def pause_ms(elapsed, pace_factor, min_yield_ms),
    do: elapsed |> Kernel.*(pace_factor) |> max(min_yield_ms) |> min(@max_pause_ms)

  # Each transaction checks the durable marker before deleting. A crash between
  # batches resumes from the start; completion and the marker are atomic.
  defp trim_batch(db, cursor, batch) do
    DB.transaction(db, fn txn ->
      if Txn.q(txn, "SELECT 1 FROM rail_sweep_cleanup WHERE id = 0") != [] do
        :complete
      else
        rows =
          Txn.q(
            txn,
            "SELECT id FROM lifecycle_events WHERE id > ?1 ORDER BY id LIMIT ?2",
            [cursor, batch]
          )

        case List.last(rows) do
          nil ->
            Txn.q(txn, "INSERT INTO rail_sweep_cleanup (id) VALUES (0)")
            :complete

          [last] ->
            Txn.q(
              txn,
              "DELETE FROM lifecycle_events WHERE id > ?1 AND id <= ?2 " <>
                "AND kind = 'rail_sweep' AND ts >= ?3 AND ts < ?4",
              [cursor, last, @first_ts, @after_last_ts]
            )

            last
        end
      end
    end)
  catch
    :exit, reason -> {:error, reason}
  end
end
