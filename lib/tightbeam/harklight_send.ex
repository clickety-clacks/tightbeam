defmodule Tightbeam.HarklightSend do
  @moduledoc false

  alias Tightbeam.{
    DB,
    HarklightFailures,
    HarklightLifecycle,
    HarklightReceipts,
    HarklightWakes,
    Id,
    Org,
    Placement
  }

  @uuid4 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  @decision_request_id ~r/\Adr_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def send_request(db, call, opts \\ []) do
    result =
      with :ok <- origin!(db, call),
           {:ok, input} <- inputs(call.params),
           {:ok, input, unresolved} <- split_unresolved(db, input),
           {:ok, runner} <- runner(opts) do
        send_with_association(db, call, Map.put(input, :unresolved, unresolved), runner, opts)
        |> Map.put(:message_type, input.message_type)
        |> Map.put(:message_type_label, type_label(input.message_type))
      else
        {:unresolved, id} -> unresolved_result("send", id)
        {:error, code, reason} -> failure("send", code, reason, "failed")
        {:error, reason} -> failure("send", reason, early_reason(reason), "failed")
      end

    result =
      if is_binary(call.params[:sender_id]),
        do: Map.put_new(result, :sender_id, call.params.sender_id),
        else: result

    unchanged_targets(result, call.params[:supersedes])
  end

  # A superseded target whose own send is unresolved (outcome unknown) cannot be
  # acted on yet. It is dropped from the request and reported per target, like
  # the invalid, unknown and closed targets Harklight warns about. A send whose
  # only supersede targets are unresolved is still refused as a whole.
  defp split_unresolved(db, input) do
    {pending, usable} =
      Enum.split_with(
        input.supersedes,
        &match?(%{state: "pending"}, HarklightLifecycle.lookup(db, &1))
      )

    cond do
      pending == [] -> {:ok, input, []}
      usable == [] -> {:unresolved, hd(pending)}
      true -> {:ok, %{input | supersedes: usable}, Enum.uniq(pending)}
    end
  end

  defp send_with_association(db, call, %{decision_request_id: nil} = input, runner, opts) do
    send_with_operation(db, call, input, Id.uuid4(), runner, opts)
  end

  defp send_with_association(db, call, input, runner, opts) do
    case Tightbeam.HarklightBriefings.reserve_send(db, call, input.decision_request_id) do
      {:ok, %{action: :start, op_id: op_id}} ->
        send_with_operation(db, call, input, op_id, runner, opts)

      {:ok, %{action: :recover, message_id: message_id}} ->
        recover_one(db, message_id, opts)
        |> Map.put(:reconciled, true)

      {:ok, %{action: :existing} = existing} ->
        %{
          command: "send",
          outcome: "committed",
          state: "registered",
          reused: true,
          op_id: existing.op_id,
          handle: existing.handle,
          sender_id: existing.sender_id,
          message_id: existing.message_id,
          session_key: existing.session_key,
          wake_effect: "none"
        }

      {:error, code, reason} ->
        failure("send", code, "The message was not sent. " <> reason, "refused", %{
          decision_request_id: input.decision_request_id
        })
    end
  end

  defp send_with_operation(db, call, input, op_id, runner, opts) do
    with {:ok, targets} <- resolve_supersedes(db, runner, input),
         {:ok, journal_id} <- journal_id(runner),
         {:ok, prepared} <-
           invoke(runner, prepare_args(input, targets, op_id), "prepared", op_id) do
      prepare_and_execute(db, call, input, targets, prepared, op_id, journal_id, runner, opts)
    else
      {:internal_error, operation, request_id} ->
        failure(
          "send",
          "internal_error",
          HarklightFailures.log_error(operation, request_id),
          "failed"
        )

      {:error, code, reason, outcome} ->
        failure("send", code, "The message was not sent. " <> reason, outcome, %{op_id: op_id})

      {:error, {:refused, code}} ->
        failure("send", code, early_reason(code), "refused", %{op_id: op_id})

      {:error, code} ->
        failure("send", code, early_reason(code), "failed", %{op_id: op_id})
    end
  end

  defp prepare_and_execute(db, call, input, targets, prepared, op_id, journal_id, runner, opts) do
    identity = %{op_id: op_id, handle: prepared["session_handle"], sender_id: input.sender}

    with {:ok, request, files} <- prepared_request(prepared, input, targets, op_id, journal_id),
         :ok <- handle_available(db, call, input.session, request["session_handle"]),
         payload = send_payload(request, files, input.decision_request_id, input.unresolved),
         %{state: "pending"} <- HarklightWakes.prepare_send(db, call, op_id, payload) do
      :global.trans({{__MODULE__, db, op_id}, self()}, fn ->
        with :ok <- HarklightWakes.mark_send_attempt(db, call, op_id, payload) do
          response =
            if prepared["kind"] == "committed",
              do: {:ok, prepared},
              else:
                invoke(runner, ["send", "--execute", "--op-id", op_id], "committed", op_id,
                  change: true
                )

          finish_send(db, call, op_id, payload, request, response, "send", opts)
        else
          {:error, reason} -> failure("send", reason, early_reason(reason), "failed", identity)
        end
      end)
    else
      %{code: code} -> failure("send", code, early_reason(code), "failed", identity)
      {:error, code} -> failure("send", code, early_reason(code), "failed", identity)
    end
  end

  defp send_payload(request, files, decision_request_id, unresolved) do
    %{"request" => request, "files" => files}
    |> put_unless_nil("decision_request_id", decision_request_id)
    |> put_unless_nil("unresolved_supersedes", if(unresolved != [], do: unresolved))
    |> JSON.encode!()
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp finish_send(db, call, op_id, payload, request, response, command, opts) do
    identity = %{
      op_id: op_id,
      handle: request["session_handle"],
      sender_id: request["message"]["sender_id"]
    }

    result =
      case response do
        {:ok, committed} ->
          with {:ok, item_id, result} <- confirmed_result(committed, request, op_id),
               %{state: "registered"} = registration <-
                 bind(db, call, op_id, payload, result, request, item_id) do
            HarklightLifecycle.process_terminals(db, opts)

            registration
            |> Map.merge(identity)
            |> Map.merge(%{
              command: command,
              outcome: "committed",
              result: committed,
              message_id: item_id
            })
            |> maybe_put_possible_contradictions(command, committed)
            |> HarklightLifecycle.refresh_acknowledgments_result(db)
          else
            error ->
              failure(
                command,
                "harklight_result_unconfirmed",
                unknown_reason(op_id) <>
                  " Binding was not confirmed: #{inspect(error)}",
                "outcome_unknown",
                identity
              )
          end

        {:error, code, reason, outcome} when outcome in ["refused", "failed"] ->
          HarklightLifecycle.record_refused(db, op_id)
          HarklightLifecycle.process_terminals(db, opts)
          failure(command, code, reason, outcome, identity)

        {:internal_error, operation, request_id} ->
          reason = HarklightFailures.hold_operation(db, operation, op_id, request_id)

          failure(
            command,
            "internal_error",
            "#{unknown_reason(op_id)} #{reason}",
            "outcome_unknown",
            identity
          )

        {:error, code, reason, _outcome} ->
          failure(
            command,
            code,
            unknown_reason(op_id) <> " " <> reason,
            "outcome_unknown",
            identity
          )
      end

    unchanged_targets(result, request["message"]["supersedes"])
  end

  defp unchanged_targets(%{outcome: "committed"} = result, _ids), do: result

  defp unchanged_targets(result, ids) when is_list(ids) and ids != [] do
    Map.put(
      result,
      :supersedes,
      Enum.map(Enum.uniq(ids), &%{message_id: &1, effect: "unchanged"})
    )
  end

  defp unchanged_targets(result, _ids), do: result

  # Both entry points use the original operation and the immutable prepared
  # bytes. Recovery never prepares a second send or changes its inputs.
  def recover_pending(db, opts \\ []) do
    with {:ok, rows} <- HarklightWakes.pending_send_attempts(db) do
      Enum.each(rows, fn [_op, _session, payload] ->
        request = JSON.decode!(payload)["request"]

        if request && request["protocol"] == 2 do
          recover_one(db, request["message"]["message_id"], opts)
        end
      end)
    end

    :ok
  end

  def settle(db, call, opts \\ []) do
    op_id = call.params[:op_id]
    message = call.params[:message_id] || op_id

    with :ok <- origin!(db, call) do
      send_record = HarklightLifecycle.lookup(db, message)
      change_record = HarklightLifecycle.lookup_change(db, message)

      cond do
        is_nil(call.params[:message_id]) and
            (not is_binary(op_id) or not match?(%{op_id: ^op_id}, send_record)) ->
          settle_receipt(db, call.session_key, op_id, opts)

        is_nil(send_record) and is_nil(change_record) ->
          settle_unrecorded(call, message, op_id, opts)

        op_id_contradicts?(op_id, send_record, change_record) ->
          failure(
            "settle",
            "harklight_op_id_mismatch",
            early_reason("harklight_op_id_mismatch"),
            "refused",
            identity(send_record) |> Map.put_new(:message_id, message)
          )

        true ->
          recover_one(db, message, opts, :explicit)
      end
    else
      {:error, code} -> failure("settle", code, early_reason(code), "failed")
    end
  end

  defp settle_receipt(db, session_key, op_id, opts) do
    case HarklightReceipts.settle_paused(db, session_key, op_id, opts) do
      :ok ->
        %{command: "settle", outcome: "committed", settled_command: "receipt", op_id: op_id}

      {:error, reason} ->
        failure("settle", "harklight_receipt_unresolved", reason, "outcome_unknown", %{
          op_id: op_id
        })

      :unknown ->
        failure(
          "settle",
          "harklight_operation_unknown",
          "Tightbeam has no send or paused handoff receipt for this operation ID.",
          "refused",
          %{op_id: op_id}
        )
    end
  end

  defp op_id_contradicts?(nil, _send, _change), do: false

  defp op_id_contradicts?(op_id, send, change),
    do: op_id not in for(%{op_id: id} <- [send, change], do: id)

  # Tightbeam has no record of this message, so it cannot find the operation to
  # retry. The caller names it; Harklight alone decides what that retry does.
  # No wake or subscription bookkeeping is created or changed.
  defp settle_unrecorded(_call, message, nil, _opts) do
    failure(
      "settle",
      "harklight_op_id_required",
      early_reason("harklight_op_id_required"),
      "refused",
      %{message_id: message}
    )
  end

  defp settle_unrecorded(_call, message, op_id, opts) do
    with {:uuid, true} <- {:uuid, is_binary(op_id) and Regex.match?(@uuid4, op_id)},
         {:ok, runner} <- runner(opts) do
      case invoke(runner, ["retry", "--op-id", op_id], "committed", op_id,
             change: true,
             operations: ["send", "revise", "retract", "progress"]
           ) do
        {:ok, _frame} ->
          Map.merge(%{message_id: message, op_id: op_id}, no_subscription_effect())
          |> Map.merge(%{command: "settle", outcome: "committed"})

        {:internal_error, operation, request_id} ->
          reason = HarklightFailures.log_error(operation, request_id, op_id)

          failure("settle", "internal_error", reason, "outcome_unknown", %{
            message_id: message,
            op_id: op_id
          })

        {:error, code, reason, outcome} ->
          failure("settle", code, reason, outcome, %{message_id: message, op_id: op_id})
      end
    else
      {:uuid, false} ->
        failure(
          "settle",
          "harklight_op_id_invalid",
          early_reason("harklight_op_id_invalid"),
          "refused",
          %{message_id: message}
        )

      {:error, code} ->
        failure("settle", code, early_reason(code), "failed", %{message_id: message})
    end
  end

  defp no_subscription_effect,
    do: %{
      wake_effect: "none",
      subscription_effect: "none",
      note: HarklightLifecycle.no_subscription_effect_note()
    }

  defp recover_one(db, message, opts, mode \\ :automatic) do
    send_record = HarklightLifecycle.lookup(db, message)
    change_record = HarklightLifecycle.lookup_change(db, message)

    cond do
      match?(%{state: "pending"}, send_record) ->
        recover_send(db, message, opts, send_record, mode)

      match?(%{state: "pending"}, change_record) ->
        recover_change(db, message, opts, send_record, change_record, mode)

      not is_nil(change_record) ->
        already_settled_change(send_record, change_record)

      true ->
        already_settled(send_record, message)
    end
  end

  defp recover_send(db, message, opts, %{op_id: op_id}, mode) do
    :global.trans({{__MODULE__, db, op_id}, self()}, fn ->
      case HarklightLifecycle.lookup(db, message) do
        %{state: "pending"} = record ->
          call = %{
            session_key: record.session_key,
            principal: {:session, record.session_key},
            transport_session_key: record.session_key
          }

          with :ok <- allow_send_recovery(db, op_id, mode),
               :ok <- origin!(db, call),
               {:ok, runner} <- runner(opts),
               %{"protocol" => 2, "journal_id" => journal_id} when is_binary(journal_id) <-
                 record.request do
            finish_send(
              db,
              call,
              op_id,
              record.payload,
              record.request,
              invoke(
                runner,
                ["retry", "--op-id", op_id, "--journal-id", journal_id],
                "committed",
                op_id,
                operations: ["send"],
                journal_id: journal_id,
                change: true
              ),
              "settle",
              opts
            )
          else
            {:held, diagnostic} ->
              failure(
                "settle",
                "internal_error",
                "#{unknown_reason(op_id)} #{diagnostic}",
                "outcome_unknown",
                identity(record) |> Map.put(:op_id, op_id)
              )

            {:error, code} ->
              failure(
                "settle",
                code,
                early_reason(code) <> " " <> unknown_reason(op_id),
                "failed",
                identity(record)
              )
              |> unchanged_targets(record.request["message"]["supersedes"])

            _ ->
              failure(
                "settle",
                "harklight_journal_unavailable",
                "The saved send has no Agent 0.2 journal identity.",
                "outcome_unknown",
                %{op_id: op_id}
              )
          end

        record ->
          already_settled(record, message)
      end
    end)
  end

  defp allow_send_recovery(_db, _op_id, :explicit), do: :ok

  defp allow_send_recovery(db, op_id, :automatic) do
    case HarklightFailures.operation_pause(db, op_id) do
      {:ok, nil} -> :ok
      {:ok, diagnostic} -> {:held, diagnostic}
      {:error, _reason} -> {:error, "harklight_recovery_state_unavailable"}
    end
  end

  defp recover_change(db, message, opts, send_record, %{op_id: op_id} = pending, mode) do
    target = change_target_for_settle(send_record, pending)

    :global.trans({{__MODULE__, db, "change", message}, self()}, fn ->
      case HarklightLifecycle.lookup_change(db, message) do
        %{state: "pending"} = change ->
          call = %{
            session_key: change.session_key,
            principal: {:session, change.session_key},
            transport_session_key: change.session_key
          }

          with :ok <- allow_send_recovery(db, op_id, mode),
               :ok <- origin!(db, call),
               {:ok, runner} <- runner(opts) do
            response = retry_change(runner, change)
            finish_change(db, target, op_id, change.command, response, "settle")
          else
            {:held, diagnostic} ->
              failure("settle", "internal_error", diagnostic, "outcome_unknown", %{
                op_id: op_id,
                message_id: message
              })

            {:error, code} ->
              failure(
                "settle",
                code,
                early_reason(code) <>
                  " The saved #{change.command} request remains unresolved; retry settlement when the originating session is available.",
                "failed",
                identity(target) |> Map.put(:op_id, op_id)
              )
          end

        change ->
          already_settled_change(send_record, change)
      end
    end)
  end

  # With no send record, the saved change request is the only source of the
  # session handle; the change was made without any subscription bookkeeping.
  defp change_target_for_settle(nil, change),
    do: %{handle: change.handle, message_id: change.message_id, unrecorded: true}

  defp change_target_for_settle(send_record, _change), do: send_record

  defp already_settled_change(send_record, nil), do: already_settled(send_record, nil)

  defp already_settled_change(send_record, change) do
    identity = identity(send_record) |> Map.put(:op_id, change.op_id)

    failure(
      "settle",
      "harklight_already_settled",
      "The #{change.command} operation for message #{change.message_id} is already settled as #{change.state}; no operation was run.",
      "refused",
      identity
    )
  end

  defp already_settled(nil, message), do: unknown_message("settle", message)

  defp already_settled(record, _message),
    do:
      failure(
        "settle",
        "harklight_already_settled",
        "The send is already settled as #{record.state}; no operation was run.",
        "refused",
        identity(record)
      )

  def change_request(db, call, command, opts \\ []) do
    message = call.params[:message_id]

    with :ok <- origin!(db, call) do
      :global.trans({{__MODULE__, db, "change", message}, self()}, fn ->
        case HarklightLifecycle.unresolved_change(db, message) do
          nil ->
            change_request_locked(db, call, command, opts)

          change ->
            record = HarklightLifecycle.lookup(db, message)
            unresolved_change_result(command, message, record, change)
        end
      end)
    else
      {:error, code} ->
        failure(command, code, early_reason(code), "failed", %{message_id: message})
    end
  end

  defp change_request_locked(db, call, command, opts) do
    message = call.params[:message_id]

    with {:ok, record} <- change_target(db, message, call.params[:handle]),
         :ok <- resolved(record),
         {:ok, runner} <- runner(opts),
         {:ok, item_id} <- change_item_id(runner, record),
         {:ok, args} <- change_args(command, call.params, Map.put(record, :item_id, item_id)),
         {:ok, journal_id} <- journal_id(runner) do
      op_id = Id.uuid4()
      request = args ++ ["--op-id", op_id]
      stored_command = if command == "progress", do: "revise", else: command
      in_reply_to = call.params[:in_reply_to]

      context = %{
        journal_id: journal_id,
        item_id: item_id,
        handle: record.handle,
        in_reply_to: in_reply_to
      }

      case HarklightWakes.prepare_change(
             db,
             call,
             op_id,
             message,
             stored_command,
             request,
             context
           ) do
        %{state: "pending"} ->
          finish_change(
            db,
            record,
            op_id,
            stored_command,
            invoke_change(runner, request, op_id, item_id, command, in_reply_to),
            command
          )

        %{code: code} ->
          failure(command, code, early_reason(code), "failed", identity(record))
      end
    else
      {:internal_error, operation, request_id} ->
        failure(
          command,
          "internal_error",
          HarklightFailures.log_error(operation, request_id),
          "failed",
          %{message_id: message}
        )

      {:error, {:refused, code}} ->
        failure(command, code, early_reason(code), "refused", %{message_id: message})

      {:error, {:unresolved, id}} ->
        unresolved_result(command, id)

      {:error, code} ->
        failure(command, code, early_reason(code), "failed", %{message_id: message})
    end
  end

  defp unresolved_change_result(command, message, send_record, change) do
    failure(
      command,
      "harklight_operation_unresolved",
      "The #{change.command} operation #{change.op_id} is unresolved. Run tightbeam harklight-settle --message #{message} to resend its exact saved request with the same operation ID.",
      "refused",
      identity(send_record) |> Map.put(:op_id, change.op_id)
    )
  end

  defp finish_change(db, record, op_id, original_command, response, result_command) do
    identity = identity(record) |> Map.put(:op_id, op_id)

    case response do
      {:ok, frame} ->
        case HarklightLifecycle.record_change_result(
               db,
               record,
               op_id,
               original_command,
               "committed"
             ) do
          {:ok, effects} ->
            result =
              Map.merge(identity, effects)
              |> Map.merge(%{command: result_command, outcome: "committed"})

            result =
              if result_command == "settle",
                do: Map.put(result, :settled_command, original_command),
                else: result

            if original_command == "revise",
              do: Map.put(result, :revision, get_in(frame, ["response", "message", "revision"])),
              else: result

          {:error, reason} ->
            failure(
              result_command,
              "harklight_change_unavailable",
              "The external #{original_command} may have committed, but Tightbeam could not save its result: #{inspect(reason)}. The saved request remains available through harklight-settle.",
              "outcome_unknown",
              identity
            )
        end

      {:internal_error, operation, request_id} ->
        reason = HarklightFailures.hold_operation(db, operation, op_id, request_id)

        failure(
          result_command,
          "internal_error",
          "The #{original_command} may have applied. Tightbeam saved the exact request and operation ID. Run tightbeam harklight-settle --message #{record.message_id} to settle that operation. " <>
            reason,
          "outcome_unknown",
          identity
        )

      {:error, code, reason, outcome} ->
        if outcome == "outcome_unknown" do
          failure(
            result_command,
            code,
            "The #{original_command} may or may not have applied. Tightbeam saved the exact request and operation ID; run tightbeam harklight-settle --message #{record.message_id} to retry that same operation. " <>
              reason,
            "outcome_unknown",
            identity
          )
        else
          case HarklightLifecycle.record_change_result(
                 db,
                 record,
                 op_id,
                 original_command,
                 outcome
               ) do
            {:ok, _effects} ->
              failure(result_command, code, reason, outcome, identity)

            {:error, persist_reason} ->
              failure(
                result_command,
                "harklight_change_unavailable",
                "The external result was #{outcome}, but Tightbeam could not record it: #{inspect(persist_reason)}. The saved operation remains available through harklight-settle.",
                "outcome_unknown",
                identity
              )
          end
        end
    end
  end

  # With a send record, its handle is used and a contradicting --session is
  # refused. Without one, the caller's --session handle is passed through to
  # Harklight, which alone decides whether the change is allowed; the change then
  # touches no wake or subscription state.
  defp change_target(db, message, handle) do
    case HarklightLifecycle.lookup(db, message) do
      nil when is_nil(handle) ->
        {:error, {:refused, "harklight_session_required"}}

      nil ->
        if is_binary(handle) and Regex.match?(@uuid4, handle),
          do: {:ok, %{handle: handle, message_id: message, unrecorded: true}},
          else: {:error, {:refused, "harklight_session_invalid"}}

      %{handle: recorded} when is_binary(handle) and handle != recorded ->
        {:error, {:refused, "harklight_session_mismatch"}}

      record ->
        {:ok, record}
    end
  end

  defp resolved(%{state: "pending", message_id: id}), do: {:error, {:unresolved, id}}
  defp resolved(_), do: :ok

  defp valid_progress?(percent, stage, note) do
    is_integer(percent) and percent >= 0 and percent <= 100 and
      is_binary(stage) and String.trim(stage) != "" and (is_nil(note) or is_binary(note))
  end

  defp change_args("progress", p, record) do
    if Enum.all?(Map.keys(p), &(&1 in ~w(message_id percent stage note)a)) and
         valid_progress?(p[:percent], p[:stage], p[:note]) do
      args = [
        "progress",
        "--session",
        record.handle,
        "--request",
        record.item_id,
        "--percent",
        to_string(p.percent),
        "--stage",
        p.stage
      ]

      {:ok, if(is_nil(p[:note]), do: args, else: args ++ ["--note", p.note])}
    else
      {:error, "invalid_harklight_progress"}
    end
  end

  defp change_args("retract", params, record) do
    if Enum.all?(Map.keys(params), &(&1 in [:message_id, :handle, :in_reply_to])) and
         valid_reply_target?(params[:in_reply_to]),
       do:
         {:ok, reply_target_args(["retract", "--item-id", record.item_id], params[:in_reply_to])},
       else: {:error, "invalid_harklight_retract"}
  end

  defp change_args("revise", p, record) do
    choices = p[:choices] || []

    if Enum.all?(
         Map.keys(p),
         &(&1 in ~w(message_id base_revision title body choices clear_choices handle in_reply_to)a)
       ) and
         is_integer(p[:base_revision]) and p.base_revision > 0 and is_binary(p[:title]) and
         p.title != "" and
         (is_nil(p[:body]) or is_binary(p.body)) and is_list(choices) and
         Enum.all?(choices, &is_binary/1) and
         p[:clear_choices] in [nil, false, true] and
         not (p[:clear_choices] == true and choices != []) and
         valid_reply_target?(p[:in_reply_to]) do
      args = [
        "revise",
        "--item-id",
        record.item_id,
        "--base-revision",
        to_string(p.base_revision),
        "--title",
        p.title
      ]

      args = if p[:body], do: args ++ ["--body", p.body], else: args
      args = if p[:clear_choices], do: args ++ ["--clear-choices"], else: args
      args = reply_target_args(args, p[:in_reply_to])
      {:ok, Enum.reduce(choices, args, fn choice, acc -> acc ++ ["--choice", choice] end)}
    else
      {:error, "invalid_harklight_revise"}
    end
  end

  defp valid_reply_target?(nil), do: true
  defp valid_reply_target?(entry), do: is_binary(entry) and String.trim(entry) != ""

  defp reply_target_args(args, nil), do: args
  defp reply_target_args(args, entry), do: args ++ ["--in-reply-to", entry]

  defp change_item_id(_runner, %{request: %{"protocol" => 2}, message_id: id}), do: {:ok, id}

  defp change_item_id(runner, %{request: %{"message" => %{"message_id" => legacy_id}}} = record) do
    with {:ok, message} <-
           read_change_item(runner, [
             "message-get",
             "--sender-id",
             record.sender_id,
             "--message-id",
             legacy_id
           ]) do
      if message["session"] == record.handle and message["sender"] == record.sender_id,
        do: {:ok, message["item_id"]},
        else: {:error, "harklight_result_mismatch"}
    end
  end

  defp change_item_id(runner, %{unrecorded: true} = record) do
    with {:ok, message} <-
           read_change_item(runner, ["message-get", "--item-id", record.message_id]) do
      if message["item_id"] == record.message_id and message["session"] == record.handle,
        do: {:ok, message["item_id"]},
        else: {:error, {:refused, "harklight_session_mismatch"}}
    end
  end

  defp change_item_id(_runner, record), do: {:ok, record.message_id}

  defp read_change_item(runner, args) do
    case runner.(args) do
      {output, 0} ->
        case JSON.decode(output) do
          {:ok, %{"message" => %{"item_id" => item} = message}}
          when is_binary(item) and item != "" ->
            {:ok, message}

          _ ->
            {:error, "harklight_result_mismatch"}
        end

      {output, status} when status in [2, 5] ->
        case result_frames(output) do
          [%{"kind" => "refused", "operation" => "message-get", "error" => token}]
          when is_binary(token) ->
            {:error, {:refused, token}}

          _ ->
            {:error, "harklight_message_lookup_failed"}
        end

      {output, status} ->
        HarklightFailures.read_error(output, status, "message-get") ||
          {:error, "harklight_message_lookup_failed"}
    end
  rescue
    _ -> {:error, "harklight_message_lookup_failed"}
  end

  defp journal_id(runner) do
    with {output, 0} <- runner.(["journal-id"]),
         {:ok, %{"kind" => "journal", "journal_id" => id}} <- JSON.decode(output),
         true <- is_binary(id) and id != "" do
      {:ok, id}
    else
      _ -> {:error, "harklight_journal_unavailable"}
    end
  rescue
    _ -> {:error, "harklight_journal_unavailable"}
  end

  defp retry_change(runner, %{
         journal_id: id,
         op_id: key,
         item_id: item,
         in_reply_to: in_reply_to,
         request: [command | _]
       })
       when is_binary(id) and is_binary(item) do
    invoke_change(
      runner,
      ["retry", "--op-id", key, "--journal-id", id],
      key,
      item,
      command,
      in_reply_to
    )
  end

  defp retry_change(_runner, _change) do
    {:error, "harklight_journal_unavailable",
     "The saved change has no Agent 0.2 journal identity.", "outcome_unknown"}
  end

  defp invoke_change(runner, args, op_id, item_id, command, in_reply_to) do
    case invoke(runner, args, "committed", op_id,
           operations: [command],
           change: true,
           journal_id: retry_journal_id(args)
         ) do
      {:ok,
       %{"response" => %{"message" => %{"item_id" => ^item_id, "revision" => revision}}} =
           frame}
      when is_integer(revision) and revision > 0 ->
        if acted_entry?(frame["response"]["entry"], item_id, in_reply_to),
          do: {:ok, frame},
          else:
            {:error, "harklight_result_mismatch",
             "The expected acted chat entry was not returned.", "outcome_unknown"}

      {:ok, _frame} ->
        {:error, "harklight_result_mismatch", "The returned message did not match.",
         "outcome_unknown"}

      error ->
        error
    end
  end

  defp acted_entry?(_entry, _item_id, nil), do: true

  defp acted_entry?(
         %{
           "item_id" => item_id,
           "entry_id" => entry_id,
           "author" => "person",
           "kind" => "reply",
           "delivery" => %{"acted" => true}
         },
         item_id,
         entry_id
       ),
       do: true

  defp acted_entry?(_entry, _item_id, _entry_id), do: false

  defp identity(nil), do: %{}
  defp identity(record), do: Map.take(record, [:op_id, :handle, :sender_id, :message_id])

  defp failure(command, code, reason, outcome, fields \\ %{}),
    do:
      Map.merge(fields, %{
        command: command,
        code: code,
        reason: reason,
        outcome: outcome,
        wake_effect: "none"
      })

  defp unknown_message(command, message),
    do:
      failure(
        command,
        "harklight_message_unknown",
        "Tightbeam has no send record and does not know this message's Harklight session. Use raw harklight-agent.",
        "refused",
        %{message_id: message}
      )

  defp unresolved_result(command, id),
    do:
      failure(
        command,
        "harklight_send_unresolved",
        "Send #{id} is unresolved. Run tightbeam harklight-settle --op-id #{id} to recover the original send.",
        "refused",
        if(command == "send", do: %{}, else: %{message_id: id})
      )

  defp unknown_reason(id),
    do:
      "The send is unresolved and no subscription is open yet. Run tightbeam harklight-settle --op-id #{id} to recover the original send."

  defp early_reason("harklight_cli_missing"),
    do: "Harklight Agent could not be run, so nothing was sent."

  defp early_reason("harklight_type_required"),
    do:
      "--type is required: use --type fyi for a Seen-only message or --type request for choices or a reply"

  defp early_reason("harklight_type_invalid"),
    do: "--type must be fyi or request"

  defp early_reason("harklight_fyi_has_answer_controls"),
    do:
      "--type fyi carries only the Seen acknowledgment; remove --choices-json and --reply, or send as --type request"

  defp early_reason("harklight_request_needs_answer_controls"),
    do:
      "--type request needs at least one choice or a reply: add --choices-json or --reply, or send as --type fyi"

  defp early_reason("harklight_kind_invalid"),
    do: "--kind must be blocker or success, or left out"

  defp early_reason("harklight_importance_invalid"),
    do: "--importance must be one of low, normal, high, now"

  defp early_reason("harklight_stake_invalid"),
    do: "--stake must be non-empty text; remove it or provide non-empty text"

  defp early_reason("harklight_by_when_invalid"),
    do: "--by-when must be a valid RFC 3339 timestamp"

  defp early_reason("harklight_reply_invalid"),
    do: "--reply is a flag; omit it or include it without a value"

  defp early_reason("harklight_session_required"),
    do:
      "Tightbeam has no send record for this message, so it does not know its Harklight session. Run the command again with --session <handle>, the session the message was sent in, to pass it to Harklight anyway."

  defp early_reason("harklight_session_invalid"),
    do: "--session must be a Harklight session handle (a UUID)."

  defp early_reason("harklight_session_mismatch"),
    do:
      "--session does not match the Harklight session Tightbeam recorded for this message; no operation was run. Remove --session or use the recorded one."

  defp early_reason("harklight_op_id_required"),
    do:
      "Tightbeam has no record of this message, so it does not know which Harklight operation to retry. Run the command again with --op-id <key>, the operation key of the unresolved Harklight operation."

  defp early_reason("harklight_op_id_invalid"),
    do: "--op-id must be a Harklight operation key (a UUID)."

  defp early_reason("harklight_op_id_mismatch"),
    do:
      "--op-id does not match any operation Tightbeam recorded for this message; no operation was run. Remove --op-id or use the recorded one."

  defp early_reason(code), do: "The command did not run: #{code}."

  defp origin!(db, call) do
    if is_binary(call[:session_key]) and call[:principal] == {:session, call.session_key} and
         call[:transport_session_key] == call.session_key and
         origin_ready?(db, call.session_key),
       do: :ok,
       else: {:error, "harklight_origin_unavailable"}
  end

  defp origin_ready?(db, session_key) do
    case Org.get(db, session_key) do
      %{state: "active", host: host} -> host == Placement.local_host_name()
      _ -> false
    end
  end

  defp inputs(params) do
    allowed =
      ~w(
        harklight_session sender_id title message_type message_kind importance stake by_when reply
        body choices files answer_ui vendor_session_id supersedes decision_request_id progress progress_stage progress_note
      )a

    session = params[:harklight_session]
    sender = params[:sender_id]
    title = params[:title]
    progress = params[:progress]
    stage = params[:progress_stage]
    note = params[:progress_note]
    message_type = params[:message_type] || if(not is_nil(progress), do: "fyi")
    message_kind = params[:message_kind]
    importance = params[:importance]
    stake = params[:stake]
    by_when = params[:by_when]
    reply = params[:reply]
    body = params[:body]
    choices = params[:choices] || []
    files = params[:files] || []
    answer_ui = params[:answer_ui]
    vendor = params[:vendor_session_id]
    supersedes = params[:supersedes] || []
    decision_request_id = params[:decision_request_id]

    cond do
      not Enum.all?(Map.keys(params), &(&1 in allowed)) ->
        {:error, "invalid_harklight_send"}

      not (session == "new" or (is_binary(session) and Regex.match?(@uuid4, session))) ->
        {:error, "invalid_harklight_send"}

      not (is_binary(sender) and sender != "" and is_binary(title) and title != "") ->
        {:error, "invalid_harklight_send"}

      not (is_nil(body) or is_binary(body)) or not (is_nil(vendor) or is_binary(vendor)) ->
        {:error, "invalid_harklight_send"}

      not (is_list(choices) and Enum.all?(choices, &(is_binary(&1) and &1 != ""))) ->
        {:error, "invalid_harklight_send"}

      not (is_list(files) and Enum.all?(files, &(is_binary(&1) and &1 != ""))) ->
        {:error, "invalid_harklight_send"}

      not (is_nil(answer_ui) or (is_binary(answer_ui) and answer_ui != "")) ->
        {:error, "harklight_answer_ui_invalid",
         "--answer-ui requires a non-empty path; provide a path or remove --answer-ui"}

      not (is_list(supersedes) and Enum.all?(supersedes, &is_binary/1)) ->
        {:error, "invalid_harklight_send"}

      not (is_nil(decision_request_id) or
               (is_binary(decision_request_id) and
                  Regex.match?(@decision_request_id, decision_request_id))) ->
        {:error, "invalid_harklight_send"}

      not is_nil(progress) and
          (not valid_progress?(progress, stage, note) or message_type != "fyi" or
             choices != [] or reply == true or not is_nil(answer_ui)) ->
        {:error, "invalid_harklight_progress"}

      is_nil(progress) and (not is_nil(stage) or not is_nil(note)) ->
        {:error, "invalid_harklight_progress"}

      is_nil(message_type) ->
        {:error, "harklight_type_required"}

      message_type not in ["fyi", "request"] ->
        {:error, "harklight_type_invalid",
         "--type must be fyi or request; got #{inspect(message_type)}"}

      not is_nil(answer_ui) and message_type != "request" ->
        {:error, "harklight_answer_ui_requires_request",
         "--answer-ui requires --type request; add --type request or remove --answer-ui"}

      not is_nil(answer_ui) and choices != [] and reply == true ->
        {:error, "harklight_answer_ui_has_answer_controls",
         "--answer-ui carries its own inputs: remove --choices-json and --reply, or drop --answer-ui and use --choices-json/--reply"}

      not is_nil(answer_ui) and choices != [] ->
        {:error, "harklight_answer_ui_has_answer_controls",
         "--answer-ui carries its own inputs: remove --choices-json, or drop --answer-ui and use --choices-json/--reply"}

      not is_nil(answer_ui) and reply == true ->
        {:error, "harklight_answer_ui_has_answer_controls",
         "--answer-ui carries its own inputs: remove --reply, or drop --answer-ui and use --choices-json/--reply"}

      not (is_nil(message_kind) or message_kind in ["blocker", "success"]) ->
        {:error, "harklight_kind_invalid",
         "--kind must be blocker or success, or left out; got #{inspect(message_kind)}"}

      not (is_nil(importance) or importance in ["low", "normal", "high", "now"]) ->
        {:error, "harklight_importance_invalid",
         "--importance must be one of low, normal, high, now; got #{inspect(importance)}"}

      not (is_nil(stake) or (is_binary(stake) and String.trim(stake) != "")) ->
        {:error, "harklight_stake_invalid",
         "--stake must be non-empty text; remove it or provide non-empty text"}

      not (is_nil(by_when) or valid_rfc3339?(by_when)) ->
        {:error, "harklight_by_when_invalid",
         "--by-when must be a valid RFC 3339 timestamp; got #{inspect(by_when)}"}

      not (is_nil(reply) or is_boolean(reply)) ->
        {:error, "harklight_reply_invalid"}

      message_type == "fyi" and (choices != [] or reply == true) ->
        {:error, "harklight_fyi_has_answer_controls"}

      message_type == "request" and is_nil(answer_ui) and choices == [] and reply != true ->
        {:error, "harklight_request_needs_answer_controls"}

      true ->
        {:ok,
         %{
           session: session,
           sender: sender,
           title: title,
           message_type: message_type,
           message_kind: message_kind,
           importance: importance,
           stake: stake,
           by_when: by_when,
           reply: reply == true,
           body: body,
           choices: choices,
           files: files,
           answer_ui: answer_ui,
           vendor: vendor,
           supersedes: supersedes,
           progress: progress,
           progress_stage: stage,
           progress_note: note,
           decision_request_id: decision_request_id
         }}
    end
  end

  defp valid_rfc3339?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_rfc3339?(_value), do: false

  defp type_label("fyi"), do: "FYI"
  defp type_label("request"), do: "Request"

  defp prepare_args(input, targets, op_id) do
    args = [
      "send",
      "--prepare",
      "--op-id",
      op_id,
      "--session",
      input.session,
      "--sender-id",
      input.sender,
      "--title",
      input.title
    ]

    args = args ++ ["--type", input.message_type]
    args = if input.answer_ui, do: args ++ ["--answer-ui", input.answer_ui], else: args
    args = if input.message_kind, do: args ++ ["--kind", input.message_kind], else: args
    args = if input.importance, do: args ++ ["--importance", input.importance], else: args
    args = if input.stake, do: args ++ ["--stake", input.stake], else: args
    args = if input.by_when, do: args ++ ["--by-when", input.by_when], else: args
    args = if input.reply, do: args ++ ["--reply"], else: args
    args = if input.body, do: args ++ ["--body", input.body], else: args

    args =
      if is_nil(input.progress),
        do: args,
        else:
          args ++
            ["--progress", to_string(input.progress), "--progress-stage", input.progress_stage]

    args =
      if is_nil(input.progress_note),
        do: args,
        else: args ++ ["--progress-note", input.progress_note]

    args = Enum.reduce(input.choices, args, fn choice, acc -> acc ++ ["--choice", choice] end)
    args = Enum.reduce(input.files, args, fn file, acc -> acc ++ ["--file", file] end)
    Enum.reduce(server_supersedes(targets), args, fn id, acc -> acc ++ ["--supersedes", id] end)
  end

  defp resolve_supersedes(db, runner, input) do
    input.supersedes
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, targets} ->
      record = HarklightLifecycle.lookup(db, id)

      case if(match?(%{sender_id: sender} when sender == input.sender, record),
             do: change_item_id(runner, record),
             else: {:ok, id}
           ) do
        {:ok, item_id} -> {:cont, {:ok, [[id, item_id] | targets]}}
        {:error, {:refused, "not_found"}} -> {:cont, {:ok, [[id, nil] | targets]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  defp server_supersedes(targets), do: for([_reference, id] <- targets, is_binary(id), do: id)

  defp prepared_request(
         %{
           "request_id" => op_id,
           "session_handle" => handle,
           "prepared" =>
             %{"sender" => sender, "session" => handle, "message" => message, "files" => files} =
               prepared
         },
         input,
         targets,
         op_id,
         journal_id
       )
       when is_map(message) and is_list(files) do
    if is_binary(handle) and Regex.match?(@uuid4, handle) and
         (input.session == "new" or handle == input.session) and sender == input.sender and
         (prepared["supersedes"] || []) == server_supersedes(targets) and
         (prepared["supersedes_local"] || []) == [] and
         Enum.map(files, & &1["name"]) == Enum.map(input.files, &Path.basename/1) and
         message["title"] == input.title and message["body"] == input.body and
         message["message_type"] == input.message_type and
         prepared_progress?(message, input) do
      request = %{
        "protocol" => 2,
        "op_id" => op_id,
        "journal_id" => journal_id,
        "session_handle" => handle,
        "vendor_session_id" => input.vendor,
        "prepared" => prepared,
        "supersedes_targets" => targets,
        "message" =>
          Map.merge(message, %{
            "sender_id" => sender,
            "message_id" => op_id,
            "supersedes" => Enum.map(targets, &hd/1)
          })
      }

      {:ok, request, files}
    else
      {:error, "harklight_prepared_mismatch"}
    end
  end

  defp prepared_request(_, _, _, _, _), do: {:error, "harklight_prepared_mismatch"}

  defp prepared_progress?(message, %{progress: nil}), do: is_nil(message["progress"])

  defp prepared_progress?(message, input) do
    case message["progress"] do
      %{"percent" => percent, "stage" => stage} = progress ->
        percent == input.progress and stage == input.progress_stage and
          progress["note"] == input.progress_note

      _ ->
        false
    end
  end

  defp handle_available(db, call, session_arg, handle) do
    case DB.query(db, "SELECT sessionKey,host FROM harklight_wake_handles WHERE handle=?1", [
           handle
         ]) do
      {:ok, []} when session_arg == "new" ->
        :ok

      {:ok, [[session, host]]} when session_arg != "new" ->
        if session == call.session_key and host == Placement.local_host_name(),
          do: :ok,
          else: {:error, "harklight_origin_mismatch"}

      _ ->
        {:error, "harklight_origin_mismatch"}
    end
  end

  defp confirmed_result(
         %{
           "request_id" => op_id,
           "item_id" => item,
           "prepared" => metadata,
           "response" =>
             %{"message" => %{"item_id" => item, "session" => handle, "sender" => sender}} =
               response
         },
         request,
         op_id
       )
       when is_binary(item) and item != "" do
    if handle == request["session_handle"] and sender == request["message"]["sender_id"] and
         metadata == request["prepared"] do
      {:ok, item, JSON.encode!(response)}
    else
      {:error, "harklight_result_mismatch"}
    end
  end

  defp confirmed_result(_, _, _), do: {:error, "harklight_result_mismatch"}

  defp maybe_put_possible_contradictions(result, _command, committed) do
    advisories = get_in(committed, ["response", "message", "advisories"]) || []

    case Enum.find(advisories, &(&1["advisory_type"] == "possible_contradictions")) do
      nil -> result
      advisory -> Map.put(result, :possible_contradictions, possible_contradictions(advisory))
    end
  end

  defp possible_contradictions(value) when is_map(value) do
    value
    |> Map.take(~w(status reason unchecked warning messages))
    |> Map.new(fn
      {"messages", messages} when is_list(messages) ->
        {"messages", Enum.map(messages, &possible_contradiction_message/1)}

      pair ->
        pair
    end)
  end

  defp possible_contradictions(value), do: value

  defp possible_contradiction_message(message) when is_map(message) do
    Map.new(message, fn
      {"sender_id", value} -> {"senderId", value}
      {"sender_name", value} -> {"senderName", value}
      {"message_id", value} -> {"messageId", value}
      pair -> pair
    end)
  end

  defp possible_contradiction_message(message), do: message

  defp bind(db, call, op_id, payload, result, request, item_id) do
    HarklightWakes.bind_send(
      db,
      call,
      op_id,
      payload,
      result,
      request["session_handle"],
      request["message"]["sender_id"],
      item_id
    )
  end

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

  defp invoke(runner, args, expected, op_id, opts \\ []) do
    {output, status} = runner.(args)

    invoke_response(
      output,
      status,
      expected,
      op_id,
      Keyword.get(opts, :operations, operation_names(args)),
      opts[:journal_id]
    )
  rescue
    error ->
      change? = Keyword.get(opts, :change, List.first(args) in ["revise", "retract"])

      reason =
        cond do
          expected == "prepared" ->
            "Harklight Agent could not complete during local preparation: #{Exception.message(error)}; the message was not sent."

          change? ->
            "Harklight Agent could not confirm the change: #{Exception.message(error)}"

          true ->
            "Harklight Agent could not complete: #{Exception.message(error)}"
        end

      {:error, "harklight_cli_failed", reason, if(change?, do: "outcome_unknown", else: "failed")}
  end

  defp retry_journal_id(["retry", "--op-id", _key, "--journal-id", id]), do: id
  defp retry_journal_id(_args), do: nil

  defp result_frames(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case JSON.decode(line) do
        {:ok, %{"kind" => _} = frame} -> [frame]
        _ -> []
      end
    end)
  end

  defp invoke_response(output, status, expected, op_id, operations, journal_id) do
    frames = result_frames(output)

    if expected == "committed" do
      HarklightFailures.write_error(frames, status, op_id, operations) ||
        interpret_response(frames, output, status, expected, op_id, operations, journal_id)
    else
      interpret_response(frames, output, status, expected, op_id, operations, journal_id)
    end
  end

  defp interpret_response(frames, output, status, expected, op_id, operations, journal_id) do
    case frames do
      [%{"kind" => "committed", "operation" => operation, "op_id" => ^op_id} = frame]
      when expected == "committed" and status == 0 ->
        if operation in operations,
          do: {:ok, frame},
          else:
            {:error, "harklight_result_unconfirmed", "The returned operation did not match.",
             "outcome_unknown"}

      [%{"kind" => kind, "operation" => "send", "op_id" => ^op_id} = frame]
      when expected == "prepared" and kind in ["prepared", "committed"] and status == 0 ->
        {:ok, frame}

      [%{"kind" => "outcome_unknown", "op_id" => ^op_id} = frame] ->
        {:error, "harklight_outcome_unknown",
         frame_reason(frame, "Harklight did not confirm the outcome."), "outcome_unknown"}

      [%{"kind" => "operation_absent", "op_id" => ^op_id, "journal_id" => ^journal_id}]
      when status == 1 and is_binary(journal_id) ->
        {:error, "harklight_operation_absent",
         "The matching Agent journal confirms that the operation never started.", "failed"}

      [%{"kind" => "refused"} = frame] when status in [2, 5] ->
        operation_matches = frame["operation"] in operations
        key_matches = is_nil(frame["op_id"]) or frame["op_id"] == op_id

        if operation_matches and key_matches,
          do:
            {:error, frame["error"] || "harklight_refused",
             frame_reason(frame, "Harklight refused the operation."), "refused"},
          else:
            {:error, "harklight_result_unconfirmed", "The returned operation did not match.",
             "outcome_unknown"}

      [] when status in [2, 5] ->
        {:error, "harklight_refused", String.trim(output), "refused"}

      _ ->
        {:error, "harklight_result_unconfirmed",
         "Harklight did not return a confirmed result: " <> String.trim(output),
         if(expected == "prepared", do: "failed", else: "outcome_unknown")}
    end
  end

  defp frame_reason(frame, fallback) do
    reason = frame["reason"] || fallback

    case frame["request_id"] do
      id when is_binary(id) and id != "" -> "#{reason} Harklight request ID: #{id}."
      _ -> reason
    end
  end

  defp operation_names(args) do
    case hd(args) do
      "retry" -> ["send", "retry"]
      operation -> [operation]
    end
  end
end
