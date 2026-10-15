defmodule Tightbeam.SchedulerMisses do
  @moduledoc false
  require Logger

  def record(loop, record) do
    :counters.add(counter(), 1, 1)
    Logger.warning("event miss loop=#{loop} record=#{record}")
    :ok
  end

  def count, do: :counters.get(counter(), 1)

  def init do
    :persistent_term.put(__MODULE__, :counters.new(1, [:write_concurrency]))
    :ok
  end

  defp counter, do: :persistent_term.get(__MODULE__)
end
