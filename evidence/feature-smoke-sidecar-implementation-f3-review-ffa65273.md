# Feature-smoke sidecar implementation F3 review — `ffa65273`

Review completed at 2026-08-29 06:34 PT. This is an independent, non-live review of
assignment `asg_cc3de744-7924-45ec-b408-9631717b74bc`.

## Verdict

`changes-requested`

The exact target passes the repository gate and its 42-case HOME suite in the normal
Gibson environment. Two material review findings remain: the F1 correction gives
exclusive evidence-file creation to a new external Node process despite the review
card's explicit no-dependency/no-custody-expansion boundary, and the AC-25 case checks
only the winning code even though AC-25 requires the code, phase, path token, and clause
to remain stable.

## Frozen review identity

| Subject | Frozen identity |
| --- | --- |
| Product base | `bdf0ad2c9ae4078f897a00e8c57767968676477c` (`origin/0.1.9`) |
| Reviewed product target | `ffa6527302cc3d66d3ecffe7ab00d50a13b5b431` |
| Target parent | `9673d3b9b0a87ed73b3d7eef26b8428a5dcf66ad` |
| Target tree | `5471654b3c0c74f107aea011dfc1fd94cfb74e8a` |
| Cumulative target diff | One path: `scripts/feature_smoke.exs`; 2,024 additions, 110 deletions |
| Target script SHA-256 | `b7c4ce48cf6601d3b713fb532dc73a56023fa43cb4e72cea52d1512f6ee387f5` |
| Spec commit | `7717ec827a7448b9b99518d2518383c43c8bd82a` |
| Spec tree | `3e5c96a2bb0c823e73a66a9015b8ec69ed43dda0` |
| Contract SHA-256 | `74bb0c3069d41948095eb998b28a4788587b6149bb77b6ccaa68fa3b7efafcc0` |
| Recon SHA-256 | `d55b343775e55b0fec614ab641d5dfe4b6251ee2bf87d0ccc62ea8e61141ab91` |
| Producer test receipt | `att_b9b491d6-e3f6-4cba-b000-8d7328bab5dd`, exact target `ffa6527302cc3d66d3ecffe7ab00d50a13b5b431` |

Both repositories were fresh reviewer-owned clones. Both exact commits and their remote
containment were verified before reading the producer narrative. The target worktree was
clean before review.

## Findings

### F1 — BLOCKING: exclusive evidence creation moved into an external Node process

The exact review card requires F1 to refuse every existing path while adding no race,
dependency, or custody expansion. The target's `create_evidence_file/1` invokes
`System.cmd("node", ...)`; the child process performs `fs.openSync(..., "wx", 0o600)`,
closes the descriptor, and returns control to the BEAM
(`scripts/feature_smoke.exs:1820-1837`). The BEAM then reopens the path and separately
checks it with `lstat` (`scripts/feature_smoke.exs:471-504`). This is a new external-helper
dependency and gives the helper custody of the security-relevant exclusive-create step.
No contract clause requires that mechanism, and the assignment expressly forbids the
expansion.

The dependency is observable in the supposedly pure HOME-case mode. With Erlang, Elixir,
and system tools available but the Tightbeam-projected `node` absent from `PATH`, this
exact target exits 1 before completing its deterministic cases:

```text
env PATH=/home/mike/.local/share/mise/installs/erlang/28.5/bin:/home/mike/.local/share/mise/installs/elixir/1.19.5-otp-28/bin:/usr/bin:/bin \
  LC_ALL=C.utf8 TIGHTBEAM_SMOKE_HOME_CASES_ONLY=1 \
  /home/mike/.local/share/mise/installs/elixir/1.19.5-otp-28/bin/mix run --no-start scripts/feature_smoke.exs

** (throw) {:home_case_refusal, %{code: "FX_EVIDENCE",
  path: "feature-smoke-home-evidence.jsonl", clause: "C-10",
  phase: "run-start", harness: "all", principal: "run-start"}}
    scripts/feature_smoke.exs:1004: anonymous fn/1 in FeatureSmoke.codex_clock_scope_case/0
```

