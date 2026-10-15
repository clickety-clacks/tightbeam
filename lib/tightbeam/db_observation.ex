defmodule Tightbeam.DBObservation do
  @moduledoc "R2–R5: observe the existing DB protocol without deciding its outcome."
  alias Tightbeam.{Diagnostics, ErrorDiagnostic, RequestContext}
  require Logger

  @key {__MODULE__, :observation}
  @transaction_capture_tag {__MODULE__, :wire_preserving_transaction}
  @operations %{
    "db.query" => nil,
    "db.execute" => nil,
    "db.transaction" => "write",
    "schema.ensure" => "schema",
    "auth.session_by_cli_token" => "read",
    "wake.due_scan" => "read",
    "db.reference_fence" => nil,
    "test.fixture" => nil
  }
  @envelope_fields ~w(request_id db_call_id operation effect_kind principal_kind principal_ref timeout_source budget_ms)a

  def operations, do: @operations

  def call(server, payload, operation, budget, mode \\ :ordinary)

  def call(server, {:transaction, callback} = payload, operation, budget, mode)
      when is_function(callback, 1) do
    transaction_call(server, payload, operation, budget, mode, fn envelope ->
      {:transaction, transaction_callback(envelope, callback)}
    end)
  end

  def call(server, {:transaction_until, callback, deadline} = payload, operation, budget, mode)
      when is_function(callback, 1) and is_integer(deadline) do
    transaction_call(server, payload, operation, budget, mode, fn envelope ->
      {:transaction_until, transaction_callback(envelope, callback), deadline}
    end)
  end

  def call(server, {:transaction_then, prepare, after_commit} = payload, operation, budget, mode)
      when is_function(prepare, 1) and is_function(after_commit) do
    transaction_call(server, payload, operation, budget, mode, fn envelope ->
      {:transaction_then, transaction_callback(envelope, prepare), after_commit}
    end)
  end

  def call(server, payload, operation, budget, mode) do
    # Existing composition proxies keep their established wire protocol. The
    # envelope is between our client and the actual owner, never a new API for
    # arbitrary processes supplied by a caller.
    if owner?(server) do
      observed_call(server, payload, operation, budget, mode)
    else
      GenServer.call(server, payload, budget)
    end
  end

  @doc false
  def transaction_metadata(callback) when is_function(callback, 1) do
    case :erlang.fun_info(callback, :env) do
      {:env, environment} ->
        Enum.find_value(environment, :none, fn
          {@transaction_capture_tag, envelope, original_callback}
          when is_map(envelope) and is_function(original_callback, 1) ->
            {:ok, envelope, original_callback}

          _ ->
            false
        end)
    end
  end

  def transaction_metadata(_callback), do: :none

  defp owner?(server) do
    with pid when is_pid(pid) <- GenServer.whereis(server),
         {:dictionary, dictionary} <- Process.info(pid, :dictionary) do
      Keyword.get(dictionary, :"$initial_call") == {Tightbeam.DB, :init, 1}
    else
      _ -> false
    end
  end

  defp observed_call(server, payload, operation, budget, mode) do
    observed_request(server, operation, budget, mode, fn envelope ->
      {:db_call, envelope, payload}
    end)
  end

  defp transaction_call(server, payload, operation, budget, mode, build_request) do
    # Transactions retain the public GenServer request tuple. The typed
    # diagnostic context is captured by a private wrapper in the callback
    # position and recovered by the owner before invoking the original callback.
    if owner?(server) do
      observed_request(server, operation, budget, mode, build_request)
    else
      GenServer.call(server, payload, budget)
    end
  end

  defp observed_request(server, operation, budget, mode, build_request) do
    context = RequestContext.capture()
    started = System.monotonic_time()

    envelope = %{
      dispatch_audit: Process.get(:tightbeam_dispatch_audit),
      request_id: context.request_id,
      db_call_id: RequestContext.id("dbc_"),
      operation: operation,
      effect_kind: Map.fetch!(@operations, operation),
      principal_kind: context.principal_kind,
      principal_ref: context.principal_ref,
      timeout_source: "otp_db_call",
      budget_ms: budget,
      deadline: System.monotonic_time(:millisecond) + budget,
      enqueued_monotonic: started
    }

    try do
      request = build_request.(envelope)
      {reply, timing} = send_request(server, request, envelope, budget)

      if Map.get(timing, :dispatch_audited) and (reply == :ok or match?({:ok, _}, reply)),
        do: Process.put(:tightbeam_dispatch_audited, true)

      emit(
        envelope,
        Map.merge(timing, %{
          event: "db_caller_completed",
          elapsed_ms: elapsed(started),
          cause: cause(timing.result_class)
        })
      )

      reply
    catch
      :exit, {:timeout, _call} ->
        elapsed = elapsed(started)

        emit(envelope, %{
          event: "db_call_abandoned",
          elapsed_ms: elapsed,
          cause: "db_caller_timeout",
          queue_ms: nil,
          execute_ms: nil,
          callback_ms: nil,
          callback_sql_ms: nil,
          callback_outside_sql_ms: nil,
          total_ms: nil
        })

        if mode == :deadline do
          # The existing deadline APIs catch this tag and return DeadlineExceeded.
          # Keep that behavior, without retaining the original message in an exit.
          exit({:timeout, {GenServer, :call, [:redacted, budget]}})
        else
          raise Tightbeam.DB.Timeout,
            request_id: envelope.request_id,
            db_call_id: envelope.db_call_id,
            operation: operation,
            effect_kind: envelope.effect_kind,
            elapsed_ms: elapsed,
            budget_ms: budget,
            effect_state: if(envelope.effect_kind == "read", do: "none", else: "unknown")
        end
    end
  end

  defp send_request(server, {:db_call, envelope, {:query, sql, params}} = request, _, budget) do
    case Tightbeam.DB.reader(server, sql) do
      nil ->
        owner_request(server, request, envelope, budget)

      conn ->
        {:reply, response, _} =
          server(envelope, 5_000, fn ->
            {:reply, Tightbeam.DB.read_query(conn, sql, params), nil}
          end)

        case response do
          {{:error, %{message: message}}, _} when is_binary(message) ->
            if String.contains?(message, "readonly"),
              do: owner_request(server, request, envelope, budget),
              else: response

          _ ->
            response
        end
    end
  end

  defp send_request(server, request, envelope, budget),
    do: owner_request(server, request, envelope, budget)

  defp owner_request(server, request, envelope, budget) do
    if Tightbeam.DB.overloaded?(server) do
      {:reply, response, _} =
        server(envelope, nil, fn ->
          {:reply, {:error, %Tightbeam.DB.Overloaded{}}, nil}
        end)

      response
    else
      GenServer.call(server, request, budget)
    end
  end

  defp transaction_callback(envelope, original_callback) do
    capture = {@transaction_capture_tag, envelope, original_callback}
    fn transaction -> apply(elem(capture, 2), [transaction]) end
  end

  @doc false
  def audit_active?, do: is_map(get_in(Process.get(@key, %{}), [:dispatch_audit]))

  @doc false
  def audit_recorded(verb) do
    case Process.get(@key) do
      %{dispatch_audit: %{verb: ^verb}} = observation ->
        Process.put(@key, %{observation | dispatch_audited: true})

      _ ->
        :ok
    end
  end

  @doc false
  def audit_in_txn(txn, changed?) do
    case Process.get(@key) do
      %{dispatch_audit: audit, dispatch_audited: false} when is_map(audit) and changed? ->
        Tightbeam.EventLog.append_event_in_txn(
          txn,
          "verb",
          audit.verb,
          audit.origin,
          audit.session_key,
          nil,
          Map.get(audit, :principal),
          System.system_time(:millisecond)
        )

      _ ->
        :ok
    end
  rescue
    _ -> Logger.warning("dispatch audit could not be recorded in primary transaction")
  end

  def server(envelope, sqlite_budget, fun) do
    started = System.monotonic_time()
    previous = Process.get(@key)

    Process.put(@key, %{
      dispatch_audit: Map.get(envelope, :dispatch_audit),
      dispatch_audited: false,
      sql: 0,
      sql_observed: false,
      callback: 0,
      callback_sql: 0,
      callback_sql_observed: false,
      in_callback: false,
      callback_observed: false,
      raised: nil,
      cleanup_failure: nil,
      sqlite_budget: sqlite_budget
    })

    try do
      case fun.() do
        {:reply, reply, state} ->
          timing =
            terminal(envelope, started, reply)
            |> Map.put(:dispatch_audited, Process.get(@key).dispatch_audited)

          {:reply, {reply, timing}, state}
      end
    catch
      kind, reason ->
        stack = __STACKTRACE__
        terminal(envelope, started, {:error, reason})
        :erlang.raise(kind, reason, stack)
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  def sqlite_budget(budget), do: update(&%{&1 | sqlite_budget: budget})

  def cleanup_failure(result) do
    update(&%{&1 | cleanup_failure: sqlite_class(result)})
  end

  def cleanup_failure_diagnostic({:error, reason} = result) when is_binary(reason) do
    ErrorDiagnostic.new(
      "cleanup",
      cleanup_failure_facts(result) ++ [reason: reason]
    )
  end

  def cleanup_failure_diagnostic(result),
    do: ErrorDiagnostic.new("cleanup", cleanup_failure_facts(result))

  defp cleanup_failure_facts(result) do
    [
      status: "unverified",
      operation: "db.rollback",
      phase: "rollback",
      origin: "db_owner",
      result_class: sqlite_class(result)
    ]
  end

  # The full exception and stack stay only in this call's ephemeral state.
  # Matching the observed raise, not an arbitrary exception message, lets
  # Txn.exec retain its public MatchError while reporting the real SQLite class.
  def sqlite(fun) do
    started = System.monotonic_time()

    try do
      fun.()
    rescue
      error ->
        stack = __STACKTRACE__

        class =
          case error do
            %MatchError{term: result} -> sqlite_class(result)
            %Tightbeam.DB.Error{} -> "sqlite_error"
            _ -> nil
          end

        remember_raise(error, stack, class)
        reraise error, stack
    after
      duration = System.monotonic_time() - started

      update(fn state ->
        %{
          state
          | sql: state.sql + duration,
            sql_observed: true,
            callback_sql_observed: state.callback_sql_observed or state.in_callback,
            callback_sql: state.callback_sql + if(state.in_callback, do: duration, else: 0)
        }
      end)
    end
  end

  def sqlite_error(result, fun) do
    try do
      fun.()
    rescue
      error ->
        remember_raise(error, __STACKTRACE__, sqlite_class(result))
        reraise error, __STACKTRACE__
    end
  end

  def callback(fun) do
    started = System.monotonic_time()
    update(&%{&1 | in_callback: true, callback_observed: true})

    try do
      fun.()
    rescue
      error ->
        stack = __STACKTRACE__

        class =
          case observed_raise(error, stack) do
            {:observed, class} -> class
            :unobserved when is_struct(error, Tightbeam.DB.DeadlineExceeded) -> nil
            :unobserved when is_struct(error, Tightbeam.DB.ReferenceFenceError) -> nil
            :unobserved -> "callback_error"
          end

        remember_raise(error, stack, class)
        reraise error, stack
    after
      duration = System.monotonic_time() - started
      update(&%{&1 | callback: &1.callback + duration, in_callback: false})
    end
  end

  defp observed_raise(error, stack) do
    case Process.get(@key) do
      %{raised: {^error, ^stack, class}} -> {:observed, class}
      _ -> :unobserved
    end
  end

  defp remember_raise(error, stack, class) do
    # An inner SQLite seam may know a more specific pinned adapter class.
    case observed_raise(error, stack) do
      {:observed, _} -> :ok
      :unobserved -> update(&%{&1 | raised: {error, stack, class}})
    end
  end

  defp update(fun) do
    case Process.get(@key) do
      nil ->
        :ok

      state ->
        Process.put(@key, fun.(state))
        :ok
    end
  end

  def sqlite_class(:busy), do: "sqlite_busy"
  def sqlite_class({:error, "database is locked"}), do: "sqlite_busy"
  def sqlite_class({:error, "database table is locked"}), do: "sqlite_locked"
  def sqlite_class({:error, reason}) when is_binary(reason), do: "sqlite_error"
  def sqlite_class(_), do: nil

  defp terminal(envelope, started, reply) do
    state = Process.get(@key)
    class = state.cleanup_failure || result_class(reply, state, envelope.operation)
    difference = state.callback - state.callback_sql
    if difference < 0, do: Logger.error("invalid diagnostic SQL/callback span")

    timing = %{
      queue_ms: ms(started - envelope.enqueued_monotonic),
      total_ms: elapsed(envelope.enqueued_monotonic),
      execute_ms: if(state.sql_observed, do: ms(state.sql)),
      callback_ms: if(state.callback_observed, do: ms(state.callback)),
      callback_sql_ms: if(state.callback_sql_observed, do: ms(state.callback_sql)),
      callback_outside_sql_ms:
        if(state.callback_observed and difference >= 0, do: ms(difference)),
      sqlite_timeout_source: if(state.sql_observed, do: "sqlite_busy", else: "none"),
      sqlite_busy_budget_ms: if(state.sql_observed, do: state.sqlite_budget),
      result_class: class
    }

    emit(envelope, Map.merge(timing, %{event: "db_server_completed", cause: cause(class)}))
    timing
  end

  defp result_class(:ok, _, _), do: "ok"
  defp result_class({:ok, _}, _, _), do: "ok"
  defp result_class({:ok, _, _}, _, _), do: "ok"

  defp result_class({:error, error}, %{raised: {raised, _stack, class}}, _) do
    if same_observed_error?(error, raised), do: class
  end

  defp result_class(result, _, "db.execute"), do: sqlite_class(result)
  defp result_class(_, _, _), do: nil

  defp same_observed_error?(left, right) when is_map(left) and is_map(right) do
    # The DB owner adds this safe caller diagnostic after the original exception
    # has been observed. Ignore only that additive field when recovering the
    # already-recorded result class; every original exception field still matches.
    Map.delete(left, :diagnostic) == Map.delete(right, :diagnostic)
  end

  defp same_observed_error?(left, right), do: left == right

  defp cause("ok"), do: nil
  defp cause("callback_error"), do: "transaction_callback_error"
  defp cause(class), do: class

  defp emit(envelope, fields),
    do: Diagnostics.emit(Map.merge(Map.take(envelope, @envelope_fields), fields))

  defp ms(duration), do: System.convert_time_unit(duration, :native, :millisecond)
  defp elapsed(started), do: ms(System.monotonic_time() - started)
end
