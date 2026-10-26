defmodule Tightbeam.Acp.ToolCallDbTrap do
  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_call(request, _from, owner) do
    send(owner, {:unexpected_tool_call_db_request, request})
    {:reply, {:error, :unexpected_database_request}, owner}
  end
end

defmodule Tightbeam.Acp.ContextUsageTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Acp.{Adapter, ContextUsage}
  alias Tightbeam.{Model, ToolCalls}

  test "a reported context observation is not an authoritative submission allowance" do
    model = Model.new("gpt-5.6-sol")
    update = %{"sessionUpdate" => "usage_update", "used" => 3000, "size" => 10000}

    {:noreply, state} =
      receive_update(%Adapter{harness: :codex, models: %{"s" => model}}, "s", update)

    assert {:reply, {:ok, usage}, ^state} =
             Adapter.handle_call({:context_usage, "s", 1000}, nil, state)

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

    {:noreply, state} =
      receive_update(state, "s", %{
        "sessionUpdate" => "usage_update",
        "used" => 10,
        "size" => 10000
      })

    for {used, size} <- [
          {nil, 10000},
          {1, nil},
          {-1, 10000},
          {10001, 10000},
          {0, 0},
          {1.5, 10000}
        ] do
      {:noreply, invalid} =
        receive_update(state, "s", %{
          "sessionUpdate" => "usage_update",
          "used" => used,
          "size" => size
        })

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

    state = %Adapter{
      harness: :codex,
      preset: Tightbeam.Harness.Codex.session_config(%{}, ""),
      models: %{"s" => model}
    }

    {:noreply, state} =
      receive_update(state, "s", %{
        "sessionUpdate" => "usage_update",
        "used" => 10,
        "size" => 10000
      })

    for next_model <- ["gpt-other", "gpt-5.6-sol"], reduce: state do
      state ->
        {:noreply, state} =
          receive_update(state, "s", %{
            "sessionUpdate" => "config_option_update",
            "configOptions" => [%{"id" => "model", "currentValue" => next_model}]
          })

        assert state.models["s"] == Model.new(next_model)

        assert {:reply, {:error, :context_usage_unavailable}, ^state} =
                 Adapter.handle_call({:context_usage, "s", 1000}, nil, state)

        state
    end
  end

  test "nonterminal updates to a started tool call stay in memory" do
    db = start_supervised!({Tightbeam.Acp.ToolCallDbTrap, self()})
    key = {"root", "call-1"}
    initial_fields = %{title: "Run command"}

    state = %Adapter{
      db: db,
      harness: :codex,
      tool_turns: %{"root" => %{session_key: "session", turn_seq: 1}},
      pending_tool_calls: %{
        key => %{
          fields: initial_fields,
          context_usage_before: "80/100 tokens"
        }
      }
    }

    first_chunk = %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "call-1",
      "status" => "in_progress",
      "rawOutput" => "partial output"
    }

    {:noreply, state} = receive_update(state, "root", first_chunk)
    refute_receive {:unexpected_tool_call_db_request, _request}, 0

    progress = %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "call-1",
      "status" => "in_progress",
      "content" => %{"type" => "text", "text" => "still running"}
    }

    {:noreply, state} = receive_update(state, "root", progress)
    refute_receive {:unexpected_tool_call_db_request, _request}, 0

    expected_fields =
      initial_fields
      |> ToolCalls.merge_pending(ToolCalls.normalize_notification(first_chunk))
      |> ToolCalls.merge_pending(ToolCalls.normalize_notification(progress))

    assert state.pending_tool_calls[key] == %{
             fields: expected_fields,
             context_usage_before: "80/100 tokens"
           }
  end

  defp receive_update(state, sid, update),
    do:
      Adapter.handle_info(
        {:acp_notification, "session/update", %{"sessionId" => sid, "update" => update}},
        state
      )
end
