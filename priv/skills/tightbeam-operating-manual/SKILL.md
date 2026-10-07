---
name: tightbeam-operating-manual
description: Resolve uncommon Tightbeam custody, failure, wait, ruling or identity questions beyond the substrate core.
---

# Operating manual: uncommon cases

## Unclassified harness failure

Record one redacted `other` observation when evidence matches no known class.
Use observedState, exactProbe, outputDigest or exactError, bounded validUntil,
worldStatus (`PROVEN` or `UNKNOWN`), recoveryCondition and notKnownClassReason,
with the required description/digests and redaction confirmation. Read
`tightbeam harness-health-observe-other --help` for exact fields. Do not invent a
probe or promote an unknown cause to proven. The incident pauses prodding for
that harness, routes for review and expires. Recovery needs matching description
and recovery-condition digests plus observed successful recovery; an ordinary
success without that evidence is insufficient. A recurrent description may need
its own classified mechanism, outside this record's authority.

## Predicate and dependency waits

For a row dependency, link the resolving assignment or decision and use
`wake --session <key> --assignment <id> --predicate '<JSON>' --fallback-after
<duration> --prompt "<dependent action>"`. Name conditions, bindings, resolverRef,
declared necessity and verificationRef. Coverage is provisional until its named
verifier checks necessity; a challenge ends it. Only a qualifying unresolved wait
pauses the effort horizon. Read the current disposition before acting. An
after-turn continuation covers only its named obligation, not unrelated work.

## Ending a cannot-proceed block

`cannot-proceed` retains custody and raises one decision to the opener. A reply
alone does not release the block: its named release fact must arrive, or the
opener must dispose of the obligation through the supported seam. Read the
assignment's actual state and the requested release evidence before resuming.
Do not file completion for unfulfilled work or treat a wake as the release.

## Delegated rulings

A presenter's recommendation is its opinion, not the user's ruling. A presenter
runs `operator-rule` only after the user explicitly delegates that act in the
same exchange with an unambiguous outcome; `--rationale` quotes the delegation.
A non-presenting relay needs an explicit instruction naming the `dr_` id. Main
does not infer authority to rule with `--as-user`. A Main wake is an opportunity
to act under its own role, not an instruction to decide for the user.

## Disputed source identity

Hash the exact bytes at both locations. Matching hashes settle identity and end
that comparison; paths, labels and memories are not contrary byte evidence.
Identity still does not establish correctness.

## Custody archaeology

Read holder and opener in `assignments`, current role bindings and `spawnedBy` in
`list`, and the item's assignment/attest history. They answer different questions:
who owes the outcome, who commissioned it, where an office is addressed and who
spawned the session. A role change does not transfer an open obligation.

## Helpers and staff

A harness subagent is your helper, not an org session. Its report creates no
Tightbeam assignment, review custody or independent staffed office. You retain
responsibility for adopted output and its evidence; a subsequent accepted handoff
is not inferred reparenting. Use actual sessions for commissioned org responsibilities.

## Identity changes

Read `tightbeam identity --help` and `identity status`; use the supported edit,
manifest and skill seams. Load `tightbeam-skills` for library changes. Authored
source, published identity and a session's received revision are separate facts.
Apply only within authority at safe boundaries, read back results and preserve
refusals. Relearn/install is not implied by a prose edit.

## Relearn after an upgrade

When the user asks to refresh learned kungfu, read `tightbeam identity --help`
and `tightbeam identity status`. Explain that one `tightbeam identity relearn`
imports the installed version of every learned kungfu and merges it with the
user's identity. Run it when the user chooses; do not run a trial relearn.
If it reports conflicts, inspect each named path and compare the installed
0.1.9 bundle's text with the user's current text. Each reported path is under
`<base_dir>/identity/`. For each conflict, tell the user why the two changes
collide, what the 0.1.9 version intends, and what their version does. Let the
user choose the resulting text. Write that choice to the conflicted path and
stage it with `git -C <base_dir>/identity add -A -- <path>`; `identity edit`
cannot resolve a merge in progress. Repeat for every conflicted path. Only
when no unmerged path remains, run `tightbeam identity relearn --resolve` and
read `identity status` to verify the live revision. If the user does not want
to settle every conflict now, use `tightbeam identity relearn --abort`; a
partial merge cannot be published. Never silently prefer either version.

Before refreshing sessions, explain that `tightbeam identity apply --all`
updates their Tightbeam-owned skill files and asks them to re-read, without
reloading their current model context, and obtain the user's confirmation.
After relearn (or `relearn --resolve`) publishes the merged identity, run
`tightbeam identity apply --all` at a boundary that does not interrupt running
turns, then read `tightbeam identity status`. Do not call the relearn done while
any session you are responsible for remains stale.

## Repeated effort requests

Compare the specific obligation's records, actual execution and current pending
wakes. Activity elsewhere in a shared session is not its progress. If supervision
contradicts coverage, record one specimen and route the defect to its owner; keep
the next action and reassessment explicit. Dismissing a request merely to quiet it
can restart the cycle. Containment is not recovery. Do not manufacture activity.
