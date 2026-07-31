defmodule Tightbeam.CommandEdge do
  @moduledoc """
  Non-blocking process-edge representations.

  A process stores an edge descriptor instead of a callback. Dispatch accepts
  only that descriptor and a command struct, so a raw function cannot stand in
  for either side of the boundary.

  The three delivery shapes deliberately have different results:

  * `signal/2` returns `:sent`; fire-and-forget has no completion result.
  * `job/2` returns `{:accepted, pid}` when supervised work was started.
  * `request/4` returns `{:pending, request_ids}`. `check_response/2`
    produces an answered transport request, never a completed lifecycle.
  """

  defmodule TurnContext do
    @moduledoc """
    Event-time turn attribution carried across an asynchronous edge.

    `assignment_id` is enforced even though `nil` is a valid captured value.
    This distinguishes an explicitly captured absence from omitted context.
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
        when session_key != @missing and turn_seq != @missing and assignment_id != @missing and
               observed_at != @missing,
        do: context
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
          %__MODULE__{adapter_key: adapter_key, token: token, observed_at: observed_at} = command
        )
        when adapter_key != @missing and token != @missing and observed_at != @missing,
        do: command
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
        when turn != @missing and message_id != @missing and status != @missing and
               error != @missing,
        do: command
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
            adapter_key: adapter_key,
            provider: provider,
            classification: classification,
            evidence: evidence,
            context: context,
            observed_at: observed_at
          } = command
        )
        when adapter_key != @missing and provider != @missing and classification != @missing and
               evidence != @missing and context != @missing and observed_at != @missing,
        do: command
  end

  defmodule Signal do
    @moduledoc false
    @enforce_keys [:target]
    defstruct [:target]

    @opaque t :: %__MODULE__{target: GenServer.server()}
  end

  defmodule Job do
    @moduledoc false
    @enforce_keys [:supervisor, :worker]
    defstruct [:supervisor, :worker]

    @opaque t :: %__MODULE__{
              supervisor: GenServer.server(),
              worker: {module(), atom(), [term()]}
            }
  end

  defmodule Request do
    @moduledoc false
    @enforce_keys [:target]
    defstruct [:target]

    @opaque t :: %__MODULE__{target: GenServer.server()}
  end

  @typedoc "Immutable data accepted by a tier edge."
  @type command :: AdapterReady.t() | TerminalPublication.t() | AuthEvent.t()

  @typedoc "Worker invoked by a job; the command is appended to these arguments."
  @type worker :: {module(), atom(), [term()]}

  @typedoc "A labelled asynchronous request has been sent, not completed."
  @type pending :: {:pending, :gen_server.request_id_collection()}

  @doc "Construct a fire-and-forget signal edge."
  @spec signal_to(GenServer.server()) :: Signal.t()
  def signal_to(target) when not is_function(target), do: %Signal{target: target}

  @doc "Construct a supervised no-reply job edge."
  @spec job_via(GenServer.server(), worker()) :: Job.t()
  def job_via(supervisor, {module, function, args} = worker)
      when not is_function(supervisor) and is_atom(module) and is_atom(function) and is_list(args),
      do: %Job{supervisor: supervisor, worker: worker}

  @doc "Construct a labelled asynchronous request edge."
  @spec request_to(GenServer.server()) :: Request.t()
  def request_to(target) when not is_function(target), do: %Request{target: target}

  @doc "Receiver-side validation for an injected signal edge."
  @spec validate_signal!(Signal.t()) :: Signal.t()
  def validate_signal!(%Signal{target: target} = edge) when not is_function(target), do: edge

  @doc "Receiver-side validation for an injected job edge."
  @spec validate_job!(Job.t()) :: Job.t()
  def validate_job!(%Job{supervisor: supervisor, worker: {module, function, args}} = edge)
      when not is_function(supervisor) and is_atom(module) and is_atom(function) and is_list(args),
      do: edge

  @doc "Receiver-side validation for an injected request edge."
  @spec validate_request!(Request.t()) :: Request.t()
  def validate_request!(%Request{target: target} = edge) when not is_function(target), do: edge

  @doc "Validate and return a supported command struct."
  @spec validate_command!(command()) :: command()
  def validate_command!(%AdapterReady{} = command), do: AdapterReady.validate!(command)

  def validate_command!(%TerminalPublication{turn: turn} = command) do
    TerminalPublication.validate!(command)
    TurnContext.validate!(turn)
    command
  end

  def validate_command!(%AuthEvent{context: :not_turn_scoped} = command),
    do: AuthEvent.validate!(command)

  def validate_command!(%AuthEvent{context: %TurnContext{} = context} = command) do
    AuthEvent.validate!(command)
    TurnContext.validate!(context)
    command
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
  Start a supervised command job with no reply to the sender.

  Acceptance means only that the Task supervisor started the worker.
  """
  @spec job(Job.t(), command()) :: {:accepted, pid()} | {:rejected, term()}
  def job(%Job{} = edge, command) do
    %Job{supervisor: supervisor, worker: worker} = validate_job!(edge)
    command = validate_command!(command)

    case Task.Supervisor.start_child(
           supervisor,
           __MODULE__,
           :perform_job,
           [worker, command],
           []
         ) do
      {:ok, pid} -> {:accepted, pid}
      {:error, reason} -> {:rejected, reason}
    end
  end

  @doc false
  @spec perform_job(worker(), command()) :: term()
  def perform_job({module, function, args}, command),
    do: apply(module, function, args ++ [validate_command!(command)])

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
    case :gen_server.check_response(message, request_ids, true) do
      {{:reply, reply}, label, request_ids} -> {:answered, label, reply, request_ids}
      {{:error, reason}, label, request_ids} -> {:failed, label, reason, request_ids}
      :no_request -> :no_request
      :no_reply -> :no_reply
    end
  end
end
