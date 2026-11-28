#!/usr/bin/env python3
"""Check the exact packaged gateway using only its ordinary HTTP listener."""
from pathlib import Path
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import sqlite3
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from urllib.error import HTTPError
from urllib.parse import quote
from contextlib import closing, contextmanager

LOOPBACK = "127.0.0.1"


class SmokeError(Exception):
    pass


def observe(args):
    return subprocess.run(args, text=True, capture_output=True, timeout=10)


def linux_listener_ports(pid):
    sockets = set()
    for fd in Path(f"/proc/{pid}/fd").iterdir():
        try:
            target = os.readlink(fd)
        except FileNotFoundError:
            continue
        if target.startswith("socket:["):
            sockets.add(target[8:-1])
    ports = set()
    for family in ("tcp", "tcp6"):
        table = Path(f"/proc/{pid}/net/{family}")
        if family == "tcp6" and not table.exists():
            continue
        for line in table.read_text().splitlines()[1:]:
            fields = line.split()
            if fields[3] == "0A" and fields[9] in sockets:
                ports.add(int(fields[1].rsplit(":", 1)[-1], 16))
    return ports


_lsof_warnings_seen = set()


def lsof_errors(stderr):
    """Split lsof stderr into its own warnings and anything else.

    lsof reports file systems it cannot stat (for example a mount under
    another user's home) as "lsof: WARNING: ..." plus indented continuation
    lines. Those concern other files, not the sockets selected with -p and
    -i, so they are accepted. Only their number is logged, so a public log
    shows no host paths. Any other output is an error.
    """
    errors, in_warning = [], False
    for line in stderr.splitlines():
        if line.startswith("lsof: WARNING:"):
            in_warning = True
            if line not in _lsof_warnings_seen:
                _lsof_warnings_seen.add(line)
                print(f"gateway-smoke: accepted {len(_lsof_warnings_seen)} distinct lsof warning(s)",
                      file=sys.stderr)
        elif in_warning and line[:1].isspace():
            continue
        elif line.strip():
            in_warning = False
            errors.append(line)
    return errors


def redact_homes(text):
    return re.sub(r"/(Users|home)/[^/\s:;]+", r"/\1/<user>", text)


def listeners(pid, port, lsof):
    if sys.platform == "linux":
        ports = linux_listener_ports(pid)
    else:
        result = observe([lsof, "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"])
        errors = lsof_errors(result.stderr)
        if result.returncode not in (0, 1) or errors:
            detail = redact_homes("; ".join(errors))[:500] or "no error output"
            raise SmokeError(
                f"cannot inspect test process listeners (lsof exit {result.returncode}: {detail})")
        ports = {int(line.rsplit(":", 1)[-1]) for line in result.stdout.splitlines()
                 if line.startswith("n")}
    if ports - {port}:
        raise SmokeError("test gateway owns an extra TCP listener")
    return port in ports


def check_epmd(package, gateway_pid, lsof):
    result = observe(["ps", "-axo", "pid=,ppid=,pgid=,comm="])
    if result.returncode != 0:
        raise SmokeError("cannot inspect test host processes")
    processes = {}
    for line in result.stdout.splitlines():
        pid, parent, group, command = line.strip().split(maxsplit=3)
        processes[int(pid)] = (int(parent), int(group), command)

    for pid, (parent, group, command) in processes.items():
        if Path(command).name != "epmd":
            continue
        ancestor = parent
        while ancestor > 1 and ancestor != gateway_pid and ancestor in processes:
            ancestor = processes[ancestor][0]
        if group == gateway_pid or ancestor == gateway_pid:
            raise SmokeError("test gateway started EPMD")
        if command.startswith(str(package) + "/"):
            raise SmokeError("test package started EPMD")
        if sys.platform == "linux":
            try:
                paths = [os.readlink(f"/proc/{pid}/exe")]
            except (FileNotFoundError, PermissionError):
                continue
        else:
            executable = observe([lsof, "-nP", "-a", "-p", str(pid), "-d", "txt", "-Fn"])
            paths = [line[1:] for line in executable.stdout.splitlines() if line.startswith("n")]
        if any(path.startswith(str(package) + "/") for path in paths):
            raise SmokeError("test package started EPMD")


