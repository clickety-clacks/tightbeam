defmodule Tightbeam.Capacity.Selection do
  @moduledoc false

  alias Tightbeam.DB.Txn

  @doc """
  Update Track A's selection projection in the observation transaction.

  A failure retains the previous window evidence, including the original send
  and receipt timestamps. A successful complete response replaces the window
  set so an omitted window does not masquerade as a current observation.
  """
  def put_in_txn(%Txn{} = txn, account_id, %{error: nil, sample: sample} = observation) do
    delete_in_txn(txn, account_id)

    Enum.each(sample.windows, fn window ->
      Txn.q(
        txn,
        """
        INSERT INTO capacity_windows
          (accountId, windowId, windowScope, model, usedPercent, resetAt, windowSeconds,
           observedAt, readAttemptAt, freshness)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        """,
        [
          account_id,
          window.id,
          window.scope,
          window.model,
          window.used_percent,
          window.resets_at,
          window.window_seconds,
          sample.observed_at,
          observation.attempted_at,
          freshness(window, sample.observed_at)
        ]
      )
    end)

    :ok
  end

  def put_in_txn(%Txn{} = txn, account_id, %{error: %{code: code}}) do
    Txn.q(
      txn,
      "UPDATE capacity_windows SET freshness = ?2 WHERE accountId = ?1",
      [account_id, code]
    )

    :ok
  end

  def delete_in_txn(%Txn{} = txn, account_id) do
    Txn.q(txn, "DELETE FROM capacity_windows WHERE accountId = ?1", [account_id])
    :ok
  end

  defp freshness(%{resets_at: reset}, observed) when is_integer(reset) and reset <= observed,
    do: "reset_passed"

  defp freshness(_, _), do: "current"
end
