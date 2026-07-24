# CLI lane handoffs

## Clause 11 — direct dependency limit

`cli/Cargo.toml` is outside the CLI lane's owned paths and still declares
`libc = "0.2"`. The dependency is used directly by `cli/src/contain.rs` for
process-group and signal operations, which is also outside this lane. A
Cargo/containment owner must either replace those calls using only the two
dependencies permitted by `cli-rust-v1.md` and remove `libc`, or obtain and
record a governing-spec amendment that permits `libc`.

## Clauses 1, 57, and 66 — executable-level `rail-exec` command

`cli/src/main.rs` is outside this lane's owned paths and intercepts `rail-exec`
before `args::parse`, so the parser cannot make that command produce the
TypeScript reference's canonical unknown-command error. The executable owner
must remove the `rail-exec` interception from `main.rs` (and adjudicate the
resulting `contain` module reachability), then add a real-binary test that runs
`tightbeam rail-exec` and asserts the exact canonical unknown-command stderr
and exit status 1.

## Mandatory clippy gate — unreachable legacy `init` and `probe` modules

`cli/src/main.rs`, `cli/src/ceremonies.rs`, and `cli/src/probe.rs` are outside
this lane's owned paths. The v1 command surface intentionally does not expose
the later `init` and `probe` commands, but `main.rs` still compiles both legacy
modules. Removing the rejected discarded-function-pointer suppression from
`dispatch::run` exposes dead-code errors throughout those modules under
`cargo clippy -- -D warnings`. The executable/module owner must stop compiling
the non-v1 modules (while preserving the v1 `setup` and `assimilate` ceremony
paths), or obtain a governing-spec amendment that makes their behavior
reachable; lint suppression or unused function-pointer references are not an
acceptable close.

## Tagged CLI integration suite versus clauses 1, 10, 14, 19, 36, 57, and 66

`test/cli_integration_test.exs` is outside this lane and requires
`.tightbeam-session` identity discovery plus assignment, producer, and work-item
verbs. Those expectations directly conflict with the governing v1 spec's
TypeScript-normative discovery, exactly-one explicit identity, canonical command
set, and no-new-verbs requirements. The spec/test owner must adjudicate the
source of truth and then either update the tagged integration suite to the v1
CLI surface or amend `cli-rust-v1.md` before those tests can be made compatible.

# conformance-smoke handoffs

Only the independent verifier's ten legitimate external/spec blockers remain. Every
lane-closeable residual was removed from this handoff and is covered by the executable
corpus runner.

| Clause(s) | Exact blocker | Required cross-lane/spec change |
|---|---|---|
| #4 | Copying the corpus and invoking the same ExUnit loader is not a second self-tuning consumer. | The self-tuning/generated-rail owner must load `identity/conformance/` through its real validator and run the unchanged corpus. |
| #7, #147, #155 | The governing spec makes forbidden-substitution intent advisory and names containment only as partial coverage. | Define an enforceable observable if this advisory intent is to become a mechanical acceptance check. |
| #21 | §1.2 says every fixture in a green class is green, while A1 requires green C2/C3 classes containing three `pending-unhomed` fixtures. | Reconcile the governing spec's class-green rule with A1/taxonomy. |
| #39 | The locked `world.adjudicate = {session, hold}` shape conflicts with the actual owner API, which requires an episode/action request. | Reconcile the world shape with the authorized owner verb; direct SQL remains forbidden. |
| #43, #116 | The exact public `rail_step/4`/`window_start` seam named by the spec is not exposed; the available public consumer is `Supervision.evaluate/5`. | Expose the pinned rail-step/window input contract. The public consumer's nil/no-write and duplicate end states are covered here. |
| #60 | Canonical fresh-identity bootstrap is owned by identity/archetype code and canonical material outside this lane. | The identity owner must supply the fresh-bootstrap artifact proof. |
| #133 | A sandbox profile-application refusal cannot be deterministically caused by fixture script content. | Expose Q3's deterministic profile-apply-failure hook; `contained-refused` remains case-level `pending-runtime`. |
| C6 `escalation-return-dispatch` self-park | The dispatch actor opens/re-returns the decision request, but neither `Dispatch.dispatch/3` nor `Escalation.escalate/4` schedules the live raiser's verb-edge self-park required by enforcement-smoke-set-spec C6. This lane owns only the corpus/runner. | The escalation/dispatch owner must add the verb-edge self-park, after which this fixture must assert its wake row and target. |
| C7 `schedule-then-check` recovered race | `Supervision.park_escalation/3` schedules/stores `parkWakeId` but has no post-schedule decision-status read, cancellation, or no-replay cursor. Public seams prove pre-ruled/no-park and later-ruling/ordinary-wake, but cannot produce the required “ruling lands between schedule and recovered check” branch because the check does not exist. | The supervision/escalation owner must add the wake-first recovered-status check and cancellation/no-replay behavior from mechanism r11; then replace the partial executable proof with the exact race assertion. |
| C7 `scheduled-wake-suppression` r21 self-wake branch | `Supervision.turn_end_schedule/0` exposes the Flynn-ratified r21 order, but `rail_step/5` still returns `:fallthrough` when `Wakes.self_pending_count/2 > 0`, bypassing `:rail_enforcement` before the named `:pending_wake_gate`. The pending fixture executes and records this mismatch. | Remove the internal self-wake bypass from `rail_step/5`; all pending wakes must be handled only by the later `:pending_wake_gate` slot. Then flip the fixture assertion from the recorded mismatch to `{:acted, :rail_remedy}`. |
| Required full-suite proof after merging `main` | `mix test test/conformance_test.exs` reaches the Cap producer actor, but merged commit `5ca6728` makes `Producers.execute/4` fail with `host-fail: producer process group unavailable`. The canonical independent test `mix test test/producers_test.exs:65 --trace` fails waiting for the same producer job to reach `done`, so this is not a conformance-fixture surrogate or assertion defect. | The producer owner must repair the host process-group launch/verification contract on eezo. Keep the conformance Cap actor's real producer execution; do not weaken it to accept a host failure. |

## CLI v1 clippy gate — unowned retired ceremony and containment code

The ratified CLI surface removes CLI-side `init` and `setup`, so the real
implementations still compiled from unowned `cli/src/ceremonies.rs` are now
unreachable. `cargo clippy --manifest-path cli/Cargo.toml -- -D warnings`
reports dead code for `setup`, `init`, their helpers, and the `InitArgs` /
`SetupArgs` types that `ceremonies.rs` still imports. The same gate reports an
independent `clippy::collapsible-if` finding in unowned
`cli/src/contain.rs:444`. The executable/ceremony owner must stop compiling and
delete the retired init/setup code and its argument types, and the containment
owner must apply the clippy-prescribed equivalent conditional rewrite. This CLI
lane cannot truthfully close the requested clippy gate without modifying files
the assignment explicitly forbids.
