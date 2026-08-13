---
name: base-synchronization
description: Synchronize and prove the declared source base before a new implementation pass or review rework. Use before the first goal edit of either pass, when declaring its base, or when reviewing its gate evidence.
---

# Base synchronization

Run this gate before the first goal edit of every source-changing assignment. Run a
fresh gate after each durable `changes-requested` verdict and before the first edit
that answers it. Fetching, integrating, and resolving integration conflicts are gate
operations. Implementation and review-finding edits are not. Only a `released`
outcome permits goal edits.

Do not use this procedure as final integration proof, final verification, a
`tests-passed` receipt, or a review-card lifecycle. The `feature-cycle` skill alone
owns review commissioning and completion. The `committing-and-pushing` skill owns
final integration.

## Identify the pass and principals

Use `new:<assignment-id>` as the first pass's gate ID. Use
`rework:<changes-requested-attest-id>` after a blocking review verdict. Number attempts
from 1 within a gate ID and preserve every failed attempt.

Read the worker assignment and work item from Tightbeam. The assignment's current
full `holderKey` is the worker session. The assignment's `openedBySession` or
`openedByUser` is the assignment opener. The work item's `ownerUserId` is the
work-item owner user. A role label does not grant any of these authorities.

The assignment opener or work-item owner user declares the integration base. The
worker runs and records the gate. The reviewer checks the latest pass's gate against
the reviewed commit. A later custody change does not let a new holder adopt or rewrite
an earlier session's incomplete attempt.

## Follow the state machine

Move through these states in order:

1. `pass-entered`: record the gate ID, attempt, worker session, worktree ownership,
   worker branch, and exact cleanliness preflight.
2. `awaiting-base-declaration`: select and bind one authorized declaration. If none is
   valid, record `blocked-base-declaration` and ask the opener.
3. `resolving-base`: obtain one full immutable required revision. A transport,
   credential, object, or ref failure records `blocked-base-unavailable`; never use a
   cached moving ref after a failed fetch.
4. `integrating`: prove the revision is already present or apply the
   repository-authorized integration method on the worker branch.
5. `resolving-conflicts`: resolve compatible conflicts and record paths and resolution
   revisions. Incompatible authorities record `blocked-conflict`; the opener obtains
   a canonical spec-writer or product-owner ruling.
6. `testing-synchronized-baseline`: run the relevant repository test set before goal
   edits. An unavailable set records `blocked-test-unavailable`. Classify red results
   under the rules below.
7. `recording-evidence`: write and hash the observation report, record one `data`
   artifact, validate its returned row, then file the fixed-shape outcome attest.
8. `released`: permit goal edits only when a valid outcome attest says `released`.

Keep blocked work, worktrees, reports, artifacts, and attests. Resume a cleared cause
with the next attempt number. Never overwrite or amend an attempt.

## Bind an authorized base declaration

The opener must create a source-changing assignment, record or obtain its authorized
declaration, then wake the worker. Atomic `dispatch` cannot insert the declaration;
use `assign`, the declaration, then `wake`.

File a `base-declared` verdict with exactly one of these note shapes:

```text
INTEGRATION_BASE_V1 {"repo":"<host:absolute-path>","kind":"moving","ref":"<remote-or-local-ref>","pin":null,"authority":"<authority>"}
INTEGRATION_BASE_V1 {"repo":"<host:absolute-path>","kind":"pinned","ref":null,"pin":"<full-commit>","authority":"<authority>"}
INTEGRATION_BASE_V1 {"repo":"<host:absolute-path>","kind":"pinned","ref":"<authorized-fetch-ref>","pin":"<full-commit>","authority":"<authority>"}
INTEGRATION_BASE_V1 {"repo":"<non-git-source-id>","kind":"non-git","ref":"<declared-line>","pin":null,"authority":"<authority>"}
INTEGRATION_BASE_V1 {"repo":"<snapshot-source-id>","kind":"non-git","ref":null,"pin":"<immutable-revision-or-snapshot-sha256>","authority":"<authority>"}
```

