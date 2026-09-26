# Landing on a shared branch

Land through the route the repository and your work
agreement authorize for its target. Where
the target takes changes through pull requests, the repository merges each one
once its required checks pass. Where it also has a merge queue, the queue tests
each change with what is ahead of it on the tip about to exist and merges in
arrival order, so the commit that was reviewed is the commit that lands. A
refused merge request is not permission to land another way.

## Landing your own change

Open the pull request from your branch to the authorized target, with
`Tightbeam-Assignment: <assignment>` and `Tightbeam-Work-Item: <work item>` in
its body, and record the pull request on your assignment. Subscribe to the
outcome before you request the merge, so the fact cannot arrive before you are
listening. Write the scope with the owner and repository in lowercase:

    tightbeam wake --role <your role> --when-fact landing.settled \
      --when-scope <owner>/<repo>#<n> --fallback-after 2h \
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

When the fallback fires, subscribe again before rereading the pull request, so
settlement cannot race through the gap between the read and the next
subscription. Keep the replacement subscription if the pull request is still
open and moving; cancel it if the reread shows that it already settled. Handing
over the assignment hands over the pull request. Whoever takes it subscribes,
then reads the pull request, since it may already have settled.

## Owning a branch

Arrival order is the default landing order. Move a change forward when priority
calls for it, and hold changes when the branch needs to settle first. To hold a
queued change, dequeue it; turning off auto-merge does not remove a change that
is already queued. Read the pull request afterwards, and report a change that
merged before the hold took effect. A red tip is yours to resolve; where the
landing watcher runs, it wakes the branch's owner role when a required check
fails on the tip. Get the tip green before more work builds on it. A queue that
stops moving shows up in your own reads, not as a signal. Commission an
integrator when reconciling changes from different sources is a job in itself.

Bypassing the branch rules is the user's decision, made for that occasion on the
user's direct instruction.