def kill_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def epmd_attribution_control(root, lsof):
    # Exercise attribution only. These external processes never listen on a socket.
    standin = root / "tools/epmd"
    normal_binary = root / "tools/smoke-standby"
    subprocess.run(
        ["cc", "-x", "c", "-o", str(standin), "-"],
        input='#include <unistd.h>\nint main(void) { sleep(15); return 0; }\n',
        text=True, capture_output=True, timeout=20, check=True,
    )
    shutil.copyfile(standin, normal_binary)
    normal_binary.chmod(0o700)
    # The two synthetic instances have separate process groups, as on a shared host.
    unrelated = subprocess.Popen([standin], start_new_session=True)
    normal = subprocess.Popen([normal_binary], start_new_session=True)
    try:
        check_epmd(root / "tightbeam", normal.pid, lsof)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and unrelated.poll() is None:
            try:
                check_epmd(root / "tightbeam", unrelated.pid, lsof)
            except SmokeError as error:
                if str(error) == "test gateway started EPMD":
                    return
                raise
            time.sleep(0.05)
        raise SmokeError("attributable external EPMD control was accepted")
    finally:
        kill_group(normal)
        kill_group(unrelated)


def packaged_listener_control(gateway, root, env, origin, port, lsof, log, expected):
    # Start the packaged gateway and inject a harmless second loopback socket.
    # The control never enables distribution, starts EPMD or connects to that socket.
    marker = root / "listener-control-ready"
    expression = (
        'spawn(fun() -> {ok, S} = gen_tcp:listen(0, [{ip, {127,0,0,1}}]), '
        'ok = file:write_file(os:getenv("TB_SMOKE_MARKER"), <<>>), '
        'receive smoke_stop -> gen_tcp:close(S) end end).'
    )
    flags = "-eval '" + expression + "'"
    negative_env = dict(env, ERL_AFLAGS=flags, TB_SMOKE_MARKER=str(marker))
    process = subprocess.Popen([gateway, "start"], cwd=root, env=negative_env,
                               stdout=log, stderr=log, start_new_session=True)
    try:
        deadline = time.monotonic() + 75
        while time.monotonic() < deadline and process.poll() is None:
            check_epmd(root / "tightbeam", process.pid, lsof)
            if marker.is_file():
                try:
                    version = ordinary_http(origin, "/version")
                except OSError:
                    pass
                else:
                    if version.get("version") == expected:
                        try:
                            listeners(process.pid, port, lsof)
                        except SmokeError as error:
                            if str(error) == "test gateway owns an extra TCP listener":
                                return
                            raise
                        raise SmokeError("unsafe packaged startup was accepted")
            time.sleep(0.25)
        raise SmokeError("unsafe packaged startup did not reach the passive control")
    finally:
        kill_group(process)


def ordinary_http(origin, path, headers=None, body=None):
    headers = dict(headers or {})
    if body is not None:
        headers["Content-Type"] = "application/json"
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(origin + path, data=data, headers=headers)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=3) as response:
        if response.status != 200:
            raise SmokeError("ordinary HTTP request did not return HTTP 200")
        return json.load(response)


def inventory_control(root):
    archive = root / "forbidden-member.tgz"
    with tarfile.open(archive, "w:gz") as target:
        target.addfile(tarfile.TarInfo("tightbeam/release/releases/COOKIE"))
    result = observe([sys.executable, str(Path(__file__).with_name("extract-payload.py")),
                      "--inventory-only", str(archive)])
    if result.returncode != 1 or result.stderr.strip() != (
        "payload archive refused: forbidden distribution credential member"
    ):
        raise SmokeError("forbidden archive member control did not produce inventory refusal")


