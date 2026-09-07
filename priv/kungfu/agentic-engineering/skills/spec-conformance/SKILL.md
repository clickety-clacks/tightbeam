---
name: spec-conformance
description: A verdict rests on a clause-by-clause reading of the ask against the work: satisfied, unsatisfied, unproven, or out-of-scope, each with evidence, each weighed by whether the MVP needs it. Use to build the clause table behind a verdict.
---

# Spec conformance

The clause table is how you SEE the work, not the verdict. It proves the review
happened and shows which clause carried which evidence; the verdict is the facet
adjudication applied to it. A verdict without the table is a rubber stamp. A table
that blocks on every row is the other failure.

1. Read the ask at its source. Under heavy posture that is the canonical spec at its
   canonical path (verify the work item's pinned sha256 when present; conformance is
   owed to the ruling text). Under light posture the work item's input is the spec:
   enumerate its asks as the clauses. Either way, list every requirement clause: every
   invariant, every acceptance item, every stated behavior. Non-goals enter the list
   as exclusions to verify.
2. Mark each clause must-have or post-mvp before you look at the code: can the ask
   ship without it? This is the facet adjudication from `reviewer-code.md`,
   carried down to clause grain.
3. Classify each clause with evidence:
   - **satisfied**: the implementation meets it, and you can cite the code, test, or
     run output that proves it.
   - **unsatisfied**: the implementation contradicts or omits it; cite where.
   - **unproven**: plausibly met, but no evidence proves it: no test exercises it, no
     run demonstrates it, the code path cannot be confirmed. Unproven is its own class;
     do not round it up to satisfied.
   - **out-of-scope**: the clause belongs to a goal this dispatch does not cover; name
     the assignment that covers it.
4. The verdict follows the must-haves. A must-have clause that is unsatisfied or
   unproven makes the work unfit: the remedy is the missing evidence (a test, a real
   run recorded as a report artifact with the verification verdict) or the missing
   behavior, and the finding is `blocking`. A post-mvp clause that is unsatisfied or
   unproven is recorded as a `post-mvp` finding with its evidence gap named; it does
   not hold the work.
5. Check the exclusions: behavior inside a named non-goal is beyond the ask and unfit.
6. The full clause table is REQUIRED in the review document, where it has room to carry
   the evidence each clause rested on. Calculate the document's SHA-256 and record the
   exact bytes first:
   `tightbeam artifact-record --kind report --title "<title>" --path <path> --work-item <workItemId> --sha256 <hex>`.
   The verdict note has a 2,000-character cap. File it as an executive summary that
   names the artifact's id and SHA-256, so the next reader can follow it to the table:
   `tightbeam attest <assignmentId> --kind verdict --verdict reviewed-clean --note "<summary + art_id + sha256>"`
   when every must-have clause is satisfied or out-of-scope and no blocking finding
   remains. File `--verdict changes-requested` when any must-have clause is
   unsatisfied or unproven. Do not paste the table into the note, truncate it, split it
   across verdicts, or request a cap increase.
7. When a clause is too vague to classify, the spec has a hole. If the clause is a
   must-have, wake the spec-writer
   (`tightbeam wake --role spec-writer --prompt "<the exact vague clause>"`) and the
   clause is unproven until the spec rules. If it is post-mvp, record the hole and move
   on.
