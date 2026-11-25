defmodule Tightbeam.Capacity.Collector do
  @moduledoc false

  alias Tightbeam.{DB, ProviderAccounts}
  alias Tightbeam.Capacity.{Selection, Store}
  alias Tightbeam.Firehose.Publisher

  @login_generation ~w(id host provider harness kind slot identityKey signedInAt)

  def firehose_sources, do: [{:record, "capacity.changed"}]

  @doc """
  Commit normalized usage only while it still belongs to the login that was read.

  This runs inside the caller's account lease for a refresh-capable read. The
  selection projection and retained sample commit together. A read-only probe
  can run beside an adapter, but a result from a superseded login is discarded.
  """
  def record(db, account, outcome, attempted_at, received_at, opts \\ []) do
    account_id = Map.fetch!(account, "id")

    case DB.transaction(db, fn txn ->
           current = ProviderAccounts.get(txn, account_id)

           if same_login?(account, current) do
             case Store.record_in_txn(txn, account_id, outcome, attempted_at, received_at) do
               {:ok, previous, next} ->
                 :ok = Selection.put_in_txn(txn, account_id, next)
                 publish_change(txn, opts[:hub], account_id, previous, next)
                 {:ok, previous, next}

               :superseded ->
                 :superseded
             end
           else
             :superseded
           end
         end) do
      {:ok, result} -> result
      {:error, _} -> {:error, %{code: "HISTORY_PERSISTENCE_ERROR"}}
    end
  end

  defp publish_change(txn, hub, id, previous, next) do
    if hub &&
         {previous.sample, previous.error, previous.retry_at} !=
           {next.sample, next.error, next.retry_at} do
      Publisher.source_invalidation_in_txn(
        txn,
        hub,
        "capacity.changed",
        next.completed_at,
        next.completed_at,
        %{"accountId" => id}
      )
    end

    :ok
  end

  defp same_login?(account, %{"loginState" => state} = current) when state != "removed",
    do: Map.take(current, @login_generation) == Map.take(account, @login_generation)

  defp same_login?(_, _), do: false
end