def prepare_provider(root, fixture):
    (root / "packaged-smoke-only").touch()
    provider = root / "base/adapters/node_modules"
    adapter = provider / "@agentclientprotocol/claude-agent-acp"
    home = root / "base/homes/packaged-smoke/claude"
    for path in (adapter / "dist", provider / ".bin", home / ".tightbeam"):
        path.mkdir(parents=True, exist_ok=True)
    (adapter / "package.json").write_text(
        '{"name":"@agentclientprotocol/claude-agent-acp","version":"0.81.0"}'
    )
    (adapter / "dist/acp-agent.js").write_text(
        'content: { type: "text", text: lastRefusalExplanation },\n'
        'const findUnsettledTurn = (uuid) => (session.turnQueue ?? []).find((t) => '
        't.promptUuid === uuid && !t.settled);\n'
        'const isAutonomousResult = message.origin != null && '
        'AUTONOMOUS_RESULT_ORIGINS.has(message.origin.kind);\n'
        '// Turn-over is when a title may have landed or become\n'
    )
    # Executable selection resolves the shim and checks its enclosing package.
    executable = adapter / "dist/fixture-acp.js"
    shutil.copyfile(fixture / "fixture-acp.js", executable)
    executable.chmod(0o700)
    (provider / ".bin/claude-agent-acp").symlink_to(executable)


