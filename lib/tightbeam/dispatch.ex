defmodule Tightbeam.Dispatch do
  @moduledoc """
  THE verb chokepoint (T3: one chokepoint, closed sets; TS reference:
  src/core/dispatch.ts). Every state-changing call — wire, HTTP facade, agent
  CLI, wake delivery — is a verb dispatched here. Nothing mutates registry/
  store/devices except through a verb handler. Reads may query stores
  directly; writes may not.

  Elixir shape (deliberate divergence from the TS mutable registry): the
  handler table is an IMMUTABLE map built once by the composition root
  (`Tightbeam.Gateway.handlers/1`) and passed in the call. There is no
  register/2 at runtime — the verb set is closed at build time, which is the
  point. Dispatch itself is a plain function, not a process: handlers run in
  the CALLER's process (a socket, an HTTP request task, the scheduler), and
  anything long-running goes through the Ledger/lane pipeline, never inline.

  Before a known handler runs, the deny-only `Tightbeam.Rules` tier evaluates
  the raw call. A statute denial or fact error appends kind "denied" and
  returns immediately; that audit append is best-effort so an unavailable
  sink cannot fail open. All calls that pass statutes retain the existing
  behavior: kind "verb" on acceptance, kind "denied" when the verb is unknown
  or the handler returns a denial (`%{code: _}`). Handler outcome rows are
  appended AFTER the handler so they can carry the result; a handler crash
  still appends a "verb" row with the error.
  """

  alias Tightbeam.{Escalation, EventLog, Rules}

  @typedoc """
  A verb call. `origin` is WHO (\"user:flynn\" | \"agent:<handle>\") — never
  trusted from params, always set by the transport from its authenticated
  identity. `session_key` is the TARGET (nil for verbs without one).
  """
  @type call :: %{
          required(:verb) => String.t(),
          required(:origin) => String.t(),
          required(:session_key) => String.t() | nil,
          required(:params) => map(),
          optional(:principal) =>
            {:session, String.t()} | {:user, String.t()} | {:process, String.t()} | nil
        }

  @typedoc "A handler: pure-ish fun; returns a result map, or %{code: _} to deny."
  @type handler :: (call() -> map())

  @type handlers :: %{optional(String.t()) => handler()}

  @doc """
  Dispatch a call through the handler table. Unknown verb → `{:error,
  %{code: "unknown_verb"}}` + a "denied" event. Handler returning `%{code: _}`
  → `{:error, that_map}` + a "denied" event. Otherwise `{:ok, result}` + a
  "verb" event. A raising handler is caught: "verb" event with the error,
  `{:error, %{code: "server_error", message: _}}` to the caller.
  """
  @spec dispatch(GenServer.server(), handlers(), call()) :: {:ok, map()} | {:error, map()}
  def dispatch(db \\ Tightbeam.DB, handlers, call) do
    verb = Map.fetch!(call, :verb)
    origin = Map.fetch!(call, :origin)
    principal = Map.get(call, :principal)
    session_key = Map.get(call, :session_key)

    case Rules.decide(db, call) do
      {{:deny, error}, _to_close, _to_consume} ->
        best_effort_denial(db, verb, origin, principal, session_key, error)
        {:error, error}

      {{:remedy, _statute, _ref, error}, _to_close, _to_consume} ->
        best_effort_denial(db, verb, origin, principal, session_key, error)
        {:error, error}

      {{:escalate, _statute, ctx, _dr_id}, _to_close, _to_consume} ->
        best_effort_denial(db, verb, origin, principal, session_key, ctx.error)
        {:error, ctx.error}

      {:allow, _to_close, to_consume} ->
        if Enum.map(to_consume, &Escalation.consume(db, &1)) |> Enum.all?() do
          dispatch_to_handler(db, handlers, call, verb, origin, principal, session_key)
        else
          error = %{code: "rule_denied", message: "ruling authorization was no longer available"}
          best_effort_denial(db, verb, origin, principal, session_key, error)
          {:error, error}
        end
    end
  end

  defp dispatch_to_handler(db, handlers, call, verb, origin, principal, session_key) do
    case Map.fetch(handlers, verb) do
      :error ->
        error = %{code: "unknown_verb"}
        :ok = EventLog.append_event(db, "denied", verb, origin, session_key, error, principal)
        {:error, error}

      {:ok, handler} ->
        case invoke(handler, call) do
          {:returned, %{code: _} = error} ->
            :ok = EventLog.append_event(db, "denied", verb, origin, session_key, error, principal)
            {:error, error}

          {:returned, result} ->
            :ok = EventLog.append_event(db, "verb", verb, origin, session_key, result, principal)
            {:ok, result}

          {:raised, exception} ->
            error = %{code: "server_error", message: Exception.message(exception)}
            :ok = EventLog.append_event(db, "verb", verb, origin, session_key, error, principal)
            {:error, error}
        end
    end
  end

  defp best_effort_denial(db, verb, origin, principal, session_key, error) do
    try do
      EventLog.append_event(
        db,
        "denied",
        verb,
        origin,
        session_key,
        JSON.encode!(error),
        principal
      )
    catch
      _kind, _reason -> :ok
    end
  end

  defp invoke(handler, call) do
    {:returned, handler.(call)}
  rescue
    exception -> {:raised, exception}
  end
end
