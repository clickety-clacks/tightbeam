defmodule Tightbeam.TurnFailureNotice do
  @moduledoc """
  Tell the session accountable for a failed turn that it failed, and why.

  A failed turn's `[turn failed]` marker lands in the failing session's own
  chat. Nobody else reads that chat, so a freshly dispatched assignment whose
  first turn failed sat unnoticed until its opener went looking. This module
  runs in the same transaction that commits the failed turn and schedules one
  prompt wake to the assignment's current opener, or else to the session's
  current parent, carrying the verbatim failure sentence.

  One notice per failed delivery. Automatic rate-limit retries share their
  root wake and health redeliveries reuse the source message id, so the wake
  id derived from that identity is the dedupe key: an existing wake means the
  recipient was already told.
  """

  alias Tightbeam.{Org, Wakes}
  alias Tightbeam.DB.Txn

  @origin "process:tightbeam"

  @doc """
  Schedule the failed-turn notice for `turn_seq` inside the terminal transaction.

  `sentence` is the failure text exactly as the `[turn failed]` marker shows it;
  when nil the turn's recorded error is used. Returns `{:scheduled, wake_id}`,
  `:duplicate`, or `:none` when the turn did not fail or nobody else is
  accountable for it.
  """
  @spec schedule_in_txn(Txn.t(), integer(), String.t() | nil) ::
          {:scheduled, String.t()} | :duplicate | :none
  def schedule_in_txn(%Txn{} = txn, turn_seq, sentence \\ nil) when is_integer(turn_seq) do
    case Txn.q(
           txn,
           """
           SELECT t.sessionKey,t.status,t.error,t.wakeId,t.messageId,t.assignmentId,
                  COALESCE(t.model,s.model),COALESCE(t.harness,s.harness),s.host,s.displayName
           FROM turns t JOIN sessions s ON s.sessionKey=t.sessionKey
           WHERE t.seq=?1
           """,
           [turn_seq]
         ) do
      [
        [
          session_key,
          "failed",
          error,
          wake_id,
          message_id,
          assignment_id,
          model,
          harness,
          host,
          display_name
        ]
      ] ->
        reason = sentence || error || "unknown failure"

        # The interrupted-outcome-unknown path already asks the parent whether
        # to redeliver; a second notice for the same failure is noise.
        if Tightbeam.HarnessHealth.classify_turn_failure(reason) == "interrupted-outcome-unknown" do
          :none
        else
          assignment = own_assignment_in_txn(txn, assignment_id, session_key)

          case recipient_in_txn(txn, session_key, assignment) do
            nil ->
              :none

            recipient ->
              notice_wake_id = notice_wake_id(txn, session_key, wake_id, message_id, turn_seq)

              if Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [notice_wake_id]) != [] do
                :duplicate
              else
                Wakes.schedule_in_txn(txn, %{
                  wake_id: notice_wake_id,
                  session_key: recipient,
                  origin: @origin,
                  prompt:
                    prompt(
                      session_key,
                      display_name,
                      assignment,
                      model,
                      harness,
                      host,
                      turn_seq,
                      reason
                    ),
                  due_at: System.system_time(:millisecond),
                  class: "blocker"
                })

                {:scheduled, notice_wake_id}
              end
          end
        end

      _ ->
        :none
    end
  end

  # Health attribution and custody both read only the executing session's own
  # assignment; a notification that merely names a child's card is not it.
  defp own_assignment_in_txn(_txn, nil, _session_key), do: nil

  defp own_assignment_in_txn(txn, assignment_id, session_key) do
    case Txn.q(
           txn,
           """
           SELECT id,subject,workItemId,COALESCE(currentOpenerSessionKey,openedBySession)
           FROM assignments WHERE id=?1 AND holderKey=?2
           """,
           [assignment_id, session_key]
         ) do
      [[id, subject, work_item_id, opener]] ->
        %{id: id, subject: subject, work_item_id: work_item_id, opener: opener}

      [] ->
        nil
    end
  end

  defp recipient_in_txn(txn, session_key, assignment) do
    opener = assignment && assignment.opener

    if active_other?(txn, opener, session_key) do
      opener
    else
      case Txn.q(
             txn,
             "SELECT #{Org.current_parent_sql("s")} FROM sessions s WHERE s.sessionKey=?1",
             [session_key]
           ) do
        [[parent]] -> if active_other?(txn, parent, session_key), do: parent
        _ -> nil
      end
    end
  end

  defp active_other?(_txn, nil, _session_key), do: false
  defp active_other?(_txn, session_key, session_key), do: false

  defp active_other?(txn, candidate, _session_key) do
    Txn.q(txn, "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'", [candidate]) ==
      [[1]]
  end

  defp notice_wake_id(txn, session_key, wake_id, message_id, turn_seq) do
    identity =
      case wake_id &&
             Txn.q(txn, "SELECT rootWakeId FROM wake_retry_attempts WHERE wakeId=?1", [wake_id]) do
        [[root]] when is_binary(root) -> ["wake", root]
        _ when is_binary(wake_id) -> ["wake", wake_id]
        _ when is_binary(message_id) -> ["message", message_id]
        _ -> ["turn", turn_seq]
      end

    digest =
      :crypto.hash(:sha256, JSON.encode!([session_key | identity]))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "w_turn_failure_" <> digest
  end

  defp prompt(session_key, display_name, assignment, model, harness, host, turn_seq, reason) do
    who = if is_binary(display_name), do: "#{session_key} (#{display_name})", else: session_key

    work =
      case assignment do
        %{id: id, subject: subject, work_item_id: work_item_id} ->
          " on assignment #{id}" <>
            if(is_binary(work_item_id), do: " (work item #{work_item_id})", else: "") <>
            if(is_binary(subject), do: ": #{subject}", else: "")

        nil ->
          ""
      end

    engine =
      [model && "model #{model}", harness && "harness #{harness}", host && "host #{host}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "[turn failed: #{session_key}]\n\n" <>
      "Session #{who} could not answer its turn #{turn_seq}#{work}.\n" <>
      if(engine != "", do: "Ran on #{engine}.\n", else: "") <>
      "Reason: #{reason}\n\n" <>
      "Tightbeam does not change its model or reassign it. If the failure persists, " <>
      "decide whether to retune, reassign or revoke. You are told once per failed delivery."
  end
end