This does not dispute that the Node-present behavior now refuses a real regular file and
a real FIFO without hanging; AC-33 passes in that environment
(`scripts/feature_smoke.exs:1306-1384`). It shows that the closure violates the additional
F1 boundary it was specifically assigned to preserve.

Deletion would close the unrequested external-helper seam. Deleting evidence creation
itself would not close C-10, and accepting the seam would violate the assignment's exact
boundary; the existing-authority exclusive-create mechanism remains the required design
choice.

### F2 — IMPORTANT: AC-25's deterministic case discards three required result fields

AC-25 requires repeated runs to return the same first code, phase, path evidence token,
and clause (`feature-smoke-claude-session-sidecar-contract.md:655`). The implementation's
case runs the candidate through `runtime_case/7`, which reduces it to `candidate.code`
(`scripts/feature_smoke.exs:872-890`), and `repeated_first_failure/3` then checks only that
three code strings are equal (`scripts/feature_smoke.exs:966-979`). It cannot detect a
regression in the selected path or clause, and it never observes a result carrying the
phase.

An in-memory diagnostic mutation changed the winning FX_MODE candidate's clause from
`C-02` to `C-WRONG` and its path from the selected raw path to `WRONG-PATH`, without
changing its code. The exact 42-case runner still exited 0 and printed:

```text
feature-smoke HOME validator deterministic cases: 42/42 PASS
```

The production implementation currently computes the expected path and clause; this is
an evidence gap, not a claim that the unmutated target emits the wrong values. C-12 and
the acceptance preface require a deterministic case for every row
(`feature-smoke-claude-session-sidecar-contract.md:603-618,626-627`).

Deleting the misleading AC-25 assertion would expose the gap but would not close it,
because the acceptance row would remain unproven. The existing case must prove the whole
required result at its current seam.

## Prior-finding closure audit

| Prior issue | Exact-target result |
| --- | --- |
| Raw filename discovery used decoded `File.ls` names | Closed. Snapshot enumeration preserves raw names through the reviewed walker. |
| Evidence path was created permissively and chmodded later | Closed for creation-time mode in the Node-present path: `openSync` requests exclusive mode 0600. F1 above concerns the forbidden helper/custody expansion. |
| No exact-commit tests-passed receipt | Closed by `att_b9b491d6-e3f6-4cba-b000-8d7328bab5dd`. |
| Shell noclobber could block on an existing FIFO | Closed in the Node-present path. The real FIFO case is bounded to two seconds, preserves identity and mode, and passes. |
| Claude snapshot clock checks leaked into Codex | Closed. Both clock guards are restricted to `harness == "claude"` (`scripts/feature_smoke.exs:598-623`); the real empty Codex HOME case with a future spawn timestamp passes, while the nonempty Codex case still refuses (`scripts/feature_smoke.exs:981-1047`). |

## Contract clause table

Status terms are `satisfied`, `unsatisfied`, `unproven`, and `out-of-scope`.

