# 0.1.9 gateway surface checks

This runbook checks the packaged gateway shim, REST authentication and the D1
reads, and CLI transport diagnostics. It runs offline inside the verified
[containment](README.md#containment) boundary, from a
[CLI shell](README.md#cli-shell) with the README's
[gateway helper](README.md#gateway-start-and-stop) defined. It needs no provider
turn. Every command uses the verified package by absolute path; never call an
installed shim, and never name a live base.

The admission checks for `TIGHTBEAM_LIVE_BASE_TRANSITION` (PR #183) run in the
migration runbook: [build admission](migration.md#build-admission) and the
[left-set refusal](migration.md#left-set-refusal).

## Shim verbs

<a id="shim-verbs"></a>

```sh
status=0; env -u TIGHTBEAM_BASE_DIR "${PKG:?}/bin/tightbeam-gateway" restart || status=$?
echo "restart exit: $status"
status=0; env -u TIGHTBEAM_BASE_DIR "$PKG/bin/tightbeam-gateway" stop || status=$?
echo "stop without a base exit: $status"
```

| Check | Pass condition |
|---|---|
| `restart` | Exit 64 with a refusal. The shim has no restart verb; nothing starts or stops. |
| `stop` with `TIGHTBEAM_BASE_DIR` unset | Exit 64 with a refusal naming the missing base. Nothing is signalled. |

## Stop isolation

<a id="stop-isolation"></a>

Two gateways on new empty bases. Stopping one through its own base must not reach
the other, even when the shell carries the other's node name, port and a cookie.

The check runs in a subshell with its own cleanup, registered before either
start, so the shared `gateway_stop` trap stays in place for later sections.
The cleanup stops the gateway `gateway_start` last launched through the shared
`gateway_stop`, which knows it from launch, so an interrupt during readiness
polling still stops it; once B is up it moves to `pid_b`. The subshell clears
`gateway_pid` first so it never stops a gateway the parent shell started.

```sh
(
base_a="$(mktemp -d "${SCRATCH:?}/stop-a.XXXXXX")"; base_a="$(cd "$base_a" && pwd -P)"
base_b="$(mktemp -d "$SCRATCH/stop-b.XXXXXX")"; base_b="$(cd "$base_b" && pwd -P)"
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
port_a="$(free_port)"; port_b="$(free_port)"
gateway_pid=""; pid_b=""
stop_pair() {
  gateway_stop
  if test -n "$pid_b"; then
    TIGHTBEAM_BASE_DIR="$base_b" "$PKG/bin/tightbeam-gateway" stop || true
    wait "$pid_b" || true; pid_b=""
  fi
}
trap stop_pair EXIT
trap 'exit 130' INT TERM
gateway_start "$base_b" "$port_b" "$base_b.log" || exit 1
pid_b="$gateway_pid"; gateway_pid=""
gateway_start "$base_a" "$port_a" "$base_a.log" || exit 1
RELEASE_NODE="tightbeam_gateway_$port_b" TIGHTBEAM_PORT="$port_b" \
  RELEASE_COOKIE="runbook-sentinel-not-a-cookie" TIGHTBEAM_BASE_DIR="$base_a" \
  "$PKG/bin/tightbeam-gateway" stop
wait "$gateway_pid" || true; gateway_pid=""
curl -fsS --noproxy '*' "http://127.0.0.1:$port_a/version" && echo "A still serving"
curl -fsS --noproxy '*' "http://127.0.0.1:$port_b/version" >/dev/null && echo "B serving"
stop_pair
)
```

Pass: gateway A exits, the first `curl` fails, and the output ends with
`B serving`. The environment variables did not redirect the stop to B.

## REST authentication and D1 reads

<a id="rest-d1"></a>

Run against a gateway on a new copy of the migrated result
([reuse the result](migration.md#reuse-the-result)), started in this shell so
the shared `gateway_stop` trap stops it on failure or exit. The probe reads the
area gateway's own descriptor for its operator token, keeps the token and all
response bodies in memory, and prints only the assertion result.

```sh
test_admin="$(sqlite3 -readonly "${AREA_BASE:?}/state.db" "SELECT userId FROM users WHERE isAdmin = 1 ORDER BY userId LIMIT 1")"
python3 - "$AREA_BASE/gateway.json" "${AREA_PORT:?}" "${test_admin:?}" <<'PY'
import json
import sys
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import ProxyHandler, Request, build_opener

descriptor_path, port, test_admin = sys.argv[1:]
with open(descriptor_path, encoding="utf-8") as f:
    token = json.load(f)["cliToken"]
base = f"http://127.0.0.1:{port}"
query = urlencode({"asUser": test_admin})
opener = build_opener(ProxyHandler({}))

def get(path, with_token=True):
    headers = {"Authorization": f"Bearer {token}"} if with_token else {}
    try:
        response = opener.open(Request(base + path, headers=headers))
    except HTTPError as error:
        response = error
    return response.code, response.headers, json.loads(response.read())

collections = [
    ("/api/config", "config"),
    ("/api/host-env", "host environment"),
    ("/api/hosts", "hosts"),
    ("/api/users", "users"),
    ("/api/identity", "identity"),
    ("/api/kungfu", "kungfu"),
]
for route, resource in collections:
    status, headers, payload = get(route + "?" + query)
    assert status == 200 and headers.get("Cache-Control") == "no-store", route
    assert payload["schemaVersion"] == 1 and payload["resource"] == resource, route
    assert isinstance(payload["items"], list), route

status, _, listing = get("/api/kungfu?" + query)
if listing["items"]:
    item = listing["items"][0]
    status, headers, detail = get("/api/kungfu/" + quote(item["name"], safe="") + "?" + query)
    assert status == 200 and headers.get("Cache-Control") == "no-store"
    assert detail["schemaVersion"] == 1 and detail["resource"] == "kungfu"
    assert detail["item"] == item
    print("kungfu detail checked")
else:
    print("kungfu detail skipped: no learned bundle in this copy")

status, headers, invalid = get("/api/kungfu?" + query + "&unknown=value")
assert status == 400 and invalid["error"]["code"] == "invalid_filter"
assert headers.get("Cache-Control") == "no-store"

status, headers, missing_auth = get("/api/hosts", with_token=False)
assert status == 401 and headers.get("Cache-Control") == "no-store"
assert missing_auth["schemaVersion"] == 1 and missing_auth["resource"] == "hosts"
assert missing_auth["error"]["code"] == "auth_failed"
print("D1 collection, filter and authentication assertions passed")
PY
gateway_stop
```

Pass: the probe exits 0 and prints its final line. An unauthenticated
`GET /api/hosts` returns 401 with
`{"schemaVersion":1,"resource":"hosts","error":{"code":"auth_failed"}}`
(0.1.8 answered 404). Each collection reports its resource and schema version 1,
every response is `no-store`, and an unknown filter is `400 invalid_filter`.
`gateway_stop` then stops the area gateway; delete its base afterwards.

## CLI transport diagnostics

<a id="cli-transport-diagnostics"></a>

The CLI reports an unreachable gateway as a typed transport failure and records a
receipt. Point it at a loopback port with nothing listening and a new scratch
base, from the CLI shell's marker-free directory:

```sh
diag_base="$(mktemp -d "${SCRATCH:?}/diag.XXXXXX")"
closed_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
status=0
TIGHTBEAM_URL="http://127.0.0.1:$closed_port" TIGHTBEAM_TOKEN=not-a-token \
  TIGHTBEAM_BASE_DIR="$diag_base" "${PKG:?}/bin/tightbeam" list >"$diag_base/out.json" 2>"$diag_base/err.txt" || status=$?
echo "exit: $status"
cat "$diag_base/out.json" "$diag_base/err.txt"
wc -l "$diag_base/diagnostics/cli-transport-v1.log"
```

Pass: exit 1. The JSON reports `error.code` `transport_failed`,
`attempt.diagnostic.code` `gateway_unavailable` (connection refused, safe to
retry) and `attempt.receipt` `recorded`. `diagnostics/cli-transport-v1.log`
under the scratch base holds a `cli_transport_failed` record with code
`gateway_unavailable` and no token.