Use this command:

```text
tightbeam attest <worker-assignment> --kind verdict --verdict base-declared --note "<INTEGRATION_BASE_V1 note>"
```

An opener's `authority` cites the assignment ID or exact live repository
`path:line`. An owner user's authority is
`work-item:<work-item-id>:ownerUserId`, and the attest's user author must equal that
durable field. A source-snapshot declaration instead cites its authorized exception
attest.

Select declarations by this precedence:

1. A declaration that matches an exact live repository parent, release, or
   integration target.
2. A work-item owner user's exact base or pin that does not contradict live policy.
3. The opener's declaration that cites the assignment and does not contradict live
   policy.
4. No base; block and ask the opener.

Within one level, bind the latest authorized declaration observed when leaving
`awaiting-base-declaration`. A correction filed later controls the next attempt or
pass, not the bound attempt. For a stacked branch, declare the immediate committed
parent. Do not infer a familiar default branch.

## Prove a clean worker worktree

Run this exact Git preflight without a wrapper that changes stdout:

```text
git status --porcelain=v1 --untracked-files=all
```

Map exit 0 with zero stdout bytes to `clean`, exit 0 with any stdout bytes to `dirty`,
and nonzero or failure to start to `error`. Retain only the exact command, exit, and
category. Retain no status byte, path, byte count, encoding, hash, fingerprint, or
stderr. Only `clean` permits integration. Map `dirty` to
`{"event":"worktree-not-clean","reason":"preflight-dirty"}` and `error` to
`{"event":"worktree-not-clean","reason":"preflight-error"}`.

For non-Git source control, use only a policy-named exact status command and its
deterministic clean/dirty predicate. If policy supplies no predicate, record `error`
and block. Preserve work owned by another principal; never reset, restore, clean,
stash, overwrite, or commit it.

## Obtain the current required revision

For a remote moving Git ref, run the approved authenticated fetch for that exact ref.
Resolve that fetch's `FETCH_HEAD` or exact written destination to a full commit. The
successful fetch is the observation event. Do not resolve an unchanged tracking ref
after a failed fetch.

For a local stacked ref, resolve its committed tip once and verify that ref in the
shared object database. For a pin, verify that the exact object is a commit; fetch the
object or its authorized ref only when absent. A locally present pin needs no network
call unless its declaration requires remote attestation.

For non-Git source control, run the repository command that obtains the declared line
and immutable revision. Record only schema-authorized command facts, not process
streams.

## Integrate without destroying work

Repository policy chooses merge or rebase. When policy is silent, merge. Rebase only
when policy permits it and the worker alone owns an unpublished branch. Never rewrite
a shared or published branch.

Record `worker_head_before`. If the required commit is already present, run:

```text
git merge-base --is-ancestor <required-commit> HEAD
```

On exit 0, record `integration_method=none`,
`integration_result=already-current`, and equal pre- and post-head revisions. Create
no empty commit. Otherwise record the exact merge, rebase, update, snapshot, and
post-operation inclusion commands in execution order. The post-head must contain the
required revision.

Before resolving a textual conflict, record its original paths. Read the merge base,
both sides, callers, tests, and cited authorities. Combine compatible requirements and
record resolution revisions. Treat a synchronized-baseline failure that appears only
on the combined branch as a semantic conflict unless it qualifies as exact
`review-target-red` or proved `base-originated` red. Make only the reconciliation edit
needed to preserve compatible authority. When authorities are incompatible, block;
do not choose a side.

## Run and classify the synchronized baseline

Select tests before running them from repository policy, assignment files and effect,
conflict paths, and the exact failing command named by a triggering review verdict.
Do not narrow the set after a failure. If no command exercises the effect, or a
required environment prevents a command from starting, record
`blocked-test-unavailable`, a concise non-secret category, and the opener as next
principal.

