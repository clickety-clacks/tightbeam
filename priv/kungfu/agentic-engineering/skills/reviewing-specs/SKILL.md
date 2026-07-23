---
name: reviewing-specs
description: Adversarially review a spec before anything is built from it — structure, contradictions, holes, undecidable clauses, scope, and the invisible ambiguity. Use when reviewing a spec assignment.
---

# Reviewing specs

You adversarially review a spec before anything is built from it. You did not write it;
you find where building from it would go wrong. Catching a defect here is the cheapest
defect removal there is — a requirement flaw is injected earliest and caught latest.

1. Read the spec whole, then the assignment that commissioned your review — its
   `--reviews` link (or subject) names the spec assignment under review; your verdict
   note cites that id.
2. Check the structure the spec-writer owes — all eight canonical sections present
   (Goal; Non-Goals named; Terms designated, what each denotes; Assumptions as their own
   falsifiable list; Invariants stated first; Architecture; Acceptance, a concrete
   testable contract; Open Questions listed explicitly, each marked blocking or
   non-blocking; spec-homing names the canonical set). The set is canonical, not a
   minimum — a missing section is a blocking finding, and an empty section must be stated
   empty rather than dropped.
3. Hunt contradictions: two clauses that cannot both hold, a requirement that violates
   a stated invariant, an acceptance item no implementation could satisfy.
4. Hunt holes: a load-bearing concept the spec uses but never defines; a behavior every
   implementation must decide that the spec is silent on; an unstated dependency; an
   assumed given the spec relies on but never records. A hole on a concept the work is
   built on is a blocking finding — an UNMARKED hole becomes an agent's invention, even
   when the right answer seems obvious to you, because a coder's obvious answer may
   differ.
5. Hunt the invisible ambiguity: a clause that reads clean to you but could be read a
   second confident way by a coder from another angle. Weasel words (fast, robust, as
   appropriate), and/or, and passive voice with no named actor are its tells. If you
   can construct two implementations that both satisfy the words and differ in
   behavior, the clause is a finding.
6. Check every acceptance clause is decidable: a coder can build to it and a reviewer
   can later classify it satisfied or unsatisfied from evidence. An undecidable clause
   is a finding.
7. Check scope: each requirement traces to the stated goal. Behavior inside a named
   non-goal is a finding; a requirement serving no goal is a finding (gold-plating at
   the source).
8. Check the spec answers what operating pattern it teaches agents: an explicit
   "none," or a substrate-manual amendment landing with the spec. A spec that adds
   agent-facing capability without that answer is a finding.
9. There is no code to reproduce against; instead cite the exact clause text for every
   finding, with a severity: blocking, important, or nit.
10. End with the verdict on your assignment:
   `tightbeam attest <assignmentId> --kind verdict --verdict reviewed-clean --note "<basis, citing the reviewed assignment id>"`
   when nothing blocking or important remains; `--verdict changes-requested` otherwise,
   with every finding, its severity, and its clause citation in the note. Then wake the
   spec-writer with the verdict and file completion on the reviewing assignment you
   hold — reviewing-code 8b and 8c govern here identically.
