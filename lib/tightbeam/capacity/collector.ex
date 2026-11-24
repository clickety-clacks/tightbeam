defmodule Tightbeam.Capacity.Collector do
  @moduledoc false

  alias Tightbeam.{DB, ProviderAccounts}
  alias Tightbeam.Capacity.{Selection, Store}

  @login_generation ~w(id host provider harness kind slot identityKey signedInAt)

  @doc """
  Commit normalized usage only while it still belongs to the login that was read.

  This runs inside the caller's account lease for a refresh-capable read. The
  selection projection and retained sample commit together. A read-only probe
  can run beside an adapter, but a result from a superseded login is discarded.
  """
  def record(db, account, outcome, attempted_at, received_at) do
    account_id = Map.fetch!(account, "id")

    case DB.transaction(db, fn txn ->
           current = ProviderAccounts.get(txn, account_id)

           if same_login?(account, current) do
             case Store.record_in_txn(txn, account_id, outcome, attempted_at, received_at) do
               {:ok, previous, next} ->
                 :ok = Selection.put_in_txn(txn, account_id, next)
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

  defp same_login?(account, %{"loginState" => state} = current) when state != "removed",
    do: Map.take(current, @login_generation) == Map.take(account, @login_generation)

  defp same_login?(_, _), do: false
end