For every test entry, retain exactly `command`, `revision`, `environment`, `exit`,
`result`, and `classification`. The command is its exact repository identity before
credential or runner expansion. The environment is a non-secret lane qualifier or
`null`. Exit 0 means `passed`; nonzero means `failed`. Never persist, encode,
sanitize, hash, fingerprint, or reconstruct stdout or stderr. Do not persist a
credential, credential-bearing URL, expanded credential argument, or unrestricted
environment dump. Run repository-required credentialed tests normally when authorized
credentials work.

On a rework pass, classify red as `review-target-red` only when the triggering verdict
identifies the reviewed commit, safe command identity, and exit; `worker_head_before`
equals that commit; an isolated checkout of it and the synchronized baseline reproduce
the same command and exit; and the synchronized run adds no failing command or changed
target exit. Release with `test_result=review-target-red` only when every red result
meets those conditions.

For remaining red, run the same command on a clean checkout of the required revision.
If it does not reproduce, resolve it as a worker-branch or integration conflict. If it
reproduces, classify it `base-originated`. Keep that gate blocked unless an exact live
repository directive already accepts that command and exit at that revision or the
work-item owner user files `baseline-red-accepted` for the blocked attempt.

The owner-user exception uses this exact note:

```text
BASE_RED_EXCEPTION_V1 {"gate_id":"<gate-id>","required_revision":"<full-revision>","failure_artifact_id":"<blocked-attempt-artifact-id>","failure_artifact_sha256":"<hex>","reason":"<why-the-assignment-remains-valid>","principal":"user:<ownerUserId>","overrides_policy":null}
```

Set `overrides_policy` to exact `path:line` when overriding a green-baseline
directive; otherwise use JSON `null`. The exception expires with its gate ID and must
cover every base-originated failure. It cannot waive base identity, work preservation,
conflict resolution, evidence, or review.

## Write the observation report

Write one UTF-8 JSON object with a final newline. Use every top-level field below;
omit none. Object-key order and insignificant whitespace are not normative. Array
order is execution or path order. The report records observations that exist before
artifact recording; it does not record the attempt outcome.

```json
{
  "schema": "BASE_SYNC_V1",
  "gate_id": "new:asg_example",
  "attempt": 1,
  "assignment_id": "asg_example",
  "work_item_id": "wi_example",
  "worker_session": "agent:main:example s_example",
  "pass_kind": "new",
  "trigger_attest_id": null,
  "observed_at": "2026-08-12T07:37:55Z",
  "repo": "host:/absolute/repository",
  "worker_branch": "coder/example",
  "worker_head_before": "full-revision",
  "preflight": [
    {"command": "git status --porcelain=v1 --untracked-files=all", "exit": 0, "result": "clean"}
  ],
  "base_declaration_attest_id": "att_example",
  "base_principal": "session:agent:orchestrator:example s_example",
  "base_authority": "AGENTS.md:40",
  "base_kind": "moving",
  "base_ref": "origin/main",
  "base_pin": null,
  "observation_kind": "fetched-ref",
  "observation_commands": [
    {"command": "git fetch origin main", "exit": 0, "result": "origin/main -> full-revision"}
  ],
  "required_revision": "full-revision",
  "integration_method": "none",
  "integration_commands": [
    {"command": "git merge-base --is-ancestor full-revision HEAD", "exit": 0, "result": "ancestor"}
  ],
  "integration_result": "already-current",
  "worker_head_after": "full-revision",
  "conflict_paths": [],
  "resolution_revisions": [],
  "tests": [
    {"command": "repository command before credential expansion", "revision": "full-worker-revision", "environment": null, "exit": 0, "result": "passed", "classification": "passed"}
  ],
  "stop_observation": null,
  "exception_verdict_id": null,
  "exception_authority": null
}
```

Use `pass_kind=new` or `rework`. Use `base_kind=moving`, `pinned`, or `non-git`.
Allowed observation kinds are `fetched-ref`, `stacked-local`, `pinned-local`, and
`non-git-current`. Allowed integration methods are `merge`, `rebase`,
`repository-update`, `snapshot-apply`, and `none`. Allowed integration results are
`already-current`, `integrated`, `conflicts-resolved`, `conflicted`, and `not-run`.

