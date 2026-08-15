defmodule Tightbeam.OnboardingWorker do
  @moduledoc """
  One host-local provider ceremony worker.

  The Rust worker speaks newline-delimited, closed observation objects on
  stdout. Response values travel in a length-prefixed stdin frame and are never
  retained in GenServer state. Observations stay in this process so a restarted
  credential owner can subscribe from its last durable sequence while the same
  provider process remains live.
  """

  use GenServer

  alias Tightbeam.OnboardingRegistry

  @response_tags %{code: 1, approved: 2}

  defstruct port: nil,
            buffer: <<>>,
            worker_ref: nil,
            ceremony_id: nil,
            provider: nil,
            credential_kind: nil,
            registry: nil,
            expected_process_id: nil,
            identity: nil,
            identity_waiters: [],
            observer: nil,
            observations: [],
            next_sequence: 1

  @type observation ::
          %{
            kind: :public_challenge_ready,
            authorization_url: String.t(),
            display_code: String.t() | nil
          }
          | %{kind: :response_delivered, response_kind: :code | :approved}
          | %{
              kind: :validation_result,
              accepted: boolean(),
              failure_code: String.t() | nil
            }
          | %{
              kind: :candidate_ready,
              staging_ref: String.t(),
              candidate_digest: String.t()
            }

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :worker_ref)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    worker_ref = Keyword.fetch!(opts, :worker_ref)
    registry = Keyword.get(opts, :registry, OnboardingRegistry)

    GenServer.start_link(__MODULE__, opts, name: OnboardingRegistry.via(worker_ref, registry))
  end

  @doc "Wait for and return the verified live process identity."
  @spec identity(String.t(), atom()) ::
          {:ok, OnboardingRegistry.identity()} | {:error, :not_found}
  def identity(worker_ref, registry \\ OnboardingRegistry) do
    with {:ok, pid} <- find_worker(worker_ref, registry) do
      GenServer.call(pid, :identity, :infinity)
    end
  end

  @doc "Subscribe to typed observations after a durable sequence number."
  @spec observe(String.t(), pid(), non_neg_integer(), atom()) :: :ok | {:error, :not_found}
  def observe(worker_ref, observer, after_sequence \\ 0, registry \\ OnboardingRegistry)
      when is_pid(observer) and is_integer(after_sequence) and after_sequence >= 0 do
    with {:ok, pid} <- find_worker(worker_ref, registry) do
      GenServer.call(pid, {:observe, observer, after_sequence})
    end
  end

  @doc "Return the non-secret observation history retained by the live worker."
  @spec observations(String.t(), atom()) ::
          {:ok, [{pos_integer(), observation()}]} | {:error, :not_found}
  def observations(worker_ref, registry \\ OnboardingRegistry) do
    with {:ok, pid} <- find_worker(worker_ref, registry) do
      GenServer.call(pid, :observations)
    end
  end

  @doc "Deliver one response through the worker's inherited stdin pipe."
  @spec deliver_response(String.t(), :code | :approved, binary() | nil, atom()) ::
          :ok | {:error, :invalid_response | :not_found | :worker_closed}
  def deliver_response(worker_ref, kind, value, registry \\ OnboardingRegistry) do
    with {:ok, pid} <- find_worker(worker_ref, registry) do
      GenServer.call(pid, {:deliver_response, kind, value})
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    worker_ref = required_string!(opts, :worker_ref)
    ceremony_id = required_string!(opts, :ceremony_id)
    provider = required_member!(opts, :provider, ["anthropic", "openai"])
    credential_kind = required_member!(opts, :credential_kind, ["subscription"])
    registry = Keyword.get(opts, :registry, OnboardingRegistry)
    command = Keyword.get_lazy(opts, :cmd, fn -> default_command(opts) end) ++ worker_args(opts)
    port = open_command(command)
    {:os_pid, expected_process_id} = Port.info(port, :os_pid)

    {:ok,
     %__MODULE__{
       port: port,
       worker_ref: worker_ref,
       ceremony_id: ceremony_id,
       provider: provider,
       credential_kind: credential_kind,
       registry: registry,
       expected_process_id: expected_process_id
     }}
  end

  @impl true
  def handle_call(:identity, _from, %{identity: identity} = state) when not is_nil(identity) do
    {:reply, {:ok, identity}, state}
  end

  def handle_call(:identity, from, state) do
    {:noreply, %{state | identity_waiters: [from | state.identity_waiters]}}
  end

  def handle_call({:observe, observer, after_sequence}, _from, state) do
    state.observations
    |> Enum.filter(fn {sequence, _observation} -> sequence > after_sequence end)
    |> Enum.each(fn {sequence, observation} ->
      send(observer, {:onboarding_worker_observation, state.worker_ref, sequence, observation})
    end)

    {:reply, :ok, %{state | observer: observer}}
  end

  def handle_call(:observations, _from, state) do
    {:reply, {:ok, state.observations}, state}
  end

  def handle_call({:deliver_response, kind, value}, _from, state) do
    case response_frame(kind, value) do
      {:ok, frame} ->
        reply = if command_port(state.port, frame), do: :ok, else: {:error, :worker_closed}
        {:reply, reply, state}

      :error ->
        {:reply, {:error, :invalid_response}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> chunk)

    Enum.reduce_while(lines, {:ok, %{state | buffer: buffer}}, fn line, {:ok, acc} ->
      case accept_line(line, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason, failed} -> {:halt, {:error, reason, failed}}
      end
    end)
    |> case do
      {:ok, next} -> {:noreply, next}
      {:error, reason, failed} -> {:stop, reason, fail_identity_waiters(failed)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:provider_worker_exit, status}, fail_identity_waiters(state)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:stop, {:provider_worker_exit, closed_reason(reason)}, fail_identity_waiters(state)}
  end

  def handle_info({:EXIT, _linked_process, reason}, state) do
    {:stop, reason, fail_identity_waiters(state)}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port && Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp accept_line(line, %{identity: nil} = state) do
    with {:ok, decoded} <- decode_json(line),
         {:ok, identity} <- decode_identity(decoded, state),
         :ok <- OnboardingRegistry.register_identity(state.registry, identity) do
      Enum.each(state.identity_waiters, &GenServer.reply(&1, {:ok, identity}))
      {:ok, %{state | identity: identity, identity_waiters: []}}
    else
      _error -> {:error, :invalid_worker_handshake, state}
    end
  end

  defp accept_line(line, state) do
    with {:ok, decoded} <- decode_json(line),
         {:ok, observation} <- decode_observation(decoded) do
      {:ok, record_observation(state, observation)}
    else
      _error -> {:error, :invalid_worker_observation, state}
    end
  end

  defp decode_identity(
         %{
           "type" => "workerStarted",
           "workerRef" => worker_ref,
           "ceremonyId" => ceremony_id,
           "processId" => process_id,
           "osProcessStartIdentity" => start_identity
         } = decoded,
         state
       )
       when worker_ref == state.worker_ref and ceremony_id == state.ceremony_id and
              process_id == state.expected_process_id and is_integer(process_id) and
              process_id > 0 and
              is_binary(start_identity) and byte_size(start_identity) > 0 do
    if exact_keys?(decoded, [
         "type",
         "workerRef",
         "ceremonyId",
         "processId",
         "osProcessStartIdentity"
       ]) do
      {:ok,
       %{
         worker_ref: worker_ref,
         ceremony_id: ceremony_id,
         worker_pid: self(),
         provider_process_id: process_id,
         os_process_start_identity: start_identity
       }}
    else
      :error
    end
  end

  defp decode_identity(_decoded, _state), do: :error

  defp decode_observation(
         %{
           "type" => "publicChallengeReady",
           "authorizationUrl" => authorization_url
         } = decoded
       )
       when is_binary(authorization_url) and byte_size(authorization_url) > 0 do
    display_code = Map.get(decoded, "displayCode")

    if exact_keys?(decoded, ["type", "authorizationUrl"], ["displayCode"]) and
         (is_nil(display_code) or (is_binary(display_code) and byte_size(display_code) > 0)) do
      {:ok,
       %{
         kind: :public_challenge_ready,
         authorization_url: authorization_url,
         display_code: display_code
       }}
    else
      :error
    end
  end

  defp decode_observation(%{"type" => "responseDelivered", "responseKind" => kind} = decoded) do
    case {exact_keys?(decoded, ["type", "responseKind"]), response_kind(kind)} do
      {true, value} when not is_nil(value) ->
        {:ok, %{kind: :response_delivered, response_kind: value}}

      _other ->
        :error
    end
  end

  defp decode_observation(%{"type" => "validationResult", "accepted" => accepted} = decoded)
       when is_boolean(accepted) do
    failure = Map.get(decoded, "failureCode")

    valid_shape =
      exact_keys?(decoded, ["type", "accepted"], ["failureCode"]) and
        case accepted do
          true -> is_nil(failure)
          false -> nonempty?(failure)
        end

    if valid_shape do
      {:ok,
       %{
         kind: :validation_result,
         accepted: accepted,
         failure_code: failure
       }}
    else
      :error
    end
  end

  defp decode_observation(
         %{
           "type" => "candidateReady",
           "stagingRef" => staging_ref,
           "candidateDigest" => candidate_digest
         } = decoded
       )
       when is_binary(staging_ref) and byte_size(staging_ref) > 0 and
              is_binary(candidate_digest) and byte_size(candidate_digest) > 0 do
    if exact_keys?(decoded, ["type", "stagingRef", "candidateDigest"]) do
      {:ok,
       %{
         kind: :candidate_ready,
         staging_ref: staging_ref,
         candidate_digest: candidate_digest
       }}
    else
      :error
    end
  end

  defp decode_observation(_decoded), do: :error

  defp record_observation(state, observation) do
    sequence = state.next_sequence
    entry = {sequence, observation}

    if state.observer do
      send(
        state.observer,
        {:onboarding_worker_observation, state.worker_ref, sequence, observation}
      )
    end

    %{
      state
      | observations: state.observations ++ [entry],
        next_sequence: sequence + 1
    }
  end

  defp response_frame(:approved, nil), do: tagged_frame(:approved, <<>>)

  defp response_frame(:code, value) when is_binary(value) and byte_size(value) > 0 do
    tagged_frame(:code, value)
  end

  defp response_frame(_kind, _value), do: :error

  defp tagged_frame(kind, value) do
    {:ok, <<Map.fetch!(@response_tags, kind), byte_size(value)::unsigned-big-32, value::binary>>}
  end

  defp command_port(port, frame) do
    Port.command(port, frame)
  catch
    :error, :badarg -> false
  end

  defp find_worker(worker_ref, registry) do
    case OnboardingRegistry.worker_pid(worker_ref, registry) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, :not_found}
    end
  end

  defp fail_identity_waiters(state) do
    Enum.each(state.identity_waiters, &GenServer.reply(&1, {:error, :worker_closed}))
    %{state | identity_waiters: []}
  end

  defp response_kind("code"), do: :code
  defp response_kind("approved"), do: :approved
  defp response_kind(_kind), do: nil

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  defp exact_keys?(map, required, optional \\ []) do
    keys = Map.keys(map)
    Enum.all?(required, &(&1 in keys)) and Enum.all?(keys, &(&1 in required or &1 in optional))
  end

  defp closed_reason(reason) when reason in [:normal, :noproc], do: 0
  defp closed_reason(_reason), do: :closed

  defp decode_json(line) do
    case JSON.decode(line) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> :error
    end
  end

  defp split_lines(bytes) do
    parts = :binary.split(bytes, "\n", [:global])
    {lines, [buffer]} = Enum.split(parts, -1)
    {Enum.reject(lines, &(&1 == <<>>)), buffer}
  end

  defp default_command(opts) do
    base_dir = Keyword.get(opts, :base_dir, Application.fetch_env!(:tightbeam, :base_dir))
    [Path.join([base_dir, "bin", "tightbeam"])]
  end

  defp worker_args(opts) do
    args = [
      "onboarding-worker",
      "--ceremony-id",
      Keyword.fetch!(opts, :ceremony_id),
      "--provider",
      normalized_member!(opts, :provider),
      "--credential-kind",
      normalized_member!(opts, :credential_kind),
      "--worker-ref",
      Keyword.fetch!(opts, :worker_ref),
      "--deadline-ms",
      opts |> Keyword.fetch!(:deadline_ms) |> Integer.to_string()
    ]

    Enum.reduce([{:secret_ref, "--secret-ref"}, {:staging_ref, "--staging-ref"}], args, fn
      {key, flag}, acc ->
        case Keyword.get(opts, key) do
          nil -> acc
          value when is_binary(value) and byte_size(value) > 0 -> acc ++ [flag, value]
          _other -> raise ArgumentError, "#{key} must be a non-empty string"
        end
    end)
  end

  defp required_string!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _other -> raise ArgumentError, "#{key} must be a non-empty string"
    end
  end

  defp required_member!(opts, key, allowed) do
    value = normalized_member!(opts, key)
    if value in allowed, do: value, else: raise(ArgumentError, "invalid #{key}")
  end

  defp normalized_member!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_atom(value) -> Atom.to_string(value)
      value when is_binary(value) -> value
      _other -> raise ArgumentError, "#{key} must be an atom or string"
    end
  end

  defp open_command([executable | args])
       when is_binary(executable) and byte_size(executable) > 0 and is_list(args) do
    shell = System.find_executable("sh") || raise "sh is required to launch onboarding workers"
    command = Enum.map_join([executable | args], " ", &shell_escape/1)

    Port.open({:spawn_executable, shell}, [
      :binary,
      :exit_status,
      {:args, ["-c", "exec " <> command <> " 2>/dev/null"]}
    ])
  end

  defp open_command(_command), do: raise(ArgumentError, "cmd must be a non-empty argv list")

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
