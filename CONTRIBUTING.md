# Contributing — lines, branches, releases

Two lines exist. They are not directly concerned with each other.

| Line | Authorized branch targets | Owner | Process |
|---|---|---|---|
| **0.2** | `main` or `0.2.0`, only when the work card names it | the Tightbeam product owner | run the verification gates in AGENTS.md, record baseline and after counts, and land review evidence in the specs repo before integration. |
| **0.1** | `0.1.9`, only for work explicitly targeted to active 0.1 maintenance | the Tightbeam product owner | route through the product owner, then use the per-version branch and build-number process below. |

A branch's existence never supplies a target. Work without an explicit target
stays untargeted. Do not select the highest branch, infer a target from the
repository, or inherit a target from nearby work.

A change crosses lines only through an explicit Mike election that names the
source and target. Never propagate it automatically or blindly apply it to
re-legislated code.

## The 0.1 release model (corrected 2026-08-26)

**`0.1.8` is locked.** No new work targets it. The remote `0.1.8` branch and
the published `v0.1.8+1334` release both identify
`2ff4ed2a93527f1a7eeb56f2b9a8c52f10368ab5`. Do not modify that branch or
move that tag.

**`0.1.9` is the active 0.1 scratchpad.** Its current remote tip is moving
code, not a default target. Only work explicitly targeted to active 0.1
maintenance goes there, through the Tightbeam product owner. All other work
stays untargeted unless its card names an authorized branch.

**Build numbers identify bytes.** Every build is `<version> build <N>`, with
`N = git rev-list --count HEAD` — deterministic, reproducible from any
checkout, no counter service (semver form: `0.1.9+N`). "Which 0.1.9 are you
running?" is answered by the build number, never by the branch name.

**A release branch evolves until it passes (ruled 2026-08-16).** Release
testing runs against the branch's builds, and every defect it finds lands its
fix ON THE SAME BRANCH as a new build — then testing re-runs against the
evolving branch. The loop continues until the branch tests clean. Passing is
what earns quits; quits is never declared over a failing branch. While a
version is still testing, its successor stays empty — and if something lands
on the successor prematurely, merge it back into the testing branch and keep
evolving. ("We evolve a release branch until it passes.")

**Calling quits.** Quits happens when the branch tests clean; the last
(passing) build *is* the release:

1. Tag `v<current>+<build>` at the branch tip — for example,
   `v0.1.8+1325`. The version and deterministic build number together are the
   immutable, byte-exact name that installs and support use. The CI proof
   (gates on both platforms, packages built and hashed, manifest verified)
   runs at that SHA.
2. Mike can spin the next version from the tip. The new branch does not target
   any work merely because it exists. Each work card needs explicit routing.
3. `<current>` never moves again. Freeze is by abandonment, identity is the
   tag.

   Written with placeholders deliberately: a branch name in this procedure is
   never authorization to target work there.

**Never push to a version branch after quits.** The tag is minted at quits —
after the branch passes — so a tag and further pushes cannot coexist. The
locked `0.1.8` branch and published `v0.1.8+1334` release are the current
example: both identify the same immutable commit. A tag name used by a GitHub Release
remains unavailable even if that release and tag are deleted. Never publish
the release before quits. If a released version needs a fix, create a new work
item and route it explicitly to active maintenance; never reopen the released
branch. (History: a frozen candidate branch was pushed to on 2026-08-15 and
had to be discarded — receipts you can write to are traps, which is why the
old `release-candidate/*` mechanism was retired along with the `0.1.x` series
branch.)

**Automation can observe a line but cannot choose a work target.** CI triggers
and branch protection can match `0.1.*`. Work routing must read the explicit
target from the card. It must never resolve the highest version or infer from
which branches exist.

## Which branch do I touch?

- New work never targets `0.1.8`.
- Explicit active 0.1 maintenance → `0.1.9`, through the product owner.
- Explicit 0.2 work → `main` or `0.2.0`, only when the card names it.
- Work without a target → keep it untargeted and take it to the product owner.
- A cross-line change → wait for Mike's explicit election.
