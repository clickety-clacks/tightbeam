defmodule Tightbeam.AdapterHealthSnapshot do
  @moduledoc """
  Last published adapter health for the gateway's `/version` response.

  The value lives outside the coordinator process so reads remain available
  while that process is busy, exiting, or restarting. Each publication stores
  the projection and its timestamp together.
  """

  @type value :: %{adapters: map(), as_of: integer() | nil}

  @spec read(GenServer.server()) :: value()
  def read(coordinator) do
    :persistent_term.get(key(coordinator), %{adapters: %{}, as_of: nil})
  end

  @spec publish(GenServer.server(), map(), boolean()) :: :ok
  def publish(coordinator, adapters, force \\ false) do
    previous = read(coordinator)

    if force or previous.adapters != adapters do
      :persistent_term.put(key(coordinator), %{
        adapters: adapters,
        as_of: System.system_time(:millisecond)
      })
    end

    :ok
  end

  @spec clear(GenServer.server()) :: :ok
  def clear(coordinator) do
    :persistent_term.erase(key(coordinator))
    :ok
  end

  defp key(coordinator), do: {__MODULE__, coordinator}
end
