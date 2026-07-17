defmodule Tightbeam.Skeleton do
  @moduledoc false
  # Compile-honest TODO stub for skeleton bodies: always raises at runtime,
  # but is TYPED as term() (the branch defeats no_return inference), so
  # composition-root callers that `case` on skeleton results still compile
  # under --warnings-as-errors while bodies await implementation. Delete
  # call sites as bodies are filled; delete this module when none remain.

  @spec todo!(String.t()) :: term()
  def todo!(msg) do
    if function_exported?(__MODULE__, :never_defined, 99), do: :unreachable, else: raise(msg)
  end
end
