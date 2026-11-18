defmodule Tightbeam.HarklightAgentActions do
  @moduledoc false

  alias Tightbeam.{DB, HarklightLifecycle, HarklightSend, HarklightWakes, Id, Org, Placement}

  @statuses ~w(received applied refused)

  def read(db, call, opts \\ []) do
    with :ok <- origin(db, call),
         :ok <- allowed_params(call.params, [:handle]),
         {:ok, handle} <- owned_handle(db, call, call.params[:handle]),
         {:ok, runner} <- runner(opts) do
      run_read(db, call, runner, handle)
    else
      {:error, code, reason} -> failure("read", code, reason, "refused")
      {:error, code} -> failure("read", code, reason_for(code), failure_outcome(code))
    end
  end

  def acknowledge(db, call, opts \\ []) do
    with :ok <- origin(db, call),
         :ok <- allowed_params(call.params, [:handle, :event_id]),
         {:ok, handle} <- owned_handle(db, call, call.params[:handle]),
         {:ok, event_id} <- required_text(call.params[:event_id], "event_id"),
         :ok <- delivered_event(db, call, handle, event_id),
         {:ok, runner} <- runner(opts) do
      run_acknowledge(runner, handle, event_id)
    else
      {:error, code, reason} -> failure("ack", code, reason, "refused")
      {:error, code} -> failure("ack", code, reason_for(code), failure_outcome(code))
    end
  end

  def reply(db, call, opts \\ []) do
    with :ok <- origin(db, call),
         :ok <- allowed_params(call.params, [:handle, :request_id, :in_reply_to, :body, :op_id]),
         {:ok, handle} <- owned_handle(db, call, call.params[:handle]),
         {:ok, request_id} <- required_text(call.params[:request_id], "request_id"),
         {:ok, event_id} <- required_text(call.params[:in_reply_to], "in_reply_to"),
         {:ok, body} <- required_text(call.params[:body], "body"),
         {:ok, op_id} <- optional_text(call.params[:op_id], "op_id"),
         :ok <- delivered_request_event(db, call, handle, event_id, request_id),
         {:ok, runner} <- runner(opts) do
      args = [
        "reply",
        "--session",
        handle,
        "--request",
        request_id,
        "--in-reply-to",
        event_id,
        "--body",
        body
      ]

      args = maybe_add_op_id(args, op_id)
      run_operation(db, call, runner, "reply", args, op_id)
    else
      {:error, code, reason} -> failure("reply", code, reason, "refused")
      {:error, code} -> failure("reply", code, reason_for(code), failure_outcome(code))
    end
  end

  def result(db, call, opts \\ []) do
    with :ok <- origin(db, call),
         :ok <- allowed_params(call.params, [:handle, :request_id, :in_reply_to, :status, :op_id]),
         {:ok, handle} <- owned_handle(db, call, call.params[:handle]),
         {:ok, request_id} <- required_text(call.params[:request_id], "request_id"),
         {:ok, event_id} <- required_text(call.params[:in_reply_to], "in_reply_to"),
         {:ok, status} <- result_status(call.params[:status]),
         {:ok, op_id} <- optional_text(call.params[:op_id], "op_id"),
         :ok <- delivered_request_event(db, call, handle, event_id, request_id),
         {:ok, runner} <- runner(opts) do
      args = [
        "result",
        "--session",
        handle,
        "--request",
        request_id,
        "--in-reply-to",
        event_id,
        "--status",
        status
      ]

      args = maybe_add_op_id(args, op_id)
      run_operation(db, call, runner, "result", args, op_id)
    else
      {:error, code, reason} -> failure("result", code, reason, "refused")
      {:error, code} -> failure("result", code, reason_for(code), failure_outcome(code))
    end
  end

  defp origin(db, call) do
    session_key = call[:session_key]

    with true <- is_binary(session_key),
         true <- call[:principal] == {:session, session_key},
         true <- call[:transport_session_key] == session_key,
         %{state: "active", host: host} <- Org.get(db, session_key),
         true <- host == Placement.local_host_name() do
      :ok
    else
      _ -> {:error, "harklight_origin_unavailable"}
    end
  end

  defp owned_handle(db, call, handle) do
    with {:ok, handle} <- required_text(handle, "handle") do
      case DB.query(db, "SELECT sessionKey,host FROM harklight_wake_handles WHERE handle=?1", [
             handle
           ]) do
        {:ok, [[session_key, host]]} ->
          if host == Placement.local_host_name() and
               (session_key == call.session_key or followed_or_delivered?(db, call, handle)),
             do: {:ok, handle},
             else: {:error, "harklight_origin_mismatch"}

        {:ok, _} ->
          {:error, "harklight_origin_mismatch"}

        {:error, _} ->
          {:error, "harklight_origin_unavailable"}
      end
    end
  end

  defp followed_or_delivered?(db, call, handle) do
    case DB.query(
           db,
           """
           SELECT 1 WHERE EXISTS (
             SELECT 1 FROM harklight_wake_follows WHERE handle=?1 AND sessionKey=?2
           ) OR EXISTS (
             SELECT 1 FROM harklight_wake_deliveries
             WHERE handle=?1 AND COALESCE(currentRecipientSessionKey,sessionKey)=?2
           )
           """,
           [handle, call.session_key]
         ) do
      {:ok, [[1]]} -> true
      _ -> false
    end
  end

  @delivered_from """
  FROM harklight_wake_entries e
  JOIN harklight_wake_deliveries d ON d.handle=e.handle AND d.eventId=e.eventId
  JOIN wakes w ON w.wakeId=d.wakeId OR w.wakeId IN (
    SELECT wakeId FROM wake_retry_attempts WHERE rootWakeId=d.wakeId
  )
  JOIN turns t ON t.seq=w.deliveredTurnSeq
  JOIN harklight_wake_handles h ON h.handle=e.handle
  WHERE e.handle=?1 AND COALESCE(d.currentRecipientSessionKey,d.sessionKey)=?2
    AND w.sessionKey=?2 AND t.sessionKey=?2 AND h.host=?3
  """

  defp delivered_event(db, call, handle, event_id) do
    case delivered_request(db, call, handle, event_id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp delivered_request_event(db, call, handle, event_id, request_id) do
    case delivered_request(db, call, handle, event_id) do
      {:ok, ^request_id} -> :ok
      {:ok, _} -> {:error, "harklight_event_mismatch"}
      error -> error
    end
  end

  defp delivered_request(db, call, handle, event_id) do
    case DB.query(db, "SELECT DISTINCT e.messageId " <> @delivered_from <> " AND e.eventId=?4", [
           handle,
           call.session_key,
           Placement.local_host_name(),
           event_id
         ]) do
      {:ok, [[message_id]]} -> {:ok, message_id}
      {:ok, []} -> {:error, "harklight_event_unknown"}
      {:error, _} -> {:error, "harklight_event_unavailable"}
    end
  end

  defp run_read(db, call, runner, handle) do
    case DB.query(db, "SELECT sessionKey FROM harklight_wake_handles WHERE handle=?1", [handle]) do
      {:ok, [[owner]]} when owner == call.session_key ->
        run_read(runner, handle)

      {:ok, [[_owner]]} ->
        with {:ok, rows} <-
               DB.query(db, "SELECT DISTINCT e.eventId " <> @delivered_from, [
                 handle,
                 call.session_key,
                 Placement.local_host_name()
               ]) do
          allowed = MapSet.new(rows, fn [event_id] -> event_id end)

          case run_read(runner, handle) do
            %{outcome: "received", output: output} = result ->
              filtered =
                output
                |> String.split("\n", trim: true)
                |> Enum.filter(fn line ->
                  case JSON.decode(line) do
                    {:ok, %{"kind" => "event", "event_id" => event_id}} ->
                      MapSet.member?(allowed, to_string(event_id))

                    _ ->
                      false
                  end
                end)
                |> Enum.join("\n")

              %{result | output: filtered}

            result ->
              result
          end
        else
          {:error, _} ->
            failure(
              "read",
              "harklight_event_unavailable",
              reason_for("harklight_event_unavailable"),
              "failed"
            )
        end
    end
  end

  defp allowed_params(params, allowed) when is_map(params) do
    if Enum.all?(Map.keys(params), &(&1 in allowed)),
      do: :ok,
      else: {:error, "invalid_harklight_action"}
  end

  defp allowed_params(_, _), do: {:error, "invalid_harklight_action"}

  defp required_text(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  defp required_text(_, _name), do: {:error, "invalid_harklight_action"}

  defp optional_text(nil, _name), do: {:ok, nil}
  defp optional_text(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_text(_, _name), do: {:error, "invalid_harklight_action"}

  defp result_status(status) when status in @statuses, do: {:ok, status}
  defp result_status(_), do: {:error, "invalid_harklight_action"}

  defp runner(opts) do
    case Keyword.get(opts, :runner) do
      fun when is_function(fun, 1) ->
        {:ok, fun}

      nil ->
        case System.find_executable("harklight-agent") do
          nil -> {:error, "harklight_cli_missing"}
          executable -> {:ok, fn args -> System.cmd(executable, args, stderr_to_stdout: true) end}
        end
    end
  end

  defp run_read(runner, handle) do
    case runner.(["read", "--session", handle]) do
      {output, 0} ->
        %{command: "read", outcome: "received", handle: handle, output: output}

      {output, 2} ->
        failure("read", "harklight_refused", String.trim(output), "refused", %{handle: handle})

      {output, _status} ->
        failure("read", "harklight_read_failed", String.trim(output), "failed", %{handle: handle})
    end
  rescue
    error ->
      failure("read", "harklight_cli_failed", Exception.message(error), "failed", %{
        handle: handle
      })
  end

  defp run_acknowledge(runner, handle, event_id) do
    {output, status} = runner.(["ack", "--session", handle, "--event", event_id])

    case frames(output) do
      [%{"kind" => "acknowledged", "event_id" => ^event_id, "status" => ack_status} = frame]
      when status == 0 and ack_status in ["delivered", "already_delivered"] ->
        %{
          command: "ack",
          outcome: "acknowledged",
          handle: handle,
          event_id: event_id,
          result: frame
        }

      [%{"kind" => "outcome_unknown"} = frame] ->
        failure(
          "ack",
          "harklight_outcome_unknown",
          frame["reason"] || String.trim(output),
          "outcome_unknown",
          %{handle: handle, event_id: event_id}
        )

      [%{"kind" => "refused"} = frame] ->
        failure("ack", "harklight_refused", frame["reason"] || String.trim(output), "refused", %{
          handle: handle,
          event_id: event_id
        })

      [] when status == 2 ->
        failure("ack", "harklight_refused", String.trim(output), "refused", %{
          handle: handle,
          event_id: event_id
        })

      _ ->
        failure(
          "ack",
          "harklight_result_unconfirmed",
          "Harklight did not confirm the acknowledgment: " <> String.trim(output),
          "outcome_unknown",
          %{handle: handle, event_id: event_id}
        )
    end
  rescue
    error ->
      failure("ack", "harklight_cli_failed", Exception.message(error), "failed", %{
        handle: handle,
        event_id: event_id
      })
  end

  defp run_operation(db, call, runner, command, args, requested_op_id) do
    op_id = requested_op_id || Id.uuid4()
    args = if requested_op_id, do: args, else: maybe_add_op_id(args, op_id)
    payload = JSON.encode!(%{operation_kind: "action", command: command, args: args})

    # Use the same immutable operation correlation and helper journal recovery as
    # send/change settlement. The retry lookup must precede the helper's acted check.
    :global.trans({{__MODULE__, db, op_id}, self()}, fn ->
      case HarklightWakes.prepare_send(db, call, op_id, payload) do
        %{state: _} ->
          with {:ok, rows} <-
                 DB.query(db, "SELECT effects FROM harklight_command_results WHERE opId=?1", [
                   op_id
                 ]) do
            case rows do
              [[json]] ->
                saved = JSON.decode!(json)

                Map.new(
                  ~w(command outcome op_id result code reason)a
                  |> Enum.filter(&Map.has_key?(saved, Atom.to_string(&1))),
                  fn key -> {key, saved[Atom.to_string(key)]} end
                )

              [] ->
                with :ok <- HarklightWakes.mark_send_attempt(db, call, op_id, payload) do
                  result =
                    case HarklightSend.recover_action(runner, args, op_id) do
                      {:ok, frame} ->
                        %{command: command, outcome: "committed", op_id: op_id, result: frame}

                      {:error, code, reason, outcome} ->
                        failure(command, code, reason, outcome, %{op_id: op_id})
                    end

                  persist_action_result(db, result)
                else
                  {:error, code} ->
                    failure(
                      command,
                      code,
                      "The saved action could not be marked for execution; no action was run.",
                      "failed",
                      %{op_id: op_id}
                    )
                end
            end
          else
            {:error, _} ->
              failure(
                command,
                "harklight_action_unavailable",
                "The saved action outcome could not be read; no action was run.",
                "failed",
                %{op_id: op_id}
              )
          end

        %{code: code} ->
          failure(
            command,
            code,
            "The operation ID must name this session's unchanged action; the saved operation was not run.",
            "refused",
            %{op_id: op_id}
          )
      end
    end)
  end

  defp persist_action_result(db, %{outcome: outcome} = result)
       when outcome in ["committed", "refused"] do
    case DB.transaction(db, fn txn ->
           HarklightLifecycle.record_result_in_txn(txn, result.op_id, outcome, result)
         end) do
      {:ok, _} ->
        result

      {:error, _} ->
        failure(
          result.command,
          "harklight_action_unavailable",
          "The helper outcome could not be saved; retry this unchanged action with the same operation ID.",
          "outcome_unknown",
          %{op_id: result.op_id}
        )
    end
  end

  defp persist_action_result(_db, result), do: result

  defp frames(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case JSON.decode(line) do
        {:ok, %{"kind" => _} = frame} -> [frame]
        _ -> []
      end
    end)
  end

  defp maybe_add_op_id(args, nil), do: args
  defp maybe_add_op_id(args, op_id), do: args ++ ["--op-id", op_id]

  defp failure_outcome(code)
       when code in [
              "invalid_harklight_action",
              "harklight_origin_unavailable",
              "harklight_origin_mismatch",
              "harklight_event_unknown",
              "harklight_event_mismatch"
            ],
       do: "refused"

  defp failure_outcome(_), do: "failed"

  defp reason_for("invalid_harklight_action"), do: "The Harklight action inputs are invalid."

  defp reason_for("harklight_origin_unavailable"),
    do: "This session has no active Harklight origin on this host."

  defp reason_for("harklight_origin_mismatch"),
    do: "This Harklight handle belongs to a different Tightbeam session."

  defp reason_for("harklight_event_unknown"),
    do: "This event was not delivered to the current session from that Harklight handle."

  defp reason_for("harklight_event_mismatch"),
    do: "The request ID does not match the delivered Harklight event."

  defp reason_for("harklight_event_unavailable"),
    do: "The delivered Harklight event could not be read."

  defp reason_for("harklight_cli_missing"), do: "Harklight Agent could not be run."
  defp reason_for(code), do: "The Harklight action could not run: #{code}."

  defp failure(command, code, reason, outcome, fields \\ %{}) do
    Map.merge(fields, %{command: command, code: code, reason: reason, outcome: outcome})
  end
end
