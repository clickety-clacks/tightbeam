# Contributing — lines, branches, releases

Two lines exist. They are not directly concerned with each other.

| Line | Branch(es) | Owner | Process |
|---|---|---|---|
| **0.2** | `main` | the 0.2 orchestrator (tb02) | no door: run the verification gates (AGENTS.md), record baseline+after counts, review evidence in the specs repo first, push main directly. CI-on-push is the tripwire. |
| **0.1** | `0.1.N` per version | the Tightbeam product owner | per-version branches + build numbers, below. |

A fix crosses lines by **cherry-pick election only**, Mike-authorized — never
automatically, and never as a blind pick into re-legislated code. If your
assignment card names an integration branch, the card wins.

## The 0.1 release model (ruled 2026-08-15)

**One living branch per version.** `0.1.9` is the active scratchpad: work meant
for the 0.1 line lands there as it comes — scope is organic, no predetermined
merge list. It is *moving code* until Mike calls quits.

**Build numbers identify bytes.** Every build is `<version> build <N>`, with
`N = git rev-list --count HEAD` — deterministic, reproducible from any
checkout, no counter service (semver form: `0.1.9+N`). "Which 0.1.9 are you
running?" is answered by the build number, never by the branch name.

**Calling quits.** The last build *is* the release:

1. Tag `v0.1.9` at the branch tip — the immutable, byte-exact name that
   installs and support use. The CI proof (gates on both platforms, packages
   built and hashed, manifest verified) runs at that SHA.
2. Spin `0.1.10` from the tip. It is the new scratchpad, effective
   immediately.
3. `0.1.9` never moves again. Freeze is by abandonment, identity is the tag.

**Never push to a version branch after its tag exists.** If a released version
needs a fix, that fix lands on the current scratchpad; shipping it is a new
version. (History: a frozen candidate branch was pushed to on 2026-08-15 and
had to be discarded — receipts you can write to are traps, which is why the
old `release-candidate/*` mechanism was retired along with the `0.1.x` series
branch.)

**Automation names the line by glob, not by name.** CI triggers and branch
protection match `0.1.*`; anything needing "the active 0.1 branch" resolves
the highest version numerically. Nothing churns when a new branch spins.

## Which branch do I touch?

- 0.2 work → `main`, through the gates.
- 0.1 work → the highest `0.1.*` branch, through the product owner's lane.
- A released tag needs a change → it doesn't; the scratchpad does.
- Unsure → it goes to the line's owner as a work item, not to git.
