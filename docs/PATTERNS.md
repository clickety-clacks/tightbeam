
## Documentation rules (Elixir-native; agents contribute against these)
- Every public function: `@doc` (what + the invariant it upholds) and `@spec`.
- Shared shapes get `@type t`-style types (see Tightbeam.Ledger.turn/0).
- Doctests for pure functions (parse/format helpers); ExUnit for stateful.
- `@moduledoc` = role + invariants + spec-section references (cite the spec
  by section name, not internal review-round numbers).
- `mix docs` (ex_doc) must build clean; treat warnings as errors.
- lib/tightbeam.ex is the project front page (@moduledoc overview), not
  scaffold cruft.
