defmodule Tightbeam.CommandEdgeTest do
  use ExUnit.Case, async: true

  alias Tightbeam.CommandEdge

  alias Tightbeam.CommandEdge.{
    AdapterReady,
    AuthEvent,
    Job,
    JobDispatcher,
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

  defmodule DeferredReceiver do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, {parent, nil}}

    def handle_call({:tightbeam_command, command}, from, {parent, nil}) do
      send(parent, {:request_received, command})
      {:noreply, {parent, from}}
    end

    def handle_cast(:reply, {parent, from}) do
      GenServer.reply(from, :late_reply)
      send(parent, :reply_attempted)
      {:noreply, {parent, nil}}
    end
  end

  defmodule BlockingTaskSupervisor do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call(request, from, parent) do
      send(parent, {:task_supervisor_call, self(), from, request})
      {:noreply, parent}
    end
  end

  test "a bare function cannot be injected as any edge representation" do
    callback = fn -> :old_callback end

    assert_executable_data_rejected(fn ->
      apply(CommandEdge, :validate_signal!, [callback])
    end)

    assert_executable_data_rejected(fn ->
      apply(CommandEdge, :validate_job!, [callback])
    end)

    assert_executable_data_rejected(fn ->
      apply(CommandEdge, :validate_request!, [callback])
    end)

    assert_executable_data_rejected(fn ->
      apply(CommandEdge, :signal_to, [callback])
    end)

    assert_executable_data_rejected(fn ->
      apply(CommandEdge, :job_via, [callback, {Worker, :perform, [self()]}])
    end)

    assert_executable_data_rejected(fn ->
      apply(CommandEdge, :request_to, [callback])
    end)

    assert_executable_data_rejected(fn ->
      apply(CommandEdge, :validate_signal!, [struct(Signal, target: callback)])
    end)

    assert_executable_data_rejected(fn ->
      edge =
        struct(Job,
          dispatcher: callback,
          worker: {Worker, :perform, [self()]}
        )

      apply(CommandEdge, :validate_job!, [edge])
    end)

    assert_executable_data_rejected(fn ->
      apply(CommandEdge, :validate_request!, [struct(Request, target: callback)])
    end)
  end

  test "functions nested in worker args, via targets, labels, and struct-shaped maps are rejected" do
    receiver = start_supervised!({Receiver, self()})
    callback = fn -> :escaped end

    job =
      struct(Job,
        dispatcher: self(),
        worker: {Worker, :perform, [self(), %{nested: [callback]}]}
      )

    assert_executable_data_rejected(fn -> CommandEdge.validate_job!(job) end)

    via_target = {:via, Registry, {:edge_registry, :receiver, callback}}
    signal = struct(Signal, target: via_target)

    assert_executable_data_rejected(fn -> CommandEdge.validate_signal!(signal) end)

    assert_executable_data_rejected(fn ->
      CommandEdge.request(
        CommandEdge.request_to(receiver),
        adapter_ready(),
        callback,
        :gen_server.reqids_new()
      )
    end)

    struct_shaped_map =
      adapter_ready()
      |> Map.from_struct()
      |> Map.put(:__struct__, AdapterReady)
      |> Map.put(:after_validation, callback)

    assert_executable_data_rejected(fn ->
      CommandEdge.validate_command!(struct_shaped_map)
    end)
  end

  test "a bare function cannot be sent as a command" do
    receiver = start_supervised!({Receiver, self()})
    signal = CommandEdge.signal_to(receiver)

    assert_executable_data_rejected(fn ->
      apply(CommandEdge, :signal, [signal, fn -> :raw end])
    end)

    refute_receive {:signal, _command}
  end

  test "signal is fire-and-forget and has no completion value" do
    receiver = start_supervised!({Receiver, self()})
    command = adapter_ready()

    assert :sent = CommandEdge.signal(CommandEdge.signal_to(receiver), command)
    assert_receive {:signal, ^command}
  end

  test "job dispatch is distinct from worker start and completion" do
    supervisor = start_supervised!({Task.Supervisor, []})
    dispatcher = start_supervised!({JobDispatcher, supervisor})
    command = adapter_ready()
    edge = CommandEdge.job_via(dispatcher, {Worker, :perform, [self()]})

    assert :dispatched = CommandEdge.job(edge, command)
    assert_receive {:job, ^command}
  end

  test "job never waits on the dispatcher or its higher-tier Task supervisor" do
    task_supervisor = start_supervised!({BlockingTaskSupervisor, self()})
    dispatcher = start_supervised!({JobDispatcher, task_supervisor})
    edge = CommandEdge.job_via(dispatcher, {Worker, :perform, [self()]})

    assert :dispatched = CommandEdge.job(edge, adapter_ready())

    assert_receive {:task_supervisor_call, ^task_supervisor, {^dispatcher, _tag}, _request}
    assert Process.alive?(dispatcher)
  end

  test "concurrent requests stay labelled while unmatched messages are ignored" do
    receiver = start_supervised!({Receiver, self()})
    command = adapter_ready()
    request_ids = :gen_server.reqids_new()

    assert {:pending, request_ids} =
             CommandEdge.request(
               CommandEdge.request_to(receiver),
               command,
               {:adapter_ready, 1},
               request_ids
             )

    assert {:pending, request_ids} =
             CommandEdge.request(
               CommandEdge.request_to(receiver),
               command,
               {:adapter_ready, 2},
               request_ids
             )

    assert :gen_server.reqids_size(request_ids) == 2
    assert :no_reply = CommandEdge.check_response(:unmatched, request_ids)
    assert :gen_server.reqids_size(request_ids) == 2

    {labels, request_ids} =
      Enum.reduce(1..2, {MapSet.new(), request_ids}, fn _, {labels, request_ids} ->
        response = receive_request_message()

        assert {:answered, label, {:received, ^command}, request_ids} =
                 CommandEdge.check_response(response, request_ids)

        {MapSet.put(labels, label), request_ids}
      end)

    assert labels == MapSet.new([{:adapter_ready, 1}, {:adapter_ready, 2}])
    assert :gen_server.reqids_size(request_ids) == 0
    assert :no_request = CommandEdge.check_response(:unmatched, request_ids)
  end

  test "a request to a dead target reports failure through the collection" do
    {:ok, receiver} = GenServer.start(Receiver, self())
    monitor = Process.monitor(receiver)
    Process.exit(receiver, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^receiver, :killed}

    assert {:pending, request_ids} =
             CommandEdge.request(
               CommandEdge.request_to(receiver),
               adapter_ready(),
               :dead_target,
               :gen_server.reqids_new()
             )

    response = receive_request_message()

    assert {:failed, :dead_target, _reason, request_ids} =
             CommandEdge.check_response(response, request_ids)

    assert :gen_server.reqids_size(request_ids) == 0
  end

  test "abandoning a request prevents its late reply from reaching the mailbox" do
    receiver = start_supervised!({DeferredReceiver, self()})
    command = adapter_ready()

    assert {:pending, request_ids} =
             CommandEdge.request(
               CommandEdge.request_to(receiver),
               command,
               :abandoned,
               :gen_server.reqids_new()
             )

    assert_receive {:request_received, ^command}
    assert :abandoned = CommandEdge.abandon_requests(request_ids)

    GenServer.cast(receiver, :reply)
    assert_receive :reply_attempted
    refute_receive {[:alias | _request_id], :late_reply}, 50
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

    assert_raise ArgumentError, ~r/invalid TurnContext/, fn ->
      CommandEdge.validate_command!(incomplete)
    end

    for field <- [:session_key, :turn_seq, :observed_at] do
      empty_context = Map.put(turn_context(nil), field, nil)
      invalid = %{complete | turn: empty_context}

      assert_raise ArgumentError, ~r/invalid TurnContext/, fn ->
        CommandEdge.validate_command!(invalid)
      end
    end

    all_nil = %TerminalPublication{
      turn: %TurnContext{
        session_key: nil,
        turn_seq: nil,
        assignment_id: nil,
        observed_at: nil
      },
      message_id: nil,
      status: nil,
      error: nil
    }

    assert_raise ArgumentError, ~r/invalid TerminalPublication/, fn ->
      CommandEdge.validate_command!(all_nil)
    end
  end

  test "command structs enforce their declared value shapes" do
    assert_raise ArgumentError, ~r/invalid AdapterReady/, fn ->
      CommandEdge.validate_command!(%AdapterReady{
        adapter_key: {:codex, "shared", "host"},
        token: {0, -1},
        observed_at: nil
      })
    end

    assert_raise ArgumentError, ~r/invalid AuthEvent/, fn ->
      CommandEdge.validate_command!(%AuthEvent{
        adapter_key: {:codex, "shared", "host"},
        provider: "openai",
        classification: :terminal,
        evidence: %{},
        context: :not_turn_scoped,
        observed_at: 123
      })
    end
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

    assert_raise ArgumentError, fn -> CommandEdge.validate_command!(omitted_context) end
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

  defp assert_executable_data_rejected(fun) do
    assert_raise ArgumentError, "command edge data cannot contain functions", fun
  end

  defp receive_request_message do
    receive do
      {[:alias | _request_id], _response} = message -> message
      {:DOWN, _request_id, :process, _target, _reason} = message -> message
    after
      1_000 -> flunk("request response did not reach the caller mailbox")
    end
  end
end
