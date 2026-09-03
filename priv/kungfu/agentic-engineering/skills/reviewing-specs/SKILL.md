---
name: reviewing-specs
description: Adversarially review a spec before anything is built from it: adjudicate the ask's facets, then hunt contradictions, load-bearing holes, undecidable clauses, scope, and the invisible ambiguity. Use when reviewing a spec assignment.
---

# Reviewing specs

You adversarially review a spec before anything is built from it. You did not write it;
you find where building the MVP of the ask from it would go wrong. Catching a defect
here is the cheapest defect removal there is. The question you answer is one: can a
coder build the MVP of the ask from this document without inventing anything
load-bearing?

1. Read the spec whole, then the assignment that commissioned your review; its
   `--reviews` link (or subject) names the spec assignment under review, and your
   verdict note cites that id. Adjudicate the facets first: which of the ask's facets
   does the spec make must-have for an initial implementation, which does it defer,
   and which does it add that the ask never named? A spec that specifies beyond the
   ask is unfit the same way code is.
2. Use the eight canonical sections (Goal, Non-Goals, Terms, Assumptions, Invariants,
   Architecture, Acceptance, Open Questions; spec-homing names the set) as your hunt
   list, not as a gate. Each names a class of defect that hides when its content is
   absent. A missing section is blocking only when the content it would have carried
   is load-bearing for the MVP: an unmarked hole, an unnamed non-goal a coder would
   walk into, an assumption the build rests on. An empty Non-Goals is a post-mvp fix
   to the document.
3. Hunt contradictions: two clauses that cannot both hold, a requirement that violates
   a stated invariant, an acceptance item no implementation could satisfy.
4. Hunt holes: a load-bearing concept the spec uses but never defines; a behavior every
   implementation must decide that the spec is silent on; an unstated dependency; an
   assumed given the spec relies on but never records. A hole on a concept the MVP is
   built on is blocking, because a coder's obvious answer may differ from yours. A hole
   on a facet the ask ships without is post-mvp, or a NON-BLOCKING open question for
   the writer to mark.
5. Hunt the invisible ambiguity: a clause that reads clean to you but could be read a
   second confident way by a coder from another angle. Weasel words (fast, robust, as
   appropriate), and/or, and passive voice with no named actor are its tells. If you
   can construct two implementations that both satisfy the words and differ in
   behavior on a must-have, the clause is blocking.
6. Check every acceptance clause is decidable: a coder can build to it and a reviewer
   can later classify it satisfied or unsatisfied from evidence. An undecidable clause
   on a must-have is blocking.
7. Check scope: each requirement traces to the stated goal. Behavior inside a named
   non-goal, or a requirement serving no goal, is beyond the ask and unfit.
8. Check the spec answers what operating pattern it teaches agents: an explicit
   "none," or a substrate-manual amendment landing with the spec. A missing answer is
   post-mvp unless the spec adds agent-facing capability the MVP ships with.
9. There is no code to reproduce against. In the review document, cite the exact clause
   text for every finding and put it in one of two classes: `blocking` (the MVP cannot
   be built from the document without it) or `post-mvp` (recommended, ordered by
   value). Nothing in the second class gates.
10. Write the review document, calculate its SHA-256, and record the exact bytes as a
   report artifact on the work item. The document is the canonical deliverable: the
   facet adjudication, the clause table, citations, evidence, reasoning, and the
   post-mvp list live there:
   `tightbeam artifact-record --kind report --title "<title>" --path <path> --work-item <workItemId> --sha256 <hex>`.
11. End with the verdict on your assignment:
   `tightbeam attest <assignmentId> --kind verdict --verdict reviewed-clean --note "<summary + art_id + sha256>"`
   when no blocking finding remains, whatever the post-mvp list holds. File
   `--verdict changes-requested` otherwise, naming each blocking finding and the
   must-have it protects. The verdict is the document's concise executive summary: the
   outcome, the major points, the report artifact's id and SHA-256, and the reviewed
   assignment id. Then wake the spec-writer with the verdict and file completion on the
   reviewing assignment you hold, whatever the verdict was. The report artifact,
   verdict, wake, and completion are four different rows; reviewing-code 9b and 9c
   govern them identically, including closing your card rather than sitting on it while
   the spec-writer revises. Whether a revision warrants a fresh spec review is the
   orchestrator's judgment. A contested blocking finding goes to the orchestrator, as
   in reviewing-code 10.
