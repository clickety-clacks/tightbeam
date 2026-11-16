#!/usr/bin/env bash
# Execute only from the exact reviewed and approved release bundle.
set -u
set -o pipefail
umask 077

BASE=__BASE__
DB=__DATABASE__
DEST=__BACKUP__
LOG=__LOG__
UNIT=tightbeam.service
MAINT_UNIT=tightbeam-0111-maintenance.service
ROOT=/opt/tightbeam
CURRENT=/opt/tightbeam/current
OLD_ID=sha256-e1af45213d14cbf37a256e72c8fa371027375ce7fb82dd70b5987564c521ee39
NEW_ID=sha256-9361f8b65b8f213941845da2481dc6aa3ca8ca9ad57afdc08cfbd47d4d07d7bd
OLD_TARGET=/opt/tightbeam/builds/sha256-e1af45213d14cbf37a256e72c8fa371027375ce7fb82dd70b5987564c521ee39
NEW_TARGET=/opt/tightbeam/builds/sha256-9361f8b65b8f213941845da2481dc6aa3ca8ca9ad57afdc08cfbd47d4d07d7bd
NEW_LINK=builds/sha256-9361f8b65b8f213941845da2481dc6aa3ca8ca9ad57afdc08cfbd47d4d07d7bd
SELECTOR=/opt/tightbeam/builds/sha256-9361f8b65b8f213941845da2481dc6aa3ca8ca9ad57afdc08cfbd47d4d07d7bd/tightbeam/bin/tightbeam-select
NODE=__NODE__
OLD_SCHEMA=decision-request-row-schema-v2-019
NEW_SCHEMA=launch-preparation-boot-v1-0110
SOURCE=306f423d331405c544ef0dfce4649e0a5c208a0a

STEP=launch-guard
FAIL_STEP=
FAIL_DETAIL=
CAPTURED=
LAST_RC=0
LOG_READY=0
FAILURE_STOP_ATTEMPTED=0
SERVICE_STOPPED=0
SERVICE_STOP_ATTEMPTED=0
FAILURE_EVIDENCED=0
FAILURE_EVIDENCE_DETAIL=
EXPECTED_PID=
NO_WRITER=0
PREDECESSOR_STAMP_OK=0
NEW_BOOT=0
OLD_START_ATTEMPTED=0
SUCCESS=0
OLD_RESTORABLE="not established; no change has been attempted"
BASELINE_RESTARTS=
START_AT=
OLD_LINK=
FINISH_MARKER=0
LOG_FAILURE=0
FAILURE_STOP_RESULT="not attempted"
FAILURE_STOP_STATE="not read"

