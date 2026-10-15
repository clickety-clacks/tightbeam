# Upgrading a running instance

## 0.1.8 to 0.1.9: follow this order

Expect downtime at the service restart: the gateway migrates its database on
first boot before it can answer `/version`, and a large database can take time.
Do not interrupt that migration or assume selecting old executable bytes can
reverse it.

Before each step that changes a production gateway, describe that exact step
to the user and wait for their explicit confirmation of the description. This
includes making a backup on the production host, staging or installing a
package, changing the selector or service, restarting and migrating the
database, re-assimilating satellites, and removing obsolete files. Name the
artifact and hash, affected paths and hosts, expected downtime, database
effect, and rollback limit as applicable. The original upgrade request is not
the confirmation. If the plan or target changes, describe it again and get a
new yes before acting; read-only inventory can proceed while waiting.

1. Identify the running build and every registered base directory. Take and
   verify a consistent backup of each base as described in
   [Take a backup first](#take-a-backup-first), including the non-database
   configuration named in [BACKUP.md](BACKUP.md). Check each copied database
   with `PRAGMA quick_check` and confirm the backup files are readable before
   selecting a new build.
2. Verify the target release package, `SHA256SUMS`, and
   `release-provenance.json`. For the package commands, follow the
   [stage/select instructions](../README.md#from-a-release-package) below the
   README's release-package heading; `stage` leaves the running build selected.
   If the service still starts an npm-installed executable, follow
   [the selector move](#moving-an-npm-installed-gateway-to-the-selector)
   for inventory and staging only at this step; its stop/configuration and
   start phases belong to steps 3 and 5 respectively.
3. Review [runtime overrides](#runtime-overrides-during-an-upgrade). At the
   authorized idle boundary, stop the 0.1.8 service through its service
   manager, then select the staged build and update the npm-based systemd
   unit or LaunchDaemon to the selector path. Keep the service stopped
   throughout step 4; do not restart or bootstrap it yet.
4. With the 0.1.8 gateway stopped, prepare every registered host before the
   first 0.1.9 start. Each item below is a gap between what 0.1.8 left on
   disk and what 0.1.9 accepts; skipping one stops agents from running.
   - **Satellite CLIs.** 0.1.9 signals old harness processes through each
     host's own `<base_dir>/bin/tightbeam`, and a 0.1.8 satellite CLI does not
     understand that command. Replace each satellite's
     `<base_dir>/bin/tightbeam` with `tightbeam/bin/tightbeam` from the same
     release, using the package for that satellite's platform
     (`darwin-aarch64` or `linux-x86_64`), verified against `SHA256SUMS`. Keep
     the old file beside it until the upgrade passes. A Linux gateway's
     `assimilate` cannot ship a macOS CLI, so copy it for a macOS satellite.
     Require `<base_dir>/bin/tightbeam --version` to report 0.1.9 on every host.
   - **Credential links.** 0.1.8 placed harness credentials in each
     `<base_dir>/homes/<host>/<harness>/` as symbolic links into
     `<base_dir>/auth/`, for example `homes/<host>/codex/auth.json` and
     `homes/<host>/claude/.credentials.json`. 0.1.9 accepts only a regular
     file there and reports a linked credential as missing. On every host,
     check each of those two paths with `ls -l` without reading the file. For
     each one that is a link, remove the link and move the file it points to
     into its place, keeping its mode. Move it; do not copy it. A Codex
     subscription credential refreshes itself, and two copies diverge. Where a
     host has no usable credential, `tightbeam onboard openai|anthropic` on
     that host after the start is the supported alternative; it needs the
     user at each sign-in.
   - **Old harness process records.** A 0.1.8 harness process record lacks the
     identity file 0.1.9 requires before it signals a process, so at first
     start 0.1.9 fails to settle each record it finds and parks that harness
     on that host until the record resolves. Until a release settles these
     records itself, review them before the first start:

     ```sh
     sqlite3 -readonly <base_dir>/state.db "SELECT launchId, adapterKey, host, processGroupId FROM harness_processes WHERE resolvedAt IS NULL;"
     sqlite3 -readonly <base_dir>/state.db "SELECT adapterKey, requestedAt FROM harness_park_fences;"
     sqlite3 -readonly <base_dir>/state.db "SELECT id, harness, host, failureClass FROM harness_health_incidents WHERE state='open';"
     ```

     Retain this inventory. On each named host, confirm with
     `ps -A -o pid=,pgid= | awk '$2==<processGroupId>'` that each reviewed
     launch's group has no live process. A failed host check or missing or
     invalid group identity is not proof of absence. If a process is alive,
     stop it on that host first; do not settle its record while it is running.
     With the gateway still stopped, describe the exact launch IDs to settle
     to the user and get their yes. Replace the example IDs below with only
     those reviewed, confirmed-absent launches, quoting each as a SQL string:

     ```sh
     sqlite3 <base_dir>/state.db "BEGIN IMMEDIATE;
       UPDATE harness_processes SET state='exited',
         resolvedAt=CAST(strftime('%s','now') AS INTEGER)*1000,
         lastError='0.1.8 to 0.1.9 upgrade: process confirmed gone before first 0.1.9 start'
       WHERE launchId IN ('<reviewed-launch-id-1>', '<reviewed-launch-id-2>')
         AND resolvedAt IS NULL;
       COMMIT;"
     ```

     Read back those launch IDs and require them to be resolved as `exited`.
     Leave `harness_park_fences` untouched by this transaction. A fence can
     represent an independent open incident, including `rate-limit-dead`;
     process absence does not clear that incident or authorize unpark.
     At startup, 0.1.9 reconciles launch-only fences and deliberately retains
     fences for open rate-limit incidents. Preserve those parks; any incident
     resolution needs its own supported, owner-authorized action after its
     cause is resolved, not an upgrade-time fence deletion.
5. Only after every step 4 preparation is complete, start the 0.1.9 service
   through its service manager, using the selector procedure's separate
   [start phase](#start-after-pre-start-preparation) if the service was moved.
   The gateway performs the supported database migration on first boot; do
   not issue manual schema
   changes. On a large database the first process can exit once after the
   migration finishes, when the wake scheduler runs before the lane manager is
   up. The service manager restarts it and the second start serves normally.
   Expect one such restart; investigate a second.
6. Require `/version` to match the selected receipt's version and source SHA,
   verify the migrated database and important existing records, and complete
   the runtime checks below. Compare the retained process/fence/incident
   inventory with the current rows: reviewed obsolete launches are resolved,
   and valid incident parks remain in force. Do not require a global zero
   fence count or delete a fence to pass verification. Require turns on
   unparked, ready harnesses to move from `queued` to `running`; diagnose any
   remaining park by its launch or incident cause. If the gateway
   fails to boot or verification fails, stop and use the retained package and
   backup only after checking schema compatibility; an executable rollback
   does not undo migration.
7. For each registered satellite, [re-assimilate that host](#refreshing-satellite-clis)
   with its recorded destination and settings so its adapters and registration
   match 0.1.9. The CLI was already replaced in step 4; re-check its version.
8. After the service and satellites pass, follow
   [old-install cleanup](#remove-the-old-npm-installation). Remove only the
   verified obsolete npm package and links, then check that the service,
   operator shell, and satellites cannot load the stale CLI or gateway.
9. Complete the upgrade by bringing in the new guidance. Installing a release
   changes Tightbeam's code; it does not change the guidance agents follow.
   As soon as the gateway and satellites pass, tell the user that the upgrade
   is not complete yet, explain the steps below in plain words before starting
   any of them, and offer to begin. Do not wait to be asked, and do not report
   the upgrade as done before the last step. Have Main lead the user through it.

   1. **Relearn.** `tightbeam identity relearn` imports the release's version
      of every learned kungfu bundle and merges it with the org's identity.
      Before running it, explain what the release changes in the guidance.
   2. **Resolve conflicts with the user.** Where the org changed a file the
      release also changed, relearn stops. For each conflict, explain the
      release's intent and the org's current text, and let the user choose:
      keep one side, combine them, or abort. Never pick a side silently.
   3. **Publish.** Once every conflict is resolved, `tightbeam identity
      relearn --resolve` commits the merged identity; a relearn with no
      conflicts publishes on its own. From then on, newly started agents
      receive the new guidance.
   4. **Check what relearn skipped.** In 0.1.9, relearn keeps the org's copy
      of some files without comparing it with the release, and reports
      nothing:
      - the two starter files Tightbeam seeded when the org was created,
        `archetypes/default.toml` and `guidance/operating-model.md`;
      - any org file at a path the release itself ships, such as an org copy
        of `guidance/operating-manual.md`, which keeps overriding the
        release's file even when it is only an old snapshot.

      Bring this to the user's attention on every upgrade and offer a fix.
      List those files by comparing the identity repository's paths with the
      selected package's `priv/seed`, `priv/guidance` and the learned bundles'
      paths. For each one, show the difference between the org's copy and the
      release's version, say which org lines look deliberate, and offer to
      apply the release's version while keeping them, or to delete an
      override that is only an old copy. Publish only what the user chooses,
      through `tightbeam identity edit`. Relearn itself is expected to merge
      these files in 0.1.10.
   5. **Roll out to existing agents.** Publishing does not reach agents that
      are already running. `tightbeam identity apply --all` rewrites their
      Tightbeam-owned skill files and asks each to re-read them; it does not
      reload a running model's context. Explain this, get the user's yes,
      and run it at a moment that does not interrupt running turns.
   6. **Confirm.** `tightbeam identity status` must show no conflicts and no
      stale sessions.

   Restarting the gateway is not upgrade completion: without these steps the
   release's code runs with the previous release's guidance, and nothing warns
   about it until a new identity is published. If the user defers any step,
   record the deferral and name what remains out of date; do not report a
   deferred step as done.

## 0.1.8 to 0.1.9 database rehearsal

The canonical standalone E2E migration procedure is
[docs/e2e/0.1.9/migration.md](e2e/0.1.9/migration.md). It starts from a
verified copy of a real 0.1.8 database, lets the verified 0.1.9 gateway migrate
that copy once, and preserves the migrated result for separately runnable
feature checks. The aggregate order and feature-area runbooks are in
[docs/e2e/0.1.9/README.md](e2e/0.1.9/README.md). Do not use this rehearsal as
permission to point a command at a live base.

For source-lineage context, canonical tag `v0.1.8+1343` (build 1343,
`b2add64414b41606a713ed284abf01a0b4d125e6`, the release Gibson runs) writes
`operator-decision-requests-v1`, which current 0.1.9 names as a predecessor.
This is a verified reference lineage, not presumed provenance for a later real
0.1.8 database. The actual snapshot's manifest must establish its source tag,
build, package provenance, commit, and stored stamp. If the actual build or
stamp differs from this reference, stop for delivery's source-backed lineage
adjudication; a different stamp does not automatically reject every 0.1.8
release. See the [0.1.9 migration runbook](e2e/0.1.9/migration.md) for source
qualification. The `pi-harness-v1` stamp below is the historical terminal
stamp of the 0.1.8 package's own migration chain. It is not an accepted 0.1.9
source stamp, and this document does not claim that current 0.1.9 migrates it.

Keep each release in its own complete directory. Stage and verify the release
package before selecting it through `/opt/tightbeam/current`; the selection is
one atomic symlink replacement, and the previous build remains available.
Never update the package directory that a service may load on a restart. In
particular, do not use `npm install -g` for a service-managed gateway: it can
replace restart-loadable bytes before a running process is restarted.

For a package upgrade, first take the backup described below, then follow the
release-package stage/select steps in [README.md](../README.md). `stage` checks
the package SHA-256 against `SHA256SUMS`, binds the package version and source
commit to `release-provenance.json`, checks the CLI and gateway versions, and
records hashes for the staged files. It does not change `current`. After the
candidate is reviewed and the applicable upgrade is authorized, `select`
rechecks those files and switches `current` atomically. A failed or interrupted
stage cannot change the selected build. Incomplete temporary stage directories
are inert and are never selected.

### Moving an npm-installed gateway to the selector

Inspect the service's executable path and environment, resolve the executable's
symlink target, and read the running gateway's `GET /version` before changing
anything. Discover the npm installation with `npm prefix -g` and
`npm ls --global --prefix <recorded-prefix> --depth=0`, and match that prefix and
package to the service's resolved executable. The prefix may be `~/.local`,
`/opt/homebrew`, or another configured directory; do not assume the interactive
shell's npm or Tightbeam binary is the service's. If they differ, trace the
service's actual npm package and record its prefix before proceeding.

The `sha` in `/version` is a short source commit stamp, not an artifact digest.
Match the running build to its exact prior release package and provenance;
stage and retain that verified package for rollback. If the running stamp does
not match a verified package, stop until the prior build is recovered.
Executable bytes on disk can already differ from the running process.

Use the service-manager branch that applies, within this same upgrade order:

- **Linux — systemd:** inspect the unit with `systemctl cat tightbeam.service`
  and `systemctl show tightbeam.service -p ExecStart -p Environment`. Resolve
  the actual `ExecStart` executable, using `readlink -f` when it is a symlink.
- **macOS — LaunchDaemon:** inspect the installed
  `/Library/LaunchDaemons/com.tightbeam.gateway.plist` with `plutil -p` and the
  loaded job with `sudo launchctl print system/com.tightbeam.gateway`. Read
  `ProgramArguments` and `EnvironmentVariables`, including `PATH`; resolve the
  executable's symlink chain with `readlink`. Use the system LaunchDaemon from
  the [README plist](../README.md#macos--launchd), not a per-login LaunchAgent.

Stage the verified 0.1.9 target using the README's release-package commands.
For the 0.1.8 upgrade, this is the end of step 2: staging does not authorize
starting the selected build. The following phases keep service configuration
separate from the first 0.1.9 start.

#### Stop and configure; leave the service stopped

At step 3's authorized idle boundary, stop the old service through its service
manager before selecting the target or changing its executable path. Select
the staged target, then move the service to
`/opt/tightbeam/current/tightbeam/bin/tightbeam-gateway`, with
`/opt/tightbeam/current/tightbeam/bin` first in its `PATH`. Preserve its existing
service user, working directory, base directory, port, advertised URL,
credentials, remaining environment and logging settings.

- **Linux — systemd:** run `sudo systemctl stop tightbeam.service`. Change
  only the unit's executable path and `PATH`, preserving `User` and
  `WorkingDirectory`. For an `ExecStart` drop-in, clear the old value with an
  empty `ExecStart=` before setting the selector path. Run
  `sudo systemctl daemon-reload` and inspect the effective unit again. Leave
  the service stopped; do not run `start` or `restart` during preparation.
- **macOS — LaunchDaemon:** run
  `sudo launchctl bootout system/com.tightbeam.gateway` to unload and stop
  the old job. In the installed plist, change the gateway executable in
  `ProgramArguments` to the selector path and put the selected bin directory
  first in `EnvironmentVariables.PATH`. Preserve `UserName`, `WorkingDirectory`,
  other arguments, `RunAtLoad`, `KeepAlive` and other settings; retain the
  README's `root:wheel` ownership and mode `644`. Validate the edited plist
  with `plutil -lint`. Leave the job unloaded; do not bootstrap it yet.

Complete every pre-start item in step 4 of
[the 0.1.8 upgrade order](#018-to-019-follow-this-order), including satellite
CLIs, credential links and reviewed obsolete launch settlement, while the
gateway remains stopped. Selecting a build or reloading configuration is not
permission to skip this preparation.

#### Start after pre-start preparation

At step 5, after the preceding preparation and the user's authorization for
the start/migration, start only the applicable service:

- **Linux — systemd:** `sudo systemctl start tightbeam.service`.
- **macOS — LaunchDaemon:** load the configured job, then inspect it:

  ```sh
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.tightbeam.gateway.plist
  sudo launchctl print system/com.tightbeam.gateway
  ```

Wait for migration to finish before requiring the new `/version`. The old npm
files are not a verified rollback merely because they remain on disk. If the
running artifact's origin is unknown, its source stamp alone is insufficient.

After selection, `readlink /opt/tightbeam/current` identifies the selected
build. The running process may still report the previous version until its
service is started in the separate phase above. Start only after pre-start
preparation and the applicable idle and authorization boundary, then compare
`GET /version`'s `version` with the selected receipt's `version` and its short
`sha` with the prefix of `sourceCommit` in
`/opt/tightbeam/builds/<selected-build-id>/.tightbeam-stage.json`. Run
`/opt/tightbeam/current/tightbeam/bin/tightbeam-select select --root
/opt/tightbeam --build <previous-build-id>` to switch back to a retained build
after you confirm that it supports the current database schema. Selecting old
executable bytes does not reverse a SQLite migration or make an incompatible
schema safe.

### Refreshing satellite CLIs

For every registered satellite that received `<base_dir>/bin/tightbeam` from
`assimilate`, record its SSH destination, host name, base directory, and harness
selection. Once the new gateway is healthy and affected remote sessions are
idle, run the selected CLI with those same recorded values:

```sh
/opt/tightbeam/current/tightbeam/bin/tightbeam assimilate <ssh-dest> \
  --name <host-name> [--base-dir <path>] [--harness <names>] \
  --as-user <adminUserId>
```

Re-assimilation is
idempotent: it refreshes the satellite CLI and adapters without creating a
second host or carrying credentials. Check the command's actual result and the
remote `<base_dir>/bin/tightbeam --version`; require 0.1.9 before considering
that satellite upgraded. Do not infer that the gateway package changed a
remote CLI or re-onboard credentials as part of this step.

### Remove the old npm installation

Do this only after the selected gateway, migrated database, and satellite CLIs
have passed verification. Recheck the effective systemd `ExecStart` and `PATH`
or LaunchDaemon `ProgramArguments` and `EnvironmentVariables.PATH`, the
`/opt/tightbeam/current` target, and the operator shell's
`type -a tightbeam tightbeam-gateway`. Run `npm prefix -g` and reconcile it with
the old prefix recorded during the selector move; it may be `/opt/homebrew`,
`~/.local`, or another location. Use the prefix that actually owns the old
package, not a different current npm default. Inspect that exact package with
`npm ls --global --prefix <recorded-old-prefix> --depth=0` and record the targets
of its `tightbeam` and `tightbeam-gateway` links under `<recorded-old-prefix>/bin`.
Require the service to use
`/opt/tightbeam/current/tightbeam/bin/tightbeam-gateway` and the selected CLI to
report 0.1.9 before removing the old package.

Uninstall only the recorded old Tightbeam npm package from its recorded prefix
(`npm uninstall --global --prefix <recorded-old-prefix> <exact-old-package-name>`),
using only the permissions authorized for that installation. Remove any remaining
Tightbeam links under `<recorded-old-prefix>/bin` only after confirming that each
resolves into that old package; keep unrelated npm packages and links. Require
the recorded old package directory to be absent. If npm leaves it behind,
identify its exact contents and references before removing only that obsolete
directory. Recheck the loaded service configuration, shell executable resolution,
and each registered satellite's CLI version: no executable path used by the
service or agents may resolve to the removed package, and the selected gateway
and CLI must still answer as 0.1.9. Remove transient package-extraction directories
and downloads after their hashes and release receipt are recorded. Retain the
verified database/configuration backup and any deliberately retained selector
rollback build; name those retained items to the user instead of treating them
as trash.

## Runtime overrides during an upgrade

Review runtime overrides before replacing an existing installation. A persisted
override can select an older executable instead of a new adapter's bundled
runtime. Cleanup is conditional: keep intentional pins that the target supports.

1. Inventory every host and harness before the upgrade. As an admin, run:

   ```sh
   tightbeam host-env-list --as-user <adminUserId>
   ```

   Record each persisted `CODEX_PATH` and `CLAUDE_CODE_EXECUTABLE` value,
   including its host and harness. Separately inspect the gateway service's
   environment: systemd unit, drop-ins and environment files, or launchd plist.
   Record those values too; your interactive shell is not the service environment.
   Keep the record private if other environment entries contain secrets.

2. Record the current Tightbeam package/build, each effective harness executable
   path, exact version and SHA-256, and each installed ACP adapter's exact package version.
   Retain the prior runtime/package and service configuration for rollback.
   Check the target's release notes and compatibility evidence for those exact
   runtime/adapter combinations. Do not infer compatibility from a branch name
   or assume an upgrade refreshes every adapter.

3. Keep each intentional, supported pin. Remove an override only when you confirm
   it was temporary, is obsolete for the target, and its replacement is compatible.
   For a persisted host/harness overlay, use the matching command below; replace
   the placeholders with the recorded host and admin user:

   ```sh
   tightbeam host-env-unset --host <host> --harness codex CODEX_PATH --as-user <adminUserId>
   tightbeam host-env-unset --host <host> --harness claude CLAUDE_CODE_EXECUTABLE --as-user <adminUserId>
   ```

   These commands remove only the named overlay. They do not edit a service's
   environment. Remove an obsolete service override separately from its recorded
   configuration source, using that service manager's configuration reload procedure.
   Removing one source can expose a value from another; inspect both.

4. Wait until affected sessions finish their turns before activation. An overlay
   change takes effect on the next adapter start; it does not replace a running
   adapter. Stage and select the verified target package as described above, then
   restart the installed service at the authorized idle boundary. Apply the same
   idle boundary to affected remote adapters before their next start.
   Do not treat a successful unset or an active service as proof of activation.

5. After activation, verify the effective executable path, exact runtime
   version and SHA-256 for each affected host/harness, plus the adapter package version.
   Use the actual adapter launch/process information and the selected binary's
   version output and file hash, not just the executable on your shell's PATH.
   Package-managed vendor paths can move or contain different bytes after an
   update; a saved path alone does not pin a runtime version.
   Run one real model turn per affected host/harness. Verify the expected hook
   fires and enforces its result, then resume an existing session and verify
   its conversation continues. Record the results before calling the upgrade
   successful. This checklist is not proof that an untested release works.

If verification fails, stop the rollout. Restore each changed overlay to its
recorded value with `tightbeam host-env-set --host <host> --harness <harness>
'NAME=previous-value' --as-user <adminUserId>`. Restore the prior service
environment and compatible runtime/adapter versions through the supported
installation procedure. Use the same idle/restart boundary and repeat verification.
Check the target's state-migration rollback restrictions before reverting a
Tightbeam package; restoring an executable alone does not undo a database migration.
Before rolling back a database that contains terminal credential incidents, use the
new code to prove that every such incident recovered. If older code will run while
any incident remains open, explicitly acknowledge that it cannot honor the durable
suppression and the automatic provider credential probe loop will return.

After the upgraded gateway is running, bring in the new guidance as step 9 of
[the 0.1.8 to 0.1.9 order](#018-to-019-follow-this-order) describes: relearn,
resolve conflicts with the user, publish, check what relearn skipped, roll out
to existing agents, confirm. Main loads the `tightbeam-operating-manual` skill
to lead it.

The 0.1.8 package carries its own exact migration chain: `model-identity-v1`
(0.1.7) to `operator-decision-requests-v1`, then to `pi-harness-v1`. A database
already at the intermediate stamp runs only the second step. When running that
0.1.8 package, the gateway refuses every other old stamp; it never infers a
schema from stored DDL. This historical chain does not establish that current
0.1.9 accepts `pi-harness-v1` as its source, nor does it establish downgrade
compatibility.

Everything below was measured on 2026-07-26 against a real `state.db` with work
genuinely in flight.

## Take a backup first

Use `VACUUM INTO` from a read-only SQLite handle when the source is a live WAL
database. It takes one consistent read snapshot. Do not use `.backup` for this
release check: a continuously written WAL source can make that API restart its
copy indefinitely. See **[BACKUP.md](BACKUP.md)** for what `state.db` does *not*
cover (`gateway.json` especially — losing it rotates the org token).

Back up **every registered base directory**. Each host owns its own `state.db`.
The primary database does not migrate a satellite database for it. A macOS host
whose registry entry says `baseDir=/Users/mike/.tightbeam`, for example, must be
stopped, backed up, upgraded, and started on that host.

## The historical 0.1.7 to 0.1.8 migration chain

This describes the historical 0.1.7-to-0.1.8 transition only; it does not
define the input contract for the current 0.1.9 migration. Use the
source-backed lineage check above and the standalone 0.1.9 rehearsal before
starting that upgrade.

Let the 0.1.8 gateway perform this migration at first boot. Do not edit the
stamp or issue manual `ALTER TABLE` statements.

The migration accepts exactly these source transitions:

```text
model-identity-v1 -> operator-decision-requests-v1 -> pi-harness-v1
```

The first step runs in one SQLite transaction. It rebuilds `decision_requests` with the
0.1.8 operator-request constraint and `ruledViaSessionKey` column. It also
rebuilds `messages` with the 0.1.8 marker-envelope columns and constraint. It
copies every 0.1.7 row, sets the new fields to `NULL`, and creates the exact
0.1.8 indexes. The 0.1.7 and 0.1.8 `wakes` table definitions are identical, so
the migration does not rewrite wakes; it checks that their row count is
unchanged in the same transaction. The second transaction rebuilds `sessions`
with the same columns and rows but adds `pi` and `opencode_go` to the closed
harness/provider constraints. The stamp changes last in each transaction. Any
failure rolls back that transaction's table rebuilds, copied rows, indexes, and
stamp together.
The serialized database owner suspends foreign-key enforcement only around the
transaction because SQLite otherwise checks child rows during `DROP TABLE`.
The transaction runs `foreign_key_check` before it stamps or commits, and the
owner restores enforcement after success or rollback.

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
3. Install an unmodified 0.1.8 package in a second isolated prefix and start it
   against a fresh copy of the fixture. Require a named `ShapeError` that shows
   `model-identity-v1` as the stored stamp and
   `pi-harness-v1` as the build stamp. It must not serve. Keep
   the migrated-run copy separate from this refusal control.
4. Before installing the migration candidate, require this exact stamp and
   record the populations:

   ```sh
   sqlite3 -readonly "$upgrade_db" "SELECT shape FROM schema_stamp;"
   sqlite3 -readonly "$upgrade_db" \
      "SELECT 'work_items',count(*) FROM work_items UNION ALL
      SELECT 'assignments',count(*) FROM assignments UNION ALL
      SELECT 'sessions',count(*) FROM sessions UNION ALL
      SELECT 'attests',count(*) FROM attests UNION ALL
      SELECT 'decision_requests',count(*) FROM decision_requests UNION ALL
      SELECT 'wakes',count(*) FROM wakes UNION ALL
      SELECT 'messages',count(*) FROM messages;"
   ```

5. Hash the complete rebuilt rows in deterministic order. Select only the
   0.1.7 columns so the new nullable columns do not change the digest:

   ```sh
   request_columns='id,kind,raiserId,raiserSessionKey,ownerUserId,assignmentId,expecterSessionKey,expecterUserId,lineageRung,effortGeneration,deadlineWakeId,raisedAt,deadlineAt,statuteName,actionKey,question,options,context,status,decision,rationale,ruledBy,ruledAt,rulingFactId,consumedAt,parkWakeId,withdrawnBy,withdrawnReason,withdrawnAt'
   sqlite3 -readonly "$upgrade_db" ".mode quote" \
     "SELECT $request_columns FROM decision_requests ORDER BY id;" | shasum -a 256
   sqlite3 -readonly "$upgrade_db" ".mode quote" \
     "SELECT * FROM wakes ORDER BY wakeId;" | shasum -a 256
   message_columns='seq,id,sessionKey,role,content,timestamp,sender,deviceId,clientMessageId,replyToMessageId,replyToClientMessageId,llmVisibleMessageId,attachments,attentionTier'
   sqlite3 -readonly "$upgrade_db" ".mode quote" \
     "SELECT $message_columns FROM messages ORDER BY seq;" | shasum -a 256
   ```

6. Install the verified migration-candidate package into the same isolated
   prefix. Start the gateway once against the same base and port. This boot
   performs the migration. Do not run a separate SQL migration command.
7. Require `/version` to report the expected 0.1.8 build and source SHA. Then
   require all of these database checks:

   ```sh
   sqlite3 -readonly "$upgrade_db" "SELECT shape FROM schema_stamp;"
   sqlite3 -readonly "$upgrade_db" "PRAGMA quick_check;"
   sqlite3 -readonly "$upgrade_db" "PRAGMA foreign_key_check;"
   sqlite3 -readonly "$upgrade_db" \
     "SELECT count(*) FROM pragma_table_info('decision_requests')
      WHERE name='ruledViaSessionKey';"
   sqlite3 -readonly "$upgrade_db" \
     "SELECT count(*) FROM pragma_table_info('messages')
      WHERE name IN ('messageType','markerKind','markerFrom','markerTo');"
   sqlite3 -readonly "$upgrade_db" \
     "SELECT count(*) FROM sqlite_master
      WHERE type='index' AND name='decision_requests_operator_open';"
   sqlite3 -readonly "$upgrade_db" \
     "SELECT count(*) FROM sqlite_master
      WHERE type='table' AND name IN
        ('decision_requests_model_identity_v1','messages_new','sessions_new');"
   sqlite3 -readonly "$upgrade_db" \
     "SELECT instr(sql, \"'pi'\"), instr(sql, \"'opencode_go'\")
      FROM sqlite_master WHERE type='table' AND name='sessions';"
   ```

   PASS means the stamp is `pi-harness-v1`, `quick_check` is
   `ok`, `foreign_key_check` prints nothing, the new request-column and index
   counts are `1`, the new message-column count is `4`, and the temporary-table
   count is `0`. Both session-constraint positions must be greater than zero.
8. Repeat all population counts and deterministic hashes. Require exact
   equality with steps 4 and 5. Start the 0.1.8 gateway a second time and
   require the same stamp timestamp, counts, and hashes again; this proves an
   ordinary restart does not replay the migration.
9. On a disposable copy, replace the stamp with an unknown value and require a
   named refusal with no table or stamp mutation.

### macOS: package and base-directory smoke

Use a fresh copy of the same pre-upgrade fixture, the Darwin package, an unused
port, and the host registry's real base-directory convention. Stop only the
isolated test gateway.

1. Boot the fixture once with the 0.1.7 Darwin package and require `/version`
   0.1.7. Stop it cleanly.
2. Install the 0.1.8 Darwin package into the same isolated prefix and restart
   against the same base directory.
3. Require `/version` to report the expected 0.1.8 build and source SHA.
4. Require the new stamp; unchanged `work_items`, `assignments`, `sessions`,
   `attests`, `decision_requests`, `wakes`, and `messages` counts;
   `PRAGMA quick_check = ok`; no foreign key failures; all new columns and
   indexes; and no migration temporary table.

Do not run the TARS or Shrdlu cold-install custody matrix again. This is the
upgrade-preservation check that matrix did not cover.

## Release upgrade sequence

For release packages, the stage/select sequence above is the supported cycle.
Keep source builds outside every service-selected path; `git pull` and
`mix compile` must not modify the executable that a crash or service restart
would load. Stage the complete release package first, select only its reported
build ID after verification and authorization, and restart the service as a
separate operation. If the process exits before that restart, the service still
starts the currently selected complete build.

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

### Fresh-agent deploy readiness is a separate proof

A boot response, an existing session answering, and an empty queue do not prove
that newly installed bits can spawn a new agent. On an explicitly authorized
disposable test deployment, run the bounded readiness mode described in
`docs/SMOKE.md`. It must spawn a new session, dispatch a wake, observe that
wake's delivered turn and matching assistant reply, and confirm retirement.
Failed, canceled, missing, or unanswered turns are not success. Retirement
failure also fails the proof. Record the installed package/source identity,
host, selected harnesses, session key, wake ID, turn/message/reply IDs and
retirement result. A skipped harness remains incomplete.

This does not authorize production smoke, installation, credentials, identity
changes or a full feature smoke against a live org. Keep migration evidence
and restart preservation evidence separate from this lifecycle proof.

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
