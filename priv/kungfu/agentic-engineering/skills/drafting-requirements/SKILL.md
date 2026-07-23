---
name: drafting-requirements
description: The craft of a single requirement — verifiability, atomicity, active voice, banned vague words, examples as acceptance, and two-way traceability. Use while drafting or tightening the requirements in a spec.
---

# Drafting requirements

The kernel's filter decides whether a line is a requirement at all: can it be checked
pass/fail? This skill is how you make each surviving line unambiguous, atomic, and
traceable.

These requirements live inside the spec's canonical skeleton — the eight sections
spec-homing names (Goal, Non-Goals, Terms, Assumptions, Invariants, Architecture,
Acceptance, Open Questions). That set is canonical, not a starting point: every spec
carries all eight. This skill sharpens the individual lines that fill it.

## Kill the vague words
Keep a banned list open while you draft; each word marks a decision you have not made:
- **and/or** — forces the reader to choose the interpretation. State exactly which
  case(s) apply.
- **etc. / and so on / including but not limited to** — you stopped enumerating before
  the thinking was done. Finish the list.
- **fast, robust, user-friendly, seamless, intuitive, efficient, flexible** —
  subjective, no test. Replace with a measured, checkable criterion.
- **minimize / maximize / optimize / better / faster / improved** — a comparative with
  no baseline. Better than what, toward which measurable target?
- **as appropriate / if necessary / where feasible / normally / typically** — pushes
  the decision downstream to whoever implements. Decide it here.
- **all / every / always / never / none** — usually untestable and usually false at an
  edge; they hide the exception case you did not consider. ("All" over a plural is
  also ambiguous between each-separately and the-set-as-a-whole; prefer "each.")

## State behavior positively
A "shall not" can be violated a thousand unenumerable ways, so it cannot be verified;
state what the system observably DOES instead, and let the non-goals carry the
exclusions.

## Expose the missing actor
Passive voice deletes the responsible agent — "the order shall be validated" by whom,
the client, the server, a human? The missing actor is where integration bugs live.
Write each requirement in active voice: name the actor for every action.

## One requirement, one claim
A requirement is atomic — one testable claim. A conjunction is a smell that you have
stapled several requirements together; split them, because a compound requirement
cannot be traced or classified when one half passes and one half fails.

## Examples ARE the acceptance
Write the acceptance as concrete, realistic examples, not abstract restatements —
Given a precondition, When an actor acts, Then an observable result. The examples
become the acceptance tests and double as living documentation that cannot silently
drift from the system. If you cannot fill in a concrete Then, the requirement is not
finished.

## Trace both directions
Every requirement traces forward to what will implement and verify it (forward trace
proves nothing was dropped), and every design element and test traces back to a
requirement that justifies it (backward trace catches gold-plating — code or a test
with no requirement behind it). A test with no requirement is untraceable scope; a
requirement with no test is unverified coverage. The two directions catch different
defects, which is why the spec must support both.
