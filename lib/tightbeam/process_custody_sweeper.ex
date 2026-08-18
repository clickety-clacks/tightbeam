defmodule Tightbeam.ProcessCustodySweeper do
  @moduledoc """
  Periodic liveness owner for durable managed-process custody.

  Boot recovery performs the first physical pass before runtime children start.
  This worker is the backstop after boot: every interval it asks the gateway to
  settle due launch deadlines, expired leases, and unresolved stop work through
  the same broker-proof and revision-CAS path as manual reconciliation.
  """

  use GenServer

  alias Tightbeam.Gateway

  defstruct [:config, :interval]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Run one custody sweep synchronously."
  @spec sweep(GenServer.server()) :: map()
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      config: Keyword.fetch!(opts, :config),
      interval: Keyword.get(opts, :interval, 1_000)
    }

    schedule(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:reply, Gateway.sweep_process_custody(state.config), state}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = Gateway.sweep_process_custody(state.config)
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
