defmodule Tightbeam.Capacity.RefreshTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Capacity.{Observation, Refresh}

  @account "acct_one"
  @now 1_800_000_000_000

  test "concurrent wait and background reads share one collection" do
    test = self()
    supervisor = start_supervised!(Task.Supervisor)
    sample = %{observed_at: @now - 60_000}

    refresh =
      start_supervised!(
        {Refresh,
         task_supervisor: supervisor,
         now: fn -> @now end,
         entry: fn _ ->
           send(test, :entry_read)
           %{Observation.empty() | sample: sample}
         end,
         collect: fn id, started ->
           send(test, {:started, self(), id, started})

           receive do
             :finish -> {:ok, %{Observation.empty() | sample: %{observed_at: @now}}}
           end
         end}
      )

    assert %{status: "stale", sample: ^sample} = Refresh.read(refresh, @account, :background)
    assert_receive {:started, worker, @account, @now}
    assert_receive :entry_read
    assert %{status: "stale", sample: ^sample} = Refresh.read(refresh, @account, :background)
    assert_receive :entry_read
    wait = Task.async(fn -> Refresh.read(refresh, @account, :wait) end)
    assert_receive :entry_read
    refute_receive {:started, _, _, _}

    send(worker, :finish)
    assert %{status: "live", sample: %{observed_at: @now}} = Task.await(wait)
  end

  test "a profile hold saves usage and suppresses the next forced collection" do
    supervisor = start_supervised!(Task.Supervisor)

    sample = %{
      observed_at: @now,
      plan: "max",
      windows: [%{id: "five_hour", used_percent: 42}],
      profile_hold: %{code: "UPSTREAM_RATE_LIMITED", retry_after_seconds: 3600}
    }

    entry = Observation.record(Observation.empty(), {:ok, sample}, @now - 10, @now)

    assert entry.retry_at == @now + :timer.hours(1)
    refute Map.has_key?(entry.sample, :profile_hold)

    refresh =
      start_supervised!(
        {Refresh,
         task_supervisor: supervisor,
         now: fn -> @now + 1 end,
         entry: fn _ -> entry end,
         collect: fn _, _ -> flunk("profile hold must suppress provider work") end}
      )

    assert %{status: "cache", sample: %{windows: [%{used_percent: 42}]}, error: nil} =
             Refresh.read(refresh, @account, :wait)
  end

  test "tracking accounts arms one due refresh and respects a future hold" do
    test = self()
    supervisor = start_supervised!(Task.Supervisor)
    held = "acct_held"

    refresh =
      start_supervised!(
        {Refresh,
         task_supervisor: supervisor,
         now: fn -> @now end,
         entry: fn
           ^held -> %{Observation.empty() | retry_at: @now + 60_000}
           _ -> Observation.empty()
         end,
         collect: fn id, at ->
           send(test, {:scheduled, id})
           {:ok, %{Observation.empty() | attempted_at: at}}
         end}
      )

    Refresh.track(refresh, [held, @account])
    assert_receive {:scheduled, @account}
    refute_receive {:scheduled, _}
  end

  test "forced read under a rate-limit hold retains the previous observation" do
    supervisor = start_supervised!(Task.Supervisor)
    sample = %{observed_at: @now - 60_000}
    error = %{code: "UPSTREAM_RATE_LIMITED"}
    entry = %{Observation.empty() | sample: sample, error: error, retry_at: @now + 60_000}

    refresh =
      start_supervised!(
        {Refresh,
         task_supervisor: supervisor,
         now: fn -> @now end,
         entry: fn _ -> entry end,
         collect: fn _, _ -> flunk("rate-limited read must never invoke a probe") end}
      )

    assert %{status: "stale", sample: ^sample, error: ^error} =
             Refresh.read(refresh, @account, :wait)
  end
end
