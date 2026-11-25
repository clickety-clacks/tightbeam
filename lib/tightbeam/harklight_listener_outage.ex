defmodule Tightbeam.HarklightListenerOutage do
  @moduledoc false
  alias Tightbeam.{DB, Org, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  def ensure_schema(db) do
    with :ok <-
           DB.execute(db, """
           CREATE TABLE IF NOT EXISTS harklight_listener_outages (
             handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
             episode TEXT NOT NULL,
             startedAt INTEGER NOT NULL,
             noticeWakeId TEXT,
             error TEXT NOT NULL,
             operation TEXT,
             diagnostic TEXT,
             checkpoint INTEGER NOT NULL DEFAULT -1
           );
           CREATE TABLE IF NOT EXISTS harklight_outage_recoveries (
             handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
             episode TEXT NOT NULL
           );
           """),
         {:ok, columns} <- DB.query(db, "PRAGMA table_info(harklight_listener_outages)") do
      if Enum.any?(columns, fn [_, name | _] -> name == "checkpoint" end),
        do: :ok,
        else:
          DB.execute(
            db,
            "ALTER TABLE harklight_listener_outages ADD COLUMN checkpoint INTEGER NOT NULL DEFAULT -1"
          )
    end
  end

  def start_in_txn(txn, handle, {error, operation, diagnostic}, now) do
    case Txn.q(
           txn,
           """
           SELECT h.state,COALESCE(c.rev,-1) FROM harklight_wake_handles h
           LEFT JOIN harklight_feed_checkpoints c ON c.handle=h.handle
           WHERE h.handle=?1
             AND NOT EXISTS(SELECT 1 FROM harklight_feed_pauses p WHERE p.handle=h.handle)
             AND NOT EXISTS(SELECT 1 FROM harklight_feed_stops s WHERE s.handle=h.handle)
           """,
           [handle]
         ) do
      [[state, checkpoint]] when state != "complete" ->
        Txn.q(
          txn,
          """
          INSERT INTO harklight_listener_outages(handle,episode,startedAt,error,operation,diagnostic,checkpoint)
          VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(handle) DO NOTHING
          """,
          [handle, Tightbeam.Id.uuid4(), now, error, operation, diagnostic, checkpoint]
        )

        Txn.q(
          txn,
          "UPDATE harklight_wake_handles SET state='unavailable',lastError=?2,updatedAt=?3 WHERE handle=?1",
          [handle, if(diagnostic, do: error <> ": " <> diagnostic, else: error), now]
        )

        hd(
          Txn.q(
            txn,
            "SELECT handle,episode,startedAt,noticeWakeId FROM harklight_listener_outages WHERE handle=?1",
            [handle]
          )
        )

      _ ->
        nil
    end
  end

  def pending(db),
    do:
      DB.query(db, "SELECT handle,episode,startedAt,noticeWakeId FROM harklight_listener_outages")

  def notify(db, handle, episode, now, delay) do
    DB.transaction(db, fn txn ->
      case Txn.q(
             txn,
             """
             SELECT h.sessionKey,h.state,o.error,o.operation,o.diagnostic,o.noticeWakeId,o.startedAt
             FROM harklight_listener_outages o JOIN harklight_wake_handles h ON h.handle=o.handle
             WHERE o.handle=?1 AND o.episode=?2
             """,
             [handle, episode]
           ) do
        [[_, state, _, _, _, nil, started]] when state != "complete" and now < started + delay ->
          {:early, [handle, episode, started, nil]}

        [[_session, state, _, _, _, nil, _started]] when state != "complete" ->
          if recipient = recipient(txn, handle) do
            notify_receiver(txn, recipient, due_together(txn, handle, recipient, now, delay), now)
          end

          :notified

        _ ->
          :unchanged
      end
    end)
  end

  # One cause usually stops many conversations at nearly the same time. Those
  # that fall due within a tenth of the delay are told together. A later outage
  # always has its own notice.
  defp due_together(txn, handle, recipient, now, delay) do
    others =
      Txn.q(
        txn,
        """
        SELECT o.handle FROM harklight_listener_outages o
        JOIN harklight_wake_handles h ON h.handle=o.handle
        WHERE o.noticeWakeId IS NULL AND h.state<>'complete' AND o.handle<>?1 AND o.startedAt<=?2
        ORDER BY o.startedAt,o.handle
        """,
        [handle, now - delay + div(delay, 10)]
      )

    [handle | for([other] <- others, recipient(txn, other) == recipient, do: other)]
  end

  defp notify_receiver(txn, recipient, [handle | others] = handles, now) do
    [[session, episode, error, operation, diagnostic]] =
      Txn.q(
        txn,
        """
        SELECT h.sessionKey,o.episode,o.error,o.operation,o.diagnostic
        FROM harklight_listener_outages o JOIN harklight_wake_handles h ON h.handle=o.handle
        WHERE o.handle=?1
        """,
        [handle]
      )

    base = "w_harklight_notice_recovery_" <> handle

    id =
      if Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [base]) == [],
        do: base,
        else: base <> "_" <> episode

    detail =
      if operation == "listen" and is_binary(diagnostic),
        do: " #{String.upcase(operation)} failure: #{diagnostic}.",
        else: ""

    prompt =
      if others == [],
        do:
          "Harklight listening for session #{session} and handle #{handle} stopped (#{error}).#{detail} Replies on this thread will not reach the current receiver while it is unavailable. Automatic recovery continues.",
        else:
          "Harklight listening stopped for #{length(handles)} of your conversations: #{listed(handles)}. The first (#{handle}, session #{session}) stopped with #{error}.#{detail} Replies on these threads will not reach their current receiver while they are unavailable. Automatic recovery continues."

    schedule(txn, %{
      wake_id: id,
      session_key: recipient,
      creator_session_key: session,
      origin: "process:tightbeam",
      class: "blocker",
      due_at: now,
      prompt: prompt
    })

    for member <- handles,
        do:
          Txn.q(txn, "UPDATE harklight_listener_outages SET noticeWakeId=?2 WHERE handle=?1", [
            member,
            id
          ])
  end

  # Tells each receiver once about its reported conversations that are back. One
  # that has gone out again is told when that outage ends, reported or not.
  def announce_recoveries(db, now) do
    DB.transaction(db, fn txn ->
      rows =
        Txn.q(
          txn,
          """
          SELECT r.handle,r.episode FROM harklight_outage_recoveries r
          WHERE NOT EXISTS(SELECT 1 FROM harklight_listener_outages o WHERE o.handle=r.handle)
          ORDER BY r.handle
          """
        )

      # One that is out again keeps its row: its all-clear follows its recovery.
      Enum.each(rows, fn [handle, _] ->
        Txn.q(txn, "DELETE FROM harklight_outage_recoveries WHERE handle=?1", [handle])
      end)

      rows
      |> Enum.group_by(fn [handle, _] -> recipient(txn, handle) end)
      |> Enum.each(fn
        {nil, _} ->
          :ok

        {recipient, [[first, episode] | _] = back} ->
          handles = Enum.map(back, &hd/1)

          prompt =
            if length(handles) == 1,
              do: "Tightbeam is receiving Harklight updates again for conversation #{first}.",
              else:
                "Tightbeam is receiving Harklight updates again for #{length(handles)} of your conversations: #{listed(handles)}."

          schedule(txn, %{
            wake_id: "w_harklight_listening_" <> episode,
            session_key: recipient,
            origin: "process:tightbeam",
            class: "fyi",
            due_at: now,
            prompt: prompt
          })
      end)
    end)
  end

  defp listed(handles) do
    {shown, rest} = Enum.split(handles, 10)
    more = if rest == [], do: "", else: " and #{length(rest)} more"
    Enum.join(shown, ", ") <> more
  end

  defp schedule(txn, attrs) do
    wake = Wakes.schedule_in_txn(txn, attrs)
    Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)
  end

  def finish(db, handle, resumed?, now) do
    DB.transaction(db, &finish_in_txn(&1, handle, resumed?, now))
  end

  def captured_in_txn(txn, handle, rev, now) do
    case Txn.q(txn, "SELECT checkpoint FROM harklight_listener_outages WHERE handle=?1", [handle]) do
      [[checkpoint]] when rev > checkpoint ->
        finish_in_txn(txn, handle, true, now)
        true

      [[_checkpoint]] ->
        false

      [] ->
        true
    end
  end

  def finish_in_txn(txn, handle, resumed?, now) do
    case Txn.q(
           txn,
           "SELECT episode,noticeWakeId FROM harklight_listener_outages WHERE handle=?1",
           [handle]
         ) do
      [[episode, notice]] when resumed? and is_binary(notice) ->
        Txn.q(
          txn,
          "INSERT OR REPLACE INTO harklight_outage_recoveries(handle,episode) VALUES(?1,?2)",
          [handle, episode]
        )

      _ ->
        :ok
    end

    Txn.q(txn, "DELETE FROM harklight_listener_outages WHERE handle=?1", [handle])
    :ok
  end

  defp recipient(txn, handle) do
    case Txn.q(
           txn,
           "SELECT COALESCE(currentReceiverSessionKey,sessionKey) FROM harklight_wake_handles WHERE handle=?1",
           [handle]
         ) do
      [[receiver]] ->
        case Org.get_in_txn(txn, receiver) do
          %{state: "active"} -> receiver
          _ -> Supervision.ladder_target(txn, receiver, 1)
        end

      _ ->
        nil
    end
  end
end
