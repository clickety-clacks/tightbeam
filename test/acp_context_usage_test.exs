defmodule Tightbeam.Acp.ContextUsageTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Acp.{Adapter, ContextUsage}
  alias Tightbeam.Model

  test "a reported context observation is not an authoritative submission allowance" do
    model = Model.new("gpt-5.6-sol")
    update = %{"sessionUpdate" => "usage_update", "used" => 3000, "size" => 10000}
    {:noreply, state} = receive_update(%Adapter{harness: :codex, models: %{"s" => model}}, "s", update)

    assert {:reply, {:ok, usage}, ^state} = Adapter.handle_call({:context_usage, "s", 1000}, nil, state)
    assert usage.used == 3000
    assert usage.size == 10000
    assert usage.model == model
    assert usage.authority == :reported_context_usage
    refute Map.has_key?(usage, :available_input_tokens)
    refute Map.has_key?(usage, :max_prompt_bytes)
  end

  test "an invalid replacement observation cannot expose the previous larger allowance" do
    model = Model.new("gpt-5.6-sol")
    state = %Adapter{harness: :codex, models: %{"s" => model}}
    {:noreply, state} = receive_update(state, "s", %{"sessionUpdate" => "usage_update", "used" => 10, "size" => 10000})

    for {used, size} <- [{nil, 10000}, {1, nil}, {-1, 10000}, {10001, 10000}, {0, 0}, {1.5, 10000}] do
      {:noreply, invalid} = receive_update(state, "s", %{"sessionUpdate" => "usage_update", "used" => used, "size" => size})
      assert {:reply, {:error, :invalid_context_usage}, ^invalid} =
               Adapter.handle_call({:context_usage, "s", 1000}, nil, invalid)
    end
  end

  test "session identity, an in-flight turn and adapter restart cannot borrow another snapshot" do
    model = Model.new("gpt-5.6-sol")
    {:ok, observation} = ContextUsage.observe(%{"used" => 10, "size" => 10000}, model, 100)
    state = %Adapter{models: %{"s" => model}, context_usage: %{"s" => {:ok, observation}}}

    assert {:reply, {:error, :context_usage_unavailable}, ^state} =
             Adapter.handle_call({:context_usage, "other", 1000}, nil, state)

    active = %{state | prompts: %{"s" => %{}}}
    assert {:reply, {:error, :context_usage_in_flight}, ^active} =
             Adapter.handle_call({:context_usage, "s", 1000}, nil, active)

    restarted = %Adapter{models: %{"s" => model}}
    assert {:reply, {:error, :context_usage_unavailable}, ^restarted} =
             Adapter.handle_call({:context_usage, "s", 1000}, nil, restarted)
  end

  test "freshness includes the exact model context and rejects future observations" do
    model = Model.new("gpt-5.6-sol")
    observation = ContextUsage.observe(%{"used" => 10, "size" => 10000}, model, 100)

    assert {:ok, _} = ContextUsage.read(observation, model, 200, 100)
    assert {:error, :stale_context_usage} = ContextUsage.read(observation, model, 201, 100)
    assert {:error, :stale_context_usage} = ContextUsage.read(observation, model, 99, 100)
    assert {:error, :stale_context_usage} =
             ContextUsage.read(observation, %{model | context: "1m"}, 200, 100)
    assert {:error, :invalid_context_usage_age} = ContextUsage.read(observation, model, 200, -1)
  end

  test "model readback changing away and back does not revive old usage" do
    model = Model.new("gpt-5.6-sol")
    state = %Adapter{harness: :codex, preset: %{effort_config: "reasoning_effort"}, models: %{"s" => model}}
    {:noreply, state} = receive_update(state, "s", %{"sessionUpdate" => "usage_update", "used" => 10, "size" => 10000})

    for next_model <- ["gpt-other", "gpt-5.6-sol"], reduce: state do
      state ->
        {:noreply, state} = receive_update(state, "s", %{
          "sessionUpdate" => "config_option_update",
          "configOptions" => [%{"id" => "model", "currentValue" => next_model}]
        })

        assert {:reply, {:error, :context_usage_unavailable}, ^state} =
                 Adapter.handle_call({:context_usage, "s", 1000}, nil, state)
        state
    end
  end

  defp receive_update(state, sid, update),
    do: Adapter.handle_info({:acp_notification, "session/update", %{"sessionId" => sid, "update" => update}}, state)
end
