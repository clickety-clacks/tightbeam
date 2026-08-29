# Feature-smoke sidecar implementation F4 review — 08e55de8

Review completed at 2026-08-29 07:28 PT. This is an independent, non-live review of
assignment asg_50d46893-da37-4a55-8dc7-d597221a0275.

## Verdict

changes-requested

The exact target still creates the evidence file with requested mode 0666 and changes it
to 0600 in a later syscall. Under umask 000, another principal can observe or open the
file between those operations. C-10 requires exclusive creation to request mode 0600.
The deterministic AC-26 case passes under umask 000 because it checks the mode only after
create_evidence_file/1 has completed the later chmod.

The prior AC-25 finding is closed. Its case now compares the complete code, phase, path
token, and clause result. The external Node helper is also gone, and the BEAM retains one
descriptor through the later mode change, validation, writes, syncs, and close. Those
closures do not remove the creation-time permission window.

## Frozen review identity

| Subject | Frozen identity |
| --- | --- |
| Product base | bdf0ad2c9ae4078f897a00e8c57767968676477c (origin/0.1.9) |
| Reviewed product target | 08e55de896106aa7fcc2ea7f60f1357e5d6cf772 |
| Target parent | ffa6527302cc3d66d3ecffe7ab00d50a13b5b431 |
| Target tree | 84e2f61e205f0e3228163aff9b4d82fdf48ddf3b |
| Cumulative target diff | One path: scripts/feature_smoke.exs; 2,050 additions, 110 deletions |
| Target script SHA-256 | d7b40e41ec221c08cc0fd51720fdc09ad3e39500a43a0e612d226a2b50aaba60 |
| Spec commit | 7717ec827a7448b9b99518d2518383c43c8bd82a |
| Spec tree | 3e5c96a2bb0c823e73a66a9015b8ec69ed43dda0 |
| Contract SHA-256 | 74bb0c3069d41948095eb998b28a4788587b6149bb77b6ccaa68fa3b7efafcc0 |
| Recon SHA-256 | d55b343775e55b0fec614ab641d5dfe4b6251ee2bf87d0ccc62ea8e61141ab91 |
| Exact producer test receipt | att_c904365e-71bb-4f63-a5db-cb74a8480e90 |
| Producer correction report | art_a630e688; SHA-256 63f7125b75eba5d6cfa95c34f16c3290c2276f741a664e01572045db586d53b9 |

Both repositories were fresh reviewer-owned clones. I verified the exact commits,
trees, hashes, remote containment, cumulative one-file diff, assignment history, and
the exact-commit tests-passed receipt before reading the producer correction narrative.
The target worktree was clean before review.

## Finding

### F1 — BLOCKING: evidence creation requests 0666, then changes mode to 0600

C-10 says the fixture requests exclusive creation with mode 0600 before it verifies the
new path (contract lines 437-449, especially 439-444). The exact target instead calls
:file.open/2 with :exclusive but no create-mode option at
scripts/feature_smoke.exs:1833-1835. The runtime supplies mode 0666 to openat. Only after
openat returns does secure_evidence_mode/1 resolve /proc/self/fd/18 and call
:file.change_mode/2 at scripts/feature_smoke.exs:1850-1858. The retained descriptor
prevents a path-reopen race, but it cannot retroactively remove the interval during
which the inode already existed with the permissive creation mode.

I reproduced this against the unmodified exact target with umask 000:

~~~text
umask 000
env ... TIGHTBEAM_SMOKE_HOME_CASES_ONLY=1 \
  strace -f -e trace=%file -s 300 \
  mix run --no-start scripts/feature_smoke.exs

openat(AT_FDCWD, ".../feature-smoke-home-evidence.jsonl",
  O_RDWR|O_CREAT|O_EXCL, 0666) = 18
chown("/proc/self/fd/18", -1, -1) = 0
chmod("/proc/self/fd/18", 0600) = 0
...
feature-smoke HOME validator deterministic cases: 42/42 PASS
~~~

