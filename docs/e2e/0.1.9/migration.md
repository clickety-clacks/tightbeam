# Migrate a real 0.1.8 database to 0.1.9

This is the one migration procedure for 0.1.8 to 0.1.9. It replaces the separate
`release-019-database-migration-rehearsal.md` procedure in the specs repository.
It runs the 0.1.9 packaged gateway against a verified copy of a real 0.1.8
database, checks build admission, preserves the migrated output and hands that
output to every feature runbook. Nothing here runs until Mike calls the run.

Everything below runs inside an environment that has passed all six
[containment](README.md#containment) conditions, from a
[CLI shell](README.md#cli-shell), with the README's
[gateway helper](README.md#gateway-start-and-stop) defined. Never point a
command at a live base, edit a schema stamp or marker, issue manual
`ALTER TABLE` statements, or rerun this migration to prepare a feature test.

## Package acquisition

<a id="package-acquisition"></a>

No published 0.1.9 release exists yet, so the package under test is a
candidate built by the `release candidate` workflow:

1. Create a branch named `release-candidate/<name>` from the 0.1.9 commit under
   test. The workflow and `scripts/release_candidate.sh --check` refuse a branch
   whose head equals the protected tip (an empty range), so add one empty marker
   commit and verify that its tree is the tip's tree:

   ```sh
   git checkout -b "release-candidate/e2e-$(date -u +%Y%m%d)" <0.1.9 commit>
   git commit --allow-empty -m "release candidate: E2E package marker for <0.1.9 commit>"
   git diff --quiet <0.1.9 commit> HEAD && echo "tree unchanged"
   git push origin HEAD
   ```

   The workflow runs on that push (or by `workflow_dispatch` with the branch
   and its 40-hex head). The candidate SHA is the marker commit; the package it
   builds is the 0.1.9 tree, and the gateway's `/version` sha will be the
   marker's. Record both.
2. When it succeeds it publishes one artifact,
   `release-candidate-proof-<sha>`, kept for 90 days. It holds
   `packages/linux-x86_64/tightbeam-0.1.9-linux-x86_64.tgz`,
   `packages/darwin-aarch64/tightbeam-0.1.9-darwin-aarch64.tgz`, `toolchains/`,
   `release-candidate-manifest.json` and a `SHA256SUMS` whose lines name those
   relative paths. The package file names carry no commit suffix. The proof
   artifact exists only if both test jobs and both package jobs passed.
3. Stage the Linux package under the exact name source qualification expects,
   and take its digest from the proof's `SHA256SUMS`:

   ```sh
   # From the downloaded proof artifact directory:
   package_entry="packages/linux-x86_64/tightbeam-0.1.9-linux-x86_64.tgz"
   test -f "$package_entry"
   cp "$package_entry" "$SOURCE_DIR/package-0.1.9.tar"
   cp SHA256SUMS "$SOURCE_DIR/SHA256SUMS.0.1.9"
   expected_target_package_sha256="$(awk -v p="$package_entry" '$2 == p {print $1}' SHA256SUMS)"
   test -n "$expected_target_package_sha256"
   test "$(sha256 "$SOURCE_DIR/package-0.1.9.tar")" = "$expected_target_package_sha256"
   ```

   The `awk` match is on the exact relative path the checksum file records, so
   an empty result stops the run instead of passing an unverified package.

   Extract the archive once into `SCRATCH`; `PKG` is the extracted `tightbeam/`
   directory, which holds `bin/`, `release/` and, for a published release only,
   `release-provenance.json`.
4. `target_source_commit` is the candidate SHA, and `target_source_checkout` is
   a checkout of that SHA placed inside `SOURCE_DIR` before containment.

A published, tagged 0.1.9 release replaces steps 1 and 2 with its GitHub
release assets, whose names carry the short commit and whose `SHA256SUMS`
lines name bare file names (as `v0.1.8+1343` does:
`tightbeam-0.1.8-linux-x86_64-b2add64.tgz`). Step 3 then binds by basename:

```sh
# From the downloaded release assets directory:
package_entry="$(ls tightbeam-0.1.9-linux-x86_64-*.tgz)"
test "$(printf '%s\n' "$package_entry" | wc -l | tr -d ' ')" -eq 1
cp "$package_entry" "$SOURCE_DIR/package-0.1.9.tar"
cp SHA256SUMS "$SOURCE_DIR/SHA256SUMS.0.1.9"
expected_target_package_sha256="$(awk -v p="$package_entry" '$2 == p {print $1}' SHA256SUMS)"
test -n "$expected_target_package_sha256"
test "$(sha256 "$SOURCE_DIR/package-0.1.9.tar")" = "$expected_target_package_sha256"
```

Nothing else changes except the [package kind](#package-kind).

## Source snapshot

<a id="source-snapshot"></a>

The snapshot is taken on the source host, outside containment, from a
read-only handle, and it is the only thing that reads the live database. It
changes nothing on that host. Run it as the operator once per E2E cycle; the
same snapshot serves every package tested afterwards.

```sh
set -eu
snapshot_dir="/operator-supplied/writable/snapshot-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$snapshot_dir"
live_db="$HOME/.tightbeam/state.db"
backup_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sqlite3 "file:$live_db?mode=ro" "VACUUM INTO '$snapshot_dir/state.db';"
test "$(sqlite3 -readonly -bail "$snapshot_dir/state.db" "PRAGMA quick_check;")" = ok
schema_stamp="$(sqlite3 -readonly -bail "$snapshot_dir/state.db" "SELECT shape FROM schema_stamp;")"
version_json="$(curl -fsS --noproxy '*' http://127.0.0.1:11373/version)"
running_sha="$(printf '%s' "$version_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')"
# The 0.1.8 package that produced this database, from its GitHub release.
cp /operator-supplied/tightbeam-0.1.8-linux-x86_64-b2add64.tgz "$snapshot_dir/package-0.1.8.tar"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
SNAP_DIR="$snapshot_dir" SNAP_STAMP="$schema_stamp" SNAP_SHA="$running_sha" SNAP_TIME="$backup_time" \
SNAP_DB_SHA="$(sha256 "$snapshot_dir/state.db")" SNAP_PKG_SHA="$(sha256 "$snapshot_dir/package-0.1.8.tar")" \
python3 - <<'PY'
import json, os
sha = os.environ["SNAP_SHA"]
commit = "b2add64414b41606a713ed284abf01a0b4d125e6"
if not commit.startswith(sha):
    raise SystemExit(f"running gateway sha {sha!r} is not the approved lineage commit")
manifest = {
    "format": "tightbeam-e2e-source/v1",
    "sourceVersion": "0.1.8",
    "sourceTag": "v0.1.8+1343",
    "sourceBuild": "1343",
    "sourceCommit": commit,
    "sourcePackageSha256": os.environ["SNAP_PKG_SHA"],
    "stateDbSha256": os.environ["SNAP_DB_SHA"],
    "schemaStamp": os.environ["SNAP_STAMP"],
    "lineageEvidence": f"GET /version on the source host reported sha {sha} at {os.environ['SNAP_TIME']}; release v0.1.8+1343 release-provenance.json names commit {commit}",
    "backupMethod": "sqlite3 VACUUM INTO from a mode=ro URI handle",
    "backupTime": os.environ["SNAP_TIME"],
}
with open(os.path.join(os.environ["SNAP_DIR"], "manifest.json"), "x", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PY
chmod a-w "$snapshot_dir"/*
```

The result is three files, `state.db`, `manifest.json` and `package-0.1.8.tar`,
that become the read-only `SOURCE_DIR` inside containment, together with the
0.1.9 package, its `SHA256SUMS` and the candidate checkout from
[package acquisition](#package-acquisition). If the running sha, tag, build or
stamp differ from the approved lineage, the manifest script stops; do not edit
the values to match.

## Source qualification

A published tagged 0.1.9 package carries a canonical
`release-provenance.json` beside its release payload. The gateway uses that
file only to distinguish a published release from a development or work-branch
build. It then derives the same exact transition the runbook would otherwise
carry explicitly, but only for an unmarked base whose read-only stamp is
`operator-decision-requests-v1`. The migration remains transactional and the
build-owner marker is written only after the current target stamp commits.
Missing or malformed release provenance, a marked base, or any other schema is
refused before migration. An explicit `TIGHTBEAM_LIVE_BASE_TRANSITION` remains
supported for the separately authorized rehearsal path below.

The database is bound to a non-secret source manifest with `format`
(`tightbeam-e2e-source/v1`), `sourceVersion`, `sourceTag`, `sourceBuild`,
`sourceCommit`, `sourcePackageSha256`, `stateDbSha256`, `schemaStamp`,
`lineageEvidence`, `backupMethod` and `backupTime`. A version label and a stamp
alone do not establish which build produced a database.

The approved reference lineage is tag `v0.1.8+1343`, build 1343, commit
`b2add64414b41606a713ed284abf01a0b4d125e6`, stored stamp
`operator-decision-requests-v1`. That is the release Gibson runs: its
`/version` reports sha `b2add644`, and the release's `release-provenance.json`
names that commit. Its Linux package is
`tightbeam-0.1.8-linux-x86_64-b2add64.tgz`, SHA-256
`9dcfd9dc04eb718e27fcf479a494b38818f8fe5d41c2a6b065c224d3ffe4b623`. If the actual snapshot differs in tag, build,
commit or stamp, stop before boot and ask delivery ownership for a source-backed
lineage ruling; do not substitute the reference values. `pi-harness-v1` is the
last stamp of the 0.1.8 package's own migration chain, not an accepted 0.1.9
source stamp, and this procedure makes no claim about it.

The database copy comes from the operator's authorized backup. For a live WAL
database that is the consistent read-only `VACUUM INTO` backup in
[UPGRADE.md](../../UPGRADE.md#take-a-backup-first). Only `state.db` is copied:
never the source base's `gateway.json`, `auth/`, `homes/`, `identity/`,
credentials or workspaces.

```sh
set -eu
trial_root="$(mktemp -d "${SCRATCH:?}/migration.XXXXXX")"
source_db="${SOURCE_DIR:?}/state.db"
source_manifest="$SOURCE_DIR/manifest.json"
source_package="$SOURCE_DIR/package-0.1.8.tar"
target_package_archive="$SOURCE_DIR/package-0.1.9.tar"
expected_target_package_sha256="replace-with-published-package-sha256"
target_package_sha256="$(sha256 "$target_package_archive")"
test "$target_package_sha256" = "$expected_target_package_sha256"
manifest_value() {
  python3 - "$source_manifest" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    manifest = json.load(f)
if manifest.get("format") != "tightbeam-e2e-source/v1":
    raise SystemExit("unrecognized source manifest format")
value = manifest.get(sys.argv[2])
if not isinstance(value, (str, int)) or not str(value).strip():
    raise SystemExit(f"missing source manifest field: {sys.argv[2]}")
print(value)
PY
}
source_version="$(manifest_value sourceVersion)"
source_tag="$(manifest_value sourceTag)"
source_build="$(manifest_value sourceBuild)"
source_commit="$(manifest_value sourceCommit)"
source_package_sha256="$(manifest_value sourcePackageSha256)"
expected_source_sha256="$(manifest_value stateDbSha256)"
manifest_source_stamp="$(manifest_value schemaStamp)"
manifest_value lineageEvidence >/dev/null
manifest_value backupMethod >/dev/null
manifest_value backupTime >/dev/null
test "$source_version" = "0.1.8"
# Fixed until a source-backed ruling admits a different actual 0.1.8 snapshot.
approved_source_tag="v0.1.8+1343"
approved_source_build="1343"
approved_source_commit="b2add64414b41606a713ed284abf01a0b4d125e6"
expected_source_stamp="operator-decision-requests-v1"
test "$source_tag" = "$approved_source_tag"
test "$source_build" = "$approved_source_build"
test "$source_commit" = "$approved_source_commit"
python3 - "$source_commit" "$source_package_sha256" "$expected_source_sha256" "$target_package_sha256" <<'PY'
import re, sys
if re.fullmatch(r"[0-9a-f]{40}", sys.argv[1]) is None:
    raise SystemExit("source commit must be a full lowercase Git SHA")
for value in sys.argv[2:]:
    if re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise SystemExit("package and database SHA-256 values must be lowercase hex")
PY
test "$(sha256 "$source_package")" = "$source_package_sha256"
test "$(sha256 "$source_db")" = "$expected_source_sha256"
test_base="$trial_root/migration-base"
mkdir "$test_base"
test_base="$(cd "$test_base" && pwd -P)"
test_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
cp -p "$source_db" "$test_base/state.db"
test "$(sha256 "$test_base/state.db")" = "$expected_source_sha256"
test ! -e "$test_base/build-owner.json"
```

Record integrity and row counts before boot. Save only the stamp, counts and
digests in the scorecard.

```sh
row_counts() {
  sqlite3 -readonly -bail -separator '|' "$1" \
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
}
source_stamp="$(sqlite3 -readonly -bail "$test_base/state.db" "SELECT shape FROM schema_stamp;")"
quick_check="$(sqlite3 -readonly -bail "$test_base/state.db" "PRAGMA quick_check;")"
foreign_key_failures="$(sqlite3 -readonly -bail "$test_base/state.db" "PRAGMA foreign_key_check;")"
test "$source_stamp" = "$manifest_source_stamp"
test "$source_stamp" = "$expected_source_stamp"
test "$quick_check" = "ok"
test -z "$foreign_key_failures"
source_row_counts="$(row_counts "$test_base/state.db")"
printf 'source stamp: %s\nquick_check: %s\nforeign_key_check: clean\n' "$source_stamp" "$quick_check"
printf '%s\n' "$source_row_counts"
```

Stop before boot if any of these fails. Do not inspect DDL to guess or repair a
stamp.

## Build admission

<a id="build-admission"></a>

### Package kind

<a id="package-kind"></a>

Two things can supply the transition the guard demands, and the runbook has to
know which one this package uses before it probes anything:

```sh
if test -f "${PKG:?}/release-provenance.json"; then package_kind=release; else package_kind=candidate; fi
echo "package kind: $package_kind"
```

- `candidate`: a release-candidate or dispatched build. It has no
  `release-provenance.json`, so the gateway never migrates on its own. The
  explicit `TIGHTBEAM_LIVE_BASE_TRANSITION` path below is the only path, and a
  start with no input is refused with `build_transition_required`. This is the
  workbranch rehearsal.
- `release`: a tagged push build. On an unmarked base stamped
  `operator-decision-requests-v1` the gateway derives the same transition itself
  (PR #185) and migrates with no input. On this kind, a start with no input
  **is the positive start**: never run it as a refusal probe, because it would
  migrate the copy. The explicit input still works and an invalid explicit
  input is still refused, so the other probes stay.

0.1.9 refuses to open a base that carries no build marker unless the operator
names the exact transition. Merge `1265b3c894356755d46bc1fd143aeab5be2c873c`
(PR #183) adds that input, `TIGHTBEAM_LIVE_BASE_TRANSITION`: one JSON object with
exactly these four fields.

- `base`: the canonical absolute path of this scratch base.
- `expectedSchema`: the source stamp read from the copied `state.db`.
- `source`: the literal `"unmarked"`.
- `target`: the 64-character lowercase `buildIdentity` in the target package's
  `build-manifest.json`. This is the package payload identity, not a commit and
  not a schema stamp.

The guard recomputes the payload identity itself and refuses if the payload does
not match its manifest. Never compute a replacement identity. The variable is
operator input for one start; it does not isolate anything.

```sh
PKG="${PKG:?}"
target_source_commit="replace-with-full-source-commit-from-package-provenance"
target_source_checkout="/operator-supplied/verified-0.1.9/source"
git -C "$target_source_checkout" merge-base --is-ancestor \
  1265b3c894356755d46bc1fd143aeab5be2c873c "$target_source_commit"
target_payload_root="$(python3 - "$PKG" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1]) / "release" / "lib"
manifests = list(root.glob("tightbeam-*/build-manifest.json"))
if len(manifests) != 1:
    raise SystemExit(f"expected one packaged payload manifest, found {len(manifests)}")
print(manifests[0].parent)
PY
)"
target_build_identity="$(python3 - "$target_payload_root/build-manifest.json" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    manifest = json.load(f)
identity = manifest.get("buildIdentity")
if manifest.get("format") != "tightbeam-payload/v1" or not isinstance(identity, str):
    raise SystemExit("unrecognized 0.1.9 payload manifest")
if re.fullmatch(r"[0-9a-f]{64}", identity) is None:
    raise SystemExit("payload buildIdentity is not a 64-character lowercase hex digest")
print(identity)
PY
)"
transition_json() { # transition_json BASE EXPECTED_SCHEMA TARGET
  python3 - "$1" "$2" "$3" <<'PY'
import json, os, sys
base = os.path.realpath(sys.argv[1])
if not os.path.isabs(base) or base != os.path.normpath(base):
    raise SystemExit("scratch base is not canonical")
print(json.dumps({
    "base": base,
    "expectedSchema": sys.argv[2],
    "source": "unmarked",
    "target": sys.argv[3],
}, separators=(",", ":")))
PY
}
```

### Refusal probes

Run these on the migration base itself, before the positive start. Admission
reads the base read-only and refuses before anything is written, so a correct
refusal leaves the copy unchanged; the probes check exactly that. A refusal
raises inside the gateway's supervision tree, so the process exits nonzero and
may write `erl_crash.dump` into its working directory. Run the probes from the
CLI shell's scratch directory.

```sh
marker_state() { # the marker's digest, or "absent"
  if test -e "$test_base/build-owner.json"; then
    sha256 "$test_base/build-owner.json"
  else
    echo absent
  fi
}

probe_refusal() { # probe_refusal NAME EXPECTED_CODE [NAME=VALUE ...]
  name="$1"; expected="$2"; shift 2
  log="$trial_root/probe-$name.log"
  digest_before="$(sha256 "$test_base/state.db")"
  marker_before="$(marker_state)"
  ls -A "$test_base" >"$trial_root/probe-$name.before"
  if gateway_start "$test_base" "$test_port" "$log" "$@"; then
    echo "$name: observed-fail (gateway served /version)"
    gateway_stop
    return 0
  fi
  if kill -0 "$gateway_pid" 2>/dev/null; then
    echo "$name: observed-fail (no /version and no exit within the limit)"
    gateway_stop
    return 0
  fi
  status=0; wait "$gateway_pid" || status=$?; gateway_pid=""
  ls -A "$test_base" >"$trial_root/probe-$name.after"
  added="$(comm -13 "$trial_root/probe-$name.before" "$trial_root/probe-$name.after" | grep -vx 'state.db-shm' || true)"
  if test "$status" -ne 0 && grep -q "$expected" "$log" &&
     test "$(sha256 "$test_base/state.db")" = "$digest_before" &&
     test -z "$added" && test "$(marker_state)" = "$marker_before"; then
    echo "$name: observed-pass ($expected)"
  else
    echo "$name: observed-fail (exit $status, added: ${added:-none})"
  fi
}

other_base="$(mktemp -d "$trial_root/other-base.XXXXXX")"
case "$package_kind" in
  candidate) probe_refusal no-transition build_transition_required ;;
  release) echo "no-transition: not a probe on a release package; it is the positive start" ;;
esac
probe_refusal malformed invalid_build_transition \
  TIGHTBEAM_LIVE_BASE_TRANSITION='{"base":'
probe_refusal wrong-target build_transition_mismatch \
  TIGHTBEAM_LIVE_BASE_TRANSITION="$(transition_json "$test_base" "$source_stamp" 0000000000000000000000000000000000000000000000000000000000000000)"
probe_refusal wrong-base build_transition_mismatch \
  TIGHTBEAM_LIVE_BASE_TRANSITION="$(transition_json "$other_base" "$source_stamp" "$target_build_identity")"
probe_refusal wrong-schema legacy_schema_mismatch \
  TIGHTBEAM_LIVE_BASE_TRANSITION="$(transition_json "$test_base" "not-the-source-stamp" "$target_build_identity")"
```

| Probe | Input | Expected refusal |
|---|---|---|
| `no-transition` | Variable unset (candidate package only) | `build_transition_required` |
| `malformed` | Truncated JSON | `invalid_build_transition` |
| `wrong-target` | Valid JSON, `target` of 64 zeros | `build_transition_mismatch` |
| `wrong-base` | Valid JSON naming another canonical scratch directory | `build_transition_mismatch` |
| `wrong-schema` | Valid JSON, `expectedSchema` not the copied stamp | `legacy_schema_mismatch` |

Each probe passes only with a nonzero exit, the expected code in its private
log, no `/version`, an unchanged `state.db` digest, `build-owner.json` in the
state it was in before the probe, and no new base entry other than
`state.db-shm`. Before migration that means the marker is still absent; for
[left-set](#left-set-refusal) it means the gateway's marker is still present
with the same digest. A probe that serves or changes the
base is `observed-fail`; if it changed the base, stop and restart this runbook
from a new copy, because the positive start needs an untouched copy.

`incompatible_schema` needs a source whose stamp 0.1.9 does not accept. Run it
only on a separate, provenance-verified source that a lineage ruling names for
that purpose; otherwise record `skipped: no authorized incompatible source`.
Never edit a stamp to make one.

## Run the migration once

On a candidate package, start the gateway with the exact transition, on this
one start only, and do not export the variable. On a release package, start it
with no input: the automatic upgrade is the behavior under test.

```sh
case "$package_kind" in
  candidate)
    migration_path="TIGHTBEAM_LIVE_BASE_TRANSITION supplied for one start only"
    gateway_start "$test_base" "$test_port" "$trial_root/gateway.log" \
      TIGHTBEAM_LIVE_BASE_TRANSITION="$(transition_json "$test_base" "$source_stamp" "$target_build_identity")" ;;
  release)
    migration_path="automatic, from release-provenance.json"
    gateway_start "$test_base" "$test_port" "$trial_root/gateway.log" ;;
esac
cp "$trial_root/gateway.log.version" "$trial_root/version.json"
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

If the exact input above is refused, record the observed code as
`observed-fail`. That is a product result; do not change the check.

Require the target stamp and a clean integrity check, and review the row
populations. Explain every difference from the source counts against the exact
migration source before calling the result a pass.

```sh
target_stamp="$(sqlite3 -readonly -bail "$test_base/state.db" "SELECT shape FROM schema_stamp;")"
target_quick_check="$(sqlite3 -readonly -bail "$test_base/state.db" "PRAGMA quick_check;")"
foreign_key_failures="$(sqlite3 -readonly -bail "$test_base/state.db" "PRAGMA foreign_key_check;")"
test "$target_stamp" = "work-item-delivery-owner-v1-019"
test "$target_quick_check" = "ok"
test -z "$foreign_key_failures"
target_row_counts="$(row_counts "$test_base/state.db")"
printf 'target stamp: %s\nquick_check: %s\nforeign_key_check: clean\n' "$target_stamp" "$target_quick_check"
printf '%s\n' "$target_row_counts"
```

### Preservation reads

Read existing rows through the same package's CLI. Choose the IDs from the
copied database: an admin user, a work item with an assignment, a decision
request, an artifact. Skip a surface only when the source has no row of that
kind, and record that. Never create replacement data to hide a failed read.

```sh
AREA_BASE="$test_base"; AREA_PORT="$test_port"
test_admin="$(sqlite3 -readonly "$test_base/state.db" "SELECT userId FROM users WHERE isAdmin = 1 ORDER BY userId LIMIT 1")"
existing_work_item="replace-with-real-work-item-id"
existing_assignment="replace-with-an-assignment-of-that-work-item"
existing_request="replace-with-real-dr-id"
existing_artifact="replace-with-real-artifact-id"
tb list --as-user "${test_admin:?}"
tb work-item-get "$existing_work_item" --as-user "$test_admin"
tb decision-request --request "$existing_request" --as-user "$test_admin"
tb artifacts --as-user "$test_admin"
```

`work-item-get` returns `existing_assignment` in its `assignments` field, and
`existing_artifact` appears in the listing. A content fetch is not required: a
historical artifact's bytes may never have been captured. `decision-request
--request` accepts only `dr_<uuidv4>` IDs; pick a request whose ID has that
form.

### Transcript index

<a id="transcript-index"></a>

0.1.9 creates the `turns_message_id` index at boot and pages transcripts through
it. On a real-size copy, check both:

```sh
sqlite3 -readonly "$test_base/state.db" \
  "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'turns_message_id';"
busiest_session="$(sqlite3 -readonly "$test_base/state.db" \
  "SELECT sessionKey FROM turns GROUP BY sessionKey ORDER BY count(*) DESC LIMIT 1")"
started="$(date +%s)"
tb transcript --session "$busiest_session" --limit 50 --as-user "$test_admin" >/dev/null
echo "transcript read: $(($(date +%s) - started))s"
```

The index query prints `turns_message_id`. The transcript command exits 0 with
at most 50 entries; record its elapsed time. Do not keep its output: it is the
copied org's conversation.

### Stop and check the marker

```sh
gateway_stop
python3 - "$test_base/build-owner.json" "$target_build_identity" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    marker = json.load(f)
if marker != {
    "format": "tightbeam-build-owner/v1",
    "buildIdentity": sys.argv[2],
}:
    raise SystemExit("gateway owner marker does not match the migrated payload")
PY
```

The gateway itself writes the marker. Never construct or edit one.

### Left-set refusal

<a id="left-set-refusal"></a>

Once the marker exists, the transition input is stale. An operator who leaves it
set must be refused; one who unsets it must be admitted. This holds for both
package kinds.

```sh
probe_refusal left-set build_transition_mismatch \
  TIGHTBEAM_LIVE_BASE_TRANSITION="$(transition_json "$test_base" "$source_stamp" "$target_build_identity")"
gateway_start "$test_base" "$test_port" "$trial_root/reboot.log"
gateway_stop
```

`left-set` passes as described under [refusal probes](#refusal-probes): the
marker checked above is still present and unchanged. The
restart with the variable unset serves `/version` and stops cleanly. The
helper always unsets the variable, so any restart outside these runbooks must
unset it as well.

## Preserve the reusable result

<a id="record-the-result"></a>

The reusable result is a clean snapshot of the migrated database, the marker the
gateway wrote and a non-secret manifest.

```sh
mkdir "$trial_root/migrated-output"
# VACUUM INTO reads through a read-only connection and writes only the new file.
sqlite3 -readonly -bail "$test_base/state.db" \
  "VACUUM INTO '$trial_root/migrated-output/state.db';"
cp -p "$test_base/build-owner.json" "$trial_root/migrated-output/build-owner.json"
target_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$trial_root/version.json")"
E2E_OUTPUT_DIR="$trial_root/migrated-output" \
E2E_SOURCE_MANIFEST="$source_manifest" \
E2E_SOURCE_ROW_COUNTS="$source_row_counts" \
E2E_TARGET_ROW_COUNTS="$target_row_counts" \
E2E_TARGET_VERSION="$target_version" \
E2E_TARGET_SOURCE_COMMIT="$target_source_commit" \
E2E_TARGET_PACKAGE_SHA256="$target_package_sha256" \
E2E_TARGET_BUILD_IDENTITY="$target_build_identity" \
E2E_TARGET_STAMP="$target_stamp" \
E2E_TARGET_QUICK_CHECK="$target_quick_check" \
E2E_TEST_HOST="$(hostname)" \
E2E_COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
E2E_GATEWAY_BIN="$PKG/bin/tightbeam-gateway" \
E2E_MIGRATION_PATH="$migration_path" \
python3 - <<'PY'
import hashlib, json, os
from pathlib import Path

output = Path(os.environ["E2E_OUTPUT_DIR"])
with open(os.environ["E2E_SOURCE_MANIFEST"], encoding="utf-8") as f:
    source = json.load(f)

def parse_counts(value):
    counts = {}
    for line in value.splitlines():
        name, count = line.split("|", 1)
        counts[name] = int(count)
    if len(counts) != 10:
        raise SystemExit("expected ten source and target row counts")
    return counts

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

manifest = {
    "format": "tightbeam-e2e-migration/v1",
    "source": {
        key: source[key]
        for key in (
            "sourceVersion", "sourceTag", "sourceBuild", "sourceCommit",
            "sourcePackageSha256", "stateDbSha256", "schemaStamp",
            "lineageEvidence", "backupMethod", "backupTime",
        )
    },
    "sourceRowCounts": parse_counts(os.environ["E2E_SOURCE_ROW_COUNTS"]),
    "target": {
        "version": os.environ["E2E_TARGET_VERSION"],
        "sourceCommit": os.environ["E2E_TARGET_SOURCE_COMMIT"],
        "packageSha256": os.environ["E2E_TARGET_PACKAGE_SHA256"],
        "buildIdentity": os.environ["E2E_TARGET_BUILD_IDENTITY"],
        "schemaStamp": os.environ["E2E_TARGET_STAMP"],
        "quickCheck": os.environ["E2E_TARGET_QUICK_CHECK"],
        "foreignKeyCheck": "clean",
        "rowCounts": parse_counts(os.environ["E2E_TARGET_ROW_COUNTS"]),
    },
    "migration": {
        "testHost": os.environ["E2E_TEST_HOST"],
        "completedAt": os.environ["E2E_COMPLETED_AT"],
        "gatewayBinary": os.environ["E2E_GATEWAY_BIN"],
        "transition": os.environ["E2E_MIGRATION_PATH"],
    },
    "output": {
        "stateDbSha256": digest(output / "state.db"),
        "buildOwnerSha256": digest(output / "build-owner.json"),
    },
}
with open(output / "manifest.json", "x", encoding="utf-8") as f:
    json.dump(manifest, f, sort_keys=True, indent=2)
    f.write("\n")
PY
chmod a-w "$trial_root/migrated-output"/*
```

Record `E2E migration: observed-pass` only if the version, stamp, integrity,
row-count review, every refusal probe, the preservation reads, the transcript
index, the marker, the left-set refusal, the unset restart and the preserved
output all hold. Otherwise record what was observed and leave the output
unapproved for feature runs.

## Reuse the result

<a id="reuse-the-result"></a>

Every feature area starts from a new copy of the preserved output, run with the
same package whose identity the manifest records. The copied marker lets the
gateway open the migrated database directly, so no transition input is set and
the migration never repeats. A different package identity is refused and needs
its own migration result.

```sh
migrated="/path/to/preserved/migrated-output"
python3 - "$migrated/manifest.json" "$target_build_identity" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
if manifest["target"]["buildIdentity"] != sys.argv[2]:
    raise SystemExit("package identity differs from the migrated result")
PY
test "$(sha256 "$migrated/state.db")" = "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["output"]["stateDbSha256"])' "$migrated/manifest.json")"
AREA_BASE="$(mktemp -d "${SCRATCH:?}/area.XXXXXX")"
AREA_BASE="$(cd "$AREA_BASE" && pwd -P)"
AREA_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
cp "$migrated/state.db" "$migrated/build-owner.json" "$AREA_BASE/"
chmod u+w "$AREA_BASE/state.db" "$AREA_BASE/build-owner.json"
gateway_start "$AREA_BASE" "$AREA_PORT" "$AREA_BASE.log"
```

Copy nothing else into the area base. Never boot 0.1.8 against the migrated
output. Delete the area base after its runbook finishes.
