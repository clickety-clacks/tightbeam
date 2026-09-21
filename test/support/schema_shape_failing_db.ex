defmodule Tightbeam.SchemaShapeTest.FailingDb do
  @moduledoc """
  A `Tightbeam.DB` interposer that forwards everything to the real server and
  fails ONE statement — the first whose SQL contains `fragment`.

  It exists because an interrupted bootstrap cannot be simulated by building
  its end state: the whole question is WHEN the stamp is written relative to
  the tables, and that is only observable by stopping a real run in the middle.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @impl true
  def init(opts), do: {:ok, opts |> Map.put(:armed, true) |> Map.put_new(:skip, 0)}

  @impl true
  def handle_call(message, _from, state) do
    if state.armed and holds?(message, state.fragment) do
      if state.skip > 0 do
        {:reply, GenServer.call(state.db, message), %{state | skip: state.skip - 1}}
      else
        {:reply, {:error, "interrupted"}, %{state | armed: false}}
      end
    else
      {:reply, GenServer.call(state.db, message), state}
    end
  end

  defp holds?(message, fragment) when is_tuple(message) do
    message |> Tuple.to_list() |> Enum.any?(&(is_binary(&1) and String.contains?(&1, fragment)))
  end

  defp holds?(_message, _fragment), do: false
end
