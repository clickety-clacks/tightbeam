defmodule Tightbeam.GatewayTurnFixture do
  @moduledoc false
  alias Tightbeam.Model

  defmodule CoordinatorStub do
    use GenServer

    def start_link({adapter, parent}),
      do: GenServer.start_link(__MODULE__, {adapter, parent}, name: Tightbeam.AdapterCoordinator)

    def start_link(adapter),
      do: GenServer.start_link(__MODULE__, {adapter, nil}, name: Tightbeam.AdapterCoordinator)

    def init({adapter, parent}), do: {:ok, {adapter, parent}}

    def handle_call({:adapter_for, key}, _from, {adapter, parent} = state) do
      if is_pid(parent), do: send(parent, {:adapter_key, key})
      reply = if is_function(adapter, 1), do: adapter.(key), else: {:ok, adapter, 1}
      {:reply, reply, state}
    end

    def handle_call({:adapter_for, key, _context}, from, state),
      do: handle_call({:adapter_for, key}, from, state)

    def handle_call({:acquire_load_slot, _machine, _borrower}, _from, state),
      do: {:reply, make_ref(), state}

    def handle_call({:close_adapter, key}, _from, {adapter, parent} = state) do
      if is_pid(parent), do: send(parent, {:close_adapter, key})
      GenServer.stop(adapter)
      {:reply, :ok, state}
    end

    def handle_call(:harness_processes, _from, {_adapter, parent} = state) do
      if is_pid(parent), do: send(parent, :harness_processes)
      {:reply, [%{launch_id: "launch-1", state: "kill_failed"}], state}
    end

    def handle_cast({:release_load_slot, _machine, _slot}, state), do: {:noreply, state}

    def handle_cast({:close_adapter, key}, {adapter, parent} = state) do
      if is_pid(parent), do: send(parent, {:close_adapter, key})
      GenServer.stop(adapter)
      {:noreply, state}
    end
  end

  defmodule AdapterStub do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    def init({:unique_sessions, parent}) do
      Process.put(:unique_fixture_sessions, true)
      {:ok, parent}
    end

    def init(parent), do: {:ok, parent}

    def handle_call({:new_session, _model, _cwd, mcp_servers, _guidance}, _from, parent) do
      send(parent, {:new_session_mcp_servers, mcp_servers})

      sid =
        if Process.get(:unique_fixture_sessions),
          do: "harness-#{System.unique_integer([:positive])}",
          else: "harness-1"

      {:reply, {:ok, sid}, parent}
    end

    def handle_call({:new_candidate_session, model, cwd, mcp_servers, guidance}, from, parent),
      do: handle_call({:new_session, model, cwd, mcp_servers, guidance}, from, parent)

    def handle_call(
          {:new_session, model, cwd, mcp_servers, guidance, _request_timeout},
          from,
          parent
        ),
        do: handle_call({:new_session, model, cwd, mcp_servers, guidance}, from, parent)

    def handle_call(:conn, _from, parent), do: {:reply, parent, parent}

    def handle_call({:knows_session?, _sid}, _from, parent), do: {:reply, false, parent}

    def handle_call({:current_model, "harness-1"}, _from, parent),
      do: {:reply, {:ok, Model.new("gpt-5.6-sol", effort: "medium")}, parent}

    def handle_call({:load_session, _sid, _model, _cwd, _mcp_servers, _guidance}, _from, parent),
      do: {:reply, {:error, %{"code" => -32602, "message" => "Invalid params"}}, parent}

    def handle_call(
          {:load_session, sid, model, cwd, mcp_servers, guidance, _request_timeout},
          from,
          parent
        ),
        do: handle_call({:load_session, sid, model, cwd, mcp_servers, guidance}, from, parent)

    def handle_call({:close_session, sid}, _from, parent) do
      send(parent, {:close_session, sid})
      {:reply, :ok, parent}
    end

    def handle_call({:prompt, _sid, "fail this turn", _opts}, _from, parent),
      do:
        {:reply,
         {:error, %{"message" => "Internal error", "data" => %{"details" => "auth expired"}}},
         parent}

    def handle_call({:prompt, _sid, "fail with " <> json, _opts}, _from, parent),
      do: {:reply, {:error, JSON.decode!(json)}, parent}

    def handle_call({:prompt, _sid, prompt, _opts}, from, parent) do
      send(parent, {:prompt_started, self()})

      messages =
        case prompt do
          "split assistant messages" ->
            [
              %{message_id: "fake-message-1", text: "FIRST"},
              %{message_id: "fake-message-2", text: "SECOND"}
            ]

          _ ->
            [%{message_id: "fake-message", text: String.upcase(prompt)}]
        end

      receive do: (:continue_prompt ->
                     GenServer.reply(
                       from,
                       {:ok,
                        %{
                          text: Enum.map_join(messages, & &1.text),
                          messages: messages,
                          stop_reason: "end_turn"
                        }}
                     ))

      {:noreply, parent}
    end
  end
end