def onboard_provider(root, fixture, origin, headers):
    # The gateway installs its real CLI at boot. Substitute only the scratch
    # projection before committing the generated credential.
    cli = root / "base/bin/tightbeam"
    temporary = cli.with_suffix(".fixture")
    shutil.copyfile(fixture / "catalog-probe-fixture.sh", temporary)
    temporary.chmod(0o700)
    temporary.replace(cli)

    params = {"provider": "anthropic", "kind": "subscription", "machine": "packaged-smoke"}

    def onboard(phase, **extra):
        try:
            response = ordinary_http(origin, "/agent/dispatch", headers, {
                "verb": "onboard", "asProcess": "packaged-smoke",
                "params": dict(params, phase=phase, **extra),
            })
        except HTTPError as error:
            raise SmokeError(f"generated credential onboarding {phase} refused (HTTP {error.code})") from error
        result = response.get("result") if isinstance(response, dict) else None
        if not isinstance(result, dict):
            raise SmokeError(f"generated credential onboarding {phase} did not return a result")
        return result

    lease = onboard("begin")
    lease_id, raw_path = lease.get("leaseId"), lease.get("stagingPath")
    if (lease.get("status") != "ready" or not isinstance(lease_id, str) or not lease_id
            or not isinstance(raw_path, str)):
        raise SmokeError("generated credential onboarding did not open a lease")
    staging = Path(raw_path)
    if (staging.parent != root / "tmp" or not staging.name.startswith("tightbeam-anthropic-onboard-")
            or staging.resolve(strict=True) != staging or not staging.is_dir()):
        raise SmokeError("generated credential staging is outside the private smoke directory")

    credential = staging / ".credentials.json"
    fd = os.open(credential, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump({"claudeAiOauth": {
                "accessToken": "generated-only", "refreshToken": "generated-only",
                "expiresAt": 4102444800000, "scopes": [],
            }}, stream)
        if onboard("finish", leaseId=lease_id).get("status") != "onboarded":
            raise SmokeError("generated credential onboarding did not commit")
    finally:
        credential.unlink(missing_ok=True)


@contextmanager
def start_gateway(gateway, root, env, port, lsof, log, expected):
    process = subprocess.Popen([gateway, "start"], cwd=root, env=env, stdout=log, stderr=log,
                               start_new_session=True)
    origin = f"http://{LOOPBACK}:{port}"
    try:
        deadline = time.monotonic() + 75
        while time.monotonic() < deadline and process.poll() is None:
            check_epmd(root / "tightbeam", process.pid, lsof)
            if listeners(process.pid, port, lsof):
                try:
                    version = ordinary_http(origin, "/version")
                except OSError:
                    pass
                else:
                    break
            time.sleep(0.25)
        else:
            raise SmokeError("test gateway did not become ready")
        if version.get("version") != expected:
            raise SmokeError("test gateway version mismatch")
        pid = subprocess.check_output([gateway, "pid"], cwd=root, env=env,
                                      text=True, timeout=10).strip()
        if pid != str(process.pid):
            raise SmokeError("packaged gateway did not report the observed PID")
        yield origin
        if not listeners(process.pid, port, lsof):
            raise SmokeError("test gateway lost its HTTP listener")
        check_epmd(root / "tightbeam", process.pid, lsof)
        subprocess.run([gateway, "stop"], cwd=root, env=env, stdout=log, stderr=log,
                       timeout=10, check=True)
        if process.wait(timeout=30) != 0:
            raise SmokeError("test gateway did not shut down gracefully")
        check_epmd(root / "tightbeam", process.pid, lsof)
    finally:
        kill_group(process)


def packaged_chat(gateway, root, env, port, lsof, log, expected, org_token):
    fixture = Path(__file__).parent.resolve() / "smoke"
    env = dict(env, TB_PACKAGED_SMOKE_ROOT=str(root), TB_PACKAGED_SMOKE_SEED=str(fixture / "seed-chat.exs"))
    prepare_provider(root, fixture)
    # Local eval seeds only the test session. Every Chat request and readback
    # below is against a separately started, normal packaged gateway.
    seed = """
      false = Node.alive?()
      {:ok, _} = Application.ensure_all_started(:tightbeam)
      Code.require_file(System.fetch_env!("TB_PACKAGED_SMOKE_SEED"))
      :ok = Application.stop(:tightbeam)
    """
    subprocess.run([gateway, "eval", seed], cwd=root, env=env, stdout=log, stderr=log,
                   timeout=75, check=True)
    tokenfile = root / "generated-session-token"
    token = tokenfile.read_text()
    tokenfile.unlink()
    chat_headers = {"Authorization": "Bearer " + token, "X-Tightbeam-CLI-Version": expected}
    org_headers = dict(chat_headers, Authorization="Bearer " + org_token)
    path = "/api/sessions/" + quote("agent:packaged-smoke", safe="")
    db = root / "base/state.db"

    def durable_delivery(label):
        with closing(sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=3)) as connection:
            return connection.execute("""
                SELECT u.id, a.id, t.seq, t.status, u.content, a.content
                  FROM messages u JOIN turns t ON t.messageId = u.id
                  JOIN messages a ON a.replyToMessageId = u.id AND a.role = 'assistant'
                 WHERE u.sessionKey = ? AND u.clientMessageId = ? AND u.role = 'user'
            """, ("agent:packaged-smoke", "c_packaged_smoke_" + label.lower())).fetchone()

    def verify(origin, label, row):
        if row is None or row[3:] != (
            "delivered", f"Generated stock Chat request {label}", f"Generated stand-in response {label}"
        ):
            raise SmokeError("generated Chat was not durably delivered")
        for message_id, content in zip(row[:2], row[4:]):
            message = ordinary_http(origin, path + "/messages/" + quote(message_id, safe=""), chat_headers)
            if content not in json.dumps(message, ensure_ascii=False):
                raise SmokeError("ordinary Chat message readback differs from durable record")
        turn = ordinary_http(origin, f"/api/turns/{row[2]}", chat_headers)
        if "delivered" not in json.dumps(turn):
            raise SmokeError("ordinary Chat turn status was not delivered")

    saved = None
    for label in ("Alpha", "Bravo"):
        with start_gateway(gateway, root, env, port, lsof, log, expected) as origin:
            if saved is not None:
                previous = durable_delivery("Alpha")
                if previous != saved:
                    raise SmokeError("Chat receipt changed on packaged restart")
                verify(origin, "Alpha", previous)
            catalog = root / "fixture-catalog.log"
            catalog.unlink(missing_ok=True)
            home = root / "base/homes/packaged-smoke/claude"
            try:
                onboard_provider(root, fixture, origin, org_headers)
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    ordinary_http(origin, "/api/sessions?asUser=packaged-smoke", org_headers)
                    if catalog.is_file():
                        break
                    time.sleep(0.25)
                else:
                    raise SmokeError("packaged startup did not derive the generated catalog")
                dispatch = ordinary_http(origin, "/agent/dispatch", org_headers, {
                    "verb": "post", "asUser": "packaged-smoke", "sessionKey": "agent:packaged-smoke",
                    "params": {"content": f"Generated stock Chat request {label}",
                               "clientMessageId": "c_packaged_smoke_" + label.lower(),
                               "deviceId": "packaged-smoke-synthetic"},
                })
                if not isinstance(dispatch, dict) or dispatch.get("error"):
                    raise SmokeError("authenticated Chat submit did not succeed")
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    row = durable_delivery(label)
                    if row and row[3] == "delivered":
                        break
                    time.sleep(0.25)
                else:
                    raise SmokeError("packaged startup did not return a durable Chat answer")
                verify(origin, label, row)
                saved = row
            finally:
                for generated_input in (home / ".tightbeam/credential.json", home / ".credentials.json"):
                    generated_input.unlink(missing_ok=True)
    if (root / "fixture-turns.log").read_text().splitlines() != ["Alpha", "Bravo"]:
        raise SmokeError("generated provider did not receive exactly the two Chat turns")


