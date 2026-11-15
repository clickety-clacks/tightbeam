#!/usr/bin/env bash
# Run only after the operator has approved the exact install sheet and bundle.
set -Eeuo pipefail
umask 077

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
MANIFEST=$DIR/manifest.json
fail() { printf 'STOP before service control: %s\n' "$*" >&2; exit 1; }
value() { /usr/bin/jq -er "$1" "$MANIFEST"; }
prop() { /usr/bin/systemctl show "$2" --property="$1" --value; }
absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "planned output already exists: $1"; }

[[ $EUID -eq 0 ]] || fail 'run through the approved single sudo handoff'
[[ $(/usr/bin/uname -s):$(/usr/bin/uname -m) == Linux:x86_64 ]] || fail 'unsupported platform'
(cd "$DIR" && /usr/bin/sha256sum -c SHA256SUMS) || fail 'release bundle hash mismatch'
[[ $(value '.format') == 1 ]] || fail 'unsupported manifest format'

OLD_VERSION=$(value '.predecessor.version')
OLD_BUILD=$(value '.predecessor.build')
OLD_SOURCE=$(value '.predecessor.source_prefix')
OLD_ID=$(value '.predecessor.build_id')
OLD_SCHEMA=$(value '.predecessor.schema')
NEW_VERSION=$(value '.release.version')
NEW_BUILD=$(value '.release.build')
NEW_TAG=$(value '.release.tag')
NEW_SOURCE=$(value '.release.source_commit')
NEW_PACKAGE=$(value '.release.package')
NEW_PACKAGE_SHA=$(value '.release.package_sha256')
NEW_ID=$(value '.release.build_id')
NEW_SCHEMA=$(value '.release.schema')
ROOT=$(value '.paths.root')
CURRENT=$(value '.paths.current')
BASE=$(value '.paths.base')
DB=$(value '.paths.database')
BACKUP_PARENT=$(value '.paths.backup_parent')
BACKUP=$(value '.paths.backup')
LOG=$(value '.paths.log')
JOB_DIR=$(value '.paths.job_dir')
NODE=$(value '.paths.node')
UNIT=$(value '.service.gateway')
MAINT_UNIT=$(value '.service.maintenance')
SERVICE_USER=$(value '.service.user')
SERVICE_GROUP=$(value '.service.group')
WORKING_DIRECTORY=$(value '.service.working_directory')
STOP_TIMEOUT=$(value '.service.stop_timeout_usec')
START_TIMEOUT=$(value '.service.start_timeout_usec')
JOB_SHA=$(value '.job_sha256')
[[ $NEW_ID == "sha256-$NEW_PACKAGE_SHA" ]] || fail 'release build ID differs from package digest'
OLD_TARGET=$ROOT/builds/$OLD_ID
NEW_TARGET=$ROOT/builds/$NEW_ID
JOB_TARGET=$JOB_DIR/maintenance-job.sh

