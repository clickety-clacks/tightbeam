defmodule Tightbeam.AssignmentOpenerAcceptance do
  @moduledoc """
  Accept opener accountability for one open assignment whose opener retired.

  The assignment stays open with its holder, attests and history. Only the
  current opener moves: `currentOpenerSessionKey` names the successor. A
  standing cannot-proceed the retired opener had to dispose, its undelivered
  notice wherever retirement sent it, an open question on the assignment
  waiting on the retired opener, and undelivered notices about the assignment
  still addressed to the retired opener move to the successor. The original `openedBySession`
  and expecter are never rewritten.

  The successor is the caller, or the session named with `toSessionKey`. The
  caller must be accountable for the assignment: the work item's delivery
  owner, the retired opener's current parent, the owning user, or an
  automation acting for that user. Repeating an acceptance that already took
  effect returns the current readback.
  """

  alias Tightbeam.{DB, EventLog, Org, Wakes}
  alias Tightbeam.DB.Txn

  defmodule Refusal do
    defexception [:code, :message]
  end

  def handle(db, %{principal: principal, params: params}) do
    assignment_id = params[:assignment_id]
    to = params[:to_session_key]

    cond do
      not nonblank?(assignment_id) ->
        refusal("invalid_message", "assignmentId is required")

      not (is_nil(to) or nonblank?(to)) ->
        refusal("invalid_message", "toSessionKey must be non-blank")

      true ->
        case DB.transaction(db, &accept_in_txn(&1, principal, assignment_id, to)) do
          {:ok, result} -> result
          {:error, %Refusal{code: code, message: message}} -> refusal(code, message)
          {:error, error} -> raise error
        end
    end
  end

  defp accept_in_txn(txn, principal, assignment_id, to) do
    assignment = fetch!(txn, assignment_id)
    opener = current_opener!(assignment)
    successor = successor!(principal, to)
    # A repeat of an acceptance that already took effect is a readback. It is
    # recognized first: after the move, the parent of the new opener is not the
    # parent that was accountable for the retired one.
    if successor == opener.session_key do
      response(txn, assignment_id, opener.original, nil, successor, principal, nil)
    else
      item = work_item(txn, assignment.work_item_id)
      owner = owner_user_id(txn, assignment, item)
      accountable!(txn, principal, assignment, opener, item, owner)
      active_successor!(txn, successor)
      retired_opener!(txn, opener.session_key)
      move!(txn, assignment_id, opener.session_key, successor, principal, item)
    end
  end

  defp move!(txn, assignment_id, from, to, principal, item) do
    Txn.q(
      txn,
      """
      UPDATE assignments SET currentOpenerSessionKey=?2
      WHERE id=?1 AND state='open' AND COALESCE(currentOpenerSessionKey,openedBySession)=?3
      """,
      [assignment_id, to, from]
    )

    if Txn.changes(txn) != 1, do: raise(Refusal, code: "assignment_changed", message: "retry")

    # A cannot-proceed the retired opener was due to dispose now waits on the
    # successor, so the holder's block has someone who can release it.
    Txn.q(
      txn,
      """
      UPDATE assignment_cannot_proceed SET disposerRef=?2
      WHERE assignmentId=?1 AND state='standing' AND disposerRef=?3
      """,
      [assignment_id, "session:" <> to, "session:" <> from]
    )

    # Open questions on this assignment that were waiting on the retired opener
    # now wait on the successor. The original expecter stays on the row.
    Txn.q(
      txn,
      """
      UPDATE decision_requests
      SET currentExpecterSessionKey=?2,rowVersion=rowVersion+1
      WHERE assignmentId=?1 AND status='open'
        AND COALESCE(currentExpecterSessionKey,expecterSessionKey)=?3
      """,
      [assignment_id, to, from]
    )

    # Undelivered notices about this assignment go to the successor: those still
    # addressed to the retired opener, and the notice of a standing block, which
    # retirement may already have handed to the retired opener's parent.
    Txn.q(
      txn,
      """
      SELECT wakeId FROM wakes
      WHERE assignmentId=?1 AND targetRole IS NULL
        AND consumer='prompt' AND reresolve IS NULL
        AND state='pending' AND deliveredTurnSeq IS NULL
        AND (sessionKey=?2 OR wakeId IN (
          SELECT decisionWakeId FROM assignment_cannot_proceed
          WHERE assignmentId=?1 AND state='standing'
        ))
      ORDER BY createdAt,wakeId
      """,
      [assignment_id, from]
    )
    |> Enum.each(fn [wake_id] ->
      case Wakes.readdress_pending_in_txn(txn, wake_id, to) do
        {:ok, _wake} ->
          :ok

        {:error, reason} ->
          raise Refusal, code: "wake_readdress_failed", message: inspect(reason)
      end
    end)

    event = "aoa_" <> Tightbeam.Id.uuid4()

    [[original]] =
      Txn.q(txn, "SELECT openedBySession FROM assignments WHERE id=?1", [assignment_id])

    response = response(txn, assignment_id, original, from, to, principal, event)

    :ok =
      EventLog.lifecycle_in_txn(
        txn,
        "assignment_opener_accepted",
        assignment_id,
        JSON.encode!(%{
          "eventId" => event,
          "assignmentId" => assignment_id,
          "principal" => response["principal"],
          "fromSessionKey" => from,
          "toSessionKey" => to
        })
      )

    if item, do: Wakes.readdress_accountability_notices_in_txn(txn, item.id)

    response
  end

  defp response(txn, assignment_id, original, from, to, principal, event) do
    [[state, holder]] =
      Txn.q(txn, "SELECT state,holderKey FROM assignments WHERE id=?1", [assignment_id])

    %{
      "assignmentId" => assignment_id,
      "state" => state,
      "holderKey" => holder,
      "openedBySession" => original,
      "previousOpenerSessionKey" => from,
      "currentOpenerSessionKey" => to,
      "principal" => principal_ref(principal),
      "eventId" => event,
      "changed" => not is_nil(event)
    }
  end

  defp fetch!(txn, assignment_id) do
    case Txn.q(
           txn,
           """
           SELECT state,openedByUser,openedBySession,currentOpenerSessionKey,workItemId
           FROM assignments WHERE id=?1
           """,
           [assignment_id]
         ) do
      [["open", by_user, by_session, current, item]] ->
        %{
          opened_by_user: by_user,
          opened_by_session: by_session,
          current_opener: current,
          work_item_id: item
        }

      [[_state, _, _, _, _]] ->
        raise Refusal, code: "assignment_closed", message: "assignment is already closed"

      [] ->
        raise Refusal, code: "unknown_assignment", message: "unknown assignment: #{assignment_id}"
    end
  end

  defp current_opener!(%{current_opener: current, opened_by_session: original})
       when is_binary(current),
       do: %{session_key: current, original: original}

  defp current_opener!(%{opened_by_session: original}) when is_binary(original),
    do: %{session_key: original, original: original}

  defp current_opener!(_assignment),
    do:
      raise(Refusal,
        code: "opener_not_session",
        message: "this assignment was opened by a user, not a session; it has no session opener"
      )

  defp successor!({:session, caller}, nil), do: caller

  defp successor!(_principal, nil),
    do:
      raise(Refusal,
        code: "invalid_message",
        message: "toSessionKey is required when the caller is not a session"
      )

  defp successor!(_principal, to), do: to

  defp work_item(_txn, nil), do: nil

  defp work_item(txn, id) do
    case Txn.q(
           txn,
           "SELECT ownerUserId,deliveryOwnerSessionKey FROM work_items WHERE id=?1",
           [id]
         ) do
      [[owner, delivery_owner]] -> %{id: id, owner: owner, delivery_owner: delivery_owner}
      [] -> nil
    end
  end

  defp owner_user_id(_txn, _assignment, %{owner: owner}) when is_binary(owner), do: owner

  defp owner_user_id(txn, assignment, _item) do
    session = assignment.current_opener || assignment.opened_by_session

    case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [session]) do
      [[owner]] -> owner
      [] -> nil
    end
  end

  defp accountable!(txn, principal, assignment, opener, item, owner) do
    if accountable?(txn, principal, assignment, opener, item, owner),
      do: :ok,
      else:
        raise(Refusal,
          code: "not_authorized",
          message:
            "only the work item's delivery owner, the retired opener's parent, " <>
              "or the owning user may accept this assignment's opener duty"
        )
  end

  defp accountable?(_txn, {:process, _}, _assignment, _opener, _item, _owner), do: true

  defp accountable?(txn, {:user, user}, _assignment, _opener, _item, owner),
    do: user == owner or Txn.q(txn, "SELECT isAdmin FROM users WHERE userId=?1", [user]) == [[1]]

  defp accountable?(txn, {:session, caller}, _assignment, opener, item, _owner) do
    match?(%{delivery_owner: ^caller}, item) or
      Txn.q(
        txn,
        "SELECT #{Org.current_parent_sql("s")} FROM sessions s WHERE s.sessionKey=?1",
        [opener.session_key]
      ) == [[caller]]
  end

  defp accountable?(_txn, _principal, _assignment, _opener, _item, _owner), do: false

  defp retired_opener!(txn, session_key) do
    case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [session_key]) do
      [["retired"]] ->
        :ok

      [["active"]] ->
        raise Refusal,
          code: "opener_active",
          message:
            "the current opener #{session_key} is still active; " <>
              "the owner can move its custody with session-custody-transfer"

      _ ->
        raise Refusal, code: "unknown_session", message: "unknown opener session #{session_key}"
    end
  end

  defp active_successor!(txn, session_key) do
    case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [session_key]) do
      [["active"]] ->
        :ok

      [[_state]] ->
        raise Refusal, code: "session_retired", message: "successor #{session_key} is retired"

      [] ->
        raise Refusal, code: "unknown_session", message: "unknown session #{session_key}"
    end
  end

  defp principal_ref({:session, key}), do: "session:" <> key
  defp principal_ref({:user, user}), do: "user:" <> user
  defp principal_ref({:process, name}), do: "process:" <> name
  defp principal_ref(_), do: nil

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp refusal(code, message), do: %{ok: false, code: code, message: message}
end
