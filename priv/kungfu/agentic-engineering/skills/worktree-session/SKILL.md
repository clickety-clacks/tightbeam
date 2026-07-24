---
name: worktree-session
description: The worktree is the isolation boundary when many agents edit one repo — your own branch, declared files, reconcile before building, never destroy work that is not yours, cleanup. Use at the start of and throughout any assignment that touches a repository.
---

# Worktree session

Other agents edit the same repository at the same time. The worktree is the isolation
boundary.

1. Do your own work only in your own worktree, on your own branch. Create the worktree
   at the start of the assignment; its branch is named for the work.
2. Declare the files your goal touches on the assignment (`--files '["path", ...]'`).
   The substrate refuses to open a second assignment that overlaps an open assignment's
   declared paths, so two coders cannot be aimed at the same file — the declaration is
   how the substrate keeps you from colliding, not just etiquette. If your goal grows
   to need a path another open assignment already holds, that overlap is a real block:
   surface it, do not reach into their file.
3. Destructive git that hides or discards another agent's uncommitted work is refused
   at the gate before it runs — `git stash` (mutating forms), `git reset --hard`,
   forced `git clean`, `git checkout -- <path>`, and `git restore` all hit a refusal
   with the reason attached. Do not route around a refusal; it is protecting a
   colleague's work. To undo your OWN uncommitted edit, reverse the edit itself — the
   same tree can hold work that is not yours.
4. A dirty tree or mid-flight branch that is not yours is not yours to reset, restore,
   or clean — and it is also not a blocker to stall on. Reconcile it: identify who or
   what created it (`git log`, the branch name, `tightbeam list` for the sessions
   around you), then either wake the owner to clean it up, or remove it yourself once
   you have established it is safe (abandoned, yours, or the owner agrees).
5. Reconcile main into your branch before building on it: merge main in, resolve
   conflicts on your branch, and prove the combined result builds and passes tests
   there. Do not build new work on a branch that has diverged from main.
6. After your branch merges, prune your worktree and delete the merged branch. A
   finished assignment leaves no worktree behind; attest the cleanup as part of
   completion.
