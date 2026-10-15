defmodule Tightbeam.Retention do
  @moduledoc """
  Deletes expired lifecycle events after boot, yielding between bounded batches.
  Configure `:retention_days` with `TIGHTBEAM_RETENTION_DAYS`, default 60.
  """
  use GenServer

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  require Logger

  @day_ms 86_400_000
  @batch 2_000
  @boot_delay 30_000
  @yield_ms 100
  @interval 3_600_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    days = Application.get_env(:tightbeam, :retention_days, 60)

    days =
      if is_integer(days) and days > 0 do
        days
      else
        Logger.error("invalid retention_days #{inspect(days)}; using 60 days")
        60
      end

    Process.send_after(self(), :trim, @boot_delay)
    {:ok, %{db: Keyword.get(opts, :db, DB), days: days, cursor: 0, cutoff: nil}}
  end

  @impl true
  def handle_info(:trim, state) do
    cutoff = state.cutoff || System.system_time(:millisecond) - state.days * @day_ms

    case trim_batch(state.db, state.cursor, cutoff) do
      {:ok, nil} ->
        Process.send_after(self(), :trim, @interval)
        {:noreply, %{state | cursor: 0, cutoff: nil}}

      {:ok, cursor} ->
        Process.send_after(self(), :trim, @yield_ms)
        {:noreply, %{state | cursor: cursor, cutoff: cutoff}}

      {:error, error} ->
        Logger.error("lifecycle retention failed: #{inspect(error)}")
        Process.send_after(self(), :trim, @interval)
        {:noreply, state}
    end
  end

  # Scan by primary key so even a table with no expired rows has bounded work.
  # Recheck timestamps in the delete, including when timestamps are out of order.
  defp trim_batch(db, cursor, cutoff) do
    DB.transaction(db, fn txn ->
      rows =
        Txn.q(
          txn,
          "SELECT id FROM lifecycle_events WHERE id > ?1 ORDER BY id LIMIT ?2",
          [cursor, @batch]
        )

      case List.last(rows) do
        nil ->
          nil

        [last] ->
          Txn.q(
            txn,
            "DELETE FROM lifecycle_events WHERE id > ?1 AND id <= ?2 AND ts < ?3",
            [cursor, last, cutoff]
          )

          last
      end
    end)
  catch
    :exit, reason -> {:error, reason}
  end
end
