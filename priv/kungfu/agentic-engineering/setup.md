# Setting up landing through a merge queue

This bundle works without this setup. When it is done, authors learn the
outcome of their pull requests from the landing watcher as soon as GitHub
settles them, and a branch's owner hears when a required check fails on the
branch tip. When it is skipped, nothing is lost: authors learn the outcome
through their own fallback check.

Walk the user through these steps in order. Steps 1 and 4 need someone who
can sign in to GitHub and change the repository's settings; you cannot do
those for the user. After each step, run `tightbeam kungfu setup
agentic-engineering`: it lists the watcher settings still missing and whether
the watcher is enabled. It cannot see GitHub, so confirm steps 1 and 4 with the
user.

1. Have the user sign `gh` in to the GitHub account the agents act as, using a
   gh configuration directory of its own, for example
   `GH_CONFIG_DIR=<dir> gh auth login`. That account needs to read the
   listed repositories and their pull requests and checks.

2. Tell the watcher where that login lives:

       tightbeam host-env-set --sentinel agentic-engineering/landing-watch GH_CONFIG_DIR=<dir>

3. Tell the watcher which branches to watch and which role owns each one.
   Each entry is `<owner>/<repo>@<branch>=<owner role>`; separate entries
   with spaces:

       tightbeam host-env-set --sentinel agentic-engineering/landing-watch LANDING_REPOS="<owner>/<repo>@<branch>=<owner role>"

   The owner role is the Tightbeam role woken when a required check fails
   on that branch's tip.

4. On GitHub, turn on the merge queue for each listed branch and require the
   checks that must pass before a change lands. Before enforcing the queue,
   make sure the repository's CI also runs for merge queue groups; a queue
   whose required checks never report on the group holds every change.

5. Start the watcher:

       tightbeam sentinel enable agentic-engineering/landing-watch

Tightbeam checks only that the two settings exist. If the login, a branch
entry or the repository settings are wrong, the watcher says so in its log
and exits; after repeated quick failures it stops, `tightbeam doctor` shows it
stopped, and whoever enabled it is woken. Fix the cause, then enable it again.