| Clause | Status | Review evidence |
| --- | --- | --- |
| C-01 | satisfied | Ordered run-start and per-leg phase plan is enforced; AC-01, AC-02, AC-03, and AC-24 pass. |
| C-02 | satisfied | Exact Claude path set, type, mode, size, JSON, and raw-path checks are integrated; AC-04 through AC-23 and AC-35 pass. |
| C-03 | satisfied | Filename/PID and sidecar identity rules are integrated; AC-05 through AC-07 and AC-18 pass. |
| C-04 | satisfied | Exact schema and semantic checks are integrated; AC-08 through AC-14 and AC-32 pass. |
| C-05 | satisfied | Backup and sidecar freshness checks are integrated; AC-15 and AC-17 pass. |
| C-06 | satisfied | Phase cardinality, continuity, cleanup, and fixed Claude-then-Codex ordering are represented; AC-16 through AC-18, AC-27, and deterministic AC-29 pass. |
| C-07 | satisfied | Codex validates an empty runtime delta and refuses a nonempty one. The real empty-HOME/future-spawn and nonempty cases pass. |
| C-08 | satisfied | Raw-name, single-snapshot, handle identity, read, and final-identity refusals are exercised by AC-19, AC-20, and AC-35 through AC-42. |
| C-09 | unproven | Production ordering is present, but AC-25 does not prove stable phase, path, or clause; see F2. |
| C-10 | unsatisfied | Node-present evidence/refusal behavior passes, including real regular and FIFO occupants, but the exact F1 assignment's no-dependency/no-custody-expansion boundary fails; see F1. |
| C-11 | satisfied | Cumulative base-to-target diff changes only `scripts/feature_smoke.exs`; hashes and reviewed authority are embedded and AC-28/AC-31 pass. |
| C-12 | unsatisfied | Exact receipt and repository gate pass, and no live action was taken, but AC-25 lacks its required complete deterministic proof. |

## Acceptance table

| Row | Status | Independent evidence |
| --- | --- | --- |
| AC-01 | satisfied | Run-start exact fixture state passes (`scripts/feature_smoke.exs:165`). |
| AC-02 | satisfied | Reused fixture state returns `FX_FIXTURE_STATE` (`:166-167`). |
| AC-03 | satisfied | Exact baseline snapshot case passes (`:168`). |
| AC-04 | satisfied | Exact Claude runtime set passes (`:169`). |
| AC-05 | satisfied | Canonical filename/PID case passes (`:170`). |
| AC-06 | satisfied | Noncanonical filename returns `FX_PATH_SET` (`:171-174`). |
| AC-07 | satisfied | Unequal filename/PID returns `FX_SIDECAR_SEMANTIC` (`:175-178`). |
| AC-08 | satisfied | Invalid UTF-8 returns `FX_JSON` (`:179-182`). |
| AC-09 | satisfied | Malformed JSON returns `FX_JSON` (`:183-186`). |
| AC-10 | satisfied | Duplicate JSON member returns `FX_JSON` (`:187-190`). |
| AC-11 | satisfied | Missing sidecar member returns `FX_SIDECAR_SCHEMA` (`:191-194`). |
| AC-12 | satisfied | Extra sidecar member returns `FX_SIDECAR_SCHEMA` (`:195-198`). |
| AC-13 | satisfied | Wrong member type returns `FX_SIDECAR_SCHEMA` (`:199-202`). |
| AC-14 | satisfied | Wrong cwd returns `FX_SIDECAR_SEMANTIC` (`:203-206`). |
| AC-15 | satisfied | Out-of-window timestamp returns `FX_FRESHNESS` (`:207-213`). |
| AC-16 | satisfied | Duplicate sidecar returns `FX_PATH_SET` (`:214-223`). |
| AC-17 | satisfied | New post-turn canonical backup passes (`:224-232`). |
| AC-18 | satisfied | Sidecar identity drift returns `FX_IDENTITY_DRIFT` (`:233-241`). |
| AC-19 | satisfied | Unexpected nested path returns `FX_PATH_SET` (`:242-251`). |
| AC-20 | satisfied | Symlink at admitted name returns `FX_TYPE` (`:252-258`). |
| AC-21 | satisfied | Wrong mode returns `FX_MODE` (`:259-262`). |
| AC-22 | satisfied | Oversized sidecar returns `FX_SIZE` (`:263-266`). |
| AC-23 | satisfied | Wrong `.claude.json` top-level shape returns `FX_JSON_SHAPE` (`:267-270`). |
| AC-24 | satisfied | Real empty Codex HOME with future spawn passes; nonempty HOME still returns `FX_CODEX_RUNTIME_PATH` (`:271`, `:981-1047`). |
| AC-25 | unproven | The case checks only the code, not phase/path/clause; an in-memory wrong-path/wrong-clause mutant still passes 42/42 (`:272`, `:966-979`). |
| AC-26 | satisfied | Seven-record canonical evidence case passes (`:273`). |
| AC-27 | satisfied | Post-spawn refusal runs cleanup and does not advance the other leg (`:274`). |
| AC-28 | satisfied | Frozen cumulative diff is exactly one implementation path (`:275`). |
| AC-29 | out-of-scope | The deterministic phase-matrix projection passes (`:276`); the review card forbids a live fixture/matrix, so no live claim is made. |
| AC-30 | satisfied | New-runtime blocker retention/no-retry case passes (`:277`). |
| AC-31 | satisfied | Frozen contract/recon provenance case passes (`:278`). |
| AC-32 | satisfied | Wrong-cwd evidence cardinality/order case passes (`:279`, `:1260-1303`). |
| AC-33 | satisfied | Real regular and FIFO occupants both refuse once, before run-start, and remain unchanged (`:280`, `:1306-1384`). F1 is the separate assignment-boundary defect in the helper mechanism. |
| AC-34 | satisfied | Append and sync failure cases pass with one console refusal and no later action (`:281`). |
| AC-35 | satisfied | Repeated path-set tie returns stable `FX_PATH_SET`, `path=-`, and clause (`:282-286`). |
| AC-36 | satisfied | Injected enumeration failure returns the specified snapshot refusal (`:287`). |
| AC-37 | satisfied | Injected `lstat` failure retains the specified partial entry (`:288`). |
| AC-38 | satisfied | Injected open failure retains metadata and null hash (`:289`). |
| AC-39 | satisfied | Injected short/read failure refuses without retry (`:290`). |
| AC-40 | satisfied | Opened-object wrong type refuses before read (`:291`). |
| AC-41 | satisfied | Opened-object identity mismatch refuses before read (`:292`). |
| AC-42 | satisfied | Final path identity/type mismatch refuses after retained SHA-256 and without resnapshot (`:293`). |