terminal_copy() {
  # The manager-owned job must not depend on the attached PTY. A child printf
  # may fail on a closed PTY; that failure is deliberately best-effort only.
  /usr/bin/printf '%s\n' "$1" >&2 2>/dev/null || true
}
terminal_line() {
  local line=$1
  if (( LOG_READY == 1 )); then
    if ! /usr/bin/printf '%s\n' "$line" >> "$LOG" 2>/dev/null; then
      LOG_FAILURE=1
      terminal_copy "$line (durable log write failed; file may be incomplete)"
      return 1
    fi
  fi
  terminal_copy "$line"
  return 0
}
emit() {
  stamp=$(/usr/bin/date --iso-8601=seconds 2>/dev/null) || stamp=timestamp-unavailable
  line="$stamp $*"
  if (( LOG_READY == 1 )); then
    if ! /usr/bin/printf '%s\n' "$line" >> "$LOG" 2>/dev/null; then
      LOG_FAILURE=1
      return 1
    fi
  else
    terminal_copy "$line"
  fi
  return 0
}
run() {
  label=$1
  shift
  if (( LOG_FAILURE == 1 )); then LAST_RC=125; return 125; fi
  emit "BEGIN $label" || { LAST_RC=125; return 125; }
  if CAPTURED=$("$@" 2>&1); then LAST_RC=0; else LAST_RC=$?; fi
  emit "COMMAND $label exit=$LAST_RC" || { LAST_RC=125; return 125; }
  if (( LOG_FAILURE == 1 )); then LAST_RC=125; return 125; fi
  return "$LAST_RC"
}
stop_for() {
  if [[ -z "$FAIL_STEP" ]]; then
    FAIL_STEP=$1
    FAIL_DETAIL=$2
    emit "FIRST FAILURE step=$FAIL_STEP detail=$FAIL_DETAIL" || true
  fi
  exit 1
}
eq() {
  if [[ "$2" != "$3" ]]; then
    if (( NEW_BOOT == 1 )); then
      FAILURE_EVIDENCED=1
      FAILURE_EVIDENCE_DETAIL="$1 did not match its required value"
    fi
    stop_for "$STEP" "$1 did not match its required value"
  fi
  emit "PASS $1=$3"
}
good_pid() {
  if ! [[ "$2" =~ ^[0-9]+$ ]] || (( $2 <= 0 )); then
    if (( NEW_BOOT == 1 )); then
      FAILURE_EVIDENCED=1
      FAILURE_EVIDENCE_DETAIL="$1 is not a nonzero PID during final verification"
    fi
    stop_for "$STEP" "$1 is not a nonzero PID"
  fi
}
prop() {
  run "read $2 $1" /usr/bin/systemctl show "--property=$2" --value "$1" ||
    stop_for "$STEP" "could not read $2 $1"
  REPLY=$CAPTURED
  emit "OBSERVED $2 $1=$REPLY" || return 125
}
matches() { printf '%s\n' "$1" | /usr/bin/grep -Eq -- "$2"; }
has() { printf '%s\n' "$1" | /usr/bin/grep -Fq -- "$2"; }
atomic_selector() {
  local expected=$1 replacement=$2 temporary=$ROOT/.current.$$
  [[ ! -e "$temporary" && ! -L "$temporary" ]] || return 1
  [[ $(/usr/bin/readlink "$CURRENT") == "$expected" ]] || return 1
  /usr/bin/ln -s "$replacement" "$temporary" || return 1
  if ! /usr/bin/mv -Tf "$temporary" "$CURRENT"; then
    /usr/bin/rm -f -- "$temporary"
    return 1
  fi
  [[ $(/usr/bin/readlink "$CURRENT") == "$replacement" ]]
}
old_schema_ok() {
  run "old schema stamp" /usr/bin/sqlite3 -readonly "$DB" 'SELECT shape FROM schema_stamp;' || return 1
  [[ "$CAPTURED" == "$OLD_SCHEMA" ]] || return 1
  PREDECESSOR_STAMP_OK=1
}
no_open_database_process() {
  if run "fuser no-writer check" /usr/bin/fuser -v "$DB"; then
    if (( LAST_RC == 1 )) && [[ -z "$CAPTURED" ]]; then
      emit "PASS fuser exit 1 with no output"
      return 0
    fi
  elif (( LAST_RC == 1 )) && [[ -z "$CAPTURED" ]]; then
    emit "PASS fuser exit 1 with no output"
    return 0
  fi
  emit "STOP fuser was not exit 1 with no output; details omitted from durable log"
  return 1
}
restore_old_before_boot() {
  if (( NO_WRITER != 1 || PREDECESSOR_STAMP_OK != 1 )); then
    OLD_RESTORABLE="not established; no-writer or predecessor schema was not proven"
    emit "Old service remains stopped; recovery preconditions incomplete"
    return
  fi
  if ! run "read selector for recovery" /usr/bin/readlink -e "$CURRENT"; then
    OLD_RESTORABLE="unknown; selector read failed"
    return
  fi
  if [[ "$CAPTURED" == "$NEW_TARGET" ]]; then
    if ! run "restore exact old selector before any 0.1.11 boot" atomic_selector "$NEW_LINK" "$OLD_LINK"; then
      OLD_RESTORABLE="unknown; selector rollback failed"
      return
    fi
  elif [[ "$CAPTURED" != "$OLD_TARGET" ]]; then
    OLD_RESTORABLE="unknown; selector target is unrecognized"
    return
  fi
  if ! run "verify old selector" /usr/bin/readlink -e "$CURRENT" || [[ "$CAPTURED" != "$OLD_TARGET" ]]; then
    OLD_RESTORABLE="unknown; old selector readback failed"
    return
  fi
  if ! run "verify old selector link text" /usr/bin/readlink "$CURRENT" || [[ "$CAPTURED" != "$OLD_LINK" ]]; then
    OLD_RESTORABLE="unknown; old selector link text changed"
    return
  fi
  if ! old_schema_ok || ! no_open_database_process; then
    OLD_RESTORABLE="unknown; predecessor schema or no-writer check failed"
    return
  fi
  if ! run "read gateway state for recovery" /usr/bin/systemctl show --property=ActiveState --value "$UNIT"; then
    OLD_RESTORABLE="yes as an executable/database pair; service state read failed"
    return
  fi
  recovery_state=$CAPTURED
  if ! run "read gateway PID for recovery" /usr/bin/systemctl show --property=MainPID --value "$UNIT"; then
    OLD_RESTORABLE="yes as an executable/database pair; service PID read failed"
    return
  fi
  recovery_pid=$CAPTURED
  if [[ "$recovery_state" != inactive || "$recovery_pid" != 0 || "$OLD_START_ATTEMPTED" == 1 ]]; then
    OLD_RESTORABLE="yes as an executable/database pair; service was not safely inactive for one restart"
    emit "Conditional old-service start skipped; no retry"
    return
  fi
  OLD_START_ATTEMPTED=1
  if ! run "one conditional old-service start" /usr/bin/systemctl start "$UNIT"; then
    OLD_RESTORABLE="yes as an executable/database pair; old-service start failed and was not retried"
    return
  fi
  local attempt
  for ((attempt=1; attempt<=30; attempt++)); do
    if run "verify recovered old /version" /usr/bin/curl -fsS --max-time 1 http://127.0.0.1:11373/version; then
      if matches "$CAPTURED" '"version"[[:space:]]*:[[:space:]]*"0\.1\.9"' &&
         matches "$CAPTURED" '"build"[[:space:]]*:[[:space:]]*"?2908"?'; then
        OLD_RESTORABLE="yes; old build, predecessor schema and service version were verified; full database integrity was not checked"
      else
        OLD_RESTORABLE="yes as an executable/database pair; old service version was unexpected"
      fi
      return
    fi
    (( attempt == 30 )) || /usr/bin/sleep 1
  done
  OLD_RESTORABLE="yes as an executable/database pair; old /version did not become ready within 30 seconds"
}
one_failure_stop() {
  (( FAILURE_EVIDENCED == 1 )) || { emit "No gateway stop: no service or migration failure was evidenced" || true; return; }
  (( FAILURE_STOP_ATTEMPTED == 1 )) && { emit "Failure stop already attempted; no second failure stop" || true; return; }
  FAILURE_STOP_ATTEMPTED=1
  if /usr/bin/systemctl stop "$UNIT" >/dev/null 2>&1; then
    FAILURE_STOP_RESULT="completed successfully"
  else
    FAILURE_STOP_RESULT="failed with exit=$?; not retried"
  fi
  emit "One gateway stop after new-boot failure: $FAILURE_STOP_RESULT" || true
  if FAILURE_STOP_STATE=$(/usr/bin/systemctl show --property=ActiveState --value "$UNIT" 2>&1); then
    emit "Gateway state after the one failure stop: $FAILURE_STOP_STATE" || true
  else
    FAILURE_STOP_STATE="read failed: $FAILURE_STOP_STATE"
    emit "Gateway state read failed after one failure stop" || true
  fi
}
finish() {
  exit_code=$?
  trap - EXIT
  set +u
  set +o pipefail
  if (( exit_code != 0 )); then
    [[ -n "$FAIL_STEP" ]] || { FAIL_STEP=$STEP; FAIL_DETAIL="unexpected job exit"; }
    if (( LOG_FAILURE == 1 )); then
      FAIL_DETAIL="$FAIL_DETAIL; a durable-log write failed, so earlier log records may be incomplete"
    fi
    failure_action=""
    if (( NEW_BOOT == 1 )); then
      OLD_RESTORABLE="not established; 0.1.11 boot or migration may be partial; do not start 0.1.9"
      if (( FAILURE_EVIDENCED == 1 )); then
        one_failure_stop
        failure_action=" Evidenced failure: $FAILURE_EVIDENCE_DETAIL. One gateway stop attempt: $FAILURE_STOP_RESULT; state readback: $FAILURE_STOP_STATE."
      else
        failure_action=" No gateway stop was attempted because no service or migration failure was evidenced; do not start 0.1.9."
      fi
    elif (( NO_WRITER == 1 && PREDECESSOR_STAMP_OK == 1 )); then
      restore_old_before_boot
    elif (( SERVICE_STOPPED == 1 || SERVICE_STOP_ATTEMPTED == 1 )); then
      OLD_RESTORABLE="not established; no-writer and predecessor schema checks did not both pass"
    fi
    final="RESULT: FAILED at $FAIL_STEP — $FAIL_DETAIL. 0.1.9 restorable: $OLD_RESTORABLE.$failure_action Durable log path: $LOG"
    terminal_line "$final" || true
    exit "$exit_code"
  fi
  if (( SUCCESS == 1 )); then
    final="RESULT: SUCCESS — Tightbeam 0.1.11 is active and verified. 0.1.9 is restorable only by separately approved restoration of the verified backup; selector-only rollback is unsafe after migration and restoration loses later writes. Durable log path: $LOG"
    if ! terminal_line "$final"; then exit 94; fi
    exit 0
  fi
  final="RESULT: FAILED at $STEP — no success record was written. 0.1.9 restorable: $OLD_RESTORABLE. Durable log path: $LOG"
  terminal_line "$final" || true
  exit 1
}

