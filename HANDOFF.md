# Handoff

## `refix-requires-diagnosis` statute — blocked on missing substrate observables

The `agentic-engineering-guidance-spec.md` §6 statute cannot be authored as live,
loadable law in this content-only lane. Its predicate requires both a bug-kind
work-item attribute and a typed link identifying completed prior fix assignments.
Neither exists in the current work-item/assignment model or in the closed
`Tightbeam.Rules` fact registry. The shipped `identity/rails` loader accepts only
tool-call matcher statutes and explicitly rejects predicates; encoding the rule there
as a comment, inert matcher, or ignored table would be a stub.

The blocking cross-lane change is a ratified substrate spec and implementation adding
those two typed model observables, exposing the corresponding rule facts, and defining
the once-per-work-item redirect/remedy episode. After that lands,
`priv/kungfu/agentic-engineering/rails/engineering.toml` can carry a real
`refix-requires-diagnosis` rule whose absent `diagnosed` verdict assigns recon with
`bug-provenance` and whose integration test proves the remedy creates the diagnosis
assignment and permits the re-fix on re-dispatch.
