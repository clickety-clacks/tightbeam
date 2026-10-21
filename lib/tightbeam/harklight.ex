defmodule Tightbeam.Harklight do
  @moduledoc false

  alias Tightbeam.{DB, Org}
  alias Tightbeam.DB.Txn
  alias Tightbeam.EventLog
  alias Tightbeam.Wakes

  @ddl """
  CREATE TABLE IF NOT EXISTS harklight_handles (
    sessionHandle TEXT PRIMARY KEY,
    recipientSessionKey TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('listening','complete')),
    ownerNotifiedAt INTEGER,
    createdAt INTEGER NOT NULL,
    completedAt INTEGER
  );

  CREATE TABLE IF NOT EXISTS harklight_requests (
    sessionHandle TEXT NOT NULL,
    senderId TEXT NOT NULL,
    messageId TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    PRIMARY KEY (sessionHandle, senderId, messageId),
    FOREIGN KEY (sessionHandle) REFERENCES harklight_handles(sessionHandle)
  );

  CREATE TABLE IF NOT EXISTS harklight_entries (
    senderId TEXT NOT NULL,
    messageId TEXT NOT NULL,
    sessionHandle TEXT NOT NULL,
    eventId TEXT NOT NULL,
    requestRevision TEXT NOT NULL,
    kind TEXT NOT NULL,
    author TEXT NOT NULL,
    delivered INTEGER NOT NULL CHECK (delivered IN (0,1)),
    acted INTEGER NOT NULL CHECK (acted IN (0,1)),
    rawEvent TEXT NOT NULL,
    wakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
    capturedAt INTEGER NOT NULL,
    PRIMARY KEY (senderId, messageId, sessionHandle, eventId),
    FOREIGN KEY (sessionHandle) REFERENCES harklight_handles(sessionHandle)
  );
  """

  @type db :: GenServer.server()

  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc false
  def register(db, call, opts \\ []) do
    with {:session, recipient} <- Map.get(call, :principal),
         handle when is_binary(handle) and handle != "" <- call.params[:session_handle],
         sender_id when is_binary(sender_id) and sender_id != "" <- call.params[:sender_id],
         message_id when is_binary(message_id) and message_id != "" <- call.params[:message_id],
         {:ok, registration} <-
           DB.transaction(db, fn txn ->
             register_in_txn(txn, recipient, handle, sender_id, message_id)
           end),
         {:ok, result} <- registration,
         {:ok, listener} <- maybe_start_listener(db, handle, result.state, opts) do
      Map.merge(result, %{listener: listener})
    else
      {:error, code, message} ->
        %{code: code, message: message}

      {:error, reason} ->
        %{code: "harklight_registration_failed", message: inspect(reason)}

      _ ->
        %{
          code: "session_required",
          message: "register a Harklight request from the Tightbeam session that sent it"
        }
    end
  end

  @doc false
  def register_in_txn(%Txn{} = txn, recipient, handle, sender_id, message_id) do
    case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [recipient]) do
      [["active"]] -> register_active_in_txn(txn, recipient, handle, sender_id, message_id)
      _ -> {:error, "session_unavailable", "the registering Tightbeam session is not active"}
    end
  end

  defp register_active_in_txn(txn, recipient, handle, sender_id, message_id) do
    case Txn.q(
           txn,
           "SELECT recipientSessionKey,state FROM harklight_handles WHERE sessionHandle=?1",
           [handle]
         ) do
      [] ->
        now = now()

        Txn.q(
          txn,
          "INSERT INTO harklight_handles (sessionHandle,recipientSessionKey,state,createdAt) VALUES (?1,?2,'listening',?3)",
          [handle, recipient, now]
        )

        insert_request(txn, handle, sender_id, message_id, now)

        {:ok,
         %{handle: handle, recipient_session_key: recipient, state: "listening", existing: false}}

      [[^recipient, state]] ->
        existing_request? =
          case Txn.q(
                 txn,
                 "SELECT 1 FROM harklight_requests WHERE sessionHandle=?1 AND senderId=?2 AND messageId=?3",
                 [handle, sender_id, message_id]
               ) do
            [[1]] -> true
            [] -> false
          end

        cond do
          state == "complete" and not existing_request? ->
            {:error, "handle_complete", "a completed Harklight handle cannot be registered again"}

          true ->
            insert_request(txn, handle, sender_id, message_id, now())

            {:ok,
             %{
               handle: handle,
               recipient_session_key: recipient,
               state: state,
               existing: existing_request?
             }}
        end

      [[_other_recipient, _state]] ->
        {:error, "recipient_conflict", "the Harklight handle is already bound to another session"}
    end
  end

  @doc false
  def registered_handles(db \\ Tightbeam.DB) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT sessionHandle FROM harklight_handles WHERE state='listening' ORDER BY createdAt,sessionHandle"
      )

    Enum.map(rows, fn [handle] -> handle end)
  end

  @doc false
  def accept_line(db, handle, line) when is_binary(line) do
    with {:ok, event} when is_map(event) <- JSON.decode(line) do
      if idle_line?(event) do
        complete(db, handle)
      else
        capture(db, handle, event, line)
      end
    else
      _ -> {:error, :invalid_json_line}
    end
  end

  @doc false
  def capture(db, handle, event, raw_event) do
    with {:ok, entry} <- event_identity(event) do
      DB.transaction(db, fn txn -> capture_in_txn(txn, handle, entry, raw_event) end)
      |> case do
        {:ok, result} -> result
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc false
  def capture_in_txn(%Txn{} = txn, handle, entry, raw_event) do
    case Txn.q(
           txn,
           "SELECT recipientSessionKey,state FROM harklight_handles WHERE sessionHandle=?1",
           [handle]
         ) do
      [[recipient, "listening"]] ->
        case Txn.q(
               txn,
               "SELECT wakeId FROM harklight_entries WHERE senderId=?1 AND messageId=?2 AND sessionHandle=?3 AND eventId=?4",
               [entry.sender_id, entry.message_id, handle, entry.event_id]
             ) do
          [[wake_id]] ->
            {:duplicate, wake_id}

          [] ->
            now = now()

            due_at =
              case Txn.q(
                     txn,
                     "SELECT MAX(w.dueAt) FROM harklight_entries e JOIN wakes w ON w.wakeId=e.wakeId WHERE e.sessionHandle=?1",
                     [handle]
                   ) do
                [[nil]] -> now
                [[last_due_at]] -> max(now, last_due_at + 1)
              end

            prompt = build_prompt(handle, entry, raw_event)

            wake =
              Wakes.schedule_in_txn(txn, %{
                session_key: recipient,
                origin: "process:tightbeam",
                creator_session_key: recipient,
                prompt: prompt,
                due_at: due_at
              })

            Txn.q(
              txn,
              """
              INSERT INTO harklight_entries
                (senderId,messageId,sessionHandle,eventId,requestRevision,kind,author,delivered,acted,rawEvent,wakeId,capturedAt)
              VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
              """,
              [
                entry.sender_id,
                entry.message_id,
                handle,
                entry.event_id,
                JSON.encode!(entry.request_revision),
                entry.kind,
                entry.author,
                bool_int(entry.delivered),
                bool_int(entry.acted),
                raw_event,
                wake.wake_id,
                now
              ]
            )

            {:captured, wake.wake_id}
        end

      [[_recipient, "complete"]] ->
        {:error, :handle_complete}

      [] ->
        {:error, :unknown_handle}
    end
  end

  @doc false
  def complete(db, handle) do
    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        "UPDATE harklight_handles SET state='complete',completedAt=?2 WHERE sessionHandle=?1 AND state='listening'",
        [handle, now()]
      )

      :complete
    end)
    |> case do
      {:ok, :complete} -> :complete
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def captured_wake_in_txn?(%Txn{} = txn, wake_id) when is_binary(wake_id) do
    Txn.q(txn, "SELECT 1 FROM harklight_entries WHERE wakeId=?1", [wake_id]) == [[1]]
  end

  def captured_wake_in_txn?(%Txn{}, _wake_id), do: false

  @doc false
  def prepare_delivery_in_txn(%Txn{} = txn, wake_id, session_key) do
    source_ids =
      if is_binary(wake_id) do
        [wake_id | Tightbeam.NoticeBatcher.carrier_source_ids_in_txn(txn, wake_id)]
      else
        []
      end

    entries =
      Enum.flat_map(source_ids, fn source_id ->
        Txn.q(
          txn,
          "SELECT e.sessionHandle,h.recipientSessionKey,h.ownerNotifiedAt FROM harklight_entries e JOIN harklight_handles h ON h.sessionHandle=e.sessionHandle WHERE e.wakeId=?1",
          [source_id]
        )
      end)

    case entries do
      [] ->
        :ordinary

      entries ->
        Enum.reduce(entries, {:deliver, []}, fn [handle, recipient, owner_notified_at],
                                                {state, notices} ->
          if recipient != session_key do
            raise ArgumentError,
                  "Harklight wake #{wake_id} targets #{session_key}, but handle #{handle} is bound to #{recipient}"
          end

          case Txn.q(txn, "SELECT state,ownerUserId FROM sessions WHERE sessionKey=?1", [recipient]) do
            [["active", _owner]] ->
              {state, notices}

            [[_state, owner_user_id]] ->
              notice =
                if is_nil(owner_notified_at) do
                  notify_owner_once_in_txn(txn, handle, recipient, owner_user_id)
                end

              { :held, if(is_list(notice), do: notices ++ notice, else: notices) }

            [] ->
              notice =
                if is_nil(owner_notified_at) do
                  notify_owner_once_in_txn(txn, handle, recipient, nil)
                end

              { :held, if(is_list(notice), do: notices ++ notice, else: notices) }
          end
        end)
        |> case do
          {:deliver, _notices} -> :deliver
          {:held, notices} -> {:held, notices}
        end
    end
  end

  defp notify_owner_once_in_txn(txn, handle, recipient, owner_user_id) do
    now = now()

    Txn.q(
      txn,
      "UPDATE harklight_handles SET ownerNotifiedAt=?2 WHERE sessionHandle=?1 AND ownerNotifiedAt IS NULL",
      [handle, now]
    )

    if Txn.changes(txn) == 1 do
      detail = JSON.encode!(%{sessionHandle: handle, recipientSessionKey: recipient})

      if is_binary(owner_user_id) and owner_user_id != "" do
        EventLog.notice_in_txn(txn, "harklight_recipient_unavailable", handle, detail,
          audience: {:session, Org.personal_session_key(owner_user_id)},
          message:
            "A Harklight entry for Tightbeam session #{recipient} is held for that same session because it is unavailable.",
          attention: :normal
        )
      else
        EventLog.lifecycle_in_txn(txn, "harklight_recipient_unavailable", handle, detail)
        nil
      end
    end
  end

  defp maybe_start_listener(_db, _handle, "complete", _opts), do: {:ok, "complete"}

  defp maybe_start_listener(db, handle, "listening", opts) do
    if Keyword.get(opts, :start_listener, true) do
      case Tightbeam.Harklight.ListenerSupervisor.ensure(db, handle) do
        {:ok, _pid} -> {:ok, "listening"}
        {:error, reason} -> {:error, "listener_unavailable", inspect(reason)}
      end
    else
      {:ok, "not_started"}
    end
  end

  defp insert_request(txn, handle, sender_id, message_id, now) do
    Txn.q(
      txn,
      "INSERT INTO harklight_requests (sessionHandle,senderId,messageId,createdAt) VALUES (?1,?2,?3,?4) ON CONFLICT DO NOTHING",
      [handle, sender_id, message_id, now]
    )
  end

  defp event_identity(event) do
    fields = %{
      sender_id: event["sender_id"],
      message_id: event["message_id"],
      event_id: event["event_id"],
      kind: event["kind"],
      terminal_state: event["terminal_state"],
      author: event["author"],
      request_revision: event["request_revision"],
      delivered: event["delivered"],
      acted: event["acted"]
    }

    if Enum.all?(
         [:sender_id, :message_id, :event_id, :kind, :author],
         &(is_binary(fields[&1]) and fields[&1] != "")
       ) and
         not is_nil(fields.request_revision) and is_boolean(fields.delivered) and
         is_boolean(fields.acted) do
      {:ok, fields}
    else
      {:error, :invalid_entry}
    end
  end

  defp idle_line?(%{"kind" => "idle", "open_requests" => 0}), do: true
  defp idle_line?(_), do: false

  defp build_prompt(handle, entry, raw_event) do
    revision = JSON.encode!(entry.request_revision)
    delivered = to_string(entry.delivered)
    acted = to_string(entry.acted)
    instruction = handling_instruction(entry)

    """
    Harklight entry for handle #{handle}.
    Entry identity: sender_id=#{entry.sender_id}, message_id=#{entry.message_id}, handle=#{handle}, event_id=#{entry.event_id}.
    Entry kind: #{entry.kind}; author: #{entry.author}; request revision: #{revision}; delivered: #{delivered}; acted: #{acted}.
    Printed Harklight entry (unaltered):
    #{raw_event}

    #{instruction}
    """
    |> String.trim()
  end

  defp handling_instruction(entry) do
    terminal = terminal_state(entry.kind, entry.terminal_state)

    steps =
      [
        "Acknowledge this entry from this Tightbeam session with `harklight-agent ack --event #{entry.event_id}`.",
        if(entry.delivered, do: delivered_check(entry, terminal), else: nil),
        if(terminal == "answered" and entry.author == "agent",
          do: "This answer was authored by an agent; do not treat it as Mike's choice.",
          else: nil
        ),
        handling_step(entry, terminal),
        "Do not run `harklight-agent listen`; the Tightbeam gateway listens for this handle."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {step, number} -> "#{number}. #{step}" end)
      |> Enum.join("\n")

    "Handling instructions:\n" <> steps
  end

  defp handling_step(_entry, terminal) when terminal in ["cleared", "expired", "superseded"],
    do:
      "Stop work on this request. Do not treat this entry as approval; send no reply and no result."

  defp handling_step(entry, "answered"),
    do:
      "Apply the answer carried by event #{entry.event_id} at most once, then report `applied` or `refused` for request #{entry.message_id} with `harklight-agent result --request #{entry.message_id} --status applied` or `harklight-agent result --request #{entry.message_id} --status refused`."

  defp handling_step(entry, _terminal),
    do:
      "For a person's discussion turn with no prior reply, reply with `harklight-agent reply --request #{entry.message_id} --in-reply-to #{entry.event_id} --body \"<your reply>\"`."

  defp delivered_check(entry, "answered") do
    "Because delivered is true, first check whether earlier work on this answer took effect under r16 R6. If you cannot tell, do not apply it again; report `received` with `harklight-agent result --request #{entry.message_id} --status received`, never `applied`."
  end

  defp delivered_check(_entry, _terminal) do
    "Because delivered is true, first check whether earlier work on this entry took effect under r16 R6. If an earlier reply already committed, do not post it again. If an outside action's outcome is unclear, do not repeat that action; reply that its outcome is unconfirmed and needs checking."
  end

  defp terminal_state(kind, _state) when kind in ["answered", "cleared", "expired", "superseded"],
    do: kind

  defp terminal_state("terminal", state)
       when state in ["answered", "cleared", "expired", "superseded"], do: state

  defp terminal_state(_kind, _state), do: nil

  defp bool_int(true), do: 1
  defp bool_int(false), do: 0
  defp now, do: System.system_time(:millisecond)
end