if (( EUID != 0 )); then
  printf '%s\n' "RESULT: FAILED at root-entry — root was not granted. 0.1.9 restorable: unchanged by this job, not yet verified. Durable log path: $LOG (not opened)"
  exit 90
fi
if [[ -e "$LOG" || -L "$LOG" ]]; then
  printf '%s\n' "RESULT: FAILED at log-preflight — existing log preserved, not overwritten. 0.1.9 restorable: unchanged by this job, not yet verified. Durable log path: $LOG (existing file preserved)"
  exit 91
fi
if ! (set -o noclobber; : > "$LOG") 2>/dev/null; then
  printf '%s\n' "RESULT: FAILED at log-create — private log could not be created. 0.1.9 restorable: unchanged by this job, not yet verified. Durable log path: $LOG (not created)"
  exit 92
fi
LOG_READY=1
if ! /usr/bin/chown __SERVICE_USER__:__SERVICE_GROUP__ "$LOG" || ! /usr/bin/chmod 0600 "$LOG"; then
  printf '%s\n' "RESULT: FAILED at log-permissions — private log permissions could not be set. 0.1.9 restorable: unchanged by this job, not yet verified. Durable log path: $LOG"
  exit 93
fi
trap finish EXIT
trap 'FAIL_STEP=terminal-signal; FAIL_DETAIL="interactive terminal signal received"; exit 130' INT TERM
trap 'FAIL_STEP=terminal-hangup-before-entry; FAIL_DETAIL="terminal disconnected before entry"; exit 129' HUP

STEP=entry
emit "Independent transient maintenance job started; no gateway or database change attempted"
emit "Private durable log=$LOG owner=__SERVICE_USER__:__SERVICE_GROUP__ mode=0600"
trap '' HUP
emit "Terminal hangup is ignored; durable log is authoritative; terminal copies are best-effort"

STEP=preflight-old-release
run "old selector target" /usr/bin/readlink -e "$CURRENT" || stop_for "$STEP" "old selector read failed"
eq "old selector target" "$CAPTURED" "$OLD_TARGET"
run "old selector link text" /usr/bin/readlink "$CURRENT" || stop_for "$STEP" "old selector link text read failed"
OLD_LINK=$CAPTURED
case "$OLD_LINK" in
  "$OLD_TARGET"|"builds/$OLD_ID") ;;
  *) stop_for "$STEP" "old selector link text does not name the pinned predecessor" ;;
esac
run "old service version" /usr/bin/curl -fsS --max-time 5 http://127.0.0.1:11373/version ||
  stop_for "$STEP" "old /version read failed"
if ! matches "$CAPTURED" '"version"[[:space:]]*:[[:space:]]*"0\.1\.9"' ||
   ! matches "$CAPTURED" '"build"[[:space:]]*:[[:space:]]*"?2908"?' ||
   ! matches "$CAPTURED" '"sha"[[:space:]]*:[[:space:]]*"8433d22'; then
  OLD_RESTORABLE="unknown; current service is not the planned old release"
  stop_for "$STEP" "current /version does not match 0.1.9 build 2908"
fi
emit "PASS old service identity version=0.1.9 build=2908 source-prefix=8433d22"
run "predecessor schema stamp" /usr/bin/sqlite3 -readonly "$DB" 'SELECT shape FROM schema_stamp;' ||
  stop_for "$STEP" "predecessor schema read failed"
eq "predecessor schema stamp" "$CAPTURED" "$OLD_SCHEMA"
OLD_RESTORABLE="yes before migration; old selector and predecessor schema verified"
for path in "$DB" "$BASE/gateway.json" "$BASE/identity" "$BASE/adapters" "$BASE/homes" "$BASE/state/users" "$ROOT/builds/$NEW_ID/.tightbeam-stage.json" "$SELECTOR"; do
  [[ -e "$path" ]] || stop_for "$STEP" "required live-state or staged-build path is absent"
