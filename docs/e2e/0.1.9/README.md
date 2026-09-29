# Tightbeam 0.1.9 end-to-end acceptance

Use these procedures only when Mike authorizes an E2E run. They are runbooks, not
evidence that migration or smoke has passed. The source branch's normal CI does
not execute these procedures.

The runbooks use one real 0.1.8 database migration and preserve its migrated
database as a reusable input. Each feature run uses a separate copy of that
output, so a feature check never migrates the source again or changes the
preserved result.

## Execution contract

- Run checkout-backed feature smoke on Racter or Eezo through the repository's
  canonical wrapper. Keep the wrapper unchanged. If that route is unavailable,
  stop and report the blocker; do not move the run to Gibson.
- Use a disposable test base and an unused port. Never resolve a path to a live
  base. Do not install a package on Gibson.
- For CLI rows, `tightbeam` means the absolute-path CLI from the same verified
  0.1.9 package as the gateway under test. The CLI resolves an ancestor
  `.tightbeam-session` first, then `TIGHTBEAM_URL` plus `TIGHTBEAM_TOKEN`,
  and only then `TIGHTBEAM_BASE_DIR`. Run every CLI call from a disposable
  shell working directory whose ancestors up to `/` contain no
  `.tightbeam-session`; stop if that cannot be verified. Unset
  `TIGHTBEAM_URL` and `TIGHTBEAM_TOKEN` in that shell and keep them unset
  for every call. Then set `TIGHTBEAM_BASE_DIR` to the disposable area base.
  Do not let `PATH` select an unrelated installed CLI.
  The `identity current` row is the deliberate exception: use only the fresh
  marker of its throwaway test session, and first confirm its URL and token
  match that area's loopback endpoint and `gateway.json` without printing the
  token. A CLI call made by a test session must use that test base's freshly
  provisioned marker; never use a marker from the operator's current session.

  Establish that shell before running any CLI row, then leave its working
  directory unchanged for those calls:

  ```sh
  cli_cwd="$(mktemp -d "${TMPDIR:-/tmp}/tightbeam-cli.XXXXXX")"
  cd "$cli_cwd"
  directory="$(pwd -P)"
  while :; do
    test ! -e "$directory/.tightbeam-session" || {
      echo "session marker in CLI working-directory ancestry; stop" >&2
      exit 1
    }
    test "$directory" = "/" && break
    directory="$(dirname "$directory")"
  done
  unset TIGHTBEAM_URL TIGHTBEAM_TOKEN
  ```

- Start the migration rehearsal from an operator-supplied, verified copy of a
  real 0.1.8 `state.db`. Do not copy `gateway.json`, provider credentials,
  harness homes, or identity state from the source base.
- Do not give the copied org access to the test host's existing harness
  credentials. The copied sessions must not inherit a provider credential or
  a route to a real host.
- If a check needs an incident, failed turn, pending placement, provider grant,
  or other real prerequisite that is absent, record it as `INCOMPLETE` with the
  missing prerequisite. Do not fabricate a success with synthetic state.

### Safe stop before copied-org gateway boot

The current 0.1.9 source has no supported quiescent boot mode for a database
copied from a real org. Before starting, `Gateway` performs liveness recovery,
and `LaneManager` immediately reconciles pending sessions at startup; pending
turns can start before a runbook check begins. The wake and supervision
interval settings delay periodic scans but do not disable that initial work.
The copied `hosts` rows can also name SSH destinations. No current runbook
step proves those routes, wakes, supervision work, or provider credentials are
inert on a real-org copy.

Therefore, stop before the first 0.1.9 gateway boot in both the migration and
feature-area procedures until the PO records a source-backed isolation path
that keeps copied sessions, turns, wakes, remote hosts, and credentials from
acting. Do not try to create that path by editing the copied database, deleting
its rows, pre-seeding build markers, changing private release config, or
extending scan intervals. Record the migration or area as `INCOMPLETE` and
leave the source and migrated result unapproved. A local bind address or
network block alone does not prevent copied work from being reconciled inside
the gateway.

The feature smoke also follows that boundary: it no longer sweeps pre-existing
open work or applies identity to every copied session. Each invocation creates
its own unique fixtures. If it stops part-way through, discard that area copy
and make a fresh one from the preserved migration result; do not clean unrelated
rows to prepare a retry.

## Aggregate run

1. Read [`migration.md`](migration.md) and qualify the real 0.1.8 source copy.
   The current source-backed isolation stop blocks package boot. Do not
   continue until the PO records an approved boot path and the migration
   runbook is updated to use it. Then run the 0.1.9 package against one
   isolated migration base exactly once, stop it cleanly, save the migrated
   `state.db` and its non-secret manifest, and leave the source copy read-only.
   Do not continue if a stamp, integrity, foreign-key, version, or unexplained
   row-count check fails.
