defmodule Tightbeam.HarklightWakes do
  @moduledoc """
  Durable, origin-bound handoff from a Harklight controller stream to ordinary
  prompt wakes. The external CLI owns the feed journal and cursor; this table
  owns the correlation between one handle and one local session and remembers
  every line captured into the wake queue.
  """

  use GenServer
  alias Tightbeam.{DB, Org, Placement, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS harklight_send_operations (
    opId TEXT PRIMARY KEY,
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    host TEXT NOT NULL,
    payload TEXT NOT NULL,
    result TEXT,
    handle TEXT,
    senderId TEXT,
    messageId TEXT,
    attemptedAt INTEGER,
    state TEXT NOT NULL CHECK(state IN ('pending','bound')),
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL,
    CHECK ((state='pending' AND result IS NULL AND handle IS NULL AND senderId IS NULL AND messageId IS NULL)
       OR (state='bound' AND result IS NOT NULL AND handle IS NOT NULL AND senderId IS NOT NULL AND messageId IS NOT NULL))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS harklight_send_bound_request
    ON harklight_send_operations(senderId,messageId);
  CREATE TABLE IF NOT EXISTS harklight_wake_handles (
    handle TEXT PRIMARY KEY,
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    host TEXT NOT NULL,
    vendorSessionId TEXT,
    state TEXT NOT NULL CHECK(state IN ('active','complete','unavailable')),
    lastCursor INTEGER NOT NULL DEFAULT 0,
    lastError TEXT,
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS harklight_wake_requests (
    senderId TEXT NOT NULL,
    messageId TEXT NOT NULL,
    handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
    PRIMARY KEY(senderId,messageId)
  );
  CREATE TABLE IF NOT EXISTS harklight_wake_entries (
    handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
    eventId TEXT NOT NULL,
    feedCursor INTEGER NOT NULL,
    senderId TEXT NOT NULL,
    messageId TEXT NOT NULL,
    requestRevision INTEGER,
    entryKind TEXT NOT NULL,
    entryAuthor TEXT NOT NULL,
    rawLine TEXT NOT NULL,
    wakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
    capturedAt INTEGER NOT NULL,
    PRIMARY KEY(handle,eventId),
    UNIQUE(handle,feedCursor)
  );
  CREATE INDEX IF NOT EXISTS harklight_wake_requests_handle
    ON harklight_wake_requests(handle);
  """

  @uuid4 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # The caller of these functions is the runtime-owned send boundary. Its
  # external adapter must execute or recover only this persisted operation and
  # must pass the original confirmed result to bind_send/8. No wire command may
  # assert a result or binding on the adapter's behalf.
  def prepare_send(db, call, op_id, payload) do
    session_key = call.session_key

    with true <- authenticated_origin?(call),
         true <- is_binary(op_id) and Regex.match?(@uuid4, op_id),
         true <- is_binary(payload) and payload != "",
         %{state: "active", host: host} <- Org.get(db, session_key),
         true <- host == Placement.local_host_name() do
      now = System.system_time(:millisecond)

      case DB.transaction(db, fn txn ->
             case Txn.q(
                    txn,
                    "SELECT sessionKey,host,payload,state FROM harklight_send_operations WHERE opId=?1",
                    [op_id]
                  ) do
               [] ->
                 Txn.q(
                   txn,
                   "INSERT INTO harklight_send_operations(opId,sessionKey,host,payload,state,createdAt,updatedAt) VALUES(?1,?2,?3,?4,'pending',?5,?5)",
                   [op_id, session_key, host, payload, now]
                 )

                 {:ok, "pending"}

               [[^session_key, ^host, ^payload, state]] ->
                 {:ok, state}

               _ ->
                 {:error, "harklight_send_mismatch"}
             end
           end) do
        {:ok, {:ok, state}} -> %{op_id: op_id, state: state}
        {:ok, {:error, reason}} -> %{code: reason}
        {:error, reason} -> %{code: "harklight_send_unavailable", message: inspect(reason)}
      end
    else
      _ -> %{code: "harklight_origin_unavailable"}
    end
  end

  def bind_send(db, call, op_id, payload, result, handle, sender_id, message_id) do
    session_key = call.session_key

    with true <- authenticated_origin?(call),
         true <- is_binary(op_id) and Regex.match?(@uuid4, op_id),
         true <- is_binary(payload) and payload != "" and is_binary(result) and result != "",
         true <- is_binary(handle) and Regex.match?(@uuid4, handle),
         true <-
           is_binary(sender_id) and sender_id != "" and is_binary(message_id) and message_id != "",
         %{state: "active", host: host} <- Org.get(db, session_key),
         true <- host == Placement.local_host_name() do
      now = System.system_time(:millisecond)
      pointer = Org.current_pointer(db, session_key)
      vendor_id = if pointer, do: pointer.harness_session_id, else: nil

      case DB.transaction(db, fn txn ->
             case Txn.q(
                    txn,
                    "SELECT sessionKey,host,payload,result,handle,senderId,messageId,state FROM harklight_send_operations WHERE opId=?1",
                    [op_id]
                  ) do
               [[^session_key, ^host, ^payload, nil, nil, nil, nil, "pending"]] ->
                 Txn.q(
                   txn,
                   "UPDATE harklight_send_operations SET result=?2,handle=?3,senderId=?4,messageId=?5,state='bound',updatedAt=?6 WHERE opId=?1",
                   [op_id, result, handle, sender_id, message_id, now]
                 )

                 register_in_txn(
                   txn,
                   handle,
                   session_key,
                   host,
                   sender_id,
                   message_id,
                   vendor_id,
                   now
                 )

               [
                 [
                   ^session_key,
                   ^host,
                   ^payload,
                   ^result,
                   ^handle,
                   ^sender_id,
                   ^message_id,
                   "bound"
                 ]
               ] ->
                 register_in_txn(
                   txn,
                   handle,
                   session_key,
                   host,
                   sender_id,
                   message_id,
                   vendor_id,
                   now
                 )

               _ ->
                 {:error, "harklight_send_mismatch"}
             end
           end) do
        {:ok, {:ok, registration}} ->
          activate(handle, registration.rearm)
          registration |> Map.delete(:rearm) |> Map.put(:op_id, op_id)

        {:ok, {:error, reason}} ->
          %{code: reason}

        {:error, reason} ->
          %{code: "harklight_send_unavailable", message: inspect(reason)}
      end
    else
      _ -> %{code: "harklight_origin_unavailable"}
    end
  end

  defp authenticated_origin?(call) do
    is_binary(call.session_key) and call.principal == {:session, call.session_key} and
      call.transport_session_key == call.session_key
  end

  def mark_send_attempt(db, call, op_id, payload) do
    with true <- authenticated_origin?(call),
         %{state: "active", host: host} <- Org.get(db, call.session_key),
         true <- host == Placement.local_host_name() do
      case DB.transaction(db, fn txn ->
             case Txn.q(
                    txn,
                    "SELECT sessionKey,host,payload,state FROM harklight_send_operations WHERE opId=?1",
                    [op_id]
                  ) do
               [[session, ^host, ^payload, "pending"]] when session == call.session_key ->
                 Txn.q(
                   txn,
                   "UPDATE harklight_send_operations SET attemptedAt=COALESCE(attemptedAt,?2),updatedAt=?2 WHERE opId=?1",
                   [op_id, System.system_time(:millisecond)]
                 )

                 :ok

               _ ->
                 {:error, "harklight_send_mismatch"}
             end
           end) do
        {:ok, :ok} -> :ok
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, _} -> {:error, "harklight_send_unavailable"}
      end
    else
      _ -> {:error, "harklight_origin_unavailable"}
    end
  end

  def pending_send_attempts(db) do
    DB.query(
      db,
      "SELECT opId,sessionKey,payload FROM harklight_send_operations WHERE state='pending' AND attemptedAt IS NOT NULL ORDER BY attemptedAt,opId"
    )
  end

  def register(db, call) do
    p = call.params
    session_key = call.session_key
    handle = p[:harklight_handle]
    sender_id = p[:harklight_sender_id]
    message_id = p[:harklight_message_id]
    supplied_vendor_id = p[:harklight_vendor_session_id]
    pointer = if is_binary(session_key), do: Org.current_pointer(db, session_key)
    vendor_id = if pointer, do: pointer.harness_session_id, else: supplied_vendor_id

    with true <- authenticated_origin?(call),
         true <- is_binary(handle) and Regex.match?(@uuid4, handle),
         true <-
           is_binary(sender_id) and sender_id != "" and is_binary(message_id) and
             message_id != "" and (is_nil(supplied_vendor_id) or is_binary(supplied_vendor_id)),
         true <- is_nil(supplied_vendor_id) or is_nil(pointer) or supplied_vendor_id == vendor_id,
         %{state: "active", host: host} <- Org.get(db, session_key),
         true <- host == Placement.local_host_name() do
      now = System.system_time(:millisecond)

      case DB.transaction(db, fn txn ->
             register_in_txn(
               txn,
               handle,
               session_key,
               host,
               sender_id,
               message_id,
               vendor_id,
               now
             )
           end) do
        {:ok, {:ok, result}} ->
          activate(handle, result.rearm)
          Map.delete(result, :rearm)

        {:ok, {:error, reason}} ->
          %{code: reason}

        {:error, reason} ->
          %{code: "harklight_registration_unavailable", message: inspect(reason)}
      end
    else
      _ ->
        %{
          code: "harklight_origin_unavailable",
          message: "registration requires the active originating session on this host"
        }
    end
  end

  defp register_in_txn(txn, handle, session_key, host, sender_id, message_id, vendor_id, now) do
    existing =
      Txn.q(
        txn,
        "SELECT sessionKey,host,state,vendorSessionId FROM harklight_wake_handles WHERE handle=?1",
        [handle]
      )

    request =
      Txn.q(
        txn,
        "SELECT handle FROM harklight_wake_requests WHERE senderId=?1 AND messageId=?2",
        [sender_id, message_id]
      )

    provenance =
      Txn.q(
        txn,
        "SELECT 1 FROM harklight_send_operations WHERE sessionKey=?1 AND host=?2 AND handle=?3 AND senderId=?4 AND messageId=?5 AND state='bound'",
        [session_key, host, handle, sender_id, message_id]
      )

    cond do
      provenance != [[1]] ->
        {:error, "harklight_send_pending"}

      existing != [] and Enum.take(hd(existing), 2) != [session_key, host] ->
        {:error, "harklight_origin_mismatch"}

      request != [] and request != [[handle]] ->
        {:error, "harklight_request_mismatch"}

      true ->
        new_request = request == []
        completed = existing != [] and Enum.at(hd(existing), 2) == "complete"

        rearm =
          existing != [] and
            ((completed and new_request) or
               (not completed and Enum.at(hd(existing), 3) != vendor_id))

        if existing == [] do
          Txn.q(
            txn,
            "INSERT INTO harklight_wake_handles(handle,sessionKey,host,vendorSessionId,state,createdAt,updatedAt) VALUES(?1,?2,?3,?4,'active',?5,?5)",
            [handle, session_key, host, vendor_id, now]
          )
        else
          [[_, _, state, previous_vendor]] = existing

          if (state == "complete" and new_request) or
               (state != "complete" and previous_vendor != vendor_id) do
            Txn.q(
              txn,
              "UPDATE harklight_wake_handles SET state='active',vendorSessionId=?2,lastError=NULL,updatedAt=?3 WHERE handle=?1",
              [handle, vendor_id, now]
            )
          end
        end

        if request == [] do
          Txn.q(
            txn,
            "INSERT INTO harklight_wake_requests(senderId,messageId,handle) VALUES(?1,?2,?3)",
            [sender_id, message_id, handle]
          )
        end

        status = if completed and not new_request, do: "complete", else: "registered"
        {:ok, %{handle: handle, session_key: session_key, state: status, rearm: rearm}}
    end
  end

  def activate(handle, force \\ false) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, {:activate, handle, force})
    :ok
  end

  def origin_ready(session_key) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, {:origin_ready, session_key})
    :ok
  end

  @impl true
  def init(opts) do
    send(self(), :restore)

    {:ok,
     %{
       db: Keyword.get(opts, :db, DB),
       listener: Keyword.get(opts, :listener, &run_listener/3),
       send_runner: Keyword.get(opts, :send_runner),
       workers: %{},
       refs: %{},
       restart: MapSet.new(),
       stopping: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:restore, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle FROM harklight_wake_handles WHERE state IN ('active','unavailable') ORDER BY createdAt,handle"
      )

    Task.start(fn ->
      Tightbeam.HarklightSend.recover_pending(state.db, runner: state.send_runner)
    end)

    {:noreply, Enum.reduce(rows, state, fn [handle], acc -> start_worker(acc, handle) end)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {handle, refs} ->
        state = %{state | refs: refs, workers: Map.delete(state.workers, handle)}

        cond do
          MapSet.member?(state.stopping, handle) ->
            {:noreply, %{state | stopping: MapSet.delete(state.stopping, handle)}}

          MapSet.member?(state.restart, handle) ->
            state = %{state | restart: MapSet.delete(state.restart, handle)}
            {:noreply, start_worker(state, handle)}

          true ->
            mark_finished(state.db, handle, "listener_terminated")
            {:noreply, state}
        end
    end
  end

  def handle_cast({:pointer_changed, session_key}, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle FROM harklight_wake_handles WHERE sessionKey=?1 AND state IN ('active','unavailable')",
        [session_key]
      )

    {:noreply, Enum.reduce(rows, state, fn [handle], acc -> force_worker(acc, handle) end)}
  end

  def handle_cast({:origin_changed, session_key}, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle,host,state FROM harklight_wake_handles WHERE sessionKey=?1",
        [session_key]
      )

    state =
      Enum.reduce(rows, state, fn [handle, host, handle_state], acc ->
        if origin_eligible?(acc.db, session_key, host) do
          if handle_state == "complete", do: acc, else: start_worker(acc, handle)
        else
          # Persist invalidation before the worker's DOWN can reach observers.
          mark_finished(acc.db, handle, "origin_unavailable")
          acc = stop_worker(acc, handle)
          notify_pending_origin_unavailable(acc.db, handle)
          acc
        end
      end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:activate, handle, true}, state) do
    {:noreply, force_worker(state, handle)}
  end

  def handle_cast({:activate, handle, false}, state), do: {:noreply, start_worker(state, handle)}

  def handle_cast({:origin_ready, session_key}, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle FROM harklight_wake_handles WHERE sessionKey=?1 AND state IN ('active','unavailable') ORDER BY createdAt,handle",
        [session_key]
      )

    {:noreply, Enum.reduce(rows, state, fn [handle], acc -> start_worker(acc, handle) end)}
  end

  defp force_worker(state, handle) do
    case Map.fetch(state.workers, handle) do
      {:ok, worker} ->
        Process.exit(worker, :shutdown)
        %{state | restart: MapSet.put(state.restart, handle)}

      :error ->
        start_worker(state, handle)
    end
  end

  defp stop_worker(state, handle) do
    case Map.fetch(state.workers, handle) do
      {:ok, worker} ->
        Process.exit(worker, :shutdown)

        %{
          state
          | stopping: MapSet.put(state.stopping, handle),
            restart: MapSet.delete(state.restart, handle)
        }

      :error ->
        state
    end
  end

  defp valid_worker?(state, handle, {pid, _tag}) do
    Map.get(state.workers, handle) == pid and
      not MapSet.member?(state.stopping, handle) and
      not MapSet.member?(state.restart, handle)
  end

  defp origin_eligible?(db, session_key, host) do
    host == Placement.local_host_name() and
      match?(%{state: "active", host: ^host}, Org.get(db, session_key))
  end

  @impl true
  def handle_call({:capture, handle, line}, from, state) do
    result =
      if valid_worker?(state, handle, from),
        do: capture_line(state.db, handle, line),
        else: {:error, "listener_fenced"}

    {:reply, result, state}
  end

  def handle_call({:attached, handle}, from, state) do
    result =
      if valid_worker?(state, handle, from) do
        case DB.query(
               state.db,
               "UPDATE harklight_wake_handles SET state='active',lastError=NULL,updatedAt=?2 WHERE handle=?1",
               [handle, System.system_time(:millisecond)]
             ) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, "attachment_state_unavailable"}
        end
      else
        {:error, "listener_fenced"}
      end

    {:reply, result, state}
  end

  def handle_call({:finished, handle, status}, from, state) do
    result =
      if valid_worker?(state, handle, from),
        do: mark_finished(state.db, handle, status),
        else: :ok

    {:reply, result, state}
  end

  defp mark_finished(db, handle, status) do
    case DB.transaction(db, fn txn -> mark_finished_in_txn(txn, handle, status) end) do
      {:ok, result} -> result
      {:error, _} -> {:error, "listener_state_unavailable"}
    end
  end

  defp mark_finished_in_txn(txn, handle, status) do
    case Txn.q(txn, "SELECT sessionKey,state FROM harklight_wake_handles WHERE handle=?1", [
           handle
         ]) do
      [[session_key, "active"]] ->
        now = System.system_time(:millisecond)
        completed = status == :complete
        next_state = if completed, do: "complete", else: "unavailable"
        error = if completed, do: nil, else: to_string(status)

        Txn.q(
          txn,
          "UPDATE harklight_wake_handles SET state=?2,lastError=?3,updatedAt=?4 WHERE handle=?1",
          [handle, next_state, error, now]
        )

        if not completed,
          do:
            notify_owner_in_txn(
              txn,
              session_key,
              handle,
              if(error == "origin_unavailable",
                do: "origin_unavailable",
                else: "listener_failure"
              ),
              error,
              now
            )

        :ok

      _ ->
        :ok
    end
  end

  defp notify_pending_origin_unavailable(db, handle) do
    DB.transaction(db, fn txn ->
      case Txn.q(
             txn,
             "SELECT h.sessionKey FROM harklight_wake_handles h JOIN harklight_wake_entries e ON e.handle=h.handle JOIN wakes w ON w.wakeId=e.wakeId WHERE h.handle=?1 AND w.state='pending' LIMIT 1",
             [handle]
           ) do
        [[session_key]] ->
          notify_owner_in_txn(
            txn,
            session_key,
            handle,
            "origin_unavailable",
            "origin_unavailable",
            System.system_time(:millisecond)
          )

        _ ->
          :ok
      end
    end)
  end

  defp notify_owner_in_txn(txn, session_key, handle, notice_kind, error, now) do
    wake_id = "w_harklight_notice_" <> notice_kind <> "_" <> handle

    if Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [wake_id]) == [] do
      if recipient = Supervision.ladder_target(txn, session_key, 1) do
        wake =
          Wakes.schedule_in_txn(txn, %{
            wake_id: wake_id,
            session_key: recipient,
            origin: "process:tightbeam",
            creator_session_key: session_key,
            prompt:
              "Harklight listening for session #{session_key} and handle #{handle} stopped (#{error}). Pending entries remain at the origin. Restore only that session on its original host; do not transfer the conversation.",
            due_at: now,
            class: "blocker"
          })

        Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)
      end
    end
  end

  defp start_worker(state, handle) do
    if Map.has_key?(state.workers, handle) do
      state
    else
      case DB.query(
             state.db,
             "SELECT sessionKey,host,vendorSessionId,state FROM harklight_wake_handles WHERE handle=?1",
             [handle]
           ) do
        {:ok, [[session_key, host, saved_vendor_id, state_value]]}
        when state_value in ["active", "unavailable"] ->
          case Org.get(state.db, session_key) do
            %{state: "active", host: ^host} ->
              if host == Placement.local_host_name() do
                pointer = Org.current_pointer(state.db, session_key)
                vendor_id = if pointer, do: pointer.harness_session_id, else: saved_vendor_id

                if vendor_id != saved_vendor_id do
                  DB.query(
                    state.db,
                    "UPDATE harklight_wake_handles SET vendorSessionId=?2,updatedAt=?3 WHERE handle=?1",
                    [handle, vendor_id, System.system_time(:millisecond)]
                  )
                end

                manager = self()
                {:ok, pid} = Task.start(fn -> state.listener.(manager, handle, vendor_id) end)
                ref = Process.monitor(pid)

                %{
                  state
                  | workers: Map.put(state.workers, handle, pid),
                    refs: Map.put(state.refs, ref, handle)
                }
              else
                state
              end

            _ ->
              state
          end

        _ ->
          state
      end
    end
  end

  defp run_listener(manager, handle, vendor_id) do
    case System.find_executable("harklight-agent") do
      nil ->
        finish(manager, handle, "cli_missing")

      executable ->
        args = [
          "attach",
          "--session",
          handle,
          "--vendor-session-id",
          vendor_id || "none",
          "--route",
          "other",
          "--controller"
        ]

        case attach(executable, args) do
          :ok ->
            case GenServer.call(manager, {:attached, handle}, :infinity) do
              :ok -> follow(manager, executable, handle)
              {:error, reason} -> finish(manager, handle, reason)
            end

          {:error, reason} ->
            finish(manager, handle, reason)
        end
    end
  rescue
    _ -> finish(manager, handle, "listener_failed")
  end

  defp attach(executable, args) do
    case attach_once(executable, args) do
      {:unknown, op_id} ->
        case System.cmd(executable, ["retry", "--op-id", op_id], stderr_to_stdout: true) do
          {_output, 0} -> attach_once(executable, args) |> attach_result()
          _ -> {:error, "attachment_outcome_unknown"}
        end

      result ->
        attach_result(result)
    end
  rescue
    _ -> {:error, "attachment_cli_failed"}
  end

  defp attach_once(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} ->
        if Enum.any?(String.split(output, "\n", trim: true), fn line ->
             match?({:ok, %{"kind" => "attached", "ready_for_listen" => true}}, JSON.decode(line))
           end), do: :ok, else: {:error, "attachment_unconfirmed"}

      {output, _} ->
        unknown =
          output
          |> String.split("\n", trim: true)
          |> Enum.find_value(fn line ->
            case JSON.decode(line) do
              {:ok, %{"kind" => "outcome_unknown", "op_id" => id}} when is_binary(id) -> id
              _ -> nil
            end
          end)

        if unknown, do: {:unknown, unknown}, else: {:error, "attachment_refused"}
    end
  end

  defp attach_result({:unknown, _}), do: {:error, "attachment_outcome_unknown"}
  defp attach_result(result), do: result

  defp follow(manager, executable, handle) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        args: ["listen", "--follow", "--controller", "--session", handle]
      ])

    receive_lines(manager, port, handle, "")
  end

  defp receive_lines(manager, port, handle, pending) do
    receive do
      {^port, {:data, bytes}} ->
        data = pending <> bytes
        lines = String.split(data, "\n")
        remainder = List.last(lines)

        result =
          lines
          |> Enum.drop(-1)
          |> Enum.reduce_while(:ok, fn line, _ ->
            case GenServer.call(manager, {:capture, handle, line}, :infinity) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case result do
          :ok ->
            receive_lines(manager, port, handle, remainder)

          {:error, reason} ->
            Port.close(port)
            finish(manager, handle, reason)
        end

      {^port, {:exit_status, 0}} ->
        finish(manager, handle, if(pending == "", do: :complete, else: "incomplete_line"))

      {^port, {:exit_status, _}} ->
        finish(manager, handle, "listener_stopped")
    end
  end

  defp finish(manager, handle, status),
    do: GenServer.call(manager, {:finished, handle, status}, :infinity)

  @doc false
  def capture_line(db, handle, line) do
    with {:ok, event} <- JSON.decode(line),
         true <- is_map(event) do
      case event do
        %{"kind" => "event"} -> capture_event(db, handle, line, event)
        %{"kind" => "idle", "open_requests" => 0} -> :ok
        %{"kind" => "unsupported"} -> {:error, "listener_unsupported"}
        _ -> {:error, "unexpected_listener_line"}
      end
    else
      _ -> {:error, "invalid_listener_line"}
    end
  end

  defp capture_event(db, handle, line, event) do
    request = event["request"] || %{}
    entry = event["entry"] || %{}
    event_id = event["event_id"]
    cursor = event["feed_cursor"]
    sender_id = request["sender_id"]
    message_id = request["message_id"]
    revision = event["request_revision"]
    kind = entry["kind"]
    author = entry["author"]

    if event["session_handle"] != handle or not is_binary(event_id) or
         not is_integer(cursor) or cursor < 1 or event_id != Integer.to_string(cursor) or
         not is_binary(sender_id) or not is_binary(message_id) or
         not (is_nil(revision) or is_integer(revision)) or
         kind not in ["discussion", "terminal"] or
         not valid_entry_author?(kind, author, entry) do
      {:error, "event_identity_invalid"}
    else
      case DB.transaction(db, fn txn ->
             capture_event_in_txn(
               txn,
               handle,
               line,
               event_id,
               cursor,
               sender_id,
               message_id,
               revision,
               kind,
               author
             )
           end) do
        {:ok, result} -> result
        {:error, _} -> {:error, "capture_unavailable"}
      end
    end
  end

  defp valid_entry_author?("discussion", author, _entry), do: author in ["person", "agent"]

  defp valid_entry_author?("terminal", "server", entry),
    do: entry["terminal_state"] in ["expired", "superseded"]

  defp valid_entry_author?("terminal", author, _entry), do: author in ["person", "agent"]

  defp capture_event_in_txn(
         txn,
         handle,
         line,
         event_id,
         cursor,
         sender_id,
         message_id,
         revision,
         kind,
         author
       ) do
    handle_state =
      Txn.q(
        txn,
        "SELECT sessionKey,host,lastCursor,state FROM harklight_wake_handles WHERE handle=?1",
        [handle]
      )

    case handle_state do
      [[session_key, host, prior_cursor, "active"]] ->
        if host == Placement.local_host_name() and
             match?(%{state: "active", host: ^host}, Org.get_in_txn(txn, session_key)) do
          capture_for_active_origin(
            txn,
            handle,
            session_key,
            prior_cursor,
            line,
            event_id,
            cursor,
            sender_id,
            message_id,
            revision,
            kind,
            author
          )
        else
          {:error, "harklight_origin_unavailable"}
        end

      _ ->
        {:error, "harklight_origin_unavailable"}
    end
  end

  defp capture_for_active_origin(
         txn,
         handle,
         session_key,
         prior_cursor,
         line,
         event_id,
         cursor,
         sender_id,
         message_id,
         revision,
         kind,
         author
       ) do
    existing =
      Txn.q(
        txn,
        "SELECT feedCursor,senderId,messageId,requestRevision,entryKind,entryAuthor FROM harklight_wake_entries WHERE handle=?1 AND eventId=?2",
        [
          handle,
          event_id
        ]
      )

    cond do
      existing != [] ->
        if existing == [[cursor, sender_id, message_id, revision, kind, author]],
          do: :ok,
          else: {:error, "event_identity_mismatch"}

      true ->
        request =
          Txn.q(
            txn,
            "SELECT handle FROM harklight_wake_requests WHERE senderId=?1 AND messageId=?2",
            [sender_id, message_id]
          )

        if request == [[handle]] do
          capture_new_entry(
            txn,
            handle,
            session_key,
            prior_cursor,
            line,
            event_id,
            cursor,
            sender_id,
            message_id,
            revision,
            kind,
            author
          )
        else
          {:error, "harklight_send_pending"}
        end
    end
  end

  defp capture_new_entry(
         txn,
         handle,
         session_key,
         prior_cursor,
         line,
         event_id,
         cursor,
         sender_id,
         message_id,
         revision,
         kind,
         author
       ) do
    if cursor <= prior_cursor do
      {:error, "event_order_invalid"}
    else
      wake_id = "w_harklight_" <> handle <> "_" <> String.pad_leading(event_id, 20, "0")
      prompt = line <> "\n\n" <> handling_instruction(handle, event_id, message_id, kind, author)

      wake =
        Wakes.schedule_in_txn(txn, %{
          wake_id: wake_id,
          session_key: session_key,
          origin: "process:tightbeam",
          prompt: prompt,
          due_at: System.system_time(:millisecond),
          creator_session_key: session_key,
          class: "blocker"
        })

      now = System.system_time(:millisecond)

      Txn.q(
        txn,
        "INSERT INTO harklight_wake_entries(handle,eventId,feedCursor,senderId,messageId,requestRevision,entryKind,entryAuthor,rawLine,wakeId,capturedAt) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
        [
          handle,
          event_id,
          cursor,
          sender_id,
          message_id,
          revision,
          kind,
          author,
          line,
          wake.wake_id,
          now
        ]
      )

      Txn.q(
        txn,
        "UPDATE harklight_wake_handles SET lastCursor=?2,updatedAt=?3 WHERE handle=?1",
        [handle, cursor, now]
      )

      Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)
      :ok
    end
  end

  defp handling_instruction(handle, event_id, message_id, _kind, _author) do
    "Handle this Harklight entry from your originating session. First run `harklight-agent ack --session #{handle} --event #{event_id}`. " <>
      "For a person discussion, reply with `harklight-agent reply --session #{handle} --request #{message_id} --in-reply-to #{event_id} --body <reply>`. " <>
      "For an answered terminal by a person, reconcile any earlier effect before applying once, then report with `harklight-agent result --session #{handle} --request #{message_id} --in-reply-to #{event_id} --status applied|refused`. An agent-authored terminal is not the person's choice. " <>
      "For cleared, expired or superseded, stop work on that request; do not treat it as approval. " <>
      "If delivered is true, check prior effects before acting again. Do not run listen; the controller listens."
  end
end
