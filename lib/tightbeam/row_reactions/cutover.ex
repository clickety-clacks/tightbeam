defmodule Tightbeam.RowReactions.Cutover do
  @moduledoc false
  require Logger
  alias Tightbeam.DB.Txn

  @source "terminal-notices/v1"
  @notice "(obligationRef LIKE 'terminal-child-owner-notification:%' OR obligationRef LIKE 'terminal-child-owner-action-reminder:%')"

  # Terminal notices move to the row-reaction ledger from the cutover on.
  # Wakes that existed before it are not adopted: they keep the behavior they
  # had, and the operator is told how many are still live. Adoption walked the
  # whole notice history inside the startup transaction, and on a long-lived
  # org that kept the gateway from starting.
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

        report(txn, watermark)
        :ok
    end
  end

  # One operator-visible line. Counting is advisory and must never fail the
  # cutover, so any error is reported instead of raised.
  defp report(txn, watermark) do
    [[pending]] =
      Txn.q(
        txn,
        "SELECT count(*) FROM wakes WHERE rowid<=?1 AND state='pending' AND #{@notice}",
        [watermark]
      )

    Logger.warning(
      "OPERATOR NOTICE: terminal-notice cutover recorded at wake rowid #{watermark}. " <>
        "#{pending} notice wake(s) created before this upgrade are still pending; they " <>
        "deliver as before but get no follow-up reminders from the new notice ledger. " <>
        "Earlier undelivered notices are not retried. To list the pending ones: SELECT " <>
        "wakeId,sessionKey,obligationRef FROM wakes WHERE rowid<=#{watermark} AND " <>
        "state='pending' AND #{@notice}"
    )
  rescue
    error ->
      Logger.warning(
        "OPERATOR NOTICE: terminal-notice cutover recorded at wake rowid #{watermark}; " <>
          "counting earlier live notices failed (#{Exception.message(error)})"
      )
  end
end
