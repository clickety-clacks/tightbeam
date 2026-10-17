#!/usr/bin/env python3
"""Exact-package soak, run INSIDE an operator-provided isolated Linux enclosure.

No defaults for package, data, auth, endpoint, workload or host admission. This
entry point does not copy a DB, provision an adapter, establish containment or
turn a successful source-test run into release acceptance. See --help.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid

MEASURE_SECONDS = 12 * 3600
WINDOW_SECONDS = 300
COVERAGE = {"ordinary_record", "due_deadline", "busy_free", "holder_activity",
            "parent_escalation", "side_task_isolation"}
# A deliberately small public operation surface, not arbitrary programs/SQL.
READ_VERBS = {"work-item-get", "work-item-trace", "assignment-get", "attests", "transcript", "inspect"}
VERBS = {"work-item-create", "work-item-get", "work-item-update", "work-item-close",
         "work-item-trace", "wake", "withdraw", "assign", "assignment-get",
         "attest", "attests", "transcript", "inspect"}


class Gap(Exception):
    """Missing/unattributed evidence: never a product failure or a pass."""


class Breach(Exception):
    """An observed frozen business assertion failed."""


def require(ok, reason):
    if not ok:
        raise Gap(reason)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def regular(path):
    p = Path(path)
    require(p.is_absolute() and str(p) == str(p.resolve()), "noncanonical path")
    require(stat.S_ISREG(p.lstat().st_mode), "nonregular evidence/input")
    return p


def pinned(spec):
    p = regular(spec["path"])
    require(digest(p) == spec["sha256"], "pinned file digest mismatch")
    return p


def document(spec):
    return json.loads(pinned(spec).read_text())


def under(path, root):
    p = Path(path)
    require(p.is_absolute() and p == p.resolve() and p.is_relative_to(root) and p != root,
            "scratch path escaped its explicit root")
    return p


def pointer(value, path):
    if path == "":
        return value
    require(path.startswith("/"), "expected RFC6901 JSON pointer")
    for part in path[1:].split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        value = value[int(part)] if isinstance(value, list) else value[part]
    return value


def substitute(value, bindings):
    # Exact typed substitution avoids accidental quoting/ID coercion. No eval.
    if isinstance(value, dict):
        if set(value) == {"$ref"}:
            return bindings[value["$ref"]]
        if set(value) == {"$after_ms"}:
            require(isinstance(value["$after_ms"], int) and value["$after_ms"] >= 0,
                    "invalid relative due time")
            return bindings["now_ms"] + value["$after_ms"]
        return {k: substitute(v, bindings) for k, v in value.items()}
    if isinstance(value, list):
        return [substitute(v, bindings) for v in value]
    return value


def quantile(samples, q):
    ordered = sorted(samples)
    return ordered[math.ceil(q * len(ordered)) - 1]


class Drift:
    """Frozen baseline vs comparable five-minute windows; signals need attribution."""
    def __init__(self, baseline):
        self.baseline = baseline
        self.runs = {}
        self.small_runs = {}
        self.sparse_runs = {}
        self.comparisons = {}
        self.throughput_run = 0
        self.last_backlog = 0

    def window(self, samples, offered, completed, eligible_backlog):
        signals = []
        for name, base in self.baseline.items():
            vals = samples.get(name, [])
            self.comparisons[name] = {"baseline_count": len(base), "window_count": len(vals),
                                      "baseline_max": max(base) if base else None,
                                      "window_max": max(vals) if vals else None}
            # Sparse classes use maxima/counts, never an invented tail quantile.
            sparse = bool(base and vals) and min(len(base), len(vals)) < 1000
            worse_max = sparse and max(vals) > max(base)
            self.sparse_runs[name] = self.sparse_runs.get(name, 0) + 1 if worse_max else 0
            if self.sparse_runs[name] >= 3:
                signals.append(f"sparse_latency_requires_assessment:{name}")
            if not base or not vals:
                signals.append(f"missing_comparable_latency_evidence:{name}")
            for label, q, minimum in (("p95", .95, 100), ("p99", .99, 1000)):
                key = (name, label)
                # Sparse/missing windows break a consecutive run; never fabricate a quantile.
                sufficient = len(vals) >= minimum and len(base) >= minimum
                worse = sufficient and quantile(vals, q) > quantile(base, q) * 1.2 and (
                    quantile(vals, q) - quantile(base, q) > .050)
                self.runs[key] = self.runs.get(key, 0) + 1 if worse else 0
                if self.runs[key] >= 3:
                    signals.append(f"sustained_latency:{name}:{label}")
                # Smaller unexplained increases are preserved for independent assessment.
                smaller = sufficient and quantile(vals, q) > quantile(base, q) and not worse
                self.small_runs[key] = self.small_runs.get(key, 0) + 1 if smaller else 0
                if self.small_runs[key] >= 3:
                    signals.append(f"smaller_drift_requires_assessment:{name}:{label}")
        accumulating = eligible_backlog > self.last_backlog
        low = offered > 0 and completed / offered < .95 and accumulating
        self.throughput_run = self.throughput_run + 1 if low else 0
        if self.throughput_run >= 3:
            signals.append("sustained_throughput_backlog")
        self.last_backlog = eligible_backlog
        return signals


def collect_future_errors(futures):
    errors = []
    for future in futures:
        try:
            future.result()
        except concurrent.futures.CancelledError:
            continue  # It never ran: no fabricated terminal operation.
        except Exception as error:
            errors.append(error)
    return errors


def preferred_error(errors):
    return next((error for error in errors if isinstance(error, Breach)), errors[0])


def stall_signals(now, last_completion, states):
    runnable = [s for s in states if s["eligible_at"] is not None and
                max(s["eligible_at"], s["waiting_until"]) <= now]
    signals = []
    if runnable:
        runnable_since = min(max(s["eligible_at"], s["waiting_until"]) for s in runnable)
        if now - max(last_completion, runnable_since) > 30:
            signals.append("global30s_completion_stall_detector")
        if any(now > max(s["progress_deadline"], s["waiting_until"]) + 60 for s in runnable):
            signals.append("eligible60s_progress_stall_detector")
    return signals


def payload(package):
    root = Path(package["root"])
    require(root.is_absolute() and root == root.resolve(), "noncanonical package root")
    pinned(package["archive"])
    mp = pinned(package["manifest"])
    require(mp.is_relative_to(root), "manifest outside package")
    m = json.loads(mp.read_text())
    entries = []
    for p in sorted(root.rglob("*")):
        require(not p.is_symlink(), "symlink in package")
        if p.is_file() and p != mp:
            entries.append({"path": p.relative_to(root).as_posix(), "sha256": digest(p)})
        else:
            require(p == mp or p.is_dir(), "special file in package")
    encoded = "".join(f"{len(e['path'].encode())}:{e['path']}:{e['sha256']}\n" for e in entries)
    identity = hashlib.sha256(("tightbeam-payload/v1\n" + encoded).encode()).hexdigest()
    require(m == {"format": "tightbeam-payload/v1", "files": entries, "buildIdentity": identity},
            "complete payload manifest mismatch")
    require(identity == package["build_identity"], "wrong payload identity")
    for leaf in ("bin/tightbeam", "bin/tightbeam-gateway"):
        require(os.access(regular(root / leaf), os.X_OK), "package entry point not executable")
    # Provenance bytes are pinned; the source binding comes from the release owner's
    # accepted package receipt, not an assumption about undocumented provenance fields.
    accepted = document(package["accepted_provenance"])
    require(len(package["source_sha"]) == 40 and len(package["version_sha"]) >= 7 and
            package["source_sha"].startswith(package["version_sha"]), "version stamp not bound to full source")
    require(accepted["acceptance_reference"] and
            accepted["source_sha"] == package["source_sha"] and
            accepted["archive_sha256"] == package["archive"]["sha256"] and
            accepted["payload_manifest_sha256"] == package["manifest"]["sha256"] and
            accepted["build_identity"] == identity, "accepted provenance binds another package/source")
    return root


def finite_positive(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0


def validate_profile(profile):
    require(profile["representativeness_evidence"], "no workload representativeness evidence")
    require(finite_positive(profile["baseline_seconds"]) and profile["baseline_seconds"] >= WINDOW_SECONDS,
            "baseline shorter than a comparison window or unbounded")
    require(profile["measure_seconds"] == MEASURE_SECONDS, "twelve measured hours required")
    require(isinstance(profile["concurrency"], int) and profile["concurrency"] > 0, "no bounded workload concurrency")
    cases = profile["cases"]
    require(cases and len({c['name'] for c in cases}) == len(cases), "empty/duplicate workload cases")
    for c in cases:
        require(finite_positive(c["period_seconds"]) and finite_positive(c["operation_budget_seconds"]),
                "invalid or unbounded offered cadence/operation budget")
        require(isinstance(c["eligible_after_seconds"], (int, float)) and
                math.isfinite(c["eligible_after_seconds"]) and c["eligible_after_seconds"] >= 0 and c["steps"],
                "missing or unbounded eligibility/steps")
        require(finite_positive(c.get("progress_budget_seconds", c["operation_budget_seconds"])),
                "invalid required-progress budget")
        require(any(step.get("marks_eligible") for step in c["steps"]),
                "no observed public readiness assertion for workload case")
        for step in c["steps"]:
            require(step["expect"], "operation without business assertion")
            if step["method"] == "POST":
                require(step["path"] == "/agent/dispatch" and step["body"]["verb"] in VERBS,
                        "unsupported workload mutation surface")
                require(not step.get("poll_seconds") or step["body"]["verb"] in READ_VERBS,
                        "never poll/retry a write")
            else:
                require(step["method"] == "GET" and step["path"].startswith("/api/"),
                        "unsupported workload read surface")
            require(finite_positive(step["timeout_seconds"]), "unbounded request")
            require(not step.get("poll_seconds") or finite_positive(step["poll_seconds"]), "unbounded polling interval")
            wait = step.get("legitimate_wait_seconds", 0)
            require(isinstance(wait, (int, float)) and math.isfinite(wait) and wait >= 0,
                    "invalid or unbounded declared legitimate wait")
            require(not wait or step.get("wait_reason"), "legitimate wait needs a frozen source-backed reason")
    return COVERAGE - {tag for c in cases for tag in c["coverage"]}


class Run:
    def __init__(self, spec, out):
        self.spec, self.out = spec, out
        self.lock = threading.Lock()
        self.gateway = None
        self.stop = threading.Event()
        self.events = (out / "operations.jsonl").open("x")
        self.signals = []
        self.samples = []
        self.offered = 0
        self.completed = 0
        self.missed = 0
        self.active = {}
        self.last_completion = time.monotonic()
        self.counter = 0
        self.local = threading.local()
        self.worker_failures = []
        self.worker_counts = {"PASS": 0, "FAIL": 0, "INCONCLUSIVE": 0}
        self.future_errors = []
        self.connection = spec["connection"]
        self.token = ""

    def event(self, kind, **fields):
        with self.lock:
            self.events.write(json.dumps({"kind": kind, "utc": time.time(), **fields}) + "\n")
            self.events.flush()

    def request(self, method, path, body, timeout):
        require(path.startswith("/") and not path.startswith("//"), "invalid loopback path")
        conn = http.client.HTTPConnection("127.0.0.1", self.connection["port"], timeout=timeout)
        headers = {"Content-Type": "application/json"}
        if path != "/version":
            headers["Authorization"] = "Bearer " + self.token
        started = time.monotonic()
        encoded = None if body is None else json.dumps(body).encode()
        with self.lock:
            self.counter += 1
            request_id = self.counter
        self.local.request_id = request_id
        request_leaf = f"request-{request_id:09d}.json"
        (self.out / request_leaf).write_bytes(encoded or b"null")
        self.event("request_started", request_id=request_id, method=method, path=path,
                   raw=request_leaf, sha256=digest(self.out / request_leaf))
        timer = None
        try:
            conn.connect()
            transport = conn.sock
            def expire():
                try:
                    transport.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            remaining = timeout - (time.monotonic() - started)
            require(remaining > 0, "request budget exhausted during connection")
            timer = threading.Timer(remaining, expire)
            timer.daemon = True
            timer.start()
            conn.request(method, path, encoded, headers)
            response = conn.getresponse()
            raw = response.read(self.spec["max_response_bytes"] + 1)
            require(len(raw) <= self.spec["max_response_bytes"], "response evidence exceeds private bound")
            # Raw body stays only in the private run directory, never printed or summarized.
            leaf = f"response-{request_id:09d}.json"
            (self.out / leaf).write_bytes(raw)
            self.event("response", request_id=request_id, method=method, path=path, status=response.status,
                       seconds=time.monotonic() - started, raw=leaf,
                       sha256=hashlib.sha256(raw).hexdigest())
            return response.status, json.loads(raw)
        except (OSError, http.client.HTTPException) as error:
            self.event("request_transport_error", request_id=request_id, error=type(error).__name__,
                       effect_unknown=method == "POST" and (body or {}).get("verb") not in READ_VERBS,
                       retried=False)
            raise
        finally:
            if timer:
                timer.cancel()
                timer.join()
            conn.close()

    def setup(self):
        s = self.spec
        require(sys.platform.startswith("linux") and os.getuid() != 0,
                "this containment entry point needs an unprivileged Linux executor")
        enclosure = document(s["enclosure"])
        require(enclosure["physical_host"], "physical host absent from private admission evidence")
        require(enclosure["uid"] == os.getuid(), "wrong enclosed UID")
        require(enclosure["network_namespace"] == os.readlink("/proc/self/ns/net") and
                enclosure["network_namespace"] != enclosure["outer_network_namespace"],
                "not in admitted private network namespace")
        require(enclosure["containment_evidence"], "missing containment receipt")
        require(enclosure["scratch"] == s["scratch"] and enclosure["package_root"] == s["package"]["root"],
                "enclosure receipt names another scratch/package")
        slot = document(s["host_slot"])
        require(slot["physical_host"] == enclosure["physical_host"],
                "slot and containment name different physical hosts")
        needed = s["profile"]["baseline_seconds"] + MEASURE_SECONDS + s["setup_restart_budget_seconds"]
        require(slot["start_utc"] <= time.time() and time.time() + needed <= slot["end_utc"],
                "host slot cannot cover setup/baseline/full measurement/restart")
        self.slot_end = slot["end_utc"]
        self.root = Path(s["scratch"])
        require(self.root.is_absolute() and self.root == self.root.resolve() and
                self.root.stat().st_uid == os.getuid() and stat.S_IMODE(self.root.stat().st_mode) == 0o700,
                "scratch not canonical owned0700")
        self.base = under(s["base"], self.root)
        self.home = under(s["home"], self.root)
        require(self.base.is_dir() and not self.home.exists(), "base absent or scratch HOME reused")
        self.home.mkdir(mode=0o700)
        self.package_root = payload(s["package"])
        require(not self.package_root.is_relative_to(self.base), "package inside writable DB base")
        self.input = document(s["authorized_input"])
        require(self.input["authorization_evidence"] and self.input["migration_lineage_evidence"],
                "missing approved source/migration lineage")
        self.immutable = pinned(self.input["immutable_db"])
        require(os.statvfs(self.immutable).f_flag & os.ST_RDONLY,
                "immutable DB is not on the admitted read-only mount")
        require(os.statvfs(self.package_root).f_flag & os.ST_RDONLY,
                "package is not on the admitted read-only mount")
        derivative = regular(self.base / "state.db")
        require(derivative.stat().st_nlink == 1 and
                (derivative.stat().st_dev, derivative.stat().st_ino) !=
                (self.immutable.stat().st_dev, self.immutable.stat().st_ino), "DB is not a separate physical derivative")
        require(digest(derivative) == self.input["immutable_db"]["sha256"], "derivative differs before first boot")
        for leaf in ("state.db-wal", "state.db-shm", "gateway.json"):
            require(not (self.base / leaf).exists(), "derivative has prior runtime state")
        require(self.input["derivative_base"] == str(self.base), "copy custody names another base")
        require(self.connection["port"] > 1024 and self.connection["port"] < 65536, "invalid private port")
        missing = validate_profile(s["profile"])
        require(not missing, "incomplete representative workload: " + ",".join(sorted(missing)))
        # Local test auth is staged by the admitted normal fixture route. Never read a
        # source credential DB, copy a home or default to this process's credentials.
        token_path = regular(under(self.connection["local_token_file"], self.root))
        require(stat.S_IMODE(token_path.stat().st_mode) == 0o600, "local token file not0600")
        self.token = token_path.read_text().strip()
        require(self.token and "\n" not in self.token, "missing local fixture token")
        support = document(s["workload_support"])
        require(support["build_identity"] == s["package"]["build_identity"],
                "workload support is for another package")
        require(not support.get("required_gaps"), "workload support has unresolved required boundaries")
        if support.get("adapter"):
            adapter = pinned(support["adapter"])
            require(adapter.is_relative_to(self.root) or adapter.is_relative_to(self.package_root),
                    "adapter outside admitted scratch/package")
        require(s["min_free_bytes"] > 0 and s["max_rss_bytes"] > 0,
                "host resource limits missing")
        require(s["startup_timeout_seconds"] > 0 and s["setup_restart_budget_seconds"] > 0,
                "setup/restart bounds missing")
        self.event("qualified", build_identity=s["package"]["build_identity"],
                   source_sha=s["package"]["source_sha"], input_sha=self.input["immutable_db"]["sha256"],
                   python=sys.version, driver_sha256=digest(Path(__file__).resolve()))

    def start(self, restart=False):
        s = self.spec
        env = {"PATH": s["runtime_path"], "HOME": str(self.home), "LANG": "C.UTF-8",
               "TIGHTBEAM_BASE_DIR": str(self.base), "TIGHTBEAM_PORT": str(self.connection["port"])}
        if self.input.get("logical_host"):
            env["TIGHTBEAM_LOCAL_HOST_NAME"] = self.input["logical_host"]
        if not restart and s.get("transition"):
            t = s["transition"]
            require(t["base"] == str(self.base) and t["target"] == s["package"]["build_identity"],
                    "transition does not name exact derivative/target")
            env["TIGHTBEAM_LIVE_BASE_TRANSITION"] = json.dumps(t)
        log = (self.out / ("restart.log" if restart else "gateway.log")).open("xb")
        try:
            self.gateway = subprocess.Popen([str(self.package_root / "bin/tightbeam-gateway"), "start"],
                                            cwd=self.base, env=env, stdout=log, stderr=log,
                                            start_new_session=True)
        finally:
            log.close()
        deadline = time.monotonic() + s["startup_timeout_seconds"]
        while time.monotonic() < deadline:
            require(self.gateway.poll() is None, "packaged gateway exited during startup; see private log")
            try:
                status, version = self.request("GET", "/version", None, 2)
            except (OSError, http.client.HTTPException):
                self.stop.wait(.25)
                continue
            require(status == 200 and version["sha"] == s["package"]["version_sha"] and
                    version["version"] == s["package"]["version"], "running package/version mismatch")
            marker = json.loads((self.base / "build-owner.json").read_text())
            require(marker["buildIdentity"] == s["package"]["build_identity"], "running owner marker mismatch")
            self.event("ready", restart=restart, pid=self.gateway.pid, version=version)
            return
        raise Gap("package startup deadline expired; cause not attributed")

    def shutdown(self):
        if self.gateway is None:
            return
        # Only this Popen session/process group; never package stop against a guessed PID.
        pid = self.gateway.pid
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.gateway.wait(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(pid, signal.SIGKILL)
            self.gateway.wait(timeout=10)
            self.signals.append("owned_gateway_required_kill")
        try:
            os.killpg(pid, 0)
        except ProcessLookupError:
            self.event("owned_postflight", pid=pid, exit=self.gateway.returncode, group_gone=True)
        else:
            raise Gap("owned process group remains after cleanup")
        self.gateway = None

    def record_worker_outcome(self, key, outcome):
        # Store failures independently of Future collection order. Keep only failures
        # in memory; the private event stream preserves every terminal operation.
        with self.lock:
            state = dict(self.active.get(key, {}))
            self.worker_counts[outcome["status"]] += 1
            if outcome["status"] != "PASS":
                self.worker_failures.append(outcome)
        self.event("transaction_outcome", **outcome, eligibility=state)
        if outcome["status"] != "PASS":
            self.stop.set()
            with self.lock:
                os.fsync(self.events.fileno())
        # Eligibility remains observable until its terminal outcome is recorded.
        with self.lock:
            self.active.pop(key, None)

    def remember_future_errors(self, futures):
        errors = collect_future_errors(futures)
        self.future_errors.extend(errors)
        for error in errors:
            self.event("future_error", error_type=type(error).__name__, reason=str(error),
                       status="FAIL" if isinstance(error, Breach) else "INCONCLUSIVE")
        return errors

    def transaction(self, case, key, phase):
        start = time.monotonic()
        bindings = {**self.spec["profile"].get("bindings", {}),
                    "run_id": self.spec["run_id"], "operation_id": uuid.uuid4().hex,
                    "now_ms": int(time.time() * 1000)}
        self.local.request_id = None
        outcome = {"case": case["name"], "phase": phase, "operation_id": bindings["operation_id"],
                   "step": None, "status": "INCONCLUSIVE", "reason": "worker_interrupted"}
        try:
            for step in case["steps"]:
                outcome["step"] = step["name"]
                self.local.request_id = None
                if self.stop.is_set():
                    raise Gap("workload stopped before assertion chain completed")
                item = substitute(step, bindings)
                end = start + case["operation_budget_seconds"]
                require(time.monotonic() < end, "earlier_deadline_investigation:operation_budget")
                while True:
                    timeout = min(item["timeout_seconds"], max(.001, end - time.monotonic()))
                    status, value = self.request(item["method"], item["path"], item.get("body"), timeout)
                    matched = status == item.get("status", 200) and all(
                        pointer(value, p) == expected for p, expected in item["expect"].items())
                    if matched:
                        break
                    if not item.get("poll_seconds"):
                        raise Breach(f"business_assertion:{case['name']}:{step['name']}")
                    if time.monotonic() >= end:
                        raise Gap("earlier_deadline_investigation:public_progress_poll")
                    if self.stop.is_set():
                        raise Gap("peer_stop_before_read_poll; latest response preserved")
                    self.stop.wait(min(item["poll_seconds"], max(0, end - time.monotonic())))
                observed = time.monotonic()
                with self.lock:
                    state = self.active[key]
                    if item.get("marks_eligible"):
                        state["eligible_at"] = observed + case["eligible_after_seconds"]
                        state["waiting_until"] = 0  # New observed readiness ends an earlier wait.
                    state["progress_deadline"] = observed + case.get(
                        "progress_budget_seconds", case["operation_budget_seconds"])
                    if item.get("legitimate_wait_seconds"):
                        state["waiting_until"] = observed + item["legitimate_wait_seconds"]
                for name, p in item.get("capture", {}).items():
                    bindings[name] = pointer(value, p)
            elapsed = time.monotonic() - start
            require(elapsed <= case["operation_budget_seconds"],
                    "earlier_deadline_investigation:transaction_completion")
            with self.lock:
                self.samples.append((phase, case["name"], elapsed))
                self.completed += 1
                self.last_completion = time.monotonic()
            outcome.update(status="PASS", reason="assertion_chain_complete", seconds=elapsed)
            self.event("transaction_complete", case=case["name"], phase=phase, seconds=elapsed)
        except Breach as error:
            outcome.update(status="FAIL", reason=str(error), error_type=type(error).__name__)
            raise
        except Exception as error:
            outcome.update(status="INCONCLUSIVE", reason=str(error), error_type=type(error).__name__,
                           investigation="earlier_deadline_or_driver_transport; not a60s-overdue observation")
            raise
        finally:
            outcome["request_id"] = self.local.request_id
            self.record_worker_outcome(key, outcome)

    def resources(self):
        # Namespace-local process group accounting, not database reads/history scans.
        rss, ticks = 0, 0
        for p in Path("/proc").iterdir():
            if not p.name.isdigit():
                continue
            try:
                fields = (p / "stat").read_text().rsplit(")", 1)[1].split()
                if int(fields[2]) == self.gateway.pid:
                    ticks += int(fields[11]) + int(fields[12])
                    rss += int(fields[21]) * os.sysconf("SC_PAGE_SIZE")
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                continue
        free = os.statvfs(self.root).f_bavail * os.statvfs(self.root).f_frsize
        wal = self.base / "state.db-wal"
        self.event("resource", cpu_ticks=ticks, clock_ticks=os.sysconf("SC_CLK_TCK"), rss_bytes=rss,
                   free_bytes=free, wal_bytes=wal.stat().st_size if wal.exists() else 0)
        require(free >= self.spec["min_free_bytes"] and rss <= self.spec["max_rss_bytes"],
                "host resource stop guard; attribution required")

    def phase(self, name, seconds, detector=None):
        profile = self.spec["profile"]
        start = time.monotonic()
        next_offer = {c["name"]: start for c in profile["cases"]}
        window = start
        resource_at = start
        baseline = {}
        with self.lock:
            self.samples = []
        all_signals = []
        futures = set()
        prior_offered, prior_completed = self.offered, self.completed
        self.last_completion = start
        self.event("phase_start", phase=name, duration_seconds=seconds)
        def flush_window(eligible):
            nonlocal prior_offered, prior_completed, window
            with self.lock:
                values, self.samples = self.samples, []
            grouped = {}
            for sample_phase, cls, elapsed in values:
                require(sample_phase == name, "mixed comparison phases")
                grouped.setdefault(cls, []).append(elapsed)
                baseline.setdefault(cls, []).append(elapsed)
            summary = {cls: {"count": len(vals), "max": max(vals),
                       **({"p95": quantile(vals, .95)} if len(vals) >= 100 else {}),
                       **({"p99": quantile(vals, .99)} if len(vals) >= 1000 else {})}
                       for cls, vals in grouped.items()}
            if detector:
                all_signals.extend(detector.window(grouped, self.offered - prior_offered,
                                                    self.completed - prior_completed, len(eligible)))
            self.event("window", phase=name, summary=summary, offered=self.offered - prior_offered,
                       completed=self.completed - prior_completed, eligible_backlog=len(eligible),
                       missed_total=self.missed, signals=all_signals,
                       comparison_evidence=detector.comparisons if detector else {})
            if any(flag.startswith("sustained_") for flag in all_signals):
                raise Gap("sustained degradation detector; product/host/driver attribution required")
            prior_offered, prior_completed = self.offered, self.completed
            window += WINDOW_SECONDS

        pool = concurrent.futures.ThreadPoolExecutor(max_workers=profile["concurrency"])
        try:
            while time.monotonic() - start < seconds:
                now = time.monotonic()
                require(time.time() < self.slot_end, "host slot expired")
                require(self.gateway.poll() is None, "unplanned gateway exit")
                done = [f for f in futures if f.done()]
                futures.difference_update(done)
                errors = self.remember_future_errors(done)
                if errors:
                    raise preferred_error(errors)
                for c in profile["cases"]:
                    if now >= next_offer[c["name"]]:
                        due = 1 + int((now - next_offer[c["name"]]) / c["period_seconds"])
                        next_offer[c["name"]] += due * c["period_seconds"]
                        self.offered += due
                        if due > 1:
                            self.missed += due - 1
                        if len(futures) >= profile["concurrency"]:
                            self.missed += 1
                            continue
                        key = uuid.uuid4().hex
                        with self.lock:
                            # Offering a request is not evidence of admitted/eligible work.
                            self.active[key] = {"eligible_at": None, "waiting_until": 0,
                                                "progress_deadline": now + c.get(
                                                    "progress_budget_seconds", c["operation_budget_seconds"])}
                        futures.add(pool.submit(self.transaction, c, key, name))
                with self.lock:
                    states = [dict(state) for state in self.active.values()]
                    last = self.last_completion
                eligible = [state for state in states if state["eligible_at"] is not None and
                            max(state["eligible_at"], state["waiting_until"]) <= now]
                stalls = stall_signals(now, last, states)
                if stalls:
                    self.event("stall_investigation", signals=stalls, active=states)
                    raise Gap(";".join(stalls) + "; product/driver/host attribution required")
                if now >= resource_at:
                    self.resources()
                    resource_at = now + 15
                if now - window >= WINDOW_SECONDS:
                    flush_window(eligible)
                self.stop.wait(.05)
            with self.lock:
                eligible = [dict(state) for state in self.active.values()
                            if state["eligible_at"] is not None and
                            max(state["eligible_at"], state["waiting_until"]) <= time.monotonic()]
            if time.monotonic() - window >= WINDOW_SECONDS:
                flush_window(eligible)
            draining = tuple(futures)
            futures.clear()
            errors = self.remember_future_errors(draining)
            if errors:
                raise preferred_error(errors)  # Drain time never counts toward measurement.
            with self.lock:
                trailing, self.samples = self.samples, []
            for sample_phase, cls, elapsed in trailing:
                require(sample_phase == name, "mixed comparison phases")
                baseline.setdefault(cls, []).append(elapsed)
            self.event("phase_end", phase=name, measured_seconds=seconds,
                       drain_complete_seconds=time.monotonic() - start,
                       trailing_counts={cls: len(vals) for cls, vals in baseline.items()})
        finally:
            self.stop.set()
            pool.shutdown(wait=True, cancel_futures=True)
            self.remember_future_errors(tuple(futures))
            futures.clear()
            self.stop.clear()
        self.signals += all_signals
        return baseline

    def execute(self):
        status, reason = "INCONCLUSIVE", "not run"
        try:
            self.setup()
            self.start()
            baseline = self.phase("baseline", self.spec["profile"]["baseline_seconds"])
            self.event("baseline_frozen", samples=baseline)
            measured = self.phase("measured", MEASURE_SECONDS, Drift(baseline))
            self.shutdown()
            self.start(restart=True)  # Same package/base; no repeated transition override.
            self.shutdown()
            if digest(self.immutable) != self.input["immutable_db"]["sha256"]:
                raise Breach("immutable_input_changed")
            payload(self.spec["package"])
            # Reuse only explicitly accepted, applicable exact-subject evidence. Merely
            # booting twice or seeing a schema stamp does not prove migration-once.
            claims = set()
            for ref in self.spec.get("accepted_semantics_evidence", []):
                ev = document(ref)
                require(ev["build_identity"] == self.spec["package"]["build_identity"] and
                        ev["input_sha256"] == self.input["immutable_db"]["sha256"] and
                        ev["acceptance_reference"] and ev["raw_evidence"],
                        "semantics evidence is unbound/unaccepted")
                claims.update(ev["claims"])
            needed = {"migration_once", "background_serving", "same_build_restart_no_replay"}
            self.signals.extend("missing_semantics_evidence:" + c for c in sorted(needed - claims))
            if self.missed:
                self.signals.append("driver_missed_offers")
            for c in self.spec["profile"]["cases"]:
                if not baseline.get(c["name"]):
                    self.signals.append("missing_baseline:" + c["name"])
                if not measured.get(c["name"]):
                    self.signals.append("missing_measured_class:" + c["name"])
            status = "INCONCLUSIVE" if self.signals else "PASS"
            reason = ";".join(sorted(set(self.signals))) or "frozen workload and supplied exact-subject evidence satisfied"
        except Breach as error:
            status, reason = "FAIL", str(error)
        except (Gap, OSError, ValueError, KeyError, TypeError, http.client.HTTPException) as error:
            reason = f"{type(error).__name__}:{error}"
        finally:
            self.stop.set()
            try:
                self.shutdown()
            except (Gap, OSError, subprocess.SubprocessError) as error:
                reason += f";owned_cleanup:{type(error).__name__}"
                if status != "FAIL":
                    status = "INCONCLUSIVE"
            # A concurrent host/driver Gap or cleanup error cannot erase a business Breach.
            business = [o for o in self.worker_failures if o["status"] == "FAIL"]
            if status == "FAIL" or business or any(isinstance(error, Breach) for error in self.future_errors):
                status = "FAIL"
                reason += ";observed_business_failure_preserved"
            elif self.worker_failures or self.future_errors:
                status = "INCONCLUSIVE"
            self.events.flush()
            os.fsync(self.events.fileno())
            self.events.close()
            result = {"status": status, "reason": reason, "offered": self.offered,
                      "completed": self.completed, "missed_offers": self.missed,
                      "worker_terminal_counts": self.worker_counts,
                      "worker_failures": self.worker_failures,
                      "operations_sha256": digest(self.out / "operations.jsonl"),
                      "subject": {"build_identity": self.spec.get("package", {}).get("build_identity"),
                                  "source_sha": self.spec.get("package", {}).get("source_sha")},
                      "private_log_sha256": {p.name: digest(p) for p in self.out.glob("*.log")},
                      "limits": ["no provider proof", "independent exact-subject release assessment required"]}
            (self.out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True, help="new private directory in admitted scratch")
    args = parser.parse_args()
    os.umask(0o077)
    spec = document({"path": str(args.manifest), "sha256": args.sha256})
    out = under(args.evidence_dir, Path(spec["scratch"]))
    out.mkdir(mode=0o700)  # Never reuse/overwrite a spent result.
    (out / "run-manifest.json").write_bytes(args.manifest.read_bytes())
    def interrupted(_signum, _frame):
        raise Gap("operator interruption; owned cleanup required")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    result = Run(spec, out).execute()
    # Console is deliberately non-secret. Raw responses/logs remain private.
    print(json.dumps({"status": result["status"], "evidence_dir": str(out)}))
    return {"PASS": 0, "FAIL": 1, "INCONCLUSIVE": 2}[result["status"]]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Gap, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"status": "INCONCLUSIVE", "reason": type(error).__name__}), file=sys.stderr)
        sys.exit(2)
