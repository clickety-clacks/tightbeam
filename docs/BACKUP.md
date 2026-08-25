# Backing up an org, and restoring one

`<base_dir>/state.db` is the sole durable metadata record of the org: work
items, assignments, attests, turns, wakes, decision requests, events, and the
digests of released artifacts. Released artifact bytes live separately under
`<base_dir>/artifact-content/sha256/`. A usable backup contains one consistent
SQLite snapshot and every verified digest that snapshot references.

Everything below was verified by running it on 2026-07-26 (SQLite 3.51.0, macOS),
against a live `Tightbeam.DB` with the production PRAGMAs (`journal_mode=WAL`,
`foreign_keys=ON`, `synchronous=NORMAL`) while a writer was committing
multi-statement transactions.

## Take a backup

```sh
sqlite3 "$TIGHTBEAM_BASE_DIR/state.db" ".backup '$DEST/state-$(date +%Y%m%d-%H%M%S).db'"
```

Safe while the gateway is running — do **not** stop it. The gateway holds one
writer connection open; `.backup` uses SQLite's online backup API on its own
connection, takes a consistent snapshot, and restarts its copy if the source is
written to mid-flight. Measured: 6ms for a 229KB database with 1.3MB of
uncommitted WAL in flight.

The snapshot is a point-in-time: it will be missing writes committed after it
started. That is correct and is what "consistent" means here — never a torn mix.

After the snapshot completes, copy the distinct verified digests referenced by
that snapshot. Derive every source path from the digest; never copy `home` or
`originPath` as released content. Record a sorted manifest containing digest and
size, verify every copied file against it, then record the snapshot's own SHA-256.
A capture that commits after the snapshot is not referenced and need not be in
this backup. A capture already referenced by the snapshot is immutable and must
be copied.

```sh
SNAPSHOT="$DEST/state-20260825-120000.db"
sqlite3 "$SNAPSHOT" \
  "SELECT DISTINCT contentSha256 || ' ' || contentSize
     FROM artifacts WHERE state='released' ORDER BY contentSha256;" \
  > "$DEST/artifact-content.manifest"

while read -r digest size; do
  mkdir -p "$DEST/artifact-content/sha256/${digest%${digest#??}}"
  cp "$TIGHTBEAM_BASE_DIR/artifact-content/sha256/${digest%${digest#??}}/$digest" \
     "$DEST/artifact-content/sha256/${digest%${digest#??}}/$digest"
  test "$(wc -c < "$DEST/artifact-content/sha256/${digest%${digest#??}}/$digest" | tr -d ' ')" = "$size"
  test "$(sha256sum "$DEST/artifact-content/sha256/${digest%${digest#??}}/$digest" | cut -d' ' -f1)" = "$digest"
done < "$DEST/artifact-content.manifest"

sha256sum "$SNAPSHOT" > "$DEST/state.sha256"
```

Use `shasum -a 256` in place of `sha256sum` on macOS. V1 has no artifact
content deletion or retention rotation. Do not remove referenced, orphaned, or
corrupt CAS objects while making space for a backup.

A cron line, if you want it unattended. This is the whole scheduling story; there
is deliberately no retention engine, no rotation logic, and no offsite anything:

```cron
17 * * * * /usr/bin/sqlite3 "$HOME/.tightbeam/state.db" ".backup '$HOME/backups/state-$(date +\%Y\%m\%d-\%H).db'"
```

### Do NOT use `cp`, and do not trust `integrity_check` to catch it

`cp state.db backup.db` is **catastrophically wrong** in WAL mode: committed data
lives in `state.db-wal` until a checkpoint, so the copy silently omits it.
Measured, taken under load:

| | `sqlite3 .backup` | `cp state.db` |
|---|---|---|
| `PRAGMA integrity_check` | ok | **ok** |
| tables present | 17 | **0** |
| rows | 128 parents / 384 children | **none — "no such table"** |

Note the second column. The `cp` copy lost the entire schema and every row, and
`integrity_check` still said **ok**, because what it checks is that the pages it
has are internally coherent — not that anything is there. An operator validating
a `cp` backup with `integrity_check` gets a false green. Use `.backup`.

## Restore

Performed end to end on 2026-07-26; these are the steps that were actually run.

