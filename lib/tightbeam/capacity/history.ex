defmodule Tightbeam.Capacity.History do
  @moduledoc """
  Seven days of normalized observations, compacted into five-minute buckets.
  Reset boundaries and usage declines survive compaction.
  """

  @bucket_ms :timer.minutes(5)
  @retention_ms :timer.hours(7 * 24)
  @max_samples 2048

  def retain(samples, now) do
    samples
    |> Enum.filter(&(&1.observed_at >= now - @retention_ms))
    |> Enum.sort_by(& &1.observed_at)
    |> Enum.reduce([], &compact/2)
    |> Enum.take(@max_samples)
    |> Enum.reverse()
  end

  def same_reset?(%{resets_at: nil}, %{resets_at: nil}), do: true

  def same_reset?(%{resets_at: a, window_seconds: duration}, %{resets_at: b})
      when is_integer(a) and is_integer(b) do
    tolerance =
      if is_integer(duration) and duration > 0 do
        min(max(60_000, duration * 10), duration * 250)
      else
        60_000
      end

    abs(a - b) <= tolerance
  end

  def same_reset?(_, _), do: false

  def declined?(previous, current), do: current.used_percent + 0.000001 < previous.used_percent

  defp compact(sample, [last | earlier] = acc) do
    if same_bucket_and_generation?(last, sample) do
      bucket = Enum.take_while(acc, &same_bucket_and_generation?(&1, sample))

      boundary? =
        any_decline?(last, sample) or
          Enum.any?(Enum.chunk_every(bucket, 2, 1, :discard), fn [newer, older] ->
            any_decline?(older, newer)
          end)

      if boundary? and length(bucket) < 3 do
        [sample | acc]
      else
        [sample | earlier]
      end
    else
      [sample | acc]
    end
  end

  defp compact(sample, []), do: [sample]

  defp same_bucket_and_generation?(a, b) do
    div(a.observed_at, @bucket_ms) == div(b.observed_at, @bucket_ms) and
      a.plan == b.plan and
      length(a.windows) == length(b.windows) and
      Enum.all?(a.windows, fn left ->
        Enum.any?(b.windows, &(same_window?(left, &1) and same_reset?(left, &1)))
      end)
  end

  defp any_decline?(a, b) do
    Enum.any?(a.windows, fn left ->
      Enum.any?(b.windows, &(same_window?(left, &1) and declined?(left, &1)))
    end)
  end

  defp same_window?(a, b), do: a.id == b.id and a.window_seconds == b.window_seconds
end
