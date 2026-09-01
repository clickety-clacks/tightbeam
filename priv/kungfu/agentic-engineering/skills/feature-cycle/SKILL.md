---
name: feature-cycle
description: The loop that takes a feature from intent to a user-verified result — spec, adversarial spec review, decompose, implement, review, spirit review for substantial changes, integrate, real run, user verification, teardown. Use when you own a feature or bug and are driving it end to end.
---

# Feature cycle

One work-item is the durable thread for the whole feature:
`tightbeam work-item-create --title "<feature>"`. When a spec already exists at a
canonical path, bind it to the work-item by content, not by memory:
`--spec-ref <name> --spec-sha256 <hex>` records the exact spec version the work
serves, so every coder and reviewer reads the same one. Every assignment below threads
to the work-item (`--work-item <id>`). `tightbeam dispatch --to <holder> --subject "…"
--brief "…" --work-item <id>` opens a plain card and wakes its holder in one atomic step;
a card that includes an advisory file suggestion (`--files`) or links a review
(`--reviews`) opens with `assign` and is then woken, because those flags live on
`assign` — so the steps below that use them keep that two-step form.

Keep only a handful of goals truly in-flight at once (see the kernel); this loop is
per-feature, but your attention across features is the scarce resource.

0. **Posture.** Before anything is staffed, rule the slice heavy or light (the
   orchestrator kernel defines both) and file it as a verdict on your slice card on
   this work item: `--verdict posture-heavy` or `--verdict posture-light`, grounds in
   the note. The substrate refuses a coder card on an unpostured work item. HEAVY runs
   steps 1 through 10. LIGHT skips steps 1 through 3: the work item's input is the
   spec, one coder is assigned it as the goal (step 4), and its review (step 5) runs
   at the light bar. Every other step applies to both.
1. **Spec.** Spawn a spec-writer and assign it the spec:
   `tightbeam assign --subject "spec: <feature>" --role spec-writer --work-item <id>`.
   The spec states invariants first, a testable acceptance contract, open questions,
   and non-goals. An open question that decides the nature of the product goes to the
   user (`tightbeam wake --user <id> --prompt "<the question>"`) before spec review;
   an implementation-detail question does not.