## Independent verification

All commands ran in the fresh reviewer clone at exact target `ffa65273`; no fixture,
gateway, harness spawn, wake, live smoke, integration, release, deploy, or restart ran.

| Check | Result |
| --- | --- |
| Release CLI prerequisite | `cargo build --release --manifest-path cli/Cargo.toml` passed. |
| Dependencies and compile | `mise exec -- mix deps.get && mise exec -- mix compile` passed. |
| Format | `mise exec -- mix format --check-formatted` passed. |
| Normal deterministic HOME suite | 42/42 passed. |
| Repeated normal deterministic HOME suite | Three reviewed runs each passed 42/42. |
| Full repository gate | `scripts/verify_mix.sh`: 9 doctests, 1,704 tests, 0 failures, 11 skipped. |
| Diff hygiene | `git diff --check` passed. |
| F1 dependency reproduction | No-Node `PATH` run exited 1 with `FX_EVIDENCE` before the 42-case result. |
| F2 diagnostic mutation | Wrong winning clause/path still exited 0 and printed 42/42 PASS. |

## Completeness, necessity, and subtraction

The integrated result and its call sites, lifecycle, refusal paths, cleanup, and evidence
writer were reviewed, not only the successor diff. The producer's F2 clock correction is
necessary and closes the prior cross-harness defect. The external Node helper is not
required by the contract and is expressly excluded by the F1 assignment boundary; it is
therefore an unrequested mechanism, not an authorized behavioral delta. No other material
unrequested addition was found.

The smallest closure is subtraction at F1's helper seam and complete observation at
AC-25's existing test seam. Deleting the product surface would discard the required
sidecar contract, and accepting either failure would contradict the explicit F1 boundary
or C-12 acceptance proof. No additional files, frameworks, retry paths, or fallback sinks
are warranted.
