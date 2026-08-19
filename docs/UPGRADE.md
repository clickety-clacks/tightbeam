# Upgrading a running instance

Stop it, back it up, swap the code, start it, and verify the durable rows.
Most upgrades are ordinary restarts because the ledger is durable. Tightbeam
0.1.8 also carries one exact migration: `model-identity-v1` (0.1.7) to
`operator-decision-requests-v1` (0.1.8). The gateway refuses every other old
stamp. It never infers a schema from stored DDL.

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

Back up **every registered base directory**. Each host owns its own `state.db`.
The primary database does not migrate a satellite database for it. A macOS host
whose registry entry says `baseDir=/Users/mike/.tightbeam`, for example, must be
stopped, backed up, upgraded, and started on that host.

## The supported 0.1.7 to 0.1.8 migration

Let the 0.1.8 gateway perform this migration at first boot. Do not edit the
stamp or issue manual `ALTER TABLE` statements.

The migration accepts exactly one source stamp:

```text
model-identity-v1 -> operator-decision-requests-v1
```

It runs in one SQLite transaction. It rebuilds `decision_requests` with the
0.1.8 operator-request constraint and `ruledViaSessionKey` column, copies every
0.1.7 request, sets the new field to `NULL`, creates the exact 0.1.8 indexes,
and updates the stamp last. The 0.1.7 and 0.1.8 `wakes` table definitions are
identical, so the migration does not rewrite wakes; it checks that their row
count is unchanged in the same transaction. Any failure rolls back the table
rename, copied rows, indexes, and stamp together.

An unstamped database, an unknown stamp, an intermediate development stamp, or
more than one stamp is a refusal. Keep that database in place and use a build
that recognizes its exact stamp. Do not rename it away and silently create an
empty org.

## Dedicated 0.1.7 to 0.1.8 upgrade E2E

Run this check separately from the cold-install matrix. Use a consistent backup
of a real 0.1.7 `state.db`; never point the test at the live org.

The release gate covers both platforms in two parts:

- Run the full row-preservation proof once on Linux with the largest real
  fixture. The migration logic is shared across release packages.
- Run a macOS install/start smoke on a fresh copy of the same pre-upgrade
  fixture. This covers the different package path, launch mechanism, and
  registered `baseDir`. It does not repeat the large row-hash proof.

This two-platform rule applies because satellite bases migrate independently.
It is not a second implementation test.

### Linux: full preservation proof

Choose isolated paths and an unused port before the run:

```sh
upgrade_root="$(mktemp -d)"
upgrade_base="$upgrade_root/base"
upgrade_db="$upgrade_base/state.db"
upgrade_prefix="$upgrade_root/prefix"
upgrade_port=12384
```

1. Copy the consistent 0.1.7 backup into an isolated base directory. Record the
   source file digest. Do not copy `-wal` or `-shm` files from a running org.
2. Install the verified 0.1.7 package into an isolated npm prefix. Start it on
   an unused port against the fixture. Require `/version` to report 0.1.7, then
   stop it cleanly.
3. Before installing 0.1.8, require this exact stamp and record the populations:

   ```sh
   sqlite3 -readonly "$upgrade_db" "SELECT shape FROM schema_stamp;"
   sqlite3 -readonly "$upgrade_db" \
     "SELECT 'work_items',count(*) FROM work_items UNION ALL
      SELECT 'assignments',count(*) FROM assignments UNION ALL
      SELECT 'decision_requests',count(*) FROM decision_requests UNION ALL
      SELECT 'wakes',count(*) FROM wakes;"
   ```

4. Hash the complete commissioned rows in deterministic order. Select only the
   0.1.7 request columns so the new nullable column does not change the digest:

   ```sh
   request_columns='id,kind,raiserId,raiserSessionKey,ownerUserId,assignmentId,expecterSessionKey,expecterUserId,lineageRung,effortGeneration,deadlineWakeId,raisedAt,deadlineAt,statuteName,actionKey,question,options,context,status,decision,rationale,ruledBy,ruledAt,rulingFactId,consumedAt,parkWakeId,withdrawnBy,withdrawnReason,withdrawnAt'
   sqlite3 -readonly "$upgrade_db" ".mode quote" \
     "SELECT $request_columns FROM decision_requests ORDER BY id;" | shasum -a 256
   sqlite3 -readonly "$upgrade_db" ".mode quote" \
     "SELECT * FROM wakes ORDER BY wakeId;" | shasum -a 256
   ```

5. Install the verified 0.1.8 package into the same isolated prefix. Start the
   gateway once against the same base and port. This boot performs the
   migration. Do not run a separate SQL migration command.
6. Require `/version` to report the expected 0.1.8 build and source SHA. Then
   require all of these database checks:

   ```sh
   sqlite3 -readonly "$upgrade_db" "SELECT shape FROM schema_stamp;"
   sqlite3 -readonly "$upgrade_db" "PRAGMA quick_check;"
   sqlite3 -readonly "$upgrade_db" "PRAGMA foreign_key_check;"
   sqlite3 -readonly "$upgrade_db" \
     "SELECT count(*) FROM pragma_table_info('decision_requests')
      WHERE name='ruledViaSessionKey';"
   sqlite3 -readonly "$upgrade_db" \
     "SELECT count(*) FROM sqlite_master
      WHERE type='index' AND name='decision_requests_operator_open';"
   sqlite3 -readonly "$upgrade_db" \
     "SELECT count(*) FROM sqlite_master
      WHERE type='table' AND name='decision_requests_model_identity_v1';"
   ```

   PASS means the stamp is `operator-decision-requests-v1`, `quick_check` is
   `ok`, `foreign_key_check` prints nothing, the new column and index counts are
   `1`, and the temporary-table count is `0`.
7. Repeat the four population counts and both deterministic hashes. Require
   exact equality with step 3 and step 4. Start the 0.1.8 gateway a second time
   and require the same counts and hashes again; this proves an ordinary restart
   does not replay the migration.

### macOS: package and base-directory smoke

Use a fresh copy of the same pre-upgrade fixture, the Darwin package, an unused
port, and the host registry's real base-directory convention. Stop only the
isolated test gateway.

1. Boot the fixture once with the 0.1.7 Darwin package and require `/version`
   0.1.7. Stop it cleanly.
2. Install the 0.1.8 Darwin package into the same isolated prefix and restart
   against the same base directory.
3. Require `/version` to report the expected 0.1.8 build and source SHA.
4. Require the new stamp, unchanged `work_items`, `assignments`,
   `decision_requests`, and `wakes` counts, `PRAGMA quick_check = ok`, no foreign
   key failures, the new column and operator index, and no migration temporary
   table.

Do not run the TARS or Shrdlu cold-install custody matrix again. This is the
upgrade-preservation check that matrix did not cover.

## The cycle

```sh
# 1. stop, and let it drain — SIGTERM is enough
kill -TERM <gateway pid>          # verified: this runs prep_stop, which drains
# 2. swap the code
git -C <checkout> pull            # or checkout the tag you are deploying
mix deps.get && mix compile
# 3. start
# 4. verify — the four checks below
```

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

The historical measurements above used two boots of the same code against one
file. They do not prove the 0.1.7 to 0.1.8 migration. Use the dedicated E2E in
this document for that release transition; do not substitute a cold install or
an ordinary restart result.