def smoke(archive, lsof):
    with tempfile.TemporaryDirectory(prefix="tightbeam-packaged-smoke-") as scratch:
        root = Path(scratch).resolve()
        subprocess.run([sys.executable, str(Path(__file__).with_name("extract-payload.py")),
                        archive, str(root)], check=True, timeout=60)
        inventory_control(root)
        package = root / "tightbeam"
        for name in ("home", "base", "tmp", "tools"):
            (root / name).mkdir(mode=0o700)
        epmd_attribution_control(root, lsof)
        discovery = root / "tools/claude"
        discovery.write_text(
            '#!/bin/sh\ncase "${1-}" in --version) echo "2.1.280 (generated discovery)";; *) exit 64;; esac\n'
        )
        discovery.chmod(0o700)
        with socket.socket() as reservation:
            reservation.bind((LOOPBACK, 0))
            port = reservation.getsockname()[1]
        token = "tbc_" + secrets.token_urlsafe(24)
        descriptor = root / "base/gateway.json"
        descriptor.touch(mode=0o600, exist_ok=False)
        descriptor.write_text(json.dumps({"cliToken": token}))
        env = {"PATH": str(root / "tools") + os.pathsep + os.environ["PATH"],
               "HOME": str(root / "home"), "TMPDIR": str(root / "tmp"),
               "LC_ALL": "C", "npm_config_offline": "true", "TIGHTBEAM_DEFAULT_HARNESS": "claude",
               "TIGHTBEAM_BASE_DIR": str(root / "base"), "TIGHTBEAM_PORT": str(port),
               "ERL_FLAGS": "+S 4:4 +SDcpu 2 +SDio 2",
               "TIGHTBEAM_LOCAL_HOST_NAME": "packaged-smoke"}
        gateway = package / "bin/tightbeam-gateway"
        origin = f"http://{LOOPBACK}:{port}"
        expected = json.loads((package / "package.json").read_text())["version"]
        with (root / "gateway.log").open("wb") as log:
            with start_gateway(gateway, root, env, port, lsof, log, expected) as listening:
                cli = package / "bin/tightbeam"
                for args in (("add-user", "packaged-smoke"), ("list", "--as-user", "packaged-smoke")):
                    subprocess.run([cli, *args], cwd=root, env=env, stdout=log, stderr=log,
                                   timeout=15, check=True)
                result = ordinary_http(listening, "/api/sessions?asUser=packaged-smoke", {
                    "Authorization": "Bearer " + token, "X-Tightbeam-CLI-Version": expected
                })
                if not isinstance(result, (dict, list)):
                    raise SmokeError("authenticated Chat session read was not JSON")
            packaged_chat(gateway, root, env, port, lsof, log, expected, token)
            packaged_listener_control(gateway, root, env, origin, port, lsof, log, expected)


def main():
    if len(sys.argv) != 2:
        raise SmokeError("usage: gateway-smoke.py <archive>")
    lsof = shutil.which("lsof")
    if sys.platform != "linux" and not lsof:
        raise SmokeError("passive package smoke needs lsof")
    started = time.monotonic()
    with open(sys.argv[1], "rb") as archive:
        digest = hashlib.file_digest(archive, "sha256").hexdigest()
    smoke(sys.argv[1], lsof)
    with open(sys.argv[1], "rb") as archive:
        if hashlib.file_digest(archive, "sha256").hexdigest() != digest:
            raise SmokeError("archive changed during package smoke")
    print(f"package smoke: OK sha256={digest} elapsed_s={time.monotonic() - started:.2f} "
          "archive inventory/control, packaged start/CLI/Chat/durable restart/stop, packaged listener control")


if __name__ == "__main__":
    try:
        main()
    except SmokeError as error:
        sys.exit("package smoke: " + str(error))
    except (OSError, ValueError, subprocess.SubprocessError):
        sys.exit("package smoke: test command or ordinary HTTP request failed")
