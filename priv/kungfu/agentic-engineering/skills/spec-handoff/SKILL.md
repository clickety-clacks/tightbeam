---
name: spec-handoff
description: How a spec moves to implementation and stays authoritative while it is built — readiness, marked holes, content-hash binding, clarifications that amend the canonical file first. Use when handing a spec to builders or answering a build-time question.
---

# Spec handoff

## Before handoff
1. Acceptance is concrete and testable: a coder can check its work against each clause,
   and a reviewer can judge each clause satisfied or not from evidence. Each clause has
   a concrete example (Given/When/Then) attached — the format is what proves the clause
   is decidable.
2. Open questions are listed explicitly in their own section, not buried in prose, each
   marked BLOCKING or NON-BLOCKING. A marked hole is one an orchestrator can build
   around; an unmarked hole it cannot see. A blocking question on a load-bearing
   concept goes to the user
   (`tightbeam wake --user <id> --prompt "<the question>"`) and holds back the affected
   scope; separable scope hands off.
3. Non-goals are named, so implementation cannot drift into them. The eight-section
   skeleton (spec-homing) is yours to fill; the reviewer blocks on a load-bearing hole
   in it, not on its shape.
4. The handoff names the spec by identity, not just topic: the canonical path plus the
   content the work-item is bound to (`--spec-ref`/`--spec-sha256`, see spec-homing),
   the in-scope goals, and the work-item id. Bind (or re-bind) the hash AFTER the
   adversarial spec review clears — builders build from the cleared text.
5. The spec states what operating pattern it teaches agents — "none," or the
   substrate-manual amendment lands with the spec.

## During implementation
You remain the spec's expert while it is built. Intent lives with you; the spec is
knowingly incomplete, and the gap-filling decisions must be checked against intent, not
re-derived by whoever hit the gap. Stay addressable: coders and reviewers reach you
with `tightbeam wake --role <your-role> --prompt "<their question>"`. Answer
conformance and ambiguity questions; do not direct the workers and do not own their
assignments.

## Clarifications
Every clarification updates the canonical spec file first, then the answer goes back:
1. Edit the canonical spec so it carries the ruling. If the ruling changes what the
   work-item is bound to, re-bind the content hash.
2. Wake the asker with the spec path and a summary of what changed.
An instruction that exists only in a message and not in the spec is not a ruling; the
next reader of the spec will build without it.

## When implementation finds a gap
A gap a coder reports is a spec defect. When the ruling is a detail within the approved
intent, rule on it yourself. When the ruling would add a load-bearing requirement,
change the product's behavior, or decide something that belongs to the user, send it to
the user (`tightbeam wake --user <id> --prompt "<the gap and the decision needed>"`)
and rule as the user answers. Either way: amend the canonical spec, re-bind the hash,
attest the amendment as progress on your assignment, and wake the coder with the path
and the change. Affected coding resumes after the spec carries the amendment.
