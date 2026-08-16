---
name: committing-and-pushing
description: Commit, push, and canonical-branch integration discipline — build before committing, separate concerns, reconcile semantically, and prove local and remote canonical-branch state. Use when committing, pushing, merging toward the line's integration branch, or verifying that the integration branch integrated.
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
5. Advancing the canonical branch is the orchestrator's decision. It happens after the
   orchestrator has cleared the work: the `reviewed-clean` verdict is on record and,
   for a substantial change under feature-cycle's spirit-review definition, the
   product owner's verdict is on the goal assignment. A routine change advances on
   `reviewed-clean` alone. After those verdicts exist, execute only “Proving the
   canonical local branch” below. That section is the sole procedure that advances
   the canonical ref.
6. When main moved during reconciliation, merge it in again and re-prove before
   advancing.

## Proving the canonical local branch

The **canonical branch** is this line's integration branch: the branch the repository's
branch authority (`AGENTS.md` at the repository root) names as the integration target.
The integration assignment must name it as a full `refs/heads/<name>` ref — written
below as `<canonical-ref>`, with `refs/remotes/origin/<name>` as its tracking ref,
written `<tracking-ref>`. Every command uses that exact assignment-named ref. A literal
`refs/heads/main` is lawful only when the card names it.

The **canonical checkout** is the product owner's repository workdir named in the
integration assignment. It is the local surface that proves whether the canonical
branch integrated. A SHA read only from a remote proves remote state. It does not
prove the branch or worktree state in this checkout.

Run this ceremony only when the integration assignment is the sole open assignment
authorized to use the exact canonical path. The assignment must name that path, the
canonical ref, and the reconciled branch as full `refs/heads/<name>` refs. If another
open integration assignment authorizes the same path, refuse. The product owner and
other agents do not use the checkout until the coder records POST or a refusal.

Run each command in order. Stop on a nonzero exit or on output that does not satisfy
its stated check.

### Synchronize before advancing the canonical branch

1. Inspect the durable assignment rows. Require this integration assignment to be the
   only open assignment authorized to integrate through the canonical path.
2. Require `git symbolic-ref -q HEAD` to print exactly `<canonical-ref>`. A detached
   HEAD or another branch is a refusal. Do not switch branches as part of this ceremony.
3. Require `git status --porcelain=v1 --untracked-files=all` to print nothing. A staged,
   unstaged, or untracked path is a refusal.
4. Require `git show-ref --verify --quiet <canonical-ref>` to exit zero.
5. Run `git fetch --no-tags --no-write-fetch-head origin
   <canonical-ref>:<tracking-ref>`. Require a zero exit. Then require
   `git show-ref --verify --quiet <tracking-ref>` to exit zero.
6. Require `git merge-base --is-ancestor <canonical-ref> <tracking-ref>` to exit zero.
   Then run `git merge --ff-only <tracking-ref>`. A local canonical branch that is
   ahead of or diverged from its tracking ref is a refusal.
7. Read the local SHA with `git rev-parse --verify <canonical-ref>^{commit}`. Read the
   remote-tracking SHA with `git rev-parse --verify <tracking-ref>^{commit}`. Read the
   direct remote SHA with `git ls-remote --exit-code origin <canonical-ref>`; require
   exactly one `<sha><TAB><canonical-ref>` line. Require the three SHAs to be equal.
8. Repeat the branch and clean-tree checks from steps 2 and 3. Record the timestamp,
   canonical path, command exits, outputs, and equal SHA as the PRE record. PRE must
   immediately precede the non-forced remote advance attempt.

### Advance and verify

1. Require the approval verdicts named by merge step 5 and the assignment conditions
   named by synchronization step 1.
2. Require `git show-ref --verify --quiet <branch-ref>` and
   `git merge-base --is-ancestor <canonical-ref> <branch-ref>` to exit zero.
3. Read the integrated branch SHA with
   `git rev-parse --verify <branch-ref>^{commit}`. Run
   `git push origin <branch-ref>:<canonical-ref>`. Do not use a leading `+`, `--force`,
   or `--force-with-lease`. This push occurs before the local canonical branch changes.
4. Repeat the targeted fetch from synchronization step 5.
5. Require `git merge-base --is-ancestor <canonical-ref> <tracking-ref>` to exit zero.
   Run `git merge --ff-only <tracking-ref>`.
6. Repeat the branch and clean-tree checks. Repeat the three SHA reads from
   synchronization step 7 and require those SHAs to be equal. Require
   `git merge-base --is-ancestor <branch-ref> <canonical-ref>` to exit zero.
7. Record the timestamp, canonical path, command exits, outputs, equal canonical-branch
   SHA, and integrated branch SHA as the POST record. Integration is proven only when
   POST exists.

If a check fails, record the command, exit status, stdout, and stderr. Then stop. Leave
the found state visible. Do not force, reset, stash, clean, checkout, switch, or
silently repair or retry. Because the push in advance step 3 precedes every local
canonical-branch change, a rejected push leaves the local canonical branch at the PRE
SHA. A later authorized attempt starts a new ceremony and may run the ordinary
synchronization steps above.
