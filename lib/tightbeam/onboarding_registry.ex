defmodule Tightbeam.OnboardingRegistry do
  @moduledoc """
  Live identity index for host-local onboarding workers.

  A worker owns two unique keys for its lifetime. The worker key prevents a
  duplicate launch for one `workerRef`; the identity key appears only after the
  launched process proves its PID in the private worker handshake. Durable
  ceremony state belongs to `Tightbeam.Credentials`, not this registry.
  """

  @type identity :: %{
          worker_ref: String.t(),
          ceremony_id: String.t(),
          worker_pid: pid(),
          provider_process_id: pos_integer(),
          os_process_start_identity: String.t()
        }

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    Supervisor.child_spec(
      {Registry, keys: :unique, name: name},
      id: name
    )
  end

  @doc "Start the unique worker registry."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Registry.start_link(keys: :unique, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec via(String.t(), atom()) :: {:via, Registry, {atom(), term()}}
  def via(worker_ref, registry \\ __MODULE__) when is_binary(worker_ref) do
    {:via, Registry, {registry, {:worker, worker_ref}}}
  end

  @doc false
  @spec register_identity(atom(), identity()) :: :ok | {:error, :identity_conflict}
  def register_identity(registry, %{worker_ref: worker_ref} = identity) do
    case Registry.register(registry, {:identity, worker_ref}, identity) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :identity_conflict}
    end
  end

  @doc "Return the live worker PID before or after its process handshake."
  @spec worker_pid(String.t(), atom()) :: {:ok, pid()} | :error
  def worker_pid(worker_ref, registry \\ __MODULE__) when is_binary(worker_ref) do
    case Registry.lookup(registry, {:worker, worker_ref}) do
      [{pid, _value}] when is_pid(pid) -> live(pid)
      [] -> :error
    end
  end

  @doc "Return the complete identity of a registered live worker."
  @spec lookup(String.t(), atom()) :: {:ok, identity()} | :error
  def lookup(worker_ref, registry \\ __MODULE__) when is_binary(worker_ref) do
    case Registry.lookup(registry, {:identity, worker_ref}) do
      [{pid, %{worker_pid: pid} = identity}] ->
        case live(pid) do
          {:ok, ^pid} -> {:ok, identity}
          :error -> :error
        end

      [] ->
        :error
    end
  end

  @doc "Prove that every stored identity names the same live worker."
  @spec lookup_exact(String.t(), String.t(), pos_integer(), String.t(), atom()) ::
          {:ok, pid()} | :error
  def lookup_exact(
        worker_ref,
        ceremony_id,
        provider_process_id,
        os_process_start_identity,
        registry \\ __MODULE__
      ) do
    case lookup(worker_ref, registry) do
      {:ok,
       %{
         ceremony_id: ^ceremony_id,
         provider_process_id: ^provider_process_id,
         os_process_start_identity: ^os_process_start_identity,
         worker_pid: pid
       }} ->
        {:ok, pid}

      _other ->
        :error
    end
  end

  defp live(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: :error
  end
end
