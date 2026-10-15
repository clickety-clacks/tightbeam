defmodule Tightbeam.SchedulerMisses do
  @moduledoc false
  require Logger

  def record(loop, record) do
    :counters.add(counter(), 1, 1)
    Logger.warning("event miss loop=#{loop} record=#{record}")
    :ok
  end

  def count, do: :counters.get(counter(), 1)

  defp counter do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        :global.trans({__MODULE__, self()}, fn ->
          case :persistent_term.get(__MODULE__, nil) do
            nil ->
              counter = :counters.new(1, [:write_concurrency])
              :persistent_term.put(__MODULE__, counter)
              counter

            counter ->
              counter
          end
        end)

      counter ->
        counter
    end
  end
end
