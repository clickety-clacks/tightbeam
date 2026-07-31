defmodule Tightbeam.CommandEdgeTest do
  use ExUnit.Case, async: true

  alias Tightbeam.CommandEdge

  alias Tightbeam.CommandEdge.{
    AdapterReady,
    AuthEvent,
    Job,
    Request,
    Signal,
    TerminalPublication,
    TurnContext
  }

  defmodule Receiver do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_cast({:tightbeam_command, command}, parent) do
      send(parent, {:signal, CommandEdge.validate_command!(command)})
      {:noreply, parent}
    end

    def handle_call({:tightbeam_command, command}, _from, parent) do
      command = CommandEdge.validate_command!(command)
      {:reply, {:received, command}, parent}
    end
  end

  defmodule Worker do
    def perform(parent, command) do
      send(parent, {:job, CommandEdge.validate_command!(command)})
    end
  end

  test "a bare function cannot be injected as any edge representation" do
    callback = fn -> :old_callback end

    assert_raise FunctionClauseError, fn ->
      apply(CommandEdge, :validate_signal!, [callback])
    end

    assert_raise FunctionClauseError, fn ->
      apply(CommandEdge, :validate_job!, [callback])
    end

    assert_raise FunctionClauseError, fn ->
      apply(CommandEdge, :validate_request!, [callback])
    end

    assert_raise FunctionClauseError, fn ->
      apply(CommandEdge, :signal_to, [callback])
    end

    assert_raise FunctionClauseError, fn ->
      apply(CommandEdge, :job_via, [callback, {Worker, :perform, [self()]}])
    end

    assert_raise FunctionClauseError, fn ->
      apply(CommandEdge, :request_to, [callback])
    end

    assert_raise FunctionClauseError, fn ->
      apply(CommandEdge, :validate_signal!, [struct(Signal, target: callback)])
    end

    assert_raise FunctionClauseError, fn ->
      edge =
        struct(Job,
          supervisor: callback,
          worker: {Worker, :perform, [self()]}
        )

      apply(CommandEdge, :validate_job!, [edge])
    end

    assert_raise FunctionClauseError, fn ->
      apply(CommandEdge, :validate_request!, [struct(Request, target: callback)])
    end
  end

  test "a bare function cannot be sent as a command" do
    receiver = start_supervised!({Receiver, self()})
    signal = CommandEdge.signal_to(receiver)

    assert_raise FunctionClauseError, fn ->
      apply(CommandEdge, :signal, [signal, fn -> :raw end])
    end

    refute_receive {:signal, _command}
  end

  test "signal is fire-and-forget and has no completion value" do
    receiver = start_supervised!({Receiver, self()})
    command = adapter_ready()

    assert :sent = CommandEdge.signal(CommandEdge.signal_to(receiver), command)
    assert_receive {:signal, ^command}
  end

  test "job acceptance is distinct from completion" do
    supervisor = start_supervised!({Task.Supervisor, []})
    command = adapter_ready()
    edge = CommandEdge.job_via(supervisor, {Worker, :perform, [self()]})

    assert {:accepted, pid} = CommandEdge.job(edge, command)
    assert is_pid(pid)
    assert_receive {:job, ^command}
  end

  test "request remains pending until its labelled response is checked" do
    receiver = start_supervised!({Receiver, self()})
    command = adapter_ready()
    request_ids = :gen_server.reqids_new()

    assert {:pending, request_ids} =
             CommandEdge.request(
               CommandEdge.request_to(receiver),
               command,
               {:adapter_ready, 7},
               request_ids
             )

    assert :gen_server.reqids_size(request_ids) == 1

    response =
      receive do
        message -> message
      after
        1_000 -> flunk("request reply did not reach the caller mailbox")
      end

    assert {:answered, {:adapter_ready, 7}, {:received, ^command}, request_ids} =
             CommandEdge.check_response(response, request_ids)

    assert :gen_server.reqids_size(request_ids) == 0
  end

  test "terminal publication requires captured turn and assignment context" do
    complete = %TerminalPublication{
      turn: turn_context(nil),
      message_id: "m1",
      status: "failed",
      error: "adapter unavailable"
    }

    assert CommandEdge.validate_command!(complete) == complete
    assert complete.turn.assignment_id == nil

    omitted_assignment =
      struct(TurnContext,
        session_key: "k1",
        turn_seq: 42,
        observed_at: 123
      )

    incomplete = %{complete | turn: omitted_assignment}

    assert_raise FunctionClauseError, fn -> CommandEdge.validate_command!(incomplete) end
  end

  test "auth event context is explicit rather than looked up later" do
    turn_scoped = %AuthEvent{
      adapter_key: {:codex, "shared", "host"},
      provider: :openai,
      classification: :terminal,
      evidence: %{"authMode" => nil},
      context: turn_context("assignment-1"),
      observed_at: 123
    }

    account_scoped = %{turn_scoped | context: :not_turn_scoped}

    assert CommandEdge.validate_command!(turn_scoped) == turn_scoped
    assert CommandEdge.validate_command!(account_scoped) == account_scoped

    omitted_context = struct(AuthEvent, Map.from_struct(turn_scoped) |> Map.delete(:context))

    assert_raise FunctionClauseError, fn -> CommandEdge.validate_command!(omitted_context) end
  end

  defp adapter_ready do
    %AdapterReady{
      adapter_key: {:codex, "shared", "host"},
      token: {9, 3},
      observed_at: 123
    }
  end

  defp turn_context(assignment_id) do
    %TurnContext{
      session_key: "k1",
      turn_seq: 42,
      assignment_id: assignment_id,
      observed_at: 123
    }
  end
end
