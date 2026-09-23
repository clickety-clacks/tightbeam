---
name: repository-retirement
description: Review repository branches, worktrees, clones, and their agent sessions for safe retention or retirement when engineering work lands, completes, or a neutral Tightbeam session-cleanup prompt arrives.
---

# Repository retirement

Use Tightbeam's generic session, assignment, custody, health, query, wake, artifact,
and attest records to coordinate this workflow. Repository meaning stays here. A
quiet-session prompt is a request for judgment, not proof that work or its session is
obsolete.

## Keep custody direct

At completion or landing, give the accountable owner one bounded retirement candidate
for the producing session. Address its exact current parent session from Tightbeam's
custody projection. An owner acts only on a direct child. Each child settles its own
direct children first and then reports upward, so the same rule covers the tree without
an ancestor bypassing an owner.

A role binding, display name, historical parent, routed prompt, silence, closed card, or
Main fallback does not transfer custody. If the recorded parent cannot act, freeze the
candidate until an accepted successor holds the cleanup duty. Do not infer a successor
or operate another session's repository on its behalf.

Identify a candidate generation by the child session, repository and worktree paths,
branch and HEAD, canonical target and observed target commit, governing work item or
assignment, and the eligibility observations and times. Give each proposed mutation a
stable action identity within that generation. Use the generation for the prompt and
its idempotency key; use the action identity for its intent and disposition receipts.
Retry the same handoff with the same key. Start a new generation when any identity or
eligibility input changes, but never use a new generation to conceal an unresolved old
action. Keep at most one pending prompt or retention wake for the same generation.
Tightbeam's existing idle-cleanup prompt is another trigger for this review, not a
second cleanup registry.

## Prove every condition

Retirement is eligible only when all of these facts are fresh and true:

- the actor has authority for this exact child and repository material;
- the promised outcome is delivered or deliberately abandoned with its remaining
  obligations accepted elsewhere;
- the candidate commit is contained in the named canonical target, or an explicit
  disposition proves the work obsolete without relying on branch names or card state;
- the worktree and index are clean, including no untracked, ignored, nested-worktree, or
  local-only material that must survive;
- no live process has its working directory, open files, locks, watchers, jobs, or other
  execution dependency in the candidate repository or worktree;
- every commit and object that must survive is present and readable from the repository's
  accepted common object store independently of the candidate worktree;
- no turn, assignment, wake, review, integration, release, recovery, or descendant duty
  still depends on the session or checkout;
- every artifact, report, trace, fixture, and recovery input has durable custody with an
  exact hash and readable destination; and
- an exact artifact-effect proof accounts for every recorded artifact path under or
  dependent on the proposed removal, and the mutation will run from a retained retirement
  workspace outside every path it may remove; and
- every applicable retention period has elapsed.

Retain active, dirty, unmerged, evidence-bound, recovery, quarantined, and ambiguous
material until its responsible owner records a disposition. A completed assignment or
remote branch is not evidence that local bytes are dispensable.

The default minimums are seven days after the latest complete eligibility proof before
pruning a worktree, thirty days after landing and the latest dependency clearance before
pruning its local branch, and final governing closure plus ninety days for canonical
archived evidence. Final governing closure means the work item and every assignment,
review, integration, release, incident, recovery, and descendant obligation governing
the material have a durable final disposition. Discovery or reopening of a dependency,
or any change to an eligibility input, invalidates the proof and resets the affected
retention clock; active or unknown time never counts. A longer repository, legal,
incident, release, or product rule wins. Use one ordinary scheduled wake for the earliest
unmet boundary when a later review is needed; a wake is only a reminder to re-read the
facts.

Before moving evidence, copy it to its accepted destination, hash and read back the
destination, record the artifact pointer, and supersede the old pointer. Only then may
the source copy become eligible. Byte identity proves preservation, not correctness.

## Retire conservatively

Before each mutation, durably record intent with the generation and action identities,
exact target and expected pre-state, fresh eligibility proof, authorized effect, and the
command or operation to be attempted. Re-read Tightbeam and Git state immediately before
acting. If either changed, do not act: record the invalidated intent and classify a new
generation. Use ordinary non-force Git operations so dirty or unmerged work refuses
removal. Remote-ref deletion, another owner's checkout, force, and broad recursive
cleanup require separate explicit authority; this workflow supplies none.

After repository material has either passed its retention boundary or been preserved
under an applicable disposition, verify that the exact child has no remaining
obligation. Retire only that session with an idempotency key derived from the candidate.
Retirement is last: it must not be the operation that discovers an inaccessible
worktree or missing evidence.

Record a completed disposition for the action identity on the governing work item,
naming the candidate generation, observations and times, canonical target commit,
preserved evidence and hashes, exact paths and refs changed, session retirement result,
and anything retained with its reason. A refusal or no-op is also a completed disposition
when it records the observed state and why no mutation occurred. Keep logical and
allocated byte counts distinct when reporting storage effects.

After interruption, restart, or a racing prompt, read the durable intent and completed
disposition for the generation and action before doing anything. Reuse an existing
completed disposition; do not repeat its action. An intent without a completed
disposition has an unknown outcome: reconcile it before retrying by comparing current
external state with its exact expected pre-state and intended effect, then record the
recovered disposition or refuse.
Never use a repeated destructive command as the existence check. Continue only a proven
uncommitted remainder under the same action identity. Conflicting receipts, changed
commits, missing paths, or unknown schema shapes are refusals to resolve with the
responsible owner, not reasons to guess or repair.
