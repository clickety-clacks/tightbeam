defmodule Tightbeam do
  @moduledoc """
  Tightbeam — a patchbay between chat clients and coding-agent harnesses.

  The substrate routes, records, and enforces; it never thinks (see the spec's
  Tenets). This app is the Elixir port of the reference gateway; start here:

    * `docs/ARCHITECTURE.md` — module map + supervision tree + the turn pipeline
    * `docs/HANDOFF.md` — how to contribute
    * `Tightbeam.Ledger` — the exemplar module (style, @spec, invariants-in-SQL)

  The one flow to understand is the turn pipeline: a post or wake commits a
  message + a ledger turn in ONE transaction; the ledger's `seq` is the
  execution order; a per-session lane runs one turn at a time; every accepted
  prompt reaches exactly one terminal state (the conservation law).
  """
end
