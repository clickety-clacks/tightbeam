---
name: committing-and-pushing
description: Commit and push discipline — build before committing, one concern per commit with behavior and structure never mixed, deliberate staging, semantic reconciliation before main advances. Use when committing, pushing, or merging a branch toward main.
---

# Committing and pushing

## Every commit
1. Build before you commit. Run the build and the tests the change touches; a commit
   that does not build is never pushed. A broken commit on a shared branch breaks every
   colleague who pulls it.
2. `git status` and `git diff` first: know exactly what you are committing, and confirm
   every staged change is yours. Stage deliberately — do not sweep in files you did not
   change.
3. One concern per commit, and never behavior and structure in the same one. A commit
   that both moves code and changes what it does cannot be reviewed under one lens —
   the reviewer cannot tell which lines are supposed to change output. Split them:
   structure commits reviewed for direction, behavior commits reviewed for
   correctness. A tangled commit is also permanent damage — it poisons blame, bisect,
   and defect archaeology long after it merges.
4. Message: concise, descriptive, states what the change does. No co-author lines, no
   tool or model attributions, no generated-by noise.
5. Push to your own branch.

## Merging your branch into main
Merging is a semantic integration problem, not a text-selection problem.
1. Merge main into your branch first. Every conflict is resolved on your branch.
2. Resolve conflicts semantically. Never resolve by wholesale accepting ours, theirs,
   or the newer block. For each conflict, determine what each side contributes — read
   the merge base, both sides, callers, and tests — and produce a combination that
   keeps your intended change and every orthogonal behavior main already carries. When
   two behaviors are truly incompatible, stop and send the decision up; do not silently
   choose one.
3. Prove the reconciled branch: build, tests, and the repository's required gates, on
   the branch, after reconciliation.
4. The review that clears the work covers the post-reconciliation result; a review from
   before reconciliation is stale where reconciliation changed semantics.
5. Advancing main is the orchestrator's decision: it happens after the
   orchestrator has cleared the work — the `reviewed-clean` verdict is on
   record, and, for a substantial change (feature-cycle's spirit-review
   definition), the product owner's `--kind verdict` attest is on the goal's
   assignment. A routine change — a wire-spelling fix, not an effort-check-in —
   advances on `reviewed-clean` alone. You execute the mechanics: confirm main
   is an ancestor of the reconciled branch
   (`git merge-base --is-ancestor main <branch>`), then advance main from the
   branch — fast-forward, because the reconciliation already happened on the
   branch. Push Tightbeam main only to the explicit canonical URL:
   `git push git@github.com:clickety-clacks/tightbeam.git <branch>:main`. Never
   rely on a named remote such as `origin` for this push.
6. After any claimed push to Tightbeam main, the orchestrator independently runs
   `git ls-remote git@github.com:clickety-clacks/tightbeam.git refs/heads/main`
   and requires the returned SHA to equal the expected integrated commit before
   reporting success. The push exit status, a local remote-tracking ref, or the
   pusher's report does not satisfy this check.
7. When main moved during reconciliation, merge it in again and re-prove before
   advancing.
