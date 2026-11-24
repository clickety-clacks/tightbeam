defmodule Tightbeam.Capacity.ObservationTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Capacity.{Observation, ReadPolicy}

  @now 1_800_000_000_000

  test "gateway receipt timestamps the sample and a failure retains its history" do
    sample = %{observed_at: 999, plan: "plus", windows: [%{id: "primary", used_percent: 70}]}
    first = Observation.record(Observation.empty(), {:ok, sample}, @now - 42, @now)

    assert first.sample.observed_at == @now
    assert first.attempted_at == @now - 42
    assert [%{observed_at: @now}] = first.history
    assert Observation.fresh?(first, @now)

    hold = %{code: "UPSTREAM_RATE_LIMITED", retry_after_seconds: 1200}
    held = Observation.record(first, {:error, hold}, @now + 500, @now + 1000)

    assert held.sample == first.sample
    assert held.history == first.history
    assert held.error == hold
    assert held.retry_at == @now + 1_201_000
    assert ReadPolicy.action(held, :wait, @now + 2_000) == :held
    refute Observation.fresh?(held, @now + 1000)
    assert Observation.record(held, {:ok, sample}, @now - 42, @now + 750) == :superseded
  end
end
