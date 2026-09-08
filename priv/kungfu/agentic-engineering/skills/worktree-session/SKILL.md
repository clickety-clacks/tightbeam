---
name: worktree-session
description: Your own clone is the isolation boundary when many agents edit one repo — clone into your workdir, never adopt a repo you did not create, push so the remote holds the record, reconcile before building, never destroy work that is not yours, cleanup. Use at the start of and throughout any assignment that touches a repository.
---

# Repo session

Other agents edit the same repository at the same time. Your own clone is the isolation
boundary.

Codex exposes the engineering review commands `/review-branch` and `/review-commit`.

1. **Clone your own copy, into your own workdir.** `git clone <remote>
   <workdir>/<branch-name>`, then work on a branch named for the work. Do NOT
   `git worktree add` against a repo you did not create, and do not adopt a repo you
   found sitting on the box. A shared repo puts every agent's branches in one namespace,
   so one agent's `fetch --prune` or branch delete reaches into another's live checkout;
   and its disk belongs to a session that can retire out from under you, taking every
   checkout hanging off it. Disk is cheap. A checkout that vanishes mid-assignment is not.
2. **Push, so the remote holds the record.** Your workdir is durable; your checkout is
   not the record. Commit and push at every natural stopping point, not once at the end.
   Work that exists only in a local directory is one cleanup away from gone, and the
   agent that deletes it will not know it was yours.
3. A repo below your session root does not announce its conventions: its `AGENTS.md`
   and committed skills do not load into your session. Read them when you enter it.
4. Add `--files '["path", ...]'` when an advisory suggestion will help others
   discover where you expect the work to land. It grants no path and forbids no work.
   Reconcile real overlaps normally, and preserve work that another agent already made.
5. The Git guards permit index-only unstaging such as `git restore --staged <path>`.
   Working-tree discard and mixed index/worktree discard remain protected, as do
   other guarded destructive operations. Do not discard another agent's work.
   Read a refusal and resolve its governing restriction with the responsible owner;
   do not route around it or assume owning the clone exempts an operation.
6. A dirty tree or mid-flight branch that is not yours is not yours to reset, restore,
   or clean — and it is also not a blocker to stall on. Reconcile it: identify who or
   what created it (`git log`, the branch name, `tightbeam list` for the sessions
   around you), then either wake the owner to clean it up, or remove it yourself once
   you have established it is safe (abandoned, yours, or the owner agrees).
7. Reconcile against the authorized target and coordinate shared integration before
   landing. Verify the resulting candidate under the repository's requirements.
8. Remove a finished clone after required output is durably preserved and no
   remaining obligation needs it.
