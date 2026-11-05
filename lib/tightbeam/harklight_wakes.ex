defmodule Tightbeam.HarklightWakes do
  @moduledoc """
  Durable, origin-bound handoff from a Harklight controller stream to ordinary
  prompt wakes. The external CLI owns the feed journal and cursor; this table
  owns the correlation between one handle and one local session and remembers
  every line captured into the wake queue.
  """

  use GenServer
  require Logger
  alias Tightbeam.{DB, ErrorDiagnostic, HarklightLifecycle, Org, Placement, Supervision, Wakes}

  @attach_retry_delays [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000]
  @attach_retry_window_ms 180_000
  # Released Server serializes every origin attach through one Relay process.
  # Restore starts all listeners at once, so cap concurrent attach attempts to
  # keep that queue inside the Relay call timeout (WI2979 fifth fleet run).
  @attach_concurrency 4

  @max_diagnostic_lines 3
  @max_diagnostic_line_chars 240
  @max_diagnostic_chars 768
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

  def ensure_schema(db \\ DB) do
    with :ok <- DB.execute(db, @ddl), do: HarklightLifecycle.ensure_schema(db)
  end

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

                 case register_in_txn(
                        txn,
                        handle,
                        session_key,
                        host,
                        sender_id,
                        message_id,
                        vendor_id,
                        now
                      ) do
                   {:ok, registration} ->
                     effects =
                       HarklightLifecycle.send_committed_in_txn(
                         txn,
                         session_key,
                         op_id,
                         payload,
                         result
                       )

                     {:ok, Map.merge(registration, effects)}

                   error ->
                     error
                 end

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
                 case register_in_txn(
                        txn,
                        handle,
                        session_key,
                        host,
                        sender_id,
                        message_id,
                        vendor_id,
                        now
                      ) do
                   {:ok, registration} ->
                     effects =
                       HarklightLifecycle.send_committed_in_txn(
                         txn,
                         session_key,
                         op_id,
                         payload,
                         result
                       )

                     {:ok, Map.merge(registration, effects)}

                   error ->
                     error
                 end

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
      "SELECT opId,sessionKey,payload FROM harklight_send_operations WHERE state='pending' AND attemptedAt IS NOT NULL AND opId NOT IN (SELECT opId FROM harklight_command_results) ORDER BY attemptedAt,opId"
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

  def origin_turn_ended(session_key) do
    if pid = Process.whereis(__MODULE__),
      do: GenServer.cast(pid, {:origin_turn_ended, session_key})

    :ok
  end

  def h8a_acknowledged(handle) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, {:h8a_acknowledged, handle})
    :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :restore)
    delays = Keyword.get(opts, :attach_retry_delays, @attach_retry_delays)
    window = Keyword.get(opts, :attach_retry_window_ms, @attach_retry_window_ms)

    {:ok,
     %{
       db: Keyword.get(opts, :db, DB),
       listener:
         Keyword.get(opts, :listener, fn manager, handle, vendor_id ->
           run_listener(manager, handle, vendor_id, delays, window)
         end),
       send_runner: Keyword.get(opts, :send_runner),
       workers: %{},
       ports: %{},
       refs: %{},
       restart: MapSet.new(),
       stopping: MapSet.new(),
       attach_limit: Keyword.get(opts, :attach_concurrency, @attach_concurrency),
       attach_slots: MapSet.new(),
       attach_waiting: :queue.new()
     }}
  end

  @impl true
  def handle_info(:restore, state) do
    {:ok, rows} =
      DB.query(
        state.db,
        "SELECT handle FROM harklight_wake_handles WHERE state IN ('active','unavailable') ORDER BY createdAt,handle"
      )

    {:ok, candidates} = answer_completion_candidates(state.db, nil)
    candidates_set = MapSet.new(candidates, fn [handle] -> handle end)

    state =
      Enum.reduce(rows, state, fn [handle], acc ->
        if MapSet.member?(candidates_set, handle), do: acc, else: start_worker(acc, handle)
      end)

    manager = self()

    Task.start(fn ->
      Tightbeam.HarklightSend.recover_pending(state.db, runner: state.send_runner)
      HarklightLifecycle.process_terminals(state.db, runner: state.send_runner)

      Enum.each(candidates, fn [handle] ->
        evidence =
          HarklightLifecycle.completion_evidence(state.db, handle, runner: state.send_runner)

        GenServer.cast(manager, {:restore_handle, handle, evidence})
      end)
    end)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state = release_attach_slot(state, pid)

    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {handle, refs} ->
        state = %{
          state
          | refs: refs,
            workers: Map.delete(state.workers, handle),
            ports: Map.delete(state.ports, handle)
        }

        cond do
          MapSet.member?(state.stopping, handle) ->
            {:noreply, %{state | stopping: MapSet.delete(state.stopping, handle)}}

          MapSet.member?(state.restart, handle) ->
            state = %{state | restart: MapSet.delete(state.restart, handle)}
            {:noreply, start_worker(state, handle)}

          true ->
            mark_terminated(state.db, handle)
            {:noreply, state}
        end
    end
  end

  # DOWN owns worker bookkeeping. Linked exits ensure a controller crash cannot
  # leave a worker holding the original handle's listener lock.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.ports, fn {_handle, port} -> close_listener_port(port) end)
    Enum.each(state.workers, fn {_handle, worker} -> Process.exit(worker, :shutdown) end)
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

  def handle_cast({:attach_slot, pid, ref}, state) do
    if MapSet.size(state.attach_slots) < state.attach_limit do
      send(pid, {:attach_slot, ref})
      {:noreply, %{state | attach_slots: MapSet.put(state.attach_slots, pid)}}
    else
      {:noreply, %{state | attach_waiting: :queue.in({pid, ref}, state.attach_waiting)}}
    end
  end

  def handle_cast({:attach_slot_released, pid}, state),
    do: {:noreply, release_attach_slot(state, pid)}

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

  def handle_cast({:origin_turn_ended, session_key}, state) do
    case answer_completion_candidates(state.db, session_key) do
      {:ok, candidates} ->
        schedule_answered_checks(self(), state.db, state.send_runner, candidates)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:h8a_acknowledged, handle}, state) do
    schedule_answered_checks(self(), state.db, state.send_runner, [[handle]])
    {:noreply, state}
  end

  # Read outside the manager, but validate and complete before starting a listener.
  # The existing transaction rejects stale evidence and preserves pending work.
  def handle_cast({:restore_handle, handle, evidence}, state) do
    result =
      case evidence do
        {:ok, evidence} ->
          DB.transaction(state.db, fn txn ->
            HarklightLifecycle.complete_answered_in_txn(txn, handle, evidence)
          end)

        _ ->
          :active
      end

    state =
      if result == {:ok, true},
        do: stop_worker(state, handle),
        else: start_worker(state, handle)

    {:noreply, state}
  end

  def handle_cast({:answer_completion_evidence, handle, evidence}, state) do
    result =
      DB.transaction(state.db, fn txn ->
        HarklightLifecycle.complete_answered_in_txn(txn, handle, evidence)
      end)

    state = if result == {:ok, true}, do: stop_worker(state, handle), else: state
    {:noreply, state}
  end

  defp answer_completion_candidates(db, session_key) do
    DB.query(
      db,
      """
      SELECT DISTINCT h.handle
      FROM harklight_wake_handles h
      JOIN harklight_wake_entries e ON e.handle=h.handle
      WHERE h.state IN ('active','unavailable') AND e.entryKind='terminal' AND e.entryAuthor='person'
        AND (?1 IS NULL OR h.sessionKey=?1)
      ORDER BY h.handle
      """,
      [session_key]
    )
  end

  defp schedule_answered_checks(manager, db, runner, candidates) do
    Task.start(fn -> schedule_answered_checks_now(manager, db, runner, candidates) end)
  end

  defp schedule_answered_checks_now(manager, db, runner, candidates) do
    Enum.each(candidates, fn [handle] ->
      case HarklightLifecycle.completion_evidence(db, handle, runner: runner) do
        {:ok, evidence} ->
          GenServer.cast(manager, {:answer_completion_evidence, handle, evidence})

        _ ->
          :ok
      end
    end)
  end

  defp force_worker(state, handle) do
    case Map.fetch(state.workers, handle) do
      {:ok, worker} ->
        if port = Map.get(state.ports, handle), do: close_listener_port(port)
        Process.exit(worker, :shutdown)
        %{state | restart: MapSet.put(state.restart, handle)}

      :error ->
        start_worker(state, handle)
    end
  end

  defp stop_worker(state, handle) do
    case Map.fetch(state.workers, handle) do
      {:ok, worker} ->
        if port = Map.get(state.ports, handle), do: close_listener_port(port)
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

  # A worker that exits while holding or awaiting a slot is released by DOWN.
  defp release_attach_slot(state, pid) do
    waiting = :queue.filter(fn {waiter, _ref} -> waiter != pid end, state.attach_waiting)

    if MapSet.member?(state.attach_slots, pid) do
      grant_attach_slot(%{
        state
        | attach_slots: MapSet.delete(state.attach_slots, pid),
          attach_waiting: waiting
      })
    else
      %{state | attach_waiting: waiting}
    end
  end

  defp grant_attach_slot(state) do
    case :queue.out(state.attach_waiting) do
      {{:value, {pid, ref}}, waiting} ->
        send(pid, {:attach_slot, ref})
        %{state | attach_slots: MapSet.put(state.attach_slots, pid), attach_waiting: waiting}

      {:empty, _} ->
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

    if result == :ok,
      do: HarklightLifecycle.acknowledge_pending(state.db, runner: state.send_runner)

    {:reply, result, state}
  end

  def handle_call({:listener_port, handle, port}, from, state) do
    if valid_worker?(state, handle, from) do
      {:reply, :ok, %{state | ports: Map.put(state.ports, handle, port)}}
    else
      {:reply, {:error, "listener_fenced"}, state}
    end
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
      if valid_worker?(state, handle, from) do
        # Later restoration failures still matter when the durable handle is
        # already unavailable; owner wake/state gating remains in the writer.
        if status != :complete, do: log_listener_failure(handle, status)
        mark_finished(state.db, handle, status)
      else
        :ok
      end

    {:reply, result, state}
  end

  defp mark_terminated(db, handle) do
    DB.transaction(db, fn txn ->
      case Txn.q(txn, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [handle]) do
        [["active"]] -> mark_finished_in_txn(txn, handle, "listener_terminated")
        _ -> :ok
      end
    end)
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
      [[session_key, current_state]] when current_state in ["active", "unavailable"] ->
        now = System.system_time(:millisecond)
        completed = status == :complete
        next_state = if completed, do: "complete", else: "unavailable"

        {error, operation, diagnostic} =
          if completed, do: {nil, nil, nil}, else: failure_details(status)

        Txn.q(
          txn,
          "UPDATE harklight_wake_handles SET state=?2,lastError=?3,updatedAt=?4 WHERE handle=?1",
          [handle, next_state, if(diagnostic, do: error <> ": " <> diagnostic, else: error), now]
        )

        if completed, do: HarklightLifecycle.complete_in_txn(txn, handle)

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
              operation,
              diagnostic,
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
            nil,
            nil,
            System.system_time(:millisecond)
          )

        _ ->
          :ok
      end
    end)
  end

  defp notify_owner_in_txn(
         txn,
         session_key,
         handle,
         _notice_kind,
         error,
         operation,
         diagnostic,
         now
       ) do
    wake_id = "w_harklight_notice_recovery_" <> handle

    if Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [wake_id]) == [] do
      recipient =
        case Org.get_in_txn(txn, session_key) do
          %{state: "active"} -> session_key
          _ -> Supervision.ladder_target(txn, session_key, 1)
        end

      if recipient do
        cli_output =
          case {error, operation, diagnostic} do
            {_, operation, diagnostic}
            when operation in ["attach", "listen"] and is_binary(diagnostic) ->
              " #{String.upcase(operation)} failure: #{diagnostic}."

            {"origin_unavailable", _, _} ->
              " The original session is inactive or no longer belongs to the recorded host."

            {"origin_host_mismatch", _, _} ->
              " The original session belongs to another host; this controller cannot attach it."

            _ ->
              " Failure cause is unknown. No safe Agent CLI diagnostic was captured."
          end

        wake =
          Wakes.schedule_in_txn(txn, %{
            wake_id: wake_id,
            session_key: recipient,
            origin: "process:tightbeam",
            creator_session_key: session_key,
            prompt:
              "Harklight listening for session #{session_key} and handle #{handle} stopped (#{error}).#{cli_output} Replies on this thread will not reach the originating session while it is unavailable. Pending entries remain at the origin. The origin may re-ask; do not transfer the conversation.",
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

                {:ok, pid} =
                  Task.start_link(fn -> state.listener.(manager, handle, vendor_id) end)

                ref = Process.monitor(pid)

                %{
                  state
                  | workers: Map.put(state.workers, handle, pid),
                    refs: Map.put(state.refs, ref, handle)
                }
              else
                mark_finished(state.db, handle, "origin_host_mismatch")
                state
              end

            _ ->
              mark_finished(state.db, handle, "origin_unavailable")
              state
          end

        _ ->
          state
      end
    end
  end

  defp run_listener(manager, handle, vendor_id, delays, window) do
    Process.flag(:trap_exit, true)

    case System.find_executable("harklight-agent") do
      nil ->
        finish(
          manager,
          handle,
          failure_status(
            "cli_missing",
            "attach",
            attempt_diagnostic(
              "ATTACH startup (CLI unavailable; subprocess not launched)",
              nil,
              nil
            )
          )
        )

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

        deadline = System.monotonic_time(:millisecond) + window

        case attach_with_transport_recovery(
               executable,
               args,
               delays,
               deadline,
               manager,
               handle,
               nil
             ) do
          :ok ->
            case GenServer.call(manager, {:attached, handle}, :infinity) do
              :ok -> follow(manager, executable, handle)
              {:error, reason} -> finish(manager, handle, reason)
            end

          {:error, reason, diagnostic} ->
            finish(manager, handle, failure_status(reason, "attach", diagnostic))

          {:error, reason} ->
            finish(manager, handle, reason)
        end
    end
  rescue
    _ -> finish(manager, handle, "listener_failed")
  end

  # Keep the original same-operation recovery inside each attempt. Only an
  # observed transport failure can schedule another attempt; a handle refusal
  # or an unclassified unknown result retains the existing disposition.
  defp attach_with_transport_recovery(executable, args, delays, deadline, manager, handle, last) do
    case paced_attach(executable, args, deadline, manager, last) do
      {:transport, reason, diagnostic} = failure ->
        case delays do
          [delay | rest] ->
            if System.monotonic_time(:millisecond) + delay <= deadline do
              log_listener_failure(handle, failure_status(reason, "attach", diagnostic))

              receive do
                {:EXIT, ^manager, exit_reason} -> exit(exit_reason)
              after
                delay ->
                  if System.monotonic_time(:millisecond) <= deadline do
                    attach_with_transport_recovery(
                      executable,
                      args,
                      rest,
                      deadline,
                      manager,
                      handle,
                      failure
                    )
                  else
                    {:error, reason, diagnostic}
                  end
              end
            else
              {:error, reason, diagnostic}
            end

          [] ->
            {:error, reason, diagnostic}
        end

      result ->
        result
    end
  end

  # Waiting for a slot spends the same retry window; a retry granted after the
  # deadline reports the previous transport failure instead of attaching.
  defp paced_attach(executable, args, deadline, manager, last) do
    ref = make_ref()
    GenServer.cast(manager, {:attach_slot, self(), ref})

    receive do
      {:attach_slot, ^ref} -> :ok
      {:EXIT, ^manager, exit_reason} -> exit(exit_reason)
    end

    try do
      if last && System.monotonic_time(:millisecond) > deadline,
        do: last,
        else: attach(executable, args)
    after
      GenServer.cast(manager, {:attach_slot_released, self()})
    end
  end

  defp attach(executable, args) do
    case attach_once(executable, args, "ATTACH initial attempt") do
      {:unknown, op_id, initial_diagnostic, _transport} ->
        case retry_existing_operation(executable, op_id) do
          {:ok, retry_diagnostic} ->
            case attach_once(executable, args, "ATTACH after same-operation retry") do
              :ok ->
                :ok

              {:unknown, _op_id, diagnostic, transport} ->
                {if(transport, do: :transport, else: :error), "attachment_outcome_unknown",
                 [initial_diagnostic, retry_diagnostic, diagnostic]}

              {kind, reason, diagnostic} when kind in [:error, :transport] ->
                {kind, reason, [initial_diagnostic, retry_diagnostic, diagnostic]}
            end

          {:transport, retry_diagnostic} ->
            {:transport, "attachment_outcome_unknown", [initial_diagnostic, retry_diagnostic]}

          {:error, retry_diagnostic} ->
            {:error, "attachment_outcome_unknown", [initial_diagnostic, retry_diagnostic]}

          {:error, reason, retry_diagnostic} ->
            {:error, reason, [initial_diagnostic, retry_diagnostic]}
        end

      result ->
        attach_result(result)
    end
  rescue
    _ ->
      {:error, "attachment_cli_failed", attempt_diagnostic("ATTACH initial attempt", nil, nil)}
  end

  defp retry_existing_operation(executable, op_id) do
    case System.cmd(executable, ["retry", "--op-id", op_id], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, attempt_diagnostic("ATTACH existing same-operation retry", 0, output)}

      {output, exit_status} ->
        diagnostic =
          attempt_diagnostic("ATTACH existing same-operation retry", exit_status, output)

        kind = if retry_transport_failure?(output, op_id), do: :transport, else: :error
        {kind, diagnostic}
    end
  rescue
    _ ->
      {:error, "attachment_cli_failed",
       attempt_diagnostic("ATTACH existing same-operation retry", nil, nil)}
  end

  defp attach_once(executable, args, attempt) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} ->
        if Enum.any?(String.split(output, "\n", trim: true), fn line ->
             match?({:ok, %{"kind" => "attached", "ready_for_listen" => true}}, JSON.decode(line))
           end),
           do: :ok,
           else: {:error, "attachment_unconfirmed", attempt_diagnostic(attempt, 0, output)}

      {output, exit_status} ->
        unknown =
          output
          |> String.split("\n", trim: true)
          |> Enum.find_value(fn line ->
            case JSON.decode(line) do
              {:ok, %{"kind" => "outcome_unknown", "op_id" => id}} when is_binary(id) -> id
              _ -> nil
            end
          end)

        diagnostic = attempt_diagnostic(attempt, exit_status, output)

        if unknown,
          do: {:unknown, unknown, diagnostic, attach_transport_failure?(output)},
          else:
            {if(attach_transport_failure?(output), do: :transport, else: :error),
             "attachment_refused", diagnostic}
    end
  rescue
    _ -> {:error, "attachment_cli_failed", attempt_diagnostic(attempt, nil, nil)}
  end

  defp attach_transport_failure?(output) do
    Enum.any?(String.split(output, "\n", trim: true), fn line ->
      case JSON.decode(line) do
        {:ok, %{"kind" => kind, "reason_source" => "agent", "reason_code" => code}}
        when kind in ["refused", "connection_error", "outcome_unknown"] and
               code in ["transport_error", "timeout"] ->
          true

        _ ->
          false
      end
    end)
  end

  # Agent 0.1.6's generic retry omits reason_code. Its ApiError::Transport
  # Display prefix is emitted on stderr beside the same operation's unknown
  # record. Inspect that source-defined prefix, but never retain the raw URL.
  defp retry_transport_failure?(output, op_id) do
    lines = String.split(output, "\n", trim: true)

    Enum.any?(lines, &String.starts_with?(&1, "origin request failed: ")) and
      Enum.any?(lines, fn line ->
        case JSON.decode(line) do
          {:ok, %{"kind" => "outcome_unknown", "op_id" => ^op_id}} -> true
          _ -> false
        end
      end)
  end

  defp attach_result({:unknown, _op_id, diagnostic}),
    do: {:error, "attachment_outcome_unknown", diagnostic}

  defp attach_result({:unknown, _}), do: {:error, "attachment_outcome_unknown", nil}
  defp attach_result({:error, reason}), do: {:error, reason, nil}
  defp attach_result(result), do: result

  defp attempt_diagnostic(attempt, exit_status, output) do
    status = exit_status_detail(exit_status)

    output = sanitize_refusal_output(output)
    output_detail = if output, do: "sanitized output: #{output}", else: "no safe output captured"

    "#{attempt}; #{status}; #{output_detail}"
    |> String.slice(0, @max_diagnostic_line_chars)
  end

  defp listen_attempt_diagnostics(attempt, exit_status, diagnostics) do
    status = exit_status_detail(exit_status)

    case diagnostics do
      [] ->
        ["#{attempt}; #{status}; no safe output captured"]

      [first | rest] ->
        [
          "#{attempt}; #{status}; sanitized output: #{first}"
          | Enum.map(rest, &"sanitized output: #{&1}")
        ]
    end
    |> Enum.take(@max_diagnostic_lines)
    |> Enum.map(&String.slice(&1, 0, @max_diagnostic_line_chars))
  end

  defp exit_status_detail(status) when is_integer(status), do: "exit status: #{status}"
  defp exit_status_detail(_), do: "exit status: unknown (not observed)"

  defp follow(manager, executable, handle) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["listen", "--follow", "--controller", "--session", handle]
      ])

    try do
      case GenServer.call(manager, {:listener_port, handle, port}, :infinity) do
        :ok -> receive_lines(manager, port, handle, "", [])
        {:error, reason} -> finish(manager, handle, reason)
      end
    after
      close_listener_port(port)
    end
  rescue
    _ ->
      finish(
        manager,
        handle,
        failure_status(
          "listener_failed",
          "listen",
          attempt_diagnostic("LISTEN attempt (Port unavailable or receive failed)", nil, nil)
        )
      )
  end

  # Closing stdin alone does not stop a CLI blocked on its SSE stream. Only
  # signal this controller's still-open port child, never another lock holder.
  defp close_listener_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        if Port.info(port), do: Port.close(port)

      _ ->
        :ok
    end
  rescue
    # The worker and its manager both clean up on shutdown. A closed port
    # means the other owner already completed that cleanup.
    ArgumentError -> :ok
  end

  defp receive_lines(manager, port, handle, pending, diagnostics) do
    receive do
      {:EXIT, ^manager, reason} ->
        exit(reason)

      {:EXIT, _sender, :shutdown} ->
        exit(:shutdown)

      {^port, {:data, bytes}} ->
        data = pending <> bytes
        lines = :binary.split(data, "\n", [:global])
        remainder = List.last(lines)

        result =
          lines
          |> Enum.drop(-1)
          |> Enum.reduce_while({:ok, diagnostics}, fn line, {:ok, current_diagnostics} ->
            case receive_listener_line(manager, handle, line, current_diagnostics) do
              {:ok, next_diagnostics} ->
                {:cont, {:ok, next_diagnostics}}

              {:error, reason, next_diagnostics} ->
                {:halt, {:error, reason, next_diagnostics}}
            end
          end)

        case result do
          {:ok, next_diagnostics} ->
            receive_lines(manager, port, handle, remainder, next_diagnostics)

          {:error, reason, next_diagnostics} ->
            close_listener_port(port)

            finish(
              manager,
              handle,
              failure_status(
                reason,
                "listen",
                listen_attempt_diagnostics("LISTEN attempt", nil, next_diagnostics)
              )
            )
        end

      {^port, {:exit_status, 0}} ->
        status =
          if pending == "",
            do: :complete,
            else:
              failure_status(
                "incomplete_line",
                "listen",
                listen_attempt_diagnostics(
                  "LISTEN attempt",
                  0,
                  append_diagnostic(diagnostics, pending)
                )
              )

        finish(manager, handle, status)

      {^port, {:exit_status, exit_status}} ->
        diagnostics = append_diagnostic(diagnostics, pending)

        finish(
          manager,
          handle,
          failure_status(
            "listener_stopped",
            "listen",
            listen_attempt_diagnostics("LISTEN attempt", exit_status, diagnostics)
          )
        )
    end
  end

  # The Agent emits JSON events on stdout and reconnect/refusal messages on
  # stderr. The port merges them; keep plain-text diagnostics without treating
  # them as events, and leave every JSON line on the existing capture path.
  defp receive_listener_line(manager, handle, line, diagnostics) do
    decoded =
      try do
        JSON.decode(line)
      rescue
        _ -> {:error, :invalid_listener_line}
      end

    case decoded do
      {:ok, %{"kind" => kind}}
      when kind in ["refused", "connection_error", "outcome_unknown", "error"] ->
        {:error, "listener_stopped", append_diagnostic(diagnostics, line)}

      {:ok, _event} ->
        case GenServer.call(manager, {:capture, handle, line}, :infinity) do
          :ok -> {:ok, diagnostics}
          {:error, reason} -> {:error, reason, append_diagnostic(diagnostics, line)}
        end

      {:error, _} ->
        diagnostic_line = String.replace_invalid(line)

        if structured_output_line?(diagnostic_line) do
          {:error, "invalid_listener_line", diagnostics}
        else
          {:ok, append_diagnostic(diagnostics, diagnostic_line)}
        end
    end
  end

  defp failure_status(error, operation, diagnostic),
    do: {:harklight_failure, error, operation, diagnostic}

  defp failure_details({:harklight_failure, error, operation, diagnostics}),
    do: {to_string(error), operation, format_failure_diagnostics(diagnostics)}

  defp failure_details(error), do: {to_string(error), nil, nil}

  defp log_listener_failure(handle, status) do
    {error, operation, diagnostic} = failure_details(status)
    handle = sanitize_diagnostic_text(handle) || "unknown"
    error = sanitize_diagnostic_text(error) || "unknown"

    operation =
      if is_binary(operation),
        do: sanitize_diagnostic_text(operation) || "unknown",
        else: "unknown"

    diagnostic =
      diagnostic ||
        "stage/attempt: unknown; exit status: unknown (not observed); no safe output captured"

    Logger.warning(
      "Harklight listener failure handle=#{handle} error=#{error} operation=#{operation}; #{diagnostic}"
    )
  end

  defp format_failure_diagnostics(nil), do: nil

  defp format_failure_diagnostics(diagnostics) when is_binary(diagnostics),
    do: format_failure_diagnostics([diagnostics])

  defp format_failure_diagnostics(diagnostics) when is_list(diagnostics) do
    diagnostics
    |> Enum.map(&sanitize_diagnostic_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(not is_binary(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_diagnostic_lines)
    |> Enum.join(" | ")
    |> String.slice(0, @max_diagnostic_chars)
    |> blank_to_nil()
  end

  @doc false
  def sanitize_refusal_output(output) when is_binary(output) do
    output
    |> String.replace_invalid()
    |> String.split(~r/[\r\n]+/, trim: true)
    |> Enum.flat_map(&refusal_detail_lines/1)
    |> Enum.map(&sanitize_diagnostic_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_diagnostic_lines)
    |> Enum.join(" | ")
    |> String.slice(0, @max_diagnostic_chars)
    |> blank_to_nil()
  end

  def sanitize_refusal_output(_), do: nil

  defp refusal_detail_lines(line) do
    case JSON.decode(String.trim(line)) do
      {:ok, %{"kind" => kind, "reason" => reason}}
      when kind in ["error", "unsupported", "refused", "outcome_unknown", "connection_error"] and
             is_binary(reason) ->
        [reason]

      {:ok, %{"type" => "error", "reason" => reason}} when is_binary(reason) ->
        [reason]

      {:ok,
       %{
         "kind" => "attached",
         "ready_for_listen" => false,
         "listening_support" => %{"unsupported_reason" => reason}
       }}
      when is_binary(reason) ->
        [reason]

      {:ok, _structured_output} ->
        []

      {:error, _} ->
        if structured_output_line?(line), do: [], else: [line]
    end
  end

  defp sanitize_diagnostic_text(text) do
    text =
      text
      |> String.replace_invalid()
      |> String.trim()
      |> String.replace(~r/\{.*\}|\[(?!REDACTED:)[^\]]*\]/u, "[REDACTED:structured output]")
      |> String.replace(~r/https?:\/\/[^\s]+/i, "[REDACTED:url]")
      |> String.replace(
        ~r/\b(payload|body|content|title|message)\s*[:=].*$/i,
        "\\1=[REDACTED:content]"
      )
      |> ErrorDiagnostic.redact_text()
      |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if text == "" do
      nil
    else
      String.slice(text, 0, @max_diagnostic_line_chars)
    end
  end

  defp structured_output_line?(line) do
    String.starts_with?(String.trim_leading(line), ["{", "["])
  end

  defp append_diagnostic(diagnostics, output) do
    case sanitize_refusal_output(output) do
      nil -> diagnostics
      diagnostic -> Enum.take(diagnostics ++ [diagnostic], -@max_diagnostic_lines)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

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

      HarklightLifecycle.hold_terminal_in_txn?(txn, handle, sender_id, message_id, event_id, line) ->
        Txn.q(
          txn,
          "UPDATE harklight_wake_handles SET lastCursor=MAX(lastCursor,?2) WHERE handle=?1",
          [handle, cursor]
        )

        :ok

      HarklightLifecycle.ended_in_txn?(txn, sender_id, message_id) ->
        Txn.q(
          txn,
          "UPDATE harklight_wake_handles SET lastCursor=MAX(lastCursor,?2) WHERE handle=?1",
          [handle, cursor]
        )

        :ok

      true ->
        held = HarklightLifecycle.held_in_txn?(txn, handle, event_id)
        prior_cursor = if held, do: cursor - 1, else: prior_cursor

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
        "UPDATE harklight_wake_handles SET lastCursor=MAX(lastCursor,?2),updatedAt=?3 WHERE handle=?1",
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
