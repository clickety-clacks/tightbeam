defmodule Tightbeam.HarklightFailures do
  @moduledoc false

  require Logger

  alias Tightbeam.{DB, ErrorDiagnostic}

  @request_id ~S/(?:None|Some\(("(?:[^"\\]|\\.)*")\))/
  @debug_option ~S/(?:None|Some\("(?:[^"\\]|\\.)*"\))/
  @listen_http ~r/\Aserver returned HTTP (\d{3}): (#{@debug_option}) \(request ID #{@debug_option}\)\z/
  @listen_batch ~r/\Alisten: live updates paused: server returned HTTP 500: Some\("internal_error"\) \(request ID #{@request_id}\)\z/
  @listen_close ~r/\Alisten: live updates paused: internal_error \(Request-Id #{@request_id}\)\z/
  @read_failure ~r/\A([a-z-]+): server returned HTTP 500: Some\("internal_error"\) \(request ID #{@request_id}\)\z/

  def ensure_schema(db) do
    DB.execute(db, """
    CREATE TABLE IF NOT EXISTS harklight_operation_pauses (
      opId TEXT PRIMARY KEY,
      diagnostic TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS harklight_operation_guards (
      opId TEXT PRIMARY KEY
    );
    """)
  end

  def operation_pause(db, op_id) do
    DB.refusable(fn ->
      case DB.query(db, "SELECT diagnostic FROM harklight_operation_pauses WHERE opId=?1", [
             op_id
           ]) do
        {:ok, [[diagnostic]]} -> {:ok, diagnostic}
        {:ok, []} -> {:ok, nil}
        {:error, _reason} = error -> error
      end
    end)
  end

  # Establish custody before an Agent invocation that can write. A crash or
  # a failed pause write leaves this guard in place and requires explicit
  # settlement. Ordinary retryable results release a newly acquired guard.
  def guarded_attempt(db, op_id, mode, invoke) do
    case DB.query(
           db,
           """
           INSERT INTO harklight_operation_guards(opId) VALUES(?1)
           ON CONFLICT(opId) DO NOTHING RETURNING opId
           """,
           [op_id]
         ) do
      {:ok, [[^op_id]]} ->
        result = invoke.()

        unless match?({:internal_error, _, _}, result) do
          case DB.query(db, "DELETE FROM harklight_operation_guards WHERE opId=?1", [op_id]) do
            {:ok, _} -> :ok
            {:error, _} -> Logger.error(guard_diagnostic(op_id))
          end
        end

        {:ok, result}

      {:ok, []} when mode == :explicit ->
        {:ok, invoke.()}

      {:ok, []} ->
        {:error, "harklight_recovery_held"}

      {:error, _} ->
        {:error, "harklight_recovery_guard_unavailable"}
    end
  end

  def guard_diagnostic(op_id) do
    "Harklight operation #{safe_field(op_id)} has no recorded attempt disposition. Settle the saved operation explicitly."
  end

  def hold_operation(db, operation, op_id, request_id) do
    diagnostic = log_error(operation, request_id, op_id)

    case persist_pause(db, op_id, diagnostic) do
      :ok ->
        {:paused, diagnostic}

      {:error, _} ->
        reason =
          "#{diagnostic} Tightbeam could not record the recovery pause. The attempt guard requires explicit settlement."

        Logger.error(reason)
        {:pause_unrecorded, reason}
    end
  end

  defp persist_pause(db, op_id, diagnostic) do
    case DB.owed_work(fn ->
           DB.query(
             db,
             """
             INSERT INTO harklight_operation_pauses(opId,diagnostic) VALUES(?1,?2)
             ON CONFLICT(opId) DO UPDATE SET diagnostic=excluded.diagnostic
             """,
             [op_id, diagnostic]
           )
         end) do
      {:ok, _} ->
        :ok

      {:error, reason} when is_struct(reason, DB.Overloaded) or is_struct(reason, DB.Timeout) ->
        Process.sleep(100)
        persist_pause(db, op_id, diagnostic)

      {:error, _reason} = error ->
        error
    end
  end

  def log_error(operation, request_id, op_id \\ nil) do
    diagnostic = details(operation, request_id, op_id)
    Logger.error(diagnostic)
    diagnostic
  end

  def write_error(
        [
          %{
            "kind" => "outcome_unknown",
            "operation" => operation,
            "op_id" => op_id,
            "status" => 500,
            "error" => "internal_error",
            "retryable" => false
          } = frame
        ],
        7,
        op_id,
        operations
      ) do
    if operation in operations, do: {:internal_error, operation, frame["request_id"]}
  end

  def write_error(_frames, _status, _op_id, _operations), do: nil

  def listen_pause(line) do
    line = String.trim(line)

    case Regex.run(@listen_batch, line) || Regex.run(@listen_close, line) do
      [_ | captures] -> {:internal_error, "listen", decode_request_id(captures)}
      nil -> nil
    end
  end

  def listen_refusal(line) do
    line = String.trim(line)

    case Regex.run(@listen_http, line) do
      [_, _, ~s|Some("unsupported")|] -> :unsupported_version
      [_, <<"4", _::binary>>, _] -> :feed_refused
      _ -> non_http_listen_refusal(line)
    end
  end

  defp non_http_listen_refusal("agent feed closed: " <> reason) when reason != "",
    do: :feed_refused

  defp non_http_listen_refusal(line)
       when line in ["invalid agent change or cursor", "invalid agent snapshot"],
       do: :invalid_response

  defp non_http_listen_refusal(line) do
    if Regex.match?(
         ~r/\Aserver sent an unexpected response \(request ID #{@debug_option}\)\z/,
         line
       ),
       do: :invalid_response
  end

  def read_error(output, 1, operation) do
    case Regex.run(@read_failure, String.trim(output)) do
      [_, ^operation | captures] -> {:internal_error, operation, decode_request_id(captures)}
      _ -> nil
    end
  end

  def read_error(_output, _status, _operation), do: nil

  defp decode_request_id([value]) do
    case JSON.decode(value) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp decode_request_id(_), do: nil

  def details(operation, request_id, op_id \\ nil) do
    fields = [
      "Harklight internal_error",
      "Operation #{safe_field(operation)}",
      "Request-Id #{safe_field(request_id)}"
    ]

    fields = if op_id, do: fields ++ ["Operation ID #{safe_field(op_id)}"], else: fields
    Enum.join(fields, ". ") <> "."
  end

  defp safe_field(value) when is_binary(value) do
    value
    |> String.replace_invalid()
    |> ErrorDiagnostic.redact_text()
    |> String.replace(~r/[[:cntrl:]]/u, " ")
    |> String.slice(0, 128)
  end

  defp safe_field(_), do: "unavailable"
end
