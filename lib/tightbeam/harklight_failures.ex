defmodule Tightbeam.HarklightFailures do
  @moduledoc false

  require Logger

  alias Tightbeam.{DB, ErrorDiagnostic}

  @request_id ~S/(?:None|Some\(("(?:[^"\\]|\\.)*")\))/
  @listen_batch ~r/\Alisten: live updates paused: server returned HTTP 500: Some\("internal_error"\) \(request ID #{@request_id}\)\z/
  @listen_close ~r/\Alisten: live updates paused: internal_error \(Request-Id #{@request_id}\)\z/
  @read_failure ~r/\A([a-z-]+): server returned HTTP 500: Some\("internal_error"\) \(request ID #{@request_id}\)\z/

  def ensure_schema(db) do
    DB.execute(db, """
    CREATE TABLE IF NOT EXISTS harklight_operation_pauses (
      opId TEXT PRIMARY KEY,
      diagnostic TEXT NOT NULL
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

  def hold_operation(db, operation, op_id, request_id) do
    diagnostic = log_error(operation, request_id, op_id)

    case persist_pause(db, op_id, diagnostic) do
      :ok -> diagnostic
      {:error, _} -> "#{diagnostic} Tightbeam could not record the recovery pause."
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
