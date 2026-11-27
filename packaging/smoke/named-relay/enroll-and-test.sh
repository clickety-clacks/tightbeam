#!/usr/bin/env bash
set -euo pipefail
sandbox=$(pwd -P)
server="$sandbox/harklight-server-0.2.34-linux-x86_64"
agent_dir="$sandbox/harklight-agent-0.2.10-x86_64-unknown-linux-gnu"
state="$sandbox/server-state"
export E2E_ROOT="$sandbox" E2E_IDENTITY="$sandbox/relay-identity"
export E2E_PERSON="$(cat "$state/person-id")"
export PATH="$agent_dir:$PATH" E2E_REAL_AGENT="$agent_dir/harklight-agent"
export HARKLIGHT_DEVICE_PORT="$ATTENTION_SERVER_PORT"
export HARKLIGHT_CA_FILE="$state/tls/ca.pem"
export E2E_RECEIVER="$sandbox/receiver-identity"
enroll() {
    local directory=$1 label=$2 code
    shift 2
    local args=(--directory "$directory" --connect 127.0.0.1 --name localhost --port "$ATTENTION_SERVER_ENROLL_PORT" --ca "$HARKLIGHT_CA_FILE")
    "$server/bin/harklight" enroll start "${args[@]}" --label "$label" >"$directory.enroll.private.log" 2>&1
    code=$(sed -n 's/.*approval code: \([^;]*\);.*/\1/p' "$directory.enroll.private.log")
    test -n "$code"
    printf 'APPROVE\n' | "$server/bin/harklight" owner approve --connect 127.0.0.1 --name localhost \
        --port "$ATTENTION_SERVER_OWNER_PORT" --ca "$HARKLIGHT_CA_FILE" \
        --cert "$state/owner/identity.pem" --key "$state/owner/identity.key" \
        --person "$E2E_PERSON" --code "$code" "$@" >"$directory.approve.private.log" 2>&1
    "$server/bin/harklight" enroll status "${args[@]}" --device-port "$HARKLIGHT_DEVICE_PORT" >>"$directory.enroll.private.log" 2>&1
}
enroll "$E2E_IDENTITY" 'Disposable relay' --senders app:relay-e2e
enroll "$E2E_RECEIVER" 'Disposable receiver'
harklight-agent --identity-dir "$E2E_IDENTITY" --state-dir "$sandbox/probe-journal" capabilities
exec python3 "$RELAY_ARCHIVE_DRIVER" "$RELAY_ARCHIVE" "$sandbox/packaged-gateway" "$RELAY_GATEWAY_SMOKE"
