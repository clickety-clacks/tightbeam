defmodule Tightbeam.RowReactions.Cutover do
  @moduledoc false
  alias Tightbeam.{RowReactions, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.{Snapshot, Store}
  @source "terminal-notices/v1"
  @root "terminal-child-owner-notification:"
  @reminder "terminal-child-owner-action-reminder:"

  def adopt(txn) do
    case Txn.q(txn, "SELECT 1 FROM row_reaction_cutovers WHERE source=?1", [@source]) do
      [[1]] ->
        :ok

      [] ->
        [[watermark]] = Txn.q(txn, "SELECT COALESCE(MAX(rowid),0) FROM wakes")
        # One finite source population. Never replay old closes that had no
        # output, and never grow this population on later rule publication.
        # Only notices still waiting to be delivered are adopted. Fired and
        # canceled history keeps the behavior it had before the cutover; on a
        # long-lived org that history is tens of thousands of rows, and adopting
        # it in this one startup transaction kept the gateway from starting.
        ids =
          Txn.q(
            txn,
            """
            SELECT wakeId FROM wakes WHERE rowid<=?1 AND state='pending' AND
              (obligationRef LIKE ?2 OR obligationRef LIKE ?3)
            ORDER BY CASE WHEN obligationRef LIKE ?2 THEN 0 ELSE 1 END,rowid
            """,
            [watermark, @root <> "%", @reminder <> "%"]
          )

        at = System.system_time(:millisecond)

        held =
          Enum.count(ids, fn [id] ->
            adopt_output(txn, Wakes.get_in_txn(txn, id), at) == "held"
          end)

        # Missing historical output is not evidence that a destination existed
        # at delivery. Mark consumed deliveries without manufacturing reminders.
        # Only deliveries the turn sweeper has not passed yet can be replayed
        # into admission, so only those need marking.
        for [id] <- unswept_deliveries(txn, watermark),
            event = RowReactions.delivery_event(txn, id),
            not is_nil(event),
            is_nil(Store.event(txn, event["org"], event["id"])) do
          Store.remember(txn, event, Snapshot.current(txn, event, %{}))
        end

        Txn.q(
          txn,
          "INSERT INTO row_reaction_cutovers(source,watermark,adoptedAt,heldCount) VALUES(?1,?2,?3,?4)",
          [@source, JSON.encode!(%{"wakeRowid" => watermark}), at, held]
        )

        :ok
    end
  end

  defp unswept_deliveries(txn, watermark) do
    Txn.q(
      txn,
      """
      SELECT wakeId FROM wakes WHERE rowid<=?1 AND deliveredTurnSeq>?2 AND
        (obligationRef LIKE ?3 OR obligationRef LIKE ?4)
      ORDER BY rowid
      """,
      [watermark, sweep_cursor(txn), @root <> "%", @reminder <> "%"]
    )
  end

  # The turn sweeper's durable cursor; absent means it has swept nothing yet.
  defp sweep_cursor(txn) do
    case Txn.q(txn, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='production_cursors'") do
      [[1]] ->
        case Txn.q(txn, "SELECT seq FROM production_cursors WHERE name='bubble'") do
          [[seq]] -> seq
          [] -> 0
        end

      [] ->
        0
    end
  end

  defp adopt_output(txn, wake, at) do
    {event, family, slot} =
      case wake.obligation_ref do
        @root <> _ -> {terminal_event(txn, wake), "terminal-handoff", "handoff"}
        @reminder <> root -> {reminder_event(txn, wake, root), "terminal-action", "reminder"}
      end

    unresolved = is_nil(event)

    event =
      event ||
        %{
          "id" => "legacy-unresolved:" <> wake.wake_id,
          "org" => wake.owner_user_id,
          "kind" => "legacy_unresolved",
          "at" => wake.created_at,
          "historical" => true,
          "source" => %{"kind" => "wake", "id" => wake.wake_id}
        }

    incomplete = not unresolved and Wakes.undelivered_notice_in_txn?(txn, wake.wake_id)

    status =
      cond do
        incomplete -> "pending"
        wake.state == "canceled" -> "canceled"
        is_integer(wake.delivered_turn_seq) -> "accepted"
        unresolved -> "held"
        wake.state == "pending" -> "pending"
        true -> "held"
      end

    facts = if unresolved, do: %{}, else: Snapshot.current(txn, event, %{})

    value =
      Map.new(
        ~w(wake_id session_key origin owner_user_id creator_session_key assignment_id work_item_id prompt due_at obligation_ref)a,
        fn key -> {Atom.to_string(key), Map.get(wake, key)} end
      )

    plan = %{
      identity: [event["org"], family, event["id"], slot],
      family: family,
      slot: slot,
      source_event_id: event["id"],
      kind: "notice",
      value: value,
      provenance: %{"source" => @source, "historical" => true}
    }

    result = %{
      "wake_id" => wake.wake_id,
      "adopted" => true,
      "requested_due_at" => wake.due_at,
      "delivery" =>
        cond do
          incomplete -> "undelivered"
          is_integer(wake.delivered_turn_seq) -> "delivered"
          true -> wake.state
        end
    }

    Store.adopt(txn, event, facts, plan, status, result, at)

    if status == "held" do
      Store.record(
        txn,
        %{"id" => Store.id(plan.identity)},
        "held",
        result,
        at,
        "historical source or actual delivery outcome is unproven"
      )
    end

    status
  end

  defp terminal_event(txn, wake) do
    case Wakes.terminal_source_in_txn(txn, wake.wake_id) do
      {:ok, terminal} ->
        after_row =
          Snapshot.assignment(txn, terminal.assignment_id)
          |> Map.merge(%{
            "state" => "closed",
            "outcome" => terminal.outcome,
            "closedAt" => terminal.terminal_at
          })

        %{
          "id" => "legacy-notice:" <> wake.wake_id,
          "org" => terminal.owner_user_id,
          "kind" => "assignment",
          "at" => terminal.terminal_at,
          "historical" => true,
          "source" => %{"kind" => terminal.source_kind, "id" => terminal.source_token},
          "generation" => terminal.source_token,
          "terminal" => stringify(terminal),
          "before" => nil,
          "after" => after_row,
          "principal" => %{"kind" => "process", "id" => "tightbeam"}
        }

      _ ->
        nil
    end
  end

  defp reminder_event(txn, wake, root) do
    predecessors = [
      root
      | Txn.q(txn, "SELECT wakeId FROM wakes WHERE obligationRef=?1", [@reminder <> root])
        |> List.flatten()
    ]

    Enum.find_value(predecessors, fn id ->
      predecessor = if id == root, do: "initial", else: id

      digest =
        :crypto.hash(
          :sha256,
          JSON.encode!(["terminal-child-owner-action-reminder", root, predecessor])
        )
        |> Base.encode16(case: :lower)

      if wake.wake_id == "w_terminal_action_" <> digest, do: RowReactions.delivery_event(txn, id)
    end)
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
