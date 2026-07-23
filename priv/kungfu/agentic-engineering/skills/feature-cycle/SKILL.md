---
name: feature-cycle
description: The loop that takes a feature from intent to a user-verified result — spec, adversarial spec review, decompose, implement, review, integrate, real run, user verification, teardown. Use when you own a feature or bug and are driving it end to end.
---

# Feature cycle

One work-item is the durable thread for the whole feature:
`tightbeam work-item-create --title "<feature>"`. When a spec already exists at a
canonical path, bind it to the work-item by content, not by memory:
`--spec-ref <name> --spec-sha256 <hex>` records the exact spec version the work
serves, so every coder and reviewer reads the same one. Every assignment below threads
to the work-item (`--work-item <id>`). `tightbeam dispatch --to <holder> --subject "…"
--brief "…" --work-item <id>` opens a plain card and wakes its holder in one atomic step;
a card that declares files (`--files`) or links a review (`--reviews`) opens with `assign`
and is then woken, because those flags live on `assign` — so the steps below that need
them keep that two-step form.

Keep only a handful of goals truly in-flight at once (see the kernel); this loop is
per-feature, but your attention across features is the scarce resource.

1. **Spec.** Spawn a spec-writer and assign it the spec:
   `tightbeam assign --subject "spec: <feature>" --role spec-writer --work-item <id>`.
   The spec states invariants first, a testable acceptance contract, open questions,
   and non-goals. An open question that decides the nature of the product goes to the
   user (`tightbeam wake --user <id> --prompt "<the question>"`) before spec review;
   an implementation-detail question does not.
2. **Adversarial spec review.** Spawn a reviewer on a different model family than the
   spec-writer, thinking hard; when one family is available, spawn a fresh session at a
   higher thinking level. Link the review to the work it reviews so the substrate can
   witness the independence:
   `tightbeam assign --subject "review of spec <id>" --role reviewer:<slug> --work-item <id> --reviews <specAssignmentId>`.
   The reviewer works per `reviewing-specs`. On `changes-requested`, wake the
   spec-writer to revise; repeat until `reviewed-clean`. The spec-writer then pins (or
   re-pins) the reviewed spec's hash on the work item (spec-handoff skill), so builders
   build from the cleared text.
3. **Decompose.** Break the spec into focused, independently verifiable coding goals —
   one objective per dispatch, together covering every clause. Cut along the seams that
   minimize what crosses between goals: defects cluster at the interfaces between
   different agents' work. Run independent goals in parallel; order goals that touch
   the same code. Declare each goal's files on its assignment
   (`--files '["path", ...]'`) — the substrate refuses a second open assignment that
   overlaps those paths, so two coders cannot be aimed at the same file.
4. **Implement.** For each goal, assign a coder one goal with the spec path and the
   work-item id. The coder attests progress as it works — including when the goal
   builds clean and is ready for review. Completion is attested only after the review
   verdict is `reviewed-clean` and integration is proven (a completion closes the
   assignment, and the producer stamps and the user's verdict land only on open ones).
5. **Code review.** Every goal ready for review goes to an independent reviewer: a
   session that did not produce the work, on a different model family than the
   producer, thinking hard; when one family is available, a fresh session at a higher
   thinking level. Link it to the reviewed work:
   `tightbeam assign --subject "review of <goal>" --role reviewer:<slug> --work-item <id> --reviews <coderAssignmentId>`.
   The `--reviews` link is what lets the substrate compute whether a verdict came from
   a different provider than produced the work; a verdict filed without it is a claim
   of independence the rows cannot confirm. On `changes-requested`, wake the coder to
   iterate; repeat until `reviewed-clean`.
6. **Integrate.** The coder reconciles the change with main
   (committing-and-pushing skill); the review that clears the work covers the
   post-reconciliation result — a review from before integration is stale where
   integration changed semantics.
7. **Real run.** For work that touches live inputs, require a real run against real
   inputs before it ships: `tightbeam run-smoke <assignmentId>` runs the org's
   committed smoke command and stamps `real-run-passed`. Compiling, green tests, and a
   clean review are not that proof. (`run-tests <assignmentId>` likewise stamps
   `tests-passed` from the committed test command — cheap to require on every goal.)
8. **Ready for user verification.** Wake the user —
   `tightbeam wake --user <id> --prompt "<what changed, how to try it, what decision remains>"`.
   Done means the user can try it; the user's verdict, when given, is attested on the
   work-item's assignment as `--kind verdict`.
9. **Teardown.** Retire sessions whose job has ended
   (`tightbeam retire --session <key>`), dependents first; a finished feature leaves no
   idle hires behind.

When a goal is broken and not converging after two attempts, revert to the last
known-good state and re-dispatch from there — the pull to spend a third attempt on an
approach you chose is escalation of commitment, not diligence.