The ordered syscalls demonstrate the behavioral defect. With umask 000, the created
inode starts as a world-readable and world-writable regular file before the later chmod.
This is the exact permissive-creation window that the prior review required the F1
correction to keep closed.

I also delayed entry to the intervening chown syscall by 100 ms and ran a read-only
observer against a reviewer-owned TMPDIR. The observer reached the exact target's new
evidence path before chmod:

~~~text
observer saw mode=666 path=.../tightbeam-home-case-137/feature-smoke-home-evidence.jsonl
feature-smoke HOME validator deterministic cases: 42/42 PASS
~~~

The passing 42-case result also demonstrates the evidence gap. AC-26 wraps
create_evidence_file/1 and reads the mode only after that function returns
(scripts/feature_smoke.exs:1114-1127). It can observe the final 0600 state but cannot
detect the creation request or the intervening mode. The path and handle verification
in with_home_evidence!/3 is likewise post-change
(scripts/feature_smoke.exs:472-495).

Deletion cannot close this while preserving the product: deleting evidence creation
violates C-10, and deleting the post-create chmod leaves the file at the wrong mode.
Acceptance would leave a security-relevant interval whose exposure depends on the
caller's umask. The closure must replace the create-then-chmod seam with a true
exclusive create-at-0600 operation and make the deterministic proof observe that
creation invariant; layering another post-create check would not close it.

## Prior-finding and correction audit

| Prior or assigned boundary | Exact-target result |
| --- | --- |
| F1 external Node helper and Node PATH dependency | Closed. No Node helper remains, and the no-Node HOME case passes. |
| F1 BEAM descriptor custody through mode, validation, writes, sync, and close | Closed. One raw BEAM descriptor is retained and all reviewed refusal paths close it. |
| F1 path reopen race | Closed. Mode change uses the retained descriptor through /proc/self/fd. |
| F1 creation-time mode 0600 | Not closed. openat requests 0666 before chmod 0600; see F1. |
| F1 existing regular-file and FIFO refusal without mutation | Closed. AC-33 passes and the reviewed path uses O_EXCL without opening an existing FIFO. |
| F2 AC-25 complete deterministic result | Closed. The case compares code, phase, path evidence token, and clause at lines 272-273, 886-898, and 978-993. |
| Raw filename preservation and snapshot acquisition | Remains closed. The integrated raw walker and handle/path checks remain in place. |
| Claude-only clock checks and Codex HOME separation | Remain closed. The no-Node deterministic suite passes all 42 cases. |
| Exact-commit tests-passed receipt | Closed by att_c904365e-71bb-4f63-a5db-cb74a8480e90. |

## Contract clause table

Status terms are satisfied, unsatisfied, unproven, and out-of-scope.

| Clause | Status | Review evidence |
| --- | --- | --- |
| C-01 | satisfied | Ordered run-start and per-leg phase plan is enforced; AC-01 through AC-03 and AC-24 pass. |
| C-02 | satisfied | Exact Claude path set, type, mode, size, JSON, and raw-path checks remain integrated; AC-04 through AC-23 and AC-35 pass. |
| C-03 | satisfied | Canonical filename, PID binding, and sidecar identity rules remain integrated; AC-05 through AC-07 and AC-18 pass. |
| C-04 | satisfied | Exact schema and semantic checks remain integrated; AC-08 through AC-14 and AC-32 pass. |
| C-05 | satisfied | Backup and sidecar freshness checks remain integrated; AC-15 and AC-17 pass. |
| C-06 | satisfied | Phase cardinality, continuity, cleanup, and fixed Claude-then-Codex ordering remain represented; AC-16 through AC-18, AC-27, and deterministic AC-29 pass. |
| C-07 | satisfied | Codex validates an empty runtime delta and refuses a nonempty one without reading Claude HOME; AC-24 passes. |
| C-08 | satisfied | Raw-name, single-snapshot, handle identity, read, and final-identity refusals remain exercised by AC-19, AC-20, and AC-35 through AC-42. |
| C-09 | satisfied | AC-25 now proves stable code, phase, path evidence token, and clause; category and predicate ordering remain integrated. |
| C-10 | unsatisfied | Exclusive open requests mode 0666 and changes it to 0600 afterward, contrary to lines 439-444; see F1. Later append, sync, refusal, cleanup, and retained-file behavior remain represented. |
| C-11 | satisfied | The cumulative base-to-target diff changes only scripts/feature_smoke.exs, and the frozen contract and recon hashes are embedded. |
| C-12 | unsatisfied | The exact receipt and repository gate evidence exist and no live action ran, but the deterministic proof accepts a C-10 creation-mode violation. The exact target therefore cannot advance as reviewed-clean. |