1. **Stop the gateway.** A restore replaces the file its writer has open.
2. **Put the snapshot and artifact CAS in place**, and clear any leftover WAL
   companions. Preserve the digest-derived directory layout:
   ```sh
   cp "$BACKUP" "$TIGHTBEAM_BASE_DIR/state.db"
   rm -f "$TIGHTBEAM_BASE_DIR/state.db-wal" "$TIGHTBEAM_BASE_DIR/state.db-shm"
   cp -R "$BACKUP_DIR/artifact-content/sha256" \
     "$TIGHTBEAM_BASE_DIR/artifact-content/"
   ```
   The `rm` is cheap hygiene, not a demonstrated fix. Measured: after a clean
   stop — and even after `kill -9` of the process holding the connection —
   SQLite had already checkpointed and removed both companions, and restoring
   over a database whose 2MB WAL had just been abandoned produced a correct file
   with `integrity_check` ok either way. So the stale-WAL hazard could not be
   reproduced here; the `rm` stays because a `-wal` belonging to a different
   file has no business next to a restored one, and removing files that are
   normally absent costs nothing.
3. **Verify before booting** — database checks and every manifest entry must
   pass. Also verify the recorded snapshot digest:
   ```sh
   sqlite3 "$TIGHTBEAM_BASE_DIR/state.db" "PRAGMA integrity_check;"    # expect: ok
   sqlite3 "$TIGHTBEAM_BASE_DIR/state.db" "PRAGMA foreign_key_check;"  # expect: no output
   sha256sum -c "$BACKUP_DIR/state.sha256"
   ```
   `foreign_key_check` is the one that matters — it is what proves the snapshot
   caught whole transactions rather than half of one.
   Rehash each restored CAS file and compare its byte count and digest to
   `artifact-content.manifest`. A missing or invalid referenced blob is not a
   partial success.
4. **Start the gateway.** Boot runs the exact shape check and its own
   recovery: any turn left `running` in the snapshot becomes terminal
   `failed_unknown` and is never auto-resumed, because its tools may already have
   run. Expect those rows; they are the recovery working, not damage. Verified
   by doing it — a turn captured mid-flight read `running` in the backup and
   `failed_unknown` after boot on the restored file. Retry is the sender's
   decision, so anything that mattered needs re-asking. Boot also scrubs every
   released artifact before accepting traffic. A missing or invalid blob is
   atomically marked corrupt with all shared references and the boot attempt
   refuses after recording that evidence.
5. **Spot-check an obligation you know existed** — a work item and its open
   assignment:
   ```sh
   sqlite3 "$TIGHTBEAM_BASE_DIR/state.db" \
     "SELECT w.id, w.state, a.id, a.state FROM work_items w
        LEFT JOIN assignments a ON a.workItemId = w.id LIMIT 5;"
   ```

Verified on restore: `integrity_check` ok, `foreign_key_check` clean, the boot
sequence ran against the restored file, and the open obligation came back intact
and readable through the real code path (`WorkItems.state_for/2` returned
`"open"`, `Org.get/2` returned the holder session with its harness and model).
Zero assignments referenced a missing work item.

## What this does NOT cover

`state.db` is not the whole org. At 3am, this is what you still do not have:

| path | back up? | why |
|---|---|---|
| `state.db` | **yes** | the only copy of all work state |
| `artifact-content/sha256/` | **yes, by snapshot manifest** | immutable released artifact bytes; the snapshot says exactly which digests are required |
| `artifact-content/tmp/` | no | incomplete capture/fetch staging; boot removes it |
| `gateway.json` | **yes** | holds the org `cliToken`. Preserved if present, but **regenerated with a new random token if missing** — lose it and every agent's injected `TIGHTBEAM_TOKEN` silently stops working |
| `identity/` | **yes** (or push it) | git repo: archetypes, guidance, skills, rails — the org's law. A remote counts |
| `state/users/<user>/user.md` | **yes** | agent-authored, durable, and nothing in `lib/` regenerates it |
| `auth/` | **see below** | secrets, and restoring them can be actively harmful |
| `work/` | your call | session workdirs — real repos. Committed work is on its remotes; **uncommitted work is not** |
| `homes/` | no | build outputs, regenerated from manifests on identity change |
| `harnesses.json` | no | rewritten from the code's registry on every boot |
| `bin/` | no | the CLI projection, reinstalled on boot |
| `*.log`, `adapter-*.stderr.log` | no | diagnostics |

**On `auth/`, deliberately not a simple yes.** Claude's grant is a non-rotating
setup token, so a restored copy still works. Codex's `auth.json` holds a
refresh token that **rotates on use**, so restoring a stale copy can make two
stores hold one grant and silently revoke each other. Prefer
`tightbeam onboard <provider>` over restoring codex credentials. Backing this
directory up at all means backing up secrets — an explicit decision, not a
default.

**Also not covered:** the harness's own conversation transcripts. The projection
store in `state.db` is a one-way cache of them (spec T2) — restoring it gives you
the operator's record of what was said, not the model's context. Resumed sessions
start from the harness's own state, or fresh if that is gone.