2. **Adversarial spec review.** A spec is authoritative policy, so it requires review.
   Select the first qualified permitted candidate from the ordered spec-review row in
   `preferred-models.md`. Try each candidate once; on an unavailable candidate, step
   right once. Send ambiguous qualification to your parent, and when the row is
   exhausted have the parent record `work-blocked` or surface the missing credential.
   Spawn the selected reviewer as a fresh session. Link the review to the work it
   reviews so the substrate can witness the independence:
   `tightbeam assign --subject "review of spec <id>" --role reviewer:<slug> --work-item <id> --reviews <specAssignmentId>`.
   The reviewer works per `reviewing-specs`. On `changes-requested`, read each
   blocking finding against the ask first: a finding the MVP ships without gets
   `review-overreach` on the review card (orchestrator kernel, "Verifying without
   redoing") and the reviewer re-files. Then wake the spec-writer to revise the rest;
   repeat until `reviewed-clean`. The spec-writer then pins (or
   re-pins) the reviewed spec's hash on the work item (spec-handoff skill), so builders
   build from the cleared text.
3. **Decompose.** Break the spec into focused, independently verifiable coding goals —
   one objective per dispatch, together covering every clause. Cut along the seams that
   minimize what crosses between goals: defects cluster at the interfaces between
   different agents' work. Run independent goals in parallel; order goals that touch
   the same code. Add `--files '["path", ...]'` when an advisory suggestion will help
   others discover the expected work area. It grants no path and forbids no work.
   Reconcile real overlaps normally.
4. **Implement.** For each goal, assign a coder one goal with the spec path and the
   work-item id. The coder attests progress as it works — including when the goal
   builds clean and is ready for review. Completion is attested only after the review
   verdict is `reviewed-clean`, the verification papertrail is recorded, and
   integration is proven (a completion closes the assignment, and verdicts land only
   on open ones).
5. **Effect review.** Classify the effect, not the holder's role. Exactly one review is
   required when a goal changes code or source behavior; authoritative specs, policy,
   Kung Fu, or rails; a release artifact or promotion; or live runtime, configuration,
   or identity state. One goal that carries several qualifying effects still gets one
   review. Review verdicts and review-card lifecycle, read-only recon or advice,
   status/accountability work, and coordination are evidence-only and get no review.

   For a review-required effect, select the first qualified permitted candidate from
   the ordered code-review row in `preferred-models.md`. Try each candidate once. An
   unavailable candidate advances the selection one place to the right; never retry
   the same candidate. Send ambiguous qualification to your parent. If the row is
   exhausted, the parent records `work-blocked` or surfaces the credential need. Spawn
   the selected reviewer as a fresh session with the capability the effect requires.
   Same model, provider, or harness remains eligible. Open exactly one linked review
   card for the change and keep that card through all revisions:
   `tightbeam assign --subject "review of <goal>" --role reviewer:<slug> --work-item <id> --reviews <coderAssignmentId>`.
   The `--reviews` link and the verdict by that card's different-session holder are
   what let the substrate compute independence. Harness and provider differences stay
   observable selection evidence; they do not gate completion. A verdict filed
   without the link is a claim the rows cannot confirm. On `changes-requested`, read
   each blocking finding against the ask before you wake anyone: a finding the MVP
   ships without gets `review-overreach` on the review card and the reviewer re-files
   with it moved to post-mvp. Then leave the review card open, wake the producer to
   iterate on what remains, and have the same reviewer re-file on that card until
   `reviewed-clean`. Complete the review card only after its clean verdict; never
   multiply or close-and-reopen cards for review rounds. Under light posture the
   reviewer's bar is "nothing egregiously wrong," and the same overreach check applies.
   The product owner's spirit review (step 6) asks a different question, whether the
   built thing is the product; the reviewer asks whether it is the ask. Nobody gates
   the same question twice, and spirit is judged once per work item (step 6), never
   once per slice.
6. **Spirit review (substantial work items).** Spirit review happens once per work
   item, never once per goal or slice. A work item is substantial when it produces
   product behavior with no product-owner-gated spec authority behind it —
   behavior an agent or user experiences, an authority moved between homes, or a
   change to what a fresh install boots as, that no owner-gated spec states. A
   goal that delivers, restores, or preserves behavior an owner-gated spec states,
   or touches no product surface (bug fixes, tests and infrastructure, legibility
   text, dependency bumps that hold every behavior contract), is routine: the
   spirit judgment on it already happened at the owner's spec gate, and gating it
   again at merge would judge the same thing twice. An effort-check-in arriving
   spec-less is substantial; a CVE bump that holds every contract is routine.
   Cross-model spec review is quality control, not spirit — a spec cleared only by
   cross-model review makes nothing routine.

   If the work item already carries the product owner's spirit verdict for its current
   intent, every implementation slice inherits it; do not ask again as the work is
   decomposed. Otherwise, the work item does not integrate until the product owner has
   answered one spirit summary. Wake the owner with what changed in product terms,
   which Spirit clauses it serves, and what it forecloses. Keep revisions on that same
   spirit-review assignment. The answer is `spirit-accepted`, or `changes-requested`
   with what the spirit refuses. An unanswered
   gate queues the merge indefinitely — that wait is the accepted cost; chase it
   up the existing wake rungs, never around the gate. An answer from before
   integration is stale where integration changed the product-visible semantics; revise
   the same work-item spirit review instead of opening one per slice. When you cannot
   tell which side a work item falls on,
   that question goes to the product owner too — the ask costs one wake; a wrong
   guess merges a change the spirit never accepted.
7. **Integrate.** Pin the authorized target tip before reconciliation and hold that
   exact tip until the reviewed candidate lands. Unrelated target movement is a hold
   violation to report, not a request to rebuild or reconcile again. The coder follows
   the committing-and-pushing skill; the review that clears the work covers the
   post-reconciliation result.
8. **Verification papertrail.** The coder writes the change first, runs its focused
   tests next, and then broadens verification only in proportion to its risk. Never
   require a full-suite baseline before implementation. Before a goal completes, the
   coder verifies the work the way the repository's prose defines verification (its
   AGENTS.md or equivalent),
   records the results (output, logs, evidence) as a report artifact on the work item
   with `tightbeam artifact-record`, and files
   `tightbeam attest <assignmentId> --kind verdict --verdict verified` with a note
   saying what was run and what was observed. Compiling, green tests, and a clean
   review are not that proof; the verification statute blocks a completion whose
   papertrail is missing. A repository that never defines verification is a process
   gap — escalate it, do not guess.
9. **Ready for user verification.** Wake the user —
   `tightbeam wake --user <id> --prompt "<what changed, how to try it, what decision remains>"`.
   Done means the user can try it; the user's verdict, when given, is attested on the
   work-item's assignment as `--kind verdict`.
10. **Teardown.** Retire sessions whose job has ended
   (`tightbeam retire --session <key>`), dependents first; a finished feature leaves no
   idle hires behind.

When a goal is broken and not converging after two attempts, revert to the last
known-good state and re-dispatch from there — the pull to spend a third attempt on an
approach you chose is escalation of commitment, not diligence.
