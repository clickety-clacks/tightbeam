"""Unit evidence for the soak driver, invoked by the canonical Mix test wrapper.

These exercise detector/identity/evidence boundaries, not product performance,
provider behavior or an actual release soak. No gateway or database is launched.
"""
import importlib.util
import json
from pathlib import Path
import tempfile
import http.server
import threading
import time
import unittest

SPEC = importlib.util.spec_from_file_location("package_soak", Path(__file__).parents[1] / "package_soak.py")
soak = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(soak)


class PackageSoakChecks(unittest.TestCase):
    def test_three_consecutive_comparable_windows_and_both_thresholds(self):
        d = soak.Drift({"record": [.1] * 1000})
        self.assertEqual([], d.window({"record": [.16] * 1000}, 1000, 1000, 0))
        self.assertEqual([], d.window({"record": [.16] * 1000}, 1000, 1000, 0))
        self.assertIn("sustained_latency:record:p99",
                      d.window({"record": [.16] * 1000}, 1000, 1000, 0))
        # Relative increase alone does not meet the absolute50ms detector.
        d = soak.Drift({"record": [.01] * 1000})
        for window in range(4):
            signals = d.window({"record": [.03] * 1000}, 1000, 1000, 0)
            self.assertNotIn("sustained_latency:record:p99", signals)
            self.assertEqual(window >= 2,
                             "smaller_drift_requires_assessment:record:p99" in signals)

    def test_sparse_or_recovered_window_breaks_consecutive_run(self):
        for interruption in ([], [.1] * 1000):
            d = soak.Drift({"record": [.1] * 1000})
            d.window({"record": [.2] * 1000}, 1000, 1000, 0)
            d.window({"record": [.2] * 1000}, 1000, 1000, 0)
            d.window({"record": interruption}, 1000, 1000, 0)
            self.assertEqual([], d.window({"record": [.2] * 1000}, 1000, 1000, 0))

    def test_sparse_low_rate_degradation_requires_assessment_without_fake_quantiles(self):
        for worsened in (.11, .2):
            d = soak.Drift({"rare": [.1] * 5})
            for window in range(4):
                signals = d.window({"rare": [worsened] * 5}, 5, 5, 0)
                self.assertEqual(window >= 2, "sparse_latency_requires_assessment:rare" in signals)
                self.assertFalse(any("p95" in flag or "p99" in flag for flag in signals))
                self.assertEqual(5, d.comparisons["rare"]["window_count"])
                self.assertEqual(worsened, d.comparisons["rare"]["window_max"])
        d = soak.Drift({"rare": [.1] * 5})
        for _ in range(4):
            self.assertEqual([], d.window({"rare": [.1] * 5}, 5, 5, 0))
        self.assertIn("missing_comparable_latency_evidence:rare", d.window({}, 5, 0, 0))

    def test_concurrent_breach_survives_gap_in_both_collection_orders(self):
        for errors in ((soak.Gap("driver"), soak.Breach("business")),
                       (soak.Breach("business"), soak.Gap("driver"))):
            futures = []
            for error in errors:
                future = soak.concurrent.futures.Future()
                future.set_exception(error)
                futures.append(future)
            observed = soak.collect_future_errors(futures)
            self.assertEqual(2, len(observed))
            self.assertIsInstance(soak.preferred_error(observed), soak.Breach)

    def test_business_terminal_event_keeps_case_step_request_and_dominates_later_gap(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            run = soak.Run({"connection": {}, "profile": {"bindings": {}}, "run_id": "unit-only",
                            "package": {"build_identity": "a" * 64, "source_sha": "b" * 40}}, out)
            def response(*_args):
                run.local.request_id = 17
                return 200, {"observed": "wrong"}
            run.request = response
            run.active["worker"] = {"eligible_at": 0, "waiting_until": 0, "progress_deadline": 120}
            case = {"name": "strict", "eligible_after_seconds": 0, "operation_budget_seconds": 120,
                    "steps": [{"name": "readback", "method": "POST", "path": "/agent/dispatch",
                               "body": {"verb": "work-item-get"}, "timeout_seconds": 10,
                               "expect": {"/observed": "correct"}}]}
            with self.assertRaises(soak.Breach):
                run.transaction(case, "worker", "measured")
            self.assertNotIn("worker", run.active)
            rows = [json.loads(row) for row in (out / "operations.jsonl").read_text().splitlines()]
            terminal = rows[-1]
            self.assertEqual(("transaction_outcome", "FAIL", "strict", "readback", 17),
                             tuple(terminal[k] for k in ("kind", "status", "case", "step", "request_id")))
            def missing_setup():
                raise soak.Gap("independent setup/host limitation")
            run.setup = missing_setup
            result = run.execute()
            self.assertEqual("FAIL", result["status"])
            self.assertEqual(1, result["worker_terminal_counts"]["FAIL"])
            self.assertEqual("strict", result["worker_failures"][0]["case"])

    def test_ready_stall_is_independent_of_operation_timeout_and_legitimate_waits(self):
        ready = {"eligible_at": 0, "waiting_until": 0, "progress_deadline": 120}
        self.assertIn("global30s_completion_stall_detector", soak.stall_signals(31, 0, [ready]))
        self.assertIn("eligible60s_progress_stall_detector", soak.stall_signals(181, 0, [ready]))
        waiting = {**ready, "waiting_until": 120}
        self.assertEqual([], soak.stall_signals(31, 0, [waiting]))
        self.assertEqual([], soak.stall_signals(149, 0, [waiting]))
        self.assertIn("global30s_completion_stall_detector", soak.stall_signals(151, 0, [waiting]))
        self.assertIn("global30s_completion_stall_detector", soak.stall_signals(31, 0, [waiting, ready]))
        future = {**ready, "eligible_at": 100}
        self.assertEqual([], soak.stall_signals(31, 0, [future]))
        self.assertEqual([], soak.stall_signals(129, 0, [future]))

    def test_early_timeout_is_durable_investigation_before_eligibility_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            run = soak.Run({"connection": {}, "profile": {"bindings": {}}, "run_id": "unit-only"}, out)
            def timed_out(*_args):
                run.local.request_id = 23
                raise TimeoutError("bounded request expired")
            run.request = timed_out
            run.active["worker"] = {"eligible_at": 0, "waiting_until": 0, "progress_deadline": 120}
            case = {"name": "bounded", "eligible_after_seconds": 0, "operation_budget_seconds": 120,
                    "steps": [{"name": "public-read", "method": "GET", "path": "/api/work-items",
                               "timeout_seconds": 1, "expect": {"/state": "ready"}}]}
            with self.assertRaises(TimeoutError):
                run.transaction(case, "worker", "measured")
            run.events.close()
            row = json.loads((out / "operations.jsonl").read_text().splitlines()[-1])
            self.assertEqual("INCONCLUSIVE", row["status"])
            self.assertEqual(23, row["request_id"])
            self.assertIn("earlier_deadline", row["investigation"])
            self.assertEqual(0, row["eligibility"]["eligible_at"])
            self.assertNotIn("worker", run.active)

    def test_throughput_requires_accumulating_eligible_backlog(self):
        d = soak.Drift({})
        for backlog in (1, 2):
            self.assertEqual([], d.window({}, 100, 90, backlog))
        self.assertIn("sustained_throughput_backlog", d.window({}, 100, 90, 3))
        d = soak.Drift({})
        for _ in range(5):
            self.assertEqual([], d.window({}, 100, 90, 0))

    def test_full_payload_mismatch_rejects_extra_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            for leaf in ("bin/tightbeam", "bin/tightbeam-gateway"):
                p = root / leaf
                p.parent.mkdir(exist_ok=True)
                p.write_text("fixture payload, never executed")
                p.chmod(0o700)
            entries = [{"path": p.relative_to(root).as_posix(), "sha256": soak.digest(p)}
                       for p in sorted(root.rglob("*")) if p.is_file()]
            encoded = "".join(f"{len(e['path'].encode())}:{e['path']}:{e['sha256']}\n" for e in entries)
            identity = soak.hashlib.sha256(("tightbeam-payload/v1\n" + encoded).encode()).hexdigest()
            manifest = root / "build-manifest.json"
            manifest.write_text(json.dumps({"format": "tightbeam-payload/v1", "files": entries,
                                            "buildIdentity": identity}))
            # Archive and receipt live outside the enumerated package, as in real staging.
            with tempfile.TemporaryDirectory() as outside:
                archive = Path(outside) / "package.tgz"
                archive.write_bytes(b"opaque fixture archive")
                proof = Path(outside) / "accepted.json"
                proof.write_text(json.dumps({"acceptance_reference": "unit-only",
                    "source_sha": "a" * 40, "archive_sha256": soak.digest(archive),
                    "build_identity": identity, "payload_manifest_sha256": soak.digest(manifest)}))
                def pin(p):
                    return {"path": str(p), "sha256": soak.digest(p)}
                package = {"root": str(root), "archive": pin(archive), "manifest": pin(manifest),
                           "build_identity": identity, "source_sha": "a" * 40, "version_sha": "a" * 8,
                           "accepted_provenance": pin(proof)}
                self.assertEqual(root, soak.payload(package))
                (root / "unexpected.beam").write_bytes(b"unlisted behavior")
                with self.assertRaises(soak.Gap):
                    soak.payload(package)

    def test_typed_id_substitution_and_missing_field_do_not_invent_evidence(self):
        self.assertEqual({"id": 42}, soak.substitute({"id": {"$ref": "id"}}, {"id": 42}))
        with self.assertRaises(KeyError):
            soak.pointer({"result": {}}, "/result/id")
        with self.assertRaises(KeyError):
            soak.substitute({"$ref": "unobserved_id"}, {})
        self.assertEqual("a", soak.pointer({"x/y": ["a"]}, "/x~1y/0"))
        self.assertEqual(11000, soak.substitute({"$after_ms": 10000}, {"now_ms": 1000}))
        with self.assertRaises(soak.Gap):
            soak.substitute({"$after_ms": -1}, {"now_ms": 1000})

    def test_whole_exchange_timeout_preserves_unknown_effect_without_retry(self):
        requests = []
        class SlowHeaders(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                requests.append(self.path)
                time.sleep(2)  # A reply never arrives within the frozen request budget.
                self.close_connection = True
            def log_message(self, *_args):
                pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SlowHeaders)
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp)
                run = soak.Run({"connection": {"port": server.server_port},
                                "max_response_bytes": 4096}, out)
                start = time.monotonic()
                with self.assertRaises((OSError, soak.http.client.HTTPException)):
                    run.request("POST", "/agent/dispatch", {"verb": "wake"}, .1)
                self.assertLess(time.monotonic() - start, 1)
                self.assertEqual(["/agent/dispatch"], requests)
                run.events.close()
                rows = [json.loads(row) for row in (out / "operations.jsonl").read_text().splitlines()]
                self.assertTrue(rows[-1]["effect_unknown"])
                self.assertFalse(rows[-1]["retried"])
                self.assertEqual("request_transport_error", rows[-1]["kind"])
                self.assertTrue((out / rows[0]["raw"]).is_file())
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)

    def test_read_only_poll_surface_and_required_coverage(self):
        profile = {"baseline_seconds": 300, "measure_seconds": 43200, "concurrency": 1,
                   "representativeness_evidence": "unit-only proxy",
                   "cases": [{"name": "record", "period_seconds": 2,
                              "operation_budget_seconds": 10, "eligible_after_seconds": 0,
                              "coverage": ["ordinary_record"], "steps": [{
                                  "name": "read", "marks_eligible": True,
                                  "method": "GET", "path": "/api/work-items",
                                  "timeout_seconds": 2, "expect": {"/items": []}}]}]}
        self.assertEqual(soak.COVERAGE - {"ordinary_record"}, soak.validate_profile(profile))
        profile["cases"][0]["operation_budget_seconds"] = float("inf")
        with self.assertRaises(soak.Gap):
            soak.validate_profile(profile)
        profile["cases"][0]["operation_budget_seconds"] = 10
        step = profile["cases"][0]["steps"][0]
        step.update(method="POST", path="/agent/dispatch", body={"verb": "work-item-create"}, poll_seconds=1)
        with self.assertRaises(soak.Gap):
            soak.validate_profile(profile)
        step.pop("poll_seconds")
        step["body"]["verb"] = "host-env-set"
        with self.assertRaises(soak.Gap):
            soak.validate_profile(profile)


if __name__ == "__main__":
    unittest.main()
