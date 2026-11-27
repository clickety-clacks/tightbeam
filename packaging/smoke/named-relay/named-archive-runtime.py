#!/usr/bin/env python3
"""Run paired named relay acceptance against a standard extracted Tightbeam archive."""

from contextlib import closing, contextmanager
import hashlib
import importlib.util
import json
import os
import secrets
from pathlib import Path
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import uuid

SENDER = "fixture-person"


def wait_for(check, seconds, label):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if value := check():
            return value
        time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for {label}")


def read_rows(database, sql):
    if not database.exists():
        return []
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as connection:
        return connection.execute(sql).fetchall()


def request(args, **kwargs):
    return json.loads(subprocess.check_output(args, timeout=30, **kwargs))


def recipient(path, body=None):
    identity = Path(os.environ["E2E_RECEIVER"])
    args = ["curl", "--silent", "--show-error", "--fail-with-body",
            "--cacert", os.environ["HARKLIGHT_CA_FILE"], "--cert", str(identity / "identity.pem"),
            "--key", str(identity / "identity.key"), "-H", "Harklight-Features: shared_messages"]
    if body is not None:
        args += ["-H", f"Idempotency-Key: {uuid.uuid4()}", "-H", "Content-Type: application/json",
                 "--data", json.dumps(body)]
    return request([*args, "https://localhost:" + os.environ["HARKLIGHT_DEVICE_PORT"] + path])


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


@contextmanager
def watcher(relay, root, env, log):
    process = subprocess.Popen(
        [sys.executable, relay, "--watch", "--config", root / "relay.json",
         "--state-dir", root / "relay-state"], cwd=root / "relay",
        env=env, stdout=log, stderr=log, start_new_session=True)
    try:
        yield process
        process.send_signal(signal.SIGTERM)
        if process.wait(timeout=10) != 0:
            raise RuntimeError("packaged relay did not stop cleanly")
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGCONT)
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)