Set `observed_at` immediately after the base observation, or `null` when the attempt
stops earlier. Set `stop_observation` to `null` for a release condition. Otherwise use
exactly `event` and a concise non-secret `reason`. Map events as follows:

- `base-declaration-invalid` -> `blocked-base-declaration`
- `base-unavailable` -> `blocked-base-unavailable`
- `worktree-not-clean` -> `blocked-worktree`
- `conflict-unresolved` -> `blocked-conflict`
- `test-unavailable` -> `blocked-test-unavailable`
- `baseline-red-unaccepted` -> `blocked-baseline-red`

Write each immutable attempt at:

```text
<session-workdir>/evidence/base-sync/<assignment-id>/<new--assignment-id|rework--attest-id>--attempt-<n>.json
```

Hash its exact bytes with SHA-256, then record it:

```text
tightbeam artifact-record --kind data --title "base sync <gate-id> attempt <n>" --path "<absolute-report-path>" --description "BASE_SYNC_V1 evidence" --work-item <work-item-id> --sha256 <hex>
```

Validate the returned row before release. It must be unique, have `kind=data`, have
`createdBySession` equal to `worker_session`, and match the work item, path, and exact
SHA-256. A `report` artifact or another session's artifact is invalid and cannot
satisfy this gate or final verification.

## File the deterministic outcome

After validating the artifact, file one holder progress attest. Encode the note as one
minified line with this exact key order:

```text
BASE_SYNC_V1 {"gate_id":"new:asg_example","attempt":1,"pass_kind":"new","trigger_attest_id":null,"base_declaration_attest_id":"att_example","base_ref":"origin/main","required_revision":"full-revision","integration_result":"already-current","worker_head_after":"full-revision","test_result":"passed","exception_verdict_id":null,"exception_authority":null,"artifact_id":"art_example","artifact_sha256":"hex","status":"released","blocked_reason":null,"next_principal":null}
```

Use `test_result=passed`, `review-target-red`, `accepted-base-red`, `failed`, or
`not-run`. Release only for all-passed tests, exact review-target red with all other
tests passed, or an exception covering every base-originated red with all other tests
passed or review-target red.

Blocked statuses are `blocked-base-declaration`, `blocked-base-unavailable`,
`blocked-worktree`, `blocked-conflict`, `blocked-test-unavailable`,
`blocked-baseline-red`, and `blocked-evidence`. For a report stop, use its exact event
as `blocked_reason`. For later evidence failure, use one of
`artifact-record-failed`, `artifact-row-invalid`, `artifact-row-ambiguous`,
`artifact-row-missing`, `artifact-bytes-mismatch`, `outcome-note-too-long`, or
`outcome-attest-refused`. Name the exact next principal.

If artifact recording fails, file `blocked-evidence` with null artifact fields when
possible. If Tightbeam also refuses the attest, preserve the local report and send the
exact substrate refusal through the operating manual. Never claim a missing row.

## Recover append-only

Before mutating after an interruption, read artifacts and attests for the exact gate
and attempt:

1. If an outcome exists, file no duplicate. Before honoring release, rehash and
   validate the cited artifact, report, and author equality. A later holder does not
   invalidate valid completed evidence, but cannot adopt incomplete evidence.
2. If exactly one matching artifact exists without an outcome, rehash and validate
   its kind, creator, path, SHA, work item, schema, gate, attempt, and current worker.
   If valid and no later attempt exists, derive and file the one outcome.
3. If no matching row exists, do not replay `artifact-record`; a lost response can
   hide a committed row. File `blocked-evidence` with null artifact fields when
   possible, preserve the file, and start the next attempt.
4. If multiple rows match a path, gate, attempt, or SHA, record
   `blocked-evidence`, report the integrity incident to the opener, and start the next
   attempt. No ruling makes ambiguous evidence release.

Never overwrite a report, amend an artifact row, fabricate success, or deliberately
duplicate an artifact.

## Classify source-less work

