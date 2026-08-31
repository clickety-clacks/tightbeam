---
name: spec-conformance
description: A verdict rests on a clause-by-clause reading of the spec against the work — satisfied, unsatisfied, unproven, or out-of-scope, each with evidence. Use to build the clause table behind a verdict.
---

# Spec conformance

A review verdict rests on a clause-by-clause reading of the spec against the work. The
clause table is also the trace that proves the review happened — a verdict without it
is a rubber stamp.

1. Read the canonical spec at its canonical path (verify the work item's pinned sha256
   when present — conformance is owed to the ruling text). Enumerate every requirement
   clause: every invariant, every acceptance item, every stated behavior. Non-goals
   enter the list as exclusions to verify.
2. Classify each clause with evidence:
   - **satisfied** — the implementation meets it, and you can cite the code, test, or
     run output that proves it.
   - **unsatisfied** — the implementation contradicts or omits it; cite where.
   - **unproven** — plausibly met, but no evidence proves it: no test exercises it, no
     run demonstrates it, the code path cannot be confirmed. Unproven is its own class;
     do not round it up to satisfied.
   - **out-of-scope** — the clause belongs to a goal this dispatch does not cover; name
     the assignment that covers it.
3. The review does not pass while any clause is unsatisfied or unproven. An unproven
   clause blocks exactly as an unsatisfied one does; the remedy differs — produce the
   missing evidence (a test, a real run — run it the way the repository's prose
   defines verification, record the results as a report artifact, and file the
   verification verdict) or return the work.
4. Check the exclusions: behavior inside a named non-goal is an unrequested addition
   and a finding.
5. Keep the full clause table in the verdict note when the note fits the 2,000-character
   cap. When it does not fit, write the full table to one report file, calculate its
   SHA-256, and record that exact file as one immutable report artifact:
   `sha256sum <report>` then
   `tightbeam artifact-record --kind report --title "review clause table" --path <report> --work-item <workItemId> --sha256 <hex>`.
   Cite the returned artifact id and the same SHA-256 in a concise verdict note. Do not
   truncate the table, split it across verdicts, or request a cap increase. If an
   oversized note receives `invalid_note`, use this artifact remedy instead of retrying
   the oversized note. When every clause is satisfied or out-of-scope, file
   `tightbeam attest <assignmentId> --kind verdict --verdict reviewed-clean --note "<basis; clause-table artifact id; sha256>"`;
   when any clause is unsatisfied or unproven, file the same evidence with
   `--verdict changes-requested`.
6. When a clause is too vague to classify, the spec has a hole. Wake the spec-writer
   (`tightbeam wake --role spec-writer --prompt "<the exact vague clause>"`); the
   clause is unproven until the spec rules.