def main(archive, root, smoke_path):
    spec = importlib.util.spec_from_file_location("gateway_smoke", smoke_path)
    smoke = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(smoke)
    root.mkdir(mode=0o700)
    subprocess.run([sys.executable, smoke_path.with_name("extract-payload.py"), archive, root],
                   check=True, timeout=60)
    package = root / "tightbeam"
    for name in ("home", "base", "tmp", "tools", "fault"):
        (root / name).mkdir(mode=0o700)
    gateway = package / "bin/tightbeam-gateway"
    cli = package / "bin/tightbeam"
    relay = package / "optional/harklight-people-relay/source/relay.py"
    agent = Path(os.environ["E2E_REAL_AGENT"])
    manifest = json.loads(relay.with_name("SOURCE.json").read_text())
    assert manifest["tree"] == "0266df678aab4f482cc0cfae88c98a23220d8282"
    for name, path in (("archive", archive), ("gateway", gateway), ("cli", cli), ("relay", relay), ("agent", agent)):
        print(f"{name} SHA-256 {digest(path)}")
    print(f"relay tree {manifest['tree']}")
    expected = json.loads((package / "package.json").read_text())["version"]
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]

    env = {
        "PATH": os.pathsep.join(map(str, [root / "tools", package / "bin", agent.parent, os.environ["PATH"]])),
        "HOME": str(root / "home"), "TMPDIR": str(root / "tmp"), "LC_ALL": "C",
        "TIGHTBEAM_BASE_DIR": str(root / "base"), "TIGHTBEAM_PORT": str(port),
        "TIGHTBEAM_LOCAL_HOST_NAME": "packaged-smoke", "TIGHTBEAM_DEFAULT_HARNESS": "claude",
        "TIGHTBEAM_LOOPBACK_ONLY": "true", "TIGHTBEAM_PEOPLE_MESSAGING": "true",
        "TIGHTBEAM_PEOPLE_MESSAGE_RELAY_SESSION": "agent:relay-fixture:relay",
        "ERL_FLAGS": "+S 4:4 +SDcpu 2 +SDio 2", "npm_config_offline": "true",
        "RELAY_PROOF_ROOT": str(root), "RELAY_PROOF_URL": f"http://127.0.0.1:{port}",
        "RELAY_PROOF_SEED": str(Path(__file__).with_name("seed-named-relay.exs").resolve()),
        "PYTHONDONTWRITEBYTECODE": "1",
        "HARKLIGHT_CA_FILE": os.environ["HARKLIGHT_CA_FILE"],
        "HARKLIGHT_DEVICE_PORT": os.environ["HARKLIGHT_DEVICE_PORT"],
    }
    discovery = root / "tools/claude"
    discovery.write_text('#!/bin/sh\ncase "$1" in --version) echo "2.1.280";; *) exit 64;; esac\n')
    discovery.chmod(0o700)
    descriptor = root / "base/gateway.json"
    descriptor.touch(mode=0o600, exist_ok=False)
    descriptor.write_text(json.dumps({"cliToken": "tbc_" + secrets.token_urlsafe(24)}))
    (root / "relay.json").write_text(json.dumps({
        "connection": os.environ["E2E_IDENTITY"], "sender": "app:relay-e2e",
        "users": {SENDER: os.environ["E2E_PERSON"]},
    }))
    seed = """
      for {label, action} <- [
        {"distribution check", fn -> false = Node.alive?() end},
        {"application startup", fn -> {:ok, _} = Application.ensure_all_started(:tightbeam) end},
        {"fixture rows", fn -> Code.require_file(System.fetch_env!("RELAY_PROOF_SEED")) end},
        {"application stop", fn -> :ok = Application.stop(:tightbeam) end}
      ] do
        try do
          action.()
          IO.puts("RELAY_PROOF_SEED: " <> label <> " OK")
        rescue
          exception ->
            stack = Enum.map(__STACKTRACE__, fn {m, f, a, _} ->
              {m, f, if(is_list(a), do: length(a), else: a)}
            end)
            IO.puts("RELAY_PROOF_SEED: " <> label <> " failed: " <>
              inspect(exception.__struct__) <> " " <> inspect(stack))
            System.halt(1)
        end
      end
    """
    wait_marker = root / "watcher-wait"
    wrapper = root / "fault/tightbeam"
    wrapper.write_text("""#!/bin/sh
if [ "$1" = people-wait ]; then
  printf '%s\\n' "$$" > "$RELAY_WAIT_MARKER"
fi
if [ -n "$E2E_LOST_ACCEPT" ]; then
  exec "$RELAY_FAULT_SCRIPT" "$@"
fi
exec "$E2E_REAL_TIGHTBEAM" "$@"
""")
    wrapper.chmod(0o700)
    relay_env = dict(env, PATH=str(wrapper.parent) + os.pathsep + env["PATH"],
                     RELAY_WAIT_MARKER=str(wait_marker), E2E_REAL_TIGHTBEAM=str(cli),
                     RELAY_FAULT_SCRIPT=str(Path(os.environ["RELAY_FAULT_SCRIPT"]).resolve()),
                     E2E_LOST_ACCEPT="")

    def tb(role, command, body):
        return request([cli, command, "--json", json.dumps(body)], cwd=root / role, env=env)

    def reported(id):
        rows = tb("sender", "people-status", {"conversation_id": id})["operations"]
        return rows if len(rows) == 2 and all(row["delivery_state"] == "reported" for row in rows) else None

    with (root / "gateway.private.log").open("wb") as gateway_log, (root / "watch.private.log").open("wb") as watch_log:
        result = subprocess.run([gateway, "eval", seed], cwd=root, env=env,
                                capture_output=True, text=True, timeout=75)
        for line in result.stdout.splitlines():
            if line.startswith("RELAY_PROOF_SEED:"):
                print(line)
        result.check_returncode()
        with smoke.start_gateway(gateway, root, env, port, None, gateway_log, expected):
            print(f"packaged gateway {expected}: verified owned process and sole loopback listener")
            readiness = tb("relay", "people-wait", {"limit": 1, "timeout_ms": 20})
            assert readiness == {"records": []}, readiness
            print("PASS bounded authenticated packaged people-wait")
            with watcher(relay, root, relay_env, watch_log) as process:
                # The wrapper observes invocation before broker registration. The
                # ordinary people_messages tests deterministically cover parking.
                wait_for(wait_marker.exists, 10, "watcher invoking authenticated wait")
                process.send_signal(signal.SIGSTOP)
                try:
                    record = tb("sender", "people-send", {
                        "addresses": ["user:" + SENDER], "title": "Idle boundary",
                        "body": "synthetic", "work_item_id": "wi-relay-fixture",
                    })["record"]["id"]
                    tb("sender", "people-update", {"conversation_id": record, "revision": 1,
                                                   "title": "Revised", "body": "next"})
                finally:
                    process.send_signal(signal.SIGCONT)
                first, updated = wait_for(lambda: reported(record), 15, "ordered send and update")
                shared = first["report"]["remote_conversation_id"]
                item = next(item for item in recipient("/v2/inbox")["items"]
                            if item["shared"]["shared_id"] == shared)
                assert updated["report"]["remote_revision"] == item["request_revision"] == 2
                assert first["report"]["outcomes"] == [{"address": "user:" + SENDER, "status": "reached"}]
                print("PASS stock named delivery and ordered revision after observed wait invocation")
            fault_marker = root / "lost-accept"
            relay_db = root / "relay-state/relay.db"
            gateway_db = root / "base/state.db"
            with watcher(relay, root, dict(relay_env, E2E_LOST_ACCEPT=str(fault_marker)), watch_log):
                recipient("/v2/items/" + item["item_id"] + "/replies", {"text": "Replay on receipt loss"})
                wait_for(fault_marker.exists, 15, "committed Chat reply with response loss")
                wakes = read_rows(gateway_db, "SELECT wakeId FROM people_events WHERE kind='chat'")
                assert len(wakes) == 1 and wakes[0][0]
                held = read_rows(relay_db, "SELECT checkpoint FROM feed")
                wait_for(lambda: read_rows(relay_db, "SELECT count(*) FROM events") == [(0,)]
                         and read_rows(relay_db, "SELECT checkpoint FROM feed") != held,
                         30, "replay advancing relay checkpoint")
                assert read_rows(gateway_db, "SELECT wakeId FROM people_events WHERE kind='chat'") == wakes
                print("PASS accepted Chat replay retained one durable wake and advanced checkpoint")
    print("PASS packaged watcher, gateway, and listener shutdown")


if __name__ == "__main__":
    main(*(Path(value).resolve() for value in sys.argv[1:]))
