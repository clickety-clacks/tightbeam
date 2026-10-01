# 0.1.9 artifact custody and retirement checks

Use the [fresh-base actors](README.md#fresh-base-actors), matching package and
[CLI shell](README.md#cli-shell). `test_admin` is the admin of this disposable
base; `as_actor <workdir>` carries a test session's identity. Create only
area-owned items and assignments. Record admission refusals and missing actors
as setup limits; never fabricate rows or borrow live tokens.

Rows labelled **Fresh / records** check durable operations through admitted
test actors. **Fresh / online** needs the stated real runtime or external
service. Record each prerequisite and use the [scorecard](README.md#scorecard).
A queued turn alone is not evidence of delivery or a reply. Every database
inspection uses `sqlite3 -readonly "$AREA_BASE/state.db"` and named columns.

Artifact paths name disposable test files only. This area owns producer and
revision binding and the ordinary `content_not_captured` refusal. The smoke
`artifacts` area owns the shared gate chain and per-harness real tool-observed
carrier evidence; cite those distinct results without a second review chain.
The unreachable-original-host control alone uses a contained migrated copy
and the [copied-token rules](README.md#copied-session-tokens) where needed.

| Feature | Tier | Exercise | Pass condition |
|---|---|---|---|
| <a id="producer-binding"></a>Artifact producer binding | Fresh / records | Dispatch test assignment P from an opener to holder X. As X, write a scratch file and run `artifact-record --kind report --title ... --path <file> --work-item <wi> --sha256 <its SHA-256> --produced-by-assignment <P>`. Read `artifacts --work-item <wi>`, and read-only `SELECT originHost FROM artifacts WHERE artifactId = '<A>'` for that artifact A. Repeat as X naming an assignment X does not hold, then naming P with `--work-item` set to a second test item. Run the first form as the admin through `tb` instead of a session. | The first record succeeds and the listing shows `producedByAssignmentId` equal to P, and A's `originHost` names X's host. Both wrong bindings are refused `invalid_producer` ("artifact producer must be a held assignment on the artifact work item"). The admin call is refused `invalid` ("artifact-record requires a session caller"). |
| <a id="verdict-binding"></a>Verdict bound to an artifact revision | Fresh / records | Using P and its artifact A from the row above, open review assignment R with `assign --reviews <P>` to holder Y, and wake nothing. As Y, file `attest <R> --kind verdict --verdict reviewed-clean --artifact <A> --sha256 <A's SHA-256>`. Also file the same with a different 64-hex digest, the same on a second review card that reviews another assignment, and `--verdict reviewed-clean --wait <any wake id>`. Read `attests <R>`. | The first verdict is kept with `artifactId` and `contentSha256` equal to A and its digest. The wrong digest and the other review card are refused `invalid_revision_binding` ("artifact revision must match the assignment reviewed by this review card"). `--wait` on an ordinary verdict is refused `invalid_wait_verdict`. |
| Wait verdicts | Fresh / records | On R, as Y, file `--verdict wait-verified` with no `--wait`. | Refused `wait_required`. A `wait-verified` bound to a real [dependency wait](work-routing.md#wake-delivery-options) needs that wait's verifier assignment; if the area has none, record the positive half `skipped`. |
| Uncaptured content | Fresh / records | As X, register a second ordinary test file with `artifact-record --kind report --title ... --path <file> --work-item <wi>` and no supplied digest. Run `artifact-content-fetch <id>` and `artifacts --work-item <wi>`. | Fetch returns `content_not_captured` ("artifact has no stored content"); the record names that ID, creating session and work item and has no stored digest. This refusal needs no real harness turn. The per-harness carrier result separately establishes tool-call provenance; it is not positive captured-content retrieval. |
| <a id="retirement-cleanup"></a>Retirement workspace cleanup | Contained migrated copy, conditional | Pick a copied leaf session (no child sessions, no open assignment) whose host row has an `ssh` route; containment conditions 2 and 4 already proved that route and the host's base unreachable. As its owner, run `retire --session <leaf> --key rb-retire-1 --as-user <owner>`, then the same command again. Try `retire` on the owner's Main. Read `list`. | The first call returns `deletedSessionKey` and `retiredSessionKeys` naming the leaf, `deferred`, and one `workspaceCleanup` report with `status` `incomplete`, empty `removedPaths` and `blockers` naming the unreachable host (for example `cleanup_command_failed`). The repeat replays and retries the cleanup. The Main is refused `denied`. The leaf no longer appears in `list`. |
| <a id="reachable-retirement"></a>Retirement on the recorded original host (U9) | Fresh / records; authorized reachable host | Follow [registered paths](#registered-paths) below for one test workspace containing a registered file and directory, plus an existing disposable no-artifact companion. | Cleanup reports the recorded original host/workspace truthfully; the registered file and complete directory subtree survive, the unregistered sibling disappears, and the companion workdir disappears entirely. |

Test fixture files may hold known inert bytes. Do not invent command evidence
or substitute reading the origin file for the `artifact-content-fetch` result.

## Registered paths

Use one admitted test session X with its original workdir on the authorized
reachable test host. Record its host and absolute workspace from actual spawn
and artifact readbacks. In that workspace create `registered.txt`, a directory
`registered-dir` with a child `child.txt`, and `unregistered.txt`, all with
known inert fixture text. As X, register the file and the directory separately
using `artifact-record --kind report --title <unique> --path <absolute path>
--work-item <test item>`; omit a file digest for the directory. Save both
artifact IDs, `originHost`, `originWorkspace`, paths and file/child digests.
If the current public interface refuses a directory, record that observed
failure rather than register its child instead and claim subtree coverage.

Choose an already disposable companion session N with no artifacts, no child
sessions and no open assignments; avoid another provider prompt just to
create this control. Check X also has no unresolved assignments/children. As
the authorized owner/spawner, retire X and N. On each recorded original host,
inspect only the recorded test workspace and the four known paths. Require:

- X's `workspaceCleanup` names that original host/workspace, reports
  `completed`, names both preserved artifacts and the removed unregistered
  sibling, and has no concealed blocker.
- The registered file and directory child remain with their pre-retirement
  digests, and the unregistered sibling is absent. The artifact records still
  point to their original host/workspace.
- N's cleanup reports `completed` and its entire original workdir is absent.

A same-spelled path on the gateway host is not evidence of satellite cleanup.
If the original host cannot be inspected, record the verification half
`INCOMPLETE` and the truthful returned cleanup status; do not report removed
files as observed. Preserve registered artifact custody after the check.
Symlink races, path containment, timeout and retry matrices stay in
`test/artifacts_test.exs`, `test/retire_ownership_test.exs` and the retirement
cases of `test/gateway_test.exs`.
