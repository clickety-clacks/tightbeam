defmodule Tightbeam.Harklight.ListenerSupervisor do
  @moduledoc false
  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def ensure(db, handle, supervisor \\ __MODULE__) do
    case Registry.lookup(Tightbeam.Harklight.ListenerRegistry, handle) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               supervisor,
               {Tightbeam.Harklight.Listener, db: db, handle: handle}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end
end

defmodule Tightbeam.Harklight.ListenerRecovery do
  @moduledoc false
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    send(self(), :recover)
    {:ok, %{db: Keyword.get(opts, :db, Tightbeam.DB)}}
  end

  @impl true
  def handle_info(:recover, state) do
    Enum.each(Tightbeam.Harklight.registered_handles(state.db), fn handle ->
      case Tightbeam.Harklight.ListenerSupervisor.ensure(state.db, handle) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error("could not resume Harklight listener for #{handle}: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end
end

defmodule Tightbeam.Harklight.Listener do
  @moduledoc false
  use GenServer
  require Logger

  def child_spec(opts) do
    handle = Keyword.fetch!(opts, :handle)

    %{
      id: {__MODULE__, handle},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def start_link(opts) do
    handle = Keyword.fetch!(opts, :handle)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Tightbeam.Harklight.ListenerRegistry, handle}}
    )
  end

  @impl true
  def init(opts) do
    handle = Keyword.fetch!(opts, :handle)
    db = Keyword.get(opts, :db, Tightbeam.DB)

    case System.find_executable("harklight-agent") do
      nil ->
        record_failure(db, handle, :harklight_agent_not_found)
        {:stop, :harklight_agent_not_found}

      executable ->
        start_listener(db, handle, executable)
    end
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> chunk)
    state = %{state | buffer: buffer}

    Enum.reduce_while(lines, {:continue, state}, fn line, {:continue, current} ->
      case trim_line_ending(line) do
        "" ->
          {:cont, {:continue, current}}

        entry_line ->
          case Tightbeam.Harklight.accept_line(current.db, current.handle, entry_line) do
            :complete -> {:halt, {:complete, current}}
            {:captured, _wake_id} -> {:cont, {:continue, current}}
            {:duplicate, _wake_id} -> {:cont, {:continue, current}}
            {:error, reason} -> {:halt, {:failed, reason, current}}
          end
      end
    end)
    |> case do
      {:continue, current} -> {:noreply, current}
      {:complete, current} -> {:stop, :normal, current}
      {:failed, reason, current} -> {:stop, {:invalid_harklight_entry, reason}, current}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:listener_exit, status}, state}
  end

  @impl true
  def terminate(reason, %{db: db, handle: handle, port: port}) do
    if reason != :normal do
      record_failure(db, handle, reason)
    end

    if Port.info(port), do: Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp record_failure(db, handle, reason) do
    case Tightbeam.Harklight.listener_failed(db, handle, reason) do
      :ok ->
        Logger.warning("Harklight listener for #{handle} stopped: #{inspect(reason)}")

      {:error, failure} ->
        Logger.error("could not record Harklight listener failure: #{inspect(failure)}")
    end
  end

  defp start_listener(db, handle, executable) do
    port_result =
      try do
        {:ok,
         Port.open({:spawn_executable, executable}, [
           :binary,
           :exit_status,
           :use_stdio,
           :hide,
           {:args, ["listen", "--follow", "--session", handle, "--controller"]}
         ])}
      rescue
        error -> {:error, {:listener_start_failed, Exception.message(error)}}
      end

    case port_result do
      {:ok, port} ->
        case Tightbeam.Harklight.listener_started(db, handle) do
          :ok ->
            {:ok, %{db: db, handle: handle, port: port, buffer: ""}}

          {:error, reason} ->
            Port.close(port)
            failure = {:listener_start_failed, reason}
            record_failure(db, handle, failure)
            {:stop, failure}
        end

      {:error, reason} ->
        record_failure(db, handle, reason)
        {:stop, reason}
    end
  end

  defp split_lines(buffer), do: split_lines(buffer, [])

  defp split_lines(buffer, lines) do
    case :binary.match(buffer, "\n") do
      {index, 1} ->
        line = binary_part(buffer, 0, index)
        rest_start = index + 1
        rest = binary_part(buffer, rest_start, byte_size(buffer) - rest_start)
        split_lines(rest, [line | lines])

      :nomatch ->
        {Enum.reverse(lines), buffer}
    end
  end

  defp trim_line_ending(line) do
    if String.ends_with?(line, "\r"),
      do: binary_part(line, 0, byte_size(line) - 1),
      else: line
  end
end
