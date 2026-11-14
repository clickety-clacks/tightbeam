import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sentinel


RECIPIENT = "agent:test:po:main s_test"
NEXT_PAGE = "https://api.appstoreconnect.apple.com/v1/apps/1/betaFeedbackCrashSubmissions?cursor=second"


def submission(
    report_id,
    build_id=None,
    comment="a crash comment",
    build_bundle_id="com.example.app",
):
    return {
        "type": "betaFeedbackCrashSubmissions",
        "id": report_id,
        "attributes": {
            "createdDate": "2026-11-13T13:09:00-07:00",
            "comment": comment,
            "deviceModel": "iPhone19_4",
            "osVersion": "27.2",
            "testerEmail": "tester@example.invalid",
            "testerName": "Private Tester",
            "buildBundleId": build_bundle_id,
        },
        "relationships": {"build": {"data": {"type": "builds", "id": build_id}}} if build_id else {},
    }


class FakeASC:
    KEY_ID = "test-key-id"
    ISSUER_ID = "test-issuer-id"

    def __init__(
        self,
        include_reports=True,
        missing_log=False,
        fail_submissions=False,
        fail_build_read=False,
    ):
        self.calls = []
        self.include_reports = include_reports
        self.missing_log = missing_log
        self.fail_submissions = fail_submissions
        self.fail_build_read = fail_build_read
        self.crash_log_texts = {
            "r1": "Version: 9.9.9 (999)\nCrash header\neyJheader.secret.signature\ntest-key-id test-issuer-id\nlog tail\n",
            "r2": "Version: 0.2.0\nBuild: 190\nCrash header\n",
            "r3": "Version: 0.3.0 (191)\nCrash header\n",
        }

    def api_get(self, endpoint):
        self.calls.append(endpoint)
        if endpoint == "apps/1":
            return {"data": {"id": "1", "attributes": {"name": "App One"}}}
        if endpoint == "apps/2":
            return {"data": {"id": "2", "attributes": {"name": "App Two"}}}
        if endpoint == "apps/1/betaFeedbackCrashSubmissions?limit=200":
            if self.fail_submissions:
                return {"errors": [{"status": "401", "code": "NOT_AUTHORIZED", "detail": "discarded"}]}
            if not self.include_reports:
                return {"data": [], "links": {}}
            return {"data": [submission("r1", "b1")], "links": {"next": NEXT_PAGE}}
        if endpoint == "apps/1/betaFeedbackCrashSubmissions?cursor=second":
            return {"data": [submission("r2", comment="second comment")], "links": {}}
        if endpoint == "apps/2/betaFeedbackCrashSubmissions?limit=200":
            return {"data": [submission("r3", comment="third comment")] if self.include_reports else [], "links": {}}
        if endpoint == "builds/b1":
            if self.fail_build_read:
                return {"errors": [{"status": "404", "code": "NOT_FOUND"}]}
            return {
                "data": {
                    "id": "b1",
                    "attributes": {"version": "189"},
                    "relationships": {"preReleaseVersion": {"data": {"id": "v1"}}},
                }
            }
        if endpoint == "preReleaseVersions/v1":
            return {"data": {"id": "v1", "attributes": {"version": "0.1.0"}}}
        if endpoint in {
            "betaFeedbackCrashSubmissions/r1/crashLog",
            "betaFeedbackCrashSubmissions/r2/crashLog",
            "betaFeedbackCrashSubmissions/r3/crashLog",
        }:
            if self.missing_log:
                return {"data": None}
            return {
                "data": {
                    "type": "betaCrashLogs",
                    "attributes": {
                        "logText": self.crash_log_texts[endpoint.split("/")[1]]
                    },
                }
            }
        return {"errors": [{"status": "404", "code": "NOT_FOUND"}]}


class SentinelTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.state = self.root / "state.json"
        self.log = self.root / "sentinel.log"
        self.workspace = self.root / "workspace"
        self.crash_root = self.workspace / "shared/testflight-sentinel/crash-logs"

    def tearDown(self):
        self.temporary.cleanup()

    def register(self, app_id="1", recipient=RECIPIENT):
        sentinel.register_app(app_id, [recipient], self.state)

    def test_registration_is_idempotent_and_history_survives_removal(self):
        self.assertIn("registered recipient", sentinel.register_app("1", [RECIPIENT], self.state))
        before = self.state.read_text(encoding="utf-8")
        self.assertIn("already registered", sentinel.register_app("1", [RECIPIENT], self.state))
        self.assertEqual(before, self.state.read_text(encoding="utf-8"))
        state = sentinel.load_state(self.state)
        state["delivered"] = {"1": {RECIPIENT: ["r1"]}}
        sentinel.save_state(state, self.state)
        sentinel.unregister_app("1", state_path=self.state)
        sentinel.register_app("1", [RECIPIENT], self.state)
        state = sentinel.load_state(self.state)
        self.assertEqual(["r1"], state["delivered"]["1"][RECIPIENT])

    def test_check_paginates_batches_across_apps_and_repeat_deduplicates(self):
        self.register("1")
        self.register("2")
        helper = FakeASC()
        wakes = []
        result = sentinel.run_check(
            self.state,
            self.log,
            self.crash_root,
            self.workspace,
            helper,
            lambda recipient, prompt: wakes.append((recipient, prompt)) or True,
        )
        self.assertEqual({"reports": 3, "wakes": 1, "errors": 0}, result)
        self.assertEqual(1, len(wakes))
        prompt = wakes[0][1]
        self.assertIn("TestFlight sentinel: 3 new crash reports", prompt)
        self.assertIn("App One (1)", prompt)
        self.assertIn("App Two (2)", prompt)
        self.assertIn("0.1.0 (189)", prompt)
        self.assertIn("0.2.0 (190)", prompt)
        self.assertIn("0.3.0 (191)", prompt)
        self.assertNotIn("9.9.9 (999)", prompt)
        self.assertNotIn("buildBundleId:", prompt)
        self.assertIn("iPhone19_4", prompt)
        self.assertIn("iOS 27.2", prompt)
        self.assertIn("2026-11-13T13:09:00-07:00", prompt)
        self.assertIn("comment: \"a crash comment\"", prompt)
        self.assertIn("shared/testflight-sentinel/crash-logs/1/r1.crash", prompt)
        self.assertNotIn("tester@example.invalid", prompt)
        self.assertNotIn("Private Tester", prompt)
        saved_log = (self.crash_root / "1/r1.crash").read_text(encoding="utf-8")
        self.assertEqual(
            "Version: 9.9.9 (999)\nCrash header\n[redacted token]\n[redacted] [redacted]\nlog tail\n",
            saved_log,
        )
        self.assertNotIn("eyJheader", saved_log)
        self.assertNotIn("test-key-id", saved_log)
        self.assertNotIn("test-issuer-id", saved_log)
        self.assertIn("apps/1/betaFeedbackCrashSubmissions?cursor=second", helper.calls)

        repeated = sentinel.run_check(
            self.state,
            self.log,
            self.crash_root,
            self.workspace,
            helper,
            lambda recipient, prompt: wakes.append((recipient, prompt)) or True,
        )
        self.assertEqual({"reports": 0, "wakes": 0, "errors": 0}, repeated)
        self.assertEqual(1, len(wakes))

    def test_submission_error_is_not_an_empty_check_and_does_not_mark_delivery(self):
        self.register()
        helper = FakeASC(fail_submissions=True)
        wakes = []
        result = sentinel.run_check(
            self.state,
            self.log,
            self.crash_root,
            self.workspace,
            helper,
            lambda recipient, prompt: wakes.append(prompt) or True,
        )
        self.assertEqual({"reports": 0, "wakes": 0, "errors": 1}, result)
        self.assertEqual([], wakes)
        self.assertEqual({}, sentinel.load_state(self.state)["delivered"])
        log = self.log.read_text(encoding="utf-8")
        self.assertIn("App Store Connect error 401 NOT_AUTHORIZED", log)
        self.assertNotIn("discarded", log)

    def test_failed_build_relationship_read_falls_back_to_crash_header(self):
        self.register()
        helper = FakeASC(fail_build_read=True)
        wakes = []
        result = sentinel.run_check(
            self.state,
            self.log,
            self.crash_root,
            self.workspace,
            helper,
            lambda recipient, prompt: wakes.append(prompt) or True,
        )
        self.assertEqual({"reports": 2, "wakes": 1, "errors": 0}, result)
        self.assertIn("build 9.9.9 (999)", wakes[0])
        self.assertIn("builds/b1", helper.calls)

    def test_failed_wake_stays_undelivered_then_succeeds_once(self):
        self.register()
        helper = FakeASC()
        decisions = iter([False, True, True])
        prompts = []

        def wake(recipient, prompt):
            prompts.append(prompt)
            return next(decisions)

        first = sentinel.run_check(self.state, self.log, self.crash_root, self.workspace, helper, wake)
        self.assertEqual(1, first["errors"])
        self.assertEqual({}, sentinel.load_state(self.state)["delivered"])
        second = sentinel.run_check(self.state, self.log, self.crash_root, self.workspace, helper, wake)
        self.assertEqual({"reports": 2, "wakes": 1, "errors": 0}, second)
        third = sentinel.run_check(self.state, self.log, self.crash_root, self.workspace, helper, wake)
        self.assertEqual({"reports": 0, "wakes": 0, "errors": 0}, third)
        self.assertEqual(2, len(prompts))

    def test_missing_crash_log_is_delivered_without_a_path(self):
        self.register()
        helper = FakeASC(missing_log=True)
        wakes = []
        result = sentinel.run_check(
            self.state,
            self.log,
            self.crash_root,
            self.workspace,
            helper,
            lambda recipient, prompt: wakes.append(prompt) or True,
        )
        self.assertEqual(2, result["reports"])
        self.assertIn("crash log not saved: App Store Connect returned no crash log", wakes[0])
        self.assertIn("buildBundleId: com.example.app; build not reported", wakes[0])
        self.assertNotIn(".crash", wakes[0])

    def test_registered_apps_with_no_reports_send_nothing(self):
        self.register("1")
        self.register("2")
        helper = FakeASC(include_reports=False)
        wakes = []
        result = sentinel.run_check(
            self.state,
            self.log,
            self.crash_root,
            self.workspace,
            helper,
            lambda recipient, prompt: wakes.append(prompt) or True,
        )
        self.assertEqual({"reports": 0, "wakes": 0, "errors": 0}, result)
        self.assertIn("apps/1/betaFeedbackCrashSubmissions?limit=200", helper.calls)
        self.assertIn("apps/2/betaFeedbackCrashSubmissions?limit=200", helper.calls)
        self.assertEqual([], wakes)

    def test_new_recipient_gets_history_without_redelivery_to_existing_recipient(self):
        second_recipient = "agent:test:po:second s_test"
        self.register()
        state = sentinel.load_state(self.state)
        state["delivered"] = {"1": {RECIPIENT: ["r1", "r2"]}}
        sentinel.save_state(state, self.state)
        sentinel.register_app("1", [second_recipient], self.state)
        helper = FakeASC()
        wakes = []
        result = sentinel.run_check(
            self.state,
            self.log,
            self.crash_root,
            self.workspace,
            helper,
            lambda recipient, prompt: wakes.append((recipient, prompt)) or True,
        )
        self.assertEqual({"reports": 2, "wakes": 1, "errors": 0}, result)
        self.assertEqual([second_recipient], [recipient for recipient, _ in wakes])
        self.assertIn("r1", wakes[0][1])
        self.assertIn("r2", wakes[0][1])


if __name__ == "__main__":
    unittest.main()
