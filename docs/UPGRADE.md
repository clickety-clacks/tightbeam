# Upgrading a running instance

Stop it, swap the code, start it, update every satellite CLI, then check four
things. There is no upgrade
machinery and none is needed — the ledger is durable, so a restart is an
ordinary event. What follows is what the stop actually does, established by
running it rather than by reading `application.ex`.

If the gateway is service-managed, installing a new package only swaps the
executable on disk; it does not restart the running process. After the package
install, restart the service before performing the checks below. On Linux:

```sh
sudo systemctl restart tightbeam.service
systemctl is-active tightbeam.service
```

Everything below was measured on 2026-07-26 against a real `state.db` with work
genuinely in flight.

## Take a backup first

`sqlite3 "$TIGHTBEAM_BASE_DIR/state.db" ".backup '$DEST/pre-upgrade.db'"` — safe
while running, and the restore is already proven. See **[BACKUP.md](BACKUP.md)**
for the procedure and, more importantly, for what `state.db` does *not* cover
(`gateway.json` especially — losing it rotates the org token).

## The cycle

```sh
# 1. stop, and let it drain — SIGTERM is enough
kill -TERM <gateway pid>          # verified: this runs prep_stop, which drains
# 2. swap the code
git -C <checkout> pull            # or checkout the tag you are deploying
mix deps.get && mix compile
# 3. start
# 4. update every registered satellite CLI and retain the per-host readback
# 5. verify — the four checks below
```

## Update every registered satellite CLI

Run this required stage with the CLI from the gateway package that you just
started:

```sh
tightbeam update-clients --as-user <adminUserId>
```

The command reads the registered CLI version from every satellite host. Before
it replaces an outdated CLI, it also reads `uname -sm` and derives that host's
target. It copies the running CLI only when the satellite target matches the
gateway host target. It refuses a cross-architecture replacement instead of
installing an incompatible binary.

Treat the command output as the fleet readback. Retain every per-host line with
the upgrade evidence. A complete successful readback has one
`already current (<version>)` or `updated (<old-version> -> <version>)` outcome
for every registered satellite. Any missing host, `incompatible`, `unreachable`,
`timed out`, `question failed`, `target check failed`, or `refused` outcome
stops the upgrade.

For an incompatible host, install the matching target package from the proved
release set at that host's registered CLI path. Verify the package against the
release `SHA256SUMS`, then run `update-clients` again and retain the new per-host
readback. Do not bypass the target refusal by copying the gateway host binary.

A gateway rollback includes the same stage. Run `update-clients` from the
restored gateway package, require every satellite to report the restored
version, and retain that rollback readback with the rollback evidence.

## What the stop actually does

`Application.prep_stop/1` sets a `draining` flag and then waits, polling every
250ms, for turns in `status = 'running'` to clear. Budget is
`:drain_timeout_ms`, **default 90s**.

While draining, `SessionLane` claims nothing new (`session_lane.ex:161`), so the
drain is not chasing a moving target — the set of running turns only shrinks.

Measured, all four with real rows:

| what was in flight | what happened |
|---|---|
| a turn that **finished** 1.5s into a 20s budget | `prep_stop` returned after **1544ms**, not the full budget. Turn ended `delivered`, and boot recovery never touched it |
| a turn that **never finished**, 3s budget | `prep_stop` waited the full **3077ms**, then gave up. Turn became `failed_unknown` at the next boot |
| a **queued** turn behind it | stayed `queued` across the stop and the restart — it simply runs after |
| a **pending wake** | still pending after the restart |

So the drain buys exactly one thing: **a turn that finishes inside the budget
completes normally instead of dying.** That is worth waiting for. Nothing else
in the list needs the drain — queued turns and wakes are durable rows and
survive either way.

### Graceful vs. kill, concretely

The ungraceful path is already understood: boot recovery terminalises orphaned
turns as `failed_unknown`, and the agent is told its side effects are
unknown-not-undone. Against that baseline, a graceful stop adds:

- **In-flight turns that finish in time end `delivered`** rather than
  `failed_unknown`. This is the whole benefit.
- **No `dirty_exit` event** at the next boot. Measured: 0 after a graceful stop.
  A kill leaves the prior epoch unstamped, and the next boot then logs
  `dirty_exit` with subject `epoch:<n>` — also measured, by opening an epoch,
  leaving it unstamped, and booting again.

And that is all it adds. If nothing is running, a kill and a graceful stop leave
the database in the same state.

### Two things that will mislead you

