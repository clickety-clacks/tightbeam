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
  0.1.9 package as the gateway under test. Configure it for the disposable area
  base; do not let `PATH` select an unrelated installed CLI.
- Start the migration rehearsal from an operator-supplied, verified copy of a
  real 0.1.8 `state.db`. Do not copy `gateway.json`, provider credentials,
  harness homes, or identity state from the source base.
- Provision any feature-smoke harness credentials separately on the permitted
  test host through its approved onboarding route. Do not onboard from a smoke
  script or copy credentials from another base. Keep tokens, credential bytes,
  request bodies, and private database content out of scorecards and artifacts.
- If a check needs an incident, failed turn, pending placement, provider grant,
  or other real prerequisite that is absent, record it as `INCOMPLETE` with the
  missing prerequisite. Do not fabricate a success with synthetic state.

## Aggregate run

1. Read [`migration.md`](migration.md) and qualify the real 0.1.8 source copy.
   Run the 0.1.9 package against one isolated migration base exactly once.
   Stop it cleanly, save the migrated `state.db` and its non-secret manifest,
   and leave the source copy read-only. Do not continue if a stamp, integrity,
   foreign-key, version, or unexplained row-count check fails.
2. Provision a disposable feature-test base on the same permitted host with a
   fresh gateway descriptor and the host's already-authorized harness setup.
   For each area, clone that base into a new directory while the gateway is
   stopped, then replace its `state.db` with a fresh copy of the preserved
   migrated database. This keeps the test host's authorized setup while leaving
   source-base credentials and configuration behind. Use a distinct port and
   base for each run. Start the verified 0.1.9 gateway on that clone with
   `TIGHTBEAM_BASE_DIR`, `TIGHTBEAM_PORT` and `TIGHTBEAM_ADVERTISED_URL` set
   explicitly, and keep it running for the scripted and manual checks:

   ```sh
   gateway_bin="/path/to/verified-0.1.9/tightbeam/bin/tightbeam-gateway"
   TIGHTBEAM_BASE_DIR="$AREA_BASE" \
   TIGHTBEAM_PORT="$AREA_PORT" \
   TIGHTBEAM_ADVERTISED_URL="ws://127.0.0.1:$AREA_PORT" \
   TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS=250 \
   "$gateway_bin"
   ```

   In the feature tables, `tightbeam` denotes the same package's absolute-path
   CLI. Run each call with `TIGHTBEAM_BASE_DIR="$AREA_BASE"` so it targets this
   clone.
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
| Telemetry | `telemetry` | Breathing, execution map/selection, durable Topline lifecycle and roster | [telemetry.md](telemetry.md) |
| Artifacts | `artifacts` | Gate enforcement, real-turn artifact carrier and captured-content fetch | [artifacts.md](artifacts.md) |

## 0.1.9 feature coverage ledger

Use this ledger to keep the manual rows attached to the public behavior they
exercise. The command names are the shipped 0.1.9 CLI spellings.

| Public feature | Area and check |
|---|---|
| Wake assignment binding, dependency predicate, after-turn continuation, queued replacement, and delivery class | [Work and routing](work-routing.md): run each delivery form against a disposable held assignment and read the durable wake/turn rows. |
| Spawn attached to a work item and assignment `--succeeds` dependency | [Work and routing](work-routing.md): create a disposable parent/child chain and verify the exact work and predecessor links. |
| Work-item priority, metadata/body updates, and direct delivery owner | [Work and routing](work-routing.md): patch and read back values, including setting and clearing the direct owner. |
| Condition payload and default priority | [Work and routing](work-routing.md): publish/read a scoped fact payload and set/read the org's test-only priority default. |
| Session PO association and session reparenting | [Work and routing](work-routing.md): use disposable sessions and a sole open assignment; verify the resulting exact association/parent. |
| Assignment stop, reopen, repair, commit-ref correction, and stale-turn settlement | [Decisions and assignments](decisions-assignments.md): use only a deliberately created disposable turn or genuine failure and verify the terminal/readback state. |
| Ask, answer, return, and decision-request readback | [Decisions and assignments](decisions-assignments.md): create two disposable requests, answer one, return the other, and read both. |
| Breathing; execution-map roster and selection | [Telemetry](telemetry.md): script checks an idle item, its roster row, and the exact scoped selection; manual rows cover active session/assignment targets. |
| Durable Topline reads, history, mutations, work/concern links, and placements | [Telemetry](telemetry.md): script covers the lifecycle; check placement resolution only when a natural pending placement exists. |
| Artifact producer binding, captured content, attest evidence/wait and content-unavailable behavior | [Artifacts](artifacts.md) and [decisions/assignments](decisions-assignments.md): script fetches and verifies captured bytes; manual rows check provenance and real evidence bindings. |
| Session connect, identity current/status/apply, provider onboarding variants | [Provider and runtime](provider-runtime.md): use disposable sessions and already-authorized test provider state; identity refresh requires a discardable test revision. |
| Kungfu setup, sentinel listing/configuration, harness process ledger | [Provider and runtime](provider-runtime.md): inspect read-only state, then exercise reversible changes on an isolated test gateway. |
| Harness health observation, resolution, review, evidence and promotion close | [Provider and runtime](provider-runtime.md): requires a genuine, redacted host incident and real review provenance; otherwise mark incomplete. |

Do not add this matrix or any E2E invocation to CI. CI establishes source
correctness; Mike calls the separate real-host E2E run.
