defmodule Tightbeam.SchedulerMisses do
  @moduledoc false
  require Logger

  @limit 20
  @loops [:wake, :recognition, :bubble, :lanes]

  def record(loop, record, late_ms \\ nil) do
    index = loop_index(loop)
    [sequence, _] = :ets.update_counter(__MODULE__, :counts, [{2, 1}, {index, 1}])
    miss = %{loop: loop_name(loop), record_id: record, late_ms: late_ms, at: System.system_time(:millisecond)}
    :ets.insert(__MODULE__, {rem(sequence, @limit), sequence, miss})
    Logger.warning("event miss loop=#{loop} record=#{record} late_ms=#{late_ms || "unknown"}")
    :ok
  end

  def count, do: :ets.lookup_element(__MODULE__, :counts, 2)

  def health do
    [counts] = :ets.lookup(__MODULE__, :counts)
    recent =
      :ets.tab2list(__MODULE__)
      |> Enum.filter(&(tuple_size(&1) == 3))
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.map(&elem(&1, 2))

    %{count: elem(counts, 1), by_loop: Map.new(Enum.with_index(@loops, 2), fn {loop, index} ->
      {loop, elem(counts, index)}
    end), recent: recent}
  end

  def init do
    :ets.new(__MODULE__, [:named_table, :public, :set])
    :ets.insert(__MODULE__, {:counts, 0, 0, 0, 0, 0})
    :ok
  end

  defp loop_name(loop) when loop in [:lane, :lane_terminal], do: :lanes
  defp loop_name(loop), do: loop
  defp loop_index(:wake), do: 3
  defp loop_index(:recognition), do: 4
  defp loop_index(:bubble), do: 5
  defp loop_index(loop) when loop in [:lane, :lane_terminal], do: 6
end
