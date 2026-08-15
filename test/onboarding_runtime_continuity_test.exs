defmodule Tightbeam.OnboardingRuntimeContinuityTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{OnboardingRegistry, OnboardingSupervisor, OnboardingWorker}

  @secret "response-secret-sentinel#state"

  setup do
    suffix = System.unique_integer([:positive])
    registry = String.to_atom("onboarding_registry_#{suffix}")
    supervisor_name = String.to_atom("onboarding_supervisor_#{suffix}")
    start_supervised!({OnboardingRegistry, name: registry})
    supervisor = start_supervised!({OnboardingSupervisor, name: supervisor_name})

    fixture_dir = Path.join(System.tmp_dir!(), "onboarding_worker_#{suffix}")
    fixture_path = Path.join(fixture_dir, "worker.exs")
    File.mkdir_p!(fixture_dir)
    File.chmod!(fixture_dir, 0o700)
    File.write!(fixture_path, fixture_source())
    File.chmod!(fixture_path, 0o700)
    on_exit(fn -> File.rm_rf!(fixture_dir) end)

    %{registry: registry, supervisor: supervisor, fixture_path: fixture_path}
  end

  test "one exact live identity outlives its starting caller and response uses stdin", ctx do
    worker_ref = "worker-owner-independent"
    ceremony_id = "ceremony-owner-independent"
    test_pid = self()

    starter =
      spawn(fn ->
        result =
          OnboardingSupervisor.start_worker(
            worker_opts(ctx, worker_ref, ceremony_id),
            ctx.supervisor
          )

        send(test_pid, {:worker_started, result})
      end)

    starter_monitor = Process.monitor(starter)
    assert_receive {:worker_started, {:ok, worker}}
    assert_receive {:DOWN, ^starter_monitor, :process, ^starter, :normal}
    assert Process.alive?(worker)

    assert {:ok, identity} = OnboardingWorker.identity(worker_ref, ctx.registry)
    assert identity.worker_ref == worker_ref
    assert identity.ceremony_id == ceremony_id
    assert identity.worker_pid == worker
    assert identity.provider_process_id > 0
    assert identity.os_process_start_identity == "fixture:#{identity.provider_process_id}"

    assert {:ok, ^worker} =
             OnboardingRegistry.lookup_exact(
               worker_ref,
               ceremony_id,
               identity.provider_process_id,
               identity.os_process_start_identity,
               ctx.registry
             )

    assert :error =
             OnboardingRegistry.lookup_exact(
               worker_ref,
               ceremony_id,
               identity.provider_process_id + 1,
               identity.os_process_start_identity,
               ctx.registry
             )

    assert :error =
             OnboardingRegistry.lookup_exact(
               worker_ref,
               ceremony_id,
               identity.provider_process_id,
               "fixture:other-start",
               ctx.registry
             )

    refute process_command(identity.provider_process_id) =~ @secret

    # The challenge was emitted before this observer attached. Replaying it
    # proves an owner can reconnect to the same live worker without relaunching.
    assert :ok = OnboardingWorker.observe(worker_ref, self(), 0, ctx.registry)

    assert_receive {:onboarding_worker_observation, ^worker_ref, 1,
                    %{
                      kind: :public_challenge_ready,
                      authorization_url: "https://example.invalid/authorize",
                      display_code: nil
                    }}

    assert :ok = OnboardingWorker.deliver_response(worker_ref, :code, @secret, ctx.registry)

    assert_receive {:onboarding_worker_observation, ^worker_ref, 2,
                    %{kind: :response_delivered, response_kind: :code}}

    assert {:ok, observations} = OnboardingWorker.observations(worker_ref, ctx.registry)

    assert Enum.map(observations, &elem(&1, 1).kind) == [
             :public_challenge_ready,
             :response_delivered
           ]

    refute inspect(observations) =~ @secret
    refute inspect(:sys.get_state(worker)) =~ @secret

    assert {:error, {:already_started, ^worker}} =
             OnboardingSupervisor.start_worker(
               worker_opts(ctx, worker_ref, ceremony_id),
               ctx.supervisor
             )

    assert %{active: 1, workers: 1} = DynamicSupervisor.count_children(ctx.supervisor)

    monitor = Process.monitor(worker)
    assert :ok = OnboardingSupervisor.terminate_worker(worker_ref, ctx.supervisor, ctx.registry)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}
    assert :error = OnboardingRegistry.worker_pid(worker_ref, ctx.registry)
    assert [] = DynamicSupervisor.which_children(ctx.supervisor)
  end

  test "an isolated worker crash never relaunches its provider exchange", ctx do
    worker_ref = "worker-temporary"

    assert %{restart: :temporary} =
             OnboardingWorker.child_spec(worker_opts(ctx, worker_ref, "ceremony-temporary"))

    assert {:ok, worker} =
             OnboardingSupervisor.start_worker(
               worker_opts(ctx, worker_ref, "ceremony-temporary"),
               ctx.supervisor
             )

    assert {:ok, identity} = OnboardingWorker.identity(worker_ref, ctx.registry)
    provider_process_id = identity.provider_process_id
    monitor = Process.monitor(worker)
    Process.exit(worker, :fixture_crash)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :fixture_crash}

    assert [] = DynamicSupervisor.which_children(ctx.supervisor)
    assert :error = OnboardingRegistry.worker_pid(worker_ref, ctx.registry)
    assert eventually_process_absent(provider_process_id)
  end

  test "the response vocabulary rejects values that could blur secret handling", ctx do
    worker_ref = "worker-response-shape"

    assert {:ok, _worker} =
             OnboardingSupervisor.start_worker(
               worker_opts(ctx, worker_ref, "ceremony-response-shape"),
               ctx.supervisor
             )

    assert {:ok, _identity} = OnboardingWorker.identity(worker_ref, ctx.registry)

    assert {:error, :invalid_response} =
             OnboardingWorker.deliver_response(worker_ref, :approved, @secret, ctx.registry)

    assert {:error, :invalid_response} =
             OnboardingWorker.deliver_response(worker_ref, :code, "", ctx.registry)

    assert {:error, :invalid_response} =
             OnboardingWorker.deliver_response(worker_ref, :unknown, @secret, ctx.registry)
  end

  defp worker_opts(ctx, worker_ref, ceremony_id) do
    [
      worker_ref: worker_ref,
      ceremony_id: ceremony_id,
      provider: :anthropic,
      credential_kind: :subscription,
      deadline_ms: 60_000,
      registry: ctx.registry,
      cmd: [System.find_executable("elixir"), ctx.fixture_path]
    ]
  end

  defp process_command(pid) do
    case System.cmd("ps", ["-o", "command=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {command, 0} -> command
      _other -> ""
    end
  end

  defp eventually_process_absent(pid, attempts \\ 100)
  defp eventually_process_absent(_pid, 0), do: false

  defp eventually_process_absent(pid, attempts) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} ->
        Process.sleep(10)
        eventually_process_absent(pid, attempts - 1)

      {_output, _status} ->
        true
    end
  end

  defp fixture_source do
    ~S'''
    value_for = fn flag ->
      args = System.argv()
      index = Enum.find_index(args, &(&1 == flag)) || raise "missing worker argument"
      Enum.at(args, index + 1) || raise "missing worker argument value"
    end

    worker_ref = value_for.("--worker-ref")
    ceremony_id = value_for.("--ceremony-id")
    process_id = System.pid() |> String.to_integer()

    IO.puts(
      ~s({"type":"workerStarted","workerRef":"#{worker_ref}","ceremonyId":"#{ceremony_id}","processId":#{process_id},"osProcessStartIdentity":"fixture:#{process_id}"})
    )

    IO.puts(
      ~s({"type":"publicChallengeReady","authorizationUrl":"https://example.invalid/authorize"})
    )

    read_response = fn read_response ->
      case IO.binread(:stdio, 5) do
        :eof ->
          :ok

        <<tag, size::unsigned-big-32>> ->
          case IO.binread(:stdio, size) do
            "response-secret-sentinel#state" when tag == 1 ->
              IO.puts(~s({"type":"responseDelivered","responseKind":"code"}))
              read_response.(read_response)

            _other ->
              System.halt(42)
          end

        _other ->
          System.halt(43)
      end
    end

    read_response.(read_response)
    '''
  end
end
