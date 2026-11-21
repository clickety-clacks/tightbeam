defmodule Tightbeam.HarnessSwitchCompactorRouteTest.Coordinator do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call({:adapter_for, key}, _from, %{hang: true, owner: owner} = state) do
    send(owner, {:adapter_checkout, key})
    {:noreply, state}
  end

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
        {:new_candidate_session, model, cwd, mcp_servers, instructions, _deadline},
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

    assert_receive {:acp_prompt, "compactor-acp-session", ^input, prompt_opts}
    assert Keyword.get(prompt_opts, :timeout) in 1..30_000
    assert Keyword.get(prompt_opts, :cancel_grace) == 5_000
    assert_receive {:acp_close, "compactor-acp-session", [request_timeout: 5_000]}
  end

  test "Claude uses a fresh Haiku ACP session and returns its own summary attribution" do
    output = "Retained goal, user decision, pending work and evidence."

    adapter =
      start_supervised!(
        {Adapter, owner: self(), response: %{stop_reason: "end_turn", text: output}}
      )

    coordinator = start_supervised!({Coordinator, adapter: adapter, owner: self()})

    assert {:ok, ^output, %{route: "acp", model: "claude-haiku-5-5"}} =
             Gateway.harness_switch_compactor_call(
               coordinator,
               "isolated-test-host",
               "/tmp/compactor-cwd",
               %{
                 route: :acp,
                 harness: Tightbeam.Harness.Claude,
                 model: "claude-haiku-5-5",
                 effort: "low"
               },
               "synthetic historical transcript",
               "summarize without tools"
             )

    assert_receive {:adapter_checkout, {:claude, "shared", "isolated-test-host"}}

    assert_receive {:acp_new_session, %Model{family: "claude-haiku-5-5", effort: "low"},
                    "/tmp/compactor-cwd", [], "summarize without tools"}

    assert_receive {:acp_prompt, "compactor-acp-session", "synthetic historical transcript", _}
    assert_receive {:acp_close, "compactor-acp-session", _}
  end

  test "Claude compactor session opts select its model and disable its built-in tools" do
    cwd = "/tmp/compactor-cwd"
    model = Model.new("claude-haiku-5-5", effort: "low")

    assert %{meta: %{claudeCode: %{options: %{model: "claude-haiku-5-5", tools: []}}}} =
             Tightbeam.Harness.Claude.session_config(
               %{cwd: cwd, compactor_model: model},
               "summarize"
             )

    %{meta: %{claudeCode: %{options: normal_options}}} =
      Tightbeam.Harness.Claude.session_config(%{cwd: cwd}, "normal")

    refute Map.has_key?(normal_options, :model)
  end

  test "a hung checkout cannot prevent later failover" do
    coordinator = start_supervised!({Coordinator, owner: self(), hang: true})

    assert {:error, :timeout} =
             Gateway.harness_switch_compactor_call(
               coordinator,
               "isolated-test-host",
               "/tmp/compactor-cwd",
               %{route: :codex_acp, harness: Tightbeam.Harness.Codex, model: "gpt-6-luna"},
               "history",
               "summarize",
               35
             )

    assert_receive {:adapter_checkout, {:codex, "shared", "isolated-test-host"}}
  end

  test "a timed out compactor prompt closes its temporary session within the cleanup bound" do
    adapter =
      start_supervised!({Adapter, owner: self(), prompt_result: {:error, :prompt_timeout}})

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

    assert_receive {:acp_prompt, "compactor-acp-session", "historical input", prompt_opts}
    assert Keyword.get(prompt_opts, :timeout) in 1..30_000
    assert Keyword.get(prompt_opts, :cancel_grace) == 5_000
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
