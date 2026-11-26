defmodule Tightbeam.Capacity.ReadPolicy do
  @moduledoc false

  @cache_ms :timer.seconds(30)
  @cadence_ms :timer.minutes(15)
  @max_timestamp 9_223_372_036_854_775_807

  def retry_at(%{code: "UPSTREAM_RATE_LIMITED", retry_after_seconds: delay}, received_at),
    do: min(received_at + delay * 1000, @max_timestamp)

  def retry_at(_, _), do: nil

  def due_at(%{attempted_at: nil, retry_at: nil}, now), do: now
  def due_at(%{attempted_at: nil, retry_at: hold}, _now), do: hold

  def due_at(%{attempted_at: attempted, retry_at: hold}, _now),
    do: max(attempted + @cadence_ms, hold || attempted)

  def action(%{retry_at: retry_at}, _mode, now) when is_integer(retry_at) and retry_at > now,
    do: :held

  def action(_, :snapshot, _now), do: :snapshot
  def action(_, :wait, _now), do: :wait
  def action(%{sample: nil}, :background, _now), do: :wait

  def action(%{sample: sample}, :background, now) do
    if cache_fresh?(sample, now), do: :snapshot, else: :background
  end

  def cache_fresh?(%{observed_at: observed}, now), do: now - observed <= @cache_ms
  def cache_fresh?(nil, _), do: false

  def result(account_id, sample, error, source) do
    status =
      cond do
        is_nil(sample) -> "error"
        error != nil or source == :retained -> "stale"
        source == :refreshed -> "live"
        true -> "cache"
      end

    %{account_id: account_id, status: status, sample: sample, error: error}
  end
end
