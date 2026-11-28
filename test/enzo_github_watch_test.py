"""Offline tests for the shipped Enzo watcher."""

import importlib.machinery
import importlib.util
import io
from pathlib import Path
import unittest


PROGRAM = Path(__file__).resolve().parents[1] / "priv/kungfu/uncle-enzo/sentinels/github-landing-watch"
loader = importlib.machinery.SourceFileLoader("enzo_watch", str(PROGRAM))
watch = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(watch)


class Runner:
    def __init__(self, demand=()):
        self.demand = list(demand)
        self.posts = []
        self.reads = []

    def tightbeam_json(self, args):
        if args[:2] == ["sentinel", "demand"]:
            return {"demand": self.demand, "extra": "ignored"}
        return {}

    def tightbeam(self, args):
        self.posts.append(args)
        return True, ""

    def graphql(self, query, variables):
        self.reads.append(variables)
        pull = {
            "state": "MERGED",
            "merged": True,
            "mergeCommit": {"oid": "merge"},
            "headRefOid": "head",
            "baseRefName": "main",
            "timelineItems": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        }
        return {"repository": {"pullRequest": pull}}


class WatchTest(unittest.TestCase):
    def setUp(self):
        self.log = watch.Log(io.StringIO())

    def test_no_github_reads_without_qualified_demand(self):
        runner = Runner([
            {"kind": "agentic-engineering/landing.settled", "filter": {"scope": ["org/repo#1"]}},
            {"kind": watch.PREFIX + watch.SETTLED, "filter": {"scope": []}},
        ])
        self.assertEqual(watch.run(["watch", "--once"], {}, runner, self.log), 0)
        self.assertEqual(runner.reads, [])
        self.assertEqual(runner.posts, [])

    def test_merge_replay_has_same_key_and_attributable_details(self):
        runner = Runner()
        for _ in range(2):
            self.assertTrue(watch.poll_demanded_pr("org/repo#1", {watch.SETTLED}, runner, self.log))
        first, second = runner.posts
        self.assertEqual(first, second)
        self.assertEqual(first[:4], ["sentinel", "post", "--event", watch.PREFIX + watch.SETTLED])
        self.assertIn("scope=org/repo#1", first)
        self.assertIn("head=head", first)
        self.assertIn("commit=merge", first)
        self.assertIn("evidence=https://github.com/org/repo/pull/1", first)

    def test_checks_require_visible_expected_checks_and_terminal_results(self):
        linux = {"__typename": "CheckRun", "id": "a", "name": "linux",
                 "status": "COMPLETED", "conclusion": "SUCCESS", "isRequired": True}
        required = [{"context": name, "integration_id": None} for name in ("linux", "macos")]
        self.assertIsNone(watch.completed_checks([linux], required))
        macos = {**linux, "id": "b", "name": "macos", "status": "QUEUED"}
        self.assertIsNone(watch.completed_checks([linux, macos], required))
        done = {**macos, "status": "COMPLETED", "conclusion": "FAILURE"}
        outcome, key = watch.completed_checks([linux, done], required)
        self.assertEqual(outcome, "fail")
        self.assertEqual((outcome, key), watch.completed_checks([done, linux], required))
        self.assertNotEqual(key, watch.completed_checks([linux, {**done, "id": "rerun"}], required)[1])


if __name__ == "__main__":
    unittest.main()
