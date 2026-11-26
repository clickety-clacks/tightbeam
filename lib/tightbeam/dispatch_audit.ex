defmodule Tightbeam.DispatchAudit do
  @moduledoc """
  Writes the audits of successful reads beside the database owner's queue.

  A read runs on a read connection, so its audit must not be what fills the
  writer's queue and has other callers refused. One process per owner holds
  the audits and writes whatever is waiting in one transaction. Its call is the
  only one in the queue, however many reads are answered, and it waits out an
  overloaded owner. A private in-memory database has no read connections, so its
  reads queue on the owner already; it has no such process and its audits are
  queued there too.
  """

  use GenServer
  require Logger
  alias Tightbeam.DB

  @batch 256
  @waiting_limit 10_000

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  @doc """
  Queue one read's audit; `record` runs in a transaction on the owner. The
  audit is skipped, with a log line, once #{@waiting_limit} others are waiting.
  Returns `:no_process` for a database whose audits belong in its own queue.
  """
  @spec record(GenServer.server(), String.t(), (DB.Txn.t() -> term())) :: :ok | :no_process
  def record(db, verb, record) when is_function(record, 1) do
    with owner when is_pid(owner) <- GenServer.whereis(db),
         audits when is_pid(audits) <- :persistent_term.get({__MODULE__, owner}, nil),
         {:message_queue_len, waiting} <- Process.info(audits, :message_queue_len) do
      if waiting < @waiting_limit,
        do: send(audits, {:audit, record}),
        else: Logger.warning("dispatch audit for #{verb} skipped: too many audits waiting")

      :ok
    else
      _ -> :no_process
    end
  end

  @impl true
  def init(owner) do
    DB.owed_work()
    :persistent_term.put({__MODULE__, owner}, self())
    {:ok, owner}
  end

  @impl true
  def handle_info({:audit, record}, owner) do
    records = [record | waiting(@batch - 1)]

    case write(owner, records) do
      {:ok, _} -> :ok
      {:error, _} -> Logger.warning("#{length(records)} dispatch audits could not be recorded")
    end

    {:noreply, owner}
  end

  # The owner is linked to this process, so a late answer must not end it.
  defp write(owner, records) do
    DB.transaction(owner, fn txn -> Enum.each(records, & &1.(txn)) end)
  rescue
    error -> {:error, error}
  end

  defp waiting(0), do: []

  defp waiting(room) do
    receive do
      {:audit, record} -> [record | waiting(room - 1)]
    after
      0 -> []
    end
  end
end
