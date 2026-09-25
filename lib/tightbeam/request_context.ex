defmodule Tightbeam.RequestContext do
  @moduledoc "Privacy-safe request correlation that never grants authority."

  @key {__MODULE__, :current}

  def capture do
    Process.get(@key) ||
      %{
        request_id: id("int_"),
        principal_kind: "internal",
        principal_ref: "internal:db_client"
      }
  end

  def bind(context, fun) when is_map(context) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, context)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc """
  Bind one internal entry's context for the DB calls that entry causes.

  R1 gives an internal caller one `int_` request ID at its subsystem entry and
  reuses it for the DB calls caused by that entry. `capture/0`'s unbound
  fallback mints a fresh ID per call, so without an entry seam two DB calls
  made by one tick cannot be correlated with each other at all.

  `component` is a registered component name, which is the only thing the
  `internal:` principal-reference form may carry. `bind/2` owns the restore, so
  a nested entry cannot outlive the caller that opened it, and a spawned
  process still receives no implicit context.
  """
  def bind_internal(component, fun) when is_binary(component) and is_function(fun, 0) do
    bind(
      %{
        request_id: id("int_"),
        principal_kind: "internal",
        principal_ref: "internal:" <> component
      },
      fun
    )
  end

  @doc """
  Record the principal that identity resolution proved for this request.

  R2 binds the context immediately after the request-ID header, which is before
  authentication has run, so `principal_kind` is `unknown` and `principal_ref`
  is null at that point. Without this seam every later record keeps reporting
  an unknown principal, including the records written after a credential
  resolved one, and an operator cannot tell an unauthenticated request from an
  authenticated one.

  The reference is assembled here from the closed kind vocabulary and an
  existing identifier, so no call site invents a form and the credential itself
  is never the argument. A no-op outside a bound context: there is no request to
  describe.
  """
  def resolve_principal(kind, subject)
      when kind in ["user", "session", "process", "internal"] and is_binary(subject) do
    case Process.get(@key) do
      nil ->
        :ok

      context ->
        Process.put(@key, %{
          context
          | principal_kind: kind,
            principal_ref: kind <> ":" <> subject
        })
    end

    :ok
  end

  @doc """
  Record that a keyed mutation was in flight for this request.

  R7 distinguishes a retryable write from an unrepeatable one, and only the
  dispatch seam knows whether the call carried an idempotency key. The marker
  lives in the bound context, so `bind/2`'s restore drops it at the request
  boundary and it can never advise a later request.

  A no-op outside a bound context: a keyed verb delivered by the scheduler has
  no HTTP response to shape.
  """
  def mark_idempotent do
    case Process.get(@key) do
      nil -> :ok
      context -> Process.put(@key, Map.put(context, :idempotent, true))
    end

    :ok
  end

  def idempotent? do
    case Process.get(@key) do
      %{idempotent: true} -> true
      _unmarked -> false
    end
  end

  def id(prefix) when prefix in ["req_", "int_", "dbc_"] do
    prefix <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end
end
