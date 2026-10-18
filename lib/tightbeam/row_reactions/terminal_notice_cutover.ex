defmodule Tightbeam.RowReactions.TerminalNoticeCutover do
  @moduledoc false
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.{Snapshot, Store}
  alias Tightbeam.Wakes

  @source "terminal-notice/v1"

  # Only an existing output is adopted. In particular, a closed assignment
  # without a notice is not an event to replay after a later rule election.
  def adopt_in_txn(txn, at) do
    adopt_population(
      txn,
      at,
      @source,
      "terminal-handoff",
      "handoff",
      "terminal-child-owner-notification:",
      &historical_event/2
    )

    adopt_population(
      txn,
      at,
      "terminal-action/v1",
      "terminal-action",
      "reminder",
      "terminal-child-owner-action-reminder:",
      &historical_delivery/2
    )
  end

  defp adopt_population(txn, at, source, family, slot, prefix, event_fun) do
    case Txn.q(txn, "SELECT 1 FROM row_reaction_cutovers WHERE source=?1", [source]) do
      [[1]] ->
        :ok

      [] ->
        ids =
          Txn.q(txn, "SELECT wakeId FROM wakes WHERE obligationRef LIKE ?1 ORDER BY rowid", [
            prefix <> "%"
          ])

        held =
          Enum.count(ids, fn [id] ->
            wake = Wakes.get_in_txn(txn, id)
            {event, resolved?} = event_fun.(txn, wake)

            status =
              cond do
                wake.state == "canceled" ->
                  "canceled"

                wake.state != "pending" or Wakes.notice_snapshot_exists_in_txn?(txn, id) ->
                  "accepted"

                resolved? ->
                  "pending"

                true ->
                  "held"
              end

            value =
              Map.new(
                ~w(wake_id session_key owner_user_id origin prompt due_at target_gate creator_session_key assignment_id work_item_id obligation_ref)a,
                fn key -> {Atom.to_string(key), Map.fetch!(wake, key)} end
              )

            # This value records the existing output, not a fallback policy.
            # The elected plan replaces it before a pending action is executed.
            plan = %{
              identity: {event["org"], family, event["id"], slot},
              family: family,
              source_event_id: event["id"],
              slot: slot,
              kind: "notice",
              value: value,
              rule: nil,
              provenance: %{"source" => source, "historical" => true}
            }

            Store.adopt_in_txn(
              txn,
              event,
              Snapshot.current(txn, event, %{}),
              plan,
              %{"wake_id" => id, "adopted" => true, "source_resolved" => resolved?},
              status,
              at
            )

            status == "held"
          end)

        Txn.q(
          txn,
          "INSERT INTO row_reaction_cutovers(source,watermark,adoptedAt,heldCount) VALUES(?1,?2,?3,?4)",
          [source, JSON.encode!(%{"wakeIds" => Enum.map(ids, &hd/1)}), at, held]
        )

        :ok
    end
  end

  defp historical_event(txn, wake) do
    base = %{
      "id" => "legacy_notice:" <> wake.wake_id,
      "org" => wake.owner_user_id,
      "historical" => true,
      "before" => nil,
      "wakeId" => wake.wake_id
    }

    case Wakes.legacy_terminal_source_in_txn(txn, wake) do
      {:ok, source} ->
        row = Snapshot.assignment_row(txn, source.assignment_id)
        # Revocation generations carry exact close evidence through reopen.
        # These fields come from that immutable source, never an assumed open
        # before-row or the current (possibly reopened) assignment state.
        closing = closing_fields(txn, source)
        after_row = Map.merge(row, closing)

        principal =
          cond do
            after_row["closedBySession"] ->
              %{"kind" => "session", "id" => after_row["closedBySession"]}

            after_row["closedByUser"] ->
              %{"kind" => "user", "id" => after_row["closedByUser"]}

            true ->
              %{
                "kind" => "process",
                "id" => String.replace_prefix(after_row["closedByProcess"], "process:", "")
              }
          end

        {Map.merge(base, %{
           "kind" => "assignment",
           "at" => source.terminal_at,
           "after" => after_row,
           "principal" => principal,
           "source" => %{"kind" => source.source_kind, "id" => source.source_token}
         }), true}

      :unresolved ->
        {Map.merge(base, %{
           "kind" => "legacy_unresolved",
           "at" => wake.created_at,
           "principal" => %{"kind" => "process", "id" => "tightbeam"}
         }), false}
    end
  end

  defp historical_delivery(txn, wake) do
    base = %{
      "id" => "legacy_notice:" <> wake.wake_id,
      "org" => wake.owner_user_id,
      "historical" => true,
      "before" => nil,
      "wakeId" => wake.wake_id,
      "principal" => %{"kind" => "process", "id" => "tightbeam"}
    }

    case Wakes.legacy_terminal_reminder_delivery_in_txn(txn, wake) do
      {:ok, delivered_id, turn} ->
        {Map.merge(base, %{
           "kind" => "wake_delivery",
           "at" => turn["createdAt"],
           "after" => Snapshot.wake(txn, delivered_id),
           "delivery" => %{
             "sessionKey" => turn["sessionKey"],
             "turnSeq" => turn["seq"],
             "carrierWakeId" => if(turn["wakeId"] == delivered_id, do: nil, else: turn["wakeId"])
           }
         }), true}

      :unresolved ->
        {Map.merge(base, %{"kind" => "legacy_unresolved", "at" => wake.created_at}), false}
    end
  end

  defp closing_fields(_txn, %{source_kind: "attest"} = source) do
    %{
      "state" => "closed",
      "outcome" => source.outcome,
      "closedAt" => source.terminal_at,
      "closingAttestId" => source.source_token,
      "closedBySession" => source.child_session_key,
      "closedByUser" => nil,
      "closedByProcess" => nil
    }
  end

  defp closing_fields(txn, %{source_kind: "assignment_revocation"} = source) do
    [[session, user, process]] =
      Txn.q(
        txn,
        "SELECT revokedBySession,revokedByUser,revokedByProcess FROM assignment_revocations WHERE id=?1 AND assignmentId=?2",
        [source.source_token, source.assignment_id]
      )

    %{
      "state" => "closed",
      "outcome" => source.outcome,
      "closedAt" => source.terminal_at,
      "closingAttestId" => nil,
      "closedBySession" => session,
      "closedByUser" => user,
      "closedByProcess" => process
    }
  end
end
