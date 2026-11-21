defmodule Tightbeam.HarklightListenerOutage do
  @moduledoc false
  alias Tightbeam.{DB, Org, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  def ensure_schema(db) do
    DB.execute(db, """
    CREATE TABLE IF NOT EXISTS harklight_listener_outages (
      handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
      episode TEXT NOT NULL,
      startedAt INTEGER NOT NULL,
      noticeWakeId TEXT,
      error TEXT NOT NULL,
      operation TEXT,
      diagnostic TEXT
    );
    """)
  end

  def start(db, handle, {error, operation, diagnostic}, now) do
    DB.transaction(db, fn txn ->
      case Txn.q(txn, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [handle]) do
        [[state]] when state != "complete" ->
          Txn.q(
            txn,
            """
            INSERT INTO harklight_listener_outages(handle,episode,startedAt,error,operation,diagnostic)
            VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(handle) DO NOTHING
            """,
            [handle, Tightbeam.Id.uuid4(), now, error, operation, diagnostic]
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
    end)
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

        [[session, state, error, operation, diagnostic, nil, _started]]
        when state != "complete" ->
          if recipient = recipient(txn, handle) do
            base = "w_harklight_notice_recovery_" <> handle

            id =
              if Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [base]) == [],
                do: base,
                else: base <> "_" <> episode

            detail =
              if operation in ["attach", "listen"] and is_binary(diagnostic),
                do: " #{String.upcase(operation)} failure: #{diagnostic}.",
                else: ""

            wake =
              Wakes.schedule_in_txn(txn, %{
                wake_id: id,
                session_key: recipient,
                creator_session_key: session,
                origin: "process:tightbeam",
                class: "blocker",
                due_at: now,
                prompt:
                  "Harklight listening for session #{session} and handle #{handle} stopped (#{error}).#{detail} Replies on this thread will not reach the current receiver while it is unavailable. Automatic recovery continues."
              })

            Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)

            Txn.q(txn, "UPDATE harklight_listener_outages SET noticeWakeId=?2 WHERE handle=?1", [
              handle,
              id
            ])
          end

          :notified

        _ ->
          :unchanged
      end
    end)
  end

  def finish(db, handle, resumed?, now) do
    DB.transaction(db, &finish_in_txn(&1, handle, resumed?, now))
  end

  def finish_in_txn(txn, handle, resumed?, now) do
    case Txn.q(
           txn,
           "SELECT episode,noticeWakeId FROM harklight_listener_outages WHERE handle=?1",
           [handle]
         ) do
      [[episode, notice]] when resumed? and is_binary(notice) ->
        if recipient = recipient(txn, handle) do
          wake =
            Wakes.schedule_in_txn(txn, %{
              wake_id: "w_harklight_listening_" <> episode,
              session_key: recipient,
              origin: "process:tightbeam",
              class: "fyi",
              due_at: now,
              prompt: "Harklight listening has resumed for conversation #{handle}."
            })

          Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)
        end

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
