defmodule Tightbeam.RowReactions.Cutover do
  @moduledoc false
  alias Tightbeam.DB.Txn

  @source "terminal-notices/v1"

  # Terminal notices move to the row-reaction ledger from the cutover on.
  # Wakes that existed before it are not adopted: they keep the behavior they
  # had, and the operator gets a report of any that are still live. Adoption
  # walked the whole notice history inside the startup transaction, and on a
  # long-lived org that kept the gateway from starting.
  def adopt(txn) do
    case Txn.q(txn, "SELECT 1 FROM row_reaction_cutovers WHERE source=?1", [@source]) do
      [[1]] ->
        :ok

      [] ->
        [[watermark]] = Txn.q(txn, "SELECT COALESCE(MAX(rowid),0) FROM wakes")

        Txn.q(
          txn,
          "INSERT INTO row_reaction_cutovers(source,watermark,adoptedAt,heldCount) VALUES(?1,?2,?3,0)",
          [@source, JSON.encode!(%{"wakeRowid" => watermark}), System.system_time(:millisecond)]
        )

        :ok
    end
  end
end
