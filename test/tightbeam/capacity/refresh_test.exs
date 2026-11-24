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
