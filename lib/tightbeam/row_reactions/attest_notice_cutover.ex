defmodule Tightbeam.RowReactions.AttestNoticeCutover do
  @moduledoc false
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.{Snapshot, Store}
  alias Tightbeam.Wakes

  @source "attest-notice/v1"

  # The retired producer rendered the immutable attest identity, kind and
  # assignment. Match that exact rendering and stored attribution; never parse
  # prose into a new source event or classify an unrelated authored message.
  def adopt_in_txn(txn, at) do
    case Txn.q(txn, "SELECT 1 FROM row_reaction_cutovers WHERE source=?1", [@source]) do
      [[1]] ->
        :ok

      [] ->
        wakes =
          Txn.q(txn, """
          SELECT w.wakeId,a.id FROM wakes w JOIN attests a
            ON a.assignmentId=w.assignmentId AND a.ts=w.dueAt
            AND ('Attest ' || a.id || ' (' || a.kind || ') was filed on assignment ' || a.assignmentId || '.')=w.prompt
            AND a.bySession IS w.creatorSessionKey
            AND CASE WHEN a.bySession IS NOT NULL THEN 'agent:' || a.bySession ELSE 'user:' || a.byUser END=w.origin
          ORDER BY w.rowid
          """)

        Enum.each(wakes, fn [id, attest_id] ->
          wake = Wakes.get_in_txn(txn, id)

          event =
            Snapshot.attest_event(txn, attest_id)
            |> Map.put("id", "legacy_notice:" <> id)
            |> Map.put("historical", true)

          status =
            cond do
              wake.state == "canceled" ->
                "canceled"

              wake.state != "pending" or Wakes.notice_snapshot_exists_in_txn?(txn, id) ->
                "accepted"

              true ->
                "pending"
            end

          value = %{
            "wake_id" => id,
            "session_key" => wake.session_key,
            "owner_user_id" => wake.owner_user_id,
            "origin" => wake.origin,
            "prompt" => wake.prompt,
            "due_at" => wake.due_at,
            "target_gate" => wake.target_gate,
            "creator_session_key" => wake.creator_session_key,
            "assignment_id" => wake.assignment_id,
            "work_item_id" => wake.work_item_id,
            "on_unavailable" => "skip"
          }

          # The one old attest notice maps to the status rail's receipt slot.
          # The rail itself decides whether this source still merits a notice;
          # progress/verdict/finish do not get a compiled fallback.
          plan = %{
            identity: {event["org"], "assignment-status", event["id"], "blocker-resolved"},
            family: "assignment-status",
            source_event_id: event["id"],
            slot: "blocker-resolved",
            kind: "notice",
            value: value,
            rule: nil,
            provenance: %{"source" => @source, "historical" => true}
          }

          Store.adopt_in_txn(
            txn,
            event,
            Snapshot.current(txn, event, %{}),
            plan,
            %{"wake_id" => id, "adopted" => true},
            status,
            at
          )
        end)

        [[row_id]] = Txn.q(txn, "SELECT COALESCE(MAX(rowid),0) FROM attests")

        Txn.q(
          txn,
          "INSERT INTO row_reaction_cutovers(source,watermark,adoptedAt,heldCount) VALUES(?1,?2,?3,?4)",
          [
            @source,
            JSON.encode!(%{"attestRowId" => row_id, "wakeIds" => Enum.map(wakes, &hd/1)}),
            at,
            0
          ]
        )

        :ok
    end
  end
end