## Acceptance table

| Row | Status | Independent evidence |
| --- | --- | --- |
| AC-01 | satisfied | Exact run-start fixture-state case passes at scripts/feature_smoke.exs:165. |
| AC-02 | satisfied | Reused fixture state returns FX_FIXTURE_STATE at lines 166-167. |
| AC-03 | satisfied | Exact baseline snapshot case passes at line 168. |
| AC-04 | satisfied | Exact Claude runtime set passes at line 169. |
| AC-05 | satisfied | Canonical filename/PID case passes at line 170. |
| AC-06 | satisfied | Noncanonical filename returns FX_PATH_SET at lines 171-174. |
| AC-07 | satisfied | Unequal filename/PID returns FX_SIDECAR_SEMANTIC at lines 175-178. |
| AC-08 | satisfied | Invalid UTF-8 returns FX_JSON at lines 179-182. |
| AC-09 | satisfied | Malformed JSON returns FX_JSON at lines 183-186. |
| AC-10 | satisfied | Duplicate JSON member returns FX_JSON at lines 187-190. |
| AC-11 | satisfied | Missing sidecar member returns FX_SIDECAR_SCHEMA at lines 191-194. |
| AC-12 | satisfied | Extra sidecar member returns FX_SIDECAR_SCHEMA at lines 195-198. |
| AC-13 | satisfied | Wrong member type returns FX_SIDECAR_SCHEMA at lines 199-202. |
| AC-14 | satisfied | Wrong cwd returns FX_SIDECAR_SEMANTIC at lines 203-206. |
| AC-15 | satisfied | Out-of-window timestamp returns FX_FRESHNESS at lines 207-213. |
| AC-16 | satisfied | Duplicate sidecar returns FX_PATH_SET at lines 214-223. |
| AC-17 | satisfied | New post-turn canonical backup passes at lines 224-232. |
| AC-18 | satisfied | Sidecar identity drift returns FX_IDENTITY_DRIFT at lines 233-241. |
| AC-19 | satisfied | Unexpected nested path returns FX_PATH_SET at lines 242-251. |
| AC-20 | satisfied | Symlink at an admitted name returns FX_TYPE at lines 252-258. |
| AC-21 | satisfied | Wrong mode returns FX_MODE at lines 259-262. |
| AC-22 | satisfied | Oversized sidecar returns FX_SIZE at lines 263-266. |
| AC-23 | satisfied | Wrong .claude.json top-level shape returns FX_JSON_SHAPE at lines 267-270. |
| AC-24 | satisfied | Empty Codex HOME passes and a nonempty delta returns FX_CODEX_RUNTIME_PATH at line 271 and in the reviewed helper. |
| AC-25 | satisfied | Three runs now compare the full expected map: FX_MODE, pre-wake, .claude.json, C-02 at lines 272-273, 886-898, and 978-993. |
| AC-26 | unproven | The retained seven-record file reaches 0600, but its test observes mode only after the create-then-chmod sequence. It does not prove C-10's create-at-0600 invariant; see F1. |
| AC-27 | satisfied | Post-spawn refusal runs cleanup and does not advance the other leg at line 275 and the reviewed helper. |
| AC-28 | satisfied | The frozen cumulative diff is exactly one implementation path at line 276. |
| AC-29 | out-of-scope | The deterministic phase-matrix projection passes at line 277. This review card forbids a live fixture or live matrix, so no live claim is made. |
| AC-30 | satisfied | New-runtime blocker retention and no-retry case passes at line 278. |
| AC-31 | satisfied | Frozen contract and recon provenance case passes at line 279. |
| AC-32 | satisfied | Wrong-cwd evidence cardinality and ordering case passes at line 280 and in the reviewed helper. |
| AC-33 | satisfied | Existing regular file and FIFO refuse once before run-start and retain identity, mode, and bytes at line 281 and in the reviewed helper. |
| AC-34 | satisfied | Append and sync failure cases pass with one console refusal and no later action at line 282. |
| AC-35 | satisfied | Repeated path-set tie returns stable FX_PATH_SET, path=-, and clause at lines 283-287. |
| AC-36 | satisfied | Injected enumeration failure returns the specified snapshot refusal at line 288. |
| AC-37 | satisfied | Injected lstat failure retains the specified partial entry at line 289. |
| AC-38 | satisfied | Injected open failure retains metadata and a null hash at line 290. |
| AC-39 | satisfied | Injected short/read failure refuses without retry at line 291. |
| AC-40 | satisfied | Opened-object wrong type refuses before read at line 292. |
| AC-41 | satisfied | Opened-object identity mismatch refuses before read at line 293. |
| AC-42 | satisfied | Final path identity/type mismatch refuses after retaining SHA-256 and without resnapshot at line 294. |

