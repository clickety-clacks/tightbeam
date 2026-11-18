---
name: landing
description: Own a branch or carry a reviewed change through its authorized PR and merge queue, recording settlement and recovering failures.
---

# Landing on a shared branch

Land through the route the repository and your work
agreement authorize for its target. Where
the target takes changes through pull requests, the repository merges each one
once its required checks pass. Where it also has a merge queue, the queue tests
each change with what is ahead of it on the tip about to exist and merges in
arrival order, so the commit that was reviewed is the commit that lands. A
refused merge request is not permission to land another way.

## Delivery destination and watcher coverage

The opener of a code assignment follows its completion through observed landing
and records the destination; a returned result is not proof that it landed.
Carry reviewed work through the authorized PR and queue route below. If the work
item declares local-only delivery, it names the clone and branch, merge target
and readback; merge there through that agreement and record the observed target
head. Do not infer local-only delivery from a private checkout.

For a new project or target branch, its PDO makes sure the landing watcher is set up, using the bundle's setup instructions from tightbeam kungfu setup agentic-engineering. The watcher follows a pull request or branch once an agent waits on its landing; listing the branch in LANDING_REPOS only adds standing alerts when its required checks fail. If the watcher is not set up or not running, use a bounded timed check of the actual PR or branch instead of waiting on a watcher fact that will not arrive. Follow the operating manual's record-wait preference and bounded fallback for real waits.

## Waiting on PR checks

Where a landing watcher supplies `pr.checks-completed`, end your turn with a
wake on that fact when waiting on an open, unqueued PR's required checks, whether
as its author or the coordinator who owns its review. Scope it to
`<owner>/<repo>#<n>` so the result reaches you without holding a turn open or
losing the news. This route requires that fact producer; a subscription alone
does not create it:

    tightbeam wake --role <your role> --when-fact pr.checks-completed \
      --when-scope <owner>/<repo>#<n> --fallback-after 3h \
      --prompt "Read PR <n>'s current checks and act on their result"

The fact reports that checks finished, on pass or fail; read the latest required
results for the current head. The coordinator who owns review decides when to
open it; review need not wait for green checks. Coders do not open their own
review. A fallback is a reason to read the current state, not evidence that
checks passed.

## Landing your own change

Open the pull request from your branch to the authorized target. Public PRs
contain product terms and verification evidence; keep internal Tightbeam IDs
only in Tightbeam records linked to the public PR or commit URL. Record the PR
on your assignment. Where the target's watcher supplies landing facts, subscribe
to the outcome before requesting the merge, so the fact cannot arrive before
you are listening. Write the scope with the owner and repository in lowercase:

    tightbeam wake --role <your role> --when-fact landing.settled \
      --when-scope <owner>/<repo>#<n> --fallback-after 3h \
      --prompt "PR <n> settled or silent: read it and finish landing <assignment>"

Then request the merge with the reviewed commit pinned:

    gh pr merge <n> --auto --merge --match-head-commit <reviewed sha>

The pin is checked when GitHub accepts the request; it does not stop later
pushes. If the request fails, deal with the failure and cancel the subscription
you no longer need.

The landing watcher, a service that reads GitHub and files landing facts, files
`landing.settled` where one runs. It means the pull request stopped moving on
its own: merged, removed from the queue, auto-merge disabled, blocked by a
failed required check, or closed. The fallback means only that nothing arrived
in time; it is a reason to read, not a finding. Either way, read the pull
request and act on what is true now.

Merged: compare the merged head with the commit that was reviewed. If they
differ, take the difference to your delivery owner before completing. If they
match, record the landing, then complete under the usual rules with the merge
commit read from the pull request as the delivered commit.

    tightbeam attest <assignment> --kind verdict --verdict landed \
      --note "<owner>/<repo> <branch> PR <n> reviewed <head sha> merged <merge sha>"

Removed, disabled, blocked or closed: find out why before resubmitting. A
conflict or a failure your change caused is yours to fix, and the fix goes back
through review when it changes what was reviewed. A failure that was not your
change's can be resubmitted once you have looked. A failure that keeps
recurring is a defect in the branch: name it to your delivery owner so it gets
an owner.

When a watcher subscription's fallback fires, subscribe again before rereading
the pull request, so settlement cannot race through the gap between the read and the next
subscription. Keep the replacement subscription if the pull request is still
open and moving; cancel it if the reread shows that it already settled. Handing
over the assignment hands over the pull request. Whoever takes it arranges the
applicable fact wait or timed check, then reads the pull request, since it may
already have settled.

## Owning a branch

Arrival order is the default landing order. Move a change forward when priority
calls for it, and hold changes when the branch needs to settle first. To hold a
queued change, dequeue it; turning off auto-merge does not remove a change that
is already queued. Read the pull request afterwards, and report a change that
merged before the hold took effect. A red tip is yours to resolve; where the
landing watcher runs, it wakes the branch's owner role when a required check
fails on the tip. Get the tip green before more work builds on it. A failing check you
believe should not exist goes to its owner, without holding unrelated work on it. A queue that stops
moving shows up in your own reads, not as a signal. Commission an integrator
when reconciling changes from different sources is a job in itself.

Bypassing the branch rules is the user's decision, made for that occasion on the
user's direct instruction.
