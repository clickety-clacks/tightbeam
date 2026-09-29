# Migrate a real 0.1.8 database to 0.1.9

This is the single standalone migration rehearsal for 0.1.8 to 0.1.9. It folds
the older `release-019-database-migration-rehearsal.md` procedure into the
canonical release runbooks. Start with the shared execution contract in the
[aggregate](README.md#execution-contract).

Bind the actual source snapshot to a non-secret manifest that identifies its
exact 0.1.8 build and package provenance, source commit, database SHA-256,
stored stamp, and the approved backup method and time. A version label and a
stamp by themselves do not establish which source produced the database.

The reference lineage is canonical tag `v0.1.8+1337`, build 1337 at
`fdb3db53b596d4114d06505b39a4c1836fba7564`. That source stamps
`operator-decision-requests-v1`, and current 0.1.9 names that predecessor. It
is a reference input, not presumed provenance for a later real 0.1.8 snapshot.
If the actual manifest identifies another build or stamp, stop before boot and
get delivery's source-backed lineage ruling. A difference requires
adjudication; it does not by itself reject every 0.1.8 snapshot. In
particular, `pi-harness-v1` is not named by the current 0.1.9 accepted-stamp
chain, so do not claim that it migrates through 0.1.9 without such a ruling.

The check uses the 0.1.9 packaged gateway once against a verified copy of a real
0.1.8 database. It preserves the input and saves the migrated output for later
feature runs. Never point a command at a live base, edit a schema stamp, issue
manual `ALTER TABLE` statements, or rerun migration to prepare a feature test.

## Inputs and isolation

Before starting, record the source host and exact 0.1.8 build, its package
provenance and source commit, the approved backup method and time, source file
size and SHA-256, the stored source stamp and its lineage evidence, the target
package version/source commit/package SHA, the test host, an unused port, and
the path of the disposable area. Obtain the database copy through the
operator's authorized backup process.
When the source is a live WAL database, use the established consistent
read-only `VACUUM INTO` backup procedure in [UPGRADE.md](../../UPGRADE.md#take-a-backup-first).

Use only the verified `state.db` as the migration input. Do not copy the source
base's `gateway.json`, `auth/`, `homes/`, `identity/`, provider credentials, or
workspace files. The package starts from a new scratch base and writes its own
gateway descriptor. If that isolated boot cannot satisfy the release's normal
host prerequisites without importing source credentials, stop and record the
missing prerequisite.

```sh
set -eu
trial_root="$(mktemp -d)"
source_db="/operator-supplied/verified-0.1.8/state.db"
expected_source_sha256="replace-with-the-db-sha-from-the-approved-source-manifest"
source_sha256="$(shasum -a 256 "$source_db" | awk '{print $1}')"
test "$source_sha256" = "$expected_source_sha256"
test_base="$trial_root/migration-base"
test_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
mkdir -p "$test_base"
cp -p "$source_db" "$test_base/state.db"
test "$(shasum -a 256 "$test_base/state.db" | awk '{print $1}')" = "$source_sha256"
```

Before boot, require the one stored source stamp to match the value established
by the source manifest and its lineage ruling. For the exact `v0.1.8+1337`
reference source, that value is `operator-decision-requests-v1`. Record
`PRAGMA quick_check`, `PRAGMA foreign_key_check`, and counts for existing
durable rows. At minimum record counts for `users`, `sessions`, `work_items`,
`assignments`, `attests`, `decision_requests`, `messages`, `turns`, `wakes`, and
`artifacts`. Save only the non-secret stamp, counts, and digests in the
scorecard.

```sh
# Use this value only for the exact +1337 reference lineage. For another source,
# do not proceed until delivery records its source-backed lineage ruling.
expected_source_stamp="operator-decision-requests-v1"
source_stamp="$(sqlite3 -readonly -bail "$test_base/state.db" "SELECT shape FROM schema_stamp;")"
quick_check="$(sqlite3 -readonly -bail "$test_base/state.db" "PRAGMA quick_check;")"
foreign_key_failures="$(sqlite3 -readonly -bail "$test_base/state.db" "PRAGMA foreign_key_check;")"
test "$source_stamp" = "$expected_source_stamp"
test "$quick_check" = "ok"
test -z "$foreign_key_failures"
printf 'source stamp: %s\nquick_check: %s\nforeign_key_check: clean\n' "$source_stamp" "$quick_check"
sqlite3 -readonly -bail "$test_base/state.db" \
  "SELECT 'users',count(*) FROM users UNION ALL
   SELECT 'sessions',count(*) FROM sessions UNION ALL
   SELECT 'work_items',count(*) FROM work_items UNION ALL
   SELECT 'assignments',count(*) FROM assignments UNION ALL
   SELECT 'attests',count(*) FROM attests UNION ALL
   SELECT 'decision_requests',count(*) FROM decision_requests UNION ALL
   SELECT 'messages',count(*) FROM messages UNION ALL
   SELECT 'turns',count(*) FROM turns UNION ALL
   SELECT 'wakes',count(*) FROM wakes UNION ALL
   SELECT 'artifacts',count(*) FROM artifacts ORDER BY 1;"
```

For the exact `v0.1.8+1337` reference lineage, the expected stamp is
`operator-decision-requests-v1`. Set `expected_source_stamp` only to the stamp
established by the source-backed lineage ruling for the actual manifest. Stop
before boot if that evidence is missing, the observed stamp differs from the
approved value, the source copy fails integrity checks, or the input digest
does not match its verified provenance. Do not inspect DDL to guess a
replacement stamp.

## Run the migration once

Use the hash-verified 0.1.9 package built from the authorized target source
commit. Set a unique scratch base and port explicitly. Start the packaged
foreground gateway and capture its output in private scratch for local
diagnostics:

```sh
gateway_bin="/path/to/verified-0.1.9/tightbeam/bin/tightbeam-gateway"
TIGHTBEAM_BASE_DIR="$test_base" \
TIGHTBEAM_PORT="$test_port" \
TIGHTBEAM_ADVERTISED_URL="ws://127.0.0.1:$test_port" \
"$gateway_bin" >"$trial_root/gateway.log" 2>&1 &
gateway_pid=$!
attempt=0
until curl -fsS "http://127.0.0.1:$test_port/version" >"$trial_root/version.json"; do
  kill -0 "$gateway_pid" 2>/dev/null || exit 1
  attempt=$((attempt + 1))
  test "$attempt" -lt 60 || exit 1
  sleep 1
done
cat "$trial_root/version.json"
```

Keep the raw gateway log in private scratch only. Do not attach it to an artifact
or scorecard; record only non-secret checks and redacted diagnostic excerpts.

While it is running, require `GET /version` to report version `0.1.9` and a
source SHA matching the package provenance. Set the full source commit from the
verified package provenance before this check:

```sh
target_source_commit="replace-with-full-source-commit-from-package-provenance"
python3 - "$trial_root/version.json" "$target_source_commit" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    version = json.load(f)
reported = version.get("sha")
if version.get("version") != "0.1.9":
    raise SystemExit(f"unexpected gateway version: {version.get('version')!r}")
if not isinstance(reported, str) or not reported or not sys.argv[2].startswith(reported):
    raise SystemExit(f"gateway source SHA does not match package provenance: {reported!r}")
PY
```

Require the stamp to reach
`work-item-delivery-owner-v1-019`. Run the same integrity, foreign-key and row
count queries from above. Compare the old durable row populations, and explain
every intentional schema-owned difference from the exact migration source
before calling the result a pass.

```sh
target_stamp="$(sqlite3 -readonly -bail "$test_base/state.db" "SELECT shape FROM schema_stamp;")"
target_quick_check="$(sqlite3 -readonly -bail "$test_base/state.db" "PRAGMA quick_check;")"
foreign_key_failures="$(sqlite3 -readonly -bail "$test_base/state.db" "PRAGMA foreign_key_check;")"
test "$target_stamp" = "work-item-delivery-owner-v1-019"
test "$target_quick_check" = "ok"
test -z "$foreign_key_failures"
printf 'target stamp: %s\nquick_check: %s\nforeign_key_check: clean\n' "$target_stamp" "$target_quick_check"
sqlite3 -readonly -bail "$test_base/state.db" \
  "SELECT 'users',count(*) FROM users UNION ALL
   SELECT 'sessions',count(*) FROM sessions UNION ALL
   SELECT 'work_items',count(*) FROM work_items UNION ALL
   SELECT 'assignments',count(*) FROM assignments UNION ALL
   SELECT 'attests',count(*) FROM attests UNION ALL
   SELECT 'decision_requests',count(*) FROM decision_requests UNION ALL
   SELECT 'messages',count(*) FROM messages UNION ALL
   SELECT 'turns',count(*) FROM turns UNION ALL
   SELECT 'wakes',count(*) FROM wakes UNION ALL
   SELECT 'artifacts',count(*) FROM artifacts ORDER BY 1;"
```

Use the packaged CLI against this scratch base to confirm that the migrated
owner, a real existing work item, and existing assignment, decision-request,
and artifact rows can be read. Choose IDs from the verified copied database;
skip a surface only when the source database has no row of that kind, and
record that fact. Do not create replacement data to hide a failed preservation
read.

```sh
test_admin="replace-with-existing-admin-user-id"
existing_work_item="replace-with-real-work-item-id"
existing_assignment="replace-with-real-assignment-id"
existing_request="replace-with-real-decision-request-id"
existing_artifact="replace-with-real-artifact-id"
TIGHTBEAM_BASE_DIR="$test_base" /path/to/verified-0.1.9/tightbeam/bin/tightbeam list --as-user "$test_admin"
TIGHTBEAM_BASE_DIR="$test_base" /path/to/verified-0.1.9/tightbeam/bin/tightbeam work-item-get "$existing_work_item" --as-user "$test_admin"
TIGHTBEAM_BASE_DIR="$test_base" /path/to/verified-0.1.9/tightbeam/bin/tightbeam assignment-get "$existing_assignment" --as-user "$test_admin"
TIGHTBEAM_BASE_DIR="$test_base" /path/to/verified-0.1.9/tightbeam/bin/tightbeam decision-request --request "$existing_request" --as-user "$test_admin"
TIGHTBEAM_BASE_DIR="$test_base" /path/to/verified-0.1.9/tightbeam/bin/tightbeam artifacts --as-user "$test_admin"
```

Confirm `existing_artifact` appears in the artifact listing; a content fetch is
not required because a historical artifact's bytes may never have been
captured.

Stop the isolated gateway through its packaged `tightbeam-gateway stop` command
with the same explicit `TIGHTBEAM_BASE_DIR`, then confirm its recorded process
has exited. Leave the original verified source copy unchanged.

```sh
TIGHTBEAM_BASE_DIR="$test_base" "$gateway_bin" stop
wait "$gateway_pid"
```

## Preserve the reusable result

Take a clean SQLite snapshot of the migrated database into a separate output
directory. Record the target stamp, target version/source SHA/package SHA,
source stamp/source SHA, row counts, integrity results, package start command,
test host, run time, and the output database SHA-256 in a non-secret JSON
manifest. The database file and manifest together are the migration result.

```sh
mkdir -p "$trial_root/migrated-output"
# VACUUM INTO reads this source through a read-only connection and writes only
# the separate destination database, which must not already exist.
sqlite3 -readonly -bail "$test_base/state.db" \
  "VACUUM INTO '$trial_root/migrated-output/state.db';"
shasum -a 256 "$trial_root/migrated-output/state.db"
```

Keep that snapshot immutable. For every standalone feature area, provision a
fresh disposable feature base with the permitted test host's own harness
setup, replace its database with a new copy of this saved `state.db`, and start
the matching 0.1.9 checkout gateway as the feature runbook requires. Do not
copy source-base credentials or configuration into those areas. Do not boot
0.1.8 against the migrated output and do not migrate it again.

The acceptance record must say `E2E migration: PASS` only if the exact version,
stamp, integrity, foreign-key, preservation-read, row-count review, clean stop,
and reusable output checks all pass. Otherwise record the observed failure and
leave the output unapproved for feature runs.