done
[[ -x "$SELECTOR" && -r "$SELECTOR" ]] || stop_for "$STEP" "published selector helper is not readable/executable"
[[ -x "$NODE" ]] || stop_for "$STEP" "explicit selector Node interpreter is not executable at $NODE"
[[ -x /usr/bin/timeout ]] || stop_for "$STEP" "bounded verification command is unavailable"
run "selector Node interpreter version" "$NODE" --version || stop_for "$STEP" "explicit Node interpreter failed before service stop"
matches "$CAPTURED" '^v[0-9]+\.[0-9]+' || stop_for "$STEP" "Node version output is not recognizable"
run "staged selector shebang" /usr/bin/head -n 1 "$SELECTOR" || stop_for "$STEP" "selector shebang read failed"
eq "staged selector shebang" "$CAPTURED" '#!/usr/bin/env node'
[[ ! -e "$DEST" && ! -L "$DEST" ]] || stop_for "$STEP" "backup destination exists; preserve it and do not overwrite"
emit "PASS required paths, staged receipt, explicit Node interpreter and backup destination"

STEP=service-boundary
prop "$UNIT" ActiveState; eq "gateway ActiveState" "$REPLY" active
prop "$UNIT" MainPID; good_pid "gateway MainPID" "$REPLY"
prop "$UNIT" ControlGroup; gateway_cgroup=$REPLY
eq "gateway ControlGroup" "$gateway_cgroup" /system.slice/tightbeam.service
prop "$UNIT" KillMode; eq "gateway KillMode" "$REPLY" control-group
prop "$UNIT" TimeoutStopUSec
eq "gateway stop timeout" "$REPLY" "__STOP_TIMEOUT_USEC__"
prop "$UNIT" TimeoutStartUSec
eq "gateway start timeout" "$REPLY" "__START_TIMEOUT_USEC__"
emit "PASS service start and stop limits match the reviewed manifest"
prop "$UNIT" Restart; eq "gateway restart policy" "$REPLY" on-failure
prop "$UNIT" RestartUSec; case "$REPLY" in 5s|5000000) ;; *) stop_for "$STEP" "gateway restart delay differs from observed five seconds";; esac
prop "$UNIT" StartLimitBurst; eq "start limit burst" "$REPLY" 5
prop "$UNIT" StartLimitIntervalUSec; case "$REPLY" in 10s|10000000) ;; *) stop_for "$STEP" "start-limit interval differs from observed ten seconds";; esac
prop "$MAINT_UNIT" ActiveState; eq "maintenance ActiveState" "$REPLY" active
prop "$MAINT_UNIT" MainPID; good_pid "maintenance MainPID" "$REPLY"
prop "$MAINT_UNIT" ControlGroup; maint_cgroup=$REPLY
[[ -n "$maint_cgroup" && "$maint_cgroup" != "$gateway_cgroup" && "$maint_cgroup" != *tightbeam.service* ]] ||
  stop_for "$STEP" "maintenance job is not outside the gateway cgroup"
prop "$MAINT_UNIT" Restart; eq "maintenance Restart" "$REPLY" no

STEP=capacity-preflight
run "database page metadata" /usr/bin/sqlite3 -readonly "$DB" 'PRAGMA page_count; PRAGMA page_size; PRAGMA max_page_count;' ||
  stop_for "$STEP" "database page metadata read failed"
