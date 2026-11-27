#!/usr/bin/env bash
# Run only in a reserved sandbox containing the two published archives.
set -euo pipefail
umask 077
sandbox=$(pwd -P)
export HOME="$sandbox/home"
export XDG_CONFIG_HOME="$HOME/config" XDG_DATA_HOME="$HOME/data" XDG_STATE_HOME="$HOME/state"
mkdir -p "$HOME" "$sandbox/tmp"
export TMPDIR="$sandbox/tmp"
export ERL_FLAGS='+S 2:2 +SDcpu 1 +SDio 1'
export RELEASE_DISTRIBUTION=none
server="$sandbox/harklight-server-0.2.34-linux-x86_64"
agent="$sandbox/harklight-agent-0.2.10-x86_64-unknown-linux-gnu/harklight-agent"
state="$sandbox/server-state"
for component in server agent; do
    (cd "$component" && sha256sum --check --ignore-missing SHA256SUMS)
    tar -xzf "$component"/*.tar.gz
done
cat "$server/BUILD_INFO"
sha256sum "$agent" "$server/bin/attention_server" "$server"/erts-*/bin/beam.smp
"$agent" --version
"$server/bin/harklight-bootstrap" "$state" localhost >"$sandbox/bootstrap.private.log" 2>&1
. "$state/server.env"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Disposable outside owner' \
    -keyout "$sandbox/outside.key" -out "$sandbox/outside.pem" >"$sandbox/outside.private.log" 2>&1
E2E_OUTSIDE=$("$server/bin/harklight" operator bootstrap --store "$state/relay.sqlite3" \
    --owner-cert "$sandbox/outside.pem")
export E2E_OUTSIDE
"$server/bin/harklight" operator organization-remove --store "$state/relay.sqlite3" \
    --person "$E2E_OUTSIDE" >>"$sandbox/outside.private.log" 2>&1
printf 'Second synthetic owner created and removed from default organization before serving\n'

read -r ATTENTION_SERVER_PORT ATTENTION_SERVER_ENROLL_PORT ATTENTION_SERVER_OWNER_PORT < <(
    python3 - <<'PY'
import socket
with socket.socket() as first, socket.socket() as second, socket.socket() as third:
    sockets = [first, second, third]
    for connection in sockets:
        connection.bind(("127.0.0.1", 0))
    print(*(connection.getsockname()[1] for connection in sockets))
PY
)
export ATTENTION_SERVER_PORT ATTENTION_SERVER_ENROLL_PORT ATTENTION_SERVER_OWNER_PORT
export ATTENTION_SERVER_BIND=127.0.0.1 ATTENTION_SERVER_ENROLL_BIND=127.0.0.1 ATTENTION_SERVER_OWNER_BIND=127.0.0.1
export ATTENTION_SERVER_DEPLOYMENT_MODE=self_hosted ATTENTION_SERVER_SHARED_MESSAGES=1 ATTENTION_SERVER_GROUPS=0
"$server/bin/attention_server" start >"$sandbox/server.private.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :' EXIT
for attempt in {1..50}; do
    kill -0 "$pid"
    if (echo >/dev/tcp/127.0.0.1/"$ATTENTION_SERVER_ENROLL_PORT") 2>/dev/null; then
        printf 'Disposable self-hosted Server listening on loopback ports %s %s %s\n' \
           "$ATTENTION_SERVER_PORT" "$ATTENTION_SERVER_ENROLL_PORT" "$ATTENTION_SERVER_OWNER_PORT"
        if [ "$#" -gt 0 ]; then
            "$@"
        fi
        exit 0
    fi
    sleep .2
done
exit 1