2. After the approved isolation path is in place, create a fresh gateway
   descriptor for each disposable feature base and copy in a new copy of the
   preserved migrated database while the gateway is stopped. Do not attach
   credentials until the approved path proves copied sessions cannot use them.
   Use a distinct port and base for each run. Start the verified 0.1.9 gateway
   only by the exact source-backed command in the approved path. In the feature
   tables, `tightbeam` denotes the same package's absolute-path CLI; the
   endpoint precedence checks above apply to every call.
3. Run the complete scripted smoke once on a disposable clone:

   ```sh
   TIGHTBEAM_BASE_DIR="$AREA_BASE" \
   TIGHTBEAM_SMOKE_AREAS=all \
   mix run --no-start scripts/feature_smoke.exs
   ```

   The canonical wrapper on the selected test host owns checkout execution and
   toolchain setup. `--no-start` is required because the gateway is already
   running against that clone. The script defaults to every area when
   `TIGHTBEAM_SMOKE_AREAS` is unset.
4. Run the manual-only rows in each feature runbook against that area's fresh
   clone. A standalone rerun sets exactly one area, for example
   `TIGHTBEAM_SMOKE_AREAS=telemetry`, and uses a new copy of the same preserved
   migrated database. Do not run the migration procedure again to rerun an
   area.
5. Record the exact package/source SHA, host, harness and model per leg, area,
   commands, result, and every incomplete prerequisite in the scorecard. Keep
   E2E results distinct from source CI and static validation.

The script groups its HTTP-driven checks as follows. The linked runbooks own
additional CLI procedures that need an operator, an active turn, or genuine
host/provider state.

| Area | Select with `TIGHTBEAM_SMOKE_AREAS` | Script checks | Runbook |
|---|---|---|---|
| Provider and runtime | `provider` | Local deployment, identity and onboarding surfaces | [provider-runtime.md](provider-runtime.md) |
| Work and routing | `work` | Facts/config reads, item/assignment reads, dispatch, body and direct-owner patch/clear | [work-routing.md](work-routing.md) |
| Decisions and assignments | `decisions` | Effort check-in, review loop, cannot-proceed handoff | [decisions-assignments.md](decisions-assignments.md) |
| Telemetry | `telemetry` | Breathing, execution map/selection, and durable Topline lifecycle/list | [telemetry.md](telemetry.md) |
| Artifacts | `artifacts` | Gate enforcement, real-turn artifact carrier, and structured `content_not_captured` with matching metadata; this does not cover positive captured-content retrieval | [artifacts.md](artifacts.md) |

## 0.1.9 must-land coverage

This ledger maps Mike's 43 must-land items to one manual row or states why the
item has no operator-facing E2E path. The linked rows give the concrete action
and pass condition. Source-CI rows are covered by the unchanged
`scripts/verify_mix.sh` merge checks; they do not invoke the new feature-smoke,
real-snapshot migration or aggregate procedures.
The artifacts area also checks the truthful uncaptured result for its newly
registered fixture. No source-backed capture lifecycle or fixture is available
for positive content-fetch coverage, so this check does not claim one.

