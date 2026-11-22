defmodule Tightbeam.HarklightAgentActions do
  @moduledoc false

  alias Tightbeam.{
    DB,
    HarklightFailures,
    HarklightLifecycle,
    HarklightReceipts,
    HarklightSend,
    HarklightWakes,
    Id,
    Org,
    Placement
  }

  @statuses ~w(received applied refused)

  def read(db, call) do
    with {:ok, handle} <- authorize(db, call, [:handle]),
         {:ok, rows} <- delivered_entries(db, call, handle, nil) do
      output =
        rows
        |> Enum.map(fn [_wake, _turn, _request, line] -> line end)
        |> Enum.uniq()
        |> Enum.join("\n")

      %{command: "read", outcome: "received", handle: handle, output: output}
    else
      {:error, code} -> failure("read", code)
    end
  end

  def acknowledge(db, call, opts \\ []) do
    with {:ok, handle} <- authorize(db, call, [:handle, :event_id]),
         {:ok, event} <- required_text(call.params[:event_id]),
         {:ok, wake, turn, _request, line} <- delivered_event(db, call, handle, event),
         {:ok, _args} <- HarklightReceipts.receipt_target(line) do
      case HarklightReceipts.acknowledge(db, wake, turn, opts) do
        :ok ->
          %{command: "ack", outcome: "acknowledged", handle: handle, event_id: event}

        {:error, reason} ->
          failure("ack", "harklight_outcome_unknown", reason, "outcome_unknown", %{
            handle: handle,
            event_id: event
          })
      end
    else
      :error -> failure("ack", "harklight_action_unsupported")
      {:error, code} -> failure("ack", code)
    end
  end

  def reply(db, call, opts \\ []) do
    with {:ok, body} <- required_text(call.params[:body]) do
      write(db, call, "reply", :body, body, opts)
    else
      {:error, code} -> failure("reply", code)
    end
  end

  def result(db, call, opts \\ []) do
    case call.params[:status] do
      status when status in @statuses -> write(db, call, "result", :status, status, opts)
      _ -> failure("result", "invalid_harklight_action")
    end
  end

  defp write(db, call, command, field, value, opts) do
    with {:ok, handle} <- authorize(db, call, [:handle, :request_id, :in_reply_to, :op_id, field]),
         {:ok, request} <- required_text(call.params[:request_id]),
         {:ok, event} <- required_text(call.params[:in_reply_to]),
         {:ok, op_id} <- operation_id(call.params[:op_id]),
         {:ok, _wake, _turn, ^request, line} <- delivered_event(db, call, handle, event),
         {:ok, target, argv} <- action(command, JSON.decode!(line), value),
         {:ok, runner} <- HarklightSend.runner(opts) do
      run_operation(db, call, runner, command, target, argv, handle, event, op_id)
    else
      {:ok, _wake, _turn, _other_request, _line} -> failure(command, "harklight_event_mismatch")
      {:error, code} -> failure(command, code)
    end
  end

  defp action(
         "reply",
         %{"kind" => "entry", "item_id" => item, "data" => %{"entry_id" => entry}},
         body
       )
       when is_binary(item) and is_binary(entry) do
    {:ok, {:reply, item, entry, body},
     ["reply", "--item-id", item, "--in-reply-to", entry, "--body", body]}
  end

  defp action(
         "result",
         %{"kind" => "message", "item_id" => item, "data" => %{"terminal" => terminal}},
         status
       )
       when is_binary(item) do
    case terminal do
      %{"state" => "answered", "at_ms" => at} when is_integer(at) ->
        {:ok, {:result, item, at, status}, ["result", "--item-id", item, "--status", status]}

      _ ->
        {:error, "harklight_action_unsupported"}
    end
  end

  defp action(_command, _entry, _value), do: {:error, "harklight_action_unsupported"}

  defp authorize(db, call, allowed) do
    session = call[:session_key]
    host = Placement.local_host_name()

    with true <- is_binary(session) and call[:principal] == {:session, session},
         true <- call[:transport_session_key] == session,
         %{state: "active", host: ^host} <- Org.get(db, session),
         :ok <- allowed_params(call.params, allowed),
         {:ok, handle} <- required_text(call.params[:handle]) do
      case DB.query(
             db,
             """
             SELECT 1 FROM harklight_wake_handles h WHERE h.handle=?1 AND h.host=?2 AND (
               h.sessionKey=?3 OR EXISTS (
                 SELECT 1 FROM harklight_wake_follows f WHERE f.handle=h.handle AND f.sessionKey=?3
               ) OR EXISTS (
                 SELECT 1 FROM harklight_wake_deliveries d WHERE d.handle=h.handle
                   AND COALESCE(d.currentRecipientSessionKey,d.sessionKey)=?3
               )
             )
             """,
             [handle, host, session]
           ) do
        {:ok, [[1]]} -> {:ok, handle}
        {:ok, []} -> {:error, "harklight_origin_mismatch"}
        {:error, _} -> {:error, "harklight_origin_unavailable"}
      end
    else
      {:error, code} -> {:error, code}
      _ -> {:error, "harklight_origin_unavailable"}
    end
  end

  defp delivered_entries(db, call, handle, event) do
    case DB.query(
           db,
           """
           SELECT d.wakeId,MIN(l.turnSeq),e.messageId,e.rawLine
           FROM harklight_wake_entries e
           JOIN harklight_wake_deliveries d ON d.handle=e.handle AND d.eventId=e.eventId
           JOIN wakes w ON w.wakeId=d.wakeId OR w.wakeId IN (
             SELECT wakeId FROM wake_retry_attempts WHERE rootWakeId=d.wakeId
           )
           JOIN turns t ON t.seq=w.deliveredTurnSeq AND t.sessionKey=?2
           JOIN turn_lifecycle_events l ON l.kind='prompt_dispatched' AND (
             l.turnSeq=t.seq OR l.turnSeq IN (
               SELECT replacement.seq FROM health_redelivery_attempts a
               JOIN turns replacement ON
                 (replacement.seq=a.redeliveryTurnSeq OR replacement.seq=a.cycleReleaseTurnSeq)
                 AND replacement.sessionKey=t.sessionKey AND replacement.messageId=t.messageId
               WHERE a.sourceTurnSeq=t.seq AND a.sessionKey=t.sessionKey AND a.sourceMessageId=t.messageId
             )
           )
           WHERE e.handle=?1 AND COALESCE(d.currentRecipientSessionKey,d.sessionKey)=?2
             AND w.sessionKey=?2 AND (?3 IS NULL OR e.eventId=?3)
           GROUP BY d.wakeId,e.feedCursor,e.messageId,e.rawLine
           ORDER BY e.feedCursor,MIN(l.turnSeq),d.wakeId
           """,
           [handle, call.session_key, event]
         ) do
      {:ok, rows} -> {:ok, rows}
      {:error, _} -> {:error, "harklight_event_unavailable"}
    end
  end

  defp delivered_event(db, call, handle, event) do
    case delivered_entries(db, call, handle, event) do
      {:ok, [[wake, turn, request, line] | _]} -> {:ok, wake, turn, request, line}
      {:ok, []} -> {:error, "harklight_event_unknown"}
      error -> error
    end
  end

  defp run_operation(db, call, runner, command, target, argv, handle, event, op_id) do
    args = argv ++ ["--op-id", op_id]

    input = %{
      "operation_kind" => "action",
      "handle" => handle,
      "event_id" => event,
      "args" => args
    }

    :global.trans({{__MODULE__, db, op_id}, self()}, fn ->
      with {:ok, journal} <- saved_journal(db, runner, call, op_id, input),
           payload = JSON.encode!(Map.put(input, "journal_id", journal)),
           %{state: _} <- HarklightWakes.prepare_send(db, call, op_id, payload),
           {:ok, cached} <- cached_result(db, op_id) do
        cached || execute(db, call, runner, command, target, args, op_id, journal, payload)
      else
        %{code: code} -> failure(command, code, nil, "refused", %{op_id: op_id})
        {:error, code} -> failure(command, code, nil, nil, %{op_id: op_id})
      end
    end)
  end

  defp saved_journal(db, runner, call, op_id, input) do
    case DB.query(
           db,
           "SELECT sessionKey,host,payload FROM harklight_send_operations WHERE opId=?1",
           [op_id]
         ) do
      {:ok, []} ->
        HarklightSend.journal_id(runner)

      {:ok, [[session, host, payload]]} when session == call.session_key ->
        with true <- host == Placement.local_host_name(),
             {:ok, saved} when is_map(saved) <- JSON.decode(payload),
             {journal, ^input} when is_binary(journal) <- Map.pop(saved, "journal_id") do
          {:ok, journal}
        else
          _ -> {:error, "harklight_send_mismatch"}
        end

      {:ok, _} ->
        {:error, "harklight_send_mismatch"}

      {:error, _} ->
        {:error, "harklight_action_unavailable"}
    end
  end

  defp cached_result(db, op_id) do
    case DB.query(db, "SELECT effects FROM harklight_command_results WHERE opId=?1", [op_id]) do
      {:ok, [[json]]} ->
        saved = JSON.decode!(json)

        {:ok,
         for(
           key <- ~w(command outcome op_id result code reason)a,
           {:ok, value} <- [Map.fetch(saved, Atom.to_string(key))],
           into: %{},
           do: {key, value}
         )}

      {:ok, []} ->
        {:ok, nil}

      {:error, _} ->
        {:error, "harklight_action_unavailable"}
    end
  end

  defp execute(db, call, runner, command, target, args, op_id, journal, payload) do
    with :ok <- HarklightWakes.mark_send_attempt(db, call, op_id, payload),
         {:ok, response} <-
           HarklightFailures.guarded_attempt(db, op_id, :explicit, fn ->
             HarklightSend.recover_action(runner, args, op_id, journal, target)
           end) do
      case response do
        {:ok, frame} ->
          persist(db, %{command: command, outcome: "committed", op_id: op_id, result: frame})

        {:error, code, reason, "refused"} ->
          persist(db, failure(command, code, reason, "refused", %{op_id: op_id}))

        {:internal_error, operation, request_id} ->
          {_, diagnostic} = HarklightFailures.hold_operation(db, operation, op_id, request_id)

          failure(command, "harklight_outcome_unknown", diagnostic, "outcome_unknown", %{
            op_id: op_id
          })

        {:error, code, reason, outcome} ->
          failure(command, code, reason, outcome, %{op_id: op_id})
      end
    else
      {:error, code} -> failure(command, code, nil, "outcome_unknown", %{op_id: op_id})
    end
  end

  defp persist(db, result) do
    case DB.transaction(db, fn txn ->
           HarklightLifecycle.record_result_in_txn(txn, result.op_id, result.outcome, result)
         end) do
      {:ok, _} ->
        result

      {:error, _} ->
        failure(
          result.command,
          "harklight_action_unavailable",
          "Tightbeam could not save the Agent outcome. Retry the unchanged action with the same operation ID.",
          "outcome_unknown",
          %{op_id: result.op_id}
        )
    end
  end

  defp allowed_params(params, allowed) when is_map(params) do
    if Enum.all?(Map.keys(params), &(&1 in allowed)),
      do: :ok,
      else: {:error, "invalid_harklight_action"}
  end

  defp required_text(value) when is_binary(value) and value != "", do: {:ok, value}
  defp required_text(_), do: {:error, "invalid_harklight_action"}

  defp operation_id(nil), do: {:ok, Id.uuid4()}

  defp operation_id(value) when is_binary(value) do
    id = String.downcase(value)

    if Regex.match?(
         ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
         id
       ),
       do: {:ok, id},
       else: {:error, "invalid_harklight_action"}
  end

  defp operation_id(_), do: {:error, "invalid_harklight_action"}

  defp failure(command, code, reason \\ nil, outcome \\ nil, fields \\ %{}) do
    Map.merge(fields, %{
      command: command,
      code: code,
      reason: reason || reason_for(code),
      outcome: outcome || failure_outcome(code)
    })
  end

  defp failure_outcome(code)
       when code in [
              "invalid_harklight_action",
              "harklight_origin_unavailable",
              "harklight_origin_mismatch",
              "harklight_event_unknown",
              "harklight_event_mismatch",
              "harklight_action_unsupported",
              "harklight_send_mismatch"
            ],
       do: "refused"

  defp failure_outcome(_), do: "failed"

  defp reason_for("invalid_harklight_action"), do: "The Harklight action inputs are invalid."

  defp reason_for("harklight_origin_unavailable"),
    do: "This session has no active Harklight origin on this host."

  defp reason_for("harklight_origin_mismatch"),
    do: "This session does not have access to that Harklight handle."

  defp reason_for("harklight_event_unknown"),
    do: "This event was not delivered to the current session from that Harklight handle."

  defp reason_for("harklight_event_mismatch"),
    do: "The request ID does not match the delivered Harklight event."

  defp reason_for("harklight_action_unsupported"),
    do: "Agent 0.2 does not support this action for that kind of Harklight entry."

  defp reason_for("harklight_send_mismatch"),
    do: "Reuse the operation ID only with the same session and unchanged action."

  defp reason_for(code), do: "The Harklight action could not run: #{code}."
end