mapfile -t page_metadata <<< "$CAPTURED"
[[ ${#page_metadata[@]} == 3 ]] || stop_for "$STEP" "database page metadata is incomplete"
page_count=${page_metadata[0]}; page_size=${page_metadata[1]}; max_pages=${page_metadata[2]}
for n in "$page_count" "$page_size" "$max_pages"; do [[ "$n" =~ ^[0-9]+$ ]] || stop_for "$STEP" "database page metadata is incomplete"; done
(( page_count > 0 && page_size > 0 && max_pages >= page_count )) || stop_for "$STEP" "database page capacity is invalid"
db_estimate=$((page_count * page_size))
run "estimate archive inputs" /usr/bin/du -sb -- "$BASE/gateway.json" "$BASE/identity" "$BASE/adapters" "$BASE/homes" "$BASE/state/users" ||
  stop_for "$STEP" "archive input size read failed"
archive_bytes=$(printf '%s\n' "$CAPTURED" | /usr/bin/awk '{sum += $1} END {printf "%.0f\n", sum}')
[[ "$archive_bytes" =~ ^[0-9]+$ ]] || stop_for "$STEP" "archive size estimate is not numeric"
run "read backup filesystem free bytes" /usr/bin/df -B1 --output=avail __BACKUP_PARENT__ ||
  stop_for "$STEP" "backup free-space read failed"
free_bytes=$(printf '%s\n' "$CAPTURED" | /usr/bin/awk 'NR == 2 {print $1}')
[[ "$free_bytes" =~ ^[0-9]+$ ]] || stop_for "$STEP" "free-space value is not numeric"
(( free_bytes > db_estimate + archive_bytes )) || stop_for "$STEP" "free space does not exceed measured backup inputs"
emit "PASS free_bytes=$free_bytes db_estimate=$db_estimate archive_input_estimate=$archive_bytes"

STEP=confirm-preconditions
run "effective gateway ExecStart" /usr/bin/systemctl show --property=ExecStart --value "$UNIT" ||
  stop_for "$STEP" "effective ExecStart read failed"
has "$CAPTURED" /opt/tightbeam/current/tightbeam/bin/tightbeam-gateway ||
  stop_for "$STEP" "ExecStart does not use the current selector"
run "maintenance cgroup readback" /usr/bin/systemctl show --property=ControlGroup --value "$MAINT_UNIT" ||
  stop_for "$STEP" "maintenance cgroup read failed"
eq "maintenance cgroup unchanged" "$CAPTURED" "$maint_cgroup"
prop "$UNIT" ActiveState; eq "gateway remains active before stop" "$REPLY" active

STEP=stop-service
SERVICE_STOP_ATTEMPTED=1
run "single gateway stop" /usr/bin/systemctl stop "$UNIT" || stop_for "$STEP" "gateway stop failed; no retry"
SERVICE_STOPPED=1
prop "$UNIT" ActiveState; eq "gateway state after stop" "$REPLY" inactive
prop "$UNIT" MainPID; eq "gateway PID after stop" "$REPLY" 0
prop "$UNIT" ControlGroup; stopped_cgroup=$REPLY
if [[ -z "$stopped_cgroup" ]]; then
  emit "PASS systemd cleared ControlGroup for inactive gateway with MainPID=0"
elif [[ "$stopped_cgroup" != "$gateway_cgroup" ]]; then
  stop_for "$STEP" "inactive gateway ControlGroup changed to an unexpected nonempty path"
else
  cgroup_dir="/sys/fs/cgroup$stopped_cgroup"
  cgroup_procs="$cgroup_dir/cgroup.procs"
  if [[ ! -d "$cgroup_dir" ]]; then
    prop "$UNIT" ActiveState; eq "gateway remains inactive after cgroup removal" "$REPLY" inactive
    prop "$UNIT" MainPID; eq "gateway remains without a PID after cgroup removal" "$REPLY" 0
    emit "PASS systemd removed the inactive gateway cgroup"
  elif [[ ! -e "$cgroup_procs" ]]; then
    stop_for "$STEP" "gateway cgroup remains but cgroup.procs is absent"
  elif [[ ! -r "$cgroup_procs" ]]; then
    stop_for "$STEP" "gateway cgroup process list is unreadable"
  elif run "read gateway cgroup process list" /usr/bin/cat "$cgroup_procs"; then
    [[ -z "$CAPTURED" ]] || stop_for "$STEP" "a process remains in gateway cgroup"
    emit "PASS remaining gateway cgroup process list is empty"
  elif [[ ! -e "$cgroup_dir" ]]; then
    prop "$UNIT" ActiveState; eq "gateway remains inactive after cgroup disappeared during read" "$REPLY" inactive
    prop "$UNIT" MainPID; eq "gateway remains without a PID after cgroup disappeared during read" "$REPLY" 0
    emit "PASS systemd removed the inactive gateway cgroup during readback"
  else
    stop_for "$STEP" "gateway cgroup read failed while its directory remained"
  fi
fi
if run "stopped endpoint check" /usr/bin/curl --silent --show-error --connect-timeout 2 --max-time 5 --output /dev/null http://127.0.0.1:11373/version; then
  stop_for "$STEP" "gateway endpoint still responds"
else (( LAST_RC == 7 )) || stop_for "$STEP" "endpoint did not return expected connection-refused exit 7"; fi
no_open_database_process || stop_for "$STEP" "fuser was not exit 1 with no output"
NO_WRITER=1
emit "PASS inactive service, no process reported in gateway cgroup, refused endpoint, and fuser exit 1 with no output"

STEP=offline-predecessor-stamp
old_schema_ok || { OLD_RESTORABLE="unknown; offline predecessor schema check failed"; stop_for "$STEP" "predecessor schema check failed"; }
emit "PASS offline predecessor stamp exact; no full source scan before backup"

STEP=backup
[[ ! -e "$DEST" && ! -L "$DEST" ]] || stop_for "$STEP" "backup destination appeared; preserve it"
run "final database page metadata before backup" /usr/bin/sqlite3 -readonly "$DB" 'PRAGMA page_count; PRAGMA page_size; PRAGMA max_page_count;' ||
  stop_for "$STEP" "final database page metadata read failed"
mapfile -t page_metadata <<< "$CAPTURED"
[[ ${#page_metadata[@]} == 3 ]] || stop_for "$STEP" "final database page metadata is incomplete"
page_count=${page_metadata[0]}; page_size=${page_metadata[1]}; max_pages=${page_metadata[2]}
for n in "$page_count" "$page_size" "$max_pages"; do [[ "$n" =~ ^[0-9]+$ ]] || stop_for "$STEP" "final database page metadata is incomplete"; done
(( page_count > 0 && page_size > 0 && max_pages >= page_count )) || stop_for "$STEP" "final database page capacity is invalid"
db_estimate=$((page_count * page_size))
run "final estimate of archive inputs" /usr/bin/du -sb -- "$BASE/gateway.json" "$BASE/identity" "$BASE/adapters" "$BASE/homes" "$BASE/state/users" ||
  stop_for "$STEP" "final archive input size read failed"
archive_bytes=$(printf '%s\n' "$CAPTURED" | /usr/bin/awk '{sum += $1} END {printf "%.0f\n", sum}')
[[ "$archive_bytes" =~ ^[0-9]+$ ]] || stop_for "$STEP" "final archive size estimate is not numeric"
run "final backup filesystem free bytes" /usr/bin/df -B1 --output=avail __BACKUP_PARENT__ ||
  stop_for "$STEP" "final backup free-space read failed"
free_bytes=$(printf '%s\n' "$CAPTURED" | /usr/bin/awk 'NR == 2 {print $1}')
[[ "$free_bytes" =~ ^[0-9]+$ ]] || stop_for "$STEP" "final free-space value is not numeric"
(( free_bytes > db_estimate + archive_bytes )) || stop_for "$STEP" "final free space does not exceed measured backup inputs"
emit "PASS final pre-backup free_bytes=$free_bytes db_estimate=$db_estimate archive_input_estimate=$archive_bytes"
run "create owner-only backup directory" /usr/bin/install -o __SERVICE_USER__ -g __SERVICE_GROUP__ -m 0700 -d "$DEST" ||
  stop_for "$STEP" "backup directory creation failed"
run "verify backup directory permissions" /usr/bin/stat -c 'owner=%U group=%G mode=%a path=%n' "$DEST" ||
  stop_for "$STEP" "backup directory stat failed"
has "$CAPTURED" "owner=__SERVICE_USER__ group=__SERVICE_GROUP__ mode=700 path=$DEST" ||
  stop_for "$STEP" "backup directory is not mode 0700 for __SERVICE_USER__"
for path in "$DEST/state.db" "$DEST/runtime-state.tar" "$DEST/user-files.tar" "$DEST/SHA256SUMS"; do
  [[ ! -e "$path" && ! -L "$path" ]] || stop_for "$STEP" "backup destination file exists; no overwrite"
done
run "read-only source SQLite backup" /usr/bin/sqlite3 -readonly "$DB" ".backup '$DEST/state.db'" ||
  stop_for "$STEP" "offline SQLite .backup failed"
[[ -s "$DEST/state.db" && -r "$DEST/state.db" ]] || stop_for "$STEP" "database backup absent/empty/unreadable"
run "archive gateway config identity adapters homes" /usr/bin/tar -cpf "$DEST/runtime-state.tar" -C "$BASE" -- gateway.json identity adapters homes ||
  stop_for "$STEP" "runtime state archive failed"
user_count=0
for file in "$BASE"/state/users/*/user.md; do
  [[ -f "$file" || -L "$file" ]] || continue
  rel=$(/usr/bin/printf '%s\n' "$file" | /usr/bin/sed "s#^$BASE/##")
  if (( user_count == 0 )); then
    run "create user markdown archive" /usr/bin/tar -cpf "$DEST/user-files.tar" -C "$BASE" -- "$rel" ||
      stop_for "$STEP" "user file archive failed"
  else
    run "append user markdown archive" /usr/bin/tar -rf "$DEST/user-files.tar" -C "$BASE" -- "$rel" ||
      stop_for "$STEP" "user file archive append failed"
  fi
  user_count=$((user_count + 1))
done
(( user_count > 0 )) || stop_for "$STEP" "no per-user user.md files were archived"
[[ -s "$DEST/runtime-state.tar" && -s "$DEST/user-files.tar" ]] || stop_for "$STEP" "required archive absent/empty"
run "set backup file owners" /usr/bin/chown __SERVICE_USER__:__SERVICE_GROUP__ "$DEST/state.db" "$DEST/runtime-state.tar" "$DEST/user-files.tar" ||
  stop_for "$STEP" "backup file chown failed"
run "set backup file modes" /usr/bin/chmod 0600 "$DEST/state.db" "$DEST/runtime-state.tar" "$DEST/user-files.tar" ||
  stop_for "$STEP" "backup file chmod failed"

STEP=verify-backup
run "backup quick_check (3600s cap)" /usr/bin/timeout --signal=TERM --kill-after=5s 3600s /usr/bin/sqlite3 -readonly "$DEST/state.db" 'PRAGMA quick_check;' ||
  stop_for "$STEP" "backup quick_check failed"
eq "backup quick_check" "$CAPTURED" ok
run "backup foreign_key_check (600s cap)" /usr/bin/timeout --signal=TERM --kill-after=5s 600s /usr/bin/sqlite3 -readonly "$DEST/state.db" 'PRAGMA foreign_key_check;' ||
  stop_for "$STEP" "backup foreign_key_check failed"
eq "backup foreign_key_check empty" "$CAPTURED" ""
run "backup predecessor stamp" /usr/bin/sqlite3 -readonly "$DEST/state.db" 'SELECT shape FROM schema_stamp;' ||
  stop_for "$STEP" "backup schema read failed"
eq "backup predecessor schema" "$CAPTURED" "$OLD_SCHEMA"
run "runtime archive list (3600s cap)" /usr/bin/timeout --signal=TERM --kill-after=5s 3600s /usr/bin/tar -tf "$DEST/runtime-state.tar" || stop_for "$STEP" "runtime archive listing failed"
for required_path in gateway.json identity adapters homes; do
  if ! has "$CAPTURED" "$required_path" && ! has "$CAPTURED" "$required_path/"; then
    stop_for "$STEP" "runtime archive omitted a required path"
  fi
done
run "user archive list (600s cap)" /usr/bin/timeout --signal=TERM --kill-after=5s 600s /usr/bin/tar -tf "$DEST/user-files.tar" || stop_for "$STEP" "user archive listing failed"
[[ -n "$CAPTURED" ]] || stop_for "$STEP" "user archive is empty"
run "backup ownership mode and sizes" /usr/bin/stat -c 'owner=%U group=%G mode=%a bytes=%s path=%n' "$DEST/state.db" "$DEST/runtime-state.tar" "$DEST/user-files.tar" ||
  stop_for "$STEP" "backup stat failed"
has "$CAPTURED" "owner=__SERVICE_USER__ group=__SERVICE_GROUP__ mode=600" || stop_for "$STEP" "backup files not private to __SERVICE_USER__"
run "compute backup checksums (3600s cap)" /usr/bin/timeout --signal=TERM --kill-after=5s 3600s /usr/bin/bash -c 'cd "$1" && /usr/bin/sha256sum state.db runtime-state.tar user-files.tar' bash "$DEST" ||
  stop_for "$STEP" "backup checksums failed"
backup_sums=$CAPTURED
printf '%s\n' "$backup_sums" > "$DEST/SHA256SUMS" || stop_for "$STEP" "SHA256SUMS write failed"
run "secure checksum owner" /usr/bin/chown __SERVICE_USER__:__SERVICE_GROUP__ "$DEST/SHA256SUMS" || stop_for "$STEP" "checksum chown failed"
run "secure checksum mode" /usr/bin/chmod 0600 "$DEST/SHA256SUMS" || stop_for "$STEP" "checksum chmod failed"
run "verify backup SHA256SUMS (3600s cap)" /usr/bin/timeout --signal=TERM --kill-after=5s 3600s /usr/bin/bash -c 'cd "$1" && /usr/bin/sha256sum -c SHA256SUMS' bash "$DEST" ||
  stop_for "$STEP" "backup checksum verification failed"
has "$CAPTURED" "state.db: OK" && has "$CAPTURED" "runtime-state.tar: OK" && has "$CAPTURED" "user-files.tar: OK" ||
  stop_for "$STEP" "not every backup file verified OK"
emit "BACKUP_SHA256SUMS $backup_sums"
run "verified backup size readback" /usr/bin/stat -c 'bytes=%s path=%n' "$DEST/state.db" "$DEST/runtime-state.tar" "$DEST/user-files.tar" "$DEST/SHA256SUMS" ||
  stop_for "$STEP" "verified backup metadata read failed"
emit "BACKUP_METADATA $CAPTURED"
emit "PASS offline backup, integrity, archive paths, private modes and SHA256SUMS"

STEP=select-release
run "validate staged release receipt" /usr/bin/jq -e --arg id "$NEW_ID" --arg source "$SOURCE" \
  --arg sha 9361f8b65b8f213941845da2481dc6aa3ca8ca9ad57afdc08cfbd47d4d07d7bd \
  --arg version 0.1.11 \
  '.schema == "tightbeam-staged-build/v1" and .buildId == $id and .packageSha256 == $sha and .sourceCommit == $source and .version == $version' \
  "$ROOT/builds/$NEW_ID/.tightbeam-stage.json" || stop_for "$STEP" "staged release receipt changed"
run "select verified published build" atomic_selector "$OLD_LINK" "$NEW_LINK" ||
  stop_for "$STEP" "release selection failed before service start"
run "selected link text readback" /usr/bin/readlink "$CURRENT" || stop_for "$STEP" "selector link readback failed"
eq "selected link text" "$CAPTURED" "$NEW_LINK"
run "selected symlink readback" /usr/bin/readlink -e "$CURRENT" || stop_for "$STEP" "selector readback failed"
eq "selected build target" "$CAPTURED" "$NEW_TARGET"
run "selected effective ExecStart" /usr/bin/systemctl show --property=ExecStart --value "$UNIT" ||
  stop_for "$STEP" "ExecStart readback failed"
has "$CAPTURED" /opt/tightbeam/current/tightbeam/bin/tightbeam-gateway ||
  stop_for "$STEP" "ExecStart does not use current selector"
emit "PASS selected source=$SOURCE package-sha256=$NEW_ID"

STEP=restart-baseline
prop "$UNIT" NRestarts; BASELINE_RESTARTS=$REPLY
[[ "$BASELINE_RESTARTS" =~ ^[0-9]+$ ]] || stop_for "$STEP" "NRestarts baseline not numeric"
prop "$UNIT" Restart; eq "restart policy" "$REPLY" on-failure
prop "$UNIT" RestartUSec; case "$REPLY" in 5s|5000000) ;; *) stop_for "$STEP" "restart delay changed";; esac
prop "$UNIT" StartLimitBurst; eq "start limit burst" "$REPLY" 5
prop "$UNIT" StartLimitIntervalUSec; case "$REPLY" in 10s|10000000) ;; *) stop_for "$STEP" "start limit interval changed";; esac
run "migration observation timestamp" /usr/bin/date --iso-8601=seconds || stop_for "$STEP" "start time read failed"
START_AT=$CAPTURED
[[ -n "$START_AT" ]] || stop_for "$STEP" "start timestamp empty"
emit "Migration begins at $START_AT; NRestarts baseline=$BASELINE_RESTARTS"

STEP=start-release
NEW_BOOT=1
if ! run "single 0.1.11 service start" /usr/bin/systemctl start "$UNIT"; then
  if (( LOG_FAILURE == 0 )); then
    FAILURE_EVIDENCED=1
    FAILURE_EVIDENCE_DETAIL="systemd start returned exit=$LAST_RC"
  fi
  stop_for "$STEP" "start failed or its result could not be durably recorded; migration may have begun"
fi

STEP=monitor-migration
EXPECTED_PID=
while :; do
  prop "$UNIT" ActiveState; active=$REPLY
  prop "$UNIT" SubState; substate=$REPLY
  prop "$UNIT" MainPID; main_pid=$REPLY
  prop "$UNIT" NRestarts; restarts=$REPLY
  (( LOG_FAILURE == 0 )) || stop_for "$STEP" "durable log unavailable during monitoring; service status is not being inferred"
  [[ "$restarts" =~ ^[0-9]+$ ]] || stop_for "$STEP" "NRestarts read not numeric"
  if (( restarts > BASELINE_RESTARTS )); then
    FAILURE_EVIDENCED=1
    FAILURE_EVIDENCE_DETAIL="systemd NRestarts increased from $BASELINE_RESTARTS to $restarts"
    stop_for "$STEP" "$FAILURE_EVIDENCE_DETAIL"
  elif (( restarts < BASELINE_RESTARTS )); then
    stop_for "$STEP" "NRestarts moved below its baseline; restart evidence is unavailable"
  fi
  if [[ "$active" == failed ]]; then
    FAILURE_EVIDENCED=1
    FAILURE_EVIDENCE_DETAIL="systemd reports ActiveState=failed"
    stop_for "$STEP" "$FAILURE_EVIDENCE_DETAIL"
  fi
  run "migration journal read" /usr/bin/journalctl -u "$UNIT" --since "$START_AT" --no-pager -o cat ||
    stop_for "$STEP" "journal read failed; service is not stopped without failure evidence"
  journal=$CAPTURED
  if matches "$journal" 'database migration (call [^:]+: failed|[^:]+: failed)'; then
    FAILURE_EVIDENCED=1
    FAILURE_EVIDENCE_DETAIL="journal reports a failed database migration"
    stop_for "$STEP" "$FAILURE_EVIDENCE_DETAIL"
  fi
  if has "$journal" 'database migration call finish_schema: finished'; then FINISH_MARKER=1; fi
  if [[ "$active" == active || "$active" == activating ]]; then
    if [[ "$main_pid" =~ ^[0-9]+$ ]] && (( main_pid > 0 )); then
      if [[ -z "$EXPECTED_PID" ]]; then
        EXPECTED_PID=$main_pid
        emit "Observed the starting gateway PID=$EXPECTED_PID"
      elif [[ "$main_pid" != "$EXPECTED_PID" ]]; then
        FAILURE_EVIDENCED=1
        FAILURE_EVIDENCE_DETAIL="gateway MainPID changed from $EXPECTED_PID to $main_pid"
        stop_for "$STEP" "$FAILURE_EVIDENCE_DETAIL"
      fi
    elif [[ -n "$EXPECTED_PID" ]]; then
      FAILURE_EVIDENCED=1
      FAILURE_EVIDENCE_DETAIL="gateway MainPID disappeared while systemd remained $active/$substate"
      stop_for "$STEP" "$FAILURE_EVIDENCE_DETAIL"
    else
      emit "Pending readiness: unit=$active/$substate has not exposed its initial nonzero MainPID; no service failure is evidenced"
      /usr/bin/sleep 2
      continue
    fi
  else
    FAILURE_EVIDENCED=1
    FAILURE_EVIDENCE_DETAIL="systemd reports gateway state $active/$substate with MainPID=$main_pid before release readiness"
    stop_for "$STEP" "$FAILURE_EVIDENCE_DETAIL"
  fi
  if (( LOG_FAILURE == 1 )); then stop_for "$STEP" "durable log unavailable during monitoring"; fi
  if run "new /version read" /usr/bin/curl -fsS --max-time 5 http://127.0.0.1:11373/version; then
    version=$CAPTURED
    if ! matches "$version" '"version"[[:space:]]*:[[:space:]]*"0\.1\.11"' ||
       ! matches "$version" '"build"[[:space:]]*:[[:space:]]*"?3390"?' ||
       ! matches "$version" '"sha"[[:space:]]*:[[:space:]]*"306f423'; then
      FAILURE_EVIDENCED=1
      FAILURE_EVIDENCE_DETAIL="/version returned an unexpected release identity"
      stop_for "$STEP" "$FAILURE_EVIDENCE_DETAIL"
    fi
    if (( FINISH_MARKER == 1 )); then
      emit "PASS release endpoint version=0.1.11 build=3390 source-prefix=306f423d with schema-completion marker"
      break
    fi
    emit "Release endpoint is open with the expected release identity but schema-completion marker is not yet present; pending on the same PID=$EXPECTED_PID"
  else
    curl_rc=$LAST_RC
    (( LOG_FAILURE == 0 )) || stop_for "$STEP" "durable log unavailable after endpoint observation"
    emit "Release endpoint not ready (curl exit=$curl_rc); same PID=$EXPECTED_PID remains active/activating with no failure line or restart; pending"
  fi
  /usr/bin/sleep 2
done

STEP=post-migration-integrity
run "live quick_check (3600s cap)" /usr/bin/timeout --signal=TERM --kill-after=5s 3600s /usr/bin/sqlite3 -readonly "$DB" 'PRAGMA quick_check;' || stop_for "$STEP" "quick_check failed"
eq "live quick_check" "$CAPTURED" ok
run "live foreign_key_check (600s cap)" /usr/bin/timeout --signal=TERM --kill-after=5s 600s /usr/bin/sqlite3 -readonly "$DB" 'PRAGMA foreign_key_check;' || stop_for "$STEP" "foreign_key_check failed"
eq "live foreign_key_check empty" "$CAPTURED" ""
run "live final schema stamp" /usr/bin/sqlite3 -readonly "$DB" 'SELECT shape FROM schema_stamp;' ||
  stop_for "$STEP" "final schema read failed"
eq "final schema stamp" "$CAPTURED" "$NEW_SCHEMA"

STEP=final-verification
prop "$UNIT" ActiveState; eq "final service state" "$REPLY" active
prop "$UNIT" MainPID; good_pid "final MainPID" "$REPLY"
prop "$UNIT" NRestarts; final_restarts=$REPLY
[[ "$final_restarts" =~ ^[0-9]+$ ]] || stop_for "$STEP" "final NRestarts not numeric"
if (( final_restarts > BASELINE_RESTARTS )); then
  FAILURE_EVIDENCED=1
  FAILURE_EVIDENCE_DETAIL="systemd NRestarts increased to $final_restarts during final verification"
  stop_for "$STEP" "$FAILURE_EVIDENCE_DETAIL"
fi
(( final_restarts == BASELINE_RESTARTS )) || stop_for "$STEP" "NRestarts moved below its baseline; restart evidence is unavailable"
run "final selector readback" /usr/bin/readlink -e "$CURRENT" || stop_for "$STEP" "selector read failed"
eq "final selected build" "$CAPTURED" "$NEW_TARGET"
run "final effective ExecStart" /usr/bin/systemctl show --property=ExecStart --value "$UNIT" ||
  stop_for "$STEP" "ExecStart read failed"
has "$CAPTURED" /opt/tightbeam/current/tightbeam/bin/tightbeam-gateway ||
  stop_for "$STEP" "ExecStart does not use selected build"
run "final /version read" /usr/bin/curl -fsS --max-time 5 http://127.0.0.1:11373/version ||
  stop_for "$STEP" "final /version failed"
if ! matches "$CAPTURED" '"version"[[:space:]]*:[[:space:]]*"0\.1\.11"' ||
   ! matches "$CAPTURED" '"build"[[:space:]]*:[[:space:]]*"?3390"?' ||
   ! matches "$CAPTURED" '"sha"[[:space:]]*:[[:space:]]*"306f423'; then
  FAILURE_EVIDENCED=1
  FAILURE_EVIDENCE_DETAIL="final /version did not identify the exact release"
  stop_for "$STEP" "$FAILURE_EVIDENCE_DETAIL"
fi
emit "PASS Tightbeam 0.1.11 active; schema=$NEW_SCHEMA; NRestarts=$final_restarts"
(( LOG_FAILURE == 0 )) || stop_for "$STEP" "durable log write failed before completion"
SUCCESS=1
OLD_RESTORABLE="yes only by separately approved restoration from verified backup; selector-only rollback is unsafe after migration, and later writes would be lost"
exit 0