| Must-land | E2E coverage |
|---|---|
| Completion handoff | [Completion handoff](decisions-assignments.md#completion-handoff). |
| Surrender replacement | Source CI verifies the retired terminal `surrender` protocol is rejected; the [typed `cannot-proceed` replacement](decisions-assignments.md#cannot-proceed-replacement) checks the supported route and opener handoff. |
| Wake cancellation history | [Wake cancellation history](work-routing.md#wake-cancellation-history). |
| Notice batching | [Notice batching](work-routing.md#notice-batching); requires an already selected disposable recipient lane or is recorded incomplete. |
| Parent reactivation | [Completion handoff](decisions-assignments.md#completion-handoff) checks the parent's real child notice and resumed turn. |
| Wake delivery | [Wake delivery](work-routing.md#wake-delivery-options). |
| Deterministic liveness | [Progress receipts](decisions-assignments.md#liveness-from-progress-receipts) and [physical breathing](telemetry.md#deterministic-liveness). |
| Editable work-item body | [Editable work-item body](work-routing.md#editable-work-item-body). |
| Session connect | [Session connect](provider-runtime.md#session-connect). |
| Harness switching in Firehose (`setHarness`) | [Firehose harness switch](provider-runtime.md#firehose-harness-switch). |
| Agent control 1: replace my unread messages | [Replace unread messages](work-routing.md#replace-unread-messages). |
| Agent control 2: see a worker's queue | [Worker queue summary](telemetry.md#worker-queue-summary). |
| Agent control 3: stop and redirect | [Stop and redirect](decisions-assignments.md#stop-and-redirect). |
| Agent control 3: stop a running turn | [Stop a running assignment turn](decisions-assignments.md#stop-running-turn). |
| Landing watcher: CI-finished fact | [Landing watcher](work-routing.md#landing-watcher). |
| No completion while blocked | [Completion while blocked](decisions-assignments.md#completion-while-blocked). |
| Agent control 4: failed means failed, and redeliver | [Failed turn and redelivery](decisions-assignments.md#failed-turn-remains-failed-and-can-be-redelivered). |
| Agent control 5: switch a seat with work queued | [Firehose harness switch with queued work](provider-runtime.md#firehose-harness-switch). |
| Agent control 6: advancing query plus owner rail | [Advancing query and owner rail](telemetry.md#advancing-query-owner-rail). |
| Flaky test fixes | Source-CI only: flakiness is established by repeated canonical Linux/macOS suite results, not a new operational scenario. |
| Crash fix A: index `turns.messageId` | Source-CI only: this storage-index repair has no independent public action; migration and database inspection stay under the separately authorized rehearsal. |
| Crash fix B: lanes recover after a manager restart | Source-CI only: the restart/race fixture is internal supervision behavior and is not exposed as an operator command. |
| Retirement cleanup on the original host | [Retirement cleanup](provider-runtime.md#retirement-cleanup-on-the-original-host). |
| Model neutrality | Run the same aggregate and each standalone feature area for every authorized harness leg; compare behavior and pass conditions, not model-specific wording. |
| Philosophy-first guidance refactor | Guidance-only: prose ordering has no separate product operation to exercise. |
| Credential backoff | [Credential backoff](provider-runtime.md#credential-backoff); it requires a provider-approved reversible test fixture or is incomplete. |
| Sign-in recovery wake (from Main) | [Sign-in recovery wake](provider-runtime.md#sign-in-recovery-wake). |
| Simplify ownership module | Source-CI only: this is an internal refactor with no separate observable operation. |
| Stuck-turn settlement | [Stale-turn settlement](decisions-assignments.md#stale-turn-settlement). |
| Timeout diagnostics | [Timeout diagnostics](decisions-assignments.md#timeout-diagnostics). |
| Error fidelity | [Error fidelity](decisions-assignments.md#error-fidelity). |
| GitHub #23 no-op rows | Source-CI only: these are internal supervision watermark/audit rows; no public command can safely drive or inspect the scheduler tick. |
| Topology | [Canonical session topology](work-routing.md#canonical-topology) distinguishes current parent from spawn provenance. |
| Visitor identity | Source-CI only: the 0.1.9 CLI has no supported visitor-principal creation route for a disposable operator fixture. |
| Deploy safety, unrolled | The staged selector and rollback remain a [release runbook](../../UPGRADE.md#release-upgrade-sequence); its package-selector behavior is source-CI tested, and this E2E card does not install a release. |
| Release CI exact-commit check (from main) | Source-CI only: the required release workflow checks the pushed source SHA; a manual E2E command cannot establish that CI property. |
| GitHub #15 retire test | [Retirement cleanup](provider-runtime.md#retirement-cleanup-on-the-original-host) checks the original-host outcome on a disposable session. |
| Idle cleanup skips standing seats | Source-CI only: the scheduled supervisor's standing-seat exclusion uses controlled clock/process fixtures unavailable through the public CLI. |
| Orchestrator model ring-down | [Orchestrator model defaults](work-routing.md#orchestrator-model-defaults) reads the choice from the target host's own catalog. |
| Orchestrator-by-default staffing rule | Guidance-only: staffing defaults are instructions, not an independent user operation. |
| Codex Guardian off by default | [Codex Guardian default](provider-runtime.md#codex-guardian-default). |
| Process facts wake again | [Landing watcher](work-routing.md#landing-watcher) observes two real scoped process facts and both resulting wakes. |
| Sentinels and landing queue | [Sentinel lifecycle](provider-runtime.md#sentinel-lifecycle), [landing watcher](work-routing.md#landing-watcher), and required source-CI merge-group checks cover the separate runtime and queue behaviors. |

Do not wire this matrix or any E2E invocation into CI. The corrected bot PR
runs the unchanged source suite through the canonical wrapper; Mike calls the
separate real-host E2E run.
