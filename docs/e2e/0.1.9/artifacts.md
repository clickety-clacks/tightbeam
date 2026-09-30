# 0.1.9 artifact custody and retirement checks

Offline rows run on a new copy of the migrated result
([reuse the result](migration.md#reuse-the-result)) inside the verified
[containment](README.md#containment) boundary, from the
[CLI shell](README.md#cli-shell). A copied session acts through
[`as_session`](README.md#copied-session-tokens), which stops unless a recorded
ruling permits copied-token use; without it, record each row that acts as a
copied session `INCOMPLETE: copied-token use not ruled`. An admin acts through
`tb ... --as-user "$test_admin"`:

```sh
test_admin="$(sqlite3 -readonly "${AREA_BASE:?}/state.db" "SELECT userId FROM users WHERE isAdmin = 1 ORDER BY userId LIMIT 1")"
```

Create this area's own test work items and assignments, and pick copied active
sessions with the same owner as their actors. Artifact paths name disposable
files in scratch; never record a path from the copied org, and keep file
content out of the scorecard.

Online rows run on a fresh empty base under the [online tier](README.md#tiers)
and are labelled "fresh-base feature evidence, not proof on migrated state".
The feature smoke's `artifacts` area ([feature smoke](README.md#feature-smoke),
online only) checks artifact-backed rule gates and the uncaptured-content
result on an artifact a real turn records.

| Feature | Tier | Exercise | Pass condition |
|---|---|---|---|
| <a id="producer-binding"></a>Artifact producer binding | Offline | Dispatch test assignment P from an opener to holder X. As X, write a scratch file and run `artifact-record --kind report --title ... --path <file> --work-item <wi> --sha256 <its SHA-256> --produced-by-assignment <P>`. Read `artifacts --work-item <wi>`, and read-only `SELECT originHost FROM artifacts WHERE artifactId = '<A>'` for that artifact A. Repeat as X naming an assignment X does not hold, then naming P with `--work-item` set to a second test item. Run the first form as the admin through `tb` instead of a session. | The first record succeeds and the listing shows `producedByAssignmentId` equal to P, and A's `originHost` names X's host. Both wrong bindings are refused `invalid_producer` ("artifact producer must be a held assignment on the artifact work item"). The admin call is refused `invalid` ("artifact-record requires a session caller"). |
| <a id="verdict-binding"></a>Verdict bound to an artifact revision | Offline | Using P and its artifact A from the row above, open review assignment R with `assign --reviews <P>` to holder Y, and wake nothing. As Y, file `attest <R> --kind verdict --verdict reviewed-clean --artifact <A> --sha256 <A's SHA-256>`. Also file the same with a different 64-hex digest, the same on a second review card that reviews another assignment, `--kind progress` with the artifact pair, and `--verdict reviewed-clean --wait <any wake id>`. Read `attests <R>`. | The first verdict is kept with `artifactId` and `contentSha256` equal to A and its digest. The wrong digest and the other review card are refused `invalid_revision_binding` ("artifact revision must match the assignment reviewed by this review card"). The progress form is refused by the CLI before any request. `--wait` on an ordinary verdict is refused `invalid_wait_verdict`. |
| Wait verdicts | Offline | On R, as Y, file `--verdict wait-verified` with no `--wait`. | Refused `wait_required`. A `wait-verified` bound to a real [dependency wait](work-routing.md#wake-delivery-options) needs that wait's verifier assignment; if the area has none, record the positive half `skipped`. |
| Uncaptured content | Online | Run the smoke's `artifacts` area. It has a real turn record its report with `artifact-record`, then calls `artifact-content-fetch <id>` and reads the record through the gateway's `artifact-get`. | The fetch returns `content_not_captured` ("artifact has no stored content"). The record names the same ID, kind, creating session, work item and turn evidence, with no stored digest. This checks the uncaptured result only; 0.1.9 has no capture path to test positive retrieval. |
| <a id="retirement-cleanup"></a>Retirement workspace cleanup | Offline | Pick a copied leaf session (no child sessions, no open assignment) whose host row has an `ssh` route; containment conditions 2 and 4 already proved that route and the host's base unreachable. As its owner, run `retire --session <leaf> --key rb-retire-1 --as-user <owner>`, then the same command again. Try `retire` on the owner's Main. Read `list`. | The first call returns `deletedSessionKey` and `retiredSessionKeys` naming the leaf, `deferred`, and one `workspaceCleanup` report with `status` `incomplete`, empty `removedPaths` and `blockers` naming the unreachable host (for example `cleanup_command_failed`). The repeat replays and retries the cleanup. The Main is refused `denied`. The leaf no longer appears in `list`. |
| Retirement cleanup on a reachable host | Online | On a fresh base, spawn a test session, record an artifact from its workdir with `artifact-record`, write a second scratch file there, and retire it. | `workspaceCleanup` reports `completed`, `removedPaths` covers the scratch file, and `preservedArtifacts` names the recorded artifact, whose file is still present. |

Do not hand-write report bytes, claim output a command did not produce, or read
an origin path in place of `artifact-content-fetch`.
