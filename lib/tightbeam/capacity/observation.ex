defmodule Tightbeam.Capacity.Observation do
  @moduledoc false

  alias Tightbeam.Capacity.{History, ReadPolicy}

  @max_sqlite_integer 9_223_372_036_854_775_807
  @stale_after :timer.minutes(30)

  def empty do
    %{sample: nil, error: nil, attempted_at: nil, completed_at: nil, retry_at: nil, history: []}
  end

  def record(current, outcome, attempted_at, received_at) do
    if current.attempted_at != nil and attempted_at < current.attempted_at do
      :superseded
    else
      apply_outcome(current, outcome, attempted_at, received_at)
    end
  end

  defp apply_outcome(current, {:ok, sample}, attempted_at, received_at) do
    {profile_hold, sample} = Map.pop(sample, :profile_hold)
    windows = Enum.map(sample.windows, &resolve_reset(&1, received_at))
    sample = %{sample | observed_at: received_at, windows: windows}

    history =
      History.retain(
        current.history ++ [Map.take(sample, [:plan, :observed_at, :windows])],
        received_at
      )

    %{
      current
      | sample: sample,
        error: nil,
        attempted_at: attempted_at,
        completed_at: received_at,
        retry_at: ReadPolicy.retry_at(profile_hold, received_at),
        history: history
    }
  end

  defp apply_outcome(current, {:error, error}, attempted_at, received_at) do
    retry_at = ReadPolicy.retry_at(error, received_at) || current.retry_at

    %{
      current
      | error: error,
        attempted_at: attempted_at,
        completed_at: received_at,
        retry_at: retry_at,
        history: History.retain(current.history, received_at)
    }
  end

  defp resolve_reset(window, received_at) do
    case Map.pop(window, :reset_after_seconds) do
      {nil, window} ->
        window

      {delay, window} ->
        reset_at = received_at + delay * 1000
        Map.put(window, :resets_at, min(reset_at, @max_sqlite_integer))
    end
  end

  def fresh?(%{error: nil, sample: %{observed_at: observed}}, now),
    do: now - observed <= @stale_after

  def fresh?(_, _), do: false
end
