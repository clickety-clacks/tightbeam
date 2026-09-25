defmodule Tightbeam.DBObservation do
  @moduledoc "R2–R5: observe the existing DB protocol without deciding its outcome."
  alias Tightbeam.{Diagnostics, RequestContext}
  require Logger

  @key {__MODULE__, :observation}
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

  def call(server, payload, operation, budget, mode \\ :ordinary) do
    # Existing composition proxies keep their established wire protocol. The
    # envelope is between our client and the actual owner, never a new API for
    # arbitrary processes supplied by a caller.
    if owner?(server) do
      observed_call(server, payload, operation, budget, mode)
    else
      GenServer.call(server, payload, budget)
    end
  end

  defp owner?(server) do
    with pid when is_pid(pid) <- GenServer.whereis(server),
         {:dictionary, dictionary} <- Process.info(pid, :dictionary) do
      Keyword.get(dictionary, :"$initial_call") == {Tightbeam.DB, :init, 1}
    else
      _ -> false
    end
  end

  defp observed_call(server, payload, operation, budget, mode) do
    context = RequestContext.capture()
    started = System.monotonic_time()

    envelope = %{
      request_id: context.request_id,
      db_call_id: RequestContext.id("dbc_"),
      operation: operation,
      effect_kind: Map.fetch!(@operations, operation),
      principal_kind: context.principal_kind,
      principal_ref: context.principal_ref,
      timeout_source: "otp_db_call",
      budget_ms: budget,
      enqueued_monotonic: started
    }

    try do
      {reply, timing} = GenServer.call(server, {:db_call, envelope, payload}, budget)

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

  def server(envelope, sqlite_budget, fun) do
    started = System.monotonic_time()
    previous = Process.get(@key)

    Process.put(@key, %{
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
          timing = terminal(envelope, started, reply)
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
  defp result_class({:error, error}, %{raised: {error, _stack, class}}, _), do: class
  defp result_class(result, _, "db.execute"), do: sqlite_class(result)
  defp result_class(_, _, _), do: nil

  defp cause("ok"), do: nil
  defp cause("callback_error"), do: "transaction_callback_error"
  defp cause(class), do: class

  defp emit(envelope, fields),
    do: Diagnostics.emit(Map.merge(Map.take(envelope, @envelope_fields), fields))

  defp ms(duration), do: System.convert_time_unit(duration, :native, :millisecond)
  defp elapsed(started), do: ms(System.monotonic_time() - started)
end
