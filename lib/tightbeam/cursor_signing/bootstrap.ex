defmodule Tightbeam.CursorSigning.Bootstrap do
  @moduledoc false

  use GenServer

  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]}
    }
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    provider = Keyword.fetch!(options, :provider)
    :ok = Tightbeam.CursorSigning.subscribe(provider, self())

    {:ok,
     %{
       supervisor: Keyword.fetch!(options, :supervisor),
       config: Keyword.fetch!(options, :config),
       admitted: false
     }}
  end

  @impl true
  def handle_info(:cursor_signing_healthy, %{admitted: false} = state) do
    :ok = Tightbeam.Application.admit_gateway(state.supervisor, state.config)
    {:noreply, %{state | admitted: true}}
  end

  def handle_info(:cursor_signing_healthy, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}
end