[[ $ROOT == /opt/tightbeam && $CURRENT == "$ROOT/current" && $DB == "$BASE/state.db" ]] || fail 'unsupported install paths'
[[ $BACKUP == "$BACKUP_PARENT"/* && $UNIT == tightbeam.service && $MAINT_UNIT == *.service ]] || fail 'unsupported backup or unit paths'
[[ -x "$NODE" ]] || fail 'the release selector interpreter is unavailable'
[[ $(/usr/bin/sha256sum "$DIR/maintenance-job.sh" | /usr/bin/awk '{print $1}') == "$JOB_SHA" ]] || fail 'job does not match manifest'
[[ $(/usr/bin/sha256sum "$DIR/$NEW_PACKAGE" | /usr/bin/awk '{print $1}') == "$NEW_PACKAGE_SHA" ]] || fail 'package does not match manifest'
[[ $(/usr/bin/sha256sum "$DIR/release-provenance.json" | /usr/bin/awk '{print $1}') == "$(value '.release.provenance_sha256')" ]] || fail 'provenance hash mismatch'
[[ $(/usr/bin/sha256sum "$DIR/release-candidate-manifest.json" | /usr/bin/awk '{print $1}') == "$(value '.release.candidate_manifest_sha256')" ]] || fail 'candidate proof hash mismatch'
[[ $(/usr/bin/sha256sum "$DIR/release-SHA256SUMS" | /usr/bin/awk '{print $1}') == "$(value '.release.checksums_sha256')" ]] || fail 'published checksum file mismatch'
(cd "$DIR" && /usr/bin/sha256sum -c release-SHA256SUMS --ignore-missing) || fail 'published package checksum mismatch'
/usr/bin/jq -e --arg tag "$NEW_TAG" --arg source "$NEW_SOURCE" --arg package "$NEW_PACKAGE" --arg proof "$(value '.release.candidate_manifest_sha256')" '
  .repository == "clickety-clacks/tightbeam" and .tag == $tag and .commit == $source
  and .checksums == "SHA256SUMS" and (.assets | index($package) != null)
  and (.assets | index("release-candidate-manifest.json") != null)
  and .candidate.proof_manifest_sha256 == $proof
  and .install_approval.approved_source_sha == $source
  and .soak.outcome == "healthy" and .soak.source_sha == $source
' "$DIR/release-provenance.json" >/dev/null || fail 'release provenance mismatch'
/usr/bin/jq -e --arg source "$NEW_SOURCE" --arg sha "$NEW_PACKAGE_SHA" --arg run "$(/usr/bin/jq -er '.candidate.run_id' "$DIR/release-provenance.json")" '
  .schema == "tightbeam-release-candidate-proof/v1" and
  .repository == "clickety-clacks/tightbeam" and .source_sha == $source and
  .run_id == $run and
  ([.packages[] | select(.platform == "linux-x86_64" and .sha256 == $sha)] | length) == 1
' "$DIR/release-candidate-manifest.json" >/dev/null || fail 'candidate proof does not bind this package'
while IFS= read -r required; do [[ -e "$required" ]] || fail "required path is absent: $required"; done < <(/usr/bin/jq -er '.required_paths[]' "$MANIFEST")
while IFS=' ' read -r expected path; do
  [[ -r "$path" ]] || fail "required file is absent: $path"
  [[ $(/usr/bin/sha256sum "$path" | /usr/bin/awk '{print $1}') == "$expected" ]] || fail "required file changed: $path"
done < <(/usr/bin/jq -r '.preflight_files[]? | "\(.sha256) \(.path)"' "$MANIFEST")
[[ $(/usr/bin/readlink -e "$CURRENT") == "$OLD_TARGET" ]] || fail 'installed predecessor selector changed'
/usr/bin/curl -fsS --max-time 5 http://127.0.0.1:11373/version | /usr/bin/jq -e --arg v "$OLD_VERSION" --arg b "$OLD_BUILD" --arg s "$OLD_SOURCE" '.version == $v and (.build|tostring) == $b and (.sha|startswith($s))' >/dev/null || fail 'running predecessor build changed'
[[ $(/usr/bin/sqlite3 -readonly "$DB" 'SELECT shape FROM schema_stamp;') == "$OLD_SCHEMA" ]] || fail 'predecessor schema changed'
[[ $(prop LoadState "$UNIT") == loaded && $(prop ActiveState "$UNIT") == active ]] || fail 'gateway unit is not active and loaded'
[[ $(prop User "$UNIT") == "$SERVICE_USER" && $(prop Group "$UNIT") == "$SERVICE_GROUP" && $(prop WorkingDirectory "$UNIT") == "$WORKING_DIRECTORY" ]] || fail 'gateway service account or working directory changed'
[[ $(prop KillMode "$UNIT") == control-group ]] || fail 'gateway kill mode changed'
[[ $(prop TimeoutStopUSec "$UNIT") == "$STOP_TIMEOUT" && $(prop TimeoutStartUSec "$UNIT") == "$START_TIMEOUT" ]] || fail 'gateway start or stop timeout changed'
[[ $(prop Restart "$UNIT") == on-failure && $(prop RestartUSec "$UNIT") == 5s ]] || fail 'gateway restart policy changed'
[[ $(prop StartLimitBurst "$UNIT") == 5 && $(prop StartLimitIntervalUSec "$UNIT") == 10s ]] || fail 'gateway start limit changed'
[[ $(prop MainPID "$UNIT") =~ ^[1-9][0-9]*$ ]] || fail 'gateway process is absent'
GATEWAY_CGROUP=$(prop ControlGroup "$UNIT")
[[ -n $GATEWAY_CGROUP && -r /proc/self/cgroup ]] || fail 'gateway or caller cgroup is unavailable'
CALLER_CGROUPS=$(< /proc/self/cgroup)
[[ -n $CALLER_CGROUPS ]] || fail 'caller cgroup is unavailable'
while IFS=: read -r _ _ caller_path; do
  [[ $caller_path != "$GATEWAY_CGROUP" && $caller_path != "$GATEWAY_CGROUP"/* ]] || fail 'launcher is inside the gateway cgroup'
done <<< "$CALLER_CGROUPS"
[[ $(prop LoadState "$MAINT_UNIT") == not-found ]] || fail 'maintenance unit name is already present'
absent "$NEW_TARGET"; absent "$JOB_DIR"; absent "$LOG"; absent "$BACKUP"

TMP=$(/usr/bin/mktemp -d /tmp/tightbeam-release-stage.XXXXXX)
trap '/usr/bin/rm -rf -- "$TMP"' EXIT
/usr/bin/tar -xzf "$DIR/$NEW_PACKAGE" -C "$TMP" tightbeam/bin/tightbeam-select
[[ -x "$TMP/tightbeam/bin/tightbeam-select" ]] || fail 'published selector is absent'
/usr/bin/env PATH="$(/usr/bin/dirname "$NODE"):/usr/local/bin:/usr/bin:/bin" "$TMP/tightbeam/bin/tightbeam-select" stage \
  --root "$ROOT" --package "$DIR/$NEW_PACKAGE" \
  --checksums "$DIR/release-SHA256SUMS" --provenance "$DIR/release-provenance.json" > "$TMP/stage-receipt.json"
/usr/bin/jq -e --arg id "$NEW_ID" --arg source "$NEW_SOURCE" '.buildId == $id and .sourceCommit == $source' "$TMP/stage-receipt.json" >/dev/null || fail 'staged build identity mismatch'
/usr/bin/install -d -o root -g root -m 0700 "$JOB_DIR"
/usr/bin/install -o root -g root -m 0500 "$DIR/maintenance-job.sh" "$JOB_TARGET"
[[ $(/usr/bin/sha256sum "$JOB_TARGET" | /usr/bin/awk '{print $1}') == "$JOB_SHA" ]] || fail 'staged job hash mismatch'
printf 'Verified and staged %s (%s). Starting the one-off maintenance unit.\n' "$NEW_TAG" "$NEW_SCHEMA"
/usr/bin/rm -rf -- "$TMP"
trap - EXIT
exec /usr/bin/systemd-run --system --unit="$MAINT_UNIT" --uid=root --service-type=exec --pty --wait --property=Restart=no --property=KillMode=control-group --working-directory=/root /usr/bin/bash --noprofile --norc "$JOB_TARGET"