## Independent verification

All commands ran in the fresh reviewer clone at exact target 08e55de8. No fixture,
gateway, harness spawn, wake, live smoke, integration, release, deploy, or restart ran.

| Check | Result |
| --- | --- |
| Release CLI prerequisite | /home/mike/.cargo/bin/cargo build --release --manifest-path cli/Cargo.toml passed. |
| Dependencies and compile | mise exec -- mix deps.get and mise exec -- mix compile passed. |
| Format | mise exec -- mix format --check-formatted passed. |
| Diff hygiene | git diff --check passed. |
| No-Node deterministic HOME suite | 42/42 passed. |
| No-Node HOME suite under umask 000 | 42/42 passed, which exposes the missing creation-mode assertion. |
| Creation-mode reproduction | strace shows O_CREAT|O_EXCL mode 0666 followed by chmod 0600; a delayed-syscall observer sees the live target path at mode 666 before chmod. |
| First full repository-gate invocation | 9 doctests, 1,704 tests, 3 failures, 11 skipped. The PATH selected /home/mike/.tightbeam/bin/codex, whose injected trust flag duplicated the test's own flag; this was an invocation-environment failure, not accepted as target evidence. |
| Full repository gate with direct CLIs | scripts/verify_mix.sh passed: 9 doctests, 1,704 tests, 0 failures, 11 skipped. |

## Completeness, necessity, YAGNI, and subtraction

I reviewed the integrated result, its callers, phase lifecycle, evidence writer, refusal
paths, cleanup, descriptor ownership, cumulative diff, and predecessor corrections rather
than only the successor hunk. No other blocking or important issue survived reproduction.

The F2 expansion is necessary because AC-25 expressly requires four stable fields. Removing
the external helper and keeping descriptor custody inside the BEAM are also within the
assigned F1 boundary. I found no unrequested file, dependency, retry, fallback sink, or
live action.

The remaining create-then-chmod mechanism does not satisfy the principle it exists to
implement. Deleting the evidence surface loses required C-10 behavior, while accepting
the interval violates the security floor. The smallest valid closure replaces this seam;
it does not add another checker, helper, framework, or fallback path.
