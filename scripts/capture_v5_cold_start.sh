#!/bin/sh
set -eu

SOURCE=${1:?usage: capture_v5_cold_start.sh SOURCE_CLONE OUTPUT_DIR}
OUTPUT=${2:?usage: capture_v5_cold_start.sh SOURCE_CLONE OUTPUT_DIR}
CAPTURE=$(mktemp -d "${TMPDIR:-/tmp}/tightbeam-v5-capture.XXXXXX")
trap 'test -d "$CAPTURE" && rm -rf "$CAPTURE"' EXIT HUP INT TERM

git clone --no-local "$SOURCE" "$CAPTURE/source"
git -C "$CAPTURE/source" checkout --detach d00e06aea578d711e608637d38a97872487df15e

(cd "$CAPTURE/source" && /home/mike/.cargo/bin/cargo build --release --manifest-path cli/Cargo.toml)
(cd "$CAPTURE/source" && mise exec -- mix deps.get)
(cd "$CAPTURE/source" && env MIX_ENV=prod mise exec -- mix release)

mkdir -p "$CAPTURE/empty" "$CAPTURE/healthy" "$CAPTURE/user-only" \
  "$CAPTURE/admin-pending" "$CAPTURE/allowlisted-no-main"

RELEASE="$CAPTURE/source/_build/prod/rel/tightbeam_gateway/bin/tightbeam_gateway"
CLI="$CAPTURE/source/cli/target/release/tightbeam"
CAPTURE_PATH="$CAPTURE/source/priv/harness_cli:/home/mike/.local/bin:/usr/local/bin:/usr/bin:/bin"

release_command() {
  env -u RELEASE_BOOT_SCRIPT -u RELEASE_BOOT_SCRIPT_CLEAN -u RELEASE_COMMAND \
    -u RELEASE_COOKIE -u RELEASE_DISTRIBUTION -u RELEASE_MODE -u RELEASE_NAME \
    -u RELEASE_NODE -u RELEASE_PROG -u RELEASE_REMOTE_VM_ARGS -u RELEASE_ROOT \
    -u RELEASE_SYS_CONFIG -u RELEASE_TMP -u RELEASE_VM_ARGS -u RELEASE_VSN \
    TIGHTBEAM_BASE_DIR="$1" TIGHTBEAM_PORT="$2" \
    TIGHTBEAM_LOCAL_HOST_NAME=capture-host PATH="$CAPTURE_PATH" "$RELEASE" "$3"
}

start_gateway() {
  release_command "$1" "$2" start >"$1/capture.log" 2>&1 &
  GATEWAY_PID=$!
  attempts=0
  until test -f "$1/gateway.json"; do
    attempts=$((attempts + 1))
    test "$attempts" -lt 200 || { echo "gateway did not start: $1" >&2; exit 1; }
    sleep 0.1
  done
}

stop_gateway() {
  release_command "$1" "$2" stop
  wait "$GATEWAY_PID"
}

pair_flow() {
  node -e '
    const [port, deviceId, claimedName, authenticate] = process.argv.slice(1);
    const url = `ws://127.0.0.1:${port}/ws`;
    const pair = new WebSocket(url);
    pair.addEventListener("open", () => pair.send(JSON.stringify({
      type: "pair_request", protocolVersion: 1, deviceId, claimedName,
      deviceInfo: {platform: "capture", model: "v5"}
    })));
    pair.addEventListener("message", event => {
      const result = JSON.parse(event.data);
      if (!result.success) throw new Error(`pair failed: ${result.reason}`);
      if (authenticate !== "auth") process.exit(0);
      const auth = new WebSocket(url);
      auth.addEventListener("open", () => auth.send(JSON.stringify({
        type: "auth", token: result.token, deviceId
      })));
      auth.addEventListener("message", authEvent => {
        if (JSON.parse(authEvent.data).type === "sync_complete") process.exit(0);
      });
    });
    setTimeout(() => process.exit(1), 10000);
  ' "$1" "$2" "$3" "$4"
}

pending_flow() {
  node -e '
    const [port] = process.argv.slice(1);
    const socket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    socket.addEventListener("open", () => socket.send(JSON.stringify({
      type: "pair_request", protocolVersion: 1, deviceId: "pending-device",
      claimedName: "captured-admin", deviceInfo: {platform: "capture", model: "v5"}
    })));
    socket.addEventListener("message", event => {
      const result = JSON.parse(event.data);
      process.exit(!result.success && result.reason === "pair_pending" ? 0 : 1);
    });
    setTimeout(() => process.exit(1), 10000);
  ' "$1"
}

start_gateway "$CAPTURE/empty" 21473
stop_gateway "$CAPTURE/empty" 21473

start_gateway "$CAPTURE/healthy" 21474
pair_flow 21474 captured-device "Captured Admin" auth
stop_gateway "$CAPTURE/healthy" 21474

start_gateway "$CAPTURE/user-only" 21475
env TIGHTBEAM_BASE_DIR="$CAPTURE/user-only" \
  "$CLI" add-user captured-admin --as-user captured-admin >/dev/null
stop_gateway "$CAPTURE/user-only" 21475

cp "$CAPTURE/user-only/state.db" "$CAPTURE/admin-pending/state.db"
start_gateway "$CAPTURE/admin-pending" 21476
pending_flow 21476
stop_gateway "$CAPTURE/admin-pending" 21476

start_gateway "$CAPTURE/allowlisted-no-main" 21477
pair_flow 21477 allowlisted-device "Captured No Main" no-auth
stop_gateway "$CAPTURE/allowlisted-no-main" 21477

for name in empty healthy user-only admin-pending allowlisted-no-main; do
  destination="$OUTPUT/v5-$name"
  mkdir -p "$destination"
  cp "$CAPTURE/$name/state.db" "$destination/state.db"
  sha256sum "$destination/state.db"
  sqlite3 "$destination/state.db" \
    "select shape from schema_stamp; select 'users',count(*) from users union all select 'devices',count(*) from devices union all select 'sessions',count(*) from sessions union all select 'events',count(*) from events;"
done
