defmodule Tightbeam.HarnessSwitchCompactorRouteTest.Coordinator do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call({:adapter_for, key}, _from, %{adapter: adapter, owner: owner} = state) do
    send(owner, {:adapter_checkout, key})
    {:reply, {:ok, adapter, 1}, state}
  end
end

defmodule Tightbeam.HarnessSwitchCompactorRouteTest.Adapter do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call(
        {:new_session, model, cwd, mcp_servers, instructions},
        _from,
        %{owner: owner} = state
      ) do
    send(owner, {:acp_new_session, model, cwd, mcp_servers, instructions})
    {:reply, {:ok, "compactor-acp-session"}, state}
  end

  @impl true
  def handle_call(
        {:prompt, session_id, input, opts},
        _from,
        %{owner: owner} = state
      ) do
    send(owner, {:acp_prompt, session_id, input, opts})

    result = Map.get(state, :prompt_result) || {:ok, Map.fetch!(state, :response)}
    {:reply, result, state}
  end

  @impl true
  def handle_call({:close_session, session_id, opts}, _from, %{owner: owner} = state) do
    send(owner, {:acp_close, session_id, opts})
    {:reply, Map.get(state, :close_result, :ok), state}
  end
end

defmodule Tightbeam.HarnessSwitchCompactorRouteTest do
  use ExUnit.Case, async: true

  alias Tightbeam.{Gateway, Model}
  alias Tightbeam.HarnessSwitchCompactorRouteTest.{Adapter, Coordinator}

  test "compaction uses the gateway Codex adapter session and closes it" do
    input = "WID19B_GOAL=preserve-this-context"
    instructions = "Compress historical context; do not invoke tools."
    output = "WID19B_GOAL=preserve-this-context"

    adapter =
      start_supervised!(
        {Adapter, owner: self(), response: %{stop_reason: "end_turn", text: output, messages: []}}
      )

    coordinator = start_supervised!({Coordinator, adapter: adapter, owner: self()})

    compactor = %{
      route: :codex_acp,
      harness: Tightbeam.Harness.Codex,
      model: "gpt-6-luna",
      effort: "low"
    }

    assert {:ok, ^output, %{route: "codex_acp", model: "gpt-6-luna", input_bytes: input_bytes}} =
             Gateway.harness_switch_compactor_call(
               coordinator,
               "isolated-test-host",
               "/tmp/compactor-cwd",
               compactor,
               input,
               instructions
             )

    assert input_bytes == byte_size(input)
    assert_receive {:adapter_checkout, {:codex, "shared", "isolated-test-host"}}

    assert_receive {:acp_new_session, %Model{family: "gpt-6-luna", effort: "low"},
                    "/tmp/compactor-cwd", [], ^instructions}

    assert_receive {:acp_prompt, "compactor-acp-session", ^input, [timeout: 30_000]}
    assert_receive {:acp_close, "compactor-acp-session", [request_timeout: 5_000]}
  end

  test "a timed out compactor prompt closes its temporary session within the cleanup bound" do
    adapter = start_supervised!({Adapter, owner: self(), prompt_result: {:error, :prompt_timeout}})
    coordinator = start_supervised!({Coordinator, adapter: adapter, owner: self()})

    assert {:error, :timeout} =
             Gateway.harness_switch_compactor_call(
               coordinator,
               "isolated-test-host",
               "/tmp/compactor-cwd",
               %{
                 route: :codex_acp,
                 harness: Tightbeam.Harness.Codex,
                 model: "gpt-6-luna",
                 effort: "low"
               },
               "historical input",
               "compact without tools"
             )

    assert_receive {:acp_prompt, "compactor-acp-session", "historical input", [timeout: 30_000]}
    assert_receive {:acp_close, "compactor-acp-session", [request_timeout: 5_000]}
  end

  test "a nonfinal compactor reply is rejected after closing the ACP session" do
    adapter =
      start_supervised!(
        {Adapter,
         owner: self(), response: %{stop_reason: "max_tokens", text: "partial", messages: []}}
      )

    coordinator = start_supervised!({Coordinator, adapter: adapter, owner: self()})

    assert {:error, :incomplete_or_unusable_response} =
             Gateway.harness_switch_compactor_call(
               coordinator,
               "isolated-test-host",
               "/tmp/compactor-cwd",
               %{
                 route: :codex_acp,
                 harness: Tightbeam.Harness.Codex,
                 model: "gpt-6-luna",
                 effort: "low"
               },
               "historical input",
               "compact without tools"
             )

    assert_receive {:acp_close, "compactor-acp-session", [request_timeout: 5_000]}
  end

  test "a prompt failure still closes the temporary ACP session" do
    adapter =
      start_supervised!({Adapter, owner: self(), prompt_result: {:error, :provider_refused}})

    coordinator = start_supervised!({Coordinator, adapter: adapter, owner: self()})

    assert {:error, {:prompt_failed, :provider_refused}} =
             Gateway.harness_switch_compactor_call(
               coordinator,
               "isolated-test-host",
               "/tmp/compactor-cwd",
               %{
                 route: :codex_acp,
                 harness: Tightbeam.Harness.Codex,
                 model: "gpt-6-luna",
                 effort: "low"
               },
               "historical input",
               "compact without tools"
             )

    assert_receive {:acp_close, "compactor-acp-session", [request_timeout: 5_000]}
  end

  test "a session that fails to close is not accepted as a compaction result" do
    output = "compacted historical context"

    adapter =
      start_supervised!(
        {Adapter,
         owner: self(),
         response: %{stop_reason: "end_turn", text: output, messages: []},
         close_result: {:error, :adapter_unavailable}}
      )

    coordinator = start_supervised!({Coordinator, adapter: adapter, owner: self()})

    assert {:error, {:session_close_failed, :adapter_unavailable}} =
             Gateway.harness_switch_compactor_call(
               coordinator,
               "isolated-test-host",
               "/tmp/compactor-cwd",
               %{
                 route: :codex_acp,
                 harness: Tightbeam.Harness.Codex,
                 model: "gpt-6-luna",
                 effort: "low"
               },
               "historical input",
               "compact without tools"
             )

    assert_receive {:acp_close, "compactor-acp-session", [request_timeout: 5_000]}
  end
end