**A "clean" shutdown does not mean nothing was lost.** The clean-shutdown stamp
is written after the drain regardless of whether the drain succeeded. Measured: a
drain that timed out with a turn still running *still* recorded a clean shutdown,
and that turn *still* became `failed_unknown`. So `dirty_exit` absence proves the
process exited in an orderly way — not that no work died. Count
`failed_unknown` (check 3 below); do not infer it from the epoch.

**The drain can complete instantly and tell you nothing.** `drain_until/1` wraps
its count query in a catch-all that reads *any* failure as zero running
(`application.ex:134-135`). Measured: with the DB stopped, a 30s budget and a
turn genuinely `running`, `prep_stop` returned in **0ms**. If the database is
unreachable when you stop — disk full, file moved, DB process already down — you
silently get the kill outcome while believing you drained. If a stop returns far
faster than the work in flight would explain, treat it as a kill and check
`failed_unknown`.

## Verify, after starting

1. **It booted.** `curl -s localhost:<port>/version` returns.
2. **The prior shutdown was orderly:**
   ```sh
   sqlite3 state.db "SELECT epoch, cleanShutdownAt FROM boot_epochs ORDER BY epoch DESC LIMIT 3;"
   ```
   The epoch you just stopped should have a `cleanShutdownAt`; the new one is
   open. A `dirty_exit` row in `lifecycle_events` means it was not orderly.
3. **Count what the restart cost you** — this is the check that matters, and the
   one the epoch table will not tell you:
   ```sh
   sqlite3 state.db "SELECT count(*) FROM turns WHERE status = 'failed_unknown';"
   ```
   Compare against the pre-upgrade number. Any increase is turns that were
   in flight and did not finish. They are **never auto-retried** — retry is the
   sender's decision — so anything that mattered has to be re-asked.
4. **Queued work is moving.** `SELECT count(*) FROM turns WHERE status='queued';`
   should fall as lanes pick it up. If it does not, the lanes are not claiming.

## What does NOT survive the restart

- **The in-flight turn, if it outlasts the budget.** `failed_unknown`, terminal,
  never auto-retried.
- **Harness processes.** Adapters exit on stdin EOF, so stopping the gateway
  reaps them — including remote ones over ssh. They are respawned on demand;
  sessions are re-adopted by `session/load`, and where re-adoption fails the
  substrate appends a visible marker at the reset point rather than pretending.
- **The model's context.** The projection store is a one-way cache of the
  harness transcript, not the transcript. A session resumed after a harness
  process dies starts from the harness's own state, or fresh.
- **In-memory caches**, all rebuilt at boot: the derived model catalog
  (re-derived, so the first spawn after an upgrade waits for it), rules and rails
  (reloaded — and **bad law stops the boot**, which is the intended fail-closed
  behaviour, not a broken upgrade), lanes, and adapter processes.
- **Startup cost is paid again**, measured earlier: ~120ms adapter boot, ~2s per
  `session/new`, plus a one-time ~9.5s gate probe on the first railed adapter
  boot per harness+host. Budget roughly ten seconds before the first agent is
  responsive, not milliseconds.

Durable and unaffected: work items, assignments, attests, the turn ledger,
wakes, decision requests, events, roles, artifacts — everything in `state.db`.

## What was verified by doing, and what was not

Run and observed, on a real `state.db`: the drain returning early on a finished
turn (1544ms of a 20000ms budget); the drain waiting out its budget and the turn
becoming `failed_unknown` (3077ms of 3000ms); queued turns and pending wakes
surviving a stop and restart; zero `dirty_exit` after a graceful stop; an
unstamped epoch producing `dirty_exit` at the next boot; the clean stamp written
despite a timed-out drain; and the catch-all returning in 0ms with the DB down.

Run and observed on a REAL GATEWAY (scratch org, port 11977, full stop → start →
stop): `kill -TERM` runs `prep_stop` — the process exited in 2s and the epoch
came back stamped, which is the whole basis for "SIGTERM is enough". The restart
opened a fresh epoch with no `dirty_exit`, and all four checks below returned
what this document says they return, including `/version` answering
`{"adapters":{},"protocolVersion":1,"server":"tightbeam"}`.

**Not verified:** running two *different* code versions against one `state.db`. The
"swap the code" step is `git checkout` plus a recompile and touches nothing the
database sees, so the restart half was exercised as two boots of the same code
against one file. A migration-bearing upgrade is a different question and this
document does not cover it — schemas are created additively at boot
(`ensure_schema`), and no destructive migration path exists to describe.
