defmodule Tightbeam.ListenerLifecycle do
  @moduledoc "R8: observe bound Bandit instances without making restart decisions."
  use GenServer
  alias Tightbeam.{Diagnostics, RequestContext}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # Keep Bandit's own supervisor child semantics and pid. The generation is
  # carried by this instance's Plug options, never a global current-generation
  # lookup which could misattribute an old request after a restart.
  def listener_spec(opts, owner \\ __MODULE__) do
    %{Bandit.child_spec(opts) | start: {__MODULE__, :start_listener, [opts, owner]}}
  end

  def start_listener(opts, owner) do
    generation = RequestContext.id("lgen_")
    plug = Keyword.fetch!(opts, :plug)

    opts =
      opts
      |> Keyword.put_new(:display_plug, display_plug(plug))
      |> Keyword.put(:plug, {__MODULE__.Plug, {plug, generation}})

    case Bandit.start_link(opts) do
      {:ok, pid} = started ->
        # Pinned Bandit returns only after ThousandIsland's listener has bound.
        # A rejected bind never reaches this seam. Notification does not wait
        # for the recorder or affect the existing listener start result.
        GenServer.cast(owner, {:bound, pid, generation, System.system_time(:millisecond)})
        started

      other ->
        other
    end
  end

  defp display_plug({module, _}), do: module
  defp display_plug(module), do: module

  @impl true
  def init(opts) do
    {:ok, %{previous: nil, emit: Keyword.get(opts, :emit, &Diagnostics.emit/1)}}
  end

  @impl true
  def handle_cast({:bound, pid, generation, observed_at}, state) do
    prior = state.previous

    if prior do
      Process.demonitor(prior.monitor, [:flush])

      unless prior.stop_accepted do
        emit(
          state,
          "listener_predecessor_stop_unknown",
          generation,
          prior.generation,
          "listener_stop_unobserved",
          observed_at
        )
      end
    end

    monitor = Process.monitor(pid)
    emit(state, "listener_started", generation, prior && prior.generation, nil, observed_at)

    {:noreply,
     %{
       state
       | previous: %{pid: pid, monitor: monitor, generation: generation, stop_accepted: false}
     }}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, %{previous: prior} = state)
      when not is_nil(prior) and prior.monitor == ref and prior.pid == pid do
    # :noproc means the instance disappeared before we could observe it. Its
    # cause is unknown, not an inferred crash. A dropped stop is likewise not
    # replaced by a claim that the record exists.
    accepted =
      reason != :noproc and
        emit(
          state,
          "listener_stopped",
          prior.generation,
          nil,
          "listener_child_exit",
          System.system_time(:millisecond)
        ) == :accepted

    {:noreply, %{state | previous: %{prior | stop_accepted: accepted}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp emit(state, event, generation, prior, cause, observed_at) do
    state.emit.(%{
      event: event,
      observed_at_ms: observed_at,
      operation: "gateway.listener",
      listener_generation: generation,
      prior_listener_generation: prior,
      cause: cause,
      timeout_source: "none",
      budget_ms: nil,
      principal_kind: "internal",
      principal_ref: "internal:listener_lifecycle"
    })
  end
end

defmodule Tightbeam.ListenerLifecycle.Plug do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init({{module, opts}, generation}) when is_atom(module),
    do: {{module, module.init(opts)}, generation}

  def init({module, generation}) when is_atom(module), do: init({{module, []}, generation})
  def init({{fun, opts}, generation}) when is_function(fun, 2), do: {{fun, opts}, generation}
  def init({fun, generation}) when is_function(fun, 2), do: {{fun, []}, generation}

  @impl true
  def call(conn, {{plug, opts}, generation}) do
    conn =
      conn
      |> Plug.Conn.put_private(:tightbeam_listener_generation, generation)
      |> Plug.Conn.put_resp_header("x-tightbeam-listener-generation", generation)

    if is_atom(plug), do: plug.call(conn, opts), else: plug.(conn, opts)
  end
end
