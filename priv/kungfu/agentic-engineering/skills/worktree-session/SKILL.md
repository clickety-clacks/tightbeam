---
name: worktree-session
description: Your own clone is the isolation boundary when many agents edit one repo — clone into your workdir, never adopt a repo you did not create, push so the remote holds the record, reconcile before building, never destroy work that is not yours, cleanup. Use at the start of and throughout any assignment that touches a repository.
---

# Repo session

Other agents edit the same repository at the same time. Your own clone is the isolation
boundary.

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
5. Destructive git that hides or discards another agent's uncommitted work is refused
   at the gate before it runs — `git stash` (mutating forms), `git reset --hard`,
   forced `git clean`, `git checkout -- <path>`, and `git restore` all hit a refusal
   with the reason attached. Do not route around a refusal; it is protecting a
   colleague's work. To undo your OWN uncommitted edit, reverse the edit itself. In
   your own clone this matters less than it used to, but the gate does not know whose
   tree it is looking at, so the refusal still fires.
6. A dirty tree or mid-flight branch that is not yours is not yours to reset, restore,
   or clean — and it is also not a blocker to stall on. Reconcile it: identify who or
   what created it (`git log`, the branch name, `tightbeam list` for the sessions
   around you), then either wake the owner to clean it up, or remove it yourself once
   you have established it is safe (abandoned, yours, or the owner agrees).
7. Reconcile main into your branch before building on it: merge main in, resolve
   conflicts on your branch, and prove the combined result builds and passes tests
   there. Do not build new work on a branch that has diverged from main.
8. After your branch merges, delete your clone. A finished assignment leaves no
   checkout behind; attest the cleanup as part of completion. Deleting your own clone
   is safe precisely because it is yours and its commits are already on the remote.
