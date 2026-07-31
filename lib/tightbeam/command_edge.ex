defmodule Tightbeam.CommandEdge do
  @moduledoc """
  Closed-target asynchronous process-edge representations.

  This module provides a seam where a process can store an edge descriptor
  instead of a callback. Dispatch targets are limited to local process
  identifiers and locally registered atoms, so target resolution cannot invoke
  caller-selected code in the dispatching process. Commands, worker arguments,
  request labels, and matched response data recursively reject functions.

  The three delivery shapes deliberately have different results:

  * `signal/2` returns `:sent`; fire-and-forget has no completion result.
  * `job/2` returns `:dispatched` after casting work to a pre-started dispatcher.
  * `request/4` returns `{:pending, request_ids}`. `check_response/2`
    produces an answered transport request, never a completed lifecycle.
  """

  defmodule TurnContext do
    @moduledoc """
    Event-time turn attribution carried across an asynchronous edge.

    `assignment_id` may be `nil` when that absence was captured at send time.
    Session key, turn sequence, and observation time must carry their declared
    values, so an empty context is not a capture.
    """

    @missing {:tightbeam_command_edge, :missing}
    @enforce_keys [:session_key, :turn_seq, :assignment_id, :observed_at]
    defstruct session_key: @missing,
              turn_seq: @missing,
              assignment_id: @missing,
              observed_at: @missing

    @type t :: %__MODULE__{
            session_key: String.t(),
            turn_seq: integer(),
            assignment_id: String.t() | nil,
            observed_at: integer()
          }

    @doc false
    @spec validate!(t()) :: t()
    def validate!(
          %__MODULE__{
            session_key: session_key,
            turn_seq: turn_seq,
            assignment_id: assignment_id,
            observed_at: observed_at
          } = context
        )
        when is_binary(session_key) and is_integer(turn_seq) and
               (is_binary(assignment_id) or is_nil(assignment_id)) and is_integer(observed_at),
        do: context

    def validate!(_context) do
      raise ArgumentError,
            "invalid TurnContext: expected a session key, turn sequence, optional assignment id, and observation time"
    end
  end

  defmodule AdapterReady do
    @moduledoc "Adapter readiness at the instant the ready edge fired."

    @missing {:tightbeam_command_edge, :missing}
    @enforce_keys [:adapter_key, :token, :observed_at]
    defstruct adapter_key: @missing, token: @missing, observed_at: @missing

    @type t :: %__MODULE__{
            adapter_key: {atom(), String.t(), String.t()},
            token: {pos_integer(), non_neg_integer()},
            observed_at: integer()
          }

    @doc false
    @spec validate!(t()) :: t()
    def validate!(
          %__MODULE__{
            adapter_key: {adapter, scope, host},
            token: {generation, revision},
            observed_at: observed_at
          } = command
        )
        when is_atom(adapter) and is_binary(scope) and is_binary(host) and
               is_integer(generation) and generation > 0 and is_integer(revision) and
               revision >= 0 and
               is_integer(observed_at),
        do: command

    def validate!(_command) do
      raise ArgumentError,
            "invalid AdapterReady: expected adapter key, positive generation token, and observation time"
    end
  end

  defmodule TerminalPublication do
    @moduledoc """
    A terminal publication with its event-time turn attribution.

    The complete `TurnContext` is required; a later worker never has to infer
    which turn or assignment the terminal belonged to.
    """

    @missing {:tightbeam_command_edge, :missing}
    @enforce_keys [:turn, :message_id, :status, :error]
    defstruct turn: @missing, message_id: @missing, status: @missing, error: @missing

    @type t :: %__MODULE__{
            turn: Tightbeam.CommandEdge.TurnContext.t(),
            message_id: String.t(),
            status: String.t(),
            error: term() | nil
          }

    @doc false
    @spec validate!(t()) :: t()
    def validate!(
          %__MODULE__{turn: turn, message_id: message_id, status: status, error: error} = command
        )
        when turn != @missing and is_binary(message_id) and is_binary(status) and
               error != @missing,
        do: command

    def validate!(_command) do
      raise ArgumentError,
            "invalid TerminalPublication: expected turn context, message id, status, and captured error"
    end
  end

  defmodule AuthEvent do
    @moduledoc """
    A classified authentication event captured at Adapter receipt.

    `context` must explicitly be either a complete `TurnContext` or
    `:not_turn_scoped`; omission cannot silently become a later lookup.
    """

    @missing {:tightbeam_command_edge, :missing}
    @enforce_keys [
      :adapter_key,
      :provider,
      :classification,
      :evidence,
      :context,
      :observed_at
    ]
    defstruct adapter_key: @missing,
              provider: @missing,
              classification: @missing,
              evidence: @missing,
              context: @missing,
              observed_at: @missing

    @type t :: %__MODULE__{
            adapter_key: {atom(), String.t(), String.t()},
            provider: atom(),
            classification: term(),
            evidence: term(),
            context: Tightbeam.CommandEdge.TurnContext.t() | :not_turn_scoped,
            observed_at: integer()
          }

    @doc false
    @spec validate!(t()) :: t()
    def validate!(
          %__MODULE__{
            adapter_key: {adapter, scope, host},
            provider: provider,
            classification: classification,
            evidence: evidence,
            context: context,
            observed_at: observed_at
          } = command
        )
        when is_atom(adapter) and is_binary(scope) and is_binary(host) and is_atom(provider) and
               classification != @missing and evidence != @missing and context != @missing and
               is_integer(observed_at),
        do: command

    def validate!(_command) do
      raise ArgumentError,
            "invalid AuthEvent: expected adapter key, provider, classification, evidence, context, and observation time"
    end
  end

  defmodule Signal do
    @moduledoc false
    @enforce_keys [:target]
    defstruct [:target]

    @opaque t :: %__MODULE__{target: Tightbeam.CommandEdge.target()}
  end

  defmodule Job do
    @moduledoc false
    @enforce_keys [:dispatcher, :worker]
    defstruct [:dispatcher, :worker]

    @opaque t :: %__MODULE__{
              dispatcher: Tightbeam.CommandEdge.target(),
              worker: {module(), atom(), [term()]}
            }
  end

  defmodule Request do
    @moduledoc false
    @enforce_keys [:target]
    defstruct [:target]

    @opaque t :: %__MODULE__{target: Tightbeam.CommandEdge.target()}
  end

  defmodule JobDispatcher do
    @moduledoc """
    Pre-started owner of the blocking Task supervisor interaction.

    Callers cast job data here and immediately resume their receive loops. This
    process, rather than the caller, waits for `Task.Supervisor.start_child/5`.
    """

    use GenServer

    @doc "Start a dispatcher for jobs supervised by `task_supervisor`."
    @spec start_link(GenServer.server()) :: GenServer.on_start()
    def start_link(task_supervisor), do: GenServer.start_link(__MODULE__, task_supervisor)

    @impl true
    def init(task_supervisor), do: {:ok, task_supervisor}

    @impl true
    def handle_cast({:tightbeam_command_job, worker, command}, task_supervisor) do
      _result =
        Task.Supervisor.start_child(
          task_supervisor,
          Tightbeam.CommandEdge,
          :perform_job,
          [worker, command],
          []
        )

      {:noreply, task_supervisor}
    end
  end

  @typedoc "Immutable data accepted by a tier edge."
  @type command :: AdapterReady.t() | TerminalPublication.t() | AuthEvent.t()

  @typedoc "A local process identifier or locally registered process name."
  @type target :: pid() | atom()

  @typedoc "Worker invoked by a job; the command is appended to these arguments."
  @type worker :: {module(), atom(), [term()]}

  @typedoc "A labelled asynchronous request has been sent, not completed."
  @type pending :: {:pending, :gen_server.request_id_collection()}

  @doc "Construct a fire-and-forget signal edge to a local target."
  @spec signal_to(target()) :: Signal.t()
  def signal_to(target), do: validate_signal!(%Signal{target: target})

  @doc "Construct a no-reply job edge through a local pre-started `JobDispatcher`."
  @spec job_via(target(), worker()) :: Job.t()
  def job_via(dispatcher, {module, function, args} = worker)
      when is_atom(module) and is_atom(function) and is_list(args),
      do: validate_job!(%Job{dispatcher: dispatcher, worker: worker})

  @doc "Construct a labelled asynchronous request edge to a local target."
  @spec request_to(target()) :: Request.t()
  def request_to(target), do: validate_request!(%Request{target: target})

  @doc "Receiver-side validation for an injected signal edge."
  @spec validate_signal!(Signal.t()) :: Signal.t()
  def validate_signal!(edge) do
    validate_data!(edge)
    validate_signal_shape!(edge)
  end

  @doc "Receiver-side validation for an injected job edge."
  @spec validate_job!(Job.t()) :: Job.t()
  def validate_job!(edge) do
    validate_data!(edge)
    validate_job_shape!(edge)
  end

  @doc "Receiver-side validation for an injected request edge."
  @spec validate_request!(Request.t()) :: Request.t()
  def validate_request!(edge) do
    validate_data!(edge)
    validate_request_shape!(edge)
  end

  @doc "Validate and return a supported command struct."
  @spec validate_command!(command()) :: command()
  def validate_command!(command) do
    validate_data!(command)
    validate_command_shape!(command)
  end

  defp validate_command_shape!(%AdapterReady{} = command), do: AdapterReady.validate!(command)

  defp validate_command_shape!(%TerminalPublication{turn: turn} = command) do
    TerminalPublication.validate!(command)
    TurnContext.validate!(turn)
    command
  end

  defp validate_command_shape!(%AuthEvent{context: :not_turn_scoped} = command),
    do: AuthEvent.validate!(command)

  defp validate_command_shape!(%AuthEvent{context: %TurnContext{} = context} = command) do
    AuthEvent.validate!(command)
    TurnContext.validate!(context)
    command
  end

  defp validate_command_shape!(_command) do
    raise ArgumentError, "unsupported command edge command"
  end

  @doc """
  Send a fire-and-forget command.

  `:sent` states only that the cast was emitted. This API has no completed
  lifecycle result.
  """
  @spec signal(Signal.t(), command()) :: :sent
  def signal(%Signal{} = edge, command) do
    %Signal{target: target} = validate_signal!(edge)
    command = validate_command!(command)
    GenServer.cast(target, {:tightbeam_command, command})
    :sent
  end

  @doc """
  Dispatch a supervised command job with no reply to the sender.

  `:dispatched` means only that the command was cast to the pre-started
  `JobDispatcher`. The caller never waits for the dispatcher or its Task
  supervisor, and the result says nothing about worker start or completion.
  """
  @spec job(Job.t(), command()) :: :dispatched
  def job(%Job{} = edge, command) do
    %Job{dispatcher: dispatcher, worker: worker} = validate_job!(edge)
    command = validate_command!(command)

    GenServer.cast(dispatcher, {:tightbeam_command_job, worker, command})
    :dispatched
  end

  @doc false
  @spec perform_job(worker(), command()) :: term()
  def perform_job(worker, command) do
    {module, function, args} = validate_worker!(worker)
    apply(module, function, args ++ [validate_command!(command)])
  end

  @doc """
  Send a labelled asynchronous request and add it to `request_ids`.

  The caller remains in its receive loop. The returned collection represents
  pending work; use `check_response/2` when mailbox messages arrive.
  """
  @spec request(
          Request.t(),
          command(),
          label :: term(),
          :gen_server.request_id_collection()
        ) :: pending()
  def request(%Request{} = edge, command, label, request_ids) do
    %Request{target: target} = validate_request!(edge)
    command = validate_command!(command)
    label = validate_data!(label)
    request_ids = validate_request_ids!(request_ids)

    request_ids =
      :gen_server.send_request(
        target,
        {:tightbeam_command, command},
        label,
        request_ids
      )

    {:pending, request_ids}
  end

  @doc "Check a mailbox message against a labelled request collection."
  @spec check_response(term(), :gen_server.request_id_collection()) ::
          {:answered, label :: term(), reply :: term(), :gen_server.request_id_collection()}
          | {:failed, label :: term(), reason :: term(), :gen_server.request_id_collection()}
          | :no_request
          | :no_reply
  def check_response(message, request_ids) do
    request_ids = validate_request_ids!(request_ids)

    case :gen_server.check_response(message, request_ids, true) do
      {{:reply, reply}, label, request_ids} ->
        {:answered, validate_data!(label), validate_data!(reply), request_ids}

      {{:error, reason}, label, request_ids} ->
        {:failed, validate_data!(label), validate_data!(reason), request_ids}

      :no_request ->
        :no_request

      :no_reply ->
        :no_reply
    end
  end

  @doc """
  Abandon every outstanding request in a collection without waiting.

  This consumes responses that have already arrived, then uses
  `:gen_server.receive_response/3` with a zero timeout and deletion enabled to
  abandon the remaining request aliases. After this returns, discard the
  collection; later replies will not be delivered to the caller's mailbox on
  alias-capable OTP nodes.
  """
  @spec abandon_requests(:gen_server.request_id_collection()) :: :abandoned
  def abandon_requests(request_ids) do
    case :gen_server.receive_response(request_ids, 0, true) do
      {_response, _label, request_ids} -> abandon_requests(request_ids)
      :timeout -> :abandoned
      :no_request -> :abandoned
    end
  end

  defp validate_signal_shape!(%Signal{target: target} = edge) do
    validate_target!(target)
    edge
  end

  defp validate_signal_shape!(_edge), do: raise(ArgumentError, "invalid signal edge")

  defp validate_job_shape!(%Job{dispatcher: dispatcher, worker: worker} = edge) do
    validate_target!(dispatcher)
    validate_worker!(worker)
    edge
  end

  defp validate_job_shape!(_edge), do: raise(ArgumentError, "invalid job edge")

  defp validate_request_shape!(%Request{target: target} = edge) do
    validate_target!(target)
    edge
  end

  defp validate_request_shape!(_edge), do: raise(ArgumentError, "invalid request edge")

  defp validate_target!(target) when is_pid(target) or is_atom(target), do: target

  defp validate_target!(_target) do
    raise ArgumentError, "command edge target must be a pid or locally registered atom"
  end

  defp validate_worker!({module, function, args} = worker)
       when is_atom(module) and is_atom(function) and is_list(args) do
    validate_data!(args)
    worker
  end

  defp validate_worker!(_worker), do: raise(ArgumentError, "invalid command job worker")

  defp validate_request_ids!(request_ids) do
    request_ids
    |> :gen_server.reqids_to_list()
    |> Enum.each(fn {_request_id, label} -> validate_data!(label) end)

    request_ids
  end

  defp validate_data!(term) when is_function(term) do
    raise ArgumentError, "command edge data cannot contain functions"
  end

  defp validate_data!([]), do: []

  defp validate_data!([head | tail] = term) do
    validate_data!(head)
    validate_data!(tail)
    term
  end

  defp validate_data!(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.each(&validate_data!/1)
    term
  end

  defp validate_data!(term) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.each(fn {key, value} ->
      validate_data!(key)
      validate_data!(value)
    end)

    term
  end

  defp validate_data!(term), do: term
end
