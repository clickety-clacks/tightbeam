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

  Every dispatch appends exactly one event row: kind "verb" on acceptance,
  kind "denied" when the verb is unknown or the handler returns a denial
  (`%{code: _}`). The event is appended AFTER the handler so the row can
  carry the outcome — but a handler crash still appends a "verb" row with the
  error (a failure has a row and a reason, T5).
  """

  alias Tightbeam.EventLog

  @typedoc """
  A verb call. `origin` is WHO (\"user:flynn\" | \"agent:<handle>\") — never
  trusted from params, always set by the transport from its authenticated
  identity. `session_key` is the TARGET (nil for verbs without one).
  """
  @type call :: %{
          verb: String.t(),
          origin: String.t(),
          session_key: String.t() | nil,
          params: map()
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
    _ = EventLog
    raise "TODO(sol): #{inspect({db, handlers, call})}"
  end
end
