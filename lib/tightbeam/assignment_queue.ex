defmodule Tightbeam.AssignmentQueue do
  @moduledoc "Read-only assignment queue evidence, restricted to its opener and owning user."

  alias Tightbeam.DB.Txn

  def query_in_txn(txn, assignment_id, principal, now) do
    case Txn.q(
           txn,
           """
           SELECT a.holderKey,a.openedBySession,s.ownerUserId
           FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey
           WHERE a.id=?1
           """,
           [assignment_id]
         ) do
      [[holder, opener, owner]] ->
        if authorized?(principal, opener, owner) do
          rows =
            Txn.q(
              txn,
              """
              SELECT origin,COUNT(*),MIN(createdAt) FROM turns
              WHERE sessionKey=?1 AND assignmentId=?2 AND status='queued'
              GROUP BY origin ORDER BY origin
              """,
              [holder, assignment_id]
            )

          oldest = rows |> Enum.map(fn [_, _, at] -> at end) |> Enum.min(fn -> nil end)

          {:ok,
           %{
             count: Enum.reduce(rows, 0, fn [_, count, _], sum -> sum + count end),
             oldestAgeMs: if(oldest, do: max(0, now - oldest), else: nil),
             senders: Enum.map(rows, fn [sender, _, _] -> sender end)
           }}
        else
          {:error, :forbidden}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp authorized?({:session, key}, opener, _owner), do: is_binary(opener) and key == opener
  defp authorized?({:user, id}, _opener, owner), do: is_binary(owner) and id == owner
  defp authorized?(_, _, _), do: false
end
