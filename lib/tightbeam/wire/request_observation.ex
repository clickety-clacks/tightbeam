defmodule Tightbeam.Wire.RequestObservation do
  @moduledoc "One correlation and error boundary around the actual Plug request."
  alias Tightbeam.{DB, Diagnostics, RequestContext}
  alias Tightbeam.Wire.{OperationRegistry, ResponseObservationAdapter}
  import Plug.Conn

  @key {__MODULE__, :response}
  @request_id ~r/\Areq_[A-Za-z0-9_-]{22}\z/

  def call(conn, next) do
    {request_id, valid?} = request_id(conn)
    context = %{request_id: request_id, principal_kind: "unknown", principal_ref: nil}

    RequestContext.bind(context, fn ->
      previous = Process.get(@key)

      conn =
        conn
        |> put_resp_header("x-tightbeam-request-id", request_id)
        |> ResponseObservationAdapter.wrap()

      Process.put(@key, %{conn: conn, state: "not_started", timeout: nil, status: nil})
      conn = register_before_send(conn, &started/1)

      try do
        returned =
          try do
            if valid? do
              next.(conn)
            else
              json(conn, 400, %{error: %{code: "invalid_request_id", requestId: request_id}})
            end
          rescue
            error ->
              case timeout(error) do
                %DB.Timeout{} = failure ->
                  observation = Process.get(@key)
                  Process.put(@key, %{observation | timeout: failure})

                  if observation.state == "not_started" do
                    timeout_response(observation.conn, failure)
                  else
                    reraise error, __STACKTRACE__
                  end

                nil ->
                  reraise error, __STACKTRACE__
              end
          end

        observation = Process.get(@key)
        # Adapter return, not the return of the entire Plug stack, owns the
        # completed transition. A later exception cannot undo a sent response.
        terminal(%{observation | conn: returned}, nil)
        ResponseObservationAdapter.unwrap(returned)
      catch
        kind, reason ->
          terminal(Process.get(@key), transport_cause(reason))
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        if previous, do: Process.put(@key, previous), else: Process.delete(@key)
      end
    end)
  end

  @doc false
  def sending(status) do
    case Process.get(@key) do
      nil -> :ok
      observation -> Process.put(@key, %{observation | state: "started", status: status})
    end
  end

  @doc false
  def sent(status) do
    case Process.get(@key) do
      nil -> :ok
      observation -> Process.put(@key, %{observation | state: "complete", status: status})
    end
  end

  defp transport_cause(%Plug.Conn.WrapperError{reason: reason}), do: transport_cause(reason)

  defp transport_cause(%Bandit.TransportError{error: reason})
       when reason in [:closed, :econnreset],
       do: "connection_reset"

  defp transport_cause(%Bandit.TransportError{}), do: "transport_failed"
  defp transport_cause(_), do: nil

  # Called after Plug's real route match, before auth/dispatch. No concrete URL
  # or parameter is retained in a diagnostic operation label.
  def matched(conn) do
    case Process.get(@key) do
      nil -> :ok
      observation -> Process.put(@key, %{observation | conn: conn})
    end

    conn
  end

  defp started(conn) do
    observation = Process.get(@key)
    Process.put(@key, %{observation | conn: conn})
    conn
  end

  defp request_id(conn) do
    case get_req_header(conn, "x-tightbeam-request-id") do
      [] ->
        {RequestContext.id("req_"), true}

      [id] ->
        if Regex.match?(@request_id, id), do: {id, true}, else: {RequestContext.id("req_"), false}

      _ ->
        {RequestContext.id("req_"), false}
    end
  end

  defp timeout(%DB.Timeout{} = error), do: error
  defp timeout(%Plug.Conn.WrapperError{reason: reason}), do: timeout(reason)
  defp timeout(_), do: nil

  defp timeout_response(conn, failure) do
    json(conn, 503, %{
      error: %{
        code: "db_timeout",
        message: "database operation timed out",
        requestId: failure.request_id,
        operation: failure.operation,
        elapsedMs: failure.elapsed_ms,
        budgetMs: failure.budget_ms,
        timeoutSource: failure.timeout_source,
        gatewayAccepted: true,
        effectState: failure.effect_state,
        action: action(failure)
      }
    })
  end

  defp action(%{effect_kind: "read"}), do: "retry_safe"

  defp action(_) do
    if RequestContext.idempotent?(), do: "retry_same_idempotency_key", else: "do_not_retry_report"
  end

  defp terminal(observation, cause) do
    context = RequestContext.capture()
    failure = observation.timeout

    operation =
      case observation.conn.private[:plug_route] do
        {template, _dispatch} -> OperationRegistry.http(observation.conn.method, template)
        _ -> OperationRegistry.http(observation.conn.method, nil)
      end

    Diagnostics.emit(%{
      event: "http_response_terminal",
      listener_generation: observation.conn.private[:tightbeam_listener_generation],
      request_id: context.request_id,
      principal_kind: context.principal_kind,
      principal_ref: context.principal_ref,
      operation: operation,
      response_state: observation.state,
      http_status: if(observation.state == "complete", do: observation.status, else: nil),
      gateway_accepted: true,
      db_call_id: failure && failure.db_call_id,
      effect_kind: failure && failure.effect_kind,
      effect_state: failure && failure.effect_state,
      action: failure && action(failure),
      cause: cause || if(failure, do: "db_caller_timeout", else: nil),
      timeout_source: if(failure, do: failure.timeout_source, else: "none"),
      budget_ms: failure && failure.budget_ms,
      elapsed_ms: failure && failure.elapsed_ms
    })
  end

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
  end
end
