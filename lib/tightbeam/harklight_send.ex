defmodule Tightbeam.HarklightSend do
  @moduledoc false

  alias Tightbeam.{DB, HarklightLifecycle, HarklightWakes, Id, Org, Placement}

  @uuid4 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def send_request(db, call, opts \\ []) do
    with :ok <- origin!(db, call),
         {:ok, input} <- inputs(call.params),
         nil <- HarklightLifecycle.unresolved(db, input.supersedes),
         {:ok, runner} <- runner(opts) do
      op_id = Id.uuid4()

      case invoke(runner, prepare_args(input, op_id), "prepared", op_id) do
        {:ok, prepared} -> prepare_and_execute(db, call, input, prepared, op_id, runner, opts)
        {:error, code, reason, outcome} -> failure("send", code, reason, outcome, %{op_id: op_id})
      end
    else
      id when is_binary(id) -> unresolved_result("send", id)
      {:error, reason} -> failure("send", reason, early_reason(reason), "failed")
    end
  end

  defp prepare_and_execute(db, call, input, prepared, op_id, runner, opts) do
    identity = prepared_identity(prepared) |> Map.put(:op_id, op_id)

    with {:ok, request, files} <- prepared_request(prepared, input, op_id),
         :ok <- handle_available(db, call, input.session, request["session_handle"]),
         payload = JSON.encode!(%{"request" => request, "files" => files}),
         %{state: "pending"} <- HarklightWakes.prepare_send(db, call, op_id, payload) do
      :global.trans({{__MODULE__, db, op_id}, self()}, fn ->
        with :ok <- HarklightWakes.mark_send_attempt(db, call, op_id, payload) do
          finish_send(
            db,
            call,
            op_id,
            payload,
            request,
            invoke(runner, ["send", "--execute", "--op-id", op_id], "committed", op_id),
            "send",
            opts
          )
        else
          {:error, reason} -> failure("send", reason, early_reason(reason), "failed", identity)
        end
      end)
    else
      %{code: code} -> failure("send", code, early_reason(code), "failed", identity)
      {:error, code} -> failure("send", code, early_reason(code), "failed", identity)
    end
  end

  defp finish_send(db, call, op_id, payload, request, response, command, opts) do
    identity = prepared_identity(%{"request" => request}) |> Map.put(:op_id, op_id)

    case response do
      {:ok, committed} ->
        with {:ok, result} <- confirmed_result(committed, request, op_id),
             %{state: "registered"} = registration <-
               bind(db, call, op_id, payload, result, request) do
          HarklightLifecycle.process_terminals(db, opts)

          registration
          |> Map.merge(identity)
          |> Map.merge(%{command: command, outcome: "committed", result: committed})
          |> HarklightLifecycle.refresh_acknowledgments_result(db)
        else
          error ->
            failure(
              command,
              "harklight_result_unconfirmed",
              unknown_reason(identity.message_id) <>
                " Binding was not confirmed: #{inspect(error)}",
              "outcome_unknown",
              identity
            )
        end

      {:error, code, reason, "refused"} ->
        HarklightLifecycle.record_refused(db, op_id)
        HarklightLifecycle.process_terminals(db, opts)
        failure(command, code, "The message was not sent. " <> reason, "refused", identity)

      {:error, code, reason, _outcome} ->
        failure(
          command,
          code,
          unknown_reason(identity.message_id) <> " " <> reason,
          "outcome_unknown",
          identity
        )
    end
  end

  # Both entry points use the original operation and the immutable prepared
  # bytes. Recovery never prepares a second send or changes its inputs.
  def recover_pending(db, opts \\ []) do
    with {:ok, rows} <- HarklightWakes.pending_send_attempts(db) do
      Enum.each(rows, fn [_op, _session, payload] ->
        request = JSON.decode!(payload)["request"]

        if request do
          recover_one(db, request["message"]["message_id"], opts)
        end
      end)
    end

    :ok
  end

  def settle(db, call, opts \\ []) do
    with :ok <- origin!(db, call) do
      recover_one(db, call.params[:message_id], opts)
    else
      {:error, code} -> failure("settle", code, early_reason(code), "failed")
    end
  end

  defp recover_one(db, message, opts) do
    case HarklightLifecycle.lookup(db, message) do
      %{state: "pending", op_id: op_id} ->
        :global.trans({{__MODULE__, db, op_id}, self()}, fn ->
          case HarklightLifecycle.lookup(db, message) do
            %{state: "pending"} = record ->
              call = %{
                session_key: record.session_key,
                principal: {:session, record.session_key},
                transport_session_key: record.session_key
              }

              with :ok <- origin!(db, call), {:ok, runner} <- runner(opts) do
                finish_send(
                  db,
                  call,
                  op_id,
                  record.payload,
                  record.request,
                  invoke(runner, ["retry", "--op-id", op_id], "committed", op_id),
                  "settle",
                  opts
                )
              else
                {:error, code} ->
                  failure(
                    "settle",
                    code,
                    early_reason(code) <> " " <> unknown_reason(message),
                    "failed",
                    identity(record)
                  )
              end

            record ->
              already_settled(record, message)
          end
        end)

      record ->
        already_settled(record, message)
    end
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

    with :ok <- origin!(db, call),
         {:ok, record} <- known_message(db, message),
         :ok <- resolved(record),
         {:ok, args} <- change_args(command, call.params, record),
         {:ok, runner} <- runner(opts) do
      op_id = Id.uuid4()
      identity = identity(record) |> Map.put(:op_id, op_id)

      case invoke(runner, args ++ ["--op-id", op_id], "committed", op_id) do
        {:ok, frame} ->
          effects =
            if command == "retract",
              do: HarklightLifecycle.retract_committed(db, record, op_id),
              else: %{wake_effect: "kept"}

          Map.merge(identity, effects)
          |> Map.merge(%{command: command, outcome: "committed"})
          |> then(fn result ->
            if command == "revise",
              do: Map.put(result, :revision, frame["response"]["revision"]),
              else: result
          end)

        {:error, code, reason, outcome} ->
          reason =
            if outcome == "outcome_unknown",
              do:
                "The change may or may not have applied. Tightbeam will not retry it on its own. The subscription is unchanged until a committed retract or supersede, or conversation completion. You may run this command again. " <>
                  reason,
              else: reason

          failure(command, code, reason, outcome, identity)
      end
    else
      {:error, :unknown_message} ->
        unknown_message(command, message)

      {:error, {:unresolved, id}} ->
        unresolved_result(command, id)

      {:error, code} ->
        failure(command, code, early_reason(code), "failed", %{message_id: message})
    end
  end

  defp known_message(db, message) do
    case HarklightLifecycle.lookup(db, message) do
      nil -> {:error, :unknown_message}
      record -> {:ok, record}
    end
  end

  defp resolved(%{state: "pending", message_id: id}), do: {:error, {:unresolved, id}}
  defp resolved(_), do: :ok

  defp change_args("retract", params, record) do
    if Map.keys(params) == [:message_id],
      do: {:ok, ["retract", "--session", record.handle, "--request", record.message_id]},
      else: {:error, "invalid_harklight_retract"}
  end

  defp change_args("revise", p, record) do
    choices = p[:choices] || []

    if Enum.all?(
         Map.keys(p),
         &(&1 in ~w(message_id base_revision title body choices clear_choices)a)
       ) and
         is_integer(p[:base_revision]) and p.base_revision > 0 and is_binary(p[:title]) and
         p.title != "" and
         (is_nil(p[:body]) or is_binary(p.body)) and is_list(choices) and
         Enum.all?(choices, &is_binary/1) and
         p[:clear_choices] in [nil, false, true] and
         not (p[:clear_choices] == true and choices != []) do
      args = [
        "revise",
        "--session",
        record.handle,
        "--request",
        record.message_id,
        "--base-revision",
        to_string(p.base_revision),
        "--title",
        p.title
      ]

      args = if p[:body], do: args ++ ["--body", p.body], else: args
      args = if p[:clear_choices], do: args ++ ["--clear-choices"], else: args
      {:ok, Enum.reduce(choices, args, fn choice, acc -> acc ++ ["--choice", choice] end)}
    else
      {:error, "invalid_harklight_revise"}
    end
  end

  def ack(handle, event, opts) do
    with {:ok, run} <- runner(opts) do
      case invoke(run, ["ack", "--session", handle, "--event", event], "acknowledged", nil) do
        {:ok, %{"event_id" => ^event, "status" => status}}
        when status in ["delivered", "already_delivered"] ->
          :ok

        other ->
          {:error,
           "Harklight acknowledgment failed: #{inspect(other)}; the subscription is still open."}
      end
    else
      {:error, code} -> {:error, early_reason(code) <> " The subscription is still open."}
    end
  end

  defp identity(record), do: Map.take(record, [:op_id, :handle, :sender_id, :message_id])

  defp prepared_identity(prepared) do
    request = prepared["request"] || %{}

    %{
      handle: request["session_handle"],
      sender_id: get_in(request, ["message", "sender_id"]),
      message_id: get_in(request, ["message", "message_id"])
    }
    |> Map.reject(fn {_, value} -> is_nil(value) end)
  end

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
        "Send #{id} is unresolved. Lifecycle commands on it are unsupported until settled. Run tightbeam harklight-settle --message #{id}, or leave it for recovery at the next gateway start.",
        "refused",
        if(command == "send", do: %{}, else: %{message_id: id})
      )

  defp unknown_reason(id),
    do:
      "The message may or may not have been sent; the send is still unresolved and no subscription is open yet. Its message ID is informational until settled; lifecycle commands on it are refused. Run tightbeam harklight-settle --message #{id} now (you may settle again), or leave it for recovery at the next gateway start. Tightbeam will not retry it on its own."

  defp early_reason("harklight_cli_missing"),
    do: "Harklight Agent could not be run, so nothing was sent."

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
      ~w(harklight_session sender_id title body choices files vendor_session_id supersedes)a

    session = params[:harklight_session]
    sender = params[:sender_id]
    title = params[:title]
    body = params[:body]
    choices = params[:choices] || []
    files = params[:files] || []
    vendor = params[:vendor_session_id]
    supersedes = params[:supersedes] || []

    if Enum.all?(Map.keys(params), &(&1 in allowed)) and
         (session == "new" or (is_binary(session) and Regex.match?(@uuid4, session))) and
         is_binary(sender) and sender != "" and is_binary(title) and title != "" and
         (is_nil(body) or is_binary(body)) and
         (is_nil(vendor) or is_binary(vendor)) and
         is_list(choices) and Enum.all?(choices, &(is_binary(&1) and &1 != "")) and
         is_list(files) and Enum.all?(files, &(is_binary(&1) and &1 != "")) and
         is_list(supersedes) and Enum.all?(supersedes, &is_binary/1) do
      {:ok,
       %{
         session: session,
         sender: sender,
         title: title,
         body: body,
         choices: choices,
         files: files,
         vendor: vendor,
         supersedes: supersedes
       }}
    else
      {:error, "invalid_harklight_send"}
    end
  end

  defp prepare_args(input, op_id) do
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

    args = if input.session == "new", do: args ++ ["--route", "other", "--controller"], else: args
    args = if input.body, do: args ++ ["--body", input.body], else: args
    args = if input.vendor, do: args ++ ["--vendor-session-id", input.vendor], else: args
    args = Enum.reduce(input.choices, args, fn choice, acc -> acc ++ ["--choice", choice] end)
    args = Enum.reduce(input.files, args, fn file, acc -> acc ++ ["--file", file] end)
    Enum.reduce(input.supersedes, args, fn id, acc -> acc ++ ["--supersedes", id] end)
  end

  defp prepared_request(%{"request" => request, "files" => files}, input, op_id)
       when is_map(request) and is_list(files) do
    handle = request["session_handle"]
    message = request["message"]

    if is_binary(handle) and Regex.match?(@uuid4, handle) and
         (input.session == "new" or handle == input.session) and
         request["type"] == "send" and request["op_id"] == op_id and
         is_map(message) and message["sender_id"] == input.sender and
         is_binary(message["message_id"]) and message["message_id"] != "" and
         (message["supersedes"] || []) == input.supersedes and
         message["title"] == input.title and message["body"] == input.body and
         request["vendor_session_id"] == input.vendor and
         (input.session != "new" or request["route"] == "other") do
      {:ok, request, files}
    else
      {:error, "harklight_prepared_mismatch"}
    end
  end

  defp prepared_request(_, _, _), do: {:error, "harklight_prepared_mismatch"}

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

  defp confirmed_result(%{"response" => response}, request, _op_id) when is_map(response) do
    if response["session_handle"] == request["session_handle"] and
         (is_nil(response["sender_id"]) or
            response["sender_id"] == request["message"]["sender_id"]) and
         (is_nil(response["message_id"]) or
            response["message_id"] == request["message"]["message_id"]) do
      {:ok, JSON.encode!(response)}
    else
      {:error, "harklight_result_mismatch"}
    end
  end

  defp confirmed_result(_, _, _), do: {:error, "harklight_result_mismatch"}

  defp bind(db, call, op_id, payload, result, request) do
    HarklightWakes.bind_send(
      db,
      call,
      op_id,
      payload,
      result,
      request["session_handle"],
      request["message"]["sender_id"],
      request["message"]["message_id"]
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

  defp invoke(runner, args, expected, op_id) do
    {output, status} = runner.(args)

    operations =
      case hd(args) do
        "retry" -> ["send", "retry"]
        "retract" -> ["withdraw"]
        operation -> [operation]
      end

    frames =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case JSON.decode(line) do
          {:ok, %{"kind" => _} = frame} -> [frame]
          _ -> []
        end
      end)

    case frames do
      [%{"kind" => "committed", "operation" => operation, "op_id" => ^op_id} = frame]
      when expected == "committed" and status == 0 ->
        if operation in operations,
          do: {:ok, frame},
          else:
            {:error, "harklight_result_unconfirmed", "The returned operation did not match.",
             "outcome_unknown"}

      [%{"kind" => "acknowledged"} = frame] when expected == "acknowledged" and status == 0 ->
        {:ok, frame}

      [%{"kind" => ^expected, "op_id" => ^op_id} = frame]
      when expected != "committed" and status == 0 ->
        {:ok, frame}

      [%{"kind" => "outcome_unknown", "op_id" => ^op_id} = frame] ->
        {:error, "harklight_outcome_unknown",
         frame["reason"] || "Harklight did not confirm the outcome.", "outcome_unknown"}

      [%{"kind" => "refused"} = frame] ->
        if is_nil(frame["op_id"]) or frame["op_id"] == op_id,
          do:
            {:error, "harklight_refused", frame["reason"] || "Harklight refused the operation.",
             "refused"},
          else:
            {:error, "harklight_result_unconfirmed", "The returned operation did not match.",
             "outcome_unknown"}

      [] when status == 2 ->
        {:error, "harklight_refused", String.trim(output), "refused"}

      _ ->
        {:error, "harklight_result_unconfirmed",
         "Harklight did not return a confirmed result: " <> String.trim(output),
         if(expected == "prepared", do: "failed", else: "outcome_unknown")}
    end
  rescue
    error ->
      {:error, "harklight_cli_failed",
       "Harklight Agent could not complete: #{Exception.message(error)}", "failed"}
  end
end
