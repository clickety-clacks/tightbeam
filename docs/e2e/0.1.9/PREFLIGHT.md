# 0.1.9 E2E preflight and readiness

This page answers one question before anyone runs the [0.1.9 E2E runbooks](README.md):
are the inputs and safety conditions in place? It adds no new procedure. Every
check it names already lives in the area runbooks or
[UPGRADE.md](../../UPGRADE.md); this page classifies them, records what is
missing, and says who supplies it.

The answer is either **YES, run** with every input named, or a finite list of
blockers. Nothing runs until Mike calls the run and that call is recorded.

## Historical readiness snapshot, 2026-09-30

The September 30 assessment was **not yet**: four inputs were absent and one
host condition was unmet. Its package, disk, account and approval statuses
below are a dated snapshot, not current readiness evidence. Reconcile them
against the run's recorded inputs before calling it ready. The October 1
coverage revision adds the fresh-base prerequisites listed below; authoring
and source CI do not execute or authorize these E2E journeys.

## Two upgrade paths, and which one E2E uses

The gateway refuses an unmarked existing base unless it knows the exact
transition. Two things can supply it:

- **Published release** (PR #185). A tagged push build carries
  `release-provenance.json` in the package root. On an unmarked base stamped
  `operator-decision-requests-v1`, the gateway derives the transition itself and
  migrates with no operator input. Candidate and manually dispatched builds omit
  the file on purpose, so they never do this.
- **Explicit transition** (PR #183). `TIGHTBEAM_LIVE_BASE_TRANSITION` names the
  base, source stamp and target payload identity for one start. Works for any
  package, and an invalid value never falls back to the automatic path.

E2E on the 0.1.9 branch uses a **candidate package**, because no 0.1.9 release
exists. A candidate has no provenance, so the migration runbook's explicit path
is the only path, and its `no-transition` probe correctly expects
`build_transition_required`. That is the workbranch rehearsal, and it is not
blocked by PR #185.

The automatic path is release behavior. It is checked once a tagged 0.1.9
package exists, by the [release package](migration.md#package-kind) branch of the
same runbook: on that package the `no-transition` start is the positive start,
and running it as a refusal probe would migrate the copy. The two paths are not
interchangeable and the runbook now tells them apart by the presence of
`release-provenance.json`.

## Prerequisites

Each row is one of: **every run** (a runbook step), **one-time** (set up once,
then reused), or a **blocker in the dated snapshot** (owner and action given).
The status column preserves that assessment; it is not a fresh host probe.

### Candidate package

| Prerequisite | Class | Where documented | Status |
|---|---|---|---|
| Build the candidate: branch `release-candidate/<name>` from the 0.1.9 head plus one empty marker commit (the workflow refuses an empty range), let `release candidate` run, download `release-candidate-proof-<sha>` | one-time per package | [Package acquisition](migration.md#package-acquisition) (added) | **Blocker.** No 0.1.9 candidate artifact exists. Owner: PDO. Action: run the workflow on the 0.1.9 head Mike names; the artifact keeps for 90 days. |
| Verify the package against the proof `SHA256SUMS`, extract it, set `PKG` to the extracted `tightbeam/` directory | every run | migration.md source qualification | Ready once the artifact exists |
| `target_source_commit` = the candidate SHA; `target_source_checkout` = a checkout of that SHA inside `SOURCE_DIR` | every run | migration.md build admission | Ready once the artifact exists |
| Package kind check: `release-provenance.json` absent, so the explicit path applies | every run | migration.md package kind (added) | Ready |

### Real 0.1.8 database snapshot

| Prerequisite | Class | Where documented | Status |
|---|---|---|---|
| Consistent `VACUUM INTO` copy of the live Gibson `state.db`, from a read-only handle, plus `PRAGMA quick_check` and the manifest | one-time per E2E cycle | [Source snapshot](migration.md#source-snapshot) (added) | **Blocker.** No snapshot exists. Owner: operator (Mike's go); executor: the E2E runner. Size 21.3 GB; Gibson has 348 GB free. Reads only; nothing on Gibson changes. |
| Source manifest (`tightbeam-e2e-source/v1`) | one-time, with the snapshot | [Source snapshot](migration.md#source-snapshot) writes it | Produced by the snapshot step |
| The 0.1.8 package that produced the source (`package-0.1.8.tar`) beside the snapshot | one-time | migration.md source qualification | Download `tightbeam-0.1.8-linux-x86_64-b2add64.tgz` from release `v0.1.8+1343`; SHA `9dcfd9dc04eb718e27fcf479a494b38818f8fe5d41c2a6b065c224d3ffe4b623` |
| Lineage pins match the actual snapshot, or a source-backed ruling admits the difference | every run (STOP) | migration.md source qualification | **Corrected.** The runbook pinned `v0.1.8+1337`; Gibson runs `v0.1.8+1343` (`/version` sha `b2add644`, release provenance commit `b2add64414b41606a713ed284abf01a0b4d125e6`, stamp `operator-decision-requests-v1`). The pins now name +1343. Delivery ownership confirms by reviewing that change. |

### Containment environment

| Prerequisite | Class | Where documented | Status |
|---|---|---|---|
| A disposable Linux environment: own PID and network namespaces, loopback only, no live base, read-only `SOURCE_DIR`, writable `SCRATCH` | one-time (image), every run (fresh container) | [Reference environment](README.md#reference-environment) (added) | Guided. Racter has Docker usable by `clu`. Eezo has no container runtime and macOS is outside the written checks. |
| Scratch holds at least 3× the source (64 GB) plus the source itself if it lives on the same disk (21 GB) | every run (STOP) | README containment condition 1 | **Blocker.** Racter has 68 GB free on its only volume. Owner: Racter's operator. Action: free or attach about 90 GB, or mount the snapshot from Gibson read-only so only 64 GB is local. |
| Six containment checks pass inside the container before the first gateway start | every run (STOP) | README containment | Ready. Docker's own bind mounts of `/etc/hosts`, `/etc/hostname` and `/etc/resolv.conf` are expected under condition 2 and are now named there. |
| Boot preflight finds a runnable harness CLI (`no_harness_cli` otherwise) | every run | README containment condition 6 | Satisfied by the image |

### Approvals and inputs Mike supplies

| Prerequisite | Class | Where documented | Status |
|---|---|---|---|
| A recorded approval naming the environment and the package (README condition 1 `approval:` line) | every run (STOP) | README containment | **Blocker.** Owner: Mike. Action: one ruling, recorded as an attest on the E2E card, naming Racter, the container image digest and the candidate SHA. |
| `COPIED_TOKEN_APPROVAL`: whether rows that act as a copied live session run | every run | README copied session tokens | **Decision pending.** Owner: Mike. Without it those rows record `INCOMPLETE`, and the run is still valid. |
| Online tier: a separately authorized environment with test-owned Claude and Codex accounts, models per leg (`TIGHTBEAM_SMOKE_MODEL_*`), `TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS=2500` | one-time (accounts), every run (env) | README tiers, [SMOKE.md](../../SMOKE.md) | **Blocker.** No test-owned accounts are recorded anywhere. Owner: Mike. Action: name the accounts and the host. Cursor and Pi legs record `INCOMPLETE(parity)` as SMOKE.md already says. |

### Runbook placeholders filled at run time

These are every-run inputs the runbooks mark `replace-with-…`. They come from
the artifacts above and the copy itself, never from guesswork:

- `expected_target_package_sha256`, `target_source_commit`, `target_source_checkout`
  (migration.md)
- `existing_work_item`, `existing_assignment`, `existing_request`,
  `existing_artifact` for the preservation reads, chosen from the copy
- `SOURCE_DIR`, `SCRATCH`, `PKG` (README containment)

### Fresh-base outcome prerequisites

New-record features use the [fresh-base actors](README.md#fresh-base-actors),
not a migrated copy reconnected to the network. Ordinary admitted actors,
roles and test users are shared across compatible journeys. Missing admission
is a setup result, never permission for raw fixture writes.

| Journey | Input supplied by the authorized E2E runner/operator | If absent |
|---|---|---|
| U1 transition and U2 satellite | Matching packaged client on a configured test satellite with no local gateway; a paired test device for the status route; two credential-ready harnesses and one real session | Name the missing route, credential or harness. A local snapshot is not satellite proof. |
| U1 legacy fallback | An already approved hash-qualified v1-only gateway fixture and redacted protocol observation | Named fallback gap; current v2/REST evidence remains separate. Do not build a fake server. |
| U1 Pi/Cursor | Test provider/model and actual tool observation; Cursor's supported dedicated execution account already exists | Named allow/deny or execution-identity gap, not parity credit from a reply alone. |
| U3–U6 records/notice/queue | Admitted independent test actors; a genuine bounded running/queued window; actual review-card admission | Report missed windows or admission limits; never forge verification evidence. |
| U4 sentinel | One disposable test repository/PR, authorized checks and guarded queue/merge route, test GitHub configuration and sentinel settings | No sentinel landing evidence; keep the same PR for checks and settlement. |
| U7 recovery | The specific genuine authorized incident for each row and existing safe observation; an already-unreachable registered test host suffices for #138 | Record each missing incident/recovery half and its focused source reference. Do not force faults. |
| U9 retirement | Owned disposable workspace on the recorded original host and a no-artifact companion | Name the unavailable host/workspace; local absence cannot prove remote cleanup. |
| U10 D1 | Fresh non-admin test session and known harmless host-environment entry with cleanup | Named authorization/redaction setup gap. |

The run's approval names the host, package/source and fixtures it actually
covers. This page supplies no approval for a provider, GitHub or live-org action.

## What a YES looks like

All of these are true, and each is recorded on the E2E card:

1. Candidate proof artifact downloaded and hash-verified; `PKG` extracted from it.
2. Snapshot taken, `quick_check` ok, manifest written, 0.1.8 package beside it.
3. Container image built; Racter has the space; the six containment checks pass
   inside a fresh container.
4. Mike's approval attest names the environment, image and package.
5. The copied-token decision is recorded either way.

Then the [aggregate run](README.md#aggregate-run) starts at step 1. The online
tier waits for its own authorization and accounts; the offline tier does not
depend on it.

## Corrections made with this page

- migration.md: lineage pins updated from `v0.1.8+1337` to `v0.1.8+1343`, with
  the release provenance as evidence.
- migration.md: a [Package kind](migration.md#package-kind) section that tells a
  candidate package from a published release, and makes the `no-transition`
  probe conditional. The preserved manifest records which path ran.
- migration.md: a [Package acquisition](migration.md#package-acquisition) section
  naming the release-candidate workflow, its proof artifact and the extracted
  layout, because no published 0.1.9 package exists.
- README.md: containment condition 2 names Docker's expected bind mounts, and a
  reference environment (Dockerfile and run command) that meets the six
  conditions.
- migration.md: a source snapshot section that takes the read-only copy and
  writes the manifest, so the snapshot is a runbook step rather than an
  operator improvisation.
- The specs-repository `release-019-database-migration-rehearsal.md` is marked
  superseded by migration.md.
