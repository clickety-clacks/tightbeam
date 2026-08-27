#!/bin/sh
set -eu

MODE=${1:?usage: derive_cold_start_fixtures_v1.sh MODE SOURCE_SET DESTINATION_SET}
SOURCE=${2:?usage: derive_cold_start_fixtures_v1.sh MODE SOURCE_SET DESTINATION_SET}
DESTINATION=${3:?usage: derive_cold_start_fixtures_v1.sh MODE SOURCE_SET DESTINATION_SET}

test -f "$SOURCE/state.db"
test ! -e "$DESTINATION/state.db"
mkdir -p "$DESTINATION"

for suffix in '' '-wal' '-shm'; do
  if test -f "$SOURCE/state.db$suffix"; then
    cp "$SOURCE/state.db$suffix" "$DESTINATION/state.db$suffix"
  fi
done

case "$MODE" in
  missing-main-parent)
    changed=$(sqlite3 "$DESTINATION/state.db" <<'SQL'
PRAGMA foreign_keys=OFF;
BEGIN IMMEDIATE;
UPDATE sessions
SET operationalParent='agent:missing:cold-start-parent'
WHERE kind='main' AND isBuiltIn=1 AND state='active';
SELECT changes();
COMMIT;
SQL
    )
    test "$changed" = 1 || {
      echo "missing-main-parent derivation expected exactly one active built-in Main" >&2
      exit 65
    }
    ;;
  *)
    echo "unknown cold-start fixture derivation: $MODE" >&2
    exit 64
    ;;
esac

sqlite3 "$DESTINATION/state.db" "PRAGMA foreign_keys; PRAGMA integrity_check;"
for suffix in '' '-wal' '-shm'; do
  if test -f "$DESTINATION/state.db$suffix"; then
    sha256sum "$DESTINATION/state.db$suffix"
  fi
done