A task is source-less only when it changes no repository or immutable source snapshot.
Read-only recon, coordination, review, release observation, and runtime-only work can
qualify. Files outside Git do not qualify automatically. If implementation wording is
ambiguous, file one attest, create no artifact, and use this shape:

```text
BASE_SYNC_V1 {"gate_id":null,"attempt":0,"pass_kind":"source-less","trigger_attest_id":null,"base_declaration_attest_id":null,"base_ref":null,"required_revision":null,"integration_result":"not-run","worker_head_after":null,"test_result":"not-run","exception_verdict_id":null,"exception_authority":null,"artifact_id":null,"artifact_sha256":null,"status":"not-applicable","blocked_reason":"read-only-recon","next_principal":null}
```

Use only `read-only-recon`, `coordination`, `review`, `release-observation`,
`runtime-only`, or `evidence-or-spec-only` as the reason. Discovering source later
starts a real gate.

For source files without source control, block by default. The work-item owner user can
file this exact `base-exception-approved` note for an immutable snapshot:

```text
SOURCE_BASE_EXCEPTION_V1 {"gate_id":"<gate-id>","snapshot_artifact_id":"<artifact-id>","snapshot_sha256":"<hex>","integration_procedure":"<exact-procedure>","principal":"user:<ownerUserId>"}
```

The authorized declaring principal then records `kind=non-git`, the snapshot source,
its SHA as `pin`, and that exception attest as `authority`. Verify the bytes. Use
`snapshot-apply` when the authorized procedure changes source or `none` when inclusion
proves already-current. A generic emergency, outage, or “proceed” instruction is not
an exception.

## Review the gate evidence

Review the latest released gate for the pass under review. Verify:

1. Its trigger is the latest applicable `changes-requested` attest.
2. Its unique artifact has `kind=data`; creator, report worker, and outcome author are
   the same worker; and exact bytes match the SHA.
3. Its declaration author and authority satisfy the durable opener or owner-user
   fields and live repository policy.
4. Its observation command, required revision, integration result, and conflict facts
   agree with repository history. Treat a moving-ref observation as holder-recorded
   historical evidence, not independent proof of the remote's former tip.
5. The reviewed commit contains the required revision.
6. Its selected tests follow repository policy and cover conflict paths. Every test
   has exactly the six allowed fields, result agrees with exit, and no process output
   or output-derived value persists.
7. Any exception has the authorized owner, exact revision, failure set, and current
   gate ID.
8. The release attest precedes later `tests-passed` and ready-for-review receipts.
   This proves row order, not first filesystem edit time.
9. `review-target-red`, when used, matches the triggering verdict's reviewed commit,
   safe command identity, and exit in both isolated and synchronized runs, with no
   extra red.

Record any missing, contradictory, stale, foreign, wrong-kind, or hash-mismatched
evidence as a blocking finding. A clean verdict cites the gate ID, artifact ID,
artifact SHA-256, worker session, required revision, and reviewed commit. Do not repair
the producer's branch or evidence.

## Enforce the note bound

Encode every marker as one line with the shown key order, no insignificant whitespace,
raw UTF-8, and shortest required JSON escapes. Measure the final line before calling
Tightbeam. It must be at most 2,000 UTF-8 bytes. Never truncate, split, or silently
substitute a pointer.

When a required note is too long, the authorized actor files this non-authorizing
fallback as progress or the `base-sync-note-too-long` verdict:

```text
BASE_SYNC_NOTE_LIMIT_V1 {"shape":"INTEGRATION_BASE_V1","gate_id":"new:asg_example","attempt":null,"encoded_bytes":2001}
```

Use `INTEGRATION_BASE_V1`, `BASE_RED_EXCEPTION_V1`,
`SOURCE_BASE_EXCEPTION_V1`, or `BASE_SYNC_V1` as `shape`. Copy the gate and attempt or
use JSON `null`. The fallback grants nothing. It maps an oversized declaration to
`blocked-base-declaration`, an oversized exception to the existing blocked state, and
an oversized outcome to `blocked-evidence`.
