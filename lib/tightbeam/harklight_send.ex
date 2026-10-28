defmodule Tightbeam.HarklightSend do
  @moduledoc false

  alias Tightbeam.{DB, HarklightWakes, Id, Org, Placement}

  @uuid4 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def send_request(db, call, opts \\ []) do
    with :ok <- origin!(db, call),
         {:ok, input} <- inputs(call.params),
         {:ok, runner} <- runner(opts) do
      op_id = Id.uuid4()

      with {:ok, prepared} <- invoke(runner, prepare_args(input, op_id), "prepared", op_id),
           {:ok, request, files} <- prepared_request(prepared, input, op_id),
           :ok <- handle_available(db, call, input.session, request["session_handle"]),
           payload = JSON.encode!(%{"request" => request, "files" => files}),
           %{state: "pending"} <- HarklightWakes.prepare_send(db, call, op_id, payload),
           :ok <- HarklightWakes.mark_send_attempt(db, call, op_id, payload),
           {:ok, committed} <-
             invoke(runner, ["send", "--execute", "--op-id", op_id], "committed", op_id),
           {:ok, result} <- confirmed_result(committed, request, op_id),
           %{state: "registered"} = registration <-
             bind(db, call, op_id, payload, result, request) do
        Map.merge(registration, %{op_id: op_id, result: committed})
      else
        %{code: _} = error -> error
        {:error, reason} -> %{code: reason, op_id: op_id}
        other -> %{code: "harklight_send_pending", op_id: op_id, detail: inspect(other)}
      end
    else
      {:error, {:invalid_harklight_send, message}} ->
        %{code: "invalid_harklight_send", message: message}

      {:error, reason} -> %{code: reason}
    end
  end

  # Recovery uses only the session, operation and prepared bytes recorded before
  # execution. The CLI owns the final wire request and its same-operation retry.
  def recover_pending(db, opts \\ []) do
    with {:ok, runner} <- runner(opts), {:ok, rows} <- HarklightWakes.pending_send_attempts(db) do
      Enum.each(rows, fn [op_id, session_key, payload] ->
        with {:ok, %{"request" => request, "files" => _files}} <- JSON.decode(payload),
             true <- origin_ready?(db, session_key),
             {:ok, committed} <- invoke(runner, ["retry", "--op-id", op_id], "committed", op_id),
             {:ok, result} <- confirmed_result(committed, request, op_id) do
          call = %{
            session_key: session_key,
            principal: {:session, session_key},
            transport_session_key: session_key
          }

          bind(db, call, op_id, payload, result, request)
        else
          _ -> :pending
        end
      end)
    end

    :ok
  end

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
    allowed = ~w(harklight_session sender_id title body choices files vendor_session_id)a
    session = params[:harklight_session]
    sender = params[:sender_id]
    title = params[:title]
    body = params[:body]
    choices = params[:choices] || []
    files = params[:files] || []
    vendor = params[:vendor_session_id]
    unknown = Enum.find(Map.keys(params), &(&1 not in allowed))

    cond do
      not is_nil(unknown) ->
        invalid_parameter("unrecognized", unknown)

      not Map.has_key?(params, :harklight_session) ->
        invalid_parameter("missing required", :harklight_session)

      not (session == "new" or (is_binary(session) and Regex.match?(@uuid4, session))) ->
        invalid_parameter("invalid", :harklight_session)

      not Map.has_key?(params, :sender_id) ->
        invalid_parameter("missing required", :sender_id)

      not (is_binary(sender) and sender != "") ->
        invalid_parameter("invalid", :sender_id)

      not Map.has_key?(params, :title) ->
        invalid_parameter("missing required", :title)

      not (is_binary(title) and title != "") ->
        invalid_parameter("invalid", :title)

      not (is_nil(body) or is_binary(body)) ->
        invalid_parameter("invalid", :body)

      not (is_nil(vendor) or is_binary(vendor)) ->
        invalid_parameter("invalid", :vendor_session_id)

      not (is_list(choices) and Enum.all?(choices, &(is_binary(&1) and &1 != ""))) ->
        invalid_parameter("invalid", :choices)

      not (is_list(files) and Enum.all?(files, &(is_binary(&1) and &1 != ""))) ->
        invalid_parameter("invalid", :files)

      true ->
        {:ok,
         %{
           session: session,
           sender: sender,
           title: title,
           body: body,
           choices: choices,
           files: files,
           vendor: vendor
         }}
    end
  end

  defp invalid_parameter(kind, parameter) do
    {:error,
     {:invalid_harklight_send, "#{kind} parameter: #{parameter_name(parameter)}"}}
  end

  defp parameter_name(:harklight_session), do: "harklightSession"
  defp parameter_name(:sender_id), do: "senderId"
  defp parameter_name(:vendor_session_id), do: "vendorSessionId"
  defp parameter_name(parameter) when is_atom(parameter), do: Atom.to_string(parameter)
  defp parameter_name(parameter) when is_binary(parameter), do: parameter
  defp parameter_name(_parameter), do: "unknown"

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
    Enum.reduce(input.files, args, fn file, acc -> acc ++ ["--file", file] end)
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
    committed_operations = if hd(args) == "retry", do: ["send", "retry"], else: ["send"]

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
        if operation in committed_operations,
          do: {:ok, frame},
          else: {:error, "harklight_result_unconfirmed"}

      [%{"kind" => ^expected, "op_id" => ^op_id} = frame]
      when expected != "committed" and status == 0 ->
        {:ok, frame}

      [%{"kind" => "outcome_unknown", "op_id" => ^op_id}] ->
        {:error, "harklight_outcome_unknown"}

      [%{"kind" => "refused", "op_id" => ^op_id}] ->
        {:error, "harklight_refused"}

      _ ->
        {:error, "harklight_result_unconfirmed"}
    end
  rescue
    _ -> {:error, "harklight_cli_failed"}
  end
end
