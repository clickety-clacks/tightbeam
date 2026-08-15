defmodule Tightbeam.OnboardingSupervisor do
  @moduledoc """
  Host-local lifetime owner for onboarding provider workers.

  Every child declares `restart: :temporary`. A provider exchange therefore
  has one process lifetime: an exit is evidence for the credential owner, not
  permission for the supervisor to launch a second exchange.
  """

  use DynamicSupervisor

  alias Tightbeam.{OnboardingRegistry, OnboardingWorker}

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Start the provider-worker supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Start exactly one temporary worker for the supplied `workerRef`."
  @spec start_worker(keyword(), GenServer.server()) :: DynamicSupervisor.on_start_child()
  def start_worker(opts, supervisor \\ __MODULE__) do
    opts = Keyword.put_new(opts, :registry, OnboardingRegistry)
    DynamicSupervisor.start_child(supervisor, {OnboardingWorker, opts})
  end

  @doc "Terminate the identified worker without launching a replacement."
  @spec terminate_worker(String.t(), GenServer.server(), atom()) :: :ok | {:error, :not_found}
  def terminate_worker(
        worker_ref,
        supervisor \\ __MODULE__,
        registry \\ OnboardingRegistry
      ) do
    case OnboardingRegistry.worker_pid(worker_ref, registry) do
      {:ok, pid} ->
        case DynamicSupervisor.terminate_child(supervisor, pid) do
          :ok -> :ok
          {:error, :not_found} -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
