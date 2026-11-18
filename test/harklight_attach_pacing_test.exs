defmodule Tightbeam.HarklightAttachPacingTest do
  use ExUnit.Case, async: true
  alias Tightbeam.HarklightWakes

  defp scheduler(opts \\ []) do
    Process.put(:pacing_now, 0)

    {:ok, state} =
      HarklightWakes.init(
        [
          now: fn -> Process.get(:pacing_now) end,
          retry_jitter: false,
          attach_spacing_ms: 250,
          slow_attach_spacing_ms: 10_000,
          cooldown_base_ms: 30_000,
          cooldown_max_ms: 300_000
        ] ++ opts
      )

    assert_receive :restore
    state
  end

  defp workers(state, count) do
    workers =
      Map.new(1..count, fn n ->
        pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        on_exit(fn -> send(pid, :stop) end)
        {n, pid}
      end)

    %{state | workers: workers, priorities: Map.new(1..count, &{&1, &1})}
  end

  # Run actual manager callbacks with a virtual monotonic clock. No database,
  # sleeping or timeout observation is needed to drive the deadline timer.
  defp tick(state) do
    if state.attach_gate_timer, do: Process.cancel_timer(elem(state.attach_gate_timer, 0))
    token = make_ref()

    Process.put(
      :pacing_now,
      max(Process.get(:pacing_now), max(state.attach_next_at, state.cooldown_until))
    )

    {:noreply, state} =
      HarklightWakes.handle_info({:attach_gate, token}, %{state | attach_gate_timer: {nil, token}})

    state
  end

  defp outcome(state, pid, result) do
    {:reply, :ok, state} =
      HarklightWakes.handle_call({:attach_result, result}, {pid, make_ref()}, state)

    {:noreply, state} = HarklightWakes.handle_cast({:attach_slot_released, pid}, state)
    state
  end

  test "150 waiting conversations share one deadline and newest-first admission" do
    state = scheduler() |> workers(150)
    waiting = :queue.from_list(for {_, pid} <- state.workers, do: {pid, make_ref()})
    state = tick(%{state | attach_waiting: waiting})
    assert state.attach_slots == MapSet.new([state.workers[150]])
    assert :queue.len(state.attach_waiting) == 149
    assert state.attach_gate_timer != nil
    assert state.attach_next_at == 250
    Process.cancel_timer(elem(state.attach_gate_timer, 0))
  end

  test "slow attaches throttle immediately; quick successes restore brisk admission" do
    state = scheduler() |> workers(2)
    pid = state.workers[1]
    state = %{state | attach_slots: MapSet.new([pid])}

    {:reply, :ok, state} =
      HarklightWakes.handle_call({:attach_result, {:ok, 2400}}, {pid, make_ref()}, state)

    assert state.slow_lane
    assert state.attach_next_at == 10_000

    state =
      Enum.reduce(1..4, state, fn _, state ->
        {:reply, :ok, state} =
          HarklightWakes.handle_call({:attach_result, {:ok, 50}}, {pid, make_ref()}, state)

        state
      end)

    refute state.slow_lane
    assert state.attach_next_at == 250
  end

  test "transport failures cap global probes and rotate away from the previous conversation" do
    state = scheduler() |> workers(150)
    pid = state.workers[150]
    state = %{state | attach_slots: MapSet.new([pid]), probe_times: %{150 => 0}}

    state =
      Enum.reduce(1..20, state, fn _, state ->
        {:reply, :ok, state} =
          HarklightWakes.handle_call({:attach_result, :transport}, {pid, make_ref()}, state)

        state
      end)

    assert state.cooldown_until == 300_000
    assert state.transport_failures == state.failure_threshold + 10
    waiting = :queue.from_list(for {_, pid} <- state.workers, do: {pid, make_ref()})
    state = tick(%{state | attach_slots: MapSet.new(), attach_waiting: waiting})
    assert state.attach_slots == MapSet.new([state.workers[149]])
    assert state.attach_gate_timer == nil
    state = outcome(state, state.workers[149], {:ok, 50})
    assert state.transport_failures == 0
    assert state.cooldown_until == Process.get(:pacing_now)
    if state.attach_gate_timer, do: Process.cancel_timer(elem(state.attach_gate_timer, 0))
  end

  test "a shared outage across 150 conversations converges to one probe per five minutes" do
    state = scheduler() |> workers(150)
    waiting = :queue.from_list(for {_, pid} <- state.workers, do: {pid, make_ref()})

    {state, probes} =
      Enum.reduce(1..150, {%{state | attach_waiting: waiting}, []}, fn _, {state, probes} ->
        state = tick(state)
        [pid] = MapSet.to_list(state.attach_slots)
        at = Process.get(:pacing_now)
        {outcome(state, pid, :transport), [{pid, at} | probes]}
      end)

    probes = Enum.reverse(probes)
    assert length(Enum.uniq_by(probes, &elem(&1, 0))) == 150
    assert Enum.take(Enum.map(probes, &elem(&1, 1)), 5) == [0, 10_000, 20_000, 30_000, 60_000]

    assert probes
           |> Enum.drop(8)
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [{_, a}, {_, b}] -> b - a == 300_000 end)

    assert state.transport_failures == state.failure_threshold + 10
    assert :queue.is_empty(state.attach_waiting)
    assert state.attach_gate_timer == nil
  end

  test "a nontransport refusal cannot trip the shared cooldown" do
    state = scheduler() |> workers(1)
    pid = state.workers[1]
    state = %{state | attach_slots: MapSet.new([pid])}

    {:reply, :ok, after_refusal} =
      HarklightWakes.handle_call({:attach_result, :other}, {pid, make_ref()}, state)

    assert after_refusal == state
  end

  defp restore_time(latency) do
    state = scheduler() |> workers(100)
    waiting = :queue.from_list(for {_, pid} <- state.workers, do: {pid, {:decision, make_ref()}})
    state = %{state | attach_waiting: waiting}
    restore_steps(state, Map.new(state.workers, fn {_, pid} -> {pid, :decision} end), latency, 0)
  end

  defp restore_steps(state, _stages, _latency, 100) do
    assert :queue.is_empty(state.attach_waiting)
    assert MapSet.size(state.attach_slots) == 0
    if state.attach_gate_timer, do: Process.cancel_timer(elem(state.attach_gate_timer, 0))
    Process.get(:pacing_now)
  end

  defp restore_steps(state, stages, latency, complete) do
    state = if MapSet.size(state.attach_slots) == 0, do: tick(state), else: state
    [pid] = MapSet.to_list(state.attach_slots)

    case stages[pid] do
      :decision ->
        Process.put(:pacing_now, Process.get(:pacing_now) + 20)
        {:noreply, state} = HarklightWakes.handle_cast({:attach_slot_released, pid}, state)
        {:noreply, state} = HarklightWakes.handle_cast({:attach_slot, pid, make_ref()}, state)
        restore_steps(state, Map.put(stages, pid, :attach), latency, complete)

      :attach ->
        Process.put(:pacing_now, Process.get(:pacing_now) + latency)
        state = outcome(state, pid, {:ok, latency})
        restore_steps(state, stages, latency, complete + 1)
    end
  end

  test "100-conversation restore is brisk on a healthy server and paced on a slow one" do
    # Includes one 20ms lifecycle check per conversation, and either a 50ms
    # unchanged attach or a 2400ms save-per-attach response. These are modeled
    # service times; this checks the real scheduler, not server throughput.
    assert restore_time(50) == 54_750
    assert restore_time(2400) == 2_220_250
  end
end
