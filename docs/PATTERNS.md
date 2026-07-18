
## Documentation rules (Elixir-native; agents contribute against these)
- Every public function: `@doc` (what + the invariant it upholds) and `@spec`.
- Shared shapes get `@type t`-style types (see Tightbeam.Ledger.turn/0).
- Doctests for pure functions (parse/format helpers); ExUnit for stateful.
- `@moduledoc` = role + invariants + spec-section references (cite the spec
  by section name, not internal review-round numbers).
- `mix docs` (ex_doc) must build clean; treat warnings as errors.
- lib/tightbeam.ex is the project front page (@moduledoc overview), not
  scaffold cruft.

## Shared serializers never touch the slow world

A GenServer serializes its callers — that is its value and its hazard. Any
process that many others call (DB owner, ConnRegistry, AdapterCoordinator,
WakeScheduler) must do only fast, bounded work in its loop: no network, no
ssh, no rsync, no unbounded file I/O. Expensive or hangable work runs in the
process that OWNS its failure (an adapter boots itself via handle_continue;
a turn runs in its TurnTask), so a slow operation hurts its owner and never
the room. The DB owner is the deliberate exception that proves the rule: it
serializes on purpose and is safe ONLY because every operation through it is
prepared-statement-fast by construction. When an operation's cost class
changes (a local file write grows an rsync), its location must change with
it — this exact miss wedged the AdapterCoordinator behind a dead host once
(see JOURNAL: dead-host hardening) and is the failure mode this rule exists
to prevent. BEAM bounds the blast radius of this mistake; it does not
prevent it. The discipline is ours.
